import SwiftUI

/// The lamp belongs to the recorder UI. Its pixels never enter the capture pipeline.
struct RecorderFrontLight: View {
    let cornerRadius: CGFloat
    let controlsOnLeft: Bool
    let turnOff: () -> Void
    @AppStorage("frontLightWidth") private var width = Width.medium
    @AppStorage("frontLightTone") private var selectedTone = Tone.white.rawValue
    @AppStorage("frontLightCustomColor") private var savedColor: Data?
    @AppStorage("frontLightOpacity") private var opacity = 1.0
    @Environment(\.scenePhase) private var scenePhase
    @State private var settingsOpen = false
    @State private var choosingColor = false

    private enum Width: String, CaseIterable {
        case thin = "Thin", medium = "Medium", wide = "Wide"

        var fraction: CGFloat {
            switch self {
            case .thin: 0.045
            case .medium: 0.085
            case .wide: 0.14
            }
        }
    }

    private enum Tone: String, CaseIterable {
        case white = "White", warm = "Warm", cool = "Cool", custom = "Custom"

        func color(customColor: Color) -> Color {
            switch self {
            case .white: .white
            case .warm: Color(red: 1, green: 0.82, blue: 0.62)
            case .cool: Color(red: 0.72, green: 0.87, blue: 1)
            case .custom: customColor
            }
        }
    }

    private var tone: Tone {
        // The fourth swatch used to be a fixed rose color.
        selectedTone == "Rose" ? .custom : Tone(rawValue: selectedTone) ?? .white
    }

    private var customColor: Color {
        if let savedColor, let resolved = try? JSONDecoder().decode(Color.Resolved.self, from: savedColor) {
            return Color(resolved)
        }
        return Color(red: 1, green: 0.70, blue: 0.79)
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let landscape = size.width > size.height
            let thickness = min(size.width, size.height) * width.fraction
            // Nest the 44-point circular target against the rounded corner with a small margin.
            let hitRadius: CGFloat = 22
            let cornerInset = hitRadius + max(0, cornerRadius - hitRadius) * (1 - 1 / sqrt(2.0)) + 3
            ZStack {
                Path { path in
                    let bounds = CGRect(origin: .zero, size: size)
                    path.addRect(bounds)
                    let opening = RoundedRectangle(cornerRadius: max(min(cornerRadius, 10), cornerRadius - thickness), style: .continuous)
                    path.addPath(opening.path(in: bounds.insetBy(dx: thickness, dy: thickness)))
                }
                .fill(tone.color(customColor: customColor).opacity(opacity), style: FillStyle(eoFill: true))
                .allowsHitTesting(false).accessibilityHidden(true)

                Button { settingsOpen = true } label: {
                    Image(systemName: "lightbulb.fill").font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white).frame(width: 30, height: 30)
                        .background(Color(white: 0.13), in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1))
                        .frame(width: 2 * hitRadius, height: 2 * hitRadius).contentShape(Circle())
                }
                .buttonStyle(.plain).accessibilityLabel("Adjust front light")
                .accessibilityValue("\(width.rawValue), \(tone.rawValue), \(opacity.formatted(.percent))")
                .accessibilityIdentifier("recorder.frontLightBulb")
                .popover(isPresented: $settingsOpen) { settings.presentationCompactAdaptation(.popover) }
                .position(x: landscape && !controlsOnLeft ? cornerInset : size.width - cornerInset,
                          y: size.height - cornerInset)
            }
        }
        .background(FrontLightBrightness(active: scenePhase == .active && opacity > 0).allowsHitTesting(false).accessibilityHidden(true))
    }

    private var settings: some View {
        RecorderGlassContainer {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Front light").font(.headline)
                    Spacer()
                    Button { settingsOpen = false } label: {
                        Image(systemName: "xmark").frame(width: 44, height: 44)
                            .recorderGlass(in: Circle(), interactive: true, fallback: Color.white.opacity(0.08))
                    }.accessibilityLabel("Close front light controls")
                }
                Text("Border width").font(.subheadline.weight(.medium))
                Picker("Border width", selection: $width) {
                    ForEach(Width.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                Text("Color").font(.subheadline.weight(.medium)).padding(.top, 4)
                HStack(spacing: 4) {
                    ForEach(Tone.allCases, id: \.self) { option in
                        Button {
                            selectedTone = option.rawValue
                            if option == .custom { choosingColor = true }
                        } label: { colorSwatch(option) }
                            .accessibilityLabel(option.rawValue)
                            .accessibilityValue(option == .custom ? UIColor(customColor).accessibilityName : "")
                            .accessibilityHint(option == .custom ? "Opens the color picker" : "")
                            .accessibilityAddTraits(tone == option ? .isSelected : [])
                    }
                }
                HStack {
                    Text("Opacity").font(.subheadline.weight(.medium))
                    Spacer()
                    Text(opacity, format: .percent.precision(.fractionLength(0)))
                        .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
                Slider(value: $opacity, in: 0...1, step: 0.05)
                    .tint(YouRecStyle.accent).accessibilityLabel("Front light opacity")
                    .accessibilityValue(opacity.formatted(.percent))
                    .accessibilityIdentifier("recorder.frontLightOpacity")
                Divider()
                Button(action: turnOff) {
                    Label("Turn off front light", systemImage: "lightbulb.slash")
                        .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
                        .recorderGlass(in: Capsule(), interactive: true, fallback: Color.white.opacity(0.09))
                }
            }
            .buttonStyle(.plain).padding(.horizontal, 16).padding(.bottom, 12)
            .frame(width: 280).foregroundStyle(.white).tint(YouRecStyle.accent).preferredColorScheme(.dark)
            .background {
                if choosingColor {
                    FrontLightColorPicker(color: customColor, select: { color in
                        if let data = try? JSONEncoder().encode(color.resolve(in: EnvironmentValues())) {
                            savedColor = data
                        }
                    }, close: { choosingColor = false })
                    .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
        }
    }

    private func colorSwatch(_ option: Tone) -> some View {
        VStack(spacing: 3) {
            Circle().fill(option.color(customColor: customColor)).frame(width: 28, height: 28)
                .overlay {
                    if option == .custom {
                        Circle().strokeBorder(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center), lineWidth: 3)
                        Image(systemName: tone == .custom ? "checkmark" : "eyedropper")
                            .font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 16, height: 16).background(.black.opacity(0.7), in: Circle())
                    } else if tone == option {
                        Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.black)
                    }
                }
            Text(option.rawValue).font(.caption)
        }.frame(maxWidth: .infinity, minHeight: 48).contentShape(Rectangle())
    }
}

/// Present the system picker directly so its Close button and swipe dismissal both work.
private struct FrontLightColorPicker: UIViewControllerRepresentable {
    let color: Color
    let select: (Color) -> Void
    let close: () -> Void

    func makeUIViewController(context: Context) -> Presenter { Presenter(configuration: self) }
    func updateUIViewController(_ controller: Presenter, context: Context) {}

    final class Presenter: UIViewController, UIColorPickerViewControllerDelegate, UIAdaptivePresentationControllerDelegate {
        private let configuration: FrontLightColorPicker
        private var hasPresented = false

        init(configuration: FrontLightColorPicker) {
            self.configuration = configuration
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { nil }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !hasPresented else { return }
            hasPresented = true
            let picker = UIColorPickerViewController()
            picker.title = "Front light color"
            picker.supportsAlpha = false
            picker.selectedColor = UIColor(configuration.color)
            picker.view.tintColor = UIColor(YouRecStyle.accent)
            picker.delegate = self
            picker.modalPresentationStyle = .pageSheet
            picker.sheetPresentationController?.detents = [.medium(), .large()]
            picker.presentationController?.delegate = self
            present(picker, animated: true)
        }

        func colorPickerViewController(_ controller: UIColorPickerViewController, didSelect color: UIColor, continuously: Bool) {
            configuration.select(Color(uiColor: color))
        }
        func colorPickerViewControllerDidFinish(_ controller: UIColorPickerViewController) { configuration.close() }
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { configuration.close() }
    }
}

/// Scope the brightness change to the actual recorder window and its active lifetime.
private struct FrontLightBrightness: UIViewRepresentable {
    let active: Bool

    final class Lamp: UIView {
        var active = false
        private var screen: UIScreen?
        private var original: CGFloat = 0

        override func didMoveToWindow() {
            super.didMoveToWindow()
            updateBrightness()
        }

        func updateBrightness() {
            let target = active ? window?.windowScene?.screen : nil
            guard target !== screen else { return }
            if let screen, screen.brightness >= 0.99 { screen.brightness = original }
            screen = target
            if let target {
                original = target.brightness
                target.brightness = 1
            }
        }
    }

    func makeUIView(context: Context) -> Lamp { Lamp() }
    func updateUIView(_ view: Lamp, context: Context) {
        view.active = active
        view.updateBrightness()
    }
    static func dismantleUIView(_ view: Lamp, coordinator: ()) {
        view.active = false
        view.updateBrightness()
    }
}
