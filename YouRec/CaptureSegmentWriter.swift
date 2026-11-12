@preconcurrency import AVFoundation
import CoreImage
import VideoToolbox
import Foundation

/// Owns encoding independently of session reconfiguration. Camera changes may
/// pause video delivery; the audio input continues writing on this queue. Video
/// timestamps retain the gap, so playback holds the last frame instead of
/// shortening the audio timeline.
final class CaptureSegmentWriter: @unchecked Sendable {
    let queue = DispatchQueue(label: "yourec.media", qos: .userInitiated)
    let videoOutput = AVCaptureVideoDataOutput()
    var onVideoSample: ((CVPixelBuffer, Double) -> Void)?
    var onStart: ((URL) -> Void)?
    var onCanvas: ((CGSize) -> Void)?
    var onFinish: ((URL, Error?) -> Void)?
    var onEmpty: (() -> Void)?
    var onUnexpectedVideoGap: ((Double) -> Void)?
    var movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)

    private let lock = NSLock()
    private var active = false
    var isRecording: Bool { lock.lock(); defer { lock.unlock() }; return active }
    private var maximumAudioGap = 0.0
    private var maximumVideoGap = 0.0
    private var audioSamples: Int64 = 0
    private var clockCorrections: Int64 = 0
    private var clockOffset: Int64 = 0
    private var lastAudioEnd = CMTime.invalid
    var metrics: [String: Double] {
        lock.lock(); defer { lock.unlock() }
        return ["maximumInputAudioGap": maximumAudioGap, "maximumInputVideoGap": maximumVideoGap, "inputAudioSamples": Double(audioSamples), "clockCorrectionSamples": Double(clockCorrections), "maximumClockOffsetSamples": Double(clockOffset)]
    }
    private var destination: URL?
    #if DEBUG
    // Isolated fault-injection oracle. These two doubles report submitted
    // sample timestamps even when SIGKILL prevents the writer finalizing.
    private var probeClock: FileHandle?
    private func reportProbeEnd(_ time: CMTime, offset: off_t) {
        guard let clock = probeClock, sessionStart.isValid else { return }
        var value = (time - sessionStart).seconds
        _ = pwrite(clock.fileDescriptor, &value, MemoryLayout<Double>.size, offset)
    }
    #endif
    private var events: [CaptureEvent] = []
    private var writer: AVAssetWriter?
    private var video: AVAssetWriterInput?
    private var audio: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioHint: CMFormatDescription?
    private var sessionStart = CMTime.invalid
    private var lastVideo = CMTime.invalid
    private var lastVideoEnd = CMTime.invalid
    private var pendingAudio: [CMSampleBuffer] = []
    private var readyAudio: [CMSampleBuffer] = []
    private var normalizer: CaptureAudioNormalizer?
    private var draining = false
    private var finishing = false
    private var closing = false
    private var paddingDeadline: Double?
    private var finishFailure: Error?
    private var requestedEnd = CMTime.invalid
    private var lastPixel: CVPixelBuffer?
    private var holdingVideo = false
    private var expectedVideoHold = false
    private var outputSize = CGSize.zero
    private var requestedCanvas: CGSize?
    private var outputHDR = false
    private var outputLog: LUTInput?
    private let unmanagedContext = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false])
    private let imageContext = CIContext(options: [.cacheIntermediates: false])

    init() {
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
    }
    func connection(with type: AVMediaType) -> AVCaptureConnection? { videoOutput.connection(with: type) }
    func startRecording(to url: URL, canvas: CGSize? = nil) {
        queue.async {
            guard self.destination == nil, !self.finishing else { return }
            self.destination = url; self.events = []
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--recording-safety-clock"), url.pathComponents.contains("RecorderUITestProjects") {
                let probe = url.deletingPathExtension().appendingPathExtension("test-clock")
                if FileManager.default.createFile(atPath: probe.path, contents: Data(repeating: 0, count: 16)) {
                    self.probeClock = try? FileHandle(forWritingTo: probe)
                }
            }
            #endif
            self.requestedCanvas = canvas
            self.sessionStart = .invalid; self.lastVideo = .invalid; self.lastVideoEnd = .invalid
            self.lastPixel = nil; self.finishFailure = nil; self.requestedEnd = .invalid; self.closing = false; self.paddingDeadline = nil
            self.pendingAudio.removeAll(keepingCapacity: true)
            self.readyAudio.removeAll(keepingCapacity: true)
            self.lastAudioEnd = .invalid
            self.expectedVideoHold = false
            self.lock.lock()
            self.active = true; self.maximumAudioGap = 0; self.maximumVideoGap = 0; self.audioSamples = 0; self.clockCorrections = 0; self.clockOffset = 0
            self.lock.unlock()
        }
    }
    func recordEvent(_ kind: String, _ detail: String) {
        queue.async {
            let time = self.sessionStart.isValid && self.lastVideo.isValid ? max(0, (self.lastVideo - self.sessionStart).seconds) : 0
            self.saveEvent(kind, detail, time: time)
        }
    }
    func bookmark(at hostTime: CMTime) {
        queue.async {
            // CaptureController converts camera PTS into the host clock before
            // appendVideo. Use the tap clock, including during a camera hold.
            guard self.active, !self.closing, self.sessionStart.isNumeric else { return }
            self.saveEvent("bookmark", "Bookmark", time: max(0, (hostTime - self.sessionStart).seconds))
        }
    }
    private func saveEvent(_ kind: String, _ detail: String, time: Double) {
        guard let destination else { return }
        events.append(CaptureEvent(time: time, kind: kind, detail: detail))
        if let data = try? JSONEncoder().encode(events) {
            try? data.write(to: destination.deletingPathExtension().appendingPathExtension("events.json"), options: .atomic)
        }
    }
    func stopRecording() { queue.async { self.finish() } }
    func holdVideo(_ hold: Bool) {
        queue.async {
            self.holdingVideo = hold
            if hold { self.expectedVideoHold = true }
        }
    }

    // Called only from the sample-buffer delegate on queue.
    func appendVideo(_ sample: CMSampleBuffer) {
        guard destination != nil, !finishing, !holdingVideo, let pixel = sample.imageBuffer else { return }
        do {
            if writer == nil { try initialize(sample) }
            guard let writer, let video, writer.status == .writing else { throw writer?.error ?? ProjectError.invalidMedia }
            let time = sample.presentationTimeStamp
            guard time.isValid, !lastVideo.isValid || time > lastVideo else { return }
            let gap = lastVideo.isValid ? (time - lastVideo).seconds : 0
            if lastVideo.isValid {
                lock.lock(); maximumVideoGap = max(maximumVideoGap, gap); lock.unlock()
            }
            // A slow encoder can drop video while audio remains continuous.
            // Preserve timestamps; do not pretend the missing frames existed.
            guard video.isReadyForMoreMediaData else { return }
            let width = CVPixelBufferGetWidth(pixel), height = CVPixelBufferGetHeight(pixel)
            if width == Int(outputSize.width), height == Int(outputSize.height), VideoColor.isHDR(pixel) == outputHDR, LogColor.profile(pixel) == outputLog {
                guard video.append(sample) else { throw writer.error ?? ProjectError.invalidMedia }
                lastPixel = pixel
            } else {
                // Upright landscape front capture and rear portrait sensors can
                // have different dimensions. Preserve this segment's canvas.
                guard let adaptor, let pool = adaptor.pixelBufferPool else { throw ProjectError.invalidMedia }
                var normalized: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &normalized) == kCVReturnSuccess, let normalized else { throw ProjectError.invalidMedia }
                let image: CIImage
                if let outputLog {
                    image = LogColor.profile(pixel) == outputLog ? CIImage(cvPixelBuffer: pixel, options: [.colorSpace: NSNull()]) : LogColor.encode(LogColor.image(pixel), profile: outputLog)
                } else { image = LogColor.image(pixel, displayReferred: true) }
                let scale = min(outputSize.width / CGFloat(width), outputSize.height / CGFloat(height))
                let fitted = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    .transformed(by: CGAffineTransform(translationX: (outputSize.width - CGFloat(width) * scale) / 2,
                                                     y: (outputSize.height - CGFloat(height) * scale) / 2))
                let bounds = CGRect(origin: .zero, size: outputSize)
                if let outputLog {
                    LogColor.tag(normalized, profile: outputLog)
                    let black = LogColor.encode(CIImage(color: .black).cropped(to: bounds), profile: outputLog)
                    unmanagedContext.render(fitted.composited(over: black), to: normalized, bounds: bounds, colorSpace: nil)
                } else {
                    VideoColor.tag(normalized, hdr: outputHDR)
                    imageContext.render(fitted.composited(over: CIImage(color: .black).cropped(to: bounds)), to: normalized, bounds: bounds, colorSpace: VideoColor.space(hdr: outputHDR))
                }
                guard adaptor.append(normalized, withPresentationTime: time) else { throw writer.error ?? ProjectError.invalidMedia }
                lastPixel = normalized
            }
            if gap > 0.1 {
                saveEvent("videoHold", String(format: "Image held for %.2f s", gap),
                          time: max(0, (lastVideo - sessionStart).seconds))
                if !expectedVideoHold || gap > 2 { onUnexpectedVideoGap?(gap) }
            }
            expectedVideoHold = false
            lastVideo = time
            let duration = sample.duration.isValid && sample.duration.seconds > 0 ? sample.duration : CMTime(value: 1, timescale: 30)
            lastVideoEnd = time + duration
            #if DEBUG
            reportProbeEnd(lastVideoEnd, offset: 0)
            #endif
            onVideoSample?(lastPixel ?? pixel, max(0,(time-sessionStart).seconds))
            drainAudio()
        } catch { finish(error) }
    }
    func appendAudio(_ sample: CMSampleBuffer) {
        audioHint = sample.formatDescription
        guard destination != nil, !closing else { return }
        if let format = audioHint.flatMap({ CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }), format.mSampleRate > 0 {
            let time = sample.presentationTimeStamp
            lock.lock()
            if lastAudioEnd.isValid { maximumAudioGap = max(maximumAudioGap, (time - lastAudioEnd).seconds) }
            audioSamples += Int64(sample.numSamples)
            lock.unlock()
            lastAudioEnd = time + CMTime(seconds: Double(sample.numSamples) / format.mSampleRate, preferredTimescale: 48000)
            #if DEBUG
            reportProbeEnd(lastAudioEnd, offset: 8)
            #endif
        }
        pendingAudio.append(sample)
        if pendingAudio.count > 200 {
            finish(NSError(domain: "YouRecCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "The encoder could not keep up with the microphone. Recording was paused; completed footage was preserved."]))
            return
        }
        drainAudio()
    }
    private func initialize(_ firstVideo: CMSampleBuffer) throws {
        guard let destination, let pixel = firstVideo.imageBuffer else { throw ProjectError.invalidMedia }
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        writer.movieFragmentInterval = movieFragmentInterval
        if #available(iOS 17, macOS 14, *) {
            writer.initialMovieFragmentInterval = CMTime(seconds: 0.5, preferredTimescale: 600)
        }
        let width = requestedCanvas.map { Int($0.width) } ?? CVPixelBufferGetWidth(pixel)
        let height = requestedCanvas.map { Int($0.height) } ?? CVPixelBufferGetHeight(pixel)
        outputSize = CGSize(width: width, height: height)
        outputHDR = VideoColor.isHDR(pixel)
        outputLog = LogColor.profile(pixel)
        var compression: [String: Any] = [AVVideoAverageBitRateKey: width * height * 6,
                                         AVVideoExpectedSourceFrameRateKey: 30, AVVideoMaxKeyFrameIntervalDurationKey: 1,
                                         AVVideoAllowFrameReorderingKey: false]
        if outputHDR || outputLog != nil {
            compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel
        }
        if outputHDR {
            compression[kVTCompressionPropertyKey_HDRMetadataInsertionMode as String] = kVTHDRMetadataInsertionMode_Auto
        }
        var settings: [String: Any] = [AVVideoCodecKey: outputHDR || outputLog != nil ? AVVideoCodecType.hevc : .h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height, AVVideoCompressionPropertiesKey: compression]
        // Leave Log's color metadata on the source buffers/format hint. Setting
        // ordinary 709/HLG output properties requests an encoder color conversion
        // and silently destroys the original camera Log signal.
        if outputLog == nil { settings[AVVideoColorPropertiesKey] = VideoColor.properties(hdr: outputHDR) }
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: settings, sourceFormatHint: firstVideo.formatDescription)
        video.expectsMediaDataInRealTime = true
        // The live-effects clock uses this same timebase; an averaged nominal
        // frame rate cannot identify individual frames after a long capture.
        video.mediaTimeScale = 600
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192000
        ])
        audio.expectsMediaDataInRealTime = true
        guard writer.canAdd(video), writer.canAdd(audio) else { throw ProjectError.invalidMedia }
        writer.add(video); writer.add(audio)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: outputHDR || outputLog != nil ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        guard writer.startWriting() else { throw writer.error ?? ProjectError.invalidMedia }
        sessionStart = firstVideo.presentationTimeStamp
        normalizer = CaptureAudioNormalizer(start: sessionStart)
        writer.startSession(atSourceTime: sessionStart)
        self.writer = writer; self.video = video; self.audio = audio; self.adaptor = adaptor
        onCanvas?(outputSize)
        onStart?(destination)
    }
    private func drainAudio() {
        guard let writer, let audio, writer.status == .writing, sessionStart.isValid else { return }
        while (!pendingAudio.isEmpty || !readyAudio.isEmpty) && audio.isReadyForMoreMediaData {
            if readyAudio.isEmpty {
                do { readyAudio = try normalizer?.process(pendingAudio.removeFirst(), endingAt: finishing ? requestedEnd : nil) ?? [] }
                catch { finishFailure = error; finish(error); return }
                lock.lock()
                clockCorrections = normalizer?.clockCorrections ?? 0; clockOffset = normalizer?.maximumClockOffset ?? 0
                lock.unlock()
            }
            if !readyAudio.isEmpty && !audio.append(readyAudio.removeFirst()) { finish(writer.error ?? ProjectError.invalidMedia); return }
        }
        if (!pendingAudio.isEmpty || !readyAudio.isEmpty) && !draining && !finishing {
            draining = true
            queue.asyncAfter(deadline: .now() + .milliseconds(5)) {
                self.draining = false
                self.drainAudio()
            }
        }
    }
    private func finish(_ failure: Error? = nil) {
        if let failure { finishFailure = finishFailure ?? failure }
        guard let destination, !finishing else { return }
        #if DEBUG
        try? probeClock?.close(); probeClock = nil
        #endif
        TakeReceipt.releaseReserve(destination)
        finishing = true
        lock.lock(); active = false; lock.unlock()
        if writer == nil && failure == nil {
            try? FileManager.default.removeItem(at: TakeReceipt.location(destination))
            self.destination = nil; pendingAudio.removeAll(); readyAudio.removeAll(); finishing = false
            onEmpty?()
            return
        }
        let stopTime = CMClockGetTime(CMClockGetHostTimeClock())
        requestedEnd = lastVideoEnd.isValid ? max(lastVideoEnd, stopTime) : stopTime
        finishWhenDrained(destination, deadline: ProcessInfo.processInfo.systemUptime + 0.3)
    }
    private func finishWhenDrained(_ destination: URL, deadline: Double) {
        guard !closing else { return }
        // An engine tap may deliver a 100-ms block after Stop that contains the
        // final words before Stop. Allow bounded delivery/encoder drain time.
        drainAudio()
        let waitingForAudio = paddingDeadline == nil && (!lastAudioEnd.isValid || lastAudioEnd < requestedEnd)
        let waitingForEncoder = !pendingAudio.isEmpty || !readyAudio.isEmpty || video?.isReadyForMoreMediaData == false
        if finishFailure == nil, writer?.status == .writing, (waitingForAudio || waitingForEncoder), ProcessInfo.processInfo.systemUptime < deadline {
            queue.asyncAfter(deadline: .now() + .milliseconds(5)) { self.finishWhenDrained(destination, deadline: deadline) }
            return
        }
        if paddingDeadline == nil, pendingAudio.isEmpty && readyAudio.isEmpty, let normalizer, writer?.status == .writing {
            paddingDeadline = ProcessInfo.processInfo.systemUptime + 0.15
            do {
                let previous = normalizer.insertedSilence
                readyAudio = try normalizer.pad(until: requestedEnd)
                if normalizer.insertedSilence - previous > 2400 {
                    recordEvent("audioGap", "Microphone ended before Stop; silence preserves video timing.")
                }
                if normalizer.insertedSilence - previous > 24000 {
                    finishFailure = finishFailure ?? NSError(domain: "YouRecCapture", code: 3, userInfo: [NSLocalizedDescriptionKey: "The microphone ended before Stop. The remaining picture was saved with silence."])
                }
                drainAudio()
            } catch { finishFailure = error }
        }
        if let paddingDeadline, !readyAudio.isEmpty, writer?.status == .writing,
           ProcessInfo.processInfo.systemUptime < paddingDeadline {
            queue.asyncAfter(deadline: .now() + .milliseconds(5)) { self.finishWhenDrained(destination, deadline: paddingDeadline) }
            return
        }
        if let normalizer, normalizer.clockCorrections != 0 {
            recordEvent("audioClockCorrection", "Microphone clock aligned by \(normalizer.clockCorrections) samples; maximum offset \(normalizer.maximumClockOffset) samples at 48 kHz.")
        }
        closing = true
        var resultError = finishFailure ?? (!pendingAudio.isEmpty || !readyAudio.isEmpty ? NSError(domain: "YouRecCapture", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Audio could not be completely saved. The playable recording was preserved."]) : nil)
        let end = requestedEnd.isValid ? max(lastVideoEnd, requestedEnd) : lastVideoEnd
        if let video, let lastPixel, lastVideo.isValid, end > lastVideoEnd, video.isReadyForMoreMediaData {
            var description: CMVideoFormatDescription?
            var heldFrame: CMSampleBuffer?
            let time = max(lastVideo + CMTime(value: 1, timescale: 60000), end - CMTime(value: 1, timescale: 30))
            var timing = CMSampleTimingInfo(duration: end - time, presentationTimeStamp: time, decodeTimeStamp: .invalid)
            if CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: lastPixel, formatDescriptionOut: &description) == noErr,
               let description,
               CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: lastPixel,
                    formatDescription: description, sampleTiming: &timing, sampleBufferOut: &heldFrame) == noErr,
               let heldFrame {
                if !video.append(heldFrame) { resultError = writer?.error ?? ProjectError.invalidMedia }
            } else { resultError = ProjectError.invalidMedia }
        }
        video?.markAsFinished(); audio?.markAsFinished()
        if let writer, writer.status == .writing {
            if end.isValid { writer.endSession(atSourceTime: end) }
            writer.finishWriting { self.queue.async { self.complete(destination, error: resultError ?? self.writer?.error) } }
        } else { complete(destination, error: resultError ?? writer?.error ?? ProjectError.invalidMedia) }
    }
    private func complete(_ url: URL, error: Error?) {
        writer = nil; video = nil; audio = nil; adaptor = nil; destination = nil; lastPixel = nil
        pendingAudio.removeAll(keepingCapacity: true); readyAudio.removeAll(keepingCapacity: true); normalizer = nil; finishing = false
        onFinish?(url, error)
    }
}
