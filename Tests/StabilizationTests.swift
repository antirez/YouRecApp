import Foundation
import AVFoundation

func stabilizationTests(root: URL) async throws {
    let frames = 240, fps = 30.0
    let size = CGSize(width: 640, height: 360)
    let pan = (0..<frames).map { StabilizationPose(x: Double($0) * 1.1, y: Double($0) * -0.2) }
    let panAnalysis = StabilizationAnalysis(width: 640, height: 360, duration: 8, samples: pan.enumerated().map { StabilizationSample(time: Double($0.offset) / fps, pose: $0.element, segment: 0) }, trackedFrames: frames - 1)
    let panPlan = try StabilizationPath.make(panAnalysis, level: .strong)
    try require(panPlan.samples.allSatisfy { abs($0.pose.x) < 0.00001 && abs($0.pose.y) < 0.00001 }, "Constant-speed pans remain unchanged, including clip endpoints")
    var poses = pan
    for i in poses.indices {
        let t = Double(i) / fps
        poses[i].x += 6 * sin(2 * .pi * 4.1 * t)
        poses[i].y += 4 * sin(2 * .pi * 3.3 * t)
        poses[i].angle = 0.008 * sin(2 * .pi * 2.7 * t)
    }
    let noisy = StabilizationAnalysis(width: 640, height: 360, duration: 8,
        samples: poses.enumerated().map { StabilizationSample(time: Double($0.offset) / fps, pose: $0.element, segment: 0) }, trackedFrames: frames - 1)
    var previousResidual = Double.infinity
    for level in StabilizationLevel.allCases where level != .off {
        let plan = try StabilizationPath.make(noisy, level: level)
        let residual = plan.samples.enumerated().dropFirst(30).dropLast(30).reduce(0.0) { sum, pair in
            let stable = pair.element.pose.applying(poses[pair.offset])
            return sum + pow(stable.x - pan[pair.offset].x, 2) + pow(stable.y - pan[pair.offset].y, 2)
        } / Double(frames - 60)
        try require(residual < previousResidual + 0.05, "Increasing stabilization levels does not increase residual shake")
        try require(plan.zoom <= level.maximumZoom + 0.000001, "Crop respects the selected level's bound")
        for frame in 0..<(frames * 3) {
            let inverse = plan.transform(at: Double(frame) / 90).inverted()
            for corner in [CGPoint.zero, CGPoint(x: size.width, y: 0), CGPoint(x: 0, y: size.height), CGPoint(x: size.width, y: size.height)] {
                let source = corner.applying(inverse)
                try require(source.x >= -0.001 && source.y >= -0.001 && source.x <= size.width + 0.001 && source.y <= size.height + 0.001, "Every output corner stays inside the source, also between analyzed frames")
            }
        }
        print("STABILIZATION: \(level.rawValue), residual MSE \(residual), crop \(plan.cropPercent)%")
        previousResidual = residual
    }
    try require(previousResidual < 2, "Strong stabilization removes most high-frequency translation")
    let off = try StabilizationPath.make(noisy, level: .off)
    try require(off.zoom == 1 && off.transform(at: 1) == .identity, "Off is exact identity")
    var zoomSamples = noisy.samples
    for i in zoomSamples.indices { zoomSamples[i].pose = StabilizationPose(logScale: Double(i) / fps * log(2) / 2) }
    let zoomAnalysis = StabilizationAnalysis(width: 640, height: 360, duration: 8, samples: zoomSamples, trackedFrames: 239)
    let zoomPlan = try StabilizationPath.make(zoomAnalysis, level: .strong)
    try require(zoomPlan.zoom == 1 && zoomPlan.samples.allSatisfy { abs($0.pose.logScale) < 1e-10 }, "Intentional recorded zoom is never smoothed or retimed")
    let panZoomSamples = (0..<450).map { i -> StabilizationSample in
        let t = Double(i) / fps, cameraX = min(t, 4) * 200
        let zoom = 1 + min(1, max(0, (t - 7) / 2))
        return StabilizationSample(time: t, pose: StabilizationPose(x: -zoom * cameraX, logScale: log(zoom)), segment: 0)
    }
    let panZoom = StabilizationAnalysis(width: 640, height: 360, duration: 15, samples: panZoomSamples, trackedFrames: 449)
    for level in [StabilizationLevel.standard, .strong] {
        let result = try StabilizationPath.make(panZoom, level: level)
        try require(result.samples.filter { $0.time >= 6.5 }.allSatisfy { abs($0.pose.x) < 0.0001 && abs($0.pose.y) < 0.0001 }, "Zoom after a completed pan introduces no false translation")
    }
    var cutSamples = noisy.samples
    for i in 120..<frames { cutSamples[i].segment = 1; cutSamples[i].pose = .identity }
    let cut = StabilizationAnalysis(width: 640, height: 360, duration: 8, samples: cutSamples, trackedFrames: 238)
    let cutPlan = try StabilizationPath.make(cut, level: .strong)
    try require(cutPlan.samples[120...].allSatisfy { abs($0.pose.x) < 0.000001 && abs($0.pose.y) < 0.000001 }, "Smoothing never crosses a cut or tracking reset")

    var p = Project(title: "Stabilization persistence")
    p.append(SourceMedia(filename: "source.mp4", duration: 4))
    var edit = p.edit; edit.clips[0].stabilization = StabilizationSettings(level: .strong); p.commit(edit)
    p.undo()
    let encoded = try JSONEncoder().encode(p)
    var reopened = try JSONDecoder().decode(Project.self, from: encoded); try reopened.validate(); reopened.redo()
    try require(reopened.edit.clips[0].stabilization?.level == .strong, "Stabilization survives persistent undo and redo")
    let split = TimelineEditing.split(reopened.edit, at: 2)
    try require(split.clips.allSatisfy { $0.stabilization?.level == .strong }, "Split inherits per-clip stabilization")
    let legacy = Data("{\"id\":\"\(UUID().uuidString)\",\"sourceID\":\"\(p.sources[0].id.uuidString)\",\"start\":0,\"end\":4}".utf8)
    let legacyClip = try JSONDecoder().decode(TimelineClip.self, from: legacy)
    try require(legacyClip.stabilization == nil, "Old clips decode with stabilization off")
    print("PASS: stabilization smoothing, pan preservation, crop inclusion, scene reset, levels, persistence and legacy clips")

    guard let fixturePath = ProcessInfo.processInfo.environment["YOUREC_STABILIZATION_FIXTURE"] else { return }
    let fixture = URL(fileURLWithPath: fixturePath)
    let folder = root.appendingPathComponent("stabilization", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let input = folder.appendingPathComponent("shake.mp4")
    try FileManager.default.copyItem(at: fixture, to: input)
    let duration = try await AVURLAsset(url: input).load(.duration).seconds
    var project = Project(title: "Stabilization media test")
    let source = SourceMedia(filename: "shake.mp4", duration: duration); project.append(source)
    let clip = project.edit.clips[0]
    let originalHash = try await SourceMediaCache.shared.fingerprint(input)
    let started = Date()
    let measured = try await VideoStabilizer.shared.analysis(source: source, clip: clip, folder: folder)
    try require(measured.trackingFraction > 0.9, "Most fixture frames track successfully")
    print("STABILIZATION: analyzed \(duration) seconds in \(Date().timeIntervalSince(started)) seconds, \(measured.trackingFraction * 100)% tracked")
    let cached = try await VideoStabilizer.shared.analysis(source: source, clip: clip, folder: folder)
    try require(cached.samples.count == measured.samples.count, "Cached analysis is reusable")
    var state = project.edit; state.clips[0].stabilization = clip.stabilizing(.standard); project.commit(state)
    let media = try await MediaRenderer.timeline(project: project, folder: folder)
    try require(media.playbackVideoComposition != nil, "Stabilization is active in the normal editor preview")
    let instructions = media.playbackVideoComposition?.instructions.compactMap { $0 as? VideoToolInstruction } ?? []
    try require(instructions.count == 1 && instructions[0].stabilization?.samples.count == measured.samples.count,
                "A stabilized take uses one playback instruction and retains every source correction")

    let splitState = TimelineEditing.split(project.edit, at: 3)
    let first = try await VideoStabilizer.shared.plan(source: source, clip: splitState.clips[0], folder: folder)!
    let second = try await VideoStabilizer.shared.plan(source: source, clip: splitState.clips[1], folder: folder)!
    try require(first.zoom == second.zoom && first.samples.count == measured.samples.count && second.samples.count == measured.samples.count, "Split clips reuse full reference analysis and exact framing")
    let cacheEntries = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("Cache/Stabilization").path)
    try require(cacheEntries.filter { $0.hasSuffix(".json") }.count == 1, "Splitting creates no duplicate motion analysis")
    let output = folder.appendingPathComponent("stabilized.mp4")
    _ = try await MediaRenderer.render(project: project, folder: folder, destination: output) { _ in }
    let exported = AVURLAsset(url: output)
    let exportedDuration = try await exported.load(.duration).seconds
    let audio = try await exported.loadTracks(withMediaType: .audio)
    try require(abs(exportedDuration - duration) < 1 / 30.0 && audio.count == 1, "Video stabilization preserves duration and audio")
    let receipt = try JSONDecoder().decode(ExportReceipt.self, from: Data(contentsOf: output.deletingPathExtension().appendingPathExtension("json")))
    try require(receipt.edit.clips[0].stabilization?.level == .standard, "Export receipt includes stabilization")
    let currentHash = try await SourceMediaCache.shared.fingerprint(input)
    try require(originalHash == currentHash, "Source file remains untouched")
    if let destination = ProcessInfo.processInfo.environment["YOUREC_STABILIZATION_RESULTS"] {
        let directory = URL(fileURLWithPath: destination, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: output, to: directory.appendingPathComponent("stabilized.mp4"))
        try JSONEncoder().encode(measured).write(to: directory.appendingPathComponent("analysis.json"))
        let plan = try StabilizationPath.make(measured, level: .standard)
        try JSONEncoder().encode(plan.samples).write(to: directory.appendingPathComponent("corrections.json"))
    }
    print("PASS: actual video analysis, cache reuse, preview transform, export, source integrity, audio duration and export receipt")
    for name in ["portrait", "vfr", "cut", "fps24", "fps25", "fps60", "hlg"] {
        let variant = fixture.deletingLastPathComponent().appendingPathComponent(name + ".mp4")
        guard FileManager.default.fileExists(atPath: variant.path) else { continue }
        try FileManager.default.copyItem(at: variant, to: folder.appendingPathComponent(name + ".mp4"))
        let asset = AVURLAsset(url: variant), tracks = try await asset.loadTracks(withMediaType: .video)
        let natural = try await tracks[0].load(.naturalSize), preferred = try await tracks[0].load(.preferredTransform)
        let upright = CGRect(origin: .zero, size: natural).applying(preferred)
        let length = try await asset.load(.duration).seconds
        var candidate = Project(title: "Stabilization " + name)
        let source = SourceMedia(filename: name + ".mp4", duration: length); candidate.append(source)
        var edits = candidate.edit
        edits.clips[0].stabilization = edits.clips[0].stabilizing(.strong); candidate.commit(edits)
        let measured = try await VideoStabilizer.shared.analysis(source: source, clip: candidate.edit.clips[0], folder: folder)
        try require(measured.valid && measured.trackingFraction > 0.9, "\(name): valid timestamped motion analysis")
        if name == "cut" { try require(Set(measured.samples.map(\.segment)).count >= 2, "Scene change resets the motion path") }
        let output = folder.appendingPathComponent(name + "-export.mp4")
        _ = try await MediaRenderer.render(project: candidate, folder: folder, destination: output) { _ in }
        let result = AVURLAsset(url: output), resultTracks = try await result.loadTracks(withMediaType: .video)
        let resultSize = try await resultTracks[0].load(.naturalSize), resultDuration = try await result.load(.duration).seconds
        if name == "hlg" {
            let descriptions = try await resultTracks[0].load(.formatDescriptions)
            try require(descriptions.contains { VideoColor.isHDR($0) }, "Stabilization preserves HDR in the exported file")
        }
        try require(resultSize.width == abs(upright.width) && resultSize.height == abs(upright.height), "\(name): export retains upright dimensions")
        try require(abs(resultDuration - length) < 1 / 30.0, "\(name): export duration stays aligned")
        if let destination = ProcessInfo.processInfo.environment["YOUREC_STABILIZATION_RESULTS"] {
            try FileManager.default.copyItem(at: output, to: URL(fileURLWithPath: destination).appendingPathComponent(name + "-export.mp4"))
        }
        print("PASS: \(name) motion analysis and rendered dimensions/duration")
    }
}
