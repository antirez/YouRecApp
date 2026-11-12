import SwiftUI
import AVKit
import UniformTypeIdentifiers

private let accent = Color(red: 1, green: 0.25, blue: 0.29)
private let surface = Color(red: 0.09, green: 0.10, blue: 0.13)

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = ProjectStore()
    @StateObject private var camera = CaptureController()
    @State private var screen = 0
    @State private var wasBackgrounded = false
    @State private var importing = false
    @State private var repairFeedback: String?
    @State private var repairing: Project?
    @State private var relinkSource: SourceMedia?
    @State private var relinkPicker = false
    @State private var privacyPolicy = false
    @State private var unverifiedRelink: URL?
    @State private var duplicatedProjectID: UUID?
    @State private var renaming: Project?
    @State private var renamedTitle = ""
    @State private var showingDeleted = false
    @State private var erasing: Project?
    @State private var expiredDeletions: [ProjectDeletion] = []
    @State private var showingExpiredDeletionPrompt = false
    @State private var insertingRecording = false
    @State private var insertionHasStarted = false
    @State private var startupRecoveryComplete = false
    @State private var recoveryProject: Project?
    @State private var recoveryDeletion: URL?
    private struct ProjectTarget: Identifiable { let id: UUID }
    @State private var originals: ProjectTarget?
    @State private var exportingProject: ProjectTarget?

    var body: some View {
        Group {
            if screen == 0 {
                RecorderView(camera: camera, project: store.selected, start: startRecording, startNewProject: startNewProject,
                             openProjects: { if insertingRecording { finishInsertion() } else { screen = 1 } },
                             openEditor: editFromRecorder,
                             insertionPosition: insertingRecording ? store.selected?.recordingInsertion : nil)
            } else if screen == 2, let project = store.selected {
                EditorView(store: store, projectID: project.id, back: { screen = 1 }, recordHere: { position, site in
                    camera.finishPausedTake()
                    guard store.update(project.id, { $0.beginRecordingInsertion(at: position, site: site) }) else { return }
                    insertionHasStarted = false; insertingRecording = true; screen = 0
                }).id(project.id)
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Text("you").foregroundStyle(.white) + Text("rec").foregroundStyle(accent)
                        Spacer()
                        Text(screen == 1 ? "PROJECTS" : "EDITOR")
                            .font(.caption.monospaced().weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .font(.system(size: 29, weight: .heavy, design: .rounded))
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    if screen == 1 { projectList }
                    else {
                        ContentUnavailableView("Choose a project", systemImage: "film.stack",
                                               description: Text("Record a take or import a video to begin editing."))
                    }
                    Divider()
                    HStack {
                        destination("Record", "record.circle", 0)
                        destination("Projects", "square.stack", 1)
                        destination("Edit", "slider.horizontal.3", 2)
                    }
                    .padding(.top, 8).padding(.bottom, 4).background(surface)
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !store.unsavedDrafts.isEmpty {
                HStack {
                    VStack(alignment: .leading) {
                        Label("Changes not saved", systemImage: "exclamationmark.triangle.fill")
                        if !Set(store.unsavedDrafts.keys).isSubset(of: store.journaledDrafts) {
                            Text("Keep YouRec open. New edits are only in memory.").font(.footnote)
                        }
                    }
                    Spacer(); Button("Retry save") { store.retrySaves() }
                }.padding(10).background(.bar).foregroundStyle(.orange).accessibilityIdentifier("recovery.unsaved")
            } else if !camera.hasActiveTake, let id = store.recoveryMessages.keys.sorted(by: { $0.uuidString < $1.uuidString }).first,
                      let message = store.recoveryMessages[id] {
                HStack {
                    Text(message).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
                    Button("Review") { originals = ProjectTarget(id: id) }
                    Button { store.recoveryMessages[id] = nil } label: { Image(systemName: "xmark").frame(minWidth: 44, minHeight: 44) }
                        .accessibilityLabel("Dismiss recovery notice")
                }.padding(.horizontal, 12).background(.bar)
            }
        }
        .sheet(item: $exportingProject) { project in
            CatalogueMovieExport(store: store, projectID: project.id)
        }
        .sheet(item: $originals) { value in OriginalRecordingsView(store: store, projectID: value.id) }
        .background(Color(red: 0.035, green: 0.04, blue: 0.055))
        .tint(accent)
        .onChange(of: screen == 0 && scenePhase == .active, initial: true) { _, visible in
            RecordingAppDelegate.keepAwake("camera-screen", active: visible)
        }
        .onDisappear { RecordingAppDelegate.keepAwake("camera-screen", active: false) }
        .task {
            #if DEBUG
            if CommandLine.arguments.contains("--retire-archived-camera-test") { await AudioDiagnostics.retireArchivedCameraTest(); return }
            if CommandLine.arguments.contains("--retention-ui-fixture") { screen = 1; return }
            if CommandLine.arguments.contains("--night-fix-cleanup") {NightFixDiagnostics.cleanup();return}
            if CommandLine.arguments.contains("--night-fix-selftest") {await NightFixDiagnostics.run();return}
            if CommandLine.arguments.contains("--color-correction-selftest") { await VideoEffectsDiagnostics.colorCorrection(); return }
            if CommandLine.arguments.contains("--log-recovery-selftest") { await VideoEffectsDiagnostics.logRecovery(); return }
            if CommandLine.arguments.contains("--video-effects-selftest") { await VideoEffectsDiagnostics.run(camera); return }
            if CommandLine.arguments.contains("--live-mask-selftest") { await VideoEffectsDiagnostics.liveMaskPairing(); return }
            if CommandLine.arguments.contains("--dual-capture-selftest") { await CaptureDiagnostics.dual(camera); return }
            if CommandLine.arguments.contains("--dual-assist-selftest") { await CaptureDiagnostics.dual(camera, assists: true); return }
            if CommandLine.arguments.contains("--color-selftest") { await CaptureDiagnostics.color(camera); return }
            if CommandLine.arguments.contains("--capture-reset-selftest") { await CaptureDiagnostics.previewReset(camera); return }
            if CommandLine.arguments.contains("--front-landscape-selftest") { await CaptureDiagnostics.frontLandscape(camera); return }
            if CommandLine.arguments.contains("--transitions-selftest") { await TransitionDiagnostics.run(); return }
            if CommandLine.arguments.contains("--pauses-selftest") { await PausesDiagnostics.run(); return }
            if CommandLine.arguments.contains("--tools-selftest") { await EditorToolsDiagnostics.run(); return }
            if CommandLine.arguments.contains("--crop-selftest") { await CropDiagnostics.run(); return }
            if CommandLine.arguments.contains("--stabilization-selftest") { await StabilizationDiagnostics.run(); return }
            if CommandLine.arguments.contains("--diagnostics-cleanup") { await AudioDiagnostics.cleanup(); return }
            if CommandLine.arguments.contains("--restore-development-backup") { AudioDiagnostics.restoreDevelopmentBackup(); return }
            if CommandLine.arguments.contains("--editor-selftest") { await EditorDiagnostics.run(); return }
            if CommandLine.arguments.contains("--effect-animation-selftest") { await runEffectAnimationDiagnostics(); return }
            if CommandLine.arguments.contains("--tracks-selftest") { await EditorDiagnostics.independentTracks(); return }
            if CommandLine.arguments.contains("--recording-history-selftest") { await EditorDiagnostics.recordingHistory(); return }
            if CommandLine.arguments.contains("--audio-comparison-selftest") { await EditorDiagnostics.comparison(); return }
            if CommandLine.arguments.contains("--gain-reset-checks") { await AudioDiagnostics.gainResetChecks(); return }
            if CommandLine.arguments.contains("--audio-import-censor-checks") { await AudioToolsDiagnostics.run(); return }
            if CommandLine.arguments.contains("--audio-gain-checks") { await AudioDiagnostics.gainChecks(); return }
            if CommandLine.arguments.contains("--audio-resume-selftest") { await AudioDiagnostics.resume(); return }
            if CommandLine.arguments.contains("--audio-deepfilter-selftest") { await AudioDiagnostics.run(deepFilter: true); return }
            if CommandLine.arguments.contains("--audio-deepfilter-stress") { await AudioDiagnostics.run(stress: true, deepFilter: true); return }
            if CommandLine.arguments.contains("--audio-stress") { await AudioDiagnostics.run(stress: true); return }
            if CommandLine.arguments.contains("--subtitle-selftest") { await SubtitleDiagnostics.run(); return }
            if CommandLine.arguments.contains("--studio-restoration-selftest") { await AudioDiagnostics.run(studioRestoration: true); return }
            if CommandLine.arguments.contains("--audio-selftest") { await AudioDiagnostics.run(); return }
            if CommandLine.arguments.contains("--capture-selftest") { await CaptureDiagnostics.run(camera); return }
            if CommandLine.arguments.contains("--capture-review-selftest") { await CaptureDiagnostics.reviewLifecycle(camera); return }
            if CommandLine.arguments.contains("--recorder-polish-selftest") { await CaptureDiagnostics.recorderPolish(camera); return }
            if CommandLine.arguments.contains("--zoom-selftest") { await CaptureDiagnostics.zoom(camera); return }
            if CommandLine.arguments.contains("--capture-stress") { await CaptureDiagnostics.stress(camera); return }
            if CommandLine.arguments.contains("--editor-preview") {
                let mixedCanvas = CommandLine.arguments.contains("--mixed-canvas-fixture")
                let logFixture=CommandLine.arguments.contains("--log-recovery-ui-fixture")
                let depthFixture=CommandLine.arguments.contains("--depth-ui-fixture")
                let speechFixture = CommandLine.arguments.contains("--speech-waveform-fixture")
                let subtitleSpeech = CommandLine.arguments.contains("--subtitle-speech-fixture")
                let fixtureTitle=ProcessInfo.processInfo.environment["YOUREC_EDITOR_FIXTURE_TITLE"] ?? (logFixture ? "Log recovery · UI test" : subtitleSpeech ? "Subtitle speech · UI test" : speechFixture ? "Speech waveform · UI test — SDR picture, original audio" : depthFixture ? "Cinematic depth · UI test" : "Studio notes · UI test")
                let documents=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
                let fixture=logFixture ? documents.appendingPathComponent("LogRecoveryQA/input.mov") : subtitleSpeech ? documents.appendingPathComponent("SubtitlesQA/input.mov") : speechFixture ? documents.appendingPathComponent("speech-waveform.mov") : depthFixture ? documents.appendingPathComponent("depth-ui-fixture.mov") : Bundle.main.url(forResource:"editor-fixture",withExtension:"mp4") ?? documents.appendingPathComponent("editor-fixture.mp4")
                if let existing = store.projects.first(where: { $0.title == fixtureTitle }) {
                    store.select(existing.id)
                    if CommandLine.arguments.contains("--reset-ui-fixture") {
                        store.update(existing.id) { value in
                            // Auxiliary media imported by a prior UI scenario must not
                            // become extra footage when resetting the base fixture.
                            value.history = [EditState(clips: value.sources.prefix(mixedCanvas ? 2 : 1).map { TimelineClip(sourceID: $0.id, start: 0, end: $0.duration) })]
                            value.historyCursor = 0; value.updatedAt = Date()
                            value.exportSettings = ExportSettings()
                        }
                    }
                }
                else if FileManager.default.fileExists(atPath: fixture.path) {
                    if CommandLine.arguments.contains("--long-stabilization-ui") {
                        do { try await EditorDiagnostics.importLongStabilizationFixture(fixture, documents: documents, store: store) }
                        catch { store.error = error.localizedDescription }
                    } else { await store.importVideo(fixture) }
                    if let id = store.selectedID { store.update(id) { $0.title = fixtureTitle } }
                }
                if mixedCanvas, let project = store.selected, project.sources.count == 1 {
                    do { try await EditorDiagnostics.appendLandscapeFixture(to: project, store: store) }
                    catch { store.error = error.localizedDescription }
                }
                let backgroundFillFixture = CommandLine.arguments.contains("--background-fill-export-fixture")
                if backgroundFillFixture || CommandLine.arguments.contains("--background-export-fixture"), let project = store.selected,
                   project.edit.clips.first?.videoEffects?.contains(where: { $0.kind == .autoBackground }) != true {
                    store.update(project.id) { project in
                        var edit = project.edit
                        for i in edit.clips.indices {
                            edit.clips[i].videoEffects = [VideoEffectSettings(.autoBackground, start: edit.clips[i].start, end: edit.clips[i].end)]
                            if backgroundFillFixture { edit.clips[i].crop = CropSettings() }
                        }
                        if backgroundFillFixture { edit.outputSize = CGSize(width: 360, height: 360) }
                        project.commit(edit)
                    }
                }
                if CommandLine.arguments.contains("--long-title-ui-fixture"), let id = store.selectedID {
                    store.update(id) { project in
                        guard let source = project.sources.first else { return }
                        let clips = (0..<4).map { _ in TimelineClip(sourceID: source.id, start: 0, end: source.duration) }
                        project.history = [EditState(clips: clips)]; project.historyCursor = 0
                    }
                }
                if CommandLine.arguments.contains("--frame-clock-fixture"), let id = store.selectedID {
                    store.update(id) { project in
                        var edit = project.edit
                        for index in edit.clips.indices {
                            let clip = edit.clips[index]
                            edit.clips[index].texts = (0..<Int(ceil(clip.end * 10))).map { tick in
                                TextOverlay(text: String(format: "%.1f s", Double(tick) / 10), start: Double(tick) / 10,
                                            end: Double(tick + 1) / 10, x: 0.5, y: 0.5, size: 0.12, style: .box, color: .white)
                            }
                        }
                        project.commit(edit)
                    }
                }
                if CommandLine.arguments.contains("--subtitles-ui-fixture"), CommandLine.arguments.contains("--reset-ui-fixture"), let id = store.selectedID {
                    store.update(id) { project in
                        var edit = project.edit
                        let words = SubtitleTiming.estimate(CommandLine.arguments.contains("--long-subtitles-ui-fixture") ? (1...100).map { "Sentence \($0) is part of a long transcript." }.joined(separator: " ") : "This is the opening sentence. We can correct these words. Captions follow the spoken audio. Change the style while watching. Short phrases are easy to read. The final sentence ends here.", speech: [0.4...max(0.5, edit.duration - 0.4)])
                        edit.timeline.installSubtitles(words, range: 0...edit.duration, language: "English")
                        project.commit(edit)
                    }
                }
                if CommandLine.arguments.contains("--multiselect-fixture") || CommandLine.arguments.contains("--link-intersection-fixture"), let id = store.selectedID {
                    store.update(id) { project in
                        var edit = project.edit
                        if CommandLine.arguments.contains("--link-intersection-fixture") {
                            edit.timeline.unlink(edit.timeline.entireSelection())
                            edit.timeline.split(at: EditTime(6), selection: TimelineSelection(video: Set(edit.timeline.video.map(\.id))))
                            edit.timeline.split(at: EditTime(12), selection: TimelineSelection(video: Set(edit.timeline.video.map(\.id))))
                            edit.timeline.move(TimelineSelection(audio: Set(edit.timeline.audio.map(\.id))), by: EditTime(3))
                        } else {
                            edit.timeline.split(at: EditTime(6), selection: edit.timeline.entireSelection())
                            let cut = CommandLine.arguments.contains("--fractional-snap-fixture") ? EditTime(ticks: 12 * EditTime.scale + 1) : EditTime(12)
                            edit.timeline.split(at: cut, selection: edit.timeline.entireSelection())
                            if CommandLine.arguments.contains("--close-move-cuts-fixture"), let last = edit.timeline.video.last {
                                edit.timeline.move(edit.timeline.selection(of: last.id), by: EditTime(ticks: 1))
                            } else if CommandLine.arguments.contains("--move-snap-fixture"), let last = edit.timeline.video.last {
                                edit.timeline.move(edit.timeline.selection(of: last.id), by: EditTime(2))
                            }
                        }
                        project.commit(edit)
                    }
                }
                if CommandLine.arguments.contains("--export-audio-warning-fixture"), let id = store.selectedID {
                    store.update(id) { project in
                        var edit = project.edit
                        edit.timeline.enhance([AudioEffect(kind: .gain, amount: 12), AudioEffect(kind: .gain, amount: 12)], selection: edit.timeline.entireSelection())
                        project.commit(edit)
                    }
                }
                if CommandLine.arguments.contains("--navigation-fixture"), let id = store.selectedID {
                    store.update(id) { project in
                        var edit = project.edit
                        var title = TextOverlay(text: "A title"); title.start = 8; title.end = 10
                        edit.timeline.video[0].content.texts = [title]
                        var eq = AudioEffect.make(.equalizer); eq.amount = 2
                        edit.timeline.enhance([eq], selection: edit.timeline.entireSelection())
                        edit.timeline.split(at: EditTime(6), selection: edit.timeline.entireSelection())
                        edit.timeline.split(at: EditTime(12), selection: edit.timeline.entireSelection())
                        project.commit(edit)
                    }
                }
                if CommandLine.arguments.contains("--one-frame-fixture"), let id = store.selectedID {
                    store.update(id) { project in
                        var edit = project.edit
                        edit.timeline.split(at: EditTime(1.0/30), selection: edit.timeline.entireSelection())
                        project.commit(edit)
                    }
                }
                if CommandLine.arguments.contains("--tracks-overlap-fixture"), let id = store.selectedID {
                    store.update(id) { project in
                        var edit = project.edit
                        edit.timeline.split(at: EditTime(9), selection: edit.timeline.entireSelection())
                        edit.timeline.unlink(edit.timeline.entireSelection())
                        if let second = edit.timeline.video.last {
                            edit.timeline.move(TimelineSelection(video: [second.id]), by: EditTime(-4.5))
                            let copy = edit.timeline.copied(TimelineSelection(video: [second.id], range: EditInterval(5...8)))
                            _ = edit.timeline.paste(copy, at: EditTime(5))
                        }
                        project.commit(edit)
                    }
                }
                if CommandLine.arguments.contains("--effect-refinement-fixture"),let id=store.selectedID {
                    store.update(id) {project in
                        guard let original=project.edit.clips.first else {return}
                        var effect=VideoEffectSettings(.quantization,start:original.start,end:original.end)
                        effect.set("faceDetail",.toggle(false))
                        // Each test launch needs an uncached palette plan.
                        effect.set("colors",.number(6))
                        var edit=project.edit
                        edit.clips=(0..<4).map {_ in var clip=original;clip.id=UUID();clip.videoEffects=[effect];return clip}
                        project.commit(edit)
                    }
                    if let project=store.selected {
                        let cache=ProjectCacheLocation.root(in:store.folder(project),preferred:"cache")
                        for file in (try? FileManager.default.contentsOfDirectory(at:cache,includingPropertiesForKeys:nil)) ?? [] where file.lastPathComponent.hasPrefix("palette-") {try? FileManager.default.removeItem(at:file)}
                    }
                }
                if CommandLine.arguments.contains("--missing-image-fixture"), let id = store.selectedID {
                    store.update(id) { project in
                        var edit = project.edit
                        if !edit.clips.isEmpty {
                            let clip = edit.clips[0]
                            edit.clips[0].images = [ImageOverlay(filename: "image-missing-fixture.png", start: clip.start, end: min(clip.end, clip.start + 3))]
                            project.commit(edit)
                        }
                    }
                }
                if CommandLine.arguments.contains("--background-position-fixture"),let id=store.selectedID {
                    store.update(id) { project in
                        var edit=project.edit
                        if let first=edit.clips.first,let source=project.sources.first(where:{$0.id==first.sourceID}) {
                            var background=VideoEffectSettings(.chromaKey,start:first.start,end:first.end)
                            let name="effect-position-fixture.mov",folder=store.folder(project)
                            if !FileManager.default.fileExists(atPath:folder.appendingPathComponent(name).path) {try? FileManager.default.copyItem(at:folder.appendingPathComponent(source.filename),to:folder.appendingPathComponent(name))}
                            background.set("personHint",.toggle(false));background.set("background",.choice("Video"));background.set("media",.media(name))
                            background.set("backgroundZoom",.number(2));background.set("strength",.number(2))
                            edit.clips[0].videoEffects=[background];project.commit(edit)
                        }
                    }
                }
                if CommandLine.arguments.contains("--broken-recovery-fixture"), CommandLine.arguments.contains("--reset-ui-fixture"), let project = store.selected {
                    try? FileManager.default.removeItem(at: store.folder(project).appendingPathComponent("Recovery", isDirectory: true))
                    let file = store.folder(project).appendingPathComponent("1790000000000-interrupted.mov")
                    if CommandLine.arguments.contains("--invalid-recipe-recovery-fixture"), let source = project.sources.first {
                        try? FileManager.default.copyItem(at: store.mediaURL(project, source), to: file)
                        try? Data("{".utf8).write(to: file.deletingPathExtension().appendingPathExtension("effects.json"))
                    } else { try? Data("unfinished movie".utf8).write(to: file) }
                    try? Data("[]".utf8).write(to: file.deletingPathExtension().appendingPathExtension("events.json"))
                }
                if CommandLine.arguments.contains("--recovery-ui-check") { await store.recoverUnindexedRecordings() }
                if let selected = store.selected {
                    if CommandLine.arguments.contains("--recovery-save-fault") {
                        try? Data().write(to: store.folder(selected).appendingPathComponent(".test-fail-next-save"))
                    }
                    if CommandLine.arguments.contains("--recovery-full-export") {
                        try? Data().write(to: store.folder(selected).appendingPathComponent(".test-full-export"))
                    }
                }
                screen = 2; return
            }
            #endif
            if store.projects.isEmpty { _ = store.create() }
            camera.onSegment = { url, completion in
                // A take belongs to the project folder the writer opened, even
                // if the user has since chosen another recording destination.
                guard let id = UUID(uuidString: url.deletingLastPathComponent().lastPathComponent) else { completion(false); return }
                Task { completion(await store.addRecording(url, to: id)) }
            }
            #if targetEnvironment(simulator)
            if CommandLine.arguments.contains("--layout-preview") { return }
            #endif
            startupRecoveryComplete = true
            if screen == 0, !camera.hasActiveTake, let project = store.selected,
               (ExportCheckpoint(folder: store.folder(project)).matches(project) || EffectApplicationReceipt.pending(for: project, in: store.folder(project)) != nil) { screen = 2 }
            // Recovery can outlive the initial scene-phase value captured by
            // this task. Query the current application state after awaiting it.
            if screen == 0 && UIApplication.shared.applicationState == .active { camera.prepare() }
            await store.recoverUnindexedRecordings()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in
            store.retryUnavailableProjects()
            if startupRecoveryComplete { Task { if !camera.hasActiveTake { await store.recoverUnindexedRecordings() } } }
        }
        .onChange(of: scenePhase) { _, phase in
            if (phase == .active || phase == .background) && !store.unsavedDrafts.isEmpty { store.retrySaves() }
            if phase == .background && camera.hasActiveTake { RecordingAppDelegate.protectPendingSave() }
            if phase == .background { wasBackgrounded = true; camera.suspend() }
            else if phase == .active && screen == 0 && startupRecoveryComplete {
                #if DEBUG
                if CommandLine.arguments.contains("--video-effects-depth-only") || CommandLine.arguments.contains("--video-effects-cinematic-only") || CommandLine.arguments.contains("--video-effects-depth-import-only") || CommandLine.arguments.contains("--video-effects-matting-only") {return}
                if CommandLine.arguments.contains("--editor-preview") || CommandLine.arguments.contains("--layout-preview") { return }
                #endif
                camera.prepare()
            }
            else if phase == .active && wasBackgrounded && screen != 0 { camera.suspend(forPlayback: true) }
            if phase == .active { wasBackgrounded = false }
        }
        .onChange(of: camera.hasActiveTake) { _, active in
            RecordingAppDelegate.keepAwake("recording", active: active)
            if !active { RecordingAppDelegate.finishedPendingSave() }
        }
        .onChange(of: camera.state) { old, value in
            if insertingRecording && insertionHasStarted && value == .idle && old != .idle { finishInsertion() }
        }
        .onChange(of: store.selectedID) { _, _ in camera.finishPausedTake() }
        .onChange(of: screen) { _, value in
            if value == 0 { if startupRecoveryComplete { camera.prepare() } } else { camera.suspend(forPlayback: true) }
        }
        .alert("YouRec", isPresented: Binding(get: { store.error != nil || camera.error != nil }, set: { if !$0 { store.error = nil; camera.error = nil } })) {
            if !store.unsavedDrafts.isEmpty { Button("Retry save") { store.retrySaves() } }
            Button("OK") { store.error = nil; camera.error = nil }
        } message: { Text(store.error ?? camera.error ?? "") }
        .sheet(item: $recoveryProject) { project in
            NavigationStack {
                List {
                    Section {
                        ForEach(store.disk.recoveryFiles(in: project), id: \.self) { file in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(file.lastPathComponent).font(.caption).lineLimit(2)
                                HStack {
                                    ShareLink("Save file", item: file)
                                    Spacer()
                                    Button("Delete", role: .destructive) { recoveryDeletion = file }
                                        .accessibilityIdentifier("recovery.delete." + file.lastPathComponent)
                                }
                            }
                        }
                    } header: { Text("Preserved files") } footer: {
                        Text("These takes could not be restored automatically. Save a copy for recovery, or delete the unfinished file. Your project and its edits are unchanged.")
                    }
                }.navigationTitle("Unfinished recordings").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { recoveryProject = nil } } }
                    .confirmationDialog("Permanently delete this unfinished recording and its sidecars?", isPresented: Binding(get: { recoveryDeletion != nil }, set: { if !$0 { recoveryDeletion = nil } }), titleVisibility: .visible) {
                        if let file = recoveryDeletion {
                            Button("Delete recording", role: .destructive) { store.removeRecoveryFile(file, project: project); recoveryDeletion = nil }
                        }
                        Button("Cancel", role: .cancel) { recoveryDeletion = nil }
                    }
            }
        }
        .sheet(isPresented: Binding(get: { store.archiveURL != nil }, set: { if !$0 { store.dismissArchive() } })) {
            NavigationStack {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Your project ZIP is ready.").font(.title2.bold())
                    Text("Import this ZIP in YouRec to restore the originals, edits, and undo history. For DaVinci Resolve, unzip it and import the .otio timeline beside the media. Cuts and tracks are editable. YouRec effects, audio mixes, and custom transitions can be recreated in the other editor.")
                    if let url = store.archiveURL { ShareLink(item: url) { Label("Save or share ZIP", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity, minHeight: 48) }.buttonStyle(.borderedProminent) }
                }.padding(24).navigationTitle("Zip project").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { store.dismissArchive() } } }
            }.presentationDetents([.medium])
        }
        .sheet(isPresented: $privacyPolicy) {
            NavigationStack {
                PrivacyPolicyView().toolbar { ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { privacyPolicy = false }
                } }
            }
        }
        .sheet(item: $repairing) { project in
            NavigationStack {
                List {
                    Section {
                        Text("Choose each unchanged original video or audio file. Cuts and undo/redo history will stay in place.").foregroundStyle(.secondary)
                    }
                    ForEach(store.missingSources(store.projects.first(where: { $0.id == project.id }) ?? project)) { source in
                        VStack(alignment: .leading, spacing: 8) {
                            let number = (project.sources.firstIndex(where: { $0.id == source.id }) ?? 0) + 1
                            Text("Take \(number) · \(source.recordedAt.formatted(date: .abbreviated, time: .shortened))").font(.subheadline)
                            let timeline = (store.projects.first { $0.id == project.id } ?? project).edit.timeline
                            let uses = timeline.video.enumerated().filter { $0.element.content.sourceID == source.id }.map { "V" + String($0.offset + 1) }
                                + timeline.audio.enumerated().filter { $0.element.sourceID == source.id }.map { "♪" + String($0.offset + 1) }
                            Text(timeLabel(source.duration) + " · " + (uses.isEmpty ? "Kept in editing history" : "On timeline: " + uses.joined(separator: ", ")))
                                .font(.caption).foregroundStyle(.secondary)
                            DisclosureGroup("File details") { Text(source.filename).font(.caption.monospaced()).textSelection(.enabled) }
                            Button("Locate original…") { relinkSource = source; relinkPicker = true }.disabled(store.importing)
                        }
                    }
                    let current = store.projects.first(where: { $0.id == project.id }) ?? project
                    let missing = Set(store.missingSources(current).map(\.id))
                    let affected = current.edit.timeline.items(usingSources: missing)
                    if !affected.isEmpty {
                        Section {
                            Button("Remove missing takes from timeline") {
                                var edit = current.edit
                                edit.timeline.remove(affected)
                                if store.commit(project.id, edit) { repairFeedback = "Removed from timeline · Undo in the editor" }
                            }.disabled(store.importing)
                            Text("This is one undoable edit. All originals and previous edits stay in the project.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let repairFeedback { Text(repairFeedback).foregroundStyle(.secondary) }
                    if store.importing {
                        ProgressView(value: store.operationProgress) { Text(store.operationLabel) }
                        Button("Cancel") { store.cancelOperation() }
                    }
                }.navigationTitle("Repair media").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { repairing = nil }.disabled(store.importing) } }
                    .confirmationDialog("This older take has no saved fingerprint. Is the selected video its unchanged original?", isPresented: Binding(get: { unverifiedRelink != nil }, set: { if !$0 { unverifiedRelink = nil } }), titleVisibility: .visible) {
                        Button("Use this original") {
                            if let url = unverifiedRelink, let source = relinkSource { store.beginRelink(url, source: source, project: project, allowUnverified: true) }
                            unverifiedRelink = nil
                        }
                    }
                    .fileImporter(isPresented: $relinkPicker, allowedContentTypes: relinkSource?.audioOnly == true ? [.audio] : [.movie]) { result in
                        switch result {
                        case .success(let url): if let source = relinkSource {
                            if source.sha256 == nil { unverifiedRelink = url }
                            else { store.beginRelink(url, source: source, project: project) }
                        }
                        case .failure(let error): store.error = error.localizedDescription
                        }
                    }
            }.interactiveDismissDisabled(store.importing)
        }
        .sheet(item: $renaming) { project in
            NavigationStack {
                Form { TextField("Project name", text: $renamedTitle).textInputAutocapitalization(.sentences) }
                    .navigationTitle("Rename project").navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { renaming = nil } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") { store.rename(project, title: renamedTitle); renaming = nil }
                                .disabled(renamedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
            }.presentationDetents([.medium])
        }
        .sheet(isPresented: $showingDeleted) {
            NavigationStack {
                List {
                    Section { Text("Originals and editing history stay here until you permanently delete them.").font(.subheadline).foregroundStyle(.secondary) }
                    ForEach(store.deletedProjects) { project in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(project.title).font(.headline)
                            if let record = store.deletionRecords[project.id] {
                                Text((record.dateIsKnown ? "Deleted " : "Age tracked since ") + record.date.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption).foregroundStyle(.secondary)
                                if record.isOlderThan30Days(at: Date()) { Text("Over 30 days").font(.caption).foregroundStyle(.orange) }
                            } else {
                                Text("Deletion date unavailable · excluded from bulk cleanup").font(.caption).foregroundStyle(.secondary)
                            }
                            HStack {
                                Button("Restore") { store.restoreDeleted(project) }.buttonStyle(.bordered).accessibilityLabel("Restore " + project.title)
                                Spacer()
                                Button("Delete permanently", role: .destructive) { erasing = project }.buttonStyle(.bordered)
                            }
                        }.padding(.vertical, 6)
                    }
                }.navigationTitle("Recently deleted").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingDeleted = false } } }
                    .confirmationDialog("Permanently delete this project and its original takes?", isPresented: Binding(get: { erasing != nil }, set: { if !$0 { erasing = nil } }), titleVisibility: .visible) {
                        Button("Delete permanently", role: .destructive) { if let project = erasing { store.eraseDeleted(project) }; erasing = nil }
                    }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.movie, .zip], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { store.beginImport(url) }
            case .failure(let error): store.error = error.localizedDescription
            }
        }
    }
    private func destination(_ title: String, _ icon: String, _ index: Int) -> some View {
        Button { screen = index } label: {
            VStack(spacing: 4) { Image(systemName: icon).font(.title3); Text(title).font(.caption.weight(.medium)) }
                .frame(maxWidth: .infinity).frame(minHeight: 48)
                .foregroundStyle(screen == index ? accent : .secondary)
        }
        .disabled(camera.hasActiveTake || store.importing)
        .accessibilityAddTraits(screen == index ? .isSelected : [])
        .accessibilityIdentifier("catalogue.tab." + String(index))
    }
    private func finishInsertion() {
        guard !camera.hasActiveTake else { return }
        if let id = store.selectedID { store.update(id) { $0.recordingInsertion = nil; $0.recordingInsertionStep = nil } }
        insertingRecording = false; insertionHasStarted = false
        camera.finishPausedTake(); screen = 2
    }
    private func startRecording() {
        guard let project = store.selected ?? store.create() else { return }
        guard !store.recoveringIDs.contains(project.id) else {
            store.error = "Recovering the last take in this project. You can start a new project while it finishes."; return
        }
        if insertingRecording { insertionHasStarted = true }
        if store.unsavedDrafts[project.id] != nil {
            store.retrySaves()
            guard store.unsavedDrafts[project.id] == nil else { return }
        }
        do {
            let destination: TakeReceipt.Destination = insertingRecording ? .placement(try project.recordingPlacement()) : .append
            camera.start(in: store.folder(project), projectID: project.id, destination: destination)
        } catch { store.error = error.localizedDescription }
    }
    private func editFromRecorder() {
        guard !camera.hasActiveTake else { return }
        if insertingRecording { finishInsertion(); return }
        // The library can be empty after deleting its last project.
        guard store.selected != nil || store.create() != nil else { return }
        screen = 2
    }
    private func startNewProject() {
        guard !camera.hasActiveTake, !store.importing, !insertingRecording,
              store.selected?.hasSourceMedia == true, store.create() != nil else { return }
        UIAccessibility.post(notification: .announcement, argument: "New project ready to record")
    }
    private var projectList: some View {
        ScrollViewReader { reader in
            projectListContent.onChange(of: duplicatedProjectID) { _, id in
                if let id { reader.scrollTo(id, anchor: .top) }
            }
        }
    }
    private func projectActions(_ project: Project, canExport: Bool) -> some View {
        let record = Button { if store.select(project.id) { screen = 0 } } label: {
            Text("Continue recording").frame(minHeight: 44)
        }.buttonStyle(.borderedProminent)
        let edit = Button { if store.select(project.id) { screen = 2 } } label: {
            Label("Edit", systemImage: "slider.horizontal.3").frame(minHeight: 44)
        }.buttonStyle(.borderedProminent).tint(Color(red: 0.06, green: 0.35, blue: 0.72)).foregroundStyle(.white)
        let export = Button {
            if store.openProject(project.id) { exportingProject = ProjectTarget(id: project.id) }
        } label: {
            Image(systemName: "square.and.arrow.up").font(.body.weight(.semibold))
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .frame(width: 46, height: 46)
                .background(MovieExportPanel.buttonColor, in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).foregroundStyle(.white)
            .disabled(!canExport).opacity(canExport ? 1 : 0.35)
            .accessibilityLabel("Export video for " + project.title)
            .accessibilityHint(canExport ? "Open video export and sharing options." : "Add media to export this project.")
            .accessibilityIdentifier("project.export." + project.id.uuidString)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                record.fixedSize(horizontal: true, vertical: false)
                edit.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                export
            }
            VStack(alignment: .leading, spacing: 8) {
                record
                HStack { edit; Spacer(minLength: 8); export }
            }
        }
    }

    private var projectListContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Pick up where you left off.").font(.title2.bold())
                HStack {
                    Button { if store.create() != nil { screen = 0 } } label: { Label("New project", systemImage: "plus") }
                    Spacer()
                    Button { importing = true } label: { Label("Import", systemImage: "square.and.arrow.down") }
                }.buttonStyle(.bordered).disabled(store.importing)
                Button { privacyPolicy = true } label: {
                    Label("Privacy policy", systemImage: "hand.raised").font(.subheadline).frame(minHeight: 44)
                }
                ForEach(store.projects) { project in
                    let duration = project.edit.duration
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            ProjectThumbnail(url: project.sources.first.map { store.mediaURL(project, $0) })
                                .frame(width: 64, height: 56).clipShape(RoundedRectangle(cornerRadius: 8))
                            Button { renamedTitle = project.title; renaming = project } label: {
                                HStack(spacing: 6) {
                                    Text(project.title).font(.headline).lineLimit(2).multilineTextAlignment(.leading)
                                    Image(systemName: "pencil").font(.caption).foregroundStyle(.secondary)
                                }.frame(minHeight: 44, alignment: .leading)
                            }.buttonStyle(.plain).disabled(store.importing)
                                .accessibilityLabel("Rename " + project.title)
                            Spacer()
                            if store.selectedID == project.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                            Menu {
                                Button("Rename", systemImage: "pencil") { renamedTitle = project.title; renaming = project }
                                Button("Duplicate project", systemImage: "plus.square.on.square") {
                                    store.duplicate(project) { copy in
                                        duplicatedProjectID = copy.id
                                        UIAccessibility.post(notification: .announcement, argument: "Created " + copy.title)
                                    }
                                }
                                Button("Original recordings", systemImage: "film.stack") { originals = ProjectTarget(id: project.id) }
                                Button("Zip project", systemImage: "shippingbox") { store.archive(project) }
                                if !store.disk.recoveryFiles(in: project).isEmpty {
                                    Button("Unfinished recordings", systemImage: "exclamationmark.video") { recoveryProject = project }
                                }
                                Button("Move to Recently deleted", systemImage: "trash", role: .destructive) { store.moveToDeleted(project) }
                            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.disabled(store.importing).accessibilityLabel("Actions for " + project.title)
                        }
                        if !store.missingSources(project).isEmpty {
                            let missing = store.missingSources(project)
                            let affectsTimeline = !project.edit.timeline.items(usingSources: Set(missing.map(\.id))).isEmpty
                            Button { repairFeedback = nil; repairing = project } label: {
                                Label(affectsTimeline ? "Repair media · \(missing.count) missing" : "\(missing.count) missing from history", systemImage: affectsTimeline ? "exclamationmark.triangle" : "info.circle")
                                    .foregroundStyle(affectsTimeline ? Color.orange : Color.secondary)
                            }
                        }
                        Text(sourceSummary(project) + " · " + timeLabel(duration) + " edited")
                            .font(.subheadline).foregroundStyle(.secondary)
                        projectActions(project, canExport: duration > 0).disabled(store.importing)
                    }.padding(18).background(surface, in: RoundedRectangle(cornerRadius: 18)).id(project.id)
                }
                ForEach(store.unavailableProjects.keys.sorted(by: { $0.uuidString < $1.uuidString }), id: \.self) { id in
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Project needs recovery", systemImage: "exclamationmark.triangle")
                        Text(store.unavailableProjects[id] ?? "").font(.footnote).foregroundStyle(.secondary)
                        Button("Open original recordings") { originals = ProjectTarget(id: id) }
                            .buttonStyle(.bordered).accessibilityIdentifier("recovery.originals." + id.uuidString)
                    }.padding().frame(maxWidth: .infinity, alignment: .leading).background(surface, in: RoundedRectangle(cornerRadius: 14))
                }
                if !store.deletedProjects.isEmpty {
                    Button { showingDeleted = true } label: { Label("Recently deleted (\(store.deletedProjects.count))", systemImage: "trash").frame(minHeight: 44) }
                }
            }.padding(20)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if store.importing {
                HStack(spacing: 16) {
                    ProgressView(value: store.operationProgress) { Text(store.operationLabel) }
                    Button("Cancel") { store.cancelOperation() }.frame(minHeight: 44)
                }.padding(.horizontal).background(.bar)
            }
        }
        .onAppear {
            expiredDeletions = store.expiredDeletions()
            showingExpiredDeletionPrompt = !expiredDeletions.isEmpty && !store.importing && store.error == nil
        }
        .alert("Delete older projects?", isPresented: $showingExpiredDeletionPrompt) {
            Button("Not now", role: .cancel) { expiredDeletions = [] }
            Button("Review") { expiredDeletions = []; showingDeleted = true }
            Button(expiredDeletions.count == 1 ? "Delete 1 project" : "Delete \(expiredDeletions.count) projects", role: .destructive) {
                store.eraseExpiredDeletions(expiredDeletions); expiredDeletions = []
            }
        } message: {
            Text("\(expiredDeletions.count == 1 ? "1 project has" : "\(expiredDeletions.count) projects have") been in Recently deleted for more than 30 days. Permanently delete \(expiredDeletions.count == 1 ? "it" : "them"), including original recordings, edits and exports? This cannot be undone.")
        }
    }
}

struct ProjectThumbnail: View {
    let url: URL?
    @State private var thumbnail: UIImage?
    var body: some View {
        ZStack {
            Color.black
            if let thumbnail { Image(uiImage: thumbnail).resizable().scaledToFill() }
            else { Image(systemName: "film.stack").foregroundStyle(.secondary) }
        }.clipped().accessibilityHidden(true).task(id: url) {
            guard let url else { return }
            let asset = AVURLAsset(url: url)
            if let reader = try? await LogThumbnailSource.make(url: url) {
                let picture = try? await reader.image(at: 0, maximumSize: CGSize(width: 192, height: 168))
                if let picture, !Task.isCancelled { thumbnail = UIImage(cgImage: picture) }
                return
            }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 192, height: 168)
            if let result = try? await generator.image(at: .zero), !Task.isCancelled { thumbnail = UIImage(cgImage: result.image) }
        }
    }
}

private func sourceSummary(_ project: Project) -> String {
    let sounds = project.sources.filter { $0.audioOnly == true }.count
    let takes = project.sources.count - sounds
    var parts: [String] = []
    if takes > 0 || sounds == 0 { parts.append(takes == 1 ? "1 take" : "\(takes) takes") }
    if sounds > 0 { parts.append(sounds == 1 ? "1 audio file" : "\(sounds) audio files") }
    return parts.joined(separator: " · ")
}

private func timeLabel(_ seconds: Double) -> String {
    let value = Int(max(0, seconds.isFinite ? seconds : 0))
    return String(format: "%02d:%02d", value / 60, value % 60)
}

/// The same policy file can be hosted for the App Store listing and read offline here.
struct PrivacyPolicyView: View {
    private static let paragraphs: [String] = {
        guard let url = Bundle.main.url(forResource: "PRIVACY", withExtension: "md"),
              let policy = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return policy.components(separatedBy: "\n\n").dropFirst().map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Self.paragraphs, id: \.self) { paragraph in
                    Text((try? AttributedString(markdown: paragraph)) ?? AttributedString(paragraph))
                }
            }.padding().frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }.navigationTitle("Privacy policy").navigationBarTitleDisplayMode(.inline)
    }
}
