import Foundation

// Biquad stages retain their own channel state across decoder buffers. Audio is
// processed at 48 kHz. Bypass is exact; no model inference is implied by EQ.
struct AudioChainProcessor {
    struct Stage {
        var b0: Double = 1, b1: Double = 0, b2: Double = 0
        var a1: Double = 0, a2: Double = 0
        var z1: [Double], z2: [Double]
        init(effect: AudioEffect, sampleRate: Double, channels: Int) {
            z1 = Array(repeating: 0, count: channels)
            z2 = z1
            let frequency = min(sampleRate * 0.45, max(20, effect.frequency))
            let w = 2 * Double.pi * frequency / sampleRate
            let c = cos(w), s = sin(w)
            switch effect.kind {
            case .voiceIsolation, .studioVoice, .studioRestoration, .unavailable: preconditionFailure("Unsupported direct DSP stage")
            case .gain: b0 = pow(10, effect.amount / 20)
            case .highPass:
                let alpha = s / (2 * sqrt(0.5)), a0 = 1 + alpha
                b0 = (1 + c) / 2 / a0; b1 = -(1 + c) / a0; b2 = b0
                a1 = -2 * c / a0; a2 = (1 - alpha) / a0
            case .equalizer:
                let amplitude = pow(10, effect.amount / 40), alpha = s / 2
                let a0 = 1 + alpha / amplitude
                b0 = (1 + alpha * amplitude) / a0; b1 = -2 * c / a0
                b2 = (1 - alpha * amplitude) / a0
                a1 = -2 * c / a0; a2 = (1 - alpha / amplitude) / a0
            }
        }
        mutating func sample(_ input: Double, channel: Int) -> Double {
            let result = b0 * input + z1[channel]
            z1[channel] = b1 * input - a1 * result + z2[channel]
            z2[channel] = b2 * input - a2 * result
            return result
        }
    }
    private var stages: [Stage]
    private(set) var peak: Float = 0
    init(effects: [AudioEffect], sampleRate: Double = 48000, channels: Int = 2) {
        stages = effects.filter(\.enabled).map { Stage(effect: $0, sampleRate: sampleRate, channels: channels) }
    }
    mutating func sample(_ value: Float, channel: Int) -> Float {
        var output = Double(value)
        for index in stages.indices { output = stages[index].sample(output, channel: channel) }
        let result = output.isFinite ? Float(output) : 0
        peak = max(peak, abs(result))
        return result
    }
}
