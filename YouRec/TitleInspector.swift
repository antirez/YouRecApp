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
    var replay: ((Bool) -> Void)?
    var changeSection: () -> Void = {}
    let pauseForFonts: () -> Void
    var showsMotion = true
    var showsLooks = true
    @State private var tab = Tab.looks
    @State private var systemFonts = false
    @State private var savePrompt = false
    @State private var name = ""
    @State private var lastGradient = TitleGradient.gallery[0].value
    @State private var deleting: SavedLook?
    @State private var chosenLookID: String?
    @State private var browsedCollection: TitleDesign.LookCollection?
    @ScaledMetric(relativeTo: .caption) private var lookTileWidth: CGFloat = 122
    @State private var lookColumns = 2
    @AppStorage("title.savedLooks.v1") private var saved = Data()
    @AppStorage("title.favoriteFonts.v1") private var favoriteData = Data()

    private enum Tab: String, CaseIterable {
        case looks = "Looks"
        case font = "Font"
        case fill = "Fill"
        case border = "Border"
        case shadow = "Shadow"
        case plate = "Background"
        case motion = "Motion"
        var icon: String {
            switch self {
            case .looks: "square.grid.2x2"
            case .font: "textformat"
            case .fill: "paintpalette"
            case .border: "character.textbox"
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
                ForEach(Tab.allCases.filter { ($0 != .motion || showsMotion) && ($0 != .looks || showsLooks) }, id: \.self) { value in
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
                            visibleTab == value ? Color.cyan.opacity(0.22) : .white.opacity(0.07),
                            in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).accessibilityAddTraits(visibleTab == value ? .isSelected : [])
                        .accessibilityIdentifier(prefix + ".tab." + value.rawValue)
                }
            }
            Divider()
            switch visibleTab {
            case .looks: looks
            case .font: fonts
            case .fill: fill
            case .border:
                Toggle("Text border", isOn: $design.outlined)
                    .frame(minHeight: 44).accessibilityIdentifier(prefix + ".outline")
                if design.outlined { borderControls }
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
                    TitleColorControl(title: "Box color", ink: $design.backing, frame: frame, editsOpacity: false)
                    slider("Background opacity", Binding(get: { design.backing.alpha }, set: { opacity in
                        design.backing = TitleInk(design.backing.rgb, alpha: UInt8((opacity * 255).rounded()))
                    }), 0...1)
                    slider("Padding", $design.padding, 0...0.8)
                    slider("Corner radius", $design.radius, 0...0.8)
                }
            case .motion: TitleMotionControls(motion: $motion, prefix: prefix, replay: replay)
            }
        }
        .onGeometryChange(for: Int.self) { geometry in
            let capacity = Int((geometry.size.width + 8) / (lookTileWidth + 8))
            // Each collection has six tiles. Keep the rows even as the inspector resizes.
            return [6, 3, 2, 1].first { $0 <= capacity } ?? 1
        } action: { lookColumns = $0 }
        .task(id: visibleTab) { if visibleTab == .font { try? await importedFonts.refresh() } }
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
                if let data = try? JSONEncoder().encode([entry] + library) {
                    saved = data
                    chosenLookID = entry.id.uuidString
                }
            }.disabled(
                name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 60
                    || library.contains {
                        $0.name.caseInsensitiveCompare(name.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
                    })
        } message: {
            Text("Saves the font and appearance across projects. Border and motion are set on each overlay.")
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
    private var visibleTab: Tab {
        if tab == .looks && !showsLooks { return .font }
        if tab == .motion && !showsMotion { return showsLooks ? .looks : .font }
        return tab
    }
    @ViewBuilder private var borderControls: some View {
        Picker("Border thickness", selection: $design.borderWidth) {
            Text("Thin").tag(0.025)
            Text("Medium").tag(0.045)
            Text("Bold").tag(0.09)
            if ![0.025, 0.045, 0.09].contains(design.borderWidth) {
                Text("Custom").tag(design.borderWidth)
            }
        }.pickerStyle(.segmented).accessibilityIdentifier(prefix + ".border.thickness")
        slider("Border width", $design.borderWidth, 0.01...0.20, step: 0.005)
        color("Border color", $design.border)
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
    private func look(_ label: String, _ value: TitleDesign, id: String, selectedID: String?) -> some View {
        let applied = design.applyingLook(value)
        let selected = id == selectedID
        return Button {
            changeSection()
            design = applied
            chosenLookID = id
        } label: {
            TitleLookTile(name: label, selected: selected) {
                TitleLookSpecimen(words: demo, design: applied, folder: folder)
            }
        }.buttonStyle(.plain).accessibilityLabel(label).accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier(prefix + ".look." + label)
    }
    @ViewBuilder private var looks: some View {
        let personal = library
        let builtIn = TitleDesign.looks.first { design.applyingLook($0.design) == design }
        let matches = [builtIn?.name].compactMap { $0 }
            + personal.filter { design.applyingLook($0.design) == design }.map { $0.id.uuidString }
        let selected = chosenLookID.flatMap { matches.contains($0) ? $0 : nil } ?? matches.first
        let collection = browsedCollection ?? builtIn?.collection ?? .editorial
        Picker("Look collection", selection: Binding(get: { collection }, set: { group in
            changeSection()
            browsedCollection = group
        })) {
            ForEach(TitleDesign.LookCollection.allCases, id: \.self) { group in Text(group.rawValue).tag(group) }
        }.pickerStyle(.segmented).accessibilityIdentifier(prefix + ".lookCollection")
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: lookColumns), spacing: 8) {
            ForEach(TitleDesign.looks.filter { $0.collection == collection }, id: \.name) { item in
                look(item.name, item.design, id: item.name, selectedID: selected)
            }
        }
        if !personal.isEmpty {
            Text("My styles").font(.headline)
            ForEach(personal) { entry in
                HStack {
                    look(entry.name, entry.design, id: entry.id.uuidString, selectedID: selected)
                    Button {
                        deleting = entry
                    } label: {
                        Image(systemName: "trash").frame(width: 44, height: 44)
                    }.accessibilityLabel("Delete " + entry.name)
                }
            }
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
}

struct TitleMotionControls: View {
    @Binding var motion: TitleMotion
    let prefix: String
    let replay: ((Bool) -> Void)?
    @State private var exitSelected = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
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

struct GroupTitleLooks: View {
    @Binding var group: LabelHeadline
    let headline: String
    let folder: URL
    let dismissKeyboard: () -> Void
    @State private var expanded = false
    @AppStorage("title.groupLooks.v1") private var saved = Data()
    @State private var saving = false
    @State private var name = ""
    @State private var chosenName: String?
    @State private var deleting: Saved?

    private struct Saved: Identifiable, Codable {
        var id = UUID()
        let name: String
        let look: LabelHeadline.Look
    }
    private var library: [Saved] { (try? JSONDecoder().decode([Saved].self, from: saved)) ?? [] }
    private func store(_ styles: [Saved]) {
        if let data = try? JSONEncoder().encode(styles) { saved = data }
    }

    var body: some View {
        let current = group.look
        let personal = library
        let matches = LabelHeadline.looks.filter { $0.design == current }.map(\.name) + personal.filter { $0.look == current }.map(\.name)
        let selected = chosenName.flatMap { matches.contains($0) ? $0 : nil } ?? matches.first ?? "Custom"
        VStack(alignment: .leading, spacing: 10) {
            Button {
                dismissKeyboard()
                expanded.toggle()
            } label: {
                HStack {
                    Label("Looks", systemImage: "square.grid.2x2")
                    Spacer()
                    Text(selected).foregroundStyle(.secondary)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption)
                }.padding(.horizontal, 12).frame(minHeight: 44)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain).accessibilityLabel("Looks").accessibilityValue(selected)
                .accessibilityHint(expanded ? "Hide title looks" : "Show looks for the label, headline and card")
                .accessibilityIdentifier("title.tab.Looks")
            if expanded {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 8)], spacing: 8) {
                    ForEach(LabelHeadline.looks, id: \.name) { item in
                        tile(item.name, look: item.design, selected: selected == item.name, id: "title.groupLook." + item.name)
                    }
                }
                if !personal.isEmpty {
                    Text("My styles").font(.headline)
                    ForEach(personal) { entry in
                        HStack {
                            tile(entry.name, look: entry.look, selected: selected == entry.name, id: "title.savedGroupLook." + entry.name)
                            Button { deleting = entry } label: {
                                Image(systemName: "trash").frame(width: 44, height: 44)
                            }.accessibilityLabel("Delete " + entry.name)
                        }
                    }
                }
                Button { name = ""; saving = true } label: {
                    Label("Save as channel style", systemImage: "bookmark").frame(minHeight: 44)
                }
            }
        }
        .alert("Save title look", isPresented: $saving) {
            TextField("Style name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let entered = name.trimmingCharacters(in: .whitespacesAndNewlines)
                store([Saved(name: entered, look: group.look)] + library)
                chosenName = entered
            }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 60
                    || (personal.map(\.name) + LabelHeadline.looks.map(\.name) + ["Custom"]).contains {
                    $0.caseInsensitiveCompare(name.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
                })
        } message: { Text("Saves the appearance of the label, headline, and card for other titles.") }
        .confirmationDialog("Delete this saved look?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { entry in
            Button("Delete look", role: .destructive) { store(personal.filter { $0.id != entry.id }) }
        }
    }

    private func tile(_ name: String, look: LabelHeadline.Look, selected: Bool, id: String) -> some View {
        Button {
            dismissKeyboard()
            group = group.applyingLook(look)
            chosenName = name
        } label: {
            TitleLookTile(name: name, selected: selected) {
                GroupLookSpecimen(group: group.applyingLook(look), headline: headline, folder: folder)
            }
        }.buttonStyle(.plain).accessibilityLabel(name).accessibilityAddTraits(selected ? .isSelected : []).accessibilityIdentifier(id)
    }
}

private struct TitleLookTile<Specimen: View>: View {
    let name: String
    let selected: Bool
    @ViewBuilder var specimen: () -> Specimen

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            specimen()
                .frame(maxWidth: .infinity).frame(height: 54)
                .background(.black)
            HStack {
                Text(name).font(.caption.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 2)
                if selected { Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.cyan) }
            }.padding(.horizontal, 9).frame(minHeight: 28)
        }
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? Color.cyan : .clear, lineWidth: 1.5) }
    }
}

private struct GroupLookSpecimen: View {
    private struct Sample: Equatable {
        var group: LabelHeadline
        let headline: String
        let folder: URL
    }
    private let sample: Sample
    @State private var image: CGImage?

    init(group: LabelHeadline, headline: String, folder: URL) {
        // Bound the gallery sample so long or multiline copy remains readable at thumbnail size.
        func excerpt(_ text: String, limit: Int) -> String {
            let words = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return words.count <= limit ? words : String(words.prefix(limit - 1)) + "…"
        }
        var copy = group
        copy.label = excerpt(group.label, limit: 18)
        var heading = excerpt(headline, limit: 23)
        if copy.label.isEmpty && heading.isEmpty { copy.label = "First text"; heading = LabelHeadline.defaultHeadline }
        sample = Sample(group: copy, headline: heading, folder: folder)
    }

    var body: some View {
        Group {
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFit() } else { Color.clear }
        }.padding(.horizontal, 10).padding(.vertical, 7)
            .task(id: sample) {
                let sample = self.sample
                let result = await Task.detached(priority: .utility) {
                    LabelHeadlineLayout(sample.group, headline: sample.headline, fontSize: 58, width: 460, folder: sample.folder)
                        .image(fitting: CGSize(width: 460, height: 240))
                }.value
                if !Task.isCancelled { image = result }
            }
    }
}

private struct TitleLookSpecimen: View {
    private struct Sample: Equatable {
        let words: String
        let design: TitleDesign
        let folder: URL
    }
    private let sample: Sample
    @State private var image: CGImage?

    init(words: String, design: TitleDesign, folder: URL) {
        let line = words.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let excerpt = line.count > 20 ? String(line.prefix(19)) + "…" : line
        sample = Sample(words: excerpt.isEmpty ? "Your title" : excerpt, design: design, folder: folder)
    }

    var body: some View {
        Group {
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFit() } else { Color.clear }
        }.padding(.horizontal, 9).padding(.vertical, 3)
            .task(id: sample) {
                let sample = self.sample
                let result = await Task.detached(priority: .utility) {
                    StyledTextLayout(text: sample.words, design: sample.design, fontSize: 48, maxWidth: 560, folder: sample.folder).image(scale: 1)
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

struct TitleColorControl: View {
    let title: String
    @Binding var ink: TitleInk
    let frame: () async throws -> CGImage
    var editsOpacity = true
    @AppStorage("title.recentColors.v1") private var recentData = Data()
    @State private var hex = ""
    @State private var sampleFrame = false
    @State private var expanded = false
    private var recents: [TitleInk] { (try? JSONDecoder().decode([TitleInk].self, from: recentData)) ?? [] }
    private func remember(_ c: TitleInk) {
        if let data = try? JSONEncoder().encode(Array(([c] + recents.filter { $0 != c }).prefix(8))) { recentData = data }
    }
    private func select(_ c: TitleInk) {
        ink = editsOpacity ? c : TitleInk(c.rgb, alpha: UInt8(ink.rgba & 255))
        remember(editsOpacity ? ink : TitleInk(ink.rgb))
    }
    private var swatches: [TitleInk] {
        let palette = TextColor.allCases.map(TitleInk.init)
        var seen = Set(palette)
        return palette + recents.compactMap { recent in
            let swatch = editsOpacity ? recent : TitleInk(recent.rgb)
            return seen.insert(swatch).inserted ? swatch : nil
        }
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
                                let alpha = editsOpacity ? UInt8(byte(a)) : UInt8(ink.rgba & 255)
                                ink = TitleInk(byte(r) << 16 | byte(g) << 8 | byte(b), alpha: alpha)
                            }
                        }), supportsOpacity: editsOpacity)
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
                if editsOpacity {
                    HStack {
                        Text("Opacity")
                        Slider(value: Binding(get: { ink.alpha }, set: {
                            ink = TitleInk(ink.rgb, alpha: UInt8(($0 * 255).rounded()))
                        }), in: 0...1, step: 0.01).accessibilityLabel(title + " opacity")
                        Text(ink.alpha.formatted(.percent)).monospacedDigit()
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 38), spacing: 2)], spacing: 1) {
                    ForEach(swatches, id: \.self) { c in
                        Button {
                            select(c)
                        } label: {
                            Circle().fill(Color(cgColor: c.cg)).overlay(Circle().stroke(.gray, lineWidth: 1)).frame(
                                width: 24, height: 24
                            ).frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.plain).accessibilityLabel(String(format: "Color %06X", c.rgb)
                            + (c.alpha < 1 ? ", " + c.alpha.formatted(.percent) + " opacity" : ""))
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
