import Foundation

extension VideoEffectID {
    var historicalHelp: String? {
        [.colorCorrection, .nightFix, .autoBackground, .freezeFrame].contains(self) ? nil : descriptor.historyNote
    }
    var usageHelp: String { switch self {
    case .colorCorrection: return "Start with Exposure and White balance, then adjust Contrast and Saturation. Use the tonal controls to refine shadows, midtones and highlights. Compare with Original while adjusting; clipped detail that was never recorded cannot be recovered."
    case .nightFix: return "Brighten dark footage and reduce noise after recording. Fast gives a quick result; higher quality modes use more processing time. Increase recovery gradually: strong settings can soften detail or expose color blotches."
    case .silentTint: return "Choose a color for the whole image. Tint colors the highlights; Tone colors the shadows while keeping whites neutral. Contrast controls the separation of light and dark."
    case .threeStrip: return "Use Saturation for rich color, Red depth for denser reds, and Warmth to balance the result. Lower Intensity for a gentler look and check skin tones in the preview."
    case .bleachBypass: return "Strength increases contrast and removes color for a dense, metallic look. Lower it if faces or shadows lose too much detail."
    case .dayForNight: return "Darkness and Blue make daylight footage read as night. Moonlight highlights preserve bright accents. It works best with controlled light; a bright daytime sky can still reveal the illusion."
    case .colorIsolation: return "Keep one color while the rest becomes black and white, or keep the person in color. Hue range widens the colors retained; Softness blends their edges. Subject mode requires a visible person."
    case .noir: return "Create a monochrome image with deep shadows. Adjust Contrast and Black crush while watching darker details; add Grain or a slight shadow tint for character."
    case .expressionism: return "Combine hard monochrome contrast with a dark vignette. Choose the iris shape and reduce Vignette if it hides important content near the edges."
    case .quantization: return "Reduce the image to a few colors or gray levels. From scene samples the picture; Pop palettes map brightness to fixed colors. Smoothing reduces speckles. Lock palette keeps colors stable, and Re-sample captures a new palette from the current frame."
    case .dollyZoom: return "During recording, tap the subject and move slowly toward or away from it; zoom tries to keep the subject the same size. Stop before reaching the lens limit. In the editor, the effect separates subject and background using imported depth or a person mask."
    case .crashZoom: return "A quick push toward a face or detail. Adjust Zoom amount, Speed and Hold, then choose whether to return. During recording, tap the subject and trigger the move with the on-screen control or a volume key."
    case .rgbOffset: return "Drag each cross to shift its color layer. The center is the original registration. The outer ring moves a channel by 12% of the picture’s shorter side. Double-tap a pad to center that channel."
    case .negativeStrobe: return "Alternate the picture with its color negative. One cycle includes a positive and a negative image. Use the whole range or set a shorter burst. Camera preview starts when you tap Try strobe; recording starts a fresh cycle."
    case .kaleidoscope: return "Two divisions mirror one half of the picture. Higher counts repeat a wedge around the center. Even counts alternate reflections. Odd counts repeat by rotation. Drag the center to move the split or the round handle to rotate it. Drag a detail to pan the source. Twist two fingers to rotate the source around the split center. The angle settles at 0° near neutral. The cyan arc marks the source wedge. The picture reflects at its edges."
    case .widescreen: return "Choose the frame ratio and bar style, then add horizontal highlight flares if desired. The bars remain clean above other effects. Oval bokeh needs compatible imported depth and is available only in the editor."
    case .freezeFrame: return "Insert a hold at the playhead. Hold duration adds time to the project; Push-in moves slowly into the still. Silence pauses dialogue until footage resumes. Continue can repeat dialogue when the original video resumes."
    case .stepPrinting: return "Repeat groups of frames for stuttering motion. Step controls the repetition and Smear blends motion within each group. Slow also reduces playback speed."
    case .undercranking: return "Choose a low frame cadence for uneven motion, then adjust Speed-up, Flicker and Gate weave. Recording previews the cadence; the editor applies the final speed and audio choice."
    case .halation: return "Glow softens bright areas, Halation red adds warm fringes around highlights, and Flash lifts shadows. Use small amounts to retain contrast."
    case .sixteenMM: return "Choose the grain size and amount, then add softness or gate movement. Grain animates with each frame. The frame edge option adds a rounded film gate."
    case .superEight: return "Combine faded warm color, coarse grain and an unsteady frame. Adjust Fade, Grain and Weave independently; Light leaks adds occasional warm light at the edge."
    case .chromaKey: return "Use a green or blue screen behind the subject. Screen color identifies the color to remove; Background chooses its replacement. Matte view shows what is kept. Despill removes colored fringes. Person hint can remove objects outside a person's silhouette, so turn it off for other subjects."
    case .autoBackground: return "Keep people and replace or blur what is behind them. With no person visible, the whole frame becomes the background. Edge softness and Shrink/Grow refine the outline; Light wrap blends it with the new background. Hair and fast motion can need careful adjustment."
    } }
}

// Browsing follows creative intent, independently of the fixed render pipeline.
// These groups never change EffectFamily, shader order or saved effect IDs.
enum VideoEffectLibrarySection:String,CaseIterable,Identifiable {
    case colorStyle,cameraFrame,time,background
    var id:String {rawValue}
    var title:String {switch self {
    case .colorStyle:return "Color & style"
    case .cameraFrame:return "Camera & frame";case .time:return "Time";case .background:return "Background"
    }}
    var symbol:String {switch self {
    case .colorStyle:return "paintpalette"
    case .cameraFrame:return "viewfinder";case .time:return "clock";case .background:return "person.crop.rectangle"
    }}
    var summary:String {switch self {
    case .colorStyle:return "Color, contrast, grain and glow"
    case .cameraFrame:return "Zoom, mirror patterns and widescreen framing"
    case .time:return "Freeze, repeat or speed up motion"
    case .background:return "Replace or blur what is behind you"
    }}
    var kinds:[VideoEffectID] {switch self {
    case .colorStyle:return [.nightFix,.colorCorrection,.rgbOffset,.silentTint,.threeStrip,.bleachBypass,.dayForNight,.colorIsolation,.noir,.expressionism,.quantization,.halation,.sixteenMM,.superEight]
    case .cameraFrame:return [.dollyZoom,.crashZoom,.kaleidoscope,.widescreen]
    case .time:return [.negativeStrobe,.freezeFrame,.stepPrinting,.undercranking]
    case .background:return [.autoBackground,.chromaKey]
    }}
    func effects(live:Bool)->[VideoEffectDescriptor] {kinds.map(\.descriptor).filter {!live || $0.mode != .edit}}
}
extension VideoEffectID {
    var librarySection:VideoEffectLibrarySection {VideoEffectLibrarySection.allCases.first {$0.kinds.contains(self)}!}
    var summary:String {switch self {
    case .rgbOffset:return "Slide the red, green and blue images out of alignment."
    case .negativeStrobe:return "Flash between the original picture and its color negative."
    case .nightFix:return "Lift dark footage and clean noise. Choose fast cleanup or motion-aligned restoration. Editor only."
    case .colorCorrection:return "Balance exposure, contrast, white balance and color before your look."
    case .silentTint:return "Tint the picture with a single film color."
    case .threeStrip:return "Rich colors, deeper reds and dense blacks."
    case .bleachBypass:return "Muted color with strong, metallic contrast."
    case .dayForNight:return "Turn daylight into a cool, dark night look."
    case .colorIsolation:return "Keep one color or the person in color; make the rest monochrome."
    case .noir:return "Black and white with deep shadows and contrast."
    case .expressionism:return "Bold monochrome contrast with a dark vignette."
    case .quantization:return "Reduce the picture to a few colors or shades of gray."
    case .dollyZoom:return "Keep the subject steady while the background stretches."
    case .crashZoom:return "A quick push toward a face or detail."
    case .kaleidoscope:return "Mirror the picture or repeat a wedge around a movable center."
    case .widescreen:return "Change the frame ratio and add horizontal light flares."
    case .freezeFrame:return "Insert a held frame, with optional slow push-in."
    case .stepPrinting:return "Repeat and blend frames for stuttering, smeared motion."
    case .undercranking:return "Quick, uneven motion with a silent-film cadence."
    case .halation:return "Soften bright lights with a warm glow."
    case .sixteenMM:return "Film grain, softness and subtle frame movement."
    case .superEight:return "Warm, faded home-movie color and coarse grain."
    case .chromaKey:return "Remove a green or blue screen and choose a new background."
    case .autoBackground:return "Keep people and blur or replace the background."
    }}
}

// One set of capability/dependency rules for the live and editor inspectors.
enum VideoEffectParameterVisibility {
    static func visible(_ parameter:EffectParameter,effect:VideoEffectSettings,time:Double=0,live:Bool=false,hasDepth:Bool=false)->Bool {
        if effect.kind == .negativeStrobe && parameter.id == "burstLength" { return effect.toggle("timedBurst", at: time) }
        let id=parameter.id
        if id=="ovalBokeh" {return !live && hasDepth}
        if effect.kind == .quantization {
            if id=="palette" && effect.toggle("monochrome",at:time) {return false}
            if id=="faceDetail" && effect.number("colors",at:time)>4 {return false}
        }
        if effect.kind == .chromaKey {
            let hasPlate:Bool = {if case .media(let file)=effect.value("cleanPlate",at:time) {return file != nil};return false}()
            if ["screenColor","autoScreen"].contains(id) && hasPlate {return false}
            if id=="screenColor" {return !effect.toggle("autoScreen",at:time)}
            if id=="screenType" {return hasPlate || effect.toggle("autoScreen",at:time)}
        }
        if effect.kind == .widescreen && id=="flareColor" {return effect.number("flares",at:time)>0}
        if effect.kind == .halation && id=="flashColor" {return effect.number("flash",at:time)>0}
        if effect.kind == .sixteenMM && id=="grainSize" {return effect.number("grain",at:time)>0}
        if effect.kind == .expressionism && id=="iris" {return effect.number("vignette",at:time)>0}
        if effect.kind == .colorIsolation && effect.choice("mode",at:time)=="The subject" && ["color","range"].contains(id) {return false}
        if id=="backgroundColor" {return effect.choice("background",at:time)=="Solid"}
        if ["media","fit","backgroundX","backgroundY","backgroundZoom","backgroundAudio"].contains(id) {
            let mode=effect.choice("background",at:time)
            if id=="media" {return ["Image","Video"].contains(mode)}
            guard case .media(let file)=effect.value("media",at:time),file != nil else {return false}
            return id=="backgroundAudio" ? mode=="Video" : ["Image","Video"].contains(mode)
        }
        if id=="backgroundBlur" && ["Solid","Blur original"].contains(effect.choice("background",at:time)) {return effect.kind == .chromaKey && effect.choice("background",at:time)=="Blur original"}
        if ["backgroundBlur","backgroundBrightness","matchColor","matchStrength"].contains(id),["Image","Video"].contains(effect.choice("background",at:time)) {
            guard case .media(let file)=effect.value("media",at:time),file != nil else {return false}
        }
        if ["matchColor","matchStrength"].contains(id),effect.choice("background",at:time)=="Blur original" {return false}
        if id=="portraitBlur" {return effect.choice("background",at:time)=="Blur original"}
        if id=="matchStrength" {return effect.toggle("matchColor",at:time)}
        if effect.kind == .crashZoom {
            if ["targetX","targetY"].contains(id) && (live || effect.toggle("trackFace",at:time)) {return false}
            if ["hold","return"].contains(id) && effect.releaseTime != nil {return false}
            if id=="hold" && !effect.toggle("return",at:time) {return false}
        }
        if live && effect.kind == .dollyZoom && ["strength","targetX","targetY","easing"].contains(id) {return false}
        return true
    }
    static func choices(_ parameter:EffectParameter,effect:VideoEffectSettings)->[String] {
        guard case .picker(let options,_)=parameter.kind else {return []}
        return options.filter {!(effect.kind == .quantization && parameter.id=="palette" && $0=="Saved" && effect.palette==nil)}
    }
}

enum IsolationHue {
    static func accepts(_ color:EffectRGB)->Bool {
        let high=max(color.red,max(color.green,color.blue)),low=min(color.red,min(color.green,color.blue))
        return high>0.001 && (high-low)/high>0.08
    }
    static func degrees(_ c:EffectRGB)->Double {
        let high=max(c.red,max(c.green,c.blue)),low=min(c.red,min(c.green,c.blue)),delta=high-low
        guard delta>0 else {return 0}
        let phase=high==c.red ? (c.green-c.blue)/delta : high==c.green ? 2+(c.blue-c.red)/delta : 4+(c.red-c.green)/delta
        return (phase*60+360).truncatingRemainder(dividingBy:360)
    }
    static func color(_ degrees:Double)->EffectRGB {
        let h=degrees.truncatingRemainder(dividingBy:360)/60,x=1-abs(h.truncatingRemainder(dividingBy:2)-1)
        switch Int(h) {case 0:return EffectRGB(1,x,0);case 1:return EffectRGB(x,1,0);case 2:return EffectRGB(0,1,x);case 3:return EffectRGB(0,x,1);case 4:return EffectRGB(x,0,1);default:return EffectRGB(1,0,x)}
    }
    static let invalidSample="Choose a colored area. Black, white and gray have no hue to isolate."
}

enum ChromaScreen {
    // Match the keyer's linear-light channel-difference test. A generic RGB
    // picker would also offer neutral/red screens this renderer cannot remove.
    static func accepts(_ color:EffectRGB)->Bool {
        func linear(_ x:Double)->Double {x<=0.04045 ? x/12.92 : pow((x+0.055)/1.055,2.4)}
        let r=linear(color.red),g=linear(color.green),b=linear(color.blue)
        return g-max(r,b)>0.02 || b-max(r,g)>0.02
    }
    static let explanation="Requires a green or blue screen. For an ordinary room or wall, use Auto Background."
    static let invalidSample="Choose a green or blue area of the screen. For an ordinary background, use Auto Background."
}

enum VideoEffectParameterSection:CaseIterable {
    case general,screen,edges,cleanPlate,background
    var title:String {switch self {case .general:return "Effect";case .screen:return "Screen";case .edges:return "Edges";case .cleanPlate:return "Clean plate";case .background:return "Background"}}
    static func sections(for effect:VideoEffectSettings,time:Double=0,live:Bool=false)->[Self] {
        allCases.filter {section in effect.parameters.contains {VideoEffectParameterVisibility.visible($0,effect:effect,time:time,live:live) && Self.section($0,effect:effect)==section}}
    }
    static func section(_ parameter:EffectParameter,effect:VideoEffectSettings)->Self {
        guard [.chromaKey,.autoBackground].contains(effect.kind) else {return .general}
        let id=parameter.id
        if id=="cleanPlate" {return .cleanPlate}
        if ["balance","blackClip","whiteClip","softness","grow","despill","wrap"].contains(id) {return .edges}
        if id.hasPrefix("background") || ["media","fit","portraitBlur","matchColor","matchStrength"].contains(id) {return .background}
        if id=="intensity" {return .general}
        return effect.kind == .autoBackground ? .general : .screen
    }
}

// Original effect definitions. Parameter IDs and units are part of the project format.
enum VideoEffectCatalog {
    static let all: [VideoEffectDescriptor] = [
        // History: Kodak Essential Reference Guide for Filmmakers, Color Timing/Color Correction.
        // https://www.kodak.com/content/products-brochures/Film/kodak-essential-reference-guide-for-filmmakers.pdf
        VideoEffectDescriptor(id: .rgbOffset, displayName: "RGB Offset", historyNote: "Color dye-transfer printing aligned three separate matrices to register the color image.", family: .color, mode: .both, parameters:
            RGBChannel.allCases.flatMap { channel in
                [EffectParameter(channel.x, channel.name + " X", .slider(min: -1, max: 1, defaultValue: 0, step: 0.001)),
                 EffectParameter(channel.y, channel.name + " Y", .slider(min: -1, max: 1, defaultValue: 0, step: 0.001))]
            }),
        VideoEffectDescriptor(id: .negativeStrobe, displayName: "Negative Strobe", historyNote: "Experimental flicker films of the 1960s intercut positive and negative images.", family: .color, mode: .both, parameters: [
            EffectParameter("frequency", "Cycles per second", .stepper(values: [1, 2, 4, 6, 8, 10, 12, 15], defaultValue: 8)),
            EffectParameter("timedBurst", "Limit duration", .toggle(defaultValue: false), animatable: false),
            EffectParameter("burstLength", "Burst length (s)", .slider(min: 0.1, max: 10, defaultValue: 1, step: 0.05), animatable: false)
        ]),
        VideoEffectDescriptor(id: .nightFix, displayName: "Night fix", historyNote: "Digital film restoration combines motion-aligned frames to separate image detail from noise before correcting exposure.", family: .color, mode: .edit, parameters: [
            EffectParameter("mode", "Mode", .picker(options: NightFixMode.allCases.map(\.rawValue), defaultValue: "Fast"), animatable: false),
            EffectParameter("brightness", "Shadow brightness", .slider(min: 0, max: 8, defaultValue: 2.5, step: 0.1)),
            EffectParameter("reduction", "Noise reduction", .slider(min: 0, max: 3, defaultValue: 1, step: 0.05)),
            EffectParameter("detail", "Preserve detail", .slider(min: 0, max: 1, defaultValue: 0.5, step: 0.05))
        ]),
        VideoEffectDescriptor(id: .colorCorrection, displayName: "Color Correction", historyNote: "Film laboratories balanced each scene with color timing; digital grading added precise control of contrast and individual tones.", family: .color, mode: .both, parameters: [
            EffectParameter("exposure", "Exposure", .slider(min: -4, max: 4, defaultValue: 0, step: 0.05)),
            EffectParameter("contrast", "Contrast", .slider(min: 0.25, max: 2, defaultValue: 1, step: 0.01)),
            EffectParameter("shadows", "Shadows", .slider(min: -1, max: 1, defaultValue: 0, step: 0.01)),
            EffectParameter("highlights", "Highlights", .slider(min: -1, max: 1, defaultValue: 0, step: 0.01)),
            EffectParameter("blacks", "Blacks", .slider(min: -1, max: 1, defaultValue: 0, step: 0.01)),
            EffectParameter("whites", "Whites", .slider(min: -1, max: 1, defaultValue: 0, step: 0.01)),
            EffectParameter("pivot", "Contrast pivot", .slider(min: 0.1, max: 0.9, defaultValue: 0.5, step: 0.01)),
            EffectParameter("temperature", "Temperature", .slider(min: -1, max: 1, defaultValue: 0, step: 0.01)),
            EffectParameter("tint", "Tint", .slider(min: -1, max: 1, defaultValue: 0, step: 0.01)),
            EffectParameter("saturation", "Saturation", .slider(min: 0, max: 2, defaultValue: 1, step: 0.01)),
            EffectParameter("vibrance", "Vibrance", .slider(min: -1, max: 1, defaultValue: 0, step: 0.01)),
            EffectParameter("hue", "Hue", .slider(min: -180, max: 180, defaultValue: 0, step: 1))
        ]),
        VideoEffectDescriptor(id: .silentTint, displayName: "Silent Tint", historyNote: "Silent cinema used tinting and toning to color whole shots and suggest mood or time of day.", family: .color, mode: .both, parameters: [
            EffectParameter("tint", "Tint", .picker(options: ["Night Blue", "Amber", "Fire Red", "Nature Green", "Sepia"], defaultValue: "Amber")),
            EffectParameter("mode", "Process", .picker(options: ["Tint", "Tone"], defaultValue: "Tint")),
            EffectParameter("contrast", "Contrast", .slider(min: 0.8, max: 1.4, defaultValue: 1.15, step: 0.01))
        ]),
        VideoEffectDescriptor(id: .threeStrip, displayName: "Three-Strip", historyNote: "Three-strip dye-transfer printing layered cyan, yellow and magenta dyes to create rich cinema color.", family: .color, mode: .both, parameters: [
            EffectParameter("saturation", "Saturation", .slider(min: 1, max: 1.8, defaultValue: 1.4, step: 0.01)),
            EffectParameter("redDepth", "Red depth", .slider(min: 0, max: 1, defaultValue: 0.6, step: 0.01)),
            EffectParameter("warmth", "Warmth", .slider(min: -1, max: 1, defaultValue: 0.2, step: 0.01))
        ]),
        VideoEffectDescriptor(id: .bleachBypass, displayName: "Bleach Bypass", historyNote: "Retaining silver during color-film processing produces desaturated color and dense contrast.", family: .color, mode: .both, parameters: [
            EffectParameter("strength", "Strength", .slider(min: 0, max: 1, defaultValue: 0.7, step: 0.01))
        ]),
        VideoEffectDescriptor(id: .dayForNight, displayName: "Day for Night", historyNote: "Day-for-night photography uses exposure and color filtration to make daylight scenes read as night.", family: .color, mode: .both, parameters: [
            EffectParameter("darkness", "Darkness", .slider(min: 0, max: 1, defaultValue: 0.6, step: 0.01)),
            EffectParameter("blue", "Blue", .slider(min: 0, max: 1, defaultValue: 0.7, step: 0.01)),
            EffectParameter("moonlight", "Moonlight highlights", .toggle(defaultValue: true))
        ]),
        VideoEffectDescriptor(id: .colorIsolation, displayName: "Color Isolation", historyNote: "Selective color contrasts a colored detail with monochrome surroundings, as in Rumble Fish (1983).", family: .color, mode: .both, parameters: [
            EffectParameter("mode", "Keep", .picker(options: ["A color", "The subject"], defaultValue: "A color")),
            EffectParameter("color", "Hue", .color(defaultValue: EffectRGB(hex: "#C0392B"))),
            EffectParameter("range", "Hue range", .slider(min: 5, max: 60, defaultValue: 22, step: 1)),
            EffectParameter("softness", "Softness", .slider(min: 0, max: 1, defaultValue: 0.4, step: 0.01))
        ]),
        VideoEffectDescriptor(id: .noir, displayName: "Noir", historyNote: "Film noir uses low-key lighting and strong shadows; colored lens filters also shaped black-and-white tones.", family: .color, mode: .both, parameters: [
            EffectParameter("contrast", "Contrast", .slider(min: 1, max: 2, defaultValue: 1.5, step: 0.01)),
            EffectParameter("crush", "Black crush", .slider(min: 0, max: 0.3, defaultValue: 0.12, step: 0.01)),
            EffectParameter("grain", "Grain", .toggle(defaultValue: true)),
            EffectParameter("shadowColor", "Blue shadows", .toggle(defaultValue: false))
        ]),
        VideoEffectDescriptor(id: .expressionism, displayName: "Expressionism", historyNote: "German Expressionist cinema used stylized shadows and distorted sets, notably in The Cabinet of Dr. Caligari (1920).", family: .color, mode: .both, parameters: [
            EffectParameter("contrast", "Contrast", .slider(min: 1.5, max: 3, defaultValue: 2.2, step: 0.01)),
            EffectParameter("vignette", "Vignette", .slider(min: 0, max: 1, defaultValue: 0.7, step: 0.01)),
            EffectParameter("iris", "Iris", .picker(options: ["Oval", "Circle"], defaultValue: "Oval")),
            EffectParameter("tint", "Tint", .toggle(defaultValue: false))
        ]),
        VideoEffectDescriptor(id: .quantization, displayName: "Quantization", historyNote: "Posterization reduces continuous tones to flat bands, echoing photographic silkscreen prints of the 1960s.", family: .quantization, mode: .both, parameters: [
            EffectParameter("colors", "Colors", .stepper(values: [2, 3, 4, 5, 6, 8, 12, 16], defaultValue: 4)),
            EffectParameter("monochrome", "B&W", .toggle(defaultValue: false)),
            EffectParameter("palette", "Palette", .picker(options: ["From scene", "Pop 1", "Pop 2", "Pop 3", "Saved"], defaultValue: "From scene")),
            EffectParameter("smoothing", "Smoothing", .slider(min: 0, max: 1, defaultValue: 0.5, step: 0.01)),
            EffectParameter("dithering", "Dithering", .picker(options: ["Off", "Ordered 4x4", "Ordered 8x8"], defaultValue: "Off")),
            EffectParameter("faceDetail", "Face detail", .toggle(defaultValue: true)),
            EffectParameter("lockPalette", "Lock palette", .toggle(defaultValue: false))
        ]),
        VideoEffectDescriptor(id: .dollyZoom, displayName: "Dolly Zoom", historyNote: "Opposing a camera move with zoom changes perspective while keeping the subject the same size, as in Vertigo (1958).", family: .camera, mode: .both, parameters: [
            EffectParameter("direction", "Direction", .picker(options: ["Stretch", "Compress"], defaultValue: "Stretch")),
            EffectParameter("strength", "Strength", .slider(min: 0.1, max: 0.5, defaultValue: 0.3, step: 0.01)),
            EffectParameter("duration", "Duration", .slider(min: 1, max: 5, defaultValue: 2.5, step: 0.1), animatable: false),
            EffectParameter("easing", "Easing", .picker(options: ["In-out cubic", "Linear"], defaultValue: "In-out cubic")),
            EffectParameter("targetX", "Subject X", .slider(min: 0, max: 1, defaultValue: 0.5, step: 0.01)),
            EffectParameter("targetY", "Subject Y", .slider(min: 0, max: 1, defaultValue: 0.5, step: 0.01))
        ]),
        VideoEffectDescriptor(id: .crashZoom, displayName: "Crash Zoom", historyNote: "Fast lens zooms became an expressive device in 1960s and 1970s westerns and martial-arts cinema.", family: .camera, mode: .both, parameters: [
            EffectParameter("zoom", "Zoom amount", .slider(min: 1.5, max: 4, defaultValue: 2.5, step: 0.1)),
            EffectParameter("speed", "Push duration", .slider(min: 0.1, max: 0.5, defaultValue: 0.18, step: 0.01), animatable: false),
            EffectParameter("hold", "Hold", .slider(min: 0, max: 3, defaultValue: 1, step: 0.1), animatable: false),
            EffectParameter("return", "Return", .toggle(defaultValue: false)),
            EffectParameter("motionBlur", "Motion blur", .slider(min: 0, max: 1, defaultValue: 0.6, step: 0.01)),
            EffectParameter("targetX", "Target X", .slider(min: 0, max: 1, defaultValue: 0.5, step: 0.01)),
            EffectParameter("targetY", "Target Y", .slider(min: 0, max: 1, defaultValue: 0.5, step: 0.01)),
            EffectParameter("trackFace", "Follow face", .toggle(defaultValue: true))
        ]),
        // https://www.eamesoffice.com/the-work/kaleidoscope-shop/
        VideoEffectDescriptor(id: .kaleidoscope, displayName: "Kaleidoscope", historyNote: "A camera fitted with mirrors turned ordinary workshop scenes into moving patterns in Kaleidoscope Shop (1959).", family: .camera, mode: .both, parameters: [
            EffectParameter("divisions", "Divisions", .stepper(values: [2, 3, 4, 5, 6, 7, 8, 9], defaultValue: 2)),
            EffectParameter("centerX", "Split center X", .slider(min: 0, max: 1, defaultValue: 0.5, step: 0.001)),
            EffectParameter("centerY", "Split center Y", .slider(min: 0, max: 1, defaultValue: 0.5, step: 0.001)),
            EffectParameter("splitAngle", "Split rotation", .slider(min: -180, max: 180, defaultValue: 0, step: 1)),
            EffectParameter("sourcePanX", "Source pan X", .slider(min: -1, max: 1, defaultValue: 0, step: 0.001)),
            EffectParameter("sourcePanY", "Source pan Y", .slider(min: -1, max: 1, defaultValue: 0, step: 0.001)),
            EffectParameter("sourceAngle", "Source rotation", .slider(min: -180, max: 180, defaultValue: 0, step: 1))
        ]),
        VideoEffectDescriptor(id: .widescreen, displayName: "Widescreen 1953", historyNote: "The widescreen expansion of the 1950s brought broad compositions, anamorphic flares and distinctive lens rendering.", family: .frame, mode: .both, parameters: [
            EffectParameter("ratio", "Ratio", .picker(options: ["2.39:1", "2.20:1", "1.85:1", "1.33:1"], defaultValue: "2.39:1")),
            EffectParameter("bars", "Bars", .picker(options: ["Black", "Blur fill"], defaultValue: "Black")),
            EffectParameter("flares", "Flares", .slider(min: 0, max: 1, defaultValue: 0.4, step: 0.01)),
            EffectParameter("flareColor", "Flare color", .picker(options: ["Blue", "Amber", "Neutral"], defaultValue: "Blue")),
            EffectParameter("ovalBokeh", "Oval bokeh", .toggle(defaultValue: false))
        ]),
        VideoEffectDescriptor(id: .freezeFrame, displayName: "Freeze Frame", historyNote: "A held frame can suspend a film at a decisive moment, as at the end of The 400 Blows (1959).", family: .time, mode: .edit, parameters: [
            EffectParameter("hold", "Hold duration", .slider(min: 0.5, max: 10, defaultValue: 3, step: 0.1), animatable: false),
            EffectParameter("push", "Push-in", .slider(min: 0, max: 0.15, defaultValue: 0.05, step: 0.01)),
            EffectParameter("style", "Style", .picker(options: ["Clean", "Print"], defaultValue: "Clean")),
            EffectParameter("audio", "Audio", .picker(options: ["Cut", "Continue", "Fade out over hold"], defaultValue: "Cut"))
        ]),
        VideoEffectDescriptor(id: .stepPrinting, displayName: "Step Printing", historyNote: "Repeating printed frames produces stuttering motion, combined with blur in Chungking Express (1994).", family: .time, mode: .edit, parameters: [
            EffectParameter("step", "Step frames", .stepper(values: [2, 3, 4, 5, 6], defaultValue: 3)),
            EffectParameter("smear", "Smear", .slider(min: 0, max: 1, defaultValue: 0.7, step: 0.01)),
            EffectParameter("speed", "Speed", .stepper(values: [0.5, 1], defaultValue: 1))
        ]),
        VideoEffectDescriptor(id: .undercranking, displayName: "Undercranking", historyNote: "Shooting fewer frames than the projection rate gives the quick, uneven movement associated with silent comedy.", family: .time, mode: .both, parameters: [
            EffectParameter("fps", "Frame rate", .stepper(values: [12, 16, 18], defaultValue: 16)),
            EffectParameter("speed", "Speed-up", .slider(min: 1, max: 1.5, defaultValue: 1.25, step: 0.05)),
            EffectParameter("flicker", "Flicker", .slider(min: 0, max: 1, defaultValue: 0.5, step: 0.01)),
            EffectParameter("weave", "Gate weave", .slider(min: 0, max: 1, defaultValue: 0.4, step: 0.01)),
            EffectParameter("mute", "Mute audio", .toggle(defaultValue: false))
        ]),
        VideoEffectDescriptor(id: .halation, displayName: "Halation", historyNote: "Film halation spreads warm light around bright highlights; diffusion and pre-exposure can soften contrast.", family: .texture, mode: .both, parameters: [
            EffectParameter("glow", "Glow", .slider(min: 0, max: 1, defaultValue: 0.4, step: 0.01)),
            EffectParameter("red", "Halation red", .slider(min: 0, max: 1, defaultValue: 0.5, step: 0.01)),
            EffectParameter("flash", "Shadow lift", .slider(min: 0, max: 1, defaultValue: 0.2, step: 0.01)),
            EffectParameter("flashColor", "Flash color", .picker(options: ["Neutral", "Warm", "Cool"], defaultValue: "Warm"))
        ]),
        VideoEffectDescriptor(id: .sixteenMM, displayName: "16mm", historyNote: "Lightweight 16mm cameras helped filmmakers work outside studios and became central to documentary production.", family: .texture, mode: .both, parameters: [
            EffectParameter("grain", "Grain", .slider(min: 0, max: 1, defaultValue: 0.5, step: 0.01)),
            EffectParameter("grainSize", "Grain size", .picker(options: ["Fine", "Medium", "Coarse"], defaultValue: "Medium")),
            EffectParameter("softness", "Softness", .slider(min: 0, max: 1, defaultValue: 0.3, step: 0.01)),
            EffectParameter("weave", "Gate weave", .slider(min: 0, max: 1, defaultValue: 0.2, step: 0.01)),
            EffectParameter("frameEdge", "Frame edge", .toggle(defaultValue: false)),
            EffectParameter("color", "Color", .picker(options: ["Color", "B&W"], defaultValue: "Color"))
        ]),
        VideoEffectDescriptor(id: .superEight, displayName: "Super 8", historyNote: "Introduced in 1965, the small-gauge cartridge format made home-movie filmmaking more accessible.", family: .texture, mode: .both, parameters: [
            EffectParameter("fade", "Fade", .slider(min: 0, max: 1, defaultValue: 0.5, step: 0.01)),
            EffectParameter("grain", "Grain", .slider(min: 0, max: 1, defaultValue: 0.7, step: 0.01)),
            EffectParameter("weave", "Weave", .slider(min: 0, max: 1, defaultValue: 0.5, step: 0.01)),
            EffectParameter("fps", "Frame rate", .stepper(values: [18, 24], defaultValue: 18)),
            EffectParameter("leaks", "Light leaks", .slider(min: 0, max: 1, defaultValue: 0.2, step: 0.01)),
            EffectParameter("border", "Frame border", .toggle(defaultValue: true))
        ]),
        VideoEffectDescriptor(id: .chromaKey, displayName: "Chroma Key", historyNote: "Color-difference travelling mattes separate a subject photographed against a blue or green backing.", family: .key, mode: .both, parameters: [
            EffectParameter("screenColor", "Manual screen color", .color(defaultValue: EffectRGB(hex: "#00FF00"))),
            EffectParameter("screenType", "Screen type", .picker(options: ["Auto", "Green", "Blue"], defaultValue: "Auto")),
            EffectParameter("autoScreen", "Detect green / blue screen", .toggle(defaultValue: true)),
            EffectParameter("strength", "Strength", .slider(min: 0, max: 2, defaultValue: 1, step: 0.01)),
            EffectParameter("balance", "Balance", .slider(min: 0, max: 1, defaultValue: 0.5, step: 0.01)),
            EffectParameter("blackClip", "Black clip", .slider(min: 0, max: 0.5, defaultValue: 0.05, step: 0.01)),
            EffectParameter("whiteClip", "White clip", .slider(min: 0.5, max: 1, defaultValue: 0.9, step: 0.01)),
            EffectParameter("softness", "Edge softness", .slider(min: 0, max: 1, defaultValue: 0.3, step: 0.01)),
            EffectParameter("grow", "Shrink / grow", .slider(min: -5, max: 5, defaultValue: 0, step: 0.1)),
            EffectParameter("despill", "Despill", .slider(min: 0, max: 1, defaultValue: 0.8, step: 0.01)),
            EffectParameter("wrap", "Light wrap", .slider(min: 0, max: 1, defaultValue: 0.25, step: 0.01)),
            EffectParameter("personHint", "Use person hint", .toggle(defaultValue: false)),
            EffectParameter("cleanPlate", "Clean plate", .media(image: true, video: false)),
            EffectParameter("view", "View", .picker(options: ["Result", "Matte", "Original"], defaultValue: "Result")),
            EffectParameter("background", "Background", .picker(options: ["Solid", "Image", "Video", "Blur original", "Studio", "Window"], defaultValue: "Solid")),
            EffectParameter("backgroundColor", "Background color", .color(defaultValue: EffectRGB(hex: "#20252D"))),
            EffectParameter("media", "Background media", .media(image: true, video: true)),
            EffectParameter("fit", "Framing", .picker(options: ["Fill", "Fit"], defaultValue: "Fill")),
            EffectParameter("backgroundX", "Background X", .slider(min: 0, max: 1, defaultValue: 0.5, step: 0.01)),
            EffectParameter("backgroundY", "Background Y", .slider(min: 0, max: 1, defaultValue: 0.5, step: 0.01)),
            EffectParameter("backgroundZoom", "Background zoom", .slider(min: 1, max: 4, defaultValue: 1, step: 0.05)),
            EffectParameter("backgroundBlur", "Background blur", .slider(min: 0, max: 20, defaultValue: 0, step: 1)),
            EffectParameter("backgroundBrightness", "Background brightness", .slider(min: -1, max: 1, defaultValue: 0, step: 0.01)),
            EffectParameter("backgroundAudio", "Background sound", .toggle(defaultValue: false)),
            EffectParameter("matchColor", "Match color", .toggle(defaultValue: false)),
            EffectParameter("matchStrength", "Match strength", .slider(min: 0, max: 1, defaultValue: 0.3, step: 0.01))
        ]),
        VideoEffectDescriptor(id: .autoBackground, displayName: "Auto Background", historyNote: "The travelling-matte tradition continues with a subject mask made by the camera instead of a colored screen.", family: .key, mode: .both, parameters: [
            EffectParameter("softness", "Edge softness", .slider(min: 0, max: 1, defaultValue: 0.3, step: 0.01)),
            EffectParameter("grow", "Shrink / grow", .slider(min: -5, max: 5, defaultValue: 0, step: 0.1)),
            EffectParameter("wrap", "Light wrap", .slider(min: 0, max: 1, defaultValue: 0.25, step: 0.01)),
            EffectParameter("portraitBlur", "Portrait blur", .slider(min: 0, max: 40, defaultValue: 12, step: 1)),
            EffectParameter("view", "View", .picker(options: ["Result", "Matte", "Original"], defaultValue: "Result")),
            EffectParameter("background", "Background", .picker(options: ["Solid", "Image", "Video", "Blur original", "Studio", "Window"], defaultValue: "Blur original")),
            EffectParameter("backgroundColor", "Background color", .color(defaultValue: EffectRGB(hex: "#20252D"))),
            EffectParameter("media", "Background media", .media(image: true, video: true)),
            EffectParameter("fit", "Framing", .picker(options: ["Fill", "Fit"], defaultValue: "Fill")),
            EffectParameter("backgroundX", "Background X", .slider(min: 0, max: 1, defaultValue: 0.5, step: 0.01)),
            EffectParameter("backgroundY", "Background Y", .slider(min: 0, max: 1, defaultValue: 0.5, step: 0.01)),
            EffectParameter("backgroundZoom", "Background zoom", .slider(min: 1, max: 4, defaultValue: 1, step: 0.05)),
            EffectParameter("backgroundBlur", "Background blur", .slider(min: 0, max: 20, defaultValue: 0, step: 1)),
            EffectParameter("backgroundBrightness", "Background brightness", .slider(min: -1, max: 1, defaultValue: 0, step: 0.01)),
            EffectParameter("backgroundAudio", "Background sound", .toggle(defaultValue: false)),
            EffectParameter("matchColor", "Match color", .toggle(defaultValue: false)),
            EffectParameter("matchStrength", "Match strength", .slider(min: 0, max: 1, defaultValue: 0.3, step: 0.01))
        ]),
    ]
}

// Shared display semantics for editor and recording controls. Temperature and
// tint are relative corrections, never a claim about the camera's Kelvin value.
enum ColorCorrectionControls {
    static let light = ["exposure", "contrast", "shadows", "highlights"]
    static let advanced = ["blacks", "whites", "pivot"]
    static let color = ["saturation", "vibrance", "temperature", "tint", "hue"]
    static func display(_ id:String,_ value:Double)->String {
        let value=abs(value)<0.00001 ? 0 : value
        switch id {
        case "exposure":return String(format:"%+.2f EV",value)
        case "contrast","saturation","intensity","pivot":return String(format:"%.0f%%",value*100)
        case "hue":return value.rounded()==0 ? "0°" : String(format:"%+.0f°",value)
        default:return (value*100).rounded()==0 ? "0" : String(format:"%+.0f",value*100)
        }
    }
    static func help(_ id:String)->String {switch id {
    case "exposure":return "Brightens or darkens the whole picture in stops. +1 EV doubles the light. This grades the image; it does not change the camera exposure. Highlights roll off gently. Like the other video effects, this grades HDR after the app’s SDR tone map; it cannot recover HDR headroom discarded by that map."
    case "contrast":return "Separates light and dark tones around the contrast pivot. 100% is unchanged. Color proportions are preserved."
    case "shadows":return "Raises or lowers darker tones, while keeping the black endpoint. Use Blacks to lift or deepen the very darkest areas."
    case "highlights":return "Raises or lowers brighter tones, while keeping the white endpoint. Use Whites to change the brightest areas."
    case "blacks":return "Lifts or deepens the darkest endpoint. Positive values soften black; negative values deepen black with a gentle toe."
    case "whites":return "Raises or lowers the brightest endpoint. Positive values brighten whites with a gentle roll-off."
    case "pivot":return "The tone that stays fixed as contrast changes. 50% is a middle display tone. Has no effect at 100% contrast."
    case "temperature":return "Relative white balance: negative is cooler (blue), positive is warmer (amber). Zero preserves the recorded balance; very bright whites stay white. This is not a Kelvin setting."
    case "tint":return "Relative white balance: negative adds green, positive adds magenta. Useful for correcting a color cast."
    case "saturation":return "Controls all color intensity. 100% is unchanged; 0% is black and white."
    case "vibrance":return "Adjusts muted colors more than already vivid ones. Positive adjustments are gentler on common skin hues."
    case "hue":return "Rotates all colors around the color wheel, preserving luminance. Zero preserves the original hues."
    default:return "Blends this correction with its input. 100% applies the full correction; 0% bypasses it."
    }}
}
