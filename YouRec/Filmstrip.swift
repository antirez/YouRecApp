import Foundation
import CryptoKit

/// The sample clock belongs to the footage. Splitting a clip or moving it on
/// the timeline must not restart the grid for all the pictures after the cut.
struct FilmstripGrid {
    let fps: Double
    let step: Double

    init(tileWidth: Double, pointsPerSecond: Double, fps: Double) {
        self.fps = fps
        let frames = max(1, tileWidth * fps / pointsPerSecond)
        step = exp2(log2(frames).rounded()) / fps
    }

    func slot(at time: Double, origin: Double) -> Double {
        origin + floor((time - origin) / step + 1e-8) * step
    }

    func sample(start: Double, end: Double, center: Bool, duration: Double) -> EditTime {
        let first = ceil(start * fps - 1e-7)
        let last = ceil(end * fps - 1e-7) - 1
        // A sub-frame sliver has no output-frame boundary of its own. Use the
        // frame already on screen during the sliver instead of the next clip.
        let preferred = center ? floor((start + end) * 0.5 * fps) : first
        let frame = min(last, max(first, preferred))
        let finalFrame = ceil(duration * fps - 1e-7) - 1
        return EditTime(max(0, min(finalFrame, frame)) / fps)
    }

    func boundaries(from start: Double, to end: Double, edges: ArraySlice<Double>, pointsPerSecond: Double) -> [Double] {
        let minimum = 12 / pointsPerSecond
        var result = [start]
        for edge in edges where edge - result[result.count - 1] >= minimum && end - edge >= minimum {
            result.append(edge)
        }
        result.append(end)
        return result
    }
}

private func filmstripDigest<T: Encodable>(_ value: T) -> String? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(value) else { return nil }
    return Data(SHA256.hash(data: data)).base64EncodedString()
}

/// Subtitle layout constrains every cue against the largest caption or pair in
/// the transcript. Moving a phrase preserves this envelope; editing it can
/// change the position of captions elsewhere in the movie.
private struct FilmstripCaptions {
    struct Span {
        var start: Double
        var cues: [SubtitleCue]
    }
    private var spans: [Span] = []
    private var style: String?
    private(set) var envelope: String?
    private var animated = false

    init(_ timeline: TrackTimeline) {
        guard var settings = timeline.subtitles else { return }
        let cues = timeline.subtitleCues
        let events = cues.indices.flatMap { [(cues[$0].start, true, $0), (cues[$0].end, false, $0)] }
            .sorted { $0.0 == $1.0 ? (!$0.1 && $1.1) : $0.0 < $1.0 }
        var active = IndexSet(), stacks = Set<[String]>()
        for (time, add, i) in events {
            if add { active.insert(i) } else { active.remove(i) }
            let visible = active.prefix(2).map { cues[$0] }
            stacks.insert(visible.map(\.text))
            if spans.last?.start == time { spans.removeLast() }
            spans.append(Span(start: time, cues: visible))
        }
        animated = settings.motion?.active == true
        settings.timingFingerprint = "" // Governs re-transcription, never pixels.
        style = filmstripDigest(settings)
        envelope = filmstripDigest(stacks.sorted { $0.lexicographicallyPrecedes($1) })
    }

    func suffix(at time: EditTime) -> String? {
        guard let visible = spans.prefixEnd(where: { $0.start <= time.seconds }).last, !visible.cues.isEmpty else { return "" }
        guard let style, envelope != nil else { return nil }
        var key = ":captions:" + style
        for cue in visible.cues {
            key += ":\(cue.text.utf8.count):" + cue.text
            if animated { key += ":\(EditTime(time.seconds - cue.start).ticks):\(EditTime(cue.end - cue.start).ticks)" }
        }
        return key
    }
}

/// Cache what the renderer actually draws: source frames, looks, placements
/// and captions. Effects that read external analysis use the composition generation.
struct FilmstripPlan {
    struct Sample {
        let key: String
        let sourceTime: Double?
        let plain: Bool
        // Same footage, grade, placement, caption and animation phase; only
        // the fit against the rest of the transcript might have changed.
        var captionPlaceholder: String?
    }
    private struct Look: Encodable {
        let color: ColorSettings?
        let crop: CropSettings?
        let mirror: MirrorSettings?
        let images: [ImageOverlay]
        let texts: [TextOverlay]
        let effects: [VideoEffectSettings]
    }
    private struct Span {
        let start: Double
        let namespace: String?
        let plain: Bool
    }
    private struct Picture {
        let item: VideoTimelineItem
        let spans: [Span]
        let playback: [EffectPlaybackSpan]
    }
    private struct Overlap {
        let interval: EditInterval
        let layers: [UUID]
        let placement: String
    }
    private var pictures: [UUID: Picture] = [:]
    private let composite: [EditInterval]
    private var overlaps: [Overlap] = []
    private let captions: FilmstripCaptions

    init(_ timeline: TrackTimeline, reusing prior: FilmstripPlan? = nil) {
        captions = FilmstripCaptions(timeline)
        var complex = timeline.generated.map(\.interval)
        for relation in timeline.transitions {
            let edge = relation.outgoing == nil ? -1 : relation.incoming == nil ? 1 : 0
            let timing = TransitionTiming(relation.settings, factor: relation.factor, edge: edge)
            complex.append(EditInterval(relation.origin + EditTime(timing.lower), relation.origin + EditTime(timing.upper)))
        }
        // Sweep only picture edges; a transcript or a dense audio edit must
        // not multiply the work of deciding whether two pictures overlap.
        let ordered = timeline.video.sorted(by: TrackTimeline.backToFront)
        var events: [EditTime: [(Int, Bool)]] = [:]
        for (i, item) in ordered.enumerated() {
            events[item.start, default: []].append((i, true))
            events[item.end, default: []].append((i, false))
        }
        let placements = Dictionary(timeline.placements.map { ($0.participants, $0.videos) }, uniquingKeysWith: { first, _ in first })
        var previous = EditTime.zero, active = IndexSet()
        for edge in events.keys.sorted() {
            if active.count > 1 {
                let interval = EditInterval(previous, edge)
                let layers = active.map { ordered[$0].id }
                let settings = placements[Set(layers)] ?? [:]
                let order = VideoPlacement.ordered(layers, settings: settings)
                if let placement = filmstripDigest(order.map { settings[$0] }) {
                    overlaps.append(Overlap(interval: interval, layers: order, placement: placement))
                } else { complex.append(interval) }
            }
            for (i, entering) in events[edge]! {
                if entering { active.insert(i) } else { active.remove(i) }
            }
            previous = edge
        }
        composite = TrackTimeline.union(complex)
        for item in timeline.video {
            let clip = item.content
            if let saved = prior?.pictures[item.id], saved.item.content == clip {
                pictures[item.id] = Picture(item: item, spans: saved.spans, playback: saved.playback)
                continue
            }
            let prefix = clip.sourceID.uuidString
            let effects = (clip.videoEffects ?? []).filter(\.enabled)
            // A freeze advances a second clock. A temporal matte switches the
            // entire instruction to the compositor's separate source reader.
            if clip.frozenFrame != nil || effects.contains(where: \.usesTemporalMatte) {
                continue
            }
            let stabilization = clip.stabilization.flatMap { $0.level == .off ? nil : $0 }
            let texts = clip.texts ?? [], images = clip.images ?? [], grades = clip.colorRegions ?? []
            enum Part { case text(Int), image(Int), grade(Int), effect(Int) }
            var changes: [Double: [(Part, Bool)]] = [clip.start: []]
            func span(_ part: Part, _ start: Double, _ end: Double) {
                guard end > clip.start, start < clip.end, end > start else { return }
                changes[max(clip.start, start), default: []].append((part, true))
                if end < clip.end { changes[end, default: []].append((part, false)) }
            }
            let windows = (clip.effectWindows ?? [:]).values.flatMap { $0 }
            let framing = [clip.crop?.activeRange, clip.mirror?.activeRange, stabilization?.activeRange].compactMap { $0 }
            for value in windows + framing + (clip.framingVariants ?? []).compactMap(\.activeRange) {
                for edge in [value.start, value.end] where clip.start < edge && edge < clip.end {
                    if changes[edge] == nil { changes[edge] = [] }
                }
            }
            for (i, grade) in grades.enumerated() { span(.grade(i), grade.start, grade.end) }
            for (i, image) in images.enumerated() { span(.image(i), image.start, image.end) }
            for (i, title) in texts.enumerated() { span(.text(i), title.start, title.end) }
            for (i, effect) in effects.enumerated() { span(.effect(i), effect.start, effect.end) }
            var activeTexts = IndexSet(), activeImages = IndexSet(), activeGrades = IndexSet(), activeEffects = IndexSet()
            var spans: [Span] = []
            for t in changes.keys.sorted() {
                for (part, enabled) in changes[t]! {
                    switch part {
                    case .text(let i): if enabled { activeTexts.insert(i) } else { activeTexts.remove(i) }
                    case .image(let i): if enabled { activeImages.insert(i) } else { activeImages.remove(i) }
                    case .grade(let i): if enabled { activeGrades.insert(i) } else { activeGrades.remove(i) }
                    case .effect(let i): if enabled { activeEffects.insert(i) } else { activeEffects.remove(i) }
                    }
                }
                let resolved = clip.resolvingEffects(at: t)
                func visible(_ id: UUID) -> Bool { clip.effectWindows?[id]?.contains { $0.contains(t) } ?? true }
                let titles = activeTexts.map { texts[$0] }.filter { visible($0.id) }
                let look = Look(color: clip.color ?? activeGrades.first.map { grades[$0].grade },
                                crop: resolved.crop?.activeRange?.contains(t) == false ? nil : resolved.crop,
                                mirror: resolved.mirror?.activeRange?.contains(t) == false ? nil : resolved.mirror,
                                images: activeImages.map { images[$0] }.filter { visible($0.id) }, texts: titles, effects: activeEffects.map { effects[$0] }.filter { visible($0.id) })
                let plain = look.color == nil && look.crop == nil && look.mirror == nil && look.images.isEmpty && titles.isEmpty && look.effects.isEmpty
                let namespace: String?
                // Refinement can replace these pixels without changing the saved edit.
                if resolved.stabilization.map({ $0.level != .off && $0.activeRange?.contains(t) != false }) == true ||
                    look.effects.contains(where: { $0.requiresOfflineAnalysis || [.undercranking, .superEight, .stepPrinting].contains($0.kind) }) ||
                    titles.contains(where: { $0.motion?.active == true }) { namespace = nil }
                else if plain { namespace = prefix }
                else if let digest = filmstripDigest(look) {
                    namespace = prefix + ":" + digest
                } else { namespace = nil }
                spans.append(Span(start: t, namespace: namespace, plain: plain))
            }
            pictures[item.id] = Picture(item: item, spans: spans, playback: clip.effectPlaybackSpans)
        }
    }

    private func layer(_ id: UUID, at time: EditTime) -> Sample? {
        guard let picture = pictures[id], picture.item.interval.contains(time) else { return nil }
        let source = picture.item.content.sourceTime(at: (time - picture.item.start).seconds, spans: picture.playback)
        guard let span = picture.spans.prefixEnd(where: { $0.start <= source }).last, let namespace = span.namespace else { return nil }
        return Sample(key: namespace + ":" + String(EditTime(source).ticks), sourceTime: source, plain: span.plain)
    }

    func sample(lane: UUID, at time: EditTime, generation: UUID) -> Sample {
        let transient = Sample(key: generation.uuidString + ":" + String(time.ticks), sourceTime: nil, plain: false)
        guard !composite.containsTime(time), let caption = captions.suffix(at: time) else { return transient }
        let picture: Sample
        if let overlap = overlaps.prefixEnd(where: { $0.interval.start <= time }).last, overlap.interval.contains(time) {
            var key = "overlap:" + overlap.placement
            for id in overlap.layers {
                guard let picture = layer(id, at: time) else { return transient }
                key += "|" + picture.key
            }
            picture = Sample(key: key, sourceTime: nil, plain: false)
        } else if let single = layer(lane, at: time) { picture = single }
        else { return transient }
        guard !caption.isEmpty, let envelope = captions.envelope else { return picture }
        let local = picture.key + caption
        return Sample(key: local + ":" + envelope, sourceTime: picture.sourceTime, plain: false, captionPlaceholder: local)
    }
}

extension Array {
    /// Binary search a sorted array for the end of its matching prefix.
    func prefixEnd(where matches: (Element) -> Bool) -> ArraySlice<Element> {
        var low = startIndex, high = endIndex
        while low < high {
            let mid = (low + high) / 2
            if matches(self[mid]) { low = mid + 1 } else { high = mid }
        }
        return self[..<low]
    }
}

private extension Array where Element == EditInterval {
    func containsTime(_ time: EditTime) -> Bool {
        prefixEnd { $0.start <= time }.last?.contains(time) == true
    }
}
