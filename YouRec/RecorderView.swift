import SwiftUI
import AVFoundation

private struct RecordingColorControls: View {
    @ObservedObject var camera: CaptureController

    private var note: String {
        if camera.hasActiveTake {
            return camera.dualActive ? "Two cameras record in SDR. Pause to change the pair or stabilization." :
                "Pause to change recording color, stabilization or the two-camera setup."
        }
        if camera.dualActive { return "Two-camera recording uses SDR." }
        if !camera.ready { return "Recording color is available when the camera is ready." }
        if let log = camera.activeLog { return "\(log.title) · 10-bit HEVC for grading. The preview uses a viewing conversion." }
        if !camera.hdrSupported && !camera.logSupported { return "This camera setup supports SDR only." }
        if !camera.logSupported { return "Log is unavailable with this camera setup." }
        return camera.hdrActive ? "HDR keeps more highlight and color detail." : "SDR is ready to share on any display."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recording color").font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
            HStack(spacing: 3) {
                ForEach(CaptureColorMode.allCases) { mode in
                    let selected = mode == camera.activeColorMode
                    let supported = mode == .sdr || (mode == .hdr ? camera.hdrSupported : camera.logSupported)
                    let enabled = camera.ready && !camera.dualActive && !camera.hasActiveTake && !camera.switchingCamera && supported
                    Button { if !selected { camera.setColorMode(mode) } } label: {
                        Text(mode.title).font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundStyle(selected ? .black : enabled ? Color.primary : .secondary)
                            .background(selected ? Color.cyan : .clear, in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(!enabled)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("recorder.color." + mode.rawValue)
                }
            }.padding(3).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
            Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Footage is the entire recorder. Everything else is a lightweight overlay;
/// secondary controls live in the drawer, without taking space from the preview.
struct RecorderView: View {
    @State private var recordingAudioOpen = false
    @State private var dualLayoutEditing = false
    @State private var frontLightEnabled = false
    @ObservedObject var camera: CaptureController
    let project: Project?
    let start: () -> Void
    let startNewProject: () -> Void
    let openProjects: () -> Void
    let openEditor: () -> Void
    var insertionPosition: Double? = nil
    @AppStorage("fitRecordedFrame") private var fitRecordedFrame = true
    @State private var settingsOpen = false
    @State private var adjustingHorizon = false
    @State private var zoomOpen = false
    @State private var apertureOpen = false
    @State private var effectsOpen = false
    @State private var effectsExpanded = false
    @State private var bookmarkAcknowledged = false
    @State private var controlsOrientation: UIInterfaceOrientation = .unknown
    @Environment(\.scenePhase) private var scenePhase
    private var controlPlate: Color { frontLightEnabled ? Color(white: 0.14) : .black.opacity(0.52) }
    private var bookmarkButton: some View {
        Button {
            camera.addBookmark(); bookmarkAcknowledged = true
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            VStack(spacing: 3) {
                Image(systemName: bookmarkAcknowledged ? "bookmark.fill" : "bookmark").font(.system(size: 20))
                Text("Mark").font(.system(size: 11, weight: .semibold))
            }.frame(width: 52, height: 52).background(controlPlate, in: RoundedRectangle(cornerRadius: 15))
                .contentShape(Rectangle())
        }.accessibilityLabel("Add recording bookmark").accessibilityIdentifier("recorder.bookmark")
            .accessibilityValue(bookmarkAcknowledged ? "Bookmark added" : "Mark this moment")
            .disabled(!recording)
            .task(id: bookmarkAcknowledged) {
                if bookmarkAcknowledged { try? await Task.sleep(for: .milliseconds(700)); bookmarkAcknowledged = false }
            }
    }
    @ScaledMetric(relativeTo:.body) private var frameToolHeight = 76.0
    private var frameToolActive:Bool { camera.positioningEffectID != nil || camera.effectColorPick != nil || camera.cleanPlateProgress != nil || camera.cleanPlateCountdown != nil }
    private var outsideTapClosesEffects: Bool {
        guard effectsOpen, !frameToolActive else { return false }
        switch camera.inspectedLiveEffect?.kind {
        case .kaleidoscope: return false
        case .crashZoom: return !camera.crashAvailable || camera.crashState != .ready
        case .dollyZoom: return !camera.dollyAvailable || camera.dollyState.moving
        default: return true
        }
    }
    private func closeEffects() { effectsOpen = false }
    private let red = Color(red: 1, green: 0.25, blue: 0.29)
    private let pictureClearance: CGFloat = 12
    private let shutterSize: CGFloat = 88
    /// Keep a group in the safe letterbox if it fits, otherwise put it inside the picture.
    private func controlInset(gutter: CGFloat, extent: CGFloat, margin: CGFloat) -> CGFloat {
        if gutter >= margin + extent + pictureClearance { return margin }
        return max(margin, ceil(gutter + pictureClearance))
    }
    private var crashControl:some View {
        Button(action:camera.triggerCrashZoom) {
            Label(camera.crashState == .holding ? "Return" : camera.crashState == .ready ? "Crash zoom" : camera.crashState.rawValue,
                  systemImage:camera.crashState == .holding ? "arrow.down.right.and.arrow.up.left" : "viewfinder")
                .font(.subheadline.weight(.semibold)).padding(.horizontal,16).frame(minHeight:48)
                .background(.black.opacity(0.65),in:Capsule()).overlay(Capsule().strokeBorder(.white.opacity(0.3)))
        }.foregroundStyle(.white).disabled(!camera.canTriggerCrash).accessibilityIdentifier("recorder.crashZoom")
    }
    private var cameraEffectControls:some View {
        VStack(spacing:4) {
            HStack(spacing:8) {
                if camera.dollyAvailable {
                    Button(action:camera.triggerDollyZoom) {
                        Label(camera.dollyState.rawValue,systemImage:camera.dollyState.moving ? "stop.circle" : "viewfinder")
                            .font(.subheadline.weight(.semibold)).padding(.horizontal,16).frame(minHeight:48)
                            .background(.black.opacity(0.65),in:Capsule()).overlay(Capsule().strokeBorder(.white.opacity(0.3)))
                    }.disabled(!camera.canTriggerDolly).accessibilityIdentifier("recorder.dollyZoom")
                }
                if camera.crashAvailable { crashControl }
            }
            if camera.dollyAvailable {
                if camera.dollyState.moving {
                    ProgressView(value:camera.dollyHeadroom).tint(.yellow).frame(width:120).accessibilityLabel("Dolly zoom room remaining")
                }
                Text(camera.dollyHint).font(.caption2).lineLimit(2).multilineTextAlignment(.center)
                    .padding(.horizontal,10).padding(.vertical,3).background(.black.opacity(0.55),in:Capsule())
            }
        }
    }
    private var recording: Bool { camera.state == .recording }
    private var keepFraming: Bool { camera.hasActiveTake || camera.state == .paused }
    private var orientation: UIInterfaceOrientation {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.interfaceOrientation ?? .portrait
    }

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            let insets = geometry.safeAreaInsets
            let roundedPhone = max(insets.leading, insets.trailing, insets.bottom) >= 20
            let cornerRadius: CGFloat = roundedPhone ? max(40, insets.top - 4, insets.leading - 4, insets.trailing - 4) : 4
            // Interface landscapeLeft puts the hardware top (both cameras) on
            // the right. Keep the capture controls at the opposite, bottom end.
            let controlsOnLeft = (controlsOrientation.isLandscape == landscape ? controlsOrientation : orientation) == .landscapeLeft
            let toolHeight=min(frameToolHeight,geometry.size.height*0.4)
            let optical = effectsOpen && camera.showsOpticalInspector && !frameToolActive
            let inspectorWidth = min(360, geometry.size.width * 0.45)
            let inspectorHeight = optical ? min(340, geometry.size.height * 0.45) :
                min(geometry.size.height, effectsExpanded ? geometry.size.height * 0.85 : 340)
            let sideInset = optical && landscape ? inspectorWidth + 12 : 0
            let bottomInset = frameToolActive ? toolHeight + 16 : optical && !landscape ? inspectorHeight + 12 : 0
            let previewSpace = CGSize(width: max(1, geometry.size.width - sideInset),
                                      height: max(1, geometry.size.height - bottomInset))
            let fitsFrame = camera.dualActive || frameToolActive || optical || fitRecordedFrame || camera.frontLandscape
            let interfaceCanvas = CGSize(width: landscape ? 16 : 9, height: landscape ? 9 : 16)
            // The dual compositor follows the interface while framing is unlocked.
            // Size the viewport in the layout pass that turns the controls.
            let fitCanvas = camera.dualActive && !keepFraming ? interfaceCanvas : camera.previewLayoutCanvas ?? interfaceCanvas
            let wideFrame = AVMakeRect(aspectRatio: fitCanvas, insideRect: CGRect(origin: .zero, size: previewSpace))
            // The picture is centered on the full display, while the controls
            // are laid out in the safe area. Express its edges in control coordinates.
            let picture = wideFrame.offsetBy(dx: (insets.trailing - insets.leading) / 2,
                                             dy: (insets.bottom - insets.top) / 2)
            let toolbarHeight: CGFloat = 44
            let toolbarTop = controlInset(gutter: fitsFrame ? picture.minY : 0, extent: toolbarHeight, margin: pictureClearance)
            let abovePicture = fitsFrame && toolbarTop + toolbarHeight <= picture.minY - pictureClearance
            let captureGutter = landscape
                ? (controlsOnLeft ? picture.minX : geometry.size.width - picture.maxX)
                : geometry.size.height - picture.maxY
            let captureInset = controlInset(gutter: fitsFrame ? captureGutter : 0, extent: shutterSize, margin: landscape ? 18 : 14)
            ZStack {
                CameraPreview(camera: camera, fill: !fitsFrame, dismissEffects: outsideTapClosesEffects ? closeEffects : nil)
                    .frame(width: optical ? previewSpace.width : fitsFrame ? wideFrame.width : nil,
                           height: optical ? previewSpace.height : fitsFrame ? wideFrame.height : nil)
                    .overlay {
                        if optical, let split = camera.inspectedLiveEffect, split.kind == .kaleidoscope {
                            KaleidoscopeGuide(pose: KaleidoscopePose(split), divisions: Int(split.number("divisions")),
                                              projection: { _ in camera.splitProjection }) { pose, target in
                                camera.adjustOpticalEffect(pose.parameters(for: target), id: split.id)
                            }
                        }
                        if !effectsOpen && camera.dualActive && camera.positioningEffectID == nil && camera.effectColorPick == nil && (dualLayoutEditing || camera.dualLayout.mode != .floating) { DualLayoutOverlay(camera: camera, showHandles: dualLayoutEditing) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background {
                        if outsideTapClosesEffects {
                            Color.black.onTapGesture(perform: closeEffects).accessibilityHidden(true)
                        } else { Color.black }
                    }
                    .ignoresSafeArea().padding(.bottom, bottomInset)
                    .padding(controlsOnLeft ? .leading : .trailing, sideInset)
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.32), location: 0),
                    .init(color: .clear, location: 0.16),
                    .init(color: .clear, location: 0.8),
                    .init(color: .black.opacity(0.36), location: 1)
                ], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea().allowsHitTesting(false)

                if frontLightEnabled {
                    RecorderFrontLight(cornerRadius: cornerRadius, controlsOnLeft: controlsOnLeft,
                                       turnOff: { frontLightEnabled = false })
                        .ignoresSafeArea()
                }

                Group {
                if landscape {
                    HStack(alignment: .center, spacing: 16) {
                        if controlsOnLeft { captureRail }
                        VStack {
                            GeometryReader { slot in
                                let row = slot.frame(in: .named("recorderControls"))
                                let overPicture = fitsFrame && !abovePicture
                                ViewThatFits(in: .horizontal) {
                                    topBar(compact: false)
                                        .padding(.leading, overPicture ? max(0, picture.minX + pictureClearance - row.minX) : 0)
                                        .padding(.trailing, overPicture ? max(0, row.maxX - picture.maxX + pictureClearance) : 0)
                                    topBar(compact: true)
                                }
                            }.frame(height: toolbarHeight)
                            if camera.effectThermalWarning { effectThermalBanner.padding(.top,8) }
                            if let warning = camera.warning { warningBanner(warning).padding(.top, 8) }
                            Spacer()
                            projectChip
                            if camera.crashAvailable || camera.dollyAvailable { cameraEffectControls }
                            if zoomOpen && !camera.dualActive { zoomPresets.padding(.bottom, 8) }
                            if apertureOpen && camera.apertureAvailable { aperturePresets.padding(.bottom, 8) }
                            cameraStrip
                        }.padding(.top, toolbarTop).padding(.bottom, 12)
                        if !controlsOnLeft { captureRail }
                    }.padding(.horizontal, captureInset)
                } else {
                    VStack(spacing: 0) {
                        topBar(compact: true)
                        if camera.effectThermalWarning { effectThermalBanner.padding(.top,8) }
                        if let warning = camera.warning { warningBanner(warning).padding(.top, 12) }
                        Spacer(minLength: 12)
                        projectChip.padding(.bottom, 6)
                        if camera.crashAvailable || camera.dollyAvailable { cameraEffectControls.padding(.bottom,6) }
                        if zoomOpen && !camera.dualActive { zoomPresets.padding(.bottom, 10) }
                        if apertureOpen && camera.apertureAvailable { aperturePresets.padding(.bottom, 10) }
                        cameraStrip.padding(.bottom, 22)
                        HStack {
                            projectOrMarkButton.frame(maxWidth: .infinity)
                            recordButton.frame(width: shutterSize)
                            secondaryButton.frame(maxWidth: .infinity)
                        }
                        .padding(.bottom, captureInset)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, toolbarTop)
                }
                }.opacity(effectsOpen || adjustingHorizon ? 0 : 1).allowsHitTesting(!effectsOpen && !adjustingHorizon)
            }
            .overlay(alignment: landscape && !frameToolActive ? (controlsOnLeft ? .leading : .trailing) : .bottom) {
                if effectsOpen {
                    LiveEffectsPanel(camera:camera,expanded:$effectsExpanded,canExpand:!landscape && !frameToolActive && !optical,onClose:closeEffects)
                        .frame(width:frameToolActive ? min(520,geometry.size.width) : landscape ? inspectorWidth : geometry.size.width,
                               height:frameToolActive ? toolHeight : landscape ? geometry.size.height : inspectorHeight)
                        .background(Color(white:0.06),in:RoundedRectangle(cornerRadius:20))
                        .clipShape(RoundedRectangle(cornerRadius:20))
                        .overlay(RoundedRectangle(cornerRadius:20).strokeBorder(.white.opacity(0.12)))
                        .shadow(color:.black.opacity(0.35),radius:16)
                        .padding(landscape && !frameToolActive ? (controlsOnLeft ? .leading : .trailing) : .bottom,8)
                }
            }
            .background(.black)
            .background(RecorderOrientationReader { value, duration in
                #if DEBUG
                if let duration { camera.probeInterfaceTurn(to: value, duration: duration) }
                #endif
                guard controlsOrientation != value else { return }
                controlsOrientation = value
                if !keepFraming && !camera.frontLandscape {
                    camera.setOrientation(value)
                    evaluateCameraTurn(current: value)
                }
            }.allowsHitTesting(false))
            .overlay {
                if recording || camera.state == .paused {
                    let color = recording ? red.opacity(0.85) : .yellow.opacity(0.75)
                    Group {
                        if #available(iOS 26, *) {
                            ConcentricRectangle(corners: .concentric(minimum: .fixed(cornerRadius))).stroke(color, lineWidth: 2)
                        } else {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(color, lineWidth: 2)
                        }
                    }.padding(3).ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
                }
                if !effectsOpen && camera.dualActive && dualLayoutEditing {
                    VStack {
                        HStack(spacing: 4) {
                            ForEach(DualCameraLayout.Mode.allCases) { mode in
                                Button { var value = camera.dualLayout; value.mode = mode; camera.updateDualLayout(value) } label: {
                                    Image(systemName: mode.icon).font(.title3).frame(width: 48, height: 44)
                                        .background(camera.dualLayout.mode == mode ? .cyan.opacity(0.4) : .clear, in: RoundedRectangle(cornerRadius: 10))
                                }.accessibilityLabel(mode.title).accessibilityIdentifier("recorder.layout." + mode.rawValue)
                            }
                            Button("Done") { dualLayoutEditing = false }.font(.subheadline.weight(.semibold)).frame(minWidth: 48, minHeight: 44)
                        }.padding(4).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                        if camera.dualLayout.mode == .floating {
                            HStack(spacing: 4) {
                                ForEach([false, true], id: \.self) { round in
                                    Button {
                                        var value = camera.dualLayout; value.roundInset = round; camera.updateDualLayout(value)
                                    } label: {
                                        Label(round ? "Circle" : "Rectangle", systemImage: round ? "circle" : "rectangle")
                                            .font(.subheadline).padding(.horizontal, 12).frame(minHeight: 44)
                                            .background(camera.dualLayout.isRound == round ? .cyan.opacity(0.4) : .clear, in: RoundedRectangle(cornerRadius: 10))
                                    }.accessibilityIdentifier("recorder.insetShape." + (round ? "circle" : "rectangle"))
                                }
                            }.padding(4).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                        }
                        Text(dualLayoutHint)
                            .font(.caption).padding(6).background(.black.opacity(0.65), in: Capsule())
                        Spacer()
                    }.padding(.top, toolbarTop + toolbarHeight + 8)
                }
            }
            .coordinateSpace(name: "recorderControls")
            .foregroundStyle(.white)
            .buttonStyle(.plain)
            .accessibilityHidden(settingsOpen)
            .overlay {
                if settingsOpen {
                    CameraSettings(camera: camera, frontLightEnabled: $frontLightEnabled, adjustingHorizon: $adjustingHorizon, project: project,
                                   landscape: landscape, close: { settingsOpen = false })
                }
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onChange(of: camera.dualActive) { _, active in
            if active { zoomOpen = false; apertureOpen = false } else { dualLayoutEditing = false }
        }
        .onChange(of: zoomOpen) { _, open in if open { apertureOpen = false } }
        .onChange(of: apertureOpen) { _, open in if open { zoomOpen = false } }
        .onChange(of: camera.cameraID) { _, _ in apertureOpen = false }
        .onChange(of: camera.apertureAvailable) { _, available in if !available { apertureOpen = false } }
        .onChange(of:camera.positioningEffectID) { _,id in if id != nil {effectsExpanded=false} }
        .onChange(of:camera.effectColorPick) { _,id in if id != nil { effectsExpanded=false } }
        .onChange(of:camera.cleanPlateProgress) { _,progress in if progress != nil { effectsExpanded=false } }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            if scenePhase == .active { evaluateCameraTurn() }
        }
        .onChange(of: scenePhase) { _, phase in
            guard !keepFraming && !camera.frontLandscape else { return }
            // Control Center may change Portrait Orientation Lock while covering the camera.
            if phase == .inactive { RecordingAppDelegate.setOrientationLock(nil, animated: false) }
            if phase == .active { evaluateCameraTurn() }
        }
        .onChange(of: keepFraming || camera.frontLandscape) { _, locked in
            if locked {
                camera.rememberFramingOrientation(orientation)
                RecordingAppDelegate.setOrientationLock(orientation, animated: false)
            } else { evaluateCameraTurn() }
        }
        .onDisappear {
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
            RecordingAppDelegate.setOrientationLock(nil)
        }
        .onAppear {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            if keepFraming || camera.frontLandscape {
                RecordingAppDelegate.setOrientationLock(camera.interfaceOrientation, animated: false)
            } else {
                camera.setOrientation(orientation)
                evaluateCameraTurn()
            }
        }
    }

    private func evaluateCameraTurn(current acceptedOrientation: UIInterfaceOrientation? = nil) {
        guard !keepFraming && !camera.frontLandscape else { return }
        let current = acceptedOrientation ?? orientation
        let candidate: UIInterfaceOrientation
        switch UIDevice.current.orientation {
        case .unknown:
            // Motion can be unavailable at launch. Pinning the initial portrait
            // window then prevents UIKit from delivering its first landscape turn.
            RecordingAppDelegate.setOrientationLock(nil, animated: false)
            return
        case .landscapeLeft: candidate = .landscapeRight
        case .landscapeRight: candidate = .landscapeLeft
        case .portrait: candidate = .portrait
        default: candidate = current
        }
        // Hold the accepted interface orientation between turns. Opening the mask
        // lets UIKit evaluate the new posture without its whole-window spin. UIKit
        // still chooses the orientation, including when the user has locked it.
        RecordingAppDelegate.setOrientationLock(candidate == current ? current : nil, animated: false)
    }

    private var dualLayoutHint: String {
        switch camera.dualLayout.mode {
        case .diagonal: "Tap divider to flip · Two fingers to pan or zoom"
        case .floating: camera.dualLayout.isRound ? "Drag to move · Pinch to resize" : "Drag to move · Pinch across to reshape"
        default: "Drag divider · Two fingers to pan or zoom"
        }
    }

    @ViewBuilder private var projectChip: some View {
        if let position = insertionPosition {
            projectAction("Insert at " + editorTime(position) + " · Back to edit", icon: "arrow.uturn.backward", action: openEditor)
                .disabled(camera.hasActiveTake)
                .accessibilityLabel("Finish insertion and return to editor")
                .accessibilityIdentifier("recorder.finishInsertion")
        } else if let project, project.hasSourceMedia, !camera.hasActiveTake {
            projectAction("Start new project", icon: "plus", action: startNewProject)
                .accessibilityHint("Leave \(project.title) and record into a new empty project.")
                .accessibilityIdentifier("recorder.newProject")
        }
    }

    private func projectAction(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .lineLimit(1).font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10).frame(minHeight: 32)
                .background(.black.opacity(0.28), in: Capsule())
                .frame(minHeight: 44)
        }
    }

    private var captureRail: some View {
        VStack(spacing: 24) { projectOrMarkButton; recordButton; secondaryButton }
    }
    @ViewBuilder private var projectOrMarkButton: some View {
        if keepFraming { bookmarkButton } else { libraryButton }
    }

    private var effectThermalBanner:some View {
        Label("iPhone is warm · adaptive preview",systemImage:"thermometer.medium")
            .font(.caption).padding(.horizontal,12).padding(.vertical,7).background(.black.opacity(0.65),in:Capsule())
            .accessibilityHint(camera.effectQualityMessage ?? "")
    }
    private func topBar(compact: Bool) -> some View {
        let plate = controlPlate
        let activePlate = Color(red: 0.06, green: 0.26, blue: 0.31).opacity(frontLightEnabled ? 1 : 0.85)
        let hasFootage = project?.hasSourceMedia == true
        let clockPlate: Color
        if recording { clockPlate = red.opacity(0.8) }
        else if hasFootage && !camera.busy { clockPlate = Color(red: 0.59, green: 0.11, blue: 0.16) }
        else { clockPlate = camera.state == .paused ? .black.opacity(0.65) : plate }
        let projectDuration = project?.edit.duration ?? 0
        return HStack(spacing: compact ? 4 : 8) {
            Button { recordingAudioOpen = true            } label: {
                VStack(spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: camera.microphoneID.isEmpty ? "mic.slash.fill" : "mic.fill")
                        if !compact {
                            Text(camera.microphoneID.isEmpty ? "No microphone" : camera.microphoneName.replacingOccurrences(of: "Microphone", with: "Mic"))
                                .font(.system(size: 12, weight: .medium)).lineLimit(1).frame(maxWidth: 96)
                        }
                        RecorderMicrophoneReadings(readings: camera.readings, hasMicrophone: !camera.microphoneID.isEmpty,
                                                   ready: camera.ready, meterAvailable: camera.meterAvailable)
                    }
                    if compact {
                        Text(camera.microphoneID.isEmpty ? "No microphone" : camera.microphoneName.replacingOccurrences(of: "Microphone", with: "Mic").replacingOccurrences(of: "Microfono", with: "Mic"))
                            .font(.system(size: 9, weight: .medium)).lineLimit(1).frame(width: 64)
                    }
                }.font(.caption).padding(.horizontal, compact ? 6 : 10).frame(height: 44)
                    .background(camera.microphoneID.isEmpty && !frontLightEnabled ? .orange.opacity(0.22) : plate, in: Capsule())
                    .foregroundStyle(camera.microphoneID.isEmpty ? .orange : .white)
            }
            .disabled(camera.busy)
            .popover(isPresented: $recordingAudioOpen) {
                RecordingAudioControls(camera: camera, readings: camera.readings)
                    .presentationCompactAdaptation(.popover)
            }
            .accessibilityIdentifier("recorder.microphone")
            .accessibilityLabel("Microphone: \(camera.microphoneName)").accessibilityValue(camera.microphoneName)
            Spacer(minLength: 4)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = camera.startedAt.map { max(0, context.date.timeIntervalSince($0)) } ?? 0
                let duration = recorderClock(projectDuration + elapsed)
                HStack(spacing: 7) {
                    if camera.busy { ProgressView().tint(.white).scaleEffect(0.7) }
                    else if recording && !compact { Text("REC").font(.system(size: 10, weight: .bold)).foregroundStyle(.white) }
                    else if camera.state == .paused {
                        if compact { Image(systemName: "pause.fill").font(.caption2).foregroundStyle(.yellow) }
                        else { Text("PAUSED").font(.system(size: 10, weight: .bold)).foregroundStyle(.yellow) }
                    }
                    Text(camera.busy ? camera.state.rawValue : duration)
                        .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                .frame(minWidth: compact ? 52 : 80, minHeight: 38)
                .padding(.horizontal, compact ? 6 : 10)
                .background(clockPlate, in: Capsule())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(hasFootage && camera.state == .idle ? "Ready to continue recording" : camera.state.rawValue)
                .accessibilityValue(camera.busy ? "" : duration)
                .accessibilityIdentifier("recorder.projectDuration")
            }
            Spacer(minLength: 4)
            Button { effectsOpen=true } label: {
                Image(systemName:"sparkles").font(.system(size:18,weight:.medium)).frame(width:44,height:44)
                    .background(camera.videoEffects.contains(where: \.enabled) ? activePlate : plate, in: Circle())
            }.disabled(camera.hasActiveTake).accessibilityLabel("Live video effects").accessibilityValue(camera.effectQualityMessage == nil ? "Full quality" : "Adaptive quality").accessibilityIdentifier("recorder.videoEffects")
            Button { dualLayoutEditing = false; settingsOpen = true } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 18, weight: .medium))
                    .frame(width: 44, height: 44)
                    .background(camera.dualActive ? activePlate : plate, in: Circle())
                    .foregroundStyle(camera.dualActive ? .cyan : .white)
                    .overlay(alignment: .bottomTrailing) {
                        if !camera.dualActive && (frontLightEnabled || camera.faceFollowEnabled || camera.singleStabilizationActive || (camera.horizonEnabled && camera.horizonUsesRear)) {
                            Circle().fill(.cyan).frame(width: 6, height: 6).padding(7)
                        }
                    }
            }.accessibilityLabel("Camera settings")
                .accessibilityValue((camera.dualActive ? "Two cameras, " : "Single camera, ") + camera.activeColorMode.title)
                .accessibilityIdentifier("recorder.settings")
        }
    }
    private var cameraStrip: some View {
        HStack(spacing: 6) {
            if camera.dualActive {
                Button { var value = camera.dualLayout; value.swapped.toggle(); camera.updateDualLayout(value) } label: {
                    Image(systemName: "arrow.triangle.swap").font(.title3).frame(width: 44, height: 44)
                }.accessibilityLabel("Swap cameras").accessibilityIdentifier("recorder.dualSwap")
                Button { dualLayoutEditing.toggle() } label: {
                    Label("Layout", systemImage: camera.dualLayout.mode.icon).font(.subheadline).padding(.horizontal, 8).frame(minHeight: 44)
                        .background(dualLayoutEditing ? .cyan.opacity(0.3) : .clear, in: Capsule())
                }.accessibilityIdentifier("recorder.dualLayout")
            } else {
            Button { camera.flipCamera() } label: {
                Image(systemName: "camera.rotate").font(.system(size: 18, weight: .medium))
                    .frame(width: 44, height: 44)
            }
            .disabled(!camera.ready || camera.busy || camera.switchingCamera || camera.oppositeCamera == nil)
            .accessibilityIdentifier("recorder.flip")
            .accessibilityLabel("Switch to \(camera.oppositeCamera?.front == true ? "front" : "back") camera")
            .accessibilityValue(camera.oppositeCamera?.name ?? "Unavailable")
            Menu {
                ForEach(camera.cameras) { choice in
                    if choice.supportsLandscape {
                        cameraChoice(choice, landscape: false)
                        cameraChoice(choice, landscape: true)
                    } else { cameraChoice(choice) }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(camera.frontLandscape ? "Front · 16:9" : (camera.cameras.first(where: { $0.id == camera.cameraID })?.name.replacingOccurrences(of: "Rear ", with: "").capitalized ?? "Camera"))
                        .lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }.font(.system(size: 13, weight: .semibold)).padding(.trailing, 8).frame(minWidth: 64, maxWidth: 118, minHeight: 44)
            }.disabled(!camera.ready || camera.busy || camera.switchingCamera)
                .menuOrder(.fixed)
                .accessibilityIdentifier("recorder.camera").accessibilityLabel("Camera")
                .accessibilityValue(selectedCameraName)
            Rectangle().fill(.white.opacity(0.2)).frame(width: 1, height: 16)
            RecorderZoomButton(camera: camera, readings: camera.readings, open: $zoomOpen)
            Rectangle().fill(.white.opacity(0.2)).frame(width: 1, height: 16)
            RecorderFocusButton(camera: camera, readings: camera.readings)
                .overlay(alignment: .topTrailing) {
                    if let hint = camera.focusHint {
                        Text(hint).font(.caption.weight(.semibold)).fixedSize()
                            .padding(.horizontal, 10).padding(.vertical, 6).background(.black.opacity(0.82), in: Capsule())
                            .offset(y: -34).allowsHitTesting(false).accessibilityIdentifier("recorder.focusFeedback")
                    }
                }
            if camera.apertureAvailable {
                Rectangle().fill(.white.opacity(0.2)).frame(width: 1, height: 16)
                RecorderApertureButton(camera: camera, readings: camera.readings, open: $apertureOpen)
            }
            }
        }
        .padding(.horizontal, 5)
        .background(.ultraThinMaterial.opacity(0.85), in: Capsule())
        .fixedSize(horizontal: false, vertical: true)
    }
    private var selectedCameraName: String {
        guard let choice = camera.cameras.first(where: { $0.id == camera.cameraID }) else { return "Unavailable" }
        return choice.name + (choice.supportsLandscape ? (camera.frontLandscape ? " (landscape)" : " (portrait)") : "")
    }
    private func cameraChoice(_ choice: CameraChoice, landscape: Bool? = nil) -> some View {
        let name = choice.name + (landscape.map { $0 ? " (landscape)" : " (portrait)" } ?? "")
        let selected = camera.cameraID == choice.id && (landscape == nil || camera.frontLandscape == landscape)
        return Button { camera.switchCamera(choice.id, landscape: landscape) } label: {
            Label(choice.available ? name : name + " · 1080p only", systemImage: selected ? "checkmark" : "camera")
        }.disabled(!choice.available)
    }
    private var zoomPresets: some View { RecorderZoomPresets(camera: camera, readings: camera.readings) }
    private var aperturePresets: some View { RecorderAperturePresets(camera: camera) }
    private var recordButton: some View {
        Button {
            if recording { camera.stop() } else { start() }
        } label: {
            ZStack {
                Circle().strokeBorder(.white, lineWidth: 3).frame(width: 80, height: 80)
                    .background(frontLightEnabled ? Color(white: 0.14) : .clear, in: Circle())
                if camera.busy { ProgressView().tint(.white) }
                else if camera.state == .paused {
                    Circle().fill(red).frame(width: 66, height: 66)
                    Image(systemName: "play.fill").font(.system(size: 24, weight: .semibold)).offset(x: 2)
                } else {
                    RoundedRectangle(cornerRadius: recording ? 7 : 34)
                        .fill(red).frame(width: recording ? 30 : 66, height: recording ? 30 : 66)
                }
            }
            .frame(width: shutterSize, height: shutterSize)
            .contentShape(Rectangle())
            .shadow(color: .black.opacity(0.16), radius: 6, y: 2)
        }
        .disabled(!recording && (!camera.ready || camera.busy || camera.switchingCamera))
        .accessibilityLabel(recording ? "Stop recording" : camera.state == .paused ? "Resume recording" : "Record into this project")
        .accessibilityIdentifier("recorder.record")
        .accessibilityValue(project?.title ?? "New project")
    }
    private var libraryButton: some View {
        Button(action: openProjects) {
            Image(systemName: "square.stack").font(.system(size: 22, weight: .regular))
                .frame(width: 52, height: 52).background(controlPlate, in: RoundedRectangle(cornerRadius: 15))
                .contentShape(Rectangle())
        }.disabled(camera.hasActiveTake).accessibilityLabel("Projects")
    }
    @ViewBuilder private var secondaryButton: some View {
        if recording {
            Button { camera.stop(pause: true) } label: {
                Image(systemName: "pause.fill").font(.system(size: 20, weight: .semibold))
                    .frame(width: 52, height: 52).background(controlPlate, in: Circle())
                    .contentShape(Rectangle())
            }.accessibilityLabel("Pause recording")
        } else if camera.state == .paused {
            Button { camera.finishPausedTake() } label: {
                Image(systemName: "stop.fill").font(.system(size: 20, weight: .semibold))
                    .frame(width: 52, height: 52).background(controlPlate, in: Circle())
                    .contentShape(Rectangle())
            }.accessibilityLabel("Finish paused recording")
        } else {
            Button(action: openEditor) {
                Image(systemName: "scissors").font(.system(size: 22, weight: .regular))
                    .frame(width: 52, height: 52).background(controlPlate, in: Circle())
                    .contentShape(Rectangle())
            }.disabled(camera.busy).accessibilityLabel("Edit this project")
        }
    }
    private func warningBanner(_ warning: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(warning).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { camera.warning = nil } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }.accessibilityLabel("Dismiss warning")
        }.foregroundStyle(.yellow).padding(.leading, 12).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
    }
}

/// First/second describe the visible slots, including Swap, rather than the
/// capture session's canonical pair order. Only supported partners are offered.
private struct CameraSettings: View {
    @ObservedObject var camera: CaptureController
    @Binding var frontLightEnabled: Bool
    @Binding var adjustingHorizon: Bool
    let project: Project?
    let landscape: Bool
    let close: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var help: String?
    @State private var moreSettings = false
    private var pair: DualCameraPair? { camera.dualPairs.first { $0.id == camera.dualPairID } ?? camera.dualPairs.first }
    private var first: AVCaptureDevice? { camera.dualLayout.swapped ? pair?.second : pair?.first }
    private var second: AVCaptureDevice? { camera.dualLayout.swapped ? pair?.first : pair?.second }
    private var canChange: Bool { camera.ready && !camera.hasActiveTake && !camera.switchingCamera }
    private var supported: Bool { !camera.dualPairs.isEmpty || CommandLine.arguments.contains("--recorder-controls-test") }
    private var devices: [AVCaptureDevice] {
        var seen = Set<String>()
        return camera.dualPairs.flatMap { [$0.first, $0.second] }.filter { seen.insert($0.uniqueID).inserted }.sorted {
            func rank(_ d: AVCaptureDevice) -> Int { (d.position == .front ? 10 : 0) + (d.deviceType == .builtInWideAngleCamera ? 0 : d.deviceType == .builtInUltraWideCamera ? 1 : 2) }
            return rank($0) < rank($1)
        }
    }
    private func contains(_ pair: DualCameraPair, _ id: String) -> Bool { pair.first.uniqueID == id || pair.second.uniqueID == id }
    private var partners: [AVCaptureDevice] {
        guard let first else { return [] }
        return devices.filter { device in
            device.uniqueID != first.uniqueID && camera.dualPairs.contains { contains($0, first.uniqueID) && contains($0, device.uniqueID) }
        }
    }
    private func select(_ device: AVCaptureDevice, firstSlot: Bool) {
        let other = firstSlot ? second : first
        let candidates = camera.dualPairs.filter { contains($0, device.uniqueID) }
        guard let next = candidates.first(where: { p in other.map { contains(p, $0.uniqueID) && $0.uniqueID != device.uniqueID } ?? false }) ?? candidates.first(where: { $0.id == camera.dualPairID }) ?? candidates.first else { return }
        var layout = camera.dualLayout
        layout.swapped = firstSlot ? next.second.uniqueID == device.uniqueID : next.first.uniqueID == device.uniqueID
        camera.updateDualLayout(layout)
        if !camera.dualActive || next.id != camera.dualPairID { camera.setTwoCameras(true, pairID: next.id) }
    }
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let quickWidth = landscape ? min(496, size.width * 0.70) : size.width
            let quickHeight: CGFloat = landscape || typeSize.isAccessibilitySize ? size.height :
                min(size.height, camera.dualActive ? 464 : 388)
            ZStack(alignment: landscape ? .trailing : .bottom) {
                Color.black.opacity(adjustingHorizon ? 0 : moreSettings ? 1 : 0.25).ignoresSafeArea()
                    .onTapGesture { close() }.accessibilityHidden(true)
                if adjustingHorizon {
                    VStack {
                        Spacer()
                        horizonAnglePanel.frame(maxWidth: 420)
                    }.padding(12).frame(maxWidth: .infinity)
                } else {
                    navigation
                        .frame(width: moreSettings ? size.width : quickWidth - 12,
                               height: moreSettings ? size.height : quickHeight - 12)
                        .background(Color(uiColor: .secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: moreSettings ? 0 : 20))
                        .overlay {
                            if !moreSettings {
                                RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.12))
                                    .allowsHitTesting(false).accessibilityHidden(true)
                            }
                        }
                        .padding(moreSettings ? 0 : 6)
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .tint(.cyan)
        .accessibilityAddTraits(.isModal)
        .onChange(of: adjustingHorizon) { _, active in camera.previewHorizonAngle(active) }
        .onDisappear { if adjustingHorizon { adjustingHorizon = false; camera.previewHorizonAngle(false) } }
        .accessibilityAction(.escape) { if adjustingHorizon { adjustingHorizon = false } else if moreSettings { moreSettings = false } else { close() } }
        .alert("Camera assist", isPresented: Binding(get: { help != nil }, set: { if !$0 { help = nil } })) {
            Button("OK", role: .cancel) { help = nil }
        } message: { Text(help ?? "") }
    }

    private var navigation: some View {
        NavigationStack {
            GeometryReader { geometry in
                let wide = geometry.size.width >= 458 && !typeSize.isAccessibilitySize
                ScrollView {
                    if wide {
                        HStack(alignment: .top, spacing: 16) {
                            VStack(alignment: .leading, spacing: 14) { assists(columns: 2); RecordingColorControls(camera: camera) }
                                .frame(width: (geometry.size.width - 56) * 0.55)
                            cameras(sideBySide: false).frame(maxWidth: .infinity)
                        }
                        .padding(.horizontal, 20).padding(.vertical, 8)
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            assists(columns: geometry.size.width >= 354 && typeSize <= .large ? 4 : 2)
                            cameras(sideBySide: !typeSize.isAccessibilitySize)
                            RecordingColorControls(camera: camera)
                        }.padding(.horizontal, 20).padding(.vertical, 8)
                    }
                }.scrollBounceBehavior(.basedOnSize)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    Button { moreSettings = true } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "gearshape")
                            Text("More settings").fontWeight(.medium)
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                        }.frame(minHeight: 48).contentShape(Rectangle())
                    }.buttonStyle(.plain).padding(.horizontal, 20)
                        .accessibilityIdentifier("recorder.moreSettings")
                }.background(.bar)
            }
            .navigationTitle("Camera settings").navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $moreSettings) {
                RecorderSettings(camera: camera, project: project, adjustHorizon: { adjustingHorizon = true })
                    .navigationTitle("More settings").navigationBarTitleDisplayMode(.inline)
                    .toolbar { closeButton }
            }
            .toolbar { closeButton }
        }
    }

    private var closeButton: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button("Done", action: close).accessibilityIdentifier("recorder.settingsDone")
        }
    }

    private var horizonAnglePanel: some View {
        let size = camera.previewCanvas ?? CGSize(width: 1920, height: 1080)
        let scale = HorizonFraming.scale(maxDegrees: camera.horizonDegrees, size: size)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Max angle").font(.headline)
                Text(camera.horizonDegrees.formatted() + "°").font(.headline.monospacedDigit()).foregroundStyle(.cyan)
                Spacer()
                Button("Done") { adjustingHorizon = false }.frame(minWidth: 48, minHeight: 44)
                    .accessibilityIdentifier("recorder.levelAngleDone")
            }
            Slider(value: Binding(get: { camera.horizonDegrees }, set: camera.setHorizonDegrees),
                   in: HorizonFraming.degreeRange, step: 0.5)
                .accessibilityLabel("Max angle").accessibilityValue(camera.horizonDegrees.formatted() + " degrees")
                .accessibilityIdentifier("recorder.levelAngleSlider")
            Text(scale.formatted(.number.precision(.fractionLength(2))) + (camera.horizonEnabled ? "× framing" : "× framing · Preview only, Level horizon is off"))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.bottom, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func assists(columns: Int) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: typeSize.isAccessibilitySize ? 1 : columns), spacing: 8) {
            assist("Stabilize", symbol: "viewfinder", on: camera.stabilizationEnabled,
                   disabled: !canChange || (!camera.dualActive && !camera.singleStabilizationSupported && !camera.stabilizationEnabled),
                   identifier: "recorder.dualStabilization", status: camera.stabilizationStatus,
                   explanation: "Apple’s camera stabilization reduces hand shake and crops the picture slightly. Choose it before recording or while paused.") { camera.setStabilization(!camera.stabilizationEnabled) }
            assist("Level horizon", symbol: "level", on: camera.horizonEnabled && camera.horizonUsesRear,
                   disabled: !canChange || !camera.horizonUsesRear || !camera.canLevelHorizon,
                   identifier: "recorder.levelHorizon",
                   explanation: "Keeps small tilts level on rear cameras using a fixed crop. Adjust Max angle in More settings before a take or while paused.") {
                camera.setHorizonEnabled(!camera.horizonEnabled)
            }
            assist("Follow face", symbol: "face.dashed", on: camera.faceFollowEnabled, disabled: !camera.ready || camera.busy || camera.switchingCamera,
                   identifier: "recorder.dualFaceFollow", status: camera.faceFollowEnabled && !camera.dualActive ? camera.singleFollowStatus.rawValue : "",
                   explanation: camera.dualActive
                   ? "Gently centers a face in each picture using the room available in its layout. If the face leaves, framing holds. Panning manually turns following off."
                   : "Follows a face across the wide view of this lens, using your selected zoom to frame it. At the widest setting, a small crop leaves room to pan. If the face leaves, framing holds.") { camera.setFaceFollow(!camera.faceFollowEnabled) }
            assist("Front light", symbol: frontLightEnabled ? "lightbulb.fill" : "lightbulb", on: frontLightEnabled,
                   disabled: false, identifier: "recorder.frontLight",
                   explanation: "Lights your face with the edge of the display. Tap the bulb on the border to adjust its width, color, or opacity, even during a take.") { frontLightEnabled.toggle() }
        }
    }

    private func cameras(sideBySide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Use two cameras", isOn: Binding(get: { camera.dualActive }, set: { camera.setTwoCameras($0) }))
                .font(.subheadline.weight(.semibold)).tint(.cyan).frame(minHeight: 44)
                .accessibilityIdentifier("recorder.dualEnabled").disabled(!canChange || !supported)
            if camera.dualActive {
                if sideBySide { HStack(spacing: 8) { cameraMenu(firstSlot: true, sideBySide: true); cameraMenu(firstSlot: false, sideBySide: true) } }
                else { cameraMenu(firstSlot: true, sideBySide: false); cameraMenu(firstSlot: false, sideBySide: false) }
                Text("1080p · 30 fps").font(.caption).foregroundStyle(.secondary)
            } else if !supported {
                Text("Two-camera capture is unavailable on this device.").font(.caption).foregroundStyle(.secondary)
            }
            if camera.switchingCamera { ProgressView().frame(maxWidth: .infinity) }
        }
    }
    private func assist(_ title: String, symbol: String, on: Bool, disabled: Bool, identifier: String, status: String = "", explanation: String, action: @escaping () -> Void) -> some View {
        let details = status.isEmpty ? explanation : status + "\n\n" + explanation
        return Button { if help == nil { action(); UISelectionFeedbackGenerator().selectionChanged() } } label: {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 21, weight: .medium))
                Text(title).font(.caption.weight(.semibold))
            }.frame(maxWidth: .infinity, minHeight: 62)
                .foregroundStyle(on ? Color.cyan : Color.white)
                .background(on ? Color.cyan.opacity(0.18) : Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .topTrailing) { if on { Image(systemName: "checkmark.circle.fill").font(.caption2).foregroundStyle(.cyan).padding(6) } }
                .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(disabled)
            .highPriorityGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in help = details })
            .accessibilityLabel(title).accessibilityValue(on ? "On" : "Off").accessibilityAddTraits(.isToggle)
            .accessibilityAction(named: "Explain setting") { help = details }.accessibilityIdentifier(identifier)
    }
    private func cameraMenu(firstSlot: Bool, sideBySide: Bool) -> some View {
        let selection = firstSlot ? first : second
        return Menu {
            ForEach(firstSlot ? devices : partners, id: \.uniqueID) { device in
                Button { select(device, firstSlot: firstSlot) } label: {
                    Label(DualCameraPair.name(device), systemImage: selection?.uniqueID == device.uniqueID ? "checkmark" : "camera")
                }
            }
        } label: {
            if sideBySide {
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(firstSlot ? "First" : "Second").font(.caption2).foregroundStyle(.secondary)
                        Text(selection.map(DualCameraPair.name) ?? "Camera").font(.subheadline).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down").font(.caption)
                }.padding(.horizontal, 12).frame(height: 48)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            } else {
            HStack(spacing: 8) {
                Text(firstSlot ? "First" : "Second").foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                Text(selection.map(DualCameraPair.name) ?? "Camera").lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.caption)
            }.font(.subheadline).padding(.horizontal, 12).frame(height: 48)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            }
        }.menuOrder(.fixed).foregroundStyle(.primary).disabled(!canChange)
            .accessibilityLabel(firstSlot ? "First camera" : "Second camera")
            .accessibilityValue(selection.map(DualCameraPair.name) ?? "Unavailable")
            .accessibilityIdentifier(firstSlot ? "recorder.dualFirst" : "recorder.dualSecond")
    }
}

/// Report the orientation actually chosen by UIKit, including same-size half turns.
private struct RecorderOrientationReader: UIViewControllerRepresentable {
    var changed: (UIInterfaceOrientation, TimeInterval?) -> Void
    func makeUIViewController(context: Context) -> Reader { Reader() }
    func updateUIViewController(_ controller: Reader, context: Context) { controller.changed = changed }

    final class Reader: UIViewController {
        var changed: ((UIInterfaceOrientation, TimeInterval?) -> Void)?
        private func report(duration: TimeInterval? = nil) {
            guard let value = viewIfLoaded?.window?.windowScene?.interfaceOrientation, value != .unknown else { return }
            changed?(value, duration)
        }
        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            DispatchQueue.main.async { [weak self] in self?.report() }
        }
        override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
            super.viewWillTransition(to: size, with: coordinator)
            // Update the picture in the same transition that changes the window's axes.
            coordinator.animate(alongsideTransition: { [weak self] context in
                self?.report(duration: context.isAnimated ? context.transitionDuration : 0)
            }) { [weak self] _ in self?.report() }
        }
    }
}

// Only these small controls subscribe to per-frame readings. The menu owners
// and the settings container observe infrequent capture state changes.
private struct RecorderMicrophoneReadings: View {
    @ObservedObject var readings: CaptureReadings
    let hasMicrophone: Bool
    let ready: Bool
    let meterAvailable: Bool
    var body: some View {
        HStack(spacing: 6) {
            if hasMicrophone { levelMeter }
            if readings.audioClipping { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red) }
            else if !readings.audioArriving && ready && meterAvailable { Image(systemName: "mic.slash").foregroundStyle(.yellow) }
        }
    }
    private var levelMeter: some View {
        HStack(spacing: 2) {
            ForEach(0..<7) { index in
                let lit = readings.level > Float(-54 + index * 8)
                Capsule().fill(lit ? (index > 5 ? Color.red : Color.white) : .white.opacity(0.22))
                    .frame(width: 3, height: CGFloat(5 + index * 2))
            }
        }.accessibilityHidden(true)
    }
}

private struct RecorderZoomButton: View {
    @ObservedObject var camera: CaptureController
    @ObservedObject var readings: CaptureReadings
    @Binding var open: Bool
    var body: some View {
        Button { withAnimation(.easeOut(duration: 0.16)) { open.toggle() } } label: {
            Text(String(format: "%.1f×", readings.zoom * camera.displayZoomMultiplier)).font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(open ? .yellow : .white).frame(width: 58, height: 44)
        }.disabled(!camera.ready || camera.busy).accessibilityLabel("Zoom, \((readings.zoom * camera.displayZoomMultiplier).formatted()) times")
            .accessibilityIdentifier("recorder.zoom").accessibilityValue(String(format: "%.1f", readings.zoom * camera.displayZoomMultiplier))
    }
}

private struct RecorderApertureButton: View {
    @ObservedObject var camera: CaptureController
    @ObservedObject var readings: CaptureReadings
    @Binding var open: Bool

    private var value: String {
        let selection = camera.selectedAperture.map(CameraAperture.label) ?? "Auto"
        #if DEBUG
        if CommandLine.arguments.contains("--probe-aperture-controls") {
            return selection + "; " + readings.apertureProbe
        }
        #endif
        return selection
    }

    var body: some View {
        Button { withAnimation(.easeOut(duration: 0.16)) { open.toggle() } } label: {
            Group {
                if let aperture = camera.selectedAperture {
                    Text(CameraAperture.label(aperture)).font(.system(size: 12, weight: .semibold))
                } else { Image(systemName: "camera.aperture").font(.system(size: 18, weight: .medium)) }
            }
            .foregroundStyle(open || camera.selectedAperture != nil ? .yellow : .white)
            .frame(width: 52, height: 44)
        }
        .disabled(!camera.ready || camera.busy || camera.switchingCamera)
        .accessibilityIdentifier("recorder.aperture").accessibilityLabel("Aperture")
        .accessibilityValue(value)
        .accessibilityHint("Show or hide automatic aperture and the available f-stops.")
    }
}

private struct RecorderAperturePresets: View {
    @ObservedObject var camera: CaptureController

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 2) {
                option(nil)
                ForEach(camera.apertureStops, id: \.self) { option($0) }
            }
        }
        .scrollIndicators(.hidden).scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: CGFloat((camera.apertureStops.count + 1) * 58))
        .frame(height: 48).padding(.horizontal, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .disabled(!camera.ready || camera.busy || camera.switchingCamera)
        .accessibilityIdentifier("recorder.aperture.presets")
    }

    private func option(_ value: Float?) -> some View {
        let selected = camera.selectedAperture == value
        let title = value.map(CameraAperture.label) ?? "Auto"
        return Button {
            camera.setAperture(value)
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            Text(title).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                .foregroundStyle(selected ? .yellow : .white)
                .frame(minWidth: 54, minHeight: 44)
                .background(selected ? .white.opacity(0.12) : .clear, in: Capsule())
        }
        .accessibilityIdentifier("recorder.aperture." + (value.map(CameraAperture.label) ?? "auto"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct RecorderFocusButton: View {
    @ObservedObject var camera: CaptureController
    @ObservedObject var readings: CaptureReadings
    @State private var startTime: Date?
    @State private var startLens: Float = 0
    @State private var moved = false
    @State private var vertical = false
    @State private var adjustedLens: Float?
    @GestureState private var touching = false

    private var canToggleMode: Bool { camera.focusLockSupported && camera.autofocusSupported }
    private func toggleMode() {
        if canToggleMode { camera.setFocus(locked: !readings.focusLocked) }
        else if camera.fixedFocus { camera.showFocusHint("This lens has fixed focus") }
    }
    private func togglePeaking() {
        camera.toggleFocusPeaking()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        camera.showFocusHint(camera.focusPeaking ? "Focus peaking on" : "Focus peaking off")
    }
    private var face: some View {
        VStack(spacing: 2) {
            if readings.focusLocked && camera.focusAdjustable { chevron("chevron.up") }
            Text(camera.fixedFocus ? "Fixed" : readings.focusLocked ? (camera.focusAdjustable ? "MF" : "Locked") : "AF").font(.system(size: 12, weight: .semibold))
            if readings.focusLocked && camera.focusAdjustable { chevron("chevron.down") }
        }
        .foregroundStyle(camera.focusPeaking ? Color.red : readings.focusLocked ? .yellow : .white)
        .frame(width: 52, height: 44).contentShape(Rectangle())
        .overlay(alignment: .topTrailing) {
            if let adjustedLens {
                Text("Focus \(Int((adjustedLens * 100).rounded()))%")
                    .font(.caption.monospacedDigit().bold()).fixedSize()
                    .padding(.horizontal, 10).padding(.vertical, 6).background(.regularMaterial, in: Capsule())
                    .offset(y: -34).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }
    private var gesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .updating($touching) { _, state, _ in state = true }
            .onChanged(updateTouch)
            .onEnded(endTouch)
    }
    private func updateTouch(_ value: DragGesture.Value) {
        if startTime == nil { startTime = value.time; startLens = readings.lensPosition }
        let dx = abs(value.translation.width), dy = abs(value.translation.height)
        if !moved && max(dx, dy) >= 7 { moved = true; vertical = dy > dx }
        guard moved, vertical, readings.focusLocked, camera.focusAdjustable else { return }
        // A short stroke gives fine control. Longer strokes traverse the lens faster.
        let amount = min(dy, 40) / 320 + max(0, dy - 40) / 160
        let lens = min(1, max(0, startLens + Float(value.translation.height < 0 ? amount : -amount)))
        if lens != adjustedLens {
            adjustedLens = lens
            camera.setFocus(locked: true, position: lens, persist: false)
        }
    }
    private func endTouch(_ value: DragGesture.Value) {
        if let adjustedLens { camera.setFocus(locked: true, position: adjustedLens) }
        else if !moved, let startTime {
            if value.time.timeIntervalSince(startTime) >= 0.45 { togglePeaking() }
            else { toggleMode() }
        }
        clearTouch()
    }
    private var focusValue: String {
        let mode = camera.fixedFocus ? "Fixed focus" : readings.focusLocked ? "Locked · \(Int((readings.lensPosition * 100).rounded()))%" : "Auto"
        return camera.focusPeaking ? mode + " · Peaking on" : mode
    }
    var body: some View {
        face.gesture(gesture)
        .onChange(of: touching) { _, active in if !active { clearTouch() } }
        .disabled(!camera.ready || camera.busy || camera.switchingCamera)
        .accessibilityElement(children: .ignore).accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("recorder.focus")
        .accessibilityLabel(camera.fixedFocus ? "Fixed focus" : readings.focusLocked ? (camera.focusAdjustable ? "Manual focus" : "Focus locked") : "Autofocus")
        .accessibilityValue(focusValue)
        .accessibilityHint(camera.fixedFocus ? "Hold and release to toggle focus peaking." : "Tap to switch focus mode. In manual focus swipe up for far or down for near. Hold and release to toggle focus peaking.")
        .accessibilityAction { toggleMode() }
        .accessibilityAction(named: "Toggle focus peaking") { togglePeaking() }
        .accessibilityAdjustableAction { direction in
            guard readings.focusLocked, camera.focusAdjustable else { return }
            switch direction {
            case .increment: camera.setFocus(locked: true, position: readings.lensPosition + 0.025)
            case .decrement: camera.setFocus(locked: true, position: readings.lensPosition - 0.025)
            @unknown default: break
            }
        }
    }
    private func chevron(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 8, weight: .bold))
    }
    private func clearTouch() { startTime = nil; moved = false; vertical = false; adjustedLens = nil }
}

private struct RecorderZoomPresets: View {
    @ObservedObject var camera: CaptureController
    @ObservedObject var readings: CaptureReadings
    @AppStorage("zoomTransitionSeconds") private var rampSeconds = 0.0
    @State private var hintID: UUID?
    private var enabled: Bool { camera.ready && !camera.busy && !camera.switchingCamera }
    private var presets: [Double] {
        [0.5, 1.0, 2.0, 3.0, 5.0, 6.0].filter {
            $0 >= camera.minZoom * camera.displayZoomMultiplier && $0 <= camera.maxZoom * camera.displayZoomMultiplier
        }
    }
    var body: some View {
        VStack(spacing: 4) {
            if let hintID {
                Text("Swipe up/down to change zoom time")
                    .font(.caption.weight(.medium)).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.black.opacity(0.8), in: Capsule())
                    .allowsHitTesting(false)
                    .task(id: hintID) {
                        do { try await Task.sleep(for: .seconds(2.5)) } catch { return }
                        self.hintID = nil
                    }
            }
            presetBar
        }
    }
    private var presetBar: some View {
        HStack(spacing: 4) {
            RecorderZoomDuration(hintID: $hintID)
            Rectangle().fill(.white.opacity(0.2)).frame(width: 1, height: 22)
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(presets, id: \.self) { zoom in
                        RecorderZoomPreset(zoom: zoom, selectsMainLens: zoom == 1 && camera.mainLensAtOneX != nil,
                            selected: !(zoom == 1 && camera.mainLensAtOneX != nil) && abs(readings.zoom * camera.displayZoomMultiplier - zoom) < 0.04,
                            normal: { select(zoom, seconds: rampSeconds) }, quick: { select(zoom, seconds: 1) })
                    }
                }
            }.scrollIndicators(.hidden).scrollBounceBehavior(.basedOnSize)
                .frame(maxWidth: CGFloat(max(0, presets.count * 46 - 2)))
                .disabled(!enabled).opacity(enabled ? 1 : 0.4)
        }.frame(height: 48).padding(.horizontal, 6).background(.ultraThinMaterial, in: Capsule())
    }
    private func select(_ zoom: Double, seconds: Double) {
        hintID = nil
        if zoom == 1, let main = camera.mainLensAtOneX { camera.switchCamera(main.id, nativeZoom: true) }
        else { camera.setZoom(zoom / camera.displayZoomMultiplier, seconds: seconds) }
    }
}

private struct RecorderZoomPreset: View {
    let zoom: Double
    let selectsMainLens: Bool
    let selected: Bool
    let normal: () -> Void
    let quick: () -> Void
    @GestureState private var pressed = false
    var body: some View {
        VStack(spacing: 0) {
            Text(String(format: "%g×", zoom)).font(.system(size: 13, weight: .semibold))
            if selectsMainLens { Text("Main").font(.system(size: 9, weight: .medium)) }
        }
            .foregroundStyle(selected ? .yellow : .white)
            .frame(width: 44, height: 48)
            .background(.white.opacity(pressed ? 0.18 : 0), in: Capsule())
            .contentShape(Rectangle())
            // Wait to distinguish taps, but give immediate touch feedback.
            // In particular, Instant must not fire before the second tap.
            .gesture(TapGesture(count: 2).exclusively(before: TapGesture()).onEnded { gesture in
                switch gesture {
                case .first: quick()
                case .second: normal()
                }
            })
            .simultaneousGesture(DragGesture(minimumDistance: 0).updating($pressed) { _, state, _ in state = true })
            .onChange(of: pressed) { _, value in if value { UISelectionFeedbackGenerator().selectionChanged() } }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(selectsMainLens ? "1 times zoom, Main camera" : "\(zoom.formatted()) times zoom")
            .accessibilityIdentifier("recorder.zoom.preset.\(Int(zoom * 10))")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityHint("One-second transition available in actions.")
            .accessibilityAction { normal() }
            .accessibilityAction(named: "One-second transition") { quick() }
    }
}

/// Separate from the live readings so an adjustment survives sensor updates.
private struct RecorderZoomDuration: View {
    @Binding var hintID: UUID?
    @AppStorage("zoomTransitionSeconds") private var seconds = 0.0
    @GestureState private var dragging = false
    @State private var dragStart: Double?
    @State private var verticalDrag: Bool?
    var body: some View {
        HStack(spacing: 3) {
            VStack(spacing: 2) {
                Image(systemName: "timer").font(.system(size: 10))
                Text(seconds == 0 ? "Instant" : "\(seconds.formatted())s").font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold))
        }
        .foregroundStyle(seconds == 0 ? .white : .yellow).frame(width: 56, height: 48).contentShape(Rectangle())
        .overlay(alignment: .topLeading) {
            if dragging {
                Text(ZoomTransition.durationLabel(seconds)).font(.caption.monospacedDigit().bold())
                    .fixedSize().padding(.horizontal, 10).padding(.vertical, 7)
                    .background(.regularMaterial, in: Capsule()).offset(x: 36, y: -38)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .gesture(DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .updating($dragging) { _, state, _ in state = true }
            .onChanged { value in
                if dragStart == nil {
                    hintID = nil
                    dragStart = seconds
                    verticalDrag = abs(value.translation.height) > abs(value.translation.width)
                }
                guard verticalDrag == true, let dragStart else { return }
                let steps = (-value.translation.height / 14).rounded(.towardZero)
                change(dragStart + steps * 0.5)
            }
            .onEnded { _ in dragStart = nil; verticalDrag = nil }
            .exclusively(before: TapGesture().onEnded { hintID = UUID() }))
        .onChange(of: dragging) { _, active in if !active { dragStart = nil; verticalDrag = nil } }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("recorder.zoom.duration")
        .accessibilityLabel("Zoom transition duration")
        .accessibilityValue(ZoomTransition.durationLabel(seconds))
        .accessibilityHint("Swipe up to lengthen or down to shorten the next zoom transition.")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: change(seconds + 0.5)
            case .decrement: change(seconds - 0.5)
            @unknown default: break
            }
        }
    }
    private func change(_ value: Double) {
        let next = ZoomTransition.boundedDuration(value)
        guard next != seconds else { return }
        seconds = next
        UISelectionFeedbackGenerator().selectionChanged()
    }
}

private struct RecorderFocusSettings: View {
    @ObservedObject var camera: CaptureController
    @ObservedObject var readings: CaptureReadings
    var body: some View {
        Section {
            Toggle("Lock focus", isOn: Binding(get: { readings.focusLocked }, set: { camera.setFocus(locked: $0) }))
                .disabled(!camera.focusLockSupported || camera.fixedFocus)
            if camera.focusAdjustable {
                HStack {
                    Text("Near").font(.caption)
                    Slider(value: Binding(get: { readings.lensPosition }, set: { camera.setFocus(locked: true, position: $0) }), in: 0...1)
                        .accessibilityLabel("Manual lens position")
                    Text("Far").font(.caption)
                }
            }
        } header: {
            Text("Focus")
        } footer: {
            Text(camera.fixedFocus ? "This lens has fixed focus. Hold the focus control to highlight sharp edges." : camera.focusAdjustable
                 ? "In the recorder, swipe up on MF for farther focus or down for nearer focus. Hold AF or MF to highlight sharp edges in the preview."
                 : "Hold the focus control in the recorder to highlight sharp edges in the preview.")
        }
    }
}

private struct RecorderSettings: View {
    @ObservedObject var camera: CaptureController
    let project: Project?
    let adjustHorizon: () -> Void
    @AppStorage("zoomTransitionSeconds") private var rampSeconds = 0.0
    @AppStorage("protectRecordingAudio") private var protectRecordingAudio = false
    @AppStorage("fitRecordedFrame") private var fitRecordedFrame = true
    private var keepFraming: Bool { camera.hasActiveTake || camera.state == .paused }
    var body: some View {
        Form {
            Section("This project") {
                Text(project?.title ?? "New project")
                Text("\(recorderClock(project?.capturedDuration ?? 0)) captured").font(.caption).foregroundStyle(.secondary)
            }
            Section("Level horizon") {
                Button(action: adjustHorizon) {
                    HStack {
                        Text("Max angle").foregroundStyle(.primary)
                        Spacer()
                        Text(camera.horizonDegrees.formatted() + "°").monospacedDigit()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("recorder.levelAngle")
                .disabled(!camera.ready || camera.hasActiveTake || camera.switchingCamera || !camera.horizonUsesRear || !camera.canLevelHorizon)
            }
            if camera.dualActive {
                Section("Two cameras") {
                    Text("1080p · 30 fps · SDR")
                    Text("Records one composed video. Layout changes are saved in the footage. Single-camera quality and HDR settings are kept for when you switch back. Dolly Zoom and Crash Zoom require Single camera.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Picture") {
                Toggle("Mirror selfie preview", isOn: $camera.mirrorPreview).accessibilityIdentifier("recorder.mirrorPreview")
                Toggle("Save mirrored selfies", isOn: $camera.mirrorRecording).disabled(camera.hasActiveTake || camera.state == .paused)
                    .accessibilityIdentifier("recorder.mirrorRecording")
                Text("The front-camera preview behaves like a mirror by default. Saved video keeps writing readable unless Save mirrored selfies is on.").font(.caption).foregroundStyle(.secondary)
            }
            if !camera.dualActive { RecorderFocusSettings(camera: camera, readings: camera.readings) }
            Section("Zoom") {
                Picker("Transition", selection: $rampSeconds) {
                    ForEach(Array(Set(ZoomTransition.durationPresets + [rampSeconds])).sorted(), id: \.self) { seconds in
                        Text(ZoomTransition.durationLabel(seconds)).tag(seconds)
                    }
                }
                .accessibilityIdentifier("recorder.transition").accessibilityLabel("Zoom transition duration")
                .accessibilityValue(ZoomTransition.durationLabel(rampSeconds))
                Text("Swipe the time beside the zoom presets up or down to adjust by half a second. Double-tap a zoom preset to reach it in one second. Each camera remembers its own zoom.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Protect recording audio", isOn: $protectRecordingAudio)
                    .disabled(camera.hasActiveTake).accessibilityIdentifier("recorder.protectAudio")
            } header: { Text("Interruptions") } footer: {
                Text("Keeps audio recording through incoming call banners. Answering a call or receiving a full-screen call interrupts the take. For Do Not Disturb throughout YouRec, choose Settings → Focus → Do Not Disturb → Add Schedule → App → YouRec.")
            }
            Section("Microphone") {
                ForEach(camera.microphones) { microphone in
                    Button { camera.selectMicrophone(microphone.id) } label: {
                        HStack { Text(microphone.name); Spacer(); if microphone.id == camera.microphoneID { Image(systemName: "checkmark") } }
                    }
                }
                Text("A quick selection lasts until Stop. Priority below is remembered, including disconnected microphones.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Microphone priority · highest first") {
                ForEach(Array(camera.microphonePriority.enumerated()), id: \.element.id) { index, microphone in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(microphone.name)
                            if !camera.microphones.contains(where: { $0.id == microphone.id }) { Text("Disconnected").font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Button { camera.moveMicrophonePreference(microphone.id, offset: -1) } label: { Image(systemName: "arrow.up").frame(width: 44, height: 44) }.disabled(index == 0)
                            .accessibilityLabel("Move \(microphone.name) earlier")
                        Button { camera.moveMicrophonePreference(microphone.id, offset: 1) } label: { Image(systemName: "arrow.down").frame(width: 44, height: 44) }.disabled(index + 1 == camera.microphonePriority.count)
                            .accessibilityLabel("Move \(microphone.name) later")
                    }.buttonStyle(.borderless)
                }
            }
            Section("Recording quality") {
                Picker("Quality", selection: Binding(get: { camera.quality }, set: { camera.setQuality($0) })) {
                    ForEach(CaptureQuality.allCases) { quality in Text(quality.title).tag(quality) }
                }.disabled(keepFraming || camera.dualActive)
                    .accessibilityIdentifier("recorder.quality").accessibilityValue(camera.quality.title)
                Text("4K uses more storage and power. Quality stays fixed until Stop.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Framing") {
                Toggle("Fit entire recorded frame", isOn: $fitRecordedFrame)
                Text("The full-screen view fills the display. Fit shows the complete recorded frame.").font(.caption).foregroundStyle(.secondary)
            }
            Section("About") {
                NavigationLink("Credits") { CreditsView() }
                    .accessibilityIdentifier("recorder.credits")
            }
        }
    }
}

private func recorderClock(_ seconds: Double) -> String {
    let value = Int(max(0, seconds.isFinite ? seconds : 0))
    return String(format: "%02d:%02d", value / 60, value % 60)
}

private struct RecordingAudioControls: View {
    @ObservedObject var camera: CaptureController
    let readings: CaptureReadings
    @State private var explanation = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Recording volume", systemImage: "mic.fill").font(.headline).onLongPressGesture { explanation = true }
                Spacer()
                Button { explanation.toggle() } label: { Image(systemName: "info.circle").frame(width: 44, height: 44) }
                    .accessibilityLabel("About recording volume")
            }
            RecordingGainControls(camera: camera, readings: readings)
            Menu {
                ForEach(camera.microphones) { mic in
                    Button { camera.selectMicrophone(mic.id) } label: {
                        Label(mic.name, systemImage: mic.id == camera.microphoneID ? "checkmark" : "mic")
                    }.accessibilityIdentifier("recorder.input." + mic.id)
                }
            } label: { Label(camera.microphoneName, systemImage: "chevron.down").font(.subheadline).frame(minHeight: 44) }.accessibilityIdentifier("recorder.gainMicrophone")
            if explanation {
                Text("Changes the volume of new recordings, including during a take. Remembered for each microphone. Red means the signal may distort; lowering gain cannot repair distortion already present in the microphone.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(18).frame(width: 310)
    }
}

/// Frequent meter publications stay inside this view, away from the microphone menu.
private struct RecordingGainControls: View {
    @ObservedObject var camera: CaptureController
    @ObservedObject var readings: CaptureReadings
    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text(camera.recordingGainDB.formatted(.number.sign(strategy: .always()).precision(.fractionLength(1))) + " dB")
                    .font(.title3.monospacedDigit().weight(.semibold)).foregroundStyle(readings.audioClipping ? .red : .primary)
                    .accessibilityIdentifier("recorder.gainValue")
                Spacer()
                Button("Reset to 0") { camera.setRecordingGain(0) }.frame(minHeight: 44)
                    .accessibilityIdentifier("recorder.gainReset")
            }
            Slider(value: Binding(get: { camera.recordingGainDB }, set: camera.setRecordingGain), in: RecordingGain.range, step: 0.5)
                .tint(readings.audioClipping ? .red : .cyan).accessibilityLabel("Recording gain").accessibilityIdentifier("recorder.gain")
            HStack {
                ProgressView(value: min(1, max(0, Double(readings.level + 60) / 60))).tint(readings.audioClipping ? .red : .green)
                Text(readings.audioClipping ? "Clipping" : readings.audioArriving ? String(format: "%.0f dBFS", readings.level) : "No signal")
                    .font(.caption.monospacedDigit()).foregroundStyle(readings.audioClipping ? .red : .secondary)
            }
        }
    }
}

private struct DualLayoutOverlay: View {
    @ObservedObject var camera: CaptureController
    var showHandles = true
    @State private var initialDivider: Double?
    var body: some View {
        GeometryReader { geo in
            let layout = camera.dualLayout, size = geo.size
            let regions = layout.regions(in: size)
            ZStack(alignment: .topLeading) {
                ForEach(0..<2) { slot in
                    DualPictureGesture(camera: camera, slot: slot, canvas: size)
                        .frame(width: regions[slot].width, height: regions[slot].height)
                        .position(x: regions[slot].midX, y: regions[slot].midY)
                }
                if layout.mode == .diagonal && showHandles {
                    Button {
                        var next = camera.dualLayout; next.flipDiagonal(); camera.updateDualLayout(next)
                    } label: {
                        Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                            .font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 44, height: 44).background(.black.opacity(0.7), in: Circle())
                            .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1))
                            .contentShape(Circle())
                    }.position(x: size.width/2, y: size.height/2)
                        .accessibilityLabel("Flip diagonal").accessibilityIdentifier("recorder.diagonalFlip")
                        .accessibilityValue(layout.diagonalTitle)
                        .accessibilityHint("Switches between the two corner-to-corner diagonals.")
                } else if layout.mode != .floating && showHandles {
                    let vertical = layout.mode == .sideBySide
                    Image(systemName: vertical ? "arrow.left.and.right" : "arrow.up.and.down")
                        .font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 44, height: 44).background(.black.opacity(0.7), in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1))
                        .contentShape(Circle())
                        .position(x: vertical ? regions[0].maxX : size.width/2, y: vertical ? size.height/2 : regions[0].maxY)
                        .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                            if initialDivider == nil { initialDivider = vertical ? layout.verticalDivider : layout.horizontalDivider }
                            var next = camera.dualLayout
                            let value = initialDivider! + (vertical ? event.translation.width/size.width : event.translation.height/size.height)
                            if vertical { next.verticalDivider = value } else { next.horizontalDivider = value }
                            camera.updateDualLayout(next)
                        }.onEnded { _ in initialDivider = nil })
                        .accessibilityLabel("Camera divider").accessibilityIdentifier("recorder.divider")
                        .accessibilityValue(String(format: "%.0f percent", (vertical ? layout.verticalDivider : layout.horizontalDivider)*100))
                        .accessibilityAdjustableAction { direction in
                            var next = camera.dualLayout
                            let delta = direction == .increment ? 0.05 : -0.05
                            if vertical { next.verticalDivider += delta } else { next.horizontalDivider += delta }
                            camera.updateDualLayout(next)
                        }
                }
            }
        }
    }
}

private struct DualPictureGesture: UIViewRepresentable {
    @ObservedObject var camera: CaptureController
    let slot: Int
    let canvas: CGSize
    func makeUIView(context: Context) -> DualPictureGestureView { DualPictureGestureView() }
    func updateUIView(_ view: DualPictureGestureView, context: Context) {
        view.layout = camera.dualDisplayLayout; view.slot = slot; view.canvas = canvas
        view.currentLayout = { camera.dualDisplayLayout }
        let source = camera.dualLayout.swapped ? 1-slot : slot
        let pair = camera.dualPairs.first { $0.id == camera.dualPairID }
        view.mirrored = camera.mirrorPreview && (source == 0 ? pair?.first : pair?.second)?.position == .front
        view.change = { camera.updateDualLayout($0, manualPan: $1) }
        view.configure()
    }
}

/// Two simultaneous recognizers keep a two-finger pan working during a pinch.
/// Incremental deltas use the current zoom, avoiding jumps when a finger lifts.
private final class DualPictureGestureView: UIView, UIGestureRecognizerDelegate {
    var layout = DualCameraLayout(), slot = 0, canvas = CGSize.zero, mirrored = false
    var change: (DualCameraLayout, Bool) -> Void = { _, _ in }
    var currentLayout: (() -> DualCameraLayout)?
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
    private lazy var pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
    private var insetResizeAxis = DualCameraLayout.InsetResizeAxis.proportional
    private var pendingPan = CGPoint.zero
    private var manualPanStarted = false
    private var inset: Bool { layout.mode == .floating && slot == 1 }
    private var first: Bool { (layout.swapped ? 1-slot : slot) == 0 }
    override init(frame: CGRect) {
        super.init(frame: frame); backgroundColor = .clear; isMultipleTouchEnabled = true
        pan.delegate = self; pinch.delegate = self
        addGestureRecognizer(pan); addGestureRecognizer(pinch)
        isAccessibilityElement = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let region = layout.regions(in: canvas)[slot]
        return layout.contains(CGPoint(x: region.minX+point.x, y: region.minY+point.y), slot: slot, in: canvas)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = inset && layout.isRound ? bounds.width/2 : 0
    }
    func configure() {
        pan.minimumNumberOfTouches = inset ? 1 : 2
        pan.maximumNumberOfTouches = 2
        layer.borderWidth = inset ? 1 : 0; layer.borderColor = UIColor.white.withAlphaComponent(0.8).cgColor
        setNeedsLayout()
        accessibilityLabel = inset ? "Floating camera" : "Camera picture \(slot+1)"
        accessibilityIdentifier = "recorder.dualPicture.\(slot)"
        let f = first ? layout.first : layout.second
        if inset {
            let rect = layout.regions(in: canvas)[1]
            accessibilityValue = String(format: "width %.1f height %.1f", rect.width, rect.height)
        } else { accessibilityValue = String(format: "x %.3f y %.3f zoom %.3f", f.x, f.y, f.zoom) }
        accessibilityHint = inset ? (layout.isRound ? "Drag to move. Pinch to resize the circle." : "Drag to move. Horizontal pinches change width, vertical pinches change height, diagonal pinches resize proportionally.") : "Use two fingers to pan or pinch to zoom."
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        (gestureRecognizer === pan && otherGestureRecognizer === pinch) || (gestureRecognizer === pinch && otherGestureRecognizer === pan)
    }
    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .began || gesture.state == .changed, canvas.width > 0, canvas.height > 0 else { return }
        if gesture.state == .began { layout = currentLayout?() ?? layout; pendingPan = .zero; manualPanStarted = false }
        var delta = gesture.translation(in: superview); gesture.setTranslation(.zero, in: superview)
        if !inset {
            // Use centroid travel to distinguish intentional panning from a
            // stationary pinch; keep simultaneous pan + zoom available.
            if !manualPanStarted {
                pendingPan.x += delta.x; pendingPan.y += delta.y
                guard hypot(pendingPan.x, pendingPan.y) >= 8 else { return }
                delta = pendingPan; pendingPan = .zero; manualPanStarted = true
            }
        }
        var next = layout
        if inset {
            let rect = layout.regions(in: canvas)[1]
            next.insetX = (rect.midX+delta.x)/canvas.width; next.insetY = (rect.midY+delta.y)/canvas.height
        } else {
            var f = first ? layout.first : layout.second
            let region = layout.regions(in: canvas)[slot]
            let placed = DualCameraLayout.placement(source: canvas, region: region, framing: f)
            let dx = delta.x * (mirrored ? -1 : 1)
            if placed.width-region.width > 0.1 { f.x -= dx/(placed.width-region.width) }
            if placed.height-region.height > 0.1 { f.y -= delta.y/(placed.height-region.height) }
            if first { next.first = f } else { next.second = f }
        }
        publish(next, manualPan: !inset)
    }
    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        guard gesture.state == .began || gesture.state == .changed else { return }
        if gesture.state == .began { layout = currentLayout?() ?? layout }
        var next = layout
        if inset {
            if gesture.state == .began, gesture.numberOfTouches == 2 {
                let a = gesture.location(ofTouch: 0, in: superview), b = gesture.location(ofTouch: 1, in: superview)
                insetResizeAxis = DualCameraLayout.insetResizeAxis(separation: CGSize(width: b.x-a.x, height: b.y-a.y))
            }
            next.resizeInset(scale: gesture.scale, axis: insetResizeAxis, canvas: canvas)
        }
        else if first { next.first.zoom *= gesture.scale }
        else { next.second.zoom *= gesture.scale }
        gesture.scale = 1; publish(next)
    }
    private func publish(_ value: DualCameraLayout, manualPan: Bool = false) {
        layout = value; layout.constrain(); change(layout, manualPan); configure()
    }
}
