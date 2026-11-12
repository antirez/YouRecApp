import AVFoundation
import CoreML
import CryptoKit
import Foundation

/// VoiceFixer's full-band analysis network + neural vocoder. Inference is
/// independent per channel, with bounded context and overlapping output. Unlike
/// LavaSR's detail stage, this replaces the entire speech waveform.
enum StudioRestorationProcessor {
    static let context = 255 * 441
    static let margin = 64 * 441
    static let stride = 120 * 441
    static let overlap = context - 2 * margin - stride
    // Include reflected samples on both sides of the file. Near the final hop,
    // right-edge reflection can reach earlier than position - margin.
    static func sourceIndices(position: Int64, length: Int64) -> [Int64] {
        precondition(length > 0)
        return (0..<context).map { i in
            guard length > 1 else { return 0 }
            let period = 2 * (length - 1)
            let j = ((position - Int64(margin) + Int64(i)) % period + period) % period
            return j < length ? j : period - j
        }
    }
    private static let lock = NSLock()
    private static var verified = Set<URL>()
    private static func hash(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var digest = SHA256()
        while let data = try file.read(upToCount: 1048576), !data.isEmpty { try Task.checkCancellation(); digest.update(data: data) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func resources() throws -> (URL, URL) {
        #if DEBUG || os(macOS)
        let root = ProcessInfo.processInfo.environment["YOUREC_VOICEFIXER_MODEL"].map { URL(fileURLWithPath: $0) }
        #else
        let root: URL? = nil
        #endif
        guard let model = root?.appendingPathComponent("VoiceFixer.mlmodelc") ?? Bundle.main.url(forResource: "VoiceFixer", withExtension: "mlmodelc"),
              let bank = root?.appendingPathComponent("VoiceFixer-Mel.bin") ?? Bundle.main.url(forResource: "VoiceFixer-Mel", withExtension: "bin") else { throw AudioProcessingError.unavailableModel }
        lock.lock(); defer { lock.unlock() }
        if !verified.contains(model) {
            guard try hash(model.appendingPathComponent("weights/weight.bin")) == AudioModel.voiceFixer.weightsSHA256,
                  try hash(model.appendingPathComponent("model.mil")) == "912bf44f5a89014f385a681fb7319af92fe9f19e22337c95fcddd7dac21760d2",
                  try hash(bank) == "ea5f198b442761e300d9f270090b5ed8c7a9936126b110b54cff03767198dcd9" else { throw AudioProcessingError.unavailableModel }
            verified.insert(model)
        }
        return (model, bank)
    }
    static func process(input: URL, output: URL, amount: Float, resumeFolder: URL? = nil, progress: (Double) -> Void) throws {
        guard amount.isFinite, (0...1).contains(amount) else { throw AudioProcessingError.invalidFormat }
        if amount == 0 { try FileManager.default.copyItem(at: input, to: output); progress(1); return }
        let original = try AVAudioFile(forReading: input)
        guard original.processingFormat.sampleRate == 48000, original.length > 0 else { throw AudioProcessingError.invalidFormat }
        let (modelURL, bankURL) = try resources()
        let configuration = MLModelConfiguration(); configuration.computeUnits = .cpuAndGPU
        let model = try MLModel(contentsOf: modelURL, configuration: configuration)
        let bankData = try Data(contentsOf: bankURL)
        let bank: [Float] = bankData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard bank.count == 1025 * 128 else { throw AudioProcessingError.invalidFormat }
        let scratch = output.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".studio-work")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let down = scratch.appendingPathComponent("input.caf"), wet = scratch.appendingPathComponent("restored.caf"), up = scratch.appendingPathComponent("output.caf")
        try resample(input, to: down, rate: 44100)
        let source = try AVAudioFile(forReading: down, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = source.processingFormat, channels = Int(source.processingFormat.channelCount)
        var settings = format.settings; settings[AVLinearPCMIsNonInterleaved] = false
        if let resumeFolder {
            let identity = "\(resumeFolder.lastPathComponent)|\(AudioModel.voiceFixer)|\(source.length)|\(channels)"
            let metadata = resumeFolder.appendingPathComponent("processing.txt")
            if FileManager.default.fileExists(atPath: resumeFolder.path), (try? String(contentsOf: metadata, encoding: .utf8)) != identity { try FileManager.default.removeItem(at: resumeFolder) }
            try FileManager.default.createDirectory(at: resumeFolder, withIntermediateDirectories: true)
            try identity.write(to: metadata, atomically: true, encoding: .utf8)
        }
        guard let read = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(context)),
              let rendered = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(stride + overlap)),
              let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(stride + overlap)),
              let samples = read.floatChannelData, let result = rendered.floatChannelData, let raw = chunk.floatChannelData else { throw AudioProcessingError.invalidFormat }
        let mel = try MLMultiArray(shape: [1, 1, 256, 128], dataType: .float32)
        let provider = try MLDictionaryFeatureProvider(dictionary: ["mel": MLFeatureValue(multiArray: mel)])
        var tail = Array(repeating: [Float](repeating: 0, count: overlap), count: channels)
        var window = [Float](repeating: 0, count: context)
        var position: Int64 = 0
        let thermal = AudioThermalGate()
        // Close the output before the resampler reads it.
        do {
            let target = try AVAudioFile(forWriting: wet, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            while position < source.length {
                try thermal.cooperate()
                let count = min(stride, Int(source.length - position)), valid = min(stride + overlap, Int(source.length - position))
                let cachedURL = resumeFolder?.appendingPathComponent("\(position).caf")
                var reused = false
                if let cachedURL, let cached = try? AVAudioFile(forReading: cachedURL, commonFormat: .pcmFormatFloat32, interleaved: false), cached.length == valid,
                   cached.processingFormat == format, (try? cached.read(into: chunk)) != nil, chunk.frameLength == valid { reused = true }
                if !reused {
                    let indices = sourceIndices(position: position, length: source.length)
                    let readStart = indices.min()!, readEnd = indices.max()! + 1
                    source.framePosition = readStart
                    try source.read(into: read, frameCount: AVAudioFrameCount(readEnd - readStart))
                    for channel in 0..<channels {
                        try Task.checkCancellation()
                        if channel > 0 && memcmp(samples[0], samples[channel], Int(read.frameLength) * MemoryLayout<Float>.size) == 0 { raw[channel].update(from: raw[0], count: valid); continue }
                        for i in 0..<context {
                            window[i] = samples[channel][Int(indices[i] - readStart)]
                        }
                        if window.allSatisfy({ abs($0) < 1e-8 }) { raw[channel].initialize(repeating: 0, count: valid); continue }
                        let ok = window.withUnsafeBufferPointer { audio in bank.withUnsafeBufferPointer { bank in yr_voicefixer_features(audio.baseAddress, bank.baseAddress, mel.dataPointer.assumingMemoryBound(to: Float.self)) } }
                        guard ok == 1 else { throw AudioProcessingError.invalidFormat }
                        try autoreleasepool {
                            let prediction = try model.prediction(from: provider)
                            guard let audio = prediction.featureValue(for: "audio")?.multiArrayValue, audio.dataType == .float32,
                                  audio.shape.map(\.intValue) == [1, 260 * 441] else { throw AudioProcessingError.invalidFormat }
                            let data = audio.dataPointer.assumingMemoryBound(to: Float.self), sampleStride = audio.strides.last!.intValue
                            // Upstream centers the vocoder padding around the input.
                            let trim = (audio.count - context) / 2
                            for i in 0..<valid {
                                let value = data[(margin + trim + i) * sampleStride]
                                guard value.isFinite else { throw AudioProcessingError.invalidFormat }; raw[channel][i] = value
                            }
                        }
                    }
                    chunk.frameLength = AVAudioFrameCount(valid)
                    if let cachedURL {
                        let partial = cachedURL.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".partial.caf")
                        defer { try? FileManager.default.removeItem(at: partial) }
                        do { let file = try AVAudioFile(forWriting: partial, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false); try file.write(from: chunk) }
                        try Task.checkCancellation()
                        if !FileManager.default.fileExists(atPath: cachedURL.path) { try FileManager.default.moveItem(at: partial, to: cachedURL) }
                    }
                }
                for channel in 0..<channels {
                    for i in 0..<count {
                        let weight = position > 0 && i < overlap ? Float(i + 1) / Float(overlap + 1) : 1
                        result[channel][i] = weight * raw[channel][i] + (1 - weight) * (i < overlap ? tail[channel][i] : 0)
                    }
                    for i in 0..<overlap { tail[channel][i] = count + i < valid ? raw[channel][count + i] : 0 }
                }
                rendered.frameLength = AVAudioFrameCount(count); try target.write(from: rendered)
                position += Int64(count); progress(0.05 + 0.85 * Double(position) / Double(max(1, source.length)))
            }
        }
        try resample(wet, to: up, rate: 48000)
        try mix(original: input, restored: up, output: output, amount: amount)
        progress(1)
    }
    private static func resample(_ input: URL, to output: URL, rate: Double) throws {
        let source = try AVAudioFile(forReading: input, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: source.processingFormat.channelCount),
              let converter = AVAudioConverter(from: source.processingFormat, to: format),
              let read = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 8192),
              let rendered = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else { throw AudioProcessingError.invalidFormat }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        var settings = format.settings; settings[AVLinearPCMIsNonInterleaved] = false
        let target = try AVAudioFile(forWriting: output, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        var inputError: Error?
        while true {
            try Task.checkCancellation()
            var error: NSError?
            let status = converter.convert(to: rendered, error: &error) { count, state in
                if source.framePosition >= source.length { state.pointee = .endOfStream; return nil }
                do { try source.read(into: read, frameCount: min(count, read.frameCapacity)); state.pointee = .haveData; return read }
                catch { inputError = error; state.pointee = .endOfStream; return nil }
            }
            if let inputError { throw inputError }; if let error { throw error }
            if rendered.frameLength > 0 { try target.write(from: rendered) }
            if status == .endOfStream { break }
            if status == .error { throw AudioProcessingError.invalidFormat }
        }
    }
    private static func mix(original: URL, restored: URL, output: URL, amount: Float) throws {
        let dry = try AVAudioFile(forReading: original, commonFormat: .pcmFormatFloat32, interleaved: false)
        let wet = try AVAudioFile(forReading: restored, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard dry.processingFormat.sampleRate == 48000, dry.processingFormat == wet.processingFormat, abs(dry.length - wet.length) <= 2,
              let a = AVAudioPCMBuffer(pcmFormat: dry.processingFormat, frameCapacity: 8192), let b = AVAudioPCMBuffer(pcmFormat: dry.processingFormat, frameCapacity: 8192) else { throw AudioProcessingError.invalidFormat }
        var settings = dry.processingFormat.settings; settings[AVLinearPCMIsNonInterleaved] = false
        let target = try AVAudioFile(forWriting: output, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        while dry.framePosition < dry.length {
            try Task.checkCancellation(); try dry.read(into: a); try wet.read(into: b, frameCount: a.frameLength)
            for c in 0..<Int(a.format.channelCount) { for i in 0..<Int(a.frameLength) {
                let value = i < Int(b.frameLength) ? b.floatChannelData![c][i] : 0
                a.floatChannelData![c][i] += amount * (value - a.floatChannelData![c][i])
            } }
            try target.write(from: a)
        }
    }
}
