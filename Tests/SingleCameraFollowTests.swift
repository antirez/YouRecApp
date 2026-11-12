import AVFoundation
import CoreImage
import Foundation
import Vision

#if os(iOS)
import XCTest

final class SingleCameraFollowDeviceTests: XCTestCase {
    func testMovingFaceAndRecordedPixels() throws {
        let portrait = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "astronaut", withExtension: "png"))
        try SingleCameraFollowTests.run(portrait)
    }
}
#else
@main enum SingleCameraFollowRunner {
    static func main() throws {
        try SingleCameraFollowTests.run(URL(fileURLWithPath: "Tests/Fixtures/astronaut.png"))
    }
}
#endif

enum SingleCameraFollowTests {
    static func check(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: "SingleCameraFollow", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static func run(_ portrait: URL) throws {
        try checkFrameZoom()
        try checkHorizon()
        let media = DispatchQueue(label: "test.single-camera.media")
        let follow = SingleCameraFaceFollow(mediaQueue: media)
        let context = CIContext(options: [.cacheIntermediates: false])
        let size = CGSize(width: 640, height: 360), bounds = CGRect(origin: .zero, size: size)
        let photo = CIImage(contentsOf: portrait)!
            .transformed(by: CGAffineTransform(scaleX: 0.43, y: 0.43))
        let background = CIImage(color: CIColor(red: 0.12, green: 0.18, blue: 0.25)).cropped(to: bounds)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        func buffer(_ x: CGFloat, _ y: CGFloat, format: OSType = kCVPixelFormatType_32BGRA,
                    encodedSpace: CGColorSpace? = nil) throws -> CVPixelBuffer {
            let placed = photo.transformed(by: CGAffineTransform(translationX: x, y: y)).composited(over: background).cropped(to: bounds)
            var pixel: CVPixelBuffer?
            let options = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary
            try check(CVPixelBufferCreate(nil, Int(size.width), Int(size.height), format, options, &pixel) == kCVReturnSuccess, "fixture buffer")
            if encodedSpace != nil {
                CVBufferSetAttachment(pixel!, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
                CVBufferSetAttachment(pixel!, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
                CVBufferSetAttachment(pixel!, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
            }
            context.render(placed, to: pixel!, bounds: bounds, colorSpace: encodedSpace ?? space)
            return pixel!
        }
        var index: Int64 = 0
        func frame(_ pixel: CVPixelBuffer) throws -> CMSampleBuffer {
            var desc: CMVideoFormatDescription?, sample: CMSampleBuffer?
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                            presentationTimeStamp: CMTime(value: index, timescale: 30), decodeTimeStamp: .invalid)
            index += 1
            try check(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixel, formatDescriptionOut: &desc) == noErr, "fixture description")
            try check(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixel, formatDescription: desc!,
                sampleTiming: &timing, sampleBufferOut: &sample) == noErr, "fixture timing")
            return sample!
        }
        func feed(_ pixel: CVPixelBuffer, count: Int, zoom: CaptureZoomStamp? = nil) throws -> (sample: CMSampleBuffer, crop: CGRect) {
            var last: CMSampleBuffer?
            for _ in 0..<count {
                let input = try frame(pixel)
                last = media.sync { follow.process(input, source: "fixture", angle: 0, mirrored: false, zoom: zoom) }
                try check(last?.presentationTimeStamp == input.presentationTimeStamp, "The camera timestamp must survive reframing")
                if count > 20 { Thread.sleep(forTimeInterval: 0.025) }
            }
            return (last!, media.sync { follow.crop })
        }
        func bytes(_ image: CIImage) -> [UInt8] {
            var data = [UInt8](repeating: 0, count: 160*90*4)
            let reduced = image.transformed(by: CGAffineTransform(scaleX: 0.25, y: 0.25))
            context.render(reduced, toBitmap: &data, rowBytes: 640, bounds: CGRect(x: 0, y: 0, width: 160, height: 90), format: .RGBA8, colorSpace: space)
            return data
        }
        func validatePixels(_ input: CVPixelBuffer, _ output: CVPixelBuffer, crop: CGRect) throws {
            let source = CIImage(cvPixelBuffer: input)
            let roi = CGRect(x: crop.minX * size.width, y: (1-crop.maxY) * size.height,
                             width: crop.width * size.width, height: crop.height * size.height)
            let expected = source.cropped(to: roi).transformed(by: CGAffineTransform(translationX: -roi.minX, y: -roi.minY))
                .transformed(by: CGAffineTransform(scaleX: 1/crop.width, y: 1/crop.height))
            let actual = bytes(CIImage(cvPixelBuffer: output))
            let error = zip(actual, bytes(expected)).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
            let mean = Double(error)/Double(actual.count)
            print("Source crop",crop,"mean pixel error",mean)
            try check(mean < 2, "Transferred pixels must match an independently cropped image, including vertical direction")
        }
        let left = try buffer(15, 142), right = try buffer(380, -120)
        // Exercise the native camera shader and the exact geometry used by the dual-camera compositor.
        for degrees in [-6.0, 6.0] {
            let level = HorizonFraming(radians: degrees * .pi/180, magnification: HorizonFraming.scale(maxDegrees: 6, size: size))
            let sample = try frame(left)
            let result = media.sync { follow.process(sample, source: "fixture", angle: 0, mirrored: false, level: level) }
            try check(result !== sample && result.presentationTimeStamp == sample.presentationTimeStamp, "Level the recorded frame at its original timestamp")
            let expected = CIImage(cvPixelBuffer: left).transformed(by: level.imageTransform(bounds)).cropped(to: bounds)
            let error = zip(bytes(CIImage(cvPixelBuffer: result.imageBuffer!)), bytes(expected)).reduce(0) { $0 + abs(Int($1.0)-Int($1.1)) }
            try check(Double(error)/Double(160*90*4) < 2, "Single and dual cameras should rotate and crop the same pixels")
        }
        var unsupported: CVPixelBuffer?
        try check(CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_OneComponent8,
                                      [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &unsupported) == kCVReturnSuccess,
                  "Create a buffer outside the camera shader’s formats")
        let level = HorizonFraming(radians: 0.03, magnification: 1.1)
        var notices = 0
        follow.onLevelFailure = { notices += 1 }
        for i in 0..<7 {
            let input = try frame(unsupported!)
            let output = media.sync { follow.process(input, source: "fixture", angle: 0, mirrored: false, level: level) }
            try check(output === input && notices == (i >= 3 ? 1 : 0), "Retain the timestamped frame and warn once after repeated failures")
        }
        for _ in 0..<40 {
            let input = try frame(left)
            _ = media.sync { follow.process(input, source: "fixture", angle: 0, mirrored: false, level: level) }
        }
        try check(follow.deliveredLevel != nil && notices == 1, "Recover the selected assist after a format or resource becomes available")
        follow.onLevelFailure = nil
        let testYUV = try buffer(200, 40, format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        var previousLuma: Data?
        for i in 0...8 {
            let point = CGPoint(x: 0.5 + Double(i) * 0.25 / size.width, y: 0.5)
            let stamp = CaptureZoomStamp(time: 0, zoom: 1, lens: "fixture", selectedZoom: 2, manualCenter: point)
            let rendered = try feed(testYUV, count: 1, zoom: stamp).sample.imageBuffer!
            CVPixelBufferLockBaseAddress(rendered, .readOnly)
            let luma = Data(bytes: CVPixelBufferGetBaseAddressOfPlane(rendered, 0)!,
                            count: CVPixelBufferGetBytesPerRowOfPlane(rendered, 0) * CVPixelBufferGetHeightOfPlane(rendered, 0))
            CVPixelBufferUnlockBaseAddress(rendered, .readOnly)
            try check(luma != previousLuma, "A quarter-pixel pan must move the image on every frame")
            previousLuma = luma
        }
        let plain = try frame(left)
        try check(media.sync { follow.process(plain, source: "fixture", angle: 0, mirrored: false) === plain }, "Disabled follow passes through the exact camera sample")
        // A pan selects pixels from the full lens even with face detection off.
        // Pixel-aligned landmarks isolate rotation and mirror errors from interpolation.
        let center = CGPoint(x: 0.375, y: 0.75)
        let stamp = CaptureZoomStamp(time: 0, zoom: 1, lens: "fixture", selectedZoom: 2, manualCenter: center)
        for angle: CGFloat in [0, 90, 180, 270] {
            for mirror in [false, true] {
                let sample = try frame(left)
                let result = media.sync { follow.process(sample, source: "fixture", angle: angle, mirrored: mirror, zoom: stamp) }
                let target = CameraFraming.oriented(center, angle: angle, mirrored: mirror)
                try check(abs(follow.crop.midX - target.x) < 1e-6 && abs(follow.crop.midY - target.y) < 1e-6,
                          "Move the saved crop in the correct direction on either camera")
                let restored = CameraFraming.sensorPoint(target, angle: angle, mirrored: mirror)
                try check(hypot(restored.x - center.x, restored.y - center.y) < 1e-6, "Sensor and preview coordinates round-trip")
                try validatePixels(left, result.imageBuffer!, crop: follow.crop)
            }
        }
        let changingLensZoom = CaptureZoomStamp(time: 0, zoom: 1.3, lens: "fixture", selectedZoom: 2, manualCenter: center)
        let compensated = try feed(left, count: 1, zoom: changingLensZoom)
        try check(abs(compensated.crop.width - 0.65) < 1e-6 && compensated.crop.minX >= 0 &&
                  compensated.crop.maxY <= 1, "Clamp to available pixels during hardware zoom handoff")
        let widest = try feed(left, count: 1)
        try check(widest.crop == SingleCameraFaceFollow.fullFrame && widest.sample.imageBuffer === left,
                  "At the widest setting, stop resampling and return the exact source")
        media.sync { follow.reset() }
        media.sync { follow.setEnabled(true) }
        let first = try feed(left, count: 75)
        try check(first.crop.minX < 0.045 && first.crop.minY < 0.045, "Vision should bring an upper-left face toward center")
        try validatePixels(left, first.sample.imageBuffer!, crop: first.crop)
        let next = try feed(right, count: 90)
        try check(next.crop.minX > 0.12 && next.crop.minY > 0.12, "Reacquire a face at lower right")
        try validatePixels(right, next.sample.imageBuffer!, crop: next.crop)
        let swapped = try frame(right)
        let afterSwitch = media.sync {
            _ = follow.process(swapped, source: "other lens", angle: 90, mirrored: true)
            return follow.crop
        }
        try check(abs(afterSwitch.width-next.crop.width) < 0.0001 && abs(afterSwitch.midX-0.5) < 0.001,
                  "A camera switch reacquires the face without replaying the zoom ramp")
        media.sync { follow.setEnabled(false) }
        let leave = try feed(right, count: 1), off = try feed(right, count: 15)
        try check(leave.crop.width > next.crop.width && leave.crop.width < 1, "Smooth return after switching off during a take")
        try check(off.crop == SingleCameraFaceFollow.fullFrame && off.sample.imageBuffer === right, "Recover the full frame and the original capture path")
        let tenBit = try buffer(20, 120, format: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        CVBufferSetAttachment(tenBit, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
        let manualHDR = try feed(tenBit, count: 1, zoom: stamp).sample.imageBuffer!
        try check((CVBufferCopyAttachment(manualHDR, kCVImageBufferTransferFunctionKey, nil) as? String) == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String,
                  "Keep HLG metadata on subpixel camera moves")
        CVPixelBufferLockBaseAddress(manualHDR, .readOnly)
        let words = CVPixelBufferGetBaseAddressOfPlane(manualHDR, 0)!.assumingMemoryBound(to: UInt16.self)
        let row = CVPixelBufferGetBytesPerRowOfPlane(manualHDR, 0) / 2
        var msbAligned = true, hasTenBitDetail = false
        for y in stride(from: 0, to: CVPixelBufferGetHeightOfPlane(manualHDR, 0), by: 3) {
            for x in stride(from: 0, to: CVPixelBufferGetWidthOfPlane(manualHDR, 0), by: 3) {
                let code = words[y * row + x]
                msbAligned = msbAligned && code & 63 == 0
                hasTenBitDetail = hasTenBitDetail || (code >> 6) & 3 != 0
            }
        }
        CVPixelBufferUnlockBaseAddress(manualHDR, .readOnly)
        try check(msbAligned && hasTenBitDetail, "Write native ten-bit samples in the high ten bits of each word")
        media.sync { follow.setEnabled(true) }
        let hdr = try feed(tenBit, count: 12).sample.imageBuffer!
        try check(hdr !== tenBit && CVPixelBufferGetPixelFormatType(hdr) == CVPixelBufferGetPixelFormatType(tenBit), "Keep native ten-bit samples")
        try check((CVBufferCopyAttachment(hdr, kCVImageBufferTransferFunctionKey, nil) as? String) == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String, "Keep HDR transfer metadata")
        // Both faces can be acquired from the wide feed even when outside the
        // previously visible 2x frame. Verify their positions in the actual output.
        let two = CaptureZoomStamp(time: 0, zoom: 1, lens: "fixture", selectedZoom: 2)
        func faceCenter(_ pixel: CVPixelBuffer) throws -> CGPoint {
            let request = VNDetectFaceRectanglesRequest()
            try VNImageRequestHandler(cvPixelBuffer: pixel, options: [:]).perform([request])
            guard let face = request.results?.first else { throw NSError(domain: "Missing portrait", code: 2) }
            return CGPoint(x: face.boundingBox.midX, y: 1 - face.boundingBox.midY)
        }
        let leftAtTwo = try feed(left, count: 75, zoom: two)
        let rightPoint = try faceCenter(right)
        try check(!leftAtTwo.crop.contains(rightPoint), "The second face starts outside the first 2x viewport")
        let rightAtTwo = try feed(right, count: 100, zoom: two)
        for (input, result) in [(left,leftAtTwo), (right,rightAtTwo)] {
            let point = try faceCenter(input), output = try faceCenter(result.sample.imageBuffer!)
            try check(abs(result.crop.width - 0.5) < 0.001, "Follow uses 2x framing without an additional crop")
            let closestX = min(0.75, max(0.25, point.x))
            let closestY = min(0.75, max(0.25, point.y))
            try check(abs(result.crop.midX-closestX) < 0.032 && abs(result.crop.midY-closestY) < 0.032, "Center the subject up to the sensor edges")
            try check(abs(output.x-(point.x-result.crop.minX)/result.crop.width) < 0.035 &&
                      abs(output.y-(point.y-result.crop.minY)/result.crop.height) < 0.035, "The tracked face lands inside the saved viewport")
            try validatePixels(input, result.sample.imageBuffer!, crop: result.crop)
        }
        let emptyScene = try buffer(2000, 2000)
        let lost = try feed(emptyScene, count: 55, zoom: two)
        try check(media.sync { follow.status == .holding }, "Report losing the face")
        try check(abs(lost.crop.midX-rightAtTwo.crop.midX) < 0.01, "Hold the crop when the face leaves the lens")
        let reappeared = try feed(left, count: 70, zoom: two)
        try check(reappeared.crop.midX < 0.30 && media.sync { follow.status == .following }, "Find a returning face outside the held crop")
        let hdrPortrait = try buffer(380, -120, format: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                                     encodedSpace: CGColorSpace(name: CGColorSpace.itur_2100_HLG)!)
        let hdrFace = try feed(hdrPortrait, count: 95, zoom: two)
        try check(hdrFace.crop.midX > 0.69 && media.sync { follow.status == .following }, "Reacquire from native 10-bit HLG pixels at 2x")
        let ramp = CaptureZoomHistory()
        ramp.record(time: 1, zoom: 1, lens: "front")
        ramp.record(time: 1.1, zoom: 2, lens: "front")
        try check(abs((ramp.frame(at: 1.05, latency: 0, interpolate: true)?.zoom ?? 0)-sqrt(2)) < 0.001, "Match a frame between two native ramp readings")
        ramp.record(time: 2, zoom: 3, lens: "front")
        try check(ramp.frame(at: 1.98, latency: 0, interpolate: true)?.zoom == 3, "Start a new handoff with current lens readings")
        let motion = CaptureZoomHistory()
        let move = ZoomTransition(start: 2, target: 3, began: 10, duration: 2,
                                  startCenter: .init(x: 0.5, y: 0.5), targetCenter: .init(x: 0.36, y: 0.60))
        for t in [10.0, 10.08, 10.11, 10.27, 10.63, 10.65, 10.9, 11.5] {
            motion.record(time: t, zoom: 1, lens: "rear", selectedZoom: move.value(at: t),
                          manualCenter: move.center(at: t), manualMove: move)
        }
        for i in 1...60 {
            let pts = 10 + Double(i) / 30
            let frame = motion.frame(at: pts)
            try check(frame?.manualCenter == move.center(at: pts) && frame?.selectedZoom == move.value(at: pts),
                      "Render every recorded frame on its curve despite irregular command delivery")
        }
        motion.record(time: 14, zoom: 1, lens: "rear", selectedZoom: 2, manualCenter: .init(x: 0.5, y: 0.5))
        motion.record(time: 14.04, zoom: 1, lens: "rear", selectedZoom: 2, manualCenter: .init(x: 0.4, y: 0.5))
        try check(abs((motion.frame(at: 14.02)?.manualCenter?.x ?? 0) - 0.45) < 1e-6,
                  "Place an immediate drag between its actual touch samples")
        print("PASS wide-source 2x tracking across opposite edges", leftAtTwo.crop, rightAtTwo.crop)
        print("PASS single-camera Vision following, moving crop, exit ramp, timestamps and HDR")
    }
    private static func checkHorizon() throws {
        let rad = Double.pi/180
        try check(HorizonFraming.defaultDegrees == 9 && HorizonFraming.degrees(3) == 3, "Start at 9° and respect a chosen smaller angle")
        for size in [CGSize(width: 1920, height: 1080), CGSize(width: 1080, height: 1920)] {
            for limit in [0.5, 3, 10] {
                let scale = HorizonFraming.scale(maxDegrees: limit, size: size)
                for roll in [-limit, 0, limit] {
                    let map = HorizonFraming(radians: roll*rad, magnification: scale).sourceTransform(size)
                    for point in [CGPoint.zero, CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1)] {
                        let input = point.applying(map)
                        try check(input.x >= -1e-8 && input.y >= -1e-8 && input.x <= 1.00000001 && input.y <= 1.00000001,
                                  "The fixed crop must cover all four corners throughout the correction range")
                    }
                }
            }
        }
        for rotation in [0.0, 90, 180, 270] {
            let a = 5*rad - (rotation-90)*rad
            for mirrored in [false, true] {
                let roll = HorizonEstimate.roll(x: -sin(a), y: -cos(a), rotation: rotation, mirrored: mirrored)
                try check(abs((roll ?? 10)-(mirrored ? -5 : 5)*rad) < 1e-7, "Gravity must follow the delivered camera axes")
                let locked = HorizonEstimate.roll(x: -sin(a + .pi/2), y: -cos(a + .pi/2), rotation: rotation, mirrored: mirrored)
                try check(abs((roll ?? 10)-(locked ?? 20)) < 1e-7, "A quarter-turned locked interface must correct the small tilt, even at 90°")
            }
        }
        try check(HorizonEstimate.roll(x: 0.02, y: 0.01, rotation: 90, mirrored: false) == nil, "Ignore unreliable roll looking straight up")
        let width = 192, height = 108
        func edge(_ angle: Double) -> [UInt8] {
            (0..<(width*height)).map { i in
                let edge = Double(height/2) + Double(i%width-width/2)*tan(angle*rad)
                return Double(i/width) >= edge ? 200 : 30
            }
        }
        for degrees in [-5.0, 0, 5] {
            let measured = HorizonLine.estimate(edge(degrees), width: width, height: height)
            try check(abs((measured ?? 100)/rad - degrees) <= 0.8, "Recognize the actual angle of a long edge")
        }
        // A portrait dual composition receives a landscape sensor buffer. A
        // vertical edge in that buffer becomes the horizon in the final image.
        var sideways: CVPixelBuffer?
        try check(CVPixelBufferCreate(nil, height, width, kCVPixelFormatType_32BGRA, nil, &sideways) == kCVReturnSuccess, "Create sideways input")
        let sensor = sideways!
        CVPixelBufferLockBaseAddress(sensor, [])
        let bytes = CVPixelBufferGetBaseAddress(sensor)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(sensor)
        let upright = edge(5)
        for y in 0..<width {
            for x in 0..<height {
                let value = upright[x*width + width-1-y]
                let index = y*stride + x*4
                bytes[index] = value; bytes[index+1] = value; bytes[index+2] = value; bytes[index+3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(sensor, [])
        let portraitLine = HorizonLine.estimate(sensor, sidewaysInput: true)
        try check(abs((portraitLine ?? 100)/rad - 5) <= 0.8, "Find the horizon in the portrait dual camera composition")
        try check(HorizonLine.estimate(edge(26), width: width, height: height) == nil, "Ignore strong perspective diagonals")
        var estimate = HorizonEstimate()
        for i in 0..<120 {
            let t = Double(i)/30
            if i.isMultiple(of: 9) { estimate.observe(line: 4*rad, gravity: 3*rad, at: t) }
            _ = estimate.correction(gravity: 3*rad, time: t, maxDegrees: 10, stabilized: false)
        }
        try check(abs(estimate.correction(gravity: 3*rad, time: 4, maxDegrees: 10, stabilized: false)/rad - 4) < 0.1,
                  "A persistent close visual horizon can refine gravity")
        estimate.observe(line: nil, gravity: 3*rad, at: 4.01)
        try check(estimate.correction(gravity: 3*rad, time: 4.02, maxDegrees: 10, stabilized: false) > 3.9*rad,
                  "A passing object must not suddenly remove the visual correction")
        for i in 1...100 { _ = estimate.correction(gravity: -20*rad, time: 4+Double(i)/30, maxDegrees: 3, stabilized: true) }
        let limited = estimate.correction(gravity: -20*rad, time: 7.4, maxDegrees: 3, stabilized: true)
        try check(limited >= -3*rad && limited < -2.95*rad, "Ease into the selected correction limit")
        let reduced = estimate.correction(gravity: -20*rad, time: 7.41, maxDegrees: 0.5, stabilized: true)
        try check(abs(reduced) <= 0.5*rad, "Reducing the live angle limit must immediately fit inside the smaller crop")
        for i in 1...100 { _ = estimate.correction(gravity: nil, time: 7.4+Double(i)/30, maxDegrees: 3, stabilized: false) }
        try check(abs(estimate.correction(gravity: nil, time: 11, maxDegrees: 3, stabilized: false)) < 0.01*rad,
                  "Ease back to neutral when gravity cannot define a horizon")
        print("PASS horizon geometry, visual consensus, limiting and orientation")
    }
    private static func checkFrameZoom() throws {
        let format = NSObject()
        var meter = FrameZoomCalibration()
        func measure(_ time: Double, _ native: Double, _ mm: Double, _ digital: Double = 1,
                     lens: String = "main", stabilized: Bool = false, compensating: Bool = true, age: Double? = nil) -> Double? {
            meter.read(lens: lens, format: ObjectIdentifier(format), stabilized: stabilized, time: time,
                       native: native, compensating: compensating, deliveryAge: age) { (mm, digital) }
        }
        _ = measure(0, 1, 25, compensating: false)
        _ = measure(0.3, 1, 25, 0, compensating: false)
        try check(measure(1, 6, 110, 150.0 / 110) == 6, "Include the digital part of the EXIF focal length")
        try check(measure(1.1, 2.73, 85) == 3.4, "A repeated 85 mm frame still shows the earlier crop")
        try check(measure(1.2, 1.77, 44) == 1.77, "Keep sub-millimetre zoom detail when the exposure agrees")
        try check(measure(1.3, 1.5, .nan) == nil, "Ignore unusable focal metadata")
        try check(measure(1.4, 1.5, 38, lens: "front") == nil, "Recalibrate when the physical lens changes")
        _ = measure(2, 1, 24, stabilized: true, compensating: false, age: 0.069)
        _ = measure(3, 1, 24, stabilized: true, compensating: false, age: 0.070)
        let sdrLag = meter.stabilizedPullLatency(frameDuration: 1.0/30)
        try check(abs(sdrLag - 0.047) < 0.001, "Match the measured stabilized 1080p sensor lag")
        try check(measure(4, 6, 98, 0, stabilized: true, age: 0.120) == nil,
                  "A stabilized 6× frame must never acquire a second crop from clipped EXIF")
        try check(meter.stabilizedPullLatency(frameDuration: 1.0/30) == sdrLag, "Late frames must not retime an active zoom")
        try check(measure(4.1, 6, 98, 0) == nil, "Recalibrate after turning stabilization off")
        _ = measure(5, 1, 24, stabilized: true, compensating: false, age: 0.088)
        try check(abs(meter.stabilizedPullLatency(frameDuration: 1.0/30) - 0.066) < 0.001,
                  "Relearn latency on a newly stabilized pipeline")
    }
}
