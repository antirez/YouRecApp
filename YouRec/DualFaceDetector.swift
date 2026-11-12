import AVFoundation
import VideoToolbox
import CoreImage
import Metal
import Vision

/// One bounded job for both feeds. Vision never blocks the capture/writer queue.
/// All state apart from Vision's local request lives on the supplied media queue.
final class DualFaceDetector {
    private let worker = DispatchQueue(label: "yourec.dual.faces", qos: .userInitiated)
    private let mediaQueue: DispatchQueue
    private var busy = false, generation = 0
    private var lastSubmit = -Double.infinity
    private(set) var targets = [DualFaceTarget(), DualFaceTarget()]
    private(set) var detections = [0, 0], errors = 0
    init(mediaQueue: DispatchQueue) { self.mediaQueue = mediaQueue }
    func reset() { generation += 1; targets = [.init(), .init()]; lastSubmit = -.infinity }
    func submit(_ images: @autoclosure () -> [CIImage], time: Double, maximumSide: CGFloat = 512) {
        let interval = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue ? 0.2 : 0.1
        guard !busy, time-lastSubmit >= interval else { return }
        busy = true; lastSubmit = time
        let token = generation
        let inputs = images()
        worker.async {
            var boxes: [[CGRect]] = [], failures = 0
            for input in inputs {
                let found: [CGRect] = autoreleasepool {
                    do {
                        let scale = min(1, maximumSide/max(input.extent.width, input.extent.height))
                        let request = VNDetectFaceRectanglesRequest()
                        try VNImageRequestHandler(ciImage: input.transformed(by: CGAffineTransform(scaleX: scale, y: scale)), options: [:]).perform([request])
                        return (request.results ?? []).filter { $0.confidence >= 0.5 }.map {
                            let r = $0.boundingBox
                            return CGRect(x: r.minX, y: 1-r.maxY, width: r.width, height: r.height)
                        }
                    } catch { failures += 1; return [] }
                }
                boxes.append(found)
            }
            let result = boxes, failureCount = failures
            self.mediaQueue.async {
                self.busy = false
                guard token == self.generation else { return }
                self.errors += failureCount
                for i in result.indices {
                    self.targets[i].observe(result[i], at: time)
                    if !result[i].isEmpty { self.detections[i] += 1 }
                }
            }
        }
    }
}

// Follow over the entire physical lens. The selected zoom defines the movable
// viewport; only near the widest setting do we need additional tracking room.
final class SingleCameraFaceFollow {
    static let fullFrame = CGRect(x: 0, y: 0, width: 1, height: 1)
    private let detector: DualFaceDetector
    private var framing = DualCameraLayout.Framing()
    private var reserve = 1.0
    private var returning = false
    private var sourceSize = CGSize.zero
    enum Status: String { case searching = "Looking for a face", following = "Following face", holding = "Holding last framing" }
    private(set) var status = Status.searching
    var onStatus: ((Status) -> Void)?
    private var previousTime: Double?
    private var sourceID = ""
    private var previousAngle: CGFloat = 0
    private var previousMirror = false
    private let fractionalCrop = CameraCropRenderer()
    private var transfer: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var poolFormat: OSType = 0
    private var poolSize = CGSize.zero
    private var levelFailures = 0
    private var retryLevelAt = -Double.infinity
    private(set) var deliveredLevel: HorizonFraming?
    private(set) var sensorTransform = CGAffineTransform.identity
    private(set) var crop = fullFrame
    private var visibleFraming: CameraFraming?
    func visibleFraming(for lens: String) -> CameraFraming? { sourceID == lens ? visibleFraming : nil }
    private(set) var enabled = false
    var onFailure: ((String) -> Void)?
    var onLevelFailure: (() -> Void)?
    var onSettledOff: (() -> Void)?

    init(mediaQueue: DispatchQueue) { detector = DualFaceDetector(mediaQueue: mediaQueue) }

    func setEnabled(_ value: Bool) {
        guard enabled != value else {
            if !value && !returning { onSettledOff?() }
            return
        }
        enabled = value
        returning = !value
        detector.reset()
        setStatus(.searching)
    }
    private func setStatus(_ value: Status) {
        if status != value { status = value; onStatus?(value) }
    }

    func reset() {
        detector.reset()
        levelFailures = 0; retryLevelAt = -.infinity; deliveredLevel = nil
        framing = .init(); crop = Self.fullFrame; sensorTransform = .identity; visibleFraming = nil; previousTime = nil; reserve = 1
        setStatus(.searching)
        sourceID = ""; pool = nil; transfer = nil
    }

    /// One bounded Vision job looks at the full source. The same resulting
    /// sample goes to the preview, effects and writer, including during a take.
    func process(_ sample: CMSampleBuffer, source: String, angle: CGFloat, mirrored: Bool,
                 zoom: CaptureZoomStamp? = nil, level: HorizonFraming? = nil) -> CMSampleBuffer {
        let manual = zoom?.manualCenter
        sensorTransform = .identity; deliveredLevel = nil
        if level == nil { levelFailures = 0; retryLevelAt = -.infinity }
        guard enabled || returning || manual != nil || level != nil, let pixel = sample.imageBuffer else {
            crop = Self.fullFrame; visibleFraming = nil; return sample
        }
        let time = sample.presentationTimeStamp.seconds
        let size = CGSize(width: CVPixelBufferGetWidth(pixel), height: CVPixelBufferGetHeight(pixel))
        if source != sourceID || size != sourceSize || angle != previousAngle || mirrored != previousMirror ||
            (previousTime.map { time < $0 || time - $0 > 0.5 } ?? false) {
            let heldReserve = reserve
            reset(); sourceID = source; previousAngle = angle; previousMirror = mirrored
            sourceSize = size; reserve = heldReserve
        }
        let dt = max(0, min(0.1, time - (previousTime ?? (time - 1.0/30))))
        previousTime = time
        // Ramp both entry and exit over a third of a second. Scaling out
        // progressively restores the whole frame even after an off-centre pan.
        if manual != nil { reserve = 1 }
        else { reserve = enabled ? min(1.20, reserve + 0.6 * dt) : max(1, reserve - 0.6 * dt) }
        let inputZoom = zoom?.zoom ?? 1
        let requested = zoom?.selectedZoom ?? inputZoom
        framing.zoom = max(1, max(requested, (zoom?.minimumZoom ?? 1) * reserve) / inputZoom)
        if !enabled && reserve == 1 && zoom?.selectedZoom == nil {
            if returning { reset(); returning = false; onSettledOff?() }
            if level == nil { crop = Self.fullFrame; visibleFraming = nil; return sample }
        }
        if enabled && manual == nil {
            // Keep a face recognizable when the wide input shows it much
            // smaller than the selected viewport. Jobs still run off the writer.
            let limit: CGFloat = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue ? 768 : 1024
            detector.submit([CIImage(cvPixelBuffer: pixel)], time: time, maximumSide: min(limit, 512 * sqrt(framing.zoom)))
            let face = detector.targets[0].current(at: time)
            setStatus(face != nil ? .following : status == .searching ? .searching : .holding)
            framing = DualFaceFraming.follow(face, source: size,
                region: CGRect(origin: .zero, size: size), current: framing, elapsed: dt)
        }
        let hardware = inputZoom / (zoom?.minimumZoom ?? 1)
        guard framing.zoom > 1.00001 || level != nil else {
            crop = Self.fullFrame; visibleFraming = CameraFraming(zoom: inputZoom); return sample
        }
        let fraction = 1 / framing.zoom
        var rectangle = CGRect(x: (1 - fraction) * framing.x, y: (1 - fraction) * framing.y, width: fraction, height: fraction)
        if let manual, fraction < 1 {
            let target = CameraFraming.oriented(manual, angle: angle, mirrored: mirrored)
            let center = CameraFraming.clamped(CGPoint(x: 0.5 + (target.x - 0.5) * hardware,
                                                       y: 0.5 + (target.y - 0.5) * hardware), fraction: fraction)
            rectangle.origin = CGPoint(x: center.x - fraction / 2, y: center.y - fraction / 2)
            // If the operator enables tracking again, ease out of this composition.
            framing.x = rectangle.minX / (1 - fraction)
            framing.y = rectangle.minY / (1 - fraction)
        }
        let mapping = CGAffineTransform(a: rectangle.width, b: 0, c: 0, d: rectangle.height, tx: rectangle.minX, ty: rectangle.minY)
        var transform = mapping
        var rendered: CMSampleBuffer?
        if let level, time >= retryLevelAt {
            transform = level.sourceTransform(size).concatenating(mapping)
            rendered = resample(sample, pixel: pixel, size: size, crop: rectangle, transform: transform, manual: manual != nil, leveling: true)
            if rendered != nil {
                deliveredLevel = level
                levelFailures = 0
            } else {
                levelFailures += 1
                if levelFailures == 4 { onLevelFailure?() }
                if levelFailures >= 4 { retryLevelAt = time + 1 }
            }
        }
        if rendered == nil {
            transform = mapping
            rendered = rectangle == Self.fullFrame ? sample :
                resample(sample, pixel: pixel, size: size, crop: rectangle, transform: mapping, manual: manual != nil, leveling: false)
        }
        guard let result = rendered else {
            // Preserve this frame (and audio) if a format or resource becomes unavailable.
            enabled = false; returning = false; reset(); onFailure?(source); return sample
        }
        crop = rectangle
        sensorTransform = transform
        let sensor = CGPoint(x: 0.5 + (rectangle.midX - 0.5) / hardware, y: 0.5 + (rectangle.midY - 0.5) / hardware)
        visibleFraming = CameraFraming(zoom: inputZoom / fraction,
                                       center: CameraFraming.sensorPoint(sensor, angle: angle, mirrored: mirrored))
        return result
    }

    private func resample(_ sample: CMSampleBuffer, pixel: CVPixelBuffer, size: CGSize, crop: CGRect, transform: CGAffineTransform, manual: Bool, leveling: Bool) -> CMSampleBuffer? {
        let format = CVPixelBufferGetPixelFormatType(pixel)
        if pool == nil || poolSize != size || poolFormat != format {
            var session: VTPixelTransferSession?
            guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session) == noErr,
                  let session, VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_ScalingMode,
                      value: kVTScalingMode_CropSourceToCleanAperture) == noErr else { return nil }
            let attributes: [String: Any] = [kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height), kCVPixelBufferPixelFormatTypeKey as String: format,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferMetalCompatibilityKey as String: true]
            guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess else { return nil }
            transfer = session; poolSize = size; poolFormat = format
        }
        var destination: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destination) == kCVReturnSuccess,
              let output = destination else { return nil }
        CVBufferRemoveAllAttachments(output)
        if !(manual || leveling) || fractionalCrop?.render(pixel, into: output, transform: transform) != true {
            if leveling { return nil }
            // Use the existing transfer on formats that cannot be bound as Metal
            // textures. Its clean-aperture attachment must never mutate the input.
            guard let transfer, let surface = CVPixelBufferGetIOSurface(pixel)?.takeUnretainedValue() else { return nil }
            var wrapper: Unmanaged<CVPixelBuffer>?
            guard CVPixelBufferCreateWithIOSurface(nil, surface, nil, &wrapper) == kCVReturnSuccess,
                  let view = wrapper?.takeRetainedValue() else { return nil }
            CVBufferPropagateAttachments(pixel, view)
            let aperture: [CFString: CGFloat] = [kCVImageBufferCleanApertureWidthKey: size.width * crop.width,
                kCVImageBufferCleanApertureHeightKey: size.height * crop.height,
                kCVImageBufferCleanApertureHorizontalOffsetKey: (crop.midX - 0.5) * size.width,
                kCVImageBufferCleanApertureVerticalOffsetKey: (crop.midY - 0.5) * size.height]
            CVBufferSetAttachment(view, kCVImageBufferCleanApertureKey, aperture as CFDictionary, .shouldPropagate)
            guard VTPixelTransferSessionTransferImage(transfer, from: view, to: output) == noErr else { return nil }
        }
        // Preserve the camera's color primaries, transfer function and Log tags
        // after transfer, while keeping the output's full, square-pixel viewport.
        if let attachments = CVBufferCopyAttachments(pixel, .shouldPropagate) as? [String: Any] {
            var tags = attachments
            tags.removeValue(forKey: kCVImageBufferCleanApertureKey as String)
            tags.removeValue(forKey: kCVImageBufferPreferredCleanApertureKey as String)
            CVBufferSetAttachments(output, tags as CFDictionary, .shouldPropagate)
        }
        var desc: CMVideoFormatDescription?, timing = CMSampleTimingInfo(), rendered: CMSampleBuffer?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: output, formatDescriptionOut: &desc) == noErr,
              let desc, CMSampleBufferGetSampleTimingInfo(sample, at: 0, timingInfoOut: &timing) == noErr,
              CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: output, formatDescription: desc,
                  sampleTiming: &timing, sampleBufferOut: &rendered) == noErr else { return nil }
        return rendered
    }
}

/// Resample the actual camera planes. Keeping Y and CbCr in their native
/// formats avoids an RGB round trip in both HDR/Log and ordinary SDR takes.
private final class CameraCropRenderer {
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let cache: CVMetalTextureCache

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = try? device.makeDefaultLibrary(bundle: Bundle(for: CameraCropRenderer.self)),
              let function = library.makeFunction(name: "cameraSubpixelCrop"),
              let pipeline = try? device.makeComputePipelineState(function: function) else { return nil }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else { return nil }
        self.queue = queue; self.pipeline = pipeline; self.cache = cache
    }

    private func texture(_ pixel: CVPixelBuffer, plane: Int, format: MTLPixelFormat, usage: MTLTextureUsage) -> CVMetalTexture? {
        let planar = CVPixelBufferIsPlanar(pixel)
        let w = planar ? CVPixelBufferGetWidthOfPlane(pixel, plane) : CVPixelBufferGetWidth(pixel)
        let h = planar ? CVPixelBufferGetHeightOfPlane(pixel, plane) : CVPixelBufferGetHeight(pixel)
        var texture: CVMetalTexture?
        let attributes = [kCVMetalTextureUsage as String: usage.rawValue] as CFDictionary
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixel, attributes, format, w, h, plane, &texture) == kCVReturnSuccess else { return nil }
        return texture
    }

    func render(_ input: CVPixelBuffer, into output: CVPixelBuffer, transform: CGAffineTransform) -> Bool {
        let formats: [MTLPixelFormat]
        var tenBit: UInt32 = 0
        switch CVPixelBufferGetPixelFormatType(input) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            formats = [.r8Unorm, .rg8Unorm]
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr10BiPlanarFullRange:
            formats = [.r16Unorm, .rg16Unorm]; tenBit = 1
        case kCVPixelFormatType_32BGRA: formats = [.bgra8Unorm]
        default: return false
        }
        guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else { return false }
        encoder.setComputePipelineState(pipeline)
        var linear = SIMD4<Float>(Float(transform.a), Float(transform.c), Float(transform.b), Float(transform.d))
        var origin = SIMD2<Float>(Float(transform.tx), Float(transform.ty))
        encoder.setBytes(&linear, length: MemoryLayout.size(ofValue: linear), index: 0)
        encoder.setBytes(&origin, length: MemoryLayout.size(ofValue: origin), index: 2)
        encoder.setBytes(&tenBit, length: MemoryLayout.size(ofValue: tenBit), index: 1)
        var surfaces: [CVMetalTexture] = []
        for (plane, format) in formats.enumerated() {
            guard let source = texture(input, plane: plane, format: format, usage: .shaderRead),
                  let target = texture(output, plane: plane, format: format, usage: .shaderWrite),
                  let read = CVMetalTextureGetTexture(source), let write = CVMetalTextureGetTexture(target) else {
                encoder.endEncoding(); return false
            }
            surfaces.append(contentsOf: [source, target])
            encoder.setTexture(read, index: 0); encoder.setTexture(write, index: 1)
            let group = MTLSize(width: pipeline.threadExecutionWidth, height: 4, depth: 1)
            encoder.dispatchThreads(MTLSize(width: write.width, height: write.height, depth: 1), threadsPerThreadgroup: group)
        }
        encoder.endEncoding()
        return withExtendedLifetime(surfaces) {
            command.commit(); command.waitUntilCompleted()
            return command.status == .completed
        }
    }
}
