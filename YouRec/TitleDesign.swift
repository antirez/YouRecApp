import CoreGraphics
import CoreText
import Foundation

/// Packed sRGB, in RRGGBBAA order. Stored values are independent of the display's color scheme.
struct TitleInk: Codable, Hashable, Sendable {
    var rgba: UInt32
    init(_ rgb: UInt32, alpha: UInt8 = 255) { rgba = (rgb << 8) | UInt32(alpha) }
    init(_ color: TextColor) {
        let (r, g, b) = color.rgb
        self.init(UInt32((r * 255).rounded()) << 16 | UInt32((g * 255).rounded()) << 8 | UInt32((b * 255).rounded()))
    }
    var rgb: UInt32 { rgba >> 8 }
    var alpha: Double { Double(rgba & 255) / 255 }
    var cg: CGColor {
        CGColor(
            srgbRed: CGFloat(rgba >> 24) / 255, green: CGFloat((rgba >> 16) & 255) / 255,
            blue: CGFloat((rgba >> 8) & 255) / 255, alpha: alpha)
    }
    static let white = TitleInk(0xffffff), black = TitleInk(0x000000)
}

struct TitleGradient: Codable, Equatable, Hashable, Sendable {
    var first: TitleInk
    var last: TitleInk
    /// Screen degrees: 0 left to right, 90 top to bottom.
    var angle: Double
    init(_ first: UInt32, _ last: UInt32, _ angle: Double) {
        self.first = TitleInk(first)
        self.last = TitleInk(last)
        self.angle = angle
    }
    static let gallery: [(name: String, value: Self)] = [
        ("Sunset", .init(0xfff0ba, 0xf58283, 105)), ("Golden hour", .init(0xfff5d6, 0xe4a044, 85)),
        ("Ember", .init(0xffcf74, 0xc84939, 30)), ("Rose", .init(0xffdae2, 0xba5486, 120)),
        ("Lavender", .init(0xeee0ff, 0x9a87dd, 95)), ("Midnight", .init(0x91aff1, 0x45417b, 45)),
        ("Glacier", .init(0xf6ffff, 0x50afcd, 100)), ("Lagoon", .init(0x72e7df, 0x386ab1, 20)),
        ("Sea glass", .init(0xe4fadb, 0x69b7a7, 130)), ("Olive", .init(0xf4e8aa, 0x829969, 70)),
        ("Silver", .init(0xffffff, 0x9ca9b8, 90)), ("Copper", .init(0xf0c6a5, 0xa36556, 145)),
    ]
    func axis(in size: CGSize) -> (CGPoint, CGPoint) {
        let a = angle * .pi / 180
        let x = cos(a)
        let y = sin(a)
        let half = (abs(x) * size.width + abs(y) * size.height) / 2
        return (
            CGPoint(x: size.width / 2 - x * half, y: size.height / 2 - y * half),
            CGPoint(x: size.width / 2 + x * half, y: size.height / 2 + y * half)
        )
    }
}

enum TitleAlignment: String, Codable, CaseIterable { case left, center, right }
enum TitlePlate: String, Codable, CaseIterable { case off, block, lines }

struct TitleDesign: Codable, Equatable, Hashable, Sendable {
    var face = "system"
    var weight = 700
    var italic = false
    var alignment = TitleAlignment.center
    var tracking = 0.0
    var lineSpacing = 0.0
    var fill = TitleInk.white
    var gradient: TitleGradient?
    var outlined = false
    var border = TitleInk.black
    var borderWidth = 0.045  // Thickness in em, outside the glyph.
    var shadow = true
    var shade = TitleInk(0x000000, alpha: 210)
    var shadowBlur = 0.12
    var shadowOffset = 0.05
    var plate = TitlePlate.off
    var backing = TitleInk(0x111218, alpha: 205)
    var padding = 0.28
    var radius = 0.14

    var layoutKey: Self {
        var key = self
        key.fill = .white
        key.gradient = nil
        key.border = .black
        key.shade = .black
        key.backing = .black
        return key
    }
    static func legacy(_ style: TextStyle, color: TextColor, font: SubtitleFont? = nil) -> Self {
        var d = TitleDesign()
        d.face = font?.postScriptName(bold: style != .clean) ?? "system"
        d.weight = style == .clean ? 400 : 700
        d.fill = style == .highlight ? .black : TitleInk(color)
        if style == .box || style == .highlight {
            d.shadow = false
            d.plate = .block
            d.backing = style == .highlight ? TitleInk(color) : TitleInk(0x050505, alpha: 209)
        }
        return d
    }
    /// Outline is a separate tool, including when switching between saved channel looks.
    func applyingLook(_ look: Self) -> Self {
        var next = look
        next.outlined = outlined
        next.border = border
        next.borderWidth = borderWidth
        return next
    }
    enum LookCollection: String, CaseIterable {
        case editorial = "Editorial", cinema = "Cinema", print = "Print", display = "Display"
    }

    static let looks: [(collection: LookCollection, name: String, design: Self)] = [
        (.editorial, "Clean", Self(face: "atkinsonhyperlegiblenext", weight: 600, lineSpacing: 0.04,
                                   shade: TitleInk(0x090B0D, alpha: 240), shadowBlur: 0.085, shadowOffset: 0.035)),
        (.editorial, "Field report", Self(face: "barlowcondensed", weight: 700, alignment: .left, tracking: 0.02, lineSpacing: 0.05,
                                          fill: TitleInk(0xF8F8F4), shadow: false, plate: .lines,
                                          backing: TitleInk(0x102335, alpha: 224), padding: 0.15, radius: 0)),
        (.editorial, "Dateline", Self(face: "ibmplexmono", weight: 500, alignment: .left, tracking: 0.025, lineSpacing: 0.06,
                                      fill: TitleInk(0xFFD79B), shade: TitleInk(0x21170F, alpha: 250), shadowBlur: 0.055, shadowOffset: 0.055)),
        (.editorial, "Caption box", Self(face: "atkinsonhyperlegiblenext", weight: 500, lineSpacing: 0.09,
                                         shadow: false, plate: .block, backing: TitleInk(0x111319, alpha: 168), padding: 0.24, radius: 0.24)),
        (.editorial, "Pull quote", Self(face: "sourceserif4", weight: 600, alignment: .left, tracking: -0.012, lineSpacing: 0.12,
                                        fill: TitleInk(0x27231F), shadow: false, plate: .block,
                                        backing: TitleInk(0xF4EFDF), padding: 0.31, radius: 0.025)),
        (.editorial, "Interview", Self(face: "system", weight: 600, alignment: .left, tracking: -0.01, lineSpacing: 0.06,
                                       fill: TitleInk(0x121D28), shadow: false, plate: .block,
                                       backing: TitleInk(0xEFF6FA, alpha: 166), padding: 0.26, radius: 0.14)),

        (.cinema, "Film title", Self(face: "sourceserif4", weight: 500, tracking: 0.035, lineSpacing: 0.10,
                                     fill: TitleInk(0xF9EFDC), shade: TitleInk(0x181519, alpha: 245), shadowBlur: 0.10, shadowOffset: 0.045)),
        (.cinema, "Opening credit", Self(face: "barlowcondensed", weight: 400, tracking: 0.075, lineSpacing: 0.16,
                                         fill: TitleInk(0xF4F6FA), shade: TitleInk(0x101720, alpha: 245), shadowBlur: 0.07, shadowOffset: 0.04)),
        (.cinema, "Intertitle", Self(face: "bodonimoda", weight: 600, tracking: 0.035, lineSpacing: 0.12,
                                     fill: TitleInk(0xF3E6CE), shadow: false, plate: .block,
                                     backing: TitleInk(0x19191A, alpha: 214), padding: 0.40, radius: 0.035)),
        (.cinema, "Daylight", Self(face: "bodonimoda", weight: 700, italic: true, tracking: -0.012, lineSpacing: 0.08,
                                   fill: TitleInk(0x28212A), shade: TitleInk(0xFFF9ED, alpha: 229), shadowBlur: 0.12, shadowOffset: 0)),
        (.cinema, "Night drive", Self(face: "unbounded", weight: 500, tracking: 0.065, lineSpacing: 0.12,
                                      fill: TitleInk(0xDEEDFF), gradient: TitleGradient(0xF4F8FC, 0xA9CDFA, 90),
                                      shade: TitleInk(0x192D50), shadowBlur: 0.07, shadowOffset: 0.035,
                                      plate: .block, backing: TitleInk(0x112238, alpha: 102), padding: 0.22, radius: 0.075)),
        (.cinema, "Matinée", Self(face: "barlowcondensed", weight: 700, italic: true, tracking: 0.02,
                                  fill: TitleInk(0xFFDAA8), shadow: false, plate: .lines,
                                  backing: TitleInk(0x531E27, alpha: 190), padding: 0.16, radius: 0.035)),

        (.print, "Headline", Self(face: "archivoblack", weight: 400, alignment: .left, tracking: -0.035,
                                  fill: TitleInk(0xFFFCF2), shade: TitleInk(0x151319), shadowBlur: 0.018, shadowOffset: 0.065)),
        (.print, "Magazine italic", Self(face: "fraunces", weight: 600, italic: true, tracking: -0.018, lineSpacing: 0.04,
                                         fill: TitleInk(0xFFE7DC), shade: TitleInk(0x352027, alpha: 245), shadowBlur: 0.09, shadowOffset: 0.04)),
        (.print, "Source note", Self(face: "ibmplexmono", weight: 400, alignment: .left, tracking: 0.015, lineSpacing: 0.12,
                                     fill: TitleInk(0x302822), shadow: false, plate: .lines,
                                     backing: TitleInk(0xF4E4C7, alpha: 181), padding: 0.16, radius: 0)),
        (.print, "Masthead", Self(face: "bodonimoda", weight: 800, alignment: .left, tracking: -0.04,
                                  fill: TitleInk(0x471628), shadow: false, plate: .block,
                                  backing: TitleInk(0xF7E9E9, alpha: 232), padding: 0.12, radius: 0)),
        (.print, "Clothbound", Self(face: "sourceserif4", weight: 500, tracking: 0.045, lineSpacing: 0.10,
                                    fill: TitleInk(0xF1E2B2), shadow: false, plate: .block,
                                    backing: TitleInk(0x183F34, alpha: 200), padding: 0.38, radius: 0.065)),
        (.print, "Field note", Self(face: "caveat", weight: 700, alignment: .left, lineSpacing: 0.06,
                                    fill: TitleInk(0xFFE379), shade: TitleInk(0x292018), shadowBlur: 0.095, shadowOffset: 0.045)),

        (.display, "Gaffer tape", Self(face: "caveat", weight: 700, alignment: .left, tracking: 0.025, lineSpacing: 0.06,
                                       fill: TitleInk(0x1A2025), shadow: false, plate: .lines,
                                       backing: TitleInk(0xF3F1E6, alpha: 186), padding: 0.14, radius: 0)),
        (.display, "Highlighter", Self(face: "atkinsonhyperlegiblenext", weight: 800, alignment: .left, tracking: -0.025, lineSpacing: 0.04,
                                       fill: TitleInk(0x142214), shadow: false, plate: .lines,
                                       backing: TitleInk(0xD9FA68), padding: 0.13, radius: 0.045)),
        (.display, "Afterglow", Self(face: "fraunces", weight: 800, tracking: -0.025, lineSpacing: 0.03,
                                     fill: TitleInk(0xFFF0AD), gradient: TitleGradient(0xFFF0AD, 0xFFA68E, 105),
                                     shade: TitleInk(0x462335, alpha: 245), shadowBlur: 0.08, shadowOffset: 0.055)),
        (.display, "Wide type", Self(face: "unbounded", weight: 800, alignment: .left, tracking: -0.03,
                                     fill: TitleInk(0xDDF4C9), shade: TitleInk(0x17362B), shadowBlur: 0.02, shadowOffset: 0.075)),
        (.display, "Flyer", Self(face: "archivoblack", weight: 400, tracking: -0.025, lineSpacing: 0.04,
                                 fill: TitleInk(0xFFFFF5), shadow: false, plate: .block,
                                 backing: TitleInk(0xAC2633, alpha: 226), padding: 0.22, radius: 0)),
        (.display, "Lilac gel", Self(face: "unbounded", weight: 600, tracking: -0.025, lineSpacing: 0.05,
                                     fill: TitleInk(0x261A40), shadow: false, plate: .block,
                                     backing: TitleInk(0xE8D9FF, alpha: 170), padding: 0.30, radius: 0.80)),
    ]

    var valid: Bool {
        !face.isEmpty && face.utf8.count <= 255 && (100...1000).contains(weight) && (-0.05...0.25).contains(tracking)
            && (0...0.8).contains(lineSpacing) && (0...0.20).contains(borderWidth) && (0...0.6).contains(shadowBlur)
            && (-0.5...0.5).contains(shadowOffset) && (0...0.8).contains(padding) && (0...0.8).contains(radius)
            && (0...360).contains(gradient?.angle ?? 0)
    }
}

/// Both lines share the overlay's anchor, size, timing and animation.
struct LabelHeadline: Codable, Equatable, Sendable {
    enum Part: String, CaseIterable { case label = "Label", headline = "Headline", card = "Card" }

    static let defaultHeadline = "Second text"
    var label = "First text"
    var labelStyle = TitleDesign(face: "system", weight: 700, alignment: .left, tracking: 0.09,
                                 fill: .black, shadow: false, plate: .block, backing: .white, padding: 0.32, radius: 0.27)
    var headlineStyle = TitleDesign(face: "archivoblack", weight: 400, alignment: .left, tracking: -0.045, shadow: false)
    var labelScale = 0.36
    var headlineScale = 1.0
    var card = TitleCard()

    var valid: Bool {
        label.count <= 500 && labelStyle.valid && headlineStyle.valid && card.valid
            && (0.2...1).contains(labelScale) && (0.5...1.8).contains(headlineScale)
    }
}

struct TitleCard: Codable, Equatable, Sendable {
    struct Offset: Codable, Equatable, Sendable {
        // Each axis is a fraction of the travel from the preset position to that edge.
        var x = 0.0, y = 0.0

        var valid: Bool { (-1...1).contains(x) && (-1...1).contains(y) }
    }

    var fill = TitleInk(0x08090B, alpha: 139)
    var border = TitleInk(0xFFFFFF, alpha: 72)
    // Dimensions are relative to the base headline size, so the whole design scales together.
    var borderWidth = 0.017
    var padding = 0.42
    var radius = 0.29
    var spacing = 0.08
    var labelOffset: Offset?
    var headlineOffset: Offset?

    var valid: Bool {
        (0...0.1).contains(borderWidth) && (0...1).contains(padding)
            && (0...1).contains(radius) && (0...1).contains(spacing)
            && labelOffset?.valid != false && headlineOffset?.valid != false
    }
}

extension LabelHeadline {
    /// A reusable look contains appearance only. Words and manual placement belong to the title.
    struct Look: Codable, Equatable, Sendable {
        var label, headline: TitleDesign
        var labelScale, headlineScale: Double
        var card: TitleCard
    }

    var look: Look {
        var frame = card
        frame.labelOffset = nil
        frame.headlineOffset = nil
        return Look(label: TitleDesign().applyingLook(labelStyle), headline: TitleDesign().applyingLook(headlineStyle),
                    labelScale: labelScale, headlineScale: headlineScale, card: frame)
    }

    func applyingLook(_ look: Look) -> Self {
        var result = self
        result.labelStyle = labelStyle.applyingLook(look.label)
        result.headlineStyle = headlineStyle.applyingLook(look.headline)
        result.labelScale = look.labelScale
        result.headlineScale = look.headlineScale
        result.card = look.card
        result.card.labelOffset = card.labelOffset
        result.card.headlineOffset = card.headlineOffset
        return result
    }

    static let looks: [(name: String, design: Look)] = {
        let broadcast = Look(
            label: TitleDesign(face: "barlowcondensed", weight: 700, alignment: .left, tracking: 0.08,
                               fill: TitleInk(0x111111), shadow: false, plate: .block, backing: TitleInk(0xFFD60A), padding: 0.20, radius: 0.06),
            headline: TitleDesign(face: "barlowcondensed", weight: 700, alignment: .left, shadow: false),
            labelScale: 0.44, headlineScale: 1.0,
            card: TitleCard(fill: TitleInk(0x0B0F14, alpha: 236), borderWidth: 0, padding: 0.36, radius: 0.08, spacing: 0.12))
        let editorial = Look(
            label: TitleDesign(face: "ibmplexmono", weight: 500, alignment: .left, tracking: 0.075, fill: TitleInk(0x962C26), shadow: false),
            headline: TitleDesign(face: "sourceserif4", weight: 600, alignment: .left, tracking: -0.01, fill: TitleInk(0x221D1A), shadow: false),
            labelScale: 0.42, headlineScale: 1.0,
            card: TitleCard(fill: TitleInk(0xF7F3EA, alpha: 246), border: TitleInk(0x51463C), borderWidth: 0.022, padding: 0.46, radius: 0.04, spacing: 0.12))
        let terminal = Look(
            label: TitleDesign(face: "ibmplexmono", weight: 500, alignment: .left, tracking: 0.06, fill: TitleInk(0x61E3A5), shadow: false),
            headline: TitleDesign(face: "ibmplexmono", weight: 700, alignment: .left, tracking: -0.025, fill: TitleInk(0xE6EDF3), shadow: false),
            labelScale: 0.41, headlineScale: 0.94,
            card: TitleCard(fill: TitleInk(0x0D1517, alpha: 240), border: TitleInk(0x61E3A5), borderWidth: 0.025, padding: 0.40, radius: 0.12, spacing: 0.12))
        let poster = Look(
            label: TitleDesign(face: "barlowcondensed", weight: 700, alignment: .left, tracking: 0.07, fill: .black,
                               shadow: false, plate: .block, backing: .white, padding: 0.18, radius: 0),
            headline: TitleDesign(face: "archivoblack", weight: 400, alignment: .left, tracking: -0.035,
                                  shadow: false, plate: .block, backing: TitleInk(0xB7251F), padding: 0.15, radius: 0),
            labelScale: 0.44, headlineScale: 1.0,
            card: TitleCard(fill: TitleInk(0, alpha: 0), borderWidth: 0, padding: 0.12, radius: 0, spacing: 0.03))
        let notebook = Look(
            label: TitleDesign(face: "caveat", weight: 700, alignment: .left, fill: TitleInk(0xFFE066), shadow: false),
            headline: TitleDesign(face: "fraunces", weight: 600, italic: true, alignment: .left, tracking: -0.01, shadow: false),
            labelScale: 0.62, headlineScale: 1.0,
            card: TitleCard(fill: TitleInk(0x14213D, alpha: 232), borderWidth: 0, padding: 0.44, radius: 0.30, spacing: 0.06))
        return [("Graphite", Self().look), ("Editorial", editorial), ("Broadcast", broadcast),
                ("Notebook", notebook), ("Terminal", terminal), ("Poster", poster)]
    }()
}

struct TitleTypeface {
    let id: String, name: String, upright: String
    var slanted: String? = nil
    var weights: [Int] = [400, 500, 600, 700, 800]
    static let families: [Self] = [
        .init(id: "system", name: "System", upright: "", slanted: ""),
        .init(
            id: "atkinsonhyperlegiblenext", name: "Atkinson Hyperlegible Next", upright: "AtkinsonHyperlegibleNext-Regular",
            slanted: "AtkinsonHyperlegibleNext-Italic"),
        .init(
            id: "barlowcondensed", name: "Barlow Condensed", upright: "BarlowCondensed-Regular",
            slanted: "BarlowCondensed-Italic", weights: [400, 700]),
        .init(id: "archivoblack", name: "Archivo Black", upright: "ArchivoBlack-Regular", weights: [400]),
        .init(
            id: "sourceserif4", name: "Source Serif 4", upright: "SourceSerif4Roman-Regular",
            slanted: "SourceSerif4Italic-Italic"),
        .init(id: "fraunces", name: "Fraunces", upright: "Fraunces-9ptBlack", slanted: "Fraunces-9ptBlackItalic"),
        .init(
            id: "ibmplexmono", name: "IBM Plex Mono", upright: "IBMPlexMono-Regular", slanted: "IBMPlexMono-Italic",
            weights: [400, 500, 700]),
        .init(id: "bodonimoda", name: "Bodoni Moda", upright: "BodoniModa-Regular", slanted: "BodoniModa-Italic"),
        .init(id: "unbounded", name: "Unbounded", upright: "Unbounded-Regular"),
        .init(id: "caveat", name: "Caveat", upright: "Caveat-Regular", weights: [400, 500, 600, 700]),
    ]
    private static let registered: Void = {
        guard let folder = Bundle.main.url(forResource: "TitleFonts", withExtension: nil),
            let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        else { return }
        for case let url as URL in files where url.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()
    static func font(_ design: TitleDesign, size: CGFloat, folder: URL? = nil) -> CTFont {
        if design.face.hasPrefix("import:") {
            return ImportedFonts.shared.font(design.face, size: size, weight: design.weight, folder: folder)
                ?? CTFontCreateUIFontForLanguage(.system, size, nil)!
        }
        _ = registered
        guard let family = families.first(where: { $0.id == design.face }) else {
            return CTFontCreateWithName(design.face as CFString, size, nil)
        }
        if family.id == "system" {
            let weights: [Int: Double] = [400: 0, 500: 0.23, 600: 0.3, 700: 0.4, 800: 0.56]
            let base = CTFontCreateUIFontForLanguage(.system, size, nil)!
            let descriptor = CTFontDescriptorCreateCopyWithAttributes(
                CTFontCopyFontDescriptor(base),
                [kCTFontTraitsAttribute: [kCTFontWeightTrait: weights[design.weight] ?? 0.4]] as CFDictionary)
            let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
            return design.italic
                ? CTFontCreateCopyWithSymbolicTraits(font, size, nil, .italicTrait, .italicTrait) ?? font : font
        }
        var name = design.italic ? family.slanted ?? family.upright : family.upright
        if family.id == "barlowcondensed" || family.id == "ibmplexmono" {
            let suffix = design.weight >= 600 ? "Bold" : family.id == "ibmplexmono" && design.weight >= 500 ? "Medium" : ""
            name =
                String(family.upright.split(separator: "-")[0]) + "-" + suffix
                + (design.italic ? "Italic" : suffix.isEmpty ? "Regular" : "")
        }
        let base = CTFontCreateWithName(name as CFString, size, nil)
        guard let axes = CTFontCopyVariationAxes(base) as? [[CFString: Any]],
            axes.contains(where: { ($0[kCTFontVariationAxisIdentifierKey] as? NSNumber)?.intValue == 0x7767_6874 })
        else { return base }
        let descriptor = CTFontDescriptorCreateCopyWithVariation(
            CTFontCopyFontDescriptor(base), NSNumber(value: 0x7767_6874), CGFloat(design.weight))
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }
    static func label(_ id: String, folder: URL? = nil) -> String {
        if let ref = ImportedFontFace.Reference(id) { return ImportedFonts.shared.face(id, folder: folder)?.name ?? ref.postScriptName }
        if let family = families.first(where: { $0.id == id }) { return family.name }
        let font = CTFontCreateWithName(id as CFString, 14, nil)
        return (CTFontCopyPostScriptName(font) as String) == id ? CTFontCopyDisplayName(font) as String : id
    }
    static func missingOnDevice(_ id: String, folder: URL? = nil) -> Bool {
        if id.hasPrefix("import:") { return ImportedFonts.shared.face(id, folder: folder) == nil }
        return !families.contains { $0.id == id }
            && (CTFontCopyPostScriptName(CTFontCreateWithName(id as CFString, 14, nil)) as String) != id
    }
}

enum TitleDirection: String, Codable, CaseIterable { case up, down, left, right }
enum TitleMove: String, Codable, CaseIterable { case none, fade, drift, scale, wipe }
struct TitleMotion: Codable, Equatable, Hashable, Sendable {
    var entrance = TitleMove.none, exit = TitleMove.none
    var inSeconds = 0.35, outSeconds = 0.35
    var inDirection: TitleDirection?, outDirection: TitleDirection?
    var active: Bool { entrance != .none || exit != .none }
    var valid: Bool { (0.05...5).contains(inSeconds) && (0.05...5).contains(outSeconds) }
    struct Pose {
        var opacity = 1.0, scale = 1.0, rise = 0.0, shift = 0.0
        var left = 0.0, right = 1.0, top = 0.0, bottom = 1.0
        func rect(_ rect: CGRect) -> CGRect {
            let width = rect.width * scale
            let height = rect.height * scale
            return CGRect(
                x: rect.midX - width / 2 + width * left + shift * rect.height,
                y: rect.midY - height / 2 + rise * rect.height + height * top,
                width: width * (right - left), height: height * (bottom - top))
        }
        func crop(_ image: CGImage) -> CGImage? {
            guard left > 0 || right < 1 || top > 0 || bottom < 1 else { return image }
            let a = floor(left * Double(image.width))
            let b = ceil(right * Double(image.width))
            let y = floor(top * Double(image.height))
            let endY = ceil(bottom * Double(image.height))
            guard b > a && endY > y else { return nil }
            return image.cropping(to: CGRect(x: a, y: y, width: b - a, height: endY - y))
        }
    }
    private func fittedEnds(duration: Double) -> (entrance: Double, exit: Double) {
        let a = entrance == .none ? 0 : inSeconds
        let b = exit == .none ? 0 : outSeconds
        guard a + b > 0 else { return (0, 0) }
        // Keep a fully readable interval even if both requested transitions exceed the cue.
        let hold = min(0.1, max(0, duration * 0.2))
        let fit = min(1, max(0, duration - hold) / (a + b))
        return (a * fit, b * fit)
    }
    func readableRange(in clock: ClosedRange<Double>) -> ClosedRange<Double> {
        let ends = fittedEnds(duration: clock.upperBound - clock.lowerBound)
        let first = clock.lowerBound + ends.entrance
        return first...max(first, clock.upperBound - ends.exit)
    }
    func previewWindow(exit atEnd: Bool, duration: Double) -> ClosedRange<Double> {
        let ends = fittedEnds(duration: duration)
        if atEnd { return max(0, duration - ends.exit - 0.35)...max(0, duration) }
        return 0...max(0, min(duration, ends.entrance + 0.35))
    }
    func pose(at time: Double, duration: Double) -> Pose {
        let ends = fittedEnds(duration: duration)
        let entering = ends.entrance > 0 && time < ends.entrance
        let leaving = ends.exit > 0 && time > duration - ends.exit
        guard entering || leaving else { return Pose() }
        let fraction = entering ? time / ends.entrance : (duration - time) / ends.exit
        let t = min(1, max(0, fraction))
        let eased = t * t * (3 - 2 * t)
        var p = Pose()
        let direction = entering ? inDirection : outDirection
        switch entering ? entrance : exit {
        case .none: break
        case .fade: p.opacity = eased
        case .drift:
            p.opacity = eased
            let offset = (entering ? -0.32 : 0.32) * (1 - eased)
            switch direction ?? .up {
            case .up: p.rise = -offset
            case .down: p.rise = offset
            case .left: p.shift = -offset
            case .right: p.shift = offset
            }
        case .scale:
            p.opacity = eased
            p.scale = 1 + (entering ? -0.12 : 0.08) * (1 - eased)
        case .wipe:
            switch direction ?? .right {
            case .right: if entering { p.right = eased } else { p.left = 1 - eased }
            case .left: if entering { p.left = 1 - eased } else { p.right = eased }
            case .down: if entering { p.bottom = eased } else { p.top = 1 - eased }
            case .up: if entering { p.top = 1 - eased } else { p.bottom = eased }
            }
        }
        return p
    }
}
