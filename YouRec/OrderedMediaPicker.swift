import CoreTransferable
import Foundation
import UniformTypeIdentifiers

#if canImport(UIKit)
import SwiftUI
import PhotosUI

/// The private system picker hands out providers in selection order. Keeping
/// the provider lets us ask for a different file representation on failure.
struct OrderedMediaPicker: UIViewControllerRepresentable {
    let picked: ([NSItemProvider]) -> Void

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let picked: ([NSItemProvider]) -> Void
        init(picked: @escaping ([NSItemProvider]) -> Void) { self.picked = picked }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picked(results.map(\.itemProvider))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(picked: picked) }
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .any(of: [.images, .videos])
        config.selection = .ordered
        config.selectionLimit = 0
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ picker: PHPickerViewController, context: Context) {}
}
#endif

extension ImportedPhotoMedia {
    static func load(_ provider: NSItemProvider) async throws -> ImportedPhotoMedia {
        let types = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
        guard let first = types.first(where: { $0.conforms(to: .movie) || $0.conforms(to: .image) }) else {
            throw ProjectError.invalidMedia
        }
        let family: UTType = first.conforms(to: .movie) ? .movie : .image
        var candidates = types.filter { $0.conforms(to: family) }
        if !candidates.contains(family) { candidates.append(family) }
        let name = provider.suggestedName
        for inPlace in [false, true] {
            for type in candidates {
                try Task.checkCancellation()
                let request = PickerFileRequest()
                do {
                    return try await withTaskCancellationHandler {
                        try await withCheckedThrowingContinuation { continuation in
                            guard request.begin(continuation) else { return }
                            let receive: @Sendable (URL?, Error?) -> Void = { url, _ in
                                guard let url else {
                                    request.finish(.failure(PickerTransferUnavailable()))
                                    return
                                }
                                let scoped = url.startAccessingSecurityScopedResource()
                                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                                request.finish(Result {
                                    try request.checkCancellation()
                                    return try ImportedPhotoMedia.copyFromPicker(url, type: type, name: name,
                                                                                checkCancellation: request.checkCancellation)
                                })
                            }
                            let progress: Progress
                            if inPlace {
                                progress = provider.loadInPlaceFileRepresentation(forTypeIdentifier: type.identifier) { url, _, error in
                                    receive(url, error)
                                }
                            } else {
                                progress = provider.loadFileRepresentation(forTypeIdentifier: type.identifier, completionHandler: receive)
                            }
                            request.observe(progress)
                        }
                    } onCancel: { request.cancel() }
                } catch is PickerTransferUnavailable {
                    continue
                } catch let error as CocoaError where [.fileReadNoSuchFile, .fileReadNoPermission, .fileReadUnknown].contains(error.code) {
                    // A provider can hand back a placeholder or revoke a URL.
                    // Only retry reading the source. Preserve storage and write errors.
                    continue
                }
            }
        }
        try Task.checkCancellation()
        throw PickerTransferUnavailable()
    }
}

private struct PickerTransferUnavailable: LocalizedError {
    var errorDescription: String? {
        "Photos couldn’t provide a file for this item. Open it in Photos to finish downloading it, then try again. You can also save it to Files and add it from there."
    }
}

/// Cancellation also releases the waiting task if an iCloud provider never
/// calls back. The provider's temporary URL is consumed inside its callback.
private final class PickerFileRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ImportedPhotoMedia, Error>?
    private var progress: Progress?
    private var cancelled = false

    func begin(_ continuation: CheckedContinuation<ImportedPhotoMedia, Error>) -> Bool {
        lock.lock()
        if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return false }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func observe(_ progress: Progress) {
        lock.lock()
        let shouldCancel = cancelled
        if continuation != nil { self.progress = progress }
        lock.unlock()
        if shouldCancel { progress.cancel() }
    }

    func checkCancellation() throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
    }

    func finish(_ result: Result<ImportedPhotoMedia, Error>) {
        lock.lock()
        let waiting = continuation
        continuation = nil
        progress = nil
        lock.unlock()
        waiting?.resume(with: result)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let pending = progress, waiting = continuation
        progress = nil
        continuation = nil
        lock.unlock()
        waiting?.resume(throwing: CancellationError())
        pending?.cancel()
    }
}

final class ImportedPhotoMedia: Transferable, Sendable {
    let url: URL
    let originalName: String
    let isPhoto: Bool
    private init(url: URL, originalName: String, isPhoto: Bool) {
        self.url = url; self.originalName = originalName; self.isPhoto = isPhoto
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    // The provider can finish a copy after cancellation. Own it until the
    // consumer finishes, and sweep interrupted transfers on the next use.
    private static let transferDirectory: URL = {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("YouRecPhotoTransfers", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        return folder
    }()
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            try await copy(received.file, isPhoto: false)
        }
        FileRepresentation(importedContentType: .image) { received in
            try await copy(received.file, isPhoto: true)
        }
    }

    private static func destination(for source: URL, isPhoto: Bool, type: UTType? = nil) throws -> URL {
        let ext = source.pathExtension.isEmpty ? (type?.preferredFilenameExtension ?? (isPhoto ? "jpg" : "mov")) : source.pathExtension
        try FileManager.default.createDirectory(at: transferDirectory, withIntermediateDirectories: true)
        return transferDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
    }

    static func copyFromPicker(_ source: URL, type: UTType, name: String?, checkCancellation: () throws -> Void) throws -> ImportedPhotoMedia {
        let isPhoto = type.conforms(to: .image)
        let url = try destination(for: source, isPhoto: isPhoto, type: type)
        do {
            try ProjectArchive.copyContents(source, to: url, checkCancellation: checkCancellation) { _ in }
            return ImportedPhotoMedia(url: url, originalName: name ?? source.lastPathComponent, isPhoto: isPhoto)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    static func copy(_ source: URL, isPhoto: Bool) async throws -> ImportedPhotoMedia {
        let url = try destination(for: source, isPhoto: isPhoto)
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let free = (try FileManager.default.attributesOfFileSystem(forPath: transferDirectory.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        guard free > Int64(size) + 256_000_000 else { throw CocoaError(.fileWriteOutOfSpace) }
        do {
            try await ProjectArchive.copyFile(source, to: url) { _ in }
            try Task.checkCancellation()
            return ImportedPhotoMedia(url: url, originalName: source.lastPathComponent, isPhoto: isPhoto)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}
