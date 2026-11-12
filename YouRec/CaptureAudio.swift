@preconcurrency import AVFoundation
import Foundation

/// The saved list controls preview. A quick selection or an open take pins a
/// port until Stop, except when iOS confirms that a replacement is in use.
struct RecordingMicrophoneRoute {
    struct Decision {
        var request: String?
        var recheckAfter: TimeInterval?
        var disconnected: String?
        var failed: String?
    }
    private var pinned: String?
    private var missingSince: TimeInterval?
    private var removalReported = false
    private var refusedFallbacks = Set<String>()
    private var pending: String?
    private var pendingActual: String?
    private var attempts = 0
    private var nextAttempt: TimeInterval = 0

    static func priority(saved: [String], discovered: [String], actual: String?) -> [String] {
        var order = saved
        // A fresh installation starts with the accessory iOS is already using.
        if order.isEmpty, let actual, discovered.contains(actual) { order.append(actual) }
        for id in discovered where !order.contains(id) { order.append(id) }
        return order
    }

    mutating func select(_ id: String) {
        self = Self()
        pinned = id
    }

    mutating func deviceDisconnected(previousInputs: [String]) {
        if let pinned, previousInputs.contains(pinned) { removalReported = true }
        pending = nil
        refusedFallbacks.removeAll()
    }

    mutating func resolve(ranked: [String], actual: String?, preferred: String?, inTake: Bool, now: TimeInterval) -> Decision {
        var result = Decision()
        if inTake, pinned == nil { pinned = ranked.first ?? actual }
        var target = pinned ?? ranked.first
        if let pinned, !ranked.contains(pinned) {
            // During Bluetooth/USB negotiation the input list can be empty or
            // briefly show only the phone, even with a working accessory.
            guard actual != pinned, let first = ranked.first(where: { !refusedFallbacks.contains($0) || $0 == actual }) else {
                missingSince = nil
                pending = nil
                result.recheckAfter = 1
                return result
            }
            let since = missingSince ?? now
            missingSince = since
            let remaining = since + (removalReported ? 0.5 : 3.0) - now
            if remaining > 0 {
                result.recheckAfter = remaining
                return result
            }
            target = first
            if actual == first {
                if inTake { result.disconnected = pinned }
                self.pinned = inTake ? first : nil
                missingSince = nil
                removalReported = false
                refusedFallbacks.removeAll()
            }
        } else {
            missingSince = nil
            removalReported = false
            refusedFallbacks.removeAll()
        }

        guard let target, target != actual || target != preferred else {
            pending = nil
            return result
        }
        // preferredInput acknowledges a request; currentRoute confirms where
        // the audio is coming from. Retry mismatches without a notification loop.
        if pending != target || pendingActual != actual {
            pending = target
            pendingActual = actual
            attempts = 0
            nextAttempt = now
        }
        let delays = [0.25, 0.5, 1.0, 1.5]
        if now < nextAttempt {
            result.recheckAfter = nextAttempt - now
        } else if attempts < delays.count {
            result.request = target
            result.recheckAfter = delays[attempts]
            nextAttempt = now + delays[attempts]
            attempts += 1
        } else if attempts == delays.count, actual != target {
            if missingSince != nil, ranked.contains(where: { $0 != target && !refusedFallbacks.contains($0) }) {
                // The pinned port disappeared and iOS declined this fallback.
                // Try remaining inputs in preference order and confirm the winner.
                refusedFallbacks.insert(target)
                pending = nil
                result.recheckAfter = 0.05
            } else {
                result.failed = target
                attempts += 1
            }
        }
        return result
    }
}

enum CapturePCM {
    static func sample(_ pcm: AVAudioPCMBuffer, at time: CMTime) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(pcm.format.sampleRate)),
                                       presentationTimeStamp: time, decodeTimeStamp: .invalid)
        let size = Int(pcm.format.streamDescription.pointee.mBytesPerFrame)
        var sample: CMSampleBuffer?
        let status = withUnsafePointer(to: size) { pointer in
            CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
                makeDataReadyCallback: nil, refcon: nil, formatDescription: pcm.format.formatDescription,
                sampleCount: CMItemCount(pcm.frameLength), sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleSizeEntryCount: pcm.format.isInterleaved ? 1 : 0,
                sampleSizeArray: pcm.format.isInterleaved ? pointer : nil, sampleBufferOut: &sample)
        }
        guard status == noErr, let sample,
              CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList) == noErr,
              CMSampleBufferSetDataReady(sample) == noErr else { throw AudioProcessingError.invalidFormat }
        return sample
    }
    static func pcm(_ sample: CMSampleBuffer) throws -> AVAudioPCMBuffer {
        guard let description = sample.formatDescription else { throw AudioProcessingError.invalidFormat }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sample.numSamples))
        else { throw AudioProcessingError.invalidFormat }
        pcm.frameLength = AVAudioFrameCount(sample.numSamples)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(sample.numSamples),
            into: pcm.mutableAudioBufferList) == noErr else { throw AudioProcessingError.invalidFormat }
        return pcm
    }
}

/// Owned by the media queue. Gain is applied to a copy, before encoding and metering.
/// A 20 ms ramp prevents clicks; unity never reuses an earlier amplified buffer.
final class RecordingGain {
    static let range = -40.0...12.0
    static func normalized(_ db: Double) -> Double {
        db.isFinite ? min(range.upperBound, max(range.lowerBound, (db * 2).rounded() / 2)) : 0
    }
    private var current: Float = 1
    private var target: Float = 1
    private var remainingSeconds = 0.0
    func set(_ db: Double) {
        let next = Float(pow(10, Self.normalized(db) / 20))
        guard next != target else { return }
        target = next; remainingSeconds = 0.020
    }
    func process(_ sample: CMSampleBuffer) throws -> CMSampleBuffer {
        if current == 1 && target == 1 { return sample }
        let source = try CapturePCM.pcm(sample)
        let channels = Int(source.format.channelCount), frames = Int(source.frameLength)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: source.format.sampleRate, channels: source.format.channelCount),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: source.frameLength),
              let destination = output.floatChannelData else { throw AudioProcessingError.invalidFormat }
        output.frameLength = source.frameLength
        let interleaved = source.format.isInterleaved
        var remaining = Int((remainingSeconds * format.sampleRate).rounded())
        for frame in 0..<frames {
            if remaining > 0 { current += (target - current) / Float(remaining); remaining -= 1 }
            else { current = target }
            for channel in 0..<channels {
                let plane = interleaved ? 0 : channel, index = interleaved ? frame * channels + channel : frame
                let value: Float
                switch source.format.commonFormat {
                case .pcmFormatFloat32: value = source.floatChannelData![plane][index]
                case .pcmFormatInt16: value = Float(source.int16ChannelData![plane][index]) / 32768
                case .pcmFormatInt32: value = Float(source.int32ChannelData![plane][index]) / 2147483648
                default: throw AudioProcessingError.invalidFormat
                }
                destination[channel][frame] = value.isFinite ? value * current : 0
            }
        }
        remainingSeconds = Double(remaining) / format.sampleRate
        return try CapturePCM.sample(output, at: sample.presentationTimeStamp)
    }
}

/// One fixed PCM format and sample clock across microphone route changes.
/// Missing input becomes explicit silence with a measured count; audio is never
/// shifted earlier to hide a hardware discontinuity.
final class CaptureAudioNormalizer {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var expectedInputEnd = CMTime.invalid
    private let start: CMTime
    private(set) var nextFrame: Int64 = 0
    private(set) var insertedSilence: Int64 = 0
    private(set) var clockCorrections: Int64 = 0
    private(set) var maximumClockOffset: Int64 = 0

    init(start: CMTime) { self.start = start }
    func process(_ sample: CMSampleBuffer, endingAt end: CMTime? = nil) throws -> [CMSampleBuffer] {
        let input = try CapturePCM.pcm(sample)
        let rate = input.format.sampleRate
        guard rate > 0, sample.presentationTimeStamp.isNumeric else { throw AudioProcessingError.invalidFormat }
        let contiguous = sourceFormat == input.format && expectedInputEnd.isValid &&
            abs((sample.presentationTimeStamp - expectedInputEnd).seconds) < max(0.002, 1.5 / rate)
        let inputEnd = sample.presentationTimeStamp + CMTime(value: Int64(input.frameLength), timescale: CMTimeScale(rate))
        if sourceFormat != input.format || !contiguous {
            guard let converter = AVAudioConverter(from: input.format, to: format) else { throw AudioProcessingError.invalidFormat }
            converter.primeMethod = .none
            converter.channelMap = input.format.channelCount == 1 ? [0, 0] : [0, 1]
            self.converter = converter; sourceFormat = input.format
        }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 48000 / rate)) + 128
        guard var converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity), let converter else { throw AudioProcessingError.invalidFormat }
        var consumed: AVAudioFrameCount = 0
        var failure: NSError?
        let status = converter.convert(to: converted, error: &failure) { requested, inputStatus in
            guard consumed < input.frameLength else { inputStatus.pointee = .noDataNow; return nil }
            // AVAudioConverter consumes at most its requested frame count. A
            // larger returned tap buffer would silently discard its remainder.
            let count = min(AVAudioFrameCount(requested), input.frameLength - consumed)
            guard let part = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: count) else { inputStatus.pointee = .noDataNow; return nil }
            part.frameLength = count
            let sources = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input.audioBufferList))
            let targets = UnsafeMutableAudioBufferListPointer(part.mutableAudioBufferList)
            let bytesPerFrame = Int(input.format.streamDescription.pointee.mBytesPerFrame)
            for index in sources.indices {
                if let source = sources[index].mData, let target = targets[index].mData {
                    memcpy(target, source.advanced(by: Int(consumed) * bytesPerFrame), Int(count) * bytesPerFrame)
                }
            }
            consumed += count
            inputStatus.pointee = .haveData
            return part
        }
        guard status != .error, consumed == input.frameLength else { throw failure ?? AudioProcessingError.invalidFormat }
        let timestampFrame = Int64(((sample.presentationTimeStamp - start).seconds * 48000).rounded())
        // A resampler may emit alternating frame counts for a fractional ratio.
        // Contiguous input follows its output clock, not a separately rounded
        // timestamp on every tap. Only real input discontinuities create gaps.
        if contiguous && timestampFrame >= 0 {
            let offset = timestampFrame - nextFrame
            maximumClockOffset = max(maximumClockOffset, abs(offset))
            // External microphone clocks need gradual correction to host time.
            // A small rate adjustment avoids accumulating drift or adding abrupt
            // silence at every fractional-rate buffer boundary.
            if abs(offset) > 72, converted.frameLength > 2 {
                let amount = Int(min(abs(offset) - 48, max(1, Int64(converted.frameLength) / 1000))) * (offset > 0 ? 1 : -1)
                let oldCount = Int(converted.frameLength), newCount = oldCount + amount
                let adjusted = try makeBuffer(newCount)
                // Localize the correction at the quietest short window. A
                // whole-buffer linear resample would modulate high frequencies.
                let radius = min(16, (oldCount - abs(amount) - 2) / 4)
                var energy = 0.0, bestEnergy = Double.infinity, center = radius
                func squared(_ index: Int) -> Double {
                    let a = Double(converted.floatChannelData![0][index]), b = Double(converted.floatChannelData![1][index])
                    return a * a + b * b
                }
                for frame in 0..<(radius * 2) { energy += squared(frame) }
                for candidate in radius..<(oldCount - radius - abs(amount)) {
                    if energy < bestEnergy { bestEnergy = energy; center = candidate }
                    energy += squared(candidate + radius) - squared(candidate - radius)
                }
                let begin = center - radius, end = min(newCount, center + radius + max(0, amount))
                for channel in 0..<2 {
                    let source = converted.floatChannelData![channel], target = adjusted.floatChannelData![channel]
                    if begin > 0 { target.update(from: source, count: begin) }
                    for frame in begin..<end {
                        let weight = Float(frame - begin) / Float(max(1, end - begin - 1))
                        let first = source[min(oldCount - 1, frame)]
                        let second = source[min(oldCount - 1, max(0, frame - amount))]
                        target[frame] = first + weight * (second - first)
                    }
                    if end < newCount { target.advanced(by: end).update(from: source.advanced(by: end - amount), count: newCount - end) }
                }
                converted = adjusted; clockCorrections += Int64(amount)
            }
        }
        let target = contiguous && timestampFrame >= 0 ? nextFrame : timestampFrame
        expectedInputEnd = inputEnd
        guard target - nextFrame < 48000 * 10 else { throw AudioProcessingError.invalidFormat }
        var outputs: [CMSampleBuffer] = []
        let finalFrame = end.map { max(0, Int64((($0 - start).seconds * 48000).rounded())) } ?? Int64.max
        while min(target, finalFrame) > nextFrame {
            let count = Int(min(4096, min(target, finalFrame) - nextFrame))
            let silence = try makeBuffer(count)
            for channel in 0..<2 { silence.floatChannelData![channel].initialize(repeating: 0, count: count) }
            outputs.append(try CapturePCM.sample(silence, at: start + CMTime(value: nextFrame, timescale: 48000)))
            nextFrame += Int64(count); insertedSilence += Int64(count)
        }
        let skip = Int(min(Int64(converted.frameLength), max(0, nextFrame - target)))
        let count = Int(min(Int64(Int(converted.frameLength) - skip), max(0, finalFrame - nextFrame)))
        if count > 0 {
            let trimmed = try makeBuffer(count)
            for channel in 0..<2 { trimmed.floatChannelData![channel].update(from: converted.floatChannelData![channel].advanced(by: skip), count: count) }
            outputs.append(try CapturePCM.sample(trimmed, at: start + CMTime(value: nextFrame, timescale: 48000)))
            nextFrame += Int64(count)
        }
        return outputs
    }
    func pad(until end: CMTime) throws -> [CMSampleBuffer] {
        let finalFrame = max(0, Int64(((end - start).seconds * 48000).rounded()))
        guard finalFrame - nextFrame <= 48000 * 10 else { throw AudioProcessingError.invalidFormat }
        var output: [CMSampleBuffer] = []
        while nextFrame < finalFrame {
            let count = Int(min(4096, finalFrame - nextFrame))
            let buffer = try makeBuffer(count)
            for channel in 0..<2 { buffer.floatChannelData![channel].initialize(repeating: 0, count: count) }
            output.append(try CapturePCM.sample(buffer, at: start + CMTime(value: nextFrame, timescale: 48000)))
            nextFrame += Int64(count); insertedSilence += Int64(count)
        }
        return output
    }
    private func makeBuffer(_ count: Int) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { throw AudioProcessingError.invalidFormat }
        buffer.frameLength = AVAudioFrameCount(count)
        return buffer
    }
}
