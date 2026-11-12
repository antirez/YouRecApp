import Foundation
import AVFoundation
import Darwin

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw NSError(domain: "YouRecTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

@main
struct CoreTests {
    static func main() async {
        setbuf(stdout, nil)
        do { try await run() }
        catch { fputs("FAIL: \(error.localizedDescription) [\(error as NSError)]\n", stderr); exit(1) }
    }
    static func run() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        if CommandLine.arguments.contains("--effect-animation") { try await effectAnimationTests(root:root); return }
        if CommandLine.arguments.contains("--auto-background-export") { try await autoBackgroundExportTests(root); return }
        if CommandLine.arguments.contains("--batch-video-import") { try await batchVideoImportTests(root); return }
        if CommandLine.arguments.contains("--export-options") { try await exportOptionsTests(root); return }
        if CommandLine.arguments.contains("--export-resume") { try await resumableExportTests(root); return }
        if CommandLine.arguments.contains("--duplicate-project") { try await duplicateProjectTests(root); return }
        if CommandLine.arguments.contains("--editorial-timeline") {
            var project = Project(title: "YouRec interchange QA")
            let first = SourceMedia(filename: "source.mp4", duration: 4), other = SourceMedia(filename: "next-scene.mp4", duration: 4)
            project.sources = [first, other]
            var edit = EditState(clips: [TimelineClip(sourceID: first.id, start: 1, end: 3), TimelineClip(sourceID: other.id, start: 0, end: 2)])
            edit.timeline.unlink(TimelineSelection(audio: [edit.timeline.audio[1].id]))
            edit.timeline.video[1].start = EditTime(3)
            edit.timeline.audio[1].start = EditTime(1.5)
            project.commit(edit)
            // A simple overlapping dissolve must import as a transition on one
            // track, with enough source media on both sides of its new cut.
            var dissolved = Project(title: "Dissolve QA")
            dissolved.sources = project.sources
            var left = TimelineClip(sourceID: first.id, start: 0, end: 3)
            let right = TimelineClip(sourceID: other.id, start: 0, end: 3)
            var transition = ClipTransition(); transition.duration = 1; transition.nextClipID = right.id
            left.transition = transition
            dissolved.commit(EditState(clips: [left, right]))
            let conform = try EditorialTimeline.data(for: dissolved)
            try conform.write(to: root.appendingPathComponent("Dissolve.otio"))
            try require(String(decoding: conform, as: UTF8.self).contains("SMPTE_Dissolve"), "An isolated cross dissolve is editable on a single track")
            let archiveURL = root.appendingPathComponent("Editorial.zip")
            try await ProjectArchive.export(project, folder: root, destination: archiveURL) { _ in }
            let archive = try Archive(url: archiveURL, accessMode: .read)
            try require(archive["Timeline.otio"] != nil, "A project ZIP contains the editable interchange timeline")
            let restored = try await ProjectArchive.restore(archiveURL, disk: ProjectDisk(root: root.appendingPathComponent("Restored"))) { _ in }
            try require(restored.edit == project.edit && restored.id != project.id, "Native restore retains edits and imports independently")
            let old = try Archive(url: archiveURL, accessMode: .update)
            try old.remove(old["Timeline.otio"]!)
            let legacy = try await ProjectArchive.restore(archiveURL, disk: ProjectDisk(root: root.appendingPathComponent("Legacy"))) { _ in }
            try require(legacy.edit == project.edit, "Projects without an OTIO file still restore")
            try await ProjectArchive.export(project, folder: root, destination: root.appendingPathComponent("Resolve.zip")) { _ in }
            print("PASS: editable ZIP and both generations of native restore")
            return
        }
        if CommandLine.arguments.contains("--large-backup") { try await largeBackupTests(root); return }
        if CommandLine.arguments.contains("--snap-boundary-only") { try await snappedBoundaryMediaTests(root: root); return }
        if CommandLine.arguments.contains("--audio-import-censor") { try await audioImportCensorTests(root: root); return }
        if CommandLine.arguments.contains("--color-only") { try await colorGradeTests(root: root); return }
        if CommandLine.arguments.contains("--log-writer") { try await logWriterTests(root: root); return }
        if CommandLine.arguments.contains("--log-recording") { try await inspectLogRecording(root: root); return }
        if CommandLine.arguments.contains("--audio-preview-window") { try await audioPreviewWindowTests(root: root); return }
        if CommandLine.arguments.contains("--audio-filter-audit") { try await audioFilterAudit(root: root); return }
        if CommandLine.arguments.contains("--abrupt-writer-child") { try await abruptWriterChild(root: root); return }
        if CommandLine.arguments.contains("--export-recovered-fixture") { try await exportRecoveredFixture(root: root); return }
        if CommandLine.arguments.contains("--project-recovery") { try await projectRecoveryTests(root: root); try recordingHistoryTests(root: root); return }
        if CommandLine.arguments.contains("--titles-only") { try await titleDesignTests(root: root); return }
        if CommandLine.arguments.contains("--subtitles-only") { try await subtitleTests(root: root); return }
        if CommandLine.arguments.contains("--capture-only") { try captureAudioTests(); try dualLayoutTests(); return }
        if CommandLine.arguments.contains("--stabilization-only") { try await stabilizationTests(root: root); return }
        if CommandLine.arguments.contains("--effect-application") { try await effectApplicationTests(root: root); return }
        if CommandLine.arguments.contains("--night-fix-only") {try await nightFixTests(root:root);return}
        if CommandLine.arguments.contains("--project-retention") { try projectRetentionTests(root: root); return }
        if CommandLine.arguments.contains("--expanded-transitions") {
            let folder = root.appendingPathComponent("expanded-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: root.appendingPathComponent("source.mp4"), to: folder.appendingPathComponent("source.mp4"))
            var project = Project(title: "Expanded transitions"); project.append(SourceMedia(filename: "source.mp4", duration: 4))
            try await expandedTransitionTests(project: project, root: root, folder: folder); return
        }
        if CommandLine.arguments.contains("--export-audio-levels") { try await exportAudioLevelTests(root: root); return }
        if CommandLine.arguments.contains("--tracks-media") { try await trackMediaTests(root: root); return }
        try await subtitleTests(root: root)
        try trackTimelineTests()
        if CommandLine.arguments.contains("--tracks-only") { return }
        try recordingHistoryTests(root: root)
        if CommandLine.arguments.contains("--effects-audio-stress") {
            for iteration in 0..<(Int(ProcessInfo.processInfo.environment["YOUREC_AUDIO_ITERATIONS"] ?? "12") ?? 12) {
                let folder=root.appendingPathComponent("audio-stress-\(iteration)-"+UUID().uuidString,isDirectory:true)
                try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
                try FileManager.default.copyItem(at:root.appendingPathComponent("source.mp4"),to:folder.appendingPathComponent("source.mp4"))
                print("AUDIO STRESS: begin \(iteration)")
                try await backgroundVideoAudioTests(root:root,folder:folder)
                print("AUDIO STRESS: complete \(iteration)")
            }
            return
        }
        if CommandLine.arguments.contains("--video-tools-only") { try await videoToolsTests(root: root); return }
        if CommandLine.arguments.contains("--effects-only") { try await videoEffectIntegrationTests(root: root); return }
        if CommandLine.arguments.contains("--history-only") { return }
        if CommandLine.arguments.contains("--recover-recording") { try recoverUnusedRecording(); return }
        if CommandLine.arguments.contains("--pauses-only") { try await pausesTests(root: root); return }
        if CommandLine.arguments.contains("--transitions-only") { try await transitionTests(root: root); return }
        var failures: [String] = []
        func check(_ name: String, _ body: () async throws -> Void) async {
            do { try await body() }
            catch { let failure = "\(name): \(error.localizedDescription)"; failures.append(failure); print("SUITE FAILED: " + failure) }
        }
        func finish() throws {
            if !failures.isEmpty { throw NSError(domain: "YouRecTests", code: 1, userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "\n")]) }
        }
        await check("Video effects") { try await videoEffectIntegrationTests(root: root) }
        await check("Batch video import") { try await batchVideoImportTests(root) }
        await check("Transitions") { try await transitionTests(root: root) }
        await check("Pauses") { try await pausesTests(root: root) }
        await check("Video tools") { try await videoToolsTests(root: root) }
        if CommandLine.arguments.contains("--tools-only") { try finish(); return }
        await check("Stabilization") { try await stabilizationTests(root: root) }
        if CommandLine.arguments.contains("--stabilization-only") { try finish(); return }
        let disk = ProjectDisk(root: root.appendingPathComponent("projects"))
        var project = Project(title: "Persistence and signal test")
        let source = SourceMedia(filename: "source.mp4", duration: 4)
        project.append(source)
        var edited = project.edit
        edited.clips[0].start = 0.5; edited.clips[0].end = 3.5
        edited.effects = [.make(.highPass), .make(.equalizer), AudioEffect(kind: .gain, amount: -6)]
        project.commit(edited)
        project.undo()
        try disk.save(project)
        var reopened = try disk.read(disk.folder(project.id).appendingPathComponent("project.json"))
        try require(reopened.canRedo && reopened.edit.clips[0].start == 0, "Undo cursor survives disk round trip")
        reopened.redo()
        try require(reopened.edit == edited, "Redo restores exact clips and ordered effects")
        reopened.undo()
        var branch = reopened.edit; branch.clips[0].end = 2
        reopened.commit(branch)
        try require(!reopened.canRedo && reopened.sources == [source], "Divergent edit drops redo, preserves original")
        var malformed = reopened; malformed.historyCursor = -1
        do { try malformed.validate(); throw NSError(domain: "YouRecTests", code: 2) }
        catch ProjectError.invalidDocument {}
        var badRange = reopened; badRange.history[badRange.historyCursor].clips[0].end = 5
        do { try badRange.validate(); throw NSError(domain: "YouRecTests", code: 3) }
        catch ProjectError.invalidDocument {}
        var pathEscape = reopened; pathEscape.sources[0].filename = "../source.mp4"
        do { try pathEscape.validate(); throw NSError(domain: "YouRecTests", code: 4) }
        catch ProjectError.invalidDocument {}
        try require(reopened.sources[0].duration == 4, "Source duration is immutable across trim")
        var future = reopened
        var futureEdit = future.edit
        var unknown = AudioEffect(kind: .unavailable("futureDereverbV9"), amount: 42)
        unknown.implementationVersion = 9
        futureEdit.effects.append(unknown); future.commit(futureEdit)
        try disk.save(future)
        let preserved = try disk.read(disk.folder(future.id).appendingPathComponent("project.json"))
        try require(preserved.edit.effects.last == unknown && preserved.canUndo, "Unknown effect kind and version preserve project, settings, and history")
        try disk.save(project)

        var bypass = AudioChainProcessor(effects: [AudioEffect(kind: .highPass, enabled: false)])
        for index in 0..<5000 {
            let input = Float(sin(Double(index) * 0.17) * 0.8)
            try require(bypass.sample(input, channel: 0) == input, "Bypass is bit-exact")
        }
        var gain = AudioChainProcessor(effects: [AudioEffect(kind: .gain, amount: -6), AudioEffect(kind: .gain, amount: 3)])
        let expected = Float(0.5 * pow(10, -3.0 / 20))
        try require(abs(gain.sample(0.5, channel: 0) - expected) < 0.000001, "Repeated stages compound independently")
        var dc = AudioChainProcessor(effects: [.make(.highPass)])
        var tail: Float = 0
        for _ in 0..<48000 { tail = dc.sample(0.25, channel: 0) }
        try require(abs(tail) < 0.000001, "Low-cut removes DC")
        try require(dc.sample(0, channel: 1) == 0, "Stereo channel state is independent")
        var eq = AudioChainProcessor(effects: [AudioEffect(kind: .equalizer, amount: 24, frequency: 12000)])
        for index in 0..<96000 {
            let result = eq.sample(Float(sin(Double(index))), channel: index % 2)
            try require(result.isFinite, "Extreme supported EQ remains stable")
        }
        print("PASS: persistence, persistent undo/redo, branching, document validation, bypass, chained gain, DC rejection, stereo state, EQ stability")
        try listeningLevelTests()

        let whole = EditState(clips: [TimelineClip(sourceID: source.id, start: 0, end: 4)])
        let split = TimelineEditing.split(whole, at: 2)
        try require(split.clips.count == 2 && split.duration == 4 && split.clips[0].end == split.clips[1].start, "Split keeps all frames and source coordinates")
        try require(TimelineEditing.split(whole, at: 0) == whole, "Boundary split does not create an empty clip")
        let removed = TimelineEditing.removing(1...3, from: split)
        try require(removed.clips.count == 2 && removed.duration == 2 && removed.clips[0].start == 0 && removed.clips[0].end == 1 && removed.clips[1].start == 3 && removed.clips[1].end == 4, "Ripple range deletion crosses clip boundaries without shifting source coordinates")
        try require(TimelineEditing.removing(0...4, from: split).clips.isEmpty, "Whole selection can be removed and undone")
        let tiny = TimelineEditing.removing(0.001...0.002, from: whole)
        try require(tiny == whole, "Subframe accidental selection is a no-op")
        print("PASS: frame-aligned split, cross-clip range deletion, empty result, boundary and subframe guards")

        await check("Neural audio") { try await neuralTests(root: root) }
        await check("DeepFilter") { try await deepFilterTests(root: root) }
        await check("Capture PCM") { try captureAudioTests() }

        if CommandLine.arguments.contains("--core-only") { try finish(); return }
        print("MEDIA: constructing timeline")
        let folder = disk.folder(project.id)
        try FileManager.default.copyItem(at: root.appendingPathComponent("source.mp4"), to: folder.appendingPathComponent("source.mp4"))
        project.redo()
        let original = try Data(contentsOf: folder.appendingPathComponent("source.mp4"))
        let timeline = try await MediaRenderer.timeline(project: project, folder: folder)
        print("MEDIA: decoding waveform")
        let peaks = try await MediaRenderer.waveform(asset: timeline.composition, duration: project.edit.duration).peaks
        try require(peaks.count == 600 && peaks.max()! > 0.001, "Waveform contains decoded audio")
        print("MEDIA: rendering with audio chain")
        let output = root.appendingPathComponent("rendered.mp4")
        _ = try await MediaRenderer.render(project: project, folder: folder, destination: output) { _ in }
        let receipt = try JSONDecoder().decode(ExportReceipt.self, from: Data(contentsOf: output.deletingPathExtension().appendingPathExtension("json")))
        try require(receipt.edit == project.edit && receipt.sourceChecksums[source.id.uuidString]?.count == 64, "Export receipt preserves exact edit and original checksum")
        let rendered = AVURLAsset(url: output)
        let duration = try await rendered.load(.duration).seconds
        try require(abs(duration - 3) < 1.0 / 30, "Export retains trimmed duration")
        let audio = try await rendered.loadTracks(withMediaType: .audio)
        try require(audio.count == 1, "Rendered chain includes audio")
        let after = try Data(contentsOf: folder.appendingPathComponent("source.mp4"))
        try require(original == after, "Render preserves source bytes")
        do {
            _ = try await MediaRenderer.render(project: project, folder: folder, destination: output) { _ in }
            throw NSError(domain: "YouRecTests", code: 5)
        } catch let error as NSError { try require(error.domain != "YouRecTests", "Export refuses to overwrite existing file") }
        print("PASS: waveform decoding, trimmed video/audio rendering, source preservation, existing export protection")

        var neuralProject = project
        var neuralEdit = neuralProject.edit
        neuralEdit.effects = [.make(.voiceIsolation), AudioEffect(kind: .gain, amount: -3), .make(.voiceIsolation)]
        neuralProject.commit(neuralEdit)
        let neuralOutput = root.appendingPathComponent("neural.mp4")
        _ = try await MediaRenderer.render(project: neuralProject, folder: folder, destination: neuralOutput) { _ in }
        let neuralAsset = AVURLAsset(url: neuralOutput)
        let neuralDuration = try await neuralAsset.load(.duration).seconds
        try require(abs(neuralDuration - 3) < 1.0 / 30, "Repeated neural stages preserve video timeline duration")

        var silentProject = Project(title: "Silent video")
        silentProject.append(SourceMedia(filename: "silent.mp4", duration: 4))
        var silentEdit = silentProject.edit; silentEdit.effects = [.make(.voiceIsolation)]
        silentProject.commit(silentEdit)
        try FileManager.default.copyItem(at: root.appendingPathComponent("silent.mp4"), to: folder.appendingPathComponent("silent.mp4"))
        let silentMedia = try await MediaRenderer.timeline(project: silentProject, folder: folder)
        let silentWaveform = try await MediaRenderer.waveform(asset: silentMedia.composition, duration: 4).peaks
        try require(silentWaveform.isEmpty, "Silent video has no invented audio waveform")
        _ = try await MediaRenderer.render(project: silentProject, folder: folder, destination: root.appendingPathComponent("silent-render.mp4")) { _ in }
        print("PASS: repeated neural-stage video export, silent-video waveform and export")

        let cache = folder.appendingPathComponent("Cache")
        let beforeCache = Set(try FileManager.default.contentsOfDirectory(atPath: cache.path).filter { $0.hasSuffix(".caf") })
        var cut = neuralProject.edit
        cut.clips = [TimelineClip(sourceID: source.id, start: 0.5, end: 1.5), TimelineClip(sourceID: source.id, start: 2, end: 3)]
        neuralProject.commit(cut)
        let prepared = try await SourceMediaCache.shared.prepared(project: neuralProject, folder: folder) { _ in }
        let afterCache = Set(try FileManager.default.contentsOfDirectory(atPath: cache.path).filter { $0.hasSuffix(".caf") })
        try require(beforeCache == afterCache, "Cuts reuse full-source neural context rather than reprocessing the edited timeline")
        let cachedTrack = try await prepared.media.composition.loadTracks(withMediaType: .audio).first!
        let segments = cachedTrack.segments.filter { !$0.isEmpty }
        try require(segments.count == 2 && abs(segments[0].timeMapping.source.start.seconds - 0.5) < 0.00001 && abs(segments[1].timeMapping.source.start.seconds - 2) < 0.00001, "Processed source audio uses exact original source coordinates at cuts")

        // Simultaneous chains share their expensive first stage. Both must
        // finish with the requested gain and leave one immutable prefix.
        var concurrentA = project, concurrentB = project
        var editA = project.edit, editB = project.edit
        let sharedIsolation = AudioEffect.make(.voiceIsolation)
        editA.effects = [sharedIsolation, AudioEffect(kind: .gain, amount: -3)]
        editB.effects = [sharedIsolation, AudioEffect(kind: .gain, amount: -9)]
        concurrentA.commit(editA); concurrentB.commit(editB)
        let concurrentSnapshotA = concurrentA, concurrentSnapshotB = concurrentB
        async let preparedA = SourceMediaCache.shared.prepared(project: concurrentSnapshotA, folder: folder) { _ in }
        async let preparedB = SourceMediaCache.shared.prepared(project: concurrentSnapshotB, folder: folder) { _ in }
        let pair = try await (preparedA, preparedB)
        let concurrentFiles = Set(try FileManager.default.contentsOfDirectory(atPath: cache.path).filter { $0.hasSuffix(".caf") })
        try require(concurrentFiles.subtracting(afterCache).count == 3, "Overlapping chains retain exactly one shared prefix and two final results")
        try require(abs(pair.1.peak / pair.0.peak - pow(10, -6.0 / 20)) < 0.0001, "Concurrent chains preserve their independent final gain")
        withExtendedLifetime(pair) {}
        print("PASS: concurrent chains share an immutable prefix and preserve independent results")

        for corruption in ["truncated", "missing-peak"] {
            let recoveryFolder = root.appendingPathComponent("cache-recovery-" + corruption, isDirectory: true)
            let recoveryCache = recoveryFolder.appendingPathComponent("Cache", isDirectory: true)
            try FileManager.default.createDirectory(at: recoveryFolder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: folder.appendingPathComponent("source.mp4"), to: recoveryFolder.appendingPathComponent("source.mp4"))
            try FileManager.default.copyItem(at: cache, to: recoveryCache)
            for file in try FileManager.default.contentsOfDirectory(at: recoveryCache, includingPropertiesForKeys: nil) where file.pathExtension == "caf" {
                if corruption == "truncated" { try Data("truncated cache".utf8).write(to: file) }
                else { try? FileManager.default.removeItem(at: file.deletingPathExtension().appendingPathExtension("peak")) }
            }
            let recovered = try await SourceMediaCache.shared.prepared(project: concurrentSnapshotA, folder: recoveryFolder) { _ in }
            try require(recovered.peak == pair.0.peak, "Invalid \(corruption) cache rebuilds the same audio from immutable originals")
        }
        print("PASS: truncated and missing-metadata audio caches recover from originals")

        var fadeProject = project
        var fadeEdit = fadeProject.edit; fadeEdit.effects = []
        fadeEdit.clips = [TimelineClip(sourceID: source.id, start: 0, end: 34.0 / 30), TimelineClip(sourceID: source.id, start: 2.2, end: 3.3)]
        fadeProject.commit(fadeEdit)
        let fadeMedia = try await MediaRenderer.timeline(project: fadeProject, folder: folder)
        let faded = root.appendingPathComponent("faded.caf"), hard = root.appendingPathComponent("hard-cut.caf")
        _ = try await MediaRenderer.processedAudio(asset: fadeMedia.composition, duration: fadeEdit.duration, effects: [], outputURL: faded, mix: fadeMedia.audioMix) { _ in }
        _ = try await MediaRenderer.processedAudio(asset: fadeMedia.composition, duration: fadeEdit.duration, effects: [], outputURL: hard) { _ in }
        func jointPeak(_ url: URL) throws -> Float {
            let file = try AVAudioFile(forReading: url)
            file.framePosition = Int64((fadeEdit.clips[0].duration * 48000).rounded()) - 24
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48)!
            try file.read(into: buffer)
            return (0..<Int(buffer.frameLength)).map { abs(buffer.floatChannelData![0][$0]) }.max() ?? 0
        }
        let fadedPeak = try jointPeak(faded), hardPeak = try jointPeak(hard)
        print("FADE: joint +/-24 samples, faded \(fadedPeak), hard \(hardPeak)")
        try require(fadedPeak < hardPeak * 0.35, "Cut envelope reduces discontinuity within half a millisecond of the join")
        let fadedFile = try AVAudioFile(forReading: faded)
        try require(fadedFile.length == Int64((fadeEdit.duration * 48000).rounded()), "Cut fades never shift audio duration")
        print("PASS: source-context cache reuse, exact source coordinates, measured non-shifting cut envelope")
        neuralProject.undo()
        let archiveURL = root.appendingPathComponent("portable-project.zip")
        try await ProjectArchive.export(neuralProject, folder: folder, destination: archiveURL) { _ in }
        let restored = try await ProjectArchive.restore(archiveURL, disk: disk) { _ in }
        try require(restored.id != neuralProject.id && restored.history == neuralProject.history && restored.historyCursor == neuralProject.historyCursor && restored.canRedo, "Portable archive restores full undo and redo into a distinct project")
        let restoredBytes = try Data(contentsOf: disk.folder(restored.id).appendingPathComponent(source.filename))
        try require(restoredBytes == original, "Archive restores exact original bytes and verifies checksums")
        let maliciousURL = root.appendingPathComponent("malicious.zip")
        let malicious = try Archive(url: maliciousURL, accessMode: .create)
        try malicious.addEntry(with: "../escape.mov", type: .file, uncompressedSize: Int64(1)) { _, _ in Data([1]) }
        do {
            _ = try await ProjectArchive.restore(maliciousURL, disk: disk) { _ in }
            throw NSError(domain: "YouRecTests", code: 101)
        } catch ProjectError.invalidDocument {}
        try require(!FileManager.default.fileExists(atPath: root.appendingPathComponent("escape.mov").path), "Archive traversal is rejected without extracting files")
        try disk.moveToDeleted(restored)
        let deleted = try disk.read(disk.deletedRoot.appendingPathComponent(restored.id.uuidString).appendingPathComponent("project.json"))
        try require(deleted.history == restored.history && deleted.canRedo, "Recently Deleted preserves the full project")
        try disk.restoreDeleted(deleted)
        let undeletedBytes = try Data(contentsOf: disk.folder(restored.id).appendingPathComponent(source.filename))
        try require(undeletedBytes == original, "Restoring Recently Deleted preserves original bytes")
        let incompleteURL = root.appendingPathComponent("incomplete.zip")
        try FileManager.default.copyItem(at: archiveURL, to: incompleteURL)
        let incomplete = try Archive(url: incompleteURL, accessMode: .update)
        try incomplete.remove(incomplete[source.filename]!)
        let recovered = try await ProjectArchive.restore(incompleteURL, disk: disk) { _ in }
        try require(recovered.history == neuralProject.history && recovered.canRedo && recovered.sources.first?.sha256 != nil, "An incomplete archive preserves history and expected source checksums for relinking")
        try require(!FileManager.default.fileExists(atPath: disk.folder(recovered.id).appendingPathComponent(source.filename).path), "Missing source stays explicitly missing")
        let corruptURL = root.appendingPathComponent("corrupted-deflate.zip")
        try FileManager.default.copyItem(at: archiveURL, to: corruptURL)
        var corruptOffset: UInt64 = 0
        do {
            let archive = try Archive(url: corruptURL, accessMode: .update)
            try archive.remove(archive[source.filename]!)
            try archive.addEntry(with: source.filename, relativeTo: folder, compressionMethod: .deflate)
            corruptOffset = archive[source.filename]!.dataOffset
        }
        let handle = try FileHandle(forWritingTo: corruptURL)
        try handle.seek(toOffset: corruptOffset)
        // BTYPE=3 is invalid in a deflate block, independently of CRC.
        try handle.write(contentsOf: Data([0x07])); try handle.close()
        let partiallyRecovered = try await ProjectArchive.restore(corruptURL, disk: disk) { _ in }
        try require(partiallyRecovered.history == neuralProject.history && partiallyRecovered.canRedo, "Corrupted compressed media retains complete editing history")
        try require(!FileManager.default.fileExists(atPath: disk.folder(partiallyRecovered.id).appendingPathComponent(source.filename).path), "Corrupted compressed media is left missing for verified relinking")
        print("PASS: portable archive round trip, persistent redo, immutable originals, path traversal rejection")
        try finish()
}

    static func listeningLevelTests() throws {
        let source = UUID()
        func gains(_ original: [Float], _ processed: [Float], range: ClosedRange<Double>? = nil) -> (original: Float, processed: Float) {
            let range = range ?? 0...(Double(original.count) * SourceListeningLevels.window)
            return SourceListeningLevels.gains(clips: [TimelineClip(sourceID: source, start: range.lowerBound, end: range.upperBound)],
                                              levels: [source: SourceListeningLevels(original: original, processed: processed)])
        }
        let louder = gains([0.01, 0.01], [0.04, 0.04])
        try require(louder.original == 1 && abs(louder.processed - 0.5) < 0.0001, "A +6 dB processed voice remains level-matched")
        let quieter = gains([0.01, 0.01], [0.0025, 0.0025])
        try require(abs(quieter.original - 0.5) < 0.0001 && quieter.processed == 1, "A quieter audible voice remains level-matched")
        let noise = gains([0.0000015, 0.0000015, 0.0000015], [0.00000025, 0.000000001, 0.0000000001])
        try require(noise.original == 1 && noise.processed == 1, "RNNoise leaving near-silence must not turn down the original background noise")
        let loudNoise = gains([0.01, 0.01], [0.00001, 0.00001])
        try require(loudNoise.original == 1 && loudNoise.processed == 1, "Strong suppression is excluded even when its residual is above the silence floor")
        let original = [Float](repeating: 0.01, count: 10) + [0.01, 0.01]
        let processed = [Float](repeating: 0.00000001, count: 10) + [0.04, 0.04]
        let mixed = gains(original, processed)
        try require(mixed.original == 1 && abs(mixed.processed - 0.5) < 0.0001, "Removed noise cannot bias matching of the surviving voice")
        let trimmed = gains(original, processed, range: 0...4)
        try require(trimmed.original == 1 && trimmed.processed == 1, "Trimming away speech restores original noise level instead of matching silence")
        let silent = gains([0, 0], [0, 0])
        try require(silent.original == 1 && silent.processed == 1, "Silent comparisons keep finite neutral gains")
        print("PASS: audio comparison preserves original noise, ignores suppressed windows, matches retained voice and follows trims")
    }

    static func neuralTests(root: URL) async throws {
        let input = root.appendingPathComponent("neural-input.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let frames = 12347 // Deliberately not a multiple of the 480-sample model frame.
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = buffer.floatChannelData!
        for frame in 0..<frames {
            data[0][frame] = Float(sin(Double(frame) * 0.14) * 0.2 + sin(Double(frame) * 0.031) * 0.3)
            data[1][frame] = 0
        }
        do {
            var settings = format.settings; settings[AVLinearPCMIsNonInterleaved] = false
            let file = try AVAudioFile(forWriting: input, settings: settings)
            try file.write(from: buffer)
        }
        var zero = AudioEffect.make(.voiceIsolation); zero.amount = 0
        let bypass = root.appendingPathComponent("neural-bypass.caf")
        _ = try OfflineAudioPipeline.process(input: input, effects: [zero], output: bypass) { _ in }
        let inputBytes = try Data(contentsOf: input), bypassBytes = try Data(contentsOf: bypass)
        try require(inputBytes == bypassBytes, "Zero neural amount preserves exact source bytes")
        let output = root.appendingPathComponent("neural-processed.caf")
        _ = try OfflineAudioPipeline.process(input: input, effects: [.make(.voiceIsolation), .make(.voiceIsolation)], output: output) { _ in }
        let result = try AVAudioFile(forReading: output)
        try require(result.length == frames, "Repeated neural stages preserve exact partial-frame sample count")
        let resultBuffer = AVAudioPCMBuffer(pcmFormat: result.processingFormat, frameCapacity: AVAudioFrameCount(frames))!
        try result.read(into: resultBuffer)
        var difference: Float = 0
        for frame in 0..<frames {
            let left = resultBuffer.floatChannelData![0][frame]
            try require(left.isFinite && resultBuffer.floatChannelData![1][frame] == 0, "Neural channel state is independent and finite")
            difference += abs(left - data[0][frame])
        }
        try require(difference > 0.1, "Neural stage runs real inference rather than bypass")
        var unknown = AudioEffect.make(.voiceIsolation); unknown.model = nil
        do {
            _ = try OfflineAudioPipeline.process(input: input, effects: [unknown], output: root.appendingPathComponent("unavailable.caf")) { _ in }
            throw NSError(domain: "YouRecTests", code: 6)
        } catch AudioProcessingError.unavailableModel {}
        unknown.enabled = false
        _ = try OfflineAudioPipeline.process(input: input, effects: [unknown], output: root.appendingPathComponent("disabled.caf")) { _ in }
        let isolation = AudioEffect.make(.voiceIsolation)
        let firstStage = root.appendingPathComponent("isolation-checkpoint.caf")
        let firstChain = root.appendingPathComponent("first-checkpoint-chain.caf")
        _ = try OfflineAudioPipeline.process(input: input, effects: [isolation, AudioEffect(kind: .gain, amount: 0, frequency: 1000)], output: firstChain,
            checkpoints: [firstStage, root.appendingPathComponent("zero-gain-checkpoint.caf")]) { _ in }
        let prefixBytes = try Data(contentsOf: firstStage)
        let changedChain = root.appendingPathComponent("changed-checkpoint-chain.caf")
        _ = try OfflineAudioPipeline.process(input: input, effects: [isolation, AudioEffect(kind: .gain, amount: -6, frequency: 1000)], output: changedChain,
            checkpoints: [firstStage, root.appendingPathComponent("minus-six-checkpoint.caf")]) { _ in }
        let preservedPrefix = try Data(contentsOf: firstStage)
        let originalPeak = try OfflineAudioPipeline.peak(of: firstChain), changedPeak = try OfflineAudioPipeline.peak(of: changedChain)
        try require(prefixBytes == preservedPrefix && abs(changedPeak / originalPeak - pow(10, -6.0 / 20)) < 0.0001, "Changing the last stage reuses an immutable prefix and applies the new gain")
        print("PASS: neural inference, zero-amount exact bypass, partial-frame drain, repeated-stage timing, silent stereo channel, explicit missing-model handling")
        if ProcessInfo.processInfo.environment["YOUREC_LAVA_MODEL"] != nil {
            let studioOutput = root.appendingPathComponent("studio.caf")
            _ = try OfflineAudioPipeline.process(input: input, effects: [.make(.voiceIsolation), .make(.studioVoice)], output: studioOutput) { _ in }
            let studio = try AVAudioFile(forReading: studioOutput)
            try require(studio.length == frames, "Core ML restoration preserves partial-context duration")
            let studioBuffer = AVAudioPCMBuffer(pcmFormat: studio.processingFormat, frameCapacity: AVAudioFrameCount(frames))!
            try studio.read(into: studioBuffer)
            for frame in 0..<frames {
                try require(studioBuffer.floatChannelData![0][frame].isFinite, "Core ML restoration remains finite")
                try require(studioBuffer.floatChannelData![1][frame] == 0, "Studio restoration preserves digital silence in the other channel")
            }
            print("PASS: RNNoise → Core ML restoration chain, exact duration, finite samples, silent channel")
            let longInput = root.appendingPathComponent("resume-input.caf")
            do {
                var longSettings = format.settings; longSettings[AVLinearPCMIsNonInterleaved] = false
                let file = try AVAudioFile(forWriting: longInput, settings: longSettings)
                for _ in 0..<40 { try file.write(from: buffer) }
            }
            let chunks = root.appendingPathComponent("restoration-chunks", isDirectory: true)
            let interrupted = root.appendingPathComponent("interrupted-restoration.caf")
            let task = Task.detached {
                try StudioVoiceProcessor.process(input: longInput, output: interrupted, amount: 0.35, resumeFolder: chunks) { value in
                    if value > 0 { withUnsafeCurrentTask { $0?.cancel() } }
                }
            }
            do { try await task.value; throw NSError(domain: "YouRecTests", code: 9) }
            catch is CancellationError {}
            let savedChunks = try FileManager.default.contentsOfDirectory(at: chunks, includingPropertiesForKeys: nil)
            try require(savedChunks.filter { $0.pathExtension == "caf" }.count == 1, "Cancellation preserves the first completed restoration window")
            let firstChunk = chunks.appendingPathComponent("0.caf")
            let before = try Data(contentsOf: firstChunk)
            let resumed = root.appendingPathComponent("resumed-restoration.caf")
            let reference = root.appendingPathComponent("reference-restoration.caf")
            try StudioVoiceProcessor.process(input: longInput, output: resumed, amount: 0.35, resumeFolder: chunks) { _ in }
            try StudioVoiceProcessor.process(input: longInput, output: reference, amount: 0.35) { _ in }
            let resumedBytes = try Data(contentsOf: resumed), referenceBytes = try Data(contentsOf: reference)
            let after = try Data(contentsOf: firstChunk)
            try require(resumedBytes == referenceBytes && before == after, "Resumed restoration is byte-identical to an uninterrupted pass and preserves completed chunks")
            print("PASS: cancellation checkpoint, resumed context windows, byte-identical restoration")
        }
    }
    static func dualLayoutTests() throws {
        try require(DualFramePairing.action(first: 1, second: 1.012) == 0, "Pair sensors with different frame phases")
        try require(DualFramePairing.action(first: 1, second: 1.1) == -1 && DualFramePairing.action(first: 1.1, second: 1) == 1, "Discard stale camera frames rather than combine different moments")
        let leftFace = CGRect(x: 0.15, y: 0.35, width: 0.15, height: 0.2)
        var target = DualFaceTarget()
        target.observe([leftFace], at: 0)
        let distractor = CGRect(x: 0.65, y: 0.25, width: 0.3, height: 0.4)
        target.observe([leftFace.offsetBy(dx: 0.02, dy: 0), distractor], at: 0.1)
        try require(target.box!.midX < 0.4, "Face following retains its target when a larger face enters")
        target.observe([distractor], at: 0.2)
        try require(target.box!.midX < 0.4 && target.current(at: 0.6) == nil, "Brief losses hold framing without tracking another person")
        target.observe([distractor], at: 1.1)
        try require(target.box.map { abs($0.midX-distractor.midX)<1e-9 && abs($0.midY-distractor.midY)<1e-9 } ?? false, "Following reacquires after a sustained loss")
        var edgeTarget = DualFaceTarget()
        edgeTarget.observe([CGRect(x: -0.05, y: 0.3, width: 0.25, height: 0.3)], at: 0)
        try require(edgeTarget.box.map { $0.minX == 0 && abs($0.width-0.2)<1e-9 && abs($0.height-0.3)<1e-9 } ?? false, "Partly visible faces remain trackable")
        let source = CGSize(width: 1920, height: 1080), region = CGRect(x: 0, y: 0, width: 960, height: 1080)
        var framing = DualCameraLayout.Framing()
        for _ in 0..<120 { framing = DualFaceFraming.follow(leftFace, source: source, region: region, current: framing, elapsed: 1.0/30) }
        let placed = DualCameraLayout.placement(source: source, region: region, framing: framing)
        try require(framing.x < 0.1 && framing.y == 0.5 && framing.zoom == 1 && placed.contains(region), "Follow uses only available horizontal crop, with no zoom or black bands")
        let held = DualFaceFraming.follow(nil, source: source, region: region, current: framing, elapsed: 0.1)
        try require(held == framing, "Lost face holds the current crop")
        let full = CGRect(origin: .zero, size: source)
        try require(DualFaceFraming.follow(leftFace, source: source, region: full, current: .init(), elapsed: 0.1) == .init(), "No overscan means no invented tracking room")
        var zoomed = DualCameraLayout.Framing(); zoomed.zoom = 2
        let firstStep = DualFaceFraming.follow(leftFace, source: source, region: full, current: zoomed, elapsed: 1.0/30)
        try require(abs(firstStep.x-zoomed.x)<0.05 && firstStep.zoom == 2, "Reacquisition eases in and preserves manual zoom")
        for size in [CGSize(width: 1920, height: 1080), CGSize(width: 1080, height: 1920)] {
            for mode in DualCameraLayout.Mode.allCases {
                for amount in [-1.0, 0.15, 0.5, 0.85, 2] {
                    var layout = DualCameraLayout(); layout.mode = mode
                    layout.verticalDivider = amount; layout.horizontalDivider = amount; layout.insetX = amount; layout.insetY = amount; layout.insetSize = amount; layout.constrain()
                    let canvas = CGRect(origin: .zero, size: size), regions = layout.regions(in: size)
                    try require(regions.allSatisfy { canvas.contains($0) && $0.width > 0 && $0.height > 0 }, "Every dual region remains in the canvas")
                    if mode == .sideBySide || mode == .topAndBottom { try require(abs(regions.reduce(0) { $0 + $1.width*$1.height }-size.width*size.height) < 0.001, "Split fills the canvas without gaps or overlaps") }
                    else if mode == .floating { try require(regions[1].width == regions[1].height, "Floating camera stays square in portrait and landscape") }
                    let before = regions; layout.swapped.toggle()
                    try require(layout.regions(in: size) == before, "Swap preserves layout geometry")
                    let data = try JSONEncoder().encode(layout)
                    let decoded = try JSONDecoder().decode(DualCameraLayout.self, from: data)
                    try require(decoded == layout, "Dual layout persists exactly")
                    for region in regions { for zoom in [1.0, 4.0] {
                        let placed = DualCameraLayout.placement(source: size, region: region, framing: .init(x: 0.8, y: 0.1, zoom: zoom))
                        try require(placed.contains(region) && abs(placed.width/placed.height-size.width/size.height) < 0.0001, "Pan/zoom fills each region without stretching")
                    } }
                }
            }
        }
        try require(DualCameraLayout.insetResizeAxis(separation: CGSize(width: 100, height: 15)) == .width, "Near horizontal pinch selects width")
        try require(DualCameraLayout.insetResizeAxis(separation: CGSize(width: -12, height: 100)) == .height, "Near vertical pinch selects height")
        try require(DualCameraLayout.insetResizeAxis(separation: CGSize(width: 80, height: -70)) == .proportional, "Diagonal pinch preserves aspect")
        for canvas in [CGSize(width: 1080, height: 1920), CGSize(width: 1920, height: 1080)] {
            var layout = DualCameraLayout()
            let square = layout.regions(in: canvas)[1]
            layout.resizeInset(scale: 1.5, axis: .width, canvas: canvas)
            let wide = layout.regions(in: canvas)[1]
            try require(abs(wide.width-square.width*1.5)<0.001 && abs(wide.height-square.height)<0.001, "Horizontal pinch changes only width")
            layout.resizeInset(scale: 0.75, axis: .height, canvas: canvas)
            let short = layout.regions(in: canvas)[1]
            try require(abs(short.width-wide.width)<0.001 && abs(short.height-wide.height*0.75)<0.001, "Vertical pinch changes only height")
            let ratio = short.width/short.height
            for factor in [1.2, 100, 0.0001, 2] {
                layout.resizeInset(scale: factor, axis: .proportional, canvas: canvas)
                let rect = layout.regions(in: canvas)[1]
                try require(abs(rect.width/rect.height-ratio)<0.001 && CGRect(origin: .zero, size: canvas).contains(rect), "Proportional resize preserves shape even at bounds")
                let placed = DualCameraLayout.placement(source: canvas, region: rect, framing: .init())
                try require(placed.contains(rect) && abs(placed.width/placed.height-canvas.width/canvas.height)<0.001, "Rectangular inset crops without stretching or empty bands")
            }
            let encoded = try JSONEncoder().encode(layout), decoded = try JSONDecoder().decode(DualCameraLayout.self, from: encoded)
            try require(decoded == layout, "Rectangular inset persists")
        }
        print("PASS: dual layout bounds, axis-specific/proportional inset resize, pan/zoom aspect, swap and persistence")
    }
    static func captureAudioTests() throws {
        let order = ["dji", "phone", "headset"]
        let ranked = RecordingMicrophoneRoute.priority(saved: order, discovered: ["headset", "phone", "dji"], actual: "phone")
        try require(ranked == order, "Discovery and system route never reorder a saved DJI-first list")
        try require(RecordingMicrophoneRoute.priority(saved: [], discovered: ["phone", "headset"], actual: "headset") == ["headset", "phone"], "Seed a new list from the active headset")
        var route = RecordingMicrophoneRoute()
        func observe(_ available: [String], _ actual: String?, _ preferred: String?, _ time: Double, take: Bool = true) -> RecordingMicrophoneRoute.Decision {
            route.resolve(ranked: available, actual: actual, preferred: preferred, inTake: take, now: time)
        }
        try require(observe(order, "phone", nil, 0, take: false).request == "dji", "Saved order wins before recording")
        try require(observe(order, "phone", "dji", 0.3).request == "dji", "Starting during negotiation pins the ranked mic and reasserts it even when preferredInput already matches")
        try require(observe(order, "dji", "dji", 1).request == nil, "No route churn once confirmed")
        route.select("phone")
        try require(observe(order, "dji", "dji", 2).request == "phone", "Manual selection beats the saved priority mid-take")
        try require(observe(order, "phone", "phone", 2.1).request == nil, "Manual choice settles")
        try require(observe(["dji", "headset"], "dji", "phone", 3).request == nil, "Do not accept a transient replacement")
        try require(observe([], nil, nil, 3.2).disconnected == nil, "An empty enumeration cannot cancel a manual choice")
        try require(observe(order, "dji", "phone", 3.5).request == "phone", "Reassert manual choice after transient route drift")
        try require(observe(["headset", "dji", "phone"], "phone", "phone", 4).request == nil, "Reordering or reconnecting a preferred mic leaves the take alone")
        try require(observe(["dji", "headset"], "phone", "phone", 5).disconnected == nil, "A still-active mic stays pinned even if temporarily missing from the list")
        route.deviceDisconnected(previousInputs: ["phone"])
        try require(observe(["dji", "headset"], "headset", nil, 6).recheckAfter != nil, "Wait for evidence of a real disconnect")
        let fallback = observe(["dji", "headset"], "headset", nil, 7.1)
        try require(fallback.request == "dji" && fallback.disconnected == nil, "Request the highest available fallback and wait for its real route")
        try require(observe(["dji", "headset"], "dji", "dji", 7.5).disconnected == "phone", "Announce a confirmed disconnection")
        try require(observe(["phone", "dji"], "dji", "dji", 8).disconnected == nil, "Fallback stays pinned and warns just once")
        try require(observe(["phone", "dji"], "phone", "dji", 9).request == "dji", "A returning mic cannot take over a take")
        route = RecordingMicrophoneRoute()
        try require(observe(order, "phone", "phone", 10, take: false).request == "dji", "After Stop the saved order applies again")
        route.select("headset")
        try require(observe(["dji", "phone"], "phone", "headset", 11).request == nil, "Ignore an unconfirmed missing manual input")
        try require(observe(["dji", "phone"], "phone", "headset", 13).request == nil, "Protect a manual input throughout format negotiation")
        for time in [14.1, 14.5, 15.1, 16.2] {
            try require(observe(["dji", "phone"], "phone", "dji", time).request == "dji", "Bounded retries when iOS refuses a ranked fallback")
        }
        try require(observe(["dji", "phone"], "phone", "dji", 18).recheckAfter != nil, "Proceed to the next available fallback")
        try require(observe(["dji", "phone"], "phone", "dji", 18.1).disconnected == "headset", "Announce the working fallback after a persistent routing failure")
        try require(observe(order, "phone", "phone", 19).request == nil, "Keep the working fallback through reconnect")
        print("PASS: microphone priority, take pin, negotiated route drift and confirmed disconnect fallback")
        let origin = CMTime(seconds: 100, preferredTimescale: 48000)
        for rate in [8000.0, 16000.0, 24000.0, 48000.0] {
            let frames = AVAudioFrameCount(rate * 0.04)
            let buffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!, frameCapacity: frames)!
            buffer.frameLength = frames
            buffer.floatChannelData![0].initialize(repeating: 0.4, count: Int(frames))
            buffer.floatChannelData![1].initialize(repeating: -0.2, count: Int(frames))
            let source = try CapturePCM.sample(buffer, at: origin)
            let gain = RecordingGain(); gain.set(12)
            let loud = try CapturePCM.pcm(gain.process(source))
            try require(loud.floatChannelData![0][Int(frames)-1] > 1.5, "Recording gain exposes clipping rather than silently limiting")
            gain.set(0)
            let resetSample = try gain.process(source), reset = try CapturePCM.pcm(resetSample)
            try require(abs(reset.floatChannelData![0][Int(frames)-1] - 0.4) < 0.00001 && abs(reset.floatChannelData![1][Int(frames)-1] + 0.2) < 0.00001, "Gain reset restores both original channels after 20 ms")
            try require(resetSample.presentationTimeStamp == origin && reset.frameLength == frames, "Recording gain preserves timing and sample count")
            let untouched = try CapturePCM.pcm(source)
            try require(untouched.floatChannelData![0][0] == 0.4, "Gain does not mutate source PCM")
        }
        let normalizer = CaptureAudioNormalizer(start: origin)
        var output: [CMSampleBuffer] = []
        // Deliberately start before video, then change both rate and channels as
        // a Bluetooth/USB fallback might do. Include an explicit 100 ms gap.
        for (rate, channels, time, frames) in [(48000.0, 1, -0.01, 4800), (24000.0, 1, 0.09, 2400), (48000.0, 2, 0.29, 4800)] {
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels))!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
            buffer.frameLength = AVAudioFrameCount(frames)
            for channel in 0..<channels {
                for frame in 0..<frames { buffer.floatChannelData![channel][frame] = Float(sin(Double(frame) * 2 * .pi * 440 / rate) * 0.2) }
            }
            let sample = try CapturePCM.sample(buffer, at: origin + CMTime(seconds: time, preferredTimescale: 48000))
            output += try normalizer.process(sample)
        }
        var next = origin
        var frames: Int64 = 0
        for sample in output {
            try require(abs((sample.presentationTimeStamp - next).seconds) < 1.0 / 48000, "Capture audio timestamps are contiguous across formats and gaps")
            let pcm = try CapturePCM.pcm(sample)
            try require(pcm.format.sampleRate == 48000 && pcm.format.channelCount == 2, "Capture output uses one fixed PCM format")
            for channel in 0..<2 {
                for frame in 0..<Int(pcm.frameLength) { try require(pcm.floatChannelData![channel][frame].isFinite, "Resampled capture PCM stays finite") }
            }
            frames += Int64(sample.numSamples)
            next = sample.presentationTimeStamp + CMTime(value: Int64(sample.numSamples), timescale: 48000)
        }
        try require(abs(Double(frames) / 48000 - 0.39) < 0.001, "Input gap is preserved in output duration rather than shifting later speech (frames=\(frames), silence=\(normalizer.insertedSilence))")
        try require(abs(normalizer.insertedSilence - 4800) <= 64, "Microphone input discontinuity is represented as explicit silence")
        let resampled = CaptureAudioNormalizer(start: origin)
        let rate = 44100.0, block = 1024, total = 44100 * 60
        let inputFormat = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        var sampleCount = 0
        while sampleCount < total {
            let count = min(block, total - sampleCount)
            let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = AVAudioFrameCount(count)
            buffer.floatChannelData![0].initialize(repeating: 0.1, count: count)
            let sample = try CapturePCM.sample(buffer, at: origin + CMTime(value: Int64(sampleCount), timescale: 44100))
            _ = try resampled.process(sample, endingAt: sampleCount + count == total ? origin + CMTime(seconds: 60, preferredTimescale: 48000) : nil)
            sampleCount += count
        }
        _ = try resampled.pad(until: origin + CMTime(seconds: 60, preferredTimescale: 48000))
        try require(resampled.nextFrame == 60 * 48000, "44.1 kHz capture has exact duration after a minute (frames=\(resampled.nextFrame), silence=\(resampled.insertedSilence))")
        try require(resampled.insertedSilence < 128, "Continuous 44.1 kHz input does not accumulate artificial gaps (silence=\(resampled.insertedSilence))")
        for ppm in [-100.0, 100.0] {
            let drifting = CaptureAudioNormalizer(start: origin)
            let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
            let block = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410)!
            block.frameLength = 4410; block.floatChannelData![0].initialize(repeating: 0.1, count: 4410)
            let seconds = 3600.0, factor = 1 + ppm / 1_000_000
            for index in 0..<36000 {
                let time = origin + CMTime(seconds: Double(index) * 0.1 * factor, preferredTimescale: 1_000_000_000)
                let endpoint = index == 35999 ? origin + CMTime(seconds: seconds * factor, preferredTimescale: 1_000_000_000) : nil
                _ = try drifting.process(CapturePCM.sample(block, at: time), endingAt: endpoint)
            }
            try require(drifting.maximumClockOffset < 128, "External microphone clock stays within 2.7 ms after an hour at \(ppm) ppm (offset=\(drifting.maximumClockOffset))")
            try require(abs(Double(drifting.nextFrame) / 48000 - seconds * factor) < 0.003, "Resampled audio follows host time without accumulating drift")
            try require(drifting.insertedSilence < 128, "Clock correction does not insert artificial silence")
            print("CLOCK: \(ppm) ppm, max offset \(drifting.maximumClockOffset) samples, correction \(drifting.clockCorrections)")
        }
        for inputRate in [8000.0, 16000.0] {
            let normal = CaptureAudioNormalizer(start: origin)
            let format = AVAudioFormat(standardFormatWithSampleRate: inputRate, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(inputRate / 10))!
            buffer.frameLength = buffer.frameCapacity; buffer.floatChannelData![0].initialize(repeating: 0.1, count: Int(buffer.frameLength))
            for index in 0..<100 {
                _ = try normal.process(CapturePCM.sample(buffer, at: origin + CMTime(seconds: Double(index) / 10, preferredTimescale: 48000)))
            }
            try require(abs(normal.nextFrame - 480000) < 128, "Bluetooth-rate input consumes all samples at \(inputRate) Hz")
        }
        for frequency in [12000.0, 11300.0] {
        let treble = CaptureAudioNormalizer(start: origin)
        let trebleFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let tone = AVAudioPCMBuffer(pcmFormat: trebleFormat, frameCapacity: 4410)!
        tone.frameLength = 4410
        for frame in 0..<4410 { tone.floatChannelData![0][frame] = 0.15 * Float(sin(Double(frame) * 2 * .pi * frequency / 44100)) }
        var minimumPower = Double.infinity, maximumPower = 0.0
        for index in 0..<1200 {
            let time = origin + CMTime(seconds: Double(index) * 0.1 * 1.0001, preferredTimescale: 1_000_000_000)
            let output = try treble.process(CapturePCM.sample(tone, at: time))
            if index > 10 {
                var energy = 0.0, frames = 0
                for sample in output {
                    let pcm = try CapturePCM.pcm(sample)
                    for frame in 0..<Int(pcm.frameLength) { let value = Double(pcm.floatChannelData![0][frame]); energy += value * value }
                    frames += Int(pcm.frameLength)
                }
                if frames > 0 { let power = energy / Double(frames); minimumPower = min(minimumPower, power); maximumPower = max(maximumPower, power) }
            }
        }
        let trebleVariation = 10 * log10(maximumPower / minimumPower)
        try require(trebleVariation < 0.2, "Clock correction preserves \(frequency) Hz level across buffers (variation=\(trebleVariation) dB)")
        print("CLOCK: \(frequency) Hz level variation \(trebleVariation) dB")
        }
        let bounded = CaptureAudioNormalizer(start: origin)
        let shortBuffer = AVAudioPCMBuffer(pcmFormat: bounded.format, frameCapacity: 4800)!
        shortBuffer.frameLength = 4800
        for channel in 0..<2 { shortBuffer.floatChannelData![channel].initialize(repeating: 0.1, count: 4800) }
        _ = try bounded.process(CapturePCM.sample(shortBuffer, at: origin), endingAt: origin + CMTime(value: 1600, timescale: 48000))
        try require(bounded.nextFrame == 1600, "Stop trims a microphone buffer exactly at the shared video endpoint")
        _ = try bounded.pad(until: origin + CMTime(value: 1800, timescale: 48000))
        try require(bounded.nextFrame == 1800 && bounded.insertedSilence == 200, "Final missing microphone input is explicit silence")
        print("PASS: capture PCM copy, leading trim, mono/stereo and 24/48-kHz changes, continuous sample clock, explicit gap duration")
    }
}

private func projectRetentionTests(root: URL) throws {
    let fm = FileManager.default
    let disk = ProjectDisk(root: root.appendingPathComponent("retention-" + UUID().uuidString))
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let cutoff = calendar.date(byAdding: .day, value: -30, to: now)!
    func record(_ date: Date) -> ProjectDeletion { ProjectDeletion(id: UUID(), token: UUID(), date: date, dateIsKnown: true) }
    try require(!record(cutoff).isOlderThan30Days(at: now, calendar: calendar), "Exactly 30 days is not older than 30 days")
    try require(record(cutoff.addingTimeInterval(-1)).isOlderThan30Days(at: now, calendar: calendar), "More than 30 days qualifies")
    try require(!record(now.addingTimeInterval(60)).isOlderThan30Days(at: now, calendar: calendar), "Future timestamps do not qualify")
    func make(_ title: String) throws -> Project {
        var project = Project(title: title); project.updatedAt = .distantPast
        try disk.save(project)
        try Data("original footage".utf8).write(to: disk.folder(project.id).appendingPathComponent("original.mov"))
        return project
    }
    let old = try make("Old"), recent = try make("Recent"), legacy = try make("Untracked"), active = try make("Active")
    let originalManifest = try Data(contentsOf: disk.folder(old.id).appendingPathComponent("project.json"))
    try disk.moveToDeleted(old, now: cutoff.addingTimeInterval(-86400))
    try disk.moveToDeleted(recent, now: now)
    try disk.moveToDeleted(legacy, now: cutoff.addingTimeInterval(-86400))
    let legacyFile = disk.deletedRoot.appendingPathComponent(legacy.id.uuidString).appendingPathComponent(".yourec-deletion.json")
    try fm.removeItem(at: legacyFile)
    let oldReceipt = try disk.deletionRecord(for: old.id, firstSeenAt: now)
    let recentReceipt = try disk.deletionRecord(for: recent.id, firstSeenAt: now)
    let legacyReceipt = try disk.deletionRecord(for: legacy.id, firstSeenAt: now)
    try require(legacyReceipt.date == now && !legacyReceipt.dateIsKnown, "Unknown deletion dates start at first observation")
    let legacyReopened = try disk.deletionRecord(for: legacy.id, firstSeenAt: now.addingTimeInterval(86400))
    try require(legacyReopened == legacyReceipt, "First-observed date survives reopening")
    try require(!recentReceipt.isOlderThan30Days(at: now), "Old last-edit time does not make a newly deleted project expire")
    let trashedManifest = try Data(contentsOf: disk.deletedRoot.appendingPathComponent(old.id.uuidString).appendingPathComponent("project.json"))
    try require(trashedManifest == originalManifest, "Moving to trash leaves the manifest unchanged")
    let recentRemoved = try disk.eraseExpiredDeletion(recentReceipt, now: now)
    let legacyRemoved = try disk.eraseExpiredDeletion(legacyReceipt, now: now)
    try require(!recentRemoved && !legacyRemoved, "Recent and untracked deletions cannot be purged")
    try disk.restoreDeleted(old)
    let restoredOriginal = try Data(contentsOf: disk.folder(old.id).appendingPathComponent("original.mov"))
    try require(restoredOriginal == Data("original footage".utf8), "Restore preserves originals")
    try disk.moveToDeleted(old, now: now)
    let staleRemoved = try disk.eraseExpiredDeletion(oldReceipt, now: now.addingTimeInterval(60 * 86400))
    try require(!staleRemoved && fm.fileExists(atPath: disk.deletedRoot.appendingPathComponent(old.id.uuidString).path), "A stale confirmation cannot delete a restored and re-deleted project")
    let newReceipt = try disk.deletionRecord(for: old.id, firstSeenAt: now)
    let removed = try disk.eraseExpiredDeletion(newReceipt, now: now.addingTimeInterval(60 * 86400))
    try require(removed && !fm.fileExists(atPath: disk.deletedRoot.appendingPathComponent(old.id.uuidString).path), "Confirmed expired project and its files are removed")
    try require(fm.fileExists(atPath: disk.folder(active.id).appendingPathComponent("original.mov").path), "Active project files survive cleanup")
    try Data("broken receipt".utf8).write(to: legacyFile)
    var rejected = false
    do { _ = try disk.eraseExpiredDeletion(legacyReceipt, now: now.addingTimeInterval(60 * 86400)) } catch { rejected = true }
    try require(rejected && fm.fileExists(atPath: legacyFile.path), "Unreadable dates preserve the deleted project")
    let userTrash = ProjectDisk(root: root.appendingPathComponent("Projects")).deletedRoot
    for name in ["EditorUITestProjects", "CinematicUITestProjects", "RetentionUITestProjects"] {
        let fixtureTrash = ProjectDisk(root: root.appendingPathComponent(name)).deletedRoot
        try require(fixtureTrash != userTrash && fixtureTrash.lastPathComponent == name + "-RecentlyDeleted", "Each fixture store has its own trash")
    }
    // Simulate a crash midway through a previously confirmed removal: the
    // manifest may already be gone, while original media is still present.
    let pending = disk.deletedRoot.appendingPathComponent(".purging-" + UUID().uuidString)
    try fm.moveItem(at: disk.deletedRoot.appendingPathComponent(legacy.id.uuidString), to: pending)
    try fm.removeItem(at: pending.appendingPathComponent("project.json"))
    let unrelated = disk.deletedRoot.appendingPathComponent(".purging-not-a-queue-id")
    try fm.createDirectory(at: unrelated, withIntermediateDirectories: true)
    disk.finishPendingDeletions()
    try require(!fm.fileExists(atPath: pending.path) && fm.fileExists(atPath: unrelated.path), "Interrupted confirmed deletion resumes without touching unrelated folders")
    try require(fm.fileExists(atPath: disk.deletedRoot.appendingPathComponent(recent.id.uuidString).path), "Queued cleanup leaves ordinary Recently Deleted projects untouched")
    print("PASS: deletion dates, exact30-day boundary, unknown dates, reopen, restore, stale confirmations, confirmed removal and original preservation")
}

private func largeBackupTests(_ root: URL) async throws {
    let disk = ProjectDisk(root: root.appendingPathComponent("large-backup-projects"))
    var project = Project(title: "Portable history")
    let source = SourceMedia(filename: "source.mp4", duration: 4)
    project.sources = [source]
    let folder = disk.folder(project.id)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let media = try Data(contentsOf: root.appendingPathComponent(source.filename))
    try media.write(to: folder.appendingPathComponent(source.filename))
    var edit = EditState(clips: (0..<100).map { TimelineClip(sourceID: source.id, start: Double($0)/25, end: Double($0+1)/25) })
    project.commit(edit)
    for index in 0..<180 {
        edit.timeline.audio[0].volumeDB = index.isMultiple(of: 2) ? -3 : -6
        project.commit(edit)
    }
    project.undo()
    let destination = root.appendingPathComponent(UUID().uuidString + ".zip")
    try await ProjectArchive.export(project, folder: folder, destination: destination) { _ in }
    let restored = try await ProjectArchive.restore(destination, disk: disk) { _ in }
    let restoredMedia = try Data(contentsOf: disk.folder(restored.id).appendingPathComponent(source.filename))
    try require(restored.history == project.history && restored.historyCursor == project.historyCursor && restored.canRedo && restoredMedia == media, "Large archive preserves source bytes, edits, undo and redo")
    if let legacy = ProcessInfo.processInfo.environment["YOUREC_LEGACY_ARCHIVE"] {
        let url = URL(fileURLWithPath: legacy)
        let archive = try Archive(url: url, accessMode: .read)
        guard let entry = archive["project.json"] else { throw ProjectError.invalidDocument }
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        let original = try JSONDecoder().decode(Project.self, from: data)
        let imported = try await ProjectArchive.restore(url, disk: disk) { _ in }
        let importedMedia = try Data(contentsOf: disk.folder(imported.id).appendingPathComponent(source.filename))
        try require(data.count > 20_000_000 && imported.history == original.history && imported.historyCursor == original.historyCursor && importedMedia == media, "Build 159 large inline archive restores all original states and footage")
    }
    // A movie-sized source must not leave one NSData per ZIP chunk in the
    // surrounding autorelease pool. ru_maxrss is reported in bytes on Darwin.
    var long = Project(title: "Streaming ZIP")
    long.append(source)
    let longFolder = disk.folder(long.id)
    try FileManager.default.createDirectory(at: longFolder, withIntermediateDirectories: true)
    let movie = longFolder.appendingPathComponent(source.filename)
    try media.write(to: movie)
    let padding: UInt32 = 256 * 1024 * 1024
    let handle = try FileHandle(forWritingTo: movie)
    let start = try handle.seekToEnd()
    var size = padding.bigEndian
    try handle.write(contentsOf: withUnsafeBytes(of: &size) { Data($0) } + Data("free".utf8))
    try handle.truncate(atOffset: start + UInt64(padding))
    try handle.close()
    let longZip = root.appendingPathComponent(UUID().uuidString + ".zip")
    defer { try? FileManager.default.removeItem(at: longZip) }
    func peakMemory() -> Int {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return usage.ru_maxrss
    }
    let before = peakMemory()
    try await ProjectArchive.export(long, folder: longFolder, destination: longZip) { _ in }
    let memoryGrowth = peakMemory() - before
    try require(memoryGrowth < 100*1024*1024, "ZIP retained movie chunks: " + String(memoryGrowth) + " bytes")
    let unpacked = try await ProjectArchive.restore(longZip, disk: disk) { _ in }
    let restoredSize = try RecoverySpace.size(disk.folder(unpacked.id).appendingPathComponent(source.filename))
    try require(restoredSize == Int64(start) + Int64(padding), "Restored movie keeps the complete checked payload")
    print("PASS: large portable backup round trip, including legacy archive when supplied")
}

final class ExportProgressTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ExportProgress] = []
    func record(_ progress: ExportProgress) { lock.withLock { events.append(progress) } }
    var steps: [ExportProgress.Step] { lock.withLock { events.map(\.step) } }
    var values: [ExportProgress] { lock.withLock { events } }
}

private func resumableExportTests(_ root: URL) async throws {
    let folder = root.appendingPathComponent("resume-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let source = SourceMedia(filename: "source.mp4", duration: 4)
    try FileManager.default.copyItem(at: root.appendingPathComponent(source.filename), to: folder.appendingPathComponent(source.filename))
    var project = Project(title: "Interrupted export")
    project.sources = [source]
    // A non-frame-aligned end and sections that cross ordinary clip boundaries.
    let clips = (0..<8).map { _ in TimelineClip(sourceID: source.id, start: 0.1, end: 3.99) }
    var edit = EditState(clips: clips, outputSize: CGSize(width: 640, height: 360))
    edit.timeline.video[3].content.texts = [TextOverlay(text: "Section boundary", start: 0.1, end: 3.9)]
    edit.timeline.audio[3].volumeDB = -12
    edit.timeline.enhance([AudioEffect(kind: .gain, amount: -3)], selection: edit.timeline.entireSelection())
    project.commit(edit)
    let snapshot = project
    let checkpoint = ExportCheckpoint(folder: folder)
    try checkpoint.prepare(project)
    let result = folder.appendingPathComponent("resumed.mp4")
    let first = ExportProgressTrace()
    try require(checkpoint.startingProgress(total: project.edit.duration).fraction == 0, "Fresh export opens at zero")
    let task = Task {
        try await MediaRenderer.render(project: snapshot, folder: folder, destination: result, checkpoint: checkpoint) { first.record($0) }
    }
    for _ in 0..<3000 {
        if checkpoint.savedSeconds(total: project.edit.duration) > 0 { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    task.cancel()
    do { _ = try await task.value; throw ProjectError.invalidDocument }
    catch is CancellationError {}
    let saved = checkpoint.savedSeconds(total: project.edit.duration)
    try require(saved >= 12 && saved < project.edit.duration && !FileManager.default.fileExists(atPath: result.path), "Interrupted export keeps finished picture sections private")
    let cache = checkpoint.directory.appendingPathComponent("picture-0.mp4")
    let before = try cache.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    let reopened = ExportCheckpoint(folder: folder)
    try require(reopened.matches(project), "Reopening the same project finds its export")
    let preparing: [ExportProgress.Step] = [.opening, .audioEffects, .timeline, .audioPeak, .audio, .picture]
    try require(preparing.allSatisfy(first.steps.contains) && !first.steps.contains(.complete), "Interrupted export reports real preparation and encoding steps without claiming completion")
    let restored = reopened.startingProgress(total: project.edit.duration)
    let floor = ExportProgress(.picture, saved / project.edit.duration).fraction
    try require(restored.step == .opening && restored.fraction == floor, "Resume starts with its current operation and its durable progress")
    let resumed = ExportProgressTrace()
    let published = try await MediaRenderer.render(project: project, folder: folder, destination: result, checkpoint: reopened) { resumed.record($0) }
    let finalSteps: [ExportProgress.Step] = [.picture, .assembleMovie, .movieIndex, .sourceFiles, .verifying, .saving, .complete]
    try require(finalSteps.allSatisfy(resumed.steps.contains) && !resumed.steps.contains(.audio) && !resumed.steps.contains(.audioPeak), "Resume skips cached audio steps and describes each remaining file operation")
    try require(resumed.values.last == ExportProgress(.complete) && resumed.values.dropLast().allSatisfy { $0.fraction < 1 }, "Only the published movie reaches 100 percent")
    var displayed = restored
    for event in resumed.values {
        let next = displayed.advanced(to: event)
        try require(next.fraction >= displayed.fraction && next.fraction >= floor, "One nondecreasing bar covers the entire resume")
        displayed = next
    }
    let late = ExportProgress(.picture, 0.8).advanced(to: ExportProgress(.timeline, 1))
    try require(late == ExportProgress(.picture, 0.8) && ExportProgress(.picture, .nan).fraction.isFinite, "Late and invalid callbacks cannot rewind or invalidate the progress bar")
    let after = try cache.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    try require(before == after, "Resume reused the first encoded section")
    let asset = AVURLAsset(url: result)
    let tracks = try await asset.load(.tracks)
    for kind in [AVMediaType.video, .audio] {
        guard let track = tracks.first(where: { $0.mediaType == kind }) else { throw ProjectError.invalidMedia }
        let range = try await track.load(.timeRange)
        try require(abs(range.start.seconds) < 0.03 && abs(range.end.seconds - project.edit.duration) < 0.04, "Full-length synchronized " + kind.rawValue)
    }
    let reference = folder.appendingPathComponent("reference.mp4")
    _ = try await MediaRenderer.render(project: project, folder: folder, destination: reference) { _ in }
    project.undo()
    try require(!reopened.matches(project), "A changed timeline cannot reuse stale encoded sections")
    let detached = try reopened.detachCompletedFiles()
    try require(FileManager.default.fileExists(atPath: detached.appendingPathComponent("picture-0.mp4").path), "Finished sections leave the resumable slot without blocking on file deletion")
    try reopened.prepare(project)
    try FileManager.default.removeItem(at: detached)
    let receiptURL = result.deletingPathExtension().appendingPathExtension("json")
    let onDisk = try JSONDecoder().decode(ExportReceipt.self, from: Data(contentsOf: receiptURL))
    try require(onDisk.id == published.id && published.filename == result.lastPathComponent && reopened.matches(project) && FileManager.default.fileExists(atPath: result.path), "Cleaning a completed export preserves the shareable movie, its receipt, and the next export")
    try require(reopened.savedSeconds(total: 32) == 0, "Starting the changed edit cleans the old checkpoints")
    try reopened.discard()
    print("PASS: interrupted multi-section export, persisted resume, exact duration, stale revision and cleanup at " + folder.path)
}

private func exportOptionsTests(_ root: URL) async throws {
    let disk = ProjectDisk(root: root.appendingPathComponent("export-options-" + UUID().uuidString))
    var project = Project(title: "Export formats · UI test")
    let folder = disk.folder(project.id)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for name in ["export-60.mp4", "export-vfr.mp4", "source.mp4"] {
        let file = folder.appendingPathComponent(name)
        try FileManager.default.copyItem(at: root.appendingPathComponent(name), to: file)
        let duration = try await AVURLAsset(url: file).load(.duration).seconds
        project.addRecording(SourceMedia(filename: name, duration: duration))
    }
    // Keep a second checkpoint in the same project and a custom-compositor cut.
    var edit = project.edit
    edit.timeline.audio[0].volumeDB = -3
    let last = project.sources[2]
    project.commit(edit)
    var repeatSource = last
    repeatSource.id = UUID()
    repeatSource.filename = "repeat.mp4"
    try FileManager.default.copyItem(at: folder.appendingPathComponent(last.filename), to: folder.appendingPathComponent(repeatSource.filename))
    project.addRecording(repeatSource)
    try disk.save(project)
    print("QA fixture:", folder.path)

    let input = try await exportFrameSamples(folder.appendingPathComponent("export-vfr.mp4"))
    let sourceDeltas = zip(input, input.dropFirst()).map { $1.time - $0.time }
    try require(sourceDeltas.contains { abs($0 - 3018.0 / 90000) < 0.00001 }, "Fixture has genuine variable frame intervals")
    let checkpoint = ExportCheckpoint(folder: folder)
    for rate in ExportSettings.FrameRate.allCases {
        project.exportSettings.frameRate = rate
        project.exportSettings.codec = rate == .high || rate == .pal ? .hevc : .h264
        switch rate {
        case .film: project.exportSettings.resolution = .ultraHD
        case .pal: project.exportSettings.resolution = .fullHD
        case .high: project.exportSettings.resolution = .hd
        default: project.exportSettings.resolution = .project
        }
        try checkpoint.prepare(project)
        let output = folder.appendingPathComponent("output-\(rate.rawValue).mp4")
        _ = try await MediaRenderer.render(project: project, folder: folder, destination: output, checkpoint: checkpoint) { _ in }
        let asset = AVURLAsset(url: output), tracks = try await asset.load(.tracks)
        let video = tracks.first { $0.mediaType == .video }!
        let size = try await video.load(.naturalSize)
        let expected = project.exportSettings.resolution.size(for: CGSize(width: 180, height: 320))
        try require(size == expected, "Portrait framing at \(rate): \(size) vs \(expected)")
        let reportedRate = try await video.load(.nominalFrameRate)
        try require(abs(reportedRate - Float(rate.rawValue)) < 0.001, "Reported rate \(reportedRate) must match the sample grid at \(rate)")
        let formats = try await video.load(.formatDescriptions)
        let codec = CMFormatDescriptionGetMediaSubType(formats[0])
        try require(codec == (project.exportSettings.codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264), "Encoded codec")
        for track in tracks {
            let range = try await track.load(.timeRange)
            try require(abs(range.start.seconds) < 0.002 && abs(range.end.seconds - project.edit.duration) < 1.0 / Double(rate.rawValue), "Timeline duration and A/V sync at \(rate)")
        }
        let frames = try await exportFrameSamples(output)
        let step = 1 / Double(rate.rawValue)
        try require(frames.count == Int(ceil(project.edit.duration / step - 0.00001)), "Output frame count at \(rate): \(frames.count)")
        try require(frames.enumerated().allSatisfy { abs($0.element.time - Double($0.offset) * step) < 0.00005 }, "Every output timestamp on selected frame grid, including section joins at \(rate)")
        if rate == .high {
            try require(zip(frames.prefix(119), frames.dropFirst()).allSatisfy { abs($0.level - $1.level) > 100 }, "60 distinct images per second from real 60 fps footage")
        }
        let receipt = try JSONDecoder().decode(ExportReceipt.self, from: Data(contentsOf: output.deletingPathExtension().appendingPathExtension("json")))
        try require(receipt.settings == project.exportSettings && receipt.framesPerSecond == rate.rawValue, "Receipt captures selected settings")
        print("PASS: \(rate.rawValue) fps, \(size), \(frames.count) timed frames, \(project.exportSettings.codec.rawValue)")
        var changed = project
        changed.exportSettings.resolution = project.exportSettings.resolution == .ultraHD ? .hd : .ultraHD
        try require(!checkpoint.matches(changed), "Format changes cannot reuse old encoded sections")
    }
    try checkpoint.discard()
    // A plain 30 fps take uses Apple's native compositor. Earlier builds
    // could checkpoint only 719 of the first 720 requested pictures at 60 fps.
    var plain = Project(title: "Upsampled recording")
    plain.exportSettings.frameRate = .high; plain.exportSettings.codec = .hevc
    let nativeFolder = disk.folder(plain.id)
    try FileManager.default.createDirectory(at: nativeFolder, withIntermediateDirectories: true)
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/editor-fixture.mp4")
    try FileManager.default.copyItem(at: fixture, to: nativeFolder.appendingPathComponent("take.mp4"))
    plain.append(SourceMedia(filename: "take.mp4", duration: 18))
    let resume = ExportCheckpoint(folder: nativeFolder)
    try resume.prepare(plain)
    let native = try await MediaRenderer.timeline(project: plain, folder: nativeFolder, framesPerSecond: 60)
    let short = resume.directory.appendingPathComponent("picture-0.mp4")
    try await MediaRenderer.encode(native.composition, preset: AVAssetExportPresetHEVCHighestQuality, to: short, type: .mp4,
                                   range: CMTimeRange(start: .zero, duration: CMTime(value: 719, timescale: 60)),
                                   videoComposition: native.videoComposition) { _ in }
    let movie = nativeFolder.appendingPathComponent("restored.mp4")
    _ = try await MediaRenderer.render(project: plain, folder: nativeFolder, destination: movie, checkpoint: resume) { _ in }
    let restored = try await exportFrameSamples(movie)
    try require(restored.count == 1080 && restored.enumerated().allSatisfy { abs($0.element.time - Double($0.offset) / 60) < 0.00005 },
                "Recover a short checkpoint and render the final tick of both upsampled sections")
    print("PASS: resumed 30 to 60 fps export contains all 1080 pictures on their original clock")

}

private func exportFrameSamples(_ file: URL) async throws -> [(time: Double, level: Int)] {
    let asset = AVURLAsset(url: file), track = try await asset.loadTracks(withMediaType: .video).first!
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
    reader.add(output)
    guard reader.startReading() else { throw reader.error ?? ProjectError.invalidMedia }
    var frames: [(Double, Int)] = []
    while let sample = output.copyNextSampleBuffer(), let pixel = CMSampleBufferGetImageBuffer(sample) {
        CVPixelBufferLockBaseAddress(pixel, .readOnly)
        let level = CVPixelBufferGetBaseAddressOfPlane(pixel, 0)!.load(as: UInt8.self)
        CVPixelBufferUnlockBaseAddress(pixel, .readOnly)
        frames.append((sample.presentationTimeStamp.seconds, Int(level)))
    }
    guard reader.status == .completed else { throw reader.error ?? ProjectError.invalidMedia }
    return frames
}

private func duplicateProjectTests(_ root: URL) async throws {
    let disk = ProjectDisk(root: root.appendingPathComponent("Duplicate-" + UUID().uuidString))
    var original = Project(title: "Interview")
    let movie = SourceMedia(filename: "source.mp4", duration: 4)
    let voice = SourceMedia(filename: "voice.caf", duration: 2, audioOnly: true)
    original.append(movie); original.sources.append(voice)
    var edit = original.edit
    edit.timeline.insertAudio(voice, at: EditTime(0.5)); original.commit(edit)
    edit.timeline.video[0].content.images = [ImageOverlay(filename: "image-title.png")]
    original.commit(edit); original.undo()
    original.exportSettings.codec = .hevc
    original.beginRecordingInsertion(at: 1, site: nil)
    try disk.save(original)
    let source = disk.folder(original.id), fm = FileManager.default
    let media = ["source.mp4", "voice.caf", "image-title.png", "unfinished.mov", "unfinished.events.json", "Recovery/" + UUID().uuidString + "/salvaged.mov"]
    let originalMovie = try Data(contentsOf: root.appendingPathComponent("source.mp4"))
    for name in media + ["Cache/preview.mov", "Exports/master.mp4"] {
        let url = source.appendingPathComponent(name)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (name == movie.filename ? originalMovie : Data(name.utf8)).write(to: url)
    }
    let copy = try await ProjectArchive.duplicate(original, in: disk, title: "Interview copy") { _ in }
    let folder = disk.folder(copy.id), manifest = folder.appendingPathComponent("project.json")
    var reopened = try disk.read(manifest)
    try require(copy.id != original.id && reopened.title == "Interview copy" && reopened.history == original.history &&
                reopened.historyCursor == original.historyCursor && reopened.canUndo && reopened.canRedo, "Independent project with the full saved history and cursor")
    try require(reopened.exportSettings == original.exportSettings && reopened.recordingInsertion == nil, "Keep export settings and start future recordings independently")
    reopened.redo(); try disk.save(reopened)
    let unchanged = try disk.read(source.appendingPathComponent("project.json"))
    try require(unchanged.edit == original.edit && unchanged.canRedo, "Redo in the copy cannot change the original")
    let lostTake = "Recovery/" + RecoveryFile.hash(Data("unfinished.mov".utf8)) + "/"
    for name in media {
        let path = name.hasPrefix("unfinished.") ? lostTake + name : name
        let bytes = try Data(contentsOf: folder.appendingPathComponent(path))
        try require(bytes == (name == movie.filename ? originalMovie : Data(name.utf8)), "Copied original or recovery asset: " + name)
    }
    try require(!fm.fileExists(atPath: folder.appendingPathComponent("Cache").path) && !fm.fileExists(atPath: folder.appendingPathComponent("Exports").path), "Generated artifacts stay with their original project")
    let handle = try FileHandle(forWritingTo: source.appendingPathComponent(movie.filename))
    try handle.write(contentsOf: Data([originalMovie[0] ^ 0xff])); try handle.close()
    try disk.moveToDeleted(original); try disk.eraseDeleted(original.id)
    let independentMovie = try Data(contentsOf: folder.appendingPathComponent(movie.filename))
    let playable = try await AVURLAsset(url: folder.appendingPathComponent(movie.filename)).load(.isPlayable)
    try require(independentMovie == originalMovie && playable, "The copy still plays after editing and deleting the original media")
    try fm.removeItem(at: folder.appendingPathComponent(voice.filename))
    let repairable = try await ProjectArchive.duplicate(reopened, in: disk, title: "Repairable") { _ in }
    try require(repairable.sources.contains { $0.id == voice.id } && !fm.fileExists(atPath: disk.folder(repairable.id).appendingPathComponent(voice.filename).path), "An existing offline reference stays relinkable")
    let empty = Project(title: "Empty"); try disk.save(empty)
    let emptyCopy = try await ProjectArchive.duplicate(empty, in: disk, title: "Empty copy") { _ in }
    try require(emptyCopy.edit.duration == 0 && emptyCopy.id != empty.id, "Empty projects duplicate")
    let before = try Set(fm.contentsOfDirectory(atPath: disk.root.path))
    let cancelled = Task {
        try await ProjectArchive.duplicate(reopened, in: disk, title: "Cancelled") { _ in
            withUnsafeCurrentTask { $0?.cancel() }
        }
    }
    do { _ = try await cancelled.value; throw NSError(domain: "Expected cancellation", code: 1) } catch is CancellationError {}
    try fm.createSymbolicLink(at: folder.appendingPathComponent(voice.filename), withDestinationURL: folder.appendingPathComponent(movie.filename))
    do {
        _ = try await ProjectArchive.duplicate(reopened, in: disk, title: "Incomplete") { _ in }
        throw NSError(domain: "Expected copy failure", code: 1)
    } catch ProjectError.invalidDocument {}
    let after = try Set(fm.contentsOfDirectory(atPath: disk.root.path))
    try require(before == after, "Canceled and failed copies leave no published project")
    print("PASS: project duplication preserves sources, recovery, settings and undo/redo; media are independent; cancellation and failure are atomic")
}
