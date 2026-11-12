import Foundation
import CoreGraphics

// A join belongs to these exact neighbors. Moving or deleting a clip must never
// silently apply its transition to unrelated footage. Source trims stay intact.
enum TransitionStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case dissolve
    case fadeColor = "fadeBlack" // Preserve existing project documents.
    case wipe, split, hitchcock, whip, flashCut, still, defocus
    var id: String { rawValue }
    var title: String { switch self { case .dissolve: return "Dissolve"; case .fadeColor: return "Fade through color"; case .wipe: return "Wipe"; case .split: return "Split screen"; case .hitchcock: return "Hitchcock"; case .whip: return "Whip pan"; case .flashCut: return "Flash Cut"; case .still: return "still"; case .defocus: return "Defocus" } }
    var symbol: String { switch self { case .dissolve: return "square.on.square"; case .fadeColor: return "circle.lefthalf.filled"; case .wipe: return "rectangle.lefthalf.inset.filled"; case .split: return "rectangle.split.2x1"; case .hitchcock: return "circle.lefthalf.striped.horizontal"; case .whip: return "wind"; case .flashCut: return "bolt.fill"; case .still: return "pause.rectangle"; case .defocus: return "camera.aperture" } }
    var supportsHold: Bool { self != .flashCut && self != .still }
}
enum TransitionAxis: String, Codable, CaseIterable, Sendable {
    case horizontal, vertical
    var title: String { self == .horizontal ? "Left / right" : "Top / bottom" }
}
enum TransitionAudio: String, Codable, CaseIterable, Sendable {
    case crossfade, first, second
    var title: String { switch self { case .crossfade: return "Crossfade"; case .first: return "First clip"; case .second: return "Second clip" } }
}
struct TransitionFraming: Codable, Equatable, Sendable {
    var x = 0.5
    var y = 0.5 // top-to-bottom coordinates, matching touch input
    var zoom = 1.0
    func crop(source: CGSize, viewport: CGSize) -> CGRect {
        CropSettings(x: x, y: y, zoom: zoom).rect(source: source, canvas: viewport)
    }
}
struct TransitionColor: Codable, Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    static let black = TransitionColor(red: 0, green: 0, blue: 0)
    var valid: Bool { [red, green, blue].allSatisfy { $0.isFinite && (0...1).contains($0) } }
    var cgColor: CGColor { CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [red, green, blue, 1])! }
}
struct ClipTransition: Codable, Equatable, Identifiable, Sendable {
    // Match the document's maximum running time; usable duration is limited
    // by the actual neighboring footage, not an arbitrary short preset cap.
    static let maximumDuration = 604800.0
    var id = UUID()
    var nextClipID: UUID?
    var style: TransitionStyle = .dissolve
    var duration = 0.5
    var axis: TransitionAxis = .horizontal
    var divider = 0.5
    var reverse = false
    var audio: TransitionAudio = .crossfade
    var first = TransitionFraming()
    var second = TransitionFraming()
    var fadeColor: TransitionColor?
    var resolvedFadeColor: TransitionColor { fadeColor ?? .black }
    var hold: Double?
    var audioOffset: Double?
    var audioBlend: Double?
    var wipeAngle: Double? // Degrees clockwise in screen coordinates.
    var hardEdge: Bool?
    var highlightsFirst: Bool?
    var flashCount: Int?
    var flashAcceleration: Double?
    var stillDissolve: Double? // nil/0 = cut; duration is the freeze length.
    var blurAmount: Double?
    var holdDuration: Double { style.supportsHold ? hold ?? 0 : 0 }
    var customAudio: Bool { audioOffset != nil || audioBlend != nil }
    var defaultAudioBlend: Double { style == .still ? 0 : duration + (style == .fadeColor ? 0 : holdDuration) }
    var angle: Double { (wipeAngle ?? (axis == .horizontal ? 0 : 90)) + (reverse ? 180 : 0) }
    var newFeatures: Bool {
        ![TransitionStyle.dissolve, .fadeColor, .wipe, .split].contains(style) || resolvedFadeColor != .black || hold != nil || audioOffset != nil || audioBlend != nil || wipeAngle != nil || hardEdge == true
    }
    func flashFrames(duration: Double, framesPerSecond: Double = 30) -> [Int] {
        let frames = max(1, Int((duration * framesPerSecond).rounded())), count = min(flashCount ?? 3, max(0, (frames - 1) / 2))
        guard count > 0 else { return [] }
        var result: [Int] = []
        for index in 1...count {
            let u = Double(index) / Double(count + 1)
            let desired = Int(((1 - pow(1 - u, flashAcceleration ?? 2)) * Double(frames - 1)).rounded())
            result.append(min(frames - 2 - 2 * (count - index), max((result.last ?? -1) + 2, desired)))
        }
        return result
    }
    var valid: Bool {
        duration.isFinite && duration > 0 && duration <= Self.maximumDuration && divider.isFinite && (0.15...0.85).contains(divider) && resolvedFadeColor.valid
            && [first, second].allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.zoom.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) && (1...4).contains($0.zoom) }
            && [hold, audioBlend, stillDissolve].compactMap { $0 }.allSatisfy { $0.isFinite && (0...Self.maximumDuration).contains($0) }
            && (audioOffset.map { $0.isFinite && abs($0) <= Self.maximumDuration } ?? true)
            && (wipeAngle.map { $0.isFinite && (-360...360).contains($0) } ?? true)
            && (flashCount.map { (1...20).contains($0) } ?? true)
            && (flashAcceleration.map { $0.isFinite && (0.25...4).contains($0) } ?? true)
            && (blurAmount.map { $0.isFinite && (0...1).contains($0) } ?? true)
    }
}
// Relative times use the beginning of the picture effect as zero. Both tracks
// keep the same media clock; the union of picture and sound requirements decides
// how far the next clip overlaps (or follows) the previous one.
struct TransitionTiming {
    var style: TransitionStyle?
    var motion = 0.0
    var hold = 0.0
    var videoDuration = 0.0
    var audioIn = 0.0...0.0
    var audioOut = 0.0...0.0
    var leftEnd = 0.0
    var rightStart = 0.0
    var lower = 0.0
    var upper = 0.0
    var cut = 0.0
    var leftCost = 0.0
    var rightCost = 0.0
    var overlap: Double { leftEnd - rightStart }
    init(_ settings: ClipTransition?, factor: Double = 1, edge: Int = 0) {
        guard let settings else { return }
        style = settings.style
        let still = settings.style == .still
        motion = (still ? settings.stillDissolve ?? 0 : settings.duration) * factor
        // Solid gaps and silent freezes need no source handles. Custom audio
        // can make the neighboring source run underneath them, so those holds
        // must then participate in fitting, just like moving-picture holds.
        hold = still ? settings.duration * (settings.customAudio && edge != 1 ? factor : 1)
            : settings.holdDuration * (settings.style == .fadeColor && edge == 0 && !settings.customAudio ? 1 : factor)
        if !still && motion + hold < TimelineEditing.frame - 0.000001 { motion = 0; hold = 0 }
        videoDuration = motion + hold
        var aNeed = videoDuration, bNeed = 0.0
        if settings.style == .fadeColor && edge == 0 { aNeed = motion / 2; bNeed = motion / 2 + hold }
        if still { aNeed = 0; bNeed = hold }
        var offset = (settings.audioOffset ?? 0) * factor
        var blend = (settings.audioBlend ?? (edge != 0 && settings.style == .fadeColor ? settings.duration + settings.holdDuration : settings.defaultAudioBlend)) * factor
        if settings.style == .split && settings.audioOffset == nil && settings.audioBlend == nil {
            if settings.audio == .first { offset = max(0, videoDuration - 0.008); blend = min(0.008, videoDuration) }
            if settings.audio == .second { blend = min(0.008, videoDuration) }
        }
        if edge == -1 {
            let begin = offset + (still && !settings.customAudio ? hold : 0)
            audioIn = begin...(begin + blend)
            rightStart = min(bNeed, audioIn.lowerBound)
            lower = min(0, rightStart); upper = max(videoDuration, audioIn.upperBound)
            rightCost = upper - rightStart
        } else if edge == 1 {
            audioOut = offset...(offset + blend)
            leftEnd = max(aNeed, audioOut.upperBound)
            lower = min(0, audioOut.lowerBound); upper = max(videoDuration, leftEnd)
            leftCost = leftEnd - lower
        } else {
            if (settings.style == .fadeColor || still) && !settings.customAudio {
                audioOut = offset...(offset + blend / 2)
                audioIn = (offset + blend / 2 + hold)...(offset + blend + hold)
            } else { audioIn = offset...(offset + blend); audioOut = audioIn }
            leftEnd = max(aNeed, audioOut.upperBound)
            rightStart = min(bNeed, audioIn.lowerBound)
            lower = min(0, rightStart, audioOut.lowerBound)
            upper = max(videoDuration, leftEnd, audioIn.upperBound)
            leftCost = leftEnd - lower; rightCost = upper - rightStart
        }
        cut = still ? hold : videoDuration / 2
    }
    func progress(at elapsed: Double) -> Double {
        if style == .still { return motion > 0 ? min(1, max(0, (elapsed - hold) / motion)) : elapsed < hold ? 0 : 1 }
        guard motion > 0 else { return elapsed < videoDuration / 2 ? 0 : 1 }
        if elapsed < motion / 2 { return min(1, max(0, elapsed / motion)) }
        if elapsed <= motion / 2 + hold { return 0.5 }
        return min(1, max(0, (elapsed - hold) / motion))
    }
}
struct TimelinePlacement {
    let clip: TimelineClip
    let index: Int
    let start: Double
    var end: Double { start + clip.duration }
    let incoming: Double
    let outgoing: Double
    let lower: Double
    let upper: Double
    var range: ClosedRange<Double> { lower...max(lower, upper) }
}
struct TransitionJoin: Identifiable {
    let index: Int
    let time: Double
    let range: ClosedRange<Double>
    let maximum: Double
    let transition: ClipTransition?
    var origin = 0.0
    var timing = TransitionTiming(nil)
    var factor = 1.0
    var selectable = true
    var edge = 0 // -1 opening, +1 closing; independent of rounded timestamps.
    var outgoingID: UUID?
    var incomingID: UUID?
    var videoRange: ClosedRange<Double> { origin...(origin + timing.videoDuration) }
    var audioIn: ClosedRange<Double> { (origin + timing.audioIn.lowerBound)...(origin + timing.audioIn.upperBound) }
    var audioOut: ClosedRange<Double> { (origin + timing.audioOut.lowerBound)...(origin + timing.audioOut.upperBound) }
    var id: Int { index }
    var title: String { index == 0 ? "Start" : "Join \(index)" }
}
struct TimelineLayout {
    let placements: [TimelinePlacement]
    let joins: [TransitionJoin]
    let duration: Double
    init(clips: [TimelineClip]) {
        guard !clips.isEmpty else { placements = []; joins = []; duration = 0; return }
        let count = clips.count
        var settings = [ClipTransition?](repeating: nil, count: count + 1)
        var factors = [Double](repeating: 1, count: count + 1)
        func edge(_ index: Int) -> Int { index == 0 ? -1 : index == count ? 1 : 0 }
        for index in 0...count {
            let right = index < count ? clips[index] : nil
            let value = index == 0 ? right?.openingTransition : clips[index - 1].transition
            if let value, value.valid, index == 0 || value.nextClipID == right?.id { settings[index] = value }
        }
        func timing(_ index: Int, _ scale: Double = 1) -> TransitionTiming { TransitionTiming(settings[index], factor: factors[index] * scale, edge: edge(index)) }
        // Adjacent footprints cannot share source time. This also prevents two
        // nonadjacent clips (or their freeze extensions) colliding on one track.
        for index in clips.indices {
            if timing(index).rightCost + timing(index + 1).leftCost > clips[index].duration + 0.00000001 {
                var lo = 0.0, hi = 1.0
                for _ in 0..<48 {
                    let mid = (lo + hi) / 2
                    if timing(index, mid).rightCost + timing(index + 1, mid).leftCost <= clips[index].duration { lo = mid } else { hi = mid }
                }
                factors[index] *= lo; factors[index + 1] *= lo
            }
        }
        let times = (0...count).map { timing($0) }
        var starts = [Double](repeating: 0, count: count)
        var origins = [Double](repeating: 0, count: count + 1)
        origins[0] = -min(0, times[0].rightStart)
        starts[0] = origins[0] + times[0].rightStart
        for index in 1..<count {
            origins[index] = starts[index - 1] + clips[index - 1].duration - times[index].leftEnd
            starts[index] = origins[index] + times[index].rightStart
        }
        let lastEnd = starts[count - 1] + clips[count - 1].duration
        origins[count] = lastEnd - times[count].leftEnd
        duration = max(lastEnd, origins[count] + times[count].upper)
        var builtJoins: [TransitionJoin] = []
        for index in 0...count {
            let t = times[index], origin = origins[index]
            let leftSpace = index > 0 ? max(0, clips[index - 1].duration - times[index - 1].rightCost) : .infinity
            let rightSpace = index < count ? max(0, clips[index].duration - times[index + 1].leftCost) : .infinity
            // The primary duration slider remains useful even when custom audio
            // requires proportional fitting; show actual timing in the summary.
            let cost = settings[index]?.style == .fadeColor && edge(index) == 0 ? 0.5 : 1.0
            let maximum = settings[index]?.style == .still ? ClipTransition.maximumDuration : max(0, min(ClipTransition.maximumDuration, leftSpace / cost, rightSpace / cost))
            let point = index == 0 ? 0 : index == count ? duration : origin + t.cut
            let range = max(0, origin + t.lower)...max(0, origin + t.upper)
            builtJoins.append(TransitionJoin(index: index, time: point, range: range, maximum: maximum, transition: settings[index], origin: origin, timing: t, factor: factors[index], edge: edge(index), outgoingID: index > 0 ? clips[index - 1].id : nil, incomingID: index < count ? clips[index].id : nil))
        }
        joins = builtJoins
        placements = clips.indices.map { index in
            TimelinePlacement(clip: clips[index], index: index, start: starts[index], incoming: max(0, times[index].overlap), outgoing: max(0, times[index + 1].overlap),
                lower: builtJoins[index].time, upper: builtJoins[index + 1].time)
        }
    }
    func boundary(at time: Double) -> TransitionJoin? {
        let matches = joins.filter { $0.selectable && abs($0.time - time) < 0.0001 }
        return matches.first { $0.edge == 0 } ?? matches.first
    }
    func placement(at time: Double) -> TimelinePlacement? { placements.first { time >= $0.lower && time < $0.upper } ?? (abs(time - duration) < 0.00001 && placements.last?.upper == duration ? placements.last : nil) }
    func transition(at time: Double) -> TransitionJoin? { joins.first { $0.transition != nil && time >= $0.range.lowerBound && time < $0.range.upperBound } }
    func joins(for placement: TimelinePlacement) -> (incoming: TransitionJoin, outgoing: TransitionJoin) {
        func join(incoming: Bool) -> TransitionJoin {
            let candidates = joins.filter { (incoming ? $0.incomingID : $0.outgoingID) == placement.clip.id }
            if let effect = candidates.first(where: { $0.transition != nil }) { return effect }
            if let cut = candidates.first { return cut }
            let time = incoming ? placement.start : placement.end
            return TransitionJoin(index: placement.index + (incoming ? 0 : 1), time: time, range: time...time, maximum: 0, transition: nil)
        }
        return (join(incoming: true), join(incoming: false))
    }
}
extension TimelineLayout {
    init(timeline: TrackTimeline) {
        let pictures = timeline.chronologicalVideo, clips = timeline.projectedClips
        duration = timeline.duration.seconds
        guard !pictures.isEmpty else { joins = []; placements = []; return }
        var built: [TransitionJoin] = []
        let last = pictures.max { $0.end < $1.end }!
        for index in 0...pictures.count {
            let right = index < pictures.count ? pictures[index] : nil
            let relation = timeline.transitions.first { $0.incoming == right?.id && (right != nil || $0.outgoing == last.id) }
            let left: VideoTimelineItem?
            if let relation { left = pictures.first { $0.id == relation.outgoing } }
            else if let right, index > 0 {
                let ending = pictures.filter { $0.id != right.id && $0.end == right.start }
                left = ending.filter { $0.layer <= right.layer }.max(by: TrackTimeline.backToFront)
                    ?? ending.min(by: TrackTimeline.backToFront) ?? pictures[index - 1]
            } else { left = right == nil ? last : nil }
            let edge = left == nil ? -1 : right == nil ? 1 : 0
            let timing = TransitionTiming(relation?.settings, factor: relation?.factor ?? 1, edge: edge)
            let origin = relation?.origin.seconds ?? left?.end.seconds ?? right?.start.seconds ?? 0
            let point = relation == nil ? origin : edge == -1 ? right!.start.seconds : edge == 1 ? left!.end.seconds : origin + timing.cut
            built.append(TransitionJoin(index: index, time: point,
                range: max(0, origin + timing.lower)...max(0, origin + timing.upper),
                maximum: min(left?.mapping.duration.seconds ?? 604800, right?.mapping.duration.seconds ?? 604800),
                transition: relation?.settings, origin: origin, timing: timing, factor: relation?.factor ?? 1,
                selectable: relation != nil || (left == nil && right?.start == .zero) || right == nil || left?.end == right?.start,
                edge: edge, outgoingID: left?.id, incomingID: right?.id))
        }
        // Moving a clip can leave its fade/transition away from an ordinary
        // sequence boundary. Keep every explicit relation editable by identity.
        for relation in timeline.transitions where !built.contains(where: { $0.transition?.id == relation.id }) {
            let left = pictures.first { $0.id == relation.outgoing }, right = pictures.first { $0.id == relation.incoming }
            let edge = left == nil ? -1 : right == nil ? 1 : 0
            let timing = TransitionTiming(relation.settings, factor: relation.factor, edge: edge)
            let origin = relation.origin.seconds, end = max(0, origin + timing.upper)
            built.append(TransitionJoin(index: built.count, time: edge == -1 ? max(0, origin) : edge == 1 ? end : origin + timing.cut,
                range: max(0, origin + timing.lower)...end, maximum: min(left?.mapping.duration.seconds ?? 604800, right?.mapping.duration.seconds ?? 604800),
                transition: relation.settings, origin: origin, timing: timing, factor: relation.factor, edge: edge,
                outgoingID: left?.id, incomingID: right?.id))
        }
        // An opening fade belongs to its picture; it must not hide a real
        // adjacent cut when that picture was moved later in the project.
        for right in pictures where timeline.transitions.contains(where: { $0.incoming == right.id && $0.outgoing == nil }) {
            let ending = pictures.filter { $0.id != right.id && $0.end == right.start }
            if let left = ending.filter({ $0.layer <= right.layer }).max(by: TrackTimeline.backToFront) ?? ending.min(by: TrackTimeline.backToFront),
               !built.contains(where: { $0.outgoingID == left.id && $0.incomingID == right.id }) {
                let time = right.start.seconds
                built.append(TransitionJoin(index: built.count, time: time, range: time...time,
                    maximum: min(left.mapping.duration.seconds, right.mapping.duration.seconds), transition: nil,
                    outgoingID: left.id, incomingID: right.id))
            }
        }
        joins = built
        placements = pictures.enumerated().map { index, item in
            let incoming = built.first { $0.incomingID == item.id && $0.transition != nil }
            let outgoing = built.first { $0.outgoingID == item.id && $0.transition != nil }
            return TimelinePlacement(clip: clips[index], index: index, start: item.start.seconds,
                incoming: max(0, incoming?.timing.overlap ?? 0), outgoing: max(0, outgoing?.timing.overlap ?? 0),
                lower: incoming?.time ?? item.start.seconds, upper: outgoing?.time ?? item.end.seconds)
        }
    }
}
extension EditState {
    var layout: TimelineLayout { TimelineLayout(timeline: timeline) }
    func settingTransition(_ value: ClipTransition?, at index: Int) -> EditState {
        guard let boundary = layout.joins.first(where: { $0.index == index }), boundary.selectable else { return self }
        var edit = self
        let left = timeline.video.first { $0.id == boundary.outgoingID }
        let right = timeline.video.first { $0.id == boundary.incomingID }
        edit.timeline.transitions.removeAll { $0.outgoing == left?.id && $0.incoming == right?.id }
        edit.timeline.pruneRelations()
        guard var value else { return edit }
        // Each picture has one incoming and one outgoing transition slot.
        // A new cut transition replaces edge fades on those same sides.
        edit.timeline.transitions.removeAll { relation in
            (left.map { relation.outgoing == $0.id } ?? false) || (right.map { relation.incoming == $0.id } ?? false)
        }
        value.nextClipID = right?.id
        // Reserve neighbouring transition handles first. Fitting a newly
        // edited relation must never create intersecting transition windows.
        func timing(_ relation: TimelineTransition) -> TransitionTiming {
            TransitionTiming(relation.settings, factor: relation.factor, edge: relation.outgoing == nil ? -1 : relation.incoming == nil ? 1 : 0)
        }
        let incoming = left.flatMap { item in edit.timeline.transitions.first { $0.incoming == item.id } }
        let outgoing = right.flatMap { item in edit.timeline.transitions.first { $0.outgoing == item.id } }
        let leftFree = max(0, (left?.mapping.duration.seconds ?? 604800) - (incoming.map { timing($0).rightCost } ?? 0))
        let rightFree = max(0, (right?.mapping.duration.seconds ?? 604800) - (outgoing.map { timing($0).leftCost } ?? 0))
        let edge = left == nil ? -1 : right == nil ? 1 : 0
        func fits(_ factor: Double) -> Bool {
            let t = TransitionTiming(value, factor: factor, edge: edge)
            return t.leftCost <= leftFree + 0.00000001 && t.rightCost <= rightFree + 0.00000001
        }
        var factor = 1.0
        if !fits(1) {
            var lo = 0.0, hi = 1.0
            for _ in 0..<48 { let mid = (lo + hi) / 2; if fits(mid) { lo = mid } else { hi = mid } }
            factor = lo
        }
        let t = TransitionTiming(value, factor: factor, edge: edge)
        guard t.videoDuration >= TimelineEditing.frame - 0.000001 else { return edit }
        // Opening J-cuts may begin sound before the picture fade. Reserve
        // that lead-in at time zero instead of shifting the first take negative.
        let origin = left.map { $0.end - EditTime(t.leftEnd) }
            ?? max(.zero, (right?.start ?? .zero) - EditTime(t.rightStart))
        if let right {
            let nextStart = origin + EditTime(t.rightStart)
            let delta = nextStart - right.start
            let moving = edit.timeline.transitionShiftTargets(from: right, excluding: left)
            edit.timeline.shiftTransitionTail(moving, by: delta)
        }
        edit.timeline.transitions.append(TimelineTransition(outgoing: left?.id, incoming: right?.id, settings: value, origin: origin, factor: factor))
        edit.timeline.placements.removeAll { $0.participants == Set([left?.id, right?.id].compactMap { $0 }) }
        edit.timeline.pruneRelations()
        edit.timeline.synchronizeFollowers()
        return edit
    }
    func restoringStraightCut(at index: Int) -> EditState {
        guard let join = layout.joins.first(where: { $0.index == index }),
              let left = timeline.video.first(where: { $0.id == join.outgoingID }),
              let right = timeline.video.first(where: { $0.id == join.incomingID }) else { return settingTransition(nil, at: index) }
        var result = settingTransition(nil, at: index)
        let moving = result.timeline.transitionShiftTargets(from: right, excluding: left)
        result.timeline.shiftTransitionTail(moving, by: left.end - right.start)
        result.timeline.pruneRelations()
        return result
    }
}

private extension TrackTimeline {
    func transitionShiftTargets(from right: VideoTimelineItem, excluding left: VideoTimelineItem?) -> Set<UUID> {
        let linked = Set(links.flatMap(\.members))
        let pictures = Set(video.filter { $0.id != left?.id && ($0.id == right.id || (linked.contains($0.id) && $0.start >= right.start)) }.map(\.id))
        let sounds = audio.filter { sound in
            guard sound.followsVideo != left?.id || left == nil else { return false }
            if let follower = sound.followsVideo { return pictures.contains(follower) }
            return linked.contains(sound.id) && sound.start >= right.start
        }.map(\.id)
        return pictures.union(sounds)
    }
    mutating func shiftTransitionTail(_ moving: Set<UUID>, by delta: EditTime) {
        for i in video.indices where moving.contains(video[i].id) { video[i].start = video[i].start + delta }
        for i in audio.indices where moving.contains(audio[i].id) { audio[i].start = audio[i].start + delta }
        for i in transitions.indices {
            let members = Set([transitions[i].outgoing, transitions[i].incoming].compactMap { $0 })
            if members.isSubset(of: moving) { transitions[i].origin = transitions[i].origin + delta }
        }
    }
}
