import Foundation
import CryptoKit

/// Only weights/data are downloaded. Runtime code ships with the app.
enum SubtitleModelPack {
    struct File: Sendable { let name: String; let bytes: Int64; let sha256: String }
    static let revision = "bc441bd1e4295c1f42d9879f056049a925b6e013"
    static let repository = "aufklarer/Qwen3-ASR-0.6B-MLX-4bit"
    static let files: [File] = [
        File(name: "config.json", bytes: 7187, sha256: "923618cf5ca452fda0253a6be5c1a17f94a2e4851d3b98beb45848565587bd72"),
        File(name: "vocab.json", bytes: 2776833, sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
        File(name: "merges.txt", bytes: 1671853, sha256: "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"),
        File(name: "tokenizer_config.json", bytes: 12487, sha256: "4942d005604266809309cabc9f4e9cb89ce855d59b14681fdc0e1cc62ea26c4c"),
        File(name: "model.safetensors", bytes: 708236945, sha256: "70c7e67e588062adce4f10796e47ad42ead51c6671eda61a0987eae38ca95ddf"),
    ]
    static var byteCount: Int64 { files.reduce(0) { $0 + $1.bytes } }
    static var root: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SubtitleModels", isDirectory: true) }
    static var directory: URL { root.appendingPathComponent("qwen-0.6b-4bit-v1", isDirectory: true) }
    static var staging: URL { root.appendingPathComponent("qwen-0.6b-4bit-v1.download", isDirectory: true) }
    static var installed: Bool {
        (try? String(contentsOf: directory.appendingPathComponent("ready"), encoding: .utf8)) == revision && files.allSatisfy {
            ((try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent($0.name).path)[.size]) as? NSNumber)?.int64Value == $0.bytes
        }
    }
    static func hash(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var digest = SHA256()
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty { try Task.checkCancellation(); digest.update(data: data) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        if installed { progress(1); return }
        let manager = FileManager.default
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        var resource = root; var values = URLResourceValues(); values.isExcludedFromBackup = true; try resource.setResourceValues(values)
        let free = ((try? manager.attributesOfFileSystem(forPath: root.path)[.systemFreeSize]) as? NSNumber)?.int64Value ?? 0
        guard free > byteCount + 150_000_000 else { throw SubtitleError.message("Free at least 900 MB to download the speech model.") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        var completed: Int64 = 0
        for file in files {
            try Task.checkCancellation()
            let target = staging.appendingPathComponent(file.name)
            if manager.fileExists(atPath: target.path), try hash(target) == file.sha256 { completed += file.bytes; progress(Double(completed) / Double(byteCount)); continue }
            let resumeURL = staging.appendingPathComponent(file.name + ".resume")
            let base = completed
            let delegate = SubtitleDownloadProgress { count in progress(min(1, Double(base + min(file.bytes, count)) / Double(byteCount))) }
            do {
                let temporary: URL, response: URLResponse
                if let resume = try? Data(contentsOf: resumeURL) {
                    (temporary, response) = try await session.download(resumeFrom: resume, delegate: delegate)
                } else {
                    let url = URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(file.name)")!
                    (temporary, response) = try await session.download(from: url, delegate: delegate)
                }
                defer { try? manager.removeItem(at: temporary) }
                guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else { throw SubtitleError.message("The model download was refused. Please retry.") }
                guard try hash(temporary) == file.sha256 else { throw SubtitleError.message("The downloaded model did not pass verification. Please retry.") }
                if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
                try manager.moveItem(at: temporary, to: target)
                try? manager.removeItem(at: resumeURL)
            } catch {
                if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data { try? data.write(to: resumeURL, options: .atomic) }
                else { try? manager.removeItem(at: resumeURL) }
                throw error
            }
            completed += file.bytes; progress(Double(completed) / Double(byteCount))
        }
        try Task.checkCancellation()
        try revision.write(to: staging.appendingPathComponent("ready"), atomically: true, encoding: .utf8)
        if manager.fileExists(atPath: directory.path) { try manager.removeItem(at: directory) }
        try manager.moveItem(at: staging, to: directory)
    }
    static func remove() throws {
        for url in [directory, staging] where FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

private final class SubtitleDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: @Sendable (Int64) -> Void
    init(_ progress: @escaping @Sendable (Int64) -> Void) { self.progress = progress }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) { progress(totalBytesWritten) }
}

enum SubtitleError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}
