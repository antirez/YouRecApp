import AVFoundation
import Photos
import AudioToolbox
import SwiftUI

struct SourceThumbnail {
    let time: Double
    let image: UIImage
}

@MainActor
final class EditorController: ObservableObject {
    let player = AVPlayer()
    // Inspector-only bounds. The main editor leaves these nil.
    var previewRange:ClosedRange<Double>? {didSet {boundPreview(player.currentItem)}}
    private var playbackRange:ClosedRange<Double> {
        let lower=min(duration,max(0,previewRange?.lowerBound ?? 0))
        return lower...max(lower,min(duration,previewRange?.upperBound ?? duration))
    }
    private func boundPreview(_ item:AVPlayerItem?) {
        item?.reversePlaybackEndTime=previewRange.map {CMTime(seconds:$0.lowerBound,preferredTimescale:60000)} ?? .invalid
        item?.forwardPlaybackEndTime=previewRange.map {CMTime(seconds:$0.upperBound,preferredTimescale:60000)} ?? .invalid
    }
    @Published var gainRevision = UUID()
    @Published var headroom: AudioHeadroom?
    private(set) var headroomSelection = TimelineSelection()
    @Published var headroomMessage = "Checking headroom…"
    private var baseGainMix: AVAudioMix?
    func auditionGain(_ db: Double?, selection: TimelineSelection) {
        if !AudioGainMix.audition(db, selection: selection, on: player.currentItem), db != nil { error = "The volume preview could not be updated." }
    }
    func measureHeadroom(selection: TimelineSelection, timeline: TrackTimeline) async {
        headroomSelection = selection
        headroom = nil; headroomMessage = "Checking headroom…"
        guard !selection.audio.isEmpty, loadedEdit?.timeline == timeline, let item = player.currentItem, let mix = baseGainMix,
              let range = timeline.interval(for: selection)?.seconds else { return }
        let asset = item.asset
        let job = Task.detached(priority: .userInitiated) { try await AudioHeadroom.analyze(asset: asset, mix: mix, selection: selection, range: range) }
        do {
            let result = try await withTaskCancellationHandler(operation: { try await job.value }, onCancel: { job.cancel() })
            try Task.checkCancellation(); guard player.currentItem === item else { return }
            headroom = result; headroomMessage = result.samples == 0 ? "Selection is silent or muted" : ""
        } catch { if !Task.isCancelled { headroomMessage = "Headroom unavailable" } }
    }
    @Published var waveforms: [UUID: SourceWaveform] = [:]
    @Published var processedWaveforms: [String: SourceWaveform] = [:]
    @Published var waveformRegions: [String: URL] = [:]
    @Published var thumbnails: [UUID: [SourceThumbnail]] = [:]
    @Published private(set) var navigation = TimelineNavigation()
    @Published var playhead: Double = 0
    @Published var playbackSpeed = 1.0
    @Published var playing = false {didSet {if !playing {installPreparedEffects()}}}
    @Published var loading = false {didSet {if !loading {installPreparedEffects()}}}
    @Published var loadingLabel = "Preparing preview"
    @Published var nightProgress=0.0
    @Published var preparingNightFix=false
    @Published var refiningEffects=false
    @Published var accurateEffectsReady=false
    @Published var effectRefinementError:String?
    @Published private(set) var exportHDR = false
    private(set) var exportUsesAutoBackground = false
    @Published private(set) var exportProgress = ExportProgress(.opening)
    @Published var canvas: CGSize?
    @Published var videoProgress: Double?
    @Published private(set) var exportPaused = false
    @Published private(set) var exportPauseReason: String?
    @Published private(set) var savedExportSeconds = 0.0
    private var exportCheckpoint: ExportCheckpoint?
    private var renderID: UUID?
    private var pendingExportSound: URL?
    @Published var rendering = false
    @Published var progress: Double = 0
    @Published var error: String?
    @Published var exportURL: URL?
    @Published private var photoSavesInFlight: Set<URL> = []
    private static var photoImportFiles = Set<URL>()
    @Published private var savedPhotoExports: Set<URL> = []
    var savingToPhotos: Bool { exportURL.map { photoSavesInFlight.contains($0) } ?? false }
    var savedToPhotos: Bool { exportURL.map { savedPhotoExports.contains($0) } ?? false }
    var hasPhotoSaveInFlight: Bool { !photoSavesInFlight.isEmpty }
    @Published var exports: [ExportReceipt] = []
    @Published var processedPreview = false
    @Published var previewStale = false
    @Published var notice: String?
    @Published var auditioning = false
    @Published var auditionPreparing = false {didSet {if !auditionPreparing {installPreparedEffects()}}}
    @Published var canUseProcessed = false
    @Published var matchListeningLevels = UserDefaults.standard.object(forKey: "matchListeningLevels") as? Bool ?? true {
        didSet { UserDefaults.standard.set(matchListeningLevels, forKey: "matchListeningLevels"); applyListeningGain() }
    }
    private(set) var enhancementComparisonGains: (original: Float, processed: Float) = (1, 1)
    private var listeningGains: (original: Float, processed: Float) = (1, 1)
    private func applyListeningGain() { player.volume = matchListeningLevels && canUseProcessed ? (processedPreview ? listeningGains.processed : listeningGains.original) : 1 }
    var scrubbing = false
    private var observer: Any?
    private var playbackFailure: NSObjectProtocol?
    private var job: Task<Void, Never>?
    private var effectJob:Task<Void,Never>?
    @Published private(set) var applicationPass = 0
    @Published private(set) var applicationPaused = false
    private(set) var application: EffectApplicationReceipt?
    private var preparingMedia: Task<PreparedTimeline, Error>?
    var canUndoApplication: Bool {
        application?.latestEdit == true && (application?.tool != VideoTool.stabilize.rawValue || preparingStabilization)
    }
    private var preparingStabilization = false
    var stabilizationStatus: String? {
        guard preparingStabilization else { return nil }
        if applicationPaused { return "Stabilization paused" }
        if effectRefinementError != nil { return "Couldn’t finish stabilization" }
        if let value = videoProgress { return "\(loadingLabel) · \(Int(value * 100))%" }
        return loadingLabel
    }
    /// Invalidate synchronously, even when Undo returns to the item already in
    /// the player. In that case a rendering-state comparison alone misses the
    /// separate analysis task and can later reinstall its obsolete result.
    func cancelObsoleteEffectWork() {
        guard application != nil || preparingMedia != nil || refiningEffects || preparedEffects != nil || effectRefinementError != nil else { return }
        generation = UUID()
        preparingMedia?.cancel(); preparingMedia = nil
        effectJob?.cancel(); effectJob = nil; preparedEffects = nil
        refiningEffects = false; accurateEffectsReady = false; preparingNightFix = false; effectRefinementError = nil
        application = nil; applicationPaused = false; preparingStabilization = false; endApplicationTime()
        loadedEdit = nil; loading = false; videoProgress = nil
    }
    private var applicationTime: UIBackgroundTaskIdentifier = .invalid
    private var crossedBackground = false

    private func endApplicationTime() {
        if applicationTime != .invalid { UIApplication.shared.endBackgroundTask(applicationTime); applicationTime = .invalid }
    }
    private func startApplication(_ receipt: EffectApplicationReceipt?) {
        endApplicationTime()
        application = receipt; applicationPaused = false; crossedBackground = false
        guard receipt != nil else { return }
        applicationTime = UIApplication.shared.beginBackgroundTask(withName: "Apply editor effects") { [weak self] in
            MainActor.assumeIsolated { self?.suspendApplication() }
        }
    }
    private func finishApplication(in folder: URL) {
        application?.finish(in: folder); application = nil; endApplicationTime()
    }
    func applicationDidEnterBackground() {
        guard let application else { return }
        crossedBackground = true
        // Audio processing and CPU motion estimation may finish during iOS's
        // finite grace period. Missing Metal work resumes in the foreground.
        if applicationTime == .invalid || refiningEffects || application.tool == VideoTool.videoEffects.rawValue { suspendApplication() }
    }
    private func suspendApplication() {
        endApplicationTime()
        guard application != nil, !applicationPaused else { return }
        generation = UUID(); preparingMedia?.cancel(); preparingMedia = nil; effectJob?.cancel(); preparedEffects = nil
        refiningEffects = false; accurateEffectsReady = false; preparingNightFix = false
        loadedEdit = nil; loading = false; applicationPaused = true; applicationPass += 1
    }
    func resumeApplication() {
        guard applicationPaused, UIApplication.shared.applicationState == .active else { return }
        applicationPaused = false; applicationPass += 1
    }
    private func interruptedApplication() -> Bool {
        guard application != nil, crossedBackground || UIApplication.shared.applicationState != .active else { return false }
        suspendApplication()
        // Some readers report the interruption only after the foreground transition.
        resumeApplication()
        return true
    }
    private struct VideoTrackSignature:Equatable {let id:CMPersistentTrackID;let range:CMTimeRange}
    private var preparedEffects:(token:UUID,composition:AVMutableVideoComposition,tracks:[VideoTrackSignature])?
    private var generation = UUID()
    private var playbackRevision = UUID()
    private var latestProject: Project?
    @Published private(set) var processingPreview = false {didSet {if !processingPreview {installPreparedEffects()}}}
    private var loadedEdit: EditState?
    private var loadedClips: [TimelineClip]?
    private var loadedOutputSize: CGSize?
    private var loadedEffects: [AudioEffect]?
    private var processedEffects: [AudioEffect]?
    private var duration = 0.0
    private var auditionEnd: Double?
    private var listenReturn: Double?
    private var playbackEnded: NSObjectProtocol?
    private var auditionItem: AVPlayerItem?
    private var mainPlaybackItem: AVPlayerItem?
    private var originalItem: AVPlayerItem?
    func coverItem(for edit: EditState) -> AVPlayerItem? {
        loadedEdit == edit && !loading ? originalItem : nil
    }
    private var processedItem: AVPlayerItem?
    private var auditionJob: Task<Void, Never>?
    private var auditionToken = UUID()
    private var auditionRange: ClosedRange<Double>?
    private var seekInFlight = false
    private var resumeAfterSeek = false
    private let awakeReason = "editor-" + UUID().uuidString
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var pendingSeek: (CMTime, Bool)?
    private var itemStatus: NSKeyValueObservation?
    private var auditionReturn = 0.0
    private var cacheLease: SourceCacheLease?
    private var auditionLease: SourceCacheLease?
    private var completedThumbnails = Set<UUID>()

    init() {
        playbackFailure = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                guard let self, let item = note.object as? AVPlayerItem, item === self.player.currentItem else { return }
                self.pause()
                self.error = "The video preview could not be displayed. " + ((note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription ?? "Please reopen the project.")
            }
        }
        playbackEnded = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                guard let self, let item = note.object as? AVPlayerItem, item === self.player.currentItem else { return }
                self.pause(); self.restoreAudition()
            }
        }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                let advancing = self.player.rate != 0
                let wantsPlayback = advancing || self.resumeAfterSeek
                if self.playing != wantsPlayback { self.playing = wantsPlayback }
                if !self.scrubbing && !self.seekInFlight && self.pendingSeek == nil && advancing && time.seconds.isFinite { let mapped = self.auditionRange.map { time.seconds >= $0.lowerBound ? time.seconds + $0.upperBound - $0.lowerBound : time.seconds } ?? time.seconds
                    self.playhead = min(self.playbackRange.upperBound, max(self.playbackRange.lowerBound,mapped)) }
                if advancing, !self.seekInFlight, let end = self.auditionEnd, time.seconds >= end { self.pause(); self.auditionEnd = nil; self.restoreAudition() }
            }
        }
    }
    deinit { if let observer { player.removeTimeObserver(observer) }; if let playbackFailure { NotificationCenter.default.removeObserver(playbackFailure) }; if let playbackEnded { NotificationCenter.default.removeObserver(playbackEnded) }; job?.cancel(); auditionJob?.cancel();effectJob?.cancel() }
    func stop() {
        preparingMedia?.cancel(); preparingMedia = nil
        endApplicationTime(); application = nil; applicationPaused = false; preparingStabilization = false
        latestProject = nil
        effectJob?.cancel();preparedEffects=nil;refiningEffects=false;accurateEffectsReady=false
        generation = UUID(); playbackRevision = UUID(); loading = false
        restoreAudition(); pause(); install(nil); job?.cancel(); loadedClips = nil; loadedEdit = nil
        originalItem = nil; processedItem = nil; cacheLease = nil; auditionLease = nil
    }
    func pause() {
        if player.rate != 0, !seekInFlight, pendingSeek == nil, !scrubbing, !auditioning, listenReturn == nil {
            let time = player.currentTime().seconds
            if time.isFinite { playhead = min(playbackRange.upperBound, max(playbackRange.lowerBound, time)) }
        }
        resumeAfterSeek = false
        player.pause(); playing = false
        installPreparedEffects()
    }
    var applyingEffectsLabel: String {
        let title = application?.tool == VideoTool.videoEffects.rawValue ? application?.title : nil
        return "Applying " + (title ?? (preparingNightFix ? "Night fix" : "video effects")) +
            (nightProgress > 0 ? " · \(Int(min(1, nightProgress) * 100))%" : "")
    }

    func retryEffects(_ project: Project, folder: URL) {
        if EffectApplicationReceipt.pending(for: project, in: folder) != nil {
            loadedEdit = nil; applicationPass += 1
        } else { refineEffects(project, folder: folder) }
    }
    func refineEffects(_ project:Project,folder:URL) {
        effectJob?.cancel();preparedEffects=nil;refiningEffects=true;accurateEffectsReady=false;effectRefinementError=nil
        let token=generation;nightProgress=0
        preparingNightFix = project.edit.clips.contains { $0.offlineVideoEffects.contains(where: \.needsNightFixFusion) }
        effectJob=Task(priority:.utility) {
            let reason="night-fix-editor-"+UUID().uuidString
            if preparingNightFix {RecordingAppDelegate.keepAwake(reason,active:true)}
            defer {RecordingAppDelegate.keepAwake(reason,active:false)}
            do {
                let media=try await VideoEffectPreparation.refine {
                    try await MediaRenderer.timeline(project:project,folder:folder,videoProgress:{value in Task {@MainActor in if self.generation==token {self.nightProgress=value}}},includeBackgroundAudio:false,effectPreparation:.refinedPreview)
                }
                try Task.checkCancellation();guard generation==token else {return}
                preparedEffects=(token,media.videoComposition,media.composition.tracks(withMediaType:.video).map {VideoTrackSignature(id:$0.trackID,range:$0.timeRange)})
                finishApplication(in: folder)
                refiningEffects=false;accurateEffectsReady=true;installPreparedEffects()
            } catch is CancellationError {} catch {
                guard generation==token else {return}
                if interruptedApplication() { return }; endApplicationTime()
                NSLog("YouRec effect application failed: %@",String(describing:error))
                refiningEffects=false;effectRefinementError=error.localizedDescription
            }
        }
    }
    private func installPreparedEffects() {
        guard !playing,!loading,!scrubbing,!auditioning,!auditionPreparing,listenReturn==nil,!processingPreview,!resumeAfterSeek,!seekInFlight,pendingSeek==nil,
              player.timeControlStatus == .paused,let prepared=preparedEffects,prepared.token==generation else {return}
        // Replace only the video instructions. Original/Processed audio, its
        // cache leases, listening gain and the playback position stay attached
        // to their existing player items.
        let items=[originalItem,processedItem].compactMap {$0}
        guard !items.isEmpty else {return}
        guard items.allSatisfy({item in
            guard let asset=item.asset as? AVComposition else {return false}
            return asset.tracks(withMediaType:.video).map {VideoTrackSignature(id:$0.trackID,range:$0.timeRange)}==prepared.tracks
        }) else {
            preparedEffects=nil;accurateEffectsReady=false;effectRefinementError="The timeline changed while applying effects. Please retry."
            return
        }
        preparedEffects=nil;accurateEffectsReady=false
        for item in items {item.videoComposition=prepared.composition}
        queueSeek(playhead,exact:true)
    }
    func setPlaybackSpeed(_ value: Double) {
        guard [1.0, 1.5, 2, 2.5, 3].contains(value) else { return }
        playbackSpeed = value
        if playing { playAtSelectedSpeed() }
    }
    private func playAtSelectedSpeed() { player.playImmediately(atRate: Float(auditioning || listenReturn != nil ? 1 : playbackSpeed)); playing = true }
    private func install(_ item: AVPlayerItem?, main: Bool = true) {
        AudioGainMix.audition(nil, selection: TimelineSelection(), on: player.currentItem)
        AudioGainMix.audition(nil, selection: TimelineSelection(), on: item)
        if main { mainPlaybackItem = item }; baseGainMix = AudioGainMix.sourceMix(of: item); headroom = nil; headroomMessage = "Checking headroom…"; gainRevision = UUID()
        itemStatus = nil; pendingSeek = nil; seekInFlight = false; resumeAfterSeek = false
        item?.audioTimePitchAlgorithm = .spectral
        boundPreview(item)
        player.replaceCurrentItem(with: item)
        applyListeningGain()
        itemStatus = item?.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.player.currentItem === item else { return }
                if item.status == .readyToPlay { self.performSeek() }
                else if item.status == .failed { self.pause(); self.error = item.error?.localizedDescription ?? "This video cannot be played." }
            }
        }
    }
    func seek(_ time: Double) {
        let resume = !scrubbing && (playing || player.rate > 0 || resumeAfterSeek)
        restoreAudition()
        if resume { resumeAfterSeek = true }
        playhead = min(playbackRange.upperBound, max(playbackRange.lowerBound, time))
        queueSeek(playhead, exact: !scrubbing)
    }
    /// Inspectors keep their still feedback until the queued exact seek finishes.
    func seekAndWait(_ time: Double) async -> Bool {
        seek(time)
        let item = player.currentItem
        for _ in 0..<300 {
            guard !Task.isCancelled, player.currentItem === item, item?.status != .failed else { return false }
            if item?.status == .readyToPlay && pendingSeek == nil && !seekInFlight { return true }
            try? await Task.sleep(for: .milliseconds(16))
        }
        return false
    }
    /// The model changes before its replacement player item is ready. Clamp
    /// against the new edit's duration, otherwise Undo of a deletion truncates
    /// a restored position to the shorter, still-loaded movie's endpoint.
    func seekAfterEdit(_ time: Double, duration: Double) {
        self.duration = duration
        seek(time)
    }
    func setScrubbing(_ active: Bool) {
        guard active != scrubbing else { return }
        if active {
            restoreAudition(); pause(); scrubbing = true
        } else {
            scrubbing = false; resumeAfterSeek = false
            queueSeek(playhead, exact: true)
        }
    }
    private func queueSeek(_ time: Double, exact: Bool) {
        pendingSeek = (TrackRenderer.time(EditTime(time)), exact)
        performSeek()
    }
    // QA1820: one seek in flight. A moving finger updates the desired time;
    // the next decode starts only once the current decode has finished.
    private func performSeek() {
        guard !seekInFlight, let pending = pendingSeek, let item = player.currentItem, item.status == .readyToPlay else { return }
        pendingSeek = nil; seekInFlight = true
        let tolerance = pending.1 ? CMTime.zero : CMTime(seconds: 0.08, preferredTimescale: 60000)
        player.seek(to: pending.0, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self, weak item] _ in
            Task { @MainActor in
                guard let self, self.player.currentItem === item else { return }
                self.seekInFlight = false
                if self.pendingSeek != nil { self.performSeek() }
                else if self.resumeAfterSeek { self.resumeAfterSeek = false; self.playAtSelectedSpeed() }
                else {self.installPreparedEffects()}
            }
        }
    }
    var stationaryPlayhead: Double { listenReturn ?? (auditionItem != nil ? auditionReturn : playhead) }
    func seekPaused(_ time: Double) { restoreAudition(); pause(); seek(time) }
    func jumpChange(forward: Bool, effectsOnly: Bool = false) {
        let anchor = stationaryPlayhead
        restoreAudition(); pause()
        if let target = navigation.destination(from: anchor, forward: forward, effectsOnly: effectsOnly) { seek(target) }
    }
    func togglePlay() {
        if playing || resumeAfterSeek { pause(); restoreAudition(); return }
        guard let item = player.currentItem else { return }
        restoreAudition(); auditionEnd = nil
        let restart = playhead >= playbackRange.upperBound - 0.05 || playhead < playbackRange.lowerBound
        if !restart, !seekInFlight, pendingSeek == nil, item === player.currentItem,
           item.status == .readyToPlay, abs(player.currentTime().seconds - playhead) <= 1.0 / 30 {
            playAtSelectedSpeed()
        } else {
            if restart { playhead = playbackRange.lowerBound }
            resumeAfterSeek = true; playing = true
            if restart || (!seekInFlight && pendingSeek == nil) { queueSeek(playhead, exact: true) }
            else { performSeek() }
        }
    }
    func audition(from start: Double, to end: Double) {
        let anchor=stationaryPlayhead
        restoreAudition(); pause()
        playhead=start; listenReturn=anchor; auditionEnd=end
        resumeAfterSeek=true; queueSeek(start,exact:true)
    }
    func audition(at time: Double) {
        let anchor = min(duration, max(0, listenReturn ?? time))
        restoreAudition(); pause()
        playhead = max(0, anchor - 1)
        listenReturn = anchor; auditionEnd = min(duration, anchor + 1)
        resumeAfterSeek = true; queueSeek(playhead, exact: true)
    }
    func snapped(_ time: Double, clips: [TimelineClip]) -> Double {
        for placement in TimelineLayout(clips: clips).placements {
            let clip = placement.clip, cursor = placement.start
            guard time >= placement.lower, time <= placement.upper, let wave = waveforms[clip.sourceID] else { continue }
            let candidates = (-2...2).map { min(cursor + clip.duration, max(cursor, time + Double($0) * 0.01)) }
            if let quiet = candidates.min(by: { wave.peak(at: clip.sourceTime(at: $0 - cursor)) < wave.peak(at: clip.sourceTime(at: $1 - cursor)) }),
               wave.peak(at: clip.sourceTime(at: quiet - cursor)) < 0.01 { return quiet }
            break
        }
        return time
    }

    func restoreAudition() {
        auditionToken = UUID(); auditionJob?.cancel(); auditionJob = nil; auditionPreparing = false
        guard auditioning || auditionItem != nil || listenReturn != nil else { return }
        let anchor = listenReturn ?? auditionReturn
        let temporaryItem = auditionItem != nil
        pause(); auditioning = false; auditionEnd = nil; auditionRange = nil; listenReturn = nil
        if temporaryItem { install(mainPlaybackItem, main: false) }
        auditionItem = nil; auditionLease = nil
        playhead = anchor; queueSeek(anchor, exact: true)
    }
    func auditionRemoval(_ range: ClosedRange<Double>, project: Project, folder: URL, selection: TimelineSelection? = nil) {
        guard !loading else { return }
        restoreAudition(); pause(); auditionPreparing = true
        let anchor = playhead
        let token = auditionToken, timelineToken = generation
        auditionJob = Task {
            defer { if token == auditionToken { auditionPreparing = false } }
            do {
                var candidate = project
                var scope = project.edit.timeline.scoped(selection ?? project.edit.timeline.entireSelection(range: EditInterval(range)))
                scope.timeline.remove(scope.selection)
                candidate.commit(EditState(timeline: scope.timeline, outputSize: project.edit.outputSize))
                guard candidate.edit.duration > 0 else { return }
                let media: TimelineMedia
                var lease: SourceCacheLease?
                if !candidate.edit.timeline.audio.isEmpty {
                    let prepared = try await SourceMediaCache.shared.prepared(project: candidate, folder: folder,effectPreparation:.cached) { _ in }
                    media = prepared.media; lease = prepared.lease
                } else { media = try await MediaRenderer.timeline(project: candidate, folder: folder,effectPreparation:.cached) }
                try Task.checkCancellation(); guard timelineToken == generation, token == auditionToken else { return }
                auditionReturn = anchor; auditionItem = mainPlaybackItem; auditionLease = lease
                let item = AVPlayerItem(asset: media.composition); item.videoComposition = media.playbackVideoComposition; try AudioGainMix.install(media.audioMix, on: item)
                install(item, main: false)
                await player.seek(to: CMTime(seconds: max(0, range.lowerBound - 1), preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
                try Task.checkCancellation(); guard token == auditionToken else { return }
                auditionEnd = min(candidate.edit.duration - 0.01, range.lowerBound + 1)
                auditionRange = candidate.edit.duration < project.edit.duration - 0.001 ? range : nil; auditioning = true; auditionPreparing = false
                player.play(); playing = true
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }

    func load(_ project: Project, folder: URL, includeTimelineDetails: Bool = true, audioPreviewRange: ClosedRange<Double>? = nil) async {
        // A requested timeline is committed state. Clear transient audition even
        // when it is identical to the loaded edit: Reset to 0 can otherwise hit
        // the fast path while a +12 dB slider audition remains installed.
        AudioGainMix.audition(nil, selection: TimelineSelection(), on: player.currentItem)
        if latestProject?.edit != project.edit {
            cancelObsoleteEffectWork()
            navigation = TimelineNavigation(project.edit)
        }
        latestProject = project; refreshExports(folder)
        func renderingState(_ edit: EditState?) -> EditState? { guard var edit else { return nil }; edit.timeline.bookmarks = []; return edit }
        let changed = renderingState(loadedEdit) != renderingState(project.edit)
        if !changed {
            loadedEdit = project.edit
            if includeTimelineDetails, application != nil {
                application = EffectApplicationReceipt.pending(for: project, in: folder)
            }
        }
        duration = project.edit.duration
        let pictureSources = Set(project.edit.timeline.video.map { $0.content.sourceID })
        let allSources = pictureSources.union(project.edit.timeline.audio.map(\.sourceID))
        guard changed || !pictureSources.isSubset(of: completedThumbnails) else { return }
        let token = changed ? UUID() : generation; generation = token
        if changed {
            restoreAudition(); pause(); loading = true
            effectJob?.cancel(); preparedEffects = nil; refiningEffects = false; accurateEffectsReady = false; effectRefinementError = nil
        }
        defer { if generation == token { preparingMedia = nil; loading = false; videoProgress = nil } }
        do {
            if changed {
                let receipt = includeTimelineDetails ? EffectApplicationReceipt.pending(for: project, in: folder) : nil
                startApplication(receipt)
                if receipt != nil && UIApplication.shared.applicationState != .active {
                    suspendApplication(); return
                }
                if project.edit.duration <= 0 {
                    install(nil); originalItem = nil; processedItem = nil; cacheLease = nil; playhead = 0; loadedEdit = project.edit; return
                }
                let hasEnhancement = project.edit.timeline.audio.contains { $0.enhancements.contains { $0.effects.contains(where: \.enabled) } }
                if let receipt { loadingLabel = "Applying " + receipt.title }
                else if hasEnhancement { loadingLabel = audioPreviewRange.map { "Preparing " + EffectPreviewWindow.label($0) } ?? "Applying audio filter" }
                else if project.edit.clips.contains(where: { $0.stabilization != nil }) { loadingLabel = "Applying stabilization" }
                else { loadingLabel = "Opening timeline" }
                notice = nil
                let stabilizing = audioPreviewRange == nil && (receipt?.tool == VideoTool.stabilize.rawValue ||
                    (receipt == nil && project.edit.clips.contains { $0.stabilization != nil }))
                preparingStabilization = stabilizing
                videoProgress = nil
                let worker = Task {
                    try await VideoEffectPreparation.$applyingSavedEdit.withValue(receipt != nil) {
                        if stabilizing {
                            return try await SourceMediaCache.shared.preparedTimeline(project: project, folder: folder, canvasSize: nil,
                                framesPerSecond: 30, effectPreparation: .cached) { step, value in
                                Task { @MainActor [weak self] in
                                    guard let self, generation == token, loading else { return }
                                    if step == .audioEffects { loadingLabel = "Preparing audio"; videoProgress = nil }
                                    else if value >= 1 { loadingLabel = "Finishing stabilization"; videoProgress = nil }
                                    else { loadingLabel = "Applying stabilization"; videoProgress = value }
                                }
                            }
                        }
                        return try await SourceMediaCache.shared.prepared(project: project, folder: folder, effectPreparation: .cached, audioPreviewRange: audioPreviewRange) { value in
                            Task { @MainActor [weak self] in if self?.generation == token { self?.videoProgress = value } }
                        }
                    }
                }
                preparingMedia = worker
                let prepared = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation(); guard generation == token else { return }
                preparingMedia = nil
                let media = prepared.media
                waveformRegions = prepared.processedRegions
                processedWaveforms = processedWaveforms.filter { prepared.processedRegions[$0.key] != nil }
                exportHDR = media.hdr
                canvas = media.videoComposition.renderSize
                let item = AVPlayerItem(asset: media.composition)
                item.videoComposition = media.playbackVideoComposition; try AudioGainMix.install(media.audioMix, on: item)
                cacheLease = prepared.lease; originalItem = item; processedItem = nil
                processedPreview = hasEnhancement; previewStale = false; canUseProcessed = false
                enhancementComparisonGains = prepared.listeningGains
                listeningGains = (1, 1); player.volume = 1
                install(item); loadedEdit = project.edit; loadedClips = project.edit.clips; loadedEffects = project.edit.effects
                loadedOutputSize = project.edit.outputSize
                // The stabilized picture is installed. Another effect can still
                // be refining on this revision, with its own progress in the editor.
                preparingStabilization = false
                seek(min(playhead, duration)); loading = false; notice = nil
                if media.effectAnalysisPending && audioPreviewRange == nil {
                    if application != nil && UIApplication.shared.applicationState != .active { suspendApplication(); return }
                    refineEffects(project, folder: folder)
                } else { finishApplication(in: folder) }
            }
            if !includeTimelineDetails { return }
            for item in project.edit.timeline.audio {
                guard let source = project.sources.first(where: { $0.id == item.sourceID }) else { continue }
                for region in item.enhancements {
                    let key = TrackRenderer.audioKey(source: source.id, effects: region.effects)
                    if let url = waveformRegions[key], processedWaveforms[key] == nil {
                        let wave = try await SourceMediaCache.shared.waveform(source: source, folder: folder, processed: url)
                        try Task.checkCancellation(); guard generation == token else { return }; processedWaveforms[key] = wave
                    }
                }
            }
            let budget = max(1, min(120, 360 / max(1, pictureSources.count)))
            thumbnails = thumbnails.filter { pictureSources.contains($0.key) }
            waveforms = waveforms.filter { allSources.contains($0.key) }; completedThumbnails.formIntersection(pictureSources)
            for source in project.sources where allSources.contains(source.id) {
                if waveforms[source.id] == nil {
                    let wave = try await SourceMediaCache.shared.waveform(source: source, folder: folder)
                    try Task.checkCancellation(); guard generation == token else { return }; waveforms[source.id] = wave
                }
                if pictureSources.contains(source.id), !completedThumbnails.contains(source.id) {
                    let sourceURL = folder.appendingPathComponent(source.filename)
                    let logReader = try await LogThumbnailSource.make(url: sourceURL)
                    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: sourceURL))
                    generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 160, height: 160)
                    generator.requestedTimeToleranceBefore = CMTime(seconds: 0.2, preferredTimescale: 600)
                    generator.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)
                    var images: [SourceThumbnail] = []
                    let step = max(1, source.duration / Double(budget))
                    for time in stride(from: 0.0, to: source.duration, by: step) {
                        try Task.checkCancellation()
                        let image: CGImage
                        if let logReader { image = try await logReader.image(at: time, maximumSize: CGSize(width: 160, height: 160)) }
                        else { image = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image }
                        guard generation == token else { return }
                        images.append(SourceThumbnail(time: time, image: UIImage(cgImage: image)))
                        if images.count == 1 || images.count.isMultiple(of: 8) { thumbnails[source.id] = images }
                    }
                    thumbnails[source.id] = images; completedThumbnails.insert(source.id)
                }
            }
        } catch is CancellationError {} catch {
            if generation == token, !interruptedApplication() {
                loadedEdit = nil; endApplicationTime()
                if application != nil { effectRefinementError = error.localizedDescription }
                else { self.error = error.localizedDescription }; notice = nil
            }
        }
    }
    /// The catalogue only needs source headers for the export settings.
    /// Building a preview here would also start waveform and effect analysis.
    func prepareCatalogueExport(_ project: Project, folder: URL) async {
        latestProject = project
        restorePausedExport(project, folder: folder)
        let edit = project.edit
        let sourceIDs = Set(edit.timeline.video.map { $0.content.sourceID })
        exportHDR = false
        if sourceIDs.isEmpty {
            canvas = edit.outputSize ?? CGSize(width: 1920, height: 1080)
            return
        }
        canvas = try? await MediaRenderer.canvas(project: project, folder: folder)
        for source in project.sources where sourceIDs.contains(source.id) {
            guard !Task.isCancelled else { return }
            let asset = AVURLAsset(url: folder.appendingPathComponent(source.filename))
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let formats = try? await track.load(.formatDescriptions), formats.contains(where: VideoColor.isHDR) {
                exportHDR = true
                return
            }
        }
    }

    func restorePausedExport(_ project: Project, folder: URL) {
        guard !rendering else { return }
        let checkpoint = ExportCheckpoint(folder: folder)
        let matches = checkpoint.matches(project)
        if matches { refreshExports(folder) }
        guard matches, matchingExport(project, folder: folder) == nil else {
            try? checkpoint.discard()
            exportCheckpoint = nil
            exportPaused = false
            return
        }
        exportCheckpoint = checkpoint
        savedExportSeconds = checkpoint.savedSeconds(total: project.edit.duration)
        exportPauseReason = checkpoint.pauseReason
        exportPaused = true
    }

    func pauseExport() {
        guard rendering, !processingPreview, let checkpoint = exportCheckpoint else { return }
        exportPaused = true
        savedExportSeconds = checkpoint.savedSeconds(total: latestProject?.edit.duration ?? 0)
        job?.cancel()
    }

    func render(_ project: Project, folder: URL, preview: Bool) {
        guard !rendering else { return }
        guard preview || !hasPhotoSaveInFlight else {
            error = "Wait for Photos to finish saving the previous export, then export again."; return
        }
        let checkpoint = preview ? nil : ExportCheckpoint(folder: folder)
        if let checkpoint {
            exportUsesAutoBackground = project.edit.clips.contains { clip in
                (clip.videoEffects ?? []).contains { $0.enabled && $0.kind == .autoBackground && $0.start < clip.end && $0.end > clip.start }
            }
            do { try checkpoint.prepare(project) }
            catch { self.error = error.localizedDescription; return }
            exportCheckpoint = checkpoint
            exportPauseReason = nil; checkpoint.setPauseReason(nil)
            exportPaused = false
            pendingExportSound = nil
        }
        let run = UUID()
        renderID = run
        restoreAudition(); pause(); rendering = true; notice = nil
        progress = 0
        exportProgress = checkpoint?.startingProgress(total: project.edit.duration) ?? ExportProgress(.opening)
        let projectID = project.id
        processingPreview = preview
        RecordingAppDelegate.keepAwake(awakeReason, active: true)
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: preview ? "Prepare audio preview" : "Finish video export") { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(self.backgroundTask); self.backgroundTask = .invalid }
                if self.processingPreview {
                    self.cancel(); self.notice = "Audio processing stopped in the background. Completed sources are kept."
                } else { self.pauseExport() }
            }
        }
        job = Task {
            var published = false
            defer {
                if let checkpoint, !exportPaused {
                    if !published { try? checkpoint.discard() }
                    exportCheckpoint = nil
                } else if let checkpoint {
                    savedExportSeconds = checkpoint.savedSeconds(total: project.edit.duration)
                }
                renderID = nil
                rendering = false;processingPreview=false; RecordingAppDelegate.keepAwake(awakeReason, active: false)
                if published { exportProgress = ExportProgress(.complete) }
                if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
            }
            do {
                try Task.checkCancellation()
                if preview {
                    #if DEBUG
                    if CommandLine.arguments.contains("--slow-audio-preview") { try await Task.sleep(for: .seconds(10)) }
                    #endif
                    var candidate = project
                    var prepared = try await SourceMediaCache.shared.prepared(project: candidate, folder: folder,effectPreparation:.cached) { value in
                        Task { @MainActor [weak self] in self?.progress = value }
                    }
                    // Cutting does not invalidate source-domain processing. Finish
                    // the source work, then build the latest edited arrangement.
                    while let latest = latestProject, latest.id == projectID, latest.edit != candidate.edit {
                        try Task.checkCancellation()
                        guard latest.edit.effects == project.edit.effects else { throw CancellationError() }
                        guard !latest.edit.clips.isEmpty else { return }
                        candidate = latest
                        prepared = try await SourceMediaCache.shared.prepared(project: candidate, folder: folder,effectPreparation:.cached) { _ in }
                    }
                    try Task.checkCancellation(); guard latestProject?.id == projectID else { return }
                    restoreAudition()
                    playbackRevision = UUID(); loadedClips = candidate.edit.clips
                    let item = AVPlayerItem(asset: prepared.media.composition); item.videoComposition = prepared.media.playbackVideoComposition; try AudioGainMix.install(prepared.media.audioMix, on: item)
                    install(item); processedItem = item; canUseProcessed = true
                    cacheLease = prepared.lease
                    processedPreview = true; previewStale = false; processedEffects = candidate.edit.effects
                    listeningGains = prepared.listeningGains; applyListeningGain()
                    seek(playhead)
                    if prepared.media.effectAnalysisPending && !refiningEffects && !accurateEffectsReady {refineEffects(candidate,folder:folder)}
                } else if let checkpoint {
                    refreshExports(folder)
                    let replaced = exports
                    let destination = folder.appendingPathComponent("Exports", isDirectory: true).appendingPathComponent(UUID().uuidString + ".mp4")
                    let receipt = try await MediaRenderer.render(project: project, folder: folder, destination: destination, checkpoint: checkpoint) { value in
                        guard value.step != .complete else { return }
                        Task { @MainActor [weak self] in
                            guard let self, self.renderID == run, !self.exportPaused else { return }
                            let next = self.exportProgress.advanced(to: value)
                            if next != self.exportProgress { self.exportProgress = next }
                        }
                    }
                    // Publishing the video and receipt may win a race with locking the phone.
                    published = true
                    exportPaused = false
                    let retired = retireExports(replaced, in: folder, checkpoint: checkpoint)
                    guard latestProject?.id == projectID else { return }
                    exports = [receipt] + exports.filter { $0.id != receipt.id && !retired.contains($0.id) }
                    exportURL = destination
                    if !Task.isCancelled { pendingExportSound = destination }
                }
            } catch {
                if !preview, !Task.isCancelled, let checkpoint, RecoverySpace.isFull(error) {
                    let reason = error.localizedDescription + " Free space, then resume the export."
                    exportPauseReason = reason; checkpoint.setPauseReason(reason)
                    pauseExport()
                } else if !preview, !Task.isCancelled, UIApplication.shared.applicationState != .active {
                    pauseExport()
                } else if !Task.isCancelled && !exportPaused {
                    self.error = error.localizedDescription
                }
            }
        }
    }
    private func switchComparison(_ item: AVPlayerItem, processed: Bool) {
        playbackRevision = UUID()
        let resume = playing || player.rate > 0
        let anchor = listenReturn
        restoreAudition(); pause(); processedPreview = processed; previewStale = false
        install(item); applyListeningGain()
        if let anchor { audition(at: anchor) }
        else { resumeAfterSeek = resume; queueSeek(playhead, exact: false) }
    }
    func original(_ project: Project, folder: URL) async {
        if let originalItem { switchComparison(originalItem, processed: false) }
        else {
            let resume = playing; restoreAudition(); pause()
            processedPreview = false; loadedClips = nil; await load(project, folder: folder)
            if resume { playAtSelectedSpeed() }
        }
    }
    func listenProcessed() {
        guard canUseProcessed, let processedItem else { return }
        switchComparison(processedItem, processed: true)
    }
    func refreshExports(_ folder: URL) {
        let directory = folder.appendingPathComponent("Exports", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        exports = files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url), let receipt = try? JSONDecoder().decode(ExportReceipt.self, from: data),
                  receipt.filename == URL(fileURLWithPath: receipt.filename).lastPathComponent,
                  FileManager.default.fileExists(atPath: directory.appendingPathComponent(receipt.filename).path) else { return nil }
            return receipt
        }.sorted { $0.createdAt > $1.createdAt }
        if exportURL == nil, let latest = exports.first { exportURL = directory.appendingPathComponent(latest.filename) }
    }
    func matchingExport(_ project: Project, folder: URL) -> ExportReceipt? {
        let ids = Set(project.edit.clips.map(\.sourceID)).union(project.edit.timeline.audio.map(\.sourceID))
        let sources = project.sources.filter { ids.contains($0.id) }
        return exports.first { receipt in
            (receipt.settings ?? ExportSettings()) == project.exportSettings && receipt.edit == project.edit && receipt.sources.filter { ids.contains($0.id) } == sources
                && FileManager.default.fileExists(atPath: folder.appendingPathComponent("Exports").appendingPathComponent(receipt.filename).path)
        }
    }
    func selectExport(_ project: Project, folder: URL) {
        refreshExports(folder)
        guard let receipt = matchingExport(project, folder: folder) ?? exports.first else { exportURL = nil; return }
        let url = folder.appendingPathComponent("Exports").appendingPathComponent(receipt.filename)
        exportURL = url
    }
    func exportActionsAppeared(for movie: URL) {
        guard !rendering, exportURL == movie, pendingExportSound == movie else { return }
        pendingExportSound = nil
        ExportCompletionSound.play()
    }
    private func retireExports(_ previous: [ExportReceipt], in folder: URL, checkpoint: ExportCheckpoint) -> Set<UUID> {
        // Processing is also reclaimed on launch if iOS interrupts deletion.
        // If a rename fails, the published movie is still ready to share.
        guard let scratch = try? checkpoint.detachCompletedFiles() else { return [] }
        let directory = folder.appendingPathComponent("Exports", isDirectory: true)
        var retired = Set<UUID>()
        for receipt in previous {
            let video = directory.appendingPathComponent(receipt.filename)
            guard !Self.photoImportFiles.contains(video) else { continue }
            let retiredVideo = scratch.appendingPathComponent(receipt.id.uuidString + ".mp4")
            do { try FileManager.default.moveItem(at: video, to: retiredVideo) } catch { continue }
            try? FileManager.default.moveItem(at: video.deletingPathExtension().appendingPathExtension("json"),
                                              to: retiredVideo.deletingPathExtension().appendingPathExtension("json"))
            savedPhotoExports.remove(video)
            retired.insert(receipt.id)
        }
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: scratch) }
        return retired
    }
    func saveToPhotos() {
        guard !rendering, let exportURL, !photoSavesInFlight.contains(exportURL), !savedPhotoExports.contains(exportURL) else { return }
        guard Self.photoImportFiles.insert(exportURL).inserted else {
            error = "This export is already being saved to Photos."; return
        }
        photoSavesInFlight.insert(exportURL)
        Task {
            defer { photoSavesInFlight.remove(exportURL); Self.photoImportFiles.remove(exportURL) }
            let permission = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard permission == .authorized || permission == .limited else {
                error = "Allow YouRec to add videos in Settings to save to Photos. You can also save or share the exported file."; return
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: exportURL)
                }
                // The selection can change while Photos copies a large video.
                // Completion belongs only to the file submitted by this task.
                savedPhotoExports.insert(exportURL)
            } catch { self.error = error.localizedDescription }
        }
    }
    func cancel() {
        if !processingPreview {
            exportPaused = false
            if !rendering { try? exportCheckpoint?.discard(); exportCheckpoint = nil }
            else { exportCheckpoint = nil }
        }
        job?.cancel()
    }
}

@MainActor
private enum ExportCompletionSound {
    private static var player: AVAudioPlayer?
    static func play() {
        // A short locally generated chime; no undocumented system sound IDs.
        let count = 14400, rate = 48000
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func number<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        text("RIFF"); number(UInt32(36 + count * 2)); text("WAVEfmt "); number(UInt32(16)); number(UInt16(1)); number(UInt16(1))
        number(UInt32(rate)); number(UInt32(rate * 2)); number(UInt16(2)); number(UInt16(16)); text("data"); number(UInt32(count * 2))
        for index in 0..<count {
            let time = Double(index) / Double(rate), envelope = min(1, Double(index) / 240) * pow(1 - Double(index) / Double(count), 2)
            let sample = (sin(time * 2 * .pi * 880) + sin(time * 2 * .pi * 1320) * 0.4) * envelope * 0.12
            number(Int16(sample * 32767))
        }
        player = try? AVAudioPlayer(data: data); player?.play()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #if DEBUG
        if CommandLine.arguments.contains("--observe-export-chime") {
            let name = CFNotificationName("com.antirez.yourec.tests.exportChime" as CFString)
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), name, nil, nil, true)
        }
        #endif
    }
}
