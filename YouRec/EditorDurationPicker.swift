import SwiftUI
import AVFoundation

/// Presets set a length once. The user's last manual edit stays Custom even
/// when the resulting length happens to equal a preset.
struct EditorDurationPicker<Details: View>: View {
    let title: String
    let seconds: Double
    let maximum: Double
    let width: CGFloat
    let choices: [Double]
    let identifier: String
    let presetPrefix: String
    @Binding var custom: Bool
    var onToggle: () -> Void = {}
    var onCustom: () -> Void = {}
    var showsDisclosure = true
    let select: (Double) -> Void
    @ViewBuilder var details: () -> Details

    @State private var expanded = false
    @ScaledMetric(relativeTo: .body) private var cellWidth = 63.0

    private var isCustom: Bool { custom || !choices.contains { EditTime($0) == EditTime(seconds) } }
    private var length: String { seconds.formatted(.number.precision(.fractionLength(0...2))) + " s" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsDisclosure { Button {
                onToggle()
                expanded.toggle()
            } label: {
                HStack {
                    Label(title, systemImage: "clock")
                    Spacer()
                    Text(isCustom ? "Custom · " + length : length).monospacedDigit()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption)
                }
                .padding(.horizontal, 12).frame(minHeight: 44)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(isCustom ? length + ", Custom" : length)
            .accessibilityHint(expanded ? "Hide duration choices" : "Show duration choices")
            .accessibilityIdentifier(identifier)
            }

            if expanded || !showsDisclosure {
                let count = min(5, max(1, Int((width + 6) / (cellWidth + 6))))
                Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                    ForEach(0..<(choices.count / count + 1), id: \.self) { row in
                        GridRow {
                            ForEach(0..<count, id: \.self) { column in
                                let index = row * count + column
                                if index < choices.count {
                                    preset(choices[index])
                                } else if index == choices.count {
                                    chip("Custom", selected: isCustom) { custom = true; onCustom() }
                                        .accessibilityHint("Adjust the timing manually")
                                        .accessibilityIdentifier(presetPrefix + ".custom")
                                } else {
                                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]).accessibilityHidden(true)
                                }
                            }
                        }
                    }
                }
                details()
            }
        }
    }

    private func preset(_ value: Double) -> some View {
        let key = value == value.rounded() ? String(Int(value)) : String(value)
        return chip(value.formatted() + " s", selected: !isCustom && EditTime(seconds) == EditTime(value)) {
            custom = false
            select(value)
        }
        .disabled(!EditorDurationPresets.fits(value, within: maximum))
        .accessibilityLabel(value.formatted() + (value == 1 ? " second" : " seconds"))
        .accessibilityIdentifier(presetPrefix + "." + key)
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(.semibold)).monospacedDigit()
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(selected ? Color.accentColor.opacity(0.20) : .white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                .overlay { if selected { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 2) } }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct DurationScrollProxyKey: EnvironmentKey {
    static let defaultValue: ScrollViewProxy? = nil
}

private extension EnvironmentValues {
    var durationScrollProxy: ScrollViewProxy? {
        get { self[DurationScrollProxyKey.self] }
        set { self[DurationScrollProxyKey.self] = newValue }
    }
}

struct DurationInspectorScroll<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView { content().environment(\.durationScrollProxy, proxy) }
        }
    }
}

struct EditorRangeDuration: View {
    let timing: EditorRangeTiming
    let width: CGFloat
    let name: String
    let identifier: String
    var onToggle: () -> Void = {}
    var showsDisclosure = true
    let change: (EditorRangeTiming.Edge, Double, Bool) -> Void
    @State private var custom = false
    @Environment(\.durationScrollProxy) private var scroll
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        EditorDurationPicker(title: "Duration", seconds: timing.duration, maximum: timing.available,
                             width: width, choices: EditorDurationPresets.wholeSeconds, identifier: identifier + ".timing",
                             presetPrefix: identifier + ".duration", custom: $custom, onToggle: onToggle,
                             onCustom: { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { scroll?.scrollTo(identifier + ".handles", anchor: .top) } },
                             showsDisclosure: showsDisclosure) { seconds in
            change(.end, timing.range.lowerBound + seconds, false)
        } details: {
            edgeControl(.start, "Start").id(identifier + ".handles")
            edgeControl(.end, "End")
            Button("Extend to end") { custom = true; change(.end, timing.bounds.upperBound, true) }
                .frame(minHeight: 44).accessibilityIdentifier(identifier + ".toEnd")
        }
    }

    private func edgeControl(_ edge: EditorRangeTiming.Edge, _ title: String) -> some View {
        let value = timing.boundary(edge)
        let limits = timing.limits(for: edge)
        let key = identifier + "." + title.lowercased()
        func trim(_ time: Double) {
            custom = true
            change(edge, time, true)
        }
        return VStack(spacing: 0) {
            HStack(spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                Button { trim(value - TimelineEditing.frame) } label: {
                    Image(systemName: "minus").frame(width: 44, height: 44)
                }.disabled(EditTime(value) <= EditTime(limits.lowerBound))
                    .accessibilityLabel(title + " earlier").accessibilityIdentifier(key + ".earlier")
                Text(editorTime(value)).font(.subheadline.monospacedDigit()).fixedSize()
                    .accessibilityIdentifier(key + ".time")
                Button { trim(value + TimelineEditing.frame) } label: {
                    Image(systemName: "plus").frame(width: 44, height: 44)
                }.disabled(EditTime(value) >= EditTime(limits.upperBound))
                    .accessibilityLabel(title + " later").accessibilityIdentifier(key + ".later")
            }.buttonStyle(.plain)
            Slider(value: Binding(get: { timing.fraction(for: edge) }, set: { trim(timing.time(at: $0, edge: edge)) }), in: 0...1)
                .frame(minHeight: 44)
                .disabled(EditTime(limits.lowerBound) == EditTime(limits.upperBound))
                .accessibilityLabel(name + " " + title.lowercased()).accessibilityValue(editorTime(value))
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: trim(value + TimelineEditing.frame)
                    case .decrement: trim(value - TimelineEditing.frame)
                    @unknown default: break
                    }
                }
        }
    }
}

/// Avoid cancelling a decode repeatedly while a finger or mouse is moving.
/// Requests arriving during an exact seek replace the queued target.
@MainActor final class RangeFrameSeeker {
    private var flight: UUID?
    private var pending: CMTime?

    func reset() { flight = nil; pending = nil }

    func seek(_ player: AVPlayer, to time: CMTime) {
        guard let item = player.currentItem else { return }
        if flight != nil { pending = time; return }
        let id = UUID()
        flight = id
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player, weak item] _ in
            Task { @MainActor in
                guard let self, self.flight == id else { return }
                let next = self.pending
                self.reset()
                if let player, player.currentItem === item, let next { self.seek(player, to: next) }
            }
        }
    }
}

/// A trim sheet can reuse the editor's assembled timeline without borrowing
/// its playhead or preparing an audio effect for each new video frame.
@MainActor final class RangeFramePreview: ObservableObject {
    let player = AVPlayer()
    private let seeker = RangeFrameSeeker()

    func show(_ time: Double, from source: AVPlayerItem?) {
        guard let source else { return }
        if player.currentItem == nil {
            let item = AVPlayerItem(asset: source.asset)
            item.videoComposition = source.videoComposition
            item.seekingWaitsForVideoCompositionRendering = true
            player.isMuted = true
            player.replaceCurrentItem(with: item)
        }
        seeker.seek(player, to: CMTime(seconds: time, preferredTimescale: 60000))
    }
}

/// The draft owns its player and instructions. Prepare its media once, including
/// pictures that can become visible when an edge moves beyond its saved range.
@MainActor final class TimelineEffectRangePreview: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var ready = false
    private let seeker = RangeFrameSeeker()
    private var layers: [VideoToolInstruction] = []
    private var base: EditState?
    private var current: EffectRangeEdit?

    func reset() {
        ready = false; seeker.reset(); layers = []; base = nil; current = nil
        player.replaceCurrentItem(with: nil)
    }

    func prepare(_ draft: EffectRangeEdit, project: Project, folder: URL, canvas: CGSize?) async {
        guard draft.hasPicture else { return }
        let edit = project.edit
        base = edit
        var widest = draft
        widest.timing.set(.start, to: widest.timing.bounds.lowerBound)
        widest.timing.set(.end, to: widest.timing.bounds.upperBound)
        var candidate = project
        candidate.history = [widest.applying(to: edit)]; candidate.historyCursor = 0
        let time = min(edit.duration, max(0, draft.originalPlayhead))
        let window = EffectPreviewWindow(time...min(edit.duration, time + TimelineEditing.frame), timeline: edit.timeline)
        do {
            let media = try await VideoEffectPreparation.$inspectionWindow.withValue(window) {
                try await MediaRenderer.timeline(project: candidate, folder: folder, canvasSize: canvas,
                                                 forceCustom: true, includeBackgroundAudio: false, effectPreparation: .cached)
            }
            try Task.checkCancellation()
            var seen = Set<ObjectIdentifier>()
            layers = media.videoComposition.instructions.flatMap(\.toolLayers).filter {
                draft.eligible.contains($0.clip.id) && seen.insert(ObjectIdentifier($0)).inserted
            }
            guard !layers.isEmpty else { return }
            let item = AVPlayerItem(asset: media.composition)
            item.videoComposition = media.videoComposition
            item.seekingWaitsForVideoCompositionRendering = true
            player.isMuted = true
            player.replaceCurrentItem(with: item)
            let latest = current ?? draft
            applyPicture(latest)
            let position = latest.lastEdge.map { latest.timing.previewTime(for: $0) } ?? time
            _ = await player.seek(to: TrackRenderer.time(EditTime(position)), toleranceBefore: .zero, toleranceAfter: .zero)
            try Task.checkCancellation()
            guard player.currentItem === item else { return }
            ready = true
            if let current, let edge = current.lastEdge {
                seeker.seek(player, to: TrackRenderer.time(EditTime(current.timing.previewTime(for: edge))))
            }
        } catch {
            // The main player continues to show the selected frame while loading
            // and if the source media becomes unavailable.
        }
    }

    func update(_ draft: EffectRangeEdit) {
        let changed = current?.timing.range != draft.timing.range
        current = draft
        guard !layers.isEmpty, let edge = draft.lastEdge else { return }
        if changed { applyPicture(draft) }
        if ready { seeker.seek(player, to: TrackRenderer.time(EditTime(draft.timing.previewTime(for: edge)))) }
    }

    private func applyPicture(_ draft: EffectRangeEdit) {
        guard let base else { return }
        let edit = draft.applying(to: base)
        let clips = Dictionary(uniqueKeysWithValues: edit.timeline.video.map { ($0.id, $0.content) })
        let clocks = draft.region.tool == .text ? TitleMotionRanges(edit) : TitleMotionRanges()
        for layer in layers {
            guard let clip = clips[layer.clip.id] else { continue }
            layer.rangePicture = VideoToolInstruction.RangePicture(tool: draft.region.tool, id: draft.region.effectID,
                                                                  clip: clip, clocks: clocks)
        }
    }
}

struct SelectionDurationEditor: View {
    @State var timing: EditorRangeTiming
    let source: AVPlayerItem?
    var showsCancel = false
    let done: (ClosedRange<Double>) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var preview = RangeFramePreview()
    @State private var frameTime: Double?

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width > geometry.size.height
            let panelWidth = wide ? min(400, geometry.size.width * 0.46) : geometry.size.width
            let layout = wide ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                VStack(spacing: 4) {
                    PlayerSurface(player: preview.player, identifier: "selection.rangePreview")
                    Text(editorTime(frameTime ?? timing.range.lowerBound)).font(.caption.monospacedDigit())
                        .accessibilityIdentifier("selection.rangeTime")
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                DurationInspectorScroll {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Duration · " + editorTime(timing.duration)).font(.headline.monospacedDigit())
                        EditorRangeDuration(timing: timing, width: panelWidth - 32, name: "Selection", identifier: "selection", showsDisclosure: false) { edge, time, _ in
                            timing.set(edge, to: time)
                            let frame = timing.previewTime(for: edge)
                            frameTime = frame
                            preview.show(frame, from: source)
                        }
                    }.padding(16)
                }.frame(width: panelWidth).frame(maxHeight: wide ? .infinity : geometry.size.height * 0.54)
                    .background(Color(white: 0.08)).accessibilityIdentifier("selection.rangeControls")
            }
        }.background(Color.black).navigationTitle("Selected range").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showsCancel {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.accessibilityIdentifier("selection.rangeCancel") }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { done(timing.range); dismiss() }.accessibilityIdentifier("selection.rangeDone") }
            }
            .onAppear { preview.show(frameTime ?? timing.range.lowerBound, from: source) }
    }
}
