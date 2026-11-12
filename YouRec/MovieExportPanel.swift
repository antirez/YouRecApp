import SwiftUI
import AVFoundation

struct MovieExportPanel: View {
    static let buttonColor = Color(red: 36/255, green: 83/255, blue: 55/255)
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: ProjectStore
    @ObservedObject var editor: EditorController
    let project: Project
    @Binding var dismissedExportAudioWarning: UUID?
    var readingFormat = false
    @State private var exportOptionsOpen = false
    @State private var exportDetent: PresentationDetent = .medium

    private func exportFileActions(previous: Bool) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { shareExportButton(previous: previous).fixedSize(horizontal: true, vertical: false); saveExportButton(previous: previous).fixedSize(horizontal: true, vertical: false) }
            VStack(spacing: 8) { shareExportButton(previous: previous); saveExportButton(previous: previous) }
        }
        .onChange(of: editor.exportURL, initial: true) { _, movie in
            if let movie { editor.exportActionsAppeared(for: movie) }
        }
    }
    @ViewBuilder private func shareExportButton(previous: Bool) -> some View {
        if let url = editor.exportURL {
            ShareLink(item: url) { Label(previous ? "Share previous movie" : "Share latest export", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity, minHeight: 44) }
                .buttonStyle(.borderedProminent).disabled(editor.rendering)
        }
    }
    @ViewBuilder private func saveExportButton(previous: Bool) -> some View {
        if editor.savedToPhotos {
            Label(previous ? "Previous movie saved to Photos" : "Saved to Photos", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).frame(maxWidth: .infinity, minHeight: 44)
        } else {
            Button { editor.saveToPhotos() } label: {
                Label(editor.savingToPhotos ? "Saving…" : previous ? "Save previous movie to Photos" : "Save to Photos", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }.buttonStyle(.borderedProminent).tint(Color(red: 0.16, green: 0.39, blue: 0.78))
                .disabled(editor.savingToPhotos || editor.rendering)
        }
    }
    @ViewBuilder private func exportAudioWarning(_ project: Project) -> some View {
        if !editor.rendering, let receipt = editor.matchingExport(project, folder: store.folder(project)),
           dismissedExportAudioWarning != receipt.id, let warning = receipt.audioWarning {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "speaker.badge.exclamationmark").accessibilityHidden(true).padding(.top, 12)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Audio may distort").font(.subheadline.weight(.semibold))
                    Text(warning).font(.caption)
                }.padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
                Button { dismissedExportAudioWarning = receipt.id } label: {
                    Image(systemName: "xmark").frame(width: 44, height: 44)
                }.buttonStyle(.plain).accessibilityLabel("Dismiss audio warning").accessibilityIdentifier("export.dismissAudioWarning")
            }.foregroundStyle(.orange).padding(.leading, 12)
                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        }
    }
    private func exportOption<Value>(_ key: WritableKeyPath<ExportSettings, Value>, in project: Project) -> Binding<Value> {
        Binding(get: { (store.projects.first { $0.id == project.id } ?? project).exportSettings[keyPath: key] }, set: { value in
            store.update(project.id) { $0.exportSettings[keyPath: key] = value }
        })
    }

    private func exportOptions(_ project: Project) -> some View {
        let settings = project.exportSettings
        let canvas = project.edit.outputSize ?? editor.canvas
        let output = canvas.map(settings.resolution.size(for:))
        let dimensions = output.map { "\(Int($0.width)) × \(Int($0.height))" } ?? settings.resolution.rawValue
        let codec = settings.outputCodec(hdr: editor.exportHDR)
        let summary = readingFormat ? "Reading video format…" : "\(dimensions) · \(settings.frameRate.rawValue) fps · \(codec.rawValue)" + (editor.exportHDR ? " · HDR" : "")
        return VStack(alignment: .leading, spacing: 12) {
            Button {
                if !exportOptionsOpen { exportDetent = .large }
                exportOptionsOpen.toggle()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Export settings").font(.subheadline.weight(.semibold))
                        Text(summary).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: exportOptionsOpen ? "chevron.up" : "chevron.down").font(.caption)
                }.frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("export.settings").accessibilityValue(summary)
            if exportOptionsOpen {
                Divider()
                LabeledContent("Resolution") {
                    Picker("Resolution", selection: exportOption(\.resolution, in: project)) {
                        ForEach(ExportSettings.Resolution.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().accessibilityIdentifier("export.resolution")
                }
                if let output, let canvas, output.width > canvas.width + 1 {
                    Text("Upscaled from \(Int(canvas.width)) × \(Int(canvas.height)).").font(.footnote).foregroundStyle(.secondary)
                }
                LabeledContent("Frame rate") {
                    Picker("Frame rate", selection: exportOption(\.frameRate, in: project)) {
                        ForEach(ExportSettings.FrameRate.allCases, id: \.self) { Text("\($0.rawValue) fps").tag($0) }
                    }.labelsHidden().accessibilityIdentifier("export.rate")
                }
                LabeledContent("Codec") {
                    if editor.exportHDR { Text("H.265 · 10-bit HDR").foregroundStyle(.secondary) }
                    else {
                        Picker("Codec", selection: exportOption(\.codec, in: project)) {
                            Text("H.264 · Compatibility").tag(ExportSettings.Codec.h264)
                            Text("H.265 · HEVC").tag(ExportSettings.Codec.hevc)
                        }.labelsHidden().accessibilityIdentifier("export.codec")
                    }
                }
                if editor.exportPaused {
                    Text("Changing settings starts a fresh export.").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            .disabled(readingFormat || editor.rendering || editor.hasPhotoSaveInFlight)
    }

    private var exportProgressView: some View {
        let progress = editor.exportProgress
        let title = progress.step == .picture && editor.exportUsesAutoBackground ? "Rendering video with Auto Background" : progress.title
        let percent = progress.fraction.formatted(.percent.precision(.fractionLength(0)).rounded(rule: .down))
        let tint: Color = switch progress.step {
        case .opening, .audioEffects, .timeline, .audioPeak: .blue
        case .audio, .picture: .teal
        default: .indigo
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(percent).monospacedDigit().foregroundStyle(.secondary).fixedSize()
            }
            .font(.subheadline.weight(.semibold))
            .accessibilityHidden(true)
            ProgressView(value: progress.fraction)
                .progressViewStyle(.linear).tint(tint)
                .accessibilityLabel(title).accessibilityValue(percent)
                .accessibilityIdentifier("export.progress")
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView { VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.title).font(.headline).accessibilityIdentifier("export.project")
                    Text("\(editorTime(project.edit.duration)) · \(project.edit.clips.count) clips").font(.subheadline).foregroundStyle(.secondary)
                }
                exportOptions(project)
                Text("Your previous export stays available until the new movie is ready.").font(.subheadline)
                if !editor.rendering, editor.exportURL != nil, editor.matchingExport(project, folder: store.folder(project)) == nil {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Previous export").font(.headline)
                        Text("This movie uses the earlier edits and settings.").font(.caption).foregroundStyle(.secondary)
                        exportFileActions(previous: true)
                    }
                }
                Spacer(minLength: 0)
            }.padding(20) }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 10) {
                        if editor.rendering && editor.processingPreview {
                            ProgressView(value: editor.progress) { Text("Preparing audio preview…") }
                            Text("Export will be available when audio processing finishes.").font(.caption).foregroundStyle(.secondary)
                        } else if editor.exportPaused {
                            VStack(alignment: .leading, spacing: 6) {
                                Label("Export paused", systemImage: "pause.circle").font(.headline)
                                Text(editor.exportPauseReason ?? "YouRec left the foreground. Keep it open and the iPhone unlocked while exporting.")
                                if editor.savedExportSeconds > 0 {
                                    Text("Video saved through " + editorTime(editor.savedExportSeconds)).monospacedDigit()
                                }
                            }.font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                            Button { exportOptionsOpen = false; editor.render(project, folder: store.folder(project), preview: false) } label: {
                                Label("Resume export", systemImage: "play.fill").frame(maxWidth: .infinity, minHeight: 44)
                            }.buttonStyle(.borderedProminent).disabled(editor.rendering || editor.hasPhotoSaveInFlight)
                        } else if editor.rendering {
                            exportProgressView
                        } else if editor.matchingExport(project, folder: store.folder(project)) != nil {
                            Label("Exported", systemImage: "checkmark.circle.fill").font(.subheadline.weight(.semibold)).foregroundStyle(.green)
                            exportAudioWarning(project)
                            exportFileActions(previous: false)
                        } else {
                            Button { exportOptionsOpen = false; editor.render(project, folder: store.folder(project), preview: false) } label: {
                                Label("Export video", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity, minHeight: 48)
                            }.buttonStyle(.borderedProminent).disabled(editor.hasPhotoSaveInFlight)
                            if editor.hasPhotoSaveInFlight {
                                Text("Waiting for Photos to finish saving the previous export…").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.padding(16).frame(maxWidth: .infinity).background(.bar)
                        .overlay(alignment: .top) { Divider() }
                }
                .navigationTitle("Export").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) {
                    Button(editor.exportPaused ? "Discard export" : editor.rendering && !editor.processingPreview ? "Cancel" : "Done") {
                        if editor.exportPaused || editor.rendering && !editor.processingPreview { editor.cancel() }
                        else { dismiss() }
                    }
                } }
                .interactiveDismissDisabled(editor.rendering && !editor.processingPreview)
                .onAppear { editor.selectExport(project, folder: store.folder(project)) }
                .onChange(of: project.exportSettings) { _, _ in
                    if editor.exportPaused { editor.restorePausedExport(project, folder: store.folder(project)) }
                    editor.selectExport(project, folder: store.folder(project))
                }
                .onChange(of: project.edit) { _, _ in editor.selectExport(project, folder: store.folder(project)) }
        }
        .presentationDetents([.medium, .large], selection: $exportDetent)
        .presentationDragIndicator(.visible)
    }
}

struct CatalogueMovieExport: View {
    @ObservedObject var store: ProjectStore
    let projectID: UUID
    @StateObject private var editor = EditorController()
    @State private var dismissedWarning: UUID?
    @State private var readingFormat = true

    var body: some View {
        if let project = store.projects.first(where: { $0.id == projectID }) {
            MovieExportPanel(store: store, editor: editor, project: project, dismissedExportAudioWarning: $dismissedWarning, readingFormat: readingFormat)
                .task {
                    await editor.prepareCatalogueExport(project, folder: store.folder(project))
                    if !Task.isCancelled { readingFormat = false }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in editor.pauseExport() }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in editor.pauseExport() }
                .alert("Export", isPresented: Binding(get: { editor.error != nil }, set: { if !$0 { editor.error = nil } })) {
                    Button("OK") { editor.error = nil }
                } message: { Text(editor.error ?? "") }
        }
    }
}
