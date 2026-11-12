import SwiftUI
import AVKit
import UniformTypeIdentifiers

struct AudioImportEditor: View {
    @ObservedObject var store: ProjectStore
    let projectID: UUID
    let position: Double
    let close: () -> Void
    let inserted: () -> Void
    @State private var picking = false
    @State private var showingRecorder = false
    @State private var busy = false
    @State private var name = ""
    @State private var failure: String?
    @State private var job: Task<Void, Never>?
    var body: some View {
        NavigationStack {
            if showingRecorder {
                VoiceRecordingEditor(store: store, projectID: projectID, position: position, cancel: { showingRecorder = false }, inserted: inserted)
            } else {
                importOptions
            }
        }.preferredColorScheme(.dark).presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
            .interactiveDismissDisabled(busy || showingRecorder).onDisappear { job?.cancel() }
    }

    private var importOptions: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Label("At \(editorTime(position))", systemImage: "playhead").font(.headline)
                Text("Adds a separate sound layer. Your existing video and audio stay in place.").foregroundStyle(.secondary)
                if busy {
                    Text(name).font(.subheadline).lineLimit(2)
                    ProgressView(value: store.operationProgress) { Text("Adding audio…") }
                        .accessibilityIdentifier("audioImport.progress")
                } else {
                    Button { failure = nil; showingRecorder = true } label: {
                        Label("Record now", systemImage: "mic.fill").frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(.borderedProminent).tint(.mint).foregroundStyle(.black).accessibilityIdentifier("audioImport.record")
                    Button { failure = nil; picking = true } label: {
                        Label("Choose audio from Files", systemImage: "folder").frame(maxWidth: .infinity, minHeight: 48)
                    }.buttonStyle(.bordered).tint(.mint).accessibilityIdentifier("audioImport.files")
                    Text("WAV, AIFF, M4A, MP3 and other supported audio files. Use Move and Volume to arrange the sound after importing.").font(.caption).foregroundStyle(.secondary)
                }
                if let failure { Text(failure).foregroundStyle(.orange).font(.callout).accessibilityIdentifier("audioImport.error") }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
        }.navigationTitle("Add audio").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { if busy { job?.cancel() } else { close() } }.frame(minHeight: 44) } }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.audio]) { result in
                switch result {
                case .success(let url):
                    busy = true; name = url.lastPathComponent; failure = nil
                    job = Task { @MainActor in
                        let success = await store.insertAudio(url, into: projectID, at: position)
                        busy = false
                        if success { inserted() }
                        else if Task.isCancelled { close() }
                        else { failure = store.error ?? "Audio could not be imported."; store.error = nil }
                    }
                case .failure(let error): failure = error.localizedDescription
                }
            }
    }
}

struct CensorAudioEditor: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let project: Project
    let folder: URL
    let request: ToolRequest
    let initialPlayer: AVPlayer
    let cancel: () -> Void
    let apply: (EditState) -> Void
    @StateObject private var preview = EditorController()
    @State private var settings: AudioCensorSettings
    @State private var job: Task<Void, Never>?
    @State private var busy = false
    @State private var dirty = true
    @State private var loaded = false
    @State private var help = false
    @State private var token = UUID()
    private let effectID: UUID
    @State private var selectedAudio: Set<UUID>
    @State private var start: Double
    @State private var end: Double
    private var selectionRange: ClosedRange<Double> { start...end }
    private var overlapping: [AudioTimelineItem] {
        project.edit.timeline.audio.filter { $0.interval.intersection(EditInterval(selectionRange)) != nil }
    }
    private var target: TimelineSelection {
        TimelineSelection(audio: selectedAudio.intersection(Set(overlapping.map(\.id))), range: EditInterval(selectionRange))
    }
    private var range: ClosedRange<Double> {
        let lower = max(0, start - 1)
        return lower...min(project.edit.duration, min(end + 1, lower + 10))
    }
    init(project: Project, folder: URL, request: ToolRequest, initialPlayer: AVPlayer, cancel: @escaping () -> Void, apply: @escaping (EditState) -> Void) {
        self.project = project; self.folder = folder; self.request = request; self.initialPlayer = initialPlayer; self.cancel = cancel; self.apply = apply
        var target = request.targets ?? project.edit.timeline.entireSelection(range: EditInterval(request.range))
        target.video = []; target.range = EditInterval(request.range)
        _selectedAudio = State(initialValue: target.audio)
        _start = State(initialValue: request.range.lowerBound); _end = State(initialValue: request.range.upperBound)
        self.effectID = request.effectID ?? UUID()
        let existing = project.edit.timeline.audio.filter { target.audio.contains($0.id) }.flatMap(\.censors)
            .first { $0.id == request.effectID }
        _settings = State(initialValue: existing?.settings ?? AudioCensorSettings())
    }
    private func state() -> EditState {
        var edit = project.edit
        if request.effectID != nil { edit = edit.removingTool(request) }
        edit.timeline.censor(settings, selection: target, effectID: effectID)
        return edit
    }
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let wide = geometry.size.width > geometry.size.height
                let layout = wide ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
                layout {
                    VStack(spacing: 0) {
                        PlayerSurface(player: loaded ? preview.player : initialPlayer, inspectionZoom: true, onPlaybackTap: play, identifier: "censor.preview")
                        HStack {
                            Button(action: play) {
                                let symbol = busy ? "xmark" : preview.playing ? "pause.fill" : "play.fill"
                                if typeSize.isAccessibilitySize { Image(systemName: symbol).font(.title2).frame(minWidth: 44, minHeight: 44) }
                                else { Label(busy ? "Cancel preview" : preview.playing ? "Pause" : "Play preview", systemImage: symbol).frame(minHeight: 44) }
                            }.accessibilityLabel(busy ? "Cancel preview" : preview.playing ? "Pause" : "Play preview").accessibilityIdentifier("censor.play")
                            Spacer()
                            Text(editorTime(loaded ? preview.playhead : initialPlayer.currentTime().seconds)).font(.caption.monospacedDigit())
                        }.padding(.horizontal, 16)
                        Slider(value: Binding(get: { min(range.upperBound, max(range.lowerBound, loaded ? preview.playhead : range.lowerBound)) }, set: { preview.seekPaused($0) }), in: range)
                            .padding(.horizontal, 16).disabled(!loaded || busy || dirty).accessibilityLabel("Censor preview position").accessibilityIdentifier("censor.seek")
                    }.frame(maxWidth: .infinity, maxHeight: wide ? .infinity : max(150, geometry.size.height * 0.36))
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Censor range").font(.headline)
                                    Button { help = true } label: { Image(systemName: "questionmark.circle").frame(width: 44, height: 44) }.accessibilityLabel("About audio censoring")
                                    Spacer()
                                }
                                boundaryControl("Start", value: start, earlier: start > 0, later: start + TimelineEditing.frame < end) { delta in start = max(0, min(end - TimelineEditing.frame, start + delta)) }
                                boundaryControl("End", value: end, earlier: end - TimelineEditing.frame > start, later: end < project.edit.duration) { delta in end = max(start + TimelineEditing.frame, min(project.edit.duration, end + delta)) }
                                Text("Nudge by one frame to cover the entire word.").font(.caption).foregroundStyle(.secondary)
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Sound to replace").font(.subheadline.weight(.semibold))
                                ForEach(overlapping) { item in
                                    Toggle(isOn: Binding(get: { selectedAudio.contains(item.id) }, set: { enabled in
                                        if enabled { selectedAudio.insert(item.id) } else { selectedAudio.remove(item.id) }
                                    })) { Text(audioTitle(item)).font(.subheadline).lineLimit(2) }
                                        .frame(minHeight: 44).accessibilityIdentifier("censor.track." + item.id.uuidString)
                                }
                                if target.audio.isEmpty { Text("Select an audio part in this range.").font(.caption).foregroundStyle(.orange) }
                                else { Text("Unselected tracks keep their sound.").font(.caption).foregroundStyle(.secondary) }
                            }
                            Picker("Waveform", selection: $settings.waveform) {
                                ForEach(CensorWaveform.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                            }.pickerStyle(.segmented).accessibilityIdentifier("censor.waveform")
                            VStack(alignment: .leading, spacing: 4) {
                                parameterHeading("Frequency", value: "\(Int(settings.frequency)) Hz")
                                Slider(value: $settings.frequency, in: 100...4000, step: 25).accessibilityLabel("Beep frequency").accessibilityValue("\(Int(settings.frequency)) hertz").accessibilityIdentifier("censor.frequency")
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 240 : 90))]) { ForEach([440.0, 1000, 2000], id: \.self) { frequency in
                                    Button("\(Int(frequency)) Hz") { settings.frequency = frequency }.font(.subheadline).lineLimit(1).buttonStyle(.bordered).tint(settings.frequency == frequency ? .mint : .gray).foregroundStyle(settings.frequency == frequency ? Color.mint : Color.primary).frame(maxWidth: .infinity, minHeight: 44).accessibilityAddTraits(settings.frequency == frequency ? .isSelected : [])
                                } }
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Envelope")
                                Picker("Envelope", selection: $settings.envelope) {
                                    Text("Short fade").tag(CensorEnvelope.short); Text("Soft fade").tag(CensorEnvelope.soft); Text("Pulsed").tag(CensorEnvelope.pulse)
                                }.pickerStyle(.segmented).accessibilityIdentifier("censor.envelope")
                                envelopeDrawing.frame(height: 34).accessibilityHidden(true)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                parameterHeading("Beep level", value: "\(Int(settings.levelDB)) dBFS")
                                Slider(value: $settings.levelDB, in: -36...(-6), step: 1).accessibilityLabel("Beep peak level").accessibilityValue("\(Int(settings.levelDB)) decibels full scale").accessibilityIdentifier("censor.level")
                                Text("Track Volume applies. Where selected tracks overlap, the loudest track carries the beep.").font(.caption).foregroundStyle(.secondary)
                            }
                            if busy { ProgressView("Preparing short audio preview…").accessibilityIdentifier("censor.preparing") }
                            if let error = preview.error { Text(error).foregroundStyle(.orange) }
                            Text("Preview includes nearby sound, up to 10 seconds. Speech stays removed during the beep's soft edges and pulse gaps.").font(.caption).foregroundStyle(.secondary)
                            if request.effectID != nil {
                                Button(role: .destructive) { finish { apply(project.edit.removingTool(request)) } } label: { Label("Remove censor", systemImage: "trash").frame(minHeight: 44) }.accessibilityIdentifier("censor.remove")
                            }
                        }.padding(16).padding(.bottom, 24)
                    }.frame(width: wide ? min(400, geometry.size.width * 0.5) : nil)
                        .accessibilityIdentifier("censor.controls")
                }
            }.background(Color(white: 0.06)).navigationTitle("Censor audio").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { finish(cancel) }.frame(minHeight: 44) }
                    ToolbarItem(placement: .confirmationAction) { Button("Apply") { finish { apply(state()) } }.disabled(target.audio.isEmpty).accessibilityIdentifier("censor.apply").frame(minHeight: 44) }
                }
                .sheet(isPresented: $help) {
                    InspectorHelpSheet(topic: InspectorHelp(title: "Censor audio", guide: "Replace a word or sound with a generated tone. Nudge Start and End to cover it completely, and choose which audio parts to replace. Unselected music or other tracks keep playing.\n\nSine is smooth; triangle and square sound sharper. Frequency sets pitch, Beep level sets the peak before track Volume, and the envelope shapes the tone without revealing speech during fades or pulse gaps.\n\nPlay preview auditions up to ten seconds around the start of the range. Changes wait for another Play tap. Apply saves the edit; Remove or Undo restores the original.", history: nil))
                }
        }.tint(.mint).preferredColorScheme(.dark).interactiveDismissDisabled()
            .onChange(of: settings) { _, _ in invalidate() }.onChange(of: selectionRange) { _, _ in invalidate() }.onChange(of: selectedAudio) { _, _ in invalidate() }.onDisappear { job?.cancel(); preview.stop() }
    }
    private func audioTitle(_ item: AudioTimelineItem) -> String {
        let number = (project.edit.timeline.audio.firstIndex { $0.id == item.id } ?? 0) + 1
        let name = project.sources.first { $0.id == item.sourceID }?.originalName ?? "Video sound"
        return "♪\(number) · " + name + (item.muted ? " · Muted" : "")
    }
    private func parameterHeading(_ title: String, value: String) -> some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout())
        return layout {
            Text(title)
            if !typeSize.isAccessibilitySize { Spacer() }
            Text(value).monospacedDigit().fixedSize()
        }
    }
    private func boundaryControl(_ title: String, value: Double, earlier: Bool, later: Bool, change: @escaping (Double) -> Void) -> some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            Text(title).font(.subheadline)
            if !typeSize.isAccessibilitySize { Spacer(minLength: 4) }
            HStack(spacing: 8) {
            Button { change(-TimelineEditing.frame) } label: { Image(systemName: "minus").frame(width: 44, height: 44) }
                .disabled(!earlier).accessibilityLabel(title + " earlier").accessibilityIdentifier("censor." + title.lowercased() + ".earlier")
            Text(editorTime(value)).font(.subheadline.monospacedDigit()).fixedSize().accessibilityIdentifier("censor." + title.lowercased())
            Button { change(TimelineEditing.frame) } label: { Image(systemName: "plus").frame(width: 44, height: 44) }
                .disabled(!later).accessibilityLabel(title + " later").accessibilityIdentifier("censor." + title.lowercased() + ".later")
            }
        }
    }
    private var envelopeDrawing: some View {
        GeometryReader { geometry in
            Path { path in
                let duration = min(1, end - start)
                for i in 0...160 {
                    let x = Double(i) / 160
                    let point = CGPoint(x: x * geometry.size.width, y: (1 - settings.envelopeValue(time: x * duration, duration: duration)) * (geometry.size.height - 4) + 2)
                    if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
            }.stroke(.mint.opacity(0.8), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
        }
    }
    private func invalidate() {
        job?.cancel(); token = UUID(); preview.pause(); dirty = true
        if busy { preview.stop(); loaded = false }; busy = false
    }
    private func finish(_ action: () -> Void) { invalidate(); action() }
    private func play() {
        if busy { invalidate(); return }
        if loaded && !dirty && preview.error == nil { preview.togglePlay(); return }
        let current = UUID(); token = current; busy = true
        var candidate = project; candidate.history = [state()]; candidate.historyCursor = 0
        job = Task { @MainActor in
            preview.previewRange = range; preview.seekAfterEdit(range.lowerBound, duration: project.edit.duration)
            await preview.load(candidate, folder: folder, includeTimelineDetails: false, audioPreviewRange: range)
            guard !Task.isCancelled, current == token else { return }
            busy = false
            if preview.error == nil { loaded = true; dirty = false; preview.seek(range.lowerBound); preview.togglePlay() }
        }
    }
}

#if DEBUG
@MainActor enum AudioToolsDiagnostics {
    static func run() async {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let root = documents.appendingPathComponent("AudioToolsQA"), folder = root.appendingPathComponent(UUID().uuidString)
        var report: [String: Any] = ["status": "running"]
        RecordingAppDelegate.keepAwake("audio-tools-qa", active: true)
        defer {
            RecordingAppDelegate.keepAwake("audio-tools-qa", active: false)
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: root.appendingPathComponent("report.json"), options: .atomic) }
        }
        func check(_ value: Bool, _ message: String) throws { if !value { throw NSError(domain: "AudioToolsQA", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) } }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let original = root.appendingPathComponent("Import tone.wav")
            let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
            do {
                let file = try AVAudioFile(forWriting: original, settings: format.settings)
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 192000)!; buffer.frameLength = 192000
                for i in 0..<192000 { for channel in 0..<2 { buffer.floatChannelData![channel][i] = Float(0.25 * sin(Double(i) * 2 * .pi * 200 / 48000)) } }
                try file.write(from: buffer)
            }
            let imported = try await ImportedAudioFile.stage(original, in: folder.appendingPathComponent("Processing")) { _ in }
            try FileManager.default.moveItem(at: imported.url, to: folder.appendingPathComponent(imported.source.filename))
            var project = Project(title: "Audio tools diagnostics"); project.sources = [imported.source]
            var edit = project.edit
            let id = edit.timeline.insertAudio(imported.source, at: .zero)
            edit.timeline.censor(AudioCensorSettings(), selection: TimelineSelection(audio: [id], range: EditInterval(1...2)))
            project.commit(edit); try project.validate()
            let media = try await TrackRenderer.timeline(project: project, folder: folder)
            func pcm(_ asset: AVAsset, mix: AVAudioMix?) async throws -> [Float] {
                let url = folder.appendingPathComponent(UUID().uuidString + ".caf")
                _ = try await MediaRenderer.processedAudio(asset: asset, duration: 4, effects: [], outputURL: url, mix: mix) { _ in }
                let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
                let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
                try file.read(into: buffer)
                return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            }
            let preview = try await pcm(media.composition, mix: media.audioMix)
            let output = folder.appendingPathComponent("Censored.mp4")
            _ = try await MediaRenderer.render(project: project, folder: folder, destination: output) { _ in }
            let exported = try await pcm(AVURLAsset(url: output), mix: nil)
            func component(_ values: [Float], hz: Double) -> Double {
                var a = 0.0, b = 0.0
                for i in 57600..<86400 { let p = Double(i) * 2 * .pi * hz / 48000; a += Double(values[i]) * cos(p); b += Double(values[i]) * sin(p) }
                return 2 * hypot(a, b) / 28800
            }
            let wanted = pow(10, -18.0 / 20), actual = component(exported, hz: 1000), leak = component(exported, hz: 200)
            try check(abs(component(preview, hz: 1000) - wanted) < 0.0001, "Preview tone differs from generator")
            try check(abs(actual - wanted) < 0.005 && leak < 0.0002, "Export tone or suppression differs from preview")
            try check(FileManager.default.fileExists(atPath: original.path), "Import changed original")
            report = ["status": "passed", "folder": folder.lastPathComponent, "previewAmplitude": component(preview, hz: 1000), "exportAmplitude": actual, "sourceLeak": leak, "duration": try await AVURLAsset(url: output).load(.duration).seconds]
        } catch { report = ["status": "failed", "error": String(describing: error)] }
    }
}
#endif
