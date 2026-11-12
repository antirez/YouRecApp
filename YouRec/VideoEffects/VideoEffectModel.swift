import Foundation

// Source-time values survive trims, pauses, speed changes and clip splits.
// Categorical parameters use hold interpolation; continuous values interpolate.
enum EffectFamily: String, Codable, CaseIterable, Sendable {
    case key, camera, color, quantization, texture, frame, time
    var order: Int { Self.allCases.firstIndex(of: self)! }
    var title: String { switch self {
    case .key: return "Background"; case .camera: return "Camera"; case .color: return "Color & tone"
    case .quantization: return "Quantization"; case .texture: return "Film texture"; case .frame: return "Frame"; case .time: return "Time"
    } }
}
enum VideoEffectQuality:String,Codable,Sendable { case full,lite }

enum NightFixMode:String,CaseIterable,Sendable {
    case fast = "Fast", medium = "Medium", precise = "Precise"
    var radius:Int {switch self {case .fast:return 0;case .medium:return 1;case .precise:return 4}}
    var guideLimit:Double {self == .medium ? 256 : 512}
    var explanation:String {switch self {
    case .fast:return "Single-frame cleanup. Preview and export use this result, with no extra preparation."
    case .medium:return "Combines 3 motion-aligned frames for cleaner noise with less waiting."
    case .precise:return "Combines 9 motion-aligned frames for the strongest temporal cleanup. Takes longer to prepare."
    }}
}

enum EffectMode: String, Codable, Sendable { case live, edit, both }
enum RGBChannel: String, CaseIterable {
    case red, green, blue
    var name: String { rawValue.capitalized }
    var x: String { rawValue + "X" }
    var y: String { rawValue + "Y" }
}

enum VideoEffectID: String, Codable, CaseIterable, Sendable {
    case rgbOffset, negativeStrobe, nightFix, colorCorrection, silentTint, threeStrip, bleachBypass, dayForNight, colorIsolation, noir, expressionism
    case quantization, dollyZoom, crashZoom, kaleidoscope, widescreen, freezeFrame, stepPrinting, undercranking
    case halation, sixteenMM, superEight, chromaKey, autoBackground
    // Stable shader ABI; adding or reordering catalogue entries must not change it.
    var shaderIndex: UInt32 { switch self {
    case .rgbOffset: return 23
    case .negativeStrobe: return 24
    case .kaleidoscope: return 22
    case .nightFix: return 21
    case .colorCorrection: return 20
    case .silentTint: return 0; case .threeStrip: return 1; case .bleachBypass: return 2
    case .dayForNight: return 3; case .colorIsolation: return 4; case .noir: return 5
    case .expressionism: return 6; case .quantization: return 7; case .dollyZoom: return 8
    case .crashZoom: return 9; case .widescreen: return 11
    case .freezeFrame: return 12; case .stepPrinting: return 13; case .undercranking: return 14
    case .halation: return 15; case .sixteenMM: return 16; case .superEight: return 17
    case .chromaKey: return 18; case .autoBackground: return 19
    } }
    var descriptor: VideoEffectDescriptor { VideoEffectCatalog.all.first { $0.id == self }! }
}
struct EffectRGB: Codable, Equatable, Sendable {
    var red: Double; var green: Double; var blue: Double
    init(_ red: Double, _ green: Double, _ blue: Double) { self.red = red; self.green = green; self.blue = blue }
    init(hex: String) {
        let value = UInt32(hex.replacingOccurrences(of: "#", with: ""), radix: 16) ?? 0
        self.init(Double((value >> 16) & 255) / 255, Double((value >> 8) & 255) / 255, Double(value & 255) / 255)
    }
    var valid: Bool { [red, green, blue].allSatisfy { $0.isFinite && (0...1).contains($0) } }
}
enum EffectValue: Codable, Equatable, Sendable {
    case number(Double), toggle(Bool), choice(String), color(EffectRGB), media(String?)
    func interpolated(to other: EffectValue, fraction: Double) -> EffectValue {
        let t = min(1, max(0, fraction))
        switch (self, other) {
        case (.number(let a), .number(let b)): return .number(a + (b - a) * t)
        case (.color(let a), .color(let b)): return .color(EffectRGB(a.red + (b.red - a.red) * t, a.green + (b.green - a.green) * t, a.blue + (b.blue - a.blue) * t))
        default: return t < 1 ? self : other
        }
    }
}
enum EffectParameterKind: Codable, Equatable, Sendable {
    case slider(min: Double, max: Double, defaultValue: Double, step: Double)
    case toggle(defaultValue: Bool)
    case stepper(values: [Double], defaultValue: Double)
    case color(defaultValue: EffectRGB)
    case picker(options: [String], defaultValue: String)
    case media(image: Bool, video: Bool)
    var defaultValue: EffectValue { switch self {
    case let .slider(_, _, value, _), let .stepper(_, value): return .number(value)
    case .toggle(let value): return .toggle(value)
    case .color(let value): return .color(value)
    case .picker(_, let value): return .choice(value)
    case .media: return .media(nil)
    } }
    var continuous: Bool { switch self { case .slider, .color: return true; default: return false } }
    func accepts(_ value: EffectValue) -> Bool { switch (self, value) {
    case let (.slider(a, b, _, _), .number(v)): return v.isFinite && (a...b).contains(v)
    case let (.stepper(values, _), .number(v)): return values.contains(v)
    case (.toggle, .toggle): return true
    case (.color, .color(let value)): return value.valid
    case let (.picker(values, _), .choice(v)): return values.contains(v)
    case let (.media(images,videos), .media(path)): return path.map {
            let ext=URL(fileURLWithPath:$0).pathExtension.lowercased()
            return !$0.isEmpty && $0==URL(fileURLWithPath:$0).lastPathComponent && !$0.hasPrefix(".") && !$0.contains("\\")
                && (images && ["png","jpg","jpeg","heic","heif","tif","tiff","webp"].contains(ext) || videos && ["mov","mp4","m4v"].contains(ext))
        } ?? true
    default: return false
    } }
}
struct EffectKeyframe: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var time: Double
    var value: EffectValue
}
struct EffectParameter: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var kind: EffectParameterKind
    var value: EffectValue
    var keyframes: [EffectKeyframe] = []
    var animatable = true
    init(_ id: String, _ title: String, _ kind: EffectParameterKind, animatable: Bool = true) {
        self.id = id; self.title = title; self.kind = kind; value = kind.defaultValue; self.animatable = animatable
    }
    static func wrappedDegrees(_ value: Double) -> Double {
        value - 360 * floor((value + 180) / 360)
    }
    func value(at time: Double) -> EffectValue {
        guard let first = keyframes.first else { return value }
        guard time > first.time else { return first.value }
        for (a, b) in zip(keyframes, keyframes.dropFirst()) where time < b.time {
            let fraction = (time - a.time) / (b.time - a.time)
            if id == "splitAngle" || id == "sourceAngle", case .number(let start) = a.value, case .number(let end) = b.value {
                let difference = end - start
                let travel = abs(difference) > 180 ? difference - copysign(360, difference) : difference
                return .number(Self.wrappedDegrees(start + travel * fraction))
            }
            return kind.continuous ? a.value.interpolated(to: b.value, fraction: fraction) : a.value
        }
        return keyframes.last!.value
    }
    mutating func setKeyframe(at time: Double, value: EffectValue) {
        guard animatable, time.isFinite, time >= 0, kind.accepts(value) else { return }
        keyframes.removeAll { abs($0.time - time) < 1.0 / 60000 }
        keyframes.append(EffectKeyframe(time: time, value: value)); keyframes.sort { $0.time < $1.time }
    }
    var valid: Bool {
        kind.accepts(value) && (animatable || keyframes.isEmpty) && keyframes.count <= 100_000
            && Set(keyframes.map(\.id)).count == keyframes.count
            && keyframes.allSatisfy { $0.time.isFinite && (0...604800).contains($0.time) && kind.accepts($0.value) }
            && zip(keyframes, keyframes.dropFirst()).allSatisfy { $0.time < $1.time }
    }
}
struct VideoEffectDescriptor: Sendable {
    let id: VideoEffectID
    let displayName: String
    let historyNote: String
    let family: EffectFamily
    let mode: EffectMode
    let parameters: [EffectParameter]
    var supportsIntensity: Bool { family != .time && family != .camera }
}
struct StrobeTimePoint: Codable, Equatable, Sendable {
    let source: Double
    let elapsed: Double
}

struct VideoEffectSettings: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var kind: VideoEffectID
    var enabled = true
    var version = 1
    var start = 0.0
    var end = 604800.0
    var parameters: [EffectParameter]
    // Persisted analysis/palette assets are immutable, project-local files.
    var analysisFile: String?
    var analysisDataFile: String?
    var capturedEffectID:UUID?
    var analysisID:UUID {capturedEffectID ?? id}
    var captureIdentity:Self {var value=self;value.id=analysisID;value.capturedEffectID=nil;return value}
    var palette: [EffectRGB]?
    var lockedPalette:EffectPalette?
    var motion: EffectAnimation?
    var algorithm:Int? // Absent in legacy recipes; preserves their rendering.
    var nightFixMode: NightFixMode { NightFixMode(rawValue: choice("mode")) ?? .fast }
    var requiresOfflineAnalysis: Bool {
        guard enabled else { return false }
        switch kind {
        case .nightFix: return nightFixMode != .fast
        case .quantization, .autoBackground, .dollyZoom: return true
        case .crashZoom: return toggle("trackFace", at: start) || parameters.contains { $0.id == "trackFace" && !$0.keyframes.isEmpty }
        case .colorIsolation, .chromaKey: return usesModernPersonMask
        default: return false
        }
    }
    var usesTemporalMatte:Bool {algorithm==2 && [.colorIsolation,.chromaKey].contains(kind)}
    var usesModernPersonMask:Bool {algorithm==1 || usesTemporalMatte}
    var usesAutoMaskStream:Bool {kind == .autoBackground && algorithm==1}
    func isActive(at time:Double)->Bool {
        enabled && time>=start && time<end && (!kind.descriptor.supportsIntensity || number("intensity",at:time)>0)
    }
    var strobeTimeMap: [StrobeTimePoint]? // Playback seconds at authoring time for sped-up or cut source material.
    var phaseOffset:Double? // Elapsed time carried into a captured camera move or an editor strobe across clips.
    var releaseTime:Double? // Source-time manual return of a captured Crash Zoom.
    init(_ kind: VideoEffectID, start: Double = 0, end: Double = 604800) {
        self.kind = kind; self.start = start; self.end = end
        algorithm=[.colorIsolation,.chromaKey].contains(kind) ? 2 : 1
        parameters = kind.descriptor.parameters
        if kind.descriptor.supportsIntensity { parameters.insert(EffectParameter("intensity", "Intensity", .slider(min: 0, max: 1, defaultValue: 1, step: 0.01)), at: 0) }
    }
    private enum CodingKeys:String,CodingKey { case motion,id,kind,enabled,version,start,end,parameters,analysisFile,analysisDataFile,capturedEffectID,palette,lockedPalette,releaseTime,phaseOffset,algorithm,strobeTimeMap }
    init(from decoder:Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        let kind=try c.decode(VideoEffectID.self,forKey:.kind)
        self.init(kind)
        id=try c.decode(UUID.self,forKey:.id);enabled=try c.decode(Bool.self,forKey:.enabled)
        version=try c.decode(Int.self,forKey:.version);start=try c.decode(Double.self,forKey:.start);end=try c.decode(Double.self,forKey:.end)
        let stored=try c.decode([EffectParameter].self,forKey:.parameters),reference=parameters
        // Bounds, labels and supported choices belong to the installed catalogue.
        // Old projects retain values and animation when the catalogue gains a
        // choice or enables animation; they cannot redefine the allowed bounds.
        parameters=stored.map { old in
            guard var canonical=reference.first(where:{$0.id==old.id}) else { return old }
            canonical.value=old.value;canonical.keyframes=old.keyframes;return canonical
        }
        parameters += reference.filter { p in !stored.contains(where:{$0.id==p.id}) }
        analysisFile=try c.decodeIfPresent(String.self,forKey:.analysisFile)
        analysisDataFile=try c.decodeIfPresent(String.self,forKey:.analysisDataFile)
        capturedEffectID=try c.decodeIfPresent(UUID.self,forKey:.capturedEffectID)
        palette=try c.decodeIfPresent([EffectRGB].self,forKey:.palette)
        lockedPalette=try c.decodeIfPresent(EffectPalette.self,forKey:.lockedPalette)
        releaseTime=try c.decodeIfPresent(Double.self,forKey:.releaseTime)
        strobeTimeMap=try c.decodeIfPresent([StrobeTimePoint].self,forKey:.strobeTimeMap)
        phaseOffset=try c.decodeIfPresent(Double.self,forKey:.phaseOffset)
        motion = try c.decodeIfPresent(EffectAnimation.self, forKey:.motion)
        algorithm=try c.decodeIfPresent(Int.self,forKey:.algorithm)
    }
    func value(_ id: String, at time: Double = 0) -> EffectValue? {
        if let motion, motion.a.values[id] != nil { return .number(motion.value(id, fraction: motion.fraction(at: time))) }
        return parameters.first { $0.id == id }?.value(at: time)
    }
    func number(_ id: String, at time: Double = 0) -> Double { if case .number(let value) = value(id, at: time) { return value }; return 0 }
    func toggle(_ id: String, at time: Double = 0) -> Bool { if case .toggle(let value) = value(id, at: time) { return value }; return false }
    func choice(_ id: String, at time: Double = 0) -> String { if case .choice(let value) = value(id, at: time) { return value }; return "" }
    func color(_ id: String, at time: Double = 0) -> EffectRGB { if case .color(let value) = value(id, at: time) { return value }; return EffectRGB(0, 0, 0) }
    mutating func set(_ id: String, _ value: EffectValue) {
        guard let index = parameters.firstIndex(where: { $0.id == id }), parameters[index].kind.accepts(value) else { return }
        parameters[index].value = value
    }
    var recordingResult:VideoEffectSettings {
        var result=self
        if let index=result.parameters.firstIndex(where:{$0.id=="view"}) {
            result.parameters[index].value = .choice("Result");result.parameters[index].keyframes=[]
        }
        return result
    }
    mutating func sanitizeBackgroundMedia(at time:Double) {
        let mode=choice("background",at:time)
        guard ["Image","Video"].contains(mode),case .media(let file)=value("media",at:time),let file,
              let index=parameters.firstIndex(where:{$0.id=="media"}) else { return }
        let isVideo=["mov","mp4","m4v"].contains(URL(fileURLWithPath:file).pathExtension.lowercased())
        if (mode=="Video") != isVideo {
            if !parameters[index].keyframes.isEmpty || parameters.first(where:{$0.id=="background"})?.keyframes.isEmpty==false {
                parameters[index].setKeyframe(at:time,value:.media(nil))
            } else { parameters[index].value = .media(nil) }
        }
    }
    var mediaFiles: [String] {
        var files: [String] = analysisFile.map { [$0] } ?? []
        if let analysisDataFile { files.append(analysisDataFile) }
        for p in parameters { for v in [p.value] + p.keyframes.map(\.value) { if case .media(let file) = v, let file { files.append(file) } } }
        return Array(Set(files)).sorted()
    }
    var valid: Bool {
        let reference = VideoEffectSettings(kind).parameters
        if let motion {
            guard kind == .colorCorrection, motion.valid(for:correctionPose(at:start),accepts:{ p in
                reference.allSatisfy { $0.kind.accepts(.number(p[$0.id])) }
            }) else { return false }
        }
        return (algorithm==nil || algorithm==1 || usesTemporalMatte) && version == 1 && start.isFinite && end.isFinite && start >= 0 && end > start && end <= 604800
            && parameters.count == reference.count && Set(parameters.map(\.id)).count == parameters.count
            && parameters.allSatisfy { p in p.valid && reference.contains { $0.id == p.id && $0.kind == p.kind && $0.animatable == p.animatable } }
            && (strobeTimeMap.map { points in
                kind == .negativeStrobe && points.count >= 2 && points.count <= 100_000 &&
                points.allSatisfy { $0.source.isFinite && $0.elapsed.isFinite && (0...604800).contains($0.elapsed) } &&
                zip(points, points.dropFirst()).allSatisfy { $0.source < $1.source && $0.elapsed <= $1.elapsed }
            } ?? true)
            && (releaseTime.map { kind == .crashZoom && $0.isFinite && $0>=start-(phaseOffset ?? 0) && $0<end } ?? true)
            && (phaseOffset.map { (kind == .crashZoom || kind == .negativeStrobe) && $0.isFinite && (0...604800).contains($0) } ?? true)
            && (lockedPalette?.valid ?? true)
            && (palette.map { (2...16).contains($0.count) && $0.allSatisfy(\.valid) } ?? true)
            && mediaFiles.allSatisfy { !$0.hasPrefix(".") && !$0.contains("\\") && $0 == URL(fileURLWithPath: $0).lastPathComponent }
    }
    func strobeShowsNegative(at time: Double, fps: Double, holdTime: Double? = nil) -> Bool {
        func elapsed(_ t: Double) -> Double {
            guard let points = strobeTimeMap, let first = points.first, let last = points.last else { return max(0, t - start) }
            if t <= first.source { return first.elapsed }
            if t >= last.source { return last.elapsed }
            var lo = 0, hi = points.count - 1
            while hi - lo > 1 {
                let mid = (lo + hi) / 2
                if points[mid].source <= t { lo = mid } else { hi = mid }
            }
            let a = points[lo], b = points[hi]
            return a.elapsed + (b.elapsed-a.elapsed) * (t-a.source)/(b.source-a.source)
        }
        let offset = phaseOffset ?? 0, clock = offset + (holdTime ?? elapsed(time))
        if toggle("timedBurst") && clock >= number("burstLength") - 1e-8 { return false }
        guard let frequency = parameters.first(where: { $0.id == "frequency" }) else { return false }
        let ceiling = max(0.5, fps * 0.5)
        func rate(_ value: EffectValue) -> Double {
            if case .number(let hz) = value { return min(ceiling, hz) }
            return 8
        }
        // Integrate held rate keys. Changing speed cannot rewind the phase,
        // and seeking to a frame produces exactly the same polarity as playing it.
        var hz = rate(frequency.value(at: start)), last = 0.0, cycles = 0.0
        for key in frequency.keyframes where key.time > start {
            if key.time > time { break }
            let next = offset + elapsed(key.time)
            cycles += (next-last)*hz; last = next; hz = rate(key.value)
        }
        cycles += (clock-last)*hz
        return floor(cycles*2 + 1e-7).truncatingRemainder(dividingBy: 2) == 1
    }

    // Captured moves may be retimed in the editor. Never leave their old end
    // cutting off an extended push/hold, and never overlap a later trigger.
    mutating func retimeCapturedCrash(after previous:Self,limit:Double) {
        let timing:Set<String>=["speed","hold","return"]
        guard parameters.filter({timing.contains($0.id)}) != previous.parameters.filter({timing.contains($0.id)}) else {return}
        refreshCapturedCrashEnd(limit:limit)
    }
    mutating func refreshCapturedCrashEnd(limit:Double) {
        guard kind == .crashZoom,phaseOffset != nil,limit>start else { return }
        func maximum(_ id:String)->Double {
            guard let p=parameters.first(where:{$0.id==id}) else { return 0 }
            return ([p.value]+p.keyframes.map(\.value)).compactMap { value in if case .number(let n)=value { return n };return nil }.max() ?? 0
        }
        let push=maximum("speed"),hold=maximum("hold"),origin=start-(phaseOffset ?? 0)
        let allReturn=parameters.first(where:{$0.id=="return"}).map { ([ $0.value ]+$0.keyframes.map(\.value)).allSatisfy {$0 == .toggle(true)} } ?? false
        let desired=releaseTime.map {$0+push} ?? (allReturn ? origin+2*push+0.08+hold : limit)
        end=max(start+min(1.0/30,limit-start),min(limit,desired))
        if let releaseTime,releaseTime>=end { self.releaseTime=nil }
    }
    static func capturedRecipe(_ effects:[VideoEffectSettings],duration:Double)->[VideoEffectSettings] {
        effects.compactMap { effect in
            guard effect.start<duration else { return nil }
            var result=effect;result.end=min(duration,effect.end)
            if let release=result.releaseTime,release>=result.end { result.releaseTime=nil }
            return result.end>result.start ? result : nil
        }
    }
    static func ordered(_ effects: [VideoEffectSettings]) -> [VideoEffectSettings] {
        effects.enumerated().sorted { a, b in
            if (a.element.kind == .nightFix) != (b.element.kind == .nightFix) {return a.element.kind == .nightFix}
            let x = a.element.kind.descriptor.family.order, y = b.element.kind.descriptor.family.order
            if x != y { return x < y }
            if (a.element.kind == .kaleidoscope) != (b.element.kind == .kaleidoscope) { return b.element.kind == .kaleidoscope }
            // Primary balance precedes creative color looks, regardless of add order.
            if (a.element.kind == .colorCorrection) != (b.element.kind == .colorCorrection) { return a.element.kind == .colorCorrection }
            return a.offset < b.offset
        }.map(\.element)
    }
}

// Unknown catalogue IDs are ignored at collection boundaries. Known effects
// still decode and validate normally: corrupt recognized settings are not hidden.
struct SupportedVideoEffects: Decodable {
    var values: [VideoEffectSettings] = []
    private enum Keys: String, CodingKey { case kind }
    init(from decoder: Decoder) throws {
        var items = try decoder.unkeyedContainer()
        while !items.isAtEnd {
            let item = try items.superDecoder()
            let fields = try item.container(keyedBy: Keys.self)
            let name = try fields.decode(String.self, forKey: .kind)
            guard VideoEffectID(rawValue: name) != nil else { continue }
            values.append(try VideoEffectSettings(from: item))
        }
    }
}
extension KeyedDecodingContainer {
    // Also used by synthesized SourceMedia/TimelineClip decoders, including
    // every Undo/Redo history entry and imported project archives.
    func decodeIfPresent(_ type: [VideoEffectSettings].Type, forKey key: Key) throws -> [VideoEffectSettings]? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        let values = try decode(SupportedVideoEffects.self, forKey: key).values
        return values
    }
}
