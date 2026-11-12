import CoreVideo
import Foundation
#if os(iOS)
import CoreMotion
#endif

/// Positive angles straighten a line that descends to the right in the delivered pixels.
struct HorizonFraming {
    static let defaultDegrees = 9.0
    static let degreeRange = 0.5...10.0
    let radians: Double
    let magnification: Double

    static func degrees(_ value: Double) -> Double {
        guard value.isFinite else { return defaultDegrees }
        return min(degreeRange.upperBound, max(degreeRange.lowerBound, (value * 2).rounded() / 2))
    }

    static func scale(maxDegrees: Double, size: CGSize) -> Double {
        guard size.width > 0, size.height > 0 else { return 1 }
        let angle = degrees(maxDegrees) * .pi / 180
        return cos(angle) + max(size.width / size.height, size.height / size.width) * sin(angle)
    }

    /// Top-left normalized, output to input. The same map drives the shader and focus hit testing.
    func sourceTransform(_ size: CGSize) -> CGAffineTransform {
        let a = cos(radians) / magnification, s = sin(radians) / magnification
        let b = s * size.width / size.height, c = -s * size.height / size.width
        return CGAffineTransform(a: a, b: b, c: c, d: a, tx: (1-a-c)/2, ty: (1-b-a)/2)
    }

    /// Maps pixel offsets from the crop center onto the displayed picture (UIKit, y down).
    func screenTransform(flip: Bool) -> CGAffineTransform {
        CGAffineTransform(rotationAngle: flip ? radians : -radians).scaledBy(x: magnification, y: magnification)
    }

    /// Core Image uses bottom-left pixel coordinates and a forward transform.
    func imageTransform(_ extent: CGRect) -> CGAffineTransform {
        CGAffineTransform(translationX: extent.midX, y: extent.midY)
            .rotated(by: radians).scaledBy(x: magnification, y: magnification)
            .translatedBy(x: -extent.midX, y: -extent.midY)
    }
}

struct HorizonEstimate {
    private var angle = 0.0
    private var lastTime: Double?
    private var lastGravityTime = -Double.infinity
    private var lastGravity = 0.0
    private var visualBias = 0.0
    private var lastVisualTime = -Double.infinity
    private var lastAgreement = -Double.infinity
    private var agreedBias = 0.0
    private var candidate = 0.0, agreements = 0

    static func roll(x: Double, y: Double, rotation: Double, mirrored: Bool) -> Double? {
        guard hypot(x, y) > 0.24 else { return nil } // Looking straight up/down has no reliable horizon.
        let raw = atan2(-x, -y) + (rotation - 90) * .pi / 180
        // The interface or a take can be locked a quarter-turn away from the phone.
        // A small roll then tilts scene verticals and horizontals by the same amount.
        let residual = atan2(sin(4 * raw), cos(4 * raw)) / 4
        return mirrored ? -residual : residual
    }

    mutating func observe(line: Double?, gravity: Double, at time: Double) {
        guard let line, abs(line - gravity) <= 3 * .pi / 180 else {
            agreements = 0; return
        }
        let difference = line - gravity
        if time - lastVisualTime > 0.9 || abs(difference - candidate) > .pi / 180 {
            agreements = 0; candidate = difference
        }
        agreements += 1
        candidate += 0.4 * (difference - candidate)
        lastVisualTime = time
        if agreements >= 3 {
            agreedBias = max(-1.5, min(1.5, candidate * 180 / .pi)) * .pi / 180
            lastAgreement = time
        }
    }

    mutating func correction(gravity: Double?, time: Double, maxDegrees: Double, stabilized: Bool) -> Double {
        let dt = max(0, min(0.1, time - (lastTime ?? (time - 1.0/30))))
        lastTime = time
        if let gravity {
            lastGravity = gravity
            lastGravityTime = time
        }
        // Hold through brief occlusions, then fade the contribution of the lost horizon.
        let recent = time - lastAgreement < 0.9
        visualBias += ((recent ? agreedBias : 0) - visualBias) * (1-exp(-dt / (recent ? 0.35 : 0.9)))
        let raw = time - lastGravityTime < 0.25 ? lastGravity + visualBias : 0
        let limit = HorizonFraming.degrees(maxDegrees) * .pi / 180, knee = limit * 0.85
        let magnitude = abs(raw)
        let bounded = magnitude <= knee ? magnitude : knee + (limit-knee) * tanh((magnitude-knee)/(limit-knee))
        // When the phone is diagonal neither quarter-turn is a natural reference.
        // Taper to neutral so crossing 45° in a locked take cannot flip the frame.
        let ambiguity = min(1, max(0, (abs(lastGravity) * 180 / .pi - 35) / 10))
        let target = (raw < 0 ? -bounded : bounded) * (1 - ambiguity*ambiguity*(3-2*ambiguity))
        // Standard stabilization already suppresses fast shake; correct slower roll on its delivered frame.
        let tau = gravity == nil ? 0.35 : stabilized ? 0.22 : 0.075
        // Reducing Max angle also reduces overscan on this frame.
        angle = min(limit, max(-limit, angle + (target-angle) * (1-exp(-dt/tau))))
        return angle
    }
}

/// Looks for a long edge with consistent polarity across most of the image.
/// Short, moving or strongly sloped edges cannot vote the frame away from gravity.
enum HorizonLine {
    private struct Edge { let x: Int, y: Int, strength: Int }
    static func estimate(_ luma: [UInt8], width: Int, height: Int) -> Double? {
        guard width >= 32, height >= 24, luma.count == width * height else { return nil }
        var edges = [Edge]()
        for x in stride(from: 2, to: width-2, by: 2) {
            for y in 2..<height-2 {
                let i = y*width+x
                let v = Int(luma[i+width]) - Int(luma[i-width])
                guard abs(v) >= 14, abs(Int(luma[i+1])-Int(luma[i-1])) < abs(v) else { continue }
                edges.append(Edge(x: x, y: y, strength: min(64, max(-64, v))))
            }
        }
        guard edges.count >= width / 3 else { return nil }
        let pad = width / 4 + 2, rows = height+2*pad
        var scores = [Double]()
        for halfDegrees in -24...24 {
            let slope = tan(Double(halfDegrees) * .pi / 360)
            var votes = [Int](repeating: 0, count: rows*8)
            for edge in edges {
                let row = pad + edge.y - Int((Double(edge.x-width/2)*slope).rounded())
                votes[row*8 + edge.x*8/width] += edge.strength
            }
            var best = 0.0
            for row in pad/2..<rows-pad/2 {
                var sum = 0
                for band in 0..<8 {
                    let value = votes[row*8+band]
                    sum += max(-width*2, min(width*2, value))
                }
                best = max(best, Double(abs(sum)))
            }
            scores.append(best)
        }
        guard let peak = scores.max(), peak > Double(width*11) else { return nil }
        let top = scores.indices.filter { scores[$0] >= peak*0.97 }
        guard let first = top.first, let last = top.last, last-first <= 6 else { return nil }
        return (Double(first+last)/2 - 24) * .pi/360
    }

    static func estimate(_ pixel: CVPixelBuffer, sidewaysInput: Bool = false) -> Double? {
        let w = CVPixelBufferGetWidth(pixel), h = CVPixelBufferGetHeight(pixel)
        let ratio = min(1, 256.0/Double(max(w,h)))
        let width = Int(Double(w)*ratio), height = Int(Double(h)*ratio)
        guard width >= 32, height >= 24 else { return nil }
        guard let luma = sampleLuma(pixel, width: width, height: height, sideways: sidewaysInput) else { return nil }
        return estimate(luma, width: sidewaysInput ? height : width, height: sidewaysInput ? width : height)
    }

    private static func sampleLuma(_ pixel: CVPixelBuffer, width: Int, height: Int, sideways: Bool) -> [UInt8]? {
        let w = CVPixelBufferGetWidth(pixel), h = CVPixelBufferGetHeight(pixel)
        let format = CVPixelBufferGetPixelFormatType(pixel)
        let bgra = format == kCVPixelFormatType_32BGRA
        let tenBit = [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
                      kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr10BiPlanarFullRange].contains(format)
        guard bgra || tenBit || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferLockBaseAddress(pixel, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        guard let base = bgra ? CVPixelBufferGetBaseAddress(pixel) : CVPixelBufferGetBaseAddressOfPlane(pixel,0) else { return nil }
        let stride = bgra ? CVPixelBufferGetBytesPerRow(pixel) : CVPixelBufferGetBytesPerRowOfPlane(pixel,0)
        var luma = [UInt8](repeating: 0, count: width*height)
        for y in 0..<height {
            let row = base.advanced(by: (y*h/height)*stride)
            let bytes = row.assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let column = x*w/width
                // A line's slope repeats every half turn. One quarter turn handles
                // either sideways orientation without rotating the full sensor buffer.
                let index = sideways ? x*height + height-1-y : y*width+x
                if bgra {
                    let p = bytes.advanced(by: column*4)
                    luma[index] = UInt8((Int(p[2])*54 + Int(p[1])*183 + Int(p[0])*19) >> 8)
                } else if tenBit { luma[index] = UInt8(row.assumingMemoryBound(to: UInt16.self)[column] >> 8) }
                else { luma[index] = bytes[column] }
            }
        }
        return luma
    }
}

#if os(iOS)
/// Called on the movie queue. Motion is matched to exposure time, including for delayed stabilized frames.
final class HorizonLevel {
    private struct Source {
        var estimate = HorizonEstimate()
        let rotation: CGFloat, mirrored: Bool
        var lastAnalysis = -Double.infinity
        var lastFrame = -Double.infinity
    }
    private let motion = CMMotionManager()
    private let motionQueue = OperationQueue()
    private let analysis = DispatchQueue(label: "yourec.horizon.scene", qos: .utility)
    private let media: DispatchQueue
    private let lock = NSLock()
    private var gravity: [(time: Double, x: Double, y: Double)] = []
    private var sources: [String: Source] = [:]
    private var maximum: Double?
    private var generation = 0, busy = false
    #if DEBUG
    private let probe = CommandLine.arguments.contains("--probe-level-horizon")
    private var lastProbeTime = -Double.infinity
    #endif
    init(media: DispatchQueue) { self.media = media; motionQueue.maxConcurrentOperationCount = 1 }
    var available: Bool { motion.isDeviceMotionAvailable }
    func configure(maximum: Double?) {
        let wasActive = self.maximum != nil
        self.maximum = maximum
        guard wasActive != (maximum != nil) else { return }
        generation += 1; sources.removeAll()
        if maximum == nil { motion.stopDeviceMotionUpdates() }
        lock.lock(); gravity.removeAll(keepingCapacity: true); lock.unlock()
        guard maximum != nil, available else { return }
        motion.deviceMotionUpdateInterval = 1.0/60
        motion.startDeviceMotionUpdates(to: motionQueue) { [weak self] sample, _ in
            guard let self, let sample else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            self.gravity.append((sample.timestamp, sample.gravity.x, sample.gravity.y))
            if self.gravity.count > 90 { self.gravity.removeFirst(self.gravity.count - 90) }
        }
    }
    deinit { motion.stopDeviceMotionUpdates() }

    private func gravityAt(_ time: Double) -> (Double, Double)? {
        lock.lock(); defer { lock.unlock() }
        guard let last = gravity.last, abs(last.time-time) < 1 else { return nil }
        guard let i = gravity.lastIndex(where: { $0.time <= time }) else { return nil }
        let a = gravity[i]
        guard i+1 < gravity.count else { return time-a.time < 0.12 ? (a.x,a.y) : nil }
        let b = gravity[i+1]
        let w = min(1, max(0, (time-a.time)/max(0.00001,b.time-a.time)))
        return (a.x+(b.x-a.x)*w, a.y+(b.y-a.y)*w)
    }

    func frame(_ pixel: CVPixelBuffer, source: String, time: Double, rotation: CGFloat, mirrored: Bool, stabilized: Bool, sidewaysInput: Bool = false) -> HorizonFraming? {
        guard let maximum, time.isFinite else { return nil }
        if sources[source]?.rotation != rotation || sources[source]?.mirrored != mirrored ||
            !(0...0.5).contains(time - (sources[source]?.lastFrame ?? time)) {
            sources[source] = Source(rotation: rotation, mirrored: mirrored)
        }
        let gravity = gravityAt(time)
        let roll = gravity.flatMap { HorizonEstimate.roll(x: $0.0, y: $0.1, rotation: rotation, mirrored: mirrored) }
        var state = sources[source]!
        state.lastFrame = time
        if let roll, abs(roll) < 13 * .pi / 180, !busy, time-state.lastAnalysis >= 0.24 {
            busy = true; state.lastAnalysis = time
            let token = generation
            analysis.async {
                let line = HorizonLine.estimate(pixel, sidewaysInput: sidewaysInput)
                self.media.async {
                    self.busy = false
                    guard self.generation == token, self.sources[source]?.lastAnalysis == time else { return }
                    self.sources[source]?.estimate.observe(line: line, gravity: roll, at: time)
                }
            }
        }
        let correction = state.estimate.correction(gravity: roll, time: time, maxDegrees: maximum, stabilized: stabilized)
        sources[source] = state
        let size = CGSize(width: CVPixelBufferGetWidth(pixel), height: CVPixelBufferGetHeight(pixel))
        #if DEBUG
        if probe, let gravity, time-lastProbeTime >= 1 {
            lastProbeTime = time
            let report: [String: Double] = ["gx": gravity.0, "gy": gravity.1, "rotation": rotation,
                "rollDegrees": (roll ?? 0)*180 / .pi, "correctionDegrees": correction*180 / .pi,
                "maximum": maximum, "width": size.width, "height": size.height]
            analysis.async {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("horizon-frame.json")
                try? JSONEncoder().encode(report).write(to: url, options: .atomic)
            }
        }
        #endif
        return HorizonFraming(radians: correction, magnification: HorizonFraming.scale(maxDegrees: maximum, size: size))
    }
}
#endif
