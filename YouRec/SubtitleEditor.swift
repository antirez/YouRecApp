import SwiftUI
import AVKit

struct SubtitleEditor: View {
    let project: Project
    let folder: URL
    let request: ToolRequest
    let cancel: () -> Void
    let apply: (EditState) -> Void
    @StateObject private var preview = EditorController()
    @State private var draft: EditState
    @State private var projectCues: [SubtitleCue]
    @State private var resolvedCues: [SubtitleCue]
    @State private var lastCopy: Date?
    @State private var revision = UUID()
    @State private var captionLayout: SubtitleLayout?
    @State private var inspecting = false
    @State private var language: String
    @State private var installed = SubtitleModelPack.installed
    @State private var busy = false
    @State private var progress = 0.0
    @State private var status = ""
    @State private var failure: String?
    @State private var job: Task<Void, Never>?
    @State private var jobID: UUID?
    @State private var stopping = false
    @State private var editing: SubtitleCue?
    @State private var editedText = ""
    @State private var editingInAll = false
    @State private var selectedTranscriptID: String?
    @State private var allSentences = true
    @State private var showAppearance = false
    @State private var replacePrompt = false
    @State private var removePrompt = false
    @State private var discardPrompt = false
    @State private var applyPausedPrompt = false
    @State private var removeModelPrompt = false
    @State private var activeRange: ClosedRange<Double>?
    @State private var pausedRange: ClosedRange<Double>?
    @State private var checkpoint: TranscriptionCheckpoint?
    @State private var interruptionMessage: String?
    @State private var pendingRange: ClosedRange<Double>?
    @State private var started = false
    @FocusState private var textFocused: Bool
    @Environment(\.scenePhase) private var scenePhase
    private let awakeReason = "subtitle-editor"
    private let languages = ["Auto", "Italian", "English", "French", "German", "Spanish", "Portuguese", "Chinese", "Japanese", "Korean", "Russian", "Arabic"]

    init(project: Project, folder: URL, request: ToolRequest, position: Double, cancel: @escaping () -> Void, apply: @escaping (EditState) -> Void) {
        self.project = project; self.folder = folder; self.request = request; self.cancel = cancel; self.apply = apply
        _draft = State(initialValue: project.edit)
        let all = project.edit.timeline.subtitleCues
        _projectCues = State(initialValue: all)
        _resolvedCues = State(initialValue: all.filter { $0.start < request.range.upperBound && $0.end > request.range.lowerBound })
        _language = State(initialValue: project.edit.timeline.subtitles?.language ?? "Auto")
    }
    private var cues: [SubtitleCue] { resolvedCues }
    private var settings: SubtitleSettings { draft.timeline.subtitles ?? SubtitleSettings() }
    private var currentIndex: Int? { cues.lastIndex { $0.start <= preview.playhead && preview.playhead < $0.end } }
    private var focusIndex: Int { currentIndex ?? cues.firstIndex { $0.start > preview.playhead } ?? max(0, cues.count - 1) }
    // A selection is half-open: seeking to its exact end would show the next
    // clip/caption. Keep the slider's final stop on its last output frame.
    private var seekRange: ClosedRange<Double> {
        request.range.lowerBound...max(request.range.lowerBound, request.range.upperBound - min(1.0 / 30, (request.range.upperBound - request.range.lowerBound) / 2))
    }
    private var ready: Bool { !busy && !preview.loading && !preview.processingPreview && preview.player.currentItem != nil }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width > geometry.size.height
            VStack(spacing: 0) {
                HStack {
                    Button(editing == nil ? "Cancel" : "Cancel edit") { if editing != nil { editing = nil; textFocused = false } else if busy || pausedRange != nil || draft != project.edit { discardPrompt = true } else { finish(cancel) } }.frame(minWidth: 60, minHeight: 44)
                    Spacer(); Text("Subtitles").font(.headline); Spacer()
                    Button(editing == nil ? "Apply" : "Save text") { if editing != nil { saveText() } else if pausedRange != nil { applyPausedPrompt = true } else { finish { apply(draft) } } }.fontWeight(.semibold).frame(minWidth: 60, minHeight: 44)
                        .disabled(busy).accessibilityIdentifier(editing == nil ? "subtitles.apply" : "subtitles.saveText")
                }.padding(.horizontal, 12)
                let layout = wide ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
                layout {
                    VStack(spacing: 4) {
                        PlayerSurface(player: preview.player, onPlaybackTap: { if ready && editing == nil { preview.togglePlay() } }, identifier: "subtitles.preview", preserveInspection: true, captions: captionPreview)
                            .overlay { if preview.loading { ProgressView() } }
                            .overlay(alignment: .topLeading) {
                                Button { inspecting.toggle() } label: {
                                    Image(systemName: inspecting ? "hand.draw" : "plus.magnifyingglass").frame(width: 44, height: 44)
                                        .foregroundStyle(inspecting ? .cyan : .white).background(.black.opacity(0.7), in: Circle())
                                }.accessibilityLabel(inspecting ? "Edit subtitle placement" : "Inspect subtitles preview")
                                    .accessibilityIdentifier("subtitles.inspect").disabled(!ready).padding(8)
                            }
                        HStack(spacing: 12) {
                            Button { preview.togglePlay() } label: { Image(systemName: preview.playing ? "pause.fill" : "play.fill").frame(width: 44, height: 44) }
                                .disabled(!ready || editing != nil).accessibilityLabel(preview.playing ? "Pause subtitles preview" : "Play subtitles preview")

                            Slider(value: Binding(get: { max(seekRange.lowerBound, min(seekRange.upperBound, preview.playhead)) }, set: { preview.seekPaused($0) }), in: seekRange)
                                .disabled(!ready || editing != nil).accessibilityIdentifier("subtitles.seek")
                            Text(editorTime(preview.playhead)).monospacedDigit().font(.caption).frame(minWidth: 45)
                        }.padding(.horizontal, 12)
                    }.frame(maxWidth: .infinity, maxHeight: wide ? .infinity : max(130, geometry.size.height * (textFocused ? 0.25 : 0.37)))
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(request.scopeTitle).font(.caption).foregroundStyle(.secondary)
                            generation
                            if !projectCues.isEmpty { copyTranscriptButton }
                            if let failure { Label(failure, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                            if let error = preview.error { Text(error).foregroundStyle(.orange); Button("Reload preview") { revision = UUID() } }
                            if draft.timeline.subtitles != nil {
                                grouping
                                Text("Drag subtitles to move · pinch to resize").font(.caption).foregroundStyle(.secondary)
                                DisclosureGroup("Appearance", isExpanded: $showAppearance) { appearance.padding(.top, 8) }
                                if !cues.isEmpty { focusedSentences }
                                else { Text("No captions in this range.").foregroundStyle(.secondary) }
                                Button(role: .destructive) { removePrompt = true } label: { Label("Remove all subtitles", systemImage: "trash").frame(minHeight: 44) }
                                    .disabled(busy || editing != nil).accessibilityIdentifier("subtitles.remove")
                                if !cues.isEmpty { transcript }
                            }
                            Text("Speech stays on your iPhone. Word timing is estimated from pauses.").font(.caption).foregroundStyle(.secondary)
                            if installed { Button("Remove downloaded model (713 MB)", role: .destructive) { removeModelPrompt = true }.font(.caption).frame(minHeight: 44).disabled(busy || stopping) }
                        }.padding(16)
                    }.accessibilityIdentifier("subtitles.controls").frame(width: wide ? min(390, geometry.size.width * 0.46) : nil).frame(maxHeight: .infinity).background(Color(white: 0.075))
                }
            }.background(.black)
        }.preferredColorScheme(.dark).interactiveDismissDisabled()
            .task(id: revision) {
                do { try await Task.sleep(for: .milliseconds(180)); try Task.checkCancellation() } catch { return }
                var candidate = project
                var base = draft
                base.timeline.removeSubtitles()
                // Keep a subtitle compositor on the preview item, including before the first transcript.
                base.timeline.subtitles = SubtitleSettings()
                candidate.commit(base)
                preview.previewRange = request.range
                // load() makes playback ready before it finishes thumbnails.
                // Set the initial position first, so finishing background work
                // cannot undo a seek the user has already made in this sheet.
                if !started { started = true; preview.seekAfterEdit(request.range.lowerBound, duration: candidate.edit.duration) }
                await preview.load(candidate, folder: folder)
            }
            .onChange(of: preview.canvas) { _, _ in rebuildCaptionLayout() }
            .onChange(of: draft.timeline.subtitles) { _, _ in refreshCaptionPreview() }
            .onChange(of: preview.player.currentItem, initial: true) { _, item in
                if let item { refreshCaptionPreview(item: item) }
            }
            .onChange(of: preview.playhead) { _, time in
                if let selectedTranscriptID, !cues.contains(where: { $0.id == selectedTranscriptID && time >= $0.start && time < $0.end }) {
                    self.selectedTranscriptID = nil
                }
            }
            .onAppear { RecordingAppDelegate.keepAwake(awakeReason, active: true) }
            .onDisappear { cancelJob(); preview.stop(); RecordingAppDelegate.keepAwake(awakeReason, active: false) }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background && busy {
                    pausedRange = activeRange
                    interruptionMessage = activeRange == nil
                        ? "Download interrupted. Tap Download to continue."
                        : "Transcription paused. Resume here to continue from the last completed section."
                    cancelJob(keepCheckpoint: true)
                }
            }
            .confirmationDialog("Apply edits and discard paused transcription?", isPresented: $applyPausedPrompt, titleVisibility: .visible) {
                Button("Apply edits and close", role: .destructive) { finish { apply(draft) } }
                Button("Keep editing", role: .cancel) {}
            }
            .confirmationDialog("Discard subtitle work?", isPresented: $discardPrompt, titleVisibility: .visible) {
                Button("Discard and close", role: .destructive) { finish(cancel) }
                Button("Keep editing", role: .cancel) {}
            }
            .confirmationDialog("Remove the downloaded speech model?", isPresented: $removeModelPrompt, titleVisibility: .visible) {
                Button("Remove model", role: .destructive) {
                    do { try SubtitleModelPack.remove(); installed = false; pausedRange = nil; checkpoint = nil; interruptionMessage = nil }
                    catch { failure = error.localizedDescription }
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Existing subtitles are kept. Generating more will require a 713 MB download.") }
            .confirmationDialog("Replace subtitles in this range? Corrected text in the range will be replaced. You can Undo after applying.", isPresented: $replacePrompt, titleVisibility: .visible) {
                Button("Re-transcribe") { if let range = pendingRange { transcribe(range) } }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Remove every subtitle from this project? This includes corrected text and timing. Undo will restore them.", isPresented: $removePrompt, titleVisibility: .visible) {
                Button("Remove all subtitles", role: .destructive) { draft.timeline.removeSubtitles(); changed() }
                Button("Cancel", role: .cancel) {}
            }
    }
    private var captionPreview: CaptionPreview? {
        guard let captionLayout, currentIndex != nil else { return nil }
        return CaptionPreview(envelope: captionLayout.envelope(settings),
            value: String(format: "%.3f x · %.3f y · %.4f size · %@", settings.centerX, settings.y, settings.size, settings.appearance.map {TitleTypeface.label($0.face, folder:folder)} ?? settings.resolvedFont.title), editable: !busy && editing == nil && !inspecting, change: { gesture in
                preview.pause()
                var value = settings
                switch gesture {
                case .pan(let delta): value.x = value.centerX + delta.x; value.y += delta.y
                case .pinch(let factor, let from, let to):
                    let target = min(captionLayout.maximumSize, max(captionLayout.minimumSize, value.size * factor))
                    let ratio = target / value.size
                    value.x = to.x + (value.centerX - from.x) * ratio
                    value.y = to.y + (value.y - from.y) * ratio; value.size = target
                case .ended: break
                }
                draft.timeline.subtitles = captionLayout.constrained(value)
            })
    }
    private func rebuildCaptionLayout() {
        defer { refreshCaptionPreview() }
        guard let canvas = preview.canvas, draft.timeline.subtitles != nil else { captionLayout = nil; return }
        let layout = SubtitleLayout(cues: projectCues, settings: settings, canvas: canvas, folder: folder)
        captionLayout = layout; draft.timeline.subtitles = layout.constrained(settings)
    }
    private func refreshCaptionPreview(item: AVPlayerItem? = nil) {
        guard let item = item ?? preview.player.currentItem, let canvas = preview.canvas,
              let composition = item.videoComposition?.mutableCopy() as? AVMutableVideoComposition,
              let track = (composition.instructions.first as? TrackVideoInstruction)?.subtitles else { return }
        // All instructions of this preview share one track, including gaps and overlaps.
        track.updatePreview(layout: captionLayout, settings: settings, canvas: canvas)
        item.videoComposition = composition
    }
    private func place(_ body: (inout SubtitleSettings) -> Void) {
        preview.pause(); var value = settings; body(&value)
        draft.timeline.subtitles = captionLayout?.constrained(value) ?? value
    }
    private var generation: some View {
        VStack(alignment: .leading, spacing: 10) {
            if busy {
                HStack { Text(status).font(.subheadline); Spacer(); Button("Cancel") { cancelJob() }.buttonStyle(.bordered).frame(minHeight: 44).accessibilityIdentifier("subtitles.cancelJob") }
                ProgressView(value: progress).accessibilityIdentifier("subtitles.progress")
            } else {
                if stopping { Text("Stopping…").font(.subheadline).accessibilityIdentifier("subtitles.stopping") }
                if let interruptionMessage { Text(interruptionMessage).font(.callout).accessibilityIdentifier("subtitles.interruption") }
                HStack {
                    Picker("Language", selection: $language) { ForEach(languages, id: \.self) { Text($0).tag($0) } }.tint(.white)
                        .onChange(of: language) { _, _ in pausedRange = nil; checkpoint = nil; interruptionMessage = nil }
                    Spacer()
                    if installed {
                        Button {
                            if let range = pausedRange { transcribe(range, resuming: true) }
                            else { requestTranscription(request.range) }
                        } label: { Label(pausedRange != nil ? "Resume transcription" : cues.isEmpty ? "Transcribe" : "Re-transcribe", systemImage: "captions.bubble") }
                            .buttonStyle(.borderedProminent).disabled(!ready || stopping || editing != nil).accessibilityIdentifier("subtitles.transcribe")
                    }
                }
                if !installed {
                    Text("Download Qwen speech recognition once, then use it offline. About 713 MB.").font(.subheadline).foregroundStyle(.secondary)
                    Button("Download speech model · 713 MB") { download() }.buttonStyle(.borderedProminent).disabled(stopping).accessibilityIdentifier("subtitles.download")
                }
            }
        }
    }
    private var grouping: some View {
        VStack(alignment: .leading, spacing: 10) {
            Stepper("Max words per subtitle: \(settings.maxWords)", value: Binding(get: { settings.maxWords }, set: { draft.timeline.regroupSubtitles($0); changed() }), in: 1...16)
                .disabled(busy || editing != nil || !draft.timeline.subtitleGroupingAvailable).accessibilityIdentifier("subtitles.maxWords")
            if !draft.timeline.subtitleGroupingAvailable {
                Text("Footage changed. Re-transcribe to change subtitle grouping.").font(.caption).foregroundStyle(.orange).accessibilityIdentifier("subtitles.stale")
                Button("Re-transcribe whole project") { requestTranscription(0...draft.duration) }.disabled(!ready || editing != nil).accessibilityIdentifier("subtitles.refreshAll")
            }
        }
    }
    private var copyTranscriptButton: some View {
        Button {
            UIPasteboard.general.string = SubtitleTiming.joined(projectCues.map(\.text))
            lastCopy = Date()
            UIAccessibility.post(notification: .announcement, argument: "Transcript copied")
        } label: {
            Label(lastCopy == nil ? "Copy full transcript" : "Transcript copied",
                  systemImage: lastCopy == nil ? "doc.on.doc" : "checkmark")
                .frame(minHeight: 44)
        }
        .accessibilityIdentifier("subtitles.copyTranscript")
        .accessibilityHint("Copies all subtitles in the project in playback order.")
        .disabled(busy || editing != nil)
        .task(id: lastCopy) {
            guard lastCopy != nil else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            lastCopy = nil
        }
    }
    private var appearance: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Drag or pinch the caption to position all subtitles. Pinch elsewhere to inspect the video. The outline fits the largest caption in the whole project.")
                .font(.caption).foregroundStyle(.secondary)
            TitleInspector(design: Binding(get:{settings.design},set:{ newValue in
                let reflow = settings.appearance?.layoutKey != newValue.layoutKey
                    || (newValue.face.hasPrefix("import:") && settings.appearance == newValue)
                draft.timeline.subtitles?.appearance=newValue; preview.pause()
                if reflow { rebuildCaptionLayout() }
            }),
                           motion: Binding(get:{settings.motion ?? TitleMotion()},set:{draft.timeline.subtitles?.motion=$0; preview.pause(); rebuildCaptionLayout()}),
                           sample: currentIndex.map {cues[$0].text} ?? cues.first?.text ?? "Subtitles",prefix:"subtitles",folder:folder,
                           frame:{try await TitleInspector.picture(player:preview.player,at:preview.playhead)},
                           replay:{ exit in
                               guard cues.indices.contains(focusIndex) else {return}; let cue = cues[focusIndex]
                               let window=(settings.motion ?? TitleMotion()).previewWindow(exit:exit,duration:cue.end-cue.start)
                               let lower=max(request.range.lowerBound,cue.start+window.lowerBound)
                               let upper=min(request.range.upperBound,cue.start+window.upperBound)
                               if upper>lower {preview.audition(from:lower,to:upper)}
                           }, pauseForFonts: preview.pause).disabled(busy || editing != nil)
            HStack { Text("Size").font(.caption).frame(width: 55, alignment: .leading)
                Slider(value: Binding(get: { settings.size }, set: { size in place { $0.size = size } }), in: (captionLayout?.minimumSize ?? 0.012)...(captionLayout?.maximumSize ?? 0.10)).accessibilityLabel("Subtitle size")
            }.disabled(busy)
            DisclosureGroup("Position") {
                Slider(value: Binding(get: { settings.centerX }, set: { x in place { $0.x = x } }), in: 0...1).accessibilityLabel("Subtitle horizontal position")
                Slider(value: Binding(get: { settings.y }, set: { y in place { $0.y = y } }), in: 0...1).accessibilityLabel("Subtitle vertical position")
                Button("Reset position and size") { place { $0.x = 0.5; $0.y = 0.86; $0.size = 0.052 } }.frame(minHeight: 44)
            }.disabled(busy)

        }
    }
    private var focusedSentences: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text("Following playback").font(.caption.weight(.semibold)); Spacer(); if currentIndex == nil { Text("Pause in speech").font(.caption).foregroundStyle(.secondary) } }
            ForEach(-2...2, id: \.self) { offset in
                let index = focusIndex + offset
                if cues.indices.contains(index) { sentence(cues[index], current: currentIndex == index) }

            }
        }
    }
    private var transcript: some View {
        DisclosureGroup("All subtitles · \(cues.count)", isExpanded: $allSentences) {
            LazyVStack(alignment: .leading, spacing: 4) { ForEach(cues) { cue in sentence(cue, current: currentIndex.map { cues[$0].id == cue.id } ?? false, all: true) } }.padding(.top, 8)
        }.accessibilityIdentifier("subtitles.fullTranscript")
    }
    @ViewBuilder private func sentence(_ cue: SubtitleCue, current: Bool, all: Bool = false) -> some View {
        if editing?.id == cue.id && editingInAll == all {
            VStack(alignment: .leading) {
                TextField("Subtitle text", text: $editedText, axis: .vertical).lineLimit(2...6).textFieldStyle(.roundedBorder).focused($textFocused).accessibilityIdentifier("subtitles.text")
            }
        } else {
            Button {
                let edit = !all || selectedTranscriptID == cue.id
                preview.seekPaused(max(request.range.lowerBound, cue.start))
                if all { selectedTranscriptID = cue.id }
                if edit { editingInAll = all; editing = cue; editedText = cue.text; textFocused = true }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Text(editorTime(cue.start)).monospacedDigit().font(.caption).foregroundStyle(.secondary).frame(width: 45, alignment: .leading)
                    Text(cue.text).font(.subheadline.weight(current ? .semibold : .regular)).foregroundStyle(current ? .white : .secondary).frame(maxWidth: .infinity, alignment: .leading)
                    if current { Image(systemName: "speaker.wave.2.fill").font(.caption).foregroundStyle(.cyan) }
                }.padding(10).frame(minHeight: 44).background(current ? Color.cyan.opacity(0.16) : Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
            }.buttonStyle(.plain).disabled(busy || editing != nil)
                .accessibilityIdentifier((all ? "subtitles.transcript." : "subtitles.sentence.") + cue.id)
                .accessibilityAddTraits(all && selectedTranscriptID == cue.id ? .isSelected : [])
                .accessibilityHint(all ? (selectedTranscriptID == cue.id ? "Tap again to edit this subtitle." : "Select and seek to this subtitle. Tap again to edit.") : "Edit this subtitle.")
        }
    }
    private func saveText() {
        guard let cue = editing else { return }
        draft.timeline.correctSubtitle(cue, text: String(editedText.prefix(4000))); editing = nil; textFocused = false; changed()
    }
    private func changed() {
        selectedTranscriptID = nil; lastCopy = nil
        projectCues = draft.timeline.subtitleCues
        resolvedCues = projectCues.filter { $0.start < request.range.upperBound && $0.end > request.range.lowerBound }
        failure = nil; preview.pause(); rebuildCaptionLayout()
    }
    private func finish(_ action: () -> Void) { cancelJob(); preview.stop(); action() }

    private func cancelJob(keepCheckpoint: Bool = false) {
        if let worker = job, jobID != nil {
            jobID = nil
            worker.cancel()
            stopping = true
            Task { @MainActor in
                await worker.value
                if jobID == nil { stopping = false; job = nil }
            }
        }
        busy = false
        activeRange = nil
        if !keepCheckpoint { pausedRange = nil; checkpoint = nil; interruptionMessage = nil }
    }
    private func requestTranscription(_ range: ClosedRange<Double>) {
        guard ready else { return }
        if draft.timeline.subtitleCues.contains(where: { $0.start < range.upperBound && $0.end > range.lowerBound }) { pendingRange = range; replacePrompt = true }
        else { transcribe(range) }
    }
    private func download() {
        guard !stopping, !busy else { return }
        activeRange = nil; interruptionMessage = nil
        busy = true; progress = 0; failure = nil; status = "Downloading speech model…"; preview.pause()
        let id = UUID()
        jobID = id
        job = Task {
            guard !Task.isCancelled, jobID == id else { return }
            do {
                try await SubtitleModelPack.download { value in
                    Task { @MainActor in if jobID == id { progress = max(progress, value) } }
                }
                guard jobID == id else { return }
                installed = SubtitleModelPack.installed
            } catch { if jobID == id && !Task.isCancelled { failure = error.localizedDescription } }
            if jobID == id { busy = false; jobID = nil; job = nil }
        }
    }
    private func transcribe(_ range: ClosedRange<Double>, resuming: Bool = false) {
        guard !stopping, !busy, let item = preview.player.currentItem else { return }
        if !resuming { checkpoint = nil }
        pausedRange = nil; activeRange = range; interruptionMessage = nil
        busy = true; progress = 0; status = "Reading selected audio…"; failure = nil; preview.pause(); editing = nil; textFocused = false
        let id = UUID(), saved = checkpoint
        jobID = id
        job = Task {
            guard !Task.isCancelled, jobID == id else { return }
            do {
                let words = try await SubtitleTranscriber.shared.transcribe(asset: item.asset, mix: item.audioMix, range: range, language: language, resuming: saved, saveCheckpoint: { saved in
                    await MainActor.run { if jobID == id { checkpoint = saved } }
                }) { value, message in
                    Task { @MainActor in if jobID == id, value >= progress { progress = value; status = message } }
                }
                try Task.checkCancellation()
                guard jobID == id else { return }
                draft.timeline.installSubtitles(words, range: range, language: language); checkpoint = nil; changed()
            } catch { if jobID == id && !Task.isCancelled { failure = error.localizedDescription } }
            if jobID == id { busy = false; jobID = nil; job = nil; activeRange = nil }
        }
    }
}
