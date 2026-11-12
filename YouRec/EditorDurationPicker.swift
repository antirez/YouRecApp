import SwiftUI

/// Editor time presets share the same touch targets and wrap in reading order.
struct EditorDurationPicker<Details: View>: View {
    let title: String
    let seconds: Double
    let maximum: Double
    let width: CGFloat
    let choices: [Double]
    let identifier: String
    let presetPrefix: String
    var onToggle: () -> Void = {}
    let select: (Double) -> Void
    @ViewBuilder var details: () -> Details

    @State private var expanded = false
    @ScaledMetric(relativeTo: .body) private var cellWidth = 52.0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                onToggle()
                expanded.toggle()
            } label: {
                HStack {
                    Label(title, systemImage: "clock")
                    Spacer()
                    Text(seconds.formatted(.number.precision(.fractionLength(0...2))) + " s").monospacedDigit()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption)
                }
                .padding(.horizontal, 12).frame(minHeight: 44)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(seconds.formatted(.number.precision(.fractionLength(0...2))) + " s")
            .accessibilityHint(expanded ? "Hide duration choices" : "Show duration choices")
            .accessibilityIdentifier(identifier)

            if expanded {
                let columns = min(5, max(1, Int((width + 6) / (max(44, cellWidth) + 6))))
                ForEach(Array(stride(from: 0, to: choices.count, by: columns)), id: \.self) { first in
                    HStack(spacing: 6) {
                        ForEach(choices[first..<min(first + columns, choices.count)], id: \.self) { value in
                            preset(value)
                        }
                    }
                }
                details()
            }
        }
    }

    private func preset(_ value: Double) -> some View {
        let selected = EditTime(seconds) == EditTime(value)
        let key = value == value.rounded() ? String(Int(value)) : String(value)
        return Button { select(value) } label: {
            Text(value.formatted() + " s").font(.subheadline.weight(.semibold)).monospacedDigit()
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(selected ? Color.accentColor.opacity(0.20) : .white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                .overlay { if selected { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor) } }
        }
        .buttonStyle(.plain)
        .disabled(!EditorDurationPresets.fits(value, within: maximum))
        .accessibilityLabel(value.formatted() + (value == 1 ? " second" : " seconds"))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(presetPrefix + "." + key)
    }
}
