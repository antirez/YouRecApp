import UIKit
import AVFoundation

/// Gesture coordinates and the recorder HUD stay fixed while composing a camera move.
final class RecorderZoomViewport: UIView {
    let picture = CameraPreview.Preview()
    private weak var camera: CaptureController?
    private var seconds = 0.0
    private let badge = UILabel()
    private lazy var pinch = FramingGesture(target: self, action: #selector(handlePinch(_:)))
    private var current: Move?
    private var displayLink: CADisplayLink?
    private var widerPicture: AVSampleBufferDisplayLayer?
    private var widerFormat: CMVideoFormatDescription?
    private var widerGeometry: (zoom: Double, angle: CGFloat, mirrored: Bool, size: CGSize, level: HorizonFraming?)?

    private final class Move {
        let token = UUID()
        let lens: String
        let seconds: Double
        var start: CameraFraming?
        var target: CameraFraming?
        var previous: FramingGesture.Contact
        let initial: FramingGesture.Contact
        let wasFollowing: Bool
        var contact: FramingGesture.Contact
        var released = false
        var dragged = false
        var appliedLiveChange = false
        var needsEdges = false
        var requestedWiderInput = false

        init(lens: String, seconds: Double, contact: FramingGesture.Contact, following: Bool) {
            self.lens = lens; self.seconds = seconds
            wasFollowing = following
            initial = contact; previous = contact; self.contact = contact
        }
    }

    private static let grid: UIColor = {
        let size = CGSize(width: 18, height: 18)
        let tile = UIGraphicsImageRenderer(size: size).image { context in
            UIColor(white: 0.10, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor(white: 0.27, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: size.width, height: 0.75))
            context.fill(CGRect(x: 0, y: 0, width: 0.75, height: size.height))
        }
        return UIColor(patternImage: tile)
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = .black
        picture.backgroundColor = .black
        isMultipleTouchEnabled = true; picture.isMultipleTouchEnabled = true
        addSubview(picture)
        badge.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        badge.textColor = .white
        badge.textAlignment = .center
        badge.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        badge.layer.cornerRadius = 14; badge.clipsToBounds = true
        badge.layer.zPosition = 2
        badge.isHidden = true; badge.isUserInteractionEnabled = false
        badge.accessibilityIdentifier = "recorder.pinchZoomTarget"
        addSubview(badge)
        addGestureRecognizer(pinch)
        NotificationCenter.default.addObserver(self, selector: #selector(cancelPinch),
            name: UIApplication.willResignActiveNotification, object: nil)
    }
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        if picture.bounds.size != bounds.size {
            cancelPinch()
            picture.bounds = CGRect(origin: .zero, size: bounds.size)
        }
        picture.center = CGPoint(x: bounds.midX, y: bounds.midY)
        badge.center = CGPoint(x: bounds.midX, y: bounds.height * 0.27)
    }

    func configure(camera: CaptureController, seconds: Double) {
        self.camera = camera
        self.seconds = ZoomTransition.boundedDuration(seconds)
        let enabled = camera.ready && !camera.busy && !camera.switchingCamera && !camera.dualActive
            && camera.maxZoom > camera.minZoom && camera.positioningEffectID == nil
            && camera.effectColorPick == nil && camera.cleanPlateCountdown == nil && camera.cleanPlateProgress == nil
        if let current, !enabled || current.lens != camera.cameraID { cancelPinch() }
        if pinch.isEnabled != enabled { pinch.isEnabled = enabled }
    }

    @objc func cancelPinch() {
        guard current != nil else { return }
        cancelMove()
        // Drop the rest of this touch sequence, including an end from the old lens.
        pinch.isEnabled = false; pinch.isEnabled = true
    }

    private func reset(committing: Bool = false) {
        if let move = current, move.seconds > 0 {
            camera?.finishFramingPreview(move.token, on: move.lens, committing: committing ? move.target : nil)
        }
        displayLink?.invalidate(); displayLink = nil
        widerPicture?.removeFromSuperlayer(); widerPicture = nil; widerFormat = nil; widerGeometry = nil
        current = nil
        picture.transform = .identity; backgroundColor = .black
        badge.isHidden = true
    }
    private func cancelMove() {
        if let move = current, move.seconds == 0 { camera?.finishLiveFraming(on: move.lens) }
        reset()
    }

    @objc private func handlePinch(_ gesture: FramingGesture) {
        guard let camera else { return }
        switch gesture.state {
        case .began:
            let move = Move(lens: camera.cameraID, seconds: seconds, contact: gesture.initial, following: camera.faceFollowEnabled)
            current = move
            if seconds > 0 { camera.framingSource.begin(move.token, lens: move.lens) }
            move.contact = gesture.contact
            camera.beginPinchZoom(on: move.lens) { [weak self] start in
                guard let self, self.current === move else { return }
                guard let start, start.zoom > 0 else { self.reset(); return }
                move.start = start; move.target = start
                self.update(move)
            }
        case .changed, .ended:
            guard let move = current else { return }
            move.contact = gesture.contact; move.released = gesture.state == .ended
            update(move)
        case .cancelled, .failed: cancelMove()
        default: break
        }
    }

    private func update(_ move: Move) {
        guard let camera, let start = move.start, let previous = move.target else { return }
        guard camera.cameraID == move.lens, !camera.switchingCamera, !camera.dualActive else { reset(); return }
        let image = imageRect(for: camera.previewLayoutCanvas)
        guard image.width > 0, image.height > 0 else { reset(); return }
        let angle = camera.previewRotationAngle, mirror = camera.frontPreviewMirrored
        func displayed(_ point: CGPoint) -> CGPoint { CameraFraming.oriented(point, angle: angle, mirrored: mirror) }
        let old = move.previous, next = move.contact
        // A parallel drag naturally jitters a few pixels in span. Ease out
        // of that small neutral zone without a zoom step when the pinch starts.
        // Measure against the start even when the gesture runs past a lens
        // limit. A small change in finger pressure there mustn't reverse zoom.
        let stops = log(next.span / move.initial.span)
        let t = max(0, min(1, (abs(stops) - 0.022) / 0.033))
        let zoom = min(camera.maxZoom, max(camera.minZoom, start.zoom * exp(stops * t * t * (3 - 2 * t))))
        let from = camera.minZoom / previous.zoom, to = camera.minZoom / zoom
        let oldCenter = displayed(previous.center)
        // The point under the previous midpoint stays under the new midpoint,
        // even when both fingers move in parallel or reverse at the lens edge.
        let leveled = camera.framingSource.screenTransform(lens: move.lens, mirrored: mirror)
        let offset = CGPoint(x: (old.mid.x - image.midX) * from - (next.mid.x - image.midX) * to,
                             y: (old.mid.y - image.midY) * from - (next.mid.y - image.midY) * to).applying(leveled.inverted())
        let proposed = CGPoint(x: oldCenter.x + offset.x / image.width, y: oldCenter.y + offset.y / image.height)
        let distance = hypot(next.mid.x - move.initial.mid.x, next.mid.y - move.initial.mid.y)
        let takeoverDistance = max(14, min(30, abs(next.span - move.initial.span) * 0.3))
        move.dragged = move.dragged || distance >= takeoverDistance
        let following = move.wasFollowing && !move.dragged
        let center = following ? previous.center : CameraFraming.sensorPoint(CameraFraming.clamped(proposed, fraction: to), angle: angle, mirrored: mirror)
        let target = CameraFraming(zoom: zoom, center: center)
        move.target = target; move.previous = next
        let ratio = zoom / start.zoom
        let source = displayed(start.center), dest = displayed(center)
        let translation = CGPoint(x: (source.x - dest.x) * image.width / to,
                                  y: (source.y - dest.y) * image.height / to).applying(leveled)
        let dx = translation.x, dy = translation.y
        let changed = abs(ratio - 1) > 0.005 || hypot(dx, dy) > 0.75
        if move.released {
            reset(committing: changed)
            if changed || move.appliedLiveChange {
                camera.setZoom(zoom, seconds: move.seconds, on: move.lens, center: following ? nil : center)
            }
            return
        }
        if move.seconds == 0 {
            if target != previous {
                move.appliedLiveChange = true
                camera.setZoom(zoom, seconds: 0, on: move.lens, persist: false, center: following ? nil : center)
            }
        } else {
            picture.transform = CGAffineTransform(a: ratio, b: 0, c: 0, d: ratio, tx: dx, ty: dy)
            backgroundColor = Self.grid
            let projected = CGRect(x: image.midX - image.width * ratio / 2 + dx,
                                   y: image.midY - image.height * ratio / 2 + dy,
                                   width: image.width * ratio, height: image.height * ratio)
            move.needsEdges = !projected.insetBy(dx: -0.5, dy: -0.5).contains(bounds)
            if move.needsEdges && displayLink == nil {
                displayLink = CADisplayLink(target: self, selector: #selector(showWiderPicture))
                displayLink?.add(to: .main, forMode: .common)
            }
            showWiderPicture()
        }
        let magnification = String(format: "%.1f×", zoom * camera.displayZoomMultiplier)
        let text: String
        if move.dragged && zoom <= camera.minZoom + 0.001 && !changed {
            text = "Zoom in to pan"
        } else if move.wasFollowing && move.dragged {
            text = move.seconds == 0 ? "\(magnification)  ·  Manual framing" : "\(magnification)  ·  Manual on release"
        } else {
            text = move.seconds == 0 ? magnification : "\(magnification)  ·  \(move.seconds.formatted())s on release"
        }
        if badge.text != text || badge.isHidden {
            badge.text = text
            badge.bounds.size = CGSize(width: badge.intrinsicContentSize.width.rounded(.up) + 20, height: 28)
            badge.isHidden = false
        }
    }

    private func imageRect(for canvas: CGSize?) -> CGRect {
        guard let canvas, canvas.width > 0, canvas.height > 0 else { return bounds }
        let x = bounds.width / canvas.width, y = bounds.height / canvas.height
        let scale = picture.previewLayer.videoGravity == .resizeAspectFill ? max(x, y) : min(x, y)
        let size = CGSize(width: canvas.width * scale, height: canvas.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    @objc private func showWiderPicture() {
        guard let camera, let move = current, move.needsEdges, let target = move.target else {
            widerPicture?.isHidden = true; return
        }
        if let frame = camera.framingSource.take(move.token) {
            guard frame.zoom > 0 else {
                widerPicture?.isHidden = true; widerGeometry = nil; return
            }
            if widerPicture == nil {
                let display = AVSampleBufferDisplayLayer()
                display.videoGravity = .resize; display.isHidden = true
                layer.insertSublayer(display, below: picture.layer)
                widerPicture = display
            }
            if widerPicture?.enqueueCameraPixel(frame.pixel, format: &widerFormat) == true {
                widerGeometry = (frame.zoom, frame.angle, frame.mirrored,
                                 CGSize(width: CVPixelBufferGetWidth(frame.pixel), height: CVPixelBufferGetHeight(frame.pixel)), frame.level)
            }
        }
        guard let display = widerPicture, let source = widerGeometry else { return }
        if #available(iOS 17.4, *), !display.isReadyForDisplay { return }
        let image = imageRect(for: camera.previewLayoutCanvas)
        let angle = (camera.previewRotationAngle - source.angle) * .pi / 180
        let sideways = abs(sin(angle)) > 0.5
        let sensorSize = sideways ? CGSize(width: source.size.height, height: source.size.width) : source.size
        // Different-aspect clips use the writer's aspect fit. Don't stretch a
        // live frame to fill any real letterbox in the composition.
        let content = AVMakeRect(aspectRatio: sensorSize, insideRect: image)
        let scale = target.zoom / source.zoom
        let w = content.width * scale, h = content.height * scale
        let center = CameraFraming.oriented(target.center, angle: camera.previewRotationAngle, mirrored: camera.frontPreviewMirrored)
        let fraction = camera.minZoom / target.zoom
        let completeLook = !camera.videoEffects.contains(where: \.enabled) && !camera.focusPeaking && camera.activeLog == nil
        CATransaction.begin(); CATransaction.setDisableActions(true)
        display.bounds = CGRect(origin: .zero, size: sideways ? CGSize(width: h, height: w) : CGSize(width: w, height: h))
        let flip = source.mirrored != camera.frontPreviewMirrored
        let leveled = source.level?.screenTransform(flip: flip) ?? .identity
        let offset = CGPoint(x: (0.5 - center.x) * content.width / fraction,
                             y: (0.5 - center.y) * content.height / fraction).applying(leveled)
        display.position = CGPoint(x: content.midX + offset.x, y: content.midY + offset.y)
        display.setAffineTransform(CGAffineTransform(rotationAngle: angle)
            .concatenating(CGAffineTransform(scaleX: flip ? -1 : 1, y: 1)).concatenating(leveled))
        // Keep the processed/peaking picture over its real, wider surroundings.
        display.zPosition = completeLook ? 1 : -0.1
        display.isHidden = false
        CATransaction.commit()
        // Present the original field of view first. The same surface follows
        // the subsequent sensor handoff, so the native preview cannot flash wide.
        if !move.requestedWiderInput {
            move.requestedWiderInput = true
            camera.widenFramingPreview(move.token, on: move.lens)
        }
    }
}

/// A single two-finger gesture owns translation and scale. Parallel travel
/// can start it, and ending either finger commits exactly once.
private final class FramingGesture: UIGestureRecognizer {
    struct Contact {
        var mid = CGPoint.zero
        var span: CGFloat = 1
    }
    private var fingers = Set<UITouch>()
    private(set) var initial = Contact(), contact = Contact()
    private func sample() -> Contact {
        let points = fingers.map { $0.location(in: view) }
        let a = points[0], b = points[1]
        return Contact(mid: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), span: max(1, hypot(a.x - b.x, a.y - b.y)))
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        fingers.formUnion(touches)
        if fingers.count > 2 { state = state == .possible ? .failed : .cancelled }
        else if fingers.count == 2 { initial = sample(); contact = initial }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard fingers.count == 2 else { return }
        contact = sample()
        if state == .possible {
            if abs(contact.span - initial.span) > 3 || hypot(contact.mid.x - initial.mid.x, contact.mid.y - initial.mid.y) > 3 { state = .began }
        } else if state == .began || state == .changed { state = .changed }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if state == .began || state == .changed {
            if fingers.count == 2 { contact = sample() }
            state = .ended
        } else if state == .possible { state = .failed }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = state == .possible ? .failed : .cancelled
    }
    override func reset() { super.reset(); fingers.removeAll() }
}


extension AVSampleBufferDisplayLayer {
    /// Share pixel storage and color metadata with the camera. Display-immediate
    /// belongs on a new sample; the writer keeps its original timing.
    func enqueueCameraPixel(_ pixel: CVPixelBuffer, format: inout CMVideoFormatDescription?, presentAt: CFTimeInterval? = nil) -> Bool {
        let renderer = sampleBufferRenderer
        if renderer.requiresFlushToResumeDecoding || renderer.status == .failed { renderer.flush() }
        guard renderer.isReadyForMoreMediaData else { return false }
        if format.map({ CMVideoFormatDescriptionMatchesImageBuffer($0, imageBuffer: pixel) }) != true {
            guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixel, formatDescriptionOut: &format) == noErr else { return false }
        }
        let time = presentAt.map { CMTime(seconds: $0, preferredTimescale: 1_000_000) } ?? CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard let description = format, CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixel, formatDescription: description,
            sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return false }
        if presentAt == nil, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let flags = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(flags, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        renderer.enqueue(sample)
        return true
    }
}

/// A single uncropped sample, only while a timed gesture is being composed.
/// A slow display never queues camera buffers or blocks the writer.
final class CameraFramingSource: @unchecked Sendable {
    struct Frame {
        let pixel: CVPixelBuffer
        let angle: CGFloat
        let mirrored: Bool
        let zoom: Double
        let level: HorizonFraming?
    }
    private var leveling: (lens: String, mirrored: Bool, framing: HorizonFraming)?
    private let lock = NSLock()
    private var owner: (token: UUID, lens: String)?
    private var latest: Frame?

    func begin(_ token: UUID, lens: String) {
        lock.lock(); defer { lock.unlock() }
        owner = (token, lens); latest = nil
    }
    func isActive(_ token: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }; return owner?.token == token
    }
    func end(_ token: UUID) {
        lock.lock(); defer { lock.unlock() }
        if owner?.token == token { owner = nil; latest = nil }
    }
    func screenTransform(lens: String, mirrored: Bool) -> CGAffineTransform {
        lock.lock(); defer { lock.unlock() }
        guard let leveling, leveling.lens == lens else { return .identity }
        return leveling.framing.screenTransform(flip: mirrored != leveling.mirrored)
    }
    func offer(_ pixel: CVPixelBuffer, lens: String, angle: CGFloat, mirrored: Bool, zoom: Double, level: HorizonFraming?) {
        lock.lock(); defer { lock.unlock() }
        leveling = level.map { (lens, mirrored, $0) }
        guard owner?.lens == lens else { return }
        latest = Frame(pixel: pixel, angle: angle, mirrored: mirrored, zoom: zoom, level: level)
    }
    func take(_ token: UUID) -> Frame? {
        lock.lock(); defer { lock.unlock() }
        guard owner?.token == token else { return nil }
        let frame = latest; latest = nil; return frame
    }
}
