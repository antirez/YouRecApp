@preconcurrency import AVFoundation
import Foundation

/// Only completed stages are published here. An interrupted encoder always writes to Processing.
struct ExportCheckpoint {
    private struct Ticket: Codable, Equatable {
        let projectID: UUID
        let revision: Date
        let historyCursor: Int
        let settings: ExportSettings?

        init(_ project: Project) {
            projectID = project.id
            revision = project.updatedAt
            historyCursor = project.historyCursor
            // Build 161 checkpoints used the default export format.
            settings = project.exportSettings == ExportSettings() ? nil : project.exportSettings
        }
    }

    let directory: URL
    private var ticketURL: URL { directory.appendingPathComponent("ticket.json") }
    private static let sectionSeconds = 12

    init(folder: URL) {
        directory = folder.appendingPathComponent("Exports/.paused-export", isDirectory: true)
    }

    func matches(_ project: Project) -> Bool {
        guard let data = try? Data(contentsOf: ticketURL),
              let ticket = try? JSONDecoder().decode(Ticket.self, from: data) else { return false }
        return ticket == Ticket(project)
    }

    func prepare(_ project: Project) throws {
        if matches(project) { return }
        try discard()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        try JSONEncoder().encode(Ticket(project)).write(to: ticketURL, options: .atomic)
    }

    private var pauseReasonURL: URL { directory.appendingPathComponent("pause-reason.txt") }
    var pauseReason: String? { try? String(contentsOf: pauseReasonURL, encoding: .utf8) }
    func setPauseReason(_ reason: String?) {
        if let reason { try? reason.write(to: pauseReasonURL, atomically: true, encoding: .utf8) }
        else { try? FileManager.default.removeItem(at: pauseReasonURL) }
    }
    func discard() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    /// Move finished sections out of the resumable slot on the same volume. A
    /// new export can then use the slot while the old files are being unlinked.
    func detachCompletedFiles() throws -> URL {
        let folder = directory.deletingLastPathComponent().deletingLastPathComponent()
        let scratch = folder.appendingPathComponent("Processing", isDirectory: true)
        let retired = scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.moveItem(at: directory, to: retired)
        return retired
    }

    var measuredPeak: Float? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("peak.json")) else { return nil }
        return try? JSONDecoder().decode(Float.self, from: data)
    }

    func savePeak(_ peak: Float) throws {
        try JSONEncoder().encode(peak).write(to: directory.appendingPathComponent("peak.json"), options: .atomic)
    }

    private func section(_ index: Int) -> URL { directory.appendingPathComponent("picture-\(index).mp4") }

    func savedSeconds(total: Double) -> Double {
        var index = 0
        while Double(index * Self.sectionSeconds) < total && FileManager.default.fileExists(atPath: section(index).path) {
            index += 1
        }
        return min(total, Double(index * Self.sectionSeconds))
    }

    func startingProgress(total: Double) -> ExportProgress {
        guard total > 0 else { return ExportProgress(.opening) }
        let saved = savedSeconds(total: total)
        if saved > 0 { return ExportProgress(resumingAfter: ExportProgress(.picture, saved / total)) }
        if FileManager.default.fileExists(atPath: audioFile.path) { return ExportProgress(resumingAfter: ExportProgress(.audio, 1)) }
        if measuredPeak != nil { return ExportProgress(resumingAfter: ExportProgress(.audioPeak, 1)) }
        return ExportProgress(.opening)
    }

    private var audioFile: URL { directory.appendingPathComponent("sound.mp4") }

    func render(_ media: TimelineMedia, duration: CMTime, scratch: URL, output: URL, codec: ExportSettings.Codec, progress: @escaping @Sendable (ExportProgress) -> Void) async throws {
        let fullRange = CMTimeRange(start: .zero, duration: duration)
        let hasAudio = !media.composition.tracks(withMediaType: .audio).isEmpty

        // Encode the complete mix once so AAC priming, music and dialogue stay continuous across picture sections.
        if hasAudio && !FileManager.default.fileExists(atPath: audioFile.path) {
            try RecoverySpace.require(Int64(duration.seconds * 32_000) + 2_000_000, at: directory)
            progress(ExportProgress(.audio))
            let audio = try composition(media.composition, keeping: .audio, duration: duration)
            try await stage(to: audioFile, scratch: scratch, asset: audio, preset: AVAssetExportPresetHighestQuality,
                            type: .mp4, range: fullRange, audioMix: media.audioMix) { progress(ExportProgress(.audio, $0)) }
        }
        try Task.checkCancellation()
        let video = try composition(media.composition, keeping: .video, duration: duration)
        var sections: [URL] = []
        let step = CMTime(value: Int64(Self.sectionSeconds), timescale: 1)
        progress(ExportProgress(.picture, savedSeconds(total: duration.seconds) / duration.seconds))
        var start = CMTime.zero
        var index = 0
        while start < duration {
            try Task.checkCancellation()
            let length = CMTimeMinimum(step, duration - start)
            let file = section(index)
            if FileManager.default.fileExists(atPath: file.path),
               try await !hasCompletePictureClock(file, length: length, frame: media.videoComposition.frameDuration) {
                // A paused export made by an earlier build may end a section
                // at its last source frame. Rebuild just that cached section.
                try Task.checkCancellation()
                try FileManager.default.removeItem(at: file)
            }
            if !FileManager.default.fileExists(atPath: file.path) {
                let pixels = media.videoComposition.renderSize.width * media.videoComposition.renderSize.height
                try RecoverySpace.require(Int64(pixels * length.seconds) + 2_000_000, at: directory)
                let offset = start.seconds
                try await stage(to: file, scratch: scratch, asset: video,
                                preset: codec == .hevc ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality,
                                type: .mp4, range: CMTimeRange(start: start, duration: length), videoComposition: media.videoComposition) { value in
                    progress(ExportProgress(.picture, (offset + value * length.seconds) / duration.seconds))
                }
            }
            sections.append(file)
            start = start + length
            index += 1
            progress(ExportProgress(.picture, start.seconds / duration.seconds))
        }
        let parts = hasAudio ? sections + [audioFile] : sections
        let total = try parts.reduce(Int64(0)) { try $0 + RecoverySpace.size($1) }
        try RecoverySpace.require(total + total / 50 + 2_000_000, at: directory)
        try await join(sections, audio: hasAudio ? audioFile : nil, duration: duration,
                       frameDuration: media.videoComposition.frameDuration, to: output, progress: progress)
    }

    private func hasCompletePictureClock(_ file: URL, length: CMTime, frame: CMTime) async throws -> Bool {
        let source = try await CompressedTrack(file, type: .video)
        let reader = try AVAssetReader(asset: source.asset)
        // Sample references read the movie index without decoding or copying pictures.
        let output = AVAssetReaderSampleReferenceOutput(track: source.track)
        guard reader.canAdd(output) else { throw ProjectError.invalidMedia }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ProjectError.invalidMedia }
        defer { reader.cancelReading() }
        var pictures: Int32 = 0
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            if sample.totalSampleSize > 0 { pictures += Int32(sample.numSamples) }
        }
        guard reader.status == .completed else { throw reader.error ?? ProjectError.invalidMedia }
        let covered = CMTimeMultiply(frame, multiplier: pictures)
        return covered >= length && covered - frame < length
    }

    // A passthrough export of a composition of independently encoded GOPs inserts
    // decoder preroll at each join. Pictures play on time, but the MP4 sample
    // table can advertise e.g. 29.77 fps for a 30 fps movie. Give compressed
    // pictures one uninterrupted decode clock, preserving presentation order.
    private func join(_ files: [URL], audio: URL?, duration: CMTime, frameDuration: CMTime, to output: URL,
                      progress: @escaping @Sendable (ExportProgress) -> Void) async throws {
        let step: ExportProgress.Step = audio == nil ? .assembleVideo : .assembleMovie
        let assembly = MediaProgress { progress(ExportProgress(step, $0)) }
        assembly.report(0)
        var reorderDelay = CMTime.zero
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            let track = try await CompressedTrack(file, type: .video)
            let (reader, stream) = try track.stream()
            defer { reader.cancelReading() }
            guard let sample = nextPicture(stream) else { throw reader.error ?? ProjectError.invalidMedia }
            if sample.decodeTimeStamp.isNumeric {
                reorderDelay = max(reorderDelay, sample.presentationTimeStamp - sample.decodeTimeStamp)
            }
            assembly.report(0.05 * Double(index + 1) / Double(files.count))
        }
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        writer.movieTimeScale = 60000
        func input(_ track: AVAssetTrack) async throws -> AVAssetWriterInput {
            guard let format = try await track.load(.formatDescriptions).first else { throw ProjectError.invalidMedia }
            let input = AVAssetWriterInput(mediaType: track.mediaType, outputSettings: nil, sourceFormatHint: format)
            guard writer.canAdd(input) else { throw ProjectError.invalidMedia }
            writer.add(input)
            return input
        }
        guard let file = files.first else { throw ProjectError.emptyTimeline }
        let first = try await CompressedTrack(file, type: .video)
        let picture = try await input(first.track)
        picture.mediaTimeScale = 60000
        var sound: (CompressedTrack, AVAssetWriterInput)?
        if let audio {
            let track = try await CompressedTrack(audio, type: .audio)
            sound = (track, try await input(track.track))
        }
        guard writer.startWriting() else { throw writer.error ?? ProjectError.invalidMedia }
        writer.startSession(atSourceTime: .zero)
        defer { if writer.status == .writing { writer.cancelWriting() } }
        let delay = reorderDelay
        try await withThrowingTaskGroup(of: Void.self) { group in
            if let (track, input) = sound {
                group.addTask {
                    let (reader, stream) = try track.stream()
                    defer { reader.cancelReading() }
                    // Forward all AAC timing markers, including priming and leading silence.
                    while let sample = stream.copyNextSampleBuffer() {
                        try await append(sample, to: input, writer: writer)
                    }
                    guard reader.status == .completed else { throw reader.error ?? ProjectError.invalidMedia }
                    input.markAsFinished()
                }
            }
            group.addTask {
                try await appendPictures(files, duration: duration, frameDuration: frameDuration,
                                         delay: delay, to: picture, writer: writer) { assembly.report(0.05 + 0.95 * $0) }
                picture.markAsFinished()
            }
            while try await group.next() != nil {}
        }
        try Task.checkCancellation()
        progress(ExportProgress(.movieIndex))
        writer.endSession(atSourceTime: duration)
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ProjectError.invalidMedia }
    }

    private func appendPictures(_ files: [URL], duration: CMTime, frameDuration: CMTime, delay: CMTime,
                                to picture: AVAssetWriterInput, writer: AVAssetWriter, progress: (Double) -> Void) async throws {
        let frameCount = duration.seconds / frameDuration.seconds
        var decoded = 0
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            let track = try await CompressedTrack(file, type: .video)
            let start = CMTime(value: Int64(index * Self.sectionSeconds), timescale: 1)
            let length = min(duration - start, CMTime(value: Int64(Self.sectionSeconds), timescale: 1))
            let (reader, stream) = try track.stream()
            defer { reader.cancelReading() }
            var firstPTS: CMTime?
            var pictures = 0
            while let sample = nextPicture(stream) {
                let origin = firstPTS ?? sample.presentationTimeStamp
                firstPTS = origin
                var timing = CMSampleTimingInfo(duration: frameDuration,
                    presentationTimeStamp: start + sample.presentationTimeStamp - origin,
                    decodeTimeStamp: CMTimeMultiply(frameDuration, multiplier: Int32(decoded)) - delay)
                var retimed: CMSampleBuffer?
                guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample,
                    sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &retimed) == noErr,
                      let retimed else { throw ProjectError.invalidMedia }
                // Section-local edit lists served their purpose during reading.
                CMRemoveAttachment(retimed, key: kCMSampleBufferAttachmentKey_TrimDurationAtStart)
                CMRemoveAttachment(retimed, key: kCMSampleBufferAttachmentKey_TrimDurationAtEnd)
                try await append(retimed, to: picture, writer: writer)
                pictures += 1
                decoded += 1
                if decoded.isMultiple(of: 16) { progress(Double(decoded) / frameCount) }
            }
            guard reader.status == .completed else { throw reader.error ?? ProjectError.invalidMedia }
            let covered = CMTimeMultiply(frameDuration, multiplier: Int32(pictures))
            guard pictures > 0, covered >= length - frameDuration,
                  index == files.count - 1 || covered == length else { throw ProjectError.invalidMedia }
        }
    }

    private struct CompressedTrack {
        let asset: AVURLAsset
        let track: AVAssetTrack

        init(_ file: URL, type: AVMediaType) async throws {
            asset = AVURLAsset(url: file)
            guard let track = try await asset.loadTracks(withMediaType: type).first else { throw ProjectError.invalidMedia }
            self.track = track
        }

        func stream() throws -> (AVAssetReader, AVAssetReaderTrackOutput) {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw ProjectError.invalidMedia }
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? ProjectError.invalidMedia }
            return (reader, output)
        }
    }

    private func nextPicture(_ stream: AVAssetReaderTrackOutput) -> CMSampleBuffer? {
        // Zero-sample buffers describe a section's edit list, not compressed pictures.
        while let sample = stream.copyNextSampleBuffer() {
            if sample.numSamples > 0 { return sample }
        }
        return nil
    }

    private func append(_ sample: CMSampleBuffer, to input: AVAssetWriterInput, writer: AVAssetWriter) async throws {
        try Task.checkCancellation()
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing else { throw writer.error ?? ProjectError.invalidMedia }
            try await Task.sleep(for: .milliseconds(2))
        }
        guard input.append(sample) else { throw writer.error ?? ProjectError.invalidMedia }
    }

    private func composition(_ input: AVMutableComposition, keeping type: AVMediaType, duration: CMTime) throws -> AVMutableComposition {
        guard let copy = input.mutableCopy() as? AVMutableComposition else { throw ProjectError.invalidMedia }
        for track in copy.tracks where track.mediaType != type { copy.removeTrack(track) }
        let end = copy.duration
        if end < duration { copy.insertEmptyTimeRange(CMTimeRange(start: end, duration: duration - end)) }
        return copy
    }

    private func stage(to destination: URL, scratch: URL, asset: AVAsset, preset: String, type: AVFileType,
                       range: CMTimeRange, videoComposition: AVVideoComposition? = nil, audioMix: AVAudioMix? = nil,
                       progress: @escaping @Sendable (Double) -> Void) async throws {
        let partial = scratch.appendingPathComponent(UUID().uuidString).appendingPathExtension(destination.pathExtension)
        defer { try? FileManager.default.removeItem(at: partial) }
        try await MediaRenderer.encode(asset, preset: preset, to: partial, type: type, range: range, videoComposition: videoComposition, audioMix: audioMix, progress: progress)
        try FileManager.default.moveItem(at: partial, to: destination)
    }
}
