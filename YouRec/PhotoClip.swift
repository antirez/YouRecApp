import AVFoundation
import ImageIO

/// A self-contained, silent timeline source. Decode the still once and reuse
/// its pixels at normal video cadence so frame-accurate edits and exports work.
enum PhotoClip {
    static let seconds = 3

    static func write(from source: URL, to destination: URL) async throws {
        try Task.checkCancellation()
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 3840
        ]
        guard let data = CGImageSourceCreateWithURL(source as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(data, 0, options as CFDictionary) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let width = max(2, (image.width + 1) / 2 * 2)
        let height = max(2, (image.height + 1) / 2 * 2)
        let color: [String: String] = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        let settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width,
                                       AVVideoHeightKey: height, AVVideoColorPropertiesKey: color]
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        var complete = false
        defer {
            if !complete {
                if writer.status == .writing { writer.cancelWriting() }
                try? FileManager.default.removeItem(at: destination)
            }
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height
        ])
        guard writer.canAdd(input) else { throw ProjectError.invalidMedia }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ProjectError.invalidMedia }
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        guard let pool = adaptor.pixelBufferPool,
              CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { throw ProjectError.invalidMedia }
        try draw(image, into: buffer)
        let fps: Int32 = 30
        for frame in 0..<(seconds * Int(fps)) {
            try Task.checkCancellation()
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else { throw writer.error ?? ProjectError.invalidMedia }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: fps)) else {
                throw writer.error ?? ProjectError.invalidMedia
            }
        }
        writer.endSession(atSourceTime: CMTime(value: Int64(seconds), timescale: 1))
        input.markAsFinished()
        await writer.finishWriting()
        try Task.checkCancellation()
        guard writer.status == .completed else { throw writer.error ?? ProjectError.invalidMedia }
        complete = true
    }

    private static func draw(_ image: CGImage, into buffer: CVPixelBuffer) throws {
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { throw ProjectError.invalidMedia }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard let space = CGColorSpace(name: CGColorSpace.itur_709),
              let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space,
                                      bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)
        else { throw ProjectError.invalidMedia }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
}
