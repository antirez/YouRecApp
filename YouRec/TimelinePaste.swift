import Foundation

/// A clipboard destination on the exact edit clock. At coincident cuts, the
/// user can choose the picture sequence or the independent sound sequence.
struct TimelinePasteTarget: Equatable {
    enum Kind { case picture, sound, project }
    enum Anchor: Equatable {
        case between(left: UUID, right: UUID)
        case start, end, gap
    }
    let kind: Kind
    let time: EditTime
    let anchor: Anchor
    var transition: UUID?

    func isAt(_ playhead: EditTime) -> Bool {
        // Next change lands on the first presentation frame after a subframe
        // edit. Pin the original exact cut even when reached by transport.
        let frameTicks = EditTime.scale / 30
        let displayFrame = ((time.ticks + frameTicks - 1) / frameTicks) * frameTicks
        return abs(time.ticks - playhead.ticks) < 24 || playhead.ticks == displayFrame
    }

    func label(in timeline: TrackTimeline) -> String {
        switch anchor {
        case .start: return "Start"
        case .end: return "End"
        case .gap: return "Gap"
        case let .between(left, right):
            let ids = kind == .picture ? timeline.video.map(\.id) : timeline.audio.map(\.id)
            let prefix = kind == .picture ? "V" : "A"
            func number(_ id: UUID) -> String { ids.firstIndex(of: id).map { prefix + String($0 + 1) } ?? prefix }
            return (kind == .picture ? "Video" : "Audio") + " · " + number(left) + " | " + number(right)
        }
    }
}

extension TrackTimeline {
    func pasteTargets(layout: TimelineLayout) -> [TimelinePasteTarget] {
        let pictures = layout.joins.compactMap { join -> TimelinePasteTarget? in
            guard join.selectable, let left = join.outgoingID, let right = join.incomingID else { return nil }
            return TimelinePasteTarget(kind: .picture, time: EditTime(join.time), anchor: .between(left: left, right: right), transition: join.transition?.id)
        }
        let pictureIDs = Set(video.map(\.id))
        let linked = Set(links.filter { !$0.members.isDisjoint(with: pictureIDs) }.flatMap(\.members))
        let independent = audio.filter { !linked.contains($0.id) }
        let starts = Dictionary(grouping: independent, by: \.start), ends = Dictionary(grouping: independent, by: \.end)
        var cuts = pictures
        for time in ends.keys.sorted() {
            guard let left = ends[time], let right = starts[time] else { continue }
            let pairs = Self.neighbors(atCut: left.map { ($0.id, $0.occurrenceID) }, incoming: right.map { ($0.id, $0.occurrenceID) })
            cuts += pairs.map { TimelinePasteTarget(kind: .sound, time: time, anchor: .between(left: $0, right: $1)) }
        }
        guard !video.isEmpty || !audio.isEmpty else { return cuts }
        let coverage = videoCoverage
        if let first = coverage.first, let last = coverage.last {
            cuts.append(TimelinePasteTarget(kind: .picture, time: first.start, anchor: .start))
            cuts.append(TimelinePasteTarget(kind: .picture, time: last.end, anchor: .end))
        }
        // A score can extend beyond the last picture, or precede the first.
        // Both the picture edge and the actual project edge are useful targets.
        let outerKind: TimelinePasteTarget.Kind = video.isEmpty ? .sound : .project
        if coverage.first?.start != .zero { cuts.append(TimelinePasteTarget(kind: outerKind, time: .zero, anchor: .start)) }
        if coverage.last?.end != duration { cuts.append(TimelinePasteTarget(kind: outerKind, time: duration, anchor: .end)) }
        return cuts
    }

    /// Snapshot only the chosen media. Collapse empty space between unrelated
    /// selections while retaining real overlaps and offsets inside linked groups.
    func clipboardFragment(_ selected: TimelineSelection, keepGaps: Bool) -> TimelineClipboard {
        var fragment = self
        fragment.video.removeAll { !selected.video.contains($0.id) }
        fragment.audio.removeAll { !selected.audio.contains($0.id) }
        fragment.placements = placementsKeeping(selected.video)
        fragment.pruneRelations()
        let visibleMarks = Set(fragment.resolvedBookmarks.map(\.id))
        fragment.bookmarks.removeAll { mark in
            if case .project = mark.anchor { return true }
            return !visibleMarks.contains(mark.id)
        }
        let spans = Dictionary(uniqueKeysWithValues: fragment.video.map { ($0.id, $0.interval) } + fragment.audio.map { ($0.id, $0.interval) })
        var occupied = Array(spans.values) + fragment.generated.map(\.interval)
        for group in fragment.links {
            let ranges = group.members.compactMap { spans[$0] }
            if let start = ranges.map(\.start).min(), let end = ranges.map(\.end).max() { occupied.append(EditInterval(start, end)) }
        }
        var islands = Self.union(occupied)
        if keepGaps, let first = islands.first, let last = islands.last {
            islands = [EditInterval(first.start, last.end)]
        }
        if let first = islands.first {
            var island = 0, offset = EditTime.zero - first.start
            var starts: [UUID: EditTime] = [:]
            for (id, range) in spans.sorted(by: { $0.value.start < $1.value.start }) {
                while island + 1 < islands.count && range.start >= islands[island + 1].start {
                    offset = offset - (islands[island + 1].start - islands[island].end)
                    island += 1
                }
                starts[id] = range.start + offset
            }
            for i in fragment.video.indices { fragment.video[i].start = starts[fragment.video[i].id]! }
            for i in fragment.audio.indices { fragment.audio[i].start = starts[fragment.audio[i].id]! }
            fragment.pruneRelations()
        }
        if !fragment.audio.contains(where: { !($0.subtitleWords ?? []).isEmpty }) { fragment.subtitles = nil }
        let pictureIDs = Set(fragment.video.map(\.id)), soundIDs = Set(fragment.audio.map(\.id))
        let inserts = fragment.links.contains { !$0.members.isDisjoint(with: pictureIDs) && !$0.members.isDisjoint(with: soundIDs) }
        return TimelineClipboard(timeline: fragment, insertsTime: inserts)
    }

    private func placementsKeeping(_ ids: Set<UUID>) -> [VideoPlacementRegion] {
        var kept = placements.filter { $0.participants.isSubset(of: ids) }
        for region in placements {
            let shared = region.participants.intersection(ids)
            guard shared.count >= 2, !kept.contains(where: { $0.participants == shared }) else { continue }
            kept.append(VideoPlacementRegion(participants: shared, videos: region.videos.filter { shared.contains($0.key) }))
        }
        return kept
    }

    /// Capture the very fragments that are lifted (a range split creates new IDs).
    /// The caller publishes the clipboard only after the project save succeeds.
    mutating func cutToClipboard(_ targets: TimelineSelection, preserving point: EditTime) -> (clipboard: TimelineClipboard, position: EditTime)? {
        var scoped = scoped(targets)
        let clip = scoped.timeline.clipboardFragment(scoped.selection, keepGaps: targets.range != nil)
        guard !clip.isEmpty else { return nil }
        scoped.timeline.placements = scoped.timeline.placementsKeeping(Set(scoped.timeline.video.map(\.id)).subtracting(scoped.selection.video))
        let position = scoped.timeline.remove(scoped.selection, preserving: point) ?? point
        let copiedMarks = Set(clip.timeline.bookmarks.map(\.id))
        let remainingMarks = Set(scoped.timeline.resolvedBookmarks.map(\.id))
        scoped.timeline.bookmarks.removeAll { copiedMarks.contains($0.id) && !remainingMarks.contains($0.id) }
        self = scoped.timeline
        return (clip, position)
    }

    mutating func preparePaste(_ clipboard: TimelineClipboard, at point: EditTime, target: TimelinePasteTarget?) -> EditTime {
        let length = clipboard.timeline.duration
        guard let target else {
            let position = max(.zero, min(duration, point))
            if clipboard.insertsTime { return insertPictureTime(length, at: position) }
            return position
        }
        let hasPicture = !clipboard.timeline.video.isEmpty
        var destination = target.time
        switch target.anchor {
        case .start, .gap:
            if hasPicture {
                let site: VideoInsertionSite = target.anchor == .gap ? .gap(after: target.time) : .start
                let placement = site.placement(in: self, length: length)
                destination = target.kind == .project ? .zero : placement.start
                if placement.ripple > .zero {
                    if target.anchor == .gap { insertTime(placement.ripple, at: placement.rippleAt, atPictureGap: true) }
                    else { move(TimelineSelection(video: Set(video.map(\.id))), by: placement.ripple) }
                }
            } else if target.kind == .sound {
                let leadingSilence = audio.map(\.start).min() ?? .zero
                move(entireSelection(), by: max(.zero, length - leadingSilence))
            }
        case .end:
            break
        case let .between(_, right):
            if hasPicture {
                destination = insertPictureTime(length, at: destination, pictureOnRight: target.kind == .picture ? right : nil, transition: target.transition)
            } else if target.kind == .sound {
                let chain = moveChoices(for: selection(of: right)).right.audio
                let tail = Set(audio.filter { chain.contains($0.id) && $0.start >= destination }.map(\.id))
                split(at: destination, selection: TimelineSelection(audio: tail))
                for i in audio.indices where tail.contains(audio[i].id) { audio[i].start = audio[i].start + length }
            }
        }
        return destination
    }

    /// Open the picture sequence and its production sound, leaving independent
    /// music continuous. If the insertion separates a dissolve, use its full handles.
    private mutating func insertPictureTime(_ length: EditTime, at point: EditTime, pictureOnRight: UUID? = nil, transition: UUID? = nil) -> EditTime {
        let crossing = generated.filter { $0.interval.start < point && point < $0.interval.end }.map(\.owner)
        let broken = Set(crossing + [transition].compactMap { $0 })
        for id in transitions.map(\.id) where broken.contains(id) {
            let edit = EditState(timeline: self)
            if let join = edit.layout.joins.first(where: { $0.transition?.id == id }) {
                self = edit.restoringStraightCut(at: join.index).timeline
            }
        }
        let position = pictureOnRight.flatMap { id in video.first { $0.id == id }?.start } ?? point
        split(at: position, selection: TimelineSelection(video: Set(video.map(\.id))))
        let tail = expanded(TimelineSelection(video: Set(video.filter { $0.start >= position }.map(\.id))))
        for i in video.indices where tail.video.contains(video[i].id) { video[i].start = video[i].start + length }
        for i in audio.indices where tail.audio.contains(audio[i].id) { audio[i].start = audio[i].start + length }
        for i in bookmarks.indices {
            if case .project(let t) = bookmarks[i].anchor, t >= position { bookmarks[i].anchor = .project(t + length) }
        }
        return position
    }

}
