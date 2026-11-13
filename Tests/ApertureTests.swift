import Foundation

@main struct ApertureTests {
    static func main() {
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
        }
        let recommended: [Float] = [4, 1.8, 2.8, 1.48, 1.8, .nan, .infinity, -1, 8]
        let stops = CameraAperture.stops(recommended: recommended, minimum: 1.48, maximum: 4) { $0 != 2.8 }
        check(stops == [1.48, 1.8, 4], "Only distinct, in-range, supported physical stops are offered")
        check(CameraAperture.stops(recommended: [1.8], minimum: 1.8, maximum: 1.8) { _ in true }.isEmpty,
              "A fixed-aperture lens has no control")
        check(CameraAperture.stops(recommended: [1.8, 2.8], minimum: .nan, maximum: 4) { _ in true }.isEmpty,
              "Invalid hardware bounds cannot expose a control")
        check(CameraAperture.savedStop(nil, in: stops) == nil, "Existing installations default to Auto")
        check(CameraAperture.savedStop(1.48000001, in: stops) == 1.48, "Preferences tolerate float representation")
        check(CameraAperture.savedStop(2.8, in: stops) == nil, "A stop unsupported by the new format falls back to Auto")
        check(CameraAperture.savedStop(.infinity, in: stops) == nil, "Malformed saved values fall back to Auto")
        check(CameraAperture.label(1.48) == "ƒ/1.48" && CameraAperture.label(1.8) == "ƒ/1.8"
              && CameraAperture.label(4) == "ƒ/4", "Labels preserve the lens's actual precision")
        print("Aperture capability and preference checks passed")
    }
}
