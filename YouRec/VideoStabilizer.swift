@preconcurrency import AVFoundation
import Accelerate
import CryptoKit
import Foundation

actor VideoStabilizer {
    static let shared = VideoStabilizer()

    private struct Checkpoint: Codable {
        let path: StabilizationAnalysis
        let previousFrame: Data
        let timestamp: Double
    }
    private var building = Set<URL>()
    private var analyses: [URL: StabilizationAnalysis] = [:]
    private var analysisOrder: [URL] = []
    private var plans: [String: StabilizationPlan] = [:]
    private var planOrder: [String] = []

    private func remember(_ analysis: StabilizationAnalysis, at file: URL) {
        analyses[file] = analysis; analysisOrder.removeAll { $0 == file }; analysisOrder.append(file)
        while analysisOrder.count > 1 && (analysisOrder.count > 3 || analyses.values.reduce(0, { $0 + $1.samples.count }) > 360_000) {
            analyses[analysisOrder.removeFirst()] = nil
        }
    }

    func analysis(source: SourceMedia, clip: TimelineClip, folder: URL, generate: Bool = true,
                  progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> StabilizationAnalysis {
        try Task.checkCancellation()
        let url = folder.appendingPathComponent(source.filename)
        let fingerprint = try await SourceMediaCache.shared.fingerprint(url)
        try Task.checkCancellation()
        let start = clip.stabilizationStart, end = clip.stabilizationEnd
        let identity = "\(StabilizationAnalysis.version)|\(fingerprint)|\(start)|\(end)"
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        var cache = folder.appendingPathComponent("Cache/Stabilization", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? cache.setResourceValues(values)
        let file = cache.appendingPathComponent(key + ".json")
        while building.contains(file) {
            if !generate { throw VideoEffectError.analysisPending }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        if let cached = analyses[file] { remember(cached, at: file); progress(1); return cached }
        if let data = try? Data(contentsOf: file), let analysis = try? JSONDecoder().decode(StabilizationAnalysis.self, from: data),
           analysis.valid, abs(analysis.duration - (end - start)) < 0.00001 {
            remember(analysis, at: file); progress(1); return analysis
        }
        guard generate else { throw VideoEffectError.analysisPending }
        building.insert(file)
        defer { building.remove(file) }
        let feedback = MediaProgress(progress)
        let checkpoint = file.deletingPathExtension().appendingPathExtension("checkpoint")
        let resumable = VideoEffectPreparation.applyingSavedEdit
        if resumable {
            // Only the currently applying analyses need partial trajectories.
            let siblings = (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? []
            for other in siblings where other.pathExtension == "checkpoint" && !building.contains(other.deletingPathExtension().appendingPathExtension("json")) {
                try? FileManager.default.removeItem(at: other)
            }
        }
        let task = Task.detached(priority: .userInitiated) {
            try await Self.measure(url: url, start: start, duration: end - start, checkpoint: resumable ? checkpoint : nil) { feedback.report($0) }
        }
        let analysis = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
        try Task.checkCancellation()
        guard analysis.valid else { throw ProjectError.invalidMedia }
        try JSONEncoder().encode(analysis).write(to: file, options: .atomic)
        try? FileManager.default.removeItem(at: checkpoint)
        // These are small replaceable trajectories, never originals. Bound
        // growth from repeated trims without interfering with audio caches.
        let files = (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
        let records = files.filter { $0.pathExtension == "json" }.compactMap { url -> (URL, Int, Date)? in
            guard let info = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (url, info.fileSize ?? 0, info.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var bytes = records.reduce(0) { $0 + $1.1 }
        for (old, size, _) in records where bytes > 64_000_000 && old != file && !building.contains(old) {
            try? FileManager.default.removeItem(at: old); bytes -= size
        }
        remember(analysis, at: file); progress(1)
        return analysis
    }

    func plan(source: SourceMedia, clip: TimelineClip, folder: URL,
              progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> StabilizationPlan? {
        try Task.checkCancellation()
        guard let settings = clip.stabilization, settings.level != .off else { return nil }
        guard settings.version == 1 else { throw ProjectError.invalidDocument }
        let fingerprint = try await SourceMediaCache.shared.fingerprint(folder.appendingPathComponent(source.filename))
        let key = "\(fingerprint)|\(clip.stabilizationStart)|\(clip.stabilizationEnd)|\(settings.level.rawValue)"
        if let plan = plans[key] { planOrder.removeAll { $0 == key }; planOrder.append(key); progress(1); return plan }
        let measured: StabilizationAnalysis
        do {
            measured = try await analysis(source: source, clip: clip, folder: folder,
                                          generate: VideoEffectPreparation.inspectionWindow == nil, progress: progress)
        } catch VideoEffectError.analysisPending {
            guard var sample = VideoEffectPreparation.inspectionWindow?.analysisClip(clip) else { return nil }
            sample.stabilization?.referenceStart = sample.start
            sample.stabilization?.referenceEnd = sample.end
            let measured = try await analysis(source: source, clip: sample, folder: folder, progress: progress)
            let plan = try StabilizationPath.make(measured, level: settings.level)
            let offset = sample.stabilizationStart - clip.stabilizationStart
            // Instructions still use the original clip clock. Only the sample
            // path was measured; never cache it under the full take's key.
            return StabilizationPlan(size: plan.size, samples: plan.samples.map {
                StabilizationSample(time: $0.time + offset, pose: $0.pose, segment: $0.segment)
            }, zoom: plan.zoom, strengthLimited: plan.strengthLimited, trackingFraction: plan.trackingFraction)
        }
        let plan = try StabilizationPath.make(measured, level: settings.level)
        plans[key] = plan; planOrder.removeAll { $0 == key }; planOrder.append(key)
        while planOrder.count > 1 && (planOrder.count > 16 || plans.values.reduce(0, { $0 + $1.samples.count }) > 360_000) {
            plans[planOrder.removeFirst()] = nil
        }
        return plan
    }

    private static func measure(url: URL, start: Double, duration: Double, checkpoint: URL?,
                                progress: @escaping @Sendable (Double) -> Void) async throws -> StabilizationAnalysis {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ProjectError.invalidMedia }
        let size = try await track.load(.naturalSize)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ProjectError.invalidMedia }
        reader.add(output)
        let ratio = min(1, 640 / max(size.width, size.height))
        let width = max(64, Int((size.width * ratio).rounded())), height = max(64, Int((size.height * ratio).rounded()))
        var previous: [UInt8]?, previousTime = -Double.infinity
        var samples: [StabilizationSample] = []
        var pose = StabilizationPose.identity, segment = 0, tracked = 0
        if let checkpoint, let data = try? Data(contentsOf: checkpoint),
           let saved = try? PropertyListDecoder().decode(Checkpoint.self, from: data),
           saved.path.width == Int(size.width), saved.path.height == Int(size.height), saved.path.duration == duration,
           saved.path.valid, let last = saved.path.samples.last, last.time == saved.timestamp,
           saved.previousFrame.count == width * height {
            samples = saved.path.samples; previous = Array(saved.previousFrame); previousTime = saved.timestamp
            pose = last.pose; segment = last.segment; tracked = saved.path.trackedFrames
        }
        // Seek slightly before the saved frame and skip through its PTS. The
        // first new motion estimate uses the exact preceding luma, including on VFR material.
        let resumeAt = start + max(0, previousTime - 0.25)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: resumeAt, preferredTimescale: 60000),
                                       end: CMTime(seconds: start + duration, preferredTimescale: 60000))
        guard reader.startReading() else { throw reader.error ?? ProjectError.invalidMedia }
        defer { if reader.status == .reading { reader.cancelReading() } }
        var nextCheckpoint = max(0, previousTime) + 5
        progress(max(0, previousTime) / duration)
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let time = max(0, sample.presentationTimeStamp.seconds - start)
            guard time.isFinite, time < duration else { continue }
            // Analyze every distinct source frame, including 60/120 fps imports.
            // Export may display any one of them after a trim or a preceding
            // clip with a fractional duration. Interpolation can mis-correct
            // high-frequency shake on that held frame.
            if time <= previousTime { continue }
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { throw ProjectError.invalidMedia }
            let gray: [UInt8] = try autoreleasepool {
                CVPixelBufferLockBaseAddress(buffer, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
                guard CVPixelBufferIsPlanar(buffer), let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { throw ProjectError.invalidMedia }
                var source = vImage_Buffer(data: base, height: vImagePixelCount(CVPixelBufferGetHeightOfPlane(buffer, 0)),
                    width: vImagePixelCount(CVPixelBufferGetWidthOfPlane(buffer, 0)), rowBytes: CVPixelBufferGetBytesPerRowOfPlane(buffer, 0))
                var bytes = [UInt8](repeating: 0, count: width * height)
                let status = bytes.withUnsafeMutableBytes { ptr in
                    var destination = vImage_Buffer(data: ptr.baseAddress!, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
                    return vImageScale_Planar8(&source, &destination, nil, vImage_Flags(kvImageHighQualityResampling))
                }
                guard status == kvImageNoError else { throw ProjectError.invalidMedia }
                return bytes
            }
            if let previous {
                let motion = previous.withUnsafeBufferPointer { a in gray.withUnsafeBufferPointer { b in
                    yr_estimate_motion(a.baseAddress!, b.baseAddress!, Int32(width), Int32(height))
                } }
                if motion.valid != 0 && time - previousTime < 0.15 {
                    // Uniform analysis scaling preserves a similarity. Account
                    // for fractional size rounding in translations separately.
                    let step = StabilizationPose(x: motion.x * size.width / Double(width), y: motion.y * size.height / Double(height),
                                                 angle: motion.angle, logScale: motion.logScale)
                    let next = step.applying(pose)
                    if next.valid { pose = next; tracked += 1 }
                    else { segment += 1; pose = .identity }
                } else { segment += 1; pose = .identity }
            }
            samples.append(StabilizationSample(time: samples.isEmpty ? 0 : time, pose: pose, segment: segment))
            previous = gray; previousTime = time
            if let checkpoint, time >= nextCheckpoint {
                let path = StabilizationAnalysis(width: Int(size.width), height: Int(size.height), duration: duration,
                                                 samples: samples, trackedFrames: tracked)
                let saved = Checkpoint(path: path, previousFrame: Data(gray), timestamp: time)
                let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
                try encoder.encode(saved).write(to: checkpoint, options: .atomic)
                nextCheckpoint = time + max(5, min(30, time / 24))
            }
            progress(time / duration)
        }
        if reader.status == .failed { throw reader.error ?? ProjectError.invalidMedia }
        try Task.checkCancellation()
        guard !samples.isEmpty else { throw ProjectError.invalidMedia }
        return StabilizationAnalysis(width: Int(size.width), height: Int(size.height), duration: duration,
                                     samples: samples, trackedFrames: tracked)
    }
}

#if DEBUG && canImport(UIKit)
import UIKit

enum StabilizationDiagnostics {
    @MainActor static func run() async {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("StabilizationTest", isDirectory: true)
        var report: [String: Any] = [:]
        RecordingAppDelegate.keepAwake("stabilization-diagnostic", active: true)
        defer { RecordingAppDelegate.keepAwake("stabilization-diagnostic", active: false) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let input = folder.appendingPathComponent("shake.mp4")
            let duration = try await AVURLAsset(url: input).load(.duration).seconds
            let source = SourceMedia(filename: "shake.mp4", duration: duration)
            var project = Project(title: "Stabilization diagnostic"); project.append(source)
            let clip = project.edit.clips[0], start = Date()
            var edit = project.edit; edit.clips[0].stabilization = clip.stabilizing(.standard); project.commit(edit)
            guard let receipt = EffectApplicationReceipt(project: project, tool: .stabilize) else { throw ProjectError.invalidDocument }
            try receipt.save(in: folder)
            let editor = EditorController()
            defer { editor.stop() }
            // SpringBoard may launch diagnostics before the scene is active;
            // the real editor resumes from its scene notification in that case.
            let deadline = ContinuousClock.now + .seconds(60)
            while UIApplication.shared.applicationState != .active && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            report["activeAtStart"] = UIApplication.shared.applicationState == .active
            await editor.load(project, folder: folder)
            report["paused"] = editor.applicationPaused
            report["editorError"] = editor.effectRefinementError ?? editor.error ?? ""
            guard editor.error == nil, editor.effectRefinementError == nil, !editor.loading,
                  EffectApplicationReceipt.pending(for: project, in: folder) == nil,
                  let item = editor.player.currentItem, let composition = item.videoComposition,
                  let picture = composition.instructions.first as? VideoToolInstruction,
                  let path = picture.stabilization, !path.samples.isEmpty else { throw ProjectError.invalidMedia }
            report["applicationSeconds"] = Date().timeIntervalSince(start)
            report["instructionCount"] = composition.instructions.count
            report["corrections"] = path.samples.count
            let images = AVAssetImageGenerator(asset: item.asset); images.videoComposition = composition
            images.requestedTimeToleranceBefore = .zero; images.requestedTimeToleranceAfter = .zero
            for point in [0.1, duration / 2, duration - 0.1] {
                _ = try await images.image(at: CMTime(seconds: point, preferredTimescale: 60000))
            }
            report["checkedEditorFrames"] = 3
            let midpoint = duration / 2
            guard await editor.seekAndWait(midpoint) else { throw ProjectError.invalidMedia }
            editor.togglePlay()
            let playbackDeadline = ContinuousClock.now + .seconds(15)
            while editor.player.currentTime().seconds < midpoint + 0.25 && ContinuousClock.now < playbackDeadline {
                try await Task.sleep(for: .milliseconds(40))
            }
            editor.pause()
            report["playbackAdvanced"] = editor.player.currentTime().seconds - midpoint
            guard editor.player.currentTime().seconds >= midpoint + 0.25 else { throw ProjectError.invalidMedia }
            let lookupStart = Date()
            let analysis = try await VideoStabilizer.shared.analysis(source: source, clip: clip, folder: folder)
            report["analysisLookupSeconds"] = Date().timeIntervalSince(lookupStart)
            report["duration"] = duration; report["trackedFraction"] = analysis.trackingFraction
            let plan = try await VideoStabilizer.shared.plan(source: source, clip: project.edit.clips[0], folder: folder)!
            report["cropZoom"] = plan.zoom
            let output = folder.appendingPathComponent("stabilized-" + UUID().uuidString + ".mp4")
            let renderStart = Date()
            _ = try await MediaRenderer.render(project: project, folder: folder, destination: output) { _ in }
            report["renderSeconds"] = Date().timeIntervalSince(renderStart); report["output"] = output.lastPathComponent
            let exported = AVURLAsset(url: output)
            report["exportDuration"] = try await exported.load(.duration).seconds
            report["audioTracks"] = try await exported.loadTracks(withMediaType: .audio).count
            let split = TimelineEditing.split(project.edit, at: duration / 2)
            let splitStart = Date()
            _ = try await VideoStabilizer.shared.plan(source: source, clip: split.clips[1], folder: folder)
            report["splitPlanSeconds"] = Date().timeIntervalSince(splitStart)
            report["success"] = true
        } catch { report["success"] = false; report["error"] = error.localizedDescription }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("report.json"), options: .atomic)
        }
    }
}
#endif
