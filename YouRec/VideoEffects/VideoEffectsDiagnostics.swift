#if DEBUG
import AVFoundation
import CoreImage
import Foundation
import UIKit
import Metal

@MainActor enum VideoEffectsDiagnostics {
    // Real Log input supplied in a diagnostics folder, never a user project.
    static func logRecovery() async {
        let documents=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
        let root=documents.appendingPathComponent("LogRecoveryQA/run-"+UUID().uuidString)
        var report:[String:Any]=["status":"running"]
        func check(_ value:Bool,_ message:String)throws {if !value {throw NSError(domain:"LogRecoveryQA",code:1,userInfo:[NSLocalizedDescriptionKey:message])}}
        RecordingAppDelegate.keepAwake("log-recovery-qa",active:true)
        defer {
            RecordingAppDelegate.keepAwake("log-recovery-qa",active:false)
            if let data=try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) {try? data.write(to:root.appendingPathComponent("report.json"),options:.atomic)}
        }
        do {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            try root.lastPathComponent.write(to:documents.appendingPathComponent("LogRecoveryQA/latest.txt"),atomically:true,encoding:.utf8)
            let source=root.appendingPathComponent("source.mov")
            try FileManager.default.copyItem(at:documents.appendingPathComponent("LogRecoveryQA/input.mov"),to:source)
            let asset=AVURLAsset(url:source),track=try await asset.loadTracks(withMediaType:.video).first!
            let formats=try await track.load(.formatDescriptions)
            try check(formats.contains {LogColor.profile($0) != nil},"Fixture must be real Log footage")
            let length=try await asset.load(.duration).seconds
            var project=Project(title:"Log recovery QA");project.append(SourceMedia(filename:"source.mov",duration:length))
            let context=CIContext(options:[.cacheIntermediates:false]),space=CGColorSpace(name:CGColorSpace.sRGB)!
            var frameErrors:[Double]=[],exportTimes:[Double]=[]
            for strength in [0.0,0.5,1.0] {
                var edit=project.edit;edit.clips[0].color=ColorSettings(localRecovery:strength);project.commit(edit)
                let media=try await MediaRenderer.timeline(project:project,folder:root)
                let preview=AVAssetImageGenerator(asset:media.composition);preview.videoComposition=media.videoComposition
                preview.maximumSize=CGSize(width:1080,height:1920);preview.requestedTimeToleranceBefore = .zero;preview.requestedTimeToleranceAfter = .zero
                let output=root.appendingPathComponent("recovery-\(strength).mov"),start=Date()
                _ = try await MediaRenderer.render(project:project,folder:root,destination:output) {_ in}
                exportTimes.append(Date().timeIntervalSince(start))
                let rendered=AVURLAsset(url:output),export=AVAssetImageGenerator(asset:rendered);export.appliesPreferredTrackTransform=true
                export.maximumSize=preview.maximumSize;export.requestedTimeToleranceBefore = .zero;export.requestedTimeToleranceAfter = .zero
                try check(abs(try await rendered.load(.duration).seconds-length)<0.04,"Recovery changed clip duration")
                try check(!(try await rendered.loadTracks(withMediaType:.audio)).isEmpty,"Recovery export lost audio")
                for time in [0.0,1.0,3.0] {
                    let stamp=CMTime(seconds:time,preferredTimescale:600),a=try await preview.image(at:stamp).image,b=try await export.image(at:stamp).image
                    func pixels(_ cg:CGImage)->[UInt8] {var p=[UInt8](repeating:0,count:a.width*a.height*4);context.render(CIImage(cgImage:cg),toBitmap:&p,rowBytes:a.width*4,bounds:CGRect(x:0,y:0,width:a.width,height:a.height),format:.RGBA8,colorSpace:space);return p}
                    let pa=pixels(a),pb=pixels(b),error=zip(pa,pb).reduce(0.0) {$0+abs(Double($1.0)-Double($1.1))}/Double(pa.count)
                    frameErrors.append(error);try check(error<3,"Preview/export mismatch: \(error)")
                    try UIImage(cgImage:a).pngData()?.write(to:root.appendingPathComponent("preview-\(strength)-\(time).png"))
                }
            }
            let reader=try VideoEffectSourceReader(url:source,hdr:false,capacity:2),image=try reader.frame(at:1)
            let recovered=LogColor.display(LogColor.localRecovery(image,amount:1))
            var times:[Double]=[]
            for index in 0..<12 {
                let start=Date()
                guard context.createCGImage(recovered,from:recovered.extent) != nil else {throw ProjectError.invalidMedia}
                if index>1 {times.append(Date().timeIntervalSince(start)*1000)}
            }
            report=["status":"passed","previewExportMeanByteErrors":frameErrors,"exportSecondsAt0_50_100":exportTimes,"fullResolutionRenderMedianMS":times.sorted()[times.count/2],"width":image.extent.width,"height":image.extent.height]
        } catch {report=["status":"failed","error":error.localizedDescription]}
    }
    // The real live worker, with deliberately slow known segmentation. Alternating
    // subject positions makes an old-frame mask visibly cut out the wrong region.
    static func liveMaskPairing() async {
        let documents=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
        let root=documents.appendingPathComponent("LiveMaskQA-"+UUID().uuidString)
        var report:[String:Any]=["status":"running"]
        RecordingAppDelegate.keepAwake("live-mask-qa",active:true)
        defer {
            RecordingAppDelegate.keepAwake("live-mask-qa",active:false)
            if let data=try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) {try? data.write(to:root.appendingPathComponent("report.json"),options:.atomic)}
        }
        do {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            try root.lastPathComponent.write(to:documents.appendingPathComponent("live-mask-qa-latest.txt"),atomically:true,encoding:.utf8)
            let worker=LiveVideoEffects(),ci=CIContext(options:[.cacheIntermediates:false]),space=CGColorSpace(name:CGColorSpace.sRGB)!
            let bounds=CGRect(x:0,y:0,width:320,height:240)
            func pixel(_ format:OSType)throws->CVPixelBuffer {
                var p:CVPixelBuffer?
                guard CVPixelBufferCreate(kCFAllocatorDefault,320,240,format,[kCVPixelBufferMetalCompatibilityKey:true,kCVPixelBufferIOSurfacePropertiesKey:[:]] as CFDictionary,&p)==kCVReturnSuccess,let p else {throw VideoEffectError.buffer}
                return p
            }
            worker.probePersonMask={ image in
                Thread.sleep(forTimeInterval:0.08)
                let mask=try pixel(kCVPixelFormatType_OneComponent8)
                ci.render(image.applyingFilter("CIColorThreshold",parameters:["inputThreshold":0.75]),to:mask,bounds:bounds,colorSpace:nil)
                return mask
            }
            var effect=VideoEffectSettings(.autoBackground)
            effect.set("background",.choice("Solid"));effect.set("backgroundColor",.color(EffectRGB(0.05,0.1,0.5)));effect.set("softness",.number(0));effect.set("wrap",.number(0))
            var delivered=0,index=0,samples:[Double]=[]
            worker.onFrame={image,_,_,_,_,_,_,_ in
                guard let image else {return}
                let x=index.isMultiple(of:2) ? 75 : 245
                var p=[Float](repeating:0,count:4)
                ci.render(image,toBitmap:&p,rowBytes:16,bounds:CGRect(x:x,y:120,width:1,height:1),format:.RGBAf,colorSpace:space)
                samples.append(Double(p[0]));delivered+=1
                if let cg=ci.createCGImage(image,from:bounds) {try? UIImage(cgImage:cg).pngData()?.write(to:root.appendingPathComponent("frame-\(index).png"))}
            }
            worker.configure([effect])
            for frame in 0..<6 {
                index=frame
                let rectangle=CGRect(x:frame.isMultiple(of:2) ? 40 : 210,y:40,width:70,height:160)
                let image=CIImage(color:.white).cropped(to:rectangle).composited(over:CIImage(color:CIColor(red:0.2,green:0.2,blue:0.2)).cropped(to:bounds))
                let p=try pixel(kCVPixelFormatType_32BGRA);ci.render(image,to:p,bounds:bounds,colorSpace:space)
                let before=delivered,deadline=Date().addingTimeInterval(10)
                worker.submit(p,time:Double(frame)/5,recording:false,angle:0,mirrored:false)
                while delivered==before && Date()<deadline {try await Task.sleep(for:.milliseconds(10))}
                guard delivered>before else {throw VideoEffectError.unavailableMask}
                try await Task.sleep(for:.milliseconds(120))
            }
            report["subjectRedValues"]=samples;report["metrics"]=await worker.metrics()
            worker.configure([])
            guard samples.count==6,samples.dropFirst().allSatisfy({$0>0.8}) else {throw NSError(domain:"LiveMaskQA",code:1,userInfo:[NSLocalizedDescriptionKey:"A previous frame's silhouette cut out the moving subject"])}
            report["status"]="passed"
        } catch {report["status"]="failed";report["error"]=error.localizedDescription}
    }
    // Deterministic media/Metal checks; no capture preferences or user projects.
    static func colorCorrection() async {
        let documents=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
        let root=documents.appendingPathComponent("EditorDiagnostics-Color-"+UUID().uuidString)
        var report:[String:Any]=["status":"running"]
        func check(_ value:Bool,_ message:String)throws {if !value {throw NSError(domain:"ColorCorrectionQA",code:1,userInfo:[NSLocalizedDescriptionKey:message])}}
        func save() {if let data=try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) {try? data.write(to:root.appendingPathComponent("report.json"),options:.atomic)}}
        RecordingAppDelegate.keepAwake("color-correction-qa",active:true)
        defer {RecordingAppDelegate.keepAwake("color-correction-qa",active:false);save()}
        do {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            try root.lastPathComponent.write(to:documents.appendingPathComponent("color-correction-qa-latest.txt"),atomically:true,encoding:.utf8)
            guard let fixture=Bundle.main.url(forResource:"editor-fixture",withExtension:"mp4") else {throw ProjectError.missingMedia}
            try FileManager.default.copyItem(at:fixture,to:root.appendingPathComponent("source.mp4"))
            let length=min(4,try await AVURLAsset(url:fixture).load(.duration).seconds)
            var project=Project(title:"Color correction QA");project.append(SourceMedia(filename:"source.mp4",duration:length))
            var edit=TimelineEditing.split(project.edit,at:length/2)
            var effect=VideoEffectSettings(.colorCorrection,start:0,end:length/2)
            effect.set("contrast",.number(1.2));effect.set("saturation",.number(0));effect.set("shadows",.number(0.25))
            let exposure=effect.parameters.firstIndex {$0.id=="exposure"}!
            effect.parameters[exposure].setKeyframe(at:0,value:.number(-0.2));effect.parameters[exposure].setKeyframe(at:length/2,value:.number(0.5))
            edit.clips[0].videoEffects=[effect];project.commit(edit)
            var reopened=try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(project));reopened.undo();reopened.redo()
            try check(reopened.edit==project.edit,"Undo/Redo after reopening changed the correction")
            let media=try await MediaRenderer.timeline(project:project,folder:root)
            let generator=AVAssetImageGenerator(asset:media.composition);generator.videoComposition=media.videoComposition
            generator.maximumSize=CGSize(width:640,height:640);generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
            let output=root.appendingPathComponent("graded.mp4")
            _ = try await MediaRenderer.render(project:project,folder:root,destination:output) {_ in}
            let asset=AVURLAsset(url:output),export=AVAssetImageGenerator(asset:asset);export.appliesPreferredTrackTransform=true;export.maximumSize=generator.maximumSize
            export.requestedTimeToleranceBefore = .zero;export.requestedTimeToleranceAfter = .zero
            let context=CIContext(),space=CGColorSpace(name:CGColorSpace.sRGB)!
            var errors:[Double]=[],chromas:[Double]=[]
            for (index,time) in [length*0.125,length*0.375,length*0.75].enumerated() {
                let stamp=CMTime(seconds:time,preferredTimescale:600),preview=try await generator.image(at:stamp).image,actual=try await export.image(at:stamp).image
                func pixels(_ cg:CGImage)->[UInt8] {var bytes=[UInt8](repeating:0,count:preview.width*preview.height*4);context.render(CIImage(cgImage:cg),toBitmap:&bytes,rowBytes:preview.width*4,bounds:CGRect(x:0,y:0,width:preview.width,height:preview.height),format:.RGBA8,colorSpace:space);return bytes}
                let a=pixels(preview),b=pixels(actual),error=zip(a,b).reduce(0.0) {$0+abs(Double($1.0)-Double($1.1))}/Double(a.count)
                var chroma=0.0
                for pixel in stride(from:0,to:a.count,by:4) {chroma+=abs(Double(a[pixel])-Double(a[pixel+1]));chroma+=abs(Double(a[pixel+1])-Double(a[pixel+2]))}
                chroma/=Double(a.count/4)
                errors.append(error);chromas.append(chroma)
                try check(error<3,"Preview/export mismatch: \(error)")
                try check(index<2 ? chroma<2 : chroma>4,"Correction escaped its selected range or failed to apply")
                try UIImage(cgImage:preview).pngData()?.write(to:root.appendingPathComponent("preview-\(index).png"))
            }
            let duration=try await asset.load(.duration).seconds
            try check(abs(duration-length)<0.04,"Grading changed timeline duration")
            let renderer=try MetalEffectRenderer(),linear=CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
            var grade=VideoEffectSettings(.colorCorrection);grade.set("exposure",.number(0.3));grade.set("contrast",.number(1.15));grade.set("temperature",.number(0.2));grade.set("vibrance",.number(0.3));grade.set("hue",.number(5))
            var gpu:[Double]=[]
            for width in [1920,3840] {
                let height=width*9/16,input=try renderer.texture(width:width,height:height),out=try renderer.texture(width:width,height:height)
                let bounds=CGRect(x:0,y:0,width:width,height:height),image=CIImage(color:CIColor(red:0.12,green:0.3,blue:0.6,colorSpace:linear)!).cropped(to:bounds)
                renderer.context.render(image,to:input,commandBuffer:nil,bounds:bounds,colorSpace:linear)
                var times:[Double]=[]
                for i in 0..<24 {
                    renderer.beginEncoding();let command=renderer.queue.makeCommandBuffer()!
                    renderer.encode(grade,input:input,output:out,frame:FrameContext(presentationTime:0,frameIndex:0),commandBuffer:command)
                    command.commit();await command.completed();if let error=command.error {throw error}
                    if i>3 {times.append((command.gpuEndTime-command.gpuStartTime)*1000)}
                }
                gpu.append(times.sorted()[times.count/2])
                let live=CIImage(mtlTexture:out,options:[.colorSpace:linear])!,exportImage=try renderer.render(image,effects:[grade],sourceTime:0)
                func center(_ image:CIImage)->[Float] {var p=[Float](repeating:0,count:4);renderer.context.render(image,toBitmap:&p,rowBytes:16,bounds:CGRect(x:width/2,y:height/2,width:1,height:1),format:.RGBAf,colorSpace:linear);return p}
                try check(zip(center(live),center(exportImage)).allSatisfy {abs($0-$1)<0.001},"Direct live encode and export renderer disagree")
            }
            report=["status":"passed","previewExportMeanErrors":errors,"scopeChroma":chromas,"duration":duration,"persistentUndoRedo":true,"directLiveExportParity":true,"gpuMedianMilliseconds1080p4K":gpu]
        } catch {report=["status":"failed","error":error.localizedDescription]}
    }
    static func run(_ camera:CaptureController) async {
        let documents=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
        let root=documents.appendingPathComponent("VideoEffectsQA-"+UUID().uuidString,isDirectory:true)
        var report:[String:Any]=["status":"running","started":Date().description]
        let oldEffects=camera.videoEffects,oldQuality=camera.quality,oldHDR=camera.hdrEnabled,oldCallback=camera.onSegment
        let oldCameraSettings=UserDefaults.standard.dictionaryRepresentation().filter {$0.key.hasPrefix("camera.")}
        var originalCameraID=""
        var files:[URL]=[]
        var livePlates:[String]=[]
        RecordingAppDelegate.keepAwake("video-effects-qa",active:true)
        func save() {
            if let data=try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) {try? data.write(to:root.appendingPathComponent("report.json"),options:.atomic)}
        }
        func wait(_ predicate:()->Bool) async throws {
            let deadline=Date().addingTimeInterval(25)
            while !predicate() {if Date()>deadline {throw ProjectError.invalidMedia};try await Task.sleep(for:.milliseconds(100))}
        }
        defer {
            RecordingAppDelegate.keepAwake("video-effects-qa",active:false)
            camera.setVideoEffects(oldEffects);camera.setQuality(oldQuality);camera.setHDR(oldHDR);camera.onSegment=oldCallback
            camera.probeDollyMeasurement(distance:nil);camera.finishPausedTake()
            if !originalCameraID.isEmpty { camera.probeRestoreSettings(oldCameraSettings,cameraID:originalCameraID) }
            camera.cancelEffectFrameTools();camera.suspend()
            for file in livePlates { try? FileManager.default.removeItem(at:LiveVideoEffects.folder.appendingPathComponent(file)) }
            save()
        }
        do {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            try root.lastPathComponent.write(to:documents.appendingPathComponent("video-effects-qa-latest.txt"),atomically:true,encoding:.utf8)
            // Read format capabilities without changing the user's active lens,
            // resolution or HDR settings. Depth must not silently downgrade them.
            report["depthCapabilities"]=AVCaptureDevice.DiscoverySession(deviceTypes:[.builtInLiDARDepthCamera,.builtInTrueDepthCamera],mediaType:.video,position:.unspecified).devices.map {device -> [String:Any] in
                let formats=device.formats.filter {!$0.supportedDepthDataFormats.isEmpty}.map {format -> [String:Any] in
                    let size=CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                    return ["width":size.width,"height":size.height,"fps":format.videoSupportedFrameRateRanges.map {[$0.minFrameRate,$0.maxFrameRate]},"hdr":format.supportedColorSpaces.contains(.HLG_BT2020),
                            "depth":format.supportedDepthDataFormats.map {depth -> [String:Any] in
                                let dimensions=CMVideoFormatDescriptionGetDimensions(depth.formatDescription)
                                return ["width":dimensions.width,"height":dimensions.height,"fps":depth.videoSupportedFrameRateRanges.map {[$0.minFrameRate,$0.maxFrameRate]},"format":CMFormatDescriptionGetMediaSubType(depth.formatDescription)]
                            }]
                }
                return ["camera":device.deviceType.rawValue,"position":device.position.rawValue,"formats":formats]
            }
            save()
            if CommandLine.arguments.contains("--video-effects-matting-only") {
                camera.suspend();_ = await camera.probeSnapshot()
                let sources=CommandLine.arguments.filter {$0.hasPrefix("--matting-source=")}.map {String($0.dropFirst("--matting-source=".count))}
                guard !sources.isEmpty else {throw ProjectError.invalidMedia}
                var results:[[String:Any]]=[]
                for (index,path) in sources.enumerated() {
                    report["stage"]="Recorded person \(index+1)";save()
                    let local=root.appendingPathComponent("person-\(index).mov")
                    try FileManager.default.copyItem(at:documents.appendingPathComponent(path),to:local)
                    let duration=try await AVURLAsset(url:local).load(.duration).seconds
                    var project=Project(title:"Person outline QA");project.append(SourceMedia(filename:local.lastPathComponent,duration:duration))
                    var effect=VideoEffectSettings(.autoBackground,start:0,end:duration)
                    effect.set("background",.choice("Solid"));effect.set("backgroundColor",.color(EffectRGB(0.05,0.2,0.45)));effect.set("wrap",.number(0))
                    var edit=project.edit;edit.clips[0].start=min(0.5,duration/4);edit.clips[0].end=min(edit.clips[0].start+2,duration)
                    edit.clips[0].videoEffects=[effect];project.commit(edit)
                    let media=try await MediaRenderer.timeline(project:project,folder:root)
                    guard let instruction=media.videoComposition.instructions.first as? VideoToolInstruction,let masks=instruction.effectMasks?.at(edit.clips[0].start) else {throw ProjectError.invalidMedia}
                    let reader=try EffectAnalysisReader(metadata:masks.metadata,data:masks.data)
                    guard reader.hasMotionAwareAutoBackground else {throw ProjectError.invalidMedia}
                    let generator=AVAssetImageGenerator(asset:media.composition);generator.videoComposition=media.videoComposition
                    generator.maximumSize=CGSize(width:960,height:960);generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
                    let first=try await generator.image(at:CMTime(seconds:0.3,preferredTimescale:600)).image
                    _ = try await generator.image(at:CMTime(seconds:1.3,preferredTimescale:600))
                    let again=try await generator.image(at:CMTime(seconds:0.3,preferredTimescale:600)).image
                    guard UIImage(cgImage:first).pngData()==UIImage(cgImage:again).pngData() else {throw ProjectError.invalidMedia}
                    try UIImage(cgImage:first).pngData()?.write(to:root.appendingPathComponent("person-\(index)-preview.png"))
                    let output=root.appendingPathComponent("person-\(index)-export.mp4"),began=Date()
                    _ = try await MediaRenderer.render(project:project,folder:root,destination:output) {_ in}
                    let exported=AVURLAsset(url:output),preview=AVAssetImageGenerator(asset:exported);preview.appliesPreferredTrackTransform=true
                    preview.maximumSize=generator.maximumSize;preview.requestedTimeToleranceBefore = .zero;preview.requestedTimeToleranceAfter = .zero
                    let actual=try await preview.image(at:CMTime(seconds:0.3,preferredTimescale:600)).image
                    let context=CIContext(),w=first.width,h=first.height
                    func pixels(_ image:CGImage)->[UInt8] {var values=[UInt8](repeating:0,count:w*h*4);context.render(CIImage(cgImage:image),toBitmap:&values,rowBytes:w*4,bounds:CGRect(x:0,y:0,width:w,height:h),format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!);return values}
                    let error=zip(pixels(first),pixels(actual)).reduce(0.0){$0+abs(Double($1.0)-Double($1.1))}/Double(w*h*4)
                    guard error<3 else {throw NSError(domain:"PersonQA",code:1,userInfo:[NSLocalizedDescriptionKey:"Person export differs from preview by \(error)."])}
                    results.append(["case":index,"meanPixelError":error,"seekStable":true,"exportSeconds":Date().timeIntervalSince(began),"exportDuration":try await exported.load(.duration).seconds,"maskWidth":reader.analysis.masks.first?.width ?? 0,"maskHeight":reader.analysis.masks.first?.height ?? 0]);report["personRenders"]=results;save()
                    effect.set("view",.choice("Matte"));edit.clips[0].videoEffects=[effect];project.commit(edit)
                    let matte=try await MediaRenderer.timeline(project:project,folder:root,previewDiagnostics:true),mattePreview=AVAssetImageGenerator(asset:matte.composition)
                    mattePreview.videoComposition=matte.videoComposition;mattePreview.maximumSize=generator.maximumSize
                    try UIImage(cgImage:try await mattePreview.image(at:CMTime(seconds:0.3,preferredTimescale:600)).image).pngData()?.write(to:root.appendingPathComponent("person-\(index)-matte.png"))
                }
                report["status"]="complete";save();return
            }
            if CommandLine.arguments.contains("--video-effects-depth-import-only") {
                camera.suspend();_ = await camera.probeSnapshot()
                guard let argument=CommandLine.arguments.first(where:{$0.hasPrefix("--depth-source=")}) else {throw ProjectError.invalidMedia}
                let url=documents.appendingPathComponent(String(argument.dropFirst("--depth-source=".count)))
                let local=root.appendingPathComponent("original.mov")
                try FileManager.default.copyItem(at:url,to:local)
                let duration=try await AVURLAsset(url:local).load(.duration).seconds
                var results:[[String:Any]]=[]
                for simulated in [false,true] {
                    report["stage"]=simulated ? "Depth Dolly and bokeh" : "Imported depth bokeh";save()
                    var wide=VideoEffectSettings(.widescreen,start:0,end:duration);wide.set("ovalBokeh",.toggle(true));wide.set("flares",.number(0))
                    var film=VideoEffectSettings(.sixteenMM,start:0,end:duration);film.set("grain",.number(0.2))
                    var project=Project(title:"Depth import QA");project.append(SourceMedia(filename:local.lastPathComponent,duration:duration))
                    var edit=project.edit;edit.clips[0].start=0.1;edit.clips[0].end=min(1.1,duration)
                    edit.clips[0].crop=CropSettings(rotation:12);edit.clips[0].videoEffects=simulated ? [VideoEffectSettings(.dollyZoom,start:0,end:duration),film,wide] : [wide];project.commit(edit)
                    let media=try await MediaRenderer.timeline(project:project,folder:root)
                    guard let instruction=media.videoComposition.instructions.first as? VideoToolInstruction,let depth=instruction.effectDepth,depth.aligned else {throw ProjectError.invalidMedia}
                    let generator=AVAssetImageGenerator(asset:media.composition);generator.videoComposition=media.videoComposition
                    generator.maximumSize=CGSize(width:320,height:320);generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
                    let first=try await generator.image(at:CMTime(seconds:0.2,preferredTimescale:600)).image
                    _ = try await generator.image(at:CMTime(seconds:0.7,preferredTimescale:600))
                    let again=try await generator.image(at:CMTime(seconds:0.2,preferredTimescale:600)).image
                    guard UIImage(cgImage:first).pngData()==UIImage(cgImage:again).pngData() else {throw NSError(domain:"DepthQA",code:1,userInfo:[NSLocalizedDescriptionKey:"Depth preview changed after a backward seek."])}
                    let name=simulated ? "dolly" : "bokeh",output=root.appendingPathComponent(name+".mp4")
                    _ = try await MediaRenderer.render(project:project,folder:root,destination:output) {_ in}
                    let exported=AVURLAsset(url:output),preview=AVAssetImageGenerator(asset:exported);preview.appliesPreferredTrackTransform=true
                    preview.maximumSize=generator.maximumSize;preview.requestedTimeToleranceBefore = .zero;preview.requestedTimeToleranceAfter = .zero
                    let actual=try await preview.image(at:CMTime(seconds:0.2,preferredTimescale:600)).image
                    try UIImage(cgImage:actual).pngData()?.write(to:root.appendingPathComponent(name+".png"))
                    let context=CIContext(),w=first.width,h=first.height
                    func pixels(_ image:CGImage)->[UInt8] {var values=[UInt8](repeating:0,count:w*h*4);context.render(CIImage(cgImage:image),toBitmap:&values,rowBytes:w*4,bounds:CGRect(x:0,y:0,width:w,height:h),format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!);return values}
                    let error=zip(pixels(first),pixels(actual)).reduce(0.0){$0+abs(Double($1.0)-Double($1.1))}/Double(w*h*4)
                    guard error<3 else {throw NSError(domain:"DepthQA",code:2,userInfo:[NSLocalizedDescriptionKey:"Depth export differs from preview by \(error)."])}
                    results.append(["case":name,"meanPixelError":error,"seekStable":true,"depthAligned":depth.aligned,"exportDuration":try await exported.load(.duration).seconds])
                    report["depthRenders"]=results;save()
                    if !simulated {
                        // Exercise the actual editor model on the signed app;
                        // this does not require a separate XCTest runner profile.
                        let request=ToolRequest(tool:.videoEffects,range:0...project.edit.duration,scopeTitle:"QA clip",effectID:wide.id)
                        let workspace=VideoEffectsWorkspace(project:project,folder:root,request:request,position:0)
                        workspace.rebuild(delay:false);try await wait {!workspace.busy && !workspace.refiningPreview}
                        guard workspace.hasDepth,workspace.error==nil,let parameter=workspace.current?.parameters.first(where:{$0.id=="ovalBokeh"}) else {throw ProjectError.invalidDocument}
                        workspace.set(parameter,.toggle(false));try await wait {!workspace.busy && !workspace.refiningPreview}
                        workspace.mutate {$0.enabled=false};try await wait {!workspace.busy && !workspace.refiningPreview}
                        guard workspace.hasDepth else {throw ProjectError.invalidDocument}
                        workspace.mutate {$0.enabled=true};try await wait {!workspace.busy && !workspace.refiningPreview}
                        workspace.set(parameter,.toggle(true));try await wait {!workspace.busy && !workspace.refiningPreview}
                        var saved=project;saved.commit(workspace.state);workspace.stop()
                        let reopened=try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(saved))
                        let reopenedWorkspace=VideoEffectsWorkspace(project:reopened,folder:root,request:request,position:0)
                        reopenedWorkspace.rebuild(delay:false);try await wait {!reopenedWorkspace.busy && !reopenedWorkspace.refiningPreview}
                        guard reopenedWorkspace.hasDepth,reopenedWorkspace.current?.toggle("ovalBokeh",at:0.1)==true,reopenedWorkspace.error==nil else {throw ProjectError.invalidDocument}
                        reopenedWorkspace.stop()
                        report["editorDepthControls"]=["available":true,"preservedWhileDisabled":true,"toggleAndReopen":true];save()
                    }
                }
                report["status"]="complete";save();return
            }
            if CommandLine.arguments.contains("--video-effects-cinematic-only") {
                camera.suspend();_ = await camera.probeSnapshot()
                report["stage"]="Cinematic source fixture";save()
                if #available(iOS 26.0,*) {
                    let probe=VideoEffectCinematicProbe(),url=try await probe.record(to:root.appendingPathComponent("cinematic-source.mov"))
                    guard let source=try await VideoEffectDepthCatalog.shared.source(url:url) else {throw ProjectError.invalidMedia}
                    let reader=VideoEffectDepthReader(source:source)
                    var frames:[[String:Any]]=[]
                    for time in [0.1,1.0,2.0,0.1,3.0] {
                        if let image=try reader.image(at:time) {frames.append(["time":time,"width":image.extent.width,"height":image.extent.height])}
                    }
                    report["depthFrames"]=frames;report["source"]=url.lastPathComponent;report["range"]=[source.range.start.seconds,source.range.duration.seconds]
                }
                report["status"]="complete";save();return
            }
            if CommandLine.arguments.contains("--video-effects-depth-only") {
                camera.suspend();_ = await camera.probeSnapshot()
                report["stage"]="depth capture";save()
                let results=await VideoEffectDepthProbe.run(folder:root) {values in report["depthProbe"]=values;save()}
                report["depthProbe"]=results;report["status"]="complete";save();return
            }
            report["stage"]="GPU probes";save()
            let gpu=try await Task.detached(priority:.userInitiated) { () throws -> [[String:Any]] in
                if CommandLine.arguments.contains("--video-effects-capture-only") { return [] }
                let renderer=try MetalEffectRenderer()
                var results:[[String:Any]]=[]
                for (width,height) in [(1920,1080),(3840,2160)] {
                    let bounds=CGRect(x:0,y:0,width:width,height:height)
                    let image=CIFilter(name:"CICheckerboardGenerator",parameters:["inputColor0":CIColor(red:0.6,green:0.3,blue:0.15),"inputColor1":CIColor(red:0.9,green:0.85,blue:0.8),"inputWidth":37])!.outputImage!.cropped(to:bounds)
                    let mask=try renderer.texture(width:256,height:144)
                    renderer.context.render(CIImage(color:.white).cropped(to:CGRect(x:0,y:0,width:256,height:144)),to:mask,commandBuffer:nil,bounds:CGRect(x:0,y:0,width:256,height:144),colorSpace:renderer.space)
                    let frame=FrameContext(presentationTime:0,frameIndex:0,personMask:mask,matteHistory:[])
                    for kind in VideoEffectID.allCases {
                        var times:[Double]=[],gpuTimes:[Double]=[]
                        for n in 0..<34 {
                            try autoreleasepool {
                                let start=ProcessInfo.processInfo.systemUptime
                                var lease:VideoEffectFrameLease?
                                _ = try renderer.render(image,effects:[VideoEffectSettings(kind)],sourceTime:Double(n)/30,frameContext:frame,lease:{lease=$0})
                                if n>3 {times.append(ProcessInfo.processInfo.systemUptime-start);gpuTimes.append(renderer.gpuSeconds)}
                                withExtendedLifetime(lease) {}
                            }
                        }
                        results.append(["effect":kind.rawValue,"width":width,"gpuMS":gpuTimes.sorted()[gpuTimes.count/2]*1000,"wallMeanMS":times.reduce(0,+)/Double(times.count)*1000])
                        let progress=try JSONSerialization.data(withJSONObject:results,options:[.prettyPrinted,.sortedKeys])
                        try progress.write(to:root.appendingPathComponent("gpu-progress.json"),options:.atomic)
                    }
                }
                return results
            }.value
            report["gpu"]=gpu;save()
            camera.onSegment={url,completion in files.append(url);completion(true)}
            camera.prepare();try await wait{camera.ready};originalCameraID=camera.cameraID
            if CommandLine.arguments.contains("--video-effects-front"),let front=camera.cameras.first(where:{$0.front && $0.available}) {
                camera.switchCamera(front.id);try await wait{camera.cameraID==front.id && !camera.switchingCamera}
            }
            let fourK=CommandLine.arguments.contains("--video-effects-4k")
            camera.setQuality(fourK ? .ultraHD4K : .hd1080);camera.setHDR(false);try await Task.sleep(for:.seconds(1))
            let cadenceQA=CommandLine.arguments.contains("--video-effects-cadence-only")
            let temporalQA=CommandLine.arguments.contains("--video-effects-temporal")
            let chains:[[VideoEffectID]]=cadenceQA ? [[.superEight],[.superEight,.undercranking]] : temporalQA ? [[.colorIsolation],[.chromaKey,.colorIsolation],[.chromaKey,.quantization,.sixteenMM]] : [[.silentTint,.sixteenMM],[.autoBackground,.halation,.widescreen],[.chromaKey,.quantization,.sixteenMM]]
            var recordings:[[String:Any]]=[]
            let sustained=CommandLine.arguments.contains("--video-effects-sustained")
            for run in 0..<(sustained ? 3 : 1) { for kinds in chains {
                report["stage"]="capture "+kinds.map(\.rawValue).joined(separator:"+");save()
                camera.setVideoEffects(kinds.map {kind in
                    var effect=VideoEffectSettings(kind)
                    if temporalQA && [.colorIsolation,.chromaKey].contains(kind) {effect.algorithm=2;effect.set("personHint",.toggle(false))}
                    // Empty-room segmentation is expected to remove the whole
                    // scene. A visible blue makes that distinguishable from a
                    // stopped camera; it has the same solid-fill render cost.
                    if [.chromaKey,.autoBackground].contains(kind) {effect.set("backgroundColor",.color(EffectRGB(hex:"#427CA6")))}
                    return effect
                })
                let thermalStart=ProcessInfo.processInfo.thermalState.rawValue
                let count=files.count
                camera.start(in:root);try await wait{camera.state == .recording}
                try await Task.sleep(for:.seconds(sustained ? 30 : 6))
                camera.stop();try await wait{camera.state == .idle && files.count>count}
                var result:[String:Any]=["run":run,"thermalStart":thermalStart,"chain":kinds.map(\.rawValue),"effects":await camera.videoEffectMetrics(),"capture":await camera.probeSnapshot(),"thermal":ProcessInfo.processInfo.thermalState.rawValue,"lowPower":ProcessInfo.processInfo.isLowPowerModeEnabled]
                let url=files.last!,asset=AVURLAsset(url:url),duration=try await asset.load(.duration).seconds
                let recordedTrack=try await asset.loadTracks(withMediaType:.video).first!
                let recordedSize=try await recordedTrack.load(.naturalSize)
                result["recordedWidth"]=recordedSize.width;result["recordedHeight"]=recordedSize.height
                if fourK && max(recordedSize.width,recordedSize.height)<3840 {throw NSError(domain:"EffectsQA",code:2,userInfo:[NSLocalizedDescriptionKey:"Adaptive preview changed the 4K recording size."])}
                let recipe=try JSONDecoder().decode([VideoEffectSettings].self,from:Data(contentsOf:url.deletingPathExtension().appendingPathExtension("effects.json")))
                var project=Project(title:"Video effects QA")
                project.append(SourceMedia(filename:url.lastPathComponent,duration:duration,videoEffects:recipe))
                try project.validate();try JSONEncoder().encode(project).write(to:root.appendingPathComponent("qa-\(count).json"),options:.atomic)
                let media=try await MediaRenderer.timeline(project:project,folder:root)
                if temporalQA {
                    let histories=media.videoComposition.instructions.compactMap {$0 as? VideoToolInstruction}.first?.effectMatteHistories ?? [:]
                    let expected=Set(recipe.filter(\.usesTemporalMatte).map(\.id))
                    guard Set(histories.keys)==expected,histories.values.allSatisfy({$0.finalized && $0.times.count>10}) else {throw NSError(domain:"EffectsQA",code:4,userInfo:[NSLocalizedDescriptionKey:"Captured temporal history could not be bound to its source frames."])}
                    result["temporalHistoryFrames"]=Dictionary(uniqueKeysWithValues:histories.map {($0.key.uuidString,$0.value.times.count)})
                    result["temporalResets"]=Dictionary(uniqueKeysWithValues:histories.map {($0.key.uuidString,$0.value.resets.count)})
                }
                let generator=AVAssetImageGenerator(asset:media.composition);generator.videoComposition=media.videoComposition;generator.maximumSize=CGSize(width:1280,height:1280)
                let rendered=try await generator.image(at:CMTime(seconds:min(2,duration/2),preferredTimescale:30))
                try UIImage(cgImage:rendered.image).pngData()?.write(to:root.appendingPathComponent("qa-\(count).png"),options:.atomic)
                if cadenceQA {
                    let clockTimes=try JSONDecoder().decode([Double].self,from:Data(contentsOf:url.deletingPathExtension().appendingPathExtension("effect-clock.json")))
                    let video=try await asset.loadTracks(withMediaType:.video).first!
                    result["sourceFPS"]=try await video.load(.nominalFrameRate)
                    result["sourceTimeScale"]=try await video.load(.naturalTimeScale)
                    let reader=try AVAssetReader(asset:asset),output=AVAssetReaderTrackOutput(track:video,outputSettings:nil)
                    reader.add(output);guard reader.startReading() else {throw ProjectError.invalidMedia}
                    var movieTimes:[Double]=[]
                    while let sample=output.copyNextSampleBuffer() {movieTimes.append(sample.presentationTimeStamp.seconds)}
                    guard reader.status == .completed else {throw reader.error ?? ProjectError.invalidMedia}
                    let error=clockTimes.map {clock in movieTimes.map {abs($0-clock)}.min() ?? 1}.max() ?? 1
                    result["liveClockMaximumError"]=error
                    guard error<0.000001 else {throw NSError(domain:"CadenceQA",code:1,userInfo:[NSLocalizedDescriptionKey:"The live effect clock differs from the recorded frame by \(error)s."])}
                    generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
                    generator.maximumSize=CGSize(width:320,height:320)
                    var held:[Int:Data]=[:],comparisons=0
                    let clock=VideoEffectSequenceClock(project.edit.clips[0])
                    for frame in 30..<60 {
                        let time=Double(frame)/30,source=project.edit.clips[0].sourceTime(at:time)
                        guard let index=clock.cadence.hold(at:source)?.index else {throw ProjectError.invalidMedia}
                        let image=try await generator.image(at:CMTime(value:Int64(frame),timescale:30)).image
                        guard let data=UIImage(cgImage:image).pngData() else {throw ProjectError.invalidMedia}
                        if let old=held[index] {
                            guard data==old else {throw NSError(domain:"CadenceQA",code:frame,userInfo:[NSLocalizedDescriptionKey:"A held frame changed its rendered look at frame \(frame)."])}
                            comparisons+=1
                        }
                        held[index]=data
                    }
                    guard comparisons>5 else {throw ProjectError.invalidMedia}
                    result["identicalHeldFrames"]=comparisons
                    let metrics=result["effects"] as! [String:Double]
                    guard (metrics["reusedHoldFrames"] ?? 0)>20,
                          metrics["previewFrames"] == (metrics["renderedFrames"] ?? 0)+(metrics["reusedHoldFrames"] ?? 0) else {throw NSError(domain:"CadenceQA",code:2,userInfo:[NSLocalizedDescriptionKey:"Held frames were rendered again instead of reused."])}
                }
                if fourK && kinds.contains(.quantization) {
                    report["stage"]="full-resolution 4K export";save()
                    let exported=root.appendingPathComponent("full-resolution-\(count).mov")
                    _ = try await MediaRenderer.render(project:project,folder:root,destination:exported) {_ in}
                    let exportedAsset=AVURLAsset(url:exported),exportedTrack=try await exportedAsset.loadTracks(withMediaType:.video).first!
                    let exportedSize=try await exportedTrack.load(.naturalSize),exportedDuration=try await exportedAsset.load(.duration).seconds
                    guard exportedSize==media.videoComposition.renderSize,max(exportedSize.width,exportedSize.height)>=3840,abs(exportedDuration-project.edit.duration)<1.0/30 else {throw NSError(domain:"EffectsQA",code:3,userInfo:[NSLocalizedDescriptionKey:"Adaptive preview changed export dimensions or duration."])}
                    result["exportedWidth"]=exportedSize.width;result["exportedHeight"]=exportedSize.height;result["exportedDuration"]=exportedDuration
                }
                result["reopenedFrame"]=true;result["duration"]=duration
                recordings.append(result);report["recordings"]=recordings;save()
            }
            }
            if CommandLine.arguments.contains("--video-effects-performance-only") { report["status"]="passed";return }
            report["stage"]="Crash Zoom lifecycle";save()
            var crash=VideoEffectSettings(.crashZoom);crash.set("trackFace",.toggle(false));crash.set("return",.toggle(false))
            camera.setVideoEffects([crash]);try await Task.sleep(for:.milliseconds(500))
            camera.triggerCrashZoom();try await wait { camera.crashState == .holding }
            let firstCount=files.count
            camera.start(in:root);try await wait { camera.state == .recording }
            try await Task.sleep(for:.seconds(1))
            camera.stop(pause:true);try await wait { camera.state == .paused && files.count>firstCount }
            guard camera.crashState == .holding else { throw ProjectError.invalidDocument }
            let firstURL=files.last!,firstRecipe=try JSONDecoder().decode([VideoEffectSettings].self,from:Data(contentsOf:firstURL.deletingPathExtension().appendingPathExtension("effects.json")))
            guard firstRecipe.count==1,firstRecipe[0].kind == .crashZoom,(firstRecipe[0].phaseOffset ?? 0)>0 else { throw ProjectError.invalidDocument }
            camera.start(in:root);try await wait { camera.state == .recording }
            try await Task.sleep(for:.milliseconds(500))
            camera.triggerCrashZoom();try await wait { camera.crashState == .ready }
            camera.triggerCrashZoom();try await wait { camera.crashState == .holding }
            try await Task.sleep(for:.milliseconds(300))
            camera.stop();try await wait { camera.state == .idle && files.count>firstCount+1 }
            let lastURL=files.last!,lastAsset=AVURLAsset(url:lastURL),lastDuration=try await lastAsset.load(.duration).seconds
            let lastRecipe=try JSONDecoder().decode([VideoEffectSettings].self,from:Data(contentsOf:lastURL.deletingPathExtension().appendingPathExtension("effects.json")))
            let retained=VideoEffectSettings.capturedRecipe(lastRecipe,duration:lastDuration)
            guard retained.count==2,retained.allSatisfy(\.valid),retained[0].releaseTime != nil else { throw ProjectError.invalidDocument }
            var zoomProject=Project(title:"Crash Zoom QA");zoomProject.append(SourceMedia(filename:lastURL.lastPathComponent,duration:lastDuration,videoEffects:retained));try zoomProject.validate()
            let zoomMedia=try await MediaRenderer.timeline(project:zoomProject,folder:root)
            let zoomGenerator=AVAssetImageGenerator(asset:zoomMedia.composition);zoomGenerator.videoComposition=zoomMedia.videoComposition
            _ = try await zoomGenerator.image(at:CMTime(seconds:0.2,preferredTimescale:30))
            report["crashZoom"]=["previewCarry":true,"pauseCarry":true,"manualReturn":true,"secondTrigger":true,"validTrimmedRecipe":true,"reopenedFrame":true]
            report["stage"]="Dolly hardware control with synthetic tracking measurements";save()
            var dolly=VideoEffectSettings(.dollyZoom);dolly.set("direction",.choice("Compress"));dolly.set("duration",.number(5))
            camera.setVideoEffects([dolly]);camera.setZoom(1,seconds:0);try await Task.sleep(for:.milliseconds(500))
            camera.probeDollyMeasurement(distance:1);try await Task.sleep(for:.milliseconds(100))
            camera.triggerDollyZoom();try await wait { camera.dollyState == .following }
            let dollyCount=files.count
            camera.start(in:root);try await wait { camera.state == .recording }
            for sample in 0..<45 {
                camera.probeDollyMeasurement(distance:1+min(1,Double(sample)/30)*0.4)
                try await Task.sleep(for:.milliseconds(67))
            }
            let followed=await camera.probeSnapshot(),followedZoom=followed["zoom"] as? Double ?? 0
            guard abs(followedZoom-1.4)<0.08 else { throw ProjectError.invalidDocument }
            camera.stop(pause:true);try await wait { camera.state == .paused && camera.dollyState == .holding && files.count>dollyCount }
            let held=(await camera.probeSnapshot())["zoom"] as? Double ?? 0
            try await Task.sleep(for:.milliseconds(500))
            let settled=(await camera.probeSnapshot())["zoom"] as? Double ?? 0
            guard abs(settled-held)<0.01 else { throw ProjectError.invalidDocument }
            let dollyURL=files.last!,dollyRecipe=try JSONDecoder().decode([VideoEffectSettings].self,from:Data(contentsOf:dollyURL.deletingPathExtension().appendingPathExtension("effects.json")))
            guard !dollyRecipe.contains(where:{$0.kind == .dollyZoom}) else { throw ProjectError.invalidDocument }
            camera.probeDollyMeasurement(distance:nil);camera.finishPausedTake()
            report["dollyZoom"]=["hardwareFollow":true,"syntheticSubject":true,"actualZoom":followedZoom,"pauseHoldsFraming":true,"noDoubleProcessing":true]
            report["stage"]="Live empty-screen capture and color picker";save()
            var key=VideoEffectSettings(.chromaKey);key.set("personHint",.toggle(false));camera.setVideoEffects([key])
            camera.captureCleanPlate(key.id)
            try await wait { if case .media(let file)=camera.videoEffects.first?.value("cleanPlate") { return file != nil };return false }
            guard case .media(let plateFile)=camera.videoEffects.first?.value("cleanPlate"),let plateFile else { throw ProjectError.invalidDocument }
            livePlates.append(plateFile)
            camera.captureCleanPlate(key.id)
            try await wait{camera.cleanPlateCountdown==nil && (camera.cleanPlateProgress ?? 0)>0.7}
            camera.cancelEffectFrameTools()
            camera.beginEffectColorPick(key.id,parameter:"screenColor");try await Task.sleep(for:.milliseconds(700))
            guard camera.effectColorPick==key.id,case .media(let stillSet)=camera.videoEffects.first?.value("cleanPlate"),stillSet==plateFile else {throw ProjectError.invalidDocument}
            camera.pickEffectColor(CGPoint(x:0.5,y:0.5));try await wait {camera.effectColorPick==nil}
            guard camera.videoEffects.first?.toggle("autoScreen")==false else { throw ProjectError.invalidDocument }
            let plateCount=files.count
            camera.start(in:root);try await wait {camera.state == .recording};try await Task.sleep(for:.seconds(1))
            camera.stop();try await wait {camera.state == .idle && files.count>plateCount}
            let plateURL=files.last!,plateAsset=AVURLAsset(url:plateURL),plateDuration=try await plateAsset.load(.duration).seconds
            let plateRecipe=try JSONDecoder().decode([VideoEffectSettings].self,from:Data(contentsOf:plateURL.deletingPathExtension().appendingPathExtension("effects.json")))
            guard FileManager.default.fileExists(atPath:root.appendingPathComponent(plateFile).path) else {throw ProjectError.missingMedia}
            var plateProject=Project(title:"Empty screen QA");plateProject.append(SourceMedia(filename:plateURL.lastPathComponent,duration:plateDuration,videoEffects:VideoEffectSettings.capturedRecipe(plateRecipe,duration:plateDuration)))
            let plateMedia=try await MediaRenderer.timeline(project:plateProject,folder:root)
            let plateGenerator=AVAssetImageGenerator(asset:plateMedia.composition);plateGenerator.videoComposition=plateMedia.videoComposition
            _ = try await plateGenerator.image(at:CMTime(seconds:0.2,preferredTimescale:30))
            report["cleanPlate"]=["captured":true,"cancelledRetake":true,"newRequestSurvivesCancel":true,"pickedColor":true,"assetCopied":true,"reopenedFrame":true]
            report["stage"]="Live palette lock, resample and save";save()
            var quant=VideoEffectSettings(.quantization);camera.setVideoEffects([quant])
            camera.sampleEffectPalette(quant.id)
            try await wait {camera.effectPaletteSampling==nil && camera.videoEffects.first?.lockedPalette?.colors.count==4}
            quant=camera.videoEffects[0];quant.set("colors",.number(6));camera.setVideoEffects([quant])
            camera.sampleEffectPalette(quant.id,save:true)
            try await wait {camera.effectPaletteSampling==nil && camera.videoEffects.first?.palette?.count==6}
            guard camera.videoEffects.first?.choice("palette")=="Saved",camera.videoEffects.first?.toggle("lockPalette")==true else {throw ProjectError.invalidDocument}
            let saved=try JSONDecoder().decode([VideoEffectSettings].self,from:JSONEncoder().encode(camera.videoEffects))
            guard saved[0].lockedPalette?.colors.count==6,saved[0].valid else {throw ProjectError.invalidDocument}
            camera.sampleEffectPalette(quant.id);camera.cancelEffectFrameTools()
            try await Task.sleep(for:.milliseconds(500))
            guard camera.effectPaletteSampling==nil,camera.videoEffects==saved else {throw ProjectError.invalidDocument}
            report["palette"]=["lock":true,"resample":true,"save":true,"cancel":true,"persisted":true]
            report["stage"]="Background positioning";save()
            guard let backgroundSource=files.first else {throw ProjectError.invalidMedia}
            let backgroundName="position-qa-"+UUID().uuidString+".mov"
            try FileManager.default.copyItem(at:backgroundSource,to:LiveVideoEffects.folder.appendingPathComponent(backgroundName));livePlates.append(backgroundName)
            var framingKey=VideoEffectSettings(.chromaKey);framingKey.set("personHint",.toggle(false));framingKey.set("background",.choice("Video"));framingKey.set("media",.media(backgroundName));framingKey.set("backgroundZoom",.number(2))
            camera.setVideoEffects([framingKey]);try await Task.sleep(for:.milliseconds(600))
            await camera.beginEffectBackgroundPosition(framingKey.id)
            guard camera.positioningEffectID==framingKey.id else {throw ProjectError.invalidMedia}
            camera.moveEffectBackground(.pan(CGPoint(x:0.1,y:0.05)));camera.moveEffectBackground(.pinch(factor:1.2,from:CGPoint(x:0.4,y:0.5),to:CGPoint(x:0.45,y:0.55)));camera.moveEffectBackground(.ended)
            guard camera.videoEffects==[framingKey],(camera.effectBackgroundPlacement?.zoom ?? 0)>2 else {throw ProjectError.invalidDocument}
            camera.finishEffectPosition(revert:true)
            guard camera.positioningEffectID==nil,camera.videoEffects==[framingKey] else {throw ProjectError.invalidDocument}
            await camera.beginEffectBackgroundPosition(framingKey.id);camera.moveEffectBackground(.pan(CGPoint(x:0.1,y:0.05)));camera.moveEffectBackground(.ended);camera.finishEffectPosition()
            let moved=camera.videoEffects
            guard moved != [framingKey],moved[0].number("backgroundZoom")==2 else {throw ProjectError.invalidDocument}
            let count=files.count
            camera.start(in:root);try await wait {camera.state == .recording};try await Task.sleep(for:.seconds(1));camera.stop();try await wait {!camera.hasActiveTake && files.count>count}
            let recipe=try JSONDecoder().decode([VideoEffectSettings].self,from:Data(contentsOf:files.last!.deletingPathExtension().appendingPathExtension("effects.json")))
            guard recipe.first?.number("backgroundX")==moved[0].number("backgroundX"),recipe.first?.number("backgroundY")==moved[0].number("backgroundY") else {throw ProjectError.invalidDocument}
            report["backgroundPosition"]=["drag":true,"pinch":true,"revert":true,"persisted":true,"recordedRecipe":true]
            report["stage"]="Continuous audio rate performance";save()
            let rateReport=try await Task.detached(priority:.userInitiated) { () throws -> [String:Double] in
                let fileURL=root.appendingPathComponent("rate-performance.caf"),format=AVAudioFormat(standardFormatWithSampleRate:48000,channels:2)!
                var settings=format.settings;settings[AVLinearPCMIsNonInterleaved]=false
                do {
                    let file=try AVAudioFile(forWriting:fileURL,settings:settings,commonFormat:.pcmFormatFloat32,interleaved:false)
                    let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:4096)!
                    var cursor=0
                    while cursor<60*48000 {
                        let count=min(4096,60*48000-cursor);buffer.frameLength=AVAudioFrameCount(count)
                        for i in 0..<count {
                            let sample=Float(sin(Double(cursor+i)*2*Double.pi*1000/48000)*0.1)
                            buffer.floatChannelData![0][i]=sample;buffer.floatChannelData![1][i]=sample
                        }
                        try file.write(from:buffer);cursor+=count
                    }
                }
                let slices=(0..<120).map {k in EffectAudioRateSlice(start:Double(k)*0.5,end:Double(k+1)*0.5,duration:0.5/(1+Double(k)*0.5/120))}
                return ["inputSeconds":60,"outputSeconds":slices.reduce(0){$0+$1.duration}]
            }.value
            let slices=(0..<120).map {k in EffectAudioRateSlice(start:Double(k)*0.5,end:Double(k+1)*0.5,duration:0.5/(1+Double(k)*0.5/120))}
            let rateStart=ProcessInfo.processInfo.systemUptime
            let sound=try await EffectAudioRateRenderer.shared.render(url:root.appendingPathComponent("rate-performance.caf"),slices:slices,folder:root)
            let wall=ProcessInfo.processInfo.systemUptime-rateStart
            let rendered=try AVAudioFile(forReading:sound)
            var result=rateReport;result["wallSeconds"]=wall;result["actualSeconds"]=Double(rendered.length)/rendered.processingFormat.sampleRate
            guard abs(result["actualSeconds"]!-result["outputSeconds"]!)<0.001 else {throw ProjectError.invalidMedia}
            report["audioRate60s"]=result
            report["status"]="passed"
        } catch {camera.stop();try? await wait{!camera.hasActiveTake};report["status"]="failed";report["error"]=error.localizedDescription}
    }
}

// Diagnostic-only capture. Owns its session and writes outside Projects; no
// user defaults or project media are changed. Compare independent delivery
// against video-primary synchronization before choosing the production path.
private final class VideoEffectDepthProbe:NSObject,AVCaptureVideoDataOutputSampleBufferDelegate,AVCaptureDepthDataOutputDelegate,AVCaptureDataOutputSynchronizerDelegate,@unchecked Sendable {
    private let queue=DispatchQueue(label:"yourec.depth-probe.session")
    private let delivery=DispatchQueue(label:"yourec.depth-probe.delivery",qos:.userInitiated)
    private let session=AVCaptureSession()
    private let video=AVCaptureVideoDataOutput(),depth=AVCaptureDepthDataOutput()
    private var synchronizer:AVCaptureDataOutputSynchronizer?
    private var videoTimes:[Double]=[],depthTimes:[Double]=[],videoLatency:[Double]=[],depthLatency:[Double]=[]
    private var videoDropped=0,depthDropped=0
    private var pictures:[Int64:CVPixelBuffer]=[:],maps:[Int64:AVDepthData]=[:]
    private var pair:(CVPixelBuffer,AVDepthData)?
    private var actual:[String:Any]=[:]
    static func run(folder:URL,progress:@escaping @MainActor ([[String:Any]])->Void) async -> [[String:Any]] {
        var results:[[String:Any]]=[]
        for kind in [AVCaptureDevice.DeviceType.builtInLiDARDepthCamera,.builtInTrueDepthCamera] {
            for hdr in [false,true] {for zoom in [1.0,2.0] {for sync in [false,true] {
                let probe=VideoEffectDepthProbe(),name="\(kind == .builtInLiDARDepthCamera ? "rear" : "front")-\(hdr ? "hlg" : "sdr")-\(Int(zoom))x-\(sync ? "sync" : "independent")"
                do {
                    try await probe.start(kind:kind,hdr:hdr,zoom:zoom,sync:sync)
                    try await Task.sleep(for:.seconds(3))
                    var result=await probe.finish(folder:folder,name:name)
                    result["name"]=name;results.append(result)
                } catch {
                    _=await probe.finish(folder:folder,name:name)
                    results.append(["name":name,"error":error.localizedDescription])
                }
                await progress(results)
            }}}
        }
        return results
    }
    private func start(kind:AVCaptureDevice.DeviceType,hdr:Bool,zoom:Double,sync:Bool) async throws {
        try await withCheckedThrowingContinuation {(continuation:CheckedContinuation<Void,Error>) in queue.async {
            do {
                guard let device=AVCaptureDevice.default(kind,for:.video,position:kind == .builtInLiDARDepthCamera ? .back : .front) else {throw NSError(domain:"YouRecDepthProbe",code:1,userInfo:[NSLocalizedDescriptionKey:"Compatible 4K30 depth format unavailable"])}
                let input=try AVCaptureDeviceInput(device:device)
                self.session.beginConfiguration();self.session.sessionPreset = .inputPriority;self.session.automaticallyConfiguresCaptureDeviceForWideColor=false
                guard self.session.canAddInput(input) else {self.session.commitConfiguration();throw ProjectError.invalidMedia}
                self.session.addInput(input)
                self.video.alwaysDiscardsLateVideoFrames=true
                self.depth.isFilteringEnabled=true;self.depth.alwaysDiscardsLateDepthData=true
                guard self.session.canAddOutput(self.video),self.session.canAddOutput(self.depth) else {self.session.commitConfiguration();throw ProjectError.invalidMedia}
                self.session.addOutput(self.video);self.session.addOutput(self.depth)
                self.video.setSampleBufferDelegate(self,queue:self.delivery);self.depth.setDelegate(self,callbackQueue:self.delivery)
                if sync {self.synchronizer=AVCaptureDataOutputSynchronizer(dataOutputs:[self.video,self.depth]);self.synchronizer!.setDelegate(self,queue:self.delivery)}
                let formats=device.formats.filter {format in
                    let size=CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                    return size.width==3840 && size.height==2160 && !format.supportedDepthDataFormats.isEmpty && format.videoSupportedFrameRateRanges.contains {$0.minFrameRate<=30 && $0.maxFrameRate>=30} && (!hdr || format.supportedColorSpaces.contains(.HLG_BT2020))
                }
                guard let format=formats.max(by:{$0.videoFieldOfView<$1.videoFieldOfView}),let depthFormat=format.supportedDepthDataFormats.filter({$0.videoSupportedFrameRateRanges.contains {$0.minFrameRate<=30 && $0.maxFrameRate>=30}}).max(by:{CMVideoFormatDescriptionGetDimensions($0.formatDescription).width<CMVideoFormatDescriptionGetDimensions($1.formatDescription).width}) else {self.session.commitConfiguration();throw NSError(domain:"YouRecDepthProbe",code:1,userInfo:[NSLocalizedDescriptionKey:"Compatible 4K30 depth format unavailable"])}
                try device.lockForConfiguration()
                device.activeFormat=format;device.activeDepthDataFormat=depthFormat
                device.activeVideoMinFrameDuration=CMTime(value:1,timescale:30);device.activeVideoMaxFrameDuration=CMTime(value:1,timescale:30)
                if format.supportedColorSpaces.contains(hdr ? .HLG_BT2020 : .sRGB) {device.activeColorSpace=hdr ? .HLG_BT2020 : .sRGB}
                device.automaticallyAdjustsVideoHDREnabled=true
                device.videoZoomFactor=CGFloat(min(Double(device.maxAvailableVideoZoomFactor),max(Double(device.minAvailableVideoZoomFactor),zoom)))
                device.unlockForConfiguration()
                for connection in [self.video.connection(with:.video),self.depth.connection(with:.depthData)].compactMap({$0}) {
                    if connection.isVideoRotationAngleSupported(90) {connection.videoRotationAngle=90}
                    if connection.isVideoMirroringSupported {connection.automaticallyAdjustsVideoMirroring=false;connection.isVideoMirrored=kind == .builtInTrueDepthCamera}
                }
                let pixelFormat=hdr ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                guard self.video.availableVideoPixelFormatTypes.contains(pixelFormat) else {self.session.commitConfiguration();throw NSError(domain:"YouRecDepthProbe",code:2,userInfo:[NSLocalizedDescriptionKey:"Requested camera pixel format unavailable after selecting depth format"])}
                self.video.videoSettings=[kCVPixelBufferPixelFormatTypeKey as String:pixelFormat]
                self.session.commitConfiguration()
                self.session.startRunning()
                try device.lockForConfiguration()
                device.videoZoomFactor=CGFloat(min(Double(device.maxAvailableVideoZoomFactor),max(Double(device.minAvailableVideoZoomFactor),zoom)))
                device.unlockForConfiguration()
                let size=CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
                self.actual=["width":size.width,"height":size.height,"zoom":device.videoZoomFactor,"minimumZoom":device.minAvailableVideoZoomFactor,"maximumZoom":device.maxAvailableVideoZoomFactor,"requestedZoom":zoom,"colorSpace":device.activeColorSpace.rawValue,"filtered":self.depth.isFilteringEnabled]
                continuation.resume()
            } catch {continuation.resume(throwing:error)}
        }}
    }
    private func time(_ pts:CMTime)->Double {
        session.synchronizationClock.map {CMSyncConvertTime(pts,from:$0,to:CMClockGetHostTimeClock()).seconds} ?? pts.seconds
    }
    private func receiveVideo(_ sample:CMSampleBuffer) {
        let t=time(sample.presentationTimeStamp);videoTimes.append(t);videoLatency.append(CMClockGetTime(CMClockGetHostTimeClock()).seconds-t)
        if pair==nil,videoTimes.count>25,let pixel=sample.imageBuffer {
            let tick=Int64((t*60000).rounded());pictures[tick]=pixel
            if let map=maps[tick] {pair=(pixel,map);pictures.removeAll();maps.removeAll()}
            else if pictures.count>4,let first=pictures.keys.min() {pictures.removeValue(forKey:first)}
        }
    }
    private func receiveDepth(_ data:AVDepthData,_ pts:CMTime) {
        let t=time(pts);depthTimes.append(t);depthLatency.append(CMClockGetTime(CMClockGetHostTimeClock()).seconds-t)
        if pair==nil,videoTimes.count>25 {
            let tick=Int64((t*60000).rounded());maps[tick]=data
            if let pixel=pictures[tick] {pair=(pixel,data);pictures.removeAll();maps.removeAll()}
            else if maps.count>4,let first=maps.keys.min() {maps.removeValue(forKey:first)}
        }
    }
    func captureOutput(_ output:AVCaptureOutput,didOutput sampleBuffer:CMSampleBuffer,from connection:AVCaptureConnection) {receiveVideo(sampleBuffer)}
    func captureOutput(_ output:AVCaptureOutput,didDrop sampleBuffer:CMSampleBuffer,from connection:AVCaptureConnection) {videoDropped+=1}
    func depthDataOutput(_ output:AVCaptureDepthDataOutput,didOutput depthData:AVDepthData,timestamp:CMTime,connection:AVCaptureConnection) {receiveDepth(depthData,timestamp)}
    func depthDataOutput(_ output:AVCaptureDepthDataOutput,didDrop depthData:AVDepthData,timestamp:CMTime,connection:AVCaptureConnection,reason:AVCaptureOutput.DataDroppedReason) {depthDropped+=1}
    func dataOutputSynchronizer(_ synchronizer:AVCaptureDataOutputSynchronizer,didOutput collection:AVCaptureSynchronizedDataCollection) {
        if let sample=collection.synchronizedData(for:video) as? AVCaptureSynchronizedSampleBufferData {
            if sample.sampleBufferWasDropped {videoDropped+=1} else {receiveVideo(sample.sampleBuffer)}
        }
        if let sample=collection.synchronizedData(for:depth) as? AVCaptureSynchronizedDepthData {
            if sample.depthDataWasDropped {depthDropped+=1} else {receiveDepth(sample.depthData,sample.timestamp)}
        }
    }
    private func finish(folder:URL,name:String) async -> [String:Any] {
        await withCheckedContinuation {continuation in queue.async {
            if self.session.isRunning {self.session.stopRunning()}
            self.delivery.async {
                var result=self.actual
                func p95(_ values:[Double])->Double {let sorted=values.sorted();return sorted.isEmpty ? 0 : sorted[min(sorted.count-1,Int(Double(sorted.count)*0.95))]}
                let deltas=self.depthTimes.map {t in self.videoTimes.map {abs($0-t)}.min() ?? .infinity}
                result["videoFrames"]=self.videoTimes.count;result["depthFrames"]=self.depthTimes.count
                result["videoDropped"]=self.videoDropped;result["depthDropped"]=self.depthDropped
                result["exactDepthMatches"]=deltas.filter {$0<0.00002}.count
                result["videoGapMax"]=zip(self.videoTimes,self.videoTimes.dropFirst()).map {$1-$0}.max() ?? 0
                result["videoLatencyP95MS"]=p95(self.videoLatency)*1000;result["depthLatencyP95MS"]=p95(self.depthLatency)*1000
                result["thermal"]=ProcessInfo.processInfo.thermalState.rawValue
                if let (pixel,depth)=self.pair {
                    do {
                        let context=CIContext(options:[.cacheIntermediates:false]),space=CGColorSpace(name:CGColorSpace.sRGB)!
                        let color=CIImage(cvPixelBuffer:pixel),scale=960/color.extent.width
                        try context.writePNGRepresentation(of:color.transformed(by:CGAffineTransform(scaleX:scale,y:scale)),to:folder.appendingPathComponent(name+"-color.png"),format:.RGBA8,colorSpace:space)
                        let data=depth.converting(toDepthDataType:kCVPixelFormatType_DepthFloat32),map=data.depthDataMap
                        let width=CVPixelBufferGetWidth(map),height=CVPixelBufferGetHeight(map)
                        result["depthSize"]=[width,height];result["videoSize"]=[CVPixelBufferGetWidth(pixel),CVPixelBufferGetHeight(pixel)]
                        CVPixelBufferLockBaseAddress(map,.readOnly)
                        var raw=Data()
                        if let base=CVPixelBufferGetBaseAddress(map) {for y in 0..<height {raw.append(base.advanced(by:y*CVPixelBufferGetBytesPerRow(map)).assumingMemoryBound(to:UInt8.self),count:width*4)}}
                        CVPixelBufferUnlockBaseAddress(map,.readOnly)
                        try raw.write(to:folder.appendingPathComponent(name+"-depth.f32"),options:.atomic)
                        if let calibration=depth.cameraCalibrationData {
                            result["calibrationSize"]=[calibration.intrinsicMatrixReferenceDimensions.width,calibration.intrinsicMatrixReferenceDimensions.height]
                            result["intrinsics"]=(0..<3).flatMap {r in (0..<3).map {c in Double(calibration.intrinsicMatrix[c][r])}}
                        }
                    } catch {result["imageError"]=error.localizedDescription}
                }
                continuation.resume(returning:result)
            }
        }}
    }
}


@available(iOS 26.0,*)
private final class VideoEffectCinematicProbe:NSObject,AVCaptureFileOutputRecordingDelegate,@unchecked Sendable {
    private let queue=DispatchQueue(label:"yourec.cinematic-probe")
    private let session=AVCaptureSession(),output=AVCaptureMovieFileOutput()
    private var completion:CheckedContinuation<URL,Error>?
    func record(to url:URL) async throws -> URL {
        try await withCheckedThrowingContinuation {continuation in queue.async {
            do {
                guard let device=AVCaptureDevice.default(.builtInDualWideCamera,for:.video,position:.back),let format=device.formats.first(where:{format in
                    let size=CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                    return format.isCinematicVideoCaptureSupported && size.width==1920 && size.height==1080 && format.videoSupportedFrameRateRanges.contains {$0.minFrameRate<=30 && $0.maxFrameRate>=30}
                }) else {throw ProjectError.invalidMedia}
                self.session.beginConfiguration();self.session.sessionPreset = .inputPriority
                let input=try AVCaptureDeviceInput(device:device)
                guard self.session.canAddInput(input) else {self.session.commitConfiguration();throw ProjectError.invalidMedia};self.session.addInput(input)
                guard self.session.canAddOutput(self.output) else {self.session.commitConfiguration();throw ProjectError.invalidMedia};self.session.addOutput(self.output)
                try device.lockForConfiguration();device.activeFormat=format
                device.activeVideoMinFrameDuration=CMTime(value:1,timescale:30);device.activeVideoMaxFrameDuration=CMTime(value:1,timescale:30);device.unlockForConfiguration()
                guard input.isCinematicVideoCaptureSupported else {self.session.commitConfiguration();throw ProjectError.invalidMedia}
                input.isCinematicVideoCaptureEnabled=true
                self.session.commitConfiguration();self.session.startRunning()
                self.completion=continuation;self.output.startRecording(to:url,recordingDelegate:self)
            } catch {continuation.resume(throwing:error)}
        }}
    }
    func fileOutput(_ output:AVCaptureFileOutput,didStartRecordingTo fileURL:URL,from connections:[AVCaptureConnection]) {
        queue.asyncAfter(deadline:.now()+4) {self.output.stopRecording()}
    }
    func fileOutput(_ output:AVCaptureFileOutput,didFinishRecordingTo outputFileURL:URL,from connections:[AVCaptureConnection],error:Error?) {
        queue.async {
            self.session.stopRunning()
            if let error,(error as NSError).userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool != true {self.completion?.resume(throwing:error)}
            else {self.completion?.resume(returning:outputFileURL)}
            self.completion=nil
        }
    }
}

#endif
