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
    private enum CodingKeys: String, CodingKey { case id, x, y, zoom, rotation, motion }
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
        rotation = try fields.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
    }
}

struct MirrorSettings: Codable, Equatable, Sendable {
    var id = UUID()
    var horizontal = false
    var vertical = false
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

/// Overlay trimming uses the editor clock. A source boundary can be between frames.
struct OverlayTiming {
    enum Edge { case start, end }
    let bounds: ClosedRange<Double>
    private(set) var range: ClosedRange<Double>
    var duration: Double { range.upperBound - range.lowerBound }
    var available: Double { bounds.upperBound - range.lowerBound }

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

    func time(at fraction: Double, edge: Edge) -> Double {
        let limits = limits(for: edge)
        if fraction <= 0 { return limits.lowerBound }
        if fraction >= 1 { return limits.upperBound }
        let offset = (limits.upperBound - limits.lowerBound) * fraction
        let frames = (offset / TimelineEditing.frame).rounded()
        return min(limits.upperBound, limits.lowerBound + frames * TimelineEditing.frame)
    }

    mutating func set(_ edge: Edge, to value: Double) {
        guard value.isFinite else { return }
        let limits = limits(for: edge)
        let time = min(limits.upperBound, max(limits.lowerBound, value))
        range = edge == .start ? time...range.upperBound : range.lowerBound...time
    }

}

struct TextOverlay: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var text = "Your text"
    var start = 0.0
    var end = 3.0
    var x = 0.5
    var y = 0.5
    // Font size relative to the shorter canvas dimension; consistent on rotation.
    var size = 0.065
    var style: TextStyle = .bold
    var color: TextColor = .white
    var appearance: TitleDesign?
    var motion: TitleMotion?
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
        if frozenFrame != nil { return [self] }
        return effectPlaybackSpans.map { span in
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
            return piece
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
struct ToolRegion: Identifiable {
    var id: String { "\(tool.rawValue)-\(effectID)-\(clipID)" + (tool == .placement ? "-\(EditTime(range.lowerBound).ticks)-\(EditTime(range.upperBound).ticks)" : "") }
    let tool: VideoTool
    let effectID: UUID
    let clipID: UUID
    let range: ClosedRange<Double>
    let label: String
}
extension EditState {
    /// Effect identity preserves animation across cuts. It is not edit scope:
    /// a badge targets its segment unless the user explicitly selects more.
    func request(for region: ToolRegion, selection: TimelineSelection = TimelineSelection()) -> ToolRequest {
        if region.tool == .subtitles { return ToolRequest(tool: .subtitles, range: 0...duration, scopeTitle: "Project subtitles", effectID: region.effectID) }
        let audio = [.enhanceAudio, .volume, .censorAudio].contains(region.tool)
        let matching = toolRegions.filter { $0.tool == region.tool && $0.effectID == region.effectID }
        let selected = audio ? selection.audio : selection.video
        let scoped = matching.filter { selected.contains($0.clipID) && (selection.range?.intersection(EditInterval($0.range)) != nil || selection.range == nil) }
        // One censor action can silence several simultaneous tracks. Its single
        // badge reopens that event together, but never reaches across a split
        // into the adjacent, non-overlapping section.
        var event = [region]
        if region.tool == .censorAudio {
            // A continuous music bed can bridge two split voice items. Include
            // the whole connected event rather than leaving a hidden old beep
            // on the far side of that split.
            while true {
                let additions = matching.filter { candidate in
                    !event.contains { $0.clipID == candidate.clipID && $0.range == candidate.range }
                    && event.contains { EditInterval($0.range).intersection(EditInterval(candidate.range)) != nil }
                }
                if additions.isEmpty { break }; event.append(contentsOf: additions)
            }
        }
        let regions = scoped.isEmpty ? event : scoped
        let ids = Set(regions.map(\.clipID))
        let bounds = EditInterval((regions.map { $0.range.lowerBound }.min() ?? region.range.lowerBound)...(regions.map { $0.range.upperBound }.max() ?? region.range.upperBound))
        let range = scoped.isEmpty ? bounds : selection.range.flatMap { $0.intersection(bounds) } ?? bounds
        let title = ids.count == 1 ? (audio ? "This audio section" : "This clip") : "Selected · \(ids.count) \(audio ? "audio sections" : "clips")"
        let targets = TimelineSelection(video: audio ? [] : ids, audio: audio ? ids : [], range: audio && [.enhanceAudio, .censorAudio].contains(region.tool) ? range : (scoped.isEmpty ? nil : selection.range))
        return ToolRequest(tool: region.tool, range: range.seconds, scopeTitle: title, effectID: region.effectID,
                           clipIDs: audio ? nil : ids, targets: targets)
    }
    // Badge removal stays on its segment. Only an explicit marked range may
    // split that segment further; unrelated effects and source media stay intact.
    func removingTool(_ request:ToolRequest)->EditState {
        guard let id=request.effectID else {return self}
        var result=self
        if request.tool == .subtitles { result.timeline.removeSubtitles(); return result }
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
            case .color:if result.clips[index].color?.id==id {result.clips[index].color=nil}
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
        for index in result.clips.indices {
            let clip = result.clips[index]
            if var pauses = clip.pauses {
                pauses.cuts = pauses.cuts.filter { $0.start < clip.end && $0.end > clip.start }
                pauses.candidates = pauses.candidates?.filter { $0.raw.start < clip.end && $0.raw.end > clip.start }
                if let analyzed = pauses.analyzed {
                    let a = max(clip.start, analyzed.start), b = min(clip.end, analyzed.end)
                    pauses.analyzed = b > a ? SourceInterval(start: a, end: b) : nil
                }
                result.clips[index].pauses = pauses
            }
        }
        result.timeline.pruneRelations()
        return result
    }
    var toolRegions: [ToolRegion] {
        var result: [ToolRegion] = []
        if let settings = timeline.subtitles, let first = timeline.subtitleCues.first, let end = timeline.subtitleCues.map(\.end).max() {
            result.append(ToolRegion(tool: .subtitles, effectID: settings.id, clipID: first.audioID, range: first.start...end, label: "Subtitles"))
        }
        for placement in layout.placements {
            let clip = placement.clip, cursor = placement.start
            let range = placement.range
            if let mirror = clip.mirror { result.append(ToolRegion(tool: .mirror, effectID: mirror.id, clipID: clip.id, range: range, label: mirror.horizontal && mirror.vertical ? "Flip H + V" : mirror.horizontal ? "Flip horizontal" : "Flip vertical")) }
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
            if let crop = clip.crop { result.append(ToolRegion(tool: .crop, effectID: crop.id, clipID: clip.id, range: range, label: abs(crop.rotation) > 0.00001 ? "Crop · \(crop.rotation.formatted(.number.precision(.fractionLength(0...1))))°" : crop.zoom == 1 ? "Fill" : "\(crop.zoom.formatted(.number.precision(.fractionLength(1))))×")) }
            if let speed = clip.speed { result.append(ToolRegion(tool: .speed, effectID: speed.id, clipID: clip.id, range: range, label: "\(speed.rate.formatted(.number.precision(.fractionLength(0...2))))×")) }
            if let color = clip.color { result.append(ToolRegion(tool: .color, effectID: color.id, clipID: clip.id, range: range, label: color.title)) }
            if let stabilization = clip.stabilization, stabilization.level != .off { result.append(ToolRegion(tool: .stabilize, effectID: stabilization.id ?? clip.id, clipID: clip.id, range: range, label: "Stabilize")) }
            if let pauses = clip.pauses { result.append(ToolRegion(tool: .pauses, effectID: pauses.id, clipID: clip.id, range: range, label: "Pauses")) }
            for text in clip.texts ?? [] where text.start < clip.end && text.end > clip.start {
                let a = cursor + clip.timelineTime(forSource: max(clip.start, text.start))
                let b = cursor + clip.timelineTime(forSource: min(clip.end, text.end))
                if b > a { result.append(ToolRegion(tool: .text, effectID: text.id, clipID: clip.id, range: a...b, label: text.text)) }
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
        for plan in timeline.compile() where plan.video.count > 1 {
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
struct ToolRequest: Identifiable {
    let id = UUID()
    let tool: VideoTool
    let range: ClosedRange<Double>
    let scopeTitle: String
    var effectID: UUID?
    var clipIDs: Set<UUID>?
    var boundaryIndex: Int?
    var targets: TimelineSelection?
    // Keep absolute project time: rebasing previews changes animated effects,
    // transitions and overlapping tracks. Only playback/scrubbing are bounded.
    func videoPreviewRange(in state:EditState, ids:Set<UUID>) -> ClosedRange<Double> {
        var ranges=state.layout.placements.filter {ids.contains($0.clip.id)}.map(\.range)
        if let effectID {
            let regions=state.toolRegions.filter {$0.tool == .videoEffects && $0.effectID==effectID && ids.contains($0.clipID)}
            if !regions.isEmpty {ranges=regions.map(\.range)}
        }
        let lower=max(0,min(state.duration,ranges.map(\.lowerBound).min() ?? range.lowerBound))
        return lower...max(lower,min(state.duration,ranges.map(\.upperBound).max() ?? range.upperBound))
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
                if b > a { intervals[Key(id:title.id,motion:motion),default:[]].append(a...b) }
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
