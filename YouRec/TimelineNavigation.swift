import Foundation

/// Transport stops, derived from the edit rather than persisted or inferred
/// from the visible chips. Half-open intervals make simultaneous ends/starts
/// one event. Comparing recipes (not UUIDs) skips a plain split on long press.
struct TimelineNavigation {
    let changes: [Double]
    let cutsAndChanges: [Double]

    init(_ edit: EditState = EditState()) {
        let timeline = edit.timeline, duration = timeline.duration
        var events: [EditTime: [String: Int]] = [:]
        var cuts: Set<EditTime> = [.zero, duration]
        // Land on the first output frame carrying the new treatment. One stop
        // per frame, including changes from several independently timed tracks.
        func frame(_ time: EditTime) -> EditTime {
            min(duration, max(.zero, EditTime(ceil(time.seconds * 30 - 0.00001) / 30)))
        }
        func add(_ token: String, _ range: EditInterval) {
            let a = frame(range.start), b = frame(range.end)
            guard b > a else { return }
            events[a, default: [:]][token, default: 0] += 1
            events[b, default: [:]][token, default: 0] -= 1
        }
        func recipe<T: Encodable>(_ kind: String, _ value: T, omit: Set<String> = []) -> String {
            // UUIDs identify UI/editor objects, not how they look or sound.
            // String parameter IDs remain significant. Analysis files are cache
            // artifacts; sampled/locked palettes and all actual values remain.
            func clean(_ object: Any, root: Bool = false) -> Any {
                if let fields = object as? [String: Any] {
                    return fields.reduce(into: [String: Any]()) { result, pair in
                        if root && omit.contains(pair.key) { return }
                        if pair.key == "id", let id = pair.value as? String, UUID(uuidString: id) != nil { return }
                        result[pair.key] = clean(pair.value)
                    }
                }
                if let array = object as? [Any] { return array.map { clean($0) } }
                return object
            }
            let encoder = JSONEncoder()
            guard let data = try? encoder.encode(value),
                  let object = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed),
                  let canonical = try? JSONSerialization.data(withJSONObject: clean(object, root: true), options: [.sortedKeys, .fragmentsAllowed]) else {
                assertionFailure("Invalid navigation recipe: \(kind)"); return kind
            }
            return kind + ":" + canonical.base64EncodedString()
        }
        let joins = edit.layout.joins.filter { $0.transition != nil }
        let compiled = timeline.compile()
        func addVideo(_ token: String, on item: VideoTimelineItem, range: EditInterval) {
            for span in compiled {
                guard let rank = span.video.firstIndex(of: item.id), let part = range.intersection(span.interval) else { continue }
                add("video.\(rank)." + token, part)
            }
        }
        func itemCut(_ time: EditTime, videoID: UUID?) {
            // Render handles inside a transition aren't extra user cuts. The
            // transition's visible join and its picture/sound edges are stops.
            let hidden = videoID.map { id in
                timeline.transitions.contains { relation in
                    guard relation.outgoing == id || relation.incoming == id,
                          let join = joins.first(where: { $0.transition?.id == relation.id }) else { return false }
                    return time.seconds > join.range.lowerBound + 0.00001 && time.seconds < join.range.upperBound - 0.00001
                }
            } ?? false
            if !hidden { cuts.insert(frame(time)) }
        }
        func sourceEffect<T: Encodable>(_ kind: String, _ value: T, start: Double, end: Double, on item: VideoTimelineItem, omit: Set<String> = ["start", "end"]) {
            let token = recipe(kind, value, omit: omit)
            var local = EditTime.zero
            for run in item.mapping.runs {
                defer { local = local + run.duration }
                if run.isHold {
                    if start <= run.sourceStart && end > run.sourceStart { addVideo(token, on: item, range: EditInterval(item.start + local, item.start + local + run.duration)) }
                } else {
                    let a = max(start, run.sourceStart), b = min(end, run.sourceEnd)
                    guard b > a else { continue }
                    let scale = run.duration.seconds / (run.sourceEnd - run.sourceStart)
                    addVideo(token, on: item, range: EditInterval(item.start + local + EditTime((a-run.sourceStart)*scale), item.start + local + EditTime((b-run.sourceStart)*scale)))
                }
            }
        }
        func internalCuts(_ mapping: SourcePlaybackMap, start: EditTime, videoID: UUID?) {
            var local = EditTime.zero
            for (left, right) in zip(mapping.runs, mapping.runs.dropFirst()) {
                local = local + left.duration
                if abs(left.sourceEnd - right.sourceStart) > 0.00001 || left.isHold != right.isHold { itemCut(start + local, videoID: videoID) }
            }
        }
        for item in timeline.video {
            let clip = item.content
            itemCut(item.start, videoID: item.id); itemCut(item.end, videoID: item.id)
            internalCuts(item.mapping, start: item.start, videoID: item.id)
            func whole<T: Encodable>(_ kind: String, _ value: T, omit: Set<String> = []) { addVideo(recipe(kind, value, omit: omit), on: item, range: item.interval) }
            if let value = clip.crop { whole("crop", value) }
            if let value = clip.mirror, value.horizontal || value.vertical { whole("mirror", value) }
            if let value = clip.speed, value.rate != 1 { whole("speed", value) }
            if let value = clip.color, value.look != .natural && value.amount > 0 { whole("color", value) }
            if let value = clip.stabilization, value.level != .off { whole("stabilize", value, omit: ["referenceStart", "referenceEnd"]) }
            if let value = clip.pauses { whole("pauses", value, omit: ["cuts", "candidates", "analyzed"]) }
            if clip.frozenFrame != nil { whole("freeze", true) }
            for value in clip.texts ?? [] where !value.text.isEmpty { sourceEffect("text", value, start: value.start, end: value.end, on: item) }
            for value in clip.images ?? [] where value.opacity > 0 { sourceEffect("image", value, start: value.start, end: value.end, on: item) }
            for value in clip.videoEffects ?? [] where value.enabled {
                if value.kind.descriptor.supportsIntensity, value.number("intensity") == 0,
                   value.parameters.first(where: { $0.id == "intensity" })?.keyframes.isEmpty != false { continue }
                sourceEffect("effect", value, start: value.start, end: value.end, on: item,
                             omit: ["start", "end", "analysisFile", "analysisDataFile", "capturedEffectID"])
            }
        }
        for item in timeline.audio {
            itemCut(item.start, videoID: item.followsVideo); itemCut(item.end, videoID: item.followsVideo)
            internalCuts(item.mapping, start: item.start, videoID: item.followsVideo)
            if item.muted { add("audio.muted", item.interval) }
            else if item.volumeDB != 0 { add(recipe("audio.volume", item.volumeDB), item.interval) }
            if let fade = item.fadeIn {
                add(recipe("audio.fadeIn", fade.seconds), EditInterval(item.start, item.start + EditTime(item.fadeSeconds(.fadeIn))))
            }
            if let fade = item.fadeOut {
                add(recipe("audio.fadeOut", fade.seconds), EditInterval(item.end - EditTime(item.fadeSeconds(.fadeOut)), item.end))
            }
            for region in item.censors {
                add(recipe("audio.censor", region.settings), EditInterval(item.start + region.interval.start, item.start + region.interval.end))
            }
            for region in item.enhancements {
                let chain = region.effects.filter { $0.enabled && $0.supported }
                guard !chain.isEmpty, let range = item.interval.intersection(EditInterval(item.start + region.interval.start, item.start + region.interval.end)) else { continue }
                add(recipe("audio.enhancement", chain), range)
            }
        }
        // Captions are one tool, not hundreds of effect changes. Navigate to
        // its first visible sentence; speech gaps and later sentences are
        // navigated inside the subtitle editor instead.
        let subtitleStart = timeline.subtitleCues.map(\.start).min().map { frame(EditTime($0)) }
        for plan in compiled where plan.video.count > 1 {
            if plan.placementID == nil, plan.video.count == 2,
               timeline.transitions.contains(where: { plan.transitionIDs.contains($0.id) && Set([$0.outgoing, $0.incoming].compactMap { $0 }) == Set(plan.video) }) { continue }
            let placement = timeline.placements.first { $0.id == plan.placementID }
            let values = plan.video.map { placement?.videos[$0] ?? VideoPlacement() }
            add(recipe("placement", values), plan.interval)
        }
        for join in joins {
            guard let value = join.transition else { continue }
            cuts.insert(frame(EditTime(join.time)))
            add(recipe("transition.picture", value), EditInterval(join.videoRange))
            // J/L cuts have independent picture and sound boundaries. A hold
            // inside the crossfade is still the same transition, not a new stop.
            let a = join.edge == -1 ? join.audioIn.lowerBound : join.edge == 1 ? join.audioOut.lowerBound : min(join.audioIn.lowerBound, join.audioOut.lowerBound)
            let b = join.edge == -1 ? join.audioIn.upperBound : join.edge == 1 ? join.audioOut.upperBound : max(join.audioIn.upperBound, join.audioOut.upperBound)
            add(recipe("transition.sound", value), EditInterval(a...b))
        }
        var boundaries: Set<EditTime> = [.zero, duration]
        if let subtitleStart { boundaries.insert(subtitleStart) }
        for (time, delta) in events where delta.values.contains(where: { $0 != 0 }) { boundaries.insert(time) }
        changes = boundaries.sorted().map(\.seconds)
        cutsAndChanges = cuts.union(boundaries).sorted().map(\.seconds)
    }

    func destination(from time: Double, forward: Bool, effectsOnly: Bool = false) -> Double? {
        let stops = effectsOnly ? changes : cutsAndChanges
        // AVPlayer's current time can be just either side of the exact seek.
        // Less than half a frame is the same anchor, never a repeated jump.
        let tolerance = 1.0 / 120
        return forward ? stops.first { $0 > time + tolerance } : stops.last { $0 < time - tolerance }
    }
}
