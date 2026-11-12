// Adapted from Kyle Howells DeepFilterNet-mlx, commit c6c4b9dc98c62bfa90ed66c5fd4f5d54e88c7b4f.
// Apache-2.0 / MIT. See LICENSE-APACHE, LICENSE-MIT and NOTICE.
// YouRec adaptation: local Core ML assets and validated DSP JSON; no MLX or downloads.
import Accelerate
import CoreML
import CryptoKit
import Foundation

private struct CoreMLSpectrumFrame {
    var real: [Float]
    var imag: [Float]
}

// MARK: - CoreML Streaming Engine

/// Core ML engine for the stateful DeepFilterNet3 per-hop graph.
///
/// The streaming graph exposes every GRU hidden state as an input and output.
/// Swift owns the temporal convolution buffers, spectrum history, lookahead,
/// and overlap-add state, so each prediction is one real 10 ms transition.
/// Not thread-safe. One stream per engine; call reset() before reusing a flushed engine.
public final class DeepFilterNetEngine {
    // MARK: - CoreML model

    private var streamingCoreMLModel: MLModel?
    private static let integrityLock = NSLock()
    private static var verifiedModels = Set<URL>()

    private static func verifyModel(_ directory: URL) throws {
        integrityLock.lock(); defer { integrityLock.unlock() }
        if verifiedModels.contains(directory) { return }
        let expected = [
            "weights/weight.bin": "1114ff972e25679e7f9707da85eee62659e1bdf50199035ecacba12e4ec0425d",
            "model.mil": "c2141d4890bbf6504ca58d1cac1ed65fd14ca6ef81e9f0423f668af6ba014dcd"
        ]
        for (name, checksum) in expected {
            let data = try Data(contentsOf: directory.appendingPathComponent(name), options: .mappedIfSafe)
            guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == checksum else {
                throw CoreMLEngineError.modelIntegrityMismatch
            }
        }
        verifiedModels.insert(directory)
    }

    // MARK: - Config constants

    private var fftSize = 960
    private var hopSize = 480
    private var freqBins = 481   // fftSize / 2 + 1
    private var nbErb = 32
    private var nbDf = 96
    private var dfOrder = 5
    private var dfLookahead = 2
    private var convLookahead = 2
    private var normAlpha: Float = 0
    private var wnorm: Float = 1

    // MARK: - DSP state

    private var vorbisWindow = [Float]()
    private var analysisMem = [Float]()
    private var synthesisMem = [Float]()

    // ERB filterbank matrices (from the MLX model)
    private var erbFB = [Float]()       // [freqBins, nbErb] (forward)
    private var erbInvFB = [Float]()    // [nbErb, freqBins] (inverse)

    // Feature normalization running states
    private var meanNormState = [Float]()
    private var unitNormState = [Float]()
    private var meanNormStateInit = [Float]()
    private var unitNormStateInit = [Float]()

    // FFT setups (complex-to-complex, supports non-power-of-2 like 960)
    private var fftForwardSetup: OpaquePointer?
    private var fftInverseSetup: OpaquePointer?

    // MARK: - Streaming state

    private let historyFrames = 10
    private var erbFeatureHistory = [Float]()
    private var specFeatureRealHistory = [Float]()
    private var specFeatureImagHistory = [Float]()
    private var spectrumQueue = [CoreMLSpectrumFrame]()
    private var spectrumPast = [CoreMLSpectrumFrame]()
    private var hEnc: MLMultiArray?
    private var hErb: MLMultiArray?
    private var hDf: MLMultiArray?
    private var streamingFrameCount = 0
    private var streamingInputSamples = 0
    private var streamingOutputSamples = 0
    private var delaySamplesToDrop = 0
    private var finished = false

    private let modelDirectory: URL
    /// Core ML compute units selected when the model was loaded.
    public let computeUnits: MLComputeUnits

    /// Creates a stateful DeepFilterNet3 Core ML runtime.
    ///
    /// - Parameters:
    ///   - modelDirectory: Directory containing `DeepFilterNet3-Streaming.mlpackage`
    ///     (or `.mlmodelc`) and `DeepFilterNet3-DSP.json`.
    ///   - computeUnits: Core ML execution units. The app pins CPU execution to
    ///     avoid changing numerical backends between approved previews.
    public init(
        modelDirectory: URL,
        computeUnits: MLComputeUnits = .cpuOnly
    ) {
        self.modelDirectory = modelDirectory.standardizedFileURL
        self.computeUnits = computeUnits
    }

    // MARK: - Prepare

    /// Loads the Core ML graph, creates DSP state, and returns initialization time in seconds.
    public func prepare() throws -> Double {
        let t0 = CFAbsoluteTimeGetCurrent()
        if streamingCoreMLModel != nil {
            try resetState()
            return CFAbsoluteTimeGetCurrent() - t0
        }
        releaseResources()
        var prepared = false
        defer { if !prepared { releaseResources() } }
        let data = try Data(contentsOf: modelDirectory.appendingPathComponent("DeepFilterNet3-DSP.json"))
        guard data.count < 1_000_000 else { throw CoreMLEngineError.streamingInputShapeMismatch }
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() ==
                "3dd66deaeafd7612f7208bfbbccb9d1d9691296acbab313e17fb099d5cdfdf29" else {
            throw CoreMLEngineError.modelIntegrityMismatch
        }
        let arrays = try JSONDecoder().decode([String: [Float]].self, from: data)
        func values(_ name: String, count: Int) throws -> [Float] {
            guard let values = arrays[name], values.count == count, values.allSatisfy({ $0.isFinite }) else {
                throw CoreMLEngineError.streamingInputShapeMismatch
            }
            return values
        }
        erbFB = try values("erb_fb", count: 481 * 32)
        erbInvFB = try values("erb_inv_fb", count: 32 * 481)
        meanNormStateInit = try values("mean_norm_state", count: 32)
        unitNormStateInit = try values("unit_norm_state", count: 96)
        normAlpha = 0.99
        wnorm = 1.0 / Float(fftSize * fftSize) * Float(2 * hopSize)
        vorbisWindow = (0..<fftSize).map { index in
            let inner = sin(0.5 * Float.pi * (Float(index) + 0.5) / Float(fftSize / 2))
            return sin(0.5 * Float.pi * inner * inner)
        }

        // Setup FFT (complex-to-complex via vDSP_DFT_zop)
        guard let fwd = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(fftSize), .FORWARD) else {
            throw CoreMLEngineError.fftSetupFailed
        }
        fftForwardSetup = fwd

        guard let inv = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(fftSize), .INVERSE) else {
            throw CoreMLEngineError.fftSetupFailed
        }
        fftInverseSetup = inv

        // Load only the per-hop artifact so an optional whole-sequence model
        // cannot add startup cost or ANE compiler noise to a live stream.
        try loadCoreMLModels()
        guard streamingCoreMLModel != nil else {
            throw CoreMLEngineError.streamingModelNotLoaded
        }

        // Initialize streaming state
        try resetState()
        prepared = true

        return CFAbsoluteTimeGetCurrent() - t0
    }

    deinit { releaseResources() }

    private func releaseResources() {
        if let fftForwardSetup { vDSP_DFT_DestroySetup(fftForwardSetup) }
        if let fftInverseSetup { vDSP_DFT_DestroySetup(fftInverseSetup) }
        fftForwardSetup = nil; fftInverseSetup = nil
        streamingCoreMLModel = nil
    }

    // MARK: - CoreML Model Loading

    private func loadCoreMLModels() throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        streamingCoreMLModel = try loadModel(
            named: "DeepFilterNet3-Streaming",
            from: modelDirectory,
            configuration: configuration
        )
        guard let model = streamingCoreMLModel else { throw CoreMLEngineError.streamingModelNotLoaded }
        let inputs: [String: [Int]] = [
            "feat_erb_buf": [1, 1, 10, 32], "feat_spec_buf": [1, 2, 10, 96],
            "h_enc_in": [1, 1, 256], "h_erb_in": [2, 1, 256], "h_df_in": [2, 1, 256]
        ]
        let outputs: [String: [Int]] = [
            "erb_mask": [1, 1, 1, 32], "df_coefs": [1, 5, 1, 96, 2],
            "h_enc_out": [1, 1, 256], "h_erb_out": [2, 1, 256], "h_df_out": [2, 1, 256]
        ]
        for (descriptions, expected) in [(model.modelDescription.inputDescriptionsByName, inputs),
                                         (model.modelDescription.outputDescriptionsByName, outputs)] {
            for (name, shape) in expected {
                guard let constraint = descriptions[name]?.multiArrayConstraint,
                      constraint.shape.map(\.intValue) == shape, constraint.dataType == .float16 else {
                    throw CoreMLEngineError.streamingInputShapeMismatch
                }
            }
        }
    }

    private func loadModel(
        named name: String,
        from directory: URL,
        configuration: MLModelConfiguration
    ) throws -> MLModel? {
        let compiled = directory.appendingPathComponent("\(name).mlmodelc")
        if FileManager.default.fileExists(atPath: compiled.path) {
            try Self.verifyModel(compiled)
            return try MLModel(contentsOf: compiled, configuration: configuration)
        }
        let package = directory.appendingPathComponent("\(name).mlpackage")
        if FileManager.default.fileExists(atPath: package.path) {
            // Development override only; Xcode bundles the compiled model for the app.
            let compiledURL = try MLModel.compileModel(at: package)
            defer {
                try? FileManager.default.removeItem(at: compiledURL)
                Self.integrityLock.lock(); Self.verifiedModels.remove(compiledURL); Self.integrityLock.unlock()
            }
            try Self.verifyModel(compiledURL)
            return try MLModel(contentsOf: compiledURL, configuration: configuration)
        }
        return nil
    }

    // MARK: - State Management

    private func resetState() throws {
        let overlapSize = fftSize - hopSize
        analysisMem = [Float](repeating: 0, count: overlapSize)
        synthesisMem = [Float](repeating: 0, count: overlapSize)
        meanNormState = meanNormStateInit
        unitNormState = unitNormStateInit
        erbFeatureHistory = [Float](repeating: 0, count: historyFrames * nbErb)
        specFeatureRealHistory = [Float](repeating: 0, count: historyFrames * nbDf)
        specFeatureImagHistory = [Float](repeating: 0, count: historyFrames * nbDf)
        spectrumQueue.removeAll(keepingCapacity: true)
        spectrumPast.removeAll(keepingCapacity: true)
        hEnc = try makeFloat16Array(shape: [1, 1, 256])
        hErb = try makeFloat16Array(shape: [2, 1, 256])
        hDf = try makeFloat16Array(shape: [2, 1, 256])
        streamingFrameCount = 0
        streamingInputSamples = 0
        streamingOutputSamples = 0
        delaySamplesToDrop = overlapSize
        finished = false
    }

    /// Clears recurrent, normalization, lookahead, and overlap-add state.
    public func reset() throws {
        guard streamingCoreMLModel != nil else { throw CoreMLEngineError.streamingModelNotLoaded }
        try resetState()
    }

    // MARK: - Streaming

    /// Processes exactly one 480-sample, 48 kHz mono hop.
    ///
    /// Initial calls can return no samples while fixed model lookahead fills.
    public func processHop(_ samples: [Float]) throws -> [Float] {
        guard !finished else { throw CoreMLEngineError.streamFinished }
        guard samples.allSatisfy({ $0.isFinite }) else { throw CoreMLEngineError.invalidSamples }
        guard samples.count == hopSize else {
            throw CoreMLEngineError.invalidHopSize(expected: hopSize, actual: samples.count)
        }
        streamingInputSamples += samples.count
        let output = try autoreleasepool {
            try processStreamingHop(samples)
        }
        streamingOutputSamples += output.count
        return output
    }

    /// Returns delayed output at the end of a stream.
    public func flush() throws -> [Float] {
        guard !finished else { return [] }
        finished = true
        guard streamingInputSamples > 0 else { return [] }
        var tail = [Float]()
        let zeroHop = [Float](repeating: 0, count: hopSize)
        for _ in 0..<(convLookahead + 1) {
            let output = try autoreleasepool {
                try processStreamingHop(zeroHop)
            }
            tail.append(contentsOf: output)
        }
        let remaining = max(0, streamingInputSamples - streamingOutputSamples)
        if tail.count > remaining {
            tail.removeLast(tail.count - remaining)
        }
        streamingOutputSamples += tail.count
        return tail
    }

    private func processStreamingHop(_ samples: [Float]) throws -> [Float] {
        guard let streamingCoreMLModel else {
            throw CoreMLEngineError.streamingModelNotLoaded
        }

        let (real, imag) = stftForward(audio: samples)
        guard real.count == freqBins, imag.count == freqBins else { return [] }

        var erb = computeERBFeatures(real: real, imag: imag, numFrames: 1)
        applyMeanNormalization(&erb, numFrames: 1)

        var featReal = Array(real.prefix(nbDf))
        var featImag = Array(imag.prefix(nbDf))
        applyUnitNormalization(real: &featReal, imag: &featImag, numFrames: 1)
        appendFrame(erb, to: &erbFeatureHistory, width: nbErb)
        appendFrame(featReal, to: &specFeatureRealHistory, width: nbDf)
        appendFrame(featImag, to: &specFeatureImagHistory, width: nbDf)

        spectrumQueue.append(CoreMLSpectrumFrame(real: real, imag: imag))
        streamingFrameCount += 1
        guard streamingFrameCount > convLookahead else { return [] }

        guard let hEnc, let hErb, let hDf else {
            throw CoreMLEngineError.streamingStateMissing
        }
        let erbInput = try makeFloat16Array(
            shape: [1, 1, historyFrames, nbErb], values: erbFeatureHistory
        )
        let specInput = try makeFloat16Array(
            shape: [1, 2, historyFrames, nbDf],
            values: specFeatureRealHistory + specFeatureImagHistory
        )
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "feat_erb_buf": MLFeatureValue(multiArray: erbInput),
            "feat_spec_buf": MLFeatureValue(multiArray: specInput),
            "h_enc_in": MLFeatureValue(multiArray: hEnc),
            "h_erb_in": MLFeatureValue(multiArray: hErb),
            "h_df_in": MLFeatureValue(multiArray: hDf),
        ])
        let prediction = try streamingCoreMLModel.prediction(from: provider)
        guard
            let maskArray = prediction.featureValue(for: "erb_mask")?.multiArrayValue,
            let coefsArray = prediction.featureValue(for: "df_coefs")?.multiArrayValue,
            let hEncOut = prediction.featureValue(for: "h_enc_out")?.multiArrayValue,
            let hErbOut = prediction.featureValue(for: "h_erb_out")?.multiArrayValue,
            let hDfOut = prediction.featureValue(for: "h_df_out")?.multiArrayValue
        else {
            throw CoreMLEngineError.streamingPredictionOutputMissing
        }
        try copyMultiArray(hEncOut, to: hEnc)
        try copyMultiArray(hErbOut, to: hErb)
        try copyMultiArray(hDfOut, to: hDf)

        var erbMask = [Float](repeating: 0, count: nbErb)
        try extractMLMultiArrayFlat(maskArray, into: &erbMask, count: nbErb)
        var coefs = [Float](repeating: 0, count: dfOrder * nbDf * 2)
        try extractMLMultiArrayFlat(coefsArray, into: &coefs, count: coefs.count)

        let target = spectrumQueue.removeFirst()
        var enhancedReal = target.real
        var enhancedImag = target.imag
        applyERBMask(
            specReal: &enhancedReal,
            specImag: &enhancedImag,
            erbMask: erbMask,
            numFrames: 1
        )
        let low = applyStreamingDeepFilter(target: target, coefs: coefs)
        enhancedReal.replaceSubrange(0..<nbDf, with: low.real)
        enhancedImag.replaceSubrange(0..<nbDf, with: low.imag)

        spectrumPast.append(target)
        let leftContext = dfOrder - dfLookahead - 1
        if spectrumPast.count > leftContext {
            spectrumPast.removeFirst(spectrumPast.count - leftContext)
        }

        var output = stftInverse(real: enhancedReal, imag: enhancedImag, numFrames: 1)
        if delaySamplesToDrop > 0, !output.isEmpty {
            let drop = min(delaySamplesToDrop, output.count)
            output.removeFirst(drop)
            delaySamplesToDrop -= drop
        }
        return output
    }

    private func applyStreamingDeepFilter(
        target: CoreMLSpectrumFrame,
        coefs: [Float]
    ) -> (real: [Float], imag: [Float]) {
        let leftContext = dfOrder - dfLookahead - 1
        let zero = CoreMLSpectrumFrame(
            real: [Float](repeating: 0, count: freqBins),
            imag: [Float](repeating: 0, count: freqBins)
        )
        var window = [CoreMLSpectrumFrame]()
        if spectrumPast.count < leftContext {
            window.append(contentsOf: repeatElement(zero, count: leftContext - spectrumPast.count))
        }
        window.append(contentsOf: spectrumPast.suffix(leftContext))
        window.append(target)
        window.append(contentsOf: spectrumQueue.prefix(dfLookahead))
        if window.count < dfOrder {
            window.append(contentsOf: repeatElement(zero, count: dfOrder - window.count))
        }

        var outReal = [Float](repeating: 0, count: nbDf)
        var outImag = [Float](repeating: 0, count: nbDf)
        for f in 0..<nbDf {
            var sumReal: Float = 0
            var sumImag: Float = 0
            for order in 0..<dfOrder {
                let coefficient = (order * nbDf + f) * 2
                let cr = coefs[coefficient]
                let ci = coefs[coefficient + 1]
                let sr = window[order].real[f]
                let si = window[order].imag[f]
                sumReal += sr * cr - si * ci
                sumImag += sr * ci + si * cr
            }
            outReal[f] = sumReal
            outImag[f] = sumImag
        }
        return (outReal, outImag)
    }

    private func appendFrame(_ frame: [Float], to history: inout [Float], width: Int) {
        precondition(frame.count == width)
        let retained = history.count - width
        history.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            memmove(base, base + width, retained * MemoryLayout<Float>.stride)
            base.advanced(by: retained).update(from: frame, count: width)
        }
    }

    private func makeFloat16Array(shape: [Int]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape.map(NSNumber.init), dataType: .float16)
        guard isContiguous(array) else { throw CoreMLEngineError.streamingInputShapeMismatch }
        memset(array.dataPointer, 0, array.count * MemoryLayout<Float16>.stride)
        return array
    }

    private func makeFloat16Array(shape: [Int], values: [Float]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape.map(NSNumber.init), dataType: .float16)
        guard array.count == values.count, isContiguous(array) else {
            throw CoreMLEngineError.streamingInputShapeMismatch
        }
        let destination = array.dataPointer.assumingMemoryBound(to: Float16.self)
        for index in values.indices {
            destination[index] = Float16(values[index])
        }
        return array
    }

    private func copyMultiArray(_ source: MLMultiArray, to destination: MLMultiArray) throws {
        guard source.dataType == .float16, destination.dataType == .float16,
              source.shape == destination.shape, source.count == destination.count else {
            throw CoreMLEngineError.streamingInputShapeMismatch
        }
        if isContiguous(source), isContiguous(destination) {
            memcpy(destination.dataPointer, source.dataPointer, source.count * MemoryLayout<Float16>.stride)
        } else {
            copyStridedValues(
                from: source.dataPointer.assumingMemoryBound(to: Float16.self),
                sourceStrides: source.strides.map(\.intValue),
                to: destination.dataPointer.assumingMemoryBound(to: Float16.self),
                destinationStrides: destination.strides.map(\.intValue), shape: source.shape.map(\.intValue)
            )
        }
    }

    private func copyStridedValues<T>(
        from source: UnsafePointer<T>,
        sourceStrides: [Int],
        to destination: UnsafeMutablePointer<T>,
        destinationStrides: [Int],
        shape: [Int]
    ) {
        for linearIndex in 0..<shape.reduce(1, *) {
            let sourceOffset = stridedOffset(
                linearIndex: linearIndex, shape: shape, strides: sourceStrides
            )
            let destinationOffset = stridedOffset(
                linearIndex: linearIndex, shape: shape, strides: destinationStrides
            )
            destination[destinationOffset] = source[sourceOffset]
        }
    }

    private func isContiguous(_ array: MLMultiArray) -> Bool {
        let shape = array.shape.map(\.intValue)
        let strides = array.strides.map(\.intValue)
        var expectedStride = 1
        for dimension in shape.indices.reversed() {
            if shape[dimension] > 1, strides[dimension] != expectedStride {
                return false
            }
            expectedStride *= shape[dimension]
        }
        return true
    }

    private func stridedOffset(linearIndex: Int, shape: [Int], strides: [Int]) -> Int {
        var remainder = linearIndex
        var offset = 0
        for dimension in shape.indices.reversed() {
            let coordinate = remainder % shape[dimension]
            remainder /= shape[dimension]
            offset += coordinate * strides[dimension]
        }
        return offset
    }

    // MARK: - STFT Forward (Analysis)

    /// Analysis STFT: audio → (real, imag) arrays each of shape [numFrames * freqBins].
    /// Uses complex-to-complex DFT via vDSP_DFT_zop (supports non-power-of-2 sizes like 960).
    private func stftForward(audio: [Float]) -> (real: [Float], imag: [Float]) {
        let overlapSize = fftSize - hopSize
        let buffer = analysisMem + audio

        let numFrames = max(0, (buffer.count - fftSize) / hopSize + 1)
        guard numFrames > 0 else {
            analysisMem = Array(buffer.suffix(overlapSize))
            return ([], [])
        }

        var real = [Float](repeating: 0, count: numFrames * freqBins)
        var imag = [Float](repeating: 0, count: numFrames * freqBins)

        var windowedFrame = [Float](repeating: 0, count: fftSize)
        var zeroImag = [Float](repeating: 0, count: fftSize)
        var outReal = [Float](repeating: 0, count: fftSize)
        var outImag = [Float](repeating: 0, count: fftSize)

        for frame in 0..<numFrames {
            let start = frame * hopSize

            // Apply window
            buffer.withUnsafeBufferPointer { buf in
                vDSP_vmul(
                    buf.baseAddress! + start, 1,
                    vorbisWindow, 1,
                    &windowedFrame, 1,
                    vDSP_Length(fftSize))
            }

            // Zero imaginary input (real signal)
            vDSP_vclr(&zeroImag, 1, vDSP_Length(fftSize))

            // Complex DFT
            vDSP_DFT_Execute(
                fftForwardSetup!,
                windowedFrame, zeroImag,
                &outReal, &outImag)

            // Copy first freqBins (481) unique bins (conjugate symmetry)
            let baseIdx = frame * freqBins
            for k in 0..<freqBins {
                real[baseIdx + k] = outReal[k] * wnorm
                imag[baseIdx + k] = outImag[k] * wnorm
            }
        }

        // Update analysis memory
        let consumed = numFrames * hopSize
        analysisMem = Array(buffer.suffix(buffer.count - consumed))
        if analysisMem.count > overlapSize {
            analysisMem = Array(analysisMem.suffix(overlapSize))
        } else if analysisMem.count < overlapSize {
            analysisMem = [Float](repeating: 0, count: overlapSize - analysisMem.count) + analysisMem
        }

        return (real, imag)
    }

    // MARK: - STFT Inverse (Synthesis)

    /// Inverse STFT: complex spectrum → audio via overlap-add.
    private func stftInverse(real: [Float], imag: [Float], numFrames: Int) -> [Float] {
        guard numFrames > 0 else { return [] }

        let inverseScale: Float = 1.0 / Float(fftSize)
        let outputLen = numFrames * hopSize
        var output = [Float](repeating: 0, count: outputLen)

        var fullReal = [Float](repeating: 0, count: fftSize)
        var fullImag = [Float](repeating: 0, count: fftSize)
        var outReal = [Float](repeating: 0, count: fftSize)
        var outImag = [Float](repeating: 0, count: fftSize)

        for frame in 0..<numFrames {
            let baseIdx = frame * freqBins

            // Undo analysis normalization before the inverse transform.
            for k in 0..<freqBins {
                fullReal[k] = real[baseIdx + k] / wnorm
                fullImag[k] = imag[baseIdx + k] / wnorm
            }

            // Reconstruct conjugate symmetric part: X[N-k] = conj(X[k])
            for k in 1..<(fftSize / 2) {
                fullReal[fftSize - k] = fullReal[k]
                fullImag[fftSize - k] = -fullImag[k]
            }

            // Inverse DFT
            vDSP_DFT_Execute(
                fftInverseSetup!,
                fullReal, fullImag,
                &outReal, &outImag)

            // Scale by 1/N
            var scale = inverseScale
            vDSP_vsmul(outReal, 1, &scale, &outReal, 1, vDSP_Length(fftSize))

            // Apply synthesis window
            var windowed = [Float](repeating: 0, count: fftSize)
            vDSP_vmul(outReal, 1, vorbisWindow, 1, &windowed, 1, vDSP_Length(fftSize))

            // Overlap-add with synthesis memory
            let overlapCount = min(fftSize, synthesisMem.count)
            for i in 0..<overlapCount {
                windowed[i] += synthesisMem[i]
            }

            // Copy hop-size samples to output
            let outStart = frame * hopSize
            for i in 0..<hopSize {
                if outStart + i < outputLen {
                    output[outStart + i] = windowed[i]
                }
            }

            // Update synthesis memory
            let overlapSize = fftSize - hopSize
            synthesisMem = Array(windowed[hopSize..<fftSize])
            if synthesisMem.count < overlapSize {
                synthesisMem.append(
                    contentsOf: [Float](repeating: 0, count: overlapSize - synthesisMem.count))
            }
        }

        return output
    }

    // MARK: - Feature Extraction

    /// Compute ERB power features in dB from complex spectrum.
    /// Returns [numFrames * nbErb] in dB scale (not yet normalized).
    private func computeERBFeatures(
        real: [Float], imag: [Float], numFrames: Int
    ) -> [Float] {
        // Power spectrum: |X|^2
        var power = [Float](repeating: 0, count: numFrames * freqBins)
        for i in 0..<power.count {
            power[i] = real[i] * real[i] + imag[i] * imag[i]
        }

        // ERB compression: power[T, F] @ erbFB[F, B] → erb[T, B]
        var erb = [Float](repeating: 0, count: numFrames * nbErb)
        if !erbFB.isEmpty {
            vDSP_mmul(
                power, 1, erbFB, 1, &erb, 1,
                vDSP_Length(numFrames), vDSP_Length(nbErb), vDSP_Length(freqBins))
        }

        // Convert to dB: 10 * log10(erb + 1e-10)
        var count32 = Int32(erb.count)
        var epsilon: Float = 1e-10
        vDSP_vsadd(erb, 1, &epsilon, &erb, 1, vDSP_Length(erb.count))
        vvlog10f(&erb, erb, &count32)
        var scale: Float = 10.0
        vDSP_vsmul(erb, 1, &scale, &erb, 1, vDSP_Length(erb.count))

        return erb
    }

    /// Apply exponential mean normalization to ERB features.
    /// state = x * (1 - alpha) + state * alpha; x_norm = (x - state) / 40
    private func applyMeanNormalization(_ erb: inout [Float], numFrames: Int) {
        let oneMinusAlpha = 1.0 - normAlpha
        for t in 0..<numFrames {
            let baseIdx = t * nbErb
            for b in 0..<nbErb {
                let x = erb[baseIdx + b]
                meanNormState[b] = x * oneMinusAlpha + meanNormState[b] * normAlpha
                erb[baseIdx + b] = (x - meanNormState[b]) / 40.0
            }
        }
    }

    /// Apply exponential unit normalization to complex spec features.
    /// state = |x| * (1 - alpha) + state * alpha; x_norm = x / sqrt(state)
    private func applyUnitNormalization(
        real: inout [Float], imag: inout [Float], numFrames: Int
    ) {
        let oneMinusAlpha = 1.0 - normAlpha
        for t in 0..<numFrames {
            let baseIdx = t * nbDf
            for f in 0..<nbDf {
                let re = real[baseIdx + f]
                let im = imag[baseIdx + f]
                let mag = sqrtf(re * re + im * im)
                unitNormState[f] = mag * oneMinusAlpha + unitNormState[f] * normAlpha
                let norm = sqrtf(max(unitNormState[f], 1e-10))
                real[baseIdx + f] = re / norm
                imag[baseIdx + f] = im / norm
            }
        }
    }

    // MARK: - Post-processing

    /// Extract float32 data from an MLMultiArray, handling float16 output from CoreML.
    private func extractMLMultiArrayFlat(
        _ array: MLMultiArray, into output: inout [Float], count: Int
    ) throws {
        guard array.count == count, output.count == count,
              array.dataType == .float16 || array.dataType == .float32 else {
            throw CoreMLEngineError.streamingInputShapeMismatch
        }
        if !isContiguous(array) {
            let shape = array.shape.map(\.intValue)
            let strides = array.strides.map(\.intValue)
            switch array.dataType {
            case .float16:
                let source = array.dataPointer.assumingMemoryBound(to: Float16.self)
                for index in 0..<count {
                    output[index] = Float(source[stridedOffset(
                        linearIndex: index, shape: shape, strides: strides
                    )])
                }
            case .float32:
                let source = array.dataPointer.assumingMemoryBound(to: Float.self)
                for index in 0..<count {
                    output[index] = source[stridedOffset(
                        linearIndex: index, shape: shape, strides: strides
                    )]
                }
            default:
                throw CoreMLEngineError.streamingInputShapeMismatch
            }
        } else if array.dataType == .float16 {
            var source = vImage_Buffer(
                data: array.dataPointer,
                height: 1,
                width: vImagePixelCount(count),
                rowBytes: count * MemoryLayout<UInt16>.stride)
            output.withUnsafeMutableBytes { bytes in
                var destination = vImage_Buffer(
                    data: bytes.baseAddress,
                    height: 1,
                    width: vImagePixelCount(count),
                    rowBytes: count * MemoryLayout<Float>.stride)
                vImageConvert_Planar16FtoPlanarF(&source, &destination, vImage_Flags(kvImageNoFlags))
            }
        } else {
            let ptr = array.dataPointer.assumingMemoryBound(to: Float.self)
            output.withUnsafeMutableBufferPointer { dst in
                dst.baseAddress!.update(from: ptr, count: count)
            }
        }
    }

    /// Apply ERB mask to the full spectrum.
    /// Expands the 32-band mask to 481 bins using the inverse filterbank,
    /// then multiplies the spectrum by the per-frequency gain.
    private func applyERBMask(
        specReal: inout [Float], specImag: inout [Float],
        erbMask: [Float], numFrames: Int
    ) {
        // Expand mask: mask[T, B] @ invFb[B, F] → fullMask[T, F]
        var fullMask = [Float](repeating: 0, count: numFrames * freqBins)
        if !erbInvFB.isEmpty {
            vDSP_mmul(
                erbMask, 1, erbInvFB, 1, &fullMask, 1,
                vDSP_Length(numFrames), vDSP_Length(freqBins), vDSP_Length(nbErb))
        }

        // Apply mask to spectrum
        vDSP_vmul(specReal, 1, fullMask, 1, &specReal, 1, vDSP_Length(specReal.count))
        vDSP_vmul(specImag, 1, fullMask, 1, &specImag, 1, vDSP_Length(specImag.count))
    }


}

// MARK: - Error Types

/// Errors reported by the low-level DeepFilterNet3 Core ML runtime.
public enum CoreMLEngineError: Error, LocalizedError {
    case modelIntegrityMismatch
    case streamFinished
    case invalidSamples
    case streamingModelNotLoaded
    case streamingPredictionOutputMissing
    case streamingStateMissing
    case streamingInputShapeMismatch
    case invalidHopSize(expected: Int, actual: Int)
    case fftSetupFailed

    public var errorDescription: String? {
        switch self {
        case .modelIntegrityMismatch:
            return "The bundled DeepFilterNet3 model does not match this project’s model version. Its audio has been preserved."
        case .streamFinished:
            return "Reset the DeepFilterNet3 engine before starting another stream."
        case .invalidSamples:
            return "DeepFilterNet3 received non-finite audio samples."
        case .streamingModelNotLoaded:
            return "DeepFilterNet3-Streaming.mlpackage or .mlmodelc was not found in the selected model directory"
        case .streamingPredictionOutputMissing:
            return "CoreML streaming prediction did not return mask, coefficients, and recurrent state"
        case .streamingStateMissing:
            return "CoreML streaming recurrent state was not initialized"
        case .streamingInputShapeMismatch:
            return "CoreML streaming input shape does not match the converted model"
        case .invalidHopSize(let expected, let actual):
            return "CoreML streaming requires \(expected) samples per hop; received \(actual)"
        case .fftSetupFailed:
            return "Failed to create vDSP DFT setup for FFT"
        }
    }
}
