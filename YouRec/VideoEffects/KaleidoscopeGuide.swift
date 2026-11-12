import SwiftUI

enum KaleidoscopePositionTarget {
    case center, rotation, source, sourceRotation
}

struct KaleidoscopePose: Equatable {
    var center = CGPoint(x: 0.5, y: 0.5)
    var degrees = 0.0
    var sourcePan = CGPoint.zero
    var sourceDegrees = 0.0

    init() {}
    init(_ effect: VideoEffectSettings, at time: Double = 0) {
        center = CGPoint(x: effect.number("centerX", at: time), y: effect.number("centerY", at: time))
        degrees = effect.number("splitAngle", at: time)
        sourcePan = CGPoint(x: effect.number("sourcePanX", at: time), y: effect.number("sourcePanY", at: time))
        sourceDegrees = effect.number("sourceAngle", at: time)
    }
    static func display(_ id: String, _ value: Double) -> String {
        id == "splitAngle" || id == "sourceAngle" ? "\(Int(value.rounded()))°" : "\(Int((value * 100).rounded()))%"
    }
    func parameters(for target: KaleidoscopePositionTarget) -> [String: Double] {
        switch target {
        case .center: return ["centerX": center.x, "centerY": center.y]
        case .rotation: return ["splitAngle": degrees]
        case .source: return ["sourcePanX": sourcePan.x, "sourcePanY": sourcePan.y]
        case .sourceRotation: return ["sourceAngle": sourceDegrees]
        }
    }
    var sourceReadout: String {
        "X \(Self.display("sourcePanX", sourcePan.x)) · Y \(Self.display("sourcePanY", sourcePan.y)) · Rotation \(Self.display("sourceAngle", sourceDegrees))"
    }
    mutating func offsetSource(x: Double, y: Double) {
        sourcePan = CGPoint(x: min(1, max(-1, sourcePan.x + x)), y: min(1, max(-1, sourcePan.y + y)))
    }
}

// Map the guide through the same fitted, rotated and mirrored frame as the image.
// Gestures keep their initial pose so neither dragging a handle nor crossing ±180° jumps.
struct KaleidoscopeGuide: View {
    let pose: KaleidoscopePose
    let divisions: Int
    let projection: (CGSize) -> CGAffineTransform?
    let change: (KaleidoscopePose, KaleidoscopePositionTarget) -> Void
    @State private var turningSource = false

    var body: some View {
        GeometryReader { proxy in
            if let transform = projection(proxy.size), abs(transform.a * transform.d - transform.b * transform.c) > 0.001,
               CGRect(x: 0, y: 0, width: 1, height: 1).applying(transform).intersects(CGRect(origin: .zero, size: proxy.size)) {
                guide(size: proxy.size, transform: transform)
            }
        }
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("kaleidoscope.guide")
    }

    private func nudge(_ dx: Double, _ dy: Double, _ target: KaleidoscopePositionTarget) {
        var next = pose
        if target == .source {
            next.offsetSource(x: dx, y: dy)
        } else {
            next.center = CGPoint(x: min(1, max(0, next.center.x + dx)), y: min(1, max(0, next.center.y + dy)))
        }
        change(next, target)
    }

    private func turnSource(by degrees: Double) {
        var next = pose
        next.sourceDegrees = EffectParameter.wrappedDegrees(pose.sourceDegrees + degrees)
        change(next, .sourceRotation)
    }

    private func guide(size: CGSize, transform: CGAffineTransform) -> some View {
        let pivot = pose.center.applying(transform)
        let width = hypot(transform.a, transform.b), height = hypot(transform.c, transform.d)
        let picture = CGRect(x: 0, y: 0, width: 1, height: 1).applying(transform)
        let visible = picture.intersection(CGRect(origin: .zero, size: size))
        let angle = (pose.degrees - 90) * .pi / 180
        let directions = (0..<divisions).map { sector in
            let ray = angle + Double(sector) * 2 * .pi / Double(divisions)
            return CGVector(dx: transform.a * cos(ray) / width + transform.c * sin(ray) / height,
                            dy: transform.b * cos(ray) / width + transform.d * sin(ray) / height)
        }
        let reach = hypot(picture.width, picture.height)
        let rays = Path { path in
            for ray in directions {
                path.move(to: pivot)
                path.addLine(to: CGPoint(x: pivot.x + reach * ray.dx, y: pivot.y + reach * ray.dy))
            }
        }
        // Keep the control reachable when a boundary points off-screen.
        let length = min(82, max(40, min(picture.width, picture.height) * 0.3))
        let safe = visible.insetBy(dx: min(22, visible.width / 4), dy: min(22, visible.height / 4))
        let candidate = directions.map { CGPoint(x: pivot.x + $0.dx * length, y: pivot.y + $0.dy * length) }
        let handle = candidate.first(where: safe.contains) ?? candidate.map {
            CGPoint(x: min(safe.maxX, max(safe.minX, $0.x)), y: min(safe.maxY, max(safe.minY, $0.y)))
        }.max(by: { hypot($0.x-pivot.x, $0.y-pivot.y) < hypot($1.x-pivot.x, $1.y-pivot.y) })!
        return ZStack(alignment: .topLeading) {
            rays.stroke(.black.opacity(0.55), lineWidth: 2.5)
            rays.stroke(.white.opacity(0.75), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            // A short arc identifies the source wedge as the user turns the split.
            Path { path in
                for i in 0...24 {
                    let ray = angle + Double(i) / 24 * 2 * .pi / Double(divisions)
                    let pt = CGPoint(x: pivot.x + 24 * (transform.a * cos(ray) / width + transform.c * sin(ray) / height),
                                     y: pivot.y + 24 * (transform.b * cos(ray) / width + transform.d * sin(ray) / height))
                    if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                }
            }.stroke(.cyan, lineWidth: 2)
            Color.clear.frame(width: visible.width, height: visible.height)
                .position(x: visible.midX, y: visible.midY)
                .accessibilityElement(children: .ignore).accessibilityLabel("Source image")
                .accessibilityIdentifier("kaleidoscope.source")
                .accessibilityValue(pose.sourceReadout)
                .accessibilityHint("Drag to pan. Twist two fingers to rotate.")
                .accessibilityAction(named: "Decrease source X") { nudge(-0.02, 0, .source) }
                .accessibilityAction(named: "Increase source X") { nudge(0.02, 0, .source) }
                .accessibilityAction(named: "Decrease source Y") { nudge(0, -0.02, .source) }
                .accessibilityAction(named: "Increase source Y") { nudge(0, 0.02, .source) }
                .accessibilityAction(named: "Increase source rotation") { turnSource(by: 1) }
                .accessibilityAction(named: "Decrease source rotation") { turnSource(by: -1) }
                .accessibilityAction(named: "Reset source rotation") { turnSource(by: -pose.sourceDegrees) }
            Circle().fill(.black.opacity(0.65)).overlay(Circle().stroke(.white, lineWidth: 1.5))
                .overlay(Image(systemName: "plus").font(.system(size: 11, weight: .bold)))
                .frame(width: 21, height: 21).frame(width: 44, height: 44).position(pivot)
                .accessibilityElement(children: .ignore).accessibilityLabel("Split center")
                .accessibilityIdentifier("kaleidoscope.center")
                .accessibilityValue("\(KaleidoscopePose.display("centerX", pose.center.x)), \(KaleidoscopePose.display("centerY", pose.center.y))")
                .accessibilityAction(named: "Move left") { nudge(-0.02, 0, .center) }
                .accessibilityAction(named: "Move right") { nudge(0.02, 0, .center) }
                .accessibilityAction(named: "Move up") { nudge(0, -0.02, .center) }
                .accessibilityAction(named: "Move down") { nudge(0, 0.02, .center) }
            Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 14, weight: .semibold))
                .frame(width: 30, height: 30).background(.black.opacity(0.75), in: Circle())
                .overlay(Circle().stroke(.white, lineWidth: 1.5)).frame(width: 44, height: 44).position(handle)
                .accessibilityElement(children: .ignore).accessibilityLabel("Rotate split")
                .accessibilityIdentifier("kaleidoscope.rotation")
                .accessibilityValue(KaleidoscopePose.display("splitAngle", pose.degrees))
                .accessibilityAdjustableAction { direction in
                    var next = pose
                    next.degrees = EffectParameter.wrappedDegrees(pose.degrees + (direction == .increment ? 1 : -1))
                    change(next, .rotation)
                }
            if turningSource {
                Text("Source \(KaleidoscopePose.display("sourceAngle", pose.sourceDegrees))")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 9).padding(.vertical, 5).background(.black.opacity(0.8), in: Capsule())
                    .position(x: visible.midX, y: visible.maxY - 19).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .foregroundStyle(.white)
        .frame(width: size.width, height: size.height)
        .mask(alignment: .topLeading) {
            Rectangle().frame(width: visible.width, height: visible.height).offset(x: visible.minX, y: visible.minY)
        }
        .contentShape(Rectangle())
        .overlay {
            KaleidoscopeGestures(visible: visible, beginDrag: { location in
                let inverse = transform.inverted(), start = location.applying(inverse)
                let centerDistance = hypot(location.x - pivot.x, location.y - pivot.y)
                let handleDistance = hypot(location.x - handle.x, location.y - handle.y)
                let target: KaleidoscopePositionTarget = min(centerDistance, handleDistance) > 22 ? .source :
                    (centerDistance <= handleDistance ? .center : .rotation)
                let mapping = kaleidoscopeDragTransform(start: start, center: pose.center,
                    size: CGSize(width: width, height: height), angle: pose.degrees, divisions: divisions,
                    sourceAngle: pose.sourceDegrees)
                return { current in
                    let point = current.applying(inverse)
                    var next = pose
                    switch target {
                    case .source:
                        let delta = CGPoint(x: (point.x - start.x) * width, y: (point.y - start.y) * height).applying(mapping)
                        next.offsetSource(x: delta.x / width, y: delta.y / height)
                    case .rotation:
                        let c = pose.center, dx = (point.x-c.x)*width, dy = (point.y-c.y)*height
                        guard hypot(dx, dy) > 8 else { return }
                        let initial = atan2((start.y-c.y)*height, (start.x-c.x)*width)
                        next.degrees = EffectParameter.wrappedDegrees(pose.degrees + (atan2(dy, dx) - initial) * 180 / .pi)
                    case .center:
                        next.center = CGPoint(x: min(1, max(0, pose.center.x + point.x - start.x)),
                                              y: min(1, max(0, pose.center.y + point.y - start.y)))
                    case .sourceRotation: return
                    }
                    change(next, target)
                }
            }, beginTwist: { midpoint in
                // A reflected wedge or a mirrored selfie preview reverses a turn.
                // Keep the starting wedge even when the fingers later cross a seam.
                let start = midpoint.applying(transform.inverted())
                let wedge = kaleidoscopeDragTransform(start: start, center: pose.center,
                    size: CGSize(width: width, height: height), angle: pose.degrees, divisions: divisions)
                let determinant = (wedge.a*wedge.d - wedge.b*wedge.c) * (transform.a*transform.d - transform.b*transform.c)
                let sign = determinant < 0 ? -1.0 : 1.0
                return { radians in
                    var next = pose
                    next.sourceDegrees = EffectParameter.wrappedDegrees(pose.sourceDegrees + sign * radians * 180 / .pi)
                    if abs(next.sourceDegrees) <= 2 { next.sourceDegrees = 0 }
                    turningSource = true
                    change(next, .sourceRotation)
                }
            }, endTwist: { turningSource = false }).accessibilityHidden(true)
        }
    }
}

// Capture the starting pose once. A second finger takes over from any single-
// finger handle, and lifting it cannot turn the remaining finger into a drag.
private struct KaleidoscopeGestures: UIViewRepresentable {
    let visible: CGRect
    let beginDrag: (CGPoint) -> (CGPoint) -> Void
    let beginTwist: (CGPoint) -> (CGFloat) -> Void
    let endTwist: () -> Void

    func makeUIView(context: Context) -> Surface {
        let surface = Surface()
        surface.isMultipleTouchEnabled = true
        return surface
    }
    func updateUIView(_ view: Surface, context: Context) { view.input = self }

    final class Surface: UIView {
        var input: KaleidoscopeGestures?
        private var fingers: [UITouch] = []
        private var drag: ((CGPoint) -> Void)?
        private var twist: ((CGFloat) -> Void)?
        private var lastPoint = CGPoint.zero
        private var startAngle = 0.0
        private var lastTurn = 0.0
        private var turning = false

        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { input?.visible.contains(point) == true }
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            fingers.append(contentsOf: touches)
            endInteraction()
            if fingers.count == 1 {
                lastPoint = fingers[0].location(in: self)
                drag = input?.beginDrag(lastPoint)
            } else if fingers.count == 2 {
                let a = fingers[0].location(in: self), b = fingers[1].location(in: self)
                startAngle = atan2(b.y-a.y, b.x-a.x)
                lastTurn = 0
                twist = input?.beginTwist(CGPoint(x: (a.x+b.x)/2, y: (a.y+b.y)/2))
            }
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            if let drag, let finger = fingers.first {
                let point = finger.location(in: self)
                if point != lastPoint { lastPoint = point; drag(point) }
            }
            if let twist {
                let a = fingers[0].location(in: self), b = fingers[1].location(in: self)
                let angle = atan2(b.y-a.y, b.x-a.x) - startAngle
                let turn = atan2(sin(angle), cos(angle))
                // Ignore a pinch or the jitter of a second fingertip landing.
                guard turning || abs(turn) >= 2 * .pi / 180 else { return }
                if hypot(b.x-a.x, b.y-a.y) > 8, abs(turn - lastTurn) > 0.002 {
                    turning = true; lastTurn = turn; twist(turn)
                }
            }
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            touchesMoved(touches, with: event)
            finish(touches)
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }
        private func finish(_ touches: Set<UITouch>) {
            endInteraction()
            fingers.removeAll { touches.contains($0) }
        }
        private func endInteraction() {
            if turning { input?.endTwist() }
            drag = nil; twist = nil; turning = false
        }
    }
}

struct KaleidoscopeControls<Control: View>: View {
    let effect: VideoEffectSettings
    let reset: ([String: Double]) -> Void
    @ViewBuilder let control: (EffectParameter) -> Control

    var body: some View {
        if let divisions = effect.parameters.first(where: { $0.id == "divisions" }) { control(divisions) }
        Text("Drag the picture to pan. Twist with two fingers to rotate the source. Drag the center or round handle to adjust the split.").font(.caption).foregroundStyle(.secondary)
        DisclosureGroup("Fine adjustments") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(["sourceAngle", "sourcePanX", "sourcePanY", "splitAngle", "centerX", "centerY"], id: \.self) { id in
                    if let parameter = effect.parameters.first(where: { $0.id == id }) { control(parameter) }
                }
                HStack {
                    Button("Reset split") { reset(["centerX": 0.5, "centerY": 0.5, "splitAngle": 0]) }
                    Spacer()
                    Button("Center source") { reset(["sourcePanX": 0, "sourcePanY": 0]) }
                }.frame(minHeight: 44)
            }
        }
    }
}
