import CoreImage
import CoreText
import Foundation

/// Core Text shapes the complete string before either color or outline is applied.
final class StyledTextLayout {
    let design: TitleDesign
    let frame: CTFrame
    let bounds: CGRect
    let fontSize: CGFloat
    let length: Int
    private let inset: CGFloat
    private static let ci = CIContext(options: [.cacheIntermediates: false])

    init(text: String, design: TitleDesign, fontSize: CGFloat, maxWidth: CGFloat, folder: URL? = nil) {
        self.design = design
        self.fontSize = fontSize
        let font = TitleTypeface.font(design, size: fontSize, folder: folder)
        var alignment: CTTextAlignment = design.alignment == .left ? .left : design.alignment == .right ? .right : .center
        var extra = design.lineSpacing * fontSize
        let paragraph = withUnsafePointer(to: &alignment) { a in
            withUnsafePointer(to: &extra) { gap in
                let options = [
                    CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: a),
                    CTParagraphStyleSetting(spec: .lineSpacingAdjustment, valueSize: MemoryLayout<CGFloat>.size, value: gap),
                ]
                return CTParagraphStyleCreate(options, options.count)
            }
        }
        let string = NSAttributedString(
            string: text,
            attributes: [
                .init(kCTFontAttributeName as String): font,
                .init(kCTKernAttributeName as String): design.tracking * fontSize,
                .init(kCTForegroundColorFromContextAttributeName as String): true,
                .init(kCTParagraphStyleAttributeName as String): paragraph,
            ])
        length = string.length
        let effectPad =
            (design.outlined ? design.borderWidth : 0)
            + (design.shadow ? 2 * design.shadowBlur + abs(design.shadowOffset) : 0)
        inset = ceil(fontSize * (max(effectPad, design.plate == .off ? 0 : design.padding) + 0.14)) + 2
        let setter = CTFramesetterCreateWithAttributedString(string)
        let measure = CTFramesetterSuggestFrameSizeWithConstraints(
            setter, CFRange(), nil,
            CGSize(width: max(fontSize, maxWidth - 2 * inset), height: 1_000_000), nil)
        let width = ceil(max(fontSize, measure.width)) + 2
        let height = ceil(max(fontSize, measure.height)) + 2
        bounds = CGRect(x: 0, y: 0, width: width + 2 * inset, height: height + 2 * inset)
        frame = CTFramesetterCreateFrame(
            setter, CFRange(), CGPath(rect: CGRect(x: inset, y: inset, width: width, height: height), transform: nil), nil)
    }

    func image(scale: CGFloat, paint: TitleDesign? = nil) -> CGImage? {
        let design = paint ?? self.design
        guard scale.isFinite, scale > 0 else { return nil }
        let w = ceil(bounds.width * scale)
        let h = ceil(bounds.height * scale)
        guard w <= 16384, h <= 16384, w * h <= 32_000_000 else { return nil }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        func bitmap() -> CGContext? {
            CGContext(
                data: nil, width: Int(w), height: Int(h), bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        guard let letters = bitmap(), let context = bitmap() else { return nil }
        letters.scaleBy(x: scale, y: scale)
        letters.setFillColor(TitleInk.white.cg)
        CTFrameDraw(frame, letters)
        guard let mask = letters.makeImage() else { return nil }
        let pixels = CGRect(x: 0, y: 0, width: w, height: h)
        context.scaleBy(x: scale, y: scale)
        if design.plate != .off {
            let pad = design.padding * fontSize
            let radius = design.radius * fontSize
            context.setFillColor(design.backing.cg)
            func plate(_ box: CGRect) {
                let r = min(radius, min(box.width, box.height) / 2)
                context.addPath(CGPath(roundedRect: box, cornerWidth: r, cornerHeight: r, transform: nil))
            }
            if design.plate == .block {
                plate(bounds.insetBy(dx: inset - pad, dy: inset - pad))
            } else {
                let lines = CTFrameGetLines(frame) as! [CTLine]
                var origins = [CGPoint](repeating: .zero, count: lines.count)
                if !lines.isEmpty { CTFrameGetLineOrigins(frame, CFRange(), &origins) }
                for (line, point) in zip(lines, origins) {
                    var ascent: CGFloat = 0
                    var descent: CGFloat = 0
                    let width =
                        CTLineGetTypographicBounds(line, &ascent, &descent, nil) - CTLineGetTrailingWhitespaceWidth(line)
                    if width > 0 {
                        plate(
                            CGRect(
                                x: inset + point.x - pad, y: inset + point.y - descent - pad, width: width + 2 * pad,
                                height: ascent + descent + 2 * pad))
                    }
                }
            }
            context.fillPath()
        }
        // All subsequent geometry is in output pixels. One shadow is cast by
        // the finished lettering, independently of the background plate.
        context.scaleBy(x: 1 / scale, y: 1 / scale)
        if design.shadow {
            context.setShadow(
                offset: CGSize(width: 0, height: -design.shadowOffset * fontSize * scale),
                blur: design.shadowBlur * fontSize * scale, color: design.shade.cg)
        }
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        if design.outlined && design.borderWidth > 0 {
            let glyph = CIImage(cgImage: mask)
            let expanded = glyph.applyingFilter(
                "CIMorphologyMaximum", parameters: [kCIInputRadiusKey: design.borderWidth * fontSize * scale])
            let outside = expanded.applyingFilter("CISourceOutCompositing", parameters: [kCIInputBackgroundImageKey: glyph])
            if let ring = Self.ci.createCGImage(outside, from: pixels) {
                context.saveGState()
                context.clip(to: pixels, mask: ring)
                context.setFillColor(design.border.cg)
                context.fill(pixels)
                context.restoreGState()
            }
        }
        context.clip(to: pixels, mask: mask)
        if let gradient = design.gradient,
            let paint = CGGradient(
                colorsSpace: space, colors: [gradient.first.cg, gradient.last.cg] as CFArray, locations: [0, 1])
        {
            let ink = pixels.insetBy(dx: inset * scale, dy: inset * scale)
            let (a, b) = gradient.axis(in: ink.size)
            context.drawLinearGradient(
                paint, start: CGPoint(x: ink.minX + a.x, y: ink.maxY - a.y),
                end: CGPoint(x: ink.minX + b.x, y: ink.maxY - b.y),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        } else {
            context.setFillColor(design.fill.cg)
            context.fill(pixels)
        }
        context.endTransparencyLayer()
        return context.makeImage()
    }
}

extension TextOverlay {
    func drawFrame(_ bitmap: CGImage, canvas: CGSize, time: Double, range: ClosedRange<Double>) -> SubtitleLayout.Frame? {
        let size = CGSize(width: bitmap.width, height: bitmap.height)
        let origin = TextRasterizer.origin(self, imageSize: size, canvas: canvas)
        let rect = CGRect(
            x: origin.x / canvas.width, y: 1 - (origin.y + size.height) / canvas.height, width: size.width / canvas.width,
            height: size.height / canvas.height)
        return SubtitleLayout.Frame(image: bitmap, rect: rect).animated(
            motion, elapsed: time - range.lowerBound, duration: range.upperBound - range.lowerBound, canvas: canvas)
    }
}
