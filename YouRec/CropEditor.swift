import SwiftUI
import AVKit

struct CropFrame {
    let clipID: UUID
    let image: UIImage
    let size: CGSize
    let texts: [TextOverlay]
    var poses: [UUID:TitleMotion.Pose] = [:]
    var mirror: MirrorSettings?
    var images: [(ImageOverlay, UIImage)] = []
}

@MainActor
final class CropWorkspace: ObservableObject {
    let project: Project
    private let titleRanges: TitleMotionRanges
    let folder: URL
    let request: ToolRequest
    let player = AVPlayer()
    let clips: [TimelineClip]
    private let scoped: EditState
    private let ids: Set<UUID>
    private let effectID: UUID
    private let origins: [UUID:Double]
    private let scope: ClosedRange<Double>
    @Published var crop = CropSettings()
    @Published var endpoint: EffectEndpoint?
    private var previewEndpoint: EffectEndpoint?
    private var lastEndpoint: EffectEndpoint = .a
    @Published var animation: EffectAnimation?
    private var animationChanged = false
    func selectEndpoint(_ e: EffectEndpoint) {
        var motion = capturedAnimation ?? EffectAnimation(crop.pose,duration:duration)
        motion.duration = duration
        animation = motion; endpoint = e; lastEndpoint = e; crop = crop.applying(motion[e])
        framingChanged = true; animationChanged = true
        returnToEndpoint()
    }
    private var capturedAnimation: EffectAnimation? {
        guard var motion = animation else { return nil }
        motion[endpoint ?? lastEndpoint] = crop.pose
        return motion
    }
    func finishEndpoint() { animation = capturedAnimation; endpoint = nil; previewEndpoint = nil }
    func removeAnimation() {
        animation = nil; endpoint = nil; previewEndpoint = nil; crop.motion = nil
        animationChanged = true; framingChanged = true
        if reviewing { showReview(false) }
    }
    func updateTiming(_ timing: EffectTiming) {
        guard var motion = capturedAnimation, motion.timing != timing else { return }
        let target = timing.previewPosition(position, following: previewEndpoint, duration: duration, frame: motion.frame)
        motion.timing = timing
        motion.duration = duration
        animation = motion
        animationChanged = true
        if reviewing {
            position = target
            showReview(true, debounce: true)
        } else if position != target {
            position = target
            loadFrame()
        }
    }
    private func returnToEndpoint() {
        guard let e = endpoint, let animation else { return }
        previewEndpoint = e
        position = animation.timing.endpoint(e,duration:duration,frame:animation.frame)
        showReview(false)
    }
    @Published var aspect: Double?
    @Published private(set) var originalCanvas: CGSize?
    @Published private(set) var frame: CropFrame?
    private var sourceSizes: [UUID: CGSize] = [:]
    @Published var position = 0.0
    @Published var busy = true
    @Published var reviewing = false
    @Published var playing = false
    @Published var error: String?
    private var selectedShape: OutputShape?
    private var framingChanged = false
    private var frameJob: Task<Void, Never>?
    private var reviewJob: Task<Void, Never>?
    private var generator: AVAssetImageGenerator?
    private var generatorClip: UUID?
    private var endpointPlaybackEnd: EffectPreviewEndObserver?
    private var observer: Any?
    private var revision = UUID()
    private let awakeReason = "crop-" + UUID().uuidString
    var duration: Double { scope.upperBound - scope.lowerBound }
    var canvas: CGSize { OutputShape.canvas(source: aspect == nil ? originalCanvas ?? .zero : project.edit.outputSize ?? originalCanvas ?? .zero, aspect: aspect) }
    var shapeTitle: String { selectedShape?.title ?? OutputShape.allCases.first { $0.aspect == aspect }?.title ?? "Custom" }
    var sourceSize: CGSize { frame?.size ?? .zero }
    var picture: UIImage? { frame?.image }
    var canApply: Bool { !busy && error == nil && frame != nil && originalCanvas != nil }
    var active: (clip: TimelineClip, offset: Double, index: Int)? {
        let t = scope.lowerBound + position
        guard let index = clips.indices.min(by:{ l,r in
            func distance(_ clip:TimelineClip) -> Double {
                let start = origins[clip.id] ?? scope.lowerBound
                return max(0, start-t, t-start-clip.duration+0.000001)
            }
            return distance(clips[l]) < distance(clips[r])
        }) else { return nil }
        let clip = clips[index]
        let offset = min(max(0,clip.duration - TimelineEditing.frame),max(0,t - (origins[clip.id] ?? t)))
        return (clip,offset,index)
    }
    init(project: Project, folder: URL, request: ToolRequest, position: Double) {
        self.project = project; self.folder = folder; self.request = request
        titleRanges = TitleMotionRanges(project.edit)
        let selection = request.videoScope(in: project.edit)
        scoped = selection.0; ids = selection.1; clips = selection.0.clips.filter { selection.1.contains($0.id) }.map { var clip = $0; clip.transition = nil; clip.openingTransition = nil; return clip }
        effectID = request.effectID ?? UUID(); aspect = project.edit.outputSize.map { $0.width / $0.height }
        let placements = selection.0.layout.placements.filter { selection.1.contains($0.clip.id) }
        origins = Dictionary(uniqueKeysWithValues:placements.map { ($0.clip.id,$0.start) })
        scope = request.videoPreviewRange(in:selection.0,ids:selection.1)
        self.position = min(max(0,scope.upperBound-scope.lowerBound-TimelineEditing.frame),max(0,position-scope.lowerBound))
        crop = active?.clip.crop ?? CropSettings(); crop.id = effectID
        animation = crop.motion; crop.motion = nil
        endpointPlaybackEnd = EffectPreviewEndObserver(player:player) { [weak self] in
            guard let self, self.endpoint != nil else { return }
            self.playing = false; self.returnToEndpoint()
        }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 15), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self, self.reviewing else { return }
                self.playing = self.player.rate > 0
                if self.playing && time.seconds.isFinite { self.position = min(self.duration,max(0,time.seconds-self.scope.lowerBound)) }
                if time.seconds >= self.scope.upperBound - 0.02 { self.player.pause(); self.playing = false; self.returnToEndpoint() }
            }
        }
    }
    deinit { if let observer { player.removeTimeObserver(observer) }; frameJob?.cancel(); reviewJob?.cancel() }
    func start() {
        frameJob?.cancel(); reviewJob?.cancel()
        let token = UUID(); revision = token; busy = true; error = nil
        frameJob = Task {
            do {
                var original = project; var edit = original.edit; edit.outputSize = nil; original.commit(edit)
                let canvas = try await MediaRenderer.canvas(project: original, folder: folder)
                var sizes: [UUID: CGSize] = [:]
                for sourceID in Set(clips.map(\.sourceID)) {
                    guard let source = project.sources.first(where: { $0.id == sourceID }),
                          let track = try await AVURLAsset(url: folder.appendingPathComponent(source.filename)).loadTracks(withMediaType: .video).first else { throw ProjectError.missingMedia }
                    let size = try await track.load(.naturalSize), transform = try await track.load(.preferredTransform)
                    let bounds = CGRect(origin: .zero, size: size).applying(transform)
                    sizes[sourceID] = CGSize(width: abs(bounds.width), height: abs(bounds.height))
                }
                try Task.checkCancellation(); guard revision == token else { return }
                sourceSizes = sizes; originalCanvas = canvas; loadFrame()
            } catch is CancellationError {} catch { if revision == token { self.error = error.localizedDescription; busy = false } }
        }
    }
    func retry() { if originalCanvas == nil { start() } else { showReview(reviewing) } }
    func stop() {
        revision = UUID(); frameJob?.cancel(); reviewJob?.cancel(); generator?.cancelAllCGImageGeneration()
        player.pause(); RecordingAppDelegate.keepAwake(awakeReason, active: false)
    }
    func adjust(_ value: CropSettings) {
        guard canApply else { return }
        crop = value; crop.x = min(1, max(0, value.x)); crop.y = min(1, max(0, value.y)); crop.zoom = min(8, max(1, value.zoom))
        crop.rotation = CropSettings.normalizedRotation(value.rotation)
        crop.id = effectID; framingChanged = true
        if animation != nil {
            animationChanged = true
            if previewEndpoint == nil {
                endpoint = lastEndpoint
                returnToEndpoint()
            }
        }
    }
    func move(x: Double? = nil, y: Double? = nil) {
        var value = crop
        if let x { value.x = x }
        if let y { value.y = y }
        let visible = value.clamped(source: sourceSize, canvas: canvas)
        if x != nil { value.x = visible.x }
        if y != nil { value.y = visible.y }
        adjust(value)
    }
    func positionRange(horizontal: Bool) -> ClosedRange<Double> {
        let area = crop.footprint(source: sourceSize, canvas: canvas)
        let half = horizontal ? area.width / max(1, sourceSize.width) / 2 : area.height / max(1, sourceSize.height) / 2
        return half < 0.5 ? half...(1 - half) : 0...1
    }
    func setShape(_ value: OutputShape) {
        guard canApply else { return }
        selectedShape = value
        aspect = value.aspect
        if reviewing { showReview(false) }
    }
    func rotate(_ degrees: Double) {
        var value = crop; value.rotation = abs(degrees) < 0.5 ? 0 : degrees
        adjust(value)
    }
    var displayedCrop: CropSettings {
        guard var motion = capturedAnimation, let active else { return crop }
        if previewEndpoint != nil { return crop }
        if animationChanged {
            let offset = (origins[active.clip.id] ?? scope.lowerBound) - scope.lowerBound
            motion = motion.placed(on: active.clip, offset: offset, replacing: active.clip.crop?.motion)
        }
        let time = active.clip.frozenFrame.map { $0.sourceTime + $0.offset + active.offset } ?? active.clip.sourceTime(at:active.offset)
        return crop.applying(motion.pose(at:time))
    }
    func resetFraming() { adjust(CropSettings(id: effectID)) }
    func state(removing: Bool = false, forPreview: Bool = false) -> EditState {
        var edit = scoped
        var changedCrop = false
        for index in edit.clips.indices where ids.contains(edit.clips[index].id) {
            let offset = (origins[edit.clips[index].id] ?? scope.lowerBound) - scope.lowerBound
            let previous = edit.clips[index].crop
            var proposed: CropSettings? = framingChanged ? crop : previous ?? CropSettings(id: effectID)
            if let motion = capturedAnimation, animationChanged {
                proposed = crop.applying(motion.a)
                proposed?.motion = motion.placed(on:edit.clips[index],offset:offset,replacing:previous?.motion)
            }
            if removing { proposed = nil }
            else if let size = sourceSizes[edit.clips[index].sourceID], let value = proposed {
                if value.motion == nil && value.isFullFrame(source: size, canvas: canvas) { proposed = nil }
            }
            changedCrop = changedCrop || proposed != previous
            edit.clips[index].crop = proposed
        }
        if !forPreview && !changedCrop {
            edit = project.edit // A neutral crop must not leave split boundaries behind.
        }
        guard !removing else { return edit }
        if selectedShape == .original && edit.timeline.video.allSatisfy({ $0.content.crop == nil }) {
            edit.outputSize = nil
        } else if changedCrop || selectedShape != nil || forPreview {
            edit.outputSize = canvas
        }
        return edit
    }
    func seek(_ value: Double) {
        previewEndpoint = nil
        player.pause(); playing = false; position = min(max(0, value), max(0, duration - TimelineEditing.frame))
        if reviewing { player.seek(to: CMTime(seconds:scope.lowerBound + position, preferredTimescale:60000), toleranceBefore:.zero,toleranceAfter:.zero) }
        else { loadFrame() }
    }
    func stepClip(_ delta: Int) {
        guard let active else { return }
        let index = min(clips.count - 1, max(0, active.index + delta))
        seek((origins[clips[index].id] ?? scope.lowerBound)-scope.lowerBound)
    }
    func loadFrame() {
        guard originalCanvas != nil else { start(); return }
        frameJob?.cancel(); generator?.cancelAllCGImageGeneration()
        let token = UUID(); revision = token; busy = true; error = nil
        frameJob = Task {
            defer { if revision == token { busy = false; RecordingAppDelegate.keepAwake(awakeReason, active: false) } }
            do {
                try await Task.sleep(for: .milliseconds(80))
                RecordingAppDelegate.keepAwake(awakeReason, active: true)
                guard let active else { throw ProjectError.emptyTimeline }
                if generatorClip != active.clip.id {
                    var candidate = project, clip = active.clip; clip.crop = nil; clip.texts = nil; clip.mirror = nil; clip.images = nil
                    candidate.commit(EditState(clips: [clip]))
                    let media = try await MediaRenderer.timeline(project: candidate, folder: folder,effectPreparation:.cached)
                    try Task.checkCancellation(); guard revision == token else { return }
                    let generator = AVAssetImageGenerator(asset: media.composition)
                    generator.videoComposition = media.videoComposition; generator.maximumSize = CGSize(width: 1600, height: 1600)
                    generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
                    self.generator = generator; generatorClip = active.clip.id
                }
                guard let generator else { throw ProjectError.invalidMedia }
                let image = try await generator.image(at: CMTime(seconds: active.offset, preferredTimescale: 60000)).image
                try Task.checkCancellation(); guard revision == token else { return }
                guard let size = sourceSizes[active.clip.sourceID] else { throw ProjectError.invalidMedia }
                let time = active.clip.sourceTime(at: active.offset)
                if !framingChanged {
                    crop = active.clip.crop ?? CropSettings()
                    if let motion = crop.motion { crop = crop.applying(motion[.a]) }
                    crop.id = effectID
                }
                let projectTime = (scoped.layout.placements.first { $0.clip.id == active.clip.id }?.start ?? 0) + active.offset
                var poses: [UUID:TitleMotion.Pose] = [:]
                for text in active.clip.texts ?? [] {
                    if let motion=text.motion, let range=titleRanges.range(for:text,at:projectTime) {
                        poses[text.id] = motion.pose(at:projectTime-range.lowerBound,duration:range.upperBound-range.lowerBound)
                    }
                }
                frame = CropFrame(clipID: active.clip.id, image: UIImage(cgImage: image), size: size,
                                  texts: (active.clip.texts ?? []).filter { time >= $0.start && time < $0.end }, poses: poses, mirror: active.clip.mirror,
                                  images: (active.clip.images ?? []).filter { time >= $0.start && time < $0.end }.compactMap { image in
                                    UIImage(contentsOfFile: folder.appendingPathComponent(image.filename).path).map { (image.motion.map { image.applying($0.pose(at:time)) } ?? image, $0) }
                                  })
            } catch is CancellationError {} catch { if revision == token { self.error = error.localizedDescription } }
        }
    }
    func showReview(_ value: Bool, autoplay: Bool = false, debounce: Bool = false) {
        guard originalCanvas != nil else { start(); return }
        if autoplay { previewEndpoint = nil }
        player.pause(); playing = false; reviewing = value
        reviewJob?.cancel()
        if !value { loadFrame(); return }
        frameJob?.cancel(); generator?.cancelAllCGImageGeneration()
        let token = UUID(); revision = token; busy = true; error = nil
        reviewJob = Task {
            defer { if revision == token { busy = false; RecordingAppDelegate.keepAwake(awakeReason, active: false) } }
            do {
                if debounce { try await Task.sleep(for: .milliseconds(120)) }
                RecordingAppDelegate.keepAwake(awakeReason, active: true)
                var candidate = project; let edit = state(forPreview: true)
                candidate.history = [edit]; candidate.historyCursor = 0
                let media = try await MediaRenderer.timeline(project: candidate, folder: folder, canvasSize: canvas,effectPreparation:.cached)
                try Task.checkCancellation(); guard revision == token else { return }
                let item = AVPlayerItem(asset: media.composition); item.videoComposition = media.playbackVideoComposition; item.audioMix = media.audioMix
                item.audioTimePitchAlgorithm = .spectral; item.seekingWaitsForVideoCompositionRendering = true
                item.reversePlaybackEndTime = CMTime(seconds:scope.lowerBound,preferredTimescale:60000)
                item.forwardPlaybackEndTime = CMTime(seconds:scope.upperBound,preferredTimescale:60000)
                player.replaceCurrentItem(with: item)
                _ = await player.seek(to: CMTime(seconds: scope.lowerBound + (autoplay && endpoint != nil ? 0 : position), preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
                if autoplay && revision == token { player.play(); playing = true }
            } catch is CancellationError {} catch { if revision == token { self.error = error.localizedDescription } }
        }
    }
    func togglePlay() {
        if playing { player.pause(); playing = false; returnToEndpoint() }
        else if !reviewing || endpoint != nil { showReview(true,autoplay:true) }
        else {
            if position >= duration - 0.05 { position = 0; player.seek(to:CMTime(seconds:scope.lowerBound,preferredTimescale:60000)) }
            player.play(); playing = true
        }
    }
}

struct CropEditor: View {
    @StateObject private var model: CropWorkspace
    let cancel: () -> Void
    let apply: (EditState) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    init(project: Project, folder: URL, request: ToolRequest, position: Double, cancel: @escaping () -> Void, apply: @escaping (EditState) -> Void) {
        _model = StateObject(wrappedValue: CropWorkspace(project: project, folder: folder, request: request, position: position))
        self.cancel = cancel; self.apply = apply
    }
    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            VStack(spacing: 0) {
                HStack {
                    Button("Cancel", action: cancel).frame(minWidth: 60, minHeight: 44).accessibilityIdentifier("tool.cancel")
                    Spacer(minLength: 0)
                    VStack(spacing: 2) {
                        Text("Crop").font(.headline)
                        Text(model.request.scopeTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if model.request.effectID != nil {
                        Button(role: .destructive) { model.stop(); apply(model.state(removing: true)) } label: {
                            Image(systemName: "trash").frame(width: 44, height: 44)
                        }.foregroundStyle(.white.opacity(0.7)).accessibilityLabel("Remove crop").accessibilityHint("Keeps the project's video shape.").accessibilityIdentifier("tool.remove")
                    }
                    Button("Apply") { model.stop(); apply(model.state()) }.bold().frame(minWidth: 60, minHeight: 44)
                        .disabled(!model.canApply).accessibilityIdentifier("tool.apply")
                }.padding(.horizontal, 16)
                let layout = landscape ? AnyLayout(HStackLayout(spacing: 12)) : AnyLayout(VStackLayout(spacing: 0))
                layout {
                    VStack(spacing: 0) {
                        ZStack {
                            if model.reviewing { PlayerSurface(player: model.player, identifier: "crop.result", preserveInspection: true) }
                            else if let frame = model.frame {
                                InspectPreview(canvas: model.canvas) { CropCanvas(image: frame.image, source: frame.size, canvas: model.canvas, texts: frame.texts,
                                           crop: model.displayedCrop, poses: frame.poses, mirror: frame.mirror, images: frame.images, folder: model.folder, changed: model.adjust).allowsHitTesting(!model.busy) }
                            }
                            if model.busy { ProgressView().padding(16).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12)) }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                        playback.padding(.horizontal, 14)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    ScrollView { settings.padding(16) }.accessibilityIdentifier("crop.settings")
                        .frame(width: landscape ? min(320, geometry.size.width * 0.38) : nil)
                        .frame(maxHeight: landscape ? .infinity : min(typeSize.isAccessibilitySize ? 340 : 280, geometry.size.height * 0.43))
                        .background(Color(white: 0.08))
                }
            }.background(Color.black)
        }.preferredColorScheme(.dark).interactiveDismissDisabled()
            .task { model.start() }.onDisappear { model.stop() }
    }
    private var playback: some View {
        VStack(spacing: 0) {
            HStack {
                ForEach([false, true], id: \.self) { result in
                    Button(result ? "Preview" : "Frame") { model.showReview(result) }
                        .font(.subheadline.weight(.semibold)).padding(.horizontal, 12).frame(minHeight: 44)
                        .background(model.reviewing == result ? Color.white.opacity(0.14) : .clear, in: Capsule())
                        .accessibilityAddTraits(model.reviewing == result ? .isSelected : [])
                        .accessibilityIdentifier(result ? "crop.preview" : "crop.frame")
                }
                Spacer(minLength: 0)
                if model.reviewing || model.endpoint != nil {
                    Button { model.togglePlay() } label: { Image(systemName: model.playing ? "pause.fill" : "play.fill").frame(width: 48, height: 44) }
                        .disabled(model.busy).accessibilityLabel(model.playing ? "Pause crop preview" : "Play crop preview")
                }
                if model.clips.count > 1 {
                    Button { model.stepClip(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }.disabled(model.active?.index == 0).accessibilityLabel("Previous crop clip")
                    Text("\((model.active?.index ?? 0) + 1)/\(model.clips.count)").font(.caption.monospacedDigit())
                    Button { model.stepClip(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }.disabled(model.active?.index == model.clips.count - 1).accessibilityLabel("Next crop clip")
                }
            }
            HStack {
                Text(editorTime(model.position)).font(.caption.monospacedDigit()).lineLimit(1).fixedSize()
                Slider(value: Binding(get: { model.position }, set: model.seek), in: 0...max(TimelineEditing.frame, model.duration - TimelineEditing.frame)).accessibilityLabel("Crop preview position")
                Text(editorTime(model.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            }.frame(minHeight: 44)
        }
    }
    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            EffectAnimationControls(motion:model.animation,endpoint:model.endpoint,duration:model.duration,select:model.selectEndpoint,remove:model.removeAnimation,done:model.finishEndpoint,update:model.updateTiming)
            if let error = model.error {
                Text(error).font(.callout).foregroundStyle(.orange)
                Button("Retry") { model.retry() }.frame(minHeight: 44)
            }
            Menu {
                ForEach(OutputShape.allCases) { shape in Button(shape.title) { model.setShape(shape) } }
            } label: {
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Video shape").font(.subheadline)
                        HStack { Text(model.shapeTitle); Spacer(); Image(systemName: "chevron.up.chevron.down") }
                        Text("Whole project").font(.caption).foregroundStyle(.secondary)
                    }.frame(minHeight: 48)
                } else {
                    HStack {
                        Image(systemName: "aspectratio")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Video shape"); Text("Whole project").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(); Text(model.shapeTitle).lineLimit(1); Image(systemName: "chevron.up.chevron.down").font(.caption)
                    }.frame(minHeight: 48)
                }
            }.disabled(!model.canApply).accessibilityIdentifier("crop.shape")
            Text(model.reviewing ? "Preview includes text and other video tools." : "Pinch to crop · drag to frame").font(.subheadline)
            if !model.reviewing {
                VStack(spacing: 0) {
                    HStack {
                        Text("Rotation").font(.subheadline)
                        Spacer()
                        Button { model.rotate(0) } label: {
                            Text("\(model.crop.rotation.formatted(.number.precision(.fractionLength(0...1))))°")
                                .font(.subheadline.monospacedDigit()).frame(minWidth: 52, minHeight: 44)
                        }.accessibilityLabel("Reset rotation").accessibilityValue("\(model.crop.rotation) degrees").accessibilityIdentifier("crop.rotationReset")
                        Button { model.rotate(model.crop.rotation + 90) } label: {
                            Image(systemName: "rotate.right").frame(width: 44, height: 44)
                        }.accessibilityLabel("Rotate 90 degrees clockwise").accessibilityIdentifier("crop.rotate90")
                    }
                    Slider(value: Binding(get: { model.crop.rotation }, set: model.rotate), in: -180...180, step: 0.1)
                        .accessibilityLabel("Crop rotation").accessibilityIdentifier("crop.rotation")
                    Text("Edges stay filled. Tap the angle to reset.").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }.disabled(!model.canApply)
                HStack {
                    Text("Zoom")
                    Slider(value: Binding(get: { model.crop.zoom }, set: { var value = model.crop; value.zoom = $0; model.adjust(value) }), in: 1...8).accessibilityLabel("Crop zoom")
                    Text("\(model.crop.zoom.formatted(.number.precision(.fractionLength(1))))×").monospacedDigit().lineLimit(1).fixedSize()
                }.font(.subheadline).frame(minHeight: 44).disabled(!model.canApply)
                HStack {
                    Button("Reset framing") { model.resetFraming() }.frame(minHeight: 44).accessibilityIdentifier("crop.reset")
                    Spacer()
                    let rect = model.crop.rect(source: model.sourceSize, canvas: model.canvas)
                    Text("\(Int(rect.width.rounded())) × \(Int(rect.height.rounded())) px").font(.caption.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.8).foregroundStyle(.secondary).accessibilityLabel("Source area \(Int(rect.width)) by \(Int(rect.height)) pixels")
                }.disabled(!model.canApply)
                DisclosureGroup("Position") {
                    HStack { Text("Across"); Slider(value: Binding(get: { model.crop.clamped(source: model.sourceSize, canvas: model.canvas).x }, set: { model.move(x: $0) }), in: model.positionRange(horizontal: true)).accessibilityLabel("Crop horizontal position")
                            .disabled(model.crop.footprint(source: model.sourceSize, canvas: model.canvas).width >= model.sourceSize.width - 0.001) }
                    HStack { Text("Down"); Slider(value: Binding(get: { model.crop.clamped(source: model.sourceSize, canvas: model.canvas).y }, set: { model.move(y: $0) }), in: model.positionRange(horizontal: false)).accessibilityLabel("Crop vertical position")
                            .disabled(model.crop.footprint(source: model.sourceSize, canvas: model.canvas).height >= model.sourceSize.height - 0.001) }
                }.disabled(!model.canApply)
            }
            Divider()
            Text("Video shape applies to the whole project. Other clips keep their full image unless cropped.").font(.caption).foregroundStyle(.secondary)
            if model.request.range.lowerBound > 0 || model.request.range.upperBound < model.project.edit.duration {
                Text("Framing changes instantly at the edges of this selection.").font(.caption).foregroundStyle(.secondary)
            }
            if model.clips.count > 1 { Text("Framing changes apply to all \(model.clips.count) selected clips. Check each with the arrows.").font(.caption).foregroundStyle(.secondary) }
        }
    }
}

private struct CropCanvas: UIViewRepresentable {
    let image: UIImage?
    let source: CGSize
    let canvas: CGSize
    let texts: [TextOverlay]
    let crop: CropSettings
    var poses: [UUID:TitleMotion.Pose] = [:]
    var mirror: MirrorSettings? = nil
    var images: [(ImageOverlay, UIImage)] = []
    let folder: URL
    let changed: (CropSettings) -> Void
    func makeUIView(context: Context) -> CropSurface { CropSurface() }
    func updateUIView(_ view: CropSurface, context: Context) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        view.image = image; view.source = source; view.canvas = canvas; view.crop = crop; view.changed = changed
        view.mirror = mirror; view.setImages(images)
        view.titlePoses = poses; view.setTitles(texts, folder: folder); view.updateLayers()
        CATransaction.commit()
    }
}

private final class CropSurface: UIView, UIGestureRecognizerDelegate {
    var image: UIImage? { didSet { if image !== oldValue { imageLayer.contents = image?.cgImage } } }
    var source = CGSize(width: 1920, height: 1080)
    var canvas = CGSize(width: 1920, height: 1080)
    var crop = CropSettings()
    var mirror: MirrorSettings?
    private var overlays: [(ImageOverlay, CALayer, CGSize)] = []
    private var overlayValues: [ImageOverlay] = []
    var changed: (CropSettings) -> Void = { _ in }
    private let imageLayer = CALayer()
    private let dimLayer = CAShapeLayer()
    private let borderLayer = CAShapeLayer()
    private let gridLayer = CAShapeLayer()
    private let titleContainer = CALayer()
    var titlePoses: [UUID:TitleMotion.Pose] = [:]
    private var titleImages: [(TextOverlay, CALayer, CGSize)] = []
    private var titles: [TextOverlay] = []
    private var titleCanvas = CGSize.zero
    private var previousWindow = CGRect.zero
    private lazy var pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
    private var gestureCrop = CropSettings()
    private var sourceAnchor = CGPoint.zero
    private var pinchBase = CGFloat(1)
    private var pinchTouches = 0
    private var panNeedsAnchor = true
    private var panOrigin = CGPoint.zero
    private var panCrop = CropSettings()
    private var cropWindow: CGRect { AVMakeRect(aspectRatio: canvas, insideRect: bounds.insetBy(dx: 20, dy: 20)) }
    private func imageTransform(_ value: CropSettings) -> CGAffineTransform {
        let window = cropWindow, scale = window.width/max(1, canvas.width)
        return value.transform(source: source, canvas: canvas)
            .concatenating(mirror?.transform(canvas: canvas) ?? .identity)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: window.minX, y: window.minY))
    }
    private func sourceDelta(_ point: CGPoint, crop: CropSettings) -> CGPoint {
        var linear = imageTransform(crop); linear.tx = 0; linear.ty = 0
        return point.applying(linear.inverted())
    }
    override init(frame: CGRect) {
        super.init(frame: frame); backgroundColor = .black; clipsToBounds = true
        for item in [imageLayer, dimLayer, borderLayer, gridLayer, titleContainer] { layer.addSublayer(item) }
        imageLayer.contentsGravity = .resize
        dimLayer.fillColor = UIColor.black.withAlphaComponent(0.65).cgColor; dimLayer.fillRule = .evenOdd
        borderLayer.fillColor = nil; borderLayer.strokeColor = UIColor.white.cgColor; borderLayer.lineWidth = 1.5
        gridLayer.fillColor = nil; gridLayer.strokeColor = UIColor.white.withAlphaComponent(0.3).cgColor; gridLayer.lineWidth = 0.5
        titleContainer.masksToBounds = true
        pinch.delegate = self; pan.delegate = self; pan.maximumNumberOfTouches = 2
        addGestureRecognizer(pinch); addGestureRecognizer(pan)
        isAccessibilityElement = true; accessibilityIdentifier = "crop.canvas"; accessibilityLabel = "Crop framing"
        accessibilityTraits = [.adjustable]
        accessibilityHint = "Pinch to crop and drag to position. Zoom and position controls are also below."
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func setImages(_ values: [(ImageOverlay, UIImage)]) {
        guard values.map({ $0.0 }) != overlayValues else { return }
        overlayValues = values.map { $0.0 }; overlays.forEach { $0.1.removeFromSuperlayer() }
        overlays = values.map { value, image in
            let picture = CALayer(); picture.contents = image.cgImage; picture.opacity = Float(value.opacity)
            titleContainer.insertSublayer(picture, at: 0)
            return (value, picture, image.size)
        }
    }
    func setTitles(_ values: [TextOverlay], folder: URL) {
        guard values != titles || titleCanvas != canvas else { return }
        titles = values; titleCanvas = canvas
        titleImages.forEach { $0.1.removeFromSuperlayer() }
        titleImages = values.compactMap { value in
            guard let bitmap = TextRasterizer.image(value, canvas: canvas, folder: folder) else { return nil }
            let title = CALayer(); title.contents = bitmap; titleContainer.addSublayer(title)
            return (value, title, CGSize(width: bitmap.width, height: bitmap.height))
        }
    }
    override func layoutSubviews() { super.layoutSubviews(); updateLayers() }
    func updateLayers() {
        guard bounds.width > 40, bounds.height > 40, canvas.width > 0, canvas.height > 0 else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        dimLayer.frame = bounds; borderLayer.frame = bounds; gridLayer.frame = bounds
        let window = cropWindow, matrix = imageTransform(crop)
        imageLayer.setAffineTransform(.identity); imageLayer.bounds = CGRect(origin: .zero, size: source)
        imageLayer.position = CGPoint(x: source.width/2, y: source.height/2).applying(matrix)
        imageLayer.setAffineTransform(CGAffineTransform(a: matrix.a, b: matrix.b, c: matrix.c, d: matrix.d, tx: 0, ty: 0))
        if window != previousWindow {
            previousWindow = window
            let outside = UIBezierPath(rect: bounds); outside.append(UIBezierPath(rect: window))
            dimLayer.path = outside.cgPath; borderLayer.path = UIBezierPath(rect: window).cgPath
            let grid = UIBezierPath()
            for fraction in [CGFloat(1 / 3.0), CGFloat(2 / 3.0)] {
                grid.move(to: CGPoint(x: window.minX + window.width * fraction, y: window.minY)); grid.addLine(to: CGPoint(x: window.minX + window.width * fraction, y: window.maxY))
                grid.move(to: CGPoint(x: window.minX, y: window.minY + window.height * fraction)); grid.addLine(to: CGPoint(x: window.maxX, y: window.minY + window.height * fraction))
            }
            gridLayer.path = grid.cgPath
        }
        titleContainer.frame = window
        let textScale = window.width / canvas.width
        for (overlay, layer, size) in overlays {
            let rect = overlay.rect(image: size, canvas: canvas)
            layer.frame = CGRect(x: rect.minX * textScale, y: (canvas.height - rect.maxY) * textScale, width: rect.width * textScale, height: rect.height * textScale)
        }
        for (title, bitmap, size) in titleImages {
            let origin = TextRasterizer.origin(title, imageSize: size, canvas: canvas)
            let pose = titlePoses[title.id] ?? TitleMotion.Pose()
            bitmap.contentsRect = CGRect(x:pose.left,y:pose.top,width:pose.right-pose.left,height:pose.bottom-pose.top)
            bitmap.opacity = Float(pose.opacity)
            bitmap.frame = pose.rect(CGRect(x:origin.x*textScale, y:(canvas.height-origin.y-size.height)*textScale,
                                            width:size.width*textScale, height:size.height*textScale))
        }
        CATransaction.commit()
        let visible = crop.clamped(source: source, canvas: canvas)
        accessibilityValue = String(format: "Rotation %.1f degrees, Zoom %.1f times, centre %.0f percent from left, %.0f percent from top", crop.rotation, crop.zoom, visible.x * 100, visible.y * 100)
    }
    private func update(_ value: CropSettings, clampX: Bool = false, clampY: Bool = false) {
        crop = value; crop.x = min(1, max(0, crop.x)); crop.y = min(1, max(0, crop.y)); crop.zoom = min(8, max(1, crop.zoom))
        let visible = crop.clamped(source: source, canvas: canvas)
        if clampX { crop.x = visible.x }
        if clampY { crop.y = visible.y }
        updateLayers(); changed(crop)
    }
    override func accessibilityIncrement() { var value = crop; value.zoom *= 1.1; update(value) }
    override func accessibilityDecrement() { var value = crop; value.zoom /= 1.1; update(value) }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        (gestureRecognizer === pinch && otherGestureRecognizer === pan) || (gestureRecognizer === pan && otherGestureRecognizer === pinch)
    }
    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        guard image != nil else { return }
        guard (gesture.state == .began || gesture.state == .changed), gesture.numberOfTouches >= 2 else {
            pinchTouches = 0; panNeedsAnchor = true; return
        }
        let point = gesture.location(in: self)
        if gesture.state == .began || pinchTouches != gesture.numberOfTouches {
            gestureCrop = crop.clamped(source: source, canvas: canvas); pinchBase = gesture.scale
            sourceAnchor = point.applying(imageTransform(gestureCrop).inverted())
        }
        pinchTouches = gesture.numberOfTouches; panNeedsAnchor = true
        var value = gestureCrop; value.zoom = min(8, max(1, gestureCrop.zoom * gesture.scale / max(0.001, pinchBase)))
        let delta = sourceDelta(CGPoint(x: point.x-cropWindow.midX, y: point.y-cropWindow.midY), crop: value)
        value.x = (sourceAnchor.x-delta.x)/source.width
        value.y = (sourceAnchor.y-delta.y)/source.height
        update(value, clampX: true, clampY: true)
    }
    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        guard image != nil, gesture.numberOfTouches == 1, pinch.numberOfTouches < 2 else { panNeedsAnchor = true; return }
        let translation = gesture.translation(in: self)
        if gesture.state == .began || panNeedsAnchor {
            panCrop = crop; panOrigin = translation; panNeedsAnchor = false
        }
        let screenDelta = CGPoint(x: translation.x-panOrigin.x, y: translation.y-panOrigin.y)
        guard hypot(screenDelta.x, screenDelta.y) >= 8 else { return }
        let delta = sourceDelta(screenDelta, crop: panCrop)
        let visible = panCrop.clamped(source: source, canvas: canvas)
        var value = panCrop
        let movedX = abs(delta.x) > 0.000001, movedY = abs(delta.y) > 0.000001
        if movedX { value.x = visible.x-delta.x/source.width }
        if movedY { value.y = visible.y-delta.y/source.height }
        update(value, clampX: movedX, clampY: movedY)
    }
}

#if DEBUG
enum CropDiagnostics {
    @MainActor static func run() async {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = documents.appendingPathComponent("CropTest", isDirectory: true)
        var report: [String: Any] = [:]
        func check(_ value: Bool, _ message: String) throws {
            if !value { throw NSError(domain: "YouRecCropQA", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func wait(_ workspace: CropWorkspace) async throws {
            for _ in 0..<600 where workspace.busy { try await Task.sleep(for: .milliseconds(100)) }
            try check(!workspace.busy && workspace.error == nil, workspace.error ?? "Crop preparation timed out")
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let input = folder.appendingPathComponent("shake.mp4")
            if !FileManager.default.fileExists(atPath: input.path) { try FileManager.default.copyItem(at: documents.appendingPathComponent("StabilizationTest/shake.mp4"), to: input) }
            let duration = try await AVURLAsset(url: input).load(.duration).seconds
            var project = Project(title: "Crop hardware diagnostic"); project.append(SourceMedia(filename: "shake.mp4", duration: duration))
            var edit = project.edit
            edit.clips[0].texts = [TextOverlay(text: "Crop QA", start: 0, end: duration, x: 0.5, y: 0.25, size: 0.08, style: .box, color: .yellow)]
            edit.clips[0].color = ColorSettings(look: .warm, amount: 0.6)
            edit.clips[0].stabilization = edit.clips[0].stabilizing(.light); project.commit(edit)
            let request = ToolRequest(tool: .crop, range: 1...3, scopeTitle: "Selected range")
            let model = CropWorkspace(project: project, folder: folder, request: request, position: 2)
            model.start(); try await wait(model)
            try check(model.picture != nil && abs(model.position - 1) < 0.001, "Range workspace opens at the current frame")
            try check(model.state() == project.edit, "A neutral range crop left splits or output settings behind")
            model.showReview(true); try await wait(model)
            model.showReview(false); try await wait(model)
            model.setShape(.portrait); model.adjust(CropSettings(x: 0.7, y: 0.4, zoom: 1.7, rotation: 17))
            model.showReview(true); try await wait(model)
            let state = model.state(); try check(state.clips.count == 3, "Range crop isolates only its boundaries")
            let framing = model.frame!, framingCrop = model.crop
            try check(state.clips[0].crop == nil && state.clips[1].crop != nil && state.clips[2].crop == nil, "Crop touched footage outside the selection")
            try check(state.outputSize == CGSize(width: 1080, height: 1920), "Crop shape did not pin vertical output")
            project.commit(state); try project.validate(); model.stop()
            let reopened = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project)); try reopened.validate()
            try check(reopened.edit == state, "Crop lost state on reopening")
            let cropID = state.clips[1].crop!.id
            let existing = CropWorkspace(project: reopened, folder: folder, request: ToolRequest(tool: .crop, range: 1...3, scopeTitle: "Existing crop", effectID: cropID, clipIDs: [state.clips[1].id]), position: 2)
            existing.start(); try await wait(existing)
            try check(existing.state() == state, "Opening and applying an unchanged crop creates an edit")
            let removed = existing.state(removing: true)
            try check(removed.clips.allSatisfy { $0.crop == nil } && removed.outputSize == state.outputSize, "Remove crop changes the committed output shape")
            existing.stop()
            // Changing zoom must preserve a shared preferred centre, even when
            // the current clip has less room to pan than another orientation.
            let portraitURL = folder.appendingPathComponent("portrait.mov")
            if !FileManager.default.fileExists(atPath: portraitURL.path) {
                let sourceAsset = AVURLAsset(url: input)
                let sourceTrack = try await sourceAsset.loadTracks(withMediaType: .video).first!
                let composition = AVMutableComposition(), track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
                try track.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 60000)), of: sourceTrack, at: .zero)
                track.preferredTransform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
                let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)!
                exporter.outputURL = portraitURL; exporter.outputFileType = .mov
                await exporter.export(); try check(exporter.status == .completed, "Portrait test fixture failed")
            }
            var mixed = Project(title: "Crop geometry QA")
            mixed.append(SourceMedia(filename: "shake.mp4", duration: duration)); mixed.append(SourceMedia(filename: "portrait.mov", duration: duration))
            let mixedModel = CropWorkspace(project: mixed, folder: folder, request: ToolRequest(tool: .crop, range: 0...mixed.edit.duration, scopeTitle: "Both orientations"), position: duration + 1)
            mixedModel.start(); try await wait(mixedModel)
            mixedModel.adjust(CropSettings(y: 0.25)); mixedModel.stepClip(-1)
            while mixedModel.busy {
                if let frame = mixedModel.frame { try check(abs(frame.image.size.width / frame.image.size.height - frame.size.width / frame.size.height) < 0.001, "A frame was paired with another clip's geometry") }
                try await Task.sleep(for: .milliseconds(30))
            }
            try check(mixedModel.error == nil, mixedModel.error ?? "Mixed orientation load failed")
            var closer = mixedModel.crop; closer.zoom = 1.2; mixedModel.adjust(closer)
            try check(mixedModel.state().clips.allSatisfy { abs(($0.crop?.y ?? 0) - 0.25) < 0.00001 }, "Zooming on landscape moved the portrait framing centre")
            mixedModel.move(x: -1)
            try check(abs(mixedModel.crop.x - (1 / 2.4)) < 0.00001 && mixedModel.crop.y == 0.25, "Moving across an edge stored an invisible position or changed the other axis")
            mixedModel.setShape(.portrait)
            try check(abs(mixedModel.crop.clamped(source: mixedModel.sourceSize, canvas: mixedModel.canvas).x - (1 / 2.4)) < 0.00001, "A shape change revealed an unseen position")
            mixedModel.stop()
            let missingURL = folder.appendingPathComponent("retry-source.mp4")
            try? FileManager.default.removeItem(at: missingURL)
            var retryProject = mixed; retryProject.sources[0].filename = missingURL.lastPathComponent
            let retryModel = CropWorkspace(project: retryProject, folder: folder, request: ToolRequest(tool: .crop, range: duration...(duration * 2), scopeTitle: "Second clip"), position: duration + 1)
            retryModel.start()
            for _ in 0..<100 where retryModel.busy { try await Task.sleep(for: .milliseconds(50)) }
            try check(retryModel.error != nil && retryModel.originalCanvas == nil && !retryModel.canApply, "Missing geometry enabled Apply with a placeholder")
            try FileManager.default.copyItem(at: input, to: missingURL)
            retryModel.retry(); try await wait(retryModel)
            try check(retryModel.originalCanvas == CGSize(width: 1920, height: 1080) && retryModel.canApply, "Retry did not reload the original canvas")
            retryModel.stop()
            let output = folder.appendingPathComponent("crop-" + UUID().uuidString + ".mp4"), started = Date()
            _ = try await MediaRenderer.render(project: reopened, folder: folder, destination: output) { _ in }
            let asset = AVURLAsset(url: output), exported = try await asset.load(.duration).seconds
            let video = try await asset.loadTracks(withMediaType: .video).first!, size = try await video.load(.naturalSize)
            try check(abs(exported - duration) < 0.05 && size == CGSize(width: 1080, height: 1920), "Export dimensions or duration differ from crop preview")
            let generator = AVAssetImageGenerator(asset: asset); generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            let image = try await generator.image(at: CMTime(seconds: 2, preferredTimescale: 60000)).image
            try UIImage(cgImage: image).pngData()?.write(to: folder.appendingPathComponent("frame.png"))
            let surface = CropSurface(frame: CGRect(x: 0, y: 0, width: 400, height: 680))
            surface.image = framing.image; surface.source = framing.size; surface.canvas = CGSize(width: 1080, height: 1920)
            surface.crop = framingCrop; surface.setTitles(framing.texts, folder: folder); surface.layoutIfNeeded(); surface.updateLayers()
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
            let snapshot = UIGraphicsImageRenderer(size: surface.bounds.size, format: format).image { surface.layer.render(in: $0.cgContext) }
            let previewImage = snapshot.cgImage!.cropping(to: CGRect(x: 20, y: 20, width: 360, height: 640))!
            let expectedImage = UIGraphicsImageRenderer(size: CGSize(width: 360, height: 640), format: format).image { _ in UIImage(cgImage: image).draw(in: CGRect(x: 0, y: 0, width: 360, height: 640)) }.cgImage!
            func pixels(_ image: CGImage) -> [UInt8] {
                var values = [UInt8](repeating: 0, count: image.width * image.height * 4)
                values.withUnsafeMutableBytes { buffer in
                    let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                }
                return values
            }
            let a = pixels(previewImage), b = pixels(expectedImage)
            let framingError = zip(a, b).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(a.count)
            try snapshot.pngData()?.write(to: folder.appendingPathComponent("framing.png"))
            try check(framingError < 8, "Framing canvas differs from actual export: \(framingError)")
            report = ["success": true, "duration": exported, "width": size.width, "height": size.height,
                      "renderSeconds": Date().timeIntervalSince(started), "output": output.lastPathComponent,
                      "audioTracks": try await asset.loadTracks(withMediaType: .audio).count,
                      "selectedRange": true, "previewBeforeEdit": true, "reopenAndRemove": true, "neutralRangeUnchanged": true,
                      "mixedGeometryCentrePreserved": true, "edgePositionRemainsVisible": true, "atomicFrameGeometry": true, "geometryRetry": true, "framingPixelError": framingError]
        } catch { report = ["success": false, "error": error.localizedDescription] }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: folder.appendingPathComponent("report.json"), options: .atomic) }
    }
}
#endif
