import SwiftUI
import PhotosUI

struct AddVideoPanel: View {
    @ObservedObject var store: ProjectStore
    let project: Project
    let position: Double
    var site: VideoInsertionSite?
    var pasteHere: (() -> Void)?
    var close: (() -> Void)?
    let record: () -> Void
    let inserted: (Int, Double) -> Void

    @State private var picked: [PhotosPickerItem] = []
    @State private var retryItems: [PhotosPickerItem] = []
    @State private var loading = false
    @State private var cancelling = false
    @State private var problem: String?
    @State private var choosingTakes = false

    private var unused: [SourceMedia] {
        let used = Set(project.edit.clips.map(\.sourceID))
        return project.sources.filter { $0.audioOnly != true && !used.contains($0.id) }
    }

    private var destinationTitle: String { site?.label ?? "Insert at \(editorTime(position))" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label(destinationTitle, systemImage: "playhead").font(.headline)
                if loading {
                    ProgressView(value: store.operationProgress) {
                        Text(cancelling ? "Cancelling import…" : store.operationLabel)
                    }.accessibilityIdentifier("addVideo.progress")
                } else {
                    Text(instructions)
                        .font(.subheadline).foregroundStyle(.secondary)
                    if let problem {
                        Text(problem).font(.subheadline).foregroundStyle(.orange)
                        if !retryItems.isEmpty {
                            Button("Retry selection") { importPhotos(retryItems) }.frame(minHeight: 44)
                        }
                    }
                    PhotosPicker(selection: $picked, maxSelectionCount: nil, selectionBehavior: .ordered,
                                 matching: .any(of: [.images, .videos]), preferredItemEncoding: .current) {
                        Label("From Photos", systemImage: "photo.on.rectangle")
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }.buttonStyle(.borderedProminent)
                    Button(action: record) {
                        Label("Record here", systemImage: "record.circle").frame(maxWidth: .infinity, minHeight: 48)
                    }.buttonStyle(.bordered).accessibilityIdentifier("editor.recordHere")
                    if let pasteHere {
                        Button(action: pasteHere) {
                            Label("Paste here", systemImage: "doc.on.clipboard")
                                .frame(maxWidth: .infinity, minHeight: 48)
                        }.buttonStyle(.bordered).accessibilityIdentifier("addVideo.pasteHere")
                    }
                    if !unused.isEmpty {
                        Button {
                            choosingTakes = true
                        } label: {
                            HStack {
                                Label("Unused takes (\(unused.count))", systemImage: "film.stack")
                                Spacer(); Image(systemName: "chevron.right").font(.caption)
                            }.frame(minHeight: 44).contentShape(Rectangle())
                        }.accessibilityIdentifier("addVideo.unused")
                    }
                }
            }.padding(20)
        }
        .navigationTitle("Add video or photo").navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(loading)
        .toolbar {
            if loading {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel import") { cancelling = true; store.cancelOperation() }.disabled(cancelling)
                }
            } else if let close {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: close) }
            }
        }
        .navigationDestination(isPresented: $choosingTakes) {
            UnusedTakePicker(takes: unused, folder: store.folder(project), destinationTitle: destinationTitle) { ordered in
                if store.update(project.id, { $0.insertVideos(ordered, at: position, site: site) }) {
                    let start = store.selected?.edit.timeline.video.first { $0.content.sourceID == ordered.first?.id }?.start.seconds
                    inserted(ordered.count, start ?? position)
                } else {
                    choosingTakes = false
                    problem = store.error ?? "Couldn’t insert the selected takes."
                }
            }
        }
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            picked = []
            importPhotos(items)
        }
        .interactiveDismissDisabled(loading)
        .onDisappear { if loading { store.cancelOperation() } }
    }

    private var instructions: String {
        let placement: String
        switch site {
        case .start: placement = project.edit.timeline.video.isEmpty ? "The first starts at 0:00." : "The last one meets your first clip."
        case .gap: placement = "They fill the gap from \(editorTime(position)), moving later footage forward if needed."
        case .end: placement = "The first starts where your last clip ends."
        case nil: placement = "The first starts at the playhead."
        }
        return "Choose photos and videos in playback order. \(placement) Each photo lasts \(PhotoClip.seconds) seconds."
    }

    private func importPhotos(_ items: [PhotosPickerItem]) {
        guard !loading else { return }
        loading = true; cancelling = false; problem = nil; retryItems = items
        store.insertVideos(items, into: project.id, at: position, site: site) { result in
            loading = false; cancelling = false
            switch result {
            case .success(let start):
                retryItems = []; inserted(items.count, start)
            case .failure(let error) where error is CancellationError:
                problem = "Import cancelled."
            case .failure(let error):
                problem = error.localizedDescription
            }
        }
    }
}

private struct UnusedTakePicker: View {
    let takes: [SourceMedia]
    let folder: URL
    let destinationTitle: String
    let insert: ([SourceMedia]) -> Void
    @State private var selected: [UUID] = []

    private func label(_ take: SourceMedia) -> some View {
        HStack(spacing: 10) {
            ProjectThumbnail(url: folder.appendingPathComponent(take.filename))
                .frame(width: 54, height: 40).clipShape(RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 2) {
                Text(take.originalName ?? take.recordedAt.formatted(date: .abbreviated, time: .standard))
                    .lineLimit(2).truncationMode(.middle)
                Text(editorTime(take.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
    var body: some View {
        let byID = Dictionary(uniqueKeysWithValues: takes.map { ($0.id, $0) })
        let ordered = selected.compactMap { byID[$0] }
        List {
            if !ordered.isEmpty {
                Section("Playback order") {
                    ForEach(Array(ordered.enumerated()), id: \.element.id) { i, take in
                        Button {
                            selected.removeAll { $0 == take.id }
                        } label: {
                            HStack(spacing: 12) {
                                Text("\(i + 1)").font(.body.monospacedDigit().weight(.semibold)).foregroundStyle(.tint)
                                label(take).foregroundStyle(.primary)
                                Spacer(); Image(systemName: "xmark.circle").foregroundStyle(.secondary)
                            }.frame(minHeight: 44).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        .accessibilityHint("Remove from this selection")
                        .accessibilityIdentifier("addVideo.ordered." + String(i + 1))
                    }
                    .onMove { from, to in selected.move(fromOffsets: from, toOffset: to) }
                }
            }
            let available = takes.filter { !selected.contains($0.id) }
            if !available.isEmpty {
                Section {
                    // Give available and selected rows distinct identities: only the selected cells have reorder controls.
                    ForEach(available, id: \.id.uuidString) { take in
                        Button {
                            selected.append(take.id)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "plus.circle").foregroundStyle(.tint)
                                label(take).foregroundStyle(.primary)
                                Spacer()
                            }.frame(minHeight: 44).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        .accessibilityIdentifier("addVideo.take." + take.id.uuidString)
                    }
                } header: { Text("Available takes") } footer: {
                    Text("Tap takes in playback order. Drag the selected rows to rearrange them.")
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Unused takes").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(ordered.isEmpty ? "Insert" : "Insert \(ordered.count)") { insert(ordered) }
                    .disabled(ordered.isEmpty).accessibilityIdentifier("addVideo.insertTakes")
                    .accessibilityHint(destinationTitle)
            }
        }
    }
}
