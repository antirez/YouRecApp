import Foundation

struct SubtitleSpeechChunk: Equatable, Sendable {
    var range: ClosedRange<Double>
    var speech: [ClosedRange<Double>]
}

enum SubtitleSpeechPlan {
    /// An energy gate identifies timing anchors, not speakers. Qwen identifies
    /// speech. The adaptive floor is capped so a continuously spoken passage
    /// does not classify its quieter syllables as background.
    static func chunks(levels: [Float], duration: Double, step: Double = 0.02) -> [SubtitleSpeechChunk] {
        guard !levels.isEmpty, duration > 0 else { return [] }
        let db = levels.map { 20 * log10(max(1e-9, Double($0))) }
        let sorted = db.sorted(), floor = sorted[min(sorted.count - 1, sorted.count / 5)]
        let threshold = max(-52, min(-35, floor + 9))
        var islands: [ClosedRange<Double>] = [], begin: Int?, last = 0
        for i in db.indices {
            if db[i] > threshold { if begin == nil { begin = i }; last = i }
            if let start = begin, (i - last > 8 || i == db.count - 1) {
                if last - start >= 2 {
                    let a = max(0, Double(start) * step - 0.08), b = min(duration, Double(last + 1) * step + 0.1)
                    if let prior = islands.last, a <= prior.upperBound { islands[islands.count - 1] = prior.lowerBound...b }
                    else if b > a { islands.append(a...b) }
                }
                begin = nil
            }
        }
        // Split long unbroken speech near the quietest 100 ms in a bounded
        // window. This keeps decoder context and activation memory bounded.
        var bounded: [ClosedRange<Double>] = []
        for island in islands {
            var a = island.lowerBound
            while island.upperBound - a > 12 {
                let lower = min(db.count - 1, Int((a + 8) / step)), upper = min(db.count - 1, Int((a + 12) / step))
                var best = lower, energy = Double.infinity
                for i in lower...upper {
                    let value = db[max(0, i - 2)...min(db.count - 1, i + 2)].reduce(0, +)
                    if value < energy { energy = value; best = i }
                }
                let b = max(a + 8, Double(best) * step)
                bounded.append(a...b); a = b
            }
            if island.upperBound > a { bounded.append(a...island.upperBound) }
        }
        var result: [SubtitleSpeechChunk] = []
        for island in bounded {
            if var previous = result.last,
               island.upperBound - previous.range.lowerBound <= 12,
               island.lowerBound - previous.range.upperBound < 0.7 || (island.lowerBound - previous.range.upperBound < 1.3 && previous.range.upperBound - previous.range.lowerBound < 3) {
                previous.range = previous.range.lowerBound...island.upperBound; previous.speech.append(island); result[result.count - 1] = previous
            } else { result.append(SubtitleSpeechChunk(range: island, speech: [island])) }
        }
        return result
    }
}
