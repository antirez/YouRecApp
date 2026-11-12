import Foundation
import CoreGraphics
import simd

// Convert a drag on a displayed copy to a translation of the underlying source.
// The starting wedge supplies the transform for the entire gesture, even across a seam.
func kaleidoscopeDragTransform(start: CGPoint, center: CGPoint, size: CGSize,
                              angle: Double, divisions: Int, sourceAngle: Double = 0) -> CGAffineTransform {
    let undoSourceTurn = -sourceAngle * .pi / 180
    let dx = (start.x - center.x) * size.width, dy = (start.y - center.y) * size.height
    guard hypot(dx, dy) > 0.001 else { return CGAffineTransform(rotationAngle: undoSourceTurn) }
    let axis = (angle - 90) * .pi / 180, turn = 2 * Double.pi
    let span = turn / Double(divisions)
    let relative = atan2(dy, dx) - axis
    let sector = min(divisions - 1, Int(floor((relative - turn * floor(relative / turn)) / span)))
    if divisions.isMultiple(of: 2) && !sector.isMultiple(of: 2) {
        let reflection = 2 * axis + Double(sector + 1) * span + undoSourceTurn
        return CGAffineTransform(a: cos(reflection), b: sin(reflection),
                                 c: sin(reflection), d: -cos(reflection), tx: 0, ty: 0)
    }
    return CGAffineTransform(rotationAngle: -Double(sector) * span + undoSourceTurn)
}

// A source-frame EMA initialized with the oldest retained raw matte. Fixed
// per-frame coefficients follow "two-frame EMA" and "25% previous alpha";
// they do not invent a 30 Hz time constant for variable-rate footage.
enum VideoEffectMatteKind {
    case isolation,key
    var prior:Double {self == .isolation ? 1.0/3 : 0.25}
    var capacity:Int {1+Int(ceil(log(0.001)/log(prior)))}
}
struct VideoEffectTemporalWindow {
    let indices:[Int] // Oldest first; every consumer uses this same order.
    let weights:[Double]
    let tailBound:Double
    static func make(times:[Double],at time:Double,start:Double,kind:VideoEffectMatteKind,cuts:Set<Int>=[])->Self? {
        guard !times.isEmpty,time.isFinite,start.isFinite,time>=start else {return nil}
        func lowerBound(_ value:Double)->Int {
            var a=0,b=times.count
            while a<b {let m=(a+b)/2;if times[m]<value {a=m+1}else {b=m}}
            return a
        }
        // A mid-frame start acts on the frame already on screen, just like
        // Step Printing. Its floor sample belongs to the new effect's window.
        let first=max(0,lowerBound(start+0.0000001)-1),current=lowerBound(time+0.0000001)-1
        guard current>=first,current>=0 else {return nil}
        var oldest=current
        while oldest>first,current-oldest+1<kind.capacity,times[oldest]-times[oldest-1]<=0.25,!cuts.contains(oldest) {oldest-=1}
        let indices=Array(oldest...current),count=indices.count
        let weights=(0..<count).map {i in pow(kind.prior,Double(count-1-i))*(i==0 ? 1 : 1-kind.prior)}
        let truncated=oldest>first && times[oldest]-times[oldest-1]<=0.25 && !cuts.contains(oldest)
        return Self(indices:indices,weights:weights,tailBound:truncated ? weights[0] : 0)
    }
}

// Original implementation of the published Oklab equations (Björn Ottosson,
// https://bottosson.github.io/posts/oklab/). Values use linear sRGB / BT.709.
enum EffectColorMath {
    static func linear(_ x: Double) -> Double { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
    static func encoded(_ x: Double) -> Double { x <= 0.0031308 ? x * 12.92 : 1.055 * pow(max(0, x), 1 / 2.4) - 0.055 }
    static func linear(_ c: EffectRGB) -> SIMD3<Double> { SIMD3(linear(c.red), linear(c.green), linear(c.blue)) }
    static func rgb(_ c: SIMD3<Double>) -> EffectRGB { EffectRGB(min(1, max(0, encoded(c.x))), min(1, max(0, encoded(c.y))), min(1, max(0, encoded(c.z)))) }
    static func lab(_ c: SIMD3<Double>) -> SIMD3<Double> {
        let l = cbrt(0.4122214708*c.x + 0.5363325363*c.y + 0.0514459929*c.z)
        let m = cbrt(0.2119034982*c.x + 0.6806995451*c.y + 0.1073969566*c.z)
        let s = cbrt(0.0883024619*c.x + 0.2817188376*c.y + 0.6299787005*c.z)
        return SIMD3(0.2104542553*l + 0.793617785*m - 0.0040720468*s, 1.9779984951*l - 2.428592205*m + 0.4505937099*s, 0.0259040371*l + 0.7827717662*m - 0.808675766*s)
    }
    static func linearFromLab(_ c: SIMD3<Double>) -> SIMD3<Double> {
        let l = pow(c.x + 0.3963377774*c.y + 0.2158037573*c.z, 3)
        let m = pow(c.x - 0.1055613458*c.y - 0.0638541728*c.z, 3)
        let s = pow(c.x - 0.0894841775*c.y - 1.291485548*c.z, 3)
        return SIMD3(4.0767416621*l - 3.3077115913*m + 0.2309699292*s, -1.2684380046*l + 2.6097574011*m - 0.3413193965*s, -0.0041960863*l - 0.7034186147*m + 1.707614701*s)
    }
    static func luminance(_ c: SIMD3<Double>) -> Double { simd_dot(c, SIMD3(0.2126, 0.7152, 0.0722)) }
    static func prepared(_ c: SIMD3<Double>) -> SIMD3<Double> {
        let y = luminance(c), s = y*y*(3-2*y), target = y + (s-y)*0.2
        return simd_clamp(c + SIMD3(repeating: target-y), SIMD3(repeating: 0), SIMD3(repeating: 1))
    }
}
struct EffectPalette: Codable, Equatable, Sendable {
    var colors: [EffectRGB]
    var thresholds: [Double]
    var valid:Bool { (2...16).contains(colors.count) && colors.allSatisfy(\.valid) && thresholds.count==colors.count-1 && thresholds.allSatisfy { $0.isFinite && (0...1).contains($0) } && zip(thresholds,thresholds.dropFirst()).allSatisfy { $0 <= $1 } }
}
struct EffectPalettePreset: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var colors: [String]
    func sampled(_ count: Int) -> [EffectRGB] {
        let sorted = colors.map { EffectRGB(hex: $0) }.sorted { EffectColorMath.lab(EffectColorMath.linear($0)).x < EffectColorMath.lab(EffectColorMath.linear($1)).x }
        guard sorted.count >= 2, count >= 2 else { return sorted }
        return (0..<count).map { sorted[Int((Double($0) * Double(sorted.count-1) / Double(count-1)).rounded())] }
    }
}
struct EffectRandom {
    var state: UInt64
    mutating func next() -> Double {
        state &+= 0x9E3779B97F4A7C15
        var x = state; x = (x ^ (x >> 30)) &* 0xBF58476D1CE4E5B9
        x = (x ^ (x >> 27)) &* 0x94D049BB133111EB
        return Double((x ^ (x >> 31)) >> 11) / 9007199254740992
    }
}
enum EffectPaletteAnalysis {
    static func analyze(_ samples: [SIMD3<Double>], count: Int, previous: EffectPalette? = nil, elapsed: Double = 0.2, seed: UInt64 = 0) -> EffectPalette {
        let count = max(2, min(16, count))
        let rgb = samples.filter { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }.map { EffectColorMath.prepared(simd_clamp($0, .zero, SIMD3(repeating: 1))) }
        guard !rgb.isEmpty else { return EffectPalette(colors: [EffectRGB(0,0,0), EffectRGB(1,1,1)], thresholds: [0.5]) }
        let labs = rgb.map(EffectColorMath.lab), ys = rgb.map(EffectColorMath.luminance).sorted()
        let thresholds = (1..<count).map { i in ys[min(ys.count - 1, Int(Double(i) * Double(ys.count) / Double(count)))] }
        var random = EffectRandom(state: seed)
        var centers: [SIMD3<Double>] = []
        if let previous, previous.colors.count == count { centers = previous.colors.map { EffectColorMath.lab(EffectColorMath.linear($0)) } }
        else {
            centers = [labs[Int(random.next() * Double(labs.count)) % labs.count]]
            while centers.count < count {
                let distances = labs.map { p in centers.map { simd_length_squared(p - $0) }.min()! }
                let sum = distances.reduce(0, +), target = random.next() * sum
                var cumulative = 0.0, index = labs.count - 1
                for i in labs.indices { cumulative += distances[i]; if cumulative >= target { index = i; break } }
                centers.append(labs[index])
            }
        }
        for _ in 0..<6 {
            var sums = [SIMD3<Double>](repeating: .zero, count: count), weights = [Int](repeating: 0, count: count)
            for p in labs {
                var best = 0, distance = Double.infinity
                for i in centers.indices { let d = simd_length_squared(p - centers[i]); if d < distance { distance = d; best = i } }
                sums[best] += p; weights[best] += 1
            }
            var populated: [SIMD3<Double>] = []
            for i in centers.indices where weights[i] > 0 {
                centers[i] = sums[i] / Double(weights[i])
                populated.append(centers[i])
            }
            if populated.count < count {
                // A blank first frame can seed identical gray centers. Revive empty
                // clusters from the least represented real pixel when color appears.
                var residual = labs.map { p in populated.map { simd_distance_squared(p, $0) }.min()! }
                for i in centers.indices where weights[i] == 0 {
                    guard let farthest = residual.indices.max(by: { residual[$0] < residual[$1] }) else { break }
                    centers[i] = labs[farthest]
                    if residual[farthest] < 1e-10 { continue }
                    for j in labs.indices { residual[j] = min(residual[j], simd_distance_squared(labs[j], centers[i])) }
                }
            }
        }
        centers.sort { $0.x < $1.x }
        var bands = thresholds
        if let previous, previous.colors.count == count {
            let old = previous.colors.map { EffectColorMath.lab(EffectColorMath.linear($0)) }.sorted { $0.x < $1.x }
            let cut = zip(centers, old).contains { simd_distance($0, $1) > 0.25 }
            if !cut {
                let alpha = 1 - exp(-max(0, elapsed) / 0.5)
                centers = zip(old, centers).map { $0 + ($1 - $0) * alpha }
                if previous.thresholds.count == bands.count { bands = zip(previous.thresholds, bands).map { $0 + ($1 - $0) * alpha } }
            }
        }
        return EffectPalette(colors: centers.map { EffectColorMath.rgb(EffectColorMath.linearFromLab($0)) }, thresholds: bands)
    }
}
enum VideoEffectTime {
    // Fractional cadence: 18fps on a 30fps output must remain 18fps, not 15.
    static func heldTime(_ presentationTime: Double, fps: Double) -> Double { floor(max(0, presentationTime) * fps + 0.000001) / max(1, fps) }
    static func frameIndex(_ time: Double, fps: Double) -> Int { max(0, Int(floor(max(0, time) * fps + 0.000001))) }
    // Capture selects the first available frame on/after a cadence boundary.
    // Choosing the preceding frame on export produces a different motion phase.
    static func firstFrame(atOrAfter time:Double,fps:Double)->Double {ceil(max(0,time)*max(1,fps)-0.0001)/max(1,fps)}
    // Capture explicitly writes a 600-tick video clock. Evaluate its live look
    // on that same clock, including real camera drift, instead of guessing a
    // frame grid from AVAssetTrack.nominalFrameRate (an average over the take).
    static func captureTime(_ time:Double)->Double {(max(0,time)*600).rounded()/600}
    static func cubic(_ time: Double) -> Double { let t = min(1, max(0, time)); return t < 0.5 ? 4*t*t*t : 1 - pow(-2*t+2, 3)/2 }
    static func dollyTarget(zoom: Double, referenceHeight: Double, observedHeight: Double, range: ClosedRange<Double>) -> Double {
        guard observedHeight > 0.00001, observedHeight.isFinite else { return zoom }
        return min(range.upperBound, max(range.lowerBound, zoom * referenceHeight / observedHeight))
    }
}

// Integrated frame phase, shared by capture (rate 1) and editor/export. The
// slower active cadence wins. Integrating fps/rate keeps both animated cadence
// and speed monotonic; changing a control cannot rewind the shown source frame.
struct VideoEffectCadenceClock {
    struct Segment {
        let start:Double,end:Double,phase:Double,frequency:Double,groupStart:Double
        var endPhase:Double {phase+(end-start)*frequency}
    }
    struct Hold {let index:Int;let boundary:Double}
    private let segments:[Segment]
    init(effects:[VideoEffectSettings],rates:[(start:Double,end:Double,rate:Double)]=[]) {
        let effects=effects.filter {$0.enabled && [.superEight,.undercranking].contains($0.kind)}
        var points=effects.flatMap {[$0.start,$0.end]+$0.parameters.filter {["fps","intensity"].contains($0.id)}.flatMap {$0.keyframes.map(\.time)}}
        points += rates.flatMap {[$0.start,$0.end]}
        points=Array(Set(points)).sorted()
        var values:[Segment]=[],phase=0.0,group=0.0,active=false
        for (a,b) in zip(points,points.dropFirst()) where b>a {
            let middle=(a+b)/2
            let fps=effects.filter {$0.start<=middle && $0.end>middle && (!$0.kind.descriptor.supportsIntensity || $0.number("intensity",at:middle)>0)}.map {$0.number("fps",at:middle)}.min() ?? 0
            guard fps>0 else {active=false;continue}
            if !active {phase=ceil(phase-0.000001);group=a};active=true
            let rate=rates.first(where:{$0.start<=middle && $0.end>middle})?.rate ?? 1
            let segment=Segment(start:a,end:b,phase:phase,frequency:fps/max(0.001,rate),groupStart:group)
            values.append(segment);phase=segment.endPhase
        }
        segments=values
    }
    func hold(at time:Double)->Hold? {
        var a=0,b=segments.count
        while a<b {let m=(a+b)/2;if segments[m].start<=time {a=m+1}else {b=m}}
        guard a>0 else {return nil};let current=segments[a-1]
        guard time<current.end else {return nil}
        let index=floor(current.phase+(time-current.start)*current.frequency+0.000001)
        a=0;b=segments.count
        while a<b {let m=(a+b)/2;if segments[m].endPhase<index-0.000001 {a=m+1}else {b=m}}
        let source=segments[min(a,segments.count-1)]
        return Hold(index:Int(index),boundary:max(current.groupStart,source.start+(index-source.phase)/source.frequency))
    }
}

// Forward, normalized top-down camera geometry, shared with target picking.
// These curves mirror the geometric sampling in Metal; color/frame effects do
// not move the subject. A held camera frame keeps its source-time phase.
enum VideoEffectGeometry {
    static func transform(_ effects:[VideoEffectSettings],time:Double,size:CGSize,targets:[UUID:CGPoint]=[:])->CGAffineTransform {
        guard size.width>0,size.height>0 else { return .identity }
        var result=CGAffineTransform.identity
        for effect in effects where effect.enabled && effect.start<=time && effect.end>time {
            let t=max(0,time-effect.start+(effect.phaseOffset ?? 0))
            var next=CGAffineTransform.identity
            if effect.kind == .crashZoom {
                let push=effect.number("speed",at:time),amount=effect.number("zoom",at:time)
                let release=effect.releaseTime.map {$0-effect.start+(effect.phaseOffset ?? 0)} ?? (push+0.08+effect.number("hold",at:time))
                let zoom:Double
                if t<push { zoom=1+(amount-1)*pow(t/push,5) }
                else if t<push+0.08 { zoom=amount*(1+0.03*sin((t-push)/0.08*Double.pi)) }
                else if (effect.releaseTime != nil || effect.toggle("return",at:time)) && t>release {
                    let f=min(1,max(0,(t-release)/push));zoom=amount+(1-amount)*f*f*(3-2*f)
                } else { zoom=amount }
                let target=(targets[effect.id] ?? CGPoint(x:effect.number("targetX",at:time),y:effect.number("targetY",at:time))).applying(result)
                next=CGAffineTransform(a:zoom,b:0,c:0,d:zoom,tx:target.x*(1-zoom),ty:target.y*(1-zoom))

            }
            result=result.concatenating(next)
        }
        return result
    }
}

// Uses the zoom belonging to the observed camera frame, not the latest command.
// Absolute size control prevents repeatedly correcting one stale observation.
struct DollyZoomFollower {
    let referenceHeight:Double
    let range:ClosedRange<Double>
    private(set) var zoom:Double
    private(set) var atLimit=false
    private var rawLogHeight:Double?
    private var measurementTime:Double
    private var frameTime:Double
    private var velocity=0.0
    private var stoppingAt:Double?
    init(referenceHeight:Double,zoom:Double,range:ClosedRange<Double>,time:Double) {
        self.referenceHeight=referenceHeight;self.zoom=zoom;self.range=range
        rawLogHeight=log(max(0.00001,referenceHeight/zoom));measurementTime=time;frameTime=time
    }
    mutating func observe(height:Double,appliedZoom:Double,time:Double) {
        guard stoppingAt==nil,height.isFinite,height>0.0001,appliedZoom.isFinite,appliedZoom>0,time>measurementTime else { return }
        let value=log(height/appliedZoom),alpha=1-exp(-(time-measurementTime)/0.15)
        rawLogHeight=rawLogHeight.map {$0+(value-$0)*alpha} ?? value;measurementTime=time
    }
    var isStopping:Bool { stoppingAt != nil }
    func hasStopped(at time:Double)->Bool { stoppingAt.map {time-$0>=0.3} ?? false }
    mutating func stop(at time:Double) { if stoppingAt==nil { stoppingAt=time } }
    mutating func value(at time:Double)->Double {
        let dt=max(0,min(0.1,time-frameTime));frameTime=time
        guard dt>0 else { return zoom }
        if time-measurementTime>0.5 && stoppingAt==nil { stoppingAt=time }
        if let began=stoppingAt {
            let remaining=max(0,0.3-(time-began))
            velocity *= remaining>0 ? remaining/(remaining+dt) : 0
            zoom=min(range.upperBound,max(range.lowerBound,zoom*exp(velocity*dt)));return zoom
        }
        let target=referenceHeight/exp(rawLogHeight ?? log(referenceHeight/zoom))
        let bounded=min(range.upperBound,max(range.lowerBound,target))
        atLimit=target<=range.lowerBound*1.02 || target>=range.upperBound/1.02
        let desired=max(-0.6*log(2),min(0.6*log(2),(log(bounded)-log(zoom))/0.15))
        velocity += (desired-velocity)*(1-exp(-dt/0.08))
        zoom=min(range.upperBound,max(range.lowerBound,zoom*exp(velocity*dt)))
        return zoom
    }
}

// Sticky for the current look: avoid resolution pumping while filming. The raw
// writer never sees this policy. A different enabled chain starts at full quality.
struct VideoEffectLiveBudget {
    private(set) var quality=VideoEffectQuality.full
    private(set) var maximumLongSide:Double?
    private var samples:[Bool]=[]
    private var startupGPU:[Double]=[]
    private var warmupFrames=0
    private var observationSize:Double?
    private var observationQuality:VideoEffectQuality?
    mutating func thermal(serious:Bool,critical:Bool) {
        guard serious || critical else {return}
        // Keep the same shader appearance at serious pressure. Lite is a final
        // emergency step; its recipe is recorded so export remains reproducible.
        maximumLongSide=min(maximumLongSide ?? .infinity,critical ? 960 : 1280)
        if critical {quality = .lite}
    }
    mutating func observe(gpu:Double,wall:Double,sourceLongSide:Double,renderLongSide:Double) {
        guard gpu.isFinite,wall.isFinite,gpu>=0,wall>=0 else {return}
        // An outstanding old-resolution measurement must not count against the
        // newly chosen size. Thermal changes also start a fresh quality window.
        if let limit=maximumLongSide,renderLongSide>limit+1 {return}
        if observationSize.map({abs($0-renderLongSide)>1}) ?? true || observationQuality != quality {
            samples.removeAll(keepingCapacity:true);startupGPU.removeAll(keepingCapacity:true);warmupFrames=0;observationSize=renderLongSide;observationQuality=quality
        }
        // Let pipeline setup and GPU frequency ramp-up settle. An early burst
        // must not permanently lower a look that is affordable once warm.
        if warmupFrames<10 {warmupFrames+=1;return}
        let budget=sourceLongSide>1920 ? 0.012 : 0.010
        // An obviously overloaded 4K look must not spend several seconds at
        // every rung. After 15 real renders, sustained >2x GPU cost permits an
        // area-based estimate. Twelve slow frames reject isolated compile or
        // allocation spikes; normal p95 adaptation below remains conservative.
        if startupGPU.count<15 {
            startupGPU.append(gpu)
            if startupGPU.count==15,startupGPU.filter({$0>2*budget}).count>=12 {
                let median=startupGPU.sorted()[7]
                // Allow 2 ms of fixed conversion/dispatch overhead; scaling
                // pixel area cannot remove that part of the measured cost.
                let target=renderLongSide*sqrt(max(0.02,(budget*0.85-0.002)/(median-0.002)))
                let rungs=[1920.0,1280,960,864,768,640].filter {$0<renderLongSide-1}
                if let next=rungs.first(where:{$0<=target}) ?? rungs.last {
                    maximumLongSide=min(maximumLongSide ?? .infinity,next)
                    samples.removeAll(keepingCapacity:true);return
                }
            }
        }
        samples.append(gpu>budget || wall>0.026)
        if samples.count>90 {samples.removeFirst()}
        // A window, not a majority vote: six slow frames in 90 are enough to
        // breach p95, even if every other frame is fast. A full new window at
        // each rung prevents old measurements forcing a second degradation.
        guard samples.count==90,samples.filter({$0}).count>=6 else {return}
        samples.removeAll(keepingCapacity:true)
        for limit in [1920.0,1280,960,864,768,640] where renderLongSide>limit+1 {
            maximumLongSide=min(maximumLongSide ?? .infinity,limit);return
        }
        quality = .lite
    }
}

enum VideoEffectPlacementGesture {
    case pan(CGPoint)
    case pinch(factor:Double,from:CGPoint,to:CGPoint)
    case ended
}
struct VideoEffectBackgroundPlacement {
    var x=0.5,y=0.5,zoom=1.0
    let canvas:CGSize
    let media:CGSize
    let fill:Bool
    private func size(at zoom:Double)->CGSize {
        let sx=canvas.width/max(1,media.width),sy=canvas.height/max(1,media.height)
        let scale=(fill ? max(sx,sy) : min(sx,sy))*zoom
        return CGSize(width:media.width*scale/max(1,canvas.width),height:media.height*scale/max(1,canvas.height))
    }
    var movementLocked:Bool {let s=size(at:zoom);return abs(1-s.width)<0.0001 && abs(1-s.height)<0.0001}
    mutating func apply(_ gesture:VideoEffectPlacementGesture) {
        let old=size(at:zoom)
        func align(_ value:Double,_ span:Double,_ previous:Double)->Double {abs(span)<0.0001 ? previous : min(1,max(0,value/span))}
        switch gesture {
        case .pan(let delta):
            x=align((1-old.width)*x+delta.x,1-old.width,x)
            y=align((1-old.height)*y+delta.y,1-old.height,y)
        case let .pinch(factor,from,to):
            guard factor.isFinite,factor>0 else {return}
            let origin=CGPoint(x:(1-old.width)*x,y:(1-old.height)*y)
            zoom=min(4,max(1,zoom*factor));let next=size(at:zoom)
            x=align(to.x-(from.x-origin.x)*next.width/old.width,1-next.width,x)
            y=align(to.y-(from.y-origin.y)*next.height/old.height,1-next.height,y)
        case .ended:break
        }
    }
}
