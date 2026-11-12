@preconcurrency import AVFoundation
import CoreImage
import CryptoKit
import Metal
import Vision
import CoreML

/// Recomputable analysis only. Render instructions own decoded values, so an
/// old JSON file can be evicted without invalidating an active composition.
enum VideoEffectAnalysisFiles {
    private static let lock = NSLock()
    static func touched(_ file: URL) { try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path) }
    static func prune(in directory: URL, keeping file: URL, maximumBytes: Int64 = 64_000_000, maximumFiles: Int = 256) {
        lock.lock(); defer { lock.unlock() }
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? []
        let records = entries.compactMap { url -> (URL, Int64, Date)? in
            let name = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension == "json", let prefix = ["palette-", "subject-"].first(where: { name.hasPrefix($0) }) else { return nil }
            let hash = name.dropFirst(prefix.count)
            guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }),
                  let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var bytes = records.reduce(Int64(0)) { $0 + $1.1 }, count = records.count
        for (url, size, _) in records where url != file {
            if bytes <= maximumBytes && count <= maximumFiles { break }
            do { try FileManager.default.removeItem(at: url); bytes -= size; count -= 1 } catch { continue }
        }
    }
}

struct EffectPaletteFrame: Codable, Sendable {
    var time: Double
    var palette: EffectPalette
}
struct EffectPaletteTrack: Codable, Sendable {
    var frames: [EffectPaletteFrame]
    var valid:Bool { !frames.isEmpty && frames.count<=3_100_000 && frames.allSatisfy { $0.time.isFinite && (0...604800).contains($0.time) && $0.palette.valid } && zip(frames,frames.dropFirst()).allSatisfy { $0.time < $1.time } }
    func palette(at time: Double) -> EffectPalette? {
        guard !frames.isEmpty else { return nil }
        var a = 0, b = frames.count
        while a < b { let middle = (a + b) / 2; if frames[middle].time <= time { a = middle + 1 } else { b = middle } }
        return frames[max(0, a - 1)].palette
    }
}

// An immutable, source-time palette sequence. Seeking and export do not depend
// on which frames the player happened to request first. Only 64x36 pixels cross
// to CPU for the small clustering job; the full-resolution image stays on GPU.
actor VideoEffectAnalysis {
    static let shared = VideoEffectAnalysis()
    private let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .cacheIntermediates: false])
    private var gate=VideoEffectAnalysisGate()
    private var tracks: [String: EffectPaletteTrack] = [:]
    private var renderer:MetalEffectRenderer?
    private var inputs:VideoEffectInputs?
    private let matteProvider=VideoEffectSourceMatteProvider()
    private let nightPicture=NightFixPicture()
    private func renderPrefix(_ prefix:[VideoEffectSettings],image:CIImage,raw:CIImage,matrix:CGAffineTransform,time:Double,sampleTime:Double,instruction:VideoToolInstruction?,folder:URL,analysis:Bool,hdr:Bool,reader:VideoEffectSourceReader?,lease:((VideoEffectFrameLease)->Void)?=nil)throws->CIImage {
        if prefix.contains(where:{$0.usesTemporalMatte && $0.isActive(at:time)}) {
            guard let instruction,let frames=instruction.sourceFrames,let reader else {throw VideoEffectError.unavailableMatteHistory}
            return try matteProvider.render(effects:prefix,time:time,frames:frames,identity:instruction.matteIdentity(analysis:analysis),renderer:renderer!,hdr:hdr,recorded:instruction.effectMatteHistories,mapInputOnly:true,equivalentCurrentAllowed:instruction.stabilization==nil,prepare:{t,upstream,histories in
                let selected=frames.times[frames.last(at:t)],beforeFirst=frames.times[0]>t+0.0000001
                let sample=try reader.sample(at:beforeFirst ? t : selected,firstAtOrAfter:!beforeFirst)
                let (picture,transform)=instruction.preparedImage(try self.nightPicture.render(sample.image,instruction:instruction,time:t),at:t,analysis:analysis)
                let contexts=try self.inputs!.frameContexts(image:picture,effects:upstream,time:t,folder:folder,palettes:instruction.effectPalettes,subjects:instruction.effectSubjects,masks:instruction.effectMasks,maskSource:analysis ? instruction.maskSource?.forPalette : instruction.maskSource,rawSource:sample.image,depth:instruction.effectDepth,depthStream:"\(instruction.trackID)|\(instruction.clip.id)",maskTransform:transform,sourceSize:instruction.sourceSize,analysisTime:beforeFirst ? t : selected,hdr:hdr,plateColor:instruction.clip.color,plateColorHDR:instruction.hdr,temporalHistories:histories,disableMatteCuts:Set(instruction.effectMatteHistories.filter {$0.value.replay(at:selected)}.keys),currentMatteCuts:Set(instruction.effectMatteHistories.filter {$0.value.replay(at:selected) && !$0.value.accepted(at:selected)}.keys),provisional:instruction.effectAnalysisPending)
                return .init(image:picture,contexts:contexts)
            },lease:lease)
        }
        let contexts=try inputs!.frameContexts(image:image,effects:prefix,time:time,folder:folder,palettes:instruction?.effectPalettes ?? [:],subjects:instruction?.effectSubjects ?? [:],masks:instruction?.effectMasks,maskSource:analysis ? instruction?.maskSource?.forPalette : instruction?.maskSource,rawSource:raw,depth:instruction?.effectDepth,depthStream:instruction.map {"\($0.trackID)|\($0.clip.id)"} ?? "analysis",maskTransform:matrix,sourceSize:instruction?.sourceSize,analysisTime:sampleTime,hdr:hdr,plateColor:instruction?.clip.color,plateColorHDR:instruction?.hdr ?? false,provisional:instruction?.effectAnalysisPending ?? false)
        return try renderer!.render(image,effects:prefix.filter {$0.kind != .nightFix},sourceTime:time,hdr:hdr,mapInputOnly:true,contexts:contexts,lease:lease)
    }
    static func prefix(_ effects:[VideoEffectSettings],before id:UUID)->[VideoEffectSettings] {
        let ordered=VideoEffectSettings.ordered(effects)
        return Array(ordered.prefix(while:{$0.id != id})).filter {$0.kind != .quantization && $0.kind != .stepPrinting}.map { effect in
            var value=effect.recordingResult
            if value.kind == .undercranking,let index=value.parameters.firstIndex(where:{$0.id=="speed"}) {
                value.parameters[index].value = .number(1);value.parameters[index].keyframes=[]
            }
            return value
        }
    }
    // The quantizer sees the preceding key, geometry and colour stages. Keep the
    // analysis image small, but run their actual shader code in linear light.
    private func sampledFrame(source:SourceMedia,effect:VideoEffectSettings,folder:URL,instruction:VideoToolInstruction,time:Double,analysis:Bool) throws -> (image:CIImage,time:Double,leases:[VideoEffectFrameLease]) {
        if renderer==nil {let r=try MetalEffectRenderer();renderer=r;inputs=VideoEffectInputs(renderer:r)}
        let reader=try VideoEffectSourceReader(url:folder.appendingPathComponent(source.filename),hdr:instruction.sourceHDR,capacity:2)
        let plan=VideoEffectSamplePlan.make(clip:instruction.clip,sourceTime:time,sourceFPS:instruction.sourceFPS,clock:instruction.sequenceClock,frames:instruction.sourceFrames)
        let times=plan?.times ?? [time],smear=plan?.smear ?? 0
        let prefix=Self.prefix(instruction.clip.videoEffects ?? [],before:effect.id)
        var sum:CIImage?,weight=0.0,leases:[VideoEffectFrameLease]=[],sampleTime=time
        for (index,t) in times.enumerated() where index==0 || smear>0 {
            let sample=try reader.sample(at:t,firstAtOrAfter:plan?.firstAtOrAfter ?? false,before:plan?.before ?? .infinity)
            sampleTime=sample.time
            let (image,matrix)=instruction.preparedImage(try nightPicture.render(sample.image,instruction:instruction,time:sample.time),at:sample.time,analysis:analysis)
            let query=plan==nil && prefix.contains(where:{$0.usesTemporalMatte}) ? time : sample.time
            let picture=try renderPrefix(prefix,image:image,raw:sample.image,matrix:matrix,time:query,sampleTime:sample.time,instruction:instruction,folder:folder,analysis:analysis,hdr:instruction.sourceHDR,reader:reader,lease:{leases.append($0)})
            let contribution=index==0 ? 1-smear+smear/Double(times.count) : smear/Double(times.count)
            weight+=contribution
            if let old=sum {
                let blend=old.applyingFilter("CIDissolveTransition",parameters:[kCIInputTargetImageKey:picture,kCIInputTimeKey:contribution/weight])
                var retained:VideoEffectFrameLease?
                sum=try renderer!.materialize(blend,lease:{retained=$0})
                leases.removeAll();if let retained {leases.append(retained)}
            } else {sum=picture}
        }
        guard let sum else {throw ProjectError.invalidMedia}
        return (sum,sampleTime,leases)
    }
    func sample(source:SourceMedia,effect:VideoEffectSettings,folder:URL,instruction:VideoToolInstruction,time:Double,count:Int) throws -> EffectPalette {
        let frame=try sampledFrame(source:source,effect:effect,folder:folder,instruction:instruction,time:time,analysis:true)
        return withExtendedLifetime(frame.leases) {
            EffectPaletteAnalysis.analyze(Self.samples(frame.image,context:context),count:count,seed:UInt64(VideoEffectTime.frameIndex(frame.time,fps:30)))
        }
    }
    func color(source:SourceMedia,effect:VideoEffectSettings,folder:URL,instruction:VideoToolInstruction,time:Double,point:CGPoint) throws -> EffectRGB {
        let frame=try sampledFrame(source:source,effect:effect,folder:folder,instruction:instruction,time:time,analysis:false)
        return withExtendedLifetime(frame.leases) {Self.sampleColor(frame.image,point:point,context:context)}
    }
    static func sampleColor(_ image:CIImage,point:CGPoint,context:CIContext)->EffectRGB {
        let bounds=image.extent
        let x=bounds.minX+min(1,max(0,point.x))*(bounds.width-1),y=bounds.minY+(1-min(1,max(0,point.y)))*(bounds.height-1)
        let patch=CGRect(x:floor(x)-4,y:floor(y)-4,width:9,height:9).intersection(bounds).integral
        let width=Int(patch.width),height=Int(patch.height)
        guard width>0,height>0 else { return EffectRGB(0,0,0) }
        var pixels=[Float](repeating:0,count:width*height*4)
        context.render(image,toBitmap:&pixels,rowBytes:width*16,bounds:patch,format:.RGBAf,colorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!)
        let channels=(0..<3).map { c in stride(from:c,to:pixels.count,by:4).map { Double(pixels[$0]) }.sorted() }
        let median=SIMD3(channels[0][width*height/2],channels[1][width*height/2],channels[2][width*height/2])
        return EffectColorMath.rgb(median)
    }

    func palette(source: SourceMedia, effect: VideoEffectSettings, folder: URL, instruction:VideoToolInstruction? = nil, analysisRange: ClosedRange<Double>? = nil, generate:Bool=true, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> EffectPaletteTrack {
        struct Key: Encodable {
            let version:Int;let source:SourceMedia;let effect:VideoEffectSettings;let prefix:[VideoEffectSettings]
            let geometry:[Double];let color:ColorSettings?;let stabilization:[StabilizationSample]?;let depth:String?
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let start=min(source.duration,max(effect.start,analysisRange?.lowerBound ?? instruction?.clip.start ?? effect.start))
        let end=min(source.duration,min(effect.end,analysisRange?.upperBound ?? instruction?.clip.end ?? effect.end))
        var analysisEffect = VideoEffectSettings(.quantization, start:start,end:end)
        analysisEffect.id = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        analysisEffect.parameters = effect.parameters.filter { ["colors", "lockPalette"].contains($0.id) }
        let prefix=Self.prefix(instruction?.clip.videoEffects ?? [],before:effect.id)
        var geometry:[Double]=[]
        if let i=instruction {
            let m=i.transform
            geometry=[m.a,m.b,m.c,m.d,m.tx,m.ty,i.canvas.width,i.canvas.height,i.sourceSize.width,i.sourceSize.height,i.stabilization?.zoom ?? 1,i.clip.stabilizationStart,i.hdr ? 1 : 0]
        }
        let key = SHA256.hash(data: try encoder.encode(Key(version: prefix.contains(where: \.usesAutoMaskStream) ? 8 : 7, source: source, effect: analysisEffect,prefix:prefix,geometry:geometry,color:instruction?.clip.color,stabilization:instruction?.stabilization?.samples,depth:prefix.contains(where:{$0.enabled && $0.kind == .dollyZoom}) ? instruction?.effectDepth?.identity : nil))).map { String(format: "%02x", $0) }.joined()
        while true {
            try Task.checkCancellation()
            if generate && gate.mustWait(key,deferrable:VideoEffectPreparation.deferrable) {
                try await Task.sleep(for:.milliseconds(100));continue
            }
            if let cached = tracks[key] { return cached }
            let directory = ProjectCacheLocation.root(in:folder,preferred:"cache")
            let file = directory.appendingPathComponent("palette-\(key).json")
            if let data = try? Data(contentsOf: file), let track = try? JSONDecoder().decode(EffectPaletteTrack.self, from: data), track.valid {
                VideoEffectAnalysisFiles.touched(file)
                tracks[key] = track; return track
            }
            guard generate else {throw VideoEffectError.analysisPending}
            guard let ticket=gate.claim(key,deferrable:VideoEffectPreparation.deferrable) else {
                try await Task.sleep(for:.milliseconds(100));continue
            }
            defer {gate.release(ticket)}
            do {
                let asset = AVURLAsset(url: folder.appendingPathComponent(source.filename))
                guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw ProjectError.invalidMedia }
                let reader = try AVAssetReader(asset: asset)
                let descriptions=try await video.load(.formatDescriptions)
                let hdr=descriptions.contains { VideoColor.isHDR($0) }
                let output = AVAssetReaderTrackOutput(track: video, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: hdr ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
                if renderer==nil { let r=try MetalEffectRenderer();renderer=r;inputs=VideoEffectInputs(renderer:r) }
                let temporalReader=prefix.contains(where:{$0.usesTemporalMatte}) ? try VideoEffectSourceReader(url:folder.appendingPathComponent(source.filename),hdr:hdr) : nil
                output.alwaysCopiesSampleData = false; reader.add(output)
                guard end > start else { throw ProjectError.invalidDocument }
                reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 60000), end: CMTime(seconds: end, preferredTimescale: 60000))
                guard reader.startReading() else { throw reader.error ?? ProjectError.invalidMedia }
                defer { reader.cancelReading() }
                let keys=effect.parameters.filter { ["colors","lockPalette"].contains($0.id) }.flatMap { $0.keyframes.map(\.time) }
                let targets=Array(Set(Array(stride(from:start,to:end,by:0.2))+keys.filter {$0>=start && $0<end})).sorted()
                let analysisProgress = MediaProgress(progress)
                var frames: [EffectPaletteFrame] = [], previous: EffectPalette?, targetIndex=0,wasLocked=false
                while let sample = output.copyNextSampleBuffer() {
                    try ticket.check();try Task.checkCancellation()
                    // A reader includes the frame overlapping its start. Its PTS
                    // can precede start (especially a 24 fps freeze's 1/30 window).
                    // Analyse that visible frame instead of discarding it.
                    let time = max(start, CMSampleBufferGetPresentationTimeStamp(sample).seconds)
                    guard targetIndex<targets.count,time+0.00001>=targets[targetIndex],let pixel=CMSampleBufferGetImageBuffer(sample) else { continue }
                    while targetIndex<targets.count && time+0.00001>=targets[targetIndex] { targetIndex += 1 }
                    analysisProgress.report((time - start) / (end - start))
                    let locked=effect.toggle("lockPalette",at:time),count=Int(effect.number("colors",at:time))
                    defer { wasLocked=locked }
                    if locked && wasLocked,previous?.colors.count==count { continue }
                    let palette: EffectPalette = try autoreleasepool {
                        let raw=LogColor.image(pixel)
                        let restored=try instruction.map {try nightPicture.render(raw,instruction:$0,time:time)} ?? raw
                        let prepared=instruction?.preparedImage(restored,at:time,analysis:true)
                        let image=prepared?.0 ?? raw.transformed(by:CGAffineTransform(scaleX:256/raw.extent.width,y:256/raw.extent.width))
                        let processed=try renderPrefix(prefix,image:image,raw:raw,matrix:prepared?.1 ?? .identity,time:time,sampleTime:time,instruction:instruction,folder:folder,analysis:true,hdr:hdr,reader:temporalReader)
                        let samples = Self.samples(processed, context: context)
                        return EffectPaletteAnalysis.analyze(samples, count: Int(effect.number("colors", at: time)), previous: previous,
                            elapsed: frames.last.map { time - $0.time } ?? 0.2, seed: UInt64(VideoEffectTime.frameIndex(time, fps: 30)))
                    }
                    frames.append(EffectPaletteFrame(time: time, palette: palette)); previous = palette
                    try await VideoEffectPreparation.checkpoint(ticket);await Task.yield()
                }
                if reader.status == .failed { throw reader.error ?? ProjectError.invalidMedia }
                let track = EffectPaletteTrack(frames: frames)
                guard !frames.isEmpty else { throw ProjectError.invalidMedia }
                try ticket.check()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try encoder.encode(track).write(to: file, options: .atomic)
                VideoEffectAnalysisFiles.prune(in: directory, keeping: file)
                tracks[key] = track
                // Plans live in the instructions; don't retain a whole library in RAM.
                if tracks.count > 12 { tracks.removeAll(keepingCapacity: true) }
                return track
            } catch is VideoEffectAnalysisGate.Superseded {continue}
        }
    }
    static func samples(_ image: CIImage, context: CIContext) -> [SIMD3<Double>] {
        let w = image.extent.width >= image.extent.height ? 64 : 36, h = w == 64 ? 36 : 64
        let scaled = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: Double(w) / image.extent.width, y: Double(h) / image.extent.height))
        var floats = [Float](repeating: 0, count: w*h*4)
        context.render(scaled, toBitmap: &floats, rowBytes: w*16, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBAf,
            colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        return stride(from: 0, to: floats.count, by: 4).map { SIMD3(Double(floats[$0]), Double(floats[$0+1]), Double(floats[$0+2])) }
    }
}

// Reuse Vision's stateful request for a live stream. Imported/export frames
// create a fresh provider so random-access rendering is independent of seeks.
final class VideoEffectPersonProvider {
    private let request=VNGeneratePersonSegmentationRequest()
    private let context=CIContext(options:[.cacheIntermediates:false])
    private var pool:CVPixelBufferPool?
    private var size=CGSize.zero
    init(live:Bool) {
        request.qualityLevel=live ? .balanced : .accurate
        request.outputPixelFormat=kCVPixelFormatType_OneComponent8
        Self.configureCompute(request)
    }
    private static func configureCompute(_ request:VNGeneratePersonSegmentationRequest) {
        if #available(iOS 17,macOS 14,*) {
            if let stages=try? request.supportedComputeStageDevices {
                for (stage,devices) in stages {
                    if let neural=devices.first(where: { if case .neuralEngine = $0 { return true };return false }) {
                        request.setComputeDevice(neural,for:stage)
                    }
                }
            }
        }
    }
    func mask(_ image:CIImage,stateless:Bool=false,orientation:CGAffineTransform = .identity) throws -> CVPixelBuffer {
        let accurate=request.qualityLevel == .accurate
        let maximumInput:Double=accurate ? 1536 : 512
        let maximumMask:Double=accurate ? 1024 : 512
        let oriented=image.transformed(by:orientation)
        let placement=orientation.concatenating(CGAffineTransform(translationX:-oriented.extent.minX,y:-oriented.extent.minY))
        let upright=image.transformed(by:placement)
        let scale=min(1,maximumInput/max(upright.extent.width,upright.extent.height))
        let reduced=upright.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
        // Copy the configured template, not the results of a previous frame.
        // Querying supported compute devices anew for every movie frame is expensive.
        let request = stateless ? self.request.copy() as? VNGeneratePersonSegmentationRequest : self.request
        guard let request else { throw VideoEffectError.unavailableMask }
        try VNImageRequestHandler(ciImage:reduced,options:[:]).perform([request])
        guard let pixel=request.results?.first?.pixelBuffer else { throw VideoEffectError.unavailableMask }
        // Accurate segmentation sees more source detail than live preview. Keep a
        // 1024-pixel mask for hair and hands; cap storage and keep it on the GPU.
        let w=CVPixelBufferGetWidth(pixel),h=CVPixelBufferGetHeight(pixel)
        guard Double(max(w,h))>maximumMask || !placement.isIdentity else {return pixel}
        // Vision must see the upright person. Return alpha in raw source
        // coordinates so crop/mirror/orientation are applied exactly once later.
        let maskImage=CIImage(cvPixelBuffer:pixel,options:[.colorSpace:NSNull()])
        let restored:CIImage
        if placement.isIdentity {restored=maskImage}
        else {restored=maskImage.transformed(by:CGAffineTransform(scaleX:upright.extent.width/Double(w),y:upright.extent.height/Double(h)))
            .transformed(by:placement.inverted()).cropped(to:image.extent)
            .transformed(by:CGAffineTransform(translationX:-image.extent.minX,y:-image.extent.minY))}
        let factor=min(1,maximumMask/max(restored.extent.width,restored.extent.height))
        let width=max(1,Int(restored.extent.width*factor)),height=max(1,Int(restored.extent.height*factor))
        if size != CGSize(width:width,height:height) {
            let attributes:[String:Any]=[kCVPixelBufferWidthKey as String:width,kCVPixelBufferHeightKey as String:height,
                kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_OneComponent8,kCVPixelBufferMetalCompatibilityKey as String:true,
                kCVPixelBufferIOSurfacePropertiesKey as String:[:]]
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault,nil,attributes as CFDictionary,&pool)==kCVReturnSuccess else {throw VideoEffectError.buffer}
            size=CGSize(width:width,height:height)
        }
        var result:CVPixelBuffer?
        guard let pool,CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault,pool,&result)==kCVReturnSuccess,let result else {throw VideoEffectError.buffer}
        let small=restored.transformed(by:CGAffineTransform(scaleX:Double(width)/restored.extent.width,y:Double(height)/restored.extent.height),highQualityDownsample:true)
        context.render(small,to:result,bounds:CGRect(origin:.zero,size:size),colorSpace:nil)
        return result
    }
}

// Queue-confined input preparation shared by compositor and live worker.
// Vision's public API supplies the mask; no third-party model weights are used.
final class VideoEffectInputs {
    let renderer: MetalEffectRenderer
    private var textureCache: CVMetalTextureCache?
    private var heldMaskTextures:[CVMetalTexture]=[]
    private var depthReaders:[String:VideoEffectDepthReader]=[:]
    private var depthReaderOrder:[String]=[]
    private var placedDepth:MTLTexture?
    private var failedDepth:Set<String>=[]
    private var placedMasks:[MTLTexture]=[]
    private var placedMaskCount=0
    private var images: [String: CIImage] = [:]
    private var movies: [String: EffectBackgroundMovie] = [:]
    private var captured: [String: EffectAnalysisReader] = [:]
    private var maskStreams: [String: SourcePersonMaskReader] = [:]
    private var maskStreamOrder: [String] = []
    private func maskReader(for source: SourcePersonMasks, stream: String) throws -> SourcePersonMaskReader {
        let key = source.identity + "|" + stream
        if let reader = maskStreams[key] {
            maskStreamOrder.removeAll { $0 == key }
            maskStreamOrder.append(key)
            return reader
        }
        let reader = try SourcePersonMaskReader(source, renderer: renderer)
        if maskStreamOrder.count == 3 { maskStreams.removeValue(forKey: maskStreamOrder.removeFirst()) }
        maskStreamOrder.append(key)
        maskStreams[key] = reader
        return reader
    }
    private var staticBackgrounds: [UUID: (VideoEffectSettings,CGSize,String?,MTLTexture)] = [:]
    private var cleanPlates: [String: MTLTexture] = [:]
    private(set) var lastPersonPixel: CVPixelBuffer?
    private(set) var lastAutoBackgroundPixel:CVPixelBuffer?
    static let pop: [EffectPalettePreset] = {
        let url = Bundle.main.url(forResource: "PopPalettes", withExtension: "json") ?? URL(fileURLWithPath: "YouRec/VideoEffects/PopPalettes.json")
        return (try? JSONDecoder().decode([EffectPalettePreset].self, from: Data(contentsOf: url))) ?? []
    }()
    init(renderer: MetalEffectRenderer) {
        self.renderer = renderer
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, renderer.device, nil, &textureCache)
    }
    static func needsPerson(_ effects:[VideoEffectSettings],at time:Double)->Bool {
        effects.contains { effect in
            guard effect.enabled, time>=effect.start,time<effect.end else { return false }
            return effect.kind == .autoBackground || effect.kind == .dollyZoom || effect.kind == .colorIsolation && effect.choice("mode",at:time)=="The subject"
                || effect.kind == .quantization && effect.toggle("faceDetail",at:time) && effect.number("colors",at:time)<=4
                || effect.kind == .chromaKey && effect.toggle("personHint",at:time)
        }
    }
    static func segmentedPixel(_ image:CIImage,live:Bool) throws -> CVPixelBuffer {
        try VideoEffectPersonProvider(live:live).mask(image)
    }
    private func person(_ image:CIImage,live:Bool,supplied:CVPixelBuffer?,publish:Bool=true) throws -> MTLTexture {
        let pixel=try supplied ?? Self.segmentedPixel(image,live:live)
        guard let cache=textureCache else { throw VideoEffectError.unavailableMask }
        if publish {lastPersonPixel=pixel}
        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixel, nil, .r8Unorm,
            CVPixelBufferGetWidth(pixel), CVPixelBufferGetHeight(pixel), 0, &texture)
        guard status == kCVReturnSuccess, let texture, let result = CVMetalTextureGetTexture(texture) else { throw VideoEffectError.unavailableMask }
        heldMaskTextures.append(texture)
        return result
    }
    func frameContexts(image: CIImage, effects: [VideoEffectSettings], time: Double, folder: URL?, palettes: [UUID: EffectPaletteTrack] = [:],subjects:[UUID:EffectSubjectTrack]=[:], live: Bool = false, masks:EffectMaskFiles?=nil,maskSource:SourcePersonMasks?=nil,rawSource:CIImage?=nil,cancelled:()->Bool={Task.isCancelled},depth:VideoEffectDepthSource?=nil,depthStream:String="", maskTransform: CGAffineTransform = .identity, sourceSize: CGSize? = nil, personPixel: CVPixelBuffer? = nil,autoBackgroundPixel:CVPixelBuffer?=nil,analysisTime:Double? = nil,hdr:Bool=false,plateColor:ColorSettings?=nil,plateColorHDR:Bool=false,temporalHistories:[UUID:[VideoEffectMatteCache.Frame]]=[:],disableMatteCuts:Set<UUID>=[],currentMatteCuts:Set<UUID>=[],provisional:Bool=false) throws -> [UUID: FrameContext] {
        let analysisTime=analysisTime ?? time
        let active = effects.filter { $0.enabled && time >= $0.start && time < $0.end }
        let maskEffects=active.filter {$0.kind != .dollyZoom || depth==nil}
        let needsPerson=Self.needsPerson(maskEffects,at:time)
        lastPersonPixel = nil;lastAutoBackgroundPixel=nil;heldMaskTextures.removeAll();placedMaskCount=0
        if let textureCache {CVMetalTextureCacheFlush(textureCache,0)}
        var saved: EffectAnalysisReader?
        if let folder, let effect = active.first(where: { $0.analysisFile != nil }), let filename = effect.analysisFile {
            let path = folder.appendingPathComponent(filename).path
            if captured[path] == nil { if captured.count>=8 { captured.removeAll() };captured[path] = try EffectAnalysisReader(metadata: URL(fileURLWithPath: path), data: effect.analysisDataFile.map { folder.appendingPathComponent($0) }) }
            saved = captured[path]
        }
        var generated:EffectAnalysisReader?
        if needsPerson,let files=masks,let masks=files.at(analysisTime) {
            if captured[masks.metadata.path]==nil {
                if captured.count>=8 {captured.removeAll()}
                captured[masks.metadata.path]=try EffectAnalysisReader(metadata:masks.metadata,data:masks.data)
            }
            generated=captured[masks.metadata.path]
        }
        func placed(_ stored:CIImage) throws -> MTLTexture {
            let size=sourceSize ?? image.extent.size
            let placed=stored.transformed(by:CGAffineTransform(scaleX:size.width/stored.extent.width,y:size.height/stored.extent.height))
                .transformed(by:maskTransform).cropped(to:image.extent)
                .composited(over:CIImage(color:.black).cropped(to:image.extent))
            let w=Int(image.extent.width),h=Int(image.extent.height),index=placedMaskCount
            placedMaskCount+=1
            if placedMasks.first?.width != w || placedMasks.first?.height != h {placedMasks.removeAll()}
            if index>=placedMasks.count {placedMasks.append(try renderer.texture(width:w,height:h,format:.r16Float))}
            let texture=placedMasks[index]
            renderer.context.render(MetalEffectRenderer.textureImage(placed),to:texture,commandBuffer:nil,bounds:image.extent,colorSpace:renderer.space)
            return texture
        }
        let modern=maskEffects.filter {$0.usesModernPersonMask},legacy=maskEffects.filter {$0.algorithm==nil}
        let hasRawModern=modern.contains {($0.kind != .autoBackground || live) && Self.needsPerson([$0],at:time)}
        let hasRawLegacy=Self.needsPerson(legacy,at:time)
        let needsSavedRaw = hasRawLegacy || hasRawModern || (maskSource == nil && saved?.hasMotionAwareAutoBackground != true)
        let storedRaw = needsPerson && needsSavedRaw ? try saved?.mask(at: analysisTime) : nil
        let streamed: SourcePersonMaskReader.Frame?
        if let maskSource, needsPerson, !modern.isEmpty, saved?.hasMotionAwareAutoBackground != true {
            streamed = try maskReader(for: maskSource, stream: depthStream).frame(at: analysisTime, currentImage: rawSource, cancelled: cancelled)
        } else { streamed = nil }
        var legacyMask:MTLTexture?,modernMask:MTLTexture?
        if let storedRaw {
            if hasRawLegacy || hasRawModern {modernMask=try placed(storedRaw);legacyMask=modernMask}
        } else {
            if hasRawLegacy {legacyMask=try person(image,live:live || provisional,supplied:personPixel)}
            if hasRawModern {
                if let stored = try streamed?.raw ?? generated?.mask(at:analysisTime) {modernMask=try placed(stored)}
                else {modernMask=try legacyMask ?? person(image,live:live || provisional,supplied:personPixel)}
            }
        }
        var autoMask=modernMask
        if modern.contains(where:{$0.kind == .autoBackground}) {
            // Older recorded EMA masks trail a moving silhouette. Rebuild this
            // derived stream from its saved raw masks; never overwrite a take.
            let capturedAuto=try saved?.hasMotionAwareAutoBackground == true ? saved?.mask(at:analysisTime,autoBackground:true) : nil
            if let stored=try capturedAuto ?? streamed?.background ?? generated?.mask(at:analysisTime,autoBackground:true) {
                autoMask=try placed(stored)
            } else if let storedRaw,!live {
                autoMask=try placed(storedRaw)
            } else if live,let smooth=autoBackgroundPixel ?? lastPersonPixel {
                autoMask=try person(image,live:true,supplied:smooth,publish:false);lastAutoBackgroundPixel=smooth
            } else {autoMask=try person(image,live:live || provisional,supplied:personPixel)}
        }
        var depthTexture:MTLTexture?,focus:Float?
        if !live,let depth,active.contains(where:{$0.kind == .dollyZoom || $0.kind == .widescreen && $0.toggle("ovalBokeh",at:time)}),!failedDepth.contains(depth.identity) {
            do {
                let key=depth.identity+"|"+depthStream
                depthReaderOrder.removeAll {$0==key};depthReaderOrder.append(key)
                while depthReaderOrder.count>4 {depthReaders.removeValue(forKey:depthReaderOrder.removeFirst())}
                if depthReaders[key]==nil {depthReaders[key]=VideoEffectDepthReader(source:depth)}
                let sample:(pixel:CVPixelBuffer,focus:Float?)?
                do {sample=try depthReaders[key]!.sample(at:analysisTime)} catch {
                    // One clean reset can recover a transient decoder failure.
                    let replacement=VideoEffectDepthReader(source:depth);depthReaders[key]=replacement
                    sample=try replacement.sample(at:analysisTime)
                }
                if let sample,let cache=textureCache {
                    let pixel=sample.pixel
                    var wrapper:CVMetalTexture?
                    guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,cache,pixel,nil,.r16Float,CVPixelBufferGetWidth(pixel),CVPixelBufferGetHeight(pixel),0,&wrapper)==kCVReturnSuccess,
                          let wrapper,let texture=CVMetalTextureGetTexture(wrapper) else {throw VideoEffectError.buffer}
                    heldMaskTextures.append(wrapper)
                    depthTexture=try renderer.placeDepth(texture,source:sourceSize ?? depth.videoSize,canvas:image.extent.size,transform:maskTransform,range:depth.lower...depth.upper,reusing:placedDepth)
                    placedDepth=depthTexture
                    focus=sample.focus
                }
            } catch {
                NSLog("YouRec: optional imported depth failed: %@",error.localizedDescription)
                failedDepth.insert(depth.identity)
                for key in depthReaderOrder where key.hasPrefix(depth.identity+"|") {depthReaders.removeValue(forKey:key)}
                depthReaderOrder.removeAll {$0.hasPrefix(depth.identity+"|")}
            }
        }
        // Decoder failure must not turn an optional depth layer into a failed
        // export. A Dolly Zoom still has the established person-mask fallback.
        if depthTexture==nil,active.contains(where:{$0.kind == .dollyZoom}),modernMask==nil {modernMask=try person(image,live:live || provisional,supplied:personPixel);if legacyMask==nil {legacyMask=modernMask}}
        var result: [UUID: FrameContext] = [:]
        for effect in active {
            var frame = FrameContext(presentationTime: time, frameIndex: VideoEffectTime.frameIndex(time, fps: 30), personMask: effect.algorithm==nil ? legacyMask : effect.kind == .autoBackground ? autoMask : modernMask)
            frame.depthMap=depthTexture;frame.depthFocus=focus
            frame.matteHistory=temporalHistories[effect.id]
            frame.matteDetectCuts = !disableMatteCuts.contains(effect.id)
            frame.matteDetectCurrentCut = currentMatteCuts.contains(effect.id)
            frame.quality=saved?.analysis.qualities?[effect.analysisID]?.quality(at:analysisTime) ?? .full
            if effect.kind == .dollyZoom || effect.kind == .crashZoom && effect.toggle("trackFace",at:time) {
                var subject=subjects[effect.id]?.sample(at:analysisTime) ?? (effect.analysisFile != nil ? saved?.analysis.subjects?.sample(at:analysisTime) : nil)
                if subject==nil && subjects[effect.id]==nil && effect.analysisFile==nil && !live {
                    subject=try EffectSubjectTracker(point:CGPoint(x:effect.number("targetX",at:time),y:effect.number("targetY",at:time)),live:true).update(image,time:time)
                    frame.target=subject?.center
                } else if let subject {
                    let size=sourceSize ?? image.extent.size
                    let point=CGPoint(x:subject.center.x*size.width,y:(1-subject.center.y)*size.height).applying(maskTransform)
                    frame.target=CGPoint(x:min(1,max(0,point.x/image.extent.width)),y:min(1,max(0,1-point.y/image.extent.height)))
                }
            }

            if effect.kind == .quantization {
                let track = palettes[effect.id] ?? saved?.analysis.palettes[effect.analysisID]
                frame.palette = Self.displayPalette(for: effect, at: time, analyzed: track?.palette(at: analysisTime))
            }
            if effect.kind == .autoBackground || effect.kind == .chromaKey {
                frame.background = try background(effect, image: image, time: time, folder: folder)
                if case .media(let file) = effect.value("cleanPlate", at: time), let file, let folder {
                    let url=folder.appendingPathComponent(file),size=sourceSize ?? image.extent.size
                    let geometry=[maskTransform.a,maskTransform.b,maskTransform.c,maskTransform.d,maskTransform.tx,maskTransform.ty,size.width,size.height,image.extent.width,image.extent.height].map {String(Double($0))}.joined(separator:",")
                    let colorKey="\(plateColor?.look.rawValue ?? "natural")-\(plateColor?.amount ?? 0)-\(plateColorHDR)-\(hdr)"
                    let key=url.path+geometry+colorKey
                    let original=try loadImage(url)
                    if VideoEffectCleanPlate.compatible(original.extent.size,with:size) {
                    if cleanPlates[key] == nil {
                        if cleanPlates.count>4 { cleanPlates.removeAll() }
                        var plate=original.transformed(by:CGAffineTransform(scaleX:size.width/original.extent.width,y:size.height/original.extent.height))
                        if let plateColor { plate=ColorLUT.apply(plateColor,to:plate,hdr:plateColorHDR,folder:folder) }
                        plate=plate.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:8*min(size.width,size.height)/1080])
                            .cropped(to:CGRect(origin:.zero,size:size)).transformed(by:maskTransform).cropped(to:image.extent)
                            .composited(over:CIImage(color:.black).cropped(to:image.extent))
                        let mapped=try renderer.render(plate,effects:[],sourceTime:time,hdr:hdr,mapInputOnly:true)
                        cleanPlates[key]=try texture(mapped,size:image.extent.size)
                    }
                    frame.cleanPlate=cleanPlates[key]
                    }
                }
            }
            result[effect.id] = frame
        }
        // Interactive editing avoids a synchronous scan of the recording for
        // every slider movement. It samples this frame after the prefix shaders;
        // playback/export outside the workspace use the deterministic track.
        if !live {
            for effect in active where effect.kind == .quantization && result[effect.id]?.palette == nil {
                let scale=min(1,256/max(image.extent.width,image.extent.height)),reduced=image.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
                let prefix=VideoEffectAnalysis.prefix(effects,before:effect.id)
                var analysisContexts=result
                for id in analysisContexts.keys {analysisContexts[id]?.resampleMatteHistory=true}
                let prepared=try renderer.render(reduced,effects:prefix,sourceTime:time,hdr:hdr,mapInputOnly:true,contexts:analysisContexts)
                let count=Int(effect.number("colors",at:time))
                let palette=EffectPaletteAnalysis.analyze(VideoEffectAnalysis.samples(prepared,context:renderer.context),count:count,seed:UInt64(VideoEffectTime.frameIndex(analysisTime,fps:30)))
                result[effect.id]?.palette=Self.displayPalette(for: effect, at: time, analyzed: palette)
            }
        }
        return result
    }
    static func displayPalette(for effect: VideoEffectSettings, at time: Double, analyzed: EffectPalette?) -> EffectPalette? {
        let count = Int(effect.number("colors", at: time))
        var palette = analyzed?.colors.count == count ? analyzed : nil
        if effect.toggle("lockPalette", at: time), let locked = effect.lockedPalette, locked.colors.count == count {
            palette = locked
        }
        guard !effect.toggle("monochrome", at: time) else { return palette }
        let choice = effect.choice("palette", at: time)
        if choice == "Saved", let colors = effect.palette, colors.count >= 2 {
            let colors = sample(colors, count: count)
            // Nearest-color matching needs no scene analysis. Supply valid bands
            // for the recorded sidecar even before the first live histogram arrives.
            let luminances = colors.map { EffectColorMath.luminance(EffectColorMath.linear($0)) }.sorted()
            let thresholds = palette?.thresholds ?? zip(luminances, luminances.dropFirst()).map { ($0 + $1) / 2 }
            return EffectPalette(colors: colors, thresholds: thresholds)
        }
        if let preset = pop.first(where: { $0.name == choice }) { palette?.colors = preset.sampled(count) }
        return palette
    }
    static func sample(_ colors: [EffectRGB], count: Int) -> [EffectRGB] {
        guard colors.count > 1, count > 1, count != colors.count else { return colors }
        let entries = colors.map { (color: $0, lab: EffectColorMath.lab(EffectColorMath.linear($0))) }.sorted { $0.lab.x < $1.lab.x }
        if entries.count < count {
            return (0..<count).map { entries[Int((Double($0)*Double(entries.count-1)/Double(count-1)).rounded())].color }
        }
        // Preserve distinct hues when reducing a saved palette. Brightness ranks
        // alone can discard its only saturated entry between several neutrals.
        var chosen = [0]
        var distance = entries.map { simd_distance_squared($0.lab, entries[0].lab) }
        distance[0] = -1
        while chosen.count < count {
            guard let next = distance.indices.max(by: { distance[$0] < distance[$1] }) else { break }
            chosen.append(next)
            distance[next] = -1
            for i in entries.indices {
                distance[i] = min(distance[i], simd_distance_squared(entries[i].lab, entries[next].lab))
            }
        }
        return chosen.sorted().map { entries[$0].color }
    }
    func texture(_ image: CIImage, size: CGSize,waitForCompletion:Bool=false) throws -> MTLTexture {
        let texture = try renderer.texture(width: Int(size.width), height: Int(size.height))
        let command=waitForCompletion ? renderer.queue.makeCommandBuffer() : nil
        if waitForCompletion && command==nil {throw VideoEffectError.buffer}
        renderer.context.render(MetalEffectRenderer.textureImage(image), to: texture, commandBuffer: command, bounds: CGRect(origin: .zero, size: size), colorSpace: renderer.space)
        if let command {command.commit();command.waitUntilCompleted();if let error=command.error {throw error}}
        return texture
    }
    private func loadImage(_ url: URL) throws -> CIImage {
        if let image = images[url.path] { return image }
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { throw ProjectError.missingMedia }
        if images.count > 8 { images.removeAll() }
        images[url.path] = image; return image
    }
    private func background(_ effect: VideoEffectSettings, image: CIImage, time: Double, folder: URL?) throws -> MTLTexture {
        let bounds = image.extent, mode = effect.choice("background", at: time),scale=min(image.extent.width,image.extent.height)/1080
        let canCache=mode != "Video" && mode != "Blur original" && effect.parameters.allSatisfy { $0.keyframes.isEmpty }
        if canCache,let cached=staticBackgrounds[effect.id],cached.0==effect,cached.1==bounds.size,cached.2==folder?.path { return cached.3 }
        var background: CIImage
        if mode == "Image" || mode == "Video", case .media(let name) = effect.value("media", at: time), let name, let folder {
            let file = folder.appendingPathComponent(name)
            if mode == "Image" { background = try loadImage(file) }
            else {
                if movies[file.path] == nil { if movies.count>=4 { movies.removeAll() };movies[file.path] = try EffectBackgroundMovie(url: file) }
                background = try movies[file.path]!.image(at: max(0, time - effect.start))
            }
            let original = background.extent, fill = effect.choice("fit", at: time) != "Fit"
            let scale = (fill ? max(bounds.width/original.width,bounds.height/original.height) : min(bounds.width/original.width,bounds.height/original.height)) * effect.number("backgroundZoom", at: time)
            background = background.transformed(by: CGAffineTransform(translationX: -original.minX, y: -original.minY))
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(translationX: (bounds.width-original.width*scale)*effect.number("backgroundX", at: time),
                    y: (bounds.height-original.height*scale)*(1-effect.number("backgroundY", at: time))))
        } else if mode == "Blur original" {
            background = image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: effect.kind == .autoBackground ? effect.number("portraitBlur", at: time)*scale : 20*scale])
        } else if mode == "Studio" || mode == "Window" {
            // Authored procedural scenes: no licensed stock photographs.
            background = CIImage(color: CIColor(red: 0.12, green: 0.15, blue: 0.20)).cropped(to: bounds)
            let light = CIFilter(name: "CIRadialGradient", parameters: ["inputCenter": CIVector(x: bounds.width*0.3, y: bounds.height*0.7), "inputRadius0": 0,
                "inputRadius1": bounds.width*0.8, "inputColor0": CIColor(red: 0.65, green: 0.58, blue: 0.48), "inputColor1": CIColor(red: 0.08, green: 0.10, blue: 0.14)])!.outputImage!
            background = light.cropped(to: bounds)
            if mode == "Window" {
                for x in [0.64, 0.80] { let bar = CGRect(x: bounds.width*x, y: bounds.height*0.18, width: bounds.width*0.1, height: bounds.height*0.65)
                    background = CIImage(color: CIColor(red: 0.62, green: 0.73, blue: 0.83)).cropped(to: bar).composited(over: background) }
            }
        } else {
            let color = effect.color("backgroundColor", at: time)
            background = CIImage(color: CIColor(red: color.red, green: color.green, blue: color.blue)).cropped(to: bounds)
        }
        background = background.composited(over: CIImage(color: .black).cropped(to: bounds)).cropped(to: bounds)
        let blur = effect.number("backgroundBlur", at: time)
        if blur > 0 { background = background.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blur*scale]).cropped(to: bounds) }
        background = background.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: effect.number("backgroundBrightness", at: time)])
        // A constant color remains constant after blur/exposure; clamp sampling
        // gives identical pixels without a full-resolution background read.
        let solid = mode == "Solid"
        let result=try texture(background,size:solid ? CGSize(width:1,height:1) : bounds.size)
        if canCache {
            if staticBackgrounds.count>8 { staticBackgrounds.removeAll() }
            staticBackgrounds[effect.id]=(effect,bounds.size,folder?.path,result)
        }
        return result
    }
}

// Two sequential decoders overlap the moving tail and head. Each retains two
// frames; live callers run off the camera queue and retain the latest output.
final class EffectBackgroundMovie {
    private let head:VideoEffectSourceReader
    private let tail:VideoEffectSourceReader
    private let transform:CGAffineTransform
    private let loop:EffectBackgroundLoop
    init(url:URL) throws {
        let asset=AVURLAsset(url:url)
        guard let track=asset.tracks(withMediaType:.video).first,asset.duration.seconds.isFinite,asset.duration.seconds>0.001 else { throw ProjectError.invalidMedia }
        transform=track.preferredTransform;loop=EffectBackgroundLoop(duration:asset.duration.seconds)
        let hdr=track.formatDescriptions.contains { VideoColor.isHDR($0 as! CMFormatDescription) }
        head=try VideoEffectSourceReader(url:url,hdr:hdr,capacity:2);tail=try VideoEffectSourceReader(url:url,hdr:hdr,capacity:2)
    }
    func image(at time:Double) throws -> CIImage {
        let phase=loop.phase(at:time)
        var image=try head.frame(at:phase.incoming)
        if let outgoing=phase.outgoing {
            image=try tail.frame(at:outgoing).applyingFilter("CIDissolveTransition",parameters:["inputTargetImage":image,"inputTime":phase.blend]).cropped(to:image.extent)
        }
        image=image.transformed(by:transform)
        return image.transformed(by:CGAffineTransform(translationX:-image.extent.minX,y:-image.extent.minY))
    }
}

// Queue-confined sampler for the live worker's background analysis queue. It
// shares shader implementations, never the live renderer's mutable scratch pool.
final class LiveEffectPaletteSampler {
    private(set) var lastError:String?
    private let renderer:MetalEffectRenderer
    private let inputs:VideoEffectInputs
    init() throws { renderer=try MetalEffectRenderer();inputs=VideoEffectInputs(renderer:renderer) }
    func analyze(_ raw:CIImage,effects:[VideoEffectSettings],targets:[VideoEffectSettings],time:Double,hdr:Bool,
                 folder:URL?,person:CVPixelBuffer?,autoPerson:CVPixelBuffer?=nil,qualities:[UUID:VideoEffectQuality],previous:[UUID:EffectPalette],elapsed:Double,subject:EffectSubjectSample?=nil,temporalHistories:[UUID:[VideoEffectMatteCache.Frame]]=[:])->[UUID:EffectPalette] {
        let scale=min(1,256/max(raw.extent.width,raw.extent.height))
        let image=raw.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
        lastError=nil
        var result:[UUID:EffectPalette]=[:]
        for effect in targets {
            let count=Int(effect.number("colors",at:time))
            if effect.toggle("lockPalette",at:time),let old=previous[effect.id],old.colors.count==count { result[effect.id]=old;continue }
            let prefix=VideoEffectAnalysis.prefix(effects,before:effect.id)
            do {
                var contexts=try inputs.frameContexts(image:image,effects:prefix,time:time,folder:folder,live:true,personPixel:person,autoBackgroundPixel:autoPerson,hdr:hdr,temporalHistories:temporalHistories)
                for id in contexts.keys { contexts[id]?.quality=qualities[id] ?? .full;contexts[id]?.resampleMatteHistory=true }
                for camera in prefix where camera.kind == .crashZoom && camera.toggle("trackFace",at:time) { contexts[camera.id]?.target=subject?.center }
                let prepared=try renderer.render(image,effects:prefix,sourceTime:time,hdr:hdr,mapInputOnly:true,contexts:contexts)
                result[effect.id]=EffectPaletteAnalysis.analyze(VideoEffectAnalysis.samples(prepared,context:renderer.context),count:count,
                    previous:previous[effect.id],elapsed:elapsed,seed:UInt64(VideoEffectTime.frameIndex(time,fps:30)))
            } catch {lastError=error.localizedDescription; if let old=previous[effect.id] { result[effect.id]=old } }
        }
        return result
    }
}


enum VideoEffectBackgroundMedia {
    static func size(at url:URL) async throws -> CGSize {
        if ["mov","mp4","m4v"].contains(url.pathExtension.lowercased()) {
            guard let track=try await AVURLAsset(url:url).loadTracks(withMediaType:.video).first else {throw ProjectError.invalidMedia}
            let size=try await track.load(.naturalSize),transform=try await track.load(.preferredTransform)
            let bounds=CGRect(origin:.zero,size:size).applying(transform)
            return CGSize(width:abs(bounds.width),height:abs(bounds.height))
        }
        guard let size=VideoEffectCleanPlate.size(at:url) else {throw ProjectError.missingImage}
        return size
    }
}
