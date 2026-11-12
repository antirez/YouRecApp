#if DEBUG
import AVFoundation
import Foundation
import Darwin
import UIKit
import CoreImage

// Development-only launch probe. It never modifies user projects and requires
// an explicit --audio-selftest argument. Input remains local on the device.
enum AudioDiagnostics {
    /// Delete exactly one disposable camera-test project after the host has
    /// archived it. Verify every file against the host archive before removal.
    static func retireArchivedCameraTest() async {
        struct Archive: Decodable { let id: UUID; let files: [String: String] }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].resolvingSymlinksInPath()
        let request = docs.appendingPathComponent("ArchivedCameraTest.json")
        do {
            let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: request))
            let base = docs.appendingPathComponent("RecorderUITestProjects")
            let dir = base.appendingPathComponent(archive.id.uuidString)
            guard !archive.files.isEmpty, archive.files["project.json"] != nil,
                  base.resolvingSymlinksInPath().path == docs.resolvingSymlinksInPath().appendingPathComponent("RecorderUITestProjects").path,
                  dir.resolvingSymlinksInPath().path == base.resolvingSymlinksInPath().appendingPathComponent(archive.id.uuidString).path,
                  let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey,.isSymbolicLinkKey]) else { throw ProjectError.invalidDocument }
            var verified = Set<String>()
            for case let file as URL in walker {
                let info = try file.resourceValues(forKeys: [.isRegularFileKey,.isSymbolicLinkKey])
                guard info.isSymbolicLink != true else { throw ProjectError.invalidDocument }
                if info.isRegularFile != true { continue }
                let path = file.resolvingSymlinksInPath().path
                let prefix = dir.resolvingSymlinksInPath().path + "/"
                guard path.hasPrefix(prefix) else { throw RecoveryError.identity }
                let relative = String(path.dropFirst(prefix.count))
                guard let expected = archive.files[relative],
                      try await SourceMediaCache.shared.fingerprint(file, memoize: false) == expected else { throw NSError(domain: "ArchivedCameraTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Archive mismatch at " + relative]) }
                verified.insert(relative)
            }
            guard verified == Set(archive.files.keys) else { throw ProjectError.invalidDocument }
            try FileManager.default.removeItem(at: dir)
            try FileManager.default.removeItem(at: request)
            try Data("verified".utf8).write(to: docs.appendingPathComponent("ArchivedCameraTest.result"), options: .atomic)
        } catch {
            try? Data(error.localizedDescription.utf8).write(to: docs.appendingPathComponent("ArchivedCameraTest.result"), options: .atomic)
        }
    }
    // Explicit recovery tool. Restores a previously archived preference domain;
    // only removes listed empty projects, never any source media or edits.
    @MainActor static func restoreDevelopmentBackup() {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var report: [String: Any] = [:]
        do {
            let file = root.appendingPathComponent("DevelopmentPreferencesRestore.plist")
            guard let domain = try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any], let bundle = Bundle.main.bundleIdentifier else { throw ProjectError.invalidDocument }
            UserDefaults.standard.setPersistentDomain(domain, forName: bundle)
            UserDefaults.standard.synchronize()
            let emptyList = root.appendingPathComponent("DevelopmentEmptyProjects.json")
            if FileManager.default.fileExists(atPath: emptyList.path) {
                let ids = try JSONDecoder().decode([UUID].self, from: Data(contentsOf: emptyList))
                for id in ids {
                    let directory = root.appendingPathComponent("Projects").appendingPathComponent(id.uuidString)
                    let data = try Data(contentsOf: directory.appendingPathComponent("project.json"))
                    guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let sources = document["sources"] as? [Any], sources.isEmpty,
                          (document["captureLedger"] as? [Any])?.isEmpty != false else { throw ProjectError.invalidDocument }
                    let children = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                    guard Set(children).isSubset(of: ["project.json", "History"]) else { throw ProjectError.invalidDocument }
                    try FileManager.default.removeItem(at: directory)
                }
                try FileManager.default.removeItem(at: emptyList)
            }
            try FileManager.default.removeItem(at: file)
            report["status"] = "passed"
        } catch { report = ["status": "failed", "error": error.localizedDescription] }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: .prettyPrinted) { try? data.write(to: root.appendingPathComponent("development-restore-report.json")) }
    }
    // Explicit development-only cleanup of artifacts already archived on the Mac.
    // Names are checked against this harness's namespace; Projects is never allowed.
    static func cleanup() async {
        await Task.detached {
            let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let manifest = root.appendingPathComponent("DiagnosticsCleanup.json")
            var report: [String: Any] = [:]
            do {
                let names = try JSONDecoder().decode([String].self, from: Data(contentsOf: manifest))
                let fixed: Set<String> = ["RecorderUITestProjects", "dual-capture-latest.txt", "DualCapturePreferences.plist", "TransitionsQA", "PausesQA", "AudioDiagnostics", "AudioStress", "capture-diagnostics-latest.txt", "capture-stress-latest.txt", "editor-diagnostics-latest.txt", "recorder-polish-latest.txt", "audio-gain-checks-latest.txt", "tracks-diagnostics-latest.txt", "capture-review-latest.txt", "CaptureReviewPreferences.plist"]
                let prefixes = ["CaptureDiagnostics-Dual-", "CaptureReviewDiagnostics-", "TrackDiagnostics-", "AudioGainDiagnostics-", "CaptureDiagnostics-Polish-", "CaptureDiagnostics-", "CaptureStress-", "EditorDiagnostics-", "EditorDiagnostics-Color-"]
                guard names.allSatisfy({ name in
                    fixed.contains(name) || prefixes.contains { prefix in
                        name.hasPrefix(prefix) && UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
                    }
                }) else { throw ProjectError.invalidDocument }
                var removed: [String] = []
                for name in names {
                    let url = root.appendingPathComponent(name)
                    if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                    removed.append(name)
                }
                report = ["status": "passed", "removed": removed]
                try FileManager.default.removeItem(at: manifest)
            } catch { report = ["status": "failed", "error": error.localizedDescription] }
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: root.appendingPathComponent("diagnostics-cleanup-report.json"), options: .atomic)
            }
        }.value
    }
    @MainActor static func gainResetChecks() async {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = documents.appendingPathComponent("AudioGainDiagnostics-" + UUID().uuidString)
        var report: [String: Any] = ["status": "running"]
        func save() { if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: folder.appendingPathComponent("report.json"), options: .atomic) } }
        func check(_ condition: Bool, _ message: String) throws { if !condition { throw NSError(domain: "GainResetQA", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) } }
        let editor = EditorController(); defer { editor.stop() }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try folder.lastPathComponent.write(to: documents.appendingPathComponent("audio-gain-checks-latest.txt"), atomically: true, encoding: .utf8); save()
            let url = folder.appendingPathComponent("signal.caf")
            let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
            do {
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 288000)!; buffer.frameLength = 288000
                for i in 0..<288000 { for c in 0..<2 { buffer.floatChannelData![c][i] = Float(0.5 * sin(Double(i) * .pi / 24)) } }
                try file.write(from: buffer)
            }
            var project = Project(title: "Gain reset QA")
            project.append(SourceMedia(filename: "signal.caf", duration: 6))
            var state = project.edit
            state.timeline.unlink(state.timeline.entireSelection())
            state.timeline.remove(TimelineSelection(video: Set(state.timeline.video.map(\.id))))
            project.commit(state)
            await editor.load(project, folder: folder)
            try check(editor.error == nil && editor.player.currentItem != nil, "Load generated audio")
            let originalItem = editor.player.currentItem, selection = state.timeline.entireSelection()
            func peak() async throws -> Float {
                guard let item = editor.player.currentItem else { throw ProjectError.invalidMedia }
                return try await ExportAudioLevel.peak(asset: item.asset, mix: item.audioMix, duration: 6)
            }
            let original = try await peak()
            editor.auditionGain(12, selection: selection)
            let boosted = try await peak()
            await editor.load(project, folder: folder)
            let reset = try await peak()
            try check(editor.player.currentItem === originalItem && AudioGainMix.auditionDB(on: originalItem) == nil, "Same-edit reset clears transient gain")
            try check(abs(original - 0.5) < 0.001 && boosted > 1.9 && abs(reset - original) < 0.000001, "Reset must restore unclipped samples")
            report["originalPeak"] = original; report["boostedPeak"] = boosted; report["resetPeak"] = reset
            var loud = state; loud.timeline.setVolume(12, muted: false, selection: selection); project.commit(loud)
            await editor.load(project, folder: folder)
            let committedHigh = try await peak()
            project.commit(state); await editor.load(project, folder: folder)
            let committedReset = try await peak()
            try check(committedHigh > 1.9 && abs(committedReset - original) < 0.000001, "Two committed gestures restore original samples")
            report["committedHighPeak"] = committedHigh; report["committedResetPeak"] = committedReset
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            editor.player.volume = 0.1; editor.togglePlay()
            for _ in 0..<60 where editor.player.currentTime().seconds < 0.1 { try await Task.sleep(for: .milliseconds(100)) }
            try check(editor.player.currentTime().seconds >= 0.1, "Physical playback starts")
            for db in [12.0, 0, 12, 0] { editor.auditionGain(db, selection: selection); try await Task.sleep(for: .milliseconds(200)) }
            await editor.load(project, folder: folder)
            try check(AudioGainMix.auditionDB(on: editor.player.currentItem) == nil && editor.player.currentItem?.status != .failed, "Playing reset clears gain without replacing or failing playback")
            report["playbackTime"] = editor.player.currentTime().seconds; report["status"] = "passed"
        } catch { report["status"] = "failed"; report["error"] = error.localizedDescription }
        save()
    }

    /// Runs on generated media only; the report and source stay outside Projects.
    @MainActor static func gainChecks() async {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = documents.appendingPathComponent("AudioGainDiagnostics-" + UUID().uuidString)
        var report: [String: Any] = ["status": "running", "started": Date().description]
        func save() { if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: folder.appendingPathComponent("report.json"), options: .atomic) } }
        func require(_ condition: Bool, _ message: String) throws { if !condition { throw NSError(domain: "AudioGainQA", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) } }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try folder.lastPathComponent.write(to: documents.appendingPathComponent("audio-gain-checks-latest.txt"), atomically: true, encoding: .utf8)
            report["stage"] = "Generate 30-minute stereo AAC"; save()
            let url = folder.appendingPathComponent("thirty-minutes.m4a")
            let generation = ProcessInfo.processInfo.systemUptime
            try await Task.detached(priority: .utility) {
                let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128000])
                let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48000)!
                buffer.frameLength = 48000
                for frame in 0..<48000 { for channel in 0..<2 { buffer.floatChannelData![channel][frame] = Float(0.5 * sin(Double(frame) * .pi / 24)) } }
                for _ in 0..<1800 { try Task.checkCancellation(); try file.write(from: buffer) }
            }.value
            report["generationSeconds"] = ProcessInfo.processInfo.systemUptime - generation
            let asset = AVURLAsset(url: url), owner = UUID()
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw ProjectError.invalidMedia }
            let segment = AudioEnvelopeSegment(start: 0, end: 1800, fadeIn: 0.008, fadeOut: 0.008, clipStart: 0, clipEnd: 1800, transitionIn: 0, transitionOut: 0, owner: owner)
            let parameter = AVMutableAudioMixInputParameters(track: track)
            parameter.audioTapProcessor = try CutAudioEnvelope.make(segments: [segment])
            let mix = AVMutableAudioMix(); mix.inputParameters = [parameter]
            AudioGainMix.register(mix, records: [track.trackID: [segment]])
            let selection = TimelineSelection(audio: [owner])
            var measurements: [[String: Any]] = []
            for seconds in [60.0, 1800.0] {
                report["stage"] = "Analyze \(Int(seconds)) seconds"; save()
                let start = ProcessInfo.processInfo.systemUptime, before = footprint()
                let result = try await Task.detached(priority: .userInitiated) { try await AudioHeadroom.analyze(asset: asset, mix: mix, selection: selection, range: 0...seconds) }.value
                try require(result.samples > Int(seconds * 40000) && !result.clips(at: 0) && result.clips(at: 12), "Decoded headroom threshold or sample coverage failed")
                measurements.append(["duration": seconds, "analysisSeconds": ProcessInfo.processInfo.systemUptime - start, "safeMaximumDB": 20 * log10(result.maximum), "samples": result.samples, "footprintBefore": before, "footprintAfter": footprint()])
                report["measurements"] = measurements; save()
            }
            report["stage"] = "Cancellation"; save()
            let cancellation = Task.detached { try await AudioHeadroom.analyze(asset: asset, mix: mix, selection: selection, range: 0...1800) }
            try await Task.sleep(for: .milliseconds(100))
            let cancelStart = ProcessInfo.processInfo.systemUptime; cancellation.cancel()
            do { _ = try await cancellation.value; throw ProjectError.invalidMedia } catch is CancellationError {}
            report["cancellationSeconds"] = ProcessInfo.processInfo.systemUptime - cancelStart
            report["stage"] = "Gain replacement during playback"; save()
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            let item = AVPlayerItem(asset: asset); try AudioGainMix.install(mix, on: item)
            let player = AVPlayer(playerItem: item); player.volume = 0.1; player.play()
            defer { player.pause() }
            for _ in 0..<100 where player.currentTime().seconds < 0.2 { try await Task.sleep(for: .milliseconds(100)) }
            try require(player.currentTime().seconds >= 0.2, "Playback did not start")
            let wallStart = ProcessInfo.processInfo.systemUptime, mediaStart = player.currentTime().seconds
            var lastTime = mediaStart, lastAdvance = wallStart, largestStall = 0.0
            for step in 0..<100 {
                AudioGainMix.audition([-6.0, 0, 3][step % 3], selection: selection, on: item)
                try await Task.sleep(for: .milliseconds(50))
                let now = ProcessInfo.processInfo.systemUptime, time = player.currentTime().seconds
                largestStall = max(largestStall, now - lastAdvance)
                if time > lastTime + 0.001 { lastAdvance = now; lastTime = time }
                try require(item.status != .failed && time >= mediaStart, "Playback failed or rewound during gain adjustment")
            }
            let advanced = player.currentTime().seconds - mediaStart, elapsed = ProcessInfo.processInfo.systemUptime - wallStart
            report["gainChanges"] = 100; report["playbackSeconds"] = advanced; report["playbackWallSeconds"] = elapsed; report["largestClockStallSeconds"] = largestStall
            try require(advanced > elapsed * 0.9 && largestStall < 0.4, "Playback clock stalled during gain replacement")
            player.pause()
            report["stage"] = "Distant waveform tiles"; save()
            for index in [0, 225, 449] {
                let tile = try await WaveformDetailCache.shared.tile(url: url, index: index)
                try require(tile.low.count == 4000 && tile.high.count == 4000 && (tile.high.max() ?? 0) > 0.4, "Waveform tile failed on long audio")
            }
            report["status"] = "passed"; report["stage"] = "complete"
        } catch { report["status"] = "failed"; report["error"] = String(describing: error) }
        save()
    }
    static func resume() async {
        await Task.detached(priority: .userInitiated) {
            let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("AudioDiagnostics", isDirectory: true)
            let folder = root.appendingPathComponent("Resume-" + UUID().uuidString, isDirectory: true)
            var report: [String: Any] = ["started": Date().description, "status": "running"]
            func save() {
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: folder.appendingPathComponent("report.json"), options: .atomic)
                }
            }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try folder.lastPathComponent.write(to: root.appendingPathComponent("resume-latest.txt"), atomically: true, encoding: .utf8)
                save()
                let input = root.appendingPathComponent("input.wav")
                let file = try AVAudioFile(forReading: input)
                // Bound this diagnostic to the private 20-second excerpt.
                guard file.processingFormat.sampleRate == 48000, file.length > Int64(StudioVoiceProcessor.strideFrames), file.length <= 48000 * 30 else { throw ProjectError.invalidMedia }
                let chunks = folder.appendingPathComponent("studio.chunks", isDirectory: true)
                let interrupted = folder.appendingPathComponent("interrupted.caf")
                let task = Task.detached {
                    try StudioVoiceProcessor.process(input: input, output: interrupted, amount: 0.35, resumeFolder: chunks) { value in
                        if value > 0 { withUnsafeCurrentTask { $0?.cancel() } }
                    }
                }
                do { try await task.value; throw ProjectError.invalidMedia } catch is CancellationError {}
                let first = chunks.appendingPathComponent("0.caf")
                let saved = try Data(contentsOf: first)
                report["stage"] = "resume and compare"; save()
                let resumed = folder.appendingPathComponent("resumed.caf"), reference = folder.appendingPathComponent("reference.caf")
                try StudioVoiceProcessor.process(input: input, output: resumed, amount: 0.35, resumeFolder: chunks) { _ in }
                try StudioVoiceProcessor.process(input: input, output: reference, amount: 0.35) { _ in }
                let resumedBytes = try Data(contentsOf: resumed), referenceBytes = try Data(contentsOf: reference)
                guard resumedBytes == referenceBytes, saved == (try Data(contentsOf: first)) else { throw ProjectError.invalidMedia }
                report["byteIdenticalResume"] = true; report["preservedFirstChunk"] = true
                report["outputFrames"] = try AVAudioFile(forReading: resumed).length
                report["stage"] = "shared neural prefix with changed gain"; save()
                let isolation = AudioEffect.make(.voiceIsolation), studio = AudioEffect.make(.studioVoice)
                let prefixes = [folder.appendingPathComponent("isolation.caf"), folder.appendingPathComponent("studio.caf")]
                let firstPeak = try OfflineAudioPipeline.process(input: input, effects: [isolation, studio, AudioEffect(kind: .gain, amount: 0)], output: folder.appendingPathComponent("first.caf"), checkpoints: prefixes) { _ in }
                let bytes = try Data(contentsOf: prefixes[1])
                let start = ProcessInfo.processInfo.systemUptime
                let nextPeak = try OfflineAudioPipeline.process(input: input, effects: [isolation, studio, AudioEffect(kind: .gain, amount: -6)], output: folder.appendingPathComponent("changed.caf"), checkpoints: prefixes) { _ in }
                guard bytes == (try Data(contentsOf: prefixes[1])), abs(nextPeak / firstPeak - pow(10, -6.0 / 20)) < 0.0001 else { throw ProjectError.invalidMedia }
                report["prefixReuseSeconds"] = ProcessInfo.processInfo.systemUptime - start
                report["prefixPreserved"] = true; report["status"] = "passed"
            } catch { report["status"] = "failed"; report["error"] = error.localizedDescription }
            save()
        }.value
    }
    static func run(stress: Bool = false, deepFilter: Bool = false, studioRestoration: Bool = false) async {
        await Task.detached(priority: .userInitiated) {
            let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(stress ? "AudioStress" : "AudioDiagnostics", isDirectory: true)
            var report: [String: Any] = ["started": Date().description, "os": ProcessInfo.processInfo.operatingSystemVersionString,
                                       "model": studioRestoration ? AudioModel.voiceFixer.id : deepFilter ? AudioModel.deepFilter.id : AudioModel.rnnoise.id,
                                       "runtime": studioRestoration ? AudioModel.voiceFixer.runtime : deepFilter ? AudioModel.deepFilter.runtime : AudioModel.rnnoise.runtime]
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let input = root.appendingPathComponent("input.wav")
                let original = try AVAudioFile(forReading: input)
                report["inputFrames"] = original.length
                report["inputSampleRate"] = original.processingFormat.sampleRate
                report["inputChannels"] = original.processingFormat.channelCount
                var measurements: [[String: Any]] = []
                var maxFootprint: UInt64 = 0
                var lastReport = 0.0
                func save() {
                    report["measurements"] = measurements
                    report["maximumFootprintBytes"] = maxFootprint
                    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                        try? data.write(to: root.appendingPathComponent("report.json"), options: .atomic)
                    }
                }
                report["status"] = "running"; save()
                var isolation = AudioEffect.make(.voiceIsolation)
                if deepFilter { isolation.model = .deepFilter }
                let selectedIsolation = isolation
                if stress {
                    let cancelled = root.appendingPathComponent("cancelled-" + UUID().uuidString + ".caf")
                    let cancellation = Task.detached {
                        try OfflineAudioPipeline.process(input: input, effects: [selectedIsolation, .make(.studioVoice)], output: cancelled) { _ in }
                    }
                    try await Task.sleep(for: .milliseconds(100)); cancellation.cancel()
                    do { _ = try await cancellation.value; throw ProjectError.invalidMedia }
                    catch is CancellationError { report["cancellationPassed"] = !FileManager.default.fileExists(atPath: cancelled.path) }
                    save()
                }
                let chains: [(String, [AudioEffect])] = studioRestoration ? [
                    ("studio-restoration", [.make(.studioRestoration)]),
                    ("studio-restoration-eq-gain", [.make(.studioRestoration), AudioEffect(kind: .equalizer, amount: 1.5, frequency: 1800), AudioEffect(kind: .gain, amount: -6)])
                ] : deepFilter ? [
                    ("deepfilter", [selectedIsolation]),
                    ("deepfilter-studio-eq", [selectedIsolation, .make(.studioVoice), AudioEffect(kind: .equalizer, amount: 1.5, frequency: 1800)])
                ] : [
                    ("isolation", [AudioEffect.make(.voiceIsolation)]),
                    ("isolation-eq-isolation", [.make(.voiceIsolation), AudioEffect(kind: .equalizer, amount: 2, frequency: 2200), .make(.voiceIsolation)]),
                    ("studio-clarity", [.make(.studioVoice)]),
                    ("isolation-studio-eq", [.make(.voiceIsolation), .make(.studioVoice), AudioEffect(kind: .equalizer, amount: 1.5, frequency: 1800)])
                ]
                for (name, chain) in chains where !stress || name == (deepFilter ? "deepfilter-studio-eq" : "isolation-studio-eq") {
                    report["currentChain"] = name; report["progress"] = 0.0; save()
                    let output = root.appendingPathComponent(name + "-" + UUID().uuidString + ".caf")
                    let start = ProcessInfo.processInfo.systemUptime
                    let peak = try OfflineAudioPipeline.process(input: input, effects: chain, output: output) { value in
                        let now = ProcessInfo.processInfo.systemUptime
                        if now - lastReport >= 0.5 {
                            lastReport = now; maxFootprint = max(maxFootprint, footprint())
                            report["progress"] = value; report["thermalState"] = ProcessInfo.processInfo.thermalState.rawValue; save()
                        }
                    }
                    let elapsed = ProcessInfo.processInfo.systemUptime - start
                    if deepFilter && !stress && name == "deepfilter" {
                        let repeatOutput = root.appendingPathComponent("deepfilter-repeat-" + UUID().uuidString + ".caf")
                        _ = try OfflineAudioPipeline.process(input: input, effects: chain, output: repeatOutput) { _ in }
                        let firstBytes = try Data(contentsOf: output), secondBytes = try Data(contentsOf: repeatOutput)
                        guard firstBytes == secondBytes else { throw ProjectError.invalidMedia }
                        report["deepFilterRepeatedBytesIdentical"] = true
                        try FileManager.default.removeItem(at: repeatOutput)
                    }
                    let rendered = try AVAudioFile(forReading: output)
                    guard rendered.length == original.length else { throw AudioProcessingError.invalidFormat }
                    measurements.append(["chain": name, "seconds": elapsed, "outputFrames": rendered.length,
                                         "peak": peak, "output": output.lastPathComponent,
                                         "thermalState": ProcessInfo.processInfo.thermalState.rawValue])
                }
                report["measurements"] = measurements
                report["maximumFootprintBytes"] = maxFootprint
                report["status"] = "passed"; report["progress"] = 1.0
            } catch { report["status"] = "failed"; report["error"] = error.localizedDescription }
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: root.appendingPathComponent("report.json"), options: .atomic)
            }
        }.value
    }
    private static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

}

@MainActor
enum CaptureDiagnostics {
    /// Real writer/bookmark smoke test. Public taps and both landscape layouts
    /// are covered by UI tests separately; this must never write into Projects.
    static func recorderPolish(_ camera: CaptureController) async {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let root = documents.appendingPathComponent("CaptureDiagnostics-Polish-" + UUID().uuidString, isDirectory: true)
        let oldCallback = camera.onSegment
        let matrix = CommandLine.arguments.contains("--framing-case")
        let oldQuality = camera.quality, oldColorMode = camera.colorMode, oldEffects = camera.videoEffects
        let oldMirror = camera.mirrorPreview, oldRecordMirror = camera.mirrorRecording
        let oldFit = UserDefaults.standard.object(forKey: "fitRecordedFrame")
        let rotate = CommandLine.arguments.contains("--framing-rotation-sweep"), oldPeaking = camera.focusPeaking
        let protect = CommandLine.arguments.contains("--framing-protect-audio")
        let oldProtection = UserDefaults.standard.object(forKey: "protectRecordingAudio")
        if protect { UserDefaults.standard.set(true, forKey: "protectRecordingAudio") }
        let saved = UserDefaults.standard.dictionaryRepresentation().filter { $0.key.hasPrefix("camera.") || ["lastFrontCamera", "lastRearCamera"].contains($0.key) }
        var originalCamera = ""
        var files: [URL] = [], report: [String: Any] = ["started": Date().description]
        camera.onSegment = { url, completion in files.append(url); completion(true) }
        defer {
            if protect { UserDefaults.standard.set(oldProtection, forKey: "protectRecordingAudio") }
            if rotate {
                camera.probeLockedRotation(nil)
                if camera.focusPeaking != oldPeaking { camera.toggleFocusPeaking() }
            }
            if matrix {
                camera.suspend(); camera.setQuality(oldQuality); camera.setColorMode(oldColorMode); camera.setVideoEffects(oldEffects)
                camera.mirrorPreview = oldMirror; camera.mirrorRecording = oldRecordMirror
                UserDefaults.standard.set(oldFit, forKey: "fitRecordedFrame")
                camera.probeRestoreSettings(saved, cameraID: originalCamera)
            }
            camera.onSegment = oldCallback
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: root.appendingPathComponent("report.json"), options: .atomic)
                try? root.lastPathComponent.write(to: documents.appendingPathComponent("recorder-polish-latest.txt"), atomically: true, encoding: .utf8)
            }
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            camera.prepare(); try await wait { camera.ready && !camera.switchingCamera }
            originalCamera = camera.cameraID
            if matrix {
                let front = CommandLine.arguments.contains("--framing-front")
                if let choice = camera.cameras.first(where: { $0.front == front && $0.available }) { camera.switchCamera(choice.id); try await wait { camera.cameraID == choice.id && !camera.switchingCamera } }
                let quality: CaptureQuality = CommandLine.arguments.contains("--framing-4k") ? .ultraHD4K : .hd1080
                camera.setQuality(quality); try await wait { camera.quality == quality }
                let hdr = CommandLine.arguments.contains("--framing-hdr")
                camera.setHDR(hdr); try await wait { camera.hdrActive == hdr }
                if CommandLine.arguments.contains("--framing-log") {
                    guard camera.logSupported else { throw NSError(domain: "LogQA", code: 1, userInfo: [NSLocalizedDescriptionKey: "This camera/format does not support genuine Log."]) }
                    camera.setColorMode(.log); try await wait { camera.activeLog != nil }
                }
                UserDefaults.standard.set(!CommandLine.arguments.contains("--framing-fill"), forKey: "fitRecordedFrame")
                camera.mirrorPreview = true; camera.mirrorRecording = CommandLine.arguments.contains("--framing-mirror")
                camera.setVideoEffects(CommandLine.arguments.contains("--framing-effects") ? [VideoEffectSettings(.silentTint)] : [])
            }
            try await Task.sleep(for: .seconds(1))
            if rotate {
                if !camera.focusPeaking { camera.toggleFocusPeaking() }
                guard let bounds = camera.probePreviewLayout()["bounds"] as? [Double], bounds.count == 4 else { throw ProjectError.invalidMedia }
                var changes = 0, samples = 0
                for turns in [1, 0, 3, 1] {
                    camera.probeLockedRotation(turns)
                    let wanted = (camera.previewRotationAngle + CGFloat(turns * 90)).truncatingRemainder(dividingBy: 360)
                    for _ in 0..<45 {
                        try await Task.sleep(for: .milliseconds(8))
                        guard let rect = camera.probePreviewLayout()["bounds"] as? [Double], rect.count == 4 else { throw ProjectError.invalidMedia }
                        samples += 1
                        if abs(rect[2] - bounds[2]) > 2 || abs(rect[3] - bounds[3]) > 2 { changes += 1 }
                    }
                    guard camera.rotationAngle == wanted else { throw ProjectError.invalidMedia }
                }
                report["lockedRotationSamples"] = samples; report["incorrectViewportSamples"] = changes
                guard changes == 0 else { throw NSError(domain: "CameraQA", code: 1, userInfo: [NSLocalizedDescriptionKey: "Locked preview changed size during rotation"]) }
            }
            report["camera"] = await camera.probeSnapshot()
            report["idleLayout"] = camera.probePreviewLayout()
            _ = try await camera.probeLivePreview(to: root.appendingPathComponent("idle-preview.png"))
            try camera.probeScreen(to: root.appendingPathComponent("idle-screen.png"))
            for index in 0..<2 {
                camera.start(in: root); try await wait { camera.state == .recording }
                try await Task.sleep(for: .seconds(1.2))
                camera.addBookmark()
                report["recording\(index)Layout"] = camera.probePreviewLayout()
                report["recording\(index)Camera"] = await camera.probeSnapshot()
                try camera.probeScreen(to: root.appendingPathComponent("recording-\(index)-screen.png"))
                _ = try await camera.probeLivePreview(to: root.appendingPathComponent("recording-\(index)-preview.png"))
                try await Task.sleep(for: .seconds(0.8))
                camera.stop(pause: index == 0)
                try await wait { !camera.hasActiveTake }
                if index == 0 {
                    guard camera.state == .paused else { throw ProjectError.invalidMedia }
                    report["pausedLayout"] = camera.probePreviewLayout()
                    try camera.probeScreen(to: root.appendingPathComponent("paused-screen.png"))
                }
            }
            guard files.count == 2, camera.state == .idle else { throw ProjectError.invalidMedia }
            try await Task.sleep(for: .seconds(0.5))
            report["stoppedLayout"] = camera.probePreviewLayout()
            report["stoppedAlertProtection"] = AVAudioSession.sharedInstance().prefersNoInterruptionsFromSystemAlerts
            var media: [[String: Any]] = []
            for file in files {
                let asset = AVURLAsset(url: file), duration = try await asset.load(.duration).seconds
                let video = try await asset.loadTracks(withMediaType: .video)
                let audio = try await asset.loadTracks(withMediaType: .audio)
                let events = try JSONDecoder().decode([CaptureEvent].self, from: Data(contentsOf: file.deletingPathExtension().appendingPathExtension("events.json")))
                let marks = events.filter { $0.kind == "bookmark" }
                guard !video.isEmpty, !audio.isEmpty, marks.count == 1, marks[0].time > 0, marks[0].time < duration else { throw ProjectError.invalidMedia }
                let size = try await video[0].load(.naturalSize)
                let formats = try await video[0].load(.formatDescriptions)
                if CommandLine.arguments.contains("--framing-log") {
                    guard formats.contains(where: { LogColor.profile($0) != nil }), formats.allSatisfy({ !VideoColor.isHDR($0) }) else { throw ProjectError.invalidMedia }
                }
                media.append(["file": file.lastPathComponent, "duration": duration, "bookmark": marks[0].time, "width": size.width, "height": size.height,
                              "log": formats.compactMap { LogColor.profile($0)?.rawValue }.first ?? "none", "hdr": formats.contains { VideoColor.isHDR($0) },
                              "format": formats.map { String(describing: CMFormatDescriptionGetExtensions($0)) }])
            }
            report["media"] = media; report["status"] = "passed"
        } catch {
            report["status"] = "failed"; report["error"] = error.localizedDescription
            camera.stop(); try? await wait { !camera.hasActiveTake }; camera.finishPausedTake()
        }
    }
    /// Exercise actual camera writes and interrupted-ramp memory without
    /// recording private footage or changing the user's projects/preferences.
    static func zoom(_ camera: CaptureController) async {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("zoom-diagnostics.json")
        let saved = UserDefaults.standard.dictionaryRepresentation().filter { $0.key.hasPrefix("camera.") || ["lastFrontCamera", "lastRearCamera"].contains($0.key) }
        var originalCamera = ""
        var report: [String: Any] = ["started": Date().description]
        func check(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: "ZoomDiagnostics", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        defer {
            camera.suspend()
            if !originalCamera.isEmpty { camera.probeRestoreSettings(saved, cameraID: originalCamera) }
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: url, options: .atomic)
            }
        }
        do {
            camera.prepare(); try await wait { camera.ready }
            originalCamera = camera.cameraID
            let low = camera.minZoom, high = min(camera.maxZoom, low * 3)
            try check(high > low, "Camera has no zoom range")
            var runs: [[String: Any]] = []
            let wideRange = min(camera.maxZoom, low * 8)
            for (start, target, seconds) in [(low, high, 1.0), (high, low, 3.0), (low, wideRange, 1.0), (low, min(camera.maxZoom, low * 2), 10.0)] {
                camera.setZoom(start, seconds: 0)
                try await Task.sleep(for: .milliseconds(200))
                camera.setZoom(target, seconds: seconds)
                let initial = await camera.probeSnapshot()
                let began = initial["zoomTransitionBegan"] as? Double ?? -1
                try check(began > 0, "Transition did not start")
                var samples: [[String: Double]] = []
                var completed = false
                var maxError = 0.0
                var endGap = 0.0
                let reference = ZoomTransition(start: start, target: target, began: began, duration: seconds)
                while ProcessInfo.processInfo.systemUptime < began + seconds + 1 {
                    let snapshot = await camera.probeSnapshot()
                    let time = snapshot["uptime"] as? Double ?? 0
                    let zoom = snapshot["zoom"] as? Double ?? 0
                    samples.append(["elapsed": time - began, "zoom": zoom])
                    maxError = max(maxError, abs(log2(zoom / reference.value(at: time))))
                    if snapshot["zoomTransitionActive"] as? Bool == false {
                        endGap = snapshot["zoomEndGap"] as? Double ?? 999
                        try check(abs(zoom - target) < 0.0001, "Transition missed target")
                        try check(abs(time - began - seconds) < 0.15, "Transition missed duration")
                        try check(endGap < log2(1.01), "Final correction exceeded one percent")
                        completed = true; break
                    }
                    try await Task.sleep(for: .milliseconds(20))
                }
                // Readings are quantized to 30 fps: a fast 1→8 ramp can move
                // 0.1875 log2 units in one frame at its peak velocity.
                let frameTolerance = max(0.15, abs(log2(target / start)) * 1.875 / seconds / 30 + 0.05)
                runs.append(["seconds": seconds, "maxLogError": maxError, "frameTolerance": frameTolerance,
                             "endGap": endGap, "samples": samples])
                report["transitions"] = runs
                try check(completed && maxError < frameTolerance, "Camera did not follow easing curve")
            }
            // Return to an already-saved target after a focus change has
            // persisted an intermediate zoom. Completion must overwrite it.
            camera.setZoom(low, seconds: 0)
            try await Task.sleep(for: .milliseconds(100))
            camera.setZoom(high, seconds: 3)
            try await Task.sleep(for: .milliseconds(600))
            camera.setFocus(locked: !camera.readings.focusLocked)
            try await Task.sleep(for: .milliseconds(100))
            camera.setZoom(low, seconds: 1)
            try await Task.sleep(for: .milliseconds(1300))
            let savedZoom = UserDefaults.standard.dictionary(forKey: "camera." + originalCamera)?["zoom"] as? Double ?? -1
            try check(abs(savedZoom - low) < 0.0001, "Focus change left an intermediate zoom saved")
            report["focusDuringZoomPersistence"] = true
            if let other = camera.cameras.first(where: { $0.id != originalCamera && $0.available }) {
                camera.setZoom(high, seconds: 3)
                try await Task.sleep(for: .milliseconds(600))
                camera.switchCamera(other.id)
                try await wait { camera.cameraID == other.id && !camera.switchingCamera }
                let stopped = UserDefaults.standard.dictionary(forKey: "camera." + originalCamera)?["zoom"] as? Double ?? -1
                camera.switchCamera(originalCamera)
                try await wait { camera.cameraID == originalCamera && !camera.switchingCamera }
                try await Task.sleep(for: .seconds(3))
                let restored = await camera.probeSnapshot()
                try check(abs((restored["zoom"] as? Double ?? 0) - stopped) < 0.0001, "Interrupted zoom resumed or lost per-camera memory")
                report["switchCancellation"] = restored
            }
            camera.setZoom(high, seconds: 3)
            try await Task.sleep(for: .milliseconds(400))
            camera.suspend(); try await wait { !camera.ready }
            let stopped = await camera.probeSnapshot()
            try await Task.sleep(for: .seconds(1))
            let later = await camera.probeSnapshot()
            try check(stopped["zoom"] as? Double == later["zoom"] as? Double && later["zoomTransitionActive"] as? Bool == false, "Zoom continued after suspension")
            report["suspendCancellation"] = true
            report["status"] = "passed"
        } catch { report["status"] = "failed"; report["error"] = error.localizedDescription }
    }

    static func previewReset(_ camera: CaptureController) async {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("CaptureResetDiagnostics-" + UUID().uuidString)
        var report: [String: Any] = [:]
        let oldCallback = camera.onSegment, oldEffects = camera.videoEffects
        var files: [URL] = []
        camera.onSegment = { file, saved in files.append(file); saved(true) }
        defer {
            camera.onSegment = oldCallback; camera.setVideoEffects(oldEffects)
            report["warning"] = camera.warning ?? ""; report["cameraError"] = camera.error ?? ""
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: root.appendingPathComponent("report.json")) }
            try? root.lastPathComponent.write(to: root.deletingLastPathComponent().appendingPathComponent("capture-reset-latest.txt"), atomically: true, encoding: .utf8)
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            camera.prepare(); try await wait { camera.ready }
            try await Task.sleep(for: .seconds(1))
            report["before"] = await camera.probeSnapshot()
            camera.warning = nil; camera.error = nil
            await camera.probeMediaServicesReset()
            try await Task.sleep(for: .seconds(3))
            try await wait { camera.ready }
            report["after"] = await camera.probeSnapshot()
            try camera.probeScreen(to: root.appendingPathComponent("recovered-screen.png"))
            _ = try await camera.probeLivePreview(to: root.appendingPathComponent("recovered-frame.png"))
            guard camera.warning == nil, camera.error == nil else { throw NSError(domain: "CaptureResetQA", code: 1, userInfo: [NSLocalizedDescriptionKey: "A recovered idle camera must not retain a failure warning."]) }
            for _ in 0..<2 {
                await camera.probeMediaServicesReset()
                try await Task.sleep(for: .seconds(0.5)); try await wait { camera.ready }
                guard camera.warning == nil, camera.error == nil else { throw ProjectError.invalidMedia }
            }
            report["repeatedRecovery"] = true

            await camera.probeDropFrames(true); await camera.probeMediaServicesReset()
            try await Task.sleep(for: .seconds(5))
            guard !camera.ready, camera.warning == "The camera could not restart. Leave the camera screen and open it again." else { throw NSError(domain: "CaptureResetQA", code: 2, userInfo: [NSLocalizedDescriptionKey: "A running session without fresh frames must remain unavailable and warn."]) }
            report["stalled"] = await camera.probeSnapshot()
            await camera.probeDropFrames(false)
            camera.suspend(); camera.prepare()
            try await Task.sleep(for: .seconds(0.5)); try await wait { camera.ready }
            guard camera.warning == nil else { throw ProjectError.invalidMedia }
            report["retryAfterStall"] = true

            camera.warning = "Diagnostic microphone warning"
            await camera.probeMediaServicesReset()
            try await Task.sleep(for: .seconds(0.5)); try await wait { camera.ready }
            guard camera.warning == "Diagnostic microphone warning" else { throw ProjectError.invalidMedia }
            camera.warning = nil; report["unrelatedWarningPreserved"] = true

            await camera.probeMediaServicesReset(); camera.suspend()
            try await Task.sleep(for: .seconds(3))
            guard !camera.ready else { throw ProjectError.invalidMedia }
            report["suspended"] = await camera.probeSnapshot()
            camera.prepare(); try await wait { camera.ready }

            // Keep real screen evidence visible through Metal on phones whose
            // native camera layer is omitted by app-generated screenshots.
            camera.setVideoEffects([VideoEffectSettings(.silentTint)])
            camera.start(in: root); try await wait { camera.state == .recording }
            try await Task.sleep(for: .seconds(1.3))
            try camera.probeScreen(to: root.appendingPathComponent("recording-screen.png"))
            _ = try await camera.probeLivePreview(to: root.appendingPathComponent("recording-frame.png"))
            await camera.probeMediaServicesReset()
            try await wait { camera.state == .paused && files.count == 1 && camera.ready }
            guard camera.warning?.contains("Recording paused") == true else { throw NSError(domain: "CaptureResetQA", code: 3, userInfo: [NSLocalizedDescriptionKey: "A reset during recording must still warn about the interruption."]) }
            report["recordingWarning"] = camera.warning
            camera.warning = nil
            camera.start(in: root); try await wait { camera.state == .recording }
            try await Task.sleep(for: .seconds(1.5))
            try camera.probeScreen(to: root.appendingPathComponent("resumed-screen.png"))
            report["resumed"] = await camera.probeSnapshot()
            camera.stop(); try await wait { !camera.hasActiveTake && files.count == 2 }
            var media: [[String: Any]] = []
            for file in files {
                let asset = AVURLAsset(url: file)
                let video = try await asset.loadTracks(withMediaType: .video), audio = try await asset.loadTracks(withMediaType: .audio)
                guard let track = video.first, !audio.isEmpty else { throw ProjectError.invalidMedia }
                let size = try await track.load(.naturalSize), duration = try await asset.load(.duration).seconds
                let formats = try await track.load(.formatDescriptions)
                guard duration > 1 else { throw ProjectError.invalidMedia }
                media.append(["file": file.lastPathComponent, "duration": duration, "width": size.width, "height": size.height,
                              "hdr": formats.contains { VideoColor.isHDR($0) }, "log": formats.compactMap { LogColor.profile($0)?.rawValue }.first ?? "none"])
            }
            report["media"] = media
            report["status"] = "passed"
        } catch {
            report["status"] = "failed"; report["error"] = error.localizedDescription
            await camera.probeDropFrames(false); camera.stop(); try? await wait { !camera.hasActiveTake }
        }
    }
    static func color(_ camera: CaptureController) async {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ColorDiagnostics", isDirectory: true)
        var report: [String: Any] = [:], files: [URL] = []
        let old = camera.onSegment, oldHDR = camera.hdrEnabled
        camera.onSegment = { url, completion in files.append(url); completion(true) }
        defer {
            camera.suspend(); camera.setHDR(oldHDR); camera.onSegment = old
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: root.appendingPathComponent("report.json"), options: .atomic) }
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            camera.prepare(); try await wait { camera.ready }
            camera.setHDR(false); try await wait { !camera.hdrActive }
            try await Task.sleep(for: .seconds(1))
            camera.start(in: root); try await wait { camera.state == .recording }
            try await Task.sleep(for: .seconds(2))
            camera.setHDR(true)
            try await Task.sleep(for: .seconds(0.3))
            guard !camera.hdrActive, files.isEmpty else { throw ProjectError.invalidMedia }
            camera.stop(pause: true); try await wait { camera.state == .paused && files.count == 1 }
            camera.setHDR(true); try await wait { camera.hdrActive }
            camera.start(in: root); try await wait { camera.state == .recording }
            try await Task.sleep(for: .seconds(2))
            if let front = camera.cameras.first(where: \.front) {
                camera.switchCamera(front.id); try await wait { camera.cameraID == front.id && !camera.switchingCamera }
                try await Task.sleep(for: .seconds(2))
            }
            camera.stop(pause: true); try await wait { camera.state == .paused && files.count == 2 }
            camera.setHDR(false); try await wait { !camera.hdrActive }
            camera.start(in: root); try await wait { camera.state == .recording }
            try await Task.sleep(for: .seconds(2))
            camera.stop(); try await wait { camera.state == .idle && files.count == 3 }
            var metadata: [[String: Any]] = []
            for (index, file) in files.enumerated() {
                let asset = AVURLAsset(url: file)
                let track = try await asset.loadTracks(withMediaType: .video).first!
                let formats = try await track.load(.formatDescriptions)
                let hdr = formats.contains { VideoColor.isHDR($0) }
                guard hdr == (index == 1) else { throw ProjectError.invalidMedia }
                metadata.append(["file": file.lastPathComponent, "hdr": hdr, "duration": try await asset.load(.duration).seconds])
            }
            var project = Project(title: "HDR processing QA")
            project.append(SourceMedia(filename: files[1].lastPathComponent, duration: try await AVURLAsset(url: files[1]).load(.duration).seconds))
            var state = project.edit; state.clips[0].texts = [TextOverlay(text: "HDR test", end: 1)]; project.commit(state)
            let destination = root.appendingPathComponent(UUID().uuidString + ".mp4")
            _ = try await MediaRenderer.render(project: project, folder: root, destination: destination) { _ in }
            let exportedTrack = try await AVURLAsset(url: destination).loadTracks(withMediaType: .video).first!
            guard try await exportedTrack.load(.formatDescriptions).contains(where: { VideoColor.isHDR($0) }) else { throw ProjectError.invalidMedia }
            report = ["success": true, "captures": metadata, "export": destination.lastPathComponent, "exportHDR": true, "pausedModeSwitch": true, "activeModeSwitchPrevented": true]
        } catch { report = ["success": false, "error": error.localizedDescription, "files": files.map(\.lastPathComponent), "cameraError": camera.error ?? "", "warning": camera.warning ?? ""] }
    }

    // Physical Center Stage sensor check: hold the phone upright. All recordings
    // live outside Projects; no existing recording or edit is changed.
    static func frontLandscape(_ camera: CaptureController) async {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FrontLandscapeDiagnostics-" + UUID().uuidString, isDirectory: true)
        let oldQuality = camera.quality, oldHDR = camera.hdrEnabled, oldEffects = camera.videoEffects
        let oldMirrorPreview = camera.mirrorPreview, oldMirrorRecording = camera.mirrorRecording
        let testEffects = CommandLine.arguments.contains("--front-landscape-effects")
        let testSwitches = CommandLine.arguments.contains("--front-landscape-switches")
        let saved = UserDefaults.standard.dictionaryRepresentation().filter { $0.key.hasPrefix("camera.") || ["lastFrontCamera", "lastRearCamera"].contains($0.key) }
        let oldCallback = camera.onSegment
        var originalCamera = "", files: [URL] = [], rows: [[String: Any]] = []
        var report: [String: Any] = ["status": "running"]
        func save() {
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: root.appendingPathComponent("report.json"), options: .atomic)
            }
        }
        func check(_ value: Bool, _ message: String) throws {
            if !value { throw NSError(domain: "FrontLandscapeDiagnostics", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        camera.onSegment = { url, completion in files.append(url); completion(true) }
        defer {
            camera.suspend(); camera.setFrontLandscape(false)
            camera.setQuality(oldQuality); camera.setHDR(oldHDR); camera.setVideoEffects(oldEffects)
            camera.mirrorPreview = oldMirrorPreview; camera.mirrorRecording = oldMirrorRecording
            camera.probeRestoreSettings(saved, cameraID: originalCamera)
            camera.onSegment = oldCallback
            report["captures"] = rows; report["files"] = files.map(\.lastPathComponent); save()
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try root.lastPathComponent.write(to: root.deletingLastPathComponent().appendingPathComponent("front-landscape-latest.txt"), atomically: true, encoding: .utf8)
            save()
            camera.prepare(); try await wait { camera.ready }
            originalCamera = camera.cameraID
            camera.setVideoEffects([])
            let frontIDs = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInUltraWideCamera], mediaType: .video, position: .front).devices.map(\.uniqueID)
            guard let front = camera.cameras.first(where: { frontIDs.contains($0.id) && $0.available }) else {
                throw NSError(domain: "FrontLandscapeDiagnostics", code: 2, userInfo: [NSLocalizedDescriptionKey: "This device has no Center Stage front camera."])
            }
            camera.switchCamera(front.id)
            try await wait { camera.cameraID == front.id && !camera.switchingCamera && camera.frontLandscapeSupported }
            try await Task.sleep(for: .seconds(1))
            report["normalFront"] = await camera.probeSnapshot()
            report["normalPreviewLayout"] = camera.probePreviewLayout()
            _ = try await camera.probeLivePreview(to: root.appendingPathComponent("normal-front.png"))
            for quality in [CaptureQuality.hd1080, .ultraHD4K] {
                for hdr in [false, true] {
                    let label = quality.rawValue + (hdr ? "-hdr" : "-sdr")
                    report["stage"] = label; save()
                    camera.setQuality(quality)
                    try await wait { camera.quality == quality && !camera.frontLandscape }
                    camera.setHDR(hdr)
                    try await wait { camera.hdrActive == hdr }
                    if testEffects {
                        camera.setVideoEffects([VideoEffectSettings(.silentTint)])
                        camera.mirrorPreview = !hdr; camera.mirrorRecording = hdr
                    }
                    try await Task.sleep(for: .milliseconds(500))
                    let expectedCaptureAngle = camera.rotationAngle, expectedPreviewAngle = camera.previewRotationAngle
                    camera.switchCamera(front.id, landscape: true)
                    try await wait { camera.frontLandscape && !camera.switchingCamera }
                    try await Task.sleep(for: .seconds(1))
                    var row = await camera.probeSnapshot()
                    row["label"] = label; row["previewRotation"] = Double(camera.previewRotationAngle)
                    row["previewLayout"] = camera.probePreviewLayout()
                    row["expectedCaptureRotation"] = Double(expectedCaptureAngle)
                    row["expectedPreviewRotation"] = Double(expectedPreviewAngle)
                    row["idleScreenAwake"] = UIApplication.shared.isIdleTimerDisabled
                    row["mirrorPreview"] = camera.mirrorPreview; row["mirrorRecording"] = camera.mirrorRecording
                    row["effect"] = testEffects ? "silentTint" : "none"
                    try check(UIApplication.shared.isIdleTimerDisabled, "Idle camera screen can sleep")
                    try check(abs(camera.rotationAngle - expectedCaptureAngle) < 0.001 &&
                              abs(camera.previewRotationAngle - expectedPreviewAngle) < 0.001 &&
                              abs((row["connectionRotation"] as? Double ?? -999) - Double(expectedCaptureAngle)) < 0.001,
                              "Landscape framing rotated the scene away from the camera's upright orientation")
                    let preview = try await camera.probeLivePreview(to: root.appendingPathComponent(label + "-preview.png"))
                    try camera.probeScreen(to: root.appendingPathComponent(label + "-screen.png"))
                    row["previewWidth"] = preview.width; row["previewHeight"] = preview.height
                    report["currentFrame"] = row; save()
                    try check(preview.width > preview.height, "Preview is not wide")
                    let count = files.count
                    camera.start(in: root); try await wait { camera.state == .recording }
                    try await Task.sleep(for: .seconds(2))
                    try camera.probeScreen(to: root.appendingPathComponent(label + "-recording-screen.png"))
                    // A framing change must not disrupt an active take.
                    camera.setFrontLandscape(false)
                    try await Task.sleep(for: .milliseconds(200))
                    try check(camera.frontLandscape, "Framing changed during recording")
                    if testSwitches {
                        var switches: [[String: Any]] = []
                        let targets = camera.cameras.filter { $0.available && $0.id != front.id }.map { ($0, false) }
                            + [(front, true), (front, false), (front, true)]
                        for (choice, landscape) in targets {
                            report["stage"] = label + " switch to " + choice.name; save()
                            camera.switchCamera(choice.id, landscape: landscape)
                            try await wait { camera.cameraID == choice.id && camera.frontLandscape == landscape && !camera.switchingCamera }
                            try await Task.sleep(for: .seconds(1))
                            var result = await camera.probeSnapshot()
                            result["name"] = choice.name; result["state"] = camera.state.rawValue
                            result["preview"] = camera.probePreviewLayout()
                            result["cover"] = camera.probePreviewSnapshot()
                            switches.append(result); report["switches"] = switches; save()
                            try camera.probeScreen(to: root.appendingPathComponent(label + "-switch-\(switches.count).png"))
                            try check(camera.state == .recording, "Switching cameras stopped the recording")
                            try check(camera.showsWidePreview && (result["cover"] as? [String: Any])?["frozenVisible"] as? Bool == false,
                                      "Camera switch left the preview frozen or lost the recording canvas")
                            try check(camera.warning?.contains("did not resume") != true, "Preview did not resume")
                        }
                        row["switches"] = switches
                    }
                    let checkPause = testSwitches && quality == .hd1080 && !hdr
                    if checkPause && !testEffects {
                        report["stage"] = "Injected display-copy failure during switch"; save()
                        camera.warning = nil
                        let fallbackCount = camera.probePreviewSnapshot()["fallbacks"] as? Int ?? 0
                        camera.probeFailPlainPreview()
                        camera.switchCamera(front.id, landscape: false)
                        try await wait { !camera.frontLandscape && !camera.switchingCamera }
                        try check(camera.state == .recording && camera.probePreviewSnapshot()["frozenVisible"] as? Bool == false,
                                  "Display-copy failure left the recording preview covered")
                        try check(camera.warning?.contains("did not resume") != true, "Native preview fallback failed")
                        try check((camera.probePreviewSnapshot()["fallbacks"] as? Int ?? 0) > fallbackCount,
                                  "Injected failure did not exercise native fallback")
                        try check(camera.probePreviewLayout()["effectsHidden"] as? Bool == true, "Fault injection ended before fallback was checked")
                        report["previewFailureFallback"] = camera.probePreviewSnapshot(); save()
                        try await Task.sleep(for: .seconds(3.5))
                        try check(camera.probePreviewLayout()["effectsHidden"] as? Bool == false, "Metal preview did not recover")
                        camera.warning = nil
                        let onceCount = camera.probePreviewSnapshot()["fallbacks"] as? Int ?? 0
                        camera.probeFailNextSwitchPreview()
                        camera.switchCamera(front.id, landscape: true)
                        try await wait { camera.frontLandscape && !camera.switchingCamera }
                        let once = camera.probePreviewSnapshot()
                        try check((once["fallbacks"] as? Int ?? 0) > onceCount && once["nativeEnabled"] as? Bool == true,
                                  "One-frame failure stranded the native preview connection")
                        report["singleFrameFailureFallback"] = once; save()
                        camera.warning = nil
                    }
                    camera.stop(pause: checkPause); try await wait { !camera.hasActiveTake && files.count == count + 1 }
                    row["finishedCapture"] = await camera.probeSnapshot()
                    try check(UIApplication.shared.isIdleTimerDisabled, "Camera can sleep after Stop")
                    let asset = AVURLAsset(url: files.last!)
                    guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw ProjectError.invalidMedia }
                    let size = try await video.load(.naturalSize), transform = try await video.load(.preferredTransform)
                    let expectedWidth: CGFloat = quality == .hd1080 ? 1920 : 3840
                    row["file"] = files.last!.lastPathComponent
                    row["width"] = size.width; row["height"] = size.height
                    row["identityTransform"] = transform.isIdentity
                    let actualHDR = try await video.load(.formatDescriptions).contains { VideoColor.isHDR($0) }
                    row["hdr"] = actualHDR
                    rows.append(row); report["captures"] = rows; save()
                    try check(size.width == expectedWidth && abs(size.width / size.height - 16 / 9.0) < 0.01,
                              "Recording did not preserve the requested landscape resolution")
                    try check(transform.isIdentity && actualHDR == hdr, "Unexpected saved rotation or dynamic range")
                    let generator = AVAssetImageGenerator(asset: asset); generator.appliesPreferredTrackTransform = true
                    let frame = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
                    try UIImage(cgImage: frame).pngData()?.write(to: root.appendingPathComponent(label + "-recording.png"))
                    if testSwitches {
                        let duration = try await asset.load(.duration).seconds
                        let last = try await generator.image(at: CMTime(seconds: max(0, duration - 0.5), preferredTimescale: 600)).image
                        try UIImage(cgImage: last).pngData()?.write(to: root.appendingPathComponent(label + "-after-switch-recording.png"))
                        if checkPause, let main = camera.cameras.first(where: { $0.front && $0.id != front.id }) {
                            camera.switchCamera(main.id)
                            try await wait { camera.cameraID == main.id && !camera.switchingCamera }
                            camera.start(in: root); try await wait { camera.state == .recording }
                            try await Task.sleep(for: .seconds(1))
                            camera.stop(); try await wait { !camera.hasActiveTake && files.count == count + 2 }
                            let resumed = try await AVURLAsset(url: files.last!).loadTracks(withMediaType: .video).first!
                            let resumedSize = try await resumed.load(.naturalSize)
                            try check(resumedSize == size, "Resume changed the original take canvas")
                            report["pauseResumeCanvas"] = true; save()
                        }
                        camera.switchCamera(front.id, landscape: testEffects)
                        try await wait { camera.cameraID == front.id && camera.frontLandscape == testEffects && !camera.switchingCamera }
                    }
                    if testEffects {
                        var bypass = VideoEffectSettings(.silentTint); bypass.enabled = false
                        camera.setVideoEffects([bypass]); try await Task.sleep(for: .milliseconds(500))
                        try camera.probeScreen(to: root.appendingPathComponent(label + "-bypass-screen.png"))
                        camera.setVideoEffects([]); try await Task.sleep(for: .milliseconds(500))
                        try camera.probeScreen(to: root.appendingPathComponent(label + "-cleared-screen.png"))
                        try check((camera.probePreviewLayout()["effectsHidden"] as? Bool) == false,
                                  "Clearing effects hid the full-frame preview")
                    }
                    camera.setFrontLandscape(false)
                    try await wait { !camera.frontLandscape && !camera.switchingCamera }
                    try await Task.sleep(for: .milliseconds(500))
                    let normal = try await camera.probeLivePreview(to: root.appendingPathComponent(label + "-normal.png"))
                    try check(normal.height > normal.width, "Normal portrait framing was not restored (phone must stay upright)")
                }
            }
            if testSwitches {
                report["stage"] = "Portrait take to landscape and failed-save recovery"; save()
                camera.setVideoEffects([]); camera.setQuality(.hd1080); camera.setHDR(false)
                try await wait { camera.quality == .hd1080 && !camera.hdrActive && !camera.frontLandscape }
                camera.switchCamera(front.id, landscape: false)
                try await wait { camera.cameraID == front.id && !camera.switchingCamera }
                let count = files.count
                camera.start(in: root); try await wait { camera.state == .recording && camera.takeCanvas != nil }
                let portraitCanvas = camera.takeCanvas!
                try check(portraitCanvas.height > portraitCanvas.width, "Test must begin with a portrait canvas")
                camera.switchCamera(front.id, landscape: true)
                try await wait { camera.frontLandscape && !camera.switchingCamera }
                try await Task.sleep(for: .seconds(1))
                let layout = camera.probePreviewLayout(), bounds = layout["effectsBounds"] as? [Double] ?? []
                try check(!camera.showsWidePreview && bounds.count == 4 && bounds[3] > bounds[2], "Portrait take was boxed inside a landscape preview")
                try check(layout["effectsFill"] as? Bool == false, "Portrait canvas is cropped")
                try camera.probeScreen(to: root.appendingPathComponent("portrait-to-landscape-screen.png"))
                report["portraitToLandscape"] = layout; save()
                // A failed project save leaves a resumable take, including its canvas.
                camera.onSegment = { url, completion in files.append(url); completion(false) }
                camera.stop(); try await wait { camera.state == .paused && files.count == count + 1 }
                try check(camera.takeCanvas == portraitCanvas, "Failed save discarded the take canvas")
                camera.onSegment = { url, completion in files.append(url); completion(true) }
                camera.start(in: root); try await wait { camera.state == .recording }
                try await Task.sleep(for: .seconds(1))
                camera.stop(); try await wait { camera.state == .idle && files.count == count + 2 }
                for file in files.suffix(2) {
                    let track = try await AVURLAsset(url: file).loadTracks(withMediaType: .video).first!
                    let size = try await track.load(.naturalSize)
                    try check(size == portraitCanvas, "Portrait take canvas changed across switch or failed-save resume")
                }
                report["failedSaveResumeCanvas"] = true
                camera.setFrontLandscape(false); try await wait { !camera.frontLandscape && !camera.switchingCamera }
            }
            report["status"] = "passed"
        } catch {
            report["status"] = "failed"; report["error"] = error.localizedDescription
            report["snapshotAtFailure"] = await camera.probeSnapshot()
            report["previewAtFailure"] = camera.probePreviewLayout()
            report["cameraError"] = camera.error ?? ""; report["cameraWarning"] = camera.warning ?? ""
            camera.stop(); try? await wait { !camera.hasActiveTake }
        }
    }

    static func reviewLifecycle(_ camera: CaptureController) async {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let root = documents.appendingPathComponent("CaptureReviewDiagnostics-" + UUID().uuidString, isDirectory: true)
        let original = camera.onSegment
        let backup = documents.appendingPathComponent("CaptureReviewPreferences.plist")
        let stored = (try? Data(contentsOf: backup)).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        let saved = (stored ?? UserDefaults.standard.dictionaryRepresentation()).filter { $0.key.hasPrefix("camera.") || ["lastFrontCamera", "lastRearCamera"].contains($0.key) }
        var cameraID = ""
        var finish: ((Bool) -> Void)?, file: URL?
        var report: [String: Any] = ["status": "running"]
        camera.onSegment = { url, completion in file = url; finish = completion }
        defer {
            finish?(false); camera.suspend(); camera.finishPausedTake()
            if !cameraID.isEmpty { camera.probeRestoreSettings(saved, cameraID: cameraID) }
            camera.onSegment = original
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: root.appendingPathComponent("report.json"), options: .atomic)
            }
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try root.lastPathComponent.write(to: documents.appendingPathComponent("capture-review-latest.txt"), atomically: true, encoding: .utf8)
            camera.prepare(); try await wait { camera.ready }
            cameraID = camera.cameraID
            camera.start(in: root); try await wait { camera.state == .recording }
            try await Task.sleep(for: .seconds(2.5))
            camera.stop()
            let background = CommandLine.arguments.contains("--capture-review-background")
            if background { camera.suspend() }
            NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
                userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
            try await wait { finish != nil && camera.state == .saving }
            NotificationCenter.default.post(name: AVCaptureSession.wasInterruptedNotification, object: camera.session)
            try await wait { !camera.ready }
            let completion = finish; finish = nil; completion?(true)
            try await wait { camera.state == .idle }
            guard let file else { throw ProjectError.invalidMedia }
            let asset = AVURLAsset(url: file), duration = try await asset.load(.duration).seconds
            guard duration > 2, !(try await asset.loadTracks(withMediaType: .video)).isEmpty else { throw ProjectError.invalidMedia }
            report = ["status": "passed", "stopAfterInterruption": "idle", "backgroundAfterStop": background, "savedDuration": duration, "file": file.lastPathComponent]
        } catch { report = ["status": "failed", "error": error.localizedDescription, "cameraError": camera.error ?? ""] }
    }

    static func run(_ camera: CaptureController) async {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CaptureDiagnostics-" + UUID().uuidString, isDirectory: true)
        let originalQuality = camera.quality
        let saved = UserDefaults.standard.dictionaryRepresentation().filter { $0.key.hasPrefix("camera.") || ["lastFrontCamera", "lastRearCamera"].contains($0.key) }
        var report: [String: Any] = ["started": Date().description]
        var files: [String] = []
        var originalCamera = ""
        let oldCallback = camera.onSegment
        camera.onSegment = { url, completion in files.append(url.lastPathComponent); completion(true) }
        defer {
            camera.suspend()
            camera.finishPausedTake(); camera.setQuality(originalQuality)
            camera.probeRestoreSettings(saved, cameraID: originalCamera)
            camera.onSegment = oldCallback
            report["files"] = files
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: root.appendingPathComponent("report.json"), options: .atomic)
                try? root.lastPathComponent.write(to: root.deletingLastPathComponent().appendingPathComponent("capture-diagnostics-latest.txt"), atomically: true, encoding: .utf8)
            }
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            camera.prepare()
            try await wait { camera.ready }
            originalCamera = camera.cameraID
            camera.setQuality(.hd1080)
            try await wait { camera.quality == .hd1080 }
            report["cameras"] = camera.cameras.map { ["id": $0.id, "name": $0.name] }
            try await Task.sleep(for: .seconds(1))
            report["idle"] = await camera.probeSnapshot()
            var recordings: [[String: Any]] = []
            var previews: [[String: Any]] = []
            var zooms: [String: Double] = [:]
            for (index, choice) in camera.cameras.enumerated() {
                report["stage"] = "select \(choice.name)"
                let previousCamera = camera.cameraID
                let beforePreview = camera.probePreviewSnapshot()
                camera.switchCamera(choice.id)
                try await wait { camera.cameraID == choice.id && camera.ready && !camera.switchingCamera }
                let preview = camera.probePreviewSnapshot(imageURL: root.appendingPathComponent("frozen-\(index).png"))
                if previousCamera != choice.id {
                    guard (preview["freezes"] as? Int ?? 0) > (beforePreview["freezes"] as? Int ?? 0),
                          (preview["resumes"] as? Int ?? 0) > (beforePreview["resumes"] as? Int ?? 0),
                          preview["frozenVisible"] as? Bool == false, preview["previewing"] as? Bool == true else {
                        throw NSError(domain: "CaptureDiagnostics", code: 4, userInfo: [NSLocalizedDescriptionKey: "Frozen preview did not cover and release the camera switch: \(preview)"])
                    }
                }
                previews.append(preview); report["previews"] = previews
                let zoom = min(camera.maxZoom, max(camera.minZoom, 1.2 + Double(index) * 0.2))
                zooms[choice.id] = zoom
                camera.setZoom(zoom, seconds: 0)
                camera.setFocus(locked: camera.focusLockSupported, position: camera.focusAdjustable ? Float(0.2 + Double(index) * 0.15) : nil)
                try await Task.sleep(for: .seconds(0.5))
                report["stage"] = "start \(choice.name)"
                camera.start(in: root)
                try await wait { camera.state == .recording }
                try await Task.sleep(for: .seconds(2))
                let snapshot = await camera.probeSnapshot()
                guard snapshot["movieRecording"] as? Bool == true else {
                    throw NSError(domain: "CaptureDiagnostics", code: 2, userInfo: [NSLocalizedDescriptionKey: "Recording stopped unexpectedly on \(choice.name)."])
                }
                camera.addBookmark()
                try await Task.sleep(for: .milliseconds(350))
                recordings.append(snapshot)
                report["recordings"] = recordings
                report["stage"] = "stop \(choice.name)"
                camera.stop()
                try await wait { !camera.hasActiveTake }
            }
            report["recordings"] = recordings
            var bookmarkCount = 0
            for file in files {
                let media = root.appendingPathComponent(file)
                let duration = try await AVURLAsset(url: media).load(.duration).seconds
                let events = try JSONDecoder().decode([CaptureEvent].self, from: Data(contentsOf: media.deletingPathExtension().appendingPathExtension("events.json")))
                let marks = events.filter { $0.kind == "bookmark" }
                guard marks.count == 1, marks[0].time > 1, marks[0].time < duration else { throw ProjectError.invalidDocument }
                bookmarkCount += marks.count
            }
            report["recordingBookmarks"] = bookmarkCount
            if let rear = camera.cameras.first(where: { !$0.front }), let front = camera.cameras.first(where: \.front) {
                camera.switchCamera(rear.id)
                try await wait { camera.cameraID == rear.id && !camera.switchingCamera }
                let restored = await camera.probeSnapshot()
                guard abs((restored["zoom"] as? Double ?? 0) - (zooms[rear.id] ?? 0)) < 0.001 else { throw ProjectError.invalidDocument }
                report["restoredRear"] = restored
                camera.start(in: root)
                try await wait { camera.state == .recording }
                try await Task.sleep(for: .seconds(2))
                let countBefore = files.count
                report["stage"] = "live swap"
                camera.probeSwapWithoutStopping(front.id)
                try await Task.sleep(for: .seconds(2))
                let swapped = await camera.probeSnapshot()
                guard swapped["movieRecording"] as? Bool == true,
                      abs((swapped["zoom"] as? Double ?? 0) - (zooms[front.id] ?? 0)) < 0.001 else { throw ProjectError.invalidDocument }
                report["liveSwap"] = swapped
                report["filesFinalizedDuringSwap"] = files.count - countBefore
                camera.stop()
                try await wait { !camera.hasActiveTake }
            }
            if let rear = camera.cameras.first(where: { !$0.front }), let front = camera.cameras.first(where: \.front) {
                camera.switchCamera(rear.id)
                try await wait { camera.cameraID == rear.id && !camera.switchingCamera }
                report["stage"] = "rejected switch, pause, resume"
                camera.start(in: root); try await wait { camera.state == .recording }
                let before = await camera.probeSnapshot()
                camera.probeRejectNextSwitch(); camera.switchCamera(front.id)
                try await Task.sleep(for: .milliseconds(500))
                let rejected = await camera.probeSnapshot()
                guard rejected["camera"] as? String == rear.id,
                      rejected["rotation"] as? Double == before["rotation"] as? Double else { throw ProjectError.invalidDocument }
                report["rejectedSwitch"] = rejected
                camera.stop(pause: true); try await wait { camera.state == .paused }
                camera.start(in: root); try await wait { camera.state == .recording }
                let resumed = await camera.probeSnapshot()
                guard resumed["rotation"] as? Double == before["rotation"] as? Double else { throw ProjectError.invalidDocument }
                report["resumedAfterRejectedSwitch"] = resumed
                camera.switchCamera(front.id)
                try await Task.sleep(for: .milliseconds(100)); camera.stop()
                try await wait { !camera.hasActiveTake && !camera.switchingCamera }
                report["rapidSwitchStop"] = await camera.probeSnapshot()
                // Immediately reopen the writer, exercising hold release and empty Stop.
                report["stage"] = "rapid record stop"
                for delay in [0, 10, 50, 150] {
                    camera.start(in: root)
                    try await Task.sleep(for: .milliseconds(delay)); camera.stop()
                    try await Task.sleep(for: .milliseconds(200))
                    try await wait { !camera.hasActiveTake }
                }
            }
            report["stage"] = "4K all cameras"
            camera.finishPausedTake(); camera.setQuality(.ultraHD4K)
            try await wait { camera.quality == .ultraHD4K }
            var highResolution: [[String: Any]] = []
            for choice in camera.cameras where choice.available {
                camera.switchCamera(choice.id)
                try await wait { camera.cameraID == choice.id && !camera.switchingCamera }
                camera.start(in: root); try await wait { camera.state == .recording }
                try await Task.sleep(for: .seconds(1))
                let snapshot = await camera.probeSnapshot()
                guard snapshot["movieRecording"] as? Bool == true,
                      max(snapshot["width"] as? Int ?? 0, snapshot["height"] as? Int ?? 0) >= 3840 else { throw ProjectError.invalidMedia }
                highResolution.append(snapshot)
                camera.stop(); try await wait { !camera.hasActiveTake }
            }
            report["4K"] = highResolution
            var media: [[String: Any]] = []
            for file in files {
                let asset = AVURLAsset(url: root.appendingPathComponent(file))
                let video = try await asset.loadTracks(withMediaType: .video)
                let audio = try await asset.loadTracks(withMediaType: .audio)
                guard !video.isEmpty, !audio.isEmpty else { throw ProjectError.invalidMedia }
                let videoRange = try await video[0].load(.timeRange), audioRange = try await audio[0].load(.timeRange)
                let offset = abs(videoRange.end.seconds - audioRange.end.seconds)
                media.append(["file": file, "videoDuration": videoRange.duration.seconds, "audioDuration": audioRange.duration.seconds, "endDifference": offset])
                guard offset < 1.0 / 30 + 0.002 else { throw NSError(domain: "CaptureDiagnostics", code: 3, userInfo: [NSLocalizedDescriptionKey: "Audio/video endpoints differ by \(offset) seconds."]) }
            }
            report["media"] = media
            report["stage"] = "capture playback session round trip"
            camera.suspend(forPlayback: true)
            try await wait { !camera.ready }
            _ = await camera.probeSnapshot()
            guard AVAudioSession.sharedInstance().category == .playback,
                  AVAudioSession.sharedInstance().mode == .moviePlayback else { throw ProjectError.invalidMedia }
            camera.suspend(forPlayback: true)
            _ = await camera.probeSnapshot()
            guard AVAudioSession.sharedInstance().category == .playback else { throw ProjectError.invalidMedia }
            camera.prepare(); try await wait { camera.ready }
            guard AVAudioSession.sharedInstance().category == .playAndRecord else { throw ProjectError.invalidMedia }
            report["playbackSessionRoundTrip"] = true
            report["status"] = "completed"
        } catch {
            report["status"] = "failed"; report["error"] = error.localizedDescription
            report["captureState"] = camera.state.rawValue
            report["captureError"] = camera.error ?? ""
            report["captureWarning"] = camera.warning ?? ""
            report["snapshotAtFailure"] = await camera.probeSnapshot()
            camera.stop(); try? await wait { !camera.hasActiveTake }
        }
    }
    static func stress(_ camera: CaptureController) async {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CaptureStress-" + UUID().uuidString, isDirectory: true)
        var report: [String: Any] = ["started": Date().description, "status": "running"]
        var checkpoints: [[String: Any]] = []
        var files: [String] = []
        let oldCallback = camera.onSegment
        camera.onSegment = { url, completion in files.append(url.lastPathComponent); completion(true) }
        func save() {
            report["files"] = files; report["checkpoints"] = checkpoints
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: root.appendingPathComponent("report.json"), options: .atomic)
            }
        }
        defer { camera.onSegment = oldCallback; camera.suspend(); save() }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try root.lastPathComponent.write(to: root.deletingLastPathComponent().appendingPathComponent("capture-stress-latest.txt"), atomically: true, encoding: .utf8)
            let available = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
            guard available > 8_000_000_000 else { throw NSError(domain: "CaptureStress", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not enough free space for the hour-long probe."]) }
            camera.prepare(); try await wait { camera.ready }
            camera.start(in: root); try await wait { camera.state == .recording }
            let start = ProcessInfo.processInfo.systemUptime
            for minute in 1...60 {
                let due = start + Double(minute * 60)
                while ProcessInfo.processInfo.systemUptime < due {
                    try await Task.sleep(for: .seconds(5))
                    guard camera.state == .recording else { throw NSError(domain: "CaptureStress", code: 2, userInfo: [NSLocalizedDescriptionKey: camera.warning ?? camera.error ?? "Recording left the active state."]) }
                }
                var checkpoint = await camera.probeSnapshot()
                checkpoint["elapsed"] = ProcessInfo.processInfo.systemUptime - start
                checkpoint["thermalState"] = ProcessInfo.processInfo.thermalState.rawValue
                checkpoint["freeBytes"] = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
                checkpoints.append(checkpoint); save()
                if minute.isMultiple(of: 2), minute < 60, !camera.cameras.isEmpty {
                    camera.switchCamera(camera.cameras[(minute / 2) % camera.cameras.count].id)
                }
            }
            camera.stop(); try await wait { !camera.hasActiveTake }
            var media: [[String: Any]] = []
            for file in files {
                let asset = AVURLAsset(url: root.appendingPathComponent(file))
                let duration = try await asset.load(.duration).seconds
                let video = try await asset.loadTracks(withMediaType: .video)
                let audio = try await asset.loadTracks(withMediaType: .audio)
                guard !video.isEmpty, !audio.isEmpty else { throw ProjectError.invalidMedia }
                media.append(["file": file, "duration": duration, "videoDuration": try await video[0].load(.timeRange).duration.seconds,
                              "audioDuration": try await audio[0].load(.timeRange).duration.seconds])
            }
            report["media"] = media; report["status"] = "completed"
        } catch {
            report["status"] = "failed"; report["error"] = error.localizedDescription
            camera.stop(); try? await wait { !camera.hasActiveTake }
        }
    }
    private static func wait(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !condition() {
            guard Date() < deadline else { throw NSError(domain: "CaptureDiagnostics", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for capture state."]) }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}

@MainActor
enum EditorDiagnostics {
    static func importLongStabilizationFixture(_ fallback: URL, documents: URL, store: ProjectStore) async throws {
        let supplied = documents.appendingPathComponent("StabilizationTest/shake.mp4")
        if FileManager.default.fileExists(atPath: supplied.path) { await store.importVideo(supplied); return }
        // Keep the UI regression runnable with the bundled fixture alone. A
        // single long source exercises the case that many short timeline items miss.
        let asset = AVURLAsset(url: fallback), duration = try await asset.load(.duration)
        guard duration.seconds > 0 else { throw ProjectError.invalidMedia }
        let target = CMTime(seconds: 1200, preferredTimescale: 600)
        let composition = AVMutableComposition()
        var cursor = CMTime.zero
        while cursor < target {
            let length = CMTimeMinimum(target - cursor, duration)
            try await composition.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: asset, at: cursor)
            cursor = cursor + length
        }
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else { throw ProjectError.invalidMedia }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        defer { try? FileManager.default.removeItem(at: url) }
        export.outputURL = url; export.outputFileType = .mov
        await export.export()
        guard export.status == .completed else { throw export.error ?? ProjectError.invalidMedia }
        await store.importVideo(url)
    }

    static func appendLandscapeFixture(to project: Project, store: ProjectStore) async throws {
        guard let first = project.sources.first else { throw ProjectError.missingMedia }
        let asset = AVURLAsset(url: store.mediaURL(project, first))
        let composition = AVMutableComposition()
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 3, preferredTimescale: 600))
        try await composition.insertTimeRange(range, of: asset, at: .zero)
        guard let track = composition.tracks(withMediaType: .video).first,
              let source = try await asset.loadTracks(withMediaType: .video).first,
              let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else { throw ProjectError.invalidMedia }
        let transform = try await source.load(.preferredTransform)
        track.preferredTransform = transform.concatenating(CGAffineTransform(rotationAngle: .pi / 2))
        let destination = store.folder(project).appendingPathComponent(UUID().uuidString + ".mov")
        export.outputURL = destination; export.outputFileType = .mov
        await export.export()
        guard export.status == .completed, await store.addRecording(destination, to: project.id) else { throw ProjectError.invalidMedia }
    }

    @MainActor static func independentTracks() async {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let root = documents.appendingPathComponent("TrackDiagnostics-" + UUID().uuidString)
        let editor = EditorController()
        defer { editor.stop() }
        var report: [String: Any] = [:]
        func check(_ value: Bool, _ message: String) throws {
            if !value { throw NSError(domain: "TrackDiagnostics", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        do {
            try timelineClipboardChecks()
            try moveBoundaryChecks()
            let stillErrors = try PlacementPreviewDiagnostics.run()
            guard let fixture = Bundle.main.url(forResource: "editor-fixture", withExtension: "mp4") else { throw ProjectError.missingMedia }
            let duration = try await AVURLAsset(url: fixture).load(.duration).seconds
            let disk = ProjectDisk(root: root)
            var project = Project(title: "Independent tracks device QA")
            let source = SourceMedia(filename: "source.mp4", duration: duration)
            project.append(source)
            project.history = [EditState(clips: [TimelineClip(sourceID: source.id, start: 0, end: 8)])]
            try disk.save(project)
            let folder = disk.folder(project.id)
            try FileManager.default.copyItem(at: fixture, to: folder.appendingPathComponent("source.mp4"))
            var state = project.edit
            state.timeline.unlink(state.timeline.entireSelection())
            let sound = TimelineSelection(audio: [state.timeline.audio[0].id])
            state.timeline.move(sound, by: EditTime(1))
            state.timeline.audio[0].volumeDB = -6
            state.timeline.addBookmark(at: EditTime(2), preferredVideo: state.timeline.video[0].id)
            project.commit(state); try disk.save(project)
            project = try disk.read(folder.appendingPathComponent("project.json"))
            try check(project.edit.duration == 9 && project.edit.timeline.resolvedBookmarks.count == 1, "Moved audio tail or bookmark lost after reopen")
            project.undo(); try check(project.edit.duration == 8, "Move Undo failed")
            project.redo(); try check(project.edit == state, "Move Redo failed")
            var other = state.timeline.video[0]
            other.content.id = UUID(); other.occurrenceID = UUID(); other.start = EditTime(8); other.layer = 10
            other.content.color = ColorSettings(look: .mono)
            state.timeline.video.append(other)
            // Exercise the real Move operation, including exact full-cover and
            // partial overlaps, rather than constructing only a final layout.
            let beforeMove = state.timeline
            for offset in [-8.0, -5, -2, 2] {
                var draft = beforeMove
                draft.move(TimelineSelection(video: [other.id]), by: EditTime(offset))
                try draft.validate(sources: [source])
                try check(draft.video.map(\.mapping) == beforeMove.video.map(\.mapping) && draft.audio == beforeMove.audio,
                          "Move consumed source footage or changed detached audio")
                let lanes = timelineLanes(draft)
                for (index, lane) in lanes.enumerated() {
                    try check(lanes.dropFirst(index + 1).allSatisfy { $0.row != lane.row || $0.interval.intersection(lane.interval) == nil },
                              "Overlapping items share a display lane")
                }
            }
            state.timeline.move(TimelineSelection(video: [other.id]), by: EditTime(-5))
            let moved = state.timeline
            project.commit(EditState(timeline: moved)); try disk.save(project)
            project = try disk.read(folder.appendingPathComponent("project.json"))
            try check(project.edit.timeline == moved, "Overlap changed after reopen")
            var removed = moved; removed.remove(TimelineSelection(video: [other.id]))
            try check(removed.video == [moved.video[0]] && removed.audio == moved.audio, "Deleting the overlay damaged the covered picture or sound")
            project.commit(EditState(timeline: removed)); project.undo()
            try check(project.edit.timeline == moved, "Delete Undo failed to restore overlap")
            project.redo(); try check(project.edit.timeline == removed, "Delete Redo changed underlying footage")
            project.undo()
            var a = VideoPlacement(); a.x = 0.25; a.width = 0.5
            var b = VideoPlacement(); b.x = 0.75; b.width = 0.5; b.order = 1
            b.edgeCrop = PlacementEdgeCrop(left: 0.2, right: 0.1, top: 0.15, bottom: 0.25)
            let ids = Set(state.timeline.video.map(\.id))
            state.timeline.placements = [VideoPlacementRegion(participants: ids, videos: [state.timeline.video[0].id: a, other.id: b])]
            state.timeline.enhance([AudioEffect(kind: .gain, amount: -3)], selection: TimelineSelection(audio: sound.audio, range: EditInterval(2...4)))
            project.commit(state); try disk.save(project)
            let prepared = try await SourceMediaCache.shared.prepared(project: project, folder: folder) { _ in }
            await editor.load(project, folder: folder)
            try check(await editor.seekAndWait(4), "Independent overlap preview did not seek")
            editor.togglePlay(); try await Task.sleep(for: .milliseconds(700))
            try check(editor.player.rate > 0 && editor.playhead > 4.1, "Independent overlap preview did not advance")
            editor.pause()
            let output = folder.appendingPathComponent("tracks-export.mp4")
            _ = try await MediaRenderer.render(project: project, folder: folder, destination: output) { _ in }
            let exported = AVURLAsset(url: output), length = try await exported.load(.duration).seconds
            try check(abs(length - 11) < 0.04, "Export did not retain independent picture/audio timing")
            func pixels(_ generator: AVAssetImageGenerator) async throws -> [UInt8] {
                generator.maximumSize = CGSize(width: 320, height: 320)
                generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
                let image = try await generator.image(at: CMTime(seconds: 4, preferredTimescale: 240000)).image
                var bytes = [UInt8](repeating: 0, count: 160 * 90 * 4)
                bytes.withUnsafeMutableBytes { raw in
                    let context = CGContext(data: raw.baseAddress, width: 160, height: 90, bitsPerComponent: 8, bytesPerRow: 640,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
                    context.draw(image, in: CGRect(x: 0, y: 0, width: 160, height: 90))
                }
                return bytes
            }
            let preview = AVAssetImageGenerator(asset: prepared.media.composition); preview.videoComposition = prepared.media.videoComposition
            let reference = try await pixels(preview), rendered = try await pixels(AVAssetImageGenerator(asset: exported))
            let error = zip(reference, rendered).enumerated().filter { $0.offset % 4 != 3 }.reduce(0.0) { $0 + abs(Double($1.element.0) - Double($1.element.1)) } / Double(160 * 90 * 3)
            try check(error < 5, "Placement preview/export pixel difference \(error)")
            withExtendedLifetime(prepared) {}
            let beforeJoin = TrackTimeline(clips: [TimelineClip(sourceID: source.id, start: 0, end: 2),
                TimelineClip(sourceID: source.id, start: 2, end: 5), TimelineClip(sourceID: source.id, start: 5, end: 8)])
            let joined = try beforeJoin.joining(beforeJoin.entireSelection())
            try check(joined.timeline.video == beforeJoin.video && joined.timeline.audio == beforeJoin.audio,
                      "Horizontal/vertical join changed source samples")
            project.commit(EditState(timeline: joined.timeline)); try disk.save(project)
            project = try disk.read(folder.appendingPathComponent("project.json"))
            try check(project.edit.timeline == joined.timeline, "Compound Link changed after reopen")
            await editor.load(project, folder: folder)
            try check(await editor.seekAndWait(4), "Joined playback failed to seek across a seam")
            let joinOutput = folder.appendingPathComponent("joined-export.mp4")
            _ = try await MediaRenderer.render(project: project, folder: folder, destination: joinOutput) { _ in }
            let joinDuration = try await AVURLAsset(url: joinOutput).load(.duration).seconds
            try check(abs(joinDuration - 8) < 0.04, "Joined export changed duration")
            var shifted = beforeJoin; shifted.unlink(shifted.entireSelection())
            shifted.move(TimelineSelection(audio: Set(shifted.audio.map(\.id))), by: EditTime(2))
            let intersection = try shifted.joining(shifted.entireSelection(), intersectionOnly: true)
            try intersection.timeline.validate(sources: [source])
            try check(intersection.timeline.duration == shifted.duration
                && intersection.timeline.interval(for: intersection.selection) == EditInterval(2...8), "Link intersection lost tails")
            project.commit(EditState(timeline: shifted)); project.commit(EditState(timeline: intersection.timeline))
            project.undo(); try check(project.edit.timeline == shifted, "Intersection Undo lost original footage")
            project.redo(); try disk.save(project)
            project = try disk.read(folder.appendingPathComponent("project.json"))
            let intersectionOutput = folder.appendingPathComponent("intersection-export.mp4")
            _ = try await MediaRenderer.render(project: project, folder: folder, destination: intersectionOutput) { _ in }
            let intersectionDuration = try await AVURLAsset(url: intersectionOutput).load(.duration).seconds
            try check(abs(intersectionDuration - 10) < 0.04, "Intersection export lost outside footage")
            report = ["success": true, "clipboardChecks": true, "moveBoundaryChecks": true, "arrangeStillExportErrors": stillErrors, "unlinkMoveVolume": true, "scopedEnhancement": true, "bookmarkReopen": true,
                      "persistentUndoRedo": true, "overlapPlayback": true, "moveOverlapLanes": true, "moveOverlapReopen": true, "overlayDeleteUndoRedo": true, "placementEdgeCrop": true, "placementPreviewExportError": error, "exportDuration": length,
                      "compoundLinkReopen": true, "joinedExportDuration": joinDuration, "intersectionUndoRedo": true, "intersectionExportDuration": intersectionDuration]
        } catch { report = ["success": false, "error": error.localizedDescription] }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: root.appendingPathComponent("report.json"), options: .atomic)
            try? root.lastPathComponent.write(to: documents.appendingPathComponent("tracks-diagnostics-latest.txt"), atomically: true, encoding: .utf8)
        }
    }
    @MainActor static func recordingHistory() async {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("RecordingHistoryTest", isDirectory: true)
        let editor = EditorController()
        defer { editor.stop() }
        var report: [String: Any] = [:]
        func check(_ value: Bool, _ message: String) throws {
            if !value { throw NSError(domain: "RecordingHistoryQA", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard let fixture = Bundle.main.url(forResource: "editor-fixture", withExtension: "mp4") else { throw ProjectError.missingMedia }
            let duration = try await AVURLAsset(url: fixture).load(.duration).seconds
            let disk = ProjectDisk(root: folder.appendingPathComponent("Projects"))
            var project = Project(title: "Recording history QA")
            try disk.save(project)
            for filename in ["first.mp4", "last.mp4"] { try FileManager.default.copyItem(at: fixture, to: disk.folder(project.id).appendingPathComponent(filename)) }
            project.append(SourceMedia(filename: "first.mp4", duration: duration))
            var trimmed = project.edit; trimmed.clips[0].start = 2; project.commit(trimmed)
            project.undo()
            project.append(SourceMedia(filename: "last.mp4", duration: duration))
            try check(project.canRedo && project.history.count == 2, "Capture discarded earlier editing redo")
            project.redo(); try disk.save(project)
            project = try disk.read(disk.folder(project.id).appendingPathComponent("project.json"))
            try check(abs(project.edit.duration - (duration * 2 - 2)) < 0.001, "Reopened trimmed timeline lost its final recording")
            let edited = project.edit
            while project.canUndo { project.undo() }
            try check(project.edit.clips.count == 2 && abs(project.edit.duration - duration * 2) < 0.001, "Undo all removed a recording")
            project.redo(); try check(project.edit == edited, "Redo changed the earlier edit")
            var deleted = project.edit; deleted.clips.removeLast(); project.commit(deleted)
            try check(project.edit.clips.count == 1, "Explicit clip deletion stopped working")
            project.undo(); try check(project.edit == edited, "Undoing deletion failed to restore the recording")
            await editor.load(project, folder: disk.folder(project.id))
            for _ in 0..<100 where editor.player.currentItem?.status != .readyToPlay { try await Task.sleep(for: .milliseconds(100)) }
            try check(editor.error == nil && editor.player.currentItem?.status == .readyToPlay, editor.error ?? "Preview did not load")
            try check(abs((editor.player.currentItem?.duration.seconds ?? 0) - edited.duration) < 0.05, "Preview omitted the final recording")
            editor.seek(edited.duration - 2); editor.togglePlay()
            try await Task.sleep(for: .seconds(1))
            try check(editor.player.rate > 0 && editor.playhead > edited.duration - 1.9, "Final recording cannot be played")
            editor.pause()
            let output = disk.folder(project.id).appendingPathComponent("history-test.mp4")
            _ = try await MediaRenderer.render(project: project, folder: disk.folder(project.id), destination: output) { _ in }
            let exported = try await AVURLAsset(url: output).load(.duration).seconds
            try check(abs(exported - edited.duration) < 0.05, "Export omitted the final recording")
            report = ["success": true, "undoPreservesAllRecordings": true, "recordingPreservesRedo": true,
                      "explicitDeletionUndo": true, "reopen": true, "lastRecordingPlayback": true,
                      "duration": edited.duration, "exportDuration": exported]
        } catch { report = ["success": false, "error": error.localizedDescription] }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: folder.appendingPathComponent("report.json"), options: .atomic) }
    }
    @MainActor static func comparison() async {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("AudioComparisonTest", isDirectory: true)
        let editor = EditorController()
        let matching = editor.matchListeningLevels
        defer { editor.stop(); editor.matchListeningLevels = matching }
        var report: [String: Any] = [:], samples: [[String: Any]] = []
        func wait(_ condition: () -> Bool) async throws {
            for _ in 0..<300 {
                if condition() { return }
                if let error = editor.error { throw NSError(domain: "AudioComparisonQA", code: 1, userInfo: [NSLocalizedDescriptionKey: error]) }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw NSError(domain: "AudioComparisonQA", code: 2, userInfo: [NSLocalizedDescriptionKey: "Playback/processing timed out"])
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard let fixture = Bundle.main.url(forResource: "editor-fixture", withExtension: "mp4") else { throw ProjectError.missingMedia }
            let source = folder.appendingPathComponent("source.mp4")
            if !FileManager.default.fileExists(atPath: source.path) { try FileManager.default.copyItem(at: fixture, to: source) }
            var duration = try await AVURLAsset(url: source).load(.duration).seconds
            var project = Project(title: "Audio comparison QA")
            project.append(SourceMedia(filename: source.lastPathComponent, duration: duration))
            var edit = project.edit; edit.effects = [AudioEffect(kind: .gain, amount: -18, frequency: 1000)]; project.commit(edit)
            if CommandLine.arguments.contains("--selected-project-comparison"),
               let selected = UserDefaults.standard.string(forKey: "selectedProject"), UUID(uuidString: selected) != nil {
                let original = folder.deletingLastPathComponent().appendingPathComponent("Projects/" + selected, isDirectory: true)
                project = try ProjectDisk(root: original.deletingLastPathComponent()).read(original.appendingPathComponent("project.json"))
                try project.validate()
                for media in project.sources {
                    let destination = folder.appendingPathComponent(media.filename)
                    if !FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.copyItem(at: original.appendingPathComponent(media.filename), to: destination) }
                }
                duration = project.edit.duration
            }
            editor.matchListeningLevels = CommandLine.arguments.contains("--selected-project-comparison") ? matching : false
            await editor.load(project, folder: folder)
            editor.render(project, folder: folder, preview: true)
            try await wait { !editor.rendering && editor.canUseProcessed }
            editor.seek(2); editor.togglePlay()
            try await wait { editor.player.rate > 0 && editor.playhead > 2.1 }
            for mode in [true, false, true, false] {
                if mode { editor.listenProcessed() } else { await editor.original(project, folder: folder) }
                let before = editor.playhead
                try await Task.sleep(for: .milliseconds(900))
                guard let item = editor.player.currentItem else { throw ProjectError.invalidMedia }
                let tracks = try await item.asset.loadTracks(withMediaType: .audio)
                let urls = tracks.compactMap { $0 as? AVCompositionTrack }.flatMap { $0.segments.compactMap { $0.sourceURL?.lastPathComponent } }
                let peaks = try await MediaRenderer.waveform(asset: item.asset, duration: duration, bins: 100).peaks
                samples.append(["requested": mode ? "processed" : "original", "selected": editor.processedPreview ? "processed" : "original",
                                "rate": editor.player.rate, "playing": editor.playing, "before": before, "after": editor.playhead,
                                "sources": urls, "peak": peaks.max() ?? 0, "volume": editor.player.volume, "status": item.status.rawValue])
            }
            report["success"] = samples.allSatisfy { ($0["rate"] as? Float ?? 0) > 0 && ($0["after"] as? Double ?? 0) > ($0["before"] as? Double ?? 0) + 0.3 }
            if CommandLine.arguments.contains("--expect-original-unity") {
                let restored = samples.filter { $0["requested"] as? String == "original" }.allSatisfy { ($0["volume"] as? Float) == 1 }
                report["originalLevelRestored"] = restored
                report["success"] = (report["success"] as? Bool == true) && restored
            }
        } catch { report["success"] = false; report["error"] = error.localizedDescription }
        report["samples"] = samples
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: folder.appendingPathComponent("report.json"), options: .atomic) }
    }
    static func run() async {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = documents.appendingPathComponent("EditorDiagnostics-" + UUID().uuidString, isDirectory: true)
        var report: [String: Any] = ["started": Date().description, "status": "running"]
        func save() {
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: folder.appendingPathComponent("report.json"), options: .atomic)
            }
        }
        let player = AVPlayer()
        defer { player.pause(); player.replaceCurrentItem(with: nil); save() }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try folder.lastPathComponent.write(to: documents.appendingPathComponent("editor-diagnostics-latest.txt"), atomically: true, encoding: .utf8)
            guard let portrait = Bundle.main.url(forResource: "editor-fixture", withExtension: "mp4") else { throw ProjectError.missingMedia }
            let captureFolder = documents.appendingPathComponent(try String(contentsOf: documents.appendingPathComponent("capture-diagnostics-latest.txt"), encoding: .utf8))
            let candidates = try FileManager.default.contentsOfDirectory(at: captureFolder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "mov" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            var hd: URL?, ultra: URL?
            for file in candidates {
                if let video = try await AVURLAsset(url: file).loadTracks(withMediaType: .video).first {
                    let size = try await video.load(.naturalSize)
                    if max(size.width, size.height) >= 3840 { if ultra == nil { ultra = file } }
                    else if hd == nil { hd = file }
                }
            }
            guard let hd, let ultra else { throw ProjectError.missingMedia }
            var project = Project(title: "Mixed framing device QA")
            for input in [portrait, hd, ultra] {
                let destination = folder.appendingPathComponent(UUID().uuidString + "." + input.pathExtension)
                try FileManager.default.copyItem(at: input, to: destination)
                let duration = try await AVURLAsset(url: destination).load(.duration).seconds
                let hash = try await SourceMediaCache.shared.fingerprint(destination)
                project.append(SourceMedia(filename: destination.lastPathComponent, duration: duration, sha256: hash))
            }
            var edit = project.edit
            edit.clips = project.sources.map { TimelineClip(sourceID: $0.id, start: 0, end: min(1.5, $0.duration)) }
            edit.effects = [.make(.voiceIsolation), AudioEffect(kind: .gain, amount: -3, frequency: 1000)]
            project.commit(edit)
            let encoded = try JSONEncoder().encode(project)
            try encoded.write(to: folder.appendingPathComponent("project.json"), options: .atomic)
            report["stage"] = "prepare mixed timeline"; save()
            let prepared = try await SourceMediaCache.shared.prepared(project: project, folder: folder) { _ in }
            let item = AVPlayerItem(asset: prepared.media.composition)
            item.videoComposition = prepared.media.playbackVideoComposition; item.audioMix = prepared.media.audioMix
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            item.add(output); player.replaceCurrentItem(with: item)
            var frames: [[String: Any]] = []
            var cursor = 0.0
            for (index, clip) in edit.clips.enumerated() {
                report["stage"] = "decode clip \(index + 1)"; save()
                let time = CMTime(seconds: cursor + min(0.3, clip.duration / 2), preferredTimescale: 60000)
                _ = await withCheckedContinuation { continuation in
                    player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { continuation.resume(returning: $0) }
                }
                player.play()
                let deadline = Date().addingTimeInterval(8)
                var pixel: CVPixelBuffer?
                var displayTime = CMTime.invalid
                while pixel == nil && Date() < deadline {
                    if item.status == .failed { throw item.error ?? ProjectError.invalidMedia }
                    let requested = item.currentTime()
                    if output.hasNewPixelBuffer(forItemTime: requested),
                       let candidate = output.copyPixelBuffer(forItemTime: requested, itemTimeForDisplay: &displayTime),
                       displayTime.isNumeric, displayTime.seconds >= time.seconds - 0.08,
                       displayTime.seconds < cursor + clip.duration {
                        pixel = candidate
                    }
                    if pixel == nil { try await Task.sleep(for: .milliseconds(50)) }
                }
                player.pause()
                guard let pixel else { throw NSError(domain: "EditorDiagnostics", code: 1, userInfo: [NSLocalizedDescriptionKey: "No composed video frame for clip \(index + 1). \(item.error?.localizedDescription ?? "")"]) }
                let image = CIImage(cvPixelBuffer: pixel)
                guard let cg = CIContext().createCGImage(image, from: image.extent), let jpeg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.85) else { throw ProjectError.invalidMedia }
                try jpeg.write(to: folder.appendingPathComponent("clip-\(index + 1).jpg"))
                frames.append(["clip": index + 1, "width": CVPixelBufferGetWidth(pixel), "height": CVPixelBufferGetHeight(pixel), "time": item.currentTime().seconds, "frameTime": displayTime.seconds])
                cursor += clip.duration
            }
            report["frames"] = frames; report["stage"] = "export mixed timeline"; save()
            player.replaceCurrentItem(with: nil)
            let destination = folder.appendingPathComponent("mixed-export.mp4")
            _ = try await MediaRenderer.render(project: project, folder: folder, destination: destination) { _ in }
            let asset = AVURLAsset(url: destination)
            report["exportDuration"] = try await asset.load(.duration).seconds
            report["expectedDuration"] = edit.duration
            for source in project.sources {
                guard try await SourceMediaCache.shared.fingerprint(folder.appendingPathComponent(source.filename)) == source.sha256 else { throw ProjectError.invalidDocument }
            }
            withExtendedLifetime(prepared) {}
            report["status"] = "passed"
        } catch { report["status"] = "failed"; report["error"] = error.localizedDescription }
    }
}

extension CaptureDiagnostics {
    static func dual(_ camera: CaptureController, assists: Bool = false) async {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let root = documents.appendingPathComponent("CaptureDiagnostics-Dual-" + UUID().uuidString)
        var report: [String: Any] = ["started": Date().description], files: [URL] = []
        let oldCallback = camera.onSegment, oldMirrored = camera.mirrorRecording, oldPreview = camera.mirrorPreview
        let backup = documents.appendingPathComponent("DualCapturePreferences.plist")
        let saved = (try? Data(contentsOf: backup)).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        func diagnosticKey(_ key: String) -> Bool {
            key.hasPrefix("camera.") || key.hasPrefix("recordingGain.") || ["lastFrontCamera", "lastRearCamera", "dualCameraLayout", "dualStabilization", "dualFaceFollow", "captureHDR", "captureQuality", "liveVideoEffects", "selectedRecorderUIProject", "mirrorFrontPreview", "mirrorFrontRecording"].contains(key)
        }
        let prefs = (saved ?? UserDefaults.standard.dictionaryRepresentation()).filter { diagnosticKey($0.key) }
        let effects = (prefs["liveVideoEffects"] as? Data).flatMap { try? JSONDecoder().decode(SupportedVideoEffects.self, from: $0).values } ?? []
        let layout = (prefs["dualCameraLayout"] as? Data).flatMap { try? JSONDecoder().decode(DualCameraLayout.self, from: $0) } ?? DualCameraLayout()
        var originalCamera = ""
        camera.onSegment = { url, completion in files.append(url); completion(true) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            camera.prepare(); try await wait { camera.ready && !camera.switchingCamera }
            originalCamera = camera.cameraID
            report["before"] = await camera.probeSnapshot()
            camera.setVideoEffects([])
            camera.setTwoCameras(true); try await wait { !camera.switchingCamera }
            guard camera.dualActive else { throw MultiCameraCapture.Failure(camera.warning ?? "No two-camera mode") }
            if assists {
                camera.setStabilization(true); try await wait { !camera.switchingCamera }
                camera.setFaceFollow(true)
            }
            try await Task.sleep(for: .seconds(2))
            report["initial"] = await camera.probeDualMetrics()
            var results: [[String: Any]] = [], comparisons: [[String: Any]] = []
            camera.mirrorPreview = true
            for name in ["floating", "sideBySide", "topAndBottom", "diagonal", "diagonalFlipped", "circle"] {
                let mode = name == "circle" ? DualCameraLayout.Mode.floating : name == "diagonalFlipped" ? .diagonal : DualCameraLayout.Mode(rawValue: name)!
                var next = DualCameraLayout(); next.mode = mode
                if mode == .floating { next.insetSize = 0.4; next.insetAspect = 1.8 }
                next.roundInset = name == "circle"; next.diagonalFlipped = name == "diagonalFlipped"
                if assists { next.first.x = 0; next.first.y = 0; next.second.x = 0; next.second.y = 0; next.first.zoom = 1.3; next.second.zoom = 1.3 }
                camera.updateDualLayout(next)
                camera.setRecordingGain(0)
                camera.mirrorRecording = mode == .topAndBottom
                camera.start(in: root); try await wait { camera.state == .recording }
                try await Task.sleep(for: .seconds(1))
                if assists { try await Task.sleep(for: .seconds(3)) }
                _ = try await camera.probeLivePreview(to: root.appendingPathComponent(name + "-preview.png"))
                try camera.probeScreen(to: root.appendingPathComponent(name + "-screen.png"))
                var pair = try await camera.probeDualImages(prefix: root.appendingPathComponent(name + "-pair"))
                pair["name"] = name + "-pair"; comparisons.append(pair)
                next.swapped = true; next.verticalDivider = 0.65; next.horizontalDivider = 0.35; camera.updateDualLayout(next)
                camera.setRecordingGain(6)
                try await Task.sleep(for: .seconds(1))
                camera.setRecordingGain(0)
                camera.addBookmark()
                try await Task.sleep(for: .seconds(1))
                _ = try await camera.probeLivePreview(to: root.appendingPathComponent(name + "-swapped.png"))
                pair = try await camera.probeDualImages(prefix: root.appendingPathComponent(name + "-swapped-pair"))
                pair["name"] = name + "-swapped-pair"; comparisons.append(pair)
                camera.stop(pause: mode == .sideBySide); try await wait { !camera.hasActiveTake }
                if camera.state == .paused {
                    camera.start(in: root); try await wait { camera.state == .recording }
                    try await Task.sleep(for: .seconds(1)); camera.stop(); try await wait { !camera.hasActiveTake }
                }
                results.append(["mode": name, "mirroredFront": camera.mirrorRecording, "metrics": await camera.probeDualMetrics(), "writer": await camera.probeSnapshot()])
            }
            camera.mirrorPreview = false; camera.mirrorRecording = true
            camera.start(in: root); try await wait { camera.state == .recording }
            try await Task.sleep(for: .seconds(1))
            var reverse = try await camera.probeDualImages(prefix: root.appendingPathComponent("reverse-mirror-pair"))
            reverse["name"] = "reverse-mirror-pair"; comparisons.append(reverse)
            try camera.probeScreen(to: root.appendingPathComponent("reverse-mirror-screen.png"))
            camera.stop(); try await wait { !camera.hasActiveTake }
            camera.mirrorPreview = true; camera.mirrorRecording = false
            camera.setVideoEffects([VideoEffectSettings(.silentTint)])
            camera.start(in: root); try await wait { camera.state == .recording }
            try await Task.sleep(for: .seconds(2)); camera.stop(); try await wait { !camera.hasActiveTake }
            report["effects"] = await camera.videoEffectMetrics()
            if assists {
                camera.setFaceFollow(false)
                camera.setStabilization(false); try await wait { !camera.switchingCamera }
                report["disabled"] = await camera.probeDualMetrics()
            }
            var key = VideoEffectSettings(.chromaKey); key.set("personHint", .toggle(false)); camera.setVideoEffects([key])
            camera.captureCleanPlate(key.id)
            try await wait { if case .media(let file) = camera.videoEffects.first?.value("cleanPlate") { return file != nil }; return false }
            guard case .media(let plate?) = camera.videoEffects.first?.value("cleanPlate"),
                  let recordedPlate = LiveVideoEffects.recordingPlateName(plate),
                  FileManager.default.fileExists(atPath: LiveVideoEffects.folder.appendingPathComponent(recordedPlate).path) else { throw ProjectError.missingMedia }
            camera.start(in: root); try await wait { camera.state == .recording }
            try await Task.sleep(for: .seconds(1)); camera.stop(); try await wait { !camera.hasActiveTake }
            guard let movie = files.last else { throw ProjectError.invalidMedia }
            let recipe = try JSONDecoder().decode([VideoEffectSettings].self, from: Data(contentsOf: movie.deletingPathExtension().appendingPathExtension("effects.json")))
            guard case .media(let savedPlate) = recipe.first?.value("cleanPlate"), savedPlate == recordedPlate,
                  FileManager.default.fileExists(atPath: root.appendingPathComponent(recordedPlate).path) else { throw ProjectError.missingMedia }
            let duration = try await AVURLAsset(url: movie).load(.duration).seconds
            var keyProject = Project(title: "Dual clean plate QA")
            keyProject.append(SourceMedia(filename: movie.lastPathComponent, duration: duration, videoEffects: VideoEffectSettings.capturedRecipe(recipe, duration: duration)))
            let keyMedia = try await MediaRenderer.timeline(project: keyProject, folder: root)
            let generator = AVAssetImageGenerator(asset: keyMedia.composition); generator.videoComposition = keyMedia.videoComposition
            _ = try await generator.image(at: CMTime(seconds: 0.2, preferredTimescale: 30))
            report["cleanPlate"] = ["preview": plate, "recorded": recordedPlate, "exportFrame": "passed"]
            report["comparisons"] = comparisons
            report["cases"] = results
            var media: [[String: Any]] = []
            for file in files {
                let asset = AVURLAsset(url: file)
                let videos = try await asset.loadTracks(withMediaType: .video), audio = try await asset.loadTracks(withMediaType: .audio)
                guard let video = videos.first, let sound = audio.first else { throw ProjectError.invalidMedia }
                let size = try await video.load(.naturalSize), videoRange = try await video.load(.timeRange), audioRange = try await sound.load(.timeRange)
                guard abs(videoRange.end.seconds-audioRange.end.seconds) < 0.05 else { throw MultiCameraCapture.Failure("Audio/video endpoints diverged") }
                media.append(["file": file.lastPathComponent, "size": [size.width, size.height], "duration": videoRange.duration.seconds, "audioDuration": audioRange.duration.seconds])
            }
            report["media"] = media; report["status"] = "passed"
        } catch { report["status"] = "failed"; report["error"] = error.localizedDescription }
        camera.stop(); try? await wait { !camera.hasActiveTake }; camera.finishPausedTake()
        if camera.dualActive {
            camera.setFaceFollow(prefs["dualFaceFollow"] as? Bool ?? false)
            camera.setStabilization(prefs["dualStabilization"] as? Bool ?? false); try? await wait { !camera.switchingCamera }
        }
        if camera.dualActive { camera.setTwoCameras(false); try? await wait { !camera.switchingCamera } }
        camera.mirrorRecording = oldMirrored; camera.mirrorPreview = oldPreview
        camera.updateDualLayout(layout); camera.setVideoEffects(effects)
        let gain = (prefs["recordingGain." + camera.microphoneID] as? Double) ?? 0
        camera.setRecordingGain(gain)
        camera.probeRestoreSettings(prefs, cameraID: originalCamera)
        try? await Task.sleep(for: .seconds(1))
        report["restored"] = await camera.probeSnapshot()
        // Remove diagnostic-only preferences too; the external snapshot verifies this.
        let keys = UserDefaults.standard.dictionaryRepresentation().keys.filter { diagnosticKey($0) }
        for key in keys { UserDefaults.standard.set(prefs[key], forKey: key) }
        camera.onSegment = oldCallback
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: root.appendingPathComponent("report.json")) }
        try? root.lastPathComponent.write(to: documents.appendingPathComponent("dual-capture-latest.txt"), atomically: true, encoding: .utf8)
    }
}

#endif
