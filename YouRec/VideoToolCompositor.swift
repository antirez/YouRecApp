@preconcurrency import AVFoundation
import CoreImage
import CoreText
import CryptoKit

/// The export scheduler can subdivide an instruction without moving the
/// original clip, transition, or animation clock used to draw its pictures.
final class ExportInstructionRange: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let original: AVVideoCompositionInstructionProtocol
    let timeRange: CMTimeRange
    var enablePostProcessing: Bool { original.enablePostProcessing }
    var containsTweening: Bool { original.containsTweening }
    var requiredSourceTrackIDs: [NSValue]? { original.requiredSourceTrackIDs }
    var passthroughTrackID: CMPersistentTrackID { original.passthroughTrackID }
    init(_ original: AVVideoCompositionInstructionProtocol, range: CMTimeRange) {
        self.original = original
        timeRange = range
    }
}

extension AVVideoCompositionInstructionProtocol {
    var toolLayers: [VideoToolInstruction] {
        if let track = self as? TrackVideoInstruction { return Array(track.layers.values) }
        if let transition = self as? TransitionVideoInstruction { return transition.layers }
        if let layer = self as? VideoToolInstruction { return [layer] }
        return []
    }
}

// One compositor for both the editor and export. Text is composited last, after
// grading and stabilization, so a camera correction never moves the title.
final class VideoToolInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = true
    let containsTweening = true
    // Temporal instructions use their indexed reader throughout the segment,
    // including inactive portions, so AVFoundation needn't decode it again.
    var readsSourceFrames:Bool {videoEffectsEnabled && sourceURL != nil && sourceFrames != nil && (clip.videoEffects ?? []).contains {$0.enabled && $0.usesTemporalMatte}}
    var requiredSourceTrackIDs: [NSValue]? {readsSourceFrames ? [] : [NSNumber(value:trackID)]}
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    let trackID: CMPersistentTrackID
    let clip: TimelineClip
    let transform: CGAffineTransform
    let sourceSize: CGSize
    let canvas: CGSize
    let stabilization: StabilizationPlan?
    var hdr = false
    var sourceHDR = false
    var sourceLog: LUTInput?
    var sourceURL: URL? {didSet {invalidateMatteIdentity()}}
    var sourceFPS = 30.0
    let sequenceClock:VideoEffectSequenceClock
    var sourceFrames:VideoEffectFrameIndex?
    var nightFix:NightFixPlan? {didSet {invalidateMatteIdentity()}}
    var effectFolder: URL?
    var effectPalettes: [UUID: EffectPaletteTrack] = [:]
    var effectSubjects:[UUID:EffectSubjectTrack]=[:] {didSet {invalidateMatteIdentity()}}
    var effectDepth:VideoEffectDepthSource? {didSet {invalidateMatteIdentity()}}
    var maskSource: SourcePersonMasks? { didSet { invalidateMatteIdentity() } }
    var effectMasks:EffectMaskFiles? {didSet {invalidateMatteIdentity()}}
    var effectMatteHistories:[UUID:VideoEffectRecordedMatteHistory]=[:] {didSet {invalidateMatteIdentity()}}
    var effectAnalysisPending=false {didSet {invalidateMatteIdentity()}}
    private let matteIdentityLock=NSLock()
    private var matteIdentities:[String:String]=[:]
    private func invalidateMatteIdentity() {
        matteIdentityLock.lock();matteIdentities.removeAll();matteIdentityLock.unlock()
    }
    func matteIdentity(analysis:Bool=false,frameRate:Double=30)throws->String {
        struct Restoration: Encodable {
            let effects: [VideoEffectSettings]
            let root: String?; let chunks: [String]; let mode: String?; let pending: Bool?
        }
        let restoration = Restoration(effects: effectSettings.filter { $0.kind == .nightFix },
            root: nightFix?.root.path, chunks: nightFix?.chunks.map(\.file) ?? [], mode: nightFix?.mode.rawValue, pending: nightFix?.pending)
        let restorationEncoder = JSONEncoder(); restorationEncoder.outputFormatting = [.sortedKeys]
        let restorationKey = SHA256.hash(data: try restorationEncoder.encode(restoration)).map { String(format: "%02x", $0) }.joined()
        let variant="mask-stream-\(maskSource?.identity ?? "none")-restore-\(restorationKey)-person2-depth1-\(effectDepth?.identity ?? "none")-geometry2-\(analysis)-\(frameRate)-\(sourceHDR)-\(hdr)-\(effectAnalysisPending)-\(effectFolder?.path ?? "")"
        matteIdentityLock.lock();defer {matteIdentityLock.unlock()}
        if let cached=matteIdentities[variant] {return cached}
        guard let sourceURL else {throw VideoEffectError.unavailableMatteHistory}
        struct Subjects:Encodable {let id:String;let track:EffectSubjectTrack}
        struct MatteHistory:Encodable {let id:String;let fingerprint:String}
        struct Identity:Encodable {
            let source:[String];let variant:String;let geometry:[Double]
            let color:ColorSettings?;let stabilization:[StabilizationSample]?
            let masks:[[String]];let subjects:[Subjects];let matteHistories:[MatteHistory]
        }
        func file(_ url:URL)throws->[String] {
            let values=try url.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey])
            return [url.standardizedFileURL.path,String(values.fileSize ?? 0),String(values.contentModificationDate?.timeIntervalSince1970 ?? 0)]
        }
        let maskURLs=effectMasks.map {[$0.metadata,$0.data]+$0.chunks.flatMap {[$0.metadata,$0.data]}} ?? []
        let value=Identity(source:try file(sourceURL),variant:variant,
            geometry:[transform.a,transform.b,transform.c,transform.d,transform.tx,transform.ty,sourceSize.width,sourceSize.height,canvas.width,canvas.height,stabilization?.zoom ?? 1,clip.stabilizationStart],
            color:clip.color,stabilization:stabilization?.samples,masks:try maskURLs.map(file),
            subjects:effectSubjects.map {Subjects(id:$0.key.uuidString,track:$0.value)}.sorted {$0.id<$1.id},matteHistories:effectMatteHistories.map {MatteHistory(id:$0.key.uuidString,fingerprint:$0.value.fingerprint)}.sorted {$0.id<$1.id})
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let identity=SHA256.hash(data:try encoder.encode(value)).map {String(format:"%02x",$0)}.joined()
        matteIdentities[variant]=identity;return identity
    }
    // Interactive positioning changes only image parameters. Publish an immutable
    // snapshot under the lock; export instructions never receive an override.
    private let previewEffectLock=NSLock()
    private var previewEffectOverride:[VideoEffectSettings]?
    var effectSettings:[VideoEffectSettings] {
        previewEffectLock.lock();defer {previewEffectLock.unlock()}
        return previewEffectOverride ?? clip.videoEffects ?? []
    }
    func previewEffects(_ effects:[VideoEffectSettings]) {
        previewEffectLock.lock();previewEffectOverride=effects;previewEffectLock.unlock()
    }
    struct PreviewTitle {
        let text: TextOverlay
        let bitmap: CGImage
        let ranges: TitleMotionRanges
    }
    private var draftTitle: PreviewTitle?
    var previewTitle: PreviewTitle? {
        get { previewEffectLock.withLock { draftTitle } }
        set { previewEffectLock.withLock { draftTitle = newValue } }
    }
    var videoEffectsEnabled=true
    var overlaysEnabled = true
    let images: [(ImageOverlay, CGImage)]
    var titleRanges = TitleMotionRanges()
    let textImages: [(TextOverlay, CGImage)]
    let frozenSourceTime: Double?
    init(trackID: CMPersistentTrackID, clip: TimelineClip, start: CMTime, transform: CGAffineTransform,
         sourceSize: CGSize, canvas: CGSize, stabilization: StabilizationPlan?, images: [(ImageOverlay, CGImage)] = [], duration: CMTime? = nil, frozenSourceTime: Double? = nil, fontFolder: URL? = nil, sequenceClock:VideoEffectSequenceClock) {
        self.sequenceClock=sequenceClock
        self.trackID = trackID; self.clip = clip; self.transform = transform; self.sourceSize = sourceSize; self.canvas = canvas; self.stabilization = stabilization
        self.images = images
        self.frozenSourceTime = frozenSourceTime
        timeRange = CMTimeRange(start: start, duration: duration ?? TransitionRenderer.time(clip.duration))
        textImages = (clip.texts ?? []).filter { $0.start < clip.end && $0.end > clip.start }.compactMap { text in
            TextRasterizer.image(text, canvas: canvas, folder: fontFolder).map { (text, $0) }
        }
    }
    var cropSource: (orientation: CGAffineTransform, size: CGSize)?
    func preparedImage(_ raw:CIImage,at sampleTime:Double,motionTime:Double?=nil,analysis:Bool=false)->(CIImage,CGAffineTransform) {
        let bounds=CGRect(origin:.zero,size:canvas)
        var image=raw
        let grade = clip.color ?? ColorSettings()
        func graded(_ value: ColorSettings) -> CIImage { ColorLUT.apply(value, to: raw, hdr: hdr, folder: effectFolder, sourceLog: sourceLog) }
        if let motion = grade.motion {
            let f = motion.fraction(at: motionTime ?? sampleTime)
            if f <= 0 { image = graded(grade.applying(motion.a)) }
            else if f >= 1 { image = graded(grade.applying(motion.b)) }
            else {
                image = graded(grade.applying(motion.a)).applyingFilter("CIDissolveTransition", parameters: ["inputTargetImage":graded(grade.applying(motion.b)), "inputTime":f]).cropped(to:raw.extent)
            }
        } else { image = graded(grade) }
        var framing = transform
        if let cropSource, let crop = clip.crop, let motion = crop.motion {
            framing = cropSource.orientation.concatenating(crop.applying(motion.pose(at:motionTime ?? sampleTime)).transform(source:cropSource.size, canvas:canvas))
            if let mirror = clip.mirror { framing = framing.concatenating(mirror.transform(canvas:canvas)) }
        }
        let correction=stabilization?.transform(at:sampleTime-clip.stabilizationStart) ?? .identity
        var matrix=CGAffineTransform(a:1,b:0,c:0,d:-1,tx:0,ty:sourceSize.height)
            .concatenating(correction).concatenating(framing)
            .concatenating(CGAffineTransform(a:1,b:0,c:0,d:-1,tx:0,ty:canvas.height))
        image=image.transformed(by:matrix).cropped(to:bounds).composited(over:CIImage(color:.black).cropped(to:bounds))
        if analysis {
            let scale=min(1,256/max(canvas.width,canvas.height)),reduction=CGAffineTransform(scaleX:scale,y:scale)
            image=image.transformed(by:reduction);matrix=matrix.concatenating(reduction)
        }
        return (image,matrix)
    }
    func motionTime(at compositionTime:Double, source:Double) -> Double {
        guard let hold = clip.frozenFrame else { return source }
        return hold.sourceTime + hold.offset + max(0,compositionTime-timeRange.start.seconds)
    }
    func sourceTime(at time: Double) -> Double { frozenSourceTime ?? clip.frozenFrame?.sourceTime ?? (clip.start + max(0, time - timeRange.start.seconds) * clip.rate) }
}

final class VideoToolCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    #if os(macOS)
    // Native QA can distinguish shader/YCbCr differences from lossy encoder
    // differences. No observer or readback exists in the iPhone build.
    private static let auditLock=NSLock()
    private static var frameAudit:((Double,CIImage,CVPixelBuffer,[VideoEffectFrameLease])->Void)?
    static func auditFrames(_ observer:((Double,CIImage,CVPixelBuffer,[VideoEffectFrameLease])->Void)?) {
        auditLock.lock();frameAudit=observer;auditLock.unlock()
    }
    private static func audit(time:Double,image:CIImage,pixel:CVPixelBuffer,leases:[VideoEffectFrameLease]) {
        auditLock.lock();let observer=frameAudit;auditLock.unlock();observer?(time,image,pixel,leases)
    }
    #endif
    var supportsHDRSourceFrames: Bool { true }
    var supportsWideColorSourceFrames: Bool { true }
    var sourcePixelBufferAttributes: [String: any Sendable]? { [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_32BGRA, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]] }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] { [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelBufferIOSurfacePropertiesKey as String: [String: String]()] }
    private let queue = DispatchQueue(label: "yourec.video.tools", qos: .userInitiated)
    private let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])
    private let nightPicture=NightFixPicture()
    private var effectsRenderer: MetalEffectRenderer?
    private var frameLeases:[VideoEffectFrameLease]=[]
    private var effectsInputs: VideoEffectInputs?
    private let matteProvider=VideoEffectSourceMatteProvider()
    private var sourceReaders: [URL:(reader:VideoEffectSourceReader,capacity:Int,use:Int)] = [:]
    private var readerUse=0
    private func sourceReader(_ url:URL,hdr:Bool,capacity:Int)throws->VideoEffectSourceReader {
        readerUse+=1
        if var entry=sourceReaders[url],entry.capacity>=capacity {
            entry.use=readerUse;sourceReaders[url]=entry;return entry.reader
        }
        sourceReaders[url]=nil
        if sourceReaders.count>=3,let oldest=sourceReaders.min(by:{$0.value.use<$1.value.use})?.key {sourceReaders[oldest]=nil}
        let reader=try VideoEffectSourceReader(url:url,hdr:hdr,capacity:capacity)
        sourceReaders[url]=(reader,capacity,readerUse);return reader
    }
    private let lock = NSLock()
    private var generation = 0
    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}
    func cancelAllPendingVideoCompositionRequests() { lock.lock(); generation += 1; lock.unlock() }
    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        lock.lock(); let token = generation; lock.unlock()
        queue.async { [self] in
            lock.lock(); let cancelled = token != generation; lock.unlock()
            if cancelled { request.finishCancelledRequest(); return }
            let isCancelled={ [self] in lock.lock();defer {lock.unlock()};return token != generation }
            autoreleasepool {
                // Keep pooled A/B/temporal images until the destination render
                // explicitly completes, including deferred Core Image work.
                defer { frameLeases.removeAll(keepingCapacity:true) }
                do {
                guard let destination = request.renderContext.newPixelBuffer() else { request.finish(with: ProjectError.invalidMedia); return }
                var image: CIImage
                let bounds: CGRect, hdr: Bool
                let drawing = (request.videoCompositionInstruction as? ExportInstructionRange)?.original ?? request.videoCompositionInstruction
                if let instruction = drawing as? VideoToolInstruction {
                    image = try render(instruction, request: request,isCancelled:isCancelled); bounds = CGRect(origin: .zero, size: instruction.canvas); hdr = instruction.hdr
                } else if let instruction = drawing as? TrackVideoInstruction {
                    bounds = CGRect(origin: .zero, size: instruction.canvas); hdr = instruction.hdr
                    image = try renderTracks(instruction, request: request, isCancelled: isCancelled)
                    if let subtitles = instruction.subtitles { image = subtitles.render(at: request.compositionTime.seconds, over: image, canvas: instruction.canvas) }
                } else if let instruction = drawing as? TransitionVideoInstruction {
                    bounds = CGRect(origin: .zero, size: instruction.canvas); hdr = instruction.hdr
                    func picture(_ layer: VideoToolInstruction) throws -> CIImage {
                        let image = try render(layer, request: request, overlays: instruction.join?.transition?.style != .split,isCancelled:isCancelled)
                        return instruction.join?.transition?.style == .split ? image.cropped(to: TransitionRenderer.contentBounds(layer)) : image
                    }
                    if let join = instruction.join, var settings = join.transition {
                        let black = TransitionRenderer.fill(settings: settings, canvas: instruction.canvas)
                        let first = try instruction.outgoing.map(picture) ?? black
                        let second = try instruction.incoming.map(picture) ?? black
                        if settings.style == .fadeColor, join.edge != 0 { settings.style = .dissolve }
                        let progress = join.timing.progress(at: request.compositionTime.seconds - join.origin)
                        image = TransitionRenderer.composite(first, second, settings: settings, progress: progress, canvas: instruction.canvas, duration: join.timing.videoDuration,
                            framesPerSecond: 1 / request.renderContext.videoComposition.frameDuration.seconds)
                        if settings.style == .split {
                            var seen = Set<UUID>()
                            for layer in instruction.layers { image = VideoOverlayRenderer.apply(layer, at: request.compositionTime.seconds, over: image, seen: &seen) }
                        }
                    } else { image = try instruction.layers.first.map(picture) ?? CIImage(color: .black).cropped(to: bounds) }
                } else { request.finish(with: ProjectError.invalidMedia); return }
                if isCancelled() {throw CancellationError()}
                VideoColor.tag(destination, hdr: hdr)
                let target=CIRenderDestination(pixelBuffer:destination)
                target.colorSpace=VideoColor.space(hdr:hdr)
                let task=try context.startTask(toRender:image,from:bounds,to:target,at:bounds.origin)
                _=try task.waitUntilCompleted()
                #if os(macOS)
                Self.audit(time:request.compositionTime.seconds,image:image,pixel:destination,leases:frameLeases)
                #endif
                request.finish(withComposedVideoFrame: destination)
                } catch is CancellationError {request.finishCancelledRequest()}
                  catch { request.finish(with: error) }
            }
        }
    }
    private func renderTracks(_ instruction: TrackVideoInstruction, request: AVAsynchronousVideoCompositionRequest, isCancelled: () -> Bool) throws -> CIImage {
        let bounds = CGRect(origin: .zero, size: instruction.canvas)
        let black = CIImage(color: .black).cropped(to: bounds)
        var result = black
        let order = VideoPlacement.ordered(instruction.order, settings: instruction.placements)
        let relation = instruction.transition
        let participants = Set([relation?.outgoing, relation?.incoming].compactMap { $0 })
        let pairTop = order.last { participants.contains($0) }
        func picture(_ id: UUID?) throws -> CIImage {
            guard let id, let layer = instruction.layers[id] else { return black }
            let image = try render(layer, request: request, overlays: relation?.settings.style != .split, isCancelled: isCancelled)
            return relation?.settings.style == .split ? image.cropped(to: TransitionRenderer.contentBounds(layer)) : image
        }
        for id in order {
            if let relation, participants.contains(id) {
                guard id == pairTop else { continue }
                var settings = relation.settings
                let edge = relation.outgoing == nil ? -1 : relation.incoming == nil ? 1 : 0
                let timing = TransitionTiming(settings, factor: relation.factor, edge: edge)
                let fill = TransitionRenderer.fill(settings: settings, canvas: instruction.canvas)
                let first = relation.outgoing == nil ? fill : try picture(relation.outgoing)
                let second = relation.incoming == nil ? fill : try picture(relation.incoming)
                if settings.style == .fadeColor && edge != 0 { settings.style = .dissolve }
                var mixed = TransitionRenderer.composite(first, second, settings: settings,
                    progress: timing.progress(at: request.compositionTime.seconds - relation.origin.seconds), canvas: instruction.canvas, duration: timing.videoDuration,
                    framesPerSecond: 1 / request.renderContext.videoComposition.frameDuration.seconds)
                if settings.style == .split {
                    var seen = Set<UUID>()
                    for participant in participants { if let layer = instruction.layers[participant] { mixed = VideoOverlayRenderer.apply(layer, at: request.compositionTime.seconds, over: mixed, seen: &seen) } }
                }
                result = mixed.composited(over: result)
            } else if let layer = instruction.layers[id] {
                var image = try render(layer, request: request, isCancelled: isCancelled)
                if let settings = instruction.placements[id] {
                    let t = request.compositionTime.seconds
                    let source = layer.motionTime(at:t, source:layer.sourceTime(at:t))
                    let value = settings.motion.map { settings.applying($0.pose(at:source)) } ?? settings
                    image = TrackRenderer.placed(image,settings:value,canvas:instruction.canvas)
                }
                result = image.composited(over: result)
            }
        }
        // Color/black holds can have no active source frame at all.
        if order.isEmpty, let relation { result = TransitionRenderer.fill(settings: relation.settings, canvas: instruction.canvas) }
        return result.cropped(to: bounds)
    }
    private func render(_ instruction: VideoToolInstruction, request: AVAsynchronousVideoCompositionRequest, overlays: Bool = true,isCancelled:()->Bool) throws -> CIImage {
        let canvas = instruction.canvas, bounds = CGRect(origin: .zero, size: canvas)
        let source = request.sourceFrame(byTrackID: instruction.trackID)
        let sourceTime = instruction.sourceTime(at: request.compositionTime.seconds)
        func processed(_ raw: CIImage, at sampleTime: Double) throws -> CIImage {
            let clock = instruction.motionTime(at:request.compositionTime.seconds,source:sampleTime)
            var (image,matrix)=instruction.preparedImage(try nightPicture.render(raw,instruction:instruction,time:sampleTime),at:sampleTime,motionTime:clock)
            var effects = instruction.effectSettings.filter { $0.kind != .stepPrinting && $0.kind != .nightFix }
            if instruction.clip.frozenFrame != nil {
                for index in effects.indices where effects[index].motion != nil {
                    let pose = effects[index].motion!.pose(at:clock)
                    effects[index].motion = nil
                    for (key, n) in pose.values { effects[index].set(key,.number(n)) }
                }
            }
            // A cadence hold freezes the entire rendered look, including
            // parameter animation, light leaks, palette, masks and camera phase.
            // Explicit Freeze Frame remains separate: its Print grain animates.
            let effectTime=instruction.clip.frozenFrame == nil ? sampleTime : sourceTime
            if instruction.videoEffectsEnabled && !effects.isEmpty {
                if effectsRenderer == nil { let renderer = try MetalEffectRenderer(); effectsRenderer = renderer; effectsInputs = VideoEffectInputs(renderer: renderer) }
                if effects.contains(where:{$0.usesTemporalMatte && $0.isActive(at:effectTime)}),instruction.clip.frozenFrame==nil {
                    guard let frames=instruction.sourceFrames,let url=instruction.sourceURL else {throw VideoEffectError.unavailableMatteHistory}
                    let reader=try sourceReader(url,hdr:instruction.sourceHDR,capacity:2)
                    let fps=1/max(0.0001,request.renderContext.videoComposition.frameDuration.seconds)
                    return try matteProvider.render(effects:effects,time:effectTime,frames:frames,identity:instruction.matteIdentity(frameRate:fps),renderer:effectsRenderer!,hdr:instruction.sourceHDR,frameRate:fps,recorded:instruction.effectMatteHistories,equivalentCurrentAllowed:instruction.stabilization==nil,isCancelled:isCancelled,prepare:{time,prefix,histories in
                        let selected=frames.times[frames.last(at:time)]
                        let beforeFirst=selected>time+0.0000001
                        let sample=try reader.sample(at:beforeFirst ? time : selected,firstAtOrAfter:!beforeFirst)
                        let (picture,matrix)=instruction.preparedImage(try self.nightPicture.render(sample.image,instruction:instruction,time:time),at:time)
                        let contexts=try self.effectsInputs!.frameContexts(image:picture,effects:prefix,time:time,folder:instruction.effectFolder,palettes:instruction.effectPalettes,subjects:instruction.effectSubjects,masks:instruction.effectMasks,maskSource:instruction.maskSource,rawSource:sample.image,cancelled:isCancelled,depth:instruction.effectDepth,depthStream:"\(instruction.trackID)|\(instruction.clip.id)",maskTransform:matrix,sourceSize:instruction.sourceSize,analysisTime:beforeFirst ? time : selected,hdr:instruction.sourceHDR,plateColor:instruction.clip.color,plateColorHDR:instruction.hdr,temporalHistories:histories,disableMatteCuts:Set(instruction.effectMatteHistories.filter {$0.value.replay(at:selected)}.keys),currentMatteCuts:Set(instruction.effectMatteHistories.filter {$0.value.replay(at:selected) && !$0.value.accepted(at:selected)}.keys),provisional:instruction.effectAnalysisPending)
                        return .init(image:picture,contexts:contexts)
                    },lease:{self.frameLeases.append($0)})
                }
                let frozenHistories:[UUID:[VideoEffectMatteCache.Frame]]=instruction.clip.frozenFrame==nil ? [:] : Dictionary(uniqueKeysWithValues:effects.filter(\.usesTemporalMatte).map {($0.id,[])})
                var frames = try effectsInputs!.frameContexts(image: image, effects: effects, time: effectTime,
                    folder: instruction.effectFolder, palettes: instruction.effectPalettes,subjects:instruction.effectSubjects, masks:instruction.effectMasks,maskSource:instruction.maskSource,rawSource:raw,cancelled:isCancelled, depth:instruction.effectDepth,depthStream:"\(instruction.trackID)|\(instruction.clip.id)", maskTransform: matrix, sourceSize: instruction.sourceSize,analysisTime:sampleTime,hdr:instruction.sourceHDR,plateColor:instruction.clip.color,plateColorHDR:instruction.hdr,temporalHistories:frozenHistories,provisional:instruction.effectAnalysisPending)
                if let frozen = instruction.clip.frozenFrame {
                    for id in frames.keys { frames[id]?.holdTime = frozen.offset + max(0, request.compositionTime.seconds-instruction.timeRange.start.seconds) }
                    // A freeze introduces no new source frames. Its explicit
                    // Print decoration may animate, but cannot advance source
                    // matte history or mix in footage preceding the hold.
                }
                image = try effectsRenderer!.render(image, effects: effects, sourceTime: effectTime,
                    presentationTime: instruction.clip.frozenFrame == nil ? sampleTime : request.compositionTime.seconds,
                    hdr: instruction.sourceHDR, frameRate: 1/max(0.0001,request.renderContext.videoComposition.frameDuration.seconds), contexts: frames, lease: { self.frameLeases.append($0) })
            }
            return image
        }
        var image: CIImage
        if let frozen = instruction.frozenSourceTime, let url = instruction.sourceURL {
            let raw = try sourceReader(url, hdr: instruction.sourceHDR, capacity: 2).sample(at: frozen).image
            image = try processed(raw, at: frozen)
        } else if (instruction.videoEffectsEnabled || instruction.clip.frozenFrame != nil),let plan = VideoEffectSamplePlan.make(clip: instruction.clip, sourceTime: sourceTime, sourceFPS: instruction.sourceFPS,clock:instruction.sequenceClock,frames:instruction.sourceFrames), let url = instruction.sourceURL {
            let reader=try sourceReader(url,hdr:instruction.sourceHDR,capacity:plan.times.count>1 ? 8 : 2)
            let leaseBase=frameLeases.count
            let firstSample=try reader.sample(at:plan.times[0],firstAtOrAfter:plan.firstAtOrAfter,before:plan.before)
            let first = try processed(firstSample.image, at:firstSample.time)
            image = first
            if plan.times.count > 1 && plan.smear > 0 {
                // Core Image evaluates this accumulation in extended linear
                // sRGB. Normalized dissolves avoid multiplying alpha twice.
                let weight = plan.smear/Double(plan.times.count)
                var accumulatedWeight = 1-plan.smear+weight
                var sum = first
                for time in plan.times.dropFirst() {
                    if isCancelled() {throw CancellationError()}
                    let nextSample=try reader.sample(at:time,firstAtOrAfter:plan.firstAtOrAfter,before:plan.before)
                    let next = try processed(nextSample.image, at:nextSample.time)
                    accumulatedWeight += weight
                    let blend=sum.applyingFilter("CIDissolveTransition", parameters: ["inputTargetImage": next, "inputTime": weight/accumulatedWeight])
                    if effectsRenderer == nil { effectsRenderer=try MetalEffectRenderer();effectsInputs=VideoEffectInputs(renderer:effectsRenderer!) }
                    var retained:VideoEffectFrameLease?
                    sum=try effectsRenderer!.materialize(blend,lease:{retained=$0})
                    frameLeases.removeSubrange(leaseBase..<frameLeases.count)
                    if let retained {frameLeases.append(retained)}
                }
                image = sum.cropped(to: bounds)
            }
        } else if instruction.readsSourceFrames,let url=instruction.sourceURL,let frames=instruction.sourceFrames {
            let selected=frames.times[frames.last(at:sourceTime)]
            let raw:CIImage
            if selected>sourceTime+0.0000001 {raw=CIImage(color:.black).cropped(to:CGRect(origin:.zero,size:instruction.sourceSize))}
            else {raw=try sourceReader(url,hdr:instruction.sourceHDR,capacity:2).sample(at:selected,firstAtOrAfter:true).image}
            image=try processed(raw,at:sourceTime)
        } else if instruction.sourceLog != nil, let url = instruction.sourceURL {
            // Read native Log buffers. AVVideoComposition may otherwise convert
            // a requested source buffer to its declared display output space.
            let raw = try sourceReader(url, hdr: false, capacity: 2).sample(at: sourceTime).image
            image = try processed(raw, at: sourceTime)
        } else { image = try processed(source.map { LogColor.image($0) } ?? CIImage(color: .black).cropped(to: bounds), at: sourceTime) }
        if overlays && instruction.overlaysEnabled {
            var seen = Set<UUID>(); image = VideoOverlayRenderer.apply(instruction, at: request.compositionTime.seconds, over: image, seen: &seen)
        }
        return image
    }

}

enum VideoOverlayRenderer {
    static func apply(_ instruction: VideoToolInstruction, at time: Double, over background: CIImage, seen: inout Set<UUID>) -> CIImage {
        let canvas = instruction.canvas, bounds = CGRect(origin: .zero, size: canvas)
        let sourceTime = instruction.sourceTime(at: time)
        var image = background
        let motionTime = instruction.motionTime(at:time, source:sourceTime)
        for (overlay, bitmap) in instruction.images where sourceTime >= overlay.start - 0.00001 && sourceTime < overlay.end - 0.00001 && seen.insert(overlay.id).inserted {
            let overlay = overlay.motion.map { overlay.applying($0.pose(at:motionTime)) } ?? overlay
            let size = CGSize(width: bitmap.width, height: bitmap.height), rect = overlay.rect(image: size, canvas: canvas)
            let picture = CIImage(cgImage: bitmap).transformed(by: CGAffineTransform(scaleX: rect.width / size.width, y: rect.height / size.height))
                .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
            image = ImageOverlayRenderer.composite(picture, opacity: overlay.opacity, over: image).cropped(to: bounds)
        }
        func draw(_ text: TextOverlay, _ bitmap: CGImage, ranges: TitleMotionRanges) {
            guard sourceTime >= text.start - 0.00001, sourceTime < text.end - 0.00001, seen.insert(text.id).inserted else { return }
            let global = ranges.range(for:text,at:time)
            let range = global ?? (text.start...text.end)
            let clock = global == nil ? sourceTime : time
            guard let frame = text.drawFrame(bitmap, canvas: canvas, time: clock, range: range) else { return }
            image = frame.composite(over: image, canvas: canvas, displayBlend:true)
        }
        for (text, bitmap) in instruction.textImages { draw(text, bitmap, ranges: instruction.titleRanges) }
        if let draft = instruction.previewTitle { draw(draft.text, draft.bitmap, ranges: draft.ranges) }
        return image
    }
}

enum ImageOverlayRenderer {
    // Match SwiftUI/UIKit's encoded-space alpha blend in the placement and crop
    // workspaces. Extended sRGB preserves HDR values above reference white.
    static func composite(_ picture: CIImage, opacity: Double, over background: CIImage) -> CIImage {
        let space = CGColorSpace(name: CGColorSpace.extendedSRGB)!
        guard let foreground = picture.matchedFromWorkingSpace(to: space),
              let backdrop = background.matchedFromWorkingSpace(to: space) else { return picture.composited(over: background) }
        let faded = foreground.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)])
        return faded.composited(over: backdrop).matchedToWorkingSpace(from: space) ?? background
    }
}

enum ColorLUT {
    static let dimension = 33
    // Authored SDR creative LUTs. No external weights, licensed looks or Log
    // camera transforms. Identity-to-look interpolation controls the strength.
    private static let cubes: [ColorLook: Data] = Dictionary(uniqueKeysWithValues: ColorLook.allCases.map { look in
        var values: [Float] = []; values.reserveCapacity(dimension * dimension * dimension * 4)
        for b in 0..<dimension { for g in 0..<dimension { for r in 0..<dimension {
            var rgb = [Double(r), Double(g), Double(b)].map { $0 / Double(dimension - 1) }
            let luma = rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722
            switch look {
            case .natural: break
            case .warm: rgb[0] = pow(rgb[0], 0.92); rgb[2] = pow(rgb[2], 1.10)
            case .cool: rgb[0] = pow(rgb[0], 1.08); rgb[2] = pow(rgb[2], 0.92)
            case .mono: rgb = [luma, luma, luma]
            case .cinema:
                rgb = rgb.map { min(1, max(0, 0.5 + ($0 - 0.5) * 1.12)) }
                rgb[0] += 0.035 * luma; rgb[1] += 0.012 * (1 - luma); rgb[2] += 0.035 * (1 - luma)
                rgb = rgb.map { luma + ($0 - luma) * 0.85 }
            case .portrait:
                rgb = rgb.map { luma + ($0 - luma) * 0.92 }
                rgb[0] += 0.018 * luma * (1 - luma); rgb[2] -= 0.025 * luma * (1 - luma)
                rgb = rgb.map { $0 * 0.95 + 0.025 }
            case .daylight:
                rgb = rgb.map { 0.5 + ($0 - 0.5) * 1.04 }
                rgb = rgb.map { luma + ($0 - luma) * 1.08 }
            case .goldenHour:
                rgb[0] += 0.12 * luma * (1 - luma); rgb[1] += 0.025 * luma
                rgb[2] *= 0.86; rgb = rgb.map { pow(max(0, $0), 0.95) }
            case .mutedFilm:
                rgb = rgb.map { 0.055 + 0.89 * (luma + ($0 - luma) * 0.72) }
                rgb[2] += 0.018 * (1 - luma)
            case .richContrast:
                rgb = rgb.map { let x = min(1, max(0, $0)); return x * x * (3 - 2 * x) * 0.55 + x * 0.45 }
            case .pastel:
                rgb = rgb.map { 0.075 + 0.88 * pow(max(0, luma + ($0 - luma) * 0.65), 0.91) }
            case .night:
                rgb = rgb.map { max(0, $0 * 0.94 - 0.012) }
                rgb[2] += 0.045 * (1 - luma); rgb[1] += 0.012 * (1 - luma)
            case .silver:
                let y = pow(max(0, rgb[0] * 0.3 + rgb[1] * 0.6 + rgb[2] * 0.1), 0.92)
                rgb = [y * 0.98, y, min(1, y * 1.015)]
            case .ink:
                let y = min(1, max(0, (luma - 0.08) / 0.84)); let dense = y * y * (3 - 2 * y)
                rgb = [dense, dense, dense]
            }
            values.append(contentsOf: rgb.map { Float(min(1, max(0, $0))) }); values.append(1)
        } } }
        return (look, values.withUnsafeBytes { Data($0) })
    })
    static func apply(_ settings: ColorSettings, to image: CIImage, hdr: Bool = false, folder: URL? = nil, sourceLog: LUTInput? = nil) -> CIImage {
        var balanced = image
        if let ev = settings.exposure, ev != 0 { balanced = balanced.applyingFilter("CIExposureAdjust", parameters: ["inputEV": ev]) }
        let warmth = settings.warmth ?? 0, tint = settings.tint ?? 0
        if warmth != 0 || tint != 0 {
            balanced = balanced.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 6500 + warmth * 2500, y: tint * 100)])
        }
        balanced = LogColor.highlights(balanced, amount: settings.highlights ?? 0)
        if sourceLog != nil { balanced = LogColor.localRecovery(balanced, amount: settings.localRecovery ?? 0) }
        let viewed = sourceLog == nil ? balanced : LogColor.display(balanced)
        guard settings.amount > 0, settings.imported != nil || settings.look != .natural else { return viewed }
        // LUT entries are display RGB, not linear-light RGB. Core Image's
        // working space is linear; explicitly enter and leave the LUT domain.
        let space = VideoColor.space(hdr: false)
        let encoded = viewed.matchedFromWorkingSpace(to: space) ?? viewed
        let mapped: CIImage
        if let lut = settings.imported, let folder, let cube = try? LUTAssets.load(lut, folder: folder) {
            mapped = cube.apply(to: lut.input == .rec709 ? encoded : LogColor.encode(balanced, profile: lut.input))
        } else if let cube = cubes[settings.look] {
            mapped = encoded.applyingFilter("CIColorCube", parameters: ["inputCubeDimension": dimension, "inputCubeData": cube, "inputExtrapolate": true])
        } else { return viewed }
        let graded = mapped.matchedToWorkingSpace(from: space) ?? mapped
        if settings.amount >= 1 { return graded }
        return graded.applyingFilter("CIDissolveTransition", parameters: ["inputTargetImage": viewed, "inputTime": 1 - settings.amount]).cropped(to: image.extent)
    }
}

enum TextRasterizer {
    static func image(_ text: TextOverlay, canvas: CGSize, folder: URL? = nil) -> CGImage? {
        guard !text.text.isEmpty, canvas.width > 0, canvas.height > 0 else { return nil }
        let fontSize = max(8, min(canvas.width, canvas.height) * text.size)
        if let design = text.appearance {
            let layout = StyledTextLayout(text: text.text, design: design, fontSize: fontSize, maxWidth: canvas.width * 0.94, folder: folder)
            return layout.image(scale: min(1, canvas.width / layout.bounds.width, canvas.height / layout.bounds.height))
        }
        let regular = CTFontCreateUIFontForLanguage(.system, fontSize, nil)!
        let font = text.style == .clean ? regular : CTFontCreateCopyWithSymbolicTraits(regular, fontSize, nil, .boldTrait, .boldTrait) ?? regular
        let (r, g, b) = text.color.rgb
        let color = CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
        var alignment = CTTextAlignment.center
        let paragraph = withUnsafePointer(to: &alignment) { pointer in
            var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: pointer)
            return CTParagraphStyleCreate(&setting, 1)
        }
        let foreground = text.style == .highlight ? CGColor(gray: 0.03, alpha: 1) : color
        let string = NSAttributedString(string: text.text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): foreground,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph
        ])
        let setter = CTFramesetterCreateWithAttributedString(string)
        let padding = fontSize * 0.35
        let maxWidth = canvas.width * 0.84 - padding * 2
        let fitting = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil,
            CGSize(width: maxWidth, height: canvas.height * 0.8), nil)
        let width = Int(ceil(min(maxWidth, max(fontSize, fitting.width)) + 2 * padding))
        let height = Int(ceil(min(canvas.height * 0.8, fitting.height) + 2 * padding))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        if text.style == .box || text.style == .highlight {
            context.setFillColor(text.style == .box ? CGColor(gray: 0.02, alpha: 0.82) : color)
            context.addPath(CGPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerWidth: padding * 0.7, cornerHeight: padding * 0.7, transform: nil)); context.fillPath()
        } else { context.setShadow(offset: CGSize(width: 0, height: -fontSize * 0.04), blur: fontSize * 0.12, color: CGColor(gray: 0, alpha: 0.9)) }
        let path = CGPath(rect: bounds.insetBy(dx: padding, dy: padding), transform: nil)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, context)
        return context.makeImage()
    }
    static func origin(_ text: TextOverlay, imageSize: CGSize, canvas: CGSize) -> CGPoint {
        // Clamp to the recorded frame, not the device screen or its safe area.
        CGPoint(x: max(0, min(canvas.width - imageSize.width, text.x * canvas.width - imageSize.width / 2)),
                y: max(0, min(canvas.height - imageSize.height, (1 - text.y) * canvas.height - imageSize.height / 2)))
    }
}
