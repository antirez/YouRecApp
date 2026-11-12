import AVKit
import SwiftUI

struct OriginalRecordingsView: View {
    @ObservedObject var store: ProjectStore
    let projectID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var items: [OriginalRecording] = []
    @State private var reviewing: OriginalRecording?
    @State private var message: String?
    @State private var copying = false
    @State private var copyJob: Task<Void, Never>?
    @State private var copySize: Int64?
    private var project: Project? { store.projects.first { $0.id == projectID } }
    var body: some View {
        NavigationStack {
            List {
                if let notice = store.recoveryMessages[projectID] { Text(notice) }
                if let issue = store.unavailableProjects[projectID] {
                    Text(issue).foregroundStyle(.secondary)
                    Button("Retry opening project") { store.retryUnavailableProjects() }
                }
                if let project, !store.interruptedRepairs(in: project).isEmpty {
                    Button("Retry interrupted recovery") {
                        Task {
                            await store.retryInterruptedRepairs(in: project)
                            items = store.disk.originals(in: projectID, project: self.project)
                        }
                    }.disabled(store.recovering)
                }
                if let message { Text(message) }
                Section("Original recordings") {
                    if items.isEmpty { Text("No original media files found.").foregroundStyle(.secondary) }
                    ForEach(items) { item in
                        HStack {
                            Button {
                                reviewing = item
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(item.title).lineLimit(2)
                                    if let source = item.source {
                                        Text(editorTime(source.duration) + " recorded").font(.caption).foregroundStyle(
                                            .secondary)
                                    }
                                }
                            }.buttonStyle(.plain)
                            Spacer()
                            ShareLink(item: item.url) {
                                Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44)
                            }
                            .accessibilityLabel("Save original " + item.title)
                        }
                    }
                    if items.count > 1 {
                        ShareLink(items: items.map(\.url)) {
                            Label("Save all originals to Files", systemImage: "square.and.arrow.up")
                        }
                    }
                }
                if !items.isEmpty {
                    Section {
                        Button {
                            copying = true
                            copyJob = Task {
                                do {
                                    message = try await store.makeRecoveredProject(from: projectID)
                                } catch is CancellationError {
                                    message = "Copy cancelled. Your originals are available."
                                } catch { message = error.localizedDescription }
                                copying = false
                            }
                        } label: {
                            Label(
                                copying ? "Creating recovered project…" : "Create recovered project",
                                systemImage: "plus.rectangle.on.folder")
                        }
                        .disabled(copying)
                        if copying { Button("Cancel copy") { copyJob?.cancel() } }
                    } footer: {
                        Text("Creates a separate project from the playable originals. The existing project stays available.")
                    }
                    if let copySize {
                        Text(
                            "Estimated space for the copy: "
                                + ByteCountFormatter.string(fromByteCount: copySize, countStyle: .file)
                        ).font(.footnote)
                    }
                }
            }.navigationTitle("Original recordings")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(copying) } }
                .interactiveDismissDisabled(copying)
                .task {
                    items = store.disk.originals(in: projectID, project: project)
                    copySize = try? items.reduce(Int64(0)) { try $0 + RecordingSalvage.copyBudget(for: $1.url) }
                }
                .sheet(item: $reviewing) { item in
                    OriginalReview(
                        item: item, canInsert: project != nil,
                        recover: {
                            try await store.makeRecoveredProject(from: projectID, only: item.url)
                        }
                    ) { start, end in
                        try await store.reinsertOriginal(item, in: projectID, start: start, end: end)
                    }
                }
        }.preferredColorScheme(.dark)
    }
}

private struct OriginalReview: View {
    let item: OriginalRecording
    let canInsert: Bool
    let recover: () async throws -> String
    let insert: (Double, Double) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var player = AVPlayer()
    @State private var media: RecordingSalvage.Media?
    @State private var start = 0.0
    @State private var end = 0.0
    @State private var issue: String?
    @State private var saving = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if media != nil { VideoPlayer(player: player).aspectRatio(16 / 9, contentMode: .fit) }
                    Text(item.title).font(.headline)
                    if let issue { Text(issue).foregroundStyle(.secondary) }
                    if let media {
                        Text(editorTime(media.duration) + " recorded").monospacedDigit()
                        ForEach(item.source?.events?.filter { $0.kind == "videoHold" || $0.kind == "audioGap" } ?? []) { event in
                            Text(editorTime(event.time) + " · " + event.detail)
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if canInsert && !media.audioOnly && item.source != nil {
                            Text("Start  " + editorTime(start))
                            Slider(
                                value: Binding(
                                    get: { start / media.duration },
                                    set: {
                                        start = min(max(0, end - TimelineEditing.frame), $0 * media.duration)
                                        player.seek(to: CMTime(seconds: start, preferredTimescale: 60000))
                                    }), in: 0...1
                            ).accessibilityLabel("Original start")
                            Text("End  " + editorTime(end))
                            Slider(
                                value: Binding(
                                    get: { end / media.duration },
                                    set: {
                                        end = min(media.duration, max(start + TimelineEditing.frame, $0 * media.duration))
                                        player.seek(
                                            to: CMTime(
                                                seconds: max(start, end - TimelineEditing.frame), preferredTimescale: 60000))
                                    }), in: 0...1
                            ).accessibilityLabel("Original end")
                            Button("Add range to end of timeline") {
                                saving = true
                                Task {
                                    do {
                                        try await insert(start, end)
                                        dismiss()
                                    } catch { issue = error.localizedDescription }
                                    saving = false
                                }
                            }.buttonStyle(.borderedProminent).disabled(saving)
                        }
                    }
                    if media == nil || item.source == nil {
                        if let size = try? RecordingSalvage.copyBudget(for: item.url) {
                            Text(
                                "Estimated repair space: "
                                    + ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
                            ).font(.footnote)
                        }
                        Button(saving ? "Recovering…" : "Recover this recording into a new project") {
                            saving = true
                            Task {
                                do { issue = try await recover() } catch { issue = error.localizedDescription }
                                saving = false
                            }
                        }.disabled(saving)
                    }
                    ShareLink("Save original to Files", item: item.url)
                }.padding()
            }.navigationTitle("Review original").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .task {
                    do {
                        let info = try await RecordingSalvage.inspect(item.url)
                        media = info
                        end = info.duration
                        player.replaceCurrentItem(with: AVPlayerItem(url: item.url))
                    } catch {
                        issue = "You can save this file or try creating a recovered project from its readable footage."
                    }
                }
                .onDisappear { player.pause() }
        }
    }
}
