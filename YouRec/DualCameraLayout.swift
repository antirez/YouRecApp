import Foundation
import CoreGraphics

struct DualCameraLayout: Codable, Equatable {
    enum Mode: String, CaseIterable, Codable, Identifiable {
        case floating, sideBySide, topAndBottom, diagonal
        var id: Self { self }
        var title: String { switch self { case .floating: "Floating"; case .sideBySide: "Side by side"; case .topAndBottom: "Top and bottom"; case .diagonal: "Diagonal" } }
        var icon: String { switch self { case .floating: "pip"; case .sideBySide: "rectangle.split.2x1"; case .topAndBottom: "rectangle.split.1x2"; case .diagonal: "square.split.diagonal.2x2" } }
    }
    struct Framing: Codable, Equatable {
        var x = 0.5, y = 0.5, zoom = 1.0
        mutating func constrain() { x = Self.clamp(x, 0...1); y = Self.clamp(y, 0...1); zoom = Self.clamp(zoom, 1...4) }
        private static func clamp(_ value: Double, _ bounds: ClosedRange<Double>) -> Double {
            value.isFinite ? min(bounds.upperBound, max(bounds.lowerBound, value)) : bounds.lowerBound
        }
    }
    var mode = Mode.floating
    var swapped = false
    // Optional so existing recorder preferences retain their framing.
    var diagonalFlipped: Bool? = nil
    var roundInset: Bool? = nil
    var isRound: Bool { roundInset == true }
    var diagonalFallsRight: Bool { diagonalFlipped == true }
    var diagonalTitle: String { diagonalFallsRight ? "Top left to bottom right" : "Top right to bottom left" }
    mutating func flipDiagonal() { diagonalFlipped = !diagonalFallsRight }
    var verticalDivider = 0.5, horizontalDivider = 0.5
    var insetX = 0.77, insetY = 0.28, insetSize = 0.32
    // Area-equivalent size plus aspect keeps old square preferences readable.
    var insetAspect: Double? = nil
    enum InsetResizeAxis { case width, height, proportional }
    static func insetResizeAxis(separation: CGSize) -> InsetResizeAxis {
        let x = abs(separation.width), y = abs(separation.height)
        guard max(x, y) > 1 else { return .proportional }
        if x >= y * 2.4 { return .width }
        if y >= x * 2.4 { return .height }
        return .proportional
    }
    private var insetDimensions: CGSize {
        if isRound { return CGSize(width: insetSize, height: insetSize) }
        let aspect = insetAspect.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 1
        return CGSize(width: insetSize * sqrt(aspect), height: insetSize / sqrt(aspect))
    }
    mutating func resizeInset(scale: Double, axis: InsetResizeAxis, canvas: CGSize) {
        guard scale.isFinite, scale > 0, canvas.width.isFinite, canvas.height.isFinite, canvas.width > 0, canvas.height > 0 else { return }
        let center = regions(in: canvas)[1]
        let unit = min(canvas.width, canvas.height)
        // Begin with the visible size: rotating a wide inset can make it fit
        // smaller, and the next pinch must respond without a hidden overshoot.
        var d = CGSize(width: center.width / unit, height: center.height / unit)
        if isRound {
            insetSize = min(1, max(0.18, d.width*scale))
            insetX = center.midX/canvas.width; insetY = center.midY/canvas.height
            constrain(); return
        }
        let maximum = CGSize(width: canvas.width / unit, height: canvas.height / unit)
        if axis == .proportional {
            let factor = min(min(maximum.width / d.width, maximum.height / d.height), max(0.18 / min(d.width, d.height), scale))
            d.width *= factor; d.height *= factor
        } else if axis == .width { d.width = min(maximum.width, max(0.18, d.width * scale)) }
        else { d.height = min(maximum.height, max(0.18, d.height * scale)) }
        insetSize = sqrt(d.width * d.height); insetAspect = d.width / d.height
        insetX = center.midX / canvas.width; insetY = center.midY / canvas.height
        constrain()
    }
    var first = Framing(), second = Framing()
    mutating func constrain() {
        func clamp(_ v: Double, _ range: ClosedRange<Double>) -> Double { v.isFinite ? min(range.upperBound, max(range.lowerBound, v)) : range.lowerBound }
        verticalDivider = clamp(verticalDivider, 0.15...0.85); horizontalDivider = clamp(horizontalDivider, 0.15...0.85)
        insetSize = insetSize.isFinite ? max(0.18, insetSize) : 0.32
        if isRound { insetSize = min(1, insetSize) }
        if !isRound {
            let d = insetDimensions
            let w = d.width.isFinite ? max(0.18, d.width) : 0.32
            let h = d.height.isFinite ? max(0.18, d.height) : 0.32
            insetSize = sqrt(w)*sqrt(h); insetAspect = w/h
        }
        insetX = clamp(insetX, 0...1); insetY = clamp(insetY, 0...1)
        first.constrain(); second.constrain()
    }
    /// Top-left coordinates, in output pixels or view points. Shared by UI/rendering.
    func regions(in size: CGSize) -> [CGRect] {
        let w = size.width, h = size.height
        guard w.isFinite, h.isFinite, w > 0, h > 0 else { return [.zero, .zero] }
        switch mode {
        case .diagonal:
            return Array(repeating: CGRect(origin: .zero, size: size), count: 2)
        case .sideBySide:
            let x = w * verticalDivider
            return [CGRect(x: 0, y: 0, width: x, height: h), CGRect(x: x, y: 0, width: w-x, height: h)]
        case .topAndBottom:
            let y = h * horizontalDivider
            return [CGRect(x: 0, y: 0, width: w, height: y), CGRect(x: 0, y: y, width: w, height: h-y)]
        case .floating:
            let d = insetDimensions, unit = min(w, h)
            // Both the preview and saved movie use this canvas-aware fit.
            // Preserve shape on orientation changes; never extend off-screen.
            let fit = min(1, min((w/unit)/d.width, (h/unit)/d.height))
            let width = min(w, unit*(d.width*fit)), height = min(h, unit*(d.height*fit))
            let x = min(w-width, max(0, insetX*w-width/2)), y = min(h-height, max(0, insetY*h-height/2))
            return [CGRect(origin: .zero, size: size), CGRect(x: x, y: y, width: width, height: height)]
        }
    }
    /// Signed perpendicular distance in pixels, positive in the lower triangle.
    func diagonalDistance(_ point: CGPoint, in size: CGSize) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return 0 }
        let value = diagonalFallsRight ? point.y/size.height-point.x/size.width : point.x/size.width+point.y/size.height-1
        return value/hypot(1/size.width, 1/size.height)
    }
    func contains(_ point: CGPoint, slot: Int, in size: CGSize) -> Bool {
        let region = regions(in: size)[slot]
        guard region.contains(point) else { return false }
        if mode == .diagonal { return slot == 0 ? diagonalDistance(point, in: size) <= 0 : diagonalDistance(point, in: size) > 0 }
        if mode == .floating && slot == 1 && isRound { return hypot(point.x-region.midX, point.y-region.midY) <= region.width/2 }
        return true
    }
    /// Aspect fill with bounded panning; never stretches a face or reveals a hole.
    static func placement(source: CGSize, region: CGRect, framing: Framing) -> CGRect {
        guard source.width > 0, source.height > 0 else { return region }
        let scale = max(region.width/source.width, region.height/source.height) * framing.zoom
        let w = source.width*scale, h = source.height*scale
        return CGRect(x: region.minX-(w-region.width)*framing.x, y: region.minY-(h-region.height)*framing.y, width: w, height: h)
    }
}

/// Face coordinates are normalized, top-down, before preview mirroring.
/// Selection stays with one nearby face across detections, including brief losses.
struct DualFaceTarget {
    private(set) var box: CGRect?
    private(set) var seenAt = -Double.infinity
    mutating func observe(_ faces: [CGRect], at time: Double) {
        // Vision can extend a partially visible face beyond the sensor bounds.
        // Keep its visible portion so tracking can bring it back into the crop.
        let bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        let valid = faces.filter { !$0.isNull && $0.width > 0 && $0.height > 0 &&
            [$0.minX, $0.minY, $0.maxX, $0.maxY].allSatisfy(\.isFinite) }
            .map { $0.intersection(bounds) }.filter { !$0.isNull && !$0.isEmpty }
        if let old = box, time-seenAt < 0.8 {
            let nearby = valid.filter { face in
                let distance = hypot(face.midX-old.midX, face.midY-old.midY)
                return distance < max(0.12, min(0.3, max(old.width, old.height))) &&
                    face.width/old.width > 0.45 && face.width/old.width < 2.2
            }
            if let next = nearby.min(by: { hypot($0.midX-old.midX, $0.midY-old.midY) < hypot($1.midX-old.midX, $1.midY-old.midY) }) {
                box = next; seenAt = time
            }
        } else {
            box = valid.max { a, b in
                func score(_ r: CGRect) -> Double { r.width*r.height / (0.25+hypot(r.midX-0.5, r.midY-0.5)) }
                return score(a) < score(b)
            }
            if box != nil { seenAt = time }
        }
    }
    func current(at time: Double) -> CGRect? { time-seenAt < 0.4 ? box : nil }
}

enum DualFaceFraming {
    /// Move only within existing overscan. Never add zoom to create tracking room.
    static func follow(_ face: CGRect?, source: CGSize, region: CGRect,
                       current: DualCameraLayout.Framing, elapsed: Double, target: CGPoint = CGPoint(x: 0.5, y: 0.5)) -> DualCameraLayout.Framing {
        guard let face, elapsed.isFinite, elapsed > 0 else { return current }
        let placed = DualCameraLayout.placement(source: source, region: region, framing: current)
        let dt = min(0.1, elapsed), alpha = 1-exp(-dt/0.22)
        func move(_ value: Double, center: Double, full: Double, visible: Double, target: Double) -> Double {
            let spare = full-visible
            guard spare > 0.5 else { return value }
            let error = center*full-spare*value-visible*target
            let deadZone = visible*0.045
            guard abs(error) > deadZone else { return value }
            let distance = error-copysign(deadZone, error)
            let step = min(visible*dt*1.5, max(-visible*dt*1.5, distance*alpha))
            return min(1, max(0, value+step/spare))
        }
        var result = current
        result.x = move(current.x, center: face.midX, full: placed.width, visible: region.width, target: target.x)
        result.y = move(current.y, center: face.midY, full: placed.height, visible: region.height, target: target.y)
        return result
    }
}

enum DualFramePairing {
    /// 0 pairs; -1 discards the older first sample; +1 discards the older second.
    static func action(first: Double, second: Double) -> Int {
        let difference = first-second
        if abs(difference) <= 1.0/60+0.001 { return 0 }
        return difference < 0 ? -1 : 1
    }
}
