import SwiftUI
import AVKit
import CoreImage

@MainActor
final class TransitionWorkspace: ObservableObject {
    let project: Project
    let folder: URL
    let boundary: Int
    let player = AVPlayer()
    var maximum: Double { settings.style == .still ? max(60, project.edit.duration, settings.duration) : join.maximum }
    var originalJoin: TransitionJoin { project.edit.layout.joins[boundary] }
    var join: TransitionJoin { state().layout.joins.first { $0.transition?.id == settings.id } ?? originalJoin }
    var audioMaximum: Double { min(60, max(2, project.edit.clips.map(\.duration).max() ?? 2)) }
    var displayedAudioBlend: Double {
        settings.audioBlend ?? (settings.style == .fadeColor && (isOpening || isClosing) ? settings.duration + settings.holdDuration : settings.defaultAudioBlend)
    }
    private var visitedStyles = Set<TransitionStyle>()
    let existing: Bool
    @Published var settings: ClipTransition
    @Published var canvas = CGSize(width: 1920, height: 1080)
    @Published var still: UIImage?
    @Published var busy = true
    @Published var error: String?
    @Published var playing = false
    @Published var position = 0.0
    @Published var previewRange = 0.0...1.0
    private var frames: [CIImage] = []
    private var frameBounds: [CGRect] = []
    private var frameLayers: [(VideoToolInstruction, Double)] = []
    var firstSize: CGSize { isOpening ? canvas : frameBounds.first?.size ?? canvas }
    var secondSize: CGSize { isClosing ? canvas : frameBounds.last?.size ?? canvas }
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var job: Task<Void, Never>?
    private var observer: Any?
    private var status: NSKeyValueObservation?
    private var revision = UUID()
    private var playbackRevision = UUID()
    private var frameTimes: [Double] = []
    private var hasChosenAxis = false
    var canApply: Bool { !busy && error == nil && still != nil && effectiveDuration >= TimelineEditing.frame - 0.000001 }
    var isOpening: Bool { originalJoin.edge == -1 }
    var isClosing: Bool { originalJoin.edge == 1 }
    var title: String { isOpening ? "Start · fade in" : isClosing ? "End · fade out" : "Clip \(boundary) → \(boundary + 1)" }
    var effectiveDuration: Double { join.timing.videoDuration }
    var lengthNote: String {
        let change = state().duration - project.edit.settingTransition(nil, at: boundary).duration
        let length = join.range.upperBound - join.range.lowerBound
        let outcome = abs(change) < 0.00001 ? "Project length unchanged" : "Project \(abs(change).formatted(.number.precision(.fractionLength(2)))) s \(change < 0 ? "shorter" : "longer")"
        return "\(length.formatted(.number.precision(.fractionLength(2)))) s total · " + outcome
    }
    func selectStyle(_ style: TransitionStyle) {
        if !visitedStyles.contains(style) {
            if style == .whip { settings.duration = 8.0 / 30 }
            if style == .still { settings.duration = 1 }
            visitedStyles.insert(style)
        }
        settings.style = style
    }
    init(project: Project, folder: URL, boundary: Int) {
        self.project = project; self.folder = folder; self.boundary = boundary
        let join = project.edit.layout.joins[boundary]
        existing = join.transition != nil
        settings = join.transition ?? ClipTransition(duration: min(0.5, join.maximum))
        visitedStyles.insert(settings.style)
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self, self.playing else { return }
                self.position = time.seconds
                if time.seconds >= self.previewRange.upperBound - TimelineEditing.frame { self.pause(); self.seek(self.previewRange.lowerBound) }
            }
        }
    }
    deinit { job?.cancel(); if let observer { player.removeTimeObserver(observer) } }
    func stop() { job?.cancel(); revision = UUID(); pause(); status = nil }
    func state(removing: Bool = false) -> EditState {
        removing ? project.edit.restoringStraightCut(at: boundary) : project.edit.settingTransition(settings, at: boundary)
    }
    private func previewProject() -> (Project, Int) {
        let ids = [originalJoin.outgoingID, originalJoin.incomingID].compactMap { $0 }
        let clips = ids.compactMap { id -> TimelineClip? in
            guard var clip = project.edit.clips.first(where: { $0.id == id }) else { return nil }
            clip.openingTransition = nil; clip.transition = nil; return clip
        }
        let localBoundary = isOpening ? 0 : 1
        var candidate = project
        var previewSettings = settings
        let factor = join.factor
        if settings.style != .still || settings.customAudio && !isClosing { previewSettings.duration *= factor }
        if settings.style != .fadeColor || isOpening || isClosing || settings.customAudio { previewSettings.hold = settings.hold.map { $0 * factor } }
        previewSettings.audioOffset = settings.audioOffset.map { $0 * factor }
        previewSettings.audioBlend = settings.audioBlend.map { $0 * factor }
        previewSettings.stillDissolve = settings.stillDissolve.map { $0 * factor }
        candidate.history = [EditState(clips: clips, outputSize: canvas).settingTransition(previewSettings, at: localBoundary)]; candidate.historyCursor = 0
        return (candidate, localBoundary)
    }
    func start() {
        job?.cancel(); busy = true; let token = UUID(); revision = token
        job = Task {
            do {
                let originalCanvas = try await MediaRenderer.canvas(project: project, folder: folder)
                try Task.checkCancellation(); guard revision == token else { return }
                // Review at screen resolution; saved framing uses normalized coordinates.
                let scale = min(1, 960 / max(originalCanvas.width, originalCanvas.height))
                canvas = CGSize(width: max(2, (originalCanvas.width * scale / 2).rounded() * 2), height: max(2, (originalCanvas.height * scale / 2).rounded() * 2))
                if !existing && !hasChosenAxis { settings.axis = canvas.height > canvas.width ? .vertical : .horizontal }
                rebuild(delay: false)
            } catch is CancellationError {} catch { self.error = error.localizedDescription; busy = false }
        }
    }
    func changed() { pause(); makeStill(); rebuild() }
    func chooseAxis(_ axis: TransitionAxis) { hasChosenAxis = true; settings.axis = axis }
    func rebuild(delay: Bool = true) {
        job?.cancel(); pause(); busy = true; error = nil
        let token = UUID(); revision = token
        job = Task {
            do {
                if delay { try await Task.sleep(for: .milliseconds(200)) }
                let (candidate, joinIndex) = previewProject()
                let media = try await MediaRenderer.timeline(project: candidate, folder: folder,effectPreparation:.cached)
                try Task.checkCancellation(); guard revision == token else { return }
                let join = candidate.edit.layout.joins[joinIndex]
                previewRange = max(0, join.range.lowerBound - 0.65)...min(candidate.edit.duration, join.range.upperBound + 0.65)
                let samples = candidate.edit.layout.placements.map { max(0, min($0.clip.duration - TimelineEditing.frame, join.origin + join.timing.videoDuration / 2 - $0.start)) }
                if frames.isEmpty || frameTimes != samples {
                    var next: [CIImage] = []
                    var bounds: [CGRect] = []
                    var overlays: [(VideoToolInstruction, Double)] = []
                    for (index, original) in candidate.edit.clips.enumerated() {
                        var clip = original; clip.transition = nil; clip.openingTransition = nil
                        var one = candidate; one.history = [EditState(clips: [clip], outputSize: canvas)]; one.historyCursor = 0
                        let single = try await MediaRenderer.timeline(project: one, folder: folder, forceCustom: true,effectPreparation:.cached)
                        for layer in single.videoComposition.instructions.compactMap({ $0 as? VideoToolInstruction }) { layer.overlaysEnabled = false }
                        let generator = AVAssetImageGenerator(asset: single.composition)
                        generator.videoComposition = single.videoComposition
                        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
                        let offset = samples[index]
                        let image = try await generator.image(at: CMTime(seconds: max(0, min(clip.duration - TimelineEditing.frame, offset)), preferredTimescale: 60000)).image
                        next.append(CIImage(cgImage: image))
                        bounds.append((single.videoComposition.instructions.first as? VideoToolInstruction).map { TransitionRenderer.contentBounds($0) } ?? CGRect(origin: .zero, size: canvas))
                        if let layer = single.videoComposition.instructions.compactMap({ $0 as? VideoToolInstruction }).first(where: { $0.timeRange.start.seconds <= offset && $0.timeRange.end.seconds > offset }) { overlays.append((layer, offset)) }
                    }
                    try Task.checkCancellation(); guard revision == token else { return }
                    frames = next; frameBounds = bounds; frameLayers = overlays; frameTimes = samples
                }
                makeStill()
                if settings.style != .split {
                    let generator = AVAssetImageGenerator(asset: media.composition); generator.videoComposition = media.videoComposition
                    generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
                    let moment = min(candidate.edit.duration - TimelineEditing.frame, max(0, join.origin + join.timing.videoDuration / 2))
                    let frame = try await generator.image(at: CMTime(seconds: moment, preferredTimescale: 60000)).image
                    try Task.checkCancellation(); guard revision == token else { return }
                    still = UIImage(cgImage: frame)
                }
                let item = AVPlayerItem(asset: media.composition); item.videoComposition = media.playbackVideoComposition; item.audioMix = media.audioMix
                status = item.observe(\.status, options: [.new]) { [weak self, weak item] _, _ in
                    Task { @MainActor in
                        guard let self, self.revision == token, let item, item === self.player.currentItem else { return }
                        if item.status == .failed { self.error = item.error?.localizedDescription ?? "This transition could not be previewed."; self.busy = false }
                    }
                }
                player.replaceCurrentItem(with: item)
                position = join.origin + join.timing.videoDuration / 2
                await player.seek(to: CMTime(seconds: position, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
                try Task.checkCancellation(); guard revision == token else { return }
                busy = false
            } catch is CancellationError {} catch { if revision == token { self.error = error.localizedDescription; busy = false } }
        }
    }
    func makeStill() {
        guard !frames.isEmpty else { return }
        let bounds = CGRect(origin: .zero, size: canvas), black = TransitionRenderer.fill(settings: settings, canvas: canvas)
        let pictures = frames.enumerated().map { index, image -> CIImage in
            if settings.style == .split { return image.cropped(to: frameBounds[index]) }
            var seen = Set<UUID>()
            return index < frameLayers.count ? VideoOverlayRenderer.apply(frameLayers[index].0, at: frameLayers[index].1, over: image, seen: &seen) : image
        }
        let first = isOpening ? black : pictures[0]
        let second = isOpening ? pictures[0] : isClosing ? black : pictures[1]
        var previewSettings = settings
        if (isOpening || isClosing) && previewSettings.style == .fadeColor { previewSettings.style = .dissolve }
        var result = TransitionRenderer.composite(first, second, settings: previewSettings, progress: 0.5, canvas: canvas)
        if settings.style == .split {
            var seen = Set<UUID>()
            for (layer, time) in frameLayers { result = VideoOverlayRenderer.apply(layer, at: time, over: result, seen: &seen) }
        }
        if let image = context.createCGImage(result, from: bounds) { still = UIImage(cgImage: image) }
    }
    func pause() { playbackRevision = UUID(); player.pause(); playing = false }
    func play() {
        guard canApply else { return }
        if playing { pause(); return }
        let token = UUID(); playbackRevision = token
        position = previewRange.lowerBound
        player.seek(to: CMTime(seconds: position, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in guard let self, finished, !self.busy, self.playbackRevision == token else { return }; self.playing = true; self.player.play() }
        }
    }
    func seek(_ time: Double) { pause(); position = time; player.seek(to: CMTime(seconds: time, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero) }
    func resetFraming() { settings.first = TransitionFraming(); settings.second = TransitionFraming(); settings.divider = 0.5 }
}

struct TransitionEditor: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @StateObject private var model: TransitionWorkspace
    let cancel: () -> Void
    let apply: (EditState) -> Void
    @State private var framing = true
    @State private var choosingStyle = false
    init(project: Project, folder: URL, request: ToolRequest, cancel: @escaping () -> Void, apply: @escaping (EditState) -> Void) {
        _model = StateObject(wrappedValue: TransitionWorkspace(project: project, folder: folder, boundary: request.boundaryIndex ?? 0))
        self.cancel = cancel; self.apply = apply
    }
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let horizontal = geometry.size.width > geometry.size.height
                let inspectorWidth = horizontal ? min(340, geometry.size.width * 0.4) : geometry.size.width
                let layout = horizontal ? AnyLayout(HStackLayout(spacing: 16)) : AnyLayout(VStackLayout(spacing: 12))
                layout {
                    preview.frame(maxWidth: .infinity, maxHeight: .infinity)
                    ScrollView { controls(width: max(0, inspectorWidth - 32)).padding(16).padding(.bottom, 24) }.accessibilityIdentifier("transition.controls")
                        .frame(width: horizontal ? inspectorWidth : nil, height: horizontal ? nil : geometry.size.height * 0.48)
                        .background(Color(white: 0.07))
                }
            }.background(.black).navigationTitle("Transition").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel).frame(minHeight: 44) }
                    ToolbarItem(placement: .confirmationAction) { Button("Apply") { apply(model.state()) }.fontWeight(.semibold).frame(minHeight: 44).disabled(!model.canApply).accessibilityIdentifier("transition.apply") }
                }
        }.preferredColorScheme(.dark).task { model.start() }.onDisappear { model.stop() }
            .sheet(isPresented: $choosingStyle) { stylePicker }
            .onChange(of: model.settings) { _, _ in framing = true; model.changed() }
    }
    private var preview: some View {
        VStack(spacing: 8) {
            Text(model.title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            GeometryReader { geometry in
                let scale = min(geometry.size.width / model.canvas.width, geometry.size.height / model.canvas.height)
                ZStack {
                if framing, let image = model.still {
                    InspectPreview(canvas: model.canvas, editsContent: model.settings.style == .split) { ZStack {
                    Image(uiImage: image).resizable().scaledToFit()
                    if model.settings.style == .split {
                        TransitionFramingSurface(settings: $model.settings, canvas: model.canvas,
                            firstSize: model.firstSize, secondSize: model.secondSize,
                            firstEnabled: !model.isOpening, secondEnabled: !model.isClosing)
                    }
                    } }
                } else { PlayerSurface(player: model.player, preserveInspection: true) }
                if model.busy && model.still == nil { ProgressView("Preparing preview…").padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12)) }
                }.frame(width: model.canvas.width * scale, height: model.canvas.height * scale)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2).clipped()
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.orange); Button("Retry") { model.rebuild(delay: false) } }
            HStack(spacing: 12) {
                Button { framing = false; model.play() } label: { Image(systemName: model.playing ? "pause.fill" : "play.fill").frame(width: 44, height: 44) }
                    .disabled(!model.canApply).accessibilityLabel(model.playing ? "Pause transition" : "Play transition").accessibilityIdentifier("transition.play")
                Slider(value: Binding(get: { model.position }, set: { framing = false; model.seek($0) }), in: model.previewRange)
                    .disabled(model.busy).accessibilityLabel("Transition preview position")
                if model.settings.style == .split {
                    Button { model.pause(); framing = true } label: { Image(systemName: "viewfinder").frame(width: 44, height: 44) }.accessibilityLabel("Frame split screen")
                }
            }.padding(.horizontal, 12)
        }.padding(.top, 8)
    }
    private func controls(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Button { choosingStyle = true } label: {
                HStack { Label(model.settings.style.title, systemImage: model.settings.style.symbol); Spacer(); Image(systemName: "chevron.up.chevron.down").font(.caption) }.font(.headline).frame(minHeight: 48)
            }.accessibilityIdentifier("transition.stylePicker")
            if model.settings.style == .fadeColor {
                ColorPicker("Fade color", selection: Binding(get: {
                    Color(cgColor: model.settings.resolvedFadeColor.cgColor)
                }, set: { value in
                    guard let rgb = UIColor(value).cgColor.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .relativeColorimetric, options: nil)?.components, rgb.count >= 3 else { return }
                    let color = TransitionColor(red: min(1, max(0, rgb[0])), green: min(1, max(0, rgb[1])), blue: min(1, max(0, rgb[2])))
                    model.settings.fadeColor = color == .black ? nil : color
                }), supportsOpacity: false).frame(minHeight: 44).accessibilityIdentifier("transition.fadeColor")
            }
            VStack(alignment: .leading, spacing: 6) {
                let maximum = model.maximum
                EditorDurationPicker(title: model.settings.style == .still ? "Freeze duration" : "Blend duration",
                                     seconds: model.settings.duration, maximum: maximum, width: width,
                                     choices: EditorDurationPresets.transitionSeconds, identifier: "transition.timing",
                                     presetPrefix: "transition.duration") { value in
                    model.settings.duration = value
                } details: {
                    Text("Up to \(maximum.formatted(.number.precision(.fractionLength(0...2)))) s")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                // SwiftUI requires at least one full step in the slider's range.
                // A one-frame neighbor has only one valid duration, so disable adjustment.
                Slider(value: Binding(get: { min(max(TimelineEditing.frame, maximum), max(TimelineEditing.frame, model.settings.duration)) }, set: { model.settings.duration = $0 }), in: TimelineEditing.frame...max(2 * TimelineEditing.frame, maximum), step: TimelineEditing.frame)
                    .disabled(maximum < 2 * TimelineEditing.frame)
                    .accessibilityLabel("Transition duration").accessibilityIdentifier("transition.duration")
                Text(model.lengthNote).font(.caption).foregroundStyle(.secondary)
                if model.join.factor < 0.99999 { Text("Picture and audio timing reduced to \((model.join.factor * 100).formatted(.number.precision(.fractionLength(0))))% to fit the neighboring clips. Your requested settings are kept.").font(.caption).foregroundStyle(.orange) }
            }
            if model.settings.style == .split || model.settings.style == .whip {
                Picker("Layout", selection: Binding(get: { model.settings.axis }, set: { model.chooseAxis($0) })) { ForEach(TransitionAxis.allCases, id: \.self) { Text($0.title).tag($0) } }.pickerStyle(.segmented).accessibilityIdentifier("transition.axis")
            }
            if model.settings.style == .whip { Toggle("Reverse direction", isOn: $model.settings.reverse) }
            if model.settings.style == .wipe {
                Picker("Edge", selection: Binding(get: { model.settings.hardEdge ?? false }, set: { model.settings.hardEdge = $0 })) { Text("Soft edge").tag(false); Text("Hard edge").tag(true) }.pickerStyle(.segmented).accessibilityIdentifier("transition.wipeEdge")
                HStack { Text("Angle"); Spacer(); Text("\(Int(model.settings.angle.rounded()))°").monospacedDigit() }
                Slider(value: Binding(get: { let a = model.settings.angle; return a > 180 ? a - 360 : a }, set: { model.settings.wipeAngle = $0; model.settings.reverse = false }), in: -180...180, step: 1).accessibilityLabel("Wipe angle").accessibilityIdentifier("transition.wipeAngle")
            }
            if model.settings.style == .hitchcock {
                Picker("Reveal", selection: Binding(get: { model.settings.highlightsFirst ?? false }, set: { model.settings.highlightsFirst = $0 })) { Text("Shadows first").tag(false); Text("Highlights first").tag(true) }.pickerStyle(.segmented).accessibilityIdentifier("transition.luminanceOrder")
            }
            if model.settings.style == .flashCut {
                Stepper("Flashes: \(model.settings.flashCount ?? 3)", value: Binding(get: { model.settings.flashCount ?? 3 }, set: { model.settings.flashCount = $0 }), in: 1...20).frame(minHeight: 44).accessibilityIdentifier("transition.flashes")
                Text("Brief glimpses of the next scene, closer together toward the cut.").font(.caption).foregroundStyle(.secondary)
                HStack { Text("Acceleration"); Spacer(); Text("\((model.settings.flashAcceleration ?? 2).formatted(.number.precision(.fractionLength(1))))×") }
                Slider(value: Binding(get: { model.settings.flashAcceleration ?? 2 }, set: { model.settings.flashAcceleration = $0 }), in: 0.25...4, step: 0.05).accessibilityIdentifier("transition.flashAcceleration")
                let count = model.settings.flashFrames(duration: model.effectiveDuration).count
                if count < (model.settings.flashCount ?? 3) { Text("\(count) flashes fit at this duration.").font(.caption).foregroundStyle(.orange) }
            }
            if model.settings.style == .still {
                Picker("After the freeze", selection: Binding(get: { (model.settings.stillDissolve ?? 0) > 0 }, set: { model.settings.stillDissolve = $0 ? 0.3 : nil })) { Text("Cut").tag(false); Text("Dissolve").tag(true) }.pickerStyle(.segmented).accessibilityIdentifier("transition.stillExit")
                if (model.settings.stillDissolve ?? 0) > 0 {
                    seconds("Exit dissolve", value: Binding(get: { model.settings.stillDissolve ?? 0.3 }, set: { model.settings.stillDissolve = $0 }), range: TimelineEditing.frame...5, id: "transition.stillDissolve")
                }
                Text("Holds the outgoing picture, then cuts or dissolves into the next scene.").font(.caption).foregroundStyle(.secondary)
            }
            if model.settings.style == .defocus {
                HStack { Text("Optical blur"); Spacer(); Text("\(Int((model.settings.blurAmount ?? 0.75) * 100))%") }
                Slider(value: Binding(get: { model.settings.blurAmount ?? 0.75 }, set: { model.settings.blurAmount = $0 }), in: 0.1...1).accessibilityIdentifier("transition.blur")
            }
            if model.settings.style.supportsHold {
                seconds(model.settings.style == .fadeColor && !model.isOpening && !model.isClosing ? "Hold on color" : "Hold at halfway", value: Binding(get: { model.settings.hold ?? 0 }, set: { model.settings.hold = $0 == 0 ? nil : $0 }), range: 0...max(10, min(60, model.maximum)), id: "transition.hold")
            }
            if model.settings.style == .split {
                Text("Drag each picture to pan · pinch to zoom. Drag the handle to move the divider.").font(.caption).foregroundStyle(.secondary)
                HStack { Text("Divider"); Spacer(); Text("\(Int((model.settings.divider * 100).rounded()))%").monospacedDigit() }
                Slider(value: $model.settings.divider, in: 0.15...0.85).accessibilityLabel("Divider position").accessibilityIdentifier("transition.divider")
                Picker("Audio", selection: Binding(get: { model.settings.audio }, set: { model.settings.audio = $0; model.settings.audioOffset = nil; model.settings.audioBlend = nil })) { ForEach(TransitionAudio.allCases, id: \.self) { Text($0.title).tag($0) } }.pickerStyle(.segmented).accessibilityLabel("Transition audio")
                Button("Reset framing") { model.resetFraming() }.frame(minHeight: 44).accessibilityIdentifier("transition.reset")
            }
            audioControls
            if model.existing {
                Button("Remove transition", role: .destructive) { apply(model.state(removing: true)) }.frame(maxWidth: .infinity, minHeight: 44).buttonStyle(.bordered).accessibilityIdentifier("transition.remove")
                if !model.isOpening && !model.isClosing {
                    Text("Restores a straight cut and keeps all source footage.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }.tint(.orange)
    }
    private func seconds(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, id: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text(title); Spacer(); Text("\(value.wrappedValue.formatted(.number.precision(.fractionLength(2)))) s").monospacedDigit().accessibilityIdentifier(id + ".value") }
            Slider(value: value, in: range, step: TimelineEditing.frame)
                .overlay {
                    if range.lowerBound < 0 && range.upperBound == -range.lowerBound {
                        Rectangle().fill(.white.opacity(0.65)).frame(width: 1, height: 14).allowsHitTesting(false)
                    }
                }.accessibilityLabel(title).accessibilityIdentifier(id)
        }
    }
    private var audioControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            HStack { Label("Audio timing", systemImage: "waveform").font(.headline); Spacer(); Button("Reset") { model.settings.audioOffset = nil; model.settings.audioBlend = nil; model.settings.audio = .crossfade }.font(.subheadline).frame(minHeight: 44) }
            seconds("Start offset", value: Binding(get: { model.settings.audioOffset ?? 0 }, set: { model.settings.audioOffset = $0; model.settings.audio = .crossfade }), range: -model.audioMaximum...model.audioMaximum, id: "transition.audioOffset")
            HStack {
                Button { model.settings.audioOffset = max(-model.audioMaximum, (model.settings.audioOffset ?? 0) - 0.1); model.settings.audio = .crossfade } label: { Label("\(0.1.formatted()) s", systemImage: "minus") }.frame(minHeight: 44).accessibilityLabel("Start audio 0.1 seconds earlier").accessibilityIdentifier("transition.audioEarlier")
                Spacer()
                Button("0 s") { model.settings.audioOffset = 0; model.settings.audio = .crossfade }.frame(minHeight: 44).accessibilityLabel("Start audio crossfade at picture transition start").accessibilityIdentifier("transition.audioAlign")
                Spacer()
                Button { model.settings.audioOffset = min(model.audioMaximum, (model.settings.audioOffset ?? 0) + 0.1); model.settings.audio = .crossfade } label: { Label("\(0.1.formatted()) s", systemImage: "plus") }.frame(minHeight: 44).accessibilityLabel("Start audio 0.1 seconds later").accessibilityIdentifier("transition.audioLater")
            }.font(.subheadline).buttonStyle(.bordered).controlSize(.regular)
            Text((model.settings.audioOffset ?? 0) < 0 ? "Sound starts before the picture transition." : (model.settings.audioOffset ?? 0) > 0 ? "Sound starts after the picture transition." : "Sound follows the picture transition.").font(.caption).foregroundStyle(.secondary)
            seconds("Audio blend", value: Binding(get: { model.displayedAudioBlend }, set: { model.settings.audioBlend = $0; model.settings.audio = .crossfade }), range: 0...max(model.audioMaximum, model.displayedAudioBlend), id: "transition.audioBlend")
            HStack {
                Button { model.settings.audioBlend = max(0, model.displayedAudioBlend - 0.1); model.settings.audio = .crossfade } label: { Label("\(0.1.formatted()) s", systemImage: "minus") }.frame(minHeight: 44).accessibilityLabel("Shorten audio blend by 0.1 seconds").accessibilityIdentifier("transition.audioShorter")
                Spacer()
                Button("Cut") { model.settings.audioBlend = 0; model.settings.audio = .crossfade }.frame(minHeight: 44).accessibilityLabel("Cut audio without crossfade").accessibilityIdentifier("transition.audioCut")
                Spacer()
                Button { model.settings.audioBlend = min(ClipTransition.maximumDuration, model.displayedAudioBlend + 0.1); model.settings.audio = .crossfade } label: { Label("\(0.1.formatted()) s", systemImage: "plus") }.frame(minHeight: 44).accessibilityLabel("Lengthen audio blend by 0.1 seconds").accessibilityIdentifier("transition.audioLonger")
            }.font(.subheadline).buttonStyle(.bordered).controlSize(.regular)
            if !model.settings.customAudio && (model.settings.style == .fadeColor || model.settings.style == .still) { Text("By default, sound follows the fade or freeze. Adjust either audio control to crossfade independently of the picture.").font(.caption).foregroundStyle(.secondary) }
            if model.settings.style == .split && !model.settings.customAudio && model.settings.audio != .crossfade { Text("\(model.settings.audio.title) is selected above. Adjust either audio control to use a timed crossfade.").font(.caption).foregroundStyle(.secondary) }
            audioTimingDiagram
            Text(model.lengthNote).font(.caption).foregroundStyle(.secondary)
        }
    }
    private var audioTimingDiagram: some View {
        let join = model.join
        let lower = join.range.lowerBound, span = max(TimelineEditing.frame, join.range.upperBound - lower)
        let audio = model.isOpening ? join.audioIn : model.isClosing ? join.audioOut : min(join.audioIn.lowerBound, join.audioOut.lowerBound)...max(join.audioIn.upperBound, join.audioOut.upperBound)
        return VStack(alignment: .leading, spacing: 8) {
          VStack(spacing: 8) {
            ForEach(0..<2) { index in
                HStack(spacing: 8) {
                    Image(systemName: index == 0 ? "film" : "waveform").frame(width: 24)
                    GeometryReader { geometry in
                        let range = index == 0 ? join.videoRange : audio
                        Capsule().fill(.white.opacity(0.07))
                        Capsule().fill(index == 0 ? Color.orange : Color.cyan)
                            .frame(width: max(2, geometry.size.width * (range.upperBound - range.lowerBound) / span))
                            .offset(x: geometry.size.width * (range.lowerBound - lower) / span)
                    }.frame(height: 7)
                }
            }
          }.overlay(alignment: .topLeading) {
              GeometryReader { geometry in
                  Rectangle().fill(.white.opacity(0.4)).frame(width: 1)
                      .offset(x: 32 + max(0, geometry.size.width - 32) * (join.origin - lower) / span)
              }.allowsHitTesting(false)
          }
          Text("Sound \((audio.lowerBound - join.origin).formatted(.number.sign(strategy: .always()).precision(.fractionLength(2)))) to \((audio.upperBound - join.origin).formatted(.number.sign(strategy: .always()).precision(.fractionLength(2)))) s · picture starts at 0")
              .font(.caption2)
        }.foregroundStyle(.secondary).padding(.vertical, 8).accessibilityElement(children: .ignore)
            .accessibilityLabel("Picture transition and audio timing").accessibilityValue(model.lengthNote)
    }
    private var stylePicker: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: typeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(TransitionStyle.allCases) { style in
                        Button { model.selectStyle(style); choosingStyle = false } label: {
                            Label(style.title, systemImage: style.symbol).font(.subheadline.weight(.medium)).frame(maxWidth: .infinity, minHeight: 54).padding(.horizontal, 6)
                                .background(model.settings.style == style ? Color.orange.opacity(0.24) : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(model.settings.style == style ? .orange : .clear) }
                        }.buttonStyle(.plain).accessibilityIdentifier("transition.style." + style.rawValue).accessibilityAddTraits(model.settings.style == style ? .isSelected : [])
                    }
                }.padding(16)
            }.navigationTitle("Transition style").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { choosingStyle = false } } }
        }.preferredColorScheme(.dark).presentationDetents([.medium, .large])
    }

}

// UIKit assigns the gesture at touch-down: a divider grab cannot pan a picture,
// and a picture drag cannot unexpectedly pick up the divider halfway through.
private struct TransitionFramingSurface: UIViewRepresentable {
    @Binding var settings: ClipTransition
    let canvas: CGSize
    let firstSize: CGSize
    let secondSize: CGSize
    let firstEnabled: Bool
    let secondEnabled: Bool
    func makeUIView(context: Context) -> TransitionFramingView { TransitionFramingView() }
    func updateUIView(_ view: TransitionFramingView, context: Context) {
        view.settings = settings; view.canvas = canvas; view.firstEnabled = firstEnabled; view.secondEnabled = secondEnabled
        view.firstSize = firstSize; view.secondSize = secondSize
        view.accessibilityValue = String(format: "divider %.3f first %.3f %.3f %.3f second %.3f %.3f %.3f", settings.divider, settings.first.x, settings.first.y, settings.first.zoom, settings.second.x, settings.second.y, settings.second.zoom)
        view.change = { settings = $0 }; view.setNeedsDisplay()
    }
}
private final class TransitionFramingView: UIView {
    var settings = ClipTransition()
    var canvas = CGSize(width: 1920, height: 1080)
    var firstSize = CGSize(width: 1920, height: 1080), secondSize = CGSize(width: 1920, height: 1080)
    var firstEnabled = true, secondEnabled = true
    var change: (ClipTransition) -> Void = { _ in }
    private var anchor = ClipTransition()
    private var target = 0 // -1 divider, 0 first, 1 second
    override init(frame: CGRect) {
        super.init(frame: frame); backgroundColor = .clear
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(pan(_:))))
        addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:))))
        let reset = UITapGestureRecognizer(target: self, action: #selector(reset(_:))); reset.numberOfTapsRequired = 2; addGestureRecognizer(reset)
        accessibilityIdentifier = "transition.framing"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let horizontal = settings.axis == .horizontal
        let center = CGPoint(x: horizontal ? bounds.width * settings.divider : bounds.midX, y: horizontal ? bounds.midY : bounds.height * settings.divider)
        let handle = CGRect(x: center.x - 18, y: center.y - 18, width: 36, height: 36)
        context.setFillColor(UIColor.black.withAlphaComponent(0.7).cgColor); context.fillEllipse(in: handle)
        UIImage(systemName: horizontal ? "arrow.left.and.right" : "arrow.up.and.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold))?
            .withTintColor(.white, renderingMode: .alwaysOriginal).draw(in: CGRect(x: center.x - 10, y: center.y - 10, width: 20, height: 20))
    }
    private func side(_ point: CGPoint) -> Int { settings.axis == .horizontal ? (point.x < bounds.width * settings.divider ? 0 : 1) : (point.y < bounds.height * settings.divider ? 0 : 1) }
    private func enabled(_ side: Int) -> Bool { side == 0 ? firstEnabled : secondEnabled }
    @objc private func pan(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: self)
        if gesture.state == .began {
            anchor = settings
            let distance = settings.axis == .horizontal ? abs(point.x - bounds.width * settings.divider) : abs(point.y - bounds.height * settings.divider)
            target = distance <= 22 ? -1 : side(point)
        }
        guard gesture.state == .began || gesture.state == .changed else { return }
        let delta = gesture.translation(in: self)
        var value = anchor
        if target == -1 {
            value.divider = min(0.85, max(0.15, anchor.divider + (settings.axis == .horizontal ? delta.x / max(1, bounds.width) : delta.y / max(1, bounds.height))))
        } else if enabled(target) {
            var framing = target == 0 ? anchor.first : anchor.second
            let rects = TransitionRenderer.splitRects(settings: anchor, canvas: canvas), viewport = target == 0 ? rects.0 : rects.1
            let sourceSize = target == 0 ? firstSize : secondSize
            let crop = framing.crop(source: sourceSize, viewport: viewport.size)
            let screenScale = bounds.width / max(1, canvas.width)
            let scale = viewport.width / max(1, crop.width) * screenScale
            framing.x = min(1, max(0, framing.x - delta.x / max(1, scale * sourceSize.width)))
            framing.y = min(1, max(0, framing.y - delta.y / max(1, scale * sourceSize.height)))
            let clamped = framing.crop(source: sourceSize, viewport: viewport.size)
            framing.x = clamped.midX / sourceSize.width; framing.y = clamped.midY / sourceSize.height
            if target == 0 { value.first = framing } else { value.second = framing }
        }
        change(value)
    }
    @objc private func pinch(_ gesture: UIPinchGestureRecognizer) {
        if gesture.state == .began { anchor = settings; target = side(gesture.location(in: self)) }
        guard enabled(target), gesture.state == .began || gesture.state == .changed else { return }
        var value = anchor, framing = target == 0 ? anchor.first : anchor.second
        framing.zoom = min(4, max(1, framing.zoom * gesture.scale))
        if target == 0 { value.first = framing } else { value.second = framing }
        change(value)
    }
    @objc private func reset(_ gesture: UITapGestureRecognizer) {
        var value = settings; let target = side(gesture.location(in: self)); guard enabled(target) else { return }
        if target == 0 { value.first = TransitionFraming() } else { value.second = TransitionFraming() }; change(value)
    }
}

#if DEBUG
// Explicit device QA against a synthetic input in an isolated folder.
// Never opens ProjectStore or writes a user project.
@MainActor enum TransitionDiagnostics {
    static func run() async {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("TransitionsQA")
        var report: [String: Any] = [:]
        RecordingAppDelegate.keepAwake("transitions-qa", active: true)
        defer { RecordingAppDelegate.keepAwake("transitions-qa", active: false) }
        func check(_ value: Bool, _ message: String) throws { if !value { throw NSError(domain: "TransitionQA", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) } }
        func ready(_ workspace: TransitionWorkspace) async throws {
            let deadline = Date().addingTimeInterval(40)
            while workspace.busy || workspace.player.currentItem?.status == .unknown {
                try check(Date() < deadline, "Preview timed out"); try await Task.sleep(for: .milliseconds(50))
            }
            try check(workspace.error == nil && workspace.canApply && workspace.player.currentItem?.status == .readyToPlay, workspace.error ?? "Player not ready")
        }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
            let input = folder.appendingPathComponent("input.mp4")
            let duration = try await AVURLAsset(url: input).load(.duration).seconds
            var project = Project(title: "Isolated transition QA")
            project.append(SourceMedia(filename: "input.mp4", duration: duration))
            var edit = project.edit; var copy = edit.clips[0]; copy.id = UUID(); edit.clips.append(copy)
            project.commit(edit)
            let workspace = TransitionWorkspace(project: project, folder: folder, boundary: 1)
            defer { workspace.stop() }
            workspace.start(); try await ready(workspace)
            workspace.settings.style = .split; workspace.settings.duration = 1
            workspace.settings.divider = 0.35; workspace.settings.first = TransitionFraming(x: 0.2, y: 0.6, zoom: 1.5)
            workspace.settings.second = TransitionFraming(x: 0.8, y: 0.4, zoom: 1.2)
            workspace.changed(); try await ready(workspace)
            workspace.play(); try await Task.sleep(for: .seconds(0.7))
            try check(workspace.player.rate > 0 && workspace.player.currentTime().seconds > workspace.previewRange.lowerBound + 0.3, "Transition playback did not advance")
            workspace.pause()
            var candidate = project; candidate.commit(workspace.state()); try candidate.validate()
            let output = folder.appendingPathComponent("export-" + UUID().uuidString + ".mp4")
            let began = Date()
            _ = try await MediaRenderer.render(project: candidate, folder: folder, destination: output) { _ in }
            let asset = AVURLAsset(url: output), actualDuration = try await asset.load(.duration).seconds
            try check(abs(actualDuration - candidate.edit.duration) < 0.04, "Export length disagrees with timeline")
            let video = try await asset.loadTracks(withMediaType: .video).first!
            report["hdr"] = try await video.load(.formatDescriptions).contains { VideoColor.isHDR($0) }
            report["exportSeconds"] = Date().timeIntervalSince(began); report["duration"] = actualDuration
            let generator = AVAssetImageGenerator(asset: asset); generator.appliesPreferredTrackTransform = true
            let frame = try await generator.image(at: CMTime(seconds: candidate.edit.layout.joins[1].time, preferredTimescale: 60000)).image
            try UIImage(cgImage: frame).pngData()?.write(to: folder.appendingPathComponent("frame.png"))
            report["width"] = frame.width; report["height"] = frame.height
            workspace.settings.axis = .vertical; workspace.changed(); try await ready(workspace)
            workspace.play(); workspace.stop(); try await Task.sleep(for: .milliseconds(350))
            try check(workspace.player.rate == 0, "Cancelled playback restarted after closing")
            var expanded: [[String: Any]] = []
            for style in TransitionStyle.allCases {
                var settings = ClipTransition(style: style, duration: style == .whip ? 8.0 / 30 : 0.6)
                settings.audioOffset = -0.15; settings.audioBlend = 0.3
                if style.supportsHold { settings.hold = 0.2 }
                if style == .fadeColor { settings.fadeColor = TransitionColor(red: 0.2, green: 0.5, blue: 0.8) }
                if style == .wipe { settings.hardEdge = true; settings.wipeAngle = 37 }
                if style == .still { settings.stillDissolve = 0.25 }
                let preview = TransitionWorkspace(project: project, folder: folder, boundary: 1)
                preview.settings = settings; preview.start(); try await ready(preview)
                preview.play(); try await Task.sleep(for: .milliseconds(600))
                try check(preview.player.currentTime().seconds > preview.previewRange.lowerBound + 0.2, "\(style.title) preview stalled")
                preview.stop()
                var edited = project.edit.settingTransition(settings, at: 1)
                if style == .whip || style == .defocus { edited.outputSize = CGSize(width: 3840, height: 2160) }
                var rendered = project; rendered.commit(edited)
                let destination = folder.appendingPathComponent("expanded-\(style.rawValue).mp4"), start = Date()
                _ = try await MediaRenderer.render(project: rendered, folder: folder, destination: destination) { _ in }
                let result = AVURLAsset(url: destination), length = try await result.load(.duration).seconds
                let track = try await result.loadTracks(withMediaType: .video).first!
                let hdr = try await track.load(.formatDescriptions).contains { VideoColor.isHDR($0) }
                try check(abs(length - rendered.edit.duration) < TimelineEditing.frame && hdr, "\(style.title) export lost timing or HDR")
                let images = AVAssetImageGenerator(asset: result)
                let frame = try await images.image(at: CMTime(seconds: rendered.edit.layout.joins[1].time, preferredTimescale: 60000)).image
                try UIImage(cgImage: frame).pngData()?.write(to: folder.appendingPathComponent("expanded-\(style.rawValue).png"))
                expanded.append(["style": style.rawValue, "duration": length, "hdr": hdr, "exportSeconds": Date().timeIntervalSince(start), "width": frame.width, "height": frame.height])
                report["expanded"] = expanded
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("progress.json"), options: .atomic)
            }
            let regressionURL = folder.appendingPathComponent("project.json")
            if FileManager.default.fileExists(atPath: regressionURL.path) {
                let before = try Data(contentsOf: regressionURL)
                let regression = try JSONDecoder().decode(Project.self, from: before)
                let editor = EditorController(); defer { editor.stop() }
                await editor.load(regression, folder: folder)
                let deadline = Date().addingTimeInterval(40)
                while editor.player.currentItem?.status == .unknown {
                    try check(Date() < deadline, "Regression editor timed out"); try await Task.sleep(for: .milliseconds(50))
                }
                try check(editor.error == nil && editor.player.currentItem?.status == .readyToPlay, editor.error ?? "Regression editor not ready")
                for time in [0.0, max(0, regression.edit.duration - 1)] {
                    await editor.player.seek(to: CMTime(seconds: time, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
                    editor.player.play(); try await Task.sleep(for: .milliseconds(650))
                    try check(editor.player.currentTime().seconds > time + 0.2 && editor.error == nil, "Regression playback failed")
                    editor.player.pause()
                }
                let exportURL = folder.appendingPathComponent("regression-" + UUID().uuidString + ".mp4")
                _ = try await MediaRenderer.render(project: regression, folder: folder, destination: exportURL) { _ in }
                let exported = AVURLAsset(url: exportURL)
                let duration = try await exported.load(.duration).seconds
                try check(abs(duration - regression.edit.duration) < TimelineEditing.frame, "Regression export length changed")
                let track = try await exported.loadTracks(withMediaType: .video).first!
                report["regressionHDR"] = try await track.load(.formatDescriptions).contains { VideoColor.isHDR($0) }
                report["regressionDuration"] = duration
                let after = try Data(contentsOf: regressionURL)
                try check(before == after, "Regression project was modified")
                report["regressionProject"] = true
            }
            report["success"] = true
        } catch { report["success"] = false; report["error"] = error.localizedDescription }
        if let bytes = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? bytes.write(to: folder.appendingPathComponent("report.json"), options: .atomic) }
    }
}
#endif
