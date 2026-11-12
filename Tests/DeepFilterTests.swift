import Foundation
import AVFoundation

extension CoreTests {
    static func deepFilterTests(root: URL) async throws {
        guard let modelPath = ProcessInfo.processInfo.environment["YOUREC_DFN3_MODEL"] else { throw NSError(domain: "DeepFilter model test requires its shipped model", code: 1) }
        let model = URL(fileURLWithPath: modelPath)
        let frames = 12347, format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        func save(_ name: String, _ channels: [[Float]]) throws -> URL {
            let url = root.appendingPathComponent(name + ".caf")
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(channels[0].count))!
            buffer.frameLength = buffer.frameCapacity
            for channel in 0..<2 { for i in channels[channel].indices { buffer.floatChannelData![channel][i] = channels[channel][i] } }
            var settings = format.settings; settings[AVLinearPCMIsNonInterleaved] = false
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
            return url
        }
        func read(_ url: URL) throws -> [[Float]] {
            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            try require(file.length == frames, "DeepFilter preserves the final partial-hop length")
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames))!
            try file.read(into: buffer)
            return (0..<2).map { Array(UnsafeBufferPointer(start: buffer.floatChannelData![$0], count: frames)) }
        }
        let left: [Float] = (0..<frames).map { index in
            let x = Double(index)
            let fundamental = sin(x * 0.033) * 0.3
            let harmonic = cos(x * 0.117) * 0.13
            return Float(fundamental + harmonic)
        }
        let right: [Float] = (0..<frames).map { Float(sin(Double($0) * 0.027) * 0.25) }
        let input = try save("dfn-input", [left, right])
        var effect = AudioEffect.make(.voiceIsolation); effect.model = .deepFilter
        func process(_ input: URL, _ name: String, _ effect: AudioEffect) throws -> URL {
            let output = root.appendingPathComponent(name + ".caf")
            _ = try OfflineAudioPipeline.process(input: input, effects: [effect], output: output) { _ in }
            return output
        }
        let wet = try read(process(input, "dfn-wet", effect))
        var half = effect; half.amount = 0.5
        let mixed = try read(process(input, "dfn-half", half))
        var zero = effect; zero.amount = 0
        let bypass = try process(input, "dfn-bypass", zero)
        let originalBytes = try Data(contentsOf: input), bypassBytes = try Data(contentsOf: bypass)
        try require(originalBytes == bypassBytes, "Zero DeepFilter amount preserves exact source bytes")
        let swappedInput = try save("dfn-swapped-input", [right, left])
        let swapped = try read(process(swappedInput, "dfn-swapped", effect))
        let silentInput = try save("dfn-silent-input", [left, [Float](repeating: 0, count: frames)])
        let silent = try read(process(silentInput, "dfn-silent", effect))
        for channel in 0..<2 {
            let dry = channel == 0 ? left : right
            for i in 0..<frames {
                try require(wet[channel][i].isFinite && wet[channel][i] == swapped[1 - channel][i], "DeepFilter stereo state is independent and repeatable")
                let expected: Float = dry[i] + 0.5 * (wet[channel][i] - dry[i])
                try require(abs(mixed[channel][i] - expected) < 1e-6, "Dry/wet mixing has no lookahead shift")
                try require(silent[1][i] == 0, "DeepFilter keeps a silent channel silent")
            }
        }
        let cancelled = root.appendingPathComponent("dfn-cancelled.caf")
        let selected = effect
        let cancellation = Task.detached {
            try OfflineAudioPipeline.process(input: input, effects: [selected], output: cancelled) { progress in
                if progress > 0.2 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { _ = try await cancellation.value; throw NSError(domain: "Missing cancellation", code: 1) }
        catch is CancellationError {}
        try require(!FileManager.default.fileExists(atPath: cancelled.path), "Cancelled DeepFilter does not publish output")

        // Reuse one loaded engine after real inference, flush, reset and prepare.
        // This exercises heap reuse, which a fresh-process comparison cannot cover.
        let engine = DeepFilterNetEngine(modelDirectory: model)
        _ = try engine.prepare()
        func render() throws -> [Float] {
            var output: [Float] = []
            for start in stride(from: 0, to: frames, by: 480) {
                let end = min(frames, start + 480)
                var hop: [Float] = Array(left[start..<end]); hop += repeatElement(Float(0), count: 480 - hop.count)
                output += try engine.processHop(hop)
            }
            output += try engine.flush()
            return Array(output.prefix(frames))
        }
        let first = try render()
        try require(first == wet[0], "Mono engine and stereo wrapper align exactly")
        let secondFlush = try engine.flush()
        try require(secondFlush.isEmpty, "Second flush does not duplicate output")
        do { _ = try engine.processHop([Float](repeating: 0, count: 480)); throw NSError(domain: "Missing finished guard", code: 1) }
        catch CoreMLEngineError.streamFinished {}
        try engine.reset()
        let afterReset = try render()
        _ = try engine.prepare()
        let afterPrepare = try render()
        try require(first == afterReset && first == afterPrepare, "Reset and repeated prepare clear all recurrent and DSP state")
        try engine.reset()
        do { _ = try engine.processHop([Float](repeating: .nan, count: 480)); throw NSError(domain: "Missing finite guard", code: 1) }
        catch CoreMLEngineError.invalidSamples {}

        // Independent timing reference: a varying harmonic signal, not the
        // engine's own output reused as the expected dry/wet reference.
        var harmonic = [Float](repeating: 0, count: 48000 * 4)
        var phase = 0.0, seed: UInt64 = 42
        for i in harmonic.indices {
            let time = Double(i) / 48000
            let fundamental = 140 + 15 * sin(2 * .pi * 5 * time)
            phase += 2 * .pi * fundamental / 48000
            var voice = 0.0
            for overtone in 1...20 { voice += sin(Double(overtone) * phase) / Double(overtone) }
            let envelope = max(0, sin(2 * .pi * 2.5 * time))
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let noise = (Double(seed >> 33) / Double(1 << 31) - 0.5) * 0.02
            harmonic[i] = Float(0.15 * envelope * voice + noise)
        }
        try engine.reset()
        var enhanced: [Float] = []
        for start in stride(from: 0, to: harmonic.count, by: 480) {
            enhanced += try engine.processHop(Array(harmonic[start..<(start + 480)]))
        }
        enhanced += try engine.flush()
        func correlation(_ lag: Int) -> Double {
            var product = 0.0, inputPower = 0.0, outputPower = 0.0
            for i in stride(from: 48000, to: 144000, by: 3) {
                let x = Double(harmonic[i]), y = Double(enhanced[i + lag])
                product += x * y; inputPower += x * x; outputPower += y * y
            }
            return product / sqrt(inputPower * outputPower)
        }
        let coarse = stride(from: -1440, through: 1440, by: 32).max { correlation($0) < correlation($1) }!
        let lag = ((coarse - 32)...(coarse + 32)).max { correlation($0) < correlation($1) }!
        print("DFN alignment: lag \(lag) samples, correlation \(correlation(lag))")
        try require(abs(lag) <= 1 && correlation(lag) > 0.98, "DeepFilter independently measured input/output alignment is within one sample")

        try require(correlation(0) - max(correlation(-340), correlation(340)) > 0.02,
                    "Timing peak is distinct from adjacent pitch periods")

        let damaged = root.appendingPathComponent("damaged-dfn", isDirectory: true)
        try FileManager.default.createDirectory(at: damaged, withIntermediateDirectories: true)
        let dsp = model.appendingPathComponent("DeepFilterNet3-DSP.json")
        var dspBytes = try Data(contentsOf: dsp); dspBytes.append(32) // valid JSON, wrong identity
        try dspBytes.write(to: damaged.appendingPathComponent(dsp.lastPathComponent))
        do { _ = try DeepFilterNetEngine(modelDirectory: damaged).prepare(); throw NSError(domain: "Missing model integrity check", code: 1) }
        catch CoreMLEngineError.modelIntegrityMismatch {}

        var project = Project(title: "Model identity persistence")
        project.append(SourceMedia(filename: "source.mp4", duration: 4))
        var edit = project.edit; edit.effects = [.make(.voiceIsolation)]; project.commit(edit)
        edit.effects = [effect]; project.commit(edit); project.undo()
        let disk = ProjectDisk(root: root.appendingPathComponent("dfn-projects"))
        try disk.save(project)
        var reopened = try disk.read(disk.folder(project.id).appendingPathComponent("project.json"))
        try require(reopened.edit.effects[0].model == .rnnoise, "Existing RNNoise identity survives reopen")
        reopened.redo()
        try require(reopened.edit.effects[0].model == .deepFilter, "Redo restores exact DeepFilter model version")
        print("PASS: DeepFilter stereo independence, partial hops, aligned half mix, exact bypass, cancellation, reset/reuse and persistent model selection")
    }
}

/// Signal measurements exercise the shipped DSP/model files, followed by the
/// same cached compositions used by AVPlayer and by video export.
func audioFilterAudit(root: URL) async throws {
    let folder = root.appendingPathComponent("audio-audit-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var report: [String: Any] = ["folder": folder.path]
    func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let result = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        try require(result.allSatisfy(\.isFinite), "Finite audio samples in \(url.lastPathComponent)")
        return result
    }
    func rms(_ x: [Float]) -> Double { sqrt(x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, x.count))) }
    func db(_ ratio: Double) -> Double { 20 * log10(max(1e-12, ratio)) }
    func difference(_ a: [Float], _ b: [Float]) -> Double { rms(zip(a, b).map { $0 - $1 }) / max(1e-12, rms(b)) }
    func saveReport() throws { try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("audio-audit-report.json"), options: .atomic) }
    func process(_ input: URL, _ name: String, _ effects: [AudioEffect]) throws -> [Float] {
        let url = folder.appendingPathComponent(name + ".caf"), start = ProcessInfo.processInfo.systemUptime
        let peak = try OfflineAudioPipeline.process(input: input, effects: effects, output: url) { _ in }
        let output = try read(url), original = try read(input)
        try require(output.count == original.count, "\(name) preserves duration")
        report[name] = ["seconds": ProcessInfo.processInfo.systemUptime - start, "rmsDBFS": db(rms(output)), "peak": peak, "relativeChangeDB": db(difference(output, original)), "output": url.path]
        try saveReport(); print("AUDIO AUDIT: \(name) \(report[name]!)")
        return output
    }
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    let tone = folder.appendingPathComponent("tones.caf"), frames = 96000
    do {
        let file = try AVAudioFile(forWriting: tone, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!; buffer.frameLength = buffer.frameCapacity
        for i in 0..<frames {
            let t = Double(i) / 48000
            let value = Float([40.0, 1800.0, 9000.0].reduce(0) { $0 + 0.03 * sin(2 * .pi * $1 * t) })
            buffer.floatChannelData![0][i] = value; buffer.floatChannelData![1][i] = value
        }
        try file.write(from: buffer)
    }
    let raw = try read(tone)
    for gain in [-18.0, -6, 0, 6, 18] {
        let x = try process(tone, "gain-\(gain)", [AudioEffect(kind: .gain, amount: gain)])
        let actual = db(rms(x) / rms(raw)); try require(abs(actual - gain) < 0.0001, "Gain \(gain) dB is actually \(actual) dB")
    }
    var disabled = AudioEffect(kind: .gain, amount: 18); disabled.enabled = false
    let bypass = try process(tone, "disabled-gain", [disabled]); try require(bypass == raw, "Disabled gain is bit-exact")
    func amplitude(_ x: [Float], hz: Double) -> Double {
        var re = 0.0, im = 0.0
        for i in 24000..<72000 { let a = 2 * Double.pi * hz * Double(i) / 48000; re += Double(x[i]) * cos(a); im += Double(x[i]) * sin(a) }
        return hypot(re, im) / 24000
    }
    let lowcut = try process(tone, "lowcut-200Hz", [AudioEffect(kind: .highPass, frequency: 200)])
    let cutDB = db(amplitude(lowcut, hz: 40) / amplitude(raw, hz: 40)), passDB = db(amplitude(lowcut, hz: 1800) / amplitude(raw, hz: 1800))
    try require(cutDB < -27 && abs(passDB) < 0.01, "Low-cut removes rumble and preserves speech band")
    let eq = try process(tone, "eq-plus6-1800Hz", [AudioEffect(kind: .equalizer, amount: 6, frequency: 1800)])
    try require(abs(db(amplitude(eq, hz: 1800) / amplitude(raw, hz: 1800)) - 6) < 0.01, "EQ delivers its actual center-frequency gain")
    report["lowcutMeasuredDB"] = cutDB; report["lowcutPassbandDB"] = passDB

    let speech = root.appendingPathComponent("speech.wav")
    let dry = try read(speech)
    let rn = AudioEffect.make(.voiceIsolation)
    var dfn = rn; dfn.model = .deepFilter
    let rnOutput = try process(speech, "rnnoise", [rn]), dfOutput = try process(speech, "deepfilter", [dfn])
    try require(difference(rnOutput, dry) > 0.001 && difference(dfOutput, dry) > 0.001, "Both isolation models do real processing")
    var studio = AudioEffect.make(.studioVoice); studio.amount = 1
    let wet = try process(speech, "studio-100", [studio])
    studio.amount = 0.35
    let partial = try process(speech, "studio-35", [studio])
    let expected = zip(dry, wet).map { $0 + 0.35 * ($1 - $0) }
    try require(difference(wet, dry) > 0.0001, "Studio model does not bypass its input")
    try require(difference(partial, expected) < 0.0001, "Studio amount is an actual dry/wet interpolation")
    studio.amount = 0
    let zero = try process(speech, "studio-zero", [studio]); try require(zero == dry, "Studio zero restores the original samples exactly")
    studio.amount = 1
    _ = try process(root.appendingPathComponent("speech-lowpass.wav"), "studio-bandlimited-100", [studio])
    let chain = [dfn, AudioEffect.make(.studioVoice), AudioEffect(kind: .highPass, frequency: 80), AudioEffect(kind: .equalizer, amount: 3, frequency: 1800), AudioEffect(kind: .gain, amount: -6)]
    _ = try process(speech, "whole-chain", chain)

    if ProcessInfo.processInfo.environment["YOUREC_VOICEFIXER_MODEL"] != nil {
        var restoration = AudioEffect.make(.studioRestoration)
        let full = try process(speech, "restoration-100", [restoration])
        restoration.amount = 0.5
        let half = try process(speech, "restoration-50", [restoration])
        var mixError: Float = 0
        for i in dry.indices { mixError = max(mixError, abs(dry[i] + 0.5 * (full[i] - dry[i]) - half[i])) }
        try require(mixError < 0.00001, "Studio restoration amount is an exact wet/dry mix")
        restoration.amount = 0
        let restoredZero = try process(speech, "restoration-zero", [restoration])
        try require(restoredZero == dry, "Zero restoration leaves original samples untouched")
        restoration.amount = 1
        _ = try process(root.appendingPathComponent("speech-lowpass.wav"), "restoration-lowpass", [restoration])
        let interrupted = folder.appendingPathComponent("restoration-interrupted.caf"), chunks = folder.appendingPathComponent("restoration.chunks")
        try StudioRestorationProcessor.process(input: speech, output: interrupted, amount: 1, resumeFolder: chunks) { _ in }
        let resumed = folder.appendingPathComponent("restoration-resumed.caf")
        try StudioRestorationProcessor.process(input: speech, output: resumed, amount: 1, resumeFolder: chunks) { _ in }
        let resumedSamples = try read(resumed), cachedSamples = try read(interrupted)
        try require(resumedSamples == cachedSamples, "Restoration cached windows reproduce identical samples")
        let cancelFile = folder.appendingPathComponent("restoration-cancelled.caf"), cancelChunks = folder.appendingPathComponent("restoration-cancel.chunks")
        let task = Task.detached {
            try StudioRestorationProcessor.process(input: speech, output: cancelFile, amount: 1, resumeFolder: cancelChunks) { value in
                if value > 0.2 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { try await task.value; try require(false, "Restoration responds to cancellation") }
        catch is CancellationError {}
        try require(!FileManager.default.fileExists(atPath: cancelFile.path), "Cancelled restoration publishes no partial audio")
        try StudioRestorationProcessor.process(input: speech, output: cancelFile, amount: 1, resumeFolder: cancelChunks) { _ in }
        let afterCancel = try read(cancelFile)
        try require(afterCancel == full, "Resuming a cancelled restoration retains timing and overlapping boundaries")
        // A partial final hop must reflect all context, including earlier samples
        // that lie outside the ordinary left margin (previously filled with zero).
        let reflected = StudioRestorationProcessor.sourceIndices(position: 52920, length: 57330)
        try require(reflected.last == 22492 && reflected.min() == 0 && reflected.max() == 57329, "Final restoration context includes complete reflected samples")
        for length in [1, 17, 481, 19201, 62401] {
            let short = folder.appendingPathComponent("short-\(length).caf"), output = folder.appendingPathComponent("short-\(length)-out.caf")
            do {
                let file = try AVAudioFile(forWriting: short, settings: format.settings)
                let data = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(length))!; data.frameLength = data.frameCapacity
                for i in 0..<length { data.floatChannelData![0][i] = length > 100 ? 0.02 * sin(Float(i) * 0.03) : 0; data.floatChannelData![1][i] = 0 }
                try file.write(from: data)
            }
            try StudioRestorationProcessor.process(input: short, output: output, amount: 1) { _ in }
            let file = try AVAudioFile(forReading: output)
            try require(file.length == length && file.processingFormat.channelCount == 2, "Short stereo restoration preserves exact frame/channel counts")
            let data = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(length))!; try file.read(into: data)
            try require((0..<length).allSatisfy { data.floatChannelData![0][$0].isFinite && data.floatChannelData![1][$0] == 0 }, "Restoration preserves a silent channel independently of the speaking channel")
        }

    }

    // Preview and export must use the same cached effect output, including
    // changes after a first render, bypass, a selected subrange and track gain.
    try FileManager.default.copyItem(at: root.appendingPathComponent("voice.mp4"), to: folder.appendingPathComponent("source.mp4"))
    var project = Project(title: "Audio audit"); project.append(SourceMedia(filename: "source.mp4", duration: 8))
    func mixed(_ project: Project, name: String, export: Bool = false) async throws -> [Float] {
        let pcm = folder.appendingPathComponent(name + "-mix.caf")
        if export {
            let movie = folder.appendingPathComponent(name + ".mp4")
            _ = try await MediaRenderer.render(project: project, folder: folder, destination: movie) { _ in }
            _ = try await MediaRenderer.processedAudio(asset: AVURLAsset(url: movie), duration: 8, effects: [], outputURL: pcm) { _ in }
        } else {
            let prepared = try await SourceMediaCache.shared.prepared(project: project, folder: folder) { _ in }
            report[name + "-matching"] = ["original": prepared.listeningGains.original, "processed": prepared.listeningGains.processed]
            _ = try await MediaRenderer.processedAudio(asset: prepared.media.composition, duration: 8, effects: [], outputURL: pcm, mix: prepared.media.audioMix) { _ in }
        }
        return try read(pcm)
    }
    let base = project.edit
    let original = try await mixed(project, name: "original")
    for gain in [6.0, -6, 0] {
        var edit = base; edit.timeline.enhance([AudioEffect(kind: .gain, amount: gain)], selection: edit.timeline.entireSelection()); project.commit(edit)
        let played = try await mixed(project, name: "preview-gain-\(gain)")
        let exported = try await mixed(project, name: "export-gain-\(gain)", export: true)
        let actual = db(rms(played) / rms(original)), final = db(rms(exported) / rms(original))
        try require(abs(actual - gain) < 0.02 && abs(final - gain) < 0.2, "Preview/export gain survives cached revisions: \(actual)/\(final)")
        report["gain-\(gain)-preview-exportDB"] = [actual, final]
    }
    var edit = base; edit.timeline.enhance([AudioEffect(kind: .gain, amount: -12)], selection: edit.timeline.entireSelection(range: EditInterval(2...6))); project.commit(edit)
    let ranged = try await mixed(project, name: "selected-range")
    func sliceRMS(_ x: [Float], _ a: Double, _ b: Double) -> Double { rms(Array(x[Int(a * 48000)..<Int(b * 48000)])) }
    for (a, b, expected) in [(0.5, 1.5, 0.0), (2.5, 5.5, -12.0), (6.5, 7.5, 0.0)] {
        try require(abs(db(sliceRMS(ranged, a, b) / sliceRMS(original, a, b)) - expected) < 0.01, "Enhancement respects selected audio range")
    }
    edit = base; edit.timeline.enhance([.make(.studioVoice), AudioEffect(kind: .gain, amount: -6)], selection: edit.timeline.entireSelection()); project.commit(edit)
    let played = try await mixed(project, name: "studio-preview"), exported = try await mixed(project, name: "studio-export", export: true)
    try require(difference(played, original.map { $0 * Float(pow(10, -6.0 / 20)) }) > 0.0001, "Studio reaches the editor mix")
    try require(abs(db(rms(exported) / rms(played))) < 0.25, "Studio preview/export loudness agrees")
    if ProcessInfo.processInfo.environment["YOUREC_VOICEFIXER_MODEL"] != nil {
        edit = base; edit.timeline.enhance([.make(.studioRestoration), AudioEffect(kind: .gain, amount: -6)], selection: edit.timeline.entireSelection(range: EditInterval(2...6))); project.commit(edit)
        let restoredPreview = try await mixed(project, name: "restoration-preview"), restoredExport = try await mixed(project, name: "restoration-export", export: true)
        try require(abs(db(rms(restoredExport) / rms(restoredPreview))) < 0.25, "Studio restoration survives preview and export")
        try require(abs(db(sliceRMS(restoredPreview, 0.5, 1.5) / sliceRMS(original, 0.5, 1.5))) < 0.01, "Studio restoration respects selected range")
    }
    project.commit(base)
    let restored = try await mixed(project, name: "removed-chain")
    try require(restored == original, "Removing the full chain restores original audio exactly")
    report["status"] = "passed"; try saveReport(); print("PASS: all audio filters, both isolation models, Studio wet amount, gain/cache reset, selected-range playback and exports")
}
