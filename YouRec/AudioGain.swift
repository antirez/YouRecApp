@preconcurrency import AVFoundation
import ObjectiveC
import SwiftUI

// All gain controls share the same absolute grid; zero is never an implicit mute.
enum AudioGainGrid {
    static func snap(_ db: Double) -> Double { min(12, max(-40, (db * 2).rounded() / 2)) }
    static func common(_ items: [AudioTimelineItem]) -> Double? {
        guard let first = items.first?.volumeDB, items.allSatisfy({ abs($0.volumeDB - first) < 0.001 }) else { return nil }
        return first
    }
}

// Shared absolute half-dB grid with a small zero detent. Mixed selections stay
// untouched until an intentional drag chooses a common level.
struct AudioGainDrag {
    let initial:Double?
    let levels:ClosedRange<Double>
    var value:Double?
    var continued=0.0
    init(value:Double?,levels:ClosedRange<Double>) {initial=value;self.value=value;self.levels=levels}
    mutating func update(distance:Double) {
        let base=initial ?? (distance>=0 ? levels.upperBound : levels.lowerBound)
        let delta=initial == nil ? max(0,abs(distance)-12)*(distance>=0 ? 0.125 : -0.125) : distance*0.125
        let raw=base+delta+continued
        var next=initial == nil && abs(distance)<12 && continued==0 ? nil : AudioGainGrid.snap(raw)
        if let value,next != nil,abs(raw-value)<(value==0 ? 0.6 : 0.4) {next=value}
        value=next
    }
    mutating func stepAtEdge(_ delta:Double) {
        let next=AudioGainGrid.snap((value ?? (delta>0 ? levels.upperBound : levels.lowerBound))+delta)
        guard next != value else {return};continued+=delta;value=next
    }
}

// One control per player item. The audio callback snapshots it once per buffer;
// the lock only protects a small immutable value, never decoding or UI work.
final class LiveAudioGain: @unchecked Sendable {
    struct Snapshot {
        var revision = 0
        var selection = TimelineSelection()
        var gain: Double?
        func applying(to source: AudioEnvelopeSegment, at time: Double, scale: Double, offset: Double) -> AudioEnvelopeSegment {
            let selected = source.owner.map { selection.audio.contains($0) } == true
            let initialSelected = source.initialOwner.map { selection.audio.contains($0) } == true
            guard selected || initialSelected else { return source }
            var result = source
            result.gainWindow = selection.range?.seconds ?? (-Double.infinity...Double.infinity)
            let level = source.endVolume.map { source.volume + ($0 - source.volume) * min(1, max(0, (time - source.start) / max(0.000001, source.end - source.start))) } ?? source.volume
            if selected { result.gainInside = level * scale + offset }
            if initialSelected { result.initialGainInside = (source.initialVolume ?? source.volume) * scale + offset }
            return result
        }
    }
    private let lock = NSLock()
    private var value = Snapshot()
    func update(_ db: Double?, selection: TimelineSelection) {
        lock.lock(); defer { lock.unlock() }
        value = Snapshot(revision: value.revision &+ 1, selection: selection, gain: db.map { pow(10, $0 / 20) })
    }
    func snapshot() -> Snapshot { lock.lock(); defer { lock.unlock() }; return value }
}

// Retained alongside the mix, not a global cache of audio taps. Playback owns
// persistent live taps; independent offline readers get fresh tap clocks.
enum AudioGainMix {
    private static var key: UInt8 = 0
    private static var itemKey: UInt8 = 0
    private static var liveKey: UInt8 = 0
    /// Offline measurements must not reuse the player's/exporter's stateful tap
    /// clocks. Keep the same envelopes, with independent processors per reader.
    static func readingCopy(_ mix: AVAudioMix?) throws -> AVAudioMix? {
        guard let mix else { return nil }
        let result = AVMutableAudioMix()
        result.inputParameters = try mix.inputParameters.map { original in
            let parameter = original.mutableCopy() as! AVMutableAudioMixInputParameters
            if let records = objc_getAssociatedObject(mix, &key) as? Records,
               let segments = records.value[original.trackID] {
                parameter.audioTapProcessor = try CutAudioEnvelope.make(segments: segments)
            }
            return parameter
        }
        return result
    }
    static func install(_ mix: AVAudioMix?, on item: AVPlayerItem) throws {
        var playback = mix
        var control: LiveAudioGain?
        if let mix, let records = objc_getAssociatedObject(mix, &key) as? Records {
            let live = LiveAudioGain(), copy = AVMutableAudioMix()
            copy.inputParameters = try mix.inputParameters.map { original in
                let parameter = original.mutableCopy() as! AVMutableAudioMixInputParameters
                if let segments = records.value[original.trackID] { parameter.audioTapProcessor = try CutAudioEnvelope.make(segments: segments, live: live) }
                return parameter
            }
            playback = copy; control = live
        }
        item.audioMix = playback // Installed once; drag steps never replace the mix.
        objc_setAssociatedObject(item, &itemKey, mix, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        objc_setAssociatedObject(item, &liveKey, control, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
    @discardableResult static func audition(_ db: Double?, selection: TimelineSelection, on item: AVPlayerItem?) -> Bool {
        guard let item, let control = objc_getAssociatedObject(item, &liveKey) as? LiveAudioGain else { return false }
        control.update(db, selection: selection); return true
    }
    #if DEBUG
    static func auditionDB(on item: AVPlayerItem?) -> Double? {
        guard let item, let control = objc_getAssociatedObject(item, &liveKey) as? LiveAudioGain,
              let gain = control.snapshot().gain else { return nil }
        return 20 * log10(gain)
    }
    #endif
    static func sourceMix(of item: AVPlayerItem?) -> AVAudioMix? {
        item.flatMap { objc_getAssociatedObject($0, &itemKey) as? AVAudioMix }
    }
    static func register(_ parameter: AVAudioMixInputParameters, envelopes: [AudioEnvelopeSegment]) {
        objc_setAssociatedObject(parameter, &key, Records([parameter.trackID: envelopes]), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
    static func envelopes(_ parameter: AVAudioMixInputParameters) -> [AudioEnvelopeSegment]? {
        (objc_getAssociatedObject(parameter, &key) as? Records)?.value[parameter.trackID]
    }
    private final class Records: NSObject { let value: [CMPersistentTrackID: [AudioEnvelopeSegment]]; init(_ value: [CMPersistentTrackID: [AudioEnvelopeSegment]]) { self.value = value } }
    static func register(_ mix: AVAudioMix, records: [CMPersistentTrackID: [AudioEnvelopeSegment]]) {
        objc_setAssociatedObject(mix, &key, Records(records), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
    enum Mode { case audition(Double), selected, remainder }
    static func replacing(_ mix: AVAudioMix, selection: TimelineSelection, mode: Mode) throws -> AVAudioMix {
        guard let records = objc_getAssociatedObject(mix, &key) as? Records else { throw ProjectError.invalidMedia }
        let result = AVMutableAudioMix()
        result.inputParameters = try mix.inputParameters.map { original in
            let parameter = original.mutableCopy() as! AVMutableAudioMixInputParameters
            if let envelopes = records.value[original.trackID] {
                parameter.audioTapProcessor = try CutAudioEnvelope.make(segments: envelopes.map { source in
                    var envelope = source
                    let selected = source.owner.map { selection.audio.contains($0) } ?? false
                    let initialSelected = source.initialOwner.map { selection.audio.contains($0) } ?? false
                    envelope.gainWindow = selection.range?.seconds ?? (-Double.infinity...Double.infinity)
                    switch mode {
                    case .audition(let db):
                        if selected { envelope.gainInside = pow(10, db / 20) }
                        if initialSelected { envelope.initialGainInside = pow(10, db / 20) }
                    case .selected:
                        envelope.gainOutside = 0; envelope.gainInside = selected ? 1 : 0
                        envelope.initialGainOutside = 0; envelope.initialGainInside = initialSelected ? 1 : 0
                    case .remainder:
                        if selected { envelope.gainInside = 0 }
                        if initialSelected { envelope.initialGainInside = 0 }
                    }
                    return envelope
                })
            } else if case .selected = mode { parameter.setVolume(0, at: .zero) }
            return parameter
        }
        register(result, records: records.value)
        return result
    }
}

enum ExportAudioLevel {
    /// Measure the final project mix, before lossy encoding: selected source
    /// ranges, enhancement regions, mute/gain, transitions and summed overlaps.
    /// Cached source peaks cannot describe this signal. Read in bounded chunks;
    /// don't write another temporary audio file or retain a whole recording.
    static func peak(asset: AVAsset, mix: AVAudioMix?, duration: Double, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Float {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty, duration > 0 else { progress(1); return 0 }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
        output.audioMix = try AudioGainMix.readingCopy(mix); output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ProjectError.invalidMedia }
        reader.add(output)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 48_000))
        guard reader.startReading() else { throw reader.error ?? ProjectError.invalidMedia }
        defer { reader.cancelReading() }
        var peak: Float = 0, samples = [Float](), reported = 0.0
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            if CMSampleBufferGetNumSamples(buffer) == 0 { continue }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { throw ProjectError.invalidMedia }
            let size = CMBlockBufferGetDataLength(block)
            guard size % MemoryLayout<Float>.size == 0 else { throw ProjectError.invalidMedia }
            samples = Array(repeating: 0, count: size / MemoryLayout<Float>.size)
            let status = samples.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: $0.baseAddress!) }
            guard status == noErr else { throw ProjectError.invalidMedia }
            for sample in samples {
                guard sample.isFinite else { throw ProjectError.invalidMedia }
                peak = max(peak, abs(sample))
            }
            let current = min(1, max(0, buffer.presentationTimeStamp.seconds / duration))
            if current - reported >= 0.02 { reported = current; progress(current) }
        }
        try Task.checkCancellation()
        guard reader.status == .completed else { throw reader.error ?? ProjectError.invalidMedia }
        progress(1); return peak
    }
}

struct AudioHeadroom: Sendable {
    var minimum = 0.0
    var maximum = Double.infinity
    var samples = 0
    // For each actual post-effects sample, -1 <= S*g + U <= 1.
    // Intersect the intervals; this also handles cancellation between tracks.
    mutating func include(selected s: Double, remainder u: Double) {
        guard s.isFinite, u.isFinite else { maximum = -1; return }
        guard abs(s) > 1e-12 else { if abs(u) > 1 { maximum = -1 }; return }
        let a = (-1 - u) / s, b = (1 - u) / s
        minimum = max(minimum, min(a, b)); maximum = min(maximum, max(a, b)); samples += 1
    }
    func clips(at db: Double) -> Bool {
        let gain = pow(10, db / 20)
        return gain < minimum - 1e-7 || gain > maximum + 1e-7
    }
    static func analyze(asset: AVAsset, mix: AVAudioMix, selection: TimelineSelection, range: ClosedRange<Double>) async throws -> AudioHeadroom {
        let duration = try await asset.load(.duration).seconds
        // A Move draft may be shorter than the previously selected interval.
        // Validate the intersection before constructing ClosedRange (which traps
        // for inverted bounds), even if its caller cancelled the analysis.
        try Task.checkCancellation()
        let lowerBound = max(0, range.lowerBound), upperBound = min(duration, range.upperBound + 0.01)
        guard duration.isFinite, lowerBound.isFinite, upperBound.isFinite, upperBound > lowerBound else { throw ProjectError.invalidMedia }
        let range = lowerBound...upperBound
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        try Task.checkCancellation()
        // Muting the last audible part leaves the composition with video only.
        guard !tracks.isEmpty else { return AudioHeadroom() }
        let a = try PCMStream(asset: asset, tracks: tracks, mix: AudioGainMix.replacing(mix, selection: selection, mode: .selected), range: range)
        defer { a.reader.cancelReading() }
        let b = try PCMStream(asset: asset, tracks: tracks, mix: AudioGainMix.replacing(mix, selection: selection, mode: .remainder), range: range)
        defer { b.reader.cancelReading() }
        var result = AudioHeadroom()
        let lower = Int((range.lowerBound * 48_000).rounded()), upper = Int((range.upperBound * 48_000).rounded())
        for frame in lower..<upper {
            if frame % 4096 == 0 { try Task.checkCancellation() }
            for channel in 0..<2 { result.include(selected: Double(try a.sample(frame, channel)), remainder: Double(try b.sample(frame, channel))) }
        }
        return result
    }
    private final class PCMStream {
        let reader: AVAssetReader
        let output: AVAssetReaderAudioMixOutput
        var values: [Float] = []
        var first = Int.min
        var last = Int.min
        var finished = false
        init(asset: AVAsset, tracks: [AVAssetTrack], mix: AVAudioMix, range: ClosedRange<Double>) throws {
            reader = try AVAssetReader(asset: asset)
            output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
            output.audioMix = mix; output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw ProjectError.invalidMedia }
            reader.add(output)
            reader.timeRange = CMTimeRange(start: CMTime(seconds: range.lowerBound, preferredTimescale: 48000), end: CMTime(seconds: range.upperBound, preferredTimescale: 48000))
            guard reader.startReading() else { throw reader.error ?? ProjectError.invalidMedia }
        }
        func sample(_ frame: Int, _ channel: Int) throws -> Float {
            while frame >= last && !finished {
                guard let buffer = output.copyNextSampleBuffer() else {
                    if reader.status == .failed { throw reader.error ?? ProjectError.invalidMedia }
                    finished = true; break
                }
                guard let block = CMSampleBufferGetDataBuffer(buffer) else { throw ProjectError.invalidMedia }
                values = Array(repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
                let status = values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
                guard status == noErr else { throw ProjectError.invalidMedia }
                first = Int((buffer.presentationTimeStamp.seconds * 48000).rounded()); last = first + values.count / 2
            }
            guard frame >= first, frame < last else { return 0 }
            return values[(frame - first) * 2 + channel]
        }
    }
}

#if canImport(UIKit)
import UIKit

// UIKit exposes the actual thumb tint, unlike SwiftUI's track-only tint.
struct HeadroomSlider: UIViewRepresentable {
    @Binding var value: Double
    var unset = false
    var clipping: Bool
    var changed: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UISlider {
        let view = UISlider(); view.minimumValue = -40; view.maximumValue = 12
        view.addTarget(context.coordinator, action: #selector(Coordinator.change(_:)), for: .valueChanged)
        view.accessibilityLabel = "Volume in decibels"; view.accessibilityIdentifier = "audio.gainSlider"
        return view
    }
    func updateUIView(_ view: UISlider, context: Context) {
        context.coordinator.parent = self; view.value = Float(value)
        view.thumbTintColor = unset ? .systemGray : clipping ? .systemRed : .white
        view.minimumTrackTintColor = unset ? .systemGray : clipping ? .systemRed : .systemCyan
        view.accessibilityValue = unset ? "Mixed, choose a level" : String(format: "%+.1f dB", value) + (clipping ? ", Clipping" : "")
    }
    final class Coordinator: NSObject {
        var parent: HeadroomSlider
        init(_ parent: HeadroomSlider) { self.parent = parent }
        @objc func change(_ slider: UISlider) { parent.value = AudioGainGrid.snap(Double(slider.value)); parent.changed() }
    }
}

#endif
