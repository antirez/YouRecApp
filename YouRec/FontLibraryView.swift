import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class EditorFonts: ObservableObject {
    static let shared = EditorFonts()
    @Published private(set) var files: [ImportedFontFile] = []
    private(set) var labels: [String: String] = [:]
    private var revision = 0

    func refresh() async throws {
        revision += 1
        let request = revision
        let entries = try await Task.detached { try ImportedFonts.shared.files() }.value
        guard request == revision else { return }
        let names = Dictionary(grouping: entries.flatMap(\.faces), by: \.name)
        labels = Dictionary(uniqueKeysWithValues: entries.flatMap { entry in
            entry.faces.map { face in
                let repeated = (names[face.name]?.count ?? 0) > 1
                return (face.id, repeated ? face.name + " · " + entry.filename : face.name)
            }
        })
        files = entries
    }
}

struct FontLibraryView: View {
    @ObservedObject private var library = EditorFonts.shared
    @Environment(\.dismiss) private var dismiss
    var use: ((ImportedFontFace) -> Void)?
    var draftFace: String?
    var folder: URL?
    @State private var picker = false
    @State private var pending: [URL] = []
    @State private var working = false
    @State private var removal: ImportedFontFile?
    @State private var feedback: String?
    @State private var problem: String?
    @State private var expanded: Set<String> = []

    private static let types: [UTType] = [.font] + ImportedFonts.extensions.compactMap { UTType(filenameExtension: $0) }
    var body: some View {
        List {
            Section {
                Button { picker = true } label: {
                    Label("Import fonts…", systemImage: "plus").frame(minHeight: 44)
                }.disabled(working).accessibilityIdentifier("fonts.add")
                if working { ProgressView("Importing fonts…") }
                if let feedback { Text(feedback).font(.subheadline).foregroundStyle(.secondary) }
            } footer: {
                Text("Choose TrueType (.ttf), OpenType (.otf), or a font collection (.ttc, .otc) from Files.")
            }
            if !library.files.isEmpty {
                Section {
                    ForEach(library.files) { file in fileRow(file) }
                } header: {
                    Text(use == nil ? "Imported fonts" : "Choose a face")
                } footer: {
                    Text("Projects keep a copy of the fonts they use, including in project ZIPs.")
                }
            }
        }
        .navigationTitle("Fonts").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if use != nil { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("fonts.done") } }
        }
        .task {
            do { try await library.refresh() } catch { problem = error.localizedDescription }
        }
        .fileImporter(isPresented: $picker, allowedContentTypes: Self.types, allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): pending = urls
            case .failure(let error): if (error as NSError).code != NSUserCancelledError { problem = error.localizedDescription }
            }
        }
        .task(id: pending) { await importPending() }
        .alert("Font library", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK") { problem = nil }
        } message: { Text(problem ?? "") }
        .confirmationDialog("Remove " + (removal?.filename ?? "font") + "?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), titleVisibility: .visible, presenting: removal) { file in
            Button("Remove from library", role: .destructive) {
                Task {
                    do {
                        let reference = draftFace.flatMap(ImportedFontFace.Reference.init)
                        let folder = self.folder
                        try await Task.detached {
                            if let reference, reference.digest == file.id, let folder {
                                try ImportedFonts.shared.preserve([reference.filename], in: folder)
                            }
                            try ImportedFonts.shared.remove(file)
                        }.value
                        try await library.refresh()
                        feedback = nil
                    } catch { problem = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in Text("Existing projects keep their copy.") }
    }

    private func importPending() async {
        guard !pending.isEmpty else { return }
        let urls = pending; working = true; feedback = nil
        defer { working = false }
        var imported: [ImportedFontFile] = [], added = 0, errors: [String] = []
        for url in urls {
            guard !Task.isCancelled else { return }
            do {
                let result = try await Task.detached(priority: .userInitiated) { try ImportedFonts.shared.add(url) }.value
                imported.append(result.file)
                if result.added { added += 1 }
            } catch { errors.append(url.lastPathComponent + " — " + error.localizedDescription) }
        }
        guard !Task.isCancelled else { return }
        do { try await library.refresh() } catch { errors.append(error.localizedDescription) }
        guard !Task.isCancelled else { return }
        pending = []
        if !errors.isEmpty { problem = errors.joined(separator: "\n") }
        if imported.count == 1, let file = imported.first {
            expanded.insert(file.id)
            feedback = added == 0 ? "Already imported · " + file.filename : "Imported " + file.filename
            if errors.isEmpty, file.faces.count == 1, let use { use(file.faces[0]); dismiss() }
        } else if !imported.isEmpty {
            feedback = "\(added) added · \(imported.count - added) already imported"
        }
    }

    private func fileRow(_ file: ImportedFontFile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if file.faces.count == 1 {
                    faceRow(file.faces[0], file: file)
                } else {
                    Button {
                        if !expanded.insert(file.id).inserted { expanded.remove(file.id) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(file.filename).lineLimit(2)
                                Text("\(file.faces.count) faces").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: expanded.contains(file.id) ? "chevron.up" : "chevron.down").font(.caption)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).frame(minHeight: 44)
                }
                Button(role: .destructive) { removal = file } label: {
                    Image(systemName: "trash").frame(width: 44, height: 44)
                }.buttonStyle(.borderless).accessibilityLabel("Remove " + file.filename)
                    .accessibilityIdentifier("fonts.remove." + file.id)
            }
            if file.faces.count > 1 && expanded.contains(file.id) {
                ForEach(file.faces) { face in Divider(); faceRow(face, file: file).padding(.leading, 12) }
            }
        }
    }

    @ViewBuilder private func faceRow(_ face: ImportedFontFace, file: ImportedFontFile) -> some View {
        let label = HStack(spacing: 12) {
            var style: TitleDesign { var d = TitleDesign(); d.face = face.id; d.weight = face.defaultWeight; return d }
            Text("Aa").font(Font(TitleTypeface.font(style, size: 24))).lineLimit(1)
                .frame(width: 44, height: 40).background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(face.name).font(.body.weight(.medium))
                if file.faces.count == 1 { Text(file.filename).font(.caption).foregroundStyle(.secondary) }
            }
        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
        if let use {
            Button { use(face); dismiss() } label: { label }.buttonStyle(.plain)
                .accessibilityLabel("Use " + face.name).accessibilityIdentifier("fonts.use." + face.id)
        } else { label }
    }
}
