import Foundation

/// Time-based easing in magnification space. Both velocity and acceleration
/// reach zero at either end, and late timer callbacks still meet the deadline.
struct ZoomTransition: Sendable {
    let start: Double
    let target: Double
    let began: Double
    let duration: Double
    var startCenter: CGPoint?
    var targetCenter: CGPoint?
    var compensatesSensorSwitch = false
    var stabilizedSwitches: [Double]? // crossed sensor modes, widest last; nil for ordinary zoom
    var returningSensorStart: Double?
    var drivesStabilizedSensor: Bool { stabilizedSwitches != nil }

    static func frameInterval(_ seconds: Double) -> Double {
        seconds.isFinite && seconds > 0 ? seconds : 1.0 / 30
    }

    func sensorZoom(at time: Double, frameDuration: Double) -> Double {
        if let returningSensorStart {
            // A reversal begins with the lens wider than the visible crop.
            return exp2(log2(returningSensorStart) + log2(target / returningSensorStart) * progress(at: time))
        }
        guard target < start else { return value(at: time) }
        let lead = min(0.18, duration / 2)
        var sensorTime = time + lead
        if drivesStabilizedSensor, duration > 0 {
            // Build the lead from the current lens position. Applying the
            // entire lead on the first tick can kick the very first exposure.
            let t = min(1, max(0, (time - began) / min(0.20, duration * 0.22)))
            sensorTime = time + lead * t * t * (3 - 2 * t)
        }
        // Keep some lead after the last switch. A stabilized sensor can hold
        // its old sampling mode for several exposures. Cross just below the
        // boundary and let it settle while the visible curve keeps moving.
        if let stabilizedSwitches, !stabilizedSwitches.isEmpty {
            let dwell = min(4 * Self.frameInterval(frameDuration), 0.65 * lead / Double(stabilizedSwitches.count))
            for factor in stabilizedSwitches {
                let boundary = max(target, factor * 0.99)
                let early = value(at: sensorTime)
                if early >= boundary { return early }
                sensorTime -= dwell
                if value(at: sensorTime) >= boundary { return boundary }
            }
        }
        return value(at: sensorTime)
    }

    func isFinished(at time: Double) -> Bool { duration <= 0 || time >= began + duration }

    private func progress(at time: Double) -> Double {
        if isFinished(at: time) { return 1 }
        if time <= began { return 0 }
        let t = (time - began) / duration
        return t * t * t * (10 + t * (-15 + 6 * t))
    }
    func value(at time: Double) -> Double {
        if isFinished(at: time) { return target }
        if time <= began { return start }
        return exp2(log2(start) + log2(target / start) * progress(at: time))
    }
    func center(at time: Double) -> CGPoint? {
        guard let startCenter, let targetCenter else { return nil }
        let t = progress(at: time)
        return CGPoint(x: startCenter.x + (targetCenter.x - startCenter.x) * t,
                       y: startCenter.y + (targetCenter.y - startCenter.y) * t)
    }

    static let durationPresets: [Double] = [0, 0.5, 1, 2, 3, 5, 10, 15, 30]
    static func durationLabel(_ seconds: Double) -> String {
        seconds == 0 ? "Instant" : "\(seconds.formatted()) \(seconds == 1 ? "second" : "seconds")"
    }
    static func boundedDuration(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(30, max(0, (value * 2).rounded() / 2))
    }
}
