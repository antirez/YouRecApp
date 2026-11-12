import Foundation

enum EffectEndpoint: String, CaseIterable {
    case a = "A"
    case b = "B"
}

enum EffectCurve: String, Codable, CaseIterable, Sendable {
    case linear, easeIn, easeOut, smooth, riseAndHold, riseHoldReturn
    var title: String {
        switch self {
        case .linear: "Linear"
        case .easeIn: "Ease in"
        case .easeOut: "Ease out"
        case .smooth: "Ease in & out"
        case .riseAndHold: "Rise & hold"
        case .riseHoldReturn: "Rise, hold & return"
        }
    }
    var hasRise: Bool { self == .riseAndHold || self == .riseHoldReturn }
}

enum RampShape: String, CaseIterable, Codable, Sendable {
    case linear, easeIn, easeOut, smooth
    var title: String {
        switch self {
        case .linear: "Linear"
        case .easeIn: "Ease in"
        case .easeOut: "Ease out"
        case .smooth: "Ease in & out"
        }
    }
    func sample(_ x: Double) -> Double {
        switch self {
        case .linear: x
        case .easeIn: x * x * x
        case .easeOut: 1 - pow(1 - x, 3)
        case .smooth: x * x * (3 - 2 * x)
        }
    }
}
struct EffectTiming: Codable, Equatable, Sendable {
    var curve: EffectCurve = .linear
    var rise = 1.0
    var release = 1.0
    var ramp: RampShape = .linear
    func phases(duration: Double) -> (rise: Double, hold: Double, release: Double) {
        let d = max(0, duration)
        let up = min(d, max(0, rise))
        let down = curve == .riseHoldReturn ? min(d - up, max(0, release)) : 0
        return (up, max(0, d - up - down), down)
    }
    func endpoint(_ endpoint: EffectEndpoint, duration: Double, frame: Double) -> Double {
        guard endpoint == .b else { return 0 }
        let last = max(0, duration - frame)
        return curve.hasRise ? min(last, ceil(phases(duration: duration).rise / frame - 0.000001) * frame) : last
    }
    /// Explicitly choosing B follows its peak as the timing changes. Scrubbing
    /// pins a frame even if the user later drags the peak across that frame.
    func previewPosition(_ position: Double, following selected: EffectEndpoint?, duration: Double, frame: Double) -> Double {
        selected.map { endpoint($0, duration: duration, frame: frame) } ?? position
    }
    func fraction(at elapsed: Double, duration: Double, frame: Double) -> Double {
        let last = max(0, duration - frame)
        let x = min(1, max(0, elapsed / max(0.000001, last)))
        switch curve {
        case .linear: return x
        case .easeIn: return x * x * x
        case .easeOut: return 1 - pow(1 - x, 3)
        case .smooth: return x * x * (3 - 2 * x)
        case .riseAndHold, .riseHoldReturn:
            let p = phases(duration: duration)
            let peak = min(last, p.rise)
            if elapsed < peak && peak > 0 { return ramp.sample(max(0, elapsed / peak)) }
            if curve == .riseHoldReturn && p.release > 0 {
                if elapsed >= last && peak < last { return 0 }
                let falling = min(last, max(peak, duration - p.release))
                if elapsed > falling { return 1 - ramp.sample(min(1, (elapsed - falling) / max(0.000001, last - falling))) }
            }
            return 1
        }
    }
}

// Only animatable controls are captured. Media identity, scope, and layer order
// continue to belong to the tool that owns the animation.
struct EffectPose: Codable, Equatable, Sendable {
    var values: [String: Double]
    var look: ColorLook?
    var lut: ImportedLUT?
    subscript(_ key: String) -> Double { values[key] ?? 0 }
}
struct EffectAnimation: Codable, Equatable, Sendable {
    var a: EffectPose
    var b: EffectPose
    var timing = EffectTiming()
    var duration: Double
    var frame = TimelineEditing.frame
    var clock: [StrobeTimePoint] = []
    init(_ pose: EffectPose, duration: Double) {
        a = pose
        b = pose
        self.duration = duration
    }
    subscript(_ endpoint: EffectEndpoint) -> EffectPose {
        get { endpoint == .a ? a : b }
        set { if endpoint == .a { a = newValue } else { b = newValue } }
    }
    func anchored(to clip: TimelineClip, offset: Double) -> Self {
        var result = self
        if let hold = clip.frozenFrame {
            let start = hold.sourceTime + hold.offset
            result.clock = [
                .init(source: start, elapsed: offset), .init(source: start + hold.duration, elapsed: offset + hold.duration),
            ]
            return result
        }
        var points: [StrobeTimePoint] = []
        var time = offset
        for span in clip.effectPlaybackSpans {
            if points.last?.source != span.start { points.append(.init(source: span.start, elapsed: time)) }
            time += span.duration
            points.append(.init(source: span.end, elapsed: time))
        }
        result.clock = points
        return result
    }
    func placed(on clip: TimelineClip, offset: Double, replacing existing: Self?) -> Self {
        if let existing, hasSameSettings(as: existing) {
            return existing
        }
        return anchored(to: clip, offset: offset)
    }
    func hasSameSettings(as other: Self) -> Bool {
        a == other.a && b == other.b && timing == other.timing
    }
    func elapsed(at source: Double) -> Double {
        guard let first = clock.first, let last = clock.last else { return source }
        if source <= first.source { return first.elapsed }
        if source >= last.source { return last.elapsed }
        var lower = 0
        var upper = clock.count - 1
        while upper - lower > 1 {
            let mid = (upper + lower) / 2
            if clock[mid].source < source { lower = mid } else { upper = mid }
        }
        let l = clock[lower]
        let r = clock[upper]
        return l.elapsed + (r.elapsed - l.elapsed) * (source - l.source) / (r.source - l.source)
    }
    func fraction(at source: Double) -> Double {
        timing.fraction(at: elapsed(at: source), duration: duration, frame: frame)
    }
    func valid(for template: EffectPose, accepts: (EffectPose) -> Bool) -> Bool {
        duration.isFinite && duration > 0 && frame.isFinite && frame > 0
            && timing.rise.isFinite && timing.rise >= 0 && timing.release.isFinite && timing.release >= 0
            && clock.allSatisfy { $0.source.isFinite && $0.elapsed.isFinite }
            && zip(clock, clock.dropFirst()).allSatisfy { $0.source < $1.source && $0.elapsed <= $1.elapsed }
            && [a, b].allSatisfy { p in
                p.values.keys == template.values.keys && p.values.values.allSatisfy(\.isFinite)
                    && (p.lut?.valid ?? true) && (template.look != nil || (p.look == nil && p.lut == nil)) && accepts(p)
            }
    }
    func value(_ key: String, fraction f: Double) -> Double {
        let start = a[key]
        let end = b[key]
        if key == "rotation" || key == "hue" {
            return CropSettings.normalizedRotation(start + f * CropSettings.normalizedRotation(end - start))
        }
        if key == "zoom", start > 0, end > 0 { return start * pow(end / start, f) }
        return start + (end - start) * f
    }
    func pose(at source: Double) -> EffectPose {
        let f = fraction(at: source)
        if f <= 0 { return a }
        if f >= 1 { return b }
        return EffectPose(values: Dictionary(uniqueKeysWithValues: a.values.keys.map { ($0, value($0, fraction: f)) }))
    }
}

extension CropSettings {
    var pose: EffectPose { .init(values: ["x": x, "y": y, "zoom": zoom, "rotation": rotation]) }
    func applying(_ p: EffectPose) -> Self {
        var v = self
        v.x = p["x"]
        v.y = p["y"]
        v.zoom = p["zoom"]
        v.rotation = p["rotation"]
        v.motion = nil
        return v
    }
}
extension ImageOverlay {
    var pose: EffectPose { .init(values: ["x": x, "y": y, "width": width, "opacity": opacity]) }
    func applying(_ p: EffectPose) -> Self {
        var v = self
        v.x = p["x"]
        v.y = p["y"]
        v.width = p["width"]
        v.opacity = p["opacity"]
        v.motion = nil
        return v
    }
}
extension VideoPlacement {
    var pose: EffectPose {
        let c = edgeCrop ?? PlacementEdgeCrop()
        return .init(values: [
            "x": x, "y": y, "width": width, "height": height, "fx": framing.x, "fy": framing.y, "zoom": framing.zoom,
            "left": c.left, "right": c.right, "top": c.top, "bottom": c.bottom,
        ])
    }
    func applying(_ p: EffectPose) -> Self {
        var v = self
        v.motion = nil
        v.x = p["x"]
        v.y = p["y"]
        v.width = p["width"]
        v.height = p["height"]
        v.framing = .init(x: p["fx"], y: p["fy"], zoom: p["zoom"])
        var c = PlacementEdgeCrop()
        c.left = p["left"]
        c.right = p["right"]
        c.top = p["top"]
        c.bottom = p["bottom"]
        v.edgeCrop = c.isEmpty ? nil : c
        return v
    }
}
extension ColorSettings {
    var pose: EffectPose {
        .init(
            values: [
                "amount": amount, "exposure": exposure ?? 0, "highlights": highlights ?? 0,
                "localRecovery": localRecovery ?? 0, "warmth": warmth ?? 0, "tint": tint ?? 0,
            ], look: look, lut: imported)
    }
    func applying(_ p: EffectPose) -> Self {
        ColorSettings(
            id: id, look: p.look ?? .natural, amount: p["amount"], imported: p.lut, exposure: p["exposure"],
            highlights: p["highlights"], localRecovery: p["localRecovery"], warmth: p["warmth"], tint: p["tint"])
    }
    var lutAssets: [ImportedLUT] { [imported, motion?.a.lut, motion?.b.lut].compactMap { $0 } }
}
extension VideoEffectSettings {
    func correctionPose(at time: Double) -> EffectPose {
        .init(
            values: Dictionary(
                uniqueKeysWithValues: parameters.compactMap { p in
                    guard case .number(let n) = p.value(at: time) else { return nil }
                    return (p.id, n)
                }))
    }
}
