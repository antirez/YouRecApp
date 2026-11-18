import SwiftUI
import PhotosUI

struct LiveEffectsPanel: View {
    @ObservedObject var camera: CaptureController
    @Binding var path: [VideoEffectPage]
    @Binding var selected: UUID?
    let onClose:()->Void
    @State private var helpTopic: InspectorHelp?
    @State private var correctionTab=0
    @State private var correctionAdvanced=false
    @State private var media: PhotosPickerItem?
    @State private var mediaParameter: String?
    @State private var mediaPicker = false
    @State private var error: String?
    private var current: VideoEffectSettings? { camera.videoEffects.first { $0.id == selected } }
    private var frameToolActive:Bool { camera.positioningEffectID != nil || camera.effectColorPick != nil || camera.cleanPlateProgress != nil || camera.cleanPlateCountdown != nil }
    private var page: VideoEffectPage { path.last ?? (camera.videoEffects.isEmpty ? .library : .applied) }

    var body: some View {
        Group {
            if frameToolActive { frameToolStatus.recorderButtonStyle() }
            else {
                NavigationStack(path: $path) {
                    screen(camera.videoEffects.isEmpty ? .library : .applied, isRoot: true)
                        .navigationDestination(for: VideoEffectPage.self) { screen($0) }
                }
            }
        }
        .preferredColorScheme(.dark).tint(YouRecStyle.accent)
        .accessibilityAction(.escape, onClose)
        .sheet(item: $helpTopic) { InspectorHelpSheet(topic: $0) }
        .onChange(of: camera.cleanPlateCountdown) { _, count in
            if let count { UIAccessibility.post(notification: .announcement, argument: "Step out of frame. \(count)") }
        }
        .onChange(of: camera.hasActiveTake) { _, active in if active { onClose() } }
        .onChange(of: page == .inspector && current?.enabled == true ? selected : nil, initial: true) { _, id in
            camera.inspectLiveEffect(id)
        }
        .onChange(of: selected) { _, _ in camera.cancelEffectFrameTools() }
        .photosPicker(isPresented: $mediaPicker, selection: $media,
                      matching: mediaParameter == "cleanPlate" || current?.choice("background") == "Image" ? .images : .videos)
        .onChange(of: media) { _, item in if let item { Task { await importMedia(item) } } }
    }

    private func screen(_ destination: VideoEffectPage, isRoot: Bool = false) -> some View {
        Group {
            if destination == .applied {
                appliedEffects.padding(.horizontal, 16).padding(.top, 12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if camera.dualActive {
                            Text("Dolly Zoom and Crash Zoom require Single camera. Other effects apply to the composed picture.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let message = camera.effectQualityMessage {
                            Label(message, systemImage: "gauge.with.dots.needle.50percent").font(.caption).foregroundStyle(.secondary)
                        }
                        if let warning = camera.warning { Text(warning).foregroundStyle(.orange).font(.caption) }
                        if let error { Text(error).foregroundStyle(.orange).font(.caption) }
                        switch destination {
                        case .applied: appliedEffects
                        case .library: library(nil)
                        case .section(let section): library(section)
                        case .inspector:
                            if let effect = current { controls(effect) }
                        }
                    }.padding(16)
                }
                .accessibilityIdentifier("liveEffects.controls")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .recorderButtonStyle()
        .navigationTitle(title(for: destination, isRoot: isRoot)).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if destination == .applied || (destination == .inspector && !camera.showsOpticalInspector) {
                ToolbarItem(placement: .primaryAction) {
                    Button { path = [.library] } label: { Image(systemName: "plus") }
                        .buttonStyle(.automatic).tint(Color.primary)
                        .accessibilityLabel("Add effect").accessibilityIdentifier("liveEffects.browse")
                }
            } else {
                RecorderCloseToolbar(identifier: "liveEffects.done", action: onClose)
            }
            if destination == .applied {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("Clear all effects", systemImage: "trash", role: .destructive) {
                            camera.setVideoEffects([]); selected = nil; path = []
                        }
                        .accessibilityIdentifier("liveEffects.clear")
                    } label: { Image(systemName: "ellipsis") }
                    .buttonStyle(.automatic).tint(Color.primary)
                    .accessibilityLabel("Effect actions").accessibilityIdentifier("liveEffects.actions")
                }
            }
        }
    }

    private func title(for destination: VideoEffectPage, isRoot: Bool) -> String {
        switch destination {
        case .applied: return "Video effects"
        case .library: return isRoot ? "Video effects" : "Add effects"
        case .section(let section): return section.title
        case .inspector: return current?.kind.descriptor.displayName ?? "Effect"
        }
    }

    @ViewBuilder private var frameToolStatus:some View {
        if camera.positioningEffectID != nil {
            HStack(spacing:8) {
                Text(camera.effectBackgroundPlacement?.movementLocked == true ? "Pinch to make room to move" : "Drag to move · pinch to scale").font(.caption).lineLimit(2)
                Spacer(minLength:0)
                Button("Center",action:camera.resetEffectBackgroundPosition).frame(minWidth:44,minHeight:44).accessibilityHint("Resets position and zoom")
                Button("Revert") {camera.finishEffectPosition(revert:true)}.frame(minWidth:44,minHeight:44)
                Button("Done") {camera.finishEffectPosition()}.recorderButtonStyle(prominent: true).frame(minWidth:44,minHeight:44)
            }.padding(.horizontal,16).padding(.vertical,6).accessibilityElement(children:.contain).accessibilityIdentifier("liveEffects.frameToolBar")
        } else if camera.positioningEffectID != nil || camera.effectColorPick != nil || camera.cleanPlateProgress != nil || camera.cleanPlateCountdown != nil {
            HStack(spacing:12) {
                VStack(alignment:.leading,spacing:6) {
                    if camera.effectColorPick != nil { Label("Tap the color in the preview",systemImage:"eyedropper") }
                    else if let seconds=camera.cleanPlateCountdown { Text("Step out of frame: \(seconds)").monospacedDigit() }
                    else { Text("Capturing the empty screen…");ProgressView(value:camera.cleanPlateProgress ?? 0) }
                }.font(.subheadline).lineLimit(2).minimumScaleFactor(0.8)
                Spacer(minLength:0)
                Button("Cancel",action:camera.cancelEffectFrameTools).frame(minWidth:44,minHeight:44).accessibilityIdentifier("liveEffects.cancelFrameTool")
            }.padding(.horizontal,16).padding(.vertical,6).accessibilityElement(children:.contain).accessibilityIdentifier("liveEffects.frameToolBar")
        }
    }
    private func library(_ section:VideoEffectLibrarySection?)->some View {
        VideoEffectLibrary(section:section,live:true,chooseSection:{path.append(.section($0))},add:add)
    }
    private var appliedEffects:some View {
        VStack(alignment:.leading,spacing:12) {
            if camera.videoEffects.isEmpty {
                Text("No live effects.").foregroundStyle(.secondary)
                Button {path = [.library]} label: {Label("Add effect",systemImage:"plus").frame(minHeight:44)}
            } else {
                VideoEffectAppliedList(effects:VideoEffectSettings.ordered(camera.videoEffects),prefix:"liveEffects",edit:{effect in
                    selected=effect.id;path = [.inspector]
                },toggle:{effect in selected=effect.id;update {$0.enabled.toggle()}},remove:{effect in
                    camera.setVideoEffects(camera.videoEffects.filter {$0.id != effect.id});selected=camera.videoEffects.first?.id
                    if camera.videoEffects.isEmpty {path = []}
                })
            }
        }
    }
    private func controls(_ effect:VideoEffectSettings) -> some View {
        VStack(alignment:.leading,spacing:16) {

            HStack {
                Toggle("Enabled", isOn: Binding(get: { effect.enabled }, set: { enabled in update { $0.enabled = enabled } }))
                    .accessibilityIdentifier("liveEffects.enabled")
                EffectHelpButton(effect: effect.kind) { helpTopic = $0 }
            }

            if effect.kind == .autoBackground {
                Text("Keeps people in focus and replaces everything behind them. With nobody in frame, the whole image becomes the background.").font(.caption).foregroundStyle(.secondary)
            }
            if effect.kind == .chromaKey {Text(ChromaScreen.explanation).font(.caption).foregroundStyle(.secondary)}
            if effect.kind == .chromaKey && effect.toggle("personHint") {
                Text("Person hint also removes objects outside a person’s silhouette. Turn it off to keep other subjects.").font(.caption).foregroundStyle(.secondary)
            }
            if effect.kind == .crashZoom && effect.enabled {
                Button(camera.crashState == .holding ? "Return" : camera.crashState == .ready ? "Try Crash Zoom" : camera.crashState.rawValue,action:camera.triggerCrashZoom)
                    .recorderButtonStyle(prominent: true).disabled(!camera.canTriggerCrash).frame(minHeight:44)
            }
            if effect.kind == .dollyZoom && effect.enabled {
                Text(camera.dollyRangeText).font(.caption).foregroundStyle(.secondary)
                Text("Stops after \(effect.number("duration").formatted(.number.precision(.fractionLength(0...1)))) seconds. Tap again to stop sooner.").font(.caption).foregroundStyle(.secondary)
                Button(camera.dollyState.rawValue,action:camera.triggerDollyZoom).recorderButtonStyle(prominent: true)
                    .disabled(!camera.canTriggerDolly).frame(minHeight:44)
                Text(camera.dollyHint).font(.caption).foregroundStyle(.secondary)
            }
            if [.chromaKey,.autoBackground].contains(effect.kind),["Image","Video"].contains(effect.choice("background")),case .media(let file)=effect.value("media",at:0),file != nil {
                Button {Task {await camera.beginEffectBackgroundPosition(effect.id)}} label: {Label("Position in preview",systemImage:"arrow.up.and.down.and.arrow.left.and.right").frame(minHeight:44)}.accessibilityIdentifier("liveEffects.positionBackground")
            }
            if effect.kind == .kaleidoscope {
                KaleidoscopeControls(effect: effect, reset: { camera.adjustOpticalEffect($0, id: effect.id) }) { parameterControl($0, effect: effect) }
            } else if effect.kind == .rgbOffset {
                RGBOffsetPads(effect: effect, time: 0, projection: camera.splitProjection) { camera.adjustOpticalEffect($0, id: effect.id) }
                if let intensity = effect.parameters.first(where: { $0.id == "intensity" }) { parameterControl(intensity, effect: effect) }
            } else if effect.kind == .colorCorrection {
                ColorCorrectionPanel(effect:effect,includesBackground:camera.videoEffects.contains {$0.enabled && $0.kind.descriptor.family == .key},tab:$correctionTab,advanced:$correctionAdvanced) {parameter in
                    ColorCorrectionSlider(parameter:parameter,set:{set(parameter.id,$0)})
                } reset:{update {$0.parameters=VideoEffectSettings(.colorCorrection).parameters}}
            } else {
            ForEach(VideoEffectParameterSection.sections(for:effect,live:true),id:\.self) {section in
                if section == .edges {
                    DisclosureGroup(section.title) {parameterGroup(section,effect:effect)}
                } else {
                    if section != .general {Text(section.title).font(.headline).accessibilityAddTraits(.isHeader)}
                    parameterGroup(section,effect:effect)
                }
            }
            }
            if effect.kind == .negativeStrobe {
                Button { camera.previewStrobe(effect.id) } label: { Label("Try strobe", systemImage: "play.fill").frame(minHeight: 44) }
                    .disabled(!effect.enabled).accessibilityIdentifier("liveEffects.tryStrobe")
            }
            if effect.kind == .quantization {
                if effect.toggle("lockPalette") {
                    Button {camera.sampleEffectPalette(effect.id)} label: {Label("Re-sample this frame",systemImage:"arrow.clockwise").frame(minHeight:44)}.disabled(camera.effectPaletteSampling != nil)
                }
                if !effect.toggle("monochrome") {
                    Button {camera.sampleEffectPalette(effect.id,save:true)} label: {
                        Label(camera.effectPaletteSampling==effect.id ? "Sampling frame…" : "Save palette from this frame",systemImage:"eyedropper.halffull").frame(minHeight:44)
                    }.disabled(camera.effectPaletteSampling != nil)
                    if let palette=effect.palette {HStack(spacing:0) {ForEach(Array(palette.enumerated()),id:\.offset) {_,color in Color(red:color.red,green:color.green,blue:color.blue)}}.frame(height:24).clipShape(RoundedRectangle(cornerRadius:6))}
                }
            }
            if effect.choice("background")=="Video" {Text("Background sound is mixed into playback and export in the editor.").font(.caption).foregroundStyle(.secondary)}
            if effect.kind == .crashZoom { Text("Tap the subject, then use Crash zoom or a volume key. Press again to return. Original framing stays available in the editor.").font(.caption).foregroundStyle(.secondary) }
            if effect.kind == .undercranking { Text("Frame cadence is previewed live. Speed-up and mute are applied when the take opens in the editor.").font(.caption).foregroundStyle(.secondary) }
            if effect.kind == .widescreen {Text("Oval bokeh is available in the editor for imported Cinematic video.").font(.caption).foregroundStyle(.secondary)}
            Button(role:.destructive) { camera.setVideoEffects(camera.videoEffects.filter{$0.id != selected});selected=camera.videoEffects.first?.id;path = [] } label: { Label("Remove effect",systemImage:"trash").frame(minHeight:44) }
        }.tint(YouRecStyle.accent)
    }
    private func parameterGroup(_ section:VideoEffectParameterSection,effect:VideoEffectSettings)->some View {
        VStack(alignment:.leading,spacing:16) {
            ForEach(effect.parameters.filter {visible($0,effect:effect) && VideoEffectParameterSection.section($0,effect:effect)==section}) {parameter in
                parameterControl(parameter,effect:effect)
            }
        }
    }
    @ViewBuilder private func parameterControl(_ parameter:EffectParameter,effect:VideoEffectSettings)->some View {
                VStack(alignment:.leading,spacing:4) {
                    switch parameter.kind {
                    case let .slider(a,b,_,step):
                        if case .number(let value)=parameter.value {
                            let label = effect.kind == .kaleidoscope ? KaleidoscopePose.display(parameter.id, value)
                                : parameter.id == "intensity" ? "\(Int(value*100))%" : value.formatted(.number.precision(.fractionLength(0...2)))
                            HStack { Text(parameter.title); Spacer(); Text(label).monospacedDigit().foregroundStyle(.secondary) }.font(.subheadline)
                            Slider(value: Binding(get: { value }, set: { set(parameter.id, .number($0)) }), in: a...b, step: step)
                                .frame(minHeight: 36).accessibilityLabel(parameter.title).accessibilityValue(label)
                        }
                    case .toggle:
                        if case .toggle(let value)=parameter.value { Toggle(parameter.title,isOn:Binding(get:{value},set:{set(parameter.id,.toggle($0))})).frame(minHeight:44) }
                    case .picker(let options,_):
                        if case .choice(let value)=parameter.value {
                            HStack {
                                Text(parameter.title); Spacer()
                                Menu(value) {
                                    ForEach(VideoEffectParameterVisibility.choices(parameter,effect:effect),id: \.self) { item in
                                        Button { set(parameter.id,.choice(item)) } label: {
                                            if item == value { Label(item,systemImage:"checkmark") } else { Text(item) }
                                        }
                                    }
                                }
                            }.frame(minHeight:44)
                        }
                    case .stepper(let values,_):
                        if case .number(let value)=parameter.value {
                            Text(parameter.title).font(.subheadline)
                            VideoEffectNumberChoices(title:parameter.title,values:values,selected:value) {set(parameter.id,.number($0))}
                        }
                    case .color:
                        if case .color(let value)=parameter.value {
                            if parameter.id=="screenColor" {
                                ChromaScreenControl(color:value,choose:{set(parameter.id,.color($0))},pick:{camera.beginEffectColorPick(effect.id,parameter:parameter.id)})
                            } else if effect.kind == .colorIsolation && parameter.id=="color" {
                                HStack {Text("Hue");Spacer();Circle().fill(Color(hue:IsolationHue.degrees(value)/360,saturation:1,brightness:1)).frame(width:24,height:24).accessibilityHidden(true)}
                                Slider(value:Binding(get:{IsolationHue.degrees(value)},set:{set(parameter.id,.color(IsolationHue.color($0)))}),in:0...359,step:1).accessibilityLabel("Hue")
                                if !IsolationHue.accepts(value) {Text(IsolationHue.invalidSample).font(.caption).foregroundStyle(.orange)}
                            } else {
                            ColorPicker(parameter.title,selection:Binding(get:{Color(red:value.red,green:value.green,blue:value.blue)},set:{ color in
                                var r:CGFloat=0,g:CGFloat=0,b:CGFloat=0,a:CGFloat=0
                                if UIColor(color).getRed(&r,green:&g,blue:&b,alpha:&a) { set(parameter.id,.color(EffectRGB(r,g,b))) }
                            }),supportsOpacity:false).frame(minHeight:44)
                            }
                            if effect.kind == .colorIsolation && parameter.id=="color" {
                                Button { camera.beginEffectColorPick(effect.id,parameter:parameter.id) } label: { Label("Pick from preview",systemImage:"eyedropper").frame(minHeight:44) }.accessibilityIdentifier("liveEffects.pickColor")
                            }
                        }
                    case .media:
                        if parameter.id=="cleanPlate" {
                            Text("For a cleaner key, capture the empty screen: a 3-second countdown, then 1 second of capture.").font(.caption).foregroundStyle(.secondary)
                            Button { camera.captureCleanPlate(effect.id) } label: { Label("Capture empty screen",systemImage:"camera.viewfinder").frame(minHeight:44) }.disabled(camera.cleanPlateProgress != nil).accessibilityIdentifier("liveEffects.capturePlate")
                            if case .media(let file)=parameter.value,let file {
                                HStack {
                                    Label("Empty-screen image set",systemImage:"checkmark.circle").font(.caption).foregroundStyle(.mint)
                                    Spacer();Button("Remove") { set(parameter.id,.media(nil)) }.frame(minHeight:44)
                                }
                                if let size=VideoEffectCleanPlate.size(at:LiveVideoEffects.folder.appendingPathComponent(file)),!VideoEffectCleanPlate.compatible(size,with:camera.effectFrameSize) {
                                    Text("This reference does not match the video framing. Capture again; the screen color is used meanwhile.").font(.caption).foregroundStyle(.orange)
                                } else { Text("Capture again after changing the lens, zoom or camera position.").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        Button { mediaParameter=parameter.id;mediaPicker=true } label: { Label(parameter.title,systemImage:"photo.on.rectangle").frame(minHeight:44) }
                    }
                }
    }
    private func visible(_ parameter:EffectParameter,effect:VideoEffectSettings)->Bool {
        VideoEffectParameterVisibility.visible(parameter,effect:effect,live:true)
    }
    private func update(_ body:(inout VideoEffectSettings)->Void) {
        var effects=camera.videoEffects;guard let index=effects.firstIndex(where:{$0.id == selected}) else{return}
        body(&effects[index]);effects[index].sanitizeBackgroundMedia(at:0);camera.setVideoEffects(effects)
    }
    private func set(_ id:String,_ value:EffectValue) {
        if id == "sourceAngle", let effect = current, effect.kind == .kaleidoscope, case .number(let degrees) = value {
            camera.adjustOpticalEffect([id: degrees], id: effect.id)
            return
        }
        if id=="lockPalette",value == .toggle(true),let selected {camera.sampleEffectPalette(selected);return}
        let resample=id=="colors" && current?.toggle("lockPalette")==true
        update {effect in effect.set(id,value);if id=="screenColor" {effect.set("autoScreen",.toggle(false));effect.set("screenType",.choice("Auto"))}}
        if resample,let selected {camera.sampleEffectPalette(selected)}
    }
    private func add(_ kind:VideoEffectID) {
        if [.crashZoom,.dollyZoom].contains(kind),let existing=camera.videoEffects.first(where:{$0.kind==kind}) { selected=existing.id;path = [.inspector];return }
        var effect = VideoEffectSettings(kind)
        if kind == .negativeStrobe { effect.set("timedBurst", .toggle(true)) }
        camera.setVideoEffects(camera.videoEffects + [effect])
        selected = effect.id; path = [.inspector]
    }
    private func importMedia(_ item:PhotosPickerItem) async {
        guard let parameter=mediaParameter else{return}
        let target=selected
        do {
            let filename:String
            let isMovie=item.supportedContentTypes.contains(where:{$0.conforms(to:.movie)})
            guard parameter != "cleanPlate" || !isMovie else { throw ProjectError.invalidMedia }
            if isMovie {
                guard let video=try await item.loadTransferable(type:ImportedPhotoMedia.self), !video.isPhoto else{throw ProjectError.invalidMedia}
                defer{try? FileManager.default.removeItem(at:video.url)}
                filename="effect-"+UUID().uuidString+".mov";try FileManager.default.copyItem(at:video.url,to:LiveVideoEffects.folder.appendingPathComponent(filename))
            } else {
                guard let data=try await item.loadTransferable(type:Data.self) else{throw ProjectError.missingImage}
                let png=try VideoEffectCleanPlate.importedPNG(data,matching:parameter=="cleanPlate" ? camera.effectFrameSize : nil)
                filename="effect-"+UUID().uuidString+".png";try png.write(to:LiveVideoEffects.folder.appendingPathComponent(filename),options:.atomic)
            }
            guard selected==target else { return }
            if parameter=="media" { update { $0.set("background",.choice(isMovie ? "Video" : "Image")) } }
            set(parameter,.media(filename));media=nil
        } catch { self.error=error.localizedDescription }
    }
}
