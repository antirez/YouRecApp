#if DEBUG || os(macOS)
import Foundation

/// Shared by the core suite and the isolated track diagnostic on the phone.
func timelineClipboardChecks() throws {
    func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw NSError(domain: "ClipboardQA", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    let source = SourceMedia(filename: "clipboard.mov", duration: 10)
    let clips = (0..<5).map { TimelineClip(sourceID: source.id, start: Double($0 * 2), end: Double($0 * 2 + 2)) }
    var base = TrackTimeline(clips: clips)
    func boundary(_ t: TrackTimeline, _ second: Double, _ kind: TimelinePasteTarget.Kind = .picture) -> TimelinePasteTarget? {
        t.pasteTargets(layout: EditState(timeline: t).layout).first { $0.kind == kind && $0.isAt(EditTime(second)) }
    }
    func order(_ timeline: TrackTimeline) -> [Int] { timeline.chronologicalVideo.map { Int($0.content.start / 2) } }
    let indices = Array(clips.indices)
    for mask in 1..<(1 << clips.count) {
        let chosen = indices.filter { mask & (1 << $0) != 0 }, kept = indices.filter { !chosen.contains($0) }
        let scope = base.selection(ids: Set(chosen.map { clips[$0].id }))
        let copy = base.copied(scope)
        try check(copy.timeline.duration == EditTime(Double(chosen.count * 2)), "Disjoint scenes must pack in playback order")
        for slot in 0...clips.count {
            var result = base
            let time = Double(slot * 2)
            let added = result.paste(copy, at: EditTime(time), target: boundary(result, time))
            try check(order(result) == Array(indices.prefix(slot)) + chosen + Array(indices.dropFirst(slot)) &&
                      added.ids.isDisjoint(with: base.allIDs), "Copy into slot \(slot) of mask \(mask) must keep the originals")
            try result.validate(sources: [source])
        }
        var lifted = base
        guard let cut = lifted.cutToClipboard(scope, preserving: .zero) else { try check(false, "Cut unexpectedly empty"); return }
        try check(order(lifted) == kept, "Cut removes only the selected scenes")
        for slot in 0...kept.count {
            var result = lifted
            let time = Double(slot * 2)
            result.paste(cut.clipboard, at: EditTime(time), target: boundary(result, time))
            try check(order(result) == Array(kept.prefix(slot)) + chosen + Array(kept.dropFirst(slot)) && result.duration == base.duration,
                      "Cut and paste must reconstruct a complete sequence, including an empty destination")
            try result.validate(sources: [source])
        }
    }

    base.addBookmark(at: EditTime(8.75))
    base.audio[4].subtitleWords = [SubtitleWord(text: "Last", start: 8.2, end: 8.8)]
    base.audio[4].setFade(.fadeIn, seconds: 0.25)
    base.enhance([AudioEffect(kind: .gain, amount: -3)], selection: base.selection(of: clips[4].id))
    var title = TextOverlay(text: "Last scene"); title.start = 8; title.end = 9
    base.video[4].content.texts = [title]
    let late = base.copied(base.selection(of: clips[4].id))
    var layered = base
    let firstPaste = layered.paste(late, at: .zero, target: boundary(layered, 0))
    let secondPaste = layered.paste(late, at: layered.duration, target: boundary(layered, layered.duration.seconds))
    try check(firstPaste.ids.isDisjoint(with: secondPaste.ids) && layered.resolvedBookmarks.map(\.time) == [EditTime(0.75), EditTime(10.75), EditTime(12.75)],
              "Each paste has its own media, mark, and edit identities")
    let audio = layered.audio.first { firstPaste.audio.contains($0.id) }!
    let video = layered.video.first { firstPaste.video.contains($0.id) }!
    try check(audio.subtitleWords?.first?.text == "Last" && audio.fadeIn == base.audio[4].fadeIn &&
              audio.enhancements.first?.effects == base.audio[4].enhancements.first?.effects &&
              video.content.texts?.first?.text == "Last scene" && video.content.texts?.first?.id != title.id,
              "Pasted titles, captions, fades and enhancements remain editable independently")
    var range = base
    let selection = base.entireSelection(range: EditInterval(1...3))
    let piece = range.cutToClipboard(selection, preserving: EditTime(8))!
    try check(piece.position == EditTime(6) && range.duration == EditTime(8) && piece.clipboard.timeline.duration == EditTime(2),
              "Cut and the clipboard must use the same exact range fragments")
    var project = Project(title: "Clipboard history"); project.sources = [source]
    project.commit(EditState(timeline: base)); project.commit(EditState(timeline: range))
    range.paste(piece.clipboard, at: EditTime(0.5)); project.commit(EditState(timeline: range))
    project = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project)); try project.validate()
    project.undo(); try check(project.edit.timeline.duration == EditTime(8), "Undo Paste")
    project.undo(); try check(project.edit.timeline == base, "Undo Cut restores the source and its edits after reopening")
    project.redo(); project.redo(); try check(project.edit.timeline == range, "Redo Cut and Paste")

    var detached = base; detached.unlink(detached.entireSelection())
    let sound = detached.copied(detached.selection(of: detached.audio[4].id))
    var atPicture = detached, atSound = detached
    atPicture.paste(sound, at: EditTime(2), target: boundary(detached, 2))
    atSound.paste(sound, at: EditTime(2), target: boundary(detached, 2, .sound))
    try check(atPicture.video == detached.video && atPicture.audio.prefix(5).elementsEqual(detached.audio) &&
              atSound.video == detached.video && atSound.audio[1].start == EditTime(4), "Choose layering on picture or inserting into the sound sequence")
    var mix = base
    let score = mix.insertAudio(source, at: .zero)
    mix.split(at: EditTime(1), selection: TimelineSelection(audio: [score]))
    mix.paste(late, at: EditTime(1), target: boundary(mix, 1, .sound))
    try check(mix.video.contains { $0.occurrenceID == base.video[0].occurrenceID && $0.start == EditTime(3) } &&
              mix.audio.first { $0.id == score }?.start == .zero, "Paste picture at a sound cut preserves detached music and splits dialogue in sync")
    let dissolve = ClipTransition(duration: 0.5)
    let blend = EditState(timeline: base).settingTransition(dissolve, at: 2)
    var separated = blend.timeline
    let join = blend.layout.joins.first { $0.transition?.id == dissolve.id }!
    separated.paste(late, at: EditTime(join.time), target: boundary(separated, join.time))
    try check(separated.transitions.isEmpty && separated.duration == EditTime(12), "Pasting picture into a dissolve recovers both source handles")
    let both = blend.timeline.copied(blend.timeline.selection(ids: Set([clips[1].id, clips[2].id])))
    var copiedBlend = base
    copiedBlend.paste(both, at: copiedBlend.duration)
    try check(copiedBlend.transitions.count == 1 && copiedBlend.transitions[0].id != dissolve.id && both.timeline.duration == EditTime(3.5),
              "An internal transition travels with both selected partners and keeps the real overlap")
    try copiedBlend.validate(sources: [source])

    var spaced = base
    spaced.move(spaced.selection(ids: Set(clips.suffix(2).map(\.id))), by: EditTime(2))
    let marked = spaced.copied(spaced.entireSelection(range: EditInterval(4...10)))
    try check(marked.timeline.duration == EditTime(6) && marked.timeline.chronologicalVideo.map(\.start) == [.zero, EditTime(4)],
              "A marked range retains the intentional gap between included clips")
    var continuousBed = base
    let scoreID = continuousBed.insertAudio(source, at: .zero)
    let beforeMusic = continuousBed.audio.first { $0.id == scoreID }
    continuousBed.paste(late, at: EditTime(1.5))
    try check(continuousBed.audio.first { $0.id == scoreID } == beforeMusic, "A mid-shot scene paste must leave detached music continuous")
    var inside = blend.timeline
    inside.paste(late, at: EditTime(join.time - 0.1))
    try check(inside.transitions.isEmpty && inside.duration == EditTime(12), "A mid-transition scene paste retains all source handles")
    try inside.validate(sources: [source])

    var arrangement = base
    let pip = VideoTimelineItem(occurrenceID: UUID(), start: EditTime(8.5), content: TimelineClip(sourceID: source.id, start: 0, end: 1), layer: 5)
    let third = VideoTimelineItem(occurrenceID: UUID(), start: EditTime(8.6), content: TimelineClip(sourceID: source.id, start: 0, end: 0.4), layer: 6)
    arrangement.video += [pip, third]
    var window = VideoPlacement(); window.width = 0.4; window.order = 2
    arrangement.placements = [VideoPlacementRegion(participants: [clips[4].id, pip.id, third.id], videos: [clips[4].id: VideoPlacement(), pip.id: window, third.id: VideoPlacement()])]
    let parts = arrangement.copied(arrangement.selection(ids: Set([clips[4].id, pip.id])))
    try check(parts.timeline.video.first { $0.id == pip.id }?.start == EditTime(0.5) &&
              parts.timeline.placements.first?.videos[pip.id] == window, "Overlapping picks retain offset and custom framing")
}
#endif
