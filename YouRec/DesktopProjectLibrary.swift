#if targetEnvironment(macCatalyst)
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    static let desktopProjectSettings = Notification.Name("YouRec.desktopProjectSettings")
}

@objc(YouRecFinderServing) protocol YouRecFinderServing {
    static func reveal(_ url: NSURL)
    @objc(observeWheel:) static func observeWheel(_ handler: @escaping (CGPoint, CGFloat) -> Bool) -> AnyObject
    @objc(observeSecondaryClick:) static func observeSecondaryClick(_ handler: @escaping (CGPoint) -> Bool) -> AnyObject
}

@MainActor
final class DesktopProjectLibrary: ObservableObject {
    @Published private(set) var location: URL?
    @Published private(set) var migrationNotice: String?
    @Published var error: String?
    @Published var canSwitch = false
    private let defaults: UserDefaults
    private let initialFolder: URL
    private let legacyFolder: URL
    private let bookmarkKey = "desktopLibraryBookmark"
    private let pathKey = "desktopLibraryPath"
    private var scoped: URL?
    static let defaultFolder = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        .resolvingSymlinksInPath().appendingPathComponent("YouRec", isDirectory: true)

    var displayPath: String { location?.path ?? defaults.string(forKey: pathKey) ?? Self.defaultFolder.path }

    init() {
        #if DEBUG
        if let run = ProcessInfo.processInfo.environment["YOUREC_LIBRARY_TEST_RUN"], UUID(uuidString: run) != nil {
            defaults = UserDefaults(suiteName: "YouRec.LibraryTest." + run)!
            let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryTest-" + run)
            initialFolder = fixture.appendingPathComponent("YouRec", isDirectory: true)
            legacyFolder = fixture.appendingPathComponent("Legacy", isDirectory: true)
        } else {
            defaults = .standard
            initialFolder = Self.defaultFolder
            legacyFolder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        }
        #else
        defaults = .standard
        initialFolder = Self.defaultFolder
        legacyFolder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #endif
        do {
            if let data = defaults.data(forKey: bookmarkKey) {
                var stale = false
                let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                                  relativeTo: nil, bookmarkDataIsStale: &stale)
                try activate(url, fromPicker: true, refreshBookmark: stale)
            } else {
                try activate(initialFolder, fromPicker: false, refreshBookmark: false)
            }
        } catch { self.error = error.localizedDescription }
    }

    func choose(_ url: URL) throws {
        try activate(url, fromPicker: true, refreshBookmark: true)
    }

    private func activate(_ url: URL, fromPicker: Bool, refreshBookmark: Bool) throws {
        let fm = FileManager.default
        let access = fromPicker && url.startAccessingSecurityScopedResource()
        var adopted = false
        defer { if access && !adopted { url.stopAccessingSecurityScopedResource() } }
        let base = url.resolvingSymlinksInPath().standardizedFileURL
        if fromPicker {
            guard try base.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw CocoaError(.fileNoSuchFile) }
        } else {
            try fm.createDirectory(at: base, withIntermediateDirectories: true)
        }
        // Refuse project interiors. Creating a library inside a project's media
        // folder would cause ordinary deletion of that project to remove both.
        var parent = base
        while parent.path != "/" {
            let enclosingLibrary = parent.deletingLastPathComponent()
            let insideLibrary = ["Projects", "RecentlyDeleted"].contains(parent.lastPathComponent)
                && fm.fileExists(atPath: enclosingLibrary.appendingPathComponent("Projects").path)
                && fm.fileExists(atPath: enclosingLibrary.appendingPathComponent("RecentlyDeleted").path)
            if insideLibrary || fm.fileExists(atPath: parent.appendingPathComponent("project.json").path) {
                throw NSError(domain: "YouRec.Library", code: 1, userInfo: [NSLocalizedDescriptionKey: "Choose the folder that contains Projects and RecentlyDeleted, or choose a separate folder for a new library."])
            }
            parent = parent.deletingLastPathComponent()
        }
        for name in ["Projects", "RecentlyDeleted"] {
            let folder = base.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            // Directory enumeration can be denied even when the folder exists.
            _ = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            guard fm.isWritableFile(atPath: folder.path) else { throw CocoaError(.fileWriteNoPermission) }
        }
        let bookmark = refreshBookmark ? try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) : nil
        var notice: String?
        if !defaults.bool(forKey: "desktopLegacyProjectsMigrated") {
            do {
                try Self.migrateProjects(from: legacyFolder, to: base)
                defaults.set(true, forKey: "desktopLegacyProjectsMigrated")
            } catch {
                notice = "Some earlier projects are still in " + legacyFolder.path + ". " + error.localizedDescription
            }
        }
        if let bookmark { defaults.set(bookmark, forKey: bookmarkKey) }
        defaults.set(base.path, forKey: pathKey)
        scoped?.stopAccessingSecurityScopedResource()
        scoped = access ? url : nil
        adopted = true
        error = nil
        migrationNotice = notice
        location = base
    }

    // Publish one whole project at a time. FileManager can implement moves as
    // copy/delete across volumes, so stage an independent copy there first.
    static func migrateProjects(from old: URL, to new: URL) throws {
        let fm = FileManager.default
        let old = old.standardizedFileURL.resolvingSymlinksInPath(), new = new.standardizedFileURL.resolvingSymlinksInPath()
        guard old.path != new.path else { return }
        for name in ["Projects", "RecentlyDeleted"] {
            let source = old.appendingPathComponent(name, isDirectory: true)
            guard fm.fileExists(atPath: source.path) else { continue }
            let dest = new.appendingPathComponent(name, isDirectory: true)
            for item in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
                let info = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard UUID(uuidString: item.lastPathComponent) != nil, info.isDirectory == true, info.isSymbolicLink != true else { continue }
                let target = dest.appendingPathComponent(item.lastPathComponent, isDirectory: true)
                guard !fm.fileExists(atPath: target.path) else { throw CocoaError(.fileWriteFileExists) }
                let srcVolume = try item.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
                let dstVolume = try dest.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
                if let srcVolume, let dstVolume, srcVolume.isEqual(dstVolume) {
                    try fm.moveItem(at: item, to: target)
                } else {
                    // The original remains recoverable even if copying is interrupted.
                    let stage = dest.appendingPathComponent(".yourec-legacy-copy-" + UUID().uuidString, isDirectory: true)
                    defer { try? fm.removeItem(at: stage) }
                    try fm.copyItem(at: item, to: stage)
                    try fm.moveItem(at: stage, to: target)
                    // On another volume, keep the legacy original as a backup.
                }
            }
        }
    }

    static let nativeServices: YouRecFinderServing.Type? = {
        guard let plugins = Bundle.main.builtInPlugInsURL,
              let bundle = Bundle(url: plugins.appendingPathComponent("FinderIntegration.bundle")) else { return nil }
        return bundle.principalClass as? YouRecFinderServing.Type
    }()

    static func reveal(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path), let service = nativeServices else { return false }
        service.reveal(url as NSURL)
        return true
    }
}

struct DesktopLibraryRoot: View {
    @StateObject private var library = DesktopProjectLibrary()
    @State private var settings = false
    @State private var selecting = false

    var body: some View {
        Group {
            if let location = library.location {
                ContentView(projectDirectory: location).id(location)
                    .environmentObject(library)
                    .safeAreaInset(edge: .top) {
                        if let notice = library.migrationNotice {
                            Text(notice).font(.callout).padding(8).frame(maxWidth: .infinity).background(.bar)
                        }
                    }
            } else {
                ContentUnavailableView {
                    Label("Open your projects folder", systemImage: "folder")
                } description: {
                    Text("YouRec needs access to " + library.displayPath + ". Choose it in Finder or open another projects folder.")
                } actions: {
                    Button("Open Settings…") { settings = true }.buttonStyle(.borderedProminent)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .desktopProjectSettings)) { _ in settings = true }
        .sheet(isPresented: $settings) {
            NavigationStack {
                Form {
                    Section {
                        Text(library.displayPath).textSelection(.enabled).accessibilityIdentifier("library.path")
                        Button("Change Folder…") { selecting = true }
                            .disabled(library.location != nil && !library.canSwitch)
                            .accessibilityIdentifier("library.change")
                    } header: {
                        Text("Projects folder")
                    } footer: {
                        Text(library.location != nil && !library.canSwitch
                             ? "Return to Projects and finish any active operation to change folders."
                             : "YouRec opens the projects in the folder you choose. Projects in your previous folder stay there.")
                    }
                    if let notice = library.migrationNotice { Text(notice).foregroundStyle(.secondary) }
                    if let error = library.error { Text(error).foregroundStyle(.red) }
                }
                .navigationTitle("Settings")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { settings = false } } }
                .fileImporter(isPresented: $selecting, allowedContentTypes: [.folder]) { result in
                    do { try library.choose(result.get()) }
                    catch where (error as NSError).code == NSUserCancelledError {}
                    catch { library.error = error.localizedDescription }
                }
                .fileDialogDefaultDirectory(library.location ?? DesktopProjectLibrary.defaultFolder.deletingLastPathComponent())
            }.frame(minWidth: 430, minHeight: 260)
        }
    }
}
#endif
