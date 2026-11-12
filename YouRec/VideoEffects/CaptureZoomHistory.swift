import Foundation

/// Center in the unrotated, unmirrored full lens. Preview and writer can each
/// rotate and mirror that same framing independently.
struct CameraFraming: Equatable {
    static let middle = CGPoint(x: 0.5, y: 0.5)
    var zoom: Double
    var center: CGPoint = middle

    static func oriented(_ point: CGPoint, angle: CGFloat, mirrored: Bool) -> CGPoint {
        let quarter = (Int((angle / 90).rounded()) % 4 + 4) % 4
        var result: CGPoint
        switch quarter {
        case 1: result = CGPoint(x: 1 - point.y, y: point.x)
        case 2: result = CGPoint(x: 1 - point.x, y: 1 - point.y)
        case 3: result = CGPoint(x: point.y, y: 1 - point.x)
        default: result = point
        }
        if mirrored { result.x = 1 - result.x }
        return result
    }

    static func sensorPoint(_ point: CGPoint, angle: CGFloat, mirrored: Bool) -> CGPoint {
        oriented(CGPoint(x: mirrored ? 1 - point.x : point.x, y: point.y), angle: -angle, mirrored: false)
    }

    /// Translate in whole-sensor units. The crop can touch an edge but never pass it.
    static func clamped(_ point: CGPoint, fraction: CGFloat) -> CGPoint {
        let half = min(1, max(0, fraction)) / 2
        return CGPoint(x: min(1 - half, max(half, point.x)), y: min(1 - half, max(half, point.y)))
    }
}

struct CaptureZoomStamp:Sendable {
    var time:Double
    var zoom:Double
    var lens:String
    var selectedZoom: Double? = nil // non-nil during face-follow ownership and handoff
    var minimumZoom: Double = 1
    var manualCenter: CGPoint? = nil
    var manualMove: ZoomTransition? = nil
}

/// On unstabilized frames EXIF rounds the focal length to a whole millimetre and excludes any
/// additional digital zoom. Their product describes the field of view of this
/// particular exposure, even when the ISP repeats the preceding sensor crop.
struct FrameZoomCalibration {
    private var lens = ""
    private var format: ObjectIdentifier?
    private var stabilized = false
    private var lastZoom = 0.0
    private var steadySince = 0.0
    private var focalLengthAtOneX: Double?
    private var steadyDeliveryAge: Double?

    func stabilizedPullLatency(frameDuration: Double) -> Double {
        let interval = ZoomTransition.frameInterval(frameDuration)
        guard let steadyDeliveryAge else { return 2 * interval }
        // On the 14 Pro Max the measured command-to-exposure lag was about
        // 46 ms in 1080p and 66 ms in 4K HDR. Delivery followed about two
        // thirds of a frame later. Use the active pipeline's timing.
        return min(3 * interval, max(interval, steadyDeliveryAge - interval * 2 / 3))
    }

    mutating func read(lens: String, format: ObjectIdentifier, stabilized: Bool, time: Double, native: Double,
                       compensating: Bool, deliveryAge: Double? = nil, focalLength: () -> (mm: Double, digital: Double)?) -> Double? {
        guard time.isFinite, native.isFinite, native > 0 else { return nil }
        if self.lens != lens || self.format != format || self.stabilized != stabilized {
            self.lens = lens
            self.format = format
            self.stabilized = stabilized
            focalLengthAtOneX = nil
            steadyDeliveryAge = nil
            lastZoom = 0
        }
        // Stabilized frames can report the same 98 mm with no digital zoom
        // from 4.4× through 6×. That field no longer measures the delivered crop.
        if stabilized {
            // Learn the delivery age outside the move. Keep the estimate fixed
            // during it so a burst at a sampling-mode change cannot jump the crop.
            if !compensating || steadyDeliveryAge == nil, let age = deliveryAge, (0..<0.5).contains(age) {
                if let previous = steadyDeliveryAge {
                    steadyDeliveryAge = previous + 0.1 * min(0.01, max(-0.01, age - previous))
                } else { steadyDeliveryAge = age }
            }
            return nil
        }
        if abs(native - lastZoom) > 0.0001 || time < steadySince {
            lastZoom = native
            steadySince = time
        }
        guard compensating || (focalLengthAtOneX == nil && time - steadySince >= 0.25),
              let focal = focalLength(), focal.mm.isFinite, focal.mm > 0,
              focal.digital.isFinite, focal.digital == 0 || focal.digital >= 1 else { return nil }
        let digital = max(1, focal.digital) // EXIF zero also means no digital zoom.
        let equivalent = focal.mm * digital
        if !compensating {
            focalLengthAtOneX = equivalent / native
            return nil
        }
        guard let reference = focalLengthAtOneX else { return nil }
        let measured = equivalent / reference
        // Prefer the precise device reading while it agrees with the frame.
        // During sensor reconfiguration that reading can be a few frames ahead.
        let tolerance = 0.55 * digital / reference + 0.003 * measured
        return abs(measured - native) <= tolerance ? native : measured
    }
}

// Camera commands and Vision complete on different queues. Look up the zoom
// that belonged to the measured frame, never the latest zoom at inference end.
// Two frames is the conservative initial ISP estimate; the feedback controller
// is tested with an error of +/- two frames. Device probes measure this delay.
final class CaptureZoomHistory:@unchecked Sendable {
    private let lock=NSLock()
    private var entries:[CaptureZoomStamp]=[]
    func record(time:Double,zoom:Double,lens:String,selectedZoom:Double? = nil,minimumZoom:Double = 1,
                manualCenter: CGPoint? = nil, manualMove: ZoomTransition? = nil) {
        guard time.isFinite,zoom.isFinite,zoom>0 else { return }
        lock.lock();defer { lock.unlock() }
        if let last=entries.last,last.lens != lens || last.time>time { entries.removeAll(keepingCapacity:true) }
        entries.append(CaptureZoomStamp(time: time, zoom: zoom, lens: lens, selectedZoom: selectedZoom,
                                        minimumZoom: minimumZoom, manualCenter: manualCenter, manualMove: manualMove))
        while entries.count>256 || entries.count>1 && entries[1].time<time-3 { entries.removeFirst() }
    }
    func frame(at time:Double,latency:Double=2.0/30,interpolate:Bool=false)->CaptureZoomStamp? {
        lock.lock();defer { lock.unlock() }
        guard !entries.isEmpty else { return nil }
        let target=time-latency
        func firstAfter(_ t: Double) -> Int {
            var low = 0, high = entries.count
            while low < high {
                let mid = (low + high) / 2
                if entries[mid].time <= t { low = mid + 1 } else { high = mid }
            }
            return low
        }
        let low = firstAfter(target)
        var result = entries[max(0,low-1)]
        if interpolate, low > 0, low < entries.count {
            let next = entries[low], interval = next.time - result.time
            if interval > 0 && interval < 0.2 {
                let fraction = (target - result.time) / interval
                // Native ramps move at a constant number of stops per second.
                result.zoom *= pow(next.zoom / result.zoom, fraction)
            } else if next.time - target < target - result.time {
                // A fresh handoff may follow a pause or a period of native-only
                // capture. Do not apply an old lens reading to its first frame.
                result.zoom = next.zoom
            }
        }
        // The ISP reading has latency. Ownership of a digital crop changes at
        // the frame's PTS, including the first frame that returns to native.
        let upper = latency == 0 ? low : firstAfter(time)
        let previous = entries[max(0, upper - 1)]
        if previous.manualCenter != nil || result.manualCenter != nil {
            result.manualCenter = previous.manualCenter
            result.manualMove = previous.manualMove
            result.selectedZoom = previous.selectedZoom
            if let center = previous.manualCenter, let selected = previous.selectedZoom {
                if let move = previous.manualMove {
                    result.selectedZoom = move.value(at: time)
                    result.manualCenter = move.center(at: time) ?? center
                } else if upper > 0, upper < entries.count {
                    let next = entries[upper], interval = next.time - previous.time
                    if interval > 0, interval < 0.1, next.manualMove == nil,
                       let end = next.manualCenter, let zoom = next.selectedZoom {
                        let t = (time - previous.time) / interval
                        result.manualCenter = CGPoint(x: center.x + (end.x - center.x) * t, y: center.y + (end.y - center.y) * t)
                        result.selectedZoom = selected * pow(zoom / selected, t)
                    }
                }
            }
        }
        result.time = time
        return result
    }
}

enum LiveDollyState:String {
    case ready="Start dolly",preparing="Preparing",following="Stop dolly",stopping="Settling",holding="Start again"
    var moving:Bool { self == .preparing || self == .following || self == .stopping }
}
