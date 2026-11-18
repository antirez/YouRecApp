import SwiftUI
import UIKit
import AVFoundation
#if targetEnvironment(macCatalyst)
import AppKit
#endif

let moveDestinationHint = "Choose a time on the timeline. Your selection will start there."

#if targetEnvironment(macCatalyst)
let timelineRulerHeight: CGFloat = 36
#else
let timelineRulerHeight: CGFloat = 20
#endif

private func editorViewport(width: CGFloat, duration: Double, requestedScale: Double) -> TimelineViewport {
    #if targetEnvironment(macCatalyst)
    return TimelineViewport(width: width, duration: duration, requestedScale: requestedScale, centersPlayhead: false)
    #else
    return TimelineViewport(width: width, duration: duration, requestedScale: requestedScale)
    #endif
}

struct EditorTimeline: UIViewRepresentable {
    let edit: EditState
    let sources: [SourceMedia]
    var folder: URL? = nil
    let waves: [UUID: SourceWaveform]
    var processedWaves: [String: SourceWaveform] = [:]
    var processedRegions: [String: URL] = [:]
    let thumbnails: [UUID: [SourceThumbnail]]
    var filmstripCanvas: CGSize?
    var filmstripItem: AVPlayerItem?
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
    var effectRange: EffectRangeEdit?
    var changeEffectEdge: (EditorRangeTiming.Edge, Double) -> Void = { _, _ in }
    var boundaryChoices: [EditTime]?
    var pickBoundary: ([EditTime]) -> Void = { _ in }
    var laneAreaHeight: Double = 144
    var portraitLaneSizing = false
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
    var playing = false
    var blade: ((Double, TimelineLane) -> Void)?
    #if targetEnvironment(macCatalyst)
    var bladeLayout: TimelineLayout?
    #endif
    var hideFromAccessibility = false
    func makeUIView(context: Context) -> TimelineSurface { TimelineSurface() }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: TimelineSurface, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let height = min(proposal.height ?? .infinity, timelineRulerHeight + laneAreaHeight)
        #if targetEnvironment(macCatalyst)
        return CGSize(width: width, height: height)
        #else
        return CGSize(width: width, height: min(height, timelineRulerHeight + uiView.laneHeight(for: self)))
        #endif
    }
    func updateUIView(_ view: TimelineSurface, context: Context) { view.accessibilityElementsHidden = hideFromAccessibility; view.configure(self) }
}

private struct LaneGeometry {
    let heights: [CGFloat]
    init(_ model: EditorTimeline, lanes: [TimelineLane]) {
        let count = (lanes.map(\.row).max() ?? 1) + 1
        let area = model.portraitLaneSizing ? min(model.laneAreaHeight, max(144, Double(count) * 36)) : model.laneAreaHeight
        // The usual two-picture/two-sound overlap fits without hiding a lane.
        let pitch = max(36, min(46, area / CGFloat(count)))
        var result = [CGFloat](repeating: pitch, count: count)
        // Use spare room for larger video thumbnails regardless of selection. A tap,
        // range or multi-selection must not resize rows or move other hit targets.
        // Divide spare space evenly; crowded timelines retain the pitch/scrolling.
        let videoRows = Set(lanes.filter { !$0.audio }.map(\.row))
        let spare = max(0, area - CGFloat(count) * pitch)
        let extra = min(82 - pitch, spare / CGFloat(max(1, videoRows.count)))
        for row in videoRows { result[row] += extra }
        heights = result
    }
    var total: CGFloat { heights.reduce(0, +) }
    func top(_ row: Int) -> CGFloat { heights.prefix(row).reduce(0, +) }
    func height(_ row: Int) -> CGFloat { heights.indices.contains(row) ? heights[row] : 46 }
    func row(at y: CGFloat) -> Int { heights.indices.first { y < top($0) + heights[$0] } ?? heights.count }
}

private func laneCard(_ lane: TimelineLane, edges: TimelineLinkLayout.Edges, layout: LaneGeometry,
                      viewport: TimelineViewport, offset: CGPoint, width: CGFloat) -> CGRect {
    // Bound offscreen coordinates; keep the outside rounding safely beyond the viewport.
    let left = max(-6, viewport.x(lane.interval.start.seconds, offset: offset.x) + (edges.previous == nil ? 1.5 : 0))
    let right = min(width + 6, viewport.x(lane.interval.end.seconds, offset: offset.x) - (edges.next == nil ? 1.5 : 0))
    // The link seam occupies the gutter. Connecting a pair must not resize
    // the waveform, its selection target or the image inside the card.
    let inset: CGFloat = 2
    return CGRect(x: left, y: layout.top(lane.row) + timelineRulerHeight - offset.y + inset,
                  width: max(1, right - left), height: layout.height(lane.row) - inset)
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
                               addSites: [(site: VideoInsertionSite, frame: CGRect)], joins: [TransitionJoin],
                               lanes: [TimelineLane], layout: LaneGeometry) -> [TimelineTransitionMarker] {
    guard !model.moving else { return [] }
    let viewport = editorViewport(width: width, duration: model.viewportDuration, requestedScale: model.pointsPerSecond)
    return joins.compactMap { join in
        guard join.transition != nil else { return nil }
        let ids = [join.outgoingID, join.incomingID].compactMap { $0 }
        let rows = Set(lanes.filter { !$0.audio && ids.contains($0.id) }.map(\.row)).sorted()
        guard let row = rows.first else { return nil }
        let x = viewport.x(join.time, offset: offset.x)
        let y = layout.top(row) + timelineRulerHeight - offset.y
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
        let lines = rows.map { CGRect(x: a, y: layout.top($0) + timelineRulerHeight - offset.y + layout.height($0) - 3, width: max(1, b - a), height: 2) }
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
        let choices = [("Whole project",editorViewport(width: width, duration: duration, requestedScale: scale).minimumScale),
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
    private let rangeBand = UIView()
    private let rangeStart = EffectRangeHandle(start: true), rangeEnd = EffectRangeHandle(start: false)
    private var rangeDrag: (edge: EditorRangeTiming.Edge, time: Double, offset: CGFloat)?
    private var rangeFinger: CGFloat = 0, rangeDelta: CGFloat = 0
    private var rangeTimer: Timer?
    private let overflow = UIButton(type: .system)
    private let span = TimelineSpanButton()
    private var fittingScrub = false
    private var detailTask: Task<Void, Never>?
    private var detailKeys: [String] = []
    #if targetEnvironment(macCatalyst)
    private var lastViewport: TimelineViewport?
    private var followPlayback = true
    private var timelineDragOrigin: CGFloat?
    private lazy var rulerScrub = UILongPressGestureRecognizer(target: self, action: #selector(scrubRuler(_:)))
    private var rulerPress: (x: CGFloat, dragged: Bool)?
    private var wheelObservation: AnyObject?
    private var wheelAnchor: (time: Double, x: CGFloat, scale: Double)?
    private var hoverPoint: CGPoint?
    private var ownsBladeCursor = false
    private let cutGuide = BladeCutGuide()
    private static let bladeCursor: NSCursor = {
        let hinge = CGPoint(x: 12, y: 12)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 26)).image { _ in
            let scissors = UIBezierPath()
            for side: CGFloat in [-1, 1] {
                scissors.move(to: CGPoint(x: hinge.x + side * 6.5, y: 2.5))
                scissors.addLine(to: hinge)
                scissors.addLine(to: CGPoint(x: hinge.x - side * 4.5, y: 16.8))
                scissors.append(UIBezierPath(ovalIn: CGRect(x: hinge.x - side * 6.5 - 3.4, y: 16.6, width: 6.8, height: 6.8)))
            }
            scissors.lineCapStyle = .round
            scissors.lineJoinStyle = .round
            UIColor.black.setStroke(); scissors.lineWidth = 3.8; scissors.stroke()
            UIColor.white.setStroke(); scissors.lineWidth = 1.8; scissors.stroke()
        }
        return NSCursor(image: image, hotSpot: hinge)
    }()
    private lazy var rulerElement = UIAccessibilityElement(accessibilityContainer: self)
    #endif
    private var previousSelection = Set<UUID>()
    private var accessibleItems: [UUID: TimelineItemAccessibilityElement] = [:]
    private var accessibleTransitions: [Int: TimelineItemAccessibilityElement] = [:]
    private var accessibleBoundaries: [EditTime: TimelineItemAccessibilityElement] = [:]
    private var accessibleAddSites: [VideoInsertionSite: TimelineItemAccessibilityElement] = [:]
    private var videoCoverage: [EditInterval] = []
    private var laneTimeline: TrackTimeline?
    private var movingLanes: TimelineSelection?
    private var hitLanes: [TimelineLane] = []
    private var hitGeometry: LaneGeometry?
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
    private var viewport: TimelineViewport { editorViewport(width: bounds.width, duration: model?.viewportDuration ?? 0, requestedScale: model?.pointsPerSecond ?? 60) }
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
        rangeBand.isUserInteractionEnabled = false; rangeBand.layer.borderWidth = 2; addSubview(rangeBand)
        for handle in [rangeStart, rangeEnd] {
            addSubview(handle)
            let edge = handle.start ? EditorRangeTiming.Edge.start : .end
            handle.activateEdge = { [weak self] in self?.revealEffectEdge(edge) }
            handle.nudge = { [weak self] delta in
                guard let self, let model, let trim = model.effectRange else { return }
                revealEffectEdge(edge)
                model.changeEffectEdge(edge, trim.timing.boundary(edge) + delta)
            }
            handle.addGestureRecognizer(TimelineEditPanRecognizer(target: self, action: #selector(effectEdgeDragged(_:))))
            handle.isHidden = true
        }
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
        #if targetEnvironment(macCatalyst)
        insertSubview(cutGuide, aboveSubview: drawing)
        cutGuide.isUserInteractionEnabled = false
        cutGuide.isOpaque = false
        cutGuide.isHidden = true
        scroll.panGestureRecognizer.allowedScrollTypesMask = .all
        rulerScrub.minimumPressDuration = 0
        rulerScrub.delegate = self
        scroll.addGestureRecognizer(rulerScrub)
        for recognizer in [tap, hold, editPan, scroll.panGestureRecognizer] { recognizer.require(toFail: rulerScrub) }
        tap.require(toFail: editPan)
        scroll.addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
        rulerElement.accessibilityLabel = "Time ruler"
        rulerElement.accessibilityIdentifier = "timeline.ruler"
        rulerElement.accessibilityHint = "Click to seek or drag to scrub the preview. Use the mouse wheel to zoom."
        #endif
        scroll.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:))))
        isAccessibilityElement = false
        drawing.isAccessibilityElement = true; drawing.accessibilityLabel = "Video and audio timeline"; drawing.accessibilityIdentifier = "editor.timeline"; drawing.accessibilityTraits = [.adjustable]
        drawing.adjust = { [weak self] in self?.adjust($0) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { rangeTimer?.invalidate(); edgeTimer?.invalidate(); gainTimer?.invalidate(); detailTask?.cancel() }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        #if targetEnvironment(macCatalyst)
        wheelObservation = window == nil ? nil : DesktopProjectLibrary.nativeServices?.observeWheel { [weak self] fraction, delta in
            guard let self, let window, window.isKeyWindow else { return false }
            let p = CGPoint(x: fraction.x * window.bounds.width, y: fraction.y * window.bounds.height)
            guard window.hitTest(p, with: nil)?.isDescendant(of: scroll) == true else { return false }
            return zoomWheel(at: convert(p, from: window).x, delta: delta)
        }
        #endif
        if window == nil {
            rangeTimer?.invalidate(); rangeTimer = nil; rangeDrag = nil
            finishGain(apply: false)
            drawing.resetFilmstrip()
            #if targetEnvironment(macCatalyst)
            endRulerScrub()
            hoverPoint = nil
            updateBladeCursor()
            #endif
        }
    }
    override func layoutSubviews() { super.layoutSubviews(); scroll.frame = bounds; drawing.frame = bounds; if let model { configure(model) } }
    private func prepareLanes(_ value: EditorTimeline) {
        let moving = value.moving ? value.selected : nil
        if laneTimeline != value.edit.timeline || movingLanes != moving {
            laneTimeline = value.edit.timeline; movingLanes = moving
            hitLanes = timelineLanes(value.edit.timeline, moving: moving)
            drawing.lanes = hitLanes
            drawing.links = TimelineLinkLayout(lanes: hitLanes, links: value.edit.timeline.links)
        }
    }
    func laneHeight(for value: EditorTimeline) -> CGFloat {
        prepareLanes(value)
        return LaneGeometry(value, lanes: hitLanes).total
    }
    func configure(_ value: EditorTimeline) {
        if gain != nil, model?.gainIdentity != value.gainIdentity || !value.gainEnabled || value.moving {finishGain(apply:false)}
        if model?.edit.timeline.video != value.edit.timeline.video || model?.edit.timeline.generated != value.edit.timeline.generated {
            videoCoverage = value.edit.timeline.videoCoverage
        }
        #if targetEnvironment(macCatalyst)
        let previous = model
        let oldOffset = scroll.contentOffset.x
        #endif
        if model?.folder != value.folder { drawing.resetFilmstrip() }
        if model?.edit != value.edit || model?.folder != value.folder {
            drawing.updateFilmstripPlan(value.edit)
        }
        prepareLanes(value)
        if value.effectRange == nil { rangeTimer?.invalidate(); rangeTimer = nil; rangeDrag = nil }
        model = value
        drawing.setFilmstripItem(value.filmstripItem, canvas: value.filmstripCanvas)
        span.frame = CGRect(x:max(0,bounds.width-48),y:timelineRulerHeight+2,width:44,height:44)
        span.configure(width:bounds.width,duration:value.viewportDuration,scale:value.pointsPerSecond,select:value.zoom)
        let view = viewport, lanes = hitLanes
        hitGeometry = LaneGeometry(value, lanes: lanes)
        programmatic = true
        scroll.contentSize = CGSize(width: max(view.contentWidth, value.edit.duration * view.scale + 2 * view.inset), height: max(bounds.height, (hitGeometry?.total ?? 0) + timelineRulerHeight))
        #if targetEnvironment(macCatalyst)
        if !scroll.isDragging && !scroll.isDecelerating && timelineDragOrigin == nil && rulerPress == nil && drag == nil && gain == nil && value.effectRange == nil {
            let changedTime = previous?.playhead != value.playhead
            let started = value.playing && previous?.playing != true
            if started || (changedTime && !value.playing) { followPlayback = true }
            var target = oldOffset
            if let old = lastViewport, old.width > 0, (old.scale != view.scale || old.width != view.width) {
                let x = old.x(value.playhead, offset: oldOffset)
                let anchor = (0...old.width).contains(x) ? value.playhead : old.time(old.width / 2, offset: oldOffset)
                let fraction = (0...old.width).contains(x) ? x / old.width : 0.5
                if let wheelAnchor, abs(view.scale - wheelAnchor.scale) < 0.0001 {
                    target = view.x(wheelAnchor.time, offset: 0) - wheelAnchor.x
                    self.wheelAnchor = nil
                } else { target = view.x(anchor, offset: 0) - fraction * view.width }
            } else if followPlayback && (changedTime || started) {
                let x = view.x(value.playhead, offset: oldOffset)
                if x < 0 || x > bounds.width {
                    target = view.x(value.playhead, offset: 0) - TimelineViewport.edgeInset
                }
            }
            scroll.contentOffset.x = boundedOffset(target)
        }
        lastViewport = view
        #else
        if !scroll.isDragging && !scroll.isDecelerating && drag == nil && gain == nil && value.effectRange == nil {
            scroll.contentOffset.x = view.fits ? 0 : value.playhead * view.scale
        }
        #endif
        if value.selection == nil, value.selected.ids != previousSelection, !value.selected.isEmpty, !value.moving, gain == nil,
           let lane = lanes.first(where: { value.selected.ids.contains($0.id) }) {
            let layout = LaneGeometry(value, lanes: lanes)
            let top = layout.top(lane.row), bottom = top + layout.height(lane.row)
            if top < scroll.contentOffset.y { scroll.contentOffset.y = top }
            else if bottom > scroll.contentOffset.y + bounds.height - timelineRulerHeight { scroll.contentOffset.y = bottom - bounds.height + timelineRulerHeight }
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
        #if targetEnvironment(macCatalyst)
        if !value.moving {
            drawing.accessibilityHint = value.blade != nil ? "Click a clip to split at the pointer. Press A to select." : "Click a clip to select. Press B for the blade. Drag the ruler to scrub the preview. Drag the filmstrip to scroll. Use the mouse wheel to zoom."
        }
        #else
        if value.blade != nil { drawing.accessibilityHint = "Tap a clip to split it. Choose Select to return to selection." }
        #endif
        drawing.accessibilityCustomActions = value.moving ? [] : lanes.flatMap { item in
            [UIAccessibilityCustomAction(name: "Select \(item.audio ? "audio" : "video") \(item.number)") { _ in value.select(item.id); return true },
             UIAccessibilityCustomAction(name: "\(value.selected.ids.contains(item.id) ? "Remove" : "Add") \(item.audio ? "audio" : "video") \(item.number) \(value.selected.ids.contains(item.id) ? "from" : "to") selection") { _ in value.toggleSelection(item.id); return true }]
        }
        redraw(); showGain()
    }
    private func redraw() {
        let layout = hitGeometry
        let hidden = layout.map { l in l.heights.indices.filter { l.top($0) + l.height($0) + timelineRulerHeight > bounds.height + scroll.contentOffset.y }.count } ?? 0
        overflow.isHidden = scroll.contentSize.height <= bounds.height + 1
        overflow.setTitle(hidden > 0 ? "⌄ +\(hidden) lanes" : "⌃ Top lanes", for: .normal)
        overflow.frame = CGRect(x: max(0, bounds.width - 108), y: bounds.height - 30, width: 104, height: 30)
        drawing.boundaryMarkers = MoveBoundaryMarker.visible(model?.boundaryChoices ?? [], viewport: viewport, offset: scroll.contentOffset.x, width: bounds.width)
        drawing.addSites = insertionMarkers(layout: layout)
        if let model, let layout, !drawing.joins.isEmpty {
            drawing.markers = transitionMarkers(model, width: bounds.width, offset: scroll.contentOffset, addSites: drawing.addSites,
                                               joins: drawing.joins, lanes: hitLanes, layout: layout)
        } else { drawing.markers = [] }
        requestDetail()
        drawing.model = model; drawing.offset = scroll.contentOffset; drawing.drag = drag.map { ($0.id, $0.left, dragDelta) }; drawing.refreshFilmstrip()
        layoutEffectHandles()
        updateAccessibleItems()
        #if targetEnvironment(macCatalyst)
        updateBladeCursor()
        #endif
    }
    private func insertionMarkers(layout: LaneGeometry?) -> [(site: VideoInsertionSite, frame: CGRect)] {
        guard let model, model.blade == nil, model.addVideo != nil, !model.moving, gain == nil, drag == nil, let layout, bounds.width >= 44 else { return [] }
        let lane = CGRect(x: 0, y: timelineRulerHeight - scroll.contentOffset.y, width: bounds.width, height: layout.height(0))
            .intersection(CGRect(x: 0, y: timelineRulerHeight, width: bounds.width, height: max(0, bounds.height - timelineRulerHeight)))
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
        if model.effectRange != nil { accessibilityElements = [rangeStart, rangeEnd, span]; return }
        var elements: [Any] = [drawing]
        #if targetEnvironment(macCatalyst)
        let leftTime = viewport.time(0, offset: scroll.contentOffset.x)
        let rightTime = viewport.time(bounds.width, offset: scroll.contentOffset.x)
        rulerElement.accessibilityValue = editorTime(leftTime) + " to " + editorTime(rightTime)
        rulerElement.accessibilityFrameInContainerSpace = CGRect(x: 0, y: 0, width: bounds.width, height: timelineRulerHeight)
        elements.append(rulerElement)
        #endif
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
        guard let layout = hitGeometry else { return }
        let lanes = hitLanes, viewport = viewport
        let visible = CGRect(x: 0, y: timelineRulerHeight, width: bounds.width, height: max(0, bounds.height - timelineRulerHeight))
        let ids = Set(lanes.map(\.id)); accessibleItems = accessibleItems.filter { ids.contains($0.key) }
        for lane in lanes {
            let edges = drawing.links.edges[lane.id] ?? .init()
            let card = laneCard(lane, edges: edges, layout: layout, viewport: viewport, offset: scroll.contentOffset,
                                width: bounds.width).intersection(visible)
            guard !card.isNull, card.width >= 1, card.height >= 1 else { continue }
            let item = accessibleItems[lane.id] ?? TimelineItemAccessibilityElement(accessibilityContainer: self)
            accessibleItems[lane.id] = item
            item.accessibilityIdentifier = "timeline.\(lane.audio ? "audio" : "video").\(lane.number)"
            let name = lane.audio ? model.sources.first(where: { $0.id == lane.source })?.originalName : nil
            item.accessibilityLabel = "\(lane.audio ? "Audio" : "Video") \(lane.number)" + (name.map { " · " + $0 } ?? "")
            if edges.memberCount > 1 {
                item.accessibilityLabel = (item.accessibilityLabel ?? "") + ", linked group of \(edges.memberCount) parts"
            }
            if model.blade != nil {
                item.accessibilityHint = "Place the playhead inside this clip, then double-tap to split it."
            } else {
                item.accessibilityHint = lane.audio ? "Swipe up or down to change volume in half-decibel steps. Long-press to add to selection." : "Tap to select. Long-press to add to selection."
            }
            item.accessibilityValue = String(format: "%.3f to %.3f seconds", lane.contentInterval.start.seconds, lane.contentInterval.end.seconds)
            item.accessibilityFrameInContainerSpace = card
            item.accessibilityTraits = model.selected.ids.contains(lane.id) ? [.button, .selected] : [.button]
            item.activate = {
                guard !model.moving else { return false }
                if let blade = model.blade {
                    let time = TimelineEditing.quantize(model.playhead)
                    guard lane.interval.start < EditTime(time), EditTime(time) < lane.interval.end else { return false }
                    blade(time, lane)
                } else { model.select(lane.id) }
                return true
            }
            elements.append(item)
        }
        let markers = drawing.markers
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
    private func layoutEffectHandles() {
        guard let model, let edit = model.effectRange else {
            rangeStart.isHidden = true; rangeEnd.isHidden = true; rangeBand.isHidden = true
            return
        }
        let visible = edit.timing.range
        let left = viewport.x(visible.lowerBound, offset: scroll.contentOffset.x)
        let right = viewport.x(visible.upperBound, offset: scroll.contentOffset.x)
        let row = hitLanes.first { $0.id == edit.region.clipID }?.row ?? 0
        let y = max(timelineRulerHeight, min(bounds.height - 44, timelineRulerHeight + (hitGeometry?.top(row) ?? 0) - scroll.contentOffset.y))
        let h = max(44, min((hitGeometry?.height(row) ?? 60), bounds.height - y))
        let tint = UIColor(edit.region.tool.tint)
        let low = max(0, left), high = min(bounds.width, right)
        rangeBand.isHidden = high <= low
        rangeBand.frame = CGRect(x: low, y: y + 2, width: max(0, high - low), height: h - 4)
        rangeBand.layer.borderColor = tint.cgColor
        rangeBand.backgroundColor = tint.withAlphaComponent(0.12)
        for handle in [rangeStart, rangeEnd] {
            let start = handle === rangeStart
            let x = start ? left : right
            // The two grab areas extend away from a short interval. If both are
            // at a screen edge, stagger them vertically so each remains reachable.
            let outside = x < 0 || x > bounds.width
            let margin = min(22, bounds.width / 2)
            let cx = min(bounds.width - margin, max(margin, x + (start ? -1 : 1) * min(17, max(0, (50 - (right-left)) / 2))))
            var cy = y + h / 2
            if right < 22 || left > bounds.width - 22 || (right - left < 55 && (left < 32 || right > bounds.width - 32)) {
                cy = start ? y + 12 : y + h - 12
            }
            handle.frame = CGRect(x: cx - margin, y: cy - 22, width: 2 * margin, height: 44)
            handle.update(tint: tint, offset: x - cx, outside: outside ? (x < 0 ? -1 : 1) : 0,
                          value: editorTime(edit.timing.boundary(start ? .start : .end)))
            handle.isHidden = false
        }
    }

    private func revealEffectEdge(_ edge: EditorRangeTiming.Edge) {
        guard let model, let edit = model.effectRange else { return }
        let time = edit.timing.boundary(edge)
        let x = viewport.x(time, offset: scroll.contentOffset.x)
        if x < 22 || x > bounds.width - 22 {
            let target = viewport.x(time, offset: 0) - bounds.width / 2
            scroll.setContentOffset(CGPoint(x: min(max(0, target), max(0, scroll.contentSize.width - bounds.width)), y: scroll.contentOffset.y), animated: false)
        }
        model.changeEffectEdge(edge, time)
    }

    @objc private func effectEdgeDragged(_ recognizer: TimelineEditPanRecognizer) {
        guard let model, let edit = model.effectRange, let handle = recognizer.view as? EffectRangeHandle else { return }
        let edge = handle.start ? EditorRangeTiming.Edge.start : .end
        if recognizer.state == .began {
            revealEffectEdge(edge)
            rangeDrag = (edge, edit.timing.boundary(edge), scroll.contentOffset.x)
            rangeTimer?.invalidate()
            rangeTimer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in self?.scrollEffectEdge() }
        }
        if [.began, .changed, .ended].contains(recognizer.state) {
            rangeFinger = recognizer.location(in: self).x
            rangeDelta = recognizer.touchDown.map { rangeFinger - $0.x } ?? recognizer.translation(in: self).x
            updateEffectEdge()
        }
        if [.ended, .cancelled, .failed].contains(recognizer.state) {
            rangeTimer?.invalidate(); rangeTimer = nil
            if recognizer.state == .cancelled, let drag = rangeDrag { model.changeEffectEdge(drag.edge, drag.time) }
            rangeDrag = nil
        }
    }
    private func updateEffectEdge() {
        guard let model, let drag = rangeDrag else { return }
        let input = drag.time + (rangeDelta + scroll.contentOffset.x - drag.offset) / viewport.scale
        let snapped = model.snapEnabled ? model.edit.timeline.snapTarget(input, scale: viewport.scale) : nil
        model.changeEffectEdge(drag.edge, snapped ?? TimelineEditing.quantize(input))
    }
    private func scrollEffectEdge() {
        guard rangeDrag != nil, abs(rangeDelta) > 4, !viewport.fits else { return }
        let distance = rangeFinger < 24 ? rangeFinger - 24 : max(0, rangeFinger - (bounds.width - 24))
        guard distance != 0 else { return }
        let x = min(max(0, scroll.contentOffset.x + max(-12, min(12, distance / 2))), max(0, scroll.contentSize.width - bounds.width))
        guard x != scroll.contentOffset.x else { return }
        scroll.contentOffset.x = x
        updateEffectEdge()
    }

    private func requestDetail() {
        guard let model, let folder = model.folder, viewport.scale >= 100 else {
            detailTask?.cancel(); detailKeys = []; drawing.details = [:]; return
        }
        let visibleStart = viewport.time(0, offset: scroll.contentOffset.x)
        let visibleEnd = viewport.time(bounds.width, offset: scroll.contentOffset.x)
        var requests: [(String, UUID, URL, Int)] = []
        for lane in hitLanes where lane.audio {
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
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        finishScrubbing(); scrollStart = scroll.contentOffset
        #if targetEnvironment(macCatalyst)
        followPlayback = false
        #endif
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        redraw()
        #if !targetEnvironment(macCatalyst)
        guard !programmatic, !pinching, drag == nil, gain == nil, scroll.isDragging || scroll.isDecelerating, let model, model.effectRange == nil, !viewport.fits else { return }
        if !horizontalScrub {
            guard abs(scroll.contentOffset.x - scrollStart.x) > 1, abs(scroll.contentOffset.x - scrollStart.x) >= abs(scroll.contentOffset.y - scrollStart.y) else { return }
            horizontalScrub = true; model.scrubbing(true)
        }
        model.seek(scroll.contentOffset.x / viewport.scale)
        #endif
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
        guard point.y >= timelineRulerHeight else { return nil }
        let position = point.x + scroll.contentOffset.x - viewport.inset
        guard position >= 0, position < viewport.duration * viewport.scale else { return nil }
        let time = EditTime(viewport.time(point.x, offset: scroll.contentOffset.x))
        guard let row = hitGeometry?.row(at: point.y + scroll.contentOffset.y - timelineRulerHeight) else { return nil }
        return hitLanes.first { $0.row == row && $0.interval.contains(time) }
    }
    private func transition(at point: CGPoint) -> TimelineTransitionMarker? {
        guard point.y >= timelineRulerHeight else { return nil }
        return drawing.markers
            .filter { $0.hitFrame.contains(point) }
            .min { abs($0.frame.midX - point.x) < abs($1.frame.midX - point.x) }
    }
    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard let model, model.effectRange == nil, !model.moving || model.boundaryChoices != nil else { return }
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
        if point.y < timelineRulerHeight {
            if let target = rulerClickTarget(time, model: model) { model.seek(target) }
            else { model.bookmarks() }
        } else if let blade = model.blade {
            if let lane = item(at: point) { blade(TimelineEditing.quantize(time), lane) }
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
    /// A click on overlapping bookmark markers opens their chooser.
    private func rulerClickTarget(_ time: Double, model: EditorTimeline) -> Double? {
        let marks = model.edit.timeline.resolvedBookmarks.filter { abs($0.time.seconds - time) * viewport.scale < 10 }
        guard marks.count < 2 else { return nil }
        return marks.first?.time.seconds ?? (model.snapEnabled ? model.edit.timeline.snap(time, scale: viewport.scale) : time)
    }
    @objc private func held(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let model, model.effectRange == nil, model.blade == nil, !model.moving, !scroll.isDecelerating else { return }
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
        guard let model, model.effectRange == nil, model.blade == nil else { return nil }
        if drawing.addSites.contains(where: { $0.frame.contains(point) }) { return nil }
        if model.boundaryChoices != nil { return nil }
        if model.moving, let lane = item(at: point), model.selected.ids.contains(lane.id) { return (lane.id, nil) }
        guard !model.moving, model.selection == nil, model.selected.video.count <= 1,
              model.selected.audio.count <= 1, point.y >= timelineRulerHeight, transition(at: point) == nil else { return nil }
        guard let geometry = hitGeometry else { return nil }
        let laneY = point.y + scroll.contentOffset.y - timelineRulerHeight
        let row = geometry.row(at: laneY)
        guard geometry.heights.indices.contains(row), abs(laneY - geometry.top(row) - geometry.height(row) / 2) <= 22 else { return nil }
        for lane in hitLanes where lane.row == row && model.selected.ids.contains(lane.id) {
            let left = viewport.x(lane.interval.start.seconds, offset: scroll.contentOffset.x), right = viewport.x(lane.interval.end.seconds, offset: scroll.contentOffset.x)
            guard right - left >= 44 else { continue }
            let leftDistance = lane.trimsLeft && left >= 0 && left < bounds.width ? abs(point.x - left) : .infinity
            let rightDistance = lane.trimsRight && right > 0 && right <= bounds.width ? abs(point.x - right) : .infinity
            if min(leftDistance, rightDistance) <= 22 { return (lane.id, leftDistance <= rightDistance) }
        }
        return nil
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        #if targetEnvironment(macCatalyst)
        if gestureRecognizer === rulerScrub {
            guard let model, !model.moving, model.boundaryChoices == nil, model.effectRange == nil else { return false }
            return touch.location(in: self).y < timelineRulerHeight
        }
        #endif
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
        #if targetEnvironment(macCatalyst)
        if scrollsTimeline(from: editPan.touchDown ?? editPan.location(in: self)) {
            return abs(velocity.x) > abs(velocity.y)
        }
        if model?.blade != nil { return false }
        #endif
        if model?.effectRange != nil { return false }
        return abs(velocity.x) > abs(velocity.y) && (modelMoving ? hit(editPan.touchDown ?? gestureRecognizer.location(in: self)) != nil : viewport.fits)
    }
    private func gainScope(at point:CGPoint)->TimelineSelection? {
        guard let model,model.blade == nil,model.gainEnabled,!model.moving,!scroll.isDecelerating,
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
        #if targetEnvironment(macCatalyst)
        if gesture.state == .began && scrollsTimeline(from: touchDown) {
            timelineDragOrigin = scroll.contentOffset.x
            followPlayback = false
        }
        if let origin = timelineDragOrigin {
            scroll.contentOffset.x = boundedOffset(origin - translation)
            if [.ended, .cancelled, .failed].contains(gesture.state) { timelineDragOrigin = nil }
            return
        }
        #endif
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
    #if targetEnvironment(macCatalyst)
    @objc private func scrubRuler(_ gesture: UILongPressGestureRecognizer) {
        guard let model else { return }
        let x = min(bounds.width, max(0, gesture.location(in: self).x))
        let time = viewport.time(x, offset: scroll.contentOffset.x)
        switch gesture.state {
        case .began:
            scroll.setContentOffset(scroll.contentOffset, animated: false)
            rulerPress = (x, false)
            model.scrubbing(true)
            if let target = rulerClickTarget(time, model: model) { model.seek(target) }
        case .changed, .ended:
            guard let press = rulerPress else { return }
            if press.dragged || abs(x - press.x) >= 1 {
                rulerPress?.dragged = true
                model.seek(time)
            } else if gesture.state == .ended, rulerClickTarget(time, model: model) == nil {
                model.bookmarks()
            }
            if gesture.state == .ended { endRulerScrub() }
        case .cancelled, .failed:
            endRulerScrub()
        default: break
        }
    }
    private func endRulerScrub() {
        guard rulerPress != nil else { return }
        rulerPress = nil
        model?.scrubbing(false)
    }
    private func scrollsTimeline(from point: CGPoint) -> Bool {
        point.y < timelineRulerHeight || (!modelMoving && item(at: point)?.audio == false)
    }
    private func zoomWheel(at x: CGFloat, delta: CGFloat) -> Bool {
        guard let model, !modelMoving || model.boundaryChoices != nil else { return false }
        let scale = wheelAnchor?.scale ?? viewport.scale
        let next = max(viewport.minimumScale, min(720, scale * exp(max(-1, min(1, Double(delta) * 0.10)))))
        if next != scale {
            // Several notches can arrive before SwiftUI applies the preceding scale.
            let time = wheelAnchor.map { $0.time + (x - $0.x) / scale } ?? viewport.time(x, offset: scroll.contentOffset.x)
            wheelAnchor = (time, x, next)
            followPlayback = false
            model.zoom(next)
        }
        return true
    }
    private func boundedOffset(_ x: CGFloat) -> CGFloat {
        min(max(0, x), max(0, scroll.contentSize.width - bounds.width))
    }
    #endif
    private func adjust(_ direction: Double) { guard let model else { return }; model.seek(model.playhead + direction * max(1 / 30, 10 / viewport.scale)) }
}

#if targetEnvironment(macCatalyst)
extension TimelineSurface {
    @objc private func hovered(_ gesture: UIHoverGestureRecognizer) {
        hoverPoint = [.began, .changed].contains(gesture.state) ? gesture.location(in: self) : nil
        updateBladeCursor()
    }

    private func updateBladeCursor() {
        if let model, model.blade != nil, let point = hoverPoint, let lane = item(at: point),
           bounds.contains(point), !span.frame.contains(point), overflow.isHidden || !overflow.frame.contains(point) {
            if NSCursor.current !== Self.bladeCursor { Self.bladeCursor.set() }
            ownsBladeCursor = true
            let time = TimelineEditing.quantize(viewport.time(point.x, offset: scroll.contentOffset.x))
            let cut = EditTime(time)
            if let geometry = hitGeometry, lane.interval.start < cut, cut < lane.interval.end,
               model.bladeLayout?.transition(at: time) == nil {
                let members = model.edit.timeline.links.first { $0.members.contains(lane.id) }?.members ?? [lane.id]
                let spans = hitLanes.compactMap { target -> ClosedRange<CGFloat>? in
                    guard members.contains(target.id), target.interval.start < cut, cut < target.interval.end else { return nil }
                    let y = timelineRulerHeight + geometry.top(target.row) - scroll.contentOffset.y
                    let top = max(timelineRulerHeight, y + 2), bottom = min(bounds.height, y + geometry.height(target.row))
                    return top < bottom ? top...bottom : nil
                }
                cutGuide.show(at: viewport.x(time, offset: scroll.contentOffset.x), height: bounds.height, spans: spans)
            } else { cutGuide.isHidden = true }
        } else {
            cutGuide.isHidden = true
            guard ownsBladeCursor else { return }
            if NSCursor.current === Self.bladeCursor { NSCursor.arrow.set() }
            ownsBladeCursor = false
        }
    }
}

// Only this thin overlay moves during hover. The filmstrip and waveform stay cached.
private final class BladeCutGuide: UIView {
    private var spans: [ClosedRange<CGFloat>] = []

    func show(at x: CGFloat, height: CGFloat, spans: [ClosedRange<CGFloat>]) {
        frame = CGRect(x: x - 2, y: 0, width: 4, height: height)
        if self.spans != spans {
            self.spans = spans
            setNeedsDisplay()
        }
        isHidden = spans.isEmpty
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        for span in spans {
            for y in stride(from: span.lowerBound + 2, through: span.upperBound - 2, by: 5) {
                let dot = CGRect(x: bounds.midX - 1.6, y: y - 1.6, width: 3.2, height: 3.2)
                context.setFillColor(UIColor.black.withAlphaComponent(0.85).cgColor)
                context.fillEllipse(in: dot)
                context.setFillColor(UIColor.white.cgColor)
                context.fillEllipse(in: dot.insetBy(dx: 0.65, dy: 0.65))
            }
        }
    }
}
#endif

private final class TimelineDrawing: UIView {
    #if DEBUG
    private let traceFilmstrip = CommandLine.arguments.contains("--trace-filmstrip")
    private let interruptFirstFrameRequests = CommandLine.arguments.contains("--interrupt-filmstrip-requests")
    private var decodedFrames = 0
    private var decodedKeys = Set<String>()
    private var missingFrames = 0
    override var accessibilityValue: String? {
        get {
            guard traceFilmstrip else { return super.accessibilityValue }
            return (super.accessibilityValue ?? "") + " \(decodedKeys.count) unique filmstrip \(decodedFrames)/\(missingFrames)/\(filmGenerator == nil ? 0 : 1)"
        }
        set { super.accessibilityValue = newValue }
    }
    #endif
    private var filmAsset: AVAsset?
    private var filmComposition: AVVideoComposition?
    private weak var lastFilmAsset: AVAsset?
    private weak var lastFilmComposition: AVVideoComposition?
    private var filmGenerator: AVAssetImageGenerator?
    private var filmJob: Task<Void, Never>?
    private struct Request {
        let key: String
        let time: EditTime
    }
    private struct Format: Equatable {
        let size: CGSize?
        let primaries: String?
        let transfer: String?
        let matrix: String?
        let fps: Double
        let compositor: String?
        let direct: Bool
    }
    private var format: Format?
    private var plan = FilmstripPlan(TrackTimeline())
    private var generation = UUID()
    private var visibleFrames: [Request] = []
    private var tileRects: [String: CGRect] = [:]
    private var visibleCaptions: [String: UIImage] = [:]
    private struct FrameFailure {
        var count: Int
        var retryAt: TimeInterval
    }
    private static let retryDelays: [TimeInterval] = [0.15, 0.6, 2, 8]
    private var failures: [String: FrameFailure] = [:]
    private var retryTimer: Timer?
    private var needsViewportPass = true

    func refreshFilmstrip() {
        needsViewportPass = true
        setNeedsDisplay()
    }

    private let filmCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 192
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()
    private var origins: [UUID: EditTime] = [:]
    private var regionsByClip: [UUID: [ToolRegion]] = [:]
    private var boundariesByClip: [UUID: [Double]] = [:]
    var joins: [TransitionJoin] = []
    var markers: [TimelineTransitionMarker] = []

    func updateFilmstripPlan(_ edit: EditState) {
        // Until the replacement item is ready, an old transition or unfinished
        // analysis at the same timeline time need not describe the new edit.
        if let previous = model?.edit.timeline, previous.video != edit.timeline.video ||
            previous.transitions != edit.timeline.transitions || previous.generated != edit.timeline.generated ||
            previous.placements != edit.timeline.placements || previous.subtitles != edit.timeline.subtitles ||
            (edit.timeline.subtitles != nil && previous.audio != edit.timeline.audio) { generation = UUID() }
        plan = FilmstripPlan(edit.timeline, reusing: plan)
        origins = Dictionary(uniqueKeysWithValues: edit.timeline.video.map { ($0.id, $0.start - $0.localOrigin) })
        let layout = edit.layout
        regionsByClip = Dictionary(grouping: edit.toolRegions(in: layout), by: \.clipID)
        boundariesByClip = regionsByClip.mapValues { regions in
            Set(regions.filter { $0.tool != .placement }.flatMap { [$0.range.lowerBound, $0.range.upperBound] }).sorted()
        }
        joins = layout.joins.filter { $0.transition != nil }
    }

    func resetFilmstrip() {
        setFilmstripItem(nil, canvas: nil)
        format = nil
        lastFilmAsset = nil; lastFilmComposition = nil
        visibleCaptions.removeAll()
        generation = UUID()
        filmCache.removeAllObjects()
    }

    func setFilmstripItem(_ item: AVPlayerItem?, canvas: CGSize?) {
        let asset = item?.asset, composition = item?.videoComposition
        guard asset !== filmAsset || composition !== filmComposition else { return }
        filmJob?.cancel(); filmJob = nil
        filmGenerator?.cancelAllCGImageGeneration()
        filmAsset = asset; filmComposition = composition
        retryTimer?.invalidate(); retryTimer = nil
        failures.removeAll(); visibleFrames = []; tileRects.removeAll()
        refreshFilmstrip()
        guard let asset else { filmGenerator = nil; return }
        if lastFilmAsset !== asset || lastFilmComposition !== composition { generation = UUID() }
        lastFilmAsset = asset; lastFilmComposition = composition
        let duration = composition?.frameDuration.seconds ?? TimelineEditing.frame
        let next = Format(size: composition?.renderSize ?? canvas, primaries: composition?.colorPrimaries,
                          transfer: composition?.colorTransferFunction, matrix: composition?.colorYCbCrMatrix,
                          fps: duration.isFinite && duration > 0 ? 1 / duration : 30,
                          compositor: composition?.customVideoCompositorClass.map { NSStringFromClass($0) },
                          direct: composition == nil)
        if format != next { filmCache.removeAllObjects(); visibleCaptions.removeAll(); format = next }
        let generator = AVAssetImageGenerator(editorAsset: asset, composition: composition)
        generator.maximumSize = CGSize(width: 256, height: 256)
        filmGenerator = generator
    }

    // Retry visible frames after transient decoder errors. Scrolls and new
    // compositions drop obsolete work; damaged media gets only a bounded retry.
    private func scheduleRetry() {
        let earliest = failures.values.lazy.filter { $0.count <= Self.retryDelays.count }.map(\.retryAt).min() ?? .infinity
        guard earliest.isFinite else { retryTimer?.invalidate(); retryTimer = nil; return }
        if let retryTimer, retryTimer.fireDate.timeIntervalSinceReferenceDate <= earliest { return }
        retryTimer?.invalidate()
        let timer = Timer(fire: Date(timeIntervalSinceReferenceDate: earliest), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.retryTimer = nil
                self?.refreshFilmstrip()
            }
        }
        retryTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func requestFrames(_ requests: [Request], viewportPass: Bool) {
        if viewportPass {
            visibleFrames = requests.reversed()
            if !failures.isEmpty { failures = failures.filter { tileRects[$0.key] != nil } }
        } else {
            for request in requests where !visibleFrames.contains(where: { $0.key == request.key }) {
                visibleFrames.append(request)
            }
        }
        guard filmJob == nil, let generator = filmGenerator else { return }
        guard !visibleFrames.isEmpty else { scheduleRetry(); return }
        filmJob = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.filmGenerator === generator {
                    self.filmJob = nil
                    self.scheduleRetry()
                }
            }
            while !Task.isCancelled, let request = self.visibleFrames.popLast() {
                let key = request.key as NSString
                if self.filmCache.object(forKey: key) != nil { continue }
                if let failure = self.failures[request.key], failure.retryAt > Date.timeIntervalSinceReferenceDate { continue }
                do {
                    #if DEBUG
                    if self.interruptFirstFrameRequests && self.failures[request.key] == nil { throw CancellationError() }
                    #endif
                    let cg = try await generator.image(at: TrackRenderer.time(request.time)).image
                    guard !Task.isCancelled, self.filmGenerator === generator else { return }
                    #if DEBUG
                    if self.traceFilmstrip { self.decodedFrames += 1; self.decodedKeys.insert(request.key) }
                    #endif
                    self.failures.removeValue(forKey: request.key)
                    self.filmCache.setObject(UIImage(cgImage: cg), forKey: key, cost: cg.bytesPerRow * cg.height)
                } catch {
                    guard !Task.isCancelled, self.filmGenerator === generator else { return }
                    guard self.tileRects[request.key] != nil else { continue }
                    let attempt = (self.failures[request.key]?.count ?? 0) + 1
                    // After the automatic retries, allow a later user redraw to
                    // try again without continuously waking an idle editor.
                    let delay = attempt <= Self.retryDelays.count ? Self.retryDelays[attempt - 1] : 30
                    self.failures[request.key] = FrameFailure(count: attempt, retryAt: Date.timeIntervalSinceReferenceDate + delay)
                }
                if let rect = self.tileRects[request.key] { self.setNeedsDisplay(rect) }
            }
        }
    }

    var lanes: [TimelineLane] = []
    var links = TimelineLinkLayout(lanes: [], links: [])
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
        let view = editorViewport(width: bounds.width, duration: model.viewportDuration, requestedScale: model.pointsPerSecond)
        func x(_ time: Double) -> Double { view.x(time, offset: offset.x) }
        let start = view.time(0, offset: offset.x), end = view.time(bounds.width, offset: offset.x)
        let selected = model.selected.ids
        let fullySelectedMembers = selected.isEmpty ? Set<UUID>() : model.edit.timeline.links.reduce(into: Set<UUID>()) { result, group in
            if group.members.isSubset(of: selected) { result.formUnion(group.members) }
        }
        var neededFrames: [Request] = []
        let filmFPS = format?.fps ?? 30
        // UIKit may clip the dirty rectangle even after an edit requested a
        // full redraw. Reconcile visible demand independently of that rectangle.
        let full = needsViewportPass || rect.contains(bounds)
        needsViewportPass = false
        var nextCaptions: [String: UIImage] = [:]
        if full { tileRects.removeAll(keepingCapacity: true) }
        defer {
            if full { visibleCaptions = nextCaptions }
            requestFrames(neededFrames, viewportPass: full)
            #if DEBUG
            if traceFilmstrip { missingFrames = tileRects.keys.filter { filmCache.object(forKey: $0 as NSString) == nil }.count }
            #endif
        }
        context.saveGState(); context.clip(to: CGRect(x: 0, y: timelineRulerHeight, width: bounds.width, height: max(0, bounds.height - timelineRulerHeight)))
        let layout = LaneGeometry(model, lanes: lanes)
        let trackBottom = max(timelineRulerHeight,min(bounds.height,timelineRulerHeight + layout.total - offset.y))
        var seams: [CGPath] = []
        for lane in lanes {
            guard lane.interval.end.seconds >= start, lane.interval.start.seconds <= end else { continue }
            let regions = regionsByClip[lane.id] ?? []
            let rowHeight = layout.height(lane.row)
            let y = layout.top(lane.row) + timelineRulerHeight - offset.y
            guard y + rowHeight >= timelineRulerHeight, y <= bounds.height else { continue }
            let left = x(lane.interval.start.seconds), right = x(lane.interval.end.seconds)
            let contentLeft = x(lane.contentInterval.start.seconds)
            let edges = links.edges[lane.id] ?? .init()
            let card = laneCard(lane, edges: edges, layout: layout, viewport: view, offset: offset, width: bounds.width)
            guard full || card.insetBy(dx: -5, dy: -3).intersects(rect) else { continue }
            var corners: UIRectCorner = []
            if edges.previous == nil {
                if !edges.joinsAbove { corners.insert(.topLeft) }
                if !edges.joinsBelow { corners.insert(.bottomLeft) }
            }
            if edges.next == nil {
                if !edges.joinsAbove { corners.insert(.topRight) }
                if !edges.joinsBelow { corners.insert(.bottomRight) }
            }
            let path = UIBezierPath(roundedRect: card, byRoundingCorners: corners, cornerRadii: CGSize(width: 5, height: 5)).cgPath
            context.saveGState(); context.addPath(path); context.clip()
            context.setFillColor(UIColor(white: lane.audio ? 0.12 : 0.18, alpha: 1).cgColor); context.fill(card)
            if lane.audio, let wave = model.waves[lane.source] {
                let audio = model.edit.timeline.audio.first { $0.id == lane.id }
                let censors = audio.map { model.edit.timeline.censorSpans(for: $0) } ?? []
                let enhancements = audio?.enhancements.map { ($0.interval, TrackRenderer.audioKey(source: lane.source, effects: $0.effects)) } ?? []
                let sourceName = model.sources.first { $0.id == lane.source }?.filename ?? ""
                let originalKey = "\(lane.source):original"
                let mappingDuration = lane.mapping.duration.seconds
                // The clip badge overlays the wave; it does not reserve a label
                // row. Use the full card symmetrically, with a small edge inset.
                let half = max(1, (card.height - 6) / 2), center = card.midY
                context.setStrokeColor(UIColor.systemMint.withAlphaComponent(audio?.muted == true ? 0.25 : 0.85).cgColor); context.setLineWidth(1)
                let firstPixel = left + max(0, ceil(max(0, rect.minX - 1) - left))
                for px in stride(from: firstPixel, to: min(bounds.width, right, rect.maxX + 1), by: 1) {
                    let a = lane.mapping.source(at: EditTime(max(0, (px - contentLeft) / view.scale))) ?? 0
                    let b = lane.mapping.source(at: EditTime(min(mappingDuration, (px - contentLeft + 1) / view.scale))) ?? a
                    var runStart = 0.0
                    let local = max(0, (px - contentLeft) / view.scale)
                    let silent = lane.mapping.runs.first { run in defer { runStart += run.duration.seconds }; return local < runStart + run.duration.seconds }?.silent ?? true
                    let regionKey = enhancements.first { $0.0.contains(EditTime(local)) }?.1
                    let processed = regionKey.flatMap { model.processedRegions[$0] }
                    let filename = processed?.lastPathComponent ?? sourceName
                    let waveKey = "\(lane.source):\(filename)"
                    let enhancedWave = regionKey.flatMap { model.processedWaves[$0] }
                    let displayed = enhancedWave ?? wave
                    // A pending processed overview must not cache raw peaks under its key.
                    let overviewKey = enhancedWave == nil ? originalKey : waveKey
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
            } else if !lane.audio {
                let originals = model.thumbnails[lane.source] ?? []
                let aspect = format?.size ?? originals.first?.image.size ?? CGSize(width: 16, height: 9)
                let grid = FilmstripGrid(tileWidth: max(64, card.height * aspect.width / max(1, aspect.height)),
                                         pointsPerSecond: view.scale, fps: filmFPS)
                let origin = origins[lane.id]?.seconds ?? lane.contentInterval.start.seconds
                let first = lane.interval.start.seconds, last = lane.interval.end.seconds
                var slot = grid.slot(at: max(first, start), origin: origin)
                let effectEdges = boundariesByClip[lane.id] ?? []
                var edge = effectEdges.prefixEnd { $0 <= max(first, slot) }.endIndex
                let editDuration = view.duration
                while slot < min(last, end) {
                    let lo = max(first, slot), hi = min(last, slot + grid.step)
                    defer { slot += grid.step }
                    guard hi > lo else { continue }
                    while edge < effectEdges.count && effectEdges[edge] <= lo { edge += 1 }
                    let firstEdge = edge
                    while edge < effectEdges.count && effectEdges[edge] < hi { edge += 1 }
                    let boundaries = grid.boundaries(from: lo, to: hi, edges: effectEdges[firstEdge..<edge], pointsPerSecond: view.scale)
                    for (a, b) in zip(boundaries, boundaries.dropFirst()) where a < b && b > start && a < end {
                        let tile = x(a), next = x(b)
                        let tileRect = CGRect(x: tile, y: card.minY, width: next - tile, height: card.height).intersection(bounds)
                        guard full || tileRect.intersects(rect) else { continue }
                        let time = grid.sample(start: a, end: b, center: boundaries.count > 2, duration: editDuration)
                        let sample = plan.sample(lane: lane.id, at: time, generation: generation)
                        tileRects[sample.key] = tileRects[sample.key]?.union(tileRect) ?? tileRect
                        var image = filmCache.object(forKey: sample.key as NSString)
                        if image == nil {
                            if filmGenerator != nil && (failures[sample.key]?.retryAt ?? 0) <= Date.timeIntervalSinceReferenceDate {
                                neededFrames.append(Request(key: sample.key, time: time))
                            }
                            if let key = sample.captionPlaceholder { image = visibleCaptions[key] }
                            // A persistently unreadable composed frame can still
                            // show its own source thumbnail while retries continue.
                            if image == nil && (sample.plain || (failures[sample.key]?.count ?? 0) >= 2) {
                                let source = sample.sourceTime ?? lane.mapping.source(at: time - lane.contentInterval.start) ?? 0
                                image = originals.last { $0.time <= source }?.image ?? originals.first?.image
                            }
                        }
                        if let image {
                            if let key = sample.captionPlaceholder {
                                if full { nextCaptions[key] = image } else { visibleCaptions[key] = image }
                            }
                            let ratio = max((next - tile) / image.size.width, card.height / image.size.height)
                            let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
                            context.saveGState(); context.clip(to: CGRect(x: tile, y: card.minY, width: next - tile, height: card.height))
                            image.draw(in: CGRect(x: (tile + next - size.width) / 2, y: card.midY - size.height / 2, width: size.width, height: size.height))
                            context.restoreGState()
                        }
                    }
                }
            }
            for region in regions where !lane.audio && region.tool != .transition {
                context.setFillColor(UIColor(region.tool.tint).cgColor)
                context.fill(CGRect(x: x(region.range.lowerBound), y: card.maxY - 3, width: (region.range.upperBound - region.range.lowerBound) * view.scale, height: 3))
            }
            let linked = edges.memberCount > 1
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
            func strokeOutline(_ area: CGRect, leftOpen: Bool, rightOpen: Bool, verticalJoins: Bool,
                               color: UIColor, width: CGFloat) {
                var outline = area.insetBy(dx: width / 2, dy: width / 2)
                if leftOpen { outline.origin.x -= 3; outline.size.width += 3 }
                if rightOpen { outline.size.width += 3 }
                if verticalJoins && edges.joinsAbove { outline.origin.y -= 3; outline.size.height += 3 }
                if verticalJoins && edges.joinsBelow { outline.size.height += 3 }
                guard outline.width > 0, outline.height > 0 else { return }
                context.saveGState(); context.clip(to: area)
                context.setStrokeColor(color.cgColor); context.setLineWidth(width)
                context.addPath(UIBezierPath(roundedRect: outline, byRoundingCorners: corners, cornerRadii: CGSize(width: 4, height: 4)).cgPath)
                context.strokePath(); context.restoreGState()
            }
            if edges.outlinedGroup {
                strokeOutline(card, leftOpen: edges.previous != nil, rightOpen: edges.next != nil, verticalJoins: true,
                              color: UIColor(white: 0.90, alpha: 0.52), width: 1)
            }
            if selected.contains(lane.id) {
                let groupSelected = fullySelectedMembers.contains(lane.id)
                let leftOpen = edges.previous.map(selected.contains) ?? false
                let rightOpen = edges.next.map(selected.contains) ?? false
                if let range = model.selection {
                    // Highlight only the source/time intersection that an edit
                    // will affect. Other tracks and the rest of a clip stay plain.
                    let from = max(lane.interval.start.seconds, range.lowerBound)
                    let to = min(lane.interval.end.seconds, range.upperBound)
                    if to > from {
                        let part = card.intersection(CGRect(x: x(from), y: card.minY, width: (to - from) * view.scale, height: card.height))
                        if !part.isNull && part.width > 0 {
                            context.saveGState()
                            context.addPath(path); context.clip()
                            context.setFillColor(UIColor.systemYellow.withAlphaComponent(0.16).cgColor); context.fill(part)
                            strokeOutline(part, leftOpen: leftOpen && range.lowerBound < lane.interval.start.seconds,
                                          rightOpen: rightOpen && range.upperBound > lane.interval.end.seconds,
                                          verticalJoins: groupSelected, color: .systemYellow, width: 2)
                            context.restoreGState()
                        }
                    }
                } else {
                    strokeOutline(card, leftOpen: leftOpen, rightOpen: rightOpen, verticalJoins: groupSelected,
                                  color: .systemYellow, width: 2)
                    if !model.moving && model.selected.video.count <= 1 && model.selected.audio.count <= 1 && right - left >= 44 {
                        context.setFillColor(UIColor.systemYellow.cgColor)
                        for edge in [lane.trimsLeft ? left + 3 : nil, lane.trimsRight ? right - 6 : nil].compactMap({ $0 }) {
                            context.fill(CGRect(x: edge, y: card.midY - 10, width: 5, height: 24))
                        }
                    }
                }
            }
            if edges.previous != nil, left >= 0, left <= bounds.width {
                let seam = CGMutablePath()
                seam.move(to: CGPoint(x: left, y: card.minY + 1))
                // Keep the cut readable even over white footage or a dense waveform.
                if min(lane.interval.duration.seconds, edges.previousDuration.seconds) * view.scale >= 14 {
                    let middle = card.midY
                    for (dx, dy) in [(0, -7), (-3, -3), (3, 2), (0, 6)] {
                        seam.addLine(to: CGPoint(x: left + CGFloat(dx), y: middle + CGFloat(dy)))
                    }
                }
                seam.addLine(to: CGPoint(x: left, y: card.maxY - 1))
                seams.append(seam)
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
        for bridge in links.bridges {
            let groupLeft = x(bridge.interval.start.seconds) + 2
            let left = max(0, groupLeft)
            let right = min(bounds.width, x(bridge.interval.end.seconds) - 2)
            guard right - left >= 2 else { continue }
            let y = timelineRulerHeight + layout.top(bridge.upperRow + 1) - offset.y
            context.setFillColor(UIColor(white: 0.12, alpha: 1).cgColor)
            context.fill(CGRect(x: left, y: y, width: right - left, height: 2))
            let seam = CGMutablePath()
            seam.move(to: CGPoint(x: left, y: y))
            if groupLeft >= -7, right - groupLeft >= 28 {
                // A little stitch connects picture and sound without covering the waveform.
                for (dx, dy) in [(7, 0), (10, -2), (14, 2), (17, 0)] {
                    seam.addLine(to: CGPoint(x: groupLeft + CGFloat(dx), y: y + CGFloat(dy)))
                }
            }
            seam.addLine(to: CGPoint(x: right, y: y))
            seams.append(seam)
        }
        context.saveGState()
        context.setLineJoin(.round)
        for (width, color) in [(CGFloat(2.8), UIColor.black.withAlphaComponent(0.75)),
                                (1.1, UIColor(white: 0.89, alpha: 0.9))] {
            context.setStrokeColor(color.cgColor); context.setLineWidth(width)
            for seam in seams { context.addPath(seam) }; context.strokePath()
        }
        context.restoreGState()
        for marker in markers {
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
            let currentRows = Dictionary(uniqueKeysWithValues: lanes.map { ($0.id, $0.row) })
            for lane in timelineLanes(base) where selected.contains(lane.id) {
                // Show the original position on the item's current lane, so its
                // outline never pretends to be another video or waveform.
                let row = currentRows[lane.id] ?? lane.row
                context.stroke(CGRect(x: x(lane.interval.start.seconds), y: layout.top(row) + timelineRulerHeight + 2 - offset.y,
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
                context.move(to: CGPoint(x: x(time), y: timelineRulerHeight)); context.addLine(to: CGPoint(x: x(time), y: trackBottom))
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
        #if targetEnvironment(macCatalyst)
        let major = [0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200].first { $0 * view.scale >= 72 } ?? 14400
        let subdivisions = major == 30 || major == 60 ? 6 : 5
        let step = major / Double(subdivisions)
        let first = Int(ceil(start / step)), last = Int(floor(end / step))
        context.setFillColor(UIColor(white: 0.25, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: timelineRulerHeight - 1, width: bounds.width, height: 1))
        if first <= last {
            for i in first...last {
                let time = Double(i) * step
                let primary = i.isMultiple(of: subdivisions)
                let h: CGFloat = primary ? 11 : 5
                context.setFillColor(UIColor(white: primary ? 0.72 : 0.43, alpha: 1).cgColor)
                context.fill(CGRect(x: x(time), y: timelineRulerHeight - h, width: 1, height: h))
                if primary {
                    let label = time < 60 ? String(format: "%g", time) : String(format: "%d:%02d", Int(time.rounded()) / 60, Int(time.rounded()) % 60)
                    (label as NSString).draw(at: CGPoint(x: x(time) + 3, y: 3), withAttributes: [.font: UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: UIColor.lightGray])
                }
            }
        }
        #else
        let rulerStep = [0.1, 0.5, 1.0, 2.0, 5.0, 10.0, 30.0, 60.0, 300.0, 600.0, 1800.0, 3600.0].first { $0 * view.scale >= 44 } ?? 7200
        for time in stride(from: floor(start / rulerStep) * rulerStep, through: end, by: rulerStep) {
            let label = time < 60 ? String(format: "%g", time) : String(format: "%d:%02d", Int(time) / 60, Int(time) % 60)
            (label as NSString).draw(at: CGPoint(x: x(time) + 3, y: 2), withAttributes: [.font: UIFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium), .foregroundColor: UIColor.secondaryLabel])
        }
        #endif
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
            context.move(to: CGPoint(x: px - 4, y: timelineRulerHeight - 8)); context.addLine(to: CGPoint(x: px + 4, y: timelineRulerHeight - 8)); context.addLine(to: CGPoint(x: px, y: timelineRulerHeight - 1)); context.closePath(); context.fillPath()
            if cluster.count > 1 { ("\(cluster.count)" as NSString).draw(at: CGPoint(x: px + 4, y: timelineRulerHeight - 12), withAttributes: [.font: UIFont.systemFont(ofSize: 9, weight: .bold), .foregroundColor: UIColor.systemOrange]) }
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
                context.move(to: CGPoint(x: edge, y: timelineRulerHeight - 2)); context.addLine(to: CGPoint(x: edge, y: trackBottom))
            }
            context.strokePath(); context.setFillColor(color.cgColor)
            let center = marker.center
            context.move(to: CGPoint(x: center - 5, y: timelineRulerHeight - 7)); context.addLine(to: CGPoint(x: center + 5, y: timelineRulerHeight - 7))
            context.addLine(to: CGPoint(x: center, y: timelineRulerHeight)); context.closePath(); context.fillPath()
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

// A real control keeps mouse, touch and VoiceOver on the same boundary.
private final class EffectRangeHandle: UIControl {
    let start: Bool
    var activateEdge: (() -> Void)?
    var nudge: ((Double) -> Void)?
    private let grip = UILabel()
    init(start: Bool) {
        self.start = start
        super.init(frame: .zero)
        isAccessibilityElement = true
        accessibilityIdentifier = start ? "effect.rangeStart" : "effect.rangeEnd"
        accessibilityLabel = start ? "Effect start" : "Effect end"
        accessibilityHint = "Drag to trim, or adjust by one frame."
        accessibilityTraits = [.adjustable, .button]
        grip.textAlignment = .center; grip.font = .systemFont(ofSize: 14, weight: .bold)
        grip.textColor = .black
        grip.layer.cornerRadius = 5; grip.layer.masksToBounds = true
        grip.layer.borderWidth = 1; grip.layer.borderColor = UIColor.black.withAlphaComponent(0.75).cgColor
        addSubview(grip)
        addTarget(self, action: #selector(activateTapped), for: .touchUpInside)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(tint: UIColor, offset: CGFloat, outside: Int, value: String) {
        grip.frame = CGRect(x: min(bounds.width - 16, max(0, bounds.midX + offset - 8)), y: 7, width: 16, height: 30)
        grip.backgroundColor = tint; grip.text = outside < 0 ? "‹" : outside > 0 ? "›" : "Ⅱ"
        accessibilityValue = value
    }
    @objc private func activateTapped() { activateEdge?() }
    override func accessibilityActivate() -> Bool { activateTapped(); return true }
    override func accessibilityIncrement() { nudge?(TimelineEditing.frame) }
    override func accessibilityDecrement() { nudge?(-TimelineEditing.frame) }
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
