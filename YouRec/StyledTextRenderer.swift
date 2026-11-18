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

/// Component rectangles use the top-left origin of the finished bitmap for hit testing.
struct LabelHeadlineLayout {
    struct Line {
        let text: StyledTextLayout
        let rect: CGRect
    }
    let label: Line?
    let headline: Line?
    let size: CGSize
    let card: TitleCard
    let fontSize: CGFloat

    init(_ group: LabelHeadline, headline words: String, fontSize: CGFloat, width: CGFloat, folder: URL?) {
        self.fontSize = fontSize
        card = group.card
        let pad = ceil(group.card.padding * fontSize)
        func layout(_ value: String, _ style: TitleDesign, _ relativeSize: Double) -> StyledTextLayout? {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return StyledTextLayout(text: value, design: style, fontSize: fontSize * relativeSize,
                                    maxWidth: max(1, width - 2 * pad), folder: folder)
        }
        let small = layout(group.label, group.labelStyle, group.labelScale)
        let large = layout(words, group.headlineStyle, group.headlineScale)
        let contentWidth = max(small?.bounds.width ?? 0, large?.bounds.width ?? 0)
        let gap = small != nil && large != nil ? ceil(group.card.spacing * fontSize) : 0
        let headlineTop = pad + (small?.bounds.height ?? 0) + gap
        let cardSize = CGSize(width: contentWidth + 2 * pad, height: headlineTop + (large?.bounds.height ?? 0) + pad)
        func place(_ line: StyledTextLayout?, y: CGFloat, offset: TitleCard.Offset?) -> Line? {
            guard let line else { return nil }
            let slack = contentWidth - line.bounds.width
            let x = pad + (line.design.alignment == .left ? 0 : line.design.alignment == .right ? slack : slack / 2)
            func travel(_ fraction: Double, from origin: CGFloat, within available: CGFloat) -> CGFloat {
                origin + fraction * (fraction < 0 ? origin : max(0, available - origin))
            }
            let dx = travel(offset?.x ?? 0, from: x, within: cardSize.width - line.bounds.width)
            let dy = travel(offset?.y ?? 0, from: y, within: cardSize.height - line.bounds.height)
            let rect = CGRect(origin: CGPoint(x: dx, y: dy), size: line.bounds.size)
            return Line(text: line, rect: rect)
        }
        label = place(small, y: pad, offset: group.card.labelOffset)
        headline = place(large, y: headlineTop, offset: group.card.headlineOffset)
        size = cardSize
    }

    func part(at fraction: CGPoint) -> LabelHeadline.Part {
        let point = CGPoint(x: fraction.x * size.width, y: fraction.y * size.height)
        if headline?.rect.contains(point) == true { return .headline }
        if label?.rect.contains(point) == true { return .label }
        return .card
    }

    func image(fitting canvas: CGSize) -> CGImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, canvas.width / size.width, canvas.height / size.height)
        let w = ceil(size.width * scale), h = ceil(size.height * scale)
        guard w > 0, h > 0, w <= 16384, h <= 16384, w * h <= 32_000_000,
              let context = CGContext(data: nil, width: Int(w), height: Int(h), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        let bounds = CGRect(origin: .zero, size: size)
        let radius = min(card.radius * fontSize, min(size.width, size.height) / 2)
        context.setFillColor(card.fill.cg)
        context.addPath(CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
        let stroke = min(card.borderWidth * fontSize, min(size.width, size.height))
        if stroke > 0 {
            let inset = stroke / 2
            let r = max(0, radius - inset)
            context.setStrokeColor(card.border.cg)
            context.setLineWidth(stroke)
            context.addPath(CGPath(roundedRect: bounds.insetBy(dx: inset, dy: inset), cornerWidth: r, cornerHeight: r, transform: nil))
            context.strokePath()
        }
        for line in [label, headline].compactMap({ $0 }) {
            guard let bitmap = line.text.image(scale: scale) else { return nil }
            let bounds = CGRect(x: line.rect.minX, y: size.height - line.rect.maxY, width: line.rect.width, height: line.rect.height)
            context.draw(bitmap, in: bounds)
        }
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
