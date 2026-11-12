@preconcurrency import AVFoundation
import Foundation
import Accelerate
import ImageIO
#if canImport(UIKit)
import UIKit
#endif

enum VideoEffectPreparation:Sendable {
    case final, cached, refinedPreview
    var preparesMissingAnalysis: Bool { self != .cached }
    @TaskLocal static var applyingSavedEdit = false
    @TaskLocal static var inspectionWindow: EffectPreviewWindow?
    @TaskLocal static var deferrable=false
    static func refine<Value>(_ operation:() async throws->Value) async throws->Value {
        try await $deferrable.withValue(true) {
            #if DEBUG
            if CommandLine.arguments.contains("--slow-video-effect-preparation") {try await Task.sleep(for:.seconds(6))}
            #endif
            return try await operation()
        }
    }
    static func checkpoint(_ ticket:VideoEffectAnalysisGate.Ticket?=nil) async throws {
        try ticket?.check();try Task.checkCancellation()
        guard deferrable else {return}
        if let ticket,!ticket.shouldCheckResources() {return}
        while true {
            try ticket?.check()
            #if canImport(UIKit)
            let inactive=await MainActor.run {UIApplication.shared.applicationState != .active}
            #else
            let inactive=false
            #endif
            let thermal=ProcessInfo.processInfo.thermalState
            if !inactive && thermal != .serious && thermal != .critical {return}
            try await Task.sleep(for:.milliseconds(250))
        }
    }
}
// Owned by each analysis actor. A foreground export supersedes a deferred
// preview producer; its next checkpoint releases decoders and temporary files.
// Waiting callers own no detached work and cancellation does not cancel others.
struct VideoEffectAnalysisGate {
    enum Superseded:Error {case work}
    final class Ticket:@unchecked Sendable {
        let key:String
        let deferrable:Bool
        private let lock=NSLock()
        private var active=true
        private var nextResourceCheck=0.0
        init(key:String,deferrable:Bool) {self.key=key;self.deferrable=deferrable}
        fileprivate func invalidate() {lock.lock();active=false;lock.unlock()}
        func shouldCheckResources()->Bool {
            lock.lock();defer {lock.unlock()}
            let now=ProcessInfo.processInfo.systemUptime
            guard now>=nextResourceCheck else {return false}
            nextResourceCheck=now+0.25;return true
        }
        func check() throws {
            lock.lock();let valid=active;lock.unlock()
            if !valid {throw Superseded.work}
        }
    }
    private var owners:[String:Ticket]=[:]
    func mustWait(_ key:String,deferrable:Bool)->Bool {
        guard let owner=owners[key] else {return false}
        return deferrable || !owner.deferrable
    }
    mutating func claim(_ key:String,deferrable:Bool)->Ticket? {
        if let current=owners[key] {
            guard !deferrable && current.deferrable else {return nil}
            current.invalidate()
        }
        let ticket=Ticket(key:key,deferrable:deferrable);owners[key]=ticket;return ticket
    }
    mutating func release(_ ticket:Ticket) {
        if owners[ticket.key] === ticket {owners.removeValue(forKey:ticket.key)}
    }
}
struct ExportProgress: Equatable, Sendable {
    enum Step: Int, Sendable {
        case opening, audioEffects, timeline, audioPeak, audio, picture
        case assembleVideo, assembleMovie, movieIndex, sourceFiles, verifying, saving, complete

        var title: String {
            switch self {
            case .opening: return "Reading export settings"
            case .audioEffects: return "Processing audio effects"
            case .timeline: return "Building the video timeline"
            case .audioPeak: return "Checking audio for clipping"
            case .audio: return "Encoding audio"
            case .picture: return "Rendering video"
            case .assembleVideo: return "Assembling video sections"
            case .assembleMovie: return "Combining video and audio"
            case .movieIndex: return "Writing the movie index"
            case .sourceFiles: return "Checking source files"
            case .verifying: return "Verifying the exported movie"
            case .saving: return "Saving the exported video"
            case .complete: return "Exported"
            }
        }

        // Estimated shares of the whole job. Within each pass, use completed
        // media time, sections or bytes. Only a successfully published file gets 100%.
        var range: ClosedRange<Double> {
            switch self {
            case .opening: return 0...0
            case .audioEffects, .timeline: return 0...0.06  // shared preparation callback
            case .audioPeak: return 0.06...0.09
            case .audio: return 0.09...0.14
            case .picture: return 0.14...0.90
            case .assembleVideo, .assembleMovie: return 0.90...0.965
            case .movieIndex: return 0.965...0.97
            case .sourceFiles: return 0.97...0.98
            case .verifying: return 0.98...0.99
            case .saving: return 0.99...0.99
            case .complete: return 1...1
            }
        }
    }
    let step: Step
    private(set) var fraction: Double

    var title: String {
        if step == .opening, fraction > 0 { return "Reopening the saved export" }
        if step == .timeline, fraction > step.range.upperBound { return "Rebuilding the video timeline" }
        return step.title
    }

    init(_ step: Step, _ value: Double = 0) {
        self.step = step
        let range = step.range
        let unit = value.isFinite ? min(1, max(0, value)) : 0
        fraction = range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }

    init(resumingAfter saved: ExportProgress?) {
        self.init(.opening)
        fraction = saved?.fraction ?? 0
    }

    // Late progress callbacks must never rewind the label or the bar. On
    // resume the label describes current work even below the saved fraction.
    func advanced(to next: Self) -> Self {
        guard next.step.rawValue >= step.rawValue else { return self }
        var result = next
        result.fraction = max(fraction, next.fraction)
        return result
    }
}

struct TimelineMedia {
    let composition: AVMutableComposition
    let videoComposition: AVMutableVideoComposition
    let audioMix: AVAudioMix?
    let playbackVideoComposition: AVVideoComposition?
    var hdr = false
    var effectAnalysisPending=false
}

// AVAssetExportSession explicitly allows cancellation from another thread.
// Keep this narrow capability in a Sendable wrapper instead of sharing mutation.
private final class ExportCancellation: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
    private let lock = NSLock()
    private var started = false
    private var cancelled = false

    func start(completion: @escaping @Sendable () -> Void) {
        lock.lock()
        guard !cancelled else { lock.unlock(); completion(); return }
        // Starting a session already cancelled by another thread raises an
        // Objective-C exception. Register the actual start before allowing cancel.
        session.exportAsynchronously(completionHandler: completion)
        started = true
        lock.unlock()
    }
    func cancel() {
        lock.lock()
        cancelled = true
        let running = started
        lock.unlock()
        if running { session.cancelExport() }
    }
}

enum MediaRenderer {
    static func timeline(project: Project, folder: URL, processedSources: [UUID: URL] = [:],
                         canvasSize: CGSize? = nil, framesPerSecond: Int = 30, stabilization: Bool = true, stabilizationPlans: [UUID: StabilizationPlan] = [:],
                         videoProgress: @escaping @Sendable (Double) -> Void = { _ in }, forceCustom: Bool = false, includeBackgroundAudio: Bool = true, previewDiagnostics:Bool = false,bypassVideoEffects:Bool=false,effectPreparation:VideoEffectPreparation = .final) async throws -> TimelineMedia {
        for clip in project.edit.clips { for lut in clip.color?.lutAssets ?? [] { _ = try LUTAssets.load(lut, folder: folder) } }
        return try await TrackRenderer.timeline(project: project, folder: folder, processedSources: processedSources,
            canvasSize: canvasSize, framesPerSecond: framesPerSecond, stabilization: stabilization, stabilizationPlans: stabilizationPlans, videoProgress: videoProgress,
            forceCustom: forceCustom, includeBackgroundAudio: includeBackgroundAudio, previewDiagnostics: previewDiagnostics,
            bypassVideoEffects: bypassVideoEffects, effectPreparation: effectPreparation)
    }

    static func sourceTimeline(project: Project, folder: URL, processedSources: [UUID: URL] = [:],
                         canvasSize: CGSize? = nil, framesPerSecond: Int = 30, stabilization: Bool = true, stabilizationPlans: [UUID: StabilizationPlan] = [:],
                         videoProgress: @escaping @Sendable (Double) -> Void = { _ in }, forceCustom: Bool = false, includeBackgroundAudio: Bool = true, previewDiagnostics:Bool = false,bypassVideoEffects:Bool=false,effectPreparation:VideoEffectPreparation = .final) async throws -> TimelineMedia {
        guard !project.edit.clips.isEmpty else { throw ProjectError.emptyTimeline }
        var project=project
        if !previewDiagnostics {
            for c in project.history[project.historyCursor].clips.indices {
                project.history[project.historyCursor].clips[c].videoEffects=project.history[project.historyCursor].clips[c].videoEffects?.map(\.recordingResult)
            }
        }
        if project.edit.layout.joins.contains(where: { $0.transition != nil }) {
            return try await TransitionRenderer.timeline(project: project, folder: folder, processedSources: processedSources,
                canvasSize: canvasSize, framesPerSecond: framesPerSecond, stabilization: stabilization, stabilizationPlans: stabilizationPlans, videoProgress: videoProgress, previewDiagnostics:previewDiagnostics,bypassVideoEffects:bypassVideoEffects,effectPreparation:effectPreparation)
        }
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw ProjectError.invalidMedia }
        var cursor = CMTime.zero
        var logicalCursor=0.0
        var instructions: [AVVideoCompositionInstructionProtocol] = []
        var canvas: CGSize? = canvasSize ?? project.edit.outputSize
        let fades = AVMutableAudioMixInputParameters(track: audio)
        var firstGeometry: (CGSize, CGAffineTransform)?
        var uniformGeometry = true
        // Stabilization is sampled in the compositor at source PTS, using the
        // same path as overlays and transitions. A layer transform event for
        // every output frame makes AVFoundation setup quadratic on long takes.
        let hasStabilization = stabilization && project.edit.clips.contains { clip in
            clip.stabilization.map { $0.level != .off } ?? false
        }
        let reframed = project.edit.outputSize != nil || project.edit.clips.contains { $0.crop != nil || $0.mirror != nil }
        var custom = forceCustom || hasStabilization || project.edit.clips.contains { !($0.videoEffects ?? []).isEmpty || $0.crop?.motion != nil || $0.color != nil || !($0.texts ?? []).isEmpty || !($0.images ?? []).isEmpty }
        var hdr = false
        var assets:[UUID:AVURLAsset]=[:]
        let sourceIDs=Set(project.edit.clips.map(\.sourceID))
        for source in project.sources where sourceIDs.contains(source.id) {
            let asset=AVURLAsset(url:folder.appendingPathComponent(source.filename));assets[source.id]=asset
            guard let track=try await asset.loadTracks(withMediaType:.video).first else { throw ProjectError.invalidMedia }
            let formats=try await track.load(.formatDescriptions)
            hdr=hdr || formats.contains { VideoColor.isHDR($0) }
            custom = custom || formats.contains { LogColor.profile($0) != nil }
            #if targetEnvironment(simulator)
            // The simulator's native AVPlayer compositor can fail with -19230
            // when fitting a source into a differently shaped canvas.
            if !custom, let canvas {
                let size = try await track.load(.naturalSize), transform = try await track.load(.preferredTransform)
                let bounds = CGRect(origin: .zero, size: size).applying(transform)
                custom = abs(bounds.width * canvas.height - bounds.height * canvas.width) > 1
            }
            #endif
        }
        var imageCache: [String: CGImage] = [:]
        var captureReaders:[String:EffectAnalysisReader]=[:]
        var captureHistories:[String:VideoEffectRecordedMatteHistory]=[:]
        var unavailableHistories=Set<String>()
        func captureReader(_ effect:VideoEffectSettings)throws->EffectAnalysisReader? {
            guard let metadata=effect.analysisFile else {return nil}
            let key=metadata+"|"+(effect.analysisDataFile ?? "")
            if let reader=captureReaders[key] {return reader}
            let reader=try EffectAnalysisReader(metadata:folder.appendingPathComponent(metadata),data:effect.analysisDataFile.map {folder.appendingPathComponent($0)})
            captureReaders[key]=reader;return reader
        }
        let totalDuration = project.edit.duration
        let playback=project.edit.clips.flatMap(\.playbackPieces)
        let sequenceClocks=Dictionary(project.edit.clips.map {($0.id,VideoEffectSequenceClock($0))},uniquingKeysWith:{first,_ in first})
        for (pieceIndex,clip) in playback.enumerated() {
            try Task.checkCancellation()
            guard let source = project.sources.first(where: { $0.id == clip.sourceID }) else { throw ProjectError.missingMedia }
            let url = folder.appendingPathComponent(source.filename)
            guard FileManager.default.fileExists(atPath: url.path) else { throw ProjectError.missingMedia }
            let asset = assets[source.id] ?? AVURLAsset(url:url)
            guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else { throw ProjectError.invalidMedia }
            let descriptions = try await sourceVideo.load(.formatDescriptions)
            hdr = hdr || descriptions.contains { VideoColor.isHDR($0) }
            let sourceSize = try await sourceVideo.load(.naturalSize)
            let preferred = try await sourceVideo.load(.preferredTransform)
            if let firstGeometry {
                if firstGeometry.0 != sourceSize || firstGeometry.1 != preferred { uniformGeometry = false }
            } else { firstGeometry = (sourceSize, preferred); video.preferredTransform = preferred }
            let bounds = CGRect(origin: .zero, size: sourceSize).applying(preferred)
            if canvas == nil { canvas = CGSize(width: (abs(bounds.width) / 2).rounded() * 2, height: (abs(bounds.height) / 2).rounded() * 2) }
            let sourceStart=TransitionRenderer.time(clip.frozenFrame?.sourceTime ?? clip.start)
            let sourceEnd=clip.frozenFrame == nil ? TransitionRenderer.time(clip.end) : sourceStart+CMTime(value:1,timescale:60000)
            let range=CMTimeRange(start:sourceStart,end:sourceEnd)
            try video.insertTimeRange(range, of: sourceVideo, at: cursor)
            logicalCursor+=clip.duration
            let outputEnd=TransitionRenderer.time(pieceIndex==playback.count-1 ? totalDuration : logicalCursor)
            let outputDuration=outputEnd-cursor
            if range.duration != outputDuration {
                video.scaleTimeRange(CMTimeRange(start: cursor, duration: range.duration), toDuration: outputDuration)
            }
            let size = canvas!
            let orientedSize = CGSize(width: abs(bounds.width), height: abs(bounds.height))
            var transform = preferred.concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
            let orientation = transform
            if let crop = clip.crop {
                transform = transform.concatenating(crop.transform(source: orientedSize, canvas: size))
            } else {
                let scale = min(size.width/orientedSize.width, size.height/orientedSize.height)
                transform = transform.concatenating(CGAffineTransform(scaleX: scale, y: scale))
                    .concatenating(CGAffineTransform(translationX: (size.width-orientedSize.width*scale)/2, y: (size.height-orientedSize.height*scale)/2))
            }
            if let mirror = clip.mirror { transform = transform.concatenating(mirror.transform(canvas: size)) }
            var activePlan: StabilizationPlan?
            if stabilization, let settings = clip.stabilization, settings.level != .off {
                if let existing = stabilizationPlans[clip.id] { activePlan = existing }
                else {
                    let offset = cursor.seconds
                    activePlan = try await VideoStabilizer.shared.plan(source: source, clip: clip, folder: folder) {
                        videoProgress((offset + $0 * clip.duration) / max(0.001, totalDuration))
                    }
                }
            }
            if custom {
                let images: [(ImageOverlay, CGImage)] = try (clip.images ?? []).filter { $0.start < clip.end && $0.end > clip.start }.map { overlay in
                    if let cached = imageCache[overlay.filename] { return (overlay, cached) }
                    guard let imageSource = CGImageSourceCreateWithURL(folder.appendingPathComponent(overlay.filename) as CFURL, nil),
                          let bitmap = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else { throw ProjectError.missingImage }
                    imageCache[overlay.filename] = bitmap
                    return (overlay, bitmap)
                }
                let customInstruction = VideoToolInstruction(trackID: video.trackID, clip: clip, start: cursor, transform: transform,
                    sourceSize: sourceSize, canvas: size, stabilization: activePlan, images: images,duration:outputDuration, fontFolder: folder, sequenceClock:sequenceClocks[clip.id]!)
                if clip.crop?.motion != nil { customInstruction.cropSource = (orientation, orientedSize) }
                customInstruction.videoEffectsEnabled = !bypassVideoEffects
                customInstruction.sourceHDR = descriptions.contains { VideoColor.isHDR($0) }
                customInstruction.sourceLog = descriptions.compactMap { LogColor.profile($0) }.first
                customInstruction.hdr=hdr
                customInstruction.effectFolder = folder
                customInstruction.sourceURL = url; customInstruction.sourceFPS = max(1, Double(try await sourceVideo.load(.nominalFrameRate)))
                // Keep the original composition clocks, effect keyframes and joins.
                // Only offline analysis is restricted to the inspector's sample.
                let analysisClip = VideoEffectPreparation.inspectionWindow.map { $0.analysisClip(clip) } ?? clip
                let bypassVideoEffects = bypassVideoEffects || analysisClip == nil
                let clip = analysisClip ?? clip
                if !bypassVideoEffects {
                    // Log is scene-referred. Preserve its extended highlights
                    // in the intermediate fusion cache until final grading.
                    customInstruction.nightFix=try await NightFixCache.shared.plan(url:url,folder:folder,clip:clip,hdr:customInstruction.sourceHDR || customInstruction.sourceLog != nil,preparation:effectPreparation) {value in
                        videoProgress((Double(pieceIndex)+value)/Double(max(1,playback.count)))
                    }
                    customInstruction.effectAnalysisPending = customInstruction.nightFix?.pending ?? false
                }
                if !bypassVideoEffects,clip.videoEffects?.contains(where:{$0.enabled && ($0.kind == .stepPrinting || $0.usesTemporalMatte)})==true {
                    customInstruction.sourceFrames=try await VideoEffectFrameAnalysis.shared.index(url:url,folder:folder)
                }
                if let frames=customInstruction.sourceFrames {
                    for effect in clip.videoEffects ?? [] where effect.enabled && effect.usesTemporalMatte {
                        guard let metadata=effect.analysisFile,let original=source.videoEffects?.first(where:{$0.analysisID==effect.analysisID}),
                              original.captureIdentity==effect.captureIdentity,VideoEffectAnalysis.prefix(source.videoEffects ?? [],before:original.id).map(\.captureIdentity)==VideoEffectAnalysis.prefix(clip.videoEffects ?? [],before:effect.id).map(\.captureIdentity),
                              clip.color==nil,clip.crop==nil,clip.mirror==nil,clip.stabilization==nil else {continue}
                        let key=source.id.uuidString+"|"+metadata+"|"+(effect.analysisDataFile ?? "")+"|"+effect.analysisID.uuidString
                        if captureHistories[key]==nil && !unavailableHistories.contains(key) {
                            if let capture=try? captureReader(effect),let samples=capture.temporalMatte(for:effect.analysisID),
                               let history=VideoEffectRecordedMatteHistory(samples:samples,finalized:capture.analysis.temporalMattesFinalized==true,source:frames) {
                                captureHistories[key]=history
                            } else {unavailableHistories.insert(key)}
                        }
                        customInstruction.effectMatteHistories[effect.id]=captureHistories[key]
                    }
                }
                if !bypassVideoEffects,clip.videoEffects?.contains(where:{$0.enabled && [.dollyZoom,.widescreen].contains($0.kind)})==true {
                    do {
                        let candidate=try await VideoEffectDepthCatalog.shared.source(url:url,generate:effectPreparation.preparesMissingAnalysis)
                        if let depth=candidate,depth.videoTrackID==sourceVideo.trackID,depth.aligned,depth.covers(sourceStart.seconds...sourceEnd.seconds) {
                            customInstruction.effectDepth=depth
                        }
                    } catch VideoEffectError.analysisPending {customInstruction.effectAnalysisPending=true}
                }
                if !bypassVideoEffects {
                    let historyDepth=(clip.videoEffects ?? []).filter {$0.enabled && $0.usesTemporalMatte}.reduce(0) {$0+($1.kind == .chromaKey ? VideoEffectMatteKind.key.capacity : VideoEffectMatteKind.isolation.capacity)-1}
                    let historyStart=customInstruction.sourceFrames.map {$0.times[max(0,$0.last(at:clip.start)-historyDepth)]} ?? clip.start
                    let analysisStart=max(0,min(historyStart,clip.start-0.25))
                    let maskEffects=(clip.videoEffects ?? []).filter {$0.enabled && $0.start<clip.end && $0.end>analysisStart}
                    let times=[analysisStart,clip.start]+maskEffects.map {max(analysisStart,$0.start)}+maskEffects.flatMap {$0.parameters.flatMap {$0.keyframes.map(\.time)}}
                    let needsMasks=times.contains {VideoEffectInputs.needsPerson(maskEffects.filter {$0.usesModernPersonMask && ($0.kind != .dollyZoom || customInstruction.effectDepth==nil)},at:$0)}
                    let saved=try maskEffects.first(where:{$0.analysisFile != nil}).flatMap(captureReader)
                    let needsAuto=maskEffects.contains {$0.usesAutoMaskStream}
                    if needsMasks && maskEffects.contains(where:{$0.usesModernPersonMask}) && ((saved?.analysis.masks.isEmpty ?? true) || needsAuto && saved?.hasMotionAwareAutoBackground != true) {
                        let capturedMaskFiles=maskEffects.first(where:{$0.analysisFile != nil}).flatMap {effect -> EffectMaskFiles? in
                            guard let name=effect.analysisFile,let data=effect.analysisDataFile,!(saved?.analysis.masks.isEmpty ?? true) else {return nil}
                            return EffectMaskFiles(metadata:folder.appendingPathComponent(name),data:folder.appendingPathComponent(data))
                        }
                        if needsAuto {
                            let frames: VideoEffectFrameIndex?
                            if effectPreparation == .final {
                                if let existing = customInstruction.sourceFrames { frames = existing }
                                else { frames = try await VideoEffectFrameAnalysis.shared.index(url: url, folder: folder) }
                            } else { frames = nil }
                            customInstruction.maskSource = SourcePersonMasks(url: url, hdr: customInstruction.sourceHDR,
                                orientation: SourcePersonMasks.orientation(size: sourceSize, preferred: preferred),
                                cacheDirectory: try EffectMaskAnalysis.directory(source: source, folder: folder, captured: capturedMaskFiles),
                                captured: capturedMaskFiles, mode: frames.map(SourcePersonMasks.Mode.export) ?? .preview)
                        } else {
                            do {
                                let files = try await EffectMaskAnalysis.shared.track(source: source, folder: folder,
                                    range: analysisStart...min(source.duration, clip.end + 0.25),
                                    captured: capturedMaskFiles, generate: effectPreparation.preparesMissingAnalysis)
                                customInstruction.effectMasks = files
                                customInstruction.effectAnalysisPending = customInstruction.effectAnalysisPending || !files.isComplete
                            } catch VideoEffectError.analysisPending {
                                customInstruction.effectAnalysisPending = true
                            }
                        }
                    }
                }
                if !bypassVideoEffects {
                    for effect in clip.videoEffects ?? [] where effect.enabled && effect.analysisFile==nil && effect.start<clip.end && effect.end>clip.start && (effect.kind == .dollyZoom || effect.kind == .crashZoom && effect.toggle("trackFace",at:clip.start)) {
                        do {customInstruction.effectSubjects[effect.id]=try await EffectSubjectAnalysis.shared.track(source:source,effect:effect,clip:clip,folder:folder,generate:effectPreparation.preparesMissingAnalysis)}
                        catch VideoEffectError.analysisPending {customInstruction.effectAnalysisPending=true}
                    }
                }
                for effect in clip.videoEffects ?? [] where !bypassVideoEffects && effect.enabled && effect.start<clip.end && effect.end>clip.start && effect.kind == .quantization {
                    // Captured palettes reproduce the live look until their input
                    // recipe, colour count or framing is edited.
                    let original=source.videoEffects?.first(where:{$0.analysisID==effect.analysisID})
                    let sameInput=VideoEffectAnalysis.prefix(source.videoEffects ?? [],before:original?.id ?? effect.id).map(\.captureIdentity)==VideoEffectAnalysis.prefix(clip.videoEffects ?? [],before:effect.id).map(\.captureIdentity)
                    let inputs:Set<String>=["colors","lockPalette"]
                    let samePalette=original?.parameters.filter { inputs.contains($0.id) } == effect.parameters.filter { inputs.contains($0.id) }
                    let unchanged=effect.analysisFile != nil && samePalette && sameInput && clip.color==nil && clip.crop==nil && clip.mirror==nil && clip.stabilization==nil
                    let locked=effect.toggle("lockPalette",at:clip.start) && effect.lockedPalette?.colors.count==Int(effect.number("colors",at:clip.start)) && effect.parameters.filter { ["colors","lockPalette"].contains($0.id) }.allSatisfy {$0.keyframes.isEmpty}
                    if !unchanged && !locked {
                        do {
                            let count = Double(max(1, playback.count))
                            customInstruction.effectPalettes[effect.id] = try await VideoEffectAnalysis.shared.palette(
                                source: source, effect: effect, folder: folder, instruction: customInstruction, analysisRange: clip.start...clip.end,
                                generate: effectPreparation.preparesMissingAnalysis) { value in
                                    videoProgress((Double(pieceIndex) + value) / count)
                                }
                        }
                        catch VideoEffectError.analysisPending {
                            customInstruction.effectPalettes[effect.id]=EffectPaletteTrack(frames:[])
                            customInstruction.effectAnalysisPending=true
                        }
                    }
                }
                instructions.append(customInstruction)
            } else {
                let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: video)
                layer.setTransform(transform, at: cursor)
                let instruction = AVMutableVideoCompositionInstruction()
                instruction.timeRange = CMTimeRange(start: cursor, duration: outputDuration)
                instruction.layerInstructions = [layer]
                instructions.append(instruction)
            }
            cursor = outputEnd
        }
        try await appendSourceAudio(project:project,folder:folder,processedSources:processedSources,composition:composition,track:audio,fades:fades)
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = canvas!
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))
        videoComposition.instructions = instructions
        if custom {
            videoComposition.customVideoCompositorClass = VideoToolCompositor.self
        }
        videoComposition.colorPrimaries = hdr ? AVVideoColorPrimaries_ITU_R_2020 : AVVideoColorPrimaries_ITU_R_709_2
        videoComposition.colorTransferFunction = hdr ? AVVideoTransferFunction_ITU_R_2100_HLG : AVVideoTransferFunction_ITU_R_709_2
        videoComposition.colorYCbCrMatrix = hdr ? AVVideoYCbCrMatrix_ITU_R_2020 : AVVideoYCbCrMatrix_ITU_R_709_2
        for instruction in instructions.compactMap({ $0 as? VideoToolInstruction }) { instruction.hdr = hdr }
        if !audio.segments.contains(where: { !$0.isEmpty }) { composition.removeTrack(audio) }
        fades.audioTimePitchAlgorithm = .spectral
        fades.audioTapProcessor = try CutAudioEnvelope.make(clips: project.edit.clips.flatMap(\.playbackPieces))
        let backgrounds = includeBackgroundAudio ? try await VideoEffectBackgroundAudio.append(project:project,folder:folder,to:composition) : []
        let mix = AVMutableAudioMix(); mix.inputParameters = [fades]+backgrounds
        let sourceBounds = firstGeometry.map { CGRect(origin: .zero, size: $0.0).applying($0.1) }
        let nativeCanvas = sourceBounds.map { CGSize(width: (abs($0.width) / 2).rounded() * 2, height: (abs($0.height) / 2).rounded() * 2) }
        // A workspace may explicitly pass the same canvas as the source. It
        // still needs no compositor for uniform, unmodified SDR footage.
        let directPlayback = uniformGeometry && canvas == nativeCanvas && !reframed && !custom && !hdr
        return TimelineMedia(composition: composition, videoComposition: videoComposition, audioMix: composition.tracks(withMediaType: .audio).isEmpty ? nil : mix, playbackVideoComposition: directPlayback ? nil : videoComposition, hdr: hdr,effectAnalysisPending:instructions.compactMap {$0 as? VideoToolInstruction}.contains(where:{$0.effectAnalysisPending}))
    }

    private static func appendSourceAudio(project:Project,folder:URL,processedSources:[UUID:URL],composition:AVMutableComposition,track:AVMutableCompositionTrack,fades:AVMutableAudioMixInputParameters) async throws {
        var runs:[[TimelineClip]]=[]
        for piece in project.edit.clips.flatMap(\.playbackPieces) {
            if let last=runs.last?.last,last.audioContinues(into:piece) {runs[runs.count-1].append(piece)}
            else {runs.append([piece])}
        }
        var position=0.0
        for run in runs {
            try Task.checkCancellation()
            let clip=run[0],duration=run.reduce(0){$0+$1.duration},start=TransitionRenderer.time(position),length=TransitionRenderer.time(position+duration)-start
            defer {position+=duration}
            guard !clip.mutesSourceAudio,let source=project.sources.first(where:{$0.id==clip.sourceID}) else {continue}
            let url=processedSources[source.id] ?? folder.appendingPathComponent(source.filename),asset=AVURLAsset(url:url)
            guard let sourceTrack=try await asset.loadTracks(withMediaType:.audio).first else {continue}
            let available=try await sourceTrack.load(.timeRange)
            let slices=run.map {EffectAudioRateSlice(start:$0.start,end:$0.end,duration:$0.duration)}
            if clip.frozenFrame==nil,EffectAudioRateRenderer.needsContinuousRender(slices) {
                let rendered=try await EffectAudioRateRenderer.shared.render(url:url,slices:slices,folder:folder,outputDuration:length,retainedBy:composition)
                let baked=AVURLAsset(url:rendered)
                guard let audio=try await baked.loadTracks(withMediaType:.audio).first else {throw ProjectError.invalidMedia}
                // The cache is already at the output clock. No scaled edit can
                // restart its time-pitch processing during playback or export.
                let range=CMTimeRange(start:.zero,duration:length)
                try track.insertTimeRange(range,of:audio,at:start)
            } else {
                let sourceStart=clip.frozenFrame?.sourceTime ?? clip.start
                let sourceDuration=clip.frozenFrame == nil ? run.last!.end-sourceStart : duration
                let range=CMTimeRange(start:TransitionRenderer.time(sourceStart),duration:TransitionRenderer.time(sourceDuration))
                try EffectAudioInsertion.insert(range,of:sourceTrack,into:track,at:start,duration:length,
                    retime:clip.frozenFrame==nil && abs(clip.rate-1)>0.000001,available:available)
                if clip.frozenFrame != nil,clip.videoEffects?.first(where:{$0.kind == .freezeFrame})?.choice("audio",at:clip.start)=="Fade out over hold" {
                    fades.setVolumeRamp(fromStartVolume:1,toEndVolume:0,timeRange:CMTimeRange(start:start,duration:length))
                }
            }
        }
    }

    static func canvas(project: Project, folder: URL) async throws -> CGSize {
        let edit = project.edit
        if let size = edit.outputSize { return size }
        guard let reference = edit.canvasSourceID, let source = project.sources.first(where: { $0.id == reference }),
              let track = try await AVURLAsset(url: folder.appendingPathComponent(source.filename)).loadTracks(withMediaType: .video).first else { throw ProjectError.invalidMedia }
        let size = try await track.load(.naturalSize), transform = try await track.load(.preferredTransform)
        let bounds = CGRect(origin: .zero, size: size).applying(transform)
        return CGSize(width: (abs(bounds.width) / 2).rounded() * 2, height: (abs(bounds.height) / 2).rounded() * 2)
    }

    private static func audioReader(_ asset: AVAsset, mix: AVAudioMix? = nil) async throws -> (AVAssetReader, AVAssetReaderAudioMixOutput)? {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return nil }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.audioMix = mix
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ProjectError.invalidMedia }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ProjectError.invalidMedia }
        return (reader, output)
    }
    private static func floats(_ sample: CMSampleBuffer) throws -> [Float] {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return [] }
        let size = CMBlockBufferGetDataLength(block)
        guard size > 0 else { return [] }
        guard size.isMultiple(of: MemoryLayout<Float>.size * 2) else { throw ProjectError.invalidMedia }
        var data = [Float](repeating: 0, count: size / MemoryLayout<Float>.size)
        let result = data.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: bytes.baseAddress!)
        }
        guard result == kCMBlockBufferNoErr else { throw ProjectError.invalidMedia }
        return data
    }

    private final class SpeechMeter {
        let left: UnsafeMutableRawPointer
        let right: UnsafeMutableRawPointer
        private var frame = [Float](repeating: 0, count: 960)
        private var filled = 0
        private var origin = 0
        private let binSeconds: Double
        private(set) var probabilities: Data

        init(bins: Int, binSeconds: Double) throws {
            guard let l = yr_denoiser_create() else { throw ProjectError.invalidMedia }
            guard let r = yr_denoiser_create() else { yr_denoiser_destroy(l); throw ProjectError.invalidMedia }
            left = l; right = r
            self.binSeconds = binSeconds
            probabilities = Data(count: bins)
        }
        deinit { yr_denoiser_destroy(left); yr_denoiser_destroy(right) }

        func append(_ samples: UnsafePointer<Float>, count: Int, at start: Int) {
            if start != origin + filled { flush() }
            var offset = 0
            while offset < count {
                if filled == 0 { origin = start + offset }
                let take = min(480 - filled, count - offset)
                frame.withUnsafeMutableBufferPointer { buffer in
                    (buffer.baseAddress! + 2 * filled).update(from: samples + 2 * offset, count: 2 * take)
                }
                offset += take; filled += take
                if filled == 480 { flush() }
            }
        }
        func flush() {
            guard filled > 0 else { return }
            frame.withUnsafeMutableBufferPointer { buffer in
                let samples = buffer.baseAddress!
                if filled < 480 { (samples + filled * 2).update(repeating: 0, count: (480 - filled) * 2) }
                // Protect speech in either channel, including stereo with opposite polarity.
                let p = max(yr_speech_probability(left, samples, 2), yr_speech_probability(right, samples + 1, 2))
                let time = Double(origin + filled / 2) / 48000
                let bin = min(probabilities.count - 1, max(0, Int(time / binSeconds)))
                probabilities[bin] = max(probabilities[bin], UInt8((min(1, max(0, p)) * 255).rounded()))
            }
            filled = 0
        }
    }

    static func waveform(asset: AVAsset, duration: Double, bins: Int = 600, measureSpeech: Bool = false,
                         progress: (@Sendable (Double) -> Void)? = nil) async throws -> SourceWaveform {
        guard duration.isFinite, duration > 0, bins > 0, let (reader, output) = try await audioReader(asset) else {
            return SourceWaveform(duration: duration, peaks: [], rms: [], speech: measureSpeech ? Data() : nil)
        }
        defer { if reader.status == .reading { reader.cancelReading() } }
        let binSeconds = duration / Double(bins)
        let meter = measureSpeech ? try SpeechMeter(bins: bins, binSeconds: binSeconds) : nil
        let feedback = progress.map(MediaProgress.init)
        var peaks = [Float](repeating: 0, count: bins), leftEnergy = peaks, rightEnergy = peaks
        var counts = [Int](repeating: 0, count: bins)
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let data = try floats(sample), origin = sample.presentationTimeStamp.seconds
            try data.withUnsafeBufferPointer { values in
                guard let samples = values.baseAddress, !values.isEmpty else { return }
                guard origin.isFinite else { throw ProjectError.invalidMedia }
                feedback?.report(origin / duration)
                meter?.append(samples, count: values.count / 2, at: Int((origin * 48000).rounded()))
                var i = 0
                while i < values.count / 2 {
                    let time = origin + Double(i) / 48000
                    let bin = Int(min(Double(bins - 1), max(0, floor(time / binSeconds))))
                    let boundary = ceil((Double(bin + 1) * binSeconds - origin) * 48000)
                    let end = bin == bins - 1 ? values.count / 2 : Int(min(Double(values.count / 2), max(Double(i + 1), boundary)))
                    let count = vDSP_Length(end - i), left = samples + 2 * i
                    var peak: Float = 0, l: Float = 0, r: Float = 0
                    vDSP_maxmgv(left, 1, &peak, count * 2)
                    vDSP_svesq(left, 2, &l, count); vDSP_svesq(left + 1, 2, &r, count)
                    peaks[bin] = max(peaks[bin], peak)
                    leftEnergy[bin] += l; rightEnergy[bin] += r; counts[bin] += end - i
                    i = end
                }
            }
        }
        if reader.status == .failed { throw reader.error ?? ProjectError.invalidMedia }
        // Measure the louder channel rather than downmixing away off-centre or out-of-phase speech.
        let rms = counts.indices.map { sqrt(max(leftEnergy[$0], rightEnergy[$0]) / Float(max(1, counts[$0]))) }
        meter?.flush()
        return SourceWaveform(duration: duration, peaks: peaks, rms: rms, speech: meter?.probabilities)
    }

    static func processedAudio(asset: AVAsset, duration: Double, effects: [AudioEffect], outputURL: URL, mix: AVAudioMix? = nil, progress: @escaping @Sendable (Double) -> Void) async throws -> Float {
        guard let (reader, output) = try await audioReader(asset, mix: mix) else { return 0 }
        defer { if reader.status == .reading { reader.cancelReading() } }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        var fileSettings = format.settings
        fileSettings[AVLinearPCMIsNonInterleaved] = false
        let file = try AVAudioFile(forWriting: outputURL, settings: fileSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
        var processor = AudioChainProcessor(effects: effects)
        let totalFrames = Int64((duration * 48000).rounded())
        var written: Int64 = 0
        func write(_ samples: [Float], skip: Int = 0) throws {
            let count = min(samples.count / 2 - skip, Int(totalFrames - written))
            guard count > 0 else { return }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)), let channels = buffer.floatChannelData else { throw ProjectError.invalidMedia }
            buffer.frameLength = AVAudioFrameCount(count)
            for frame in 0..<count {
                for channel in 0..<2 { channels[channel][frame] = processor.sample(samples[(frame + skip) * 2 + channel], channel: channel) }
            }
            try file.write(from: buffer)
            written += Int64(count)
        }
        func silence(until target: Int64) throws {
            while written < min(target, totalFrames) {
                try Task.checkCancellation()
                let count = min(4096, Int(min(target, totalFrames) - written))
                try write([Float](repeating: 0, count: count * 2))
            }
        }
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let timestamp = sample.presentationTimeStamp.seconds
            guard timestamp.isFinite else { throw ProjectError.invalidMedia }
            let target = max(0, Int64((timestamp * 48000).rounded()))
            try silence(until: target)
            let data = try floats(sample)
            try write(data, skip: min(data.count / 2, Int(max(0, written - target))))
            progress(Double(written) / Double(max(1, totalFrames)))
        }
        if reader.status == .failed { throw reader.error ?? ProjectError.invalidMedia }
        try silence(until: totalFrames)
        return processor.peak
    }

    /// AVAssetExportSession can stop interpolating at the last source picture
    /// of a time range (e.g. 719 pictures for 12 s of 30 → 60 fps). An
    /// instruction starting on the final output tick makes it render that tick.
    private static func exportComposition(_ source: AVVideoComposition, range: CMTimeRange) -> AVVideoComposition {
        let frame = source.frameDuration
        guard frame.isNumeric, frame > .zero, range.duration > frame else { return source }
        let ticks = CMTimeConvertScale(range.duration, timescale: frame.timescale, method: .roundTowardPositiveInfinity).value
        let offset = (ticks - 1) / frame.value * frame.value
        let cut = range.start + CMTime(value: offset, timescale: frame.timescale)
        var instructions = source.instructions
        guard let index = instructions.firstIndex(where: { $0.timeRange.start < cut && cut < $0.timeRange.end }),
              let composition = source.mutableCopy() as? AVMutableVideoComposition else { return source }
        let original = instructions[index]
        func part(_ range: CMTimeRange) -> AVVideoCompositionInstructionProtocol {
            if let native = original as? AVVideoCompositionInstruction,
               let copy = native.mutableCopy() as? AVMutableVideoCompositionInstruction {
                copy.timeRange = range
                return copy
            }
            return ExportInstructionRange(original, range: range)
        }
        instructions.replaceSubrange(index...index, with: [
            part(CMTimeRange(start: original.timeRange.start, end: cut)),
            part(CMTimeRange(start: cut, end: original.timeRange.end)),
        ])
        composition.instructions = instructions
        return composition
    }

    static func encode(_ asset: AVAsset, preset: String, to destination: URL, type: AVFileType, range: CMTimeRange,
                       videoComposition: AVVideoComposition? = nil, audioMix: AVAudioMix? = nil,
                       progress: @escaping @Sendable (Double) -> Void) async throws {
        try Task.checkCancellation()
        guard let export = AVAssetExportSession(asset: asset, presetName: preset) else { throw ProjectError.invalidMedia }
        export.videoComposition = videoComposition.map { exportComposition($0, range: range) }
        export.audioMix = audioMix
        export.outputURL = destination
        export.outputFileType = type
        export.shouldOptimizeForNetworkUse = true
        export.timeRange = range
        let monitor = Task {
            while !Task.isCancelled {
                progress(Double(export.progress))
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        defer { monitor.cancel() }
        let cancellation = ExportCancellation(export)
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                cancellation.start { continuation.resume() }
            }
        }, onCancel: { cancellation.cancel() })
        try Task.checkCancellation()
        guard export.status == .completed else { throw export.error ?? ProjectError.invalidMedia }
    }

    static func render(project: Project, folder: URL, destination: URL, checkpoint: ExportCheckpoint? = nil, progress: @escaping @Sendable (ExportProgress) -> Void) async throws -> ExportReceipt {
        guard !FileManager.default.fileExists(atPath: destination.path), !FileManager.default.fileExists(atPath: destination.deletingPathExtension().appendingPathExtension("json").path) else { throw CocoaError(.fileWriteFileExists) }
        let settings = project.exportSettings
        progress(ExportProgress(.opening))
        var canvas = project.edit.outputSize
        if settings.resolution != .project {
            if canvas == nil {
                if project.edit.clips.isEmpty { canvas = CGSize(width: 1920, height: 1080) }
                else { canvas = try await Self.canvas(project: project, folder: folder) }
            }
            canvas = canvas.map(settings.resolution.size(for:))
        }
        let prepared = try await SourceMediaCache.shared.preparedTimeline(project: project, folder: folder, canvasSize: canvas,
                                                                           framesPerSecond: settings.frameRate.rawValue) { step, value in
            progress(ExportProgress(step == .audioEffects ? .audioEffects : .timeline, value))
        }
        defer { withExtendedLifetime(prepared) {} }
        let media = prepared.media
        let peak: Float
        if let measured = checkpoint?.measuredPeak {
            peak = measured
        } else {
            progress(ExportProgress(.audioPeak))
            peak = try await ExportAudioLevel.peak(asset: media.composition, mix: media.audioMix, duration: project.edit.duration) {
                progress(ExportProgress(.audioPeak, $0))
            }
            try checkpoint?.savePeak(peak)
        }
        let codec = settings.outputCodec(hdr: media.hdr)
        let scratch = folder.appendingPathComponent("Processing", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let partial = scratch.appendingPathComponent(UUID().uuidString + ".mp4")
        let receiptPartial = scratch.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: partial); try? FileManager.default.removeItem(at: receiptPartial) }
        try Task.checkCancellation()
        let length = TransitionRenderer.time(project.edit.duration)
        if let checkpoint {
            try await checkpoint.render(media, duration: length, scratch: scratch, output: partial, codec: codec, progress: progress)
        } else {
            progress(ExportProgress(.picture))
            try await encode(media.composition, preset: codec == .hevc ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality,
                             to: partial, type: .mp4, range: CMTimeRange(start: .zero, duration: length),
                             videoComposition: media.videoComposition, audioMix: media.audioMix) { progress(ExportProgress(.picture, $0)) }
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let ids = Set(project.edit.clips.map(\.sourceID)).union(project.edit.timeline.audio.map(\.sourceID))
        let usedSources = project.sources.filter { ids.contains($0.id) }
        var checksums: [String: String] = [:]
        for (index, source) in usedSources.enumerated() {
            let count = Double(usedSources.count)
            progress(ExportProgress(.sourceFiles, Double(index) / count))
            checksums[source.id.uuidString] = try await SourceMediaCache.shared.fingerprint(folder.appendingPathComponent(source.filename)) { value in
                progress(ExportProgress(.sourceFiles, (Double(index) + value) / count))
            }
        }
        progress(ExportProgress(.verifying))
        let output = AVURLAsset(url: partial)
        let actual = try await output.load(.duration).seconds
        guard actual.isFinite, abs(actual - length.seconds) <= max(0.12, 2 / Double(settings.frameRate.rawValue)),
              !(try await output.loadTracks(withMediaType: .video)).isEmpty else { throw ProjectError.invalidMedia }
        if !media.composition.tracks(withMediaType: .audio).isEmpty,
           (try await output.loadTracks(withMediaType: .audio)).isEmpty { throw ProjectError.invalidMedia }
        let check = AVAssetImageGenerator(asset: output)
        check.maximumSize = CGSize(width: 96, height: 96)
        _ = try await check.image(at: .zero)
        if actual > 0.1 {
            progress(ExportProgress(.verifying, 0.5))
            check.requestedTimeToleranceBefore = CMTime(seconds: 0.15, preferredTimescale: 60000)
            _ = try await check.image(at: CMTime(seconds: max(0, min(actual, length.seconds) - 1 / Double(settings.frameRate.rawValue)), preferredTimescale: 60000))
        }
        progress(ExportProgress(.saving))
        let receipt = ExportReceipt(filename: destination.lastPathComponent, projectID: project.id, projectTitle: project.title,
            historyRevision: project.historyCursor, edit: project.edit, sources: usedSources, sourceChecksums: checksums,
            width: Int(media.videoComposition.renderSize.width), height: Int(media.videoComposition.renderSize.height), framesPerSecond: settings.frameRate.rawValue,
            settings: settings, codec: codec, audioPeak: peak)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let receiptData = try encoder.encode(receipt)
        try Task.checkCancellation()
        try receiptData.write(to: receiptPartial, options: .atomic)
        let receiptURL = destination.deletingPathExtension().appendingPathExtension("json")
        // Publish metadata first: a crash may leave an ignored receipt, but
        // never a completed video without its reproducible edit snapshot.
        try FileManager.default.moveItem(at: receiptPartial, to: receiptURL)
        do {
            try RecoveryFile.syncFile(receiptURL)
            try RecoveryFile.syncFile(partial)
        } catch { try? FileManager.default.removeItem(at: receiptURL); throw error }
        do { try FileManager.default.moveItem(at: partial, to: destination) }
        catch { try? FileManager.default.removeItem(at: receiptURL); throw error }
        try RecoveryFile.syncDirectory(destination.deletingLastPathComponent())
        progress(ExportProgress(.complete))
        return receipt
    }
}

// Capture and editing share explicit color metadata. HLG is genuine 10-bit HDR;
// EDR sensor processing alone is not a file-format choice.
enum VideoColor {
    static func isHDR(_ pixel: CVPixelBuffer) -> Bool {
        guard let value = CVBufferCopyAttachment(pixel, kCVImageBufferTransferFunctionKey, nil) as? String else { return false }
        return value == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String || value == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String
    }
    static func isHDR(_ format: CMFormatDescription) -> Bool {
        guard let value = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String else { return false }
        return value == AVVideoTransferFunction_ITU_R_2100_HLG || value == AVVideoTransferFunction_SMPTE_ST_2084_PQ
    }
    static func space(hdr: Bool) -> CGColorSpace {
        // CoreMedia's video transfer curve differs from the generic ITU-709
        // display profile. Encoding into the latter and tagging the result as
        // video 709 lifts shadows every time the custom compositor is used.
        let attachments: [CFString: CFString] = [
            kCVImageBufferColorPrimariesKey: hdr ? kCVImageBufferColorPrimaries_ITU_R_2020 : kCVImageBufferColorPrimaries_ITU_R_709_2,
            kCVImageBufferTransferFunctionKey: hdr ? kCVImageBufferTransferFunction_ITU_R_2100_HLG : kCVImageBufferTransferFunction_ITU_R_709_2,
            kCVImageBufferYCbCrMatrixKey: hdr ? kCVImageBufferYCbCrMatrix_ITU_R_2020 : kCVImageBufferYCbCrMatrix_ITU_R_709_2
        ]
        return CVImageBufferCreateColorSpaceFromAttachments(attachments as CFDictionary)!.takeRetainedValue()
    }
    static func properties(hdr: Bool) -> [String: String] {
        [AVVideoColorPrimariesKey: hdr ? AVVideoColorPrimaries_ITU_R_2020 : AVVideoColorPrimaries_ITU_R_709_2,
         AVVideoTransferFunctionKey: hdr ? AVVideoTransferFunction_ITU_R_2100_HLG : AVVideoTransferFunction_ITU_R_709_2,
         AVVideoYCbCrMatrixKey: hdr ? AVVideoYCbCrMatrix_ITU_R_2020 : AVVideoYCbCrMatrix_ITU_R_709_2]
    }
    static func tag(_ pixel: CVPixelBuffer, hdr: Bool) {
        let properties = properties(hdr: hdr)
        CVBufferSetAttachment(pixel, kCVImageBufferColorPrimariesKey, properties[AVVideoColorPrimariesKey]! as CFString, .shouldPropagate)
        CVBufferSetAttachment(pixel, kCVImageBufferTransferFunctionKey, properties[AVVideoTransferFunctionKey]! as CFString, .shouldPropagate)
        CVBufferSetAttachment(pixel, kCVImageBufferYCbCrMatrixKey, properties[AVVideoYCbCrMatrixKey]! as CFString, .shouldPropagate)
    }
}
