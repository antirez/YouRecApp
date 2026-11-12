@preconcurrency import AVFoundation
import CryptoKit
import Foundation

struct SourceWaveform: Codable, Sendable {
    let duration: Double
    let peaks: [Float]
    var rms: [Float]? = nil // Older peak-only waveform caches are still usable by the timeline.
    var speech: Data? = nil // One quantized RNNoise probability per 10 ms bin, generated for Pauses only.
    func peak(at time: Double) -> Float {
        guard !peaks.isEmpty, time >= 0, time < duration else { return 0 }
        return peaks[min(peaks.count - 1, Int(time / duration * Double(peaks.count)))]
    }
}

struct PreparedTimeline {
    enum Step { case audioEffects, timeline }
    let media: TimelineMedia
    let peak: Float
    let lease: SourceCacheLease?
    let listeningGains: (original: Float, processed: Float)
    let processedSources: [UUID: URL]
    let processedRegions: [String: URL]
    init(media: TimelineMedia, peak: Float, lease: SourceCacheLease? = nil, listeningGains: (original: Float, processed: Float) = (1, 1), processedSources: [UUID: URL] = [:], processedRegions: [String: URL] = [:]) {
        self.media = media; self.peak = peak; self.lease = lease; self.listeningGains = listeningGains; self.processedSources = processedSources; self.processedRegions = processedRegions
    }
}

struct AudioPreviewWindow {
    let range: ClosedRange<Double>
    let url: URL
    static func listeningRange(at position: Double, selection: ClosedRange<Double>) -> ClosedRange<Double> {
        EffectPreviewWindow.range(at: position, within: selection)
    }
}

final class SourceCacheLease: @unchecked Sendable {
    private let files: [URL]
    private let parents: [SourceCacheLease]
    init(_ files: [URL], parents: [SourceCacheLease] = []) { self.files = files; self.parents = parents }
    deinit {
        let released = files
        Task { await SourceMediaCache.shared.release(released) }
    }
}

// Each cached AI result is computed in the original source's time domain.
// Trims/reorders reuse it without resetting the model or mixing context across cuts.
actor SourceMediaCache {
    static let shared = SourceMediaCache()
    private var fingerprints: [String: String] = [:]
    private var waves: [String: SourceWaveform] = [:]
    private var pins: [URL: Int] = [:]
    private var initializedFolders = Set<URL>()
    private var projectRoots = Set<URL>()
    private var building = Set<URL>()
    private var lastPrune = -Double.infinity
    func release(_ files: [URL]) {
        for file in files {
            if let count = pins[file], count > 1 { pins[file] = count - 1 } else { pins[file] = nil }
        }
        for folder in Set(files.map { $0.deletingLastPathComponent() }) { try? prune(folder, reserving: 0) }
    }
    private func pin(_ url: URL) {
        pins[url, default: 0] += 1
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }
    private func prune(_ folder: URL, reserving required: Int64) throws {
        // Releasing an audition lease must not repeatedly walk every cache.
        let now = ProcessInfo.processInfo.systemUptime
        if required == 0 && now - lastPrune < 15 { return }
        lastPrune = now
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        var cacheFolders: Set<URL> = [folder]
        for root in projectRoots {
            for project in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                let cache = ProjectCacheLocation.root(in:project)
                if FileManager.default.fileExists(atPath: cache.path) { cacheFolders.insert(cache) }
            }
        }
        var files: [URL] = []
        for cache in cacheFolders {
            let contents = (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: Array(keys))) ?? []
            files.append(contentsOf: contents.filter { ["caf", "chunks"].contains($0.pathExtension) && $0.deletingPathExtension().lastPathComponent.count == 64 })
        }
        var records: [(URL, Int64, Date, Int)] = []
        for file in files {
            let info = try file.resourceValues(forKeys: keys)
            var bytes = Int64(info.fileSize ?? 0)
            if file.pathExtension == "chunks" {
                bytes = 0
                for child in (try? FileManager.default.contentsOfDirectory(at: file, includingPropertiesForKeys: [.fileSizeKey])) ?? [] {
                    bytes += Int64((try? child.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                }
            }
            let priorityURL = file.deletingPathExtension().appendingPathExtension("priority")
            let priority = (try? String(contentsOf: priorityURL, encoding: .utf8)).flatMap(Int.init) ?? 0
            records.append((file, bytes, info.contentModificationDate ?? .distantPast, priority))
        }
        var total = records.reduce(Int64(0)) { $0 + $1.1 }
        let filesystemAvailable = (try FileManager.default.attributesOfFileSystem(forPath: folder.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? Int64.max
        // Some macOS volumes return zero for this optional estimate even with
        // ample free space. Actual free bytes remain usable in that case.
        let reclaimable = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? 0
        var available = max(filesystemAvailable, reclaimable)
        // Long sources need several gigabytes of reusable neural stages.
        // Scale within 2–8 GB, bounded by a tenth of reclaimable space.
        let quota = max(Int64(2_000_000_000), min(8_000_000_000, available / 10 + total / 10))
        for (url, bytes, _, _) in records.sorted(by: { $0.3 == $1.3 ? $0.2 < $1.2 : $0.3 < $1.3 }) where pins[url] == nil && pins[url.deletingPathExtension().appendingPathExtension("caf")] == nil {
            if total <= quota && available >= required + 256_000_000 { break }
            try FileManager.default.removeItem(at: url)
            // A stale chunk directory can coexist with its committed CAF after
            // a crash. Removing it must not invalidate the CAF's metadata.
            if url.pathExtension == "caf" || !FileManager.default.fileExists(atPath: url.deletingPathExtension().appendingPathExtension("caf").path) {
                for extensionName in ["peak", "levels.json", "priority"] {
                    try? FileManager.default.removeItem(at: url.deletingPathExtension().appendingPathExtension(extensionName))
                }
            }
            total -= bytes; available += bytes
        }
        guard available >= required + 256_000_000 else {
            throw NSError(domain: "SourceMediaCache", code: 1, userInfo: [NSLocalizedDescriptionKey: "There is not enough free space to process this take. Free some storage and try again."])
        }
    }

    func fingerprint(_ url: URL, memoize: Bool = true, progress: (@Sendable (Double) -> Void)? = nil) async throws -> String {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let identity = "\(url.path)|\(values.fileSize ?? 0)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        if memoize, let existing = fingerprints[identity] { return existing }
        let memoFolder = url.deletingLastPathComponent().appendingPathComponent("Cache/Fingerprints", isDirectory: true)
        let memoKey = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let memo = memoFolder.appendingPathComponent(memoKey)
        if memoize, let value = try? String(contentsOf: memo, encoding: .utf8), value.count == 64,
           value.allSatisfy({ $0.isHexDigit }) {
            fingerprints[identity] = value; return value
        }
        let fileSize = Double(max(1, values.fileSize ?? 0))
        let feedback = progress.map(MediaProgress.init)
        let task = Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hash = SHA256()
            var bytesRead = 0
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                try Task.checkCancellation(); hash.update(data: data)
                bytesRead += data.count
                feedback?.report(Double(bytesRead) / fileSize)
            }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        let result = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
        if memoize {
            fingerprints[identity] = result
            // Caching a successfully computed hash is optional, especially
            // while finalizing a recording on a nearly full volume.
            try? FileManager.default.createDirectory(at: memoFolder, withIntermediateDirectories: true)
            try? result.write(to: memo, atomically: true, encoding: .utf8)
        }
        return result
    }
    private func cacheFolder(_ folder: URL) throws -> URL {
        let cache = ProjectCacheLocation.root(in:folder)
        projectRoots.insert(folder.deletingLastPathComponent())
        projectRoots.insert(ProjectDisk(root: folder.deletingLastPathComponent()).deletedRoot)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        if initializedFolders.insert(cache).inserted {
            // Only crash leftovers from our scratch naming scheme are removed.
            for file in (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? [] {
                if file.pathExtension == "chunks" {
                    for child in (try? FileManager.default.contentsOfDirectory(at: file, includingPropertiesForKeys: nil)) ?? [] where child.lastPathComponent.hasSuffix(".partial.caf") {
                        try? FileManager.default.removeItem(at: child)
                    }
                }
                if (file.pathExtension == "studio-work" && UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil) || file.lastPathComponent.hasSuffix(".working.caf") || (file.pathExtension == "caf" && UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil) {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
        var excluded = cache
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
        return cache
    }
    func waveform(source: SourceMedia, folder: URL, processed: URL? = nil, needsRMS: Bool = false, needsSpeech: Bool = false,
                  progress: (@Sendable (Double) -> Void)? = nil) async throws -> SourceWaveform {
        let url = processed ?? folder.appendingPathComponent(source.filename)
        let key = try await fingerprint(url) + "-wave-v2"
        func usable(_ wave: SourceWaveform) -> Bool {
            wave.duration == source.duration && (!needsRMS || wave.rms?.count == wave.peaks.count)
                && (!needsSpeech || wave.speech?.count == wave.peaks.count)
        }
        if let wave = waves[key], usable(wave) { return wave }
        let destination = try cacheFolder(folder).appendingPathComponent(key + ".json")
        if let data = try? Data(contentsOf: destination),
           let wave = try? JSONDecoder().decode(SourceWaveform.self, from: data),
           usable(wave), wave.peaks.allSatisfy({ $0.isFinite && $0 >= 0 }),
           wave.rms.map({ $0.count == wave.peaks.count && $0.allSatisfy { $0.isFinite && $0 >= 0 } }) ?? true {
            waves[key] = wave; return wave
        }
        // 10 ms bins support silence placement even when zoomed to frame level.
        let wave = try await MediaRenderer.waveform(asset: AVURLAsset(url: url), duration: source.duration,
                                                    bins: max(1, Int(ceil(source.duration * 100))), measureSpeech: needsSpeech, progress: progress)
        // A concurrent timeline drawing request must never overwrite a completed speech scan.
        if let existing = waves[key], usable(existing), existing.speech != nil { return existing }
        try JSONEncoder().encode(wave).write(to: destination, options: .atomic)
        if waves.count >= 12 { waves.removeAll() }
        waves[key] = wave
        return wave
    }
    private func listeningLevels(source: URL, duration: Double, processed: URL, decodedOriginal: URL? = nil) async throws -> SourceListeningLevels {
        let metadata = processed.deletingPathExtension().appendingPathExtension("levels.json")
        let expected = Int(ceil(duration / SourceListeningLevels.window))
        if let data = try? Data(contentsOf: metadata), let value = try? JSONDecoder().decode(SourceListeningLevels.self, from: data),
           value.original.count == expected, value.processed.count == expected,
           (value.original + value.processed).allSatisfy({ $0.isFinite && $0 >= 0 }) { return value }
        let raw = decodedOriginal ?? processed.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".working.caf")
        defer { if decodedOriginal == nil { try? FileManager.default.removeItem(at: raw) } }
        if decodedOriginal == nil {
            _ = try await MediaRenderer.processedAudio(asset: AVURLAsset(url: source), duration: duration, effects: [], outputURL: raw) { _ in }
        }
        let task = Task.detached(priority: .utility) {
            SourceListeningLevels(original: try SourceListeningLevels.energies(raw), processed: try SourceListeningLevels.energies(processed))
        }
        let result = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
        try JSONEncoder().encode(result).write(to: metadata, options: .atomic)
        return result
    }
    func prepared(project: Project, folder: URL, canvasSize: CGSize? = nil, framesPerSecond: Int = 30, effectPreparation: VideoEffectPreparation = .final, audioPreviewRange: ClosedRange<Double>? = nil, progress: @escaping @Sendable (Double) -> Void) async throws -> PreparedTimeline {
        if let audioPreviewRange {
            let sample = EffectPreviewWindow(audioPreviewRange, timeline: project.edit.timeline)
            return try await VideoEffectPreparation.$inspectionWindow.withValue(sample) {
                try await preparedPreview(project: project, folder: folder, range: audioPreviewRange, progress: progress)
            }
        }
        return try await preparedTimeline(project: project, folder: folder, canvasSize: canvasSize, framesPerSecond: framesPerSecond,
                                          effectPreparation: effectPreparation) { _, value in progress(value) }
    }

    func preparedTimeline(project: Project, folder: URL, canvasSize: CGSize?, framesPerSecond: Int,
                          effectPreparation: VideoEffectPreparation = .final,
                          progress: @escaping @Sendable (PreparedTimeline.Step, Double) -> Void) async throws -> PreparedTimeline {
        var requests: [String: (SourceMedia, [AudioEffect])] = [:]
        for item in project.edit.timeline.audio {
            guard let source = project.sources.first(where: { $0.id == item.sourceID }) else { throw ProjectError.missingMedia }
            for region in item.enhancements where region.effects.contains(where: { $0.enabled }) {
                requests[TrackRenderer.audioKey(source: source.id, effects: region.effects)] = (source, region.effects)
            }
        }
        guard !requests.isEmpty else {
            progress(.timeline, 0)
            return PreparedTimeline(media: try await MediaRenderer.timeline(project: project, folder: folder, canvasSize: canvasSize, framesPerSecond: framesPerSecond, videoProgress: { progress(.timeline, $0) }, effectPreparation: effectPreparation), peak: 0)
        }
        progress(.audioEffects, 0)
        var files: [String: URL] = [:], leases: [SourceCacheLease] = []
        var peak: Float = 0
        for (index, key) in requests.keys.sorted().enumerated() {
            try Task.checkCancellation()
            let (source, effects) = requests[key]!
            var sourceProject = project
            sourceProject.sources = [source]
            sourceProject.history = [EditState(clips: [TimelineClip(sourceID: source.id, start: 0, end: source.duration)], effects: effects)]
            sourceProject.historyCursor = 0
            let part = try await preparedUniform(project: sourceProject, folder: folder, effectPreparation: .cached) { value in
                progress(.audioEffects, 0.85 * (Double(index) + value) / Double(requests.count))
            }
            files[key] = part.processedSources[source.id]
            if let lease = part.lease { leases.append(lease) }
            peak = max(peak, part.peak)
        }
        var comparison: [(Float, Float, Double)] = []
        for item in project.edit.timeline.audio where !item.muted {
            for region in item.enhancements {
                let key = TrackRenderer.audioKey(source: item.sourceID, effects: region.effects)
                guard let file = files[key], let source = project.sources.first(where: { $0.id == item.sourceID }) else { continue }
                let levels = try await listeningLevels(source: folder.appendingPathComponent(source.filename), duration: source.duration, processed: file)
                for run in item.mapping.sliced(region.interval).runs where !run.silent && !run.isHold {
                    for index in Int(run.sourceStart / SourceListeningLevels.window)..<Int(ceil(run.sourceEnd / SourceListeningLevels.window)) {
                        guard levels.original.indices.contains(index), levels.processed.indices.contains(index) else { continue }
                        let width = SourceListeningLevels.window
                        let weight = max(0, min(run.sourceEnd, Double(index + 1) * width) - max(run.sourceStart, Double(index) * width)) * run.duration.seconds / (run.sourceEnd - run.sourceStart)
                        let gain = Float(item.gain * item.gain)
                        comparison.append((levels.original[index] * gain, levels.processed[index] * gain, weight))
                    }
                }
            }
        }
        progress(.timeline, 0.85)
        let media = try await TrackRenderer.timeline(project: project, folder: folder, processedRegions: files, canvasSize: canvasSize, framesPerSecond: framesPerSecond,
            videoProgress: { progress(.timeline, 0.85 + $0 * 0.15) }, effectPreparation: effectPreparation)
        progress(.timeline, 1)
        return PreparedTimeline(media: media, peak: peak, lease: SourceCacheLease([], parents: leases), listeningGains: SourceListeningLevels.gains(windows: comparison), processedRegions: files)
    }
    /// Inspector auditions process only audible source windows. Keep their source
    /// offsets explicit: a ten-second excerpt must never trigger a whole-take AI
    /// render, nor substitute a short CAF as though it started at source time zero.
    private func preparedPreview(project: Project, folder: URL, range: ClosedRange<Double>, progress: @escaping @Sendable (Double) -> Void) async throws -> PreparedTimeline {
        var requests: [String: (source: SourceMedia, effects: [AudioEffect], spans: [ClosedRange<Double>])] = [:]
        let window = EditInterval(range)
        for item in project.edit.timeline.audio where !item.muted {
            guard let part = item.interval.intersection(window), let source = project.sources.first(where: { $0.id == item.sourceID }) else { continue }
            let local = EditInterval(part.start - item.start, part.end - item.start)
            for region in item.enhancements where region.effects.contains(where: \.enabled) {
                guard let scope = region.interval.intersection(local) else { continue }
                let key = TrackRenderer.audioKey(source: source.id, effects: region.effects)
                let spans = item.mapping.sliced(scope).runs.filter { !$0.silent && !$0.isHold }.map { $0.sourceStart...$0.sourceEnd }
                if requests[key] == nil { requests[key] = (source, region.effects, []) }
                requests[key]!.spans += spans
            }
        }
        // Merge intersecting windows of the same source/chain, never bridge a
        // removed section or distant repeated occurrence of the same take.
        for key in requests.keys {
            var merged: [ClosedRange<Double>] = []
            for span in requests[key]!.spans.sorted(by: { $0.lowerBound < $1.lowerBound }) {
                if let last = merged.last, span.lowerBound <= last.upperBound + 0.00001 {
                    merged[merged.count - 1] = last.lowerBound...max(last.upperBound, span.upperBound)
                } else { merged.append(span) }
            }
            requests[key]!.spans = merged
        }
        let total = max(1, requests.values.reduce(0) { $0 + $1.spans.count })
        var done = 0, pinned: [URL] = [], windows: [String: [AudioPreviewWindow]] = [:], transferred = false
        defer { if !transferred { release(pinned) } }
        let cache = try cacheFolder(folder), encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for key in requests.keys.sorted() {
            let request = requests[key]!, sourceURL = folder.appendingPathComponent(request.source.filename)
            let asset = AVURLAsset(url: sourceURL)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else { continue }
            let info = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            for span in request.spans {
                try Task.checkCancellation()
                let duration = span.upperBound - span.lowerBound
                // Source media is immutable. Metadata avoids hashing an entire
                // long recording just to audition a few seconds of it.
                var identity = Data("audio-window-v1|\(sourceURL.path)|\(info.fileSize ?? 0)|\(info.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(span)|\(OfflineAudioPipeline.cacheVersion)|".utf8)
                identity.append(try encoder.encode(request.effects))
                let hash = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
                let destination = cache.appendingPathComponent(hash + ".caf")
                while building.contains(destination) { try await Task.sleep(for: .milliseconds(50)); try Task.checkCancellation() }
                building.insert(destination)
                defer { building.remove(destination) }
                let existing = try? AVAudioFile(forReading: destination)
                if existing?.length != Int64((duration * 48000).rounded()) || existing?.processingFormat.sampleRate != 48000 || existing?.processingFormat.channelCount != 2 {
                    try prune(cache, reserving: Int64(ceil(duration * 48000 * 8 * Double(request.effects.count + 3))))
                    let raw = cache.appendingPathComponent(UUID().uuidString + ".working.caf"), output = cache.appendingPathComponent(UUID().uuidString + ".working.caf")
                    defer { for url in [raw, output] { try? FileManager.default.removeItem(at: url) } }
                    let excerpt = AVMutableComposition()
                    guard let audio = excerpt.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw ProjectError.invalidMedia }
                    let selected = CMTimeRange(start: TransitionRenderer.time(span.lowerBound), duration: TransitionRenderer.time(duration))
                    let available = try await track.load(.timeRange)
                    let actual = CMTimeRangeGetIntersection(selected, otherRange: available)
                    if actual.duration > .zero { try audio.insertTimeRange(actual, of: track, at: actual.start - selected.start) }
                    let index = done
                    _ = try await MediaRenderer.processedAudio(asset: excerpt, duration: duration, effects: [], outputURL: raw) { progress((Double(index) + $0 * 0.15) / Double(total)) }
                    let processing = Task.detached(priority: .userInitiated) {
                        try OfflineAudioPipeline.process(input: raw, effects: request.effects, output: output) { progress((Double(index) + 0.15 + $0 * 0.8) / Double(total)) }
                    }
                    _ = try await withTaskCancellationHandler(operation: { try await processing.value }, onCancel: { processing.cancel() })
                    try Task.checkCancellation()
                    if FileManager.default.fileExists(atPath: destination.path) {
                        guard pins[destination] == nil else { throw AudioProcessingError.invalidFormat }
                        try FileManager.default.removeItem(at: destination)
                    }
                    try FileManager.default.moveItem(at: output, to: destination)
                }
                pin(destination); pinned.append(destination)
                windows[key, default: []].append(AudioPreviewWindow(range: span, url: destination))
                done += 1; progress(Double(done) / Double(total))
            }
        }
        let media = try await TrackRenderer.timeline(project: project, folder: folder, audioPreviewRange: range, processedWindows: windows, effectPreparation: .cached)
        try Task.checkCancellation(); transferred = true
        return PreparedTimeline(media: media, peak: 0, lease: SourceCacheLease(pinned))
    }
    private func preparedUniform(project: Project, folder: URL, effectPreparation:VideoEffectPreparation = .final, progress: @escaping @Sendable (Double) -> Void) async throws -> PreparedTimeline {
        let hasVideoProcessing = project.edit.clips.contains { $0.stabilization != nil && $0.stabilization?.level != .off }
        let audioWeight = hasVideoProcessing ? 0.75 : 1.0
        let feedback = MediaProgress { progress($0 * audioWeight) }
        let enabled = project.edit.effects.filter(\.enabled)
        guard enabled.allSatisfy(\.supported) else { throw AudioProcessingError.unavailableModel }
        let active = enabled.filter { !($0.kind.isNeural && $0.amount == 0) }
        guard !enabled.isEmpty else {
            return PreparedTimeline(media: try await MediaRenderer.timeline(project: project, folder: folder, videoProgress: progress,effectPreparation:effectPreparation), peak: 0)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let chain = try encoder.encode(active)
        let ids = Set(project.edit.clips.map(\.sourceID))
        let sources = project.sources.filter { ids.contains($0.id) }
        var audio: [UUID: URL] = [:]
        var levels: [UUID: SourceListeningLevels] = [:]
        var pinned: [URL] = []
        var transferred = false
        defer { if !transferred { release(pinned) } }
        var peak: Float = 0
        let cache = try cacheFolder(folder)
        for (index, source) in sources.enumerated() {
            try Task.checkCancellation()
            let sourceURL = folder.appendingPathComponent(source.filename)
            guard !(try await AVURLAsset(url: sourceURL).loadTracks(withMediaType: .audio)).isEmpty else { continue }
            let identity = Data((try await fingerprint(sourceURL) + "|\(OfflineAudioPipeline.cacheVersion)|\(source.duration)|").utf8)
            var keyData = identity; keyData.append(chain)
            let key = SHA256.hash(data: keyData).map { String(format: "%02x", $0) }.joined()
            let destination = cache.appendingPathComponent(key + ".caf")
            let metadata = cache.appendingPathComponent(key + ".peak")
            let checkpoints = try active.indices.map { index -> URL in
                var data = identity; data.append(try encoder.encode(Array(active.prefix(index + 1))))
                let prefix = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                return cache.appendingPathComponent(prefix + ".caf")
            }
            // Reserve the entire prefix set atomically, before any await.
            // Different chains sharing a stage cannot delete or rewrite each
            // other's resume windows. Waiters cancel independently.
            let reservations = Set(checkpoints + [destination])
            while !building.isDisjoint(with: reservations) { try await Task.sleep(for: .milliseconds(50)); try Task.checkCancellation() }
            building.formUnion(reservations)
            defer { building.subtract(reservations) }
            if let file = try? AVAudioFile(forReading: destination),
               file.length == Int64((source.duration * 48000).rounded()),
               file.processingFormat.sampleRate == 48000, file.processingFormat.channelCount == 2,
               let text = try? String(contentsOf: metadata, encoding: .utf8), let value = Float(text), value.isFinite, value >= 0 {
                pin(destination); pinned.append(destination)
                peak = max(peak, value); audio[source.id] = destination
                levels[source.id] = try await listeningLevels(source: sourceURL, duration: source.duration, processed: destination)
                feedback.report(Double(index + 1) / Double(sources.count)); continue
            }
            // Reservations exclude other builders. Remove unusable derived
            // stages before taking our own pins, so an interrupted metadata
            // write or truncated cache can be regenerated from the original.
            for file in reservations where FileManager.default.fileExists(atPath: file.path) {
                let peakFile = file.deletingPathExtension().appendingPathExtension("peak")
                let cached = try? AVAudioFile(forReading: file)
                let value = (try? String(contentsOf: peakFile, encoding: .utf8)).flatMap(Float.init)
                let valid = cached?.length == Int64((source.duration * 48000).rounded()) &&
                    cached?.processingFormat.sampleRate == 48000 && cached?.processingFormat.channelCount == 2 &&
                    value.map { $0.isFinite && $0 >= 0 } == true
                if !valid {
                    guard pins[file] == nil else { throw AudioProcessingError.invalidFormat }
                    try FileManager.default.removeItem(at: file)
                    for suffix in ["peak", "levels.json", "priority"] {
                        try? FileManager.default.removeItem(at: file.deletingPathExtension().appendingPathExtension(suffix))
                    }
                }
            }
            for file in checkpoints { pin(file) }
            defer { release(checkpoints) }
            for (index, file) in checkpoints.enumerated() {
                // Prefer retaining a neural boundary over its cheap EQ/gain
                // derivatives, so changing tone does not rerun the models.
                let cost = active.prefix(index + 1).filter { $0.kind.isNeural }.count * 100 + (active[index].kind.isNeural ? 10 : 0)
                try String(cost).write(to: file.deletingPathExtension().appendingPathExtension("priority"), atomically: true, encoding: .utf8)
            }
            try prune(cache, reserving: Int64(ceil(source.duration * 48000 * 2 * 4 * Double(active.count + 3))))
            let raw = cache.appendingPathComponent(UUID().uuidString + ".working.caf")
            let processed = cache.appendingPathComponent(UUID().uuidString + ".working.caf")
            defer { for url in [raw, processed] { try? FileManager.default.removeItem(at: url) } }
            let base = Double(index) / Double(sources.count), weight = 1 / Double(sources.count)
            _ = try await MediaRenderer.processedAudio(asset: AVURLAsset(url: sourceURL), duration: source.duration,
                effects: [], outputURL: raw) { feedback.report(base + $0 * weight * 0.2) }
            let processing = Task.detached(priority: .userInitiated) {
                try OfflineAudioPipeline.process(input: raw, effects: enabled, output: processed, checkpoints: checkpoints) {
                    feedback.report(base + (0.2 + $0 * 0.8) * weight)
                }
            }
            let value = try await withTaskCancellationHandler(operation: { try await processing.value }, onCancel: { processing.cancel() })
            try Task.checkCancellation()
            if let existing = try? AVAudioFile(forReading: destination),
               existing.length == Int64((source.duration * 48000).rounded()),
               existing.processingFormat.sampleRate == 48000, existing.processingFormat.channelCount == 2,
               let text = try? String(contentsOf: metadata, encoding: .utf8), let measured = Float(text), measured.isFinite, measured >= 0 {
                // Another request completed while this one decoded. Never replace
                // an immutable cache file that a player may already have open.
                pin(destination); pinned.append(destination)
                peak = max(peak, measured); audio[source.id] = destination
                levels[source.id] = try await listeningLevels(source: sourceURL, duration: source.duration, processed: destination, decodedOriginal: raw)
                continue
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                guard pins[destination] == nil else { throw AudioProcessingError.invalidFormat }
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: processed, to: destination)
            try String(value).write(to: metadata, atomically: true, encoding: .utf8)
            pin(destination); pinned.append(destination)
            peak = max(peak, value); audio[source.id] = destination
            levels[source.id] = try await listeningLevels(source: sourceURL, duration: source.duration, processed: destination, decodedOriginal: raw)
        }
        let media = try await MediaRenderer.timeline(project: project, folder: folder, processedSources: audio, videoProgress: { progress(audioWeight + $0 * (1 - audioWeight)) },effectPreparation:effectPreparation)
        transferred = true
        return PreparedTimeline(media: media, peak: peak, lease: SourceCacheLease(pinned), listeningGains: SourceListeningLevels.gains(clips: project.edit.clips, levels: levels), processedSources: audio)
    }
}
