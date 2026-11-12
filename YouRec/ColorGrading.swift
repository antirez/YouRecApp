import Foundation
import CryptoKit
import CoreImage

enum LUTInput: String, Codable, CaseIterable, Identifiable, Sendable {
    case rec709, appleLog, appleLog2
    var id: String { rawValue }
    var title: String { switch self { case .rec709: return "Rec.709"; case .appleLog: return "Apple Log"; case .appleLog2: return "Apple Log 2" } }
}

struct ImportedLUT: Codable, Equatable, Identifiable, Sendable {
    var filename: String
    var name: String
    var input: LUTInput = .rec709
    var id: String { filename }
    var valid: Bool {
        filename.hasPrefix("effect-lut-") && filename.hasSuffix(".cube") && filename.count < 160
        && filename == URL(fileURLWithPath: filename).lastPathComponent && !filename.contains("\\")
        && !name.isEmpty && name.count <= 120
    }
}

enum LUTError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case let .invalid(reason) = self { return reason }; return nil }
}

/// Strict, bounded CUBE reader. Red is the fastest-changing axis. Both standalone
/// 1D curves and 3D cubes are supported; combined shaper+cube files are rejected
/// explicitly rather than silently discarding their shaper. Values may exceed 1.
struct CubeLUT: Sendable {
    let dimension: Int
    let rgba: Data
    let curves: Data?
    let domainMin: SIMD3<Double>
    let domainMax: SIMD3<Double>
    let title: String?
    static let maximumBytes = 32 * 1024 * 1024
    init(data: Data) throws {
        guard data.count <= Self.maximumBytes, let text = String(data: data, encoding: .utf8) else { throw LUTError.invalid("Choose a UTF-8 .cube file smaller than 32 MB.") }
        var size: Int?, oneD = false, title: String?
        var low = SIMD3<Double>(repeating: 0), high = SIMD3<Double>(repeating: 1)
        var rows: [SIMD3<Float>] = []; var seen = Set<String>()
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0].trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard let first = parts.first else { continue }
            if first == "TITLE" {
                guard !seen.contains("TITLE") else { throw LUTError.invalid("The LUT contains duplicate TITLE entries.") }
                title = String(line.dropFirst(5)).trimmingCharacters(in: CharacterSet(charactersIn: "\" ")).prefix(120).description
                seen.insert("TITLE"); continue
            }
            if first == "LUT_3D_SIZE" || first == "LUT_1D_SIZE" {
                guard size == nil, rows.isEmpty, parts.count == 2, let value = Int(parts[1]),
                      (first == "LUT_3D_SIZE" ? (2...65).contains(value) : (2...16384).contains(value)) else {
                    throw LUTError.invalid("Use a standalone 3D LUT (2–65 points) or 1D LUT (2–16,384 points). Combined shaper LUTs are not supported.")
                }
                size = value; oneD = first == "LUT_1D_SIZE"; continue
            }
            if first == "DOMAIN_MIN" || first == "DOMAIN_MAX" {
                guard rows.isEmpty, !seen.contains(String(first)), parts.count == 4 else { throw LUTError.invalid("Invalid LUT input domain.") }
                let values = parts.dropFirst().compactMap { Double($0) }
                guard values.count == 3, values.allSatisfy({ $0.isFinite && abs($0) <= 65536 }) else { throw LUTError.invalid("Invalid LUT input domain.") }
                let v = SIMD3(values[0], values[1], values[2])
                if first == "DOMAIN_MIN" { low = v } else { high = v }; seen.insert(String(first)); continue
            }
            guard let size, parts.count == 3, rows.count < (oneD ? size : size * size * size) else { throw LUTError.invalid("Unsupported LUT header or incorrect number of color entries.") }
            let values = parts.compactMap { Float($0) }
            guard values.count == 3, values.allSatisfy({ $0.isFinite && abs($0) <= 65536 }) else { throw LUTError.invalid("The LUT contains an invalid color value.") }
            rows.append(SIMD3(values[0], values[1], values[2]))
        }
        guard let size, rows.count == (oneD ? size : size * size * size), (0..<3).allSatisfy({ high[$0] > low[$0] }) else { throw LUTError.invalid("The LUT is incomplete or has an invalid input domain.") }
        dimension = size; domainMin = low; domainMax = high; self.title = title
        if oneD {
            let values = rows.flatMap { [$0.x, $0.y, $0.z] }
            curves = values.withUnsafeBytes { Data($0) }; rgba = Data()
        } else {
            let values = rows.flatMap { [$0.x, $0.y, $0.z, Float(1)] }
            rgba = values.withUnsafeBytes { Data($0) }; curves = nil
        }
    }
    func apply(to image: CIImage) -> CIImage {
        let span = domainMax - domainMin
        let normalized = image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1 / span.x, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 1 / span.y, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 1 / span.z, w: 0),
            "inputBiasVector": CIVector(x: -domainMin.x / span.x, y: -domainMin.y / span.y, z: -domainMin.z / span.z, w: 0)
        ])
        if let curves {
            let filter = CIFilter(name: "CIColorCurves")!
            filter.setValue(normalized, forKey: kCIInputImageKey)
            filter.setValue(curves, forKey: "inputCurvesData")
            filter.setValue(CIVector(x: 0, y: 1), forKey: "inputCurvesDomain")
            filter.setValue(nil, forKey: "inputColorSpace")
            return filter.outputImage!
        }
        return normalized.applyingFilter("CIColorCube", parameters: ["inputCubeDimension": dimension, "inputCubeData": rgba, "inputExtrapolate": false])
    }
}

/// Immutable hash-named project payloads: editing a preset/library cannot change
/// a previous edit, redo entry or exported project archive.
enum LUTAssets {
    private final class Box: NSObject { let cube: CubeLUT; init(_ cube: CubeLUT) { self.cube = cube } }
    private static let cache = NSCache<NSURL, Box>()
    static func load(_ lut: ImportedLUT, folder: URL) throws -> CubeLUT {
        guard lut.valid else { throw LUTError.invalid("Invalid LUT reference.") }
        let url = folder.appendingPathComponent(lut.filename)
        if let cached = cache.object(forKey: url as NSURL) { return cached.cube }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= CubeLUT.maximumBytes else { throw LUTError.invalid("The LUT is too large.") }
        let cube = try CubeLUT(data: Data(contentsOf: url)); cache.totalCostLimit = 32 * 1024 * 1024
        cache.setObject(Box(cube), forKey: url as NSURL, cost: cube.rgba.count + (cube.curves?.count ?? 0)); return cube
    }
    static func ingest(_ url: URL, folder: URL) throws -> ImportedLUT {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= CubeLUT.maximumBytes else { throw LUTError.invalid("Choose a .cube file smaller than 32 MB.") }
        let data = try Data(contentsOf: url), cube = try CubeLUT(data: data)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let filename = "effect-lut-" + hash + ".cube"
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(filename)
        if !FileManager.default.fileExists(atPath: target.path) { try data.write(to: target, options: .atomic) }
        let name = cube.title.flatMap { $0.isEmpty ? nil : $0 } ?? String(url.deletingPathExtension().lastPathComponent.prefix(120))
        return ImportedLUT(filename: filename, name: name)
    }
}

struct SavedGrade: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var settings: ColorSettings
}

struct GradeLibrary: Codable {
    var imported: [ImportedLUT] = []
    var grades: [SavedGrade] = []
    var favorites: Set<String> = []
    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ColorLibrary", isDirectory: true)
    }
    static func read() -> GradeLibrary {
        (try? JSONDecoder().decode(Self.self, from: Data(contentsOf: folder.appendingPathComponent("library.json")))) ?? GradeLibrary()
    }
    func save() throws {
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: Self.folder.appendingPathComponent("library.json"), options: .atomic)
    }
    static func copy(_ lut: ImportedLUT, from source: URL, to target: URL) throws {
        _ = try LUTAssets.load(lut, folder: source)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let destination = target.appendingPathComponent(lut.filename)
        if !FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.copyItem(at: source.appendingPathComponent(lut.filename), to: destination) }
    }
}
