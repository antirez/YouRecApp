import Foundation

/// The edit clock is exact for 48 kHz sound and 24/25/30/50/60 fps,
/// including 24000/1001, 30000/1001 and 60000/1001. Source PTS remains separate.
struct EditTime: Codable, Hashable, Comparable, Sendable {
    static let scale: Int64 = 240_000
    var ticks: Int64
    init(ticks: Int64) { self.ticks = ticks }
    init(_ seconds: Double) { ticks = seconds.isFinite ? Int64((min(604_800, max(-604_800, seconds)) * Double(Self.scale)).rounded()) : 0 }
    var seconds: Double { Double(ticks) / Double(Self.scale) }
    static let zero = EditTime(ticks: 0)
    static func < (a: Self, b: Self) -> Bool { a.ticks < b.ticks }
    static func + (a: Self, b: Self) -> Self { Self(ticks: a.ticks + b.ticks) }
    static func - (a: Self, b: Self) -> Self { Self(ticks: a.ticks - b.ticks) }
}

struct EditInterval: Codable, Hashable, Sendable {
    var start: EditTime
    var end: EditTime
    init(_ start: EditTime, _ end: EditTime) { self.start = start; self.end = end }
    init(_ range: ClosedRange<Double>) { start = EditTime(range.lowerBound); end = EditTime(range.upperBound) }
    var duration: EditTime { end - start }
    var isEmpty: Bool { end <= start }
    func contains(_ time: EditTime) -> Bool { start <= time && time < end }
    func intersection(_ other: Self) -> Self? {
        let result = Self(max(start, other.start), min(end, other.end))
        return result.isEmpty ? nil : result
    }
    var seconds: ClosedRange<Double> { start.seconds...max(start.seconds, end.seconds) }
}

/// Each run maps an exact local interval to original source timestamps. A hold
/// has equal source endpoints and is silent; no duplicate dialogue is inserted.
struct PlaybackRun: Codable, Equatable {
    var duration: EditTime
    var sourceStart: Double
    var sourceEnd: Double
    var silent = false
    var isHold: Bool { sourceStart == sourceEnd }
    func source(at offset: EditTime) -> Double {
        guard duration > .zero else { return sourceStart }
        return sourceStart + (sourceEnd - sourceStart) * min(1, max(0, offset.seconds / duration.seconds))
    }
}
struct SourcePlaybackMap: Codable, Equatable {
    var runs: [PlaybackRun]
    var duration: EditTime { EditTime(ticks: runs.reduce(0) { $0 + $1.duration.ticks }) }
    init(runs: [PlaybackRun]) { self.runs = runs }
    init(_ clip: TimelineClip) {
        if let hold = clip.frozenFrame {
            runs = [PlaybackRun(duration: EditTime(hold.duration), sourceStart: hold.sourceTime, sourceEnd: hold.sourceTime, silent: true)]
        } else {
            // Round cumulative boundaries, not each run's length, to carry the
            // rounding residual across a long sequence of speed changes/cuts.
            var total = 0.0, prior = EditTime.zero
            runs = clip.effectPlaybackSpans.map { span in
                total += span.duration
                let boundary = EditTime(total), duration = boundary - prior
                prior = boundary
                return PlaybackRun(duration: duration, sourceStart: span.start, sourceEnd: span.end,
                                   silent: clip.mutesSourceAudio(at: (span.start + span.end) / 2))
            }.filter { $0.duration > .zero }
        }
    }
    func applyingMute(from clip: TimelineClip) -> Self {
        let boundaries = clip.effectPlaybackSpans.flatMap { [$0.start, $0.end] }
        var result: [PlaybackRun] = []
        for run in runs {
            if run.isHold { var hold = run; hold.silent = true; result.append(hold); continue }
            let points = Array(Set([run.sourceStart, run.sourceEnd] + boundaries.filter { $0 > run.sourceStart && $0 < run.sourceEnd })).sorted()
            var prior = EditTime.zero
            for (a, b) in zip(points, points.dropFirst()) {
                let end = b == run.sourceEnd ? run.duration : EditTime(run.duration.seconds * (b - run.sourceStart) / (run.sourceEnd - run.sourceStart))
                if end > prior { result.append(PlaybackRun(duration: end - prior, sourceStart: a, sourceEnd: b, silent: clip.mutesSourceAudio(at: (a + b) / 2))) }
                prior = end
            }
        }
        return Self(runs: result)
    }
    func source(at local: EditTime) -> Double? {
        var cursor = EditTime.zero
        for run in runs {
            if local < cursor + run.duration { return run.source(at: max(.zero, local - cursor)) }
            cursor = cursor + run.duration
        }
        return local == duration ? runs.last?.sourceEnd : nil
    }
    func local(forSource time: Double) -> EditTime? {
        var cursor = EditTime.zero
        for run in runs {
            if !run.isHold, time >= run.sourceStart, time < run.sourceEnd {
                return cursor + EditTime(run.duration.seconds * (time - run.sourceStart) / (run.sourceEnd - run.sourceStart))
            }
            cursor = cursor + run.duration
        }
        return nil
    }
    func sliced(_ interval: EditInterval) -> Self {
        var cursor = EditTime.zero, result: [PlaybackRun] = []
        for run in runs {
            let end = cursor + run.duration
            if let part = EditInterval(cursor, end).intersection(interval) {
                result.append(PlaybackRun(duration: part.duration, sourceStart: run.source(at: part.start - cursor), sourceEnd: run.source(at: part.end - cursor), silent: run.silent))
            }
            cursor = end
        }
        return Self(runs: result)
    }
}

struct VideoTimelineItem: Codable, Equatable, Identifiable {
    var id: UUID { content.id }
    var occurrenceID: UUID
    var start: EditTime
    var content: TimelineClip
    var layer = 0
    var localOrigin = EditTime.zero
    var mapping: SourcePlaybackMap
    init(occurrenceID: UUID, start: EditTime, content: TimelineClip, layer: Int = 0) {
        self.occurrenceID = occurrenceID; self.start = start; self.content = content; self.layer = layer
        mapping = SourcePlaybackMap(content)
    }
    var end: EditTime { start + mapping.duration }
    var interval: EditInterval { EditInterval(start, end) }
}
struct AudioEnhancementRegion: Codable, Equatable, Identifiable {
    var id = UUID()
    /// Local coordinates, independent of the item's placement in the project.
    var interval: EditInterval
    var effects: [AudioEffect]
}
/// A split inside a fade inherits its slope and its level at the cut.
struct AudioEdgeFade: Codable, Equatable {
    let seconds: Double
    var elapsed = 0.0

    var valid: Bool { seconds > 0 && seconds <= 604800 && elapsed >= 0 && elapsed < seconds }
    func remaining(in length: Double) -> Double { min(length, seconds - elapsed) }
    func trimming(_ amount: EditTime) -> Self? {
        var part = self
        part.elapsed = (EditTime(elapsed) + amount).seconds
        return part.elapsed < seconds ? part : nil
    }
    func fitted(from oldLength: EditTime, to newLength: EditTime) -> Self {
        let visible = remaining(in: oldLength.seconds)
        guard newLength > .zero && newLength.seconds < visible else { return self }
        let scale = newLength.seconds / visible
        return Self(seconds: seconds * scale, elapsed: elapsed * scale)
    }
    func gain(_ distanceFromEdge: Double) -> Double { min(1, max(0, (elapsed + distanceFromEdge) / seconds)) }
}

enum AudioFadeEdge: String, CaseIterable, Identifiable {
    case fadeIn, fadeOut
    var id: Self { self }
    var title: String { self == .fadeIn ? "Fade in" : "Fade out" }
    func index(in audio: [AudioTimelineItem], selected: Set<UUID>) -> Int? {
        // Select just one item if several share an edge. The lowest timeline
        // audio number wins the tie, and is named alongside the control.
        audio.indices.filter { selected.contains(audio[$0].id) }.min {
            self == .fadeIn ? audio[$0].start < audio[$1].start : audio[$0].end > audio[$1].end
        }
    }
}

struct AudioTimelineItem: Codable, Equatable, Identifiable {
    var id = UUID()
    var occurrenceID: UUID
    var sourceID: UUID
    var start: EditTime
    var mapping: SourcePlaybackMap
    var localOrigin = EditTime.zero
    var followsVideo: UUID?
    var volumeDB = 0.0
    var muted = false
    var fadeIn: AudioEdgeFade?
    var fadeOut: AudioEdgeFade?
    var enhancements: [AudioEnhancementRegion] = []
    var censorRegions: [AudioCensorRegion]?
    var censors: [AudioCensorRegion] {
        get { censorRegions ?? [] }
        set { censorRegions = newValue.isEmpty ? nil : newValue }
    }
    var subtitleWords: [SubtitleWord]?
    var end: EditTime { start + mapping.duration }
    var interval: EditInterval { EditInterval(start, end) }
    var gain: Double { muted ? 0 : pow(10, volumeDB / 20) }
    func fadeSeconds(_ edge: AudioFadeEdge) -> Double {
        (edge == .fadeIn ? fadeIn : fadeOut)?.remaining(in: mapping.duration.seconds) ?? 0
    }
    mutating func setFade(_ edge: AudioFadeEdge, seconds: Double) {
        let length = min(mapping.duration, max(.zero, EditTime(seconds))).seconds
        let fade = length > 0 ? AudioEdgeFade(seconds: length) : nil
        if edge == .fadeIn { fadeIn = fade } else { fadeOut = fade }
    }
    func sliced(_ part: EditInterval, id: UUID) -> Self {
        var result = self
        result.id = id; result.start = start + part.start
        result.localOrigin = localOrigin + part.start
        result.mapping = mapping.sliced(part)
        result.fadeIn = fadeIn?.trimming(part.start)
        result.fadeOut = fadeOut?.trimming(mapping.duration - part.end)
        result.censors = censors.compactMap { $0.sliced(part) }
        result.enhancements = enhancements.compactMap { region in
            guard let intersection = region.interval.intersection(part) else { return nil }
            var region = region
            region.interval = EditInterval(intersection.start - part.start, intersection.end - part.start)
            return region
        }
        return result
    }
}

extension TrackTimeline {
    /// Audio overlays do not ripple the picture or any existing sound.
    @discardableResult
    mutating func insertAudio(_ source: SourceMedia, at position: EditTime) -> UUID {
        let item = AudioTimelineItem(occurrenceID: UUID(), sourceID: source.id, start: max(.zero, position),
            mapping: SourcePlaybackMap(runs: [PlaybackRun(duration: EditTime(source.duration), sourceStart: 0, sourceEnd: source.duration)]))
        audio.append(item)
        return item.id
    }
}
struct TimelineLink: Codable, Equatable, Identifiable {
    var id = UUID()
    var members: Set<UUID>
}
struct TimelineSelection: Equatable {
    var video: Set<UUID> = []
    var audio: Set<UUID> = []
    var range: EditInterval?
    var ids: Set<UUID> { video.union(audio) }
    var isEmpty: Bool { ids.isEmpty }
    var title: String { video.isEmpty ? "Audio" : audio.isEmpty ? "Video" : "Video + audio" }
    var countTitle: String {
        [video.isEmpty ? nil : "\(video.count) video\(video.count == 1 ? "" : "s")",
         audio.isEmpty ? nil : "\(audio.count) audio part\(audio.count == 1 ? "" : "s")"].compactMap { $0 }.joined(separator: " + ")
    }
}

enum TimelineMoveScope: String, CaseIterable {
    case selected, left, right, both

    var includesLeft: Bool { self == .left || self == .both }
    var includesRight: Bool { self == .right || self == .both }
}

// Picture cuts and independent sound cuts at the same time are different joins.
private enum MoveBoundary: Hashable {
    case video(EditTime), audio(EditTime)
}

struct TimelineMoveChoices {
    var selected = TimelineSelection()
    var left = TimelineSelection()
    var right = TimelineSelection()
    var both = TimelineSelection()

    subscript(_ scope: TimelineMoveScope) -> TimelineSelection {
        switch scope {
        case .selected: return selected
        case .left: return left
        case .right: return right
        case .both: return both
        }
    }

    func available(_ scope: TimelineMoveScope) -> Bool {
        switch scope {
        case .selected: return true
        case .left: return left != selected
        case .right: return right != selected
        case .both: return both != left && both != right
        }
    }
}

enum TimelineLinkError: LocalizedError {
    case tooFew, nonContiguous, noIntersection, confirmationRequired, transitionBoundary
    var errorDescription: String? {
        switch self {
        case .tooFew: return "Tap a part to select it, then long-press other video or audio parts to add them. Long-press again to remove a part from the selection."
        case .nonContiguous: return "Non-contiguous parts selected. Each video or audio sequence must meet edge to edge, without gaps or overlaps. Move the parts together with Snap, then try Link again."
        case .noIntersection: return "The selected video and audio do not overlap in time. Move them to a shared interval before linking."
        case .confirmationRequired: return "Video and audio cover different times. Link only their intersection?"
        case .transitionBoundary: return "The shared time starts or ends inside a transition. Adjust or remove that transition before linking the intersection."
        }
    }
}
struct TimelineLinkPlan {
    var selection: TimelineSelection
    var video: EditInterval?
    var audio: EditInterval?
    var needsIntersection: Bool { video != nil && audio != nil && video != audio }
    var intersection: EditInterval? { guard let video, let audio else { return nil }; return video.intersection(audio) }
}

/// The start of the explicitly picked material stays the alignment point even
/// when Move includes neighbors. Targets use the original edit clock for the
/// entire gesture session, so moving the draft never creates another stop.
struct TimelineMoveBoundaries {
    let anchor: EditTime
    let times: [EditTime]

    init() { anchor = .zero; times = [] }

    init(timeline: TrackTimeline, picked: TimelineSelection, moving: TimelineSelection) {
        guard let original = timeline.interval(for: picked), let group = timeline.interval(for: moving) else {
            self.init(); return
        }
        let layout = timeline.transitions.isEmpty ? nil : TimelineLayout(timeline: timeline)
        let members = moving.ids
        var stops: Set<EditTime> = [.zero, original.start, timeline.duration]
        for (id, span) in displayIntervals(timeline, folding: layout) where !members.contains(id) {
            stops.insert(span.start); stops.insert(span.end)
        }
        for join in layout?.joins ?? [] where join.transition != nil {
            let partners = [join.outgoingID, join.incomingID].compactMap { $0 }
            if partners.contains(where: { !members.contains($0) }) { stops.insert(EditTime(join.time)) }
        }
        let earliest = original.start - group.start
        let latest = original.start + EditTime(604800) - group.end
        self.init(anchor: original.start, times: stops.filter { earliest <= $0 && $0 <= latest }.sorted())
    }

    private init(anchor: EditTime, times: [EditTime]) { self.anchor = anchor; self.times = times }

    func previous(from time: EditTime) -> EditTime? { times.last { $0 < time } }
    func next(from time: EditTime) -> EditTime? { times.first { $0 > time } }
}

struct TimelineMoveSnap: Equatable {
    var target: EditTime
    var edge: EditTime
}
struct TimelineMoveResult {
    var delta: EditTime
    var snap: TimelineMoveSnap?
}

enum BookmarkAnchor: Codable, Equatable {
    case source(occurrence: UUID, source: UUID, time: Double)
    case local(occurrence: UUID, offset: EditTime)
    case project(EditTime)
}
struct TimelineBookmark: Codable, Equatable, Identifiable {
    var id = UUID()
    var label = ""
    var anchor: BookmarkAnchor
}
struct ResolvedBookmark: Identifiable {
    let bookmark: TimelineBookmark
    let time: EditTime
    var id: UUID { bookmark.id }
}
enum PlacementCropEdge: String, CaseIterable {
    case left, right, top, bottom
    var horizontal: Bool { self == .left || self == .right }
}
struct PlacementEdgeCrop: Codable, Equatable {
    static let minimumSpan = 0.02
    var left = 0.0
    var right = 0.0
    var top = 0.0
    var bottom = 0.0
    var isEmpty: Bool { left == 0 && right == 0 && top == 0 && bottom == 0 }
    var valid: Bool {
        [left, right, top, bottom].allSatisfy { $0.isFinite && $0 >= 0 }
            && left + right <= 1 - Self.minimumSpan + 0.0000001
            && top + bottom <= 1 - Self.minimumSpan + 0.0000001
    }
    subscript(_ edge: PlacementCropEdge) -> Double {
        get { switch edge { case .left: return left; case .right: return right; case .top: return top; case .bottom: return bottom } }
        set { switch edge { case .left: left = newValue; case .right: right = newValue; case .top: top = newValue; case .bottom: bottom = newValue } }
    }
}
struct VideoPlacement: Codable, Equatable {
    var x = 0.5
    var y = 0.5
    var width = 1.0
    var height = 1.0
    var framing = TransitionFraming()
    var fill = true
    var order = 0
    // Independent clipping after framing/placement. It must never participate
    // in Fit/Fill or recenter/rescale the picture when an edge is dragged.
    var motion: EffectAnimation?
    var edgeCrop: PlacementEdgeCrop?
    func window(in canvas: CGSize) -> CGRect {
        CGRect(x: (x - width / 2) * canvas.width, y: (y - height / 2) * canvas.height,
               width: width * canvas.width, height: height * canvas.height)
    }
    func visibleWindow(in canvas: CGSize) -> CGRect {
        let full = pictureWindow(in: canvas), crop = edgeCrop ?? PlacementEdgeCrop()
        return CGRect(x: full.minX + crop.left * full.width, y: full.minY + crop.top * full.height,
                      width: full.width * (1 - crop.left - crop.right), height: full.height * (1 - crop.top - crop.bottom))
    }
    /// Fit can leave transparent space inside the window. Handles and margins
    /// follow the picture, never that empty band. Scaling remains crop-independent.
    func pictureWindow(in canvas: CGSize) -> CGRect {
        let full = window(in: canvas)
        guard !fill else { return full }
        let scale = min(width, height)
        return CGRect(x: full.midX - canvas.width * scale / 2, y: full.midY - canvas.height * scale / 2,
                      width: canvas.width * scale, height: canvas.height * scale)
    }
    static func layout(_ kind: Int, index: Int, count: Int) -> Self {
        var value = Self(); value.order = index
        if kind == 1 { value.width = 1 / Double(max(1, count)); value.x = (Double(index) + 0.5) * value.width }
        if kind == 2 { value.height = 1 / Double(max(1, count)); value.y = (Double(index) + 0.5) * value.height }
        if kind == 3 && index > 0 {
            let total = max(1, count - 1), columns = total <= 3 ? 1 : Int(ceil(sqrt(Double(total))))
            let rows = Int(ceil(Double(total) / Double(columns))), gap = 0.02
            let side = min(0.32, (0.9 - Double(max(columns, rows) - 1) * gap) / Double(max(columns, rows)))
            value.width = side; value.height = side
            value.x = 0.94 - side / 2 - Double((index - 1) % columns) * (side + gap)
            value.y = 0.94 - side / 2 - Double((index - 1) / columns) * (side + gap)
        }
        return value
    }
    /// Translate the actual source crop by the finger distance in the preview.
    /// Framing stores a source-space center. Resolve its actual clamped center
    /// first, then account for window scale; screen fractions drift at zoom and
    /// can leave a long dead zone when reversing a drag at the image edge.
    mutating func reframe(by translation: CGSize, canvas: CGSize) {
        let window = window(in: canvas)
        let crop = framing.crop(source: canvas, viewport: fill ? window.size : canvas)
        let scale = fill ? max(window.width / crop.width, window.height / crop.height) : min(window.width / crop.width, window.height / crop.height)
        guard scale.isFinite, scale > 0 else { return }
        framing.x = min(canvas.width - crop.width / 2, max(crop.width / 2, crop.midX - translation.width / scale)) / canvas.width
        framing.y = min(canvas.height - crop.height / 2, max(crop.height / 2, crop.midY - translation.height / scale)) / canvas.height
    }
    /// One stable order for the compositor, inspector stills and hit testing.
    static func ordered(_ ids: [UUID], settings: [UUID: VideoPlacement]) -> [UUID] {
        let fallback = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
        return ids.sorted {
            let a = settings[$0]?.order ?? fallback[$0]!, b = settings[$1]?.order ?? fallback[$1]!
            return a == b ? fallback[$0]! < fallback[$1]! : a < b
        }
    }
    mutating func crop(_ edge: PlacementCropEdge, to position: Double, canvas: CGSize = CGSize(width: 1920, height: 1080), minimumPoints: Double = 0) {
        guard position.isFinite else { return }
        let picture = pictureWindow(in: canvas)
        let full = CGRect(x: picture.minX / canvas.width, y: picture.minY / canvas.height,
                          width: picture.width / canvas.width, height: picture.height / canvas.height)
        var crop = edgeCrop ?? PlacementEdgeCrop()
        let maximum = 1 - min(1, max(PlacementEdgeCrop.minimumSpan, minimumPoints / (edge.horizontal ? picture.width : picture.height)))
        switch edge {
        case .left: crop.left = min(max(crop.left, maximum - crop.right), max(0, (position - full.minX) / full.width))
        case .right: crop.right = min(max(crop.right, maximum - crop.left), max(0, (full.maxX - position) / full.width))
        case .top: crop.top = min(max(crop.top, maximum - crop.bottom), max(0, (position - full.minY) / full.height))
        case .bottom: crop.bottom = min(max(crop.bottom, maximum - crop.top), max(0, (full.maxY - position) / full.height))
        }
        edgeCrop = crop.isEmpty ? nil : crop
    }
}
struct VideoPlacementRegion: Codable, Equatable, Identifiable {
    var id = UUID()
    var participants: Set<UUID>
    var videos: [UUID: VideoPlacement]
}
struct TimelineTransition: Codable, Equatable, Identifiable {
    var id: UUID { settings.id }
    var outgoing: UUID?
    var incoming: UUID?
    var settings: ClipTransition
    /// Persist the resolved picture/sound placement. Rendering never ripples.
    var origin: EditTime
    var factor = 1.0
}
struct TimelineGeneratedRegion: Codable, Equatable, Identifiable {
    var id: UUID
    var owner: UUID
    var interval: EditInterval
    var freezeVideo: UUID?
}
struct CompiledTimelineInterval {
    var interval: EditInterval
    var video: [UUID]
    var audio: [UUID]
    var placementID: UUID?
    var transitionIDs: [UUID]
}

/// Canonical independent-item edit. There is no inferred magnetic track: ripple
/// is an explicit edit command and a link records selection membership only.
struct TrackTimeline: Codable, Equatable {
    // Transient provenance follows tool drafts; it is not rendering data.
    var captureBase: Int?
    private enum CodingKeys: String, CodingKey { case video, audio, links, bookmarks, placements, transitions, generated, subtitles }
    static func == (a: Self, b: Self) -> Bool {
        a.video == b.video && a.audio == b.audio && a.links == b.links && a.bookmarks == b.bookmarks
            && a.placements == b.placements && a.transitions == b.transitions && a.generated == b.generated && a.subtitles == b.subtitles
    }
    var video: [VideoTimelineItem] = []
    var audio: [AudioTimelineItem] = []
    var links: [TimelineLink] = []
    var bookmarks: [TimelineBookmark] = []
    var placements: [VideoPlacementRegion] = []
    var transitions: [TimelineTransition] = []
    var generated: [TimelineGeneratedRegion] = []
    var subtitles: SubtitleSettings?
    var duration: EditTime { max(video.map(\.end).max() ?? .zero, audio.map(\.end).max() ?? .zero, generated.map { $0.interval.end }.max() ?? .zero) }
    var allIDs: Set<UUID> { Set(video.map(\.id) + audio.map(\.id)) }

    init() {}
    /// One-time conversion of a development-format sequential edit. Capture IDs
    /// give deterministic counterpart IDs, so converting Undo snapshots agrees.
    init(sequence: EditState) { self = sequence.timeline }
    init(clips: [TimelineClip], effects: [AudioEffect] = [], pictureOnlySources: Set<UUID> = []) {
        let layout = TimelineLayout(clips: clips)
        for item in layout.placements {
            var clip = item.clip; clip.openingTransition = nil; clip.transition = nil
            video.append(VideoTimelineItem(occurrenceID: clip.id, start: EditTime(item.start), content: clip, layer: item.index))
            if pictureOnlySources.contains(clip.sourceID) { continue }
            let audioID = Self.counterpart(clip.id)
            var sound = AudioTimelineItem(id: audioID, occurrenceID: clip.id, sourceID: clip.sourceID, start: EditTime(item.start), mapping: SourcePlaybackMap(clip))
            if !effects.isEmpty { sound.enhancements = [AudioEnhancementRegion(id: audioID, interval: EditInterval(.zero, sound.mapping.duration), effects: effects)] }
            sound.followsVideo = clip.id
            audio.append(sound)
            links.append(TimelineLink(id: clip.id, members: [clip.id, audioID]))
        }
        generated = layout.joins.compactMap { join in
            guard let transition = join.transition, join.range.upperBound > join.range.lowerBound else { return nil }
            return TimelineGeneratedRegion(id: Self.counterpart(transition.id), owner: transition.id,
                interval: EditInterval(join.range), freezeVideo: transition.style == .still && join.index > 0 ? clips[join.index - 1].id : nil)
        }
        transitions = layout.joins.compactMap { join in
            guard let settings = join.transition else { return nil }
            return TimelineTransition(outgoing: join.index > 0 ? clips[join.index - 1].id : nil,
                incoming: join.index < clips.count ? clips[join.index].id : nil,
                settings: settings, origin: EditTime(join.origin), factor: join.factor)
        }
    }
    static func counterpart(_ id: UUID) -> UUID {
        var bytes = id.uuid
        bytes.15 ^= 0x80
        return UUID(uuid: bytes)
    }
    func expanded(_ selection: TimelineSelection) -> TimelineSelection {
        var result = selection
        for group in links where !group.members.isDisjoint(with: selection.ids) {
            result.video.formUnion(video.filter { group.members.contains($0.id) }.map(\.id))
            result.audio.formUnion(audio.filter { group.members.contains($0.id) }.map(\.id))
        }
        return result
    }
    func selection(of id: UUID, linked: Bool = true, range: EditInterval? = nil) -> TimelineSelection {
        let members = linked ? links.first(where: { $0.members.contains(id) })?.members ?? [id] : [id]
        return TimelineSelection(video: Set(video.filter { members.contains($0.id) }.map(\.id)), audio: Set(audio.filter { members.contains($0.id) }.map(\.id)), range: range)
    }
    func items(usingSources ids: Set<UUID>) -> TimelineSelection {
        TimelineSelection(video: Set(video.filter { ids.contains($0.content.sourceID) }.map(\.id)),
                          audio: Set(audio.filter { ids.contains($0.sourceID) }.map(\.id)))
    }
    func entireSelection(range: EditInterval? = nil) -> TimelineSelection {
        TimelineSelection(video: Set(video.map(\.id)), audio: Set(audio.map(\.id)), range: range)
    }
    func selection(ids: Set<UUID>) -> TimelineSelection {
        expanded(TimelineSelection(video: ids.intersection(Set(video.map(\.id))), audio: ids.intersection(Set(audio.map(\.id)))))
    }
    func toggling(_ id: UUID, in selected: Set<UUID>) -> Set<UUID> {
        let group = selection(of: id).ids
        return group.isSubset(of: selected) ? selected.subtracting(group) : selected.union(group)
    }
    func isSingleLink(_ selection: TimelineSelection) -> Bool {
        links.contains { $0.members == selection.ids }
    }
    func interval(for selection: TimelineSelection) -> EditInterval? {
        if let range = selection.range { return range }
        let intervals = video.filter { selection.video.contains($0.id) }.map(\.interval) + audio.filter { selection.audio.contains($0.id) }.map(\.interval)
        guard let start = intervals.map(\.start).min(), let end = intervals.map(\.end).max() else { return nil }
        return EditInterval(start, end)
    }
    mutating func unlink(_ selection: TimelineSelection) {
        let members = Set(links.filter { !$0.members.isDisjoint(with: selection.ids) }.flatMap(\.members))
        for i in audio.indices where members.contains(audio[i].id) { audio[i].followsVideo = nil }
        links.removeAll { !$0.members.isDisjoint(with: selection.ids) }
    }
    /// Establish horizontal continuity first, then compare the two resulting
    /// spans. Different source files/effects remain separate render items; the
    /// link glues their selection and movement without flattening any media.
    func linkPlan(_ selection: TimelineSelection) throws -> TimelineLinkPlan {
        let selection = expanded(selection)
        guard selection.ids.count >= 2, selection.range == nil else { throw TimelineLinkError.tooFew }
        func chain(_ parts: [(UUID?, EditInterval)]) throws -> EditInterval? {
            let sorted = parts.sorted { $0.1.start < $1.1.start }
            guard let first = sorted.first else { return nil }
            for pair in zip(sorted, sorted.dropFirst()) where pair.0.1.end != pair.1.1.start {
                // A real transition connects two sequential parts even though
                // its handles overlap. Arbitrary stacked videos are not a chain.
                let transitionJoin = pair.0.1.end > pair.1.1.start && pair.0.0 != nil && pair.1.0 != nil
                    && transitions.contains { $0.outgoing == pair.0.0 && $0.incoming == pair.1.0 }
                guard transitionJoin else { throw TimelineLinkError.nonContiguous }
            }
            return EditInterval(first.1.start, sorted.map { $0.1.end }.max()!)
        }
        let plan = try TimelineLinkPlan(selection: selection,
            video: chain(video.filter { selection.video.contains($0.id) }.map { ($0.id, $0.interval) }),
            audio: chain(audio.filter { selection.audio.contains($0.id) }.map { ($0.followsVideo, $0.interval) }))
        if plan.needsIntersection && plan.intersection == nil { throw TimelineLinkError.noIntersection }
        if plan.needsIntersection, let shared = plan.intersection {
            for transition in transitions {
                guard let a = video.first(where: { $0.id == transition.outgoing && selection.video.contains($0.id) }),
                      let b = video.first(where: { $0.id == transition.incoming && selection.video.contains($0.id) }) else { continue }
                if [shared.start, shared.end].contains(where: { b.start < $0 && $0 < a.end }) {
                    throw TimelineLinkError.transitionBoundary
                }
            }
        }
        return plan
    }
    /// Pure draft: cancellation cannot split footage or create a history entry.
    func joining(_ selection: TimelineSelection, intersectionOnly: Bool = false) throws -> (timeline: Self, selection: TimelineSelection) {
        let plan = try linkPlan(selection)
        guard !plan.needsIntersection || intersectionOnly else { throw TimelineLinkError.confirmationRequired }
        var target = plan.selection
        if plan.needsIntersection { target.range = plan.intersection }
        var result = scoped(target)
        let members = result.selection.ids
        result.timeline.links = result.timeline.links.compactMap { group in
            var remaining = group; remaining.members.subtract(members)
            return remaining.members.count >= 2 ? remaining : nil
        }
        result.timeline.links.append(TimelineLink(members: members))
        // Preserve existing sample-aligned followers. Re-linking a matching
        // original pair also restores its source-time relationship for Speed.
        for i in result.timeline.audio.indices where result.selection.audio.contains(result.timeline.audio[i].id) {
            let sound = result.timeline.audio[i]
            if sound.followsVideo == nil,
               let picture = result.timeline.video.first(where: { result.selection.video.contains($0.id)
                   && $0.occurrenceID == sound.occurrenceID && $0.content.sourceID == sound.sourceID
                   && $0.start == sound.start && $0.mapping == sound.mapping }) {
                result.timeline.audio[i].followsVideo = picture.id
            }
        }
        result.timeline.pruneRelations()
        return result
    }
    typealias CutNeighbor = (id: UUID, occurrence: UUID)

    /// A cut can coincide across several layers. Match both halves of the
    /// same occurrence before assigning the remaining neighbors in lane order.
    static func neighbors(atCut outgoing: [CutNeighbor], incoming: [CutNeighbor]) -> [(UUID, UUID)] {
        var available = incoming, unmatched: [CutNeighbor] = [], pairs: [(UUID, UUID)] = []
        for part in outgoing {
            if let i = available.firstIndex(where: { $0.occurrence == part.occurrence }) {
                pairs.append((part.id, available.remove(at: i).id))
            } else { unmatched.append(part) }
        }
        pairs.append(contentsOf: zip(unmatched, available).map { ($0.id, $1.id) })
        return pairs
    }

    /// Resolve companions on the scoped, undragged timeline once per Move session.
    /// An ordinary overlap is a separate layer; a transition explicitly joins its two pictures.
    func moveChoices(for selected: TimelineSelection) -> TimelineMoveChoices {
        let seed = expanded(selected)
        let pictures = Set(video.map(\.id)), sounds = Set(audio.map(\.id))
        let pictureLinks = links.filter { !$0.members.isDisjoint(with: pictures) }
        let linkedToPicture = Set(pictureLinks.flatMap(\.members))
        let groupByMember = Dictionary(uniqueKeysWithValues: links.flatMap { group in group.members.map { ($0, group) } })

        // A transition owns the cut on the corresponding side of each participant.
        var previous: [UUID: UUID] = [:], next: [UUID: UUID] = [:]
        func join(_ a: UUID, _ b: UUID) { previous[b] = a; next[a] = b }
        for relation in transitions {
            if let a = relation.outgoing, let b = relation.incoming { join(a, b) }
        }
        var starts: [MoveBoundary: [CutNeighbor]] = [:], ends: [MoveBoundary: [CutNeighbor]] = [:]
        for picture in video.sorted(by: Self.backToFront) {
            let part = (picture.id, picture.occurrenceID)
            if previous[picture.id] == nil { starts[.video(picture.start), default: []].append(part) }
            if next[picture.id] == nil { ends[.video(picture.end), default: []].append(part) }
        }
        // Independent sound has its own joins. A soundtrack can span many picture gaps.
        for sound in audio where !linkedToPicture.contains(sound.id) {
            let part = (sound.id, sound.occurrenceID)
            starts[.audio(sound.start), default: []].append(part)
            ends[.audio(sound.end), default: []].append(part)
        }
        for (cut, outgoing) in ends {
            for (a, b) in Self.neighbors(atCut: outgoing, incoming: starts[cut] ?? []) { join(a, b) }
        }
        func following(_ neighbors: [UUID: UUID]) -> TimelineSelection {
            var members = seed.ids, pending = Array(members), visitedLinks = Set<UUID>()
            func include(_ id: UUID) { if members.insert(id).inserted { pending.append(id) } }
            while let id = pending.popLast() {
                if let group = groupByMember[id], visitedLinks.insert(group.id).inserted {
                    group.members.forEach(include)
                }
                if let neighbor = neighbors[id] { include(neighbor) }
            }
            return TimelineSelection(video: members.intersection(pictures), audio: members.intersection(sounds))
        }
        let left = following(previous), right = following(next)
        let both = TimelineSelection(video: left.video.union(right.video), audio: left.audio.union(right.audio))
        return TimelineMoveChoices(selected: seed, left: left, right: right, both: both)
    }

    /// Shift all selected members by one clamped offset; never clamp individually
    /// because doing so would destroy their existing synchronization/offset.
    mutating func move(_ selection: TimelineSelection, by delta: EditTime) {
        let selection = expanded(selection)
        guard let range = interval(for: TimelineSelection(video: selection.video, audio: selection.audio)) else { return }
        let amount = max(EditTime.zero - range.start, delta)
        guard amount != .zero else { return }
        let previous = video
        for i in video.indices where selection.video.contains(video[i].id) { video[i].start = video[i].start + amount }
        promoteNewOverlaps(selection.video, previous: previous)
        for i in audio.indices where selection.audio.contains(audio[i].id) { audio[i].start = audio[i].start + amount }
        for i in transitions.indices {
            let relation = transitions[i]
            let participants = Set([relation.outgoing, relation.incoming].compactMap { $0 })
            if participants.isSubset(of: selection.video) { transitions[i].origin = transitions[i].origin + amount }
        }
        for i in generated.indices {
            if let relation = transitions.first(where: { $0.id == generated[i].owner }),
               Set([relation.outgoing, relation.incoming].compactMap { $0 }).isSubset(of: selection.video) {
                generated[i].interval = EditInterval(generated[i].interval.start + amount, generated[i].interval.end + amount)
            }
        }
        retainPlacementAcrossNewOverlaps(moving: selection.video)
        pruneRelations()
    }
    /// A newly dropped overlay comes forward. Adjusting an existing overlap
    /// must not silently swap the picture merely to fix its timing.
    private mutating func promoteNewOverlaps(_ selected: Set<UUID>, previous: [VideoTimelineItem]) {
        let old = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0.interval) })
        let stationary = video.filter { !selected.contains($0.id) }
        guard video.contains(where: { item in
            selected.contains(item.id) && stationary.contains { other in
                item.interval.intersection(other.interval) != nil && old[item.id]?.intersection(old[other.id] ?? other.interval) == nil
            }
        }) else { return }
        let front = (video.map(\.layer).max() ?? 0) + 1
        let order = video.indices.filter { selected.contains(video[$0].id) }.sorted { Self.backToFront(video[$0], video[$1]) }
        for (rank, index) in order.enumerated() { video[index].layer = front + rank }
    }
    static func backToFront(_ a: VideoTimelineItem, _ b: VideoTimelineItem) -> Bool {
        a.layer == b.layer ? a.id.uuidString < b.id.uuidString : a.layer < b.layer
    }
    mutating func setVolume(_ db: Double, muted: Bool, selection: TimelineSelection) {
        for i in audio.indices where selection.audio.contains(audio[i].id) { audio[i].volumeDB = min(12, max(-60, db)); audio[i].muted = muted }
    }
    mutating func enhance(_ effects: [AudioEffect], selection: TimelineSelection, effectID: UUID = UUID()) {
        for i in audio.indices where selection.audio.contains(audio[i].id) {
            let item = audio[i]
            let target: EditInterval
            if let range = selection.range { guard let part = item.interval.intersection(range) else { continue }; target = part }
            else { target = item.interval }
            let local = EditInterval(target.start - item.start, target.end - item.start)
            var regions: [AudioEnhancementRegion] = []
            for region in item.enhancements {
                if region.interval.intersection(local) == nil { regions.append(region); continue }
                if region.interval.start < local.start {
                    var left = region; left.interval.end = local.start; regions.append(left)
                }
                if region.interval.end > local.end {
                    var right = region; right.interval.start = local.end; regions.append(right)
                }
            }
            if !effects.isEmpty { regions.append(AudioEnhancementRegion(id: effectID, interval: local, effects: effects)) }
            audio[i].enhancements = regions.sorted { $0.interval.start < $1.interval.start }
        }
    }
    /// Return the new position of the content under the playhead. Use the same
    /// resolved shifts as deletion (not the selected duration: overlaps and
    /// detached tracks may leave some or all of that time in place).
    @discardableResult
    mutating func remove(_ selection: TimelineSelection, preserving position: EditTime? = nil) -> EditTime? {
        guard !selection.isEmpty else { return position }
        let oldVideo = video, oldAudio = audio, oldLinks = links, oldDuration = duration
        // Only complete linked groups qualify. A range is split before this call.
        let complete = oldLinks.filter { !$0.members.isDisjoint(with: selection.video) && !$0.members.isDisjoint(with: selection.audio) && $0.members.isSubset(of: selection.ids) }
        let removedVideo = Set(complete.flatMap { $0.members }).intersection(selection.video)
        let closing = Self.union(oldVideo.filter { removedVideo.contains($0.id) }.map(\.interval))
        let audioIDs = Set(audio.map(\.id)), videoIDs = Set(video.map(\.id))
        let downstreamGroups = oldLinks.filter { $0.members.isDisjoint(with: selection.ids)
            && !$0.members.isDisjoint(with: audioIDs) && !$0.members.isDisjoint(with: videoIDs) }
        let downstreamIDs = Set(downstreamGroups.flatMap(\.members))
        let remainingVideo = oldVideo.filter { !selection.video.contains($0.id) && downstreamIDs.contains($0.id) }
        // P and N are remaining linked picture edges. This closes only the
        // newly vacated space, including the handles of removed transitions.
        let closedGaps: [EditInterval] = closing.compactMap { range in
            let before = remainingVideo.filter { $0.start < range.start }.map(\.end).max() ?? range.start
            let after = remainingVideo.filter { $0.start >= range.start }.map(\.start).min() ?? range.end
            let start = max(range.start, before), end = min(range.end, after)
            return end > start ? EditInterval(start, end) : nil
        }
        video.removeAll { selection.video.contains($0.id) }
        audio.removeAll { selection.audio.contains($0.id) }
        for group in downstreamGroups {
            let positions = oldVideo.filter { group.members.contains($0.id) }.map(\.start)
            let anchor = positions.min() ?? audio.filter { group.members.contains($0.id) }.map(\.start).min() ?? .zero
            let amount = closedGaps.filter { $0.start <= anchor }.reduce(EditTime.zero) { $0 + $1.duration }
            for i in video.indices where group.members.contains(video[i].id) { video[i].start = video[i].start - amount }
            for i in audio.indices where group.members.contains(audio[i].id) { audio[i].start = audio[i].start - amount }
        }
        for i in transitions.indices {
            if let owner = transitions[i].outgoing ?? transitions[i].incoming,
               let prior = oldVideo.first(where: { $0.id == owner }), let current = video.first(where: { $0.id == owner }) {
                transitions[i].origin = transitions[i].origin + current.start - prior.start
            }
        }
        pruneRelations()
        guard let position else { return nil }
        let removedTime = closedGaps.reduce(EditTime.zero) { total, gap in
            total + min(gap.duration, max(.zero, position - gap.start))
        }
        if closedGaps.contains(where: { $0.contains(position) }) {
            return min(duration, max(.zero, position - removedTime))
        }
        func contains(_ interval: EditInterval) -> Bool {
            interval.contains(position) || (position == oldDuration && interval.end == position)
        }
        // Preserve the visible occurrence, even if an unrelated layer rippled.
        // Audio is the anchor only when there was no picture here to begin with.
        var mapped: EditTime?
        if let picture = oldVideo.filter({ contains($0.interval) }).max(by: { $0.layer < $1.layer }) {
            if let kept = video.first(where: { $0.id == picture.id }) { mapped = position + kept.start - picture.start }
        } else if let sound = oldAudio.first(where: { contains($0.interval) }),
                  let kept = audio.first(where: { $0.id == sound.id }) { mapped = position + kept.start - sound.start }
        // Inside deleted footage, land at its resulting cut. With no ripple
        // (unlinked picture/sound), the existing gap and clock stay unchanged.
        return min(duration, max(.zero, mapped ?? position - removedTime))
    }
    static func union(_ ranges: [EditInterval]) -> [EditInterval] {
        var result: [EditInterval] = []
        for range in ranges.sorted(by: { $0.start < $1.start }) where !range.isEmpty {
            if let last = result.last, range.start <= last.end { result[result.count - 1].end = max(last.end, range.end) }
            else { result.append(range) }
        }
        return result
    }
    mutating func retainUniqueTransitionSlots() {
        var incoming = Set<UUID>(), outgoing = Set<UUID>()
        transitions = transitions.reversed().filter { relation in
            guard !(relation.incoming.map(incoming.contains) ?? false), !(relation.outgoing.map(outgoing.contains) ?? false) else { return false }
            if let id = relation.incoming { incoming.insert(id) }
            if let id = relation.outgoing { outgoing.insert(id) }
            return true
        }.reversed()
        let owners = Set(transitions.map(\.id))
        generated.removeAll { !owners.contains($0.owner) }
    }
    mutating func pruneRelations() {
        let ids = allIDs
        links = links.compactMap { link in var link = link; link.members.formIntersection(ids); return link.members.count >= 2 ? link : nil }
        placements.removeAll { region in
            let members = video.filter { region.participants.contains($0.id) }
            guard members.count == region.participants.count, members.count > 1,
                  let lower = members.map(\.start).max(), let upper = members.map(\.end).min() else { return true }
            return lower >= upper
        }
        transitions = transitions.compactMap { saved in
            var relation = saved
            let a = relation.outgoing.flatMap { id in video.first { $0.id == id } }
            let b = relation.incoming.flatMap { id in video.first { $0.id == id } }
            if relation.outgoing != nil && a == nil || relation.incoming != nil && b == nil { return nil }
            let edge = a == nil ? -1 : b == nil ? 1 : 0
            if let a, let b {
                let requiredOverlap = (a.end - b.start).seconds
                var lo = 0.0, hi = 1.0
                let original = TransitionTiming(relation.settings, factor: relation.factor)
                if abs(original.overlap - requiredOverlap) > 2.0 / Double(EditTime.scale) {
                    let low = TransitionTiming(relation.settings, factor: 0).overlap
                    let high = TransitionTiming(relation.settings, factor: 1).overlap
                    guard requiredOverlap >= min(low, high) - 0.00001 && requiredOverlap <= max(low, high) + 0.00001 else { return nil }
                    for _ in 0..<48 {
                        let mid = (lo + hi) / 2
                        let overlap = TransitionTiming(relation.settings, factor: mid).overlap
                        if (overlap < requiredOverlap) == (high >= low) { lo = mid } else { hi = mid }
                    }
                    relation.factor = (lo + hi) / 2
                }
                let timing = TransitionTiming(relation.settings, factor: relation.factor)
                guard timing.leftCost <= a.mapping.duration.seconds + 0.00001, timing.rightCost <= b.mapping.duration.seconds + 0.00001 else { return nil }
                relation.origin = a.end - EditTime(timing.leftEnd)
                guard abs((relation.origin + EditTime(timing.rightStart) - b.start).ticks) <= 2 else { return nil }
            } else {
                let timing = TransitionTiming(relation.settings, factor: relation.factor, edge: edge)
                if let a { relation.origin = a.end - EditTime(timing.leftEnd) }
                if let b { relation.origin = b.start - EditTime(timing.rightStart) }
            }
            return relation
        }
        retainUniqueTransitionSlots()
        generated = transitions.map { relation in
            let edge = relation.outgoing == nil ? -1 : relation.incoming == nil ? 1 : 0
            let timing = TransitionTiming(relation.settings, factor: relation.factor, edge: edge)
            return TimelineGeneratedRegion(id: Self.counterpart(relation.id), owner: relation.id,
                interval: EditInterval(max(.zero, relation.origin + EditTime(timing.lower)), max(.zero, relation.origin + EditTime(timing.upper))),
                freezeVideo: relation.settings.style == .still ? relation.outgoing : nil)
        }
        for i in audio.indices {
            if let id = audio[i].followsVideo, !links.contains(where: { $0.members.contains(id) && $0.members.contains(audio[i].id) }) { audio[i].followsVideo = nil }
        }
    }

    var resolvedBookmarks: [ResolvedBookmark] {
        bookmarks.compactMap { bookmark -> ResolvedBookmark? in
            let time: EditTime?
            switch bookmark.anchor {
            case .project(let value): time = value
            case .source(let occurrence, let source, let point):
                time = video.filter { $0.occurrenceID == occurrence && $0.content.sourceID == source }.compactMap { item in item.mapping.local(forSource: point).map { item.start + $0 } }.first
                    ?? audio.filter { $0.occurrenceID == occurrence && $0.sourceID == source }.compactMap { item in item.mapping.local(forSource: point).map { item.start + $0 } }.first
            case .local(let occurrence, let offset):
                time = video.first(where: { $0.occurrenceID == occurrence && offset >= $0.localOrigin && offset < $0.localOrigin + $0.mapping.duration }).map { $0.start + offset - $0.localOrigin }
            }
            return time.map { ResolvedBookmark(bookmark: bookmark, time: $0) }
        }.sorted { $0.time == $1.time ? $0.id.uuidString < $1.id.uuidString : $0.time < $1.time }
    }
    /// A newly overlapping third video must not reset the existing windows.
    /// Geometry follows shared items; new items retain their normal layer slot.
    func placementSeed(participants: Set<UUID>, near position: EditTime, moving: Set<UUID> = []) -> VideoPlacementRegion {
        if let exact = placements.first(where: { $0.participants == participants }) { return exact }
        let members = video.filter { participants.contains($0.id) }.sorted(by: Self.backToFront)
        let canonical = members.map(\.id)
        func distance(_ region: VideoPlacementRegion) -> Double {
            let items = video.filter { region.participants.contains($0.id) }
            let lower = items.map(\.start).max() ?? .zero, upper = items.map(\.end).min() ?? .zero
            return max(0, lower.seconds - position.seconds, position.seconds - upper.seconds)
        }
        let candidates = placements.filter { !$0.participants.isDisjoint(with: participants) }.sorted {
            let a = $0.participants.intersection(participants).count, b = $1.participants.intersection(participants).count
            if a != b { return a > b }
            let da = distance($0), db = distance($1)
            return da == db ? $0.id.uuidString < $1.id.uuidString : da < db
        }
        var values = Dictionary(uniqueKeysWithValues: members.map { item in
            (item.id, candidates.first(where: { region in
                region.videos[item.id] != nil && (moving.contains(item.id)
                    || region.participants.intersection(participants).count > 1 || distance(region) < 0.00001)
            })?.videos[item.id] ?? VideoPlacement())
        })
        var order = canonical
        for region in candidates.reversed() {
            let slots = order.indices.filter { region.participants.contains(order[$0]) }
            let shared = VideoPlacement.ordered(slots.map { order[$0] }, settings: region.videos)
            for (slot, id) in zip(slots, shared) { order[slot] = id }
        }
        for (rank, id) in order.enumerated() { values[id]?.order = rank }
        return VideoPlacementRegion(participants: participants, videos: values)
    }
    private mutating func retainPlacementAcrossNewOverlaps(moving: Set<UUID>) {
        guard !placements.isEmpty, !moving.isEmpty else { return }
        let original = self
        var seen = Set(placements.map(\.participants))
        for interval in compile() where interval.video.count > 1 && !Set(interval.video).isDisjoint(with: moving) {
            let ids = Set(interval.video)
            guard seen.insert(ids).inserted else { continue }
            let seed = original.placementSeed(participants: ids, near: interval.interval.start, moving: moving)
            let defaults = Dictionary(uniqueKeysWithValues: interval.video.enumerated().map { rank, id in
                var value = VideoPlacement(); value.order = rank; return (id, value)
            })
            if seed.videos != defaults { placements.append(seed) }
        }
    }
    /// Audio edits can subdivide a visual overlap. Merge those subdivisions,
    /// but never include a time where the inspector's visible layers differ.
    func placementPreviewInterval(participants: Set<UUID>, near position: Double, preferred: ClosedRange<Double>) -> EditInterval? {
        let spans = Self.union(compile().filter { Set($0.video) == participants && $0.video.count > 1 }.map(\.interval))
        return spans.first { $0.contains(EditTime(position)) }
            ?? spans.first { $0.intersection(EditInterval(preferred)) != nil }
            ?? spans.first
    }
    func compile() -> [CompiledTimelineInterval] {
        var edges: Set<EditTime> = [.zero, duration]
        for item in video { edges.insert(item.start); edges.insert(item.end) }
        for item in audio {
            edges.insert(item.start); edges.insert(item.end)
            for region in item.enhancements { edges.insert(item.start + region.interval.start); edges.insert(item.start + region.interval.end) }
            for region in item.censors { edges.insert(item.start + region.interval.start); edges.insert(item.start + region.interval.end) }
        }
        for region in generated { edges.insert(region.interval.start); edges.insert(region.interval.end) }
        for relation in transitions {
            let edge = relation.outgoing == nil ? -1 : relation.incoming == nil ? 1 : 0
            let timing = TransitionTiming(relation.settings, factor: relation.factor, edge: edge)
            for value in [timing.lower, timing.upper, 0, timing.videoDuration, timing.audioIn.lowerBound, timing.audioIn.upperBound, timing.audioOut.lowerBound, timing.audioOut.upperBound] {
                edges.insert(max(.zero, relation.origin + EditTime(value)))
            }
        }
        let marks = edges.filter { $0 >= .zero && $0 <= duration }.sorted()
        return zip(marks, marks.dropFirst()).compactMap { a, b in
            guard b > a else { return nil }
            let picture = video.filter { $0.interval.contains(a) }.sorted(by: Self.backToFront)
            let ids = Set(picture.map(\.id))
            return CompiledTimelineInterval(interval: EditInterval(a, b), video: picture.map(\.id),
                audio: audio.filter { $0.interval.contains(a) }.map(\.id),
                placementID: placements.first { $0.participants == ids }?.id,
                transitionIDs: transitions.filter { relation in
                    let members = Set([relation.outgoing, relation.incoming].compactMap { $0 })
                    let edge = relation.outgoing == nil ? -1 : relation.incoming == nil ? 1 : 0
                    let timing = TransitionTiming(relation.settings, factor: relation.factor, edge: edge)
                    return !members.isEmpty && a >= relation.origin + EditTime(timing.lower) && a < relation.origin + EditTime(timing.upper)
                }.map(\.id))
        }
    }
}

extension TrackTimeline {
    /// Split identities once in the draft; dragging or changing inspector values
    /// must reuse that draft instead of regenerating fragments every frame.
    @discardableResult
    mutating func split(at time: EditTime, selection: TimelineSelection) -> [UUID: UUID] {
        let selection = expanded(selection)
        var children: [UUID: UUID] = [:]
        var pictures: [VideoTimelineItem] = []
        for item in video {
            guard selection.video.contains(item.id), time > item.start, time < item.end else { pictures.append(item); continue }
            let local = time - item.start
            guard local.ticks >= 1, (item.end - time).ticks >= 1 else { pictures.append(item); continue }
            var left = item, right = item
            right.content.id = UUID(); right.start = time; right.localOrigin = item.localOrigin + local
            if let frozen = item.content.frozenFrame {
                left.content.frozenFrame?.duration = local.seconds
                right.content.frozenFrame?.duration = (item.end - time).seconds
                right.content.frozenFrame?.offset = frozen.offset + local.seconds
            } else {
                guard let source = item.mapping.source(at: local) else { pictures.append(item); continue }
                left.content.end = source; right.content.start = source
            }
            left.mapping = item.mapping.sliced(EditInterval(.zero, local))
            right.mapping = item.mapping.sliced(EditInterval(local, item.mapping.duration))
            children[item.id] = right.id
            pictures += [left, right]
        }
        video = pictures
        var sounds: [AudioTimelineItem] = []
        for item in audio {
            guard selection.audio.contains(item.id), time > item.start, time < item.end else { sounds.append(item); continue }
            let local = time - item.start, newID = UUID()
            sounds.append(item.sliced(EditInterval(.zero, local), id: item.id))
            sounds.append(item.sliced(EditInterval(local, item.mapping.duration), id: newID))
            children[item.id] = newID
        }
        audio = sounds
        for i in audio.indices {
            if let parent = audio[i].followsVideo, let child = children[parent], audio[i].start >= time { audio[i].followsVideo = child }
        }
        var newLinks: [TimelineLink] = []
        for group in links {
            // Splitting a different lane must not dissolve a horizontal join.
            guard !group.members.isDisjoint(with: selection.ids) else { newLinks.append(group); continue }
            var left = Set<UUID>(), right = Set<UUID>()
            for id in group.members {
                if let child = children[id] { left.insert(id); right.insert(child) }
                else {
                    let start = video.first(where: { $0.id == id })?.start ?? audio.first(where: { $0.id == id })?.start ?? .zero
                    if start >= time { right.insert(id) } else { left.insert(id) }
                }
            }
            if left.count >= 2 { newLinks.append(TimelineLink(id: group.id, members: left)) }
            if right.count >= 2 { newLinks.append(TimelineLink(id: left.isEmpty ? group.id : UUID(), members: right)) }
        }
        links = newLinks
        for i in transitions.indices {
            if let id = transitions[i].outgoing, let right = children[id] { transitions[i].outgoing = right }
        }
        // Every child starts at the same cut. A placement can survive on
        // either side, but a mix of left and right children never overlaps.
        let rightPlacements = placements.compactMap { region -> VideoPlacementRegion? in
            let divided = region.participants.filter { children[$0] != nil }
            guard !divided.isEmpty else { return nil }
            var copy = region
            copy.id = UUID()
            for id in divided {
                guard let right = children[id] else { continue }
                copy.participants.remove(id); copy.participants.insert(right)
                copy.videos[right] = copy.videos.removeValue(forKey: id)
            }
            return copy
        }
        placements += rightPlacements
        pruneRelations()
        return children
    }
    func scoped(_ selection: TimelineSelection) -> (timeline: Self, selection: TimelineSelection) {
        let selection = expanded(selection)
        guard let range = selection.range else { return (self, selection) }
        var result = self, targets = selection
        let upper = result.split(at: range.end, selection: targets)
        targets.video.formUnion(upper.filter { targets.video.contains($0.key) }.map(\.value))
        targets.audio.formUnion(upper.filter { targets.audio.contains($0.key) }.map(\.value))
        let lower = result.split(at: range.start, selection: targets)
        targets.video.formUnion(lower.filter { targets.video.contains($0.key) }.map(\.value))
        targets.audio.formUnion(lower.filter { targets.audio.contains($0.key) }.map(\.value))
        targets.video = Set(result.video.filter { targets.video.contains($0.id) && $0.start >= range.start && $0.end <= range.end }.map(\.id))
        targets.audio = Set(result.audio.filter { targets.audio.contains($0.id) && $0.start >= range.start && $0.end <= range.end }.map(\.id))
        targets.range = nil
        return (result, targets)
    }
    /// Keep a marked scope attached to the same source occurrences when a tool
    /// splits its items. A second use of the same source is not a descendant.
    func remapping(_ selection: TimelineSelection, from previous: Self) -> TimelineSelection {
        func scoped(_ map: SourcePlaybackMap, at start: EditTime) -> SourcePlaybackMap {
            guard let range = selection.range else { return map }
            return map.sliced(EditInterval(range.start - start, range.end - start))
        }
        var ranges: [EditInterval] = []
        func scopeOrigin(_ origin: EditTime, start: EditTime, duration: EditTime) -> EditTime {
            origin + (selection.range.map { min(duration, max(.zero, $0.start - start)) } ?? .zero)
        }
        func match(_ old: SourcePlaybackMap, _ new: SourcePlaybackMap, oldOrigin: EditTime, newOrigin: EditTime, at start: EditTime) -> Bool {
            var found = false, local = EditTime.zero
            for run in new.runs {
                defer { local = local + run.duration }
                var sourceLocal = oldOrigin
                for source in old.runs {
                    defer { sourceLocal = sourceLocal + source.duration }
                    if run.isHold || source.isHold {
                        if run.isHold && source.isHold && run.sourceStart == source.sourceStart,
                           let part = EditInterval(sourceLocal, sourceLocal + source.duration).intersection(EditInterval(newOrigin + local, newOrigin + local + run.duration)) {
                            ranges.append(EditInterval(start + part.start - newOrigin, start + part.end - newOrigin)); found = true
                        }
                        continue
                    }
                    let a = max(source.sourceStart, run.sourceStart), b = min(source.sourceEnd, run.sourceEnd)
                    guard b > a + 0.0000001 else { continue }
                    let scale = run.duration.seconds / (run.sourceEnd - run.sourceStart)
                    ranges.append(EditInterval(start + local + EditTime((a - run.sourceStart) * scale), start + local + EditTime((b - run.sourceStart) * scale)))
                    found = true
                }
            }
            return found
        }
        let pictures = previous.video.filter { selection.video.contains($0.id) }
        let sounds = previous.audio.filter { selection.audio.contains($0.id) }
        let pictureIDs = Set(video.filter { item in pictures.contains {
            $0.occurrenceID == item.occurrenceID && $0.content.sourceID == item.content.sourceID && match(scoped($0.mapping, at: $0.start), item.mapping,
                oldOrigin: scopeOrigin($0.localOrigin, start: $0.start, duration: $0.mapping.duration), newOrigin: item.localOrigin, at: item.start)
        } }.map(\.id))
        let soundIDs = Set(audio.filter { item in sounds.contains {
            $0.occurrenceID == item.occurrenceID && $0.sourceID == item.sourceID && match(scoped($0.mapping, at: $0.start), item.mapping,
                oldOrigin: scopeOrigin($0.localOrigin, start: $0.start, duration: $0.mapping.duration), newOrigin: item.localOrigin, at: item.start)
        } }.map(\.id))
        let range = selection.range.flatMap { _ -> EditInterval? in
            guard let start = ranges.map(\.start).min(), let end = ranges.map(\.end).max() else { return nil }
            return EditInterval(start, end)
        }
        return TimelineSelection(video: pictureIDs, audio: soundIDs, range: range)
    }
    mutating func insertTime(_ duration: EditTime, at time: EditTime, atPictureGap: Bool = false) {
        guard duration > .zero else { return }
        // A soundtrack running under a picture gap continues through the edit.
        // Linked sound follows the pictures being moved, including split edits.
        let splitScope = atPictureGap ? TimelineSelection(video: Set(video.filter { $0.start >= time }.map(\.id))) : entireSelection()
        split(at: time, selection: splitScope)
        for i in video.indices where video[i].start >= time { video[i].start = video[i].start + duration }
        for i in audio.indices where audio[i].start >= time { audio[i].start = audio[i].start + duration }
        for i in bookmarks.indices {
            if case .project(let position) = bookmarks[i].anchor, position >= time { bookmarks[i].anchor = .project(position + duration) }
        }
        for i in transitions.indices where transitions[i].origin >= time { transitions[i].origin = transitions[i].origin + duration }
        for i in generated.indices where generated[i].interval.start >= time {
            generated[i].interval = EditInterval(generated[i].interval.start + duration, generated[i].interval.end + duration)
        }
        pruneRelations()
    }
    mutating func addBookmark(at time: EditTime, preferredVideo: UUID? = nil, label: String = "") {
        let active = video.filter { $0.interval.contains(time) }
        let audioSelected = audio.contains { $0.id == preferredVideo }
        let item = audioSelected ? nil : active.first { $0.id == preferredVideo } ?? active.max { $0.layer < $1.layer }
        let anchor: BookmarkAnchor
        if let item, let source = item.mapping.source(at: time - item.start) {
            anchor = item.content.frozenFrame == nil ? .source(occurrence: item.occurrenceID, source: item.content.sourceID, time: source)
                : .local(occurrence: item.occurrenceID, offset: item.localOrigin + time - item.start)
        } else if let sound = audio.first(where: { $0.id == preferredVideo && $0.interval.contains(time) }) ?? audio.first(where: { $0.interval.contains(time) }), let source = sound.mapping.source(at: time - sound.start) {
            anchor = .source(occurrence: sound.occurrenceID, source: sound.sourceID, time: source)
        } else { anchor = .project(time) }
        bookmarks.append(TimelineBookmark(label: label, anchor: anchor))
    }
    func validate(sources: [SourceMedia]) throws {
        let ids = video.map(\.id) + audio.map(\.id)
        guard Set(ids).count == ids.count, duration >= .zero, duration.seconds <= 604800 else { throw ProjectError.invalidDocument }
        let sourceDurations = Dictionary(sources.map { ($0.id, $0.duration) }, uniquingKeysWith: { a, _ in a })
        func valid(_ map: SourcePlaybackMap, sourceID: UUID) -> Bool {
            guard let duration = sourceDurations[sourceID], !map.runs.isEmpty else { return false }
            return map.runs.allSatisfy { $0.duration > .zero && $0.sourceStart.isFinite && $0.sourceEnd.isFinite && $0.sourceStart >= 0 && $0.sourceEnd >= $0.sourceStart && $0.sourceEnd <= duration + 0.001 }
        }
        guard video.allSatisfy({ $0.start >= .zero && valid($0.mapping, sourceID: $0.content.sourceID) }),
              audio.allSatisfy({ $0.start >= .zero && valid($0.mapping, sourceID: $0.sourceID) && $0.volumeDB.isFinite && (-60...12).contains($0.volumeDB) && $0.fadeIn?.valid != false && $0.fadeOut?.valid != false }) else { throw ProjectError.invalidDocument }
        var linked = Set<UUID>()
        for link in links {
            guard link.members.count >= 2, link.members.isSubset(of: Set(ids)), linked.isDisjoint(with: link.members) else { throw ProjectError.invalidDocument }
            linked.formUnion(link.members)
        }
        guard subtitles?.valid ?? true else { throw ProjectError.invalidDocument }
        for item in audio {
            let words = item.subtitleWords ?? []
            guard words.count <= 200_000, Set(words.map(\.id)).count == words.count,
                  words.allSatisfy({ !$0.text.isEmpty && $0.text.count <= 4000 && $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start && $0.end <= (sourceDurations[item.sourceID] ?? 0) + 0.001 }) else { throw ProjectError.invalidDocument }
        }
        let pictures = Set(video.map(\.id))
        guard Set(links.map(\.id)).count == links.count, Set(bookmarks.map(\.id)).count == bookmarks.count,
              Set(placements.map(\.id)).count == placements.count, Set(transitions.map(\.id)).count == transitions.count else { throw ProjectError.invalidDocument }
        for placement in placements {
            guard placement.participants.count > 1, placement.participants.isSubset(of: pictures),
                  Set(placement.videos.keys) == placement.participants else { throw ProjectError.invalidDocument }
            for value in placement.videos.values {
                func validGeometry(_ value:VideoPlacement) -> Bool {
                    [value.x, value.y, value.width, value.height, value.framing.x, value.framing.y, value.framing.zoom].allSatisfy(\.isFinite) &&
                      (-2...3).contains(value.x) && (-2...3).contains(value.y) && (0.01...3).contains(value.width) && (0.01...3).contains(value.height) &&
                      (0...1).contains(value.framing.x) && (0...1).contains(value.framing.y) && (1...8).contains(value.framing.zoom) &&
                      (value.edgeCrop?.valid ?? true)
                }
                guard validGeometry(value),value.motion?.valid(for:value.pose,accepts:{ validGeometry(value.applying($0)) }) ?? true else { throw ProjectError.invalidDocument }
            }
        }
        let incoming = transitions.compactMap(\.incoming), outgoing = transitions.compactMap(\.outgoing)
        guard Set(incoming).count == incoming.count, Set(outgoing).count == outgoing.count else { throw ProjectError.invalidDocument }
        for relation in transitions {
            let participants = Set([relation.outgoing, relation.incoming].compactMap { $0 })
            guard !participants.isEmpty, participants.isSubset(of: pictures), relation.settings.valid,
                  relation.factor.isFinite, (0...1).contains(relation.factor) else { throw ProjectError.invalidDocument }
        }
        for bookmark in bookmarks {
            guard bookmark.label.count <= 500 else { throw ProjectError.invalidDocument }
            switch bookmark.anchor {
            case .source(_, let source, let time): guard let duration = sourceDurations[source], time.isFinite, time >= 0, time <= duration + 0.001 else { throw ProjectError.invalidDocument }
            case .local(_, let time), .project(let time): guard time >= .zero, time.seconds <= 604800 else { throw ProjectError.invalidDocument }
            }
        }
        for item in audio {
            if let videoID = item.followsVideo {
                guard let picture = video.first(where: { $0.id == videoID }),
                      links.contains(where: { $0.members.contains(videoID) && $0.members.contains(item.id) }),
                      picture.start == item.start, picture.mapping.duration == item.mapping.duration else { throw ProjectError.invalidDocument }
            }
            let regions = item.enhancements.sorted { $0.interval.start < $1.interval.start }
            var censorEnd = EditTime.zero
            for region in item.censors.sorted(by: { $0.interval.start < $1.interval.start }) {
                guard region.interval.start >= censorEnd, region.interval.end <= item.mapping.duration,
                      !region.interval.isEmpty, region.settings.valid, abs(region.phaseOrigin.seconds) <= 604800,
                      region.envelopeInterval.map({ !$0.isEmpty && $0.start <= region.interval.start && $0.end >= region.interval.end && abs($0.start.seconds) <= 604800 && abs($0.end.seconds) <= 604800 }) ?? true else { throw ProjectError.invalidDocument }
                censorEnd = region.interval.end
            }
            var end = EditTime.zero
            for region in regions {
                guard region.interval.start >= end, region.interval.end <= item.mapping.duration, !region.interval.isEmpty,
                      Set(region.effects.map(\.id)).count == region.effects.count,
                      region.effects.allSatisfy({ $0.implementationVersion > 0 && $0.amount.isFinite && $0.frequency.isFinite && (20...20000).contains($0.frequency) && (!$0.supported || ($0.kind.isNeural ? (0...1) : (-24...24)).contains($0.amount)) }) else { throw ProjectError.invalidDocument }
                end = region.interval.end
            }
        }
    }
}

extension TrackTimeline {
    /// Stable time order for sequence-facing controls. Layer order remains
    /// independent: moving a picture must not change which overlap is in front.
    var chronologicalVideo: [VideoTimelineItem] {
        video.enumerated().sorted { a, b in
            a.element.start == b.element.start ? a.offset < b.offset : a.element.start < b.element.start
        }.map(\.element)
    }
    var projectedClips: [TimelineClip] {
        chronologicalVideo.map { item in
            var clip = item.content
            clip.openingTransition = transitions.first { $0.incoming == item.id && $0.outgoing == nil }?.settings
            clip.transition = transitions.first { $0.outgoing == item.id }?.settings
            clip.transition?.nextClipID = transitions.first { $0.outgoing == item.id }?.incoming
            return clip
        }
    }
    mutating func restoreSourceMute() {
        for i in video.indices { video[i].mapping = video[i].mapping.applyingMute(from: video[i].content) }
        for i in audio.indices {
            guard let id = audio[i].followsVideo, let picture = video.first(where: { $0.id == id }) else { continue }
            audio[i].mapping = audio[i].mapping.applyingMute(from: picture.content)
        }
    }
    mutating func synchronizeFollowers() {
        restoreSourceMute()
        for i in audio.indices {
            guard let id = audio[i].followsVideo, let item = video.first(where: { $0.id == id }) else { continue }
            let priorMap = audio[i].mapping
            audio[i].start = item.start; audio[i].mapping = item.mapping
            if priorMap != item.mapping {
                audio[i].fadeIn = audio[i].fadeIn?.fitted(from: priorMap.duration, to: item.mapping.duration)
                audio[i].fadeOut = audio[i].fadeOut?.fitted(from: priorMap.duration, to: item.mapping.duration)
                var rebased: [AudioEnhancementRegion] = []
                for region in audio[i].enhancements {
                    let sourceRuns = priorMap.sliced(region.interval).runs
                    var cursor = EditTime.zero
                    for run in item.mapping.runs {
                        defer { cursor = cursor + run.duration }
                        for old in sourceRuns where !old.isHold && !run.isHold {
                            let a = max(old.sourceStart, run.sourceStart), b = min(old.sourceEnd, run.sourceEnd)
                            guard b > a else { continue }
                            let duration = run.sourceEnd - run.sourceStart
                            var copy = region
                            copy.interval = EditInterval(cursor + EditTime(run.duration.seconds * (a - run.sourceStart) / duration), cursor + EditTime(run.duration.seconds * (b - run.sourceStart) / duration))
                            if !copy.interval.isEmpty { rebased.append(copy) }
                        }
                    }
                }
                var merged: [AudioEnhancementRegion] = []
                for region in rebased.sorted(by: { $0.interval.start < $1.interval.start }) {
                    if let last = merged.last, last.id == region.id, last.effects == region.effects, last.interval.end == region.interval.start {
                        merged[merged.count - 1].interval.end = region.interval.end
                    } else { merged.append(region) }
                }
                var seen = Set<UUID>()
                for j in merged.indices {
                    if !seen.insert(merged[j].id).inserted { merged[j].id = UUID(); seen.insert(merged[j].id) }
                }
                audio[i].enhancements = merged
                var censors: [AudioCensorRegion] = []
                for region in audio[i].censors {
                    let oldRuns = priorMap.sliced(region.interval).runs
                    var cursor = EditTime.zero
                    for run in item.mapping.runs {
                        defer { cursor = cursor + run.duration }
                        for old in oldRuns where !old.isHold && !run.isHold {
                            let a = max(old.sourceStart, run.sourceStart), b = min(old.sourceEnd, run.sourceEnd)
                            guard b > a else { continue }
                            var copy = region
                            copy.interval = EditInterval(cursor + EditTime(run.duration.seconds * (a - run.sourceStart) / (run.sourceEnd - run.sourceStart)), cursor + EditTime(run.duration.seconds * (b - run.sourceStart) / (run.sourceEnd - run.sourceStart)))
                            copy.phaseOrigin = copy.interval.start; copy.envelopeInterval = nil
                            if !copy.interval.isEmpty { censors.append(copy) }
                        }
                    }
                }
                var mergedCensors: [AudioCensorRegion] = []
                for region in censors.sorted(by: { $0.interval.start < $1.interval.start }) {
                    if let last = mergedCensors.last, last.id == region.id, last.settings == region.settings, last.interval.end == region.interval.start {
                        mergedCensors[mergedCensors.count - 1].interval.end = region.interval.end
                    } else { mergedCensors.append(region) }
                }
                audio[i].censors = mergedCensors
            }
        }
    }
    /// Compatibility at the *tool API*, not a second saved timeline. Existing
    /// color/crop/effect inspectors edit video payloads; positions remain explicit.
    mutating func replaceVideoContents(_ clips: [TimelineClip]) {
        let previous = projectedClips
        guard clips != previous else { return }
        let previousItems = video
        var retimed = Set<UUID>()
        let oldIDs = Set(video.map(\.id)), newIDs = Set(clips.map(\.id))
        let removed = oldIDs.subtracting(newIDs)
        if !removed.isEmpty {
            var targets = TimelineSelection()
            for id in removed { let group = selection(of: id); targets.video.formUnion(group.video); targets.audio.formUnion(group.audio) }
            remove(targets)
        }
        for content in clips {
            guard let index = video.firstIndex(where: { $0.id == content.id }) else { continue }
            let before = video[index]
            var clean = content; clean.openingTransition = nil; clean.transition = nil
            let derived = SourcePlaybackMap(clean)
            let timingChanged = derived != SourcePlaybackMap(before.content)
            let difference = timingChanged ? derived.duration - before.mapping.duration : .zero
            video[index].content = clean
            if timingChanged { video[index].mapping = derived }
            if difference != .zero { retimed.insert(content.id) }
            if difference != .zero, let group = links.first(where: { $0.members.contains(content.id) }) {
                let originalIncoming = transitions.first { $0.incoming == content.id }
                let originalOutgoing = transitions.first { $0.outgoing == content.id }
                var incoming = originalIncoming, outgoing = originalOutgoing
                func timing(_ relation: TimelineTransition?, scale: Double = 1) -> TransitionTiming {
                    guard let relation else { return TransitionTiming(nil) }
                    return TransitionTiming(relation.settings, factor: relation.factor * scale, edge: relation.outgoing == nil ? -1 : relation.incoming == nil ? 1 : 0)
                }
                func cost(_ scale: Double) -> Double { timing(incoming, scale: scale).rightCost + timing(outgoing, scale: scale).leftCost }
                if cost(1) > derived.duration.seconds {
                    if clean.start != before.content.start || clean.end != before.content.end {
                        // Trimming away the footage required by a transition
                        // removes that relation, as an ordinary trim promises.
                        let removed = Set([incoming?.id, outgoing?.id].compactMap { $0 })
                        transitions.removeAll { removed.contains($0.id) }; incoming = nil; outgoing = nil
                    } else {
                        // Speed changes preserve the source footage. Fit both
                        // handles together before moving the next picture.
                        var lo = 0.0, hi = 1.0
                        for _ in 0..<48 { let mid = (lo + hi) / 2; if cost(mid) <= derived.duration.seconds { lo = mid } else { hi = mid } }
                        incoming?.factor *= lo; outgoing?.factor *= lo
                        for updated in [incoming, outgoing].compactMap({ $0 }) {
                            if let i = transitions.firstIndex(where: { $0.id == updated.id }) { transitions[i] = updated }
                        }
                    }
                }
                if let originalIncoming {
                    let t = timing(incoming)
                    if let previous = video.first(where: { $0.id == originalIncoming.outgoing }) {
                        video[index].start = previous.end - EditTime(t.leftEnd) + EditTime(t.rightStart)
                    } else { video[index].start = incoming.map { max(.zero, $0.origin + EditTime(t.rightStart)) } ?? .zero }
                }
                var delta = video[index].end - before.end
                if let originalOutgoing, let next = video.first(where: { $0.id == originalOutgoing.incoming }) {
                    let t = timing(outgoing)
                    delta = video[index].end - EditTime(t.leftEnd) + EditTime(t.rightStart) - next.start
                }
                let soundIDs = Set(audio.map(\.id)), pictureIDs = Set(video.map(\.id))
                let avGroups = links.filter { !$0.members.isDisjoint(with: soundIDs) && !$0.members.isDisjoint(with: pictureIDs) }
                let downstream = group.members.isDisjoint(with: soundIDs) ? group.members : Set(avGroups.flatMap(\.members))
                // A concurrent overlay is not downstream of the edited picture.
                // Explicit transition handles are the exception: their incoming
                // picture must follow the retimed outgoing end.
                let nextPicture = originalOutgoing?.incoming
                let isOverlay = previousItems.contains { $0.id != content.id && $0.id != originalIncoming?.outgoing && $0.layer < before.layer && $0.interval.contains(before.start) }
                var transitionChain = Set<UUID>()
                var next = nextPicture
                while let id = next, transitionChain.insert(id).inserted { next = transitions.first { $0.outgoing == id }?.incoming }
                let moving = Set(video.filter { $0.id != content.id && downstream.contains($0.id) && (isOverlay ? transitionChain.contains($0.id) : ($0.start >= before.end || $0.id == nextPicture)) }.map(\.id))
                for i in video.indices where moving.contains(video[i].id) { video[i].start = video[i].start + delta }
                for i in audio.indices where downstream.contains(audio[i].id) && audio[i].followsVideo != content.id && (audio[i].followsVideo.map(moving.contains) ?? (!isOverlay && audio[i].start >= before.end)) { audio[i].start = audio[i].start + delta }
                for i in transitions.indices where (!isOverlay && transitions[i].origin >= before.end) || transitions[i].outgoing == content.id || transitions[i].incoming.map(moving.contains) == true { transitions[i].origin = transitions[i].origin + delta }
                for i in generated.indices where (!isOverlay && generated[i].interval.start >= before.end) || transitions.contains(where: { $0.id == generated[i].owner && ($0.outgoing == content.id || $0.incoming.map(moving.contains) == true) }) {
                    generated[i].interval = EditInterval(generated[i].interval.start + delta, generated[i].interval.end + delta)
                }
            }
        }
        for (index, clip) in clips.enumerated() where !oldIDs.contains(clip.id) {
            let position = index > 0 ? video.first(where: { $0.id == clips[index - 1].id })?.end ?? duration : .zero
            insertTime(EditTime(clip.duration), at: position)
            var added = TrackTimeline(clips: [clip])
            for i in added.video.indices { added.video[i].start = added.video[i].start + position; added.video[i].layer = (video.map(\.layer).max() ?? -1) + 1 }
            for i in added.audio.indices { added.audio[i].start = added.audio[i].start + position }
            video += added.video; audio += added.audio; links += added.links
        }
        let ordering = Dictionary(clips.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
        video.sort { (ordering[$0.id] ?? Int.max) < (ordering[$1.id] ?? Int.max) }
        // Inspector removals are explicit. Merely rearranging an array is never
        // allowed to transfer a transition onto a different neighbor.
        for clip in clips {
            guard let old = previous.first(where: { $0.id == clip.id }) else { continue }
            if old.openingTransition != nil && clip.openingTransition == nil { transitions.removeAll { $0.incoming == clip.id && $0.outgoing == nil } }
            if old.transition != nil && clip.transition == nil { transitions.removeAll { $0.outgoing == clip.id } }
        }
        promoteNewOverlaps(retimed, previous: previousItems)
        synchronizeFollowers(); retainPlacementAcrossNewOverlaps(moving: retimed); pruneRelations()
    }
}

/// One viewport calculation for pinch, fit, presets and hit testing. At fit,
/// both ends are visible and the playhead moves independently of the viewport.
struct TimelineViewport {
    // At whole-project fit, each edge has room for its own 44-point add target.
    static let edgeInset = 48.0
    let width: Double
    let duration: Double
    let requestedScale: Double
    var minimumScale: Double { max(0.000001, (width - 2 * Self.edgeInset) / max(1, duration)) }
    var scale: Double { max(minimumScale, min(720, requestedScale)) }
    var fits: Bool { duration * scale <= width - 2 * Self.edgeInset + 0.5 }
    var inset: Double { fits ? Self.edgeInset : width / 2 }
    var contentWidth: Double { max(width, duration * scale + 2 * inset) }
    func x(_ time: Double, offset: Double) -> Double { time * scale + inset - offset }
    func time(_ x: Double, offset: Double) -> Double { min(duration, max(0, (x + offset - inset) / scale)) }
}

struct TimelineClipboard {
    var timeline: TrackTimeline
    var insertsTime: Bool
    var isEmpty: Bool { timeline.video.isEmpty && timeline.audio.isEmpty }
}
extension TrackTimeline {
    mutating func includeCaptureBookmarks(_ source: SourceMedia) {
        guard let item = video.first(where: { $0.content.sourceID == source.id && $0.content.frozenFrame == nil }) else { return }
        for event in source.events ?? [] where event.kind == "bookmark" && event.time >= 0 && event.time < source.duration {
            guard !bookmarks.contains(where: { $0.id == event.id }) else { continue }
            bookmarks.append(TimelineBookmark(id: event.id, anchor: .source(occurrence: item.occurrenceID, source: source.id, time: event.time)))
        }
    }
    private func snapPoints(excluding: Set<UUID>, extra: [Double]) -> [EditTime] {
        let stationaryMarks = resolvedBookmarks.filter { resolved in
            let owner: UUID?
            switch resolved.bookmark.anchor {
            case .project: owner = nil
            case .source(let occurrence, let source, let point):
                owner = video.first { $0.occurrenceID == occurrence && $0.content.sourceID == source && $0.mapping.local(forSource: point) != nil }?.id
                    ?? audio.first { $0.occurrenceID == occurrence && $0.sourceID == source && $0.mapping.local(forSource: point) != nil }?.id
            case .local(let occurrence, let offset):
                owner = video.first { $0.occurrenceID == occurrence && offset >= $0.localOrigin && offset < $0.localOrigin + $0.mapping.duration }?.id
            }
            return owner.map { !excluding.contains($0) } ?? true
        }
        let edges = video.filter { !excluding.contains($0.id) }.flatMap { [$0.start.seconds, $0.end.seconds] }
            + audio.filter { !excluding.contains($0.id) }.flatMap { [$0.start.seconds, $0.end.seconds] }
            + stationaryMarks.map { $0.time.seconds } + extra + [0]
        return Set(edges.map(EditTime.init)).sorted()
    }
    func snapTarget(_ time: Double, scale: Double, excluding: Set<UUID> = [], extra: [Double] = []) -> Double? {
        guard let target = snapPoints(excluding: excluding, extra: extra).min(by: { abs($0.seconds - time) < abs($1.seconds - time) }), abs(target.seconds - time) * scale <= 8 else { return nil }
        return target.seconds
    }
    func snappedMove(_ selection: TimelineSelection, by requested: EditTime, scale: Double,
                     latch: TimelineMoveSnap? = nil, extra: [Double] = []) -> TimelineMoveResult {
        let selected = expanded(selection)
        let intervals = video.filter { selected.video.contains($0.id) }.map(\.interval)
            + audio.filter { selected.audio.contains($0.id) }.map(\.interval)
        guard let start = intervals.map(\.start).min() else { return TimelineMoveResult(delta: .zero) }
        let minimum = EditTime.zero - start, delta = max(minimum, requested)
        let edges = Set(intervals.flatMap { [$0.start, $0.end] }).sorted()
        let targets = snapPoints(excluding: selected.ids, extra: extra)
        let scale = max(0.000001, scale)
        var best: TimelineMoveSnap?, distance = Double.infinity
        for edge in edges {
            let position = edge + delta
            var lower = 0, upper = targets.count
            while lower < upper {
                let mid = (lower + upper) / 2
                if targets[mid] < position { lower = mid + 1 } else { upper = mid }
            }
            for index in [lower - 1, lower] where targets.indices.contains(index) {
                let target = targets[index]
                guard target - edge >= minimum else { continue }
                let gap = abs((edge + delta - target).seconds) * scale
                if gap <= 10 && gap < distance { best = TimelineMoveSnap(target: target, edge: edge); distance = gap }
            }
        }
        if let latch, edges.contains(latch.edge), targets.contains(latch.target), latch.target - latch.edge >= minimum {
            let heldDistance = abs((latch.edge + delta - latch.target).seconds) * scale
            // Hysteresis must not pull past another cut under the finger.
            if heldDistance <= 18 && (best == nil || heldDistance <= distance + 1) {
                return TimelineMoveResult(delta: latch.target - latch.edge, snap: latch)
            }
        }
        return TimelineMoveResult(delta: best.map { $0.target - $0.edge } ?? delta, snap: best)
    }
    func snap(_ time: Double, scale: Double, excluding: Set<UUID> = [], extra: [Double] = []) -> Double {
        snapTarget(time, scale: scale, excluding: excluding, extra: extra) ?? time
    }
    func copied(_ targets: TimelineSelection) -> TimelineClipboard {
        let scoped = scoped(targets)
        return scoped.timeline.clipboardFragment(scoped.selection, keepGaps: targets.range != nil)
    }
    @discardableResult
    mutating func paste(_ clipboard: TimelineClipboard, at point: EditTime, target: TimelinePasteTarget? = nil) -> TimelineSelection {
        var addition = clipboard.timeline
        guard !clipboard.isEmpty else { return TimelineSelection() }
        var identifiers: [UUID: UUID] = [:]
        func fresh(_ old: UUID) -> UUID { if let value = identifiers[old] { return value }; let value = UUID(); identifiers[old] = value; return value }
        let position = preparePaste(clipboard, at: point, target: target)
        let front = (video.map(\.layer).max() ?? 0) + 1
        let layers = Set(addition.video.map(\.layer)).sorted()
        let newLayers = Dictionary(uniqueKeysWithValues: layers.enumerated().map { ($0.element, front + $0.offset) })
        for i in addition.video.indices {
            var item = addition.video[i]
            item.content.id = fresh(item.id); item.occurrenceID = fresh(item.occurrenceID)
            item.start = item.start + position; item.layer = newLayers[item.layer]!
            if let v = item.content.speed { item.content.speed?.id = fresh(v.id) }
            if let v = item.content.crop { item.content.crop?.id = fresh(v.id) }
            if let v = item.content.color { item.content.color?.id = fresh(v.id) }
            if let v = item.content.mirror { item.content.mirror?.id = fresh(v.id) }
            if let v = item.content.pauses { item.content.pauses?.id = fresh(v.id) }
            if let id = item.content.stabilization?.id { item.content.stabilization?.id = fresh(id) }
            item.content.texts = item.content.texts?.map { var v = $0; v.id = fresh(v.id); return v }
            item.content.images = item.content.images?.map { var v = $0; v.id = fresh(v.id); return v }
            item.content.videoEffects = item.content.videoEffects?.map { var v = $0; if v.analysisFile != nil { v.capturedEffectID = v.analysisID }; v.id = fresh(v.id); return v }
            addition.video[i] = item
        }
        for i in addition.audio.indices {
            addition.audio[i].id = fresh(addition.audio[i].id)
            addition.audio[i].occurrenceID = fresh(addition.audio[i].occurrenceID)
            addition.audio[i].followsVideo = addition.audio[i].followsVideo.map(fresh)
            addition.audio[i].start = addition.audio[i].start + position
            addition.audio[i].subtitleWords = addition.audio[i].subtitleWords?.map { var word = $0; word.id = fresh(word.id); word.phraseID = fresh(word.phraseID); return word }
            for r in addition.audio[i].enhancements.indices { addition.audio[i].enhancements[r].id = fresh(addition.audio[i].enhancements[r].id) }
            addition.audio[i].censors = addition.audio[i].censors.map { var region = $0; region.id = fresh(region.id); return region }
        }
        addition.links = addition.links.map { TimelineLink(members: Set($0.members.map(fresh))) }
        addition.transitions = addition.transitions.map { var v = $0; v.settings.id = fresh(v.id); v.outgoing = v.outgoing.map(fresh); v.incoming = v.incoming.map(fresh); v.origin = v.origin + position; return v }
        addition.placements = addition.placements.map { VideoPlacementRegion(participants: Set($0.participants.map(fresh)), videos: Dictionary(uniqueKeysWithValues: $0.videos.map { (fresh($0.key), $0.value) })) }
        addition.bookmarks = addition.bookmarks.map { mark in
            var copy = mark; copy.id = UUID()
            switch mark.anchor {
            case .source(let occurrence, let source, let time): copy.anchor = .source(occurrence: fresh(occurrence), source: source, time: time)
            case .local(let occurrence, let offset): copy.anchor = .local(occurrence: fresh(occurrence), offset: offset)
            case .project(let time): copy.anchor = .project(time + position)
            }
            return copy
        }
        if subtitles == nil { subtitles = addition.subtitles; subtitles?.timingFingerprint = "" }
        video += addition.video; audio += addition.audio; links += addition.links
        transitions += addition.transitions; placements += addition.placements; bookmarks += addition.bookmarks
        video.sort { $0.start < $1.start }; pruneRelations()
        return addition.entireSelection()
    }
}

extension TrackTimeline {
    func gap(at time: EditTime) -> EditInterval? {
        let occupied = Self.union(video.map(\.interval) + audio.map(\.interval) + generated.map(\.interval))
        guard time >= .zero, time < duration, !occupied.contains(where: { $0.contains(time) }) else { return nil }
        let start = occupied.filter { $0.end <= time }.map(\.end).max() ?? .zero
        let end = occupied.filter { $0.start > time }.map(\.start).min() ?? duration
        return end > start ? EditInterval(start, end) : nil
    }
    mutating func closeGap(at time: EditTime) {
        guard let gap = gap(at: time) else { return }
        for i in video.indices where video[i].start >= gap.end { video[i].start = video[i].start - gap.duration }
        for i in audio.indices where audio[i].start >= gap.end { audio[i].start = audio[i].start - gap.duration }
        for i in transitions.indices where transitions[i].origin >= gap.end { transitions[i].origin = transitions[i].origin - gap.duration }
        for i in bookmarks.indices {
            if case .project(let mark) = bookmarks[i].anchor, mark >= gap.start { bookmarks[i].anchor = .project(max(gap.start, mark - gap.duration)) }
        }
        pruneRelations()
    }
    func syncOffset(audio id: UUID) -> EditTime? {
        guard let sound = audio.first(where: { $0.id == id }), let sourceTime = sound.mapping.runs.first?.sourceStart,
              let picture = video.first(where: { $0.occurrenceID == sound.occurrenceID && $0.mapping.local(forSource: sourceTime) != nil }),
              let local = picture.mapping.local(forSource: sourceTime) else { return nil }
        return sound.start - picture.start - local
    }
    mutating func restoreSync(audio id: UUID) {
        guard let offset = syncOffset(audio: id), let index = audio.firstIndex(where: { $0.id == id }) else { return }
        audio[index].start = max(.zero, audio[index].start - offset)
        pruneRelations()
    }
    /// Reveal previously trimmed original material. Other items keep their
    /// positions: revealing into an occupied interval creates an editable overlap.
    mutating func extend(_ selection: TimelineSelection, left: Bool, by requested: EditTime, sources: [SourceMedia]) {
        let target = expanded(selection)
        var amount = requested
        func available(_ map: SourcePlaybackMap, start: EditTime, source: UUID) -> EditTime {
            guard let run = left ? map.runs.first : map.runs.last, !run.isHold,
                  let duration = sources.first(where: { $0.id == source })?.duration else { return .zero }
            let rate = (run.sourceEnd - run.sourceStart) / run.duration.seconds
            return left ? min(start, EditTime(run.sourceStart / rate)) : EditTime(max(0, duration - run.sourceEnd) / rate)
        }
        func revealMap(_ item: VideoTimelineItem) -> SourcePlaybackMap {
            guard item.content.frozenFrame == nil,
                  let duration = sources.first(where: { $0.id == item.content.sourceID })?.duration else { return SourcePlaybackMap(runs: []) }
            var clip = item.content
            clip.start = left ? 0 : item.mapping.runs.last?.sourceEnd ?? clip.end
            clip.end = left ? item.mapping.runs.first?.sourceStart ?? clip.start : duration
            return clip.end > clip.start ? SourcePlaybackMap(clip) : SourcePlaybackMap(runs: [])
        }
        let revealed = Dictionary(uniqueKeysWithValues: video.filter { target.video.contains($0.id) }.map { ($0.id, revealMap($0)) })
        for item in video where target.video.contains(item.id) { amount = min(amount, left ? min(item.start, revealed[item.id]!.duration) : revealed[item.id]!.duration) }
        for item in audio where target.audio.contains(item.id) && !(item.followsVideo.map(target.video.contains) ?? false) {
            amount = min(amount, available(item.mapping, start: item.start, source: item.sourceID))
        }
        guard amount > .zero else { return }
        let previous = video
        for i in video.indices where target.video.contains(video[i].id) {
            let map = revealed[video[i].id]!
            let part = map.sliced(left ? EditInterval(map.duration - amount, map.duration) : EditInterval(.zero, amount))
            video[i].mapping.runs = left ? part.runs + video[i].mapping.runs : video[i].mapping.runs + part.runs
            if left { video[i].start = video[i].start - amount; video[i].localOrigin = video[i].localOrigin - amount }
            video[i].content.start = video[i].mapping.runs.first!.sourceStart
            video[i].content.end = video[i].mapping.runs.last!.sourceEnd
        }
        for i in audio.indices where target.audio.contains(audio[i].id) {
            if left, let fade = audio[i].fadeIn {
                audio[i].fadeIn?.elapsed = max(0, fade.elapsed - amount.seconds)
            } else if !left, let fade = audio[i].fadeOut {
                audio[i].fadeOut?.elapsed = max(0, fade.elapsed - amount.seconds)
            }
            if !(audio[i].followsVideo.map(target.video.contains) ?? false) {
                let j = left ? 0 : audio[i].mapping.runs.count - 1
                let run = audio[i].mapping.runs[j], change = amount.seconds * (run.sourceEnd - run.sourceStart) / run.duration.seconds
                let added = PlaybackRun(duration: amount, sourceStart: left ? max(0, run.sourceStart - change) : run.sourceEnd,
                    sourceEnd: left ? run.sourceStart : run.sourceEnd + change, silent: false)
                if left { audio[i].mapping.runs.insert(added, at: 0) } else { audio[i].mapping.runs.append(added) }
            }
            if left {
                audio[i].start = audio[i].start - amount; audio[i].localOrigin = audio[i].localOrigin - amount
                if !(audio[i].followsVideo.map(target.video.contains) ?? false) {
                    for j in audio[i].enhancements.indices { audio[i].enhancements[j].interval = EditInterval(audio[i].enhancements[j].interval.start + amount, audio[i].enhancements[j].interval.end + amount) }
                    audio[i].censors = audio[i].censors.map { var region = $0; region.interval = EditInterval(region.interval.start + amount, region.interval.end + amount); region.phaseOrigin = region.phaseOrigin + amount; if let envelope = region.envelopeInterval { region.envelopeInterval = EditInterval(envelope.start + amount, envelope.end + amount) }; return region }
                }
            }
        }
        synchronizeFollowers()
        promoteNewOverlaps(target.video, previous: previous)
        retainPlacementAcrossNewOverlaps(moving: target.video)
        pruneRelations()
    }
}

// Shared by drawing, hit testing, accessibility and edit-invariant tests.
struct TimelineLane {
    let id: UUID
    /// Visible card only. Transition handles remain in contentInterval/mapping.
    let interval: EditInterval
    let contentInterval: EditInterval
    let source: UUID
    let mapping: SourcePlaybackMap
    let row: Int
    let number: Int
    let audio: Bool
    var trimsLeft: Bool { interval.start == contentInterval.start }
    var trimsRight: Bool { interval.end == contentInterval.end }
}
private func displayIntervals(_ timeline: TrackTimeline, folding layout: TimelineLayout?) -> [UUID: EditInterval] {
    var visible = Dictionary(uniqueKeysWithValues: timeline.video.map { ($0.id, $0.interval) } + timeline.audio.map { ($0.id, $0.interval) })
    // A transition is presented as a join, not a second compositing layer.
    // Only fold its real overlap; generated black/freeze gaps keep their time.
    func fold(_ a: UUID, _ b: UUID, at time: EditTime) {
        guard var left = visible[a], var right = visible[b], let overlap = left.intersection(right) else { return }
        let cut = min(overlap.end, max(overlap.start, time))
        guard cut > left.start, cut < right.end else { return }
        left.end = cut; right.start = cut; visible[a] = left; visible[b] = right
    }
    if let layout {
        for join in layout.joins where join.transition != nil && join.edge == 0 {
            guard let a = timeline.video.first(where: { $0.id == join.outgoingID }),
                  let b = timeline.video.first(where: { $0.id == join.incomingID }) else { continue }
            fold(a.id, b.id, at: EditTime(join.time))
            // Detached or independently trimmed sound remains an honest layer.
            func followers(of picture: VideoTimelineItem) -> [AudioTimelineItem] {
                timeline.audio.filter { sound in
                    sound.followsVideo == picture.id && sound.interval == picture.interval
                        && timeline.links.contains { $0.members.contains(picture.id) && $0.members.contains(sound.id) }
                }
            }
            let first = followers(of: a), second = followers(of: b)
            if first.count == 1, second.count == 1 { fold(first[0].id, second[0].id, at: EditTime(join.time)) }
        }
    }
    return visible
}

func timelineLanes(_ timeline: TrackTimeline, moving: TimelineSelection? = nil) -> [TimelineLane] {
    var result: [TimelineLane] = []
    let layout = moving == nil && !timeline.transitions.isEmpty ? TimelineLayout(timeline: timeline) : nil
    let visible = displayIntervals(timeline, folding: layout)
    let videoNumbers = Dictionary(uniqueKeysWithValues: timeline.video.enumerated().map { ($0.element.id, $0.offset + 1) })
    let audioNumbers = Dictionary(uniqueKeysWithValues: timeline.audio.enumerated().map { ($0.element.id, $0.offset + 1) })
    let pictures = timeline.video.sorted { TrackTimeline.backToFront($1, $0) }
    let videoLayers = Dictionary(uniqueKeysWithValues: timeline.video.map { ($0.id, $0.layer) })
    var linkedLayers: [UUID: Int] = [:]
    for group in timeline.links {
        if let layer = group.members.compactMap({ videoLayers[$0] }).max() {
            for id in group.members { linkedLayers[id] = layer }
        }
    }
    let sounds = timeline.audio.sorted { a, b in
        let aLayer = linkedLayers[a.id] ?? -1, bLayer = linkedLayers[b.id] ?? -1
        if aLayer != bLayer { return aLayer > bLayer }
        return a.start == b.start ? a.id.uuidString < b.id.uuidString : a.start < b.start
    }
    let transitionPairs = Set(timeline.transitions.compactMap { relation -> Set<UUID>? in
        guard let a = relation.outgoing, let b = relation.incoming else { return nil }
        return [a, b]
    })
    func pack(_ items: [TimelineLane], base: Int) -> Int {
        var rows: [[EditInterval]] = []
        var placed: [(id: UUID, interval: EditInterval, row: Int)] = []
        for item in items {
            // Ordinary overlays retain their front/back order. Transition
            // partners blend, rather than cover, so reuse alternate rows for a
            // long chain of crossfades instead of growing one row per cut.
            let minimum = item.audio ? 0 : (placed.filter {
                $0.interval.intersection(item.interval) != nil && !transitionPairs.contains([$0.id, item.id])
            }.map(\.row).max() ?? -1) + 1
            let row = rows.indices.first { index in index >= minimum && !rows[index].contains { $0.intersection(item.interval) != nil } } ?? rows.count
            if row == rows.count { rows.append([]) }; rows[row].append(item.interval)
            placed.append((item.id, item.interval, row))
            result.append(TimelineLane(id: item.id, interval: item.interval, contentInterval: item.contentInterval, source: item.source, mapping: item.mapping,
                                       row: base + row, number: item.number, audio: item.audio))
        }
        return rows.count
    }
    let video = pictures.map { TimelineLane(id: $0.id, interval: visible[$0.id]!, contentInterval: $0.interval, source: $0.content.sourceID, mapping: $0.mapping,
                                            row: 0, number: videoNumbers[$0.id]!, audio: false) }
    let audio = sounds.map { TimelineLane(id: $0.id, interval: visible[$0.id]!, contentInterval: $0.interval, source: $0.sourceID, mapping: $0.mapping,
                                        row: 0, number: audioNumbers[$0.id]!, audio: true) }
    var base = 0
    for items in [video, audio] {
        if items.first?.audio == true { base = max(1, base) }
        if let moving {
            // Give the moving group dedicated rows until Done/Cancel. Both the
            // group and stationary cards keep their vertical positions as edges
            // cross. Empty space is intentional, like lifting a clip for placing.
            base += pack(items.filter { moving.ids.contains($0.id) }, base: base)
            base += pack(items.filter { !moving.ids.contains($0.id) }, base: base)
        } else { base += pack(items, base: base) }
    }
    return result
}
