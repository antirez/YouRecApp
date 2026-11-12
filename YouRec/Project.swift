import Foundation
import CryptoKit

enum ProjectCacheLocation {
    // Older builds used both "Cache" and "cache". A sandbox on a
    // case-insensitive filesystem may reject creating the alternate spelling
    // even though stat() finds it. Keep the exact spelling already on disk.
    // On a case-sensitive device with both legacy folders, preserve each one.
    static func root(in folder:URL,preferred:String="Cache")->URL {
        let entries=(try? FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:[.isDirectoryKey])) ?? []
        let matches=entries.filter {$0.lastPathComponent.caseInsensitiveCompare("Cache") == .orderedSame && (try? $0.resourceValues(forKeys:[.isDirectoryKey]).isDirectory)==true}
        return (matches.first(where:{$0.lastPathComponent==preferred}) ?? matches.first ?? folder.appendingPathComponent("Cache",isDirectory:true)).standardizedFileURL
    }
}

struct CaptureEvent: Codable, Identifiable, Equatable {
    var id = UUID()
    var time: Double
    var kind: String
    var detail: String
}

extension CaptureEvent {
    static func recovered(_ events: [CaptureEvent], duration: Double) -> [CaptureEvent] {
        events.filter { $0.time.isFinite && $0.time >= 0 && $0.time < duration }
    }
}

struct SourceMedia: Codable, Identifiable, Equatable {
    var id = UUID()
    var filename: String
    var duration: Double
    var recordedAt = Date()
    var events: [CaptureEvent]?
    var sha256: String?
    var videoEffects: [VideoEffectSettings]?
    var audioOnly: Bool?
    var isStillPhoto: Bool?
    var originalName: String?
}

struct TimelineClip: Codable, Identifiable, Equatable {
    var id = UUID()
    var sourceID: UUID
    var start: Double
    var end: Double
    // Optional so existing projects/history decode with stabilization off.
    var stabilization: StabilizationSettings?
    var speed: SpeedSettings?
    var color: ColorSettings?
    var texts: [TextOverlay]?
    var pauses: PauseSettings?
    var crop: CropSettings?
    var mirror: MirrorSettings?
    var images: [ImageOverlay]?
    var openingTransition: ClipTransition?
    var transition: ClipTransition?
    var videoEffects: [VideoEffectSettings]?
    var frozenFrame: FrozenFrameSegment?
    var duration: Double { frozenFrame?.duration ?? effectPlaybackSpans.reduce(0) { $0 + $1.duration } }
}

enum EffectKind: Codable, CaseIterable, Identifiable, Hashable {
    case voiceIsolation, studioVoice, studioRestoration, highPass, equalizer, gain
    case unavailable(String)
    static let allCases: [EffectKind] = [.voiceIsolation, .studioVoice, .studioRestoration, .highPass, .equalizer, .gain]
    var isSupported: Bool { Self.allCases.contains(self) }
    var isNeural: Bool { self == .voiceIsolation || self == .studioVoice || self == .studioRestoration }
    var id: String { rawValue }
    var rawValue: String {
        switch self {
        case .voiceIsolation: return "voiceIsolation"
        case .studioVoice: return "studioVoice"
        case .studioRestoration: return "studioRestoration"
        case .highPass: return "highPass"
        case .equalizer: return "equalizer"
        case .gain: return "gain"
        case .unavailable(let name): return name
        }
    }
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self.allCases.first { $0.rawValue == value } ?? .unavailable(value)
    }
    func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }
    var title: String {
        switch self {
        case .voiceIsolation: return "Noise reduction"
        case .studioVoice: return "Speech detail restoration"
        case .studioRestoration: return "Studio restoration"
        case .highPass: return "Low-cut filter"
        case .equalizer: return "Voice EQ"
        case .gain: return "Output gain"
        case .unavailable: return "Unavailable filter"
        }
    }
}

struct AudioModel: Codable, Equatable {
    let id: String
    let weightsSHA256: String
    let runtime: String
    static let rnnoise = AudioModel(id: "rnnoise-v0.1-cdf196b1",
        weightsSHA256: "f0cdb52b30501aab489f90fedbc7a023c719d91b337db2da7f26fc3036556b95",
        runtime: "yourec-rnnoise-c-v1")
    static let lava = AudioModel(id: "lavasr-v2-33ac0408",
        weightsSHA256: "1ef7557e72c9b2ee78ccb35cf3ab3400c0c73be1838ab16ff7dde52934f4d2cf",
        runtime: "yourec-coreml-fp32-lava-dsp-v1")
    static let voiceFixer = AudioModel(id: "voicefixer-aae2253c",
        weightsSHA256: "67971970d18c06c1220dc63df11aa0186f787dc961c829dcd1624dad3d612360",
        runtime: "yourec-voicefixer-coreml-44100-context256-overlap-v2")
    static let deepFilter = AudioModel(id: "deepfilternet3-dfc12319",
        weightsSHA256: "1114ff972e25679e7f9707da85eee62659e1bdf50199035ecacba12e4ec0425d",
        runtime: "yourec-dfn3-coreml-cpu-v1-dsp3dd66dea-milc2141d48")
}

// Optional model metadata keeps pre-AI project documents readable. An enabled
// unknown model is an explicit render error; it is never silently substituted.
struct AudioEffect: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: EffectKind
    var enabled = true
    var amount: Double = 0
    var frequency: Double = 1800
    var implementationVersion = 1
    var model: AudioModel?
    var supported: Bool {
        guard kind.isSupported, implementationVersion == 1 else { return false }
        if kind == .voiceIsolation { return amount == 0 || model == .rnnoise || model == .deepFilter }
        if kind == .studioVoice { return amount == 0 || model == .lava }
        if kind == .studioRestoration { return amount == 0 || model == .voiceFixer }
        return true
    }
    static func make(_ kind: EffectKind) -> AudioEffect {
        AudioEffect(kind: kind, amount: kind == .studioVoice ? 0.35 : kind.isNeural ? 1 : 0,
                    frequency: kind == .highPass ? 80 : 1800,
                    model: kind == .voiceIsolation ? .rnnoise : kind == .studioVoice ? .lava : kind == .studioRestoration ? .voiceFixer : nil)
    }
}

struct EditState: Codable, Equatable {
    var timeline: TrackTimeline
    // Only Crop sets a fixed output size. In automatic mode an edit may keep
    // an earlier take as its reference even after a different clip moves ahead of it.
    var outputSize: CGSize?
    private(set) var canvasReference: UUID?
    fileprivate var firstVideoSourceID: UUID? { timeline.video.min { $0.start < $1.start }?.content.sourceID }
    var canvasSourceID: UUID? {
        if let canvasReference, timeline.video.contains(where: { $0.content.sourceID == canvasReference }) { return canvasReference }
        return firstVideoSourceID
    }

    mutating func retainCanvasReference(from previous: EditState) {
        canvasReference = nil
        guard outputSize == nil, let reference = previous.canvasSourceID,
              reference != firstVideoSourceID, timeline.video.contains(where: { $0.content.sourceID == reference }) else { return }
        canvasReference = reference
    }
    var clips: [TimelineClip] {
        get { timeline.projectedClips }
        set { timeline.replaceVideoContents(newValue) }
    }
    // Kept as an inspector convenience while the audio UI is moved into Tools.
    // The persisted data is always per audio item/interval.
    var effects: [AudioEffect] {
        get { timeline.audio.first?.enhancements.first?.effects ?? [] }
        set { timeline.enhance(newValue, selection: timeline.entireSelection()) }
    }
    var duration: Double { timeline.duration.seconds }
    init(clips: [TimelineClip] = [], effects: [AudioEffect] = [], outputSize: CGSize? = nil) {
        timeline = TrackTimeline(clips: clips, effects: effects); self.outputSize = outputSize
    }
    init(timeline: TrackTimeline, outputSize: CGSize? = nil) { self.timeline = timeline; self.outputSize = outputSize }
    private enum CodingKeys: String, CodingKey { case timeline, outputSize, canvasReference, clips, effects }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        outputSize = try values.decodeIfPresent(CGSize.self, forKey: .outputSize)
        canvasReference = try values.decodeIfPresent(UUID.self, forKey: .canvasReference)
        if let saved = try values.decodeIfPresent(TrackTimeline.self, forKey: .timeline) { timeline = saved; timeline.restoreSourceMute(); timeline.retainUniqueTransitionSlots() }
        else {
            // Explicit conversion of existing development projects. There is no
            // alternate legacy playback path or modification of original media.
            timeline = TrackTimeline(clips: try values.decode([TimelineClip].self, forKey: .clips), effects: try values.decodeIfPresent([AudioEffect].self, forKey: .effects) ?? [])
        }
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(timeline, forKey: .timeline)
        try values.encodeIfPresent(outputSize, forKey: .outputSize)
        try values.encodeIfPresent(canvasReference, forKey: .canvasReference)
    }
}

/// Immutable edit payload. Capture is journaled independently, so a new take
/// never rewrites a historical snapshot or becomes an accidental Undo step.
final class EditSnapshot: Codable, @unchecked Sendable {
    let state: EditState
    let captureCursor: Int
    private let lock = NSLock()
    private var encoded: Data?
    private enum CodingKeys: String, CodingKey { case state, captureCursor }
    init(_ state: EditState, cursor: Int) { self.state = state; captureCursor = cursor }
    static func decode(_ bytes: Data) throws -> EditSnapshot {
        let result = try JSONDecoder().decode(Self.self, from: bytes)
        result.encoded = bytes
        return result
    }
    func data() throws -> Data {
        lock.lock(); defer { lock.unlock() }
        if let encoded { return encoded }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self); encoded = data; return data
    }
}
private struct CaptureLedgerEntry: Codable {
    let clip: TimelineClip
    let insertion: Bool
}
private struct RecordingInsertionSite: Codable {
    let site: VideoInsertionSite
    let firstCapture: Int
}
struct DeferredProjectHistory {
    let manifest: URL
    let count: Int
    let cursor: Int
}

struct Project: Codable, Identifiable {
    static let latestReadableSchema = 12
    private enum CodingKeys: String, CodingKey {
        case automaticCanvasVersion, exportSettings, schemaVersion, id, title, createdAt, updatedAt, sources, history, historyCursor, recordingHistoryVersion, recordingInsertion, recordingInsertionStep, recordingSite, snapshots, snapshotFiles, captureLedger
    }
    var exportSettings = ExportSettings()
    var schemaVersion = 6
    var id = UUID()
    var title: String
    var createdAt = Date()
    var updatedAt = Date()
    var sources: [SourceMedia] = []
    fileprivate var snapshots = [EditSnapshot(EditState(), cursor: 0)]
    private var captureLedger: [CaptureLedgerEntry] = []
    var deferredHistory: DeferredProjectHistory?
    // Runtime provenance only. Pin the damaged index before the first edit
    // publishes over it, even after older rotating backups expire.
    var recoveryOrigin: String?
    // Explicit fixture/import callers can still replace a complete history.
    // Normal editing uses snapshots directly, and materializes only its cursor.
    var history: [EditState] {
        get { snapshots.map(materialized) }
        set { snapshots = newValue.map { EditSnapshot($0, cursor: 0) }; captureLedger = [] }
    }
    init(title: String) { self.title = title }
    private func materialized(_ snapshot: EditSnapshot) -> EditState { materialized(snapshot, through: captureLedger.count) }
    private func materialized(_ snapshot: EditSnapshot, through captureCount: Int) -> EditState {
        var state = snapshot.state
        for event in captureLedger.prefix(captureCount).dropFirst(snapshot.captureCursor) where !event.insertion {
            var addition = TrackTimeline(clips: [event.clip])
            let position = state.timeline.duration
            let layer = (state.timeline.video.map(\.layer).max() ?? -1) + 1
            for i in addition.video.indices { addition.video[i].start = addition.video[i].start + position; addition.video[i].layer = layer }
            for i in addition.audio.indices { addition.audio[i].start = addition.audio[i].start + position }
            state.timeline.video += addition.video; state.timeline.audio += addition.audio; state.timeline.links += addition.links
            if let source = sources.first(where: { $0.id == event.clip.sourceID }) { state.timeline.includeCaptureBookmarks(source) }
        }
        state.timeline.captureBase = captureCount
        return state
    }
    var historyCursor = 0
    // Missing in older documents, where adding a captured segment was undoable.
    var recordingHistoryVersion: Int? = 1
    var recordingInsertion: Double? { didSet { if recordingInsertion == nil { recordingSite = nil } } }
    var recordingInsertionStep: Int?
    private var recordingSite: RecordingInsertionSite?
    mutating func beginRecordingInsertion(at position: Double, site: VideoInsertionSite?) {
        recordingInsertion = position
        recordingInsertionStep = nil
        recordingSite = site.map { RecordingInsertionSite(site: $0, firstCapture: captureLedger.count) }
    }
    func recordingPlacement() throws -> TakeReceipt.Placement {
        guard let recordingInsertion, deferredHistory == nil else { throw ProjectError.invalidDocument }
        return try TakeReceipt.Placement(time: recordingInsertion, site: recordingSite?.site,
                                         revision: RecoveryFile.hash(snapshots[historyCursor].data()) + ".json", captureCount: captureLedger.count)
    }
    var edit: EditState { materialized(snapshots[historyCursor]) }
    var imageFiles: [String] { Array(Set(history.flatMap { $0.clips.flatMap { ($0.images ?? []).map(\.filename) } })).sorted() }
    var effectFiles: [String] {
        let effects = sources.flatMap { $0.videoEffects ?? [] } + history.flatMap { $0.clips.flatMap { $0.videoEffects ?? [] } }
        let luts = history.flatMap { $0.clips.flatMap { ($0.color?.lutAssets ?? []).map(\.filename) } }
        return Array(Set(effects.flatMap(\.mediaFiles) + luts)).sorted()
    }
    var fontFiles: [String] {
        var files = Set<String>()
        for snapshot in snapshots { files.formUnion(snapshot.state.importedFontFiles) }
        for capture in captureLedger {
            for text in capture.clip.texts ?? [] {
                if let face = text.appearance?.face, let ref = ImportedFontFace.Reference(face) { files.insert(ref.filename) }
            }
        }
        return files.sorted()
    }
    var mediaFiles: [String] { sources.map(\.filename) + Array(Set(imageFiles + effectFiles + fontFiles)).sorted() }
    var hasSourceMedia: Bool { !sources.isEmpty }
    var capturedDuration: Double { sources.reduce(0) { $0 + $1.duration } }
    var canUndo: Bool { (deferredHistory?.cursor ?? historyCursor) > 0 }
    var canRedo: Bool { (deferredHistory?.cursor ?? historyCursor) + 1 < (deferredHistory?.count ?? snapshots.count) }

    func canCommit(_ state: EditState) -> Bool {
        guard let base = state.timeline.captureBase else { return true }
        return !captureLedger.dropFirst(max(0, base)).contains { $0.insertion }
    }
    mutating func commit(_ state: EditState) {
        guard canCommit(state) else { return }
        let previous = edit
        var state = state.normalizedTools()
        state.retainCanvasReference(from: previous)
        guard state != previous else { return }
        // Older readers must not silently discard independent placement crops.
        schemaVersion = max(schemaVersion, state.timeline.placements.contains { $0.videos.values.contains { $0.edgeCrop != nil } } ? 7 : 6)
        if state.timeline.video.contains(where: { item in
            let clip = item.content
            return clip.crop?.motion != nil || clip.color?.motion != nil || (clip.images ?? []).contains { $0.motion != nil }
                || (clip.videoEffects ?? []).contains { $0.motion != nil }
        }) || state.timeline.placements.contains(where:{ $0.videos.values.contains { $0.motion != nil } }) { schemaVersion = max(schemaVersion,12) }
        if state.timeline.subtitles != nil { schemaVersion = max(schemaVersion, 8) }
        // An older reader would pick the first timeline picture and silently reframe the movie.
        if state.canvasReference != nil { schemaVersion = max(schemaVersion, 10) }
        if state.timeline.audio.contains(where: { $0.fadeIn != nil || $0.fadeOut != nil }) { schemaVersion = max(schemaVersion, 11) }
        // Older builds must not silently discard a censor and reveal speech.
        if state.timeline.audio.contains(where: { !$0.censors.isEmpty }) || sources.contains(where: { $0.audioOnly == true }) { schemaVersion = max(schemaVersion, 9) }
        snapshots = Array(snapshots.prefix(historyCursor + 1))
        snapshots.append(EditSnapshot(state, cursor: min(captureLedger.count, max(0, state.timeline.captureBase ?? captureLedger.count))))
        historyCursor += 1
        updatedAt = Date()
    }
    mutating func append(_ source: SourceMedia) {
        protectRecordingHistory()
        if !(source.videoEffects ?? []).isEmpty { schemaVersion = max(schemaVersion, 5) }
        sources.append(source)
        includeRecording(source)
    }
    mutating func addRecording(_ source: SourceMedia) {
        schemaVersion = max(schemaVersion, 2)
        if let position = recordingInsertion {
            if !(source.videoEffects ?? []).isEmpty { schemaVersion = max(schemaVersion, 5) }
            sources.append(source)
            let clip = TimelineClip(sourceID: source.id, start: 0, end: source.duration, videoEffects: source.videoEffects)
            captureLedger.append(CaptureLedgerEntry(clip: clip, insertion: true))
            let continuing = recordingInsertionStep == historyCursor && historyCursor > 0 && historyCursor == snapshots.count - 1
            if !continuing, recordingInsertionStep != nil, let previous = recordingSite {
                recordingSite = RecordingInsertionSite(site: previous.site, firstCapture: captureLedger.count - 1)
            }
            var next: EditState
            if let recordingSite, continuing {
                // Refit the complete recording (including paused segments) just
                // like a Photos batch. A longer prepend may use more of the lead-in.
                let clips = captureLedger.dropFirst(recordingSite.firstCapture).filter(\.insertion).map(\.clip)
                let base = materialized(snapshots[historyCursor - 1])
                next = TimelineEditing.inserting(clips, into: base, at: position, site: recordingSite.site)
                let ids = Set(clips.map(\.sourceID))
                for take in sources where ids.contains(take.id) { next.timeline.includeCaptureBookmarks(take) }
            } else {
                next = TimelineEditing.inserting([clip], into: edit, at: position, site: recordingSite?.site)
                next.timeline.includeCaptureBookmarks(source)
            }
            if continuing {
                next.retainCanvasReference(from: edit)
                snapshots[historyCursor] = EditSnapshot(next.normalizedTools(), cursor: captureLedger.count); updatedAt = Date()
            } else { commit(next); recordingInsertionStep = historyCursor }
            recordingInsertion = next.timeline.video.first { $0.content.sourceID == source.id }?.end.seconds ?? min(edit.duration, position + source.duration)
        } else { append(source) }
    }
    /// Return false when the footage was rescued into Originals but the original
    /// edit location can no longer be proven. Never resurrect intentional cuts.
    mutating func indexTake(_ source: SourceMedia, receipt: TakeReceipt?, uncertain: Bool) throws -> Bool {
        guard !sources.contains(where: { $0.id == source.id || $0.filename == source.filename }) else { return false }
        if source.audioOnly == true {
            schemaVersion = max(schemaVersion, 9)
            sources.append(source); updatedAt = Date(); return false
        }
        if uncertain || receipt?.indexed == true { sources.append(source); updatedAt = Date(); return false }
        if let receipt {
            guard receipt.projectID == id, receipt.segmentID == source.id else { throw RecoveryError.identity }
            if receipt.insertion == nil { append(source); return true }
            let revision = try RecoveryFile.hash(snapshots[historyCursor].data()) + ".json"
            guard recordingInsertion == receipt.insertion, recordingSite?.site == receipt.insertionSite,
                  revision == receipt.revision, captureLedger.count == receipt.captureCount else {
                sources.append(source); updatedAt = Date(); return false
            }
        }
        addRecording(source)
        return true
    }
    private mutating func includeRecording(_ source: SourceMedia) {
        let clip = TimelineClip(sourceID: source.id, start: 0, end: source.duration, videoEffects: source.videoEffects)
        captureLedger.append(CaptureLedgerEntry(clip: clip, insertion: false))
        updatedAt = Date()
    }
    mutating func undo() { if canUndo { historyCursor -= 1; updatedAt = Date() } }
    mutating func redo() { if canRedo { historyCursor += 1; updatedAt = Date() } }

    // Explicit recovery only. An unused source might have been deliberately
    // removed, so loading a document must never automatically add it back.
    mutating func restoreUnusedRecording(_ id: UUID) throws {
        protectRecordingHistory()
        guard let source = sources.first(where: { $0.id == id }), source.audioOnly != true,
              !history.contains(where: { $0.clips.contains(where: { $0.sourceID == id }) }) else { throw ProjectError.invalidDocument }
        includeRecording(source)
    }

    mutating func protectRecordingHistory() {
        guard recordingHistoryVersion == nil, !history.isEmpty, history.indices.contains(historyCursor) else { return }
        let previous = history
        var seen = Set(previous[0].clips.map(\.sourceID))
        var captureSteps = Set<Int>()
        for index in previous.indices.dropFirst() {
            let before = previous[index - 1], after = previous[index]
            defer { seen.formUnion(after.clips.map(\.sourceID)) }
            guard after.clips.count == before.clips.count + 1, let added = after.clips.last,
                  !seen.contains(added.sourceID), let source = sources.first(where: { $0.id == added.sourceID }),
                  added == TimelineClip(id: added.id, sourceID: source.id, start: 0, end: source.duration) else { continue }
            var expected = before; expected.clips.append(added)
            guard expected == after else { continue }
            captureSteps.insert(index)
            // Only an exact first full-source append qualifies. Later cuts,
            // deliberate deletions and reinsertions remain ordinary edits.
            for earlier in 0..<index { history[earlier].clips.append(added) }
        }
        var compacted: [EditState] = [], cursor = 0
        for (index, state) in history.enumerated() {
            if !captureSteps.contains(index) { compacted.append(state) }
            if index == historyCursor { cursor = compacted.count - 1 }
        }
        history = compacted; historyCursor = cursor; recordingHistoryVersion = 1
    }

    func validate() throws {
        guard snapshots.allSatisfy({ (0...captureLedger.count).contains($0.captureCursor) }),
              captureLedger.allSatisfy({ event in sources.contains { $0.id == event.clip.sourceID } }),
              (1...Self.latestReadableSchema).contains(schemaVersion), recordingHistoryVersion == nil || recordingHistoryVersion == 1,
              !history.isEmpty, history.indices.contains(historyCursor),
              Set(sources.map(\.id)).count == sources.count,
              Set(sources.map { $0.filename.lowercased() }).count == sources.count,
              sources.allSatisfy({ $0.duration.isFinite && $0.duration > 0 && $0.duration <= 604800 && ($0.originalName?.count ?? 0) <= 255 &&
                  $0.filename == URL(fileURLWithPath: $0.filename).lastPathComponent && !$0.filename.hasPrefix(".") && !$0.filename.contains("\\") &&
                  !["project.json", "integrity.json", "cache", "processing", "previews", "exports"].contains($0.filename.lowercased()) })
        else { throw ProjectError.invalidDocument }
        if let recordingInsertion { guard recordingInsertion.isFinite, recordingInsertion >= 0, recordingInsertion <= 604800 else { throw ProjectError.invalidDocument } }
        if let step = recordingInsertionStep { guard history.indices.contains(step) else { throw ProjectError.invalidDocument } }
        if let recordingSite {
            guard recordingInsertion != nil, (0...captureLedger.count).contains(recordingSite.firstCapture) else { throw ProjectError.invalidDocument }
        }
        guard Set(mediaFiles.map { $0.lowercased() }).count == mediaFiles.count else { throw ProjectError.invalidDocument }
        for filename in imageFiles {
            guard filename.hasPrefix("image-"), filename == URL(fileURLWithPath: filename).lastPathComponent,
                  !filename.contains("\\"), ["png", "jpg", "jpeg", "heic"].contains(URL(fileURLWithPath: filename).pathExtension.lowercased()) else { throw ProjectError.invalidDocument }
        }
        for filename in effectFiles {
            guard filename.hasPrefix("effect-"), filename == URL(fileURLWithPath: filename).lastPathComponent,
                  !filename.contains("\\"), ["json", "png", "jpg", "jpeg", "heic", "mov", "mp4", "bin", "cube"].contains(URL(fileURLWithPath: filename).pathExtension.lowercased()) else { throw ProjectError.invalidDocument }
        }
        for source in sources {
            guard (source.videoEffects ?? []).allSatisfy(\.valid),
                  Set((source.videoEffects ?? []).map(\.id)).count == (source.videoEffects ?? []).count else { throw ProjectError.invalidDocument }
            if let hash = source.sha256 { guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else { throw ProjectError.invalidDocument } }
            guard (source.events ?? []).allSatisfy({ $0.time.isFinite && $0.time >= 0 && $0.time <= source.duration + 1 }) else { throw ProjectError.invalidDocument }
        }
        for state in history {
            try state.timeline.validate(sources: sources)
            if let size = state.outputSize {
                guard size.width.isFinite, size.height.isFinite, (2...16384).contains(size.width), (2...16384).contains(size.height),
                      size.width.truncatingRemainder(dividingBy: 2) == 0, size.height.truncatingRemainder(dividingBy: 2) == 0 else { throw ProjectError.invalidDocument }
            }
            guard state.duration.isFinite, state.duration <= 604800 else { throw ProjectError.invalidDocument }
            guard Set(state.clips.map(\.id)).count == state.clips.count,
                  Set(state.effects.map(\.id)).count == state.effects.count else { throw ProjectError.invalidDocument }
            for clip in state.clips {
                guard let source = sources.first(where: { $0.id == clip.sourceID }),
                      clip.start.isFinite, clip.end.isFinite, clip.start >= 0,
                      clip.end > clip.start, clip.end <= source.duration + 0.001
                else { throw ProjectError.invalidDocument }
                guard clip.rate.isFinite, (0.125...6).contains(clip.rate), clip.duration > 0, (clip.speed.map { $0.rate.isFinite && (0.25...4).contains($0.rate) } ?? true) else { throw ProjectError.invalidDocument }
                if let frozen = clip.frozenFrame {
                    guard frozen.valid, frozen.sourceTime >= clip.start, frozen.sourceTime < clip.end,
                          clip.videoEffects?.contains(where: { $0.kind == .freezeFrame }) == true else { throw ProjectError.invalidDocument }
                }
                guard [clip.openingTransition, clip.transition].compactMap({ $0 }).allSatisfy(\.valid) else { throw ProjectError.invalidDocument }
                guard (clip.videoEffects ?? []).allSatisfy(\.valid),
                      Set((clip.videoEffects ?? []).map(\.id)).count == (clip.videoEffects ?? []).count else { throw ProjectError.invalidDocument }
                if let color = clip.color { guard color.valid, color.motion?.valid(for:color.pose, accepts:{ color.applying($0).valid }) ?? true else { throw ProjectError.invalidDocument } }
                if let crop = clip.crop { guard crop.motion?.valid(for:crop.pose,accepts:{ (0...1).contains($0["x"]) && (0...1).contains($0["y"]) && (1...8).contains($0["zoom"]) && (-180...180).contains($0["rotation"]) }) ?? true, crop.x.isFinite, crop.y.isFinite, crop.zoom.isFinite, crop.rotation.isFinite, (-180...180).contains(crop.rotation),
                    (0...1).contains(crop.x), (0...1).contains(crop.y), (1...8).contains(crop.zoom) else { throw ProjectError.invalidDocument } }
                if let pauses = clip.pauses {
                    guard pauses.thresholdDB.isFinite, (-80...0).contains(pauses.thresholdDB),
                          pauses.minimum.isFinite, (0.1...10).contains(pauses.minimum),
                          pauses.before.isFinite, (0...2).contains(pauses.before), pauses.after.isFinite, (0...2).contains(pauses.after),
                          pauses.cuts.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start && $0.end <= source.duration + 0.001 }) else { throw ProjectError.invalidDocument }
                    guard (pauses.candidates ?? []).allSatisfy({ $0.raw.start.isFinite && $0.raw.end.isFinite && $0.raw.start >= 0 && $0.raw.end > $0.raw.start && $0.raw.end <= source.duration + 0.001 }) else { throw ProjectError.invalidDocument }
                    if let analyzed = pauses.analyzed { guard analyzed.start.isFinite, analyzed.end.isFinite, analyzed.start >= 0, analyzed.end > analyzed.start, analyzed.end <= source.duration + 0.001 else { throw ProjectError.invalidDocument } }
                }
                guard Set((clip.texts ?? []).map(\.id)).count == (clip.texts ?? []).count else { throw ProjectError.invalidDocument }
                guard Set((clip.images ?? []).map(\.id)).count == (clip.images ?? []).count else { throw ProjectError.invalidDocument }
                for image in clip.images ?? [] {
                    guard image.start.isFinite, image.end.isFinite, image.start >= 0, image.end > image.start, image.end <= source.duration + 0.001,
                          image.x.isFinite, image.y.isFinite, (0...1).contains(image.x), (0...1).contains(image.y),
                          image.motion?.valid(for:image.pose,accepts:{ (0...1).contains($0["x"]) && (0...1).contains($0["y"]) && (0.03...3).contains($0["width"]) && (0...1).contains($0["opacity"]) }) ?? true, image.width.isFinite, (0.03...3).contains(image.width), image.opacity.isFinite, (0...1).contains(image.opacity) else { throw ProjectError.invalidDocument }
                }
                for text in clip.texts ?? [] {
                    guard text.start.isFinite, text.end.isFinite, text.start >= 0, text.end > text.start, text.end <= source.duration + 0.001,
                          text.appearance?.valid != false, text.motion?.valid != false, text.text.count <= 500, text.x.isFinite, text.y.isFinite, (0...1).contains(text.x), (0...1).contains(text.y),
                          text.size.isFinite, (0.02...0.3).contains(text.size) else { throw ProjectError.invalidDocument }
                }
                if let stabilization = clip.stabilization {
                    guard stabilization.version == 1 else { throw ProjectError.invalidDocument }
                    if let start = stabilization.referenceStart, let end = stabilization.referenceEnd {
                        guard start.isFinite, end.isFinite, start >= 0, end > start, end <= source.duration + 0.001 else { throw ProjectError.invalidDocument }
                    } else if stabilization.referenceStart != nil || stabilization.referenceEnd != nil { throw ProjectError.invalidDocument }
                }
            }
            guard state.effects.allSatisfy({ $0.implementationVersion > 0 && $0.amount.isFinite &&
                (!$0.supported || ($0.kind.isNeural ? (0...1) : (-24...24)).contains($0.amount)) &&
                $0.frequency.isFinite && (20...20000).contains($0.frequency) })
            else { throw ProjectError.invalidDocument }
        }
    }
}

extension Project {
    fileprivate static let readerKey = CodingUserInfoKey(rawValue: "YouRec.historyReader")!
    fileprivate struct HistoryReader {
        let summaryFile: URL?
        let load: (String) throws -> Data
    }
    static func isSnapshotName(_ name: String) -> Bool {
        name.utf8.count == 69 && name.hasSuffix(".json") && name.prefix(64).allSatisfy { "0123456789abcdef".contains($0) }
    }
    static func readManifest(_ data: Data, summaryFile: URL? = nil, load: @escaping (String) throws -> Data) throws -> Project {
        let decoder = JSONDecoder()
        decoder.userInfo[readerKey] = HistoryReader(summaryFile: summaryFile, load: load)
        return try decoder.decode(Project.self, from: data)
    }
    func manifest(writing write: (String, Data) throws -> Void) throws -> Data {
        guard deferredHistory == nil else { throw ProjectError.invalidDocument }
        var names: [String] = []
        for snapshot in snapshots {
            let data = try snapshot.data()
            let name = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() + ".json"
            try write(name, data)
            names.append(name)
        }
        var metadata = self
        metadata.snapshots = []
        let encoder = JSONEncoder()
        guard var header = try JSONSerialization.jsonObject(with: encoder.encode(metadata)) as? [String: Any] else { throw ProjectError.invalidDocument }
        header.removeValue(forKey: "snapshots")
        header["snapshotFiles"] = names
        return try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(exportSettings, forKey: .exportSettings)
        try values.encode(schemaVersion, forKey: .schemaVersion); try values.encode(id, forKey: .id)
        try values.encode(title, forKey: .title); try values.encode(createdAt, forKey: .createdAt); try values.encode(updatedAt, forKey: .updatedAt)
        try values.encode(sources, forKey: .sources); try values.encode(historyCursor, forKey: .historyCursor)
        try values.encode(snapshots, forKey: .snapshots); try values.encode(captureLedger, forKey: .captureLedger)
        try values.encode(1, forKey: .automaticCanvasVersion)
        try values.encodeIfPresent(recordingInsertionStep, forKey: .recordingInsertionStep)
        try values.encodeIfPresent(recordingInsertion, forKey: .recordingInsertion)
        try values.encodeIfPresent(recordingSite, forKey: .recordingSite)
        try values.encodeIfPresent(recordingHistoryVersion, forKey: .recordingHistoryVersion)
    }
    /// Old versions wrote a fixed size during timeline edits as well as Crop.
    /// Only a change of picture sources proves that the size came from a timeline
    /// edit. Preserve unattested formats and later Crop decisions, including Redo.
    private mutating func repairImplicitCanvasSizes() {
        var inheritedSize: CGSize?
        for index in snapshots.indices.dropFirst() {
            let entry = snapshots[index]
            var state = entry.state
            guard let size = state.outputSize, state.timeline.video.allSatisfy({ $0.content.crop == nil }) else {
                inheritedSize = nil
                continue
            }
            let before = materialized(snapshots[index - 1], through: entry.captureCursor)
            let previousSources = Set(before.timeline.video.map { $0.content.sourceID })
            let addedVideo = state.timeline.video.contains { !previousSources.contains($0.content.sourceID) }
            let startsImplicitSize = before.outputSize == nil && !previousSources.isEmpty
                && before.timeline.video.allSatisfy { $0.content.crop == nil }
                && (before.firstVideoSourceID != state.firstVideoSourceID || addedVideo)
            guard size == inheritedSize || (inheritedSize == nil && startsImplicitSize) else {
                inheritedSize = nil
                continue
            }
            inheritedSize = size
            state.outputSize = nil
            state.retainCanvasReference(from: before)
            if state.canvasReference != nil { schemaVersion = max(schemaVersion, 10) }
            snapshots[index] = EditSnapshot(state, cursor: entry.captureCursor)
        }
    }

    // Normalize before a caller can read edit and build its next operation.
    // Migrating inside commit would be too late: that operation could have
    // captured a legacy state which was still missing an undone recording.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        exportSettings = try values.decodeIfPresent(ExportSettings.self, forKey: .exportSettings) ?? ExportSettings()
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        sources = try values.decode([SourceMedia].self, forKey: .sources)
        historyCursor = try values.decode(Int.self, forKey: .historyCursor)
        captureLedger = try values.decodeIfPresent([CaptureLedgerEntry].self, forKey: .captureLedger) ?? []
        if let names = try values.decodeIfPresent([String].self, forKey: .snapshotFiles) {
            guard let reader = decoder.userInfo[Self.readerKey] as? HistoryReader,
                  names.indices.contains(historyCursor), names.allSatisfy(Self.isSnapshotName) else { throw ProjectError.invalidDocument }
            let requested: ArraySlice<String>
            if let file = reader.summaryFile {
                deferredHistory = DeferredProjectHistory(manifest: file, count: names.count, cursor: historyCursor)
                requested = names[historyCursor...historyCursor]
                historyCursor = 0
            } else { requested = names[...] }
            snapshots = try requested.map { name in
                let payload = try reader.load(name)
                let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
                guard hash + ".json" == name else { throw ProjectError.invalidDocument }
                return try EditSnapshot.decode(payload)
            }
        } else if let records = try values.decodeIfPresent([EditSnapshot].self, forKey: .snapshots) {
            snapshots = records
        } else { history = try values.decode([EditState].self, forKey: .history) }
        recordingInsertionStep = deferredHistory == nil ? try values.decodeIfPresent(Int.self, forKey: .recordingInsertionStep) : nil
        recordingInsertion = try values.decodeIfPresent(Double.self, forKey: .recordingInsertion)
        recordingSite = try values.decodeIfPresent(RecordingInsertionSite.self, forKey: .recordingSite)
        recordingHistoryVersion = try values.decodeIfPresent(Int.self, forKey: .recordingHistoryVersion)
        try validate()
        protectRecordingHistory()
        if deferredHistory == nil, !values.contains(.automaticCanvasVersion) { repairImplicitCanvasSizes() }
        try validate()
    }
}

struct ExportSettings: Codable, Equatable, Sendable {
    enum Codec: String, CaseIterable, Codable { case h264 = "H.264", hevc = "H.265" }
    enum Resolution: String, CaseIterable, Codable {
        case project = "Project size", hd = "720p", fullHD = "1080p", ultraHD = "4K"

        func size(for canvas: CGSize) -> CGSize {
            let limit: (CGFloat, CGFloat)
            switch self {
            case .project: return canvas
            case .hd: limit = (1280, 720)
            case .fullHD: limit = (1920, 1080)
            case .ultraHD: limit = (3840, 2160)
            }
            let scale = min(limit.0 / max(canvas.width, canvas.height), limit.1 / min(canvas.width, canvas.height))
            func even(_ dimension: CGFloat) -> CGFloat { max(2, (dimension * scale / 2).rounded() * 2) }
            return CGSize(width: even(canvas.width), height: even(canvas.height))
        }
    }
    enum FrameRate: Int, CaseIterable, Codable { case film = 24, pal = 25, standard = 30, palHigh = 50, high = 60 }

    var codec: Codec = .h264
    var resolution: Resolution = .project
    var frameRate: FrameRate = .standard

    func outputCodec(hdr: Bool) -> Codec { hdr ? .hevc : codec }
}

struct ExportReceipt: Codable, Identifiable {
    var schemaVersion = 1
    var id = UUID()
    var createdAt = Date()
    let filename: String
    let projectID: UUID
    let projectTitle: String
    let historyRevision: Int
    let edit: EditState
    let sources: [SourceMedia]
    let sourceChecksums: [String: String]
    let width: Int
    let height: Int
    var framesPerSecond = 30
    var settings: ExportSettings?
    var codec: ExportSettings.Codec?
    // Measured from this export's final mix, not whole cached source recordings.
    // Older exports without a measurement make no claim about audio headroom.
    var audioPeak: Float?
    var audioWarning: String? {
        guard let peak = audioPeak, peak.isFinite, peak > 1.0001 else { return nil }
        let excess = max(0.1, ceil(20 * log10(Double(peak)) * 10) / 10)
        return String(format: "Peaks are %.1f dB above full scale. Lower Volume in the editor and export again.", excess)
    }
}

enum ProjectError: LocalizedError {
    case invalidDocument, missingMedia, missingImage, emptyTimeline, invalidMedia
    var errorDescription: String? {
        switch self {
        case .invalidDocument: return "This project has unsupported or invalid editing data. Its files have been preserved."
        case .missingImage: return "An overlay image is missing. Open Tools and select its Image entry to replace or remove it. Your recordings and editing history are preserved."
        case .missingMedia: return "A source file is missing. The project has been preserved."
        case .emptyTimeline: return "Add a recording before previewing or exporting."
        case .invalidMedia: return "The recording could not be opened as a valid video. Its file has been preserved."
        }
    }
}

struct ProjectDeletion: Codable, Equatable, Identifiable {
    let id: UUID
    let token: UUID
    let date: Date
    let dateIsKnown: Bool
    func isOlderThan30Days(at now: Date, calendar: Calendar = .current) -> Bool {
        guard date.timeIntervalSinceReferenceDate.isFinite,
              let cutoff = calendar.date(byAdding: .day, value: -30, to: now) else { return false }
        return date < cutoff
    }
}

struct ProjectDisk {
    let root: URL
    func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func recoveryFiles(in project: Project) -> [URL] {
        let directory = folder(project.id).appendingPathComponent("Recovery", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return entries.flatMap { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
            .filter { ["mov", "mp4"].contains($0.pathExtension.lowercased()) }.sorted { $0.path < $1.path }
    }
    func quarantineRecording(_ requested: URL, in project: Project) throws {
        // Enumeration resolves /var to /private/var on Apple platforms. Compare
        // canonical paths, then move only the verified, non-symlink orphan from
        // our enumeration, never an arbitrary caller-supplied alias.
        guard let file = try unindexedRecordings(in: project).first(where: {
            $0.resolvingSymlinksInPath() == requested.resolvingSymlinksInPath()
        }) else { return }
        let destination = folder(project.id).appendingPathComponent("Recovery", isDirectory: true)
            .appendingPathComponent(RecoveryFile.hash(Data(file.lastPathComponent.utf8)), isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let stem = file.deletingPathExtension().lastPathComponent + "."
        let companions = try FileManager.default.contentsOfDirectory(at: folder(project.id), includingPropertiesForKeys: nil)
        let sidecars = companions.filter { $0 != file && $0.lastPathComponent != file.lastPathComponent &&
            $0.lastPathComponent.hasPrefix(stem) && !project.mediaFiles.contains($0.lastPathComponent) }
        for companion in sidecars {
            let target = destination.appendingPathComponent(companion.lastPathComponent)
            if !FileManager.default.fileExists(atPath: target.path) { try FileManager.default.copyItem(at: companion, to: target) }
        }
        try FileManager.default.moveItem(at: file, to: destination.appendingPathComponent(file.lastPathComponent))
        for companion in sidecars { try? FileManager.default.removeItem(at: companion) }
    }
    func unindexedRecordings(in project: Project) throws -> [URL] {
        let known = Set(project.mediaFiles.map { $0.lowercased() })
        let files = try FileManager.default.contentsOfDirectory(at: folder(project.id), includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return files.filter { file in
            let name = file.lastPathComponent.lowercased()
            // Effect assets share the project directory with captures. Also
            // exclude unused/undone assets: a library summary omits older edits.
            guard ["mov", "mp4"].contains(file.pathExtension.lowercased()), !name.hasPrefix("recovered-"),
                  !name.hasPrefix("."), !name.hasPrefix("effect-"), !VideoBatchImport.ownsFilename(name), !known.contains(name),
                  let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
            return values.isRegularFile == true && values.isSymbolicLink != true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    // Fixture stores must never share the user's Recently Deleted directory.
    var deletedRoot: URL {
        root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent == "Projects" ? "RecentlyDeleted" : root.lastPathComponent + "-RecentlyDeleted", isDirectory: true)
    }
    private func deletionFile(in directory: URL) -> URL { directory.appendingPathComponent(".yourec-deletion.json") }
    func moveToDeleted(_ project: Project, now: Date = Date()) throws {
        try FileManager.default.createDirectory(at: deletedRoot, withIntermediateDirectories: true)
        let receipt = ProjectDeletion(id: project.id, token: UUID(), date: now, dateIsKnown: true)
        // A failed receipt write leaves the active project in place. The manifest,
        // originals and immutable edit history are not rewritten for deletion.
        try JSONEncoder().encode(receipt).write(to: deletionFile(in: folder(project.id)), options: .atomic)
        try FileManager.default.moveItem(at: folder(project.id), to: deletedRoot.appendingPathComponent(project.id.uuidString, isDirectory: true))
    }
    func restoreDeleted(_ project: Project) throws {
        try FileManager.default.moveItem(at: deletedRoot.appendingPathComponent(project.id.uuidString, isDirectory: true), to: folder(project.id))
        try? FileManager.default.removeItem(at: deletionFile(in: folder(project.id)))
    }
    func deletionRecord(for id: UUID, firstSeenAt now: Date = Date()) throws -> ProjectDeletion {
        let directory = deletedRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("project.json").path) else { throw ProjectError.invalidDocument }
        let url = deletionFile(in: directory)
        if FileManager.default.fileExists(atPath: url.path) {
            let record = try JSONDecoder().decode(ProjectDeletion.self, from: Data(contentsOf: url))
            guard record.id == id, record.date.timeIntervalSinceReferenceDate.isFinite else { throw ProjectError.invalidDocument }
            return record
        }
        // Previous builds did not record deletion time. Start a conservative
        // 30-day clock now; never substitute last edit or original creation time.
        let record = ProjectDeletion(id: id, token: UUID(), date: now, dateIsKnown: false)
        try JSONEncoder().encode(record).write(to: url, options: .atomic)
        return record
    }
    @discardableResult func eraseExpiredDeletion(_ confirmed: ProjectDeletion, now: Date = Date()) throws -> Bool {
        let directory = deletedRoot.appendingPathComponent(confirmed.id.uuidString, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return false }
        let current = try deletionRecord(for: confirmed.id, firstSeenAt: now)
        // Revalidate the exact deletion event: restoring and deleting the same
        // project again invalidates an already-visible confirmation.
        guard current == confirmed, current.isOlderThan30Days(at: now) else { return false }
        try eraseDeleted(confirmed.id)
        return true
    }
    func eraseDeleted(_ id: UUID) throws {
        let original = deletedRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        let pending = deletedRoot.appendingPathComponent(".purging-" + UUID().uuidString, isDirectory: true)
        // This rename is the permanent-deletion commit. Only confirmed removals
        // enter this queue; a crash after any child unlink can safely resume.
        try FileManager.default.moveItem(at: original, to: pending)
        try? FileManager.default.removeItem(at: pending)
    }
    func finishPendingDeletions() {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        for folder in (try? FileManager.default.contentsOfDirectory(at: deletedRoot, includingPropertiesForKeys: Array(keys))) ?? [] {
            let name = folder.lastPathComponent
            guard name.hasPrefix(".purging-"), UUID(uuidString: String(name.dropFirst(".purging-".count))) != nil,
                  let values = try? folder.resourceValues(forKeys: keys), values.isDirectory == true, values.isSymbolicLink != true else { continue }
            try? FileManager.default.removeItem(at: folder)
        }
    }
    private static let writeLock = NSLock()
    func save(_ project: Project) throws {
        guard project.deferredHistory == nil else { throw ProjectError.invalidDocument }
        try project.validate()
        Self.writeLock.lock(); defer { Self.writeLock.unlock() }
        let directory = folder(project.id), history = directory.appendingPathComponent("History", isDirectory: true)
        #if DEBUG
        if root.lastPathComponent == "EditorUITestProjects", CommandLine.arguments.contains("--recovery-save-fault") {
            let marker = directory.appendingPathComponent(".test-fail-next-save")
            if FileManager.default.fileExists(atPath: marker.path) {
                try FileManager.default.removeItem(at: marker); throw CocoaError(.fileWriteOutOfSpace)
            }
        }
        #endif
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        try ImportedFonts.shared.preserve(project.edit.importedFontFiles, in: directory)
        let head = directory.appendingPathComponent("project.json")
        let previous = try RecoveryFile.readIfPresent(head)
        if let previous, let damaged = project.recoveryOrigin, RecoveryFile.hash(previous) == damaged {
            let preserved = directory.appendingPathComponent(".revisions/damaged-head-" + damaged + ".json")
            if !FileManager.default.fileExists(atPath: preserved.path) { try RecoveryFile.write(previous, to: preserved) }
        }
        if let previous { try keepManifest(previous, in: directory, nextSchema: project.schemaVersion) }
        let data = try project.manifest { name, data in
            let file = history.appendingPathComponent(name)
            try RecoveryFile.ensureSnapshot(data, at: file)
        }
        if data != previous { try RecoveryFile.write(data, to: head) }
        // Secondary copy. A failure here cannot revoke the successful primary commit.
        try? keepManifest(data, in: directory, nextSchema: project.schemaVersion)
        clearMatchingDraft(data, in: directory)
    }
    func read(_ file: URL, summary: Bool = false) throws -> Project {
        let data = try Data(contentsOf: file)
        let history = file.deletingLastPathComponent().appendingPathComponent("History", isDirectory: true)
        return try Project.readManifest(data, summaryFile: summary ? file : nil) { name in
            try Data(contentsOf: history.appendingPathComponent(name))
        }
    }

}


/// Expensive media jobs can report thousands of blocks per second. Keep UI
/// updates bounded while always delivering the start and completion values.
final class MediaProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var lastTime = -Double.infinity
    private var lastValue = -1.0
    private let callback: @Sendable (Double) -> Void
    init(_ callback: @escaping @Sendable (Double) -> Void) { self.callback = callback }
    func report(_ value: Double) {
        let bounded = min(1, max(0, value)), now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let publish = bounded != lastValue && (now - lastTime >= 0.1 || bounded == 0 || bounded == 1)
        if publish { lastTime = now; lastValue = bounded }
        lock.unlock()
        if publish { callback(bounded) }
    }
}
