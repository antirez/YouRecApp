#if DEBUG || os(macOS)
import Foundation

func moveBoundaryChecks() throws {
    func check(_ ok: Bool, _ message: String) throws {
        guard ok else { throw NSError(domain: "MoveBoundaryQA", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    let source = SourceMedia(filename: "moves.mov", duration: 18)
    let scenes = (0..<3).map { TimelineClip(sourceID: source.id, start: Double(6 * $0), end: Double(6 * ($0 + 1))) }
    let base = TrackTimeline(clips: scenes)
    let picked = base.selection(of: scenes[1].id), choices = base.moveChoices(for: picked)
    func stops(_ t: TrackTimeline, _ moved: TimelineSelection) -> TimelineMoveBoundaries {
        TimelineMoveBoundaries(timeline: t, picked: picked, moving: moved)
    }
    let plain = stops(base, picked)
    try check(plain.anchor == EditTime(6) && plain.times == [0, 6, 12, 18].map { EditTime($0) },
              "Aligned picture and sound stops must occur exactly once")
    try check(plain.next(from: EditTime(6)) == EditTime(12) && plain.previous(from: EditTime(12)) == EditTime(6) &&
              plain.next(from: EditTime(18)) == nil && plain.previous(from: .zero) == nil, "Strict, reversible stops and finite endpoints")
    let left = stops(base, choices.left), right = stops(base, choices.right)
    try check(left.anchor == plain.anchor && left.previous(from: plain.anchor) == nil &&
              right.times == [0, 6, 18].map { EditTime($0) }, "Companions keep the picked anchor, skip internal cuts and cannot move before zero")
    for scope in [choices.selected, choices.left, choices.right, choices.both] {
        let plan = stops(base, scope)
        for target in plan.times {
            var draft = base; draft.move(scope, by: target - plan.anchor)
            for item in base.video {
                let delta = scope.video.contains(item.id) ? target - plan.anchor : .zero
                try check(draft.video.first { $0.id == item.id }?.start == item.start + delta, "Move must preserve all picture offsets and untouched clips")
            }
            for item in base.audio {
                let delta = scope.audio.contains(item.id) ? target - plan.anchor : .zero
                try check(draft.audio.first { $0.id == item.id }?.start == item.start + delta, "Move must preserve linked sync")
            }
            try draft.validate(sources: [source])
        }
    }
    var gaps = base
    gaps.move(gaps.selection(of: scenes[2].id), by: EditTime(ticks: 1))
    let first = gaps.selection(of: scenes[0].id)
    let tickStops = TimelineMoveBoundaries(timeline: gaps, picked: first, moving: first)
    let tick = EditTime(12) + EditTime(ticks: 1)
    try check(tickStops.next(from: EditTime(12)) == tick && tickStops.previous(from: tick) == EditTime(12), "A one-tick gap exposes two independently reachable edges")
    gaps.unlink(gaps.selection(of: scenes[2].id))
    let loose = gaps.selection(of: gaps.audio[2].id)
    gaps.move(loose, by: EditTime(1))
    let audioCuts = TimelineMoveBoundaries(timeline: gaps, picked: picked, moving: picked)
    try check(audioCuts.times.contains(tick + EditTime(1)), "An independent sound edit is a valid destination for picture")
    let anchoredAudio = TimelineMoveBoundaries(timeline: gaps, picked: loose, moving: loose)
    var audioDraft = gaps; audioDraft.move(loose, by: .zero - anchoredAudio.anchor)
    try check(audioDraft.video == gaps.video && audioDraft.audio[2].start == .zero, "Detached audio can be precisely placed without moving picture")

    let blend = EditState(timeline: base).settingTransition(ClipTransition(duration: 1), at: 1)
    let last = blend.timeline.selection(of: scenes[2].id)
    let folded = TimelineMoveBoundaries(timeline: blend.timeline, picked: last, moving: last)
    let join = blend.layout.joins.first { $0.transition != nil }!
    try check(folded.times.contains(EditTime(join.time)) && !folded.times.contains(blend.timeline.video[1].start) &&
              !folded.times.contains(blend.timeline.video[0].end), "Dissolves offer their displayed join instead of their underlying overlap handles")

    let scoped = base.scoped(base.entireSelection(range: EditInterval(1.25...3.25)))
    let partial = TimelineMoveBoundaries(timeline: scoped.timeline, picked: scoped.selection, moving: scoped.selection)
    try check(partial.anchor == EditTime(1.25) && partial.next(from: EditTime(1.25)) == EditTime(3.25),
              "A marked range aligns from the chosen source fragment")
    let separate = base.selection(ids: Set([scenes[0].id, scenes[2].id]))
    var grouped = base
    grouped.move(separate, by: EditTime(6))
    try check(grouped.video.map(\.start) == [6, 6, 18].map { EditTime($0) }, "Disjoint selected parts move together, preserving their gap")
}
#endif
