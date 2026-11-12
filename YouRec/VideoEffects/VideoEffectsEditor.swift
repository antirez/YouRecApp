import SwiftUI
import AVKit
import PhotosUI

struct InspectorHelp: Identifiable {
    var id: String { title }
    let title: String
    let guide: String
    let history: String?
    init(title: String, guide: String, history: String?) { self.title = title; self.guide = guide; self.history = history }
    init(effect: VideoEffectID) { title = effect.descriptor.displayName; guide = effect.usageHelp; history = effect.historicalHelp }
}
struct InspectorHelpSheet: View {
    let topic: InspectorHelp
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(topic.guide).font(.body)
                    if let history = topic.history { Divider(); Text("Film technique").font(.headline); Text(history).foregroundStyle(.secondary) }
                }.frame(maxWidth: 560, alignment: .leading).padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }.navigationTitle(topic.title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.frame(minHeight: 44).accessibilityIdentifier("inspectorHelp.done") } }
        }.preferredColorScheme(.dark).presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
}
struct EffectHelpButton: View {
    let effect: VideoEffectID
    let open: (InspectorHelp) -> Void
    var body: some View {
        Button { open(InspectorHelp(effect: effect)) } label: {
            Image(systemName: "questionmark.circle").font(.body).foregroundStyle(.secondary).frame(width: 44, height: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("About " + effect.descriptor.displayName).accessibilityIdentifier("effectHelp." + effect.rawValue)
    }
}

enum VideoEffectPage:Equatable {
    case applied,library,section(VideoEffectLibrarySection),inspector
    var identity:String {switch self {case .applied:return "applied";case .library:return "library";case .section(let section):return section.id;case .inspector:return "inspector"}}
}
extension VideoEffectLibrarySection {
    var tint:Color {switch self {case .colorStyle:return .orange;case .cameraFrame:return .cyan;case .time:return .purple;case .background:return .teal}}
}

// One navigation model for live and editor effects. Rendering families stay
// internal: users browse the visible sections and edit a vertical applied list.
struct VideoEffectNavigationBar:View {
    let page:VideoEffectPage
    let count:Int
    let prefix:String
    let back:()->Void
    let add:()->Void
    private var title:String {switch page {
    case .applied:return "Applied effects · \(count)"
    case .library:return "Add effects"
    case .section(let section):return section.title
    case .inspector:return "Applied · \(count)"
    }}
    var body:some View {
        HStack(spacing:8) {
            if page == .inspector {
                Button(action:back) {Label(title,systemImage:"chevron.left").font(.subheadline.weight(.semibold)).frame(minHeight:44)}
                    .accessibilityIdentifier(prefix+".back").accessibilityLabel("Back to applied effects")
            } else {
                if page != .applied && (page != .library || count>0) {
                    Button(action:back) {Image(systemName:"chevron.left").frame(width:44,height:44)}
                        .accessibilityIdentifier(prefix+".back").accessibilityLabel(page == .library ? "Back to applied effects" : "Back to effect sections")
                }
                Text(title).font(.headline).fixedSize(horizontal:false,vertical:true).accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength:0)
            if page == .applied || page == .inspector {
                Button(action:add) {Label("Add",systemImage:"plus").font(.subheadline.weight(.semibold)).frame(minWidth:54,minHeight:44)}
                    .accessibilityLabel("Add effect").accessibilityIdentifier(prefix+".browse")
            }
        }.padding(.horizontal,12).padding(.vertical,2)
    }
}

struct VideoEffectLibrary:View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let section:VideoEffectLibrarySection?
    let live:Bool
    let chooseSection:(VideoEffectLibrarySection)->Void
    let add:(VideoEffectID)->Void
    private var prefix:String {live ? "liveEffects" : "videoEffects"}
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            if let section {
                Text(section.summary).font(.subheadline).foregroundStyle(.secondary)
                ForEach(section.effects(live:live),id:\.id) {effect in
                    Button {add(effect.id)} label: {
                        HStack(spacing:12) {
                            Image(systemName:section.symbol).font(.title3).foregroundStyle(section.tint).frame(width:28)
                            VStack(alignment:.leading,spacing:4) {
                                Text(effect.displayName).font(.headline)
                                Text(effect.id.summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                            }
                            Spacer(minLength:0);Image(systemName:"plus.circle").foregroundStyle(section.tint)
                        }.padding(12).frame(maxWidth:.infinity,minHeight:68,alignment:.leading)
                            .background(.white.opacity(0.045),in:RoundedRectangle(cornerRadius:12))
                    }.buttonStyle(.plain).accessibilityIdentifier(prefix+".add."+effect.id.rawValue)
                }
                if live && section == .time {Text("Freeze Frame and Step Printing are available in the editor.").font(.caption).foregroundStyle(.secondary)}
            } else {
                if typeSize.isAccessibilitySize {categoryRows}
                else {
                    ViewThatFits(in:.horizontal) {
                        categoryGrid.frame(minWidth:340)
                        categoryRows
                    }
                }
            }
        }
    }
    private func countLabel(_ group:VideoEffectLibrarySection)->String {
        "\(group.effects(live:live).count) effects"
    }
    private var categoryGrid:some View {
        LazyVGrid(columns:[GridItem(.flexible(),spacing:10,alignment:.top),GridItem(.flexible(),spacing:10,alignment:.top)],spacing:10) {
            ForEach(VideoEffectLibrarySection.allCases) {group in
                Button {chooseSection(group)} label: {
                    VStack(alignment:.leading,spacing:7) {
                        HStack {Image(systemName:group.symbol).foregroundStyle(group.tint);Spacer(minLength:0);Image(systemName:"chevron.right").font(.caption).foregroundStyle(.secondary)}
                        Text(group.title).font(.subheadline.weight(.semibold)).fixedSize(horizontal:false,vertical:true)
                        Text(countLabel(group)).font(.caption).foregroundStyle(.secondary)
                    }.padding(12).frame(maxWidth:.infinity,minHeight:92,alignment:.topLeading)
                        .background(group.tint.opacity(0.08),in:RoundedRectangle(cornerRadius:12))
                }.buttonStyle(.plain).accessibilityIdentifier(prefix+".section."+group.id)
            }
        }
    }
    private var categoryRows:some View {
        VStack(spacing:8) {
            ForEach(VideoEffectLibrarySection.allCases) {group in
                Button {chooseSection(group)} label: {
                    HStack(spacing:12) {
                        Image(systemName:group.symbol).font(.title3).foregroundStyle(group.tint).frame(width:28)
                        VStack(alignment:.leading,spacing:3) {
                            Text(group.title).font(.subheadline.weight(.semibold)).fixedSize(horizontal:false,vertical:true)
                            Text(countLabel(group)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength:0);Image(systemName:"chevron.right").font(.caption).foregroundStyle(.secondary)
                    }.padding(.horizontal,12).padding(.vertical,8).frame(maxWidth:.infinity,minHeight:56,alignment:.leading)
                        .background(group.tint.opacity(0.08),in:RoundedRectangle(cornerRadius:12))
                }.buttonStyle(.plain).accessibilityIdentifier(prefix+".section."+group.id)
            }
        }
    }
}

struct ChromaScreenControl:View {
    let color:EffectRGB
    let choose:(EffectRGB)->Void
    let pick:()->Void
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            HStack {
                Text("Manual screen color").font(.subheadline)
                Spacer()
                Circle().fill(Color(red:color.red,green:color.green,blue:color.blue)).frame(width:24,height:24).accessibilityHidden(true)
            }
            HStack(spacing:12) {
                Button("Green") {choose(EffectRGB(0,1,0))}.frame(minWidth:60,minHeight:44)
                Button("Blue") {choose(EffectRGB(0,0,1))}.frame(minWidth:60,minHeight:44)
                Button(action:pick) {Label("Sample",systemImage:"eyedropper").frame(minHeight:44)}.accessibilityLabel("Sample green or blue screen").accessibilityIdentifier("effects.sampleScreen")
            }.buttonStyle(.bordered)
            if !ChromaScreen.accepts(color) {Text("This saved color is not a green or blue screen. Choose Green, Blue, or sample your screen.").font(.caption).foregroundStyle(.orange)}
        }
    }
}

struct VideoEffectAppliedList:View {
    let effects:[VideoEffectSettings]
    let prefix:String
    let edit:(VideoEffectSettings)->Void
    let toggle:(VideoEffectSettings)->Void
    let remove:(VideoEffectSettings)->Void
    var body:some View {
        List {
            ForEach(effects) {effect in
                HStack(spacing:8) {
                    Button {edit(effect)} label: {
                        HStack(spacing:10) {
                            Image(systemName:effect.kind.librarySection.symbol).foregroundStyle(effect.kind.librarySection.tint).frame(width:28)
                            VStack(alignment:.leading,spacing:3) {
                                Text(effect.kind.descriptor.displayName).font(.headline).fixedSize(horizontal:false,vertical:true)
                                Text(effect.kind == .freezeFrame ? "Hold frame · tap to edit" : effect.enabled ? "On · tap to edit" : "Off · tap to edit").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength:0)
                            Image(systemName:"chevron.right").font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth:.infinity,minHeight:48,alignment:.leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel(effect.kind.descriptor.displayName)
                        .accessibilityValue(effect.enabled ? "On" : "Off").accessibilityHint("Edit effect settings")
                        .accessibilityIdentifier(prefix+".edit."+effect.id.uuidString)
                    if effect.kind != .freezeFrame {
                        Toggle(effect.kind.descriptor.displayName,isOn:Binding(get:{effect.enabled},set:{_ in toggle(effect)}))
                            .labelsHidden().fixedSize().accessibilityLabel("Enable "+effect.kind.descriptor.displayName)
                            .accessibilityIdentifier(prefix+".toggle."+effect.id.uuidString)
                    }
                }.padding(12).background(.white.opacity(0.045),in:RoundedRectangle(cornerRadius:12))
                    .listRowInsets(EdgeInsets(top:0,leading:0,bottom:0,trailing:0)).listRowSeparator(.hidden).listRowBackground(Color.clear)
                    .swipeActions(edge:.trailing,allowsFullSwipe:true) {
                        Button(role:.destructive) {remove(effect)} label: {Label("Delete",systemImage:"trash")}
                            .buttonStyle(.automatic)
                            .accessibilityIdentifier(prefix+".delete."+effect.id.uuidString)
                    }
                    .accessibilityAction(named:"Delete "+effect.kind.descriptor.displayName) {remove(effect)}
            }
        }.listStyle(.plain).scrollContentBackground(.hidden).listRowSpacing(10)
            .contentMargins(.all,0,for:.scrollContent).accessibilityIdentifier(prefix+".appliedList")
    }
}

struct VideoEffectNumberChoices:View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let title:String
    let values:[Double]
    let selected:Double
    let choose:(Double)->Void
    var body:some View {
        LazyVGrid(columns:[GridItem(.adaptive(minimum:typeSize.isAccessibilitySize ? 76 : 46),spacing:8)],spacing:8) {
            ForEach(values,id:\.self) {value in
                Button {choose(value)} label: {
                    Text(value.formatted(.number.precision(.fractionLength(0...1))))
                        .frame(maxWidth:.infinity,minHeight:44)
                        .background(selected == value ? .white.opacity(0.2) : .white.opacity(0.05),in:RoundedRectangle(cornerRadius:9))
                }.accessibilityLabel("\(title) \(value.formatted())").accessibilityAddTraits(selected == value ? .isSelected : [])
            }
        }
    }
}

extension EffectFamily {
    var tint: Color { switch self {
    case .key: return .mint; case .camera: return .cyan; case .color: return .orange
    case .quantization: return .pink; case .texture: return .yellow; case .frame: return .indigo; case .time: return .purple
    } }
    var symbol: String { switch self {
    case .key: return "person.crop.rectangle"; case .camera: return "viewfinder"; case .color: return "circle.lefthalf.filled"
    case .quantization: return "square.grid.2x2.fill"; case .texture: return "film"; case .frame: return "rectangle.ratio.16.to.9"; case .time: return "clock"
    } }
}

@MainActor final class VideoEffectsWorkspace: ObservableObject {
    let project: Project
    let folder: URL
    let request: ToolRequest
    let player = AVPlayer()
    var ids: Set<UUID>
    @Published var state: EditState
    @Published var selected: UUID? { didSet { if oldValue != selected { correctionEndpoint = nil; correctionLast = .a }; if pickingColor != nil && selected != pickingEffectID { cancelColorPick() };if positioningEffectID != nil && selected != positioningEffectID {finishPosition()} } }
    @Published var position: Double
    @Published var playing = false {didSet {if !playing {installPreparedPreview()}}}
    @Published var busy = true {didSet {if !busy {performSeek(); installPreparedPreview()}}}
    @Published var nightProgress=0.0
    var hasNightFix: Bool { state.clips.contains { $0.offlineVideoEffects.contains(where: \.needsNightFixFusion) } }
    @Published private(set) var sampleStopped = false
    func stopSample() {
        sampleStopped = true; revision = UUID()
        job?.cancel(); job = nil
        pendingSeek = nil; seekingItem = nil; player.currentItem?.cancelPendingSeeks()
        refinementJob?.cancel(); refinementJob = nil
        preparedPreview = nil; refiningPreview = false; accuratePreviewReady = false
        player.pause(); playing = false; busy = false
        RecordingAppDelegate.keepAwake(awakeReason, active: false)
    }
    func resumeSample() { sampleStopped = false; rebuild(delay: false) }
    @Published var refiningPreview=false
    @Published var accuratePreviewReady=false
    @Published var refinementError:String?
    @Published var error: String?
    @Published var bypass = false
    @Published var correctionEndpoint: EffectEndpoint? {
        didSet { if correctionEndpoint == nil { previewEndpoint = nil } }
    }
    private var previewEndpoint: EffectEndpoint?
    private var correctionLast: EffectEndpoint = .a
    var correctionRange: ClosedRange<Double> { request.videoPreviewRange(in:state,ids:ids) }
    var correctionDuration: Double { correctionRange.upperBound - correctionRange.lowerBound }
    func selectCorrection(_ e: EffectEndpoint) {
        guard let selected, current?.kind == .colorCorrection else { return }
        player.pause(); playing = false; animate = false
        let range = correctionRange, length = correctionDuration
        for pos in state.layout.placements where ids.contains(pos.clip.id) {
            guard let c = state.clips.firstIndex(where: { $0.id == pos.clip.id }),
                  let i = pos.clip.videoEffects?.firstIndex(where: { $0.id == selected }),
                  var effect = pos.clip.videoEffects?[i] else { continue }
            if effect.motion == nil {
                var motion = EffectAnimation(effect.correctionPose(at:effect.start),duration:length)
                motion.b = effect.correctionPose(at:min(effect.end,pos.clip.end))
                effect.motion = motion.anchored(to:pos.clip,offset:pos.start-range.lowerBound)
                for p in effect.parameters.indices { effect.parameters[p].keyframes = [] }
                state.clips[c].videoEffects![i] = effect
            }
        }
        correctionEndpoint = e; correctionLast = e; returnToCorrection(); rebuild(delay:false)
    }
    func returnToCorrection() {
        guard let e = correctionEndpoint, let motion = current?.motion else { return }
        seek(correctionRange.lowerBound + motion.timing.endpoint(e,duration:correctionDuration,frame:motion.frame), following: e)
    }
    func removeCorrectionAnimation() {
        let endpoint = correctionEndpoint ?? correctionLast
        correctionEndpoint = nil
        mutate { effect in
            guard let motion = effect.motion else { return }
            for (key,n) in motion[endpoint].values { effect.set(key,.number(n)) }
            effect.motion = nil
        }
    }
    func updateCorrectionTiming(_ timing: EffectTiming) {
        guard let selected, let motion = current?.motion, motion.timing != timing else { return }
        let range = correctionRange
        let start = range.lowerBound, length = range.upperBound - start
        let target = timing.previewPosition(position - start, following: previewEndpoint, duration: length, frame: motion.frame)
        player.pause(); playing = false
        position = boundedPosition(start + target)
        var edit = state
        for i in edit.timeline.video.indices where ids.contains(edit.timeline.video[i].id) {
            let item = edit.timeline.video[i]
            guard let index = item.content.videoEffects?.firstIndex(where: { $0.id == selected }),
                  var updated = item.content.videoEffects?[index].motion else { continue }
            updated.timing = timing
            updated.duration = length
            edit.timeline.video[i].content.videoEffects![index].motion = updated.anchored(to: item.content, offset: item.start.seconds - start)
        }
        state = edit
        rebuild()
    }
    func resetCorrection() {
        let pose = VideoEffectSettings(.colorCorrection).correctionPose(at:0)
        let e = correctionEndpoint ?? correctionLast
        mutate { effect in
            if effect.motion != nil { effect.motion?[e] = pose }
            else { effect.parameters = VideoEffectSettings(.colorCorrection).parameters }
        }
    }
    @Published var animate = false
    @Published var sampleMessage: String?
    @Published var samplingPalette=false
    @Published private var depthClips:Set<UUID>=[]
    @Published var pickingColor:EffectParameter?
    @Published var pickHint="Tap the color"
    private var pickingEffectID:UUID?
    @Published var positioningEffectID:UUID?
    @Published var backgroundPlacement:VideoEffectBackgroundPlacement?
    private var positionSnapshot:EditState?
    private var pendingBackgroundPlacement:VideoEffectBackgroundPlacement?
    private var backgroundPreviewAt = -Double.infinity
    private var previewCache:[Bool:(EditState,AVPlayerItem,Bool)]=[:]
    private var job: Task<Void, Never>?
    private var refinementJob:Task<Void,Never>?
    private var preparedPreview:(UUID,AVPlayerItem)?
    private var endpointPlaybackEnd: EffectPreviewEndObserver?
    private var observer: Any?
    private var scrubbing = false
    private var pendingSeek: (time: CMTime, exact: Bool)?
    private var seekingItem: AVPlayerItem?

    private var status: NSKeyValueObservation?
    private var revision = UUID()
    private let awakeReason = "video-effects-" + UUID().uuidString
    var duration: Double { state.duration }
    private(set) var sampleRange: ClosedRange<Double>?
    var previewRange: ClosedRange<Double> { sampleRange ?? request.videoPreviewRange(in: state, ids: ids) }
    private func updateSampleRange() {
        let selection = request.videoPreviewRange(in: state, ids: ids)
        let scope = EffectPreviewWindow(selection, timeline: state.timeline)
        let slow = current?.kind != .colorCorrection && state.timeline.video.contains { item in
            scope.analysisClip(item.content)?.offlineVideoEffects.isEmpty == false
        }
        let next = slow ? EffectPreviewWindow.range(at: sampleAnchor ?? position, within: selection) : nil
        if slow && sampleAnchor == nil { sampleAnchor = position }
        if !slow { sampleAnchor = nil; sampleStopped = false }
        if sampleRange != next { previewCache.removeAll(); sampleRange = next }
    }
    private var sampleAnchor: Double?
    private func renderPreview(_ candidate: Project, bypass: Bool, preparation: VideoEffectPreparation,
                               progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> TimelineMedia {
        let window = sampleRange.map { EffectPreviewWindow($0, timeline: candidate.edit.timeline) }
        return try await VideoEffectPreparation.$inspectionWindow.withValue(window) {
            try await MediaRenderer.timeline(project: candidate, folder: folder, videoProgress: progress,
                previewDiagnostics: true, bypassVideoEffects: bypass, effectPreparation: preparation)
        }
    }
    var previewSeekRange:ClosedRange<Double> {previewRange.lowerBound...max(previewRange.lowerBound+0.001,previewRange.upperBound-1.0/30)}
    private func boundedPosition(_ time:Double)->Double {min(previewSeekRange.upperBound,max(previewSeekRange.lowerBound,time))}
    private func bound(_ item:AVPlayerItem) {
        item.reversePlaybackEndTime=CMTime(seconds:previewRange.lowerBound,preferredTimescale:60000)
        item.forwardPlaybackEndTime=CMTime(seconds:previewRange.upperBound,preferredTimescale:60000)
    }
    var placement: TimelinePlacement? { state.layout.placement(at: min(position, max(0, duration-0.001))) }
    var sourceTime: Double { placement.map { $0.clip.sourceTime(at: position-$0.start) } ?? 0 }
    var active: [VideoEffectSettings] {
        VideoEffectSettings.ordered(placement?.clip.videoEffects ?? []).filter { sourceTime >= $0.start && sourceTime < $0.end }
    }
    var current: VideoEffectSettings? {
        active.first { $0.id == selected } ?? state.clips.flatMap { $0.videoEffects ?? [] }.first { $0.id == selected }
    }
    private var depthScope:[TimelineClip] {
        guard let selected else {return state.clips.filter {ids.contains($0.id)}}
        return state.clips.filter {$0.videoEffects?.contains(where:{$0.id==selected})==true}
    }
    var hasDepth:Bool {depthScope.contains {depthClips.contains($0.id)}}
    var depthNote:String {
        let count=depthScope.filter {depthClips.contains($0.id)}.count
        #if targetEnvironment(simulator) && !canImport(Cinematic)
        return "Cinematic depth editing requires a physical iPhone."
        #else
        if count==0 {return refiningPreview || busy ? "Checking for imported depth…" : "No usable depth in these clips. Oval bokeh requires an original Cinematic video with depth."}
        #endif
        if count<depthScope.count {return "Depth is available on \(count) of \(depthScope.count) clips. Other clips keep their original focus."}
        return "Uses depth and focus from the original Cinematic video."
    }
    private func updateDepthAvailability(_ item:AVPlayerItem) {
        guard !bypass else {return}
        let layers=item.videoComposition?.instructions.flatMap {instruction->[VideoToolInstruction] in
            (instruction as? TrackVideoInstruction).map { Array($0.layers.values) } ?? (instruction as? TransitionVideoInstruction)?.layers ?? (instruction as? VideoToolInstruction).map {[$0]} ?? []
        } ?? []
        // Source identity/framing cannot change in this workspace. Keep known
        // capabilities while a look is disabled or compared with the original.
        depthClips.formUnion(layers.filter {$0.effectDepth != nil}.map { $0.clip.id })
    }
    init(project: Project, folder: URL, request: ToolRequest, position: Double) {
        self.project = project; self.folder = folder; self.request = request
        let scoped = request.videoScope(in: project.edit)
        state = scoped.0; ids = scoped.1; selected = request.effectID
        self.position = min(max(request.range.lowerBound, position), max(request.range.lowerBound, request.range.upperBound - 1.0/30))
        endpointPlaybackEnd = EffectPreviewEndObserver(player:player) { [weak self] in
            guard let self, self.correctionEndpoint != nil else { return }
            self.playing = false; self.returnToCorrection()
        }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 15), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self, !self.scrubbing, self.seekingItem == nil, self.pendingSeek == nil else { return }
                self.playing = self.player.rate > 0
                if self.playing && time.seconds.isFinite { self.position = self.boundedPosition(time.seconds) }
                if time.seconds >= self.previewRange.upperBound - 0.02 { self.player.pause(); self.playing = false; self.returnToCorrection() }
            }
        }
    }
    deinit { if let observer { player.removeTimeObserver(observer) }; job?.cancel();refinementJob?.cancel() }
    func stop() {
        revision = UUID()
        job?.cancel(); refinementJob?.cancel(); preparedPreview = nil
        pendingSeek = nil; seekingItem = nil; scrubbing = false
        status = nil; player.pause(); player.currentItem?.cancelPendingSeeks()
        player.replaceCurrentItem(with: nil); previewCache.removeAll()
        RecordingAppDelegate.keepAwake(awakeReason, active: false)
    }

    func add(_ kind: VideoEffectID) {
        if kind == .freezeFrame {
            let result = TimelineEditing.freezing(state, at: position)
            guard let effectID = result.1 else { error = "Move the playhead outside a transition to freeze one frame."; return }
            state = result.0; selected = effectID
            ids.formUnion(state.clips.filter { $0.videoEffects?.contains(where: { $0.id == effectID }) == true }.map(\.id))
            rebuild(); return
        }
        if kind == .nightFix,let existing=state.clips.filter({ids.contains($0.id)}).flatMap({$0.videoEffects ?? []}).first(where:{$0.kind == .nightFix}) {
            selected=existing.id;rebuild();return
        }
        if kind == .negativeStrobe { player.pause(); playing = false }
        let starts = kind == .negativeStrobe ? Dictionary(uniqueKeysWithValues: state.layout.placements.map { ($0.clip.id, $0.start) }) : [:]
        let rangeStart = starts.filter { ids.contains($0.key) }.values.min() ?? 0
        let id = UUID()
        for index in state.clips.indices where ids.contains(state.clips[index].id) {
            let clip = state.clips[index]
            var effect = VideoEffectSettings(kind, start: clip.start, end: clip.end); effect.id = id
            if kind == .negativeStrobe {
                effect.phaseOffset = max(0, (starts[clip.id] ?? rangeStart) - rangeStart)
                let spans = clip.effectPlaybackSpans
                if clip.frozenFrame == nil && (spans.count > 1 || spans.first?.rate != 1), let first = spans.first {
                    var elapsed = 0.0, points = [StrobeTimePoint(source: first.start, elapsed: 0)]
                    for span in spans {
                        if span.start > points.last!.source { points.append(.init(source: span.start, elapsed: elapsed)) }
                        elapsed += span.duration
                        points.append(.init(source: span.end, elapsed: elapsed))
                    }
                    effect.strobeTimeMap = points
                }
            }
            state.clips[index].videoEffects = (clip.videoEffects ?? []) + [effect]
        }
        selected = id; rebuild()
    }
    func mutate(_ action: (inout VideoEffectSettings) -> Void) {
        guard let selected else { return }
        let time=sourceTime
        for c in state.clips.indices where ids.contains(state.clips[c].id) {
            for e in (state.clips[c].videoEffects ?? []).indices where state.clips[c].videoEffects![e].id == selected {
                let previous=state.clips[c].videoEffects![e]
                action(&state.clips[c].videoEffects![e])
                state.clips[c].videoEffects![e].sanitizeBackgroundMedia(at:time)
                retimeCapturedCrash(clip:c,effect:e,previous:previous)
                if state.clips[c].videoEffects![e].kind == .freezeFrame { state.clips[c].frozenFrame?.duration = state.clips[c].videoEffects![e].number("hold", at: state.clips[c].start) }
            }
        }
        rebuild()
    }
    func set(_ parameter: EffectParameter, _ value: EffectValue) {
        guard parameter.kind.accepts(value) else { return }
        if current?.kind == .colorCorrection, current?.motion != nil, case .number(let n) = value {
            let e = correctionEndpoint ?? correctionLast; correctionEndpoint = e
            returnToCorrection()
            mutate { effect in
                guard var motion = effect.motion else { return }; motion[e].values[parameter.id] = n; effect.motion = motion
            }
            return
        }
        if parameter.id == "sourceAngle", current?.kind == .kaleidoscope, current?.enabled == true,
           !busy, !bypass, case .number(let degrees) = value {
            adjustOpticalEffect([parameter.id: degrees])
            return
        }
        if parameter.id=="lockPalette",value == .toggle(true),!animate {
            Task { await samplePalette(lockOnly:true) };return
        }
        if parameter.id=="view" {
            mutate { effect in if let index=effect.parameters.firstIndex(where:{$0.id=="view"}) { effect.parameters[index].value=value;effect.parameters[index].keyframes=[] } };return
        }
        if parameter.id=="screenColor",case .color(let color)=value {
            guard ChromaScreen.accepts(color) else {pickHint=ChromaScreen.invalidSample;return}
            // Screen sampling is calibration, not a color animation across
            // unsupported neutral colors between green and blue keyframes.
            mutate {effect in
                effect.set("autoScreen",.toggle(false));effect.set("screenType",.choice("Auto"))
                if let index=effect.parameters.firstIndex(where:{$0.id=="screenColor"}) {effect.parameters[index].value=value;effect.parameters[index].keyframes=[]}
            };return
        }
        let time = sourceTime, clipID = placement?.clip.id
        let resampleLock=parameter.id=="colors" && current?.toggle("lockPalette",at:time)==true && !animate
        if animate && parameter.animatable {
            for c in state.clips.indices where state.clips[c].id == clipID {
                for e in (state.clips[c].videoEffects ?? []).indices where state.clips[c].videoEffects![e].id == selected {
                    guard let p = state.clips[c].videoEffects![e].parameters.firstIndex(where: { $0.id == parameter.id }) else { continue }
                    let previous=state.clips[c].videoEffects![e]
                    if state.clips[c].videoEffects![e].parameters[p].keyframes.isEmpty && time > state.clips[c].start + 0.001 {
                        state.clips[c].videoEffects![e].parameters[p].setKeyframe(at: state.clips[c].start, value: parameter.value)
                    }
                    state.clips[c].videoEffects![e].parameters[p].setKeyframe(at: time, value: value)
                    state.clips[c].videoEffects![e].sanitizeBackgroundMedia(at:time)
                    retimeCapturedCrash(clip:c,effect:e,previous:previous)
                }
            }
            rebuild()
        } else {
            mutate { effect in
                guard let index = effect.parameters.firstIndex(where: { $0.id == parameter.id }) else { return }
                effect.parameters[index].value = value
                // Changing a control with existing animation edits the key at
                // the playhead, never silently erases its animation.
                if !effect.parameters[index].keyframes.isEmpty { effect.parameters[index].setKeyframe(at: time, value: value) }
            }
        }
        if resampleLock { Task { await samplePalette(lockOnly:true) } }
    }
    func keyframe(_ parameter: EffectParameter) {
        guard let selected, let clipID = placement?.clip.id else { return }
        let time = sourceTime
        for c in state.clips.indices where state.clips[c].id == clipID {
            for e in (state.clips[c].videoEffects ?? []).indices where state.clips[c].videoEffects![e].id == selected {
                guard let p = state.clips[c].videoEffects![e].parameters.firstIndex(where: { $0.id == parameter.id }) else { continue }
                let previous=state.clips[c].videoEffects![e]
                if let index = parameter.keyframes.firstIndex(where: { abs($0.time-time) < 1.0/60 }) {
                    state.clips[c].videoEffects![e].parameters[p].keyframes.remove(at: index)
                } else { state.clips[c].videoEffects![e].parameters[p].setKeyframe(at: time, value: parameter.value(at: time)) }
                retimeCapturedCrash(clip:c,effect:e,previous:previous)
            }
        }
        rebuild()
    }
    func remove() {
        state.clips.removeAll { clip in ids.contains(clip.id) && clip.frozenFrame != nil && clip.videoEffects?.contains { $0.id == selected && $0.kind == .freezeFrame } == true }
        for index in state.clips.indices where ids.contains(state.clips[index].id) {
            state.clips[index].videoEffects?.removeAll { $0.id == selected }
            if state.clips[index].videoEffects?.isEmpty == true { state.clips[index].videoEffects = nil }
        }
        selected = active.first?.id; rebuild()
    }
    func scrub(_ active: Bool) {
        scrubbing = active
        if active { player.pause(); playing = false }
        else { seek(position) }
    }
    func seek(_ value: Double, following selected: EffectEndpoint? = nil) {
        guard value.isFinite else { return }
        previewEndpoint = selected
        if positioningEffectID != nil { finishPosition() }
        position = boundedPosition(value)
        pendingSeek = (CMTime(seconds: position, preferredTimescale: 60000), !scrubbing)
        performSeek()
    }
    private func performSeek() {
        guard !busy, seekingItem == nil, let target = pendingSeek,
              let item = player.currentItem, item.status == .readyToPlay else { return }
        seekingItem = item; pendingSeek = nil
        let tolerance = target.exact ? CMTime.zero : CMTime(seconds: 0.08, preferredTimescale: 60000)
        player.seek(to: target.time, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self, weak item] _ in
            Task { @MainActor in
                guard let self, let item, self.seekingItem === item else { return }
                self.seekingItem = nil
                self.performSeek()
                self.installPreparedPreview()
            }
        }
    }
    func togglePlay() {
        if positioningEffectID != nil {finishPosition();return}
        if playing { player.pause(); playing = false; returnToCorrection() }
        else { if correctionEndpoint != nil || position >= previewRange.upperBound-0.05 || position < previewRange.lowerBound { seek(previewRange.lowerBound) }; player.play(); playing = true }
    }
    private func retimeCapturedCrash(clip:Int,effect:Int,previous:VideoEffectSettings) {
        guard let effects=state.clips[clip].videoEffects else {return}
        let limit=effects.filter {$0.kind == .crashZoom && $0.start>effects[effect].start}.map(\.start).min() ?? state.clips[clip].end
        state.clips[clip].videoEffects![effect].retimeCapturedCrash(after:previous,limit:min(state.clips[clip].end,limit))
    }
    func rebuild(delay: Bool = true) {
        updateSampleRange()
        refinementJob?.cancel();preparedPreview=nil;refiningPreview=false;accuratePreviewReady=false;refinementError=nil
        pendingSeek = nil; seekingItem = nil; job?.cancel(); let token = UUID(); revision = token
        let resume = playing; player.pause(); playing = false; busy = true; error = nil
        let position = boundedPosition(position),cacheState=state,cacheMode=bypass,cacheable=pickingColor==nil && positioningEffectID==nil
        if previewCache.values.contains(where:{$0.0 != state}) { previewCache.removeAll() }
        var candidate = project, edit = state
        if let selected,pickingColor != nil {
            for index in edit.clips.indices where edit.clips[index].videoEffects?.contains(where:{$0.id==selected})==true {
                edit.clips[index].videoEffects=VideoEffectAnalysis.prefix(edit.clips[index].videoEffects ?? [],before:selected)
                edit.clips[index].texts=nil;edit.clips[index].images=nil
            }
        }
        if let id=positioningEffectID {
            for index in edit.clips.indices {
                guard let effect=edit.clips[index].videoEffects?.first(where:{$0.id==id}) else {continue}
                var framing=effect;framing.enabled=true
                edit.clips[index].videoEffects=VideoEffectAnalysis.prefix(edit.clips[index].videoEffects ?? [],before:id)+[framing]
                edit.clips[index].texts=nil;edit.clips[index].images=nil
            }
        }
        candidate.commit(edit)
        job = Task {
            defer { if revision == token { busy = false; RecordingAppDelegate.keepAwake(awakeReason, active: false) } }
            do {
                if delay { try await Task.sleep(for: .milliseconds(180)) }
                RecordingAppDelegate.keepAwake(awakeReason, active: true)
                let item:AVPlayerItem
                let pending:Bool
                if cacheable,let cached=previewCache[cacheMode],cached.0==cacheState { item=cached.1;pending=cached.2 }
                else {
                    let media=try await renderPreview(candidate, bypass: cacheMode && cacheable, preparation: .cached)
                    try Task.checkCancellation();guard token==revision else { return }
                    item=AVPlayerItem(asset:media.composition);item.videoComposition=media.playbackVideoComposition;item.audioMix=media.audioMix
                    pending=media.effectAnalysisPending
                    item.audioTimePitchAlgorithm = .spectral
                    if cacheable { previewCache[cacheMode]=(cacheState,item,pending) }
                }
                updateDepthAvailability(item)
                if pendingSeek == nil { self.position = position }; bound(item); observe(item,token:token)
                player.replaceCurrentItem(with: item)
                await player.seek(to: CMTime(seconds: position, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
                try Task.checkCancellation(); guard token == revision else { return }
                if resume && !scrubbing && pendingSeek == nil { player.play(); playing = true }
                if pending && cacheable {prepareAccuratePreview(candidate: candidate,state:cacheState,mode:cacheMode,token:token)}
            } catch is CancellationError {} catch { if token == revision { self.error = error.localizedDescription } }
        }
    }
    private func observe(_ item:AVPlayerItem,token:UUID) {
        status=item.observe(\.status,options:[.new]) {[weak self] value,_ in
            if value.status == .readyToPlay {
                Task { @MainActor in if self?.revision == token { self?.performSeek() } }
            } else if value.status == .failed {
                let message=value.error?.localizedDescription ?? "The effects preview could not be played."
                Task {@MainActor in guard self?.revision==token else {return};self?.error=message;self?.playing=false}
            }
        }
    }
    private func prepareAccuratePreview(candidate:Project,state:EditState,mode:Bool,token:UUID) {
        guard !sampleStopped else { return }
        refiningPreview=true;nightProgress=0
        refinementJob=Task(priority:.utility) {
            let reason=awakeReason+"-night-"+UUID().uuidString
            if hasNightFix {RecordingAppDelegate.keepAwake(reason,active:true)}
            defer {RecordingAppDelegate.keepAwake(reason,active:false)}
            do {
                let media=try await VideoEffectPreparation.refine {
                    try await renderPreview(candidate, bypass: mode, preparation: .refinedPreview) { value in Task { @MainActor in if self.revision == token { self.nightProgress = value } } }
                }
                try Task.checkCancellation();guard revision==token else {return}
                let item=AVPlayerItem(asset:media.composition);item.videoComposition=media.playbackVideoComposition;item.audioMix=media.audioMix
                item.audioTimePitchAlgorithm = .spectral
                previewCache[mode]=(state,item,false);preparedPreview=(token,item);updateDepthAvailability(item)
                refiningPreview=false;accuratePreviewReady=true;installPreparedPreview()
            } catch is CancellationError {} catch {
                guard revision==token else {return}
                refiningPreview=false;refinementError=error.localizedDescription
            }
        }
    }
    private func installPreparedPreview() {
        guard !playing,!busy,!scrubbing,seekingItem == nil,pendingSeek == nil,player.timeControlStatus == .paused,let (token,item)=preparedPreview,token==revision else {return}
        preparedPreview=nil;accuratePreviewReady=false;busy=true
        let position=boundedPosition(position)
        job=Task {
            defer {if revision==token {busy=false}}
            guard revision==token else {return}
            self.position=position;bound(item);observe(item,token:token);player.replaceCurrentItem(with:item)
            await player.seek(to:CMTime(seconds:position,preferredTimescale:60000),toleranceBefore:.zero,toleranceAfter:.zero)
        }
    }
    var previewCanvas: CGSize {
        player.currentItem?.videoComposition?.renderSize ?? player.currentItem?.presentationSize ?? .zero
    }
    func adjustOpticalEffect(_ values: [String: Double]) {
        guard !busy, !bypass, let effect = current, effect.enabled else { return }
        let needsAnalysis = refiningPreview || active.contains { [.quantization, .colorIsolation, .chromaKey, .autoBackground, .dollyZoom, .nightFix].contains($0.kind) }
        preparedPreview = nil
        if playing { player.pause(); playing = false }
        updatePosition(values: values, id: effect.id)
        guard needsAnalysis, !busy else { return }
        // Existing instructions give immediate pixels while dragging. Refresh
        // palette/matte dependencies once the user settles on a new position.
        let edited = state, token = revision
        refinementJob?.cancel()
        refinementJob = Task {
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard revision == token, state == edited, !bypass else { return }
            var candidate = project; candidate.commit(edited)
            prepareAccuratePreview(candidate: candidate, state: edited, mode: false, token: token)
        }
    }
    func beginBackgroundPosition() async {
        guard let effect=current,case .media(let file)=effect.value("media",at:sourceTime),let file else {return}
        player.pause();playing=false;cancelColorPick()
        do {
            let media=try await VideoEffectBackgroundMedia.size(at:folder.appendingPathComponent(file))
            guard selected==effect.id,current==effect else {return}
            let canvas=player.currentItem?.presentationSize ?? .zero
            guard canvas.width>0,canvas.height>0 else {throw ProjectError.invalidMedia}
            positionSnapshot=state;backgroundPlacement=VideoEffectBackgroundPlacement(x:effect.number("backgroundX",at:sourceTime),y:effect.number("backgroundY",at:sourceTime),zoom:effect.number("backgroundZoom",at:sourceTime),canvas:canvas,media:media,fill:effect.choice("fit",at:sourceTime) != "Fit")
            pendingBackgroundPlacement=backgroundPlacement
            positioningEffectID=effect.id;bypass=false;rebuild(delay:false)
            UIAccessibility.post(notification:.announcement,argument:"Positioning background. Drag to move, pinch to scale. Preview actions also move and resize it.")
        } catch {self.error=error.localizedDescription}
    }
    func changeBackground(_ gesture:VideoEffectPlacementGesture) {
        guard !busy,let id=positioningEffectID,var placement=pendingBackgroundPlacement else {return}
        placement.apply(gesture);pendingBackgroundPlacement=placement
        let now=ProcessInfo.processInfo.systemUptime
        if case .ended=gesture {} else if now-backgroundPreviewAt<1.0/30 {return}
        backgroundPreviewAt=now;backgroundPlacement=placement
        updatePosition(values: ["backgroundX": placement.x, "backgroundY": placement.y, "backgroundZoom": placement.zoom], id: id)
    }
    private func updatePosition(values: [String: Double], id: UUID) {
        let currentPlacement = placement
        let time = currentPlacement.map { $0.clip.sourceTime(at: position - $0.start) } ?? 0
        let currentClip = currentPlacement?.clip.id
        var edit = state
        var changed: [UUID: VideoEffectSettings] = [:]
        // These gestures change only spatial values. Edit the affected video
        // items directly instead of re-projecting and retiming the timeline for each axis.
        for i in edit.timeline.video.indices {
            let clip = edit.timeline.video[i].content
            guard ids.contains(clip.id), !animate || clip.id == currentClip,
                  let effects = clip.videoEffects, let e = effects.firstIndex(where: { $0.id == id }) else { continue }
            var effect = effects[e]
            for p in effect.parameters.indices {
                var parameter = effect.parameters[p]
                guard let number = values[parameter.id], parameter.kind.accepts(.number(number)),
                      case .number(let prior) = parameter.value(at: time), abs(prior - number) > 0.000001 else { continue }
                if animate && parameter.keyframes.isEmpty && time > clip.start + 0.001 {
                    parameter.setKeyframe(at: clip.start, value: parameter.value)
                }
                if animate || !parameter.keyframes.isEmpty { parameter.setKeyframe(at: time, value: .number(number)) }
                else { parameter.value = .number(number) }
                effect.parameters[p] = parameter
            }
            guard effect != effects[e] else { continue }
            edit.timeline.video[i].content.videoEffects![e] = effect
            changed[clip.id] = effect
        }
        guard !changed.isEmpty else { return }
        refinementJob?.cancel(); preparedPreview = nil; refiningPreview = false
        previewCache.removeAll()
        state = edit
        guard let item = player.currentItem, let composition = item.videoComposition?.mutableCopy() as? AVMutableVideoComposition else { rebuild(delay: false); return }
        for instruction in composition.instructions {
            for layer in instruction.toolLayers {
                guard var effect = changed[layer.clip.id] else { continue }
                if positioningEffectID == id { effect.enabled = true }
                layer.previewEffects(layer.effectSettings.map { $0.id == id ? effect : $0 })
            }
        }
        // Apple QA1966: a new composition instance redraws a paused frame.
        item.videoComposition=composition
    }
    func resetBackgroundPosition() {
        guard var placement=pendingBackgroundPlacement else {return}
        placement.x=0.5;placement.y=0.5;placement.zoom=1;pendingBackgroundPlacement=placement;changeBackground(.ended)
    }
    func finishPosition(cancel:Bool=false) {
        guard positioningEffectID != nil else {return}
        if cancel,let snapshot=positionSnapshot {state=snapshot}
        else {changeBackground(.ended)}
        positioningEffectID=nil;backgroundPlacement=nil;pendingBackgroundPlacement=nil;positionSnapshot=nil;rebuild(delay:false)
    }
    func importMedia(_ item: PhotosPickerItem, parameter: EffectParameter) async {
        let target=selected
        do {
            let name: String
            let isMovie=item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) })
            guard case let .media(images,videos)=parameter.kind,(isMovie ? videos : images),parameter.id != "cleanPlate" || !isMovie else { throw ProjectError.invalidMedia }
            if isMovie {
                guard let movie = try await item.loadTransferable(type: ImportedPhotoMedia.self), !movie.isPhoto else { throw ProjectError.invalidMedia }
                defer { try? FileManager.default.removeItem(at: movie.url) }
                name = "effect-" + UUID().uuidString + ".mov"
                try FileManager.default.copyItem(at: movie.url, to: folder.appendingPathComponent(name))
            } else {
                guard let data = try await item.loadTransferable(type: Data.self) else { throw ProjectError.missingImage }
                var size:CGSize?
                if parameter.id=="cleanPlate",let clip=placement?.clip,let source=project.sources.first(where:{$0.id==clip.sourceID}) {
                    let asset=AVURLAsset(url:folder.appendingPathComponent(source.filename))
                    guard let track=try await asset.loadTracks(withMediaType:.video).first else {throw ProjectError.invalidMedia}
                    let natural=try await track.load(.naturalSize),transform=try await track.load(.preferredTransform)
                    size=CGRect(origin:.zero,size:natural).applying(transform).size
                }
                let png=try VideoEffectCleanPlate.importedPNG(data,matching:size)
                name = "effect-" + UUID().uuidString + ".png"
                try png.write(to: folder.appendingPathComponent(name), options: .atomic)
            }
            guard selected==target else { return }
            if parameter.id=="media" { mutate { $0.set("background",.choice(isMovie ? "Video" : "Image")) } }
            set(parameter, .media(name))
        } catch { self.error = error.localizedDescription }
    }
    private func samplingInstruction(clip original:TimelineClip) async throws -> VideoToolInstruction {
        var single=project,clip=original
        clip.videoEffects=nil;clip.openingTransition=nil;clip.transition=nil;clip.texts=nil;clip.images=nil
        let canvas = try await MediaRenderer.canvas(project: project, folder: folder)
        single.commit(EditState(clips: [clip], outputSize: canvas))
        let media=try await MediaRenderer.timeline(project:single,folder:folder,forceCustom:true,includeBackgroundAudio:false,effectPreparation:.cached)
        guard let base=media.videoComposition.instructions.first as? VideoToolInstruction else { throw ProjectError.invalidMedia }
        var sampledClip=original
        if pickingColor != nil,let selected {sampledClip.videoEffects=VideoEffectAnalysis.prefix(original.videoEffects ?? [],before:selected)}
        let instruction=VideoToolInstruction(trackID:base.trackID,clip:sampledClip,start:.zero,transform:base.transform,sourceSize:base.sourceSize,canvas:base.canvas,stabilization:base.stabilization,fontFolder:folder,sequenceClock:VideoEffectSequenceClock(sampledClip))
        let displayed=player.currentItem?.videoComposition?.instructions.flatMap {item->[VideoToolInstruction] in
            if let single=item as? VideoToolInstruction {return [single]}
            return (item as? TrackVideoInstruction).map { Array($0.layers.values) } ?? (item as? TransitionVideoInstruction)?.layers ?? []
        }.first {$0.clip.id==original.id && $0.clip.start<=sourceTime && $0.clip.end>sourceTime}
        instruction.maskSource = displayed?.maskSource ?? base.maskSource
        instruction.effectMasks=displayed?.effectMasks ?? base.effectMasks
        instruction.effectDepth=displayed?.effectDepth ?? base.effectDepth
        instruction.effectSubjects=displayed?.effectSubjects ?? base.effectSubjects
        instruction.effectMatteHistories=displayed?.effectMatteHistories ?? base.effectMatteHistories
        instruction.effectAnalysisPending=displayed?.effectAnalysisPending ?? base.effectAnalysisPending
        instruction.effectFolder=folder
        if let source=project.sources.first(where:{$0.id==original.sourceID}) {instruction.sourceURL=folder.appendingPathComponent(source.filename)}
        if sampledClip.videoEffects?.contains(where:{$0.enabled && ($0.kind == .stepPrinting || $0.usesTemporalMatte)})==true,
           let source=project.sources.first(where:{$0.id==original.sourceID}) {
            instruction.sourceFrames=try await VideoEffectFrameAnalysis.shared.index(url:folder.appendingPathComponent(source.filename),folder:folder)
        }
        instruction.sourceFPS=base.sourceFPS;instruction.sourceHDR=base.sourceHDR;instruction.sourceLog=base.sourceLog;instruction.hdr=base.hdr;return instruction
    }
    func beginColorPick(_ parameter:EffectParameter) {
        if positioningEffectID != nil {finishPosition()}
        player.pause();playing=false;pickingEffectID=selected;pickHint=parameter.id=="screenColor" ? "Tap the green or blue screen" : "Tap the color";pickingColor=parameter;rebuild(delay:false)
    }
    func cancelColorPick() { guard pickingColor != nil else { return };pickingColor=nil;pickingEffectID=nil;rebuild(delay:false) }
    func pickColor(at point:CGPoint) async {
        guard !busy,let parameter=pickingColor,let placement,let effect=current,effect.id==pickingEffectID,let source=project.sources.first(where:{$0.id==placement.clip.sourceID}) else { return }
        let target=selected,time=sourceTime
        busy=true
        do {
            let instruction=try await samplingInstruction(clip:placement.clip)
            let color=try await VideoEffectAnalysis.shared.color(source:source,effect:effect,folder:folder,instruction:instruction,time:time,point:point)
            guard target==selected else { busy=false;return }
            if parameter.id=="screenColor",!ChromaScreen.accepts(color) {pickHint=ChromaScreen.invalidSample;busy=false;return}
            if effect.kind == .colorIsolation,parameter.id=="color",!IsolationHue.accepts(color) {pickHint=IsolationHue.invalidSample;busy=false;return}
            pickingColor=nil;pickingEffectID=nil;set(parameter,.color(color))
        } catch { self.error=error.localizedDescription;busy=false }
    }
    func samplePalette(lockOnly:Bool=false) async {
        guard !samplingPalette,let placement,let effect=current,let source=project.sources.first(where:{$0.id==placement.clip.sourceID}) else { return }
        let target=selected,time=sourceTime,original=placement.clip
        samplingPalette=true;defer { samplingPalette=false }
        do {
            let instruction=try await samplingInstruction(clip:original)
            let count=Int(effect.number("colors",at:time))
            let palette=try await VideoEffectAnalysis.shared.sample(source:source,effect:effect,folder:folder,instruction:instruction,time:time,count:count)
            guard selected==target else { return }
            mutate { effect in
                if lockOnly {
                    effect.lockedPalette=palette;effect.set("lockPalette",.toggle(true))
                    if let index=effect.parameters.firstIndex(where:{$0.id=="lockPalette"}),!effect.parameters[index].keyframes.isEmpty { effect.parameters[index].setKeyframe(at:time,value:.toggle(true)) }
                }
                else {
                    effect.palette = palette.colors
                    effect.set("palette", .choice("Saved"))
                    if let index = effect.parameters.firstIndex(where: { $0.id == "palette" }), !effect.parameters[index].keyframes.isEmpty {
                        effect.parameters[index].setKeyframe(at: time, value: .choice("Saved"))
                    }
                }
            }
            sampleMessage=lockOnly ? "Palette locked to this frame · \(count) colours" : "Palette saved in this project"
        } catch { self.error=error.localizedDescription }
    }

}

struct VideoEffectsEditor: View {
    @StateObject private var model: VideoEffectsWorkspace
    @State private var page = VideoEffectPage.library
    @State private var confirmRemove = false
    @State private var helpTopic: InspectorHelp?
    @State private var correctionTab=0
    @State private var correctionAdvanced=false
    @State private var photo: PhotosPickerItem?
    @State private var mediaParameter: EffectParameter?
    @State private var showPhotoPicker = false
    @State private var showSpinner=false
    let cancel: () -> Void
    let apply: (EditState) -> Void
    init(project: Project, folder: URL, request: ToolRequest, position: Double, cancel: @escaping () -> Void, apply: @escaping (EditState) -> Void) {
        _model = StateObject(wrappedValue: VideoEffectsWorkspace(project: project, folder: folder, request: request, position: position))
        self.cancel = cancel; self.apply = apply
    }
    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width > geometry.size.height * 1.25
            VStack(spacing: 0) {
                header
                if wide {
                    HStack(spacing: 0) {
                        preview.frame(maxWidth: .infinity, maxHeight: .infinity)
                        controls.frame(width: min(340, geometry.size.width*0.36))
                    }
                } else {
                    preview.frame(height: max(180, geometry.size.height * (inspectedSplit == nil ? 0.40 : 0.53)))
                    controls
                }
            }.background(Color(white: 0.035))
        }.preferredColorScheme(.dark)
            .task(id:model.busy) {
                showSpinner=false
                if model.busy { try? await Task.sleep(for:.milliseconds(300));if !Task.isCancelled && model.busy { showSpinner=true } }
            }
            .sheet(item: $helpTopic) { InspectorHelpSheet(topic: $0) }
            .task { page = model.active.isEmpty ? .library : .applied; model.rebuild(delay: false) }
            .onDisappear { model.stop() }
            .photosPicker(isPresented: $showPhotoPicker, selection: $photo, matching: mediaParameter?.id == "cleanPlate" || model.current?.choice("background",at:model.sourceTime)=="Image" ? .images : .videos)
            .onChange(of: photo) { _, item in if let item, let parameter = mediaParameter { Task { await model.importMedia(item, parameter: parameter); photo = nil } } }
            .confirmationDialog("Remove this effect?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove effect", role: .destructive) { model.remove();page = model.active.isEmpty ? .library : .applied }
            }
    }
    private var header: some View {
        HStack(spacing: 12) {
            Button("Cancel", action: cancel).frame(minWidth: 54, minHeight: 44)
            Spacer(minLength: 0)
            VStack(spacing: 2) {
                Text("Video effects").font(.headline)
                Text(model.request.scopeTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button("Apply") { model.finishPosition();model.stop(); var edit=model.state;for c in edit.clips.indices { edit.clips[c].videoEffects=edit.clips[c].videoEffects?.map(\.recordingResult) };apply(edit) }.fontWeight(.semibold).frame(minWidth: 54, minHeight: 44)
                .disabled((model.busy && model.sampleRange == nil) || model.error != nil)
                .accessibilityIdentifier("videoEffects.apply")
        }.padding(.horizontal, 12)
    }
    private var inspectedSplit: VideoEffectSettings? {
        guard page == .inspector, !model.bypass, let effect = model.current, effect.kind == .kaleidoscope,
              effect.enabled, model.active.contains(where: { $0.id == effect.id }) else { return nil }
        return effect
    }
    private var preview: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                PlayerSurface(player:model.player,inspectionZoom:inspectedSplit == nil,onPointTap:model.pickingColor == nil ? nil : { point in Task { await model.pickColor(at:point) } },identifier:"videoEffects.preview",preserveInspection:true,onPointOutside:{model.pickHint="Tap inside the picture"},onBackgroundGesture:model.backgroundPlacement == nil ? nil : {model.changeBackground($0)}).background(.black)
                if let effect = inspectedSplit {
                    KaleidoscopeGuide(pose: KaleidoscopePose(effect, at: model.sourceTime),
                                      divisions: Int(effect.number("divisions", at: model.sourceTime)),
                                      projection: { size in
                        guard model.previewCanvas.width > 0 && model.previewCanvas.height > 0 else { return nil }
                        let rect = AVMakeRect(aspectRatio: model.previewCanvas, insideRect: CGRect(origin: .zero, size: size))
                        return CGAffineTransform(a: rect.width, b: 0, c: 0, d: rect.height, tx: rect.minX, ty: rect.minY)
                    }) { pose, target in model.adjustOpticalEffect(pose.parameters(for: target)) }
                }
                if model.pickingColor != nil {
                    VStack {
                        Spacer()
                        HStack(spacing:8) {
                            VStack(alignment:.leading,spacing:2) {
                                Text(model.busy ? "Preparing…" : model.pickHint).font(.caption.weight(.semibold))
                                Text("Input to " + (model.current?.kind.descriptor.displayName ?? "effect")).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(minLength:0)
                            Button("Cancel") { model.cancelColorPick() }.frame(minWidth:54,minHeight:44).accessibilityIdentifier("videoEffects.cancelPick")
                        }.padding(.horizontal,12).background(.black.opacity(0.8),in:RoundedRectangle(cornerRadius:12)).padding(8)
                    }
                } else if model.positioningEffectID==nil { Button { model.bypass.toggle(); model.rebuild(delay: false) } label: {
                    Label(model.bypass ? "Original" : "Effects", systemImage: model.bypass ? "eye.slash" : "eye")
                        .font(.caption.weight(.semibold)).padding(.horizontal, 12).frame(minHeight: 44)
                        .background(.black.opacity(0.65), in: Capsule())
                }.padding(8).accessibilityIdentifier("videoEffects.compare") }
                if showSpinner { ProgressView().padding(12).background(.black.opacity(0.65), in: Circle()).frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
            if model.positioningEffectID != nil { backgroundPositionBar }
            playbackControls
        }
    }

    private var playbackControls: some View {
        HStack(spacing: 8) {
            Button(action: model.togglePlay) { Image(systemName: model.playing ? "pause.fill" : "play.fill").frame(width: 44, height: 44) }
                .disabled(model.busy || model.pickingColor != nil || model.positioningEffectID != nil)
                .accessibilityLabel(model.playing ? "Pause preview" : "Play preview")
            Slider(value: Binding(get: { model.position }, set: { model.seek($0) }), in: model.previewSeekRange, onEditingChanged: model.scrub)
                .accessibilityLabel("Preview position").accessibilityValue(String(format:"%.2f to %.2f; at %.2f",model.previewRange.lowerBound,model.previewRange.upperBound,model.position))
                .disabled(model.pickingColor != nil || model.positioningEffectID != nil)
            Text(editorTime(model.position-model.previewRange.lowerBound)+" / "+editorTime(model.previewRange.upperBound-model.previewRange.lowerBound)).font(.caption.monospacedDigit()).fixedSize()
        }.padding(.trailing, 12)
    }
    private var controls: some View {
        VStack(spacing: 0) {
            VideoEffectNavigationBar(page:page,count:model.active.count,prefix:"videoEffects",back:goBack,add:{model.cancelColorPick();page = .library})
                .disabled(model.positioningEffectID != nil)
            Divider()
            if model.sampleRange != nil || model.refiningPreview || model.accuratePreviewReady {
                HStack(spacing:8) {
                    if model.refiningPreview {ProgressView().controlSize(.small)}
                    let sample = model.sampleRange.map(EffectPreviewWindow.label) ?? "preview"
                    Text(model.sampleStopped ? "Preview stopped" : model.busy || model.refiningPreview ? "Preparing " + sample + (model.hasNightFix && model.nightProgress > 0 ? " · \(Int(model.nightProgress * 100))%" : "") : model.accuratePreviewReady ? sample + " ready · pause to view" : sample).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier(model.refiningPreview || model.accuratePreviewReady ? "videoEffects.refinement" : "videoEffects.sample")
                    Spacer(minLength:0)
                    if model.sampleStopped {
                        Button(action: model.resumeSample) { Text("Preview").frame(minWidth: 58, minHeight: 44) }
                            .accessibilityIdentifier("videoEffects.resumeSample")
                    } else if model.refiningPreview || model.busy {
                        Button(action: model.stopSample) { Text("Stop").frame(minWidth: 58, minHeight: 44) }
                            .accessibilityIdentifier("videoEffects.stopSample")
                    }
                }.font(.caption).padding(.horizontal, 16).frame(minHeight: 44)
            }
            if page == .applied {
                appliedEffects.padding(.horizontal,16).padding(.top,12)
            } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let error = model.error { Label(error, systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(.orange)
                        Button("Retry") { model.rebuild(delay: false) } }
                    if let error=model.refinementError {
                        Text("Preview refinement paused: "+error).font(.caption).foregroundStyle(.secondary)
                        Button("Retry preview refinement") {model.rebuild(delay:false)}
                    }
                    if model.positioningEffectID != nil { positioningCard }
                    else {switch page {
                    case .applied:appliedEffects
                    case .library:library(nil)
                    case .section(let section):library(section)
                    case .inspector:
                        if let effect=model.current {settings(effect)} else {appliedEffects}
                    }}
                }.padding(16).padding(.bottom,16)
            }.id(page == .inspector ? "inspector-"+(model.selected?.uuidString ?? "") : page.identity).accessibilityIdentifier("videoEffects.controls")
            }
        }.background(Color(white: 0.07))
    }
    private var positioningCard:some View {
        VStack(alignment:.leading,spacing:16) {
            Label("Position background",systemImage:"arrow.up.and.down.and.arrow.left.and.right").font(.headline)
            Text("Drag the picture to move the background. Pinch to change its size.")
            if let placement=model.backgroundPlacement {
                Text(String(format:"X %.2f · Y %.2f · Zoom %.2f×",placement.x,placement.y,placement.zoom)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text("Effects after \(model.current?.kind.descriptor.displayName ?? "this background") are hidden while you position.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var backgroundPositionBar:some View {
        ViewThatFits(in:.horizontal) {
            HStack(spacing:8) {backgroundPositionHint;Spacer(minLength:8);backgroundPositionButtons}
            VStack(alignment:.leading,spacing:0) {backgroundPositionHint;backgroundPositionButtons.frame(maxWidth:.infinity,alignment:.trailing)}
        }.padding(.horizontal,12).padding(.vertical,4).background(Color(white:0.08))
            .accessibilityElement(children:.contain).accessibilityIdentifier("videoEffects.positionBar")
            .accessibilityValue(String(format:"X %.3f Y %.3f Zoom %.3f",model.backgroundPlacement?.x ?? 0.5,model.backgroundPlacement?.y ?? 0.5,model.backgroundPlacement?.zoom ?? 1))
    }
    private var backgroundPositionHint:some View {
        Text(model.backgroundPlacement?.movementLocked == true ? "Pinch to make room to move" : "Drag to move · pinch to scale").font(.caption).fixedSize(horizontal:true,vertical:false)
    }
    private var backgroundPositionButtons:some View {
        HStack(spacing:8) {
            Button("Center") {model.resetBackgroundPosition()}.frame(minWidth:44,minHeight:44).accessibilityHint("Resets position and zoom").accessibilityIdentifier("videoEffects.positionReset")
            Button("Revert") {model.finishPosition(cancel:true)}.frame(minWidth:50,minHeight:44).accessibilityIdentifier("videoEffects.positionRevert")
            Button("Done") {model.finishPosition()}.buttonStyle(.borderedProminent).frame(minWidth:44,minHeight:44).accessibilityIdentifier("videoEffects.positionDone")
        }.disabled(model.busy)
    }
    private func goBack() {
        model.cancelColorPick()
        switch page {
        case .section:page = .library
        case .inspector,.library:page = .applied
        case .applied:break
        }
    }
    private func library(_ section:VideoEffectLibrarySection?)->some View {
        VideoEffectLibrary(section:section,live:false,chooseSection:{page = .section($0)},add:{kind in
            model.add(kind);page = .inspector
        })
    }
    private var appliedEffects:some View {
        VStack(alignment:.leading,spacing:12) {
            if let error=model.error {Text(error).font(.caption).foregroundStyle(.orange);Button("Retry") {model.rebuild(delay:false)}}
            if model.active.isEmpty {
                Text("No effects at the playhead.").foregroundStyle(.secondary)
                Button {page = .library} label: {Label("Add effect",systemImage:"plus").frame(minHeight:44)}
            } else {
                Text("At the playhead · tap an effect to adjust it.").font(.caption).foregroundStyle(.secondary)
                VideoEffectAppliedList(effects:model.active,prefix:"videoEffects",edit:{effect in
                    model.selected=effect.id;model.animate=false;page = .inspector
                },toggle:{effect in model.selected=effect.id;model.mutate {$0.enabled.toggle()}},remove:{effect in
                    model.selected=effect.id;model.remove();page = model.active.isEmpty ? .library : .applied
                })
            }
        }
    }
    private func settings(_ effect: VideoEffectSettings) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ViewThatFits(in:.horizontal) {
                HStack {Text(effect.kind.descriptor.displayName).font(.title3.weight(.semibold));EffectHelpButton(effect: effect.kind) { helpTopic = $0 };Spacer();effectActions(effect).fixedSize(horizontal:true,vertical:false)}
                VStack(alignment:.leading,spacing:8) {HStack {Text(effect.kind.descriptor.displayName).font(.title3.weight(.semibold));EffectHelpButton(effect: effect.kind) { helpTopic = $0 };Spacer()};effectActions(effect)}
            }
            if model.animate { Text("Animating · changes add keyframes at \(editorTime(model.position))").font(.caption).padding(10).frame(maxWidth:.infinity,alignment:.leading).background(effect.kind.librarySection.tint.opacity(0.12),in:RoundedRectangle(cornerRadius:10)) }
            if effect.kind == .nightFix { Label("Editor only",systemImage:"moon.stars").font(.caption).foregroundStyle(.secondary) }
            if effect.kind == .autoBackground {
                Text("Keeps people in focus and replaces everything behind them. With nobody in frame, the whole image becomes the background.").font(.caption).foregroundStyle(.secondary)
            }
            if effect.kind == .chromaKey {Text(ChromaScreen.explanation).font(.caption).foregroundStyle(.secondary)}
            if effect.kind == .chromaKey && effect.toggle("personHint",at:model.sourceTime) {
                Text("Person hint also removes objects outside a person’s silhouette. Turn it off to keep other subjects.").font(.caption).foregroundStyle(.secondary)
            }
            if [.chromaKey,.autoBackground].contains(effect.kind),["Image","Video"].contains(effect.choice("background",at:model.sourceTime)),case .media(let file)=effect.value("media",at:model.sourceTime),file != nil {
                Button {Task {await model.beginBackgroundPosition()}} label: {Label("Position in preview",systemImage:"arrow.up.and.down.and.arrow.left.and.right").frame(minHeight:44)}.disabled(model.busy || model.positioningEffectID != nil).accessibilityIdentifier("videoEffects.positionBackground")
                if model.positioningEffectID != nil {Text("Showing this background effect. Later effects return on Done.").font(.caption).foregroundStyle(.secondary)}
            }
            if effect.kind == .kaleidoscope {
                KaleidoscopeControls(effect: effect, reset: model.adjustOpticalEffect, control: parameterControl)
            } else if effect.kind == .rgbOffset {
                RGBOffsetPads(effect: effect, time: model.sourceTime, projection: nil, change: model.adjustOpticalEffect)
                    .disabled(model.busy || model.bypass || !effect.enabled)
                if let intensity = effect.parameters.first(where: { $0.id == "intensity" }) { parameterControl(intensity) }
            } else if effect.kind == .colorCorrection {
                if effect.motion != nil { correctionControls(effect) }
                ColorCorrectionPanel(effect:effect,time:model.sourceTime,includesBackground:model.active.contains {$0.enabled && $0.kind.descriptor.family == .key},tab:$correctionTab,advanced:$correctionAdvanced) {parameter in parameterControl(parameter)} reset:{
                    model.resetCorrection()
                }
            } else {
            ForEach(VideoEffectParameterSection.sections(for:effect,time:model.sourceTime),id:\.self) {section in
                if section == .edges {DisclosureGroup(section.title) {parameterGroup(section,effect:effect)}}
                else {
                    if section != .general {Text(section.title).font(.headline).accessibilityAddTraits(.isHeader)}
                    parameterGroup(section,effect:effect)
                }
            }
            }
            if effect.kind == .nightFix {
                if effect.nightFixMode != .fast {Text("Completed cleanup is reused when you adjust brightness, noise reduction or detail.").font(.caption).foregroundStyle(.secondary)}
                if effect.number("brightness",at:model.sourceTime)>4 || effect.number("reduction",at:model.sourceTime)>1.5 {
                    Text("Strong recovery can reveal color blotches and soften fine detail. Compare with Original before applying.").font(.caption).foregroundStyle(.orange).accessibilityIdentifier("nightFix.strongWarning")
                }
            }
            if effect.kind == .freezeFrame {
                Text("Silence during hold pauses dialogue until the video resumes. Continue plays it during the hold too, so some dialogue may repeat. Fade out lowers it through the hold.").font(.caption).foregroundStyle(.secondary)
            }
            if effect.kind == .quantization {
                if effect.toggle("lockPalette",at:model.sourceTime) {
                    Button { Task { await model.samplePalette(lockOnly:true) } } label: { Label("Re-sample this frame",systemImage:"arrow.clockwise").frame(minHeight:44) }.disabled(model.samplingPalette)
                }
                if !effect.toggle("monochrome",at:model.sourceTime) {
                    Button { Task { await model.samplePalette() } } label: { Label(model.samplingPalette ? "Sampling frame…" : "Save palette from this frame", systemImage: "eyedropper.halffull").frame(minHeight: 44) }.disabled(model.samplingPalette)
                    if let colors = effect.palette { HStack(spacing: 0) { ForEach(Array(colors.enumerated()), id: \.offset) { _, color in Color(red: color.red, green: color.green, blue: color.blue) } }.frame(height: 24).clipShape(RoundedRectangle(cornerRadius: 6)) }
                }
                if let message = model.sampleMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            if effect.kind == .dollyZoom { Text(model.hasDepth ? "Uses imported depth to separate the subject." : "Uses person separation when imported depth is unavailable.").font(.caption).foregroundStyle(.secondary) }
            if effect.kind == .widescreen { Text(model.depthNote).font(.caption).foregroundStyle(.secondary) }
            Button(role: .destructive) { confirmRemove = true } label: { Label(effect.kind == .freezeFrame ? "Remove hold" : "Remove effect", systemImage: "trash").frame(minHeight: 44) }
        }.tint(effect.kind.librarySection.tint)
    }
    private func visible(_ parameter: EffectParameter, effect: VideoEffectSettings) -> Bool {
        // Keep the depth row stable while capabilities are being checked;
        // its toggle is disabled, with an explanation, until depth is usable.
        VideoEffectParameterVisibility.visible(parameter,effect:effect,time:model.sourceTime,hasDepth:true)
    }
    private func parameterGroup(_ section:VideoEffectParameterSection,effect:VideoEffectSettings)->some View {
        VStack(alignment:.leading,spacing:18) {
            ForEach(effect.parameters.filter {visible($0,effect:effect) && VideoEffectParameterSection.section($0,effect:effect)==section}) {parameter in parameterControl(parameter)}
        }
    }
    private func correctionControls(_ effect:VideoEffectSettings) -> EffectAnimationControls {
        EffectAnimationControls(motion:effect.motion,endpoint:model.correctionEndpoint,duration:model.correctionDuration,
                                select:model.selectCorrection,remove:model.removeCorrectionAnimation,done:{model.correctionEndpoint=nil},
                                update:model.updateCorrectionTiming,showsEndpointMenu:false)
    }
    private func effectActions(_ effect:VideoEffectSettings)->some View {
        HStack(spacing:8) {
            if effect.kind == .colorCorrection {
                correctionControls(effect).endpointMenu
            } else {
                Button { model.animate.toggle() } label: {
                    Label("Animate",systemImage:model.animate ? "diamond.fill" : "diamond")
                        .font(.caption.weight(.semibold)).padding(.horizontal,12).frame(minWidth:44,minHeight:44)
                        .background(model.animate ? effect.kind.librarySection.tint.opacity(0.25) : .white.opacity(0.07),in:Capsule())
                }.accessibilityLabel("Animate").accessibilityHint("Add keyframes as you adjust controls").accessibilityValue(model.animate ? "On" : "Off")
            }
            if effect.kind != .freezeFrame {Button {model.mutate {$0.enabled.toggle()}} label: {Image(systemName:"power").foregroundStyle(effect.enabled ? .black : .secondary).frame(width:44,height:44).background(effect.enabled ? effect.kind.librarySection.tint : .white.opacity(0.07),in:Circle())}.accessibilityLabel(effect.enabled ? "Disable effect" : "Enable effect")}
        }
    }
    private func numberLabel(_ number: Double, parameter: EffectParameter) -> String {
        if model.current?.kind == .kaleidoscope && parameter.id != "divisions" {
            return KaleidoscopePose.display(parameter.id, number)
        }
        if model.current?.kind == .nightFix {
            return parameter.id == "brightness" ? String(format: "+%.1f stops", number) : "\(Int((number * 100).rounded()))%"
        }
        if parameter.id == "intensity" { return "\(Int(number * 100))%" }
        let suffix = ["range", "angle"].contains(parameter.id) ? "°" : ""
        return number.formatted(.number.precision(.fractionLength(0...2))) + suffix
    }
    private func correctionParameter(_ p:EffectParameter) -> EffectParameter {
        guard let effect = model.current, let motion = effect.motion else { return p }
        var v = p
        if let e = model.correctionEndpoint, !model.playing { v.value = .number(motion[e][p.id]) }
        else { v.value = effect.value(p.id,at:model.sourceTime) ?? p.value }
        v.keyframes = []; return v
    }
    @ViewBuilder private func parameterControl(_ parameter: EffectParameter) -> some View {
        let value = parameter.value(at: model.sourceTime)
        if model.current?.kind == .nightFix && parameter.id == "mode" {
            VStack(alignment:.leading,spacing:8) {
                Text("Mode").font(.subheadline)
                Picker("Mode",selection:Binding(get:{model.current?.nightFixMode ?? .fast},set:{model.set(parameter,.choice($0.rawValue))})) {
                    ForEach(NightFixMode.allCases,id:\.self) {Text($0.rawValue).tag($0)}
                }.pickerStyle(.segmented).accessibilityIdentifier("nightFix.mode")
                Text((model.current?.nightFixMode ?? .fast).explanation).font(.caption).foregroundStyle(.secondary)
            }
        } else if model.current?.kind == .colorCorrection {
            VStack(alignment:.leading,spacing:4) {
                ColorCorrectionSlider(parameter:correctionParameter(parameter),time:model.sourceTime,animate:model.animate,set:{model.set(parameter,$0)},keyframe:{model.keyframe(parameter)})
                if !parameter.keyframes.isEmpty {keyframeNavigation(parameter)}
            }
        } else if parameter.id=="screenColor",case .color(let color)=value {
            ChromaScreenControl(color:color,choose:{model.set(parameter,.color($0))},pick:{model.beginColorPick(parameter)})
        } else {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(parameter.title).font(.subheadline)
                Spacer()
                if case .number(let number) = value {
                    Text(numberLabel(number, parameter: parameter))
                        .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
                if case .color(let color)=value {
                    if parameter.id=="screenColor" || model.current?.kind == .colorIsolation && parameter.id=="color" {
                        Button { model.beginColorPick(parameter) } label: { Label("Pick",systemImage:"eyedropper").font(.caption.weight(.semibold)).padding(.horizontal,10).frame(minHeight:44).background(.white.opacity(0.08),in:Capsule()) }.accessibilityLabel("Pick in preview").accessibilityIdentifier("videoEffects.pickColor")
                    }
                    if model.current?.kind == .colorIsolation && parameter.id=="color" {
                        Circle().fill(Color(hue:IsolationHue.degrees(color)/360,saturation:1,brightness:1)).frame(width:24,height:24).accessibilityHidden(true)
                    } else {
                    ColorPicker(parameter.title,selection:Binding(get:{Color(red:color.red,green:color.green,blue:color.blue)},set:{color in
                        var r:CGFloat=0,g:CGFloat=0,b:CGFloat=0,a:CGFloat=0
                        if UIColor(color).getRed(&r,green:&g,blue:&b,alpha:&a) { model.set(parameter,.color(EffectRGB(r,g,b))) }
                    }),supportsOpacity:false).labelsHidden().frame(width:44,height:44)
                    }
                }
                if parameter.id != "view" && parameter.animatable && (model.animate || !parameter.keyframes.isEmpty) {
                    Button { model.keyframe(parameter) } label: {
                        Image(systemName: parameter.keyframes.contains { abs($0.time-model.sourceTime)<1.0/60 } ? "diamond.fill" : "diamond").frame(width: 44, height: 44)
                    }.accessibilityLabel("Keyframe for " + parameter.title)
                }
            }
            switch parameter.kind {
            case let .slider(minimum, maximum, _, step):
                if case .number(let number) = value {
                    Slider(value: Binding(get: { number }, set: { model.set(parameter, .number($0)) }), in: minimum...maximum, step: step)
                        .frame(minHeight: 36).accessibilityLabel(parameter.title).accessibilityIdentifier("videoEffects.slider." + parameter.id)
                        .accessibilityValue(numberLabel(number, parameter: parameter))
                }
            case .toggle:
                if case .toggle(let enabled) = value { Toggle(parameter.title, isOn: Binding(get: { enabled }, set: { model.set(parameter, .toggle($0)) })).disabled(parameter.id=="ovalBokeh" && !model.hasDepth).labelsHidden().frame(maxWidth: .infinity, alignment: .trailing) }
            case .picker:
                if case .choice(let selected) = value {
                    Menu { ForEach(model.current.map {VideoEffectParameterVisibility.choices(parameter,effect:$0)} ?? [], id: \.self) { choice in Button { model.set(parameter, .choice(choice)) } label: { if selected == choice { Label(choiceTitle(choice,parameter:parameter), systemImage: "checkmark") } else { Text(choiceTitle(choice,parameter:parameter)) } } } } label: {
                        HStack { Text(choiceTitle(selected,parameter:parameter)); Spacer(); Image(systemName: "chevron.up.chevron.down") }.frame(minHeight: 44).padding(.horizontal, 12).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            case .stepper(let values, _):
                if case .number(let number) = value {
                    VideoEffectNumberChoices(title:parameter.title,values:values,selected:number) {model.set(parameter,.number($0))}
                }
            case .color:
                if model.current?.kind == .colorIsolation,parameter.id=="color",case .color(let color)=value {
                    Slider(value:Binding(get:{IsolationHue.degrees(color)},set:{model.set(parameter,.color(IsolationHue.color($0)))}),in:0...359,step:1).accessibilityLabel("Hue")
                    if !IsolationHue.accepts(color) {Text(IsolationHue.invalidSample).font(.caption).foregroundStyle(.orange)}
                }
            case .media:
                Button { mediaParameter = parameter; showPhotoPicker = true } label: {
                    Label({ if case .media(let file) = value, file != nil { return "Replace media" }; return "Choose from Photos" }(), systemImage: "photo.on.rectangle").frame(minHeight: 44)
                }
                if case .media(let file)=value,file != nil {
                    Button("Remove media",role:.destructive) {model.set(parameter,.media(nil))}.frame(minHeight:44)
                }
            }
            if !parameter.keyframes.isEmpty {
                keyframeNavigation(parameter)
            }
        }
        }
    }
    private func seekKeyframe(_ key:EffectKeyframe) {
        if let placement=model.placement {model.seek(placement.start+placement.clip.timelineTime(forSource:key.time))}
    }
    private func keyframeNavigation(_ parameter:EffectParameter)->some View {
        let previous=parameter.keyframes.last {$0.time<model.sourceTime-1.0/60000}
        let next=parameter.keyframes.first {$0.time>model.sourceTime+1.0/60000}
        return HStack(spacing:8) {
            Button {if let previous {seekKeyframe(previous)}} label: {Image(systemName:"backward.end.fill").frame(width:44,height:44)}
                .disabled(previous==nil).accessibilityLabel("Previous keyframe for "+parameter.title)
            Menu {
                ForEach(parameter.keyframes) {key in Button(editorTime(key.time)) {seekKeyframe(key)}}
            } label: {
                Label("\(parameter.keyframes.count) " + (parameter.keyframes.count == 1 ? "keyframe" : "keyframes"),systemImage:"diamond.fill").font(.caption).frame(maxWidth:.infinity,minHeight:44)
            }.accessibilityLabel("Keyframes for "+parameter.title)
            Button {if let next {seekKeyframe(next)}} label: {Image(systemName:"forward.end.fill").frame(width:44,height:44)}
                .disabled(next==nil).accessibilityLabel("Next keyframe for "+parameter.title)
        }
    }
    private func choiceTitle(_ value:String,parameter:EffectParameter)->String {
        model.current?.kind == .freezeFrame && parameter.id=="audio" && value=="Cut" ? "Silence during hold" : value
    }
}

// One compact inspector shared by recording and timeline editing. Two fixed
// tabs avoid a second horizontal scroll axis beside the live picture.
struct ColorCorrectionPanel<Control:View>:View {
    let effect:VideoEffectSettings
    var time=0.0
    var includesBackground=false
    @Binding var tab:Int
    @Binding var advanced:Bool
    @ViewBuilder let control:(EffectParameter)->Control
    let reset:()->Void
    @State private var confirmReset=false
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Picker("Correction controls",selection:$tab) {
                Text("Light").tag(0);Text("Color").tag(1)
            }.pickerStyle(.segmented).accessibilityIdentifier("colorCorrection.tabs")
            Text("Before color looks · tap a value to reset").font(.caption).foregroundStyle(.secondary)
            if includesBackground {Text("Also grades the replacement background.").font(.caption).foregroundStyle(.secondary)}
            group(tab==0 ? ColorCorrectionControls.light : ColorCorrectionControls.color)
            if tab==0 {
                DisclosureGroup("Advanced light",isExpanded:$advanced) {
                    group(ColorCorrectionControls.advanced)
                    if effect.number("contrast",at:time)==1 {Text("Adjust contrast to use the pivot.").font(.caption).foregroundStyle(.secondary)}
                }
                    .accessibilityIdentifier("colorCorrection.advanced")
            }
            Divider()
            if let intensity=effect.parameters.first(where:{$0.id=="intensity"}) {control(intensity)}
            HStack {
                Text("Hold a label for help").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength:8)
                Button("Reset correction") {confirmReset=true}.frame(minHeight:44).accessibilityIdentifier("colorCorrection.resetAll")
            }
        }.confirmationDialog("Reset this correction?",isPresented:$confirmReset,titleVisibility:.visible) {
            Button("Reset all adjustments",role:.destructive,action:reset)
        } message: {Text("Returns all controls to neutral and removes their keyframes. Other effects are kept.")}
    }
    private func group(_ ids:[String])->some View {
        VStack(spacing:8) {ForEach(ids,id:\.self) {id in if let parameter=effect.parameters.first(where:{$0.id==id}) {control(parameter).disabled(id=="pivot" && effect.number("contrast",at:time)==1)}}}
    }
}
struct ColorCorrectionSlider:View {
    let parameter:EffectParameter
    var time=0.0
    var animate=false
    let set:(EffectValue)->Void
    var keyframe:(()->Void)?=nil
    @State private var help=false
    var body:some View {
        if case let .slider(low,high,neutral,step)=parameter.kind,case .number(let value)=parameter.value(at:time) {
            VStack(spacing:0) {
                HStack {
                    Text(parameter.title).font(.subheadline).frame(minHeight:40)
                        .contentShape(Rectangle()).onLongPressGesture {help=true}
                        .accessibilityAction(named:"Explain setting") {help=true}
                    Spacer(minLength:4)
                    Button {set(.number(neutral))} label: {
                        Text(ColorCorrectionControls.display(parameter.id,value)).font(.subheadline.monospacedDigit()).frame(minWidth:68,minHeight:44)
                    }.accessibilityLabel("Reset " + parameter.title).accessibilityValue(ColorCorrectionControls.display(parameter.id,value))
                        .accessibilityHint(parameter.keyframes.isEmpty ? "Resets this adjustment to neutral" : "Sets neutral at the playhead; other keyframes are kept")
                        .accessibilityIdentifier("colorCorrection.value."+parameter.id)
                    if let keyframe,animate || !parameter.keyframes.isEmpty {
                        Button(action:keyframe) {Image(systemName:parameter.keyframes.contains {abs($0.time-time)<1.0/60} ? "diamond.fill" : "diamond").frame(width:44,height:44)}.accessibilityLabel("Keyframe for " + parameter.title)
                    }
                }
                Slider(value:Binding(get:{value},set:{set(.number($0))}),in:low...high,step:step)
                    .frame(minHeight:32).accessibilityLabel(parameter.title)
                    .accessibilityValue(ColorCorrectionControls.display(parameter.id,value))
                    .accessibilityIdentifier("colorCorrection.slider."+parameter.id)
                    .overlay(alignment:.bottom) {
                        GeometryReader {g in
                            Rectangle().fill(.secondary).frame(width:1,height:4).position(x:14+max(0,g.size.width-28)*(neutral-low)/(high-low),y:g.size.height-1)
                        }.allowsHitTesting(false).accessibilityHidden(true)
                    }
            }.alert(parameter.title,isPresented:$help) {Button("Got it",role:.cancel) {}} message: {Text(ColorCorrectionControls.help(parameter.id))}
        }
    }
}
