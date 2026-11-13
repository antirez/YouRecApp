@preconcurrency import AVFoundation
import CoreImage
import UIKit

extension UIInterfaceOrientation {
    /// Use rear-sensor axes to tag an already-upright two-camera composite.
    var compositeVideoAngle: CGFloat {
        switch self {
        case .landscapeRight: 0
        case .landscapeLeft: 180
        case .portraitUpsideDown: 270
        default: 90
        }
    }

    // Inputs stay in landscapeRight sensor coordinates. Turning the handset
    // turns the unmirrored selfie view in the opposite direction to the rear.
    func feedOrientation(front: Bool) -> CGImagePropertyOrientation {
        switch self {
        case .landscapeRight: .up
        case .landscapeLeft: .down
        case .portraitUpsideDown: front ? .right : .left
        default: front ? .left : .right
        }
    }
}

struct DualCameraPair: Identifiable {
    let first: AVCaptureDevice
    let second: AVCaptureDevice
    var id: String { first.uniqueID + "|" + second.uniqueID }
    var title: String { Self.name(first) + " + " + Self.name(second) }
    static func name(_ device: AVCaptureDevice) -> String {
        let lens = device.deviceType == .builtInUltraWideCamera ? "ultrawide" : device.deviceType == .builtInTelephotoCamera ? "tele" : "main"
        return (device.position == .front ? "Front " : "Rear ") + lens
    }
}

/// Topology on CaptureController's queue; samples/compositing on the writer queue.
/// No capture audio inputs: the existing microphone engine remains continuous.
final class MultiCameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureMultiCamSession()
    private let horizon: HorizonLevel
    let mediaQueue: DispatchQueue
    var onFrame: ((CMSampleBuffer, CVPixelBuffer) -> Void)? // host time; independent selfie-preview mirroring
    var onFailure: ((String) -> Void)?
    var onFollowFraming: ((DualCameraLayout) -> Void)?
    private(set) var pair: DualCameraPair?
    private var outputs: [AVCaptureVideoDataOutput] = []
    private var connections: [AVCaptureConnection] = []
    // Sensors have different frame phases. Match within half a frame, retaining
    // at most 8 samples per feed to cover the Standard stabilization delay.
    private var pending: [[(pixel: CVPixelBuffer, time: CMTime)]] = [[], []]
    private var latest: [(pixel: CVPixelBuffer, time: CMTime)?] = [nil, nil]
    private let context = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var pool: CVPixelBufferPool?
    private var poolSize = CGSize.zero
    private var active = false
    private var failed = false
    private var layout = DualCameraLayout()
    private var renderLayout = DualCameraLayout()
    private var followsFace = false
    private lazy var faceDetector = DualFaceDetector(mediaQueue: mediaQueue)
    private var followFraming = [DualCameraLayout.Framing(), DualCameraLayout.Framing()]
    private var lastFrameTime = -Double.infinity, lastFollowPublish = -Double.infinity
    private var maximumSkew = 0.0, maximumLatency = 0.0
    private var mirrorRecording = false
    private var mirrorPreview = true
    private var front = [false, true]
    private var canvas = CGSize(width: 1080, height: 1920)
    private(set) var frameAngle: CGFloat = 90 // media queue
    private var interfaceOrientation: UIInterfaceOrientation = .portrait
    private var accepted = 0, dropped = 0
    #if DEBUG
    private var probePair: (record: CVPixelBuffer, preview: CVPixelBuffer, layout: DualCameraLayout, front: [Bool], mirrors: [Bool])?
    func probeImages(prefix: URL) throws -> [String: Any] {
        guard let pair = mediaQueue.sync(execute: { probePair }) else { throw Failure("No paired camera frame") }
        let context = CIContext(options: [.cacheIntermediates: false])
        for (name, pixel) in [("record", pair.record), ("preview", pair.preview)] {
            let image = CIImage(cvPixelBuffer: pixel)
            guard let cg = context.createCGImage(image, from: image.extent), let data = UIImage(cgImage: cg).pngData() else { throw Failure("Cannot save camera comparison") }
            try data.write(to: prefix.appendingPathExtension(name + ".png"))
        }
        let size = CGSize(width: CVPixelBufferGetWidth(pair.record), height: CVPixelBufferGetHeight(pair.record))
        return ["front": pair.front, "swapped": pair.layout.swapped, "mode": pair.layout.mode.rawValue,
                "mirrors": pair.mirrors, "size": [size.width, size.height],
                "regions": pair.layout.regions(in: size).map { [$0.minX, $0.minY, $0.width, $0.height] }]
    }
    #endif

    init(mediaQueue: DispatchQueue, horizon: HorizonLevel) { self.mediaQueue = mediaQueue; self.horizon = horizon; super.init() }
    static func availablePairs() -> [DualCameraPair] {
        guard AVCaptureMultiCamSession.isMultiCamSupported else { return [] }
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera], mediaType: .video, position: .unspecified)
        let devices = discovery.devices.sorted {
            func rank(_ d: AVCaptureDevice) -> Int { (d.position == .front ? 10 : 0) + (d.deviceType == .builtInWideAngleCamera ? 0 : d.deviceType == .builtInUltraWideCamera ? 1 : 2) }
            return rank($0) < rank($1)
        }
        var pairs: [DualCameraPair] = []
        for i in devices.indices { for j in devices.indices where j > i {
            let a = devices[i], b = devices[j]
            if discovery.supportedMultiCamDeviceSets.contains(where: { $0.contains(a) && $0.contains(b) }), format(a) != nil, format(b) != nil {
                pairs.append(DualCameraPair(first: a, second: b))
            }
        } }
        return pairs.sorted { ($0.second.position == .front ? 0 : 1) < ($1.second.position == .front ? 0 : 1) }
    }
    static func stabilizationMode(_ format: AVCaptureDevice.Format) -> AVCaptureVideoStabilizationMode {
        if #available(iOS 26, *), format.isVideoStabilizationModeSupported(.lowLatency) { return .lowLatency }
        return format.isVideoStabilizationModeSupported(.standard) ? .standard : .off
    }
    private static func format(_ device: AVCaptureDevice, stabilize: Bool = false) -> AVCaptureDevice.Format? {
        let formats = device.formats.filter { f in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return f.isMultiCamSupported && d.width == 1920 && d.height == 1080 &&
                CMFormatDescriptionGetMediaSubType(f.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange &&
                f.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }
        }
        guard stabilize else { return formats.first }
        // Prefer the least delayed supported mode; never choose cinematic/auto.
        return formats.first { if #available(iOS 26, *) { return stabilizationMode($0) == .lowLatency }; return false }
            ?? formats.first { stabilizationMode($0) == .standard } ?? formats.first
    }
    func configure(pair: DualCameraPair, orientation: UIInterfaceOrientation, canvas: CGSize? = nil, stabilize: Bool = false) throws {
        shutdown()
        session.beginConfiguration()
        session.automaticallyConfiguresApplicationAudioSession = false
        session.automaticallyConfiguresCaptureDeviceForWideColor = false
        do {
            for device in [pair.first, pair.second] {
                guard let format = Self.format(device, stabilize: stabilize) else { throw Failure("This camera pair cannot record at 1080p / 30 fps.") }
                let input = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(input) else { throw Failure("This camera pair is unavailable.") }
                session.addInputWithNoConnections(input)
                try device.lockForConfiguration()
                device.activeFormat = format
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
                device.automaticallyAdjustsVideoHDREnabled = false
                if format.isVideoHDRSupported { device.isVideoHDREnabled = false }
                if format.supportedColorSpaces.contains(.sRGB) { device.activeColorSpace = .sRGB }
                device.videoZoomFactor = 1
                if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
                // A single-camera manual aperture must not carry into the dual session.
                if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                device.unlockForConfiguration()
                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                guard session.canAddOutput(output) else { throw Failure("Two-camera output is unavailable.") }
                session.addOutputWithNoConnections(output)
                guard let port = input.ports(for: .video, sourceDeviceType: device.deviceType, sourceDevicePosition: device.position).first else { throw Failure("The camera has no video port.") }
                let connection = AVCaptureConnection(inputPorts: [port], output: output)
                guard session.canAddConnection(connection) else { throw Failure("The camera connection is unavailable.") }
                session.addConnection(connection)
                if connection.isVideoMirroringSupported { connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = false }
                connection.videoOrientation = .landscapeRight
                if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = stabilize ? Self.stabilizationMode(format) : .off }
                output.setSampleBufferDelegate(self, queue: mediaQueue)
                outputs.append(output); connections.append(connection)
            }
            session.commitConfiguration()
            guard session.hardwareCost <= 1 else { throw Failure("This camera pair exceeds this iPhone’s recording budget. Choose another pair.") }
            self.pair = pair
            mediaQueue.sync { front = [pair.first.position == .front, pair.second.position == .front]; failed = false; accepted = 0; dropped = 0; maximumSkew = 0; maximumLatency = 0 }
            orient(orientation, canvas: canvas)
        } catch {
            if session.inputs.count < 2 || connections.count < 2 { session.commitConfiguration() }
            shutdown(); throw error
        }
    }
    func orient(_ orientation: UIInterfaceOrientation, canvas fixedCanvas: CGSize? = nil) {
        let landscape = fixedCanvas.map { $0.width > $0.height } ?? orientation.isLandscape
        mediaQueue.sync {
            self.interfaceOrientation = orientation
            frameAngle = orientation.compositeVideoAngle
            canvas = landscape ? CGSize(width: 1920, height: 1080) : CGSize(width: 1080, height: 1920)
            faceDetector.reset()
            lastFrameTime = -.infinity
        }
    }
    func update(_ layout: DualCameraLayout, recordingMirrored: Bool, previewMirrored: Bool, followFace: Bool = false) {
        mediaQueue.async {
            if self.followsFace != followFace { self.faceDetector.reset(); self.lastFrameTime = -.infinity }
            for (i, framing) in [layout.first, layout.second].enumerated() {
                let old = i == 0 ? self.layout.first : self.layout.second
                if !self.followsFace || old.x != framing.x || old.y != framing.y { self.followFraming[i] = framing }
                self.followFraming[i].zoom = framing.zoom
            }
            self.layout = layout; self.mirrorRecording = recordingMirrored; self.mirrorPreview = previewMirrored; self.followsFace = followFace
        }
    }
    func start() { mediaQueue.sync { active = true; failed = false; latest = [nil, nil]; pending = [[], []]; faceDetector.reset(); lastFrameTime = -.infinity }; session.startRunning() }
    var isDelivering: Bool { session.isRunning && mediaQueue.sync { active && !failed } }
    func stop() { mediaQueue.sync { active = false; latest = [nil, nil]; pending = [[], []]; pool = nil; faceDetector.reset() }; if session.isRunning { session.stopRunning() } }
    func shutdown() {
        stop(); session.beginConfiguration()
        for connection in session.connections { session.removeConnection(connection) }
        for output in session.outputs { (output as? AVCaptureVideoDataOutput)?.setSampleBufferDelegate(nil, queue: nil); session.removeOutput(output) }
        for input in session.inputs { session.removeInput(input) }
        session.commitConfiguration(); outputs = []; connections = []; pair = nil
        #if DEBUG
        mediaQueue.sync { probePair = nil }
        #endif
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard active, !failed, let index = outputs.firstIndex(where: { $0 === output }), let pixel = sample.imageBuffer else { return }
        guard CVPixelBufferGetWidth(pixel) == 1920, CVPixelBufferGetHeight(pixel) == 1080 else { return }
        let host = CMClockGetHostTimeClock()
        let time = session.synchronizationClock.map { CMSyncConvertTime(sample.presentationTimeStamp, from: $0, to: host) } ?? sample.presentationTimeStamp
        pending[index].append((pixel, time))
        if pending[index].count > 8 { pending[index].removeFirst(); dropped += 1 }
        while let a = pending[0].first, let b = pending[1].first {
            let action = DualFramePairing.action(first: a.time.seconds, second: b.time.seconds)
            if action != 0 { pending[action == -1 ? 0 : 1].removeFirst(); dropped += 1; continue }
            pending[0].removeFirst(); pending[1].removeFirst()
            compose([a.pixel, b.pixel], times: [a.time, b.time])
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) { dropped += 1 }
    private func compose(_ pixels: [CVPixelBuffer], times: [CMTime]) {
        guard !failed else { return }
        let host = CMClockGetHostTimeClock()
        let time = times[0]
        let skew = abs((times[0]-times[1]).seconds)
        guard skew < 1.0/30+0.001 else { dropped += 1; return }
        maximumSkew = max(maximumSkew, skew); maximumLatency = max(maximumLatency, (CMClockGetTime(host)-time).seconds)
        latest = [(pixels[0], times[0]), (pixels[1], times[1])]
        // Rotate the feeds before fitting each slot. Core Image folds this into
        // the existing composite render; no full-size intermediate is needed.
        let feeds = pixels.enumerated().map { index, pixel -> CIImage in
            let feed = CIImage(cvPixelBuffer: pixel).oriented(interfaceOrientation.feedOrientation(front: front[index]))
            guard !front[index], let pair else { return feed }
            let lens = index == 0 ? pair.first : pair.second
            let rotation = (connections[index].videoRotationAngle + frameAngle).truncatingRemainder(dividingBy: 360)
            guard let level = horizon.frame(pixel, source: lens.uniqueID, time: times[index].seconds,
                                            rotation: rotation, mirrored: false,
                                            stabilized: connections[index].activeVideoStabilizationMode != .off,
                                            sidewaysInput: !interfaceOrientation.isLandscape) else { return feed }
            return feed.transformed(by: level.imageTransform(feed.extent)).cropped(to: feed.extent)
        }
        renderLayout = layout
        if followsFace {
            faceDetector.submit(feeds, time: time.seconds)
            let regions = layout.regions(in: canvas)
            for slot in 0..<2 {
                let source = layout.swapped ? 1-slot : slot
                let face = faceDetector.targets[source].current(at: time.seconds)
                followFraming[source] = DualFaceFraming.follow(face, source: feeds[source].extent.size,
                    region: regions[slot], current: followFraming[source], elapsed: time.seconds-lastFrameTime,
                    target: CGPoint(x: 0.5, y: layout.mode == .diagonal ? (slot == 0 ? 0.25 : 0.75) : 0.5))
            }
            renderLayout.first = followFraming[0]; renderLayout.second = followFraming[1]
            if time.seconds-lastFollowPublish >= 0.1 { lastFollowPublish = time.seconds; onFollowFraming?(renderLayout) }
        }
        lastFrameTime = time.seconds
        do {
            let recorded = try composite(feeds, mirrored: mirrorRecording)
            var description: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: recorded, formatDescriptionOut: &description) == noErr, let description else { throw Failure("Could not describe the composed frame.") }
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: time, decodeTimeStamp: .invalid)
            var composed: CMSampleBuffer?
            guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: recorded, formatDescription: description, sampleTiming: &timing, sampleBufferOut: &composed) == noErr, let composed else { throw Failure("Could not create the composed video frame.") }
            let preview = mirrorPreview != mirrorRecording && front.contains(true)
                ? try composite(feeds, mirrored: mirrorPreview) : recorded
            #if DEBUG
            probePair = (recorded, preview, renderLayout, front, [mirrorRecording, mirrorPreview])
            #endif
            accepted += 1; onFrame?(composed, preview)
        } catch { fail(error.localizedDescription) }
    }
    private func fail(_ message: String) { guard !failed else { return }; failed = true; onFailure?(message) }
    private func composite(_ feeds: [CIImage], mirrored: Bool) throws -> CVPixelBuffer {
        if pool == nil || poolSize != canvas {
            let attrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: Int(canvas.width), kCVPixelBufferHeightKey as String: Int(canvas.height), kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferMetalCompatibilityKey as String: true]
            guard CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool) == kCVReturnSuccess else { throw Failure("Could not allocate the two-camera canvas.") }
            poolSize = canvas
        }
        var buffer: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, [kCVPixelBufferPoolAllocationThresholdKey as String: 10] as CFDictionary, &buffer) == kCVReturnSuccess, let buffer else { throw Failure("Two-camera rendering could not keep up. Recording paused safely.") }
        let bounds = CGRect(origin: .zero, size: canvas)
        var image = CIImage(color: .black).cropped(to: bounds)
        let layout = renderLayout
        let regions = layout.regions(in: canvas)
        for slot in 0..<2 {
            let source = layout.swapped ? 1-slot : slot
            var feed = feeds[source]
            let placed = DualCameraLayout.placement(source: feed.extent.size, region: regions[slot], framing: source == 0 ? layout.first : layout.second)
            let scale = placed.width/feed.extent.width
            let bottom = canvas.height-placed.maxY
            feed = feed.transformed(by: CGAffineTransform(scaleX: scale, y: scale)).transformed(by: CGAffineTransform(translationX: placed.minX, y: bottom))
            let clip = CGRect(x: regions[slot].minX, y: canvas.height-regions[slot].maxY, width: regions[slot].width, height: regions[slot].height)
            feed = feed.cropped(to: clip)
            if front[source] && mirrored {
                feed = feed.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: clip.midX*2, ty: 0))
            }
            image = slot == 1 ? DualCameraMasks.composite(first: image, second: feed, layout: layout, canvas: canvas) : feed.composited(over: image)
        }
        // A thin neutral separator is part of the composition, handles are not.
        if layout.mode == .sideBySide || layout.mode == .topAndBottom {
            let line: CGRect = layout.mode == .sideBySide ? CGRect(x: regions[0].maxX-1, y: 0, width: 2, height: canvas.height) : CGRect(x: 0, y: canvas.height-regions[0].maxY-1, width: canvas.width, height: 2)
            image = CIImage(color: CIColor(red: 0.12, green: 0.12, blue: 0.12)).cropped(to: line).composited(over: image)
        }
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        context.render(image, to: buffer, bounds: bounds, colorSpace: colorSpace)
        return buffer
    }
    func metrics() -> [String: Any] {
        var result: [String: Any] = ["hardwareCost": session.hardwareCost, "systemPressureCost": session.systemPressureCost, "pair": pair?.title ?? "", "formats": session.inputs.compactMap { ($0 as? AVCaptureDeviceInput)?.device.activeFormat.description }, "angles": connections.map(\.videoRotationAngle)]
        result["stabilization"] = connections.map { ["preferred": $0.preferredVideoStabilizationMode.rawValue, "active": $0.activeVideoStabilizationMode.rawValue] }
        mediaQueue.sync {
            result["frames"] = accepted; result["drops"] = dropped; result["canvas"] = [canvas.width, canvas.height]; result["delivered"] = latest.map { $0.map { [CVPixelBufferGetWidth($0.pixel), CVPixelBufferGetHeight($0.pixel)] } ?? [] }
            result["maximumSkew"] = maximumSkew; result["maximumDeliveryLatency"] = maximumLatency
            result["followFace"] = followsFace; result["faceDetections"] = faceDetector.detections; result["faceErrors"] = faceDetector.errors
            result["faceTargets"] = faceDetector.targets.map { target in target.box.map { [$0.minX, $0.minY, $0.width, $0.height] } ?? [] }
            result["faceAges"] = faceDetector.targets.map { lastFrameTime-$0.seenAt }.map { $0.isFinite ? $0 : -1 }
            result["framing"] = followFraming.map { [$0.x, $0.y, $0.zoom] }
        }
        return result
    }
    func stabilizationSummary() -> String {
        guard let pair, connections.count == 2 else { return "" }
        let names = [pair.first, pair.second].enumerated().compactMap { index, device in
            connections[index].activeVideoStabilizationMode != .off ? DualCameraPair.name(device) : nil
        }
        if names.count == 2 { return "Both cameras stabilized" }
        return names.first.map { $0 + " only · other camera unsupported" } ?? "Stabilization unavailable for this camera pair"
    }
    struct Failure: LocalizedError { let message: String; init(_ message: String) { self.message = message }; var errorDescription: String? { message } }
}
