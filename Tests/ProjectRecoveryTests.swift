import AVFoundation
import Foundation

func projectRecoveryTests(root: URL) async throws {
    let base = root.appendingPathComponent("safety-" + UUID().uuidString)
    let disk = ProjectDisk(root: base)
    var project = Project(title: "Safety fixture")
    let file = disk.folder(project.id).appendingPathComponent("project.json")
    let directory = file.deletingLastPathComponent()
    try disk.save(project)
    let movie = directory.appendingPathComponent("original.mov")
    try FileManager.default.copyItem(at: root.appendingPathComponent("source.mp4"), to: movie)
    let original = SourceMedia(
        filename: movie.lastPathComponent, duration: 4, sha256: try await SourceMediaCache.shared.fingerprint(movie))
    project.append(original)
    try disk.save(project)
    for start in [0.1, 0.2, 0.3] {
        var edit = project.edit
        edit.clips[0].start = start
        project.commit(edit)
        try disk.save(project)
    }
    let head = try Data(contentsOf: file)
    try Data("{".utf8).write(to: file)
    let restored = try disk.openRecovering(file)
    try require(
        restored.notice != nil && restored.project.history == project.history,
        "Corrupt head must restore the latest usable edit and Undo")
    let damaged = try Data(contentsOf: file)
    try require(damaged == Data("{".utf8), "Opening silently rewrote the damaged manifest")
    var next = restored.project
    next.title = "After recovery"
    try disk.save(next)
    let pinned = directory.appendingPathComponent(".revisions/damaged-head-" + RecoveryFile.hash(damaged) + ".json")
    try require(FileManager.default.fileExists(atPath: pinned.path), "A new save must preserve the damaged head")
    try FileManager.default.removeItem(at: file)
    let missing = try disk.openRecovering(file)
    try require(missing.project.title == next.title, "Missing project index")
    try head.write(to: file)
    let header = try JSONSerialization.jsonObject(with: head) as! [String: Any]
    let names = header["snapshotFiles"] as! [String]
    let badStep = directory.appendingPathComponent("History/" + names[1])
    try Data("broken history".utf8).write(to: badStep)
    let limited = try disk.openRecovering(file)
    try require(
        limited.notice != nil && limited.project.edit == project.edit && limited.project.canUndo
            && limited.project.history.count == 2,
        "A damaged older Undo step invalidated the good current timeline")
    try disk.save(project)
    var future = header
    future["schemaVersion"] = 900
    let newer = try JSONSerialization.data(withJSONObject: future)
    try newer.write(to: file)
    do {
        _ = try disk.openRecovering(file)
        throw NSError(domain: "Opened future project", code: 1)
    } catch RecoveryError.newerProject {}
    do {
        try disk.save(project)
        throw NSError(domain: "Overwrote future project", code: 1)
    } catch RecoveryError.newerProject {}
    let protected = try Data(contentsOf: file)
    try require(protected == newer, "Future project changed")
    try require(
        disk.originals(in: project.id, project: nil).map(\.url) == [movie],
        "Unindexed original must be shareable even with an unknown schema")
    try head.write(to: file)
    var draft = project
    draft.title = "Uncommitted title"
    try disk.journalDraft(draft)
    let pending = try disk.pendingDraft(for: project.id)
    try require(pending?.title == draft.title && pending?.history == project.history, "Durable pending draft")
    try disk.save(draft)
    let cleared = try disk.pendingDraft(for: project.id)
    try require(cleared == nil, "Committed draft replay")
    let segmentID = UUID()
    let segment = directory.appendingPathComponent("123-" + segmentID.uuidString + ".mov")
    project.beginRecordingInsertion(at: 1, site: nil)
    try disk.save(project)
    try TakeReceipt.begin(movie: segment, projectID: project.id, take: UUID(), segment: segmentID, sequence: 0)
    let receipt = try TakeReceipt.read(segment, project: project.id)!
    let source = SourceMedia(id: segmentID, filename: segment.lastPathComponent, duration: 4)
    var insertion = try disk.read(file)
    let placed = try insertion.indexTake(source, receipt: receipt, uncertain: false)
    try require(
        placed && insertion.edit.clips.contains(where: { $0.sourceID == source.id }), "Record here lost its insertion anchor"
    )
    let again = try insertion.indexTake(source, receipt: receipt, uncertain: false)
    try require(!again && insertion.sources.filter { $0.id == source.id }.count == 1, "Duplicate recovered take")
    var moved = project
    var newerEdit = moved.edit
    newerEdit.clips = []
    moved.commit(newerEdit)
    let before = moved.edit
    let guessed = try moved.indexTake(source, receipt: receipt, uncertain: false)
    try require(
        !guessed && moved.edit == before && moved.sources.contains(where: { $0.id == source.id }),
        "Ambiguous insertion overwrote deliberate edits")
    try receipt.markIndexed(segment)
    TakeReceipt.releaseReserve(segment)
    let indexed = try TakeReceipt.read(segment, project: project.id)
    try require(indexed?.indexed == true, "Receipt completion")
    let held = directory.appendingPathComponent("Recovery/" + UUID().uuidString)
    try FileManager.default.createDirectory(at: held, withIntermediateDirectories: true)
    let raw = Data("interrupted original".utf8), recipe = Data("unreadable recipe".utf8)
    try raw.write(to: held.appendingPathComponent("interview.mov"))
    try recipe.write(to: held.appendingPathComponent("interview.effects.json"))
    let unindexed = directory.appendingPathComponent("unindexed.mov")
    try raw.write(to: unindexed)
    let backup = base.appendingPathComponent("off-device.zip")
    try await ProjectArchive.export(draft, folder: directory, destination: backup) { _ in }
    let clean = ProjectDisk(root: base.appendingPathComponent("clean-install"))
    let copy = try await ProjectArchive.restore(backup, disk: clean) { _ in }
    let copied = try await SourceMediaCache.shared.fingerprint(
        clean.folder(copy.id).appendingPathComponent(original.filename))
    try require(
        copy.history == draft.history && copied == original.sha256,
        "External archive did not restore source and editing history")
    let heldCopy = clean.folder(copy.id).appendingPathComponent("Recovery/" + held.lastPathComponent)
    let restoredRaw = try Data(contentsOf: heldCopy.appendingPathComponent("interview.mov"))
    let restoredRecipe = try Data(contentsOf: heldCopy.appendingPathComponent("interview.effects.json"))
    try require(restoredRaw == raw && restoredRecipe == recipe && copy.sources.count == draft.sources.count,
                "Backup lost the untouched interrupted movie or its sidecar, or inserted it in the edit")
    let recoveredOriginals = clean.originals(in: copy.id, project: copy)
    try require(recoveredOriginals.contains { $0.url.lastPathComponent == "unindexed.mov" && $0.source == nil },
                "An original awaiting indexing was missing from the backup")
    let abandoned = clean.root.appendingPathComponent(".yourec-archive-staging/" + UUID().uuidString)
    try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)
    try raw.write(to: abandoned.appendingPathComponent("unpublished.mov"))
    ProjectArchive.discardInterruptedRestores(in: clean)
    try require(!FileManager.default.fileExists(atPath: abandoned.path) && FileManager.default.fileExists(atPath: heldCopy.path),
                "An interrupted archive restore accumulated duplicate media or removed a published original")
    let info = try await RecordingSalvage.inspect(movie)
    try require(!info.audioOnly && abs(info.duration - 4) < 0.1, "Original cannot be decoded")
    let fragments = try Data(contentsOf: root.appendingPathComponent("recovery-fragments.mov"))
    let truncated = directory.appendingPathComponent("torn.mov")
    let damagedBytes = Data(fragments.prefix(fragments.count * 90 / 100))
    try damagedBytes.write(to: truncated)
    let repaired = directory.appendingPathComponent("playable.mov")
    let part = try await RecordingSalvage.repair(truncated, to: repaired)
    let retained = try Data(contentsOf: truncated)
    try require(
        retained == damagedBytes && !part.audioOnly && part.duration > 2 && part.duration < 4,
        "Recover a readable movie prefix to a new file and preserve the interrupted file")
    try require(
        RecoverySpace.floor(total: 16_000_000_000) == 512_000_000
            && RecoverySpace.floor(total: 256_000_000_000) == 2_000_000_000,
        "Storage reserve bounds")
    let capacity = try RecoverySpace.capacity(at: directory)
    do {
        try RecoverySpace.require(capacity.free, at: directory)
        throw ProjectError.invalidDocument
    } catch { try require(RecoverySpace.isFull(error), "Refuse an allocation that uses the safety margin") }
    print(
        "PASS: head and history recovery, durable drafts, unknown schemas, insertion receipts, originals and clean-install archive"
    )
}

#if os(macOS)
    /// The host SIGKILLs this process at a known submitted sample, without ever
    /// calling stopRecording. The fixture encodes its frame number in luminance.
    func abruptWriterChild(root: URL) async throws {
        let env = ProcessInfo.processInfo.environment
        guard let marker = env["YOUREC_KILL_FRAME"].flatMap(Int.init), let output = env["YOUREC_KILL_OUTPUT"] else {
            throw ProjectError.invalidMedia
        }
        let asset = AVURLAsset(url: root.appendingPathComponent("clock.mov"))
        let reader = try AVAssetReader(asset: asset)
        let video = AVAssetReaderTrackOutput(
            track: try await asset.loadTracks(withMediaType: .video).first!,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange])
        let audio = AVAssetReaderTrackOutput(
            track: try await asset.loadTracks(withMediaType: .audio).first!,
            outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32])
        reader.add(video)
        reader.add(audio)
        guard reader.startReading() else { throw ProjectError.invalidMedia }
        var v = video.copyNextSampleBuffer()
        var a = audio.copyNextSampleBuffer()
        let capture = CaptureSegmentWriter()
        let file = URL(fileURLWithPath: output)
        capture.startRecording(to: file)
        let began = ContinuousClock.now
        while let frame = v {
            let pts = frame.presentationTimeStamp.seconds
            try await ContinuousClock().sleep(until: began + .seconds(pts))
            while let sound = a, sound.presentationTimeStamp.seconds <= pts {
                capture.queue.sync { capture.appendAudio(sound) }
                a = audio.copyNextSampleBuffer()
            }
            capture.queue.sync { capture.appendVideo(frame) }
            if Int((pts * 30).rounded()) == marker {
                try Data(String(marker).utf8).write(to: file.appendingPathExtension("armed"))
                raise(SIGSTOP)
                throw ProjectError.invalidMedia
            }
            v = video.copyNextSampleBuffer()
        }
        throw ProjectError.invalidMedia
    }
#endif

func exportRecoveredFixture(root: URL) async throws {
    let fm = FileManager.default
    let head = root.appendingPathComponent("project.json")
    let disk = ProjectDisk(root: root.deletingLastPathComponent())
    let project = try disk.read(head)
    let output = root.appendingPathComponent("verified-export-" + UUID().uuidString + ".mp4")
    let result = try await MediaRenderer.render(project: project, folder: root, destination: output) { _ in }
    let media = try await RecordingSalvage.inspect(output)
    try require(!media.audioOnly && abs(media.duration - project.edit.duration) < 0.12, "Long recovered export duration")
    try require(fm.fileExists(atPath: output.deletingPathExtension().appendingPathExtension("json").path), "Export receipt")
    print(
        "PASS: recovered project exported through YouRec, duration \(media.duration), audio peak \(result.audioPeak ?? .nan), output \(output.path)"
    )
}
