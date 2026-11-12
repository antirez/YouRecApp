@preconcurrency import AVFoundation
import Foundation

struct WaveformTile: Sendable {
    static let seconds = 4.0
    static let binsPerSecond = 1000.0
    let start: Double
    let low: [Float]
    let high: [Float]
    func envelope(from: Double, to: Double) -> (Float, Float)? {
        guard from >= start, from < start + Self.seconds else { return nil }
        let a = max(0, Int((from - start) * Self.binsPerSecond))
        let b = min(low.count, max(a + 1, Int(ceil((to - start) * Self.binsPerSecond))))
        guard a < b else { return nil }
        return (low[a..<b].min() ?? 0, high[a..<b].max() ?? 0)
    }
}

// Only visible four-second tiles are decoded. No full-project millisecond array,
// scratch PCM file, or per-pixel decoding. 64 tiles cost about two megabytes.
actor WaveformDetailCache {
    static let shared = WaveformDetailCache()
    private var tiles: [String: WaveformTile] = [:]
    private var order: [String] = []
    func tile(url: URL, index: Int) async throws -> WaveformTile {
        let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let key = "\(url.path)|\(attributes.fileSize ?? 0)|\(attributes.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(index)"
        if let value = tiles[key] { order.removeAll { $0 == key }; order.append(key); return value }
        let task = Task.detached(priority: .utility) { try await Self.decode(url: url, index: index) }
        let result = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
        try Task.checkCancellation()
        tiles[key] = result; order.append(key)
        while order.count > 64 { tiles[order.removeFirst()] = nil }
        return result
    }
    private static func decode(url: URL, index: Int) async throws -> WaveformTile {
        let start = Double(index) * WaveformTile.seconds
        let asset = AVURLAsset(url: url)
        let reader = try AVAssetReader(asset: asset)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let count = Int(WaveformTile.seconds * WaveformTile.binsPerSecond)
        var low = [Float](repeating: 0, count: count), high = low
        guard !tracks.isEmpty else { return WaveformTile(start: start, low: low, high: high) }
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
        output.alwaysCopiesSampleData = false; reader.add(output)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 48000), duration: CMTime(seconds: WaveformTile.seconds, preferredTimescale: 48000))
        guard reader.startReading() else { throw reader.error ?? ProjectError.invalidMedia }
        defer { reader.cancelReading() }
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(sample) else { throw ProjectError.invalidMedia }
            var values = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
            let status = values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            guard status == noErr else { throw ProjectError.invalidMedia }
            let origin = sample.presentationTimeStamp.seconds - start
            for frame in 0..<(values.count / 2) {
                let bin = Int(floor((origin + Double(frame) / 48000) * WaveformTile.binsPerSecond + 1e-7))
                guard bin >= 0, bin < count else { continue }
                low[bin] = min(low[bin], values[frame * 2], values[frame * 2 + 1])
                high[bin] = max(high[bin], values[frame * 2], values[frame * 2 + 1])
            }
        }
        if reader.status == .failed { throw reader.error ?? ProjectError.invalidMedia }
        return WaveformTile(start: start, low: low, high: high)
    }
}
