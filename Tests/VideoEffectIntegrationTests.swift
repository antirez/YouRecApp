import Foundation
import AVFoundation
import CoreImage
import ImageIO
import CryptoKit

func videoEffectIntegrationTests(root: URL) async throws {
    try await reviewEffectRegressions(root: root)
    if ProcessInfo.processInfo.environment["YOUREC_MATTING_ROTATION_ONLY"] == "1" {try await rotatedPersonMaskTrackTest(folder:root);return}
    try await videoEffectDepthImportTests()
    try await videoEffectDepthRenderTests(root:root)
    if ProcessInfo.processInfo.environment["YOUREC_DEPTH_ONLY"] == "1" {return}
    var gate=VideoEffectAnalysisGate()
    let previewOwner=gate.claim("same-source",deferrable:true)!
    try require(gate.claim("same-source",deferrable:true)==nil,"Concurrent previews coalesce rather than opening a second decoder")
    let exportOwner=gate.claim("same-source",deferrable:false)!
    var superseded=false
    do {try await VideoEffectPreparation.checkpoint(previewOwner)} catch is VideoEffectAnalysisGate.Superseded {superseded=true}
    try require(superseded,"Export immediately supersedes background analysis, including a deferred producer")
    gate.release(previewOwner)
    try require(gate.claim("same-source",deferrable:false)==nil && gate.claim("same-source",deferrable:true)==nil,"A superseded producer cannot release export's ownership")
    gate.release(exportOwner)
    let replacement=gate.claim("same-source",deferrable:true)
    try require(replacement != nil,"Cancellation/completion releases ownership for the next producer")
    if let replacement {gate.release(replacement)}
    var project = Project(title: "Film effect persistence")
    var recorded = VideoEffectSettings(.silentTint, start: 0, end: 4)
    recorded.parameters[0].setKeyframe(at: 0, value: .number(0.3))
    recorded.parameters[0].setKeyframe(at: 4, value: .number(1))
    project.append(SourceMedia(filename: "source.mp4", duration: 4, videoEffects: [recorded]))
    try project.validate()
    try require(project.schemaVersion == 6 && project.edit.clips[0].videoEffects == [recorded], "Recorded recipes retain the canonical track schema and attach to timeline")
    var edit = TimelineEditing.split(project.edit, at: 2)
    let before = edit
    var film = VideoEffectSettings(.sixteenMM, start: 2, end: 4)
    film.set("grain", .number(0.2)); edit.clips[1].videoEffects?.append(film)
    project.commit(edit)
    let pasted = TimelineEditing.inserting(edit.clips, into: edit, at: 4)
    try require(pasted.clips[2].videoEffects![0].id != recorded.id && pasted.clips[2].videoEffects![0].id == pasted.clips[3].videoEffects![0].id, "Paste gives independent effect identity shared across copied split pieces")
    var reopened = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
    reopened.undo(); try require(reopened.edit.duration == 4 && reopened.edit.clips.count == 1, "Undoing effects preserves complete recording")
    reopened.redo(); try require(reopened.edit == edit && reopened.sources == project.sources, "Effect values and keyframes survive reopening and redo")
    try require(before.duration == edit.duration, "Image effects do not change time")
    var bg = VideoEffectSettings(.chromaKey, start: 0, end: 4)
    bg.set("media", .media("effect-background.png")); bg.analysisFile = "effect-analysis.json"
    var archived = project.edit; archived.clips[0].videoEffects?.append(bg); project.commit(archived); project.undo()
    try require(project.effectFiles == ["effect-analysis.json", "effect-background.png"], "Assets from undo/redo history remain in project archive manifest")
    try project.validate()
    let folder = root.appendingPathComponent("effect-tests", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: root.appendingPathComponent("source.mp4"), to: folder.appendingPathComponent("source.mp4"))
    if ProcessInfo.processInfo.environment["YOUREC_TEMPORAL_ONLY"] == "1" {
        try await temporalMatteProviderTests(folder:folder)
        return
    }
    let depthCatalog=VideoEffectDepthCatalog()
    let notCinematic=try await depthCatalog.source(url:folder.appendingPathComponent("source.mp4"))
    try require(notCinematic==nil,"An ordinary clip does not advertise imported depth")
    try await Task.sleep(for:.seconds(6))
    let cachedNegative=try await depthCatalog.source(url:folder.appendingPathComponent("source.mp4"),generate:false)
    try require(cachedNegative==nil,"Definitive absence of depth stays cached after six seconds without a new refinement")
    try capturedEffectAnalysisTests(folder:folder)
    try await temporalMaskAnalysisTests(folder:folder)
    try await rotatedPersonMaskTrackTest(folder:folder)
    try await temporalMatteProviderTests(folder:folder)
    try cleanPlateCaptureTests(folder:folder)
    try await backgroundVideoAudioTests(root:root,folder:folder)
    var visual = Project(title: "Effects render path")
    visual.append(SourceMedia(filename: "source.mp4", duration: 4))
    var state = visual.edit
    var noir = VideoEffectSettings(.noir, start: 0, end: 4); noir.set("grain", .toggle(false))
    state.clips[0].videoEffects = [noir]; visual.commit(state)
    let media = try await MediaRenderer.timeline(project: visual, folder: folder)
    let preview = AVAssetImageGenerator(asset: media.composition); preview.videoComposition = media.videoComposition
    preview.maximumSize = CGSize(width: 320, height: 180); preview.requestedTimeToleranceBefore = .zero; preview.requestedTimeToleranceAfter = .zero
    let previewImage = try await preview.image(at: CMTime(seconds: 1, preferredTimescale: 30)).image
    let output = folder.appendingPathComponent("effects.mp4")
    _ = try await MediaRenderer.render(project: visual, folder: folder, destination: output) { _ in }
    let asset = AVURLAsset(url: output)
    let exported = AVAssetImageGenerator(asset: asset); exported.maximumSize = CGSize(width: 320, height: 180)
    exported.requestedTimeToleranceBefore = .zero; exported.requestedTimeToleranceAfter = .zero
    let exportedImage = try await exported.image(at: CMTime(seconds: 1, preferredTimescale: 30)).image
    let context = CIContext()
    func pixels(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 320*180*4)
        context.render(CIImage(cgImage: image), toBitmap: &bytes, rowBytes: 320*4, bounds: CGRect(x: 0,y: 0,width: 320,height: 180), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return bytes
    }
    let a = pixels(previewImage), b = pixels(exportedImage)
    var chroma = 0
    for i in stride(from: 0, to: a.count, by: 4) { chroma += abs(Int(a[i])-Int(a[i+1])); chroma += abs(Int(a[i+1])-Int(a[i+2])) }
    let difference = zip(a,b).reduce(0.0) { $0 + abs(Double($1.0)-Double($1.1)) } / Double(a.count)
    try require(Double(chroma)/Double(320*180) < 2, "Noir actually makes preview monochrome")
    try require(difference < 3, "Export matches editor shader output within encode tolerance: \(difference)")
    let length = try await asset.load(.duration).seconds
    try require(abs(length-4) < 1.0/30, "Effects export preserves full source duration")
    var split = VideoEffectSettings(.kaleidoscope, start: 0.5, end: 3.5)
    let divisions = split.parameters.firstIndex { $0.id == "divisions" }!
    split.parameters[divisions].setKeyframe(at: 0.5, value: .number(3))
    split.parameters[divisions].setKeyframe(at: 2, value: .number(9))
    split.set("centerX", .number(0.42)); split.set("centerY", .number(0.67)); split.set("splitAngle", .number(37))
    let pan = split.parameters.firstIndex { $0.id == "sourcePanX" }!
    split.parameters[pan].setKeyframe(at: 0.5, value: .number(-0.32))
    split.parameters[pan].setKeyframe(at: 3.5, value: .number(0.58))
    split.set("sourcePanY", .number(0.24))
    let sourceTurn = split.parameters.firstIndex { $0.id == "sourceAngle" }!
    split.parameters[sourceTurn].setKeyframe(at: 0.5, value: .number(33))
    split.parameters[sourceTurn].setKeyframe(at: 3.5, value: .number(-78))
    var patterned = visual
    var patternedEdit = patterned.edit
    patternedEdit.clips[0].videoEffects = [split]
    patterned.commit(patternedEdit)
    let patternedMovie = folder.appendingPathComponent("kaleidoscope.mp4")
    _ = try await MediaRenderer.render(project: patterned, folder: folder, destination: patternedMovie) { _ in }
    let timeline = try await MediaRenderer.timeline(project: patterned, folder: folder, effectPreparation: .cached)
    // Compare geometry inside the same project color pipeline. A standalone
    // generator can interpret the test camera's untagged SDR primaries differently.
    var neutralProject = patterned, neutralEdit = patterned.edit
    neutralEdit.clips[0].videoEffects = nil
    neutralProject.commit(neutralEdit)
    let neutralMedia = try await MediaRenderer.timeline(project: neutralProject, folder: folder, forceCustom: true)
    let rawMovie = AVAssetImageGenerator(asset: neutralMedia.composition)
    rawMovie.videoComposition = neutralMedia.videoComposition
    let live = AVAssetImageGenerator(asset: timeline.composition)
    live.videoComposition = timeline.videoComposition
    let saved = AVAssetImageGenerator(asset: AVURLAsset(url: patternedMovie))
    for generator in [rawMovie, live, saved] {
        generator.maximumSize = CGSize(width: 320, height: 180)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
    }
    for t in [0.2, 1.0, 2.5, 3.8] {
        let time = CMTime(seconds: t, preferredTimescale: 30)
        let original = pixels(try await rawMovie.image(at: time).image)
        let shown = pixels(try await live.image(at: time).image)
        let result = pixels(try await saved.image(at: time).image)
        func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
            zip(a,b).reduce(0.0) { $0 + abs(Double($1.0)-Double($1.1)) } / Double(a.count)
        }
        try require(difference(shown,result) < 5, "Kaleidoscope preview/export agreement at \(t)")
        let changed = difference(original,result)
        try require(t < 0.5 || t >= 3.5 ? changed < 5 : changed > 12, "Kaleidoscope respects the selected interval at \(t), difference \(changed)")
    }
    print("PASS: animated source pan and rotation with 3/9-way Kaleidoscope, selected-range playback and encoded frames")
    var rgb = VideoEffectSettings(.rgbOffset, start: 0.5, end: 3.5)
    rgb.set("redX", .number(0.8)); rgb.set("greenY", .number(-0.75))
    let blue = rgb.parameters.firstIndex { $0.id == "blueX" }!
    rgb.parameters[blue].setKeyframe(at: 0.5, value: .number(-0.7))
    rgb.parameters[blue].setKeyframe(at: 3.5, value: .number(0.7))
    var strobe = VideoEffectSettings(.negativeStrobe, start: 0.5, end: 3.5)
    strobe.set("frequency", .number(4)); strobe.set("timedBurst", .toggle(true)); strobe.set("burstLength", .number(1))
    var optical = visual, opticalEdit = visual.edit
    opticalEdit.clips[0].videoEffects = [rgb]; optical.commit(opticalEdit)
    let registered = try await MediaRenderer.timeline(project: optical, folder: folder)
    opticalEdit.clips[0].videoEffects = [rgb, strobe]; optical.commit(opticalEdit)
    let opticalFile = folder.appendingPathComponent("optical.mp4")
    _ = try await MediaRenderer.render(project: optical, folder: folder, destination: opticalFile) { _ in }
    let opticalTimeline = try await MediaRenderer.timeline(project: optical, folder: folder)
    let registeredFrames = AVAssetImageGenerator(asset: registered.composition)
    registeredFrames.videoComposition = registered.videoComposition
    let previewFrames = AVAssetImageGenerator(asset: opticalTimeline.composition)
    previewFrames.videoComposition = opticalTimeline.videoComposition
    let exportedFrames = AVAssetImageGenerator(asset: AVURLAsset(url: opticalFile))
    for generator in [registeredFrames, previewFrames, exportedFrames] {
        generator.maximumSize = CGSize(width: 320, height: 180)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
    }
    func meanError(_ a: [UInt8], _ b: [UInt8]) -> Double {
        zip(a,b).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(a.count)
    }
    for index in [6, 16, 20, 24, 28, 49, 109, 21] {
        let t = CMTime(value: Int64(index), timescale: 30)
        let original = pixels(try await rawMovie.image(at: t).image)
        let positive = pixels(try await registeredFrames.image(at: t).image)
        let shown = pixels(try await previewFrames.image(at: t).image)
        let result = pixels(try await exportedFrames.image(at: t).image)
        try require(meanError(shown, result) < 5, "Optical preview/export agree at frame \(index)")
        let negative = [20, 21, 28].contains(index)
        try require(negative ? meanError(positive, result) > 35 : meanError(positive, result) < 5, "Strobe polarity and burst duration at frame \(index)")
        if [16,24,49].contains(index) { try require(meanError(original, positive) > 1, "RGB offset visible at frame \(index)") }
    }
    print("PASS: timed negative burst over animated RGB offsets, preview and exported movie")
    let quant = VideoEffectSettings(.quantization, start: 0, end: 4)
    let first = try await VideoEffectAnalysis.shared.palette(source: visual.sources[0], effect: quant, folder: folder)
    let again = try await VideoEffectAnalysis.shared.palette(source: visual.sources[0], effect: quant, folder: folder)
    try require(first.frames.count >= 19 && first.palette(at: 3.2) == again.palette(at: 3.2), "Source-time palette cache is seek-order independent")
    let native=CGSize(width:640,height:360)
    var inputClip=visual.history[0].clips[0];inputClip.videoEffects=[noir,quant]
    let inputInstruction=VideoToolInstruction(trackID:1,clip:inputClip,start:.zero,transform:.identity,sourceSize:native,canvas:native,stabilization:nil,sequenceClock:VideoEffectSequenceClock(inputClip))
    var sceneClip = inputClip
    sceneClip.videoEffects = [quant]
    let sceneInstruction = VideoToolInstruction(trackID: 1, clip: sceneClip, start: .zero, transform: .identity,
        sourceSize: native, canvas: native, stabilization: nil, sequenceClock: VideoEffectSequenceClock(sceneClip))
    let fromFrame = try await VideoEffectAnalysis.shared.sample(source: visual.sources[0], effect: quant, folder: folder,
        instruction: sceneInstruction, time: 1.5, count: 4)
    func coloredEntries(_ palette: EffectPalette) -> Int {
        palette.colors.filter { c in max(c.red,c.green,c.blue) - min(c.red,c.green,c.blue) > 0.2 }.count
    }
    try require(coloredEntries(fromFrame) >= 2 && first.frames.allSatisfy { coloredEntries($0.palette) >= 2 },
                "From scene and Save palette sample actual chroma from a decoded color chart")
    var sampledEffect = quant
    sampledEffect.palette = fromFrame.colors
    sampledEffect.set("palette", .choice("Saved"))
    let immediately = VideoEffectInputs.displayPalette(for: sampledEffect, at: 1.5, analyzed: nil)
    try require(immediately?.valid == true && immediately?.colors == fromFrame.colors, "Saved colors are available on the first frame")
    let graded=try await VideoEffectAnalysis.shared.palette(source:visual.sources[0],effect:quant,folder:folder,instruction:inputInstruction)
    try require(graded.frames.allSatisfy { $0.palette.colors.allSatisfy { abs($0.red-$0.green)<0.002 && abs($0.green-$0.blue)<0.002 } },"Palette analysis uses preceding Noir shader instead of raw source colours")
    var lock=quant
    let lockParameter=lock.parameters.firstIndex(where:{$0.id=="lockPalette"})!
    lock.parameters[lockParameter].setKeyframe(at:0,value:.toggle(false))
    lock.parameters[lockParameter].setKeyframe(at:1,value:.toggle(true))
    lock.parameters[lockParameter].setKeyframe(at:2,value:.toggle(false))
    let locked=try await VideoEffectAnalysis.shared.palette(source:visual.sources[0],effect:lock,folder:folder)
    try require(locked.palette(at:1.1)==locked.palette(at:1.9) && locked.frames.contains(where:{$0.time>=2.2}),"Palette locks across its interval and resumes after an Unlock keyframe")
    lock.lockedPalette=try await VideoEffectAnalysis.shared.sample(source:visual.sources[0],effect:quant,folder:folder,instruction:inputInstruction,time:2.7,count:4)
    let lockCopy=try JSONDecoder().decode(VideoEffectSettings.self,from:JSONEncoder().encode(lock))
    try require(lockCopy==lock && lockCopy.valid,"Exact-frame locked palette survives reopening")
    var shortClip=inputClip;shortClip.start=1;shortClip.end=2
    let shortInstruction=VideoToolInstruction(trackID:1,clip:shortClip,start:.zero,transform:.identity,sourceSize:native,canvas:native,stabilization:nil,sequenceClock:VideoEffectSequenceClock(shortClip))
    let shortTrack=try await VideoEffectAnalysis.shared.palette(source:visual.sources[0],effect:quant,folder:folder,instruction:shortInstruction)
    try require(shortTrack.frames.count<=6 && shortTrack.frames.first!.time>=1 && shortTrack.frames.last!.time<2,"A trimmed clip plans only its own palette range")
    let analysisWriter=try EffectAnalysisWriter(folder:folder)
    let fixedPalette=EffectPalette(colors:[EffectRGB(0,0,0),EffectRGB(0.5,0,0),EffectRGB(1,0.5,0),EffectRGB(1,1,1)],thresholds:[0.1,0.4,0.7])
    try analysisWriter.append(time:0,palettes:[quant.id:fixedPalette],mask:nil);try analysisWriter.checkpoint()
    var capturedQuant=quant;capturedQuant.analysisFile=analysisWriter.metadataName;capturedQuant.analysisDataFile=analysisWriter.dataName
    var captureCrank=VideoEffectSettings(.undercranking,start:0,end:4);captureCrank.analysisFile=analysisWriter.metadataName;captureCrank.analysisDataFile=analysisWriter.dataName
    var capturedProject=Project(title:"Recorded palette preservation")
    capturedProject.append(SourceMedia(filename:"source.mp4",duration:4,videoEffects:[captureCrank,capturedQuant]))
    let captureMedia=try await MediaRenderer.timeline(project:capturedProject,folder:folder)
    try require(captureMedia.videoComposition.instructions.compactMap {$0 as? VideoToolInstruction}.allSatisfy {$0.effectPalettes.isEmpty},"Retiming pieces reuse the captured palette when its pixel inputs have not changed")
    let bypassMedia=try await MediaRenderer.timeline(project:capturedProject,folder:folder,previewDiagnostics:true,bypassVideoEffects:true)
    try require(bypassMedia.composition.duration==captureMedia.composition.duration && bypassMedia.videoComposition.instructions.compactMap {$0 as? VideoToolInstruction}.allSatisfy {!$0.videoEffectsEnabled},"Visual comparison preserves the time-effect source clock and project duration")
    var editedCapture=capturedProject.edit;editedCapture.clips[0].videoEffects![1].set("colors",.number(8));capturedProject.commit(editedCapture)
    let draftMedia=try await MediaRenderer.timeline(project:capturedProject,folder:folder,previewDiagnostics:true,effectPreparation:.cached)
    try require(draftMedia.videoComposition.instructions.compactMap {$0 as? VideoToolInstruction}.allSatisfy {$0.effectPalettes[quant.id]?.frames.isEmpty==true},"Interactive count changes invalidate captured palettes without scanning the take")
    try require(draftMedia.effectAnalysisPending,"A provisional preview reports its unfinished analysis")
    let draftGenerator=AVAssetImageGenerator(asset:draftMedia.composition);draftGenerator.videoComposition=draftMedia.videoComposition
    _ = try await draftGenerator.image(at:CMTime(seconds:1,preferredTimescale:30))
    async let firstPreparation=VideoEffectPreparation.refine {
        try await MediaRenderer.timeline(project:capturedProject,folder:folder,previewDiagnostics:true)
    }
    async let secondPreparation=VideoEffectPreparation.refine {
        try await MediaRenderer.timeline(project:capturedProject,folder:folder,previewDiagnostics:true)
    }
    let (finalDiagnostic,concurrentDiagnostic)=try await (firstPreparation,secondPreparation)
    let concurrentInstructions=concurrentDiagnostic.videoComposition.instructions.compactMap {$0 as? VideoToolInstruction}
    try require(!concurrentDiagnostic.effectAnalysisPending && concurrentInstructions.allSatisfy {!($0.effectPalettes[quant.id]?.frames.isEmpty ?? true)},"Concurrent refinements both receive the completed palette analysis")
    let cachedDiagnostic=try await MediaRenderer.timeline(project:capturedProject,folder:folder,previewDiagnostics:true,effectPreparation:.cached)
    let finalInstructions=finalDiagnostic.videoComposition.instructions.compactMap {$0 as? VideoToolInstruction},cachedInstructions=cachedDiagnostic.videoComposition.instructions.compactMap {$0 as? VideoToolInstruction}
    try require(!finalDiagnostic.effectAnalysisPending && !cachedDiagnostic.effectAnalysisPending && finalInstructions.count==cachedInstructions.count,"Diagnostic viewing and deterministic analysis are independent")
    try require(zip(finalInstructions,cachedInstructions).allSatisfy {$0.effectPalettes[quant.id]?.frames.map(\.palette)==$1.effectPalettes[quant.id]?.frames.map(\.palette)},"A quick rebuild uses the exact prepared palette instead of per-frame fallbacks")
    try faceTrackingTests()
    let targets=EffectSubjectTrack(samples:[
        EffectSubjectSample(time:0,box:CGRect(x:0.2,y:0.2,width:0.2,height:0.2),confidence:0.9,face:true),
        EffectSubjectSample(time:0.2,box:CGRect(x:0.4,y:0.2,width:0.2,height:0.2),confidence:0.9,face:true)])
    try require(targets.valid && abs(targets.sample(at:0.1)!.center.x-0.4)<0.000001 && targets.sample(at:1)==nil,"Subject trajectories interpolate without following a stale lost face")
    var capturedTargets=targets;capturedTargets.stepwise=true
    var lost=targets.samples.last!;lost.time=0.3;lost.lost=true;capturedTargets.samples.append(lost)
    try require(capturedTargets.sample(at:0.1)==targets.samples[0] && capturedTargets.sample(at:0.31)==nil,"Captured target movement and loss replay exactly without invented interpolation")
    let noSubject=try EffectSubjectTracker(live:false).update(CIImage(color:.black).cropped(to:CGRect(x:0,y:0,width:256,height:144)),time:0)
    try require(noSubject==nil,"A blank scene does not invent a face target")
    print("PASS: processed palette input, exact-frame saved palette and animated lock/unlock")
    let colorContext=CIContext(options:[.workingColorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!])
    let colorBounds=CGRect(x:0,y:0,width:30,height:20)
    let bottom=CIImage(color:CIColor(red:0,green:0,blue:1)).cropped(to:colorBounds)
    let top=CIImage(color:CIColor(red:1,green:0,blue:0)).cropped(to:CGRect(x:0,y:10,width:30,height:10)).composited(over:bottom)
    let outlier=CIImage(color:.white).cropped(to:CGRect(x:15,y:15,width:1,height:1)).composited(over:top)
    let picked=VideoEffectAnalysis.sampleColor(outlier,point:CGPoint(x:0.5,y:0.2),context:colorContext)
    let pickedBottom=VideoEffectAnalysis.sampleColor(outlier,point:CGPoint(x:0.5,y:0.8),context:colorContext)
    try require(picked.red>0.99 && picked.green<0.001 && pickedBottom.blue>0.99,"Preview colour picker uses top-down coordinates and a 9×9 median that rejects a bright outlier")
    let frozen = TimelineEditing.freezing(visual.history[0], at: 2)
    try require(frozen.1 != nil && frozen.0.clips.count == 3 && abs(frozen.0.duration-7)<0.00001, "Freeze inserts a three-second hold without removing source footage")
    let held = frozen.0.clips[1]
    try require(held.frozenFrame?.sourceTime == 2 && frozen.0.clips[2].start == 2, "Freeze and following footage share source position; no missing final section")
    let splitHold = TimelineEditing.split(frozen.0, at: 3)
    try require(splitHold.clips.count == 4 && splitHold.duration == 7 && splitHold.clips[2].frozenFrame?.offset == 1, "Splitting a hold preserves its full duration and animation phase")
    var freezing = visual; freezing.commit(frozen.0); try freezing.validate()
    let freezeMedia = try await MediaRenderer.timeline(project: freezing, folder: folder)
    let freezeGenerator = AVAssetImageGenerator(asset: freezeMedia.composition); freezeGenerator.videoComposition = freezeMedia.videoComposition
    freezeGenerator.requestedTimeToleranceBefore = .zero; freezeGenerator.requestedTimeToleranceAfter = .zero
    _ = try await freezeGenerator.image(at: CMTime(seconds: 3.5, preferredTimescale: 30))
    let freezeOutput = folder.appendingPathComponent("freeze.mp4")
    _ = try await MediaRenderer.render(project: freezing, folder: folder, destination: freezeOutput) { _ in }
    let frozenLength = try await AVURLAsset(url: freezeOutput).load(.duration).seconds
    try require(abs(frozenLength-7)<1.0/30, "Freeze export includes hold and the full remaining footage")
    var stepState = visual.history[0]
    var step = VideoEffectSettings(.stepPrinting, start: 0, end: 4); step.set("speed", .number(0.5))
    stepState.clips[0].videoEffects = [step]
    try require(stepState.duration == 8, "Slow step printing retimes the timeline at half speed")
    var stepped = visual; stepped.commit(stepState)
    let sourceIndex=try await VideoEffectFrameAnalysis.shared.index(url:folder.appendingPathComponent("source.mp4"),folder:folder)
    try require(sourceIndex.times.count==120 && sourceIndex.times.enumerated().allSatisfy {abs($0.element-Double($0.offset)/30)<0.000001},"Compressed frame index skips edit markers and uses displayed PTS, including B-frame priming")
    let unavailableCache=folder.appendingPathComponent("not-a-cache-directory")
    try Data([0]).write(to:unavailableCache)
    let uncached=try await VideoEffectFrameAnalysis().index(url:folder.appendingPathComponent("source.mp4"),folder:unavailableCache)
    try require(uncached.times==sourceIndex.times,"An unwritable disposable cache cannot fail a valid timeline")
    let stepMedia = try await MediaRenderer.timeline(project: stepped, folder: folder)
    let stepGenerator = AVAssetImageGenerator(asset: stepMedia.composition); stepGenerator.videoComposition = stepMedia.videoComposition
    stepGenerator.maximumSize = CGSize(width: 320,height: 180); stepGenerator.requestedTimeToleranceBefore = .zero; stepGenerator.requestedTimeToleranceAfter = .zero
    let heldA = try await stepGenerator.image(at: CMTime(seconds: 1.0,preferredTimescale: 30)).image
    let heldB = try await stepGenerator.image(at: CMTime(seconds: 1.1,preferredTimescale: 30)).image
    try require(pixels(heldA) == pixels(heldB), "Step printing repeats the same accumulated source block")
    var super8=VideoEffectSettings(.superEight,start:0,end:4)
    super8.set("leaks",.number(1))
    let fadeIndex=super8.parameters.firstIndex(where:{$0.id=="fade"})!
    super8.parameters[fadeIndex].setKeyframe(at:0,value:.number(0))
    super8.parameters[fadeIndex].setKeyframe(at:4,value:.number(1))
    var cadenceState=visual.history[0];cadenceState.clips[0].videoEffects=[super8]
    var cadenceProject=visual;cadenceProject.commit(cadenceState)
    let cadenceMedia=try await MediaRenderer.timeline(project:cadenceProject,folder:folder)
    let cadenceGenerator=AVAssetImageGenerator(asset:cadenceMedia.composition);cadenceGenerator.videoComposition=cadenceMedia.videoComposition
    cadenceGenerator.maximumSize=CGSize(width:320,height:180);cadenceGenerator.requestedTimeToleranceBefore = .zero;cadenceGenerator.requestedTimeToleranceAfter = .zero
    let cadenceClock=VideoEffectCadenceClock(effects:[super8]),sourceReader=try VideoEffectSourceReader(url:folder.appendingPathComponent("source.mp4"),hdr:false)
    var heldPixels:[Int:[UInt8]]=[:],framePixels:[Int:[UInt8]]=[:],lastHold = -1,liveTime=0.0
    for frame in 0..<60 {
        let t=Double(frame)/30,hold=cadenceClock.hold(at:t)!
        if hold.index != lastHold {liveTime=t;lastHold=hold.index}
        let plan=VideoEffectSamplePlan.make(clip:cadenceState.clips[0],sourceTime:t,sourceFPS:30,clock:VideoEffectSequenceClock(cadenceState.clips[0]))!
        let sample=try sourceReader.sample(at:plan.times[0],firstAtOrAfter:plan.firstAtOrAfter,before:plan.before)
        try require(abs(sample.time-liveTime)<0.0001,"The decoded held source frame matches the live first-frame selection")
        let picture=pixels(try await cadenceGenerator.image(at:CMTime(value:Int64(frame),timescale:30)).image)
        if let previous=heldPixels[hold.index] {try require(picture==previous,"Held Super 8 freezes animated color, grain and light leaks together")}
        heldPixels[hold.index]=picture;framePixels[frame]=picture
    }
    for frame in (0..<60).map({($0*37)%60}) {
        let picture=pixels(try await cadenceGenerator.image(at:CMTime(value:Int64(frame),timescale:30)).image)
        try require(picture==framePixels[frame],"Arbitrary seeks reproduce the same held look as sequential playback")
    }
    let sixty=try VideoEffectSourceReader(url:root.appendingPathComponent("cadence60.mp4"),hdr:false)
    let sixtyClock=VideoEffectCadenceClock(effects:[super8])
    var expected:[Int:Double]=[:]
    for frame in 0..<120 {
        let t=Double(frame)/60,hold=sixtyClock.hold(at:t)!
        if expected[hold.index]==nil {expected[hold.index]=t}
        let sample=try sixty.sample(at:hold.boundary,firstAtOrAfter:true,before:2)
        try require(abs(sample.time-expected[hold.index]!)<0.0001,"An imported 60fps movie selects the first decoded frame of each hold")
    }
    for frame in (0..<120).map({($0*37)%120}) {
        let hold=sixtyClock.hold(at:Double(frame)/60)!
        let sample=try sixty.sample(at:hold.boundary,firstAtOrAfter:true,before:2)
        try require(abs(sample.time-expected[hold.index]!)<0.0001,"A 60fps reader selects the same frame after arbitrary seeks")
    }
    var samplingClip=cadenceState.clips[0]
    let paletteEffect=VideoEffectSettings(.quantization,start:0,end:4)
    samplingClip.videoEffects?.append(paletteEffect)
    let samplingInstruction=VideoToolInstruction(trackID:1,clip:samplingClip,start:.zero,transform:.identity,sourceSize:native,canvas:native,stabilization:nil,sequenceClock:VideoEffectSequenceClock(samplingClip))
    let pickedA=try await VideoEffectAnalysis.shared.color(source:visual.sources[0],effect:paletteEffect,folder:folder,instruction:samplingInstruction,time:1,point:CGPoint(x:0.3,y:0.3))
    let pickedB=try await VideoEffectAnalysis.shared.color(source:visual.sources[0],effect:paletteEffect,folder:folder,instruction:samplingInstruction,time:1+1.0/30,point:CGPoint(x:0.3,y:0.3))
    let paletteA=try await VideoEffectAnalysis.shared.sample(source:visual.sources[0],effect:paletteEffect,folder:folder,instruction:samplingInstruction,time:1,count:4)
    let paletteB=try await VideoEffectAnalysis.shared.sample(source:visual.sources[0],effect:paletteEffect,folder:folder,instruction:samplingInstruction,time:1+1.0/30,count:4)
    try require(pickedA==pickedB && paletteA==paletteB,"Color and palette picking sample the held image actually shown in the preview")
    print("CADENCE: jittered host-clock movie")
    try await jitteredCadenceMovieTest(folder:folder)
    try await jitteredCadenceMovieTest(folder:folder,variableRate:true)
    // Speed-integration pieces use the original clock and trim, not their own
    // short source ranges. A split preserves the cadence's source phase.
    var animatedCadence=VideoEffectSettings(.undercranking,start:0,end:4)
    let speedParameter=animatedCadence.parameters.firstIndex(where:{$0.id=="speed"})!
    animatedCadence.parameters[speedParameter].setKeyframe(at:0,value:.number(1))
    animatedCadence.parameters[speedParameter].setKeyframe(at:4,value:.number(1.5))
    var rampClip=cadenceState.clips[0];rampClip.videoEffects=[animatedCadence,super8]
    let integrated=VideoEffectSequenceClock(rampClip)
    var splitClip=rampClip;splitClip.start=1.5
    let splitClock=VideoEffectSequenceClock(splitClip)
    var lastBoundary = -1.0
    for piece in rampClip.playbackPieces {
        for t in [piece.start,(piece.start+piece.end)/2,piece.end-0.000001] {
            let plan=VideoEffectSamplePlan.make(clip:piece,sourceTime:t,sourceFPS:30,clock:integrated)!
            try require(plan.times[0]>=lastBoundary-0.00001,"Speed-ramp pieces never rewind cadence frames")
            if t>=1.6 {try require(abs(integrated.cadence.hold(at:t)!.boundary-splitClock.cadence.hold(at:t)!.boundary)<0.00001,"Splitting does not reset the cadence clock")}
            lastBoundary=plan.times[0]
        }
    }
    print("PASS: decoded live cadence, frozen shader clocks, random seeks and integrated speed-ramp holds")
    var partial=visual.history[0]
    var crank=VideoEffectSettings(.undercranking,start:1,end:3)
    crank.set("speed",.number(1.5));crank.set("mute",.toggle(true))
    partial.clips[0].videoEffects=[crank]
    let clock=partial.clips[0]
    try require(abs(clock.duration-(2+2/1.5))<0.000001,"A partial time effect retimes only its covered source interval")
    try require(clock.playbackPieces.count==3 && abs(clock.sourceTime(at:2)-2.5)<0.000001 && abs(clock.timelineTime(forSource:2.5)-2)<0.000001,"Seeking uses the same partial-effect clock as composition")
    for source in stride(from:0.0,through:4,by:0.05) {
        try require(abs(clock.sourceTime(at:clock.timelineTime(forSource:source))-source)<0.000001,"Source/timeline clock is invertible")
    }
    var partialProject=visual;partialProject.commit(partial);try partialProject.validate()
    let partialMedia=try await MediaRenderer.timeline(project:partialProject,folder:folder)
    try require(abs(partialMedia.composition.duration.seconds-clock.duration)<1.0/30000,"Partial speed renders the expected complete duration")
    let partAudio=try await partialMedia.composition.loadTracks(withMediaType:.audio).first!
    let sound=try await partAudio.load(.segments).filter {!$0.isEmpty}
    try require(sound.count==2 && abs(sound[0].timeMapping.target.duration.seconds-1)<0.0001 && abs(sound[1].timeMapping.target.start.seconds-(1+2/1.5))<0.0001,"Undercranking mute leaves source audio outside the effect untouched")
    let p=crank.parameters.firstIndex(where:{$0.id=="speed"})!
    crank.parameters[p].setKeyframe(at:1,value:.number(1))
    crank.parameters[p].setKeyframe(at:3,value:.number(1.5))
    partial.clips[0].videoEffects=[crank]
    let animated=partial.clips[0]
    let exact=2+log(1.5)/0.25
    try require(abs(animated.duration-exact)<0.0001 && animated.playbackPieces.count<130,"Animated speed integrates smoothly with bounded composition segments")
    let divided=TimelineEditing.split(partial,at:1.7)
    try require(divided.timeline.video[0].mapping.duration == EditTime(1.7) && divided.timeline.duration == partial.timeline.duration
        && abs(divided.clips[0].duration - 1.7) <= 1 / Double(EditTime.scale),
        "Animated speed keeps exact split ticks and source-grid timing: \(divided.clips[0].duration), \(divided.duration), \(partial.duration)")
    var cut=animated;cut.start=animated.sourceTime(at:0.7);cut.end=animated.sourceTime(at:2.3)
    try require(abs(cut.duration-1.6)<0.000001,"Trimming an animated rate preserves the same source clock")
    let imageOnly=EffectParameterKind.media(image:true,video:false)
    try require(!imageOnly.accepts(.media("clip.mov")) && imageOnly.accepts(.media("plate.png")),"Clean plate rejects movie media")
    var key=VideoEffectSettings(.chromaKey,start:0,end:4)
    key.set("background",.choice("Video"));key.set("media",.media("source.mp4"));key.set("background",.choice("Image"));key.sanitizeBackgroundMedia(at:0)
    try require(key.value("media")==EffectValue.media(nil),"Switching background type clears incompatible media")
    key.set("view",.choice("Matte"))
    try require(key.recordingResult.choice("view")=="Result" && key.choice("view")=="Matte","Diagnostic views never become recorded effect recipes")
    print("PASS: partial and animated effect timing, scoped mute, media validation and diagnostic recipe isolation")
    print("PASS: inserted freeze, split hold, full-duration export and repeated step-print frames")
    print("PASS: video effect persistence, split/paste identity, undo media retention, real preview/export pixels and palette cache")
}

private func jitteredCadenceMovieTest(folder:URL,variableRate:Bool=false) async throws {
    let url=folder.appendingPathComponent(variableRate ? "cadence-variable.mov" : "cadence-jitter.mov"),size=CGSize(width:64,height:64)
    let origin=CMTime(value:734_123_456_789_013,timescale:1_000_000_000)
    let times=(0..<300).map {frame -> Double in
        let nominal:Double
        if variableRate,frame>=200 {nominal=10+Double(frame-200)/60}
        else if variableRate,frame>=100 {nominal=100.0/30+Double(frame-100)/15}
        else {nominal=Double(frame)/30}
        let jitter=frame==0 ? 0 : (frame.isMultiple(of:2) ? 0.00004 : -0.00004)+Double(frame)*0.000057
        return nominal+jitter
    }
    let duration=variableRate ? times.last!+1.0/60 : 10
    let writer=try AVAssetWriter(outputURL:url,fileType:.mov)
    let input=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:64,AVVideoHeightKey:64])
    input.mediaTimeScale=600
    let adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:64,kCVPixelBufferHeightKey as String:64])
    writer.add(input);guard writer.startWriting() else {throw writer.error ?? ProjectError.invalidMedia};writer.startSession(atSourceTime:origin)
    let context=CIContext(),bounds=CGRect(origin:.zero,size:size)
    for frame in 0..<300 {
        let deadline=Date().addingTimeInterval(10)
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing,Date()<deadline else {writer.cancelWriting();throw writer.error ?? ProjectError.invalidMedia}
            try Task.checkCancellation();try await Task.sleep(nanoseconds:1_000_000)
        }
        var pixel:CVPixelBuffer?
        guard let pool=adaptor.pixelBufferPool,CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault,pool,&pixel)==kCVReturnSuccess,let pixel else {throw ProjectError.invalidMedia}
        let color=CIColor(red:Double(frame%256)/255,green:Double(frame/256)/255,blue:0)
        context.render(CIImage(color:color).cropped(to:bounds),to:pixel)
        guard adaptor.append(pixel,withPresentationTime:origin+CMTime(seconds:times[frame],preferredTimescale:1_000_000_000)) else {throw writer.error ?? ProjectError.invalidMedia}
    }
    writer.endSession(atSourceTime:origin+CMTime(seconds:duration,preferredTimescale:600));input.markAsFinished();await writer.finishWriting()
    guard writer.status == .completed else {throw writer.error ?? ProjectError.invalidMedia}
    let reader=try VideoEffectSourceReader(url:url,hdr:false)
    for fps in [12.0,16,18] {
        var effect=VideoEffectSettings(.undercranking,start:0,end:duration);effect.set("fps",.number(fps))
        let clock=VideoEffectCadenceClock(effects:[effect]);var last = -1,held=0.0
        for frame in 0..<300 {
            let live=VideoEffectTime.captureTime(times[frame]),hold=clock.hold(at:live)!
            if hold.index != last {held=live;last=hold.index}
            let decoded=try reader.sample(at:hold.boundary,firstAtOrAfter:true,before:duration)
            try require(abs(decoded.time-held)<0.0001 && VideoEffectTime.frameIndex(decoded.time,fps:30)==VideoEffectTime.frameIndex(held,fps:30),"MOV timescale rounding matches jittered live hold selection and grain seeds over ten seconds")
        }
    }
    let index=try await VideoEffectFrameAnalysis.shared.index(url:url,folder:folder)
    print("CADENCE: indexed",index.times.count,"frames",variableRate)
    try require(index.times.count==300,"Compressed-packet indexing retains every real movie frame")
    for count in [2,3,6] {
        for start in [0,37,150] {
            var step=VideoEffectSettings(.stepPrinting,start:index.times[start],end:duration);step.set("step",.number(Double(count)));step.set("smear",.number(0))
            let clip=TimelineClip(sourceID:UUID(),start:0,end:duration,videoEffects:[step]),clock=VideoEffectSequenceClock(clip)
            for frame in start..<300 {
                let plan=VideoEffectSamplePlan.make(clip:clip,sourceTime:index.times[frame],sourceFPS:30,clock:clock,frames:index)!
                let block=start+(frame-start)/count*count
                for j in 0..<count {
                    let decoded=try reader.sample(at:plan.times[j],firstAtOrAfter:plan.firstAtOrAfter,before:plan.before)
                    let expected=VideoEffectTime.captureTime(times[min(299,block+j)])
                    try require(abs(decoded.time-expected)<0.000001,"Step Printing selects each actual source-frame ordinal once, including variable-rate sections")
                }
            }
        }
    }
    let mid=index.times[37]+0.01
    try require(index.block(at:mid,origin:mid,count:3,lower:0,upper:duration,firstAtOrAfter:false)==Array(index.times[37...39]),"An effect starting inside a frame uses the frame already on screen")
    let trim=index.times[50]+0.01,split=index.times[150]+0.01
    for t in [trim,split,index.times[200]] {
        let block=index.block(at:t,origin:mid,count:3,lower:trim,upper:duration,firstAtOrAfter:false)
        try require(block.allSatisfy {$0>=index.times[51]},"Trimmed Step Printing never reads a removed frame")
    }
    var cadence=VideoEffectSettings(.undercranking,start:0,end:duration);cadence.set("fps",.number(16));cadence.set("speed",.number(1))
    let step=VideoEffectSettings(.stepPrinting,start:0,end:duration)
    let combined=TimelineClip(sourceID:UUID(),start:0,end:duration,videoEffects:[cadence,step]),combinedClock=VideoEffectSequenceClock(combined)
    // Deliberately visit frames out of order through the same bounded reader.
    for offset in 0..<60 {
        let frame=(offset*137)%300,t=index.times[frame],hold=combinedClock.cadence.hold(at:t)!
        let ordinal=min(299,index.first(at:hold.boundary)),first=ordinal/3*3
        let plan=VideoEffectSamplePlan.make(clip:combined,sourceTime:t,sourceFPS:30,clock:combinedClock,frames:index)!
        for j in 0..<3 {
            let actual=try reader.sample(at:plan.times[j],firstAtOrAfter:true,before:duration)
            try require(actual.time==index.times[min(299,first+j)],"Cadence plus Step Printing keeps ordinal blocks through random seeks")
        }
    }
    print("PASS: nonzero host origin, jittered \(variableRate ? "30/15/60" : "30")fps movie clocks and exact Step Printing frame blocks")
}

private func capturedEffectAnalysisTests(folder:URL) throws {
    let cacheParent=folder.appendingPathComponent("cache-spelling-test",isDirectory:true)
    let legacyCache=cacheParent.appendingPathComponent("Cache",isDirectory:true)
    try FileManager.default.createDirectory(at:legacyCache,withIntermediateDirectories:true)
    try require(ProjectCacheLocation.root(in:cacheParent,preferred:"cache").lastPathComponent=="Cache","Video analysis resolves the existing audio cache spelling without creating a case-colliding directory")
    let writer=try EffectAnalysisWriter(folder:folder)
    func mask(_ value:UInt8)->CVPixelBuffer {
        var pixel:CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault,8,4,kCVPixelFormatType_OneComponent8,nil,&pixel)
        let result=pixel!;CVPixelBufferLockBaseAddress(result,[])
        let base=CVPixelBufferGetBaseAddress(result)!.assumingMemoryBound(to:UInt8.self),row=CVPixelBufferGetBytesPerRow(result)
        for y in 0..<4 { for x in 0..<8 { base[y*row+x]=y<2 ? value : 0 } }
        CVPixelBufferUnlockBaseAddress(result,[]);return result
    }
    let a=mask(255),b=mask(128),id=UUID(),palette=EffectPalette(colors:[EffectRGB(0,0,0),EffectRGB(1,1,1)],thresholds:[0.3])
    try writer.append(time:0,palettes:[id:palette],mask:a,qualities:[id:.full])
    try writer.append(time:1.0/30,palettes:[id:palette],mask:a)
    try writer.append(time:2.0/30,palettes:[id:palette],mask:b,qualities:[id:.lite]);try writer.checkpoint()
    let reader=try EffectAnalysisReader(metadata:folder.appendingPathComponent(writer.metadataName),data:folder.appendingPathComponent(writer.dataName))
    try require(reader.analysis.masks.count==2 && reader.analysis.palettes[id]?.frames.count==1,"Capture reuses unchanged mask and palette without duplicating storage")
    try require(reader.analysis.qualities?[id]?.quality(at:0.01) == .full && reader.analysis.qualities?[id]?.quality(at:0.1) == .lite,"Live quality changes replay at their recorded source times")
    let context=CIContext(options:[.workingColorSpace:NSNull()])
    for (time,value) in [(0.0,Float(1)),(0.1,Float(128.0/255)),(0.01,Float(1))] {
        let image=try reader.mask(at:time)!
        var values=[Float](repeating:0,count:8*4*4)
        context.render(image,toBitmap:&values,rowBytes:8*16,bounds:CGRect(x:0,y:0,width:8,height:4),format:.RGBAf,colorSpace:nil)
        try require(abs(values[4*4]-value)<0.001 && values[(3*8+4)*4]==0,"Lossless asymmetric mask retains top/bottom orientation when seeking")
    }
    var corrupt=reader.analysis;corrupt.masks[0].offset = .max
    let invalid=folder.appendingPathComponent("invalid-analysis.json");try JSONEncoder().encode(corrupt).write(to:invalid)
    do { _ = try EffectAnalysisReader(metadata:invalid,data:folder.appendingPathComponent(writer.dataName));throw NSError(domain:"VideoEffectTest",code:1,userInfo:[NSLocalizedDescriptionKey:"Invalid mask offset accepted"]) }
    catch ProjectError.invalidDocument { }
    let temporal=try EffectAnalysisWriter(folder:folder,checkpointInterval:0)
    let initial=try EffectAnalysisReader(metadata:folder.appendingPathComponent(temporal.metadataName),data:folder.appendingPathComponent(temporal.dataName))
    try require(initial.analysis.masks.isEmpty && initial.analysis.temporalMattes==nil,"Even a recording interrupted before its first frame has valid analysis")
    let accepted=(0..<200).filter {$0%3 != 1}
    for frame in accepted {try temporal.append(time:Double(frame)/30,palettes:[:],mask:nil,temporalResets:[id:frame==0 || frame==90])}
    try temporal.checkpoint()
    let partial=try EffectAnalysisReader(metadata:folder.appendingPathComponent(temporal.metadataName),data:folder.appendingPathComponent(temporal.dataName))
    try require(partial.temporalMatte(for:id)?.map(\.tick)==accepted.map {Int64($0*20)} && partial.temporalMatte(for:id)?.filter(\.reset).map(\.tick)==[0,1800],"Accepted live frames and cut resets round-trip through compressed append-only chunks")
    try require(partial.analysis.temporalMattesFinalized==false,"An interrupted recording identifies its last checkpoint")
    try temporal.append(time:7,palettes:[:],mask:nil,temporalResets:[id:true]);try temporal.checkpoint(finalized:true)
    let complete=try EffectAnalysisReader(metadata:folder.appendingPathComponent(temporal.metadataName),data:folder.appendingPathComponent(temporal.dataName))
    try require(complete.analysis.temporalMattesFinalized==true && complete.temporalMatte(for:id)?.last?.tick==4200 && complete.temporalMatte(for:id)?.last?.reset==true,"Finalization flushes the last partial block without losing a reset")
    var corruptMatte=complete.analysis
    corruptMatte.temporalMattes?[id]?.chunks[0]=CapturedMatteChunk(offset:.max,bytes:64,count:8)
    try JSONEncoder().encode(corruptMatte).write(to:invalid)
    let optionalCorrupt=try EffectAnalysisReader(metadata:invalid,data:folder.appendingPathComponent(temporal.dataName))
    try require(optionalCorrupt.temporalMatte(for:id)==nil && optionalCorrupt.temporalMatte(for:id)==nil,"A damaged optional history falls back without preventing the movie from opening")
    var withMask=reader.analysis;withMask.temporalMattes=corruptMatte.temporalMattes
    try JSONEncoder().encode(withMask).write(to:invalid)
    let maskSurvives=try EffectAnalysisReader(metadata:invalid,data:folder.appendingPathComponent(writer.dataName))
    let survivingMask=try maskSurvives.mask(at:0)
    try require(maskSurvives.temporalMatte(for:id)==nil && survivingMask != nil,"Damaged temporal chunks do not invalidate saved person masks")
    print("PASS: captured analysis lossless replay, random access, deduplication and bounded file offsets")
}

func backgroundVideoAudioTests(root:URL,folder:URL) async throws {
    try FileManager.default.copyItem(at:root.appendingPathComponent("silent.mp4"),to:folder.appendingPathComponent("silent.mp4"))
    var clock=AudioEnvelopeClock()
    let firstTime=clock.start(reported:2,frames:480,rate:48000,fallback:0)
    let missing=clock.start(reported:.nan,frames:480,rate:48000,fallback:0)
    let sought=clock.start(reported:5,frames:480,rate:48000,fallback:0)
    try require(firstTime==2 && abs(missing-2.01)<1e-9 && sought==5,"Audio envelope clock retains successful pulls with missing timestamps and follows valid seek timestamps")
    let loop=EffectBackgroundLoop(duration:4)
    let phase=loop.phase(at:3.9)
    try require(abs(phase.incoming-0.1)<0.00001 && abs(phase.outgoing!-3.9)<0.00001 && abs(phase.blend-0.5)<0.00001,"Background loop overlaps two moving frames on one shared clock")
    print("BACKGROUND: preparing sequential readers")
    let movie=try EffectBackgroundMovie(url:folder.appendingPathComponent("source.mp4"))
    _ = try movie.image(at:3.9);_ = try movie.image(at:0.2);_ = try movie.image(at:8.1)
    var project=Project(title:"Background sound")
    project.append(SourceMedia(filename:"silent.mp4",duration:4))
    var effect=VideoEffectSettings(.chromaKey,start:0,end:4)
    effect.set("personHint",.toggle(false));effect.set("background",.choice("Video"));effect.set("media",.media("source.mp4"));effect.set("backgroundAudio",.toggle(true))
    var state=project.edit;state.clips[0].videoEffects=[effect];project.commit(state)
    print("BACKGROUND: composing sound")
    let media=try await MediaRenderer.timeline(project:project,folder:folder)
    let output=folder.appendingPathComponent("background.caf")
    print("BACKGROUND: rendering mixed sound")
    _ = try await MediaRenderer.processedAudio(asset:media.composition,duration:4,effects:[],outputURL:output,mix:media.audioMix) { _ in }
    let audio=try AVAudioFile(forReading:output,commonFormat:.pcmFormatFloat32,interleaved:false)
    func rms(at time:Double) throws -> Double {
        audio.framePosition=Int64(time*48000)
        let buffer=AVAudioPCMBuffer(pcmFormat:audio.processingFormat,frameCapacity:2400)!;try audio.read(into:buffer)
        let data=buffer.floatChannelData![0]
        return sqrt((0..<Int(buffer.frameLength)).reduce(0.0) { $0+Double(data[$1]*data[$1]) }/Double(buffer.frameLength))
    }
    let baseline=try rms(at:1),overlap=try rms(at:3.87)
    try require(baseline>0.006 && baseline<0.016,"Background audio is mixed at -18 dB below its original sine")
    try require(overlap>baseline*0.8 && overlap<baseline*1.2,"Loop audio remains continuous during moving video crossfade")
    var changed=TimelineEditing.split(project.edit,at:2)
    changed=changed.settingTransition(ClipTransition(style:.dissolve,duration:0.5),at:1)
    project.commit(changed)
    let transition=try await MediaRenderer.timeline(project:project,folder:folder)
    try require(transition.composition.tracks(withMediaType:.audio).count>=2,"Background sound survives transition composition without being discarded by its child timelines")
    func renderAudio(_ edit:EditState,name:String) async throws -> AVAudioFile {
        if CommandLine.arguments.contains("--effects-audio-stress") {print("AUDIO STRESS: rendering "+name)}
        var candidate=project
        if name.hasPrefix("main-") {candidate.sources[0].filename="source.mp4"}
        candidate.commit(edit)
        let timeline=try await MediaRenderer.timeline(project:candidate,folder:folder),file=folder.appendingPathComponent(name+".caf")
        var mix=timeline.audioMix
        if name=="background-animated-rate",let variant=ProcessInfo.processInfo.environment["YOUREC_AUDIO_REPRO"] {
            let changed=AVMutableAudioMix()
            changed.inputParameters=(mix?.inputParameters ?? []).map { original in
                let value=original.mutableCopy() as! AVMutableAudioMixInputParameters
                if variant=="no-tap" {value.audioTapProcessor=nil}
                if variant=="time-domain" {value.audioTimePitchAlgorithm = .timeDomain}
                return value
            }
            mix=changed
        }
        if name.hasSuffix("-export") {
            let exported=folder.appendingPathComponent(name+".m4a")
            guard let session=AVAssetExportSession(asset:timeline.composition,presetName:AVAssetExportPresetAppleM4A) else {throw ProjectError.invalidMedia}
            session.audioMix=mix;session.outputURL=exported;session.outputFileType = .m4a
            await session.export()
            guard session.status == .completed else {throw session.error ?? ProjectError.invalidMedia}
            return try AVAudioFile(forReading:exported,commonFormat:.pcmFormatFloat32,interleaved:false)
        }
        _ = try await MediaRenderer.processedAudio(asset:timeline.composition,duration:edit.duration,effects:[],outputURL:file,mix:mix) { _ in }
        return try AVAudioFile(forReading:file,commonFormat:.pcmFormatFloat32,interleaved:false)
    }
    func level(_ file:AVAudioFile,at time:Double,frames:AVAudioFrameCount=2400) throws -> Double {
        file.framePosition=Int64(time*file.processingFormat.sampleRate)
        let buffer=AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:frames)!;try file.read(into:buffer)
        guard buffer.frameLength>0 else {return 0};let data=buffer.floatChannelData![0]
        return sqrt((0..<Int(buffer.frameLength)).reduce(0.0){$0+Double(data[$1]*data[$1])}/Double(buffer.frameLength))
    }
    var hold=TimelineEditing.freezing(state,at:1).0
    let holdIndex=hold.clips.firstIndex(where:{$0.frozenFrame != nil})!
    let holdEffect=hold.clips[holdIndex].videoEffects!.firstIndex(where:{$0.kind == .freezeFrame})!
    try require(hold.clips[holdIndex].videoEffects![holdEffect].choice("audio")=="Cut","New Freeze Frames default to silence during the hold")
    for name in ["background-freeze-default","main-freeze-default"] {
        let file=try await renderAudio(hold,name:name)
        let before=try level(file,at:0.5),during=try level(file,at:2.5),after=try level(file,at:4.3)
        try require(before>0.006 && during<0.00001 && after>0.006,"Default Freeze silences the inserted hold and resumes sound with the following video")
    }
    hold.clips[holdIndex].videoEffects![holdEffect].set("audio",.choice("Continue"))
    let reopened=try JSONDecoder().decode(EditState.self,from:JSONEncoder().encode(hold))
    try require(reopened.clips[holdIndex].videoEffects![holdEffect].choice("audio")=="Continue","Previously saved Continue choices remain unchanged when reopened")
    let continued=try await renderAudio(hold,name:"background-freeze-continue")
    let continuedLevel=try level(continued,at:2.5)
    try require(continuedLevel>baseline*0.8,"Freeze Continue keeps background sound for the whole hold, not one frame")
    hold.clips[holdIndex].videoEffects![holdEffect].set("audio",.choice("Fade out over hold"))
    let faded=try await renderAudio(hold,name:"background-freeze-fade")
    let early=try level(faded,at:1.5),late=try level(faded,at:3.5)
    try require(early>baseline*0.7 && late<early*0.3 && late>baseline*0.05,"Freeze Fade smoothly reduces background sound over the whole hold")
    hold.clips[holdIndex].videoEffects![holdEffect].set("audio",.choice("Cut"))
    let cut=try await renderAudio(hold,name:"background-freeze-cut")
    let cutLevel=try level(cut,at:2.5)
    try require(cutLevel<0.00001,"Freeze Cut silences background sound too")
    var ramp=state,under=VideoEffectSettings(.undercranking,start:0,end:4)
    let speed=under.parameters.firstIndex(where:{$0.id=="speed"})!
    under.parameters[speed].setKeyframe(at:0,value:.number(1));under.parameters[speed].setKeyframe(at:4,value:.number(1.5))
    ramp.clips[0].videoEffects!.append(under)
    let sped=try await renderAudio(ramp,name:"background-animated-rate")
    var cursor=0.0,levels:[Double]=[]
    for piece in ramp.clips[0].playbackPieces {
        cursor+=piece.duration
        if cursor>0.2 && cursor<ramp.duration-0.2 { levels.append(try level(sped,at:cursor-0.004,frames:384)) }
    }
    let minimum=levels.min() ?? 0
    print("BACKGROUND: minimum ramp boundary RMS \(minimum/baseline) of baseline")
    try require(!levels.isEmpty && minimum>baseline*0.6,"Every animated-speed boundary retains background audio, without spectral dropouts")
    for offset in stride(from:0.15,to:ramp.duration-0.15,by:0.005) {
        let window=try level(sped,at:offset,frames:240)
        try require(window>baseline*0.1,"No 5 ms window loses more than 20 dB during the speed ramp at \(offset)s")
    }
    var mainRamp=ramp;mainRamp.clips[0].videoEffects=[under]
    let main=try await renderAudio(mainRamp,name:"main-ramp"),exported=try await renderAudio(ramp,name:"background-ramp-export")
    for (name,file) in [("Main source",main),("Background export",exported)] {
        let reference=try level(file,at:1)
        for offset in stride(from:0.15,to:ramp.duration-0.15,by:0.005) {
            let window=try level(file,at:offset,frames:240)
            try require(window>reference*0.6,"\(name) retains sound through every ramp sample window at \(offset)s")
        }
        file.framePosition=Int64(file.processingFormat.sampleRate)
        let n=AVAudioFrameCount(file.processingFormat.sampleRate*0.25),buffer=AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:n)!
        try file.read(into:buffer);let data=buffer.floatChannelData![0]
        let crossings=(1..<Int(buffer.frameLength)).filter {data[$0-1]<0 && data[$0]>=0}.count
        try require(abs(Double(crossings)/0.25-1000)<20,"\(name) preserves the 1 kHz pitch through an animated speed change")
        try require(abs(Double(file.length)/file.processingFormat.sampleRate-ramp.duration)<0.03,"\(name) preserves the integrated video duration")
    }
    // Pulsed speech-like envelopes expose drift that a steady sine cannot.
    let markerURL=folder.appendingPathComponent("rate-markers.caf"),format=AVAudioFormat(standardFormatWithSampleRate:48000,channels:1)!
    do {
        let output=try AVAudioFile(forWriting:markerURL,settings:format.settings),buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:192000)!
        buffer.frameLength=192000
        for n in 0..<192000 {
            let t=Double(n)/48000,nearest=[0.5,2.0,3.5].map {abs(t-$0)}.min()!,amplitude=0.01+0.2*exp(-pow(nearest/0.035,2))
            buffer.floatChannelData![0][n]=Float(amplitude*sin(2*Double.pi*1000*t))
        }
        try output.write(from:buffer)
    }
    let slices=ramp.clips[0].playbackPieces.map {EffectAudioRateSlice(start:$0.start,end:$0.end,duration:$0.duration)}
    let markerOutput=try await EffectAudioRateRenderer.shared.render(url:markerURL,slices:slices,folder:folder)
    let markers=try AVAudioFile(forReading:markerOutput,commonFormat:.pcmFormatFloat32,interleaved:false)
    for sourceTime in [0.5,2.0,3.5] {
        let expected=ramp.clips[0].timelineTime(forSource:sourceTime)
        var best=(time:0.0,level:0.0)
        for t in stride(from:expected-0.1,through:expected+0.1,by:0.002) {
            let rms=try level(markers,at:t,frames:240)
            if rms>best.level {best=(t+0.0025,rms)}
        }
        try require(abs(best.time-expected)<1.0/30,"Continuous speed ramp keeps an audio marker within one video frame (error \(best.time-expected)s)")
    }
    if !CommandLine.arguments.contains("--effects-audio-stress") || ProcessInfo.processInfo.environment["YOUREC_AUDIO_PRODUCTION"] != nil {
        func exportAsset(_ asset:AVAsset,name:String,preset:String=AVAssetExportPresetPassthrough,type:AVFileType = .mov) async throws -> URL {
            let destination=folder.appendingPathComponent(name)
            guard let session=AVAssetExportSession(asset:asset,presetName:preset) else {throw ProjectError.invalidMedia}
            session.outputURL=destination;session.outputFileType=type;await session.export()
            guard session.status == .completed else {throw session.error ?? ProjectError.invalidMedia};return destination
        }
        let aac=try await exportAsset(AVURLAsset(url:markerURL),name:"markers.m4a",preset:AVAssetExportPresetAppleM4A,type:.m4a)
        let aacAsset=AVURLAsset(url:aac),aacTrack=try await aacAsset.loadTracks(withMediaType:.audio).first!
        for (name,leading,trim) in [("priming",0.0,0.0),("delayed",0.5,0.0),("trimmed",0.0,0.2)] {
            let composition=AVMutableComposition(),track=composition.addMutableTrack(withMediaType:.audio,preferredTrackID:kCMPersistentTrackID_Invalid)!
            try track.insertTimeRange(CMTimeRange(start:TransitionRenderer.time(trim),duration:TransitionRenderer.time(4-trim)),of:aacTrack,at:TransitionRenderer.time(leading))
            let mov=try await exportAsset(composition,name:name+".mov")
            let rendered=try await EffectAudioRateRenderer.shared.render(url:mov,slices:slices,folder:folder)
            let sound=try AVAudioFile(forReading:rendered,commonFormat:.pcmFormatFloat32,interleaved:false)
            if leading>0 {let quiet=try level(sound,at:0.1);try require(quiet<0.00001,"A movie's leading empty edit remains silent after retiming")}
            for marker in [0.5,2.0,3.5] where marker+leading-trim<4 {
                let expected=ramp.clips[0].timelineTime(forSource:marker+leading-trim)
                var best=(time:0.0,level:0.0)
                for t in stride(from:expected-0.1,through:expected+0.1,by:0.002) {
                    let rms=try level(sound,at:t,frames:240);if rms>best.level {best=(t+0.0025,rms)}
                }
                print("MOV alignment",name,marker,best.time-expected)
                try require(abs(best.time-expected)<1.0/60,"MOV edit lists and AAC priming retain audio synchronization through the speed ramp")
            }
        }
        let shortURL=folder.appendingPathComponent("short-rate.caf")
        do {
            let short=try AVAudioFile(forWriting:shortURL,settings:format.settings),input=try AVAudioFile(forReading:markerURL)
            let buffer=AVAudioPCMBuffer(pcmFormat:input.processingFormat,frameCapacity:38400)!;try input.read(into:buffer);try short.write(from:buffer)
        }
        let shortOutput=try await EffectAudioRateRenderer.shared.render(url:shortURL,slices:slices,folder:folder)
        let shortFile=try AVAudioFile(forReading:shortOutput,commonFormat:.pcmFormatFloat32,interleaved:false)
        let before=try level(shortFile,at:0.3),after=try level(shortFile,at:2.0)
        try require(before>0.001 && after<0.00001,"A short source track retains sound before its end and silence afterwards")
        var movieProject=project;movieProject.sources[0].filename="source.mp4";movieProject.commit(mainRamp)
        let inspect=try await MediaRenderer.timeline(project:movieProject,folder:folder)
        print("RAMP COVERAGE",inspect.composition.duration.seconds,inspect.videoComposition.instructions.last!.timeRange.end.seconds,movieProject.edit.duration)
        try await assertTransitionCoverage(inspect,duration:movieProject.edit.duration)
        let destination=folder.appendingPathComponent("ramped-movie.mov")
        _ = try await MediaRenderer.render(project:movieProject,folder:folder,destination:destination) {_ in}
        let movieSound=try AVAudioFile(forReading:destination,commonFormat:.pcmFormatFloat32,interleaved:false),reference=try level(movieSound,at:1)
        for offset in stride(from:0.15,to:ramp.duration-0.15,by:0.005) {
            let sample=try level(movieSound,at:offset,frames:240)
            try require(sample>reference*0.6,"The production video export retains ramped source sound at \(offset)s")
        }
        // Deliberately off the CMTime tick grid and discontinuous in source
        // time, so these cannot collapse back into one continuous audio run.
        for background in [false,true] {
            var ordinary=project,edit=state
            if !background {ordinary.sources[0].filename="source.mp4"}
            edit.clips=[(0.0,1.234507),(1.4,2.883787),(3.0,4.0)].map { a,b in
                var clip=state.clips[0];clip.id=UUID();clip.start=a;clip.end=b
                if !background {clip.videoEffects=nil};return clip
            }
            ordinary.commit(edit)
            let composed=try await MediaRenderer.timeline(project:ordinary,folder:folder)
            for track in composed.composition.tracks(withMediaType:.audio) {
                try require(track.segments.filter {!$0.isEmpty}.allSatisfy {$0.timeMapping.source.duration==$0.timeMapping.target.duration},"Ordinary cuts never create spectral speed edits, including background sound")
            }
            let url=folder.appendingPathComponent("ordinary-\(background).caf")
            _ = try await MediaRenderer.processedAudio(asset:composed.composition,duration:edit.duration,effects:[],outputURL:url,mix:composed.audioMix) {_ in}
            let file=try AVAudioFile(forReading:url,commonFormat:.pcmFormatFloat32,interleaved:false),reference=try level(file,at:0.5)
            for boundary in [1.234507,2.718294] {
                for offset in stride(from:0.01,to:0.1,by:0.005) {
                    let rms=try level(file,at:boundary+offset,frames:240)
                    try require(rms>reference*0.6,"Speech immediately after an ordinary cut is retained at \(boundary+offset)s")
                }
            }
        }
        let nextName="next-scene.mp4"
        try FileManager.default.copyItem(at:root.appendingPathComponent(nextName),to:folder.appendingPathComponent(nextName))
        var linked=movieProject;linked.append(SourceMedia(filename:nextName,duration:4))
        linked.commit(linked.edit.settingTransition(ClipTransition(style:.dissolve,duration:0.5),at:1))
        try require(linked.edit.layout.joins[1].transition != nil && linked.edit.duration<mainRamp.duration+4,"The audio regression exercises a real overlapping join")
        let joined=try await MediaRenderer.timeline(project:linked,folder:folder)
        try await assertTransitionCoverage(joined,duration:linked.edit.duration)
        for track in joined.composition.tracks(withMediaType:.audio) {
            try require(track.segments.filter {!$0.isEmpty}.allSatisfy {$0.timeMapping.source.duration==$0.timeMapping.target.duration},"Retimed audio remains unscaled when inserted through a transition")
        }
        let joinedURL=folder.appendingPathComponent("ramp-transition.caf")
        _ = try await MediaRenderer.processedAudio(asset:joined.composition,duration:linked.edit.duration,effects:[],outputURL:joinedURL,mix:joined.audioMix) {_ in}
        let joinedAudio=try AVAudioFile(forReading:joinedURL,commonFormat:.pcmFormatFloat32,interleaved:false)
        for t in stride(from:0.15,to:linked.edit.duration-0.15,by:0.005) {
            let rms=try level(joinedAudio,at:t,frames:240)
            try require(rms>reference*0.3,"A speed ramp joined by a transition has no audio dropout at \(t)s")
        }
        let pinned=try await EffectAudioRateRenderer.shared.render(url:markerURL,slices:slices,folder:folder,retainedBy:joined.composition)
        let duplicate=try await EffectAudioRateRenderer.shared.render(url:markerURL,slices:slices,folder:folder)
        try require(pinned==duplicate,"An unchanged ramp reuses its aligned audio cache")
        let alias=folder.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:folder)
        defer {try? FileManager.default.removeItem(at:alias)}
        let aliasOwner=AVMutableComposition()
        let aliasPinned=try await EffectAudioRateRenderer.shared.render(url:markerURL,slices:slices,folder:alias,outputDuration:TransitionRenderer.time(ramp.duration)+CMTime(value:1,timescale:60000),retainedBy:aliasOwner)
        try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:0)],ofItemAtPath:aliasPinned.path)
        let cache=pinned.deletingLastPathComponent(),old=cache.appendingPathComponent(String(repeating:"0",count:64)+".caf")
        FileManager.default.createFile(atPath:old.path,contents:Data());let sparse=try FileHandle(forWritingTo:old);try sparse.truncate(atOffset:500_000_001);try sparse.close()
        try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:1)],ofItemAtPath:old.path)
        await EffectAudioRateRenderer.shared.trimCache(in:folder)
        try require(!FileManager.default.fileExists(atPath:old.path) && FileManager.default.fileExists(atPath:pinned.path),"Cache eviction removes old files and retains audio owned by an active composition")
        withExtendedLifetime(aliasOwner) {}
        try require(FileManager.default.fileExists(atPath:aliasPinned.path),"Cache leases survive a project directory reached through a symlink")

    }
    print("PASS: moving video loop, -18 dB background sound, seamless audio loop and transition composition")
}

private func faceTrackingTests() throws {
    let url=URL(fileURLWithPath:"Tests/Fixtures/astronaut.png")
    guard let image=CIImage(contentsOf:url) else { throw ProjectError.missingMedia }
    let bounds=image.extent,tracker=EffectSubjectTracker(live:true)
    guard let initial=try tracker.update(image,time:0),initial.face else { throw ProjectError.invalidMedia }
    let center=CGPoint(x:initial.center.x*bounds.width,y:(1-initial.center.y)*bounds.height)
    var follower=DollyZoomFollower(referenceHeight:initial.box.height,zoom:1,range:1...3,time:0)
    var commands=[Double](repeating:1,count:181),errors:[Double]=[]
    for frame in 1...180 {
        let time=Double(frame)/30,applied=commands[max(0,frame-2)],distance=1+min(3,time)*0.2,scale=applied/distance
        let matrix=CGAffineTransform(translationX:-center.x,y:-center.y).concatenating(CGAffineTransform(scaleX:scale,y:scale)).concatenating(CGAffineTransform(translationX:center.x,y:center.y))
        let picture=image.transformed(by:matrix).composited(over:CIImage(color:.black).cropped(to:bounds)).cropped(to:bounds)
        if frame.isMultiple(of:2) {
            let subject=try tracker.update(picture,time:time)
            try require(subject?.face == true,"Face tracking retains the moving portrait")
            if let subject {
                errors.append(abs(subject.box.height/(initial.box.height*scale)-1))
                follower.observe(height:subject.box.height,appliedZoom:applied,time:time)
            }
        }
        commands[frame]=follower.value(at:time)
    }
    let median=errors.sorted()[errors.count/2]
    try require(median<0.05 && abs(commands.last!-1.6)<0.08,"Vision face scale drives the Dolly controller without cumulative drift")
    print("PASS: real Vision face-scale tracking, delayed-zoom feedback and stable framing (median error \(median))")
}

private func cleanPlateCaptureTests(folder:URL) throws {
    let renderer=try MetalEffectRenderer(),capture=VideoEffectCleanPlate(renderer:renderer)
    let bounds=CGRect(x:0,y:0,width:64,height:48)
    for frame in 0...30 {
        let c=Double(frame)/30
        let image=CIImage(color:CIColor(red:c,green:2,blue:0.1,colorSpace:renderer.space)!).cropped(to:bounds)
        let complete=try capture.append(image,time:Double(frame)/30)
        try require(complete == (frame==30),"Clean plate averages a full second without retaining all input frames")
    }
    let url=folder.appendingPathComponent("test-clean.tiff");try capture.save(to:url)
    guard let saved=CIImage(contentsOf:url) else { throw ProjectError.invalidMedia }
    var pixel=[Float](repeating:0,count:4)
    renderer.context.render(saved,toBitmap:&pixel,rowBytes:16,bounds:CGRect(x:30,y:20,width:1,height:1),format:.RGBAf,colorSpace:renderer.space)
    try require(abs(pixel[0]-0.5)<0.005 && abs(pixel[1]-2)<0.005,"Saved half-float clean plate retains the linear mean and HDR highlights")
    let screen=CIImage(color:CIColor(red:0.1,green:0.8,blue:0.1,colorSpace:renderer.space)!).cropped(to:bounds)
    let lower=CIImage(color:CIColor(red:0.02,green:0.3,blue:0.02,colorSpace:renderer.space)!).cropped(to:CGRect(x:0,y:0,width:64,height:24))
    let plate=lower.composited(over:screen)
    try renderer.context.writeTIFFRepresentation(of:plate,to:folder.appendingPathComponent("uneven.tiff"),format:.RGBAh,colorSpace:renderer.space,options:[:])
    var effect=VideoEffectSettings(.chromaKey);effect.set("personHint",.toggle(false));effect.set("cleanPlate",.media("uneven.tiff"));effect.set("view",.choice("Matte"))
    let transform=CGAffineTransform(a:1,b:0,c:0,d:-1,tx:0,ty:48)
    let framed=plate.transformed(by:transform),inputs=VideoEffectInputs(renderer:renderer)
    let frames=try inputs.frameContexts(image:framed,effects:[effect],time:0,folder:folder,maskTransform:transform,sourceSize:bounds.size,temporalHistories:[effect.id:[]])
    let keyed=try renderer.render(framed,effects:[effect],sourceTime:0,contexts:frames)
    for y in [8,40] {
        renderer.context.render(keyed,toBitmap:&pixel,rowBytes:16,bounds:CGRect(x:30,y:y,width:1,height:1),format:.RGBAf,colorSpace:renderer.space)
        try require(pixel[0]<0.02,"Clean plate follows image geometry when editing mirrored footage")
    }
    let portrait=CIImage(color:.green).cropped(to:CGRect(x:0,y:0,width:48,height:64))
    let incompatible=try inputs.frameContexts(image:portrait,effects:[effect],time:0,folder:folder)
    try require(incompatible[effect.id]?.cleanPlate==nil,"A clean plate with a different aspect falls back to screen color, never stretches")
    for change in 0..<3 {
        let average=VideoEffectCleanPlate(renderer:renderer)
        _ = try average.append(screen,time:0)
        do {
            _ = try average.append(change==0 ? portrait : screen,time:change==1 ? 0.5 : 0.033,hdr:change==2)
            throw ProjectError.invalidDocument
        } catch is VideoEffectCleanPlate.Failure { }
    }
    let tagged=NSMutableData()
    let bitmap=renderer.context.createCGImage(screen,from:bounds)!
    let destination=CGImageDestinationCreateWithData(tagged,"public.tiff" as CFString,1,nil)!
    CGImageDestinationAddImage(destination,bitmap,[kCGImagePropertyOrientation:6] as CFDictionary);CGImageDestinationFinalize(destination)
    let normalized=try VideoEffectCleanPlate.importedPNG(tagged as Data,matching:CGSize(width:48,height:64))
    let upright=CIImage(data:normalized)!
    try require(upright.extent.width==48 && upright.extent.height==64,"Photos import bakes EXIF rotation into the saved pixels")
    do {
        _ = try VideoEffectCleanPlate.importedPNG(tagged as Data,matching:bounds.size)
        throw ProjectError.invalidDocument
    } catch let error as NSError { try require(error.domain=="CleanPlate","A mismatched imported plate is rejected with an explicit framing message") }
    print("PASS: one-second streaming clean plate, HDR TIFF retention and geometry-aligned key reference")
}

// Set YOUREC_BACKGROUND_EXPORT_FIXTURE to exercise a camera-length input with the
// same checkpointed export path as the phone. The normal run uses a four-second clip.
func autoBackgroundExportTests(_ root: URL) async throws {
    let environment = ProcessInfo.processInfo.environment
    let input = environment["YOUREC_BACKGROUND_EXPORT_FIXTURE"].map { URL(fileURLWithPath: $0) } ?? root.appendingPathComponent("source.mp4")
    let asset = AVURLAsset(url: input)
    let length = try await asset.load(.duration).seconds
    let inputTrack = try await asset.loadTracks(withMediaType: .video).first!
    let size = try await inputTrack.load(.naturalSize)
    let folder = root.appendingPathComponent("background-export-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("recording.mp4")
    try FileManager.default.copyItem(at: input, to: url)
    var project = Project(title: "Auto Background export")
    project.append(SourceMedia(filename: url.lastPathComponent, duration: length))
    var edit = project.edit
    edit.clips[0].videoEffects = [VideoEffectSettings(.autoBackground, start: 0, end: length)]
    for crop in [false, true] {
        if crop {
            edit.clips[0].crop = CropSettings(x: 0.56)
            edit.outputSize = CGSize(width: size.height, height: size.height)
        }
        project.commit(edit)
        let name = crop ? "Fill" : "Plain"
        let started = Date()
        let preview = try await MediaRenderer.timeline(project: project, folder: folder, effectPreparation: .cached)
        try require(!preview.effectAnalysisPending, "Auto Background is immediately editable with " + name)
        let checkpoint = ExportCheckpoint(folder: folder)
        try checkpoint.prepare(project)
        let trace = ExportProgressTrace()
        let output = folder.appendingPathComponent(name + ".mp4")
        _ = try await MediaRenderer.render(project: project, folder: folder, destination: output, checkpoint: checkpoint) { event in
            trace.record(event)
            if event.step != .picture && event.fraction == event.step.range.lowerBound {
                print("Auto Background", name, event.title, "after", Int(Date().timeIntervalSince(started)), "s")
            }
        }
        let result = AVURLAsset(url: output)
        for kind in [AVMediaType.video, .audio] {
            let track = try await result.loadTracks(withMediaType: kind).first!
            let range = try await track.load(.timeRange)
            try require(abs(range.end.seconds - length) < 0.045, "Complete " + kind.rawValue + " with " + name)
            if kind == .video {
                let dimensions = try await track.load(.naturalSize)
                try require(dimensions == (crop ? edit.outputSize! : size), "Correct export dimensions for " + name)
            }
        }
        try require(trace.values.contains { $0.step == .picture && $0.fraction > $0.step.range.lowerBound && $0.fraction < $0.step.range.upperBound }, "Video encoding reports progress")
        let caches = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        try require(!caches.contains { $0.pathExtension == "bin" }, "Export never materializes a movie-length mask sidecar")
        print("PASS: Auto Background", name, length, "seconds of picture and sound,", Int(Date().timeIntervalSince(started)), "s to export", output.path)
    }
}

private func rotatedPersonMaskTrackTest(folder:URL) async throws {
    let photo=CIImage(contentsOf:URL(fileURLWithPath:"Tests/Fixtures/astronaut.png"))!
    let upright=photo.cropped(to:CGRect(x:96,y:0,width:320,height:512)).transformed(by:CGAffineTransform(translationX:-96,y:0))
    let context=CIContext(),space=CGColorSpace(name:CGColorSpace.sRGB)!
    var samples:[[UInt8]]=[]
    for rotated in [false,true] {
        let size=rotated ? CGSize(width:512,height:320) : upright.extent.size
        let preferred=rotated ? CGAffineTransform(a:0,b:1,c:-1,d:0,tx:320,ty:0) : .identity
        let matrix=CGAffineTransform(a:1,b:0,c:0,d:-1,tx:0,ty:size.height).concatenating(preferred)
            .concatenating(CGAffineTransform(a:1,b:0,c:0,d:-1,tx:0,ty:512))
        let picture=upright.transformed(by:matrix.inverted()),url=folder.appendingPathComponent(rotated ? "person-rotated.mov" : "person-upright.mov")
        let writer=try AVAssetWriter(outputURL:url,fileType:.mov)
        let input=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:Int(size.width),AVVideoHeightKey:Int(size.height)])
        input.transform=preferred
        let adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:Int(size.width),kCVPixelBufferHeightKey as String:Int(size.height)])
        writer.add(input);guard writer.startWriting() else {throw writer.error ?? ProjectError.invalidMedia};writer.startSession(atSourceTime:.zero)
        for frame in 0..<6 {
            let deadline=Date().addingTimeInterval(10)
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing,Date()<deadline else {throw writer.error ?? ProjectError.invalidMedia}
                try await Task.sleep(for:.milliseconds(1))
            }
            var pixel:CVPixelBuffer?
            guard let pool=adaptor.pixelBufferPool,CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault,pool,&pixel)==kCVReturnSuccess,let pixel else {throw ProjectError.invalidMedia}
            context.render(picture,to:pixel,bounds:CGRect(origin:.zero,size:size),colorSpace:space)
            guard adaptor.append(pixel,withPresentationTime:CMTime(value:Int64(frame),timescale:30)) else {throw writer.error ?? ProjectError.invalidMedia}
        }
        writer.endSession(atSourceTime:CMTime(value:6,timescale:30));input.markAsFinished();await writer.finishWriting()
        guard writer.status == .completed else {throw writer.error ?? ProjectError.invalidMedia}
        let source = SourceMedia(filename: url.lastPathComponent, duration: 0.2)
        let descriptor = SourcePersonMasks(url: url, hdr: false,
            orientation: SourcePersonMasks.orientation(size: size, preferred: preferred),
            cacheDirectory: try EffectMaskAnalysis.directory(source: source, folder: folder, captured: nil),
            captured: nil, mode: .export(try await VideoEffectFrameAnalysis.shared.index(url: url, folder: folder)))
        let streaming = try SourcePersonMaskReader(descriptor)
        func alpha(_ image: CIImage) -> [UInt8] {
            let bounds = image.extent.integral, width = Int(bounds.width)
            var bytes = [UInt8](repeating: 0, count: width * Int(bounds.height))
            context.render(image, toBitmap: &bytes, rowBytes: width, bounds: bounds, format: .R8, colorSpace: nil)
            return bytes
        }
        let frame = try streaming.frame(at: 0.1, currentImage: nil, cancelled: { false })
        let expectedRaw = alpha(frame.raw), expectedSmooth = alpha(frame.background)
        let fresh = try SourcePersonMaskReader(descriptor)
        _ = try fresh.frame(at: 4.0 / 30, currentImage: nil, cancelled: { false })
        let seek = try fresh.frame(at: 0.1, currentImage: nil, cancelled: { false })
        try require(alpha(seek.background) == expectedSmooth, "Random-access masks match sequential masks")
        let files=try await EffectMaskAnalysis.shared.track(source: source,folder:folder)
        let reader=try EffectAnalysisReader(metadata:files.metadata,data:files.data)
        let referenceRaw = try alpha(reader.mask(at: 0.100001)!)
        let referenceSmooth = try alpha(reader.mask(at: 0.100001, autoBackground: true)!)
        func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
            guard a.count == b.count else { return .infinity }
            return zip(a, b).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(a.count)
        }
        let rawDelta = difference(referenceRaw, expectedRaw), smoothDelta = difference(referenceSmooth, expectedSmooth)
        try require(rawDelta < 0.5 && smoothDelta < 0.5, "Source mask parity with the accurate reference (raw \(rawDelta), smooth \(smoothDelta))")
        let cached = try SourcePersonMaskReader(descriptor).frame(at: 0.1, currentImage: nil, cancelled: { false })
        try require(alpha(cached.background) == referenceSmooth, "Previously generated accurate masks can be reused")
        let raw=try reader.mask(at:0.1)!
        let placed=raw.transformed(by:CGAffineTransform(scaleX:size.width/raw.extent.width,y:size.height/raw.extent.height)).transformed(by:matrix)
        let small=placed.transformed(by:CGAffineTransform(scaleX:0.25,y:0.25))
        var bytes=[UInt8](repeating:0,count:80*128)
        CIContext(options:[.workingColorSpace:NSNull()]).render(small,toBitmap:&bytes,rowBytes:80,bounds:CGRect(x:0,y:0,width:80,height:128),format:.R8,colorSpace:nil)
        samples.append(bytes)
    }
    let delta=zip(samples[0],samples[1]).reduce(0.0){$0+abs(Double($1.0)-Double($1.1))}/Double(samples[0].count)
    let foreground=samples[0].filter {$0>200}.count
    try require(foreground>500 && delta<4,"Non-square rotated video tracks infer the upright person and store correctly aligned alpha: \(delta)")
    print("PASS: real rotated-track person analysis, including preferred transform and non-square mask placement (mean error \(delta)/255)")
}

func temporalMaskAnalysisTests(folder:URL) async throws {
    let portrait=CIImage(contentsOf:URL(fileURLWithPath:"Tests/Fixtures/astronaut.png"))!
    let provider=VideoEffectPersonProvider(live:false)
    let raw=try provider.mask(portrait)
    try require((513...1024).contains(max(CVPixelBufferGetWidth(raw),CVPixelBufferGetHeight(raw))),"Accurate Vision masks retain detail beyond the former 512-pixel limit within a bounded 1024-pixel mask")
    let rotation=CGAffineTransform(a:0,b:1,c:-1,d:0,tx:portrait.extent.height,ty:0)
    let rotated=portrait.transformed(by:rotation)
    let rotatedMask=try provider.mask(rotated,stateless:true,orientation:rotation.inverted())
    let maskContext=CIContext(options:[.workingColorSpace:NSNull()])
    func silhouette(_ pixel:CVPixelBuffer,size:CGSize)->CIImage {
        CIImage(cvPixelBuffer:pixel,options:[.colorSpace:NSNull()]).transformed(by:CGAffineTransform(scaleX:size.width/Double(CVPixelBufferGetWidth(pixel)),y:size.height/Double(CVPixelBufferGetHeight(pixel))))
    }
    func maskBytes(_ image:CIImage)->[UInt8] {
        var bytes=[UInt8](repeating:0,count:128*128)
        let reduced=image.transformed(by:CGAffineTransform(scaleX:128/image.extent.width,y:128/image.extent.height))
        maskContext.render(reduced,toBitmap:&bytes,rowBytes:128,bounds:CGRect(x:0,y:0,width:128,height:128),format:.R8,colorSpace:nil)
        return bytes
    }
    let originalMask=maskBytes(silhouette(raw,size:portrait.extent.size))
    let reorientedMask=maskBytes(silhouette(rotatedMask,size:rotated.extent.size).transformed(by:rotation.inverted()))
    let rotationError=zip(originalMask,reorientedMask).reduce(0.0) {$0+abs(Double($1.0)-Double($1.1))}/Double(originalMask.count)
    try require(rotationError<2,"Portrait metadata is applied before semantic inference and the stored alpha maps back to the raw frame: \(rotationError)")
    let detailed=try EffectAnalysisWriter(folder:folder,maskFilter:"auto-background-ema-v1",motionAwareAutoBackground:true)
    try detailed.append(time:0,palettes:[:],mask:raw);try detailed.checkpoint()
    let restored=try EffectAnalysisReader(metadata:folder.appendingPathComponent(detailed.metadataName),data:folder.appendingPathComponent(detailed.dataName)).rawPixel(at:0)!
    try require(CVPixelBufferGetWidth(restored)==CVPixelBufferGetWidth(raw) && CVPixelBufferGetHeight(restored)==CVPixelBufferGetHeight(raw) && maskBytes(silhouette(restored,size:portrait.extent.size))==originalMask,"Accurate masks survive sidecar storage without losing resolution or changing alpha")
    let renderer=try MetalEffectRenderer(),smoother=try VideoEffectMaskSmoother()
    let filtered=try smoother.push(raw,image:portrait,time:0,geometry:"portrait")
    CVPixelBufferLockBaseAddress(filtered,.readOnly)
    let base=CVPixelBufferGetBaseAddress(filtered)!.assumingMemoryBound(to:UInt8.self),stride=CVPixelBufferGetBytesPerRow(filtered)
    var foreground=0,background=0
    for y in 0..<CVPixelBufferGetHeight(filtered) {for x in 0..<CVPixelBufferGetWidth(filtered) {
        let a=base[y*stride+x];if a>220 {foreground+=1};if a<30 {background+=1}
    }}
    CVPixelBufferUnlockBaseAddress(filtered,.readOnly)
    try require(foreground>1000 && background>1000,"GPU resize retains an actual portrait silhouette, not an empty or solid mask")
    let source=SourceMedia(filename:"source.mp4",duration:4)
    let files=try await EffectMaskAnalysis.shared.track(source:source,folder:folder)
    let reader=try EffectAnalysisReader(metadata:files.metadata,data:files.data)
    try require(reader.analysis.maskFilter=="auto-background-ema-v1" && reader.hasMotionAwareAutoBackground && reader.analysis.masks.count>=100 && (reader.analysis.autoBackgroundMasks?.count ?? 0)>=100,"Source-anchored analysis stores motion-aware masks while retaining a capture format readable by the rollback build")
    func bytes(_ image:CIImage)->[UInt8] {
        var result=[UInt8](repeating:0,count:64*36*4)
        let small=image.transformed(by:CGAffineTransform(scaleX:64/image.extent.width,y:36/image.extent.height))
        renderer.context.render(small,toBitmap:&result,rowBytes:64*4,bounds:CGRect(x:0,y:0,width:64,height:36),format:.RGBA8,colorSpace:renderer.space)
        return result
    }
    let expected=try bytes(reader.mask(at:1.4)!)
    _ = try reader.mask(at:3.9);_ = try reader.mask(at:0.03)
    let repeated=try bytes(reader.mask(at:1.4)!)
    try require(repeated==expected,"Random seeks replay exactly the saved temporal mask")
    let again=try await EffectMaskAnalysis.shared.track(source:source,folder:folder)
    try require(again.metadata==files.metadata && again.data==files.data,"Splits and trims share the source track instead of resetting temporal state")
    func uniform(_ value:UInt8)->CVPixelBuffer {
        var p:CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault,16,16,kCVPixelFormatType_OneComponent8,[kCVPixelBufferMetalCompatibilityKey:true,kCVPixelBufferIOSurfacePropertiesKey:[:]] as CFDictionary,&p)
        CVPixelBufferLockBaseAddress(p!,[])
        let base=CVPixelBufferGetBaseAddress(p!)!.assumingMemoryBound(to:UInt8.self),stride=CVPixelBufferGetBytesPerRow(p!)
        for y in 0..<16 {base.advanced(by:y*stride).initialize(repeating:value,count:16)}
        CVPixelBufferUnlockBaseAddress(p!,[]);return p!
    }
    let dual=try EffectAnalysisWriter(folder:folder,maskFilter:"auto-background-ema-v1")
    try dual.append(time:0,palettes:[:],mask:uniform(0),autoBackgroundMask:uniform(255));try dual.checkpoint()
    let dualFiles=EffectMaskFiles(metadata:folder.appendingPathComponent(dual.metadataName),data:folder.appendingPathComponent(dual.dataName))
    var auto=VideoEffectSettings(.autoBackground);auto.analysisFile=dual.metadataName;auto.analysisDataFile=dual.dataName
    var legacy=auto;legacy.id=UUID();legacy.algorithm=nil
    var isolation=VideoEffectSettings(.colorIsolation);isolation.set("mode",.choice("The subject"))
    let inputs=VideoEffectInputs(renderer:renderer)
    let stale=try inputs.frameContexts(image:portrait,effects:[auto],time:0,folder:folder)
    let staleImage=CIImage(mtlTexture:stale[auto.id]!.personMask!,options:[.colorSpace:NSNull()])!
    try require(bytes(staleImage).enumerated().filter {$0.offset.isMultiple(of:4)}.allSatisfy {$0.element==0},"Old recorded Auto Background uses its raw silhouette while motion-aware analysis is being rebuilt")
    let frames=try inputs.frameContexts(image:portrait,effects:[auto,legacy,isolation],time:0,folder:folder,masks:dualFiles)
    func meanMask(_ id:UUID)->Double {
        let texture=frames[id]!.personMask!
        let image=CIImage(mtlTexture:texture,options:[.colorSpace:NSNull()])!
        return Double(bytes(image).enumerated().filter {$0.offset.isMultiple(of:4)}.reduce(0) {$0+Int($1.element)})/Double(64*36*255)
    }
    try require(meanMask(auto.id)>0.99 && meanMask(legacy.id)<0.01 && meanMask(isolation.id)<0.01,"Only versioned Auto Background consumes the smoothed stream; legacy and other tools keep raw masks")
    legacy.analysisFile=nil;legacy.analysisDataFile=nil
    let mixed=try inputs.frameContexts(image:portrait,effects:[legacy,isolation],time:0,folder:folder,masks:dualFiles,personPixel:filtered)
    let legacyImage=CIImage(mtlTexture:mixed[legacy.id]!.personMask!,options:[.colorSpace:NSNull()])!
    let modernImage=CIImage(mtlTexture:mixed[isolation.id]!.personMask!,options:[.colorSpace:NSNull()])!
    try require(bytes(legacyImage).enumerated().filter {$0.offset.isMultiple(of:4)}.contains {$0.element>220} && bytes(modernImage).enumerated().filter {$0.offset.isMultiple(of:4)}.allSatisfy {$0.element==0},"A new effect's generated masks cannot replace a legacy effect's original mask path")
    let rawRoundtrip=try EffectAnalysisReader(metadata:dualFiles.metadata,data:dualFiles.data).rawPixel(at:0)!
    CVPixelBufferLockBaseAddress(rawRoundtrip,.readOnly)
    let firstByte=CVPixelBufferGetBaseAddress(rawRoundtrip)!.assumingMemoryBound(to:UInt8.self)[0]
    CVPixelBufferUnlockBaseAddress(rawRoundtrip,.readOnly)
    try require(firstByte==0,"Stored raw mask decoding preserves alpha values")
    let extended=AVMutableComposition(),video=extended.addMutableTrack(withMediaType:.video,preferredTrackID:kCMPersistentTrackID_Invalid)!
    let original=AVURLAsset(url:folder.appendingPathComponent("source.mp4")),track=try await original.loadTracks(withMediaType:.video).first!
    for index in 0..<3 {try video.insertTimeRange(CMTimeRange(start:.zero,duration:CMTime(seconds:4,preferredTimescale:30)),of:track,at:CMTime(seconds:Double(index)*4,preferredTimescale:30))}
    let longURL=folder.appendingPathComponent("mask-chunks.mov"),export=AVAssetExportSession(asset:extended,presetName:AVAssetExportPresetPassthrough)!
    export.outputURL=longURL;export.outputFileType = .mov
    await export.export()
    guard export.status == .completed else {throw export.error ?? ProjectError.invalidMedia}
    let capture=try EffectAnalysisWriter(folder:folder,checkpointInterval:0)
    for index in 0..<360 {try capture.append(time:Double(index)/30,palettes:[:],mask:uniform(UInt8(128+Int(60*sin(Double(index)/10)))))}
    try capture.checkpoint()
    let recorded=EffectMaskFiles(metadata:folder.appendingPathComponent(capture.metadataName),data:folder.appendingPathComponent(capture.dataName))
    let longSource=SourceMedia(filename:longURL.lastPathComponent,duration:12)
    let sourceMasks = SourcePersonMasks(url: longURL, hdr: false, orientation: .identity,
        cacheDirectory: try EffectMaskAnalysis.directory(source: longSource, folder: folder, captured: recorded),
        captured: recorded, mode: .export(try await VideoEffectFrameAnalysis.shared.index(url: longURL, folder: folder)))
    let stream = try SourcePersonMaskReader(sourceMasks)
    var warmupFrames = 0
    do {
        _ = try stream.frame(at: 10.5, currentImage: nil) { warmupFrames += 1; return warmupFrames > 5 }
        try require(false, "A cancelled mask warm-up must stop")
    } catch is CancellationError {}
    let lateAlpha = try bytes(stream.frame(at: 10.5, currentImage: nil, cancelled: { false }).background)
    _ = try stream.frame(at: 9.9, currentImage: nil, cancelled: { false })
    let replayed = try bytes(stream.frame(at: 10.5, currentImage: nil, cancelled: { false }).background)
    try require(lateAlpha == replayed, "Crossing a source chunk backwards and resuming keeps the same matte")
    let late=try await EffectMaskAnalysis.shared.track(source:longSource,folder:folder,range:10.3...10.7,captured:recorded)
    let partial=try await EffectMaskAnalysis.shared.track(source:longSource,folder:folder,captured:recorded,generate:false)
    try require(!partial.isComplete && partial.chunks.count==1 && partial.at(5)==nil && partial.at(11) != nil,"A cache-only mask lookup cannot analyse or borrow masks across an unfinished chunk")
    let lateBytes=try Data(contentsOf:late.data),lateInfo=try EffectAnalysisReader(metadata:late.metadata,data:late.data)
    try require(late.chunks.count==1 && (lateInfo.analysis.masks.first?.time ?? -1)>=10 && lateInfo.analysis.masks.count<=61,"A late selection analyses only its anchored chunk and warm-up, using the captured raw stream")
    let referenceLate = try bytes(lateInfo.mask(at: 10.5, autoBackground: true)!)
    try require(referenceLate == lateAlpha, "Captured raw-mask replay matches the reference after a checkpoint or cut")
    let all=try await EffectMaskAnalysis.shared.track(source:longSource,folder:folder,captured:recorded)
    let preserved=try Data(contentsOf:late.data),earlyBytes=try Data(contentsOf:all.data)
    try require(all.chunks.count==2 && preserved==lateBytes,"Extending mask coverage preserves existing chunks exactly")
    try FileManager.default.removeItem(at:late.metadata);try FileManager.default.removeItem(at:late.data)
    let rerun=try await EffectMaskAnalysis.shared.track(source:longSource,folder:folder,range:10...12,captured:recorded)
    let rerunBytes=try Data(contentsOf:rerun.data),stillEarly=try Data(contentsOf:all.data)
    try require(rerunBytes==lateBytes && stillEarly==earlyBytes,"Chunk generation is byte-identical regardless of seek order and cannot rewrite adjacent chunks")
    print("PASS: bounded accurate Vision masks, source-anchored temporal analysis and random-seek replay")
}

private func temporalMatteProviderTests(folder:URL) async throws {
    let renderer=try MetalEffectRenderer(),inputs=VideoEffectInputs(renderer:renderer)
    let url=folder.appendingPathComponent("source.mp4")
    let frames=try await VideoEffectFrameAnalysis.shared.index(url:url,folder:folder)
    let reader=try VideoEffectSourceReader(url:url,hdr:false,capacity:8)
    let provider=VideoEffectSourceMatteProvider(),bounds=CGRect(x:0,y:0,width:160,height:90)
    var key=VideoEffectSettings(.chromaKey,start:0,end:4);key.algorithm=2
    key.set("personHint",.toggle(false));key.set("softness",.number(0));key.set("wrap",.number(0))
    var isolation=VideoEffectSettings(.colorIsolation,start:0.017,end:4);isolation.algorithm=2
    isolation.set("range",.number(25));isolation.set("intensity",.number(0.8))
    var second=isolation;second.id=UUID();second.set("color",.color(EffectRGB(hex:"#21B35A")))
    var animated=isolation
    let intensity=animated.parameters.firstIndex(where:{$0.id=="intensity"})!
    for (time,value) in [(0.0,1.0),(0.4,0),(0.8,1),(1.1,0),(1.3,0),(1.7,1)] {animated.parameters[intensity].setKeyframe(at:time,value:.number(value))}
    let range=animated.parameters.firstIndex(where:{$0.id=="range"})!
    animated.parameters[range].setKeyframe(at:0,value:.number(10));animated.parameters[range].setKeyframe(at:2,value:.number(45))
    var fade=animated;fade.parameters[range]=isolation.parameters[range]
    func render(_ chain:[VideoEffectSettings],_ time:Double,identity:String)throws->Data {
        try autoreleasepool {
            var leases:[VideoEffectFrameLease]=[]
            let image=try provider.render(effects:chain,time:time,frames:frames,identity:identity,renderer:renderer,equivalentCurrentAllowed:true,prepare:{t,prefix,histories in
                let index=frames.last(at:t)
                let sample=try reader.sample(at:frames.times[index],firstAtOrAfter:true)
                let image=sample.image.transformed(by:CGAffineTransform(scaleX:160/sample.image.extent.width,y:90/sample.image.extent.height))
                let contexts=try inputs.frameContexts(image:image,effects:prefix,time:t,folder:folder,analysisTime:sample.time,temporalHistories:histories)
                return .init(image:image,contexts:contexts)
            },lease:{leases.append($0)})
            var bytes=[UInt8](repeating:0,count:160*90*8)
            renderer.context.render(image,toBitmap:&bytes,rowBytes:160*8,bounds:bounds,format:.RGBAh,colorSpace:renderer.space)
            return withExtendedLifetime(leases) {Data(bytes)}
        }
    }
    // Offset composition times deliberately differ from the actual movie PTS.
    // The first request is inside the first source frame and after effect.start.
    let times=(0..<60).map {frames.times[$0]+($0==0 ? 0.025 : 0.005)}
    for (chainIndex,chain) in [[isolation],[key,isolation],[key,isolation,second],[fade],[key,animated,second]].enumerated() {
        VideoEffectMatteCache.shared.purge()
        let identity="temporal-integration-\(chainIndex)",before=provider.historicalRenders
        var reference:[Data]=[]
        for time in times {reference.append(try render(chain,time,identity:identity))}
        if chainIndex<4 {try require(provider.historicalRenders==before,"Static raw mattes reuse equivalent non-PTS evaluations, including their own intensity animation")}
        var random=EffectRandom(state:UInt64(chainIndex+17))
        for _ in 0..<24 {
            let frame=Int(random.next()*Double(times.count))
            VideoEffectMatteCache.shared.purge()
            let actual=try render(chain,times[frame],identity:identity)
            try require(actual==reference[frame],"Temporal matte seek matches sequential bytes for chain \(chainIndex), frame \(frame)")
        }
    }
    VideoEffectMatteCache.shared.purge()
    var preparedCount=0,cancelled=false
    do {
        _=try provider.render(effects:[key,animated,second],time:1.5,frames:frames,identity:"cancel-history",renderer:renderer,isCancelled:{preparedCount>=3},prepare:{time,prefix,histories in
            preparedCount+=1
            let image=CIImage(color:CIColor(red:0.4,green:0.5,blue:0.1)).cropped(to:bounds)
            return .init(image:image,contexts:try inputs.frameContexts(image:image,effects:prefix,time:time,folder:folder,temporalHistories:histories))
        })
    } catch is CancellationError {cancelled=true}
    try require(cancelled && preparedCount==3,"Scrubbing cancellation stops recursive history warming between frames")
    print("PASS: recursive matte history, duplicate effects, mid-frame starts, intensity runs, random seek equality and static-prefix reuse")
    let liveHistory=VideoEffectLiveMatteHistory(),recordedChain=[key,isolation]
    var accepted:[UUID:[CapturedMatteSample]]=[:],liveFrames:[Data]=[]
    func bytes(_ image:CIImage)->Data {
        var data=[UInt8](repeating:0,count:160*90*8)
        renderer.context.render(image,toBitmap:&data,rowBytes:160*8,bounds:bounds,format:.RGBAh,colorSpace:renderer.space)
        return Data(data)
    }
    for index in 0..<90 {
        let time=frames.times[index],snapshot=liveHistory.snapshot(effects:recordedChain,time:time,geometry:index<60 ? "rear" : "front")
        let sample=try reader.sample(at:time,firstAtOrAfter:true)
        let picture=sample.image.transformed(by:CGAffineTransform(scaleX:160/sample.image.extent.width,y:90/sample.image.extent.height))
        let contexts=try inputs.frameContexts(image:picture,effects:recordedChain,time:time,folder:folder,temporalHistories:snapshot.history)
        let capture=index%3 != 1 && !(30...42).contains(index)
        var raw:[UUID:VideoEffectMatteCache.Frame]=[:]
        let output=try renderer.render(picture,effects:recordedChain,sourceTime:time,contexts:snapshot.applying(to:contexts,device:renderer.device.registryID,capture:capture),captureMatte:{raw[$0]=$1})
        liveFrames.append(bytes(output))
        if capture {
            let resets=try liveHistory.accept(raw,snapshot:snapshot)
            for (id,reset) in resets {accepted[id,default:[]].append(.init(tick:Int64((time*600).rounded()),reset:reset))}
        }
    }
    let recorded=accepted.compactMapValues {VideoEffectRecordedMatteHistory(samples:$0,finalized:true,source:frames)}
    try require(recorded.count==recordedChain.count,"Recorded matte ticks bind exactly to the original movie frames")
    let wrong=VideoEffectFrameIndex(times:frames.times.map {$0+0.001})
    try require(VideoEffectRecordedMatteHistory(samples:accepted[key.id]!,finalized:true,source:wrong)==nil,"A sidecar cannot bind to a shifted or re-encoded movie")
    let incomplete=VideoEffectRecordedMatteHistory(samples:accepted[key.id]!,finalized:false,source:frames)!
    try require(!incomplete.replay(at:3.5) && incomplete.replay(at:1),"Crash recovery replays the checkpoint and regenerates the uncaptured tail")
    liveHistory.reset();VideoEffectMatteCache.shared.purge()
    let replay=VideoEffectSourceMatteProvider()
    let queries=Array(0..<90)+[79,3,62,37,43,59,60,17,88]
    for index in queries {
        let output=try replay.render(effects:recordedChain,time:frames.times[index],frames:frames,identity:"recorded-matte-integration",renderer:renderer,recorded:recorded,prepare:{time,prefix,histories in
            let sample=try reader.sample(at:frames.times[frames.last(at:time)],firstAtOrAfter:true)
            let picture=sample.image.transformed(by:CGAffineTransform(scaleX:160/sample.image.extent.width,y:90/sample.image.extent.height))
            return .init(image:picture,contexts:try inputs.frameContexts(image:picture,effects:prefix,time:time,folder:folder,temporalHistories:histories))
        })
        try require(bytes(output)==liveFrames[index],"Recorded history reproduces accepted and skipped live frames, resets and random seeks at frame \(index)")
    }
    print("PASS: exact recorded-matte replay with skipped previews, gaps, camera resets and random seeks")
    let sidecar=try EffectAnalysisWriter(folder:folder,checkpointInterval:0)
    var captureQuant=VideoEffectSettings(.quantization,start:0,end:4)
    captureQuant.set("colors",.number(2));captureQuant.set("faceDetail",.toggle(false))
    let capturePalette=EffectPalette(colors:[EffectRGB(0.1,0.2,0.3),EffectRGB(0.8,0.7,0.6)],thresholds:[0.35])
    for index in 0..<90 {
        let tick=Int64((frames.times[index]*600).rounded())
        let resets=accepted.compactMapValues {$0.first(where:{$0.tick==tick})?.reset}
        try sidecar.append(time:frames.times[index],palettes:[captureQuant.id:capturePalette],mask:nil,qualities:[isolation.id:.lite],temporalResets:resets)
    }
    try sidecar.checkpoint(finalized:true)
    // Deliberately omit capturedEffectID on the source to exercise existing
    // projects as well as newly recorded recipes.
    let captureRecipe=(recordedChain+[captureQuant]).map {value -> VideoEffectSettings in
        var value=value;value.analysisFile=sidecar.metadataName;value.analysisDataFile=sidecar.dataName;return value
    }
    let capturedSource=SourceMedia(filename:"source.mp4",duration:4,videoEffects:captureRecipe)
    var copiedProject=Project(title:"Pasted capture");copiedProject.append(capturedSource)
    copiedProject.commit(TimelineEditing.inserting(copiedProject.edit.clips,into:copiedProject.edit,at:4))
    var insertedProject=Project(title:"Inserted capture");insertedProject.recordingInsertion=0;insertedProject.addRecording(capturedSource)
    for project in [copiedProject,insertedProject] {
        let reopened=try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(project))
        let media=try await MediaRenderer.timeline(project:reopened,folder:folder,previewDiagnostics:true)
        for instruction in media.videoComposition.instructions.compactMap({$0 as? VideoToolInstruction}) {
            let effects=instruction.clip.videoEffects!
            let copiedIsolation=effects.first(where:{$0.kind == .colorIsolation})!,copiedQuant=effects.first(where:{$0.kind == .quantization})!
            try require(instruction.effectMatteHistories.count==2 && instruction.effectMatteHistories[copiedIsolation.id]?.fingerprint==recorded[isolation.id]?.fingerprint,"Pasting and recording at insertion preserve captured history after reopening")
            let image=CIImage(color:.gray).cropped(to:bounds)
            let contexts=try inputs.frameContexts(image:image,effects:effects,time:1,folder:folder)
            try require(contexts[copiedIsolation.id]?.quality == .lite && contexts[copiedQuant.id]?.palette == capturePalette,"Independent pasted effect IDs retain saved quality and palette tracks")
        }
    }
    try require(copiedProject.edit.clips[0].videoEffects![0].id != copiedProject.edit.clips[1].videoEffects![0].id,"Pasted effects keep independent editable identities")
    print("PASS: recorded temporal history, palettes and quality survive paste, insertion and project reopening")
    var project=Project(title:"Temporal compositor")
    project.append(SourceMedia(filename:"source.mp4",duration:4,videoEffects:[key,animated,second]))
    let timeline=try await MediaRenderer.timeline(project:project,folder:folder)
    try require(timeline.videoComposition.instructions.allSatisfy {($0.requiredSourceTrackIDs ?? []).isEmpty},"Indexed temporal instructions avoid a second AVFoundation video decode")
    let generator=AVAssetImageGenerator(asset:timeline.composition)
    generator.videoComposition=timeline.videoComposition;generator.maximumSize=bounds.size
    generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
    func decoded(_ generator:AVAssetImageGenerator,_ frame:Int) async throws->Data {
        let picture=try await generator.image(at:CMTime(value:Int64(frame),timescale:30)).image
        var bytes=[UInt8](repeating:0,count:160*90*4)
        renderer.context.render(CIImage(cgImage:picture),toBitmap:&bytes,rowBytes:160*4,bounds:bounds,format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!)
        return Data(bytes)
    }
    var sequential:[Data]=[]
    for frame in 0..<60 {sequential.append(try await decoded(generator,frame))}
    for frame in [53,4,39,17,1,58,27,13,44,6] {
        VideoEffectMatteCache.shared.purge()
        let actual=try await decoded(generator,frame)
        try require(actual==sequential[frame],"AVFoundation temporal compositor matches sequential pixels after a backward seek")
    }
    final class Audit {
        let queue=DispatchQueue(label:"yourec.tests.frame-audit")
        let lock=NSLock(),context=CIContext(options:[.workingColorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!, .workingFormat:CIFormat.RGBAh])
        var frames:[Double:[String:String]]=[:]
        func enqueue(time:Double,image:CIImage,pixel:CVPixelBuffer,leases:[VideoEffectFrameLease]) {
            queue.async { self.record(time:time,image:image,pixel:pixel);withExtendedLifetime(leases) {} }
        }
        func completed()->[Double:[String:String]] {queue.sync {frames}}
        func record(time:Double,image:CIImage,pixel:CVPixelBuffer) {
            let width=CVPixelBufferGetWidth(pixel),height=CVPixelBufferGetHeight(pixel)
            var rgba=[UInt8](repeating:0,count:width*height*8)
            context.render(image,toBitmap:&rgba,rowBytes:width*8,bounds:CGRect(x:0,y:0,width:width,height:height),format:.RGBAh,colorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!)
            var output=Data()
            CVPixelBufferLockBaseAddress(pixel,.readOnly)
            let ten=CVPixelBufferGetPixelFormatType(pixel)==kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            for plane in 0..<CVPixelBufferGetPlaneCount(pixel) {
                let row=CVPixelBufferGetBytesPerRowOfPlane(pixel,plane),bytes=CVPixelBufferGetWidthOfPlane(pixel,plane)*(plane==0 ? 1 : 2)*(ten ? 2 : 1)
                let pointer=CVPixelBufferGetBaseAddressOfPlane(pixel,plane)!
                for y in 0..<CVPixelBufferGetHeightOfPlane(pixel,plane) {output.append(pointer.advanced(by:y*row).assumingMemoryBound(to:UInt8.self),count:bytes)}
            }
            CVPixelBufferUnlockBaseAddress(pixel,.readOnly)
            let hashes=["rgba":SHA256.hash(data:Data(rgba)).map{String(format:"%02x",$0)}.joined(),"yuv":SHA256.hash(data:output).map{String(format:"%02x",$0)}.joined()]
            lock.lock();frames[time]=hashes;lock.unlock()
        }
    }
    var firstExport:[Data]=[],firstAudit:[Double:[String:String]]=[:]
    let auditEnabled=ProcessInfo.processInfo.environment["YOUREC_EXPORT_AUDIT"] != "0"
    for run in 0..<4 {
        VideoEffectMatteCache.shared.purge()
        let destination=folder.appendingPathComponent("temporal-export-\(run).mov")
        let audit=Audit()
        if auditEnabled {VideoToolCompositor.auditFrames {t,image,pixel,leases in audit.enqueue(time:t,image:image,pixel:pixel,leases:leases)}}
        defer {VideoToolCompositor.auditFrames(nil)}
        _=try await MediaRenderer.render(project:project,folder:folder,destination:destination) {_ in}
        VideoToolCompositor.auditFrames(nil)
        let rawFrames=audit.completed()
        try JSONEncoder().encode(rawFrames).write(to:folder.appendingPathComponent("temporal-export-\(run)-audit.json"))
        if run==0 {firstAudit=rawFrames}
        else if auditEnabled {
            for plane in ["rgba","yuv"] {
                let different=rawFrames.keys.sorted().filter {rawFrames[$0]?[plane] != firstAudit[$0]?[plane]}
                print("EXPORT AUDIT \(plane): \(different.count)/\(rawFrames.count) different; first \(different.prefix(12))")
            }
            try require(rawFrames==firstAudit,"Repeated exports supply identical float and YCbCr frames to the encoder")
        }
        let movie=AVAssetImageGenerator(asset:AVURLAsset(url:destination));movie.maximumSize=bounds.size
        movie.requestedTimeToleranceBefore = .zero;movie.requestedTimeToleranceAfter = .zero
        for (index,frame) in [5,15,30,45,75,105].enumerated() {
            let actual=try await decoded(movie,frame)
            if run==0 {firstExport.append(actual)}
            else {
                // Hardware H.264 rate control may produce different lossy codes
                // for identical YCbCr input. Exact equality is asserted above,
                // before encoding; compressed pictures use the golden PSNR gate.
                let mse=zip(actual,firstExport[index]).reduce(0.0) {$0+pow(Double($1.0)-Double($1.1),2)}/Double(actual.count)
                let psnr=mse==0 ? Double.infinity : 10*log10(255*255/mse)
                try require(psnr>40,"Repeated compressed exports retain PSNR > 40 dB (\(psnr))")
            }
        }
    }
    var freezing=project
    let hold=TimelineEditing.freezing(project.edit,at:2).0
    freezing.commit(hold)
    let held=freezing.edit.clips.firstIndex(where:{$0.frozenFrame != nil})!
    var heldState=freezing.edit
    var quant=VideoEffectSettings(.quantization,start:0,end:4);quant.set("faceDetail",.toggle(false))
    heldState.clips[held].videoEffects?.append(quant);freezing.commit(heldState)
    let frozen=try await MediaRenderer.timeline(project:freezing,folder:folder,previewDiagnostics:true)
    let still=AVAssetImageGenerator(asset:frozen.composition);still.videoComposition=frozen.videoComposition
    still.requestedTimeToleranceBefore = .zero;still.requestedTimeToleranceAfter = .zero
    _=try await still.image(at:CMTime(seconds:3,preferredTimescale:30))
    print("PASS: temporal AVFoundation playback seeks and repeated full-resolution exports")
}


func videoEffectDepthImportTests() async throws {
    guard let path=ProcessInfo.processInfo.environment["YOUREC_CINEMATIC_FIXTURE"] else {return}
    let url=URL(fileURLWithPath:path)
    try require(VideoEffectDepthCatalog.normalization([-1,-0.5,0],attempted:3) != nil,"Cinematic disparity permits an undefined offset, including negative values")
    try require(VideoEffectDepthCatalog.normalization(Array(repeating:0.2,count:100),attempted:100)==nil,"Flat disparity never amplifies noise into full-strength blur")
    try require(VideoEffectDepthCatalog.normalization([0,0.5,1],attempted:100)==nil,"Mostly invalid depth falls back instead of inventing a range")
    guard let source=try await VideoEffectDepthCatalog().source(url:url),let repeated=try await VideoEffectDepthCatalog().source(url:url) else {throw ProjectError.invalidMedia}
    try require(source.frames.count>30 && source.lower.isFinite && source.upper>source.lower,"A real Cinematic original has indexed, decodable disparity")
    try require(source.frames==repeated.frames && source.lower==repeated.lower && source.upper==repeated.upper,"Source-wide disparity normalization is deterministic")
    try require(source.covers(source.range.start.seconds...source.range.end.seconds),"Complete Cinematic disparity covers the video interval")
    var damaged=source;damaged.frames.removeSubrange(10..<15)
    try require(!damaged.covers(source.range.start.seconds...source.range.end.seconds) && damaged.covers(source.frames[0].seconds...source.frames[5].seconds),"A depth gap disables only intervals containing that gap")
    func hash(_ pixel:CVPixelBuffer)->Data {
        CVPixelBufferLockBaseAddress(pixel,.readOnly);defer {CVPixelBufferUnlockBaseAddress(pixel,.readOnly)}
        let width=CVPixelBufferGetWidth(pixel),height=CVPixelBufferGetHeight(pixel),row=CVPixelBufferGetBytesPerRow(pixel)
        var bytes=Data()
        if let base=CVPixelBufferGetBaseAddress(pixel) {for y in 0..<height {bytes.append(base.advanced(by:y*row).assumingMemoryBound(to:UInt8.self),count:width*2)}}
        return Data(SHA256.hash(data:bytes))
    }
    let sequential=VideoEffectDepthReader(source:source),seeking=VideoEffectDepthReader(source:source)
    var hashes:[Data]=[],focus:[Float?]=[]
    for time in source.frames {
        guard let sample=try sequential.sample(at:time.seconds) else {throw ProjectError.invalidMedia}
        hashes.append(hash(sample.pixel));focus.append(sample.focus)
    }
    try require(focus.compactMap {$0}.count>source.frames.count/2,"Cinematic focus metadata is decodable alongside disparity")
    for index in (0..<source.frames.count).sorted(by:{($0*73)%source.frames.count<($1*73)%source.frames.count}) {
        for offset in [0.0,0.37] {
            let time=source.frames[index].seconds+source.frameDuration*offset
            guard let sample=try seeking.sample(at:time) else {throw ProjectError.invalidMedia}
            try require(sample.focus==focus[index],"Focus metadata follows the same random and sub-frame seeks")
            try require(hash(sample.pixel)==hashes[index],"Random, exact-PTS and sub-frame seeks return the indexed original disparity frame")
        }
    }
    let afterEnd=try seeking.pixel(at:source.range.end.seconds+1)
    try require(afterEnd==nil,"Depth never extends beyond its source interval")
    print("PASS: original Cinematic disparity, source-wide normalization, coverage and exact random-seek pixels")
}

func videoEffectDepthRenderTests(root:URL) async throws {
    guard let path=ProcessInfo.processInfo.environment["YOUREC_CINEMATIC_FIXTURE"] else {return}
    let folder=root.appendingPathComponent("depth-render-tests")
    try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
    let original=URL(fileURLWithPath:path),sourceURL=folder.appendingPathComponent("original.mov")
    try FileManager.default.copyItem(at:original,to:sourceURL)
    let duration=try await AVURLAsset(url:sourceURL).load(.duration).seconds
    var project=Project(title:"Imported depth render")
    project.append(SourceMedia(filename:sourceURL.lastPathComponent,duration:duration))
    var wide=VideoEffectSettings(.widescreen,start:0,end:duration);wide.set("ovalBokeh",.toggle(true));wide.set("flares",.number(0))
    var edit=project.edit;edit.clips[0].start=0.1;edit.clips[0].end=0.9;edit.clips[0].crop=CropSettings(rotation:12);edit.clips[0].videoEffects=[wide];project.commit(edit)
    let media=try await MediaRenderer.timeline(project:project,folder:folder)
    guard let instruction=media.videoComposition.instructions.first as? VideoToolInstruction,let depth=instruction.effectDepth else {throw ProjectError.invalidMedia}
    try require(depth.aligned && depth.covers(0.1...0.9),"Only registered, complete imported depth reaches the compositor")
    let generator=AVAssetImageGenerator(asset:media.composition);generator.videoComposition=media.videoComposition
    generator.maximumSize=CGSize(width:216,height:384);generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
    let time=CMTime(seconds:0.2,preferredTimescale:600)
    let expected=try await generator.image(at:time).image
    let output=folder.appendingPathComponent("depth-export.mp4")
    _ = try await MediaRenderer.render(project:project,folder:folder,destination:output) {_ in}
    let exported=AVAssetImageGenerator(asset:AVURLAsset(url:output));exported.appliesPreferredTrackTransform=true;exported.maximumSize=generator.maximumSize
    exported.requestedTimeToleranceBefore = .zero;exported.requestedTimeToleranceAfter = .zero
    let actual=try await exported.image(at:time).image
    try require(expected.width==actual.width && expected.height==actual.height && expected.height>expected.width,"Portrait imported depth preserves preview/export orientation")
    let context=CIContext(),width=expected.width,height=expected.height
    func pixels(_ image:CGImage)->[UInt8] {
        var bytes=[UInt8](repeating:0,count:width*height*4)
        context.render(CIImage(cgImage:image),toBitmap:&bytes,rowBytes:width*4,bounds:CGRect(x:0,y:0,width:width,height:height),format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!)
        return bytes
    }
    let reference=pixels(expected),result=pixels(actual),error=zip(reference,result).reduce(0.0){$0+abs(Double($1.0)-Double($1.1))}/Double(reference.count)
    try require(error<3,"Cinematic depth plus crop rotation produces the same preview/export pixels within encoding tolerance: \(error)")
    for request in [0.6,0.1,0.2] {_ = try await generator.image(at:CMTime(seconds:request,preferredTimescale:600))}
    let repeated=try await generator.image(at:time).image
    try require(pixels(repeated)==reference,"Depth-based composition is stable after reverse and random playback seeks")
    print("PASS: portrait Cinematic depth through camera geometry, editor seeks and full-resolution export (mean error \(error))")
}


private func reviewEffectRegressions(root: URL) async throws {
    let folder = root.appendingPathComponent("review-effects-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: root.appendingPathComponent("cadence24.mp4"), to: folder.appendingPathComponent("cadence24.mp4"))
    let cache = folder.appendingPathComponent("analysis-cache", isDirectory: true)
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    var generated: [URL] = []
    for n in 0..<8 {
        let file = cache.appendingPathComponent("palette-" + String(format: "%064x", n) + ".json")
        try Data(repeating: 0, count: 100).write(to: file); generated.append(file)
    }
    let userFile = cache.appendingPathComponent("my-palette.json"); try Data("keep".utf8).write(to: userFile)
    VideoEffectAnalysisFiles.prune(in: cache, keeping: generated[7], maximumBytes: 300, maximumFiles: 3)
    let retainedFiles = generated.filter { FileManager.default.fileExists(atPath: $0.path) }
    try require(retainedFiles.count == 3 && retainedFiles.contains(generated[7]) && FileManager.default.fileExists(atPath: userFile.path), "Analysis cache bounds old generated JSON and preserves current/user files")
    let source = SourceMedia(filename: "cadence24.mp4", duration: 4)
    for start in [1.01, 1.045, 4.0/30, 31.0/30] {
        var effect = VideoEffectSettings(.quantization, start: start, end: start + 1.0/30)
        effect.set("faceDetail", .toggle(false))
        let palette = try await VideoEffectAnalysis.shared.palette(source: source, effect: effect, folder: folder)
        try require(palette.valid && !palette.frames.isEmpty, "Palette analysis accepts a frame overlapping a short off-grid hold")
    }
    var held = TimelineClip(sourceID: source.id, start: 1.045, end: 1.045 + 1.0/30)
    held.frozenFrame = FrozenFrameSegment(sourceTime: held.start, duration: 0.5)
    var quantization = VideoEffectSettings(.quantization, start: 0, end: 4)
    quantization.set("faceDetail", .toggle(false)); held.videoEffects = [quantization]
    var project = Project(title: "24 fps freeze export"); project.append(source); project.commit(EditState(clips: [held]))
    let file = folder.appendingPathComponent("hold.mp4")
    _ = try await MediaRenderer.render(project: project, folder: folder, destination: file) { _ in }
    let duration = try await AVURLAsset(url: file).load(.duration).seconds
    try require(abs(duration - 0.5) < 1.0/30, "Off-grid Freeze plus Quantization exports the complete hold")

    let renderer = try MetalEffectRenderer(), provider = VideoEffectSourceMatteProvider()
    let frames = VideoEffectFrameIndex(times: (0..<30).map { Double($0)/30 })
    let isolation = VideoEffectSettings(.colorIsolation, start: 0, end: 1)
    var correction = VideoEffectSettings(.colorCorrection, start: 0, end: 1); correction.set("hue", .number(120))
    let image = CIImage(color: CIColor(red: 0.75, green: 0.22, blue: 0.17)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 36))
    var prefixes: [[VideoEffectID]] = []
    let identity = UUID().uuidString
    _ = try provider.render(effects: [isolation, correction], time: 10.0/30, frames: frames, identity: identity, renderer: renderer, prepare: { _, prefix, _ in
        prefixes.append(prefix.map(\.kind)); return .init(image: image, contexts: [:])
    })
    try require(!prefixes.isEmpty && prefixes.allSatisfy { $0 == [.colorCorrection, .colorIsolation] }, "Temporal masks use the renderer's correction-first order")
    try require(VideoEffectAnalysis.prefix([isolation, correction], before: isolation.id).map(\.kind) == [.colorCorrection], "Color picking uses the same upstream order")
    let rendered = provider.historicalRenders
    correction.set("hue", .number(0))
    _ = try provider.render(effects: [isolation, correction], time: 10.0/30, frames: frames, identity: identity, renderer: renderer, prepare: { _, _, _ in .init(image: image, contexts: [:]) })
    try require(provider.historicalRenders > rendered, "Changing correction invalidates historical masks")

    var night = VideoEffectSettings(.nightFix, start: 0, end: 4)
    night.set("brightness", .number(2.5)); night.set("mode", .choice("Medium"))
    var clip = TimelineClip(sourceID: source.id, start: 0, end: 4); clip.videoEffects = [night, isolation]
    let instruction = VideoToolInstruction(trackID: 1, clip: clip, start: .zero, transform: .identity, sourceSize: CGSize(width: 160, height: 90), canvas: CGSize(width: 160, height: 90), stabilization: nil, sequenceClock: VideoEffectSequenceClock(clip))
    instruction.sourceURL = folder.appendingPathComponent(source.filename)
    let initial = try instruction.matteIdentity()
    night.set("brightness", .number(8)); night.set("mode", .choice("Precise")); instruction.previewEffects([night, isolation])
    let changed = try instruction.matteIdentity()
    try require(initial != changed, "Night Fix settings invalidate the same instruction's matte cache")
    night.enabled = false; instruction.previewEffects([night, isolation])
    let disabled = try instruction.matteIdentity()
    try require(disabled != changed, "Disabling Night Fix also invalidates matte history")
    print("PASS: off-grid Freeze/Quantization export, correction-first mask history and Night Fix cache invalidation")
}
