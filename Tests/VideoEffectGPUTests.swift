import Foundation
import CoreImage
import Metal
import CoreVideo
import simd

@main struct VideoEffectGPUTests {
    static func main() throws {
        func check(_ value: @autoclosure () -> Bool, _ message: String) throws { if !value() { throw NSError(domain:"VideoEffectGPU",code:1,userInfo:[NSLocalizedDescriptionKey:message]) } }
        let renderer=try MetalEffectRenderer(),width=320,height=180,space=CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
        let bounds=CGRect(x:0,y:0,width:width,height:height)
        var data=[Float]();data.reserveCapacity(width*height*4)
        for y in 0..<height { for x in 0..<width { data += [Float(x)/Float(width-1),Float(y)/Float(height-1),0.15,1] } }
        let input=CIImage(bitmapData:data.withUnsafeBytes {Data($0)},bytesPerRow:width*16,size:bounds.size,format:.RGBAf,colorSpace:space)
        func pixels(_ image:CIImage)->[Float] {
            var result=[Float](repeating:0,count:width*height*4)
            renderer.context.render(image,toBitmap:&result,rowBytes:width*16,bounds:bounds,format:.RGBAf,colorSpace:space);return result
        }
        let source=pixels(input)
        // Primary correction acceptance: identity, neutral grays, independent
        // controls, monotone ramps, encoded preview/export and saturation gamut.
        let neutralGrade=VideoEffectSettings(.colorCorrection)
        let neutralPixels=pixels(try renderer.render(input,effects:[neutralGrade],sourceTime:0))
        try check(zip(source,neutralPixels).allSatisfy {abs($0-$1)<0.001},"Neutral correction leaves the full RGB gradient unchanged")
        var pivotOnly=neutralGrade;pivotOnly.set("pivot",.number(0.2))
        let pivotPixels=pixels(try renderer.render(input,effects:[pivotOnly],sourceTime:0))
        try check(pivotPixels==neutralPixels,"Pivot alone is exactly inert")
        var rampData=[Float]()
        for _ in 0..<height {for x in 0..<width {let v=Float(x)/Float(width-1);rampData += [v,v,v,1]}}
        let gradeRamp=CIImage(bitmapData:rampData.withUnsafeBytes {Data($0)},bytesPerRow:width*16,size:bounds.size,format:.RGBAf,colorSpace:space)
        for definition in neutralGrade.kind.descriptor.parameters {
            guard case let .slider(low,high,_,_)=definition.kind else {continue}
            for endpoint in [low,high] {
                var grade=neutralGrade;grade.set(definition.id,.number(endpoint))
                let output=pixels(try renderer.render(input,effects:[grade],sourceTime:0))
                try check(output.allSatisfy {$0.isFinite && $0>=0 && $0<=1},"Bounded grading at \(definition.id) \(endpoint)")
                if definition.id != "pivot" {try check(zip(output,neutralPixels).contains {abs($0-$1)>0.005},"Control has a visible effect: \(definition.id)")}
                if ColorCorrectionControls.light.contains(definition.id) || ColorCorrectionControls.advanced.contains(definition.id) {
                    let gray=pixels(try renderer.render(gradeRamp,effects:[grade],sourceTime:0))
                    for x in 1..<width {try check(gray[x*4]>=gray[(x-1)*4]-0.001,"Tone ramp never reverses for \(definition.id)")}
                    for x in 0..<width {try check(abs(gray[x*4]-gray[x*4+1])<0.001 && abs(gray[x*4]-gray[x*4+2])<0.001,"Tone controls keep neutral grays neutral")}
                }
            }
        }
        for (id,value) in [("exposure",1.0),("whites",1),("blacks",-1)] {
            var grade=neutralGrade;grade.set(id,.number(value))
            let output=pixels(try renderer.render(gradeRamp,effects:[grade],sourceTime:0))
            let unique=Set((0..<width).map {output[$0*4]})
            try check(unique.count>300,"Strong \(id) preserves distinct gray levels instead of clipping: \(unique.count)")
        }
        var redRamp:[Float]=[]
        for _ in 0..<height {for x in 0..<width {let v=0.7*Float(x)/Float(width-1);redRamp += [0.7,v,v,1]}}
        let redGradient=CIImage(bitmapData:redRamp.withUnsafeBytes {Data($0)},bytesPerRow:width*16,size:bounds.size,format:.RGBAf,colorSpace:space)
        var saturated=neutralGrade;saturated.set("saturation",.number(2))
        let redResult=pixels(try renderer.render(redGradient,effects:[saturated],sourceTime:0))
        try check(Set((0..<width).map {redResult[$0*4+1]}).count>300,"Saturation preserves vivid gradients instead of flattening them at the gamut edge")
        for saturation in [0.0,1,2] {
            var grade=neutralGrade;grade.set("saturation",.number(saturation));grade.set("vibrance",.number(1));grade.set("hue",.number(75))
            let gray=pixels(try renderer.render(gradeRamp,effects:[grade],sourceTime:0))
            try check(zip(gray,rampData).allSatisfy {abs($0-$1)<0.001},"Color controls cannot tint a gray ramp")
        }
        var bwGrade=neutralGrade;bwGrade.set("saturation",.number(0))
        let bw=pixels(try renderer.render(input,effects:[bwGrade],sourceTime:0))
        for i in stride(from:0,to:bw.count,by:4) {try check(abs(bw[i]-bw[i+1])<0.001 && abs(bw[i]-bw[i+2])<0.001,"Zero saturation is monochrome")}
        let gray18=CIImage(color:CIColor(red:0.18,green:0.18,blue:0.18,colorSpace:space)!).cropped(to:bounds)
        var exposureGrade=neutralGrade;exposureGrade.set("exposure",.number(1))
        let exposed=pixels(try renderer.render(gray18,effects:[exposureGrade],sourceTime:0))
        try check(abs(exposed[0]-0.36)<0.001,"One exposure stop doubles middle-gray linear light")
        var combo=neutralGrade
        for (id,value) in [("exposure",0.3),("contrast",1.3),("shadows",0.3),("highlights",-0.4),("blacks",0.1),("whites",-0.1),("temperature",0.2),("tint",-0.1),("saturation",1.15),("vibrance",0.4),("hue",12.0)] {combo.set(id,.number(value))}
        let graded=pixels(try renderer.render(input,effects:[combo],sourceTime:0))
        let repeatedGrade=pixels(try renderer.render(input,effects:[combo],sourceTime:0))
        try check(graded==repeatedGrade,"Correction is deterministic")
        combo.set("intensity",.number(0.5))
        let halfway=pixels(try renderer.render(input,effects:[combo],sourceTime:0))
        try check(zip(halfway,zip(neutralPixels,graded)).allSatisfy {abs($0-($1.0+$1.1)/2)<0.001},"Correction intensity blends with its own input in linear light")
        print("PASS: Color Correction neutral defaults, EV exposure, tone monotonicity, gray stability, gamut, determinism and intensity")
        // Stateless finite-window matte math: changing seek order cannot change
        // these inputs. Source-index/caching integration is tested separately.
        func constant(_ value:Double,width:Int=320,height:Int=180,format:MTLPixelFormat = .r16Float)throws->MTLTexture {
            let texture=try renderer.texture(width:width,height:height,format:format)
            let image=CIImage(color:CIColor(red:value,green:value,blue:value,colorSpace:space)!).cropped(to:CGRect(x:0,y:0,width:width,height:height))
            renderer.context.render(image,to:texture,commandBuffer:nil,bounds:image.extent,colorSpace:space)
            return texture
        }
        func temporal(_ current:MTLTexture,_ guide:MTLTexture,_ history:[(matte:MTLTexture,guide:MTLTexture)],_ kind:VideoEffectMatteKind,detectCuts:Bool=true,detectCurrentCut:Bool=false)throws->[Float] {
            renderer.beginEncoding();let command=renderer.queue.makeCommandBuffer()!
            let result=renderer.temporalMatte(current:current,guide:guide,history:history,kind:kind,detectCuts:detectCuts,detectCurrentCut:detectCurrentCut,commandBuffer:command)
            command.commit();command.waitUntilCompleted();if let error=command.error {throw error}
            return pixels(CIImage(mtlTexture:result,options:[.colorSpace:space])!)
        }
        let matteGuide=try constant(0.25,width:80,height:45),currentMatte=try constant(0.7)
        for kind in [VideoEffectMatteKind.isolation,.key] {
            let values=(0..<(kind.capacity-1)).map {Double(($0*11)%19)/18}
            let history=try values.map {(matte:try constant($0,format:.r8Unorm),guide:matteGuide)}
            let output=try temporal(currentMatte,matteGuide,history,kind)
            var expected=Double((values.last!*255).rounded())/255
            for value in values.dropLast().reversed() {expected=expected*kind.prior+(value*255).rounded()/255*(1-kind.prior)}
            expected=expected*kind.prior+0.7*(1-kind.prior)
            try check(abs(Double(output[0])-expected)<0.001,"GPU matte window matches the finite EMA including R8 history rounding")
            let repeated=try temporal(currentMatte,matteGuide,history,kind)
            try check(repeated==output,"Matte history has no hidden render-order state")
            let empty=try temporal(currentMatte,matteGuide,[],kind)
            try check(abs(Double(empty[0])-0.7)<0.001,"A new matte stream preserves its current value")
            let cutGuide=try constant(0.8,width:80,height:45)
            let cut=try temporal(currentMatte,cutGuide,history,kind)
            try check(cut==empty,"An internal scene cut discards earlier matte history")
        }
        let lateCutGuide=try constant(0.8,width:80,height:45)
        let oldCuts=[(matte:try constant(0.1,format:.r8Unorm),guide:matteGuide),(matte:try constant(1,format:.r8Unorm),guide:lateCutGuide)]
        let recordedOnly=try temporal(currentMatte,matteGuide,oldCuts,.isolation,detectCuts:false)
        let newBoundaryOnly=try temporal(currentMatte,matteGuide,oldCuts,.isolation,detectCuts:false,detectCurrentCut:true)
        try check(newBoundaryOnly==recordedOnly,"Skipped-preview export frames preserve recorded decisions for older boundaries")
        let newCut=try temporal(currentMatte,lateCutGuide,oldCuts,.isolation,detectCuts:false,detectCurrentCut:true)
        let noHistory=try temporal(currentMatte,lateCutGuide,[],.isolation)
        try check(newCut==noHistory,"A cut on a frame skipped by live preview still closes export history")
        let oldMatte=try constant(0.2,format:.r8Unorm)
        var motionValues:[Float]=[]
        for difference in [0.0,0.008,0.015,0.019,0.021] {
            let oldGuide=try constant(0.25-difference,width:80,height:45)
            let result=try temporal(currentMatte,matteGuide,[(oldMatte,oldGuide)],.key)
            motionValues.append(result[0])
        }
        try check(zip(motionValues,motionValues.dropFirst()).allSatisfy {$0<=$1+0.001} && abs(motionValues[2]-0.6375)<0.004 && abs(motionValues.last!-0.7)<0.001,"Keyed alpha smoothly releases history between 0.01 and 0.02 perceptual-luma motion")
        let guideInput=try constant(0.01,format:.rgba16Float)
        renderer.beginEncoding();let guideCommand=renderer.queue.makeCommandBuffer()!
        let darkGuide=renderer.matteGuide(guideInput,commandBuffer:guideCommand)
        guideCommand.commit();guideCommand.waitUntilCompleted()
        let darkPixels=pixels(CIImage(mtlTexture:darkGuide,options:[.colorSpace:space])!.transformed(by:CGAffineTransform(scaleX:4,y:4)))
        try check(abs(Double(darkPixels[0])-EffectColorMath.encoded(0.01))<0.001,"Matte guides preserve dark-scene contrast in perceptual light: \(darkPixels[0]) expected \(EffectColorMath.encoded(0.01))")
        let matteCache=VideoEffectMatteCache(softLimit:250_000,hardLimit:1_000_000,entryLimit:12)
        func cachedFrame(_ index:Int)throws->VideoEffectMatteCache.Frame {
            try autoreleasepool {
                let frame=try matteCache.allocate(renderer:renderer,width:64,height:64)
                let command=renderer.queue.makeCommandBuffer()!
                frame.retain(until:command)
                let key=VideoEffectMatteCache.Key(device:renderer.device.registryID,stream:"reference",time:Double(index))
                let fill=CIImage(color:CIColor(red:Double(index)/40,green:0,blue:0,colorSpace:space)!).cropped(to:CGRect(x:0,y:0,width:64,height:64))
                renderer.context.render(fill,to:frame.matte,commandBuffer:command,bounds:fill.extent,colorSpace:space)
                var rejected=false
                do {try matteCache.publish(frame,for:key,completed:command)} catch {rejected=true}
                try check(rejected && matteCache.frame(for:key)==nil,"An uncommitted matte cannot become visible on another queue")
                command.commit();command.waitUntilCompleted()
                try matteCache.publish(frame,for:key,completed:command)
                return frame
            }
        }
        var retainedMatte:VideoEffectMatteCache.Frame?=try cachedFrame(1)
        for index in 2...40 {try autoreleasepool { _=try cachedFrame(index) }}
        try check(matteCache.statistics.cachedFrames<=12 && matteCache.statistics.cachedBytes<=250_000 && matteCache.statistics.allocatedBytes<=1_000_000,"Matte cache obeys its entry, soft cache and hard allocation budgets")
        let otherRenderer=try MetalEffectRenderer()
        var retainedPixel=[Float](repeating:0,count:4)
        otherRenderer.context.render(CIImage(mtlTexture:retainedMatte!.matte,options:[.colorSpace:space])!,toBitmap:&retainedPixel,rowBytes:16,bounds:CGRect(x:0,y:0,width:1,height:1),format:.RGBAf,colorSpace:space)
        try check(abs(Double(retainedPixel[0])-Double((0.025*255).rounded())/255)<0.001,"An evicted leased matte remains immutable and readable from another GPU queue")
        let allocatedBeforeFailure=matteCache.statistics.allocatedBytes
        var allocationRejected=false
        do {_=try matteCache.allocate(renderer:renderer,width:16384,height:16384)} catch {allocationRejected=true}
        try check(allocationRejected && matteCache.statistics.allocatedBytes==allocatedBeforeFailure,"An oversized allocation fails without leaking a reservation or evicting valid entries")
        matteCache.purge()
        try check(matteCache.statistics.cachedFrames==0 && matteCache.statistics.allocatedBytes==retainedMatte!.allocatedBytes,"Purging keeps evicted-but-leased GPU storage accounted for")
        retainedMatte=nil
        try check(matteCache.statistics.allocatedBytes==0,"Releasing the final matte lease returns allocation accounting to zero")
        weak var releasedCache:VideoEffectMatteCache?
        try autoreleasepool {
            let temporary=VideoEffectMatteCache();releasedCache=temporary
            let frame=try temporary.allocate(renderer:renderer,width:32,height:18),command=renderer.queue.makeCommandBuffer()!
            command.commit();command.waitUntilCompleted()
            try temporary.publish(frame,for:.init(device:renderer.device.registryID,stream:"lifetime",time:0),completed:command)
        }
        try check(releasedCache==nil,"Cached reservations do not form an ownership cycle")
        for kind in [VideoEffectID.colorIsolation,.chromaKey] {
            var modern=VideoEffectSettings(kind);modern.algorithm=1
            modern.set("personHint",.toggle(false));modern.set("softness",.number(0))
            let legacy=try renderer.render(input,effects:[modern],sourceTime:0.5),legacyPixels=pixels(legacy)
            modern.algorithm=2
            var rejected=false
            do {_=try renderer.render(input,effects:[modern],sourceTime:0.5)} catch VideoEffectError.unavailableMatteHistory {rejected=true}
            try check(rejected,"A modern effect cannot silently render with unavailable temporal history")
            let key=VideoEffectMatteCache.Key(device:renderer.device.registryID,stream:"capture-"+kind.rawValue,time:0.5)
            var frame=FrameContext(presentationTime:0.5,frameIndex:15);frame.matteHistory=[];frame.matteCapture=key
            var captured:VideoEffectMatteCache.Frame?
            let current=try renderer.render(input,effects:[modern],sourceTime:0.5,frameContext:frame,captureMatte:{_,raw in captured=raw})
            let currentPixels=pixels(current)
            try check(zip(currentPixels,legacyPixels).allSatisfy {abs($0-$1)<0.002},"A fresh temporal stream agrees with its spatial matte")
            try check(captured != nil && VideoEffectMatteCache.shared.frame(for:key) === captured,"Completed rendering publishes an immutable raw matte before its own smoothing")
            frame.matteCapture=nil;frame.matteHistory=[captured!]
            let blended=pixels(try renderer.render(input,effects:[modern],sourceTime:0.5,frameContext:frame))
            try check(zip(blended,currentPixels).allSatisfy {abs($0-$1)<0.002},"Repeating a static raw matte preserves the image within R8-history precision")
            frame.matteCapture = .init(device:renderer.device.registryID,stream:"raw-only-"+kind.rawValue,time:0.5)
            frame.matteHistory=nil;frame.matteOnly=true
            var rawOnly:VideoEffectMatteCache.Frame?
            _=try renderer.render(input,effects:[modern],sourceTime:0.5,frameContext:frame,captureMatte:{_,raw in rawOnly=raw})
            try check(rawOnly != nil,"Producing a raw matte needs upstream history but not its own history")
        }
        VideoEffectMatteCache.shared.purge()
        let liveHistory=VideoEffectLiveMatteHistory()
        var liveIsolation=VideoEffectSettings(.colorIsolation);liveIsolation.algorithm=2
        for index in 0..<20 {
            let time=Double(index)/30
            let snapshot=liveHistory.snapshot(effects:[liveIsolation],time:time,geometry:"rear")
            if index%3==1 {continue} // Deliberately missed/held previews.
            let picture=CIImage(color:index<15 ? CIColor(red:0.2,green:0.2,blue:0.2) : .white).cropped(to:index<10 ? bounds : CGRect(x:0,y:0,width:160,height:90))
            let contexts=snapshot.applying(to:[:],device:renderer.device.registryID,capture:true)
            var raw:[UUID:VideoEffectMatteCache.Frame]=[:]
            _=try renderer.render(picture,effects:[liveIsolation],sourceTime:time,contexts:contexts,captureMatte:{raw[$0]=$1})
            let resets=try liveHistory.accept(raw,snapshot:snapshot)
            try check(resets[liveIsolation.id]==(index==0 || index==15),"Live rings retain accepted frames across resize and persist real scene cuts")
            try check((snapshot.history[liveIsolation.id]?.count ?? 0)<VideoEffectMatteKind.isolation.capacity,"Live history remains bounded")
        }
        let gapSnapshot=liveHistory.snapshot(effects:[liveIsolation],time:1,geometry:"rear")
        try check(gapSnapshot.history[liveIsolation.id]?.isEmpty==true,"Long source gaps reset live matte history")
        let cameraSnapshot=liveHistory.snapshot(effects:[liveIsolation],time:1.01,geometry:"front")
        try check(cameraSnapshot.history[liveIsolation.id]?.isEmpty==true,"Camera changes begin a fresh live matte stream")
        liveHistory.reset();VideoEffectMatteCache.shared.purge()
        for index in 0..<300 {
            try autoreleasepool {
                let time=Double(index)/30,snapshot=liveHistory.snapshot(effects:[liveIsolation],time:time,geometry:"rear")
                var raw:[UUID:VideoEffectMatteCache.Frame]=[:]
                _=try renderer.render(input,effects:[liveIsolation],sourceTime:time,contexts:snapshot.applying(to:[:],device:renderer.device.registryID,capture:true),captureMatte:{raw[$0]=$1})
                let before=snapshot.history[liveIsolation.id]?.count ?? 0
                _=try liveHistory.resetDecisions(raw,snapshot:snapshot)
                _=liveHistory.peek(effects:[],time:time,geometry:"rear")
                try check(liveHistory.peek(effects:[liveIsolation],time:time,geometry:"rear").history[liveIsolation.id]?.count==before,"Auxiliary reads and pending sidecar writes never mutate the main ring")
                try liveHistory.accept(raw,snapshot:snapshot)
            }
        }
        let retained=liveHistory.peek(effects:[liveIsolation],time:10,geometry:"rear").history[liveIsolation.id] ?? []
        let liveStats=VideoEffectMatteCache.shared.statistics
        try check(liveStats.cachedBytes==0 && liveStats.cachedFrames==0,"Live captures never accumulate in the export cache")
        try check(liveStats.allocatedBytes==retained.reduce(0) {$0+$1.allocatedBytes},"After 300 frames only the bounded live ring owns matte allocations")
        liveHistory.reset();VideoEffectMatteCache.shared.purge()
        for kind in VideoEffectID.allCases where ![VideoEffectID.dollyZoom,.autoBackground,.nightFix].contains(kind) {
            var effect=VideoEffectSettings(kind,end:4)
            if kind == .chromaKey { effect.set("personHint",.toggle(false)) }
            let a=try renderer.render(input,effects:[effect],sourceTime:0.5,frameContext:FrameContext(presentationTime:0.5,frameIndex:15,matteHistory:[]))
            let b=try renderer.render(input,effects:[effect],sourceTime:0.5,frameContext:FrameContext(presentationTime:0.5,frameIndex:15,matteHistory:[]))
            let pa=pixels(a),pb=pixels(b)
            try check(pa.allSatisfy{$0.isFinite&&$0 >= -0.001&&$0 <= 1.001},"Finite normalized output: \(kind)")
            try check(pa==pb,"Identical repeated pixels: \(kind)")
            if kind.descriptor.supportsIntensity {
                effect.set("intensity",.number(0));let identity=try renderer.render(input,effects:[effect],sourceTime:0.5,frameContext:FrameContext(presentationTime:0.5,frameIndex:15,matteHistory:[]))
                try check(pixels(identity)==source,"Zero intensity is exact identity: \(kind)")
            }
            print("GPU \(kind.rawValue): deterministic, \(String(format:"%.3f",renderer.gpuSeconds*1000)) ms")
        }
        // Paired bilinear Gaussian taps must retain the original normalized
        // kernel, including subpixel radii used on keyed hair and fine grain.
        let impulse=CIImage(color:.white).cropped(to:CGRect(x:width/2,y:height/2,width:1,height:1)).composited(over:CIImage(color:.black).cropped(to:bounds))
        let impulseTexture=try renderer.texture(width:width,height:height)
        renderer.context.render(impulse,to:impulseTexture,commandBuffer:nil,bounds:bounds,colorSpace:space)
        let impulsePixels=pixels(CIImage(mtlTexture:impulseTexture,options:[.colorSpace:space])!)
        let peak=stride(from:0,to:impulsePixels.count,by:4).max { impulsePixels[$0]<impulsePixels[$1] }!/4
        let centerX=peak%width,centerY=peak/width
        for sigma in [0.25,0.45,1.5,8.0,14.0] {
            renderer.beginEncoding();let command=renderer.queue.makeCommandBuffer()!
            let output=renderer.blur(impulseTexture,sigma:sigma,commandBuffer:command)
            command.commit();command.waitUntilCompleted()
            let image=CIImage(mtlTexture:output,options:[.colorSpace:space])!,actual=pixels(image)
            let radius=min(48,Int(ceil(sigma*3))),weights=(0...min(48,Int(ceil(sigma*3)))).map { exp(-Double($0*$0)/(2*sigma*sigma)) }
            let total=weights[0]+2*weights.dropFirst().reduce(0,+)
            for y in -radius...radius { for x in -radius...radius {
                let expected=weights[abs(x)]*weights[abs(y)]/(total*total),observed=Double(actual[((centerY+y)*width+centerX+x)*4])
                try check(abs(expected-observed)<0.001,"Gaussian bilinear pairing preserves kernel at sigma \(sigma)")
            } }
        }
        // Materialization must finish reading the old sum before its textures
        // are returned to the pool. Retaining the first layer catches A/B reuse.
        var sumLeases:[VideoEffectFrameLease]=[]
        let saved=try renderer.materialize(input,lease:{sumLeases.append($0)}),savedPixels=pixels(saved)
        var running=saved
        for index in 1...12 {
            let next=CIImage(color:CIColor(red:Double(index)/12,green:0.4,blue:0.2,colorSpace:space)!).cropped(to:bounds)
            let blend=running.applyingFilter("CIDissolveTransition",parameters:[kCIInputTargetImageKey:next,kCIInputTimeKey:0.5])
            var retained:VideoEffectFrameLease?
            running=try renderer.materialize(blend,lease:{retained=$0})
            if sumLeases.count>1 {sumLeases.removeLast()};sumLeases.append(retained!)
            try check(pixels(saved)==savedPixels,"Streaming temporal accumulation cannot overwrite the other transition layer")
            let expected=pixels(blend),actual=pixels(running)
            try check(zip(expected,actual).allSatisfy{abs($0-$1)<0.001},"Materialized temporal sums match the lazy linear-light blend")
        }
        // Keep an old GPU result alive while later frames borrow from the pool.
        // This covers the two sides of a transition and a queued display draw.
        var leases:[VideoEffectFrameLease]=[]
        let leasedA=try renderer.render(input,effects:[VideoEffectSettings(.silentTint)],sourceTime:0,lease:{leases.append($0)})
        let expectedLeased=pixels(leasedA)
        for frame in 1...8 {
            var currentLease:VideoEffectFrameLease?
            _ = try renderer.render(input,effects:[VideoEffectSettings(.noir)],sourceTime:Double(frame)/30,lease:{currentLease=$0})
            try check(pixels(leasedA)==expectedLeased,"A retained output lease prevents overwriting a queued frame")
            withExtendedLifetime(currentLease) {}
        }
        leases.removeAll()
        if renderer.device.supportsCounterSampling(.atStageBoundary) {
            renderer.profileGPU=true
            _ = try renderer.render(input,effects:[VideoEffectSettings(.noir)],sourceTime:0)
            try check(!renderer.gpuStages.isEmpty && renderer.gpuStages.values.allSatisfy { $0.isFinite && $0>=0 && $0<1 },"GPU timestamp counters report finite per-stage seconds")
            renderer.profileGPU=false
        }
        var neutralContrast = VideoEffectSettings(.silentTint); neutralContrast.set("contrast",.number(1))
        let amber=try renderer.render(CIImage(color:CIColor(red:0.5,green:0.5,blue:0.5,colorSpace:space)!).cropped(to:bounds),effects:[neutralContrast],sourceTime:0)
        let p=pixels(amber);let tint=EffectColorMath.linear(EffectRGB(hex:"#D9A441"))
        try check(abs(Double(p[0])-0.5*tint.x)<0.001&&abs(Double(p[1])-0.5*tint.y)<0.001,"Silent Tint linear-light reference")
        var key=VideoEffectSettings(.chromaKey);key.set("autoScreen",.toggle(false));key.set("personHint",.toggle(false));key.set("softness",.number(0));key.set("despill",.number(0));key.set("wrap",.number(0))
        let original=CIImage(color:CIColor(red:0.15,green:0.7,blue:0.1,colorSpace:space)!).cropped(to:bounds)
        let background=try renderer.texture(width:width,height:height)
        renderer.context.render(CIImage(color:CIColor(red:0,green:0,blue:1,colorSpace:space)!).cropped(to:bounds),to:background,commandBuffer:nil,bounds:bounds,colorSpace:space)
        let context=FrameContext(presentationTime:0,frameIndex:0,background:background,matteHistory:[])
        let keyed=try renderer.render(original,effects:[key],sourceTime:0,frameContext:context)
        let kp=pixels(keyed)
        try check(kp[0]>0.14,"Unmixing does not multiply translucent foreground by alpha twice")
        var automatic=key;automatic.set("autoScreen",.toggle(true))
        let detected=try renderer.render(original,effects:[automatic],sourceTime:0,frameContext:context)
        let detectedPixels=pixels(detected)
        try check(detectedPixels[0]<0.005 && detectedPixels[2]>0.99,"Auto screen reference removes an unevenly exposed green instead of assuming pure #00FF00")
        let fullMask=try renderer.texture(width:16,height:16)
        renderer.context.render(CIImage(color:.white).cropped(to:CGRect(x:0,y:0,width:16,height:16)),to:fullMask,commandBuffer:nil,bounds:CGRect(x:0,y:0,width:16,height:16),colorSpace:space)
        var hinted=key;hinted.set("personHint",.toggle(true));hinted.set("view",.choice("Matte"))
        let hintedResult=try renderer.render(original,effects:[hinted],sourceTime:0,frameContext:FrameContext(presentationTime:0,frameIndex:0,personMask:fullMask,background:background,matteHistory:[]))
        try check(pixels(hintedResult)[0]>0.99,"Person holdout fills a partially keyed interior")
        let emptyMask=try renderer.texture(width:16,height:16)
        renderer.context.render(CIImage(color:.black).cropped(to:CGRect(x:0,y:0,width:16,height:16)),to:emptyMask,commandBuffer:nil,bounds:CGRect(x:0,y:0,width:16,height:16),colorSpace:space)
        let outside=try renderer.render(input,effects:[hinted],sourceTime:0,frameContext:FrameContext(presentationTime:0,frameIndex:0,personMask:emptyMask,background:background,matteHistory:[]))
        let outsidePixels=pixels(outside)
        try check(stride(from:0,to:width*height*4,by:4).allSatisfy{outsidePixels[$0]<0.001},"Person garbage matte removes material outside the subject")
        var quant=VideoEffectSettings(.quantization)
        let unanalysed = pixels(try renderer.render(input, effects: [quant], sourceTime: 0))
        try check(zip(source, unanalysed).allSatisfy { abs($0-$1) < 0.001 }, "Waiting for a palette keeps the picture in color")
        let red = SIMD3<Double>(0.8, 0, 0), green = SIMD3<Double>(0, 0.8*0.2126/0.7152, 0)
        let sameBrightnessPalette = EffectPalette(colors: [EffectColorMath.rgb(red), EffectColorMath.rgb(green)], thresholds: [0.9])
        let paletteFrame = FrameContext(presentationTime: 0, frameIndex: 0, palette: sameBrightnessPalette)
        let quantFull=pixels(try renderer.render(input,effects:[quant],sourceTime:0, frameContext:paletteFrame))
        quant.set("intensity",.number(0.9999))
        let quantAlmost=pixels(try renderer.render(input,effects:[quant],sourceTime:0, frameContext:paletteFrame))
        try check(zip(quantFull,quantAlmost).allSatisfy{abs($0-$1)<0.002},"Full-intensity quantization agrees with the blended path")
        quant.set("intensity", .number(1))
        for choice in ["From scene", "Saved"] {
            quant.set("palette", .choice(choice))
            for color in [red, green] {
                let patch = CIImage(color: CIColor(red: color.x, green: color.y, blue: 0, colorSpace: space)!).cropped(to: bounds)
                let actual = pixels(try renderer.render(patch, effects: [quant], sourceTime: 0, frameContext: paletteFrame))
                try check(abs(Double(actual[0])-color.x)<0.003 && abs(Double(actual[1])-color.y)<0.003, "Equally bright sampled hues survive in " + choice)
            }
        }
        quant.set("monochrome", .toggle(true))
        let grayQuant = pixels(try renderer.render(input, effects: [quant], sourceTime: 0, frameContext: paletteFrame))
        for i in stride(from: 0, to: grayQuant.count, by: 4) {
            try check(grayQuant[i] == grayQuant[i+1] && grayQuant[i] == grayQuant[i+2], "Explicit B&W still uses brightness bands")
        }
        let neutralBG=try renderer.texture(width:width,height:height)
        renderer.context.render(CIImage(color:CIColor(red:0.2,green:0.3,blue:0.6,colorSpace:space)!).cropped(to:bounds),to:neutralBG,commandBuffer:nil,bounds:bounds,colorSpace:space)
        var match=VideoEffectSettings(.autoBackground);match.set("matchColor",.toggle(true));match.set("matchStrength",.number(1))
        let person=CIImage(color:CIColor(red:0.6,green:0.3,blue:0.2,colorSpace:space)!).cropped(to:bounds)
        let matched=try renderer.render(person,effects:[match],sourceTime:0,frameContext:FrameContext(presentationTime:0,frameIndex:0,personMask:fullMask,background:neutralBG))
        let matchedPixels=pixels(matched)
        try check(matchedPixels[0]<0.4 && matchedPixels[2]>0.3,"Match color shifts the subject toward background illumination")
        // A patterned old background makes the local screen estimate imperfect.
        // Even then, foreground energy must be bounded by its actual coverage:
        // dividing by a tiny alpha must not create a bright opaque fringe.
        let checker=CIImage(color:CIColor(red:0.05,green:0.05,blue:0.05,colorSpace:space)!).cropped(to:bounds)
        let brightWindow=CIImage(color:CIColor(red:0.98,green:0.98,blue:0.98,colorSpace:space)!)
            .cropped(to:CGRect(x:width/3,y:0,width:7,height:height)).composited(over:checker)
        for coverage in [0.01,0.1,0.5,1.0] {
            let silhouette=try constant(coverage,width:80,height:45,format:.r8Unorm)
            var replacement=VideoEffectSettings(.autoBackground);replacement.set("wrap",.number(0));replacement.set("background",.choice("Solid"))
            let frame=FrameContext(presentationTime:0,frameIndex:0,personMask:silhouette,background:neutralBG)
            let output=pixels(try renderer.render(brightWindow,effects:[replacement],sourceTime:0,frameContext:frame))
            replacement.set("view",.choice("Matte"))
            let alpha=pixels(try renderer.render(brightWindow,effects:[replacement],sourceTime:0,frameContext:frame))
            for offset in stride(from:0,to:output.count,by:4) {
                let a=alpha[offset]
                for channel in 0..<3 {
                    let background:[Float]=[0.2,0.3,0.6],base=background[channel]*(1-a)
                    try check(output[offset+channel]>=base-0.003 && output[offset+channel]<=base+a+0.003,"Background estimate errors cannot exceed the person's coverage")
                }
            }
            if coverage==0.01 {try check(alpha[0]<0.001,"Low-confidence mask skirts are transparent instead of adding padding")}
            if coverage==0.5 {try check(abs(alpha[0]-0.5)<0.01,"Edge cleanup retains the half-coverage contour")}
        }
        print("PASS: person edges reject low-confidence skirts and compositing bounds translucent foreground energy")
        // Asymmetric Core Video mask catches a texture-coordinate flip that
        // uniform colors and CI-created masks cannot reveal.
        var pixel: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault,width,height,kCVPixelFormatType_OneComponent8,[kCVPixelBufferMetalCompatibilityKey:true,kCVPixelBufferIOSurfacePropertiesKey:[:]] as CFDictionary,&pixel)
        let maskPixel=pixel!;CVPixelBufferLockBaseAddress(maskPixel,[])
        let row=CVPixelBufferGetBytesPerRow(maskPixel),base=CVPixelBufferGetBaseAddress(maskPixel)!.assumingMemoryBound(to:UInt8.self)
        for y in 0..<height { for x in 0..<width { base[y*row+x]=y<height/2 ? 255 : 0 } }
        CVPixelBufferUnlockBaseAddress(maskPixel,[])
        var cache:CVMetalTextureCache?;CVMetalTextureCacheCreate(kCFAllocatorDefault,nil,renderer.device,nil,&cache)
        var cvTexture:CVMetalTexture?;CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,cache!,maskPixel,nil,.r8Unorm,width,height,0,&cvTexture)
        let top=CIImage(color:CIColor(red:0.6,green:0.1,blue:0.05,colorSpace:space)!).cropped(to:CGRect(x:0,y:height/2,width:width,height:height/2))
        let bottom=CIImage(color:CIColor(red:0.1,green:0.5,blue:0.2,colorSpace:space)!).cropped(to:bounds)
        let asymmetric=top.composited(over:bottom)
        var isolation=VideoEffectSettings(.colorIsolation);isolation.set("mode",.choice("The subject"))
        let isolated=try renderer.render(asymmetric,effects:[isolation],sourceTime:0,frameContext:FrameContext(presentationTime:0,frameIndex:0,personMask:CVMetalTextureGetTexture(cvTexture!),matteHistory:[]))
        func at(_ image:CIImage,_ x:Int,_ y:Int)->[Float] {
            var p=[Float](repeating:0,count:4);renderer.context.render(image,toBitmap:&p,rowBytes:16,bounds:CGRect(x:x,y:y,width:1,height:1),format:.RGBAf,colorSpace:space);return p
        }
        // Use a distinct landmark in every channel so a sign error or a swapped channel is observable.
        var chartData = [Float](repeating: 0.15, count: width*height*4)
        for i in stride(from: 0, to: chartData.count, by: 4) { chartData[i+3] = 1 }
        for y in 70..<92 { for x in 120..<145 {
            let i = (y*width+x)*4
            chartData[i] = 0.8; chartData[i+1] = 0.65; chartData[i+2] = 0.45
        }}
        let chart = CIImage(bitmapData: chartData.withUnsafeBytes { Data($0) }, bytesPerRow: width*16, size: bounds.size, format: .RGBAf, colorSpace: space)
        let reference = pixels(chart)
        var offset = VideoEffectSettings(.rgbOffset)
        let neutralOffset = pixels(try renderer.render(chart, effects: [offset], sourceTime: 0))
        try check(reference == neutralOffset, "Centered RGB pads preserve the source")
        let shifts = [(12,0), (-4,10), (2,-9)]
        for (channel, displacement) in zip(RGBChannel.allCases, shifts) {
            offset.set(channel.x, .number(Double(displacement.0)/(0.12*Double(height))))
            offset.set(channel.y, .number(Double(displacement.1)/(0.12*Double(height))))
        }
        let shiftedRGB = pixels(try renderer.render(chart,effects:[offset],sourceTime:0))
        // The bitmap is in row order; positive Y in the shader moves content down.
        for c in 0..<3 { for y in 0..<height { for x in 0..<width {
            let sourceX = max(0, min(width-1, x-shifts[c].0))
            let sourceY = max(0, min(height-1, y-shifts[c].1))
            try check(abs(shiftedRGB[(y*width+x)*4+c]-reference[(sourceY*width+sourceX)*4+c]) < 0.002, "Independent channel displacement \(c) at \(x), \(y)")
        }}}
        var strobe = VideoEffectSettings(.negativeStrobe, start: 1, end: 2)
        strobe.set("frequency", .number(15)); strobe.set("timedBurst",.toggle(true)); strobe.set("burstLength",.number(0.2))
        for f in [0,1,2,5,6,3,-1,30] {
            let rendered = pixels(try renderer.render(chart, effects: [strobe], sourceTime: 1+Double(f)/30))
            let negative = [1,3,5].contains(f)
            for c in 0..<3 {
                let i = (80*width+130)*4+c
                let v = Double(reference[i]), code = 1.055 * pow(v,1/2.4)-0.055
                let inverse = 1-code, expected = inverse <= 0.04045 ? inverse/12.92 : pow((inverse+0.055)/1.055,2.4)
                try check(abs(Double(rendered[i])-(negative ? expected : v)) < 0.002, "Positive/negative phase at frame \(f)")
            }
        }
        print("PASS: RGB channel registration, neutral bypass, negative in display values, burst boundaries and random seeks")
        // Probe the interior of every sector. Use the expected repeated source
        // point, independent of the shader's inverse polar mapping.
        for (w, h) in [(width, height), (height, width)] {
            let picture = input.transformed(by: CGAffineTransform(scaleX: Double(w)/Double(width), y: Double(h)/Double(height)))
            let center = CGPoint(x: Double(w)*0.56, y: Double(h)*0.42)
            for count in 2...9 {
                var effect = VideoEffectSettings(.kaleidoscope)
                effect.set("divisions", .number(Double(count)))
                effect.set("centerX", .number(0.56)); effect.set("centerY", .number(0.42))
                effect.set("splitAngle", .number(31))
                let rendered = try renderer.render(picture, effects: [effect], sourceTime: 1)
                effect.set("sourcePanX", .number(0.81)); effect.set("sourcePanY", .number(-0.77))
                let shifted = try renderer.render(picture, effects: [effect], sourceTime: 1)
                effect.set("sourceAngle", .number(73))
                let turned = try renderer.render(picture, effects: [effect], sourceTime: 1)
                let span = 2 * Double.pi / Double(count), base = -59.0 * Double.pi / 180
                func probe(_ image: CIImage, _ theta: Double) -> [Float] {
                    at(image, Int(center.x + 64 * cos(theta)), h - 1 - Int(center.y + 64 * sin(theta)))
                }
                for fraction in [0.18, 0.7] {
                    let expected = probe(picture, base + fraction * span)
                    func reflect(_ x: Double, length: Int) -> Int {
                        let period = 2 * Double(length)
                        let phase = x - period * floor(x / period)
                        return min(length - 1, Int(min(phase, period - phase)))
                    }
                    let theta = base + fraction * span
                    let sourceX = reflect(center.x + 64 * cos(theta) - 0.81 * Double(w), length: w)
                    let sourceY = reflect(center.y + 64 * sin(theta) + 0.77 * Double(h), length: h)
                    let movedSource = at(picture, sourceX, h - 1 - sourceY)
                    let turnedTheta = theta - 73 * Double.pi / 180
                    let turnedX = reflect(center.x + 64 * cos(turnedTheta) - 0.81 * Double(w), length: w)
                    let turnedY = reflect(center.y + 64 * sin(turnedTheta) + 0.77 * Double(h), length: h)
                    let turnedSource = at(picture, turnedX, h - 1 - turnedY)
                    for sector in 0..<count {
                        let local = count.isMultiple(of: 2) && !sector.isMultiple(of: 2) ? 1-fraction : fraction
                        let actual = probe(rendered, base + (Double(sector) + local) * span)
                        try check(abs(actual[0]-expected[0]) < 0.012 && abs(actual[1]-expected[1]) < 0.012, "Kaleidoscope sector \(sector)/\(count), \(w)×\(h), follows the off-center rotated source wedge")
                        let moved = probe(shifted, base + (Double(sector) + local) * span)
                        try check(abs(moved[0]-movedSource[0]) < 0.012 && abs(moved[1]-movedSource[1]) < 0.012,
                                  "Positive X and negative Y pan sample the translated picture including reflected borders in sector \(sector)/\(count)")
                        let rotated = probe(turned, base + (Double(sector) + local) * span)
                        try check(zip(rotated.prefix(2), turnedSource).allSatisfy { abs($0-$1) < 0.012 },
                                  "Source rotation samples the turned and panned picture inside the same sector \(sector)/\(count) at \(w)×\(h)")
                    }
                }
            }
        }
        for linearColor in [SIMD3<Double>(0.18,0.08,0.03), SIMD3<Double>(3.2,1.6,0.6)] {
            let patch = CIImage(color: CIColor(red: linearColor.x, green: linearColor.y, blue: linearColor.z, colorSpace: space)!).cropped(to: bounds)
            for intensity in [0.0, 0.4, 1] {
                var mirror = VideoEffectSettings(.kaleidoscope)
                mirror.set("intensity", .number(intensity))
                let sampled = at(try renderer.render(patch, effects: [mirror], sourceTime: 0, hdr: true), width/2, height/2)
                for channel in 0..<3 {
                    try check(abs(Double(sampled[channel])-linearColor[channel]) < 0.004, "Kaleidoscope preserves HDR midtones and highlights at every strength")
                }
            }
        }
        let vertical = try renderer.render(input, effects: [VideoEffectSettings(.kaleidoscope)], sourceTime: 0)
        for y in [8, height/2, height-9] {
            let preserved = at(input, width-18, y)
            for x in [17, width-18] {
                let actual = at(vertical, x, y)
                try check(zip(actual, preserved).allSatisfy { abs($0-$1) < 0.002 }, "Two divisions make one true vertical mirror")
            }
        }
        print("PASS: two-way reflection and every 2–9-way rotated, off-center split in portrait and landscape")
        let kept=at(isolated,width/2,height*3/4),removed=at(isolated,width/2,height/4)
        try check(kept[0]-kept[1]>0.4&&abs(removed[0]-removed[1])<0.005,"CV top-half mask keeps the top subject; no vertical flip")
        func constantMask(_ value:UInt8)->CVPixelBuffer {
            var pixel:CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault,width,height,kCVPixelFormatType_OneComponent8,[kCVPixelBufferMetalCompatibilityKey:true,kCVPixelBufferIOSurfacePropertiesKey:[:]] as CFDictionary,&pixel)
            CVPixelBufferLockBaseAddress(pixel!,[])
            let stride=CVPixelBufferGetBytesPerRow(pixel!),base=CVPixelBufferGetBaseAddress(pixel!)!.assumingMemoryBound(to:UInt8.self)
            for y in 0..<height {base.advanced(by:y*stride).initialize(repeating:value,count:width)}
            CVPixelBufferUnlockBaseAddress(pixel!,[]);return pixel!
        }
        func maskAt(_ pixel:CVPixelBuffer,_ x:Int=0,_ y:Int=0)->Double {
            CVPixelBufferLockBaseAddress(pixel,.readOnly);defer {CVPixelBufferUnlockBaseAddress(pixel,.readOnly)}
            return Double(CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to:UInt8.self)[y*CVPixelBufferGetBytesPerRow(pixel)+x])/255
        }
        let smoother=try VideoEffectMaskSmoother(),low=constantMask(51),high=constantMask(204),nearMask=constantMask(66)
        let staticGuide=CIImage(color:CIColor(red:0.2,green:0.2,blue:0.2,colorSpace:space)!).cropped(to:bounds)
        let equalLumaMotion=try VideoEffectMaskSmoother()
        _ = try equalLumaMotion.push(low,image:staticGuide,time:0,geometry:"equal-luma",motionGate:true)
        let changedSilhouette=try equalLumaMotion.push(high,image:staticGuide,time:1.0/30,geometry:"equal-luma",motionGate:true)
        try check(abs(maskAt(changedSilhouette)-0.8)<0.005,"A strong silhouette change must follow immediately even when foreground and background have the same luma")
        let heldMask=try smoother.push(low,image:staticGuide,time:0,geometry:"front",motionGate:true)
        let smoothed=try smoother.push(nearMask,image:staticGuide,time:1.0/30,geometry:"front",motionGate:true)
        try check(abs(maskAt(smoothed)-(51+0.3*15)/255)<0.005,"Static mask EMA uses alpha 0.3")
        _ = try smoother.push(nearMask,image:staticGuide,time:2.0/30,geometry:"front",motionGate:true)
        try check(abs(maskAt(heldMask)-0.2)<0.005 && abs(maskAt(smoothed)-(51+0.3*15)/255)<0.005,"Published CV masks remain immutable across later frames")
        let jump=try smoother.push(high,image:CIImage(color:.white).cropped(to:bounds),time:0.1,geometry:"front",motionGate:true)
        try check(abs(maskAt(jump)-0.8)<0.005,"Scene change resets the whole mask history")
        let backward=try smoother.push(low,image:staticGuide,time:0,geometry:"front",motionGate:true)
        let lens=try smoother.push(high,image:staticGuide,time:1.0/30,geometry:"rear",motionGate:true)
        let gap=try smoother.push(low,image:staticGuide,time:1,geometry:"rear",motionGate:true)
        try check(abs(maskAt(backward)-0.2)<0.005 && abs(maskAt(lens)-0.8)<0.005 && abs(maskAt(gap)-0.2)<0.005,"Seek, lens change and interruption reset temporal masks")
        let movingGuide=CIImage(color:CIColor(red:0.27,green:0.27,blue:0.27,colorSpace:space)!).cropped(to:CGRect(x:0,y:height/2,width:width,height:height/2)).composited(over:staticGuide)
        let moving=try smoother.push(nearMask,image:movingGuide,time:1+1.0/30,geometry:"rear",motionGate:true)
        try check(abs(maskAt(moving,width/2,height/4)-66.0/255)<0.005 && abs(maskAt(moving,width/2,height*3/4)-(51+0.3*15)/255)<0.005,"Moving top edge follows immediately; stationary bottom edge is smoothed without coordinate inversion")
        let autoSmoother=try VideoEffectMaskSmoother()
        _ = try autoSmoother.push(low,image:staticGuide,time:0,geometry:"auto",motionGate:true)
        let autoEMA=try autoSmoother.push(nearMask,image:movingGuide,time:1.0/30,geometry:"auto",motionGate:true)
        try check(abs(maskAt(autoEMA,width/2,height/4)-66.0/255)<0.005 && abs(maskAt(autoEMA,width/2,height*3/4)-(51+0.3*15)/255)<0.005,"Auto Background follows moving edges without leaving the old silhouette behind, while static edges stay smoothed")
        let skins=[EffectRGB(0.82,0.65,0.52),EffectRGB(0.60,0.45,0.35),EffectRGB(0.36,0.25,0.20)]
        func hue(_ color:EffectRGB)->Double {
            let r=color.red,g=color.green,b=color.blue,high=max(r,max(g,b)),low=min(r,min(g,b)),span=high-low
            guard span>1e-8 else{return 0}
            let value=high==r ? (g-b)/span : high==g ? (b-r)/span+2 : (r-g)/span+4
            return (value*60+360).truncatingRemainder(dividingBy:360)
        }
        for skin in skins {
            let c=EffectColorMath.linear(skin),patch=CIImage(color:CIColor(red:c.x,green:c.y,blue:c.z,colorSpace:space)!).cropped(to:bounds)
            let rendered=try renderer.render(patch,effects:[VideoEffectSettings(.threeStrip)],sourceTime:0),p=at(rendered,width/2,height/2)
            let encoded=EffectColorMath.rgb(SIMD3(Double(p[0]),Double(p[1]),Double(p[2]))),difference=abs(hue(encoded)-hue(skin))
            try check(min(difference,360-difference)<=8,"Three-Strip stays within eight degrees of each reference skin hue")
        }
        for kind in [VideoEffectID.silentTint,.noir,.expressionism] {
            for skin in skins {
                let c=EffectColorMath.linear(skin),patch=CIImage(color:CIColor(red:c.x,green:c.y,blue:c.z,colorSpace:space)!).cropped(to:bounds)
                var effect=VideoEffectSettings(kind);if kind == .noir {effect.set("grain",.toggle(false))}
                let result=try renderer.render(patch,effects:[effect],sourceTime:0),value=at(result,width/2,height/2)
                try check(value[0]+value[1]+value[2]>0.0005,"Default \(kind) retains shadow detail in all three skin patches")
            }
        }
        var tiny=VideoEffectSettings(.silentTint);tiny.set("intensity",.number(0.001))
        let near=try renderer.render(input,effects:[tiny],sourceTime:0),nearPixels=pixels(near)
        try check(zip(source,nearPixels).allSatisfy{abs($0-$1)<0.002},"GPU intensity blend approaches the SDR source continuously")
        let bright=CIImage(color:CIColor(red:2,green:1.5,blue:0.8,colorSpace:space)!).cropped(to:bounds)
        tiny.set("intensity",.number(0))
        let hdrZero=pixels(try renderer.render(bright,effects:[tiny],sourceTime:0,hdr:true))
        tiny.set("intensity",.number(0.001))
        let hdrNear=pixels(try renderer.render(bright,effects:[tiny],sourceTime:0,hdr:true))
        try check(zip(hdrZero,hdrNear).allSatisfy{abs($0-$1)<0.002},"HDR intensity remains continuous at zero inside the SDR working space")
        tiny.enabled=false
        let hdrBypass=pixels(try renderer.render(bright,effects:[tiny],sourceTime:0,hdr:true))
        try check(hdrBypass==pixels(bright),"Disabling the entire look restores the untouched HDR image")
        var crash=VideoEffectSettings(.crashZoom,start:0,end:10);crash.set("trackFace",.toggle(false));crash.releaseTime=2.1
        var carried=crash;carried.phaseOffset=2;carried.releaseTime=0.1
        for time in [0.0,0.05,0.15,0.25] {
            let full=try renderer.render(input,effects:[crash],sourceTime:2+time)
            let resumed=try renderer.render(input,effects:[carried],sourceTime:time)
            try check(pixels(full)==pixels(resumed),"Crash Zoom preserves the exact phase and manual return when Record starts mid-move")
        }
        var freezeContext=FrameContext(presentationTime:2,frameIndex:60);freezeContext.holdTime=0.05
        let frozenCrash=try renderer.render(input,effects:[crash],sourceTime:2,frameContext:freezeContext)
        let existingCrash=try renderer.render(input,effects:[crash],sourceTime:2)
        try check(pixels(frozenCrash)==pixels(existingCrash),"Freezing a zoomed frame preserves camera phase rather than restarting its push")
        let grid=input
        var framing=crash;framing.releaseTime=nil;framing.set("zoom",.number(1.5));framing.set("motionBlur",.number(0))
        var aimed=crash;aimed.releaseTime=nil;aimed.set("targetX",.number(0.25));aimed.set("targetY",.number(0.6));aimed.set("motionBlur",.number(0))
        for chain in [[aimed,framing],[framing,aimed]] {
            let warped=try renderer.render(grid,effects:chain,sourceTime:1)
            let inverse=VideoEffectGeometry.transform(chain,time:1,size:bounds.size).inverted()
            for x in [width/3,width/2,width*2/3] {
                let y=height/2,point=CGPoint(x:(Double(x)+0.5)/Double(width),y:1-(Double(y)+0.5)/Double(height)).applying(inverse)
                let expected=at(grid,Int(point.x*Double(width)),Int((1-point.y)*Double(height))),actual=at(warped,x,y)
                try check(abs(expected[0]-actual[0])<0.02 && abs(expected[1]-actual[1])<0.02,"Target geometry agrees with actual chained Metal camera transforms")
            }
        }
        // The subject sits off-centre so a stale base-space mask cannot pass.
        let region=CGRect(x:width/5,y:height/3,width:width/4,height:height/3)
        let grey=CIImage(color:CIColor(red:0.15,green:0.15,blue:0.15,colorSpace:space)!).cropped(to:bounds)
        let subject=CIImage(color:CIColor(red:0.8,green:0.08,blue:0.03,colorSpace:space)!).cropped(to:region).composited(over:grey)
        let silhouette=CIImage(color:.white).cropped(to:region).composited(over:CIImage(color:.black).cropped(to:bounds))
        let subjectMask=try renderer.texture(width:width,height:height,format:.r16Float)
        renderer.context.render(MetalEffectRenderer.textureImage(silhouette),to:subjectMask,commandBuffer:nil,bounds:bounds,colorSpace:space)
        var isolate=VideoEffectSettings(.colorIsolation);isolate.set("mode",.choice("The subject"));isolate.set("softness",.number(0))
        var maskContext=FrameContext(presentationTime:1,frameIndex:30,personMask:subjectMask);maskContext.matteHistory=[]
        var maskZoom=aimed;maskZoom.set("targetX",.number(0.35));maskZoom.set("targetY",.number(0.5))
        var pattern = VideoEffectSettings(.kaleidoscope)
        pattern.set("splitAngle", .number(180))
        pattern.set("sourcePanX", .number(-0.12)); pattern.set("sourcePanY", .number(0.08))
        for camera in [[framing],[maskZoom],[framing,maskZoom],[maskZoom,framing],[pattern]] {
            let reference=pixels(try renderer.render(subject,effects:camera,sourceTime:1))
            let actual=pixels(try renderer.render(subject,effects:camera+[isolate],sourceTime:1,frameContext:maskContext))
            var retained=0,total=0
            for i in stride(from:0,to:actual.count,by:4) where reference[i]-reference[i+1]>0.4 {
                total+=1;if actual[i]-actual[i+1]>0.35 {retained+=1}
            }
            try check(total>100 && Double(retained)/Double(total)>0.97,"Subject mask follows ordered camera transforms: \(camera.map(\.kind)), kept \(retained)/\(total)")
        }
        let baseCentre=CGPoint(x:region.midX/Double(width),y:1-region.midY/Double(height))
        var centreZoom=aimed;centreZoom.set("zoom",.number(1.5));centreZoom.set("targetX",.number(baseCentre.x));centreZoom.set("targetY",.number(baseCentre.y))
        func centroid(_ samples:[Float])->CGPoint {
            var sx=0.0,sy=0.0,total=0.0
            for y in 0..<height {for x in 0..<width {let i=(y*width+x)*4,w=Double(max(0,samples[i]-samples[i+1]));sx+=(Double(x)+0.5)*w;sy+=(Double(y)+0.5)*w;total+=w}}
            return CGPoint(x:sx/total,y:sy/total)
        }
        let centreSubject=CIImage(color:CIColor(red:0.8,green:0.08,blue:0.03,colorSpace:space)!).cropped(to:region.insetBy(dx:25,dy:20)).composited(over:grey)
        let framedCentre=centroid(pixels(try renderer.render(centreSubject,effects:[framing],sourceTime:1)))
        let zoomedCentre=centroid(pixels(try renderer.render(centreSubject,effects:[framing,centreZoom],sourceTime:1)))
        let predicted=baseCentre.applying(VideoEffectGeometry.transform([framing,centreZoom],time:1,size:bounds.size))
        try check(hypot(framedCentre.x-zoomedCentre.x,framedCentre.y-zoomedCentre.y)<1 && hypot(predicted.x*Double(width)-zoomedCentre.x,predicted.y*Double(height)-zoomedCentre.y)<1,"A zoom targeted at the subject after a preceding zoom keeps its centroid fixed, matching live target picking: \(framedCentre), \(zoomedCentre), \(predicted)")
        // A disparity ramp with an invalid corner catches orientation swaps,
        // accidental gamma conversion and invalid-as-far depth handling.
        let dw=32,dh=18,rawDepth=try renderer.texture(width:32,height:18,shared:true,format:.r16Float)
        var ramp=(0..<(dw*dh)).map {Float16(Float($0%dw+3*($0/dw))/100).bitPattern};ramp[0]=Float16.nan.bitPattern
        ramp.withUnsafeBytes {rawDepth.replace(region:MTLRegionMake2D(0,0,dw,dh),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:dw*2)}
        let rotate=CGAffineTransform(a:0,b:1,c:-1,d:0,tx:Double(dh),ty:0)
        let placedDepth=try renderer.placeDepth(rawDepth,source:CGSize(width:dw,height:dh),canvas:CGSize(width:dh,height:dw),transform:rotate,range:0...1)
        let readback=renderer.device.makeBuffer(length:256*dw,options:.storageModeShared)!,readCommand=renderer.queue.makeCommandBuffer()!,blit=readCommand.makeBlitCommandEncoder()!
        blit.copy(from:placedDepth,sourceSlice:0,sourceLevel:0,sourceOrigin:MTLOrigin(x:0,y:0,z:0),sourceSize:MTLSize(width:dh,height:dw,depth:1),to:readback,destinationOffset:0,destinationBytesPerRow:256,destinationBytesPerImage:256*dw);blit.endEncoding();readCommand.commit();readCommand.waitUntilCompleted()
        let placed=readback.contents().assumingMemoryBound(to:UInt16.self)
        for y in 0..<dw {for x in 0..<dh {
            let sourceX=dw-1-y,sourceY=x,index=y*128+x*2
            if sourceX==0 && sourceY==0 {try check(Float16(bitPattern:placed[index+1])==0,"Invalid disparity retains its validity flag after rotation")}
            else {try check(abs(Float(Float16(bitPattern:placed[index]))-Float(sourceX+3*sourceY)/100)<0.001 && Float16(bitPattern:placed[index+1])==1,"Depth placement follows portrait video orientation without gamma conversion")}
        }}
        var detail:[Float]=[],depthValues:[UInt16]=[]
        for y in 0..<height {for x in 0..<width {
            let near=x>=width/2,value:Float=(x+y)%2==0 ? 0.8 : 0.02
            detail += [value,value,value,1];depthValues += [Float16(near ? 0.8 : 0.1).bitPattern,Float16(1).bitPattern]
        }}
        let sharp=CIImage(bitmapData:detail.withUnsafeBytes {Data($0)},bytesPerRow:width*16,size:bounds.size,format:.RGBAf,colorSpace:space)
        let depthMap=try renderer.texture(width:width,height:height,shared:true,format:.rg16Float)
        depthValues.withUnsafeBytes {depthMap.replace(region:MTLRegionMake2D(0,0,width,height),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:width*4)}
        var wide=VideoEffectSettings(.widescreen);wide.set("flares",.number(0));wide.set("ovalBokeh",.toggle(true))
        let depthFrame=FrameContext(presentationTime:1,frameIndex:30,depthMap:depthMap,depthFocus:0.8)
        let defocused=pixels(try renderer.render(sharp,effects:[wide],sourceTime:1,frameContext:depthFrame)),originalDetail=pixels(sharp)
        var farChange:Float=0,nearChange:Float=0,count:Float=0
        for y in 60..<120 {for x in 40..<120 {let a=(y*width+x)*4,b=(y*width+x+160)*4;farChange+=abs(defocused[a]-originalDetail[a]);nearChange+=abs(defocused[b]-originalDetail[b]);count+=1}}
        try check(farChange/count>0.15 && nearChange/count<0.002,"Oval aperture blurs only behind the Cinematic focus plane")
        let withoutDepth=pixels(try renderer.render(sharp,effects:[wide],sourceTime:1))
        wide.set("ovalBokeh",.toggle(false))
        let plainWide=pixels(try renderer.render(sharp,effects:[wide],sourceTime:1))
        try check(withoutDepth==plainWide,"Missing depth leaves Widescreen unchanged even with a saved bokeh setting")
        var depthDolly=VideoEffectSettings(.dollyZoom);depthDolly.set("targetX",.number(0.7))
        let depthDollyResult=pixels(try renderer.render(subject,effects:[depthDolly],sourceTime:1,frameContext:depthFrame))
        try check(depthDollyResult.allSatisfy(\.isFinite),"Imported depth supports Dolly Zoom without a person mask")
        // Replacement media must not inherit sharp patches belonging to objects
        // in the OLD background. Its virtual plane lies behind the original.
        let backdrop=try renderer.texture(width:width,height:height)
        renderer.context.render(MetalEffectRenderer.textureImage(sharp),to:backdrop,commandBuffer:nil,bounds:bounds,colorSpace:space)
        var replace=VideoEffectSettings(.autoBackground);replace.set("background",.choice("Image"));replace.set("wrap",.number(0));replace.set("softness",.number(0))
        wide.set("ovalBokeh",.toggle(true))
        let replacementMask=try constant(0)
        let compositeFrame=FrameContext(presentationTime:1,frameIndex:30,personMask:replacementMask,depthMap:depthMap,depthFocus:0.8,background:backdrop)
        let composite=pixels(try renderer.render(sharp,effects:[replace,wide],sourceTime:1,frameContext:compositeFrame))
        var replacedLeft:Float=0,replacedRight:Float=0
        for y in 60..<120 {for x in 40..<120 {let a=(y*width+x)*4,b=(y*width+x+160)*4;replacedLeft+=abs(composite[a]-0.41);replacedRight+=abs(composite[b]-0.41)}}
        try check(replacedLeft/count<0.1 && replacedRight/count<0.1 && abs(replacedLeft-replacedRight)/count<0.01,"A replaced background has uniform defocus instead of preserving the old scene's near-depth patches")
        if ProcessInfo.processInfo.environment["YOUREC_GPU_FOCUSED"] == nil {
        // Thirty seconds of a stationary portrait with small deterministic
        // sensor-like grain. Count palette recomputes too, including startup.
        let photograph=CIImage(contentsOf:URL(fileURLWithPath:"Tests/Fixtures/astronaut.png"))!
        let portrait=photograph.cropped(to:CGRect(x:0,y:224,width:512,height:288)).transformed(by:CGAffineTransform(translationX:0,y:-224)).transformed(by:CGAffineTransform(scaleX:Double(width)/512,y:Double(height)/288))
        var sensor=VideoEffectSettings(.sixteenMM);sensor.set("grain",.number(0.03));sensor.set("softness",.number(0));sensor.set("weave",.number(0))
        var palette:EffectPalette?,lastSource:[Float]?,lastOutput:[Float]?,sourceChange=0.0,outputChange=0.0
        var quantized=VideoEffectSettings(.quantization);quantized.set("colors",.number(4))
        for frame in 0..<900 {
            try autoreleasepool {
                let time=Double(frame)/30
                let noisy=try renderer.render(portrait,effects:[sensor],sourceTime:time)
                if frame.isMultiple(of:6) {
                    let reduced=noisy.transformed(by:CGAffineTransform(scaleX:64/Double(width),y:36/Double(height)))
                    var sample=[Float](repeating:0,count:64*36*4)
                    renderer.context.render(reduced,toBitmap:&sample,rowBytes:64*16,bounds:CGRect(x:0,y:0,width:64,height:36),format:.RGBAf,colorSpace:space)
                    let colors=stride(from:0,to:sample.count,by:4).map { SIMD3(Double(sample[$0]),Double(sample[$0+1]),Double(sample[$0+2])) }
                    palette=EffectPaletteAnalysis.analyze(colors,count:4,previous:palette,elapsed:0.2,seed:UInt64(frame))
                }
                let result=try renderer.render(noisy,effects:[quantized],sourceTime:time,frameContext:FrameContext(presentationTime:time,frameIndex:frame,personMask:fullMask,palette:palette))
                let inputPixels=pixels(noisy),outputPixels=pixels(result)
                if let previous=lastSource,let previousOutput=lastOutput {
                    sourceChange += zip(previous,inputPixels).reduce(0.0){$0+Double(abs($1.0-$1.1))}
                    outputChange += zip(previousOutput,outputPixels).reduce(0.0){$0+Double(abs($1.0-$1.1))}
                }
                lastSource=inputPixels;lastOutput=outputPixels
            }
        }
        print("Quantization static-portrait flicker ratio: \(outputChange/max(0.000001,sourceChange))")
        try check(outputChange<=sourceChange*1.1,"Quantization does not amplify frame-to-frame flicker by more than 10% on the stationary portrait")
        }
        print("PASS: asymmetric CV mask, three skin tones and nonzero GPU intensity blend")
        print("PASS: GPU linear-color reference, repeatability, intensity bypass and key-edge premultiplication")
    }
}
