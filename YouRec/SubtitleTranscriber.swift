@preconcurrency import AVFoundation
import YouRecQwen

struct TranscriptionCheckpoint: Sendable {
    let range: ClosedRange<Double>
    let language: String
    let plan: [SubtitleSpeechChunk]
    let completed: Int
    let words: [SubtitleWord]
}

// AVAssetReader supports cancelling a read from another thread. The data
// output and scratch file stay confined to the extraction task.
private struct SubtitleAudioReadCancellation: @unchecked Sendable {
    let reader: AVAssetReader
    func cancel() { reader.cancelReading() }
}

actor SubtitleTranscriber {
    static let shared = SubtitleTranscriber()
    private var busy = false
    private var recentDecodingRate: Double? // wall seconds per second of audio on this device

    func transcribe(asset: AVAsset, mix: AVAudioMix?, range: ClosedRange<Double>, language: String,
                    resuming checkpoint: TranscriptionCheckpoint? = nil,
                    saveCheckpoint: @escaping @Sendable (TranscriptionCheckpoint) async -> Void = { _ in },
                    progress: @escaping @Sendable (Double, String) -> Void) async throws -> [SubtitleWord] {
        guard !busy else { throw SubtitleError.message("A transcription is already running.") }
        busy = true; defer { busy = false }
        guard SubtitleModelPack.installed else { throw SubtitleError.message("Download the speech model first.") }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("yourec-subtitles-" + UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: scratch) }
        progress(0, "Reading selected audio…")
        let levels = try await Self.extract(asset: asset, mix: mix, range: range, output: scratch) { progress(0.05 * $0, "Reading selected audio…") }
        try Task.checkCancellation()
        let chunks = SubtitleSpeechPlan.chunks(levels: levels, duration: range.upperBound - range.lowerBound)
        guard !chunks.isEmpty else { throw SubtitleError.message("No speech was detected in this range. Try a range with audible speech.") }
        progress(0.05, "Loading speech model…")
        // The actor serializes MLX access. No model is retained after this job,
        // including cancellation, and no service/network is used for inference.
        defer { Qwen3ASRModel.releaseCache() }
        var model: Qwen3ASRModel? = try Qwen3ASRModel.loadLocal(directory: SubtitleModelPack.directory)
        defer { model = nil }
        let file = try AVAudioFile(forReading: scratch)
        let resume = checkpoint.flatMap { saved in
            saved.range == range && saved.language == language && saved.plan == chunks ? saved : nil
        }
        if checkpoint != nil && resume == nil { progress(0.08, "Audio changed. Restarting transcription…") }
        var words = resume?.words ?? []
        let remaining = chunks.dropFirst(resume?.completed ?? 0)
        let totalAudio = remaining.reduce(0.0) { $0 + $1.range.upperBound - $1.range.lowerBound }
        let started = ProcessInfo.processInfo.systemUptime
        var decoded = 0.0
        for (index, chunk) in chunks.enumerated().dropFirst(resume?.completed ?? 0) {
            try Task.checkCancellation()
            let count = AVAudioFrameCount(max(1, ((chunk.range.upperBound - chunk.range.lowerBound) * 16000).rounded()))
            file.framePosition = AVAudioFramePosition((chunk.range.lowerBound * 16000).rounded())
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else { throw AudioProcessingError.invalidFormat }
            try file.read(into: buffer, frameCount: count)
            let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            var message = "Transcribing section \(index + 1) of \(chunks.count)"
            let rate = decoded > 0 ? (ProcessInfo.processInfo.systemUptime - started) / decoded : recentDecodingRate
            if let rate {
                let seconds = rate * max(0, totalAudio - decoded)
                let estimate = Duration.seconds(max(1, seconds.rounded())).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 1))
                message += " · about " + estimate + " left"
            } else { message += " · estimating time…" }
            progress(0.08 + 0.90 * Double(index) / Double(chunks.count), message)
            let text = try autoreleasepool {
                try model!.transcribeThrowing(audio: samples, sampleRate: 16000,
                    options: Qwen3DecodingOptions(maxTokens: 256, language: language == "Auto" ? nil : language))
            }
            try Task.checkCancellation()
            decoded += chunk.range.upperBound - chunk.range.lowerBound
            if decoded > 0 { recentDecodingRate = (ProcessInfo.processInfo.systemUptime - started) / decoded }
            let speech = chunk.speech.map { ($0.lowerBound + range.lowerBound)...($0.upperBound + range.lowerBound) }
            words += SubtitleTiming.estimate(text, speech: speech)
            await saveCheckpoint(TranscriptionCheckpoint(range: range, language: language, plan: chunks, completed: index + 1, words: words))
        }
        guard !words.isEmpty else { throw SubtitleError.message("The model did not find spoken words. Your previous subtitles are unchanged.") }
        progress(1, "Subtitles ready")
        return words
    }

    /// Read the actual edited mix, with its pitch-preserved speed changes and
    /// effects, into bounded disk storage. Reader PTS preserves gaps and offset.
    private static func extract(asset: AVAsset, mix: AVAudioMix?, range: ClosedRange<Double>, output: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [Float] {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw SubtitleError.message("This range has no audio.") }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: range.lowerBound, preferredTimescale: 16000), end: CMTime(seconds: range.upperBound, preferredTimescale: 16000))
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let sound = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
        sound.audioMix = mix; sound.audioTimePitchAlgorithm = .spectral; sound.alwaysCopiesSampleData = false
        guard reader.canAdd(sound) else { throw ProjectError.invalidMedia }; reader.add(sound)
        let file = try AVAudioFile(forWriting: output, settings: format.settings)
        guard reader.startReading() else { throw reader.error ?? ProjectError.invalidMedia }
        defer { reader.cancelReading() }
        let cancellation = SubtitleAudioReadCancellation(reader: reader)
        return try await withTaskCancellationHandler {
            let feedback = MediaProgress(progress)
            let limit = Int(((range.upperBound - range.lowerBound) * 16000).rounded())
            var written = 0, levels: [Float] = [], energy = 0.0, energyCount = 0
            func append(_ samples: [Float]) throws {
                guard !samples.isEmpty else { return }
                let count = min(samples.count, max(0, limit - written)); guard count > 0 else { return }
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!; buffer.frameLength = AVAudioFrameCount(count)
                for i in 0..<count {
                    let sample = samples[i].isFinite ? samples[i] : 0
                    buffer.floatChannelData![0][i] = sample
                    energy += Double(sample * sample); energyCount += 1
                    if energyCount == 320 { levels.append(Float(sqrt(energy / 320))); energy = 0; energyCount = 0 }
                }
                try file.write(from: buffer); written += count
                feedback.report(Double(written) / Double(max(1, limit)))
            }
            func pad(to count: Int) throws {
                while written < min(limit, count) { try Task.checkCancellation(); try append(Array(repeating: 0, count: min(16000, min(limit, count) - written))) }
            }
            while let sample = sound.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
                let size = CMBlockBufferGetDataLength(block)
                if size == 0 { continue }
                guard size % 4 == 0 else { throw ProjectError.invalidMedia }
                var values = [Float](repeating: 0, count: size / 4)
                let status = values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: $0.baseAddress!) }
                guard status == noErr else { throw ProjectError.invalidMedia }
                let offset = (sample.presentationTimeStamp.seconds - range.lowerBound) * 16000
                guard offset.isFinite else { throw ProjectError.invalidMedia }
                let position = Int(min(Double(limit), max(-Double(values.count), offset.rounded())))
                try pad(to: position)
                let skip = max(0, written - position)
                if skip < values.count { try append(Array(values.dropFirst(skip))) }
            }
            try Task.checkCancellation()
            guard reader.status == .completed else { throw reader.error ?? ProjectError.invalidMedia }
            try pad(to: limit)
            if energyCount > 0 { levels.append(Float(sqrt(energy / Double(energyCount)))) }
            return levels
        } onCancel: { cancellation.cancel() }
    }
}
