@preconcurrency import AVFoundation
import MediaToolbox

struct AudioEnvelopeSegment {
    let start: Double
    let end: Double
    var fadeIn: Double
    var fadeOut: Double
    let clipStart: Double
    let clipEnd: Double
    let transitionIn: Double
    let transitionOut: Double
    var audibleStart: Double = -.infinity
    var audibleEnd: Double = .infinity
    var inRamp: ClosedRange<Double>?
    var outRamp: ClosedRange<Double>?
    var userFadeIn: AudioEdgeFade?
    var userFadeOut: AudioEdgeFade?
    var owner: UUID?
    var initialOwner: UUID?
    var initialVolume: Double?
    var censors: [AudioCensorSpan] = []
    var volume = 1.0
    var endVolume:Double?
    var gainWindow: ClosedRange<Double>?
    var gainInside: Double?
    var gainOutside: Double?
    var initialGainInside: Double?
    var initialGainOutside: Double?
    func gain(at time: Double) -> Double {
        guard time >= start, time < end else { return 0 }
        var gain = min(1, max(0, min(fadeIn > 0 ? (time - start) / fadeIn : 1, fadeOut > 0 ? (end - time) / fadeOut : 1)))
        if transitionIn > 0 { gain = min(gain, max(0, (time - clipStart) / transitionIn)) }
        if transitionOut > 0 { gain = min(gain, max(0, (clipEnd - time) / transitionOut)) }
        gain = min(gain, max(0, min((time - audibleStart) / 0.008, (audibleEnd - time) / 0.008)))
        if let ramp = inRamp { gain *= min(1, max(0, (time - ramp.lowerBound) / max(0.008, ramp.upperBound - ramp.lowerBound))) }
        if let ramp = outRamp { gain *= min(1, max(0, (ramp.upperBound - time) / max(0.008, ramp.upperBound - ramp.lowerBound))) }
        gain *= min(userFadeIn?.gain(time - clipStart) ?? 1, userFadeOut?.gain(clipEnd - time) ?? 1)
        let level=endVolume.map { volume+($0-volume)*min(1,max(0,(time-start)/max(0.000001,end-start))) } ?? volume
        func adjusted(_ value: Double, inside: Double?, outside: Double?) -> Double {
            guard let range = gainWindow else { return value }
            // A gain-only boundary is a short ramp, never a fade through silence.
            let enter = min(1, max(0, (time - range.lowerBound) / 0.01))
            let leave = min(1, max(0, (time - range.upperBound) / 0.01))
            let weight = enter * (1 - leave)
            return (outside ?? value) * (1 - weight) + (inside ?? value) * weight
        }
        let target = adjusted(level, inside: gainInside, outside: gainOutside)
        if let initialVolume {
            let initial = adjusted(initialVolume, inside: initialGainInside, outside: initialGainOutside)
            let weight = min(1, max(0, (time - start) / 0.01))
            return gain * (initial + (target - initial) * weight)
        }
        return gain * target
    }
}

// A successful source pull must never be discarded because its timestamp is
// temporarily invalid (possible at an empty/scaled edit). Keep a sample clock.
struct AudioEnvelopeClock {
    private(set) var next:Double?
    mutating func start(reported:Double,frames:Int,rate:Double,fallback:Double)->Double {
        let time=reported.isFinite ? reported : next ?? fallback
        next=time+Double(frames)/rate
        return time
    }
}

// The system volume-ramp mixer can quantize short ramps to decoder buffers.
// A post-effects tap applies the envelope to each sample without moving time.
enum CutAudioEnvelope {
    private final class State {
        let boundaries: [Double]
        let duration: Double
        let segments: [AudioEnvelopeSegment]?
        let live: LiveAudioGain?
        var liveSnapshot = LiveAudioGain.Snapshot()
        var gains: [Double] = []
        var tones: [Double] = []
        var liveScale = 1.0
        var liveOffset = 0.0
        var rampRemaining = 0
        var format = AudioStreamBasicDescription()
        var clock=AudioEnvelopeClock()
        let fade = 0.008
        init(clips: [TimelineClip]) {
            segments = nil; live = nil
            var points: [Double] = []
            var cursor = 0.0
            for (index, clip) in clips.enumerated() {
                if index > 0 {
                    let previous = clips[index - 1]
                    if !previous.audioContinues(into:clip) { points.append(cursor) }
                }
                cursor += clip.duration
            }
            boundaries = points; duration = cursor
        }
        init(segments: [AudioEnvelopeSegment], live: LiveAudioGain?) { self.segments = segments; self.live = live; boundaries = []; duration = segments.last?.end ?? 0 }
        func bufferGains(start: Double, count: Int) {
            if let next = live?.snapshot(), next.revision != liveSnapshot.revision {
                // Only the selected gain is smoothed. Smoothing the entire
                // envelope would alter cuts/fades on unselected tracks too.
                var next = next
                if next.gain == nil { next.selection = liveSnapshot.selection }
                else if next.selection != liveSnapshot.selection { liveScale = 1; liveOffset = 0 }
                liveSnapshot = next; rampRemaining = max(1, Int(format.mSampleRate * 0.01))
            }
            if gains.count < count { gains = Array(repeating: 0, count: count); tones = Array(repeating: 0, count: count) }
            for frame in 0..<count {
                if rampRemaining > 0 {
                    let targetScale = liveSnapshot.gain == nil ? 1.0 : 0.0
                    liveScale += (targetScale - liveScale) / Double(rampRemaining)
                    liveOffset += ((liveSnapshot.gain ?? 0) - liveOffset) / Double(rampRemaining)
                    rampRemaining -= 1
                }
                let pair = sampleGains(start + Double(frame) / format.mSampleRate)
                gains[frame] = pair.0; tones[frame] = pair.1
            }
        }
        func sampleGains(_ time: Double) -> (Double, Double) {
            if let segments {
                var lower = 0, upper = segments.count
                while lower < upper {
                    let middle = (lower + upper) / 2
                    if segments[middle].end <= time { lower = middle + 1 } else { upper = middle }
                }
                guard lower < segments.count else { return (0, 0) }
                let segment = segments[lower]
                let gain = liveScale == 1 && liveOffset == 0 ? segment.gain(at: time)
                    : liveSnapshot.applying(to: segment, at: time, scale: liveScale, offset: liveOffset).gain(at: time)
                var original = 1.0, tone = 0.0
                for censor in segment.censors {
                    original = min(original, censor.originalGain(at: time))
                    tone += censor.tone(at: time, sampleRate: format.mSampleRate)
                }
                return (gain * original, gain * tone)
            }
            var gain = min(1, max(0, min(time, duration - time) / fade))
            // Binary search makes even thousands of cuts inexpensive per sample.
            var lower = 0, upper = boundaries.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if boundaries[middle] < time { lower = middle + 1 } else { upper = middle }
            }
            if lower < boundaries.count { gain = min(gain, abs(boundaries[lower] - time) / fade) }
            if lower > 0 { gain = min(gain, abs(time - boundaries[lower - 1]) / fade) }
            return (gain, 0)
        }
    }
    static func make(clips: [TimelineClip]) throws -> MTAudioProcessingTap {
        try make(state: State(clips: clips))
    }
    static func make(segments: [AudioEnvelopeSegment], live: LiveAudioGain? = nil) throws -> MTAudioProcessingTap {
        try make(state: State(segments: segments, live: live))
    }
    private static func make(state: State) throws -> MTAudioProcessingTap {
        let opaque = Unmanaged.passRetained(state).toOpaque()
        var callbacks = MTAudioProcessingTapCallbacks(version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: opaque,
            init: { _, info, storage in storage.pointee = info },
            finalize: { tap in Unmanaged<State>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
            prepare: { tap, maxFrames, format in
                let state=Unmanaged<State>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                state.format=format.pointee;state.clock=AudioEnvelopeClock()
                state.gains = Array(repeating: 0, count: maxFrames); state.tones = state.gains; state.rampRemaining = 0
                state.liveSnapshot = state.live?.snapshot() ?? LiveAudioGain.Snapshot()
                state.liveScale = state.liveSnapshot.gain == nil ? 1 : 0; state.liveOffset = state.liveSnapshot.gain ?? 0
            },
            unprepare: nil,
            process: { tap, frames, _, buffers, count, flags in
                var timeRange = CMTimeRange.invalid
                let status = MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flags, &timeRange, count)
                guard status == noErr else {count.pointee=0;return}
                guard count.pointee > 0 else { return }
                let state = Unmanaged<State>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                let format = state.format
                guard format.mFormatID == kAudioFormatLinearPCM, format.mSampleRate > 0 else { return }
                let start=state.clock.start(reported:timeRange.start.seconds,frames:count.pointee,rate:format.mSampleRate,fallback:state.segments?.first?.start ?? 0)
                state.bufferGains(start: start, count: count.pointee)
                let floating = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
                let width = Int(format.mBitsPerChannel / 8)
                for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
                    guard let pointer = buffer.mData, width > 0 else { continue }
                    let channels = max(1, Int(buffer.mNumberChannels))
                    let frameCount = min(count.pointee, Int(buffer.mDataByteSize) / width / channels)
                    for frame in 0..<frameCount {
                        let gain = state.gains[frame], tone = state.tones[frame]
                        for channel in 0..<channels {
                            let index = frame * channels + channel
                            if floating && width == 4 { let data = pointer.assumingMemoryBound(to: Float.self); data[index] = data[index] * Float(gain) + Float(tone) }
                            else if floating && width == 8 { let data = pointer.assumingMemoryBound(to: Double.self); data[index] = data[index] * gain + tone }
                            else if !floating && width == 2 { let data = pointer.assumingMemoryBound(to: Int16.self); data[index] = Int16(min(Double(Int16.max), max(Double(Int16.min), Double(data[index]) * gain + tone * Double(Int16.max)))) }
                            else if !floating && width == 4 { let data = pointer.assumingMemoryBound(to: Int32.self); data[index] = Int32(min(Double(Int32.max), max(Double(Int32.min), Double(data[index]) * gain + tone * Double(Int32.max)))) }
                        }
                    }
                }
            })
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard status == noErr, let tap else { Unmanaged<State>.fromOpaque(opaque).release(); throw ProjectError.invalidMedia }
        return tap
    }
}
