import AVFoundation
import CoreText
import CoreImage
import ImageIO
import UniformTypeIdentifiers

private func compareDraftTitleColors(movie: String, hdr: Bool, captions: Bool, root: URL) async throws {
    var project = Project(title: "Title color comparison")
    project.append(SourceMedia(filename: movie, duration: 3))
    let size = CGSize(width: 640, height: 360)
    var text = TextOverlay(text: "MMMMMM", start: 0, end: 3, size: 0.2)
    var design = TitleDesign()
    design.plate = .block
    design.backing = TitleInk(0x916235)
    design.fill = TitleInk(0x4383ca)
    design.shadow = false
    text.appearance = design
    guard let bitmap = TextRasterizer.image(text, canvas: size) else { throw ProjectError.invalidMedia }
    var edit = project.edit, base = project
    if captions {
        edit.timeline.installSubtitles(SubtitleTiming.estimate("MMMMMM", speech: [0...3]), range: 0...3, language: "English")
        edit.timeline.subtitles?.appearance = design
        edit.timeline.subtitles?.size = 0.2
        edit.timeline.subtitles?.y = 0.5
        var empty = base.edit
        empty.timeline.subtitles = SubtitleSettings()
        base.commit(empty)
    } else {
        edit.clips[0].texts = [text]
    }
    let draft = try await MediaRenderer.timeline(project: base, folder: root, canvasSize: size, forceCustom: true)
    try require(draft.hdr == hdr, "Fixture transfer characteristic")
    if captions, let settings = edit.timeline.subtitles {
        let layout = SubtitleLayout(cues: edit.timeline.subtitleCues, settings: settings, canvas: size)
        guard let track = (draft.videoComposition.instructions.first as? TrackVideoInstruction)?.subtitles else { throw ProjectError.invalidMedia }
        track.updatePreview(layout: layout, settings: settings, canvas: size)
    } else {
        for instruction in draft.videoComposition.instructions {
            for layer in instruction.toolLayers { layer.previewTitle = .init(text: text, bitmap: bitmap, ranges: TitleMotionRanges()) }
        }
    }
    let inspector = AVAssetImageGenerator(asset: draft.composition)
    inspector.videoComposition = draft.playbackVideoComposition
    project.commit(edit)
    let url = root.appendingPathComponent(UUID().uuidString + ".mp4")
    defer { try? FileManager.default.removeItem(at: url) }
    _ = try await MediaRenderer.render(project: project, folder: root, destination: url) { _ in }
    let exported = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    let context = CIContext()
    let area = CGRect(origin: .zero, size: size)
    func colors(_ generator: AVAssetImageGenerator) async throws -> [UInt8] {
        let frame = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 30)).image
        var pixels = [UInt8](repeating: 0, count: 640*360*4)
        context.render(CIImage(cgImage: frame), toBitmap: &pixels, rowBytes: 640*4, bounds: area,
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return pixels
    }
    let timeline = try await MediaRenderer.timeline(project: project, folder: root, canvasSize: size)
    let applied = AVAssetImageGenerator(asset: timeline.composition)
    applied.videoComposition = timeline.playbackVideoComposition
    let preview = try await colors(inspector), editor = try await colors(applied), saved = try await colors(exported)
    try require(preview == editor, "The inspector and applied title must match pixel for pixel in " + movie)
    // 4:2:0 encoders mix chroma across sharp glyph boundaries. Measure solid
    // lettering and backing separately so a large plate cannot hide a font color shift.
    var errors = [[Int](), [Int]()]
    for y in 2..<358 {
        for x in 2..<638 {
            let i = (y*640+x)*4
            let color = Int(preview[i]) - Int(preview[i+2])
            guard abs(color) > 40 else { continue }
            let uniform = [-2, 2, -1280, 1280].allSatisfy { offset in
                (0..<3).allSatisfy { abs(Int(preview[i+$0])-Int(preview[i+offset*4+$0])) <= 2 }
            }
            if uniform {
                let error = (0..<3).map { abs(Int(preview[i+$0])-Int(saved[i+$0])) }.max()!
                errors[color > 0 ? 0 : 1].append(error)
            }
        }
    }
    for samples in errors {
        try require(samples.count > 1000 && samples.sorted()[samples.count/2] <= 3,
                    "The encoded title has a visibly different fill or backing color in " + movie)
    }
    print("PASS: " + (captions ? "subtitle" : "title") + " draft and applied frames match exactly, encoded colors agree in " + movie)
}

func titleDesignTests(root: URL) async throws {
    try overlayTimingTests()
    try await importedFontTests(root: root)
    for (movie, hdr) in [("title-black.mp4", false), ("title-hlg.mp4", true)] {
        for captions in [false, true] { try await compareDraftTitleColors(movie: movie, hdr: hdr, captions: captions, root: root) }
    }
    var design = TitleDesign()
    for family in TitleTypeface.families.dropFirst() {
        design.face = family.id
        for italic in family.slanted == nil ? [false] : [false, true] {
            design.italic = italic
            for weight in family.weights {
                design.weight = weight
                let font = TitleTypeface.font(design, size: 64)
                let name = CTFontCopyPostScriptName(font) as String
                try require(
                    !name.contains("LastResort") && !name.contains("Times") && !name.contains("Helvetica"),
                    "Font fallback for " + family.name)
                let url = CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL
                try require(
                    url?.path.contains("TitleFonts/") == true,
                    "An unbundled font was substituted for " + family.name + " / " + name)
            }
        }
    }
    design = TitleDesign()
    design.face = "archivoblack"
    design.shadow = false
    design.outlined = true
    design.border = TitleInk(0x00ff00)
    design.borderWidth = 0.10
    design.gradient = TitleGradient(0xff0000, 0x0000ff, 0)
    let look = design.applyingLook(TitleDesign.looks[1].design)
    try require(
        look.outlined && look.border == design.border && look.borderWidth == design.borderWidth,
        "Looks changed the independent outline")
    func pixels(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        data.withUnsafeMutableBytes { raw in
            let ctx = CGContext(
                data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return data
    }
    func colors(_ image: CGImage) -> (red: Int, green: Int, blue: Int) {
        let bytes = pixels(image)
        var n = (0, 0, 0)
        for i in stride(from: 0, to: bytes.count, by: 4) where bytes[i + 3] > 140 {
            let r = Int(bytes[i])
            let g = Int(bytes[i + 1])
            let b = Int(bytes[i + 2])
            if r > g + 70 && r > b + 30 { n.0 += 1 }
            if g > r + 70 && g > b + 70 { n.1 += 1 }
            if b > g + 70 && b > r + 30 { n.2 += 1 }
        }
        return n
    }
    var title = TextOverlay(text: "HORIZON", start: 0, end: 1.5, size: 0.18)
    title.appearance = design
    let canvas = CGSize(width: 640, height: 360)
    guard let bitmap = TextRasterizer.image(title, canvas: canvas) else { throw ProjectError.invalidMedia }
    let full = colors(bitmap)
    try require(
        min(full.red, full.green, full.blue) > 100,
        "Title is missing a gradient end or its outline: " + String(describing: full))
    var hollow = title
    hollow.appearance?.gradient = nil
    hollow.appearance?.fill = TitleInk(0, alpha: 0)
    guard let ring = TextRasterizer.image(hollow, canvas: canvas) else { throw ProjectError.invalidMedia }
    let ringPixels = colors(ring).green
    try require(
        abs(ringPixels - full.green) < max(100, full.green / 10), "Transparent fill exposed the interior of the stroke")
    var motion = TitleMotion()
    motion.entrance = .fade
    motion.exit = .wipe
    motion.inSeconds = 0.75
    motion.outSeconds = 0.75
    for t in [0.13, 0.15, 0.17] {
        let pose = motion.pose(at: t, duration: 0.30)
        try require(pose.opacity == 1 && pose.left == 0, "Short title lost its readable hold")
    }
    for mode in TitleMove.allCases where mode != .none {
        var m = TitleMotion()
        m.entrance = mode
        m.exit = mode
        let t = 0.15
        let early = m.pose(at: t, duration: 2)
        let late = m.pose(at: 2 - t, duration: 2)
        let mid = m.pose(at: 1, duration: 2)
        try require(mid.opacity == 1 && mid.scale == 1 && mid.left == 0 && mid.right == 1, "Unstable title hold")
        if mode == .wipe {
            try require(early.right < 1 && late.left > 0, "Wipe does not reveal and erase")
        } else {
            try require(early.opacity < 1 && late.opacity < 1, "Animation missing on one end")
        }
    }
    title.motion = motion
    var project = Project(title: "Animated title across a cut")
    project.append(SourceMedia(filename: "title-black.mp4", duration: 3))
    let source = project.sources[0].id
    var a = TimelineClip(sourceID: source, start: 0, end: 1.5)
    var b = TimelineClip(sourceID: source, start: 0, end: 1.5)
    a.texts = [title]
    b.texts = [title]
    project.commit(EditState(clips: [a, b]))
    try project.validate()
    let decoded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
    try require(decoded.edit.clips[0].texts?.first == title, "Saved title design or motion failed to round-trip")
    try require(
        TitleMotionRanges(decoded.edit).range(for: title, at: 1.5) == 0...3, "Title does not span its two source fragments")
    var edited = decoded.edit
    var different = title
    different.motion?.exit = .drift
    edited.timeline.video[1].content.texts = [different]
    let independent = TitleMotionRanges(edited)
    try require(
        independent.range(for: title, at: 1) == 0...1.5 && independent.range(for: different, at: 2) == 1.5...3,
        "Editing motion on one side of a cut changed the other")
    var separated = decoded.edit
    separated.timeline.video[1].start = EditTime(2)
    let parted = TitleMotionRanges(separated)
    try require(
        parted.range(for: title, at: 1.6) == nil && parted.range(for: title, at: 2.5) == 2...3.5,
        "Title motion ran through an empty gap")
    let timeline = try await MediaRenderer.timeline(project: decoded, folder: root, canvasSize: canvas)
    let preview = AVAssetImageGenerator(asset: timeline.composition)
    preview.videoComposition = timeline.playbackVideoComposition
    let url = root.appendingPathComponent("title-export-" + UUID().uuidString + ".mp4")
    _ = try await MediaRenderer.render(project: decoded, folder: root, destination: url) { _ in }
    let encoded = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    encoded.appliesPreferredTrackTransform = true
    for gen in [preview, encoded] {
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        var measurements = [Int]()
        for t in [0.0, 0.3, 1.45, 1.5, 2.7, 2.96] {
            let im = try await gen.image(at: CMTime(seconds: t, preferredTimescale: 60000)).image
            let n = colors(im)
            measurements.append(n.red + n.green + n.blue)
        }
        let n = measurements
        try require(
            n[0] < 50 && n[1] > 100 && n[2] > 1000 && abs(n[2] - n[3]) < n[2] / 8 && n[4] < n[3] && n[5] < n[4] / 4,
            "Incorrect entrance, cut boundary or exit in rendered frames: " + String(describing: n))
        print("Title frame pixel counts: " + String(describing: n))
    }
    var captions = SubtitleSettings()
    captions.appearance = design
    captions.motion = motion
    let cues = [
        SubtitleCue(id: "short", audioID: UUID(), wordIDs: [], text: "Hi", start: 0, end: 1),
        SubtitleCue(
            id: "long", audioID: UUID(), wordIDs: [],
            text: "È già l’ora di parlare di quello che abbiamo visto sulla strada.", start: 1, end: 3),
    ]
    let layout = SubtitleLayout(cues: cues, settings: captions, canvas: CGSize(width: 360, height: 640))
    try require(layout.containsEveryCharacter, "Styled subtitles truncated a line")
    captions.size = 0.30
    captions.x = 1
    captions.y = 0
    for t in [0.01, 0.5, 1.2, 2.8] {
        let frames = layout.frames(at: t, settings: captions, output: CGSize(width: 360, height: 640))
        try require(
            !frames.isEmpty && frames.allSatisfy { CGRect(x: 0, y: 0, width: 1, height: 1).contains($0.rect) },
            "Animated subtitle exceeded the video")
    }
    for canvas in [CGSize(width: 360, height: 640), CGSize(width: 640, height: 360)] {
        for d in TitleDirection.allCases {
            var travel = TitleMotion()
            travel.entrance = .drift
            travel.inDirection = d
            captions.motion = travel
            let layout = SubtitleLayout(cues: cues, settings: captions, canvas: canvas)
            for corner in [0.0, 1.0] {
                captions.x = corner
                captions.y = corner
                let frames = layout.frames(at: 1.01, settings: captions, output: canvas)
                try require(
                    frames.count == 1 && CGRect(x: 0, y: 0, width: 1, height: 1).contains(frames[0].rect),
                    "Drift moved a caption beyond the canvas")
            }
            travel.entrance = .wipe
            let before = travel.pose(at: 0.1, duration: 2)
            switch d {
            case .up: try require(before.top > 0 && before.bottom == 1, "Up wipe")
            case .down: try require(before.top == 0 && before.bottom < 1, "Down wipe")
            case .left: try require(before.left > 0 && before.right == 1, "Left wipe")
            case .right: try require(before.left == 0 && before.right < 1, "Right wipe")
            }
        }
    }
    print("Title font, layout, outline, motion, persistence and export checks passed")
}

private func overlayTimingTests() throws {
    let frame = TimelineEditing.frame
    var timing = OverlayTiming(range: 3.125...6.125, bounds: 1.25...70.38)
    for seconds in EditorDurationPresets.wholeSeconds {
        try require(EditorDurationPresets.fits(seconds, within: timing.available), "Expected a usable duration preset")
        timing.set(.end, to: timing.range.lowerBound + seconds)
        try require(timing.range == 3.125...(3.125 + seconds), "Preset moved Start or rounded the duration")
    }
    timing.set(.start, to: 62)
    try require(!EditorDurationPresets.fits(9, within: timing.available) && EditorDurationPresets.fits(8, within: timing.available), "Overlong presets must not change Start")
    timing.set(.end, to: timing.time(at: 1, edge: .end))
    try require(timing.range.upperBound == timing.bounds.upperBound, "A fractional final boundary must be reachable")
    timing.set(.end, to: timing.time(at: 0, edge: .end))
    try require(abs(timing.duration - frame) < 0.000001, "Dragging End past Start must preserve a frame")
    for length in [0.0, frame / 2, frame, frame * 1.4] {
        let bounds = 8.125...(8.125 + length)
        var short = OverlayTiming(range: bounds, bounds: bounds)
        for edge in [OverlayTiming.Edge.start, .end] {
            for fraction in [0.0, 0.1, 0.95, 1.0] {
                short.set(edge, to: short.time(at: fraction, edge: edge))
                try require(bounds.contains(short.range.lowerBound) && bounds.contains(short.range.upperBound)
                            && short.duration + 0.000001 >= min(length, frame), "Tiny trim range exceeded its bounds")
            }
        }
    }
}

private func importedFontTests(root: URL) async throws {
    let fm = FileManager.default
    let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Fonts")
    let scratch = root.appendingPathComponent("fonts-" + UUID().uuidString)
    let library = ImportedFonts(root: scratch.appendingPathComponent("Library"))
    let disk = ProjectDisk(root: scratch.appendingPathComponent("Projects"))
    let ttf = try library.add(fixtures.appendingPathComponent("YouRec-QA-Triangle.ttf"))
    let otf = try library.add(fixtures.appendingPathComponent("YouRec-QA-Ink.otf"))
    let ttc = try library.add(fixtures.appendingPathComponent("YouRec-QA-Triangle-Family.ttc"))
    let otc = try library.add(fixtures.appendingPathComponent("YouRec-QA-Ink-Family.otc"))
    try require(ttf.file.faces.count == 1 && otf.file.faces.count == 1 && ttc.file.faces.count == 2 && otc.file.faces.count == 2, "All four native formats and every face in a collection")
    let renamed = scratch.appendingPathComponent("Same font.ttf")
    try fm.copyItem(at: fixtures.appendingPathComponent(ttf.file.filename), to: renamed)
    let again = try library.add(renamed)
    try require(!again.added && again.file == ttf.file, "Duplicate font bytes under a different filename")
    try Data("invalid".utf8).write(to: renamed)
    do { _ = try library.add(renamed); throw NSError(domain: "Expected invalid font", code: 1) } catch ImportedFonts.LibraryError.invalid {}
    let cold = ImportedFonts(root: scratch.appendingPathComponent("Library"))
    let files = try cold.files()
    try require(files.count == 4, "Library survives reopening and a bad input adds nothing")
    for file in files {
        for face in file.faces {
            let resolved = cold.font(face.id, size: 40, weight: 400, folder: nil)
            try require(resolved.map { CTFontCopyPostScriptName($0) as String } == ImportedFontFace.Reference(face.id)?.postScriptName, "Correct collection face loaded")
        }
    }
    let variable = try library.add(root.appendingPathComponent("TitleFonts/caveat/Caveat[wght].ttf")).file.faces[0]
    let light = library.font(variable.id, size: 40, weight: 400, folder: nil)!
    let heavy = library.font(variable.id, size: 40, weight: 700, folder: nil)!
    try require(variable.weights.contains(700) && (CTFontCopyVariation(light) as NSDictionary?) != (CTFontCopyVariation(heavy) as NSDictionary?), "Imported variable weight affects the actual font")

    var project = Project(title: "Imported lettering")
    let media = SourceMedia(filename: "title-black.mp4", duration: 3)
    project.append(media)
    let folder = disk.folder(project.id)
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    try fm.copyItem(at: root.appendingPathComponent(media.filename), to: folder.appendingPathComponent(media.filename))
    var edit = project.edit
    var title = TextOverlay(text: "ABC", start: 0, end: 3, x: 0.5, y: 0.22, size: 0.16)
    var design = TitleDesign(); design.face = ttf.file.faces[0].id; design.shadow = false
    title.appearance = design; edit.timeline.video[0].content.texts = [title]
    edit.timeline.installSubtitles(SubtitleTiming.estimate("ABC", speech: [0...3]), range: 0...3, language: "English")
    var captionDesign = design; captionDesign.face = otc.file.faces[1].id
    edit.timeline.subtitles?.appearance = captionDesign
    project.commit(edit)
    try library.preserve(edit.importedFontFiles, in: folder)
    try disk.save(project)
    try library.remove(ttf.file); try library.remove(otc.file)
    try require(library.face(design.face, folder: nil) == nil && cold.face(design.face, folder: nil) == nil, "Removal frees the library source")
    for id in [design.face, captionDesign.face] {
        let name = ImportedFontFace.Reference(id)!.postScriptName
        try require(library.font(id, size: 32, weight: 400, folder: folder).map { CTFontCopyPostScriptName($0) as String } == name, "Project owns the face after removal")
    }
    project.undo()
    let copy = try await ProjectArchive.duplicate(project, in: disk, title: "Font history copy") { _ in }
    let zip = scratch.appendingPathComponent("editable.zip")
    try await ProjectArchive.export(copy, folder: disk.folder(copy.id), destination: zip) { _ in }
    var restored = try await ProjectArchive.restore(zip, disk: disk) { _ in }
    try disk.moveToDeleted(project); try disk.eraseDeleted(project.id)
    restored.redo()
    let target = disk.folder(restored.id)
    try require(restored.fontFiles.count == 2 && restored.fontFiles.allSatisfy { fm.fileExists(atPath: target.appendingPathComponent($0).path) }, "Undo-only fonts survive duplication and ZIP restore")
    let final = scratch.appendingPathComponent("lettering.mp4")
    _ = try await MediaRenderer.render(project: restored, folder: target, destination: final) { _ in }
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: final))
    let image = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
    let output = try fontTestPixels(image)
    // Each original fixture maps A, B and C to the same geometric glyph.
    // Compare both the title and caption against an independently rendered
    // composition with the selected fonts unavailable.
    let missingFolder = scratch.appendingPathComponent("MissingFonts")
    try fm.createDirectory(at: missingFolder, withIntermediateDirectories: true)
    try fm.copyItem(at: target.appendingPathComponent(media.filename), to: missingFolder.appendingPathComponent(media.filename))
    let fallbackMedia = try await MediaRenderer.timeline(project: restored, folder: missingFolder)
    let fallbackGenerator = AVAssetImageGenerator(asset: fallbackMedia.composition)
    fallbackGenerator.videoComposition = fallbackMedia.videoComposition
    let fallback = try await fallbackGenerator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
    let other = try fontTestPixels(fallback)
    let half = output.count / 2
    for region in [0..<half, half..<output.count] {
        let changed = region.reduce(0) { $0 + (abs(Int(output[$1]) - Int(other[$1])) > 65 ? 1 : 0) }
        try require(changed > 90, "An exported title and an exported subtitle both use the imported glyphs")
    }
    print("Imported TTF/OTF/TTC/OTC, variable weights, redo, ZIP restore and exported title/subtitle pixels passed")
}

private func fontTestPixels(_ image: CGImage) throws -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: image.width * image.height)
    try pixels.withUnsafeMutableBytes { bytes in
        guard let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { throw ProjectError.invalidMedia }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return pixels
}
