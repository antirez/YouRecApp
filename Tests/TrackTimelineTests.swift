import Foundation

func trackTimelineTests() throws {
    try reviewRegressionTests()
    try timelineNavigationTests()
    try transitionPresentationTests()
    try overlapInteractionTests()
    try placementCropTests()
    try multiSelectionTests()
    try moveCompanionTests()
    try moveBoundaryChecks()
    try timelineClipboardChecks()
    let source = SourceMedia(filename: "source.mp4", duration: 4)
    let a = TimelineClip(sourceID: source.id, start: 0, end: 2)
    let b = TimelineClip(sourceID: source.id, start: 2, end: 4)
    let sequential = EditState(clips: [a, b])
    let baseline = TrackTimeline(sequence: sequential)
    try baseline.validate(sources: [source])
    try require(baseline == TrackTimeline(sequence: sequential), "Conversion gives stable AV/link identities")
    try require(baseline.duration == EditTime(4), "Independent timeline preserves complete source duration")
    let first = baseline.selection(of: a.id)
    let splitElsewhere = TimelineEditing.split(sequential, at: 3, selectedItems: first.ids).timeline
    try require(splitElsewhere.video.map(\.start) == [.zero, EditTime(2), EditTime(3)] &&
                splitElsewhere.audio.map(\.start) == [.zero, EditTime(2), EditTime(3)] &&
                splitElsewhere.video.first == baseline.video.first && splitElsewhere.duration == baseline.duration,
                "A selection in the first clip still allows one synchronized cut in the second")
    try require(TimelineEditing.split(sequential, at: 4, selectedItems: first.ids) == sequential,
                "An old selection cannot create an empty clip at the project end")
    for (before, after) in [(0.5, 0.0), (2.0, 0.0), (3.25, 1.25), (4.0, 2.0)] {
        var cut = baseline
        try require(cut.remove(first, preserving: EditTime(before)) == EditTime(after), "Ripple deletion follows surviving content, or lands at the cut when current content is removed")
    }
    var endCut = baseline
    try require(endCut.remove(baseline.selection(of: b.id), preserving: EditTime(0.75)) == EditTime(0.75), "A later deletion leaves the playhead untouched")
    var overlaidCut = baseline
    var cover = baseline.video[0]; cover.content.id = UUID(); cover.start = EditTime(0.25); cover.layer = 99
    overlaidCut.video.append(cover)
    try require(overlaidCut.remove(first, preserving: EditTime(1)) == .zero, "Deleted linked footage lands at its cut even under a stationary detached overlay")
    try require(first.video == [a.id] && first.audio.count == 1, "Linked selection includes exactly its picture and sound")
    var ripple = baseline
    ripple.remove(first)
    try require(ripple.duration == EditTime(2) && ripple.video[0].start == .zero && ripple.audio[0].start == .zero, "Linked deletion closes gap in both components")
    var separate = baseline
    separate.unlink(first)
    let splitSound = TimelineEditing.split(EditState(timeline: separate), at: 1, selectedItems: [separate.audio[0].id]).timeline
    try require(splitSound.video == separate.video && splitSound.audio.map(\.start) == [.zero, EditTime(1), EditTime(2)],
                "An explicitly selected detached audio part at the playhead still splits independently")
    try require(separate.video == baseline.video && separate.audio.map(\.mapping) == baseline.audio.map(\.mapping) && separate.audio.map(\.start) == baseline.audio.map(\.start), "Unlink changes no timing, samples or settings")
    var audioOnly = separate
    let soundPosition = audioOnly.remove(separate.selection(of: baseline.audio[0].id), preserving: EditTime(3))
    try require(soundPosition == EditTime(3), "Detached audio deletion keeps the absolute playhead")
    try require(audioOnly.video == baseline.video && audioOnly.audio == [baseline.audio[1]] && audioOnly.duration == EditTime(4), "Deleting unlinked audio leaves silence without moving any video")
    var videoOnly = separate
    let picturePosition = videoOnly.remove(separate.selection(of: a.id), preserving: EditTime(1))
    try require(picturePosition == EditTime(1), "Detached video deletion leaves the playhead in the resulting gap")
    try require(videoOnly.audio == separate.audio && videoOnly.video == [baseline.video[1]] && videoOnly.duration == EditTime(4), "Deleting unlinked video leaves picture gap without moving sound")
    var moving = separate
    moving.move(moving.selection(of: a.id), by: EditTime(2.5))
    try require(moving.audio == separate.audio && moving.video[0].start == EditTime(2.5), "Moving detached video leaves audio immutable")
    try require(moving.compile().contains { $0.video.count == 2 && $0.video.last == a.id }, "Overlap compiler orders newly moved video in foreground")
    moving.move(moving.selection(of: a.id), by: EditTime(-30))
    try require(moving.video[0].start == .zero, "Move clamps whole group at project start")
    var linkedMove = baseline
    linkedMove.move(first, by: EditTime(1))
    try require(linkedMove.video[0].start == linkedMove.audio[0].start, "Moving linked AV preserves sync")
    var bed = baseline
    bed.unlink(bed.selection(of: b.id))
    let detached = bed.audio[1]
    bed.remove(first)
    try require(bed.audio.contains(detached), "Deleting a linked clip never cuts or shifts detached audio")
    var marks = baseline
    marks.addBookmark(at: EditTime(1))
    try require(marks.snapTarget(1.02, scale: 60) == 1, "Stationary source marks are snap targets")
    try require(marks.snapTarget(1.02, scale: 60, excluding: first.ids) == nil, "Moving footage never snaps to its own attached bookmark")
    let selected = marks.selection(of: a.id)
    marks.split(at: EditTime(1), selection: selected)
    try require(marks.duration == baseline.duration && marks.video.count == 3 && marks.audio.count == 3 && marks.links.count == 3, "Split preserves all source and creates independent linked pairs")
    try require(marks.resolvedBookmarks.count == 1 && marks.resolvedBookmarks[0].time == EditTime(1), "Bookmark at a split is not duplicated")
    let right = marks.video.first { $0.start == EditTime(1) }!
    marks.move(marks.selection(of: right.id), by: EditTime(4))
    try require(marks.resolvedBookmarks[0].time == EditTime(5), "Source bookmark follows its occurrence after split and move")
    try marks.validate(sources: [source])
    let range = baseline.entireSelection(range: EditInterval(0.5...3.5))
    var scoped = baseline.scoped(range)
    let rangePosition = scoped.timeline.remove(scoped.selection, preserving: EditTime(3.75))
    try require(rangePosition == EditTime(0.75), "Range deletion preserves the source frame after scoping splits")
    try require(abs(scoped.timeline.duration.seconds - 1) < 0.00001, "Range deletion splits linked AV and closes the exact interval")
    try require(scoped.timeline.video.map { $0.content.start } == [0, 3.5] && scoped.timeline.video.map { $0.content.end } == [0.5, 4], "Range deletion preserves exact outer source pieces")
    var enhancements = baseline
    let audioID = baseline.audio[0].id
    let gain = AudioEffect(kind: .gain, amount: -6)
    enhancements.enhance([gain], selection: TimelineSelection(audio: [audioID], range: EditInterval(0.5...1.5)))
    enhancements.enhance([AudioEffect(kind: .gain, amount: -3)], selection: TimelineSelection(audio: [audioID], range: EditInterval(1...2)))
    try require(enhancements.audio[0].enhancements.count == 2 && enhancements.audio[0].enhancements[0].interval == EditInterval(0.5...1), "Partial enhancement replaces intersection without double processing")
    let unchanged = enhancements
    enhancements.enhance([gain], selection: TimelineSelection(audio: [audioID], range: EditInterval(3...4)))
    try require(enhancements == unchanged, "Nonintersecting enhancement does not broaden to whole clip")
    try enhancements.validate(sources: [source])
    var insertion = baseline
    insertion.insertTime(EditTime(1), at: EditTime(1))
    try require(insertion.duration == EditTime(5) && insertion.video.count == 3, "Insert time preserves crossing pieces and shifts right side")
    try insertion.validate(sources: [source])
    let allCopy = baseline.copied(baseline.selection(of: a.id))
    var pasted = baseline
    let fresh = pasted.paste(allCopy, at: EditTime(1))
    try require(allCopy.insertsTime && pasted.duration == EditTime(6) && fresh.video.count == 1 && fresh.audio.count == 1, "Linked clipboard inserts time and keeps both components")
    try pasted.validate(sources: [source])
    let soundCopy = separate.copied(separate.selection(of: audioID))
    var overlaid = separate
    let soundPaste = overlaid.paste(soundCopy, at: EditTime(1))
    try require(!soundCopy.insertsTime && overlaid.video == separate.video && soundPaste.video.isEmpty && soundPaste.audio.count == 1 && overlaid.duration == separate.duration, "Audio paste overlays sound without shifting picture")
    try overlaid.validate(sources: [source])
    let viewport = TimelineViewport(width: 402, duration: 960, requestedScale: 0.01)
    try require(viewport.fits && viewport.x(0, offset: 0) >= 0 && viewport.x(960, offset: 0) <= 402 && viewport.minimumScale < 0.4, "Whole-project fit shows both ends of a sixteen-minute project and escapes 201-second limit")
    var capture = source; capture.events = [CaptureEvent(time: 1.2, kind: "bookmark", detail: "Bookmark"), CaptureEvent(time: 4.1, kind: "bookmark", detail: "After recovery end")]
    var captureMarks = baseline
    captureMarks.includeCaptureBookmarks(capture); captureMarks.includeCaptureBookmarks(capture)
    try require(captureMarks.resolvedBookmarks.count == 1 && captureMarks.resolvedBookmarks[0].time == EditTime(1.2), "Capture bookmarks import once and exclude unrecovered footage")
    let encoded = try JSONEncoder().encode(marks)
    let restored = try JSONDecoder().decode(TrackTimeline.self, from: encoded)
    try require(restored == marks, "Independent positions, links and bookmarks round-trip exactly")
    for rate in [24.0, 25, 30, 50, 60, 24000.0/1001, 30000.0/1001, 60000.0/1001] {
        let frame = EditTime(1 / rate)
        try require(abs(frame.seconds - 1 / rate) < 1e-10, "Canonical clock exactly represents standard frame durations")
    }
    var speed = a; speed.speed = SpeedSettings(rate: 1.5)
    let map = SourcePlaybackMap(speed)
    var retimedCut = TrackTimeline(sequence: EditState(clips: [speed, b]))
    let priorPosition = retimedCut.video[1].start + EditTime(0.5)
    let retimedPosition = retimedCut.remove(retimedCut.selection(of: a.id), preserving: priorPosition)
    try require(retimedPosition == EditTime(0.5), "Deletion rebases by playback duration rather than source seconds")
    try require(abs(map.source(at: EditTime(0.5))! - 0.75) < 0.00001, "Source mapping preserves speed independently of placement")
    var three = TrackTimeline(clips: [a, b, TimelineClip(sourceID: source.id, start: 0, end: 2)])
    var threeEdit = EditState(timeline: three)
    threeEdit = threeEdit.settingTransition(ClipTransition(duration: 0.5), at: 1)
    threeEdit = threeEdit.settingTransition(ClipTransition(duration: 0.5), at: 2)
    three = threeEdit.timeline
    let middleID = three.video[1].id
    let lastID = three.video[2].id, priorLast = three.video[2].start
    let afterOverlap = three.remove(three.selection(of: middleID), preserving: priorLast + EditTime(1))
    try require(afterOverlap == three.video.first(where: { $0.id == lastID })!.start + EditTime(1), "Transition handles do not cause playhead drift after deletion")
    try require(three.video[1].start == three.video[0].end && three.duration == EditTime(4), "Deleting a linked clip between two transitions closes only the newly vacated gap")
    var tickState: UInt64 = 21
    func random() -> Double { tickState = tickState &* 6364136223846793005 &+ 1; return Double(tickState >> 11) / Double(1 << 53) }
    for _ in 0..<2000 {
        var clip = TimelineClip(sourceID: source.id, start: 0, end: 4)
        clip.speed = SpeedSettings(rate: 0.25 + random() * 3.75)
        clip.pauses = PauseSettings(cuts: [SourceInterval(start: 0.5 + random() * 0.3, end: 1.2 + random() * 0.3)])
        var graph = TrackTimeline(clips: [clip])
        let end = graph.duration
        let at = EditTime(ticks: max(1, Int64(Double(end.ticks) * (0.1 + random() * 0.8))))
        graph.split(at: at, selection: graph.entireSelection())
        try require(graph.video[0].end == at && graph.video[1].start == at && graph.video[1].end == end, "Video split conserves exact ticks through speed and pauses")
        try require(graph.audio[0].end == at && graph.audio[1].end == end, "Audio and picture split stay sample-aligned")
        let selected = graph.scoped(graph.entireSelection(range: EditInterval(at, end)))
        try require(selected.selection.video.count == 1 && selected.selection.audio.count == 1, "Scope never selects only one linked component because of rounding")
    }
    for style in TransitionStyle.allCases {
        for hold in [0.0, 1.5] {
            for offset in [-0.7, 0, 0.7] {
                var clips = [a, b]
                clips[0].openingTransition = ClipTransition(style: style, duration: 0.7, hold: hold, audioOffset: offset, audioBlend: 1)
                clips[0].transition = ClipTransition(nextClipID: b.id, style: style, duration: 1.2, hold: hold, audioOffset: offset, audioBlend: 1)
                clips[1].transition = ClipTransition(style: style, duration: 0.7, hold: hold, audioOffset: offset, audioBlend: 1)
                let oracle = LegacyTimelineLayout(clips: clips)
                let converted = TrackTimeline(clips: clips)
                try require(abs(converted.duration.seconds - oracle.duration) <= 4.0 / 240000, "Transition conversion preserves full duration: \(style)")
                for (actual, expected) in zip(converted.video, oracle.placements) {
                    try require(abs(actual.start.seconds - expected.start) <= 4.0 / 240000, "Transition conversion preserves source placement")
                }
                let compiled = converted.compile()
                try require(compiled.first?.interval.start == .zero && compiled.last?.interval.end == converted.duration, "Compiler covers transition holds and tails")
                for pair in zip(compiled, compiled.dropFirst()) { try require(pair.0.interval.end == pair.1.interval.start, "Compiler has no instruction gaps") }
            }
        }
    }
    var reveal = TrackTimeline(clips: [TimelineClip(sourceID: source.id, start: 1, end: 3)])
    let revealID = reveal.video[0].id
    reveal.move(reveal.entireSelection(), by: EditTime(2))
    reveal.extend(reveal.selection(of: revealID), left: true, by: EditTime(1), sources: [source])
    try require(reveal.video[0].start == EditTime(1) && reveal.video[0].content.start == 0 && reveal.audio[0].mapping == reveal.video[0].mapping, "Outward trim restores source samples and linked sound")
    reveal.unlink(reveal.selection(of: revealID)); let detachedID = reveal.audio[0].id
    reveal.move(TimelineSelection(audio: [detachedID]), by: EditTime(0.5))
    reveal.restoreSync(audio: detachedID)
    try require(reveal.audio[0].start == reveal.video[0].start && reveal.links.isEmpty, "Restore sync is explicit and does not silently relink")
    reveal.closeGap(at: EditTime(0.5))
    try require(reveal.video[0].start == .zero && reveal.audio[0].start == .zero, "Close gap removes only time empty on every lane")
    print("PASS: independent AV timing, unlink, component gaps, linked ripple, overlaps, range splits, bookmarks, enhancement intervals, persistence and edit clock")
}


private func placementCropTests() throws {
    var value = VideoPlacement()
    value.x = 0.6; value.y = 0.4; value.width = 0.8; value.height = 0.6
    value.framing = TransitionFraming(x: 0.2, y: 0.7, zoom: 2); value.fill = true; value.order = 3
    let original = value, canvas = CGSize(width: 1920, height: 1080)
    let full = value.window(in: CGSize(width: 1, height: 1))
    value.crop(.left, to: full.minX + full.width * 0.2)
    value.crop(.right, to: full.maxX - full.width * 0.1)
    value.crop(.top, to: full.minY + full.height * 0.15)
    value.crop(.bottom, to: full.maxY - full.height * 0.25)
    let visible = value.visibleWindow(in: canvas)
    try require(abs(visible.width - original.width * canvas.width * 0.7) < 0.00001 && abs(visible.height - original.height * canvas.height * 0.6) < 0.00001,
                "Each Placement edge crops only its own margin")
    var stripped = value; stripped.edgeCrop = nil
    try require(stripped == original, "Edge cropping never changes picture scale, position, Fit/Fill, framing or order")
    var fit = original; fit.fill = false
    let fitted = fit.pictureWindow(in: canvas)
    try require(abs(fitted.width / fitted.height - canvas.width / canvas.height) < 0.00001, "Fit crop handles follow the actual picture aspect")
    fit.crop(.left, to: (fitted.minX + fitted.width * 0.2) / canvas.width, canvas: canvas)
    try require(abs(fit.visibleWindow(in: canvas).minX - (fitted.minX + fitted.width * 0.2)) < 0.00001, "Fit crop starts at the picture, without dead margins")
    var small = original
    small.crop(.left, to: 10, canvas: CGSize(width: 300, height: 168.75), minimumPoints: 44)
    try require(abs(small.visibleWindow(in: CGSize(width: 300, height: 168.75)).width - 44) < 0.00001, "Touch crop leaves a movable visible window")
    var narrow = original; narrow.fill = false; narrow.edgeCrop = PlacementEdgeCrop(top: 0.4, bottom: 0.35)
    let touchCanvas = CGSize(width: 300, height: 168.75), narrowBefore = narrow
    let top = narrow.visibleWindow(in: touchCanvas).minY / touchCanvas.height
    narrow.crop(.top, to: top + 0.01, canvas: touchCanvas, minimumPoints: 44)
    try require(narrow == narrowBefore, "Touching an already-small crop after Fit/rotation neither grows it nor shrinks it further")
    for fill in [false, true] { for zoom in [1.0, 2, 5] {
        var framed = original; framed.fill = fill; framed.framing = TransitionFraming(x: 0.5, y: 0.5, zoom: zoom)
        let window = framed.window(in: touchCanvas)
        let before = framed.framing.crop(source: touchCanvas, viewport: fill ? window.size : touchCanvas)
        let scale = fill ? max(window.width / before.width, window.height / before.height) : min(window.width / before.width, window.height / before.height)
        framed.reframe(by: CGSize(width: 4, height: -3), canvas: touchCanvas)
        let after = framed.framing.crop(source: touchCanvas, viewport: fill ? window.size : touchCanvas)
        let expectedX = min(4, before.minX * scale), expectedY = min(3, (touchCanvas.height - before.maxY) * scale)
        try require(abs((before.midX - after.midX) * scale - expectedX) < 0.00001 && abs((after.midY - before.midY) * scale - expectedY) < 0.00001,
                    "Reframe follows the exact finger distance in both Fit and Fill at every zoom")
        framed.reframe(by: CGSize(width: 10000, height: 10000), canvas: touchCanvas)
        framed.reframe(by: CGSize(width: -2, height: -2), canvas: touchCanvas)
        let reversed = framed.framing.crop(source: touchCanvas, viewport: fill ? window.size : touchCanvas)
        try require(abs(reversed.minX * scale - min(2, (touchCanvas.width - reversed.width) * scale)) < 0.00001,
                    "Reversing at an image edge responds immediately without a hidden pan dead zone")
    } }
    for count in 2...24 { for index in 1..<count {
        let pip = VideoPlacement.layout(3, index: index, count: count).visibleWindow(in: canvas)
        try require(CGRect(origin: .zero, size: canvas).contains(pip), "Picture-in-picture keeps every preset window on canvas, including larger stacks")
    } }
    let serialized = try JSONEncoder().encode(value)
    let decoded = try JSONDecoder().decode(VideoPlacement.self, from: serialized)
    try require(decoded == value, "Placement crop margins round-trip exactly")
    let old = try JSONEncoder().encode(original)
    let existing = try JSONDecoder().decode(VideoPlacement.self, from: old)
    try require(existing.edgeCrop == nil, "Existing placements open uncropped")
    var clamped = value
    for edge in PlacementCropEdge.allCases {
        clamped.crop(edge, to: edge == .left || edge == .top ? 10 : -10)
        try require(clamped.edgeCrop!.valid, "Opposite edge handles cannot cross or produce an empty crop")
    }
    for edge in PlacementCropEdge.allCases { clamped.crop(edge, to: edge == .left || edge == .top ? -10 : 10) }
    try require(clamped == original, "Dragging every edge out restores the complete original window")
    var moved = value; moved.x += 0.1; moved.y -= 0.1; moved.width *= 1.5; moved.height *= 1.5
    try require(moved.edgeCrop == value.edgeCrop && moved.framing == value.framing, "Pan and resize retain the crop margins and content framing")
    var project = Project(title: "Placement crop Undo")
    let source = SourceMedia(filename: "source.mp4", duration: 8); project.append(source)
    var state = project.edit, other = state.timeline.video[0]
    other.content.id = UUID(); other.occurrenceID = UUID(); state.timeline.video.append(other)
    let ids = Set(state.timeline.video.map(\.id))
    state.timeline.placements = [VideoPlacementRegion(participants: ids, videos: [state.timeline.video[0].id: original, other.id: original])]
    let canonical = state.timeline.video.sorted(by: TrackTimeline.backToFront).map(\.id)
    try require(VideoPlacement.ordered(canonical, settings: state.timeline.placements[0].videos) == canonical,
                "Equal placement depths retain the timeline's stable picture order")
    var divided = state.timeline; divided.unlink(divided.entireSelection())
    divided.split(at: EditTime(3), selection: TimelineSelection(audio: Set(divided.audio.map(\.id))))
    try require(divided.placementPreviewInterval(participants: ids, near: 9, preferred: 1...2) == EditInterval(0...8),
                "Arrange preview merges audio subdivisions and finds the overlap even from an outside playhead")
    var movedPlacement = state.timeline
    let baseID = movedPlacement.video[0].id, overlayID = movedPlacement.video[1].id
    movedPlacement.unlink(movedPlacement.entireSelection())
    movedPlacement.video[1].mapping = SourcePlaybackMap(TimelineClip(sourceID: source.id, start: 0, end: 2))
    movedPlacement.video[1].content.end = 2; movedPlacement.video[1].start = EditTime(1)
    movedPlacement.split(at: EditTime(4), selection: TimelineSelection(video: [baseID]))
    let beforePlacedMove = movedPlacement
    movedPlacement.move(TimelineSelection(video: [overlayID]), by: EditTime(4))
    let movedPlan = movedPlacement.compile().first { $0.interval.contains(EditTime(5.5)) }!
    let movedRegion = movedPlacement.placements.first { $0.id == movedPlan.placementID }
    var expectedPlacement = original; expectedPlacement.order = movedRegion?.videos[overlayID]?.order ?? -1
    try require(movedRegion?.videos[overlayID] == expectedPlacement,
                "Moving a placed overlay across a split preserves its window instead of turning it into full-frame Cover")
    var extendedPlacement = beforePlacedMove
    extendedPlacement.extend(TimelineSelection(video: [overlayID]), left: false, by: EditTime(3), sources: [source])
    let extendedPlan = extendedPlacement.compile().first { $0.interval.contains(EditTime(5)) }!
    try require(extendedPlacement.placements.first { $0.id == extendedPlan.placementID }?.videos[overlayID]?.width == original.width,
                "Trim extension into another base clip preserves the overlay's geometry")
    var slowPlacement = beforePlacedMove
    var slowClips = slowPlacement.projectedClips
    slowClips[slowClips.firstIndex { $0.id == overlayID }!].speed = SpeedSettings(rate: 0.5)
    slowPlacement.replaceVideoContents(slowClips)
    let slowPlan = slowPlacement.compile().first { $0.interval.contains(EditTime(4.5)) }!
    try require(slowPlacement.placements.first { $0.id == slowPlan.placementID }?.videos[overlayID]?.width == original.width,
                "Slowing an overlay into another base clip preserves its geometry")
    var thirdLayer = state.timeline, third = thirdLayer.video[0]
    third.content.id = UUID(); third.occurrenceID = UUID(); third.start = EditTime(8); thirdLayer.video.append(third)
    thirdLayer.move(TimelineSelection(video: [third.id]), by: EditTime(-6))
    let three = thirdLayer.compile().first { $0.video.count == 3 }!
    let inherited = thirdLayer.placements.first { $0.id == three.placementID }!
    try require(inherited.videos[baseID]?.width == original.width && inherited.videos[overlayID]?.framing == original.framing,
                "Adding a third overlapping picture keeps the existing arrangement")
    try require(VideoPlacement.ordered(three.video, settings: inherited.videos).last == third.id,
                "New overlay remains in front while inherited windows retain their relative order")
    var remote = TrackTimeline(clips: [TimelineClip(sourceID: source.id, start: 0, end: 8)])
    var short = remote.video[0]; short.content.id = UUID(); short.occurrenceID = UUID(); short.content.end = 1; short.mapping = SourcePlaybackMap(short.content); short.start = EditTime(1)
    var remoteBase = remote.video[0]; remoteBase.content.id = UUID(); remoteBase.occurrenceID = UUID(); remoteBase.start = EditTime(10)
    var pip = short; pip.content.id = UUID(); pip.occurrenceID = UUID(); pip.start = EditTime(11); pip.layer = 2
    remote.video += [short, remoteBase, pip]
    let aID = remote.video[0].id
    remote.placements = [VideoPlacementRegion(participants: [aID, short.id], videos: [aID: VideoPlacement.layout(1, index: 0, count: 2), short.id: VideoPlacement.layout(1, index: 1, count: 2)]),
                         VideoPlacementRegion(participants: [remoteBase.id, pip.id], videos: [remoteBase.id: VideoPlacement(), pip.id: VideoPlacement.layout(3, index: 1, count: 2)])]
    remote.move(TimelineSelection(video: [pip.id]), by: EditTime(-6))
    let remotePlan = remote.compile().first { $0.interval.contains(EditTime(5.5)) }!
    let remoteValues = remote.placements.first { $0.id == remotePlan.placementID }!.videos
    try require(remoteValues[aID]?.width == 1 && remoteValues[pip.id]?.width == 0.32,
                "A moved PiP retains its size without borrowing unrelated distant geometry for the stationary background")
    project.commit(state)
    state.timeline.placements[0].videos[other.id] = value; project.commit(state); try project.validate()
    try require(project.schemaVersion == 7, "Older builds cannot silently drop placement crops")
    project.undo()
    try require(project.edit.timeline.placements[0].videos[other.id]?.edgeCrop == nil, "Undo restores crop without changing the overlapping pictures")
    project = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project)); project.redo()
    try require(project.edit == state, "Placement crop survives saved Redo and reopening")
    state.timeline.placements[0].videos[other.id]?.edgeCrop = PlacementEdgeCrop(left: 0.8, right: 0.7)
    do { try state.timeline.validate(sources: [source]); throw NSError(domain: "PlacementCropQA", code: 1) } catch ProjectError.invalidDocument {}
    print("PASS: Placement edge crop geometry, fixed framing, limits, persistence and Undo/Redo")
}


private func moveCompanionTests() throws {
    let source = SourceMedia(filename: "companions.mov", duration: 18)
    let clips = (0..<5).map { i in TimelineClip(sourceID: source.id, start: Double(3 * i), end: Double(3 * i + 3)) }
    var timeline = TrackTimeline(clips: clips)
    let seed = timeline.selection(of: clips[1].id)
    let later = timeline.selection(ids: Set(clips.suffix(2).map(\.id)))
    timeline.move(later, by: EditTime(ticks: 1))
    let overlay = TimelineClip(sourceID: source.id, start: 0, end: 10)
    timeline.video.append(VideoTimelineItem(occurrenceID: UUID(), start: EditTime(2), content: overlay, layer: 12))
    let music = SourceMedia(filename: "score.m4a", duration: 16, audioOnly: true)
    timeline.insertAudio(music, at: .zero)

    let choices = timeline.moveChoices(for: seed)
    func pictures(_ indices: Int...) -> TimelineSelection { timeline.selection(ids: Set(indices.map { clips[$0].id })) }
    try require(choices.selected == seed && choices.left == pictures(0, 1) && choices.right == pictures(1, 2)
                && choices.both == pictures(0, 1, 2), "Move includes the chosen sides with linked sound and stops at a one-tick gap, even under an overlay and score")
    let multiple = timeline.moveChoices(for: pictures(0, 4))
    try require(multiple.left == pictures(0, 3, 4) && multiple.right == pictures(0, 1, 2, 4), "Each selected island has its own left and right neighbors")
    var moved = timeline
    moved.move(choices.right, by: EditTime(0.75))
    for picture in timeline.video {
        let delta = choices.right.video.contains(picture.id) ? EditTime(0.75) : .zero
        try require(moved.video.first { $0.id == picture.id }?.start == picture.start + delta, "Move preserves relative picture offsets")
    }
    for sound in timeline.audio {
        let delta = choices.right.audio.contains(sound.id) ? EditTime(0.75) : .zero
        try require(moved.audio.first { $0.id == sound.id }?.start == sound.start + delta, "Linked audio moves with its picture, independent music stays")
    }
    var detached = TrackTimeline(clips: clips)
    detached.unlink(detached.entireSelection())
    let audio = detached.moveChoices(for: detached.selection(of: detached.audio[2].id))
    try require(audio.both.video.isEmpty && audio.both.audio == Set(detached.audio.map(\.id)), "Independent sound can move with adjacent sound without selecting pictures")
    let picture = detached.moveChoices(for: detached.selection(of: clips[2].id))
    try require(picture.both.audio.isEmpty && picture.both.video.count == 5, "Unlinked pictures do not recruit sound at coincident cuts")
    var stacked = detached
    stacked.video.append(VideoTimelineItem(occurrenceID: UUID(), start: EditTime(1), content: overlay, layer: 12))
    stacked.split(at: EditTime(6), selection: stacked.entireSelection())
    let overlayIDs = Set(stacked.video.filter { $0.layer == 12 }.map(\.id))
    let overlayChoices = stacked.moveChoices(for: stacked.selection(of: overlay.id))
    try require(overlayChoices.right.video == overlayIDs && overlayIDs.count == 2, "An overlay cut exactly at a main edit follows its own continuation only")
    try require(stacked.moveChoices(for: stacked.selection(of: clips[2].id)).both.video == picture.both.video, "The main edit stays on its own layer at a stacked cut")
    let end = detached.moveChoices(for: detached.selection(of: clips.last!.id))
    try require(end.available(.left) && !end.available(.right) && !end.available(.both), "A direction with no additional neighbors is unavailable")

    var joinedClips = Array(clips.prefix(3))
    joinedClips[0].transition = ClipTransition(nextClipID: clips[1].id, style: .dissolve, duration: 1)
    var joined = TrackTimeline(clips: joinedClips)
    let relation = joined.transitions[0]
    let fromLast = joined.moveChoices(for: joined.selection(of: clips[2].id)).left
    try require(fromLast == joined.entireSelection(), "Walk through cuts and an overlapping transition transitively")
    joined.move(fromLast, by: EditTime(2))
    try require(joined.transitions.first?.origin == relation.origin + EditTime(2), "A transition follows its moving pair")
    let scoped = detached.scoped(TimelineSelection(video: [clips[1].id], range: EditInterval(4...5)))
    let range = scoped.timeline.moveChoices(for: scoped.selection)
    try require(range.selected.video.count == 1 && range.left.video.count == 3 && range.right.video.count == 5, "Marked ranges recruit outward from their scoped boundaries")
}

private func multiSelectionTests() throws {
    let source = SourceMedia(filename: "multi.mp4", duration: 12)
    let clips = (0..<3).map { TimelineClip(sourceID: source.id, start: Double($0 * 4), end: Double(($0 + 1) * 4)) }
    let original = TrackTimeline(clips: clips)
    let all = original.entireSelection()
    var chosen = original.selection(of: clips[0].id).ids
    chosen = original.toggling(clips[1].id, in: chosen)
    try require(chosen.count == 4, "Long press adds another linked pair")
    chosen = original.toggling(original.audio[0].id, in: chosen)
    try require(chosen == original.selection(of: clips[1].id).ids, "Long press removes the whole selected link, keeping other selections")
    let together = try original.joining(all)
    try require(together.timeline.links.count == 1 && together.timeline.links[0].members == all.ids, "Join horizontal chains before vertical linking")
    try require(together.timeline.video == original.video && together.timeline.audio == original.audio, "Join preserves every sample map, source identity, setting and follower")
    try together.timeline.validate(sources: [source])
    let encoded = try JSONEncoder().encode(together.timeline)
    let decoded = try JSONDecoder().decode(TrackTimeline.self, from: encoded)
    try require(decoded == together.timeline, "Multi-part link persists exactly")
    var project = Project(title: "Link history")
    project.sources = [source]; project.history = [EditState(timeline: original)]; project.historyCursor = 0
    project.commit(EditState(timeline: together.timeline)); project.undo()
    try require(project.edit.timeline == original, "One undo restores all original groups")
    project.redo(); try require(project.edit.timeline == together.timeline, "Redo restores the compound link")
    var detached = original; detached.unlink(all)
    let videos = TimelineSelection(video: all.video), audios = TimelineSelection(audio: all.audio)
    let v = try detached.joining(videos), a = try detached.joining(audios)
    try require(v.timeline.selection(of: clips[1].id).ids == all.video, "Video-only horizontal glue selects every joined section")
    try require(a.timeline.selection(of: detached.audio[1].id).ids == all.audio, "Audio-only horizontal glue selects every joined section")
    var removeV = v.timeline; removeV.remove(v.selection)
    try require(removeV.video.isEmpty && removeV.audio == detached.audio && removeV.duration == EditTime(12), "Removing a horizontal video group leaves detached sound and time intact")
    var removeA = a.timeline; removeA.remove(a.selection)
    try require(removeA.audio.isEmpty && removeA.video == detached.video, "Removing a horizontal audio group leaves picture intact")
    var bulk = original
    let firstLast = original.selection(ids: [clips[0].id, clips[2].id])
    bulk.remove(firstLast)
    try require(bulk.video.count == 1 && bulk.audio.count == 1 && bulk.duration == EditTime(4) && bulk.video[0].start == .zero, "Bulk linked deletion closes both vacated ranges exactly once")
    var horizontalBed = original
    horizontalBed.unlink(horizontalBed.entireSelection())
    horizontalBed = try horizontalBed.joining(audios).timeline
    // Re-link only the first original pair; downstream audio remains a separate group.
    let pair = TimelineSelection(video: [clips[0].id], audio: [original.audio[0].id])
    // An already glued sequence expands on selection; use a fresh independent bed instead.
    horizontalBed = original
    horizontalBed.unlink(horizontalBed.selection(of: clips[1].id)); horizontalBed.unlink(horizontalBed.selection(of: clips[2].id))
    horizontalBed = try horizontalBed.joining(TimelineSelection(audio: Set(horizontalBed.audio.dropFirst().map(\.id)))).timeline
    let bed = Array(horizontalBed.audio.dropFirst())
    horizontalBed.remove(pair)
    try require(Array(horizontalBed.audio) == bed, "AV ripple never shifts a detached horizontal audio group")
    let horizontal = try detached.joining(videos).timeline
    var unrelatedSplit = horizontal
    unrelatedSplit.split(at: EditTime(6), selection: TimelineSelection(audio: [unrelatedSplit.audio[1].id]))
    try require(unrelatedSplit.links == horizontal.links, "Splitting unrelated audio preserves a horizontal video group")
    var splitGroup = together.timeline
    splitGroup.split(at: EditTime(6), selection: together.selection)
    try require(splitGroup.links.count == 2 && splitGroup.links.allSatisfy { $0.members.count == 4 }, "Splitting a joined sequence separates the two sides, with AV sync preserved")
    try splitGroup.validate(sources: [source])
    func rejected(_ timeline: TrackTimeline, _ scope: TimelineSelection, _ expected: TimelineLinkError) throws {
        do { _ = try timeline.linkPlan(scope); try require(false, "Invalid Link unexpectedly accepted") }
        catch let error as TimelineLinkError { try require(error.errorDescription == expected.errorDescription, "Link reports the correct selection problem") }
    }
    try rejected(detached, TimelineSelection(), .tooFew)
    try rejected(detached, TimelineSelection(video: [clips[0].id]), .tooFew)
    try rejected(detached, TimelineSelection(video: [clips[0].id, clips[2].id]), .nonContiguous)
    var overlap = detached
    overlap.move(TimelineSelection(video: [clips[1].id]), by: EditTime(-1))
    try rejected(overlap, videos, .nonContiguous)
    try rejected(detached, TimelineSelection(video: [clips[0].id], audio: [detached.audio[2].id]), .noIntersection)
    // Different internal split points, identical coverage: no unnecessary prompt.
    var partitioned = TrackTimeline(clips: [TimelineClip(sourceID: source.id, start: 0, end: 12)])
    partitioned.unlink(partitioned.entireSelection())
    partitioned.split(at: EditTime(4), selection: TimelineSelection(video: [partitioned.video[0].id]))
    partitioned.split(at: EditTime(8), selection: TimelineSelection(video: Set(partitioned.video.map(\.id))))
    let plan = try partitioned.linkPlan(partitioned.entireSelection())
    try require(!plan.needsIntersection, "Horizontal aggregation makes 3 video sections match one equal-length audio section")
    let joinedPartition = try partitioned.joining(plan.selection)
    try require(joinedPartition.timeline.links[0].members.count == 4, "One link can glue differently partitioned AV")
    // Same length is not enough: a shifted audio range requires confirmation.
    var mismatch = TrackTimeline(clips: [TimelineClip(sourceID: source.id, start: 0, end: 8)])
    mismatch.unlink(mismatch.entireSelection())
    mismatch.move(TimelineSelection(audio: [mismatch.audio[0].id]), by: EditTime(2))
    let before = mismatch
    let mismatchPlan = try mismatch.linkPlan(mismatch.entireSelection())
    try require(mismatchPlan.needsIntersection && mismatchPlan.intersection == EditInterval(2...8), "Shifted AV proposes only their shared time")
    try rejected(mismatch, TimelineSelection(video: []), .tooFew)
    do { _ = try mismatch.joining(mismatch.entireSelection()); try require(false, "Intersection linked without confirmation") }
    catch let error as TimelineLinkError { try require(error.errorDescription == TimelineLinkError.confirmationRequired.errorDescription, "Intersection is explicitly opt-in") }
    try require(mismatch == before, "Planning/cancelling leaves the original edit byte-for-byte unchanged")
    let clipped = try mismatch.joining(mismatch.entireSelection(), intersectionOnly: true)
    try clipped.timeline.validate(sources: [source])
    try require(clipped.timeline.duration == before.duration && clipped.timeline.video.count == 2 && clipped.timeline.audio.count == 2, "Intersection keeps both outside tails and the full timeline")
    try require(clipped.timeline.interval(for: clipped.selection) == EditInterval(2...8) && clipped.selection.ids.count == 2, "Only the shared pieces are linked and selected")
    try require(clipped.timeline.video.map { $0.mapping.duration.ticks }.reduce(0,+) == before.video[0].mapping.duration.ticks
        && clipped.timeline.audio.map { $0.mapping.duration.ticks }.reduce(0,+) == before.audio[0].mapping.duration.ticks, "Intersection conserves every video/audio tick")
    var moveShared = clipped.timeline
    moveShared.move(clipped.selection, by: EditTime(1))
    try require(moveShared.video[0] == clipped.timeline.video[0] && moveShared.audio[1] == clipped.timeline.audio[1], "Moving the new link leaves outside tails stationary")
    // Multi-part mismatch: horizontal validation happens before vertical clipping.
    var many = detached
    many.move(audios, by: EditTime(2))
    let manyJoin = try many.joining(many.entireSelection(), intersectionOnly: true)
    try manyJoin.timeline.validate(sources: [source])
    try require(manyJoin.timeline.interval(for: manyJoin.selection) == EditInterval(2...12), "N-part video/audio chains link the complete shared span")
    var retimedVideo = horizontal
    var retimedClips = retimedVideo.projectedClips
    retimedClips[0].speed = SpeedSettings(rate: 0.5)
    retimedVideo.replaceVideoContents(retimedClips)
    try require(retimedVideo.video[1].start == EditTime(8) && retimedVideo.video[2].start == EditTime(12)
        && retimedVideo.audio == horizontal.audio, "Retiming a horizontal video group keeps its joins contiguous without moving detached sound")
    // Snap on exact edit ticks, at both scales, with hysteresis and interior edges.
    let moving = TimelineSelection(video: [clips[0].id])
    let snap = detached.snappedMove(moving, by: EditTime(3.9), scale: 60)
    try require(snap.delta == EditTime(4) && snap.snap != nil, "Move snaps a leading edge exactly to a neighboring boundary")
    let held = detached.snappedMove(moving, by: EditTime(4.25), scale: 60, latch: snap.snap)
    try require(held.delta == EditTime(4), "Snap holds through small finger movement")
    let released = detached.snappedMove(moving, by: EditTime(4.4), scale: 60, latch: held.snap)
    try require(released.snap == nil && released.delta == EditTime(4.4), "Snap releases beyond its sticky threshold")
    let trailing = detached.snappedMove(TimelineSelection(video: [clips[2].id]), by: EditTime(-3.9), scale: 60)
    try require(trailing.delta == EditTime(-4), "Move also snaps a trailing edge when approaching from the other side")
    let zoomed = detached.snappedMove(moving, by: EditTime(3.9), scale: 720)
    try require(zoomed.snap == nil, "Snap tolerance is measured in displayed points, not a fixed time window")
    let clamp = detached.snappedMove(moving, by: EditTime(-100), scale: 60)
    try require(clamp.delta == .zero, "Snapping cannot move any selected part before the start")
    let selfOnly = original.snappedMove(all, by: EditTime(0.5), scale: 60)
    try require(selfOnly.snap == nil && selfOnly.delta == EditTime(0.5), "Moving all linked parts excludes their own edges")
    var withTransition = EditState(clips: Array(clips.prefix(2)))
    withTransition = withTransition.settingTransition(ClipTransition(duration: 1), at: 1)
    let transitioned = try withTransition.timeline.joining(withTransition.timeline.entireSelection())
    try require(transitioned.timeline.transitions == withTransition.timeline.transitions && transitioned.timeline.video == withTransition.timeline.video, "Sequential parts joined by an explicit transition can be glued without losing its handles")
    try transitioned.timeline.validate(sources: [source])
    var transitionIntersection = withTransition.timeline
    transitionIntersection.unlink(transitionIntersection.entireSelection())
    // A detached sound ending inside the crossfade must not make Link split
    // its two overlapping participants and silently discard the transition.
    transitionIntersection.audio = [detached.audio[0]]
    transitionIntersection.audio[0].mapping = detached.audio[0].mapping.sliced(EditInterval(0...3.5))
    let unchangedTransition = transitionIntersection
    try rejected(transitionIntersection, transitionIntersection.entireSelection(), .transitionBoundary)
    try require(transitionIntersection == unchangedTransition, "Refused intersection preserves the complete transition and sources")
    var layers = detached
    layers.move(TimelineSelection(video: [clips[0].id]), by: EditTime(5))
    let topBefore = layers.video.sorted { $0.layer < $1.layer }.map(\.id)
    layers.move(layers.entireSelection(), by: EditTime(1))
    try require(layers.video.sorted { $0.layer < $1.layer }.map(\.id) == topBefore, "Moving a group preserves its internal foreground/background order")
    var dense = detached
    dense.addBookmark(at: EditTime(4.2))
    let targetA = dense.snappedMove(moving, by: EditTime(3.99), scale: 60)
    let targetB = dense.snappedMove(moving, by: EditTime(4.2), scale: 60, latch: targetA.snap)
    try require(targetB.delta == EditTime(4.2), "A sticky snap yields to a nearer cut or bookmark under the finger")
    print("PASS: additive selection, horizontal/vertical joins, intersection confirmation/tails, multi-delete, link persistence and magnetic Move")
}

/// Exercise arrangements, not just individual methods: Move is never an
/// overwrite edit, and every intersecting item must remain visible/hit-testable.
private func overlapInteractionTests() throws {
    let source = SourceMedia(filename: "source.mp4", duration: 12)
    let clips = (0..<3).map { TimelineClip(sourceID: source.id, start: Double($0 * 4), end: Double(($0 + 1) * 4)) }
    let original = TrackTimeline(clips: clips)
    func lanesAreDisjoint(_ timeline: TrackTimeline) throws {
        let lanes = timelineLanes(timeline)
        try require(Set(lanes.map(\.id)) == Set(timeline.video.map(\.id) + timeline.audio.map(\.id)), "Every item has a visible lane")
        for (index, lane) in lanes.enumerated() {
            for other in lanes.dropFirst(index + 1) where other.row == lane.row {
                try require(lane.interval.intersection(other.interval) == nil, "No two overlapping items may paint into the same lane")
            }
        }
        let lastVideo = lanes.filter { !$0.audio }.map(\.row).max() ?? -1
        try require(lanes.filter(\.audio).allSatisfy { $0.row > lastVideo }, "Audio lanes never paint over video")
        for part in timeline.compile() {
            let actual = Set(timeline.video.filter { $0.interval.contains(part.interval.start) }.map(\.id))
            try require(Set(part.video) == actual, "The compositor retains every overlapping source")
            let row = Dictionary(uniqueKeysWithValues: lanes.filter { !$0.audio }.map { ($0.id, $0.row) })
            try require(part.video.sorted { row[$0]! > row[$1]! } == part.video, "Visible upper/lower lane order agrees with the compositor in every overlap interval")
        }
        try timeline.validate(sources: [source])
    }
    func retainedFootage(_ timeline: TrackTimeline) throws {
        for id in clips.map(\.id) {
            let pictures = timeline.video.filter { $0.occurrenceID == id }.flatMap { $0.mapping.runs }
            let sounds = timeline.audio.filter { $0.occurrenceID == id }.flatMap { $0.mapping.runs }
            for runs in [pictures, sounds] {
                let ordered = runs.sorted { $0.sourceStart < $1.sourceStart }
                let index = clips.firstIndex { $0.id == id }!
                try require(ordered.first?.sourceStart == Double(index * 4) && ordered.last?.sourceEnd == Double((index + 1) * 4), "The first and last source frame survive compound edits")
                try require(abs(ordered.reduce(0.0) { $0 + $1.sourceEnd - $1.sourceStart } - 4) < 0.00001, "Move/split/link preserves every source sample exactly once")
                for (left, right) in zip(ordered, ordered.dropFirst()) {
                    try require(abs(left.sourceEnd - right.sourceStart) < 0.00001, "Source coverage has no missing or duplicated interior interval")
                }
            }
        }
    }
    var count = 0
    for detached in [false, true] {
        var base = original
        if detached { base.unlink(base.entireSelection()) }
        let selections = [base.selection(of: clips[0].id), base.selection(of: clips[1].id), base.selection(of: clips[2].id),
                          TimelineSelection(audio: [base.audio[1].id]),
                          base.selection(ids: [clips[0].id, clips[2].id]), base.entireSelection(),
                          base.selection(of: clips[1].id, range: EditInterval(5...7))]
        for selection in selections {
            let scoped = base.scoped(selection)
            let moveRows = Dictionary(uniqueKeysWithValues: timelineLanes(scoped.timeline, moving: scoped.selection).map { ($0.id, $0.row) })
            for offset in [-30.0, -8, -4, -2, -0.1, 0, 0.1, 2, 4, 6, 8, 12] {
                var moved = scoped.timeline
                let priorVideo = Dictionary(uniqueKeysWithValues: moved.video.map { ($0.id, $0) })
                let priorAudio = Dictionary(uniqueKeysWithValues: moved.audio.map { ($0.id, $0) })
                moved.move(scoped.selection, by: EditTime(offset))
                try require(Set(moved.video.map(\.id)) == Set(priorVideo.keys) && Set(moved.audio.map(\.id)) == Set(priorAudio.keys), "Move cannot consume or replace another item")
                for item in moved.video {
                    try require(item.mapping == priorVideo[item.id]?.mapping && item.content == priorVideo[item.id]?.content, "Move cannot trim or rewrite video")
                }
                for item in moved.audio { try require(item.mapping == priorAudio[item.id]?.mapping, "Move cannot trim audio") }
                try lanesAreDisjoint(moved); try retainedFootage(moved)
                let draftLanes = timelineLanes(moved, moving: scoped.selection)
                for lane in draftLanes {
                    try require(lane.row == moveRows[lane.id], "Move keeps every card's row fixed as edges cross")
                    try require(draftLanes.allSatisfy { $0.id == lane.id || $0.row != lane.row || $0.interval.intersection(lane.interval) == nil }, "Dedicated Move rows never hide another item")
                }
                var project = Project(title: "Overlap regression")
                project.sources = [source]; project.history = [EditState(timeline: base)]; project.historyCursor = 0
                project.commit(EditState(timeline: moved))
                let saved = try JSONEncoder().encode(project)
                var reopened = try JSONDecoder().decode(Project.self, from: saved)
                try require(reopened.edit.timeline == moved, "Overlap and item identities survive project reopening")
                if reopened.canUndo {
                    reopened.undo(); try require(reopened.edit.timeline == base, "Undo restores the exact prior arrangement")
                    reopened.redo(); try require(reopened.edit.timeline == moved, "Redo restores all overlapping tracks")
                }
                // Removing the moved item must reveal the covered item intact.
                var deleted = moved
                deleted.unlink(deleted.entireSelection())
                deleted.remove(scoped.selection)
                for item in deleted.video {
                    try require(item.content == priorVideo[item.id]?.content && item.mapping == priorVideo[item.id]?.mapping, "Deleting a moved overlay does not trim the video beneath it")
                }
                try lanesAreDisjoint(deleted)
                count += 1
            }
        }
    }
    // Deterministic mixed sequence with full history: overlaps, scoped splits,
    // unlinks, linked joins, and moves in both directions.
    var sequence = original
    sequence.move(sequence.selection(of: clips[1].id), by: EditTime(-2))
    try lanesAreDisjoint(sequence)
    sequence.split(at: EditTime(3), selection: sequence.selection(of: clips[1].id))
    let secondPieces = Set(sequence.video.filter { $0.occurrenceID == clips[1].id }.map(\.id))
    let joined = try sequence.joining(sequence.selection(ids: secondPieces))
    sequence = joined.timeline
    sequence.move(joined.selection, by: EditTime(1))
    try lanesAreDisjoint(sequence); try retainedFootage(sequence)
    sequence.unlink(sequence.entireSelection())
    for index in 0..<100 {
        let item = sequence.video[index % sequence.video.count]
        sequence.move(TimelineSelection(video: [item.id]), by: EditTime(index % 2 == 0 ? 0.37 : -0.23))
        try lanesAreDisjoint(sequence); try retainedFootage(sequence)
    }
    // A small timing adjustment of the lower picture must not change which
    // source covers it. Extending into a NEW overlap should come forward.
    var stacked = original
    stacked.move(stacked.selection(of: clips[1].id), by: EditTime(-2))
    let lower = clips[0].id, top = clips[1].id
    let priorOrder = stacked.video.sorted(by: TrackTimeline.backToFront).map(\.id)
    stacked.move(stacked.selection(of: lower), by: EditTime(1.0 / 30))
    try require(stacked.video.sorted(by: TrackTimeline.backToFront).map(\.id) == priorOrder,
                "Nudging a covered picture preserves foreground order")
    try require(stacked.compile().first { $0.video.contains(lower) && $0.video.contains(top) }?.video.last == top,
                "A sync nudge cannot replace the visible picture")
    var slowed = original
    slowed.unlink(slowed.entireSelection())
    var slowerClips = slowed.projectedClips
    slowerClips[0].speed = SpeedSettings(rate: 0.5)
    slowed.replaceVideoContents(slowerClips)
    try require(slowed.compile().first { $0.video.contains(clips[0].id) && $0.video.contains(clips[1].id) }?.video.last == clips[0].id,
                "Slowing detached picture reveals its extended footage instead of hiding it")
    try lanesAreDisjoint(slowed)
    var reveal = original
    reveal.split(at: EditTime(2), selection: reveal.selection(of: lower))
    let child = reveal.video.first { $0.start == EditTime(2) }!
    reveal.extend(reveal.selection(of: lower), left: false, by: EditTime(1), sources: [source])
    let overlap = reveal.compile().first { $0.video.contains(lower) && $0.video.contains(child.id) }
    try require(overlap?.video.last == lower, "Extending into a new overlap reveals the extended footage in front")
    let lanes = timelineLanes(reveal)
    try require(lanes.first { $0.id == lower }!.row < lanes.first { $0.id == child.id }!.row,
                "Trim overlap lane order agrees with the compositor")
    var transitions = EditState(clips: (0..<20).map { TimelineClip(sourceID: source.id, start: Double($0) * 0.6, end: Double($0 + 1) * 0.6) })
    for boundary in 1..<20 { transitions = transitions.settingTransition(ClipTransition(duration: 0.2), at: boundary) }
    let transitionLanes = timelineLanes(transitions.timeline)
    try require(Set(transitionLanes.filter { !$0.audio }.map(\.row)).count == 1 && Set(transitionLanes.filter(\.audio).map(\.row)).count == 1,
                "Twenty sequential crossfades remain one picture row and one linked sound row")
    for (index, lane) in transitionLanes.enumerated() {
        try require(transitionLanes.dropFirst(index + 1).allSatisfy { $0.row != lane.row || $0.interval.intersection(lane.interval) == nil },
                    "Transition partners have adjacent, independently selectable cards")
    }
    print("PASS: \(count) overlap arrangements, non-overwriting lanes, range moves, linked/detached audio, remove-to-reveal, saved Undo/Redo and 100 mixed moves")
}

private func transitionPresentationTests() throws {
    let source = SourceMedia(filename: "source.mp4", duration: 12)
    let clips = [TimelineClip(sourceID: source.id, start: 0, end: 4), TimelineClip(sourceID: source.id, start: 4, end: 8)]
    for style in TransitionStyle.allCases {
        for offset: Double? in [nil, -1, 0, 1] {
            let edit = EditState(clips: clips).settingTransition(ClipTransition(style: style, duration: 1, hold: 0.4, audioOffset: offset, audioBlend: offset == nil ? nil : 1.5), at: 1)
            let original = edit.timeline, lanes = timelineLanes(original)
            try require(Set(lanes.filter { !$0.audio }.map(\.row)).count == 1 && Set(lanes.filter(\.audio).map(\.row)).count == 1,
                        "Sequential \(style) with audio offset \(String(describing: offset)) remains compact")
            for lane in lanes {
                let content = lane.audio ? original.audio.first { $0.id == lane.id }!.interval : original.video.first { $0.id == lane.id }!.interval
                try require(lane.contentInterval == content && !lane.interval.isEmpty && lane.interval.start >= content.start && lane.interval.end <= content.end,
                            "Presentation keeps all source handles and a nonempty selectable card")
            }
            try require(edit.timeline == original, "Compact presentation cannot change saved edits, timing, or media")
            let transition = edit.layout.joins[1].transition!
            let removed = edit.removingTool(ToolRequest(tool: .transition, range: edit.layout.joins[1].range, scopeTitle: "Join", effectID: transition.id, boundaryIndex: 99))
            try require(removed.timeline.transitions.isEmpty && removed.duration == 8 && removed.timeline.video[0].end == removed.timeline.video[1].start,
                        "Removing \(style) by identity restores a straight cut, including custom audio timing")
            try require(removed.timeline.video.map(\.mapping) == original.video.map(\.mapping) && removed.timeline.audio.map(\.mapping) == original.audio.map(\.mapping),
                        "Transition removal never trims or loses source samples")
        }
    }
    let edit = EditState(clips: clips).settingTransition(ClipTransition(duration: 2), at: 1)
    try require(!edit.toolRegions.contains { $0.tool == .placement }, "A plain transition does not advertise a default Placement effect")
    let lanes = timelineLanes(edit.timeline), outgoing = lanes.first { $0.id == clips[0].id }!, incoming = lanes.first { $0.id == clips[1].id }!
    try require(outgoing.interval.end == EditTime(3) && incoming.interval.start == EditTime(3) && edit.duration == 6,
                "Two four-second clips with a two-second dissolve meet at 3 s in a six-second timeline")
    try require(incoming.mapping.source(at: EditTime(3.25) - incoming.contentInterval.start) == 5.25,
                "The incoming thumbnail/waveform starts at its correct source position, not the hidden transition handle")
    try require(outgoing.trimsLeft && !outgoing.trimsRight && !incoming.trimsLeft && incoming.trimsRight,
                "Internal transition handles cannot masquerade as ordinary trim edges")
    var detached = edit.timeline; detached.unlink(detached.selection(of: clips[0].id))
    try require(Set(timelineLanes(detached).filter(\.audio).map(\.row)).count == 2,
                "Independently editable overlapping sound keeps separate lanes")
    var overlay = edit.timeline
    let cover = TimelineClip(sourceID: source.id, start: 8, end: 10)
    overlay.video.append(VideoTimelineItem(occurrenceID: cover.id, start: EditTime(2), content: cover, layer: 99))
    var layeredEdit = edit; layeredEdit.timeline = overlay
    try require(layeredEdit.toolRegions.contains { $0.tool == .placement }, "An actual overlay retains its Placement control")
    let layers = timelineLanes(overlay)
    try require(layers.first { $0.id == cover.id }!.interval == EditInterval(2...4) && Set(layers.filter { !$0.audio }.map(\.row)).count == 2,
                "A deliberate overlay remains a complete separate card above the compact transition")
    let moving = timelineLanes(edit.timeline, moving: edit.timeline.selection(of: clips[0].id))
    try require(moving.allSatisfy { $0.interval == $0.contentInterval }, "Move exposes full source extents for accurate placement")
    var removed = edit.timeline; removed.transitions = []; removed.pruneRelations()
    try require(Set(timelineLanes(removed).filter { !$0.audio }.map(\.row)).count == 2,
                "Removing the transition reveals the actual overlap instead of concealing a layer")
    print("PASS: compact transition presentation, all styles/audio offsets, source clocks, linked/detached audio and real overlays")
}


func timelineNavigationTests() throws {
    let source = UUID()
    let original = TimelineClip(sourceID: source, start: 0, end: 18)
    var edit = EditState(clips: [original])
    var text = TextOverlay(text: "Title"); text.start = 8; text.end = 10
    edit.timeline.video[0].content.texts = [text]
    var voice = AudioEffect.make(.equalizer); voice.amount = 2
    edit.timeline.enhance([voice], selection: edit.timeline.entireSelection())
    edit.timeline.split(at: EditTime(6), selection: edit.timeline.entireSelection())
    edit.timeline.split(at: EditTime(12), selection: edit.timeline.entireSelection())
    let nav = TimelineNavigation(edit)
    try require(nav.cutsAndChanges == [0,6,8,10,12,18], "Tap includes cuts and title edges")
    try require(nav.changes == [0,8,10,18], "Long press skips splits of the same sound/image recipe")
    try require(nav.destination(from: 0, forward: true) == 6 && nav.destination(from: 0, forward: true, effectsOnly: true) == 8, "Separate tap/hold navigation")
    try require(nav.destination(from: 9, forward: false) == 8 && nav.destination(from: 8, forward: false) == 6, "Previous reaches current section start, then earlier section")
    try require(nav.destination(from: 7.999, forward: true) == 10, "Floating point seek noise does not repeat the same anchor")
    try require(nav.destination(from: 18, forward: true) == nil && nav.destination(from: 0, forward: false) == nil, "Endpoints never wrap")
    var captioned = edit
    let words = [SubtitleWord(text: "First.", start: 2, end: 3), SubtitleWord(text: "Second.", start: 7, end: 8), SubtitleWord(text: "Last.", start: 14, end: 16)]
    captioned.timeline.installSubtitles(words, range: 2...16, language: "English")
    let captionNav = TimelineNavigation(captioned)
    try require(captionNav.changes == [0,2,8,10,18] && captionNav.cutsAndChanges == [0,2,6,8,10,12,18], "Subtitles add only their first start, not sentence edges or speech gaps")
    captioned.timeline.regroupSubtitles(1)
    try require(TimelineNavigation(captioned).changes == captionNav.changes, "Caption regrouping does not clutter transport navigation")
    captioned.timeline.removeSubtitles()
    try require(TimelineNavigation(captioned).changes == nav.changes, "Removing subtitles removes their navigation start")
    var changed = edit
    changed.timeline.audio[1].enhancements[0].effects[0].amount = 4
    try require(TimelineNavigation(changed).changes == [0,6,8,10,12,18], "Same effect with different settings counts")
    changed = edit
    changed.timeline.audio[1].enhancements[0].effects[0].id = UUID()
    try require(TimelineNavigation(changed).changes == nav.changes, "New recipe identity alone isn't an effect change")
    var disabled = VideoEffectSettings(.noir, start: 2, end: 4); disabled.enabled = false
    changed.timeline.video[0].content.videoEffects = [disabled]
    try require(TimelineNavigation(changed).changes == nav.changes, "Disabled video effects make no stops")
    disabled.enabled = true; disabled.set("intensity", .number(0))
    changed.timeline.video[0].content.videoEffects = [disabled]
    try require(TimelineNavigation(changed).changes == nav.changes, "Zero intensity without animation is bypassed")
    changed.timeline.audio[0].enhancements[0].effects[0].enabled = false
    try require(TimelineNavigation(changed).changes.contains(6), "Disabled sound changes the actual active set")
    changed = edit
    changed.timeline.unlink(changed.timeline.entireSelection())
    changed.timeline.audio[1].volumeDB = -3
    changed.timeline.move(TimelineSelection(audio: [changed.timeline.audio[1].id]), by: EditTime(1))
    try require(TimelineNavigation(changed).changes.contains(7) && TimelineNavigation(changed).changes.contains(13), "Detached moved audio has project-clock stops")
    var rate = original; rate.speed = SpeedSettings(rate: 2); rate.texts = [text]
    let retimed = TimelineNavigation(EditState(clips: [rate]))
    try require(retimed.changes == [0,4,5,9], "Source-anchored title follows speed mapping")
    var removed = original; removed.texts = [text]
    removed.pauses = PauseSettings(cuts: [SourceInterval(start: 4, end: 6)])
    let pauseNav = TimelineNavigation(EditState(clips: [removed]))
    try require(pauseNav.changes == [0,6,8,16] && pauseNav.cutsAndChanges.contains(4), "Removed silence is a cut, not a recipe change")
    var overlay = edit
    overlay.timeline.unlink(overlay.timeline.entireSelection())
    overlay.timeline.move(TimelineSelection(video: [overlay.timeline.video[1].id]), by: EditTime(-2))
    let overlapNav = TimelineNavigation(overlay)
    try require(overlapNav.changes.contains(4) && overlapNav.changes.contains(6), "Overlap Placement begins and ends at its actual picture edges")
    var edge = text; edge.start = 8.001; edge.end = 10.001
    var frameAligned = original; frameAligned.texts = [edge]
    let rounded = TimelineNavigation(EditState(clips: [frameAligned]))
    try require(abs(rounded.changes[1] - 241.0/30) < 0.00001, "Sub-frame changes land on the first affected output frame")
    let clips = [TimelineClip(sourceID: source, start: 0, end: 8), TimelineClip(sourceID: source, start: 8, end: 18)]
    let transition = EditState(clips: clips).settingTransition(ClipTransition(duration: 2, audioOffset: -1, audioBlend: 3), at: 1)
    let transitionNav = TimelineNavigation(transition)
    let join = transition.layout.joins.first { $0.transition != nil }!
    func has(_ time: Double, in stops: [Double]) -> Bool { stops.contains { abs($0-time) <= 1.0/30 } }
    try require(has(join.videoRange.lowerBound, in: transitionNav.changes) && has(join.videoRange.upperBound, in: transitionNav.changes), "Transition video edges are navigable")
    try require(has(join.audioIn.lowerBound, in: transitionNav.changes) && has(join.audioIn.upperBound, in: transitionNav.changes), "J/L audio edges are navigable independently")
    try require(has(join.time, in: transitionNav.cutsAndChanges), "Tap also reaches the visible transition join")
    let opening = EditState(clips: [original]).settingTransition(ClipTransition(duration: 2, audioOffset: 3, audioBlend: 2), at: 0)
    let openingNav = TimelineNavigation(opening)
    let openingJoin = opening.layout.joins.first { $0.transition != nil }!
    try require(has(openingJoin.audioIn.lowerBound, in: openingNav.changes), "Opening fade ignores the absent outgoing track when sound starts later")
    try require(TimelineNavigation(edit).changes == nav.changes, "Deriving navigation never mutates edit state; Undo's previous snapshot has its original stops")
    print("Timeline change navigation passed")
}


private func reviewRegressionTests() throws {
    let source = SourceMedia(filename: "source.mp4", duration: 20)
    let clips = (0..<3).map { TimelineClip(sourceID: source.id, start: Double($0 * 4), end: Double(($0 + 1) * 4)) }
    var overlapped = TrackTimeline(clips: clips)
    overlapped.move(overlapped.selection(of: clips[1].id), by: EditTime(-3))
    var fast = EditState(timeline: overlapped)
    fast.clips[0].speed = SpeedSettings(rate: 4)
    try fast.timeline.validate(sources: [source])
    try require(fast.timeline.video.first { $0.id == clips[1].id }!.start == EditTime(1), "Speed preserves an independent concurrent layer's position")
    try require(fast.timeline.video.first { $0.id == clips[2].id }!.start == EditTime(5), "Speed still ripples sequential linked content")

    let original = TrackTimeline(clips: clips)
    let pair = TimelineSelection(video: [clips[0].id, clips[1].id], audio: [TrackTimeline.counterpart(clips[0].id), TrackTimeline.counterpart(clips[1].id)])
    let linked = try original.joining(pair).timeline
    let dissolve = EditState(timeline: linked).settingTransition(ClipTransition(duration: 1), at: 1)
    try dissolve.timeline.validate(sources: [source])
    try require(dissolve.timeline.video[0].start == .zero && dissolve.timeline.video[1].start == EditTime(3) && dissolve.duration == 11,
        "A transition inside a horizontal link keeps its outgoing picture fixed")
    let straight = dissolve.restoringStraightCut(at: 1)
    try straight.timeline.validate(sources: [source])
    try require(straight.timeline.video.map(\.start) == original.video.map(\.start) && straight.duration == 12, "Removing a linked transition restores the straight cut")

    var compressedTransition = EditState(timeline: original).settingTransition(ClipTransition(duration: 4), at: 1)
    compressedTransition.clips[0].speed = SpeedSettings(rate: 4)
    try compressedTransition.timeline.validate(sources: [source])
    try require(compressedTransition.timeline.transitions.count == 1 && compressedTransition.timeline.video[1].start == .zero,
        "Speed refits a full-length transition without negative time or dropping it")
    try require(compressedTransition.duration == 8, "Shrinking footage already inside an overlap does not move the next cut")
    var reordered = original
    reordered.move(reordered.selection(of: clips[0].id), by: EditTime(12))
    reordered.move(reordered.selection(of: clips[2].id), by: EditTime(-8))
    reordered.move(reordered.selection(of: clips[0].id), by: EditTime(-4))
    let layout = EditState(timeline: reordered).layout
    try require(layout.joins.filter(\.selectable).map(\.time) == [0,4,8,12], "Move derives joins from actual time order")
    try require(layout.boundary(at: 4)?.outgoingID == clips[2].id && layout.boundary(at: 4)?.incomingID == clips[1].id,
        "Moved transition boundaries name the actual neighboring pictures")
    let movedDissolve = EditState(timeline: reordered).settingTransition(ClipTransition(duration: 1), at: layout.boundary(at: 4)!.index)
    try movedDissolve.timeline.validate(sources: [source])
    try require(movedDissolve.timeline.transitions.first?.outgoing == clips[2].id, "Transition after Move edits the correct cut")
    var withOverlay = dissolve.timeline
    let extra = TimelineClip(sourceID: source.id, start: 0, end: 1)
    var inserted = TrackTimeline(clips: [extra]); inserted.move(inserted.entireSelection(), by: EditTime(1))
    withOverlay.video += inserted.video; withOverlay.audio += inserted.audio; withOverlay.links += inserted.links
    try require(EditState(timeline: withOverlay).layout.joins.contains { $0.transition?.id == dissolve.timeline.transitions[0].id && $0.outgoingID == clips[0].id },
        "A third overlay between participant starts cannot hide a transition")

    let long = TrackTimeline(clips: [TimelineClip(sourceID: source.id, start: 0, end: 20)])
    var selected = long.entireSelection(); selected.range = EditInterval(2...8)
    var scope = long.scoped(selected)
    for i in scope.timeline.video.indices where scope.selection.video.contains(scope.timeline.video[i].id) {
        scope.timeline.video[i].content.color = ColorSettings(look: .warm, amount: 0.5)
    }
    var retimedRange = EditState(timeline: scope.timeline)
    for i in retimedRange.clips.indices where scope.selection.video.contains(retimedRange.clips[i].id) { retimedRange.clips[i].speed = SpeedSettings(rate: 2) }
    let spedSelection = retimedRange.timeline.remapping(selected, from: long)
    try require(spedSelection.range == EditInterval(2...5), "Marked ranges follow their source content through a speed change")
    var speedDelete = retimedRange.timeline.scoped(spedSelection); speedDelete.timeline.remove(speedDelete.selection)
    try require(speedDelete.timeline.duration == EditTime(14), "Delete after Speed removes the intended source range only")
    let retained = scope.timeline.remapping(selected, from: long)
    var deleting = scope.timeline.scoped(retained)
    deleting.timeline.remove(deleting.selection)
    try require(deleting.timeline.duration == EditTime(14), "Delete after a range tool removes the entire retained range")
    var split = long; split.split(at: EditTime(5), selection: selected)
    deleting = split.scoped(split.remapping(selected, from: long)); deleting.timeline.remove(deleting.selection)
    try require(deleting.timeline.duration == EditTime(14), "Delete after Split follows both children")

    var colored = EditState(clips: Array(clips.prefix(2)))
    for i in colored.clips.indices { colored.clips[i].color = ColorSettings(look: .warm, amount: 0.5) }
    try require(TimelineNavigation(colored).changes == [0,8] && TimelineNavigation(colored).cutsAndChanges == [0,4,8],
        "Identical effects on separate takes skip a plain cut only on long press")

    var crank = VideoEffectSettings(.undercranking, start: 0, end: 4)
    crank.set("speed", .number(1)); crank.set("mute", .toggle(false))
    let mute = crank.parameters.firstIndex { $0.id == "mute" }!
    crank.parameters[mute].setKeyframe(at: 0, value: .toggle(false))
    crank.parameters[mute].setKeyframe(at: 1, value: .toggle(true))
    crank.parameters[mute].setKeyframe(at: 3, value: .toggle(false))
    var clip = clips[0]; clip.videoEffects = [crank]
    let audio = TrackTimeline(clips: [clip]).audio[0].mapping.runs
    try require(audio.map(\.silent) == [false,true,false] && audio.map { $0.duration.seconds } == [1,2,1],
        "Undercranking mute keyframes control each source interval")
    var oldMute = TrackTimeline(clips: [clip])
    for i in oldMute.video[0].mapping.runs.indices { oldMute.video[0].mapping.runs[i].silent = false }
    for i in oldMute.audio[0].mapping.runs.indices { oldMute.audio[0].mapping.runs[i].silent = true }
    let reopened = try JSONDecoder().decode(EditState.self, from: JSONEncoder().encode(EditState(timeline: oldMute)))
    try require(reopened.timeline.audio[0].mapping.runs.map(\.silent) == [false, true, false], "Reopening repairs old interval mute without changing timing")
    oldMute.synchronizeFollowers()
    try require(oldMute.audio[0].mapping.runs.map(\.silent) == [false, true, false], "Unrelated edits preserve the actual muted interval")
    var limited = TimelineClip(sourceID: source.id, start: 1, end: 3)
    var muteEffect = VideoEffectSettings(.undercranking, start: 1, end: 3)
    muteEffect.set("speed", .number(1.25)); muteEffect.set("mute", .toggle(true)); limited.videoEffects = [muteEffect]
    var extensionTimeline = TrackTimeline(clips: [limited])
    extensionTimeline.extend(extensionTimeline.entireSelection(), left: false, by: EditTime(1), sources: [source])
    try extensionTimeline.validate(sources: [source])
    let extendedRuns = extensionTimeline.audio[0].mapping.runs
    try require(extendedRuns.map(\.silent) == [true, false] && extendedRuns.last?.duration == EditTime(1) && extendedRuns.last?.sourceEnd == 4,
        "Extend stops mute and speed at their effect boundary")
    var leftExtension = TrackTimeline(clips: [limited])
    leftExtension.move(leftExtension.entireSelection(), by: EditTime(2))
    leftExtension.enhance([AudioEffect.make(.highPass)], selection: leftExtension.entireSelection())
    leftExtension.extend(leftExtension.entireSelection(), left: true, by: EditTime(1), sources: [source])
    try leftExtension.validate(sources: [source])
    try require(leftExtension.audio[0].mapping.runs.map(\.silent) == [false, true] && leftExtension.audio[0].enhancements[0].interval.start == EditTime(1),
        "Left Extend retains audio enhancement source coordinates")

    let overlay = TimelineClip(sourceID: source.id, start: 12, end: 14)
    var composite = original, overlayTracks = TrackTimeline(clips: [overlay])
    overlayTracks.move(overlayTracks.entireSelection(), by: EditTime(1)); overlayTracks.video[0].layer = 9
    composite.video += overlayTracks.video; composite.audio += overlayTracks.audio; composite.links += overlayTracks.links
    for rate in [0.5, 2.0] {
        var edit = EditState(timeline: composite)
        let index = edit.clips.firstIndex { $0.id == overlay.id }!
        edit.clips[index].speed = SpeedSettings(rate: rate)
        try edit.timeline.validate(sources: [source])
        try require(clips.allSatisfy { originalClip in edit.timeline.video.first { $0.id == originalClip.id }!.start == original.video.first { $0.id == originalClip.id }!.start },
            "Retiming an overlay never ripples the main sequence")
    }
    composite.video[3].start = EditTime(2); composite.synchronizeFollowers()
    let overlayLayout = EditState(timeline: composite).layout
    try require(overlayLayout.boundary(at: 4)?.outgoingID == clips[0].id, "An overlay ending on a cut cannot steal its outgoing participant")
    let overlapLayout = EditState(timeline: withOverlay).layout
    let firstPlacement = overlapLayout.placements.first { $0.clip.id == clips[0].id }!
    try require(overlapLayout.joins(for: firstPlacement).outgoing.transition != nil, "Background sound envelopes follow participant IDs")
    var movedFade = EditState(timeline: original).settingTransition(ClipTransition(duration: 1), at: 0)
    movedFade.timeline.move(movedFade.timeline.selection(of: clips[0].id), by: EditTime(12))
    let fadeJoin = movedFade.layout.joins.first { $0.transition != nil }!
    try require(fadeJoin.time == 12 && movedFade.layout.boundary(at: 0) == nil, "Moved fades are anchored to their own picture")
    try require(movedFade.layout.boundary(at: 12)?.outgoingID == clips[2].id && movedFade.layout.boundary(at: 12)?.incomingID == clips[0].id,
        "A moved opening fade leaves the adjacent cut available")
    var held = clips[0]; held.frozenFrame = FrozenFrameSegment(sourceTime: 1, duration: 3)
    let holdTimeline = TrackTimeline(clips: [held])
    var holdRange = holdTimeline.entireSelection(); holdRange.range = EditInterval(1...2)
    var holdScope = holdTimeline.scoped(holdRange)
    let holdMapped = holdScope.timeline.remapping(holdRange, from: holdTimeline)
    try require(holdMapped.range == EditInterval(1...2) && holdMapped.video.count == 1, "A marked fraction of a freeze stays on that fraction after a tool splits it")
    holdScope = holdScope.timeline.scoped(holdMapped); holdScope.timeline.remove(holdScope.selection)
    try require(holdScope.timeline.duration == EditTime(2), "Delete after a scoped freeze edit removes only the marked second")
    var edgeFades = EditState(timeline: original).settingTransition(ClipTransition(style: .fadeColor, duration: 1), at: 0)
    edgeFades = edgeFades.settingTransition(ClipTransition(style: .fadeColor, duration: 1), at: 3)
    edgeFades.timeline.move(edgeFades.timeline.selection(of: clips[0].id), by: EditTime(12))
    let replacedFades = edgeFades.settingTransition(ClipTransition(duration: 1), at: edgeFades.layout.boundary(at: 12)!.index)
    try replacedFades.timeline.validate(sources: [source])
    try require(replacedFades.timeline.transitions.count == 1 && replacedFades.timeline.transitions[0].outgoing == clips[2].id && replacedFades.timeline.transitions[0].incoming == clips[0].id,
        "A cut transition replaces the old outgoing and incoming edge fades")
    let replacementID = replacedFades.timeline.transitions[0].id
    try require(replacedFades.timeline.compile().filter { !$0.transitionIDs.isEmpty }.allSatisfy { $0.transitionIDs == [replacementID] }, "Rendering sees only the replacement transition")
    var duplicate = replacedFades.timeline; duplicate.transitions += edgeFades.timeline.transitions
    var rejected = false
    do { try duplicate.validate(sources: [source]) } catch { rejected = true }
    try require(rejected, "Validation rejects competing transition slots")
    duplicate.transitions = edgeFades.timeline.transitions + replacedFades.timeline.transitions; duplicate.pruneRelations()
    try require(duplicate.transitions.map(\.id) == [replacementID], "Pruning deterministically retains the latest transition in each slot")

    var multiRunClip = TimelineClip(sourceID: source.id, start: 2, end: 8)
    var rateEffect = VideoEffectSettings(.undercranking, start: 4, end: 6); rateEffect.set("speed", .number(1.25)); multiRunClip.videoEffects = [rateEffect]
    var enhanced = TrackTimeline(clips: [multiRunClip]); enhanced.move(enhanced.entireSelection(), by: EditTime(2))
    let region = AudioEnhancementRegion(interval: EditInterval(0.5...5.1), effects: [AudioEffect.make(.highPass)])
    enhanced.audio[0].enhancements = [region]
    for left in [false, true] {
        var extended = enhanced
        extended.extend(extended.entireSelection(), left: left, by: EditTime(1), sources: [source])
        try extended.validate(sources: [source])
        try require(extended.audio[0].enhancements.count == 1 && extended.audio[0].enhancements[0].id == region.id,
            "Extend retains one enhancement across consecutive rate runs")
        try require(extended.audio[0].enhancements[0].interval == EditInterval(left ? 1.5...6.1 : 0.5...5.1), "Extend keeps the enhancement span exact")
    }
    print("PASS: review regressions for overlap retiming, linked/reordered transitions, retained range selection, effect navigation and interval mute")
}
