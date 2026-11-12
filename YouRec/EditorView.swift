import SwiftUI
import AVKit
import PhotosUI
import UniformTypeIdentifiers

private let editorAccent = Color(red: 1, green: 0.25, blue: 0.29)
private let editorSurface = Color(white: 0.08)

private struct EditorLoadRevision: Equatable { let edit: Date; let application: Int; let inspecting: Bool }

private struct SnapMagnet: View {
    let enabled: Bool
    var body: some View {
        ZStack {
            Path { p in
                p.move(to: CGPoint(x: 5, y: 8)); p.addLine(to: CGPoint(x: 5, y: 14))
                p.addCurve(to: CGPoint(x: 19, y: 14), control1: CGPoint(x: 5, y: 24), control2: CGPoint(x: 19, y: 24))
                p.addLine(to: CGPoint(x: 19, y: 8))
            }.stroke(style: StrokeStyle(lineWidth: 4, lineCap: .butt))
            Path { p in
                p.addRect(CGRect(x: 3, y: 3, width: 4, height: 3))
                p.addRect(CGRect(x: 17, y: 3, width: 4, height: 3))
            }.fill(.white.opacity(enabled ? 0.95 : 0.5))
            if !enabled {
                Path { p in p.move(to: CGPoint(x: 1, y: 23)); p.addLine(to: CGPoint(x: 23, y: 1)) }
                    .stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
        }.frame(width: 24, height: 24).rotationEffect(.degrees(-25)).accessibilityHidden(true)
    }
}

private struct MoveScopeButton: View {
    let scope: TimelineMoveScope
    let chosen: Bool
    let compact: Bool
    let action: () -> Void
    private var title: String {
        switch scope {
        case .selected: return "Selected only"
        case .left: return "With left"
        case .right: return "With right"
        case .both: return "Both sides"
        }
    }
    private var hint: String {
        switch scope {
        case .selected: return "Move the selected parts and anything linked to them."
        case .left: return "Include adjoining clips to the left, up to the first gap."
        case .right: return "Include adjoining clips to the right, up to the first gap."
        case .both: return "Include adjoining clips in both directions, up to the first gap on each side."
        }
    }
    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Canvas { context, _ in
                    for index in 0...2 {
                        let center = index == 1
                        let tile = CGRect(x: CGFloat(index * 13) + 1, y: center ? 1 : 3,
                                          width: 10, height: center ? 14 : 10)
                        let path = Path(roundedRect: tile, cornerRadius: 2)
                        if center || (index == 0 ? scope.includesLeft : scope.includesRight) {
                            context.fill(path, with: .color(center ? .yellow : .white))
                        } else {
                            context.stroke(path, with: .color(.white.opacity(0.55)), lineWidth: 1)
                        }
                        if center {
                            let grip = CGRect(x: tile.midX - 1, y: 5, width: 2, height: 6)
                            context.fill(Path(roundedRect: grip, cornerRadius: 1), with: .color(.black.opacity(0.75)))
                        }
                    }
                    let firstX = scope.includesLeft ? 1 : 14, lastX = scope.includesRight ? 37 : 24
                    let rail = CGRect(x: firstX, y: 17, width: lastX - firstX, height: 2)
                    context.fill(Path(roundedRect: rail, cornerRadius: 1), with: .color(.white))
                }.frame(width: 38, height: 19).accessibilityHidden(true)
                Text(title).font(.caption.weight(.semibold)).multilineTextAlignment(.center)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: compact ? 44 : 48).padding(.vertical, compact ? 0 : 4)
            .foregroundStyle(chosen ? Color.yellow : .white)
            .background(chosen ? Color.yellow.opacity(0.13) : .white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
            .overlay { if chosen { RoundedRectangle(cornerRadius: 12).strokeBorder(.yellow, lineWidth: 1.5) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(EditorActionStyle())
        .accessibilityLabel(title)
        .accessibilityHint(hint)
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityIdentifier("editor.moveScope." + scope.rawValue)
    }
}

private struct MoveOrigin {
    let revision: Date
    let playhead: Double
    let scale: Double
}

struct EditorView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @ScaledMetric(relativeTo: .title3) private var clipboardIconHeight: CGFloat = 24
    @ObservedObject var store: ProjectStore
    let projectID: UUID
    let back: () -> Void
    var recordHere: (Double, VideoInsertionSite?) -> Void = { _, _ in }
    @StateObject private var editor = EditorController()
    @AppStorage("snapToCuts") private var snapToCuts = true
    private var clipboard: TimelineClipboard? {
        get { store.trackClipboards[projectID] }
        nonmutating set { store.trackClipboards[projectID] = newValue }
    }
    @State private var rangeTargets: TimelineSelection?
    @State private var movePreviewTask: Task<Void, Never>?
    @State private var moveBase: EditState?
    @State private var cutLayout = TimelineLayout(clips: [])
    @State private var pasteTargets: [TimelinePasteTarget] = []
    @State private var moveDraft: EditState?
    @State private var moveChoices = TimelineMoveChoices()
    @State private var moveScope = TimelineMoveScope.selected
    @State private var moveOrigin: MoveOrigin?
    @State private var moveBoundaries = TimelineMoveBoundaries()
    @State private var moveViewportEnd: EditTime?
    @State private var pickingMoveBoundary = false
    // A target in the original edit may now be beyond the shortened draft.
    @State private var moveBrowseTime: Double?
    @State private var nearbyMoveBoundaries: [EditTime] = []
    private var moveTargets: TimelineSelection { moveChoices[moveScope] }
    @State private var moveOffset = 0.0
    @State private var requestedMoveOffset = 0.0
    @State private var moveSnap: TimelineMoveSnap?
    @State private var moveDragOrigin = 0.0
    @State private var fullPreview = false
    @State private var bookmarksSheet = false
    @State private var bookmarkHelp = false
    @State private var renamingBookmark: UUID?
    @State private var bookmarkName = ""
    @State private var playTapTime: Date?
    @State private var playTapAnchor = 0.0
    @State private var pendingPlay: Task<Void, Never>?
    @State private var addAudioSheet = false
    @State private var pendingAddAudio = false
    @State private var showingAddVideo = false
    @State private var timelineAddSite: VideoInsertionSite?
    @State private var pendingRecord = false
    @State private var insertionTime = 0.0
    @State private var selectedItems = Set<UUID>()
    @State private var pendingLink: TimelineLinkPlan?
    @State private var pendingLinkBase: EditState?
    private var selectedClip: UUID? { selectedItems.count == 1 ? selectedItems.first : nil }
    @State private var markStart: Double?
    @State private var selection: ClosedRange<Double>?
    @State private var pointsPerSecond = 60.0
    @State private var playbackSpeedsOpen = false
    @State private var audioSheet = false
    @State private var audioDetent: PresentationDetent = .fraction(0.85)
    @State private var exportSheet = false
    @State private var dismissedExportAudioWarning: UUID?
    @State private var toolsSheet = false
    @State private var coverPicker: CoverPickerSource?
    @State private var toolRequest: ToolRequest?
    @State private var pendingTool: ToolRequest?
    @State private var effectChoices: [ToolRegion] = []
    @State private var timelineRegions: [ToolRegion] = []
    @State private var effectsSheet = false
    @State private var removalRegionID:String?
    @State private var confirmLeave = false
    @State private var feedback: String?
    @State private var resumeGainAtRevision: Int?
    @State private var requestedLoad: EditorLoadRevision?
    @State private var editorLoadTask: Task<Void, Never>?
    @State private var viewPositions: [Int: Double] = [:]
    private var project: Project? { store.projects.first { $0.id == projectID } }

    var body: some View {
        if let project {
            editorSheets(project)
            .fullScreenCover(item: $toolRequest) { request in toolEditor(request, project: project) }
            .alert("Editor", isPresented: Binding(get: { editor.error != nil }, set: { if !$0 { editor.error = nil } })) {
                Button("OK") { editor.error = nil }
            } message: { Text(editor.error ?? "") }
        }
    }
    private var inspectingSlowTool: Bool {
        guard let tool = toolRequest?.tool else { return false }
        return [.videoEffects, .enhanceAudio].contains(tool)
    }
    private func undoApplicationButton(_ project: Project) -> some View {
        Button { history(project, redo: false) } label: { Text("Undo application").frame(minHeight: 44) }
            .font(.caption.weight(.semibold)).accessibilityIdentifier("editor.undoApplication")
    }
    private func observedEditor(_ project: Project) -> some View {
            editorLayout(project)
            .accessibilityHidden(fullPreview)
            .background(Color.black)
            .onChange(of: EditorLoadRevision(edit: project.updatedAt, application: editor.applicationPass, inspecting: inspectingSlowTool), initial: true) { _, revision in
                // A full-screen inspector can hide this view. Only a new
                // revision or leaving the editor owns cancellation of its load.
                guard revision != requestedLoad else { return }
                requestedLoad = revision
                editorLoadTask?.cancel()
                if revision.inspecting { editor.cancelObsoleteEffectWork(); return }
                guard !editor.applicationPaused else { return }
                timelineRegions = project.edit.toolRegions
                editorLoadTask = Task { @MainActor in
                    guard !Task.isCancelled else { return }
                    await editor.load(project, folder: store.folder(project))
                    guard !Task.isCancelled, let gainRevision = resumeGainAtRevision else { return }
                    resumeGainAtRevision = nil
                    if gainRevision == project.historyCursor && !editor.loading && editor.error == nil { editor.togglePlay() }
                }
            }
            .onAppear {
                editor.restorePausedExport(project, folder: store.folder(project))
                if editor.exportPaused { exportSheet = true }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in editor.pauseExport() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in editor.pauseExport(); editor.applicationDidEnterBackground() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in editor.resumeApplication() }
            .onDisappear {
                pendingPlay?.cancel(); movePreviewTask?.cancel()
                if toolRequest == nil && !fullPreview {
                    editorLoadTask?.cancel(); editorLoadTask = nil; requestedLoad = nil
                    editor.stop()
                }
            }
            .onChange(of: audioSheet) { _, shown in
                if shown {
                    feedback = nil
                    audioDetent = dynamicTypeSize.isAccessibilitySize || verticalSizeClass == .compact ? .large : .fraction(0.85)
                }
            }
            .onChange(of: editor.playhead) { _, time in
                if editor.scrubbing { playbackSpeedsOpen = false; removalRegionID = nil }
                if pickingMoveBoundary, let draft = moveDraft, time < draft.duration { moveBrowseTime = nil }
            }
            .onChange(of: project.updatedAt, initial: true) { previous, date in
                let layout = project.edit.layout
                cutLayout = layout
                pasteTargets = project.edit.timeline.pasteTargets(layout: layout)
                guard previous != date else { return }
                if let origin = moveOrigin, origin.revision != date {
                    finishMove(project, apply: false)
                }
                removalRegionID = nil
                if editor.exportPaused { editor.restorePausedExport(project, folder: store.folder(project)) }
            }
            .onChange(of: selectedItems) {_,_ in removalRegionID=nil}
            .onChange(of: toolsSheet) {_,_ in removalRegionID=nil; cancelPendingPlay()}
            .onChange(of: toolRequest?.id) {_,_ in cancelPendingPlay()}
            .onChange(of: fullPreview) {_,_ in cancelPendingPlay()}
            .onChange(of: verticalSizeClass) { _, value in if audioSheet && value == .compact { audioDetent = .large } }
            .onChange(of: exportSheet) { _, shown in
                if shown { feedback = nil }
            }
            .task(id: feedback) {
                guard feedback != nil else { return }
                do { try await Task.sleep(for: .seconds(3)); feedback = nil } catch {}
            }
            .confirmationDialog("Leave and cancel the current processing job? Completed source processing will be kept.", isPresented: $confirmLeave, titleVisibility: .visible) {
                Button("Leave and cancel", role: .destructive) { back() }
            }
            .onChange(of: project.edit.timeline.allIDs) { _, ids in
                selectedItems.formIntersection(ids)
            }
    }
    private func linkConfirmation(_ project: Project) -> some View {
        observedEditor(project)
            .alert("Link shared time only?", isPresented: Binding(get: { pendingLink != nil }, set: { if !$0 { pendingLink = nil; pendingLinkBase = nil } })) {
                Button("Cancel", role: .cancel) { pendingLink = nil; pendingLinkBase = nil }
                Button("Link intersection") {
                    if let plan = pendingLink, pendingLinkBase == self.project?.edit {
                        applyLink(plan.selection, project: project, intersectionOnly: true)
                    } else {
                        editor.error = "The timeline changed. Tap Link again to review the current selection."
                    }
                    pendingLink = nil; pendingLinkBase = nil
                }
            } message: {
                if let interval = pendingLink?.intersection {
                    Text("Video and audio cover different times. Split at \(editorTime(interval.start.seconds)) and \(editorTime(interval.end.seconds)), then link the shared interval? The outside parts stay separate. Nothing is deleted or moved.")
                }
            }
    }
    private func editorSheets(_ project: Project) -> some View {
        linkConfirmation(project)
            .sheet(isPresented: $bookmarksSheet) { bookmarkPanel(project) }
            .sheet(isPresented: Binding(get: { !nearbyMoveBoundaries.isEmpty }, set: { if !$0 { nearbyMoveBoundaries = [] } })) {
                NavigationStack {
                    List(nearbyMoveBoundaries, id: \.self) { time in
                        Button {
                            nearbyMoveBoundaries = []
                            placeMove(at: time, project: project)
                        } label: {
                            Text(moveBoundaryLabel(time, among: nearbyMoveBoundaries)).monospacedDigit()
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                        }.accessibilityIdentifier("move.choice.\(time.ticks)")
                    }.navigationTitle("Choose a start time").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Back") { nearbyMoveBoundaries = [] } } }
                }.presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $bookmarkHelp) { BookmarkHelpView() }
            .fullScreenCover(isPresented: $fullPreview) {
                FullEditorPreview(editor: editor, duration: project.edit.duration, bookmarks: project.edit.timeline.resolvedBookmarks,
                                  close: { fullPreview = false }, addBookmark: { addBookmark(project) })
            }
            .sheet(isPresented: $exportSheet) {
                MovieExportPanel(store: store, editor: editor, project: project, dismissedExportAudioWarning: $dismissedExportAudioWarning)
            }
            .sheet(isPresented: $toolsSheet, onDismiss: {
                coverPicker = nil
                if let pendingTool { toolRequest = pendingTool; self.pendingTool = nil }
                showingAddVideo = false
                if pendingRecord { pendingRecord = false; recordHere(insertionTime, timelineAddSite) }
                timelineAddSite = nil
                if pendingAddAudio { pendingAddAudio = false; addAudioSheet = true }
            }) {
                NavigationStack {
                    if timelineAddSite != nil {
                        addVideoPanel(project)
                    } else {
                        ToolsPanel(snapToCuts: $snapToCuts, matchListeningLevels: $editor.matchListeningLevels,
                                   scope: toolScopeTitle(project), overlayScope: selection == nil ? "At \(editorTime(editor.playhead)) · 3 s long" : toolScopeTitle(project), choose: { kind in
                            if kind == .addVideo { insertionTime = editor.playhead; showingAddVideo = true; return }
                            else if kind == .addAudio { insertionTime = editor.playhead; pendingAddAudio = true }
                            else { pendingTool = makeToolRequest(kind, project: project) }
                            toolsSheet = false
                        }, regions: uniqueEffects(project), insertionPosition: editor.playhead, canAdjust: project.edit.duration > 0, hasVideo: !targets(project).video.isEmpty, hasAudio: !targets(project).audio.isEmpty, canCensor: selection != nil, canTranscribe: !project.edit.timeline.audio.isEmpty || project.edit.timeline.subtitles != nil,
                                   selectCover: coverAction(project),
                                   edit: { region in
                            pendingTool = request(for: region, project: project); toolsSheet = false
                        }, close: { toolsSheet = false })
                        .navigationDestination(isPresented: $showingAddVideo) { addVideoPanel(project) }
                        .navigationDestination(item: $coverPicker) { CoverPicker(source: $0) }
                    }
                }.presentationDetents([.large]).presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $addAudioSheet) { AudioImportEditor(store: store, projectID: project.id, position: insertionTime, close: { addAudioSheet = false }, inserted: { addAudioSheet = false; editor.seek(insertionTime); feedback = "Audio added · Undo available" }) }
            .sheet(isPresented: $effectsSheet, onDismiss: {
                if let pendingTool { toolRequest = pendingTool; self.pendingTool = nil }
            }) {
                NavigationStack {
                    List(effectChoices) { region in
                        Button { pendingTool = request(for: region, project: project); effectsSheet = false } label: {
                            Label(region.tool == .text ? "Text · " + region.label : region.tool.title + " · " + region.label, systemImage: region.tool.symbol)
                                .foregroundStyle(region.tool.tint).frame(minHeight: 44)
                        }
                    }.navigationTitle("Edit effect").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { effectsSheet = false } } }
                }.presentationDetents([.medium, .large])
            }
    }
    private func editorLayout(_ project: Project) -> some View {
        GeometryReader { geometry in
                let horizontal = geometry.size.width > geometry.size.height
                VStack(spacing: 0) {
                    if !horizontal { header(project).background(Color.black).zIndex(2) }
                    let layout = horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
                    layout {
                        preview(project, horizontal: horizontal).frame(maxWidth: .infinity, maxHeight: .infinity)
                            .overlay(alignment: .top) { if horizontal { header(project, compact: true) } }
                            .overlay(alignment: .bottom) {
                                if horizontal && !dynamicTypeSize.isAccessibilitySize { processingStatus().background(.ultraThinMaterial) }
                            }
                        if horizontal && dynamicTypeSize.isAccessibilitySize {
                            ScrollView { controls(project) }.accessibilityIdentifier("editor.controlsScroll")
                                .frame(width: geometry.size.width * 0.56)
                        } else if horizontal {
                            controls(project, compact: true)
                                .frame(width: geometry.size.width * 0.52)
                        } else if dynamicTypeSize.isAccessibilitySize {
                            ScrollView { controls(project) }.accessibilityIdentifier("editor.controlsScroll")
                                .frame(maxHeight: geometry.size.height * 0.58)
                        } else { controls(project) }
                    }
                    if horizontal && !dynamicTypeSize.isAccessibilitySize {
                        timeline(project, height: 164)
                        selectionStatus(project)
                    }
                }.allowsHitTesting(!audioSheet)
            }
    }
    @ViewBuilder private func toolEditor(_ request: ToolRequest, project: Project) -> some View {
                if request.tool == .subtitles {
                    SubtitleEditor(project: project, folder: store.folder(project), request: request, position: editor.playhead,
                                   cancel: { toolRequest = nil }, apply: { applyTool($0, request: request) })
                } else if request.tool == .censorAudio {
                    CensorAudioEditor(project: project, folder: store.folder(project), request: request, initialPlayer: editor.player, cancel: { toolRequest = nil }, apply: { applyTool($0, request: request) })
                } else if request.tool == .enhanceAudio || request.tool == .volume {
                    AudioToolEditor(project: project, folder: store.folder(project), request: request, position: editor.playhead, initialPlayer: editor.player,
                                    cancel: { toolRequest = nil }, apply: { applyTool($0, request: request) })
                } else if request.tool == .placement {
                    PlacementEditor(project: project, folder: store.folder(project), request: request, position: editor.playhead,
                                    cancel: { toolRequest = nil }, apply: { applyTool($0, request: request) })
                } else if request.tool == .transition {
                    TransitionEditor(project: project, folder: store.folder(project), request: request,
                                     cancel: { toolRequest = nil }, apply: { applyTool($0, request: request) })
                } else if request.tool == .videoEffects {
                    VideoEffectsEditor(project: project, folder: store.folder(project), request: request, position: editor.playhead,
                                       cancel: { toolRequest = nil }, apply: { applyTool($0, request: request) })
                } else if request.tool == .crop {
                    CropEditor(project: project, folder: store.folder(project), request: request, position: editor.playhead,
                               cancel: { toolRequest = nil }, apply: { applyTool($0, request: request) })
                } else {
                    ToolEditor(project: project, folder: store.folder(project), request: request, editor: editor,
                               cancel: { toolRequest = nil }, apply: { applyTool($0, request: request) })
                }
    }
    private func applyTool(_ state: EditState, request: ToolRequest) {
        guard let current = self.project else { toolRequest = nil; return }
        guard state != current.edit else { toolRequest = nil; return }
        let transitionPosition: Double? = request.tool == .transition ? request.boundaryIndex.flatMap { index -> Double? in
            guard let original = current.edit.layout.joins.first(where: { $0.index == index }) else { return nil }
            return state.layout.joins.first { $0.outgoingID == original.outgoingID && $0.incomingID == original.incomingID }?.time
        } : nil
        guard commit(state, project: current, position: transitionPosition) else { return }
        if let saved = self.project, let receipt = EffectApplicationReceipt(project: saved, tool: request.tool) {
            do { try receipt.save(in: store.folder(saved)) }
            catch { editor.notice = "Edit saved. Reopen this project to continue applying the effect." }
        }
        if request.tool == .volume, request.targets?.range != nil { clearSelection() }
        toolRequest = nil; feedback = "\(request.tool.title) updated · Undo available"
    }
    private func header(_ project: Project, compact: Bool = false) -> some View {
        HStack(spacing: 8) {
            Button { if editor.rendering { confirmLeave = true } else { back() } } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }.accessibilityLabel("Back to projects")
            if !compact { Text(project.title).font(.subheadline.weight(.semibold)).lineLimit(1) }
            Spacer(minLength: 4)
            if compact { fullPreviewButton(project).padding(.trailing,8) }
        }.foregroundStyle(.white).disabled(moveDraft != nil)
    }
    private func fullPreviewButton(_ project: Project) -> some View {
        Button { cancelPendingPlay(); editor.restoreAudition(); fullPreview = true } label: {
            ZStack {
                // A crisp black outline around the white glyph, without a button plate.
                ForEach(0..<8) { index in
                    Image(systemName:"arrow.up.left.and.arrow.down.right").foregroundStyle(.black)
                        .offset(x:cos(Double(index) * .pi / 4) * 1.25,y:sin(Double(index) * .pi / 4) * 1.25)
                }
                Image(systemName:"arrow.up.left.and.arrow.down.right").foregroundStyle(.white)
            }.font(.system(size:21,weight:.semibold)).frame(width:44,height:44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("Full").accessibilityHint("Open full-screen preview")
            .accessibilityIdentifier("editor.fullPreview")
            .disabled(project.edit.duration <= 0 || editor.loading || editor.rendering || moveDraft != nil)
    }
    private func preview(_ project: Project, horizontal: Bool) -> some View {
        ZStack {
            PlayerSurface(player: editor.player, inspectionZoom: true, onPlaybackTap: { guard !editor.loading, project.edit.duration > 0 else { return }; cancelPendingPlay(); editor.togglePlay() }, hideFromAccessibility: fullPreview)
            if project.edit.duration <= 0 {
                ContentUnavailableView("Your timeline is empty", systemImage: "film", description: Text(project.canUndo ? "Undo to bring your clips back." : "Record or import a video to get started."))
            }
            if !editor.rendering { VStack { Spacer(); HStack(spacing: 0) {
                Button { withAnimation(.easeOut(duration: 0.16)) { playbackSpeedsOpen.toggle() } } label: {
                    Text("\(editor.playbackSpeed.formatted())×").font(.subheadline.monospacedDigit().weight(.semibold)).frame(minWidth: 48, minHeight: 44)
                }.foregroundStyle(.white).accessibilityLabel("Review speed").accessibilityValue("\(editor.playbackSpeed.formatted())×")
                    .accessibilityIdentifier("editor.reviewSpeed")
                if playbackSpeedsOpen {
                    ForEach([1.0, 1.5, 2, 2.5, 3], id: \.self) { speed in
                        Button { editor.setPlaybackSpeed(speed); playbackSpeedsOpen = false } label: {
                            Text("\(speed.formatted())×").font(.caption.monospacedDigit().weight(.semibold)).frame(minWidth: 44, minHeight: 44)
                                .foregroundStyle(editor.playbackSpeed == speed ? .yellow : .white)
                        }.accessibilityLabel("Review at \(speed.formatted()) times speed").accessibilityIdentifier("editor.reviewSpeed.\(speed)")
                    }
                }
            }.background(.black.opacity(0.65), in: Capsule()).overlay { Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 0.5).allowsHitTesting(false) }.frame(maxWidth: .infinity, alignment: .leading).padding(8) }
                .disabled(project.edit.duration <= 0 || editor.loading) }
            if editor.loading {
                VStack(spacing: 8) {
                    if let progress = editor.videoProgress {
                        ProgressView(value: progress).frame(width: 160)
                        Text("\(editor.loadingLabel) · \(Int(progress * 100))%").font(.caption)
                            .accessibilityIdentifier("editor.applicationProgress")
                    }
                    else { ProgressView(editor.loadingLabel) }
                    if editor.canUndoApplication { undoApplicationButton(project) }
                }.padding(16).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }.overlay(alignment:.topTrailing) {
            if !horizontal { fullPreviewButton(project).padding(8) }
        }.frame(minHeight: 120).clipped()
    }
    private func controls(_ project: Project, compact: Bool = false) -> some View {
        VStack(spacing: 0) {
            transport(project)
            if editor.applicationPaused {
                Text("Effect application paused · resumes when YouRec is active").font(.caption)
            } else if editor.refiningEffects || editor.accurateEffectsReady {
                HStack(spacing:8) {
                    if editor.refiningEffects {ProgressView().controlSize(.small)}
                    Text(editor.accurateEffectsReady ? "Effects applied · pause playback to see the result" : editor.applyingEffectsLabel).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("editor.effectRefinement")
                    Spacer(minLength:0)
                    if editor.canUndoApplication { undoApplicationButton(project) }
                }.padding(.horizontal,16).padding(.bottom,6)
            } else if editor.effectRefinementError != nil {
                HStack {
                    Text(editor.effectRefinementError ?? "").lineLimit(2)
                    Button("Retry applying effects") { editor.retryEffects(project, folder: store.folder(project)) }
                }.font(.caption).padding(.horizontal).padding(.bottom, 6)
            }
            if !compact {
                timeline(project, height: portraitTimelineHeight(project))
                selectionStatus(project)
            }
            editTools(project, compact: compact)
            comparison(project)
            if !compact { processingStatus() }
        }.background(editorSurface)
    }
    private func portraitTimelineHeight(_ project: Project) -> Double {
        let lanes = timelineLanes((moveDraft ?? project.edit).timeline, moving: moveDraft == nil ? nil : moveTargets)
        let rows = (lanes.map(\.row).max() ?? 1) + 1
        // Keep six full-size usable lanes visible on the taller portrait canvas.
        // Landscape retains its 164-point area and explicit vertical scrolling.
        return max(164, 20 + Double(min(6, rows)) * 36)
    }
    private func targets(_ project: Project) -> TimelineSelection {
        var value = rangeTargets ?? (selectedItems.isEmpty ? project.edit.timeline.entireSelection() : project.edit.timeline.selection(ids: selectedItems))
        value.range = selection.map(EditInterval.init)
        return value
    }
    private func selectedTargets(_ project: Project) -> TimelineSelection {
        selection != nil || markStart != nil || !selectedItems.isEmpty ? targets(project) : TimelineSelection()
    }
    private func quickReview(_ project: Project) {
        if let moveDraft {
            var candidate = project; candidate.history = [moveDraft]; candidate.historyCursor = 0
            editor.audition(at: editor.playhead); return
        }
        if let selection { editor.auditionRemoval(selection, project: project, folder: store.folder(project), selection: targets(project)) }
        else { editor.audition(at: editor.playhead) }
    }
    private func playTapped(_ project: Project) {
        if UIAccessibility.isVoiceOverRunning { editor.togglePlay(); return }
        let now = Date()
        if let last = playTapTime, now.timeIntervalSince(last) < 0.27 {
            pendingPlay?.cancel(); pendingPlay = nil; playTapTime = nil
            editor.seek(playTapAnchor); quickReview(project); return
        }
        playTapTime = now; playTapAnchor = editor.playhead
        if editor.playing { editor.pause(); return }
        pendingPlay?.cancel()
        pendingPlay = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(270)); editor.togglePlay(); pendingPlay = nil; playTapTime = nil } catch {}
        }
    }
    private func transport(_ project: Project) -> some View {
        let duration = moveDraft?.duration ?? project.edit.duration
        let position = pickingMoveBoundary ? moveBrowseTime ?? editor.playhead : editor.playhead
        let accessible = dynamicTypeSize.isAccessibilitySize
        return VStack(spacing: 0) {
            if accessible {
                ViewThatFits(in: .horizontal) {
                    HStack { timecode(position); Spacer(); timecode(duration, total: true) }
                    VStack(alignment: .leading) { timecode(position); timecode(duration, total: true) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 0) {
                if !accessible { timecode(position).frame(maxWidth: .infinity, alignment: .leading) }
                Button { jumpBookmark(project, forward: false) } label: { Image(systemName: "bookmark").overlay(alignment: .leading) { Image(systemName: "chevron.left").font(.system(size: 7)).offset(x: -6) }.frame(width: 44, height: 48) }.accessibilityLabel("Previous bookmark")
                ChangeNavigationButton(forward: false, enabled: project.edit.duration > 0 && editor.navigation.destination(from: editor.stationaryPlayhead, forward: false) != nil, hideFromAccessibility: fullPreview) { effectsOnly in
                    cancelPendingPlay(); editor.jumpChange(forward: false, effectsOnly: effectsOnly)
                }.frame(width: 44, height: 48)
                Button { playTapped(project) } label: { Image(systemName: editor.playing || pendingPlay != nil ? "pause.fill" : "play.fill").font(.title3).frame(width: 48, height: 48) }
                    .accessibilityLabel(editor.playing ? "Pause playback" : "Play").accessibilityAction(named: "Quick review") { quickReview(project) }
                    .disabled(project.edit.duration <= 0)
                ChangeNavigationButton(forward: true, enabled: project.edit.duration > 0 && editor.navigation.destination(from: editor.stationaryPlayhead, forward: true) != nil, hideFromAccessibility: fullPreview) { effectsOnly in
                    cancelPendingPlay(); editor.jumpChange(forward: true, effectsOnly: effectsOnly)
                }.frame(width: 44, height: 48)
                Button { jumpBookmark(project, forward: true) } label: { Image(systemName: "bookmark").overlay(alignment: .trailing) { Image(systemName: "chevron.right").font(.system(size: 7)).offset(x: 6) }.frame(width: 44, height: 48) }.accessibilityLabel("Next bookmark")
                if !accessible { timecode(duration, total: true).frame(maxWidth: .infinity, alignment: .trailing) }
            }
        }.padding(.horizontal, 12).foregroundStyle(.white).disabled(editor.loading)
    }
    private func timecode(_ seconds: Double, total: Bool = false) -> some View {
        Text(editorTime(seconds)).font(.caption.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.75)
            .fixedSize(horizontal: dynamicTypeSize.isAccessibilitySize, vertical: true)
            .foregroundStyle(total ? .secondary : .primary)
            .accessibilityIdentifier(total ? "editor.duration" : "editor.playhead")
    }
    private func timeline(_ project: Project, height: CGFloat) -> some View {
        let content = EditorTimeline(edit: moveDraft ?? project.edit, sources: project.sources, folder: store.folder(project), waves: editor.waveforms, processedWaves: editor.processedWaveforms, processedRegions: editor.waveformRegions, thumbnails: editor.thumbnails,
                       playhead: pickingMoveBoundary ? moveBrowseTime ?? editor.playhead : editor.playhead, pointsPerSecond: pointsPerSecond, selected: moveDraft == nil ? selectedTargets(project) : moveTargets,
                       selection: moveDraft == nil ? selection ?? markStart.map { min($0, editor.playhead)...max($0, editor.playhead) } : nil,
                       seek: { time in
                           cancelPendingPlay()
                           if pickingMoveBoundary { moveBrowseTime = time > (moveDraft?.duration ?? project.edit.duration) ? time : nil }
                           editor.seekPaused(time)
                       }, scrubbing: { active in if active { cancelPendingPlay() }; editor.setScrubbing(active) }, snapEnabled: snapToCuts, moving: moveDraft != nil, moveLayout: moveBase?.timeline, moveViewportEnd: moveViewportEnd,
                       boundaryChoices: pickingMoveBoundary ? moveBoundaries.times : nil,
                       pickBoundary: { choices in
                           if choices.count == 1, let time = choices.first { placeMove(at: time, project: project) }
                           else if !choices.isEmpty { nearbyMoveBoundaries = choices }
                       }, laneAreaHeight: height - 20, snapTime: moveSnap?.target.seconds, bookmarks: { bookmarksSheet = true },
                       focusTransition: { time in editor.pause(); removalRegionID = nil; editor.seek(time) },
                       addVideo: editor.loading || editor.rendering || moveDraft != nil ? nil : { site in
                           cancelPendingPlay(); editor.pause()
                           insertionTime = site.placement(in: project.edit.timeline, length: .zero).start.seconds
                           timelineAddSite = site; toolsSheet = true
                       },
                       move: { delta, scale in updateMove(moveDragOrigin + delta, project: project, scale: scale) }, moveEnded: { moveDragOrigin = moveOffset; previewMove(project) },
                       moveCancelled: { updateMove(moveDragOrigin, project: project, snapping: false); previewMove(project) },
                       editEffects: { regions in
                           editor.pause(); if regions.count == 1, let region = regions.first { toolRequest = request(for: region, project: project) }
                           else { effectChoices = regions; effectsSheet = true }
                       }, select: { id in
                           selectedItems = id.map { project.edit.timeline.selection(of: $0).ids } ?? []
                           selection = nil; markStart = nil; rangeTargets = nil
                       }, toggleSelection: { id in
                           editor.pause()
                           selectedItems = project.edit.timeline.toggling(id, in: selection == nil && markStart == nil ? selectedItems : [])
                           selection = nil; markStart = nil; rangeTargets = nil
                       },
                       zoom: { pointsPerSecond = $0 }, trim: { trimItem($0, left: $1, delta: $2, project: project) },
                       gainIdentity: "\(project.id)|\(project.historyCursor)", gainEnabled: !editor.loading && moveDraft == nil,
                       gainHeadroom: editor.headroom, gainHeadroomSelection: editor.headroomSelection,
                       previewGain: { db,scope in editor.auditionGain(db,selection:scope) },
                       commitGain: { db,scope in commitGain(db,scope:scope,project:project) }, hideFromAccessibility: fullPreview)
        return content.frame(height: min(height,content.contentHeight))
            .accessibilityAction(named: "Mark cut boundary") { if moveDraft == nil { mark(project) } }
            .accessibilityAction(named: "Split at playhead") { if moveDraft == nil { split(project) } }
            .accessibilityAction(named: "Delete selection") { if moveDraft == nil { removeSelection(project) } }

    }
    private func selectionStatus(_ project: Project) -> some View {
        let active = timelineRegions.filter { region in
            region.tool == .placement ? EditInterval(region.range).contains(EditTime(editor.playhead)) : region.range.contains(editor.playhead)
        }
        let placement = active.first { $0.tool == .placement }
        let cuts = moveDraft == nil && !editor.playing
            ? pasteTargets.filter { $0.isAt(EditTime(editor.playhead)) } : []
        let join = cutLayout.boundary(at: editor.playhead) ?? cuts.first(where: { $0.kind == .picture }).flatMap { cut in
            guard case let .between(left, right) = cut.anchor else { return nil }
            return cutLayout.joins.first { $0.incomingID == right && $0.outgoingID == left }
        }
        return HStack(spacing: 4) {
            if moveDraft != nil {
                moveActions(project)
            } else {
                if let id = removalRegionID, let armed = timelineRegions.first(where: { $0.id == id }) {
                    effectBubble(armed, project: project, identifier: "effect." + armed.tool.rawValue)
                } else if !selectedItems.isEmpty || selection != nil || markStart != nil {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            Menu {
                                Button("Copy", systemImage: "doc.on.doc") { copyOrCut(project, cut: false) }.disabled(markStart != nil)
                                Button("Cut", systemImage: "scissors") { copyOrCut(project, cut: true) }.disabled(markStart != nil)
                                if clipboard != nil { Button("Clear clipboard", systemImage: "xmark") { clipboard = nil } }
                                if let id = targets(project).audio.first, targets(project).audio.count == 1,
                                   let offset = project.edit.timeline.syncOffset(audio: id), offset != .zero {
                                    Button("Restore audio sync (\(offset.seconds.formatted(.number.sign(strategy: .always()).precision(.fractionLength(2)))) s)", systemImage: "arrow.triangle.2.circlepath") {
                                        var edit = project.edit; edit.timeline.restoreSync(audio: id); commit(edit, project: project)
                                    }
                                }
                                if selection != nil { Button("Preview cut", systemImage: "play.square") { quickReview(project) } }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(selectionTitle(project, scope: targets(project))).font(.caption.weight(.semibold))
                                    Text(markStart != nil ? "Choose end" : selection.map { editorTime($0.upperBound - $0.lowerBound) } ?? targets(project).countTitle).font(.caption2).foregroundStyle(.secondary)
                                }.lineLimit(1).frame(minWidth: 44, maxWidth: 120, minHeight: 48, alignment: .leading).accessibilityLabel("Selection actions: " + targets(project).title)
                            }
                            if selection != nil { Button { quickReview(project) } label: { Image(systemName: "play.square").frame(width: 44, height: 48) }.accessibilityLabel("Preview cut") }
                            clipboardButton(project, cut: false)
                            clipboardButton(project, cut: true)
                                .padding(.trailing, 4)
                            Button { removeSelection(project) } label: { Image(systemName: "trash").frame(width: 44, height: 48) }.foregroundStyle(editorAccent).accessibilityLabel(targets(project).video.isEmpty || targets(project).audio.isEmpty ? "Delete, leave gap" : "Delete selection")
                            clearSelectionButton
                            if clipboard != nil { pasteButton(cuts, project: project) }
                            if let placement { compactPlacement(placement, project: project) }
                        }
                    }
                } else if clipboard != nil || !active.isEmpty || (join?.maximum ?? 0) >= TimelineEditing.frame {
                    effectChips(project, active: active, join: join.flatMap { $0.maximum >= TimelineEditing.frame ? $0 : nil }, cuts: cuts)
                }
                else if project.edit.timeline.gap(at: EditTime(editor.playhead)) != nil {
                    Button("Close gap", systemImage: "arrow.right.and.line.vertical.and.arrow.left") {
                        var edit = project.edit
                        let cut = edit.timeline.gap(at: EditTime(editor.stationaryPlayhead))?.start.seconds
                        edit.timeline.closeGap(at: EditTime(editor.stationaryPlayhead))
                        commit(edit, project: project, position: cut)
                    }.frame(minHeight: 48)
                }
                else { Text(feedback ?? "Scroll to scrub · pinch to zoom").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Spacer(minLength: 0)
            }
        }.font(.subheadline).padding(.horizontal, 8).frame(minHeight: 48).padding(.vertical,6)
    }
    @ViewBuilder private func moveActions(_ project: Project) -> some View {
        let at = moveBoundaries.anchor + EditTime(moveOffset)
        let previous = moveBoundaries.previous(from: at), next = moveBoundaries.next(from: at)
        if pickingMoveBoundary {
            Image(systemName: "scope").foregroundStyle(.cyan).accessibilityHidden(true)
                .padding(.trailing, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text("Tap a dashed cyan line on the timeline").font(.headline)
                Text("Your selection will start there.").font(.subheadline).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("move.destinationPrompt")
            Spacer(minLength: 0)
            Button { pickingMoveBoundary = false } label: {
                Text("Back").frame(minWidth: 48, minHeight: 44).contentShape(Rectangle())
            }.accessibilityLabel("Back to Move")
        } else {
            VStack(alignment: .leading, spacing: 1) {
                Text(moveBoundaryLabel(at, among: moveBoundaries.times)).font(.subheadline.monospacedDigit().weight(.semibold))
                Text("Selection start").font(.caption2).foregroundStyle(.secondary)
            }.lineLimit(1).accessibilityElement(children: .ignore).accessibilityLabel("Selection start")
                .accessibilityValue(moveBoundaryLabel(at, among: moveBoundaries.times)).accessibilityIdentifier("move.anchor")
            HStack(spacing: 6) {
                Button { if let previous { placeMove(at: previous, project: project) } } label: {
                    moveBoundaryIcon("arrow.left.to.line", tint: .yellow)
                }.disabled(previous == nil).accessibilityLabel("Move to previous cut").accessibilityIdentifier("move.previous")
                Button { if let next { placeMove(at: next, project: project) } } label: {
                    moveBoundaryIcon("arrow.right.to.line", tint: .yellow)
                }.disabled(next == nil).accessibilityLabel("Move to next cut").accessibilityIdentifier("move.next")
                Button {
                    cancelPendingPlay(); editor.pause(); moveBrowseTime = nil; pickingMoveBoundary = true
                    UIAccessibility.post(notification: .announcement, argument: moveDestinationHint)
                } label: {
                    moveBoundaryIcon("scope", tint: .cyan)
                }.disabled(previous == nil && next == nil)
                    .accessibilityLabel("Move to a boundary").accessibilityIdentifier("move.choose")
            }.buttonStyle(EditorActionStyle())
            Spacer(minLength: 0)
            Button { finishMove(project, apply: false) } label: {
                Text("Cancel").frame(minWidth: 48, minHeight: 48).contentShape(Rectangle())
            }
            Button { finishMove(project, apply: true) } label: {
                Text("Done").fontWeight(.semibold).frame(minWidth: 44, minHeight: 48).contentShape(Rectangle())
            }
        }
    }

    private func moveBoundaryIcon(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.body.weight(.semibold))
            .foregroundStyle(tint)
            .frame(width: 44, height: 44)
            .background(tint.opacity(0.14), in: Circle())
            .frame(height: 48)
            .contentShape(Rectangle())
    }

    private func clipboardButton(_ project: Project, cut: Bool) -> some View {
        Button {
            copyOrCut(project, cut: cut)
        } label: {
            VStack(spacing: 2) {
                Image(systemName: cut ? "scissors" : "doc.on.doc")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.cyan)
                    .frame(height: clipboardIconHeight)
                Text(cut ? "Cut" : "Copy")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .frame(minWidth: 46, minHeight: 44)
            .background(.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(EditorActionStyle())
        .accessibilityLabel(cut ? "Cut selection" : "Copy selection")
        .accessibilityHint(cut ? "Removes the selection and puts it on the clipboard." : "Copies the selection to the clipboard.")
        .accessibilityIdentifier(cut ? "editor.cut" : "editor.copy")
        .disabled(markStart != nil)
    }

    private func pasteButton(_ cuts: [TimelinePasteTarget], project: Project) -> some View {
        let position = EditTime(editor.playhead)
        let insideTransition = project.edit.timeline.generated.contains { $0.interval.start < position && position < $0.interval.end }
        let insertsPicture = clipboard?.timeline.video.isEmpty == false &&
            (cuts.isEmpty ? clipboard?.insertsTime == true : cuts.contains { if case .between = $0.anchor { return true }; return false })
        let replacesTransition = insertsPicture && (insideTransition || cuts.contains { $0.transition != nil })
        let label = VStack(spacing: 1) {
            Label("Paste", systemImage: "doc.on.clipboard")
            if replacesTransition { Text("Replaces transition").font(.caption2) }
        }.fixedSize().padding(.horizontal, 12).frame(minHeight: 48).background(.cyan.opacity(0.12), in: Capsule())
        return Group {
            if cuts.count > 1 {
                Menu {
                    ForEach(cuts.indices, id: \.self) { i in
                        Button(cuts[i].label(in: project.edit.timeline)) { paste(project, target: cuts[i]) }
                    }
                } label: { label }
            } else {
                Button { paste(project, target: cuts.first) } label: { label }
            }
        }.foregroundStyle(.cyan).accessibilityLabel("Paste")
            .accessibilityValue(replacesTransition ? "Replaces transition" : "").accessibilityIdentifier("editor.paste")
            .disabled(editor.loading || editor.rendering || editor.playing)
    }

    private func compactPlacement(_ region: ToolRegion, project: Project) -> some View {
        effectBubble(region, project: project, identifier: "effect.placement").labelStyle(.iconOnly).frame(width: 44)
    }
    private func effectChips(_ project: Project, active: [ToolRegion], join: TransitionJoin? = nil, cuts: [TimelinePasteTarget] = []) -> some View {
        let regions = active.filter { join == nil || $0.effectID != join?.transition?.id }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if clipboard != nil {
                    pasteButton(cuts, project: project)
                    Button { clipboard = nil } label: { Image(systemName: "xmark").frame(width: 44, height: 48) }
                        .accessibilityLabel("Clear clipboard")
                }
                if let join {
                    if let transition=join.transition,let region=timelineRegions.first(where:{$0.tool == .transition && $0.effectID==transition.id}) {
                        effectBubble(region,project:project,identifier:"editor.transition")
                    } else {
                        Button {
                            removalRegionID=nil;editor.pause();editor.seek(join.time);toolRequest=makeToolRequest(.transition,project:project)
                        } label: {Label("Transition",systemImage:"plus").fixedSize().padding(.horizontal,12).frame(minHeight:48).background(Color.orange.opacity(0.12),in:Capsule())}
                            .foregroundStyle(.orange).accessibilityIdentifier("editor.transition")
                    }
                }
                if let placement = regions.first(where: { $0.tool == .placement }) {
                    effectBubble(placement, project: project, identifier: "effect.placement")
                }
                ForEach(regions.filter { $0.tool != .placement }) {region in effectBubble(region,project:project,identifier:"effect."+region.tool.rawValue)}
            }
        }
    }
    private func effectBubble(_ region:ToolRegion,project:Project,identifier:String)->some View {
        EffectRemovalBubble(title:region.label,symbol:region.tool.symbol,tint:region.tool.tint,identifier:identifier,
                            armed:removalRegionID==region.id,edit:{
            removalRegionID=nil;editor.pause();editor.seek(editor.playhead);toolRequest=request(for:region,project:project)
        },arm:{editor.pause();removalRegionID=region.id;UIImpactFeedbackGenerator(style:.light).impactOccurred()},cancel:{removalRegionID=nil},remove:{
            guard let current=self.project else {return}
            let state=current.edit.removingTool(request(for:region,project:current))
            removalRegionID=nil
            guard state != current.edit else {return}
            commit(state,project:current);feedback="Removed "+region.label+" · Undo available"
        })
    }
    private func copyOrCut(_ project: Project, cut: Bool) {
        guard markStart == nil, !selectedItems.isEmpty || selection != nil else { return }
        let scope = targets(project)
        if cut {
            var edit = project.edit
            guard let result = edit.timeline.cutToClipboard(scope, preserving: EditTime(editor.stationaryPlayhead)),
                  commit(edit, project: project, position: result.position.seconds) else { return }
            clipboard = result.clipboard
        } else {
            let copied = project.edit.timeline.copied(scope)
            guard !copied.isEmpty else { return }
            editor.pause()
            clipboard = copied
        }
        clearSelection()
        let message = cut ? "Cut to clipboard" : "Copied to clipboard"
        feedback = message
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    private func paste(_ project: Project, target: TimelinePasteTarget? = nil) {
        guard let clipboard, !clipboard.isEmpty else { return }
        var state = project.edit
        let added = state.timeline.paste(clipboard, at: EditTime(editor.stationaryPlayhead), target: target)
        guard !added.isEmpty, commit(state, project: project, position: state.timeline.interval(for: added)?.start.seconds) else { return }
        clearSelection(); selectedItems = added.ids
        feedback = "Pasted · Undo available"
        UIAccessibility.post(notification: .announcement, argument: "Pasted")
    }

    private func addVideoPanel(_ project: Project) -> some View {
        let target: TimelinePasteTarget?
        switch timelineAddSite {
        case .start: target = pasteTargets.first { $0.kind != .project && $0.anchor == .start }
        case .end: target = pasteTargets.first { $0.kind != .project && $0.anchor == .end }
        case .gap(let time): target = TimelinePasteTarget(kind: .picture, time: time, anchor: .gap)
        case nil: target = nil
        }
        // A cut can leave an empty project. Its start + still pastes at zero.
        return AddVideoPanel(store: store, project: project, position: insertionTime, site: timelineAddSite,
                      pasteHere: timelineAddSite != nil && clipboard != nil ? {
                          toolsSheet = false
                          paste(project, target: target)
                      } : nil,
                      close: timelineAddSite == nil ? nil : { toolsSheet = false }, record: {
            pendingRecord = true; toolsSheet = false
        }, inserted: { count, start in
            toolsSheet = false
            if let updated = self.project { finishEdit(updated.edit, from: project, position: start) }
            feedback = count == 1 ? "Clip inserted · Undo available" : "\(count) clips inserted · Undo available"
        })
    }
    private var clearSelectionButton: some View {
        Button {
            clearSelection()
            feedback = "Selection cleared"
        } label: {
            Image(systemName: "xmark").frame(width: 44, height: 48)
        }.foregroundStyle(.white.opacity(0.8))
            .accessibilityLabel("Clear selection").accessibilityIdentifier("editor.clearSelection")
    }
    private func editTools(_ project: Project, compact: Bool) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: dynamicTypeSize.isAccessibilitySize ? 2 : 4)
        return LazyVGrid(columns: columns, spacing: 8) {
            if moveDraft != nil {
                ForEach(TimelineMoveScope.allCases, id: \.self) { scope in
                    MoveScopeButton(scope: scope, chosen: scope == moveScope, compact: compact) {
                        changeMoveScope(scope, project: project)
                    }.disabled(!moveChoices.available(scope))
                }
            } else {
                tool(selection != nil ? "Move end" : markStart == nil ? "Mark start" : "Mark end", markStart == nil ? "rectangle.dashed" : "checkmark", compact: compact) { mark(project) }.disabled(project.edit.duration <= 0)
                tool("Split", "square.split.2x1", compact: compact) { split(project) }.disabled(project.edit.duration <= 0)
                tool("Tools", "square.grid.2x2", compact: compact) {
                    editor.pause(); editor.seek(editor.playhead); toolsSheet = true
                }.disabled(editor.rendering)
                tool("Export", "square.and.arrow.up", compact: compact, fill: MovieExportPanel.buttonColor) {
                    exportSheet = true
                }.disabled(project.edit.duration <= 0)
            }
        }.padding(.horizontal, 12).disabled(editor.loading && moveDraft == nil)
    }
    private func comparison(_ project: Project) -> some View {
        let scope = selectedTargets(project)
        let volumeScope = targets(project)
        let linked = project.edit.timeline.isSingleLink(scope)
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 6)) : AnyLayout(HStackLayout(spacing: 4))
        return layout {
            HStack(spacing: 4) {
                Button { history(project, redo: false) } label: { Image(systemName: "arrow.uturn.backward").frame(width: 44, height: 44) }.disabled(!project.canUndo || moveDraft != nil).accessibilityLabel("Undo")
                Button { history(project, redo: true) } label: { Image(systemName: "arrow.uturn.forward").frame(width: 44, height: 44) }.disabled(!project.canRedo || moveDraft != nil).accessibilityLabel("Redo")
                Button {
                    snapToCuts.toggle(); moveSnap = nil
                    UISelectionFeedbackGenerator().selectionChanged()
                } label: {
                    SnapMagnet(enabled: snapToCuts).frame(width: 44, height: 44)
                        .foregroundStyle(snapToCuts ? Color.yellow : Color.secondary)
                        .background(snapToCuts ? Color.yellow.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
                }.accessibilityLabel("Snap to cuts").accessibilityValue(snapToCuts ? "On" : "Off")
                    .accessibilityAddTraits(.isToggle)
                    .accessibilityHint("Snap the playhead and moved parts to nearby clip edges.")
                    .accessibilityIdentifier("editor.snap")
                    .highPriorityGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                        editor.error = "Snap aligns the playhead and moved parts with nearby clip edges and bookmarks. Turn the magnet off for free positioning. The one-frame Move arrows always remain precise."
                    })
            }
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
            HStack(spacing: 4) {
                tool(linked ? "Unlink" : "Link", linked ? "link" : "link.badge.plus", compact: true) { toggleLink(project) }.disabled(moveDraft != nil)
                tool("Move", "arrow.left.and.right", compact: true) { beginMove(project) }.disabled(scope.isEmpty || moveDraft != nil)
                QuickVolumeControl(value: AudioGainGrid.common(project.edit.timeline.audio.filter { volumeScope.audio.contains($0.id) }),
                    enabled: !volumeScope.audio.isEmpty && moveDraft == nil && !editor.loading,
                    headroom: scope.audio.isEmpty ? nil : editor.headroom,
                    tap: { editor.pause(); toolRequest = makeToolRequest(.volume, project: project) }).frame(width: 56, height: 44)
                    .task(id: "\(project.historyCursor)|\(scope.audio.sorted { $0.uuidString < $1.uuidString })|\(String(describing: scope.range))|\(editor.loading)|\(editor.gainRevision)|\(moveDraft != nil)") {
                        // Do not scan the whole project's sound merely to enable the
                        // button. The volume panel analyzes its full scope on opening.
                        guard !editor.loading, moveDraft == nil else { return }
                        await editor.measureHeadroom(selection: scope, timeline: project.edit.timeline)
                    }
            }
        }.padding(.horizontal, 8).padding(.top, 8).foregroundStyle(.white).disabled(editor.loading && moveDraft == nil)
    }
    private func commitGain(_ db:Double,scope:TimelineSelection,project:Project) {
        let wasPlaying=editor.playing
        var audioScope=scope;audioScope.video=[]
        var scoped=project.edit.timeline.scoped(audioScope)
        let indices = scoped.timeline.audio.indices.filter { scoped.selection.audio.contains(scoped.timeline.audio[$0].id) }
        guard indices.contains(where: { scoped.timeline.audio[$0].volumeDB != db }) else { return }
        for index in indices { scoped.timeline.audio[index].volumeDB = db }
        if commit(EditState(timeline:scoped.timeline,outputSize:project.edit.outputSize),project:project) {
            clearSelection();selectedItems=scoped.selection.ids
            if wasPlaying {resumeGainAtRevision=self.project?.historyCursor}
            feedback=String(format:"%+.1f dB · Undo available",db)
        }
    }
    private func uniqueEffects(_ project: Project) -> [ToolRegion] {
        var seen = Set<String>()
        let selection = selectedTargets(project)
        let regions = project.edit.toolRegions.filter { region in
            guard region.tool != .transition, region.tool != .placement else { return false }
            return selection.isEmpty || (selection.ids.contains(region.clipID) && (selection.range == nil || selection.range?.intersection(EditInterval(region.range)) != nil))
        }.sorted { a, b in
            let hereA = EditInterval(a.range).contains(EditTime(editor.playhead)), hereB = EditInterval(b.range).contains(EditTime(editor.playhead))
            if hereA != hereB { return hereA }
            return a.range.lowerBound < b.range.lowerBound
        }
        return regions.filter { seen.insert($0.tool.rawValue + $0.effectID.uuidString).inserted }
    }
    private func selectionTitle(_ project: Project, scope: TimelineSelection) -> String {
        let video = project.edit.timeline.video.enumerated().filter { scope.video.contains($0.element.id) }.map { "V\($0.offset + 1)" }
        let audio = project.edit.timeline.audio.enumerated().filter { scope.audio.contains($0.element.id) }.map { "♪\($0.offset + 1)" }
        let names = video + audio
        if names.count == 1, let item = project.edit.timeline.audio.first(where: { scope.audio.contains($0.id) }),
           let name = project.sources.first(where: { $0.id == item.sourceID })?.originalName { return names[0] + " · " + name }
        return names.count > 4 ? scope.title + " · \(names.count) items" : names.joined(separator: " + ")
    }
    private func toolScopeTitle(_ project: Project) -> String {
        if let selection { return "Selected range · \(editorTime(selection.lowerBound))–\(editorTime(selection.upperBound))" }
        if !selectedItems.isEmpty { return "Selected · " + targets(project).countTitle }
        return "Whole project · \(editorTime(project.edit.duration))"
    }
    private func coverAction(_ project: Project) -> (() -> Void)? {
        guard !project.edit.timeline.video.isEmpty, let item = editor.coverItem(for: project.edit) else { return nil }
        return {
            let scope = selection == nil && selectedItems.isEmpty ? TimelineSelection() : targets(project)
            coverPicker = CoverPickerSource(item: item, project: project, selection: scope,
                                            canvas: editor.canvas ?? item.presentationSize)
        }
    }
    private func makeToolRequest(_ kind: VideoTool, project: Project) -> ToolRequest {
        if kind == .transition, let join = project.edit.layout.boundary(at: editor.playhead) { return ToolRequest(tool: kind, range: join.range, scopeTitle: join.title, effectID: join.transition?.id, boundaryIndex: join.index) }
        var scope = targets(project)
        if [.enhanceAudio, .volume, .censorAudio].contains(kind) { scope.video = [] }
        var range = project.edit.timeline.interval(for: scope)?.seconds ?? 0...project.edit.duration
        if selection == nil, kind == .text || (kind == .image && selectedItems.isEmpty) { range = min(editor.playhead, max(0, project.edit.duration - TimelineEditing.frame))...min(project.edit.duration, editor.playhead + 3) }
        let title = kind == .volume && selectedTargets(project).isEmpty ? "Whole project · All audio" : selectionTitle(project, scope: scope)
        let scopeTitle = (kind == .text || kind == .image) ? title : title + " · " + editorTime(range.lowerBound) + "–" + editorTime(range.upperBound)
        return ToolRequest(tool: kind, range: range, scopeTitle: scopeTitle, clipIDs: scope.video, targets: scope)
    }
    private func request(for region: ToolRegion, project: Project) -> ToolRequest {
        if region.tool == .placement {
            let plan = project.edit.timeline.compile().first { $0.video.count > 1 && $0.interval.intersection(EditInterval(region.range)) != nil }
            let ids = Set(plan?.video ?? [])
            let selectedRange = selection.flatMap { EditInterval($0).intersection(EditInterval(region.range)) }
            return ToolRequest(tool:.placement, range:selectedRange?.seconds ?? region.range, scopeTitle:"Overlapping videos",
                               effectID:plan?.placementID, clipIDs:ids, targets:selectedRange.map { TimelineSelection(video:ids,range:$0) })
        }
        if region.tool == .transition, let join = project.edit.layout.joins.first(where: { $0.transition?.id == region.effectID }) {
            return ToolRequest(tool: .transition, range: join.range, scopeTitle: join.title, effectID: region.effectID, boundaryIndex: join.index)
        }
        return project.edit.request(for: region, selection: selectedTargets(project))
    }
    private func clipAtPlayhead(_ project: Project) -> TimelineClip? {
        project.edit.layout.placement(at: editor.playhead)?.clip
    }
    private func processingStatus() -> some View {
        VStack(spacing: 0) {
            if editor.rendering && editor.processingPreview {
                HStack {
                    ProgressView(value: editor.progress)
                    Text("\(Int(editor.progress * 100))%").font(.caption.monospacedDigit())
                    Button("Cancel") { editor.cancel() }.font(.caption).frame(minHeight: 44)
                }.padding(.horizontal, 16)
            }
            if let notice = editor.notice { Text(notice).font(.caption).foregroundStyle(.orange).padding(.horizontal, 16).padding(.bottom, 8) }
        }
    }
    private func tool(_ title: String, _ icon: String, compact: Bool = false, fill: Color = .white.opacity(0.07), action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                if compact || !dynamicTypeSize.isAccessibilitySize { Image(systemName: icon) }
                Text(compact ? (title == "Mark start" ? "Start" : title == "Mark end" || title == "Move end" ? "End" : title == "Preview cut" ? "Preview" : title) : title)
                    .lineLimit(compact ? 1 : 2, reservesSpace: !compact && dynamicTypeSize.isAccessibilitySize).multilineTextAlignment(.center)
            }.font(.caption.weight(.semibold)).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, minHeight: compact ? 44 : 48).padding(.vertical, compact ? 0 : 4)
                .background(fill, in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.white).id(title).transaction { $0.animation = nil }
        }.buttonStyle(EditorActionStyle()).accessibilityLabel(title)
    }
    private func cancelPendingPlay() { pendingPlay?.cancel(); pendingPlay = nil; playTapTime = nil }
    @discardableResult
    private func commit(_ state: EditState, project: Project, position: Double? = nil) -> Bool {
        cancelPendingPlay()
        editor.restoreAudition()
        editor.pause()
        viewPositions[project.historyCursor] = editor.playhead
        guard store.commit(projectID, state) else { return false }
        editor.cancelObsoleteEffectWork()
        finishEdit(state, from: project, position: position)
        return true
    }

    private func finishEdit(_ state: EditState, from project: Project, position: Double?) {
        if var scope = rangeTargets {
            scope.range = selection.map(EditInterval.init)
            let mapped = state.timeline.remapping(scope, from: project.edit.timeline)
            rangeTargets = mapped
            if selection != nil { selection = mapped.range?.seconds }
        }
        if !selectedItems.isEmpty {
            selectedItems = state.timeline.remapping(project.edit.timeline.selection(ids: selectedItems), from: project.edit.timeline).ids
        }
        let newPosition = position ?? min(editor.playhead, state.duration)
        if let updated = self.project { viewPositions[updated.historyCursor] = newPosition }
        editor.seekAfterEdit(newPosition, duration: state.duration)
    }
    private func history(_ project: Project, redo: Bool) {
        cancelPendingPlay(); editor.restoreAudition(); editor.pause(); viewPositions[project.historyCursor] = editor.playhead
        guard store.update(projectID, { if redo { $0.redo() } else { $0.undo() } }) else { return }
        editor.cancelObsoleteEffectWork()
        clearSelection()
        if let updated = self.project { editor.seekAfterEdit(viewPositions[updated.historyCursor] ?? editor.playhead, duration: updated.edit.duration) }
        feedback = redo ? "Redone" : "Undone"
    }
    private func split(_ project: Project) {
        let time = editor.playhead
        if cutLayout.transition(at: time) != nil { feedback = "Remove the transition before splitting inside its overlap"; return }
        let items = selection == nil && markStart == nil ? selectedItems : []
        let next = TimelineEditing.split(project.edit, at: time, selectedItems: items)
        guard next != project.edit else {
            feedback = cutLayout.placement(at: time).map { let joins = cutLayout.joins(for: $0); return joins.incoming.transition != nil || joins.outgoing.transition != nil } == true
                ? "Shorten or remove the nearby transition before splitting here" : "Move at least one frame inside a clip"
            return
        }
        guard commit(next, project: project, position: TimelineEditing.quantize(time)) else { return }
        clearSelection()
        feedback = "Split · Undo available"
        UISelectionFeedbackGenerator().selectionChanged()
    }
    private func mark(_ project: Project) {
        let raw = editor.playhead
        let boundary = snapToCuts ? TimelineEditing.snap(raw, clips: project.edit.clips, pointsPerSecond: pointsPerSecond) : raw
        let onBoundary = project.edit.layout.boundary(at: boundary) != nil
        var time = snapToCuts && onBoundary ? boundary : TimelineEditing.quantize(editor.snapped(raw, clips: project.edit.clips))
        if let join = project.edit.layout.transition(at: time) { time = join.time; feedback = "Selection aligned to the transition join" }
        editor.pause(); editor.seek(time)
        if let selection {
            guard time - selection.lowerBound >= TimelineEditing.frame - 0.00001 else { feedback = "Place the end after the start"; return }
            self.selection = selection.lowerBound...time
        } else if let start = markStart {
            guard abs(start - time) >= TimelineEditing.frame - 0.00001 else { feedback = "Choose an end at least one frame away"; return }
            selection = min(start, time)...max(start, time); markStart = nil
        } else { selection = nil; markStart = time; rangeTargets = targets(project) }
        UISelectionFeedbackGenerator().selectionChanged()
    }
    private func clearSelection() { selection = nil; markStart = nil; selectedItems = []; rangeTargets = nil }
    private func removeSelection(_ project: Project) {
        guard !selectedItems.isEmpty || selection != nil else { return }
        var scope = project.edit.timeline.scoped(targets(project))
        let position = scope.timeline.remove(scope.selection, preserving: EditTime(editor.stationaryPlayhead))
        let next = EditState(timeline: scope.timeline, outputSize: project.edit.outputSize)
        guard !scope.selection.isEmpty, next != project.edit else { clearSelection(); feedback = "Nothing selected to delete"; return }
        guard commit(next, project: project, position: position?.seconds) else { return }
        clearSelection(); feedback = "Deleted · Undo available"
    }
    private func toggleLink(_ project: Project) {
        guard selection == nil && markStart == nil else {
            editor.error = "Clear the time range, then tap a part and long-press other parts to select them for Link."; return
        }
        let scope = selectedTargets(project)
        if project.edit.timeline.isSingleLink(scope) {
            var edit = project.edit; edit.timeline.unlink(scope)
            if commit(edit, project: project) { feedback = "Unlinked \(scope.countTitle) · Undo restores links" }
            return
        }
        do {
            let plan = try project.edit.timeline.linkPlan(scope)
            if plan.needsIntersection { pendingLinkBase = project.edit; pendingLink = plan }
            else { applyLink(scope, project: project) }
        } catch { editor.error = error.localizedDescription }
    }
    private func applyLink(_ scope: TimelineSelection, project: Project, intersectionOnly: Bool = false) {
        do {
            let joined = try project.edit.timeline.joining(scope, intersectionOnly: intersectionOnly)
            var edit = project.edit; edit.timeline = joined.timeline
            if commit(edit, project: project) {
                selectedItems = joined.selection.ids
                feedback = "Linked · Undo available"
            }
        } catch { editor.error = error.localizedDescription }
    }
    private func beginMove(_ project: Project) {
        cancelPendingPlay(); editor.restoreAudition(); editor.pause()
        let scope = project.edit.timeline.scoped(targets(project))
        guard !scope.selection.isEmpty else { return }
        var base = project.edit; base.timeline = scope.timeline
        moveChoices = base.timeline.moveChoices(for: scope.selection); moveScope = .selected
        moveOrigin = MoveOrigin(revision: project.updatedAt, playhead: editor.playhead, scale: pointsPerSecond)
        moveBoundaries = TimelineMoveBoundaries(timeline: base.timeline, picked: scope.selection, moving: scope.selection)
        pickingMoveBoundary = false; moveViewportEnd = nil
        moveBase = base; moveDraft = base; moveOffset = 0; requestedMoveOffset = 0; moveDragOrigin = 0; moveSnap = nil
    }
    private func changeMoveScope(_ scope: TimelineMoveScope, project: Project) {
        guard scope != moveScope, moveChoices.available(scope) else { return }
        guard let base = moveBase else { return }
        moveScope = scope
        moveBoundaries = TimelineMoveBoundaries(timeline: base.timeline, picked: moveChoices.selected, moving: moveChoices[scope])
        nearbyMoveBoundaries = []
        updateMove(requestedMoveOffset, project: project, snapping: false, changingScope: true)
        moveDragOrigin = moveOffset
        if requestedMoveOffset != 0 { previewMove(project) }
        UISelectionFeedbackGenerator().selectionChanged()
    }
    private func placeMove(at time: EditTime, project: Project) {
        guard moveOrigin?.revision == project.updatedAt, moveBoundaries.times.contains(time) else { return }
        cancelPendingPlay(); editor.pause()
        pickingMoveBoundary = false
        updateMove((time - moveBoundaries.anchor).seconds, project: project, snapping: false)
        moveDragOrigin = moveOffset
        moveSnap = TimelineMoveSnap(target: time, edge: moveBoundaries.anchor)
        if let draft = moveDraft {
            moveViewportEnd = max(EditTime(project.edit.duration), draft.timeline.duration)
            editor.seekAfterEdit(time.seconds, duration: draft.duration)
        }
        previewMove(project)
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func updateMove(_ offset: Double, project: Project, snapping: Bool = true, scale: Double? = nil, changingScope: Bool = false) {
        guard var base = moveBase, let interval = base.timeline.interval(for: moveTargets) else { return }
        var delta = max(-interval.start.seconds, offset)
        let previousSnap = moveSnap
        if snapToCuts && snapping {
            let result = base.timeline.snappedMove(moveTargets, by: EditTime(delta), scale: scale ?? pointsPerSecond, latch: moveSnap, extra: [editor.playhead])
            delta = result.delta.seconds; moveSnap = result.snap
        } else { moveSnap = nil }
        if let snap = moveSnap, snap != previousSnap { UISelectionFeedbackGenerator().selectionChanged() }
        moveOffset = max(-interval.start.seconds, delta)
        // Trying a wider group can hit time zero. Switching back restores the original drag.
        if !changingScope { requestedMoveOffset = moveOffset }
        base.timeline.move(moveTargets, by: EditTime(moveOffset)); moveDraft = base
        if changingScope, moveViewportEnd != nil {
            moveViewportEnd = max(EditTime(project.edit.duration), base.timeline.duration)
        }
    }
    private func previewMove(_ project: Project) {
        guard let draft = moveDraft else { return }
        var candidate = project; candidate.history = [draft]; candidate.historyCursor = 0
        movePreviewTask?.cancel()
        movePreviewTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(120)); try Task.checkCancellation(); await editor.load(candidate, folder: store.folder(project)) } catch {}
        }
    }
    private func finishMove(_ project: Project, apply: Bool) {
        movePreviewTask?.cancel(); movePreviewTask = nil
        guard let origin = moveOrigin else { return }
        if apply, origin.revision == project.updatedAt, let draft = moveDraft, EditTime(moveOffset) != .zero {
            guard commit(draft, project: project) else { return }
            viewPositions[project.historyCursor] = origin.playhead
            clearSelection()
        } else {
            pointsPerSecond = origin.scale
            editor.pause(); editor.seekAfterEdit(origin.playhead, duration: project.edit.duration)
            Task { await editor.load(project, folder: store.folder(project)) }
        }
        pickingMoveBoundary = false; nearbyMoveBoundaries = []; moveOrigin = nil; moveViewportEnd = nil
        moveDraft = nil; moveBase = nil; moveDragOrigin = 0; moveSnap = nil
        if origin.revision != project.updatedAt { feedback = "Timeline changed. Select the clips again." }
        else { feedback = apply ? (EditTime(moveOffset) == .zero ? nil : "Moved · Undo available") : "Move cancelled" }
    }
    private func trimItem(_ id: UUID, left: Bool, delta: Double, project: Project) {
        let chosen = project.edit.timeline.selection(of: id)
        guard let interval = project.edit.timeline.interval(for: chosen) else { return }
        if left && delta < 0 || !left && delta > 0 {
            var edit = project.edit; edit.timeline.extend(chosen, left: left, by: EditTime(abs(delta)), sources: project.sources)
            if edit != project.edit { commit(edit, project: project); feedback = "Trim extended · Undo available" }
            return
        }
        // A trim removes material from this occurrence, never from another lane.
        let point = left ? min(interval.end.seconds - TimelineEditing.frame, max(interval.start.seconds, interval.start.seconds + delta)) : max(interval.start.seconds + TimelineEditing.frame, min(interval.end.seconds, interval.end.seconds + delta))
        let removed = left ? interval.start.seconds...point : point...interval.end.seconds
        guard removed.upperBound - removed.lowerBound > 0.00001 else { return }
        var target = chosen; target.range = EditInterval(removed)
        var scope = project.edit.timeline.scoped(target)
        let position = scope.timeline.remove(scope.selection, preserving: EditTime(editor.stationaryPlayhead))
        commit(EditState(timeline: scope.timeline, outputSize: project.edit.outputSize), project: project, position: position?.seconds)
        feedback = "Trimmed · Undo available"
    }
    private func jumpBookmark(_ project: Project, forward: Bool) {
        let marks = project.edit.timeline.resolvedBookmarks
        guard !marks.isEmpty else { cancelPendingPlay(); editor.pause(); bookmarkHelp = true; return }
        let mark = forward ? marks.first { $0.time.seconds > editor.playhead + 0.02 } : marks.last { $0.time.seconds < editor.playhead - 0.02 }
        if let mark { cancelPendingPlay(); editor.seekPaused(mark.time.seconds) }
    }
    private func addBookmark(_ project: Project) {
        var edit = project.edit; edit.timeline.addBookmark(at: EditTime(editor.playhead), preferredVideo: selectedClip)
        store.commit(project.id, edit); feedback = "Bookmark added"
    }
    private func bookmarkThumbnail(_ mark: ResolvedBookmark, project: Project) -> UIImage? {
        guard let item = project.edit.timeline.video.filter({ $0.interval.contains(mark.time) }).max(by: { $0.layer < $1.layer }),
              let source = item.mapping.source(at: mark.time - item.start), let frames = editor.thumbnails[item.content.sourceID] else { return nil }
        return frames.last(where: { $0.time <= source })?.image ?? frames.first?.image
    }
    private func bookmarkPanel(_ project: Project) -> some View {
        NavigationStack {
            List {
                Button { addBookmark(project) } label: { Label("Add at \(editorTime(editor.playhead))", systemImage: "bookmark.badge.plus").frame(minHeight: 44) }
                ForEach(project.edit.timeline.resolvedBookmarks) { mark in
                    Button { editor.seek(mark.time.seconds); bookmarksSheet = false } label: {
                        HStack {
                            if let thumbnail = bookmarkThumbnail(mark, project: project) { Image(uiImage: thumbnail).resizable().scaledToFill().frame(width: 56, height: 40).clipped().clipShape(RoundedRectangle(cornerRadius: 5)) }
                            else { Image(systemName: "bookmark.fill").foregroundStyle(.orange) }
                            VStack(alignment: .leading) { Text(mark.bookmark.label.isEmpty ? "Bookmark" : mark.bookmark.label); Text(editorTime(mark.time.seconds)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                        }.frame(minHeight: 44)
                    }.contextMenu { Button("Rename", systemImage: "pencil") { bookmarkName = mark.bookmark.label; renamingBookmark = mark.id } }
                    .swipeActions { Button("Delete", role: .destructive) { var state = project.edit; state.timeline.bookmarks.removeAll { $0.id == mark.id }; commit(state, project: project) } }
                }
            }.navigationTitle("Bookmarks").toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { bookmarksSheet = false } } }
        }
        .alert("Bookmark label", isPresented: Binding(get: { renamingBookmark != nil }, set: { if !$0 { renamingBookmark = nil } })) {
                TextField("Label", text: $bookmarkName)
                Button("Save") { if let id = renamingBookmark { var edit = project.edit; if let index = edit.timeline.bookmarks.firstIndex(where: { $0.id == id }) { edit.timeline.bookmarks[index].label = String(bookmarkName.prefix(120)); store.commit(project.id, edit) } }; renamingBookmark = nil }
                Button("Cancel", role: .cancel) { renamingBookmark = nil }
            }
        .presentationDetents([.medium, .large])
    }

}

/// Native cancellation guarantees that a hold fires only effects-only navigation,
/// never an additional cut jump when the finger lifts. Same control in Full.
struct ChangeNavigationButton: UIViewRepresentable {
    let forward: Bool
    var enabled = true
    var hideFromAccessibility = false
    var identifierPrefix = "transport"
    let action: (Bool) -> Void
    func makeUIView(context: Context) -> ChangeNavigationControl { ChangeNavigationControl() }
    func updateUIView(_ button: ChangeNavigationControl, context: Context) {
        button.action = action; button.isEnabled = enabled && context.environment.isEnabled
        button.isAccessibilityElement = !hideFromAccessibility
        button.setImage(UIImage(systemName: forward ? "forward.end" : "backward.end", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17)), for: .normal)
        button.accessibilityLabel = forward ? "Next change" : "Previous change"
        button.accessibilityIdentifier = identifierPrefix + (forward ? ".nextChange" : ".previousChange")
        button.accessibilityHint = "Jump to a cut or effect change. Hold to skip cuts."
        button.accessibilityCustomActions = [UIAccessibilityCustomAction(name: forward ? "Next effect change only" : "Previous effect change only") { [weak button] _ in
            guard let button, button.isEnabled else { return false }; button.action?(true); return true
        }]
    }
}
final class ChangeNavigationControl: UIButton {
    var action: ((Bool) -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        tintColor = .white
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.45; hold.cancelsTouchesInView = true
        addGestureRecognizer(hold)
    }
    @objc private func tapped() { action?(false) }
    @objc private func held(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began && isEnabled { UISelectionFeedbackGenerator().selectionChanged(); action?(true) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    var inspectionZoom = true
    var onPointTap:((CGPoint)->Void)?
    var onPlaybackTap:(()->Void)?
    var hideFromAccessibility = false
    var identifier="editor.preview"
    var preserveInspection=false
    var onPointOutside:(()->Void)?
    var onBackgroundGesture:((VideoEffectPlacementGesture)->Void)?
    var captions: CaptionPreview?
    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView(); view.configure(player: player, inspectionZoom: inspectionZoom,preserveInspection:preserveInspection);view.onPointTap=onPointTap;view.onPlaybackTap=onPlaybackTap;view.accessibilityElementsHidden=hideFromAccessibility;view.previewIdentifier=identifier;view.onPointOutside=onPointOutside;view.onBackgroundGesture=onBackgroundGesture; view.captions=captions; return view
    }
    func updateUIView(_ uiView: PlayerLayerView, context: Context) { uiView.configure(player: player, inspectionZoom: inspectionZoom,preserveInspection:preserveInspection);uiView.onPointTap=onPointTap;uiView.onPlaybackTap=onPlaybackTap;uiView.accessibilityElementsHidden=hideFromAccessibility;uiView.previewIdentifier=identifier;uiView.onPointOutside=onPointOutside;uiView.onBackgroundGesture=onBackgroundGesture; uiView.captions=captions }
    static func dismantleUIView(_ uiView: PlayerLayerView, coordinator: ()) { uiView.layerPlayer.player = nil }
}
struct CaptionPreview {
    var envelope: CGRect
    var value: String
    var editable = true
    var change: (VideoEffectPlacementGesture) -> Void
}
final class PlayerLayerView: UIView, UIGestureRecognizerDelegate {
    let layerPlayer = AVPlayerLayer()
    private let picture = UIView()
    private let captionHandle = UIView()
    private let captionGuide = CAShapeLayer()
    private var captionPan = false
    private var captionPinch = false
    var captions: CaptionPreview? {
        // A seek can update this representable inside a SwiftUI graph update.
        // Synchronously committing a layer transaction here re-enters that graph.
        didSet { if captions != nil || oldValue != nil { setNeedsLayout() } }
    }
    var previewIdentifier="editor.preview" { didSet { picture.accessibilityIdentifier=previewIdentifier } }
    private let resetButton = UIButton(type: .system)
    var onBackgroundGesture:((VideoEffectPlacementGesture)->Void)? {didSet {
        if (oldValue==nil) != (onBackgroundGesture==nil) {backgroundPanPoint=nil;backgroundPinchPoint=nil;backgroundScale=1;setNeedsLayout();updateGestureAccessibility()}
    }}
    private var backgroundPanPoint:CGPoint?
    private var backgroundPinchPoint:CGPoint?
    private var inspectionZoomEnabled=true
    private var backgroundScale:CGFloat=1
    var onPointTap:((CGPoint)->Void)? { didSet { pointTap.isEnabled=onPointTap != nil || onPlaybackTap != nil } }
    var onPlaybackTap:(()->Void)? { didSet { pointTap.isEnabled=onPointTap != nil || onPlaybackTap != nil; updateGestureAccessibility() } }
    private lazy var pointTap=UITapGestureRecognizer(target:self,action:#selector(pickedPoint(_:)))
    private lazy var pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
    private var zoom = CGFloat(1)
    private var offset = CGPoint.zero
    private var gestureZoom = CGFloat(1)
    private var gestureOffset = CGPoint.zero
    private var gestureAnchor = CGPoint.zero
    private var pinchBase = CGFloat(1)
    private var pinchTouches = 0
    private var panNeedsAnchor = true
    private var panOrigin = CGPoint.zero
    private var panOffset = CGPoint.zero
    private var previousSize = CGSize.zero
    private var knownCanvas=CGSize.zero
    private var preserveInspection=false
    var onPointOutside:(()->Void)?
    private var sizeObservation:NSKeyValueObservation?
    private var item: AVPlayerItem?
    private var readyObservation: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?
    private var durationObservation: NSKeyValueObservation?
    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true; backgroundColor = .black
        addSubview(picture); picture.layer.addSublayer(layerPlayer)
        picture.isAccessibilityElement = true; picture.accessibilityIdentifier = "editor.preview"
        picture.accessibilityLabel = "Video preview"
        captionHandle.isUserInteractionEnabled = false; captionHandle.isAccessibilityElement = true
        captionHandle.accessibilityIdentifier = "subtitles.placement"
        captionHandle.accessibilityLabel = "Subtitle placement"
        captionHandle.accessibilityHint = "Drag to move, pinch to resize all captions. Limited by the largest caption in the project."
        captionHandle.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Move subtitles left") { [weak self] _ in self?.captions?.change(.pan(CGPoint(x: -0.05, y: 0))); return true },
            UIAccessibilityCustomAction(name: "Move subtitles right") { [weak self] _ in self?.captions?.change(.pan(CGPoint(x: 0.05, y: 0))); return true },
            UIAccessibilityCustomAction(name: "Move subtitles up") { [weak self] _ in self?.captions?.change(.pan(CGPoint(x: 0, y: -0.05))); return true },
            UIAccessibilityCustomAction(name: "Move subtitles down") { [weak self] _ in self?.captions?.change(.pan(CGPoint(x: 0, y: 0.05))); return true },
            UIAccessibilityCustomAction(name: "Enlarge subtitles") { [weak self] _ in self?.resizeCaption(1.1); return true },
            UIAccessibilityCustomAction(name: "Shrink subtitles") { [weak self] _ in self?.resizeCaption(1 / 1.1); return true }
        ]; addSubview(captionHandle)
        captionGuide.strokeColor = UIColor.systemCyan.cgColor; captionGuide.fillColor = UIColor.clear.cgColor
        captionGuide.actions = ["path": NSNull(), "hidden": NSNull()]
        captionGuide.lineWidth = 1; captionGuide.lineDashPattern = [4, 3]; layer.addSublayer(captionGuide)
        pointTap.delegate=self;pointTap.isEnabled=false;addGestureRecognizer(pointTap)
        pinch.delegate = self; addGestureRecognizer(pinch); pan.maximumNumberOfTouches = 2; pan.delegate = self; addGestureRecognizer(pan)
        resetButton.setImage(UIImage(systemName: "arrow.down.right.and.arrow.up.left", withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .semibold)), for: .normal)
        resetButton.tintColor = .white; resetButton.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        resetButton.layer.cornerRadius = 24; resetButton.isHidden = true
        resetButton.accessibilityLabel = "Reset preview zoom"; resetButton.accessibilityIdentifier = "editor.preview.resetZoom"
        resetButton.addTarget(self, action: #selector(resetZoom), for: .touchUpInside); addSubview(resetButton)
        readyObservation = layerPlayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.updateAccessibility(); self?.setNeedsLayout() }
        }
    }
    func configure(player: AVPlayer, inspectionZoom: Bool,preserveInspection:Bool=false) {
        self.preserveInspection=preserveInspection
        if layerPlayer.player !== player {
            layerPlayer.player = player
            // SwiftUI can keep this representable unchanged while the same
            // AVPlayer receives a new item. Follow that change directly.
            itemObservation = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] player, _ in
                DispatchQueue.main.async {
                    guard let self, self.layerPlayer.player === player else { return }
                    self.bindItem(player.currentItem)
                }
            }
        }
        bindItem(player.currentItem)
        pinch.isEnabled = inspectionZoom; pan.isEnabled = inspectionZoom
        if !inspectionZoom { resetZoom() }
        inspectionZoomEnabled=inspectionZoom;updateGestureAccessibility()
        updateAccessibility()
    }
    private func updateGestureAccessibility() {
        if onBackgroundGesture != nil {
            picture.accessibilityHint="Position the background in the exported video. Use actions to move or scale it; Cancel restores its previous position."
            picture.accessibilityCustomActions=[
                UIAccessibilityCustomAction(name:"Move background left") { [weak self] _ in self?.onBackgroundGesture?(.pan(CGPoint(x:-0.05,y:0)));self?.onBackgroundGesture?(.ended);return true },
                UIAccessibilityCustomAction(name:"Move background right") { [weak self] _ in self?.onBackgroundGesture?(.pan(CGPoint(x:0.05,y:0)));self?.onBackgroundGesture?(.ended);return true },
                UIAccessibilityCustomAction(name:"Move background up") { [weak self] _ in self?.onBackgroundGesture?(.pan(CGPoint(x:0,y:-0.05)));self?.onBackgroundGesture?(.ended);return true },
                UIAccessibilityCustomAction(name:"Move background down") { [weak self] _ in self?.onBackgroundGesture?(.pan(CGPoint(x:0,y:0.05)));self?.onBackgroundGesture?(.ended);return true },
                UIAccessibilityCustomAction(name:"Enlarge background") { [weak self] _ in self?.onBackgroundGesture?(.pinch(factor:1.1,from:CGPoint(x:0.5,y:0.5),to:CGPoint(x:0.5,y:0.5)));self?.onBackgroundGesture?(.ended);return true },
                UIAccessibilityCustomAction(name:"Shrink background") { [weak self] _ in self?.onBackgroundGesture?(.pinch(factor:1/1.1,from:CGPoint(x:0.5,y:0.5),to:CGPoint(x:0.5,y:0.5)));self?.onBackgroundGesture?(.ended);return true }
            ]
        } else {
            picture.accessibilityHint = inspectionZoomEnabled ? "Pinch to inspect, drag while zoomed. Preview zoom does not change the export." : nil
            if onPlaybackTap != nil { picture.accessibilityHint = "Tap to play or pause. " + (picture.accessibilityHint ?? "") }
            picture.accessibilityCustomActions = inspectionZoomEnabled ? [
                UIAccessibilityCustomAction(name: "Zoom in preview") { [weak self] _ in self?.changeZoom(by: 1.5); return true },
                UIAccessibilityCustomAction(name: "Zoom out preview") { [weak self] _ in self?.changeZoom(by: 1 / 1.5); return true },
                UIAccessibilityCustomAction(name: "Reset preview zoom") { [weak self] _ in self?.resetZoom(); return true }
            ] : nil
            if onPlaybackTap != nil {
                picture.accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Play or pause") { [weak self] _ in self?.onPlaybackTap?(); return true }] + (picture.accessibilityCustomActions ?? [])
            }
        }
    }
    private func bindItem(_ value: AVPlayerItem?) {
        guard item !== value else { return }
        item = value
        if !preserveInspection { resetZoom() }
        sizeObservation=value?.observe(\.presentationSize,options:[.initial,.new]) { [weak self] value,_ in
            DispatchQueue.main.async {
                guard let self,self.item===value,value.presentationSize.width>0,value.presentationSize.height>0 else { return }
                if self.knownCanvas != .zero && self.knownCanvas != value.presentationSize { self.resetZoom() }
                self.knownCanvas=value.presentationSize;self.updatePicture()
            }
        }
        durationObservation = item?.observe(\.duration, options: [.initial, .new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self, self.item === item else { return }
                self.updateAccessibility()
            }
        }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        if previousSize != bounds.size { zoom = 1; offset = .zero; previousSize = bounds.size }
        picture.frame = bounds
        let resetWidth:CGFloat=preserveInspection ? 134 : 48
        resetButton.frame=CGRect(x:max(0,bounds.width-resetWidth-8),y:max(8,bounds.height-56),width:resetWidth,height:48)
        updatePicture()
    }
    private func updatePicture() {
        let measured=item?.presentationSize ?? .zero
        let size=measured.width>0 && measured.height>0 ? measured : knownCanvas != .zero ? knownCanvas : bounds.size
        let fit = size.width > 0 && size.height > 0 ? AVMakeRect(aspectRatio: size, insideRect: bounds).size : bounds.size
        let limitX = max(0, (fit.width * zoom - bounds.width) / 2), limitY = max(0, (fit.height * zoom - bounds.height) / 2)
        offset.x = min(limitX, max(-limitX, offset.x)); offset.y = min(limitY, max(-limitY, offset.y))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layerPlayer.frame = CGRect(x: (bounds.width * (1 - zoom)) / 2 + offset.x, y: (bounds.height * (1 - zoom)) / 2 + offset.y,
                                  width: bounds.width * zoom, height: bounds.height * zoom)
        CATransaction.commit()
        resetButton.setTitle(preserveInspection ? String(format:" %.1f× · Preview",zoom) : nil,for:.normal)
        resetButton.titleLabel?.font = .systemFont(ofSize:12,weight:.semibold)
        resetButton.isHidden = zoom <= 1.001 || onBackgroundGesture != nil; updateAccessibility(); updateCaptions()
    }
    private func resizeCaption(_ factor: Double) {
        guard let captions else { return }
        let center = CGPoint(x: captions.envelope.midX, y: captions.envelope.midY)
        captions.change(.pinch(factor: factor, from: center, to: center))
    }
    private func updateCaptions() {
        guard let captions else {
            captionHandle.isHidden = true; captionGuide.isHidden = true
            return
        }
        let video = layerPlayer.convert(layerPlayer.videoRect, to: layer)
        func screen(_ r: CGRect) -> CGRect { CGRect(x: video.minX + r.minX * video.width, y: video.minY + r.minY * video.height, width: r.width * video.width, height: r.height * video.height) }
        captionHandle.isHidden = !captions.editable || video.isEmpty
        let box = screen(captions.envelope)
        captionHandle.frame = box.insetBy(dx: -max(0, (44 - box.width) / 2), dy: -max(0, (44 - box.height) / 2))
        captionHandle.accessibilityValue = captions.value
        captionGuide.path = CGPath(rect: box, transform: nil)
        captionGuide.isHidden = !captionPan && !captionPinch
    }
    private func positionCaption(_ gesture: UIGestureRecognizer, pinching: Bool) -> Bool {
        guard let captions, captions.editable else { captionPan = false; captionPinch = false; return false }
        if gesture.state == .began {
            let hits = captionHandle.frame.insetBy(dx: -10, dy: -10).contains(gesture.location(in: self))
            if pinching { captionPinch = captionPan || hits } else { captionPan = captionPinch || hits }
            if pinching ? captionPinch : captionPan { captions.change(.pan(.zero)) }
        }
        let owns = pinching ? captionPinch : captionPan
        if owns { positionBackground(gesture, action: captions.change) }
        if [.ended, .cancelled, .failed].contains(gesture.state) {
            if pinching { captionPinch = false; panNeedsAnchor = true } else { captionPan = false }
        }
        updateCaptions()
        return owns
    }
    private func updateAccessibility() {
        let duration = item?.duration.seconds ?? 0
        picture.accessibilityValue = layerPlayer.isReadyForDisplay ? "Frame visible · " + String(format: "%.2f seconds", duration.isFinite ? duration : 0) + String(format: " · %.2f× view", zoom) : "Loading frame"
    }
    @objc private func resetZoom() { zoom = 1; offset = .zero; updatePicture() }
    private func changeZoom(by factor: CGFloat) { zoom = min(8, max(1, zoom * factor)); updatePicture() }
    private func backgroundLocation(_ gesture:UIGestureRecognizer)->CGPoint? {
        let point=layerPlayer.convert(gesture.location(in:self),from:layer),rect=layerPlayer.videoRect
        guard rect.width>0,rect.height>0 else {return nil}
        return CGPoint(x:(point.x-rect.minX)/rect.width,y:(point.y-rect.minY)/rect.height)
    }
    private func positionBackground(_ gesture:UIGestureRecognizer, action supplied: ((VideoEffectPlacementGesture) -> Void)? = nil) {
        guard let action=supplied ?? onBackgroundGesture else {return}
        if let pinch=gesture as? UIPinchGestureRecognizer {
            backgroundPanPoint=nil
            if [.ended,.cancelled,.failed].contains(gesture.state) || pinch.numberOfTouches<2 {
                backgroundPinchPoint=nil;backgroundScale=1;action(.ended);return
            }
            guard let point=backgroundLocation(gesture) else {return}
            if gesture.state == .began || backgroundPinchPoint==nil {backgroundPinchPoint=point;backgroundScale=pinch.scale;return}
            action(.pinch(factor:Double(pinch.scale/max(0.0001,backgroundScale)),from:backgroundPinchPoint!,to:point))
            backgroundScale=pinch.scale;backgroundPinchPoint=point
        } else {
            if [.ended,.cancelled,.failed].contains(gesture.state) {backgroundPanPoint=nil;action(.ended);return}
            guard pinch.numberOfTouches<2,gesture.numberOfTouches==1 else {backgroundPanPoint=nil;return}
            guard let point=backgroundLocation(gesture) else {return}
            if gesture.state == .began || backgroundPanPoint==nil {backgroundPanPoint=point;return}
            action(.pan(CGPoint(x:point.x-backgroundPanPoint!.x,y:point.y-backgroundPanPoint!.y)))
            backgroundPanPoint=point
        }
    }
    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        if positionCaption(gesture, pinching: true) { return }
        if onBackgroundGesture != nil {positionBackground(gesture);return}
        guard (gesture.state == .began || gesture.state == .changed), gesture.numberOfTouches >= 2 else {
            pinchTouches = 0; panNeedsAnchor = true; return
        }
        if gesture.state == .began || pinchTouches != gesture.numberOfTouches {
            gestureZoom = zoom; gestureOffset = offset; gestureAnchor = gesture.location(in: self); pinchBase = gesture.scale
        }
        pinchTouches = gesture.numberOfTouches; panNeedsAnchor = true
        zoom = min(8, max(1, gestureZoom * gesture.scale / max(0.001, pinchBase)))
        let point = gesture.location(in: self), ratio = zoom / gestureZoom
        offset = CGPoint(x: point.x - bounds.midX - (gestureAnchor.x - bounds.midX - gestureOffset.x) * ratio,
                         y: point.y - bounds.midY - (gestureAnchor.y - bounds.midY - gestureOffset.y) * ratio)
        updatePicture()
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        (gestureRecognizer === pinch && otherGestureRecognizer === pan) || (gestureRecognizer === pan && otherGestureRecognizer === pinch)
    }
    func gestureRecognizer(_ gestureRecognizer:UIGestureRecognizer,shouldReceive touch:UITouch)->Bool {
        if gestureRecognizer===pointTap {
            var view=touch.view
            while let current=view,current !== self { if current is UIControl { return false };view=current.superview }
        }
        return true
    }
    @objc private func pickedPoint(_ gesture:UITapGestureRecognizer) {
        guard let onPointTap else { onPlaybackTap?(); return }
        let point=layerPlayer.convert(gesture.location(in:self),from:layer),rect=layerPlayer.videoRect
        guard rect.width>0,rect.height>0,rect.contains(point) else { onPointOutside?();return }
        let location=gesture.location(in:self),marker=UIView(frame:CGRect(x:location.x-15,y:location.y-15,width:30,height:30))
        marker.isUserInteractionEnabled=false;marker.layer.cornerRadius=15;marker.layer.borderWidth=2;marker.layer.borderColor=UIColor.white.cgColor;addSubview(marker)
        UIView.animate(withDuration:0.4,delay:0.15,options:[]) { marker.alpha=0 } completion: { _ in marker.removeFromSuperview() }
        onPointTap(CGPoint(x:(point.x-rect.minX)/rect.width,y:(point.y-rect.minY)/rect.height))
    }
    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        if positionCaption(gesture, pinching: false) { return }
        if onBackgroundGesture != nil {positionBackground(gesture);return}
        guard gesture.numberOfTouches == 1, pinch.numberOfTouches < 2 else { panNeedsAnchor = true; return }
        let translation = gesture.translation(in: self)
        if gesture.state == .began || panNeedsAnchor { panOffset = offset; panOrigin = translation; panNeedsAnchor = false }
        offset = CGPoint(x: panOffset.x + translation.x - panOrigin.x, y: panOffset.y + translation.y - panOrigin.y); updatePicture()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

final class ImportedPhotoMedia: Transferable, Sendable {
    let url: URL
    let originalName: String
    let isPhoto: Bool
    private init(url: URL, originalName: String, isPhoto: Bool) {
        self.url = url; self.originalName = originalName; self.isPhoto = isPhoto
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    // The provider can finish a copy after cancellation. Own it until the
    // consumer finishes, and sweep interrupted transfers on the next use.
    private static let transferDirectory: URL = {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("YouRecPhotoTransfers", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        return folder
    }()
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            try await copy(received.file, isPhoto: false)
        }
        FileRepresentation(importedContentType: .image) { received in
            try await copy(received.file, isPhoto: true)
        }
    }

    private static func copy(_ source: URL, isPhoto: Bool) async throws -> ImportedPhotoMedia {
        let ext = source.pathExtension.lowercased()
        try FileManager.default.createDirectory(at: transferDirectory, withIntermediateDirectories: true)
        let url = transferDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(isPhoto || ["mp4", "m4v"].contains(ext) ? ext : "mov")
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let free = (try FileManager.default.attributesOfFileSystem(forPath: transferDirectory.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        guard free > Int64(size) + 256_000_000 else { throw CocoaError(.fileWriteOutOfSpace) }
        do {
            try await ProjectArchive.copyFile(source, to: url) { _ in }
            try Task.checkCancellation()
            return ImportedPhotoMedia(url: url, originalName: source.lastPathComponent, isPhoto: isPhoto)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}

// An explicit second tap confirms removal; a long press itself never edits data.
private struct EffectRemovalBubble:View {
    let title:String
    let symbol:String
    let tint:Color
    let identifier:String
    let armed:Bool
    let edit:()->Void
    let arm:()->Void
    let cancel:()->Void
    let remove:()->Void
    private var label:some View {Label(title,systemImage:symbol).lineLimit(1).frame(maxWidth:180).padding(.horizontal,12).frame(minHeight:48)}
    var body:some View {
        Group {
            if armed {
                HStack(spacing:0) {
                    label
                    Button(action:remove) {Image(systemName:"trash.fill").frame(width:44,height:48)}
                        .foregroundStyle(.red).accessibilityLabel("Remove "+title).accessibilityIdentifier("effect.confirmRemove")
                    Button(action:cancel) {Image(systemName:"xmark").frame(width:44,height:48)}
                        .accessibilityLabel("Cancel removal").accessibilityIdentifier("effect.cancelRemove")
                }.accessibilityElement(children:.contain)
            } else {
                label.contentShape(Capsule())
                    .gesture(LongPressGesture(minimumDuration:0.5).exclusively(before:TapGesture()).onEnded {value in
                        switch value {case .first(true):arm();case .second:edit();default:break}
                    })
                    .accessibilityElement(children:.ignore).accessibilityLabel("Edit "+title).accessibilityAddTraits(.isButton)
                    .accessibilityHint("Touch and hold for removal controls")
                    .accessibilityAction {edit()}.accessibilityAction(named:"Remove") {arm()}
                    .accessibilityIdentifier(identifier)
            }
        }.foregroundStyle(tint).background(tint.opacity(armed ? 0.22 : 0.12),in:Capsule())
    }
}

private struct EditorActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(enabled ? (configuration.isPressed ? 0.65 : 1) : 0.35)
    }
}

/// Tools with draggable content need an explicit inspection mode: the same
/// pinch cannot resize an export element and inspect the video at once.
struct InspectPreview<Content: View>: View {
    var canvas: CGSize
    var editsContent = true
    @ViewBuilder var content: () -> Content
    @State private var inspecting = false
    @State private var zoom: CGFloat = 1
    @State private var offset = CGSize.zero
    @State private var pinchStart: (CGFloat, CGSize)?
    @State private var dragStart: CGSize?
    private var active: Bool { inspecting || !editsContent }
    var body: some View {
        GeometryReader { geometry in
            let fit = AVMakeRect(aspectRatio: canvas, insideRect: CGRect(origin: .zero, size: geometry.size)).size
            ZStack(alignment: .bottomTrailing) {
                content().frame(width: geometry.size.width, height: geometry.size.height)
                    .scaleEffect(zoom).offset(offset).allowsHitTesting(!active)
                if active {
                    Color.clear.contentShape(Rectangle()).accessibilityLabel("Inspect tool preview")
                        .accessibilityIdentifier("tool.preview.inspection")
                        .accessibilityValue(String(format: "%.2f× view", zoom))
                        .gesture(MagnifyGesture().onChanged { value in
                            if pinchStart == nil { pinchStart = (zoom, offset) }
                            let start = pinchStart!, next = min(8, max(1, start.0 * value.magnification)), ratio = next / start.0
                            let anchor = CGSize(width: (value.startAnchor.x - 0.5) * geometry.size.width, height: (value.startAnchor.y - 0.5) * geometry.size.height)
                            zoom = next
                            offset = constrained(CGSize(width: anchor.width - (anchor.width - start.1.width) * ratio, height: anchor.height - (anchor.height - start.1.height) * ratio), fit: fit, viewport: geometry.size)
                        }.onEnded { _ in pinchStart = nil })
                        .simultaneousGesture(DragGesture(minimumDistance: 2).onChanged { value in
                            guard pinchStart == nil else { dragStart = nil; return }
                            if dragStart == nil { dragStart = offset }
                            offset = constrained(CGSize(width: dragStart!.width + value.translation.width, height: dragStart!.height + value.translation.height), fit: fit, viewport: geometry.size)
                        }.onEnded { _ in dragStart = nil })
                        .accessibilityAction(named: "Zoom in preview") { zoom = min(8, zoom * 1.5) }
                        .accessibilityAction(named: "Zoom out preview") { zoom = max(1, zoom / 1.5); offset = constrained(offset, fit: fit, viewport: geometry.size) }
                }
                HStack(spacing: 6) {
                    if zoom > 1.001 {
                        Button { reset() } label: { Image(systemName: "arrow.down.right.and.arrow.up.left").frame(width: 44, height: 44) }
                            .accessibilityLabel("Reset preview zoom").accessibilityIdentifier("tool.preview.resetZoom")
                    }
                    if editsContent {
                        Button { reset(); inspecting.toggle() } label: {
                            Label(inspecting ? "Edit" : "Inspect", systemImage: inspecting ? "hand.draw" : "plus.magnifyingglass").font(.caption.weight(.semibold)).padding(.horizontal, 12).frame(height: 44)
                        }.accessibilityLabel(inspecting ? "Resume editing preview" : "Inspect preview").accessibilityIdentifier("tool.preview.inspect")
                    }
                }.foregroundStyle(.white).background(.black.opacity(0.75), in: Capsule()).padding(8)
            }.clipped().onChange(of: geometry.size) { _, _ in reset() }.onChange(of: canvas) { _, _ in reset() }
        }
    }
    private func constrained(_ value: CGSize, fit: CGSize, viewport: CGSize) -> CGSize {
        let x = max(0, (fit.width * zoom - viewport.width) / 2), y = max(0, (fit.height * zoom - viewport.height) / 2)
        return CGSize(width: min(x, max(-x, value.width)), height: min(y, max(-y, value.height)))
    }
    private func reset() { zoom = 1; offset = .zero; pinchStart = nil; dragStart = nil }
}
