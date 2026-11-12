@preconcurrency import AVFoundation
import Foundation

// The engine PCM is copied before this value is published. After construction
// the buffer is immutable and retained until the encoder queue consumes it.
struct CapturedAudio: @unchecked Sendable { let sample: CMSampleBuffer }

/// A microphone engine independent of the video capture session. Replacing a
/// camera input must not tear down the audio stream. Host-time timestamps share
/// Core Media's clock with the video-only AVCaptureSession.
final class LiveMicrophone: @unchecked Sendable {
    private var engine: AVAudioEngine?
    private var inputID: String?
    private var format: AVAudioFormat?
    #if DEBUG
    private(set) var simulatedNegotiations = 0
    #endif
    var onSample: ((CapturedAudio) -> Void)?
    var isRunning: Bool { engine?.isRunning == true }
    func owns(_ candidate: AVAudioEngine?) -> Bool { candidate != nil && candidate === engine }

    func start() throws {
        #if DEBUG
        if CommandLine.arguments.contains("--microphone-negotiation-qa"), simulatedNegotiations < 2 {
            simulatedNegotiations += 1
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
        }
        #endif
        let audio = AVAudioSession.sharedInstance()
        guard let port = audio.currentRoute.inputs.first, audio.sampleRate > 0, audio.inputNumberOfChannels > 0 else {
            throw AudioProcessingError.invalidFormat
        }
        if let engine, engine.isRunning, inputID == port.uid,
           format?.sampleRate == audio.sampleRate, Int(format?.channelCount ?? 0) == audio.inputNumberOfChannels { return }
        stop()
        // A route change can replace the I/O unit (e.g. stereo output to an
        // AirPods hands-free mic). A stopped engine can retain the old bus format.
        let next = AVAudioEngine()
        let node = next.inputNode
        let hardware = node.inputFormat(forBus: 0)
        let output = node.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0,
              output.sampleRate > 0, output.channelCount > 0 else { throw AudioProcessingError.invalidFormat }
        node.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, time in
            guard buffer.frameLength > 0, time.isHostTimeValid else { return }
            guard let sample = try? CapturePCM.sample(buffer, at: CMClockMakeHostTimeFromSystemUnits(time.hostTime)) else { return }
            self?.onSample?(CapturedAudio(sample: sample))
        }
        do { try next.start() }
        catch {
            node.removeTap(onBus: 0)
            next.stop()
            throw error
        }
        engine = next
        inputID = port.uid
        format = hardware
    }
    func stop() {
        guard let old = engine else { return }
        engine = nil; inputID = nil; format = nil
        old.stop()
        old.inputNode.removeTap(onBus: 0)
    }
    func resetAfterMediaServicesReset() { stop() }
}
