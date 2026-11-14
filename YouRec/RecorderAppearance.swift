import SwiftUI

enum YouRecStyle {
    static let accent = Color("AccentColor")
}

struct RecorderCloseToolbar: ToolbarContent {
    let identifier: String
    let action: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Group {
                if #available(iOS 26, *) {
                    Button(role: .close, action: action)
                } else {
                    Button("Close", systemImage: "xmark", action: action).labelStyle(.iconOnly)
                }
            }
            .buttonStyle(.automatic).tint(Color.primary)
            .accessibilityIdentifier(identifier)
        }
    }
}

extension View {
    /// Use Apple's glass renderer without changing custom control sizes.
    @ViewBuilder
    func recorderGlass<S: Shape, F: ShapeStyle>(in shape: S, tint: Color? = nil,
                                               interactive: Bool = false, fallback: F) -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            background(fallback, in: shape)
        }
    }

    @ViewBuilder
    func recorderButtonStyle(prominent: Bool = false) -> some View {
        if #available(iOS 26, *) {
            if prominent { buttonStyle(.glassProminent) }
            else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) }
            else { buttonStyle(.bordered) }
        }
    }

    /// Content uses a standard material so glass controls can sit above it.
    func recorderPanel(cornerRadius: CGFloat = 26) -> some View {
        background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

struct RecorderGlassContainer<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: 0) { content }
        } else {
            content
        }
    }
}
