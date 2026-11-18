#if targetEnvironment(macCatalyst)
import SwiftUI
import ScreenCaptureKit
@preconcurrency import AVFoundation
import CoreImage

private enum DesktopCaptureError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? { switch self { case .unavailable(let message): message } }
}

enum DesktopSources: String, CaseIterable {
    case camera = "Camera", screen = "Screen", both = "Screen + camera"
    var usesCamera: Bool { self != .screen }
    var usesScreen: Bool { self != .camera }
}

// AVFoundation device changes run off the main thread. All incoming samples,
// the composited preview, and the writer share a single serial media queue.
private final class DesktopInputs: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
                                   AVCaptureAudioDataOutputSampleBufferDelegate, SCStreamOutput, @unchecked Sendable {
    let writer = CaptureSegmentWriter()
    let display = AVSampleBufferDisplayLayer()
    private let devices = DispatchQueue(label: "yourec.desktop.devices")
    private let session = AVCaptureSession()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let color = CGColorSpace(name: CGColorSpace.sRGB)!
    static let canvas = CGSize(width: 1920, height: 1080)
    var onReady: ((Bool) -> Void)?
    private var timer: DispatchSourceTimer?
    private var lastPicture: CMSampleBuffer?
    private var cameraOutput: AVCaptureVideoDataOutput?
    private var micOutput: AVCaptureAudioDataOutput?
    private var screenStream: SCStream?
    private var cameraPixel: CVPixelBuffer?
    private var screenPixel: CVPixelBuffer?
    private var screenBlank = false
    private var mode = DesktopSources.camera
    private var layout = DualCameraLayout()
    private var pool: CVPixelBufferPool?
    private var format: CMVideoFormatDescription?
    private var dirty = false
    private var ready = false
    private var inputClock: CMClock?

    func configure(camera: AVCaptureDevice?, mic: AVCaptureDevice?, mode: DesktopSources,
                   completion: @escaping (Error?) -> Void) {
        devices.async {
            self.session.stopRunning()
            self.session.beginConfiguration()
            self.session.inputs.forEach(self.session.removeInput)
            self.session.outputs.forEach(self.session.removeOutput)
            var failure: Error?
            let video = AVCaptureVideoDataOutput(), audio = AVCaptureAudioDataOutput()
            do {
                if let camera {
                    let input = try AVCaptureDeviceInput(device: camera)
                    guard self.session.canAddInput(input) else { throw DesktopCaptureError.unavailable("This camera is in use or unavailable.") }
                    self.session.addInput(input)
                    if self.session.canSetSessionPreset(.hd1920x1080) { self.session.sessionPreset = .hd1920x1080 }
                    video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                    video.alwaysDiscardsLateVideoFrames = true
                    guard self.session.canAddOutput(video) else { throw DesktopCaptureError.unavailable("Could not open the camera video stream.") }
                    self.session.addOutput(video)
                    video.setSampleBufferDelegate(self, queue: self.writer.queue)
                }
                if let mic {
                    let input = try AVCaptureDeviceInput(device: mic)
                    guard self.session.canAddInput(input) else { throw DesktopCaptureError.unavailable("Could not open the selected microphone.") }
                    self.session.addInput(input)
                    guard self.session.canAddOutput(audio) else { throw DesktopCaptureError.unavailable("Could not receive microphone audio.") }
                    self.session.addOutput(audio)
                    audio.setSampleBufferDelegate(self, queue: self.writer.queue)
                }
            } catch { failure = error }
            self.session.commitConfiguration()
            self.writer.queue.sync {
                self.mode = mode
                self.cameraOutput = camera == nil ? nil : video
                self.micOutput = mic == nil ? nil : audio
                self.cameraPixel = nil
                self.lastPicture = nil
                self.dirty = true
                self.setReady(false)
                self.startTimer()
            }
            if failure == nil, !self.session.inputs.isEmpty { self.session.startRunning() }
            let clock = self.session.synchronizationClock
            self.writer.queue.async { self.inputClock = clock }
            let result = failure
            DispatchQueue.main.async { completion(result) }
        }
    }

    #if DEBUG
    func setTestFrames(camera: CVPixelBuffer?, screen: CVPixelBuffer?) {
        writer.queue.async {
            if let camera { self.cameraPixel = camera }
            if let screen { self.screenPixel = screen }
            self.dirty = true
        }
    }
    #endif

    func setScreen(_ stream: SCStream?) {
        writer.queue.async {
            self.screenStream = stream
            self.screenBlank = false
            self.screenPixel = nil
            self.lastPicture = nil
            self.dirty = true
            self.setReady(false)
        }
    }
    func setLayout(_ value: DualCameraLayout) {
        writer.queue.async { self.layout = value; self.dirty = true }
    }
    func stop() {
        devices.async {
            self.session.stopRunning()
            self.session.beginConfiguration()
            self.session.inputs.forEach(self.session.removeInput)
            self.session.outputs.forEach(self.session.removeOutput)
            self.session.commitConfiguration()
            self.writer.queue.async {
                self.timer?.cancel()
                self.timer = nil
                self.lastPicture = nil
                self.cameraOutput = nil
                self.micOutput = nil
                self.screenStream = nil
                self.cameraPixel = nil
                self.screenPixel = nil
                self.setReady(false)
                self.display.sampleBufferRenderer.flush(removingDisplayedImage: true)
            }
        }
    }
    private func setReady(_ value: Bool) {
        guard value != ready else { return }
        ready = value
        onReady?(value)
    }
    private func startTimer() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: writer.queue)
        source.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / 30), leeway: .milliseconds(2))
        source.setEventHandler { [weak self] in self?.compose() }
        timer = source
        source.resume()
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === cameraOutput { cameraPixel = sampleBuffer.imageBuffer; dirty = true }
        else if output === micOutput {
            let host = CMClockGetHostTimeClock()
            guard let clock = inputClock, !CFEqual(clock, host) else { writer.appendAudio(sampleBuffer); return }
            var timing = CMSampleTimingInfo()
            guard CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: 0, timingInfoOut: &timing) == noErr else { return }
            let start = timing.presentationTimeStamp
            timing.presentationTimeStamp = CMSyncConvertTime(start, from: clock, to: host)
            if timing.duration.isNumeric {
                timing.duration = CMSyncConvertTime(start + timing.duration, from: clock, to: host) - timing.presentationTimeStamp
            }
            if timing.decodeTimeStamp.isNumeric { timing.decodeTimeStamp = CMSyncConvertTime(timing.decodeTimeStamp, from: clock, to: host) }
            var synced: CMSampleBuffer?
            if CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sampleBuffer, sampleTimingEntryCount: 1,
                    sampleTimingArray: &timing, sampleBufferOut: &synced) == noErr, let synced { writer.appendAudio(synced) }
        }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard stream === screenStream, type == .screen,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return }
        // An idle screen still has a valid last frame. Never keep showing the
        // previous contents when the system has blanked the selected source.
        if status == .complete, let pixel = sampleBuffer.imageBuffer { screenPixel = pixel; screenBlank = false; dirty = true }
        else if status == .blank || status == .suspended {
            screenPixel = nil
            screenBlank = true
            lastPicture = nil
            dirty = true
            display.sampleBufferRenderer.flush(removingDisplayedImage: true)
            setReady(false)
        }
    }
    private func compose() {
        guard dirty || writer.isRecording else { return }
        guard (!mode.usesScreen || screenPixel != nil || screenBlank), (!mode.usesCamera || cameraPixel != nil) else { return }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: now, decodeTimeStamp: .invalid)
        if !dirty, let lastPicture {
            // Static documents need fresh timestamps, but no additional GPU work.
            var repeated: CMSampleBuffer?
            if CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: lastPicture, sampleTimingEntryCount: 1,
                    sampleTimingArray: &timing, sampleBufferOut: &repeated) == noErr, let repeated { writer.appendVideo(repeated) }
            return
        }
        let bounds = CGRect(origin: .zero, size: Self.canvas)
        let background = CIImage(color: .black).cropped(to: bounds)
        let regions = mode == .both ? layout.regions(in: Self.canvas) : [bounds]
        var picture = background
        for (slot, region) in regions.enumerated() {
            let screen = mode == .screen || (mode == .both && slot == (layout.swapped ? 1 : 0))
            let rect = CGRect(x: region.minX, y: bounds.height - region.maxY, width: region.width, height: region.height)
            let source: CIImage
            if screen && screenBlank { source = background }
            else if let pixel = screen ? screenPixel : cameraPixel { source = CIImage(cvPixelBuffer: pixel) }
            else { return }
            let x = rect.width/source.extent.width, y = rect.height/source.extent.height
            // Keep the edges of a shared document visible. Camera panels fill their frame.
            let scale = screen ? min(x, y) : max(x, y)
            var image = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            image = image.transformed(by: CGAffineTransform(translationX: rect.midX-image.extent.midX, y: rect.midY-image.extent.midY))
            image = image.composited(over: background).cropped(to: rect)
            picture = slot == 0 ? image.composited(over: background) : DualCameraMasks.composite(first: picture, second: image, layout: layout, canvas: Self.canvas)
        }
        if pool == nil {
            let attrs: [String: Any] = [kCVPixelBufferWidthKey as String: Int(bounds.width), kCVPixelBufferHeightKey as String: Int(bounds.height),
                                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                        kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferMetalCompatibilityKey as String: true]
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        }
        var pixel: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool,
                [kCVPixelBufferPoolAllocationThresholdKey as String: 10] as CFDictionary, &pixel) == kCVReturnSuccess, let pixel else { return }
        CVBufferSetAttachment(pixel, kCVImageBufferCGColorSpaceKey, color, .shouldPropagate)
        context.render(picture, to: pixel, bounds: bounds, colorSpace: color)
        if format == nil { CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixel, formatDescriptionOut: &format) }
        var sample: CMSampleBuffer?
        guard let format, CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixel, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return }
        dirty = false
        lastPicture = sample
        writer.appendVideo(sample)
        let renderer = display.sampleBufferRenderer
        if renderer.requiresFlushToResumeDecoding { renderer.flush() }
        if renderer.isReadyForMoreMediaData { renderer.enqueue(sample) }
        setReady(true)
    }
}

private final class DesktopSharingObserver: NSObject, SCContentSharingPickerObserver, SCStreamDelegate {
    weak var recorder: DesktopRecorder?
    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in recorder?.pickerClosed() }
    }
    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in recorder?.pickerClosed(error) }
    }
    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in await recorder?.accept(filter, replacing: stream) }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in recorder?.lost(stream, error: error) }
    }
}

@MainActor final class DesktopRecorder: ObservableObject {
    enum State { case idle, recording, saving }
    @Published private(set) var state = State.idle
    @Published private(set) var ready = false
    @Published private(set) var mode = DesktopSources.camera
    @Published private(set) var cameras: [AVCaptureDevice] = []
    @Published private(set) var microphones: [AVCaptureDevice] = []
    @Published private(set) var cameraID = ""
    @Published private(set) var micID = ""
    @Published private(set) var screenName: String?
    @Published private(set) var picking = false
    @Published var error: String?
    @Published var layout = DualCameraLayout() { didSet { inputs.setLayout(layout) } }
    var onSegment: ((URL, @escaping (Bool) -> Void) -> Void)?
    var hasActiveTake: Bool { state != .idle }
    var display: AVSampleBufferDisplayLayer { inputs.display }
    private let inputs = DesktopInputs()
    private let observer = DesktopSharingObserver()
    private let picker = SCContentSharingPicker.shared
    private var stream: SCStream?
    private var visible = false
    private var choseMicrophone = false
    private var inputRevision = 0
    private var sharingRevision = 0
    private var notifications: [NSObjectProtocol] = []
    init() {
        observer.recorder = self
        inputs.onReady = { [weak self] value in Task { @MainActor in if self?.visible == true { self?.ready = value } } }
        inputs.writer.onEmpty = { [weak self] in Task { @MainActor in self?.state = .idle; self?.error = "No video frames were recorded." } }
        inputs.writer.onFinish = { [weak self] url, failure in Task { @MainActor in
            guard let self else { return }
            if let failure { self.error = failure.localizedDescription }
            self.state = .saving
            guard self.onSegment != nil else { self.state = .idle; return }
            self.onSegment?(url) { [weak self] indexed in Task { @MainActor in
                self?.state = .idle
                if !indexed { self?.error = "The take was saved. Open the project to recover it." }
            } }
        } }
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            notifications.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.devicesChanged() }
            })
        }
    }
    deinit { notifications.forEach(NotificationCenter.default.removeObserver) }
    private func discover() {
        cameras = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified).devices
        microphones = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }
    private func devicesChanged() {
        guard visible else { return }
        discover()
        let missingCamera = mode.usesCamera && !cameras.contains { $0.uniqueID == cameraID }
        let missingMic = !micID.isEmpty && !microphones.contains { $0.uniqueID == micID }
        if missingCamera || missingMic {
            if state == .recording { stop(); error = "A capture device disconnected. The take is being saved." }
            if missingCamera { cameraID = cameras.first?.uniqueID ?? "" }
            if missingMic { micID = "" }
            configure()
        }
    }
    func prepare() {
        guard !visible else { return }
        visible = true
        discover()
        if cameraID.isEmpty { cameraID = AVCaptureDevice.default(for: .video)?.uniqueID ?? cameras.first?.uniqueID ?? "" }
        if micID.isEmpty && !choseMicrophone { micID = AVCaptureDevice.default(for: .audio)?.uniqueID ?? microphones.first?.uniqueID ?? "" }
        if cameras.isEmpty { mode = .screen }
        observer.recorder = self
        picker.add(observer)
        configure()
    }
    func suspend(forPlayback: Bool = false) {
        guard visible else { return }
        visible = false
        inputRevision += 1
        if state == .recording { stop() }
        endSharing()
        picker.remove(observer)
        inputs.stop()
        ready = false
    }
    func finishPausedTake() { /* Desktop takes finish when Stop is pressed. */ }
    func choose(mode value: DesktopSources) {
        guard !hasActiveTake, value != mode else { return }
        mode = value
        if !value.usesScreen { endSharing() }
        configure()
    }
    func select(camera: String) { guard !hasActiveTake else { return }; cameraID = camera; configure() }
    func select(microphone: String) { guard !hasActiveTake else { return }; choseMicrophone = true; micID = microphone; configure() }
    private func configure() {
        inputRevision += 1
        let revision = inputRevision
        ready = false
        Task {
            let camera = mode.usesCamera ? cameras.first { $0.uniqueID == cameraID } : nil
            var mic = microphones.first { $0.uniqueID == micID }
            let allowCamera = camera == nil ? true : await AVCaptureDevice.requestAccess(for: .video)
            let allowMic = mic == nil ? true : await AVCaptureDevice.requestAccess(for: .audio)
            guard visible, revision == inputRevision else { return }
            if !allowMic { mic = nil; micID = ""; error = "Microphone access is off. You can record silently or enable access in System Settings." }
            if !allowCamera { error = "Allow camera access in System Settings, or choose Screen to record without a camera." }
            inputs.configure(camera: allowCamera ? camera : nil, mic: mic, mode: mode) { [weak self] failure in
                guard let self, self.visible, revision == self.inputRevision, let failure else { return }
                self.error = failure.localizedDescription
            }
        }
    }
    #if DEBUG
    /// The chart belongs to the test process. The normal compositor, display
    /// layer and movie writer are used for both deterministic and hardware runs.
    func preparePiPRegression(chart: SCContentFilter?, cameraFrame: CVPixelBuffer?, screenFrame: CVPixelBuffer?) async throws {
        visible = true
        mode = .both
        var device: AVCaptureDevice?
        if cameraFrame == nil {
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                throw DesktopCaptureError.unavailable("Allow YouRec to use the camera for the hardware test.")
            }
            let candidates = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external],
                mediaType: .video, position: .unspecified).devices
            guard let builtIn = candidates.first(where: { $0.deviceType == .builtInWideAngleCamera })
                    ?? candidates.first(where: { $0.modelID.contains("MacBook") || $0.localizedName.contains("FaceTime") })
            else { throw DesktopCaptureError.unavailable("No built-in camera found. Available cameras: " + candidates.map(\.localizedName).joined(separator: ", ")) }
            device = builtIn
        }
        try await withCheckedThrowingContinuation { (completion: CheckedContinuation<Void, Error>) in
            inputs.configure(camera: device, mic: nil, mode: .both) { error in
                if let error { completion.resume(throwing: error) } else { completion.resume() }
            }
        }
        inputs.setTestFrames(camera: cameraFrame, screen: screenFrame)
        if let chart { await accept(chart, replacing: nil) }
        if let error { throw DesktopCaptureError.unavailable(error) }
    }
    #endif

    func chooseScreen(_ style: SCShareableContentStyle) {
        guard visible, mode.usesScreen, !hasActiveTake, !picking else { return }
        picking = true
        var config = SCContentSharingPickerConfiguration()
        config.allowedPickerModes = style == .window ? [.singleWindow] : [.singleDisplay]
        config.excludedBundleIDs = [Bundle.main.bundleIdentifier].compactMap { $0 }
        picker.defaultConfiguration = config
        picker.isActive = true
        if let stream {
            picker.setConfiguration(config, for: stream)
            picker.present(for: stream, using: style)
        } else { picker.present(using: style) }
    }
    fileprivate func pickerClosed(_ failure: Error? = nil) {
        picking = false
        if stream == nil { picker.isActive = false }
        if visible, let failure { error = failure.localizedDescription }
    }
    fileprivate func accept(_ filter: SCContentFilter, replacing old: SCStream?) async {
        guard visible, mode.usesScreen, old == nil || old === stream else { return }
        sharingRevision += 1
        let revision = sharingRevision
        let config = SCStreamConfiguration()
        let size = filter.contentRect.size
        let scale = min(CGFloat(filter.pointPixelScale), min(1920/max(1,size.width), 1080/max(1,size.height)))
        config.width = max(2, Int(size.width*scale)/2*2)
        config.height = max(2, Int(size.height*scale)/2*2)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 4
        config.showsCursor = true
        config.capturesAudio = false
        let active = stream ?? SCStream(filter: filter, configuration: config, delegate: observer)
        let isNew = stream == nil
        do {
            if isNew {
                stream = active
                try active.addStreamOutput(inputs, type: .screen, sampleHandlerQueue: inputs.writer.queue)
                inputs.setScreen(active)
                try await active.startCapture()
            } else {
                try await active.updateContentFilter(filter)
                try await active.updateConfiguration(config)
            }
            guard revision == sharingRevision, active === stream else { return }
            screenName = filter.style == .window ? (filter.includedWindows.first?.title ?? "Selected window") : "Selected display"
            picking = false
        } catch {
            guard revision == sharingRevision else { return }
            lost(active, error: error)
        }
    }
    private func endSharing() {
        sharingRevision += 1
        let old = stream
        stream = nil
        screenName = nil
        picking = false
        picker.isActive = false
        inputs.setScreen(nil)
        if let old { Task { try? await old.stopCapture() } }
    }
    fileprivate func lost(_ stopped: SCStream, error: Error) {
        guard stream === stopped else { return }
        if state == .recording { stop() }
        endSharing()
        self.error = "Screen sharing ended. " + error.localizedDescription
    }
    func start(in folder: URL, projectID: UUID, destination: TakeReceipt.Destination) {
        guard visible, ready, state == .idle else { return }
        let segment = UUID()
        let name = String(format: "%.0f", Date().timeIntervalSince1970 * 1000) + "-" + segment.uuidString + ".mov"
        let url = folder.appendingPathComponent(name)
        do {
            try TakeReceipt.begin(movie: url, projectID: projectID, take: UUID(), segment: segment, sequence: 0, destination: destination)
            state = .recording
            inputs.writer.startRecording(to: url, canvas: DesktopInputs.canvas, includesMicrophone: !micID.isEmpty)
        } catch { self.error = error.localizedDescription }
    }
    func stop() {
        guard state == .recording else { return }
        state = .saving
        inputs.writer.stopRecording()
    }
}

private struct DesktopPicture: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    final class Host: UIView {
        var picture: AVSampleBufferDisplayLayer?
        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            picture?.frame = bounds
            CATransaction.commit()
        }
    }
    func makeUIView(context: Context) -> Host {
        let view = Host()
        view.accessibilityIdentifier = "desktop.preview"
        layer.videoGravity = .resizeAspect
        view.picture = layer
        view.layer.addSublayer(layer)
        return view
    }
    func updateUIView(_ view: Host, context: Context) {}
}

/// This overlay only handles the pointer. The pixels underneath still come from
/// the same compositor and layout as the movie, including during a take.
private struct DesktopInsetControls: View {
    @Binding var layout: DualCameraLayout
    @State private var dragOrigin: CGRect?
    @GestureState private var dragging = false
    @State private var hovering = false
    @Namespace private var coordinates

    var body: some View {
        GeometryReader { geometry in
            let canvas = geometry.size
            let inset = layout.regions(in: canvas)[1]
            let shape = RoundedRectangle(cornerRadius: layout.isRound ? inset.width / 2 : 0)
            ZStack(alignment: .topLeading) {
                shape.fill(.clear)
                    .contentShape(shape)
                    .frame(width: inset.width, height: inset.height)
                    .position(x: inset.midX, y: inset.midY)
                    .gesture(drag(corner: nil, canvas: canvas))
                    .help("Drag to move picture in picture")
                Rectangle().strokeBorder(.white.opacity(hovering || dragging ? 0.85 : 0.4), lineWidth: 1)
                    .frame(width: inset.width, height: inset.height)
                    .position(x: inset.midX, y: inset.midY)
                    .allowsHitTesting(false)
                ForEach(DualCameraLayout.InsetCorner.allCases, id: \.self) { corner in
                    let point = corner.point(in: inset)
                    Circle().fill(.white)
                        .overlay(Circle().strokeBorder(.black.opacity(0.85), lineWidth: 1.5))
                        .frame(width: 9, height: 9)
                        .opacity(hovering || dragging ? 1 : 0.8)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                        .position(point)
                        .gesture(drag(corner: corner, canvas: canvas))
                        .help("Drag to resize picture in picture")
                }
            }
            .frame(width: canvas.width, height: canvas.height)
            .coordinateSpace(name: coordinates)
            .onHover { hovering = $0 }
            .onChange(of: dragging) { _, active in
                if !active { dragOrigin = nil }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Picture in picture")
        .accessibilityHint("Drag the picture to move it or drag a corner to resize it.")
        .accessibilityIdentifier("desktop.pip")
    }

    private func drag(corner: DualCameraLayout.InsetCorner?, canvas: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(coordinates))
            .updating($dragging) { _, active, _ in active = true }
            .onChanged { value in
                let origin = dragOrigin ?? layout.regions(in: canvas)[1]
                dragOrigin = origin
                var next = layout
                next.dragInset(from: origin, by: value.translation, corner: corner, canvas: canvas)
                if next != layout { layout = next }
            }
            .onEnded { _ in dragOrigin = nil }
    }
}

struct DesktopRecorderView: View {
    @ObservedObject var camera: DesktopRecorder
    let project: Project?
    let start, newProject, projects, edit: () -> Void
    let inserting: Bool
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: projects) { Label("Projects", systemImage: "chevron.left") }
                Text(project?.title ?? "New project").font(.headline)
                Spacer()
                if !inserting, project?.hasSourceMedia == true { Button("Start new project", action: newProject) }
                Button("Edit project", action: edit)
            }.disabled(camera.hasActiveTake).padding()
            Divider()
            HStack(spacing: 0) {
                ZStack {
                    Color.black
                    DesktopPicture(layer: camera.display)
                    if camera.ready, camera.mode == .both, camera.layout.mode == .floating, camera.state != .saving {
                        DesktopInsetControls(layout: $camera.layout)
                            .aspectRatio(DesktopInputs.canvas.width / DesktopInputs.canvas.height, contentMode: .fit)
                            .clipped()
                    }
                    if !camera.ready {
                        VStack(spacing: 12) {
                            if camera.mode.usesScreen && camera.screenName == nil {
                                Image(systemName: "macwindow").font(.largeTitle)
                                Text(camera.picking ? "Choose what to share in the macOS picker." : "Choose a window or display in Recording sources.")
                            } else { Text("Waiting for camera…").foregroundStyle(.secondary) }
                        }.padding().background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Recording sources").font(.title3.bold())
                        Picker("Video", selection: Binding(get: { camera.mode }, set: { camera.choose(mode: $0) })) {
                            ForEach(DesktopSources.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        if camera.mode.usesScreen {
                            if let name = camera.screenName { Label(name, systemImage: "macwindow").lineLimit(2) }
                            HStack {
                                Button("Window…") { camera.chooseScreen(.window) }
                                    .accessibilityLabel("Choose window")
                                Button("Display…") { camera.chooseScreen(.display) }
                                    .accessibilityLabel("Choose display")
                            }.disabled(camera.picking)
                        }
                        if camera.mode.usesCamera {
                            Picker("Camera", selection: Binding(get: { camera.cameraID }, set: { camera.select(camera: $0) })) {
                                if camera.cameras.isEmpty { Text("No camera available").tag("") }
                                ForEach(camera.cameras, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                            }
                        }
                        Picker("Microphone", selection: Binding(get: { camera.micID }, set: { camera.select(microphone: $0) })) {
                            Text("None").tag("")
                            ForEach(camera.microphones, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                        }
                        if camera.mode == .both {
                            Divider()
                            LabeledContent("Layout") {
                                Picker("Layout", selection: $camera.layout.mode) {
                                    ForEach(DualCameraLayout.Mode.allCases) { Text($0.title).tag($0) }
                                }.labelsHidden()
                            }
                            if camera.layout.mode == .floating {
                                Toggle("Circular inset", isOn: Binding(get: { camera.layout.isRound }, set: { camera.layout.roundInset = $0 }))
                                Slider(value: $camera.layout.insetSize, in: 0.18...1) { Text("Inset size") }
                            } else if camera.layout.mode == .sideBySide {
                                Slider(value: $camera.layout.verticalDivider, in: 0.15...0.85) { Text("Divider") }
                            } else if camera.layout.mode == .topAndBottom {
                                Slider(value: $camera.layout.horizontalDivider, in: 0.15...0.85) { Text("Divider") }
                            } else { Button("Flip diagonal") { camera.layout.flipDiagonal() } }
                            Button { camera.layout.swapped.toggle() } label: { Label("Swap positions", systemImage: "arrow.left.arrow.right") }
                        }
                    }.pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading).padding()
                    .disabled(camera.hasActiveTake)
                }.frame(width: 280)
            }
            Divider()
            HStack {
                Text(camera.state == .saving ? "Saving take…" : camera.state == .recording ? "Recording" : "1080p · 30 fps")
                    .foregroundStyle(.secondary)
                Spacer()
                Button { if camera.state == .recording { camera.stop() } else { start() } } label: {
                    Label(camera.state == .recording ? "Stop recording" : "Record", systemImage: camera.state == .recording ? "stop.fill" : "record.circle")
                }.buttonStyle(.borderedProminent).tint(.red)
                    .disabled(camera.state == .saving || (!camera.hasActiveTake && (!camera.ready || camera.picking)))
                    .accessibilityIdentifier("desktop.record")
            }.padding()
        }
    }
}
#endif
