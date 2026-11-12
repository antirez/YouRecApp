import Foundation
// Fixed pre-independent-timeline oracle, used only by migration tests.
struct LegacyTimelineLayout {
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
            builtJoins.append(TransitionJoin(index: index, time: point, range: range, maximum: maximum, transition: settings[index], origin: origin, timing: t, factor: factors[index], edge: edge(index)))
        }
        joins = builtJoins
        placements = clips.indices.map { index in
            TimelinePlacement(clip: clips[index], index: index, start: starts[index], incoming: max(0, times[index].overlap), outgoing: max(0, times[index + 1].overlap),
                lower: builtJoins[index].time, upper: builtJoins[index + 1].time)
        }
    }
    func boundary(at time: Double) -> TransitionJoin? { joins.first { abs($0.time - time) < 0.0001 } }
    func placement(at time: Double) -> TimelinePlacement? { placements.first { time >= $0.lower && time < $0.upper } ?? (time >= duration ? placements.last : placements.first) }
    func transition(at time: Double) -> TransitionJoin? { joins.first { $0.transition != nil && time >= $0.range.lowerBound && time < $0.range.upperBound } }
}
