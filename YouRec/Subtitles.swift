import Foundation
import CryptoKit
import NaturalLanguage

/// Times are estimates, anchored in the original sound. Each audio item owns
/// its words by value: splits, moves, copies and Undo cannot share mutable text.
struct SubtitleWord: Codable, Equatable, Identifiable {
    var id = UUID()
    var phraseID = UUID()
    var text: String
    var start: Double
    var end: Double
}

enum SubtitleFont: String, Codable, CaseIterable {
    case system, modern, classic, mono, condensed
    var title: String { switch self { case .system: return "System"; case .modern: return "Modern"; case .classic: return "Classic"; case .mono: return "Mono"; case .condensed: return "Narrow" } }
    func postScriptName(bold: Bool) -> String? {
        switch self {
        case .system: return nil
        case .modern: return bold ? "AvenirNext-DemiBold" : "AvenirNext-Regular"
        case .classic: return bold ? "Georgia-Bold" : "Georgia"
        case .mono: return bold ? "Menlo-Bold" : "Menlo-Regular"
        case .condensed: return "DINCondensed-Bold"
        }
    }
}

struct SubtitleSettings: Codable, Equatable {
    var id = UUID()
    var maxWords = 6
    var style = TextStyle.box
    var color = TextColor.white
    var size = 0.052
    var y = 0.86
    var language = "Auto"
    var timingFingerprint = ""
    // Optional fields preserve projects written before direct caption placement.
    var x: Double?
    var font: SubtitleFont?
    var appearance: TitleDesign?
    var motion: TitleMotion?
    var design: TitleDesign { appearance ?? .legacy(style, color: color, font: resolvedFont) }
    var centerX: Double { x ?? 0.5 }
    var resolvedFont: SubtitleFont { font ?? .system }
    var valid: Bool { appearance?.valid != false && motion?.valid != false && (1...16).contains(maxWords) && size.isFinite && (0.0001...0.30).contains(size) && y.isFinite && (0...1).contains(y) && centerX.isFinite && (0...1).contains(centerX) }
}

struct SubtitleCue: Identifiable, Equatable {
    let id: String
    let audioID: UUID
    let wordIDs: [UUID]
    let text: String
    let start: Double
    let end: Double
    func overlay(_ settings: SubtitleSettings) -> TextOverlay {
        TextOverlay(text: text, start: start, end: end, x: settings.centerX, y: settings.y, size: settings.size, style: settings.style, color: settings.color, appearance: settings.appearance, motion: settings.motion)
    }
}

enum SubtitleTiming {
    /// Preserve punctuation with its preceding word; NLTokenizer also handles
    /// languages that do not separate words with spaces.
    static func tokens(_ text: String) -> [String] {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .word); tokenizer.string = value
        var starts: [String.Index] = []
        tokenizer.enumerateTokens(in: value.startIndex..<value.endIndex) { range, _ in starts.append(range.lowerBound); return true }
        guard !starts.isEmpty else { return [value] }
        starts[0] = value.startIndex
        return starts.enumerated().map { index, start in
            String(value[start..<(index + 1 < starts.count ? starts[index + 1] : value.endIndex)]).trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }
    static func joined(_ words: [String]) -> String {
        words.joined(separator: " ")
    }
    private static func weight(_ text: String) -> Double { pow(Double(max(1, text.filter(\.isLetter).count)), 0.65) }
    private static func normalized(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }

    /// Divide voiced time, never the intervening silence. Allocate each word to
    /// one speech island before interpolating within that island.
    static func estimate(_ text: String, speech: [ClosedRange<Double>]) -> [SubtitleWord] {
        let words = tokens(text), spans = speech.filter { $0.upperBound > $0.lowerBound }
        guard !words.isEmpty, !spans.isEmpty else { return [] }
        let totalTime = spans.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
        let weights = words.map(weight), totalWeight = weights.reduce(0, +)
        var grouped = Array(repeating: [Int](), count: spans.count), consumed = 0.0
        for i in words.indices {
            let midpoint = (consumed + weights[i] / 2) / totalWeight * totalTime
            var cursor = 0.0, island = spans.count - 1
            for j in spans.indices { cursor += spans[j].upperBound - spans[j].lowerBound; if midpoint < cursor { island = j; break } }
            grouped[island].append(i); consumed += weights[i]
        }
        return spans.indices.flatMap { j -> [SubtitleWord] in
            let sum = grouped[j].reduce(0.0) { $0 + weights[$1] }
            var cursor = spans[j].lowerBound
            return grouped[j].map { i in
                let end = min(spans[j].upperBound, cursor + (spans[j].upperBound - spans[j].lowerBound) * weights[i] / max(sum, 0.001))
                defer { cursor = end }
                return SubtitleWord(text: words[i], start: cursor, end: end)
            }
        }
    }
    static func group(_ input: [SubtitleWord], maxWords: Int) -> [SubtitleWord] {
        var words = input.sorted { $0.start < $1.start }, group = UUID(), count = 0
        for i in words.indices {
            if i > 0 && (count >= maxWords || words[i].start - words[i - 1].end > 0.32 || words[i - 1].text.last.map({ ".!?。！？".contains($0) }) == true) { group = UUID(); count = 0 }
            words[i].phraseID = group; count += 1
        }
        return words
    }
    /// LCS keeps unchanged words anchored. Replacements share only the freed
    /// interval between neighboring surviving words. Full rewrites retain the
    /// old phrase interval. Punctuation-only edits leave all timings intact.
    static func corrected(_ old: [SubtitleWord], text: String) -> [SubtitleWord] {
        let old = old.sorted { $0.start < $1.start }, next = tokens(text)
        guard let first = old.first, let last = old.last else { return [] }
        guard !next.isEmpty else { return [] }
        // Bound work for a pasted paragraph, without quadratic allocation.
        guard old.count <= 128, next.count <= 128 else {
            return estimate(joined(Array(next.prefix(128))), speech: [first.start...last.end]).map { var w = $0; w.phraseID = first.phraseID; return w }
        }
        let a = old.map { normalized($0.text) }, b = next.map(normalized)
        var dp = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in a.indices.reversed() { for j in b.indices.reversed() { dp[i][j] = a[i] == b[j] ? 1 + dp[i + 1][j + 1] : max(dp[i + 1][j], dp[i][j + 1]) } }
        var anchors: [(Int, Int)] = [], i = 0, j = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] { anchors.append((i, j)); i += 1; j += 1 }
            else if dp[i + 1][j] >= dp[i][j + 1] { i += 1 } else { j += 1 }
        }
        var result: [SubtitleWord] = [], priorOld = -1, priorNew = -1
        for (oi, ni) in anchors + [(old.count, next.count)] {
            if ni > priorNew + 1 {
                var start = priorOld < 0 ? first.start : old[priorOld].end
                var end = oi == old.count ? last.end : old[oi].start
                // Insertion between adjacent words has no empty interval. Borrow
                // a small part of the following/preceding word within the phrase.
                if end - start < 0.04 {
                    if oi < old.count { end = min(old[oi].end, start + (old[oi].end - old[oi].start) * 0.45) }
                    else if let previous = result.last { start = max(previous.start, previous.end - (previous.end - previous.start) * 0.45); result[result.count - 1].end = start }
                }
                let replacement = estimate(joined(Array(next[(priorNew + 1)..<ni])), speech: [start...max(start, end)])
                result += replacement.map { var w = $0; w.phraseID = first.phraseID; return w }
            }
            if oi < old.count { var w = old[oi]; w.text = next[ni]; w.start = max(w.start, result.last?.end ?? w.start); if w.end > w.start { result.append(w) } }
            priorOld = oi; priorNew = ni
        }
        return result
    }
}

extension TrackTimeline {
    var subtitleCues: [SubtitleCue] {
        guard subtitles != nil else { return [] }
        var cues: [SubtitleCue] = []
        for item in audio where !item.muted {
            var offset = 0.0
            for (runIndex, run) in item.mapping.runs.enumerated() {
                defer { offset += run.duration.seconds }
                guard !run.silent, !run.isHold else { continue }
                let scale = run.duration.seconds / (run.sourceEnd - run.sourceStart)
                let words = (item.subtitleWords ?? []).filter { $0.end > run.sourceStart && $0.start < run.sourceEnd }.sorted { $0.start < $1.start }
                var group: [SubtitleWord] = []
                func emit() {
                    guard let first = group.first, let last = group.last else { return }
                    let start = item.start.seconds + offset + (max(run.sourceStart, first.start) - run.sourceStart) * scale
                    let end = item.start.seconds + offset + (min(run.sourceEnd, last.end) - run.sourceStart) * scale
                    if end > start { cues.append(SubtitleCue(id: "\(item.id)-\(runIndex)-\(first.id)", audioID: item.id, wordIDs: group.map(\.id), text: SubtitleTiming.joined(group.map(\.text)), start: start, end: end)) }
                }
                for word in words {
                    if let last = group.last, last.phraseID != word.phraseID || word.start - last.end > 0.4 { emit(); group = [] }
                    group.append(word)
                }
                emit()
            }
        }
        return cues.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
    }
    /// Excludes color, framing, gain and caption edits. Includes structural sound
    /// and picture edits. Undo to the transcribed structure restores regrouping.
    var subtitleTimingFingerprint: String {
        struct Item: Encodable { let id: UUID; let source: UUID; let start: EditTime; let mapping: SourcePlaybackMap; let muted: Bool }
        let sound = audio.map { Item(id: $0.id, source: $0.sourceID, start: $0.start, mapping: $0.mapping, muted: $0.muted) }
        let picture = video.map { Item(id: $0.id, source: $0.content.sourceID, start: $0.start, mapping: $0.mapping, muted: false) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: (try? encoder.encode(sound + picture)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }
    var subtitleGroupingAvailable: Bool { subtitles?.timingFingerprint == subtitleTimingFingerprint }
    mutating func removeSubtitles() { subtitles = nil; for i in audio.indices { audio[i].subtitleWords = nil } }
    mutating func regroupSubtitles(_ count: Int) {
        guard subtitleGroupingAvailable, (1...16).contains(count) else { return }
        subtitles?.maxWords = count
        for i in audio.indices { audio[i].subtitleWords = SubtitleTiming.group(audio[i].subtitleWords ?? [], maxWords: count) }
    }
    mutating func correctSubtitle(_ cue: SubtitleCue, text: String) {
        guard let i = audio.firstIndex(where: { $0.id == cue.audioID }) else { return }
        let ids = Set(cue.wordIDs), words = audio[i].subtitleWords ?? []
        audio[i].subtitleWords = (words.filter { !ids.contains($0.id) } + SubtitleTiming.corrected(words.filter { ids.contains($0.id) }, text: text)).sorted { $0.start < $1.start }
    }
    /// Attach estimated project times to the strongest eligible speech track.
    /// Transitions/overlapping speakers are best effort; never duplicate a word
    /// onto both tracks. Each source time remains independent of project moves.
    mutating func installSubtitles(_ words: [SubtitleWord], range: ClosedRange<Double>, language: String) {
        let previous = subtitleCues
        var settings = subtitles ?? SubtitleSettings(); settings.language = language
        let coversExisting = previous.allSatisfy { $0.start >= range.lowerBound - 0.001 && $0.end <= range.upperBound + 0.001 }
        if subtitles == nil || subtitleGroupingAvailable || coversExisting { settings.timingFingerprint = subtitleTimingFingerprint }
        subtitles = settings
        for i in audio.indices {
            let item = audio[i]
            audio[i].subtitleWords = (item.subtitleWords ?? []).filter { word in
                guard let local = item.mapping.local(forSource: (word.start + word.end) / 2) else { return false }
                return !range.contains(item.start.seconds + local.seconds)
            }
        }
        let newIDs = Set(words.map(\.id))
        for word in words {
            let midpoint = EditTime((word.start + word.end) / 2)
            let candidates = audio.indices.filter { !audio[$0].muted && audio[$0].interval.contains(midpoint) }.sorted {
                if audio[$0].volumeDB == audio[$1].volumeDB { return audio[$0].id.uuidString < audio[$1].id.uuidString }
                return audio[$0].volumeDB > audio[$1].volumeDB
            }
            for i in candidates {
                let item = audio[i]; var cursor = item.start.seconds
                var attached = false
                for run in item.mapping.runs {
                    defer { cursor += run.duration.seconds }
                    guard !run.silent, !run.isHold, midpoint.seconds >= cursor, midpoint.seconds < cursor + run.duration.seconds else { continue }
                    var value = word
                    let a = max(cursor, word.start), b = min(cursor + run.duration.seconds, word.end)
                    value.start = run.source(at: EditTime(a - cursor)); value.end = run.source(at: EditTime(b - cursor))
                    if value.end > value.start { audio[i].subtitleWords = (audio[i].subtitleWords ?? []) + [value]; attached = true }
                    break
                }
                if attached { break }
            }
        }
        // Re-transcribing a selection must not regroup corrected captions outside it.
        for i in audio.indices {
            let all = audio[i].subtitleWords ?? []
            let preserved = all.filter { !newIDs.contains($0.id) }
            let added = SubtitleTiming.group(all.filter { newIDs.contains($0.id) }, maxWords: settings.maxWords)
            audio[i].subtitleWords = (preserved + added).sorted { $0.start < $1.start }
        }
    }
}
