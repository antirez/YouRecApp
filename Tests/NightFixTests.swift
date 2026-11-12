import Foundation
import AVFoundation
import CoreImage
import CryptoKit

func nightFixTests(root base:URL) async throws {
    let root=base.appendingPathComponent("night-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    for name in ["night-source.mov","night-flow.mov"] {try FileManager.default.copyItem(at:base.appendingPathComponent(name),to:root.appendingPathComponent(name))}
    let source=root.appendingPathComponent("night-source.mov")
    let index=try await VideoEffectFrameAnalysis.shared.index(url:source,folder:root)
    var effect=VideoEffectSettings(.nightFix,start:0.25,end:1.5)
    try require(effect.nightFixMode == .fast && !effect.needsNightFixFusion,"New Night fix defaults to Fast")
    try require(effect.parameters.first(where:{$0.id=="mode"})?.animatable==false,"Processing mode is constant over an effect")
    effect.set("mode",.choice("Precise"))
    try require(effect.kind.descriptor.mode == .edit,"Night fix is editor-only")
    var extreme=effect;extreme.set("brightness",.number(8));extreme.set("reduction",.number(3))
    extreme.parameters[0].setKeyframe(at:0.25,value:.number(0.4))
    let decoded=try JSONDecoder().decode(VideoEffectSettings.self,from:JSONEncoder().encode(extreme))
    try require(decoded==extreme,"Extreme settings and mix keyframes persist")
    let gpu=try NightFixGPU(),size=CGRect(x:0,y:0,width:96,height:64)
    let input=CIImage(color:CIColor(red:0.003,green:0.006,blue:0.01,alpha:1)).cropped(to:size)
    func mean(_ image:CIImage)throws->Double {
        var values=[Float](repeating:0,count:96*64*4)
        gpu.context.render(image,toBitmap:&values,rowBytes:96*16,bounds:size,format:.RGBAf,colorSpace:gpu.space)
        try require(values.allSatisfy(\.isFinite),"Night fix pixels stay finite")
        return stride(from:0,to:values.count,by:4).reduce(0){$0+Double(values[$1])}/Double(96*64)
    }
    var disabled=extreme;disabled.set("intensity",.number(0));disabled.parameters[0].keyframes=[]
    let original=try mean(input),zero=try mean(gpu.adjust(original:input,fused:input,effect:disabled,time:1))
    try require(abs(zero-original)<1e-8,"Zero mix is pixel-identical")
    var light=effect;light.set("reduction",.number(0));light.set("brightness",.number(2.5))
    let normal=try mean(gpu.adjust(original:input,fused:input,effect:light,time:1))
    light.set("brightness",.number(8));let pushed=try mean(gpu.adjust(original:input,fused:input,effect:light,time:1))
    try require(pushed>normal*3 && normal>original*4,"Brightness can push well beyond comparison setting")
    var identity=effect;identity.set("reduction",.number(0));identity.set("brightness",.number(0))
    let neutral=try mean(gpu.adjust(original:input,fused:input,effect:identity,time:1))
    try require(abs(neutral-original)<1e-8,"Zero cleanup plus zero brightness is identity")
    print("PASS night parameters, keyframes, neutral controls and +8-stop range")

    // Direct flow evidence: source fixture's second image translates the first
    // eight pixels right and four down. Check vectors and the actual warp error.
    let flowSource=root.appendingPathComponent("night-flow.mov")
    let flowIndex=try await VideoEffectFrameAnalysis.shared.index(url:flowSource,folder:root)
    let fusion=try NightFixFusion(url:flowSource,index:flowIndex,hdr:false,width:384,height:256)
    let flow=try fusion.flow(from:0,to:1)
    CVPixelBufferLockBaseAddress(flow,.readOnly)
    let pixels=CVPixelBufferGetBaseAddress(flow)!.assumingMemoryBound(to:Float.self),rowStride=CVPixelBufferGetBytesPerRow(flow)/4
    var xs:[Float]=[],ys:[Float]=[]
    for y in 12..<(CVPixelBufferGetHeight(flow)-12) {for x in 12..<(CVPixelBufferGetWidth(flow)-12) {xs.append(pixels[y*rowStride+x*2]);ys.append(pixels[y*rowStride+x*2+1])}}
    CVPixelBufferUnlockBaseAddress(flow,.readOnly)
    xs.sort();ys.sort();let x=xs[xs.count/2],y=ys[ys.count/2]
    print("Flow median",x,y,"expected 2, 1 guide pixels")
    try require(abs(x-2)<0.6 && abs(y-1)<0.6,"Optical-flow direction and coordinates match known translation")

    var project=Project(title:"Night fix model QA")
    project.append(SourceMedia(filename:source.lastPathComponent,duration:2))
    var edit=project.edit;edit.clips[0].videoEffects=[effect];project.commit(edit)
    var fastClip=edit.clips[0];fastClip.videoEffects![0].set("mode",.choice("Fast"))
    let fastPlan=try await NightFixCache.shared.plan(url:source,folder:root,clip:fastClip,hdr:false,preparation:.final,progress:{_ in})
    try require(fastPlan==nil,"Fast never prepares temporal data")
    var fastProject=project;var fastState=edit;fastState.clips=[fastClip];fastProject.commit(fastState)
    let fastPreview=try await MediaRenderer.timeline(project:fastProject,folder:root,effectPreparation:.cached)
    try require(!fastPreview.effectAnalysisPending,"Fast preview is final quality immediately")
    let fastOutput=root.appendingPathComponent("fast.mp4")
    _=try await MediaRenderer.render(project:fastProject,folder:root,destination:fastOutput,progress:{_ in})
    try require(!FileManager.default.fileExists(atPath:ProjectCacheLocation.root(in:root).appendingPathComponent("NightFix").path),"Fast preview/export never create a fusion cache")
    let originalSources=project.sources
    try project.validate()
    let cacheBefore=try await NightFixCache.shared.plan(url:source,folder:root,clip:edit.clips[0],hdr:false,preparation:.cached,progress:{_ in})
    try require(cacheBefore?.pending==true,"Missing cache is explicitly provisional")
    let begin=Date()
    let full=try await NightFixCache.shared.plan(url:source,folder:root,clip:edit.clips[0],hdr:false,preparation:.final,progress:{_ in})!
    print("Fusion seconds",Date().timeIntervalSince(begin))
    try require(!full.pending && full.index.times==index.times,"Final preparation covers requested frames without changing timestamps")
    var mediumClip=edit.clips[0];mediumClip.videoEffects![0].set("mode",.choice("Medium"))
    let medium=try await NightFixCache.shared.plan(url:source,folder:root,clip:mediumClip,hdr:false,preparation:.final,progress:{_ in})!
    try require(medium.mode == .medium && !medium.pending && medium.root != full.root,"Medium prepares a distinct three-frame cache")
    let mediumFusion=try NightFixFusion(url:source,index:index,hdr:false,width:384,height:256,mode:.medium)
    try require(mediumFusion.mode.radius==1 && full.mode.radius==4,"Quality modes use three and nine frame neighborhoods")
    let file=full.root.appendingPathComponent(full.chunks[0].file)
    let before=try Data(contentsOf:file),modified=try file.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate
    var adjusted=edit.clips[0];adjusted.videoEffects=[extreme]
    let reused=try await NightFixCache.shared.plan(url:source,folder:root,clip:adjusted,hdr:false,preparation:.final,progress:{_ in})!
    try require(!reused.pending && reused.chunks.map(\.file)==full.chunks.map(\.file),"Control changes reuse the same temporal fusion")
    let after=try Data(contentsOf:file),newModified=try file.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate
    try require(before==after && modified==newModified,"Reused cache is never re-encoded")
    // The cache must retain fractional shadow codes: 8-bit HEVC visibly
    // posterizes this material when the user subsequently pushes brightness.
    let direct=try NightFixFusion(url:source,index:index,hdr:false,width:384,height:256)
    let reader=try VideoEffectSourceReader(url:source,hdr:false,capacity:2,highPrecision:true)
    let cachedReader=try VideoEffectSourceReader(url:file,hdr:false,capacity:2,highPrecision:true)
    let t=index.times[15],raw=try reader.sample(at:t).image
    let fused=try direct.frame(15,cancel:{false}),packed=try cachedReader.sample(at:t-full.chunks[0].times[0]).image
    func samples(_ image:CIImage,region:CGRect)->[Float] {
        var values=[Float](repeating:0,count:Int(region.width*region.height)*4)
        gpu.context.render(image,toBitmap:&values,rowBytes:Int(region.width)*16,bounds:region,format:.RGBAf,colorSpace:gpu.space)
        return stride(from:0,to:values.count,by:4).map {values[$0]}
    }
    var push=VideoEffectSettings(.nightFix);push.set("brightness",.number(6))
    let uncached=try gpu.adjust(original:raw,fused:fused,effect:push,time:t)
    let fromCache=try gpu.adjust(original:raw,fused:packed,effect:push,time:t,cached:true)
    let region=CGRect(x:0,y:0,width:384,height:256)
    let aa=samples(uncached,region:region),bb=samples(fromCache,region:region)
    let rmse=sqrt(zip(aa,bb).reduce(0.0){$0+Double(($1.0-$1.1)*($1.0-$1.1))}/Double(aa.count))
    print("Six-stop cached vs direct RMSE",rmse)
    try require(rmse<0.015,"Cache retains fine shadow precision under strong exposure")
    func variance(_ a:[Float])->Double {let mean=a.reduce(0,+)/Float(a.count);return a.reduce(0){$0+Double(($1-mean)*($1-mean))}/Double(a.count)}
    let flat=CGRect(x:20,y:20,width:45,height:45),rawNoise=variance(samples(raw,region:flat)),fusedNoise=variance(samples(fused,region:flat))
    let mediumImage=try mediumFusion.frame(15,cancel:{false})
    let mediumNoise=variance(samples(mediumImage,region:flat))
    try require(mediumNoise<rawNoise*0.9,"Medium reduces noise with its shorter temporal neighborhood")
    print("Medium noise variance",mediumNoise)
    print("Flat-region noise variance",rawNoise,fusedNoise)
    try require(fusedNoise<rawNoise*0.85,"Temporal restoration reduces noise on a stationary surface")
    // Dynamic-range and monotonicity guard: no channel can become NaN or
    // reverse the neutral ramp, including values above reference white.
    let hdr=CIImage(color:CIColor(red:2,green:2,blue:2,colorSpace:gpu.space)!).cropped(to:size)
    let hdrMean=try mean(gpu.adjust(original:hdr,fused:hdr,effect:push,time:t))
    try require(hdrMean>1.8,"Highlights above reference white remain above white")
    let media=try await MediaRenderer.timeline(project:project,folder:root)
    try require(!media.effectAnalysisPending && abs(media.composition.duration.seconds-2)<0.001,"Night fix preserves timeline duration")
    let frames=AVAssetImageGenerator(asset:media.composition);frames.videoComposition=media.videoComposition
    frames.requestedTimeToleranceBefore = .zero;frames.requestedTimeToleranceAfter = .zero
    for time in [0.0,0.5,1.2,1.75] { _=try await frames.image(at:CMTime(seconds:time,preferredTimescale:240000)) }
    let destination=root.appendingPathComponent("night-export-"+UUID().uuidString+".mp4")
    _=try await MediaRenderer.render(project:project,folder:root,destination:destination,progress:{_ in})
    let rendered=AVURLAsset(url:destination)
    let renderedDuration=try await rendered.load(.duration).seconds
    try require(abs(renderedDuration-2)<0.001,"Export keeps picture and audio duration")
    let disk=ProjectDisk(root:root.appendingPathComponent("night-projects"));try disk.save(project)
    var reopened=try disk.read(disk.folder(project.id).appendingPathComponent("project.json"))
    reopened.undo();try require(reopened.sources==originalSources && reopened.edit.duration==2,"Undo retains all original footage")
    reopened.redo();try require(reopened.edit==edit,"Redo restores effect and range")
    let split=TimelineEditing.split(edit,at:0.7);project.commit(split)
    let splitMedia=try await MediaRenderer.timeline(project:project,folder:root)
    try require(!splitMedia.effectAnalysisPending && abs(splitMedia.composition.duration.seconds-2)<0.001,"Split retains restored source-time mapping and reuse")
    // Night fix follows original source time through the editor's other tools.
    let joined=split.settingTransition(ClipTransition(duration:0.25),at:1)
    project.commit(joined)
    let overlap=try await MediaRenderer.timeline(project:project,folder:root)
    let og=AVAssetImageGenerator(asset:overlap.composition);og.videoComposition=overlap.videoComposition
    _=try await og.image(at:CMTime(seconds:joined.layout.joins[1].time,preferredTimescale:240000))
    var fast=edit;fast.clips[0].speed=SpeedSettings(rate:2);project.commit(fast)
    let sped=try await MediaRenderer.timeline(project:project,folder:root)
    try require(abs(sped.composition.duration.seconds-1)<0.001,"Speed changes output time without changing restored source frames")
    let frozen=TimelineEditing.freezing(edit,at:0.75).0;project.commit(frozen)
    let hold=try await MediaRenderer.timeline(project:project,folder:root)
    let hg=AVAssetImageGenerator(asset:hold.composition);hg.videoComposition=hold.videoComposition
    _=try await hg.image(at:CMTime(seconds:1.5,preferredTimescale:240000))
    try require(hold.composition.duration.seconds>2,"Freeze keeps its hold with restored original pixels")
    // Compare the actual preview compositor to the compressed exported frame.
    let eg=AVAssetImageGenerator(asset:rendered);eg.appliesPreferredTrackTransform=true
    eg.requestedTimeToleranceBefore = .zero;eg.requestedTimeToleranceAfter = .zero
    let preview=try await frames.image(at:CMTime(seconds:0.5,preferredTimescale:60000)).image
    let export=try await eg.image(at:CMTime(seconds:0.5,preferredTimescale:60000)).image
    let pv=samples(CIImage(cgImage:preview),region:region),ev=samples(CIImage(cgImage:export),region:region)
    let exportRMSE=sqrt(zip(pv,ev).reduce(0.0){$0+Double(($1.0-$1.1)*($1.0-$1.1))}/Double(pv.count))
    print("Preview/export RMSE",exportRMSE)
    try require(exportRMSE<0.02,"Preview and exported restoration agree within encoding tolerance")
    // Fast must still show the same result after a Precise cache exists.
    let finalFast=try await MediaRenderer.timeline(project:fastProject,folder:root)
    try require(!finalFast.effectAnalysisPending,"Fast does not reuse or wait for a different mode")
    let fq=AVAssetImageGenerator(asset:fastPreview.composition);fq.videoComposition=fastPreview.videoComposition
    let ff=AVAssetImageGenerator(asset:finalFast.composition);ff.videoComposition=finalFast.videoComposition
    let fe=AVAssetImageGenerator(asset:AVURLAsset(url:fastOutput));fe.appliesPreferredTrackTransform=true
    for generator in [fq,ff,fe] {generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero}
    let when=CMTime(seconds:0.5,preferredTimescale:60000)
    let quickFrame=try await fq.image(at:when).image,finalFrame=try await ff.image(at:when).image,encodedFrame=try await fe.image(at:when).image
    let q=samples(CIImage(cgImage:quickFrame),region:region),f=samples(CIImage(cgImage:finalFrame),region:region),e=samples(CIImage(cgImage:encodedFrame),region:region)
    try require(q==f,"Fast quick and fully prepared compositors are pixel-identical even after Precise was cached")
    let fastRMSE=sqrt(zip(q,e).reduce(0.0){$0+Double(($1.0-$1.1)*($1.0-$1.1))}/Double(q.count))
    try require(fastRMSE<0.02,"Fast export agrees with its immediate preview")
    print("Fast preview/export RMSE",fastRMSE)
    let task=Task {try await NightFixCache.shared.plan(url:source,folder:root,clip:edit.clips[0],hdr:false,preparation:.final,progress:{_ in})}
    task.cancel();var canceled=false
    do {_=try await task.value}catch is CancellationError {canceled=true}
    try require(canceled,"Preparation honors cancellation")
    // Bound inspector playback using project time, including retimed effects.
    var rangeProject=Project(title:"Preview range");rangeProject.append(SourceMedia(filename:source.lastPathComponent,duration:12))
    let request=ToolRequest(tool:.videoEffects,range:3...5,scopeTitle:"Selection")
    let (scoped,ids)=request.videoScope(in:rangeProject.edit)
    try require(request.videoPreviewRange(in:scoped,ids:ids)==3...5,"Preview excludes footage before and after the selection")
    var retimed=scoped
    for i in retimed.clips.indices where ids.contains(retimed.clips[i].id) {retimed.clips[i].speed=SpeedSettings(rate:2)}
    try require(request.videoPreviewRange(in:retimed,ids:ids)==3...4,"Preview bounds follow speed changes")
    var partial=rangeProject.edit;let inner=VideoEffectSettings(.nightFix,start:4,end:6);partial.clips[0].videoEffects=[inner]
    let reopen=ToolRequest(tool:.videoEffects,range:4...6,scopeTitle:"Night fix",effectID:inner.id,clipIDs:[partial.clips[0].id])
    try require(reopen.videoPreviewRange(in:partial,ids:[partial.clips[0].id])==4...6,"Reopening a subrange effect preserves its exact preview bounds")
    print("PASS night modes, cache, playback, export, ranges, speed, split, undo/redo and cancellation")
}

/// Run the inspector and saved edit through the actual media builders. A player
/// with end-time bounds alone would pass a UI test but fail the cache assertions.
func effectApplicationTests(root fixtures: URL) async throws {
    let root = fixtures.appendingPathComponent("application-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.copyItem(at: fixtures.appendingPathComponent("apply-fixture.mp4"), to: root.appendingPathComponent("apply-fixture.mp4"))
    let source = SourceMedia(filename: "apply-fixture.mp4", duration: 18)
    let url = root.appendingPathComponent(source.filename)
    var project = Project(title: "Effect application"); project.append(source)
    var edit = project.edit
    var night = VideoEffectSettings(.nightFix, start: 0, end: 18); night.set("mode", .choice("Medium"))
    edit.clips[0].videoEffects = [night]; project.commit(edit)
    let range = EffectPreviewWindow.range(at: 9, within: 0...18)
    try require(range == 4...14, "Inspector spans ten seconds on the timeline")
    let window = EffectPreviewWindow(range, timeline: edit.timeline)
    _ = try await VideoEffectPreparation.$inspectionWindow.withValue(window) {
        try await MediaRenderer.timeline(project: project, folder: root, effectPreparation: .refinedPreview)
    }
    func cached() async throws -> NightFixPlan {
        try await NightFixCache.shared.plan(url: url, folder: root, clip: edit.clips[0], hdr: false,
                                            preparation: .cached, progress: { _ in })!
    }
    let sample = try await cached()
    try require(sample.pending && sample.sample(at: 9) != nil && sample.sample(at: 0) == nil && sample.sample(at: 17) == nil,
                "Only source chunks intersecting the sample were generated")
    // Cancel the producer while it has an open encoder. The stopped operation
    // must return, release its gate and remove its partial before Undo or retry.
    let cancelled = Task { try await MediaRenderer.timeline(project: project, folder: root, effectPreparation: .refinedPreview) }
    func partialExists() throws -> Bool {
        try FileManager.default.contentsOfDirectory(atPath: sample.root.path).contains { $0.hasSuffix(".partial.mov") }
    }
    let deadline = ContinuousClock.now + .seconds(15)
    while try !partialExists(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    let inFlight = try partialExists(); try require(inFlight, "Cancellation exercised an active Night fix encoder")
    cancelled.cancel()
    do { _ = try await cancelled.value; try require(false, "Cancelled Night fix must stop") }
    catch is CancellationError {}
    let leftovers = try partialExists()
    let afterStop = try await cached()
    try require(!leftovers && afterStop.pending, "Stopping clears in-flight work and does not publish an incomplete chunk")
    var removed = project, clean = removed.edit; clean.clips[0].videoEffects = nil; removed.commit(clean)
    let cleanMedia = try await MediaRenderer.timeline(project: removed, folder: root, effectPreparation: .refinedPreview)
    let stillStopped = try await cached()
    try require(!cleanMedia.effectAnalysisPending && stillStopped.chunks.map(\.file) == afterStop.chunks.map(\.file),
                "A removed effect cannot be scheduled by the replacement edit")
    let receipt = EffectApplicationReceipt(project: project, tool: .videoEffects)!
    try receipt.save(in: root)
    let reopened = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
    try require(EffectApplicationReceipt.pending(for: reopened, in: root) == receipt, "Application survives a process restart")
    var undone = reopened; undone.undo()
    try require(EffectApplicationReceipt.pending(for: undone, in: root) == nil, "Undo cannot replay a stale application")
    let medium = sample.root.appendingPathComponent(sample.chunks[0].file)
    let stamp = try medium.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    _ = try await MediaRenderer.timeline(project: reopened, folder: root, effectPreparation: .refinedPreview)
    let full = try await cached()
    let after = try medium.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    try require(!full.pending && full.sample(at: 0) != nil && full.sample(at: 17) != nil && stamp == after,
                "Applying the whole saved edit reuses completed preview chunks")
    receipt.finish(in: root)
    try require(EffectApplicationReceipt.pending(for: reopened, in: root) == nil, "Completed application retires its receipt")

    let clip = edit.clips[0]
    let cache = root.appendingPathComponent("Cache/Stabilization")
    let analysis = Task {
        try await VideoEffectPreparation.$applyingSavedEdit.withValue(true) {
            try await VideoStabilizer().analysis(source: source, clip: clip, folder: root)
        }
    }
    let checkpointDeadline = ContinuousClock.now + .seconds(20)
    while !((try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []).contains(where: { $0.hasSuffix(".checkpoint") }) {
        try require(ContinuousClock.now < checkpointDeadline, "Stabilization published its first durable checkpoint")
        try await Task.sleep(for: .milliseconds(1))
    }
    analysis.cancel()
    do { _ = try await analysis.value; try require(false, "Stabilization should have been interrupted") }
    catch is CancellationError {}
    let files = try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)
    try require(files.contains { $0.pathExtension == "checkpoint" }, "Interruption retains stabilization measurements")
    let resumed = try await VideoEffectPreparation.$applyingSavedEdit.withValue(true) {
        try await VideoStabilizer().analysis(source: source, clip: clip, folder: root)
    }
    try FileManager.default.removeItem(at: cache)
    let continuous = try await VideoStabilizer().analysis(source: source, clip: clip, folder: root)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let a = try encoder.encode(resumed), b = try encoder.encode(continuous)
    try require(a == b, "Resumed stabilization matches every sample of an uninterrupted run")
    print("PASS bounded temporal preview, full application, receipt recovery, chunk reuse and identical resumed stabilization")
}
