import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import CoreText

func subtitleTests(root: URL) async throws {
    let speech = [0.2...2.0, 4.0...7.0, 9.0...11.0]
    let words = SubtitleTiming.estimate("Here is the first sentence. Then another sentence arrives. Finally we finish.", speech: speech)
    try require(!words.isEmpty && words.allSatisfy { word in speech.contains { word.start >= $0.lowerBound && word.end <= $0.upperBound } }, "Word estimates never bridge a silence")
    try require(zip(words, words.dropFirst()).allSatisfy { $0.end <= $1.start + 0.000001 }, "Word estimates are ordered")
    let corrected = SubtitleTiming.corrected(Array(words.prefix(4)), text: "Here is a replacement")
    try require(corrected.prefix(2).map(\.start) == words.prefix(2).map(\.start), "Unchanged words retain timing after correction")
    try require(corrected.allSatisfy { $0.start >= words[0].start && $0.end <= words[3].end }, "Corrected words stay within their phrase")
    let punctuated = SubtitleTiming.corrected(Array(words.prefix(3)), text: "Here, is the!")
    try require(punctuated.map(\.start) == words.prefix(3).map(\.start) && punctuated.map(\.end) == words.prefix(3).map(\.end), "Punctuation corrections retain timings exactly")
    let inserted = SubtitleTiming.corrected(Array(words.prefix(2)), text: "Here really is")
    try require(inserted.count == 3 && zip(inserted, inserted.dropFirst()).allSatisfy { $0.end <= $1.start + 0.000001 }, "Inserted words borrow bounded timing without overlaps")
    let silence = SubtitleSpeechPlan.chunks(levels: Array(repeating: 0, count: 2000), duration: 40)
    try require(silence.isEmpty, "Silence does not invoke ASR")
    let continuous = SubtitleSpeechPlan.chunks(levels: Array(repeating: 0.1, count: 5000), duration: 100)
    try require(continuous.count >= 9 && continuous.allSatisfy { $0.range.upperBound - $0.range.lowerBound <= 12.001 }, "Continuous speech stays in bounded inference chunks")
    var project = Project(title: "Subtitle model QA")
    project.append(SourceMedia(filename: "source.mp4", duration: 12))
    var state = project.edit
    state.timeline.installSubtitles(words, range: 0...12, language: "English")
    try require(state.timeline.subtitleGroupingAvailable && state.timeline.subtitleCues.allSatisfy { SubtitleTiming.tokens($0.text).count <= 6 }, "Initial captions obey word limit")
    state.timeline.regroupSubtitles(2)
    try require(state.timeline.subtitleCues.allSatisfy { SubtitleTiming.tokens($0.text).count <= 2 }, "Regrouping uses stored transcript")
    project.commit(state)
    let navigation = TimelineNavigation(project.edit)
    let firstCue = project.edit.timeline.subtitleCues[0]
    try require(navigation.changes.contains { abs($0 - firstCue.start) <= 1.0 / 30 }, "Effect navigation includes subtitle boundaries")
    let original = project.edit, firstAudio = original.timeline.audio[0].id
    var divided = original
    divided.timeline.split(at: EditTime(5), selection: divided.timeline.entireSelection())
    try require(!divided.timeline.subtitleGroupingAvailable && !divided.timeline.subtitleCues.isEmpty, "Split preserves captions and marks regrouping stale")
    let beforeRight = divided.timeline.subtitleCues.filter { $0.audioID != firstAudio }.map(\.text)
    if let cue = divided.timeline.subtitleCues.first(where: { $0.audioID == firstAudio }) { divided.timeline.correctSubtitle(cue, text: "Edited independently") }
    try require(beforeRight == divided.timeline.subtitleCues.filter { $0.audioID != firstAudio }.map(\.text), "Correcting a split caption cannot mutate its other half")
    let count = divided.timeline.subtitles!.maxWords; divided.timeline.regroupSubtitles(9)
    try require(divided.timeline.subtitles!.maxWords == count, "Stale transcript refuses regrouping")
    project.commit(divided); project.undo()
    try require(project.edit == original && project.edit.timeline.subtitleGroupingAvailable, "Undo restores exact captions and regrouping")
    project.redo(); try require(project.edit == divided, "Redo restores corrected split captions")
    var moved = original
    moved.timeline.unlink(moved.timeline.entireSelection())
    moved.timeline.move(TimelineSelection(audio: [firstAudio]), by: EditTime(3))
    try require(abs(moved.timeline.subtitleCues[0].start - original.timeline.subtitleCues[0].start - 3) < 0.00001, "Captions follow independent speech moves")
    var faster = original; faster.clips[0].speed = SpeedSettings(rate: 2)
    try require(abs(faster.timeline.subtitleCues[0].start * 2 - original.timeline.subtitleCues[0].start) < 0.0001, "Captions follow pitch-preserved speed changes")
    var partial = original.timeline
    let preserved = partial.subtitleCues.filter { $0.start > 4 }.map(\.id)
    partial.installSubtitles(SubtitleTiming.estimate("New opening", speech: [0.3...1.5]), range: 0...2, language: "English")
    try require(partial.subtitleCues.filter { $0.start > 4 }.map(\.id) == preserved, "Partial re-transcription preserves phrase identity outside the selection")
    var styled = original; styled.timeline.subtitles?.style = .bold
    try require(styled.timeline.subtitleGroupingAvailable, "Style changes do not invalidate timing")
    var gain = original; gain.timeline.audio[0].volumeDB = -3
    try require(gain.timeline.subtitleGroupingAvailable, "Gain changes do not invalidate timing")
    var pasted = original.timeline
    let clipboard = pasted.copied(pasted.entireSelection())
    let selection = pasted.paste(clipboard, at: EditTime(12))
    let copy = pasted.subtitleCues.first { selection.audio.contains($0.audioID) }!
    pasted.correctSubtitle(copy, text: "Independent copy")
    try require(pasted.subtitleCues.filter { !selection.audio.contains($0.audioID) }.map(\.text) == original.timeline.subtitleCues.map(\.text), "Pasted subtitles own independent words")
    var removed = original; removed.timeline.removeSubtitles(); project.commit(removed)
    try require(project.edit.timeline.subtitleCues.isEmpty && project.edit.timeline.audio.allSatisfy { $0.subtitleWords == nil }, "Removal deletes transcript and timing together")
    project.undo(); try require(project.edit == divided, "Undo restores full transcript after global removal")
    let disk = ProjectDisk(root: root.appendingPathComponent("subtitle-projects"))
    try disk.save(project)
    let reopened = try disk.read(disk.folder(project.id).appendingPathComponent("project.json"))
    try require(reopened.edit == project.edit && reopened.canRedo, "Transcript corrections and Undo/Redo survive reopening")
    try reopened.validate()

    // Placement is constrained by the entire series, including long captions,
    // pasted paragraphs and simultaneous speech, in portrait and landscape.
    let layoutCues = [
        SubtitleCue(id: "short", audioID: UUID(), wordIDs: [], text: "Ciao", start: 0, end: 1),
        SubtitleCue(id: "long", audioID: UUID(), wordIDs: [], text: "How are you? I'm fine. This longer subtitle needs more than one line.", start: 1, end: 2),
        SubtitleCue(id: "overlap", audioID: UUID(), wordIDs: [], text: "Another speaker talking at the same time.", start: 1, end: 2),
        SubtitleCue(id: "paragraph", audioID: UUID(), wordIDs: [], text: String(repeating: "Long corrected sentence with punctuation, accents: città. ", count: 30), start: 2, end: 3)
    ]
    for canvas in [CGSize(width: 1920, height: 1080), CGSize(width: 1080, height: 1920), CGSize(width: 1080, height: 1080)] {
        for font in SubtitleFont.allCases {
            if let name = font.postScriptName(bold: true) {
                let actual = CTFontCopyPostScriptName(CTFontCreateWithName(name as CFString, 30, nil)) as String
                try require(actual == name, "Built-in subtitle font exists: \(name), got \(actual)")
            }
            for style in TextStyle.allCases {
                var settings = SubtitleSettings(); settings.font = font; settings.style = style
                let layout = SubtitleLayout(cues: layoutCues, settings: settings, canvas: canvas)
                let short = SubtitleLayout(cues: Array(layoutCues.prefix(1)), settings: settings, canvas: canvas)
                try require(layout.containsEveryCharacter, "No text truncated in \(font)/\(style)/\(canvas)")
                try require(layout.maximumSize < short.maximumSize, "Short caption cannot determine series size limit")
                for point in [CGPoint.zero, CGPoint(x: 1, y: 1), CGPoint(x: 0.5, y: 0.5)] {
                    settings.size = 0.3; settings.x = point.x; settings.y = point.y
                    let constrained = layout.constrained(settings)
                    try require(constrained.valid, "Safe layout settings remain valid even for a pasted paragraph")
                    let box = layout.envelope(constrained)
                    try require(CGRect(x: 0.024, y: 0.024, width: 0.952, height: 0.952).contains(box), "Largest caption envelope stays within video")
                    for time in [0.5, 1.5, 2.5] {
                        let frames = layout.frames(at: time, settings: constrained, output: canvas)
                        try require(frames.count == (time == 1.5 ? 2 : 1), "Every active caption is rendered")
                        try require(frames.allSatisfy { CGRect(x: 0, y: 0, width: 1, height: 1).contains($0.rect) }, "Every glyph bitmap stays within frame, even at placement limits")
                        if frames.count == 2 { try require(!frames[0].rect.intersects(frames[1].rect), "Simultaneous captions never overlap") }
                    }
                }
            }
        }
    }
    var placement = SubtitleSettings(); placement.font = .classic; placement.x = 0.3; placement.size = 0.13; placement.y = 0.2
    let encoded = try JSONEncoder().encode(placement)
    let decoded = try JSONDecoder().decode(SubtitleSettings.self, from: encoded)
    try require(decoded == placement, "Font and placement round trip")
    var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]; legacy.removeValue(forKey: "x"); legacy.removeValue(forKey: "font")
    let oldSettings = try JSONDecoder().decode(SubtitleSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
    try require(oldSettings.centerX == 0.5 && oldSettings.resolvedFont == .system, "Existing subtitles load with centered system font")

    let folder = root.appendingPathComponent("subtitle-render"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: folder.appendingPathComponent("source.mp4").path) { try FileManager.default.copyItem(at: root.appendingPathComponent("source.mp4"), to: folder.appendingPathComponent("source.mp4")) }
    var renderProject = Project(title: "Subtitle render QA"); renderProject.append(SourceMedia(filename: "source.mp4", duration: 4))
    var renderState = renderProject.edit
    renderState.timeline.installSubtitles(SubtitleTiming.estimate("A visible subtitle", speech: [0.2...3.5]), range: 0...4, language: "English")
    renderState.timeline.subtitles?.font = .classic
    renderState.timeline.subtitles?.x = 0.3
    renderState.timeline.subtitles?.y = 0.2
    renderState.timeline.subtitles?.size = 0.095
    renderProject.commit(renderState)
    let media = try await MediaRenderer.timeline(project: renderProject, folder: folder)
    try require(media.videoComposition.instructions.compactMap { $0 as? TrackVideoInstruction }.allSatisfy { $0.subtitles != nil }, "Caption render track is shared by preview and export instructions")
    let exported = folder.appendingPathComponent("captions.mp4")
    try? FileManager.default.removeItem(at: exported)
    _ = try await MediaRenderer.render(project: renderProject, folder: folder, destination: exported) { _ in }
    let asset = AVURLAsset(url: exported), duration = try await asset.load(.duration).seconds
    try require(abs(duration - 4) < 0.05, "Subtitles do not alter exported duration")
    let generator = AVAssetImageGenerator(asset: asset); generator.appliesPreferredTrackTransform = true
    let image = try generator.copyCGImage(at: CMTime(seconds: 1, preferredTimescale: 600), actualTime: nil)
    try require(image.width == 640 && image.height == 360, "Caption export decodes at original resolution")
    let originalGenerator = AVAssetImageGenerator(asset: AVURLAsset(url: folder.appendingPathComponent("source.mp4")))
    let originalImage = try originalGenerator.copyCGImage(at: CMTime(seconds: 1, preferredTimescale: 600), actualTime: nil)
    func pixels(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: 640 * 360 * 4)
        data.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: 640, height: 360, bitsPerComponent: 8, bytesPerRow: 640 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 640, height: 360))
        }
        return data
    }
    let before = pixels(originalImage), after = pixels(image)
    var changed = 0
    for pixel in stride(from: 0, to: before.count, by: 4) {
        let red = abs(Int(before[pixel]) - Int(after[pixel]))
        let green = abs(Int(before[pixel + 1]) - Int(after[pixel + 1]))
        if red > 70 || green > 70 { changed += 1 }
    }
    try require(changed > 200, "Export contains visible caption pixels, not just a decodable video")
    if let output = CGImageDestinationCreateWithURL(folder.appendingPathComponent("caption-frame.png") as CFURL, UTType.png.identifier as CFString, 1, nil) { CGImageDestinationAddImage(output, image, nil); CGImageDestinationFinalize(output) }
    print("PASS: subtitles — timing, silence, regrouping, text edits, split isolation, moves, speed, paste, Undo/Redo, persistence and export")
}
