import Foundation
import AVFoundation
import CoreImage

func transitionTests(root: URL) async throws {
    if let path = ProcessInfo.processInfo.environment["YOUREC_TRANSITION_PROJECT"] {
        try await transitionProjectRegression(folder: URL(fileURLWithPath: path))
    }
    var project = Project(title: "Transitions")
    project.append(SourceMedia(filename: "source.mp4", duration: 4))
    project.append(SourceMedia(filename: "portrait.mp4", duration: 4))
    let original = project.edit
    let secondID = original.clips[1].id
    let dissolve = ClipTransition(nextClipID: secondID, duration: 1)
    let edit = original.settingTransition(dissolve, at: 1)
    try require(edit.duration == 7 && edit.layout.placements[1].start == 3 && edit.layout.joins[1].time == 3.5, "Overlap shifts the second clip and join by the correct amounts")
    try require(edit.clips.map(\.start) == original.clips.map(\.start) && edit.clips.map(\.end) == original.clips.map(\.end), "Adding an overlap never changes source trims")
    try require(TimelineEditing.snap(3.51, clips: edit.clips, pointsPerSecond: 60) == 3.5, "Snap lands at the transition midpoint")
    try require(TimelineEditing.scope(edit, selection: nil, clipID: secondID) == 3.5...7, "Clip scope follows the overlap layout")
    try require(TimelineEditing.split(edit, at: 3.25) == edit, "Splitting inside an overlap is refused without modifying footage")
    let split = TimelineEditing.split(edit, at: 1)
    try require(split.clips.count == 3 && split.duration == 7 && split.clips[1].transition == dissolve && split.clips[0].transition == nil, "Splits preserve the outgoing join and duration")
    let removed = edit.settingTransition(nil, at: 1)
    try require(removed.timeline.transitions.isEmpty && removed.timeline.video.map(\.start) == edit.timeline.video.map(\.start), "Removing a transition retains explicit clip positions")
    try require(edit.restoringStraightCut(at: 1).duration == original.duration, "Explicit straight-cut restoration recovers sequence duration")
    project.commit(edit); project.undo()
    var reopened = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project)); reopened.redo(); try reopened.validate()
    try require(reopened.edit == edit, "Transition parameters and undo/redo survive reopening")
    try require(reopened.schemaVersion == 6, "Older builds reject transition projects instead of silently changing their running time")
    var longEdit = original
    for index in longEdit.clips.indices { longEdit.clips[index].speed = SpeedSettings(rate: 0.25) }
    longEdit = longEdit.settingTransition(ClipTransition(duration: 12), at: 1)
    try require(longEdit.layout.joins[1].maximum == 16 && longEdit.duration == 20, "Transitions extend beyond ten seconds up to available footage")
    var longProject = project; longProject.commit(longEdit); longProject.undo()
    var longReopened = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(longProject)); longReopened.redo(); try longReopened.validate()
    try require(longReopened.edit == longEdit, "Long transition settings and Undo/Redo survive reopening")
    try require(longEdit.restoringStraightCut(at: 1).duration == 32, "Removing a long overlap restores all footage")
    var reordered = edit; reordered.clips.swapAt(0, 1); reordered = reordered.normalizedTools()
    try require(reordered.timeline.transitions == edit.timeline.transitions, "Reordering payload storage never reassigns a transition or changes participant identity")
    var trimmed = edit; trimmed.clips[0].end = 0.5
    try require(trimmed.timeline.transitions.isEmpty, "A trim that removes required transition handles removes the invalid relation")
    trimmed.clips[0].end = 4; try require(trimmed.timeline.transitions.isEmpty, "Extending does not resurrect removed transitions")
    var fade = dissolve; fade.style = .fadeColor
    let faded = original.settingTransition(fade, at: 1)
    try require(faded.duration == 8 && faded.layout.joins[1].range == 3.5...4.5, "Fade through black retains timeline length")
    var ends = original.settingTransition(ClipTransition(duration: 1), at: 0)
    ends = ends.settingTransition(ClipTransition(duration: 1), at: 2)
    try require(ends.duration == 8 && ends.layout.joins[0].range == 0...1 && ends.layout.joins[2].range == 7...8, "Black opening/closing retain the whole project")
    var chain = original
    var third = original.clips[0]; third.id = UUID(); chain.clips.append(third)
    chain = chain.settingTransition(ClipTransition(duration: 3), at: 1).settingTransition(ClipTransition(duration: 3), at: 2)
    let layout = chain.layout
    try require(layout.placements[1].incoming + layout.placements[1].outgoing <= 4.000001, "Adjacent transitions never require three simultaneous clips")
    try require(layout.joins[1].range.upperBound <= layout.joins[2].range.lowerBound + 0.000001, "Transition windows never cross")
    let badScope = TimelineEditing.scoped(edit, range: 3.2...5)
    try require(badScope.1.isEmpty && badScope.0 == edit, "A selection inside overlap cannot silently modify excess footage")
    var offGrid = original; offGrid.clips[0].end = 0.517
    var pastedClip = original.clips[0]; pastedClip.end = 0.3
    let pasted = TimelineEditing.inserting([pastedClip], into: offGrid, at: 1)
    let afterDelete = TimelineEditing.removing(1...1.3, from: pasted)
    try require(abs(afterDelete.duration - offGrid.duration) < 0.00001, "Paste then Delete near off-grid clip boundaries restores exact duration")
    let nearCut = TimelineEditing.removing(0.517 + 0.001...offGrid.duration - 0.001, from: offGrid)
    try require(nearCut.clips.count == 1 && abs(nearCut.duration - 0.517) < 0.00001, "Selection endpoints within a frame of a cut keep existing deletion behavior")

    let canvas = CGSize(width: 160, height: 90), bounds = CGRect(origin: .zero, size: canvas)
    let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: bounds)
    let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: bounds)
    let context = CIContext()
    func pixel(_ image: CIImage, _ x: Int, _ y: Int) -> [UInt8] {
        var rgba = [UInt8](repeating: 0, count: 4)
        context.render(image, toBitmap: &rgba, rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return rgba
    }
    var pair = dissolve; pair.style = .split; pair.divider = 0.35
    var result = TransitionRenderer.composite(red, blue, settings: pair, progress: 0.5, canvas: canvas)
    try require(pixel(result, 20, 40)[0] > 240 && pixel(result, 100, 40)[2] > 240, "Split screen puts outgoing left and incoming right")
    pair.axis = .vertical
    result = TransitionRenderer.composite(red, blue, settings: pair, progress: 0.5, canvas: canvas)
    try require(pixel(result, 50, 80)[0] > 240 && pixel(result, 50, 20)[2] > 240, "Vertical split uses outgoing top and incoming bottom")
    let black = TransitionRenderer.composite(red, blue, settings: fade, progress: 0.5, canvas: canvas)
    try require(pixel(black, 40, 40).prefix(3).allSatisfy { $0 < 2 }, "Fade through black midpoint is black")
    let oldFade = try JSONDecoder().decode(ClipTransition.self, from: JSONEncoder().encode(fade))
    try require(oldFade.resolvedFadeColor == .black && oldFade.style.rawValue == "fadeBlack", "Existing black fades decode unchanged")
    var coloredFade = fade; coloredFade.fadeColor = TransitionColor(red: 0.1, green: 0.8, blue: 0.2)
    let colored = pixel(TransitionRenderer.composite(red, blue, settings: coloredFade, progress: 0.5, canvas: canvas), 40, 40)
    try require(colored[1] > 180 && colored[0] < 50 && colored[2] < 80, "Color fade midpoint uses the selected sRGB color")
    var colorProject = project; let colorEdit = original.settingTransition(coloredFade, at: 1); colorProject.commit(colorEdit); colorProject.undo()
    var colorReopened = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(colorProject)); colorReopened.redo(); try colorReopened.validate()
    try require(colorReopened.edit == colorEdit && colorReopened.schemaVersion == 6, "Custom colors persist and older apps cannot silently discard them")
    var wipe = ClipTransition(style: .wipe, duration: 1); wipe.hardEdge = true; wipe.wipeAngle = 45
    let diagonal = TransitionRenderer.composite(red, blue, settings: wipe, progress: 0.5, canvas: canvas)
    try require(pixel(diagonal, 20, 80)[2] > 240 && pixel(diagonal, 140, 10)[0] > 240, "Hard wipe follows its configured diagonal")
    var hitchcock = ClipTransition(style: .hitchcock, duration: 1)
    let dark = CIImage(color: CIColor(red: 0.1, green: 0.1, blue: 0.1)).cropped(to: CGRect(x: 0, y: 0, width: 80, height: 90))
    let bright = CIImage(color: CIColor(red: 3, green: 3, blue: 3)).cropped(to: bounds)
    let brightness = dark.composited(over: bright)
    let shadows = TransitionRenderer.composite(brightness, blue, settings: hitchcock, progress: 0.5, canvas: canvas)
    try require(pixel(shadows, 20, 40)[2] > 240 && pixel(shadows, 120, 40)[0] > 240, "Hitchcock reveals shadows before highlights")
    let late = TransitionRenderer.composite(brightness, blue, settings: hitchcock, progress: 0.99, canvas: canvas)
    try require(pixel(late, 120, 40)[0] < 4, "HDR highlights reveal before the final frame, without a last-frame pop")
    hitchcock.highlightsFirst = true
    let highlights = TransitionRenderer.composite(brightness, blue, settings: hitchcock, progress: 0.5, canvas: canvas)
    try require(pixel(highlights, 120, 40)[0] < 4 && pixel(highlights, 20, 40)[2] < 100, "Hitchcock reverses to highlights first")
    let flashes = ClipTransition(style: .flashCut, duration: 1)
    for frame in 0..<30 {
        let image = TransitionRenderer.composite(red, blue, settings: flashes, progress: Double(frame) / 30, canvas: canvas)
        let isBlue = pixel(image, 40, 40)[2] > 240
        try require(isBlue == flashes.flashFrames(duration: 1).contains(frame), "Flash Cut uses exact single frames of the next scene")
    }
    var edgeHold = ClipTransition(style: .fadeColor, duration: 1); edgeHold.hold = 10
    let edgeLayout = original.settingTransition(edgeHold, at: 0).settingTransition(dissolve, at: 1).layout
    try require(edgeLayout.joins[0].range.upperBound <= edgeLayout.joins[1].range.lowerBound + 0.000001, "Opening color holds cannot collide with the next transition")
    print("TRANSITIONS: timing, identity, history, short clips, split geometry and safe edits passed")
    if CommandLine.arguments.contains("--core-only") { return }

    let folder = root.appendingPathComponent("transitions", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for filename in ["source.mp4", "portrait.mp4", "silent.mp4"] { try FileManager.default.copyItem(at: root.appendingPathComponent(filename), to: folder.appendingPathComponent(filename)) }
    func rgba(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { memory in
            let c = CGContext(data: memory.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }
    for style in TransitionStyle.allCases {
        var settings = dissolve; settings.style = style; settings.divider = 0.35; settings.first = TransitionFraming(x: 0.2, y: 0.6, zoom: 1.5); settings.second = TransitionFraming(x: 0.8, y: 0.4, zoom: 1.2)
        if style == .fadeColor { settings.fadeColor = coloredFade.fadeColor }
        var state = original.settingTransition(settings, at: 1)
        state.clips[0].color = ColorSettings(look: .warm, amount: 0.5)
        state.clips[1].mirror = MirrorSettings(horizontal: true)
        let title = TextOverlay(text: "Shared title", start: 0, end: 4, x: 0.5, y: 0.2, size: 0.07)
        state.clips[0].texts = [title]; state.clips[1].texts = [title]
        var candidate = project; candidate.commit(state)
        let media = try await MediaRenderer.timeline(project: candidate, folder: folder)
        let output = folder.appendingPathComponent(style.rawValue + ".mp4")
        _ = try await MediaRenderer.render(project: candidate, folder: folder, destination: output) { _ in }
        let export = AVURLAsset(url: output), duration = try await export.load(.duration).seconds
        try require(abs(duration - state.duration) < 0.04, "\(style) export duration matches editor")
        let preview = AVAssetImageGenerator(asset: media.composition); preview.videoComposition = media.videoComposition
        let exported = AVAssetImageGenerator(asset: export); exported.appliesPreferredTrackTransform = true
        for generator in [preview, exported] { generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero }
        let join = state.layout.joins[1]
        for time in [join.range.lowerBound - 0.1, join.time - 0.2, join.time + 0.2, join.range.upperBound + 0.1] {
            let stamp = CMTime(seconds: time, preferredTimescale: 60000)
            let p = try await preview.image(at: stamp).image, e = try await exported.image(at: stamp).image
            let a = rgba(p), b = rgba(e)
            try require(a.count == b.count, "Transition export keeps canvas dimensions")
            let difference = zip(a, b).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(a.count)
            try require(difference < 9, "\(style) preview matches export at \(time): \(difference)")
        }
        let pcm = folder.appendingPathComponent(style.rawValue + ".caf")
        _ = try await MediaRenderer.processedAudio(asset: media.composition, duration: duration, effects: [], outputURL: pcm, mix: media.audioMix) { _ in }
        let file = try AVAudioFile(forReading: pcm, commonFormat: .pcmFormatFloat32, interleaved: false)
        try require(abs(Double(file.length) / 48000 - duration) < 0.04, "Transition audio retains full timeline length")
        file.framePosition = Int64((join.time + 0.2) * 48000)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 2400)!; try file.read(into: buffer)
        let values = buffer.floatChannelData![0]
        let rms = sqrt((0..<Int(buffer.frameLength)).reduce(0.0) { $0 + Double(values[$1] * values[$1]) } / Double(buffer.frameLength))
        try require(rms > 0.005, "\(style) audio is audible through the transition")
        print("TRANSITIONS: \(style) preview/export match, \(duration)s, audio RMS \(rms)")
    }
    var combined = original.settingTransition(dissolve, at: 1)
    combined.clips[0].speed = SpeedSettings(rate: 2)
    combined.clips[1].pauses = PauseSettings(cuts: [SourceInterval(start: 1, end: 1.5)])
    combined = combined.settingTransition(ClipTransition(duration: 0.3), at: 0).settingTransition(ClipTransition(duration: 0.3), at: 2)
    var mixed = project; mixed.commit(combined)
    let output = folder.appendingPathComponent("combined.mp4")
    _ = try await MediaRenderer.render(project: mixed, folder: folder, destination: output) { _ in }
    let duration = try await AVURLAsset(url: output).load(.duration).seconds
    try require(abs(duration - combined.duration) < 0.04, "Speed, Pauses and opening/closing transitions compose without timing drift")
    print("TRANSITIONS: combined Speed/Pauses/start/end render passed")
    try await fractionalTransitionTests(project: project, folder: folder)
    try await expandedTransitionTests(project: project, root: root, folder: folder)
}

func assertTransitionCoverage(_ media: TimelineMedia, duration: Double) async throws {
    var cursor = CMTime.zero
    for instruction in media.videoComposition.instructions {
        try require(instruction.timeRange.start == cursor && instruction.timeRange.duration > .zero, "Transition instructions cover every tick without gaps or zero-length ranges")
        if let transition = instruction as? TransitionVideoInstruction {
            try require(transition.layers.count <= 2 && (!transition.layers.isEmpty || transition.join != nil), "At most two layers, or an explicit solid/frozen transition interval")
            if transition.layers.count == 2 { try require(transition.join != nil, "Every overlapping tick is blended, including half-tick boundaries") }
        }
        cursor = instruction.timeRange.end
    }
    let endpoint = media.videoComposition.instructions.first is TrackVideoInstruction ? TrackRenderer.time(EditTime(duration)) : TransitionRenderer.time(duration)
    try require(cursor == endpoint, "Transition instructions end at the canonical absolute project endpoint")
    let valid = try await media.videoComposition.isValid(for: media.composition, timeRange: CMTimeRange(start: .zero, end: cursor), validationDelegate: nil)
    try require(valid, "AVFoundation accepts the complete transition composition")
}

func fractionalTransitionTests(project: Project, folder: URL) async throws {
    // Four cuts from one source: an overlap, an ordinary cut, then a fade.
    // Subtraction produces fractional ticks even though the visible cuts are
    // frame-derived. The previous renderer reported this valid edit as corrupt.
    let cuts = [0.0, 6.066666666666666 / 5, 11.233333333333333 / 5, 14.866666666666665 / 5, 18.025 / 5]
    var candidate = project
    let clips = zip(cuts, cuts.dropFirst()).map { a, b in TimelineClip(sourceID: project.sources[0].id, start: a, end: b) }
    let initial = EditState(clips: clips).settingTransition(ClipTransition(duration: 4.3 / 5), at: 1)
        .settingTransition(ClipTransition(style: .fadeColor, duration: 0.1), at: 3)
    candidate.commit(initial)
    let media = try await MediaRenderer.timeline(project: candidate, folder: folder)
    try await assertTransitionCoverage(media, duration: candidate.edit.duration)
    let generator = AVAssetImageGenerator(asset: media.composition); generator.videoComposition = media.videoComposition
    generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
    for time in stride(from: 0.0, to: candidate.edit.duration - 1.0 / 30, by: 1.0 / 30) {
        _ = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 60000))
    }
    let output = folder.appendingPathComponent("fractional-transitions.mp4")
    _ = try await MediaRenderer.render(project: candidate, folder: folder, destination: output) { _ in }
    let exportedDuration = try await AVURLAsset(url: output).load(.duration).seconds
    try require(abs(exportedDuration - candidate.edit.duration) < 1.0 / 30, "Fractional multi-transition export retains the complete timeline")
    for style in TransitionStyle.allCases {
        for duration in [1.0 / 30, 0.137, 0.511118, 1.013, 10] {
            var edit = initial.settingTransition(ClipTransition(style: style, duration: duration), at: 2)
            edit.clips[0].speed = SpeedSettings(rate: 1.3)
            edit.clips[3].pauses = PauseSettings(cuts: [SourceInterval(start: cuts[3] + 0.123456, end: cuts[3] + 0.345678)])
            edit = edit.settingTransition(ClipTransition(duration: duration), at: 0).settingTransition(ClipTransition(duration: duration), at: 4)
            candidate.commit(edit)
            let media = try await MediaRenderer.timeline(project: candidate, folder: folder)
            try await assertTransitionCoverage(media, duration: edit.duration)
        }
    }
    print("TRANSITIONS: fractional multi-join playback/export and all-style duration/speed/pause coverage passed")
}

// Optional local reproduction; neither the document nor its sources are written.
func transitionProjectRegression(folder: URL) async throws {
    let original = try JSONDecoder().decode(Project.self, from: Data(contentsOf: folder.appendingPathComponent("project.json")))
    let before = try Data(contentsOf: folder.appendingPathComponent("project.json"))
    let media = try await MediaRenderer.timeline(project: original, folder: folder, canvasSize: CGSize(width: 160, height: 90))
    try await assertTransitionCoverage(media, duration: original.edit.duration)
    for boundary in original.edit.layout.joins.indices {
        let indices = boundary == 0 ? [0] : boundary == original.edit.clips.count ? [boundary - 1] : [boundary - 1, boundary]
        let clips = indices.map { index in var clip = original.edit.clips[index]; clip.transition = nil; clip.openingTransition = nil; return clip }
        for style in TransitionStyle.allCases {
            for duration in [1.0 / 30, 0.1, 0.5, 1, 2, 3, 4.3, 10] {
                var project = original
                project.history = [EditState(clips: clips).settingTransition(ClipTransition(style: style, duration: duration), at: boundary == 0 ? 0 : 1)]; project.historyCursor = 0
                do {
                    let media = try await MediaRenderer.timeline(project: project, folder: folder, canvasSize: CGSize(width: 160, height: 90))
                    try await assertTransitionCoverage(media, duration: project.edit.duration)
                    var full = original; full.commit(original.edit.settingTransition(ClipTransition(style: style, duration: duration), at: boundary))
                    let timeline = try await MediaRenderer.timeline(project: full, folder: folder, canvasSize: CGSize(width: 160, height: 90))
                    try await assertTransitionCoverage(timeline, duration: full.edit.duration)
                }
                catch { print("TRANSITION REPRO: boundary=\(boundary) style=\(style) duration=\(duration) effective=\(project.edit.duration) clips=\(clips.map(\.duration))"); throw error }
            }
        }
    }
    let after = try Data(contentsOf: folder.appendingPathComponent("project.json"))
    try require(before == after, "Transition reproduction leaves the project unchanged")
    print("TRANSITIONS: local project and all join previews built successfully")
}

func expandedTransitionTests(project: Project, root: URL, folder: URL) async throws {
    var base = project
    let sourceA = project.sources[0]
    let sourceB = SourceMedia(filename: "next-scene.mp4", duration: 4)
    try FileManager.default.copyItem(at: root.appendingPathComponent(sourceB.filename), to: folder.appendingPathComponent(sourceB.filename))
    base.sources = [sourceA, sourceB]
    let clips = [TimelineClip(sourceID: sourceA.id, start: 0, end: 4), TimelineClip(sourceID: sourceB.id, start: 0, end: 4)]
    base.history = [EditState(clips: clips)]; base.historyCursor = 0
    let original = base.edit
    func candidate(_ settings: ClipTransition, boundary: Int = 1) -> Project {
        var p = base; p.commit(original.settingTransition(settings, at: boundary)); return p
    }
    var opening = original
    opening.timeline.unlink(opening.timeline.selection(of: opening.timeline.video[0].id))
    let starts = opening.timeline.video.map(\.start), soundStarts = opening.timeline.audio.map(\.start), originalDuration = opening.duration
    for offset in [-0.5, -0.2, 0.0, -0.5] {
        var settings = ClipTransition(duration: 1); settings.audioOffset = offset; settings.audioBlend = 0
        opening = opening.settingTransition(settings, at: 0)
        try require(opening.timeline.video.map(\.start) == starts && opening.timeline.audio.map(\.start) == soundStarts && opening.duration == originalDuration,
                    "Re-editing an opening J-cut stays anchored without gaps or detached audio drift")
    }
    var hold = ClipTransition(duration: 1); hold.hold = 2
    let held = candidate(hold), join = held.edit.layout.joins[1]
    try require(abs(held.edit.duration - 5) < 0.00001 && join.timing.progress(at: 1) == 0.5 && join.timing.progress(at: 2) == 0.5, "Midpoint hold adds to the moving overlap and retains the 50/50 mix")
    var color = hold; color.style = .fadeColor; color.fadeColor = TransitionColor(red: 0.2, green: 0.7, blue: 0.4)
    let plateau = candidate(color)
    try require(plateau.edit.duration == 10, "Solid color hold adds time without consuming footage")
    var freeze = ClipTransition(style: .still, duration: 2); freeze.stillDissolve = 0.5
    let still = candidate(freeze)
    try require(still.edit.duration == 10 && still.edit.layout.joins[1].videoRange == 4...6.5, "Still holds the final frame before dissolving into the next scene")
    try require(candidate(ClipTransition(style: .still, duration: 1), boundary: 0).edit.duration == 9, "Opening still holds black before source footage")
    try require(candidate(freeze, boundary: 2).edit.duration == 10.5, "Closing still includes the final fade to black")
    for p in [held, plateau, still] {
        let media = try await MediaRenderer.timeline(project: p, folder: folder)
        try await assertTransitionCoverage(media, duration: p.edit.duration)
        let j = p.edit.layout.joins[1]
        let generator = AVAssetImageGenerator(asset: media.composition); generator.videoComposition = media.videoComposition
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        func frame(_ time: Double) async throws -> CGImage { try await generator.image(at: TransitionRenderer.time(time)).image }
        let a = try await frame(j.origin + j.timing.motion / 2 + 0.2)
        let b = try await frame(j.origin + j.timing.motion / 2 + 0.6)
        func pixels(_ image: CGImage) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            bytes.withUnsafeMutableBytes { buf in
                let c = CGContext(data: buf.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            return bytes
        }
        let delta = zip(pixels(a), pixels(b)).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(a.width * a.height * 4)
        if p.edit.clips[0].transition?.style == .dissolve { try require(delta > 0.1, "Pictures keep moving during midpoint hold") }
        else { try require(delta < 0.01, "Color plateau and still hold remain visually constant") }
        if p.edit.clips[0].transition?.style == .still {
            let prior = try await frame(4 - 1.0 / 30)
            let difference = zip(pixels(a), pixels(prior)).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(a.width * a.height * 4)
            if difference >= 1 {
                try CIContext().writePNGRepresentation(of: CIImage(cgImage: a), to: folder.appendingPathComponent("still-held.png"), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                try CIContext().writePNGRepresentation(of: CIImage(cgImage: prior), to: folder.appendingPathComponent("still-prior.png"), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                print("STILL DIAGNOSTIC FOLDER: \(folder.path)")
            }
            print("STILL FRAME DIFFERENCE: \(difference), origin \(j.origin), range \(j.videoRange)")
            try require(difference < 1, "Still freezes the actual final visible frame of the outgoing clip")
        }
        let output = folder.appendingPathComponent("hold-" + UUID().uuidString + ".mp4")
        _ = try await MediaRenderer.render(project: p, folder: folder, destination: output) { _ in }
        let length = try await AVURLAsset(url: output).load(.duration).seconds
        try require(abs(length - p.edit.duration) < TimelineEditing.frame, "Hold export retains complete timeline length")
    }
    for style in TransitionStyle.allCases {
    for (offset, blend, frequency) in [(-1.0, 0.5, 500.0), (1.5, 0.5, 1000.0)] {
        var settings = ClipTransition(style: style, duration: 1); settings.audioOffset = offset; settings.audioBlend = blend
        let p = candidate(settings), layout = p.edit.layout, j = layout.joins[1]
        let media = try await MediaRenderer.timeline(project: p, folder: folder)
        try await assertTransitionCoverage(media, duration: p.edit.duration)
        try require(j.audioIn == j.audioOut, "Every style permits a continuous custom audio crossfade")
        let sampleTime = offset < 0 ? (j.audioIn.upperBound + j.videoRange.lowerBound) / 2 : (j.videoRange.upperBound + j.audioOut.lowerBound) / 2
        if offset < 0 { try require(j.audioIn.upperBound < j.videoRange.lowerBound, "J-cut finishes its audio blend before the picture transition") }
        else { try require(j.audioOut.lowerBound > j.videoRange.upperBound, "L-cut retains outgoing sound after the picture change") }
        let pcm = folder.appendingPathComponent("audio-offset-" + UUID().uuidString + ".caf")
        _ = try await MediaRenderer.processedAudio(asset: media.composition, duration: p.edit.duration, effects: [], outputURL: pcm, mix: media.audioMix) { _ in }
        let file = try AVAudioFile(forReading: pcm, commonFormat: .pcmFormatFloat32, interleaved: false)
        file.framePosition = Int64(sampleTime * 48000)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4800)!; try file.read(into: buffer)
        func energy(_ hz: Double) -> Double {
            let data = buffer.floatChannelData![0]
            var re = 0.0, im = 0.0
            for i in 0..<Int(buffer.frameLength) { let phase = 2 * Double.pi * hz * Double(i) / 48000; re += Double(data[i]) * cos(phase); im += Double(data[i]) * sin(phase) }
            return re * re + im * im
        }
        try require(energy(frequency) > energy(frequency == 500 ? 1000 : 500) * 100, "Correct scene's sound is audible independently of the picture change")
    }
    }
    // Deterministic varied footprints exercise both neighbors, off-grid cuts,
    // custom audio and added-time joins without exposing any private media.
    var seed: UInt64 = 71
    func random() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / 9007199254740992 }
    for run in 0..<90 {
        var edit = original; var third = clips[0]; third.id = UUID(); edit.clips.append(third)
        for i in edit.clips.indices { edit.clips[i].end = 0.2 + random() * 3.8 }
        for boundary in 0...edit.clips.count {
            let style = TransitionStyle.allCases[(run + boundary) % TransitionStyle.allCases.count]
            var settings = ClipTransition(style: style, duration: 0.1 + random() * 3)
            settings.hold = random() * 10; settings.audioOffset = random() * 4 - 2; settings.audioBlend = random() * 2
            if style == .still { settings.stillDissolve = random() }
            edit = edit.settingTransition(settings, at: boundary)
        }
        var p = base; p.commit(edit)
        do { try p.validate() } catch {
            let debug = folder.appendingPathComponent("invalid-random-\(run).json")
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(p).write(to: debug)
            print("INVALID TRANSITION RUN: \(run), \(debug.path)"); throw error
        }
        for placement in p.edit.layout.placements {
            let (incoming, outgoing) = p.edit.layout.joins(for: placement)
            try require(incoming.timing.rightCost + outgoing.timing.leftCost <= EditTime(placement.clip.duration).seconds + 1 / Double(EditTime.scale), "Long holds and custom sound fit available footage: run \(run), clip \(placement.index), incoming \(incoming.timing.rightCost), outgoing \(outgoing.timing.leftCost), duration \(placement.clip.duration)")
        }
        p.undo(); var reopened = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(p)); reopened.redo()
        try require(reopened.edit == edit && reopened.schemaVersion == 6, "All new transition settings survive saved Undo/Redo")
        p = reopened
        let media = try await MediaRenderer.timeline(project: p, folder: folder)
        try await assertTransitionCoverage(media, duration: p.edit.duration)
    }
    print("TRANSITIONS: moving midpoint hold, solid color, exact freeze, J/L audio isolation and varied footprints passed")
}
