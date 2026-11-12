import Foundation
import Darwin
import CryptoKit
@preconcurrency import AVFoundation

/// A private, validated copy. The caller moves it into the project only when
/// the new edit can be committed; the user's Files/iCloud original is read-only.
struct ImportedAudioFile {
    let url: URL
    let source: SourceMedia
    static func stage(_ original: URL, in directory: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> Self {
        let access = original.startAccessingSecurityScopedResource()
        defer { if access { original.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suffix = original.pathExtension.lowercased()
        let ext = !suffix.isEmpty && suffix.count <= 10 && suffix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) ? suffix : "audio"
        let staged = directory.appendingPathComponent(UUID().uuidString + "." + ext)
        do {
            try await ProjectArchive.copyFile(original, to: staged, progress: progress)
            let asset = AVURLAsset(url: staged)
            guard try await !asset.load(.hasProtectedContent),
                  let track = try await asset.loadTracks(withMediaType: .audio).first else { throw AudioImportError.unreadable }
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0, duration <= 604800 else { throw AudioImportError.unreadable }
            // A container declaring an audio track is not sufficient evidence
            // that the system can decode its codec or that its samples exist.
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            guard reader.canAdd(output) else { throw AudioImportError.unreadable }
            reader.add(output)
            guard reader.startReading(), let sample = output.copyNextSampleBuffer(), CMSampleBufferGetNumSamples(sample) > 0 else { throw AudioImportError.unreadable }
            reader.cancelReading()
            let hash = try await SourceMediaCache.shared.fingerprint(staged, memoize: false)
            try Task.checkCancellation()
            return Self(url: staged, source: SourceMedia(filename: staged.lastPathComponent, duration: duration, sha256: hash,
                audioOnly: true, originalName: String(original.lastPathComponent.prefix(255))))
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
    }
}
enum AudioImportError: LocalizedError {
    case unreadable
    var errorDescription: String? { "This file has no playable audio. Choose an unprotected audio file such as WAV, AIFF, M4A or MP3." }
}

struct ArchiveIntegrity: Codable {
    var version = 1
    let sha256: [String: String]
}

private enum BackupLimit {
    static let header = 20_000_000
    static let snapshot = 32_000_000
    // Charge every referenced snapshot, including repeated references.
    static let history = 256_000_000
    static func check(_ bytes: Int, maximum: Int) throws {
        guard bytes <= maximum else {
            throw CocoaError(.fileReadTooLarge, userInfo: [NSLocalizedDescriptionKey: "This editing history exceeds the supported project backup size."])
        }
    }
}

enum ProjectArchive {
    private static let restoreSession = UUID().uuidString
    private static func restoreWorkspace(in disk: ProjectDisk) -> URL {
        disk.root.appendingPathComponent(".yourec-archive-staging", isDirectory: true)
    }
    static func discardInterruptedRestores(in disk: ProjectDisk) {
        let work = restoreWorkspace(in: disk)
        guard let info = try? work.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]),
              info.isDirectory == true, info.isSymbolicLink != true else { return }
        for session in (try? FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)) ?? []
        where session.lastPathComponent != restoreSession && UUID(uuidString: session.lastPathComponent) != nil {
            try? FileManager.default.removeItem(at: session)
        }
    }

    // Other apps can consume space between preflight and the end of a long copy.
    private struct CopyBudget {
        let directory: URL
        var nextCheck: Int64 = 0
        mutating func check(at offset: Int64) throws {
            try Task.checkCancellation()
            if offset >= nextCheck {
                try RecoverySpace.require(0, at: directory)
                nextCheck = offset + 16_777_216
            }
        }
    }

    // Recovery entries are opaque originals. Keep them outside the restored
    // timeline, including the sidecars that came with an interrupted take.
    private static func isRecoveryEntry(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "Recovery",
              UUID(uuidString: String(parts[1])) != nil || (parts[1].count == 64 && parts[1].allSatisfy(\.isHexDigit)) else { return false }
        let name = String(parts[2])
        guard !name.isEmpty, name.utf8.count <= 255, !name.hasPrefix("."), !name.contains("\\"), !name.contains("\0") else { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        return ["mov", "mp4", "m4v", "m4a", "caf", "wav", "aac", "flac", "mp3", "aif", "aiff"].contains(ext)
            || name.hasSuffix(".events.json") || name.hasSuffix(".effects.json")
    }

    private static func recoveryEntries(in projectFolder: URL) throws -> [String] {
        let fm = FileManager.default
        let root = projectFolder.appendingPathComponent("Recovery", isDirectory: true)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        do {
            let values = try root.resourceValues(forKeys: keys)
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw ProjectError.invalidDocument }
        } catch { if RecoveryFile.missing(error) { return [] }; throw error }
        var paths: [String] = []
        for group in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys)) {
            let info = try group.resourceValues(forKeys: keys)
            guard info.isDirectory == true, info.isSymbolicLink != true else { continue }
            for url in try fm.contentsOfDirectory(at: group, includingPropertiesForKeys: Array(keys)) {
                let path = "Recovery/" + group.lastPathComponent + "/" + url.lastPathComponent
                let info = try url.resourceValues(forKeys: keys)
                if info.isRegularFile == true, info.isSymbolicLink != true, isRecoveryEntry(path) { paths.append(path) }
            }
        }
        return paths.sorted()
    }

    static func copyFile(_ source: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let task = Task.detached(priority: .userInitiated) {
            var coordinationError: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { coordinated in
                do {
                    try Task.checkCancellation()
                    let total = max(1, (try coordinated.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 1)
                    try RecoverySpace.require(Int64(total), at: destination.deletingLastPathComponent())
                    guard !FileManager.default.fileExists(atPath: destination.path),
                          FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw CocoaError(.fileWriteFileExists) }
                    let input = try FileHandle(forReadingFrom: coordinated), output = try FileHandle(forWritingTo: destination)
                    defer { try? input.close(); try? output.close() }
                    var count = 0, lastProgress = -1.0, nextSpaceCheck = 16_777_216
                    while let chunk = try input.read(upToCount: 2_097_152), !chunk.isEmpty {
                        try Task.checkCancellation(); try output.write(contentsOf: chunk); count += chunk.count
                        if count >= nextSpaceCheck {
                            try RecoverySpace.require(0, at: destination.deletingLastPathComponent())
                            nextSpaceCheck = count + 16_777_216
                        }
                        let value = Double(count) / Double(total)
                        if value - lastProgress >= 0.005 { lastProgress = value; progress(min(1, value)) }
                    }
                    try Task.checkCancellation(); try output.synchronize(); progress(1)
                } catch { copyError = error }
            }
            if let error = copyError ?? coordinationError { throw error }
        }
        try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    private static func preservedOriginals(_ project: Project, in folder: URL) throws -> [String: URL] {
        var preserved = Dictionary(uniqueKeysWithValues: try recoveryEntries(in: folder).map { ($0, folder.appendingPathComponent($0)) })
        // A backup can be requested before startup has finished indexing a take.
        // Restore these files under Originals, without guessing their timeline position.
        if UUID(uuidString: folder.lastPathComponent) == project.id {
            let disk = ProjectDisk(root: folder.deletingLastPathComponent())
            for movie in try disk.unindexedRecordings(in: project) {
                let prefix = "Recovery/" + RecoveryFile.hash(Data(movie.lastPathComponent.utf8)) + "/"
                preserved[prefix + movie.lastPathComponent] = movie
                for suffix in ["events.json", "effects.json"] {
                    let sidecar = movie.deletingPathExtension().appendingPathExtension(suffix)
                    if FileManager.default.fileExists(atPath: sidecar.path) { preserved[prefix + sidecar.lastPathComponent] = sidecar }
                }
            }
        }
        return preserved
    }

    /// Clone editable media locally. The filesystem can share its disk blocks,
    /// while each project owns its files and can edit, repair, or delete them.
    static func duplicate(_ original: Project, in disk: ProjectDisk, title: String, progress: @escaping @Sendable (Double) -> Void) async throws -> Project {
        try Task.checkCancellation()
        guard original.deferredHistory == nil else { throw ProjectError.invalidDocument }
        try original.validate()
        var copy = original
        copy.id = UUID(); copy.title = title
        copy.createdAt = Date(); copy.updatedAt = copy.createdAt
        copy.recordingInsertion = nil; copy.recordingInsertionStep = nil; copy.recoveryOrigin = nil

        let staged = stagingDisk(in: disk), work = staged.folder(copy.id)
        let fm = FileManager.default, sourceFolder = disk.folder(original.id)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        try RecoverySpace.require(0, at: work)
        let preserved = try preservedOriginals(original, in: sourceFolder)
        let names = original.mediaFiles + preserved.keys.sorted()
        let feedback = MediaProgress(progress)
        for (index, name) in names.enumerated() {
            try Task.checkCancellation()
            let source = preserved[name] ?? sourceFolder.appendingPathComponent(name)
            let target = work.appendingPathComponent(name)
            do {
                let info = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard info.isRegularFile == true, info.isSymbolicLink != true else { throw ProjectError.invalidDocument }
            } catch where RecoveryFile.missing(error) && preserved[name] == nil {
                // Keep an already missing asset relinkable in both timelines.
                continue
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if clonefile(source.path, target.path, UInt32(CLONE_NOFOLLOW)) != 0 {
                let code = errno
                guard code == ENOTSUP || code == EXDEV || code == ENOSYS else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
                try await copyFile(source, to: target) { value in
                    feedback.report((Double(index) + value) / Double(names.count))
                }
            }
            feedback.report(Double(index + 1) / Double(names.count))
        }
        return try publish(copy, from: staged, into: disk)
    }

    static func export(_ project: Project, folder: URL, destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let feedback = MediaProgress(progress)
        try project.validate()
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }
        let partial = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".partial")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: partial) }
        // Keep backup usable if an overlay asset has gone missing, even when
        // only an undo state refers to it. Original recordings remain required.
        let preserved = try preservedOriginals(project, in: folder)
        let files = project.sources.map(\.filename) + Array(Set(project.imageFiles + project.effectFiles + project.fontFiles)).sorted().filter {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        } + preserved.keys.sorted()
        var required: Int64 = 256_000_000
        for filename in files {
            let source = preserved[filename] ?? folder.appendingPathComponent(filename)
            let values = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw ProjectError.missingMedia }
            let sum = required.addingReportingOverflow(Int64(values.fileSize ?? 0))
            guard !sum.overflow else { throw ProjectError.invalidDocument }; required = sum.partialValue
        }
        try RecoverySpace.require(required, at: destination.deletingLastPathComponent())
        let archive = try Archive(url: partial, accessMode: .create)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        func add(_ data: Data, name: String) throws {
            try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .none) { position, count in
                data.subdata(in: Int(position)..<min(data.count, Int(position) + count))
            }
        }
        var written = Set<String>()
        var historyBytes = 0
        let manifest = try project.manifest { name, data in
            try Task.checkCancellation()
            try BackupLimit.check(data.count, maximum: BackupLimit.snapshot)
            historyBytes += data.count
            try BackupLimit.check(historyBytes, maximum: BackupLimit.history)
            if written.insert(name).inserted { try add(data, name: "History/" + name) }
        }
        try BackupLimit.check(manifest.count, maximum: BackupLimit.header)
        try add(manifest, name: "project.json")
        try add(EditorialTimeline.data(for: project), name: EditorialTimeline.filename(for: project))
        var hashes: [String: String] = [:]
        for (index, filename) in files.enumerated() {
            try Task.checkCancellation()
            let file = preserved[filename] ?? folder.appendingPathComponent(filename)
            let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else { throw ProjectError.missingMedia }
            let size = try RecoverySpace.size(file)
            let input = try FileHandle(forReadingFrom: file)
            defer { try? input.close() }
            var budget = CopyBudget(directory: partial.deletingLastPathComponent())
            var sha = SHA256()
            try archive.addEntry(with: filename, type: .file, uncompressedSize: size,
                                 compressionMethod: .none, bufferSize: 1024 * 1024) { offset, count in
                // FileHandle can autorelease its NSData. ZIPFoundation calls
                // this provider synchronously for the entire movie.
                try autoreleasepool {
                    try budget.check(at: offset)
                    let bytes = try input.read(upToCount: count) ?? Data()
                    guard bytes.count == count else { throw ProjectError.missingMedia }
                    sha.update(data: bytes)
                    let fraction = Double(offset + Int64(count)) / Double(max(1, size))
                    feedback.report((Double(index) + fraction) / Double(files.count))
                    return bytes
                }
            }
            if try RecoverySpace.size(file) != size {
                throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "A recording changed during backup. Wait for recording to finish and try again."])
            }
            hashes[filename] = sha.finalize().map { String(format: "%02x", $0) }.joined()
            feedback.report(Double(index + 1) / Double(max(1, files.count)))
        }
        let integrity = try encoder.encode(ArchiveIntegrity(version: preserved.isEmpty ? 1 : 2, sha256: hashes))
        try BackupLimit.check(integrity.count, maximum: BackupLimit.header)
        try add(integrity, name: "integrity.json")
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: partial, to: destination)
    }

    static func restore(_ url: URL, disk: ProjectDisk, progress: @escaping @Sendable (Double) -> Void) async throws -> Project {
        let feedback = MediaProgress(progress)
        let archive = try Archive(url: url, accessMode: .read)
        let entries = Array(archive)
        var names = Set<String>()
        for entry in entries {
            let flat = !entry.path.hasPrefix(".") && !entry.path.contains("/") && !entry.path.contains("\\")
                && entry.path == URL(fileURLWithPath: entry.path).lastPathComponent
            let snapshot = entry.path.hasPrefix("History/") && Project.isSnapshotName(String(entry.path.dropFirst(8)))
            guard entry.type == .file, flat || snapshot || isRecoveryEntry(entry.path),
                  names.insert(entry.path.lowercased()).inserted else { throw ProjectError.invalidDocument }
        }
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
        func read(_ name: String, limit: Int = BackupLimit.header) throws -> Data {
            guard let entry = byName[name], entry.uncompressedSize <= UInt64(limit) else { throw ProjectError.invalidDocument }
            var data = Data()
            let crc = try archive.extract(entry) { chunk in
                try Task.checkCancellation()
                guard data.count + chunk.count <= Int(entry.uncompressedSize) else { throw ProjectError.invalidDocument }
                data.append(chunk)
            }
            guard data.count == Int(entry.uncompressedSize), crc == entry.checksum else { throw ProjectError.invalidDocument }
            return data
        }
        // Older releases put the entire history inline. Keep a bounded reader
        // for those backups, including files larger than the old 20 MB limit.
        var snapshotPaths = Set<String>()
        var remaining = BackupLimit.history
        var project = try Project.readManifest(read("project.json", limit: BackupLimit.history)) { name in
            let path = "History/" + name
            let data = try read(path, limit: min(remaining, BackupLimit.snapshot))
            remaining -= data.count
            snapshotPaths.insert(path)
            return data
        }
        try project.validate()
        let integrity = try JSONDecoder().decode(ArchiveIntegrity.self, from: read("integrity.json"))
        let preserved = Set(integrity.sha256.keys.filter(isRecoveryEntry))
        let mediaFiles = project.mediaFiles + preserved.sorted()
        guard (integrity.version == 1 && preserved.isEmpty) || integrity.version == 2,
              preserved.isSubset(of: byName.keys),
              Set(entries.map(\.path)).isSubset(of: snapshotPaths.union(mediaFiles + ["project.json", "integrity.json", EditorialTimeline.filename(for: project)])),
              Set(project.sources.map(\.filename)).isSubset(of: Set(integrity.sha256.keys)),
              Set(integrity.sha256.keys).isSubset(of: Set(mediaFiles)) else { throw ProjectError.invalidDocument }
        for index in project.sources.indices { project.sources[index].sha256 = integrity.sha256[project.sources[index].filename] }
        try project.validate()
        project.id = UUID(); project.updatedAt = Date()
        let staged = stagingDisk(in: disk)
        let folder = staged.folder(project.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var required: UInt64 = 256_000_000
        for entry in entries {
            let sum = required.addingReportingOverflow(UInt64(entry.uncompressedSize))
            guard !sum.overflow else { throw ProjectError.invalidDocument }; required = sum.partialValue
        }
        guard required <= UInt64(Int64.max) else { throw ProjectError.invalidDocument }
        try RecoverySpace.require(Int64(required), at: folder)
        for (index, filename) in mediaFiles.enumerated() {
            try Task.checkCancellation()
            guard let entry = archive[filename] else { continue }
            let file = folder.appendingPathComponent(filename)
            if preserved.contains(filename) {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            let transfer = Progress(totalUnitCount: -1)
            let sourceCount = max(1, mediaFiles.count)
            let observation = transfer.observe(\.fractionCompleted) { value, _ in
                feedback.report((Double(index) + value.fractionCompleted) / Double(sourceCount))
            }
            defer { observation.invalidate() }
            do {
                try Data().write(to: file, options: .withoutOverwriting)
                let output = try FileHandle(forWritingTo: file)
                defer { try? output.close() }
                var budget = CopyBudget(directory: folder)
                var bytes: Int64 = 0
                var sha = SHA256()
                let crc = try await withTaskCancellationHandler(operation: {
                    try archive.extract(entry, bufferSize: 1024 * 1024, progress: transfer) { chunk in
                        guard UInt64(chunk.count) <= entry.uncompressedSize - UInt64(bytes) else { throw ProjectError.invalidDocument }
                        try budget.check(at: bytes)
                        try output.write(contentsOf: chunk)
                        bytes += Int64(chunk.count)
                        sha.update(data: chunk)
                    }
                }, onCancel: { transfer.cancel() })
                try output.synchronize()
                let hash = sha.finalize().map { String(format: "%02x", $0) }.joined()
                if UInt64(bytes) != entry.uncompressedSize || crc != entry.checksum || hash != integrity.sha256[filename] {
                    if preserved.contains(filename) { throw ProjectError.invalidDocument }
                    // Keep the valid takes and editing history. The missing take
                    // remains explicitly relinkable using its expected checksum.
                    try FileManager.default.removeItem(at: file)
                }
            } catch Archive.ArchiveError.invalidCRC32 {
                if preserved.contains(filename) { throw ProjectError.invalidDocument }
                try? FileManager.default.removeItem(at: file)
            } catch Data.CompressionError.corruptedData {
                if preserved.contains(filename) { throw ProjectError.invalidDocument }
                try? FileManager.default.removeItem(at: file)
            }
            feedback.report(Double(index + 1) / Double(max(1, mediaFiles.count)))
        }
        return try publish(project, from: staged, into: disk)
    }

    private static func stagingDisk(in disk: ProjectDisk) -> ProjectDisk {
        discardInterruptedRestores(in: disk)
        return ProjectDisk(root: restoreWorkspace(in: disk).appendingPathComponent(restoreSession, isDirectory: true))
    }

    private static func publish(_ project: Project, from staged: ProjectDisk, into disk: ProjectDisk) throws -> Project {
        try Task.checkCancellation()
        try staged.save(project)
        try Task.checkCancellation()
        let destination = disk.folder(project.id)
        try FileManager.default.moveItem(at: staged.folder(project.id), to: destination)
        do { try RecoveryFile.syncDirectory(disk.root) }
        catch {
            try FileManager.default.removeItem(at: destination)
            throw error
        }
        return project
    }
}
