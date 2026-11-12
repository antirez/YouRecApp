import Foundation

/// An inspector samples the draft near the playhead. Its source ranges are
/// scoped by timeline occurrence, so a repeated or overlapping take stays distinct.
struct EffectPreviewWindow {
    let range: ClosedRange<Double>
    private let sources: [UUID: ClosedRange<Double>]

    static func range(at position: Double, within selection: ClosedRange<Double>) -> ClosedRange<Double> {
        let anchor = min(selection.upperBound, max(selection.lowerBound, position))
        return max(selection.lowerBound, anchor - 5)...min(selection.upperBound, anchor + 5)
    }

    static func label(_ range: ClosedRange<Double>) -> String {
        let seconds = range.upperBound - range.lowerBound
        let value = seconds.formatted(.number.precision(.fractionLength(seconds < 1 ? 1 : 0)))
        return "\(value) s preview"
    }

    init(_ range: ClosedRange<Double>, timeline: TrackTimeline) {
        self.range = range
        let window = EditInterval(range)
        var spans: [UUID: ClosedRange<Double>] = [:]
        for item in timeline.video {
            guard let part = item.interval.intersection(window) else { continue }
            let runs = item.mapping.sliced(EditInterval(part.start - item.start, part.end - item.start)).runs
            if let start = runs.first?.sourceStart, let end = runs.last?.sourceEnd {
                spans[item.id] = start...max(start, end)
            }
        }
        sources = spans
    }

    func analysisClip(_ clip: TimelineClip) -> TimelineClip? {
        guard let span = sources[clip.id] else { return nil }
        if clip.frozenFrame != nil { return clip }
        var sample = clip
        sample.start = max(clip.start, span.lowerBound)
        sample.end = min(clip.end, span.upperBound)
        return sample.start < sample.end ? sample : nil
    }
}

extension TimelineClip {
    var offlineVideoEffects: [VideoEffectSettings] {
        (videoEffects ?? []).filter {
            guard $0.requiresOfflineAnalysis else { return false }
            if let hold = frozenFrame { return $0.start <= hold.sourceTime && hold.sourceTime < $0.end }
            return $0.start < end && $0.end > start
        }
    }
}

/// A small intent receipt. The project document owns the edit and its undo step;
/// the normal renderer owns the reusable audio stages and picture-analysis caches.
struct EffectApplicationReceipt: Codable, Equatable {
    let projectID: UUID
    let revision: Date
    let cursor: Int
    let tool: String
    let title: String
    var latestEdit = true

    init?(project: Project, tool: VideoTool) {
        let edit = project.edit
        switch tool {
        case .videoEffects:
            let effects = edit.clips.flatMap(\.offlineVideoEffects)
            guard !effects.isEmpty else { return nil }
            let kinds = Set(effects.map(\.kind))
            title = kinds.count == 1 ? effects[0].kind.descriptor.displayName : "video effects"
        case .stabilize:
            guard edit.clips.contains(where: { $0.stabilization != nil }) else { return nil }
            title = "stabilization"
        case .enhanceAudio:
            guard edit.timeline.audio.contains(where: { $0.enhancements.contains { $0.effects.contains(where: \.enabled) } }) else { return nil }
            title = "audio effects"
        default: return nil
        }
        projectID = project.id; revision = project.updatedAt; cursor = project.historyCursor
        self.tool = tool.rawValue
    }

    private static func file(_ folder: URL) -> URL { folder.appendingPathComponent(".applying-effect.json") }
    static func pending(for project: Project, in folder: URL) -> Self? {
        guard let data = try? Data(contentsOf: file(folder)), let value = try? JSONDecoder().decode(Self.self, from: data),
              value.projectID == project.id, value.revision == project.updatedAt, value.cursor == project.historyCursor else { return nil }
        return value
    }
    func save(in folder: URL) throws { try JSONEncoder().encode(self).write(to: Self.file(folder), options: .atomic) }
    func finish(in folder: URL) {
        let file = Self.file(folder)
        guard let data = try? Data(contentsOf: file), (try? JSONDecoder().decode(Self.self, from: data)) == self else { return }
        try? FileManager.default.removeItem(at: file)
    }
}
