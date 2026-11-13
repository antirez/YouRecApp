@preconcurrency import AVFoundation
import SwiftUI
import CoreImage
import AVKit

enum CaptureQuality: String, CaseIterable, Identifiable {
    case hd1080, ultraHD4K
    var id: Self { self }
    var title: String { self == .hd1080 ? "1080p · 30 fps" : "4K · 30 fps" }
    var preset: AVCaptureSession.Preset { self == .hd1080 ? .hd1920x1080 : .hd4K3840x2160 }
}

struct CameraChoice: Identifiable {
    let id: String
    let name: String
    let front: Bool
    var available = true
    var supportsLandscape = false
    var lens: AVCaptureDevice.DeviceType = .builtInWideAngleCamera
}
struct MicrophoneChoice: Identifiable {
    let id: String
    let name: String
}

/// Fast sensor readings are observed only by the recorder's changing labels.
/// They must not invalidate menus or settings while a finger is selecting a row.
final class CaptureReadings: ObservableObject {
    @Published private(set) var zoom: Double = 1
    @Published private(set) var focusLocked = false
    @Published private(set) var lensPosition: Float = 0.5
    @Published private(set) var level: Float = -160
    @Published private(set) var audioArriving = false
    @Published private(set) var audioClipping = false
    @Published private(set) var aperture: Float = 0
    #if DEBUG
    @Published private(set) var apertureProbe = ""
    func updateApertureProbe(_ text: String) { if apertureProbe != text { apertureProbe = text } }
    #endif

    func updateAperture(_ value: Float) { if aperture != value { aperture = value } }

    func update(zoom: Double, focusLocked: Bool, lensPosition: Float, level: Float, audioArriving: Bool, audioClipping: Bool) {
        if self.zoom != zoom { self.zoom = zoom }
        if self.focusLocked != focusLocked { self.focusLocked = focusLocked }
        if self.lensPosition != lensPosition { self.lensPosition = lensPosition }
        if self.level != level { self.level = level }
        if self.audioArriving != audioArriving { self.audioArriving = audioArriving }
        if self.audioClipping != audioClipping { self.audioClipping = audioClipping }
    }
}

// Session/device mutation is serialized on queue; observable values are only
// written by publish on the main queue. AVCaptureSession owns its thread safety.
final class CaptureController: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum State: String { case idle = "Ready", starting = "Starting", recording = "Recording", saving = "Saving", paused = "Paused" }
    private enum Next { case stop, pause, camera(String) }
    @Published private(set) var state: State = .idle
    @Published private(set) var dualActive = false
    @Published private(set) var dualPairs: [DualCameraPair] = []
    @Published private(set) var dualPairID = ""
    @Published private(set) var stabilizationEnabled = UserDefaults.standard.bool(forKey: "dualStabilization")
    @Published private(set) var faceFollowEnabled = UserDefaults.standard.bool(forKey: "dualFaceFollow")
    @Published private(set) var dualStabilizationSummary = ""
    @Published private(set) var singleStabilizationSupported = false
    @Published private(set) var singleStabilizationActive = false
    private var singleStabilizing = false // capture queue, requested on the actual output
    private var followPreviewRequired = false // includes the ramp back to full framing
    private lazy var singleFollow = SingleCameraFaceFollow(mediaQueue: movie.queue)
    @Published private(set) var singleFollowStatus = SingleCameraFaceFollow.Status.searching
    // Capture queue. Keep the user's framing separate from the ISP's centered
    // zoom until the native lens has taken it back, including mid-take toggles.
    private var followZoom: (lens: String, selected: CGFloat, restoring: Bool)?
    private var manualCenter: CGPoint? // capture queue, in full-lens sensor coordinates
    private var manualInputZoom: CGFloat? // widest hardware command issued for the current manual crop
    let framingSource = CameraFramingSource()
    private var framingPreviewOwner: (token: UUID, previousInput: CGFloat?)? // capture queue; speculative
    @Published private var manualFramePreview = false
    private var lastSingleStabilizationMode = AVCaptureVideoStabilizationMode.off
    var stabilizationStatus: String {
        if dualActive { return dualStabilizationSummary }
        if !singleStabilizationSupported { return "Stabilization unavailable for this camera format" }
        return singleStabilizationActive ? "Camera stabilized" : "Stabilization inactive"
    }
    // The rendered pixels already show tracking. Publishing every crop update
    // would repeatedly rebuild open menus; gestures read this when they begin.
    private var dualFollowFraming: DualCameraLayout?
    var dualDisplayLayout: DualCameraLayout {
        var result = dualLayout
        if faceFollowEnabled, let follow = dualFollowFraming {
            result.first.x = follow.first.x; result.first.y = follow.first.y
            result.second.x = follow.second.x; result.second.y = follow.second.y
        }
        return result
    }
    @Published private(set) var dualLayout: DualCameraLayout = {
        var layout = UserDefaults.standard.data(forKey: "dualCameraLayout").flatMap { try? JSONDecoder().decode(DualCameraLayout.self, from: $0) } ?? DualCameraLayout()
        layout.constrain(); return layout
    }()
    private lazy var horizon = HorizonLevel(media: movie.queue)
    @Published private(set) var horizonEnabled = UserDefaults.standard.bool(forKey: "levelHorizon")
    @Published private(set) var horizonDegrees = HorizonFraming.degrees(
        UserDefaults.standard.object(forKey: "levelHorizonDegrees") as? Double ?? HorizonFraming.defaultDegrees)
    private var previewLevelAngle = false // capture queue: momentary preview while choosing the angle
    private lazy var dualCapture = MultiCameraCapture(mediaQueue: movie.queue, horizon: horizon)
    var horizonUsesRear: Bool {
        if dualActive { return dualPairs.first(where: { $0.id == dualPairID }).map { $0.first.position == .back || $0.second.position == .back } ?? true }
        return cameras.first(where: { $0.id == cameraID })?.front == false
    }
    var canLevelHorizon: Bool {
        #if DEBUG && targetEnvironment(simulator)
        if recorderControlFixture { return true }
        #endif
        return horizon.available
    }
    private var dualEnabled = false // capture queue
    private var mediaDualActive = false // media queue
    private var dualPreviewPixel: CVPixelBuffer? // current composed preview; media queue
    private let dualRecordingEffects = LiveVideoEffects()
    private lazy var recordingEffects = liveEffects // media queue; fixed for each segment
    private var dualLastFrame = -Double.infinity // meter lock
    private var dualDeliveryWarned = false // capture queue
    private var activeSession: AVCaptureSession { dualEnabled ? dualCapture.session : session }
    private var activeEffects: [VideoEffectSettings] { dualActive ? videoEffects.filter { $0.kind != .dollyZoom && $0.kind != .crashZoom } : videoEffects }

    @Published private(set) var quality = CaptureQuality(rawValue: UserDefaults.standard.string(forKey: "captureQuality") ?? "") ?? .hd1080
    @Published private(set) var hdrEnabled = UserDefaults.standard.object(forKey: "captureHDR") as? Bool ?? true
    @Published private(set) var hdrActive = false
    @Published private(set) var hdrSupported = false
    @Published private(set) var logSupported = false
    @Published private(set) var activeLog: LUTInput?
    @Published private(set) var colorMode = CaptureColorMode(rawValue: UserDefaults.standard.string(forKey: "captureColorMode") ?? "") ?? ((UserDefaults.standard.object(forKey: "captureHDR") as? Bool ?? true) ? .hdr : .sdr)
    var activeColorMode: CaptureColorMode {
        if dualActive { return .sdr }
        if activeLog != nil { return .log }
        return hdrActive ? .hdr : .sdr
    }
    @Published var mirrorPreview = UserDefaults.standard.object(forKey: "mirrorFrontPreview") as? Bool ?? true {
        didSet { UserDefaults.standard.set(mirrorPreview, forKey: "mirrorFrontPreview"); updateDualComposition() }
    }
    @Published var mirrorRecording = UserDefaults.standard.bool(forKey: "mirrorFrontRecording") {
        didSet {
            UserDefaults.standard.set(mirrorRecording, forKey: "mirrorFrontRecording")
            updateDualComposition()
            queue.async { self.applyConnectionRotation() }
        }
    }
    var frontPreviewMirrored: Bool { !dualActive && mirrorPreview && cameras.first(where: { $0.id == cameraID })?.front == true }
    @Published private(set) var cameras: [CameraChoice] = []
    @Published private(set) var cameraID = ""
    @Published private(set) var switchingCamera = false
    @Published private(set) var microphones: [MicrophoneChoice] = []
    @Published private(set) var microphonePriority: [MicrophoneChoice] = []
    @Published private(set) var recordingGainDB = 0.0
    private let recordingGain = RecordingGain() // media queue
    @Published private(set) var microphoneID = ""
    @Published private(set) var microphoneName = "Microphone unavailable"
    @Published private(set) var meterAvailable = false
    @Published private(set) var displayZoomMultiplier: Double = 1
    @Published private(set) var maxZoom: Double = 1
    @Published private(set) var minZoom: Double = 1
    @Published private(set) var focusPeaking = UserDefaults.standard.bool(forKey: "focusPeaking")
    @Published private(set) var focusHint: String?
    private var focusHintDismiss: Task<Void, Never>?
    @Published private(set) var autofocusSupported = false
    @Published private(set) var focusAdjustable = false
    @Published private(set) var apertureStops: [Float] = []
    @Published private(set) var selectedAperture: Float?
    var apertureAvailable: Bool { !dualActive && !apertureStops.isEmpty }
    private var manualAperture: Float? // Capture queue; persist the requested stop, not an in-flight reading.
    private var manualFocus = false // capture-queue intent; one-shot AF can also end in .locked
    private var focusTarget: (id: UUID, deviceID: String, started: TimeInterval)?

    @Published private(set) var focusLockSupported = false
    @Published private(set) var ready = false
    @Published private(set) var startedAt: Date?
    @Published private(set) var rotationAngle: CGFloat = 90
    @Published private(set) var previewRotationAngle: CGFloat = 90
    @Published private(set) var frontLandscapeSupported = false
    @Published private(set) var frontLandscape = false
    @Published private(set) var takeCanvas: CGSize?
    private struct PreviewGeometry: Equatable {
        let size: CGSize
        let angle: CGFloat
        var cameraID: String?
    }
    @Published private var deliveredPreview: PreviewGeometry?
    private(set) var previewCanvas: CGSize? {
        get { deliveredPreview?.size }
        set { deliveredPreview = newValue.map { PreviewGeometry(size: $0, angle: rotationAngle) } }
    }
    var displayCanvas: CGSize? { takeCanvas ?? previewCanvas }
    var previewLayoutCanvas: CGSize? {
        guard let canvas = displayCanvas else { return nil }
        // The sample buffer is in capture coordinates. The preview layer and
        // Metal view both rotate it again for the window (e.g. portrait lock).
        // Fit the displayed axes, or AVLayer aspect-fits a second time inside
        // a landscape box that is already much too small.
        let frameAngle = takeCanvas == nil && !dualActive ? (deliveredPreview?.angle ?? rotationAngle) : rotationAngle
        let delta = (previewRotationAngle - frameAngle) * .pi / 180
        return CGRect(origin: .zero, size: canvas).applying(CGAffineTransform(rotationAngle: delta)).standardized.size
    }
    var showsWidePreview: Bool { displayCanvas.map { $0.width > $0.height } ?? frontLandscape }
    var needsFramePreview: Bool {
        dualActive || faceFollowEnabled || manualFramePreview || (horizonEnabled && horizonUsesRear)
            || (stabilizationEnabled && singleStabilizationSupported) || frontLandscape || activeLog != nil
            || Self.differentAspect(takeCanvas, previewCanvas)
    }
    private static func differentAspect(_ a: CGSize?, _ b: CGSize?) -> Bool {
        guard let a, let b, a.height > 0, b.height > 0 else { return false }
        return abs(a.width / a.height - b.width / b.height) > 0.001
    }
    @Published var warning: String?
    @Published var error: String?
    @Published private(set) var videoEffects: [VideoEffectSettings] = {
        guard let data = UserDefaults.standard.data(forKey: "liveVideoEffects"),
              let effects = try? JSONDecoder().decode(SupportedVideoEffects.self, from: data).values, effects.allSatisfy(\.valid) else { return [] }
        return effects
    }()
    @Published private(set) var effectQualityMessage:String?
    @Published private(set) var effectThermalWarning=false
    private let liveEffects = LiveVideoEffects()
    @Published private(set) var crashState=LiveCrashState.ready
    private(set) var trackedSubject:EffectSubjectSample?
    var crashAvailable:Bool { !dualActive && videoEffects.contains {$0.enabled && $0.kind == .crashZoom} }
    var canTriggerCrash:Bool { ready && !busy && (crashState == .ready || crashState == .holding) }
    func triggerCrashZoom() { guard canTriggerCrash else { return };liveEffects.triggerCrash();UIImpactFeedbackGenerator(style:.light).impactOccurred() }
    func selectEffectSubject(_ point:CGPoint) { liveEffects.target(point) }

    @Published private(set) var dollyState=LiveDollyState.ready
    @Published private(set) var dollyHint="Tap a face, then start"
    @Published private(set) var dollyHeadroom=1.0
    @Published private(set) var dollyRangeText=""
    var dollyAvailable:Bool { !dualActive && videoEffects.contains {$0.enabled && $0.kind == .dollyZoom} }
    var canTriggerDolly:Bool { ready && !busy && dollyState != .stopping }
    private var dollyFollower:DollyZoomFollower? // capture queue
    private var dollyLens=""
    private var dollyDirection="Stretch"
    private var dollyCleanZoom=1.0
    private var dollyEndsAt=Double.infinity
    private var dollyPreparation:UUID?
    private var dollyMeasurement:(subject:EffectSubjectSample,stamp:CaptureZoomStamp)?
    private var dollyLastUI = -Double.infinity
    private var dollyStopReason=""
    private let zoomHistory=CaptureZoomHistory()
    private let observedFollowZoom = CaptureZoomHistory()
    private var frameZoomCalibration = FrameZoomCalibration() // movie.queue
    private var effectCameraStamp:CaptureZoomStamp? // movie queue, paired with its callback
    private var effectSourceCameraID: String? // actual sample connection, not zoom-history interpolation
    private static var hostTime:Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }
    @Published private(set) var effectColorPick:UUID?
    @Published private(set) var effectPaletteSampling:UUID?
    @Published private(set) var cleanPlateProgress:Double?
    @Published private(set) var cleanPlateCountdown:Int?
    @Published private(set) var effectFrameSize:CGSize = .zero
    private var plateCountdownTask:Task<Void,Never>?
    private var colorPickParameter=""
    private var effectFrameToolToken:UUID?
    private var plateTimeout:Task<Void,Never>?
    @Published private(set) var positioningEffectID:UUID?
    @Published private(set) var effectBackgroundPlacement:VideoEffectBackgroundPlacement?
    @Published private var positionDraft:VideoEffectSettings?
    private var effectBackgroundPending:VideoEffectBackgroundPlacement?
    private var effectBackgroundAt = -Double.infinity
    @Published private var inspectedLiveEffectID: UUID?
    @Published private(set) var splitProjection: CGAffineTransform?
    var inspectedLiveEffect: VideoEffectSettings? {
        guard let id = inspectedLiveEffectID else { return nil }
        return videoEffects.first { $0.id == id && $0.enabled }
    }
    var showsOpticalInspector: Bool {
        switch inspectedLiveEffect?.kind {
        case .kaleidoscope, .rgbOffset, .negativeStrobe: true
        default: false
        }
    }
    func inspectLiveEffect(_ id: UUID?) {
        guard inspectedLiveEffectID != id else { return }
        if inspectedLiveEffectID != nil { liveEffects.endStrobeAudition() }
        inspectedLiveEffectID = id
        splitProjection = nil
    }
    private var spatialSave: Task<Void, Never>?
    func adjustOpticalEffect(_ values: [String: Double], id: UUID) {
        guard !hasActiveTake, let index = videoEffects.firstIndex(where: { $0.id == id }) else { return }
        var effect = videoEffects[index]
        for (key, value) in values { effect.set(key, .number(value)) }
        guard effect != videoEffects[index] else { return }
        videoEffects[index] = effect
        liveEffects.adjustOpticalEffect(effect)
        spatialSave?.cancel()
        spatialSave = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let self, let data = try? JSONEncoder().encode(self.videoEffects) else { return }
            UserDefaults.standard.set(data, forKey: "liveVideoEffects")
        }
    }
    func previewStrobe(_ id: UUID) { liveEffects.previewStrobe(id) }
    func beginEffectBackgroundPosition(_ id:UUID) async {
        guard !hasActiveTake,let effect=videoEffects.first(where:{$0.id==id}),case .media(let name)=effect.value("media",at:0),let name else {return}
        cancelEffectFrameTools();let operation=UUID();effectFrameToolToken=operation
        do {
            let size=try await VideoEffectBackgroundMedia.size(at:LiveVideoEffects.folder.appendingPathComponent(name))
            guard effectFrameToolToken==operation,!hasActiveTake,videoEffects.contains(effect) else {return}
            guard effectFrameSize.width>0,effectFrameSize.height>0 else {warning="Wait for the camera preview, then try positioning again.";return}
            let placement=VideoEffectBackgroundPlacement(x:effect.number("backgroundX"),y:effect.number("backgroundY"),zoom:effect.number("backgroundZoom"),canvas:effectFrameSize,media:size,fill:effect.choice("fit") != "Fit")
            effectBackgroundPlacement=placement;effectBackgroundPending=placement;positionDraft=effect;positioningEffectID=id
            queue.async {self.stopDolly(immediate:false,reason:"Position the background");self.cancelZoomTransition()}
            liveEffects.positionEffect(effect)
            UIAccessibility.post(notification:.announcement,argument:"Positioning background. Drag to move, pinch to scale.")
        } catch {warning=error.localizedDescription}
    }
    func moveEffectBackground(_ gesture:VideoEffectPlacementGesture) {
        guard !hasActiveTake,var placement=effectBackgroundPending,var effect=positionDraft else {return}
        placement.apply(gesture);effectBackgroundPending=placement
        let now=ProcessInfo.processInfo.systemUptime
        if case .ended=gesture {} else if now-effectBackgroundAt<1.0/30 {return}
        effectBackgroundAt=now;effectBackgroundPlacement=placement
        effect.set("backgroundX",.number(placement.x));effect.set("backgroundY",.number(placement.y));effect.set("backgroundZoom",.number(placement.zoom))
        positionDraft=effect;liveEffects.positionEffect(effect)
    }
    func resetEffectBackgroundPosition() {
        guard var placement=effectBackgroundPending else {return}
        placement.x=0.5;placement.y=0.5;placement.zoom=1;effectBackgroundPending=placement;moveEffectBackground(.ended)
    }
    func finishEffectPosition(revert:Bool=false) {
        guard positioningEffectID != nil else {return}
        if !revert {moveEffectBackground(.ended)}
        let draft=positionDraft
        effectFrameToolToken=nil;positioningEffectID=nil;splitProjection=nil;effectBackgroundPlacement=nil;effectBackgroundPending=nil;positionDraft=nil
        liveEffects.cancelFrameTools()
        if !revert,let draft,let index=videoEffects.firstIndex(where:{$0.id==draft.id}) {
            var effects=videoEffects;effects[index]=draft;setVideoEffects(effects)
        }
    }
    func sampleEffectPalette(_ id:UUID,save:Bool=false) {
        guard !hasActiveTake else {return}
        cancelEffectFrameTools();let token=UUID();effectFrameToolToken=token;effectPaletteSampling=id
        liveEffects.samplePalette(id,save:save,token:token)
        plateTimeout=Task { @MainActor [weak self] in
            do {try await Task.sleep(for:.seconds(6));try Task.checkCancellation()} catch {return}
            guard let self,self.effectFrameToolToken==token else {return}
            self.cancelEffectFrameTools();self.warning="The palette could not be sampled. Try again when the camera preview is visible."
        }
    }
    func beginEffectColorPick(_ id:UUID,parameter:String) {
        guard !hasActiveTake else { return }
        cancelEffectFrameTools()
        let token=UUID();effectFrameToolToken=token
        effectColorPick=id;colorPickParameter=parameter;liveEffects.beginColorPick(id,token:token)
        queue.async { self.stopDolly(immediate:false,reason:"Choose the color") }
    }
    func pickEffectColor(_ point:CGPoint) { liveEffects.pickColor(at:point) }
    func captureCleanPlate(_ id:UUID) {
        guard !hasActiveTake else { return }
        cancelEffectFrameTools();let token=UUID();effectFrameToolToken=token;cleanPlateProgress=0;cleanPlateCountdown=3
        queue.async { self.cancelZoomTransition() }
        plateCountdownTask=Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                for remaining in (1...3).reversed() { self.cleanPlateCountdown=remaining;try await Task.sleep(for:.seconds(1));try Task.checkCancellation() }
                guard !self.hasActiveTake else { self.cancelEffectFrameTools();return }
                self.plateCountdownTask=nil;self.cleanPlateCountdown=nil;self.liveEffects.capturePlate(for:id,token:token)
                self.plateTimeout=Task { @MainActor [weak self] in
                    do { try await Task.sleep(for:.seconds(6));try Task.checkCancellation() } catch { return }
                    guard let self,self.effectFrameToolToken==token else { return }
                    self.cancelEffectFrameTools();self.error="No camera frames arrived. Try capturing the empty screen again."
                }
            } catch { }
        }
    }
    func cancelEffectFrameTools() {
        finishEffectPosition()
        effectFrameToolToken=nil;plateTimeout?.cancel();plateTimeout=nil
        plateCountdownTask?.cancel();plateCountdownTask=nil;cleanPlateCountdown=nil
        effectColorPick=nil;effectPaletteSampling=nil;cleanPlateProgress=nil;liveEffects.cancelFrameTools()
    }
    private var effectFrameAngle: CGFloat = 0
    private var effectFrameMirrored = false
    let readings = CaptureReadings()
    let session = AVCaptureSession()
    var onSegment: ((URL, @escaping (Bool) -> Void) -> Void)?
    var busy: Bool { state == .starting || state == .saving }
    var hasActiveTake: Bool { state == .recording || busy }

    private let queue = DispatchQueue(label: "yourec.capture")
    private let movie = CaptureSegmentWriter()
    private let microphoneEngine = LiveMicrophone()
    private let meterLock = NSLock()
    private var lastAudioAt = -Double.infinity
    private var lastClipAt = -Double.infinity
    private var measuredPeak: Float = -160
    private var restartAfterFailure = false
    private var previewResetPending = false
    private var previewRecoveryID: UUID?
    private var previewRecoveryExhausted = false
    private var configuredColorSpace: AVCaptureColorSpace = .sRGB
    private static let previewRecoveryMessage = "The camera could not restart. Leave the camera screen and open it again."
    // RotationCoordinator and preview-layer references are used only on main.
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationPool: [String: AVCaptureDevice.RotationCoordinator] = [:]
    private var frozenAngles: [String: (capture: CGFloat, preview: CGFloat)] = [:]
    private var changingCamera = false
    private var dynamicChangeID: UUID?
    #if DEBUG
    private var rejectNextSwitch = false
    private var lastFinishError = ""
    private var zoomEndGap = 0.0
    private var syntheticDollyProbe=false
    #endif
    private var rotationObservations: [NSKeyValueObservation] = []
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private weak var previewView: CameraPreview.Preview?
    private let previewFrames = PreviewFrameStore()
    private var lastFrontCameraID = UserDefaults.standard.string(forKey: "lastFrontCamera")
    private var lastRearCameraID = UserDefaults.standard.string(forKey: "lastRearCamera")
    private(set) var interfaceOrientation: UIInterfaceOrientation = .portrait
    private var input: AVCaptureDeviceInput?
    private var devices: [AVCaptureDevice] = []
    private var selectedQuality = CaptureQuality(rawValue: UserDefaults.standard.string(forKey: "captureQuality") ?? "") ?? .hd1080
    private var configured = false
    private var configuring = false
    private var next: Next = .stop
    private var directory: URL?
    private var recordingProjectID: UUID?
    private var takeDestination = TakeReceipt.Destination.append
    private var takeID = UUID()
    private var segmentSequence = 0
    private var recordingFile: URL?
    private var storageSample = (time: 0.0, bytes: Int64(0))
    private var bytesPerSecond = 0.0
    private var activeMicID = ""
    private var microphoneRoute = RecordingMicrophoneRoute()
    private var microphoneRouteCheck: DispatchWorkItem?
    private var captureActive = false {
        didSet {
            guard oldValue != captureActive else { return }
            syncAlertProtection()
        }
    }
    private var microphoneRetry: DispatchWorkItem?
    private var recoveringMic = false
    private var lastMicIssue: String?
    private var micRecoveryStarted = 0.0

    private var captureRequestedAt = 0.0
    private var retainMicrophone = false
    private var takeHasMedia = false
    private var requestedStop = false
    private var explicitStopRequested: Bool { if case .stop = next { return requestedStop }; return false }
    private var finalizing = false
    private var wantsPreview = true
    private var preferredAngle: CGFloat = 90
    private var landscapeFrontEnabled = false
    private var captureCanvas: CGSize?
    private var deliveredCanvas: CGSize?
    private var observedPreview: PreviewGeometry? // Accessed only on the serial video output queue.
    private var landscapePreviewAngle: CGFloat = 0
    private var meter: DispatchSourceTimer?
    private var zoomTimer: DispatchSourceTimer?
    private var zoomTransition: (deviceID: String, curve: ZoomTransition)?
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        singleFollow.onStatus = { [weak self] status in self?.publish { $0.singleFollowStatus = status } }
        singleFollow.onSettledOff = { [weak self] in
            self?.queue.async {
                guard let self, self.followZoom == nil, !UserDefaults.standard.bool(forKey: "dualFaceFollow") else { return }
                self.followPreviewRequired = false
                self.refreshFramePreview()
            }
        }
        singleFollow.onLevelFailure = { [weak self] in
            self?.publish { $0.warning = "Level horizon is temporarily unavailable. Recording can continue." }
        }
        singleFollow.onFailure = { [weak self] lens in
            self?.queue.async {
                guard let self, !self.dualEnabled, let device = self.input?.device, device.uniqueID == lens else { return }
                // We cannot compensate a hardware ramp if this format can no longer
                // be resampled. Restore the selected framing on the lens itself.
                let wasManual = self.manualCenter != nil
                do {
                    try device.lockForConfiguration()
                    let selected = self.selectedZoom(device)
                    device.cancelVideoZoomRamp(); device.videoZoomFactor = selected
                    self.followZoom = nil; self.manualCenter = nil; self.manualInputZoom = nil; device.unlockForConfiguration()
                    self.saveCameraSettings()
                    self.recordZoom(device)
                } catch { self.publish { $0.error = error.localizedDescription } }
                self.followPreviewRequired = false; self.refreshFramePreview()
                UserDefaults.standard.set(false, forKey: "dualFaceFollow")
                self.publish {
                    $0.manualFramePreview = false
                    $0.faceFollowEnabled = false
                    $0.warning = wasManual ? "Panning is unavailable for this camera format." : "Face following is unavailable for this camera format."
                }
            }
        }
        liveEffects.onFrame = { [weak self] image, angle, mirrored, leases, geometry, target, cameraID, presentation in
            guard let self,let view=self.previewView else { return }
            if let image,self.effectFrameSize != image.extent.size {
                self.effectFrameSize=image.extent.size
                if let value=self.effectBackgroundPending {
                    let changed=VideoEffectBackgroundPlacement(x:value.x,y:value.y,zoom:value.zoom,canvas:image.extent.size,media:value.media,fill:value.fill)
                    self.effectBackgroundPending=changed;self.effectBackgroundPlacement=changed
                }
            }
            view.effectsView?.effectTransform=geometry
            view.effectsView?.sensorTransform = self.liveEffects.displayedSensorTransform
            view.effectsView?.show(image,angle:angle,mirrored:mirrored,leases:leases,cameraID:cameraID,nativeOverlay:presentation != .effects, zoomDeadline: self.liveEffects.displayedZoomDeadline)
            if self.showsOpticalInspector, let surface = view.effectsView {
                let projection = surface.frameProjection(in: surface.bounds)
                if self.splitProjection != projection { self.splitProjection = projection }
            }
            view.showAssistedFrame(presentation == .assistedCapture ? image?.pixelBuffer : nil, angle: angle, mirrored: mirrored, cameraID: cameraID, zoomDeadline: self.liveEffects.displayedZoomDeadline)
            view.showTarget(target)
        }
        liveEffects.onCrashState = { [weak self] state in self?.crashState=state }
        liveEffects.onPalettePicked = { [weak self] token,id,palette,save in
            guard let self,self.effectFrameToolToken==token,self.effectPaletteSampling==id,!self.hasActiveTake,
                  let index=self.videoEffects.firstIndex(where:{$0.id==id}),Int(self.videoEffects[index].number("colors"))==palette.colors.count else {return}
            var effects=self.videoEffects;effects[index].lockedPalette=palette;effects[index].set("lockPalette",.toggle(true))
            if save {effects[index].palette=palette.colors;effects[index].set("palette",.choice("Saved"))}
            self.cancelEffectFrameTools();self.setVideoEffects(effects)
        }
        liveEffects.onColorPicked = { [weak self] token,id,color in
            guard let self,self.effectFrameToolToken==token,self.effectColorPick==id,!self.hasActiveTake,
                  let index=self.videoEffects.firstIndex(where:{$0.id==id}) else { return }
            if self.colorPickParameter=="screenColor",!ChromaScreen.accepts(color) {
                self.cancelEffectFrameTools();self.warning=ChromaScreen.invalidSample;return
            }
            if self.videoEffects[index].kind == .colorIsolation,self.colorPickParameter=="color",!IsolationHue.accepts(color) {
                self.cancelEffectFrameTools();self.warning=IsolationHue.invalidSample;return
            }
            var effects=self.videoEffects;effects[index].set(self.colorPickParameter,.color(color))
            if self.colorPickParameter=="screenColor" { effects[index].set("autoScreen",.toggle(false));effects[index].set("screenType",.choice("Auto")) }
            self.effectFrameToolToken=nil;self.effectColorPick=nil;self.setVideoEffects(effects)
        }
        liveEffects.onFrameToolFailed = { [weak self] token,message in
            guard let self,self.effectFrameToolToken==token else { return }
            self.cancelEffectFrameTools();self.warning=message
        }
        liveEffects.onPlateProgress = { [weak self] token,progress in
            guard let self,self.effectFrameToolToken==token,self.plateCountdownTask==nil else { return }
            if let progress { self.cleanPlateProgress=progress } else { self.cancelEffectFrameTools() }
        }
        liveEffects.onPlateReady = { [weak self] token,id,name in
            guard let self,self.effectFrameToolToken==token,!self.hasActiveTake,let index=self.videoEffects.firstIndex(where:{$0.id==id}) else {
                try? FileManager.default.removeItem(at:LiveVideoEffects.folder.appendingPathComponent(name));return
            }
            self.plateTimeout?.cancel();self.plateTimeout=nil;self.effectFrameToolToken=nil;self.cleanPlateProgress=nil
            var effects=self.videoEffects;effects[index].set("cleanPlate",.media(name));self.setVideoEffects(effects)
        }
        liveEffects.onSubject = { [weak self] subject in self?.trackedSubject=subject }
        liveEffects.onTrackingMeasurement = { [weak self] subject,stamp in
            self?.queue.async { self?.acceptDollyMeasurement(subject,stamp:stamp) }
        }
        liveEffects.onQualityChange = { [weak self] message,thermal in self?.effectQualityMessage=message;self?.effectThermalWarning=thermal }
        liveEffects.onNotice = { [weak self] notice in self?.warning = notice }
        liveEffects.configure(videoEffects)
        movie.onVideoSample = { [weak self] pixel, time in
            guard let self else { return }
            self.recordingEffects.submit(pixel,time:time,recording:true,angle:self.effectFrameAngle,mirrored:self.effectFrameMirrored,cameraStamp:self.effectCameraStamp,sourceCameraID:self.effectSourceCameraID,
                                         sensorTransform: self.mediaDualActive ? .identity : self.singleFollow.sensorTransform)
            if self.mediaDualActive, let preview = self.dualPreviewPixel {
                self.liveEffects.submit(preview,time:time,recording:false,angle:self.effectFrameAngle,mirrored:false,sourceCameraID:"dual",displayTime:time)
            }
        }
        movie.onStart = { [weak self] url in self?.recordingStarted(url) }
        movie.onCanvas = { [weak self] size in
            self?.queue.async {
                guard let self else { return }
                self.captureCanvas = size
                self.refreshFramePreview()
                self.publish { $0.takeCanvas = size }
            }
        }
        movie.onFinish = { [weak self] url, error in self?.recordingFinished(url, error: error) }
        movie.onEmpty = { [weak self] in
            self?.recordingEffects.finishRecording(discard:true,{})
            self?.queue.async {
                guard let self else { return }
                self.captureActive = false; self.finalizing = false
                let paused = self.takeHasMedia && { if case .pause = self.next { return true }; return false }()
                if !paused { self.retainMicrophone = false; self.microphoneRoute = RecordingMicrophoneRoute(); self.clearTakeCanvas() }
                self.publish { $0.state = paused ? .paused : .idle; $0.startedAt = nil }
                if !self.wantsPreview { self.stopSession() }
                else if self.restartAfterFailure { self.restartAfterFailure = false; self.configure() }
                else { self.refreshMicrophones() }
            }
        }
        // Ordinary camera holds are saved as editor events, without a banner
        // interrupting the shot. Microphone/storage failures still warn here.
        movie.onUnexpectedVideoGap = { [weak self] gap in
            self?.publish { $0.warning = String(format: "Video paused for %.2f s. Review this take in the editor.", gap) }
        }
        dualCapture.onFrame = { [weak self] sample, preview in
            guard let self, self.mediaDualActive else { return }
            self.dualPreviewPixel = preview
            self.effectCameraStamp = nil; self.effectSourceCameraID = "dual"
            self.effectFrameAngle = self.dualCapture.frameAngle; self.effectFrameMirrored = false
            self.previewFrames.store(preview, angle: self.effectFrameAngle, mirrored: false)
            self.meterLock.lock(); self.dualLastFrame = ProcessInfo.processInfo.systemUptime; self.meterLock.unlock()
            if !self.movie.isRecording { self.liveEffects.submit(preview, time: sample.presentationTimeStamp.seconds, recording: false, angle: self.effectFrameAngle, mirrored: false, sourceCameraID: "dual", recordingReference: sample.imageBuffer) }
            self.movie.appendVideo(sample)
            self.dualPreviewPixel = nil
        }
        dualRecordingEffects.onNotice = { [weak self] message in self?.warning = message }
        dualCapture.onFollowFraming = { [weak self] framing in
            self?.publish { if $0.faceFollowEnabled && $0.dualFollowFraming != framing { $0.dualFollowFraming = framing } }
        }
        dualCapture.onFailure = { [weak self] message in
            self?.stop(pause: true)
            self?.publish { $0.warning = message; $0.ready = false }
        }
        microphoneEngine.onSample = { [weak self] sample in
            guard let self else { return }
            self.movie.queue.async { self.processMicrophoneSample(sample.sample) }
        }
        observers.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { [weak self] note in
            let changed = note.object as? AVAudioEngine
            self?.queue.async {
                guard let self, self.microphoneEngine.owns(changed) else { return }
                self.scheduleMicrophoneRefresh()
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .began { self?.stop(pause: true) }
            else { self?.queue.async { if self?.wantsPreview == true { self?.configure() } } }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let previous = note.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
            let previousIDs = previous?.inputs.map(\.uid) ?? []
            self?.queue.async {
                if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                    self?.microphoneRoute.deviceDisconnected(previousInputs: previousIDs)
                }
                self?.scheduleMicrophoneRefresh()
            }
        })
        for name in [AVCaptureSession.wasInterruptedNotification, AVCaptureSession.runtimeErrorNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                let failure = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
                let interruptedSession = note.object as? AVCaptureSession
                self?.queue.async {
                    guard let self, self.configured, interruptedSession === self.activeSession else { return }
                    #if DEBUG
                    self.traceCaptureFailure(note.userInfo?[AVCaptureSessionErrorKey] as? NSError, event: name.rawValue)
                    #endif
                    // Preview interruptions lose no footage. Check the capture
                    // queue's take state before stopping, not the delayed UI state.
                    let interruptedTake = self.captureActive || self.movie.isRecording
                    let reset = failure?.domain == AVFoundationErrorDomain && failure?.code == AVError.mediaServicesWereReset.rawValue
                    if reset {
                        self.previewResetPending = true
                        if !interruptedTake && !self.finalizing {
                            // An idle reset has lost no footage. Recover and
                            // confirm fresh frames before showing a failure.
                            self.recoverPreviewAfterReset()
                            return
                        }
                    }
                    let warning = reset && interruptedTake
                        ? "Camera services restarted. Recording paused; review the last take."
                        : failure?.localizedDescription ?? (interruptedTake ? "Capture was interrupted. Resume when ready." : nil)
                    self.saveCameraSettings()
                    self.cancelZoomTransition()
                    if !self.finalizing && !self.explicitStopRequested {
                        self.next = .pause
                        self.requestedStop = true
                    }
                    if name == AVCaptureSession.runtimeErrorNotification { self.restartAfterFailure = true }
                    if self.movie.isRecording { self.movie.stopRecording() }
                    self.publish {
                        $0.cancelEffectFrameTools()
                        if let warning { $0.warning = warning }
                        $0.ready = false
                    }
                    if self.restartAfterFailure && !self.captureActive && !self.finalizing && self.wantsPreview {
                        self.restartAfterFailure = false
                        self.configure()
                    }
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: nil, queue: nil) { [weak self] note in
            let interruptedSession = note.object as? AVCaptureSession
            self?.queue.async {
                guard let self, interruptedSession === self.activeSession else { return }
                // Resume through the owner: starting the native session alone
                // leaves the dual compositor inactive after background stop().
                if self.wantsPreview { self.configure() }
            }
        })
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver); meter?.cancel(); zoomTimer?.cancel() }
    private func publish(_ body: @escaping (CaptureController) -> Void) { DispatchQueue.main.async { body(self) } }

    #if DEBUG && targetEnvironment(simulator)
    private var recorderControlFixture: Bool { CommandLine.arguments.contains("--recorder-controls-test") }
    private var fixtureZooms: [String: Double] = [:]
    private var fixtureZoomRamp: ZoomTransition?
    private func refreshFixtureMicrophone() {
        let route = microphoneRoute.resolve(ranked: microphones.map(\.id), actual: microphoneID,
            preferred: microphoneID, inTake: hasActiveTake, now: ProcessInfo.processInfo.systemUptime)
        if let choice = microphones.first(where: { $0.id == route.request }) {
            microphoneID = choice.id
            microphoneName = choice.name
        }
    }
    private func prepareRecorderControlFixture() {
        let widePreview = CommandLine.arguments.contains("--front-landscape-preview-test")
        let turnFixture = CommandLine.arguments.contains("--interface-turn-fixture")
        let picture = widePreview || turnFixture ? Self.framingFixture() : nil
        let fixtureSize = picture.map { CGSize(width: CVPixelBufferGetWidth($0), height: CVPixelBufferGetHeight($0)) }
        queue.async {
            // The fixture keeps its simulated camera and meter when visiting Projects.
            // Mirror a real session becoming ready again when the recorder reopens.
            if self.meter != nil {
                self.publish { $0.ready = true }
                return
            }
            self.publish {
                $0.cameras = [CameraChoice(id: "fixture-wide", name: "Rear wide", front: false),
                              CameraChoice(id: "fixture-front", name: "Front", front: true),
                              CameraChoice(id: "fixture-front-wide", name: widePreview ? "Front ultrawide" : "Front wide", front: true, supportsLandscape: widePreview),
                              CameraChoice(id: "fixture-tele", name: "Rear telephoto", front: false)]
                $0.cameraID = "fixture-wide"; $0.ready = true; $0.maxZoom = 8
                $0.configureFixtureAperture(reset: CommandLine.arguments.contains("--reset-aperture-fixture"))
                $0.singleStabilizationSupported = true; $0.singleStabilizationActive = $0.stabilizationEnabled
                $0.hdrSupported = true; $0.hdrActive = $0.hdrEnabled; $0.logSupported = false
                $0.rememberCamera("fixture-wide", front: false)
                $0.microphoneID = "fixture-mic"; $0.microphoneName = "Built-In Microphone"
                $0.microphones = [MicrophoneChoice(id: "fixture-mic", name: "Built-In Microphone"),
                                  MicrophoneChoice(id: "fixture-wireless", name: "Wireless test mic")]
                $0.meterAvailable = true; $0.focusLockSupported = true; $0.focusAdjustable = true; $0.autofocusSupported = true
                if CommandLine.arguments.contains("--fixed-focus-fixture") {
                    $0.autofocusSupported = false; $0.focusAdjustable = false; $0.focusLockSupported = true
                }
                if turnFixture {
                    $0.rotationAngle = 0
                    $0.liveEffects.requireFramePreview(true)
                }
                if widePreview {
                    $0.cameraID = "fixture-front-wide"; $0.frontLandscapeSupported = true
                    $0.previewRotationAngle = 0; $0.rotationAngle = 0; $0.mirrorPreview = false
                    $0.setVideoEffects([])
                }
            }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(50))
            timer.setEventHandler { [weak self] in
                if let self, let picture {
                    self.previewFrames.store(picture, angle: 0)
                    self.liveEffects.submit(picture, time: ProcessInfo.processInfo.systemUptime, recording: false, angle: 0, mirrored: false)
                }
                self?.publish {
                    if let fixtureSize {
                        // The wide fixture bypasses captureOutput. Supply the same
                        // delivered geometry while its simulated lens is selected.
                        let canvas = $0.frontLandscape || turnFixture ? fixtureSize : nil
                        if $0.previewCanvas != canvas { $0.previewCanvas = canvas }
                    }
                    // Reproduce capture's frequent publication while a menu is open.
                    var zoom = $0.readings.zoom
                    if let ramp = $0.fixtureZoomRamp {
                        let now = ProcessInfo.processInfo.systemUptime
                        zoom = ramp.value(at: now)
                        if let center = ramp.center(at: now) { $0.probePanCenter = center }
                        if ramp.isFinished(at: now) { $0.fixtureZoomRamp = nil }
                    }
                    $0.readings.update(zoom: zoom, focusLocked: $0.readings.focusLocked,
                        lensPosition: $0.readings.focusLocked ? $0.readings.lensPosition : Float(0.5 + 0.2 * sin(ProcessInfo.processInfo.systemUptime * 2)),
                        level: Float(-35 + 15 * sin(ProcessInfo.processInfo.systemUptime * 4)),
                        audioArriving: true, audioClipping: false)
                }
            }
            self.meter = timer; timer.resume()
        }
    }
    private static func framingFixture() -> CVPixelBuffer? {
        let size = CGSize(width: 1280, height: 720)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(white: 0.16, alpha: 1).setFill(); context.fill(CGRect(origin: .zero, size: size))
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 64, height: 720))
            UIColor.blue.setFill(); context.fill(CGRect(x: 1216, y: 0, width: 64, height: 720))
            UIColor.green.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1280, height: 48))
            UIColor.yellow.setFill(); context.fill(CGRect(x: 0, y: 672, width: 1280, height: 48))
            let text = "LANDSCAPE 16:9\nENTIRE FRAME" as NSString
            let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
            text.draw(in: CGRect(x: 80, y: 280, width: 1120, height: 180), withAttributes: [
                .foregroundColor: UIColor.white, .font: UIFont.boldSystemFont(ofSize: 60), .paragraphStyle: paragraph])
        }
        var pixel: CVPixelBuffer?
        guard let cg = image.cgImage, CVPixelBufferCreate(nil, 1280, 720, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel) == kCVReturnSuccess, let pixel else { return nil }
        CIContext().render(CIImage(cgImage: cg), to: pixel)
        return pixel
    }
    #endif

    func prepare() {
        #if DEBUG && targetEnvironment(simulator)
        if recorderControlFixture { prepareRecorderControlFixture(); return }
        #endif
        #if DEBUG
        if CommandLine.arguments.contains("--restore-development-backup") || CommandLine.arguments.contains("--diagnostics-cleanup") || CommandLine.arguments.contains(where: { $0.hasPrefix("--audio-") }) { return }
        #endif
        #if targetEnvironment(simulator)
        if CommandLine.arguments.contains("--layout-preview") { return }
        #endif
        queue.async {
            self.previewRecoveryExhausted = false
            if !self.wantsPreview && self.dualEnabled {
                self.meterLock.lock(); self.dualLastFrame = ProcessInfo.processInfo.systemUptime; self.meterLock.unlock()
                self.dualDeliveryWarned = false
            }
            self.wantsPreview = true; self.playbackRequested = false
        }
        Task {
            let video = await AVCaptureDevice.requestAccess(for: .video)
            let audio = await AVCaptureDevice.requestAccess(for: .audio)
            guard video && audio else {
                publish { $0.error = "Allow Camera and Microphone access in Settings to record." }
                return
            }
            queue.async { self.configure() }
        }
    }
    func setStabilization(_ enabled: Bool) {
        guard !hasActiveTake, !switchingCamera, !enabled || dualActive || singleStabilizationSupported else { return }
        stabilizationEnabled = enabled; UserDefaults.standard.set(enabled, forKey: "dualStabilization")
        dualStabilizationSummary = ""
        if dualActive { setTwoCameras(true, pairID: dualPairID); return }
        #if DEBUG && targetEnvironment(simulator)
        if recorderControlFixture { singleStabilizationActive = enabled; return }
        #endif
        queue.async { self.applySingleStabilization(); self.refreshFramePreview() }
    }
    func setHorizonEnabled(_ enabled: Bool) {
        guard !hasActiveTake, !switchingCamera, !enabled || (canLevelHorizon && horizonUsesRear) else { return }
        horizonEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "levelHorizon")
        queue.async { self.refreshFramePreview() }
    }
    func setHorizonDegrees(_ value: Double) {
        guard !hasActiveTake, !switchingCamera else { return }
        horizonDegrees = HorizonFraming.degrees(value)
        UserDefaults.standard.set(horizonDegrees, forKey: "levelHorizonDegrees")
        queue.async { self.refreshFramePreview() }
    }
    func previewHorizonAngle(_ enabled: Bool) {
        queue.async {
            self.previewLevelAngle = enabled && !self.captureActive && !self.finalizing
            self.refreshFramePreview()
        }
    }
    func setFaceFollow(_ enabled: Bool) {
        guard !busy, !switchingCamera else { return }
        let held = dualDisplayLayout
        faceFollowEnabled = enabled; UserDefaults.standard.set(enabled, forKey: "dualFaceFollow")
        dualFollowFraming = nil
        if dualActive { updateDualLayout(held) }
        else { queue.async { self.updateSingleFollow(enabled) } }
    }
    // Capture queue. Never replace the user's capture format to enable a camera assist.
    private func applySingleStabilization() {
        guard !dualEnabled, let device = input?.device, let connection = movie.connection(with: .video) else { return }
        let mode = connection.isVideoStabilizationSupported ? MultiCameraCapture.stabilizationMode(device.activeFormat) : .off
        singleStabilizing = mode != .off && UserDefaults.standard.bool(forKey: "dualStabilization")
        let preferred = singleStabilizing ? mode : .off
        if connection.isVideoStabilizationSupported && connection.preferredVideoStabilizationMode != preferred {
            connection.preferredVideoStabilizationMode = preferred
        }
        publish { $0.singleStabilizationSupported = mode != .off }
    }
    private func updateSingleFollow(_ enabled: Bool) {
        guard !dualEnabled, let device = input?.device else { return }
        if manualCenter != nil {
            if !enabled {
                movie.queue.async { self.singleFollow.setEnabled(false) }
                refreshFramePreview()
                return
            }
            manualCenter = nil; manualInputZoom = nil; saveCameraSettings()
            publish { $0.manualFramePreview = false }
            recordZoom(device)
        }
        let wasFollowing = followZoom?.lens == device.uniqueID && followZoom?.restoring == false
        if enabled != wasFollowing {
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                let selected = selectedZoom(device)
                followZoom = (device.uniqueID, selected, !enabled)
                handOffZoom(to: enabled ? device.minAvailableVideoZoomFactor : selected, on: device)
                recordZoom(device)
            } catch {
                publish { camera in
                    guard camera.faceFollowEnabled == enabled else { return }
                    camera.faceFollowEnabled = wasFollowing
                    UserDefaults.standard.set(wasFollowing, forKey: "dualFaceFollow")
                    camera.warning = error.localizedDescription
                }
                return
            }
        }
        if enabled { followPreviewRequired = true }
        movie.queue.async { self.singleFollow.setEnabled(enabled) }
        refreshFramePreview()
    }

    private func selectedZoom(_ device: AVCaptureDevice) -> CGFloat {
        if let followZoom, followZoom.lens == device.uniqueID { return followZoom.selected }
        return device.videoZoomFactor
    }
    // Called with the device configuration lock held. When following, the
    // full-width input stays on this lens and zoom changes move the viewport.
    private func applySelectedZoom(_ value: CGFloat, to device: AVCaptureDevice, duringPinch: Bool = false) {
        if let center = manualCenter {
            let minimum = device.minAvailableVideoZoomFactor
            let curve = zoomTransition?.curve
            let atMinimum = value <= minimum + 0.00001 && (curve?.target ?? value) <= minimum + 0.00001
            // The shrinking digital crop now covers the whole current input.
            // Continue the same move on the lens, without a second zoom ramp.
            let wideningToCenter = curve.map { $0.target < $0.start && $0.targetCenter == CameraFraming.middle } ?? false
            let reachedNativeInput = wideningToCenter && curve?.compensatesSensorSwitch != true && center == CameraFraming.middle
                && value <= (manualInputZoom ?? device.videoZoomFactor)
            // Keep one preview surface under the fingers at the limit. The
            // last touch commits the native view even if its zoom is identical.
            if (atMinimum && !duringPinch) || reachedNativeInput {
                manualCenter = nil; manualInputZoom = nil; followZoom = nil
                device.cancelVideoZoomRamp()
                followPreviewRequired = false; refreshFramePreview()
                publish { $0.manualFramePreview = false }
            } else {
                manualCenter = CameraFraming.clamped(center, fraction: device.minAvailableVideoZoomFactor / value)
            }
        }
        if var state = followZoom, state.lens == device.uniqueID {
            state.selected = value; followZoom = state
            if state.restoring { handOffZoom(to: value, on: device) }
        } else { device.videoZoomFactor = value }
    }
    private func handOffZoom(to target: CGFloat, on device: AVCaptureDevice, over duration: Double = 0.65) {
        device.cancelVideoZoomRamp()
        let stops = abs(log2(target / device.videoZoomFactor))
        if stops > 0.001 { device.ramp(toVideoZoomFactor: target, withRate: Float(stops / duration)) }
        else { device.videoZoomFactor = target }
    }
    func updateDualLayout(_ value: DualCameraLayout, manualPan: Bool = false) {
        if manualPan && faceFollowEnabled {
            faceFollowEnabled = false; dualFollowFraming = nil
            UserDefaults.standard.set(false, forKey: "dualFaceFollow")
        }
        var value = value; value.constrain(); dualLayout = value
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: "dualCameraLayout") }
        updateDualComposition()
    }
    private func updateDualComposition() {
        let layout = dualLayout, recorded = mirrorRecording, preview = mirrorPreview, follow = faceFollowEnabled
        queue.async { self.dualCapture.update(layout, recordingMirrored: recorded, previewMirrored: preview, followFace: follow) }
    }
    func setTwoCameras(_ enabled: Bool, pairID: String? = nil) {
        guard !hasActiveTake, !switchingCamera else { return }
        #if DEBUG && targetEnvironment(simulator)
        if recorderControlFixture {
            dualActive = enabled
            configureFixtureAperture()
            dualStabilizationSummary = stabilizationEnabled ? "Both cameras stabilized" : ""
            // Like a real dual composite, the fixture canvas is already upright.
            // Matching angles keep its aspect ratio when the take locks framing.
            previewRotationAngle = enabled ? interfaceOrientation.compositeVideoAngle : 90
            rotationAngle = previewRotationAngle
            previewCanvas = enabled && interfaceOrientation.isLandscape
                ? CGSize(width: 1920, height: 1080) : CGSize(width: 1080, height: 1920)
            return
        }
        #endif
        guard !enabled || !dualPairs.isEmpty else { warning = "This iPhone does not support two cameras at once."; return }
        let pair = dualPairs.first { $0.id == pairID } ?? dualPairs.first { $0.id == dualPairID } ?? dualPairs.first
        let orientation = interfaceOrientation
        switchingCamera = true
        cancelEffectFrameTools()
        let layout = dualDisplayLayout, recordMirror = mirrorRecording, previewMirror = mirrorPreview, follow = faceFollowEnabled, stabilize = stabilizationEnabled
        dualFollowFraming = nil
        queue.async {
            guard !self.captureActive, !self.finalizing, self.configured, self.wantsPreview else { self.publish { $0.switchingCamera = false }; return }
            self.stopDolly(immediate: true, reason: "Two cameras"); self.cancelZoomTransition(); self.saveCameraSettings()
            if self.session.isRunning { self.session.stopRunning() }
            self.dualCapture.shutdown()
            self.movie.queue.sync { self.mediaDualActive = false; self.singleFollow.reset() }
            self.dualEnabled = false
            do {
                if enabled, let pair {
                    try self.dualCapture.configure(pair: pair, orientation: orientation, canvas: self.captureCanvas, stabilize: stabilize)
                    self.dualCapture.update(layout, recordingMirrored: recordMirror, previewMirrored: previewMirror, followFace: follow)
                    self.dualEnabled = true; self.dualDeliveryWarned = false
                    self.movie.queue.sync { self.mediaDualActive = true }
                    self.refreshFramePreview()
                    self.meterLock.lock(); self.dualLastFrame = ProcessInfo.processInfo.systemUptime; self.meterLock.unlock()
                    self.dualCapture.start()
                    guard self.dualCapture.session.isRunning else { throw MultiCameraCapture.Failure("The two cameras could not start. Single-camera recording has been restored.") }
                    self.publish {
                        $0.dualActive = true; $0.dualPairID = pair.id; $0.frontLandscape = false; $0.previewRotationAngle = orientation.compositeVideoAngle; $0.rotationAngle = orientation.compositeVideoAngle
                        $0.previewCanvas = orientation.isLandscape ? CGSize(width: 1920, height: 1080) : CGSize(width: 1080, height: 1920)
                        $0.hdrActive = false; $0.activeLog = nil; $0.ready = true; $0.switchingCamera = false
                        $0.liveEffects.configure($0.activeEffects)
                        // The phone can turn while the second camera is starting.
                        if $0.interfaceOrientation != orientation { $0.setOrientation($0.interfaceOrientation) }
                    }
                    self.queue.asyncAfter(deadline: .now()+0.5) {
                        guard self.dualEnabled, self.dualCapture.pair?.id == pair.id else { return }
                        let summary = self.dualCapture.stabilizationSummary()
                        self.publish { $0.dualStabilizationSummary = stabilize ? summary : "" }
                    }
                } else { self.restoreSingleCamera() }
            } catch {
                self.dualCapture.shutdown(); self.dualEnabled = false
                self.movie.queue.sync { self.mediaDualActive = false }
                self.restoreSingleCamera()
                self.publish { $0.warning = error.localizedDescription }
            }
        }
    }
    private func restoreSingleCamera() {
        dualEnabled = false
        movie.queue.sync { mediaDualActive = false; observedPreview = nil }
        applyCameraSettings(); refreshFramePreview()
        session.startRunning()
        publish {
            $0.dualActive = false; $0.switchingCamera = false; $0.ready = self.session.isRunning
            $0.liveEffects.configure($0.videoEffects)
            $0.bindRotation(to: self.input!.device); $0.refreshRotation()
        }
    }
    #if DEBUG
    func probeDualImages(prefix: URL) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in queue.async {
            do { continuation.resume(returning: try self.dualCapture.probeImages(prefix: prefix)) }
            catch { continuation.resume(throwing: error) }
        } }
    }
    func probeDualMetrics() async -> [String: Any] {
        await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: self.dualCapture.metrics()) } }
    }
    #endif
    private func configure() {
        guard wantsPreview else { return }
        if previewResetPending { recoverPreviewAfterReset(); return }
        guard !configured else {
            do { try resumeSession() }
            catch { publish { $0.error = error.localizedDescription; $0.ready = false }; return }
            publish { $0.ready = self.activeSession.isRunning }
            return
        }
        guard !configuring else { return }
        configuring = true
        defer { configuring = false }
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .videoRecording, options: [.allowBluetoothHFP])
            try audioSession.setActive(true)
            try audioSession.setAllowHapticsAndSystemSoundsDuringRecording(true)
            devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera], mediaType: .video, position: .unspecified).devices
            guard let camera = devices.first(where: { $0.position == .back && $0.deviceType == .builtInWideAngleCamera }) ?? devices.first else { throw ProjectError.invalidMedia }
            let videoInput = try AVCaptureDeviceInput(device: camera)
            session.beginConfiguration()
            session.automaticallyConfiguresApplicationAudioSession = false
            session.automaticallyConfiguresCaptureDeviceForWideColor = false
            if session.canSetSessionPreset(selectedQuality.preset) { session.sessionPreset = selectedQuality.preset }
            guard session.canAddInput(videoInput) else { session.commitConfiguration(); throw ProjectError.invalidMedia }
            session.addInput(videoInput)
            if !camera.supportsSessionPreset(selectedQuality.preset) {
                selectedQuality = .hd1080; session.sessionPreset = .hd1920x1080
                UserDefaults.standard.set(CaptureQuality.hd1080.rawValue, forKey: "captureQuality")
                publish { $0.quality = .hd1080; $0.warning = "This camera uses 1080p for recording." }
            }
            guard session.canAddOutput(movie.videoOutput) else {
                session.removeInput(videoInput); session.commitConfiguration(); throw ProjectError.invalidMedia
            }
            session.addOutput(movie.videoOutput)
            movie.videoOutput.setSampleBufferDelegate(self, queue: movie.queue)
            input = videoInput
            session.commitConfiguration()
            configured = true
            let pairs = MultiCameraCapture.availablePairs()
            publish { $0.dualPairs = pairs }
            applyCameraSettings()
            session.startRunning()
            recoverMicrophone()
            publish {
                for device in self.devices {
                    $0.rotationPool[device.uniqueID] = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: $0.previewLayer)
                }
                $0.cameras = self.devices.map { device in
                    let side = device.position == .front ? "Front" : "Rear"
                    let lens = device.deviceType == .builtInUltraWideCamera ? "ultrawide" : device.deviceType == .builtInTelephotoCamera ? "tele" : "main"
                    return CameraChoice(id: device.uniqueID, name: "\(side) \(lens)", front: device.position == .front,
                        available: device.supportsSessionPreset(self.selectedQuality.preset), supportsLandscape: Self.supportsLandscape(device), lens: device.deviceType)
                }
                $0.ready = self.session.isRunning
            }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(50))
            timer.setEventHandler { [weak self] in self?.updateReadings() }
            meter = timer
            timer.resume()
        } catch { publish { $0.error = error.localizedDescription } }
    }

    private func resumeSession() throws {
        refreshFramePreview()
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playAndRecord, mode: .videoRecording, options: [.allowBluetoothHFP])
        try audio.setActive(true)
        try audio.setAllowHapticsAndSystemSoundsDuringRecording(true)
        if dualEnabled {
            if !dualCapture.isDelivering {
                meterLock.lock(); dualLastFrame = ProcessInfo.processInfo.systemUptime; meterLock.unlock()
                dualDeliveryWarned = false; dualCapture.start()
            }
        } else if !session.isRunning { session.startRunning() }
        recoverMicrophone()
    }

    private func recoverPreviewAfterReset() {
        guard wantsPreview, !captureActive, !finalizing, previewRecoveryID == nil, !previewRecoveryExhausted else { return }
        let token = UUID(); previewRecoveryID = token
        publish {
            $0.ready = false
            if $0.warning == Self.previewRecoveryMessage { $0.warning = nil }
        }
        queue.asyncAfter(deadline: .now() + 0.15) { self.restartPreview(token, attempt: 0) }
    }
    private func restartPreview(_ token: UUID, attempt: Int) {
        guard previewRecoveryID == token, wantsPreview, !captureActive, !finalizing else { return }
        let serial = previewFrames.frameSerial, began = ProcessInfo.processInfo.systemUptime
        if activeSession.isRunning { activeSession.stopRunning() }
        microphoneEngine.resetAfterMediaServicesReset()
        do { try resumeSession() }
        catch {
            #if DEBUG
            traceCaptureFailure(error as NSError, event: "preview-restart-attempt")
            #endif
        }
        checkPreviewRecovery(token, attempt: attempt, serial: serial, began: began)
    }
    private func checkPreviewRecovery(_ token: UUID, attempt: Int, serial: UInt64, began: Double) {
        guard previewRecoveryID == token, wantsPreview, !captureActive, !finalizing else { return }
        meterLock.lock(); let audioArrived = lastAudioAt > began; meterLock.unlock()
        let color = dualEnabled ? AVCaptureColorSpace.sRGB : configuredColorSpace
        if previewFrames.hasFreshFrames(after: serial, color: color), audioArrived, microphoneEngine.isRunning, activeSession.isRunning {
            previewRecoveryID = nil; previewResetPending = false
            #if DEBUG
            traceCaptureFailure(nil, event: "preview-recovered")
            #endif
            publish { $0.ready = true }
        } else if ProcessInfo.processInfo.systemUptime - began < 2 {
            queue.asyncAfter(deadline: .now() + 0.1) { self.checkPreviewRecovery(token, attempt: attempt, serial: serial, began: began) }
        } else if attempt == 0 {
            restartPreview(token, attempt: 1)
        } else {
            previewRecoveryID = nil; previewRecoveryExhausted = true
            #if DEBUG
            traceCaptureFailure(nil, event: "preview-recovery-failed")
            #endif
            publish { $0.ready = false; $0.warning = Self.previewRecoveryMessage }
        }
    }

    private var playbackRequested = false
    func suspend(forPlayback: Bool = false) {
        cancelEffectFrameTools()
        queue.async {
            self.wantsPreview = false
            self.previewRecoveryID = nil
            self.playbackRequested = forPlayback
            self.saveCameraSettings()
            self.cancelZoomTransition()
            if self.captureActive {
                if !self.explicitStopRequested { self.next = .pause }
                self.requestedStop = true
                self.publish { $0.state = .saving }
                if self.movie.isRecording { self.movie.stopRecording() }
            } else if !self.finalizing { self.stopSession() }
        }
    }
    private func stopSession() {
        saveCameraSettings()
        cancelZoomTransition()
        previewFrames.clear()
        publish { $0.previewView?.cancelFreeze() }
        movie.queue.async { self.horizon.configure(maximum: nil) }
        if dualEnabled { dualCapture.stop() }
        if session.isRunning { session.stopRunning() }
        microphoneRouteCheck?.cancel(); microphoneRouteCheck = nil
        microphoneRetry?.cancel(); microphoneRetry = nil; recoveringMic = false
        microphoneEngine.stop()
        let audio = AVAudioSession.sharedInstance()
        if playbackRequested {
            do {
                // Inactive→active transitions (Control Center/permission alerts)
                // must not tear down an already playing editor audio session.
                if audio.category != .playback || audio.mode != .moviePlayback {
                    try audio.setCategory(.playback, mode: .moviePlayback)
                }
                try audio.setActive(true)
                try audio.setAllowHapticsAndSystemSoundsDuringRecording(true)
            } catch { publish { $0.error = error.localizedDescription } }
        } else { try? audio.setActive(false, options: .notifyOthersOnDeactivation) }
        publish { $0.ready = false }
    }

    func setOrientation(_ orientation: UIInterfaceOrientation) {
        guard !hasActiveTake, state != .paused else { return }
        interfaceOrientation = orientation
        #if DEBUG && targetEnvironment(simulator)
        if CommandLine.arguments.contains("--interface-turn-fixture") {
            previewRotationAngle = orientation.compositeVideoAngle
            previewView?.orientPicture(to: previewRotationAngle, capture: rotationAngle)
            return
        }
        #endif
        if dualActive {
            previewRotationAngle = orientation.compositeVideoAngle
            previewView?.orientPicture(to: previewRotationAngle, capture: rotationAngle)
            queue.async {
                // A Record request may have reached the capture queue before
                // SwiftUI publishes Starting. Never rotate an already-started take.
                guard self.dualEnabled, !self.captureActive, !self.finalizing, !self.retainMicrophone else { return }
                self.dualCapture.orient(orientation)
                self.publish {
                    guard $0.dualActive, $0.interfaceOrientation == orientation else { return }
                    $0.rotationAngle = orientation.compositeVideoAngle
                    $0.previewCanvas = orientation.isLandscape ? CGSize(width: 1920, height: 1080) : CGSize(width: 1080, height: 1920)
                }
            }
        } else { refreshRotation() }
    }
    func rememberFramingOrientation(_ orientation: UIInterfaceOrientation) { interfaceOrientation = orientation }
    func attachPreview(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        for (id, coordinator) in rotationPool {
            if let device = coordinator.device { rotationPool[id] = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: layer) }
        }
        if let device = rotationCoordinator?.device { bindRotation(to: device) }
    }
    func attachPreviewView(_ view: CameraPreview.Preview) {
        previewView = view
        attachPreview(view.previewLayer)
        #if DEBUG
        if measuringPreviewRotation {
            view.effectsView?.probeDualPresentation = { [weak self] angle, time in
                guard let self, let turn = self.pendingDualTurn, angle == turn.angle, time >= turn.began else { return }
                self.dualTurnTimes.append(Int(((time - turn.began) * 1000).rounded()))
                self.pendingDualTurn = nil
                self.previewView?.accessibilityValue = self.previewTurnReport
            }
        }
        #endif
    }
    private func rememberCamera(_ id: String, front: Bool) {
        if front { lastFrontCameraID = id } else { lastRearCameraID = id }
        #if DEBUG && targetEnvironment(simulator)
        if recorderControlFixture { return }
        #endif
        UserDefaults.standard.set(id, forKey: front ? "lastFrontCamera" : "lastRearCamera")
    }
    var oppositeCamera: CameraChoice? {
        guard let current = cameras.first(where: { $0.id == cameraID }) else { return nil }
        let choices = cameras.filter { $0.front != current.front && $0.available }
        let remembered = current.front ? lastRearCameraID : lastFrontCameraID
        return choices.first(where: { $0.id == remembered }) ?? choices.first
    }
    func flipCamera() {
        guard !busy, !switchingCamera, let target = oppositeCamera else { return }
        switchCamera(target.id)
    }
    private func bindRotation(to device: AVCaptureDevice) {
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        if (hasActiveTake || state == .paused), let frozen = frozenAngles[device.uniqueID] {
            previewRotationAngle = frozen.preview
            queue.async {
                self.preferredAngle = frozen.capture
                self.applyConnectionRotation()
            }
        }
        rotationCoordinator = coordinator
        rotationObservations = [
            coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] source, _ in
                self?.updateHorizonPreview(from: source)
            },
            coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { [weak self] source, _ in
                self?.updateHorizonCapture(from: source)
            }
        ]
        refreshRotation()
    }
    private var followsHorizon: Bool { !dualActive && !hasActiveTake && state != .paused && !frontLandscape }
    fileprivate var displayedPreviewAngle: CGFloat {
        if followsHorizon, let rotationCoordinator { return rotationCoordinator.videoRotationAngleForHorizonLevelPreview }
        return previewRotationAngle
    }
    private func refreshRotation() {
        guard let coordinator = rotationCoordinator else { return }
        updateHorizonPreview(from: coordinator)
        updateHorizonCapture(from: coordinator)
    }
    private func updateHorizonPreview(from coordinator: AVCaptureDevice.RotationCoordinator) {
        guard followsHorizon, rotationCoordinator === coordinator else { return }
        let angle = coordinator.videoRotationAngleForHorizonLevelPreview
        // AVFoundation delivers preview-angle KVO on main. Apply it to the
        // actual picture in this callback, even if SwiftUI is busy relaying out.
        MainActor.assumeIsolated {
            #if DEBUG
            notePreviewRotationRequest(angle)
            #endif
            previewView?.orientPicture(to: angle, capture: rotationAngle)
            #if DEBUG
            notePreviewRotationApplied()
            #endif
        }
        // Attaching a preview layer can call us during makeUIView. Publish
        // the aspect-ratio change separately and discard superseded turns.
        if previewRotationAngle != angle {
            publish { camera in
                guard camera.followsHorizon, camera.rotationCoordinator === coordinator,
                      coordinator.videoRotationAngleForHorizonLevelPreview == angle,
                      camera.previewRotationAngle != angle else { return }
                camera.previewRotationAngle = angle
            }
        }
    }
    private func updateHorizonCapture(from coordinator: AVCaptureDevice.RotationCoordinator) {
        guard followsHorizon, rotationCoordinator === coordinator else { return }
        var captureAngle = coordinator.videoRotationAngleForHorizonLevelCapture
        #if DEBUG
        if let turns = probeGravityTurns {
            captureAngle = (coordinator.videoRotationAngleForHorizonLevelPreview + CGFloat(turns * 90)).truncatingRemainder(dividingBy: 360)
        } else if CommandLine.arguments.contains("--framing-locked-sideways") {
            captureAngle = (coordinator.videoRotationAngleForHorizonLevelPreview + 90).truncatingRemainder(dividingBy: 360)
        }
        #endif
        queue.async {
            guard !self.dualEnabled, !self.captureActive, !self.finalizing, !self.landscapeFrontEnabled else { return }
            self.preferredAngle = captureAngle
            self.applyConnectionRotation()
        }
    }
    private func applyConnectionRotation() {
        guard !dualEnabled else { return }
        if let connection = movie.connection(with: .video), connection.isVideoRotationAngleSupported(preferredAngle) {
            if connection.videoRotationAngle != preferredAngle { connection.videoRotationAngle = preferredAngle }
            if connection.isVideoMirroringSupported {
                if connection.automaticallyAdjustsVideoMirroring { connection.automaticallyAdjustsVideoMirroring = false }
                let mirrored = input?.device.position == .front && UserDefaults.standard.bool(forKey: "mirrorFrontRecording")
                if connection.isVideoMirrored != mirrored { connection.isVideoMirrored = mirrored }
            }
        }
        let applied = preferredAngle
        publish { if $0.rotationAngle != applied { $0.rotationAngle = applied } }
    }

    func start(in directory: URL, projectID: UUID? = nil, destination: TakeReceipt.Destination = .append) {
        #if DEBUG && targetEnvironment(simulator)
        // The control fixture tests public gestures and layout, not capture.
        if recorderControlFixture { state = .recording; startedAt = Date(); refreshFixtureMicrophone(); return }
        #endif
        finishEffectPosition(); cancelEffectFrameTools()
        if state != .paused && !hasActiveTake {
            frozenAngles = rotationPool.mapValues { ($0.videoRotationAngleForHorizonLevelCapture, $0.videoRotationAngleForHorizonLevelPreview) }
            if frontLandscape { frozenAngles[cameraID] = (rotationAngle, previewRotationAngle) }
        }
        let continuing = state == .paused
        queue.async {
            guard self.configured, self.activeSession.isRunning, !self.previewResetPending, !self.captureActive, !self.finalizing, !self.changingCamera else { return }
            if !continuing || self.directory != directory { self.takeID = UUID(); self.segmentSequence = 0 }
            self.recordingProjectID = projectID
            self.takeDestination = destination
            self.directory = directory
            self.beginSegment()
        }
    }
    func videoEffectMetrics() async -> [String:Double] {
        var metrics = await liveEffects.metrics()
        if dualActive { for (key, value) in await dualRecordingEffects.metrics() { metrics["record." + key] = value } }
        return metrics
    }
    func setVideoEffects(_ effects: [VideoEffectSettings]) {
        guard !hasActiveTake, effects.allSatisfy(\.valid) else { return }
        if effectPaletteSampling != nil {cancelEffectFrameTools()}
        let dollyChanged=videoEffects.first(where:{$0.kind == .dollyZoom}) != effects.first(where:{$0.kind == .dollyZoom})
        videoEffects = effects
        if let data = try? JSONEncoder().encode(effects) { UserDefaults.standard.set(data,forKey:"liveVideoEffects") }
        if dollyChanged { queue.async { self.stopDolly(immediate:false,reason:"Tap a face, then start") } }
        liveEffects.configure(activeEffects)
    }
    private func beginSegment() {
        guard let directory, wantsPreview, !activeSession.isInterrupted, activeSession.isRunning else {
            failedSegmentStart("Recording could not start. Check the camera and try again.", warning: true)
            return
        }
        if !microphoneEngine.isRunning { recoverMicrophone() }
        guard microphoneEngine.isRunning else {
            failedSegmentStart("Waiting for the microphone. Try Record when the meter is active.", warning: true)
            return
        }
        do {
            try RecoverySpace.require(selectedQuality == .ultraHD4K ? 170_000_000 : 75_000_000, at: directory)
        } catch { failedSegmentStart(error.localizedDescription); return }
        let segmentID = UUID()
        let filename = String(format: "%.0f", Date().timeIntervalSince1970 * 1000) + "-" + segmentID.uuidString + ".mov"
        let url = directory.appendingPathComponent(filename)
        #if DEBUG
        let safetyTest = ProcessInfo.processInfo.arguments.contains("--recording-safety-clock") && directory.pathComponents.contains("RecorderUITestProjects")
        if safetyTest {
            do { try RecoverySpace.require(256 * 1024 * 1024, at: directory) }
            catch { failedSegmentStart(error.localizedDescription); return }
            // Independent of the host connection. A failed fault-injection test
            // must never leave a real camera running on the user's phone.
            queue.asyncAfter(deadline: .now() + 20) { [weak self] in
                guard let self, self.recordingFile == url, self.captureActive else { return }
                self.next = .pause; self.requestedStop = true; self.movie.stopRecording()
            }
        }
        #endif
        if let recordingProjectID {
            do {
                try TakeReceipt.begin(movie: url, projectID: recordingProjectID, take: takeID, segment: segmentID,
                                      sequence: segmentSequence, destination: takeDestination)
                if case .placement = takeDestination { takeDestination = .savedInsertion }
            }
            catch { failedSegmentStart("Could not save the recording information. " + error.localizedDescription); return }
        }
        segmentSequence += 1
        recordingFile = url
        bytesPerSecond = selectedQuality == .ultraHD4K ? 7_000_000 : 2_000_000
        storageSample = (ProcessInfo.processInfo.systemUptime, 0)
        captureActive = true
        captureRequestedAt = ProcessInfo.processInfo.systemUptime
        retainMicrophone = true
        refreshMicrophones()
        requestedStop = false
        next = .stop
        applyConnectionRotation()
        publish { $0.state = .starting }
        let effects = dualEnabled ? videoEffects.filter { $0.kind != .dollyZoom && $0.kind != .crashZoom } : videoEffects
        let processor = dualEnabled ? dualRecordingEffects : liveEffects
        var recordedEffects = effects
        if dualEnabled {
            for i in recordedEffects.indices {
                if case .media(let name?) = effects[i].value("cleanPlate"),
                   let recorded = LiveVideoEffects.recordingPlateName(name),
                   FileManager.default.fileExists(atPath: LiveVideoEffects.folder.appendingPathComponent(recorded).path) {
                    recordedEffects[i].set("cleanPlate", .media(recorded))
                }
            }
            // Preview masks/palettes follow the mirrored display; saved analysis
            // must be computed from the actual writer pixels for correct export.
            processor.configure(recordedEffects)
            liveEffects.configure(effects)
        }
        movie.queue.sync { self.recordingEffects = processor }
        do { try processor.beginRecording(url, effects: recordedEffects) }
        catch {
            failedSegmentStart("The selected video effect assets could not be prepared. " + error.localizedDescription)
            return
        }
        movie.startRecording(to: url, canvas: captureCanvas)
        if dollyFollower != nil { movie.recordEvent("dollyStart","Dolly Zoom continuing from the preview") }
    }
    private func failedSegmentStart(_ message: String, warning: Bool = false) {
        captureActive = false; retainMicrophone = takeHasMedia
        let state: State = takeHasMedia ? .paused : .idle
        if !takeHasMedia { microphoneRoute = RecordingMicrophoneRoute(); clearTakeCanvas(); refreshMicrophones() }
        publish {
            $0.state = state; $0.startedAt = nil
            if warning { $0.warning = message } else { $0.error = message }
        }
    }
    func finishPausedTake() {
        #if DEBUG && targetEnvironment(simulator)
        if recorderControlFixture { state = .idle; startedAt = nil; microphoneRoute = RecordingMicrophoneRoute(); refreshFixtureMicrophone(); return }
        #endif
        queue.async {
            guard !self.captureActive, !self.finalizing else { return }
            self.retainMicrophone = false
            self.microphoneRoute = RecordingMicrophoneRoute()
            self.clearTakeCanvas()
            self.refreshMicrophones()
            self.publish { $0.state = .idle; $0.refreshRotation() }
        }
    }
    func stop(pause: Bool = false) {
        #if DEBUG && targetEnvironment(simulator)
        if recorderControlFixture {
            state = pause ? .paused : .idle; startedAt = nil
            if !pause { microphoneRoute = RecordingMicrophoneRoute() }
            refreshFixtureMicrophone()
            return
        }
        #endif
        queue.async {
            guard self.captureActive else { return }
            self.stopDolly(immediate:false,reason:pause ? "Move paused" : "Recording stopped")
            // Stop wins over an automatic pause from a call, route loss or
            // session interruption while the writer is finishing.
            if pause && self.explicitStopRequested { return }
            self.next = pause ? .pause : .stop
            self.requestedStop = true
            self.publish { $0.state = .saving }
            if self.movie.isRecording { self.movie.stopRecording() }
        }
    }
    var mainLensAtOneX: CameraChoice? {
        guard cameras.contains(where: { $0.id == cameraID && !$0.front && $0.lens == .builtInUltraWideCamera }) else { return nil }
        return cameras.first { !$0.front && $0.lens == .builtInWideAngleCamera && $0.available }
    }

    func switchCamera(_ id: String, landscape: Bool? = nil, nativeZoom: Bool = false) {
        guard !dualActive else { return }
        #if DEBUG && targetEnvironment(simulator)
        if recorderControlFixture {
            guard let choice = cameras.first(where: { $0.id == id && $0.available }) else { return }
            fixtureZooms[cameraID] = readings.zoom
            fixtureZoomRamp = nil
            cameraID = id
            configureFixtureAperture()
            frontLandscapeSupported = choice.supportsLandscape
            frontLandscape = landscape ?? false
            liveEffects.requireFramePreview(needsFramePreview, peaking: focusPeaking)
            rememberCamera(id, front: choice.front)
            readings.update(zoom: nativeZoom ? 1 : (fixtureZooms[id] ?? 1), focusLocked: readings.focusLocked,
                lensPosition: readings.lensPosition, level: readings.level, audioArriving: true, audioClipping: false)
            return
        }
        #endif
        let wantsLandscape = landscape ?? (id == cameraID && frontLandscape)
        let angle = (hasActiveTake || state == .paused) ? frozenAngles[id]?.capture : rotationPool[id]?.videoRotationAngleForHorizonLevelCapture
        let previewAngle = (hasActiveTake || state == .paused) ? frozenAngles[id]?.preview : rotationPool[id]?.videoRotationAngleForHorizonLevelPreview
        queue.async {
            guard !self.finalizing, !self.changingCamera,
                  self.input?.device.uniqueID != id || self.landscapeFrontEnabled != wantsLandscape else { return }
            if self.captureActive, let current = self.input?.device,
               current.activeColorSpace == .appleLog || current.activeColorSpace.rawValue == 4 {
                let width = self.selectedQuality == .ultraHD4K ? 3840 : 1920
                let compatible = self.devices.first(where: { $0.uniqueID == id })?.formats.contains { format in
                    CMVideoFormatDescriptionGetDimensions(format.formatDescription).width == width
                        && format.supportedColorSpaces.contains { $0 == .appleLog || $0.rawValue == 4 }
                        && format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }
                } ?? false
                guard compatible else {
                    self.publish { $0.warning = "This camera cannot record Log at this resolution. Pause and choose SDR or HDR before switching." }
                    return
                }
            }
            self.saveCameraSettings()
            self.cancelZoomTransition()
            self.changingCamera = true
            self.publish { controller in
                controller.switchingCamera = true
                let change: (Bool) -> Void = { prepared in
                    self.queue.async {
                        guard prepared, self.wantsPreview else {
                            self.changingCamera = false
                            self.publish { $0.previewView?.cancelFreeze(); $0.switchingCamera = false }
                            return
                        }
                        self.movie.holdVideo(true)
                        let resume = {
                            self.movie.holdVideo(false)
                            self.publish { controller in
                                let finish: (Bool) -> Void = { resumed in
                                    self.queue.async {
                                        self.changingCamera = false
                                        let failed = !resumed && self.wantsPreview
                                        self.publish {
                                            $0.switchingCamera = false
                                            if failed { $0.warning = "Camera preview did not resume. Try selecting another camera." }
                                        }
                                    }
                                }
                                if let preview = controller.previewView {
                                    preview.resume(angle: controller.previewRotationAngle, mirrored: controller.frontPreviewMirrored,
                                        framePreview: controller.needsFramePreview || controller.videoEffects.contains(where: \.enabled),
                                        cameraID: controller.cameraID, completion: finish)
                                    #if DEBUG
                                    if controller.failNextSwitchPreview {
                                        controller.failNextSwitchPreview = false
                                        controller.liveEffects.probeFailOnePlainPreview()
                                    }
                                    #endif
                                } else { finish(true) }
                            }
                        }
                        let frame = {
                            guard self.input?.device.uniqueID == id else { resume(); return }
                            self.configureFrontLandscape(wantsLandscape, captureAngle: angle ?? self.preferredAngle,
                                previewAngle: previewAngle ?? angle ?? self.preferredAngle, completion: resume)
                        }
                        if self.input?.device.uniqueID == id { frame() }
                        else { self.changeCamera(id, angle: angle, nativeZoom: nativeZoom, completion: frame) }
                    }
                }
                if let preview = controller.previewView {
                    preview.freeze(using: self.previewFrames, completion: change)
                } else { change(true) }
            }
        }
    }
    private func changeCamera(_ id: String, angle: CGFloat? = nil, nativeZoom: Bool = false, completion: (() -> Void)? = nil) {
        guard let device = devices.first(where: { $0.uniqueID == id }), let old = input else {
            if completion != nil { publish { $0.error = "The requested camera is unavailable." } }
            completion?()
            return
        }
        do {
            #if DEBUG
            if rejectNextSwitch { rejectNextSwitch = false; completion?(); return }
            #endif
            guard device.supportsSessionPreset(selectedQuality.preset) else {
                publish { $0.warning = "This camera does not support the selected quality. Stop the take and choose 1080p to use it." }
                completion?(); return
            }
            let replacement = try AVCaptureDeviceInput(device: device)
            saveCameraSettings()
            cancelZoomTransition()
            session.beginConfiguration()
            session.removeInput(old)
            guard session.canAddInput(replacement) else {
                session.addInput(old); session.commitConfiguration()
                publish { $0.error = "This camera is unavailable with the current capture settings." }
                completion?(); return
            }
            session.addInput(replacement)
            guard session.canSetSessionPreset(selectedQuality.preset) else {
                session.removeInput(replacement); session.addInput(old); session.commitConfiguration()
                publish { $0.error = "Choose a compatible recording quality before changing to this camera." }
                completion?(); return
            }
            session.sessionPreset = selectedQuality.preset
            input = replacement
            if let angle { preferredAngle = angle }
            movie.recordEvent("cameraSwitch", "Camera changed to " + device.localizedName)
            applyConnectionRotation()
            session.commitConfiguration()
            landscapeFrontEnabled = false
            applyCameraSettings(nativeZoom: nativeZoom, completion: completion)
            refreshMicrophones()
        } catch {
            movie.holdVideo(false); changingCamera = false
            publish { $0.error = error.localizedDescription; $0.switchingCamera = false }
            completion?()
        }
    }
    private func settingsKey(_ device: AVCaptureDevice) -> String { "camera." + device.uniqueID }
    private func saveCameraSettings() {
        guard !dualEnabled else { return }
        guard let device = input?.device else { return }
        var saved = UserDefaults.standard.dictionary(forKey: settingsKey(device)) ?? [:]
        let currentZoom = selectedZoom(device)
        if zoomTransition != nil || device.isRampingVideoZoom || saved["zoom"] == nil || currentZoom != lastSavedZoom {
            saved["zoom"] = Double(currentZoom)
        }
        storeCenter(in: &saved)
        saved["locked"] = manualFocus; saved["lens"] = Double(device.lensPosition)
        saved["aperture"] = manualAperture.map { Double($0) }
        UserDefaults.standard.set(saved, forKey: settingsKey(device))
    }
    private func storeCenter(in saved: inout [String: Any]) {
        saved["panX"] = manualCenter?.x
        saved["panY"] = manualCenter?.y
    }
    private func applyCameraSettings(nativeZoom: Bool = false, completion: (() -> Void)? = nil) {
        guard let device = input?.device else { return }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }) {
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            }
            let selectedMode = CaptureColorMode(rawValue: UserDefaults.standard.string(forKey: "captureColorMode") ?? "") ?? ((UserDefaults.standard.object(forKey: "captureHDR") as? Bool ?? true) ? .hdr : .sdr)
            let wantsHDR = selectedMode == .hdr
            let target = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            let compatible = device.formats.filter { format in
                let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                return size.width == target.width && size.height == target.height
                    && format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }
            }
            // Prefer the current format, then the closest sensor framing. Do
            // not choose an unrelated binned format just because it appears first.
            let current = device.activeFormat
            let ranked = compatible.sorted { a, b in
                func score(_ format: AVCaptureDevice.Format) -> Double {
                    if format == current { return -1 }
                    return abs(Double(format.videoFieldOfView - current.videoFieldOfView))
                        + (format.isVideoBinned == current.isVideoBinned ? 0 : 100)
                }
                return score(a) < score(b)
            }
            let hdrFormat = ranked.first { $0.supportedColorSpaces.contains(.HLG_BT2020) }
            let sdrFormat = ranked.first { $0.supportedColorSpaces.contains(.sRGB) }
            let logFormats: [AVCaptureDevice.Format]
            if #available(iOS 17.2, *) { logFormats = landscapeFrontEnabled ? [device.activeFormat] : ranked }
            else { logFormats = [] } // Native Log metadata became public in 17.2.
            var logSpace: AVCaptureColorSpace = .appleLog
            if #available(iOS 26, *), logFormats.contains(where: { $0.supportedColorSpaces.contains(.appleLog2) }) { logSpace = .appleLog2 }
            let logFormat = logFormats.first { $0.supportedColorSpaces.contains(logSpace) }
            if !landscapeFrontEnabled, let format = selectedMode == .log ? (logFormat ?? sdrFormat) : wantsHDR ? (hdrFormat ?? sdrFormat) : sdrFormat { device.activeFormat = format }
            let desired: AVCaptureColorSpace = selectedMode == .log && logFormat != nil && device.activeFormat.supportedColorSpaces.contains(logSpace) ? logSpace : wantsHDR && device.activeFormat.supportedColorSpaces.contains(.HLG_BT2020) ? .HLG_BT2020 : .sRGB
            if device.activeFormat.supportedColorSpaces.contains(desired) { device.activeColorSpace = desired }
            else { publish { $0.warning = "This framing cannot change dynamic range. Turn off landscape selfie to change HDR." } }
            let hdr = device.activeColorSpace == .HLG_BT2020
            let log = device.activeColorSpace == .appleLog || device.activeColorSpace.rawValue == 4
            configuredColorSpace = device.activeColorSpace
            // EDR (sensor processing) is distinct from 10-bit HLG. Let the
            // camera use its normal processing when recording SDR as well.
            device.automaticallyAdjustsVideoHDREnabled = !log
            if log, device.activeFormat.isVideoHDRSupported { device.isVideoHDREnabled = false }
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            // Some square front formats expose sRGB but cannot deliver 8-bit
            // full-range buffers. Asking for an unsupported type raises an Obj-C
            // exception (not a Swift error). Negotiate against the active output.
            let available = movie.videoOutput.availableVideoPixelFormatTypes
            let preferred: [OSType] = log
                ? [kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                   kCVPixelFormatType_420YpCbCr10BiPlanarFullRange]
                : hdr
                ? [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
                   kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange]
                : [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                   kCVPixelFormatType_32BGRA, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                   kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange]
            guard let pixelFormat = preferred.first(where: available.contains) else {
                throw NSError(domain: "YouRec", code: 3, userInfo: [NSLocalizedDescriptionKey:
                    "This camera format cannot provide a compatible recording buffer. Choose another recording quality."])
            }
            movie.videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
            publish {
                $0.hdrSupported = self.landscapeFrontEnabled ? device.activeFormat.supportedColorSpaces.contains(.HLG_BT2020) && device.activeFormat.supportedColorSpaces.contains(.sRGB) : hdrFormat != nil
                $0.hdrActive = hdr; $0.logSupported = logFormat != nil
                $0.activeLog = log ? (device.activeColorSpace.rawValue == 4 ? .appleLog2 : .appleLog) : nil
                if selectedMode == .log && !log { $0.warning = "Log is unavailable for this camera and framing. Using SDR." }
            }
            var settings = UserDefaults.standard.dictionary(forKey: settingsKey(device)) ?? [:]
            if nativeZoom {
                settings["zoom"] = Double(device.minAvailableVideoZoomFactor)
                UserDefaults.standard.set(settings, forKey: settingsKey(device))
            }
            let selected = min(device.maxAvailableVideoZoomFactor, max(device.minAvailableVideoZoomFactor, CGFloat(settings["zoom"] as? Double ?? 1)))
            let follows = UserDefaults.standard.bool(forKey: "dualFaceFollow")
            manualCenter = nil
            if !follows, !nativeZoom, selected > device.minAvailableVideoZoomFactor,
               let x = settings["panX"] as? Double, let y = settings["panY"] as? Double, x.isFinite, y.isFinite {
                let point = CameraFraming.clamped(CGPoint(x: x, y: y), fraction: device.minAvailableVideoZoomFactor / selected)
                if point != CameraFraming.middle { manualCenter = point }
            }
            let manual = manualCenter != nil
            manualInputZoom = manual ? device.minAvailableVideoZoomFactor : nil
            publish { $0.manualFramePreview = manual }
            followZoom = follows || manual ? (device.uniqueID, selected, false) : nil
            device.videoZoomFactor = follows || manual ? device.minAvailableVideoZoomFactor : selected
            lastSavedZoom = selected
            recordZoom(device)
            liveEffects.target(nil);dollyMeasurement=nil
            let clean=self.cleanZoom(device)
            let display:Double
            if #available(iOS 18.0,*) { display=Double(device.displayVideoZoomFactorMultiplier) } else { display=1 }
            publish { $0.dollyRangeText=String(format:"Clean zoom %.1f–%.1f×",Double(device.minAvailableVideoZoomFactor)*display,clean*display) }
            manualFocus = settings["locked"] as? Bool == true && device.isFocusModeSupported(.locked)
                && (Self.autoFocusMode(device) != nil || device.isLockingFocusWithCustomLensPositionSupported)
            if manualFocus {
                if device.isLockingFocusWithCustomLensPositionSupported {
                    device.setFocusModeLocked(lensPosition: Float(settings["lens"] as? Double ?? 0.5))
                } else { device.focusMode = .locked }
            } else if let mode = Self.autoFocusMode(device) { device.focusMode = mode }
            let apertureStops = Self.supportedApertures(device)
            let wasManual = manualAperture != nil
            manualAperture = CameraAperture.savedStop(settings["aperture"] as? Double, in: apertureStops)
            if !apertureStops.isEmpty || wasManual { Self.applyAperture(manualAperture, to: device) }
            let aperture = manualAperture
            var supportsLandscape = false
            if #available(iOS 26.0, *), device.position == .front {
                supportsLandscape = device.formats.contains {
                    $0.supportedDynamicAspectRatios.contains(.ratio16x9) && $0.supportedDynamicAspectRatios.contains(.ratio9x16)
                }
            }
            publish {
                $0.frontLandscape = self.landscapeFrontEnabled
                $0.bindRotation(to: device)
                $0.cameraID = device.uniqueID
                $0.apertureStops = apertureStops; $0.selectedAperture = aperture
                $0.rememberCamera(device.uniqueID, front: device.position == .front)
                if #available(iOS 18.0, *) { $0.displayZoomMultiplier = Double(device.displayVideoZoomFactorMultiplier) }
                else { $0.displayZoomMultiplier = 1 }
                $0.minZoom = Double(device.minAvailableVideoZoomFactor)
                $0.maxZoom = min(10, Double(device.maxAvailableVideoZoomFactor))
                $0.autofocusSupported = Self.autoFocusMode(device) != nil
                $0.focusAdjustable = device.isLockingFocusWithCustomLensPositionSupported
                $0.focusLockSupported = device.isFocusModeSupported(.locked)
                $0.frontLandscapeSupported = supportsLandscape
                if self.landscapeFrontEnabled { $0.previewRotationAngle = self.landscapePreviewAngle }
                else { $0.refreshRotation() }
                if let completion { self.queue.async(execute: completion) }
            }
        } catch {
            publish { $0.error = error.localizedDescription }
            if captureActive { if !explicitStopRequested { next = .pause }; requestedStop = true; movie.stopRecording() }
            completion?()
        }
        applyConnectionRotation()
        applySingleStabilization()
        updateSingleFollow(UserDefaults.standard.bool(forKey: "dualFaceFollow"))
        updateReadings()
    }

    private static func supportedApertures(_ device: AVCaptureDevice) -> [Float] {
        guard #available(iOS 27.0, *), device.isExposureModeSupported(.custom),
              device.isExposureModeSupported(.continuousAutoExposure) else { return [] }
        let format = device.activeFormat
        return CameraAperture.stops(recommended: format.recommendedLensApertureStops,
                                    minimum: format.minLensAperture, maximum: format.maxLensAperture) {
            format.supportsExposureModeCustom(lensAperture: $0, duration: AVCaptureDevice.autoExposureDuration,
                                               iso: AVCaptureDevice.autoISO)
        }
    }

    // The caller holds the device configuration lock and has checked the active format.
    private static func applyAperture(_ value: Float?, to device: AVCaptureDevice) {
        guard #available(iOS 27.0, *) else { return }
        if let value {
            device.setExposureModeCustom(lensAperture: value, duration: AVCaptureDevice.autoExposureDuration,
                                         iso: AVCaptureDevice.autoISO, completionHandler: nil)
        } else if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
    }

    func setAperture(_ value: Float?) {
        #if DEBUG && targetEnvironment(simulator)
        if recorderControlFixture {
            guard apertureAvailable, value.map({ apertureStops.contains($0) }) ?? true else { return }
            var settings = UserDefaults.standard.dictionary(forKey: "camera." + cameraID) ?? [:]
            settings["aperture"] = value.map { Double($0) }
            UserDefaults.standard.set(settings, forKey: "camera." + cameraID)
            configureFixtureAperture()
            return
        }
        #endif
        let id = cameraID
        queue.async {
            guard let device = self.input?.device, device.uniqueID == id, !self.dualEnabled,
                  !self.changingCamera, !self.finalizing else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                let stops = Self.supportedApertures(device)
                guard !stops.isEmpty, value.map({ stops.contains($0) }) ?? true else { return }
                Self.applyAperture(value, to: device)
                self.manualAperture = value
                self.saveCameraSettings()
                self.publish { camera in
                    guard camera.cameraID == id else { return }
                    camera.selectedAperture = value
                }
                self.updateReadings()
            } catch { self.publish { $0.warning = error.localizedDescription } }
        }
    }

    #if DEBUG && targetEnvironment(simulator)
    private func configureFixtureAperture(reset: Bool = false) {
        apertureStops = CommandLine.arguments.contains("--aperture-fixture") && cameraID == "fixture-wide" && !dualActive
            ? [1.48, 1.8, 2.8, 4] : []
        var settings = UserDefaults.standard.dictionary(forKey: "camera." + cameraID) ?? [:]
        if reset {
            settings.removeValue(forKey: "aperture")
            UserDefaults.standard.set(settings, forKey: "camera." + cameraID)
        }
        selectedAperture = CameraAperture.savedStop(settings["aperture"] as? Double, in: apertureStops)
        readings.updateAperture(selectedAperture ?? 1.8)
    }
    #endif

    func setHDR(_ enabled: Bool) {
        guard !dualActive else { return }
        #if DEBUG && targetEnvironment(simulator)
        if recorderControlFixture {
            guard !hasActiveTake else { return }
            hdrEnabled = enabled; hdrActive = enabled; colorMode = enabled ? .hdr : .sdr
            return
        }
        #endif
        queue.async {
            guard !self.captureActive, !self.finalizing, !self.changingCamera else { return }
            self.configureHDR(enabled)
        }
    }
    private func configureHDR(_ enabled: Bool) {
        cancelZoomTransition()
        UserDefaults.standard.set(enabled ? "hdr" : "sdr", forKey: "captureColorMode")
        UserDefaults.standard.set(enabled, forKey: "captureHDR")
        publish { $0.hdrEnabled = enabled; $0.colorMode = enabled ? .hdr : .sdr }
        // Select a matching format directly. Reapplying a session preset while
        // the old format is HLG-only can make AVFoundation select sRGB too early.
        applyCameraSettings()
    }
    func setColorMode(_ mode: CaptureColorMode) {
        guard !dualActive, mode != .log || logSupported else { return }
        if mode != .log { setHDR(mode == .hdr); return }
        queue.async {
            guard !self.captureActive, !self.finalizing, !self.changingCamera else { return }
            self.cancelZoomTransition()
            UserDefaults.standard.set(mode.rawValue, forKey: "captureColorMode")
            self.publish { $0.colorMode = mode }
            self.applyCameraSettings()
        }
    }

    func setQuality(_ quality: CaptureQuality) {
        guard !dualActive else { return }
        #if DEBUG && targetEnvironment(simulator)
        if recorderControlFixture { self.quality = quality; return }
        #endif
        queue.async {
            guard !self.captureActive, !self.finalizing, !self.retainMicrophone, !self.changingCamera, let device = self.input?.device else { return }
            guard device.supportsSessionPreset(quality.preset), self.session.canSetSessionPreset(quality.preset) else {
                self.publish { $0.warning = "This camera does not support \(quality.title)." }; return
            }
            self.saveCameraSettings()
            self.cancelZoomTransition()
            self.session.beginConfiguration(); self.session.sessionPreset = quality.preset; self.session.commitConfiguration()
            self.selectedQuality = quality; self.landscapeFrontEnabled = false
            UserDefaults.standard.set(quality.rawValue, forKey: "captureQuality")
            self.applyCameraSettings()
            let supported = Set(self.devices.filter { $0.supportsSessionPreset(quality.preset) }.map(\.uniqueID))
            self.publish {
                $0.quality = quality
                $0.cameras = $0.cameras.map { var choice = $0; choice.available = supported.contains(choice.id); return choice }
                if supported.count < self.devices.count { $0.warning = "Some cameras need 1080p. They are marked in the camera menu." }
            }
        }
    }

    func setFrontLandscape(_ enabled: Bool) {
        guard !hasActiveTake, state != .paused else { return }
        switchCamera(cameraID, landscape: enabled)
    }

    private static func supportsLandscape(_ device: AVCaptureDevice) -> Bool {
        guard #available(iOS 26.0, *), device.position == .front else { return false }
        return device.formats.contains {
            $0.supportedDynamicAspectRatios.contains(.ratio16x9) && $0.supportedDynamicAspectRatios.contains(.ratio9x16)
        }
    }
    // Capture queue; the caller freezes the displayed frame and holds writer
    // input through BOTH the lens replacement and this source-format change.
    private func configureFrontLandscape(_ enabled: Bool, captureAngle: CGFloat, previewAngle: CGFloat,
                                         completion: @escaping () -> Void) {
        guard enabled != landscapeFrontEnabled, let device = input?.device else { completion(); return }
        guard #available(iOS 26.0, *), device.position == .front else { completion(); return }
        // Center Stage's dynamic-ratio API uses landscape-format axes, not
        // delivered-pixel axes: ratio9x16 at capture angle0 produces1920x1080.
        if !enabled {
            self.session.beginConfiguration()
            self.session.sessionPreset = self.selectedQuality.preset
            self.session.commitConfiguration()
            self.landscapeFrontEnabled = false
            self.applyCameraSettings(completion: completion)
            return
        }
        let longSide: Int32 = self.selectedQuality == .ultraHD4K ? 3840 : 1920
        let shortSide: Int32 = self.selectedQuality == .ultraHD4K ? 2160 : 1080
        let quarterTurns = Int((captureAngle / 90).rounded())
        let apiRatioWide = !quarterTurns.isMultiple(of: 2)
        let ratio: AVCaptureDevice.AspectRatio = apiRatioWide ? .ratio16x9 : .ratio9x16
        let mode = CaptureColorMode(rawValue: UserDefaults.standard.string(forKey: "captureColorMode") ?? "") ?? ((UserDefaults.standard.object(forKey: "captureHDR") as? Bool ?? true) ? .hdr : .sdr)
        let wantsHDR = mode == .hdr
        var colorSpace: AVCaptureColorSpace = wantsHDR ? .HLG_BT2020 : .sRGB
        let apiWidth = apiRatioWide ? longSide : shortSide
        let apiHeight = apiRatioWide ? shortSide : longSide
        if mode == .log {
            let spaces: [AVCaptureColorSpace] = [.appleLog2, .appleLog]
            if let space = spaces.first(where: { space in device.formats.contains {
                let size = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                return $0.supportedDynamicAspectRatios.contains(ratio) && $0.supportedColorSpaces.contains(space)
                    && size.width >= apiWidth && size.height >= apiHeight && (size.width == apiWidth || size.height == apiHeight)
                    && $0.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }
            } }) { colorSpace = space }
        }
        let candidates = device.formats.filter {
            let size = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return $0.supportedDynamicAspectRatios.contains(ratio) &&
                $0.supportedColorSpaces.contains(colorSpace) &&
                size.width >= apiWidth && size.height >= apiHeight &&
                // One crop dimension must match: a larger square sensor
                // format would otherwise silently raise recording resolution.
                (size.width == apiWidth || size.height == apiHeight) &&
                $0.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }
        }
        guard let format = candidates.min(by: {
            let aBoth = $0.supportedColorSpaces.contains(.HLG_BT2020) && $0.supportedColorSpaces.contains(.sRGB)
            let bBoth = $1.supportedColorSpaces.contains(.HLG_BT2020) && $1.supportedColorSpaces.contains(.sRGB)
            if aBoth != bBoth { return aBoth }
            let a = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            let b = CMVideoFormatDescriptionGetDimensions($1.formatDescription)
            return Int64(a.width) * Int64(a.height) < Int64(b.width) * Int64(b.height)
        }) else {
            self.publish { $0.warning = wantsHDR
                ? "Landscape selfie is unavailable at this HDR quality. Try SDR or 1080p."
                : "Landscape selfie is unavailable at this quality. Try 1080p." }; completion(); return
        }
        let token = UUID()
        self.dynamicChangeID = token
        let finish: (Error?) -> Void = { error in
            guard self.dynamicChangeID == token else { return }
            self.dynamicChangeID = nil
            var failure = error
            let dimensions = device.dynamicDimensions
            if failure == nil && (dimensions.width != apiWidth || dimensions.height != apiHeight) {
                failure = NSError(domain: "YouRec", code: 2, userInfo: [NSLocalizedDescriptionKey:
                    "The camera could not provide the requested landscape resolution. Portrait framing has been restored."])
            }
            if let error = failure {
                self.session.beginConfiguration()
                self.session.sessionPreset = self.selectedQuality.preset
                self.session.commitConfiguration()
                self.landscapeFrontEnabled = false
                self.publish { $0.error = error.localizedDescription }
            } else {
                self.landscapeFrontEnabled = true
                self.preferredAngle = captureAngle
                self.landscapePreviewAngle = previewAngle
            }
            self.applyCameraSettings(completion: completion)
        }
        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            device.setDynamicAspectRatio(ratio) { _, error in
                self.queue.async { finish(error) }
            }
            device.unlockForConfiguration()
            self.queue.asyncAfter(deadline: .now() + 5) {
                finish(NSError(domain: "YouRec", code: 1, userInfo: [NSLocalizedDescriptionKey: "The camera did not finish changing format. Try again when the preview is active."]))
            }
        } catch { finish(error) }
    }

    private func refreshFramePreview() {
        let rear = dualEnabled ? dualCapture.pair.map { $0.first.position == .back || $0.second.position == .back } == true : input?.device.position == .back
        let leveling = wantsPreview && rear && (previewLevelAngle || UserDefaults.standard.bool(forKey: "levelHorizon"))
        let maximum = UserDefaults.standard.object(forKey: "levelHorizonDegrees") as? Double ?? HorizonFraming.defaultDegrees
        movie.queue.async { self.horizon.configure(maximum: leveling ? HorizonFraming.degrees(maximum) : nil) }
        let log = input?.device.activeColorSpace == .appleLog || input?.device.activeColorSpace.rawValue == 4
        // Earlier display layers cannot confirm presentation of a new lens.
        // Keep the Metal presentation handshake on those OS releases.
        let nativeAssist: Bool
        if #available(iOS 17.4, *) { nativeAssist = !dualEnabled && !log && (leveling || singleStabilizing || followPreviewRequired || manualCenter != nil) }
        else { nativeAssist = false }
        liveEffects.requireFramePreview(leveling || dualEnabled || singleStabilizing || followPreviewRequired || manualCenter != nil || landscapeFrontEnabled || log || Self.differentAspect(captureCanvas, deliveredCanvas),
                                        peaking: !dualEnabled && UserDefaults.standard.bool(forKey: "focusPeaking"),
                                        assistedCapture: nativeAssist)
    }
    private func clearTakeCanvas() {
        takeHasMedia = false
        captureCanvas = nil
        refreshFramePreview()
        publish { $0.takeCanvas = nil }
    }

    private func recordZoom(_ device:AVCaptureDevice) {
        let selected = followZoom.flatMap { $0.lens == device.uniqueID ? Double($0.selected) : nil }
        zoomHistory.record(time: Self.hostTime, zoom: Double(device.videoZoomFactor), lens: device.uniqueID,
                           selectedZoom: selected, minimumZoom: Double(device.minAvailableVideoZoomFactor),
                           manualCenter: manualCenter, manualMove: manualCenter == nil ? nil : zoomTransition?.curve)
    }
    private func cleanZoom(_ device:AVCaptureDevice)->Double {
        let native=device.activeFormat.secondaryNativeResolutionZoomFactors.max().map(Double.init) ?? 1
        return min(Double(device.maxAvailableVideoZoomFactor),max(Double(device.minAvailableVideoZoomFactor),max(native,Double(device.activeFormat.videoZoomFactorUpscaleThreshold))))
    }
    func triggerDollyZoom() {
        guard canTriggerDolly,let effect=videoEffects.first(where:{$0.enabled && $0.kind == .dollyZoom}) else { return }
        queue.async {
            if self.dollyFollower != nil || self.dollyPreparation != nil { self.stopDolly(immediate:false,reason:"Move held");return }
            guard let device=self.input?.device,self.wantsPreview,self.session.isRunning,!self.changingCamera else { return }
            let now=Self.hostTime,clean=self.cleanZoom(device),minimum=Double(device.minAvailableVideoZoomFactor)
            let upper=min(Double(device.maxAvailableVideoZoomFactor),clean*1.5)
            guard upper/minimum>=1.3 else {
                self.publish {$0.dollyHint="Choose 1080p or another lens for more zoom range"};return
            }
            guard let measurement=self.dollyMeasurement,measurement.stamp.lens==device.uniqueID,now-measurement.stamp.time<0.5 else {
                self.publish {$0.dollyHint="Tap a visible face or person"};return
            }
            self.cancelZoomTransition(cancelDolly:false)
            self.dollyCleanZoom=clean;self.dollyDirection=effect.choice("direction")
            let current=Double(self.selectedZoom(device))
            let desired=self.dollyDirection=="Stretch" ? min(upper,max(current,min(2,0.7/measurement.subject.box.height*current))) : current
            let token=UUID();self.dollyPreparation=token
            if desired>current*1.05 {
                self.publish {$0.dollyState = .preparing;$0.dollyHint="Hold still while the camera frames the subject"}
                self.setZoom(desired,seconds:0.8,forDolly:true)
                self.queue.asyncAfter(deadline:.now()+1.15) {
                    guard self.dollyPreparation==token else { return }
                    self.armDolly(effect,range:minimum...upper)
                }
            } else { self.armDolly(effect,range:minimum...upper) }
        }
    }
    private func armDolly(_ effect:VideoEffectSettings,range:ClosedRange<Double>) {
        dollyPreparation=nil
        guard let device=input?.device,let measurement=dollyMeasurement,
              measurement.stamp.lens==device.uniqueID,Self.hostTime-measurement.stamp.time<0.5,
              wantsPreview,session.isRunning,!session.isInterrupted else {
            publish {$0.dollyState = .ready;$0.dollyHint="Keep the subject fully in frame, then try again"};return
        }
        let zoom=Double(selectedZoom(device)),now=Self.hostTime
        guard range.contains(zoom) else { publish {$0.dollyState = .ready;$0.dollyHint="Zoom out before starting this move"};return }
        let headroom=dollyDirection=="Stretch" ? zoom/range.lowerBound : range.upperBound/zoom
        guard headroom>=1.12 else {
            publish {$0.dollyState = .ready;$0.dollyHint="Change Direction or zoom to leave room for the move"};return
        }
        dollyLens=device.uniqueID;dollyStopReason=""
        dollyFollower=DollyZoomFollower(referenceHeight:measurement.subject.box.height*zoom/measurement.stamp.zoom,zoom:zoom,range:range,time:measurement.stamp.time)
        dollyEndsAt=now+effect.number("duration");dollyLastUI = -.infinity
        movie.recordEvent("dollyStart",String(format:"Dolly Zoom on %@ at %.2f×",device.localizedName,zoom))
        publish {$0.dollyState = .following;$0.dollyHint=self.dollyDirection=="Stretch" ? "Walk slowly toward the subject" : "Walk slowly away from the subject"}
    }
    private func acceptDollyMeasurement(_ subject:EffectSubjectSample?,stamp:CaptureZoomStamp,synthetic:Bool=false) {
        #if DEBUG
        if syntheticDollyProbe && !synthetic { return }
        #endif
        guard let subject,subject.valid,!subject.clipped,subject.confidence>=0.6,
              (0.04...0.8).contains(subject.box.height),stamp.lens==input?.device.uniqueID else { return }
        if let previous=dollyMeasurement,dollyFollower != nil {
            guard previous.subject.face==subject.face else { return }
            let dt=max(1.0/30,stamp.time-previous.stamp.time)
            let change=abs(log((subject.box.height/stamp.zoom)/(previous.subject.box.height/previous.stamp.zoom)))
            guard change<min(0.5,0.25*dt*15) else { return }
        }
        dollyMeasurement=(subject,stamp)
        if dollyFollower != nil,stamp.lens==dollyLens {
            dollyFollower?.observe(height:subject.box.height,appliedZoom:stamp.zoom,time:stamp.time)
        }
    }
    private func advanceDollyZoom() {
        guard var follower=dollyFollower,let device=input?.device,device.uniqueID==dollyLens,
              wantsPreview,session.isRunning,!session.isInterrupted else { stopDolly(immediate:true,reason:"Move stopped");return }
        let now=Self.hostTime
        if now>=dollyEndsAt { follower.stop(at:now);if dollyStopReason.isEmpty { dollyStopReason="Move complete" } }
        let zoom=follower.value(at:now)
        do {
            try device.lockForConfiguration()
            applySelectedZoom(CGFloat(min(Double(device.maxAvailableVideoZoomFactor),max(Double(device.minAvailableVideoZoomFactor),zoom))), to: device)
            recordZoom(device);device.unlockForConfiguration()
            dollyFollower=follower
            if follower.hasStopped(at:now) { stopDolly(immediate:true,reason:dollyStopReason.isEmpty ? "Subject lost — tap to choose again" : dollyStopReason);return }
            if now-dollyLastUI>=0.2 {
                dollyLastUI=now
                let range=follower.range,span=max(0.001,log(range.upperBound/range.lowerBound))
                let headroom=min(1,max(0,dollyDirection=="Stretch" ? log(zoom/range.lowerBound)/span : log(range.upperBound/zoom)/span))
                let hint=follower.isStopping ? "Holding this framing" : self.dollyMeasurement?.subject.face==false ? "Following body — a visible face is steadier" : headroom<0.08 ? "Near the zoom limit" : zoom>dollyCleanZoom*1.02 ? "Digital zoom — image may look softer" : dollyDirection=="Stretch" ? "Walk slowly toward the subject" : "Walk slowly away from the subject"
                publish {$0.dollyState=follower.isStopping ? .stopping : .following;$0.dollyHint=hint;$0.dollyHeadroom=headroom}
            }
        } catch { stopDolly(immediate:true,reason:"Zoom stopped");publish {$0.warning=error.localizedDescription} }
    }
    private func stopDolly(immediate:Bool,reason:String) {
        let wasMoving=dollyFollower != nil || dollyPreparation != nil
        if dollyPreparation != nil {
            dollyPreparation=nil;cancelZoomTransition(cancelDolly:false)
        }
        if !immediate,dollyFollower != nil {
            dollyStopReason=reason;dollyFollower?.stop(at:Self.hostTime)
            publish {$0.dollyState = .stopping;$0.dollyHint="Holding this framing"};return
        }
        if dollyFollower != nil,let device=input?.device {
            var saved=UserDefaults.standard.dictionary(forKey:settingsKey(device)) ?? [:]
            saved["zoom"]=Double(selectedZoom(device));UserDefaults.standard.set(saved,forKey:settingsKey(device));lastSavedZoom=selectedZoom(device)
            movie.recordEvent("dollyEnd",String(format:"%@ at %.2f×",reason,Double(selectedZoom(device))))
        }
        dollyFollower=nil;dollyEndsAt = .infinity
        publish {$0.dollyState=wasMoving ? .holding : .ready;$0.dollyHint=wasMoving ? reason : "Tap a face, then start"}
    }

    /// Take over an existing move at the lens's actual framing, without blocking touch delivery.
    func beginPinchZoom(on lens: String, completion: @escaping (CameraFraming?) -> Void) {
        #if DEBUG && targetEnvironment(simulator)
        if recorderControlFixture {
            fixtureZoomRamp = nil
            completion(cameraID == lens ? CameraFraming(zoom: readings.zoom, center: probePanCenter) : nil)
            return
        }
        #endif
        queue.async {
            guard self.wantsPreview, self.session.isRunning, !self.session.isInterrupted,
                  !self.dualEnabled, !self.changingCamera, let device = self.input?.device, device.uniqueID == lens else {
                self.publish { _ in completion(nil) }; return
            }
            self.cancelZoomTransition()
            let start = self.currentFraming(device)
            self.publish { _ in completion(start) }
        }
    }

    private func currentFraming(_ device: AVCaptureDevice) -> CameraFraming {
        if manualCenter == nil, followZoom != nil,
           let visible = movie.queue.sync(execute: { singleFollow.visibleFraming(for: device.uniqueID) }) { return visible }
        return CameraFraming(zoom: Double(selectedZoom(device)), center: manualCenter ?? CameraFraming.middle)
    }

    /// Reveal more of this lens only when the speculative view needs it.
    /// During a take, retain the native detail delivered by the current format.
    func widenFramingPreview(_ token: UUID, on lens: String) {
        queue.async {
            guard self.framingSource.isActive(token), self.wantsPreview, !self.dualEnabled, !self.changingCamera,
                  !self.session.isInterrupted, self.manualCenter != nil || self.followZoom == nil,
                  let device = self.input?.device, device.uniqueID == lens else { return }
            let input = device.videoZoomFactor, minimum = device.minAvailableVideoZoomFactor
            var floor = minimum
            if self.captureActive {
                floor = max(minimum, min(input, device.activeFormat.videoZoomFactorUpscaleThreshold))
                for factor in device.activeFormat.secondaryNativeResolutionZoomFactors where factor <= input {
                    floor = max(floor, factor)
                }
            }
            guard input - floor > 0.01, (self.manualInputZoom ?? input) - floor > 0.01 else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                let selected = self.selectedZoom(device)
                self.framingPreviewOwner = (token, self.manualInputZoom)
                self.manualCenter = self.manualCenter ?? CameraFraming.middle
                self.followZoom = (lens, selected, false)
                self.manualInputZoom = nil
                self.widenManualInput(to: floor, on: device, over: 0.22)
                self.recordZoom(device); self.refreshFramePreview()
                self.publish { $0.manualFramePreview = true }
            } catch { /* The view can still compose inside the available sensor image. */ }
        }
    }

    func finishFramingPreview(_ token: UUID, on lens: String, committing target: CameraFraming?) {
        framingSource.end(token)
        queue.async {
            guard let owner = self.framingPreviewOwner, owner.token == token else { return }
            self.framingPreviewOwner = nil
            guard let device = self.input?.device, device.uniqueID == lens, !self.dualEnabled,
                  self.manualCenter != nil, self.followZoom?.lens == lens else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                // A centered move only needs to see its widest endpoint. Retain
                // the native detail we can use throughout the move.
                if let target {
                    let needed = self.inputZoom(for: CGFloat(target.zoom), center: target.center, timed: true, on: device)
                    self.widenManualInput(to: needed, on: device, over: 0.16)
                } else if let original = owner.previousInput {
                    self.manualInputZoom = original
                    self.handOffZoom(to: original, on: device)
                } else { self.restoreNativeZoomIfCentered(device) }
                self.recordZoom(device)
            } catch { self.publish { $0.warning = error.localizedDescription } }
        }
    }

    /// A centered zoom can stay native. An offset crop needs the wider sensor
    /// image; compensate for the ISP handoff on the same frames sent to the writer.
    private func widenManualInput(to requested: CGFloat, on device: AVCaptureDevice, over duration: Double) {
        let target = max(device.minAvailableVideoZoomFactor, min(requested, device.videoZoomFactor))
        if let previous = manualInputZoom, target >= previous - 0.0001 { return }
        manualInputZoom = target
        handOffZoom(to: target, on: device, over: duration)
    }

    private func inputZoom(for zoom: CGFloat, center: CGPoint?, timed: Bool, on device: AVCaptureDevice) -> CGFloat {
        guard center == CameraFraming.middle else { return device.minAvailableVideoZoomFactor }
        // A speculative pinch may already have widened the sensor a little.
        // Ease through that available crop before widening the lens any further.
        if timed && manualCenter == CameraFraming.middle && zoom < selectedZoom(device) {
            return manualInputZoom ?? device.videoZoomFactor
        }
        return zoom
    }

    private func beginManualFraming(_ start: CameraFraming, device: AVCaptureDevice, hardware: CGFloat, over duration: Double) {
        manualCenter = start.center
        followZoom = (device.uniqueID, CGFloat(start.zoom), false)
        manualInputZoom = nil
        widenManualInput(to: hardware, on: device, over: duration)
        if UserDefaults.standard.bool(forKey: "dualFaceFollow") {
            UserDefaults.standard.set(false, forKey: "dualFaceFollow")
            movie.queue.async { self.singleFollow.setEnabled(false) }
            publish { $0.faceFollowEnabled = false }
        }
        publish { $0.manualFramePreview = true }
        refreshFramePreview(); recordZoom(device)
    }

    func finishLiveFraming(on lens: String) {
        queue.async {
            guard !self.dualEnabled, let device = self.input?.device, device.uniqueID == lens else { return }
            if self.manualCenter == CameraFraming.middle {
                do {
                    try device.lockForConfiguration()
                    defer { device.unlockForConfiguration() }
                    self.restoreNativeZoomIfCentered(device)
                    self.recordZoom(device)
                } catch { self.publish { $0.warning = error.localizedDescription } }
            }
            self.saveCameraSettings()
        }
    }

    // Once centered, give magnification back to the ISP. The wide-source
    // crop compensates each delivered frame until the handoff is complete.
    private func restoreNativeZoomIfCentered(_ device: AVCaptureDevice) {
        guard let point = manualCenter, let state = followZoom, !state.restoring,
              hypot(point.x - 0.5, point.y - 0.5) * state.selected / device.minAvailableVideoZoomFactor < 0.003 else { return }
        manualCenter = CameraFraming.middle
        manualInputZoom = nil
        followZoom = (device.uniqueID, state.selected, true)
        handOffZoom(to: state.selected, on: device)
    }

    func setZoom(_ target: Double, seconds: Double, forDolly:Bool=false, on lens: String? = nil,
                 persist: Bool = true, center: CGPoint? = nil) {
        guard !dualActive, target.isFinite, seconds.isFinite else { return }
        if let center, !center.x.isFinite || !center.y.isFinite { return }
        #if DEBUG && targetEnvironment(simulator)
        if recorderControlFixture {
            guard lens == nil || lens == cameraID else { return }
            let bounded = min(maxZoom, max(minZoom, target))
            if seconds > 0 {
                fixtureZoomRamp = ZoomTransition(start: readings.zoom, target: bounded,
                    began: ProcessInfo.processInfo.systemUptime, duration: seconds,
                    startCenter: probePanCenter, targetCenter: CameraFraming.clamped(center ?? probePanCenter, fraction: minZoom / bounded))
            } else {
                fixtureZoomRamp = nil
                probePanCenter = CameraFraming.clamped(center ?? probePanCenter, fraction: minZoom / bounded)
                readings.update(zoom: bounded, focusLocked: readings.focusLocked, lensPosition: readings.lensPosition,
                                level: readings.level, audioArriving: true, audioClipping: false)
            }
            return
        }
        #endif
        queue.async {
            guard self.wantsPreview, self.session.isRunning, !self.session.isInterrupted,
                  !self.changingCamera, let device = self.input?.device else { return }
            guard !self.dualEnabled, lens == nil || device.uniqueID == lens else { return }
            let continuingSensorMove = self.zoomTransition?.curve.compensatesSensorSwitch == true
                && self.manualCenter == CameraFraming.middle && self.followZoom?.restoring == false
            self.cancelZoomTransition(cancelDolly:!forDolly, restoreInput: false)
            let bounded = min(device.maxAvailableVideoZoomFactor, max(device.minAvailableVideoZoomFactor, CGFloat(target)))
            let targetCenter = (center ?? self.manualCenter).map { CameraFraming.clamped($0, fraction: device.minAvailableVideoZoomFactor / bounded) }
            // Read the last visible tracking crop before locking the device.
            let takeover: CameraFraming?
            // A centered move on a native lens uses its existing zoom curve.
            // Widening the sensor separately while animating the same crop can
            // briefly expose the wrong magnification partway through the move.
            let interruptsHandoff = self.followZoom?.restoring == true && lens != nil && seconds > 0 && center != nil
                && abs(self.selectedZoom(device) - bounded) > 0.001
            if let targetCenter, self.manualCenter == nil || self.followZoom?.restoring == true,
               targetCenter != CameraFraming.middle || interruptsHandoff || (center != nil && UserDefaults.standard.bool(forKey: "dualFaceFollow")) {
                takeover = self.currentFraming(device)
            } else { takeover = nil }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if self.followZoom == nil { device.cancelVideoZoomRamp() }
                let hardware = self.inputZoom(for: bounded, center: targetCenter, timed: seconds > 0, on: device)
                let handoff = seconds > 0 ? min(0.30, seconds * 0.28) : 0.15
                let start = self.selectedZoom(device)
                let stabilized = (self.movie.connection(with: .video)?.activeVideoStabilizationMode ?? .off) != .off
                let centeredPinch = stabilized && lens != nil && targetCenter == CameraFraming.middle
                    && (self.manualCenter == nil || self.manualCenter == CameraFraming.middle)
                let centeredMove = seconds > 0 && ((lens == nil && center == nil) || centeredPinch) && !forDolly
                    && !UserDefaults.standard.bool(forKey: "dualFaceFollow")
                let sensorStart = min(self.manualInputZoom ?? device.videoZoomFactor, device.videoZoomFactor)
                let switches = device.activeFormat.secondaryNativeResolutionZoomFactors
                    .filter { sensorStart >= $0 && bounded < $0 }.sorted(by: >)
                let ownsCenteredInput = (self.manualCenter == nil && self.followZoom == nil) || centeredPinch
                let compensate = centeredMove && ((ownsCenteredInput && !switches.isEmpty) || continuingSensorMove)
                if compensate {
                    if self.manualCenter == nil || self.followZoom?.restoring == true {
                        self.beginManualFraming(CameraFraming(zoom: Double(start)), device: device, hardware: sensorStart, over: handoff)
                    }
                } else if let takeover { self.beginManualFraming(takeover, device: device, hardware: hardware, over: handoff) }
                else if self.manualCenter != nil && self.followZoom?.restoring == false {
                    self.widenManualInput(to: hardware, on: device, over: handoff)
                }
                if seconds <= 0 || (abs(self.selectedZoom(device) - bounded) <= 0.001 && self.manualCenter == targetCenter) {
                    if self.manualCenter != nil { self.manualCenter = targetCenter }
                    self.applySelectedZoom(bounded, to: device, duringPinch: !persist)
                    if persist { self.restoreNativeZoomIfCentered(device) }
                    self.recordZoom(device)
                    if persist {
                        var saved = UserDefaults.standard.dictionary(forKey: self.settingsKey(device)) ?? [:]
                        saved["zoom"] = Double(bounded)
                        self.storeCenter(in: &saved)
                        UserDefaults.standard.set(saved, forKey: self.settingsKey(device))
                        self.lastSavedZoom = bounded
                    }
                } else {
                    self.zoomTransition = (device.uniqueID, ZoomTransition(start: Double(self.selectedZoom(device)),
                        target: Double(bounded), began: Self.hostTime, duration: seconds,
                        startCenter: self.manualCenter, targetCenter: targetCenter, compensatesSensorSwitch: compensate,
                        stabilizedSwitches: compensate && stabilized ? switches.map(Double.init) : nil,
                        returningSensorStart: compensate && continuingSensorMove && stabilized && bounded > start ? Double(device.videoZoomFactor) : nil))
                    self.recordZoom(device)
                    let timer = DispatchSource.makeTimerSource(queue: self.queue)
                    if self.zoomTransition?.curve.drivesStabilizedSensor == true {
                        // Stabilization can deliver several exposures together.
                        // Drive this short handoff independently of those bursts.
                        timer.schedule(deadline: .now(), repeating: .nanoseconds(11_111_111), leeway: .milliseconds(1))
                    } else {
                        // Ordinary moves are frame-driven with a final deadline.
                        timer.schedule(deadline: .now() + seconds)
                    }
                    timer.setEventHandler { [weak self] in self?.advanceZoomTransition() }
                    self.zoomTimer = timer
                    timer.resume()
                }
            } catch { self.publish { $0.error = error.localizedDescription } }
        }
    }
    // All transition state and device writes belong to the capture queue.
    private func cancelZoomTransition(cancelDolly:Bool=true, restoreInput: Bool = true) {
        if cancelDolly { stopDolly(immediate:true,reason:"Move stopped") }
        zoomTimer?.cancel(); zoomTimer = nil
        if let transition = zoomTransition, let device = input?.device, device.uniqueID == transition.deviceID {
            do {
                try device.lockForConfiguration()
                if followZoom == nil { device.cancelVideoZoomRamp() }
                else if restoreInput && transition.curve.compensatesSensorSwitch { restoreNativeZoomIfCentered(device) }
                device.unlockForConfiguration()
                saveCameraSettings()
            } catch { publish { $0.error = error.localizedDescription } }
        }
        let hadMove = zoomTransition != nil
        zoomTransition = nil
        if hadMove, let device = input?.device { recordZoom(device) }
    }
    private func advanceZoomTransition() {
        guard let transition = zoomTransition, let device = input?.device,
              device.uniqueID == transition.deviceID, wantsPreview, session.isRunning, !session.isInterrupted else {
            saveCameraSettings(); cancelZoomTransition(); return
        }
        let now = Self.hostTime
        do {
            try device.lockForConfiguration()
            let target = min(device.maxAvailableVideoZoomFactor, max(device.minAvailableVideoZoomFactor, CGFloat(transition.curve.target)))
            let finished = transition.curve.isFinished(at: now)
            if transition.curve.compensatesSensorSwitch, manualCenter != nil, followZoom?.restoring == false {
                // The ISP may hold its previous crop for several exposures
                // while changing sampling modes. Request the wider input early;
                // the visible crop still follows the original presentation time.
                // A pinch can already have widened the input under the fingers.
                // Continue from there when the operator releases the gesture.
                let upper = transition.curve.target < transition.curve.start ? manualInputZoom ?? device.maxAvailableVideoZoomFactor : device.maxAvailableVideoZoomFactor
                let input = min(upper, max(device.minAvailableVideoZoomFactor,
                    transition.curve.sensorZoom(at: now, frameDuration: device.activeVideoMinFrameDuration.seconds)))
                if input != manualInputZoom {
                    device.videoZoomFactor = input
                    manualInputZoom = input
                }
            }
            if let center = transition.curve.center(at: now), manualCenter != nil { manualCenter = center }
            if finished {
                #if DEBUG
                zoomEndGap = abs(log2(Double(target / selectedZoom(device))))
                #endif
                if followZoom == nil { device.cancelVideoZoomRamp() }
                applySelectedZoom(target, to: device)
                restoreNativeZoomIfCentered(device)
            } else {
                // Evaluate the visible curve at elapsed time even when capture
                // delivers frames late or the stabilized lens is already wider.
                let value = CGFloat(transition.curve.value(at: now))
                applySelectedZoom(min(device.maxAvailableVideoZoomFactor, max(device.minAvailableVideoZoomFactor, value)), to: device)
            }
            recordZoom(device)
            device.unlockForConfiguration()
            if finished {
                // Focus changes can have saved an intermediate zoom even when
                // the target equals lastSavedZoom. Always persist completion.
                var saved = UserDefaults.standard.dictionary(forKey: settingsKey(device)) ?? [:]
                saved["zoom"] = Double(selectedZoom(device))
                storeCenter(in: &saved)
                UserDefaults.standard.set(saved, forKey: settingsKey(device))
                lastSavedZoom = selectedZoom(device)
                cancelZoomTransition(cancelDolly:false)
                updateReadings() // Persist only the final applied value, not every frame.
            }
        } catch {
            saveCameraSettings(); cancelZoomTransition()
            publish { $0.error = error.localizedDescription }
        }
    }
    func showFocusHint(_ text: String) {
        focusHintDismiss?.cancel()
        focusHint = text
        UIAccessibility.post(notification: .announcement, argument: text)
        focusHintDismiss = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(1.8)); try Task.checkCancellation() } catch { return }
            self?.focusHint = nil
        }
    }
    func toggleFocusPeaking() {
        focusPeaking.toggle()
        UserDefaults.standard.set(focusPeaking, forKey: "focusPeaking")
        queue.async { self.refreshFramePreview() }
    }

    private static func autoFocusMode(_ device: AVCaptureDevice) -> AVCaptureDevice.FocusMode? {
        if device.isFocusModeSupported(.continuousAutoFocus) { return .continuousAutoFocus }
        return device.isFocusModeSupported(.autoFocus) ? .autoFocus : nil
    }
    var fixedFocus: Bool { !autofocusSupported && !focusAdjustable }
    func autofocus(at point: CGPoint, marker: CGPoint, inOutputPixels: Bool = false) {
        guard ready, !busy, !switchingCamera, !dualActive, !readings.focusLocked else { return }
        if fixedFocus { showFocusHint("This lens has fixed focus"); return }
        let cameraID = self.cameraID
        queue.async {
            guard let device = self.input?.device, device.uniqueID == cameraID, !self.dualEnabled,
                  !self.manualFocus, let mode = Self.autoFocusMode(device) else { return }
            guard device.isFocusPointOfInterestSupported else {
                self.publish { if $0.cameraID == cameraID { $0.showFocusHint("This lens chooses its own focus point") } }
                return
            }
            do {
                let target: CGPoint
                if inOutputPixels {
                    let rect = self.movie.videoOutput.metadataOutputRectConverted(fromOutputRect:
                        CGRect(x: point.x - 0.5, y: point.y - 0.5, width: 1, height: 1))
                    guard !rect.isNull, !rect.isEmpty else { return }
                    target = CGPoint(x: min(1, max(0, rect.midX)), y: min(1, max(0, rect.midY)))
                } else { target = point }
                try device.lockForConfiguration()
                device.focusPointOfInterest = target
                device.focusMode = mode
                device.unlockForConfiguration()
                let id = UUID()
                self.focusTarget = (id, cameraID, ProcessInfo.processInfo.systemUptime)
                self.publish { camera in
                    if camera.cameraID == cameraID && !camera.switchingCamera { camera.previewView?.showFocus(at: marker, id: id) }
                }
            } catch { self.publish { $0.warning = error.localizedDescription } }
        }
    }
    func setFocus(locked: Bool, position: Float? = nil, persist: Bool = true) {
        #if DEBUG && targetEnvironment(simulator)
        if recorderControlFixture {
            readings.update(zoom: readings.zoom, focusLocked: locked, lensPosition: position ?? readings.lensPosition,
                            level: readings.level, audioArriving: true, audioClipping: false)
            return
        }
        #endif
        let cameraID = self.cameraID
        queue.async {
            guard let device = self.input?.device, device.uniqueID == cameraID, !self.dualEnabled else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                self.manualFocus = locked && device.isFocusModeSupported(.locked)
                if self.manualFocus {
                    if let position, device.isLockingFocusWithCustomLensPositionSupported {
                        device.setFocusModeLocked(lensPosition: min(1, max(0, position)))
                    } else { device.focusMode = .locked }
                } else if let mode = Self.autoFocusMode(device) { device.focusMode = mode }
                if persist { self.saveCameraSettings() }
                if persist, locked, let position {
                    var saved = UserDefaults.standard.dictionary(forKey: self.settingsKey(device)) ?? [:]
                    saved["lens"] = Double(min(1, max(0, position)))
                    saved["locked"] = true
                    UserDefaults.standard.set(saved, forKey: self.settingsKey(device))
                }
                self.updateReadings()
            } catch { self.publish { $0.error = error.localizedDescription } }
        }
    }
    private func syncAlertProtection() {
        let audio = AVAudioSession.sharedInstance()
        let requested = captureActive && UserDefaults.standard.bool(forKey: "protectRecordingAudio")
        guard audio.prefersNoInterruptionsFromSystemAlerts != requested else { return }
        do { try audio.setPrefersNoInterruptionsFromSystemAlerts(requested) }
        catch { if requested { publish { $0.warning = "iOS could not enable recording interruption protection." } } }
    }

    private func scheduleMicrophoneRefresh() {
        guard configured, wantsPreview, !previewResetPending else { return }
        // Port and engine notifications describe successive steps of the same
        // negotiation. Query the settled route once, on the capture queue.
        if recoveringMic { return }
        microphoneRetry?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.recoverMicrophone() }
        microphoneRetry = work
        queue.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func recoverMicrophone(attempt: Int = 0) {
        guard configured, wantsPreview else { return }
        microphoneRetry?.cancel(); microphoneRetry = nil
        if attempt == 0 { micRecoveryStarted = ProcessInfo.processInfo.systemUptime }
        recoveringMic = true
        refreshMicrophones()
        do {
            try microphoneEngine.start()
            recoveringMic = false
            let resolved = lastMicIssue; lastMicIssue = nil
            publish { camera in
                camera.meterAvailable = true
                if let resolved, camera.warning == resolved { camera.warning = nil }
            }
        } catch {
            let delays = [0.12, 0.25, 0.5, 0.8, 1.0]
            if attempt < delays.count {
                let work = DispatchWorkItem { [weak self] in self?.recoverMicrophone(attempt: attempt + 1) }
                microphoneRetry = work
                queue.asyncAfter(deadline: .now() + delays[attempt], execute: work)
                return
            }
            recoveringMic = false
            let message = captureActive ? "Microphone disconnected. Recording paused." : "Microphone unavailable. Check the input in the microphone menu."
            lastMicIssue = message
            publish { $0.meterAvailable = false; $0.warning = message }
            if captureActive { stop(pause: true) }
        }
    }

    func selectMicrophone(_ id: String) {
        #if DEBUG && targetEnvironment(simulator)
        if recorderControlFixture {
            guard microphones.contains(where: { $0.id == id }) else { return }
            microphoneRoute.select(id)
            refreshFixtureMicrophone()
            return
        }
        #endif
        queue.async {
            guard self.configured, self.wantsPreview else { return }
            guard AVAudioSession.sharedInstance().availableInputs?.contains(where: { $0.uid == id }) == true else {
                self.publish { $0.warning = "That microphone is no longer available." }
                self.refreshMicrophones()
                return
            }
            self.microphoneRoute.select(id)
            self.refreshMicrophones()
        }
    }
    func moveMicrophonePreference(_ id: String, offset: Int) {
        queue.async {
            var order = UserDefaults.standard.stringArray(forKey: "microphonePriority") ?? []
            guard let index = order.firstIndex(of: id), order.indices.contains(index + offset) else { return }
            order.swapAt(index, index + offset)
            UserDefaults.standard.set(order, forKey: "microphonePriority")
            self.refreshMicrophones()
        }
    }
    private func refreshMicrophones() {
        guard configured, wantsPreview else { return }
        let audio = AVAudioSession.sharedInstance()
        let ports = audio.availableInputs ?? []
        let actual = audio.currentRoute.inputs.first
        let defaults = UserDefaults.standard
        let saved = defaults.stringArray(forKey: "microphonePriority") ?? []
        let preferences = RecordingMicrophoneRoute.priority(saved: saved, discovered: ports.map(\.uid), actual: actual?.uid)
        if preferences != saved { defaults.set(preferences, forKey: "microphonePriority") }
        let savedNames = defaults.dictionary(forKey: "microphoneNames") as? [String: String] ?? [:]
        var known = savedNames
        for port in ports { known[port.uid] = port.portName }
        if known != savedNames { defaults.set(known, forKey: "microphoneNames") }
        let available = preferences.compactMap { id in ports.first { $0.uid == id } }
        let decision = microphoneRoute.resolve(ranked: available.map(\.uid), actual: actual?.uid,
            preferred: audio.preferredInput?.uid, inTake: retainMicrophone, now: ProcessInfo.processInfo.systemUptime)
        microphoneRouteCheck?.cancel()
        if let delay = decision.recheckAfter {
            let check = DispatchWorkItem { [weak self] in
                guard let self, self.wantsPreview, !self.previewResetPending else { return }
                if self.recoveringMic { self.refreshMicrophones() } else { self.recoverMicrophone() }
            }
            microphoneRouteCheck = check
            queue.asyncAfter(deadline: .now() + delay, execute: check)
        }
        if let id = decision.request, let port = available.first(where: { $0.uid == id }) {
            // iOS can reject this transiently while negotiating; resolve checks
            // the live route again and reports a persistent failure to the user.
            try? audio.setPreferredInput(port)
        }
        if let id = decision.failed {
            let desired = known[id] ?? "the selected microphone"
            let current = actual.map { " Using " + $0.portName + "." } ?? ""
            publish { $0.warning = "Could not switch to " + desired + "." + current }
        }
        if let id = decision.disconnected, let actual {
            let oldName = known[id] ?? "Microphone"
            let message = oldName + " disconnected. Using " + actual.portName + "."
            movie.recordEvent("microphoneFallback", message)
            publish { $0.warning = message }
        }
        let newMicID = actual?.uid ?? ""
        if newMicID != activeMicID, actual != nil || !retainMicrophone {
            let gain = RecordingGain.normalized(UserDefaults.standard.double(forKey: "recordingGain." + newMicID))
            movie.queue.async { self.recordingGain.set(gain) }
            publish { $0.recordingGainDB = gain }
        }
        if actual != nil || !retainMicrophone { activeMicID = newMicID }
        publish {
            $0.microphones = available.map { MicrophoneChoice(id: $0.uid, name: $0.portName) }
            $0.microphonePriority = preferences.map { MicrophoneChoice(id: $0, name: known[$0] ?? "Disconnected microphone") }
            $0.microphoneID = actual?.uid ?? ""
            $0.microphoneName = actual?.portName ?? "Microphone unavailable"
        }
    }
    private var lastSavedZoom: CGFloat = -1
    private var lastStorageCheck = -Double.infinity
    private func updateReadings() {
        guard let device = input?.device else { return }
        if !dualEnabled, let connection = movie.connection(with: .video), connection.activeVideoStabilizationMode != lastSingleStabilizationMode {
            let mode = connection.activeVideoStabilizationMode
            lastSingleStabilizationMode = mode
            publish { $0.singleStabilizationActive = mode != .off }
        }
        if !dualEnabled, let state = followZoom, state.lens == device.uniqueID {
            if state.restoring && !device.isRampingVideoZoom && abs(device.videoZoomFactor - state.selected) < 0.001 {
                followZoom = nil
                if manualCenter != nil {
                    manualCenter = nil; manualInputZoom = nil; followPreviewRequired = false
                    refreshFramePreview(); saveCameraSettings()
                    publish { $0.manualFramePreview = false }
                }
            }
            recordZoom(device)
        }
        let currentZoom = selectedZoom(device)
        if !dualEnabled, zoomTransition == nil, dollyFollower == nil, !device.isRampingVideoZoom, currentZoom != lastSavedZoom {
            lastSavedZoom = currentZoom
            var saved = UserDefaults.standard.dictionary(forKey: settingsKey(device)) ?? [:]
            saved["zoom"] = Double(currentZoom)
            UserDefaults.standard.set(saved, forKey: settingsKey(device))
        }
        let now = ProcessInfo.processInfo.systemUptime
        meterLock.lock()
        let audioAge = now - lastAudioAt
        let arriving = audioAge < 0.8
        let power = arriving ? measuredPeak : -160
        let clipping = now - lastClipAt < 0.35
        let dualAge = now - dualLastFrame
        meterLock.unlock()
        if captureActive && !requestedStop {
            if dualEnabled && dualAge > 1 && now - captureRequestedAt > 1 {
                next = .pause; requestedStop = true; movie.stopRecording()
                publish { $0.warning = "Two-camera video stopped arriving. Recording paused safely."; $0.ready = false }
            } else if !arriving && audioAge > 1 && now - captureRequestedAt > 1 && !(recoveringMic && now - micRecoveryStarted < 3) {
                next = .pause; requestedStop = true
                movie.stopRecording()
                microphoneEngine.stop()
                restartAfterFailure = true
                publish { $0.state = .saving; $0.warning = "No microphone audio is arriving. Recording paused; check the microphone before resuming." }
            } else if now - lastStorageCheck > 5, let directory {
                lastStorageCheck = now
                let capacity = try? RecoverySpace.capacity(at: directory)
                if let file = recordingFile, now > storageSample.time,
                   let bytes = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? NSNumber {
                    let rate = Double(max(0, bytes.int64Value - storageSample.bytes)) / (now - storageSample.time)
                    bytesPerSecond = max(bytesPerSecond, rate)
                    storageSample = (now, bytes.int64Value)
                }
                // Cover the next check, encoder drain, final fragment and project commit.
                if capacity.map({ Double($0.free - $0.floor) < 32_000_000 + 15 * bytesPerSecond }) ?? true {
                    next = .pause; requestedStop = true; movie.stopRecording()
                    publish { $0.state = .saving; $0.warning = "Recording paused to finish saving safely. Free some storage before resuming." }
                }
            }
        }
        if dualEnabled && wantsPreview && dualAge > 3 && !dualDeliveryWarned {
            dualDeliveryWarned = true
            publish { $0.ready = false; $0.warning = "Two-camera preview is unavailable. Pause and choose the cameras again." }
        }
        let locked = manualFocus || Self.autoFocusMode(device) == nil && device.isLockingFocusWithCustomLensPositionSupported
        if let target = focusTarget {
            let age = now - target.started
            if locked || device.uniqueID != target.deviceID || (age >= 0.85 && !device.isAdjustingFocus) || age >= 4 {
                focusTarget = nil
                publish { $0.previewView?.dismissFocus(id: target.id) }
            }
        }
        let position = device.lensPosition
        let aperture = device.lensAperture
        let id = device.uniqueID
        #if DEBUG
        var apertureProbe = ""
        if CommandLine.arguments.contains("--probe-aperture-controls"), #available(iOS 27.0, *) {
            apertureProbe = String(format: "actual=%.3f", aperture)
                + " apertureAuto=\(device.automaticallyAdjustsLensAperture) shutterAuto=\(device.automaticallyAdjustsExposureDuration) isoAuto=\(device.automaticallyAdjustsISO)"
        }
        #endif
        publish {
            $0.readings.update(zoom: Double(currentZoom), focusLocked: locked, lensPosition: position,
                              level: power, audioArriving: arriving, audioClipping: clipping)
            if $0.cameraID == id {
                $0.readings.updateAperture(aperture)
                #if DEBUG
                $0.readings.updateApertureProbe(apertureProbe)
                #endif
            }
        }
    }
    func addBookmark() { movie.bookmark(at: CMClockGetTime(CMClockGetHostTimeClock())) }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        #if DEBUG
        if probeDropPreviewFrames { return }
        #endif
        guard !mediaDualActive else { return }
        let host=CMClockGetHostTimeClock()
        let frameTime=session.synchronizationClock.map { CMSyncConvertTime(sampleBuffer.presentationTimeStamp,from:$0,to:host).seconds } ?? sampleBuffer.presentationTimeStamp.seconds
        effectCameraStamp=zoomHistory.frame(at:frameTime)
        let frameDevice = (connection.inputPorts.first?.input as? AVCaptureDeviceInput)?.device
        effectSourceCameraID = frameDevice?.uniqueID
        var stamp = effectCameraStamp.flatMap { $0.lens == effectSourceCameraID ? $0 : nil }
        let stabilized = connection.activeVideoStabilizationMode != .off
        let compensating = stamp?.manualMove?.compensatesSensorSwitch == true
        let frameZoom = frameDevice.flatMap { device in
            frameZoomCalibration.read(lens: device.uniqueID, format: ObjectIdentifier(device.activeFormat),
                stabilized: stabilized, time: frameTime, native: device.videoZoomFactor, compensating: compensating,
                deliveryAge: stabilized ? Self.hostTime - frameTime : nil) {
                guard let exif = CMGetAttachment(sampleBuffer, key: kCGImagePropertyExifDictionary, attachmentModeOut: nil) as? NSDictionary,
                      let focal = exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? NSNumber else { return nil }
                return (focal.doubleValue, (exif[kCGImagePropertyExifDigitalZoomRatio] as? NSNumber)?.doubleValue ?? 1)
            }
        }
        if stamp?.selectedZoom != nil, let frameDevice {
            if stabilized, let move = stamp?.manualMove, move.drivesStabilizedSensor {
                // A widening sensor command reaches the exposed image later.
                // A reversal back in follows the command at exposure time.
                let delay = move.target < move.start
                    ? frameZoomCalibration.stabilizedPullLatency(frameDuration: frameDevice.activeVideoMinFrameDuration.seconds) : 0
                if let reading = zoomHistory.frame(at: frameTime, latency: delay, interpolate: true), reading.lens == frameDevice.uniqueID {
                    stamp?.zoom = reading.zoom
                }
            } else {
                observedFollowZoom.record(time: Self.hostTime, zoom: Double(frameDevice.videoZoomFactor), lens: frameDevice.uniqueID)
                if let reading = observedFollowZoom.frame(at: frameTime, latency: 0, interpolate: true) { stamp?.zoom = reading.zoom }
                if let frameZoom { stamp?.zoom = frameZoom }
            }
            effectCameraStamp = stamp
        }
        let fullInput = sampleBuffer.imageBuffer
        let level: HorizonFraming?
        if let frameDevice, frameDevice.position == .back, let fullInput {
            level = horizon.frame(fullInput, source: frameDevice.uniqueID, time: frameTime, rotation: connection.videoRotationAngle,
                                  mirrored: connection.isVideoMirrored, stabilized: connection.activeVideoStabilizationMode != .off)
        } else { level = nil }
        let sampleBuffer = singleFollow.process(sampleBuffer, source: effectSourceCameraID ?? "",
                                                angle: connection.videoRotationAngle, mirrored: connection.isVideoMirrored, zoom: stamp, level: level)
        #if DEBUG
        if panProbeEnabled, frameTime - lastPanProbeTime >= 0.06 {
            lastPanProbeTime = frameTime
            let center = singleFollow.visibleFraming(for: effectSourceCameraID ?? "")?.center ?? CameraFraming.middle
            publish { if $0.probePanCenter != center { $0.probePanCenter = center } }
        }
        if followProbeEnabled, frameTime - lastFollowProbeTime > 0.2,
           let device = (connection.inputPorts.first?.input as? AVCaptureDeviceInput)?.device {
            lastFollowProbeTime = frameTime
            let crop = singleFollow.crop
            let value = String(format: "camera %.3f crop %.3f center %.3f %.3f", device.videoZoomFactor / device.minAvailableVideoZoomFactor, crop.width, crop.midX, crop.midY)
            publish { if $0.followProbeReading != value { $0.followProbeReading = value } }
        }
        #endif
        queue.async {
            if let transition = self.zoomTransition {
                if !transition.curve.drivesStabilizedSensor { self.advanceZoomTransition() }
            } else if self.dollyFollower != nil { self.advanceDollyZoom() }
        }
        if let pixel = sampleBuffer.imageBuffer {
            let size = CGSize(width: CVPixelBufferGetWidth(pixel), height: CVPixelBufferGetHeight(pixel))
            var angle = connection.videoRotationAngle
            // The connection may already advertise the new quarter-turn while
            // the output queue still holds landscape/portrait buffers from the old one.
            if let prior = observedPreview, prior.cameraID == effectSourceCameraID, prior.size == size, size.width != size.height,
               Int(((angle - prior.angle) / 90).rounded()) % 2 != 0 {
                // A newly switched lens can also deliver correctly rotated pixels before
                // the connection angle catches up. Don't keep the first, stale angle
                // indefinitely when the delivered size confirms the new orientation.
                let expected = frameDevice.flatMap { device -> CGSize? in
                    let format = device.activeFormat
                    if #available(iOS 26.0, *), format.supportedDynamicAspectRatios.contains(.ratio9x16),
                       format.supportedDynamicAspectRatios.contains(.ratio16x9) { return nil }
                    let native = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                    let quarterTurn = !Int((angle / 90).rounded()).isMultiple(of: 2)
                    return CGSize(width: CGFloat(quarterTurn ? native.height : native.width),
                                  height: CGFloat(quarterTurn ? native.width : native.height))
                }
                if expected != size { angle = prior.angle }
            }
            let geometry = PreviewGeometry(size: size, angle: angle, cameraID: effectSourceCameraID)
            if let fullInput, let lens = effectSourceCameraID {
                framingSource.offer(fullInput, lens: lens, angle: angle, mirrored: connection.isVideoMirrored,
                                    zoom: stamp?.zoom ?? Double(frameDevice?.videoZoomFactor ?? 1), level: singleFollow.deliveredLevel)
            }
            if observedPreview != geometry {
                observedPreview = geometry
                queue.async {
                    self.deliveredCanvas = size
                    self.refreshFramePreview()
                    self.publish { $0.deliveredPreview = geometry }
                }
            }
            previewFrames.store(pixel, angle: angle, mirrored: connection.isVideoMirrored)
            effectFrameAngle = angle; effectFrameMirrored = connection.isVideoMirrored
            if !movie.isRecording { liveEffects.submit(pixel,time:sampleBuffer.presentationTimeStamp.seconds,recording:false,angle:effectFrameAngle,mirrored:effectFrameMirrored,cameraStamp:effectCameraStamp,sourceCameraID:effectSourceCameraID,sensorTransform:singleFollow.sensorTransform) }
        }
        guard let clock = session.synchronizationClock, !CFEqual(clock, host) else { movie.appendVideo(sampleBuffer); return }
        var timing = CMSampleTimingInfo()
        guard CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: 0, timingInfoOut: &timing) == noErr else { return }
        let originalTime = timing.presentationTimeStamp
        timing.presentationTimeStamp = CMSyncConvertTime(originalTime, from: clock, to: host)
        if timing.duration.isNumeric { timing.duration = CMSyncConvertTime(originalTime + timing.duration, from: clock, to: host) - timing.presentationTimeStamp }
        if timing.decodeTimeStamp.isNumeric { timing.decodeTimeStamp = CMSyncConvertTime(timing.decodeTimeStamp, from: clock, to: host) }
        var synchronized: CMSampleBuffer?
        if CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sampleBuffer, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &synchronized) == noErr, let synchronized { movie.appendVideo(synchronized) }
    }
    func setRecordingGain(_ db: Double) {
        let gain = RecordingGain.normalized(db)
        recordingGainDB = gain
        if !microphoneID.isEmpty { UserDefaults.standard.set(gain, forKey: "recordingGain." + microphoneID) }
        movie.queue.async {
            self.recordingGain.set(gain)
            self.meterLock.lock(); self.lastClipAt = -.infinity; self.measuredPeak = -160; self.meterLock.unlock()
        }
    }
    private func processMicrophoneSample(_ original: CMSampleBuffer) {
        let sampleBuffer: CMSampleBuffer
        do { sampleBuffer = try recordingGain.process(original) }
        catch {
            // Never silently discard sound on a route format we cannot process.
            sampleBuffer = original
            publish { $0.warning = "Recording gain is unavailable for this microphone format." }
        }
        movie.appendAudio(sampleBuffer)
        guard let description = sampleBuffer.formatDescription,
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              format.mFormatID == kAudioFormatLinearPCM,
              let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let size = CMBlockBufferGetDataLength(block)
        let bytesPerSample = Int(format.mBitsPerChannel / 8)
        guard size > 0, bytesPerSample > 0, size.isMultiple(of: bytesPerSample) else { return }
        var address: UnsafeMutablePointer<Int8>?
        var contiguous = 0
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &contiguous, totalLengthOut: nil, dataPointerOut: &address) == kCMBlockBufferNoErr,
              contiguous == size, let address else { return }
        var peak: Float = 0
        do {
            let bytes = UnsafeRawBufferPointer(start: address, count: size)
            for offset in stride(from: 0, to: size, by: bytesPerSample) {
                let value: Float
                if format.mFormatFlags & kAudioFormatFlagIsFloat != 0, bytesPerSample == 4 {
                    value = bytes.loadUnaligned(fromByteOffset: offset, as: Float.self)
                } else if format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0, bytesPerSample == 2 {
                    value = Float(bytes.loadUnaligned(fromByteOffset: offset, as: Int16.self)) / 32768
                } else if format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0, bytesPerSample == 4 {
                    value = Float(bytes.loadUnaligned(fromByteOffset: offset, as: Int32.self)) / 2147483648
                } else { continue }
                peak = max(peak, abs(value))
            }
        }
        meterLock.lock()
        lastAudioAt = ProcessInfo.processInfo.systemUptime
        // Fast attack, approximately 300 ms release between callback buffers.
        measuredPeak = max(20 * log10(max(peak, 0.00000001)), measuredPeak - 1.5)
        if peak >= 0.988 { lastClipAt = lastAudioAt }
        meterLock.unlock()
    }

    #if DEBUG
    func probeDollyMeasurement(distance:Double?) {
        queue.async {
            guard let distance else { self.syntheticDollyProbe=false;return }
            self.syntheticDollyProbe=true
            guard let stamp=self.zoomHistory.frame(at:Self.hostTime) else { return }
            let height=0.18/distance*stamp.zoom
            let subject=EffectSubjectSample(time:0,box:CGRect(x:0.4,y:0.5-height/2,width:0.2,height:height),confidence:1,face:true)
            self.acceptDollyMeasurement(subject,stamp:stamp,synthetic:true)
        }
    }
    @MainActor func probePreviewSnapshot(imageURL: URL? = nil) -> [String: Any] {
        if let imageURL, let data = previewView?.lastFrozenImage?.pngData() { try? data.write(to: imageURL) }
        return ["freezes": previewView?.freezeCount ?? 0, "resumes": previewView?.resumeCount ?? 0,
                "hasFrozenImage": previewView?.lastFrozenImage != nil, "frozenVisible": previewView?.frozenVisible ?? false,
                "previewing": previewLayer?.isPreviewing ?? false, "switching": switchingCamera,
                "fallbacks": previewView?.fallbackCount ?? 0, "nativeEnabled": previewLayer?.connection?.isEnabled ?? false,
                "cameraID": cameraID, "oppositeCamera": oppositeCamera?.id ?? "", "warning": warning ?? ""]
    }
    @MainActor func probeLivePreview(to url: URL) async throws -> CGSize {
        let image: UIImage? = await withCheckedContinuation { continuation in
            previewFrames.image(previewAngle: previewRotationAngle, mirrored: frontPreviewMirrored) {
                continuation.resume(returning: $0)
            }
        }
        guard let image, let data = image.pngData() else { throw ProjectError.invalidMedia }
        try data.write(to: url)
        return image.size
    }
    @MainActor func probeScreen(to url: URL) throws {
        guard let window = previewView?.window else { throw ProjectError.invalidMedia }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try image.pngData()?.write(to: url)
    }
    private var probeGravityTurns: Int?
    fileprivate let measuringPreviewRotation = CommandLine.arguments.contains("--probe-preview-rotation")
    private var requestedPreviewTurn: (angle: CGFloat, time: CFTimeInterval)?
    private var previewTurnTimings: [Double] = []
    private func notePreviewRotationRequest(_ angle: CGFloat) {
        guard measuringPreviewRotation, let connection = previewLayer?.connection,
              connection.videoRotationAngle != angle, requestedPreviewTurn?.angle != angle else { return }
        requestedPreviewTurn = (angle, CACurrentMediaTime())
    }
    fileprivate func notePreviewRotationApplied() {
        guard measuringPreviewRotation, let requested = requestedPreviewTurn,
              previewLayer?.connection?.videoRotationAngle == requested.angle else { return }
        previewTurnTimings.append((CACurrentMediaTime() - requested.time) * 1000)
        requestedPreviewTurn = nil
    }
    private var interfaceTurnReport = ""
    private var pendingDualTurn: (angle: CGFloat, began: CFTimeInterval)?
    private var lastProbedDualOrientation: UIInterfaceOrientation?
    private var dualTurnTimes: [Int] = []

    @MainActor func probeInterfaceTurn(to orientation: UIInterfaceOrientation, duration: TimeInterval) {
        guard measuringPreviewRotation else { return }
        if dualActive && !hasActiveTake && state != .paused && orientation != lastProbedDualOrientation {
            lastProbedDualOrientation = orientation
            pendingDualTurn = (orientation.compositeVideoAngle, CACurrentMediaTime())
        }
        interfaceTurnReport = "System turn \(orientation.rawValue): \(Int((duration * 1000).rounded())) ms"
        previewView?.accessibilityValue = previewTurnReport
    }

    @MainActor fileprivate var previewTurnReport: String {
        let timings = previewTurnTimings.map { String(format: "%.3f", $0) }.joined(separator: ",")
        return "Observer to preview connection (ms): " + timings + "; " + interfaceTurnReport +
            "; dual presented (ms): " + dualTurnTimes.map(String.init).joined(separator: ",") +
            "; layout: " + String(describing: probePreviewLayout())
    }
    @MainActor func probeLockedRotation(_ quarterTurns: Int?) {
        probeGravityTurns = quarterTurns
        refreshRotation()
    }
    @MainActor func probePreviewLayout() -> [String: Any] {
        func rect(_ value: CGRect?) -> [Double] {
            guard let value else { return [] }
            return [Double(value.minX), Double(value.minY), Double(value.width), Double(value.height)]
        }
        return ["frontLandscape": frontLandscape, "gravity": previewLayer?.videoGravity.rawValue ?? "",
                "bounds": rect(previewLayer?.bounds),
                "pictureRect": rect(previewLayer?.layerRectConverted(fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1))),
                "previewRotation": Double(previewLayer?.connection?.videoRotationAngle ?? -1),
                "effectsHidden": previewView?.effectsView?.isHidden ?? true,
                "effectsFill": previewView?.effectsView?.fill ?? true,
                "effectsBounds": rect(previewView?.effectsView?.bounds)]
    }
    private var failNextSwitchPreview = false
    func probeFailNextSwitchPreview() { failNextSwitchPreview = true }
    func probeFailPlainPreview() { liveEffects.probeFailPlainPreview() }
    func probeRejectNextSwitch() { queue.async { self.rejectNextSwitch = true } }
    func probeSwapWithoutStopping(_ id: String) { switchCamera(id) }
    private var probeDropPreviewFrames = false // movie.queue only
    private let followProbeEnabled = CommandLine.arguments.contains("--probe-follow-zoom") && CommandLine.arguments.contains("--recorder-controls-test")
    private let panProbeEnabled = CommandLine.arguments.contains("--probe-lens-controls") && CommandLine.arguments.contains("--recorder-controls-test")
    private var lastPanProbeTime = -Double.infinity
    @Published fileprivate(set) var probePanCenter = CameraFraming.middle
    private var lastFollowProbeTime = -Double.infinity // movie.queue
    @Published private(set) var followProbeReading = ""
    private func traceCaptureFailure(_ error: NSError?, event: String) {
        let row: [String: Any] = ["time": Date().description, "event": event,
            "error": error.map { String(describing: $0) } ?? "", "wantsPreview": wantsPreview,
            "recording": captureActive || movie.isRecording, "running": activeSession.isRunning,
            "camera": input?.device.uniqueID ?? "", "colorSpace": input?.device.activeColorSpace.rawValue ?? -1,
            "buffer": previewFrames.probeGeometry()]
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("CaptureRuntimeDiagnostics.jsonl")
        guard let line = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
        var data = (try? Data(contentsOf: url)) ?? Data()
        if data.count > 128_000 { data = Data() }
        data.append(line); data.append(10); try? data.write(to: url, options: .atomic)
    }
    func probeMediaServicesReset() async {
        await withCheckedContinuation { continuation in queue.async {
            self.activeSession.stopRunning()
            NotificationCenter.default.post(name: AVCaptureSession.runtimeErrorNotification, object: self.activeSession,
                userInfo: [AVCaptureSessionErrorKey: NSError(domain: AVFoundationErrorDomain, code: AVError.mediaServicesWereReset.rawValue)])
            continuation.resume()
        } }
    }
    func probeDropFrames(_ drop: Bool) async {
        await withCheckedContinuation { continuation in movie.queue.async { self.probeDropPreviewFrames = drop; continuation.resume() } }
    }
    func probeSnapshot() async -> [String: Any] {
        await withCheckedContinuation { continuation in
            queue.async {
                self.meterLock.lock()
                let audioAge = min(999, ProcessInfo.processInfo.systemUptime - self.lastAudioAt)
                let peak = self.measuredPeak
                self.meterLock.unlock()
                let device = self.input?.device
                let dimensions = device.map { CMVideoFormatDescriptionGetDimensions($0.activeFormat.formatDescription) }
                var dynamic = CMVideoDimensions(width: 0, height: 0)
                var ratio = ""
                var dynamicFormats: [[String: Any]] = []
                if #available(iOS 26.0, *), let device {
                    dynamic = device.dynamicDimensions; ratio = device.dynamicAspectRatio?.rawValue ?? ""
                    dynamicFormats = device.formats.filter { !$0.supportedDynamicAspectRatios.isEmpty }.map {
                        let size = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                        return ["width": Int(size.width), "height": Int(size.height),
                                "ratios": $0.supportedDynamicAspectRatios.map(\.rawValue),
                                "colorSpaces": $0.supportedColorSpaces.map(\.rawValue)]
                    }
                }
                continuation.resume(returning: ["camera": device?.uniqueID ?? "", "movieRecording": self.movie.isRecording,
                    "previewRecovery": self.previewRecoveryID != nil, "previewResetPending": self.previewResetPending,
                    "previewSerial": self.previewFrames.frameSerial, "wantsPreview": self.wantsPreview,
                    "uptime": ProcessInfo.processInfo.systemUptime,
                    "zoomTransitionBegan": self.zoomTransition?.curve.began ?? -1,
                    "zoomTransitionActive": self.zoomTransition != nil,
                    "zoomEndGap": self.zoomEndGap,
                    "width": Int(dimensions?.width ?? 0), "height": Int(dimensions?.height ?? 0),
                    "dynamicWidth": Int(dynamic.width), "dynamicHeight": Int(dynamic.height), "dynamicRatio": ratio,
                    "dynamicFormats": dynamicFormats,
                    "activeColorSpace": device?.activeColorSpace.rawValue ?? -1,
                    "colorFormats": device?.formats.map { format -> [String: Any] in
                        let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                        return ["width": size.width, "height": size.height, "spaces": format.supportedColorSpaces.map(\.rawValue)]
                    } ?? [],
                    "landscapeFront": self.landscapeFrontEnabled,
                    "actualBuffer": self.previewFrames.probeGeometry(), "sessionPreset": self.session.sessionPreset.rawValue,
                    "outputSettings": String(describing: self.movie.videoOutput.videoSettings),
                    "connectionRotation": Double(self.movie.connection(with: .video)?.videoRotationAngle ?? -1),
                    "rotation": Double(self.preferredAngle), "zoom": Double(device?.videoZoomFactor ?? 0),
                    "focusLocked": device?.focusMode == .locked, "lensPosition": device?.lensPosition ?? 0,
                    "audioAge": audioAge, "peakDB": peak,
                    "microphone": self.activeMicID, "writer": self.movie.metrics,
                    "alertProtection": AVAudioSession.sharedInstance().prefersNoInterruptionsFromSystemAlerts,
                    "micFormatRetries": self.microphoneEngine.simulatedNegotiations,
                    "lastFinishError": self.lastFinishError, "captureClockIsHost": self.session.synchronizationClock.map { CFEqual($0, CMClockGetHostTimeClock()) } ?? false])
            }
        }
    }
    func probeRestoreSettings(_ settings: [String: Any], cameraID: String) {
        queue.async {
            self.changeCamera(cameraID)
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("camera.") {
                UserDefaults.standard.removeObject(forKey: key)
            }
            for (key, value) in settings { UserDefaults.standard.set(value, forKey: key) }
            self.applyCameraSettings()
        }
    }
    #endif
    private func recordingStarted(_ fileURL: URL) {
        queue.async {
            if !self.wantsPreview || self.requestedStop { self.movie.stopRecording(); return }
            self.publish { $0.state = .recording; $0.startedAt = Date() }
        }
    }
    private func recordingFinished(_ outputFileURL: URL, error: Error?) {
        recordingEffects.finishRecording { [weak self] in self?.saveFinishedRecording(outputFileURL, error:error) }
    }
    private func saveFinishedRecording(_ outputFileURL: URL, error: Error?) {
        queue.async {
            #if DEBUG
            self.lastFinishError = error?.localizedDescription ?? ""
            #endif
            self.captureActive = false
            self.finalizing = true
            self.publish { $0.state = .saving; $0.startedAt = nil }
            let success = error == nil || ((error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true)
            if !success {
                if !self.explicitStopRequested { self.next = .pause }
                self.publish { $0.warning = "Recording interrupted. Recovering any playable footage. \(error?.localizedDescription ?? "")" }
            }
            self.publish { controller in
                guard let save = controller.onSegment else {
                    self.queue.async {
                        self.finalizing = false; self.retainMicrophone = false
                        self.publish { $0.error = "No project is available to save this recording. Its file has been preserved."; $0.state = .paused }
                        if !self.wantsPreview { self.stopSession() }
                    }
                    return
                }
                save(outputFileURL) { saved in
                    self.queue.async {
                        self.finalizing = false
                        if saved { self.takeHasMedia = true }
                        let action = self.next
                        if saved, case .camera(let id) = action, self.wantsPreview {
                            self.changeCamera(id) { self.beginSegment() }; return
                        }
                        let paused = !saved || { if case .stop = action { return false }; return true }()
                        self.retainMicrophone = paused
                        if !paused { self.microphoneRoute = RecordingMicrophoneRoute(); self.clearTakeCanvas() }
                        self.publish {
                            $0.state = paused ? .paused : .idle
                            if $0.state == .idle { $0.refreshRotation() }
                        }
                        if !self.wantsPreview { self.stopSession() }
                        else if self.restartAfterFailure { self.restartAfterFailure = false; self.configure() }
                        else { self.refreshMicrophones() }
                    }
                }
            }
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    @ObservedObject var camera: CaptureController
    var fill = true
    var dismissEffects: (() -> Void)?
    @AppStorage("zoomTransitionSeconds") private var pinchSeconds = 0.0

    init(camera: CaptureController, fill: Bool = true, dismissEffects: (() -> Void)? = nil) {
        self.camera = camera; self.fill = fill; self.dismissEffects = dismissEffects
    }
    final class Preview: UIView, UIGestureRecognizerDelegate {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        var mirrored = false
        weak var focusCamera: CaptureController?
        private let focusBox = UIView()
        private var assistLayer: AVSampleBufferDisplayLayer?
        private var assistedFrameAngle: CGFloat = 0
        private var assistedFrameMirrored = false
        private var assistLens: String?
        private var assistFormat: CMVideoFormatDescription?
        private var focusBoxID: UUID?
        var subjectTap:((CGPoint)->Void)?
        var colorTap:((CGPoint)->Void)?
        var dismissEffects: (() -> Void)?
        private var backgroundAction:((VideoEffectPlacementGesture)->Void)?
        private var backgroundPanPoint:CGPoint?,backgroundPinchPoint:CGPoint?
        private var backgroundScale:CGFloat=1
        private var backgroundBounds=CGSize.zero
        private lazy var backgroundPan=UIPanGestureRecognizer(target:self,action:#selector(positionBackground(_:)))
        private lazy var backgroundPinch=UIPinchGestureRecognizer(target:self,action:#selector(positionBackground(_:)))
        private lazy var targetTap=UITapGestureRecognizer(target:self,action:#selector(tapSubject(_:)))
        private var captureInteraction:UIInteraction?
        private let targetBracket=CAShapeLayer()
        let effectsView = MetalEffectPreview(effectsPreview:true)
        private let frozenImage = UIImageView()
        private var generation: UUID?
        private var previewObservation: NSKeyValueObservation?
        private var resumed: ((Bool) -> Void)?
        private var waitingForStoppedPreview = false
        private var resumeAngle: CGFloat = 0
        private let pausedLabel = UILabel()
        #if DEBUG
        private(set) var freezeCount = 0
        private(set) var resumeCount = 0
        private(set) var fallbackCount = 0
        private(set) var lastFrozenImage: UIImage?
        var frozenVisible: Bool { !frozenImage.isHidden }
        #endif

        override init(frame: CGRect) {
            super.init(frame: frame)
            addGestureRecognizer(targetTap)
            backgroundPan.maximumNumberOfTouches=2;backgroundPan.delegate=self;backgroundPinch.delegate=self
            addGestureRecognizer(backgroundPan);addGestureRecognizer(backgroundPinch)
            backgroundPan.isEnabled=false;backgroundPinch.isEnabled=false
            targetBracket.fillColor=UIColor.clear.cgColor;targetBracket.strokeColor=UIColor.systemYellow.withAlphaComponent(0.8).cgColor;targetBracket.lineWidth=1.5;layer.addSublayer(targetBracket)
            if let effectsView { addSubview(effectsView) }
            frozenImage.backgroundColor = .black
            frozenImage.clipsToBounds = true
            frozenImage.isHidden = true
            frozenImage.isUserInteractionEnabled = false
            frozenImage.accessibilityIdentifier = "recorder.frozenPreview"
            addSubview(frozenImage)
            pausedLabel.text = "Preview paused"; pausedLabel.textColor = .white
            pausedLabel.font = .preferredFont(forTextStyle: .headline)
            pausedLabel.textAlignment = .center; pausedLabel.isHidden = true
            addSubview(pausedLabel)
            layer.addSublayer(targetBracket)
            focusBox.isUserInteractionEnabled = false
            focusBox.layer.borderColor = UIColor.systemYellow.cgColor
            focusBox.layer.borderWidth = 1.5
            focusBox.layer.cornerRadius = 3
            focusBox.layer.shadowColor = UIColor.black.cgColor
            focusBox.layer.shadowOffset = .zero; focusBox.layer.shadowOpacity = 0.9; focusBox.layer.shadowRadius = 1
            focusBox.alpha = 0
            addSubview(focusBox)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layoutSubviews() {
            super.layoutSubviews()
            if backgroundBounds != bounds.size {backgroundBounds=bounds.size;backgroundPanPoint=nil;backgroundPinchPoint=nil;backgroundScale=1}
            effectsView?.frame = bounds
            layoutAssistedFrame()
            frozenImage.frame = bounds
            pausedLabel.frame = CGRect(x: 0, y: bounds.midY - 22, width: bounds.width, height: 44)
        }
        func configureCaptureButtons(camera:CaptureController) {
            focusCamera = camera
            if camera.switchingCamera || camera.dualActive {
                focusBoxID = nil; focusBox.layer.removeAllAnimations(); focusBox.alpha = 0
            }
            effectsView?.peakingEnabled = camera.focusPeaking && !camera.dualActive && camera.effectColorPick == nil
            if #available(iOS 17.2,*) {
                if captureInteraction==nil {
                    let interaction=AVCaptureEventInteraction { [weak camera] event in if event.phase == .ended { camera?.triggerCrashZoom() } }
                    addInteraction(interaction);captureInteraction=interaction
                }
                (captureInteraction as? AVCaptureEventInteraction)?.isEnabled=camera.crashAvailable && camera.ready && camera.positioningEffectID==nil
            }
            let positioning=camera.effectBackgroundPlacement != nil
            if positioning != (backgroundAction != nil) {backgroundPanPoint=nil;backgroundPinchPoint=nil;backgroundScale=1}
            backgroundAction=positioning ? { [weak camera] in camera?.moveEffectBackground($0) } : nil
            backgroundPan.isEnabled=positioning;backgroundPinch.isEnabled=positioning;targetTap.isEnabled = camera.positioningEffectID == nil
            accessibilityHint=positioning ? "Position the background. Drag to move and pinch to scale, or use the movement actions." : nil
            accessibilityCustomActions=positioning ? [
                UIAccessibilityCustomAction(name:"Move background left") { [weak camera] _ in camera?.moveEffectBackground(.pan(CGPoint(x:-0.05,y:0)));camera?.moveEffectBackground(.ended);return true },
                UIAccessibilityCustomAction(name:"Move background right") { [weak camera] _ in camera?.moveEffectBackground(.pan(CGPoint(x:0.05,y:0)));camera?.moveEffectBackground(.ended);return true },
                UIAccessibilityCustomAction(name:"Move background up") { [weak camera] _ in camera?.moveEffectBackground(.pan(CGPoint(x:0,y:-0.05)));camera?.moveEffectBackground(.ended);return true },
                UIAccessibilityCustomAction(name:"Move background down") { [weak camera] _ in camera?.moveEffectBackground(.pan(CGPoint(x:0,y:0.05)));camera?.moveEffectBackground(.ended);return true },
                UIAccessibilityCustomAction(name:"Enlarge background") { [weak camera] _ in camera?.moveEffectBackground(.pinch(factor:1.1,from:CGPoint(x:0.5,y:0.5),to:CGPoint(x:0.5,y:0.5)));camera?.moveEffectBackground(.ended);return true },
                UIAccessibilityCustomAction(name:"Shrink background") { [weak camera] _ in camera?.moveEffectBackground(.pinch(factor:1/1.1,from:CGPoint(x:0.5,y:0.5),to:CGPoint(x:0.5,y:0.5)));camera?.moveEffectBackground(.ended);return true }
            ] : nil
            colorTap=camera.effectColorPick != nil ? { [weak camera] point in camera?.pickEffectColor(point) } : nil
            subjectTap=(camera.crashAvailable && camera.crashState == .ready || camera.dollyAvailable && !camera.dollyState.moving) ? { [weak camera] point in camera?.selectEffectSubject(point) } : nil
        }
        func gestureRecognizer(_ gestureRecognizer:UIGestureRecognizer,shouldRecognizeSimultaneouslyWith otherGestureRecognizer:UIGestureRecognizer)->Bool {
            (gestureRecognizer===backgroundPan && otherGestureRecognizer===backgroundPinch) || (gestureRecognizer===backgroundPinch && otherGestureRecognizer===backgroundPan)
        }
        @objc private func positionBackground(_ gesture:UIGestureRecognizer) {
            guard let action=backgroundAction else {return}
            if let pinch=gesture as? UIPinchGestureRecognizer {
                backgroundPanPoint=nil
                if [.ended,.cancelled,.failed].contains(gesture.state) || pinch.numberOfTouches<2 {backgroundPinchPoint=nil;backgroundScale=1;action(.ended);return}
                guard let point=effectsView?.framePoint(at:gesture.location(in:self),in:bounds,clamped:false) else {return}
                if gesture.state == .began || backgroundPinchPoint==nil {backgroundPinchPoint=point;backgroundScale=pinch.scale;return}
                action(.pinch(factor:Double(pinch.scale/max(0.0001,backgroundScale)),from:backgroundPinchPoint!,to:point))
                backgroundScale=pinch.scale;backgroundPinchPoint=point
            } else {
                if [.ended,.cancelled,.failed].contains(gesture.state) {backgroundPanPoint=nil;action(.ended);return}
                guard backgroundPinch.numberOfTouches<2,gesture.numberOfTouches==1 else {backgroundPanPoint=nil;return}
                guard let point=effectsView?.framePoint(at:gesture.location(in:self),in:bounds,clamped:false) else {return}
                if gesture.state == .began || backgroundPanPoint==nil {backgroundPanPoint=point;return}
                action(.pan(CGPoint(x:point.x-backgroundPanPoint!.x,y:point.y-backgroundPanPoint!.y)));backgroundPanPoint=point
            }
        }
        func showTarget(_ source:CGPoint?) {
            CATransaction.begin();CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            guard let source,let point=effectsView?.viewPoint(forSource:source,in:bounds),bounds.contains(point) else { targetBracket.opacity=0;return }
            targetBracket.path=UIBezierPath(roundedRect:CGRect(x:point.x-24,y:point.y-24,width:48,height:48),cornerRadius:8).cgPath
            targetBracket.opacity=1
        }
        func orientPicture(to angle: CGFloat, capture: CGFloat) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            if let connection = previewLayer.connection, connection.videoRotationAngle != angle,
               connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
            let needsLayout = effectsView?.previewAngle != angle
            effectsView?.orient(preview: angle, capture: capture)
            if needsLayout { layoutAssistedFrame() }
        }
        private func layoutAssistedFrame() {
            guard let display = assistLayer, let effectsView else { return }
            let rotation = (effectsView.previewAngle - assistedFrameAngle) * .pi / 180
            let sideways = abs(sin(rotation)) > 0.5
            CATransaction.begin(); CATransaction.setDisableActions(true)
            display.bounds = CGRect(origin: .zero, size: sideways ? CGSize(width: bounds.height, height: bounds.width) : bounds.size)
            display.position = CGPoint(x: bounds.midX, y: bounds.midY)
            display.videoGravity = previewLayer.videoGravity
            display.setAffineTransform(CGAffineTransform(rotationAngle: rotation)
                .concatenating(CGAffineTransform(scaleX: mirrored == assistedFrameMirrored ? 1 : -1, y: 1)))
            CATransaction.commit()
        }
        // Display the actual stabilized/reframed buffer. Apple's media layer
        // handles HLG and SDR in their native color spaces, just as for playback.
        func showAssistedFrame(_ pixel: CVPixelBuffer?, angle: CGFloat, mirrored captureMirror: Bool, cameraID: String?, zoomDeadline: CFTimeInterval?) {
            if pixel == nil || assistLens != cameraID {
                assistLayer?.sampleBufferRenderer.flush()
                assistLayer?.removeFromSuperlayer()
                assistLayer = nil; assistFormat = nil; assistLens = nil
            }
            guard let pixel, let effectsView else { return }
            if assistLayer == nil {
                let display = AVSampleBufferDisplayLayer()
                // Keep the live camera visible while the first reframed buffer
                // is being prepared, including after a renderer flush.
                display.isHidden = true
                layer.insertSublayer(display, below: effectsView.layer)
                assistLayer = display; assistLens = cameraID
            }
            guard let display = assistLayer else { return }
            assistedFrameAngle = angle; assistedFrameMirrored = captureMirror
            layoutAssistedFrame()
            let enqueued = display.enqueueCameraPixel(pixel, format: &assistFormat, presentAt: zoomDeadline)
            if #available(iOS 17.4, *) {
                let ready = display.isReadyForDisplay
                if display.isHidden == ready {
                    CATransaction.begin(); CATransaction.setDisableActions(true)
                    display.isHidden = !ready
                    CATransaction.commit()
                }
                if ready && enqueued { effectsView.onPresented?(cameraID, effectsView.frameSerial) }
            }
        }
        func showFocus(at point: CGPoint, id: UUID) {
            focusBoxID = id
            focusBox.layer.removeAllAnimations()
            let side: CGFloat = 48
            focusBox.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            focusBox.center = point
            focusBox.alpha = 1
        }
        func dismissFocus(id: UUID) {
            guard focusBoxID == id else { return }
            focusBoxID = nil
            UIView.animate(withDuration: 0.22) { self.focusBox.alpha = 0 }
        }
        @objc private func tapSubject(_ gesture:UITapGestureRecognizer) {
            if let dismissEffects { dismissEffects(); return }
            let point=gesture.location(in:self)
            if let colorTap {
                if let normalized=effectsView?.framePoint(at:point,in:bounds) { colorTap(normalized) }
                return
            }
            guard let subjectTap else {
                guard let camera = focusCamera, !camera.readings.focusLocked, !camera.dualActive,
                      frozenImage.isHidden, previewLayer.connection != nil else { return }
                let picture = previewLayer.layerRectConverted(fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1))
                if let effectsView, (assistLayer != nil || (!effectsView.isHidden && !effectsView.nativeOverlay)), let size = camera.previewCanvas {
                    guard let output = effectsView.captureOutputPoint(at: point, sourceSize: size) else { return }
                    camera.autofocus(at: output, marker: point, inOutputPixels: true)
                } else if picture.contains(point) {
                    camera.autofocus(at: previewLayer.captureDevicePointConverted(fromLayerPoint: point), marker: point)
                }
                return
            }
            guard let normalized=effectsView?.sourcePoint(at:point,in:bounds) else { return }
            subjectTap(normalized)
            let rect=CGRect(x:point.x-24,y:point.y-24,width:48,height:48)
            targetBracket.path=UIBezierPath(roundedRect:rect,cornerRadius:8).cgPath;targetBracket.opacity=1
            DispatchQueue.main.asyncAfter(deadline:.now()+0.8) { [weak self] in self?.targetBracket.opacity=0 }
        }
        func freeze(using frames: PreviewFrameStore, completion: @escaping (Bool) -> Void) {
            let token = UUID(); generation = token
            previewObservation = nil
            let angle = previewLayer.connection?.videoRotationAngle ?? 0
            let fill = previewLayer.videoGravity == .resizeAspectFill
            frames.image(previewAngle: angle, mirrored: previewLayer.connection?.isVideoMirrored ?? false) { [weak self] image in
                guard let self, self.generation == token else { completion(false); return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                // Keep an existing cover if a failed camera is being retried.
                if self.frozenImage.isHidden, let image {
                    self.frozenImage.image = image
                    self.frozenImage.contentMode = fill ? .scaleAspectFill : .scaleAspectFit
                    self.frozenImage.frame = self.bounds
                    self.frozenImage.isHidden = false
                    #if DEBUG
                    self.lastFrozenImage = image; self.freezeCount += 1
                    #endif
                }
                CATransaction.setCompletionBlock { [weak self] in
                    // Commit the cover before disconnecting the old preview.
                    guard let self, self.generation == token else { completion(false); return }
                    self.previewLayer.connection?.isEnabled = false
                    completion(true)
                }
                CATransaction.commit()
            }
        }
        func resume(angle: CGFloat, mirrored: Bool, framePreview: Bool, cameraID: String, completion: @escaping (Bool) -> Void) {
            guard let token = generation else { completion(false); return }
            self.mirrored = mirrored
            resumed = completion
            resumeAngle = angle; waitingForStoppedPreview = true
            if framePreview, let effectsView {
                // The visible surface is Metal, so native isPreviewing cannot
                // certify it. Release the cover only after a fresh frame from
                // the selected lens has actually been presented on screen.
                let serial = effectsView.frameSerial
                effectsView.onPresented = { [weak self] source, frame in
                    guard let self, self.generation == token, source == cameraID, frame > serial else { return }
                    self.revealRenderedFrame()
                }
                effectsView.onUnavailable = { [weak self] source in
                    guard let self, self.generation == token, source == nil || source == cameraID else { return }
                    self.resumeNativePreview(token: token, fallback: true)
                }
                if let connection = previewLayer.connection {
                    if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
                    if connection.isVideoMirroringSupported {
                        connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = mirrored
                    }
                    connection.isEnabled = true
                }
            } else {
                resumeNativePreview(token: token)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.generation == token else { return }
                if !framePreview || self.previewObservation != nil { self.revealLivePreview(token: token) }
                guard self.generation == token else { return }
                self.frozenImage.alpha = 0.4; self.pausedLabel.isHidden = false
                let callback = self.resumed; self.resumed = nil
                callback?(false)
                // Keep the frame visible on failure. A late first frame or a
                // subsequent switch can still release the cover.
            }
        }
        private func resumeNativePreview(token: UUID, fallback: Bool = false) {
            guard generation == token, previewObservation == nil else { return }
            effectsView?.onUnavailable = nil; effectsView?.onPresented = nil
            #if DEBUG
            if fallback { fallbackCount += 1 }
            #endif
            // A failed Metal display copy falls back to the actual native
            // preview. Require its stopped → rendering handshake too.
            waitingForStoppedPreview = true
            previewObservation = previewLayer.observe(\.isPreviewing, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.revealLivePreview(token: token) }
            }
            previewLayer.connection?.isEnabled = false
            revealLivePreview(token: token)
        }
        private func revealLivePreview(token: UUID) {
            guard generation == token else { return }
            if waitingForStoppedPreview {
                guard !previewLayer.isPreviewing, let connection = previewLayer.connection else { return }
                if connection.isVideoRotationAngleSupported(resumeAngle) { connection.videoRotationAngle = resumeAngle }
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = mirrored
                }
                waitingForStoppedPreview = false
                connection.isEnabled = true
                return
            }
            guard previewLayer.isPreviewing else { return }
            revealRenderedFrame()
        }
        private func revealRenderedFrame() {
            effectsView?.onPresented = nil; effectsView?.onUnavailable = nil
            previewObservation = nil; generation = nil
            waitingForStoppedPreview = false
            previewLayer.connection?.isEnabled = true
            frozenImage.isHidden = true; frozenImage.image = nil; frozenImage.alpha = 1; pausedLabel.isHidden = true
            #if DEBUG
            resumeCount += 1
            #endif
            let callback = resumed; resumed = nil; callback?(true)
        }
        func cancelFreeze() {
            effectsView?.onPresented = nil; effectsView?.onUnavailable = nil
            generation = nil; previewObservation = nil
            frozenImage.isHidden = true; frozenImage.image = nil; frozenImage.alpha = 1; pausedLabel.isHidden = true
            previewLayer.connection?.isEnabled = true
            let callback = resumed; resumed = nil; callback?(false)
        }
    }
    func makeUIView(context: Context) -> RecorderZoomViewport {
        let viewport = RecorderZoomViewport()
        let view = viewport.picture
        view.isAccessibilityElement=true;view.accessibilityLabel="Camera preview";view.accessibilityIdentifier="recorder.preview"
        view.previewLayer.session = camera.session
        camera.attachPreviewView(view)
        view.configureCaptureButtons(camera:camera)
        view.previewLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        return viewport
    }
    func updateUIView(_ viewport: RecorderZoomViewport, context: Context) {
        viewport.configure(camera: camera, seconds: pinchSeconds)
        let view = viewport.picture
        view.dismissEffects = dismissEffects
        view.configureCaptureButtons(camera:camera)
        let gravity: AVLayerVideoGravity = fill ? .resizeAspectFill : .resizeAspect
        if view.previewLayer.videoGravity != gravity { view.previewLayer.videoGravity = gravity }
        let angle = camera.displayedPreviewAngle
        view.effectsView?.fill = fill; view.effectsView?.mirrored = camera.frontPreviewMirrored
        view.mirrored = camera.frontPreviewMirrored
        view.orientPicture(to: angle, capture: camera.rotationAngle)
        view.accessibilityValue = (camera.showsWidePreview ? "Landscape" : "Portrait") + (fill ? ", Fill screen" : ", entire recorded frame")
        #if DEBUG
        if !camera.followProbeReading.isEmpty { view.accessibilityValue = camera.followProbeReading }
        if CommandLine.arguments.contains("--probe-lens-controls"), let device = AVCaptureDevice(uniqueID: camera.cameraID) {
            let focus = "continuous=\(device.isFocusModeSupported(.continuousAutoFocus)) single=\(device.isFocusModeSupported(.autoFocus)) point=\(device.isFocusPointOfInterestSupported) custom=\(device.isLockingFocusWithCustomLensPositionSupported) afPoint=\(device.focusPointOfInterest.x),\(device.focusPointOfInterest.y)"
            let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            let nativePicture = view.previewLayer.layerRectConverted(fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1))
            view.accessibilityValue = "\(device.deviceType.rawValue) \(focus) zoom=\(device.videoZoomFactor) format=\(dims.width)x\(dims.height) capture=\(camera.rotationAngle) preview=\(angle) canvas=\(String(describing: camera.previewCanvas)) fitted=\(String(describing: camera.previewLayoutCanvas)) bounds=\(view.bounds.size) native=\(nativePicture) frozen=\(view.frozenVisible) upscale=\(device.activeFormat.videoZoomFactorUpscaleThreshold) nativeStops=\(device.activeFormat.secondaryNativeResolutionZoomFactors)"
        }
        if CommandLine.arguments.contains("--probe-lens-controls") {
            let center = CameraFraming.oriented(camera.probePanCenter, angle: angle, mirrored: camera.frontPreviewMirrored)
            view.accessibilityValue = (view.accessibilityValue ?? "") + String(format: " pan=%.4f,%.4f", center.x, center.y) + " stabilized=\(camera.singleStabilizationActive)"
        }
        if CommandLine.arguments.contains("--probe-aperture-controls"), #available(iOS 27.0, *),
           let device = AVCaptureDevice(uniqueID: camera.cameraID) {
            view.accessibilityValue = (view.accessibilityValue ?? "")
                + " apertureAuto=\(device.automaticallyAdjustsLensAperture)"
        }
        #endif
        if let connection = view.previewLayer.connection, connection.isVideoMirroringSupported {
            if connection.automaticallyAdjustsVideoMirroring { connection.automaticallyAdjustsVideoMirroring = false }
            if connection.isVideoMirrored != camera.frontPreviewMirrored { connection.isVideoMirrored = camera.frontPreviewMirrored }
        }
        #if DEBUG
        if camera.measuringPreviewRotation {
            camera.notePreviewRotationApplied()
            view.accessibilityValue = camera.previewTurnReport
        }
        #endif
    }
    static func dismantleUIView(_ viewport: RecorderZoomViewport, coordinator: ()) {
        viewport.cancelPinch(); viewport.picture.cancelFreeze()
    }
}

/// Retain just one video buffer even when idle; render a still only when asked
/// to switch. Rendering runs off the audio/video writer queue.
final class PreviewFrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: (pixel: CVPixelBuffer, angle: CGFloat, mirrored: Bool)?
    private var serial: UInt64 = 0
    private var arrivedAt = -Double.infinity
    private let renderQueue = DispatchQueue(label: "yourec.preview-still", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    func store(_ pixel: CVPixelBuffer, angle: CGFloat, mirrored: Bool = false) {
        lock.lock(); latest = (pixel, angle, mirrored); serial &+= 1; arrivedAt = ProcessInfo.processInfo.systemUptime; lock.unlock()
    }
    var frameSerial: UInt64 { lock.lock(); defer { lock.unlock() }; return serial }
    func hasFreshFrames(after previous: UInt64, color: AVCaptureColorSpace) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard serial &- previous >= 2, ProcessInfo.processInfo.systemUptime - arrivedAt < 0.5, let pixel = latest?.pixel else { return false }
        if color == .appleLog { return LogColor.profile(pixel) == .appleLog }
        if color.rawValue == 4 { return LogColor.profile(pixel) == .appleLog2 }
        return LogColor.profile(pixel) == nil && VideoColor.isHDR(pixel) == (color == .HLG_BT2020)
    }
    func clear() { lock.lock(); latest = nil; lock.unlock() }
    #if DEBUG
    func probeGeometry() -> [String: Any] {
        lock.lock(); let frame = latest; lock.unlock()
        guard let frame else { return [:] }
        return ["width": CVPixelBufferGetWidth(frame.pixel), "height": CVPixelBufferGetHeight(frame.pixel),
                "rotation": Double(frame.angle), "mirrored": frame.mirrored,
                "format": CVPixelBufferGetPixelFormatType(frame.pixel), "log": LogColor.profile(frame.pixel)?.rawValue ?? "none", "hdr": VideoColor.isHDR(frame.pixel)]
    }
    #endif
    func image(previewAngle: CGFloat, mirrored: Bool = false, completion: @escaping (UIImage?) -> Void) {
        lock.lock(); let frame = latest; lock.unlock()
        renderQueue.async {
            let image: UIImage? = autoreleasepool {
                guard let frame else { return nil }
                // Video-output pixels are already rotated. Apply only the
                // difference from capture orientation to preview orientation.
                var ci = LogColor.image(frame.pixel, displayReferred: true)
                if frame.mirrored { ci = ci.transformed(by: CGAffineTransform(scaleX: -1, y: 1)) }
                ci = ci.transformed(by: CGAffineTransform(rotationAngle: -(previewAngle - frame.angle) * .pi / 180))
                if mirrored { ci = ci.transformed(by: CGAffineTransform(scaleX: -1, y: 1)) }
                let scale = min(1, 1920 / max(ci.extent.width, ci.extent.height))
                ci = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                return self.context.createCGImage(ci, from: ci.extent).map { UIImage(cgImage: $0) }
            }
            DispatchQueue.main.async { completion(image) }
        }
    }
}
