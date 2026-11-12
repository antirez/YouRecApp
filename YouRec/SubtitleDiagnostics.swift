#if DEBUG
import AVFoundation
import UIKit

/// Explicit developer probe. Input/output are in Documents/SubtitlesQA only;
/// no project, recording preference or source file is changed.
enum SubtitleDiagnostics {
    @MainActor static func run() async {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("SubtitlesQA")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        RecordingAppDelegate.keepAwake("subtitle-QA", active: true)
        defer { RecordingAppDelegate.keepAwake("subtitle-QA", active: false) }
        var report: [String: Any] = ["status": "running", "device": UIDevice.current.model]
        func save() { if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: root.appendingPathComponent("report.json"), options: .atomic) } }
        save()
        do {
            let started = ProcessInfo.processInfo.systemUptime
            if !SubtitleModelPack.installed {
                report["phase"] = "download"; save()
                try await SubtitleModelPack.download { _ in }
            }
            report["modelInstalled"] = SubtitleModelPack.installed; report["downloadSeconds"] = ProcessInfo.processInfo.systemUptime - started; save()
            let asset = AVURLAsset(url: root.appendingPathComponent("input.wav")), duration = try await asset.load(.duration).seconds
            let start = ProcessInfo.processInfo.systemUptime
            let words = try await SubtitleTranscriber.shared.transcribe(asset: asset, mix: nil, range: 0...duration, language: "Auto") { value, message in
                Task { @MainActor in report["progress"] = value; report["phase"] = message; save() }
            }
            report["transcribeSeconds"] = ProcessInfo.processInfo.systemUptime - start
            report["duration"] = duration; report["text"] = SubtitleTiming.joined(words.map(\.text))
            report["words"] = words.map { ["text": $0.text, "start": $0.start, "end": $0.end] as [String: Any] }
            report["status"] = "passed"; save()
        } catch { report["status"] = "failed"; report["error"] = error.localizedDescription; save() }
    }
}
#endif
