import SwiftUI
import AVFoundation

@MainActor
final class StabilizationPreview: ObservableObject {
    let player = AVPlayer()
    @Published var level: StabilizationLevel
    @Published var original = false
    @Published var analyzing = false
    @Published var updating = false
    @Published var progress = 0.0
    @Published var position = 0.0
    @Published var playing = false
    @Published var ready = false
    @Published var plan: StabilizationPlan?
    @Published var error: String?
    private var analysis: StabilizationAnalysis?
    private var originalItem: AVPlayerItem?
    private var originalComposition: AVVideoComposition?
    private var stabilizedComposition: AVVideoComposition?
    private var compositions: [StabilizationLevel: (AVVideoComposition, StabilizationPlan)] = [:]
    private var measureJob: Task<Void, Never>?
    private var previewJob: Task<Void, Never>?
    private var observer: Any?
    private var itemStatus: NSKeyValueObservation?
    private var revision = UUID()
    private var initialProject: Project?
    private var folder: URL?
    private var scrubbing = false
    private var seeking = false
    private var pendingSeek: Double?
    private let awakeReason = "stabilization-" + UUID().uuidString
    private var background: UIBackgroundTaskIdentifier = .invalid
    let clip: TimelineClip
    var canApply: Bool { !updating && (level == .off || (ready && plan != nil)) && error == nil }
    var hasChanges: Bool { level != (clip.stabilization?.level ?? .off) }

    init(clip: TimelineClip) {
        self.clip = clip
        level = clip.stabilization?.level ?? .standard
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 15), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.playing = self.player.rate > 0
                if !self.scrubbing, time.seconds.isFinite { self.position = min(self.clip.duration, max(0, time.seconds)) }
                if self.playing && time.seconds >= self.clip.duration - 0.04 {
                    self.player.seek(to: .zero); self.player.play()
                }
            }
        }
    }
    deinit { if let observer { player.removeTimeObserver(observer) }; measureJob?.cancel(); previewJob?.cancel() }

    func start(project: Project, folder: URL, at time: Double) {
        guard initialProject == nil else { return }
        var candidate = project
        var edit = project.edit; edit.clips = [clip]; edit.effects = []
        candidate.commit(edit)
        initialProject = candidate; self.folder = folder
        position = min(max(0, time), max(0, clip.duration - 1 / 30))
        measureJob = Task {
            do {
                let media = try await MediaRenderer.timeline(project: candidate, folder: folder, stabilization: false,effectPreparation:.cached)
                try Task.checkCancellation()
                let item = AVPlayerItem(asset: media.composition); item.videoComposition = media.playbackVideoComposition; item.audioMix = media.audioMix
                item.seekingWaitsForVideoCompositionRendering = true
                itemStatus = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                    Task { @MainActor in
                        if item.status == .failed { self?.error = item.error?.localizedDescription ?? "The video preview could not be displayed." }
                    }
                }
                originalItem = item; originalComposition = item.videoComposition; install(item)
                if level == .off { ready = true }
                else { measure() }
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    func choose(_ value: StabilizationLevel) {
        guard value != level else { return }
        level = value; error = nil
        UISelectionFeedbackGenerator().selectionChanged()
        if value == .off {
            revision = UUID(); previewJob?.cancel(); updating = false; ready = originalItem != nil
            plan = nil; display(originalComposition)
        } else if analysis != nil { updatePreview() }
        else if !analyzing && originalItem != nil { measure() }
    }
    func retry() { error = nil; if analysis != nil { updatePreview() } else { measure() } }
    private func measure() {
        guard let project = initialProject, let folder, let source = project.sources.first(where: { $0.id == clip.sourceID }), !analyzing else { return }
        analyzing = true; progress = 0; ready = false
        RecordingAppDelegate.keepAwake(awakeReason, active: true)
        background = UIApplication.shared.beginBackgroundTask(withName: "Analyze video motion") { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.background != .invalid { UIApplication.shared.endBackgroundTask(self.background); self.background = .invalid }
                self.measureJob?.cancel()
                self.error = "Analysis paused in the background. Tap Retry to start again."
            }
        }
        measureJob = Task {
            defer {
                analyzing = false; RecordingAppDelegate.keepAwake(awakeReason, active: false)
                if background != .invalid { UIApplication.shared.endBackgroundTask(background); background = .invalid }
            }
            do {
                analysis = try await VideoStabilizer.shared.analysis(source: source, clip: clip, folder: folder) { value in
                    Task { @MainActor [weak self] in self?.progress = value }
                }
                try Task.checkCancellation()
                if level != .off { updatePreview() } else { ready = true }
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    private func updatePreview() {
        guard let analysis, var candidate = initialProject, let folder else { return }
        previewJob?.cancel(); let token = UUID(); revision = token
        let selectedLevel = level
        if let (composition, cachedPlan) = compositions[selectedLevel] {
            stabilizedComposition = composition; plan = cachedPlan; ready = true; updating = false
            if !original { display(composition) }
            return
        }
        updating = true; ready = false
        display(originalComposition)
        var edit = candidate.edit; edit.clips[0].stabilization = clip.stabilizing(selectedLevel); candidate.commit(edit)
        previewJob = Task {
            defer { if token == revision { updating = false } }
            do {
                let computation = Task.detached(priority: .userInitiated) { try StabilizationPath.make(analysis, level: selectedLevel) }
                let result = try await withTaskCancellationHandler(operation: { try await computation.value }, onCancel: { computation.cancel() })
                let media = try await MediaRenderer.timeline(project: candidate, folder: folder, stabilizationPlans: [clip.id: result],effectPreparation:.cached)
                try Task.checkCancellation(); guard token == revision else { return }
                stabilizedComposition = media.videoComposition; plan = result; ready = true
                compositions[selectedLevel] = (media.videoComposition, result)
                if !original { display(media.videoComposition) }
            } catch is CancellationError {} catch { if token == revision { self.error = error.localizedDescription } }
        }
    }
    private func display(_ composition: AVVideoComposition?) {
        guard let item = player.currentItem else { return }
        // A fresh composition also invalidates a paused frame (Apple QA1966).
        item.videoComposition = composition?.mutableCopy() as? AVVideoComposition
        // The player keeps its timeline and audio running during comparison.
        // A paused player needs an exact seek to redraw the current frame.
        if player.rate == 0 { seek(position) }
    }
    private func install(_ item: AVPlayerItem) {
        guard player.currentItem !== item else { return }
        let resume = playing || player.rate > 0
        player.pause(); player.replaceCurrentItem(with: item)
        let time = position
        player.seek(to: CMTime(seconds: time, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak item] success in
            Task { @MainActor in
                guard let self, self.player.currentItem === item else { return }
                if success && resume { self.player.play(); self.playing = true }
            }
        }
    }
    func compare(original: Bool) {
        self.original = original
        if original || level == .off { display(originalComposition) }
        else if ready { display(stabilizedComposition) }
    }
    func togglePlay() {
        if playing {
            player.pause(); playing = false
            let current = player.currentTime().seconds
            if current.isFinite { position = min(clip.duration, max(0, current)) }
        }
        else {
            if position >= clip.duration - 0.04 { seek(0) }
            player.play(); playing = true
        }
    }
    func seek(_ value: Double) {
        position = min(clip.duration, max(0, value))
        pendingSeek = position; performSeek()
    }
    private func performSeek() {
        guard !seeking, let time = pendingSeek else { return }
        pendingSeek = nil; seeking = true
        let tolerance = scrubbing ? CMTime(seconds: 0.06, preferredTimescale: 60000) : .zero
        player.seek(to: CMTime(seconds: time, preferredTimescale: 60000), toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.seeking = false; self.performSeek()
            }
        }
    }
    func scrub(_ active: Bool) {
        scrubbing = active
        if active { player.pause(); playing = false }
        else { seek(position) }
    }
    func stop() {
        revision = UUID(); measureJob?.cancel(); previewJob?.cancel(); player.pause(); player.replaceCurrentItem(with: nil)
        RecordingAppDelegate.keepAwake(awakeReason, active: false)
    }
}

struct StabilizationEditor: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let project: Project
    let clip: TimelineClip
    let folder: URL
    let initialTime: Double
    let cancel: () -> Void
    let apply: (StabilizationLevel) -> Void
    @StateObject private var preview: StabilizationPreview
    @State private var settingsHeight: CGFloat = 260
    init(project: Project, clip: TimelineClip, folder: URL, initialTime: Double,
         cancel: @escaping () -> Void, apply: @escaping (StabilizationLevel) -> Void) {
        self.project = project; self.clip = clip; self.folder = folder; self.initialTime = initialTime
        self.cancel = cancel; self.apply = apply
        _preview = StateObject(wrappedValue: StabilizationPreview(clip: clip))
    }
    private var clipNumber: Int { (project.edit.clips.firstIndex(where: { $0.id == clip.id }) ?? 0) + 1 }
    private var timeRange: String {
        let start = TimelineEditing.offset(of: clip.id, in: project.edit)
        func label(_ t: Double) -> String { let s = max(0, Int(t.rounded())); return String(format: "%d:%02d", s / 60, s % 60) }
        return label(start) + "–" + label(start + clip.duration)
    }
    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            VStack(spacing: 0) {
                HStack {
                    Button(action: cancel) { Text("Cancel").frame(minWidth: 52, minHeight: 44).contentShape(Rectangle()) }
                        .accessibilityIdentifier("stabilization.cancel")
                    Spacer(minLength: 4)
                    VStack(spacing: 2) {
                        Text("Stabilize").font(.headline)
                        Text("Clip \(clipNumber) · \(timeRange)").font(.caption).foregroundStyle(.secondary)
                    }.accessibilityElement(children: .combine)
                    Spacer(minLength: 4)
                    Button { if preview.hasChanges { apply(preview.level) } else { cancel() } } label: {
                        Text(preview.hasChanges ? "Apply" : "Done").font(.body.weight(.semibold)).frame(minWidth: 52, minHeight: 44).contentShape(Rectangle())
                    }
                        .disabled(!preview.canApply).accessibilityIdentifier("stabilization.apply")
                }.padding(.horizontal, 16).padding(.vertical, 4)
                if landscape {
                    HStack(spacing: 0) {
                        movie.frame(maxWidth: .infinity, maxHeight: .infinity)
                        ScrollView { settings.padding(16) }
                            .frame(width: dynamicTypeSize.isAccessibilitySize ? min(geometry.size.width * 0.43, 340) : min(geometry.size.width * 0.35, 290))
                            .background(Color(white: 0.085))
                    }
                } else {
                    movie.frame(maxWidth: .infinity, maxHeight: .infinity)
                    ScrollView { settings.padding(16).background(GeometryReader { proxy in
                        Color.clear.preference(key: StabilizationSettingsHeight.self, value: proxy.size.height)
                    }) }
                        .onPreferenceChange(StabilizationSettingsHeight.self) { settingsHeight = $0 }
                        .frame(height: min(settingsHeight, dynamicTypeSize.isAccessibilitySize ? geometry.size.height * 0.48 : 300))
                        .background(Color(white: 0.085))
                }
            }
        }
        .background(.black).foregroundStyle(.white).tint(Color(red: 1, green: 0.3, blue: 0.34))
        .preferredColorScheme(.dark)
        .task { preview.start(project: project, folder: folder, at: initialTime) }
        .onDisappear { preview.stop() }
        .interactiveDismissDisabled()
    }
    private var movie: some View {
        VStack(spacing: 0) {
            PlayerSurface(player: preview.player, preserveInspection: true)
                .accessibilityIdentifier("stabilization.preview")
            HStack(spacing: 4) {
                comparisonButton("Original", original: true)
                comparisonButton("Stabilized", original: false)
            }.padding(4).frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? 320 : 250)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 13)).padding(.top, 6)
                .disabled(!preview.ready || preview.level == .off || preview.updating)
            HStack(spacing: 10) {
                Button { preview.togglePlay() } label: {
                    Image(systemName: preview.playing ? "pause.fill" : "play.fill").frame(width: 44, height: 44)
                }.accessibilityLabel(preview.playing ? "Pause stabilization preview" : "Play stabilization preview")
                Slider(value: Binding(get: { preview.position }, set: { preview.seek($0) }), in: 0...max(0.01, clip.duration), onEditingChanged: preview.scrub)
                    .accessibilityLabel("Clip position")
                Text(editorTime(preview.position)).font(.caption.monospacedDigit()).frame(minWidth: 46)
            }.padding(.horizontal, 10)
        }
    }
    private var settings: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Stabilization level").font(.subheadline.weight(.semibold))
                ViewThatFits(in: .horizontal) {
                    levelRow
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) { levelButtons }
                }
                Text(preview.level.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if preview.analyzing {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: preview.progress)
                    Text("Analyzing motion · \(Int(preview.progress * 100))%").font(.caption.monospacedDigit())
                    Text("You can watch the original while this runs.").font(.caption).foregroundStyle(.secondary)
                }.accessibilityIdentifier("stabilization.progress")
            } else if preview.updating {
                HStack { ProgressView(); Text("Updating preview…").font(.caption) }
            }
            if let error = preview.error {
                Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                Button("Retry") { preview.retry() }.frame(minHeight: 44)
            }
            if let plan = preview.plan, preview.level != .off, preview.ready {
                Label(plan.zoom < 1.001 ? "Full frame kept" : "Zoomed in \(plan.zoom.formatted(.number.precision(.fractionLength(2))))× to hide edges", systemImage: "crop")
                    .font(.caption.weight(.medium)).accessibilityIdentifier("stabilization.crop")
                if plan.trackingFraction < 0.65 {
                    Text("Some motion could not be tracked. Those sections keep their original movement.")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                } else if plan.strengthLimited {
                    Text("Smoothing is limited to keep more of your frame.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("Applies to this clip only. You can undo it in the editor.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var levelRow: some View { HStack(spacing: 6) { levelButtons }.fixedSize(horizontal: true, vertical: false) }
    private var levelButtons: some View {
        ForEach(StabilizationLevel.allCases) { level in
            Button { preview.choose(level) } label: {
                Text(level.title).font(.subheadline.weight(.semibold)).lineLimit(1).padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background(preview.level == level ? Color(red: 1, green: 0.3, blue: 0.34) : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
                    .foregroundStyle(preview.level == level ? .black : .white)
            }.accessibilityIdentifier("stabilization.level." + level.rawValue)
                .accessibilityAddTraits(preview.level == level ? .isSelected : [])
        }
    }
    private func comparisonButton(_ title: String, original: Bool) -> some View {
        let showingOriginal = preview.original || preview.level == .off || !preview.ready
        return Button { preview.compare(original: original) } label: {
            Text(title).font(.caption.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
                .background(showingOriginal == original ? Color.white.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 10))
        }.tint(.white).accessibilityIdentifier("stabilization.compare." + (original ? "original" : "stabilized"))
            .accessibilityAddTraits(showingOriginal == original ? .isSelected : [])
    }
}

private struct StabilizationSettingsHeight: PreferenceKey {
    static var defaultValue: CGFloat = 260
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
