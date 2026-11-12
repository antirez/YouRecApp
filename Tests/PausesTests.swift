import Foundation
import AVFoundation

func pausesTests(root: URL) async throws {
    try pauseLevelTests()
    try await pauseWaveformUpgrade(root: root)
    var plain = Project(title: "Pause preview geometry")
    plain.append(SourceMedia(filename: "source.mp4", duration: 4))
    let native = try await MediaRenderer.timeline(project: plain, folder: root, canvasSize: CGSize(width: 640, height: 360))
    try require(native.playbackVideoComposition == nil, "An explicit native canvas does not force unnecessary video composition")
    let scaled = try await MediaRenderer.timeline(project: plain, folder: root, canvasSize: CGSize(width: 1280, height: 720))
    try require(scaled.playbackVideoComposition != nil, "A different preview canvas still needs video composition")
    let noAudio = try await SourceMediaCache.shared.waveform(source: SourceMedia(filename: "silent.mp4", duration: 4), folder: root)
    try require(noAudio.peaks.isEmpty, "Audio-less clips remain distinct from recorded silence")
    // Optional local recording is never bundled, committed, or modified.
    if let path = ProcessInfo.processInfo.environment["YOUREC_PAUSE_PROJECT"],
       let reportPath = ProcessInfo.processInfo.environment["YOUREC_PAUSE_REPORT"] {
        let folder = URL(fileURLWithPath: path), destination = URL(fileURLWithPath: reportPath)
        let bytes = try Data(contentsOf: folder.appendingPathComponent("project.json"))
        var project = try ProjectDisk(root: folder.deletingLastPathComponent()).read(folder.appendingPathComponent("project.json"))
        let original = project.edit
        var edit = original, rows: [[String: Any]] = []
        let settings = PauseSettings()
        for index in edit.clips.indices {
            let clip = edit.clips[index], source = project.sources.first { $0.id == clip.sourceID }!
            let wave = try await SourceMediaCache.shared.waveform(source: source, folder: folder, needsRMS: true, needsSpeech: true)
            let raw = PauseDetector.raw(wave: wave, clip: clip, settings: settings)
            let cuts = PauseDetector.effectiveCuts(raw.map { DetectedPause(raw: $0) }, clip: clip, settings: settings)
            var value = settings; value.candidates = raw.map { DetectedPause(raw: $0) }; value.cuts = cuts
            value.thresholdDB = PauseDetector.levelDB(wave: wave, settings: value)
            value.analyzed = SourceInterval(start: clip.start, end: clip.end); edit.clips[index].pauses = cuts.isEmpty ? nil : value
            var energyOnly = wave; energyOnly.speech = nil
            let previous = PauseDetector.raw(wave: energyOnly, clip: clip, settings: settings)
            rows.append(["source": source.filename, "clipStart": clip.start, "clipEnd": clip.end, "energyOnlyCount": previous.count,
                         "threshold": value.thresholdDB, "raw": raw.map { [$0.start, $0.end] }, "cuts": cuts.map { [$0.start, $0.end] }])
            print("PAUSES: energy alone found \(previous.count), speech-aware detection found \(cuts.count) cuts")
        }
        project.commit(edit); try project.validate()
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let output = destination.deletingLastPathComponent().appendingPathComponent("pauses-" + UUID().uuidString + ".mp4")
        try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]).write(to: destination.appendingPathExtension("analysis.json"))
        let renderState = project.edit
        let media = try await MediaRenderer.timeline(project: project, folder: folder)
        try require(abs(media.composition.duration.seconds - renderState.duration) < 0.04, "Actual main-editor playback follows the cut timeline")
        _ = try await MediaRenderer.render(project: project, folder: folder, destination: output) { _ in }
        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        try require(abs(duration - edit.duration) < 0.08, "Actual exported duration matches the detected cuts")
        project.undo(); try require(project.edit == original, "Undo restores all original footage after Pauses")
        var reopened = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        reopened.redo(); try require(reopened.edit == renderState, "Reopened redo restores exact pause choices")
        let after = try Data(contentsOf: folder.appendingPathComponent("project.json"))
        try require(after == bytes, "Private recording manifest stays untouched")
        let report: [String: Any] = ["originalDuration": original.duration, "editedDuration": edit.duration, "exportedDuration": duration,
                                    "removed": original.duration - edit.duration, "export": output.path, "clips": rows]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: destination, options: .atomic)
        print("PAUSES: real recording \(original.duration)s → \(duration)s; output \(output.lastPathComponent)")
    }
    let clip = TimelineClip(sourceID: UUID(), start: 0, end: 4)
    let quiet = SourceWaveform(duration: 4, peaks: Array(repeating: 0.001, count: 400))
    let raw = PauseDetector.raw(wave: quiet, clip: clip, settings: PauseSettings(levelMode: nil))
    try require(raw.count == 1, "A fully quiet clip must appear as a reviewable pause, not falsely report no pauses")
    let zeroPadding = PauseSettings(before: 0, after: 0)
    let quietCuts = PauseDetector.effectiveCuts(raw.map { DetectedPause(raw: $0) }, clip: clip, settings: zeroPadding)
    try require(abs(quietCuts.reduce(0) { $0 + $1.duration } - (4 - TimelineEditing.frame)) < 0.000001, "Fully quiet footage keeps exactly one selectable frame with zero padding")
    let protected = PauseDetector.effectiveCuts(raw.map { DetectedPause(raw: $0) }, clip: clip, settings: PauseSettings())
    try require(abs(protected.reduce(0) { $0 + $1.duration } - 3.7) < 0.000001, "Fully quiet footage honors both padding values")
    let short = [DetectedPause(raw: SourceInterval(start: 1, end: 1.2))]
    try require(PauseDetector.effectiveCuts(short, clip: clip, settings: PauseSettings()).isEmpty, "Padding-swallowed pauses do not count as removals")
    let overlapping = [DetectedPause(raw: SourceInterval(start: 1, end: 3)), DetectedPause(raw: SourceInterval(start: 2, end: 3.5))]
    try require(PauseDetector.effectiveCuts(overlapping, clip: clip, settings: zeroPadding) == [SourceInterval(start: 1, end: 3.5)], "Overlapping candidates never double-count removed time")
    let speech = SourceWaveform(duration: 4, peaks: Array(repeating: 0.2, count: 400))
    try require(PauseDetector.raw(wave: speech, clip: clip, settings: PauseSettings(levelMode: nil)).isEmpty, "Continuous speech produces no pause")
    let split = SourceWaveform(duration: 4, peaks: (0..<400).map { (100..<250).contains($0) ? 0.001 : 0.2 })
    let intervals = PauseDetector.raw(wave: split, clip: clip, settings: PauseSettings(levelMode: nil))
    try require(intervals == [SourceInterval(start: 1, end: 2.5)], "Raw boundaries align with quiet windows")
    print("PAUSES: detection, quiet/speech extremes and real export passed")
}

private func pauseLevelTests() throws {
    let clip = TimelineClip(sourceID: UUID(), start: 0, end: 4)
    let energy: [Float] = (0..<400).map { i in
        if (190..<210).contains(i) { return 0.08 } // A short word between two pauses.
        return (100..<300).contains(i) ? 0.01 : 0.24
    }
    let noisy = SourceWaveform(duration: 4, peaks: energy.map { $0 * 3 }, rms: energy)
    let defaults = PauseSettings()
    try require(PauseDetector.levelDB(wave: noisy, settings: defaults) == -32, "Automatic level follows room tone with headroom below speech")
    let cuts = PauseDetector.raw(wave: noisy, clip: clip, settings: defaults)
    try require(cuts.count == 2 && cuts[0].end <= 1.9 + 0.0001 && cuts[1].start >= 2.1 - 0.0001,
                "Room tone is detected without cutting the short word between pauses")
    let fixed = PauseSettings(thresholdDB: -50, levelMode: .manual)
    try require(PauseDetector.raw(wave: noisy, clip: clip, settings: fixed).isEmpty, "A stricter manual RMS threshold is honored")
    var stored = try JSONSerialization.jsonObject(with: JSONEncoder().encode(defaults)) as! [String: Any]
    stored.removeValue(forKey: "levelMode")
    let legacy = try JSONDecoder().decode(PauseSettings.self, from: JSONSerialization.data(withJSONObject: stored))
    try require(legacy.levelMode == nil && PauseDetector.raw(wave: noisy, clip: clip, settings: legacy).isEmpty,
                "Previously saved manual thresholds still use peak levels")
    let peaksOnly = SourceWaveform(duration: 4, peaks: energy)
    try require(PauseDetector.raw(wave: peaksOnly, clip: clip, settings: defaults).isEmpty,
                "Automatic detection cannot accidentally treat a peak-only cache as RMS")
    var roomTone = [Float](repeating: 0.014, count: 1200)
    roomTone[800] = 0.24
    func sparse(_ levels: [Float]) -> [SourceInterval] {
        PauseDetector.raw(wave: SourceWaveform(duration: 12, peaks: levels, rms: levels),
                          clip: TimelineClip(sourceID: UUID(), start: 0, end: 12), settings: defaults)
    }
    try require(sparse(roomTone).isEmpty, "One click cannot calibrate an otherwise continuous signal as speech")
    for i in 780..<830 { roomTone[i] = 0.24 }
    try require(sparse(roomTone).count == 2, "A mostly quiet take still protects a brief spoken passage")

    // The noisy gap never drops below the energy threshold. A short quiet word
    // splits it in two, even though that word is quieter than the background.
    var noisyRoom = [Float](repeating: 0.04, count: 400)
    var voice = Data(repeating: 8, count: noisyRoom.count)
    for i in 0..<75 { noisyRoom[i] = 0.3; voice[i] = 235 }
    for i in 190..<211 { noisyRoom[i] = 0.003; voice[i] = 210 }
    for i in 330..<400 { noisyRoom[i] = 0.24; voice[i] = 240 }
    var dialogue = SourceWaveform(duration: 4, peaks: noisyRoom, rms: noisyRoom, speech: voice)
    let speechCuts = PauseDetector.raw(wave: dialogue, clip: clip, settings: defaults)
    try require(speechCuts.count == 2 && abs(speechCuts[0].start - 0.75) < 1e-6 && abs(speechCuts[0].end - 1.9) < 1e-6
                && abs(speechCuts[1].start - 2.11) < 1e-6 && abs(speechCuts[1].end - 3.3) < 1e-6,
                "Speech-aware detection protects a quiet word between two noisy pauses")
    let manual = PauseSettings(thresholdDB: PauseDetector.levelDB(wave: dialogue, settings: defaults), levelMode: .manual)
    try require(PauseDetector.raw(wave: dialogue, clip: clip, settings: manual).isEmpty, "Manual mode uses the selected dB threshold, even with cached speech probabilities")
    var missedOnset = noisyRoom
    for i in 166..<179 { missedOnset[i] = 0.12 }
    missedOnset[110] = 0.12
    let withOnset = SourceWaveform(duration: 4, peaks: missedOnset, rms: missedOnset, speech: voice)
    let protected = PauseDetector.raw(wave: withOnset, clip: clip, settings: defaults)
    try require(protected.contains { $0.start < 1.10 && $0.end > 1.12 } && !protected.contains { $0.start < 1.77 && $0.end > 1.68 },
                "A brief unclassified syllable is retained while a single noise spike stays inside the pause")
    dialogue.speech = Data(repeating: 4, count: 400)
    try require(PauseDetector.raw(wave: dialogue, clip: clip, settings: defaults).isEmpty, "Without evidence of dialogue, an ambient take is not classified wholesale as a speech pause")
}

private func pauseWaveformUpgrade(root: URL) async throws {
    let folder = root.appendingPathComponent("pause-cache-" + UUID().uuidString)
    let cache = ProjectCacheLocation.root(in: folder)
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    let source = SourceMedia(filename: "source.mp4", duration: 4)
    let movie = folder.appendingPathComponent(source.filename)
    try FileManager.default.copyItem(at: root.appendingPathComponent(source.filename), to: movie)
    let cacheReader = SourceMediaCache()
    let key = try await cacheReader.fingerprint(movie)
    let file = cache.appendingPathComponent(key + "-wave-v2.json")
    let old = SourceWaveform(duration: 4, peaks: [Float](repeating: 0.25, count: 400))
    try JSONEncoder().encode(old).write(to: file)
    let initiallyLoaded = try await cacheReader.waveform(source: source, folder: folder)
    try require(initiallyLoaded.rms == nil && initiallyLoaded.peaks == old.peaks, "Timeline can keep using the previous peak cache")
    let measured = try await cacheReader.waveform(source: source, folder: folder, needsRMS: true)
    let disk = try JSONDecoder().decode(SourceWaveform.self, from: Data(contentsOf: file))
    try require(measured.rms?.count == 400 && measured.peaks.count == 400, "A new pause scan obtains energy for every peak window")
    let ratio = (measured.rms?[100] ?? 0) / max(measured.peaks[100], 1e-8)
    try require((0.65...0.78).contains(ratio), "A decoded sine wave has the expected RMS-to-peak ratio")
    try require(disk.rms == measured.rms && disk.peaks == measured.peaks, "The upgraded cache can be decoded on reopen")
    let voiced = try await cacheReader.waveform(source: source, folder: folder, needsRMS: true, needsSpeech: true)
    let reopened = try await SourceMediaCache().waveform(source: source, folder: folder, needsRMS: true, needsSpeech: true)
    try require(measured.speech == nil && voiced.speech?.count == 400, "Only a speech scan upgrades the ordinary waveform")
    try require(reopened.speech == voiced.speech && reopened.rms == voiced.rms, "Saved speech and energy bins survive reopening exactly")
    // Independent AAC decodes can differ slightly at individual window boundaries.
    let differences = zip(voiced.rms ?? [], measured.rms ?? []).map { abs($0 - $1) }
    try require(differences.count == 400 && differences.reduce(0, +) / 400 < 0.0001,
                "Speech analysis preserves the recorded signal level")
}
