@preconcurrency import AVFoundation
import CoreImage
import CryptoKit

// Optical printing groups actual source frames, including variable-rate movies.
// AVAssetTrack.nominalFrameRate is an average, not a list of frame timestamps.
struct VideoEffectFrameIndex:Codable {
    let times:[Double]
    var valid:Bool {!times.isEmpty && times.count<=3_000_000 && times.allSatisfy {$0.isFinite && (0...604800).contains($0)} && zip(times,times.dropFirst()).allSatisfy {$0<$1}}
    func first(at time:Double)->Int {
        var a=0,b=times.count
        while a<b {let m=(a+b)/2;if times[m]<time-0.0000001 {a=m+1}else {b=m}}
        return a
    }
    func last(at time:Double)->Int {
        var a=0,b=times.count
        while a<b {let m=(a+b)/2;if times[m]<=time+0.0000001 {a=m+1}else {b=m}}
        return max(0,a-1)
    }
    func block(at time:Double,origin:Double,count:Int,lower:Double,upper:Double,firstAtOrAfter:Bool)->[Double] {
        let start=last(at:origin),index=firstAtOrAfter ? first(at:time) : last(at:time)
        let block=start+(max(start,min(times.count-1,index))-start)/count*count
        let minimum=min(times.count-1,first(at:lower)),lastBefore=first(at:upper)-1
        if lastBefore<minimum {return Array(repeating:times[last(at:lower)],count:count)}
        let maximum=min(times.count-1,lastBefore)
        return (0..<count).map {times[min(maximum,max(minimum,block+$0))]}
    }
}
actor VideoEffectFrameAnalysis {
    static let shared=VideoEffectFrameAnalysis()
    private var indices:[String:VideoEffectFrameIndex]=[:]
    func index(url:URL,folder:URL) async throws -> VideoEffectFrameIndex {
        let info=try url.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey])
        let identity="source-output-pts-v3-\(url.standardizedFileURL.path)-\(info.fileSize ?? 0)-\(info.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        let key=SHA256.hash(data:Data(identity.utf8)).map {String(format:"%02x",$0)}.joined()
        if let index=indices[key] {return index}
        let cache=ProjectCacheLocation.root(in:folder,preferred:"cache"),file=cache.appendingPathComponent("frames-\(key).json")
        if let size=try? file.resourceValues(forKeys:[.fileSizeKey]).fileSize,size<=64_000_000,
           let data=try? Data(contentsOf:file),let index=try? JSONDecoder().decode(VideoEffectFrameIndex.self,from:data),index.valid {
            if indices.count>=8 {indices.removeAll()};indices[key]=index;return index
        }
        let asset=AVURLAsset(url:url)
        guard let video=try await asset.loadTracks(withMediaType:.video).first else {throw ProjectError.invalidMedia}
        // Another caller may have finished while this actor loaded the track.
        if let index=indices[key] {return index}
        let index:VideoEffectFrameIndex
        do {index=try scan(asset:asset,video:video,references:true)}
        catch is CancellationError {throw CancellationError()}
        catch {index=try scan(asset:asset,video:video,references:false)}
        // The index remains usable if a disposable cache cannot be written.
        if (try? FileManager.default.createDirectory(at:cache,withIntermediateDirectories:true)) != nil {
            try? JSONEncoder().encode(index).write(to:file,options:.atomic)
        }
        if indices.count>=8 {indices.removeAll()};indices[key]=index
        return index
    }
    private func scan(asset:AVAsset,video:AVAssetTrack,references:Bool)throws->VideoEffectFrameIndex {
        let reader=try AVAssetReader(asset:asset)
        // Read timing references without walking gigabytes of compressed data.
        // A decoder fallback handles formats without sample-reference support.
        let output:AVAssetReaderOutput=references ? AVAssetReaderSampleReferenceOutput(track:video) : AVAssetReaderTrackOutput(track:video,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        guard reader.canAdd(output) else {throw ProjectError.invalidMedia}
        output.alwaysCopiesSampleData=false;reader.add(output)
        guard reader.startReading() else {throw reader.error ?? ProjectError.invalidMedia}
        defer {if reader.status == .reading {reader.cancelReading()}}
        var times:[Double]=[]
        while let sample=output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            // Compressed readers also emit zero-sample edit/drain markers. The
            // output PTS includes container edit lists and differs from the codec
            // PTS (notably H.264 B-frame priming). Index displayed frames only.
            guard sample.numSamples>0 else {continue}
            if let attachments=CMSampleBufferGetSampleAttachmentsArray(sample,createIfNecessary:false) as? [[CFString:Any]],
               attachments.first?[kCMSampleAttachmentKey_DoNotDisplay] as? Bool == true {continue}
            let time=CMSampleBufferGetOutputPresentationTimeStamp(sample).seconds
            guard time.isFinite,times.count<3_000_000 else {throw ProjectError.invalidMedia}
            if time>=0 {times.append(time)}
        }
        guard reader.status == .completed else {throw reader.error ?? ProjectError.invalidMedia}
        let index=VideoEffectFrameIndex(times:Array(Set(times)).sorted())
        guard index.valid else {throw ProjectError.invalidMedia}
        return index
    }
}

// Keep the original trim bounds, but integrate from the effect's own origin.
// Pauses and split points cannot reset the source-domain phase.
struct VideoEffectSequenceClock {
    let lower:Double,upper:Double
    let cadence:VideoEffectCadenceClock
    init(_ clip:TimelineClip) {
        lower=clip.start;upper=clip.end
        var extended=clip;extended.pauses=nil
        let effects=(clip.videoEffects ?? []).filter {$0.enabled && [.superEight,.undercranking].contains($0.kind)}
        extended.start=min(clip.start,effects.map(\.start).min() ?? clip.start)
        extended.end=max(clip.end,effects.map(\.end).max() ?? clip.end)
        cadence=VideoEffectCadenceClock(effects:effects,rates:extended.effectPlaybackSpans.map {($0.start,$0.end,$0.rate)})
    }
}

struct VideoEffectSamplePlan {
    var times: [Double]
    var smear: Double
    var firstAtOrAfter=false
    var before=Double.infinity
    static func make(clip: TimelineClip, sourceTime: Double, sourceFPS: Double,clock:VideoEffectSequenceClock,frames:VideoEffectFrameIndex?=nil) -> VideoEffectSamplePlan? {
        if let frozen = clip.frozenFrame { return VideoEffectSamplePlan(times: [frozen.sourceTime], smear: 0) }
        let effects = (clip.videoEffects ?? []).filter { $0.enabled && sourceTime >= $0.start && sourceTime < $0.end }
        var sample = sourceTime, changed = false
        if let hold=clock.cadence.hold(at:sourceTime) {
            sample=hold.boundary
            changed=true
        }
        if let step = effects.first(where: { $0.kind == .stepPrinting }) {
            let count = max(2, Int(step.number("step", at: sourceTime)))
            if let frames {
                return VideoEffectSamplePlan(times:frames.block(at:sample,origin:step.start,count:count,lower:clock.lower,upper:clock.upper,firstAtOrAfter:changed),smear:step.number("smear",at:sourceTime),firstAtOrAfter:true,before:clock.upper)
            }
            // A fallback for an isolated caller without a file index. Production
            // instructions always provide one; nearest sampling avoids duplicate
            // slots caused by sub-frame timestamp rounding.
            let selected=changed ? VideoEffectTime.firstFrame(atOrAfter:sample,fps:sourceFPS) : sample
            let frame = Int(floor(max(0,selected-step.start)*sourceFPS+0.00001))
            let first = (frame/count)*count
            let last=max(clock.lower,clock.upper-1.0/sourceFPS)
            let times = (0..<count).map { min(last, max(clock.lower, step.start+(Double(first+$0)-0.5)/sourceFPS)) }
            return VideoEffectSamplePlan(times:times,smear:step.number("smear",at:sourceTime),firstAtOrAfter:true,before:clock.upper)
        }
        // Integration pieces can be shorter than a frame. Clamp to the original
        // clip, never to the current speed-ramp piece, which would break a hold.
        return changed ? VideoEffectSamplePlan(times:[min(clock.upper-0.00001,max(clock.lower,sample))],smear:0,firstAtOrAfter:true,before:clock.upper) : nil
    }
}

// Small sequential reader for edit-only temporal effects. Retain at most one
// six-frame accumulation block; out-of-order editor seeks start a new decode.
final class VideoEffectSourceReader {
    private let asset: AVURLAsset
    private let track: AVAssetTrack
    private let duration: CMTime
    private let format: OSType
    private let sourceMaskInput: Bool
    private let useCompositionColorFallback: Bool
    private let capacity: Int
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var pending: CMSampleBuffer?
    private var frames: [(Double, CIImage)] = []
    init(url: URL, hdr: Bool, capacity: Int = 8, highPrecision:Bool=false, sourceMaskInput: Bool = false) throws {
        self.sourceMaskInput = sourceMaskInput
        self.capacity=max(2,capacity)
        asset = AVURLAsset(url: url)
        guard let video = asset.tracks(withMediaType: .video).first else { throw ProjectError.invalidMedia }
        track = video; duration = asset.duration
        useCompositionColorFallback = !sourceMaskInput && !video.formatDescriptions.contains { value in
            let format = value as! CMFormatDescription
            return LogColor.profile(format) != nil || CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) != nil
                && CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) != nil
        }
        format = hdr || highPrecision || !sourceMaskInput && video.formatDescriptions.contains { LogColor.profile($0 as! CMFormatDescription) != nil } ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }
    func frame(at time: Double) throws -> CIImage {
        try sample(at:time).image
    }
    func sample(at time:Double,firstAtOrAfter:Bool=false,before:Double = .infinity) throws -> (time:Double,image:CIImage) {
        let tolerance=firstAtOrAfter ? 0.0000001 : 0.0001
        if let found = frames.first(where: { abs($0.0-time)<tolerance && $0.0<before }) { return (found.0,found.1) }
        if firstAtOrAfter,let lower=frames.first,lower.0<=time,
           let found=frames.first(where:{$0.0>=time-tolerance && $0.0<before}) {return (found.0,found.1)}
        if reader == nil || time < (frames.first?.0 ?? time) - 0.0001 || time > (frames.last?.0 ?? time)+1 {
            reader?.cancelReading(); let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: format])
            output.alwaysCopiesSampleData = false; reader.add(output)
            reader.timeRange = CMTimeRange(start: CMTime(seconds: max(0,time-1.0/30), preferredTimescale: 60000), end: duration)
            guard reader.startReading() else { throw reader.error ?? ProjectError.invalidMedia }
            self.reader = reader; self.output = output; pending = nil; frames.removeAll(keepingCapacity: true)
        }
        while let sample = pending ?? output?.copyNextSampleBuffer() {
            let stamp=CMSampleBufferGetPresentationTimeStamp(sample).seconds
            if stamp>=before || (!firstAtOrAfter && stamp > time+0.0001 && !frames.isEmpty) { pending = sample; break }
            pending = nil
            if let pixel = CMSampleBufferGetImageBuffer(sample) {
                // AVVideoComposition applies its declared 709/HLG fallback to
                // untagged media. A direct reader otherwise guesses Composite
                // NTSC for small SDR footage, changing color during a freeze.
                // Preserve explicitly tagged footage; align only guessed input.
                if useCompositionColorFallback, CVBufferCopyAttachment(pixel, "ColorInfoGuessedBy" as CFString, nil) != nil {
                    VideoColor.tag(pixel, hdr: VideoColor.isHDR(pixel))
                    CVBufferRemoveAttachment(pixel, kCVImageBufferCGColorSpaceKey)
                }
                // Match the native image supplied to Vision by the persisted
                // source-mask analyser, including its treatment of untagged media.
                frames.append((stamp, sourceMaskInput ? CIImage(cvPixelBuffer: pixel) : LogColor.image(pixel)))
                if frames.count > capacity { frames.removeFirst() }
            }
            if firstAtOrAfter && stamp>=time-tolerance {break}
        }
        if reader?.status == .failed { throw reader?.error ?? ProjectError.invalidMedia }
        let eligible=frames.filter {$0.0<before}
        let selected=firstAtOrAfter ? eligible.first(where:{$0.0>=time-tolerance}) ?? eligible.last : eligible.filter({$0.0<=time+0.0001}).last ?? eligible.first
        guard let closest=selected else { throw ProjectError.invalidMedia }
        return (closest.0,closest.1)
    }
}

// Every historical matte is produced from its complete upstream prefix. The
// recursion strictly shortens that prefix: E never needs its own history to
// produce its raw matte. This avoids caching partially warmed downstream masks.
struct VideoEffectRecordedMatteHistory:Sendable {
    let times:[Double]
    let resets:[Double]
    let finalized:Bool
    let fingerprint:String
    init?(samples:[CapturedMatteSample],finalized:Bool,source:VideoEffectFrameIndex) {
        guard source.valid,!samples.isEmpty,samples.count<=2_000_000 else {return nil}
        let values=samples.map(\.time)
        // A sidecar from a re-encoded/different source must not silently select
        // nonexistent frames. Captured movies and their sidecars use 600 ticks.
        guard values.allSatisfy({time in source.times[source.last(at:time)]==time}) else {return nil}
        times=values;resets=samples.filter(\.reset).map(\.time);self.finalized=finalized
        var hash=SHA256()
        hash.update(data:Data([finalized ? 1 : 0]))
        var packed=Data(capacity:samples.count*8)
        for sample in samples {
            var value=(UInt64(sample.tick) | (sample.reset ? 1<<63 : 0)).littleEndian
            withUnsafeBytes(of:&value) {packed.append(contentsOf:$0)}
        }
        hash.update(data:packed)
        fingerprint=hash.finalize().map {String(format:"%02x",$0)}.joined()
    }
    func replay(at time:Double)->Bool {finalized || time<=(times.last ?? -.infinity)}
    func accepted(at time:Double)->Bool {
        var a=0,b=times.count
        while a<b {let m=(a+b)/2;if times[m]<time {a=m+1}else {b=m}}
        return a<times.count && times[a]==time
    }
    func lastReset(at time:Double)->Double? {
        var a=0,b=resets.count
        while a<b {let m=(a+b)/2;if resets[m]<=time {a=m+1}else {b=m}}
        return a>0 ? resets[a-1] : nil
    }
    func preceding(_ time:Double,count:Int)->[Double] {
        var a=0,b=times.count
        while a<b {let m=(a+b)/2;if times[m]<time {a=m+1}else {b=m}}
        return Array(times[max(0,a-count)..<a])
    }
}
final class VideoEffectSourceMatteProvider {
    struct Prepared {
        let image:CIImage
        var contexts:[UUID:FrameContext]
    }
    private var prefixPlans:[([VideoEffectSettings],[Int:String])]=[]
    private(set) var historicalRenders=0
    private(set) var cacheHits=0
    func render(effects:[VideoEffectSettings],time:Double,frames:VideoEffectFrameIndex,
                identity:String,renderer:MetalEffectRenderer,hdr:Bool=false,frameRate:Double=30,recorded:[UUID:VideoEffectRecordedMatteHistory]=[:],
                mapInputOnly:Bool=false,equivalentCurrentAllowed:Bool=false,isCancelled:()->Bool={false},
                prepare:(Double,[VideoEffectSettings],[UUID:[VideoEffectMatteCache.Frame]])throws->Prepared,
                lease:((VideoEffectFrameLease)->Void)?=nil)throws->CIImage {
        let ordered=VideoEffectSettings.ordered(effects).filter {$0.kind != .stepPrinting}
        func checkCancellation()throws {
            try Task.checkCancellation()
            if isCancelled() {throw CancellationError()}
        }
        try checkCancellation()
        // Compare the recipe once per request, not for every recursive lookup.
        let suffixes:[Int:String]
        if let cached=prefixPlans.first(where:{$0.0==ordered}) {suffixes=cached.1}
        else {
            let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
            var built:[Int:String]=[:]
            for (index,effect) in ordered.enumerated() where effect.usesTemporalMatte {
                built[index+1]=SHA256.hash(data:try encoder.encode(Array(ordered.prefix(index+1)))).map {String(format:"%02x",$0)}.joined()
            }
            suffixes=built
            if prefixPlans.count>=8 {prefixPlans.removeFirst()};prefixPlans.append((ordered,built))
        }
        func origin(_ effect:VideoEffectSettings,at t:Double)->Double? {
            guard effect.isActive(at:t) else {return nil}
            let zero=effect.parameters.first(where:{$0.id=="intensity"})?.keyframes.last(where:{$0.time<=t && $0.time>=effect.start && $0.value == .number(0)})?.time
            guard let zero else {return effect.start}
            // A zero-intensity boundary is open. Unlike effect.start, its raw
            // matte does not exist at that exact instant. Start at the first
            // actual source frame that satisfies the renderer's predicate.
            var index=frames.first(at:zero)
            while index<frames.times.count && frames.times[index]<=t {
                if frames.times[index]>zero && effect.isActive(at:frames.times[index]) {return frames.times[index]}
                index+=1
            }
            return nil
        }
        func canonical(_ effect:VideoEffectSettings,at t:Double)->Double? {
            guard let origin=origin(effect,at:t) else {return nil}
            let index=frames.last(at:t)
            guard frames.times[index]<=t+0.0000001 else {return nil}
            let result=max(frames.times[index],origin)
            return result<=t && effect.isActive(at:result) ? result : nil
        }
        func sameEvaluation(_ prefix:[VideoEffectSettings],_ a:Double,_ b:Double)->Bool {
            if a==b {return true}
            guard equivalentCurrentAllowed else {return false}
            return prefix.enumerated().allSatisfy {index,effect in
                let ownRaw=index==prefix.count-1
                let rawKeyParameters:Set<String>=["screenColor","screenType","autoScreen","strength","balance","blackClip","whiteClip","softness","grow","personHint","cleanPlate"]
                let relevant=effect.parameters.filter {parameter in
                    if ownRaw && parameter.id=="intensity" {return false}
                    return !ownRaw || effect.kind != .chromaKey || rawKeyParameters.contains(parameter.id)
                }
                guard effect.isActive(at:a)==effect.isActive(at:b),relevant.allSatisfy({$0.keyframes.isEmpty}) else {return false}
                guard effect.isActive(at:a) else {return true}
                switch effect.kind {
                case .crashZoom,.dollyZoom,.undercranking,.superEight,.freezeFrame:return false
                case .noir:return !effect.toggle("grain",at:a)
                case .chromaKey,.autoBackground:return ownRaw || effect.choice("background",at:a) != "Video"
                default:return true
                }
            }
        }
        func key(_ prefix:[VideoEffectSettings],at t:Double)throws->VideoEffectMatteCache.Key {
            guard let suffix=suffixes[prefix.count] else {throw VideoEffectError.unavailableMatteHistory}
            return .init(device:renderer.device.registryID,stream:"source-matte-v1-"+identity+"-"+suffix,time:t)
        }
        func raw(_ prefix:[VideoEffectSettings],at t:Double)throws->VideoEffectMatteCache.Frame {
            try checkCancellation()
            let requested=try key(prefix,at:t)
            if let cached=VideoEffectMatteCache.shared.frame(for:requested) {cacheHits+=1;return cached}
            historicalRenders+=1
            var captured:VideoEffectMatteCache.Frame?
            _=try renderPrefix(prefix,at:t,rawOnly:prefix.last!.id,capture:{id,frame in if id==prefix.last!.id {captured=frame}},lease:nil)
            guard let captured else {throw VideoEffectError.unavailableMatteHistory}
            return captured
        }
        func renderPrefix(_ prefix:[VideoEffectSettings],at t:Double,rawOnly:UUID?,capture:((UUID,VideoEffectMatteCache.Frame)->Void)?,lease:((VideoEffectFrameLease)->Void)?)throws->CIImage {
            try checkCancellation()
            var histories:[UUID:[VideoEffectMatteCache.Frame]]=[:]
            for (index,effect) in prefix.enumerated() where effect.usesTemporalMatte && effect.isActive(at:t) && effect.id != rawOnly {
                let kind:VideoEffectMatteKind=effect.kind == .chromaKey ? .key : .isolation
                var values:[VideoEffectMatteCache.Frame]=[]
                if var start=origin(effect,at:t) {
                    var times=frames.times
                    if let captured=recorded[effect.id] {
                        let current=frames.times[frames.last(at:t)]
                        if captured.replay(at:current) {
                            start=max(start,captured.lastReset(at:current) ?? start)
                            times=captured.preceding(current,count:kind.capacity-1)+[current]
                        } else {
                            // The raw movie can outlive its last crash checkpoint.
                            // Recover that tail using complete source frames.
                            start=max(start,captured.times.last ?? start)
                        }
                    }
                    if let window=VideoEffectTemporalWindow.make(times:times,at:t,start:start,kind:kind) {
                    let upstream=Array(prefix.prefix(index+1))
                    // Produce oldest first to reuse upstream current raws in the
                    // next historical frame; the GPU consumes newest first.
                    for frame in window.indices.dropLast() {
                        let sample=max(times[frame],start)
                        if effect.isActive(at:sample) {values.append(try raw(upstream,at:sample))}
                    }
                    }
                }
                histories[effect.id]=Array(values.reversed())
            }
            // frameContexts reuses placed mask textures. Preparing it before
            // recursion would let history renders overwrite the current mask.
            try checkCancellation()
            var prepared=try prepare(t,prefix,histories)
            for (index,effect) in prefix.enumerated() where effect.usesTemporalMatte && effect.isActive(at:t) {
                var context=prepared.contexts[effect.id] ?? FrameContext(presentationTime:t,frameIndex:VideoEffectTime.frameIndex(t,fps:frameRate))
                context.matteHistory=histories[effect.id]
                context.matteDetectCuts = !(recorded[effect.id]?.replay(at:frames.times[frames.last(at:t)]) ?? false)
                context.matteDetectCurrentCut = !context.matteDetectCuts && !(recorded[effect.id]?.accepted(at:frames.times[frames.last(at:t)]) ?? true)
                context.matteOnly=effect.id==rawOnly
                let upstream=Array(prefix.prefix(index+1))
                if effect.id==rawOnly {context.matteCapture=try key(upstream,at:t)}
                else if let canonical=canonical(effect,at:t),sameEvaluation(upstream,canonical,t) {context.matteCapture=try key(upstream,at:canonical)}
                prepared.contexts[effect.id]=context
            }
            return try renderer.render(prepared.image,effects:prefix,sourceTime:t,hdr:hdr,frameRate:frameRate,mapInputOnly:mapInputOnly,contexts:prepared.contexts,lease:lease,captureMatte:capture)
        }
        return try renderPrefix(ordered,at:time,rawOnly:nil,capture:nil,lease:lease)
    }
}
