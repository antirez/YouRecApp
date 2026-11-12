import CoreImage
import CoreText
import Foundation

/// Layout in a canonical video canvas, independent of preview resolution. Line
/// breaks stay fixed while resizing; even the longest caption must fit in full.
/// Measure once per transcript/font/style, never on each drag or playback frame.
final class SubtitleLayout {
    static let referenceSize = 0.052
    let canvas: CGSize
    let cues: [SubtitleCue]
    let largest: CGSize
    let maximumSize: Double
    var minimumSize: Double { min(0.012, maximumSize) }
    private let types: [String: CaptionType]
    private let images = NSCache<NSString, CGImage>()
    private let paintLock = NSLock()
    private var lastPaint: TitleDesign?
    private let gap: CGFloat = 12

    init(cues: [SubtitleCue], settings: SubtitleSettings, canvas input: CGSize, folder: URL? = nil) {
        let factor = 1080 / max(1, min(input.width, input.height))
        canvas = CGSize(width: max(1, input.width * factor), height: max(1, input.height * factor))
        self.cues = cues
        var types: [String: CaptionType] = [:]
        for cue in cues where types[cue.text] == nil {
            types[cue.text] = CaptionType(text: cue.text, settings: settings, canvas: canvas, folder: folder)
        }
        self.types = types
        // Two simultaneous speech tracks are rendered as a single centered stack.
        // Include their combined bounds, not just the largest individual caption.
        var width: CGFloat = 1, height: CGFloat = 1
        var active: Set<Int> = []
        let events = cues.indices.flatMap { [(cues[$0].start, true, $0), (cues[$0].end, false, $0)] }
            .sorted { $0.0 == $1.0 ? (!$0.1 && $1.1) : $0.0 < $1.0 }
        for (_, starting, index) in events {
            if starting { active.insert(index) } else { active.remove(index) }
            let bounds = active.sorted().prefix(2).compactMap { types[cues[$0].text]?.bounds.size }
            width = max(width, bounds.map(\.width).max() ?? 0)
            height = max(height, bounds.reduce(0) { $0 + $1.height } + (bounds.count > 1 ? gap : 0))
        }
        if let motion = settings.motion {
            if motion.exit == .scale { width *= 1.08; height *= 1.08 }
            let drift = [(motion.entrance, motion.inDirection), (motion.exit, motion.outDirection)]
                .filter { $0.0 == .drift }.map { $0.1 ?? .up }
            let margin = height * 0.64
            if drift.contains(.left) || drift.contains(.right) { width += margin }
            if drift.contains(.up) || drift.contains(.down) { height += margin }
        }
        largest = CGSize(width: width, height: height)
        maximumSize = max(0.0001, min(0.30, Self.referenceSize * min(canvas.width * 0.94 / width, canvas.height * 0.94 / height)))
        images.countLimit = 16; images.totalCostLimit = 24 * 1024 * 1024
    }
    func constrained(_ value: SubtitleSettings) -> SubtitleSettings {
        var result = value
        result.size = min(maximumSize, max(minimumSize, value.size))
        let scale = result.size / Self.referenceSize
        let halfW = largest.width * scale / canvas.width / 2 + 0.025
        let halfH = largest.height * scale / canvas.height / 2 + 0.025
        result.x = min(1 - halfW, max(halfW, value.centerX))
        result.y = min(1 - halfH, max(halfH, value.y))
        return result
    }
    /// Normalized, top-left coordinates. This is the gesture boundary and guide,
    /// including every phrase in the project, even outside the selected range.
    func envelope(_ value: SubtitleSettings) -> CGRect {
        let value = constrained(value), scale = value.size / Self.referenceSize
        let w = largest.width * scale / canvas.width, h = largest.height * scale / canvas.height
        return CGRect(x: value.centerX - w / 2, y: value.y - h / 2, width: w, height: h)
    }
    struct Frame {
        let image: CGImage
        var opacity = 1.0
        let rect: CGRect // Normalized, top-left coordinates, as in the editor.
        func animated(_ motion: TitleMotion?, elapsed: Double, duration: Double, canvas: CGSize) -> Self? {
            guard let motion, motion.active else { return self }
            let pose = motion.pose(at: elapsed, duration: duration)
            guard let visible = pose.crop(image) else { return nil }
            // Apply motion in square pixels so horizontal and vertical drift travel the same distance.
            let pixels = CGAffineTransform(scaleX: canvas.width, y: canvas.height)
            let moved = pose.rect(rect.applying(pixels)).applying(pixels.inverted())
            return Self(image: visible, opacity: pose.opacity, rect: moved)
        }
        func composite(over background: CIImage, canvas: CGSize, displayBlend: Bool) -> CIImage {
            guard opacity > 0 else { return background }
            let width = rect.width * canvas.width, height = rect.height * canvas.height
            let picture = CIImage(cgImage:image)
                .transformed(by:CGAffineTransform(scaleX:width/CGFloat(image.width),y:height/CGFloat(image.height)))
                .transformed(by:CGAffineTransform(translationX:rect.minX*canvas.width,y:(1-rect.maxY)*canvas.height))
            return opacity == 1 && !displayBlend ? picture.composited(over:background) : ImageOverlayRenderer.composite(picture,opacity:opacity,over:background)
        }
    }
    func frames(at time: Double, settings value: SubtitleSettings, output: CGSize) -> [Frame] {
        // A replacement preview item can render the same layout while the outgoing item drains.
        paintLock.lock(); defer { paintLock.unlock() }
        let settings = constrained(value), scale = settings.size / Self.referenceSize
        if lastPaint != settings.appearance { images.removeAllObjects(); lastPaint = settings.appearance }
        let active = cues.filter { $0.start <= time && time < $0.end }.prefix(2)
        let height = active.reduce(CGFloat(0)) { $0 + (types[$1.text]?.bounds.height ?? 0) } + (active.count > 1 ? gap : 0)
        var top = settings.y - height * scale / canvas.height / 2
        var result: [Frame] = []
        for cue in active {
            guard let type = types[cue.text] else { continue }
            let key = "\(cue.text)|\(settings.size)|\(settings.color.rawValue)|\(output.width)x\(output.height)" as NSString
            let bitmap: CGImage
            if let saved = images.object(forKey: key) { bitmap = saved }
            else {
                guard let rendered = type.image(scale: scale * output.width / canvas.width, color: settings.color, paint: settings.appearance) else { continue }
                images.setObject(rendered, forKey: key, cost: rendered.bytesPerRow * rendered.height); bitmap = rendered
            }
            // Bitmap rounding is contained in the 0.5% safety reserve.
            let w = Double(bitmap.width) / output.width, h = Double(bitmap.height) / output.height
            let frame = Frame(image: bitmap, rect: CGRect(x: settings.centerX - w / 2, y: top, width: w, height: h))
            if let visible = frame.animated(settings.motion, elapsed: time-cue.start, duration: cue.end-cue.start, canvas: output) { result.append(visible) }
            top += (type.bounds.height + gap) * scale / canvas.height
        }
        return result
    }
    // Used by layout tests: a caption must never silently truncate in Core Text.
    var containsEveryCharacter: Bool { types.values.allSatisfy { CTFrameGetVisibleStringRange($0.frame).length == $0.length } }
}

private struct CaptionType {
    private var styled: StyledTextLayout?
    let frame: CTFrame
    let bounds: CGRect
    let fontSize: CGFloat
    let style: TextStyle
    let length: Int
    init(text: String, settings: SubtitleSettings, canvas: CGSize, folder: URL?) {
        style = settings.style
        let fontSize = min(canvas.width, canvas.height) * SubtitleLayout.referenceSize
        self.fontSize = fontSize
        if let design = settings.appearance {
            let layout = StyledTextLayout(text:text,design:design,fontSize:fontSize,maxWidth:canvas.width*0.84,folder:folder)
            styled = layout; length = layout.length; bounds = layout.bounds; frame = layout.frame
            return
        }
        let regular = settings.resolvedFont.postScriptName(bold: style != .clean).map { CTFontCreateWithName($0 as CFString, fontSize, nil) }
            ?? CTFontCreateUIFontForLanguage(.system, fontSize, nil)!
        let font = style == .clean ? regular : CTFontCreateCopyWithSymbolicTraits(regular, fontSize, nil, .boldTrait, .boldTrait) ?? regular
        var alignment = CTTextAlignment.center
        let paragraph = withUnsafePointer(to: &alignment) { pointer in
            var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: pointer)
            return CTParagraphStyleCreate(&setting, 1)
        }
        let string = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph
        ])
        length = string.length
        let setter = CTFramesetterCreateWithAttributedString(string), padding = fontSize * 0.35
        let fitting = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil,
            CGSize(width: canvas.width * 0.84 - padding * 2, height: 1_000_000), nil)
        bounds = CGRect(x: 0, y: 0, width: ceil(max(fontSize, fitting.width)) + padding * 2 + 2, height: ceil(fitting.height) + padding * 2 + 2)
        frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: bounds.insetBy(dx: padding, dy: padding), transform: nil), nil)
    }
    func image(scale: CGFloat, color: TextColor, paint: TitleDesign?) -> CGImage? {
        if let styled { return styled.image(scale:scale,paint:paint) }
        let width = max(1, Int(ceil(bounds.width * scale))), height = max(1, Int(ceil(bounds.height * scale)))
        guard width <= 16384, height <= 16384,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        let (r, g, b) = color.rgb, ink = CGColor(srgbRed: r, green: g, blue: b, alpha: 1), padding = fontSize * 0.35
        if style == .box || style == .highlight {
            context.setFillColor(style == .box ? CGColor(gray: 0.02, alpha: 0.82) : ink)
            context.addPath(CGPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerWidth: padding * 0.7, cornerHeight: padding * 0.7, transform: nil)); context.fillPath()
        } else { context.setShadow(offset: CGSize(width: 0, height: -fontSize * 0.04), blur: fontSize * 0.12, color: CGColor(gray: 0, alpha: 0.9)) }
        context.setFillColor(style == .highlight ? CGColor(gray: 0.03, alpha: 1) : ink)
        CTFrameDraw(frame, context)
        return context.makeImage()
    }
}

/// Preview and export consume exactly the same caption layout and bitmaps.
final class SubtitleRenderTrack: @unchecked Sendable {
    private var cues: [SubtitleCue]
    private var settings: SubtitleSettings
    private let lock = NSLock()
    private var layout: SubtitleLayout?
    private var canvas = CGSize.zero
    private let folder: URL?
    init(cues: [SubtitleCue], settings: SubtitleSettings, folder: URL? = nil) { self.cues = cues; self.settings = settings; self.folder = folder }
    func updatePreview(layout: SubtitleLayout?, settings: SubtitleSettings, canvas: CGSize) {
        lock.withLock {
            self.cues = layout?.cues ?? []
            self.settings = settings
            self.layout = layout
            self.canvas = canvas
        }
    }
    func render(at time: Double, over background: CIImage, canvas: CGSize) -> CIImage {
        lock.lock(); defer { lock.unlock() }
        if self.canvas != canvas { self.canvas = canvas; layout = SubtitleLayout(cues: cues, settings: settings, canvas: canvas, folder: folder) }
        var image = background
        for frame in layout?.frames(at: time, settings: settings, output: canvas) ?? [] {
            image = frame.composite(over:image,canvas:canvas,displayBlend:settings.appearance != nil)
        }
        return image
    }
}
