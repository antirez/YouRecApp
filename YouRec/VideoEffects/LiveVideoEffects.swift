@preconcurrency import AVFoundation
import CoreImage
import MetalKit
import UIKit

enum LiveCrashState:String { case ready="Ready",pushing="Pushing",holding="Holding",returning="Returning" }

enum CameraFramePresentation { case effects, peakingOverlay, assistedCapture }

final class LiveVideoEffects: @unchecked Sendable {
    static let folder: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LiveEffects", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }()
    var onFrame: ((CIImage?, CGFloat, Bool, [VideoEffectFrameLease],CGAffineTransform,CGPoint?,String?,CameraFramePresentation) -> Void)?
    private var deliveryCameraID: String?
    private var deliverySensorTransform = CGAffineTransform.identity // worker
    private var zoomFrameDeadline: Double? // host clock, worker only
    private var zoomPresentationDelay = 0.09
    private(set) var displayedZoomDeadline: CFTimeInterval? // main only
    private(set) var displayedSensorTransform = CGAffineTransform.identity // main
    var onNotice: ((String) -> Void)?
    var onQualityChange:((String?,Bool)->Void)?
    var onCrashState:((LiveCrashState)->Void)?
    var onSubject:((EffectSubjectSample?)->Void)?
    var onPalettePicked:((UUID,UUID,EffectPalette,Bool)->Void)?
    private var palettePick:(id:UUID,save:Bool)?
    var onColorPicked:((UUID,UUID,EffectRGB)->Void)?
    var onPlateProgress:((UUID,Double?)->Void)?
    var onFrameToolFailed:((UUID,String)->Void)?
    var onPlateReady:((UUID,UUID,String)->Void)?
    private var colorPickID:UUID?
    private var positionEffect:VideoEffectSettings?
    private var frameToolToken:UUID?
    private var colorPickImage:CIImage?
    private var colorPickLeases:[VideoEffectFrameLease]=[]
    private var plateCapture:(id:UUID,average:VideoEffectCleanPlate)?
    private var recordingPlate: VideoEffectCleanPlate?
    static func recordingPlateName(_ name: String) -> String? {
        guard name.hasPrefix("clean-plate-"), name.hasSuffix(".tiff") else { return nil }
        return name.hasSuffix("-record.tiff") ? name : String(name.dropLast(5)) + "-record.tiff"
    }
    private static func plateFiles(_ name: String) -> [String] {
        guard let recorded = recordingPlateName(name) else { return [name] }
        return [String(recorded.dropLast(12)) + ".tiff", recorded]
    }
    private var sweptPlates=false
    private var plateProgressAt = -Double.infinity
    var onTrackingMeasurement:((EffectSubjectSample?,CaptureZoomStamp)->Void)?
    private let subjectQueue=DispatchQueue(label:"yourec.effects.subject",qos:.userInitiated)
    private var subjectTracker:EffectSubjectTracker? // subjectQueue only
    private let trackingOrigin=ProcessInfo.processInfo.systemUptime
    private var latestSubject:EffectSubjectSample? // lock protected
    private var subjectBusy=false // lock protected
    private var subjectPoint:CGPoint? // copied on the worker before dispatch
    private var lastSubjectTime = -Double.infinity
    private var cameraTemplates:[VideoEffectSettings]=[]
    private var lastFrameTime=0.0
    private var crashState=LiveCrashState.ready
    private var inputTime:(value:Double,recording:Bool)? // lock protected
    private let queue = DispatchQueue(label: "yourec.effects.live", qos: .userInitiated)
    private let paletteQueue = DispatchQueue(label: "yourec.effects.palette", qos: .userInitiated)
    private let lock = NSLock()
    private var working = false
    private var enabled = false
    // Read under lock by capture/configuration; changed on the effects queue.
    private var framePreviewRequired = false
    private var assistedCapturePreview = false
    private var peakingRequested = false
    private var peakingDeliveryPending = false  // lock protected
    private var zoomFramesPending = 0 // lock protected

    private var generation = 0
    private var settings: [VideoEffectSettings] = []
    private var renderer: MetalEffectRenderer?
    private var inputs: VideoEffectInputs?
    private var previousPalette: [UUID: EffectPalette] = [:]
    private var pendingPalette: [UUID: EffectPalette] = [:]
    private var paletteBusy = false
    private var paletteSampler:LiveEffectPaletteSampler? // paletteQueue only
    private var recordingURL: URL?
    private var analysis: EffectAnalysisWriter?
    private var elapsed = 0.0
    private var previewOrigin: Double?
    private var frames = 0
    private var reusedHoldFrames=0
    private var misses = 0
    private var noticeAt = -Double.infinity
    private var cpuTimes: [Double] = []
    private var gpuTimes: [Double] = []
    private var renderSize:CGSize = .zero
    private var tierTimes:[String:[(wall:Double,gpu:Double,encoding:Double,completion:Double)]]=[:]
    private var firstLiteFrame:Int?
    private var finalRung=""
    private var finalRungFrame=0
    private var finalRungTimes:[(wall:Double,gpu:Double)]=[]
    private var forcedQuality:VideoEffectQuality? {
        #if DEBUG
        if CommandLine.arguments.contains("--video-effects-force-full") { return .full }
        if CommandLine.arguments.contains("--video-effects-force-lite") { return .lite }
        #endif
        return nil
    }
    private var adaptsPreview:Bool {
        #if DEBUG
        if forcedQuality != nil || CommandLine.arguments.contains("--video-effects-preview-720") || CommandLine.arguments.contains("--video-effects-preview-540") {return false}
        #endif
        return true
    }
    private var stageTimes:[String:[Double]]=[:]
    private var failures = 0
    private var qualities:[UUID:VideoEffectQuality]=[:]
    private var budget=VideoEffectLiveBudget()
    private var qualityMessage:String?
    private var thermalQuality=false
    private var liteFrames=0
    // Effects-worker confined. Every displayed image uses its own segmentation;
    // submit() still bounds work to one frame and never blocks the capture queue.
    private var personProvider:VideoEffectPersonProvider?
    private var maskSmoother:VideoEffectMaskSmoother?
    private var lastMaskTime = -Double.infinity
    private var maskGeometry=""
    private var lastPaletteTime=0.0
    private var lastHeldImage: CIImage?
    private var lastHeldLeases:[VideoEffectFrameLease]=[]
    private var lastHeldIndex = -1
    private var lastHeldGeometry=CGAffineTransform.identity
    private var cadenceClock=VideoEffectCadenceClock(effects:[])
    private let matteHistory=VideoEffectLiveMatteHistory()
    #if DEBUG
    private var observedClock:[Double]=[]
    // Set before submitting frames; exercises slow segmentation without relying
    // on the scene or Vision's current neural inference speed.
    var probePersonMask: ((CIImage) throws -> CVPixelBuffer)?
    #endif
    private var auditionID: UUID?
    private var auditionStart: Double?
    func previewStrobe(_ id: UUID) {
        queue.async { self.auditionID = id; self.auditionStart = nil; self.lastHeldIndex = -1 }
    }
    func endStrobeAudition() {
        queue.async {
            guard self.auditionID != nil else { return }
            self.auditionID = nil; self.auditionStart = nil; self.lastHeldIndex = -1
        }
    }
    // Keep the capture clock, matte history and palette intact during direct manipulation.
    func adjustOpticalEffect(_ effect: VideoEffectSettings) {
        queue.async {
            guard self.recordingURL == nil, let i = self.settings.firstIndex(where: { $0.id == effect.id }) else { return }
            self.settings[i] = effect; self.lastHeldIndex = -1
        }
    }
    private func displayedEffects(at time: Double, recording: Bool) -> [VideoEffectSettings] {
        guard !recording && settings.contains(where: { $0.kind == .negativeStrobe }) else { return settings }
        return settings.compactMap { effect in
            guard effect.kind == .negativeStrobe else { return effect }
            guard effect.enabled, auditionID == effect.id else { return nil }
            let start = auditionStart ?? time
            auditionStart = start
            let duration = effect.toggle("timedBurst") ? effect.number("burstLength") : 2
            guard time >= start && time < start + duration else { auditionID = nil; return nil }
            var preview = effect
            preview.start = start; preview.end = start + duration
            return preview
        }
    }
    func configure(_ effects: [VideoEffectSettings]) {
        lock.lock(); generation += 1; lock.unlock()
        queue.async {
            self.matteHistory.reset()
            let keep=Set(effects.flatMap(\.mediaFiles).flatMap(Self.plateFiles)),old=Set((self.settings+self.cameraTemplates).flatMap(\.mediaFiles).flatMap(Self.plateFiles))
            if !self.sweptPlates || keep != old {
            self.sweptPlates=true
            for file in (try? FileManager.default.contentsOfDirectory(at:Self.folder,includingPropertiesForKeys:[.contentModificationDateKey])) ?? [] where file.lastPathComponent.hasPrefix("clean-plate-") && file.pathExtension=="tiff" && !keep.contains(file.lastPathComponent) {
                let modified=(try? file.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? Date()
                if old.contains(file.lastPathComponent) || Date().timeIntervalSince(modified)>60 { try? FileManager.default.removeItem(at:file) }
            }
            }
            self.personProvider=nil;self.maskSmoother=nil;self.lastMaskTime = -.infinity
            let oldChain=(self.settings+self.cameraTemplates).filter(\.enabled).map(\.id)
            let newChain=effects.filter(\.enabled).map(\.id)
            if Set(oldChain) != Set(newChain) {self.qualities.removeAll();self.budget=VideoEffectLiveBudget();self.setQualityMessage(nil)}
            let templates=effects.filter { [.dollyZoom,.crashZoom].contains($0.kind) }
            let sameCamera=templates==self.cameraTemplates
            let activeMoves=sameCamera ? self.settings.filter {$0.kind == .crashZoom} : []
            self.cameraTemplates=templates
            self.settings=effects.filter { ![.dollyZoom,.crashZoom].contains($0.kind) }+activeMoves
            self.cadenceClock=VideoEffectCadenceClock(effects:self.settings)
            if !sameCamera {
                self.subjectQueue.async { self.subjectTracker=nil }
                self.lastFrameTime=0;self.lastSubjectTime = -.infinity;self.setCrashState(.ready);self.previewOrigin=nil
                self.lock.lock();self.latestSubject=nil;self.lock.unlock()
            }
            self.previousPalette.removeAll();self.frames=0;self.reusedHoldFrames=0;self.lastHeldImage=nil;self.lastHeldLeases.removeAll();self.lastHeldIndex = -1
            self.lock.lock();self.pendingPalette.removeAll();self.misses=0;self.lock.unlock()
            if self.refreshEnabled() && (self.framePreviewRequired || self.hasEffectPreview) {
                do { try self.prepareRenderer() } catch { self.notice(error.localizedDescription) }
            }
        }
    }
    /// Use the captured buffer as the framing reference even with no effects.
    /// Submission stays bounded to the existing single frame in flight.
    func requireFramePreview(_ required: Bool, peaking: Bool = false, assistedCapture: Bool = false) {
        queue.async {
            self.lock.lock()
            let framingChanged = self.framePreviewRequired != required || self.assistedCapturePreview != assistedCapture
            guard framingChanged || self.peakingRequested != peaking else { self.lock.unlock(); return }
            self.framePreviewRequired = required
            self.assistedCapturePreview = assistedCapture
            self.peakingRequested = peaking
            self.generation += 1
            self.lock.unlock()
            if framingChanged {
                self.budget = VideoEffectLiveBudget(); self.qualities.removeAll(); self.setQualityMessage(nil)
                self.lastHeldImage = nil; self.lastHeldLeases.removeAll(); self.lastHeldIndex = -1
            }
            self.refreshEnabled()
        }
    }
    /// Effects queue only: derive the worker state after mutations have landed.
    /// A queued disable must hide the surface with the current generation even
    /// if a simultaneous framing change invalidated configure's earlier token.
    @discardableResult private func refreshEnabled() -> Bool {
        lock.lock()
        enabled = peakingRequested || framePreviewRequired || hasEffectPreview
        let active = enabled, token = generation
        lock.unlock()
        if !active { deliveryCameraID = nil; deliver(nil, angle: 0, mirrored: false, token: token) }
        return active
    }
    private var hasEffectPreview: Bool {
        frameToolToken != nil || positionEffect != nil
            || settings.contains(where: \.enabled) || cameraTemplates.contains(where: \.enabled)
    }
    private var plainFramePreview: Bool { framePreviewRequired && !hasEffectPreview }
    func positionEffect(_ effect:VideoEffectSettings) {
        queue.async {
            if self.positionEffect?.id != effect.id {self.clearFrameTools()}
            var preview=effect;preview.enabled=true;self.positionEffect=preview
            self.lock.lock();self.enabled=true;self.lock.unlock()
        }
    }
    func samplePalette(_ id:UUID,save:Bool,token:UUID) {
        queue.async {
            self.clearFrameTools();self.frameToolToken=token;self.palettePick=(id,save)
            self.lock.lock();self.enabled=true;self.lock.unlock()
        }
    }
    func beginColorPick(_ id:UUID,token:UUID) {
        queue.async {
            self.clearFrameTools();self.colorPickID=id;self.frameToolToken=token
            self.lock.lock();self.enabled=true;self.lock.unlock()
        }
    }
    func pickColor(at point:CGPoint) {
        queue.async {
            guard let token=self.frameToolToken,let id=self.colorPickID,let image=self.colorPickImage,let renderer=self.renderer else { return }
            let color=VideoEffectAnalysis.sampleColor(image,point:point,context:renderer.context)
            self.clearFrameTools(notify:false)
            DispatchQueue.main.async { self.onColorPicked?(token,id,color) }
        }
    }
    func capturePlate(for id:UUID,token:UUID) {
        queue.async {
            self.clearFrameTools();self.frameToolToken=token
            do {
                try self.prepareRenderer();self.plateCapture=(id,VideoEffectCleanPlate(renderer:self.renderer!));self.plateProgressAt = -.infinity
                self.lock.lock();self.enabled=true;self.lock.unlock()
                DispatchQueue.main.async { self.onPlateProgress?(token,0) }
            } catch { self.clearFrameTools(notify:false);DispatchQueue.main.async { self.onFrameToolFailed?(token,error.localizedDescription) } }
        }
    }
    func cancelFrameTools() { queue.async { self.clearFrameTools() } }
    private func clearFrameTools(notify:Bool = true) {
        let operation=frameToolToken;frameToolToken=nil
        positionEffect=nil;colorPickID=nil;colorPickImage=nil;colorPickLeases.removeAll();plateCapture=nil;recordingPlate=nil;palettePick=nil
        refreshEnabled()
        if notify,let operation { DispatchQueue.main.async { self.onPlateProgress?(operation,nil) } }
    }
    func beginRecording(_ url: URL, effects: [VideoEffectSettings]) throws {
        cancelFrameTools()
        // Called before the raw writer starts. Copy only chosen background assets;
        // the source movie itself remains the writer's responsibility.
        lock.lock();generation += 1;lock.unlock()
        let folder = url.deletingLastPathComponent()
        for name in Set(effects.flatMap(\.mediaFiles)) {
            let target = folder.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: target.path) { try FileManager.default.copyItem(at: Self.folder.appendingPathComponent(name), to: target) }
        }
        try JSONEncoder().encode(effects.filter { ![.dollyZoom,.crashZoom].contains($0.kind) }.map(\.recordingResult)).write(to: url.deletingPathExtension().appendingPathExtension("effects.json"), options: .atomic)
        queue.async {
            self.auditionID = nil; self.auditionStart = nil
            self.matteHistory.reset()
            let carried=self.carriedCrash(at:self.lastFrameTime)
            self.cameraTemplates=effects.filter { [.dollyZoom,.crashZoom].contains($0.kind) }
            self.settings = effects.filter { ![.dollyZoom,.crashZoom].contains($0.kind) };self.lastFrameTime=0;self.lastSubjectTime = -.infinity;self.setCrashState(.ready)
            self.settings += carried;self.updateCrashState(at:0)
            self.cadenceClock=VideoEffectCadenceClock(effects:self.settings)
            #if DEBUG
            self.observedClock=[]
            #endif
            self.recordingURL = url; self.elapsed = 0; self.frames = 0; self.lastHeldImage=nil; self.lastHeldLeases.removeAll(); self.lastHeldIndex = -1; self.cpuTimes.removeAll(); self.gpuTimes.removeAll(); self.tierTimes.removeAll();self.firstLiteFrame=nil;self.finalRung="";self.finalRungFrame=0;self.finalRungTimes.removeAll(); self.stageTimes.removeAll(); self.failures=0; self.liteFrames=0; self.previousPalette.removeAll(); self.lastPaletteTime=0
            self.reusedHoldFrames=0
            self.personProvider=nil;self.maskSmoother=nil;self.lastMaskTime = -.infinity
            self.lock.lock(); self.pendingPalette.removeAll();  self.misses=0; self.lock.unlock()
            do { self.analysis = effects.contains(where:{$0.enabled && $0.kind != .dollyZoom}) ? try EffectAnalysisWriter(folder:folder,maskFilter:"auto-background-ema-v1",motionAwareAutoBackground:true) : nil;try self.saveRecipe() }
            catch { self.notice("The original video is recording. Effect analysis could not be saved: " + error.localizedDescription) }
        }
    }
    func finishRecording(discard:Bool=false,_ completion: @escaping () -> Void) {
        queue.async {
            defer {
                let carried=self.carriedCrash(at:self.lastFrameTime)
                self.recordingURL=nil;self.analysis=nil;self.previewOrigin=nil
                self.settings.removeAll {$0.kind == .crashZoom};self.settings += carried
                self.lastFrameTime=0;self.lastSubjectTime = -.infinity;self.updateCrashState(at:0);completion()
            }
            guard let url = self.recordingURL else { return }
            #if DEBUG
            if CommandLine.arguments.contains("--video-effects-cadence-only") {
                try? JSONEncoder().encode(self.observedClock).write(to:url.deletingPathExtension().appendingPathExtension("effect-clock.json"),options:.atomic)
            }
            #endif
            if discard {
                self.analysis?.discard();try? FileManager.default.removeItem(at:url.deletingPathExtension().appendingPathExtension("effects.json"));return
            }
            do {
                var recipe = self.settings.map(\.recordingResult)
                if let analysis = self.analysis {
                    try analysis.checkpoint(finalized:true)
                    for i in recipe.indices { recipe[i].analysisFile = analysis.metadataName; recipe[i].analysisDataFile = analysis.dataName;recipe[i].capturedEffectID=recipe[i].id }
                }
                for i in recipe.indices where recipe[i].kind != .crashZoom { recipe[i].start = 0; recipe[i].end = 604800 }
                try JSONEncoder().encode(recipe).write(to: url.deletingPathExtension().appendingPathExtension("effects.json"), options: .atomic)
            } catch { self.notice("The original video was saved. Some effect analysis is unavailable: " + error.localizedDescription) }
        }
    }
    private func carriedCrash(at time:Double)->[VideoEffectSettings] {
        settings.filter { $0.kind == .crashZoom && $0.enabled && $0.start<=time && $0.end>time }.map { effect in
            var result=effect;result.phaseOffset=(effect.phaseOffset ?? 0)+time-effect.start;result.start=0
            result.end=effect.end==604800 ? 604800 : max(1.0/30,effect.end-time)
            result.releaseTime=effect.releaseTime.map {$0-time};return result
        }
    }
    func target(_ point:CGPoint?) {
        lock.lock();generation += 1;lock.unlock()
        queue.async {
            self.subjectPoint=point;self.lastSubjectTime = -.infinity
            self.lock.lock();self.latestSubject=nil;self.lock.unlock()
            self.subjectQueue.async { self.subjectTracker=nil }
        }
    }
    func triggerCrash() {
        queue.async {
            self.lock.lock();let submitted=self.inputTime;self.lock.unlock()
            let time:Double
            if let submitted,submitted.recording == (self.recordingURL != nil) { time=submitted.recording ? submitted.value : max(0,submitted.value-(self.previewOrigin ?? submitted.value)) }
            else { time=self.lastFrameTime }
            if let index=self.settings.lastIndex(where:{$0.kind == .crashZoom && $0.enabled && $0.start<=time && $0.end>time}) {
                let effect=self.settings[index],push=effect.number("speed"),origin=effect.start-(effect.phaseOffset ?? 0)
                let release=effect.releaseTime ?? (effect.toggle("return") ? origin+push+0.08+effect.number("hold") : .infinity)
                guard time>=origin+push+0.08,time<release else { return }
                self.settings[index].releaseTime=time;self.settings[index].end=time+push
                self.setCrashState(.returning);do { try self.saveRecipe() } catch { self.notice(error.localizedDescription) };return
            }
            guard var effect=self.cameraTemplates.first(where:{$0.enabled && $0.kind == .crashZoom}) else { return }
            effect.id=UUID();effect.start=time;effect.releaseTime=nil;effect.phaseOffset=0
            effect.end=effect.toggle("return") ? time+2*effect.number("speed")+0.08+effect.number("hold") : 604800
            if let point=self.subjectPoint { effect.set("targetX",.number(point.x));effect.set("targetY",.number(point.y)) }
            self.settings.append(effect);self.setCrashState(.pushing);do { try self.saveRecipe() } catch { self.notice(error.localizedDescription) }
        }
    }
    private func saveRecipe() throws {
        guard let url=recordingURL else { return }
        var recipe=settings.map(\.recordingResult)
        if let analysis {
            try analysis.checkpoint()
            for index in recipe.indices { recipe[index].analysisFile=analysis.metadataName;recipe[index].analysisDataFile=analysis.dataName;recipe[index].capturedEffectID=recipe[index].id }
        }
        try JSONEncoder().encode(recipe).write(to:url.deletingPathExtension().appendingPathExtension("effects.json"),options:.atomic)
    }
    private func setCrashState(_ state:LiveCrashState) {
        guard crashState != state else { return };crashState=state
        DispatchQueue.main.async { self.onCrashState?(state) }
    }
    private func updateCrashState(at time:Double) {
        guard let effect=settings.last(where:{$0.kind == .crashZoom && $0.enabled && $0.start<=time && $0.end>time}) else { setCrashState(.ready);return }
        let push=effect.number("speed"),origin=effect.start-(effect.phaseOffset ?? 0)
        let release=effect.releaseTime ?? (effect.toggle("return") ? origin+push+0.08+effect.number("hold") : .infinity)
        setCrashState(time<origin+push+0.08 ? .pushing : time>=release ? .returning : .holding)
    }
    private func analysisCopy(_ input:CIImage,longSide:Double) throws -> CIImage {
        let factor=min(1,longSide/max(input.extent.width,input.extent.height))
        let size=CGSize(width:max(1,floor(input.extent.width*factor)),height:max(1,floor(input.extent.height*factor)))
        let reduced=input.transformed(by:CGAffineTransform(scaleX:size.width/input.extent.width,y:size.height/input.extent.height))
        let texture=try inputs!.texture(reduced,size:size,waitForCompletion:true)
        guard let image=CIImage(mtlTexture:texture,options:[.colorSpace:renderer!.space]) else { throw VideoEffectError.buffer }
        return MetalEffectRenderer.textureImage(image)
    }
    #if DEBUG
    private var failPlainPreviewUntil = 0.0
    private var failOnePlainPreview = false
    func probeFailOnePlainPreview() { queue.async { self.failOnePlainPreview = true } }
    func probeFailPlainPreview() { queue.async { self.failPlainPreviewUntil = ProcessInfo.processInfo.systemUptime + 3 } }
    #endif
    // One frame in flight, no unbounded capture-buffer queue. Submission takes a
    // lock and retains a buffer; Vision/GPU/decode/storage happen on our worker.
    func submit(_ pixel: CVPixelBuffer, time: Double, recording: Bool, angle: CGFloat, mirrored: Bool, cameraStamp:CaptureZoomStamp?=nil,sourceCameraID:String?=nil,displayTime:Double?=nil,recordingReference:CVPixelBuffer?=nil, sensorTransform: CGAffineTransform = .identity) {
        lock.lock();inputTime=(time,recording)
        guard enabled, !working else { if working { misses += 1 }; lock.unlock(); return }
        working = true; let token = generation; lock.unlock()
        queue.async {
            defer { self.lock.lock(); self.working = false; self.lock.unlock() }
            self.lock.lock(); let current = self.enabled && self.generation == token; self.lock.unlock()
            guard current else { return }
            self.deliveryCameraID = sourceCameraID
            self.deliverySensorTransform = sensorTransform
            if let stamp = cameraStamp, let move = stamp.manualMove, move.compensatesSensorSwitch {
                if self.zoomFrameDeadline == nil {
                    // Stabilized 4K frames can already be 90 ms old on arrival.
                    // Give the display some headroom, fixed for the entire move
                    // so variations in capture delivery do not change its pace.
                    let age = CMClockGetTime(CMClockGetHostTimeClock()).seconds - stamp.time
                    self.zoomPresentationDelay = move.drivesStabilizedSensor ? min(0.22, max(0.09, age + 0.05)) : 0.09
                }
                self.zoomFrameDeadline = stamp.time + self.zoomPresentationDelay
            } else { self.zoomFrameDeadline = nil }
            autoreleasepool {
                let began=ProcessInfo.processInfo.systemUptime
                do {
                    if !self.hasEffectPreview && (self.assistedCapturePreview || (self.peakingRequested && !self.framePreviewRequired)) {
                        // Keep the native layer's HDR, exposure and framing. The MTKView
                        // contributes transparent contours only and never feeds the writer.
                        let image = CIImage(cvPixelBuffer: pixel)
                        self.deliver(image, angle: angle, mirrored: mirrored, token: token, presentation: self.assistedCapturePreview ? .assistedCapture : .peakingOverlay)
                        return
                    }
                    try self.prepareRenderer()
                    if self.previewOrigin == nil { self.previewOrigin = time }
                    let local = VideoEffectTime.captureTime(displayTime ?? (recording ? time : max(0,time-self.previewOrigin!)))
                    #if DEBUG
                    if recording,CommandLine.arguments.contains("--video-effects-cadence-only"),self.observedClock.count<900 {self.observedClock.append(local)}
                    #endif
                    if recording { self.elapsed = local }
                    self.lastFrameTime=local;self.updateCrashState(at:local)
                    self.frames += 1
                    var input = LogColor.image(pixel, displayReferred: true)
                    if self.plainFramePreview {
                        #if DEBUG
                        if self.failOnePlainPreview { self.failOnePlainPreview = false; throw VideoEffectError.buffer }
                        if ProcessInfo.processInfo.systemUptime < self.failPlainPreviewUntil { throw VideoEffectError.buffer }
                        #endif
                        // A raw framing preview does not need 4K effect textures
                        // or effects/thermal-quality notices. Only this display
                        // copy is scaled; the writer receives the original buffer.
                        let scale = min(1, 1920 / max(input.extent.width, input.extent.height))
                        input = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                        let display = Self.displayInput(input, hdr: VideoColor.isHDR(pixel))
                        var leases: [VideoEffectFrameLease] = []
                        let image = try self.renderer!.render(display.image, effects: [], sourceTime: local,
                            hdr: display.hdr, mapInputOnly: true, lease: { leases.append($0) })
                        self.renderSize = input.extent.size
                        self.cpuTimes.append(ProcessInfo.processInfo.systemUptime - began)
                        self.gpuTimes.append(self.renderer!.gpuSeconds)
                        if self.cpuTimes.count > 600 { self.cpuTimes.removeFirst() }
                        if self.gpuTimes.count > 600 { self.gpuTimes.removeFirst() }
                        self.deliver(image, angle: angle, mirrored: mirrored, token: token, leases: leases)
                        return
                    }
                    let folder = recording ? self.recordingURL?.deletingLastPathComponent() : Self.folder
                    if let plate=self.plateCapture,let operation=self.frameToolToken {
                        let finished=try plate.average.append(input,time:time,hdr:VideoColor.isHDR(pixel))
                        if let reference = recordingReference {
                            if self.recordingPlate == nil { self.recordingPlate = VideoEffectCleanPlate(renderer: self.renderer!) }
                            _ = try self.recordingPlate?.append(CIImage(cvPixelBuffer: reference), time: time, hdr: VideoColor.isHDR(reference))
                        }
                        if time-self.plateProgressAt>=0.1 || finished {
                            self.plateProgressAt=time;let progress=plate.average.progress
                            DispatchQueue.main.async { self.onPlateProgress?(operation,progress) }
                        }
                        var leases:[VideoEffectFrameLease]=[]
                        let preview=try self.renderer!.render(input,effects:[],sourceTime:local,hdr:VideoColor.isHDR(pixel),mapInputOnly:true,lease:{leases.append($0)})
                        self.deliver(preview,angle:angle,mirrored:mirrored,token:token,leases:leases)
                        if finished {
                            let name="clean-plate-"+UUID().uuidString+".tiff"
                            try plate.average.save(to:Self.folder.appendingPathComponent(name))
                            if let recorded = Self.recordingPlateName(name) { try self.recordingPlate?.save(to: Self.folder.appendingPathComponent(recorded)) }
                            self.clearFrameTools(notify:false)
                            DispatchQueue.main.async { self.onPlateReady?(operation,plate.id,name) }
                        }
                        return
                    }
                    let sourceLongSide=max(input.extent.width,input.extent.height)
                    let thermal=ProcessInfo.processInfo.thermalState
                    if self.adaptsPreview {
                        self.budget.thermal(serious:thermal == .serious,critical:thermal == .critical)
                        if self.budget.quality == .lite {for effect in self.settings {self.qualities[effect.id] = .lite}}
                    }
                    var limit=self.budget.maximumLongSide ?? .infinity
                    #if DEBUG
                    if CommandLine.arguments.contains("--video-effects-preview-540") {limit=960}
                    else if CommandLine.arguments.contains("--video-effects-preview-720") {limit=1280}
                    #endif
                    if sourceLongSide>limit {
                        let scale=limit/sourceLongSide
                        input=input.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
                    }
                    // Dual-camera display frames use the writer clock, while a separate processor records analysis.
                    let displayed = self.displayedEffects(at: local, recording: recording || displayTime != nil)
                    self.renderSize=input.extent.size
                    let matteGeometry="\(cameraStamp?.lens ?? "camera")-\(CVPixelBufferGetWidth(pixel))x\(CVPixelBufferGetHeight(pixel))-\(angle)-\(mirrored)"
                    if let background=self.positionEffect {
                        let chain=VideoEffectAnalysis.prefix(displayed,before:background.id)+[background]
                        let snapshot=self.matteHistory.peek(effects:chain,time:local,geometry:matteGeometry)
                        let frames=snapshot.applying(to:try self.liveContexts(input,pixel:pixel,effects:chain,time:local,folder:folder,angle:angle,mirrored:mirrored,token:token),device:self.renderer!.device.registryID,capture:false)
                        var leases:[VideoEffectFrameLease]=[]
                        let picture=try self.renderer!.render(input,effects:chain,sourceTime:local,hdr:VideoColor.isHDR(pixel),mapInputOnly:true,contexts:frames,lease:{leases.append($0)})
                        self.deliver(picture,angle:angle,mirrored:mirrored,token:token,leases:leases)
                        return
                    }
                    if let id=self.colorPickID {
                        let prefix=VideoEffectAnalysis.prefix(displayed,before:id)
                        let snapshot=self.matteHistory.peek(effects:prefix,time:local,geometry:matteGeometry)
                        let frames=snapshot.applying(to:try self.liveContexts(input,pixel:pixel,effects:prefix,time:local,folder:folder,angle:angle,mirrored:mirrored,token:token),device:self.renderer!.device.registryID,capture:false)
                        var leases:[VideoEffectFrameLease]=[]
                        let preview=try self.renderer!.render(input,effects:prefix,sourceTime:local,hdr:VideoColor.isHDR(pixel),mapInputOnly:true,contexts:frames,lease:{leases.append($0)})
                        self.colorPickImage=preview;self.colorPickLeases=leases
                        self.deliver(preview,angle:angle,mirrored:mirrored,token:token,leases:leases,geometry:VideoEffectGeometry.transform(prefix,time:local,size:input.extent.size))
                        return
                    }
                    let needsTarget=self.cameraTemplates.contains { $0.enabled && ($0.kind == .dollyZoom || $0.kind == .crashZoom && $0.toggle("trackFace")) }
                    let trackingTime=(cameraStamp?.time ?? ProcessInfo.processInfo.systemUptime)-self.trackingOrigin
                    self.lock.lock();let target=self.latestSubject.flatMap { trackingTime-$0.time<=0.5 ? $0 : nil }
                    let trackNow=needsTarget && !self.subjectBusy && local-self.lastSubjectTime>=1.0/15
                    if trackNow { self.subjectBusy=true;self.lastSubjectTime=local };self.lock.unlock()
                    if trackNow {
                        let copy:CIImage
                        do { copy=try self.analysisCopy(input,longSide:512) } catch { self.lock.lock();self.subjectBusy=false;self.lock.unlock();throw error }
                        let point=self.subjectPoint
                        self.subjectQueue.async {
                            if self.subjectTracker==nil { self.subjectTracker=EffectSubjectTracker(point:point,live:true) }
                            let subject=try? self.subjectTracker?.update(copy,time:trackingTime)
                            self.lock.lock();let current=self.generation==token
                            if current { self.latestSubject=subject };self.subjectBusy=false;self.lock.unlock()
                            if current, let cameraStamp {
                                // The optical dolly controller compares face height to physical lens zoom.
                                // Keep its measurement in sensor coordinates; effects track the cropped image.
                                let sensorSubject = subject.map { value in
                                    var sample = value
                                    sample.box = value.box.applying(sensorTransform)
                                    return sample
                                }
                                self.onTrackingMeasurement?(sensorSubject, cameraStamp)
                            }
                            if current { DispatchQueue.main.async {
                                self.lock.lock();let stillCurrent=self.generation==token;self.lock.unlock()
                                if stillCurrent { self.onSubject?(subject) }
                            } }
                        }
                    }

                    let matteSnapshot=self.matteHistory.snapshot(effects:displayed,time:local,geometry:matteGeometry)
                    var context=matteSnapshot.applying(to:try self.liveContexts(input,pixel:pixel,effects:displayed,time:local,folder:folder,angle:angle,mirrored:mirrored,token:token),device:self.renderer!.device.registryID,capture:true)
                    for effect in displayed where effect.kind == .crashZoom && effect.toggle("trackFace",at:local) { context[effect.id]?.target=target?.center }
                    if self.adaptsPreview && (thermal == .serious || thermal == .critical) {
                        self.setQualityMessage(self.budget.quality == .lite ? "The iPhone is warm. Live effects use lighter processing; recording continues." : "The iPhone is warm. Preview resolution is reduced; recording continues.",thermal:true)
                    } else if self.qualities.values.contains(.lite) {
                        self.setQualityMessage("Live preview uses lighter processing. Recording and export stay at full resolution.")
                    } else if self.budget.maximumLongSide != nil {
                        self.setQualityMessage("Preview resolution is reduced to keep recording smooth. Export stays at full resolution.")
                    }
                    for id in context.keys { context[id]?.quality=self.forcedQuality ?? self.qualities[id] ?? .full }
                    let isLite=context.values.contains(where:{$0.quality == .lite})
                    if isLite { self.liteFrames += 1;if self.firstLiteFrame == nil { self.firstLiteFrame=self.frames } }
                    self.lock.lock(); let ready = self.pendingPalette; self.pendingPalette.removeAll(); self.lock.unlock()
                    for (id, palette) in ready { self.previousPalette[id] = palette }
                    if let request=self.palettePick,let operation=self.frameToolToken,let effect=displayed.first(where:{$0.id==request.id}) {
                        let copy=try self.analysisCopy(input,longSide:256),all=displayed,person=self.inputs?.lastPersonPixel,autoPerson=self.inputs?.lastAutoBackgroundPixel,qualities=context.mapValues(\.quality),hdr=VideoColor.isHDR(pixel)
                        self.clearFrameTools(notify:false)
                        self.paletteQueue.async {autoreleasepool {
                            do {
                                if self.paletteSampler==nil {self.paletteSampler=try LiveEffectPaletteSampler()}
                                let palettes=self.paletteSampler!.analyze(copy,effects:all,targets:[effect],time:local,hdr:hdr,folder:folder,person:person,autoPerson:autoPerson,qualities:qualities,previous:[:],elapsed:0.2,subject:target,temporalHistories:matteSnapshot.history)
                                guard let palette=palettes[effect.id] else {throw VideoEffectError.shader(self.paletteSampler!.lastError ?? "Palette sampling")}
                                DispatchQueue.main.async {self.onPalettePicked?(operation,effect.id,palette,request.save)}
                            } catch {DispatchQueue.main.async {self.onFrameToolFailed?(operation,error.localizedDescription)}}
                        }}
                    }
                    let quant = displayed.filter { $0.enabled && $0.kind == .quantization }
                    if !quant.isEmpty {
                        let all=displayed,person=self.inputs?.lastPersonPixel,autoPerson=self.inputs?.lastAutoBackgroundPixel,qualities=context.mapValues(\.quality),hdr=VideoColor.isHDR(pixel)
                        // Retain only a private reduced image across background
                        // analysis, releasing the camera's scarce buffer promptly.
                        if self.previousPalette.isEmpty {
                            let copy=try self.analysisCopy(input,longSide:256)
                            self.previousPalette=self.paletteQueue.sync {
                                if self.paletteSampler==nil { self.paletteSampler=try? LiveEffectPaletteSampler() }
                                let sampled=self.paletteSampler?.analyze(copy,effects:all,targets:quant,time:local,hdr:hdr,folder:folder,person:person,autoPerson:autoPerson,qualities:qualities,previous:[:],elapsed:0.2,subject:target,temporalHistories:matteSnapshot.history) ?? [:]
                                if let error=self.paletteSampler?.lastError {self.notice("Palette analysis: "+error)}
                                return sampled
                            }
                        }
                        self.lock.lock(); let canAnalyze = !self.paletteBusy; if canAnalyze && self.frames.isMultiple(of: 6) { self.paletteBusy = true }; self.lock.unlock()
                        if canAnalyze && self.frames.isMultiple(of: 6) {
                            let copy:CIImage
                            do { copy=try self.analysisCopy(input,longSide:256) } catch { self.lock.lock();self.paletteBusy=false;self.lock.unlock();throw error }
                            let old=self.previousPalette,elapsed=max(0,local-self.lastPaletteTime)
                            self.lastPaletteTime=local
                            self.paletteQueue.async { autoreleasepool {
                                if self.paletteSampler==nil { self.paletteSampler=try? LiveEffectPaletteSampler() }
                                let results=self.paletteSampler?.analyze(copy,effects:all,targets:quant,time:local,hdr:hdr,folder:folder,person:person,autoPerson:autoPerson,qualities:qualities,previous:old,elapsed:elapsed,subject:target,temporalHistories:matteSnapshot.history) ?? [:]
                                if let error=self.paletteSampler?.lastError {self.queue.async {self.notice("Palette analysis: "+error)}}
                                self.lock.lock(); if self.generation == token { self.pendingPalette = results }; self.paletteBusy = false; self.lock.unlock()
                            } }
                        }
                        for effect in quant {
                            context[effect.id]?.palette = VideoEffectInputs.displayPalette(for: effect, at: local, analyzed: self.previousPalette[effect.id])
                        }
                    }
                    var leases:[VideoEffectFrameLease]=[]
                    let cadence=self.cadenceClock.hold(at:local)
                    let result:CIImage,rendered:Bool,cameraGeometry:CGAffineTransform
                    var temporalResets:[UUID:Bool]=[:]
                    var captured:[UUID:VideoEffectMatteCache.Frame]=[:]
                    if let cadence,cadence.index==self.lastHeldIndex,let held=self.lastHeldImage {
                        // Keep analysis and tracking current, but do not encode a
                        // full shader chain only to discard it for a held frame.
                        result=held;leases=self.lastHeldLeases;rendered=false
                        cameraGeometry=self.lastHeldGeometry;self.reusedHoldFrames += 1
                    } else {
                        let visible = displayed.filter { $0.enabled && $0.start <= local && local < $0.end }
                        let geometryOnly = visible.allSatisfy { $0.kind == .kaleidoscope }
                        let hdr = VideoColor.isHDR(pixel)
                        let display = geometryOnly ? Self.displayInput(input, hdr: hdr) : (image: input, hdr: hdr)
                        result=try self.renderer!.render(display.image,effects:displayed,sourceTime:local,hdr:display.hdr,mapInputOnly:self.framePreviewRequired || (geometryOnly && display.hdr),contexts:context,lease:{leases.append($0)},captureMatte:{captured[$0]=$1})
                        temporalResets=try self.matteHistory.resetDecisions(captured,snapshot:matteSnapshot)
                        rendered=true
                        cameraGeometry=VideoEffectGeometry.transform(displayed,time:local,size:input.extent.size,targets:context.compactMapValues(\.target))
                        if let cadence {self.lastHeldImage=result;self.lastHeldLeases=leases;self.lastHeldIndex=cadence.index;self.lastHeldGeometry=cameraGeometry}
                        else {self.lastHeldImage=nil;self.lastHeldLeases.removeAll();self.lastHeldIndex = -1}
                    }
                    if recording, let analysis = self.analysis {
                        let palettes = context.compactMapValues(\.palette)
                        try analysis.append(time:local,palettes:palettes,mask:self.inputs?.lastPersonPixel,autoBackgroundMask:self.inputs?.lastAutoBackgroundPixel,qualities:context.mapValues(\.quality),subject:target,temporalResets:temporalResets)
                    }
                    if rendered {try self.matteHistory.accept(captured,snapshot:matteSnapshot)}
                    let elapsed=ProcessInfo.processInfo.systemUptime-began
                    self.cpuTimes.append(elapsed)
                    // GPU percentiles describe actual renders; counting reused
                    // frames as zero would disguise a slow shader's tail latency.
                    if rendered {
                    self.gpuTimes.append(self.renderer!.gpuSeconds)
                    let tier=isLite ? "lite" : "full"
                    let rung=tier+"-\(Int(input.extent.width))x\(Int(input.extent.height))"
                    if rung != self.finalRung {self.finalRung=rung;self.finalRungFrame=self.frames;self.finalRungTimes.removeAll(keepingCapacity:true)}
                    self.finalRungTimes.append((elapsed,self.renderer!.gpuSeconds))
                    if self.finalRungTimes.count>1800 {self.finalRungTimes.removeFirst()}
                    self.tierTimes[tier,default:[]].append((elapsed,self.renderer!.gpuSeconds,self.renderer!.encodingSeconds,self.renderer!.completionSeconds))
                    if self.tierTimes[tier]!.count>1800 { self.tierTimes[tier]!.removeFirst() }
                    if self.adaptsPreview {
                        self.budget.observe(gpu:self.renderer!.gpuSeconds,wall:elapsed,sourceLongSide:sourceLongSide,renderLongSide:max(input.extent.width,input.extent.height))
                    }
                    for (stage,time) in self.renderer!.gpuStages {
                        self.stageTimes[stage,default:[]].append(time)
                        if self.stageTimes[stage]!.count>600 { self.stageTimes[stage]!.removeFirst() }
                    }
                    }
                    if self.cpuTimes.count>600 {self.cpuTimes.removeFirst()}
                    if self.gpuTimes.count>600 {self.gpuTimes.removeFirst()}
                    self.deliver(result,angle:angle,mirrored:mirrored,token:token,leases:leases,geometry:cameraGeometry,target:self.cameraTemplates.contains(where: \.enabled) ? (target?.center ?? self.subjectPoint) : nil)
                } catch {
                    // Any partially written analysis becomes a closed history
                    // boundary. The next successful frame records a fresh start.
                    self.matteHistory.reset();self.lastHeldImage=nil;self.lastHeldLeases.removeAll();self.lastHeldIndex = -1
                    self.failures += 1
                    if self.plainFramePreview {
                        // Do not leave a stale Metal picture covering the live
                        // camera when the display copy fails. The writer is independent.
                        self.deliver(nil, angle: angle, mirrored: mirrored, token: token)
                        self.notice("Full-frame preview unavailable; using camera preview. " + error.localizedDescription)
                    } else if let operation=self.frameToolToken {
                        self.clearFrameTools(notify:false)
                        DispatchQueue.main.async { self.onFrameToolFailed?(operation,error.localizedDescription) }
                    } else { self.notice("Live effect preview: " + error.localizedDescription) }
                }
            }
        }
    }
    // The live display surface is SDR. Use the same HLG display conversion with
    // or without a mirror; the recorder and editor retain the source headroom.
    private static func displayInput(_ image: CIImage, hdr: Bool) -> (image: CIImage, hdr: Bool) {
        if hdr, #available(iOS 18.0, *) {
            return (image.applyingFilter("CIToneMapHeadroom", parameters: ["inputTargetHeadroom": 1.0]), false)
        }
        return (image, hdr)
    }
    private func liveContexts(_ input:CIImage,pixel:CVPixelBuffer,effects:[VideoEffectSettings],time:Double,folder:URL?,angle:CGFloat,mirrored:Bool,token:Int) throws -> [UUID:FrameContext] {
        var person:CVPixelBuffer?,auto:CVPixelBuffer?
        if VideoEffectInputs.needsPerson(effects,at:time) {
            let geometry="\(deliveryCameraID ?? "camera")-\(CVPixelBufferGetWidth(pixel))x\(CVPixelBufferGetHeight(pixel))-\(angle)-\(mirrored)"
            if geometry != maskGeometry || time<=lastMaskTime || time-lastMaskTime>0.25 {
                personProvider=nil;maskSmoother=nil;maskGeometry=geometry
            }
            if personProvider==nil {personProvider=VideoEffectPersonProvider(live:true)}
            // Inference may lower preview cadence on a busy device. Keep the
            // entire last composite until this matching image/mask pair is ready,
            // rather than putting an old silhouette over newer camera pixels.
            #if DEBUG
            person=try probePersonMask?(input) ?? personProvider!.mask(input)
            #else
            person=try personProvider!.mask(input)
            #endif
            if effects.contains(where:{$0.enabled && $0.usesAutoMaskStream}) {
                if maskSmoother==nil {maskSmoother=try VideoEffectMaskSmoother()}
                auto=try maskSmoother!.push(person!,image:input,time:time,geometry:geometry,motionGate:true)
            }
            lastMaskTime=time
        }
        return try inputs!.frameContexts(image:input,effects:effects,time:time,folder:folder,live:true,personPixel:person,autoBackgroundPixel:auto,hdr:VideoColor.isHDR(pixel))
    }

    func metrics() async -> [String:Double] {
        await withCheckedContinuation { continuation in queue.async {
            func p95(_ values:[Double])->Double { let sorted=values.sorted();return sorted.isEmpty ? 0 : sorted[min(sorted.count-1,Int(Double(sorted.count)*0.95))]*1000 }
            self.lock.lock();let misses=self.misses;self.lock.unlock()
            var metrics=["renderedFrames":Double(self.frames-self.failures-self.reusedHoldFrames),"previewFrames":Double(self.frames-self.failures),"reusedHoldFrames":Double(self.reusedHoldFrames),"skippedPreviewFrames":Double(misses),"wallP95MS":p95(self.cpuTimes),"gpuP95MS":p95(self.gpuTimes),"errors":Double(self.failures),"liteFrames":Double(self.liteFrames)]
            func p50(_ values:[Double])->Double { let sorted=values.sorted();return sorted.isEmpty ? 0 : sorted[sorted.count/2]*1000 }
            metrics["finalRungStartFrame"]=Double(self.finalRungFrame)
            metrics["finalRungFrames"]=Double(self.finalRungTimes.count)
            metrics["finalRungGPU95MS"]=p95(self.finalRungTimes.map(\.gpu))
            metrics["finalRungWall95MS"]=p95(self.finalRungTimes.map(\.wall))
            metrics["firstLiteFrame"]=Double(self.firstLiteFrame ?? -1)
            metrics["renderWidth"]=self.renderSize.width;metrics["renderHeight"]=self.renderSize.height
            for (tier,values) in self.tierTimes {
                metrics[tier+".frames"]=Double(values.count)
                metrics[tier+".gpuP50MS"]=p50(values.map(\.gpu));metrics[tier+".gpuP95MS"]=p95(values.map(\.gpu))
                metrics[tier+".wallP50MS"]=p50(values.map(\.wall));metrics[tier+".wallP95MS"]=p95(values.map(\.wall))
                metrics[tier+".encodingP95MS"]=p95(values.map(\.encoding));metrics[tier+".completionP95MS"]=p95(values.map(\.completion))
            }
            for (stage,values) in self.stageTimes { metrics["stage."+stage+".p95MS"]=p95(values) }
            continuation.resume(returning:metrics)
        } }
    }
    private func setQualityMessage(_ message:String?,thermal:Bool=false) {
        guard message != qualityMessage || thermal != thermalQuality else { return };qualityMessage=message;thermalQuality=thermal
        DispatchQueue.main.async { self.onQualityChange?(message,thermal) }
    }
    private func prepareRenderer() throws {
        if renderer == nil {
            let renderer=try MetalEffectRenderer();renderer.profileGPU=CommandLine.arguments.contains("--video-effects-profile")
            self.renderer=renderer;inputs=VideoEffectInputs(renderer:renderer)
        }
    }
    private func deliver(_ image: CIImage?, angle: CGFloat, mirrored: Bool, token: Int,leases:[VideoEffectFrameLease]=[],geometry:CGAffineTransform = .identity,target:CGPoint?=nil, presentation: CameraFramePresentation = .effects) {
        // Frames can arrive in a burst at a sensor-mode switch. Present the
        // compensated preview at capture cadence on the display's host clock.
        // Bound pending work even if the main thread temporarily falls behind.
        let deadline = image == nil ? nil : zoomFrameDeadline
        let singlePending = presentation != .effects && deadline == nil
        lock.lock()
        if deadline != nil {
            guard zoomFramesPending < 5 else { lock.unlock(); return }
            zoomFramesPending += 1
        } else if singlePending {
            guard !peakingDeliveryPending else { lock.unlock(); return }
            peakingDeliveryPending = true
        }
        lock.unlock()
        let cameraID = deliveryCameraID, transform = deliverySensorTransform
        DispatchQueue.main.async {
            self.lock.lock()
            let current = token == self.generation
            if deadline != nil { self.zoomFramesPending -= 1 }
            if singlePending { self.peakingDeliveryPending = false }
            self.lock.unlock()
            if current {
                self.displayedZoomDeadline = deadline
                self.displayedSensorTransform = transform
                self.onFrame?(image,angle,mirrored,leases,geometry,target,cameraID,presentation)
            }
        }
    }
    private func notice(_ text: String) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now-noticeAt > 8 else { return }; noticeAt = now
        DispatchQueue.main.async { self.onNotice?(text) }
    }
}

final class MetalEffectPreview: MTKView, MTKViewDelegate {
    var onPresented: ((String?, UInt64) -> Void)?
    var onUnavailable: ((String?) -> Void)?
    private var zoomDeadline: CFTimeInterval?
    #if DEBUG
    private static let traceZoomPresentation = CommandLine.arguments.contains("--probe-zoom-motion")
    var probeDualPresentation: (@MainActor (CGFloat, CFTimeInterval) -> Void)?
    #endif
    private(set) var frameSerial: UInt64 = 0
    private var cameraID: String?
    private var picture: CIImage?
    private var frameLeases:[VideoEffectFrameLease]=[]
    private var captureAngle: CGFloat = 0
    private var capturedMirrored = false
    private(set) var previewAngle: CGFloat = 0
    private var expectedCaptureAngle: CGFloat?

    func orient(preview: CGFloat, capture: CGFloat) {
        guard previewAngle != preview || expectedCaptureAngle != capture else { return }
        previewAngle = preview; expectedCaptureAngle = capture
        if nativeOverlay { picture = nil }
        setNeedsDisplay()
    }
    var mirrored = false
    var fill = true
    var effectTransform=CGAffineTransform.identity
    var sensorTransform = CGAffineTransform.identity
    private(set) var nativeOverlay = false
    var peakingEnabled = false {
        didSet {
            guard peakingEnabled != oldValue else { return }
            if !peakingEnabled { peakingInput = nil; if nativeOverlay { isHidden = true } }
            setNeedsDisplay()
        }
    }
    private var peakingInput: MTLTexture?
    private lazy var peakingPipeline: MTLComputePipelineState? = {
        guard let device, let function = device.makeDefaultLibrary()?.makeFunction(name: "recorderFocusPeaking") else { return nil }
        return try? device.makeComputePipelineState(function: function)
    }()
    private let ci: CIContext
    private let commands: MTLCommandQueue
    init?(effectsPreview: Bool) {
        guard let device = MTLCreateSystemDefaultDevice(), let commands = device.makeCommandQueue() else { return nil }
        self.commands = commands; ci = CIContext(mtlDevice:device,options:[.cacheIntermediates:false])
        super.init(frame:.zero,device:device)
        framebufferOnly=false; colorPixelFormat = .bgra8Unorm; isPaused=true; enableSetNeedsDisplay=true; delegate=self
        isUserInteractionEnabled=false; isHidden=true; layer.isOpaque=true
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func show(_ image: CIImage?, angle: CGFloat, mirrored: Bool,leases:[VideoEffectFrameLease], cameraID: String?, nativeOverlay: Bool, zoomDeadline: CFTimeInterval?) {
        if self.nativeOverlay != nativeOverlay {
            self.nativeOverlay = nativeOverlay
            isOpaque = !nativeOverlay; layer.isOpaque = !nativeOverlay
            backgroundColor = .clear
        }
        self.cameraID = cameraID; frameSerial &+= 1
        frameLeases=leases;picture=image;captureAngle=angle;capturedMirrored=mirrored;isHidden=image == nil || (nativeOverlay && !peakingEnabled)
        self.zoomDeadline = zoomDeadline
        if image == nil { onUnavailable?(cameraID) }
        else if zoomDeadline != nil && !isHidden { draw() }
        else { setNeedsDisplay() }
    }
    private func viewTransform(in bounds:CGRect)->CGAffineTransform? {
        guard let original=picture,bounds.width>0,bounds.height>0 else { return nil }
        var transform=CGAffineTransform(rotationAngle:-(previewAngle-captureAngle)*CGFloat.pi/180)
        let rotated=original.extent.applying(transform)
        transform=transform.concatenating(CGAffineTransform(translationX:-rotated.minX,y:-rotated.minY))
        if mirrored != capturedMirrored { transform=transform.concatenating(CGAffineTransform(a:-1,b:0,c:0,d:1,tx:rotated.width,ty:0)) }
        let scale=fill ? max(bounds.width/rotated.width,bounds.height/rotated.height) : min(bounds.width/rotated.width,bounds.height/rotated.height)
        return transform.concatenating(CGAffineTransform(scaleX:scale,y:scale))
            .concatenating(CGAffineTransform(translationX:(bounds.width-rotated.width*scale)/2,y:(bounds.height-rotated.height*scale)/2))
            .concatenating(CGAffineTransform(a:1,b:0,c:0,d:-1,tx:0,ty:bounds.height))
    }
    func sourcePoint(at point:CGPoint,in bounds:CGRect)->CGPoint? {
        guard let original=picture,let transform=viewTransform(in:bounds) else { return nil }
        let source=point.applying(transform.inverted())
        guard original.extent.contains(source) else { return nil }
        let normalized=CGPoint(x:source.x/original.extent.width,y:1-source.y/original.extent.height).applying(effectTransform.inverted())
        return CGRect(x:0,y:0,width:1,height:1).contains(normalized) ? normalized : nil
    }
    // Remove effect geometry and any bars introduced by switching cameras
    // mid-take before letting AVFoundation convert the preview point to the lens.
    func captureOutputPoint(at point: CGPoint, sourceSize: CGSize) -> CGPoint? {
        guard let picture, let source = sourcePoint(at: point, in: bounds), sourceSize.width > 0, sourceSize.height > 0 else { return nil }
        let frame = CGRect(origin: .zero, size: picture.extent.size)
        let content = AVMakeRect(aspectRatio: sourceSize, insideRect: frame)
        let pixel = CGPoint(x: source.x * frame.width, y: source.y * frame.height)
        guard content.contains(pixel) else { return nil }
        let sensor = CGPoint(x: (pixel.x-content.minX)/content.width, y: (pixel.y-content.minY)/content.height).applying(sensorTransform)
        return CGPoint(x: sensor.x*sourceSize.width, y: sensor.y*sourceSize.height)
    }
    func framePoint(at point:CGPoint,in bounds:CGRect,clamped:Bool=true)->CGPoint? {
        guard let original=picture,let transform=viewTransform(in:bounds) else { return nil }
        let source=point.applying(transform.inverted())
        guard !clamped || original.extent.contains(source) else { return nil }
        return CGPoint(x:source.x/original.extent.width,y:1-source.y/original.extent.height)
    }
    func frameProjection(in bounds: CGRect) -> CGAffineTransform? {
        guard let original = picture, let view = viewTransform(in: bounds) else { return nil }
        let extent = original.extent
        return CGAffineTransform(a: extent.width, b: 0, c: 0, d: -extent.height,
                                 tx: extent.minX, ty: extent.maxY).concatenating(view)
    }
    func viewPoint(forSource point:CGPoint,in bounds:CGRect)->CGPoint? {
        guard let original=picture,let transform=viewTransform(in:bounds) else { return nil }
        let processed=point.applying(effectTransform)
        return CGPoint(x:processed.x*original.extent.width,y:(1-processed.y)*original.extent.height).applying(transform)
    }
    func mtkView(_ view: MTKView,drawableSizeWillChange size:CGSize) { setNeedsDisplay() }
    func draw(in view: MTKView) {
        guard let drawable = currentDrawable, let command = commands.makeCommandBuffer() else { return }
        // Retire the old contour on the same GPU queue as the next frame. A
        // transparent layer can stop presenting drawables altogether on iOS.
        if nativeOverlay && (picture == nil || expectedCaptureAngle != captureAngle) {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = drawable.texture
            pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            command.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
            command.present(drawable); command.commit()
            return
        }
        guard var image = picture else { return }
        let angle = (previewAngle-captureAngle)*CGFloat.pi/180
        image=image.transformed(by:CGAffineTransform(rotationAngle:-angle))
        image=image.transformed(by:CGAffineTransform(translationX:-image.extent.minX,y:-image.extent.minY))
        if mirrored != capturedMirrored { image=image.transformed(by:CGAffineTransform(a:-1,b:0,c:0,d:1,tx:image.extent.width,ty:0)) }
        let size=CGSize(width:drawable.texture.width,height:drawable.texture.height)
        let scale=fill ? max(size.width/image.extent.width,size.height/image.extent.height) : min(size.width/image.extent.width,size.height/image.extent.height)
        image=image.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
        image=image.transformed(by:CGAffineTransform(translationX:(size.width-image.extent.width)/2,y:(size.height-image.extent.height)/2))
        let bounds=CGRect(origin:.zero,size:size)
        let composed = image.composited(over: CIImage(color: .black).cropped(to: bounds))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        if !drawPeaking(composed, on: drawable.texture, command: command, bounds: bounds, colorSpace: colorSpace) {
            let fallback = nativeOverlay ? CIImage(color: .clear).cropped(to: bounds) : composed
            ci.render(fallback, to: drawable.texture, commandBuffer: command, bounds: bounds, colorSpace: colorSpace)
        }
        let heldLeases=frameLeases, nativeSource = nativeOverlay ? picture : nil
        let presentedCamera = cameraID, serial = frameSerial
        #if targetEnvironment(simulator)
        command.addCompletedHandler { [weak self] _ in
            DispatchQueue.main.async { self?.onPresented?(presentedCamera, serial) }
        }
        #else
        #if DEBUG
        let traceDeadline = Self.traceZoomPresentation ? zoomDeadline : nil
        let dualProbe = presentedCamera == "dual" && captureAngle == previewAngle ? probeDualPresentation : nil
        let drawnAngle = captureAngle
        #endif
        drawable.addPresentedHandler { [weak self] shown in
            guard shown.presentedTime > 0 else { return }
            #if DEBUG
            if let traceDeadline { print("Zoom presentation,\(traceDeadline),\(shown.presentedTime)") }
            if let dualProbe {
                let time = shown.presentedTime
                DispatchQueue.main.async { dualProbe(drawnAngle, time) }
            }
            #endif
            DispatchQueue.main.async { self?.onPresented?(presentedCamera, serial) }
        }
        #endif
        command.addCompletedHandler { _ in withExtendedLifetime((heldLeases, nativeSource)) {} }
        if let zoomDeadline { command.present(drawable, atTime: zoomDeadline) }
        else { command.present(drawable) }
        command.commit()
    }
    private func drawPeaking(_ image: CIImage, on display: MTLTexture, command: MTLCommandBuffer,
                             bounds: CGRect, colorSpace: CGColorSpace) -> Bool {
        guard peakingEnabled, let pipeline = peakingPipeline, let device else { return false }
        if peakingInput?.width != display.width || peakingInput?.height != display.height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: colorPixelFormat,
                width: display.width, height: display.height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]; descriptor.storageMode = .private
            peakingInput = device.makeTexture(descriptor: descriptor)
        }
        guard let input = peakingInput else { return false }
        // Unlike CI's direct drawable render, Metal addresses our intermediate
        // from its top row. Flip within the visible viewport for both paths.
        let sample = MetalEffectRenderer.textureImage(image.cropped(to: bounds))
        ci.render(sample, to: input, commandBuffer: command, bounds: bounds, colorSpace: colorSpace)
        guard let encoder = command.makeComputeCommandEncoder() else { return false }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(input, index: 0); encoder.setTexture(display, index: 1)
        var overlayOnly: UInt32 = nativeOverlay ? 1 : 0
        encoder.setBytes(&overlayOnly, length: MemoryLayout<UInt32>.size, index: 0)
        let width = pipeline.threadExecutionWidth
        encoder.dispatchThreads(MTLSize(width: input.width, height: input.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: min(8, pipeline.maxTotalThreadsPerThreadgroup / width), depth: 1))
        encoder.endEncoding()
        return true
    }

}
