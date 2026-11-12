import AVFoundation
import CoreML
import CryptoKit
import Foundation

enum StudioVoiceProcessor {
    static let contextFrames = 192000
    static let margin = 16384 // 32 STFT hops; exceeds the network receptive radius.
    static let strideFrames = contextFrames - 2 * margin
    private static let integrityLock = NSLock()
    private static var verifiedModels = Set<URL>()

    private static func verifyModel(_ url: URL) throws {
        integrityLock.lock(); defer { integrityLock.unlock() }
        if verifiedModels.contains(url) { return }
        for (name, expected) in [
            "weights/weight.bin": AudioModel.lava.weightsSHA256,
            "model.mil": "8a68fd3d717c6d5ae48318dc9dea6729ea8566b387e8cd296f56a11df57490de"
        ] {
            let file = try FileHandle(forReadingFrom: url.appendingPathComponent(name))
            defer { try? file.close() }
            var hash = SHA256()
            while true {
                try Task.checkCancellation()
                let data = try file.read(upToCount: 1024 * 1024) ?? Data()
                if data.isEmpty { break }
                hash.update(data: data)
            }
            guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == expected else {
                throw AudioProcessingError.unavailableModel
            }
        }
        verifiedModels.insert(url)
    }

    static func process(input: URL, output: URL, amount: Float, resumeFolder: URL? = nil, progress: (Double) -> Void) throws {
        #if DEBUG || os(macOS)
        let override = ProcessInfo.processInfo.environment["YOUREC_LAVA_MODEL"].map { URL(fileURLWithPath: $0) }
        #else
        let override: URL? = nil
        #endif
        guard let url = override ?? Bundle.main.url(forResource: "LavaSRv2", withExtension: "mlmodelc") else { throw AudioProcessingError.unavailableModel }
        try verifyModel(url)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndGPU
        let model = try MLModel(contentsOf: url, configuration: configuration)
        let source = try AVAudioFile(forReading: input, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = source.processingFormat
        guard format.sampleRate == 48000 else { throw AudioProcessingError.invalidFormat }
        var settings = format.settings; settings[AVLinearPCMIsNonInterleaved] = false
        let target = try AVAudioFile(forWriting: output, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(contextFrames)),
              let rendered = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(strideFrames)),
              let channels = buffer.floatChannelData, let result = rendered.floatChannelData
        else { throw AudioProcessingError.invalidFormat }
        let mel = try MLMultiArray(shape: [1, 80, 375], dataType: .float32)
        let provider = try MLDictionaryFeatureProvider(dictionary: ["mel": MLFeatureValue(multiArray: mel)])
        var window = [Float](repeating: 0, count: contextFrames)
        var reconstructed = window, merged = window
        if let resumeFolder {
            let metadata = resumeFolder.appendingPathComponent("processing.txt")
            let identity = "\(resumeFolder.lastPathComponent)|\(OfflineAudioPipeline.cacheVersion)|\(AudioModel.lava)|\(amount)|\(source.length)|\(format.channelCount)"
            if FileManager.default.fileExists(atPath: resumeFolder.path),
               (try? String(contentsOf: metadata, encoding: .utf8)) != identity {
                try FileManager.default.removeItem(at: resumeFolder)
            }
            try FileManager.default.createDirectory(at: resumeFolder, withIntermediateDirectories: true)
            try identity.write(to: metadata, atomically: true, encoding: .utf8)
        }
        var position: Int64 = 0
        let thermal = AudioThermalGate()
        while position < source.length {
            try thermal.cooperate()
            let count = min(strideFrames, Int(source.length - position))
            let chunkURL = resumeFolder?.appendingPathComponent(String(position) + ".caf")
            if let chunkURL, let cached = try? AVAudioFile(forReading: chunkURL, commonFormat: .pcmFormatFloat32, interleaved: false),
               cached.length == Int64(count), cached.processingFormat.sampleRate == format.sampleRate,
               cached.processingFormat.channelCount == format.channelCount,
               (try? cached.read(into: rendered, frameCount: AVAudioFrameCount(count))) != nil, rendered.frameLength == count {
                try target.write(from: rendered); position += Int64(count)
                progress(Double(position) / Double(max(1, source.length))); continue
            }
            let start = position - Int64(margin)
            let readStart = max(0, start), readEnd = min(source.length, start + Int64(contextFrames))
            source.framePosition = readStart
            try source.read(into: buffer, frameCount: AVAudioFrameCount(max(0, readEnd - readStart)))
            for channel in 0..<Int(format.channelCount) {
                try Task.checkCancellation()
                // The built-in mono mic is stored as dual mono. Exact equality
                // permits reusing this independent window without changing a
                // sample; real stereo continues through separate predictions.
                if channel > 0 && memcmp(channels[0], channels[channel], Int(buffer.frameLength) * MemoryLayout<Float>.size) == 0 {
                    result[channel].update(from: result[0], count: count)
                    continue
                }
                for index in 0..<contextFrames {
                    var global = start + Int64(index)
                    // Reflection handles even one-sample recordings without an
                    // unbounded bounce loop. Grid stays aligned to 512 samples.
                    if source.length > 1 {
                        let period = 2 * (source.length - 1)
                        global = (global % period + period) % period
                        if global >= source.length { global = period - global }
                    } else { global = 0 }
                    let local = Int(global - readStart)
                    window[index] = local >= 0 && local < Int(buffer.frameLength) ? channels[channel][local] : 0
                }
                if window.allSatisfy({ abs($0) < 1e-8 }) {
                    for frame in 0..<count { result[channel][frame] = 0 }
                    continue
                }
                let melPointer = mel.dataPointer.assumingMemoryBound(to: Float.self)
                guard window.withUnsafeBufferPointer({ yr_lava_features($0.baseAddress, melPointer) }) == 1 else { throw AudioProcessingError.invalidFormat }
                // Core ML's Objective-C prediction and feature objects may
                // survive until the thread's autorelease pool drains. Bound
                // that lifetime to one channel/window, not an entire take.
                try autoreleasepool {
                let prediction = try model.prediction(from: provider)
                guard let real = prediction.featureValue(for: "real")?.multiArrayValue,
                      let imaginary = prediction.featureValue(for: "imaginary")?.multiArrayValue,
                      real.dataType == .float32, imaginary.dataType == .float32,
                      real.count == 1025 * 375, imaginary.count == real.count,
                      real.shape.map(\.intValue) == [1, 1025, 375], imaginary.shape == real.shape
                else { throw AudioProcessingError.invalidFormat }
                try Task.checkCancellation()
                // Core ML may pad rows (e.g. stride 384 for 375 values). Shape
                // does not imply contiguous storage, especially on the GPU.
                let packedReal = pack(real), packedImaginary = pack(imaginary)
                let ok = packedReal.withUnsafeBufferPointer { real in
                    packedImaginary.withUnsafeBufferPointer { imaginary in
                        reconstructed.withUnsafeMutableBufferPointer { yr_lava_reconstruct(real.baseAddress, imaginary.baseAddress, $0.baseAddress) }
                    }
                }
                guard ok == 1 else { throw AudioProcessingError.invalidFormat }
                let mixed = window.withUnsafeBufferPointer { dry in
                    reconstructed.withUnsafeBufferPointer { wet in
                        merged.withUnsafeMutableBufferPointer { yr_lava_merge(dry.baseAddress, wet.baseAddress, $0.baseAddress) }
                    }
                }
                guard mixed == 1 else { throw AudioProcessingError.invalidFormat }
                for frame in 0..<count {
                    let index = margin + frame
                    let value = window[index] + amount * (merged[index] - window[index])
                    guard value.isFinite else { throw AudioProcessingError.invalidFormat }
                    result[channel][frame] = value
                }
                }
            }
            rendered.frameLength = AVAudioFrameCount(count)
            try target.write(from: rendered)
            if let chunkURL {
                let partial = chunkURL.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".partial.caf")
                defer { try? FileManager.default.removeItem(at: partial) }
                // Close the chunk before publishing its immutable filename.
                do {
                    let chunk = try AVAudioFile(forWriting: partial, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                    try chunk.write(from: rendered)
                }
                do { try FileManager.default.moveItem(at: partial, to: chunkURL) }
                catch {
                    guard let existing = try? AVAudioFile(forReading: chunkURL), existing.length == Int64(count) else { throw error }
                }
            }
            position += Int64(count)
            progress(Double(position) / Double(max(1, source.length)))
        }
    }
    private static func pack(_ array: MLMultiArray) -> [Float] {
        let source = array.dataPointer.assumingMemoryBound(to: Float.self)
        let rowStride = array.strides[1].intValue, elementStride = array.strides[2].intValue
        var result = [Float](repeating: 0, count: 1025 * 375)
        result.withUnsafeMutableBufferPointer { destination in
            for row in 0..<1025 {
                if elementStride == 1 { destination.baseAddress!.advanced(by: row * 375).update(from: source.advanced(by: row * rowStride), count: 375) }
                else { for column in 0..<375 { destination[row * 375 + column] = source[row * rowStride + column * elementStride] } }
            }
        }
        return result
    }
}
