import Foundation

enum CensorWaveform: String, Codable, CaseIterable { case sine, triangle, square }
enum CensorEnvelope: String, Codable, CaseIterable { case short, soft, pulse }

struct AudioCensorSettings: Codable, Equatable {
    var frequency = 1000.0
    var levelDB = -18.0
    var waveform = CensorWaveform.sine
    var envelope = CensorEnvelope.short
    var valid: Bool { frequency.isFinite && (100...4000).contains(frequency) && levelDB.isFinite && (-36...(-6)).contains(levelDB) }
    var amplitude: Double { pow(10, levelDB / 20) }

    /// Phase is derived from time, not callback order: seeking and exporting
    /// produce the same samples. Triangle harmonics stop below Nyquist; a
    /// polynomial band-limited step smooths the square wave's discontinuities.
    func oscillator(time: Double, sampleRate: Double) -> Double {
        let phase = 2 * Double.pi * (time * frequency).truncatingRemainder(dividingBy: 1)
        if waveform == .sine { return sin(phase) }
        if waveform == .square {
            let raw = (time * frequency).truncatingRemainder(dividingBy: 1)
            let t = raw < 0 ? raw + 1 : raw, dt = min(0.49, frequency / sampleRate)
            func blep(_ t: Double) -> Double {
                if t < dt { let x = t / dt; return x + x - x * x - 1 }
                if t > 1 - dt { let x = (t - 1) / dt; return x * x + x + x + 1 }
                return 0
            }
            return (t < 0.5 ? 1 : -1) + blep(t) - blep((t + 0.5).truncatingRemainder(dividingBy: 1))
        }
        let maximum = min(17, Int((sampleRate * 0.45 / frequency).rounded(.down)))
        var value = 0.0, scale = 0.0
        for harmonic in stride(from: 1, through: max(1, maximum), by: 2) {
            let n = Double(harmonic)
            let coefficient = ((harmonic / 2) % 2 == 0 ? 1.0 : -1.0) / (n * n)
            value += coefficient * sin(n * phase); scale += abs(coefficient)
        }
        return value / max(1, scale)
    }
    func envelopeValue(time: Double, duration: Double) -> Double {
        guard time >= 0, time < duration else { return 0 }
        let fade = min(duration / 2, envelope == .soft ? 0.06 : 0.008)
        func smooth(_ value: Double) -> Double { let x = min(1, max(0, value)); return x * x * (3 - 2 * x) }
        var result = smooth(time / max(0.00001, fade)) * smooth((duration - time) / max(0.00001, fade))
        if envelope == .pulse {
            let t = time.truncatingRemainder(dividingBy: 0.25)
            result *= smooth(t / 0.008) * smooth((0.18 - t) / 0.008)
        }
        return result
    }
}

struct AudioCensorRegion: Codable, Equatable, Identifiable {
    var id = UUID()
    var interval: EditInterval
    var phaseOrigin: EditTime
    var settings: AudioCensorSettings
    var envelopeInterval: EditInterval?
    func sliced(_ part: EditInterval) -> Self? {
        guard let intersection = interval.intersection(part) else { return nil }
        var result = self
        result.interval = EditInterval(intersection.start - part.start, intersection.end - part.start)
        let envelope = envelopeInterval ?? interval
        result.envelopeInterval = EditInterval(envelope.start - part.start, envelope.end - part.start)
        result.phaseOrigin = phaseOrigin - part.start
        return result
    }
}

/// Absolute render clock. The audible generator is owned by one selected item
/// for each shared region; overlapping selected tracks are all silenced but
/// cannot stack identical beeps and unexpectedly multiply their level.
struct AudioCensorSpan {
    let start: Double
    let end: Double
    let phaseOrigin: Double
    let envelopeStart: Double
    let envelopeEnd: Double
    let settings: AudioCensorSettings
    let emitsTone: Bool
    func originalGain(at time: Double) -> Double {
        if time >= start && time < end { return 0 }
        return min(1, max(0, time < start ? (start - time) / 0.005 : (time - end) / 0.005))
    }
    func tone(at time: Double, sampleRate: Double) -> Double {
        guard emitsTone, time >= start, time < end else { return 0 }
        return settings.amplitude * settings.envelopeValue(time: time - envelopeStart, duration: envelopeEnd - envelopeStart)
            * settings.oscillator(time: time - phaseOrigin, sampleRate: sampleRate)
    }
}

extension TrackTimeline {
    mutating func censor(_ settings: AudioCensorSettings?, selection: TimelineSelection, effectID: UUID = UUID(), removingOnly: UUID? = nil) {
        for i in audio.indices where selection.audio.contains(audio[i].id) {
            let item = audio[i]
            guard let target = selection.range.flatMap({ item.interval.intersection($0) }) ?? (selection.range == nil ? item.interval : nil) else { continue }
            let local = EditInterval(target.start - item.start, target.end - item.start)
            var regions: [AudioCensorRegion] = []
            for region in item.censors {
                guard (removingOnly == nil || region.id == removingOnly), region.interval.intersection(local) != nil else { regions.append(region); continue }
                if region.interval.start < local.start { var left = region; left.interval.end = local.start; let envelope = region.envelopeInterval ?? region.interval; left.envelopeInterval = EditInterval(envelope.start, local.start); regions.append(left) }
                if region.interval.end > local.end { var right = region; right.interval.start = local.end; let envelope = region.envelopeInterval ?? region.interval; right.envelopeInterval = EditInterval(local.end, envelope.end); regions.append(right) }
            }
            if let settings {
                // All pieces of one operation share the event's clock, even
                // when a later clip begins halfway through the censor range.
                let envelope = selection.range.map { EditInterval($0.start - item.start, $0.end - item.start) }
                regions.append(AudioCensorRegion(id: effectID, interval: local, phaseOrigin: envelope?.start ?? local.start,
                    settings: settings, envelopeInterval: envelope))
            }
            audio[i].censors = regions.sorted { $0.interval.start < $1.interval.start }
        }
    }

    func censorSpans(for item: AudioTimelineItem) -> [AudioCensorSpan] {
        item.censors.flatMap { region -> [AudioCensorSpan] in
            let start = item.start + region.interval.start, end = item.start + region.interval.end
            let envelope = region.envelopeInterval ?? region.interval
            let itemOrder = audio.firstIndex { $0.id == item.id } ?? 0
            let others = audio.enumerated().filter { index, other in
                !other.muted && (other.volumeDB > item.volumeDB || (other.volumeDB == item.volumeDB && index < itemOrder))
            }.flatMap { _, other in
                other.censors.filter { $0.id == region.id && $0.settings == region.settings }.map { EditInterval(other.start + $0.interval.start, other.start + $0.interval.end) }
            }.compactMap { $0.intersection(EditInterval(start, end)) }
            let points = Array(Set([start, end] + others.flatMap { [$0.start, $0.end] })).sorted()
            return zip(points, points.dropFirst()).map { a, b in
                AudioCensorSpan(start: a.seconds, end: b.seconds, phaseOrigin: (item.start + region.phaseOrigin).seconds,
                    envelopeStart: (item.start + envelope.start).seconds, envelopeEnd: (item.start + envelope.end).seconds, settings: region.settings, emitsTone: !others.contains { $0.contains(a) })
            }
        }
    }
}
