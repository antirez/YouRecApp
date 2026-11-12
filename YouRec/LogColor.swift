@preconcurrency import AVFoundation
import CoreImage
import simd

enum CaptureColorMode: String, CaseIterable, Identifiable {
    case sdr, hdr, log
    var id: String { rawValue }
    var title: String { rawValue == "log" ? "Log" : rawValue.uppercased() }
}

/// Thumbnails use the same monitoring transform as the editor. Keep decoding
/// and GPU work off the main actor, and reuse a reader for a timeline strip.
actor LogThumbnailSource {
    private let reader: VideoEffectSourceReader
    private let transform: CGAffineTransform
    private let context = CIContext(options: [.cacheIntermediates: false])
    private init(url: URL, transform: CGAffineTransform) throws {
        reader = try VideoEffectSourceReader(url: url, hdr: false, capacity: 2)
        // Track transforms use top-left coordinates; Core Image uses bottom-left.
        let flip = CGAffineTransform(scaleX: 1, y: -1)
        self.transform = flip.concatenating(transform).concatenating(flip)
    }
    static func make(url: URL) async throws -> LogThumbnailSource? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first,
              try await track.load(.formatDescriptions).contains(where: { LogColor.profile($0) != nil }) else { return nil }
        let transform = try await track.load(.preferredTransform)
        return try await Task.detached(priority: .utility) { try LogThumbnailSource(url: url, transform: transform) }.value
    }
    func image(at time: Double, maximumSize: CGSize) throws -> CGImage {
        let upright = LogColor.display(try reader.frame(at: time)).transformed(by: transform)
        let scale = min(1, maximumSize.width / upright.extent.width, maximumSize.height / upright.extent.height)
        let small = upright.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let image = context.createCGImage(small, from: small.extent) else { throw ProjectError.invalidMedia }
        return image
    }
}

/// Explicit Apple Log color management. Core Image has no public Apple Log
/// CGColorSpace. Read unmanaged code values, decode the specified camera curve,
/// then transform its actual primaries into linear Rec.709 working RGB.
/// Profile constants: Apple Log Profile (2023), Apple Log 2 Profile (2025),
/// cross-checked against ASWF OpenColorIO's Apple camera reference transforms.
enum LogColor {
    static func profile(_ pixel: CVPixelBuffer) -> LUTInput? {
        if #available(iOS 17.2, macOS 14.2, *) {
            guard let name = CVBufferCopyAttachment(pixel, kCVImageBufferLogTransferFunctionKey, nil) as? String else { return nil }
            if #available(iOS 26, macOS 26, *), name == kCVImageBufferLogTransferFunction_AppleLog2 as String { return .appleLog2 }
            if name == kCVImageBufferLogTransferFunction_AppleLog as String { return .appleLog }
        }
        return nil
    }
    static func profile(_ format: CMFormatDescription) -> LUTInput? {
        if #available(iOS 17.2, macOS 14.2, *) {
            guard let name = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_LogTransferFunction) as? String else { return nil }
            if #available(iOS 26, macOS 26, *), name == kCVImageBufferLogTransferFunction_AppleLog2 as String { return .appleLog2 }
            if name == kCVImageBufferLogTransferFunction_AppleLog as String { return .appleLog }
        }
        return nil
    }
    static func decodeValue(_ x: Double) -> Double {
        x >= 47.28711236 * pow(0.01 + 0.05641088, 2)
            ? pow(2, (x - 0.69336945) / 0.08550479) - 0.00964052 : sqrt(max(0, x) / 47.28711236) - 0.05641088
    }
    static func encodeValue(_ x: Double) -> Double {
        x >= 0.01 ? log2(x + 0.00964052) * 0.08550479 + 0.69336945 : 47.28711236 * pow(max(0, x + 0.05641088), 2)
    }
    private static let decodeKernel = CIColorKernel(source: """
    kernel vec4 decodeAppleLog(__sample p) {
        vec3 lo = sqrt(max(p.rgb, vec3(0.0)) / 47.28711236) - 0.05641088;
        vec3 hi = exp2((p.rgb - 0.69336945) / 0.08550479) - 0.00964052;
        return vec4(mix(lo, hi, step(vec3(0.20855531595), p.rgb)), p.a);
    }
    """
    )!
    private static let encodeKernel = CIColorKernel(source: """
    kernel vec4 encodeAppleLog(__sample p) {
        vec3 t = max(p.rgb + 0.05641088, vec3(0.0));
        vec3 lo = 47.28711236 * t * t;
        vec3 hi = log2(max(p.rgb + 0.00964052, vec3(0.00000001))) * 0.08550479 + 0.69336945;
        return vec4(mix(lo, hi, step(vec3(0.01), p.rgb)), p.a);
    }
    """
    )!
    // Original SDR viewing transform. Scene middle-gray stays at 0.18 and the
    // toe remains linear. A rational shoulder retains separation several stops
    // above white; the former exponential shoulder flattened these highlights
    // to the same output code. This is viewing only; capture never bakes it.
    private static let displayKernel = CIColorKernel(source: """
    kernel vec4 logDisplay(__sample p) {
        float y = max(0.0, dot(p.rgb, vec3(0.2126, 0.7152, 0.0722)));
        float excess = max(0.0, y - 0.6);
        float mapped = y <= 0.6 ? y : 0.6 + 0.4 * excess / (excess + 0.4);
        vec3 rgb = p.rgb * (y > 0.000001 ? mapped / y : 1.0);
        // Fit out-of-gamut highlights toward neutral at the same luminance,
        // rather than independently clipping channels and changing their hue.
        vec3 chroma = rgb - vec3(mapped);
        float hi = max(chroma.r, max(chroma.g, chroma.b));
        float lo = min(chroma.r, min(chroma.g, chroma.b));
        float fit = min(1.0, min((1.0 - mapped) / max(hi, 0.000001), mapped / max(-lo, 0.000001)));
        rgb = vec3(mapped) + chroma * fit;
        return vec4(clamp(rgb, 0.0, 1.0), p.a);
    }
    """
    )!
    // Scene-linear selective correction, BEFORE display conversion or any LUT.
    // The log shoulder has unit slope at its knee and is strictly monotonic:
    // no inversion, spatial halos or per-frame exposure pumping. Values at/below
    // 0.35 are unchanged; only bright tones are compressed/expanded. Zero is an
    // exact bypass. Negative amounts recover highlights; positive amounts lift.
    private static let highlightsKernel = CIColorKernel(source: """
    kernel vec4 selectiveHighlights(__sample p, float amount) {
        float y = max(0.0, dot(p.rgb, vec3(0.2126, 0.7152, 0.0722)));
        float delta = max(0.0, y - 0.35);
        float strength = max(0.000001, -amount * 6.0);
        float down = log(1.0 + strength * delta) / strength;
        float up = delta * (1.0 + 2.0 * amount * delta / (delta + 0.35));
        float mapped = y <= 0.35 ? y : 0.35 + (amount < 0.0 ? down : up);
        return vec4(p.rgb * (y > 0.000001 ? mapped / y : 1.0), p.a);
    }
    """
    )!
    static func highlights(_ scene: CIImage, amount: Double) -> CIImage {
        guard amount.isFinite, amount != 0 else { return scene }
        return highlightsKernel.apply(extent: scene.extent, arguments: [scene, max(-1, min(1, amount))])!
    }
    // Local natural: guided-filter log luminance into illumination and detail.
    // Compress bright illumination, retain detail without sharpening, and return
    // SCENE-LINEAR RGB. The inverse viewing shoulder below makes our ordinary
    // display transform reproduce the study's result; an imported Log LUT still
    // receives scene values encoded in its declared profile, never SDR pixels.
    // Original implementation. Reference experiment: log-wall-recovery-20261102.md.
    private static let localMoments = CIColorKernel(source: """
    kernel vec4 localMoments(__sample p) {
        float l = log2(max(0.000001, dot(p.rgb, vec3(0.2126, 0.7152, 0.0722))));
        return vec4(l, l * l, 0.0, 1.0);
    }
    """)!
    private static let localCoefficients = CIColorKernel(source: """
    kernel vec4 localCoefficients(__sample m) {
        float variance = max(0.0, m.g - m.r * m.r);
        float a = variance / (variance + 0.12);
        return vec4(a, m.r * (1.0 - a), 0.0, 1.0);
    }
    """)!
    private static let localReconstruct = CIColorKernel(source: """
    kernel vec4 localReconstruct(__sample p, __sample coefficients, float strength) {
        float y = max(0.000001, dot(p.rgb, vec3(0.2126, 0.7152, 0.0722)));
        float l = log2(y);
        float baseLog = coefficients.r * l + coefficients.g;
        float base = exp2(baseLog);
        float adjusted = base <= 0.35 ? base : 0.35 + log(1.0 + 12.0 * (base - 0.35)) / 12.0;
        float excess = max(0.0, adjusted - 0.6);
        float mappedBase = adjusted <= 0.6 ? adjusted : 0.6 + 0.4 * excess / (excess + 0.4);
        float local = mappedBase * exp2(l - baseLog);
        float spike = max(0.0, local - 0.9);
        local = local <= 0.9 ? local : 0.9 + 0.1 * spike / (spike + 0.1);
        float originalExcess = max(0.0, y - 0.6);
        float original = y <= 0.6 ? y : 0.6 + 0.4 * originalExcess / (originalExcess + 0.4);
        float target = mix(original, local, strength);
        // Invert only the scalar shoulder, preserving source chroma/headroom.
        // Gamut fitting belongs to the chosen technical display transform.
        float sceneY = target <= 0.6 ? target : 0.6 + 0.4 * (target - 0.6) / max(0.000001, 1.0 - target);
        return vec4(p.rgb * (sceneY / y), p.a);
    }
    """)!
    static func localRecovery(_ scene: CIImage, amount: Double) -> CIImage {
        guard amount.isFinite, amount > 0, !scene.extent.isEmpty, !scene.extent.isInfinite else { return scene }
        let extent = scene.extent
        // Same physical neighborhood at proxy and export resolutions. All
        // passes remain in Core Image's GPU graph; no CPU readback or history.
        let radius = max(1, (60 * min(extent.width, extent.height) / 1080).rounded())
        func mean(_ image: CIImage) -> CIImage {
            // CIBoxBlur's effective box width is inputRadius (verified against
            // a CPU box mean), so a ±radius neighborhood needs 2r + 1 here.
            image.clampedToExtent().applyingFilter("CIBoxBlur", parameters: [kCIInputRadiusKey: 2 * radius + 1]).cropped(to: extent)
        }
        let moments = localMoments.apply(extent: extent, arguments: [scene])!
        let coefficients = localCoefficients.apply(extent: extent, arguments: [mean(moments)])!
        return localReconstruct.apply(extent: extent, arguments: [scene, mean(coefficients), min(1, amount)])!
    }
    private static func xyz(_ r: SIMD2<Double>, _ g: SIMD2<Double>, _ b: SIMD2<Double>) -> simd_double3x3 {
        func column(_ p: SIMD2<Double>) -> SIMD3<Double> { SIMD3(p.x / p.y, 1, (1 - p.x - p.y) / p.y) }
        let matrix = simd_double3x3(columns: (column(r), column(g), column(b)))
        let white = SIMD3<Double>(0.3127 / 0.3290, 1, (1 - 0.3127 - 0.3290) / 0.3290)
        return matrix * simd_double3x3(diagonal: matrix.inverse * white)
    }
    private static let rec709 = xyz(SIMD2(0.64, 0.33), SIMD2(0.30, 0.60), SIMD2(0.15, 0.06))
    private static let bt2020 = xyz(SIMD2(0.708, 0.292), SIMD2(0.170, 0.797), SIMD2(0.131, 0.046))
    private static let apple = xyz(SIMD2(0.725, 0.301), SIMD2(0.221, 0.814), SIMD2(0.068, -0.076))
    static func matrix(_ profile: LUTInput) -> simd_double3x3 { rec709.inverse * (profile == .appleLog2 ? apple : bt2020) }
    private static func transform(_ image: CIImage, _ matrix: simd_double3x3) -> CIImage {
        func row(_ n: Int) -> CIVector { CIVector(x: matrix[0][n], y: matrix[1][n], z: matrix[2][n], w: 0) }
        return image.applyingFilter("CIColorMatrix", parameters: ["inputRVector": row(0), "inputGVector": row(1), "inputBVector": row(2)])
    }
    static func decode(_ codes: CIImage, profile: LUTInput) -> CIImage {
        transform(decodeKernel.apply(extent: codes.extent, arguments: [codes])!, matrix(profile))
    }
    static func encode(_ scene: CIImage, profile: LUTInput) -> CIImage {
        let rgb = transform(scene, matrix(profile).inverse)
        return encodeKernel.apply(extent: rgb.extent, arguments: [rgb])!
    }
    static func display(_ scene: CIImage) -> CIImage { displayKernel.apply(extent: scene.extent, arguments: [scene])! }
    static func image(_ pixel: CVPixelBuffer, displayReferred: Bool = false) -> CIImage {
        guard let profile = profile(pixel) else { return CIImage(cvPixelBuffer: pixel) }
        let codes = CIImage(cvPixelBuffer: pixel, options: [.colorSpace: NSNull()])
        let scene = decode(codes, profile: profile)
        return displayReferred ? display(scene) : scene
    }
    static func tag(_ pixel: CVPixelBuffer, profile: LUTInput) {
        if #available(iOS 17.2, macOS 14.2, *) {
            var name = kCVImageBufferLogTransferFunction_AppleLog
            if #available(iOS 26, macOS 26, *), profile == .appleLog2 { name = kCVImageBufferLogTransferFunction_AppleLog2 }
            CVBufferSetAttachment(pixel, kCVImageBufferLogTransferFunctionKey, name, .shouldPropagate)
            CVBufferRemoveAttachment(pixel, kCVImageBufferCGColorSpaceKey)
            CVBufferRemoveAttachment(pixel, kCVImageBufferTransferFunctionKey)
            if profile == .appleLog2 { CVBufferRemoveAttachment(pixel, kCVImageBufferColorPrimariesKey) }
            else { CVBufferSetAttachment(pixel, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate) }
            CVBufferSetAttachment(pixel, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        }
    }
}
