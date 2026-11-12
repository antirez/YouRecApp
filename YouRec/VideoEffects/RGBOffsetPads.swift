import SwiftUI

struct RGBOffsetPads: View {
    let effect: VideoEffectSettings
    let time: Double
    let projection: CGAffineTransform?
    let change: ([String: Double]) -> Void

    // Offsets use equal picture-pixel distances on both axes. The live selfie
    // preview can mirror or rotate those axes independently of the recording.
    private var orientation: CGAffineTransform {
        guard let t = projection else { return .identity }
        let x = hypot(t.a, t.b), y = hypot(t.c, t.d)
        guard x > 0, y > 0 else { return .identity }
        return CGAffineTransform(a: t.a / x, b: t.b / x, c: t.c / y, d: t.d / y, tx: 0, ty: 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(RGBChannel.allCases, id: \.self) { channel in
                    pad(channel).frame(maxWidth: .infinity)
                }
            }
            Text("Drag a cross to shift its color. Double-tap to center it.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func pad(_ channel: RGBChannel) -> some View {
        let tint: Color = switch channel { case .red: .red; case .green: .green; case .blue: .blue }
        let source = CGPoint(x: effect.number(channel.x, at: time), y: effect.number(channel.y, at: time))
        let displayed = source.applying(orientation)
        let reading = "X \(Int((displayed.x * 100).rounded()))% · Y \(Int((displayed.y * 100).rounded()))%"
        func place(_ point: CGPoint) {
            let radius = max(1, hypot(point.x, point.y))
            let raw = CGPoint(x: point.x / radius, y: point.y / radius).applying(orientation.inverted())
            change([channel.x: max(-1, min(1, raw.x)), channel.y: max(-1, min(1, raw.y))])
        }
        return VStack(spacing: 5) {
            GeometryReader { proxy in
                let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
                let reach = max(1, min(center.x, center.y) - 10)
                ZStack {
                    Circle().fill(tint.opacity(0.12))
                    Circle().strokeBorder(tint.opacity(0.8), lineWidth: 1)
                    Circle().strokeBorder(tint.opacity(0.22)).padding(reach * 0.48)
                    Circle().fill(.white.opacity(0.4)).frame(width: 3, height: 3)
                    Image(systemName: "plus").font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white).shadow(color: .black, radius: 1)
                        .position(x: center.x + displayed.x * reach, y: center.y + displayed.y * reach)
                }
                .contentShape(Circle())
                .gesture(DragGesture(minimumDistance: 1).onChanged { event in
                    place(CGPoint(x: (event.location.x - center.x) / reach, y: (event.location.y - center.y) / reach))
                })
                .simultaneousGesture(TapGesture(count: 2).onEnded { place(.zero) })
            }.aspectRatio(1, contentMode: .fit).frame(maxWidth: 108)
            Text(channel.name).font(.subheadline.weight(.semibold))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("rgbOffset." + channel.rawValue)
        .accessibilityLabel(channel.name + " offset").accessibilityValue(reading)
        .accessibilityAction(named: "Move left") { place(CGPoint(x: displayed.x - 0.03, y: displayed.y)) }
        .accessibilityAction(named: "Move right") { place(CGPoint(x: displayed.x + 0.03, y: displayed.y)) }
        .accessibilityAction(named: "Move up") { place(CGPoint(x: displayed.x, y: displayed.y - 0.03)) }
        .accessibilityAction(named: "Move down") { place(CGPoint(x: displayed.x, y: displayed.y + 0.03)) }
        .accessibilityAction(named: "Center") { place(.zero) }
    }
}
