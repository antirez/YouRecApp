import Foundation
import CoreGraphics

@main
struct ZoomTransitionTests {
    static func main() {
        // Different distances and directions must meet the same duration,
        // with no overshoot, including callbacks arriving after the deadline.
        for (start, target) in [(1.0, 8.0), (8.0, 1.0), (0.5, 1.0), (3.0, 3.0)] {
            for duration in [0.5, 1.0, 5.0, 30.0] {
                let ramp = ZoomTransition(start: start, target: target, began: 100, duration: duration)
                precondition(ramp.value(at: 99) == start)
                precondition(ramp.value(at: 100) == start)
                precondition(ramp.value(at: 100 + duration) == target)
                precondition(ramp.value(at: 110 + duration) == target)
                precondition(!ramp.isFinished(at: 100 + duration * 0.9))
                precondition(ramp.isFinished(at: 100 + duration))
                var previous = start
                for tick in 1...600 {
                    let value = ramp.value(at: 100 + duration * Double(tick) / 600)
                    precondition(value >= min(start, target) - 1e-12 && value <= max(start, target) + 1e-12)
                    precondition(target >= start ? value >= previous - 1e-12 : value <= previous + 1e-12)
                    previous = value
                }
                if target != start {
                    func delta(_ a: Double, _ b: Double) -> Double {
                        abs(log2(ramp.value(at: 100 + b * duration) / ramp.value(at: 100 + a * duration)))
                    }
                    precondition(delta(0.9, 1) < delta(0.8, 0.9))
                    precondition(delta(0.8, 0.9) < delta(0.7, 0.8))
                    precondition(delta(0, 0.1) < delta(0.1, 0.2))
                    precondition(delta(0.99, 1) < delta(0.49, 0.5) / 100)
                }
                let interruptedAt = 100 + duration * 0.37
                let applied = ramp.value(at: interruptedAt)
                let replacement = ZoomTransition(start: applied, target: start, began: interruptedAt, duration: 1)
                precondition(replacement.value(at: interruptedAt) == applied)
                precondition(replacement.value(at: interruptedAt + 1) == start)
            }
        }
        precondition(ZoomTransition(start: 1, target: 3, began: 0, duration: 0).value(at: 0) == 3)
        let pan = ZoomTransition(start: 2, target: 2, began: 1, duration: 4,
                                 startCenter: CGPoint(x: 0.5, y: 0.5), targetCenter: CGPoint(x: 0.25, y: 0.75))
        precondition(pan.center(at: 1) == pan.startCenter && pan.center(at: 5) == pan.targetCenter)
        precondition(pan.center(at: 3) == CGPoint(x: 0.375, y: 0.625) && pan.value(at: 3) == 2)
        precondition(pan.center(at: 1.1)!.x > 0.499 && pan.center(at: 4.9)!.x < 0.251)
        precondition(ZoomTransition.boundedDuration(-1) == 0)
        precondition(ZoomTransition.boundedDuration(31) == 30)
        precondition(ZoomTransition.boundedDuration(5.4) == 5.5)
        for duration in [0.5, 1, 5] as [Double] {
            let pull = ZoomTransition(start: 6, target: 1, began: 0, duration: duration,
                                      compensatesSensorSwitch: true, stabilizedSwitches: [2])
            for fps in [24.0, 30, 60] {
                precondition(pull.sensorZoom(at: 0, frameDuration: 1 / fps) == pull.start)
                precondition(pull.sensorZoom(at: 0.01, frameDuration: 1 / fps) > 0.99 * pull.start)
                var last = pull.start
                var settled = 0
                for tick in 0...Int(duration * 1000) {
                    let t = Double(tick) / 1000
                    let input = pull.sensorZoom(at: t, frameDuration: 1 / fps)
                    precondition(input <= last + 1e-10 && input <= pull.value(at: t) + 1e-10)
                    if abs(input - 1.98) < 1e-10 { settled += 1 }
                    last = input
                }
                precondition(settled >= 60 && last == 1)
            }
        }
        let reversed = ZoomTransition(start: 3, target: 6, began: 2, duration: 1,
                                      compensatesSensorSwitch: true, returningSensorStart: 2)
        precondition(reversed.value(at: 2) == 3 && reversed.sensorZoom(at: 2, frameDuration: 1/30) == 2)
        precondition(abs(reversed.sensorZoom(at: 3, frameDuration: 1/30) - 6) < 1e-10)
        print("PASS: zoom deadlines, monotonicity, easing, retargeting and duration bounds")
    }
}
