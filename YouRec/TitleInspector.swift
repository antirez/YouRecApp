import AVFoundation
import SwiftUI

struct TitleInspector: View {
    @Binding var design: TitleDesign
    @Binding var motion: TitleMotion
    let sample: String
    let prefix: String
    let folder: URL
    @ObservedObject private var importedFonts = EditorFonts.shared
    @State private var fontLibrary = false
    let frame: () async throws -> CGImage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var replay: ((Bool) -> Void)?
    var changeSection: () -> Void = {}
    let pauseForFonts: () -> Void
    @State private var tab = Tab.looks
    @State private var exitSelected = false
    @State private var systemFonts = false
    @State private var savePrompt = false
    @State private var name = ""
    @State private var lastGradient = TitleGradient.gallery[0].value
    @State private var deleting: SavedLook?
    @AppStorage("title.savedLooks.v1") private var saved = Data()
    @AppStorage("title.favoriteFonts.v1") private var favoriteData = Data()

    private enum Tab: String, CaseIterable {
        case looks = "Looks"
        case font = "Font"
        case fill = "Fill"
        case border = "Outline"
        case shadow = "Shadow"
        case plate = "Background"
        case motion = "Motion"
        var icon: String {
            switch self {
            case .looks: "square.grid.2x2"
            case .font: "textformat"
            case .fill: "paintpalette"
            case .border: "circle.dashed"
            case .shadow: "circle.righthalf.filled"
            case .plate: "rectangle.fill"
            case .motion: "arrow.right.to.line"
            }
        }
    }
    private struct SavedLook: Identifiable, Codable {
        var id = UUID()
        let name: String
        let design: TitleDesign
    }
    private var library: [SavedLook] { (try? JSONDecoder().decode([SavedLook].self, from: saved)) ?? [] }
    private var favorites: [String] { (try? JSONDecoder().decode([String].self, from: favoriteData)) ?? [] }
    private var demo: String { sample.isEmpty ? "Your title" : String(sample.prefix(48)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 82), spacing: 6)], spacing: 6) {
                ForEach(Tab.allCases, id: \.self) { value in
                    Button {
                        changeSection()
                        tab = value
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: value.icon)
                            Text(value.rawValue).font(.caption)
                        }
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(
                            tab == value ? Color.cyan.opacity(0.22) : .white.opacity(0.07),
                            in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).accessibilityAddTraits(tab == value ? .isSelected : [])
                        .accessibilityIdentifier(prefix + ".tab." + value.rawValue)
                }
            }
            Divider()
            switch tab {
            case .looks: looks
            case .font: fonts
            case .fill: fill
            case .border:
                Toggle("Letter outline", isOn: $design.outlined).accessibilityIdentifier(prefix + ".outline")
                if design.outlined {
                    color("Outline color", $design.border)
                    slider("Width", $design.borderWidth, 0.01...0.20, step: 0.005)
                }
            case .shadow:
                Toggle("Drop shadow", isOn: $design.shadow)
                if design.shadow {
                    color("Shadow color", $design.shade)
                    slider("Blur", $design.shadowBlur, 0...0.6)
                    slider("Offset", $design.shadowOffset, -0.5...0.5)
                }
            case .plate:
                Picker("Background", selection: $design.plate) {
                    Text("None").tag(TitlePlate.off)
                    Text("One box").tag(TitlePlate.block)
                    Text("Each line").tag(TitlePlate.lines)
                }.pickerStyle(.segmented)
                if design.plate != .off {
                    color("Box color", $design.backing)
                    slider("Padding", $design.padding, 0...0.8)
                    slider("Corner radius", $design.radius, 0...0.8)
                }
            case .motion: motionControls
            }
        }
        .task(id: tab) { if tab == .font { try? await importedFonts.refresh() } }
        .sheet(isPresented: $fontLibrary) {
            NavigationStack {
                FontLibraryView(use: { chooseFace($0.id) }, draftFace: design.face, folder: folder)
            }.preferredColorScheme(.dark)
        }
        .sheet(isPresented: $systemFonts) {
            DeviceTitleFontPicker { ps in
                if let ps {
                    design.face = ps
                    design.weight = 400
                    design.italic = false
                }
                systemFonts = false
            }
        }
        .alert("Save channel style", isPresented: $savePrompt) {
            TextField("Style name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let entry = SavedLook(name: name.trimmingCharacters(in: .whitespacesAndNewlines), design: design)
                if let data = try? JSONEncoder().encode([entry] + library) { saved = data }
            }.disabled(
                name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 60
                    || library.contains {
                        $0.name.caseInsensitiveCompare(name.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
                    })
        } message: {
            Text("Saves the font and appearance across projects. Outline and motion are set on each overlay.")
        }
        .confirmationDialog(
            "Delete this saved style?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible, presenting: deleting
        ) { entry in
            Button("Delete style", role: .destructive) {
                if let data = try? JSONEncoder().encode(library.filter { $0.id != entry.id }) { saved = data }
                deleting = nil
            }
        }
    }
    private func color(_ name: String, _ value: Binding<TitleInk>) -> some View {
        TitleColorControl(title: name, ink: value, frame: frame)
    }
    private func slider(_ name: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, step: Double = 0.01)
        -> some View
    {
        VStack(spacing: 1) {
            HStack {
                Text(name)
                Spacer()
                Text(value.wrappedValue.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit().foregroundStyle(
                    .secondary)
            }
            Slider(value: value, in: range, step: step).accessibilityLabel(name)
        }.font(.subheadline)
    }
    private func look(_ label: String, _ value: TitleDesign) -> some View {
        Button {
            design = design.applyingLook(value)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                TitleLookSpecimen(words: demo, design: design.applyingLook(value), folder: folder)
                Text(label).font(.caption).foregroundStyle(.secondary)
            }.padding(8).frame(maxWidth: .infinity, minHeight: 58, alignment: .leading).background(
                .white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).accessibilityLabel(label).accessibilityIdentifier(prefix + ".look." + label)
    }
    @ViewBuilder private var looks: some View {
        if !library.isEmpty {
            Text("My styles").font(.headline)
            ForEach(library) { entry in
                HStack {
                    look(entry.name, entry.design)
                    Button {
                        deleting = entry
                    } label: {
                        Image(systemName: "trash").frame(width: 44, height: 44)
                    }.accessibilityLabel("Delete " + entry.name)
                }
            }
        }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 115), spacing: 8)]) {
            ForEach(TitleDesign.looks, id: \.name) { item in look(item.name, item.design) }
        }
        Button {
            name = ""
            savePrompt = true
        } label: {
            Label("Save as channel style", systemImage: "bookmark").frame(minHeight: 44)
        }
    }
    private var orderedFonts: [String] {
        let added = importedFonts.files.flatMap { $0.faces.map(\.id) }
        let favorites = self.favorites.filter { !$0.hasPrefix("import:") || added.contains($0) || $0 == design.face }
        let listed = added + TitleTypeface.families.map(\.id)
        let extra = listed.contains(design.face) ? [] : [design.face]
        var seen = Set<String>()
        return (favorites + extra + listed).filter { seen.insert($0).inserted }
    }
    private func chooseFace(_ id: String) {
        var next = design
        let family = TitleTypeface.families.first { $0.id == id }
        if let imported = ImportedFonts.shared.face(id, folder: folder) {
            if id != design.face { next.weight = imported.defaultWeight }
        } else if let family, !family.weights.contains(next.weight) { next.weight = family.weights[0] }
        next.face = id
        if family?.slanted == nil { next.italic = false }
        design = next
    }
    @ViewBuilder private var fonts: some View {
        Button { changeSection(); pauseForFonts(); fontLibrary = true } label: {
            Label("Import", systemImage: "square.and.arrow.down").frame(minHeight: 44)
        }.accessibilityHint("Open your font library.").accessibilityIdentifier(prefix + ".fonts.import")
        if TitleTypeface.missingOnDevice(design.face, folder: folder) {
            Text("Using a fallback for " + TitleTypeface.label(design.face, folder: folder) + ". Import the original font to restore it.")
                .font(.footnote)
        }
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(orderedFonts, id: \.self) { fontRow($0) }
        }
        Button("More iPhone fonts…") { systemFonts = true }.frame(minHeight: 44)
        let choice = TitleTypeface.families.first { $0.id == design.face }
        let weights = choice?.weights ?? ImportedFonts.shared.face(design.face, folder: folder)?.weights ?? []
        if weights.count > 1 {
            Picker("Weight", selection: $design.weight) {
                ForEach(weights, id: \.self) { w in Text(weightName(w)).tag(w) }
            }
        }
        if choice?.slanted != nil { Toggle("Italic", isOn: $design.italic) }
        Picker("Alignment", selection: $design.alignment) {
            ForEach(TitleAlignment.allCases, id: \.self) { v in Text(v.rawValue.capitalized).tag(v) }
        }.pickerStyle(.segmented)
        slider("Letter spacing", $design.tracking, -0.05...0.25)
        slider("Line spacing", $design.lineSpacing, 0...0.8)
    }
    private func fontRow(_ id: String) -> some View {
        let label = importedFonts.labels[id] ?? TitleTypeface.label(id, folder: folder)
        let family = TitleTypeface.families.first { $0.id == id }
        var specimen: TitleDesign {
            var d = design
            d.face = id
            if id != design.face, let imported = ImportedFonts.shared.face(id, folder: folder) { d.weight = imported.defaultWeight }
            if let family, !family.weights.contains(d.weight) { d.weight = family.weights[0] }
            return d
        }
        return HStack {
            Button {
                chooseFace(id)
            } label: {
                HStack {
                    VStack(alignment: .leading) {
                        Text(demo).font(Font(TitleTypeface.font(specimen, size: 22, folder: folder))).lineLimit(1)
                        Text(label).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if design.face == id { Image(systemName: "checkmark").foregroundStyle(.cyan) }
                }
                .contentShape(Rectangle())
            }.buttonStyle(.plain).frame(minHeight: 44).accessibilityLabel(label)
                .accessibilityAddTraits(design.face == id ? .isSelected : [])
                .accessibilityIdentifier(prefix + ".face." + id)
            Button {
                let next = favorites.contains(id) ? favorites.filter { $0 != id } : favorites + [id]
                if let data = try? JSONEncoder().encode(next) { favoriteData = data }
            } label: {
                Image(systemName: favorites.contains(id) ? "star.fill" : "star").frame(width: 44, height: 44)
            }
            .accessibilityLabel((favorites.contains(id) ? "Unfavorite " : "Favorite ") + label)
        }
    }
    private func weightName(_ weight: Int) -> String {
        [400: "Regular", 500: "Medium", 600: "Semibold", 700: "Bold", 800: "Extra bold"][weight] ?? String(weight)
    }
    @ViewBuilder private var fill: some View {
        Picker(
            "Fill",
            selection: Binding(
                get: { design.gradient != nil },
                set: { enabled in
                    if enabled {
                        design.gradient = lastGradient
                    } else {
                        if let old = design.gradient { lastGradient = old }
                        design.gradient = nil
                    }
                })
        ) {
            Text("Solid").tag(false)
            Text("Gradient").tag(true)
        }.pickerStyle(.segmented).accessibilityIdentifier(prefix + ".fillMode")
        if let g = design.gradient {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 8)], spacing: 8) {
                ForEach(TitleGradient.gallery, id: \.name) { item in
                    Button {
                        design.gradient = item.value
                        lastGradient = item.value
                    } label: {
                        VStack(spacing: 3) {
                            GeometryReader { proxy in
                                let size = proxy.size
                                let axis = item.value.axis(in: size)
                                if size.width > 0 && size.height > 0 {
                                    LinearGradient(
                                        colors: [Color(cgColor: item.value.first.cg), Color(cgColor: item.value.last.cg)],
                                        startPoint: UnitPoint(x: axis.0.x / size.width, y: axis.0.y / size.height),
                                        endPoint: UnitPoint(x: axis.1.x / size.width, y: axis.1.y / size.height))
                                }
                            }.frame(height: 29).clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay {
                                    if g == item.value {
                                        Image(systemName: "checkmark.circle.fill").symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, .black)
                                    }
                                }
                            Text(item.name).font(.caption)
                        }.frame(minHeight: 48)
                    }.buttonStyle(.plain).accessibilityLabel(item.name).accessibilityAddTraits(
                        g == item.value ? .isSelected : []
                    )
                    .accessibilityIdentifier(prefix + ".gradient." + item.name)
                }
            }
            color("First color", Binding(get: { design.gradient?.first ?? g.first }, set: { design.gradient?.first = $0 }))
            color("Second color", Binding(get: { design.gradient?.last ?? g.last }, set: { design.gradient?.last = $0 }))
            HStack {
                Text("Angle")
                Slider(
                    value: Binding(get: { design.gradient?.angle ?? g.angle }, set: { design.gradient?.angle = $0 }),
                    in: 0...360, step: 1
                ).accessibilityLabel("Gradient angle")
                Text("\(Int(g.angle))°").monospacedDigit()
            }
        } else {
            color("Text color", $design.fill)
        }
    }
    @ViewBuilder private var motionControls: some View {
        Picker("Animation end", selection: $exitSelected) {
            Text("Entrance").tag(false)
            Text("Exit").tag(true)
        }.pickerStyle(.segmented)
        let move = exitSelected ? $motion.exit : $motion.entrance
        let seconds = exitSelected ? $motion.outSeconds : $motion.inSeconds
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 76))]) {
            ForEach(TitleMove.allCases, id: \.self) { mode in
                Button {
                    move.wrappedValue = mode
                    if mode != .none && !reduceMotion { replay?(exitSelected) }
                } label: {
                    Text(mode.rawValue.capitalized).frame(maxWidth: .infinity, minHeight: 44)
                        .background(
                            move.wrappedValue == mode ? .cyan.opacity(0.22) : .white.opacity(0.07),
                            in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).accessibilityAddTraits(move.wrappedValue == mode ? .isSelected : [])
                    .accessibilityIdentifier(prefix + ".motion." + mode.rawValue)
            }
        }
        if move.wrappedValue == .drift || move.wrappedValue == .wipe {
            let direction = exitSelected ? $motion.outDirection : $motion.inDirection
            Picker(
                "Direction",
                selection: Binding(
                    get: { direction.wrappedValue ?? (move.wrappedValue == .drift ? .up : .right) },
                    set: { direction.wrappedValue = $0 })
            ) {
                ForEach(TitleDirection.allCases, id: \.self) { d in Text(d.rawValue.capitalized).tag(d) }
            }
        }
        if move.wrappedValue != .none {
            HStack {
                Text("Duration")
                Slider(value: seconds, in: 0.05...5, step: 0.05).accessibilityLabel("Animation duration")
                Text(seconds.wrappedValue.formatted(.number.precision(.fractionLength(2))) + " s").monospacedDigit()
            }
        }
        if let replay, move.wrappedValue != .none {
            Button {
                replay(exitSelected)
            } label: {
                Label(exitSelected ? "Preview exit" : "Preview entrance", systemImage: "play.fill").frame(minHeight: 44)
            }.accessibilityIdentifier(prefix + ".replay")
        }
    }
}

private struct TitleLookSpecimen: View {
    struct Key: Hashable {
        let words: String
        let design: TitleDesign
    }
    let words: String, design: TitleDesign
    let folder: URL
    @State private var image: CGImage?
    var body: some View {
        Group {
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFit() } else { Color.clear }
        }.frame(maxWidth: .infinity, minHeight: 28, maxHeight: 32, alignment: .leading)
            .task(id: Key(words: words, design: design)) {
                let words = self.words
                let style = self.design
                let result = await Task.detached(priority: .utility) {
                    StyledTextLayout(text: words, design: style, fontSize: 36, maxWidth: 360, folder: folder).image(scale: 1)
                }.value
                if !Task.isCancelled { image = result }
            }
    }
}

private struct DeviceTitleFontPicker: UIViewControllerRepresentable {
    let complete: (String?) -> Void
    final class Coordinator: NSObject, UIFontPickerViewControllerDelegate {
        let complete: (String?) -> Void
        init(_ complete: @escaping (String?) -> Void) { self.complete = complete }
        func fontPickerViewControllerDidPickFont(_ viewController: UIFontPickerViewController) {
            complete(viewController.selectedFontDescriptor?.postscriptName)
        }
        func fontPickerViewControllerDidCancel(_ viewController: UIFontPickerViewController) { complete(nil) }
    }
    func makeCoordinator() -> Coordinator { Coordinator(complete) }
    func makeUIViewController(context: Context) -> UIFontPickerViewController {
        let config = UIFontPickerViewController.Configuration()
        config.includeFaces = true
        let picker = UIFontPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: UIFontPickerViewController, context: Context) {}
}

extension TitleInspector {
    /// Sample the composed frame at the parked playhead, in display sRGB.
    static func picture(player: AVPlayer, at time: Double) async throws -> CGImage {
        guard let item = player.currentItem else { throw ProjectError.invalidMedia }
        let generator = AVAssetImageGenerator(asset: item.asset)
        generator.videoComposition = item.videoComposition
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: CMTime(seconds: max(0, time), preferredTimescale: 60000)).image
    }
}

private struct TitleColorControl: View {
    let title: String
    @Binding var ink: TitleInk
    let frame: () async throws -> CGImage
    @AppStorage("title.recentColors.v1") private var recentData = Data()
    @State private var hex = ""
    @State private var sampleFrame = false
    @State private var expanded = false
    private var recents: [TitleInk] { (try? JSONDecoder().decode([TitleInk].self, from: recentData)) ?? [] }
    private func remember(_ c: TitleInk) {
        if let data = try? JSONEncoder().encode(Array(([c] + recents.filter { $0 != c }).prefix(8))) { recentData = data }
    }
    private func select(_ c: TitleInk) {
        ink = c
        remember(c)
    }
    private var encoded: String { String(format: "%06X", ink.rgb) }
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                ColorPicker(
                    "Pick color",
                    selection: Binding(
                        get: { Color(cgColor: ink.cg) },
                        set: { c in
                            var r: CGFloat = 0
                            var g: CGFloat = 0
                            var b: CGFloat = 0
                            var a: CGFloat = 1
                            let ui = UIColor(c)
                            if let rgb = ui.cgColor.converted(
                                to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .relativeColorimetric, options: nil),
                                UIColor(cgColor: rgb).getRed(&r, green: &g, blue: &b, alpha: &a)
                            {
                                func byte(_ x: CGFloat) -> UInt32 { UInt32((min(1, max(0, x)) * 255).rounded()) }
                                ink = TitleInk(byte(r) << 16 | byte(g) << 8 | byte(b), alpha: UInt8(byte(a)))
                            }
                        }), supportsOpacity: true)
                HStack {
                    Text("Hex")
                    TextField("RRGGBB", text: $hex).textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder).accessibilityLabel(title + " hex")
                    Button("Set") {
                        let clean = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
                        if let value = UInt32(clean, radix: 16) { select(TitleInk(value, alpha: UInt8(ink.rgba & 255))) }
                    }.disabled(
                        !hex.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).allSatisfy(\.isHexDigit)
                            || hex.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).count != 6)
                }
                HStack {
                    Text("Opacity")
                    Slider(
                        value: Binding(
                            get: { ink.alpha }, set: { ink = TitleInk(ink.rgb, alpha: UInt8(($0 * 255).rounded())) }),
                        in: 0...1, step: 0.01
                    ).accessibilityLabel(title + " opacity")
                    Text(ink.alpha.formatted(.percent)).monospacedDigit()
                }
                let palette = TextColor.allCases.map(TitleInk.init)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 38), spacing: 2)], spacing: 1) {
                    ForEach(palette + recents.filter { !palette.contains($0) }, id: \.self) { c in
                        Button {
                            select(c)
                        } label: {
                            Circle().fill(Color(cgColor: c.cg)).overlay(Circle().stroke(.gray, lineWidth: 1)).frame(
                                width: 24, height: 24
                            ).frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.plain).accessibilityLabel(String(format: "Color %06X", c.rgb))
                    }
                }
                Button {
                    sampleFrame = true
                } label: {
                    Label("Sample video frame", systemImage: "eyedropper").frame(minHeight: 44)
                }
            }.padding(.vertical, 6)
        } label: {
            HStack {
                Text(title)
                Spacer()
                Circle().fill(Color(cgColor: ink.cg)).overlay(Circle().stroke(.gray, lineWidth: 1)).frame(
                    width: 22, height: 22)
            }.frame(minHeight: 40)
        }
        .onAppear { hex = encoded }.onChange(of: ink) { _, _ in hex = encoded }
        .onChange(of: expanded) { _, open in if !open { remember(ink) } }
        .onDisappear { if expanded { remember(ink) } }
        .sheet(isPresented: $sampleFrame) {
            FrameInkPicker(load: frame) { color in
                select(color)
                sampleFrame = false
            }
        }
    }
}

private struct FrameInkPicker: View {
    @Environment(\.dismiss) private var dismiss
    let load: () async throws -> CGImage
    let choose: (TitleInk) -> Void
    @State private var image: CGImage?
    @State private var failure: String?
    var body: some View {
        NavigationStack {
            Group {
                if let image {
                    GeometryReader { geometry in
                        let rect = AVMakeRect(
                            aspectRatio: CGSize(width: image.width, height: image.height),
                            insideRect: CGRect(origin: .zero, size: geometry.size))
                        Image(decorative: image, scale: 1).resizable().frame(width: rect.width, height: rect.height)
                            .contentShape(Rectangle()).onTapGesture { p in
                                let x = min(image.width - 1, max(0, Int(p.x / rect.width * Double(image.width))))
                                let y = min(image.height - 1, max(0, Int(p.y / rect.height * Double(image.height))))
                                guard let pixel = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return }
                                var bytes = [UInt8](repeating: 0, count: 4)
                                let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
                                    guard
                                        let ctx = CGContext(
                                            data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                                    else { return false }
                                    ctx.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                                    return true
                                }
                                if ok { choose(TitleInk(UInt32(bytes[0]) << 16 | UInt32(bytes[1]) << 8 | UInt32(bytes[2]))) }
                            }
                            .accessibilityElement(children: .ignore).accessibilityLabel("Video frame")
                            .accessibilityIdentifier("title.frameSample")
                            .position(x: rect.midX, y: rect.midY)
                    }
                } else if let failure {
                    Text(failure).padding()
                } else {
                    ProgressView("Loading frame…")
                }
            }.navigationTitle("Tap a color in the frame").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }.preferredColorScheme(.dark).task {
            do { image = try await load() } catch { failure = error.localizedDescription }
        }
    }
}
