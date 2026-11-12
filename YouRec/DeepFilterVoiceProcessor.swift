import AVFoundation
import Foundation

/// Independent recurrent state per channel, bounded file-backed processing.
/// The engine drains its lookahead; dry mixing follows the output sample clock.
enum DeepFilterVoiceProcessor {
    static func process(input: URL, output: URL, amount: Float, progress: (Double) -> Void) throws {
        #if DEBUG || os(macOS)
        let override = ProcessInfo.processInfo.environment["YOUREC_DFN3_MODEL"].map { URL(fileURLWithPath: $0) }
        #else
        let override: URL? = nil
        #endif
        guard let directory = override ?? Bundle.main.resourceURL else { throw AudioProcessingError.unavailableModel }
        let source = try AVAudioFile(forReading: input, commonFormat: .pcmFormatFloat32, interleaved: false)
        let dry = try AVAudioFile(forReading: input, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = source.processingFormat, channels = Int(source.processingFormat.channelCount)
        guard format.sampleRate == 48000, (1...2).contains(channels), amount.isFinite, (0...1).contains(amount) else { throw AudioProcessingError.invalidFormat }
        let engines = try (0..<channels).map { _ -> DeepFilterNetEngine in
            try Task.checkCancellation()
            let engine = DeepFilterNetEngine(modelDirectory: directory)
            _ = try engine.prepare()
            return engine
        }
        var settings = format.settings; settings[AVLinearPCMIsNonInterleaved] = false
        let target = try AVAudioFile(forWriting: output, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480),
              let dryBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2048),
              let rendered = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2048) else { throw AudioProcessingError.invalidFormat }
        var written: Int64 = 0
        func write(_ samples: [[Float]]) throws {
            guard let first = samples.first, samples.allSatisfy({ $0.count == first.count }), first.count <= 2048 else { throw AudioProcessingError.invalidFormat }
            let count = min(first.count, Int(source.length - written))
            guard count > 0 else { return }
            try dry.read(into: dryBuffer, frameCount: AVAudioFrameCount(count))
            guard dryBuffer.frameLength == count else { throw AudioProcessingError.invalidFormat }
            rendered.frameLength = AVAudioFrameCount(count)
            for channel in 0..<channels {
                for frame in 0..<count {
                    let original = dryBuffer.floatChannelData![channel][frame], enhanced = samples[channel][frame]
                    let value = amount == 1 ? enhanced : original + amount * (enhanced - original)
                    guard value.isFinite else { throw AudioProcessingError.invalidFormat }
                    rendered.floatChannelData![channel][frame] = value
                }
            }
            try target.write(from: rendered); written += Int64(count)
        }
        let thermal = AudioThermalGate()
        while source.framePosition < source.length {
            try thermal.cooperate()
            try source.read(into: inputBuffer, frameCount: 480)
            guard inputBuffer.frameLength > 0 else { throw AudioProcessingError.invalidFormat }
            var output: [[Float]] = []
            for channel in 0..<channels {
                try Task.checkCancellation()
                var hop = [Float](repeating: 0, count: 480)
                for frame in 0..<Int(inputBuffer.frameLength) { hop[frame] = inputBuffer.floatChannelData![channel][frame] }
                output.append(try engines[channel].processHop(hop))
            }
            try write(output)
            progress(Double(source.framePosition) / Double(max(1, source.length)))
        }
        try Task.checkCancellation()
        try write(engines.map { try $0.flush() })
        guard written == source.length else { throw AudioProcessingError.invalidFormat }
    }
}
