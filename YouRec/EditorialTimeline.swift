import Foundation

/// An editable conform of the current edit. Media URLs are relative to the OTIO
/// document so the unzipped folder can move between machines.
enum EditorialTimeline {
    typealias Node = [String: Any]
    private struct Item {
        var start: EditTime
        var map: SourcePlaybackMap
        var source: SourceMedia
        var muted: Bool
        var incomingDissolve: Node?
        var end: EditTime { start + map.duration }
    }

    static func filename(for project: Project) -> String {
        let reserved = Set(project.mediaFiles.map { $0.lowercased() })
        var name = "Timeline.otio", index = 1
        while reserved.contains(name.lowercased()) { index += 1; name = "Timeline-\(index).otio" }
        return name
    }

    static func data(for project: Project) throws -> Data {
        let edit = project.edit.timeline
        let rate = Double(project.exportSettings.frameRate.rawValue)
        let media = Dictionary(uniqueKeysWithValues: project.sources.map { ($0.id, $0) })
        func time(_ frames: Double) -> Node { ["OTIO_SCHEMA": "RationalTime.1", "rate": rate, "value": frames] }
        func range(_ start: Double, _ length: Double) -> Node {
            ["OTIO_SCHEMA": "TimeRange.1", "start_time": time(start), "duration": time(length)]
        }
        func object(_ schema: String, _ name: String, _ fields: Node = [:]) -> Node {
            ["OTIO_SCHEMA": schema, "name": name, "metadata": Node(), "effects": [], "markers": [], "enabled": true,
             "source_range": NSNull()].merging(fields) { _, new in new }
        }
        func edge(_ time: EditTime) -> Double { (time.seconds * rate).rounded() }
        func gap(_ length: Double) -> Node { object("Gap.1", "", ["source_range": range(0, length)]) }
        func tracks(_ items: [Item], kind: String) -> [Node] {
            // Input picture order is back to front. Reuse a lane across cuts,
            // stacking only overlapping items above the material they obscure.
            var lanes: [[Item]] = []
            for item in items {
                var index = lanes.count
                while index > 0 {
                    let lane = lanes[index - 1]
                    var low = 0, high = lane.count
                    while low < high {
                        let mid = (low + high) / 2
                        if lane[mid].end <= item.start { low = mid + 1 } else { high = mid }
                    }
                    if low < lane.count && lane[low].start < item.end { break }
                    index -= 1
                }
                if index == lanes.count { lanes.append([]) }
                if let last = lanes[index].last, last.start > item.start {
                    let slot = lanes[index].firstIndex { $0.start > item.start } ?? lanes[index].endIndex
                    lanes[index].insert(item, at: slot)
                } else { lanes[index].append(item) }
            }
            return lanes.enumerated().map { n, lane in
                var children: [Node] = [], cursor = 0.0
                for item in lane {
                    if let dissolve = item.incomingDissolve { children.append(dissolve) }
                    var pos = item.start
                    for run in item.map.runs {
                        let start = edge(pos)
                        pos = pos + run.duration
                        let end = edge(pos), length = end - start
                        guard length > 0 else { continue }
                        if start > cursor { children.append(gap(start - cursor)) }
                        cursor = end
                        if kind == "Audio" && run.isHold { children.append(gap(length)); continue }
                        let ref: Node = ["OTIO_SCHEMA": "ExternalReference.1", "metadata": Node(), "name": item.source.originalName ?? item.source.filename,
                                         "available_range": range(0, item.source.duration * rate),
                                         "target_url": item.source.filename.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? item.source.filename]
                        var effects: [Node] = []
                        let scalar = (run.sourceEnd - run.sourceStart) / run.duration.seconds
                        if run.isHold || abs(scalar - 1) > 0.0001 {
                            let name = run.isHold ? "FreezeFrame" : "LinearTimeWarp"
                            effects.append(["OTIO_SCHEMA": name + ".1", "name": "", "effect_name": name, "metadata": Node(), "time_scalar": scalar])
                        }
                        children.append(object("Clip.2", item.source.originalName ?? item.source.filename, [
                            "source_range": range(run.sourceStart * rate, length), "effects": effects,
                            "enabled": kind != "Audio" || (!run.silent && !item.muted),
                            "active_media_reference_key": "DEFAULT_MEDIA", "media_references": ["DEFAULT_MEDIA": ref]
                        ]))
                    }
                }
                if edge(edit.duration) > cursor { children.append(gap(edge(edit.duration) - cursor)) }
                return object("Track.1", "\(kind) \(n + 1)", ["kind": kind, "children": children])
            }
        }
        let ordered = edit.video.sorted(by: TrackTimeline.backToFront)
        var picture: [Item] = try ordered.map { clip in
            guard let source = media[clip.content.sourceID] else { throw ProjectError.missingMedia }
            return Item(start: clip.start, map: clip.mapping, source: source, muted: false)
        }
        let index = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element.id, $0.offset) })
        var nativeJoins = Set<UUID>()
        // OTIO dissolves sit on a cut, with media handles on both sides. Only
        // collapse a two-shot overlap when both shots can occupy one picture lane.
        for join in edit.transitions where join.settings.style == .dissolve && join.settings.holdDuration == 0 {
            guard let outgoing = join.outgoing.flatMap({ index[$0] }), let incoming = join.incoming.flatMap({ index[$0] }) else { continue }
            let a = picture[outgoing], b = picture[incoming]
            let timing = TransitionTiming(join.settings, factor: join.factor)
            guard a.start < b.start, a.end > b.start, b.end > a.end,
                  abs((a.end - b.start).seconds - timing.videoDuration) < 0.0001,
                  abs((join.origin - b.start).seconds) < 0.0001,
                  !ordered.contains(where: { $0.id != join.outgoing && $0.id != join.incoming && $0.start < b.end && $0.end > a.start }) else { continue }
            let first = edge(b.start), last = edge(a.end), middle = ((first + last) / 2).rounded(.down)
            guard last > first else { continue }
            let cut = EditTime(middle / rate)
            guard cut > a.start, cut >= b.start, cut <= a.end, cut < b.end else { continue }
            picture[outgoing].map = a.map.sliced(EditInterval(.zero, cut - a.start))
            picture[incoming].map = b.map.sliced(EditInterval(cut - b.start, b.map.duration))
            picture[incoming].start = cut
            picture[incoming].incomingDissolve = ["OTIO_SCHEMA": "Transition.1", "name": "Dissolve", "metadata": Node(),
                "transition_type": "SMPTE_Dissolve", "in_offset": time(middle - first), "out_offset": time(last - middle)]
            nativeJoins.insert(join.id)
        }
        let sound: [Item] = try edit.audio.sorted { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start }.map { clip in
            guard let source = media[clip.sourceID] else { throw ProjectError.missingMedia }
            return Item(start: clip.start, map: clip.mapping, source: source, muted: clip.muted)
        }
        func marker(_ name: String, _ start: Double, _ duration: Double, _ color: String) -> Node {
            ["OTIO_SCHEMA": "Marker.2", "metadata": Node(), "name": name, "color": color, "marked_range": range(start, duration), "comment": ""]
        }
        var markers = edit.resolvedBookmarks.map { marker($0.bookmark.label.isEmpty ? "Bookmark" : $0.bookmark.label, edge($0.time), 0, "YELLOW") }
        for join in edit.transitions where !nativeJoins.contains(join.id) {
            let boundary = join.outgoing == nil ? -1 : join.incoming == nil ? 1 : 0
            let timing = TransitionTiming(join.settings, factor: join.factor, edge: boundary)
            let start = max(0, edge(join.origin)), end = min(edge(edit.duration), edge(join.origin + EditTime(timing.videoDuration)))
            markers.append(marker(join.settings.style.title, start, max(0, end - start), "PURPLE"))
        }
        let stack = object("Stack.1", "tracks", ["children": tracks(sound, kind: "Audio") + tracks(picture, kind: "Video"), "markers": markers])
        let timeline: Node = ["OTIO_SCHEMA": "Timeline.1", "name": project.title, "global_start_time": time(0), "tracks": stack, "metadata": Node()]
        return try JSONSerialization.data(withJSONObject: timeline, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
    }
}
