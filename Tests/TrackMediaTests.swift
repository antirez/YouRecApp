import Foundation
import AVFoundation
import CoreGraphics
import ImageIO

func snappedBoundaryMediaTests(root: URL) async throws {
    let source = SourceMedia(filename: "source.mp4", duration: 4)
    var failures: [String] = []
    for ticks in [240000, 240001, 240002, 240003, 250001] {
        for independent in [false, true] {
            let a = TimelineClip(sourceID: source.id, start: 0, end: EditTime(ticks: Int64(ticks)).seconds)
            let b = TimelineClip(sourceID: source.id, start: 1.3, end: 3.3)
            var timeline = TrackTimeline(clips: [a, b])
            if independent { timeline.unlink(timeline.entireSelection()) }
            let target = timeline.selection(of: b.id)
            timeline.move(target, by: EditTime(0.5))
            let snapped = timeline.snappedMove(target, by: EditTime(-0.49), scale: 100)
            try require(snapped.snap != nil, "Regression must use the real magnet calculation")
            timeline.move(target, by: snapped.delta)
            let left = timeline.video.first { $0.id == a.id }!, right = timeline.video.first { $0.id == b.id }!
            try require(left.end == right.start, "Magnet joins picture edges exactly")
            var project = Project(title: "Snapped boundary QA"); project.sources = [source]
            project.history = [EditState(timeline: timeline)]; project.historyCursor = 0
            let media = try await MediaRenderer.timeline(project: project, folder: root)
            for instruction in media.videoComposition.instructions.compactMap({ $0 as? TrackVideoInstruction }) {
                if !Set(instruction.order).isSubset(of: Set(instruction.layers.keys)) {
                    failures.append("Missing layer at \(instruction.timeRange.start.seconds)...\(instruction.timeRange.end.seconds), ticks=\(ticks), independent=\(independent)")
                }
            }
            let generator = AVAssetImageGenerator(asset: media.composition)
            generator.videoComposition = media.videoComposition
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            var generators = [("preview", generator)]
            if independent && ticks == 240001 {
                let export = root.appendingPathComponent("snapped-boundary-export.mp4")
                try? FileManager.default.removeItem(at: export)
                _ = try await MediaRenderer.render(project: project, folder: root, destination: export) { _ in }
                let exported = AVAssetImageGenerator(asset: AVURLAsset(url: export))
                exported.requestedTimeToleranceBefore = .zero; exported.requestedTimeToleranceAfter = .zero
                generators.append(("export", exported))
            }
            // Include the frame-grid point just before a fractional join: the
            // old renderer could leave that frame inside its rounding gap.
            let times = Set([left.end.seconds - 1.0/30, left.end.seconds, left.end.seconds + 1.0/30,
                             floor(left.end.seconds * 30) / 30]).sorted()
            for (kind, images) in generators { for time in times {
                let image = try await images.image(at: TrackRenderer.time(EditTime(time))).image
                var pixels = [UInt8](repeating: 0, count: 32 * 32 * 4)
                let context = CGContext(data: &pixels, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 32*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
                let brightness = pixels.enumerated().filter { $0.offset % 4 != 3 }.reduce(0.0) { $0 + Double($1.element) } / Double(32*32*3)
                print("SNAP FRAME \(kind) ticks=\(ticks) independent=\(independent) at=\(time) brightness=\(brightness)")
                if brightness < 10 { failures.append("Black \(kind) frame at \(time), ticks=\(ticks), independent=\(independent)") }
            } }
        }
    }
    try require(failures.isEmpty, failures.joined(separator: "\n"))
    print("PASS: snapped boundaries retain exact instruction coverage and visible frames")
}

func audioPreviewWindowTests(root: URL) async throws {
    let folder = root.appendingPathComponent("audio-window-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    let sourceURL = folder.appendingPathComponent("long.caf")
    do {
        let file = try AVAudioFile(forWriting: sourceURL, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!; buffer.frameLength = 48000
        for second in 0..<60 {
            for frame in 0..<48000 {
                let sample = Float((0.03 + Double(second) * 0.001) * sin(Double(frame) * .pi / 24))
                for channel in 0..<2 { buffer.floatChannelData![channel][frame] = sample }
            }
            try file.write(from: buffer)
        }
    }
    var project = Project(title: "Window test")
    project.append(SourceMedia(filename: "long.caf", duration: 60))
    var state = project.edit; state.timeline.video = []; state.timeline.links = []
    var gain = AudioEffect.make(.gain); gain.amount = 6
    state.timeline.enhance([gain], selection: TimelineSelection(audio: Set(state.timeline.audio.map(\.id))))
    project.history = [state]; project.historyCursor = 0
    try require(AudioPreviewWindow.listeningRange(at: 30, selection: 0...60) == 25...35, "Preview is five seconds before/after the playhead")
    try require(AudioPreviewWindow.listeningRange(at: 0, selection: 0...60) == 0...5, "At the beginning, do not extend beyond five seconds after the playhead")
    try require(AudioPreviewWindow.listeningRange(at: 33, selection: 32...34) == 32...34, "Preview never escapes the selected piece")
    let window = try await SourceMediaCache.shared.prepared(project: project, folder: folder, audioPreviewRange: 25...35) { _ in }
    let cache = ProjectCacheLocation.root(in: folder)
    var files = try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil).filter { $0.pathExtension == "caf" }
    try require(files.count == 1, "Only the requested source window is processed")
    let rendered = try AVAudioFile(forReading: files[0])
    try require(rendered.length == 10 * 48000, "The preview CAF contains ten seconds, not the sixty-second take")
    let fullURL = folder.appendingPathComponent("full.caf")
    _ = try OfflineAudioPipeline.process(input: sourceURL, effects: [gain], output: fullURL) { _ in }
    let full = try await TrackRenderer.timeline(project: project, folder: folder, processedSources: [project.sources[0].id: fullURL])
    let original = try await AudioPreviewLevels.energies(asset: full.composition, mix: full.audioMix, range: 25.2...34.8)
    let shortened = try await AudioPreviewLevels.energies(asset: window.media.composition, mix: window.media.audioMix, range: 25.2...34.8)
    try require(original.count == shortened.count && zip(original, shortened).allSatisfy { abs($0 - $1) < 0.00001 }, "Window offset and gain match full processing at the same source position")
    let outside = try await AudioPreviewLevels.energies(asset: window.media.composition, mix: window.media.audioMix, range: 0...10)
    try require(outside.allSatisfy { $0 < 1e-10 }, "Preview mix does not include audio outside its window")
    // One moved item can contain disjoint source runs and variable rates. Do not
    // process the large discarded source gap, and retain pitch/timing on both.
    state.timeline.audio[0].mapping = SourcePlaybackMap(runs: [
        PlaybackRun(duration: EditTime(2), sourceStart: 3, sourceEnd: 7),
        PlaybackRun(duration: EditTime(2), sourceStart: 50, sourceEnd: 51)
    ])
    state.timeline.audio[0].start = EditTime(6)
    state.timeline.audio[0].enhancements[0].interval = EditInterval(0...4)
    project.history = [state]
    let cut = try await SourceMediaCache.shared.prepared(project: project, folder: folder, audioPreviewRange: 6...10) { _ in }
    let reference = try await TrackRenderer.timeline(project: project, folder: folder, processedSources: [project.sources[0].id: fullURL])
    let a = try await AudioPreviewLevels.energies(asset: cut.media.composition, mix: cut.media.audioMix, range: 6.2...9.8)
    let b = try await AudioPreviewLevels.energies(asset: reference.composition, mix: reference.audioMix, range: 6.2...9.8)
    let levelErrors = zip(a, b).map { 10 * log10(max($0, 1e-10) / max($1, 1e-10)) }
    // The spectral stretcher has less look-ahead at the end of a windowed
    // file. Keep the strict comparison across the cut and measure the final
    // energy window separately (up to 0.25 dB variation on the Apple backend).
    let interiorMatches = zip(a.dropLast(), b.dropLast()).allSatisfy { abs($0 - $1) < 0.0001 }
    try require(!a.isEmpty && a.count == b.count && interiorMatches && abs(levelErrors.last ?? .infinity) < 0.3,
                "Disjoint, retimed preview keeps source offsets, gain and pitch-preserved timing; measured dB differences: \(levelErrors)")
    files = try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil).filter { $0.pathExtension == "caf" }
    let lengths = try files.map { Double(try AVAudioFile(forReading: $0).length) / 48000 }
    try require(lengths.contains(4) && lengths.contains(1) && !lengths.contains(48), "Separate windows never decode the gap between source runs")
    state.timeline.audio[0].mapping.runs[1].sourceStart = 7
    state.timeline.audio[0].mapping.runs[1].sourceEnd = 8
    project.history = [state]
    let ramp = try await SourceMediaCache.shared.prepared(project: project, folder: folder, audioPreviewRange: 6...10) { _ in }
    let rampReference = try await TrackRenderer.timeline(project: project, folder: folder, processedSources: [project.sources[0].id: fullURL])
    let c = try await AudioPreviewLevels.energies(asset: ramp.media.composition, mix: ramp.media.audioMix, range: 6.2...9.8)
    let d = try await AudioPreviewLevels.energies(asset: rampReference.composition, mix: rampReference.audioMix, range: 6.2...9.8)
    try require(c.count == d.count && zip(c,d).allSatisfy { abs($0-$1) < 0.0001 }, "Continuous rate changes retain the same pitch renderer in preview and export")
    withExtendedLifetime([window.lease, cut.lease, ramp.lease]) {}
    print("PASS: lazy audio preview window, selection bounds, short source processing, gain, disjoint cuts and retiming")
}

func trackMediaTests(root: URL) async throws {
    let folder = root.appendingPathComponent("independent-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: root.appendingPathComponent("source.mp4"), to: folder.appendingPathComponent("source.mp4"))
    var project = Project(title: "Independent media")
    project.append(SourceMedia(filename: "source.mp4", duration: 4))
    let baseline = project.edit
    var retainedLeases: [SourceCacheLease] = []
    func media(_ edit: EditState, processed: Bool = false) async throws -> TimelineMedia {
        var candidate = project; candidate.history = [edit]; candidate.historyCursor = 0
        if processed { let prepared = try await SourceMediaCache.shared.prepared(project: candidate, folder: folder) { _ in }; if let lease = prepared.lease { retainedLeases.append(lease) }; return prepared.media }
        return try await MediaRenderer.timeline(project: candidate, folder: folder)
    }
    func picture(_ media: TimelineMedia, at seconds: Double) async throws -> [UInt8] {
        let generator = AVAssetImageGenerator(asset: media.composition)
        generator.videoComposition = media.videoComposition
        return try await picture(generator, at: seconds)
    }
    func picture(_ generator: AVAssetImageGenerator, at seconds: Double) async throws -> [UInt8] {
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let frame = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 240000))
        let image = frame.image
        if let destination = CGImageDestinationCreateWithURL(folder.appendingPathComponent("frame-\(seconds)-" + UUID().uuidString + ".png") as CFURL, "public.png" as CFString, 1, nil) { CGImageDestinationAddImage(destination, image, nil); CGImageDestinationFinalize(destination) }
        print("TRACK FRAME: \(seconds) actual \(frame.actualTime.seconds) space \(image.colorSpace?.name as Any)")
        var values = [UInt8](repeating: 0, count: 160 * 90 * 4)
        values.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: 160, height: 90, bitsPerComponent: 8, bytesPerRow: 160 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 160, height: 90))
        }
        return values
    }
    func difference(_ a: [UInt8], _ b: [UInt8]) -> Double { zip(a, b).enumerated().filter { $0.offset % 4 != 3 }.reduce(0.0) { $0 + abs(Double($1.element.0) - Double($1.element.1)) } / Double(160 * 90 * 3) }
    func sound(_ media: TimelineMedia, duration: Double) async throws -> [Float] {
        let url = folder.appendingPathComponent(UUID().uuidString + ".caf")
        _ = try await MediaRenderer.processedAudio(asset: media.composition, duration: duration, effects: [], outputURL: url, mix: media.audioMix) { _ in }
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }
    func rms(_ values: [Float], at start: Double, duration: Double = 0.2) -> Double {
        let a = min(values.count, Int(start * 48000)), b = min(values.count, Int((start + duration) * 48000))
        return a < b ? sqrt(values[a..<b].reduce(0.0) { $0 + Double($1 * $1) } / Double(b - a)) : 0
    }
    // Check the warning against float PCM from the actual mix, including a
    // scoped edit, overlapping lanes, and the native picture fast path.
    var bounds = AudioHeadroom()
    bounds.include(selected: 0.5, remainder: 0.25)
    try require(!bounds.clips(at: 3) && bounds.clips(at: 4), "Headroom includes other tracks rather than positive-dB heuristics")
    var cancellation = AudioHeadroom(); cancellation.include(selected: -0.5, remainder: 1.2)
    try require(cancellation.clips(at: -12) && !cancellation.clips(at: 0), "Opposite-polarity overlap has a lower safe-gain bound")
    var silentSelected = AudioHeadroom(); silentSelected.include(selected: 0, remainder: 1.2)
    try require(silentSelected.clips(at: -40), "Unselected audio overload remains visible when selected audio is silent")
    let signalURL = folder.appendingPathComponent("headroom.caf")
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    let signalFile = try AVAudioFile(forWriting: signalURL, settings: format.settings)
    let signal = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 192000)!; signal.frameLength = 192000
    for frame in 0..<192000 { for channel in 0..<2 { signal.floatChannelData![channel][frame] = Float(0.5 * sin(Double(frame) * .pi / 24)) } }
    try signalFile.write(from: signal)
    let tagged = try await TrackRenderer.timeline(project: project, folder: folder, processedSources: [project.sources[0].id: signalURL])
    let selected = TimelineSelection(audio: [baseline.timeline.audio[0].id], range: EditInterval(1...3))
    let room = try await AudioHeadroom.analyze(asset: tagged.composition, mix: tagged.audioMix!, selection: selected, range: 1...3)
    try require(room.samples > 10000 && !room.clips(at: 6) && room.clips(at: 6.5), "Decoded headroom turns red at the real half-scale overload threshold")
    let audition = try AudioGainMix.replacing(tagged.audioMix!, selection: selected, mode: .audition(6))
    let boosted = TimelineMedia(composition: tagged.composition, videoComposition: tagged.videoComposition, audioMix: audition, playbackVideoComposition: tagged.playbackVideoComposition)
    let boostedSamples = try await sound(boosted, duration: 4)
    try require(abs(rms(boostedSamples, at: 1.5) / rms(boostedSamples, at: 0.5) - pow(10, 6.0 / 20)) < 0.002, "Live audition affects only the selected range with the same gain as export")
    let liveItem = AVPlayerItem(asset: tagged.composition)
    try AudioGainMix.install(tagged.audioMix, on: liveItem)
    let installedMix = liveItem.audioMix
    try require(AudioGainMix.audition(6, selection: selected, on: liveItem), "Live gain control is installed")
    try require(liveItem.audioMix === installedMix, "A live gain step must not replace AVPlayerItem.audioMix")
    let liveMedia = TimelineMedia(composition: tagged.composition, videoComposition: tagged.videoComposition, audioMix: liveItem.audioMix, playbackVideoComposition: tagged.playbackVideoComposition)
    let liveSamples = try await sound(liveMedia, duration: 4)
    try require(zip(liveSamples, boostedSamples).map { abs($0 - $1) }.max() ?? 1 < 0.002, "Persistent live gain tap agrees with export envelopes including range ramps")
    AudioGainMix.audition(nil, selection: selected, on: liveItem)
    let restoredSamples = try await sound(liveMedia, duration: 4)
    let originalSamples = try await sound(tagged, duration: 4)
    try require(zip(restoredSamples, originalSamples).map { abs($0 - $1) }.max() ?? 1 < 0.002, "Cancellation restores original samples without replacing the mix")
    // Change gain after the tap has prepared. All readers retain the same mix;
    // decoded samples, rather than controller state, verify each live update.
    func liveProbe(_ item: AVPlayerItem, update: (Double) -> Void) throws -> [Float] {
        let reader = try AVAssetReader(asset: tagged.composition)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tagged.composition.tracks(withMediaType: .audio), audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
        output.audioMix = item.audioMix; reader.add(output)
        try require(reader.startReading(), "Start live gain sample probe")
        var samples: [Float] = [], stereoError: Float = 0
        while let sample = output.copyNextSampleBuffer() {
            let block = CMSampleBufferGetDataBuffer(sample)!
            var values = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
            _ = values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            for index in stride(from: 0, to: values.count, by: 2) { samples.append(values[index]); stereoError = max(stereoError, abs(values[index] - values[index + 1])) }
            update(sample.presentationTimeStamp.seconds)
        }
        try require(reader.status == .completed && stereoError < 0.000001, "Live gain ramp is identical on both stereo channels")
        return samples
    }
    // Deliberately clip, then return to absolute 0 dB without replacing the tap.
    var overloadStep = 0
    let overloadSamples = try liveProbe(liveItem) { time in
        if time >= 0.5 && overloadStep == 0 { AudioGainMix.audition(12, selection: selected, on: liveItem); overloadStep = 1 }
        if time >= 1.5 && overloadStep == 1 { AudioGainMix.audition(0, selection: selected, on: liveItem); overloadStep = 2 }
        if time >= 2.5 && overloadStep == 2 { AudioGainMix.audition(nil, selection: selected, on: liveItem); overloadStep = 3 }
    }
    try require(rms(overloadSamples, at: 1.2) > rms(originalSamples, at: 1.2) * 3.9, "The overload probe actually reaches clipping gain")
    for start in [2.0, 3.0] {
        let a = Int(start * 48000), b = a + 4800
        try require(zip(overloadSamples[a..<b], originalSamples[a..<b]).map { abs($0 - $1) }.max() ?? 1 < 0.000001,
            "Returning to zero after overload restores undistorted original PCM")
    }
    var changedLive = false, cancelledLive = false
    let wholeAudio = TimelineSelection(audio: selected.audio)
    let dynamicSamples = try liveProbe(liveItem) { time in
        if time >= 0.5 && !changedLive { AudioGainMix.audition(-6, selection: wholeAudio, on: liveItem); changedLive = true }
        if time >= 2 && !cancelledLive { AudioGainMix.audition(nil, selection: wholeAudio, on: liveItem); cancelledLive = true }
    }
    try require(abs(rms(dynamicSamples, at: 1.5) / rms(originalSamples, at: 1.5) - pow(10, -6.0 / 20)) < 0.002, "Gain changes reach already-running audio taps")
    try require(zip(dynamicSamples, originalSamples).dropFirst(3 * 48000).map { abs($0 - $1) }.max() ?? 1 < 0.000001, "Cancellation returns every sample exactly to its original level")
    let periods = stride(from: 2400, to: min(dynamicSamples.count - 48, 3 * 48000), by: 48).map { start in dynamicSamples[start..<(start + 48)].map(abs).max() ?? 0 }
    try require(zip(periods, periods.dropFirst()).map { abs($0 - $1) }.max() ?? 1 < 0.04, "A live gain change ramps over multiple sine periods instead of stepping abruptly")
    changedLive = false; cancelledLive = false
    let rangedSamples = try liveProbe(liveItem) { time in
        if time >= 0.5 && !changedLive { AudioGainMix.audition(-6, selection: selected, on: liveItem); changedLive = true }
        if time >= 2 && !cancelledLive { AudioGainMix.audition(nil, selection: selected, on: liveItem); cancelledLive = true }
    }
    try require(zip(rangedSamples, originalSamples).enumerated().filter { $0.offset < 47520 || $0.offset > 144480 }.map { abs($0.element.0 - $0.element.1) }.max() ?? 1 < 0.000001, "Live range changes never alter samples outside the selected window and edge ramp")
    // A long fade on an unselected neighbour must remain sample-identical even
    // when the selected gain changes and cancels in the middle of that fade.
    let neighbourSegments = [
        AudioEnvelopeSegment(start: 0, end: 2, fadeIn: 0.008, fadeOut: 0.008, clipStart: 0, clipEnd: 2, transitionIn: 0, transitionOut: 0, owner: wholeAudio.audio.first),
        AudioEnvelopeSegment(start: 2, end: 4, fadeIn: 0.8, fadeOut: 0.1, clipStart: 2, clipEnd: 4, transitionIn: 0, transitionOut: 0, owner: UUID(), volume: 0.8)
    ]
    let neighbourMix = AVMutableAudioMix(), neighbourParameter = tagged.audioMix!.inputParameters[0].mutableCopy() as! AVMutableAudioMixInputParameters
    neighbourParameter.audioTapProcessor = try CutAudioEnvelope.make(segments: neighbourSegments); neighbourMix.inputParameters = [neighbourParameter]
    AudioGainMix.register(neighbourMix, records: [neighbourParameter.trackID: neighbourSegments])
    let neighbourReference = try await sound(TimelineMedia(composition: tagged.composition, videoComposition: tagged.videoComposition, audioMix: neighbourMix, playbackVideoComposition: tagged.playbackVideoComposition), duration: 4)
    let neighbourItem = AVPlayerItem(asset: tagged.composition); try AudioGainMix.install(neighbourMix, on: neighbourItem)
    AudioGainMix.audition(-6, selection: wholeAudio, on: neighbourItem); changedLive = false; cancelledLive = false
    let neighbourSamples = try liveProbe(neighbourItem) { time in
        if time >= 2.1 && !changedLive { AudioGainMix.audition(6, selection: wholeAudio, on: neighbourItem); changedLive = true }
        if time >= 2.4 && !cancelledLive { AudioGainMix.audition(nil, selection: wholeAudio, on: neighbourItem); cancelledLive = true }
    }
    try require(zip(neighbourSamples, neighbourReference).dropFirst(2 * 48000).map { abs($0 - $1) }.max() ?? 1 < 0.000001, "Live gain smoothing leaves an unselected neighbour's fade unchanged")
    var doubled = project
    var duplicate = doubled.edit.timeline.audio[0]; duplicate.id = UUID(); duplicate.followsVideo = nil
    var doubledEdit = doubled.edit; doubledEdit.timeline.audio.append(duplicate); doubled.commit(doubledEdit)
    let doubleMedia = try await TrackRenderer.timeline(project: doubled, folder: folder, processedSources: [project.sources[0].id: signalURL])
    let doubleRoom = try await AudioHeadroom.analyze(asset: doubleMedia.composition, mix: doubleMedia.audioMix!, selection: selected, range: 1...3)
    try require(!doubleRoom.clips(at: -0.5) && doubleRoom.clips(at: 0.5), "Overlapping sound lowers the available headroom")
    let tile = try await WaveformDetailCache.shared.tile(url: signalURL, index: 0)
    try require(tile.low.count == 4000 && tile.high.count == 4000 && abs((tile.envelope(from: 1.002, to: 1.003)?.1 ?? 0) - 0.5) < 0.001, "Fine waveform decodes actual one-millisecond signed extrema")
    try require(AudioGainGrid.snap(1.24) == 1 && AudioGainGrid.snap(1.26) == 1.5 && AudioGainGrid.snap(90) == 12, "Gain uses repeatable half-decibel steps")
    var scope = baseline.timeline.scoped(selected)
    scope.timeline.setVolume(6, muted: false, selection: scope.selection)
    var committed = project; committed.history = [EditState(timeline: scope.timeline)]; committed.historyCursor = 0
    let committedMedia = try await TrackRenderer.timeline(project: committed, folder: folder, processedSources: [project.sources[0].id: signalURL])
    let committedSamples = try await sound(committedMedia, duration: 4)
    let errorAtGainEdges = zip(committedSamples, boostedSamples).enumerated().filter { (48000..<49000).contains($0.offset) || (144000..<145000).contains($0.offset) }.map { abs($0.element.0 - $0.element.1) }.max() ?? 0
    try require(errorAtGainEdges < 0.002, "Committed range gain and audition have identical click-free edge ramps")
    do {
        _ = try await AudioHeadroom.analyze(asset: tagged.composition, mix: tagged.audioMix!, selection: wholeAudio, range: 12...18)
        try require(false, "A stale selection beyond the preview asset must fail safely")
    } catch ProjectError.invalidMedia { }
    print("PASS: gain headroom, overlaps, scoped audition, fine PCM waveform")
    let native = try await media(baseline)
    var unlinked = baseline
    unlinked.timeline.unlink(unlinked.timeline.entireSelection())
    let separate = try await media(unlinked)
    let reference = try await picture(native, at: 1)
    let separatedPicture = try await picture(separate, at: 1)
    print("TRACK FRAME: unlink difference \(difference(reference, separatedPicture))")
    try require(difference(reference, separatedPicture) < 1, "Unlink keeps picture identical")
    let nativeSound = try await sound(native, duration: 4), unlinkedSound = try await sound(separate, duration: 4)
    try require(abs(rms(nativeSound, at: 1) - rms(unlinkedSound, at: 1)) < 0.0001, "Unlink keeps audio samples and volume unchanged")
    var scenes = baseline.timeline
    scenes.split(at: EditTime(1), selection: scenes.entireSelection())
    scenes.split(at: EditTime(3), selection: scenes.entireSelection())
    scenes.audio[2].muted = true
    func cutAndPaste(_ id: UUID, intoSlot time: EditTime?) -> TrackTimeline {
        var edit = scenes
        let lifted = edit.cutToClipboard(edit.selection(of: id), preserving: .zero)!
        let position = time ?? edit.duration
        let cut = edit.pasteTargets(layout: EditState(timeline: edit).layout).first { $0.time == position }
        edit.paste(lifted.clipboard, at: position, target: cut)
        return edit
    }
    var restored = project; restored.commit(EditState(timeline: cutAndPaste(scenes.video[2].id, intoSlot: EditTime(1))))
    restored = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(restored))
    let reopened = try await media(restored.edit)
    let movie = folder.appendingPathComponent("relocated-scenes.mp4")
    _ = try await MediaRenderer.render(project: restored, folder: folder, destination: movie) { _ in }
    let exportedScenes = AVURLAsset(url: movie), exportFrames = AVAssetImageGenerator(asset: exportedScenes)
    for (time, original) in [(1.0, 3.0), (1.5, 3.5), (2.5, 1.5)] {
        let reference = try await picture(native, at: original)
        let preview = try await picture(reopened, at: time), export = try await picture(exportFrames, at: time)
        try require(difference(reference, preview) < 1 && difference(reference, export) < 4, "Preview and exported picture show the moved source at \(time)")
    }
    let exportedPCM = folder.appendingPathComponent("relocated-audio.caf")
    _ = try await MediaRenderer.processedAudio(asset: exportedScenes, duration: 4, effects: [], outputURL: exportedPCM, mix: nil) { _ in }
    let relocatedAudioFile = try AVAudioFile(forReading: exportedPCM, commonFormat: .pcmFormatFloat32, interleaved: false)
    let relocatedBuffer = AVAudioPCMBuffer(pcmFormat: relocatedAudioFile.processingFormat, frameCapacity: AVAudioFrameCount(relocatedAudioFile.length))!
    try relocatedAudioFile.read(into: relocatedBuffer)
    let exportedSound = Array(UnsafeBufferPointer(start: relocatedBuffer.floatChannelData![0], count: Int(relocatedBuffer.frameLength)))
    for samples in [try await sound(reopened, duration: 4), exportedSound] {
        try require(rms(samples, at: 0.5) > 0.02 && rms(samples, at: 1.5) < 0.001 && rms(samples, at: 2.5) > 0.02,
                    "The muted scene moves in sync in the preview mix and the encoded soundtrack")
    }
    print("PASS: pinned relocation after reopening - exact first inserted picture, subsequent scenes and audio in preview and export")
    for prepend in [true, false] {
        let id = scenes.video[prepend ? 2 : 0].id
        var candidate = project; candidate.commit(EditState(timeline: cutAndPaste(id, intoSlot: prepend ? .zero : nil)))
        let url = folder.appendingPathComponent(prepend ? "prepend.mp4" : "append.mp4")
        _ = try await MediaRenderer.render(project: candidate, folder: folder, destination: url) { _ in }
        let asset = AVURLAsset(url: url), frames = AVAssetImageGenerator(asset: asset)
        let duration = try await asset.load(.duration).seconds
        try require(abs(duration - 4) < 0.01, "Moving a linked scene to the edge keeps the exported duration")
        let lastFrame = 1.0 / 30
        for (output, source) in [(0.0, prepend ? 3.0 : 1.0), (4.0 - lastFrame, (prepend ? 3.0 : 1.0) - lastFrame)] {
            let actual = try await picture(frames, at: output), expected = try await picture(native, at: source)
            try require(difference(actual, expected) < 4, "Export shows the right first and last frames after pasting at the \(prepend ? "start" : "end")")
        }
    }
    print("PASS: first and last exported frames after prepending and appending linked scenes")
    var splitAudio = unlinked
    splitAudio.timeline.split(at: EditTime(2), selection: TimelineSelection(audio: [splitAudio.timeline.audio[0].id]))
    let splitSound = try await sound(media(splitAudio), duration: 4)
    try require(abs(rms(splitSound, at: 1.994, duration: 0.012) / rms(nativeSound, at: 1.994, duration: 0.012) - 1) < 0.01,
                "Splitting continuous independent audio introduces no fade or volume dip")
    print("TRACK MEDIA: native and independent picture/sound parity")
    var gap = unlinked
    gap.timeline.move(TimelineSelection(video: [gap.timeline.video[0].id]), by: EditTime(1))
    let gapMedia = try await media(gap)
    let black = try await picture(gapMedia, at: 0.5)
    try require(black.enumerated().filter { $0.offset % 4 != 3 }.allSatisfy { $0.element < 3 }, "Unlinked video move leaves black gap")
    let moved = try await picture(gapMedia, at: 2)
    try require(difference(reference, moved) < 1, "Moved picture maps to exact source frame")
    let gapSound = try await sound(gapMedia, duration: 5)
    try require(rms(gapSound, at: 0.5) > 0.02 && rms(gapSound, at: 4.5) < 0.0001, "Detached sound stays in original position under video gap")
    var soundOnly = unlinked
    soundOnly.timeline.remove(TimelineSelection(video: [soundOnly.timeline.video[0].id]))
    let audioMedia = try await media(soundOnly)
    let audioBlack = try await picture(audioMedia, at: 1)
    try require(audioBlack.enumerated().filter { $0.offset % 4 != 3 }.allSatisfy { $0.element < 3 }, "Audio-only project has a black canvas")
    let audioSamples = try await sound(audioMedia, duration: 4)
    try require(rms(audioSamples, at: 1) > 0.02, "Deleting video preserves independently playable audio")
    print("TRACK MEDIA: black gaps, moved source frame, audio-only playback")
    var overlap = baseline
    var other = overlap.timeline.video[0]; other.content.id = UUID(); other.occurrenceID = UUID(); other.start = EditTime(1); other.layer = 10
    other.content.color = ColorSettings(look: .mono)
    overlap.timeline.video.append(other)
    let overlapping = try await media(overlap)
    let gray = try await picture(overlapping, at: 2)
    var channelSpread = 0.0
    for i in stride(from: 0, to: gray.count, by: 4) {
        channelSpread += Double(max(gray[i], gray[i+1], gray[i+2])) - Double(min(gray[i], gray[i+1], gray[i+2]))
    }
    let saturation = channelSpread / Double(160 * 90)
    try require(saturation < 3, "Foreground video covers background by default")
    let ids = Set(overlap.timeline.video.map(\.id))
    var back = VideoPlacement(); back.order = 10
    var front = VideoPlacement(); front.order = 0
    overlap.timeline.placements = [VideoPlacementRegion(participants: ids, videos: [baseline.clips[0].id: back, other.id: front])]
    let orderedMedia = try await media(overlap)
    let reordered = try await picture(orderedMedia, at: 2)
    let sourceTwo = try await picture(native, at: 2)
    try require(difference(reordered, sourceTwo) < 1, "Placement order changes which video covers the other")
    var cropped = overlap
    back.order = 0; front.order = 10
    front.edgeCrop = PlacementEdgeCrop(left: 0.2, right: 0.15, top: 0.2, bottom: 0.1)
    cropped.timeline.placements = [VideoPlacementRegion(participants: ids, videos: [baseline.clips[0].id: back, other.id: front])]
    let croppedMedia = try await media(cropped), croppedFrame = try await picture(croppedMedia, at: 2)
    var expectedCrop = reordered
    for y in 18..<81 { for x in 32..<136 { for channel in 0..<4 { let i = (y * 160 + x) * 4 + channel; expectedCrop[i] = gray[i] } } }
    // The 640x360 render is downsampled to 160x90. Only the one-pixel
    // transition at a clip edge may differ due to interpolation/extent rounding.
    var interiorError = 0.0, interiorCount = 0
    var exteriorError = 0.0, exteriorCount = 0
    for y in 0..<90 { for x in 0..<160 { for channel in 0..<3 {
        let i = (y * 160 + x) * 4 + channel
        if (20..<79).contains(y) && (34..<134).contains(x) {
            interiorError += abs(Double(croppedFrame[i]) - Double(gray[i])); interiorCount += 1
        } else if y < 16 || y >= 83 || x < 30 || x >= 138 {
            exteriorError += abs(Double(croppedFrame[i]) - Double(reordered[i])); exteriorCount += 1
        }
    } } }
    try require(interiorError / Double(interiorCount) < 0.1 && exteriorError / Double(exteriorCount) < 0.1,
                "Cropping leaves exact interior pixels and reveals unaltered lower video on all four sides")
    try require(difference(croppedFrame, expectedCrop) < 1, "Crop boundaries agree within the downsampled edge tolerance")
    var cropExport = project; cropExport.history = [cropped]; cropExport.historyCursor = 0
    let cropURL = folder.appendingPathComponent("placement-crop.mp4")
    _ = try await MediaRenderer.render(project: cropExport, folder: folder, destination: cropURL) { _ in }
    let reader = AVAssetImageGenerator(asset: AVURLAsset(url: cropURL))
    reader.requestedTimeToleranceBefore = .zero; reader.requestedTimeToleranceAfter = .zero
    let exportedFrame = try await reader.image(at: CMTime(seconds: 2, preferredTimescale: 240000)).image
    var exportedCrop = [UInt8](repeating: 0, count: 160 * 90 * 4)
    exportedCrop.withUnsafeMutableBytes { raw in
        let context = CGContext(data: raw.baseAddress, width: 160, height: 90, bitsPerComponent: 8, bytesPerRow: 640, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(exportedFrame, in: CGRect(x: 0, y: 0, width: 160, height: 90))
    }
    try require(difference(exportedCrop, croppedFrame) < 2, "Placement edge crop preview and encoded export agree")
    print("TRACK MEDIA: edge crop preserves picture transform, reveals lower video and matches export")
    print("TRACK MEDIA: default covering and Placement order")
    var enhanced = baseline
    enhanced.timeline.enhance([AudioEffect(kind: .gain, amount: -12)], selection: enhanced.timeline.entireSelection(range: EditInterval(1...2)))
    let enhancedMedia = try await media(enhanced, processed: true)
    let enhancedSound = try await sound(enhancedMedia, duration: 4)
    try require(abs(rms(enhancedSound, at: 0.5) / rms(nativeSound, at: 0.5) - 1) < 0.01, "Audio before enhancement stays original")
    try require(abs(rms(enhancedSound, at: 1.3) / rms(nativeSound, at: 1.3) - pow(10, -12.0 / 20)) < 0.01, "Scoped enhancement applies only inside region")
    try require(abs(rms(enhancedSound, at: 2.5) / rms(nativeSound, at: 2.5) - 1) < 0.01, "Audio after enhancement returns to original")
    print("TRACK MEDIA: scoped audio chain")
    var exporting = project; exporting.history = [gap]; exporting.historyCursor = 0
    let output = folder.appendingPathComponent("moved.mp4")
    _ = try await MediaRenderer.render(project: exporting, folder: folder, destination: output) { _ in }
    let exported = AVURLAsset(url: output)
    let duration = try await exported.load(.duration).seconds
    try require(abs(duration - 5) < 0.04, "Export retains moved picture and audio tail duration")
    for style in [TransitionStyle.dissolve, .fadeColor, .still, .split, .hitchcock] {
        var edit = TimelineEditing.split(baseline, at: 2)
        edit = edit.settingTransition(ClipTransition(style: style, duration: style == .still ? 0.5 : 1), at: 1)
        let rendered = try await media(edit)
        let join = edit.layout.joins[1]
        _ = try await picture(rendered, at: min(edit.duration - 0.05, join.time))
        try await assertTransitionCoverage(rendered, duration: edit.duration)
    }
    print("PASS: independent media preview, audio gaps, overlaps, scoped enhancement, export and transition coverage")
}


func exportAudioLevelTests(root: URL) async throws {
    let folder = root.appendingPathComponent("export-audio-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: root.appendingPathComponent("source.mp4"), to: folder.appendingPathComponent("source.mp4"))
    var project = Project(title: "Export audio level")
    project.append(SourceMedia(filename: "source.mp4", duration: 4))
    let sourceID = project.sources[0].id
    try await volumeFadeTests(project: project, folder: folder)
    let signalURL = folder.appendingPathComponent("signal.caf")
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    let file = try AVAudioFile(forWriting: signalURL, settings: format.settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 192000)!; buffer.frameLength = 192000
    for frame in 0..<192000 { for channel in 0..<2 {
        buffer.floatChannelData![channel][frame] = Float((frame >= 120000 && frame < 144000 ? 1.5 : 0.4) * sin(Double(frame) * .pi / 24))
    } }
    try file.write(from: buffer)
    func level(_ edit: EditState) async throws -> Float {
        var candidate = project; candidate.history = [edit]; candidate.historyCursor = 0
        let media = try await TrackRenderer.timeline(project: candidate, folder: folder, processedSources: [sourceID: signalURL])
        return try await ExportAudioLevel.peak(asset: media.composition, mix: media.audioMix, duration: edit.duration)
    }
    let full = try await level(project.edit)
    try require(abs(full - 1.5) < 0.001, "Final float mix preserves peaks above full scale for the check")
    let quiet = EditState(clips: [TimelineClip(sourceID: sourceID, start: 0, end: 2)])
    let trimmed = try await level(quiet)
    try require(abs(trimmed - 0.4) < 0.001, "Removed source peaks never warn on the remaining quiet range")
    var reduced = project.edit; reduced.timeline.audio[0].volumeDB = -12
    let lower = try await level(reduced)
    try require(abs(lower - 1.5 * pow(10, -12.0/20)) < 0.001, "Volume reduction is included in export measurement")
    var muted = project.edit; muted.timeline.audio[0].muted = true
    let silent = try await level(muted)
    try require(silent == 0, "Muted source peaks do not warn")
    var mutedProject = project; mutedProject.commit(muted)
    let mutedMedia = try await TrackRenderer.timeline(project: mutedProject, folder: folder)
    guard let mutedMix = mutedMedia.audioMix else { throw ProjectError.invalidMedia }
    let mutedHeadroom = try await AudioHeadroom.analyze(asset: mutedMedia.composition, mix: mutedMix,
        selection: muted.timeline.entireSelection(), range: 0...muted.duration)
    try require(mutedHeadroom.samples == 0 && !mutedHeadroom.clips(at: 12), "A fully muted volume preview reports silence")
    let mutedURL = folder.appendingPathComponent("muted.mp4")
    _ = try await MediaRenderer.render(project: mutedProject, folder: folder, destination: mutedURL) { _ in }
    let movie = AVURLAsset(url: mutedURL)
    let movieDuration = try await movie.load(.duration).seconds
    let videoTracks = try await movie.loadTracks(withMediaType: .video)
    let exportedPeak = try await ExportAudioLevel.peak(asset: movie, mix: nil, duration: movieDuration)
    try require(!videoTracks.isEmpty && abs(movieDuration - muted.duration) < 0.05 && exportedPeak == 0,
                "Muting the entire project exports the full picture in silence")
    var overlap = quiet
    for _ in 0..<2 { var copy = overlap.timeline.audio[0]; copy.id = UUID(); overlap.timeline.audio.append(copy) }
    let sum = try await level(overlap)
    try require(abs(sum - 1.2) < 0.001, "Overlapping zero-gain tracks can exceed full scale when summed")
    overlap.timeline.audio[0].muted = true
    let remaining = try await level(overlap)
    try require(abs(remaining - 0.8) < 0.001, "Muting one overlapping track preserves the others at their original levels")
    var transition = EditState(clips: [TimelineClip(sourceID: sourceID, start: 0, end: 1), TimelineClip(sourceID: sourceID, start: 1, end: 2)])
    transition = transition.settingTransition(ClipTransition(duration: 0.5), at: 1)
    let blended = try await level(transition)
    try require(blended <= 0.401, "Transition fade envelopes are included, not naive peak addition")
    // Exercise the complete cache -> mix -> MP4 -> receipt path. The source
    // cache stays loud after lowering Volume; the new exported mix does not.
    var boosted = project.edit
    boosted.timeline.enhance([AudioEffect(kind: .gain, amount: 12), AudioEffect(kind: .gain, amount: 12)], selection: boosted.timeline.entireSelection())
    project.commit(boosted)
    let prepared = try await SourceMediaCache.shared.prepared(project: project, folder: folder) { _ in }
    try require(prepared.peak > 1, "Regression fixture has an over-scale cached source")
    let output = folder.appendingPathComponent("loud.mp4")
    let loud = try await MediaRenderer.render(project: project, folder: folder, destination: output) { _ in }.audioPeak ?? .nan
    func receipt(_ url: URL) throws -> ExportReceipt { try JSONDecoder().decode(ExportReceipt.self, from: Data(contentsOf: url.deletingPathExtension().appendingPathExtension("json"))) }
    let loudReceipt = try receipt(output)
    try require(loud > 1 && loudReceipt.audioWarning != nil && loudReceipt.audioPeak == loud, "Warning is attached to the measured export receipt")
    boosted.timeline.audio[0].volumeDB = -12; project.commit(boosted)
    let correctedURL = folder.appendingPathComponent("corrected.mp4")
    let corrected = try await MediaRenderer.render(project: project, folder: folder, destination: correctedURL) { _ in }.audioPeak ?? .nan
    let correctedReceipt = try receipt(correctedURL)
    try require(corrected < 1 && correctedReceipt.audioWarning == nil, "Re-export after reducing Volume clears the warning despite loud cached source")
    let repeatCheck = try await ExportAudioLevel.peak(asset: prepared.media.composition, mix: prepared.media.audioMix, duration: 4)
    try require(abs(repeatCheck-loud) < 0.001, "Measurement has independent tap clocks and does not change later rendering")
    var old = correctedReceipt; old.audioPeak = nil
    try require(old.audioWarning == nil, "An older/unmeasured export cannot produce an unverified warning")
    print("PASS: final export audio levels, trims, mute, volume, overlaps, transitions, receipt persistence and corrected re-export")
}

private func volumeFadeTests(project: Project, folder: URL) async throws {
    var base = project.edit
    base.timeline.split(at: EditTime(1.5), selection: base.timeline.entireSelection())
    base.timeline.split(at: EditTime(2.5), selection: base.timeline.entireSelection())
    var edit = base
    let all = edit.timeline.entireSelection().audio
    let intro = AudioFadeEdge.fadeIn.index(in: edit.timeline.audio, selected: all)!
    let outro = AudioFadeEdge.fadeOut.index(in: edit.timeline.audio, selected: all)!
    try require(intro == 0 && outro == 2, "Whole-project fade targets are the first and last audio clips")
    edit.timeline.audio[intro].setFade(.fadeIn, seconds: 1)
    edit.timeline.audio[outro].setFade(.fadeOut, seconds: 1)
    try require(edit.timeline.audio[1] == base.timeline.audio[1], "Intermediate audio keeps its level")
    var project = project; project.commit(edit)
    let reopened = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
    try require(reopened.edit == project.edit, "Volume fades persist when the project is reopened")
    let region = edit.toolRegions.first { $0.tool == .volume && $0.clipID == edit.timeline.audio[0].id }!
    let removed = edit.removingTool(edit.request(for: region))
    try require(removed.timeline.audio[0].fadeIn == nil && removed.timeline.audio[2].fadeOut != nil, "Remove clears only the chosen volume region")
    var undo = project; undo.undo(); undo.redo()
    try require(undo.edit == project.edit, "Undo and Redo restore fades together")

    var tied = edit.timeline.audio
    tied[1].start = .zero; tied[2].start = .zero
    try require(AudioFadeEdge.fadeIn.index(in: tied, selected: all) == 0 && AudioFadeEdge.fadeOut.index(in: tied, selected: all) == 0, "Ties target a single lowest-numbered audio clip")
    tied[2].start = EditTime(0.1); tied[1].start = EditTime(0.4)
    try require(AudioFadeEdge.fadeOut.index(in: tied, selected: all) == 2, "The latest end wins even if a shorter clip starts later")
    let cut = EditTime(0.4)
    var split = edit; split.timeline.split(at: cut, selection: split.timeline.entireSelection())
    let after = split.timeline.audio.first { $0.start == cut }!
    try require(abs((after.fadeIn?.gain(0) ?? 0) - 0.4) < 0.00001, "Splitting midway through a fade preserves its level and slope")
    let range = base.timeline.scoped(TimelineSelection(audio: all, range: EditInterval(0.4...3.3)))
    let rangeIn = AudioFadeEdge.fadeIn.index(in: range.timeline.audio, selected: range.selection.audio)!
    let rangeOut = AudioFadeEdge.fadeOut.index(in: range.timeline.audio, selected: range.selection.audio)!
    try require(range.timeline.audio[rangeIn].start == EditTime(0.4) && range.timeline.audio[rangeOut].end == EditTime(3.3), "Marked ranges target their actual audible edges")

    func energies(_ asset: AVAsset, mix: AVAudioMix?) async throws -> [Double] {
        let out = folder.appendingPathComponent(UUID().uuidString + ".caf")
        _ = try await MediaRenderer.processedAudio(asset: asset, duration: edit.duration, effects: [], outputURL: out, mix: mix) { _ in }
        let file = try AVAudioFile(forReading: out, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let pcm = buffer.floatChannelData![0], rate = file.processingFormat.sampleRate
        return [0.1, 0.4, 0.8, 1.7, 2.2, 3.2, 3.6, 3.9].map { time in
            let start = Int((time - 0.01) * rate), end = Int((time + 0.01) * rate)
            return sqrt((start..<end).reduce(0.0) { $0 + Double(pcm[$1] * pcm[$1]) } / Double(end - start))
        }
    }
    // Measure the saved AAC movie as well as the exact preview mix, including a cut inside a fade.
    project.commit(split)
    let media = try await TrackRenderer.timeline(project: project, folder: folder)
    let preview = try await energies(media.composition, mix: media.audioMix)
    let movie = folder.appendingPathComponent("volume-fades.mp4")
    _ = try await MediaRenderer.render(project: project, folder: folder, destination: movie) { _ in }
    let exported = try await energies(AVURLAsset(url: movie), mix: nil)
    for levels in [preview, exported] {
        let flat = levels[3]
        try require(flat > 0.01 && zip(levels, [0.1, 0.4, 0.8, 1, 1, 0.8, 0.4, 0.1]).allSatisfy {
            abs($0.0 / flat - $0.1) < 0.045
        }, "The first/last clips fade linearly in actual audio, including across split and encoded playback: \(levels)")
    }
    print("PASS: edge-only audio fades, saved project, range, overlaps, edit navigation, split ramp continuity, rendered preview and exported MP4")
}

func audioImportCensorTests(root: URL) async throws {
    let folder = root.appendingPathComponent("audio-censor-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    let original = folder.appendingPathComponent("Original voice.wav")
    do {
        let file = try AVAudioFile(forWriting: original, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 192000)!; buffer.frameLength = 192000
        for frame in 0..<192000 { for channel in 0..<2 { buffer.floatChannelData![channel][frame] = Float(0.25 * sin(Double(frame) * 2 * .pi * 200 / 48000)) } }
        try file.write(from: buffer)
    }
    let originalBytes = try Data(contentsOf: original)
    let work = folder.appendingPathComponent("Processing")
    let imported = try await ImportedAudioFile.stage(original, in: work) { _ in }
    try require(imported.source.audioOnly == true && imported.source.originalName == "Original voice.wav", "Import records audio type and original name")
    try require(abs(imported.source.duration - 4) < 0.0001 && imported.source.sha256 != nil, "Import validates duration and fingerprints original bytes")
    let copiedBytes = try Data(contentsOf: imported.url)
    try require(copiedBytes == originalBytes, "Audio import does not transcode or change the original")
    let retainedBytes = try Data(contentsOf: original)
    try require(retainedBytes == originalBytes, "Audio import leaves Files original untouched")
    try FileManager.default.moveItem(at: imported.url, to: folder.appendingPathComponent(imported.source.filename))
    let bad = folder.appendingPathComponent("broken.wav"); try Data("Not audio".utf8).write(to: bad)
    do { _ = try await ImportedAudioFile.stage(bad, in: work) { _ in }; throw NSError(domain: "Test", code: 1) }
    catch AudioImportError.unreadable {} catch { if (error as NSError).domain == "Test" { throw error } }
    let stagingFiles = try FileManager.default.contentsOfDirectory(atPath: work.path)
    try require(stagingFiles.isEmpty, "Failed import cleans only its staging file")
    // Exercise compressed and uncompressed containers with actual decoders.
    for (extensionName, settings) in [
        ("m4a", [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128000] as [String: Any]),
        ("aiff", [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: true] as [String: Any])
    ] {
        let url = folder.appendingPathComponent("Import test." + extensionName)
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            let input = try AVAudioFile(forReading: original)
            let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 192000)!
            try input.read(into: buffer); try file.write(from: buffer)
        }
        let copy = try await ImportedAudioFile.stage(url, in: work) { _ in }
        try require(abs(copy.source.duration - 4) < 0.1, "Compressed/uncompressed audio import preserves duration")
        try FileManager.default.removeItem(at: copy.url)
    }
    var project = Project(title: "Audio censor QA")
    project.sources = [imported.source]
    var baseline = project.edit
    let id = baseline.timeline.insertAudio(imported.source, at: .zero)
    project.commit(baseline)
    project.undo(); try require(project.edit.timeline.audio.isEmpty, "Undo audio import removes the item")
    project.redo(); try require(project.edit.timeline.audio.count == 1, "Redo audio import restores the item")
    var overlapping = baseline.timeline
    overlapping.insertAudio(imported.source, at: EditTime(1))
    try require(overlapping.audio[0] == baseline.timeline.audio[0] && overlapping.duration == EditTime(5), "Audio imports overlay without shifting existing items")

    let scope = TimelineSelection(audio: [id], range: EditInterval(1...2))
    let settings = AudioCensorSettings()
    var edit = baseline
    let effectID = UUID()
    edit.timeline.censor(settings, selection: scope, effectID: effectID)
    project.commit(edit); try project.validate()
    try require(project.schemaVersion == 9, "Older builds must reject rather than silently drop censor edits")
    let encoded = try JSONEncoder().encode(project)
    let decoded = try JSONDecoder().decode(Project.self, from: encoded)
    try require(decoded.edit.timeline.audio[0].censors == edit.timeline.audio[0].censors, "Censor survives project persistence")
    var split = edit.timeline
    _ = split.split(at: EditTime(1.5), selection: TimelineSelection(audio: [id]))
    try require(split.audio.count == 2 && split.audio.allSatisfy { $0.censors.count == 1 }, "Splitting preserves censor on both halves")
    let right = split.audio[1].id
    split.censor(nil, selection: TimelineSelection(audio: [right]), removingOnly: effectID)
    try require(split.audio[0].censors.count == 1 && split.audio[1].censors.isEmpty, "Removing a split censor affects only its own audio section")
    split.move(TimelineSelection(audio: [id]), by: EditTime(2))
    try require(split.censorSpans(for: split.audio[0])[0].start == 3, "Censor follows moved audio")
    try split.validate(sources: project.sources)
    let clipboard = edit.timeline.copied(scope)
    var pasted = baseline.timeline; _ = pasted.paste(clipboard, at: EditTime(2))
    try pasted.validate(sources: project.sources)
    try require(pasted.audio.last?.censors.first?.id != effectID, "Pasted censor has independent effect identity")
    var layered = baseline.timeline
    layered.insertAudio(imported.source, at: .zero)
    layered.censor(settings, selection: TimelineSelection(audio: Set(layered.audio.map(\.id)), range: EditInterval(1...2)), effectID: effectID)
    try require(layered.audio.flatMap { layered.censorSpans(for: $0) }.filter { $0.emitsTone }.count == 1, "One censor across overlapping selected tracks emits one beep")
    layered.audio[0].volumeDB = -18
    try require(!layered.censorSpans(for: layered.audio[0])[0].emitsTone && layered.censorSpans(for: layered.audio[1])[0].emitsTone, "The loudest selected track carries a shared beep, independent of UUID ordering")
    var layeredEdit = baseline; layeredEdit.timeline = layered
    let event = layeredEdit.request(for: layeredEdit.toolRegions.first { $0.tool == .censorAudio }!)
    try require(event.targets?.audio.count == 2, "One shared censor badge targets the entire overlapping event")
    var retuned = settings; retuned.frequency = 440
    var retunedEdit = layeredEdit.removingTool(event)
    retunedEdit.timeline.censor(retuned, selection: event.targets!, effectID: effectID)
    try require(retunedEdit.timeline.audio.flatMap { retunedEdit.timeline.censorSpans(for: $0) }.filter { $0.emitsTone }.count == 1, "Editing a shared badge never leaves two different beeps behind")
    try require(retunedEdit.removingTool(event).timeline.audio.allSatisfy { $0.censors.isEmpty }, "Removing a shared badge restores every affected track")
    var bridged = layeredEdit
    bridged.timeline.split(at: EditTime(1.5), selection: TimelineSelection(audio: [bridged.timeline.audio[0].id]))
    for region in bridged.toolRegions.filter({ $0.tool == .censorAudio }) {
        let bridgedRequest = bridged.request(for: region)
        try require(bridgedRequest.targets?.audio.count == 3, "An uncut music bed joins both split voice halves into the same censor event")
        var changed = bridged.removingTool(bridgedRequest)
        changed.timeline.censor(retuned, selection: bridgedRequest.targets!, effectID: effectID)
        let spans = changed.timeline.audio.flatMap { changed.timeline.censorSpans(for: $0) }
        for t in [1.25, 1.75] { try require(spans.filter { $0.emitsTone && $0.start <= t && t < $0.end }.count == 1, "Retuning either split half never stacks old and new tones") }
        try require(changed.removingTool(bridgedRequest).timeline.audio.allSatisfy { $0.censors.isEmpty }, "Removing the bridged event leaves no hidden old region")
    }
    var staggered = baseline.timeline
    staggered.insertAudio(imported.source, at: EditTime(1))
    staggered.censor(settings, selection: TimelineSelection(audio: Set(staggered.audio.map(\.id)), range: EditInterval(0.5...3.5)))
    let staggeredSpans: [AudioCensorSpan] = staggered.audio.flatMap { staggered.censorSpans(for: $0) }
    for span in staggeredSpans {
        let sameClock = abs(span.phaseOrigin - 0.5) < 0.00001 && abs(span.envelopeStart - 0.5) < 0.00001 && abs(span.envelopeEnd - 3.5) < 0.00001
        try require(sameClock, "Clips beginning inside one censor share its phase and envelope clock")
    }
    var changedTone = settings; changedTone.frequency = 2000
    layered.censor(changedTone, selection: TimelineSelection(audio: [layered.audio[1].id], range: EditInterval(1...2)), effectID: effectID)
    try require(layered.audio.flatMap { layered.censorSpans(for: $0) }.filter { $0.emitsTone }.count == 2, "Editing one overlapping track's censor must remain audible independently")
    var linked = TrackTimeline(clips: [TimelineClip(sourceID: imported.source.id, start: 0, end: 4)])
    linked.censor(settings, selection: TimelineSelection(audio: [linked.audio[0].id], range: EditInterval(1...2)))
    var faster = linked.projectedClips; faster[0].speed = SpeedSettings(rate: 2)
    linked.replaceVideoContents(faster)
    try require(linked.audio[0].censors[0].interval == EditInterval(0.5...1), "Censor follows speech through a linked speed change")
    try linked.validate(sources: project.sources)
    var reunited = edit.timeline
    reunited.split(at: EditTime(1.5), selection: reunited.entireSelection())
    let beforeJoin = reunited.audio
    reunited = try reunited.joining(reunited.entireSelection()).timeline
    try require(reunited.audio == beforeJoin, "Horizontal linking keeps both split censor regions intact")
    let archive = folder.appendingPathComponent("audio-project.zip")
    try await ProjectArchive.export(project, folder: folder, destination: archive) { _ in }
    let restored = try await ProjectArchive.restore(archive, disk: ProjectDisk(root: folder.appendingPathComponent("Restored"))) { _ in }
    try require(restored.sources[0].audioOnly == true && restored.edit.timeline.audio[0].censors == project.edit.timeline.audio[0].censors, "Project archive restores imported audio and censor edits")

    func samples(_ edit: EditState, exported: Bool = false) async throws -> [Float] {
        var candidate = project; candidate.history = [edit]; candidate.historyCursor = 0
        let asset: AVAsset, mix: AVAudioMix?
        if exported {
            let url = folder.appendingPathComponent(UUID().uuidString + ".mp4")
            _ = try await MediaRenderer.render(project: candidate, folder: folder, destination: url) { _ in }
            asset = AVURLAsset(url: url); mix = nil
        } else {
            let media = try await TrackRenderer.timeline(project: candidate, folder: folder)
            asset = media.composition; mix = media.audioMix
        }
        let out = folder.appendingPathComponent(UUID().uuidString + ".caf")
        _ = try await MediaRenderer.processedAudio(asset: asset, duration: edit.duration, effects: [], outputURL: out, mix: mix) { _ in }
        let file = try AVAudioFile(forReading: out, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }
    let clean = try await samples(baseline), censored = try await samples(edit), again = try await samples(edit)
    var splitEdit = edit
    _ = splitEdit.timeline.split(at: EditTime(1.5), selection: TimelineSelection(audio: [id]))
    let splitSound = try await samples(splitEdit)
    let halfRequest = splitEdit.request(for: splitEdit.toolRegions.first { $0.tool == .censorAudio }!)
    try require(halfRequest.targets?.audio.count == 1, "Censor badge grouping does not reach across adjacent split sections")
    try require(zip(censored, splitSound).allSatisfy { abs($0 - $1) < 0.00002 }, "A pure split inside a censor does not restart its oscillator or envelope")
    try require(censored == again, "Censor PCM is independent of decoder callback order")
    try require(zip(clean[4800..<43200], censored[4800..<43200]).allSatisfy { abs($0 - $1) < 0.00001 }, "Audio outside censor remains unchanged")
    for frame in 57600..<86400 {
        let expected = settings.amplitude * sin(Double(frame - 48000) * 2 * .pi * 1000 / 48000)
        try require(abs(Double(censored[frame]) - expected) < 0.00002, "Censor replaces source with exact 1 kHz -18 dBFS waveform")
    }
    var pulse = settings; pulse.envelope = .pulse
    var pulsed = baseline; pulsed.timeline.censor(pulse, selection: scope)
    let pulseSamples = try await samples(pulsed)
    try require(pulseSamples[58320..<58800].allSatisfy { abs($0) < 0.00001 }, "Pulse gaps remain silent, never reveal original words")
    let output = try await samples(edit, exported: true)
    func component(_ values: [Float], hz: Double) -> Double {
        let range = 57600..<86400
        var real = 0.0, imaginary = 0.0
        for i in range { let phase = Double(i) * 2 * .pi * hz / 48000; real += Double(values[i]) * cos(phase); imaginary += Double(values[i]) * sin(phase) }
        return 2 * hypot(real, imaginary) / Double(range.count)
    }
    try require(abs(component(output, hz: 1000) - settings.amplitude) < 0.005, "Encoded export retains censor frequency and level")
    try require(component(output, hz: 200) < 0.0002, "Encoded export does not retain censored source tone")
    for waveform in CensorWaveform.allCases {
        var value = settings; value.waveform = waveform
        let peak = (0..<4800).map { abs(value.oscillator(time: Double($0) / 48000, sampleRate: 48000)) }.max()!
        try require(peak <= 1.000001 && peak > 0.6, "All waveforms have bounded useful peak amplitude")
    }
    print("PASS: audio import, independent overlay, undo, staging cleanup; censor PCM, pulse silence, determinism, split/move/copy, overlap ownership and encoded export")
}
