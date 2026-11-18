import Foundation

// Crop, mirror and stabilization historically occupied one slot per picture.
// A local variant can share that slot at a different time without cutting media.
enum FramingVariant: Codable, Equatable {
    case crop(CropSettings), mirror(MirrorSettings), stabilization(UUID, StabilizationSettings)
    var id: UUID {
        switch self {
        case .crop(let v): v.id
        case .mirror(let v): v.id
        case .stabilization(let id, _): id
        }
    }
    var hasID: Bool { if case .stabilization(let id, let v) = self { return v.id == id }; return true }
    var tool: VideoTool {
        switch self { case .crop: .crop; case .mirror: .mirror; case .stabilization: .stabilize }
    }
    var label: String { tool.title }
    var activeRange: SourceInterval? {
        switch self { case .crop(let v): v.activeRange; case .mirror(let v): v.activeRange; case .stabilization(_, let v): v.activeRange }
    }
    func identified(_ id: UUID) -> Self {
        switch self {
        case .crop(var v): v.id = id; return .crop(v)
        case .mirror(var v): v.id = id; return .mirror(v)
        case .stabilization(_, var v): v.id = id; return .stabilization(id, v)
        }
    }
}

extension TimelineClip {
    func framing(_ tool: VideoTool) -> FramingVariant? {
        switch tool {
        case .crop: return crop.map(FramingVariant.crop)
        case .mirror: return mirror.map(FramingVariant.mirror)
        case .stabilize:
            guard var v = stabilization else { return nil }
            let effectID = v.id ?? id; v.id = effectID
            return .stabilization(effectID, v)
        default: return nil
        }
    }
    mutating func setFraming(_ value: FramingVariant) {
        switch value {
        case .crop(let v): crop = v
        case .mirror(let v): mirror = v
        case .stabilization(_, let v): stabilization = v
        }
    }
    func promoting(_ variant: FramingVariant) -> Self {
        var copy = self
        var others = (framingVariants ?? []).filter { $0.id != variant.id }
        if let current = framing(variant.tool), current.id != variant.id { others.append(current) }
        copy.framingVariants = others.isEmpty ? nil : others
        copy.setFraming(variant)
        return copy
    }
    var windowRecipeIDs: Set<UUID> {
        var ids = Set((texts ?? []).map(\.id))
        ids.formUnion((images ?? []).map(\.id)); ids.formUnion((videoEffects ?? []).map(\.id))
        ids.formUnion([crop?.id, mirror?.id, stabilization.map { $0.id ?? id }].compactMap { $0 })
        ids.formUnion((framingVariants ?? []).map(\.id))
        return ids
    }
    mutating func normalizeEffectWindows() {
        guard effectWindows != nil || framingVariants != nil else { return }
        var alternatives = framingVariants ?? []
        for tool in [VideoTool.crop, .mirror, .stabilize] {
            if let main = framing(tool) {
                // Applying a fresh, unscoped framing via Tools replaces the
                // previous framing on this item, including its local variants.
                if effectWindows?[main.id] == nil && main.activeRange == nil {
                    alternatives.removeAll { $0.tool == tool }
                }
            } else if let i = alternatives.firstIndex(where: { $0.tool == tool }) {
                setFraming(alternatives.remove(at: i))
            }
        }
        framingVariants = alternatives.isEmpty ? nil : alternatives
        let ids = windowRecipeIDs
        let kept = effectWindows?.filter { ids.contains($0.key) }
        effectWindows = kept?.isEmpty == false ? kept : nil
    }
    var validEffectWindows: Bool {
        let variants = framingVariants ?? []
        guard variants.allSatisfy(\.hasID), Set(variants.map(\.id)).count == variants.count,
              variants.allSatisfy({ effectWindows?[$0.id]?.isEmpty == false }) else { return false }
        guard let windows = effectWindows else { return variants.isEmpty }
        guard Set(windows.keys).isSubset(of: windowRecipeIDs) else { return false }
        return windows.values.allSatisfy { spans in
            !spans.isEmpty && spans.allSatisfy { $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start && $0.end <= 604800 }
                && zip(spans, spans.dropFirst()).allSatisfy { $0.end < $1.start }
        }
    }
    func resolvingEffects(at time: Double) -> Self {
        guard let windows = effectWindows else { return self }
        func includes(_ id: UUID) -> Bool { windows[id]?.contains { $0.contains(time) } ?? true }
        var copy = self
        copy.effectWindows = nil; copy.framingVariants = nil
        copy.texts?.removeAll { !includes($0.id) }
        copy.images?.removeAll { !includes($0.id) }
        copy.videoEffects?.removeAll { !includes($0.id) }
        if let v = crop, !includes(v.id) { copy.crop = nil }
        if let v = mirror, !includes(v.id) { copy.mirror = nil }
        if let v = stabilization, !includes(v.id ?? id) { copy.stabilization = nil }
        for variant in framingVariants ?? [] where includes(variant.id) { copy.setFraming(variant) }
        return copy
    }
    // All callers of playbackPieces (ordinary preview, transitions and export)
    // receive the same recipe. Source times, effect ordering and clocks survive.
    var resolvedEffectPieces: [Self] {
        guard let windows = effectWindows else { return [self] }
        let lower = gradeTime(at: 0), upper = gradeTime(at: duration)
        let tick = 1 / Double(EditTime.scale)
        let edges = Set(windows.values.flatMap { $0.flatMap { [$0.start, $0.end] } }
            .filter { $0 - lower > tick && upper - $0 > tick }).sorted()
        let bounds = [lower] + edges + [upper]
        return zip(bounds, bounds.dropFirst()).map { a, b in
            var piece = resolvingEffects(at: (a + b) / 2)
            if let settings = piece.stabilization {
                piece.stabilization?.referenceStart = settings.referenceStart ?? start
                piece.stabilization?.referenceEnd = settings.referenceEnd ?? end
            }
            if let hold = frozenFrame {
                piece.frozenFrame?.offset = hold.offset + a - lower
                piece.frozenFrame?.duration = b - a
            } else {
                piece.start = a; piece.end = b
            }
            return piece
        }
    }
}

// Only the requested recipe is copied into/out of a scoped inspector. A change
// to a clip-wide canvas or to another member of a filter stack cannot escape it.
private enum ScopedRecipe: Equatable {
    case text(TextOverlay), image(ImageOverlay), effect(VideoEffectSettings), framing(FramingVariant), grade(ColorSettings)

    func identified(_ id: UUID) -> Self {
        switch self {
        case .text(var v): v.id = id; return .text(v)
        case .image(var v): v.id = id; return .image(v)
        case .effect(var v):
            if v.id != id, v.analysisFile != nil || [.chromaKey, .autoBackground].contains(v.kind) { v.capturedEffectID = v.analysisID }
            v.id = id; return .effect(v)
        case .framing(let v): return .framing(v.identified(id))
        case .grade(var v): v.id = id; return .grade(v)
        }
    }
    // Keep the authored clock and geometry window. Scope edges express visibility,
    // not a new fade, strobe, animated zoom, or set of parameter keyframes.
    func keepingTiming(of original: Self) -> Self {
        switch (self, original) {
        case (.text(var v), .text(let old)): v.start = old.start; v.end = old.end; return .text(v)
        case (.image(var v), .image(let old)):
            v.start = old.start; v.end = old.end; if let clock = old.motion?.clock { v.motion?.clock = clock }; return .image(v)
        case (.effect(var v), .effect(let old)):
            v.start = old.start; v.end = old.end; v.phaseOffset = old.phaseOffset; v.strobeTimeMap = old.strobeTimeMap
            if let clock = old.motion?.clock { v.motion?.clock = clock }; return .effect(v)
        case (.framing(.crop(var v)), .framing(.crop(let old))):
            v.activeRange = old.activeRange; if let clock = old.motion?.clock { v.motion?.clock = clock }; return .framing(.crop(v))
        case (.framing(.mirror(var v)), .framing(.mirror(let old))): v.activeRange = old.activeRange; return .framing(.mirror(v))
        case (.framing(.stabilization(let id, var v)), .framing(.stabilization(_, let old))): v.activeRange = old.activeRange; return .framing(.stabilization(id, v))
        case (.grade(var v), .grade(let old)): if let clock = old.motion?.clock { v.motion?.clock = clock }; return .grade(v)
        default: return self
        }
    }
}

private extension TimelineClip {
    func recipe(_ tool: VideoTool, _ id: UUID) -> ScopedRecipe? {
        switch tool {
        case .text: return texts?.first { $0.id == id }.map(ScopedRecipe.text)
        case .image: return images?.first { $0.id == id }.map(ScopedRecipe.image)
        case .videoEffects: return videoEffects?.first { $0.id == id }.map(ScopedRecipe.effect)
        case .color: return visibleGrades.first { $0.grade.id == id }.map { .grade($0.grade) }
        default: return (framing(tool).flatMap { $0.id == id ? $0 : nil } ?? framingVariants?.first { $0.id == id }).map(ScopedRecipe.framing)
        }
    }
    mutating func setRecipe(_ recipe: ScopedRecipe?, tool: VideoTool, id: UUID, beside parent: UUID) {
        func update<T: Identifiable>(_ array: inout [T]?, _ value: T?) where T.ID == UUID {
            var values = array ?? []
            if let index = values.firstIndex(where: { $0.id == id }) {
                if let value { values[index] = value } else { values.remove(at: index) }
            } else if let value {
                let index = values.firstIndex { $0.id == parent }.map { $0 + 1 } ?? values.count
                values.insert(value, at: index)
            }
            array = values.isEmpty ? nil : values
        }
        switch tool {
        case .text: if case .text(let v) = recipe { update(&texts, v) } else { update(&texts, nil) }
        case .image: if case .image(let v) = recipe { update(&images, v) } else { update(&images, nil) }
        case .videoEffects: if case .effect(let v) = recipe { update(&videoEffects, v) } else { update(&videoEffects, nil) }
        case .crop, .mirror, .stabilize:
            var alternatives = (framingVariants ?? []).filter { $0.id != id }
            if framing(tool)?.id == id || framing(tool) == nil {
                if case .framing(let v) = recipe { setFraming(v) }
                else if let index = alternatives.firstIndex(where: { $0.tool == tool }) { setFraming(alternatives.remove(at: index)) }
                else { switch tool { case .crop: crop = nil; case .mirror: mirror = nil; default: stabilization = nil } }
            } else if case .framing(let v) = recipe { alternatives.append(v) }
            framingVariants = alternatives.isEmpty ? nil : alternatives
        default: break
        }
    }
    mutating func setWindows(_ ranges: [EditInterval], for id: UUID) {
        var windows = effectWindows ?? [:]
        let spans = TrackTimeline.union(ranges).map { SourceInterval(start: $0.start.seconds, end: $0.end.seconds) }
        windows[id] = spans.isEmpty ? nil : spans
        effectWindows = windows.isEmpty ? nil : windows
    }
}

struct ScopedEffectOperation {
    let region: ToolRegion
    let event: [ToolRegion]
    let parts: [UUID: [EditInterval]]
    let local: Bool
    let scopeName: String
    private let variant = UUID()

    init?(_ region: ToolRegion, in state: EditState, selection: TimelineSelection?, all: [ToolRegion]) {
        guard region.tool.hasEditableRange else { return nil }
        if region.tool == .videoEffects, let fx = state.timeline.video.first(where: { $0.id == region.clipID })?.content.videoEffects?.first(where: { $0.id == region.effectID }),
           fx.kind.descriptor.family == .time { return nil } // These operations retime the underlying footage.
        self.region = region
        event = state.applicationRegions(for: region, matching: all.filter { $0.tool == region.tool && $0.effectID == region.effectID })
        var parts: [UUID: [EditInterval]] = [:]
        let isAudio = region.tool.isAudioRange
        let selected = selection.map { isAudio ? $0.audio : $0.video }
        for member in event {
            if let selected, !selected.contains(member.clipID) { continue }
            let interval = EditInterval(member.range)
            if let marked = selection?.range {
                if let overlap = interval.intersection(marked) { parts[member.clipID, default: []].append(overlap) }
            } else { parts[member.clipID, default: []].append(interval) }
        }
        guard !parts.isEmpty else { return nil }
        local = selection != nil
        if local {
            let complete = event.allSatisfy { member in parts[member.clipID]?.contains(EditInterval(member.range)) == true }
            guard !complete else { return nil }
        }
        self.parts = parts.mapValues(TrackTimeline.union)
        scopeName = selection?.range != nil ? "marked range" : parts.count == 1 ? (isAudio ? "this audio clip" : "this clip") : "selected clips"
    }

    var range: ClosedRange<Double> {
        let all = parts.values.joined()
        return all.map(\.start).min()!.seconds...all.map(\.end).max()!.seconds
    }
    var renderedID: UUID { local ? variant : region.effectID }
    func contains(projectTime: Double, owner: UUID? = nil) -> Bool {
        let t = EditTime(projectTime)
        func includes(_ span: EditInterval) -> Bool { span.contains(t) }
        if let owner { return parts[owner]?.contains(where: includes) == true }
        return parts.values.contains { $0.contains(where: includes) }
    }
    // Native inspectors can still edit a simple whole application directly.
    func needsProjection(in state: EditState) -> Bool {
        if local { return true }
        if event.count > Set(event.map(\.clipID)).count { return true }
        if TrackTimeline.union(event.map { EditInterval($0.range) }).count > 1 { return true }
        if region.tool.isAudioRange || region.tool == .color {
            let hull = EditInterval(range)
            let owners = region.tool.isAudioRange
                ? state.timeline.audio.map { ($0.id, $0.interval) }
                : state.timeline.video.map { ($0.id, $0.interval) }
            for (id, interval) in owners {
                if let spans = parts[id], let intersection = interval.intersection(hull), spans != [intersection] { return true }
            }
        }
        return state.timeline.video.contains { item in parts[item.id] != nil && (item.content.effectWindows?[region.effectID] != nil || item.content.framingVariants?.contains { $0.id == region.effectID } == true) }
    }
    func request() -> ToolRequest {
        let ids = Set(parts.keys), audio = region.tool.isAudioRange
        return ToolRequest(tool: region.tool, range: range, scopeTitle: (local ? scopeName.prefix(1).uppercased() + scopeName.dropFirst() : "Entire effect") + " · " + range.lowerBound.formatted(.number.precision(.fractionLength(0...2))) + "–" + range.upperBound.formatted(.number.precision(.fractionLength(0...2))) + " s",
                           effectID: region.effectID, clipIDs: audio ? nil : ids, scopedEffect: self,
                           targets: TimelineSelection(video: audio ? [] : ids, audio: audio ? ids : [], range: audio ? EditInterval(range) : nil))
    }

    func inspectorState(_ state: EditState) -> EditState {
        var result = state
        for i in result.timeline.video.indices where parts[result.timeline.video[i].id] != nil {
            let clip = result.timeline.video[i].content
            if let variant = clip.framingVariants?.first(where: { $0.id == region.effectID }) {
                result.timeline.video[i].content = clip.promoting(variant)
            }
        }
        return result
    }

    func removing(from state: EditState) -> EditState { updating(state, edited: nil) }
    func applying(_ edited: EditState, to state: EditState) -> EditState { updating(state, edited: edited) }

    private func updating(_ state: EditState, edited: EditState?) -> EditState {
        var result = state
        let id = region.effectID, destination = local ? variant : id
        var changed = false
        if !local, region.tool == .crop, let edited, edited.outputSize != state.outputSize {
            result.outputSize = edited.outputSize; changed = true
        }
        let titles = region.tool == .text ? TitleMotionRanges(state) : TitleMotionRanges()
        func titleClock(_ item: VideoTimelineItem, _ title: TextOverlay) -> TitlePlaybackClock? {
            if let clock = title.playbackClock { return clock }
            guard let occurrence = event.first(where: { $0.clipID == item.id }),
                  let range = titles.range(for: title, at: (occurrence.range.lowerBound + occurrence.range.upperBound) / 2)
            else { return nil }
            let anchor = EffectAnimation(EffectPose(values: [:]), duration: range.upperBound - range.lowerBound)
                .anchored(to: item.content, offset: item.start.seconds - range.lowerBound)
            return TitlePlaybackClock(duration: anchor.duration, points: anchor.clock)
        }
        for i in result.timeline.video.indices {
            let item = result.timeline.video[i]
            guard let selected = parts[item.id], let original = item.content.recipe(region.tool, id) else { continue }
            var next = edited?.timeline.video.first { $0.id == item.id }?.content.recipe(region.tool, id)?.keepingTiming(of: original).identified(id)
            guard next != original else { continue }
            if case .text(var title) = next, case .text(let old) = original, title.motion == old.motion {
                title.playbackClock = titleClock(item, old); next = .text(title)
            }
            let affected = sourceRanges(selected, item: item)
            let coverage = sourceRanges(event.filter { $0.clipID == item.id }.map { EditInterval($0.range) }, item: item)
            guard !affected.isEmpty else { continue }
            var clip = item.content
            if region.tool == .stabilize, clip.stabilization?.id == nil, clip.stabilization != nil {
                clip.stabilization?.id = item.content.id
            }
            if region.tool == .color {
                var grades = clip.visibleGrades
                for part in affected {
                    grades = grades.flatMap { entry -> [ColorRegion] in
                        let span = EditInterval(entry.start...entry.end)
                        guard entry.grade.id == id, let inside = span.intersection(part) else { return [entry] }
                        var pieces = span.subtracting(inside).map { ColorRegion(start: $0.start.seconds, end: $0.end.seconds, grade: entry.grade) }
                        if case .grade(let grade) = next?.identified(destination) {
                            pieces.append(ColorRegion(start: inside.start.seconds, end: inside.end.seconds, grade: grade))
                        }
                        return pieces
                    }
                }
                clip.color = nil; clip.colorRegions = grades.isEmpty ? nil : grades.sorted { $0.start < $1.start }
            } else {
                let outside = affected.reduce(coverage) { rest, part in rest.flatMap { $0.subtracting(part) } }
                if !local, let next { clip.setRecipe(next, tool: region.tool, id: id, beside: id) }
                else {
                    if let next {
                        clip.setRecipe(next.identified(destination), tool: region.tool, id: destination, beside: id)
                        clip.setWindows(affected, for: destination)
                    }
                    clip.setWindows(outside, for: id)
                    if outside.isEmpty { clip.setRecipe(nil, tool: region.tool, id: id, beside: id) }
                }
            }
            result.timeline.video[i].content = clip
            changed = true
        }
        for i in result.timeline.audio.indices where region.tool.isAudioRange {
            var item = result.timeline.audio[i]
            guard let selected = parts[item.id] else { continue }
            let draft = edited?.timeline.audio.first { $0.id == item.id }
            for projectPart in selected {
                let localPart = EditInterval(projectPart.start - item.start, projectPart.end - item.start)
                if region.tool == .enhanceAudio {
                    let next = draft?.enhancements.first { $0.id == id && $0.interval.intersection(localPart) != nil }?.effects
                    item.enhancements = item.enhancements.flatMap { entry in
                        guard entry.id == id, let hit = entry.interval.intersection(localPart), next != entry.effects else { return [entry] }
                        changed = true
                        var pieces = entry.interval.subtracting(hit).map { part in var keep = entry; keep.interval = part; return keep }
                        if let next { pieces.append(AudioEnhancementRegion(id: destination, interval: hit, effects: next)) }
                        return pieces.sorted { $0.interval.start < $1.interval.start }
                    }
                } else {
                    let next = draft?.censors.first { $0.id == id && $0.interval.intersection(localPart) != nil }?.settings
                    item.censors = item.censors.flatMap { entry in
                        guard entry.id == id, let hit = entry.interval.intersection(localPart), next != entry.settings else { return [entry] }
                        changed = true
                        var pieces = entry.interval.subtracting(hit).map { part in
                            var keep = entry; keep.interval = part; keep.envelopeInterval = entry.envelopeInterval ?? entry.interval; return keep
                        }
                        if let next {
                            var v = entry; v.interval = hit; v.envelopeInterval = entry.envelopeInterval ?? entry.interval
                            v.id = destination; v.settings = next; pieces.append(v)
                        }
                        return pieces.sorted { $0.interval.start < $1.interval.start }
                    }
                }
            }
            result.timeline.audio[i] = item
        }
        guard changed else { return state }
        let owners = Set(event.map(\.clipID))
        if region.tool.isAudioRange {
            for i in result.timeline.audio.indices where owners.contains(result.timeline.audio[i].id) {
                result.timeline.audio[i].spanningEffects = (result.timeline.audio[i].spanningEffects ?? []).union([id, destination])
            }
        } else {
            for i in result.timeline.video.indices where owners.contains(result.timeline.video[i].id) {
                let item = result.timeline.video[i]
                if region.tool == .text, let j = item.content.texts?.firstIndex(where: { $0.id == id }),
                   let old = state.timeline.video[i].content.texts?.first(where: { $0.id == id }),
                   item.content.texts?[j].motion == old.motion {
                    result.timeline.video[i].content.texts?[j].playbackClock = titleClock(state.timeline.video[i], old)
                }
                result.timeline.video[i].spanningEffects = (result.timeline.video[i].spanningEffects ?? []).union([id, destination])
            }
        }
        return result.normalizedTools()
    }

    /// The existing handle editor supplies recipes and animation clocks for new
    /// footage. Install them only on the old visible pieces and the two edges
    /// swept by the handles. Its bounding interval may contain a different look.
    func reshaped(in state: EditState, using proposed: EditState, to range: EditInterval, eligible: Set<UUID>) -> EditState {
        var result = state
        let hull = EditInterval(self.range), id = region.effectID, tool = region.tool
        let growth = range.subtracting(hull)
        let others = state.toolRegions.filter { $0.tool == tool && $0.effectID != id }
        func coverage(for owner: UUID, on track: EditInterval) -> [EditInterval] {
            var newlyCovered = growth.compactMap { $0.intersection(track) }
            if tool.isAudioRange || [.color, .mirror, .crop, .stabilize].contains(tool) {
                for other in others where other.clipID == owner {
                    newlyCovered = newlyCovered.flatMap { $0.subtracting(EditInterval(other.range)) }
                }
            }
            return TrackTimeline.union((parts[owner] ?? []).compactMap { $0.intersection(range) } + newlyCovered)
        }
        for i in result.timeline.video.indices where !tool.isAudioRange {
            let item = result.timeline.video[i]
            guard eligible.contains(item.id), parts[item.id] != nil || growth.contains(where: { $0.intersection(item.interval) != nil }) else { continue }
            let spans = sourceRanges(coverage(for: item.id, on: item.interval), item: item)
            var clip = item.content
            let recipe = proposed.timeline.video.first(where: { $0.id == item.id })?.content.recipe(tool, id)
            if tool == .color {
                var grades = clip.visibleGrades.filter { $0.grade.id != id }
                if case .grade(let value) = recipe {
                    grades += spans.map { ColorRegion(start: $0.start.seconds, end: $0.end.seconds, grade: value) }
                }
                clip.color = nil; clip.colorRegions = grades.isEmpty ? nil : grades.sorted { $0.start < $1.start }
            } else {
                clip.setRecipe(spans.isEmpty ? nil : recipe, tool: tool, id: id, beside: id)
                clip.setWindows(recipe == nil ? [] : spans, for: id)
            }
            result.timeline.video[i].content = clip
            if !spans.isEmpty { result.timeline.video[i].spanningEffects = (item.spanningEffects ?? []).union([id]) }
        }
        for i in result.timeline.audio.indices where tool.isAudioRange {
            let item = result.timeline.audio[i]
            guard eligible.contains(item.id), let draft = proposed.timeline.audio.first(where: { $0.id == item.id }),
                  parts[item.id] != nil || growth.contains(where: { $0.intersection(item.interval) != nil }) else { continue }
            let spans = coverage(for: item.id, on: item.interval).map { EditInterval($0.start - item.start, $0.end - item.start) }
            if tool == .enhanceAudio {
                let copies = draft.enhancements.filter { $0.id == id }.flatMap { value in
                    spans.compactMap { span -> AudioEnhancementRegion? in
                        guard let overlap = span.intersection(value.interval) else { return nil }
                        var result = value; result.interval = overlap; return result
                    }
                }
                result.timeline.audio[i].enhancements = (item.enhancements.filter { $0.id != id } + copies).sorted { $0.interval.start < $1.interval.start }
            } else {
                let copies = draft.censors.filter { $0.id == id }.flatMap { value in
                    spans.compactMap { span -> AudioCensorRegion? in
                        guard let overlap = span.intersection(value.interval) else { return nil }
                        var result = value; result.interval = overlap; return result
                    }
                }
                result.timeline.audio[i].censors = (item.censors.filter { $0.id != id } + copies).sorted { $0.interval.start < $1.interval.start }
            }
            if !spans.isEmpty { result.timeline.audio[i].spanningEffects = (item.spanningEffects ?? []).union([id]) }
        }
        return result.normalizedTools()
    }

    private func sourceRanges(_ parts: [EditInterval], item: VideoTimelineItem) -> [EditInterval] {
        TrackTimeline.union(parts.map { span in
            EditInterval(EditTime(item.content.gradeTime(at: (span.start - item.start).seconds)),
                         EditTime(item.content.gradeTime(at: (span.end - item.start).seconds)))
        }.filter { !$0.isEmpty })
    }
}

private extension EditInterval {
    func subtracting(_ part: EditInterval) -> [EditInterval] {
        guard let hit = intersection(part) else { return [self] }
        return [EditInterval(start, hit.start), EditInterval(hit.end, end)].filter { !$0.isEmpty }
    }
}
