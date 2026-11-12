import SwiftUI
@preconcurrency import AVFAudio

/// Finalize each pass before auditioning it or changing input. Every pass uses
/// the same PCM format, so joining takes drops the pauses without re-encoding.
@MainActor
private final class VoiceDraft: NSObject, ObservableObject, AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    enum Transport { case stopped, recording, playing }
    @Published private(set) var transport = Transport.stopped
    @Published private(set) var duration = 0.0
    @Published private(set) var inputs: [AVAudioSessionPortDescription] = []
    @Published private(set) var inputID: String?
    @Published private(set) var denied = false
    @Published var error: String?

    private let session = AVAudioSession.sharedInstance()
    private var previousSession: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions, String?)?
    private var chosenInput: String?
    private var recordingInput: String?
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var parts: [URL] = []
    private static let workspace: URL = {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("YouRecVoiceDrafts", isDirectory: true)
        // This runs once per process. Only unpublished takes from earlier
        // launches can be here; saved audio lives inside its project.
        try? FileManager.default.removeItem(at: folder)
        return folder
    }()
    private let directory = VoiceDraft.workspace.appendingPathComponent(UUID().uuidString, isDirectory: true)
    private var joined: URL { directory.appendingPathComponent("Joined/Voice recording.caf") }

    var hasAudio: Bool { duration > 0 || transport == .recording }
    var clock: Double {
        switch transport {
        case .recording: duration + (recorder?.currentTime ?? 0)
        case .playing: player?.currentTime ?? 0
        case .stopped: duration
        }
    }
    var level: Double {
        guard let recorder else { return 0 }
        recorder.updateMeters()
        return min(1, max(0, Double(recorder.averagePower(forChannel: 0) + 55) / 55))
    }

    func open() async {
        let granted = await AVAudioApplication.requestRecordPermission()
        guard !Task.isCancelled else { return }
        denied = !granted
        guard granted else { return }
        do { try activateInput() } catch { self.error = error.localizedDescription }
    }

    private func activateInput() throws {
        if previousSession == nil {
            previousSession = (session.category, session.mode, session.categoryOptions, session.preferredInput?.uid)
        }
        let options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothHFP]
        if session.category != .playAndRecord || session.mode != .default || !session.categoryOptions.isSuperset(of: options) {
            try session.setCategory(.playAndRecord, mode: .default, options: options)
        }
        try session.setActive(true)
        if let chosenInput, let port = session.availableInputs?.first(where: { $0.uid == chosenInput }), session.preferredInput?.uid != chosenInput {
            try session.setPreferredInput(port)
        }
        refreshInputs()
    }

    func routeChanged() {
        // Returning to the editor can restore its playback-only session after
        // this sheet has reappeared. Re-enumerate inputs under a recording session.
        if previousSession != nil, transport == .stopped, session.category == .playback,
           UIApplication.shared.applicationState == .active {
            do { try activateInput() } catch { self.error = error.localizedDescription }
        } else {
            refreshInputs()
        }
    }

    private func refreshInputs() {
        inputs = session.availableInputs ?? []
        inputID = session.currentRoute.inputs.first?.uid
        if transport == .recording, let recordingInput, inputID != recordingInput {
            interrupt("Microphone changed. Tap Record more to continue.")
        }
    }

    func select(_ port: AVAudioSessionPortDescription) {
        do {
            try session.setPreferredInput(port)
            chosenInput = port.uid
            refreshInputs()
        } catch { self.error = error.localizedDescription }
    }

    func record() {
        stopPlayback()
        do {
            error = nil
            try activateInput()
            guard let inputID else { throw failure("No microphone is available.") }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Leave room for joining previous takes and importing the finished
            // file, in addition to the reserve shared with camera recordings.
            if FileManager.default.fileExists(atPath: joined.path) {
                try FileManager.default.removeItem(at: joined)
            }
            let bytesPerSecond = 48_000 * 2.0
            let reserveForTakes = Int64(duration * bytesPerSecond) * 2 + 65_536
            let capacity = try RecoverySpace.capacity(at: directory)
            let copies = parts.isEmpty ? 2.0 : 3.0
            let maxSeconds = Double(capacity.free - capacity.floor - reserveForTakes) / (copies * bytesPerSecond)
            guard maxSeconds >= 1 else { throw failure("Free some space on your iPhone before recording more audio.") }
            let name = parts.isEmpty ? "Voice recording.caf" : UUID().uuidString + ".caf"
            let url = directory.appendingPathComponent(name)
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
            let next = try AVAudioRecorder(url: url, settings: settings)
            next.delegate = self
            next.isMeteringEnabled = true
            guard next.record(forDuration: maxSeconds) else { throw failure("The microphone could not start recording.") }
            recorder = next
            recordingInput = inputID
            transport = .recording
        } catch { self.error = error.localizedDescription }
    }

    @discardableResult func stopRecording() -> Bool {
        guard let recorder else { return true }
        recorder.delegate = nil
        recorder.stop()
        self.recorder = nil
        recordingInput = nil
        transport = .stopped
        do {
            let file = try AVAudioFile(forReading: recorder.url)
            guard file.length > 0 else { throw failure("No sound was recorded. Tap Record to try again.") }
            parts.append(recorder.url)
            duration += Double(file.length) / file.processingFormat.sampleRate
            return true
        } catch {
            self.error = error.localizedDescription
            try? FileManager.default.removeItem(at: recorder.url)
            return false
        }
    }

    func play(_ url: URL) throws {
        try session.setActive(true)
        let next = try AVAudioPlayer(contentsOf: url)
        next.delegate = self
        guard next.play() else { throw failure("The recording could not be played.") }
        player = next
        transport = .playing
    }

    func stopPlayback() {
        guard let player else { return }
        player.delegate = nil
        player.stop()
        self.player = nil
        transport = .stopped
    }

    func interrupt(_ message: String) {
        if transport == .recording, stopRecording() { error = message }
        stopPlayback()
    }

    nonisolated func audioRecorderDidFinishRecording(_ sender: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            guard self.recorder === sender else { return }
            self.interrupt(flag ? "Recording stopped to leave space to save this take." : "Recording was interrupted. Check the take before continuing.")
        }
    }
    nonisolated func audioRecorderEncodeErrorDidOccur(_ sender: AVAudioRecorder, error: Error?) {
        Task { @MainActor in
            guard self.recorder === sender else { return }
            self.interrupt(error?.localizedDescription ?? "Recording was interrupted.")
        }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ sender: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard self.player === sender else { return }
            self.stopPlayback()
            if !flag { self.error = "Playback was interrupted." }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ sender: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            guard self.player === sender else { return }
            self.stopPlayback()
            self.error = error?.localizedDescription ?? "The recording could not be played."
        }
    }

    /// Preview and insertion read the same completed file. A one-pass take is
    /// already ready; multi-pass takes are joined once, in bounded chunks.
    func audioFile() async throws -> URL {
        guard let first = parts.first else { throw failure("Record some audio first.") }
        if parts.count == 1 { return first }
        if FileManager.default.fileExists(atPath: joined.path) { return joined }
        try await Self.join(parts, to: joined)
        return joined
    }

    private static nonisolated func join(_ parts: [URL], to url: URL) async throws {
        let fm = FileManager.default
        try Task.checkCancellation()
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let size = try parts.reduce(Int64(0)) { try $0 + RecoverySpace.size($1) }
        try RecoverySpace.require(size, at: url.deletingLastPathComponent())
        do {
            let first = try AVAudioFile(forReading: parts[0])
            let output = try AVAudioFile(forWriting: url, settings: first.fileFormat.settings)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: output.processingFormat, frameCapacity: 32_768) else { throw CocoaError(.fileWriteUnknown) }
            for part in parts {
                let input = try AVAudioFile(forReading: part)
                while input.framePosition < input.length {
                    try Task.checkCancellation()
                    try input.read(into: buffer)
                    guard buffer.frameLength > 0 else { throw CocoaError(.fileReadCorruptFile) }
                    try output.write(from: buffer)
                }
            }
        } catch { try? fm.removeItem(at: url); throw error }
    }

    func discard() {
        stopPlayback()
        recorder?.delegate = nil
        recorder?.stop()
        recorder = nil; recordingInput = nil
        parts.removeAll()
        duration = 0; transport = .stopped; error = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func close() {
        discard()
        guard let (category, mode, options, preferred) = previousSession else { return }
        previousSession = nil
        if session.category == .playAndRecord {
            try? session.setPreferredInput(session.availableInputs?.first { $0.uid == preferred })
        }
        try? session.setCategory(category, mode: mode, options: options)
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "YouRec.VoiceRecording", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

struct VoiceRecordingEditor: View {
    @ObservedObject var store: ProjectStore
    let projectID: UUID
    let position: Double
    let cancel: () -> Void
    let inserted: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @StateObject private var draft = VoiceDraft()
    @State private var job: Task<Void, Never>?
    @State private var saving = false
    @State private var confirmDiscard = false
    @State private var leaving = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                microphoneMenu
                TimelineView(.animation(minimumInterval: 0.1, paused: draft.transport == .stopped)) { _ in
                    VStack(spacing: 8) {
                        Text(editorTime(draft.clock)).font(.system(.largeTitle, design: .rounded).monospacedDigit().weight(.medium))
                            .accessibilityLabel("Elapsed time").accessibilityValue(editorTime(draft.clock))
                            .accessibilityIdentifier("voice.time")
                        ProgressView(value: draft.level).tint(.mint).frame(width: 120).accessibilityHidden(true)
                            .opacity(draft.transport == .recording ? 1 : 0)
                    }
                }
                HStack(spacing: 12) {
                    Button {
                        if draft.transport == .recording { draft.stopRecording() } else { draft.record() }
                    } label: {
                        Label(recordTitle, systemImage: draft.transport == .recording ? "stop.fill" : "record.circle")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent).tint(.red).foregroundStyle(.white)
                    .disabled(job != nil || draft.denied || AVAudioApplication.shared.recordPermission != .granted)
                    .accessibilityIdentifier("voice.record")
                    Button {
                        if draft.transport == .playing { draft.stopPlayback() } else { useTake(save: false) }
                    } label: {
                        Label(draft.transport == .playing ? "Stop" : "Play", systemImage: draft.transport == .playing ? "stop.fill" : "play.fill")
                            .frame(minWidth: 72, minHeight: 44)
                    }
                    .buttonStyle(.bordered).tint(.primary)
                    .disabled(!draft.hasAudio || draft.transport == .recording || job != nil)
                    .accessibilityIdentifier("voice.play")
                }
                if job != nil {
                    ProgressView(saving ? "Adding recording…" : "Preparing playback…").font(.callout)
                } else if draft.denied {
                    Text("Allow microphone access in Settings to record your voice.").font(.callout)
                    Button("Open Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }
                } else if let error = draft.error {
                    Text(error).font(.callout).foregroundStyle(.orange)
                }
                if draft.hasAudio {
                    Button { askToDiscard(leave: false) } label: {
                        Label("Start over", systemImage: "arrow.counterclockwise").frame(minHeight: 44)
                    }.foregroundStyle(.secondary).disabled(job != nil).accessibilityIdentifier("voice.startOver")
                }
            }
            .frame(maxWidth: 420).padding(.horizontal, 20).padding(.vertical, 12)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Voice recording").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { askToDiscard(leave: true) }.disabled(job != nil).accessibilityIdentifier("voice.cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { useTake(save: true) }.disabled(!draft.hasAudio || job != nil)
                    .accessibilityHint("Adds the recording at the playhead").accessibilityIdentifier("voice.done")
            }
        }
        .alert("Discard this recording?", isPresented: $confirmDiscard) {
            Button("Keep take", role: .cancel) {}
            Button("Discard", role: .destructive) {
                draft.discard()
                if leaving { cancel() }
            }
        } message: { Text("This discards all the takes in this voice recording.") }
        .task(id: scenePhase == .active) {
            if scenePhase == .active, draft.transport == .stopped { await draft.open() }
        }
        .onChange(of: draft.transport == .recording) { _, active in
            RecordingAppDelegate.keepAwake("editorVoiceRecording", active: active)
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification).receive(on: RunLoop.main)) { _ in draft.routeChanged() }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification).receive(on: RunLoop.main)) { note in
            if (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue {
                draft.interrupt("Recording paused by iOS. Tap Record more to continue.")
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                if !saving { job?.cancel() }
                draft.interrupt("Recording paused. Tap Record more to continue.")
            }
        }
        .onDisappear {
            job?.cancel()
            draft.close()
            RecordingAppDelegate.keepAwake("editorVoiceRecording", active: false)
        }
    }

    private var microphoneMenu: some View {
        Menu {
            ForEach(draft.inputs, id: \.uid) { input in
                Button { draft.select(input) } label: {
                    if input.uid == draft.inputID { Label(input.portName, systemImage: "checkmark") }
                    else { Text(input.portName) }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "mic.fill").foregroundStyle(.mint)
                Text(draft.inputs.first(where: { $0.uid == draft.inputID })?.portName ?? "Microphone").lineLimit(2)
                Image(systemName: "chevron.down").font(.caption2)
            }.font(.subheadline.weight(.semibold)).frame(minHeight: 44)
        }
        .tint(.primary).disabled(draft.transport == .recording || draft.inputs.isEmpty || job != nil)
        .accessibilityHint("Choose the microphone for the next take").accessibilityIdentifier("voice.mic")
    }

    private var recordTitle: String {
        if draft.transport == .recording { return "Stop" }
        return draft.hasAudio ? "Record more" : "Record"
    }

    private func askToDiscard(leave: Bool) {
        guard draft.hasAudio else { if leave { cancel() }; return }
        draft.stopRecording()
        draft.stopPlayback()
        leaving = leave
        confirmDiscard = true
    }

    private func useTake(save: Bool) {
        guard job == nil, draft.stopRecording() else { return }
        draft.stopPlayback()
        draft.error = nil
        saving = save
        job = Task { @MainActor in
            defer { job = nil }
            do {
                let url = try await draft.audioFile()
                try Task.checkCancellation()
                if save {
                    if await store.insertAudio(url, into: projectID, at: position) { inserted() }
                    else { draft.error = store.error ?? "Couldn’t add the recording. Tap Done to try again."; store.error = nil }
                } else if UIApplication.shared.applicationState == .active {
                    try draft.play(url)
                }
            } catch is CancellationError {} catch { draft.error = error.localizedDescription }
        }
    }
}
