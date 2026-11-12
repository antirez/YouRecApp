import AVFoundation
import Accelerate
import Foundation

enum AudioProcessingError: LocalizedError {
    case unavailableModel, invalidFormat, deviceTooWarm
    var errorDescription: String? {
        switch self {
        case .unavailableModel: return "This project's audio model is unavailable. Bypass that stage to use the original audio."
        case .deviceTooWarm: return "Your device is too warm to continue processing. Let it cool, then try again. Completed source processing is kept."
        case .invalidFormat: return "The audio could not be processed at its expected sample rate."
        }
    }
}

/// Heavy audio work stays off the UI thread and yields under thermal pressure.
final class AudioThermalGate {
    private var checkedAt = -Double.infinity
    func cooperate() throws {
        try Task.checkCancellation()
        let now = ProcessInfo.processInfo.systemUptime
        guard now - checkedAt >= 0.2 else { return }
        checkedAt = now
        switch ProcessInfo.processInfo.thermalState {
        case .critical: throw AudioProcessingError.deviceTooWarm
        case .serious: Thread.sleep(forTimeInterval: 0.05)
        default: break
        }
    }
}

/// File-backed stages bound RAM independently of recording length. Each stage
/// consumes the previous stage's exact PCM output, including repeated models.
enum OfflineAudioPipeline {
    // Bump adapter/DSP revisions when processing math changes. Model weights
    // and their runtime versions are also encoded in each stage's settings.
    // OS build isolates Core ML backend changes, including resumed windows.
    static var cacheVersion: String {
        "source-audio-v3|rnnoise-adapter-1|dfn3-stream-cpu-1|eq-1|lava-dsp-1|cpuAndGPU|\(StudioVoiceProcessor.contextFrames):\(StudioVoiceProcessor.margin)|\(ProcessInfo.processInfo.operatingSystemVersionString)"
    }
    static func process(input: URL, effects: [AudioEffect], output: URL, checkpoints: [URL] = [],
                        progress: @escaping (Double) -> Void) throws -> Float {
        guard effects.filter(\.enabled).allSatisfy(\.supported) else { throw AudioProcessingError.unavailableModel }
        let active = effects.filter { $0.enabled && !($0.kind.isNeural && $0.amount == 0) }
        guard !FileManager.default.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteFileExists) }
        let inputFile = try AVAudioFile(forReading: input)
        var intermediates: [URL] = []
        defer { for file in intermediates { try? FileManager.default.removeItem(at: file) } }
        var current = input
        for (index, effect) in active.enumerated() {
            try Task.checkCancellation()
            let checkpoint = checkpoints.indices.contains(index) ? checkpoints[index] : nil
            if let checkpoint, let cached = try? AVAudioFile(forReading: checkpoint),
               cached.length == inputFile.length, cached.processingFormat.sampleRate == 48000,
               cached.processingFormat.channelCount == inputFile.processingFormat.channelCount,
               let text = try? String(contentsOf: checkpoint.deletingPathExtension().appendingPathExtension("peak"), encoding: .utf8),
               let peak = Float(text), peak.isFinite {
                if intermediates.contains(current) { try? FileManager.default.removeItem(at: current) }
                current = checkpoint; progress(Double(index + 1) / Double(max(1, active.count))); continue
            }
            let next = output.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".caf")
            intermediates.append(next)
            let report: (Double) -> Void = { progress((Double(index) + $0) / Double(max(1, active.count))) }
            if effect.kind == .voiceIsolation {
                if effect.model == .deepFilter {
                    try DeepFilterVoiceProcessor.process(input: current, output: next, amount: Float(effect.amount), progress: report)
                } else {
                    guard effect.model == .rnnoise else { throw AudioProcessingError.unavailableModel }
                    try denoise(input: current, output: next, amount: Float(effect.amount), progress: report)
                }
            } else if effect.kind == .studioVoice {
                guard effect.model == .lava else { throw AudioProcessingError.unavailableModel }
                try StudioVoiceProcessor.process(input: current, output: next, amount: Float(effect.amount), resumeFolder: checkpoint?.deletingPathExtension().appendingPathExtension("chunks"), progress: report)
            } else if effect.kind == .studioRestoration {
                guard effect.model == .voiceFixer else { throw AudioProcessingError.unavailableModel }
                try StudioRestorationProcessor.process(input: current, output: next, amount: Float(effect.amount), resumeFolder: checkpoint?.deletingPathExtension().appendingPathExtension("chunks"), progress: report)
            } else {
                try dsp(input: current, output: next, effect: effect, progress: report)
            }
            if intermediates.contains(current) { try? FileManager.default.removeItem(at: current) }
            if let checkpoint {
                let measured = try peak(of: next)
                do { try FileManager.default.moveItem(at: next, to: checkpoint) }
                catch {
                    // A different chain may have completed this same prefix.
                    // Never replace its immutable audio, including open players.
                    guard let existing = try? AVAudioFile(forReading: checkpoint),
                          existing.length == inputFile.length,
                          existing.processingFormat.channelCount == inputFile.processingFormat.channelCount else { throw error }
                }
                try String(measured).write(to: checkpoint.deletingPathExtension().appendingPathExtension("peak"), atomically: true, encoding: .utf8)
                // A fully committed stage supersedes its resumable windows.
                try? FileManager.default.removeItem(at: checkpoint.deletingPathExtension().appendingPathExtension("chunks"))
                current = checkpoint
            } else { current = next }
        }
        try Task.checkCancellation()
        let measuredPeak = try peak(of: current)
        try Task.checkCancellation()
        // copyItem refuses to overwrite; this also makes zero amount/bypass exact.
        if current == input || checkpoints.contains(current) { try FileManager.default.copyItem(at: current, to: output) }
        else { try FileManager.default.moveItem(at: current, to: output) }
        progress(1)
        return measuredPeak
    }

    private static func files(input: URL, output: URL) throws -> (AVAudioFile, AVAudioFile) {
        let source = try AVAudioFile(forReading: input, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = source.processingFormat
        guard format.sampleRate == 48000, format.channelCount > 0 else { throw AudioProcessingError.invalidFormat }
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        let target = try AVAudioFile(forWriting: output, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        return (source, target)
    }

    private static func dsp(input: URL, output: URL, effect: AudioEffect, progress: (Double) -> Void) throws {
        let (source, target) = try files(input: input, output: output)
        let channels = Int(source.processingFormat.channelCount)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 4096),
              let data = buffer.floatChannelData else { throw AudioProcessingError.invalidFormat }
        var processor = AudioChainProcessor(effects: [effect], channels: channels)
        let thermal = AudioThermalGate()
        while source.framePosition < source.length {
            try thermal.cooperate()
            try Task.checkCancellation()
            try source.read(into: buffer)
            guard buffer.frameLength > 0 else { throw AudioProcessingError.invalidFormat }
            for channel in 0..<channels {
                for frame in 0..<Int(buffer.frameLength) { data[channel][frame] = processor.sample(data[channel][frame], channel: channel) }
            }
            try target.write(from: buffer)
            progress(Double(source.framePosition) / Double(max(1, source.length)))
        }
    }

    private static func denoise(input: URL, output: URL, amount: Float, progress: (Double) -> Void) throws {
        let (source, target) = try files(input: input, output: output)
        let channels = Int(source.processingFormat.channelCount)
        let states = (0..<channels).map { _ in yr_denoiser_create() }
        defer { for state in states { yr_denoiser_destroy(state) } }
        guard states.allSatisfy({ $0 != nil }),
              let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 480),
              let result = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 480),
              let data = buffer.floatChannelData, let rendered = result.floatChannelData
        else { throw AudioProcessingError.invalidFormat }
        var previous = Array(repeating: [Float](repeating: 0, count: 480), count: channels)
        var previousCount = 0
        var wet = [Float](repeating: 0, count: 480)
        // The first model frame is latency. Feeding one final padded frame
        // drains the final real samples, including a partial (<480) input frame.
        let thermal = AudioThermalGate()
        while source.framePosition < source.length || previousCount > 0 {
            try thermal.cooperate()
            try Task.checkCancellation()
            for channel in 0..<channels { data[channel].initialize(repeating: 0, count: 480) }
            if source.framePosition < source.length { try source.read(into: buffer, frameCount: 480) }
            else { buffer.frameLength = 0 }
            let count = Int(buffer.frameLength)
            for channel in 0..<channels {
                wet.withUnsafeMutableBufferPointer { yr_denoiser_process(states[channel], data[channel], $0.baseAddress) }
                for frame in 0..<previousCount {
                    let dry = previous[channel][frame]
                    rendered[channel][frame] = dry + amount * (wet[frame] - dry)
                }
                for frame in 0..<480 { previous[channel][frame] = data[channel][frame] }
            }
            if previousCount > 0 {
                result.frameLength = AVAudioFrameCount(previousCount)
                try target.write(from: result)
            }
            previousCount = count
            progress(Double(source.framePosition) / Double(max(1, source.length)))
        }
    }

    static func peak(of url: URL) throws -> Float {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096),
              let data = buffer.floatChannelData else { throw AudioProcessingError.invalidFormat }
        var peak: Float = 0
        let thermal = AudioThermalGate()
        while file.framePosition < file.length {
            try thermal.cooperate()
            try Task.checkCancellation()
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { throw AudioProcessingError.invalidFormat }
            for channel in 0..<Int(file.processingFormat.channelCount) {
                for frame in 0..<Int(buffer.frameLength) {
                    guard data[channel][frame].isFinite else { throw AudioProcessingError.invalidFormat }
                    peak = max(peak, abs(data[channel][frame]))
                }
            }
        }
        return peak
    }
}


/// 400 ms energy windows for a speech-oriented, gated comparison. This is a
/// preview loudness estimate, not a claimed LUFS/EBU broadcast measurement.
struct SourceListeningLevels: Codable {
    let original: [Float]
    let processed: [Float]
    static let window = 0.4
    static func energies(_ url: URL) throws -> [Float] {
        let source = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(source.processingFormat.sampleRate * window)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: frames) else { throw AudioProcessingError.invalidFormat }
        var result: [Float] = []
        let thermal = AudioThermalGate()
        while source.framePosition < source.length {
            try thermal.cooperate()
            try Task.checkCancellation(); try source.read(into: buffer)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
            var sum: Float = 0
            for channel in 0..<Int(buffer.format.channelCount) {
                var value: Float = 0
                vDSP_svesq(channels[channel], 1, &value, vDSP_Length(buffer.frameLength)); sum += value
            }
            result.append(sum / Float(Int(buffer.frameLength) * Int(buffer.format.channelCount)))
        }
        return result
    }
    static func gains(clips: [TimelineClip], levels: [UUID: SourceListeningLevels]) -> (original: Float, processed: Float) {
        var windows: [(Float, Float, Double)] = []
        for clip in clips.flatMap(\.playbackPieces) {
            guard let level = levels[clip.sourceID] else { continue }
            for index in Int(clip.start / window)..<Int(ceil(clip.end / window)) {
                guard level.original.indices.contains(index), level.processed.indices.contains(index) else { continue }
                let weight = max(0, min(clip.end, Double(index + 1) * window) - max(clip.start, Double(index) * window))
                windows.append((level.original[index], level.processed[index], weight / clip.rate))
            }
        }
        return gains(windows: windows)
    }
    static func gains(windows: [(Float, Float, Double)]) -> (original: Float, processed: Float) {
        // Compare audio that survives in BOTH versions. Noise removed by a
        // denoiser is not a voice-level reference: matching it would attenuate
        // Original toward silence and hide the very difference being auditioned.
        // The -60 dBFS floor rejects near-silence; >20 dB reduction identifies
        // heavily suppressed windows. This is an energy gate, not a speech VAD.
        let audible = windows.filter { $0.0 > 0.000001 && $0.1 > 0.000001 && $0.1 >= $0.0 * 0.01 }
        let duration = audible.reduce(0) { $0 + $1.2 }
        guard duration > 0 else { return (1, 1) }
        let mean = audible.reduce(0) { $0 + Double($1.0) * $1.2 } / duration
        let processedMean = audible.reduce(0) { $0 + Double($1.1) * $1.2 } / duration
        let speech = audible.filter { Double($0.0) >= mean * 0.1 && Double($0.1) >= processedMean * 0.1 }
        let original = speech.reduce(0) { $0 + Double($1.0) * $1.2 }
        let processed = speech.reduce(0) { $0 + Double($1.1) * $1.2 }
        guard original > 0, processed > 0 else { return (1, 1) }
        let target = min(original, processed)
        return (Float(max(0.125, sqrt(target / original))), Float(max(0.125, sqrt(target / processed))))
    }
}

/// Comparison must never cancel an explicitly requested gain. Measurements
/// cover the actual audible mix in the inspector's range, including overlaps,
/// trims, track volume and other effects left active by Bypass.
enum AudioPreviewLevels {
    static func allowsMatching(_ effects: [AudioEffect]) -> Bool {
        !effects.contains { $0.enabled && $0.kind == .gain }
    }
    static func energies(asset: AVAsset, mix: AVAudioMix?, range: ClosedRange<Double>) async throws -> [Float] {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty, range.upperBound > range.lowerBound else { return [] }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: range.lowerBound, preferredTimescale: 48000), duration: CMTime(seconds: range.upperBound - range.lowerBound, preferredTimescale: 48000))
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false
        ])
        output.audioMix = mix; output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AudioProcessingError.invalidFormat }; reader.add(output)
        guard reader.startReading() else { throw reader.error ?? AudioProcessingError.invalidFormat }
        defer { if reader.status == .reading { reader.cancelReading() } }
        let window = Int(48000 * SourceListeningLevels.window) * 2
        var result: [Float] = [], energy = 0.0, count = 0
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let size = CMBlockBufferGetDataLength(block)
            guard size > 0 else { continue }
            guard size.isMultiple(of: MemoryLayout<Float>.size * 2) else { throw AudioProcessingError.invalidFormat }
            var values = [Float](repeating: 0, count: size / MemoryLayout<Float>.size)
            let status = values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: $0.baseAddress!) }
            guard status == kCMBlockBufferNoErr else { throw AudioProcessingError.invalidFormat }
            for value in values {
                guard value.isFinite else { throw AudioProcessingError.invalidFormat }
                energy += Double(value) * Double(value); count += 1
                if count == window { result.append(Float(energy / Double(count))); energy = 0; count = 0 }
            }
        }
        if reader.status == .failed { throw reader.error ?? AudioProcessingError.invalidFormat }
        if count > 0 { result.append(Float(energy / Double(count))) }
        return result
    }
    static func gains(original: [Float], processed: [Float]) -> (original: Float, processed: Float) {
        SourceListeningLevels.gains(windows: zip(original, processed).map { ($0, $1, SourceListeningLevels.window) })
    }
}
