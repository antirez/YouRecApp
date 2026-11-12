import Foundation

// A hold is an inserted timeline segment referencing one original frame. It
// never removes or replaces the footage following the playhead.
struct FrozenFrameSegment: Codable, Equatable {
    var sourceTime: Double
    var duration: Double
    var offset = 0.0
    var valid: Bool { sourceTime.isFinite && sourceTime >= 0 && duration.isFinite && duration > 0 && duration <= 10 && offset.isFinite && offset >= 0 && offset <= 10 }
}
struct EffectPlaybackSpan {
    var start: Double
    var end: Double
    var rate: Double
    var duration: Double { (end-start)/rate }
}
extension TimelineClip {
    func sequenceRate(at time: Double) -> Double {
        (videoEffects ?? []).filter { $0.enabled && $0.start <= time && $0.end > time }.reduce(1) { result, effect in
            [.undercranking,.stepPrinting].contains(effect.kind) ? result * effect.number("speed",at:time) : result
        }
    }
    var sequenceRate: Double { sequenceRate(at:start) }
    var mutesSourceAudio: Bool { mutesSourceAudio(at: start) }
    func mutesSourceAudio(at time: Double) -> Bool {
        if frozenFrame != nil,videoEffects?.first(where:{$0.kind == .freezeFrame})?.choice("audio",at:time)=="Cut" { return true }
        return videoEffects?.contains { $0.enabled && $0.kind == .undercranking && $0.start <= time && $0.end > time && $0.toggle("mute",at:time) } == true
    }
    func audioContinues(into next:TimelineClip)->Bool {
        sourceID==next.sourceID && abs(end-next.start)<0.00001 && mutesSourceAudio==next.mutesSourceAudio && frozenFrame==nil && next.frozenFrame==nil
    }

    // One source clock for duration, seeking, audio and the compositor. Constant
    // ranges remain a single composition segment. Animated speed is subdivided
    // only where its change exceeds 1%; midpoint samples bound the rate steps
    // without generating thousands of segments for a long constant-speed shot.
    var effectPlaybackSpans: [EffectPlaybackSpan] {
        let effects=(videoEffects ?? []).filter { $0.enabled && [.undercranking,.stepPrinting].contains($0.kind) && $0.start < end && $0.end > start }
        let kept=keptIntervals
        guard !effects.isEmpty else { return kept.map { EffectPlaybackSpan(start:$0.start,end:$0.end,rate:rate) } }
        var points=[min(start,effects.map(\.start).min() ?? start),max(end,effects.map(\.end).max() ?? end)]
        for effect in effects {
            points += [effect.start,effect.end]
            points += effect.parameters.filter { ["speed","mute"].contains($0.id) }.flatMap { $0.keyframes.map(\.time) }
        }
        // Subdivide the effect's own source intervals, then intersect the result
        // with trims/pauses. Splitting a clip cannot move the integration grid.
        let boundaries=Array(Set(points)).sorted()
        var result:[EffectPlaybackSpan]=[]
        func add(_ a:Double,_ b:Double,_ depth:Int=0) {
            guard kept.contains(where:{$0.start<b && $0.end>a}) else { return }
            let r0=min(6,max(0.125,(speed?.rate ?? 1)*sequenceRate(at:a+0.0000001)))
            let r1=min(6,max(0.125,(speed?.rate ?? 1)*sequenceRate(at:b-0.0000001)))
            if depth < 12 && b-a > 1.0/30 && abs(log(r1/r0)) > 0.01 {
                let middle=(a+b)/2;add(a,middle,depth+1);add(middle,b,depth+1)
            } else {
                let value=min(6,max(0.125,(speed?.rate ?? 1)*sequenceRate(at:(a+b)/2)))
                for interval in kept where interval.start<b && interval.end>a {
                    result.append(EffectPlaybackSpan(start:max(a,interval.start),end:min(b,interval.end),rate:value))
                }
            }
        }
        for (a,b) in zip(boundaries,boundaries.dropFirst()) where b>a { add(a,b) }
        return result
    }
}
extension TimelineEditing {
    static func freezing(_ state: EditState, at time: Double) -> (EditState, UUID?) {
        let position = time >= state.duration-frame/2 ? state.duration : min(max(0, quantize(time)), max(0, state.duration-frame))
        guard let placement = state.layout.placement(at: position) else { return (state, nil) }
        let sourceTime = min(placement.clip.end-frame, max(placement.clip.start, placement.clip.sourceTime(at: position-placement.start)))
        var split = Self.split(state, at: position)
        // Inside an overlap there is no single underlying frame to hold.
        guard split.layout.joins.contains(where: { abs($0.time-position)<0.001 }) else { return (state, nil) }
        let join = split.layout.boundary(at: position)
        let index = split.clips.firstIndex { $0.id == join?.incomingID } ?? split.clips.count
        var hold = placement.clip; hold.id = UUID(); hold.start = sourceTime; hold.end = min(placement.clip.end, sourceTime+frame)
        hold.pauses = nil; hold.speed = nil; hold.openingTransition = nil; hold.transition = nil
        hold.frozenFrame = FrozenFrameSegment(sourceTime: sourceTime, duration: 3)
        hold.videoEffects = (hold.videoEffects ?? []).filter { $0.kind.descriptor.family != .time }
        let effect = VideoEffectSettings(.freezeFrame, start: sourceTime, end: hold.end)
        hold.videoEffects!.append(effect)
        split.clips.insert(hold, at: index)
        return (split.normalizedTools(), effect.id)
    }
}
