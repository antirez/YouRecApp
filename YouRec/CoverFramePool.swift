import Foundation

/// Sample the editor's 30 fps clock in chronological bands, skipping empty
/// timeline gaps. The pool stays small even for a multi-hour project.
struct CoverFramePool {
    private struct Span {
        let first: Int64
        let count: Int
    }
    private static let step = EditTime.scale / 30
    private let spans: [Span]
    let count: Int

    init(picture: [EditInterval], scope: [EditInterval]) {
        let pictures = Self.merged(picture), scopes = Self.merged(scope)
        var spans: [Span] = [], i = 0, j = 0
        while i < pictures.count && j < scopes.count {
            if let interval = pictures[i].intersection(scopes[j]) {
                let gridStart = (interval.start.ticks + Self.step - 1) / Self.step * Self.step
                let first = gridStart < interval.end.ticks ? gridStart : interval.start.ticks
                spans.append(Span(first: first, count: 1 + Int((interval.end.ticks - 1 - first) / Self.step)))
            }
            if pictures[i].end < scopes[j].end { i += 1 } else { j += 1 }
        }
        self.spans = spans
        count = spans.reduce(0) { $0 + $1.count }
    }

    private static func merged(_ ranges: [EditInterval]) -> [EditInterval] {
        var result: [EditInterval] = []
        for range in ranges.sorted(by: { $0.start < $1.start }) where !range.isEmpty {
            if let last = result.last, range.start <= last.end {
                result[result.count - 1].end = max(last.end, range.end)
            } else { result.append(range) }
        }
        return result
    }

    func picks(replacing previous: [Int]) -> [Int] {
        let bands = min(count, 9)
        return (0..<bands).map { band in
            let start = band * count / bands, end = (band + 1) * count / bands
            guard end - start > 1, previous.indices.contains(band) else { return Int.random(in: start..<end) }
            let pick = Int.random(in: start..<(end - 1))
            return pick < previous[band] ? pick : pick + 1
        }
    }

    func time(of index: Int) -> EditTime {
        var offset = index
        for span in spans {
            if offset < span.count { return EditTime(ticks: span.first + Int64(offset) * Self.step) }
            offset -= span.count
        }
        preconditionFailure("Cover index outside the sampled range")
    }
}
