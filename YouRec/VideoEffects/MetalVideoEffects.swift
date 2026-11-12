@preconcurrency import Metal
import CoreImage
import CoreVideo
import Foundation
import simd

struct VideoFormat {
    var width: Int
    var height: Int
    var frameRate: Double = 30
    var hdr = false
}
struct FrameContext {
    var presentationTime: Double
    var frameIndex: Int
    var frameRate: Double = 30
    var personMask: MTLTexture?
    var depthMap: MTLTexture?
    var depthFocus: Float?
    var depthFocusTexture:MTLTexture?
    var target:CGPoint?
    var intensity: Float = 1
    var effectTime: Double = 0
    var duration: Double = 0
    var palette: EffectPalette?
    var background: MTLTexture?
    var cleanPlate: MTLTexture?
    var temporalImage: MTLTexture?
    var holdTime: Double?
    var quality:VideoEffectQuality = .full
    var matteHistory:[VideoEffectMatteCache.Frame]?
    var matteCapture:VideoEffectMatteCache.Key?
    var matteOnly=false
    var resampleMatteHistory=false
    var matteDetectCuts=true
    var matteDetectCurrentCut=false
    var matteRecordCut=false
    var mattePublishCapture=true
}
protocol VideoEffect {
    static var id: String { get }
    static var displayName: String { get }
    static var historyNote: String { get }
    static var family: EffectFamily { get }
    static var mode: EffectMode { get }
    var parameters: [EffectParameter] { get set }
    func prepare(device: MTLDevice, format: VideoFormat) throws
    func encode(input: MTLTexture, output: MTLTexture, context: FrameContext, commandBuffer: MTLCommandBuffer)
}
protocol VideoEffectDefinition { static var kind: VideoEffectID { get } }
final class ShaderVideoEffect<Definition: VideoEffectDefinition>: VideoEffect {
    static var id: String { Definition.kind.rawValue }
    static var displayName: String { Definition.kind.descriptor.displayName }
    static var historyNote: String { Definition.kind.descriptor.historyNote }
    static var family: EffectFamily { Definition.kind.descriptor.family }
    static var mode: EffectMode { Definition.kind.descriptor.mode }
    var parameters = VideoEffectSettings(Definition.kind).parameters
    private var renderer: MetalEffectRenderer?
    func prepare(device: MTLDevice, format: VideoFormat) throws { renderer = try MetalEffectRenderer(device: device) }
    func encode(input: MTLTexture, output: MTLTexture, context: FrameContext, commandBuffer: MTLCommandBuffer) {
        guard let renderer else { return }
        var settings = VideoEffectSettings(Definition.kind); settings.parameters = parameters
        var frame=context
        if settings.kind.descriptor.supportsIntensity { frame.intensity=Float(settings.number("intensity",at:context.presentationTime)) }
        renderer.beginEncoding()
        renderer.encode(settings,input:input,output:output,frame:frame,commandBuffer:commandBuffer)
    }
}
enum VideoEffectError: LocalizedError {
    case noGPU, missingLibrary, shader(String), buffer, unavailableMask, unavailableMatteHistory,analysisPending
    var errorDescription: String? { switch self {
    case .noGPU: return "Video effects need a Metal-capable device."
    case .missingLibrary: return "The video effect shaders could not be loaded."
    case .shader(let name): return "The video effect could not be prepared: \(name)."
    case .buffer: return "The video effect could not allocate its working image."
    case .unavailableMask: return "A subject mask is needed for this effect."
    case .unavailableMatteHistory: return "The effect's source-frame history is not ready."
    case .analysisPending:return "The accurate effect preview is still being prepared."
    } }
}
// A lease lives at least as long as every GPU consumer of the image. Core
// Image graphs retain textures but cannot tell a pool when reuse is safe.
final class VideoEffectFrameLease: @unchecked Sendable {
    fileprivate let texture:MTLTexture
    private let pool:VideoEffectOutputPool
    fileprivate init(_ texture:MTLTexture,pool:VideoEffectOutputPool) { self.texture=texture;self.pool=pool }
    deinit { pool.recycle(texture) }
}
private final class VideoEffectOutputPool: @unchecked Sendable {
    private let lock=NSLock()
    private var available:[MTLTexture]=[]
    func take(width:Int,height:Int,format:MTLPixelFormat)->MTLTexture? {
        lock.lock();defer { lock.unlock() }
        guard let index=available.lastIndex(where: { $0.width==width && $0.height==height && $0.pixelFormat==format }) else { return nil }
        return available.remove(at:index)
    }
    func recycle(_ texture:MTLTexture) {
        lock.lock();defer { lock.unlock() }
        while !available.isEmpty && available.reduce(texture.allocatedSize,{ $0+$1.allocatedSize })>128*1024*1024 { available.removeFirst() }
        if texture.allocatedSize<=128*1024*1024 { available.append(texture) }
    }
}

// Instances are confined to one renderer queue. CI and Metal share the device
// and command buffer; full-resolution frames never round-trip through the CPU.
final class MetalEffectRenderer {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let context: CIContext
    let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private let pipelines: [String: MTLComputePipelineState]
    private let effects: [VideoEffectID: MTLComputePipelineState]
    private var blurWeights: [Float: [SIMD4<Float>]] = [:]
    private var scratch: [String: [MTLTexture?]] = [:]
    private var scratchCounts: [String: Int] = [:]
    private var allocationError: Error?
    private var matteCaptures:[(id:UUID,key:VideoEffectMatteCache.Key,frame:VideoEffectMatteCache.Frame,cut:MTLBuffer?,publish:Bool)]=[]
    private var matteCutBuffers:[MTLBuffer]=[]
    private let outputPool=VideoEffectOutputPool()
    private let emergencyTexture: MTLTexture
    private(set) var gpuSeconds = 0.0
    private(set) var encodingSeconds = 0.0
    private(set) var completionSeconds = 0.0
    private(set) var gpuStages:[String:Double]=[:]
    var profileGPU=false
    private var counters:MTLCounterSampleBuffer?
    private var counterLabels:[String]=[]
    private static let pipelineLock=NSLock()
    private static var compiled:[String:([String:MTLComputePipelineState],[VideoEffectID:MTLComputePipelineState])]=[:]
    init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard let device, let queue = device.makeCommandQueue() else { throw VideoEffectError.noGPU }
        self.device = device; self.queue = queue
        let emergency = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false)
        emergency.usage = [.shaderRead,.shaderWrite,.renderTarget]
        guard let fallback = device.makeTexture(descriptor: emergency) else { throw VideoEffectError.buffer }
        emergencyTexture = fallback
        // CI uploads and compute passes must share ordering. A device-only
        // context uses another queue and cannot order writes to reused masks.
        context = CIContext(mtlCommandQueue: queue, options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])
        let cacheKey="\(device.registryID)-"+(ProcessInfo.processInfo.environment["YOUREC_EFFECTS_METALLIB"] ?? "app")
        Self.pipelineLock.lock();defer { Self.pipelineLock.unlock() }
        if let cached=Self.compiled[cacheKey] { pipelines=cached.0;effects=cached.1;return }
        let library: MTLLibrary
        if let path = ProcessInfo.processInfo.environment["YOUREC_EFFECTS_METALLIB"] { library = try device.makeLibrary(URL: URL(fileURLWithPath: path)) }
        else if let loaded = device.makeDefaultLibrary() { library = loaded }
        else { throw VideoEffectError.missingLibrary }
        var result: [String: MTLComputePipelineState] = [:]
        for name in ["ve_personCoverage","ve_bokehAmount","ve_depthPlace","ve_depthFocus","ve_depthMask","ve_depthBokeh","ve_geometryMap","ve_toneMap","ve_blur","ve_bilateral","ve_highlights","ve_guidedStats","ve_guidedApply","ve_keyAlpha","ve_morphology","ve_bgWeight","ve_bgNormalize","ve_personHint","ve_reduce","ve_screenReference","ve_subjectWeight","ve_grainNoise","ve_maskSceneCut","ve_maskTemporal","ve_matteGuide","ve_matteCuts","ve_matteWindow","ve_isolationAlpha"] {
            guard let function = library.makeFunction(name: name) else { throw VideoEffectError.shader(name) }
            result[name] = try device.makeComputePipelineState(function: function)
        }
        pipelines = result
        // Specialization removes unrelated effect branches, loops and registers.
        // This is especially important for the smaller iPhone GPUs.
        var specialized: [VideoEffectID: MTLComputePipelineState] = [:]
        for kind in VideoEffectID.allCases {
            let constants=MTLFunctionConstantValues();var index=kind.shaderIndex
            constants.setConstantValue(&index,type:.uint,index:0)
            let function=try library.makeFunction(name:"ve_effect",constantValues:constants)
            specialized[kind]=try device.makeComputePipelineState(function:function)
        }
        effects=specialized
        Self.compiled[cacheKey]=(result,specialized)
    }
    func texture(width: Int, height: Int, shared: Bool = false, format:MTLPixelFormat = .rgba16Float) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead,.shaderWrite,.renderTarget]; descriptor.storageMode = shared ? .shared : .private
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw VideoEffectError.buffer }
        return texture
    }
    private func temporary(_ width: Int, _ height: Int, format:MTLPixelFormat = .rgba16Float) -> MTLTexture {
        let key = "\(width)x\(height)-\(format.rawValue)", index = scratchCounts["\(width)x\(height)-\(format.rawValue)", default:0]
        scratchCounts[key] = index+1
        do {
            if scratch[key] == nil { scratch[key] = [] }
            if scratch[key]!.count <= index { scratch[key]!.append(nil) }
            if scratch[key]![index] == nil { scratch[key]![index] = try outputPool.take(width:width,height:height,format:format) ?? texture(width:width,height:height,format:format) }
            return scratch[key]![index]!
        } catch { allocationError = error; return emergencyTexture }
    }
    func beginEncoding() {
        scratchCounts.removeAll(keepingCapacity:true);allocationError=nil;counterLabels.removeAll(keepingCapacity:true);gpuStages.removeAll(keepingCapacity:true)
        if profileGPU,counters == nil,device.supportsCounterSampling(.atStageBoundary),let set=device.counterSets?.first(where: { $0.name==MTLCommonCounterSet.timestamp.rawValue }) {
            let descriptor=MTLCounterSampleBufferDescriptor();descriptor.counterSet=set;descriptor.sampleCount=512;descriptor.storageMode = .shared
            counters=try? device.makeCounterSampleBuffer(descriptor:descriptor)
        }
    }
    private func encoder(_ buffer:MTLCommandBuffer,label:String)->MTLComputeCommandEncoder? {
        guard profileGPU,let counters,counterLabels.count<256 else { return buffer.makeComputeCommandEncoder() }
        let pass=MTLComputePassDescriptor(),index=counterLabels.count*2
        pass.sampleBufferAttachments[0].sampleBuffer=counters
        pass.sampleBufferAttachments[0].startOfEncoderSampleIndex=index
        pass.sampleBufferAttachments[0].endOfEncoderSampleIndex=index+1
        counterLabels.append(label)
        return buffer.makeComputeCommandEncoder(descriptor:pass)
    }
    private func resolveCounters() {
        guard profileGPU,!counterLabels.isEmpty,let data=try? counters?.resolveCounterRange(0..<(counterLabels.count*2)) else { return }
        data.withUnsafeBytes { bytes in
            for (index,label) in counterLabels.enumerated() {
                let start=bytes.loadUnaligned(fromByteOffset:index*16,as:UInt64.self),end=bytes.loadUnaligned(fromByteOffset:index*16+8,as:UInt64.self)
                if end>=start,end != UInt64.max { gpuStages[label,default:0]+=Double(end-start)/1_000_000_000 }
            }
        }
    }
    static func textureImage(_ image: CIImage) -> CIImage {
        image.transformed(by:CGAffineTransform(a:1,b:0,c:0,d:-1,tx:-image.extent.minX,ty:image.extent.maxY))
    }
    private func compute<T>(_ name: String, textures: [MTLTexture], value: T, output: MTLTexture, commandBuffer: MTLCommandBuffer) {
        var value=value
        let data=withUnsafeBytes(of:&value) { Data($0) }
        computeData(name,textures:textures,data:data,output:output,commandBuffer:commandBuffer)
    }
    func encodeMaskTemporal(mask:MTLTexture,guide:MTLTexture,previous:MTLTexture,state:MTLTexture,output:MTLTexture,cut:MTLTexture,weight:Float,reset:Bool,motionGate:Bool,commandBuffer:MTLCommandBuffer) {
        let values=SIMD4<Float>(weight,reset ? 1 : 0,motionGate ? 0.02 : .infinity,0.12)
        compute("ve_maskSceneCut",textures:[guide,previous,cut],value:values,output:cut,commandBuffer:commandBuffer)
        compute("ve_maskTemporal",textures:[mask,guide,previous,state,output,cut],value:values,output:output,commandBuffer:commandBuffer)
    }
    // Source-window matte primitives. History is immutable and newest first;
    // callers enumerate actual source frames, never the player's request order.
    // These utilities are not enabled in a recipe until its random-access
    // source-window provider supplies complete upstream history.
    func matteGuide(_ input:MTLTexture,commandBuffer:MTLCommandBuffer)->MTLTexture {
        let output=temporary(max(1,(input.width+3)/4),max(1,(input.height+3)/4),format:.r16Float)
        compute("ve_matteGuide",textures:[input,output],value:UInt32(0),output:output,commandBuffer:commandBuffer)
        return output
    }
    func temporalMatte(current:MTLTexture,guide:MTLTexture,history:[(matte:MTLTexture,guide:MTLTexture)],kind:VideoEffectMatteKind,detectCuts:Bool=true,detectCurrentCut:Bool=false,cutReadback:MTLBuffer?=nil,commandBuffer:MTLCommandBuffer)->MTLTexture {
        let previous=Array(history.prefix(kind.capacity-1))
        let mattes=[current]+previous.map(\.matte),guides=[guide]+previous.map(\.guide)
        var parameters=SIMD4<Float>(Float(kind.prior),Float(mattes.count),kind == .key ? 1 : 0,detectCuts ? 0 : detectCurrentCut ? 2 : 1)
        let cuts=temporary(8,1,format:.r16Float),result=temporary(current.width,current.height,format:.r16Float)
        for (name,output) in [("ve_matteCuts",cuts),("ve_matteWindow",result)] {
            guard let encoder=encoder(commandBuffer,label:name),let pipeline=pipelines[name] else {allocationError=VideoEffectError.shader(name);return current}
            encoder.setComputePipelineState(pipeline)
            for index in 0..<8 {
                encoder.setTexture(mattes[min(index,mattes.count-1)],index:index)
                encoder.setTexture(guides[min(index,guides.count-1)],index:8+index)
            }
            encoder.setTexture(cuts,index:16);encoder.setTexture(output,index:17)
            encoder.setBytes(&parameters,length:MemoryLayout<SIMD4<Float>>.size,index:0)
            encoder.dispatchThreads(MTLSize(width:output.width,height:output.height,depth:1),threadsPerThreadgroup:MTLSize(width:pipeline.threadExecutionWidth,height:1,depth:1));encoder.endEncoding()
        }
        if let cutReadback {
            guard let copy=commandBuffer.makeBlitCommandEncoder() else {allocationError=VideoEffectError.buffer;return result}
            // One half-float decision, never a full-resolution CPU image copy.
            copy.copy(from:cuts,sourceSlice:0,sourceLevel:0,sourceOrigin:.init(x:0,y:0,z:0),sourceSize:.init(width:1,height:1,depth:1),to:cutReadback,destinationOffset:0,destinationBytesPerRow:256,destinationBytesPerImage:256)
            copy.endEncoding()
        }
        return result
    }
    private func computeData(_ name:String,textures:[MTLTexture],data:Data,output:MTLTexture,commandBuffer:MTLCommandBuffer) {
        guard let encoder = encoder(commandBuffer,label:name), let pipeline = pipelines[name] else { allocationError = VideoEffectError.shader(name); return }
        encoder.label = name; encoder.setComputePipelineState(pipeline)
        for (index, texture) in textures.enumerated() { encoder.setTexture(texture, index: index) }
        data.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length:$0.count,index:0) }
        let width = pipeline.threadExecutionWidth, height = max(1, min(8, pipeline.maxTotalThreadsPerThreadgroup / width))
        encoder.dispatchThreads(MTLSize(width: output.width, height: output.height, depth: 1), threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1)); encoder.endEncoding()
    }
    private func effectPass(_ settings: VideoEffectSettings, input: MTLTexture, aux: MTLTexture, mask: MTLTexture, background: MTLTexture, extra: MTLTexture, wrap: MTLTexture, matchSubject: MTLTexture, matchBackground: MTLTexture, noise:MTLTexture, output: MTLTexture, frame: FrameContext, commandBuffer: MTLCommandBuffer) {
        guard let encoder = encoder(commandBuffer,label:settings.kind.rawValue), let pipeline = effects[settings.kind] else { allocationError = VideoEffectError.shader("ve_effect"); return }
        encoder.setComputePipelineState(pipeline)
        for (index, texture) in [input,aux,mask,background,output,extra,wrap,matchSubject,matchBackground,noise].enumerated() { encoder.setTexture(texture, index: index) }
        let data = uniforms(settings, frame: frame)
        data.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 0) }
        encoder.dispatchThreads(MTLSize(width: output.width, height: output.height, depth: 1), threadsPerThreadgroup: MTLSize(width: pipeline.threadExecutionWidth, height: max(1,min(8,pipeline.maxTotalThreadsPerThreadgroup/pipeline.threadExecutionWidth)), depth: 1)); encoder.endEncoding()
    }
    private func uniforms(_ settings: VideoEffectSettings, frame: FrameContext, geometrySize:CGSize?=nil) -> Data {
        // Byte layout matches EffectUniforms: 8 scalar words then float4 arrays.
        var header: [UInt32] = [settings.kind.shaderIndex,UInt32(truncatingIfNeeded: frame.frameIndex), (frame.personMask == nil ? 0 : 1) | (frame.cleanPlate == nil ? 0 : 2) | (settings.releaseTime == nil ? 0 : 4) | (settings.usesTemporalMatte ? 8 : 0) | (frame.depthMap == nil ? 0 : 16), UInt32(frame.palette?.colors.count ?? 0)]
        header += [Float(frame.effectTime).bitPattern,frame.intensity.bitPattern,Float(frame.duration).bitPattern,Float(frame.frameRate).bitPattern]
        var vectors = [SIMD4<Float>](repeating: .zero, count: 40 + 16 + 4)
        for (index, definition) in settings.kind.descriptor.parameters.enumerated() {
            if let target=frame.target,definition.id=="targetX" || definition.id=="targetY" {
                vectors[index].x=Float(definition.id=="targetX" ? target.x : target.y);continue
            }
            switch settings.value(definition.id, at: frame.presentationTime) ?? definition.value {
            case .number(let value): vectors[index].x = Float(value)
            case .toggle(let value): vectors[index].x = value ? 1 : 0
            case .choice(let value): if case .picker(let choices, _) = definition.kind { vectors[index].x = Float(choices.firstIndex(of: value) ?? 0) }
            case .color(let value): let c = EffectColorMath.linear(value); vectors[index] = SIMD4(Float(c.x),Float(c.y),Float(c.z),1)
            case .media: break
            }
        }
        if let size=geometrySize {vectors[38]=SIMD4(Float(size.width),Float(size.height),0,0)}
        if let release=settings.releaseTime { vectors[39].x=Float(max(0,release-settings.start+(settings.phaseOffset ?? 0))) }
        let palette = frame.palette ?? EffectPalette(colors: [], thresholds: [])
        for (index, color) in palette.colors.prefix(16).enumerated() { let c=EffectColorMath.lab(EffectColorMath.linear(color)); vectors[40+index]=SIMD4(Float(c.x),Float(c.y),Float(c.z),1) }
        for (index, threshold) in palette.thresholds.prefix(15).enumerated() { vectors[56+index/4][index%4]=Float(threshold) }
        var data = header.withUnsafeBytes { Data($0) }; vectors.withUnsafeBytes { data.append(contentsOf: $0) }; return data
    }
    func blur(_ input: MTLTexture, sigma: Double, size: (Int,Int)? = nil, horizontalOnly: Bool = false, commandBuffer: MTLCommandBuffer) -> MTLTexture {
        let requestedWidth = size?.0 ?? input.width, requestedHeight = size?.1 ?? input.height
        let downscale = min(1, 14 / max(0.25,sigma*Double(requestedWidth)/Double(input.width)))
        let width=max(2,Int(Double(requestedWidth)*downscale)), height=max(2,Int(Double(requestedHeight)*downscale))
        let format=input.pixelFormat == .r8Unorm ? MTLPixelFormat.r16Float : input.pixelFormat
        var source=input
        if width<input.width || height<input.height {
            source=temporary(width,height,format:format)
            compute("ve_reduce",textures:[input,source],value:UInt32(0),output:source,commandBuffer:commandBuffer)
        }
        let a = temporary(width,height,format:format), b = temporary(width,height,format:format)
        let radius = Float(sigma * Double(width) / Double(input.width))
        gaussian(source,to:a,sigma:radius,horizontal:true,commandBuffer:commandBuffer)
        gaussian(a,to:b,sigma:radius,horizontal:horizontalOnly,commandBuffer:commandBuffer)
        return b
    }
    private func gaussian(_ source:MTLTexture,to output:MTLTexture,sigma:Float,horizontal:Bool,commandBuffer:MTLCommandBuffer) {
        let sigma=max(0.25,sigma)
        var weights=blurWeights[sigma]
        if weights == nil {
            let radius=min(48,Int(ceil(sigma*3)))
            let raw=(0...radius).map { exp(-Float($0*$0)/(2*sigma*sigma)) }
            let total=raw[0]+2*raw.dropFirst().reduce(0,+)
            var values=[SIMD4<Float>](repeating:.zero,count:25)
            values[0]=SIMD4(raw[0]/total,Float((radius+1)/2),0,0)
            for i in stride(from:1,through:radius,by:2) {
                let a=raw[i],b=i+1<=radius ? raw[i+1] : 0
                values[(i+1)/2]=SIMD4(Float(i)+b/(a+b),(a+b)/total,0,0)
            }
            weights=values
            if blurWeights.count>256 { blurWeights.removeAll(keepingCapacity:true) }
            blurWeights[sigma]=values
        }
        var values=weights!;values[0].z=horizontal ? 1 : 0;values[0].w=horizontal ? 0 : 1
        computeData("ve_blur",textures:[source,output],data:values.withUnsafeBytes { Data($0) },output:output,commandBuffer:commandBuffer)
    }
    private func morph(_ input: MTLTexture, radius: Double, size: (Int,Int), commandBuffer: MTLCommandBuffer) -> MTLTexture {
        let a=temporary(size.0,size.1,format:.r16Float),b=temporary(size.0,size.1,format:.r16Float)
        compute("ve_morphology",textures:[input,a],value:SIMD4(Float(radius),1,0,0),output:a,commandBuffer:commandBuffer)
        compute("ve_morphology",textures:[a,b],value:SIMD4(Float(radius),0,1,0),output:b,commandBuffer:commandBuffer)
        return b
    }
    private func backgroundEstimate(_ input: MTLTexture, mask: MTLTexture, fill: Bool, commandBuffer: MTLCommandBuffer) -> MTLTexture {
        let w=max(2,input.width/4),h=max(2,input.height/4),weighted=temporary(w,h)
        compute("ve_bgWeight",textures:[input,mask,weighted],value:UInt32(0),output:weighted,commandBuffer:commandBuffer)
        let local=blur(weighted,sigma:4*Double(min(input.width,input.height))/1080,commandBuffer:commandBuffer)
        if !fill {
            let result=temporary(w,h)
            compute("ve_bgNormalize",textures:[local,input,result],value:UInt32(0),output:result,commandBuffer:commandBuffer)
            return result
        }
        var pyramid=[local],last=local
        while last.width>2 || last.height>2 {
            last=blur(last,sigma:2,size:(max(2,last.width/2),max(2,last.height/2)),commandBuffer:commandBuffer);pyramid.append(last)
        }
        var fallback=input
        for level in pyramid.reversed() {
            let result=temporary(level.width,level.height)
            compute("ve_bgNormalize",textures:[level,fallback,result],value:UInt32(0),output:result,commandBuffer:commandBuffer);fallback=result
        }
        return fallback
    }
    private func average(_ input:MTLTexture,commandBuffer:MTLCommandBuffer)->MTLTexture {
        var image=input
        while image.width>1 || image.height>1 {
            let next=temporary(max(1,(image.width+3)/4),max(1,(image.height+3)/4))
            compute("ve_reduce",textures:[image,next],value:UInt32(0),output:next,commandBuffer:commandBuffer)
            image=next
        }
        return image
    }
    // The source transform includes orientation, crop, mirror and stabilisation.
    // Preserve scalar disparity through placement; never use CI colour conversion.
    func placeDepth(_ input:MTLTexture,source:CGSize,canvas:CGSize,transform:CGAffineTransform,range:ClosedRange<Float>,reusing:MTLTexture?=nil) throws -> MTLTexture {
        let scale=min(1,512/max(canvas.width,canvas.height))
        let width=max(1,Int(canvas.width*scale)),height=max(1,Int(canvas.height*scale))
        let result=try reusing.flatMap {$0.width==width && $0.height==height ? $0 : nil} ?? texture(width:width,height:height,format:.rg16Float)
        guard let command=queue.makeCommandBuffer() else {throw VideoEffectError.buffer}
        let inverse=transform.inverted()
        let values:[SIMD4<Float>]=[SIMD4(Float(inverse.a),Float(inverse.c),Float(inverse.tx),0),SIMD4(Float(inverse.b),Float(inverse.d),Float(inverse.ty),0),SIMD4(Float(source.width),Float(source.height),Float(canvas.width),Float(canvas.height)),SIMD4(range.lowerBound,range.upperBound-range.lowerBound,0,0)]
        computeData("ve_depthPlace",textures:[input,result],data:values.withUnsafeBytes {Data($0)},output:result,commandBuffer:command)
        command.commit();command.waitUntilCompleted();if let error=command.error {throw error}
        return result
    }
    private func depthFocus(_ depth:MTLTexture,frame:FrameContext,preferRecorded:Bool,commandBuffer:MTLCommandBuffer)->MTLTexture {
        if let cached=frame.depthFocusTexture {return cached}
        let focus=temporary(1,1,format:.rg16Float),target=frame.target ?? CGPoint(x:0.5,y:0.5)
        compute("ve_depthFocus",textures:[depth,focus],value:SIMD4<Float>(preferRecorded ? frame.depthFocus ?? -1 : -1,Float(target.x),Float(target.y),0),output:focus,commandBuffer:commandBuffer)
        return focus
    }
    func refinedMask(_ mask: MTLTexture, guide: MTLTexture, softness: Double, grow: Double = 0, quality:VideoEffectQuality = .full, person:Bool=false, commandBuffer: MTLCommandBuffer) -> MTLTexture {
        // Person boundaries must not acquire the wide feather used for glow or
        // coarse depth. Keep accurate masks detailed and bound coefficient blur.
        let maximum=person ? (quality == .lite ? 384.0 : 1024.0) : (quality == .lite ? 256.0 : 512.0)
        let scale = min(1,maximum / Double(max(guide.width,guide.height)))
        let width = max(2,Int(Double(guide.width)*scale)), height = max(2,Int(Double(guide.height)*scale))
        let source = mask
        let stats=temporary(width,height,format:.rg16Float),result=temporary(guide.width,guide.height,format:.r16Float)
        compute("ve_guidedStats",textures:[guide,source,stats],value:UInt32(max(1,Int((2+6*softness)*Double(min(guide.width,guide.height))/1080*scale))),output:stats,commandBuffer:commandBuffer)
        let smooth=blur(stats,sigma:person ? 0.25+0.75*softness : 1+softness,commandBuffer:commandBuffer)
        compute("ve_guidedApply",textures:[guide,smooth,result],value:UInt32(0),output:result,commandBuffer:commandBuffer)
        var refined=result
        if person {
            refined=temporary(guide.width,guide.height,format:.r16Float)
            // Remove low-confidence skirts without moving the 50% contour.
            let black=Float(0.02+0.05*(1-softness)),white=1-black
            compute("ve_personCoverage",textures:[result,refined],value:SIMD2<Float>(black,white),output:refined,commandBuffer:commandBuffer)
        }
        if grow != 0 { return morph(refined,radius:grow*Double(min(guide.width,guide.height))/1080,size:(guide.width,guide.height),commandBuffer:commandBuffer) }
        return refined
    }
    private func finishMatte(_ raw:MTLTexture,input:MTLTexture,settings:VideoEffectSettings,frame:FrameContext,commandBuffer:MTLCommandBuffer)->MTLTexture {
        var guide:MTLTexture?
        var capturedIndex:Int?
        if let key=frame.matteCapture {
            do {
                let stored=try VideoEffectMatteCache.shared.allocate(renderer:self,width:raw.width,height:raw.height)
                stored.retain(until:commandBuffer)
                compute("ve_reduce",textures:[raw,stored.matte],value:UInt32(0),output:stored.matte,commandBuffer:commandBuffer)
                compute("ve_matteGuide",textures:[input,stored.guide],value:UInt32(0),output:stored.guide,commandBuffer:commandBuffer)
                capturedIndex=matteCaptures.count
                matteCaptures.append((settings.id,key,stored,nil,frame.mattePublishCapture));guide=stored.guide
            } catch {allocationError=error;return raw}
        }
        if frame.matteOnly {return raw}
        guard let history=frame.matteHistory else {allocationError=VideoEffectError.unavailableMatteHistory;return raw}
        guard !history.isEmpty else {return raw}
        guard history.allSatisfy({(frame.resampleMatteHistory || $0.matte.width==raw.width && $0.matte.height==raw.height) && $0.matte.device.registryID==device.registryID}) else {allocationError=VideoEffectError.unavailableMatteHistory;return raw}
        var cutReadback:MTLBuffer?
        if frame.matteRecordCut,let capturedIndex {
            // render() waits for completion and reads each decision before the
            // next encode. Reuse one tiny buffer per simultaneous effect.
            while matteCutBuffers.count<=capturedIndex {
                guard let buffer=device.makeBuffer(length:256,options:.storageModeShared) else {allocationError=VideoEffectError.buffer;return raw}
                matteCutBuffers.append(buffer)
            }
            let buffer=matteCutBuffers[capturedIndex]
            cutReadback=buffer;matteCaptures[capturedIndex].cut=buffer
        }
        return temporalMatte(current:raw,guide:guide ?? matteGuide(input,commandBuffer:commandBuffer),history:history.map {($0.matte,$0.guide)},kind:settings.kind == .chromaKey ? .key : .isolation,detectCuts:frame.matteDetectCuts,detectCurrentCut:frame.matteDetectCurrentCut,cutReadback:cutReadback,commandBuffer:commandBuffer)
    }
    @discardableResult func encode(_ settings: VideoEffectSettings, input: MTLTexture, output: MTLTexture, frame: FrameContext, commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        let width=input.width,height=input.height,scale=Double(min(width,height))/1080
        var renderFrame=frame
        var matchSubject=input,matchBackground=input,noise=input
        let grainSize:Double?
        switch settings.kind {
        case .noir: grainSize=settings.toggle("grain",at:frame.presentationTime) ? 1 : nil
        case .freezeFrame: grainSize=settings.choice("style",at:frame.presentationTime)=="Print" ? 1.5 : nil
        case .sixteenMM: grainSize=["Fine":1.0,"Medium":1.5,"Coarse":2.2][settings.choice("grainSize",at:frame.presentationTime)] ?? 1.5
        case .superEight: grainSize=2.2
        default:grainSize=nil
        }
        if let grainSize {
            noise=temporary(Int(ceil(Double(width)/(scale*grainSize)))+1,Int(ceil(Double(height)/(scale*grainSize)))+1)
            compute("ve_grainNoise",textures:[noise],value:UInt32(truncatingIfNeeded:frame.frameIndex),output:noise,commandBuffer:commandBuffer)
        }
        var aux=input,background=frame.background ?? input,mask=frame.personMask ?? input,extra=input,wrap=frame.background ?? input
        switch settings.kind {
        case .quantization:
            if settings.number("smoothing",at:frame.presentationTime)>0 {
                let factor=(frame.quality == .lite ? 0.5 : 1)/max(1,scale),w=max(2,Int(Double(width)*factor)),h=max(2,Int(Double(height)*factor))
                let intermediate=temporary(w,h);aux=temporary(w,h)
                let sigma=Float((1+4*settings.number("smoothing",at:frame.presentationTime))*scale*factor)
                compute("ve_bilateral",textures:[input,intermediate],value:SIMD4(sigma,1,0,0),output:intermediate,commandBuffer:commandBuffer)
                compute("ve_bilateral",textures:[intermediate,aux],value:SIMD4(sigma,0,1,0),output:aux,commandBuffer:commandBuffer)
            }
            if settings.toggle("faceDetail",at:frame.presentationTime), frame.personMask != nil, settings.number("colors",at:frame.presentationTime)<=4 {
                background=blur(input,sigma:8*scale,size:(max(2,width/2),max(2,height/2)),commandBuffer:commandBuffer)
            }
        case .sixteenMM: if settings.number("softness",at:frame.presentationTime)>0 {
            let size=frame.quality == .lite ? (max(2,width/2),max(2,height/2)) : nil
            aux=blur(input,sigma:1.5*scale,size:size,commandBuffer:commandBuffer)
        }
        case .superEight:
            let size=frame.quality == .lite ? (max(2,width/2),max(2,height/2)) : nil
            aux=blur(input,sigma:2*scale,size:size,commandBuffer:commandBuffer)
        case .halation, .widescreen:
            let small=temporary(max(2,width/4),max(2,height/4));let wide=settings.kind == .widescreen
            let detail=frame.quality == .lite ? 0.5 : 1.0
            compute("ve_highlights",textures:[input,small],value:SIMD4<Float>(wide ? 0.9 : 0.75,wide ? 0.05 : 0.1,0,0),output:small,commandBuffer:commandBuffer)
            if wide { aux=blur(small,sigma:Double(width)/24/4*detail,horizontalOnly:true,commandBuffer:commandBuffer);if settings.choice("bars",at:frame.presentationTime)=="Blur fill" { background=blur(input,sigma:12*scale,size:(max(2,width/4),max(2,height/4)),commandBuffer:commandBuffer) } }
            if wide,settings.toggle("ovalBokeh",at:frame.presentationTime),let depth=frame.depthMap {
                wrap=depthFocus(depth,frame:frame,preferRecorded:true,commandBuffer:commandBuffer)
                let amount=temporary(depth.width,depth.height,format:.r16Float)
                compute("ve_bokehAmount",textures:[depth,wrap,amount],value:UInt32(0),output:amount,commandBuffer:commandBuffer)
                mask=refinedMask(amount,guide:input,softness:0.3,commandBuffer:commandBuffer);matchSubject=depth
                extra=temporary(max(2,width/2),max(2,height/2))
                compute("ve_depthBokeh",textures:[input,depth,wrap,extra],value:Float(12*scale),output:extra,commandBuffer:commandBuffer)
            }
            if !wide { aux=blur(small,sigma:Double(width)*0.01/4*detail,commandBuffer:commandBuffer);background=blur(small,sigma:Double(width)*0.006/4*detail,commandBuffer:commandBuffer);extra=blur(small,sigma:Double(width)*0.04/4*detail,commandBuffer:commandBuffer) }
        case .colorIsolation:
            if settings.choice("mode",at:frame.presentationTime)=="The subject",let person=frame.personMask { mask=refinedMask(person,guide:input,softness:settings.number("softness",at:frame.presentationTime),quality:frame.quality,person:true,commandBuffer:commandBuffer) }
            if settings.usesTemporalMatte {
                if settings.choice("mode",at:frame.presentationTime) != "The subject" {
                    mask=temporary(width,height,format:.r16Float)
                    computeData("ve_isolationAlpha",textures:[input,mask],data:uniforms(settings,frame:frame),output:mask,commandBuffer:commandBuffer)
                }
                mask=finishMatte(mask,input:input,settings:settings,frame:frame,commandBuffer:commandBuffer)
            }
        case .dollyZoom:
            if let depth=frame.depthMap {
                let focus=depthFocus(depth,frame:frame,preferRecorded:false,commandBuffer:commandBuffer)
                mask=temporary(depth.width,depth.height,format:.r16Float)
                compute("ve_depthMask",textures:[depth,focus,mask],value:UInt32(0),output:mask,commandBuffer:commandBuffer)
                mask=refinedMask(mask,guide:input,softness:0.3,quality:frame.quality,commandBuffer:commandBuffer)
            } else if let person=frame.personMask { mask=refinedMask(person,guide:input,softness:0.3,quality:frame.quality,person:true,commandBuffer:commandBuffer) }
            aux=backgroundEstimate(input,mask:mask,fill:true,commandBuffer:commandBuffer)
        case .autoBackground:
            if let person=frame.personMask { mask=refinedMask(person,guide:input,softness:settings.number("softness",at:frame.presentationTime),grow:settings.number("grow",at:frame.presentationTime),quality:frame.quality,person:true,commandBuffer:commandBuffer) }
            aux=backgroundEstimate(input,mask:mask,fill:false,commandBuffer:commandBuffer)
            if settings.number("wrap",at:frame.presentationTime)>0,(settings.choice("background",at:frame.presentationTime) != "Solid" || frame.background == nil) {
                wrap=blur(background,sigma:Double(width)*0.02,size:(max(2,width/4),max(2,height/4)),commandBuffer:commandBuffer)
            }
        case .chromaKey:
            aux=frame.cleanPlate ?? input
            if frame.cleanPlate == nil,settings.toggle("autoScreen",at:frame.presentationTime) {
                aux=temporary(1,1)
                computeData("ve_screenReference",textures:[input,aux],data:uniforms(settings,frame:frame),output:aux,commandBuffer:commandBuffer)
                renderFrame.cleanPlate=aux
            }
            var dilated=input,eroded=input
            if settings.toggle("personHint",at:frame.presentationTime),let person=frame.personMask {
                let reduction=frame.quality == .lite ? 8 : 4
                let w=max(2,width/reduction),h=max(2,height/reduction)
                dilated=morph(person,radius:Double(h)*0.04,size:(w,h),commandBuffer:commandBuffer)
                eroded=morph(person,radius:-Double(h)*0.03,size:(w,h),commandBuffer:commandBuffer)
            }
            let alpha=temporary(width,height,format:.r16Float)
            computeData("ve_keyAlpha",textures:[input,aux,dilated,alpha,eroded],data:uniforms(settings,frame:renderFrame),output:alpha,commandBuffer:commandBuffer)
            var matte=alpha
            if settings.number("wrap",at:frame.presentationTime)>0,(settings.choice("background",at:frame.presentationTime) != "Solid" || frame.background == nil) {
                wrap=blur(background,sigma:Double(width)*0.02,size:(max(2,width/4),max(2,height/4)),commandBuffer:commandBuffer)
            }
            let grow=settings.number("grow",at:frame.presentationTime)*scale,softness=settings.number("softness",at:frame.presentationTime)
            if grow != 0 { matte=morph(matte,radius:grow,size:(width,height),commandBuffer:commandBuffer) }
            if settings.usesTemporalMatte {
                mask=softness>0 ? refinedMask(matte,guide:input,softness:softness,quality:frame.quality,commandBuffer:commandBuffer) : matte
                mask=finishMatte(mask,input:input,settings:settings,frame:frame,commandBuffer:commandBuffer)
            } else {mask=softness > 0 ? blur(matte,sigma:softness*1.5*scale,commandBuffer:commandBuffer) : matte}
        case .stepPrinting: aux=frame.temporalImage ?? input
        default: break
        }
        if frame.matteOnly {return nil}
        if [.chromaKey,.autoBackground].contains(settings.kind),settings.toggle("matchColor",at:frame.presentationTime) {
            let weighted=temporary(64,36)
            compute("ve_subjectWeight",textures:[input,mask,weighted],value:UInt32(0),output:weighted,commandBuffer:commandBuffer)
            matchSubject=average(weighted,commandBuffer:commandBuffer)
            matchBackground=average(background,commandBuffer:commandBuffer)
        }
        effectPass(settings,input:input,aux:aux,mask:mask,background:background,extra:extra,wrap:wrap,matchSubject:matchSubject,matchBackground:matchBackground,noise:noise,output:output,frame:renderFrame,commandBuffer:commandBuffer)
        return [.chromaKey,.autoBackground].contains(settings.kind) && settings.choice("background",at:frame.presentationTime) != "Blur original" && settings.choice("view",at:frame.presentationTime)=="Result" ? mask : nil
    }
    // Evaluate a temporal sum before releasing its input leases. Streaming the
    // accumulation bounds memory to the previous sum and next processed frame,
    // even for six-frame 4K blocks on both sides of an overlap transition.
    func materialize(_ image:CIImage,lease:(VideoEffectFrameLease)->Void) throws -> CIImage {
        let bounds=image.extent,width=Int(bounds.width),height=Int(bounds.height)
        let output=try outputPool.take(width:width,height:height,format:.rgba16Float) ?? texture(width:width,height:height)
        guard let command=queue.makeCommandBuffer() else {throw VideoEffectError.buffer}
        context.render(Self.textureImage(image),to:output,commandBuffer:command,bounds:CGRect(origin:.zero,size:bounds.size),colorSpace:space)
        command.commit();command.waitUntilCompleted()
        if let error=command.error {throw error}
        guard let stored=CIImage(mtlTexture:output,options:[.colorSpace:space]) else {throw VideoEffectError.buffer}
        lease(VideoEffectFrameLease(output,pool:outputPool))
        return Self.textureImage(stored).transformed(by:CGAffineTransform(translationX:bounds.minX,y:bounds.minY))
    }
    func render(_ image: CIImage, effects: [VideoEffectSettings], sourceTime: Double, presentationTime: Double? = nil, hdr: Bool = false,
                frameRate: Double = 30, mapInputOnly:Bool = false, frameContext: FrameContext? = nil, contexts: [UUID: FrameContext] = [:], lease: ((VideoEffectFrameLease)->Void)? = nil,captureMatte:((UUID,VideoEffectMatteCache.Frame)->Void)?=nil) throws -> CIImage {
        let enabled = VideoEffectSettings.ordered(effects).filter { effect in
            guard effect.enabled, sourceTime >= effect.start, sourceTime < effect.end else { return false }
            if effect.kind == .negativeStrobe {
                let hold = contexts[effect.id]?.holdTime ?? frameContext?.holdTime
                return effect.strobeShowsNegative(at: sourceTime, fps: frameRate, holdTime: hold)
            }
            if effect.kind == .rgbOffset {
                return RGBChannel.allCases.contains { effect.number($0.x, at: sourceTime) != 0 || effect.number($0.y, at: sourceTime) != 0 }
            }
            return true
        }
        let active=enabled.filter { !$0.kind.descriptor.supportsIntensity || $0.number("intensity",at:sourceTime)>0 }
        // Intensity mixes within the defined SDR working space. Reaching zero
        // must not suddenly remove the HDR shoulder. Disabling/bypassing the
        // whole look still returns the untouched HDR source.
        guard !active.isEmpty || mapInputOnly || hdr && !enabled.isEmpty else { return image }
        // A mirrored sample keeps its source radiometry, including extended HDR highlights.
        // Palette analysis explicitly asks for the display-referred working space.
        let preserveColor = !mapInputOnly && enabled.allSatisfy { $0.kind == .kaleidoscope }
        if preserveColor && active.isEmpty { return image }
        let width=Int(image.extent.width),height=Int(image.extent.height)
        guard width>0,height>0,let commandBuffer=queue.makeCommandBuffer() else { throw VideoEffectError.buffer }
        let began=ProcessInfo.processInfo.systemUptime
        matteCaptures.removeAll(keepingCapacity:true)
        defer {matteCaptures.removeAll(keepingCapacity:true)}
        beginEncoding()
        let input=temporary(width,height),mapped=temporary(width,height),other=temporary(width,height)
        // Fuse the SDR clamp with CI's camera conversion. The HDR shoulder
        // remains in Metal; no extra full-resolution read/write for SDR.
        let prepared=(hdr || preserveColor) ? image : image.applyingFilter("CIColorClamp",parameters:["inputMinComponents":CIVector(x:0,y:0,z:0,w:0),"inputMaxComponents":CIVector(x:1,y:1,z:1,w:1)])
        context.render(Self.textureImage(prepared),to:input,commandBuffer:commandBuffer,bounds:CGRect(origin:.zero,size:image.extent.size),colorSpace:space)
        let toneMap = hdr && !preserveColor
        if toneMap { compute("ve_toneMap",textures:[input,mapped],value:UInt32(1),output:mapped,commandBuffer:commandBuffer) }
        let baseCounts = scratchCounts
        var current=toneMap ? mapped : input
        // Sequence sampling is handled by the timeline. Its pixel decorations
        // precede Frame so a held push-in or weave never shifts the clean bars.
        let stages:[EffectFamily]=[.key,.camera,.time,.color,.quantization,.texture,.frame]
        let pixelOrder=stages.flatMap { stage in active.filter { $0.kind.descriptor.family == stage } }
        var geometry:[(data:Data,focus:MTLTexture?)]=[],warped:[String:MTLTexture]=[:],mapLeases:[MTLTexture]=[]
        var targetTransform=CGAffineTransform.identity
        defer {for texture in mapLeases {outputPool.recycle(texture)}}
        func warpMap(_ source:MTLTexture?,depth:Bool=false) throws -> MTLTexture? {
            guard let source,!geometry.isEmpty else {return source}
            var current=source
            for (index,geometry) in geometry.enumerated() {
                // Keyer and Dolly entries only change background depth;
                // their foreground person masks retain their coordinates.
                if !depth && geometry.focus != nil {continue}
                let key="\(ObjectIdentifier(source))-\(index)-\(depth)"
                if let cached=warped[key] {current=cached;continue}
                let format=source.pixelFormat == .r8Unorm ? MTLPixelFormat.r16Float : source.pixelFormat
                let scale:Double=max(source.width,source.height)>2048 ? 0.5 : 1
                let w=max(1,Int(Double(source.width)*scale)),h=max(1,Int(Double(source.height)*scale))
                let result=try outputPool.take(width:w,height:h,format:format) ?? texture(width:w,height:h,format:format)
                mapLeases.append(result)
                var data=geometry.data
                if depth {var flag:Float=1;withUnsafeBytes(of:&flag){data.replaceSubrange((32+38*16+8)..<(32+38*16+12),with:$0)}}
                computeData("ve_geometryMap",textures:[current,result,geometry.focus ?? current],data:data,output:result,commandBuffer:commandBuffer)
                warped[key]=result;current=result
            }
            return current
        }
        for settings in pixelOrder {
            scratchCounts=baseCounts // Reuse auxiliary textures between ordered GPU stages.
            let output = current === mapped ? other : mapped
            var frame=contexts[settings.id] ?? frameContext ?? FrameContext(presentationTime:sourceTime,frameIndex:VideoEffectTime.frameIndex(presentationTime ?? sourceTime,fps:frameRate),frameRate:frameRate)
            if settings.kind == .dollyZoom || settings.kind == .autoBackground || settings.kind == .chromaKey && settings.toggle("personHint",at:sourceTime) || settings.kind == .colorIsolation && settings.choice("mode",at:sourceTime)=="The subject" || settings.kind == .quantization && settings.toggle("faceDetail",at:sourceTime) && settings.number("colors",at:sourceTime)<=4 {frame.personMask=try warpMap(frame.personMask)}
            if settings.kind == .dollyZoom || settings.kind == .widescreen && settings.toggle("ovalBokeh",at:sourceTime) {frame.depthMap=try warpMap(frame.depthMap,depth:true)}
            if settings.kind == .dollyZoom || settings.kind == .crashZoom {
                let target=frame.target ?? CGPoint(x:settings.number("targetX",at:sourceTime),y:settings.number("targetY",at:sourceTime))
                frame.target=target.applying(targetTransform)
            }
            if (settings.kind == .autoBackground || settings.kind == .dollyZoom && frame.depthMap == nil || settings.kind == .colorIsolation && settings.choice("mode",at:sourceTime) == "The subject") && frame.personMask == nil { throw VideoEffectError.unavailableMask }
            frame.frameRate = frameRate
            frame.frameIndex=VideoEffectTime.frameIndex(presentationTime ?? sourceTime,fps:frameRate)
            frame.presentationTime=sourceTime;frame.effectTime=(settings.kind == .freezeFrame ? frame.holdTime : nil) ?? max(0,sourceTime-settings.start+(settings.phaseOffset ?? 0));frame.duration=settings.end-settings.start
            frame.intensity=settings.kind.descriptor.supportsIntensity ? Float(settings.number("intensity",at:sourceTime)) : 1
            if settings.kind == .dollyZoom,let depth=frame.depthMap {
                let focus=try outputPool.take(width:1,height:1,format:.rg16Float) ?? texture(width:1,height:1,format:.rg16Float)
                mapLeases.append(focus)
                let target=frame.target ?? CGPoint(x:0.5,y:0.5)
                compute("ve_depthFocus",textures:[depth,focus],value:SIMD4<Float>(-1,Float(target.x),Float(target.y),0),output:focus,commandBuffer:commandBuffer)
                frame.depthFocusTexture=focus
            }
            let keyMatte=encode(settings,input:current,output:output,frame:frame,commandBuffer:commandBuffer)
            if !frame.matteOnly {
                current=output
                if let keyMatte,pixelOrder.contains(where:{$0.kind == .dollyZoom || $0.kind == .widescreen && $0.toggle("ovalBokeh",at:sourceTime)}),contexts.values.contains(where:{$0.depthMap != nil}) || frameContext?.depthMap != nil {
                    let factor=min(1,512.0/Double(max(keyMatte.width,keyMatte.height))),w=max(1,Int(Double(keyMatte.width)*factor)),h=max(1,Int(Double(keyMatte.height)*factor))
                    let matte=try outputPool.take(width:w,height:h,format:.r16Float) ?? texture(width:w,height:h,format:.r16Float)
                    mapLeases.append(matte)
                    compute("ve_reduce",textures:[keyMatte,matte],value:UInt32(0),output:matte,commandBuffer:commandBuffer)
                    geometry.append((uniforms(settings,frame:frame,geometrySize:image.extent.size),matte))
                }
                if [.kaleidoscope,.crashZoom,.freezeFrame,.undercranking,.sixteenMM,.superEight].contains(settings.kind) || settings.kind == .dollyZoom && frame.depthMap != nil {
                    geometry.append((uniforms(settings,frame:frame,geometrySize:image.extent.size),frame.depthFocusTexture))
                    if settings.kind == .crashZoom {
                        let targets=frame.target.map {[settings.id:$0]} ?? [:]
                        targetTransform=targetTransform.concatenating(VideoEffectGeometry.transform([settings],time:sourceTime,size:image.extent.size,targets:targets))
                    }
                }
            }
        }
        if let allocationError { throw allocationError }
        let committed=ProcessInfo.processInfo.systemUptime
        encodingSeconds=committed-began
        commandBuffer.commit();commandBuffer.waitUntilCompleted()
        completionSeconds=ProcessInfo.processInfo.systemUptime-committed
        if let error=commandBuffer.error { throw error }
        for (id,key,stored,cut,publish) in matteCaptures {
            stored.cutBefore=cut.map {$0.contents().load(as:UInt16.self) != 0} ?? false
            if publish {try VideoEffectMatteCache.shared.publish(stored,for:key,completed:commandBuffer)}
            captureMatte?(id,stored)
        }
        gpuSeconds=max(0,commandBuffer.gpuEndTime-commandBuffer.gpuStartTime)
        resolveCounters()
        // Owned results keep the old lifetime semantics. Main render paths
        // hold explicit leases through the compositor/display GPU completion.
        for key in Array(scratch.keys) {
            if let index=scratch[key]!.firstIndex(where:{$0 === current}) { scratch[key]![index]=nil; break }
        }
        if let lease { lease(VideoEffectFrameLease(current,pool:outputPool)) }
        var imageOptions: [CIImageOption: Any] = [.colorSpace: space]
        if preserveColor, #available(iOS 18, macOS 15, *), image.contentHeadroom > 0 {
            imageOptions[.contentHeadroom] = image.contentHeadroom
        }
        guard let result=CIImage(mtlTexture:current,options:imageOptions) else { throw VideoEffectError.buffer }
        return Self.textureImage(result).transformed(by:CGAffineTransform(translationX:image.extent.minX,y:image.extent.minY))
    }
}

// Confined to the segmentation queue. Two small history textures; completed
// masks come from a CV pool and remain immutable while preview/analysis use them.
final class VideoEffectMaskSmoother {
    private let renderer:MetalEffectRenderer
    private var cache:CVMetalTextureCache?
    private var pool:CVPixelBufferPool?
    private var states:[MTLTexture]=[]
    private var guide:MTLTexture?
    private var cut:MTLTexture?
    private var previousTime:Double?
    private var previousGeometry=""
    private var current=0
    init(renderer: MetalEffectRenderer? = nil) throws {
        self.renderer = try renderer ?? MetalEffectRenderer()
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault,nil,self.renderer.device,nil,&cache)==kCVReturnSuccess else {throw VideoEffectError.buffer}
    }
    func reset() { previousTime = nil }
    func push(_ mask:CVPixelBuffer,image:CIImage,time:Double,geometry:String,motionGate:Bool=false) throws -> CVPixelBuffer {
        let width=CVPixelBufferGetWidth(mask),height=CVPixelBufferGetHeight(mask)
        guard (1...1024).contains(width),(1...1024).contains(height),CVPixelBufferGetPixelFormatType(mask)==kCVPixelFormatType_OneComponent8,time.isFinite else {throw VideoEffectError.unavailableMask}
        if guide?.width != width || guide?.height != height {
            guide=try renderer.texture(width:width,height:height)
            states=try (0..<2).map {_ in try renderer.texture(width:width,height:height,format:.rg16Float)}
            cut=try renderer.texture(width:1,height:1,format:.r16Float)
            let attributes:[String:Any]=[kCVPixelBufferWidthKey as String:width,kCVPixelBufferHeightKey as String:height,
                kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_OneComponent8,kCVPixelBufferMetalCompatibilityKey as String:true,
                kCVPixelBufferIOSurfacePropertiesKey as String:[:]]
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault,nil,attributes as CFDictionary,&pool)==kCVReturnSuccess else {throw VideoEffectError.buffer}
            previousTime=nil;current=0
        }
        guard let pool,let cache,let guide,let cut,let command=renderer.queue.makeCommandBuffer() else {throw VideoEffectError.buffer}
        var output:CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault,pool,&output)==kCVReturnSuccess,let output else {throw VideoEffectError.buffer}
        func wrapped(_ pixel:CVPixelBuffer) throws -> CVMetalTexture {
            var result:CVMetalTexture?
            guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,cache,pixel,nil,.r8Unorm,width,height,0,&result)==kCVReturnSuccess,let result else {throw VideoEffectError.buffer}
            return result
        }
        let inputWrapper=try wrapped(mask),outputWrapper=try wrapped(output)
        guard let input=CVMetalTextureGetTexture(inputWrapper),let result=CVMetalTextureGetTexture(outputWrapper) else {throw VideoEffectError.buffer}
        let delta=previousTime.map {time-$0} ?? 0
        let reset=previousTime==nil || geometry != previousGeometry || delta<=0 || delta>0.25
        let weight=Float(1-pow(0.7,max(0,delta)*30)) // EMA alpha 0.3 at 30 Hz.
        let reduced=image.transformed(by:CGAffineTransform(translationX:-image.extent.minX,y:-image.extent.minY))
            .transformed(by:CGAffineTransform(scaleX:Double(width)/image.extent.width,y:Double(height)/image.extent.height))
        renderer.context.render(MetalEffectRenderer.textureImage(reduced),to:guide,commandBuffer:command,bounds:CGRect(x:0,y:0,width:width,height:height),colorSpace:renderer.space)
        renderer.encodeMaskTemporal(mask:input,guide:guide,previous:states[current],state:states[1-current],output:result,cut:cut,weight:weight,reset:reset,motionGate:motionGate,commandBuffer:command)
        command.commit();command.waitUntilCompleted()
        if let error=command.error {throw error}
        withExtendedLifetime((inputWrapper,outputWrapper)) {}
        CVMetalTextureCacheFlush(cache,0)
        current=1-current;previousTime=time;previousGeometry=geometry
        return output
    }
}

// Process-wide matte storage. Only completed GPU results enter the lookup map;
// an evicted frame remains accounted for while any renderer still leases it.
// There is no lock across Metal allocation, encoding or completion waits.
final class VideoEffectMatteCache: @unchecked Sendable {
    static let shared=VideoEffectMatteCache()
    struct Key:Hashable {
        let device:UInt64
        let stream:String // Effective source/recipe/geometry/analysis identity.
        let time:Double   // Exact canonical producer time, not the seek position.
    }
    final class Frame {
        let matte:MTLTexture
        let guide:MTLTexture
        fileprivate(set) var cutBefore=false // Published only after GPU completion.
        fileprivate let reservation:Reservation
        fileprivate init(matte:MTLTexture,guide:MTLTexture,reservation:Reservation) {
            self.matte=matte;self.guide=guide;self.reservation=reservation
        }
        var allocatedBytes:Int {reservation.bytes}
        func retain(until command:MTLCommandBuffer) {
            command.addCompletedHandler { [self] _ in withExtendedLifetime(self) {} }
        }
    }
    fileprivate final class Reservation {
        weak var owner:VideoEffectMatteCache?
        private(set) var bytes:Int
        init(owner:VideoEffectMatteCache,bytes:Int) {self.owner=owner;self.bytes=bytes}
        func resize(_ size:Int)throws {
            guard let owner else {throw VideoEffectError.buffer}
            if size>bytes {try owner.acquire(size-bytes)}
            else if size<bytes {owner.release(bytes-size)}
            bytes=size
        }
        deinit {owner?.release(bytes)}
    }
    private struct Entry {let frame:Frame;var used:UInt64}
    private let lock=NSLock()
    private var entries:[Key:Entry]=[:]
    private var clock:UInt64=0
    private var allocated=0
    private var cachedBytes=0
    private let softLimit:Int,hardLimit:Int,entryLimit:Int
    init(softLimit:Int=256*1024*1024,hardLimit:Int=512*1024*1024,entryLimit:Int=1024) {
        self.softLimit=max(0,softLimit);self.hardLimit=max(softLimit,hardLimit);self.entryLimit=max(1,entryLimit)
    }
    var statistics:(allocatedBytes:Int,cachedBytes:Int,cachedFrames:Int) {
        lock.lock();defer {lock.unlock()};return (allocated,cachedBytes,entries.count)
    }
    func frame(for key:Key)->Frame? {
        lock.lock();defer {lock.unlock()}
        guard var value=entries[key] else {return nil}
        clock &+= 1;value.used=clock;entries[key]=value
        return value.frame
    }
    private func release(_ bytes:Int) {
        lock.lock();allocated-=bytes;assert(allocated>=0);lock.unlock()
    }
    private func acquire(_ bytes:Int)throws {
        guard bytes>=0,bytes<=hardLimit else {throw VideoEffectError.buffer}
        while true {
            // Keep a strong reference until after unlocking: dropping the last
            // map reference can release its reservation and reenter this lock.
            var retired:Entry?
            lock.lock()
            // In-flight/current allocations count only against the hard limit.
            // Charging them against the cache's soft limit would evict useful
            // history on every frame of a two-layer 4K transition.
            if allocated+bytes<=hardLimit {
                allocated+=bytes;lock.unlock();return
            }
            guard let oldest=entries.min(by:{$0.value.used<$1.value.used})?.key else {lock.unlock();throw VideoEffectError.buffer}
            retired=entries.removeValue(forKey:oldest);cachedBytes-=retired!.frame.allocatedBytes
            lock.unlock()
            withExtendedLifetime(retired) {}
            retired=nil
        }
    }
    func allocate(renderer:MetalEffectRenderer,width:Int,height:Int)throws->Frame {
        guard width>0,height>0,width<=16384,height<=16384 else {throw VideoEffectError.buffer}
        let gw=(width+3)/4,gh=(height+3)/4
        // Reserve before allocation, then account the driver's actual padded
        // allocation. The conservative estimate includes tile/page overhead.
        let estimate=(width*height+2*gw*gh)*5/4+131072
        try acquire(estimate)
        let reservation=Reservation(owner:self,bytes:estimate)
        let matte=try renderer.texture(width:width,height:height,format:.r8Unorm)
        let guide=try renderer.texture(width:gw,height:gh,format:.r16Float)
        try reservation.resize(max(width*height+2*gw*gh,matte.allocatedSize+guide.allocatedSize))
        return Frame(matte:matte,guide:guide,reservation:reservation)
    }
    func publish(_ frame:Frame,for key:Key,completed command:MTLCommandBuffer)throws {
        guard command.status == .completed,command.error == nil,
              frame.reservation.owner === self,key.device==frame.matte.device.registryID,key.time.isFinite else {throw VideoEffectError.buffer}
        var retired:[Entry]=[]
        lock.lock()
        if entries[key]==nil {
            clock &+= 1;entries[key]=Entry(frame:frame,used:clock);cachedBytes+=frame.allocatedBytes
            while entries.count>entryLimit || cachedBytes>softLimit {
                guard let oldest=entries.min(by:{$0.value.used<$1.value.used})?.key,let value=entries.removeValue(forKey:oldest) else {break}
                cachedBytes-=value.frame.allocatedBytes;retired.append(value)
            }
        }
        lock.unlock()
        withExtendedLifetime(retired) {}
        retired.removeAll()
    }
    func purge() {
        lock.lock();var retired=entries;entries.removeAll(keepingCapacity:false);cachedBytes=0;lock.unlock()
        retired.removeAll()
    }
}

// Confined to the live renderer queue. Only successful main renders advance
// these rings; palette sampling and frame tools borrow an immutable snapshot.
final class VideoEffectLiveMatteHistory {
    struct Snapshot {
        let time:Double
        let effects:[VideoEffectSettings]
        let history:[UUID:[VideoEffectMatteCache.Frame]]
        let stream:String
        func applying(to original:[UUID:FrameContext],device:UInt64,capture:Bool)->[UUID:FrameContext] {
            var contexts=original
            for effect in effects {
                var context=contexts[effect.id] ?? FrameContext(presentationTime:time,frameIndex:VideoEffectTime.frameIndex(time,fps:30))
                context.matteHistory=history[effect.id] ?? []
                context.resampleMatteHistory=true
                if capture {
                    context.matteCapture = .init(device:device,stream:stream+effect.id.uuidString,time:time)
                    context.matteRecordCut=true
                    context.mattePublishCapture=false
                }
                contexts[effect.id]=context
            }
            return contexts
        }
    }
    private struct Entry {let time:Double;let frame:VideoEffectMatteCache.Frame}
    private var rings:[UUID:[Entry]]=[:]
    private var stream=UUID().uuidString
    private var geometry=""
    private var queriedTime = -Double.infinity
    func reset() {rings.removeAll();stream=UUID().uuidString;geometry="";queriedTime = -.infinity}
    func snapshot(effects:[VideoEffectSettings],time:Double,geometry:String)->Snapshot {
        if self.geometry != geometry || time<queriedTime {reset();self.geometry=geometry}
        queriedTime=time
        let active=effects.filter {$0.usesTemporalMatte && $0.isActive(at:time)}
        let ids=Set(active.map(\.id));rings=rings.filter {ids.contains($0.key)}
        for effect in active {
            if let last=rings[effect.id]?.last,time-last.time>0.25 {rings[effect.id]=nil}
        }
        return peek(effects:effects,time:time,geometry:geometry)
    }
    func peek(effects:[VideoEffectSettings],time:Double,geometry:String)->Snapshot {
        let active=effects.filter {$0.usesTemporalMatte && $0.isActive(at:time)}
        let values=Dictionary(uniqueKeysWithValues:active.map {effect -> (UUID,[VideoEffectMatteCache.Frame]) in
            guard self.geometry==geometry,let ring=rings[effect.id],let last=ring.last,time>=last.time,time-last.time<=0.25 else {return (effect.id,[])}
            return (effect.id,ring.filter {$0.time<time && $0.time>=effect.start}.reversed().map(\.frame))
        })
        return Snapshot(time:time,effects:active,history:values,stream:stream)
    }
    // Prepare sidecar decisions without advancing the ring. Disk failures must
    // not make the next live frame depend on an unsaved accepted frame.
    func resetDecisions(_ frames:[UUID:VideoEffectMatteCache.Frame],snapshot:Snapshot)throws->[UUID:Bool] {
        guard snapshot.stream==stream,Set(frames.keys)==Set(snapshot.effects.map(\.id)) else {throw VideoEffectError.unavailableMatteHistory}
        return Dictionary(uniqueKeysWithValues:snapshot.effects.map {effect in
            (effect.id,(snapshot.history[effect.id]?.isEmpty ?? true) || frames[effect.id]!.cutBefore)
        })
    }
    @discardableResult
    func accept(_ frames:[UUID:VideoEffectMatteCache.Frame],snapshot:Snapshot)throws->[UUID:Bool] {
        let resets=try resetDecisions(frames,snapshot:snapshot)
        for effect in snapshot.effects {
            let frame=frames[effect.id]!
            let reset=resets[effect.id]!
            if reset {rings[effect.id]=[]}
            let capacity=(effect.kind == .chromaKey ? VideoEffectMatteKind.key : .isolation).capacity-1
            var values=(rings[effect.id] ?? []).filter {$0.time<snapshot.time}
            values.append(Entry(time:snapshot.time,frame:frame))
            rings[effect.id]=Array(values.suffix(capacity))
        }
        return resets
    }
}
