@preconcurrency import AVFoundation
import CoreImage

final class TrackVideoInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = true
    let containsTweening = true
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    var requiredSourceTrackIDs: [NSValue]? { Array(Set(layers.values.filter { !$0.readsSourceFrames && $0.frozenSourceTime == nil }.map(\.trackID))).map { NSNumber(value: $0) } }
    let layers: [UUID: VideoToolInstruction]
    let order: [UUID]
    let placements: [UUID: VideoPlacement]
    let transition: TimelineTransition?
    let canvas: CGSize
    let hdr: Bool
    var subtitles: SubtitleRenderTrack?
    init(range: CMTimeRange, layers: [UUID: VideoToolInstruction], order: [UUID], placements: [UUID: VideoPlacement], transition: TimelineTransition?, canvas: CGSize, hdr: Bool) {
        timeRange = range; self.layers = layers; self.order = order; self.placements = placements
        self.transition = transition; self.canvas = canvas; self.hdr = hdr
    }
}

/// All edit positions come from TrackTimeline. The existing source renderer is
/// reused only to prepare a single item's effects, never to arrange the project.
enum TrackRenderer {
    static func time(_ value: EditTime) -> CMTime { CMTime(value: value.ticks, timescale: CMTimeScale(EditTime.scale)) }
    static func audioKey(source: UUID, effects: [AudioEffect]) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return source.uuidString + "|" + ((try? encoder.encode(effects.filter(\.enabled)).base64EncodedString()) ?? "")
    }
    static func timeline(project: Project, folder: URL, processedSources: [UUID: URL] = [:], processedRegions: [String: URL] = [:],
                         canvasSize: CGSize? = nil, framesPerSecond: Int = 30, stabilization: Bool = true, stabilizationPlans: [UUID: StabilizationPlan] = [:],
                         videoProgress: @escaping @Sendable (Double) -> Void = { _ in }, forceCustom: Bool = false,
                         includeBackgroundAudio: Bool = true, previewDiagnostics: Bool = false, bypassVideoEffects: Bool = false,
                         audioPreviewRange: ClosedRange<Double>? = nil, processedWindows: [String: [AudioPreviewWindow]] = [:],
                         effectPreparation: VideoEffectPreparation = .final) async throws -> TimelineMedia {
        let timeline = project.edit.timeline
        for item in timeline.video { for lut in item.content.color?.lutAssets ?? [] { _ = try LUTAssets.load(lut, folder: folder) } }
        guard timeline.duration > .zero else { throw ProjectError.emptyTimeline }
        let canvas: CGSize
        if let size = canvasSize ?? project.edit.outputSize { canvas = size }
        else if !timeline.video.isEmpty { canvas = try await MediaRenderer.canvas(project: project, folder: folder) }
        else { canvas = CGSize(width: 1920, height: 1080) }
        // Preserve the native, inexpensive path when the compiler proves this is
        // exactly one ordinary linked sequence. This is an optimization only.
        let sequential = TimelineLayout(clips: project.edit.clips)
        let native = timeline.subtitles == nil && timeline.transitions.isEmpty && timeline.placements.isEmpty && timeline.generated.isEmpty
            && timeline.audio.count == timeline.video.count && timeline.video.count == sequential.placements.count
            && zip(timeline.video, sequential.placements).allSatisfy { $0.start == EditTime($1.start) }
            && timeline.audio.allSatisfy { audio in
                guard let video = timeline.video.first(where: { $0.id == audio.followsVideo }) else { return false }
                return audio.start == video.start && audio.mapping == video.mapping && audio.volumeDB == 0 && !audio.muted
                    && (audio.enhancements.isEmpty || !processedSources.isEmpty && processedRegions.isEmpty)
            }
        if native {
            let source = try await MediaRenderer.sourceTimeline(project: project, folder: folder, processedSources: processedSources, canvasSize: canvas, framesPerSecond: framesPerSecond,
                stabilization: stabilization, stabilizationPlans: stabilizationPlans, videoProgress: videoProgress, forceCustom: forceCustom,
                includeBackgroundAudio: false, previewDiagnostics: previewDiagnostics, bypassVideoEffects: bypassVideoEffects, effectPreparation: effectPreparation)
            // Keep the native picture path, but use the same sample envelopes for
            // audio audition, headroom analysis and export on every timeline.
            for track in source.composition.tracks(withMediaType: .audio) { source.composition.removeTrack(track) }
            let mix = try await audioMix(timeline, project: project, folder: folder, composition: source.composition,
                processedSources: processedSources, processedRegions: processedRegions, includeBackgroundAudio: includeBackgroundAudio,
                previewRange: audioPreviewRange, processedWindows: processedWindows)
            installTitleClocks(project.edit, in: source.videoComposition)
            return TimelineMedia(composition: source.composition, videoComposition: source.videoComposition, audioMix: mix,
                playbackVideoComposition: source.playbackVideoComposition, hdr: source.hdr, effectAnalysisPending: source.effectAnalysisPending)
        }
        let composition = AVMutableComposition()
        var videoTracks: [AVMutableCompositionTrack] = [], videoEnds: [EditTime] = []
        var layers: [(UUID, VideoToolInstruction)] = []
        var hdr = false
        for (number, item) in timeline.video.sorted(by: { $0.start < $1.start }).enumerated() {
            try Task.checkCancellation()
            let freezeRelation = timeline.transitions.first { $0.settings.style == .still && $0.outgoing == item.id }
            let freeze = freezeRelation.map { relation -> EditInterval in
                let timing = TransitionTiming(relation.settings, factor: relation.factor, edge: relation.incoming == nil ? 1 : 0)
                return EditInterval(relation.origin, relation.origin + EditTime(timing.videoDuration))
            }
            let finish = max(item.end, freeze?.end ?? item.end)
            let lane: Int
            if let free = videoEnds.firstIndex(where: { $0 <= item.start }) { lane = free }
            else {
                guard let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw ProjectError.invalidMedia }
                lane = videoTracks.count; videoTracks.append(track); videoEnds.append(.zero)
            }
            videoEnds[lane] = finish
            var child = project
            child.history = [EditState(clips: [item.content], outputSize: canvas)]; child.historyCursor = 0
            let media = try await MediaRenderer.sourceTimeline(project: child, folder: folder, canvasSize: canvas, framesPerSecond: framesPerSecond, stabilization: stabilization,
                stabilizationPlans: stabilizationPlans, videoProgress: { videoProgress((Double(number) + $0) / Double(max(1, timeline.video.count))) },
                forceCustom: true, includeBackgroundAudio: false, previewDiagnostics: previewDiagnostics, bypassVideoEffects: bypassVideoEffects,
                effectPreparation: effectPreparation)
            hdr = hdr || media.hdr
            guard let sourceTrack = media.composition.tracks(withMediaType: .video).first else { throw ProjectError.invalidMedia }
            let childLayers = media.videoComposition.instructions.compactMap { $0 as? VideoToolInstruction }
            let localEnd = childLayers.last?.timeRange.end ?? .zero
            guard localEnd > .zero else { throw ProjectError.invalidMedia }
            let start = time(item.start), end = time(item.end)
            let freezeStart = freeze.map { max(item.start, min(item.end, $0.start)) } ?? item.end
            let mainEnd = time(freezeStart - item.start)
            if mainEnd > .zero {
                let available = min(localEnd, mainEnd)
                try videoTracks[lane].insertTimeRange(CMTimeRange(start: .zero, duration: available), of: sourceTrack, at: start)
                if available != mainEnd { videoTracks[lane].scaleTimeRange(CMTimeRange(start: start, duration: available), toDuration: mainEnd) }
            }
            for layer in childLayers {
                let a = start + time(EditTime(layer.timeRange.start.seconds)), b = min(time(freezeStart), start + time(EditTime(layer.timeRange.end.seconds)))
                if b > a { layers.append((item.id, relocated(layer, track: videoTracks[lane].trackID, start: a, end: b))) }
            }
            if let freeze, freeze.end > freezeStart {
                let lastShown = max(item.start.seconds, (ceil(freezeStart.seconds * Double(framesPerSecond) - 0.000001) - 1) / Double(framesPerSecond))
                let last = max(0, min(localEnd.seconds - 1 / 60000, lastShown - item.start.seconds))
                guard let layer = childLayers.last(where: { $0.timeRange.start.seconds <= last }) else { throw ProjectError.invalidMedia }
                let sample = TransitionRenderer.time(last), tick = CMTime(value: 1, timescale: 60000)
                let at = time(freezeStart), length = time(freeze.end - freezeStart)
                try videoTracks[lane].insertTimeRange(CMTimeRange(start: sample, duration: tick), of: sourceTrack, at: at)
                videoTracks[lane].scaleTimeRange(CMTimeRange(start: at, duration: tick), toDuration: length)
                layers.append((item.id, relocated(layer, track: videoTracks[lane].trackID, start: at, end: at + length, frozen: layer.sourceTime(at: last))))
            }
            _ = end
        }
        let mix = try await audioMix(timeline, project: project, folder: folder, composition: composition, processedSources: processedSources, processedRegions: processedRegions, includeBackgroundAudio: includeBackgroundAudio, previewRange: audioPreviewRange, processedWindows: processedWindows)
        // An empty picture lane still provides the duration for black instructions
        // in an audio-only project and for trailing independent audio.
        if videoTracks.isEmpty, let empty = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            // An entirely empty AVFoundation picture track can play sound but
            // cannot export a video. A tiny real sample drives our black-frame
            // instructions (and subtitles) for an audio-only project as well.
            let asset = AVURLAsset(url: try await TimelineBlackSource.file(in: folder))
            guard let black = try await asset.loadTracks(withMediaType: .video).first else { throw ProjectError.invalidMedia }
            let available = try await black.load(.timeRange)
            try empty.insertTimeRange(available, of: black, at: .zero)
            empty.scaleTimeRange(CMTimeRange(start: .zero, duration: available.duration), toDuration: time(timeline.duration))
            videoTracks.append(empty)
        }
        if let first = videoTracks.first, first.timeRange.end < time(timeline.duration) {
            first.insertEmptyTimeRange(CMTimeRange(start: first.timeRange.end, end: time(timeline.duration)))
        }
        let compiled = timeline.compile()
        var boundaries = Set(compiled.flatMap { [$0.interval.start, $0.interval.end] })
        for (_, layer) in layers { boundaries.insert(EditTime(layer.timeRange.start.seconds)); boundaries.insert(EditTime(layer.timeRange.end.seconds)) }
        let marks = boundaries.sorted()
        var instructions: [AVVideoCompositionInstructionProtocol] = []
        let subtitles = timeline.subtitles.map { SubtitleRenderTrack(cues: timeline.subtitleCues, settings: $0, folder: folder) }
        for (a, b) in zip(marks, marks.dropFirst()) where b > a {
            guard let plan = compiled.first(where: { $0.interval.contains(a) }) else { throw ProjectError.invalidDocument }
            let active = layers.filter { $0.1.timeRange.start <= time(a) && time(a) < $0.1.timeRange.end }
            let dictionary = Dictionary(active, uniquingKeysWith: { first, _ in first })
            for layer in dictionary.values { layer.hdr = hdr }
            let relation = timeline.transitions.first { plan.transitionIDs.contains($0.id) }
            var order = plan.video
            for (id, _) in active where !order.contains(id) { order.append(id) }
            order.sort { a, b in
                guard let left = timeline.video.first(where: { $0.id == a }), let right = timeline.video.first(where: { $0.id == b }) else { return a.uuidString < b.uuidString }
                return TrackTimeline.backToFront(left, right)
            }
            let placement = timeline.placements.first { $0.id == plan.placementID }
            instructions.append(TrackVideoInstruction(range: CMTimeRange(start: time(a), end: time(b)), layers: dictionary, order: order,
                placements: placement?.videos ?? [:], transition: relation, canvas: canvas, hdr: hdr))
        }
        for instruction in instructions.compactMap({ $0 as? TrackVideoInstruction }) { instruction.subtitles = subtitles }
        let video = AVMutableVideoComposition()
        video.renderSize = canvas; video.frameDuration = CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))
        video.instructions = instructions; video.customVideoCompositorClass = VideoToolCompositor.self
        video.colorPrimaries = hdr ? AVVideoColorPrimaries_ITU_R_2020 : AVVideoColorPrimaries_ITU_R_709_2
        video.colorTransferFunction = hdr ? AVVideoTransferFunction_ITU_R_2100_HLG : AVVideoTransferFunction_ITU_R_709_2
        video.colorYCbCrMatrix = hdr ? AVVideoYCbCrMatrix_ITU_R_2020 : AVVideoYCbCrMatrix_ITU_R_709_2
        installTitleClocks(project.edit, in: video)
        return TimelineMedia(composition: composition, videoComposition: video, audioMix: mix,
            playbackVideoComposition: video, hdr: hdr, effectAnalysisPending: layers.contains { $0.1.effectAnalysisPending })
    }
    /// An overlay can span several clips, including both sides of a transition.
    /// Give each render instruction the same clock from the assembled project.
    private static func installTitleClocks(_ edit: EditState, in video: AVVideoComposition) {
        let ranges = TitleMotionRanges(edit)
        guard !ranges.isEmpty else { return }
        for instruction in video.instructions {
            for layer in instruction.toolLayers { layer.titleRanges = ranges }
        }
    }
    static func relocated(_ layer: VideoToolInstruction, track: CMPersistentTrackID, start: CMTime, end: CMTime, frozen: Double? = nil) -> VideoToolInstruction {
        let result = VideoToolInstruction(trackID: track, clip: layer.clip, start: start, transform: layer.transform, sourceSize: layer.sourceSize,
            canvas: layer.canvas, stabilization: layer.stabilization, images: layer.images, duration: end - start, frozenSourceTime: frozen, fontFolder: layer.effectFolder, sequenceClock: layer.sequenceClock)
        result.cropSource = layer.cropSource
        result.sourceURL = layer.sourceURL; result.sourceFPS = layer.sourceFPS; result.sourceHDR = layer.sourceHDR; result.sourceLog = layer.sourceLog; result.effectFolder = layer.effectFolder
        result.effectPalettes = layer.effectPalettes; result.videoEffectsEnabled = layer.videoEffectsEnabled; result.effectSubjects = layer.effectSubjects
        result.maskSource = layer.maskSource; result.effectMasks = layer.effectMasks; result.effectDepth = layer.effectDepth; result.sourceFrames = layer.sourceFrames
        result.nightFix = layer.nightFix
        result.effectMatteHistories = layer.effectMatteHistories; result.effectAnalysisPending = layer.effectAnalysisPending
        return result
    }
    private static func audioMix(_ timeline: TrackTimeline, project: Project, folder: URL, composition: AVMutableComposition,
                                    processedSources: [UUID: URL], processedRegions: [String: URL], includeBackgroundAudio: Bool,
                                    previewRange: ClosedRange<Double>? = nil, processedWindows: [String: [AudioPreviewWindow]] = [:]) async throws -> AVAudioMix {
        var tracks: [AVMutableCompositionTrack] = [], ends: [EditTime] = [], envelopes: [[AudioEnvelopeSegment]] = []
        var formats: [String] = []
        var preceding: [Int: (url: URL, sourceEnd: Double, rate: Double)] = [:]
        for item in timeline.audio.sorted(by: { $0.start < $1.start }) {
            guard let source = project.sources.first(where: { $0.id == item.sourceID }) else { throw ProjectError.missingMedia }
            var boundaries = [EditTime.zero, item.mapping.duration] + item.enhancements.flatMap { [$0.interval.start, $0.interval.end] }
            // A continuous time-pitch pass must never bridge a removed source
            // interval or a silent hold. Keep adjacent rate changes together,
            // but restart at actual source discontinuities in preview and export.
            var cursor = EditTime.zero
            for (run, next) in zip(item.mapping.runs, item.mapping.runs.dropFirst()) {
                cursor = cursor + run.duration
                if abs(run.sourceEnd - next.sourceStart) > 0.00001 || run.silent != next.silent || run.isHold || next.isHold { boundaries.append(cursor) }
            }
            if let previewRange {
                guard let scope = item.interval.intersection(EditInterval(previewRange)) else { continue }
                boundaries += [scope.start - item.start, scope.end - item.start]
                boundaries = boundaries.filter { $0 >= scope.start - item.start && $0 <= scope.end - item.start }
            }
            let points = Set(boundaries).sorted()
            for (a, b) in zip(points, points.dropFirst()) where b > a {
                let region = item.enhancements.first { $0.interval.contains(a) }
                let key = region.map { audioKey(source: source.id, effects: $0.effects) }
                var url = key.flatMap { processedRegions[$0] } ?? processedSources[source.id] ?? folder.appendingPathComponent(source.filename)
                var map = item.mapping.sliced(EditInterval(a, b))
                guard !item.muted, map.runs.contains(where: { !$0.silent }) else { continue }
                if previewRange != nil, region?.effects.contains(where: \.enabled) == true {
                    if key.flatMap({ processedWindows[$0] }) == nil,
                       try await AVURLAsset(url: folder.appendingPathComponent(source.filename)).loadTracks(withMediaType: .audio).isEmpty { continue }
                    guard let key, let windows = processedWindows[key], let first = map.runs.first, let last = map.runs.last,
                          let window = windows.first(where: { $0.range.lowerBound <= first.sourceStart + 0.00001 && $0.range.upperBound >= last.sourceEnd - 0.00001 }) else { throw AudioProcessingError.invalidFormat }
                    url = window.url
                    map.runs = map.runs.map { run in var run = run; run.sourceStart = max(0, run.sourceStart - window.range.lowerBound); run.sourceEnd -= window.range.lowerBound; return run }
                }
                let slices = map.runs.map { EffectAudioRateSlice(start: $0.sourceStart, end: $0.sourceEnd, duration: $0.duration.seconds) }
                let bake = !item.muted && map.runs.allSatisfy { !$0.silent } && EffectAudioRateRenderer.needsContinuousRender(slices)
                let inputURL = bake ? try await EffectAudioRateRenderer.shared.render(url: url, slices: slices, folder: folder, outputDuration: time(b - a), retainedBy: composition) : url
                let asset = AVURLAsset(url: inputURL)
                guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first else { continue }
                let descriptions = try await sourceTrack.load(.formatDescriptions)
                let format = descriptions.map { description -> String in
                    guard let audio = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else { return "unknown" }
                    return "\(audio.mFormatID):\(audio.mSampleRate):\(audio.mChannelsPerFrame):\(audio.mFormatFlags)"
                }.joined(separator: "|")
                // Do not change an audio tap's input format halfway through a
                // lane. AAC camera audio and stereo processed PCM can otherwise
                // stall AVAssetReader when a scoped enhancement starts/ends.
                let lane: Int
                let onset = item.start + a
                let free = ends.indices.first { lane in
                    guard ends[lane] <= onset, formats[lane] == format else { return false }
                    guard ends[lane] == onset, let prior = preceding[lane], let first = slices.first,
                          abs(prior.rate - 1) > 0.00001 || abs(first.rate - 1) > 0.00001 else { return true }
                    // A spectral processor carries audio across adjacent segments on
                    // one track. Give a discontinuous, retimed cut a fresh processor;
                    // otherwise it can mute the start of the incoming passage.
                    return prior.url == inputURL && abs(first.start - prior.sourceEnd) < 0.00001 && abs(first.rate - prior.rate) < 0.00001
                }
                if let free { lane = free }
                else {
                    guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw ProjectError.invalidMedia }
                    lane = tracks.count; tracks.append(track); ends.append(.zero); envelopes.append([]); formats.append(format)
                }
                ends[lane] = item.start + b
                let available = try await sourceTrack.load(.timeRange)
                if bake { try tracks[lane].insertTimeRange(CMTimeRange(start: .zero, duration: time(b - a)), of: sourceTrack, at: time(item.start + a)) }
                var cursor = item.start + a
                for run in map.runs {
                    defer { cursor = cursor + run.duration }
                    guard !run.silent, !item.muted else { continue }
                    let sourceRange = CMTimeRange(start: TransitionRenderer.time(run.sourceStart), end: TransitionRenderer.time(run.sourceEnd))
                    if !bake {
                        try EffectAudioInsertion.insert(sourceRange, of: sourceTrack, into: tracks[lane], at: time(cursor), duration: time(run.duration),
                            retime: abs(sourceRange.duration.seconds - run.duration.seconds) > 0.00001, available: available)
                    }
                    let incoming = timeline.transitions.first { $0.incoming == item.followsVideo && item.followsVideo != nil }
                    let outgoing = timeline.transitions.first { $0.outgoing == item.followsVideo && item.followsVideo != nil }
                    func ramp(_ relation: TimelineTransition?, incoming: Bool) -> ClosedRange<Double>? {
                        guard let relation else { return nil }
                        let edge = relation.outgoing == nil ? -1 : relation.incoming == nil ? 1 : 0
                        let timing = TransitionTiming(relation.settings, factor: relation.factor, edge: edge)
                        let range = incoming ? timing.audioIn : timing.audioOut
                        return (relation.origin.seconds + range.lowerBound)...(relation.origin.seconds + range.upperBound)
                    }
                    let rate = bake ? 1 : (run.sourceEnd - run.sourceStart) / run.duration.seconds
                    let incomingRamp = ramp(incoming, incoming: true), outgoingRamp = ramp(outgoing, incoming: false)
                    let continuous: Bool
                    if let prior = preceding[lane], let envelope = envelopes[lane].last {
                        continuous = abs(envelope.end - cursor.seconds) < 1 / Double(EditTime.scale)
                            && prior.url == inputURL && abs(prior.sourceEnd - run.sourceStart) < 0.00001
                            && abs(prior.rate - rate) < 0.00001
                            && envelope.outRamp == outgoingRamp && envelope.inRamp == incomingRamp
                    } else { continuous = false }
                    if continuous { envelopes[lane][envelopes[lane].count - 1].fadeOut = 0 }
                    preceding[lane] = (inputURL, run.sourceEnd, rate)
                    envelopes[lane].append(AudioEnvelopeSegment(start: cursor.seconds, end: (cursor + run.duration).seconds, fadeIn: continuous ? 0 : 0.008, fadeOut: 0.008,
                        clipStart: item.start.seconds, clipEnd: item.end.seconds, transitionIn: 0, transitionOut: 0,
                        inRamp: incomingRamp, outRamp: outgoingRamp, userFadeIn: item.fadeIn, userFadeOut: item.fadeOut, owner: item.id,
                        initialOwner: continuous ? envelopes[lane].last?.owner : nil,
                        initialVolume: continuous ? envelopes[lane].last?.volume : nil, censors: timeline.censorSpans(for: item), volume: item.gain))
                }
            }
        }
        var parameters: [AVAudioMixInputParameters] = []
        for (i, track) in tracks.enumerated() {
            if !track.segments.contains(where: { !$0.isEmpty }) { composition.removeTrack(track); continue }
            let parameter = AVMutableAudioMixInputParameters(track: track); parameter.audioTimePitchAlgorithm = .spectral
            parameter.audioTapProcessor = try CutAudioEnvelope.make(segments: envelopes[i].sorted { $0.start < $1.start })
            parameters.append(parameter)
        }
        var records: [CMPersistentTrackID: [AudioEnvelopeSegment]] = [:]
        for (i, track) in tracks.enumerated() { records[track.trackID] = envelopes[i] }
        if includeBackgroundAudio {
            let background = try await VideoEffectBackgroundAudio.append(project: project, folder: folder, to: composition)
            for parameter in background { if let envelope = AudioGainMix.envelopes(parameter) { records[parameter.trackID] = envelope } }
            parameters += background
        }
        let mix = AVMutableAudioMix(); mix.inputParameters = parameters
        AudioGainMix.register(mix, records: records)
        return mix
    }
    static func placed(_ image: CIImage, settings: VideoPlacement, canvas: CGSize) -> CIImage {
        let bounds = CGRect(origin: .zero, size: canvas)
        let window = CGRect(x: (settings.x - settings.width / 2) * canvas.width,
                            y: (1 - settings.y - settings.height / 2) * canvas.height,
                            width: settings.width * canvas.width, height: settings.height * canvas.height)
        let crop = settings.framing.crop(source: canvas, viewport: settings.fill ? window.size : canvas)
        let source = CGRect(x: crop.minX, y: canvas.height - crop.maxY, width: crop.width, height: crop.height)
        let scale = settings.fill ? max(window.width / source.width, window.height / source.height) : min(window.width / source.width, window.height / source.height)
        let visible = settings.visibleWindow(in: canvas)
        let clip = CGRect(x: visible.minX, y: canvas.height - visible.maxY, width: visible.width, height: visible.height)
        return image.cropped(to: source).transformed(by: CGAffineTransform(translationX: -source.midX, y: -source.midY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale)).concatenating(CGAffineTransform(translationX: window.midX, y: window.midY))).cropped(to: clip.intersection(bounds))
    }
}

private enum TimelineBlackSource {
    static func file(in folder: URL) async throws -> URL {
        let cache = ProjectCacheLocation.root(in: folder)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let destination = cache.appendingPathComponent("black-video-v1.mov")
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        let temporary = cache.appendingPathComponent(UUID().uuidString + ".partial.mov")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let writer = try AVAssetWriter(outputURL: temporary, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ProjectError.invalidMedia }
        writer.startSession(atSourceTime: .zero)
        do {
            var pixel: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel) == kCVReturnSuccess, let pixel else { throw ProjectError.invalidMedia }
            CVPixelBufferLockBaseAddress(pixel, [])
            memset(CVPixelBufferGetBaseAddress(pixel), 0, CVPixelBufferGetBytesPerRow(pixel) * 64)
            CVPixelBufferUnlockBaseAddress(pixel, [])
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                if writer.status == .failed { throw writer.error ?? ProjectError.invalidMedia }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            guard adaptor.append(pixel, withPresentationTime: .zero) else { throw writer.error ?? ProjectError.invalidMedia }
            writer.endSession(atSourceTime: CMTime(value: 1, timescale: 30)); input.markAsFinished()
            await writer.finishWriting()
            try Task.checkCancellation()
            guard writer.status == .completed else { throw writer.error ?? ProjectError.invalidMedia }
            do { try FileManager.default.moveItem(at: temporary, to: destination) }
            catch { if !FileManager.default.fileExists(atPath: destination.path) { throw error } }
            return destination
        } catch { writer.cancelWriting(); throw error }
    }
}
