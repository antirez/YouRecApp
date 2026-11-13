import Foundation

enum CameraAperture {
    static func stops(recommended: [Float], minimum: Float, maximum: Float,
                      supports: (Float) -> Bool) -> [Float] {
        guard minimum.isFinite, maximum.isFinite, minimum > 0, maximum > minimum else { return [] }
        let valid = Set(recommended.filter { $0.isFinite && $0 >= minimum && $0 <= maximum }).sorted()
        guard valid.count > 1 else { return [] }
        return valid.filter(supports)
    }

    static func savedStop(_ value: Double?, in stops: [Float]) -> Float? {
        guard let value, value.isFinite else { return nil }
        return stops.first { abs(Double($0) - value) < 0.001 }
    }

    static func label(_ value: Float) -> String {
        var number = String(format: "%.2f", value)
        while number.last == "0" { number.removeLast() }
        if number.last == "." { number.removeLast() }
        return "ƒ/" + number
    }
}
