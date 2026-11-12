import CryptoKit
import Darwin
import Foundation

/// All URLs passed here are app-owned metadata, on the same volume. Publish only
/// after the bytes reach the filesystem; synchronize the containing directory too.
enum RecoveryFile {
    private static let checkedSnapshots = NSCache<NSURL, NSString>()
    static func ensureSnapshot(_ data: Data, at file: URL) throws {
        func stamp() throws -> NSString {
            let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            return
                "\(attrs[.systemFileNumber] ?? 0)-\(attrs[.size] ?? 0)-\((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
                as NSString
        }
        do {
            let stamp = try stamp()
            if checkedSnapshots.object(forKey: file as NSURL) == stamp { return }
            let existing = try Data(contentsOf: file)
            if existing == data {
                checkedSnapshots.setObject(stamp, forKey: file as NSURL)
                return
            }
            let evidence = file.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(".revisions/damaged-history/" + hash(existing) + ".json")
            try write(existing, to: evidence)
        } catch { if !missing(error) { throw error } }
        try write(data, to: file)
        checkedSnapshots.setObject(try stamp(), forKey: file as NSURL)
    }
    static func write(_ data: Data, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = directory.appendingPathComponent(".saving-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        try data.write(to: temp, options: .withoutOverwriting)
        let handle = try FileHandle(forWritingTo: temp)
        do {
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        guard rename(temp.path, destination.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try syncDirectory(directory)
    }
    static func syncDirectory(_ directory: URL) throws {
        let fd = open(directory.path, O_RDONLY)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        if fsync(fd) != 0, errno != EINVAL, errno != ENOTSUP { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    static func syncFile(_ file: URL) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.synchronize()
    }
    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func missing(_ error: Error) -> Bool {
        let e = error as NSError
        return e.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(e.code)
    }
    static func repairable(_ error: Error) -> Bool {
        if error is DecodingError || error is ProjectError || missing(error) { return true }
        let e = error as NSError
        return e.domain == NSCocoaErrorDomain && [NSFileReadCorruptFileError, 3840].contains(e.code)
    }
    static func readIfPresent(_ file: URL) throws -> Data? {
        do { return try Data(contentsOf: file) } catch {
            if missing(error) { return nil }
            throw error
        }
    }
}

enum RecoveryError: LocalizedError {
    case newerProject, identity, noMedia
    var errorDescription: String? {
        switch self {
        case .newerProject: return "This project was saved by a newer YouRec. You can save its original recordings."
        case .identity: return "The project index belongs to a different folder."
        case .noMedia: return "No playable media was found. The original files are available to save."
        }
    }
}

extension ProjectDisk {
    struct Opened {
        var project: Project
        var notice: String?
    }

    private func revisions(in directory: URL) throws -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { file in
                    let parts = file.deletingPathExtension().lastPathComponent.split(separator: "-")
                    guard file.pathExtension == "json", parts.count == 3, parts[0] == "revision",
                        parts[1].count == 19, let generation = Int64(parts[1]), generation >= 0,
                        generation < Int64.max, parts[2].count == 64
                    else { return false }
                    return parts[2].allSatisfy(\.isHexDigit)
                }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
        } catch {
            if RecoveryFile.missing(error) { return [] }
            throw error
        }
    }
    /// Called under the project write lock. Only rotate our own backup files,
    /// keeping immutable history dependencies and pre-migration copies.
    func keepManifest(_ data: Data, in directory: URL, nextSchema: Int) throws {
        let backups = directory.appendingPathComponent(".revisions", isDirectory: true)
        let hash = RecoveryFile.hash(data)
        let header = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let version = header?["schemaVersion"] as? Int {
            guard version <= Project.latestReadableSchema else { throw RecoveryError.newerProject }
            guard (header?["id"] as? String).flatMap(UUID.init(uuidString:)) == UUID(uuidString: directory.lastPathComponent)
            else { throw RecoveryError.identity }
            if version < nextSchema || header?["recordingHistoryVersion"] == nil || header?["automaticCanvasVersion"] == nil
                || header?["snapshotFiles"] == nil
            {
                let migration = backups.appendingPathComponent("schema-\(version)-\(hash).json")
                if !FileManager.default.fileExists(atPath: migration.path) { try RecoveryFile.write(data, to: migration) }
            }
        } else {
            let damaged = backups.appendingPathComponent("damaged-\(hash).json")
            if !FileManager.default.fileExists(atPath: damaged.path) { try RecoveryFile.write(data, to: damaged) }
            return
        }
        let files = try revisions(in: backups)
        if files.first?.lastPathComponent.hasSuffix("-" + hash + ".json") == true { return }
        let last = files.first?.lastPathComponent.split(separator: "-").dropFirst().first.flatMap { Int64($0) } ?? 0
        let name = String(format: "revision-%019lld-", last + 1) + hash + ".json"
        try RecoveryFile.write(data, to: backups.appendingPathComponent(name))
        for stale in files.dropFirst(4) { try? FileManager.default.removeItem(at: stale) }
    }

    func openRecovering(_ file: URL, summary: Bool = false) throws -> Opened {
        let directory = file.deletingLastPathComponent()
        guard let expected = UUID(uuidString: directory.lastPathComponent) else { throw RecoveryError.identity }
        func decode(_ data: Data, summarized: Bool) throws -> Project {
            let p = try Project.readManifest(data, summaryFile: summarized ? file : nil) { name in
                try Data(contentsOf: directory.appendingPathComponent("History/" + name))
            }
            guard p.id == expected else { throw RecoveryError.identity }
            return p
        }
        func open(_ data: Data, summarized: Bool) throws -> Opened {
            do { return Opened(project: try decode(data, summarized: summarized)) } catch {
                guard RecoveryFile.repairable(error) else { throw error }
                guard var header = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw error }
                if (header["schemaVersion"] as? Int ?? 0) > Project.latestReadableSchema { throw RecoveryError.newerProject }
                guard let names = header["snapshotFiles"] as? [String], let cursor = header["historyCursor"] as? Int,
                    names.indices.contains(cursor), names.allSatisfy(Project.isSnapshotName)
                else { throw error }
                func valid(_ index: Int) throws -> Bool {
                    do {
                        let blob = try Data(contentsOf: directory.appendingPathComponent("History/" + names[index]))
                        return RecoveryFile.hash(blob) + ".json" == names[index]
                            && (try? JSONDecoder().decode(EditSnapshot.self, from: blob)) != nil
                    } catch {
                        if RecoveryFile.repairable(error) { return false }
                        throw error
                    }
                }
                guard try valid(cursor) else { throw error }
                var lo = cursor
                var hi = cursor
                while lo > 0 {
                    guard try valid(lo - 1) else { break }
                    lo -= 1
                }
                while hi + 1 < names.count {
                    guard try valid(hi + 1) else { break }
                    hi += 1
                }
                for retained in [lo...hi, cursor...cursor] where retained.count < names.count {
                    header["snapshotFiles"] = Array(names[retained])
                    header["historyCursor"] = cursor - retained.lowerBound
                    header.removeValue(forKey: "recordingInsertionStep")
                    do {
                        let p = try decode(JSONSerialization.data(withJSONObject: header), summarized: false)
                        return Opened(
                            project: p, notice: "Opened the saved timeline. Some Undo or Redo steps could not be read.")
                    } catch { if !RecoveryFile.repairable(error) { throw error } }
                }
                throw error
            }
        }
        var primaryDigest: String?
        do {
            let data = try Data(contentsOf: file)
            do {
                var result = try open(data, summarized: summary)
                if result.notice != nil { result.project.recoveryOrigin = RecoveryFile.hash(data) }
                return result
            } catch {
                primaryDigest = RecoveryFile.hash(data)
                throw error
            }
        } catch {
            guard RecoveryFile.repairable(error) else { throw error }
            let backups = directory.appendingPathComponent(".revisions")
            let pinned = ((try? FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasPrefix("schema-") }.sorted {
                    $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending
                }
            for backup in try revisions(in: backups) + pinned {
                do {
                    let data = try Data(contentsOf: backup)
                    guard backup.lastPathComponent.hasSuffix("-" + RecoveryFile.hash(data) + ".json") else { continue }
                    var opened = try open(data, summarized: false)
                    opened.project.recoveryOrigin = primaryDigest ?? "missing"
                    let time = opened.project.updatedAt.formatted(date: .abbreviated, time: .shortened)
                    opened.notice = ["Opened the project revision saved \(time).", opened.notice].compactMap { $0 }.joined(
                        separator: " ")
                    return opened
                } catch { if !RecoveryFile.repairable(error) { throw error } }
            }
            throw error
        }
    }
}

/// One receipt per writer segment. The movie name and project folder are
/// authoritative even if the phone is killed before the editor indexes the take.
struct TakeReceipt: Codable {
    struct Placement {
        let time: Double
        let site: VideoInsertionSite?
        let revision: String
        let captureCount: Int
    }
    enum Destination {
        case append
        case placement(Placement)
        case savedInsertion
    }
    let version: Int
    let projectID: UUID
    let takeID: UUID
    let segmentID: UUID
    let sequence: Int
    let filename: String
    let started: Date
    let insertion: Double?
    let insertionSite: VideoInsertionSite?
    let revision: String?
    let captureCount: Int
    var indexed = false

    static func location(_ movie: URL) -> URL {
        movie.deletingLastPathComponent().appendingPathComponent(".capture-receipts")
            .appendingPathComponent(movie.deletingPathExtension().lastPathComponent + ".json")
    }
    static func begin(
        movie: URL, projectID: UUID, take: UUID, segment: UUID, sequence: Int, destination: Destination = .savedInsertion
    ) throws {
        let folder = movie.deletingLastPathComponent()
        guard UUID(uuidString: folder.lastPathComponent) == projectID else { throw RecoveryError.identity }
        var insertion: Double?
        var site: VideoInsertionSite?
        var revision: String?
        var count = 0
        switch destination {
        case .append: break
        case .placement(let placement):
            insertion = placement.time
            site = placement.site
            revision = placement.revision
            count = placement.captureCount
        case .savedInsertion:
            // Automatic continuation after the previous segment's save callback.
            let header = try JSONDecoder().decode(
                Head.self, from: Data(contentsOf: folder.appendingPathComponent("project.json")))
            guard header.id == projectID, header.schemaVersion <= Project.latestReadableSchema,
                header.recordingInsertion != nil
            else { throw RecoveryError.identity }
            insertion = header.recordingInsertion
            site = header.recordingSite?.site
            count = header.captureLedger?.count ?? 0
            revision = header.snapshotFiles.flatMap {
                $0.indices.contains(header.historyCursor) ? $0[header.historyCursor] : nil
            }
        }
        let receipt = Self(
            version: 1, projectID: projectID, takeID: take, segmentID: segment, sequence: sequence,
            filename: movie.lastPathComponent, started: Date(), insertion: insertion,
            insertionSite: site, revision: revision, captureCount: count)
        try RecoveryFile.write(JSONEncoder().encode(receipt), to: location(movie))
        do {
            reserveLock.lock()
            defer { reserveLock.unlock() }
            let file = location(movie).deletingPathExtension().appendingPathExtension("reserve")
            try RecoveryFile.write(Data(repeating: 0xad, count: 4 * 1024 * 1024), to: file)
            liveReserves.insert(file.standardizedFileURL)
        } catch {
            try? FileManager.default.removeItem(at: location(movie))
            throw error
        }
    }
    private struct Head: Decodable {
        struct Site: Decodable { let site: VideoInsertionSite }
        struct Entry: Decodable {}
        let id: UUID, schemaVersion: Int, historyCursor: Int
        let recordingInsertion: Double?, recordingSite: Site?, snapshotFiles: [String]?, captureLedger: [Entry]?
    }
    static func read(_ movie: URL, project: UUID) throws -> Self? {
        guard let bytes = try RecoveryFile.readIfPresent(location(movie)) else { return nil }
        let r = try JSONDecoder().decode(Self.self, from: bytes)
        guard r.version == 1, r.projectID == project, r.filename == movie.lastPathComponent, r.sequence >= 0,
            r.filename.hasSuffix("-" + r.segmentID.uuidString + ".mov")
        else { throw RecoveryError.identity }
        return r
    }
    func markIndexed(_ movie: URL) throws {
        guard !indexed else { return }
        var value = self
        value.indexed = true
        try RecoveryFile.write(JSONEncoder().encode(value), to: Self.location(movie))
    }
    private static let reserveLock = NSLock()
    private static var liveReserves = Set<URL>()
    @discardableResult static func reclaimAbandonedReserves(in folder: URL) -> Int {
        reserveLock.lock()
        defer { reserveLock.unlock() }
        let dir = folder.appendingPathComponent(".capture-receipts")
        var missingMovies = 0
        for url in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        where url.pathExtension == "reserve" && !liveReserves.contains(url.standardizedFileURL) {
            let stem = url.deletingPathExtension().lastPathComponent
            guard UUID(uuidString: String(stem.suffix(36))) != nil,
                let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                v.isRegularFile == true, v.isSymbolicLink != true
            else { continue }
            do {
                try FileManager.default.removeItem(at: url)
                if !FileManager.default.fileExists(atPath: folder.appendingPathComponent(stem + ".mov").path) {
                    missingMovies += 1
                }
            } catch { continue }
        }
        return missingMovies
    }
    static func releaseReserve(_ movie: URL) {
        let file = location(movie).deletingPathExtension().appendingPathExtension("reserve")
        reserveLock.lock()
        defer { reserveLock.unlock() }
        try? FileManager.default.removeItem(at: file)
        liveReserves.remove(file.standardizedFileURL)
    }
}

extension ProjectDisk {
    private struct PendingEdit: Codable {
        let previous: String?
        let manifest: Data
    }
    func clearMatchingDraft(_ committed: Data, in folder: URL) {
        let directory = folder.appendingPathComponent(".pending-edit")
        guard let bytes = try? Data(contentsOf: directory.appendingPathComponent("draft.json")),
            let draft = try? JSONDecoder().decode(PendingEdit.self, from: bytes),
            draft.manifest == committed
        else { return }
        try? FileManager.default.removeItem(at: directory)
    }
    /// This is an emergency journal for a failed normal save. Only write
    /// snapshots that cannot be read from the main history directory.
    func journalDraft(_ project: Project) throws {
        let base = folder(project.id)
        let directory = base.appendingPathComponent(".pending-edit")
        let previous = try RecoveryFile.readIfPresent(base.appendingPathComponent("project.json")).map(RecoveryFile.hash)
        let data = try project.manifest { name, bytes in
            let existing = try? Data(contentsOf: base.appendingPathComponent("History/" + name))
            if existing != bytes {
                try RecoveryFile.ensureSnapshot(bytes, at: directory.appendingPathComponent("History/" + name))
            }
        }
        let envelope = PendingEdit(previous: previous, manifest: data)
        try RecoveryFile.write(try JSONEncoder().encode(envelope), to: directory.appendingPathComponent("draft.json"))
    }
    func pendingDraft(for id: UUID) throws -> Project? {
        let base = folder(id)
        let directory = base.appendingPathComponent(".pending-edit")
        guard let data = try RecoveryFile.readIfPresent(directory.appendingPathComponent("draft.json")) else { return nil }
        let draft = try JSONDecoder().decode(PendingEdit.self, from: data)
        let current = try RecoveryFile.readIfPresent(base.appendingPathComponent("project.json"))
        guard current != draft.manifest, current.map(RecoveryFile.hash) == draft.previous else { return nil }
        let project = try Project.readManifest(draft.manifest) { name in
            if let recovered = try RecoveryFile.readIfPresent(directory.appendingPathComponent("History/" + name)) {
                return recovered
            }
            return try Data(contentsOf: base.appendingPathComponent("History/" + name))
        }
        guard project.id == id else { throw RecoveryError.identity }
        return project
    }
}

enum RecoverySpace {
    static func isFull(_ error: Error) -> Bool {
        var next: NSError? = error as NSError
        for _ in 0..<6 {
            guard let e = next else { break }
            if (e.domain == NSCocoaErrorDomain && e.code == NSFileWriteOutOfSpaceError)
                || (e.domain == NSPOSIXErrorDomain && e.code == Int(ENOSPC))
                || (e.domain == "AVFoundationErrorDomain" && e.code == -11807)
            {
                return true
            }
            next = e.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }
    static let autoFileLimit: Int64 = 64 * 1024 * 1024
    static let autoTotalLimit: Int64 = 256 * 1024 * 1024
    static func floor(total: Int64) -> Int64 {
        max(512_000_000, min(2_000_000_000, total / 50))
    }
    static func capacity(at directory: URL) throws -> (free: Int64, floor: Int64) {
        #if DEBUG
            if directory.pathComponents.contains("EditorUITestProjects"),
                directory.pathComponents.contains(".paused-export"),
                CommandLine.arguments.contains("--recovery-full-export"),
                let i = directory.pathComponents.firstIndex(of: "EditorUITestProjects"),
                i + 1 < directory.pathComponents.count
            {
                let folder = NSURL.fileURL(withPathComponents: Array(directory.pathComponents.prefix(i + 2)))
                if let folder,
                    FileManager.default.fileExists(atPath: folder.appendingPathComponent(".test-full-export").path)
                {
                    return (1_000_000, 512_000_000)
                }
            }
        #endif
        let v = try FileManager.default.attributesOfFileSystem(forPath: directory.path)
        guard let free = v[.systemFreeSize] as? NSNumber, let total = v[.systemSize] as? NSNumber else {
            throw CocoaError(.fileReadUnknown)
        }
        return (free.int64Value, floor(total: total.int64Value))
    }
    static func size(_ url: URL) throws -> Int64 {
        guard let bytes = (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize else {
            throw CocoaError(.fileReadUnknown)
        }
        return Int64(bytes)
    }
    static func require(_ bytes: Int64, at directory: URL) throws {
        let volume = try capacity(at: directory)
        let room = volume.free - volume.floor
        guard bytes >= 0, bytes <= room else {
            let extra = ByteCountFormatter.string(fromByteCount: max(1, bytes - room), countStyle: .file)
            throw NSError(
                domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError,
                userInfo: [
                    NSLocalizedDescriptionKey: "Free about " + extra
                        + " more space to finish this operation and keep space available on the iPhone."
                ])
        }
    }
}
