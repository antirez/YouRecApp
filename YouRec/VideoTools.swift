import Foundation
import CoreGraphics

// Framing is stored in the oriented source, independent of preview size.
// The output aspect belongs to the project; a crop fills that output frame.
struct CropSettings: Codable, Equatable, Sendable {
    var id = UUID()
    var x = 0.5
    var y = 0.5
    var zoom = 1.0
    var rotation = 0.0 // Clockwise degrees, applied before output-space mirrors/overlays.
    var motion: EffectAnimation?
    var activeRange: SourceInterval?
    private enum CodingKeys: String, CodingKey { case id, x, y, zoom, rotation, motion, activeRange }
    static func normalizedRotation(_ angle: Double) -> Double {
        guard angle.isFinite else { return 0 }
        let value = (angle + 180).truncatingRemainder(dividingBy: 360)
        let normalized = (value < 0 ? value + 360 : value) - 180
        return normalized == -180 && angle > 0 ? 180 : normalized
    }
    private var radians: Double { rotation * .pi / 180 }
    // The crop window is axis-aligned in output space. Its inverse-rotated
    // footprint must fit inside the source, including when panned to an edge.
    func rect(source: CGSize, canvas: CGSize) -> CGRect {
        guard source.width > 0, source.height > 0, canvas.width > 0, canvas.height > 0 else { return .zero }
        let c = abs(cos(radians)), s = abs(sin(radians))
        let scale = max((canvas.width*c + canvas.height*s)/source.width,
                        (canvas.width*s + canvas.height*c)/source.height) * min(8, max(1, zoom))
        let width = canvas.width/scale, height = canvas.height/scale
        let halfX = (width*c + height*s)/2, halfY = (width*s + height*c)/2
        let cx = min(source.width-halfX, max(halfX, x*source.width))
        let cy = min(source.height-halfY, max(halfY, y*source.height))
        return CGRect(x: cx-width/2, y: cy-height/2, width: width, height: height)
    }
    func footprint(source: CGSize, canvas: CGSize) -> CGRect {
        let area = rect(source: source, canvas: canvas), c = abs(cos(radians)), s = abs(sin(radians))
        let width = area.width*c + area.height*s, height = area.width*s + area.height*c
        return CGRect(x: area.midX-width/2, y: area.midY-height/2, width: width, height: height)
    }
    func transform(source: CGSize, canvas: CGSize) -> CGAffineTransform {
        let area = rect(source: source, canvas: canvas)
        guard area.width > 0 else { return .identity }
        let scale = canvas.width/area.width
        return CGAffineTransform(translationX: -area.midX, y: -area.midY)
            .concatenating(CGAffineTransform(rotationAngle: radians))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: canvas.width/2, y: canvas.height/2))
    }
    func clamped(source: CGSize, canvas: CGSize) -> CropSettings {
        var result = self
        result.zoom = min(8, max(1, zoom)); result.rotation = Self.normalizedRotation(rotation)
        let rect = result.rect(source: source, canvas: canvas)
        result.x = rect.midX / max(1, source.width); result.y = rect.midY / max(1, source.height)
        return result
    }
    func isFullFrame(source: CGSize, canvas: CGSize) -> Bool {
        guard abs(Self.normalizedRotation(rotation)) < 0.00001, zoom == 1, source.width > 0, source.height > 0 else { return false }
        let area = rect(source: source, canvas: canvas)
        // Encoder-safe even dimensions can slightly change an imported image's
        // aspect. That rounding alone must not create a crop or split a range.
        return abs(area.width - source.width) < max(2, source.width * 0.0025)
            && abs(area.height - source.height) < max(2, source.height * 0.0025)
    }
}
extension CropSettings {
    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = try fields.decode(UUID.self, forKey: .id)
        x = try fields.decode(Double.self, forKey: .x); y = try fields.decode(Double.self, forKey: .y)
        zoom = try fields.decode(Double.self, forKey: .zoom)
        motion = try fields.decodeIfPresent(EffectAnimation.self, forKey: .motion)
        activeRange = try fields.decodeIfPresent(SourceInterval.self, forKey: .activeRange)
        rotation = try fields.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
    }
}

struct MirrorSettings: Codable, Equatable, Sendable {
    var id = UUID()
    var horizontal = false
    var vertical = false
    var activeRange: SourceInterval?
    func transform(canvas: CGSize) -> CGAffineTransform {
        CGAffineTransform(a: horizontal ? -1 : 1, b: 0, c: 0, d: vertical ? -1 : 1,
                          tx: horizontal ? canvas.width : 0, ty: vertical ? canvas.height : 0)
    }
}
struct ImageOverlay: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var filename: String
    var start = 0.0
    var end = 3.0
    var x = 0.5
    var y = 0.5
    var width = 0.4 // fraction of the shorter canvas edge, original aspect is retained
    var opacity = 1.0
    var motion: EffectAnimation?
    func rect(image: CGSize, canvas: CGSize) -> CGRect {
        let w = min(canvas.width, canvas.height) * width, h = w * image.height / max(1, image.width)
        return CGRect(x: canvas.width * x - w / 2, y: canvas.height * (1 - y) - h / 2, width: w, height: h)
    }
}

enum OutputShape: String, CaseIterable, Identifiable {
    case original, landscape, portrait, square, feed
    var id: String { rawValue }
    var title: String { switch self { case .original: return "Original"; case .landscape: return "16:9"; case .portrait: return "9:16"; case .square: return "1:1"; case .feed: return "4:5" } }
    var aspect: Double? { switch self { case .original: return nil; case .landscape: return 16 / 9; case .portrait: return 9 / 16; case .square: return 1; case .feed: return 4 / 5 } }
    static func canvas(source: CGSize, aspect: Double?) -> CGSize {
        guard let aspect else { return source }
        // Keep the source's short-edge resolution, rounded to encoder-safe pixels.
        let edge = min(source.width, source.height)
        return CGSize(width: max(2, ((aspect >= 1 ? edge * aspect : edge) / 2).rounded() * 2),
                      height: max(2, ((aspect >= 1 ? edge : edge / aspect) / 2).rounded() * 2))
    }
}

// All tool timing is anchored to immutable source media. Timeline time can
// change after a speed edit, pause removal, split or reorder without losing it.
struct SourceInterval: Codable, Equatable, Sendable {
    var start: Double
    var end: Double
    var duration: Double { max(0, end - start) }
    func contains(_ source: Double) -> Bool { start <= source && source < end }
}
struct SpeedSettings: Codable, Equatable, Sendable {
    var id = UUID()
    var rate = 1.0
}
enum ColorLook: String, Codable, CaseIterable, Identifiable, Sendable {
    case natural, warm, cool, cinema, mono, portrait, daylight, goldenHour, mutedFilm, richContrast, pastel, night, silver, ink
    var id: String { rawValue }
    var title: String { switch self {
    case .natural: return "Natural"; case .warm: return "Warm"; case .cool: return "Cool shadows"
    case .cinema: return "Cinema"; case .mono: return "Mono"; case .portrait: return "Portrait"
    case .daylight: return "Daylight"; case .goldenHour: return "Golden hour"; case .mutedFilm: return "Muted film"
    case .richContrast: return "Rich contrast"; case .pastel: return "Pastel"; case .night: return "Night"
    case .silver: return "Silver"; case .ink: return "Ink"
    } }
}
struct ColorSettings: Codable, Equatable, Sendable {
    var id = UUID()
    var look: ColorLook = .natural
    var amount = 1.0
    var imported: ImportedLUT?
    var exposure: Double?
    var highlights: Double?
    var localRecovery: Double?
    var warmth: Double?
    var tint: Double?
    var motion: EffectAnimation?
    var title: String { imported?.name ?? (look == .natural && hasBalance ? "Color balance" : look.title) }
    var hasBalance: Bool { (exposure ?? 0) != 0 || (highlights ?? 0) != 0 || (localRecovery ?? 0) != 0 || (warmth ?? 0) != 0 || (tint ?? 0) != 0 }
    // A zero-strength look remains editable; only an empty grade is removed.
    var isIdentity: Bool { motion == nil && !hasBalance && look == .natural && imported == nil }
    var valid: Bool {
        amount.isFinite && (0...1).contains(amount) && (exposure ?? 0).isFinite && (-4...4).contains(exposure ?? 0)
        && (highlights ?? 0).isFinite && (-1...1).contains(highlights ?? 0)
        && (localRecovery ?? 0).isFinite && (0...1).contains(localRecovery ?? 0)
        && (warmth ?? 0).isFinite && (-1...1).contains(warmth ?? 0) && (tint ?? 0).isFinite && (-1...1).contains(tint ?? 0)
        && (imported?.valid ?? true)
    }
}
/// Source time for moving footage, or the advancing motion clock for a freeze.
/// Intervals are half-open so adjacent grades never compete for a frame.
struct ColorRegion: Codable, Equatable, Sendable {
    var start: Double
    var end: Double
    var grade: ColorSettings
    var valid: Bool {
        start.isFinite && end.isFinite && start >= 0 && end > start && grade.valid
            && (grade.motion?.valid(for: grade.pose, accepts: { grade.applying($0).valid }) ?? true)
    }
}

extension TimelineClip {
    var hasGrade: Bool { color != nil || colorRegions?.isEmpty == false }
    var gradeAssets: [ImportedLUT] { (color?.lutAssets ?? []) + (colorRegions ?? []).flatMap { $0.grade.lutAssets } }

    func gradeTime(at local: Double) -> Double {
        if let hold = frozenFrame { return hold.sourceTime + hold.offset + local }
        return sourceTime(at: local)
    }
    func gradeOffset(at source: Double) -> Double {
        if let hold = frozenFrame { return min(hold.duration, max(0, source - hold.sourceTime - hold.offset)) }
        return timelineTime(forSource: source)
    }
    func grade(at source: Double) -> ColorSettings? {
        color ?? colorRegions?.first { $0.start <= source && source < $0.end }?.grade
    }
    var visibleGrades: [ColorRegion] {
        guard hasGrade else { return [] }
        let first = gradeTime(at: 0), last = gradeTime(at: duration)
        if let color { return [ColorRegion(start: first, end: last, grade: color)] }
        return (colorRegions ?? []).compactMap { region in
            let a = max(first, region.start), b = min(last, region.end)
            return b > a ? ColorRegion(start: a, end: b, grade: region.grade) : nil
        }
    }

    mutating func replaceGrade(in range: ClosedRange<Double>, with grade: ColorSettings?, removingOnly id: UUID? = nil) {
        let lower = range.lowerBound, upper = range.upperBound
        guard upper > lower else { return }
        var result: [ColorRegion] = []
        for region in visibleGrades {
            guard region.start < upper, region.end > lower, id == nil || region.grade.id == id else {
                result.append(region); continue
            }
            if region.start < lower { result.append(ColorRegion(start: region.start, end: lower, grade: region.grade)) }
            if region.end > upper {
                var remainder = region.grade
                if region.start < lower {
                    // Separate handles for the two remnants.
                    remainder.id = UUID()
                }
                result.append(ColorRegion(start: upper, end: region.end, grade: remainder))
            }
        }
        if let grade {
            // Re-editing just the middle of a look leaves independent editable remnants.
            for i in result.indices where result[i].grade.id == grade.id { result[i].grade.id = UUID() }
            result.append(ColorRegion(start: lower, end: upper, grade: grade))
        }
        if result.count == 1, result[0].start <= gradeTime(at: 0), result[0].end >= gradeTime(at: duration) {
            color = result[0].grade; colorRegions = nil
        } else {
            color = nil; colorRegions = result.isEmpty ? nil : result.sorted { $0.start < $1.start }
        }
    }
}

extension EditState {
    mutating func setGrade(_ grade: ColorSettings?, in range: ClosedRange<Double>, videos: Set<UUID>, removingOnly id: UUID? = nil,
                           preservingClocksFrom original: TrackTimeline? = nil) {
        for i in timeline.video.indices where videos.contains(timeline.video[i].id) {
            let item = timeline.video[i]
            guard let part = item.interval.intersection(EditInterval(range)) else { continue }
            let a = item.content.gradeTime(at: (part.start - item.start).seconds)
            let b = item.content.gradeTime(at: (part.end - item.start).seconds)
            guard b > a else { continue }
            var value = grade
            if let motion = grade?.motion, motion.clock.isEmpty {
                let previous = original?.video.first { $0.id == item.id }?.content.grade(at: a)?.motion
                value?.motion = motion.placed(on: item.content, offset: item.start.seconds - range.lowerBound, replacing: previous)
            }
            timeline.video[i].content.replaceGrade(in: a...b, with: value, removingOnly: id)
        }
    }
}

enum OverlayPlacement {
    /// Normalized coordinates in the video frame. Each axis snaps independently.
    static func snappedCenter(_ point: CGPoint) -> CGPoint {
        func snap(_ value: CGFloat) -> CGFloat {
            abs(value - 0.5) < 0.015 ? 0.5 : min(1, max(0, value))
        }
        return CGPoint(x: snap(point.x), y: snap(point.y))
    }
}

enum TextStyle: String, Codable, CaseIterable, Sendable { case clean, bold, box, highlight }
enum TextColor: String, Codable, CaseIterable, Sendable {
    case white, black, yellow, coral, mint, blue
    var rgb: (Double, Double, Double) {
        switch self {
        case .white: return (1, 1, 1); case .black: return (0.03, 0.03, 0.04)
        case .yellow: return (1, 0.85, 0.16); case .coral: return (1, 0.3, 0.36)
        case .mint: return (0.35, 0.94, 0.72); case .blue: return (0.35, 0.66, 1)
        }
    }
}
enum EditorDurationPresets {
    static let wholeSeconds: [Double] = (1...10).map(Double.init) + [15, 30, 60]
    static let transitionSeconds = [0.5] + wholeSeconds

    static func fits(_ seconds: Double, within available: Double) -> Bool {
        EditTime(seconds) <= EditTime(available)
    }
}

/// Range trimming uses the editor clock. A source boundary can be between frames.
struct EditorRangeTiming {
    enum Edge { case start, end }
    let bounds: ClosedRange<Double>
    private(set) var range: ClosedRange<Double>
    var duration: Double { range.upperBound - range.lowerBound }
    var available: Double { bounds.upperBound - range.lowerBound }

    /// Pick a paused frame from the footage the overlay will actually cover.
    /// A title spanning a cut can have its readable hold on the other clip.
    func openingPosition(footage: [ClosedRange<Double>], readable: ClosedRange<Double>?) -> Double {
        let middle = range.lowerBound + duration / 2
        let preferred = readable ?? range
        let target = preferred.contains(middle) ? middle : (preferred.lowerBound + preferred.upperBound) / 2
        var best: Double?
        for clip in footage {
            let first = max(range.lowerBound, clip.lowerBound)
            let end = min(range.upperBound, clip.upperBound)
            guard first < end else { continue }
            let last = max(first, end - TimelineEditing.frame)
            let candidate = min(last, max(first, target))
            if best.map({ abs(candidate - target) < abs($0 - target) }) ?? true { best = candidate }
        }
        return (best ?? range.lowerBound) - range.lowerBound
    }

    init(range: ClosedRange<Double>, bounds: ClosedRange<Double>) {
        self.bounds = bounds
        let start = min(bounds.upperBound, max(bounds.lowerBound, range.lowerBound))
        self.range = start...min(bounds.upperBound, max(start, range.upperBound))
    }

    func limits(for edge: Edge) -> ClosedRange<Double> {
        switch edge {
        case .start: bounds.lowerBound...max(bounds.lowerBound, range.upperBound - TimelineEditing.frame)
        case .end: min(bounds.upperBound, range.lowerBound + TimelineEditing.frame)...bounds.upperBound
        }
    }

    func boundary(_ edge: Edge) -> Double { edge == .start ? range.lowerBound : range.upperBound }

    func previewTime(for edge: Edge) -> Double {
        edge == .start ? range.lowerBound : max(range.lowerBound, range.upperBound - TimelineEditing.frame)
    }

    func fraction(for edge: Edge) -> Double {
        let span = bounds.upperBound - bounds.lowerBound
        return span > 0 ? (boundary(edge) - bounds.lowerBound) / span : 0
    }

    // Both thumbs use the same ruler. Only the dragged thumb's permitted travel changes.
    func time(at fraction: Double, edge: Edge) -> Double {
        let limits = limits(for: edge)
        if fraction <= 0 { return limits.lowerBound }
        if fraction >= 1 { return limits.upperBound }
        let offset = (bounds.upperBound - bounds.lowerBound) * fraction
        let frames = (offset / TimelineEditing.frame).rounded()
        return min(limits.upperBound, max(limits.lowerBound, bounds.lowerBound + frames * TimelineEditing.frame))
    }

    mutating func set(_ edge: Edge, to value: Double) {
        guard value.isFinite else { return }
        let limits = limits(for: edge)
        let time = min(limits.upperBound, max(limits.lowerBound, value))
        range = edge == .start ? time...range.upperBound : range.lowerBound...time
    }

}

/// A source-anchored title clock survives an edit to just its middle, including
/// when the selection contains the entire first or last clip of its animation.
struct TitlePlaybackClock: Codable, Equatable, Sendable {
    var duration: Double
    var points: [StrobeTimePoint]
    func elapsed(at source: Double) -> Double { StrobeTimePoint.elapsed(at: source, in: points) }
    var valid: Bool {
        duration.isFinite && duration > 0 && !points.isEmpty && points.allSatisfy { $0.source.isFinite && $0.elapsed.isFinite }
            && zip(points, points.dropFirst()).allSatisfy { $0.source <= $1.source && $0.elapsed <= $1.elapsed }
    }
}

struct TextOverlay: Codable, Equatable, Identifiable, Sendable {
    static let starterText = "Text"
    var id = UUID()
    var text = Self.starterText
    var start = 0.0
    var end = 3.0
    var x = 0.5
    var y = 0.5
    // Font size relative to the shorter canvas dimension; consistent on rotation.
    var size = 0.10
    var style: TextStyle = .bold
    var color: TextColor = .white
    var appearance: TitleDesign?
    var labelHeadline: LabelHeadline?
    var motion: TitleMotion?
    var playbackClock: TitlePlaybackClock?
    var displayText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? labelHeadline?.label ?? "" : text
    }
    var hasText: Bool { !displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var fontFaces: [String] {
        [appearance?.face, labelHeadline?.labelStyle.face, labelHeadline?.headlineStyle.face].compactMap { $0 }
    }
    var design: TitleDesign { appearance ?? .legacy(style, color: color) }
}
struct DetectedPause: Codable, Equatable, Sendable {
    var raw: SourceInterval
    var enabled = true
}
enum PauseLevelMode: String, Codable, Sendable { case automatic, manual }
struct PauseSettings: Codable, Equatable, Sendable {
    var id = UUID()
    var thresholdDB = -38.0
    var minimum = 0.6
    var before = 0.12
    var after = 0.18
    var cuts: [SourceInterval] = []
    var candidates: [DetectedPause]?
    var analyzed: SourceInterval?
    var levelMode: PauseLevelMode? = .automatic // Absent in saved peak-based detections.
}

extension TimelineClip {
    var rate: Double { min(6,max(0.125,(speed?.rate ?? 1) * sequenceRate)) }
    var sourceDuration: Double { max(0, end - start) }
    var keptIntervals: [SourceInterval] {
        var result: [SourceInterval] = [], cursor = start
        for cut in (pauses?.cuts ?? []).sorted(by: { $0.start < $1.start }) {
            let a = max(start, cut.start), b = min(end, cut.end)
            guard b > a else { continue }
            if a > cursor { result.append(SourceInterval(start: cursor, end: a)) }
            cursor = max(cursor, b)
        }
        if cursor < end { result.append(SourceInterval(start: cursor, end: end)) }
        return result
    }
    func sourceTime(at timelineOffset:Double)->Double { sourceTime(at:timelineOffset,spans:effectPlaybackSpans) }
    func sourceTime(at timelineOffset: Double,spans:[EffectPlaybackSpan]) -> Double {
        if let frozenFrame { return frozenFrame.sourceTime }
        var remaining = max(0, timelineOffset)
        for (index, span) in spans.enumerated() {
            if remaining < span.duration - 0.000001 || index == spans.count-1 { return min(span.end,span.start+remaining*span.rate) }
            remaining -= span.duration
        }
        return end
    }
    func timelineTime(forSource time: Double) -> Double {
        if let frozenFrame { return time <= frozenFrame.sourceTime ? 0 : frozenFrame.duration }
        return effectPlaybackSpans.reduce(0) { $0 + max(0,min($1.end,time)-$1.start)/$1.rate }
    }
    var playbackPieces: [TimelineClip] {
        if frozenFrame != nil { return resolvedEffectPieces }
        return effectPlaybackSpans.flatMap { span -> [TimelineClip] in
            var piece=self;piece.start=span.start;piece.end=span.end;piece.pauses=nil
            // The source clock already integrated the speed controls. Collapse
            // only those controls in this transient render instruction, keeping
            // every other animated parameter and the project's original recipe.
            for e in (piece.videoEffects ?? []).indices where [.undercranking,.stepPrinting].contains(piece.videoEffects![e].kind) {
                if let p=piece.videoEffects![e].parameters.firstIndex(where:{$0.id=="speed"}) {
                    piece.videoEffects![e].parameters[p].value = .number(1)
                    piece.videoEffects![e].parameters[p].keyframes=[]
                }
            }
            piece.speed=SpeedSettings(rate:span.rate)
            return piece.resolvedEffectPieces
        }
    }
}

extension TimelineEditing {
    // Split only at scope boundaries, retaining source effects and identities.
    static func scoped(_ state: EditState, range: ClosedRange<Double>) -> (EditState, Set<UUID>) {
        for time in [range.lowerBound, range.upperBound] where state.layout.boundary(at: time) == nil {
            if state.layout.transition(at: time) != nil { return (state, []) }
        }
        let scoped = state.timeline.scoped(state.timeline.entireSelection(range: EditInterval(range)))
        return (EditState(timeline: scoped.timeline, outputSize: state.outputSize), scoped.selection.video)
    }
    static func scope(_ state: EditState, selection: ClosedRange<Double>?, clipID: UUID?) -> ClosedRange<Double> {
        if let selection { return max(0, selection.lowerBound)...min(state.duration, selection.upperBound) }
        if let clip = state.clips.first(where: { $0.id == clipID }) {
            return state.layout.placements.first { $0.clip.id == clip.id }!.range
        }
        return 0...state.duration
    }
}

enum PauseDetector {
    static func levelDB(wave: SourceWaveform, settings: PauseSettings) -> Double {
        guard settings.levelMode == .automatic, let levels = wave.rms, !levels.isEmpty else { return settings.thresholdDB }
        let sorted = levels.sorted()
        func db(_ percentile: Int) -> Double {
            20 * log10(max(1e-8, Double(sorted[(sorted.count - 1) * percentile / 100])))
        }
        let floorDB = db(10)
        var speechDB = db(90)
        // A take can be mostly steady room tone with only a few spoken words.
        // A sustained louder passage qualifies as a reference; a lone click cannot.
        if speechDB - floorDB < 10 && db(50) - floorDB < 5 && wave.duration > 0 {
            let block = max(1, Int(ceil(0.2 * Double(levels.count) / wave.duration)))
            var loudest: Float = 0
            if block <= levels.count {
                for i in stride(from: 0, through: levels.count - block, by: block) {
                    loudest = max(loudest, levels[i..<(i + block)].min() ?? 0)
                }
            }
            speechDB = max(speechDB, 20 * log10(max(1e-8, Double(loudest))))
        }
        // Leave headroom above room tone and stay well below the stronger voice.
        return max(-56, min(-27, floorDB + 8, speechDB - 18)).rounded()
    }
    static func raw(wave: SourceWaveform, clip: TimelineClip, settings: PauseSettings, levelDB: Double? = nil) -> [SourceInterval] {
        var raw = settings; raw.before = 0; raw.after = 0
        return detect(wave: wave, clip: clip, settings: raw, levelDB: levelDB)
    }
    static func padded(_ raw: SourceInterval, rate: Double, settings: PauseSettings) -> SourceInterval {
        let a = min(raw.end, raw.start + settings.before * rate)
        return SourceInterval(start: a, end: max(a, raw.end - settings.after * rate))
    }
    static func padded(_ raw:SourceInterval,clip:TimelineClip,settings:PauseSettings)->SourceInterval {
        var full=clip;full.pauses=nil
        let a=min(raw.end,full.sourceTime(at:full.timelineTime(forSource:raw.start)+settings.before))
        let b=max(a,full.sourceTime(at:max(0,full.timelineTime(forSource:raw.end)-settings.after)))
        return SourceInterval(start:a,end:b)
    }
    static func effectiveCuts(_ candidates: [DetectedPause], clip: TimelineClip, settings: PauseSettings) -> [SourceInterval] {
        let frame = TimelineEditing.frame * clip.rate
        let proposed = candidates.filter(\.enabled).map { candidate -> SourceInterval in
            let padded = padded(candidate.raw,clip:clip,settings:settings)
            return SourceInterval(start: max(clip.start, padded.start), end: min(clip.end, padded.end))
        }.filter { $0.duration >= frame - 0.000001 }.sorted { $0.start < $1.start }
        var cuts: [SourceInterval] = []
        for cut in proposed {
            if let last = cuts.last, cut.start <= last.end {
                cuts[cuts.count - 1].end = max(last.end, cut.end)
            } else { cuts.append(cut) }
        }
        // Preserve one addressable frame even with zero padding on a silent
        // clip. The UI summary and the saved edit use these same intervals.
        let excess = cuts.reduce(0) { $0 + $1.duration } - max(0, clip.sourceDuration - frame)
        if excess > 0, !cuts.isEmpty { cuts[cuts.count - 1].end -= excess }
        return cuts.filter { $0.duration >= frame - 0.000001 }
    }
    static func detect(wave: SourceWaveform, clip: TimelineClip, settings: PauseSettings, levelDB: Double? = nil) -> [SourceInterval] {
        let levels = settings.levelMode == nil ? wave.peaks : wave.rms ?? []
        guard !levels.isEmpty, wave.duration > 0 else { return [] }
        let step = wave.duration / Double(levels.count)
        let threshold = Float(pow(10, (levelDB ?? Self.levelDB(wave: wave, settings: settings)) / 20))
        var result: [SourceInterval] = [], beginning: Int?
        var full = clip; full.pauses = nil
        func append(_ bins: Range<Int>) {
            let start = Double(bins.lowerBound) * step, time = min(clip.end, Double(bins.upperBound) * step)
            guard full.timelineTime(forSource:time)-full.timelineTime(forSource:start)>=settings.minimum else { return }
            let interval=padded(SourceInterval(start:start,end:time),clip:full,settings:settings)
            if full.timelineTime(forSource:interval.end)-full.timelineTime(forSource:interval.start)>=TimelineEditing.frame { result.append(interval) }
        }
        let first = max(0, Int(ceil(clip.start / step))), last = min(levels.count, Int(floor(clip.end / step)))
        if first < last {
            // Establish that this is dialogue before relaxing the energy gate. For music,
            // steady room tone or an unvoiced selection, keep the ordinary silence test.
            let speech = settings.levelMode == .automatic && wave.speech?.count == levels.count ? wave.speech : nil
            var hasDialogue = false
            if let speech {
                var voiced = 0
                let reference = max(1, Int(ceil(0.16 / step)))
                for i in first..<last {
                    voiced = speech[i] >= 179 ? voiced + 1 : 0
                    if voiced >= reference { hasDialogue = true; break }
                }
            }
            // Let steady noise exceed the normal threshold by up to 12 dB, bounded
            // at -15 dBFS. A likely voice protects even a quiet syllable.
            let noiseLimit = min(Float(0.177828), threshold * 3.981072)
            func close(at end: Int) {
                guard let start = beginning else { return }
                beginning = nil
                let range = start..<end
                guard hasDialogue, range.count >= 5,
                      levels[range].contains(where: { $0 > threshold }) else { append(range); return }
                // A faint utterance can slip past the voice classifier. Protect sustained
                // onsets that rise 7 dB above this gap's own background. Three of five
                // 10 ms bins distinguish a short syllable from an isolated noise spike.
                let sorted = levels[range].sorted()
                let onset = max(threshold, sorted[sorted.count / 2] * 2.23872)
                var elevated = 0, cursor = start
                for i in start..<(end + 2) {
                    if i < end, levels[i] > onset { elevated += 1 }
                    if i - 5 >= start, levels[i - 5] > onset { elevated -= 1 }
                    if i >= start + 2, elevated >= 3 {
                        let protected = i - 2
                        if cursor < protected { append(cursor..<protected) }
                        cursor = protected + 1
                    }
                }
                if cursor < end { append(cursor..<end) }
            }
            for index in first..<last {
                var quiet = levels[index] <= threshold
                if hasDialogue, let speech {
                    let probability = speech[index]
                    quiet = (quiet && probability < 102) || (levels[index] <= noiseLimit && probability < 31)
                }
                if quiet { if beginning == nil { beginning = index } }
                else { close(at: index) }
            }
            close(at: last)
        }
        return result
    }
}

enum VideoTool: String, CaseIterable, Identifiable, Sendable {
    case subtitles, stabilize, text, color, pauses, speed, crop, mirror, image, addVideo, addAudio, censorAudio, transition, videoEffects, enhanceAudio, volume, placement
    var id: String { rawValue }
    var title: String { switch self { case .subtitles: return "Subtitles"; case .stabilize: return "Stabilize"; case .text: return "Text"; case .color: return "Color LUTs"; case .pauses: return "Pauses"; case .speed: return "Speed"; case .crop: return "Crop"; case .mirror: return "Mirror"; case .image: return "Image"; case .transition: return "Transition"; case .videoEffects: return "Video effects"; case .enhanceAudio: return "Enhance audio"; case .volume: return "Volume"; case .placement: return "Placement"; case .addAudio: return "Add audio"; case .censorAudio: return "Censor audio"; case .addVideo: return "Video or photo" } }
    var symbol: String { switch self { case .subtitles: return "captions.bubble"; case .stabilize: return "level"; case .text: return "textformat"; case .color: return "camera.filters"; case .pauses: return "waveform.path"; case .speed: return "speedometer"; case .crop: return "crop"; case .mirror: return "arrow.left.and.right.righttriangle.left.righttriangle.right"; case .image: return "photo"; case .transition: return "square.on.square"; case .videoEffects: return "sparkles.tv"; case .enhanceAudio: return "waveform.badge.mic"; case .volume: return "speaker.wave.2"; case .placement: return "square.3.layers.3d"; case .addAudio: return "waveform.badge.plus"; case .censorAudio: return "waveform.slash"; case .addVideo: return "video.badge.plus" } }
    var detail: String { switch self { case .subtitles: return "Transcribe speech into editable captions, offline"; case .stabilize: return "Smooth camera movement"; case .text: return "Add words to the picture"; case .color: return "Choose a look and strength"; case .pauses: return "Review and shorten silence"; case .speed: return "Change pace, keep voice pitch"; case .crop: return "Rotate and choose what stays in frame"; case .mirror: return "Flip horizontally or vertically"; case .image: return "Place a picture over the video"; case .transition: return "Join two clips, or fade to and from black"; case .videoEffects: return "Film techniques, backgrounds and animated looks"; case .enhanceAudio: return "Apply voice filters to selected sound"; case .volume: return "Adjust the selected audio level"; case .placement: return "Arrange overlapping videos"; case .addAudio: return "Record or import sound at the playhead"; case .censorAudio: return "Replace sound in a marked range with a beep"; case .addVideo: return "Insert photos and videos or record here" } }
}
extension VideoTool {
    var isAudioRange: Bool { self == .censorAudio || self == .enhanceAudio }
    var hasEditableRange: Bool { isAudioRange || [.text, .image, .color, .videoEffects, .crop, .mirror, .stabilize].contains(self) }
}

struct ToolRegion: Identifiable {
    var id: String { "\(tool.rawValue)-\(effectID)-\(clipID)" + (tool == .placement || tool.hasEditableRange ? "-\(EditTime(range.lowerBound).ticks)-\(EditTime(range.upperBound).ticks)" : "") }
    let tool: VideoTool
    let effectID: UUID
    let clipID: UUID
    let range: ClosedRange<Double>
    let label: String
}
extension EditState {
    /// Source-local recipes render each clip. Their persisted ID identifies the application.
    /// Older edits have no explicit membership: touching clips from different takes
    /// can share one authored ID, while a plain split inherited its recipe by value.
    func applicationRegions(for region: ToolRegion, matching: [ToolRegion], openingApplication: Bool = true) -> [ToolRegion] {
        guard region.tool.hasEditableRange, matching.count > 1 else { return [region] }
        let audio = region.tool.isAudioRange
        let owners = audio
            ? Dictionary(uniqueKeysWithValues: timeline.audio.map { ($0.id, ($0.occurrenceID, $0.spanningEffects?.contains(region.effectID) == true)) })
            : Dictionary(uniqueKeysWithValues: timeline.video.map { ($0.id, ($0.occurrenceID, $0.spanningEffects?.contains(region.effectID) == true)) })
        let pictures = Dictionary(uniqueKeysWithValues: timeline.video.map { ($0.id, $0.content) })
        let sounds = Dictionary(uniqueKeysWithValues: timeline.audio.map { ($0.id, $0) })
        // Earlier builds sometimes copied the ID while allowing the two halves to
        // be restyled independently. Preserve that distinction when opening an old edit.
        func sameLegacyRecipe(_ a: ToolRegion, _ b: ToolRegion) -> Bool {
            let id = region.effectID
            if audio {
                guard let l = sounds[a.clipID], let r = sounds[b.clipID] else { return false }
                let la = EditTime(a.range.lowerBound) - l.start, rb = EditTime(b.range.lowerBound) - r.start
                if region.tool == .censorAudio {
                    return l.censors.first { $0.id == id && $0.interval.start == la }?.settings
                        == r.censors.first { $0.id == id && $0.interval.start == rb }?.settings
                }
                return l.enhancements.first { $0.id == id && $0.interval.start == la }?.effects
                    == r.enhancements.first { $0.id == id && $0.interval.start == rb }?.effects
            }
            guard let l = pictures[a.clipID], let r = pictures[b.clipID] else { return false }
            func recipe(_ clip: TimelineClip) -> TimelineClip {
                var value = TimelineClip(id: id, sourceID: id, start: 0, end: 1)
                switch region.tool {
                case .text:
                    if var title = clip.texts?.first(where: { $0.id == id }) {
                        title.start = 0; title.end = 1; value.texts = [title]
                    }
                case .image:
                    if var image = clip.images?.first(where: { $0.id == id }) {
                        image.start = 0; image.end = 1; image.motion?.clock = []; value.images = [image]
                    }
                case .color:
                    value.color = clip.visibleGrades.first { $0.grade.id == id }?.grade
                    value.color?.motion?.clock = []
                case .mirror: value.mirror = clip.mirror; value.mirror?.activeRange = nil
                case .crop: value.crop = clip.crop; value.crop?.activeRange = nil; value.crop?.motion?.clock = []
                case .stabilize: value.stabilization = StabilizationSettings(level: clip.stabilization?.level ?? .off)
                case .videoEffects:
                    if var effect = clip.videoEffects?.first(where: { $0.id == id }) {
                        effect.start = 0; effect.end = 1; effect.motion?.clock = []; effect.strobeTimeMap = nil
                        effect.phaseOffset = nil; value.videoEffects = [effect]
                    }
                default: break
                }
                return value
            }
            return recipe(l) == recipe(r)
        }
        var event = [region], remaining = matching.filter { $0.clipID != region.clipID || $0.range != region.range }
        while !remaining.isEmpty {
            let next = remaining.filter { candidate in
                guard let owner = owners[candidate.clipID] else { return false }
                return event.contains { member in
                    guard let other = owners[member.clipID] else { return false }
                    if candidate.clipID == member.clipID { return owner.1 }

                    let a = EditInterval(candidate.range), b = EditInterval(member.range)
                    if owner.1 && other.1 { return true }
                    if region.tool == .censorAudio, a.intersection(b) != nil { return true }
                    return (openingApplication || owner.0 != other.0) && max(a.start, b.start) <= min(a.end, b.end) && sameLegacyRecipe(candidate, member)
                }
            }
            guard !next.isEmpty else { break }
            event += next
            remaining.removeAll { candidate in next.contains { $0.clipID == candidate.clipID && $0.range == candidate.range } }
        }
        return event
    }

    func request(for region: ToolRegion, selection: TimelineSelection = TimelineSelection(), openingBadge: Bool = false) -> ToolRequest {
        if region.tool == .subtitles { return ToolRequest(tool: .subtitles, range: 0...duration, scopeTitle: "Project subtitles", effectID: region.effectID) }
        let audio = [.enhanceAudio, .volume, .censorAudio].contains(region.tool)
        let matching = toolRegions.filter { $0.tool == region.tool && $0.effectID == region.effectID }
        let event = applicationRegions(for: region, matching: matching, openingApplication: openingBadge)
        let selected = audio ? selection.audio : selection.video
        let whole = openingBadge && region.tool.hasEditableRange
        let scoped = whole ? [] : matching.filter { selected.contains($0.clipID) && (selection.range?.intersection(EditInterval($0.range)) != nil || selection.range == nil) }
        let regions = scoped.isEmpty ? event : scoped
        let ids = Set(regions.map(\.clipID))
        let bounds = EditInterval((regions.map { $0.range.lowerBound }.min() ?? region.range.lowerBound)...(regions.map { $0.range.upperBound }.max() ?? region.range.upperBound))
        let range = scoped.isEmpty ? bounds : selection.range.flatMap { $0.intersection(bounds) } ?? bounds
        let title = ids.count == 1 ? (audio ? "This audio section" : "This clip") : "Effect range · \(ids.count) \(audio ? "audio sections" : "clips")"
        let targets = TimelineSelection(video: audio ? [] : ids, audio: audio ? ids : [], range: audio && [.enhanceAudio, .censorAudio].contains(region.tool) ? range : (scoped.isEmpty ? nil : selection.range))
        return ToolRequest(tool: region.tool, range: range.seconds, scopeTitle: title, effectID: region.effectID,
                           clipIDs: audio ? nil : ids, targets: targets)
    }
    /// Persist membership when an application is created. This also distinguishes a deliberate
    /// operation across a gap from coincidental same-ID fragments left by a cut.
    mutating func rememberApplications(of tool: VideoTool, changedFrom before: EditState) {
        guard tool.hasEditableRange else { return }
        let audio = tool.isAudioRange
        let changed: Set<UUID>
        if audio {
            let old = Dictionary(uniqueKeysWithValues: before.timeline.audio.map { ($0.id, $0) })
            changed = Set(timeline.audio.filter { old[$0.id] != $0 }.map(\.id))
        } else {
            let old = Dictionary(uniqueKeysWithValues: before.timeline.video.map { ($0.id, $0.content) })
            changed = Set(timeline.video.filter { old[$0.id] != $0.content }.map(\.id))
        }
        guard !changed.isEmpty else { return }
        let groups = Dictionary(grouping: toolRegions.filter { $0.tool == tool && changed.contains($0.clipID) }, by: \.effectID)
        let oldRegions = before.toolRegions.filter { $0.tool == tool }
        for (id, parts) in groups {
            let ids = Set(parts.map(\.clipID))
            // New applications need explicit membership. Editing an existing range
            // keeps its established membership, including old independent occurrences.
            guard !oldRegions.contains(where: { $0.effectID == id }) else { continue }
            if audio {
                for i in timeline.audio.indices where ids.contains(timeline.audio[i].id) {
                    timeline.audio[i].spanningEffects = (timeline.audio[i].spanningEffects ?? []).union([id])
                }
            } else {
                for i in timeline.video.indices where ids.contains(timeline.video[i].id) {
                    timeline.video[i].spanningEffects = (timeline.video[i].spanningEffects ?? []).union([id])
                }
            }
        }
    }

    // Badge removal stays on its segment. Only an explicit marked range may
    // split that segment further; unrelated effects and source media stay intact.
    func removingTool(_ request:ToolRequest)->EditState {
        guard let id=request.effectID else {return self}
        var result=self
        if request.tool == .subtitles { result.timeline.removeSubtitles(); return result }
        if request.tool == .color {
            result.setGrade(nil, in: request.range, videos: request.clipIDs ?? Set(timeline.video.map(\.id)), removingOnly: id)
            return result
        }
        if request.tool == .censorAudio {
            let targets = request.targets ?? TimelineSelection(audio: Set(timeline.audio.map(\.id)), range: EditInterval(request.range))
            result.timeline.censor(nil, selection: targets, removingOnly: id)
            return result
        }
        if request.tool == .enhanceAudio {
            let targets = request.targets ?? TimelineSelection(audio: Set(timeline.audio.map(\.id)), range: EditInterval(request.range))
            for i in result.timeline.audio.indices where targets.audio.contains(result.timeline.audio[i].id) {
                let item = result.timeline.audio[i]
                let scope = targets.range ?? item.interval
                result.timeline.audio[i].enhancements = item.enhancements.flatMap { region -> [AudioEnhancementRegion] in
                    guard region.id == id, let part = EditInterval(item.start + region.interval.start, item.start + region.interval.end).intersection(scope) else { return [region] }
                    var kept: [AudioEnhancementRegion] = []
                    if item.start + region.interval.start < part.start { var copy = region; copy.interval.end = part.start - item.start; kept.append(copy) }
                    if item.start + region.interval.end > part.end { var copy = region; copy.interval.start = part.end - item.start; if !kept.isEmpty { copy.id = UUID() }; kept.append(copy) }
                    return kept
                }
            }
            return result
        }
        if request.tool == .volume {
            for i in result.timeline.audio.indices where result.timeline.audio[i].id == id {
                result.timeline.audio[i].volumeDB = 0; result.timeline.audio[i].muted = false
                result.timeline.audio[i].fadeIn = nil; result.timeline.audio[i].fadeOut = nil
            }
            return result
        }
        if request.tool == .placement { result.timeline.placements.removeAll { $0.id == id }; return result }
        if request.tool == .transition {
            guard let join = layout.joins.first(where: { $0.transition?.id == id }) else { return self }
            return restoringStraightCut(at: join.index)
        }
        let scoped: Set<UUID>
        if request.targets?.range != nil { (result, scoped) = request.videoScope(in: self) }
        else { scoped = request.clipIDs ?? Set(clips.map(\.id)) }
        if request.tool == .videoEffects {
            result.clips.removeAll {clip in scoped.contains(clip.id) && clip.frozenFrame != nil && (clip.videoEffects ?? []).contains {$0.id==id && $0.kind == .freezeFrame}}
        }
        for index in result.clips.indices {
            guard scoped.contains(result.clips[index].id) else {continue}
            switch request.tool {
            case .videoEffects:
                result.clips[index].videoEffects?.removeAll {$0.id==id}
                if result.clips[index].videoEffects?.isEmpty == true {result.clips[index].videoEffects=nil}
            case .text:result.clips[index].texts?.removeAll {$0.id==id}
            case .image:result.clips[index].images?.removeAll {$0.id==id}
            case .speed:if result.clips[index].speed?.id==id {result.clips[index].speed=nil}
            case .color: break
            case .crop:if result.clips[index].crop?.id==id {result.clips[index].crop=nil}
            case .mirror:if result.clips[index].mirror?.id==id {result.clips[index].mirror=nil}
            case .pauses:if result.clips[index].pauses?.id==id {result.clips[index].pauses=nil}
            case .stabilize:if (result.clips[index].stabilization?.id ?? result.clips[index].id)==id {result.clips[index].stabilization=nil}
            case .subtitles,.addVideo,.addAudio,.censorAudio,.transition,.enhanceAudio,.volume,.placement:break
            }
        }
        return result.normalizedTools()
    }
    func normalizedTools() -> EditState {
        var result = self
        for index in result.timeline.video.indices {
            if result.timeline.video[index].content.effectWindows != nil || result.timeline.video[index].content.framingVariants != nil {
                result.timeline.video[index].content.normalizeEffectWindows()
            }
            let clip = result.timeline.video[index].content
            if var pauses = clip.pauses {
                pauses.cuts = pauses.cuts.filter { $0.start < clip.end && $0.end > clip.start }
                pauses.candidates = pauses.candidates?.filter { $0.raw.start < clip.end && $0.raw.end > clip.start }
                if let analyzed = pauses.analyzed {
                    let a = max(clip.start, analyzed.start), b = min(clip.end, analyzed.end)
                    pauses.analyzed = b > a ? SourceInterval(start: a, end: b) : nil
                }
                result.timeline.video[index].content.pauses = pauses
            }
        }
        for i in result.timeline.video.indices where result.timeline.video[i].spanningEffects != nil {
            let clip = result.timeline.video[i].content
            var ids = Set((clip.videoEffects ?? []).map(\.id))
            ids.formUnion((clip.texts ?? []).map(\.id)); ids.formUnion((clip.images ?? []).map(\.id))
            ids.formUnion(clip.visibleGrades.map { $0.grade.id })
            ids.formUnion([clip.crop?.id, clip.mirror?.id, clip.stabilization.map { $0.id ?? clip.id }].compactMap { $0 })
            ids.formUnion((clip.framingVariants ?? []).map(\.id))
            let live = result.timeline.video[i].spanningEffects!.intersection(ids)
            result.timeline.video[i].spanningEffects = live.isEmpty ? nil : live
        }
        for i in result.timeline.audio.indices where result.timeline.audio[i].spanningEffects != nil {
            let item = result.timeline.audio[i]
            let ids = Set(item.enhancements.map(\.id) + item.censors.map(\.id))
            let live = item.spanningEffects!.intersection(ids)
            result.timeline.audio[i].spanningEffects = live.isEmpty ? nil : live
        }
        result.timeline.pruneRelations()
        return result
    }
    var toolRegions: [ToolRegion] { toolRegions(in: layout) }

    func toolRegions(in layout: TimelineLayout) -> [ToolRegion] {
        var result: [ToolRegion] = []
        let cues = timeline.subtitleCues
        if let settings = timeline.subtitles, let first = cues.first, let end = cues.map(\.end).max() {
            result.append(ToolRegion(tool: .subtitles, effectID: settings.id, clipID: first.audioID, range: first.start...end, label: "Subtitles"))
        }
        for placement in layout.placements {
            let clip = placement.clip
            let first = result.count
            let cursor = placement.start
            let range = placement.range
            func visible(_ active: SourceInterval?) -> ClosedRange<Double>? {
                guard let active else { return range }
                let a = cursor + clip.gradeOffset(at: active.start), b = cursor + clip.gradeOffset(at: active.end)
                return b > a ? a...b : nil
            }
            if let mirror = clip.mirror, let range = visible(mirror.activeRange) { result.append(ToolRegion(tool: .mirror, effectID: mirror.id, clipID: clip.id, range: range, label: mirror.horizontal && mirror.vertical ? "Flip H + V" : mirror.horizontal ? "Flip horizontal" : "Flip vertical")) }
            for image in clip.images ?? [] where image.start < clip.end && image.end > clip.start {
                let a = cursor + clip.timelineTime(forSource: max(clip.start, image.start))
                let b = cursor + clip.timelineTime(forSource: min(clip.end, image.end))
                if b > a { result.append(ToolRegion(tool: .image, effectID: image.id, clipID: clip.id, range: a...b, label: "Image")) }
            }
            for effect in clip.videoEffects ?? [] where effect.start < clip.end && effect.end > clip.start {
                let a = cursor + clip.timelineTime(forSource: max(clip.start, effect.start))
                let b = cursor + clip.timelineTime(forSource: min(clip.end, effect.end))
                if b > a { result.append(ToolRegion(tool: .videoEffects, effectID: effect.id, clipID: clip.id, range: a...b, label: effect.kind.descriptor.displayName)) }
            }
            if let crop = clip.crop, let range = visible(crop.activeRange) { result.append(ToolRegion(tool: .crop, effectID: crop.id, clipID: clip.id, range: range, label: abs(crop.rotation) > 0.00001 ? "Crop · \(crop.rotation.formatted(.number.precision(.fractionLength(0...1))))°" : crop.zoom == 1 ? "Fill" : "\(crop.zoom.formatted(.number.precision(.fractionLength(1))))×")) }
            if let speed = clip.speed { result.append(ToolRegion(tool: .speed, effectID: speed.id, clipID: clip.id, range: range, label: "\(speed.rate.formatted(.number.precision(.fractionLength(0...2))))×")) }
            for region in clip.visibleGrades {
                let a = cursor + clip.gradeOffset(at: region.start), b = cursor + clip.gradeOffset(at: region.end)
                if b > a { result.append(ToolRegion(tool: .color, effectID: region.grade.id, clipID: clip.id, range: a...b, label: region.grade.title)) }
            }
            if let stabilization = clip.stabilization, stabilization.level != .off, let range = visible(stabilization.activeRange) { result.append(ToolRegion(tool: .stabilize, effectID: stabilization.id ?? clip.id, clipID: clip.id, range: range, label: "Stabilize")) }
            if let pauses = clip.pauses { result.append(ToolRegion(tool: .pauses, effectID: pauses.id, clipID: clip.id, range: range, label: "Pauses")) }
            for text in clip.texts ?? [] where text.start < clip.end && text.end > clip.start {
                let a = cursor + clip.timelineTime(forSource: max(clip.start, text.start))
                let b = cursor + clip.timelineTime(forSource: min(clip.end, text.end))
                if b > a { result.append(ToolRegion(tool: .text, effectID: text.id, clipID: clip.id, range: a...b, label: text.displayText)) }
            }
            if let variants = clip.framingVariants {
                for variant in variants {
                    if let active = variant.activeRange.flatMap(visible) ?? (variant.activeRange == nil ? range : nil) {
                        result.append(ToolRegion(tool: variant.tool, effectID: variant.id, clipID: clip.id, range: active, label: variant.label))
                    }
                }
            }
            if let windows = clip.effectWindows {
                let recipes = Array(result[first...])
                result.removeSubrange(first...)
                for recipe in recipes {
                    guard let windows = windows[recipe.effectID] else { result.append(recipe); continue }
                    for window in windows {
                        guard let span = visible(window), let part = EditInterval(span).intersection(EditInterval(recipe.range)) else { continue }
                        result.append(ToolRegion(tool: recipe.tool, effectID: recipe.effectID, clipID: clip.id, range: part.seconds, label: recipe.label))
                    }
                }
            }
        }
        for audio in timeline.audio {
            for region in audio.censors {
                result.append(ToolRegion(tool: .censorAudio, effectID: region.id, clipID: audio.id, range: (audio.start + region.interval.start).seconds...(audio.start + region.interval.end).seconds, label: "Censor audio"))
            }
            for region in audio.enhancements {
                result.append(ToolRegion(tool: .enhanceAudio, effectID: region.id, clipID: audio.id,
                    range: (audio.start.seconds + region.interval.start.seconds)...(audio.start.seconds + region.interval.end.seconds), label: "Enhance audio"))
            }
            let levels = [audio.muted ? "Muted" : audio.volumeDB == 0 ? nil : String(format: "%+.1f dB", audio.volumeDB),
                          audio.fadeIn == nil ? nil : "Fade in", audio.fadeOut == nil ? nil : "Fade out"].compactMap { $0 }
            if !levels.isEmpty {
                result.append(ToolRegion(tool: .volume, effectID: audio.id, clipID: audio.id, range: audio.interval.seconds, label: levels.joined(separator: " · ")))
            }
        }
        // A straight-cut sequence cannot have a Placement. Avoid compiling every
        // audio and video boundary simply to discover that there are none.
        let placementPlans = timeline.hasOverlappingPictures ? timeline.compile() : []
        for plan in placementPlans where plan.video.count > 1 {
            // A plain transition is edited through its own control. Do not
            // present its render overlap as an extra, unconfigured Placement.
            if plan.placementID == nil, plan.video.count == 2,
               timeline.transitions.contains(where: { relation in
                   plan.transitionIDs.contains(relation.id)
                       && Set([relation.outgoing, relation.incoming].compactMap { $0 }) == Set(plan.video)
               }) { continue }
            let id = plan.placementID ?? plan.video[0]
            result.append(ToolRegion(tool: .placement, effectID: id, clipID: plan.video[0], range: plan.interval.seconds, label: plan.placementID == nil ? "Placement · default" : "Placement"))
        }
        for join in layout.joins {
            guard let transition = join.transition else { continue }
            result.append(ToolRegion(tool: .transition, effectID: transition.id,
                                     clipID: join.outgoingID ?? join.incomingID ?? clips[0].id, range: join.range, label: transition.style.title))
        }
        return result
    }
}
/// The handles use project time. Rendering recipes are projected into source time
/// only on the members of the application and its continuation along the same row.
struct EffectRangeEdit {
    let region: ToolRegion
    let original: ClosedRange<Double>
    var timing: EditorRangeTiming
    let originalPlayhead: Double
    var lastEdge: EditorRangeTiming.Edge?
    private let members: [UUID: Set<EditInterval>]
    private let scoped: ScopedEffectOperation?
    let eligible: Set<UUID>
    var hasPicture: Bool { !region.tool.isAudioRange }

    init?(_ region: ToolRegion, in edit: EditState, playhead: Double) {
        guard region.tool.hasEditableRange else { return nil }
        let all = edit.toolRegions.filter { $0.tool == region.tool }
        let event = edit.applicationRegions(for: region, matching: all.filter { $0.effectID == region.effectID })
        let members = Dictionary(grouping: event, by: \.clipID).mapValues { Set($0.map { EditInterval($0.range) }) }
        guard let a = event.map({ EditTime($0.range.lowerBound) }).min(),
              let b = event.map({ EditTime($0.range.upperBound) }).max(), b - a >= EditTime(TimelineEditing.frame) else { return nil }
        if region.tool == .videoEffects {
            guard let effect = edit.timeline.video.first(where: { $0.id == region.clipID })?.content.videoEffects?.first(where: { $0.id == region.effectID }),
                  ![.freezeFrame, .stepPrinting, .undercranking].contains(effect.kind) else { return nil }
        }
        let lanes = timelineLanes(edit.timeline).filter { $0.audio == region.tool.isAudioRange }
        let rows = Set(lanes.filter { members[$0.id] != nil }.map(\.row))
        let chain = lanes.filter { rows.contains($0.row) }
        guard let first = chain.map(\.contentInterval.start).min(), let last = chain.map(\.contentInterval.end).max() else { return nil }
        let eligible = Set(chain.map(\.id))
        var left = first, right = last
        func protect(_ interval: EditInterval) {
            if interval.end <= a { left = max(left, interval.end) }
            if interval.start >= b { right = min(right, interval.start) }
        }
        let exclusiveSlot = [.crop, .mirror, .stabilize].contains(region.tool)
        let laneIntervals = Dictionary(uniqueKeysWithValues: chain.map { ($0.id, $0.contentInterval) })
        for other in all {
            guard let item = laneIntervals[other.clipID] else { continue }
            let interval = EditInterval(other.range)
            if other.effectID == region.effectID, members[other.clipID]?.contains(interval) == true { continue }
            // Crop, mirror and stabilization each occupy one recipe slot per clip.
            // LUTs and sound have interval slots. Independent text and looks can overlap.
            if exclusiveSlot || (other.effectID == region.effectID && !region.tool.isAudioRange) { protect(item) }
            else if region.tool.isAudioRange || region.tool == .color { protect(interval) }
        }
        if [.text, .image, .videoEffects].contains(region.tool) {
            for item in edit.timeline.video where eligible.contains(item.id) && item.content.frozenFrame != nil {
                if members[item.id] != nil { return nil }
                protect(item.interval)
            }
        }
        let operation = ScopedEffectOperation(region, in: edit, selection: nil, all: all)
        scoped = operation?.needsProjection(in: edit) == true ? operation : nil
        self.region = region; self.members = members; self.eligible = eligible
        original = EditInterval(a, b).seconds
        timing = EditorRangeTiming(range: original, bounds: EditInterval(left, right).seconds)
        originalPlayhead = playhead
    }

    private func participates(_ id: UUID, interval: EditInterval, range: EditInterval) -> Bool {
        if members[id] != nil { return true }
        guard eligible.contains(id), let added = interval.intersection(range) else { return false }
        let old = EditInterval(original)
        return added.start < old.start || added.end > old.end
    }

    func applying(to edit: EditState) -> EditState {
        let range = EditInterval(timing.range)
        guard range != EditInterval(original) else { return edit }
        if let scoped {
            let candidate = applyingRecipe(to: scoped.inspectorState(edit), range: range)
            return scoped.reshaped(in: edit, using: candidate, to: range, eligible: eligible)
        }
        return applyingRecipe(to: edit, range: range)
    }

    private func applyingRecipe(to edit: EditState, range: EditInterval) -> EditState {
        var result = edit
        if region.tool.isAudioRange {
            applyAudio(to: &result.timeline, range: range)
        } else {
            guard let owner = edit.timeline.video.first(where: { $0.id == region.clipID }) else { return edit }
            for i in result.timeline.video.indices {
                let item = edit.timeline.video[i]
                guard participates(item.id, interval: item.interval, range: range) else { continue }
                let part = item.interval.intersection(range)
                let member = members[item.id] != nil
                let recipe = member ? item : owner
                var clip = item.content
                let source = part.map { SourceInterval(start: clip.gradeTime(at: ($0.start - item.start).seconds),
                                                       end: clip.gradeTime(at: ($0.end - item.start).seconds)) }
                let window = part == item.interval ? nil : source
                func retimed(_ animation: EffectAnimation?) -> EffectAnimation? {
                    guard var animation else { return nil }
                    animation.duration = range.duration.seconds
                    return animation.anchored(to: clip, offset: (item.start - range.start).seconds)
                }
                let id = region.effectID
                switch region.tool {
                case .text:
                    guard var value = recipe.content.texts?.first(where: { $0.id == id }) else { continue }
                    value.playbackClock = nil
                    if let source { value.start = source.start; value.end = source.end }
                    replace(&clip.texts, id: id, with: part == nil ? nil : value)
                case .image:
                    guard var value = recipe.content.images?.first(where: { $0.id == id }) else { continue }
                    value.motion = retimed(value.motion)
                    if let source { value.start = source.start; value.end = source.end }
                    replace(&clip.images, id: id, with: part == nil ? nil : value)
                case .crop:
                    var value = recipe.content.crop
                    let motion = retimed(value?.motion)
                    value?.motion = motion; value?.activeRange = window
                    clip.crop = part == nil ? nil : value
                case .mirror:
                    clip.mirror = part == nil ? nil : recipe.content.mirror
                    clip.mirror?.activeRange = window
                case .stabilize:
                    var value = recipe.content.stabilization
                    if !member { value?.referenceStart = clip.start; value?.referenceEnd = clip.end }
                    value?.id = id; value?.activeRange = window
                    clip.stabilization = part == nil ? nil : value
                case .color:
                    guard var value = recipe.content.visibleGrades.first(where: { $0.grade.id == id })?.grade else { continue }
                    if member, let old = clip.visibleGrades.first(where: { $0.grade.id == id }) {
                        clip.replaceGrade(in: old.start...old.end, with: nil, removingOnly: id)
                    }
                    if let source {
                        value.motion = retimed(value.motion)
                        clip.replaceGrade(in: source.start...source.end, with: value)
                    }
                case .videoEffects:
                    guard var value = recipe.content.videoEffects?.first(where: { $0.id == id }) else { continue }
                    if let part, let source {
                        if !member {
                            // A captured mask, palette sequence or face track belongs to its source.
                            value.analysisFile = nil; value.analysisDataFile = nil; value.capturedEffectID = nil
                            for j in value.parameters.indices where !value.parameters[j].keyframes.isEmpty {
                                let boundary = part.start < EditTime(original.lowerBound) ? value.start : value.end
                                value.parameters[j].value = value.parameters[j].value(at: boundary)
                                value.parameters[j].keyframes = []
                            }
                            value.phaseOffset = nil; value.releaseTime = nil
                        }
                        value.trimSourceRange(source.start...source.end)
                        if value.kind == .negativeStrobe {
                            value.phaseOffset = (part.start - range.start).seconds
                            let runs = item.mapping.sliced(EditInterval(part.start - item.start, part.end - item.start)).runs
                            var points: [StrobeTimePoint] = [], elapsed = 0.0
                            for run in runs where !run.isHold {
                                if points.last?.source != run.sourceStart { points.append(.init(source: run.sourceStart, elapsed: elapsed)) }
                                elapsed += run.duration.seconds
                                points.append(.init(source: run.sourceEnd, elapsed: elapsed))
                            }
                            value.strobeTimeMap = points.count >= 2 ? points : nil
                        }
                        value.motion = retimed(value.motion)
                    }
                    replace(&clip.videoEffects, id: id, with: part == nil ? nil : value)
                default: continue
                }
                result.timeline.video[i].content = clip
                if part != nil && (members.count > 1 || !member || range.start < owner.start || range.end > owner.end) {
                    result.timeline.video[i].spanningEffects = (item.spanningEffects ?? []).union([id])
                }
            }
        }
        return result
    }

    private func replace<T: Identifiable>(_ list: inout [T]?, id: UUID, with value: T?) where T.ID == UUID {
        var values = list ?? []
        if let index = values.firstIndex(where: { $0.id == id }) {
            if let value { values[index] = value } else { values.remove(at: index) }
        } else if let value { values.append(value) }
        list = values.isEmpty ? nil : values
    }

    private func applyAudio(to timeline: inout TrackTimeline, range: EditInterval) {
        let id = region.effectID
        guard let owner = timeline.audio.first(where: { $0.id == region.clipID }) else { return }
        let first = EditTime(region.range.lowerBound) - owner.start
        let chain = owner.enhancements.first { $0.id == id && $0.interval.start == first }?.effects
        let beep = owner.censors.first { $0.id == id && $0.interval.start == first }?.settings
        for i in timeline.audio.indices {
            let item = timeline.audio[i]
            guard participates(item.id, interval: item.interval, range: range) else { continue }
            func belongs(_ recipeID: UUID, _ local: EditInterval) -> Bool {
                recipeID == id && members[item.id]?.contains(EditInterval(item.start + local.start, item.start + local.end)) == true
            }
            let local = item.interval.intersection(range).map { EditInterval($0.start - item.start, $0.end - item.start) }
            func available(excluding occupied: [EditInterval]) -> [EditInterval] {
                guard let local else { return [] }
                var free: [EditInterval] = [], cursor = local.start
                for other in occupied.sorted(by: { $0.start < $1.start }) {
                    guard let overlap = local.intersection(other) else { continue }
                    if cursor < overlap.start { free.append(EditInterval(cursor, overlap.start)) }
                    cursor = max(cursor, overlap.end)
                }
                if cursor < local.end { free.append(EditInterval(cursor, local.end)) }
                return free
            }
            if let chain, region.tool == .enhanceAudio {
                var kept = item.enhancements.filter { !belongs($0.id, $0.interval) }
                kept += available(excluding: kept.map(\.interval)).map { AudioEnhancementRegion(id: id, interval: $0, effects: chain) }
                timeline.audio[i].enhancements = kept.sorted { $0.interval.start < $1.interval.start }
            } else if let beep, region.tool == .censorAudio {
                var kept = item.censors.filter { !belongs($0.id, $0.interval) }
                let envelope = EditInterval(range.start - item.start, range.end - item.start)
                kept += available(excluding: kept.map(\.interval)).map {
                    AudioCensorRegion(id: id, interval: $0, phaseOrigin: envelope.start, settings: beep, envelopeInterval: envelope)
                }
                timeline.audio[i].censors = kept.sorted { $0.interval.start < $1.interval.start }
            }
            if local != nil && (members.count > 1 || members[item.id] == nil || range.start < owner.start || range.end > owner.end) {
                timeline.audio[i].spanningEffects = (item.spanningEffects ?? []).union([id])
            }
        }
    }
}

struct ToolRequest: Identifiable {
    let id = UUID()
    let tool: VideoTool
    let range: ClosedRange<Double>
    let scopeTitle: String
    var effectID: UUID?
    var clipIDs: Set<UUID>?
    var boundaryIndex: Int?
    var scopedEffect: ScopedEffectOperation?
    var targets: TimelineSelection?
    // Keep absolute project time: rebasing previews changes animated effects,
    // transitions and overlapping tracks. Only playback/scrubbing are bounded.
    func videoPreviewRange(in state: EditState, ids: Set<UUID>, inspecting: UUID? = nil) -> ClosedRange<Double> {
        let items = state.timeline.video.filter { ids.contains($0.id) }
        var ranges = items.map { $0.interval.seconds }
        var followsRetime = false
        if tool == .videoEffects, let id = inspecting ?? effectID {
            let affected = items.compactMap { item -> ClosedRange<Double>? in
                let clip = item.content
                guard let effect = clip.videoEffects?.first(where: { $0.id == id }),
                      effect.start < clip.end, effect.end > clip.start else { return nil }
                let first = item.start.seconds + clip.timelineTime(forSource: max(clip.start, effect.start))
                let end = item.start.seconds + clip.timelineTime(forSource: min(clip.end, effect.end))
                guard first < end else { return nil }
                // Inserting a hold or retiming a split selection changes its project times.
                if effect.kind.descriptor.family == .time { followsRetime = true }
                return first...end
            }
            if !affected.isEmpty { ranges = affected }
        }
        let limits = followsRetime ? 0...state.duration : range.clamped(to: 0...state.duration)
        let lower = min(limits.upperBound, max(limits.lowerBound, ranges.map(\.lowerBound).min() ?? limits.lowerBound))
        let upper = min(limits.upperBound, ranges.map(\.upperBound).max() ?? limits.upperBound)
        return lower...max(lower, upper)
    }
    func previewState(_ draft: EditState, in original: EditState) -> EditState {
        scopedEffect?.applying(draft, to: original) ?? draft
    }
    func videoScope(in state: EditState) -> (EditState, Set<UUID>) {
        if let targets {
            let scoped = state.timeline.scoped(targets)
            let requested = scoped.timeline.remapping(targets, from: state.timeline).video
            return (EditState(timeline: scoped.timeline, outputSize: state.outputSize), scoped.selection.video.intersection(requested))
        }
        return clipIDs.map { (state, $0) } ?? TimelineEditing.scoped(state, range: range)
    }
}

/// Like the visual fragments, a clock can span a straight cut or overlap. A real
/// gap or a separately changed motion starts a new run of that animation.
struct TitleMotionRanges {
    private struct Key: Hashable { var id: UUID; var motion: TitleMotion }
    private var intervals: [Key:[ClosedRange<Double>]] = [:]
    var isEmpty: Bool { intervals.isEmpty }
    init() {}
    init(_ edit: EditState) {
        guard edit.clips.contains(where: { ($0.texts ?? []).contains { $0.motion?.active == true } }) else { return }
        for placement in edit.layout.placements {
            let clip = placement.clip
            for title in clip.texts ?? [] where title.end > clip.start && title.start < clip.end {
                guard let motion = title.motion, motion.active else { continue }
                let a = placement.start + clip.timelineTime(forSource: max(clip.start,title.start))
                let b = placement.start + clip.timelineTime(forSource: min(clip.end,title.end))
                if let clock = title.playbackClock {
                    let origin = placement.start - clock.elapsed(at: clip.gradeTime(at: 0))
                    intervals[Key(id:title.id,motion:motion),default:[]].append(origin...(origin + clock.duration))
                } else if b > a { intervals[Key(id:title.id,motion:motion),default:[]].append(a...b) }
            }
        }
        for (key, parts) in intervals {
            var runs: [ClosedRange<Double>] = []
            for part in parts.sorted(by: { $0.lowerBound < $1.lowerBound }) {
                if let previous = runs.last, part.lowerBound <= previous.upperBound + 1/Double(EditTime.scale) {
                    runs[runs.count-1] = previous.lowerBound...max(previous.upperBound,part.upperBound)
                } else { runs.append(part) }
            }
            intervals[key] = runs
        }
    }
    func range(for text: TextOverlay, at time: Double) -> ClosedRange<Double>? {
        guard let motion=text.motion, motion.active else { return nil }
        return intervals[Key(id:text.id,motion:motion)]?.first { time >= $0.lowerBound-0.00001 && time <= $0.upperBound+0.00001 }
    }
}
