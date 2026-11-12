@preconcurrency import AVFoundation
import CoreImage

final class TransitionVideoInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = true
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    let layers: [VideoToolInstruction]
    let join: TransitionJoin?
    let canvas: CGSize
    let hdr: Bool
    let firstIsIncoming: Bool
    let outgoing: VideoToolInstruction?
    let incoming: VideoToolInstruction?
    init(range: CMTimeRange, layers: [VideoToolInstruction], join: TransitionJoin?, canvas: CGSize, hdr: Bool, firstIsIncoming: Bool, indices: [Int] = []) {
        timeRange = range; self.layers = layers; self.join = join; self.canvas = canvas; self.hdr = hdr
        self.firstIsIncoming = firstIsIncoming
        outgoing = join.flatMap { join in layers.first { $0.clip.id == join.outgoingID } }
        incoming = join.flatMap { join in layers.first { $0.clip.id == join.incomingID } }
        requiredSourceTrackIDs = layers.map { NSNumber(value: $0.trackID) }
    }
}

enum TransitionRenderer {
    enum TimingError: LocalizedError {
        case uncoveredInterval
        var errorDescription: String? { "The transition could not be prepared. Your recording and edits are preserved." }
    }
    // Convert absolute boundaries once. CMTime(seconds:) truncates fractional
    // ticks; separately converting a start and duration can leave holes even
    // at ordinary cuts. Every track, layer and transition shares this grid.
    // Rendering must share the edit clock. Rounding 240 kHz clip ends down to
    // 60 kHz left tiny intervals with no picture layer at otherwise exact joins.
    static func time(_ seconds: Double) -> CMTime { CMTime(value: EditTime(seconds).ticks, timescale: CMTimeScale(EditTime.scale)) }
    static func timeline(project: Project, folder: URL, processedSources: [UUID: URL], canvasSize: CGSize?, framesPerSecond: Int = 30,
                         stabilization: Bool, stabilizationPlans: [UUID: StabilizationPlan],
                         videoProgress: @escaping @Sendable (Double) -> Void, previewDiagnostics:Bool = false,bypassVideoEffects:Bool=false,effectPreparation:VideoEffectPreparation = .final) async throws -> TimelineMedia {
        let layout = project.edit.layout
        let canvas: CGSize
        if let canvasSize { canvas = canvasSize } else { canvas = try await MediaRenderer.canvas(project: project, folder: folder) }
        let composition = AVMutableComposition()
        var videos: [AVMutableCompositionTrack] = [], audios: [AVMutableCompositionTrack] = []
        for _ in 0..<2 {
            guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
                  let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw ProjectError.invalidMedia }
            videos.append(video); audios.append(audio)
        }
        var layers: [(index: Int, instruction: VideoToolInstruction)] = []
        var envelopes: [[AudioEnvelopeSegment]] = [[], []]
        var hdr = false
        for placement in layout.placements {
            try Task.checkCancellation()
            var clip = placement.clip; clip.transition = nil; clip.openingTransition = nil
            var part = project
            part.history = [EditState(clips: [clip], outputSize: canvas)]; part.historyCursor = 0
            let media = try await MediaRenderer.timeline(project: part, folder: folder, processedSources: processedSources,
                canvasSize: canvas, framesPerSecond: framesPerSecond, stabilization: stabilization, stabilizationPlans: stabilizationPlans,
                videoProgress: { videoProgress((Double(placement.index) + $0) / Double(layout.placements.count)) }, forceCustom: true, includeBackgroundAudio: false, previewDiagnostics:previewDiagnostics,bypassVideoEffects:bypassVideoEffects,effectPreparation:effectPreparation)
            EffectAudioRateRenderer.retainAudio(from:media.composition,in:composition)
            hdr = hdr || media.hdr
            let trackIndex = placement.index % 2
            let start = time(placement.start), end = time(placement.end)
            let outputRange = CMTimeRange(start: start, end: end)
            guard let localEnd = media.videoComposition.instructions.last?.timeRange.end, localEnd > .zero else { throw TimingError.uncoveredInterval }
            let range = CMTimeRange(start: .zero, duration: localEnd)
            guard let video = media.composition.tracks(withMediaType: .video).first else { throw ProjectError.invalidMedia }
            let (inJoin, outJoin) = layout.joins(for: placement)
            let freezes = outJoin.transition?.style == .still
            let freezeStart = freezes ? max(start, min(end, time(outJoin.origin))) : end
            let mainDuration = freezeStart - start
            let localMainEnd = freezes ? time(localEnd.seconds * mainDuration.seconds / outputRange.duration.seconds) : localEnd
            if localMainEnd > .zero {
                let mainRange = CMTimeRange(start: .zero, duration: localMainEnd)
                try videos[trackIndex].insertTimeRange(mainRange, of: video, at: start)
                if mainDuration != localMainEnd { videos[trackIndex].scaleTimeRange(CMTimeRange(start: start, duration: localMainEnd), toDuration: mainDuration) }
            }
            if let audio = media.composition.tracks(withMediaType: .audio).first {
                let roundingOnly=abs(range.duration.seconds-outputRange.duration.seconds)<=0.001
                let audioRange=roundingOnly ? CMTimeRange(start:.zero,duration:min(range.duration,outputRange.duration)) : range
                let available = CMTimeRangeGetIntersection(audioRange, otherRange: audio.timeRange)
                if available.duration.seconds > 0 { try audios[trackIndex].insertTimeRange(available, of: audio, at: start + available.start) }
                if roundingOnly,audios[trackIndex].timeRange.end<end {
                    audios[trackIndex].insertEmptyTimeRange(CMTimeRange(start:audios[trackIndex].timeRange.end,end:end))
                }
                if !roundingOnly,range.duration != outputRange.duration && !audios[trackIndex].segments.isEmpty {
                    let inserted = CMTimeRange(start: start, duration: range.duration)
                    if audios[trackIndex].timeRange.end < inserted.end { audios[trackIndex].insertEmptyTimeRange(CMTimeRange(start: audios[trackIndex].timeRange.end, end: inserted.end)) }
                    audios[trackIndex].scaleTimeRange(inserted, toDuration: outputRange.duration)
                }
            }
            let previous = placement.index > 0 ? layout.placements[placement.index - 1].clip : nil
            let next = placement.index + 1 < layout.placements.count ? layout.placements[placement.index + 1].clip : nil
            let joinsPrevious = previous?.audioContinues(into:clip) == true
            let joinsNext = next.map { clip.audioContinues(into:$0) } ?? false
            var pieceStart = placement.start
            let pieces=clip.playbackPieces
            for (index, piece) in pieces.enumerated() {
                let continuousBefore=index==0 ? joinsPrevious : pieces[index-1].audioContinues(into:piece)
                let continuousAfter=index==pieces.count-1 ? joinsNext : piece.audioContinues(into:pieces[index+1])
                envelopes[trackIndex].append(AudioEnvelopeSegment(start: pieceStart, end: pieceStart + piece.duration,
                    fadeIn: continuousBefore ? 0 : 0.008,
                    fadeOut: continuousAfter ? 0 : 0.008,
                    clipStart: placement.start, clipEnd: placement.end, transitionIn: 0, transitionOut: 0,
                    inRamp: inJoin.transition == nil ? nil : inJoin.audioIn,
                    outRamp: outJoin.transition == nil ? nil : outJoin.audioOut))
                pieceStart += piece.duration
            }
            let childLayers = media.videoComposition.instructions.compactMap { $0 as? VideoToolInstruction }
            func mapped(_ local: CMTime) -> CMTime {
                if local == .zero { return start }; if local == localEnd { return end }
                return start + CMTime(value: Int64((Double(outputRange.duration.value) * local.seconds / localEnd.seconds).rounded()), timescale: 60000)
            }
            func copy(_ layer: VideoToolInstruction, from lower: CMTime, to upper: CMTime, frozen: Double? = nil) -> VideoToolInstruction {
                let copy = VideoToolInstruction(trackID: videos[trackIndex].trackID, clip: layer.clip, start: lower, transform: layer.transform, sourceSize: layer.sourceSize,
                    canvas: canvas, stabilization: layer.stabilization, images: layer.images, duration: upper - lower, frozenSourceTime: frozen, fontFolder: folder, sequenceClock:layer.sequenceClock)
                copy.cropSource = layer.cropSource
                copy.sourceURL = layer.sourceURL; copy.sourceFPS = layer.sourceFPS; copy.sourceHDR = layer.sourceHDR; copy.effectFolder = layer.effectFolder; copy.effectPalettes = layer.effectPalettes;copy.videoEffectsEnabled=layer.videoEffectsEnabled;copy.effectSubjects=layer.effectSubjects;copy.maskSource=layer.maskSource;copy.effectMasks=layer.effectMasks;copy.effectDepth=layer.effectDepth
                copy.sourceFrames=layer.sourceFrames
                copy.sourceLog=layer.sourceLog
                copy.effectMatteHistories=layer.effectMatteHistories
                copy.nightFix=layer.nightFix;copy.effectAnalysisPending=layer.effectAnalysisPending
                return copy
            }
            for layer in childLayers {
                let layerStart = mapped(layer.timeRange.start), layerEnd = min(freezeStart, mapped(layer.timeRange.end))
                if layerEnd > layerStart { layers.append((placement.index, copy(layer, from: layerStart, to: layerEnd))) }
            }
            if freezes {
                let freezeEnd = time(outJoin.videoRange.upperBound)
                if freezeEnd > freezeStart {
                    let lastShown = max(start.seconds, (ceil(freezeStart.seconds * Double(framesPerSecond) - 0.000001) - 1) / Double(framesPerSecond))
                    let tick = CMTime(value: 1, timescale: 60000)
                    let sampleStart = max(.zero, min(localEnd - tick, time(localEnd.seconds * (lastShown - start.seconds) / outputRange.duration.seconds)))
                    let sampleEnd = sampleStart + tick
                    let sampleRange = CMTimeRange(start: sampleStart, end: sampleEnd)
                    try videos[trackIndex].insertTimeRange(sampleRange, of: video, at: freezeStart)
                    videos[trackIndex].scaleTimeRange(CMTimeRange(start: freezeStart, duration: sampleRange.duration), toDuration: freezeEnd - freezeStart)
                    guard let layer = childLayers.first(where: { $0.timeRange.start <= sampleStart && sampleStart < $0.timeRange.end }) else { throw TimingError.uncoveredInterval }
                    layers.append((placement.index, copy(layer, from: freezeStart, to: freezeEnd, frozen: layer.sourceTime(at: sampleStart.seconds))))
                }
            }
        }
        let joins = layout.joins.filter { $0.transition != nil }.map { join in
            var lower = time(join.range.lowerBound), upper = time(join.range.upperBound)
            if join.index > 0 && join.index < layout.placements.count {
                if abs(join.timing.lower - join.timing.rightStart) < 0.00000001 { lower = time(layout.placements[join.index].start) }
                if abs(join.timing.upper - join.timing.leftEnd) < 0.00000001 { upper = time(layout.placements[join.index - 1].end) }
            }
            return TransitionJoin(index: join.index, time: time(join.time).seconds, range: lower.seconds...max(lower.seconds, upper.seconds), maximum: join.maximum,
                transition: join.transition, origin: join.origin, timing: join.timing, factor: join.factor, edge: join.edge)
        }
        let marks = Array(Set(layers.flatMap { [$0.instruction.timeRange.start.value, $0.instruction.timeRange.end.value] }
            + joins.flatMap { [time($0.range.lowerBound).value, time($0.range.upperBound).value] } + [0, time(layout.duration).value])).sorted()
        var instructions: [AVVideoCompositionInstructionProtocol] = []
        for (a, b) in zip(marks, marks.dropFirst()) where b > a {
            let active = layers.filter { a >= $0.instruction.timeRange.start.value && a < $0.instruction.timeRange.end.value }.sorted { $0.index < $1.index }
            let join = joins.first { a >= time($0.range.lowerBound).value && a < time($0.range.upperBound).value }
            guard !active.isEmpty || join != nil else { throw TimingError.uncoveredInterval }
            guard active.count <= 2 else { throw TimingError.uncoveredInterval }
            active.forEach { $0.instruction.hdr = hdr }
            instructions.append(TransitionVideoInstruction(range: CMTimeRange(start: CMTime(value: a, timescale: 60000), end: CMTime(value: b, timescale: 60000)),
                layers: active.map(\.instruction), join: join, canvas: canvas, hdr: hdr, firstIsIncoming: false, indices: active.map(\.index)))
        }
        let video = AVMutableVideoComposition()
        video.renderSize = canvas; video.frameDuration = CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))
        video.instructions = instructions; video.customVideoCompositorClass = VideoToolCompositor.self
        video.colorPrimaries = hdr ? AVVideoColorPrimaries_ITU_R_2020 : AVVideoColorPrimaries_ITU_R_709_2
        video.colorTransferFunction = hdr ? AVVideoTransferFunction_ITU_R_2100_HLG : AVVideoTransferFunction_ITU_R_709_2
        video.colorYCbCrMatrix = hdr ? AVVideoYCbCrMatrix_ITU_R_2020 : AVVideoYCbCrMatrix_ITU_R_709_2
        var parameters: [AVAudioMixInputParameters] = []
        for (index, track) in audios.enumerated() {
            guard track.segments.contains(where: { !$0.isEmpty }) else { composition.removeTrack(track); continue }
            let input = AVMutableAudioMixInputParameters(track: track); input.audioTimePitchAlgorithm = .spectral
            input.audioTapProcessor = try CutAudioEnvelope.make(segments: envelopes[index])
            parameters.append(input)
        }
        parameters += try await VideoEffectBackgroundAudio.append(project:project,folder:folder,to:composition)
        let mix = AVMutableAudioMix(); mix.inputParameters = parameters
        return TimelineMedia(composition: composition, videoComposition: video, audioMix: parameters.isEmpty ? nil : mix, playbackVideoComposition: video, hdr: hdr,effectAnalysisPending:layers.contains {$0.instruction.effectAnalysisPending})
    }

    static func fill(settings: ClipTransition, canvas: CGSize) -> CIImage {
        let color = settings.style == .fadeColor ? settings.resolvedFadeColor : .black
        return CIImage(color: CIColor(cgColor: color.cgColor)).cropped(to: CGRect(origin: .zero, size: canvas))
    }

    static func composite(_ first: CIImage, _ second: CIImage, settings: ClipTransition, progress: Double, canvas: CGSize, duration: Double? = nil, framesPerSecond: Double = 30) -> CIImage {
        let bounds = CGRect(origin: .zero, size: canvas), black = CIImage(color: .black).cropped(to: bounds)
        let t = min(1, max(0, progress)), eased = t * t * (3 - 2 * t)
        if t <= 0 { return first }; if t >= 1 { return second }
        switch settings.style {
        case .dissolve, .still:
            return first.applyingFilter("CIDissolveTransition", parameters: ["inputTargetImage": second, "inputTime": eased]).cropped(to: bounds)
        case .fadeColor:
            let color = fill(settings: settings, canvas: canvas)
            return t < 0.5 ? first.applyingFilter("CIDissolveTransition", parameters: ["inputTargetImage": color, "inputTime": min(1, t * 2)])
                : color.applyingFilter("CIDissolveTransition", parameters: ["inputTargetImage": second, "inputTime": max(0, t * 2 - 1)])
        case .wipe:
            let angle = settings.angle * .pi / 180, dx = cos(angle), dy = -sin(angle)
            let span = abs(dx) * canvas.width + abs(dy) * canvas.height
            let feather = settings.hardEdge == true ? 0.5 : max(1, span * 0.035)
            let distance = (span + 2 * feather) * eased - span / 2 - feather
            let center = CGPoint(x: canvas.width / 2 + dx * distance, y: canvas.height / 2 + dy * distance)
            let p0 = CGPoint(x: center.x - dx * feather, y: center.y - dy * feather)
            let p1 = CGPoint(x: center.x + dx * feather, y: center.y + dy * feather)
            let mask = CIFilter(name: "CILinearGradient", parameters: ["inputPoint0": CIVector(cgPoint: p0), "inputPoint1": CIVector(cgPoint: p1), "inputColor0": CIColor.white, "inputColor1": CIColor.black])!.outputImage!
            return second.applyingFilter("CIBlendWithMask", parameters: ["inputBackgroundImage": first, "inputMaskImage": mask]).cropped(to: bounds)
        case .hitchcock:
            let feather = 0.08, threshold = eased * (1 + 2 * feather) - feather
            let sign = settings.highlightsFirst == true ? 1.0 : -1.0
            let weights = CIVector(x: sign * 0.2126 / feather, y: sign * 0.7152 / feather, z: sign * 0.0722 / feather, w: 0)
            let bias = (settings.highlightsFirst == true ? threshold - 1 : threshold) / feather + 0.5
            // Key perceptual brightness, not linear-light energy. Clamp the mask
            // input only, so HDR highlights are revealed before the final frame.
            let key = (first.matchedFromWorkingSpace(to: CGColorSpace(name: CGColorSpace.extendedSRGB)!) ?? first)
                .applyingFilter("CIColorClamp", parameters: ["inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0), "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])
            let mask = key.applyingFilter("CIColorMatrix", parameters: ["inputRVector": weights, "inputGVector": weights, "inputBVector": weights,
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 1)])
                .applyingFilter("CIColorClamp", parameters: ["inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 1), "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])
            return second.applyingFilter("CIBlendWithMask", parameters: ["inputBackgroundImage": first, "inputMaskImage": mask]).cropped(to: bounds)
        case .whip:
            let vertical = settings.axis == .vertical, sign = settings.reverse ? -1.0 : 1.0
            let distance = (vertical ? canvas.height : canvas.width) * 0.65 * sign
            let radius = min(canvas.width, canvas.height) * 0.12 * sin(.pi * t)
            func pan(_ image: CIImage, _ offset: Double) -> CIImage {
                let scale = blurScale(radius: radius, canvas: canvas)
                return downsample(image, scale: scale).clampedToExtent()
                    .transformed(by: CGAffineTransform(translationX: vertical ? 0 : offset * scale, y: vertical ? -offset * scale : 0))
                    .applyingFilter("CIMotionBlur", parameters: ["inputRadius": radius * scale, "inputAngle": vertical ? Double.pi / 2 : 0])
                    .transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale)).cropped(to: bounds)
            }
            return pan(first, -eased * distance).applyingFilter("CIDissolveTransition", parameters: ["inputTargetImage": pan(second, (1 - eased) * distance), "inputTime": eased]).cropped(to: bounds)
        case .flashCut:
            let length = duration ?? settings.duration
            let frame = Int(floor(t * length * framesPerSecond + 0.000001))
            return settings.flashFrames(duration: length, framesPerSecond: framesPerSecond).contains(frame) ? second : first
        case .defocus:
            // Optical aperture blur produces highlight discs. Preview and export
            // use the same normalized radius; no Gaussian approximation.
            let radius = min(canvas.width, canvas.height) * 0.05 * (settings.blurAmount ?? 0.75) * sin(.pi * t)
            func optical(_ image: CIImage) -> CIImage {
                let scale = blurScale(radius: radius, canvas: canvas)
                return downsample(image, scale: scale).clampedToExtent()
                    .applyingFilter("CIBokehBlur", parameters: ["inputRadius": radius * scale, "inputRingAmount": 0.12, "inputRingSize": 0.1, "inputSoftness": 0.25])
                    .transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale)).cropped(to: bounds)
            }
            let blend = min(1, max(0, (t - 0.35) / 0.3))
            if blend <= 0 { return optical(first) }; if blend >= 1 { return optical(second) }
            return optical(first).applyingFilter("CIDissolveTransition", parameters: ["inputTargetImage": optical(second), "inputTime": blend]).cropped(to: bounds)
        case .split:
            let rectangles = splitRects(settings: settings, canvas: canvas)
            let left = framed(first, framing: settings.first, in: rectangles.0, canvas: canvas)
            let right = framed(second, framing: settings.second, in: rectangles.1, canvas: canvas)
            var pair = right.composited(over: left).composited(over: black)
            let lineWidth = max(1, min(canvas.width, canvas.height) * 0.002)
            let line = settings.axis == .horizontal ? CGRect(x: rectangles.0.maxX - lineWidth / 2, y: 0, width: lineWidth, height: canvas.height)
                : CGRect(x: 0, y: rectangles.0.minY - lineWidth / 2, width: canvas.width, height: lineWidth)
            pair = CIImage(color: CIColor(red: 0.25, green: 0.25, blue: 0.25)).cropped(to: line).composited(over: pair)
            // Brief, restrained entry/exit; most of the interval holds both views.
            let edge = 0.15
            if t < edge { return first.applyingFilter("CIDissolveTransition", parameters: ["inputTargetImage": pair, "inputTime": t / edge]).cropped(to: bounds) }
            if t > 1 - edge { return pair.applyingFilter("CIDissolveTransition", parameters: ["inputTargetImage": second, "inputTime": (t - 1 + edge) / edge]).cropped(to: bounds) }
            return pair.cropped(to: bounds)
        }
    }
    private static func blurScale(radius: Double, canvas: CGSize) -> Double {
        // Preserve full detail near the sharp endpoints; large optical kernels
        // need fewer pixels. The blur radius remains in output-picture units.
        min(1, max(960 / max(canvas.width, canvas.height), 2 / max(2, radius)))
    }
    private static func downsample(_ image: CIImage, scale: Double) -> CIImage {
        scale >= 1 ? image : image.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": scale, "inputAspectRatio": 1])
    }
    static func splitRects(settings: ClipTransition, canvas: CGSize) -> (CGRect, CGRect) {
        if settings.axis == .horizontal {
            let split = canvas.width * settings.divider
            return (CGRect(x: 0, y: 0, width: split, height: canvas.height), CGRect(x: split, y: 0, width: canvas.width - split, height: canvas.height))
        }
        let split = canvas.height * settings.divider
        return (CGRect(x: 0, y: canvas.height - split, width: canvas.width, height: split), CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height - split))
    }
    static func framed(_ image: CIImage, framing: TransitionFraming, in viewport: CGRect, canvas: CGSize) -> CIImage {
        let extent = image.extent
        let topCrop = framing.crop(source: extent.size, viewport: viewport.size)
        let crop = CGRect(x: extent.minX + topCrop.minX, y: extent.maxY - topCrop.maxY, width: topCrop.width, height: topCrop.height)
        let scale = viewport.width / max(0.001, crop.width)
        return image.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: viewport.minX, y: viewport.minY)).cropped(to: viewport)
    }
    static func contentBounds(_ layer: VideoToolInstruction) -> CGRect {
        let top = CGRect(origin: .zero, size: layer.sourceSize).applying(layer.transform)
            .intersection(CGRect(origin: .zero, size: layer.canvas))
        return CGRect(x: top.minX, y: layer.canvas.height - top.maxY, width: top.width, height: top.height)
    }
}
