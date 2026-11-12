import AVFoundation
import Foundation

struct OriginalRecording: Identifiable {
    var url: URL
    var source: SourceMedia?
    var id: URL { url }
    var title: String { source?.originalName ?? url.lastPathComponent }
}

extension ProjectDisk {
    /// Limit sharing and repair to real media in owned directories. Caches,
    /// LUT backgrounds, backups and working exports are separate namespaces.
    func originals(in id: UUID, project: Project?) -> [OriginalRecording] {
        let fm = FileManager.default
        let base = folder(id)
        func real(_ file: URL, directory: Bool) -> Bool {
            guard let v = try? file.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]),
                v.isSymbolicLink != true
            else { return false }
            return directory ? v.isDirectory == true : v.isRegularFile == true
        }
        guard real(base, directory: true) else { return [] }
        let sources = Dictionary((project?.sources ?? []).map { ($0.filename, $0) }, uniquingKeysWith: { a, _ in a })
        let media = Set(["mov", "mp4", "m4v", "m4a", "aac", "mp3", "wav", "aif", "aiff", "flac", "caf"])
        func list(_ directory: URL) -> [URL] {
            (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        }
        var result = list(base).compactMap { url -> OriginalRecording? in
            let source = sources[url.lastPathComponent]
            guard real(url, directory: false),
                source != nil
                    || (media.contains(url.pathExtension.lowercased())
                        && !url.lastPathComponent.lowercased().hasPrefix("effect-"))
            else { return nil }
            return OriginalRecording(url: url, source: source)
        }
        let recovery = base.appendingPathComponent("Recovery")
        if real(recovery, directory: true) {
            for dir in list(recovery) where real(dir, directory: true) {
                result += list(dir).filter { media.contains($0.pathExtension.lowercased()) && real($0, directory: false) }
                    .map { OriginalRecording(url: $0) }
            }
        }
        return result.sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
    }
}

enum RecordingSalvage {
    struct Media {
        let duration: Double
        let audioOnly: Bool
    }
    static func copyBudget(for url: URL) throws -> Int64 {
        let bytes = try RecoverySpace.size(url)
        return bytes + bytes / 10 + 1_048_576
    }
    static func clearUnpublishedCopies(in folder: URL) {
        let work = folder.appendingPathComponent(".repair-work")
        guard let values = try? work.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
            values.isDirectory == true, values.isSymbolicLink != true
        else { return }
        for url in (try? FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)) ?? [] {
            let key = url.deletingPathExtension().lastPathComponent
            if url.pathExtension == "mov", key.count == 64, key.allSatisfy(\.isHexDigit) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
    private static func scratch(for destination: URL) throws -> URL {
        let dir = destination.deletingLastPathComponent().appendingPathComponent(".repair-work")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let temp = dir.appendingPathComponent(RecoveryFile.hash(Data(destination.lastPathComponent.utf8)) + ".mov")
        // This path is exclusively the unpublished output for this destination.
        if FileManager.default.fileExists(atPath: temp.path) { try FileManager.default.removeItem(at: temp) }
        return temp
    }
    static func mediaFailure(_ error: Error) -> Bool {
        if case ProjectError.invalidMedia = error { return true }
        let e = error as NSError
        guard e.domain == AVFoundationErrorDomain else { return false }
        return [
            AVError.fileFormatNotRecognized, .fileFailedToParse, .invalidSourceMedia, .failedToParse, .decodeFailed,
            .noSourceTrack,
        ].contains(AVError.Code(rawValue: e.code))
    }
    static func inspect(_ url: URL) async throws -> Media {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, duration <= 604800 else { throw ProjectError.invalidMedia }
        let video = try await asset.loadTracks(withMediaType: .video).first
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        guard video != nil || audio != nil else { throw ProjectError.invalidMedia }
        for track in [video, audio].compactMap({ $0 }) {
            let span = try await track.load(.timeRange)
            guard span.isValid, span.duration.seconds.isFinite, span.duration.seconds > 0 else {
                throw ProjectError.invalidMedia
            }
            for offset in Set([0, max(0, span.duration.seconds - 0.40)]) {
                try Task.checkCancellation()
                let reader = try AVAssetReader(asset: asset)
                let settings: [String: Any] =
                    track.mediaType == .video
                    ? [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                    : [AVFormatIDKey: kAudioFormatLinearPCM]
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
                guard reader.canAdd(output) else { throw ProjectError.invalidMedia }
                reader.add(output)
                let start = span.start + CMTime(seconds: offset, preferredTimescale: 60000)
                reader.timeRange = CMTimeRange(start: start, end: span.end)
                guard reader.startReading(), let sample = output.copyNextSampleBuffer(),
                    CMSampleBufferGetNumSamples(sample) > 0
                else { throw reader.error ?? ProjectError.invalidMedia }
                reader.cancelReading()
            }
        }
        return Media(duration: duration, audioOnly: video == nil)
    }

    /// Find a complete prefix of an interrupted fragmented QuickTime file.
    /// A prefix needs its original initialization atom and closed movie fragments.
    /// Unknown or broken boxes terminate the scan. Never edit the source in place.
    static func completePrefix(_ input: FileHandle) throws -> UInt64? {
        let length = try input.seekToEnd()
        var offset: UInt64 = 0
        var boundary: UInt64 = 0
        var initialized = false
        var fragment = false
        while length - offset >= 8 {
            try Task.checkCancellation()
            try input.seek(toOffset: offset)
            let header = [UInt8](try input.read(upToCount: 16) ?? Data())
            guard header.count >= 8 else { break }
            func integer(_ bytes: ArraySlice<UInt8>) -> UInt64 { bytes.reduce(0) { $0 << 8 | UInt64($1) } }
            var size = integer(header[0..<4])
            let type = String(decoding: header[4..<8], as: UTF8.self)
            let extended = size == 1
            if extended {
                guard header.count == 16 else { break }
                size = integer(header[8..<16])
            }
            guard size >= (extended ? 16 : 8), size <= length - offset else { break }
            offset += size
            if type == "moov" { initialized = true }
            if type == "moof" { fragment = initialized }
            if type == "mdat", fragment {
                boundary = offset
                fragment = false
            }
        }
        return boundary > 0 && boundary < length ? boundary : nil
    }
    static func copyPlayablePrefix(_ url: URL, to destination: URL) async throws -> Media {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        guard let count = try completePrefix(input) else { throw ProjectError.invalidMedia }
        try input.seek(toOffset: 0)
        let temp = try scratch(for: destination)
        try Data().write(to: temp, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: temp) }
        let out = try FileHandle(forWritingTo: temp)
        defer { try? out.close() }
        var remaining = count
        while remaining > 0 {
            try Task.checkCancellation()
            guard let bytes = try input.read(upToCount: Int(min(remaining, 1_048_576))), !bytes.isEmpty else {
                throw ProjectError.invalidMedia
            }
            try out.write(contentsOf: bytes)
            remaining -= UInt64(bytes.count)
            if remaining % 16_777_216 < UInt64(bytes.count) {
                try RecoverySpace.require(0, at: temp.deletingLastPathComponent())
            }
        }
        try out.synchronize()
        let result = try await inspect(temp)
        try FileManager.default.moveItem(at: temp, to: destination)
        return result
    }
}

extension RecordingSalvage {
    /// For damaged tracks with a usable sample table, pass readable packets
    /// through to a fresh movie on their original timebase. A reader per track
    /// allows an intact sound track to survive a damaged picture track.
    static func repair(_ source: URL, to destination: URL) async throws -> Media {
        guard !FileManager.default.fileExists(atPath: destination.path) else { return try await inspect(destination) }
        let budget = try copyBudget(for: source)
        try RecoverySpace.require(budget, at: destination.deletingLastPathComponent())
        do { return try await copyPlayablePrefix(source, to: destination) } catch {
            if Task.isCancelled { throw CancellationError() }
            if (error as NSError).code == NSFileWriteOutOfSpaceError { throw error }
        }
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.load(.tracks).filter { $0.mediaType == .video || $0.mediaType == .audio }
        let temp = try scratch(for: destination)
        defer { try? FileManager.default.removeItem(at: temp) }
        let writer = try AVAssetWriter(outputURL: temp, fileType: .mov)
        struct Stream {
            let reader: AVAssetReader, output: AVAssetReaderTrackOutput, input: AVAssetWriterInput
            var next: CMSampleBuffer?
        }
        var streams: [Stream] = []
        for track in tracks {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            guard reader.canAdd(output) else { continue }
            reader.add(output)
            guard reader.startReading(), let first = output.copyNextSampleBuffer(), let format = first.formatDescription
            else { continue }
            let input = AVAssetWriterInput(mediaType: track.mediaType, outputSettings: nil, sourceFormatHint: format)
            if track.mediaType == .video { input.transform = try await track.load(.preferredTransform) }
            guard writer.canAdd(input) else {
                reader.cancelReading()
                continue
            }
            writer.add(input)
            streams.append(Stream(reader: reader, output: output, input: input, next: first))
        }
        defer {
            for stream in streams { stream.reader.cancelReading() }
            if writer.status == .writing { writer.cancelWriting() }
        }
        guard let first = streams.compactMap({ $0.next?.presentationTimeStamp }).min(), writer.startWriting() else {
            throw ProjectError.invalidMedia
        }
        writer.startSession(atSourceTime: first)
        var lastWrite = ContinuousClock.now
        var lastSpaceCheck = lastWrite
        while streams.contains(where: { $0.next != nil }) {
            try Task.checkCancellation()
            if ContinuousClock.now >= lastSpaceCheck + .seconds(1) {
                try RecoverySpace.require(0, at: temp.deletingLastPathComponent())
                if (try? RecoverySpace.size(temp)) ?? 0 > budget { throw CocoaError(.fileWriteOutOfSpace) }
                lastSpaceCheck = .now
            }
            guard writer.status == .writing else { throw writer.error ?? ProjectError.invalidMedia }
            guard
                let index = streams.indices.filter({ streams[$0].next != nil && streams[$0].input.isReadyForMoreMediaData })
                    .min(by: { streams[$0].next!.presentationTimeStamp < streams[$1].next!.presentationTimeStamp })
            else {
                guard ContinuousClock.now < lastWrite + .seconds(10) else { throw ProjectError.invalidMedia }
                try await Task.sleep(for: .milliseconds(3))
                continue
            }
            guard streams[index].input.append(streams[index].next!) else { throw writer.error ?? ProjectError.invalidMedia }
            streams[index].next = streams[index].output.copyNextSampleBuffer()
            if streams[index].next == nil { streams[index].input.markAsFinished() }
            lastWrite = .now
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ProjectError.invalidMedia }
        let media = try await inspect(temp)
        try FileManager.default.moveItem(at: temp, to: destination)
        return media
    }
}
