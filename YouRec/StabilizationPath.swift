import Foundation
import CoreGraphics

enum StabilizationLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case off, light, standard, strong
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var detail: String {
        switch self {
        case .off: return "Keep the original camera movement."
        case .light: return "Soften small shakes. Keep more of the frame."
        case .standard: return "Smooth handheld movement with a balanced crop."
        case .strong: return "Steadier movement with a tighter crop."
        }
    }
    var sigma: Double {
        switch self { case .off: return 0; case .light: return 0.12; case .standard: return 0.28; case .strong: return 0.5 }
    }
    var maximumZoom: Double {
        switch self { case .off: return 1; case .light: return 1.045; case .standard: return 1.10; case .strong: return 1.18 }
    }
}

struct StabilizationSettings: Codable, Equatable, Sendable {
    var level: StabilizationLevel
    var version = 1
    var id: UUID?
    // Preserve the analyzed take range through splits and ripple cuts. Adjacent
    // pieces inherit the same path/crop, with no new analysis or framing jump.
    var referenceStart: Double?
    var referenceEnd: Double?
}

extension TimelineClip {
    var stabilizationStart: Double { min(start, stabilization?.referenceStart ?? start) }
    var stabilizationEnd: Double { max(end, stabilization?.referenceEnd ?? end) }
    func stabilizing(_ level: StabilizationLevel) -> StabilizationSettings {
        StabilizationSettings(level: level, referenceStart: stabilizationStart, referenceEnd: stabilizationEnd)
    }
}

// A similarity about the center of the encoded (unrotated) frame.
struct StabilizationPose: Codable, Sendable {
    var x = 0.0, y = 0.0, angle = 0.0, logScale = 0.0
    static let identity = StabilizationPose()
    var scale: Double { exp(logScale) }
    func applying(_ other: Self) -> Self {
        let a = scale * cos(angle), b = scale * sin(angle)
        return Self(x: a * other.x - b * other.y + x, y: b * other.x + a * other.y + y,
                    angle: angle + other.angle, logScale: logScale + other.logScale)
    }
    var inverse: Self {
        let a = cos(angle) / scale, b = sin(angle) / scale
        return Self(x: -a * x - b * y, y: b * x - a * y, angle: -angle, logScale: -logScale)
    }
    func attenuated(_ amount: Double) -> Self {
        Self(x: x * amount, y: y * amount, angle: angle * amount, logScale: logScale * amount)
    }
    func transform(size: CGSize, zoom: Double = 1) -> CGAffineTransform {
        let a = scale * cos(angle) * zoom, b = scale * sin(angle) * zoom
        let cx = size.width / 2, cy = size.height / 2
        return CGAffineTransform(a: a, b: b, c: -b, d: a, tx: cx - a * cx + b * cy + x * zoom, ty: cy - b * cx - a * cy + y * zoom)
    }
    // Exact corner inclusion for a rotated/scaled rectangle. This is stronger
    // than bounding-box overlap, which can leave black triangular corners.
    func requiredZoom(size: CGSize) -> Double {
        let c = cos(angle), s = sin(angle), hw = size.width / 2, hh = size.height / 2
        let dx = scale * hw - abs(c * x + s * y), dy = scale * hh - abs(-s * x + c * y)
        guard dx > 0, dy > 0 else { return .infinity }
        return max(1, (abs(c) * hw + abs(s) * hh) / dx, (abs(s) * hw + abs(c) * hh) / dy)
    }
    var valid: Bool { [x, y, angle, logScale].allSatisfy(\.isFinite) && abs(logScale) < 8 }
}

struct StabilizationSample: Codable, Sendable {
    var time: Double
    var pose: StabilizationPose
    var segment: Int
}

struct StabilizationAnalysis: Codable, Sendable {
    static let version = "yourec-stabilization-2"
    let width: Int
    let height: Int
    let duration: Double
    let samples: [StabilizationSample]
    let trackedFrames: Int
    var trackingFraction: Double { Double(trackedFrames) / Double(max(1, samples.count - 1)) }
    var valid: Bool {
        width > 0 && height > 0 && duration.isFinite && duration > 0 && !samples.isEmpty &&
        samples.allSatisfy { $0.time.isFinite && $0.time >= 0 && $0.time < duration + 0.001 && $0.pose.valid } &&
        zip(samples, samples.dropFirst()).allSatisfy { $0.time < $1.time && $0.segment <= $1.segment }
    }
}

struct StabilizationPlan: Sendable {
    let size: CGSize
    let samples: [StabilizationSample]
    let zoom: Double
    let strengthLimited: Bool
    let trackingFraction: Double
    var cropPercent: Int { Int(((1 - 1 / zoom) * 100).rounded()) }
    func transform(at time: Double) -> CGAffineTransform {
        guard let first = samples.first else { return .identity }
        if time <= first.time { return first.pose.transform(size: size, zoom: zoom) }
        var low = 0, high = samples.count
        while low < high { let middle = (low + high) / 2; if samples[middle].time <= time + 0.000001 { low = middle + 1 } else { high = middle } }
        let before = samples[max(0, low - 1)]
        // AVFoundation holds the source frame whose PTS precedes this output
        // time. Correct that exact image, not an interpolated nonexistent frame.
        return before.pose.transform(size: size, zoom: zoom)
    }
}

enum StabilizationPath {
    static func make(_ analysis: StabilizationAnalysis, level: StabilizationLevel) throws -> StabilizationPlan {
        let size = CGSize(width: analysis.width, height: analysis.height)
        guard level != .off else {
            return StabilizationPlan(size: size, samples: [], zoom: 1, strengthLimited: false, trackingFraction: analysis.trackingFraction)
        }
        let source = analysis.samples
        var corrections: [StabilizationSample] = []
        corrections.reserveCapacity(source.count)
        // Gaussian local-linear regression preserves intentional constant-speed
        // pans, including the ends of a clip (no clamped endpoint slowdown).
        var left = 0, right = 0
        var segmentStart = 0, segmentEnd = 0
        for i in source.indices {
            if i.isMultiple(of: 128) { try Task.checkCancellation() }
            let current = source[i], radius = level.sigma * 3
            if i == 0 || source[i - 1].segment != current.segment {
                segmentStart = i; segmentEnd = i + 1
                while segmentEnd < source.count && source[segmentEnd].segment == current.segment { segmentEnd += 1 }
            }
            while left < i && (source[left].time < current.time - radius || source[left].segment != current.segment) { left += 1 }
            right = max(i + 1, right)
            while right < source.count && source[right].segment == current.segment && source[right].time <= current.time + radius { right += 1 }
            // A segment change can leave the old right edge behind us, never
            // let a regression borrow the first frame of the next shot.
            var sw = 0.0, st = 0.0, stt = 0.0
            var sums = [Double](repeating: 0, count: 4), timeSums = sums
            for j in left..<right where source[j].segment == current.segment {
                let dt = source[j].time - current.time
                let w = exp(-0.5 * pow(dt / level.sigma, 2))
                sw += w; st += w * dt; stt += w * dt * dt
                // Smooth camera position in the reference/world coordinates,
                // not feature displacement in the zooming image. Otherwise a
                // zoom after a pan magnifies past translation into false drift.
                let p = source[j].pose.inverse, values = [p.x, p.y, p.angle, p.logScale]
                for k in 0..<4 { sums[k] += w * values[k]; timeSums[k] += w * dt * values[k] }
            }
            let determinant = sw * stt - st * st
            let values = (0..<4).map { determinant > 1e-10 ? (sums[$0] * stt - timeSums[$0] * st) / determinant : sums[$0] / max(sw, 1e-10) }
            // Measured scale helps estimate camera motion, but never retime a
            // deliberate recorded zoom. Correct translation and rotation only.
            let smooth = StabilizationPose(x: values[0], y: values[1], angle: values[2], logScale: current.pose.inverse.logScale).inverse
            func fade(_ seconds: Double) -> Double {
                let x = min(1, max(0, seconds / 0.3)); return x * x * (3 - 2 * x)
            }
            var confidence = 1.0
            if segmentStart > 0 { confidence = min(confidence, fade(current.time - source[segmentStart].time)) }
            if segmentEnd < source.count { confidence = min(confidence, fade(source[segmentEnd - 1].time - current.time)) }
            let correction = smooth.applying(current.pose.inverse).attenuated(confidence)
            corrections.append(StabilizationSample(time: current.time, pose: correction, segment: current.segment))
        }
        // One crop for the entire reference range, with a smoothly anticipated
        // reduction around large bumps. One outlier cannot weaken a whole take.
        let pixelMargin = 1 + 3 / Double(min(analysis.width, analysis.height))
        let allowed = corrections.map { sample -> Double in
            if sample.pose.requiredZoom(size: size) * pixelMargin <= level.maximumZoom { return 1 }
            var low = 0.0, high = 1.0
            for _ in 0..<24 { let middle = (low + high) / 2; if sample.pose.attenuated(middle).requiredZoom(size: size) * pixelMargin <= level.maximumZoom { low = middle } else { high = middle } }
            return low
        }
        var strengthLimited = false, zoom = 1.0
        left = 0; right = 0
        for i in corrections.indices {
            try Task.checkCancellation()
            let t = corrections[i].time
            while left < i && corrections[left].time < t - 0.7 { left += 1 }
            right = max(i + 1, right)
            while right < corrections.count && corrections[right].time <= t + 0.7 { right += 1 }
            var strength = allowed[i]
            for j in left..<right where allowed[j] < 1 && corrections[j].segment == corrections[i].segment {
                let d = min(1, abs(t - corrections[j].time) / 0.7)
                strength = min(strength, allowed[j] + (1 - allowed[j]) * d * d * (3 - 2 * d))
            }
            strengthLimited = strengthLimited || strength < 0.97
            corrections[i].pose = corrections[i].pose.attenuated(strength)
            zoom = max(zoom, corrections[i].pose.requiredZoom(size: size))
        }
        // No pointless crop on a static or entirely untrackable clip.
        if zoom > 1.00001 { zoom = min(level.maximumZoom, zoom * pixelMargin) }
        return StabilizationPlan(size: size, samples: corrections, zoom: zoom,
            strengthLimited: strengthLimited, trackingFraction: analysis.trackingFraction)
    }
}
