@preconcurrency import AVFoundation
@preconcurrency import Metal
import CoreImage
import Vision
import VideoToolbox
import CryptoKit

// Night fix restores source pixels before crop, masks, grading and compositing.
// Optional, parameter-independent motion-aligned fusion is cached in fixed
// source-frame chunks. Strength, brightness, mix and their keyframes stay cheap.
// No source, edit timing or audio is replaced. No neural model is used: Vision
// revision 1 is explicitly selected for classical optical flow.
extension VideoEffectSettings {
    var needsNightFixFusion:Bool {kind == .nightFix && enabled && nightFixMode != .fast}
}
enum NightFixError: LocalizedError {
    case processing, space, incomplete
    var errorDescription:String? { switch self {
    case .processing:return "Night fix could not prepare these frames. Try again."
    case .space:return "Night fix needs more free storage. Free some space and try again."
    case .incomplete:return "Night fix is still preparing this part of the video."
    } }
}
struct NightFixChunk:Codable,Sendable {
    let version:Int
    let file:String
    let first:Int
    let times:[Double]
    let duration:Double
    let bytes:Int
}
final class NightFixLease:@unchecked Sendable {
    let files:[URL]
    init(_ files:[URL]) { self.files=files;NightFixPins.change(files,by:1) }
    deinit {NightFixPins.change(files,by:-1)}
}
private enum NightFixPins {
    static let lock=NSLock()
    static var values:[URL:Int]=[:]
    static func change(_ files:[URL],by delta:Int) {lock.lock();defer {lock.unlock()};for file in files {let n=(values[file] ?? 0)+delta;if n>0 {values[file]=n}else {values[file]=nil}}}
    static func contains(_ file:URL)->Bool {lock.lock();defer {lock.unlock()};return values[file] != nil}
}
struct NightFixPlan:@unchecked Sendable {
    let root:URL
    let chunks:[NightFixChunk]
    let index:VideoEffectFrameIndex
    let hdr:Bool
    let mode:NightFixMode
    let pending:Bool
    let lease:NightFixLease
    func sample(at time:Double)->(URL,Double)? {
        let frame=index.last(at:time)
        guard let chunk=chunks.first(where:{$0.first<=frame && frame<$0.first+$0.times.count}),let origin=chunk.times.first else {return nil}
        return (root.appendingPathComponent(chunk.file),max(0,index.times[frame]-origin))
    }
}
actor NightFixCache {
    static let shared=NightFixCache()
    static let version=4
    static let chunkFrames=60
    private var gate=VideoEffectAnalysisGate()
    private var initialized=Set<URL>()
    func plan(url:URL,folder:URL,clip:TimelineClip,hdr:Bool,preparation:VideoEffectPreparation,
              progress:@escaping @Sendable(Double)->Void) async throws -> NightFixPlan? {
        let effects=(clip.videoEffects ?? []).filter {$0.needsNightFixFusion && $0.start<clip.end && $0.end>clip.start}
        guard effects.contains(where:{effect in
            func maximum(_ id:String)->Double {guard let p=effect.parameters.first(where:{$0.id==id}) else {return 0};return ([p.value]+p.keyframes.map(\.value)).compactMap {if case .number(let n)=$0 {return n};return nil}.max() ?? 0}
            return maximum("intensity")>0 && maximum("reduction")>0
        }) else {return nil}
        let mode=effects.map(\.nightFixMode).max(by:{$0.radius<$1.radius})!
        let index=try await VideoEffectFrameAnalysis.shared.index(url:url,folder:folder)
        let fingerprint=try await SourceMediaCache.shared.fingerprint(url)
        let identity="night-fusion-\(Self.version)|\(fingerprint)|\(hdr)|\(mode.rawValue)|vision-revision-1|\(ProcessInfo.processInfo.operatingSystemVersionString)"
        let hash=SHA256.hash(data:Data(identity.utf8)).map {String(format:"%02x",$0)}.joined()
        var root=ProjectCacheLocation.root(in:folder).appendingPathComponent("NightFix/"+hash,isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        var values=URLResourceValues();values.isExcludedFromBackup=true;try? root.setResourceValues(values)
        if initialized.insert(root).inserted {
            // Only crash leftovers owned by this cache; never touch source media.
            for file in (try? FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)) ?? [] where file.lastPathComponent.hasSuffix(".partial.mov") {
                try? FileManager.default.removeItem(at:file)
            }
        }
        var requested=Set<Int>()
        for effect in effects {
            // A held frame still reads its original temporal neighborhood.
            let a=clip.frozenFrame?.sourceTime ?? max(clip.start,effect.start)
            let b=clip.frozenFrame.map {$0.sourceTime+0.000001} ?? min(clip.end,effect.end)
            let first=index.last(at:a),last=min(index.times.count-1,max(first,index.first(at:b)-1))
            for n in (first/Self.chunkFrames)...(last/Self.chunkFrames) {requested.insert(n)}
        }
        let duration=try await AVURLAsset(url:url).load(.duration).seconds
        var chunks:[NightFixChunk]=[]
        let ordered=requested.sorted()
        // Pin before any await: another plan may finish and prune while this one
        // is still building its later chunks.
        let lease=NightFixLease(ordered.map {root.appendingPathComponent("\($0).mov")})
        for (ordinal,number) in ordered.enumerated() {
            try Task.checkCancellation()
            let metadata=root.appendingPathComponent("\(number).json"),movie=root.appendingPathComponent("\(number).mov")
            func cached()->NightFixChunk? {
                guard let data=try? Data(contentsOf:metadata),let value=try? JSONDecoder().decode(NightFixChunk.self,from:data),
                      value.version==Self.version,value.first==number*Self.chunkFrames,!value.times.isEmpty,value.times.count==min(Self.chunkFrames,index.times.count-value.first),
                      value.times==Array(index.times[value.first..<min(index.times.count,value.first+value.times.count)]),
                      value.file==movie.lastPathComponent,
                      let bytes=try? movie.resourceValues(forKeys:[.fileSizeKey]).fileSize,bytes==value.bytes,bytes>0 else {return nil}
                return value
            }
            var value=cached()
            let first=number*Self.chunkFrames
            if value==nil,preparation.preparesMissingAnalysis {
                let key=movie.path
                while gate.mustWait(key,deferrable:VideoEffectPreparation.deferrable) {try await Task.sleep(for:.milliseconds(100))}
                if let ready=cached() {value=ready}
                else if let ticket=gate.claim(key,deferrable:VideoEffectPreparation.deferrable) {
                    defer {gate.release(ticket)}
                    try await VideoEffectPreparation.checkpoint(ticket)
                    let partial=root.appendingPathComponent(UUID().uuidString+".partial.mov")
                    defer {try? FileManager.default.removeItem(at:partial)}
                    let worker=Task.detached(priority:VideoEffectPreparation.deferrable ? .utility : .userInitiated) {
                        try await VideoEffectPreparation.$deferrable.withValue(ticket.deferrable) {
                            try await NightFixFusion.make(url:url,index:index,first:first,count:min(Self.chunkFrames,index.times.count-first),
                                sourceDuration:duration,hdr:hdr,mode:mode,destination:partial,ticket:ticket) {p in progress((Double(ordinal)+p)/Double(max(1,ordered.count)))}
                        }
                    }
                    let result=try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()})
                    try ticket.check();try Task.checkCancellation()
                    if FileManager.default.fileExists(atPath:movie.path) {try FileManager.default.removeItem(at:movie)}
                    try FileManager.default.moveItem(at:partial,to:movie)
                    let bytes=try movie.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
                    let record=NightFixChunk(version:Self.version,file:movie.lastPathComponent,first:first,times:result.0,duration:result.1,bytes:bytes)
                    try JSONEncoder().encode(record).write(to:metadata,options:.atomic)
                    value=record
                }
            }
            if let value {chunks.append(value)}
            progress(Double(ordinal+1)/Double(max(1,ordered.count)))
        }
        trim(folder:folder,excluding:Set(requested.map {root.appendingPathComponent("\($0).mov")}))
        return NightFixPlan(root:root,chunks:chunks,index:index,hdr:hdr,mode:mode,pending:chunks.count != requested.count,lease:lease)
    }
    private func trim(folder:URL,excluding:Set<URL>) {
        let root=ProjectCacheLocation.root(in:folder).appendingPathComponent("NightFix")
        guard let walker=FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.fileSizeKey,.contentModificationDateKey]) else {return}
        var files:[(URL,Int,Date)]=[]
        for case let url as URL in walker where url.pathExtension=="mov" && !url.lastPathComponent.contains("partial") {
            if let info=try? url.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey]) {files.append((url,info.fileSize ?? 0,info.contentModificationDate ?? .distantPast))}
        }
        var bytes=files.reduce(0){$0+$1.1}
        for (file,size,_) in files.sorted(by:{$0.2<$1.2}) where bytes>4_000_000_000 && !excluding.contains(file) && !NightFixPins.contains(file) {
            try? FileManager.default.removeItem(at:file);try? FileManager.default.removeItem(at:file.deletingPathExtension().appendingPathExtension("json"));bytes-=size
        }
    }
}

// Queue-confined GPU helpers. Image/texture flips match the common compositor.
final class NightFixGPU {
    let device:MTLDevice,queue:MTLCommandQueue,context:CIContext
    // Keep source video code values: ColorSync uses a display transfer curve
    // for video 709, whereas the reference restoration decodes the 709 OETF.
    // Metal explicitly decodes/encodes that OETF around linear fusion/gain.
    let space=CGColorSpaceCreateExtended(VideoColor.space(hdr:false))!
    private let pipelines:[String:MTLComputePipelineState]
    private var cvCache:CVMetalTextureCache!
    private var adjustmentScratch:[MTLTexture]=[]
    init() throws {
        guard let device=MTLCreateSystemDefaultDevice(),let queue=device.makeCommandQueue() else {throw VideoEffectError.noGPU}
        self.device=device;self.queue=queue
        context=CIContext(mtlCommandQueue:queue,options:[.workingColorSpace:space,.workingFormat:CIFormat.RGBAh,.cacheIntermediates:false])
        let library:MTLLibrary
        if let path=ProcessInfo.processInfo.environment["YOUREC_EFFECTS_METALLIB"] {library=try device.makeLibrary(URL:URL(fileURLWithPath:path))}
        else if let value=device.makeDefaultLibrary() {library=value}else {throw VideoEffectError.missingLibrary}
        var states:[String:MTLComputePipelineState]=[:]
        for name in ["nf_guide","nf_seed","nf_fuse","nf_finish","nf_adjust","nf_chroma","nf_mix"] {
            guard let fn=library.makeFunction(name:name) else {throw VideoEffectError.shader(name)}
            states[name]=try device.makeComputePipelineState(function:fn)
        }
        pipelines=states
        guard CVMetalTextureCacheCreate(nil,nil,device,nil,&cvCache)==kCVReturnSuccess else {throw VideoEffectError.buffer}
    }
    func texture(_ width:Int,_ height:Int,format:MTLPixelFormat = .rgba16Float)throws->MTLTexture {
        let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:format,width:width,height:height,mipmapped:false)
        d.usage=[.shaderRead,.shaderWrite,.renderTarget];d.storageMode = .private
        guard let t=device.makeTexture(descriptor:d) else {throw VideoEffectError.buffer};return t
    }
    func pixelTexture(_ pixel:CVPixelBuffer,format:MTLPixelFormat)throws->(CVMetalTexture,MTLTexture) {
        var wrapper:CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil,cvCache,pixel,nil,format,CVPixelBufferGetWidth(pixel),CVPixelBufferGetHeight(pixel),0,&wrapper)==kCVReturnSuccess,
              let wrapper,let texture=CVMetalTextureGetTexture(wrapper) else {throw VideoEffectError.buffer}
        return (wrapper,texture)
    }
    func upload(_ image:CIImage,to texture:MTLTexture,command:MTLCommandBuffer) {
        context.render(MetalEffectRenderer.textureImage(image),to:texture,commandBuffer:command,bounds:CGRect(x:0,y:0,width:texture.width,height:texture.height),colorSpace:space)
    }
    func run(_ name:String,_ textures:[MTLTexture],_ value:SIMD4<Float>,on command:MTLCommandBuffer,output:MTLTexture)throws {
        guard let encoder=command.makeComputeCommandEncoder(),let state=pipelines[name] else {throw VideoEffectError.buffer}
        encoder.setComputePipelineState(state)
        for (i,t) in textures.enumerated() {encoder.setTexture(t,index:i)}
        var value=value;encoder.setBytes(&value,length:MemoryLayout<SIMD4<Float>>.stride,index:0)
        let width=state.threadExecutionWidth,height=max(1,min(8,state.maxTotalThreadsPerThreadgroup/width))
        encoder.dispatchThreads(MTLSize(width:output.width,height:output.height,depth:1),threadsPerThreadgroup:MTLSize(width:width,height:height,depth:1));encoder.endEncoding()
    }
    func command()throws->MTLCommandBuffer {guard let c=queue.makeCommandBuffer() else {throw VideoEffectError.buffer};return c}
    func finish(_ command:MTLCommandBuffer)throws {command.commit();command.waitUntilCompleted();if let error=command.error {throw error}}
    func image(_ texture:MTLTexture)throws->CIImage {guard let image=CIImage(mtlTexture:texture,options:[.colorSpace:space]) else {throw VideoEffectError.buffer};return MetalEffectRenderer.textureImage(image)}
    func adjust(original:CIImage,fused:CIImage,effect:VideoEffectSettings,time:Double,cached:Bool=false)throws->CIImage {
        let mix=Float(effect.number("intensity",at:time)),amount=Float(effect.number("reduction",at:time)),stops=Float(effect.number("brightness",at:time))
        if mix<=0 || amount<=0 && stops==0 {return original}
        let w=Int(original.extent.width),h=Int(original.extent.height)
        if adjustmentScratch.first?.width != w || adjustmentScratch.first?.height != h {adjustmentScratch=try (0..<5).map {_ in try texture(w,h)}}
        let raw=adjustmentScratch[0],temporal=adjustmentScratch[1],first=adjustmentScratch[2],second=adjustmentScratch[3],third=adjustmentScratch[4],result=try texture(w,h)
        let command=try command();upload(original,to:raw,command:command);upload(fused,to:temporal,command:command)
        try run("nf_adjust",[raw,temporal,first],SIMD4<Float>(amount,stops,Float(effect.number("detail",at:time)),cached ? 1 : 0),on:command,output:first)
        try run("nf_chroma",[first,second],SIMD4<Float>(amount,1,0,0),on:command,output:second)
        try run("nf_chroma",[second,third],SIMD4<Float>(amount,0,1,0),on:command,output:third)
        try run("nf_mix",[raw,third,result],SIMD4<Float>(mix,0,0,0),on:command,output:result)
        try finish(command)
        return try image(result)
    }
}

private struct NightFixGuide {
    let pixel:CVPixelBuffer
    let mean:Double
    let signature:[Double]
    func difference(_ other:NightFixGuide)->Double {zip(signature,other.signature).reduce(0) {$0+abs($1.0-$1.1)}/Double(signature.count)}
}
final class NightFixFusion {
    private static let visionLock=NSLock()
    let gpu:NightFixGPU
    let reader:VideoEffectSourceReader
    let index:VideoEffectFrameIndex
    let mode:NightFixMode
    let width:Int,height:Int,guideWidth:Int,guideHeight:Int
    let current:MTLTexture,neighbor:MTLTexture,accumulated:MTLTexture,output:MTLTexture
    private var guides:[Int:NightFixGuide]=[:]
    private var flows:[String:CVPixelBuffer]=[:]
    init(url:URL,index:VideoEffectFrameIndex,hdr:Bool,width:Int,height:Int,mode:NightFixMode = .precise)throws {
        self.index=index;self.mode=mode;self.width=width;self.height=height;gpu=try NightFixGPU()
        reader=try VideoEffectSourceReader(url:url,hdr:hdr,capacity:12,highPrecision:true)
        let scale=min(0.25,mode.guideLimit/Double(max(width,height)))
        guideWidth=max(32,Int(Double(width)*scale));guideHeight=max(32,Int(Double(height)*scale))
        current=try gpu.texture(width,height);neighbor=try gpu.texture(width,height);accumulated=try gpu.texture(width,height);output=try gpu.texture(width,height)
    }
    private func source(_ n:Int)throws->CIImage {try reader.sample(at:index.times[n],firstAtOrAfter:true).image}
    private func guide(_ n:Int)throws->NightFixGuide {
        if let g=guides[n] {return g}
        var pixel:CVPixelBuffer?
        guard CVPixelBufferCreate(nil,guideWidth,guideHeight,kCVPixelFormatType_32BGRA,[kCVPixelBufferMetalCompatibilityKey:true,kCVPixelBufferIOSurfacePropertiesKey:[:]] as CFDictionary,&pixel)==kCVReturnSuccess,let pixel else {throw VideoEffectError.buffer}
        let (wrapper,texture)=try gpu.pixelTexture(pixel,format:.bgra8Unorm),command=try gpu.command()
        gpu.upload(try source(n),to:neighbor,command:command)
        try gpu.run("nf_guide",[neighbor,texture],SIMD4<Float>.zero,on:command,output:texture);try gpu.finish(command);withExtendedLifetime(wrapper) {}
        CVPixelBufferLockBaseAddress(pixel,.readOnly);defer {CVPixelBufferUnlockBaseAddress(pixel,.readOnly)}
        let bytes=CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to:UInt8.self),rowStride=CVPixelBufferGetBytesPerRow(pixel)
        var sum=0.0
        for y in 0..<guideHeight {for x in 0..<guideWidth {sum+=Double(bytes[y*rowStride+x*4])/255}}
        var signature:[Double]=[]
        for y in stride(from:0,to:guideHeight,by:max(1,guideHeight/16)) {
            for x in stride(from:0,to:guideWidth,by:max(1,guideWidth/16)) {signature.append(Double(bytes[y*rowStride+x*4])/255)}
        }
        let value=NightFixGuide(pixel:pixel,mean:sum/Double(guideWidth*guideHeight),signature:signature);guides[n]=value;return value
    }
    func flow(from a:Int,to b:Int)throws->CVPixelBuffer {
        let key="\(a):\(b)";if let value=flows[key] {return value}
        let first=try guide(a),second=try guide(b)
        let pixel:CVPixelBuffer = try autoreleasepool {
            Self.visionLock.lock();defer {Self.visionLock.unlock()}
            // Apple's header example: handler = from; targeted image = to.
            let request=VNGenerateOpticalFlowRequest(targetedCVPixelBuffer:second.pixel,options:[:])
            request.revision=VNGenerateOpticalFlowRequestRevision1
            request.computationAccuracy = mode == .medium ? .medium : .high;request.outputPixelFormat=kCVPixelFormatType_TwoComponent32Float
            try VNImageRequestHandler(cvPixelBuffer:first.pixel,options:[:]).perform([request])
            guard let result=request.results?.first?.pixelBuffer else {throw NightFixError.processing};return result
        }
        flows[key]=pixel;return pixel
    }
    func frame(_ n:Int,cacheEncoding:Bool=false,cancel:()->Bool)throws->CIImage {
        let center=try guide(n)
        let begin=try gpu.command();gpu.upload(try source(n),to:current,command:begin)
        try gpu.run("nf_seed",[current,accumulated],SIMD4<Float>.zero,on:begin,output:accumulated);try gpu.finish(begin)
        for j in max(0,n-mode.radius)...min(index.times.count-1,n+mode.radius) where j != n {
            if cancel() {throw CancellationError()}
            let other=try guide(j)
            // Reject global exposure jumps before flow; photometric and
            // bidirectional consistency below also reject local occlusions.
            if abs(center.mean-other.mean)>0.075 || center.difference(other)>22.0/255.0 {continue}
            let f=try flow(from:n,to:j),b=try flow(from:j,to:n)
            let (fw,ft)=try gpu.pixelTexture(f,format:.rg32Float),(bw,bt)=try gpu.pixelTexture(b,format:.rg32Float)
            let command=try gpu.command();gpu.upload(try source(j),to:neighbor,command:command)
            try gpu.run("nf_fuse",[current,neighbor,ft,bt,accumulated],SIMD4<Float>(Float(j-n),Float(guideWidth),Float(guideHeight),0),on:command,output:accumulated)
            try gpu.finish(command);withExtendedLifetime((fw,bw)) {}
        }
        let end=try gpu.command();try gpu.run("nf_finish",[accumulated,output],SIMD4<Float>(cacheEncoding ? 1 : 0,0,0,0),on:end,output:output);try gpu.finish(end)
        guides=guides.filter {$0.key>=n-3}
        flows=flows.filter {key,_ in key.split(separator:":").allSatisfy {Int($0)!>=n-3}}
        return try gpu.image(output)
    }
    static func make(url:URL,index:VideoEffectFrameIndex,first:Int,count:Int,sourceDuration:Double,hdr:Bool,mode:NightFixMode,destination:URL,ticket:VideoEffectAnalysisGate.Ticket,
                     progress:@escaping @Sendable(Double)->Void) async throws->([Double],Double) {
        let asset=AVURLAsset(url:url)
        guard let track=try await asset.loadTracks(withMediaType:.video).first else {throw ProjectError.invalidMedia}
        let size=try await track.load(.naturalSize),w=Int(size.width),h=Int(size.height)
        let available=(try FileManager.default.attributesOfFileSystem(forPath:destination.deletingLastPathComponent().path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        guard available>128_000_000 else {throw NightFixError.space}
        let engine=try NightFixFusion(url:url,index:index,hdr:hdr,width:w,height:h,mode:mode)
        let writer=try AVAssetWriter(outputURL:destination,fileType:.mov)
        let input=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.hevc,AVVideoWidthKey:w,AVVideoHeightKey:h,AVVideoColorPropertiesKey:VideoColor.properties(hdr:hdr),AVVideoCompressionPropertiesKey:[AVVideoProfileLevelKey:kVTProfileLevel_HEVC_Main10_AutoLevel,AVVideoAverageBitRateKey:max(12_000_000,w*h*14),AVVideoExpectedSourceFrameRateKey:max(1,try await track.load(.nominalFrameRate)),AVVideoAllowFrameReorderingKey:false]])
        input.expectsMediaDataInRealTime=false
        let adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,kCVPixelBufferWidthKey as String:w,kCVPixelBufferHeightKey as String:h,kCVPixelBufferIOSurfacePropertiesKey as String:[:]])
        guard writer.canAdd(input) else {throw NightFixError.processing};writer.add(input)
        guard writer.startWriting() else {throw writer.error ?? NightFixError.processing};writer.startSession(atSourceTime:.zero)
        var complete=false;defer {if !complete {writer.cancelWriting()}}
        let times=Array(index.times[first..<first+count]),origin=times[0]
        let finish=first+count<index.times.count ? index.times[first+count] : sourceDuration
        for (offset,n) in (first..<first+count).enumerated() {
            try await VideoEffectPreparation.checkpoint(ticket)
            while !input.isReadyForMoreMediaData {try await VideoEffectPreparation.checkpoint(ticket);guard writer.status == .writing else {throw writer.error ?? NightFixError.processing};try await Task.sleep(for:.milliseconds(5))}
            try autoreleasepool {
                let image=try engine.frame(n,cacheEncoding:true,cancel:{Task.isCancelled})
                guard let pool=adaptor.pixelBufferPool else {throw VideoEffectError.buffer}
                var pixel:CVPixelBuffer?;guard CVPixelBufferPoolCreatePixelBuffer(nil,pool,&pixel)==kCVReturnSuccess,let pixel else {throw VideoEffectError.buffer}
                VideoColor.tag(pixel,hdr:hdr)
                engine.gpu.context.render(image,to:pixel,bounds:CGRect(origin:.zero,size:size),colorSpace:VideoColor.space(hdr:hdr))
                guard adaptor.append(pixel,withPresentationTime:CMTime(seconds:index.times[n]-origin,preferredTimescale:240000)) else {throw writer.error ?? NightFixError.processing}
            }
            progress(Double(offset+1)/Double(count))
        }
        writer.endSession(atSourceTime:CMTime(seconds:max(0.00001,finish-origin),preferredTimescale:240000));input.markAsFinished()
        await writer.finishWriting();try Task.checkCancellation();try ticket.check()
        guard writer.status == .completed else {throw writer.error ?? NightFixError.processing};complete=true
        return (times,finish-origin)
    }
}

// Each compositor/analysis queue owns its own small reader set and GPU scratch.
final class NightFixPicture {
    private var gpu:NightFixGPU?
    private var readers:[URL:VideoEffectSourceReader]=[:]
    func render(_ raw:CIImage,instruction:VideoToolInstruction,time:Double)throws->CIImage {
        guard instruction.videoEffectsEnabled else {return raw}
        let effects=instruction.effectSettings.filter {$0.kind == .nightFix && $0.isActive(at:time)}
        guard let effect=effects.first else {return raw}
        if gpu==nil {gpu=try NightFixGPU()}
        let fused:CIImage
        let cached:Bool
        if effect.nightFixMode != .fast,let plan=instruction.nightFix,plan.mode == effect.nightFixMode,let (url,local)=plan.sample(at:time) {
            if readers[url]==nil {if readers.count>=3 {readers.removeAll()};readers[url]=try VideoEffectSourceReader(url:url,hdr:instruction.sourceHDR,capacity:2,highPrecision:true)}
            fused=try readers[url]!.sample(at:local).image;cached=true
        } else {fused=raw;cached=false}
        return try gpu!.adjust(original:raw,fused:fused,effect:effect,time:time,cached:cached)
    }
}

#if DEBUG && canImport(UIKit)
import UIKit
@MainActor enum NightFixDiagnostics {
    static func cleanup() {
        let documents=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
        for url in (try? FileManager.default.contentsOfDirectory(at:documents,includingPropertiesForKeys:nil)) ?? [] {
            let name=url.lastPathComponent
            if (name.hasPrefix("NightFixDiagnostics-") && UUID(uuidString:String(name.dropFirst("NightFixDiagnostics-".count))) != nil) || ["night-fix-input.mov","night-fix-qa-latest.txt"].contains(name) {try? FileManager.default.removeItem(at:url)}
        }
    }
    static func run() async {
        let documents=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
        let root=documents.appendingPathComponent("NightFixDiagnostics-"+UUID().uuidString)
        var report:[String:Any]=["status":"running","started":Date().description]
        var peak:UInt64=0,lastProgress = -1.0
        func memory()->UInt64 {
            var info=task_vm_info_data_t(),count=mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size/MemoryLayout<integer_t>.size)
            let code=withUnsafeMutablePointer(to:&info) {p in p.withMemoryRebound(to:integer_t.self,capacity:Int(count)) {task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&count)}}
            return code==KERN_SUCCESS ? info.phys_footprint : 0
        }
        func save() {if let data=try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) {try? data.write(to:root.appendingPathComponent("report.json"),options:.atomic)}}
        func check(_ value:Bool,_ message:String)throws {if !value {throw NSError(domain:"NightFixQA",code:1,userInfo:[NSLocalizedDescriptionKey:message])}}
        RecordingAppDelegate.keepAwake("night-fix-qa",active:true);defer {RecordingAppDelegate.keepAwake("night-fix-qa",active:false)}
        do {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            try root.lastPathComponent.write(to:documents.appendingPathComponent("night-fix-qa-latest.txt"),atomically:true,encoding:.utf8)
            try FileManager.default.copyItem(at:documents.appendingPathComponent("night-fix-input.mov"),to:root.appendingPathComponent("source.mov"))
            let asset=AVURLAsset(url:root.appendingPathComponent("source.mov")),duration=try await asset.load(.duration).seconds
            var project=Project(title:"Night fix QA");project.append(SourceMedia(filename:"source.mov",duration:duration))
            let checksum=try await SourceMediaCache.shared.fingerprint(root.appendingPathComponent("source.mov"))
            var edit=project.edit;edit.clips[0].videoEffects=[VideoEffectSettings(.nightFix,start:0,end:duration)];project.commit(edit)
            // Cold per-mode caches, same real input. Fast must never defer work.
            for mode in [NightFixMode.fast,.medium] {
                edit.clips[0].videoEffects![0].set("mode",.choice(mode.rawValue));project.commit(edit)
                let start=Date(),quick=try await MediaRenderer.timeline(project:project,folder:root,effectPreparation:.cached)
                if mode == .fast {try check(!quick.effectAnalysisPending,"Fast unexpectedly schedules temporal preparation")}
                let prepared=try await MediaRenderer.timeline(project:project,folder:root)
                report[mode.rawValue+"PrepareSeconds"]=Date().timeIntervalSince(start)
                try check(!prepared.effectAnalysisPending,"Mode left preparation pending")
                let generator=AVAssetImageGenerator(asset:prepared.composition);generator.videoComposition=prepared.videoComposition
                let frame=try await generator.image(at:CMTime(seconds:duration/2,preferredTimescale:240000)).image
                try UIImage(cgImage:frame).pngData()?.write(to:root.appendingPathComponent(mode.rawValue+".png"))
                let exportStart=Date(),file=root.appendingPathComponent(mode.rawValue+".mp4")
                _=try await MediaRenderer.render(project:project,folder:root,destination:file,progress:{_ in})
                report[mode.rawValue+"ExportSeconds"]=Date().timeIntervalSince(exportStart)
                let output=AVURLAsset(url:file),length=try await output.load(.duration).seconds,audio=try await output.loadTracks(withMediaType:.audio)
                try check(abs(length-duration)<0.04 && !audio.isEmpty,"Mode changed timing or lost audio")
                peak=max(peak,memory());save()
            }
            edit.clips[0].videoEffects![0].set("mode",.choice("Precise"));project.commit(edit)
            let begin=Date()
            let media=try await MediaRenderer.timeline(project:project,folder:root,videoProgress:{p in Task {@MainActor in
                peak=max(peak,memory());if p-lastProgress>0.05 {lastProgress=p;report["progress"]=p;report["peakBytes"]=peak;save()}
            }})
            report["prepareSeconds"]=Date().timeIntervalSince(begin);report["framesPrepared"]=Int((duration*30).rounded());peak=max(peak,memory())
            try check(!media.effectAnalysisPending,"Final preparation is incomplete")
            let gen=AVAssetImageGenerator(asset:media.composition);gen.videoComposition=media.videoComposition
            gen.requestedTimeToleranceBefore = .zero;gen.requestedTimeToleranceAfter = .zero
            for (n,t) in [0.25,duration/2,max(0,duration-0.25)].enumerated() {
                let image=try await gen.image(at:CMTime(seconds:t,preferredTimescale:240000)).image
                try UIImage(cgImage:image).pngData()?.write(to:root.appendingPathComponent("default-\(n).png"));peak=max(peak,memory())
            }
            let rawGenerator=AVAssetImageGenerator(asset:asset);rawGenerator.appliesPreferredTrackTransform=true
            let rawFrame=try await rawGenerator.image(at:CMTime(seconds:duration/2,preferredTimescale:240000)).image
            try UIImage(cgImage:rawFrame).pngData()?.write(to:root.appendingPathComponent("original.png"))
            let first=root.appendingPathComponent("default.mp4")
            _=try await MediaRenderer.render(project:project,folder:root,destination:first,progress:{_ in})
            edit=project.edit;edit.clips[0].videoEffects![0].set("brightness",.number(6));edit.clips[0].videoEffects![0].set("reduction",.number(3));project.commit(edit)
            let reconfigure=Date(),strong=try await MediaRenderer.timeline(project:project,folder:root)
            report["reconfigureSeconds"]=Date().timeIntervalSince(reconfigure)
            let sg=AVAssetImageGenerator(asset:strong.composition);sg.videoComposition=strong.videoComposition
            let still=try await sg.image(at:CMTime(seconds:duration/2,preferredTimescale:240000)).image
            try UIImage(cgImage:still).pngData()?.write(to:root.appendingPathComponent("strong.png"));peak=max(peak,memory())
            let second=root.appendingPathComponent("strong.mp4")
            _=try await MediaRenderer.render(project:project,folder:root,destination:second,progress:{_ in})
            for output in [first,second] {
                let rendered=AVURLAsset(url:output),length=try await rendered.load(.duration).seconds
                try check(abs(length-duration)<0.04,"Export changed the timeline length")
                let tracks=try await rendered.loadTracks(withMediaType:.audio)
                try check(!tracks.isEmpty,"Original audio missing from export")
            }
            let sourceHash=try await SourceMediaCache.shared.fingerprint(root.appendingPathComponent("source.mov"))
            try check(sourceHash==checksum,"Original source changed")
            report["duration"]=duration;report["peakBytes"]=peak;report["sourceSHA256"]=checksum;report["status"]="passed"
        } catch {report["status"]="failed";report["error"]=String(describing:error)}
        save()
    }
}
#endif
