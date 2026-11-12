import SwiftUI
import AVKit
import CoreImage

struct BookmarkHelpView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing:16) {
                    Image(systemName:"bookmark").font(.system(size:36,weight:.light)).foregroundStyle(.orange).accessibilityHidden(true)
                    Text("No marks yet").font(.title2.weight(.semibold))
                    Text("While recording, tap Mark to remember a moment in your video—for example, a mistake to cut or a take to keep.")
                    Text("Use the previous and next bookmark buttons in the editor to jump back to those moments.").foregroundStyle(.secondary)
                }.multilineTextAlignment(.center).frame(maxWidth:420).padding(24).frame(maxWidth:.infinity)
            }.navigationTitle("Marks").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement:.confirmationAction) { Button("Got it") { dismiss() } } }
        }.preferredColorScheme(.dark).presentationDetents([.medium,.large]).presentationDragIndicator(.visible)
    }
}

struct FullEditorPreview: View {
    @ObservedObject var editor: EditorController
    let duration: Double
    let bookmarks: [ResolvedBookmark]
    let close: () -> Void
    let addBookmark: () -> Void
    @State private var controls = true
    @State private var bookmarkHelp = false
    @State private var hideControls: Task<Void, Never>?
    @State private var scrubbing = false
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerSurface(player: editor.player, inspectionZoom: true, onPlaybackTap: { editor.togglePlay(); scheduleControls() }, identifier: "fullPreview.preview")
            if controls {
                VStack {
                    HStack {
                        Menu { ForEach([1.0, 1.5, 2, 2.5, 3], id: \.self) { speed in Button("\(speed.formatted())×") { editor.setPlaybackSpeed(speed) } } } label: { Text("\(editor.playbackSpeed.formatted())×").frame(width: 52, height: 44) }
                        Spacer()
                        Button("Done", action: close).frame(minWidth: 60, minHeight: 44)
                    }.padding(.horizontal).background(.black.opacity(0.55))
                    Spacer()
                    VStack(spacing: 4) {
                        Slider(value: Binding(get: { editor.playhead }, set: { editor.seekPaused($0) }), in: 0...max(0.001, duration), onEditingChanged: { active in scrubbing = active; editor.setScrubbing(active); scheduleControls() }).accessibilityLabel("Full preview position")
                        HStack {
                            Text(editorTime(editor.playhead)).accessibilityIdentifier("fullPreview.playhead").monospacedDigit().font(.caption)
                            Spacer()
                            Button { jump(false) } label: { Image(systemName: "bookmark").overlay(alignment: .leading) { Image(systemName: "chevron.left").font(.system(size: 7)).offset(x: -6) }.frame(width: 44, height: 44) }.accessibilityLabel("Previous bookmark").accessibilityIdentifier("fullPreview.previousBookmark")
                            ChangeNavigationButton(forward: false, enabled: editor.navigation.destination(from: editor.stationaryPlayhead, forward: false) != nil, identifierPrefix: "fullPreview") { effectsOnly in
                                editor.jumpChange(forward: false, effectsOnly: effectsOnly); scheduleControls()
                            }.frame(width: 44, height: 44)
                            Button { editor.togglePlay(); scheduleControls() } label: { Image(systemName: editor.playing ? "pause.fill" : "play.fill").frame(width: 52, height: 44) }.accessibilityLabel(editor.playing ? "Pause" : "Play").accessibilityIdentifier("fullPreview.playPause")
                            ChangeNavigationButton(forward: true, enabled: editor.navigation.destination(from: editor.stationaryPlayhead, forward: true) != nil, identifierPrefix: "fullPreview") { effectsOnly in
                                editor.jumpChange(forward: true, effectsOnly: effectsOnly); scheduleControls()
                            }.frame(width: 44, height: 44)
                            Button { jump(true) } label: { Image(systemName: "bookmark").overlay(alignment: .trailing) { Image(systemName: "chevron.right").font(.system(size: 7)).offset(x: 6) }.frame(width: 44, height: 44) }.accessibilityLabel("Next bookmark").accessibilityIdentifier("fullPreview.nextBookmark")
                            Spacer()
                            Menu { Button("Add bookmark here", systemImage: "bookmark.badge.plus", action: addBookmark); ForEach(bookmarks) { mark in Button(editorTime(mark.time.seconds) + (mark.bookmark.label.isEmpty ? "" : " · " + mark.bookmark.label)) { editor.seekPaused(mark.time.seconds) } } } label: { Image(systemName: "bookmark").frame(width: 44, height: 44) }.accessibilityLabel("Bookmarks")
                        }
                    }.padding(.horizontal, 16).padding(.bottom, 8).background(.black.opacity(0.7))
                }
            }
        }.foregroundStyle(.white).preferredColorScheme(.dark).statusBarHidden()
            .sheet(isPresented:$bookmarkHelp) { BookmarkHelpView() }
            .onAppear { scheduleControls() }
            .onChange(of: editor.playing) { _, _ in scheduleControls() }
            .onDisappear { hideControls?.cancel() }
    }
    private func scheduleControls() {
        hideControls?.cancel(); controls = true
        guard editor.playing, !scrubbing else { return }
        hideControls = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(2.5))
                guard editor.playing, !scrubbing else { return }
                withAnimation(.easeOut(duration: 0.2)) { controls = false }
            } catch {}
        }
    }
    private func jump(_ forward: Bool) {
        guard !bookmarks.isEmpty else { editor.pause(); bookmarkHelp = true; return }
        let mark = forward ? bookmarks.first { $0.time.seconds > editor.playhead + 0.02 } : bookmarks.last { $0.time.seconds < editor.playhead - 0.02 }
        if let mark { editor.seekPaused(mark.time.seconds) }; scheduleControls()
    }
}

private struct AudioFadeRow: View {
    let edge: AudioFadeEdge
    let target: String
    let seconds: Double
    let limit: Double
    let playing: Bool
    let change: (Double) -> Void
    let listen: () -> Void
    @State private var enteringTime = false
    @State private var entry = ""

    private var number: FloatingPointFormatStyle<Double> { .number.grouping(.never).precision(.fractionLength(0...3)) }
    private var entered: Double? {
        let text = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(text.replacingOccurrences(of: ",", with: ".")), value.isFinite, value >= 0 else { return nil }
        if value > 0 && value == (limit * 1000).rounded() / 1000 { return limit }
        return value <= limit ? value : nil
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(edge.title).font(.subheadline.weight(.semibold))
                    Text(target).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("volume." + edge.rawValue + ".target")
                }
                Spacer()
                Button {
                    entry = seconds.formatted(number); enteringTime = true
                } label: {
                    Text(seconds == 0 ? "Off" : seconds.formatted(number) + " s")
                        .font(.body.monospacedDigit()).frame(minWidth: 48, minHeight: 44)
                }.accessibilityLabel(edge.title + " duration").accessibilityValue(seconds.formatted(number) + " seconds")
                    .accessibilityHint("Enter an exact time in seconds. Zero turns the fade off.")
                    .accessibilityIdentifier("volume." + edge.rawValue + ".duration")
            }
            HStack(spacing: 10) {
                Button(action: listen) {
                    Image(systemName: playing ? "pause.fill" : "play.fill").frame(width: 44, height: 44)
                }.accessibilityLabel((playing ? "Pause " : "Preview ") + edge.title.lowercased())
                    .accessibilityIdentifier("volume." + edge.rawValue + ".listen")
                // Give short fades useful travel even when a take is many minutes long.
                Slider(value: Binding(get: { log1p(seconds) / log1p(max(0.001, limit)) }, set: { value in
                    let raw = expm1(value * log1p(limit))
                    change(value >= 1 ? limit : min(limit, (raw * 10).rounded() / 10))
                }), in: 0...1).tint(.mint)
                    .accessibilityLabel(edge.title)
                    .accessibilityValue(seconds.formatted(number) + " seconds")
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: change(min(limit, seconds + 0.1))
                        case .decrement: change(max(0, seconds - 0.1))
                        @unknown default: break
                        }
                    }
            }
        }
        .alert(edge.title + " duration", isPresented: $enteringTime) {
            TextField("Seconds", text: $entry).keyboardType(.decimalPad)
            Button("Cancel", role: .cancel) {}
            Button("Set") { if let entered { change(entered) } }.disabled(entered == nil)
        } message: { Text("Enter 0 to \(limit.formatted(number)) seconds. Zero turns the fade off.") }
    }
}

struct AudioToolEditor: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let project: Project
    let folder: URL
    let request: ToolRequest
    let position: Double
    let initialPlayer: AVPlayer?
    let cancel: () -> Void
    let apply: (EditState) -> Void
    @StateObject private var preview = EditorController()
    @State private var effects: [AudioEffect]
    @State private var volume: Double
    @State private var volumeChosen = false
    @State private var muteChosen = false
    @State private var fadeEdits: [AudioFadeEdge: Double] = [:]
    @State private var listeningEdge: AudioFadeEdge?
    private let fadeTargets: [AudioFadeEdge: (index: Int, label: String)]
    private let mixedVolume: Bool
    private let volumeBounds: ClosedRange<Double>
    private let mixedMute: Bool
    @State private var muted: Bool
    @State private var revision = 0
    @State private var bypass = false
    @State private var dirty = false
    @State private var preparing = false
    @State private var previewRequested = false
    @State private var playWhenReady = false
    @State private var loadedPreview = false
    @State private var originalEnergies: [Float]?
    @State private var matchingHelp = false
    @State private var probe = ""
    @State private var enhancementID = UUID()
    @AppStorage("matchListeningLevels") private var matchListeningLevels = true
    @State private var comparisonGains: (original: Float, processed: Float) = (1, 1)
    private let target: TimelineSelection
    private let base: EditState
    private let mixed: Bool
    init(project: Project, folder: URL, request: ToolRequest, position: Double, initialPlayer: AVPlayer? = nil, cancel: @escaping () -> Void, apply: @escaping (EditState) -> Void) {
        self.project = project; self.folder = folder; self.request = request; self.position = position; self.initialPlayer = initialPlayer; self.cancel = cancel; self.apply = apply
        var targets = request.targets ?? project.edit.timeline.entireSelection(range: EditInterval(request.range)); targets.video = []
        if request.tool == .volume {
            let scoped = project.edit.timeline.scoped(targets)
            var state = project.edit; state.timeline = scoped.timeline
            base = state; target = scoped.selection
        } else { base = project.edit; target = targets }
        let selectionIDs = target.audio
        var endpoints: [AudioFadeEdge: (index: Int, label: String)] = [:]
        if request.tool == .volume {
            let original = project.edit.timeline.audio
            for edge in AudioFadeEdge.allCases {
                guard let i = edge.index(in: base.timeline.audio, selected: selectionIDs) else { continue }
                let part = base.timeline.audio[i]
                let sourceIndex = original.firstIndex { $0.id == part.id } ?? original.firstIndex {
                    $0.occurrenceID == part.occurrenceID && $0.interval.intersection(part.interval) != nil
                }
                let number = sourceIndex.map { "Audio \($0 + 1) · " } ?? ""
                endpoints[edge] = (i, number + editorTime(edge == .fadeIn ? part.start.seconds : part.end.seconds))
            }
        }
        fadeTargets = endpoints
        let items = base.timeline.audio.filter { selectionIDs.contains($0.id) }
        let chains = items.flatMap { item in item.enhancements.filter { region in targets.range.map { $0.intersection(EditInterval(item.start + region.interval.start, item.start + region.interval.end)) != nil } ?? true }.map(\.effects) }
        _effects = State(initialValue: chains.first ?? [])
        mixedVolume = AudioGainGrid.common(items) == nil
        volumeBounds = (items.map(\.volumeDB).min() ?? 0)...(items.map(\.volumeDB).max() ?? 0)
        mixedMute = items.contains(where: \.muted) && items.contains { !$0.muted }
        _volume = State(initialValue: AudioGainGrid.common(items) ?? items.map(\.volumeDB).max() ?? 0); _muted = State(initialValue: !items.isEmpty && items.allSatisfy(\.muted))
        mixed = chains.dropFirst().contains { $0 != chains.first } || items.contains { $0.enhancements.isEmpty } && !chains.isEmpty
    }
    private func state(bypassed: Bool = false) -> EditState {
        var state = base
        if request.tool == .volume {
            for i in state.timeline.audio.indices where target.audio.contains(state.timeline.audio[i].id) {
                if volumeChosen { state.timeline.audio[i].volumeDB = volume }
                if muteChosen { state.timeline.audio[i].muted = muted }
            }
            for (edge, seconds) in fadeEdits {
                if let target = fadeTargets[edge] { state.timeline.audio[target.index].setFade(edge, seconds: seconds) }
            }
        }
        else { state.timeline.enhance(bypassed ? [] : effects, selection: target, effectID: request.effectID ?? enhancementID) }
        return state
    }
    private var listeningRange: ClosedRange<Double> {
        if request.tool == .enhanceAudio { return AudioPreviewWindow.listeningRange(at: position, selection: request.range) }
        if let edge = listeningEdge, let target = fadeTargets[edge] {
            let item = base.timeline.audio[target.index], length = (fadeEdits[edge] ?? item.fadeSeconds(edge)) + 1
            return edge == .fadeIn ? item.start.seconds...min(item.end.seconds, item.start.seconds + length)
                                  : max(item.start.seconds, item.end.seconds - length)...item.end.seconds
        }
        return request.range
    }
    private var displayedPosition: Double { loadedPreview ? preview.playhead : min(listeningRange.upperBound, max(listeningRange.lowerBound, position)) }
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let compact = geometry.size.width > geometry.size.height
                let layout = compact ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
                layout {
                    VStack(spacing: 4) {
                        PlayerSurface(player: loadedPreview ? preview.player : initialPlayer ?? preview.player, inspectionZoom: true, onPlaybackTap: playPreview).frame(minHeight: 120)
                        HStack {
                            Text(editorTime(max(0,displayedPosition-listeningRange.lowerBound))+" / "+editorTime(listeningRange.upperBound-listeningRange.lowerBound)).font(.caption.monospacedDigit()).accessibilityIdentifier("audioTool.position").accessibilityValue(String(format:"%.2f to %.2f; at %.2f",listeningRange.lowerBound,listeningRange.upperBound,displayedPosition)); Spacer()
                            if request.tool == .enhanceAudio {
                                Button { invalidatePreview(); bypass.toggle() } label: { Label(bypass ? "Bypass on" : "Bypass", systemImage: bypass ? "speaker.slash" : "speaker.wave.2").frame(minHeight: 44) }.labelStyle(.iconOnly).frame(width: 44)
                            }
                            Button(action: playPreview) { Label(preparing && request.tool == .enhanceAudio ? "Cancel preview" : preview.playing ? "Pause" : "Play preview", systemImage: preparing && request.tool == .enhanceAudio ? "xmark" : preview.playing ? "pause.fill" : "play.fill").frame(minHeight: 44) }.disabled(preparing && request.tool == .volume)
                        }.padding(.horizontal, 12)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    ScrollView {
                        VStack(alignment: .leading, spacing: request.tool == .volume ? 10 : 16) {
                            Text(request.scopeTitle).font(.subheadline.weight(.semibold)).accessibilityIdentifier("audioTool.scope")
                            #if DEBUG
                            if CommandLine.arguments.contains("--gain-preview-probe") {
                                TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                                    Text(AudioGainMix.auditionDB(on: preview.player.currentItem).map { String(format: "%+.1f dB", $0) } ?? "Committed gain")
                                        .accessibilityIdentifier("audio.gainPreviewProbe")
                                }
                            }
                            #endif
                            if request.tool == .volume {
                                HStack {
                                    Text(mixedVolume && !volumeChosen ? "Mixed levels" : muted ? "Muted" : String(format: "%+.1f dB", volume)).font(.title2.monospacedDigit())
                                    Spacer()
                                    Stepper("Adjust by 0.5 dB", onIncrement: { stepVolume(0.5) }, onDecrement: { stepVolume(-0.5) })
                                        .labelsHidden()
                                }
                                HeadroomSlider(value: $volume, unset: mixedVolume && !volumeChosen, clipping: !muted && (!mixedVolume || volumeChosen) && preview.headroom?.clips(at: volume) == true) {
                                    volumeChosen = true; preview.auditionGain(volume, selection: target)
                                }.frame(minHeight: 44)
                                if !muted && (!mixedVolume || volumeChosen) && preview.headroom?.clips(at: volume) == true {
                                    Label("Clipping at this level", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.caption)
                                } else if !preview.headroomMessage.isEmpty { Text(preview.headroomMessage).font(.caption).foregroundStyle(.secondary) }
                                if mixedVolume && !volumeChosen { Text("Choose a level to set all selected parts to the same gain.").font(.caption).foregroundStyle(.secondary) }
                                if mixedMute && !muteChosen { Text("Some selected parts are muted. Gain preserves their mute settings.").font(.caption).foregroundStyle(.secondary) }
                                let levelActions = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading)) : AnyLayout(HStackLayout())
                                levelActions {
                                    Toggle("Mute", isOn: $muted).fixedSize().onChange(of: muted) { _, _ in muteChosen = true; revision += 1 }
                                    if !typeSize.isAccessibilitySize { Spacer() }
                                    Button("Reset to 0 dB") { volume = 0; muted = false; volumeChosen = true; muteChosen = true; revision += 1 }
                                        .frame(minHeight: 44)
                                }
                                ForEach(AudioFadeEdge.allCases) { edge in
                                    if let endpoint = fadeTargets[edge] {
                                        let item = base.timeline.audio[endpoint.index]
                                        Divider()
                                        AudioFadeRow(edge: edge, target: endpoint.label,
                                                     seconds: fadeEdits[edge] ?? item.fadeSeconds(edge),
                                                     limit: item.mapping.duration.seconds,
                                                     playing: listeningEdge == edge && preview.playing,
                                                     change: { seconds in
                                            if !dirty || preparing { invalidatePreview() }
                                            let value = EditTime(seconds).seconds
                                            fadeEdits[edge] = value == item.fadeSeconds(edge) ? nil : value
                                        }, listen: { listenToFade(edge) })
                                    }
                                }
                            } else {
                                if mixed { Text("This selection contains different chains. Apply replaces them only in this selection.").font(.caption).foregroundStyle(.secondary) }
                                Menu { ForEach(EffectKind.allCases) { kind in Button(kind.title) { changeEffects(effects + [.make(kind)]) } } } label: { Label("Add filter", systemImage: "plus").frame(minHeight: 44) }
                                AudioChainControls(effects: effects, busy: false, compact: compact, change: changeEffects)
                                Text("Play previews up to 5 seconds before and after your playhead, within this selection. Apply uses the full selection.").font(.caption).foregroundStyle(.secondary)
                                Toggle("Match listening levels", isOn: Binding(get: { matchListeningLevels && AudioPreviewLevels.allowsMatching(effects) }, set: { matchListeningLevels = $0 }))
                                    .disabled(!AudioPreviewLevels.allowsMatching(effects))
                                    .onLongPressGesture { matchingHelp = true }
                                    .accessibilityHint("Only affects comparison playback, never the exported file.")
                                if !AudioPreviewLevels.allowsMatching(effects) {
                                    Text("Output gain uses actual volume; level matching is suspended.").font(.caption).foregroundStyle(.secondary)
                                } else if dirty { Text("Play prepares your latest changes.").font(.caption).foregroundStyle(.secondary) }
                                #if DEBUG
                                if CommandLine.arguments.contains("--audio-preview-probe") {
                                    Text(probe).accessibilityIdentifier("audio.previewPCMProbe")
                                    Text(preparing ? "Preparing" : loadedPreview && !dirty ? "Ready" : "Idle").accessibilityIdentifier("audio.previewState")
                                }
                                #endif
                            }
                            if preparing { ProgressView(value: preview.videoProgress); Text(request.tool == .enhanceAudio ? "Preparing " + EffectPreviewWindow.label(listeningRange) : "Preparing audio preview…").font(.caption).accessibilityIdentifier("audioTool.preparing") }
                            if let error = preview.error { Text(error).foregroundStyle(.orange) }
                        }.padding(16).padding(.bottom, 48)
                    }.accessibilityIdentifier("audioTool.controls")
                        .frame(width: compact ? geometry.size.width * 0.55 : nil, height: compact ? nil : geometry.size.height * 0.55)
                }
            }.background(Color(white: 0.06)).navigationTitle(request.tool.title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
                    ToolbarItem(placement: .confirmationAction) { Button("Apply") {
                        let edited = state()
                        apply(request.tool == .volume && edited == base ? project.edit : edited)
                    }.disabled(target.audio.isEmpty) }
                    if request.tool == .enhanceAudio {
                        ToolbarItem(placement: .bottomBar) { Button("Remove", role: .destructive) {
                            var edited = base
                            edited.timeline.enhance([], selection: target)
                            apply(edited)
                        } }
                    }
                }
                .task(id: revision) { if (request.tool == .volume && !dirty) || previewRequested { await preparePreview() } }
                .onChange(of: matchListeningLevels) { _, _ in
                    if request.tool == .enhanceAudio { invalidatePreview(); comparisonGains = (1, 1) }
                    updateListeningVolume()
                }
                .alert("Match listening levels", isPresented: $matchingHelp) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text("Balances the original and processed voice for a fair comparison. It does not affect export, and is suspended when Output gain is enabled so you can hear your volume changes.")
                }
                .onDisappear { preview.stop() }
        }.preferredColorScheme(.dark)
    }
    private func changeEffects(_ value: [AudioEffect]) {
        invalidatePreview(); effects = value; bypass = false
    }
    private func invalidatePreview() {
        preview.pause()
        if preparing { preview.stop(); loadedPreview = false }
        previewRequested = false; playWhenReady = false; preparing = false; dirty = true; revision += 1
    }
    private func playPreview() {
        if preparing { invalidatePreview(); return }
        if !preview.playing, listeningEdge != nil { listeningEdge = nil; preview.previewRange = request.range }
        if !loadedPreview || dirty || preview.error != nil { previewRequested = true; playWhenReady = true; preparing = true; revision += 1 }
        else { preview.togglePlay() }
    }
    private func stepVolume(_ delta: Double) {
        let next = mixedVolume && !volumeChosen ? (delta > 0 ? volumeBounds.upperBound : volumeBounds.lowerBound) : volume + delta
        volume = AudioGainGrid.snap(next); volumeChosen = true
        preview.auditionGain(volume, selection: target)
    }
    private func listenToFade(_ edge: AudioFadeEdge) {
        if listeningEdge == edge && preview.playing { preview.pause(); return }
        preview.pause(); listeningEdge = edge
        if !loadedPreview || dirty || preparing || preview.error != nil {
            playWhenReady = true; previewRequested = true; preparing = true; revision += 1
        } else {
            preview.previewRange = listeningRange
            preview.seekPaused(listeningRange.lowerBound); preview.togglePlay()
        }
    }
    private func updateListeningVolume() {
        preview.player.volume = matchListeningLevels && AudioPreviewLevels.allowsMatching(effects) && request.tool == .enhanceAudio
            ? (bypass ? comparisonGains.original : comparisonGains.processed) : 1
    }
    private func preparePreview() async {
        let token = revision
        preparing = true; preview.error = nil
        defer { if token == revision && !Task.isCancelled { preparing = false } }
        let range = listeningRange
        let anchor = request.tool == .enhanceAudio || listeningEdge != nil ? range.lowerBound : loadedPreview ? preview.playhead : position
        preview.pause(); preview.previewRange = range
        preview.seekAfterEdit(min(range.upperBound, max(range.lowerBound, anchor)), duration: base.duration)
        var candidate = project; candidate.history = [state(bypassed: bypass)]; candidate.historyCursor = 0
        await preview.load(candidate, folder: folder, includeTimelineDetails: false, audioPreviewRange: request.tool == .enhanceAudio ? range : nil)
        guard !Task.isCancelled, token == revision, preview.error == nil else { return }
        do {
            if request.tool == .enhanceAudio {
                if !bypass && effects.contains(where: \.enabled) && AudioPreviewLevels.allowsMatching(effects), let item = preview.player.currentItem {
                    if originalEnergies == nil {
                        var original = project; original.history = [state(bypassed: true)]; original.historyCursor = 0
                        let prepared = try await SourceMediaCache.shared.prepared(project: original, folder: folder, effectPreparation: .cached, audioPreviewRange: range) { _ in }
                        originalEnergies = try await AudioPreviewLevels.energies(asset: prepared.media.composition, mix: prepared.media.audioMix, range: range)
                    }
                    let processed = try await AudioPreviewLevels.energies(asset: item.asset, mix: item.audioMix, range: range)
                    comparisonGains = AudioPreviewLevels.gains(original: originalEnergies ?? [], processed: processed)
                }
                try Task.checkCancellation(); guard token == revision else { return }
                updateListeningVolume()
                #if DEBUG
                if CommandLine.arguments.contains("--audio-preview-probe"), let item = preview.player.currentItem {
                    let energy = try await AudioPreviewLevels.energies(asset: item.asset, mix: item.audioMix, range: range)
                    let mean = energy.reduce(0, +) / Float(max(1, energy.count))
                    probe = String(format: "rms=%.4f; volume=%.4f; bypass=%@", 10 * log10(max(1e-12, mean)), preview.player.volume, bypass ? "yes" : "no")
                }
                #endif
                dirty = false
            }
            try Task.checkCancellation(); guard token == revision else { return }
            loadedPreview = true
            if playWhenReady { playWhenReady = false; preview.togglePlay() }
            if request.tool == .volume {
                dirty = false; previewRequested = false; preparing = false
                await preview.measureHeadroom(selection: target, timeline: candidate.edit.timeline)
            }
        } catch is CancellationError {} catch { preview.error = error.localizedDescription }
    }

}

struct PlacementEditor: View {
    let project: Project
    let folder: URL
    let request: ToolRequest
    let position: Double
    let cancel: () -> Void
    let apply: (EditState) -> Void
    @StateObject private var preview = EditorController()
    @State private var placement: VideoPlacementRegion
    @State private var selected: UUID?
    @State private var endpoint: EffectEndpoint?
    @State private var previewEndpoint: EffectEndpoint?
    @State private var lastEndpoint: EffectEndpoint = .a
    @State private var motions: [UUID: EffectAnimation]
    @State private var explicitPick = false
    @State private var reframe = false
    @State private var revision = 0
    @State private var dragStart: VideoPlacement?
    @State private var pinchStart: VideoPlacement?
    @State private var manipulationID: UUID?
    @State private var cropStart: (id: UUID, value: VideoPlacement)?
    @GestureState private var dragging = false
    @GestureState private var pinching = false
    @State private var loadedRevision = -1
    @State private var stills: [UUID: UIImage] = [:]
    @State private var showingStills = false
    @State private var frameTime: Double
    @State private var stillsTime: Double?
    @State private var stillError: String?
    @State private var reviewing = false
    private let previewRange: ClosedRange<Double>
    private let originalEdit: EditState
    private let initialPlacement: VideoPlacementRegion
    private let inheritedSeed: Bool
    private let members: [VideoTimelineItem]
    init(project: Project, folder: URL, request: ToolRequest, position: Double, cancel: @escaping () -> Void, apply: @escaping (EditState) -> Void) {
        originalEdit = project.edit
        var project = project
        var participantIDs = request.clipIDs ?? []
        if let targets = request.targets, targets.range != nil {
            let scoped = project.edit.timeline.scoped(targets)
            var edit = project.edit; edit.timeline = scoped.timeline
            participantIDs = scoped.selection.video
            project.history = [edit]; project.historyCursor = 0
        }
        self.project = project; self.folder = folder; self.request = request; self.position = position; self.cancel = cancel; self.apply = apply
        members = project.edit.timeline.video.filter { participantIDs.contains($0.id) }.sorted(by: TrackTimeline.backToFront)
        let ids = Set(members.map(\.id))
        initialPlacement = project.edit.timeline.placementSeed(participants: ids, near: EditTime(position))
        let defaults = Dictionary(uniqueKeysWithValues: members.enumerated().map { rank, item in var value = VideoPlacement(); value.order = rank; return (item.id, value) })
        inheritedSeed = !project.edit.timeline.placements.contains { $0.participants == ids } && initialPlacement.videos != defaults
        _placement = State(initialValue: initialPlacement)
        _motions = State(initialValue:initialPlacement.videos.compactMapValues { $0.motion })
        _selected = State(initialValue: VideoPlacement.ordered(members.map(\.id), settings: initialPlacement.videos).last)
        let interval = project.edit.timeline.placementPreviewInterval(participants: ids, near: position, preferred: request.range)
        let lower = max(interval?.start.seconds ?? request.range.lowerBound, request.range.lowerBound)
        let upper = max(lower, min(interval?.end.seconds ?? request.range.upperBound, request.range.upperBound) - TimelineEditing.frame)
        previewRange = lower...upper
        _frameTime = State(initialValue: min(upper, max(lower, position)))
    }
    private var motionDuration: Double { previewRange.upperBound - previewRange.lowerBound + TimelineEditing.frame }
    private var menuMotion: EffectAnimation? { selected.flatMap { motions[$0] } ?? motions.values.first }
    private func captureEndpoints() -> [UUID:EffectAnimation] {
        var values = motions
        for (id, v) in placement.videos where values[id] != nil { values[id]?[endpoint ?? lastEndpoint] = v.pose }
        return values
    }
    private func selectEndpoint(_ e: EffectEndpoint) {
        preview.pause(); reviewing = false
        var captured = captureEndpoints()
        for item in members {
            guard let value = placement.videos[item.id] else { continue }
            let motion = captured[item.id] ?? EffectAnimation(value.pose,duration:motionDuration)
            captured[item.id] = motion
            placement.videos[item.id] = value.applying(motion[e])
        }
        motions = captured; endpoint = e; lastEndpoint = e; returnToEndpoint()
    }
    private func returnToEndpoint() {
        if let endpoint, let m = menuMotion {
            previewEndpoint = endpoint
            frameTime = previewRange.lowerBound + m.timing.endpoint(endpoint,duration:motionDuration,frame:m.frame)
            showingStills = true; revision += 1
        }
    }
    private func finishEndpoint() { motions = captureEndpoints(); endpoint = nil; previewEndpoint = nil }
    private func removeAnimation() {
        motions.removeAll(); endpoint = nil; previewEndpoint = nil
        for id in placement.videos.keys { placement.videos[id]?.motion = nil }; revision += 1
    }
    private func updateTiming(_ timing: EffectTiming) {
        guard let motion = menuMotion, timing != motion.timing else { return }
        let position = (reviewing ? preview.playhead : frameTime) - previewRange.lowerBound
        let target = timing.previewPosition(position, following: previewEndpoint, duration: motionDuration, frame: motion.frame)
        reviewing = false
        preview.pause()
        var captured = captureEndpoints()
        for id in captured.keys { captured[id]?.timing = timing }
        motions = captured
        frameTime = min(previewRange.upperBound, max(previewRange.lowerBound, previewRange.lowerBound + target))
        showingStills = false
        revision += 1
    }
    private func state(removing: Bool = false) -> EditState {
        var placement = self.placement
        let captured = captureEndpoints()
        for item in members {
            guard var motion = captured[item.id], let value = placement.videos[item.id] else { continue }
            motion.duration = motionDuration
            var result = value.applying(motion.a)
            result.motion = motion.placed(on:item.content,offset:item.start.seconds-previewRange.lowerBound,replacing:initialPlacement.videos[item.id]?.motion)
            placement.videos[item.id] = result
        }
        if !removing && !inheritedSeed && placement == initialPlacement { return originalEdit }
        var state = project.edit
        state.timeline.placements.removeAll { $0.participants == placement.participants }
        if !removing {
            state.timeline.placements.append(placement)
            state.timeline.transitions.removeAll { relation in
                let ids = Set([relation.outgoing, relation.incoming].compactMap { $0 })
                return ids.count > 1 && ids.isSubset(of: placement.participants)
            }
            state.timeline.pruneRelations()
        }
        return state
    }
    private func change(_ id: UUID? = nil, _ body: (inout VideoPlacement) -> Void) {
        guard let target = id ?? selected, var value = placement.videos[target] else { return }; body(&value); placement.videos[target] = value; showingStills = true
    }
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let compact = geometry.size.width > geometry.size.height
                let layout = compact ? AnyLayout(HStackLayout(spacing: 16)) : AnyLayout(VStackLayout(spacing: 8))
                layout {
                    InspectPreview(canvas: preview.canvas ?? CGSize(width: 1920, height: 1080)) { GeometryReader { canvas in
                        let aspect = (preview.canvas?.width ?? 1920) / (preview.canvas?.height ?? 1080)
                        let width = max(1, min(canvas.size.width - 48, (canvas.size.height - 48) * aspect))
                        let height = width / aspect
                        ZStack {
                            PlayerSurface(player: preview.player, inspectionZoom: false, identifier: "placement.preview")
                            if showingStills && stillsTime == frameTime && stills.count == members.count { PlacementStillSurface(images: stills, placements: placement.videos, order: orderedIDs).allowsHitTesting(false) }
                            Color.clear.contentShape(Rectangle())
                                .gesture(DragGesture(minimumDistance: 2).updating($dragging) { _, active, _ in active = true }.onChanged { drag in
                                    guard cropStart == nil else { return }
                                    if dragStart == nil {
                                        beginManipulation(x: drag.startLocation.x / max(1, width), y: drag.startLocation.y / max(1, height))
                                        preview.pause(); showingStills = true
                                        dragStart = manipulationID.flatMap { placement.videos[$0] }
                                    }
                                    guard let start = dragStart else { return }
                                    change(manipulationID) { value in
                                        if reframe {
                                            var framed = start; framed.framing.zoom = value.framing.zoom
                                            framed.reframe(by: CGSize(width: drag.translation.width, height: drag.translation.height), canvas: CGSize(width: width, height: height))
                                            value.framing.x = framed.framing.x; value.framing.y = framed.framing.y
                                        }
                                        else {
                                            let size = CGSize(width: width, height: height), original = start.visibleWindow(in: size), current = value.visibleWindow(in: size)
                                            value.x += (original.midX + drag.translation.width - current.midX) / width
                                            value.y += (original.midY + drag.translation.height - current.midY) / height
                                            constrain(&value, canvas: size)
                                        }
                                    }
                                }.onEnded { _ in guard dragStart != nil else { return }; dragStart = nil; if pinchStart == nil { manipulationID = nil; revision += 1 } })
                                .simultaneousGesture(MagnifyGesture().updating($pinching) { _, active, _ in active = true }.onChanged { gesture in
                                    guard cropStart == nil else { return }
                                    if pinchStart == nil {
                                        beginManipulation(x: gesture.startAnchor.x, y: gesture.startAnchor.y, pinchMargin: 44 / width)
                                        preview.pause(); showingStills = true; pinchStart = manipulationID.flatMap { placement.videos[$0] }
                                    }
                                    guard let start = pinchStart else { return }
                                    change(manipulationID) { value in
                                        if reframe { value.framing.zoom = min(8, max(1, start.framing.zoom * gesture.magnification)) }
                                        else {
                                            let size = CGSize(width: width, height: height), original = start.visibleWindow(in: size), before = value.visibleWindow(in: size)
                                            let minimum = min(1, max(44 / original.width, 44 / original.height))
                                            let scale = min(3 / max(start.width, start.height), max(minimum, gesture.magnification))
                                            value.width = start.width * scale; value.height = start.height * scale
                                            let after = value.visibleWindow(in: size)
                                            value.x += (before.midX - after.midX) / width; value.y += (before.midY - after.midY) / height
                                            constrain(&value, canvas: size)
                                        }
                                    }
                                }.onEnded { _ in guard pinchStart != nil else { return }; pinchStart = nil; if dragStart == nil { manipulationID = nil; revision += 1 } })
                                .simultaneousGesture(SpatialTapGesture().onEnded { tap in
                                    let x = tap.location.x / max(1, width), y = tap.location.y / max(1, height)
                                    guard cropStart == nil else { return }
                                    selected = hitTest(x: x, y: y) ?? selected; explicitPick = false
                                }).allowsHitTesting(canManipulate)
                        }.frame(width: width, height: height).clipped().position(x: canvas.size.width / 2, y: canvas.size.height / 2)
                        PlacementCropOverlay(value: canManipulate ? selected.flatMap { placement.videos[$0] } : nil,
                            canvas: CGRect(x: (canvas.size.width - width) / 2, y: (canvas.size.height - height) / 2, width: width, height: height),
                            reframe: reframe, enabled: dragStart == nil && pinchStart == nil,
                            begin: {
                                guard let selected, let value = placement.videos[selected] else { return }
                                preview.pause(); cropStart = (selected, value); showingStills = true
                            }, change: { edge, position in
                                guard let start = cropStart else { return }
                                var value = start.value; value.crop(edge, to: position, canvas: CGSize(width: width, height: height), minimumPoints: 44); placement.videos[start.id] = value
                            }, end: { cancelled in
                                guard let start = cropStart else { return }
                                let changed = placement.videos[start.id] != start.value
                                if cancelled { placement.videos[start.id] = start.value }
                                cropStart = nil
                                if changed && !cancelled { revision += 1 } else if loadedRevision == revision { showingStills = false }
                            }, adjust: { edge, amount in
                                guard let selected, var value = placement.videos[selected] else { return }
                                let size = CGSize(width: width, height: height), bounds = value.visibleWindow(in: size), base = value.pictureWindow(in: size)
                                let position = edge == .left ? (bounds.minX + amount * base.width) / width : edge == .right ? (bounds.maxX - amount * base.width) / width
                                    : edge == .top ? (bounds.minY + amount * base.height) / height : (bounds.maxY - amount * base.height) / height
                                value.crop(edge, to: position, canvas: size, minimumPoints: 44); preview.pause(); placement.videos[selected] = value; showingStills = true; revision += 1
                            }).frame(width: canvas.size.width, height: canvas.size.height)
                    } }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            EffectAnimationControls(motion:menuMotion,endpoint:endpoint,duration:motionDuration,select:selectEndpoint,remove:removeAnimation,done:finishEndpoint,update:updateTiming)
                            Text(overlapTitle).font(.subheadline.weight(.semibold))
                            HStack {
                                Text(editorTime(reviewing ? preview.playhead : frameTime)).monospacedDigit().accessibilityIdentifier("placement.time")
                                Spacer()
                                Button(preview.playing ? "Pause" : "Play preview", action: togglePreview).frame(minHeight: 44).disabled(preview.loading)
                            }
                            Slider(value: Binding(get: { frameTime }, set: { previewEndpoint = nil; frameTime = $0; showingStills = false; preview.seek($0) }), in: previewRange.lowerBound...max(previewRange.lowerBound + 0.00001, previewRange.upperBound), onEditingChanged: { editing in
                                if editing { reviewing = false; preview.pause(); stillsTime = nil }
                                else { revision += 1 }
                            }).accessibilityLabel("Overlap preview position").disabled(preview.loading || reviewing)
                            Group {
                            Text("Drag to \(reframe ? "reframe" : "move") · pinch to \(reframe ? "zoom" : "resize")\nDrag edge circles to crop").font(.caption).foregroundStyle(.secondary)
                            HStack {
                            Picker("Video", selection: Binding(get: { selected }, set: { selected = $0; explicitPick = true })) { ForEach(members) { item in Text(videoLabel(item)).tag(Optional(item.id)) } }.pickerStyle(.menu).labelsHidden().accessibilityLabel("Video").accessibilityValue(members.first(where: { $0.id == selected }).map(videoLabel) ?? "").accessibilityIdentifier("placement.video")
                            Spacer(minLength: 8)
                            Menu {
                                Text("Layouts reset crop, framing and Fit")
                                Button("Cover") { preset(0) }
                                Button("Side by side") { preset(1) }
                                Button("Top and bottom") { preset(2) }
                                Button("Picture in picture") { preset(3) }
                            } label: { Label("Layout", systemImage: "rectangle.split.2x1").frame(minHeight: 44) }
                            }
                            Toggle("Reframe inside window", isOn: $reframe)
                            HStack {
                                Button("Bring to front") { let order = (placement.videos.values.map(\.order).max() ?? 0) + 1; change { $0.order = order }; revision += 1 }
                                Button("Send to back") { let order = (placement.videos.values.map(\.order).min() ?? 0) - 1; change { $0.order = order }; revision += 1 }
                            }.buttonStyle(.bordered).frame(minHeight: 44)
                            if let selected, let value = placement.videos[selected] {
                                Toggle("Fill window", isOn: Binding(get: { value.fill }, set: { new in change { $0.fill = new }; revision += 1 }))
                                HStack {
                                    Button("Center picture") { change { $0.framing = TransitionFraming() }; revision += 1 }
                                    Spacer(minLength: 8)
                                    Button("Reset crop") { change { $0.edgeCrop = nil }; revision += 1 }
                                        .disabled(value.edgeCrop == nil).accessibilityIdentifier("placement.resetCrop")
                                }.frame(minHeight: 44)
                            }
                            }.disabled(reviewing)
                            if preview.loading || (!reviewing && stillsTime != frameTime && stillError == nil) { ProgressView("Preparing frame…") }
                            if let stillError { Text(stillError).font(.caption).foregroundStyle(.orange); Button("Retry frame") { revision += 1 } }
                            if let error = preview.error { Text(error).font(.caption).foregroundStyle(.orange) }
                            if project.edit.timeline.transitions.contains(where: { relation in
                                let ids = Set([relation.outgoing, relation.incoming].compactMap { $0 }); return ids.count > 1 && ids.isSubset(of: placement.participants)
                            }) { Label("Changing this arrangement replaces the transition between these videos", systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.orange) }
                            Text("Audio from overlapping clips mixes. Select an audio item in the timeline to change its volume.").font(.caption).foregroundStyle(.secondary)
                            Button("Reset placement", role: .destructive) { apply(state(removing: true)) }.frame(minHeight: 44)
                        }.padding(16)
                    }.accessibilityIdentifier("placement.controls")
                        .frame(width: compact ? geometry.size.width * 0.4 : nil, height: compact ? nil : geometry.size.height * 0.45)
                }
            }.background(Color.black).navigationTitle("Placement").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
                    ToolbarItem(placement: .confirmationAction) { Button("Apply") { apply(state()) }.disabled(members.count < 2) }
                }
                .task(id: revision) {
                    let version = revision, time = frameTime
                    var candidate = project; candidate.history = [state()]; candidate.historyCursor = 0
                    await preview.load(candidate, folder: folder)
                    guard !Task.isCancelled else { return }
                    preview.player.currentItem?.forwardPlaybackEndTime = CMTime(seconds: previewRange.upperBound + 1.0 / 30, preferredTimescale: 240000)
                    let ready = await preview.seekAndWait(time)
                    if stillsTime != time || stills.count != members.count { await prepareStills(at: time) }
                    if ready && !Task.isCancelled && revision == version {
                        loadedRevision = version
                        if dragStart == nil && pinchStart == nil && cropStart == nil { showingStills = false }
                    }
                }
                .onChange(of:placement.videos) { previous, current in
                    if current != previous, !motions.isEmpty, previewEndpoint == nil {
                        endpoint = lastEndpoint; returnToEndpoint()
                    }
                }
                .onChange(of: preview.playing) { _, active in
                    if !active && reviewing { finishPreview() }
                }
                // Each gesture owns its cancellation state: lifting a pinch
                // finger must not reset a drag that is still in progress.
                .onChange(of: dragging) { _, active in
                    if !active && dragStart != nil {
                        dragStart = nil
                        if pinchStart == nil { manipulationID = nil; revision += 1 }
                    }
                }
                .onChange(of: pinching) { _, active in
                    if !active && pinchStart != nil {
                        pinchStart = nil
                        if dragStart == nil { manipulationID = nil; revision += 1 }
                    }
                }
                .onDisappear { preview.stop() }
        }.preferredColorScheme(.dark)
    }
    private var overlapTitle: String {
        let labels = members.map { item in "V" + String((project.edit.timeline.video.firstIndex(of:item) ?? 0)+1) }
        let range = editorTime(previewRange.lowerBound) + "–" + editorTime(previewRange.upperBound + TimelineEditing.frame)
        return labels.joined(separator:" + ") + " · " + range
    }
    private var orderedIDs: [UUID] { VideoPlacement.ordered(members.map(\.id), settings: placement.videos) }
    private var canManipulate: Bool { !reviewing && stillsTime == frameTime && stills.count == members.count }
    private func togglePreview() {
        if reviewing { finishPreview() }
        else {
            previewEndpoint = nil; showingStills = false; reviewing = true
            if endpoint != nil || preview.playhead >= previewRange.upperBound - 0.02 { preview.seek(previewRange.lowerBound) }
            preview.togglePlay()
        }
    }
    private func finishPreview() {
        reviewing = false; preview.pause()
        if endpoint != nil { returnToEndpoint(); return }
        let time = preview.player.currentTime().seconds
        frameTime = min(previewRange.upperBound, max(previewRange.lowerBound, time.isFinite ? time : frameTime))
        showingStills = false; revision += 1
    }
    private var sourceCanvas: CGSize { preview.canvas ?? CGSize(width: 1920, height: 1080) }
    private func beginManipulation(x: Double, y: Double, pinchMargin: Double = 0) {
        guard manipulationID == nil else { return }
        // Retain a deliberately selected occluded window; otherwise choose
        // what the finger touches. Both simultaneous gestures lock this ID.
        let point = CGPoint(x: x * sourceCanvas.width, y: y * sourceCanvas.height)
        let window = selected.flatMap { placement.videos[$0]?.visibleWindow(in: sourceCanvas) }
        let hit = hitTest(x: x, y: y), hitWindow = hit.flatMap { placement.videos[$0]?.visibleWindow(in: sourceCanvas) }
        let marginIsClear = hit == nil || hit == selected || (hitWindow.map { $0.width * $0.height >= sourceCanvas.width * sourceCanvas.height * 0.5 } ?? false)
        if explicitPick && window?.contains(point) == true {
            manipulationID = selected
        } else if pinchMargin > 0 && marginIsClear, let window, window.width * window.height < sourceCanvas.width * sourceCanvas.height * 0.5,
                  window.insetBy(dx: -pinchMargin * sourceCanvas.width, dy: -pinchMargin * sourceCanvas.width).contains(point) {
            manipulationID = selected
        } else { manipulationID = hit; explicitPick = false }
        if let manipulationID { selected = manipulationID }
    }
    private func hitTest(x: Double, y: Double) -> UUID? {
        let point = CGPoint(x: x * sourceCanvas.width, y: y * sourceCanvas.height)
        return orderedIDs.reversed().first { placement.videos[$0]?.visibleWindow(in: sourceCanvas).contains(point) == true }
    }
    private func videoLabel(_ item: VideoTimelineItem) -> String {
        let ids = orderedIDs, rank = ids.firstIndex(of: item.id) ?? 0
        let depth = rank == ids.count - 1 ? "front" : rank == 0 ? "back" : "middle \(rank + 1) of \(ids.count)"
        return "V\((project.edit.timeline.video.firstIndex { $0.id == item.id } ?? 0) + 1) · " + depth
    }
    private func prepareStills(at position: Double) async {
        var images: [UUID: UIImage] = [:]
        stillError = nil
        for item in members {
            do {
                var candidate = project
                candidate.history = [EditState(clips: [item.content], outputSize: project.edit.outputSize)]; candidate.historyCursor = 0
                let media = try await MediaRenderer.sourceTimeline(project: candidate, folder: folder, canvasSize: preview.canvas, includeBackgroundAudio: false, effectPreparation: .cached)
                let generator = AVAssetImageGenerator(asset: media.composition); generator.videoComposition = media.videoComposition
                generator.maximumSize = CGSize(width: 800, height: 800)
                generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
                let time = min(item.mapping.duration.seconds - 1 / 30, max(0, position - item.start.seconds))
                let frame = try await generator.image(at: CMTime(seconds: max(0, time), preferredTimescale: 240000))
                try Task.checkCancellation(); images[item.id] = UIImage(cgImage: frame.image)
            } catch {
                if Task.isCancelled { return }
                stillError = "This frame could not be prepared. Choose another position or retry."
            }
        }
        guard !Task.isCancelled, frameTime == position else { return }
        stills = images; stillsTime = position
    }
    private func constrain(_ value: inout VideoPlacement, canvas: CGSize) {
        let visible = value.visibleWindow(in: canvas)
        func coordinate(_ raw: Double, leading: Double, trailing: Double, points: Double) -> Double {
            let keep = min(44 / points, trailing - leading)
            let bounded = min(1 - keep - leading, max(keep - trailing, raw))
            let anchors = [0.5 - (leading + trailing) / 2, -leading, 1 - trailing]
            return anchors.first { abs($0 - bounded) < 0.012 } ?? bounded
        }
        value.x = coordinate(value.x, leading: visible.minX / canvas.width - value.x, trailing: visible.maxX / canvas.width - value.x, points: canvas.width)
        value.y = coordinate(value.y, leading: visible.minY / canvas.height - value.y, trailing: visible.maxY / canvas.height - value.y, points: canvas.height)
    }
    private func preset(_ kind: Int) {
        showingStills = true
        for (index, id) in orderedIDs.enumerated() {
            let value = VideoPlacement.layout(kind, index: index, count: members.count)
            placement.videos[id] = value
        }
        revision += 1
    }
}

/// Lightweight drag feedback using the same placement transform as export.
/// Frames include the item's crop, text and video effects, prepared once.
private struct PlacementStillSurface: UIViewRepresentable {
    let images: [UUID: UIImage]
    let placements: [UUID: VideoPlacement]
    let order: [UUID]
    func makeUIView(context: Context) -> PlacementStillView { PlacementStillView() }
    func updateUIView(_ view: PlacementStillView, context: Context) { view.show(images, placements: placements, order: order) }
}
private final class PlacementStillView: UIView {
    private struct Picture {
        let window = UIView()
        let crop = UIView()
        let image = UIImageView()
    }
    private var pictures: [UUID: Picture] = [:]
    private var placements: [UUID: VideoPlacement] = [:]
    private var order: [UUID] = []
    func show(_ images: [UUID: UIImage], placements: [UUID: VideoPlacement], order: [UUID]) {
        backgroundColor = .black; clipsToBounds = true
        for id in Array(pictures.keys) where images[id] == nil { pictures.removeValue(forKey: id)?.window.removeFromSuperview() }
        for (id, image) in images {
            if pictures[id] == nil {
                let picture = Picture(); picture.window.clipsToBounds = true; picture.crop.clipsToBounds = true
                picture.image.contentMode = .scaleToFill; picture.window.addSubview(picture.crop); picture.crop.addSubview(picture.image)
                addSubview(picture.window); pictures[id] = picture
            }
            pictures[id]?.image.image = image
        }
        self.placements = placements; self.order = order; setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        // Prepared stills already share the render canvas. Moving UIKit layers
        // avoids a GPU render/readback for every finger event.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for id in order {
            guard let settings = placements[id] else { continue }
            guard let picture = pictures[id], let image = picture.image.image else { continue }
            let window = CGRect(x: (settings.x - settings.width / 2) * bounds.width,
                                y: (settings.y - settings.height / 2) * bounds.height,
                                width: settings.width * bounds.width, height: settings.height * bounds.height)
            let source = image.size
            let crop = settings.framing.crop(source: source, viewport: settings.fill ? window.size : source)
            let scale = settings.fill ? max(window.width / crop.width, window.height / crop.height) : min(window.width / crop.width, window.height / crop.height)
            let visible = settings.visibleWindow(in: bounds.size)
            picture.window.frame = visible
            picture.crop.frame = CGRect(x: window.minX - visible.minX + (window.width - crop.width * scale) / 2,
                                        y: window.minY - visible.minY + (window.height - crop.height * scale) / 2,
                                        width: crop.width * scale, height: crop.height * scale)
            picture.image.frame = CGRect(x: -crop.minX * scale, y: -crop.minY * scale, width: source.width * scale, height: source.height * scale)
            bringSubviewToFront(picture.window)
        }
    }
}

/// Only the four edge targets intercept touches; the picture keeps its existing
/// pan/pinch gestures. One recognizer resolves the nearest handle even when a
/// narrow crop makes the 44-point touch targets overlap.
private struct PlacementCropOverlay: UIViewRepresentable {
    let value: VideoPlacement?
    let canvas: CGRect
    let reframe: Bool
    let enabled: Bool
    let begin: () -> Void
    let change: (PlacementCropEdge, Double) -> Void
    let end: (Bool) -> Void
    let adjust: (PlacementCropEdge, Double) -> Void
    func makeUIView(context: Context) -> PlacementCropHandleView { PlacementCropHandleView() }
    func updateUIView(_ view: PlacementCropHandleView, context: Context) {
        view.value = value; view.canvas = canvas; view.reframe = reframe; view.enabled = enabled
        view.begin = begin; view.change = change; view.end = end; view.adjust = adjust
        view.refresh()
    }
}
private final class PlacementCropHandleView: UIView {
    var value: VideoPlacement?
    var canvas = CGRect.zero
    var reframe = false
    var enabled = true
    var begin: () -> Void = {}
    var change: (PlacementCropEdge, Double) -> Void = { _, _ in }
    var end: (Bool) -> Void = { _ in }
    var adjust: (PlacementCropEdge, Double) -> Void = { _, _ in }
    private var active: (edge: PlacementCropEdge, point: CGPoint)?
    private var elements: [PlacementCropEdge: CropEdgeAccessibilityElement] = [:]
    override init(frame: CGRect) {
        super.init(frame: frame); backgroundColor = .clear; isAccessibilityElement = false
        let pan = PlacementEdgePanRecognizer(target: self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1; addGestureRecognizer(pan)
        for edge in PlacementCropEdge.allCases {
            let element = CropEdgeAccessibilityElement(accessibilityContainer: self)
            element.accessibilityLabel = "Crop \(edge.rawValue) edge"
            element.accessibilityIdentifier = "placement.crop.\(edge.rawValue)"
            element.accessibilityTraits = [.adjustable]
            element.accessibilityHint = "Drag this edge to crop without resizing the picture. Swipe up to crop more, down to restore."
            element.adjust = { [weak self] amount in self?.adjust(edge, amount) }
            elements[edge] = element
        }
        accessibilityElements = PlacementCropEdge.allCases.compactMap { elements[$0] }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private var visible: CGRect? {
        value.map { $0.visibleWindow(in: canvas.size).offsetBy(dx: canvas.minX, dy: canvas.minY) }
    }
    private var points: [PlacementCropEdge: CGPoint] {
        guard let visible, canvas.width > 0, canvas.height > 0 else { return [:] }
        func x(_ x: Double) -> Double { min(canvas.maxX, max(canvas.minX, x)) }
        func y(_ y: Double) -> Double { min(canvas.maxY, max(canvas.minY, y)) }
        let intersection = visible.intersection(canvas)
        let middle = intersection.isNull ? CGPoint(x: x(visible.midX), y: y(visible.midY)) : CGPoint(x: intersection.midX, y: intersection.midY)
        return [.left: CGPoint(x: x(visible.minX), y: middle.y), .right: CGPoint(x: x(visible.maxX), y: middle.y),
                .top: CGPoint(x: middle.x, y: y(visible.minY)), .bottom: CGPoint(x: middle.x, y: y(visible.maxY))]
    }
    private func nearest(_ point: CGPoint) -> (PlacementCropEdge, CGPoint)? {
        guard enabled else { return nil }
        return PlacementCropEdge.allCases.compactMap { edge -> (PlacementCropEdge, CGPoint)? in
            guard let position = points[edge], let visible else { return nil }
            // Leave a useful interior for moving even a small cropped window.
            let span = edge.horizontal ? visible.width : visible.height
            let inward = span < 88 ? 7.0 : 14.0, outward = 44 - inward
            let dx = point.x - position.x, dy = point.y - position.y
            let normal = edge == .left ? dx : edge == .right ? -dx : edge == .top ? dy : -dy
            let tangent = edge.horizontal ? abs(dy) : abs(dx)
            guard normal >= -outward, normal <= inward, tangent <= 22 else { return nil }
            return (edge, position)
        }.min { hypot($0.1.x - point.x, $0.1.y - point.y) < hypot($1.1.x - point.x, $1.1.y - point.y) }
    }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { nearest(point) != nil }
    func refresh() {
        setNeedsDisplay(); accessibilityElementsHidden = value == nil || !enabled
        accessibilityElements = value == nil || !enabled ? [] : PlacementCropEdge.allCases.compactMap { elements[$0] }
        for edge in PlacementCropEdge.allCases {
            guard let point = points[edge], let element = elements[edge] else { continue }
            element.accessibilityFrameInContainerSpace = CGRect(x: point.x - 22, y: point.y - 22, width: 44, height: 44)
            element.accessibilityValue = "\(Int(((value?.edgeCrop ?? PlacementEdgeCrop())[edge] * 100).rounded()))% cropped"
        }
    }
    @objc private func panned(_ gesture: PlacementEdgePanRecognizer) {
        guard let touchDown = gesture.touchDown else { return }
        let location = gesture.location(in: self)
        let translation = CGPoint(x: location.x - touchDown.x, y: location.y - touchDown.y)
        if gesture.state == .began {
            guard let target = nearest(touchDown) else { return }
            active = (target.0, target.1); begin()
        }
        if let active, gesture.state == .began || gesture.state == .changed || gesture.state == .ended {
            let position = active.edge.horizontal ? (active.point.x + translation.x - canvas.minX) / max(1, canvas.width)
                : (active.point.y + translation.y - canvas.minY) / max(1, canvas.height)
            let base = value?.pictureWindow(in: canvas.size) ?? .zero
            let original = active.edge == .left ? base.minX / canvas.width : active.edge == .right ? base.maxX / canvas.width
                : active.edge == .top ? base.minY / canvas.height : base.maxY / canvas.height
            let threshold = 5 / (active.edge.horizontal ? canvas.width : canvas.height)
            let snapped = [original, 0, 0.5, 1].first { abs($0 - position) < threshold } ?? position
            change(active.edge, snapped)
        }
        if active != nil, [.ended, .cancelled, .failed].contains(gesture.state) {
            active = nil; end(gesture.state != .ended)
        }
        setNeedsDisplay()
    }
    override func draw(_ rect: CGRect) {
        guard let visible, let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState(); context.clip(to: canvas.insetBy(dx: -1, dy: -1))
        context.setStrokeColor(UIColor.systemYellow.cgColor); context.setLineWidth(1.5)
        if reframe { context.setLineDash(phase: 0, lengths: [6, 4]) }
        context.stroke(visible); context.restoreGState()
        for (edge, point) in points {
            let dot = CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14)
            context.setFillColor((active?.edge == edge ? UIColor.systemYellow : .white).cgColor)
            context.setStrokeColor(UIColor.black.withAlphaComponent(0.8).cgColor); context.setLineWidth(2)
            context.fillEllipse(in: dot); context.strokeEllipse(in: dot)
        }
    }
}
/// UIKit's pan translation excludes the recognition slop on some OS versions.
/// Keep the real touch-down location so an edge tracks the finger exactly,
/// including when its narrow inward hit target is crossed before recognition.
private final class PlacementEdgePanRecognizer: UIPanGestureRecognizer {
    private(set) var touchDown: CGPoint?
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if touchDown == nil, let touch = touches.first { touchDown = touch.location(in: view) }
        super.touchesBegan(touches, with: event)
    }
    override func reset() { super.reset(); touchDown = nil }
}
private final class CropEdgeAccessibilityElement: UIAccessibilityElement {
    var adjust: (Double) -> Void = { _ in }
    override func accessibilityIncrement() { adjust(0.02) }
    override func accessibilityDecrement() { adjust(-0.02) }
}

#if DEBUG
/// Exercise the actual UIKit drag surface against the export compositor on
/// device. Generated patterns make orientation, framing and ordering measurable.
@MainActor enum PlacementPreviewDiagnostics {
    static func run() throws -> [Double] {
        let canvas = CGSize(width: 320, height: 180), bounds = CGRect(origin: .zero, size: canvas)
        let ids = (0..<3).map { _ in UUID() }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true; format.preferredRange = .standard
        let renderer = UIGraphicsImageRenderer(size: canvas, format: format)
        var images: [UUID: UIImage] = [:]
        for (index, id) in ids.enumerated() {
            images[id] = renderer.image { context in
                UIColor(hue: Double(index) / 3, saturation: 0.7, brightness: 0.8, alpha: 1).setFill(); context.fill(bounds)
                for x in stride(from: 0, to: 320, by: 20) {
                    UIColor(white: Double(x) / 400, alpha: 1).setFill(); context.fill(CGRect(x: x, y: 20 + index * 15, width: 12, height: 40))
                }
                UIColor.white.setFill(); context.fill(CGRect(x: 10, y: 5, width: 32, height: 12))
            }
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ci = CIContext(options: [.workingColorSpace: space, .outputColorSpace: space])
        func bytes(_ image: CGImage) -> [UInt8] {
            var values = [UInt8](repeating: 0, count: 320 * 180 * 4)
            values.withUnsafeMutableBytes { raw in
                let context = CGContext(data: raw.baseAddress, width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: 1280, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
                context.draw(image, in: bounds)
            }
            return values
        }
        var errors: [Double] = []
        for scenario in 0..<5 {
            var settings: [UUID: VideoPlacement] = [:]
            for (i, id) in ids.enumerated() {
                var value = VideoPlacement(); value.order = scenario == 1 ? 0 : i
                if scenario >= 2 {
                    value.width = 0.75 - Double(i) * 0.12; value.height = 0.8 - Double(i) * 0.15
                    value.x = 0.35 + Double(i) * 0.14; value.y = 0.4 + Double(i) * 0.15
                    value.fill = scenario != 3; value.framing = TransitionFraming(x: 0.3, y: 0.65, zoom: 1.7)
                    value.edgeCrop = PlacementEdgeCrop(left: 0.08, right: 0.12, top: 0.1, bottom: 0.15)
                    if scenario == 4 { value.x -= 0.25; value.order = 2 - i }
                }
                settings[id] = value
            }
            let order = VideoPlacement.ordered(ids, settings: settings)
            let view = PlacementStillView(frame: bounds); view.show(images, placements: settings, order: order); view.layoutIfNeeded()
            let actual = renderer.image { view.layer.render(in: $0.cgContext) }
            var expected = CIImage(color: .black).cropped(to: bounds)
            for id in order {
                expected = TrackRenderer.placed(CIImage(cgImage: images[id]!.cgImage!), settings: settings[id]!, canvas: canvas).composited(over: expected)
            }
            guard let reference = ci.createCGImage(expected, from: bounds), let rendered = actual.cgImage else { throw ProjectError.invalidMedia }
            let left = bytes(reference), right = bytes(rendered)
            let error = zip(left, right).enumerated().filter { $0.offset % 4 != 3 }.reduce(0.0) { $0 + abs(Double($1.element.0) - Double($1.element.1)) } / Double(320 * 180 * 3)
            errors.append(error)
            guard error < 3 else { throw NSError(domain: "PlacementPreviewQA", code: scenario, userInfo: [NSLocalizedDescriptionKey: "Arrange drag/export mismatch in scenario \(scenario): \(error)/255"]) }
        }
        return errors
    }
}
#endif
