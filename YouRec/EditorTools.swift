import SwiftUI
import AVKit
import PhotosUI
import ImageIO

extension VideoTool {
    var tint: Color { switch self { case .subtitles: return .cyan; case .text: return .purple; case .speed: return .blue; case .color: return .pink; case .stabilize: return .mint; case .pauses: return .white; case .crop: return .indigo; case .mirror: return .teal; case .image: return .orange; case .transition: return .orange; case .videoEffects: return .cyan; case .enhanceAudio, .volume, .addAudio, .censorAudio: return .mint; case .placement: return .orange; case .addVideo: return .cyan } }
}

struct ToolsPanel: View {
    private struct SettingHelp: Identifiable {
        let title: String
        let explanation: String
        var id: String { title }
    }
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var settingHelp: SettingHelp?
    @Binding var snapToCuts: Bool
    @Binding var matchListeningLevels: Bool
    let scope: String
    var overlayScope = "At playhead · duration below"
    let choose: (VideoTool) -> Void
    var regions: [ToolRegion] = []
    var insertionPosition = 0.0
    var canAdjust = true
    var hasVideo = true
    var hasAudio = true
    var canCensor = false
    var canTranscribe = true
    let selectCover: (() -> Void)?
    var edit: (ToolRegion) -> Void = { _ in }
    let close: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Add media at \(editorTime(insertionPosition))").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 10) { toolCard(.addVideo); toolCard(.addAudio) }
                    Button { selectCover?() } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "photo.on.rectangle.angled").font(.title3).foregroundStyle(.teal).frame(width: 28)
                            Text("Select cover").font(.subheadline.weight(.semibold))
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }.padding(.horizontal, 12).frame(minHeight: 48)
                            .background(Color.teal.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
                    }.buttonStyle(.plain).disabled(selectCover == nil).accessibilityIdentifier("tools.cover")
                        .accessibilityHint("Browse frames to share as a JPEG.")
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Overlays").font(.headline).accessibilityAddTraits(.isHeader)
                        Text(overlayScope).font(.caption).foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 10)], spacing: 10) {
                        ForEach([VideoTool.text, .image]) { toolCard($0) }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Adjust").font(.headline).accessibilityAddTraits(.isHeader)
                        Label(scope, systemImage: "rectangle.dashed").font(.caption).foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 10)], spacing: 10) {
                        ForEach([VideoTool.videoEffects, .stabilize, .crop, .mirror, .color, .speed, .pauses, .enhanceAudio, .censorAudio, .subtitles]) { toolCard($0) }
                    }
                }
                if !regions.isEmpty {
                    Text("In this project").font(.headline).accessibilityAddTraits(.isHeader)
                    ForEach(regions) { region in
                        Button { edit(region) } label: {
                            HStack {
                                Image(systemName: region.tool.symbol).foregroundStyle(region.tool.tint).frame(width: 26)
                                VStack(alignment: .leading) {
                                    Text(region.tool == .text ? region.label : region.tool.title + " · " + region.label).lineLimit(1)
                                    Text("Tap to edit or remove").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, minHeight: 48).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("tools.existing." + region.tool.rawValue)
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    Divider().overlay(.white.opacity(0.08))
                    Text("Settings").font(.headline).accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("tools.settings")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 240 : 145), spacing: 10)], spacing: 10) {
                        settingCard("Snap to cuts", symbol: "arrow.right.and.line.vertical.and.arrow.left", value: $snapToCuts,
                                    identifier: "tools.settings.snap", hint: "Align the playhead and selection marks with nearby clip boundaries.",
                                    explanation: "When you stop scrubbing near a clip boundary, the playhead snaps exactly to it. Selection marks also snap to nearby boundaries. Turn it off for free placement.\n\nThis applies to clip boundaries, not the cuts inside a Pauses effect.")
                        settingCard("Match listening levels", symbol: "speaker.wave.2", value: $matchListeningLevels,
                                    identifier: "tools.settings.matchLevels", hint: "Match Bypass and Enhanced volume inside Enhance audio. Exports are unchanged.",
                                    explanation: "Plays Bypass and Enhanced audio at similar volume in Enhance audio, so you can compare sound quality without the louder version seeming better.\n\nThis changes preview volume only. Exported audio keeps your filter gain. Matching is automatically suspended when an Output gain filter is enabled, so gain adjustments remain audible. Turn it off to hear actual levels for other filters too.")
                    }
                    NavigationLink {
                        FontLibraryView()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "textformat").frame(width: 28)
                            Text("Fonts").font(.subheadline.weight(.semibold))
                            Spacer(); Image(systemName: "chevron.right").font(.caption)
                        }.padding(.horizontal, 12).frame(minHeight: 48)
                            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                    }.buttonStyle(.plain).accessibilityIdentifier("tools.settings.fonts")
                        .accessibilityHint("Import and remove fonts for text and subtitles.")
                    Text("Touch and hold a setting for an explanation.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(20)
        }.accessibilityIdentifier("tools.content").background(Color(white: 0.06)).navigationTitle("Tools").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: close).frame(minHeight: 44) } }
        .preferredColorScheme(.dark)
            .alert(item: $settingHelp) { help in
                Alert(title: Text(help.title), message: Text(help.explanation), dismissButton: .default(Text("Got it")))
            }
    }
    private func toolCard(_ tool: VideoTool) -> some View {
        Button {
            if tool == .censorAudio && !canCensor {
                settingHelp = SettingHelp(title: "Mark the sound to censor", explanation: "In the timeline, use Mark start and Mark end around the word or sound, then open Censor audio. Select an audio item first to affect only that track; otherwise all audio in the marked range is censored.")
            } else { choose(tool) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: tool.symbol).font(.title3).foregroundStyle(tool.tint).frame(width: 28)
                Text(tool.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, minHeight: 54).padding(.horizontal, 12)
                .background(tool.tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.plain).disabled((!canAdjust && ![.addVideo, .addAudio].contains(tool)) || ([.enhanceAudio, .censorAudio].contains(tool) && !hasAudio) || (tool == .subtitles && !canTranscribe) || (![.addVideo, .addAudio, .censorAudio, .enhanceAudio, .subtitles].contains(tool) && !hasVideo)).accessibilityIdentifier("tools." + tool.rawValue).accessibilityHint(tool.detail)
    }
    private func settingCard(_ title: String, symbol: String, value: Binding<Bool>, identifier: String, hint: String, explanation: String) -> some View {
        Button {
            guard settingHelp == nil else { return }
            value.wrappedValue.toggle()
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: symbol).font(.title3).frame(width: 28)
                    Spacer(minLength: 4)
                    Label(value.wrappedValue ? "On" : "Off", systemImage: value.wrappedValue ? "checkmark.circle.fill" : "circle")
                        .font(.caption.weight(.semibold))
                }.foregroundStyle(value.wrappedValue ? Color.white : Color.secondary)
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading).fixedSize(horizontal: false, vertical: true)
            }.padding(12).frame(maxWidth: .infinity, minHeight: 98, alignment: .topLeading)
                .background(Color.white.opacity(value.wrappedValue ? 0.1 : 0.04), in: RoundedRectangle(cornerRadius: 14))
                .overlay { RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(value.wrappedValue ? 0.55 : 0.12), lineWidth: 1) }
                .contentShape(RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.plain)
            .highPriorityGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                settingHelp = SettingHelp(title: title, explanation: explanation)
                UISelectionFeedbackGenerator().selectionChanged()
            })
            .accessibilityLabel(title).accessibilityValue(value.wrappedValue ? "On" : "Off")
            .accessibilityHint(hint)
            .accessibilityAddTraits(.isToggle)
            .accessibilityAction(named: "Explain setting") { settingHelp = SettingHelp(title: title, explanation: explanation) }
            .accessibilityIdentifier(identifier)
    }
}

struct PauseChoice: Identifiable {
    let id = UUID()
    let clipID: UUID
    let raw: SourceInterval
    var interval: SourceInterval
    var enabled = true
}

@MainActor
final class ToolWorkspace: ObservableObject {
    let project: Project
    let folder: URL
    let request: ToolRequest
    let player = AVPlayer()
    @Published var level: StabilizationLevel = .standard
    @Published var rate = 1.0
    @Published var look: ColorLook = .natural
    @Published var amount = 1.0
    @Published var importedLUT: ImportedLUT?
    @Published var exposure = 0.0
    @Published var highlights = 0.0
    @Published var localRecovery = 0.0
    @Published private(set) var logSourceCount: Int?
    private var checkedColorSources = false
    @Published var warmth = 0.0
    @Published var tint = 0.0
    @Published var library = GradeLibrary.read()
    @Published var lookThumbnails: [String: UIImage] = [:]
    @Published var colorError: String?
    private var thumbnailJob: Task<Void, Never>?
    private var thumbnailGenerator: AVAssetImageGenerator?
    var colorSettings: ColorSettings { ColorSettings(id: effectID, look: look, amount: amount, imported: importedLUT, exposure: exposure, highlights: highlights, localRecovery: localRecovery, warmth: warmth, tint: tint) }
    @Published var text = TextOverlay()
    private var rasterKey: TextOverlay?
    private var rasterCanvas = CGSize.zero
    private var raster: CGImage?
    private var existingMotion: TitleMotion?
    private var existingTitleRange: ClosedRange<Double>?
    var titleMotionRange: ClosedRange<Double> {
        if start == request.range.lowerBound, end == request.range.upperBound, text.motion == existingMotion,
           let existingTitleRange { return existingTitleRange }
        return start...max(start, end)
    }
    func titleBitmap() -> CGImage? {
        var key = text
        key.x = 0.5; key.y = 0.5; key.motion = nil; key.start = 0; key.end = 0
        if key != rasterKey || canvas != rasterCanvas {
            raster = TextRasterizer.image(text, canvas: canvas, folder: folder)
            rasterKey = key; rasterCanvas = canvas
        }
        return raster
    }
    private var draftTiming: (range: ClosedRange<Double>, motion: TitleMotion?, clips: [UUID: ClosedRange<Double>], clocks: TitleMotionRanges)?
    func refreshTitlePreview(item: AVPlayerItem? = nil) {
        guard request.tool == .text, let item = item ?? player.currentItem,
              let composition = item.videoComposition?.mutableCopy() as? AVMutableVideoComposition else { return }
        if draftTiming?.range != scope || draftTiming?.motion != text.motion {
            let edit = state()
            var clips: [UUID: ClosedRange<Double>] = [:]
            for clip in edit.clips where request.clipIDs?.contains(clip.id) != false {
                if let title = clip.texts?.first(where: { $0.id == effectID }) {
                    clips[clip.id] = title.start...title.end
                }
            }
            draftTiming = (scope, text.motion, clips, TitleMotionRanges(edit))
        }
        guard let timing = draftTiming else { return }
        let bitmap = titleBitmap()
        for instruction in composition.instructions {
            for layer in instruction.toolLayers {
                if let range = timing.clips[layer.clip.id], let bitmap {
                    var title = text
                    title.start = range.lowerBound
                    title.end = range.upperBound
                    layer.previewTitle = .init(text: title, bitmap: bitmap, ranges: timing.clocks)
                } else {
                    layer.previewTitle = nil
                }
            }
        }
        // A fresh composition redraws the paused player without replacing or seeking its item.
        item.videoComposition = composition
    }
    func setTitleDesign(_ design: TitleDesign) {
        rasterKey = nil
        text.appearance = design
    }
    private let gradeRange: ClosedRange<Double>
    var playbackOrigin: Double { isOverlay ? start : request.tool == .color ? gradeRange.lowerBound : 0 }
    private var titleAuditionEnd: Double?
    func replayTitle(exit: Bool) {
        guard let motion = text.motion, !busy, !text.text.isEmpty else { return }
        let clock = titleMotionRange
        let window = motion.previewWindow(exit: exit, duration: clock.upperBound - clock.lowerBound)
        let from = max(0, min(duration, clock.lowerBound + window.lowerBound - start))
        let to = max(0, min(duration, clock.lowerBound + window.upperBound - start))
        guard to > from else { return }
        seek(from, playThrough: to)
    }
    @Published var mirror = MirrorSettings()
    @Published var image = ImageOverlay(filename: "")
    @Published var endpoint: EffectEndpoint?
    private var previewEndpoint: EffectEndpoint?
    @Published var animation: EffectAnimation?
    private var lastEndpoint: EffectEndpoint = .a
    private var endpointPose: EffectPose { request.tool == .image ? image.pose : colorSettings.pose }
    private var motionDuration: Double { request.tool == .image ? end - start : gradeRange.upperBound - gradeRange.lowerBound }
    private var capturedAnimation: EffectAnimation? {
        guard var motion = animation else { return nil }
        motion[endpoint ?? lastEndpoint] = endpointPose
        motion.duration = motionDuration
        return motion
    }
    private func loadPose(_ p: EffectPose) {
        if request.tool == .image { image = image.applying(p); return }
        let grade = colorSettings.applying(p)
        look = grade.look; amount = grade.amount; importedLUT = grade.imported
        exposure = grade.exposure ?? 0; highlights = grade.highlights ?? 0; localRecovery = grade.localRecovery ?? 0
        warmth = grade.warmth ?? 0; tint = grade.tint ?? 0
    }
    func selectEndpoint(_ e: EffectEndpoint) {
        let motion = capturedAnimation ?? EffectAnimation(endpointPose,duration:motionDuration)
        animation = motion; endpoint = e; lastEndpoint = e
        loadPose(motion[e]); returnToEndpoint(); if request.tool == .color { rebuild(delay:false) }
    }
    func adjustedEndpoint() {
        if animation != nil && previewEndpoint == nil {
            endpoint = lastEndpoint
            returnToEndpoint()
        }
    }
    func finishEndpoint() { animation = capturedAnimation; endpoint = nil; previewEndpoint = nil }
    func removeAnimation() {
        animation = nil; endpoint = nil; previewEndpoint = nil; image.motion = nil
        if request.tool == .color { rebuild(delay:false) }
    }
    func updateTiming(_ timing: EffectTiming) {
        guard var motion = capturedAnimation, motion.timing != timing else { return }
        let target = timing.previewPosition(position, following: previewEndpoint, duration: motionDuration, frame: motion.frame)
        motion.timing = timing
        animation = motion
        if request.tool == .color {
            player.pause(); playing = false; position = target
            rebuild()
        } else if playing || target != position {
            seek(target, following: previewEndpoint)
        }
    }
    private func returnToEndpoint() {
        guard let e = endpoint, let motion = animation else { return }
        seek(motion.timing.endpoint(e, duration:motionDuration, frame:motion.frame), following: e)
    }
    private lazy var savedImageMotions: [(TimelinePlacement, EffectAnimation)] = project.edit.layout.placements.compactMap { placement in
        guard self.request.clipIDs?.contains(placement.clip.id) != false,
              let saved = placement.clip.images?.first(where: { $0.id == self.effectID })?.motion else { return nil }
        return (placement, saved)
    }
    var displayedImage: ImageOverlay {
        guard var motion = capturedAnimation else { return image }
        if previewEndpoint != nil { return image }
        let time = start + position
        if request.effectID != nil, start == request.range.lowerBound, end == request.range.upperBound,
           let (placement, saved) = savedImageMotions.first(where: { $0.0.start <= time && time < $0.0.end }),
           motion.hasSameSettings(as: saved) {
            let offset = time - placement.start
            let source = placement.clip.frozenFrame.map { $0.sourceTime + $0.offset + offset } ?? placement.clip.sourceTime(at: offset)
            return image.applying(saved.pose(at: source))
        }
        motion.clock = []
        return image.applying(motion.pose(at: position))
    }
    @Published var imageBitmap: UIImage?
    @Published var loadingImage = false
    private var importedImages: [URL] = []
    var isOverlay: Bool { request.tool == .text || request.tool == .image }
    @Published private(set) var timing: OverlayTiming
    var start: Double { timing.range.lowerBound }
    var end: Double { timing.range.upperBound }
    @Published var pauseSettings = PauseSettings() { didSet { pauseDraft = nil } }
    private var detectedLevels: [UUID: Double] = [:] { didSet { pauseDraft = nil } }
    private var pauseDraft: EditState?
    private lazy var uncutPauseState = makePauseState(removing: true)
    var displayedPauseLevel: Double {
        let clipID = choices.indices.contains(selectedPause) ? choices[selectedPause].clipID : scopedState.clips.first(where: { scopedIDs.contains($0.id) })?.id
        return clipID.flatMap { detectedLevels[$0] } ?? pauseSettings.thresholdDB
    }
    var automaticLevelDescription: String? {
        guard pauseAudioAvailable, let low = detectedLevels.values.min(), let high = detectedLevels.values.max() else { return nil }
        if low == high { return "Reference level \(low.formatted()) dBFS RMS." }
        return "Reference levels range from \(low.formatted()) to \(high.formatted()) dBFS RMS."
    }
    func setAutomaticPauseLevel(_ automatic: Bool) {
        var settings = pauseSettings
        if !automatic { settings.thresholdDB = displayedPauseLevel }
        settings.levelMode = automatic ? .automatic : .manual
        pauseSettings = settings
    }
    @Published var choices: [PauseChoice] = [] { didSet { pauseDraft = nil } }
    @Published var selectedPause = 0
    @Published var detected = false
    @Published var analyzingPauses = false
    @Published private(set) var pauseScanProgress = 0.0
    @Published var pauseAudioAvailable = true
    @Published private(set) var auditioningPause = false
    @Published var busy = false
    @Published var progress = 0.0
    @Published var cropZoom = 1.0
    @Published var trackingWarning = false
    @Published var analysisLabel = "Preparing stabilization…"
    @Published var error: String?
    @Published var original = false
    @Published var position = 0.0
    @Published var duration = 1.0
    @Published var canvas = CGSize(width: 1920, height: 1080)
    @Published var still: UIImage?
    @Published var playing = false
    private var previewJob: Task<Void, Never>?
    private var pauseJob: Task<Void, Never>?
    private var pauseRevision = UUID()
    // Retain manual Keep decisions even when a temporary detection setting
    // hides their candidates. Sliding back should not silently cut them again.
    private var keptPauses: [UUID: [SourceInterval]] = [:]
    private var auditionJob: Task<Void, Never>?
    private var playbackRevision = UUID()
    private var itemStatus: NSKeyValueObservation?
    private var playbackFailure: NSObjectProtocol?
    private var frameJob: Task<Void, Never>?
    private var generator: AVAssetImageGenerator?
    private var endpointPlaybackEnd: EffectPreviewEndObserver?
    private var observer: Any?
    private var revision = UUID()
    private var itemRevision = UUID()
    private var initialPosition: Double?
    let savedStabilizationLevel: StabilizationLevel?
    private var stabilizationAnchor = 0.0
    private(set) var stabilizationWindow: ClosedRange<Double>?
    @Published private(set) var stabilizationSampleStopped = false
    func stopStabilizationSample() {
        revision = UUID(); previewJob?.cancel(); previewJob = nil
        player.pause(); playing = false; busy = false; stabilizationSampleStopped = true
        RecordingAppDelegate.keepAwake(awakeReason, active: false)
    }
    func resumeStabilizationSample() { stabilizationSampleStopped = false; rebuild(delay: false) }
    private var playbackClips: [TimelineClip] = []
    private var projectCanvas: CGSize?
    private var pauseAudition: (position: Double, end: Double)?
    private var auditionReady = false
    private let effectID: UUID
    private let awakeReason = "tool-" + UUID().uuidString
    var scope: ClosedRange<Double> { timing.range }
    var canApply: Bool { (!busy || request.tool == .stabilize) && !loadingImage && (request.tool != .image || imageBitmap != nil) && !analyzingPauses && error == nil && (request.tool != .pauses || (detected && (!choices.isEmpty || request.effectID != nil))) && (request.tool != .text || !text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
    var cutSeconds: Double {
        state().clips.filter { scopedIDs.contains($0.id) }.reduce(0) { sum,clip in var complete=clip;complete.pauses=nil;return sum+complete.duration-clip.duration }
    }
    var cutCount: Int { state().clips.filter { scopedIDs.contains($0.id) }.reduce(0) { $0 + ($1.pauses?.cuts.count ?? 0) } }
    // Keep split UUIDs stable throughout a draft, including pause-choice IDs.
    private var scopedState: EditState
    private var scopedIDs: Set<UUID>
    init(project: Project, folder: URL, request: ToolRequest, position: Double) {
        self.project = project; self.folder = folder; self.request = request
        let bounds: ClosedRange<Double>
        if [.text, .image].contains(request.tool), let ids = request.clipIDs {
            var lower = project.edit.duration, upper = 0.0
            for placement in project.edit.layout.placements where ids.contains(placement.clip.id) {
                lower = min(lower, placement.lower); upper = max(upper, placement.upper)
            }
            bounds = min(lower, upper)...upper
        } else { bounds = 0...project.edit.duration }
        timing = OverlayTiming(range: request.range, bounds: bounds)
        effectID = request.effectID ?? UUID()
        let scoped: (EditState, Set<UUID>)
        if request.targets != nil && ![.text, .image].contains(request.tool) { scoped = request.videoScope(in: project.edit) }
        else if let ids = request.clipIDs { scoped = (project.edit, ids) }
        else if [.text, .image].contains(request.tool) {
            scoped = (project.edit, Set(project.edit.layout.placements.filter { $0.start < request.range.upperBound && $0.end > request.range.lowerBound }.map { $0.clip.id }))
        } else { scoped = TimelineEditing.scoped(project.edit, range: request.range) }
        scopedState = scoped.0; scopedIDs = scoped.1
        gradeRange = request.tool == .color ? request.videoPreviewRange(in:scoped.0,ids:scoped.1) : request.range
        if request.tool == .stabilize {
            let levels = Set(scoped.0.timeline.video.filter { scoped.1.contains($0.id) }.map { $0.content.stabilization?.level ?? .off })
            savedStabilizationLevel = levels.count == 1 && !levels.contains(.off) ? levels.first : nil
        } else { savedStabilizationLevel = nil }
        let clip = scoped.0.clips.first { scoped.1.contains($0.id) }
        level = clip?.stabilization?.level ?? .standard
        rate = clip?.speed?.rate ?? 1; look = clip?.color?.look ?? .natural; amount = clip?.color?.amount ?? 1
        importedLUT = clip?.color?.imported; exposure = clip?.color?.exposure ?? 0; warmth = clip?.color?.warmth ?? 0; tint = clip?.color?.tint ?? 0
        highlights = clip?.color?.highlights ?? 0
        localRecovery = clip?.color?.localRecovery ?? 0
        if let value = clip?.pauses { pauseSettings = value }
        if let id = request.effectID, let existing = scoped.0.clips.lazy.filter({ scoped.1.contains($0.id) })
            .compactMap({ $0.texts?.first { $0.id == id } }).first {
            text = existing
            existingMotion = existing.motion
            existingTitleRange = TitleMotionRanges(project.edit).range(for: existing, at: request.range.lowerBound)
        }
        if request.effectID == nil { text.text = "" }
        text.id = effectID
        mirror = clip?.mirror ?? MirrorSettings(); mirror.id = effectID
        if let id = request.effectID, let existing = project.edit.clips.flatMap({ $0.images ?? [] }).first(where: { $0.id == id }) {
            image = existing; imageBitmap = UIImage(contentsOfFile: folder.appendingPathComponent(existing.filename).path)
        }
        image.id = effectID
        animation = request.tool == .image ? image.motion : (request.tool == .color ? clip?.color?.motion : nil)
        if let motion = animation { loadPose(motion.a) }
        initialPosition = 0
        var local = 0.0
        for placement in scoped.0.layout.placements {
            let clip = placement.clip
            if scoped.1.contains(clip.id) {
                if placement.range.contains(position) { initialPosition = local + min(max(0, position - placement.start), max(0, placement.clip.duration - TimelineEditing.frame)); break }
                local += clip.duration
            }
        }
        if request.tool == .stabilize {
            // A selected clip can be away from the playhead. Sample its nearest
            // edge, including at the end of the project or between selected clips.
            var offset = 0.0, nearest = Double.infinity
            for placement in scoped.0.layout.placements where scoped.1.contains(placement.clip.id) {
                let local = min(placement.clip.duration, max(0, position - placement.start))
                let distance = abs(position - (placement.start + local))
                if distance < nearest { nearest = distance; stabilizationAnchor = offset + local }
                offset += placement.clip.duration
            }
            initialPosition = stabilizationAnchor
        }
        if request.tool == .color { initialPosition = min(max(0,motionDuration-TimelineEditing.frame),max(0,position-playbackOrigin)) }
        if isOverlay { initialPosition = 0 }
        playbackFailure = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                guard let self, let item = note.object as? AVPlayerItem, item === self.player.currentItem,
                      self.itemRevision == self.revision else { return }
                NSLog("YouRec tool playback failed: %@", String(describing: note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey]))
                let message = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription ?? "This video could not be played."
                self.previewJob?.cancel(); self.busy = false
                self.seek(self.pauseAudition?.position ?? self.position); self.error = message
            }
        }
        let previewRate: CMTimeScale = isOverlay ? 30 : 15
        endpointPlaybackEnd = EffectPreviewEndObserver(player:player) { [weak self] in
            guard let self, self.endpoint != nil else { return }
            self.playing = false; self.returnToEndpoint()
        }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: previewRate), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.playing = self.player.rate > 0
                let observed = self.player.currentTime().seconds - self.playbackOrigin
                if self.playing, observed.isFinite { self.position = min(self.duration, max(0, observed)) }
                if self.auditionReady, let audition = self.pauseAudition, observed >= min(audition.end, self.duration - 0.02) {
                    self.seek(audition.position); return
                }
                if let end=self.titleAuditionEnd, self.playing, observed >= end-0.015 {
                    self.seek(end)
                } else if observed >= self.duration - 0.02 { self.player.pause(); self.playing = false; self.returnToEndpoint() }
            }
        }
    }
    deinit { if let observer { player.removeTimeObserver(observer) }; if let playbackFailure { NotificationCenter.default.removeObserver(playbackFailure) }; previewJob?.cancel(); pauseJob?.cancel(); frameJob?.cancel(); auditionJob?.cancel() }
    func stop() {
        revision = UUID()
        thumbnailJob?.cancel(); thumbnailGenerator?.cancelAllCGImageGeneration()
        previewJob?.cancel(); pauseJob?.cancel(); frameJob?.cancel(); auditionJob?.cancel(); generator?.cancelAllCGImageGeneration(); player.pause()
        pauseRevision = UUID(); playbackRevision = UUID(); pauseAudition = nil; auditioningPause = false
        RecordingAppDelegate.keepAwake(awakeReason, active: false)
    }
    func loadImage(_ item: PhotosPickerItem) async {
        loadingImage = true
        defer { loadingImage = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 4096] as CFDictionary),
                  let png = UIImage(cgImage: bitmap).pngData() else { throw ProjectError.invalidMedia }
            try Task.checkCancellation()
            let url = folder.appendingPathComponent("image-" + UUID().uuidString + ".png")
            try png.write(to: url, options: .atomic)
            importedImages.append(url); image.filename = url.lastPathComponent; imageBitmap = UIImage(cgImage: bitmap)
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    func finishImages(keeping filename: String? = nil) {
        for url in importedImages where url.lastPathComponent != filename { try? FileManager.default.removeItem(at: url) }
        importedImages = []
    }
    private func scoped() -> (EditState, Set<UUID>) { (scopedState, scopedIDs) }
    func selectGrade(_ settings: ColorSettings) {
        do {
            if let lut = settings.imported { try GradeLibrary.copy(lut, from: GradeLibrary.folder, to: folder) }
            look = settings.look; amount = settings.amount; importedLUT = settings.imported
            exposure = settings.exposure ?? 0; warmth = settings.warmth ?? 0; tint = settings.tint ?? 0
            highlights = settings.highlights ?? 0
            localRecovery = settings.localRecovery ?? 0
            colorError = nil; rebuild()
        } catch { colorError = error.localizedDescription }
    }
    func importLUT(_ url: URL) async {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let lut = try await Task.detached(priority: .userInitiated) { try LUTAssets.ingest(url, folder: GradeLibrary.folder) }.value
            try GradeLibrary.copy(lut, from: GradeLibrary.folder, to: folder)
            if !library.imported.contains(where: { $0.id == lut.id }) { library.imported.append(lut) }
            try library.save(); importedLUT = lut; look = .natural; amount = 1; colorError = nil
            refreshLookThumbnails(); rebuild()
        } catch { colorError = error.localizedDescription }
    }
    func saveGrade(named name: String) {
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)); guard !clean.isEmpty else { return }
        do {
            if let lut = importedLUT { try GradeLibrary.copy(lut, from: folder, to: GradeLibrary.folder) }
            library.grades.append(SavedGrade(name: clean, settings: colorSettings)); try library.save(); colorError = nil
        } catch { colorError = error.localizedDescription }
    }
    func toggleFavorite(_ id: String) {
        if library.favorites.contains(id) { library.favorites.remove(id) } else { library.favorites.insert(id) }
        do { try library.save() } catch { colorError = error.localizedDescription }
    }
    func refreshLookThumbnails() {
        guard request.tool == .color, !playing else { return }
        thumbnailJob?.cancel()
        thumbnailGenerator?.cancelAllCGImageGeneration()
        let time = position
        thumbnailJob = Task {
            do {
                try await Task.sleep(for: .milliseconds(220)); try Task.checkCancellation()
                if thumbnailGenerator == nil {
                    var candidate = previewProject()
                    var edit = candidate.edit; for i in edit.clips.indices { edit.clips[i].color = nil }
                    candidate.history = [edit]; candidate.historyCursor = 0
                    let media = try await MediaRenderer.timeline(project: candidate, folder: folder, canvasSize: projectCanvas, effectPreparation: .cached)
                    try Task.checkCancellation()
                    let generator = AVAssetImageGenerator(asset: media.composition)
                    generator.videoComposition = media.videoComposition; generator.appliesPreferredTrackTransform = true
                    generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
                    generator.maximumSize = CGSize(width: 240, height: 240); thumbnailGenerator = generator
                }
                guard let thumbnailGenerator else { return }
                let frame = try await thumbnailGenerator.image(at: CMTime(seconds: playbackOrigin + min(time, max(0, duration - TimelineEditing.frame)), preferredTimescale: 600)).image
                let luts = library.imported, folder = self.folder
                // The small reference image is color-managed SDR, just like the
                // editor preview. No placeholder swatches masquerading as looks.
                let pictures = await Task.detached(priority: .utility) { () -> [String: CGImage] in
                    let context = CIContext(options: [.cacheIntermediates: false]); let input = CIImage(cgImage: frame)
                    var result: [String: CGImage] = [:]
                    for look in ColorLook.allCases {
                        let image = ColorLUT.apply(ColorSettings(look: look), to: input)
                        result[look.rawValue] = context.createCGImage(image, from: input.extent)
                    }
                    for lut in luts {
                        let sourceFolder = FileManager.default.fileExists(atPath: folder.appendingPathComponent(lut.filename).path) ? folder : GradeLibrary.folder
                        let image = ColorLUT.apply(ColorSettings(imported: lut), to: input, folder: sourceFolder)
                        result[lut.id] = context.createCGImage(image, from: input.extent)
                    }
                    return result
                }.value
                try Task.checkCancellation(); lookThumbnails = pictures.mapValues { UIImage(cgImage: $0) }
            } catch is CancellationError {} catch { /* Playback remains usable if an individual frame is unavailable. */ }
        }
    }
    private func makePauseState(removing: Bool) -> EditState {
        var edit = scopedState
        let groups = Dictionary(grouping: choices, by: \.clipID)
        // Replace the clip collection once. Mutating its projected subscript repeatedly
        // used to retime the entire multitrack project once for every clip, on every redraw.
        edit.clips = edit.clips.map { clip in
            guard scopedIDs.contains(clip.id) else { return clip }
            var updated = clip
            guard !removing, let choices = groups[clip.id], !choices.isEmpty else {
                updated.pauses = nil
                return updated
            }
            var settings = pauseSettings
            settings.id = effectID
            if settings.levelMode == .automatic { settings.thresholdDB = detectedLevels[clip.id] ?? settings.thresholdDB }
            let candidates = choices.map { DetectedPause(raw: $0.raw, enabled: $0.enabled) }
            settings.candidates = candidates
            settings.analyzed = SourceInterval(start: clip.start, end: clip.end)
            settings.cuts = PauseDetector.effectiveCuts(candidates, clip: clip, settings: settings)
            updated.pauses = settings
            return updated
        }
        return edit
    }
    func state(removing: Bool = false, forPreview: Bool = false) -> EditState {
        if request.tool == .pauses {
            if removing { return uncutPauseState }
            if let pauseDraft { return pauseDraft }
            let draft = makePauseState(removing: false)
            pauseDraft = draft
            return draft
        }
        if request.tool == .image {
            var edit = project.edit
            let positions = edit.layout.placements
            for index in edit.clips.indices {
                var clip = edit.clips[index]
                let cursor = positions[index].start
                if let ids = request.clipIDs, !ids.contains(clip.id) { continue }
                var image = self.image
                if let motion = capturedAnimation {
                    image = image.applying(motion.a); image.motion = motion.placed(on:clip,offset:cursor-start,replacing:(start == request.range.lowerBound && end == request.range.upperBound) ? clip.images?.first(where:{ $0.id == effectID })?.motion : nil)
                }
                let previous = (clip.images ?? []).first { $0.id == effectID }
                clip.images = (clip.images ?? []).filter { $0.id != effectID }
                if !removing, !forPreview, request.effectID != nil, start == request.range.lowerBound, end == request.range.upperBound {
                    if let previous { var value = image; value.start = previous.start; value.end = previous.end; clip.images = (clip.images ?? []) + [value] }
                } else {
                    let a = max(start, cursor), b = min(end, cursor + clip.duration)
                    if !removing, !forPreview, b > a + 0.000001, !image.filename.isEmpty {
                        var value = image; value.start = clip.sourceTime(at: a - cursor); value.end = clip.sourceTime(at: b - cursor)
                        clip.images = (clip.images ?? []) + [value]
                    }
                }
                edit.clips[index] = clip
            }
            return edit
        }
        if request.tool == .mirror && request.effectID == nil && !mirror.horizontal && !mirror.vertical { return project.edit }
        if request.tool == .text {
            var edit = project.edit
            let positions = edit.layout.placements
            for index in edit.clips.indices {
                var clip = edit.clips[index]
                let cursor = positions[index].start
                if let ids = request.clipIDs, !ids.contains(clip.id) { continue }
                let previous = (clip.texts ?? []).first { $0.id == effectID }
                clip.texts = (clip.texts ?? []).filter { $0.id != effectID }
                if !removing, !forPreview, request.effectID != nil, start == request.range.lowerBound, end == request.range.upperBound {
                    if let previous { var value = text; value.start = previous.start; value.end = previous.end; clip.texts = (clip.texts ?? []) + [value] }
                    edit.clips[index] = clip; continue
                }
                let a = max(start, cursor), b = min(end, cursor + clip.duration)
                if !removing, !forPreview, b > a + 0.000001, request.clipIDs == nil || request.clipIDs!.contains(clip.id) {
                    var value = text; value.start = clip.sourceTime(at: a - cursor); value.end = clip.sourceTime(at: b - cursor)
                    clip.texts = (clip.texts ?? []) + [value]
                }
                edit.clips[index] = clip
            }
            return edit
        }
        var edit = scopedState
        let starts = request.tool == .color ? Dictionary(uniqueKeysWithValues:edit.layout.placements.map { ($0.clip.id,$0.start) }) : [:]
        for index in edit.clips.indices where scopedIDs.contains(edit.clips[index].id) {
            switch request.tool {
            case .speed: edit.clips[index].speed = removing || rate == 1 ? nil : SpeedSettings(id: effectID, rate: rate)
            case .color:
                var grade = colorSettings
                if let motion = capturedAnimation {
                    grade = grade.applying(motion.a); grade.motion = motion.placed(on:edit.clips[index],offset:(starts[edit.clips[index].id] ?? playbackOrigin)-playbackOrigin,replacing:edit.clips[index].color?.motion)
                }
                edit.clips[index].color = removing || grade.isIdentity ? nil : grade
            case .stabilize:
                if removing || level == .off { edit.clips[index].stabilization = nil }
                else { var value = edit.clips[index].stabilizing(level); value.id = effectID; edit.clips[index].stabilization = value }
            case .mirror: edit.clips[index].mirror = removing || (!mirror.horizontal && !mirror.vertical) ? nil : mirror
            case .pauses, .subtitles, .text, .crop, .image, .addVideo, .addAudio, .censorAudio, .transition, .videoEffects, .enhanceAudio, .volume, .placement: break
            }
        }
        return edit
    }
    private func previewProject() -> Project {
        var candidate = project
        var edit = state(removing: original, forPreview: isOverlay)
        if isOverlay || request.tool == .color {
            // Preserve transitions, gaps, underlying captions and layer placement. The player's
            // seek and end bounds restrict playback to the selected title interval.
            candidate.history = [edit]; candidate.historyCursor = 0; return candidate
        }
        edit.clips = edit.clips.filter { scopedIDs.contains($0.id) }
        // Tool workspaces inspect the complete clips independently of their joins.
        // The saved edit retains transitions; the main editor previews the joins.
        edit.clips = edit.clips.map { var clip = $0; clip.transition = nil; clip.openingTransition = nil; return clip }
        if request.tool == .stabilize {
            let sequence = TimelineLayout(clips: edit.clips)
            let window = EffectPreviewWindow.range(at: stabilizationAnchor, within: 0...sequence.duration)
            stabilizationWindow = window
            let samples = EffectPreviewWindow(window, timeline: TrackTimeline(clips: edit.clips))
            edit = EditState(clips: edit.clips.compactMap { clip in
                guard var sample = samples.analysisClip(clip) else { return nil }
                // Keep the saved take clock. A ready full path is authoritative;
                // otherwise the inspector measures just its visible sample.
                sample.stabilization?.referenceStart = clip.stabilizationStart
                sample.stabilization?.referenceEnd = clip.stabilizationEnd
                return sample
            }, outputSize: edit.outputSize)
        } else {
            edit = EditState(clips: edit.clips, outputSize: edit.outputSize)
        }
        candidate.history = [edit]; candidate.historyCursor = 0; return candidate
    }
    func rebuild(delay: Bool = true, focusPause: Bool = false) {
        guard !stabilizationSampleStopped else { return }
        auditionJob?.cancel(); playbackRevision = UUID(); auditioningPause = false
        previewJob?.cancel(); let token = UUID(); revision = token
        let resume = playing && pauseAudition == nil
        if let audition = pauseAudition { position = audition.position; pauseAudition = nil }
        let observed = player.currentTime().seconds - playbackOrigin
        if resume && observed.isFinite { position = observed }
        var cursor = 0.0
        var anchor: (UUID, UUID, Double)?
        for clip in playbackClips {
            if position < cursor + clip.duration || clip.id == playbackClips.last?.id {
                anchor = (clip.id, clip.sourceID, clip.sourceTime(at: position - cursor)); break
            }
            cursor += clip.duration
        }
        player.pause(); playing = false
        player.currentItem?.cancelPendingSeeks()
        busy = true; progress = 0; error = nil
        previewJob = Task {
            defer { if revision == token { busy = false; RecordingAppDelegate.keepAwake(awakeReason, active: false) } }
            do {
                if delay { try await Task.sleep(for: .milliseconds(180)) }
                RecordingAppDelegate.keepAwake(awakeReason, active: true)
                let candidate = previewProject()
                if request.tool == .color && !checkedColorSources {
                    let ids = Set(scopedState.clips.filter { scopedIDs.contains($0.id) }.map(\.sourceID))
                    var count = 0
                    for source in project.sources where ids.contains(source.id) {
                        let asset = AVURLAsset(url: folder.appendingPathComponent(source.filename))
                        if let track = try await asset.loadTracks(withMediaType: .video).first,
                           try await track.load(.formatDescriptions).contains(where: { LogColor.profile($0) != nil }) { count += 1 }
                    }
                    try Task.checkCancellation()
                    logSourceCount = count; checkedColorSources = true
                }
                if projectCanvas == nil { projectCanvas = try await MediaRenderer.canvas(project: project, folder: folder) }
                var plans: [UUID: StabilizationPlan] = [:]
                if request.tool == .stabilize && !original && level != .off {
                    let clips = candidate.edit.clips
                    let window = EffectPreviewWindow(0...candidate.edit.duration, timeline: candidate.edit.timeline)
                    var crop = 1.0, weakTracking = false
                    for (index, clip) in clips.enumerated() {
                        guard let source = candidate.sources.first(where: { $0.id == clip.sourceID }) else { throw ProjectError.missingMedia }
                        analysisLabel = "Preparing " + (stabilizationWindow.map(EffectPreviewWindow.label) ?? "stabilization preview")
                        let plan = try await VideoEffectPreparation.$inspectionWindow.withValue(window) {
                            try await VideoStabilizer.shared.plan(source: source, clip: clip, folder: folder) { value in
                                Task { @MainActor [weak self] in if self?.revision == token { self?.progress = (Double(index) + value) / Double(max(1, clips.count)) } }
                            }
                        }
                        if let plan { plans[clip.id] = plan; crop = max(crop, plan.zoom); weakTracking = weakTracking || plan.trackingFraction < 0.65 }
                        try Task.checkCancellation()
                    }
                    cropZoom = crop; trackingWarning = weakTracking
                }
                let media = try await MediaRenderer.timeline(project: candidate, folder: folder, canvasSize: projectCanvas, stabilizationPlans: plans, videoProgress: { value in
                    Task { @MainActor [weak self] in if self?.revision == token { self?.progress = value } }
                }, forceCustom: request.tool == .text, effectPreparation:.cached)
                try Task.checkCancellation(); guard revision == token else { return }
                duration = isOverlay ? timing.duration : request.tool == .color ? motionDuration : candidate.edit.duration; canvas = media.videoComposition.renderSize
                let item = AVPlayerItem(asset: media.composition); item.videoComposition = media.playbackVideoComposition; item.audioMix = media.audioMix
                item.audioTimePitchAlgorithm = .spectral; item.seekingWaitsForVideoCompositionRendering = true
                if request.tool == .text { refreshTitlePreview(item:item) }
                if isOverlay || request.tool == .color {
                    item.reversePlaybackEndTime = CMTime(seconds:playbackOrigin,preferredTimescale:60000)
                    item.forwardPlaybackEndTime = CMTime(seconds:playbackOrigin+duration,preferredTimescale:60000)
                }
                itemStatus = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                    guard item.status == .failed else { return }
                    let message = item.error?.localizedDescription ?? "This video could not be played."
                    Task { @MainActor [weak self] in
                        guard let self, self.revision == token else { return }
                        self.error = message; self.player.pause(); self.playing = false
                    }
                }
                itemRevision = token; player.replaceCurrentItem(with: item)
                generator?.cancelAllCGImageGeneration()
                let generator = AVAssetImageGenerator(asset: media.composition); generator.videoComposition = media.videoComposition
                generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 1280, height: 1280)
                generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
                self.generator = generator
                var target = initialPosition.map { $0 - (stabilizationWindow?.lowerBound ?? 0) } ?? position
                if initialPosition == nil, request.tool != .color, !isOverlay, let anchor {
                    let matching = candidate.edit.clips.first { $0.id == anchor.0 && anchor.2 >= $0.start && anchor.2 <= $0.end }
                        ?? candidate.edit.clips.first { $0.sourceID == anchor.1 && anchor.2 >= $0.start && anchor.2 <= $0.end }
                    if let matching { target = TimelineEditing.offset(of: matching.id, in: candidate.edit) + matching.timelineTime(forSource: anchor.2) }
                }
                playbackClips = candidate.edit.clips
                if focusPause, choices.indices.contains(selectedPause) { target = pausePreviewRange(choices[selectedPause]).lowerBound }
                position = min(max(0, target), max(0, duration - TimelineEditing.frame)); initialPosition = nil
                // Replacing the item can race its initial frame/seek. Do not
                // advertise the new look as ready until its exact paused frame
                // has rendered, and never let a cancelled rebuild seek again.
                let deadline = ContinuousClock.now + .seconds(20)
                while item.status == .unknown {
                    try Task.checkCancellation(); guard revision == token else { return }
                    if ContinuousClock.now >= deadline { throw ProjectError.invalidMedia }
                    try await Task.sleep(for: .milliseconds(20))
                }
                try Task.checkCancellation(); guard revision == token else { return }
                if let failure = item.error { throw failure }
                let sought = await player.seek(to: CMTime(seconds: position + playbackOrigin, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
                try Task.checkCancellation(); guard revision == token else { return }
                guard sought else { throw ProjectError.invalidMedia }
                if request.tool == .color { refreshLookThumbnails() }
                if request.tool == .image { await loadFrame() }
                else if resume { player.play(); playing = true }
            } catch is CancellationError {} catch {
                if revision == token {
                    NSLog("YouRec %@ inspector: %@, underlying: %@", request.tool.rawValue, String(describing: error), String(describing: (error as NSError).userInfo[NSUnderlyingErrorKey]))
                    self.error = error.localizedDescription
                }
            }
        }
    }
    func seek(_ value: Double, playThrough auditionEnd: Double? = nil, following selected: EffectEndpoint? = nil) {
        previewEndpoint = selected
        titleAuditionEnd = nil
        auditionJob?.cancel(); playbackRevision = UUID(); auditioningPause = false
        pauseAudition = nil
        player.pause(); playing = false; position = min(max(0, value), max(0, duration - TimelineEditing.frame))
        if request.tool == .image {
            frameJob?.cancel(); generator?.cancelAllCGImageGeneration()
            frameJob = Task { try? await Task.sleep(for: .milliseconds(80)); guard !Task.isCancelled else { return }; await loadFrame() }
        } else {
            let target = CMTime(seconds: position + playbackOrigin, preferredTimescale: 60000)
            if let auditionEnd {
                let token = playbackRevision
                player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] completed in
                    Task { @MainActor in
                        guard completed, let self, self.playbackRevision == token else { return }
                        self.titleAuditionEnd = auditionEnd
                        self.player.play(); self.playing = true
                    }
                }
            } else {
                player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
    }
    func trim(_ edge: OverlayTiming.Edge, to value: Double, previewEdge: Bool = true) {
        let absolutePlayhead = start + position
        var updated = timing
        updated.set(edge, to: value)
        guard updated.range != timing.range else { return }
        timing = updated
        if request.tool == .image {
            rebuild()
            return
        }
        // Text previews already contain the full underlying composition. Trimming
        // only changes the player's playback window and the draft title's clock.
        duration = timing.duration
        let lastFrame = max(0, duration - TimelineEditing.frame)
        let target = previewEdge ? (edge == .start ? 0 : lastFrame) : min(lastFrame, max(0, absolutePlayhead - start))
        guard let item = player.currentItem, !busy else {
            initialPosition = target
            rebuild()
            return
        }
        refreshTitlePreview(item: item)
        item.reversePlaybackEndTime = CMTime(seconds: start, preferredTimescale: 60000)
        item.forwardPlaybackEndTime = CMTime(seconds: end, preferredTimescale: 60000)
        seek(target)
    }
    private func loadFrame() async {
        guard let generator else { return }
        do { let result = try await generator.image(at: CMTime(seconds: position+playbackOrigin, preferredTimescale: 60000)); try Task.checkCancellation(); still = UIImage(cgImage: result.image) }
        catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func togglePlay() {
        if request.tool == .text { playbackRevision = UUID() }
        titleAuditionEnd = nil
        if playing { player.pause(); playing = false; returnToEndpoint(); if let audition = pauseAudition { seek(audition.position) } }
        else {
            previewEndpoint = nil
            if endpoint != nil || position >= duration - 0.05 {
                if request.tool == .image { position=0; player.seek(to:CMTime(seconds:playbackOrigin,preferredTimescale:60000),toleranceBefore:.zero,toleranceAfter:.zero) }
                else { seek(0) }
            } else if request.tool == .image {
                player.seek(to:CMTime(seconds:playbackOrigin+position,preferredTimescale:60000),toleranceBefore:.zero,toleranceAfter:.zero)
            }
            player.play(); playing = true
        }
    }
    func analyzePauses(delay: Bool = false) {
        pauseJob?.cancel(); let token = UUID(); pauseRevision = token
        analyzingPauses = true; pauseScanProgress = 0; detected = false; error = nil
        let settings = pauseSettings
        let anchor = choices.indices.contains(selectedPause) ? choices[selectedPause] : nil
        pauseJob = Task {
            defer { if pauseRevision == token { analyzingPauses = false } }
            do {
                if delay { try await Task.sleep(for: .milliseconds(250)) }
                var proposed: [PauseChoice] = [], hasAudio = false
                var sourceLevels: [UUID: Double] = [:], clipLevels: [UUID: Double] = [:]
                let clips = scopedState.clips.filter { scopedIDs.contains($0.id) }
                let sourceIDs = Set(clips.map(\.sourceID))
                let totalSeconds = project.sources.filter { sourceIDs.contains($0.id) }.reduce(0) { $0 + $1.duration }
                var scanned = 0.0
                for clip in clips {
                    guard let source = project.sources.first(where: { $0.id == clip.sourceID }) else { throw ProjectError.missingMedia }
                    let base = scanned, length = sourceLevels[source.id] == nil ? source.duration : 0
                    let wave = try await SourceMediaCache.shared.waveform(source: source, folder: folder, needsRMS: settings.levelMode != nil,
                                                                        needsSpeech: settings.levelMode == .automatic) { [weak self] fraction in
                        Task { @MainActor in
                            guard let self, self.pauseRevision == token, self.analyzingPauses else { return }
                            self.pauseScanProgress = max(self.pauseScanProgress, (base + length * fraction) / max(totalSeconds, 0.001))
                        }
                    }
                    try Task.checkCancellation(); guard pauseRevision == token else { return }
                    scanned += length
                    pauseScanProgress = scanned / max(totalSeconds, 0.001)
                    hasAudio = hasAudio || !wave.peaks.isEmpty
                    let level = sourceLevels[source.id] ?? PauseDetector.levelDB(wave: wave, settings: settings)
                    sourceLevels[source.id] = level; if !wave.peaks.isEmpty { clipLevels[clip.id] = level }
                    let intervals = PauseDetector.raw(wave: wave, clip: clip, settings: settings, levelDB: level)
                    let previous = keptPauses[clip.id] ?? []
                    for raw in intervals {
                        let keep = previous.contains { min($0.end, raw.end) - max($0.start, raw.start) > min(raw.duration, $0.duration) * 0.5 }
                        proposed.append(PauseChoice(clipID: clip.id, raw: raw, interval: PauseDetector.padded(raw,clip:clip,settings:settings), enabled: !keep))
                    }
                }
                try Task.checkCancellation(); guard pauseRevision == token else { return }
                choices = proposed; pauseAudioAvailable = hasAudio; detectedLevels = clipLevels
                if let anchor, let closest = choices.indices.filter({ choices[$0].clipID == anchor.clipID }).min(by: { abs(choices[$0].raw.start - anchor.raw.start) < abs(choices[$1].raw.start - anchor.raw.start) }) { selectedPause = closest }
                else { selectedPause = min(selectedPause, max(0, choices.count - 1)) }
                detected = true; rebuild(delay: false, focusPause: true)
            } catch is CancellationError {} catch { if pauseRevision == token { self.error = error.localizedDescription } }
        }
    }
    func pauseSettingsChanged(from old: PauseSettings) {
        if old.levelMode != pauseSettings.levelMode || old.thresholdDB != pauseSettings.thresholdDB || old.minimum != pauseSettings.minimum || analyzingPauses {
            analyzePauses(delay: true); return
        }
        for index in choices.indices {
            if let clip=scopedState.clips.first(where:{$0.id==choices[index].clipID}) {
                choices[index].interval=PauseDetector.padded(choices[index].raw,clip:clip,settings:pauseSettings)
            }
        }
        if detected { rebuild(focusPause: true) }
    }
    func cutDuration(_ choice: PauseChoice) -> Double {
        guard let clip = scopedState.clips.first(where: { $0.id == choice.clipID }) else { return 0 }
        var full=clip;full.pauses=nil
        return PauseDetector.effectiveCuts([DetectedPause(raw:choice.raw)],clip:clip,settings:pauseSettings).reduce(0) { $0+full.timelineTime(forSource:$1.end)-full.timelineTime(forSource:$1.start) }
    }
    func pausePreviewRange(_ choice: PauseChoice) -> ClosedRange<Double> {
        var cursor = 0.0
        for clip in state(removing: original).clips where scopedIDs.contains(clip.id) {
            if clip.id == choice.clipID {
                let interval = original || !choice.enabled || cutDuration(choice) < TimelineEditing.frame ? choice.raw : choice.interval
                let start = cursor + clip.timelineTime(forSource: interval.start)
                let end = cursor + clip.timelineTime(forSource: interval.end)
                return start...max(start, end)
            }
            cursor += clip.duration
        }
        return 0...0
    }
    func selectPause(_ index: Int) {
        guard !busy, !analyzingPauses, !choices.isEmpty else { return }
        selectedPause = min(max(0, index), choices.count - 1)
        seek(pausePreviewRange(choices[selectedPause]).lowerBound)
    }
    func setPauseEnabled(_ enabled: Bool) {
        guard choices.indices.contains(selectedPause) else { return }
        let choice = choices[selectedPause]
        keptPauses[choice.clipID, default: []].removeAll { min($0.end, choice.raw.end) - max($0.start, choice.raw.start) > min(choice.raw.duration, $0.duration) * 0.5 }
        if !enabled { keptPauses[choice.clipID, default: []].append(choice.raw) }
        choices[selectedPause].enabled = enabled; rebuild(focusPause: true)
    }
    func auditionPause() {
        if let audition = pauseAudition { seek(audition.position); return }
        guard !busy, !analyzingPauses, choices.indices.contains(selectedPause) else { return }
        let range = pausePreviewRange(choices[selectedPause])
        let anchor = position, start = max(0, range.lowerBound - 0.75), end = min(duration, range.upperBound + 0.75)
        auditionJob?.cancel(); player.pause(); playing = false
        let token = UUID(); playbackRevision = token; auditioningPause = true; auditionReady = false; pauseAudition = (anchor, end)
        auditionJob = Task {
            let sought = await player.seek(to: CMTime(seconds: start, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
            guard !Task.isCancelled, playbackRevision == token else { return }
            guard sought else { seek(anchor); return }
            position = start; auditionReady = true; player.play(); playing = true
        }
    }
    func startPreview() {
        if request.tool == .pauses {
            for clip in scopedState.clips {
                if scopedIDs.contains(clip.id), let settings = clip.pauses {
                    detectedLevels[clip.id] = settings.thresholdDB
                    let candidates = settings.candidates ?? settings.cuts.map { DetectedPause(raw: SourceInterval(start: max(clip.start, $0.start - settings.before * clip.rate), end: min(clip.end, $0.end + settings.after * clip.rate))) }
                    choices += candidates.filter { $0.raw.start < clip.end && $0.raw.end > clip.start }.map {
                        PauseChoice(clipID: clip.id, raw: $0.raw, interval: PauseDetector.padded($0.raw,clip:clip,settings:settings), enabled: $0.enabled)
                    }
                }
            }
            for choice in choices where !choice.enabled { keptPauses[choice.clipID, default: []].append(choice.raw) }
            if request.effectID != nil { detected = true; rebuild(delay: false, focusPause: true) }
            else { rebuild(delay: false); analyzePauses() }
        } else { rebuild(delay: false) }
    }
}

struct ToolEditor: View {
    @StateObject private var model: ToolWorkspace
    @ObservedObject private var editor: EditorController
    @State private var samplingStabilization = false
    private var reviewingSavedLevel: Bool { model.savedStabilizationLevel == model.level }
    private var showingEditorFrame: Bool { reviewingSavedLevel && !samplingStabilization }
    let cancel: () -> Void
    let apply: (EditState) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var pickedImage: PhotosPickerItem?
    @FocusState private var textFocused: Bool
    @State private var dragOrigin: CGPoint?
    @State private var pinchSize: Double?
    init(project: Project, folder: URL, request: ToolRequest, editor: EditorController, cancel: @escaping () -> Void, apply: @escaping (EditState) -> Void) {
        _model = StateObject(wrappedValue: ToolWorkspace(project: project, folder: folder, request: request, position: editor.playhead))
        self.editor = editor
        self.cancel = cancel; self.apply = apply
    }
    private var kind: VideoTool { model.request.tool }
    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            let inspectorWidth = landscape ? min(320, geometry.size.width * 0.4) : geometry.size.width
            VStack(spacing: 0) {
                header
                let layout = landscape ? AnyLayout(HStackLayout(spacing: 12)) : AnyLayout(VStackLayout(spacing: 0))
                layout {
                    VStack(spacing: 0) {
                        preview.frame(maxWidth: .infinity, maxHeight: .infinity)
                        if showingEditorFrame {
                            Button { samplingStabilization = true; model.startPreview() } label: {
                                Label("Preview around playhead", systemImage: "play.fill").frame(minHeight: 44)
                            }.accessibilityIdentifier("stabilize.previewSaved")
                        } else { playback.padding(.horizontal, 14).padding(.vertical, 4) }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if let error = model.error {
                                Text(error).font(.callout).foregroundStyle(.orange)
                                Button("Retry") { model.rebuild(delay: false) }.frame(minHeight: 44)
                            }
                            if kind == .image || (kind == .color && model.animation != nil) { animationControls }
                            settings(width: max(0, inspectorWidth - 32))
                            if model.request.effectID != nil {
                                Button(role: .destructive) { model.finishImages(); model.stop(); apply(model.state(removing: true)) } label: {
                                    Label("Remove \(kind == .color ? "look" : kind.title.lowercased())", systemImage: "trash").frame(maxWidth: .infinity, minHeight: 44)
                                }.accessibilityIdentifier("tool.remove")
                            }
                        }.padding(16)
                    }.accessibilityIdentifier("tool.settings").frame(width: landscape ? inspectorWidth : nil)
                        .frame(maxHeight: landscape ? .infinity : min(kind == .pauses || kind == .color ? 360 : typeSize.isAccessibilitySize ? 350 : (kind == .text || kind == .image) ? 310 : 230, geometry.size.height * 0.48))
                        .background(Color(white: 0.08))
                }
            }.background(Color.black)
        }.preferredColorScheme(.dark).interactiveDismissDisabled()
            .task { if !showingEditorFrame { model.startPreview() } }
            .onDisappear { model.stop() }
            .onChange(of: model.text) { _, _ in model.refreshTitlePreview() }
            .onChange(of: model.mirror) { _, _ in model.rebuild() }
            .task(id: pickedImage) { if let pickedImage { await model.loadImage(pickedImage) } }
            .onChange(of: model.level) { _, _ in
                samplingStabilization = true
                model.resumeStabilizationSample()
            }
            .onChange(of: model.rate) { _, _ in model.rebuild() }
            .onChange(of: model.colorSettings) { _, _ in model.adjustedEndpoint(); model.rebuild() }
            .onChange(of:model.image.pose) { _,_ in model.adjustedEndpoint() }
            .onChange(of: model.position) { _, _ in model.refreshLookThumbnails() }
            .onChange(of: model.playing) { _, playing in if !playing { model.refreshLookThumbnails() } }
            .onChange(of: model.original) { _, _ in model.rebuild(delay: false) }
            .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { textFocused = false } } }
    }
    private var scopeDescription: String {
        let title = model.request.scopeTitle
        if let window = model.stabilizationWindow { return title + " · " + EffectPreviewWindow.label(window) }
        if model.isOverlay { return title + " · " + editorTime(model.start) + "–" + editorTime(model.end) }
        return title
    }
    private var header: some View {
        HStack(spacing: 8) {
            if reviewingSavedLevel { Color.clear.frame(width: 60, height: 44).accessibilityHidden(true) }
            else { Button("Cancel") { model.finishImages(); cancel() }.frame(minWidth: 60, minHeight: 44).accessibilityIdentifier("tool.cancel") }
            Spacer(minLength: 0)
            VStack(spacing: 2) {
                Text(kind.title).font(.headline)
                Text(scopeDescription)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if reviewingSavedLevel {
                Button("Done", action: cancel).fontWeight(.semibold).frame(minWidth: 60, minHeight: 44)
                    .accessibilityIdentifier("stabilize.done")
            } else {
                Button(model.savedStabilizationLevel == nil ? "Apply" : "Apply changes") {
                    textFocused = false; model.finishImages(keeping: model.image.filename); model.stop(); apply(model.state())
                }.fontWeight(.semibold).frame(minWidth: 60, minHeight: 44).disabled(!model.canApply).accessibilityIdentifier("tool.apply")
            }
        }.padding(.horizontal, 12).background(Color(white: 0.06))
    }
    private var preview: some View {
        ZStack {
            if showingEditorFrame { PlayerSurface(player: editor.player, identifier: "tool.savedFrame", preserveInspection: true) }
            else if kind == .text { InspectPreview(canvas: model.canvas) { textCanvas } }
            else if kind == .image { InspectPreview(canvas: model.canvas) { imageCanvas } }
            else { PlayerSurface(player: model.player, identifier: "tool.preview", preserveInspection: true) }
            if model.stabilizationSampleStopped {
                Button("Preview stabilization", action: model.resumeStabilizationSample)
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("stabilize.resumeSample")
            } else if !showingEditorFrame && (model.busy || model.analyzingPauses) {
                VStack(spacing: 8) {
                    if model.progress > 0 { ProgressView(value: model.progress).frame(width: 140) } else { ProgressView() }
                    Text(model.analyzingPauses ? "Finding pauses…" : kind == .stabilize ? model.analysisLabel : "Preparing preview…").font(.caption)
                    if kind == .stabilize {
                        Button(action: model.stopStabilizationSample) { Text("Stop").frame(minWidth: 64, minHeight: 44) }
                            .accessibilityIdentifier("stabilize.stopSample")
                    }
                }.padding(14).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14)).allowsHitTesting(kind == .stabilize)
            }
        }.clipped()
    }
    private var textCanvas: some View {
        GeometryReader { geometry in
            let ratio = model.canvas.width / max(1, model.canvas.height)
            let width = min(geometry.size.width, geometry.size.height * ratio)
            let height = width / ratio
            let size = CGSize(width: width, height: height)
            ZStack {
                PlayerSurface(player:model.player,identifier:"tool.text.video").allowsHitTesting(false)
                if let bitmap = model.titleBitmap() {
                    let dimensions = CGSize(width:bitmap.width,height:bitmap.height)
                    let origin = TextRasterizer.origin(model.text,imageSize:dimensions,canvas:model.canvas)
                    let scale = width/model.canvas.width
                    Color.clear.frame(width:max(44,dimensions.width*scale+16),height:max(44,dimensions.height*scale+16))
                        .contentShape(Rectangle())
                        .position(x:(origin.x+dimensions.width/2)*scale,y:height-(origin.y+dimensions.height/2)*scale)
                        .gesture(DragGesture(minimumDistance: 2).onChanged { value in
                            if dragOrigin == nil { dragOrigin = CGPoint(x: model.text.x, y: model.text.y) }
                            let x = min(1, max(0, dragOrigin!.x + value.translation.width / max(1, size.width)))
                            let y = min(1, max(0, dragOrigin!.y + value.translation.height / max(1, size.height)))
                            model.text.x = abs(x - 0.5) < 0.015 ? 0.5 : x
                            model.text.y = abs(y - 0.5) < 0.015 ? 0.5 : y
                        }.onEnded { _ in dragOrigin = nil })
                        .onTapGesture { textFocused = true }
                        .accessibilityElement(children:.ignore).accessibilityLabel("Text position").accessibilityIdentifier("tool.text.overlay")
                        .accessibilityHint("Drag to move, pinch to resize. Position and size controls are also below.")
                }
            }.frame(width: width, height: height).clipped().contentShape(Rectangle())
                .simultaneousGesture(MagnificationGesture().onChanged { value in
                    if pinchSize == nil { pinchSize = model.text.size }
                    model.text.size = min(0.3, max(0.02, pinchSize! * value))
                }.onEnded { _ in pinchSize = nil })
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
    }
    private var imageCanvas: some View {
        GeometryReader { geometry in
            let ratio = model.canvas.width / max(1, model.canvas.height)
            let width = min(geometry.size.width, geometry.size.height * ratio), height = width / ratio
            let image = model.displayedImage
            ZStack {
                if model.playing { PlayerSurface(player:model.player,inspectionZoom:false) }
                else if let still = model.still { Image(uiImage: still).resizable().aspectRatio(contentMode: .fit) }
                if let bitmap = model.imageBitmap {
                    Image(uiImage: bitmap).resizable().aspectRatio(contentMode: .fit)
                        .frame(width: min(width, height) * image.width).opacity(image.opacity)
                        .overlay { if dragOrigin != nil || pinchSize != nil { Rectangle().strokeBorder(.orange, lineWidth: 1) } }
                        .contentShape(Rectangle())
                        .position(x: width * image.x, y: height * image.y)
                        .gesture(DragGesture(minimumDistance: 2).onChanged { value in
                            if dragOrigin == nil { dragOrigin = CGPoint(x: model.image.x, y: model.image.y) }
                            let x = min(1, max(0, dragOrigin!.x + value.translation.width / max(1, width)))
                            let y = min(1, max(0, dragOrigin!.y + value.translation.height / max(1, height)))
                            model.image.x = abs(x - 0.5) < 0.015 ? 0.5 : x
                            model.image.y = abs(y - 0.5) < 0.015 ? 0.5 : y
                        }.onEnded { _ in dragOrigin = nil })
                        .accessibilityLabel("Image position").accessibilityIdentifier("tool.image.overlay")
                } else { Text("Choose an image below").foregroundStyle(.white).padding().background(.black.opacity(0.6), in: Capsule()) }
            }.frame(width: width, height: height).clipped().contentShape(Rectangle())
                .simultaneousGesture(MagnificationGesture().onChanged { value in
                    if pinchSize == nil { pinchSize = model.image.width }
                    model.image.width = min(3, max(0.03, pinchSize! * value))
                }.onEnded { _ in pinchSize = nil })
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
    }
    private func imageSettings(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            let imageLabel = model.loadingImage ? "Loading image…" : model.imageBitmap == nil ? "Choose image" : "Replace image"
            PhotosPicker(selection: $pickedImage, matching: .images) {
                Label(imageLabel, systemImage: "photo.on.rectangle").frame(minHeight: 44)
            }.disabled(model.loadingImage).accessibilityIdentifier("tool.image.choose")
            overlayTiming(width: width)
            Text("Drag to move · pinch to resize").font(.caption).foregroundStyle(.secondary)
            HStack { Text("Size"); Slider(value: Binding(get: { log(model.image.width) }, set: { model.image.width = exp($0) }), in: log(0.03)...log(3.0)).accessibilityLabel("Image size").accessibilityValue("\(Int((model.image.width * 100).rounded())) percent") }
            HStack { Text("Opacity"); Slider(value: $model.image.opacity, in: 0...1).accessibilityLabel("Image opacity") }
            DisclosureGroup("Position") {
                HStack { Text("Across"); Slider(value: $model.image.x, in: 0...1).accessibilityLabel("Image horizontal position") }
                HStack { Text("Down"); Slider(value: $model.image.y, in: 0...1).accessibilityLabel("Image vertical position") }
                Button("Centre image") { model.image.x = 0.5; model.image.y = 0.5 }.frame(minHeight: 44)
            }
        }
    }
    private var animationControls: EffectAnimationControls {
        EffectAnimationControls(motion:model.animation,endpoint:model.endpoint,duration:model.duration,select:model.selectEndpoint,
                                remove:model.removeAnimation,done:model.finishEndpoint,update:model.updateTiming,showsEndpointMenu:kind != .color)
    }
    private var playback: some View {
        VStack(spacing: 0) {
            if kind != .text && kind != .image {
                HStack {
                    Button { model.togglePlay() } label: { Image(systemName: model.playing ? "pause.fill" : "play.fill").frame(width: 44, height: 44) }
                        .disabled(model.busy).accessibilityLabel(model.playing ? "Pause tool preview" : "Play tool preview")
                    Spacer()
                    if kind == .color { animationControls.endpointMenu }
                    ForEach([true, false], id: \.self) { original in
                        Button(original ? "Before" : "After") { model.original = original }
                            .font(.subheadline.weight(.semibold)).padding(.horizontal, 12).frame(minHeight: 44)
                            .background(model.original == original ? Color.white.opacity(0.14) : .clear, in: Capsule())
                            .accessibilityAddTraits(model.original == original ? .isSelected : [])
                            .accessibilityIdentifier(original ? "tool.before" : "tool.after")
                    }
                }
            }
            HStack(spacing: 8) {
                if kind == .text || kind == .image {
                    Button(action:model.togglePlay) {Image(systemName:model.playing ? "pause.fill":"play.fill").frame(width:44,height:44)}
                        .disabled(model.busy).accessibilityLabel(model.playing ? "Pause " + kind.title.lowercased() + " preview" : "Play " + kind.title.lowercased() + " preview")
                }
                Text(editorTime(model.position)).accessibilityIdentifier("tool.position").font(.caption.monospacedDigit()).lineLimit(1).fixedSize()
                Slider(value: Binding(get: { model.position }, set: { model.seek($0) }), in: 0...max(TimelineEditing.frame, model.duration - TimelineEditing.frame))
                    .disabled(model.busy).accessibilityLabel("Tool preview position")
                Text(editorTime(model.duration)).accessibilityIdentifier("tool.duration").font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            }.frame(minHeight: 44)
        }
    }
    @ViewBuilder private func settings(width: CGFloat) -> some View {
        switch kind {
        case .stabilize:
            if let saved = model.savedStabilizationLevel {
                let status = editor.stabilizationStatus ?? "Applied"
                Text(status + " · " + saved.title).font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("stabilize.savedStatus")
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(StabilizationLevel.allCases) { level in
                    choice(level.title, selected: model.level == level) { model.level = level }
                        .accessibilityIdentifier("tool.level." + level.rawValue)
                }
            }
            if model.trackingWarning { Text("Some frames in this preview could not be tracked reliably.").font(.caption).foregroundStyle(.orange) }
            Text(model.level.detail).font(.callout).foregroundStyle(.secondary)
            if !showingEditorFrame {
                Text(model.level == .off ? "Original framing" : "Crop zoom \(model.cropZoom.formatted(.number.precision(.fractionLength(2))))× · Audio unchanged")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.request.range.lowerBound > 0 || model.request.range.upperBound < model.project.edit.duration {
                Text("Framing can change at the edges of this selection.").font(.caption).foregroundStyle(.secondary)
            }
        case .speed:
            Text("\(model.rate.formatted(.number.precision(.fractionLength(0...2))))×").font(.largeTitle.monospacedDigit().bold())
            Slider(value: $model.rate, in: 0.25...4, step: 0.05).accessibilityLabel("Playback speed")
            HStack(spacing: 6) { ForEach([0.5, 1, 1.5, 2], id: \.self) { rate in choice("\(rate.formatted())×", selected: abs(model.rate - rate) < 0.001) { model.rate = rate } } }
            Text("Voice pitch is preserved. Text follows the footage, so its duration changes too. Slow motion repeats source frames.").font(.caption).foregroundStyle(.secondary)
        case .color: ColorGradeControls(model: model)
        case .text: textSettings(width: width)
        case .pauses: pauseControls
        case .mirror:
            Toggle("Flip horizontally", isOn: $model.mirror.horizontal).frame(minHeight: 44).accessibilityIdentifier("tool.mirror.horizontal")
            Toggle("Flip vertically", isOn: $model.mirror.vertical).frame(minHeight: 44).accessibilityIdentifier("tool.mirror.vertical")
            Text("Flips the footage. Text and image overlays keep their orientation.").font(.caption).foregroundStyle(.secondary)
        case .image: imageSettings(width: width)
        case .subtitles, .addVideo, .addAudio, .censorAudio, .transition, .videoEffects, .enhanceAudio, .volume, .placement: EmptyView()
        case .crop: EmptyView() // Crop has its own interactive workspace.
        }
    }
    private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
            .background(selected ? kind.tint.opacity(0.3) : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 11))
            .overlay { RoundedRectangle(cornerRadius: 11).stroke(selected ? kind.tint : .clear, lineWidth: 1) }
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func textSettings(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Write something", text: $model.text.text, axis: .vertical).lineLimit(1...4)
                .textFieldStyle(.roundedBorder).focused($textFocused).accessibilityIdentifier("tool.text.input")
                .onChange(of: model.text.text) { _, value in if value.count > 500 { model.text.text = String(value.prefix(500)) } }
            overlayTiming(width: width)
            TitleInspector(design:Binding(get:{model.text.design},set:model.setTitleDesign),
                           motion:Binding(get:{model.text.motion ?? TitleMotion()},set:{model.text.motion=$0}),
                           sample:model.text.text,prefix:"title",folder:model.folder,frame:{try await TitleInspector.picture(player:model.player,at:model.start+model.position)},
                           replay:model.replayTitle, changeSection:{textFocused=false}, pauseForFonts:{ if model.playing { model.togglePlay() } })
            Text("Drag to move · pinch to resize").font(.caption).foregroundStyle(.secondary)
            HStack { Text("Size"); Slider(value: $model.text.size, in: 0.02...0.3).accessibilityLabel("Text size") }
            DisclosureGroup("Position") {
                HStack { Text("Across"); Slider(value: $model.text.x, in: 0...1).accessibilityLabel("Text horizontal position") }
                HStack { Text("Down"); Slider(value: $model.text.y, in: 0...1).accessibilityLabel("Text vertical position") }
                Button("Centre text") { model.text.x = 0.5; model.text.y = 0.5 }.frame(minHeight: 44)
            }
        }
    }
    private func overlayTiming(width: CGFloat) -> some View {
        EditorDurationPicker(title: "Duration", seconds: model.timing.duration, maximum: model.timing.available,
                             width: width, choices: EditorDurationPresets.wholeSeconds, identifier: "overlay.timing",
                             presetPrefix: "overlay.duration", onToggle: { textFocused = false }) { seconds in
            model.trim(.end, to: model.start + seconds, previewEdge: false)
        } details: {
            HStack {
                Text("\(secondsLabel(model.timing.available)) available").font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Button("To end") { model.trim(.end, to: model.timing.bounds.upperBound, previewEdge: false) }
                    .frame(minHeight: 44).accessibilityLabel("Extend to end").accessibilityIdentifier("overlay.toEnd")
            }
            HStack { Text("Start"); Spacer(); Text(editorTime(model.start)).monospacedDigit() }.font(.caption)
            trimSlider(.start, label: kind.title + " start")
            HStack { Text("End"); Spacer(); Text(editorTime(model.end)).monospacedDigit() }.font(.caption)
            trimSlider(.end, label: kind.title + " end")
        }
    }
    private func secondsLabel(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2))) + " s"
    }
    private func trimSlider(_ edge: OverlayTiming.Edge, label: String) -> some View {
        let timing = model.timing
        let limits = timing.limits(for: edge)
        let span = limits.upperBound - limits.lowerBound
        let value = edge == .start ? model.start : model.end
        // SwiftUI's stepped Slider asserts for an empty or sub-step range.
        // Keep its domain fixed while the other handle changes the available time.
        return Slider(value: Binding(
            get: { span > 0 ? min(1, max(0, (value - limits.lowerBound) / span)) : (edge == .start ? 0 : 1) },
            set: { model.trim(edge, to: model.timing.time(at: $0, edge: edge)) }
        ), in: 0...1)
        .disabled(EditTime(span) == .zero)
        .accessibilityLabel(label).accessibilityValue(editorTime(value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: model.trim(edge, to: value + TimelineEditing.frame)
            case .decrement: model.trim(edge, to: value - TimelineEditing.frame)
            @unknown default: break
            }
        }
    }
    private var pauseControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.analyzingPauses {
                Label(model.pauseSettings.levelMode == .automatic ? "Listening for speech pauses…" : "Measuring silence…", systemImage: "waveform").font(.headline)
                ProgressView(value: model.pauseScanProgress).accessibilityLabel("Pause scan progress")
            } else if model.detected {
                HStack {
                    Text("\(model.cutCount) \(model.cutCount == 1 ? "cut" : "cuts") · \(model.cutSeconds.formatted(.number.precision(.fractionLength(2)))) s shorter")
                        .font(.headline).accessibilityIdentifier("tool.pauses.summary")
                    Spacer()
                    Button { model.analyzePauses() } label: {
                        Label("Scan again", systemImage: "arrow.clockwise").font(.subheadline).frame(minHeight: 44)
                    }.accessibilityIdentifier("tool.pauses.find")
                }
                Text("\(editorTime(model.state(removing: true).duration)) → \(editorTime(model.state().duration)) in project")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if model.choices.indices.contains(model.selectedPause) {
                let choice = model.choices[model.selectedPause]
                let removable = model.cutDuration(choice)
                VStack(spacing: 8) {
                    HStack {
                        Button { model.selectPause(model.selectedPause - 1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                            .disabled(model.busy || model.selectedPause == 0).accessibilityLabel("Previous pause")
                        Spacer()
                        Text("Pause \(model.selectedPause + 1) of \(model.choices.count)").font(.subheadline).accessibilityIdentifier("tool.pauses.selection")
                        Spacer()
                        Button { model.selectPause(model.selectedPause + 1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                            .disabled(model.busy || model.selectedPause == model.choices.count - 1).accessibilityLabel("Next pause")
                    }
                    Text("At \(editorTime(model.pausePreviewRange(choice).lowerBound)) · \(model.original ? "Before" : "After")")
                        .font(.caption.monospacedDigit()).accessibilityIdentifier("tool.pauses.time")
                    if removable < TimelineEditing.frame {
                        Text("Kept: padding leaves no room to cut.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Picker("This pause", selection: Binding(get: { choice.enabled }, set: { model.setPauseEnabled($0) })) {
                            Text("Cut").tag(true); Text("Keep").tag(false)
                        }.pickerStyle(.segmented).frame(minHeight: 44).accessibilityIdentifier("tool.pauses.cut")
                        Text(choice.enabled ? "Remove \(removable.formatted(.number.precision(.fractionLength(2)))) s" : "Keep this pause in the video")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button { model.auditionPause() } label: {
                        Label(model.auditioningPause ? "Stop preview" : model.original || !choice.enabled || removable < TimelineEditing.frame ? "Listen to pause" : "Listen to cut",
                              systemImage: model.auditioningPause ? "stop.fill" : "play.fill").frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(.borderedProminent).disabled(model.busy).accessibilityIdentifier("tool.pauses.listen")
                }.padding(10).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                    .disabled(model.analyzingPauses)
            } else if model.detected {
                Text(!model.pauseAudioAvailable ? "This section has no audio to analyze." : model.pauseSettings.levelMode == .automatic
                     ? "No pauses found. Try a shorter minimum pause or choose a manual silence level in Detection settings."
                     : "No pauses found. Raise the silence level or shorten the minimum pause in Detection settings.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            DisclosureGroup("Detection settings") {
                VStack(spacing: 12) {
                    Toggle("Automatic silence level", isOn: Binding(get: { model.pauseSettings.levelMode == .automatic }, set: model.setAutomaticPauseLevel))
                        .disabled(model.analyzingPauses && model.pauseSettings.levelMode == .automatic)
                    if model.pauseSettings.levelMode == .automatic {
                        Text("Looks for breaks in speech, even when background noise continues.").font(.caption).foregroundStyle(.secondary)
                        if model.detected, let description = model.automaticLevelDescription {
                            Text(description)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        parameter("Silence below", value: $model.pauseSettings.thresholdDB, range: -65 ... -15, step: 1,
                                  suffix: model.pauseSettings.levelMode == nil ? "dBFS peak" : "dBFS RMS")
                        Text("This level applies to the selection. Raising it can include quiet speech.").font(.caption).foregroundStyle(.secondary)
                    }
                    parameter("Minimum pause", value: $model.pauseSettings.minimum, range: 0.1...3, step: 0.1, suffix: "s")
                    parameter("Keep after speech", value: $model.pauseSettings.before, range: 0...1, step: 0.02, suffix: "s")
                    parameter("Keep before speech", value: $model.pauseSettings.after, range: 0...1, step: 0.02, suffix: "s")
                    Text("Uses original audio. Changes update automatically. After extending a clip, tap Scan again.").font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 8)
            }.frame(minHeight: 44).accessibilityIdentifier("tool.pauses.settings")
            Text("Choices are saved. Removing this effect restores the pauses.").font(.caption).foregroundStyle(.secondary)
        }.onChange(of: model.pauseSettings) { old, _ in model.pauseSettingsChanged(from: old) }
    }
    private func parameter(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, suffix: String) -> some View {
        VStack(spacing: 2) {
            HStack { Text(title); Spacer(); Text("\(value.wrappedValue.formatted(.number.precision(.fractionLength(0...2)))) \(suffix)").monospacedDigit() }.font(.caption)
            Slider(value: value, in: range, step: step).accessibilityLabel(title)
        }
    }
}

#if DEBUG
enum EditorToolsDiagnostics {
    @MainActor static func run() async {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = documents.appendingPathComponent("ToolsTest", isDirectory: true)
        var report: [String: Any] = [:]
        RecordingAppDelegate.keepAwake("tools-diagnostic", active: true)
        defer { RecordingAppDelegate.keepAwake("tools-diagnostic", active: false) }
        func check(_ value: Bool, _ message: String) throws {
            if !value { throw NSError(domain: "YouRecToolsQA", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let input = folder.appendingPathComponent("shake.mp4")
            if !FileManager.default.fileExists(atPath: input.path) {
                try FileManager.default.copyItem(at: documents.appendingPathComponent("StabilizationTest/shake.mp4"), to: input)
            }
            let duration = try await AVURLAsset(url: input).load(.duration).seconds
            var project = Project(title: "Tools diagnostic"); project.append(SourceMedia(filename: "shake.mp4", duration: duration))
            var edit = TimelineEditing.split(project.edit, at: duration / 2)
            let speedID = UUID(), pauseID = UUID(), titleID = UUID(), colorID = UUID()
            for index in edit.clips.indices {
                edit.clips[index].speed = SpeedSettings(id: speedID, rate: 1.5)
                edit.clips[index].color = ColorSettings(id: colorID, look: .warm, amount: 0.75)
                edit.clips[index].texts = [TextOverlay(id: titleID, text: "YouRec · Tools QA", start: 0.5, end: duration - 0.5, x: 0.5, y: 0.25, size: 0.08, style: .box, color: .yellow)]
                edit.clips[index].stabilization = edit.clips[index].stabilizing(.light)
                let raw = SourceInterval(start: edit.clips[index].start + 1, end: min(edit.clips[index].end, edit.clips[index].start + 2))
                var pauses = PauseSettings(id: pauseID, before: 0.1, after: 0.2)
                pauses.candidates = [DetectedPause(raw: raw, enabled: index == 0)]
                pauses.analyzed = SourceInterval(start: edit.clips[index].start, end: edit.clips[index].end)
                pauses.cuts = index == 0 ? [PauseDetector.padded(raw, rate: 1.5, settings: pauses)] : []
                edit.clips[index].pauses = pauses
            }
            project.commit(edit); try project.validate()
            let ids = Set(edit.clips.map(\.id))
            let speed = ToolWorkspace(project: project, folder: folder, request: ToolRequest(tool: .speed, range: 0...edit.duration, scopeTitle: "Both clips", effectID: speedID, clipIDs: ids), position: 0)
            speed.rate = 2
            try check(speed.state().clips.allSatisfy { $0.rate == 2 }, "Re-editing a shared speed effect missed a clip")
            try check(speed.state(removing: true).clips.allSatisfy { $0.speed == nil }, "Removing a shared effect missed a clip")
            report["sharedEffectReedit"] = true
            let firstID = edit.clips[0].id, otherText = edit.clips[1].texts
            let textRequest = ToolRequest(tool: .text, range: 0...edit.clips[0].duration, scopeTitle: "This section", effectID: titleID, clipIDs: [firstID])
            let textDraft = ToolWorkspace(project: project, folder: folder, request: textRequest, position: 0)
            textDraft.text.text = "Edited section"; textDraft.trim(.end, to: textDraft.end - 0.2)
            try check(textDraft.state().clips[1].texts == otherText, "Editing one separated text fragment changed another")
            try check(textDraft.state(removing: true).clips[1].texts == otherText, "Removing one separated text fragment removed another")
            textDraft.stop(); report["separatedTextScope"] = true
            let pauses = ToolWorkspace(project: project, folder: folder, request: ToolRequest(tool: .pauses, range: 0...edit.duration, scopeTitle: "Both clips", effectID: pauseID, clipIDs: ids), position: 0)
            pauses.startPreview()
            for _ in 0..<600 where pauses.busy { try await Task.sleep(for: .milliseconds(100)) }
            try check(pauses.error == nil, pauses.error ?? "Pause preview failed")
            let old = pauses.pauseSettings; pauses.pauseSettings.before = 0.2; pauses.pauseSettingsChanged(from: old)
            try check(pauses.choices.filter { !$0.enabled }.count == 1, "Kept pause was lost on padding change")
            var revised = project; revised.commit(pauses.state()); try revised.validate()
            let reopened = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(revised)); try reopened.validate()
            try check(reopened.edit.clips.flatMap { $0.pauses?.candidates ?? [] }.filter { !$0.enabled }.count == 1, "Kept pause was lost on reopening")
            pauses.stop(); speed.stop(); report["keptPauseSurvivedPaddingAndReopen"] = true
            let output = folder.appendingPathComponent("tools-" + UUID().uuidString + ".mp4")
            let start = Date()
            _ = try await MediaRenderer.render(project: reopened, folder: folder, destination: output) { _ in }
            report["renderSeconds"] = Date().timeIntervalSince(start); report["output"] = output.lastPathComponent
            let asset = AVURLAsset(url: output)
            let exported = try await asset.load(.duration).seconds
            try check(abs(exported - reopened.edit.duration) < 0.05, "Combined export duration differs from timeline")
            report["expectedDuration"] = reopened.edit.duration; report["exportDuration"] = exported
            report["audioTracks"] = try await asset.loadTracks(withMediaType: .audio).count
            let generator = AVAssetImageGenerator(asset: asset); generator.appliesPreferredTrackTransform = true
            let frame = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 60000)).image
            report["width"] = frame.width; report["height"] = frame.height
            try UIImage(cgImage: frame).pngData()?.write(to: folder.appendingPathComponent("frame.png"))
            report["success"] = true
        } catch { report["success"] = false; report["error"] = error.localizedDescription }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: folder.appendingPathComponent("report.json"), options: .atomic) }
    }
}
#endif

#if DEBUG
// Runs only against an explicitly supplied private QA copy, never ProjectStore.
@MainActor enum PausesDiagnostics {
    static func run() async {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("PausesQA")
        var report: [String: Any] = [:]
        RecordingAppDelegate.keepAwake("pauses-qa", active: true)
        defer { RecordingAppDelegate.keepAwake("pauses-qa", active: false) }
        func check(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: "PausesQA", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func wait(_ message: String, seconds: Double = 20, until predicate: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while !predicate() {
                try check(Date() < deadline, "Timeout: " + message)
                try await Task.sleep(for: .milliseconds(40))
            }
        }
        func ready(_ model: ToolWorkspace) async throws {
            try await wait("preview composition") { !model.busy && !model.analyzingPauses }
            try check(model.error == nil, model.error ?? "Preview error")
            try await wait("player ready") { model.player.currentItem?.status == .readyToPlay || model.player.currentItem?.status == .failed }
            try check(model.player.currentItem?.status == .readyToPlay, model.player.currentItem?.error?.localizedDescription ?? "Player failed")
        }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
            let bytes = try Data(contentsOf: folder.appendingPathComponent("project.json"))
            let project = try ProjectDisk(root: folder.deletingLastPathComponent()).read(folder.appendingPathComponent("project.json"))
            let model = ToolWorkspace(project: project, folder: folder, request: ToolRequest(tool: .pauses, range: 0...project.edit.duration, scopeTitle: "QA copy"), position: 0)
            defer { model.stop() }
            // The stored reference intervals in this diagnostic predate RMS detection.
            model.pauseSettings.levelMode = nil
            model.startPreview(); try await ready(model)
            try check(model.detected && model.choices.count == 9, "Expected nine pauses in the supplied recording")
            try check(abs(model.cutSeconds - 8.29694952856) < 0.02, "Removal summary differs from source analysis")
            report["cuts"] = model.cutCount; report["removed"] = model.cutSeconds; report["originalDuration"] = project.edit.duration; report["previewDuration"] = model.duration
            if let item = model.player.currentItem {
                let generator = AVAssetImageGenerator(asset: item.asset); generator.videoComposition = item.videoComposition
                generator.maximumSize = CGSize(width: 640, height: 640)
                let frame = try await generator.image(at: CMTime(seconds: 2, preferredTimescale: 60000)).image
                try UIImage(cgImage: frame).pngData()?.write(to: folder.appendingPathComponent("preview.png"))
                report["frame"] = [frame.width, frame.height]
            }
            model.selectPause(6)
            try check(abs(model.position - model.pausePreviewRange(model.choices[6]).lowerBound) < 0.001, "Navigator did not seek")
            let afterAnchor = model.position
            model.auditionPause(); try await wait("After audition starts") { model.playing }
            try await wait("After audition restores", seconds: 6) { !model.auditioningPause }
            try check(abs(model.position - afterAnchor) < 0.001 && !model.playing, "After audition did not restore position")
            report["afterAuditionRestores"] = true
            model.selectPause(1); model.seek(7)
            try await Task.sleep(for: .milliseconds(150)); model.togglePlay()
            try await wait("main playback advances") { model.position > 7.2 }
            let lateAnchor = model.position; model.auditionPause()
            try await wait("late audition starts") { model.playing }
            try await wait("late audition restores", seconds: 6) { !model.auditioningPause }
            try check(abs(model.position - lateAnchor) < 0.1, "Listen during later playback did not restore its anchor")
            report["listenWhilePlayingPastPause"] = true
            model.seek(4)
            try await Task.sleep(for: .milliseconds(150))
            let sourceMoment = model.state().clips[0].sourceTime(at: model.position)
            model.original = true; model.rebuild(delay: false); try await ready(model)
            try check(abs(model.position - sourceMoment) < 0.04, "Before/After lost the source moment")
            report["comparisonPreservesSourceMoment"] = true
            model.selectPause(6)
            model.original = true; model.rebuild(delay: false, focusPause: true); try await ready(model)
            let beforeRange = model.pausePreviewRange(model.choices[6]), beforeAnchor = model.position
            try check(beforeRange.upperBound - beforeRange.lowerBound > 2.7, "Before audition must include the whole long pause")
            let began = Date(); model.auditionPause()
            try await wait("Before audition starts") { model.playing }
            try await wait("Before audition restores", seconds: 8) { !model.auditioningPause }
            try check(Date().timeIntervalSince(began) > 3.5, "Before audition truncated the long pause")
            try check(abs(model.position - beforeAnchor) < 0.001, "Before audition did not restore position")
            report["beforeAuditionSeconds"] = Date().timeIntervalSince(began)
            model.auditionPause(); model.auditionPause()
            try await Task.sleep(for: .milliseconds(300))
            try check(!model.auditioningPause && !model.playing, "Quick Stop raced the pending seek")
            report["immediateStop"] = true
            model.original = false; model.setPauseEnabled(false); try await ready(model)
            try check(model.cutCount == 8, "Keep did not restore the chosen pause")
            let keptRaw = model.choices[6].raw
            for threshold in [-35.0, -41, -38] {
                let old = model.pauseSettings; model.pauseSettings.thresholdDB = threshold; model.pauseSettingsChanged(from: old)
            }
            try check(model.analyzingPauses && !model.canApply, "Apply must wait for the latest detection")
            try await ready(model)
            try check(model.choices.contains { $0.raw == keptRaw && !$0.enabled }, "Automatic detection lost Keep")
            report["automaticDetectionPreservesKeep"] = true
            let previousMinimum = model.pauseSettings; model.pauseSettings.minimum = 3; model.pauseSettingsChanged(from: previousMinimum)
            try await ready(model)
            try check(model.choices.isEmpty && !model.canApply, "Empty detection should not create an effect")
            let emptySettings = model.pauseSettings; model.pauseSettings.minimum = 0.6; model.pauseSettingsChanged(from: emptySettings)
            try await ready(model)
            try check(model.choices.contains { $0.raw == keptRaw && !$0.enabled }, "A temporary empty result erased a Keep decision")
            report["keepSurvivesTemporaryEmptyDetection"] = true
            var edited = project; edited.commit(model.state()); try edited.validate()
            let reopened = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(edited))
            let clip = reopened.edit.clips[0]
            let second = ToolWorkspace(project: reopened, folder: folder, request: ToolRequest(tool: .pauses, range: 0...reopened.edit.duration, scopeTitle: "Reopened", effectID: clip.pauses!.id, clipIDs: Set(reopened.edit.clips.map(\.id))), position: 0)
            defer { second.stop() }; second.startPreview(); try await ready(second)
            try check(second.choices.contains { $0.raw == keptRaw && !$0.enabled }, "Reopened effect lost Keep")
            try check(second.state(removing: true).clips == project.edit.clips, "Remove failed to restore footage")
            edited.undo(); try check(edited.edit == project.edit, "Undo failed to restore original")
            edited.redo(); try check(edited.edit == reopened.edit, "Redo failed to restore cuts")
            report["applyUndoRedoReopenRemove"] = true
            model.stop(); second.stop()
            let scoped = ToolWorkspace(project: project, folder: folder, request: ToolRequest(tool: .pauses, range: 8...16, scopeTitle: "Middle selection"), position: 10)
            defer { scoped.stop() }; scoped.startPreview(); try await ready(scoped)
            scoped.original = true; scoped.rebuild(delay: false, focusPause: true); try await ready(scoped)
            for index in scoped.choices.indices {
                scoped.selectPause(index)
                try check(abs(scoped.position - (scoped.choices[index].raw.start - 8)) < 0.001, "Scoped navigator uses full-project time")
            }
            try check(abs(scoped.duration - 8) < 0.001, "Scoped preview contains unrelated footage")
            report["partialSelectionTimebase"] = true
            let after = try Data(contentsOf: folder.appendingPathComponent("project.json"))
            try check(after == bytes, "QA altered input manifest")
            report["success"] = true
        } catch { report["success"] = false; report["error"] = error.localizedDescription }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("report.json"), options: .atomic)
        }
    }
}
#endif
