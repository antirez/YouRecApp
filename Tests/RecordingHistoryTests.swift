import AVFoundation
import ImageIO

func recordingHistoryTests(root: URL) throws {
    try recordingRecoveryAssetTests(root: root)
    try automaticCanvasHistoryTests(root: root)
    let a = SourceMedia(filename: "first.mov", duration: 764.485)
    let b = SourceMedia(filename: "last.mov", duration: 204.31554166666666)
    let first = TimelineClip(sourceID: a.id, start: 0, end: a.duration)
    let last = TimelineClip(sourceID: b.id, start: 0, end: b.duration)
    var project = Project(title: "Recording undo regression")
    project.append(a); project.append(b)
    try require(!project.canUndo && project.history.count == 1, "Recording additions are a baseline, not editing undo steps")
    var edit = project.edit; edit.clips[0].start = 2; project.commit(edit)
    project.undo(); project.undo()
    try require(abs(project.edit.duration - a.duration - b.duration) < 0.000001, "Undo cannot remove the final recording")
    var branched = project.edit; branched.effects = [.make(.voiceIsolation)]; project.commit(branched)
    try require(project.edit.clips.count == 2 && !project.canRedo, "A new edit after Undo retains all captured segments")
    project.undo()
    let c = SourceMedia(filename: "continued.mov", duration: 7)
    project.append(c)
    try require(project.canRedo && project.edit.clips.count == 3, "Continuing recording retains the existing editing redo branch")
    project.redo(); try require(project.edit.effects.count == 1 && project.edit.clips.count == 3, "Redo restores effects while preserving continued footage")
    project.undo(); try require(project.edit.effects.isEmpty && project.edit.clips.count == 3, "Older edits remain undoable after recording continuation")
    var deletion = project.edit; deletion.clips.remove(at: 1); project.commit(deletion)
    try require(!project.edit.clips.contains { $0.sourceID == b.id }, "Explicit clip deletion still works")
    project.undo(); try require(project.edit.clips.count == 3, "Undoing an explicit deletion restores the deleted clip")
    project.redo(); project.append(SourceMedia(filename: "later.mov", duration: 3))
    try require(!project.edit.clips.contains { $0.sourceID == b.id }, "New recording does not reverse an intentional deletion")
    project.undo(); try require(project.edit.clips.count == 4, "Deletion can still be undone without losing later capture")
    try project.validate()

    var legacy = Project(title: "Legacy append history")
    legacy.sources = [a, b]; legacy.recordingHistoryVersion = nil
    var trimmed = EditState(clips: [first]); trimmed.clips[0].start = 2
    var continued = trimmed; continued.clips.append(last)
    var filtered = continued; filtered.effects = [.make(.voiceIsolation)]
    var removed = filtered; removed.clips.removeLast()
    legacy.history = [EditState(), EditState(clips: [first]), trimmed, continued, filtered, removed]
    for cursor in legacy.history.indices {
        var migrated = legacy; migrated.historyCursor = cursor; migrated.protectRecordingHistory()
        try migrated.validate()
        try require(migrated.history.count == 4, "Migration removes only the two capture transitions")
        try require(migrated.historyCursor == [0, 0, 1, 1, 2, 3][cursor], "Migration maps the current undo cursor correctly")
        let expectedCount = cursor == 5 ? 1 : 2
        try require(migrated.edit.clips.count == expectedCount, "Migration preserves deliberate deletion, including the current state")
        let saved = migrated.history; migrated.protectRecordingHistory()
        try require(migrated.history == saved, "Migration is idempotent")
        while migrated.canUndo { migrated.undo() }
        try require(abs(migrated.edit.duration - a.duration - b.duration) < 0.000001, "All historical edits undo to the complete recording")
    }
    // A full source manually reinserted after deletion is an editing step, not
    // its first appearance. Do not rebase that later insertion.
    legacy.history.append(filtered); legacy.historyCursor = 6
    legacy.protectRecordingHistory(); legacy.undo()
    try require(legacy.edit.clips.count == 1, "A later reinsertion remains undoable")

    for variant in 0..<3 {
        var ambiguous = Project(title: "Non-capture transition")
        ambiguous.sources = [a]; ambiguous.recordingHistoryVersion = nil
        var inserted = EditState(clips: [first])
        if variant == 0 { inserted.clips[0].crop = CropSettings(zoom: 2) }
        if variant == 1 { inserted.effects = [.make(.voiceIsolation)] }
        if variant == 2 { inserted.outputSize = CGSize(width: 1080, height: 1920) }
        ambiguous.history = [EditState(), inserted]; ambiguous.historyCursor = 1
        ambiguous.protectRecordingHistory()
        try require(ambiguous.history.count == 2 && ambiguous.historyCursor == 1, "Migration leaves ambiguous tool/effect/format changes alone")
    }
    var repeated = Project(title: "Unrelated historical no-op")
    repeated.sources = [a]; repeated.recordingHistoryVersion = nil
    repeated.history = [EditState(), EditState(), EditState(clips: [first])]; repeated.historyCursor = 2
    repeated.protectRecordingHistory()
    try require(repeated.history.count == 2 && repeated.historyCursor == 1, "Migration removes only capture steps, not unrelated duplicate snapshots")

    var undoneCapture = Project(title: "Direct decode before first edit")
    undoneCapture.sources = [a, b]; undoneCapture.recordingHistoryVersion = nil
    undoneCapture.history = [EditState(), EditState(clips: [first]), EditState(clips: [first, last])]
    undoneCapture.historyCursor = 1
    var decoded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(undoneCapture))
    try require(decoded.edit.clips.count == 2 && !decoded.canUndo, "Every decode normalizes capture before exposing edit or undo availability")
    var nextEdit = decoded.edit; nextEdit.effects = [.make(.voiceIsolation)]; decoded.commit(nextEdit)
    try require(decoded.edit.clips.count == 2 && decoded.canUndo, "The first edit after direct decoding cannot reintroduce lost footage")

    // Reproduce the user's saved branch: both sources survive, but the second
    // recording disappeared from every retained snapshot after Undo + a trim.
    var affected = Project(title: "Missing final section")
    affected.recordingHistoryVersion = nil; affected.sources = [a, b]
    var tools = trimmed; tools.clips[0].crop = CropSettings(zoom: 2); tools.effects = [.make(.voiceIsolation)]
    affected.history = [EditState(), EditState(clips: [first]), trimmed, tools]; affected.historyCursor = 3
    let disk = ProjectDisk(root: root.appendingPathComponent("recording-history"))
    try disk.save(affected)
    let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: disk.folder(affected.id).appendingPathComponent("project.json"))) as! [String: Any]
    try require(raw["recordingHistoryVersion"] == nil, "Legacy fixture genuinely omits the new optional field")
    affected = try disk.read(disk.folder(affected.id).appendingPathComponent("project.json"))
    try require(affected.edit.clips.count == 1, "Loading never guesses that an unused source should return")
    let before = affected.history
    try affected.restoreUnusedRecording(b.id)
    try require(affected.historyCursor == 2 && affected.history.count == before.count, "Recovery retains the current edit and all editing history")
    for (old, new) in zip(before, affected.history) {
        var prefix = new; prefix.clips.removeLast()
        try require(prefix == old && new.clips.last?.sourceID == b.id, "Recovery preserves every edit and appends only the intact missing take")
    }
    try disk.save(affected); affected = try disk.read(disk.folder(affected.id).appendingPathComponent("project.json"))
    while affected.canUndo { affected.undo() }
    try require(abs(affected.edit.duration - a.duration - b.duration) < 0.000001, "Recovered footage survives Undo all and reopening")
    while affected.canRedo { affected.redo() }
    try require(affected.edit.clips[0].crop?.zoom == 2 && affected.edit.effects.count == 1, "Recovered project retains its video and audio effects")
    do { try affected.restoreUnusedRecording(b.id); throw NSError(domain: "RecordingQA", code: 1) }
    catch ProjectError.invalidDocument {}
    // Real captured boundaries are not generally on an absolute 30-fps grid.
    let edgeA = TimelineClip(sourceID: UUID(), start: 0, end: 10.017)
    let edgeB = TimelineClip(sourceID: UUID(), start: 0, end: 5.013)
    let edgeC = TimelineClip(sourceID: UUID(), start: 0, end: 7)
    let boundaryState = EditState(clips: [edgeA, edgeB, edgeC])
    let cut = TimelineEditing.cut(edgeA.duration...(edgeA.duration + edgeB.duration), from: boundaryState)
    try require(cut.edit.clips == [edgeA, edgeC] && cut.clips == [edgeB], "Boundary-exact Cut leaves no slivers and changes no adjacent source coordinates")
    let pasted = TimelineEditing.inserting(cut.clips, into: cut.edit, at: edgeA.duration)
    try require(pasted.clips.map(\.sourceID) == boundaryState.clips.map(\.sourceID) && pasted.duration == boundaryState.duration, "Pasting at an exact take join restores the order and exact duration")
    var decorated = edgeB; decorated.texts = [TextOverlay(text: "Copy", end: 3)]; decorated.mirror = MirrorSettings(horizontal: true)
    let twice = TimelineEditing.inserting([decorated], into: EditState(clips: [decorated]), at: 0)
    try require(twice.clips[0].texts?.first?.id != twice.clips[1].texts?.first?.id && twice.clips[0].mirror?.id != twice.clips[1].mirror?.id, "Pasted effects edit independently from their originals")
    try require(TimelineEditing.snap(10.02, clips: boundaryState.clips, pointsPerSecond: 60) == edgeA.duration, "Snapping retains the exact recorded boundary")
    var insertSession = Project(title: "Record here")
    insertSession.append(a); insertSession.recordingInsertion = 10
    insertSession.addRecording(b); insertSession.addRecording(c)
    try insertSession.validate()
    try require(insertSession.history.count == 2 && insertSession.edit.clips.map(\.sourceID) == [a.id, b.id, c.id, a.id], "All recorded insertion segments form one ordered undo step")
    insertSession = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(insertSession))
    insertSession.undo(); try require(insertSession.edit.clips.count == 1 && insertSession.sources.count == 3, "Undoing Record here preserves every original recording")
    insertSession.redo(); try require(insertSession.edit.outputSize == nil && insertSession.edit.canvasSourceID == a.id, "Record insertion retains the automatic canvas reference through reopen/redo")
    var late = Project(title: "Late recording while an inspector is open")
    late.append(a); var openDraft = late.edit
    openDraft.timeline.audio[0].volumeDB = -4
    late.append(b); late.commit(openDraft)
    try require(late.edit.clips.map(\.sourceID) == [a.id, b.id] && late.edit.timeline.audio[0].volumeDB == -4, "A stale tool draft cannot hide capture indexed after the tool opened")
    late.undo(); try require(late.edit.clips.count == 2, "Undo after a stale-draft commit still preserves late capture")
    var recovery = Project(title: "Late record-here recovery")
    recovery.append(a); let staleInsertionDraft = recovery.edit
    recovery.recordingInsertion = 2; recovery.addRecording(b)
    let recoveredState = recovery.edit
    try require(!recovery.canCommit(staleInsertionDraft), "An inspector opened before Record here recovery reports a conflict")
    recovery.commit(staleInsertionDraft)
    try require(recovery.edit == recoveredState, "A stale draft never overwrites a recovered inserted recording")
    let recoveredMarks = CaptureEvent.recovered([CaptureEvent(time: 1, kind: "bookmark", detail: ""), CaptureEvent(time: 5.8, kind: "bookmark", detail: "")], duration: 4)
    try require(recoveredMarks.count == 1 && recoveredMarks[0].time == 1, "A mark beyond the last written fragment does not prevent recording recovery")
    // Published payloads are immutable, and later ordinary recording is a
    // small journal update even with both Undo and Redo branches present.
    var journal = Project(title: "Immutable capture ledger")
    journal.append(a); var modified = journal.edit; modified.timeline.audio[0].volumeDB = -3; journal.commit(modified)
    try disk.save(journal)
    let manifestURL = disk.folder(journal.id).appendingPathComponent("project.json")
    let historyURL = disk.folder(journal.id).appendingPathComponent("History")
    let filesBefore = try FileManager.default.contentsOfDirectory(at: historyURL, includingPropertiesForKeys: nil)
    let bytesBefore = try Dictionary(uniqueKeysWithValues: filesBefore.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
    journal.undo(); journal.append(b); try disk.save(journal)
    let filesAfter = try FileManager.default.contentsOfDirectory(at: historyURL, includingPropertiesForKeys: nil)
    try require(filesAfter.count == filesBefore.count, "Recording publishes no rewritten history payloads")
    for file in filesAfter { let bytes = try Data(contentsOf: file); try require(bytes == bytesBefore[file.lastPathComponent], "Every old snapshot stays byte-identical") }
    let summary = try disk.read(manifestURL, summary: true)
    try require(summary.deferredHistory != nil && summary.canRedo && summary.edit.clips.count == 2, "Library reads only the active snapshot and materializes later capture")
    do { try disk.save(summary); throw NSError(domain: "RecordingQA", code: 2) } catch ProjectError.invalidDocument {}
    journal = try disk.read(manifestURL); journal.redo()
    try require(journal.edit.timeline.audio[0].volumeDB == -3 && journal.edit.clips.count == 2, "Journal capture survives reopened Redo")
    let stableIDs = journal.edit.timeline.allIDs
    try require(stableIDs == journal.edit.timeline.allIDs, "Capture materialization uses stable item and link identities")
    let lastCapturedID = journal.edit.timeline.video.last!.id
    var deleted = journal.edit; deleted.timeline.remove(deleted.timeline.selection(of: lastCapturedID)); journal.commit(deleted)
    journal.append(c); try disk.save(journal); journal = try disk.read(manifestURL)
    try require(journal.edit.clips.map(\.sourceID) == [a.id, c.id], "Snapshot capture cursor never resurrects a deliberate deletion")
    journal.undo(); try require(journal.edit.clips.map(\.sourceID) == [a.id, b.id, c.id], "Undo restores a deleted recording while retaining subsequent capture")
    // Corrupt history must be rejected rather than silently losing edits.
    let latestManifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
    let referenced = latestManifest["snapshotFiles"] as! [String]
    let payload = historyURL.appendingPathComponent(referenced[0]), original = try Data(contentsOf: historyURL.appendingPathComponent(referenced[0]))
    try Data("{}".utf8).write(to: payload, options: .atomic)
    do { _ = try disk.read(manifestURL); throw NSError(domain: "RecordingQA", code: 3) } catch ProjectError.invalidDocument {}
    try original.write(to: payload, options: .atomic)
    print("PASS: captured footage survives Undo/Redo, new edits, continuation, legacy migration and explicit missing-take recovery")
}

private func recordingRecoveryAssetTests(root: URL) throws {
    let disk = ProjectDisk(root: root.appendingPathComponent("recovery-assets"))
    var project = Project(title: "Recovery with background video")
    project.append(SourceMedia(filename: "original.mov", duration: 4))
    var background = VideoEffectSettings(.chromaKey, start: 0, end: 4)
    background.set("background", .choice("Video")); background.set("media", .media("effect-background.mov"))
    var edit = project.edit; edit.clips[0].videoEffects = [background]; project.commit(edit)
    try disk.save(project)
    let folder = disk.folder(project.id), manifest = folder.appendingPathComponent("project.json")
    let names = ["original.mov", "effect-background.mov", "effect-unused.mp4", "EFFECT-unused.MOV", ".partial.mov", "1790000000000-new-take.mov"]
    for name in names { try Data("fixture".utf8).write(to: folder.appendingPathComponent(name)) }
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("directory.mov"), withIntermediateDirectories: false)
    func check(_ p: Project) throws {
        let candidates = try disk.unindexedRecordings(in: p).map(\.lastPathComponent)
        try require(candidates == ["1790000000000-new-take.mov"],
                    "Recovery finds actual unindexed takes and excludes background assets, hidden files and directories")
    }
    // The old startup scan attempted this and falsely reported project corruption.
    var mistaken = project; mistaken.append(SourceMedia(filename: "effect-background.mov", duration: 4))
    do { try mistaken.validate(); throw NSError(domain: "RecordingQA", code: 4) } catch ProjectError.invalidDocument {}
    try check(project); try check(disk.read(manifest, summary: true))
    project.undo(); try disk.save(project)
    let summary = try disk.read(manifest, summary: true)
    try require(summary.effectFiles.isEmpty, "Undone background is absent from the library summary")
    try check(summary)
    project.redo(); var removed = project.edit; removed.clips[0].videoEffects = nil; project.commit(removed); try disk.save(project)
    let before = try Data(contentsOf: manifest)
    try check(disk.read(manifest, summary: true)); try check(disk.read(manifest))
    let after = try Data(contentsOf: manifest)
    try require(after == before, "Recovery discovery never rewrites projects")
    let orphan = folder.appendingPathComponent("1790000000000-new-take.mov")
    let sidecar = orphan.deletingPathExtension().appendingPathExtension("events.json")
    try Data("sidecar".utf8).write(to: sidecar)
    try disk.quarantineRecording(orphan, in: project)
    let preserved = disk.recoveryFiles(in: project)
    let remaining = try disk.unindexedRecordings(in: project)
    try require(preserved.count == 1 && remaining.isEmpty, "Quarantine preserves an unfinished take without retrying it on startup")
    let bytes = try Data(contentsOf: preserved[0])
    try require(bytes == Data("fixture".utf8) && FileManager.default.fileExists(atPath: preserved[0].deletingPathExtension().appendingPathExtension("events.json").path), "Recovery keeps the movie and its sidecars together")
    try disk.quarantineRecording(folder.appendingPathComponent("original.mov"), in: project)
    try require(FileManager.default.fileExists(atPath: folder.appendingPathComponent("original.mov").path), "Quarantine refuses a referenced source")
    let afterQuarantine = try Data(contentsOf: manifest)
    try require(afterQuarantine == before, "Quarantine does not modify the project or Undo history")
    print("PASS: recording recovery excludes active, undone, removed and unused background videos while retaining unfinished takes")
}

// Local recovery utility: writes a new manifest, never the input or a device.
// Run only after the regression tests above pass, with explicit input/output/ID.
func recoverUnusedRecording() throws {
    let env = ProcessInfo.processInfo.environment
    guard let input = env["YOUREC_RECOVERY_INPUT"], let output = env["YOUREC_RECOVERY_OUTPUT"],
          input != output, !FileManager.default.fileExists(atPath: output),
          let id = env["YOUREC_RECOVERY_SOURCE"].flatMap(UUID.init(uuidString:)) else { throw ProjectError.invalidDocument }
    var project = try JSONDecoder().decode(Project.self, from: Data(contentsOf: URL(fileURLWithPath: input)))
    try project.validate()
    try project.restoreUnusedRecording(id)
    try project.validate()
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let destination = URL(fileURLWithPath: output)
    let temporary = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".partial")
    defer { try? FileManager.default.removeItem(at: temporary) }
    try encoder.encode(project).write(to: temporary, options: .atomic)
    try FileManager.default.moveItem(at: temporary, to: destination)
    print("RECOVERED: \(project.edit.duration) seconds, \(project.history.count) editing states, cursor \(project.historyCursor)")
}


private func automaticCanvasHistoryTests(root: URL) throws {
    let portrait = SourceMedia(filename: "portrait.mov", duration: 3)
    let landscape = SourceMedia(filename: "landscape.mov", duration: 4)
    let portraitSize = CGSize(width: 1080, height: 1920)
    var project = Project(title: "Canvas history")
    project.append(landscape)
    project.recordingInsertion = 0
    project.addRecording(portrait)
    try require(project.schemaVersion == 10 && project.edit.clips.first?.sourceID == portrait.id && project.edit.canvasSourceID == landscape.id,
                "Recording at the front preserves the existing picture reference")
    let disk = ProjectDisk(root: root.appendingPathComponent(UUID().uuidString))
    try disk.save(project)
    let url = disk.folder(project.id).appendingPathComponent("project.json")
    project = try disk.read(url)
    try require(project.edit.canvasSourceID == landscape.id && project.edit.outputSize == nil, "A non-leading automatic reference survives disk reopen")
    var pictures = project.edit
    pictures.timeline.video.removeAll { $0.content.sourceID == landscape.id }
    pictures.timeline.links.removeAll()
    for i in pictures.timeline.audio.indices { pictures.timeline.audio[i].followsVideo = nil }
    project.commit(pictures)
    try project.validate()
    try require(project.edit.canvasSourceID == portrait.id && project.edit.timeline.audio.contains { $0.sourceID == landscape.id },
                "Detached audio alone cannot hold the old picture orientation")
    project.undo(); try require(project.edit.canvasSourceID == landscape.id, "Undo restores the former reference")
    project.redo(); try require(project.edit.canvasSourceID == portrait.id, "Redo restores the remaining picture's orientation")

    // Recreate the on-disk representation written by the old UI. A later capture
    // must neither rewrite the deletion nor be mistaken for a Crop operation.
    var old = Project(title: "Implicit portrait padding")
    old.append(portrait); old.append(landscape)
    var deleted = old.edit; deleted.clips.removeFirst(); deleted.outputSize = portraitSize; old.commit(deleted)
    var gain = old.edit; gain.timeline.audio[0].volumeDB = -3; old.commit(gain)
    var crop = old.edit; crop.clips[0].crop = CropSettings(zoom: 1.2); old.commit(crop)
    old.append(SourceMedia(filename: "subsequent.mov", duration: 2))
    old.undo()
    func reopenLegacy(_ project: Project) throws -> Project {
        var header = try JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as! [String: Any]
        header.removeValue(forKey: "automaticCanvasVersion")
        return try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: header))
    }
    try disk.save(old)
    let legacyURL = disk.folder(old.id).appendingPathComponent("project.json")
    var header = try JSONSerialization.jsonObject(with: Data(contentsOf: legacyURL)) as! [String: Any]
    header.removeValue(forKey: "automaticCanvasVersion")
    try JSONSerialization.data(withJSONObject: header).write(to: legacyURL)
    let summary = try disk.read(legacyURL, summary: true)
    try require(summary.deferredHistory != nil, "Project browser can still load only the current snapshot")
    var recovered = try disk.read(legacyURL)
    try disk.save(recovered)
    recovered = try disk.read(legacyURL)
    try require(recovered.edit.outputSize == nil && recovered.edit.canvasSourceID == landscape.id && recovered.edit.timeline.audio[0].volumeDB == -3,
                "Opening a padded project repairs its automatic format without losing later edits")
    recovered.undo(); recovered.undo()
    try require(recovered.edit.canvasSourceID == portrait.id && recovered.edit.clips.count == 3, "Undo recovers portrait and the later appended take")
    recovered.redo(); recovered.redo(); recovered.redo()
    try require(recovered.edit.outputSize == portraitSize && recovered.edit.clips[0].crop?.zoom == 1.2, "Redoing a deliberate crop retains its fixed format")

    var explicit = Project(title: "Intentional portrait output")
    explicit.append(landscape)
    var fixed = explicit.edit; fixed.outputSize = portraitSize; explicit.commit(fixed)
    let preserved = try reopenLegacy(explicit)
    try require(preserved.edit.outputSize == portraitSize, "A deliberate shape-only edit stays fixed even without a crop rectangle")
    explicit.history = [fixed]; explicit.historyCursor = 0
    let ambiguous = try reopenLegacy(explicit)
    try require(ambiguous.edit.outputSize == portraitSize, "A format without evidence of how it was chosen stays fixed")
}

func batchVideoImportTests(_ root: URL) async throws {
    try timelineVideoInsertionTests()
    try await stillPhotoImportTests(root)
    func requireFailure(_ operation: () async throws -> Void, _ message: String) async throws {
        do { try await operation() } catch { return }
        try require(false, message)
    }
    let fm = FileManager.default, disk = ProjectDisk(root: root.appendingPathComponent("BatchProjects"))
    var project = Project(title: "Batch import")
    let baseline = SourceMedia(filename: "original.mp4", duration: 4)
    project.append(baseline); try disk.save(project)
    let folder = disk.folder(project.id)
    try fm.copyItem(at: root.appendingPathComponent("source.mp4"), to: folder.appendingPathComponent(baseline.filename))
    func privateCopy(_ name: String) throws -> URL {
        let copy = root.appendingPathComponent(UUID().uuidString + ".mp4")
        try fm.copyItem(at: root.appendingPathComponent(name), to: copy)
        return copy
    }
    func read() throws -> Project { try disk.read(folder.appendingPathComponent("project.json")) }
    var batch = try VideoBatchImport(folder: folder)
    for name in ["cadence60.mp4", "source.mp4", "cadence24.mp4"] {
        try await batch.stage(privateCopy: privateCopy(name), originalName: name)
    }
    let saved = try batch.commit(to: project, at: 1.25, disk: disk)
    let loaded = try read(), takes = batch.sources
    let expected = [baseline.id] + takes.map(\.id) + [baseline.id]
    try require(loaded.edit.clips.map(\.sourceID) == expected && saved.edit == loaded.edit, "Middle insertion respects selection order on disk")
    try require(abs(loaded.edit.clips.first!.duration-1.25)<0.0001 && abs(loaded.edit.clips.last!.duration-2.75)<0.0001, "Only the original clip is split, once at the playhead")
    try require(!fm.fileExists(atPath: batch.directory.path) && takes.allSatisfy { fm.fileExists(atPath: folder.appendingPathComponent($0.filename).path) }, "All originals are durable, staging is gone")
    var replay = loaded; replay.undo()
    try require(replay.edit == project.edit && !replay.canUndo, "One Undo restores the exact previous edit")
    replay.redo(); try require(replay.edit == loaded.edit, "One Redo restores the complete sequence")
    var reused = loaded; reused.undo()
    reused.insertVideos([takes[2], takes[0]], at: 0)
    try require(reused.edit.clips.map(\.sourceID) == [takes[2].id, takes[0].id, baseline.id] && reused.sources.count == loaded.sources.count, "Unused takes reuse their originals in the chosen order")

    var corrupt = try VideoBatchImport(folder: folder)
    try await corrupt.stage(privateCopy: privateCopy("source.mp4"), originalName: "Good")
    let bad = root.appendingPathComponent("broken.mov"); try Data([1,2,3]).write(to: bad)
    try await requireFailure({ try await corrupt.stage(privateCopy: bad, originalName: "Broken") }, "Invalid video must fail")
    let badImage = root.appendingPathComponent("broken.png")
    try Data([1,2,3]).write(to: badImage)
    try await requireFailure({ try await corrupt.stage(privateCopy: badImage, originalName: "Broken.png", isPhoto: true) },
                             "An unreadable photo must fail the batch")
    corrupt.discard()
    let afterFailure = try read()
    try require(afterFailure.edit == loaded.edit && !fm.fileExists(atPath: corrupt.directory.path), "A bad later clip leaves no partial edit or staged movies")

    var interrupted = try VideoBatchImport(folder: folder)
    try await interrupted.stage(privateCopy: privateCopy("source.mp4"), originalName: "Uncommitted")
    let orphan = interrupted.sources[0].filename
    let committed = takes[0].filename
    try JSONEncoder().encode([orphan, committed]).write(to: interrupted.directory.appendingPathComponent("promoting.json"))
    try fm.moveItem(at: interrupted.directory.appendingPathComponent(orphan), to: folder.appendingPathComponent(orphan))
    let candidates = try disk.unindexedRecordings(in: loaded)
    try require(candidates.isEmpty, "Half-published Photos imports are never recovered as recordings")
    try VideoBatchImport.recover(in: loaded, folder: folder)
    try require(!fm.fileExists(atPath: folder.appendingPathComponent(orphan).path) && fm.fileExists(atPath: folder.appendingPathComponent(committed).path), "Recovery distinguishes pre- and post-manifest publication")

    var rollback = try VideoBatchImport(folder: folder)
    for _ in 0..<2 { try await rollback.stage(privateCopy: privateCopy("source.mp4"), originalName: nil) }
    try fm.removeItem(at: rollback.directory.appendingPathComponent(rollback.sources[1].filename))
    try await requireFailure({ _ = try rollback.commit(to: loaded, at: 0, disk: disk) }, "Missing staged take must fail")
    rollback.discard()
    let afterRollback = try read()
    try require(afterRollback.edit == loaded.edit && rollback.sources.allSatisfy { !fm.fileExists(atPath: folder.appendingPathComponent($0.filename).path) }, "Failure after promotion of the first movie rolls back the batch")
    var cancelled = try VideoBatchImport(folder: folder)
    try await cancelled.stage(privateCopy: privateCopy("source.mp4"), originalName: nil)
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try cancelled.commit(to: loaded, at: 0, disk: disk)
    }
    do { _ = try await task.value; try require(false, "Cancelled insertion must fail") } catch is CancellationError {}
    cancelled.discard()
    let afterCancel = try read()
    try require(afterCancel.edit == loaded.edit && !fm.fileExists(atPath: cancelled.directory.path), "Cancelled batch publishes nothing")
    print("PASS: ordered batch, one ripple edit, persistent Undo/Redo, unused takes, rollback, interruption and cancellation")
}

private func stillPhotoImportTests(_ root: URL) async throws {
    let disk = ProjectDisk(root: root.appendingPathComponent("PhotoProjects"))
    var project = Project(title: "Screenshot at start")
    let original = SourceMedia(filename: "original.mp4", duration: 4)
    project.append(original)
    try disk.save(project)
    let folder = disk.folder(project.id)
    try FileManager.default.copyItem(at: root.appendingPathComponent("source.mp4"), to: folder.appendingPathComponent(original.filename))
    let bitmap = CGContext(data: nil, width: 121, height: 215, bitsPerComponent: 8, bytesPerRow: 0,
                           space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    bitmap.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
    bitmap.fill(CGRect(x: 0, y: 0, width: 121, height: 35))
    bitmap.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    bitmap.fill(CGRect(x: 0, y: 180, width: 121, height: 35))
    let screenshot = root.appendingPathComponent("screenshot.png")
    let png = CGImageDestinationCreateWithURL(screenshot as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(png, bitmap.makeImage()!, nil)
    try require(CGImageDestinationFinalize(png), "Write screenshot fixture")
    var batch = try VideoBatchImport(folder: folder)
    defer { batch.discard() }
    try await batch.stage(privateCopy: screenshot, originalName: "Screenshot.png", isPhoto: true)
    let photo = batch.sources[0]
    _ = try batch.commit(to: project, at: 0, site: .start, disk: disk)
    var saved = try disk.read(folder.appendingPathComponent("project.json"))
    try require(saved.edit.clips.map(\.sourceID) == [photo.id, original.id] && saved.edit.duration == 7 &&
                saved.edit.timeline.audio.map(\.sourceID) == [original.id] && saved.edit.canvasSourceID == original.id,
                "A screenshot adds three seconds of picture, preserving existing sound and framing")
    let export = root.appendingPathComponent("photo-export.mp4")
    _ = try await MediaRenderer.render(project: saved, folder: folder, destination: export) { _ in }
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: export))
    generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
    func rgb(_ image: CGImage, y: Double) -> [UInt8] {
        let patch = image.cropping(to: CGRect(x: image.width / 2, y: Int(Double(image.height) * y), width: 2, height: 2))!
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes {
            let sample = CGContext(data: $0.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            sample.draw(patch, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes
    }
    for frame in [0, 45, 89] {
        let image = try await generator.image(at: CMTime(value: Int64(frame), timescale: 30)).image
        let top = rgb(image, y: 0.08), bottom = rgb(image, y: 0.92), middle = rgb(image, y: 0.50)
        try require(top[0] > 190 && top[2] < 55 && bottom[2] > 190 && bottom[0] < 55 && middle.prefix(3).max()! < 20,
                    "Exported frame \(frame) must show both colored ends upright and flatten transparent pixels onto black")
    }
    saved.undo()
    let restored = saved.sources.first { $0.id == photo.id }!
    saved.insertVideos([restored], at: saved.edit.duration, site: .end)
    try require(saved.edit.timeline.audio.count == 1 && saved.edit.clips.last?.sourceID == photo.id,
                "Reusing an unused photo preserves its picture-only track")

    var empty = Project(title: "Photo only")
    try disk.save(empty)
    let emptyFolder = disk.folder(empty.id)
    let jpeg = root.appendingPathComponent("rotated-photo.jpg")
    let jpg = CGImageDestinationCreateWithURL(jpeg as CFURL, "public.jpeg" as CFString, 1, nil)!
    CGImageDestinationAddImage(jpg, bitmap.makeImage()!, [kCGImagePropertyOrientation: 6] as CFDictionary)
    try require(CGImageDestinationFinalize(jpg), "Write JPEG with camera orientation")
    var rotated = try VideoBatchImport(folder: emptyFolder)
    defer { rotated.discard() }
    try await rotated.stage(privateCopy: jpeg, originalName: "Photo.jpg", isPhoto: true)
    empty = try rotated.commit(to: empty, at: 0, site: .start, disk: disk)
    let photoOnly = root.appendingPathComponent("photo-only-export.mp4")
    let receipt = try await MediaRenderer.render(project: empty, folder: emptyFolder, destination: photoOnly) { _ in }
    let savedAsset = AVURLAsset(url: photoOnly)
    let audio = try await savedAsset.loadTracks(withMediaType: .audio)
    try require(empty.edit.timeline.audio.isEmpty && audio.isEmpty && receipt.width == 216 && receipt.height == 122,
                "A photo alone exports silently, with the JPEG's display orientation and even dimensions")
    print("PASS: screenshot insertion, standalone storage, orientation, transparency and frames through the end of export")
}

private func timelineVideoInsertionTests() throws {
    let left = SourceMedia(filename: "left.mov", duration: 4)
    let right = SourceMedia(filename: "right.mov", duration: 2)
    let short = SourceMedia(filename: "short.mov", duration: 2)
    let long = SourceMedia(filename: "long.mov", duration: 8)
    let bed = SourceMedia(filename: "bed.m4a", duration: 16, audioOnly: true)
    var project = Project(title: "Video insertion sites")
    project.append(left); project.append(right)
    project.sources += [short, long, bed]
    var gapped = project.edit
    gapped.timeline.insertTime(EditTime(6), at: EditTime(4))
    gapped.timeline.insertAudio(bed, at: .zero)
    project.commit(gapped)
    let original = project.edit
    let gap = VideoInsertionSite.gap(after: EditTime(4))
    var layered = original.timeline
    let overlay = TimelineClip(sourceID: long.id, start: 0, end: 5)
    layered.video.append(VideoTimelineItem(occurrenceID: UUID(), start: EditTime(3), content: overlay, layer: 1))
    layered.generated.append(TimelineGeneratedRegion(id: UUID(), owner: UUID(), interval: EditInterval(8...10)))
    try require(layered.videoCoverage == [EditInterval(0...12)], "Overlapping layers and generated transition frames do not expose false gaps")
    func start(_ edit: EditState, _ source: SourceMedia) -> Double? {
        edit.timeline.video.first { $0.content.sourceID == source.id }?.start.seconds
    }
    var filled = project
    filled.insertVideos([short, short], at: 8, site: gap)
    try require(filled.edit.timeline.video.map(\.start.seconds) == [0, 4, 6, 10], "Batch fills from left edge, preserving the remaining gap and the right clip")
    try require(filled.edit.timeline.audio.first { $0.sourceID == bed.id } == original.timeline.audio.first { $0.sourceID == bed.id }, "Audio crossing a picture gap stays intact when inserts fit")
    filled.undo(); try require(filled.edit == original, "One Undo restores the exact gap")
    filled.redo(); try require(start(filled.edit, right) == 10, "Redo preserves the right clip timing")
    var overflow = project
    overflow.insertVideos([long], at: 8, site: gap)
    try require(start(overflow.edit, long) == 4 && start(overflow.edit, right) == 12, "Only overflow ripples at the right edge")
    try require(overflow.edit.timeline.audio.filter { $0.sourceID == bed.id } == original.timeline.audio.filter { $0.sourceID == bed.id }, "Overflow keeps an independent soundtrack continuous")
    var appended = project
    appended.insertVideos([short], at: 16, site: .end)
    try require(start(appended.edit, short) == 12 && appended.edit.duration == 16, "Append meets last picture before an audio-only tail")
    var leading = original
    leading.timeline.insertTime(EditTime(5), at: .zero)
    var prepend = project; prepend.commit(leading)
    prepend.insertVideos([short], at: 0, site: .start)
    try require(start(prepend.edit, short) == 3 && start(prepend.edit, left) == 5, "Prepend backfills the lead-in flush against the first picture")
    prepend.undo(); prepend.insertVideos([long], at: 0, site: .start)
    try require(start(prepend.edit, long) == 0 && start(prepend.edit, left) == 8, "A long prepend shifts only its excess")
    var audioOnly = Project(title: "Soundtrack")
    audioOnly.sources = [bed, short]
    var music = audioOnly.edit; music.timeline.insertAudio(bed, at: .zero); audioOnly.commit(music)
    audioOnly.insertVideos([short], at: 10, site: .start)
    try require(start(audioOnly.edit, short) == 0 && audioOnly.edit.timeline.audio.first { $0.sourceID == bed.id }?.start == .zero, "First picture starts with the soundtrack")

    let a = SourceMedia(filename: "take-a.mov", duration: 2), b = SourceMedia(filename: "take-b.mov", duration: 4)
    for site in [VideoInsertionSite.start, gap, .end] {
        var recorded = project
        if site == .start { recorded.commit(leading) }
        let base = recorded.edit
        recorded.beginRecordingInsertion(at: 0, site: site)
        recorded.addRecording(a)
        recorded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(recorded))
        recorded.addRecording(b); recorded.recordingInsertion = nil; recorded.recordingInsertionStep = nil
        let span = site.placement(in: base.timeline, length: EditTime(6))
        try require(start(recorded.edit, a) == span.start.seconds && start(recorded.edit, b) == span.start.seconds + 2, "Recorded segments match an ordered import after reload")
        try recorded.validate()
        recorded.undo(); try require(recorded.edit.timeline.video == base.timeline.video && recorded.edit.timeline.audio == base.timeline.audio, "Record here remains a single Undo")
    }
}
