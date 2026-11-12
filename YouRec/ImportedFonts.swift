import CoreText
import CryptoKit
import Foundation

/// Content identity makes a saved face independent of its filename, the system's
/// installed fonts, and other versions of the same typeface.
struct ImportedFontFace: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let weights: [Int]
    let defaultWeight: Int

    struct Reference {
        let digest: String
        let index: Int
        let postScriptName: String
        var filename: String { "font-" + digest + ".sfnt" }
        init?(_ id: String) {
            guard id.hasPrefix("import:") else { return nil }
            let parts = id.split(separator: ":", maxSplits: 3)
            guard parts.count == 4, parts[1].utf8.count == 64, parts[1].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  let index = Int(parts[2]), index >= 0 else { return nil }
            digest = String(parts[1]); self.index = index; postScriptName = String(parts[3])
        }
    }
}

struct ImportedFontFile: Identifiable, Equatable, Sendable {
    let id: String
    let filename: String
    let faces: [ImportedFontFace]
}

final class ImportedFonts: @unchecked Sendable {
    static let extensions = ["ttf", "otf", "ttc", "otc"]
    static let shared: ImportedFonts = {
        var base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #if DEBUG
        if CommandLine.arguments.contains("--editor-preview"), let session = ProcessInfo.processInfo.environment["YOUREC_RECOVERY_TEST_RUN"],
           let id = UUID(uuidString: session) { base = base.appendingPathComponent("EditorUITestFonts/" + id.uuidString) }
        #endif
        return ImportedFonts(root: base.appendingPathComponent("YouRec/Fonts", isDirectory: true))
    }()

    private let root: URL
    private let mutations = NSLock()
    private let cache = NSCache<NSURL, Contents>()
    init(root: URL) { self.root = root; cache.totalCostLimit = 48 * 1024 * 1024 }

    private final class Contents {
        let faces: [ImportedFontFace]
        let descriptors: [CTFontDescriptor]
        let bytes: Int
        init(data: Data, digest: String) throws {
            descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor] ?? []
            guard !descriptors.isEmpty else { throw LibraryError.invalid }
            bytes = data.count
            faces = try descriptors.enumerated().map { index, descriptor in
                let face = CTFontCreateWithFontDescriptor(descriptor, 16, nil)
                let ps = CTFontCopyPostScriptName(face) as String
                guard !ps.isEmpty else { throw LibraryError.invalid }
                let hint = String(decoding: ps.utf8.prefix(140), as: UTF8.self)
                let axis = (CTFontCopyVariationAxes(face) as? [[CFString: Any]])?.first {
                    ($0[kCTFontVariationAxisIdentifierKey] as? NSNumber)?.intValue == 0x77676874
                }
                var weights: [Int] = [], weight = 400
                if let lo = axis?[kCTFontVariationAxisMinimumValueKey] as? NSNumber,
                   let hi = axis?[kCTFontVariationAxisMaximumValueKey] as? NSNumber,
                   let normal = axis?[kCTFontVariationAxisDefaultValueKey] as? NSNumber {
                    let low = max(100, lo.intValue), high = min(1000, hi.intValue)
                    if low <= high {
                        weight = min(high, max(low, normal.intValue))
                        weights = Array(Set([low, high, weight] + stride(from: 100, through: 1000, by: 100).filter { (low...high).contains($0) })).sorted()
                    }
                }
                return ImportedFontFace(id: "import:\(digest):\(index):\(hint)", name: CTFontCopyDisplayName(face) as String, weights: weights, defaultWeight: weight)
            }
        }
    }

    enum LibraryError: LocalizedError {
        case invalid, unsupported
        var errorDescription: String? {
            switch self {
            case .invalid: "This file could not be read as a font."
            case .unsupported: "Choose a TTF, OTF, TTC, or OTC font file."
            }
        }
    }
    private func file(for digest: String) -> URL? {
        let folder = root.appendingPathComponent(digest, isDirectory: true)
        return (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?.first {
            Self.extensions.contains($0.pathExtension.lowercased())
        }
    }
    private func contents(at url: URL, digest: String) throws -> Contents {
        if let result = cache.object(forKey: url as NSURL) { return result }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard RecoveryFile.hash(data) == digest else { throw LibraryError.invalid }
        let value = try Contents(data: data, digest: digest)
        cache.setObject(value, forKey: url as NSURL, cost: value.bytes)
        return value
    }
    func files() throws -> [ImportedFontFile] {
        mutations.lock(); defer { mutations.unlock() }
        let directories: [URL]
        do { directories = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) }
        catch where RecoveryFile.missing(error) { return [] }
        return directories.compactMap { directory in
            let digest = directory.lastPathComponent
            guard let url = file(for: digest), let value = try? contents(at: url, digest: digest) else { return nil }
            return ImportedFontFile(id: digest, filename: url.lastPathComponent, faces: value.faces)
        }.sorted { ($0.faces[0].name, $0.filename, $0.id) < ($1.faces[0].name, $1.filename, $1.id) }
    }

    func add(_ source: URL) throws -> (file: ImportedFontFile, added: Bool) {
        guard Self.extensions.contains(source.pathExtension.lowercased()) else { throw LibraryError.unsupported }
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        var result: Result<(ImportedFontFile, Bool), Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { url in
            result = Result { try install(url, filename: source.lastPathComponent) }
        }
        if let result { return try result.get() }
        throw coordinationError ?? CocoaError(.fileReadUnknown) as NSError
    }
    private func install(_ url: URL, filename: String) throws -> (ImportedFontFile, Bool) {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let digest = RecoveryFile.hash(data)
        mutations.lock(); defer { mutations.unlock() }
        if let installed = file(for: digest) {
            let value = try contents(at: installed, digest: digest)
            return (ImportedFontFile(id: digest, filename: installed.lastPathComponent, faces: value.faces), false)
        }
        let value = try Contents(data: data, digest: digest)
        let fm = FileManager.default, directory = root.appendingPathComponent(digest, isDirectory: true)
        // A file is the entire library entry. Publish it atomically; an empty
        // directory left by an interrupted import is invisible and retryable.
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try RecoverySpace.require(Int64(data.count), at: directory)
        let target = directory.appendingPathComponent(filename)
        try RecoveryFile.write(data, to: target)
        // The validation descriptors can retain a mapping of the user's original
        // file. Only cache descriptors subsequently opened from our private copy.
        return (ImportedFontFile(id: digest, filename: filename, faces: value.faces), true)
    }
    func remove(_ entry: ImportedFontFile) throws {
        mutations.lock(); defer { mutations.unlock() }
        guard let url = file(for: entry.id) else { return }
        try FileManager.default.removeItem(at: url.deletingLastPathComponent())
        cache.removeObject(forKey: url as NSURL)
    }

    private func resolved(_ id: String, folder: URL?) -> (CTFontDescriptor, ImportedFontFace)? {
        guard let ref = ImportedFontFace.Reference(id) else { return nil }
        func read(_ url: URL) -> (CTFontDescriptor, ImportedFontFace)? {
            guard let value = try? contents(at: url, digest: ref.digest), value.faces.indices.contains(ref.index),
                  value.faces[ref.index].id == id else { return nil }
            return (value.descriptors[ref.index], value.faces[ref.index])
        }
        if let folder, let match = read(folder.appendingPathComponent(ref.filename)) { return match }
        return file(for: ref.digest).flatMap(read)
    }
    func face(_ id: String, folder: URL?) -> ImportedFontFace? { resolved(id, folder: folder)?.1 }
    func font(_ id: String, size: CGFloat, weight: Int, folder: URL?) -> CTFont? {
        guard let (descriptor, face) = resolved(id, folder: folder) else { return nil }
        if face.weights.count > 1 {
            let varied = CTFontDescriptorCreateCopyWithVariation(descriptor, NSNumber(value: 0x77676874), CGFloat(weight))
            return CTFontCreateWithFontDescriptor(varied, size, nil)
        }
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }

    /// A saved project owns one immutable file per font, including collections.
    /// Write the asset before publishing the manifest that refers to it.
    func preserve(_ filenames: Set<String>, in folder: URL) throws {
        for filename in filenames {
            let target = folder.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: target.path) { continue }
            let digest = String(filename.dropFirst("font-".count).dropLast(".sfnt".count))
            mutations.lock()
            defer { mutations.unlock() }
            guard let source = file(for: digest) else { continue }
            try RecoveryFile.write(Data(contentsOf: source, options: .mappedIfSafe), to: target)
        }
    }
}

extension EditState {
    var importedFontFiles: Set<String> {
        let faces = timeline.video.flatMap { ($0.content.texts ?? []).compactMap { $0.appearance?.face } }
        return Set((faces + [timeline.subtitles?.appearance?.face].compactMap { $0 })
            .compactMap { ImportedFontFace.Reference($0)?.filename })
    }
}
