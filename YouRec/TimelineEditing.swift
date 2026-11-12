import Foundation

enum VideoInsertionSite: Codable, Hashable {
    case start, gap(after: EditTime), end

    var label: String {
        switch self {
        case .start: return "Add video or photo at start"
        case .gap: return "Add video or photo in gap"
        case .end: return "Add video or photo at end"
        }
    }

    // Free picture time may contain independent audio. Use it before opening
    // more time, and ripple at the next picture only when the batch overflows.
    func placement(in timeline: TrackTimeline, length: EditTime) -> (start: EditTime, rippleAt: EditTime, ripple: EditTime) {
        let coverage = timeline.videoCoverage
        guard let first = coverage.first, let last = coverage.last else { return (.zero, .zero, .zero) }
        switch self {
        case .start:
            return (max(.zero, first.start - length), first.start, max(.zero, length - first.start))
        case .end:
            return (last.end, last.end, .zero)
        case .gap(let edge):
            // Re-resolve against the edit being committed (Photos may take time).
            guard let left = coverage.last(where: { $0.start < edge }) else {
                return VideoInsertionSite.start.placement(in: timeline, length: length)
            }
            guard let right = coverage.first(where: { $0.start > left.end }) else { return (left.end, left.end, .zero) }
            return (left.end, right.start, max(.zero, length - (right.start - left.end)))
        }
    }
}

extension TrackTimeline {
    var videoCoverage: [EditInterval] {
        Self.union(video.map(\.interval) + generated.map(\.interval))
    }
}

enum TimelineEditing {
    static let frame = 1.0 / 30
    static func quantize(_ time: Double) -> Double { (time * 30).rounded() / 30 }

    static func split(_ state: EditState, at time: Double, selectedItems: Set<UUID> = []) -> EditState {
        var result = state
        let point = EditTime(quantize(time))
        if let join = state.layout.transition(at: time), time > join.range.lowerBound + 0.00001, time < join.range.upperBound - 0.00001 { return state }
        if !selectedItems.isEmpty {
            // An explicit lane selection can split detached audio or picture on
            // its own. A selection elsewhere must not swallow the playhead cut.
            let selected = state.timeline.selection(ids: selectedItems)
            let cutsVideo = state.timeline.video.contains { selected.video.contains($0.id) && $0.start < point && point < $0.end }
            let cutsAudio = state.timeline.audio.contains { selected.audio.contains($0.id) && $0.start < point && point < $0.end }
            if cutsVideo || cutsAudio {
                result.timeline.split(at: point, selection: selected)
                return result
            }
        }
        result.timeline.split(at: point, selection: result.timeline.entireSelection())
        return result
    }

    // Use exactly the same clip-relative boundaries for Cut, Copy and Delete.
    // Absolute quantization corrupts selections at non-frame-aligned take joins.
    static func cut(_ range: ClosedRange<Double>, from state: EditState) -> (edit: EditState, clips: [TimelineClip]) {
        guard range.upperBound - range.lowerBound >= frame - 0.00001 else { return (state, []) }
        let boundaries = Set(state.timeline.video.flatMap { [$0.start.seconds, $0.end.seconds] } + state.timeline.audio.flatMap { [$0.start.seconds, $0.end.seconds] })
        func aligned(_ time: Double) -> Double {
            guard let nearest = boundaries.min(by: { abs($0 - time) < abs($1 - time) }), abs(nearest - time) < frame else { return time }
            return nearest
        }
        let a = aligned(range.lowerBound), b = aligned(range.upperBound)
        guard b > a else { return (state, []) }
        var scoped = state.timeline.scoped(state.timeline.entireSelection(range: EditInterval(a...b)))
        let copied = scoped.timeline.video.filter { scoped.selection.video.contains($0.id) }.map(\.content)
        scoped.timeline.remove(scoped.selection)
        return (EditState(timeline: scoped.timeline, outputSize: state.outputSize), copied)
    }
    static func removing(_ range: ClosedRange<Double>, from state: EditState) -> EditState { cut(range, from: state).edit }

    static func copying(_ range: ClosedRange<Double>, from state: EditState) -> [TimelineClip] {
        let scope = scoped(state, range: range)
        return scope.0.clips.filter { scope.1.contains($0.id) }
    }
    static func inserting(_ clips: [TimelineClip], into state: EditState, at time: Double, site: VideoInsertionSite? = nil,
                          pictureOnlySources: Set<UUID> = []) -> EditState {
        guard !clips.isEmpty else { return state }
        let time = min(state.duration, max(0, time))
        var result = state
        // Pasted copies need independent identities for every tool, including
        // overlays shared across adjacent pieces. Re-editing one copy must not
        // silently edit the original or a later paste.
        var ids: [UUID: UUID] = [:]
        func fresh(_ old: UUID) -> UUID { if let id = ids[old] { return id }; let id = UUID(); ids[old] = id; return id }
        let inserted = clips.map { original in
            var clip = original; clip.id = UUID()
            // The clipboard contains clips, not the neighboring join identity.
            clip.openingTransition = nil; clip.transition = nil
            if let value = clip.speed { clip.speed?.id = fresh(value.id) }
            if let value = clip.color { clip.color?.id = fresh(value.id) }
            if let value = clip.crop { clip.crop?.id = fresh(value.id) }
            if let value = clip.mirror { clip.mirror?.id = fresh(value.id) }
            if let value = clip.pauses { clip.pauses?.id = fresh(value.id) }
            if let id = clip.stabilization?.id { clip.stabilization?.id = fresh(id) }
            clip.texts = clip.texts?.map { var value = $0; value.id = fresh(value.id); return value }
            clip.videoEffects = clip.videoEffects?.map {
                var value=$0
                if value.analysisFile != nil {value.capturedEffectID=value.analysisID}
                value.id=fresh(value.id);return value
            }
            clip.images = clip.images?.map { var value = $0; value.id = fresh(value.id); return value }
            return clip
        }
        let addition = TrackTimeline(clips: inserted, pictureOnlySources: pictureOnlySources)
        let point = EditTime(time)
        let placement = site?.placement(in: state.timeline, length: addition.duration) ??
            (start: point, rippleAt: point, ripple: addition.duration)
        result.timeline.insertTime(placement.ripple, at: placement.rippleAt, atPictureGap: site != nil)
        var shifted = addition
        let insertionLayer = (result.timeline.video.map(\.layer).max() ?? 0) + 1
        for i in shifted.video.indices { shifted.video[i].start = shifted.video[i].start + placement.start; shifted.video[i].layer += insertionLayer }
        for i in shifted.audio.indices { shifted.audio[i].start = shifted.audio[i].start + placement.start }
        result.timeline.video += shifted.video; result.timeline.audio += shifted.audio; result.timeline.links += shifted.links
        result.timeline.video.sort { $0.start < $1.start }
        return result
    }
    static func snap(_ time: Double, clips: [TimelineClip], pointsPerSecond: Double) -> Double {
        let boundaries = TimelineLayout(clips: clips).joins.map(\.time)
        guard let nearest = boundaries.min(by: { abs($0 - time) < abs($1 - time) }),
              abs(nearest - time) * pointsPerSecond <= 8 else { return time }
        return nearest
    }

    static func trimmed(_ clip: TimelineClip, left: Bool, by delta: Double, sourceDuration: Double) -> TimelineClip {
        guard abs(delta) > 0.000001 else { return clip }
        if let frozen = clip.frozenFrame {
            var result = clip
            let length = min(10, max(frame, frozen.duration + (left ? -delta : delta)))
            if left { result.frozenFrame?.offset = max(0, frozen.offset + frozen.duration-length) }
            result.frozenFrame?.duration = length
            return result
        }
        var available = clip; available.start = 0; available.end = sourceDuration
        let a = available.timelineTime(forSource: clip.start), b = available.timelineTime(forSource: clip.end)
        var result = clip
        if left {
            let target = min(b - frame, max(0, quantize(a + delta)))
            result.start = available.sourceTime(at: target)
        } else {
            let target = max(a + frame, min(available.duration, quantize(b + delta)))
            result.end = available.sourceTime(at: target)
        }
        return result.duration >= frame - 0.000001 ? result : clip
    }

    static func offset(of id: UUID, in state: EditState) -> Double {
        state.layout.placements.first { $0.clip.id == id }?.start ?? state.duration
    }
}
