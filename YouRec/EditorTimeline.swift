import SwiftUI
import UIKit

let moveDestinationHint = "Choose a time on the timeline. Your selection will start there."

struct EditorTimeline: UIViewRepresentable {
    let edit: EditState
    let sources: [SourceMedia]
    var folder: URL? = nil
    let waves: [UUID: SourceWaveform]
    var processedWaves: [String: SourceWaveform] = [:]
    var processedRegions: [String: URL] = [:]
    let thumbnails: [UUID: [SourceThumbnail]]
    let playhead: Double
    let pointsPerSecond: Double
    let selected: TimelineSelection
    let selection: ClosedRange<Double>?
    let seek: (Double) -> Void
    let scrubbing: (Bool) -> Void
    var snapEnabled = true
    var moving = false
    var moveLayout: TrackTimeline?
    var moveViewportEnd: EditTime?
    var viewportDuration: Double { moveViewportEnd?.seconds ?? moveLayout?.duration.seconds ?? edit.duration }
    var boundaryChoices: [EditTime]?
    var pickBoundary: ([EditTime]) -> Void = { _ in }
    var laneAreaHeight: Double = 144
    var snapTime: Double?
    var bookmarks: () -> Void = {}
    var focusTransition: (Double) -> Void = { _ in }
    var addVideo: ((VideoInsertionSite) -> Void)?
    var move: (Double, Double) -> Void = { _, _ in }
    var moveEnded: () -> Void = {}
    var moveCancelled: () -> Void = {}
    let editEffects: ([ToolRegion]) -> Void
    let select: (UUID?) -> Void
    var toggleSelection: (UUID) -> Void = { _ in }
    let zoom: (Double) -> Void
    let trim: (UUID, Bool, Double) -> Void
    var gainIdentity = ""
    var gainEnabled = false
    var gainHeadroom: AudioHeadroom?
    var gainHeadroomSelection = TimelineSelection()
    var previewGain: (Double?, TimelineSelection) -> Void = { _, _ in }
    var commitGain: (Double, TimelineSelection) -> Void = { _, _ in }
    var hideFromAccessibility = false
    var contentHeight: CGFloat { 20 + LaneGeometry(self).total }
    func makeUIView(context: Context) -> TimelineSurface { TimelineSurface() }
    func updateUIView(_ view: TimelineSurface, context: Context) { view.accessibilityElementsHidden = hideFromAccessibility; view.configure(self) }
}

private struct LaneGeometry {
    let heights: [CGFloat]
    init(_ model: EditorTimeline) {
        let lanes = timelineLanes(model.edit.timeline, moving: model.moving ? model.selected : nil)
        let count = (lanes.map(\.row).max() ?? 1) + 1
        // The usual two-picture/two-sound overlap fits without hiding a lane.
        let pitch = max(36, min(46, CGFloat(model.laneAreaHeight) / CGFloat(count)))
        var result = [CGFloat](repeating: pitch, count: count)
        // Use spare room for larger video thumbnails regardless of selection. A tap,
        // range or multi-selection must not resize rows or move other hit targets.
        // Divide spare space evenly; crowded timelines retain the pitch/scrolling.
        let videoRows = Set(lanes.filter { !$0.audio }.map(\.row))
        let spare = max(0, CGFloat(model.laneAreaHeight) - CGFloat(count) * pitch)
        let extra = min(82 - pitch, spare / CGFloat(max(1, videoRows.count)))
        for row in videoRows { result[row] += extra }
        heights = result
    }
    var total: CGFloat { heights.reduce(0, +) }
    func top(_ row: Int) -> CGFloat { heights.prefix(row).reduce(0, +) }
    func height(_ row: Int) -> CGFloat { heights.indices.contains(row) ? heights[row] : 46 }
    func row(at y: CGFloat) -> Int { heights.indices.first { y < top($0) + heights[$0] } ?? heights.count }
}

// One finger-sized target for boundaries too close to distinguish at this
// zoom. A cluster opens the exact times instead of guessing which cut was tapped.
private struct MoveBoundaryMarker {
    var firstX: CGFloat
    var lastX: CGFloat
    var times: [EditTime]
    var center: CGFloat { (firstX + lastX) / 2 }

    static func visible(_ choices: [EditTime], viewport: TimelineViewport, offset: CGFloat, width: CGFloat) -> [Self] {
        var result: [Self] = []
        var lo = 0, hi = choices.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if viewport.x(choices[mid].seconds, offset: offset) < 0 { lo = mid + 1 } else { hi = mid }
        }
        for time in choices[lo...] {
            let x = viewport.x(time.seconds, offset: offset)
            if x < 0 { continue }
            if x > width { break }
            if let last = result.indices.last, x - result[last].firstX < 22 {
                result[last].lastX = x; result[last].times.append(time)
            } else { result.append(Self(firstX: x, lastX: x, times: [time])) }
        }
        return result
    }
}

private struct TimelineTransitionMarker {
    let join: TransitionJoin
    let frame: CGRect
    let hitFrame: CGRect
    let durationLines: [CGRect]
}

// Drawing, touch and VoiceOver use the same compact marker geometry.
private func transitionMarkers(_ model: EditorTimeline, width: CGFloat, offset: CGPoint,
                               addSites: [(site: VideoInsertionSite, frame: CGRect)]) -> [TimelineTransitionMarker] {
    guard !model.moving else { return [] }
    let lanes = timelineLanes(model.edit.timeline), layout = LaneGeometry(model)
    let viewport = TimelineViewport(width: width, duration: model.edit.duration, requestedScale: model.pointsPerSecond)
    return model.edit.layout.joins.compactMap { join in
        guard join.transition != nil else { return nil }
        let ids = [join.outgoingID, join.incomingID].compactMap { $0 }
        let rows = Set(lanes.filter { !$0.audio && ids.contains($0.id) }.map(\.row)).sorted()
        guard let row = rows.first else { return nil }
        let x = viewport.x(join.time, offset: offset.x)
        let y = layout.top(row) + 20 - offset.y
        let center = y + 2 + (layout.height(row) - 2) / 2
        var frame = CGRect(x: x - 12, y: center - 11, width: 24, height: 22)
        var hit = CGRect(x: x - 22, y: center - 22, width: 44, height: 44)
        // A tight gutter or gap can place Add beside a one-sided transition.
        // Keep the badge on the clip and the boundary itself tappable.
        if join.edge != 0, addSites.contains(where: { add in
            let outside = join.edge < 0 ? add.frame.maxX <= x : add.frame.minX >= x
            return outside && add.frame.intersects(hit.insetBy(dx: -4, dy: 0))
        }) {
            frame.origin.x = join.edge < 0 ? x : x - frame.width
            hit.origin.x = join.edge < 0 ? x - 1 : x + 1 - hit.width
        }
        hit = hit.intersection(CGRect(x: 0, y: y + 2, width: width, height: max(0, layout.height(row) - 2)))
        let a = viewport.x(join.videoRange.lowerBound, offset: offset.x)
        let b = viewport.x(join.videoRange.upperBound, offset: offset.x)
        let lines = rows.map { CGRect(x: a, y: layout.top($0) + 20 - offset.y + layout.height($0) - 3, width: max(1, b - a), height: 2) }
        return TimelineTransitionMarker(join: join, frame: frame, hitFrame: hit, durationLines: lines)
    }
}

private struct WaveformGainSession {
    let scope: TimelineSelection
    let origin: CGPoint
    var point: CGPoint
    var adjustment: AudioGainDrag
    var cancelling = false
}
private struct WaveformGainPreview {
    let scope: TimelineSelection
    let db: Double
    func gain(for audio: AudioTimelineItem?, at time:Double)->Float {
        guard let audio else {return 1}
        guard !audio.muted else {return 0}
        guard scope.audio.contains(audio.id), scope.range?.contains(EditTime(time)) ?? true else {return Float(audio.gain)}
        return Float(pow(10,db/20))
    }
}

// Keep the span control in the same UIKit surface as the timeline so its entire
// rectangular hit area wins over the filmstrip underneath, including corners.
private final class TimelineSpanButton: UIButton {
    private let plate = UIView()
    private var inputs: [Double] = []
    private var select: (Double) -> Void = { _ in }
    init() {
        super.init(frame:.zero)
        plate.backgroundColor = UIColor.black.withAlphaComponent(0.78)
        plate.layer.borderColor = UIColor.white.withAlphaComponent(0.2).cgColor; plate.layer.borderWidth = 0.5
        plate.isUserInteractionEnabled = false
        setImage(UIImage(systemName:"arrow.left.and.right",withConfiguration:UIImage.SymbolConfiguration(pointSize:16,weight:.semibold)),for:.normal)
        insertSubview(plate,at:0)
        tintColor = .white; imageEdgeInsets = UIEdgeInsets(top:0,left:0,bottom:16,right:0)
        showsMenuAsPrimaryAction = true
        accessibilityLabel = "Timeline view span"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews(); plate.frame = CGRect(x:0,y:0,width:bounds.width,height:28); sendSubviewToBack(plate)
    }
    func configure(width: Double, duration: Double, scale: Double, select: @escaping (Double) -> Void) {
        self.select = select
        // Playback publishes at 30 Hz: don't replace an open menu on each frame.
        guard inputs != [width,duration,scale] else { return }
        inputs = [width,duration,scale]
        let choices = [("Whole project",TimelineViewport(width: width, duration: duration, requestedScale: scale).minimumScale),
                       ("5 minutes",width/300),("1 minute",width/60),("10 seconds",width/10),("1 second",width)]
        accessibilityValue = choices.first { abs(scale-$0.1)<0.0000001 }?.0 ?? "Custom"
        menu = UIMenu(children:choices.map { choice in
            UIAction(title:choice.0,state:abs(scale-choice.1)<0.0000001 ? .on : .off) { [weak self] _ in self?.select(choice.1) }
        })
    }
}

final class TimelineSurface: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private let scroll = UIScrollView()
    private let drawing = TimelineDrawing()
    private let overflow = UIButton(type: .system)
    private let span = TimelineSpanButton()
    private var fittingScrub = false
    private var detailTask: Task<Void, Never>?
    private var detailKeys: [String] = []
    private var previousSelection = Set<UUID>()
    private var accessibleItems: [UUID: TimelineItemAccessibilityElement] = [:]
    private var accessibleTransitions: [Int: TimelineItemAccessibilityElement] = [:]
    private var accessibleBoundaries: [EditTime: TimelineItemAccessibilityElement] = [:]
    private var accessibleAddSites: [VideoInsertionSite: TimelineItemAccessibilityElement] = [:]
    private var videoCoverage: [EditInterval] = []
    private var model: EditorTimeline?
    private var programmatic = false
    private var pinching = false
    private var horizontalScrub = false
    private var scrollStart = CGPoint.zero
    private var zoomStart = 60.0
    private var drag: (id: UUID, left: Bool?, originOffset: CGFloat, originScale: Double)?
    private var dragDelta = 0.0
    private var dragPoint = CGPoint.zero
    private var translation = CGFloat.zero
    private var edgeTimer: Timer?
    private var gain: WaveformGainSession?
    private let gainReadout = WaveformGainReadout()
    private var gainTimer: Timer?
    #if DEBUG
    private var gainCapturePending = Set<String>()
    #endif
    private lazy var gainPan = TimelineEditPanRecognizer(target: self, action: #selector(gainDragged(_:)))
    private lazy var trimHold = UILongPressGestureRecognizer(target: self, action: #selector(trimDragged(_:)))
    private lazy var editPan = TimelineEditPanRecognizer(target: self, action: #selector(dragged(_:)))
    private var viewport: TimelineViewport { TimelineViewport(width: bounds.width, duration: model?.viewportDuration ?? 0, requestedScale: model?.pointsPerSecond ?? 60) }
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.065, alpha: 1)
        scroll.delegate = self; scroll.showsHorizontalScrollIndicator = false; scroll.showsVerticalScrollIndicator = true
        scroll.bounces = false; scroll.isDirectionalLockEnabled = true; scroll.decelerationRate = .fast
        addSubview(scroll); addSubview(drawing)
        overflow.titleLabel?.font = .systemFont(ofSize: 11, weight: .semibold)
        overflow.tintColor = .white; overflow.backgroundColor = UIColor(white: 0.08, alpha: 0.95)
        overflow.layer.cornerRadius = 10; overflow.addTarget(self, action: #selector(revealLanes), for: .touchUpInside)
        overflow.accessibilityLabel = "Show more timeline lanes"; addSubview(overflow)
        addSubview(span)
        drawing.isUserInteractionEnabled = false; drawing.backgroundColor = .clear
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.45; hold.allowableMovement = 10
        tap.require(toFail: hold)
        scroll.addGestureRecognizer(tap); scroll.addGestureRecognizer(hold)
        editPan.delegate = self; editPan.maximumNumberOfTouches = 1; scroll.addGestureRecognizer(editPan); scroll.panGestureRecognizer.require(toFail: editPan)
        gainPan.delegate = self; gainPan.maximumNumberOfTouches = 1; scroll.addGestureRecognizer(gainPan)
        scroll.panGestureRecognizer.require(toFail: gainPan)
        trimHold.minimumPressDuration = 0.3
        trimHold.allowableMovement = 8
        trimHold.delegate = self
        scroll.addGestureRecognizer(trimHold)
        for recognizer in [editPan, scroll.panGestureRecognizer, hold, gainPan] { recognizer.require(toFail: trimHold) }
        scroll.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:))))
        isAccessibilityElement = false
        drawing.isAccessibilityElement = true; drawing.accessibilityLabel = "Video and audio timeline"; drawing.accessibilityIdentifier = "editor.timeline"; drawing.accessibilityTraits = [.adjustable]
        drawing.adjust = { [weak self] in self?.adjust($0) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { edgeTimer?.invalidate(); gainTimer?.invalidate(); detailTask?.cancel() }
    override func didMoveToWindow() { super.didMoveToWindow(); if window == nil { finishGain(apply:false) } }
    override func layoutSubviews() { super.layoutSubviews(); scroll.frame = bounds; drawing.frame = bounds; if let model { configure(model) } }
    func configure(_ value: EditorTimeline) {
        if gain != nil, model?.gainIdentity != value.gainIdentity || !value.gainEnabled || value.moving {finishGain(apply:false)}
        if model?.edit.timeline.video != value.edit.timeline.video || model?.edit.timeline.generated != value.edit.timeline.generated {
            videoCoverage = value.edit.timeline.videoCoverage
        }
        model = value
        span.frame = CGRect(x:max(0,bounds.width-48),y:22,width:44,height:44)
        span.configure(width:bounds.width,duration:value.viewportDuration,scale:value.pointsPerSecond,select:value.zoom)
        let view = viewport, lanes = timelineLanes(value.edit.timeline, moving: value.moving ? value.selected : nil)
        programmatic = true
        scroll.contentSize = CGSize(width: max(view.contentWidth, value.edit.duration * view.scale + 2 * view.inset), height: max(bounds.height, LaneGeometry(value).total + 20))
        if !scroll.isDragging && !scroll.isDecelerating && drag == nil && gain == nil {
            scroll.contentOffset.x = view.fits ? 0 : value.playhead * view.scale
        }
        if value.selection == nil, value.selected.ids != previousSelection, !value.selected.isEmpty, !value.moving, gain == nil,
           let lane = lanes.first(where: { value.selected.ids.contains($0.id) }) {
            let layout = LaneGeometry(value)
            let top = layout.top(lane.row), bottom = top + layout.height(lane.row)
            if top < scroll.contentOffset.y { scroll.contentOffset.y = top }
            else if bottom > scroll.contentOffset.y + bounds.height - 20 { scroll.contentOffset.y = bottom - bounds.height + 20 }
        }
        previousSelection = value.selected.ids
        if drag == nil { scroll.contentOffset.y = min(max(0, scroll.contentOffset.y), max(0, scroll.contentSize.height - bounds.height)) }
        programmatic = false
        if let range = value.selection {
            drawing.accessibilityValue = String(format: "%.2f seconds. Range %.2f to %.2f seconds. %@", value.playhead,
                                                range.lowerBound, range.upperBound, value.selected.title)
        } else {
            drawing.accessibilityValue = String(format: "%.2f seconds. %@", value.playhead, value.selected.isEmpty ? "No selection" : value.selected.countTitle)
        }
        let videoRows = Set(lanes.filter { !$0.audio }.map(\.row)).count
        let audioRows = Set(lanes.filter(\.audio).map(\.row)).count
        drawing.accessibilityValue = "\(videoRows) video lanes, \(audioRows) audio lanes. " + (drawing.accessibilityValue ?? "")
        if let snap = value.snapTime { drawing.accessibilityValue = (drawing.accessibilityValue ?? "") + String(format: ". Snapped at %.2f seconds", snap) }
        drawing.accessibilityHint = value.boundaryChoices != nil ? moveDestinationHint + " Scroll or pinch to find more cuts."
            : value.moving ? "Drag the selected material to move it." : "Tap a picture or waveform to select. Long-press another part to add or remove it. Swipe an audio waveform up or down to adjust volume. Drag sideways to scrub. Hold a yellow handle, then drag to trim."
        drawing.accessibilityCustomActions = value.moving ? [] : lanes.flatMap { item in
            [UIAccessibilityCustomAction(name: "Select \(item.audio ? "audio" : "video") \(item.number)") { _ in value.select(item.id); return true },
             UIAccessibilityCustomAction(name: "\(value.selected.ids.contains(item.id) ? "Remove" : "Add") \(item.audio ? "audio" : "video") \(item.number) \(value.selected.ids.contains(item.id) ? "from" : "to") selection") { _ in value.toggleSelection(item.id); return true }]
        }
        redraw(); showGain()
    }
    private func redraw() {
        let layout = model.map(LaneGeometry.init)
        let hidden = layout.map { l in l.heights.indices.filter { l.top($0) + l.height($0) + 20 > bounds.height + scroll.contentOffset.y }.count } ?? 0
        overflow.isHidden = scroll.contentSize.height <= bounds.height + 1
        overflow.setTitle(hidden > 0 ? "⌄ +\(hidden) lanes" : "⌃ Top lanes", for: .normal)
        overflow.frame = CGRect(x: max(0, bounds.width - 108), y: bounds.height - 30, width: 104, height: 30)
        drawing.boundaryMarkers = MoveBoundaryMarker.visible(model?.boundaryChoices ?? [], viewport: viewport, offset: scroll.contentOffset.x, width: bounds.width)
        drawing.addSites = insertionMarkers(layout: layout)
        requestDetail()
        drawing.model = model; drawing.offset = scroll.contentOffset; drawing.drag = drag.map { ($0.id, $0.left, dragDelta) }; drawing.setNeedsDisplay()
        updateAccessibleItems()
    }
    private func insertionMarkers(layout: LaneGeometry?) -> [(site: VideoInsertionSite, frame: CGRect)] {
        guard let model, model.addVideo != nil, !model.moving, gain == nil, drag == nil, let layout, bounds.width >= 44 else { return [] }
        let lane = CGRect(x: 0, y: 20 - scroll.contentOffset.y, width: bounds.width, height: layout.height(0))
            .intersection(CGRect(x: 0, y: 20, width: bounds.width, height: max(0, bounds.height - 20)))
        guard !lane.isNull, lane.height >= 28 else { return [] }
        let view = viewport
        func x(_ time: EditTime) -> CGFloat { view.x(time.seconds, offset: scroll.contentOffset.x) }
        var result: [(site: VideoInsertionSite, frame: CGRect)] = []
        func add(_ site: VideoInsertionSite, between left: CGFloat, and right: CGFloat, edge: Bool = false) {
            let a = max(0, left), b = min(bounds.width, right)
            guard b - a >= 44 - 0.0001 else { return }
            let h = edge ? 44 : min(44, lane.height)
            var frame = CGRect(x: (a + b - 44)/2, y: lane.midY - h/2, width: 44, height: h)
            if frame.intersects(span.frame) {
                if edge { frame.origin.y = span.frame.maxY + 1 }
                else if span.frame.minX - a >= 44 { frame.origin.x = (a + span.frame.minX - 44)/2 }
                else { return }
            }
            guard bounds.contains(frame), overflow.isHidden || !frame.intersects(overflow.frame),
                  !result.contains(where: { $0.site == site }) else { return }
            result.append((site, frame))
        }
        if videoCoverage.isEmpty {
            add(.start, between: 0, and: bounds.width)
            return result
        }
        let first = videoCoverage[0], last = videoCoverage[videoCoverage.count-1]
        let start = x(.zero), end = x(EditTime(model.edit.duration))
        // Leave 4 pt between adjacent 44 pt targets whenever the gutter allows.
        // At whole-project fit, keep the entire button on screen.
        func addOutside(_ site: VideoInsertionSite, at boundary: CGFloat, before: Bool, edge: Bool) {
            let room = before ? boundary : bounds.width - boundary
            let padding = max(2, min(26, room - 44 - 2))
            let left = before ? boundary - padding - 44 : boundary + padding
            add(site, between: left, and: left + 44, edge: edge)
        }
        addOutside(.start, at: start, before: true, edge: true)
        if last.end < EditTime(model.edit.duration) {
            addOutside(.end, at: x(last.end), before: false, edge: false)
        }
        addOutside(.end, at: end, before: false, edge: true)
        // In a long gap the affordance stays in the visible slice. Its insertion
        // point still belongs to the actual neighbouring picture.
        add(.start, between: start + 2, and: x(first.start) - 2)
        for (left, right) in zip(videoCoverage, videoCoverage.dropFirst()) {
            add(.gap(after: left.end), between: x(left.end) + 2, and: x(right.start) - 2)
        }
        add(.end, between: x(last.end) + 2, and: end - 2)
        return result.sorted { $0.frame.midX < $1.frame.midX }
    }
    private func updateAccessibleItems() {
        guard let model else { return }
        var elements: [Any] = [drawing]
        if model.boundaryChoices != nil {
            let visible = Set(drawing.boundaryMarkers.compactMap { $0.times.first })
            accessibleBoundaries = accessibleBoundaries.filter { visible.contains($0.key) }
            for marker in drawing.boundaryMarkers {
                let times = marker.times
                let element = accessibleBoundaries[times[0]] ?? TimelineItemAccessibilityElement(accessibilityContainer: self)
                accessibleBoundaries[times[0]] = element
                element.accessibilityTraits = .button
                element.accessibilityIdentifier = "timeline.moveBoundary.\(times[0].ticks)"
                element.accessibilityLabel = times.count == 1 ? "Boundary at " + editorTime(times[0].seconds) : "Choose among \(times.count) nearby boundaries"
                let y = min(bounds.height - 44, 68)
                element.accessibilityFrameInContainerSpace = CGRect(x: marker.center - 22, y: y, width: 44, height: 44).intersection(bounds)
                element.activate = { model.pickBoundary(times); return true }
                elements.append(element)
            }
            elements.append(span); accessibilityElements = elements
            return
        }
        accessibleBoundaries.removeAll(keepingCapacity: true)
        let lanes = timelineLanes(model.edit.timeline, moving: model.moving ? model.selected : nil)
        let layout = LaneGeometry(model), viewport = viewport
        let visible = CGRect(x: 0, y: 20, width: bounds.width, height: max(0, bounds.height - 20))
        let ids = Set(lanes.map(\.id)); accessibleItems = accessibleItems.filter { ids.contains($0.key) }
        for lane in lanes {
            let left = viewport.x(lane.interval.start.seconds, offset: scroll.contentOffset.x)
            let card = CGRect(x: left + 1.5, y: layout.top(lane.row) + 22 - scroll.contentOffset.y,
                              width: max(1, lane.interval.duration.seconds * viewport.scale - 3), height: layout.height(lane.row) - 2).intersection(visible)
            guard !card.isNull, card.width >= 1, card.height >= 1 else { continue }
            let item = accessibleItems[lane.id] ?? TimelineItemAccessibilityElement(accessibilityContainer: self)
            accessibleItems[lane.id] = item
            item.accessibilityIdentifier = "timeline.\(lane.audio ? "audio" : "video").\(lane.number)"
            let name = lane.audio ? model.sources.first(where: { $0.id == lane.source })?.originalName : nil
            item.accessibilityLabel = "\(lane.audio ? "Audio" : "Video") \(lane.number)" + (name.map { " · " + $0 } ?? "")
            item.accessibilityHint = lane.audio ? "Swipe up or down to change volume in half-decibel steps. Long-press to add to selection." : "Tap to select. Long-press to add to selection."
            item.accessibilityValue = String(format: "%.3f to %.3f seconds", lane.contentInterval.start.seconds, lane.contentInterval.end.seconds)
            item.accessibilityFrameInContainerSpace = card
            item.accessibilityTraits = model.selected.ids.contains(lane.id) ? [.button, .selected] : [.button]
            item.activate = { guard !model.moving else { return false }; model.select(lane.id); return true }
            elements.append(item)
        }
        let markers = transitionMarkers(model, width: bounds.width, offset: scroll.contentOffset, addSites: drawing.addSites)
        let indices = Set(markers.map { $0.join.index })
        accessibleTransitions = accessibleTransitions.filter { indices.contains($0.key) }
        for marker in markers {
            let frame = marker.hitFrame.intersection(visible)
            guard !frame.isNull, !frame.isEmpty, let transition = marker.join.transition else { continue }
            let item = accessibleTransitions[marker.join.index] ?? TimelineItemAccessibilityElement(accessibilityContainer: self)
            accessibleTransitions[marker.join.index] = item
            item.accessibilityIdentifier = "timeline.transition.\(marker.join.index)"
            item.accessibilityLabel = transition.style.title + " transition, " + marker.join.title
            item.accessibilityHint = "Position the playhead here to edit or remove the transition using the toolbar."
            item.accessibilityValue = String(format: "%.3f seconds", marker.join.time)
            item.accessibilityFrameInContainerSpace = frame
            item.accessibilityTraits = abs(model.playhead - marker.join.time) < 0.0001 ? [.button, .selected] : [.button]
            item.activate = { model.select(nil); model.focusTransition(marker.join.time); return true }
            elements.append(item)
        }
        // The aggregate remains adjustable; each visible card is independently
        // selectable by VoiceOver and exposes its actual clipped screen frame.
        let addSites = drawing.addSites
        let siteIDs = Set(addSites.map(\.site))
        accessibleAddSites = accessibleAddSites.filter { siteIDs.contains($0.key) }
        for (site, frame) in addSites {
            let item = accessibleAddSites[site] ?? TimelineItemAccessibilityElement(accessibilityContainer: self)
            accessibleAddSites[site] = item
            item.accessibilityLabel = site.label
            switch site {
            case .start: item.accessibilityIdentifier = "timeline.add.start"
            case .end: item.accessibilityIdentifier = "timeline.add.end"
            case .gap(let edge):
                item.accessibilityIdentifier = "timeline.add.gap.\(edge.ticks)"
                item.accessibilityValue = editorTime(edge.seconds)
            }
            item.accessibilityFrameInContainerSpace = frame; item.accessibilityTraits = [.button]
            item.activate = { model.addVideo?(site); return true }
            elements.append(item)
        }
        if !overflow.isHidden { elements.append(overflow) }
        elements.append(span)
        accessibilityElements = elements
    }
    private func requestDetail() {
        guard let model, let folder = model.folder, viewport.scale >= 100 else {
            detailTask?.cancel(); detailKeys = []; drawing.details = [:]; return
        }
        let visibleStart = viewport.time(0, offset: scroll.contentOffset.x)
        let visibleEnd = viewport.time(bounds.width, offset: scroll.contentOffset.x)
        var requests: [(String, UUID, URL, Int)] = []
        for lane in timelineLanes(model.edit.timeline, moving: model.moving ? model.selected : nil) where lane.audio {
            guard lane.interval.end.seconds > visibleStart, lane.interval.start.seconds < visibleEnd,
                  let source = model.sources.first(where: { $0.id == lane.source }) else { continue }
            var cursor = lane.contentInterval.start.seconds
            for run in lane.mapping.runs {
                defer { cursor += run.duration.seconds }
                let a = max(cursor, visibleStart), b = min(cursor + run.duration.seconds, visibleEnd)
                guard b > a, !run.silent else { continue }
                let rate = (run.sourceEnd - run.sourceStart) / run.duration.seconds
                let start = run.sourceStart + (a - cursor) * rate, end = run.sourceStart + (b - cursor) * rate
                for tile in max(0, Int(start / WaveformTile.seconds))...max(0, Int(end / WaveformTile.seconds)) {
                    var urls = [folder.appendingPathComponent(source.filename)]
                    if let audio = model.edit.timeline.audio.first(where: { $0.id == lane.id }) {
                        urls += audio.enhancements.compactMap { region in
                            let range = EditInterval(audio.start + region.interval.start, audio.start + region.interval.end)
                            guard range.intersection(EditInterval(a...b)) != nil else { return nil }
                            return model.processedRegions[TrackRenderer.audioKey(source: source.id, effects: region.effects)]
                        }
                    }
                    for url in urls {
                        let key = "\(source.id):\(url.lastPathComponent):\(tile)"
                        if !requests.contains(where: { $0.0 == key }), requests.count < 64 { requests.append((key, source.id, url, tile)) }
                    }
                }
            }
        }
        let keys = requests.map { $0.0 }
        guard keys != detailKeys else { return }
        detailKeys = keys; detailTask?.cancel()
        drawing.details = drawing.details.filter { keys.contains($0.key) }
        detailTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(100))
                for (key, _, url, index) in requests {
                    let tile = try await WaveformDetailCache.shared.tile(url: url, index: index)
                    try Task.checkCancellation(); guard let self, self.detailKeys == keys else { return }
                    self.drawing.details[key] = tile; self.drawing.setNeedsDisplay()
                }
            } catch { /* The overview stays available while seeking or on read failure. */ }
        }
    }
    @objc private func revealLanes() {
        let bottom = max(0, scroll.contentSize.height - bounds.height)
        let next = scroll.contentOffset.y >= bottom - 1 ? 0 : min(bottom, scroll.contentOffset.y + 92)
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: next), animated: true)
    }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { finishScrubbing(); scrollStart = scroll.contentOffset }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        redraw()
        guard !programmatic, !pinching, drag == nil, gain == nil, scroll.isDragging || scroll.isDecelerating, let model, !viewport.fits else { return }
        if !horizontalScrub {
            guard abs(scroll.contentOffset.x - scrollStart.x) > 1, abs(scroll.contentOffset.x - scrollStart.x) >= abs(scroll.contentOffset.y - scrollStart.y) else { return }
            horizontalScrub = true; model.scrubbing(true)
        }
        model.seek(scroll.contentOffset.x / viewport.scale)
    }
    private func finishScrubbing() {
        guard let model, !pinching, horizontalScrub else { return }
        if !viewport.fits {
            let time = scroll.contentOffset.x / viewport.scale
            model.seek(model.snapEnabled ? model.edit.timeline.snap(time, scale: viewport.scale) : time)
        }
        model.scrubbing(false)
        horizontalScrub = false
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) { if !decelerate { finishScrubbing() } }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { finishScrubbing() }
    private func item(at point: CGPoint) -> TimelineLane? {
        guard let model, point.y >= 20 else { return nil }
        let time = EditTime(viewport.time(point.x, offset: scroll.contentOffset.x))
        let row = LaneGeometry(model).row(at: point.y + scroll.contentOffset.y - 20)
        return timelineLanes(model.edit.timeline, moving: model.moving ? model.selected : nil).first { $0.row == row && $0.interval.contains(time) }
    }
    private func transition(at point: CGPoint) -> TimelineTransitionMarker? {
        guard let model, point.y >= 20 else { return nil }
        return transitionMarkers(model, width: bounds.width, offset: scroll.contentOffset, addSites: drawing.addSites)
            .filter { $0.hitFrame.contains(point) }
            .min { abs($0.frame.midX - point.x) < abs($1.frame.midX - point.x) }
    }
    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard let model, !model.moving || model.boundaryChoices != nil else { return }
        if horizontalScrub || scroll.isDecelerating {
            scroll.setContentOffset(scroll.contentOffset, animated: false)
            finishScrubbing()
            return
        }
        let point = gesture.location(in: self)
        if model.boundaryChoices != nil {
            if let closest = drawing.boundaryMarkers.min(by: { abs($0.center - point.x) < abs($1.center - point.x) }),
               point.x >= closest.firstX - 22, point.x <= closest.lastX + 22 {
                model.pickBoundary(closest.times)
            }
            return
        }
        let time = viewport.time(point.x, offset: scroll.contentOffset.x)
        if point.y < 20 {
            let marks = model.edit.timeline.resolvedBookmarks.filter { abs($0.time.seconds - time) * viewport.scale < 10 }
            if marks.count > 1 { model.bookmarks(); return }
            if let mark = marks.min(by: { abs($0.time.seconds - time) < abs($1.time.seconds - time) }) { model.seek(mark.time.seconds); return }
            model.seek(model.snapEnabled ? model.edit.timeline.snap(time, scale: viewport.scale) : time)
        } else if let marker = drawing.addSites.first(where: { $0.frame.contains(point) }) {
            model.addVideo?(marker.site)
        } else if let marker = transition(at: point) {
            model.select(nil); model.focusTransition(marker.join.time)
        } else if let item = item(at: point) {
            // Range membership is an edit scope, not a whole-clip selection.
            model.select(model.selection == nil && model.edit.timeline.selection(of: item.id).ids == model.selected.ids ? nil : item.id)
        }
        else { model.select(nil); model.seek(time) }
    }
    @objc private func held(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let model, !model.moving, !scroll.isDecelerating else { return }
        let point = gesture.location(in: self)
        if let marker = transition(at: point) { model.select(nil); model.focusTransition(marker.join.time); return }
        guard let part = item(at: point) else { return }
        model.toggleSelection(part.id)
        UISelectionFeedbackGenerator().selectionChanged()
    }
    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        guard let model, !model.moving || model.boundaryChoices != nil else { return }
        if gesture.state == .began { finishScrubbing(); zoomStart = viewport.scale; pinching = true }
        if gesture.state == .began || gesture.state == .changed { model.zoom(max(viewport.minimumScale, min(720, zoomStart * gesture.scale))) }
        if gesture.state == .ended || gesture.state == .cancelled { pinching = false }
    }
    private func hit(_ point: CGPoint) -> (UUID, Bool?)? {
        guard let model else { return nil }
        if drawing.addSites.contains(where: { $0.frame.contains(point) }) { return nil }
        if model.boundaryChoices != nil { return nil }
        if model.moving, let lane = item(at: point), model.selected.ids.contains(lane.id) { return (lane.id, nil) }
        guard !model.moving, model.selection == nil, model.selected.video.count <= 1,
              model.selected.audio.count <= 1, point.y >= 20, transition(at: point) == nil else { return nil }
        let geometry = LaneGeometry(model)
        let laneY = point.y + scroll.contentOffset.y - 20
        let row = geometry.row(at: laneY)
        guard geometry.heights.indices.contains(row), abs(laneY - geometry.top(row) - geometry.height(row) / 2) <= 22 else { return nil }
        for lane in timelineLanes(model.edit.timeline, moving: model.moving ? model.selected : nil) where lane.row == row && model.selected.ids.contains(lane.id) {
            let left = viewport.x(lane.interval.start.seconds, offset: scroll.contentOffset.x), right = viewport.x(lane.interval.end.seconds, offset: scroll.contentOffset.x)
            guard right - left >= 44 else { continue }
            let leftDistance = lane.trimsLeft && left >= 0 && left < bounds.width ? abs(point.x - left) : .infinity
            let rightDistance = lane.trimsRight && right > 0 && right <= bounds.width ? abs(point.x - right) : .infinity
            if min(leftDistance, rightDistance) <= 22 { return (lane.id, leftDistance <= rightDistance) }
        }
        return nil
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === trimHold { return !modelMoving && hit(touch.location(in: self))?.1 != nil }
        return true
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === gainPan {
            let velocity=gainPan.velocity(in:self)
            return abs(velocity.y)>abs(velocity.x) && gainScope(at:gainPan.touchDown ?? gainPan.location(in:self)) != nil
        }
        guard gestureRecognizer === editPan else { return true }
        let velocity = editPan.velocity(in: self)
        return abs(velocity.x) > abs(velocity.y) && (modelMoving ? hit(editPan.touchDown ?? gestureRecognizer.location(in: self)) != nil : viewport.fits)
    }
    private func gainScope(at point:CGPoint)->TimelineSelection? {
        guard let model,model.gainEnabled,!model.moving,!scroll.isDecelerating,
              let lane=item(at:point),lane.audio else {return nil}
        let time=EditTime(viewport.time(point.x,offset:scroll.contentOffset.x))
        if model.selected.audio.contains(lane.id),model.selected.range?.contains(time) ?? true {
            var scope=model.selected;scope.video=[];return scope
        }
        return TimelineSelection(audio:[lane.id])
    }
    @objc private func gainDragged(_ gesture:TimelineEditPanRecognizer) {
        guard let model,let window else {finishGain(apply:false);return}
        if gesture.state == .began {
            let touch=gesture.touchDown ?? gesture.location(in:self)
            guard let scope=gainScope(at:touch) else {return}
            let items=model.edit.timeline.audio.filter {scope.audio.contains($0.id)}
            let origin=convert(touch,to:window)
            gain=WaveformGainSession(scope:scope,origin:origin,point:origin,
                adjustment:AudioGainDrag(value:AudioGainGrid.common(items),levels:(items.map(\.volumeDB).min() ?? 0)...(items.map(\.volumeDB).max() ?? 0)))
            #if DEBUG
            gainCapturePending=[];captureGainFrame("before",delayed:false)
            #endif
            // Dragging an unselected waveform targets that item. An existing
            // range/multi-selection applies only when the touch starts in it.
            if !scope.audio.isSubset(of:model.selected.audio) || scope.range != model.selected.range {model.select(scope.audio.first)}
            gainTimer=Timer(timeInterval:0.12,repeats:true) {[weak self] _ in self?.repeatGainEdge()}
            if let gainTimer {RunLoop.main.add(gainTimer,forMode:.common)}
            UIImpactFeedbackGenerator(style:.light).impactOccurred()
        }
        if [.began,.changed,.ended].contains(gesture.state),var session=gain {
            session.point=gesture.location(in:window)
            session.cancelling=abs(session.point.x-session.origin.x)>80
            let before=session.adjustment.value
            session.adjustment.update(distance:session.origin.y-session.point.y)
            gain=session
            if session.adjustment.value != before {UISelectionFeedbackGenerator().selectionChanged()}
            previewGain()
        }
        if [.ended,.cancelled,.failed].contains(gesture.state) {finishGain(apply:gesture.state == .ended)}
    }
    private func repeatGainEdge() {
        guard var session=gain,!session.cancelling,let window else {return}
        let delta:Double=session.point.y<window.safeAreaInsets.top+22 ? 0.5 : session.point.y>window.bounds.height-window.safeAreaInsets.bottom-22 ? -0.5 : 0
        guard delta != 0 else {return}
        session.adjustment.stepAtEdge(delta);gain=session;previewGain()
    }
    private func previewGain() {
        guard let session=gain,let model else {return}
        let db=session.cancelling ? nil : session.adjustment.value
        model.previewGain(db,session.scope)
        drawing.gainPreview=db.map {WaveformGainPreview(scope:session.scope,db:$0)}
        drawing.setNeedsDisplay();showGain()
        #if DEBUG
        if let db,abs(db-(session.adjustment.initial ?? 0))>=3.9 {captureGainFrame("during",delayed:true)}
        #endif
    }
    private func showGain() {
        guard let session=gain,let model,let window else {return}
        let scopeMatches=model.gainHeadroomSelection.audio==session.scope.audio && model.gainHeadroomSelection.range==session.scope.range
        let clips=scopeMatches && session.adjustment.value.map {model.gainHeadroom?.clips(at:$0)==true}==true
        gainReadout.show(level:session.adjustment.value,clipping:clips,cancelling:session.cancelling,point:session.point,in:window)
        #if DEBUG
        if clips {captureGainFrame("clipping",delayed:true)}
        #endif
    }
    private func finishGain(apply:Bool) {
        guard let session=gain else {return}
        gain=nil;gainTimer?.invalidate();gainTimer=nil;gainReadout.removeFromSuperview()
        drawing.gainPreview=nil;drawing.setNeedsDisplay()
        model?.previewGain(nil,session.scope)
        if apply,!session.cancelling,let db=session.adjustment.value,db != session.adjustment.initial {model?.commitGain(db,session.scope)}
    }
    #if DEBUG
    private func captureGainFrame(_ name:String,delayed:Bool) {
        guard CommandLine.arguments.contains("--capture-waveform-gain"),name == "clipping" || gain?.adjustment.initial == 0,!gainCapturePending.contains(name),let window else {return}
        gainCapturePending.insert(name)
        let capture = { [weak self,weak window] in
            guard let self,let window,self.gain != nil else {return}
            let image=UIGraphicsImageRenderer(bounds:window.bounds).image {_ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:delayed)}
            let url=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("waveform-gain-"+name+".png")
            try? image.pngData()?.write(to:url)
        }
        if delayed {DispatchQueue.main.asyncAfter(deadline:.now()+0.05,execute:capture)} else {capture()}
    }
    #endif
    private var modelMoving: Bool { model?.moving == true }
    @objc private func dragged(_ gesture: TimelineEditPanRecognizer) {
        guard let model else { return }
        let touchDown = gesture.touchDown ?? gesture.location(in: self)
        dragPoint = gesture.location(in: self); translation = dragPoint.x - touchDown.x
        if gesture.state == .began, !modelMoving, viewport.fits {
            fittingScrub = true; model.scrubbing(true)
        }
        if fittingScrub {
            let time = viewport.time(dragPoint.x, offset: 0)
            model.seek(gesture.state == .ended && model.snapEnabled ? model.edit.timeline.snap(time, scale: viewport.scale) : time)
            if [.ended, .cancelled, .failed].contains(gesture.state) { fittingScrub = false; model.scrubbing(false) }
            return
        }
        trackDrag(gesture.state, origin: touchDown)
    }

    @objc private func trimDragged(_ gesture: UILongPressGestureRecognizer) {
        dragPoint = gesture.location(in: self)
        if gesture.state == .began {
            trimOrigin = dragPoint
            UISelectionFeedbackGenerator().selectionChanged()
        }
        translation = dragPoint.x - trimOrigin.x
        trackDrag(gesture.state, origin: trimOrigin)
    }

    private var trimOrigin = CGPoint.zero
    private func trackDrag(_ state: UIGestureRecognizer.State, origin: CGPoint) {
        guard let model else { return }
        if state == .began, let hit = hit(origin) {
            drag = (hit.0, hit.1, scroll.contentOffset.x, viewport.scale); dragDelta = 0
            model.scrubbing(true)
            edgeTimer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in self?.advanceEdge() }
        }
        // Fast short drags can go from began straight to ended. Always apply
        // the final touch translation, including the movement that began recognition.
        if [.began, .changed, .ended].contains(state) { updateDrag() }
        if [.ended, .cancelled, .failed].contains(state) {
            edgeTimer?.invalidate(); edgeTimer = nil
            if state == .ended, let drag, let left = drag.left { model.trim(drag.id, left, dragDelta) }
            if let drag, drag.left == nil {
                if state == .ended { model.moveEnded() } else { model.moveCancelled() }
            }
            self.drag = nil; dragDelta = 0; model.scrubbing(false); redraw()
        }
    }
    private func advanceEdge() {
        guard let drag, drag.left == nil || abs(translation) > 8,
              dragPoint.x < 26 || dragPoint.x > bounds.width - 26 else { return }
        programmatic = true
        scroll.contentOffset.x = min(max(0, scroll.contentOffset.x + (dragPoint.x < 26 ? -6 : 6)), max(0, scroll.contentSize.width - bounds.width))
        programmatic = false; updateDrag()
    }
    private func updateDrag() {
        guard let drag, let model else { return }
        dragDelta = Double(translation + scroll.contentOffset.x - drag.originOffset) / drag.originScale
        if drag.left == nil { model.move(dragDelta, drag.originScale) }
        redraw()
    }
    override func accessibilityIncrement() { adjust(1) }
    override func accessibilityDecrement() { adjust(-1) }
    private func adjust(_ direction: Double) { guard let model else { return }; model.seek(model.playhead + direction * max(1 / 30, 10 / viewport.scale)) }
}

private final class TimelineDrawing: UIView {
    var boundaryMarkers: [MoveBoundaryMarker] = []
    var addSites: [(site: VideoInsertionSite, frame: CGRect)] = []
    var gainPreview: WaveformGainPreview?
    var details: [String: WaveformTile] = [:]
    var adjust: (Double) -> Void = { _ in }
    override func accessibilityIncrement() { adjust(1) }
    override func accessibilityDecrement() { adjust(-1) }
    var model: EditorTimeline?
    var offset = CGPoint.zero
    var drag: (UUID, Bool?, Double)?
    private var pyramids: [String: [[Float]]] = [:]
    private func peak(source: String, wave: SourceWaveform, from: Double, to: Double) -> Float {
        if pyramids[source]?.first?.count != wave.peaks.count {
            var levels = [wave.peaks]
            while let last = levels.last, last.count > 1 {
                levels.append(stride(from: 0, to: last.count, by: 2).map { max(last[$0], last[min(last.count - 1, $0 + 1)]) })
            }
            pyramids[source] = levels
        }
        guard let levels = pyramids[source], !wave.peaks.isEmpty, wave.duration > 0 else { return 0 }
        let a = max(0, min(wave.peaks.count - 1, Int(from / wave.duration * Double(wave.peaks.count))))
        let b = max(a + 1, min(wave.peaks.count, Int(to / wave.duration * Double(wave.peaks.count))))
        var cursor = a, result: Float = 0
        while cursor < b {
            var level = 0
            while level + 1 < levels.count, cursor % (1 << (level + 1)) == 0, cursor + (1 << (level + 1)) <= b { level += 1 }
            result = max(result, levels[level][cursor >> level]); cursor += 1 << level
        }
        return result
    }
    override func draw(_ rect: CGRect) {
        guard let model, let context = UIGraphicsGetCurrentContext() else { return }
        let view = TimelineViewport(width: bounds.width, duration: model.viewportDuration, requestedScale: model.pointsPerSecond)
        func x(_ time: Double) -> Double { view.x(time, offset: offset.x) }
        let start = view.time(0, offset: offset.x), end = view.time(bounds.width, offset: offset.x)
        let selected = model.selected.ids
        let regions = model.edit.toolRegions
        context.saveGState(); context.clip(to: CGRect(x: 0, y: 20, width: bounds.width, height: max(0, bounds.height - 20)))
        let layout = LaneGeometry(model)
        let trackBottom = max(20,min(bounds.height,20 + layout.total - offset.y))
        for lane in timelineLanes(model.edit.timeline, moving: model.moving ? model.selected : nil) {
            guard lane.interval.end.seconds >= start, lane.interval.start.seconds <= end else { continue }
            let rowHeight = layout.height(lane.row)
            let y = layout.top(lane.row) + 20 - offset.y
            guard y + rowHeight >= 20, y <= bounds.height else { continue }
            let left = x(lane.interval.start.seconds), right = x(lane.interval.end.seconds)
            let contentLeft = x(lane.contentInterval.start.seconds)
            let card = CGRect(x: max(-5, left + 1.5), y: y + 2, width: max(1, min(bounds.width + 5, right - 1.5) - max(-5, left + 1.5)), height: rowHeight - 2)
            context.saveGState(); context.addPath(CGPath(roundedRect: card, cornerWidth: 5, cornerHeight: 5, transform: nil)); context.clip()
            context.setFillColor(UIColor(white: lane.audio ? 0.12 : 0.18, alpha: 1).cgColor); context.fill(card)
            if lane.audio, let wave = model.waves[lane.source] {
                let audio = model.edit.timeline.audio.first { $0.id == lane.id }
                let censors = audio.map { model.edit.timeline.censorSpans(for: $0) } ?? []
                // The clip badge overlays the wave; it does not reserve a label
                // row. Use the full card symmetrically, with a small edge inset.
                let half = max(1, (card.height - 6) / 2), center = card.midY
                context.setStrokeColor(UIColor.systemMint.withAlphaComponent(audio?.muted == true ? 0.25 : 0.85).cgColor); context.setLineWidth(1)
                for px in stride(from: left + max(0, ceil(-left)), to: min(bounds.width, right), by: 1) {
                    let a = lane.mapping.source(at: EditTime(max(0, (px - contentLeft) / view.scale))) ?? 0
                    let b = lane.mapping.source(at: EditTime(min(lane.mapping.duration.seconds, (px - contentLeft + 1) / view.scale))) ?? a
                    var runStart = 0.0
                    let local = max(0, (px - contentLeft) / view.scale)
                    let silent = lane.mapping.runs.first { run in defer { runStart += run.duration.seconds }; return local < runStart + run.duration.seconds }?.silent ?? true
                    let regionKey = audio?.enhancements.first { $0.interval.contains(EditTime(local)) }.map { TrackRenderer.audioKey(source: lane.source, effects: $0.effects) }
                    let processed = regionKey.flatMap { model.processedRegions[$0] }
                    let filename = processed?.lastPathComponent ?? model.sources.first { $0.id == lane.source }?.filename ?? ""
                    let waveKey = "\(lane.source):\(filename)"
                    let enhancedWave = regionKey.flatMap { model.processedWaves[$0] }
                    let displayed = enhancedWave ?? wave
                    // A pending processed overview must not cache raw peaks under its key.
                    let overviewKey = enhancedWave == nil ? "\(lane.source):original" : waveKey
                    let peak = silent ? 0 : peak(source: overviewKey, wave: displayed, from: a, to: max(a, b))
                    var envelope: (Float, Float) = (-peak, peak)
                    if view.scale >= 100 && !silent {
                        let tileIndex = Int(a / WaveformTile.seconds)
                        if let detail = details["\(waveKey):\(tileIndex)"]?.envelope(from: a, to: max(a, b)) {
                            envelope = detail
                            if b >= Double(tileIndex + 1) * WaveformTile.seconds,
                               let next = details["\(waveKey):\(tileIndex + 1)"]?.envelope(from: Double(tileIndex + 1) * WaveformTile.seconds, to: b) { envelope = (min(detail.0, next.0), max(detail.1, next.1)) }
                        }
                    }
                    if !silent, let censor = censors.first(where: { $0.start <= lane.contentInterval.start.seconds + local && lane.contentInterval.start.seconds + local < $0.end }) {
                        let t = lane.contentInterval.start.seconds + local - censor.envelopeStart
                        let level = censor.emitsTone ? Float(censor.settings.amplitude * censor.settings.envelopeValue(time: t, duration: censor.envelopeEnd - censor.envelopeStart)) : 0
                        envelope = (-level, level)
                    }
                    let level = gainPreview?.gain(for:audio,at:lane.contentInterval.start.seconds+local) ?? Float(audio?.gain ?? 1)
                    let fade = min(audio?.fadeIn?.gain(local) ?? 1, audio?.fadeOut?.gain(lane.contentInterval.duration.seconds - local) ?? 1)
                    let gain = level * Float(fade)
                    // Square-root amplitude keeps quiet consonants visible without
                    // the old log display making nearly every peak full height.
                    let top = max(0.35, CGFloat(sqrt(min(1, max(0, envelope.1 * gain)))) * half)
                    let bottom = max(0.35, CGFloat(sqrt(min(1, max(0, -envelope.0 * gain)))) * half)
                    context.move(to: CGPoint(x: px, y: center - top)); context.addLine(to: CGPoint(x: px, y: center + bottom))
                }
                context.strokePath()
                for region in audio?.censors ?? [] {
                    context.setFillColor(UIColor.systemOrange.cgColor)
                    context.fill(CGRect(x: x(lane.contentInterval.start.seconds + region.interval.start.seconds), y: card.maxY - 6, width: region.interval.duration.seconds * view.scale, height: 3))
                }
                for region in audio?.enhancements ?? [] {
                    context.setFillColor(UIColor.systemPurple.cgColor)
                    context.fill(CGRect(x: x(lane.contentInterval.start.seconds + region.interval.start.seconds), y: card.maxY - 3, width: region.interval.duration.seconds * view.scale, height: 3))
                }
            } else if let images = model.thumbnails[lane.source], !images.isEmpty {
                // Taller rows need wider landscape thumbnails, not a tighter
                // crop of the same narrow strip.
                let tileWidth = max(64, card.height * images[0].image.size.width / max(1, images[0].image.size.height))
                var tile = max(left, floor((max(0, left) - left) / tileWidth) * tileWidth + left)
                while tile < min(right, bounds.width) {
                    let sourceTime = lane.mapping.source(at: EditTime((tile - contentLeft) / view.scale)) ?? 0
                    let image = images.last { $0.time <= sourceTime }?.image ?? images[0].image
                    let ratio = max(tileWidth / image.size.width, card.height / image.size.height)
                    let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
                    context.saveGState(); context.clip(to: CGRect(x: tile, y: card.minY, width: tileWidth, height: card.height))
                    image.draw(in: CGRect(x: tile + (tileWidth - size.width) / 2, y: card.midY - size.height / 2, width: size.width, height: size.height)); context.restoreGState(); tile += tileWidth
                }
            }
            for region in regions where region.clipID == lane.id && !lane.audio && region.tool != .transition {
                context.setFillColor(UIColor(region.tool.tint).cgColor)
                context.fill(CGRect(x: x(region.range.lowerBound), y: card.maxY - 3, width: (region.range.upperBound - region.range.lowerBound) * view.scale, height: 3))
            }
            let linked = model.edit.timeline.links.contains { $0.members.contains(lane.id) }
            let audio = model.edit.timeline.audio.first { $0.id == lane.id }
            let picture = audio.flatMap { sound in model.edit.timeline.video.first {
                $0.occurrenceID == sound.occurrenceID && $0.mapping.source(at: .zero) == sound.mapping.source(at: .zero)
            } }
            let displacement = audio.flatMap { sound in picture.map { (sound.start - $0.start).seconds } } ?? 0
            let offsetLabel = lane.audio && !linked && abs(displacement) >= 0.01 ? String(format: " %+.2fs", displacement) : ""
            let label = "\(lane.audio ? "♪" : "V")\(lane.number)" + offsetLabel
            if card.width > 28 {
                let font = UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
                let size = (label as NSString).size(withAttributes: [.font: font])
                let badge = CGRect(x: max(4, card.minX + 3), y: lane.audio ? card.maxY - 20 : card.minY + 2, width: size.width + 6 + (linked ? 13 : 0), height: 18)
                context.setFillColor(UIColor.black.withAlphaComponent(lane.audio ? 0.6 : 0.72).cgColor)
                context.addPath(CGPath(roundedRect: badge, cornerWidth: 4, cornerHeight: 4, transform: nil)); context.fillPath()
                (label as NSString).draw(at: CGPoint(x: badge.minX + 3, y: badge.minY + 1), withAttributes: [.font: font, .foregroundColor: UIColor.white])
                if linked {
                    UIImage(systemName:"link",withConfiguration:UIImage.SymbolConfiguration(pointSize:10,weight:.semibold))?
                        .withTintColor(.white.withAlphaComponent(0.7),renderingMode:.alwaysOriginal)
                        .draw(in:CGRect(x:badge.maxX-13,y:badge.midY-5,width:10,height:10))
                }
            }
            context.restoreGState()
            if selected.contains(lane.id) {
                if let range = model.selection {
                    // Highlight only the source/time intersection that an edit
                    // will affect. Other tracks and the rest of a clip stay plain.
                    let from = max(lane.interval.start.seconds, range.lowerBound)
                    let to = min(lane.interval.end.seconds, range.upperBound)
                    if to > from {
                        let part = card.intersection(CGRect(x: x(from), y: card.minY, width: (to - from) * view.scale, height: card.height))
                        if !part.isNull && part.width > 0 {
                            context.saveGState()
                            context.addPath(CGPath(roundedRect: card, cornerWidth: 5, cornerHeight: 5, transform: nil)); context.clip()
                            context.setFillColor(UIColor.systemYellow.withAlphaComponent(0.16).cgColor); context.fill(part)
                            context.setStrokeColor(UIColor.systemYellow.cgColor); context.setLineWidth(2)
                            context.stroke(part.insetBy(dx: min(1, part.width / 2), dy: 1)); context.restoreGState()
                        }
                    }
                } else {
                    context.setStrokeColor(UIColor.systemYellow.cgColor); context.setLineWidth(2)
                    context.addPath(CGPath(roundedRect: card.insetBy(dx: 1, dy: 1), cornerWidth: 4, cornerHeight: 4, transform: nil)); context.strokePath()
                    if !model.moving && model.selected.video.count <= 1 && model.selected.audio.count <= 1 && right - left >= 44 {
                        context.setFillColor(UIColor.systemYellow.cgColor)
                        for edge in [lane.trimsLeft ? left + 3 : nil, lane.trimsRight ? right - 6 : nil].compactMap({ $0 }) {
                            context.fill(CGRect(x: edge, y: card.midY - 10, width: 5, height: 24))
                        }
                    }
                }
            }
            if let drag, drag.0 == lane.id, let isLeft = drag.1 {
                let removed = min(max(0, lane.interval.duration.seconds - TimelineEditing.frame), isLeft ? drag.2 : -drag.2)
                let edge = isLeft ? lane.interval.start.seconds + removed : lane.interval.end.seconds - removed
                context.setStrokeColor(UIColor.systemYellow.cgColor); context.setLineWidth(3)
                context.move(to: CGPoint(x: x(edge), y: card.minY)); context.addLine(to: CGPoint(x: x(edge), y: card.maxY)); context.strokePath()
                let title = removed > 0 ? "Trim " + editorTime(removed) : (isLeft ? "Trim start" : "Trim end")
                let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold), .foregroundColor: UIColor.black]
                let size = (title as NSString).size(withAttributes: attributes)
                let badge = CGRect(x: min(max(2, x(edge) - size.width / 2 - 6), bounds.width - size.width - 14),
                                   y: card.minY + 2, width: size.width + 12, height: size.height + 4)
                UIColor.systemYellow.setFill()
                UIBezierPath(roundedRect: badge, cornerRadius: 5).fill()
                (title as NSString).draw(at: CGPoint(x: badge.minX + 6, y: badge.minY + 2), withAttributes: attributes)
            }
        }
        for marker in transitionMarkers(model, width: bounds.width, offset: offset, addSites: addSites) {
            let active = abs(model.playhead - marker.join.time) < 0.0001
            context.setFillColor(UIColor.systemOrange.withAlphaComponent(0.85).cgColor)
            for line in marker.durationLines { context.fill(line) }
            guard marker.frame.intersects(bounds) else { continue }
            let path = CGPath(roundedRect: marker.frame, cornerWidth: 5, cornerHeight: 5, transform: nil)
            context.addPath(path); context.setFillColor((active ? UIColor.systemOrange : UIColor(white: 0.1, alpha: 1)).cgColor); context.fillPath()
            context.addPath(path); context.setStrokeColor(UIColor.systemOrange.cgColor); context.setLineWidth(1.5); context.strokePath()
            context.setFillColor((active ? UIColor.black : UIColor.systemOrange).cgColor)
            let c = CGPoint(x: marker.frame.midX, y: marker.frame.midY)
            for side in [CGFloat(-1), CGFloat(1)] {
                context.move(to: CGPoint(x: c.x + side * 7, y: c.y - 5))
                context.addLine(to: CGPoint(x: c.x + side, y: c.y))
                context.addLine(to: CGPoint(x: c.x + side * 7, y: c.y + 5)); context.closePath(); context.fillPath()
            }
        }
        if let base = model.moveLayout {
            context.setStrokeColor(UIColor.white.withAlphaComponent(0.45).cgColor); context.setLineWidth(1); context.setLineDash(phase: 0, lengths: [4, 3])
            let currentRows = Dictionary(uniqueKeysWithValues: timelineLanes(model.edit.timeline, moving: model.moving ? model.selected : nil).map { ($0.id, $0.row) })
            for lane in timelineLanes(base) where selected.contains(lane.id) {
                // Show the original position on the item's current lane, so its
                // outline never pretends to be another video or waveform.
                let row = currentRows[lane.id] ?? lane.row
                context.stroke(CGRect(x: x(lane.interval.start.seconds), y: layout.top(row) + 22 - offset.y,
                    width: lane.interval.duration.seconds * view.scale, height: layout.height(row) - 4))
            }
            context.setLineDash(phase: 0, lengths: [])
        }
        if let selection = model.selection {
            // Quiet guides locate the range through gaps without shading lanes
            // outside its scope. Whole-clip trim handles remain exclusive to taps.
            context.setStrokeColor(UIColor.systemYellow.withAlphaComponent(0.5).cgColor); context.setLineWidth(1)
            context.setLineDash(phase: 0, lengths: [2, 3])
            for time in Set([selection.lowerBound, selection.upperBound]) {
                context.move(to: CGPoint(x: x(time), y: 20)); context.addLine(to: CGPoint(x: x(time), y: trackBottom))
            }
            context.strokePath(); context.setLineDash(phase: 0, lengths: [])
        }
        context.restoreGState()
        if let time = model.snapTime {
            context.setStrokeColor(UIColor.systemCyan.cgColor); context.setLineWidth(1.5)
            context.setLineDash(phase: 0, lengths: [3, 3]); context.move(to: CGPoint(x: x(time), y: 0))
            context.addLine(to: CGPoint(x: x(time), y: trackBottom)); context.strokePath(); context.setLineDash(phase: 0, lengths: [])
            context.setFillColor(UIColor.systemCyan.cgColor); context.fillEllipse(in: CGRect(x: x(time) - 3, y: 1, width: 6, height: 6))
        }
        let rulerStep = [0.1, 0.5, 1.0, 2.0, 5.0, 10.0, 30.0, 60.0, 300.0, 600.0, 1800.0, 3600.0].first { $0 * view.scale >= 44 } ?? 7200
        for time in stride(from: floor(start / rulerStep) * rulerStep, through: end, by: rulerStep) {
            let label = time < 60 ? String(format: "%g", time) : String(format: "%d:%02d", Int(time) / 60, Int(time) % 60)
            (label as NSString).draw(at: CGPoint(x: x(time) + 3, y: 2), withAttributes: [.font: UIFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium), .foregroundColor: UIColor.secondaryLabel])
        }
        var clusters: [(x: Double, count: Int)] = []
        for mark in model.edit.timeline.resolvedBookmarks {
            let px = x(mark.time.seconds)
            guard px >= 0, px <= bounds.width else { continue }
            if let last = clusters.last, px - last.x < 12 { clusters[clusters.count - 1].count += 1 }
            else { clusters.append((px, 1)) }
        }
        for cluster in clusters {
            let px = cluster.x
            context.setFillColor(UIColor.systemOrange.cgColor)
            context.move(to: CGPoint(x: px - 4, y: 12)); context.addLine(to: CGPoint(x: px + 4, y: 12)); context.addLine(to: CGPoint(x: px, y: 19)); context.closePath(); context.fillPath()
            if cluster.count > 1 { ("\(cluster.count)" as NSString).draw(at: CGPoint(x: px + 4, y: 8), withAttributes: [.font: UIFont.systemFont(ofSize: 9, weight: .bold), .foregroundColor: UIColor.systemOrange]) }
        }
        context.setStrokeColor(UIColor.white.cgColor); context.setLineWidth(1.5)
        context.move(to: CGPoint(x: x(model.playhead), y: 0)); context.addLine(to: CGPoint(x: x(model.playhead), y: trackBottom)); context.strokePath()
        for marker in boundaryMarkers {
            let color = UIColor.systemCyan
            context.saveGState()
            context.setStrokeColor(color.withAlphaComponent(0.85).cgColor); context.setLineWidth(1.5)
            context.setLineDash(phase: 0, lengths: [4, 3])
            for time in marker.times {
                let edge = x(time.seconds)
                context.move(to: CGPoint(x: edge, y: 18)); context.addLine(to: CGPoint(x: edge, y: trackBottom))
            }
            context.strokePath(); context.setFillColor(color.cgColor)
            let center = marker.center
            context.move(to: CGPoint(x: center - 5, y: 13)); context.addLine(to: CGPoint(x: center + 5, y: 13))
            context.addLine(to: CGPoint(x: center, y: 20)); context.closePath(); context.fillPath()
            if marker.times.count > 1 {
                let count = String(marker.times.count) as NSString
                let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 10), .foregroundColor: UIColor.black]
                let size = count.size(withAttributes: attributes)
                let plate = CGRect(x: center - size.width / 2 - 3, y: 0, width: size.width + 6, height: 14)
                context.fill(plate); count.draw(at: CGPoint(x: plate.minX + 3, y: 0), withAttributes: attributes)
            }
            context.restoreGState()
        }
        for marker in addSites {
            let c = CGPoint(x: marker.frame.midX, y: marker.frame.midY)
            let circle = CGRect(x: c.x - 12, y: c.y - 12, width: 24, height: 24)
            context.setFillColor(UIColor(white: 0.17, alpha: 1).cgColor); context.fillEllipse(in: circle)
            context.setStrokeColor(UIColor(white: 0.55, alpha: 1).cgColor); context.setLineWidth(1); context.strokeEllipse(in: circle)
            context.setStrokeColor(UIColor.white.cgColor); context.setLineWidth(1.6); context.setLineCap(.round)
            context.move(to: CGPoint(x: c.x - 5, y: c.y)); context.addLine(to: CGPoint(x: c.x + 5, y: c.y))
            context.move(to: CGPoint(x: c.x, y: c.y - 5)); context.addLine(to: CGPoint(x: c.x, y: c.y + 5)); context.strokePath()
        }
    }
}

func editorTime(_ seconds: Double) -> String {
    let frames = Int((max(0, seconds.isFinite ? seconds : 0) * 30).rounded())
    return String(format: "%d:%02d.%02d", frames / 1800, frames / 30 % 60, Int((Double(frames % 30) / 30 * 100).rounded()))
}

/// Editor labels normally round to a video frame. Keep subframe cuts distinct
/// when two of them would have the same label in the nearby-boundaries list.
func moveBoundaryLabel(_ time: EditTime, among neighbors: [EditTime]) -> String {
    let label = editorTime(time.seconds)
    let ticksPerFrame = EditTime.scale / 30
    let frame = (time.ticks + ticksPerFrame / 2) / ticksPerFrame
    guard neighbors.contains(where: { $0 != time && ($0.ticks + ticksPerFrame / 2) / ticksPerFrame == frame }) else { return label }
    let minutes = time.ticks / (60 * EditTime.scale)
    let seconds = Double(time.ticks % (60 * EditTime.scale)) / Double(EditTime.scale)
    return String(format: "%lld:%09.6f", minutes, seconds)
}

/// Preserve touch-down in the surface coordinate system. UIPan translation can
/// omit recognition slop, and its view is a scrolling content container.
private final class TimelineEditPanRecognizer: UIPanGestureRecognizer {
    private(set) var touchDown: CGPoint?
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if touchDown == nil, let touch = touches.first { touchDown = touch.location(in: view?.superview) }
        super.touchesBegan(touches, with: event)
    }
    override func reset() { super.reset(); touchDown = nil }
}

private final class TimelineItemAccessibilityElement: UIAccessibilityElement {
    var activate: () -> Bool = { false }
    override func accessibilityActivate() -> Bool { activate() }
}
