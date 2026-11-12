import SwiftUI
import AVFoundation
import PhotosUI

@MainActor
final class ProjectStore: ObservableObject {
    @Published private(set) var projects: [Project] = []
    @Published private(set) var deletedProjects: [Project] = []
    @Published private(set) var deletionRecords: [UUID: ProjectDeletion] = [:]
    @Published var selectedID: UUID?
    @Published var clipboards: [UUID: [TimelineClip]] = [:]
    @Published var trackClipboards: [UUID: TimelineClipboard] = [:]
    @Published private(set) var unsavedDrafts: [UUID: Project] = [:]
    @Published private(set) var journaledDrafts = Set<UUID>()
    @Published var error: String?
    @Published private(set) var recovering = false
    @Published private(set) var recoveringIDs = Set<UUID>()
    @Published private(set) var unavailableProjects: [UUID: String] = [:]
    @Published var recoveryMessages: [UUID: String] = [:]
    @Published var importing = false {
        didSet {
            RecordingAppDelegate.keepAwake("project-transfer", active: importing)
            if importing && backgroundTask == .invalid {
                backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish project transfer") { [weak self] in
                    Task { @MainActor in self?.cancelOperation() }
                }
            } else if !importing && backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid
            }
        }
    }
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @Published var operationProgress = 0.0
    @Published var operationLabel = ""
    @Published var archiveURL: URL?
    private var operation: Task<Void, Never>?
    private var photoTransfer: Progress?
    let disk: ProjectDisk
    private let selectionKey:String
    var selected: Project? { projects.first { $0.id == selectedID } }

    // A process can die during an explicit recovery copy. Only unpublished
    // copies live here. Run once so a second store cannot erase an active copy.
    private static let recoveryWorkspace: URL = {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("YouRecRecoveryCopies", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        return folder
    }()

    init() {
        _ = Self.recoveryWorkspace
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #if DEBUG
        let retentionFixture = CommandLine.arguments.contains("--retention-ui-fixture")
        let recorderFixture = CommandLine.arguments.contains("--recorder-controls-test") || CommandLine.arguments.contains("--dual-capture-ui-test")
        let isolated=CommandLine.arguments.contains("--depth-ui-fixture")
        let editorFixture = CommandLine.arguments.contains("--editor-preview") || CommandLine.arguments.contains("--front-landscape-selftest") || CommandLine.arguments.contains("--tracks-selftest") || CommandLine.arguments.contains("--subtitle-selftest")
        #else
        let retentionFixture = false
        let recorderFixture = false
        let isolated=false
        let editorFixture = false
        #endif
        selectionKey=recorderFixture ? "selectedRecorderUIProject" : retentionFixture ? "selectedRetentionUIProject" : isolated ? "selectedDepthUIProject" : editorFixture ? "selectedEditorUIProject" : "selectedProject"
        var storeBase = documents
        #if DEBUG
        if editorFixture, let value = ProcessInfo.processInfo.environment["YOUREC_RECOVERY_TEST_RUN"], let run = UUID(uuidString: value) {
            storeBase = documents.appendingPathComponent("RecoveryUITestSessions/" + run.uuidString)
        }
        #endif
        disk = ProjectDisk(root: storeBase.appendingPathComponent(recorderFixture ? "RecorderUITestProjects" : retentionFixture ? "RetentionUITestProjects" : isolated ? "CinematicUITestProjects" : editorFixture ? "EditorUITestProjects" : "Projects", isDirectory: true))
        // Archives are transient share payloads; never accumulate full copies in Documents.
        let shareFolder = FileManager.default.temporaryDirectory.appendingPathComponent("YouRecArchives", isDirectory: true)
        try? FileManager.default.removeItem(at: shareFolder)
        do {
            #if DEBUG
            if editorFixture, CommandLine.arguments.contains("--recovery-originals-fixture"),
               let video = Bundle.main.url(forResource: "editor-fixture", withExtension: "mp4") {
                let dir = disk.folder(UUID(uuidString: "134DFF48-A310-4C9B-AB49-E0F6FBDF8292")!)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let movie = dir.appendingPathComponent("Original QA interview.mp4")
                if !FileManager.default.fileExists(atPath: movie.path) { try FileManager.default.copyItem(at: video, to: movie) }
                try Data("{".utf8).write(to: dir.appendingPathComponent("project.json"))
            }
            if retentionFixture && CommandLine.arguments.contains("--reset-retention-fixture") {
                try? FileManager.default.removeItem(at: disk.root)
                try? FileManager.default.removeItem(at: disk.deletedRoot)
                let now = Date(), calendar = Calendar.current
                for (title, age) in [("Active project", -1), ("Old deleted project", 40), ("Recent deleted project", 5), ("Unknown deletion date", 60)] {
                    let project = Project(title: title)
                    try disk.save(project)
                    if age >= 0 {
                        try disk.moveToDeleted(project, now: calendar.date(byAdding: .day, value: -age, to: now)!)
                        if title == "Unknown deletion date" {
                            try FileManager.default.removeItem(at: disk.deletedRoot.appendingPathComponent(project.id.uuidString).appendingPathComponent(".yourec-deletion.json"))
                        }
                    }
                }
                if CommandLine.arguments.contains("--retention-corrupt-fixture") {
                    let secondOld = Project(title: "Second old deleted project")
                    try disk.save(secondOld)
                    try disk.moveToDeleted(secondOld, now: calendar.date(byAdding: .day, value: -45, to: now)!)
                    let project = Project(title: "Unreadable deletion date")
                    try disk.save(project); try disk.moveToDeleted(project)
                    try Data("broken receipt".utf8).write(to: disk.deletedRoot.appendingPathComponent(project.id.uuidString).appendingPathComponent(".yourec-deletion.json"))
                }
            }
            #endif
            try FileManager.default.createDirectory(at: disk.root, withIntermediateDirectories: true)
            ProjectArchive.discardInterruptedRestores(in: disk)
            for folder in try FileManager.default.contentsOfDirectory(at: disk.root, includingPropertiesForKeys: nil) {
                let manifest = folder.appendingPathComponent("project.json")
                guard let id = UUID(uuidString: folder.lastPathComponent),
                      let info = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      info.isDirectory == true, info.isSymbolicLink != true else { continue }
                if TakeReceipt.reclaimAbandonedReserves(in: folder) > 0 {
                    recoveryMessages[id] = "A recording was interrupted before a movie file was available."
                }
                RecordingSalvage.clearUnpublishedCopies(in: folder)
                if !FileManager.default.fileExists(atPath: manifest.path),
                   FileManager.default.fileExists(atPath: folder.appendingPathComponent(".yourec-importing").path),
                   disk.originals(in: id, project: nil).isEmpty { continue }
                do {
                    let opened = try disk.openRecovering(manifest, summary: true)
                    let project = opened.project
                    if let notice = opened.notice { recoveryMessages[id] = notice }
                    let pending: Project?
                    do { pending = try disk.pendingDraft(for: id) }
                    catch { pending = nil; recoveryMessages[id] = "The saved project opened. Its pending edit journal could not be read." }
                    if let draft = pending {
                        projects.append(draft); unsavedDrafts[id] = draft; journaledDrafts.insert(id)
                        recoveryMessages[id] = "Recovered your pending edits. Retry save to commit them."
                    } else { projects.append(project) }
                    guard opened.notice == nil, pending == nil else { continue }
                    try VideoBatchImport.recover(in: project, folder: folder)
                    // These are exclusively generated working files; originals,
                    // manifests, and completed exports are never cleaned here.
                    for name in ["Processing", "Previews"] {
                        let cache = folder.appendingPathComponent(name, isDirectory: true)
                        if FileManager.default.fileExists(atPath: cache.path) { try? FileManager.default.removeItem(at: cache) }
                    }
                }
                catch {
                    if !projects.contains(where: { $0.id == id }) { unavailableProjects[id] = error.localizedDescription }
                    else { recoveryMessages[id] = error.localizedDescription }
                }
            }
            disk.finishPendingDeletions()
            deletedProjects = ((try? FileManager.default.contentsOfDirectory(at: disk.deletedRoot, includingPropertiesForKeys: nil)) ?? []).compactMap { folder in
                guard let id = UUID(uuidString: folder.lastPathComponent),
                      let project = try? disk.read(folder.appendingPathComponent("project.json"), summary: true), project.id == id else { return nil }
                return project
            }
            refreshDeletionRecords()
            sort()
            if let saved = UserDefaults.standard.string(forKey: selectionKey), let id = UUID(uuidString: saved),
               projects.contains(where: { $0.id == id }) {
                if !select(id) { error = (error ?? "") + " Choose a project in Projects or record a new project." }
            } else if let id = projects.first?.id { select(id) }
        } catch { self.error = error.localizedDescription }
    }

    @discardableResult func create() -> Project? {
        let title = Date().formatted(.dateTime.month(.abbreviated).day()) + " · " + Date().formatted(date: .omitted, time: .shortened)
        let project = Project(title: title)
        do { try disk.save(project); projects.insert(project, at: 0); select(project.id); return project }
        catch { self.error = error.localizedDescription; return nil }
    }
    func retryUnavailableProjects() {
        for id in Array(unavailableProjects.keys) {
            do {
                let opened = try disk.openRecovering(disk.folder(id).appendingPathComponent("project.json"))
                if !projects.contains(where: { $0.id == id }) { projects.append(opened.project) }
                unavailableProjects[id] = nil
                recoveryMessages[id] = opened.notice ?? "The project is available again."
            } catch { unavailableProjects[id] = error.localizedDescription }
        }
        sort()
    }
    private func hydrated(_ project: Project) throws -> Project {
        guard let deferred = project.deferredHistory else { return project }
        let opened = try disk.openRecovering(deferred.manifest)
        if let notice = opened.notice { recoveryMessages[project.id] = notice }
        return opened.project
    }
    func openProject(_ id: UUID) -> Bool {
        guard let index = projects.firstIndex(where: { $0.id == id }) else {
            error = "This project is no longer available."
            return false
        }
        do { projects[index] = try hydrated(unsavedDrafts[id] ?? projects[index]) }
        catch {
            self.error = "Could not open “\(projects[index].title)”. " + error.localizedDescription
            return false
        }
        return true
    }
    @discardableResult
    func select(_ id: UUID) -> Bool {
        guard openProject(id) else { return false }
        selectedID = id
        UserDefaults.standard.set(id.uuidString, forKey: selectionKey)
        return true
    }
    @discardableResult
    func update(_ id: UUID, _ change: (inout Project) -> Void) -> Bool {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return false }
        do {
            var candidate = try hydrated(unsavedDrafts[id] ?? projects[index]); change(&candidate)
            try candidate.validate()
            do {
                try disk.save(candidate)
                // A second edit during a long application should resume the latest
                // saved timeline. Undoing the effect retires the old receipt.
                let folder = folder(candidate)
                if let old = EffectApplicationReceipt.pending(for: projects[index], in: folder),
                   let tool = VideoTool(rawValue: old.tool) {
                    if var next = EffectApplicationReceipt(project: candidate, tool: tool) {
                        next.latestEdit = old.latestEdit && candidate.edit == projects[index].edit
                        try? next.save(in: folder)
                    }
                    else { old.finish(in: folder) }
                }
                unsavedDrafts[id] = nil; projects[index] = candidate; sort()
            }
            catch { retainDraft(candidate, failure: error); return false }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func retrySaves() {
        var failures: [String] = []
        for (id, draft) in unsavedDrafts {
            guard projects.contains(where: { $0.id == id }) else { unsavedDrafts[id] = nil; continue }
            do { try disk.save(draft); if let index = projects.firstIndex(where: { $0.id == id }) { projects[index] = draft }; unsavedDrafts[id] = nil }
            catch { failures.append(draft.title + ": " + error.localizedDescription) }
        }
        journaledDrafts.formIntersection(unsavedDrafts.keys)
        error = failures.isEmpty ? nil : failures.joined(separator: "\n"); sort()
    }
    private func retainDraft(_ draft: Project, failure: Error) {
        unsavedDrafts[draft.id] = draft
        if let index = projects.firstIndex(where: { $0.id == draft.id }) { projects[index] = draft }
        do {
            try disk.journalDraft(draft); journaledDrafts.insert(draft.id)
            error = "Changes not saved. A recovery copy of the edits was written. " + failure.localizedDescription
        } catch {
            journaledDrafts.remove(draft.id)
            self.error = "Changes are only in memory. Keep YouRec open and retry the save. " + failure.localizedDescription
        }
    }
    func rename(_ project: Project, title: String) {
        let value = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        guard !value.isEmpty else { return }
        update(project.id) { $0.title = value; $0.updatedAt = Date() }
    }
    func moveToDeleted(_ project: Project) {
        guard !importing else { return }
        do {
            if let draft = unsavedDrafts[project.id] {
                do { try disk.save(draft) }
                catch {
                    self.error = "Save the pending edits before moving “\(draft.title)” to Recently Deleted. " + error.localizedDescription
                    return
                }
            }
            try disk.moveToDeleted(project)
            unsavedDrafts[project.id] = nil
            projects.removeAll { $0.id == project.id }; deletedProjects.insert(try disk.read(disk.deletedRoot.appendingPathComponent(project.id.uuidString).appendingPathComponent("project.json"), summary: true), at: 0)
            deletionRecords[project.id] = try disk.deletionRecord(for: project.id)
            if selectedID == project.id { selectedID = nil; if let id = projects.first?.id { select(id) } }
        } catch { self.error = error.localizedDescription }
    }
    func restoreDeleted(_ project: Project) {
        do {
            try disk.restoreDeleted(project)
            deletionRecords[project.id] = nil
            deletedProjects.removeAll { $0.id == project.id }; projects.append(try disk.read(disk.folder(project.id).appendingPathComponent("project.json"), summary: true)); sort(); select(project.id)
        } catch { self.error = error.localizedDescription }
    }
    func eraseDeleted(_ project: Project) {
        guard !importing else { return }
        do {
            try disk.eraseDeleted(project.id)
            deletedProjects.removeAll { $0.id == project.id }; deletionRecords[project.id] = nil
        } catch { self.error = error.localizedDescription }
    }
    private func refreshDeletionRecords(now: Date = Date()) {
        var records: [UUID: ProjectDeletion] = [:]
        for project in deletedProjects {
            do { records[project.id] = try disk.deletionRecord(for: project.id, firstSeenAt: now) }
            catch { /* Keep this project out of bulk cleanup; manual Restore/Delete remain available. */ }
        }
        deletionRecords = records
        deletedProjects.sort { first, second in
            let a = records[first.id], b = records[second.id]
            if (a?.dateIsKnown ?? false) != (b?.dateIsKnown ?? false) { return a?.dateIsKnown == true }
            let left = a?.date ?? .distantPast, right = b?.date ?? .distantPast
            return left == right ? first.id.uuidString < second.id.uuidString : left > right
        }
    }
    func expiredDeletions(now: Date = Date()) -> [ProjectDeletion] {
        refreshDeletionRecords(now: now)
        return deletedProjects.compactMap { deletionRecords[$0.id] }.filter { $0.isOlderThan30Days(at: now) }
    }
    func eraseExpiredDeletions(_ confirmed: [ProjectDeletion], now: Date = Date()) {
        guard !importing else { return }
        var failures: [String] = []
        for record in confirmed where deletedProjects.contains(where: { $0.id == record.id }) {
            do {
                if try disk.eraseExpiredDeletion(record, now: now) {
                    deletedProjects.removeAll { $0.id == record.id }; deletionRecords[record.id] = nil
                }
            } catch { failures.append(error.localizedDescription) }
        }
        if !failures.isEmpty { error = "Some deleted projects could not be removed. They remain in Recently deleted. " + failures[0] }
    }
    func missingSources(_ project: Project) -> [SourceMedia] {
        project.sources.filter { !FileManager.default.fileExists(atPath: mediaURL(project, $0).path) }
    }
    @discardableResult
    func commit(_ id: UUID, _ edit: EditState) -> Bool {
        guard let current = unsavedDrafts[id] ?? projects.first(where: { $0.id == id }) else { return false }
        guard current.canCommit(edit) else { error = "A new recording was inserted while this tool was open. Reopen the tool to edit the updated timeline."; return false }
        return update(id) { $0.commit(edit) }
    }
    func folder(_ project: Project) -> URL { disk.folder(project.id) }
    func mediaURL(_ project: Project, _ source: SourceMedia) -> URL { folder(project).appendingPathComponent(source.filename) }
    private func sort() { projects.sort { $0.updatedAt > $1.updatedAt } }

    func addRecording(_ url: URL, to id: UUID, recovering: Bool = false, preservePlacement: Bool = true, original: URL? = nil, audioOnly: Bool = false) async -> Bool {
        let capture = original ?? url
        do {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            let video = try await asset.loadTracks(withMediaType: .video)
            guard duration.isFinite, duration > 0, audioOnly || !video.isEmpty else { throw ProjectError.invalidMedia }
            guard let index = projects.firstIndex(where: { $0.id == id }) else { throw ProjectError.invalidDocument }
            if projects[index].sources.contains(where: { $0.filename == url.lastPathComponent }) {
                if unsavedDrafts[id] != nil { retrySaves() }
                return unsavedDrafts[id] == nil
            }
            var uncertain = !preservePlacement
            let receipt: TakeReceipt?
            do { receipt = try TakeReceipt.read(capture, project: id) }
            catch {
                guard error is DecodingError || error is RecoveryError else { throw error }
                receipt = nil; uncertain = true
            }
            var notices: [String] = []
            var candidate = projects[index]
            let eventURL = capture.deletingPathExtension().appendingPathExtension("events.json")
            var events: [CaptureEvent]?
            if FileManager.default.fileExists(atPath: eventURL.path) {
                do { events = CaptureEvent.recovered(try JSONDecoder().decode([CaptureEvent].self, from: Data(contentsOf: eventURL)), duration: duration) }
                catch {
                    guard RecoveryFile.repairable(error) else { throw error }
                    notices.append("Some recording marks could not be read. The original marks file was kept.")
                }
            }
            let recipeURL = capture.deletingPathExtension().appendingPathExtension("effects.json")
            var videoEffects: [VideoEffectSettings]?
            if !audioOnly, FileManager.default.fileExists(atPath: recipeURL.path) {
                do {
                    let data = try Data(contentsOf: recipeURL)
                    let recipe = try JSONDecoder().decode(SupportedVideoEffects.self, from: data).values
                    guard recipe.allSatisfy(\.valid) else { throw ProjectError.invalidDocument }
                    guard recipe.flatMap(\.mediaFiles).allSatisfy({ name in
                        name == URL(fileURLWithPath: name).lastPathComponent &&
                            FileManager.default.fileExists(atPath: capture.deletingLastPathComponent().appendingPathComponent(name).path)
                    }) else { throw ProjectError.missingMedia }
                    videoEffects = recipe.isEmpty ? nil : VideoEffectSettings.capturedRecipe(recipe,duration:duration)
                } catch {
                    guard RecoveryFile.repairable(error) else { throw error }
                    notices.append("The original recording is available. Its saved effects could not be read. The effects file was kept.")
                }
            }
            try await Task.detached(priority: .utility) { try RecoveryFile.syncFile(url) }.value
            let hash = try await SourceMediaCache.shared.fingerprint(url)
            // Re-read after hashing: the actor can yield while the user edits.
            guard let current = projects.first(where: { $0.id == id }) else { throw ProjectError.invalidDocument }
            candidate = try hydrated(unsavedDrafts[id] ?? current)
            if candidate.sources.contains(where: { $0.filename == url.lastPathComponent }) { return unsavedDrafts[id] == nil }
            let source = SourceMedia(id: receipt?.segmentID ?? UUID(), filename: url.lastPathComponent, duration: duration,
                                     recordedAt: receipt?.started ?? Date(), events: events, sha256: hash, videoEffects: videoEffects, audioOnly: audioOnly ? true : nil)
            let placed = try candidate.indexTake(source, receipt: receipt, uncertain: uncertain)
            if !placed { notices.append("The take is in Original recordings. Choose where to insert it.") }
            try candidate.validate()
            do { try disk.save(candidate); unsavedDrafts[id] = nil }
            catch { retainDraft(candidate, failure: error); return false }
            if let currentIndex = projects.firstIndex(where: { $0.id == id }) { projects[currentIndex] = candidate }
            try? receipt?.markIndexed(capture)
            if recovering { notices.insert("Recovered " + duration.formatted(.number.precision(.fractionLength(1))) + " s. The length of any missing ending is unknown.", at: 0) }
            if !notices.isEmpty { recoveryMessages[id] = notices.joined(separator: " ") }
            sort()
            return true
        } catch {
            self.error = error.localizedDescription; return false
        }
    }

    func insertVideos(_ items: [PhotosPickerItem], into id: UUID, at position: Double, site: VideoInsertionSite? = nil,
                      completion: @escaping (Result<Double, Error>) -> Void) {
        guard !importing, !items.isEmpty, let project = projects.first(where: { $0.id == id }) else {
            completion(.failure(ProjectError.invalidDocument)); return
        }
        importing = true; operationProgress = 0
        operationLabel = "Loading 1 of \(items.count) from Photos…"
        operation = Task {
            var preparingIndex: Int?
            let result: Result<Double, Error>
            do {
                let batchFolder = folder(project)
                var batch = try VideoBatchImport(folder: batchFolder)
                defer { batch.discard() }
                for (i, item) in items.enumerated() {
                    preparingIndex = i
                    try Task.checkCancellation()
                    let count = "\(i + 1) of \(items.count)"
                    operationLabel = "Loading " + count + " from Photos…"
                    let media = try await loadSelectedMedia(item)
                    defer { try? FileManager.default.removeItem(at: media.url) }
                    operationLabel = media.isPhoto ? "Creating photo clip " + count + "…" : "Checking video " + count + "…"
                    operationProgress = (Double(i) + 0.5) / Double(items.count + 1)
                    try await batch.stage(privateCopy: media.url, originalName: media.originalName, isPhoto: media.isPhoto)
                    operationProgress = Double(i + 1) / Double(items.count + 1)
                }
                preparingIndex = nil
                operationLabel = "Inserting clips…"
                guard let projectIndex = projects.firstIndex(where: { $0.id == id }) else { throw ProjectError.invalidDocument }
                let current = try hydrated(unsavedDrafts[id] ?? projects[projectIndex])
                let saved = try batch.commit(to: current, at: position, site: site, disk: disk)
                unsavedDrafts[id] = nil; projects[projectIndex] = saved; sort()
                operationProgress = 1
                result = .success(saved.edit.timeline.video.first { $0.content.sourceID == batch.sources.first?.id }?.start.seconds ?? position)
            } catch {
                if Task.isCancelled { result = .failure(CancellationError()) }
                else {
                    let message = preparingIndex.map { "Couldn’t add item \($0 + 1) of \(items.count)." } ?? "Couldn’t insert the clips."
                    result = .failure(NSError(domain: "YouRec.VideoImport", code: 1,
                                              userInfo: [NSLocalizedDescriptionKey: message + " " + error.localizedDescription]))
                }
            }
            operation = nil; importing = false
            completion(result)
        }
    }

    private func loadSelectedMedia(_ item: PhotosPickerItem) async throws -> ImportedPhotoMedia {
        try Task.checkCancellation()
        defer { photoTransfer = nil }
        let media: ImportedPhotoMedia? = try await withCheckedThrowingContinuation { continuation in
            photoTransfer = item.loadTransferable(type: ImportedPhotoMedia.self) { continuation.resume(with: $0) }
        }
        guard let media else { throw ProjectError.invalidMedia }
        return media
    }

    func insertAudio(_ url: URL, into id: UUID, at position: Double) async -> Bool {
        guard !importing, let stored = projects.first(where: { $0.id == id }) else { return false }
        importing = true; operationLabel = "Adding audio…"; operationProgress = 0
        defer { importing = false }
        do {
            let imported = try await ImportedAudioFile.stage(url, in: folder(stored).appendingPathComponent("Processing")) { value in
                Task { @MainActor [weak self] in self?.operationProgress = value * 0.9 }
            }
            defer { try? FileManager.default.removeItem(at: imported.url) }
            try Task.checkCancellation()
            guard let current = projects.first(where: { $0.id == id }) else { throw ProjectError.invalidDocument }
            var candidate = try hydrated(unsavedDrafts[id] ?? current)
            candidate.sources.append(imported.source)
            var edit = candidate.edit
            edit.timeline.insertAudio(imported.source, at: EditTime(min(edit.duration, max(0, position))))
            candidate.commit(edit)
            try candidate.validate()
            let destination = folder(candidate).appendingPathComponent(imported.source.filename)
            try FileManager.default.moveItem(at: imported.url, to: destination)
            do { try disk.save(candidate); unsavedDrafts[id] = nil } catch { try? FileManager.default.removeItem(at: destination); throw error }
            if let index = projects.firstIndex(where: { $0.id == id }) { projects[index] = candidate }; sort()
            operationProgress = 1
            return true
        } catch is CancellationError { return false }
        catch { self.error = "Audio import failed: " + error.localizedDescription; return false }
    }

    func recoverUnindexedRecordings() async {
        guard !recovering else { return }
        recovering = true
        defer { recovering = false; recoveringIDs.removeAll() }
        // Snapshot candidates before yielding. A new capture must never become
        // a recovery candidate while another orphan is being fingerprinted.
        let candidates = projects.map { ($0, (try? disk.unindexedRecordings(in: $0)) ?? []) }
        var autoBudget = RecoverySpace.autoTotalLimit
        for parent in [disk.root, disk.deletedRoot] {
            for folder in (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? [] {
                for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
                where file.lastPathComponent.hasPrefix("recovered-") && file.pathExtension == "mov" {
                    autoBudget = max(0, autoBudget - ((try? RecoverySpace.size(file)) ?? autoBudget))
                }
            }
        }
        recoveringIDs = Set(candidates.filter { !$0.1.isEmpty }.map { $0.0.id })
        for (project, files) in candidates {
            let folder = disk.folder(project.id)
            var unresolved = false
            for file in files {
                guard UIApplication.shared.isProtectedDataAvailable else { unresolved = true; break }
                TakeReceipt.releaseReserve(file)
                let key = RecoveryFile.hash(Data(file.lastPathComponent.utf8))
                let marker = folder.appendingPathComponent(".recovery-attempts/" + key)
                let attempts: Int
                do {
                    if let data = try RecoveryFile.readIfPresent(marker) {
                        attempts = Int(String(decoding: data, as: UTF8.self)) ?? 1
                    } else { attempts = 0 }
                } catch { unresolved = true; continue }
                if attempts >= 2 {
                    recoveryMessages[project.id] = "Automatic repair was interrupted. You can review and save the original recordings."
                    unresolved = true; continue
                }
                do {
                    try RecoveryFile.write(Data(String(attempts + 1).utf8), to: marker)
                    defer { try? FileManager.default.removeItem(at: marker) }
                    var url = file
                    let info: RecordingSalvage.Media
                    var partial = false
                    do { info = try await RecordingSalvage.inspect(file) }
                    catch {
                        guard UIApplication.shared.isProtectedDataAvailable, RecordingSalvage.mediaFailure(error) else { throw error }
                        url = folder.appendingPathComponent("recovered-" + key + ".mov")
                        let estimated = try RecordingSalvage.copyBudget(for: file)
                        if !FileManager.default.fileExists(atPath: url.path), estimated > min(RecoverySpace.autoFileLimit, autoBudget) {
                            try disk.quarantineRecording(file, in: project)
                            recoveryMessages[project.id] = "This interrupted take needs a repair copy. Review the original to see the space required."
                            continue
                        }
                        do {
                            info = try await RecordingSalvage.repair(file, to: url); partial = true
                            autoBudget = max(0, autoBudget - ((try? RecoverySpace.size(url)) ?? estimated))
                        }
                        catch {
                            guard RecordingSalvage.mediaFailure(error), UIApplication.shared.isProtectedDataAvailable else { throw error }
                            try disk.quarantineRecording(file, in: project)
                            recoveryMessages[project.id] = "An unfinished recording could not be opened. Its original files are available to save."
                            continue
                        }
                    }
                    let saved = await addRecording(url, to: project.id, recovering: true,
                                                   preservePlacement: project.recoveryOrigin == nil,
                                                   original: file, audioOnly: info.audioOnly)
                    if saved && partial {
                        try disk.quarantineRecording(file, in: projects.first { $0.id == project.id } ?? project)
                        recoveryMessages[project.id] = "Recovered " + info.duration.formatted(.number.precision(.fractionLength(1))) +
                            (info.audioOnly ? " s of audio." : " s of playable footage.") + " The interrupted file was kept. The missing duration is unknown."
                    }
                    if !saved { unresolved = true }
                } catch {
                    unresolved = true
                    recoveryMessages[project.id] = "Recovery is pending. " + error.localizedDescription
                }
            }
            if !unresolved, project.recordingInsertion != nil, projects.first(where: { $0.id == project.id })?.recordingInsertion != nil {
                update(project.id) { $0.recordingInsertion = nil; $0.recordingInsertionStep = nil }
            }
            recoveringIDs.remove(project.id)
        }
    }

    func removeRecoveryFile(_ file: URL, project: Project) {
        guard disk.recoveryFiles(in: project).contains(file) else { return }
        do { try FileManager.default.removeItem(at: file.deletingLastPathComponent()); objectWillChange.send() }
        catch { self.error = error.localizedDescription }
    }
    func interruptedRepairs(in project: Project) -> [URL] {
        let directory = folder(project).appendingPathComponent(".recovery-attempts")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path), !entries.isEmpty else { return [] }
        return ((try? disk.unindexedRecordings(in: project)) ?? []).map {
            directory.appendingPathComponent(RecoveryFile.hash(Data($0.lastPathComponent.utf8)))
        }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
    func retryInterruptedRepairs(in project: Project) async {
        guard !recovering else { return }
        do { for marker in interruptedRepairs(in: project) { try FileManager.default.removeItem(at: marker) } }
        catch { self.error = error.localizedDescription; return }
        await recoverUnindexedRecordings()
    }

    func beginImport(_ url: URL) {
        guard !importing else { return }
        importing = true
        operation = Task {
            if url.pathExtension.lowercased() == "zip" { await importArchive(url) }
            else { await importVideo(url) }
        }
    }
    func cancelOperation() { operation?.cancel(); photoTransfer?.cancel() }
    func dismissArchive() {
        if let archiveURL { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }
        archiveURL = nil
    }
    func duplicate(_ project: Project, completed: @escaping (Project) -> Void) {
        guard !importing, let current = projects.first(where: { $0.id == project.id }) else { return }
        importing = true; operationProgress = 0; operationLabel = "Duplicating project…"
        operation = Task {
            defer { operation = nil; importing = false }
            do {
                let original = try hydrated(unsavedDrafts[current.id] ?? current)
                let copy = try await ProjectArchive.duplicate(original, in: disk, title: copyTitle(for: original.title)) { progress in
                    Task { @MainActor [weak self] in self?.operationProgress = progress }
                }
                projects.insert(copy, at: 0); select(copy.id); sort()
                completed(copy)
            } catch is CancellationError {} catch { self.error = "Couldn’t duplicate the project. " + error.localizedDescription }
        }
    }

    private func copyTitle(for title: String) -> String {
        let base = title.replacingOccurrences(of: #" copy(?: [0-9]+)?$"#, with: "", options: [.regularExpression, .caseInsensitive])
        let existing = Set(projects.map { $0.title.lowercased() })
        var number = 1
        while true {
            let suffix = number == 1 ? " copy" : " copy \(number)"
            let candidate = String(base.prefix(120 - suffix.count)) + suffix
            if !existing.contains(candidate.lowercased()) { return candidate }
            number += 1
        }
    }

    func archive(_ project: Project) {
        guard !importing else { return }
        importing = true; operationProgress = 0; operationLabel = "Creating project ZIP…"
        operation = Task {
            defer { importing = false }
            let safeTitle = String(project.title.components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters)).joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "."))).prefix(55))
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("YouRecArchives", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true).appendingPathComponent((safeTitle.isEmpty ? "YouRec project" : String(decoding: safeTitle.utf8.prefix(200), as: UTF8.self)) + ".zip")
            do {
                try await ProjectArchive.export(hydrated(project), folder: folder(project), destination: url) { value in
                    Task { @MainActor [weak self] in self?.operationProgress = value }
                }
                archiveURL = url
            } catch {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
    private func importArchive(_ url: URL) async {
        importing = true; operationProgress = 0; operationLabel = "Restoring project archive…"
        defer { importing = false }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.createDirectory(at: Self.recoveryWorkspace, withIntermediateDirectories: true)
            let local = Self.recoveryWorkspace.appendingPathComponent(UUID().uuidString + ".zip")
            defer { try? FileManager.default.removeItem(at: local) }
            try await ProjectArchive.copyFile(url, to: local) { value in
                Task { @MainActor [weak self] in self?.operationProgress = value * 0.2 }
            }
            let project = try await ProjectArchive.restore(local, disk: disk) { value in
                Task { @MainActor [weak self] in self?.operationProgress = 0.2 + value * 0.8 }
            }
            projects.insert(project, at: 0); select(project.id); sort()
            if !missingSources(project).isEmpty { error = "The project was restored, but some original takes are missing or damaged. Use Repair media to reconnect those originals. All editing history has been kept." }
        } catch is CancellationError {} catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func beginRelink(_ url: URL, source: SourceMedia, project: Project, allowUnverified: Bool = false) {
        guard !importing else { return }
        importing = true; operationProgress = 0; operationLabel = "Checking original take…"
        operation = Task {
            defer { importing = false }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let work = folder(project).appendingPathComponent("Processing", isDirectory: true)
            let temporary = work.appendingPathComponent(UUID().uuidString + "." + url.pathExtension)
            defer { try? FileManager.default.removeItem(at: temporary) }
            do {
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                guard source.sha256 != nil || allowUnverified else {
                    throw NSError(domain: "YouRec", code: 1, userInfo: [NSLocalizedDescriptionKey: "This older take has no saved fingerprint. Confirm that the selected video is its unchanged original before reconnecting it."])
                }
                let destination = mediaURL(project, source)
                guard !FileManager.default.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }
                try await ProjectArchive.copyFile(url, to: temporary) { value in
                    Task { @MainActor [weak self] in self?.operationProgress = value * 0.85 }
                }
                let asset = AVURLAsset(url: temporary)
                let duration = try await asset.load(.duration).seconds
                guard duration.isFinite, abs(duration - source.duration) < 0.05,
                      !(try await asset.loadTracks(withMediaType: source.audioOnly == true ? .audio : .video)).isEmpty else { throw source.audioOnly == true ? AudioImportError.unreadable : ProjectError.invalidMedia }
                let hash = try await SourceMediaCache.shared.fingerprint(temporary)
                if let expected = source.sha256, hash != expected {
                    throw NSError(domain: "YouRec", code: 1, userInfo: [NSLocalizedDescriptionKey: "This is not the original take: its checksum differs. Choose the unchanged original video."])
                }
                try Task.checkCancellation()
                try FileManager.default.moveItem(at: temporary, to: destination)
                update(project.id) { value in
                    if let index = value.sources.firstIndex(where: { $0.id == source.id }) { value.sources[index].sha256 = hash }
                    value.updatedAt = Date()
                }
                operationProgress = 1
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func importVideo(_ url: URL) async {
        importing = true; operationProgress = 0; operationLabel = "Copying original video…"
        defer { importing = false }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        var project = Project(title: String(url.deletingPathExtension().lastPathComponent.prefix(120)))
        let directory = folder(project)
        let destination = directory.appendingPathComponent(UUID().uuidString + "." + url.pathExtension)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data().write(to: directory.appendingPathComponent(".yourec-importing"))
            try await ProjectArchive.copyFile(url, to: destination) { value in
                Task { @MainActor [weak self] in self?.operationProgress = value * 0.9 }
            }
            try Task.checkCancellation()
            operationProgress = 0.9
            let asset = AVURLAsset(url: destination)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0, !(try await asset.loadTracks(withMediaType: .video)).isEmpty else { throw ProjectError.invalidMedia }
            let hash = try await SourceMediaCache.shared.fingerprint(destination)
            project.append(SourceMedia(filename: destination.lastPathComponent, duration: duration, sha256: hash))
            try disk.save(project)
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(".yourec-importing"))
            projects.insert(project, at: 0); select(project.id); sort()
        } catch {
            // Only this import's new directory is removed; its original is untouched.
            try? FileManager.default.removeItem(at: directory)
            if !Task.isCancelled { self.error = "Import failed: " + error.localizedDescription }
        }
    }
}

extension ProjectStore {
    func reinsertOriginal(_ item: OriginalRecording, in id: UUID, start: Double, end: Double) async throws {
        guard let current = projects.first(where: { $0.id == id }),
              let source = current.sources.first(where: { $0.id == item.source?.id }),
              item.url == mediaURL(current, source), start >= 0, end > start, end <= source.duration + 0.001 else { throw ProjectError.invalidMedia }
        guard update(id, { project in
            let clip = TimelineClip(sourceID: source.id, start: start, end: min(end, source.duration), videoEffects: source.videoEffects)
            project.commit(TimelineEditing.inserting([clip], into: project.edit, at: project.edit.duration))
        }) else { throw ProjectError.invalidDocument }
    }

    func makeRecoveredProject(from id: UUID, only selected: URL? = nil) async throws -> String {
        guard !importing, !recoveringIDs.contains(id) else { throw ProjectError.invalidDocument }
        importing = true; operationLabel = "Copying original recordings…"; operationProgress = 0
        defer { importing = false }
        let current = projects.first { $0.id == id }
        let all = disk.originals(in: id, project: current)
        let playableCopies = Set(all.compactMap { $0.source?.filename })
        let items = all.filter { item in
            if let selected { return item.url == selected }
            guard item.url.deletingLastPathComponent() != disk.folder(id) else { return true }
            let copy = "recovered-" + RecoveryFile.hash(Data(item.url.lastPathComponent.utf8)) + ".mov"
            return !playableCopies.contains(copy)
        }
        guard !items.isEmpty else { throw RecoveryError.noMedia }
        let scratch = Self.recoveryWorkspace.appendingPathComponent(id.uuidString, isDirectory: true)
        if FileManager.default.fileExists(atPath: scratch.path) { try FileManager.default.removeItem(at: scratch) }
        let estimate = try items.reduce(Int64(0)) { try $0 + RecordingSalvage.copyBudget(for: $1.url) }
        try RecoverySpace.require(estimate, at: disk.root)
        var project = Project(title: String((current?.title ?? "Recordings").prefix(95)) + " · Recovered")
        let staged = ProjectDisk(root: scratch)
        let dir = staged.folder(project.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        var skipped = 0, partial = 0
        for (index, item) in items.enumerated() {
            try Task.checkCancellation()
            let name = UUID().uuidString
            var dest = dir.appendingPathComponent(name).appendingPathExtension(item.url.pathExtension)
            let media: RecordingSalvage.Media
            var complete: RecordingSalvage.Media?
            do { complete = try await RecordingSalvage.inspect(item.url) }
            catch { if Task.isCancelled { throw CancellationError() } }
            if let complete {
                media = complete
                try await ProjectArchive.copyFile(item.url, to: dest) { _ in }
            } else {
                dest = dir.appendingPathComponent(name + ".mov")
                do { media = try await RecordingSalvage.repair(item.url, to: dest); partial += 1 }
                catch { if error is ProjectError { skipped += 1; continue }; throw error }
            }
            let hash = try await SourceMediaCache.shared.fingerprint(dest, memoize: false)
            let source = SourceMedia(filename: dest.lastPathComponent, duration: media.duration,
                                     recordedAt: item.source?.recordedAt ?? Date(), sha256: hash, audioOnly: media.audioOnly ? true : nil,
                                     originalName: String(item.title.prefix(255)))
            if media.audioOnly {
                project.sources.append(source)
                var edit = project.edit; edit.timeline.insertAudio(source, at: EditTime(edit.duration)); project.commit(edit)
            } else { project.append(source) }
            operationProgress = Double(index + 1) / Double(items.count)
        }
        guard !project.sources.isEmpty else { throw RecoveryError.noMedia }
        try staged.save(project)
        _ = try staged.read(dir.appendingPathComponent("project.json"))
        try FileManager.default.moveItem(at: dir, to: disk.folder(project.id))
        projects.append(project); sort()
        return "Created “" + project.title + "” with \(project.sources.count) recordings." +
            (partial > 0 ? " Recovered readable portions of \(partial) files." : "") +
            (skipped > 0 ? " \(skipped) unreadable files remain with the original project." : "")
    }
}
