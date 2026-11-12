import SwiftUI
import UniformTypeIdentifiers

struct ColorGradeControls: View {
    @ObservedObject var model: ToolWorkspace
    @State private var category = "Built-in"
    @State private var importing = false
    @State private var saving = false
    @State private var gradeName = ""
    @State private var balanceOpen = false
    private var selectedID: String { model.importedLUT?.id ?? model.look.rawValue }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(model.importedLUT?.name ?? model.look.title).font(.headline).lineLimit(2)
                Spacer(minLength: 4)
                Button { model.toggleFavorite(selectedID) } label: {
                    Image(systemName: model.library.favorites.contains(selectedID) ? "star.fill" : "star").frame(width: 44, height: 44)
                }.accessibilityLabel("Favorite look").accessibilityValue(model.library.favorites.contains(selectedID) ? "On" : "Off")
                Button { importing = true } label: { Image(systemName: "square.and.arrow.down").frame(width: 44, height: 44) }
                    .accessibilityLabel("Import LUT").accessibilityIdentifier("color.import")
            }
            HStack(spacing: 12) {
                Text("Strength").font(.caption)
                Slider(value: $model.amount, in: 0...1, step: 0.01)
                    .disabled(model.look == .natural && model.importedLUT == nil).accessibilityLabel("Look strength")
                Text("\(Int(model.amount * 100))%").font(.caption.monospacedDigit()).frame(width: 35, alignment: .trailing)
            }.frame(minHeight: 32)
            if (model.logSourceCount ?? 0) > 0 || model.localRecovery > 0 {
                VStack(spacing: 4) {
                    HStack {
                        Text("Local highlight recovery").font(.subheadline)
                        Spacer(minLength: 4)
                        Button { model.localRecovery = 1 } label: {
                            Text("Natural").font(.subheadline).frame(minWidth: 44, minHeight: 44)
                        }.accessibilityLabel("Use natural highlight recovery").accessibilityIdentifier("color.recovery.natural")
                        Button { model.localRecovery = 0 } label: {
                            Text("\(Int((model.localRecovery * 100).rounded()))%")
                                .monospacedDigit().frame(minWidth: 44, minHeight: 44)
                        }.accessibilityLabel("Reset local highlight recovery")
                            .accessibilityValue("\(Int((model.localRecovery * 100).rounded()))%")
                            .accessibilityIdentifier("color.recovery.reset")
                    }
                    Slider(value: $model.localRecovery, in: 0...1, step: 0.01)
                        .accessibilityLabel("Local highlight recovery").accessibilityIdentifier("color.recovery")
                    Text((model.logSourceCount ?? 0) > 0
                         ? "Compresses bright areas while retaining texture. Applies only to Log footage."
                         : "Available for Log footage. This grade’s recovery setting is saved but does not affect this footage.")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }.disabled((model.logSourceCount ?? 0) == 0)
            }
            VStack(spacing: 4) {
                HStack {
                    Text("Highlights").font(.subheadline)
                    Spacer()
                    Button { model.highlights = 0 } label: {
                        Text(String(format: "%+.0f", model.highlights * 100)).monospacedDigit()
                            .frame(minWidth: 44, minHeight: 44)
                    }.accessibilityLabel("Reset highlights")
                        .accessibilityValue(String(format: "%+.0f", model.highlights * 100))
                        .accessibilityIdentifier("color.highlights.reset")
                }
                Slider(value: $model.highlights, in: -1...1, step: 0.01)
                    .accessibilityLabel("Highlights").accessibilityIdentifier("color.highlights")
                Text("Adjusts bright tones before the look. Move left to lower them.")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            DisclosureGroup("Exposure & white balance", isExpanded: $balanceOpen) {
                VStack(spacing: 12) {
                    adjustment("Exposure", value: $model.exposure, range: -4...4, unit: " EV")
                    adjustment("Warmth", value: $model.warmth, range: -1...1)
                    adjustment("Tint", value: $model.tint, range: -1...1)
                    Button("Reset balance") { model.exposure = 0; model.warmth = 0; model.tint = 0 }.frame(minHeight: 44)
                }.padding(.top, 12)
            }
            Picker("Library", selection: $category) {
                ForEach(["Built-in", "Imported", "Favorites", "Grades"], id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.segmented).accessibilityIdentifier("color.library")
            if category == "Grades" {
                if model.library.grades.isEmpty { Text("Save a look and its color balance to reuse on another clip.").font(.caption).foregroundStyle(.secondary) }
                ForEach(model.library.grades) { grade in
                    Button { model.selectGrade(grade.settings) } label: { Label(grade.name, systemImage: "slider.horizontal.3").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading) }
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 85), spacing: 8)], spacing: 10) {
                    if category != "Imported" {
                        ForEach(ColorLook.allCases.filter { category != "Favorites" || model.library.favorites.contains($0.rawValue) }) { look in
                            tile(look.title, id: look.rawValue) { model.importedLUT = nil; model.look = look }
                        }
                    }
                    if category != "Built-in" {
                        ForEach(model.library.imported.filter { category != "Favorites" || model.library.favorites.contains($0.id) }) { lut in
                            tile(lut.name, id: lut.id) { var settings = model.colorSettings; settings.imported = lut; model.selectGrade(settings) }
                        }
                    }
                }
                if category == "Imported", model.library.imported.isEmpty {
                    Button("Import a .cube LUT from Files") { importing = true }.frame(minHeight: 44)
                }
                if category == "Favorites", model.library.favorites.isEmpty { Text("Tap the star beside a look’s name to keep it here.").font(.caption).foregroundStyle(.secondary) }
            }
            if model.importedLUT != nil {
                Picker("LUT expects", selection: Binding(get: { model.importedLUT?.input ?? .rec709 }, set: { input in
                    model.importedLUT?.input = input
                    if let lut = model.importedLUT, let i = model.library.imported.firstIndex(where: { $0.id == lut.id }) {
                        model.library.imported[i] = lut; do { try model.library.save() } catch { model.colorError = error.localizedDescription }
                    }
                })) { ForEach(LUTInput.allCases) { Text($0.title).tag($0) } }
                Text("Choose the input specified by the LUT’s author. Output must be Rec.709. Log-to-Rec.709 LUTs include their own camera conversion.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button { gradeName = model.colorSettings.title; saving = true } label: {
                Label("Save grade", systemImage: "bookmark").frame(maxWidth: .infinity, minHeight: 44)
            }.accessibilityIdentifier("color.saveGrade")
            if let error = model.colorError {
                HStack(alignment: .top) {
                    Text(error).font(.caption).foregroundStyle(.orange)
                    Button { model.colorError = nil } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }.accessibilityLabel("Dismiss LUT message")
                }
            }
        }
        .onAppear { if model.importedLUT != nil { category = "Imported" } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "cube") ?? .data], allowsMultipleSelection: false) { result in
            switch result { case let .success(urls): if let url = urls.first { Task { await model.importLUT(url); category = "Imported" } }
            case let .failure(error): model.colorError = error.localizedDescription }
        }
        .alert("Save grade", isPresented: $saving) {
            TextField("Name", text: $gradeName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { model.saveGrade(named: gradeName) }
        } message: { Text("Saves the look, strength, highlight adjustments, exposure and white balance for other clips and projects.") }
    }
    private func tile(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    Rectangle().fill(.white.opacity(0.06))
                    if let image = model.lookThumbnails[id] { Image(uiImage: image).resizable().scaledToFill() }
                    else { Image(systemName: "photo").foregroundStyle(.secondary) }
                }.frame(height: 56).clipped().allowsHitTesting(false)
                Text(title).font(.caption).lineLimit(2).frame(maxWidth: .infinity, minHeight: 28)
            }.padding(3).background(selectedID == id ? Color.cyan.opacity(0.18) : .clear)
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(selectedID == id ? Color.cyan : .white.opacity(0.15), lineWidth: selectedID == id ? 2 : 1))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("tool.look." + id)
            .accessibilityAddTraits(selectedID == id ? .isSelected : [])
            .contextMenu { Button(model.library.favorites.contains(id) ? "Remove favorite" : "Add favorite") { model.toggleFavorite(id) } }
    }
    private func adjustment(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String = "") -> some View {
        VStack(spacing: 4) {
            HStack { Text(title); Spacer(); Text(String(format: "%+.2f", value.wrappedValue) + unit).monospacedDigit() }
            Slider(value: value, in: range, step: 0.05).accessibilityLabel(title)
        }
    }
}
