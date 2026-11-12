import AVFoundation
import SwiftUI

struct EffectAnimationControls: View {
    let motion: EffectAnimation?
    let endpoint: EffectEndpoint?
    let duration: Double
    let select: (EffectEndpoint) -> Void
    let remove: () -> Void
    let done: () -> Void
    let update: (EffectTiming) -> Void

    var showsEndpointMenu = true
    var endpointMenu: some View {
        Menu {
            ForEach(EffectEndpoint.allCases, id: \.self) { e in
                Button {
                    select(e)
                } label: {
                    Label(e.rawValue, systemImage: e == endpoint ? "checkmark.diamond.fill" : "diamond")
                }
            }
            if motion != nil {
                Button("Remove animation", role: .destructive, action: remove)
                Button("Done", action: done)
            }
        } label: {
            Label(
                endpoint.map { "Edit " + $0.rawValue } ?? "Animate",
                systemImage: motion == nil ? "diamond" : "diamond.fill"
            )
            .font(.subheadline.weight(.semibold)).padding(.horizontal, 12).frame(minHeight: 44)
            .background(.white.opacity(0.09), in: Capsule())
        }.accessibilityIdentifier("effect.animation")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let motion {
                let curve = Binding(get: { motion.timing.curve }, set: { choice in
                    var timing = motion.timing
                    timing.curve = choice
                    if choice == .riseHoldReturn && timing.rise + timing.release > duration {
                        timing.rise = duration / 2
                        timing.release = duration / 2
                    }
                    update(timing)
                })
                timingMenu("Animation curve", id: "effect.curve", selection: curve, choices: EffectCurve.allCases, title: \.title) {
                    if showsEndpointMenu { endpointMenu } else { Text("Animation curve") }
                }
            } else if showsEndpointMenu {
                endpointMenu
            }
            if let motion, endpoint != nil || motion.timing.curve.hasRise {
                Canvas { ctx, size in
                    var line = Path()
                    for i in 0...100 {
                        let x = CGFloat(i) / 100
                        let f = motion.timing.fraction(at: x * duration, duration: duration, frame: motion.frame)
                        let p = CGPoint(x: x * size.width, y: 2 + (1 - f) * (size.height - 4))
                        if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
                    }
                    ctx.stroke(line, with: .color(.cyan), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                }.frame(height: 23).accessibilityHidden(true)
                if motion.timing.curve.hasRise {
                    let ramp = Binding(get: { motion.timing.ramp }, set: { shape in
                        var timing = motion.timing
                        timing.ramp = shape
                        update(timing)
                    })
                    timingMenu("Ramp shape", id: "effect.ramp", selection: ramp, choices: RampShape.allCases, title: \.title) { Text("Ramp shape") }
                    phase("Rise", rise: true, motion: motion)
                    if motion.timing.curve == .riseHoldReturn { phase("Return", rise: false, motion: motion) }
                    let held = motion.timing.phases(duration: duration).hold
                    Text("Hold B for " + seconds(held)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
    private func timingMenu<Choice: Hashable, Heading: View>(
        _ name: String, id: String, selection: Binding<Choice>, choices: [Choice], title: KeyPath<Choice, String>,
        @ViewBuilder heading: () -> Heading
    ) -> some View {
        let current = selection.wrappedValue[keyPath: title]
        let menu = Menu {
            Picker(name, selection: selection) {
                ForEach(choices, id: \.self) { Text($0[keyPath: title]).tag($0) }
            }
        } label: {
            HStack(spacing: 6) {
                Text(current)
                Image(systemName: "chevron.down").font(.caption.weight(.semibold)).accessibilityHidden(true)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12).frame(minHeight: 44)
            .background(.white.opacity(0.09), in: Capsule()).contentShape(Capsule())
        }
        .menuIndicator(.hidden)
        .accessibilityLabel(name).accessibilityValue(current)
        .accessibilityIdentifier(id)

        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                heading(); Spacer(minLength: 0); menu
            }
            VStack(alignment: .leading, spacing: 4) { heading(); menu }
        }.font(.subheadline)
    }
    private func seconds(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...2))) + " s" }
    private func phase(_ title: String, rise: Bool, motion: EffectAnimation) -> some View {
        let times = motion.timing.phases(duration: duration)
        let value = rise ? times.rise : times.release
        let maximum = max(0, duration - (rise ? times.release : times.rise))
        let step = maximum < 0.25 ? TimelineEditing.frame : 0.1
        let binding = Binding<Double>(
            get: { value },
            set: { number in
                var timing = motion.timing
                let bounded = number >= maximum ? maximum : min(maximum, max(0, (number / step).rounded() * step))
                if rise { timing.rise = bounded } else { timing.release = bounded }
                update(timing)
            })
        return HStack {
            Text(title).frame(minWidth: 45, alignment: .leading)
            Slider(value: binding, in: 0...max(0.001, maximum)).disabled(maximum == 0).accessibilityLabel(title + " time")
            Stepper(value: binding, in: 0...max(0.001, maximum), step: step) { Text(seconds(value)).monospacedDigit() }
                .fixedSize().accessibilityLabel(title + " time in seconds")
        }.font(.caption)
    }
}

/// A periodic playhead sample can skip the last frame, especially at 24 fps.
final class EffectPreviewEndObserver {
    private var token: NSObjectProtocol?
    @MainActor init(player: AVPlayer, finished: @escaping @MainActor () -> Void) {
        token = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) {
            [weak player] note in
            guard let item = note.object as? AVPlayerItem else { return }
            Task { @MainActor in
                guard player?.currentItem === item else { return }
                finished()
            }
        }
    }
    deinit { if let token { NotificationCenter.default.removeObserver(token) } }
}
