import SwiftUI
import UniformTypeIdentifiers

private let effectDragType = UTType(exportedAs: "com.antirez.yourec.audio-effect")

private extension EffectKind {
    var stripName: String {
        switch self {
        case .voiceIsolation: return "Denoise"
        case .studioVoice: return "Detail"
        case .studioRestoration: return "Studio"
        case .highPass: return "Low-cut"
        case .equalizer: return "EQ"
        case .gain: return "Gain"
        case .unavailable: return "Unknown"
        }
    }
    var stripColor: Color {
        switch self {
        case .voiceIsolation: return Color(red: 0.18, green: 0.83, blue: 0.69)
        case .studioVoice: return Color(red: 0.98, green: 0.70, blue: 0.29)
        case .studioRestoration: return Color(red: 0.45, green: 0.71, blue: 0.98)
        case .highPass: return Color(red: 0.73, green: 0.53, blue: 0.97)
        case .equalizer: return Color(red: 0.34, green: 0.66, blue: 1)
        case .gain: return Color(red: 1, green: 0.44, blue: 0.50)
        case .unavailable: return .gray
        }
    }
    var primaryLabel: String { isNeural ? "Amount" : self == .highPass ? "Cutoff" : "Gain" }
    var faderLabel: String { self == .gain ? title : isNeural ? "\(title) amount" : "\(title) \(primaryLabel.lowercased())" }
}

private extension AudioEffect {
    var normalizedPrimary: Double {
        if kind.isNeural { return min(1, max(0, amount)) }
        if kind == .highPass { return min(1, max(0, log(max(20, frequency) / 20) / log(25))) }
        return min(1, max(0, (amount + 24) / 48))
    }
    func settingPrimary(_ normalized: Double) -> AudioEffect {
        var value = self
        let n = min(1, max(0, normalized))
        if kind.isNeural { value.amount = (n * 100).rounded() / 100 }
        else if kind == .highPass { value.frequency = (20 * pow(25, n)).rounded() }
        else { value.amount = ((n * 48 - 24) * 10).rounded() / 10 }
        return value
    }
    var frequencyText: String {
        frequency >= 1000 ? frequency.formatted(.number.scale(0.001).precision(.fractionLength(1)).grouping(.never)) + " kHz"
            : frequency.formatted(.number.precision(.fractionLength(0)).grouping(.never)) + " Hz"
    }
    var primaryText: String {
        if kind.isNeural { return amount.formatted(.percent.precision(.fractionLength(0))) }
        if kind == .highPass { return frequencyText }
        return amount.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always()).grouping(.never)) + " dB"
    }
}

/// Selection is local UI state; each finished adjustment/drop commits exactly
/// one change to the existing project history. Effects keep their stable IDs.
struct AudioChainControls: View {
    let effects: [AudioEffect]
    let busy: Bool
    var compact = false
    let change: ([AudioEffect]) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var selectedID: UUID?
    private var selected: AudioEffect? { effects.first { $0.id == selectedID } ?? effects.first }

    var body: some View {
        Group {
            if effects.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "slider.vertical.3").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Build your sound").font(.headline)
                    Text("Add a filter above. Combine noise reduction, speech detail and EQ in any order.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity).padding(.vertical, 30)
            } else if compact {
                HStack(alignment: .top, spacing: 16) {
                    strips.frame(maxWidth: .infinity)
                    // Reserve only the width the settings need; the chain gets
                    // the remaining space. Clip this nested scroller explicitly
                    // so long cards/bounce cannot draw over the listening controls.
                    ScrollView { settings }
                        .frame(width: typeSize.isAccessibilitySize ? 300 : 220, height: 196)
                        .clipped()
                        .accessibilityIdentifier("audio.details")
                }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("\(effects.count) \(effects.count == 1 ? "FILTER" : "FILTERS")").font(.caption.weight(.semibold))
                        Image(systemName: "arrow.right").font(.caption)
                        Spacer()
                        Text("Hold grips to reorder").font(.caption).foregroundStyle(.secondary)
                    }
                    strips
                    settings
                }
            }
        }
        .onAppear { if selectedID == nil { selectedID = effects.first?.id } }
    }
    private var strips: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(Array(effects.enumerated()), id: \.element.id) { index, effect in
                        EffectStrip(effect: effect, index: index, selected: selected?.id == effect.id,
                                    busy: busy, compact: compact, select: { selectedID = effect.id },
                                    change: replace, reorder: { move($0, to: effect.id) })
                            .frame(width: typeSize.isAccessibilitySize ? 118 : compact ? 96 : 82)
                            .id(effect.id)
                    }
                }.padding(3)
            }
            .scrollIndicators(.visible)
            .accessibilityIdentifier("audio.strips")
            .onChange(of: selectedID) { _, id in
                if let id { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id) } }
            }
            .onChange(of: effects.map(\.id)) { old, new in
                if let added = new.first(where: { !old.contains($0) }) { selectedID = added }
                else if !new.contains(selectedID ?? UUID()) { selectedID = new.first }
            }
        }.frame(height: compact ? 196 : 286)
    }
    @ViewBuilder private var settings: some View {
        if let selected, let index = effects.firstIndex(where: { $0.id == selected.id }) {
            SelectedEffectSettings(effect: selected, index: index, count: effects.count, compact: compact,
                                   change: replace, move: { offset in
                var next = effects; next.swapAt(index, index + offset); change(next)
            }, remove: {
                var next = effects; next.remove(at: index)
                selectedID = next.isEmpty ? nil : next[min(index, next.count - 1)].id
                change(next)
            }).id(selected.id).disabled(busy)
        }
    }
    private func replace(_ effect: AudioEffect) {
        guard !busy, let index = effects.firstIndex(where: { $0.id == effect.id }) else { return }
        var next = effects; next[index] = effect; change(next)
    }
    private func move(_ source: UUID, to target: UUID) {
        guard !busy, let from = effects.firstIndex(where: { $0.id == source }),
              let to = effects.firstIndex(where: { $0.id == target }), from != to else { return }
        var next = effects; let effect = next.remove(at: from); next.insert(effect, at: to)
        selectedID = source; change(next)
        UISelectionFeedbackGenerator().selectionChanged()
    }
}

private struct EffectStrip: View {
    let effect: AudioEffect
    let index: Int
    let selected: Bool
    let busy: Bool
    let compact: Bool
    let select: () -> Void
    let change: (AudioEffect) -> Void
    let reorder: (UUID) -> Void
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 6) {
            if compact {
                HStack(spacing: 4) { grip.frame(width: 44); Spacer(minLength: 0); power.frame(width: 44) }
            } else { grip; power }
            FilledEffectFader(effect: effect, selected: selected, busy: busy, select: select, change: change)
                .frame(height: compact ? 140 : 180)
                .overlay { if targeted { RoundedRectangle(cornerRadius: 20).strokeBorder(.white, lineWidth: 3).allowsHitTesting(false) } }
        }
        .onDrop(of: [effectDragType], isTargeted: $targeted) { providers in
            guard !busy, let provider = providers.first else { return false }
            _ = provider.loadDataRepresentation(forTypeIdentifier: effectDragType.identifier) { data, _ in
                guard let data, let value = String(data: data, encoding: .utf8), let id = UUID(uuidString: value) else { return }
                DispatchQueue.main.async { reorder(id) }
            }
            return true
        }
    }
    private var grip: some View {
        HStack {
            if !compact { Text("\(index + 1)").font(.caption.monospacedDigit()) }
            Spacer(minLength: 0)
            Image(systemName: "line.3.horizontal").font(.caption.weight(.semibold))
        }
        .foregroundStyle(.secondary).padding(.horizontal, compact ? 4 : 10).frame(height: 44).contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onDrag {
            let provider = NSItemProvider()
            provider.registerDataRepresentation(forTypeIdentifier: effectDragType.identifier, visibility: .ownProcess) { completion in
                completion(effect.id.uuidString.data(using: .utf8), nil); return nil
            }
            return provider
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Reorder \(effect.kind.title)")
        .accessibilityIdentifier("audio.grip.\(effect.id)")
        .accessibilityValue("Position \(index + 1)")
        .disabled(busy)
    }
    private var power: some View {
        Button {
            select(); var next = effect; next.enabled.toggle(); change(next)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "power")
                if !compact { Text(effect.enabled ? "On" : "Off").font(.caption.weight(.semibold)) }
            }.frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(effect.enabled ? effect.kind.stripColor : .secondary)
                .background(effect.kind.stripColor.opacity(effect.enabled ? 0.15 : 0.04), in: Capsule())
        }.buttonStyle(.plain).disabled(busy)
            .accessibilityLabel("\(effect.kind.title) enabled").accessibilityValue(effect.enabled ? "On" : "Off")
            .accessibilityIdentifier("audio.enabled.\(effect.id)")
    }

}

private struct FilledEffectFader: UIViewRepresentable {
    let effect: AudioEffect
    let selected: Bool
    let busy: Bool
    let select: () -> Void
    let change: (AudioEffect) -> Void
    func makeUIView(context: Context) -> FilledFaderControl { FilledFaderControl() }
    func updateUIView(_ view: FilledFaderControl, context: Context) {
        view.configure(effect: effect, selected: selected, busy: busy, select: select, change: change)
    }
}

/// A direction-aware pan leaves horizontal swipes to the chain scroller.
/// Taps select without changing the value; relative vertical drags avoid jumps.
private final class FilledFaderControl: UIControl, UIGestureRecognizerDelegate {
    private let fill = CALayer(), levelLine = CALayer(), levelRight = CALayer(), zeroLine = CALayer()
    private let name = UILabel(), valueLabel = UILabel(), parameter = UILabel()
    private var effect = AudioEffect.make(.gain)
    private var select: () -> Void = {}
    private var change: (AudioEffect) -> Void = { _ in }
    private var normalized = 0.5
    private var origin = 0.5
    private var dragging = false
    private var snapPoint: Double?
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(adjust(_:)))
    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 20; layer.borderWidth = 1.5; clipsToBounds = true
        layer.addSublayer(fill); layer.addSublayer(zeroLine); layer.addSublayer(levelLine); layer.addSublayer(levelRight)
        for label in [name, valueLabel, parameter] {
            label.textAlignment = .center; label.textColor = .white; label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.7; addSubview(label)
        }
        name.font = .preferredFont(forTextStyle: .subheadline).withTraits(.traitBold)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
        parameter.font = .preferredFont(forTextStyle: .caption2); parameter.textColor = .lightGray
        pan.delegate = self; addGestureRecognizer(pan)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        isAccessibilityElement = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === pan else { return false }
        var ancestor = superview
        while let view = ancestor {
            if let scroll = view as? UIScrollView, other === scroll.panGestureRecognizer { return true }
            ancestor = view.superview
        }
        return false
    }
    func configure(effect: AudioEffect, selected: Bool, busy: Bool, select: @escaping () -> Void, change: @escaping (AudioEffect) -> Void) {
        self.effect = effect; self.select = select; self.change = change
        isEnabled = !busy && effect.supported
        if !dragging { normalized = effect.normalizedPrimary }
        let color = UIColor(effect.kind.stripColor)
        backgroundColor = color.withAlphaComponent(effect.enabled ? 0.1 : 0.035)
        fill.backgroundColor = color.withAlphaComponent(effect.enabled ? 0.48 : 0.10).cgColor
        levelLine.backgroundColor = color.withAlphaComponent(effect.enabled ? 1 : 0.4).cgColor
        levelRight.backgroundColor = levelLine.backgroundColor
        zeroLine.backgroundColor = UIColor.white.withAlphaComponent(0.24).cgColor
        layer.borderColor = (selected ? UIColor.white : color.withAlphaComponent(0.48)).cgColor
        layer.borderWidth = selected ? 2.5 : 1.5
        name.font = .preferredFont(forTextStyle: .subheadline).withTraits(.traitBold)
        parameter.font = .preferredFont(forTextStyle: .caption2)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .headline).pointSize, weight: .semibold)
        parameter.textColor = UIColor.white.withAlphaComponent(0.85)
        parameter.layer.shadowColor = UIColor.black.cgColor; parameter.layer.shadowOpacity = 0.7
        parameter.layer.shadowRadius = 2; parameter.layer.shadowOffset = .zero
        name.text = effect.kind.stripName
        switch effect.kind {
        case .voiceIsolation: parameter.text = effect.model == .deepFilter ? "DFN3" : "RNNoise"
        case .studioVoice: parameter.text = "LavaSR"
        case .studioRestoration: parameter.text = "VoiceFixer"
        case .equalizer: parameter.text = effect.frequencyText
        case .gain: parameter.text = nil
        default: parameter.text = effect.kind.primaryLabel
        }
        accessibilityLabel = effect.kind.faderLabel
        accessibilityIdentifier = "audio.fader.\(effect.id)"
        accessibilityHint = "Tap for settings. Swipe up or down to adjust."
        accessibilityTraits = [.adjustable]
        if selected { accessibilityTraits.insert(.selected) }
        if !isEnabled { accessibilityTraits.insert(.notEnabled) }
        refreshValue()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let compact = bounds.height < 150
        name.frame = CGRect(x: 5, y: compact ? 10 : 16, width: bounds.width - 10, height: 25)
        parameter.frame = CGRect(x: 4, y: compact ? 39 : 48, width: bounds.width - 8, height: 20)
        valueLabel.frame = CGRect(x: 4, y: bounds.height - (compact ? 38 : 44), width: bounds.width - 8, height: 28)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let y = CGFloat(1 - normalized) * bounds.height
        let bipolar = effect.kind == .equalizer || effect.kind == .gain
        fill.frame = CGRect(x: 0, y: bipolar ? min(y, bounds.midY) : y, width: bounds.width,
                            height: bipolar ? abs(bounds.midY - y) : bounds.height - y)
        let intersectsText = textIntersects(y)
        let lineY = max(0, min(bounds.height - 2, y))
        levelLine.frame = CGRect(x: 0, y: lineY, width: intersectsText ? 6 : bounds.width, height: 2)
        levelRight.frame = CGRect(x: bounds.width - 6, y: lineY, width: 6, height: 2)
        levelRight.isHidden = !intersectsText
        zeroLine.isHidden = effect.kind.isNeural || effect.kind == .highPass || textIntersects(bounds.midY)
        zeroLine.frame = CGRect(x: 8, y: bounds.midY, width: bounds.width - 16, height: 1)
        CATransaction.commit()
    }
    private func textIntersects(_ y: CGFloat) -> Bool {
        for label in [name, parameter, valueLabel] where label.text != nil {
            if label.frame.insetBy(dx: 0, dy: -2).contains(CGPoint(x: bounds.midX, y: y)) { return true }
        }
        return false
    }
    private func refreshValue() {
        let edited = effect.settingPrimary(normalized)
        valueLabel.text = edited.primaryText
        accessibilityValue = edited.primaryText + (effect.enabled ? "" : ", bypassed")
        setNeedsLayout()
    }
    @objc private func tapped() { select() }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard isEnabled else { return false }
        if gestureRecognizer === pan { let v = pan.velocity(in: self); return abs(v.y) > abs(v.x) }
        return true
    }
    @objc private func adjust(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began: dragging = true; origin = normalized; snapPoint = nil; select()
        case .changed:
            normalized = dragValue(gesture)
            refreshValue()
        case .ended:
            normalized = dragValue(gesture)
            dragging = false; change(effect.settingPrimary(normalized)); refreshValue()
        case .cancelled, .failed: dragging = false; normalized = effect.normalizedPrimary; refreshValue()
        default: break
        }
    }
    private func dragValue(_ gesture: UIPanGestureRecognizer) -> Double {
        let value = min(1, max(0, origin - gesture.translation(in: self).y / max(1, bounds.height)))
        let center = AudioEffect.make(effect.kind).normalizedPrimary
        let tolerance = effect.kind == .gain || effect.kind == .equalizer ? 0.4 / 48 : 0.01
        let snap: Double? = value == 0 || value == 1 ? value : abs(value - center) <= tolerance ? center : nil
        if snap != snapPoint, snap != nil { UISelectionFeedbackGenerator().selectionChanged() }
        snapPoint = snap
        return snap ?? value
    }
    override func accessibilityActivate() -> Bool { select(); return true }
    private var accessibleStep: Double { effect.kind.isNeural ? 0.01 : effect.kind == .highPass ? log(2) / (12 * log(25)) : 0.5 / 48 }
    override func accessibilityIncrement() { accessibilityAdjust(accessibleStep) }
    override func accessibilityDecrement() { accessibilityAdjust(-accessibleStep) }
    private func accessibilityAdjust(_ delta: Double) {
        guard isEnabled else { return }; select()
        normalized = min(1, max(0, normalized + delta)); change(effect.settingPrimary(normalized)); refreshValue()
    }
}

private extension UIFont {
    func withTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        UIFont(descriptor: fontDescriptor.withSymbolicTraits(traits) ?? fontDescriptor, size: pointSize)
    }
}

private struct SelectedEffectSettings: View {
    let effect: AudioEffect
    let index: Int
    let count: Int
    let compact: Bool
    let change: (AudioEffect) -> Void
    let move: (Int) -> Void
    let remove: () -> Void
    @State private var frequency = 1800.0
    private var frequencyDisplay: String { var value = effect; value.frequency = frequency; return value.frequencyText }
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            HStack {
                Circle().fill(effect.kind.stripColor).frame(width: 8, height: 8)
                Text(effect.kind.title).font(.headline)
                Spacer(minLength: 0)
                if !effect.enabled { Text("Bypassed").font(.caption).foregroundStyle(.secondary) }
            }.accessibilityIdentifier("audio.selectedEffect")
            if compact { actions }
            if !effect.supported {
                Text("This filter is unavailable in this app version. Bypass or remove it to process audio; its saved settings are retained.").font(.caption).foregroundStyle(.orange)
            } else if effect.kind == .voiceIsolation {
                HStack {
                    Text("Model").foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        Button("RNNoise") { var value = effect; value.model = .rnnoise; change(value) }
                        Button("DeepFilterNet3") { var value = effect; value.model = .deepFilter; change(value) }
                    } label: { Label(effect.model == .deepFilter ? "DeepFilterNet3" : "RNNoise", systemImage: "chevron.down").frame(minHeight: 44) }
                        .accessibilityLabel("Noise reduction model").accessibilityValue(effect.model == .deepFilter ? "DeepFilterNet3" : "RNNoise")
                }
                if !compact { Text("Reduces background noise. Adjust Amount in the column above.").font(.caption).foregroundStyle(.secondary) }
            } else if effect.kind == .studioRestoration {
                Text("VoiceFixer restores the full speech signal, reducing recording defects such as noise, room echo and muffling. Amount blends the restored voice with the recording.").font(.caption).foregroundStyle(.secondary)
                Text("Neural resynthesis can alter vocal character. For speech, not music; compare with Bypass. This is not an emulation of a specific microphone.").font(.caption).foregroundStyle(.secondary)
                Link("VoiceFixer · Haohe Liu et al. · CC BY 4.0", destination: URL(string: "https://zenodo.org/records/5600188")!).font(.caption)
            } else if effect.kind == .equalizer {
                HStack { Text("Frequency"); Spacer(); Text(frequencyDisplay).monospacedDigit() }.font(.subheadline)
                Slider(value: Binding(get: { log(max(80, frequency) / 80) / log(150) },
                                      set: { frequency = (80 * pow(150, $0)).rounded() }), in: 0...1) { editing in
                    if !editing { var value = effect; value.frequency = frequency; change(value) }
                }.tint(effect.kind.stripColor).accessibilityLabel("EQ frequency").accessibilityValue(frequencyDisplay)
                if !compact { Text("Boost or cut this frequency with the EQ column. Add another EQ stage for another band.").font(.caption).foregroundStyle(.secondary) }
            } else if !compact {
                Text(effect.kind == .studioVoice ? "LavaSR restores high-frequency speech detail. It does not simulate a studio microphone or remove room echo. Start low: clean recordings may need none." : effect.kind == .highPass ? "Removes low rumble below the cutoff. Raise the column to raise the cutoff frequency." : "Adjusts the output level in decibels. The center line is 0 dB.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !compact { actions }
        }
        .padding(compact ? 10 : 14).background(effect.kind.stripColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
        .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(effect.kind.stripColor.opacity(0.22)).allowsHitTesting(false) }
        .onAppear { frequency = effect.frequency }
        .onChange(of: effect.frequency) { _, value in frequency = value }
    }
    private var actions: some View {
        HStack(spacing: 4) {
            Button { move(-1) } label: { Image(systemName: "arrow.left").frame(width: 44, height: 44) }
                .disabled(index == 0).accessibilityLabel("Move effect earlier")
            Button { move(1) } label: { Image(systemName: "arrow.right").frame(width: 44, height: 44) }
                .disabled(index + 1 == count).accessibilityLabel("Move effect later")
            Spacer()
            Button { var value = AudioEffect.make(effect.kind); value.id = effect.id; value.enabled = effect.enabled; value.model = effect.model; change(value) }
                label: { Text("Reset").foregroundStyle(.white.opacity(0.85)).frame(minWidth: 44, minHeight: 44) }
                .disabled(!effect.supported).accessibilityLabel("Reset selected effect")
            Button(role: .destructive, action: remove) { Image(systemName: "trash").frame(width: 44, height: 44) }.accessibilityLabel("Remove effect")
        }
    }
}
