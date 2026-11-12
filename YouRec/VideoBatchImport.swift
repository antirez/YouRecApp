import AVFoundation

/// Private Photos copies are staged on the project volume and published in tap order.
struct VideoBatchImport {
    let directory: URL
    private(set) var sources: [SourceMedia] = []

    init(folder: URL) throws {
        directory = folder.appendingPathComponent("Processing/AddVideos-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    static func ownsFilename(_ name: String) -> Bool {
        let prefix = "photos-import-"
        let url = URL(fileURLWithPath: name)
        return name == url.lastPathComponent && name.hasPrefix(prefix) &&
            ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased()) &&
            UUID(uuidString: String(url.deletingPathExtension().lastPathComponent.dropFirst(prefix.count))) != nil
    }

    mutating func stage(privateCopy: URL, originalName: String?, isPhoto: Bool = false) async throws {
        try Task.checkCancellation()
        let ext = privateCopy.pathExtension.lowercased()
        let filename = "photos-import-" + UUID().uuidString + "." + (!isPhoto && ["mov", "mp4", "m4v"].contains(ext) ? ext : "mov")
        let staged = directory.appendingPathComponent(filename)
        if isPhoto {
            try await PhotoClip.write(from: privateCopy, to: staged)
        } else {
            try FileManager.default.moveItem(at: privateCopy, to: staged)
        }
        let asset = AVURLAsset(url: staged)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, duration <= 604800,
              !(try await asset.loadTracks(withMediaType: .video)).isEmpty else { throw ProjectError.invalidMedia }
        let hash = try await SourceMediaCache.shared.fingerprint(staged, memoize: false)
        try Task.checkCancellation()
        sources.append(SourceMedia(filename: filename, duration: duration, sha256: hash, isStillPhoto: isPhoto ? true : nil,
                                   originalName: originalName.map { String($0.prefix(255)) }))
    }

    func commit(to current: Project, at position: Double, site: VideoInsertionSite? = nil, disk: ProjectDisk) throws -> Project {
        try Task.checkCancellation()
        guard !sources.isEmpty else { throw ProjectError.invalidMedia }
        var candidate = current
        candidate.sources.append(contentsOf: sources)
        candidate.insertVideos(sources, at: position, site: site)
        try candidate.validate()
        let folder = disk.folder(current.id), fm = FileManager.default
        let journal = directory.appendingPathComponent("promoting.json")
        let names = sources.map(\.filename)
        guard names.allSatisfy({ !fm.fileExists(atPath: folder.appendingPathComponent($0).path) }) else { throw CocoaError(.fileWriteFileExists) }
        // A process termination between the first move and the atomic manifest
        // save must never turn part of this group into recovered camera footage.
        try JSONEncoder().encode(names).write(to: journal, options: .atomic)
        var moved: [URL] = []
        do {
            for name in names {
                try Task.checkCancellation()
                let destination = folder.appendingPathComponent(name)
                try fm.moveItem(at: directory.appendingPathComponent(name), to: destination)
                moved.append(destination)
            }
            try Task.checkCancellation()
            try disk.save(candidate)
        } catch {
            for file in moved { try fm.removeItem(at: file) }
            try fm.removeItem(at: journal)
            throw error
        }
        try? fm.removeItem(at: directory)
        return candidate
    }

    func discard() {
        // Leave the journal available to startup recovery if rollback itself failed.
        if !FileManager.default.fileExists(atPath: directory.appendingPathComponent("promoting.json").path) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    static func recover(in project: Project, folder: URL) throws {
        let fm = FileManager.default, work = folder.appendingPathComponent("Processing")
        guard fm.fileExists(atPath: work.path) else { return }
        let known = Set(project.sources.map { $0.filename.lowercased() })
        for batch in try fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
            where batch.lastPathComponent.hasPrefix("AddVideos-") {
            let journal = batch.appendingPathComponent("promoting.json")
            guard fm.fileExists(atPath: journal.path) else { continue }
            let names = try JSONDecoder().decode([String].self, from: Data(contentsOf: journal))
            guard names.allSatisfy(ownsFilename) else { throw ProjectError.invalidDocument }
            for name in names where !known.contains(name.lowercased()) {
                let file = folder.appendingPathComponent(name)
                if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
            }
        }
    }
}

extension Project {
    mutating func insertVideos(_ ordered: [SourceMedia], at position: Double, site: VideoInsertionSite? = nil) {
        guard !ordered.isEmpty else { return }
        let clips = ordered.map { TimelineClip(sourceID: $0.id, start: 0, end: $0.duration) }
        let photos = Set(ordered.filter { $0.isStillPhoto == true }.map(\.id))
        commit(TimelineEditing.inserting(clips, into: edit, at: position, site: site, pictureOnlySources: photos))
    }
}
