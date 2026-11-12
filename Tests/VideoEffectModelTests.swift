import Foundation
import simd

@main struct VideoEffectModelTests {
    static func main() throws {
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws { if !condition() { throw NSError(domain: "VideoEffects", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) } }
        try check(VideoEffectCatalog.all.count == VideoEffectID.allCases.count, "Every effect has a catalog entry")
        for id in VideoEffectID.allCases {
            let effect = VideoEffectSettings(id)
            try check(effect.valid, "Valid defaults: \(id)")
            let copy = try JSONDecoder().decode(VideoEffectSettings.self, from: JSONEncoder().encode(effect))
            try check(copy == effect && copy.valid, "Typed parameter round trip: \(id)")
        }
        try check(Set(VideoEffectID.allCases.map(\.shaderIndex)) == Set(0...24).subtracting([10]),"Unique Metal effect IDs without the removed rotation shader")
        try check(ColorCorrectionControls.display("tint",-0.004)=="0" && ColorCorrectionControls.display("hue",-0.2)=="0°","Interpolated near-neutral values never display negative zero")
        var strobe = VideoEffectSettings(.negativeStrobe, start: 3, end: 9)
        strobe.set("frequency", .number(15))
        for frame in [0, 1, 2, 25, 15, 4, 3] {
            try check(strobe.strobeShowsNegative(at: 3 + Double(frame)/30, fps: 30) == !frame.isMultiple(of: 2),
                      "Alternating frames stay in phase after backward seeks")
        }
        strobe.set("timedBurst", .toggle(true)); strobe.set("burstLength", .number(0.1))
        try check(!strobe.strobeShowsNegative(at: 3.1, fps: 30), "Timed burst ends exactly at its boundary")
        strobe.phaseOffset = 0.1
        try check(!strobe.strobeShowsNegative(at: 3.04, fps: 30), "Later clips do not restart a timed burst")
        strobe.phaseOffset = nil; strobe.set("timedBurst", .toggle(false))
        strobe.strobeTimeMap = [.init(source: 3, elapsed: 0), .init(source: 5, elapsed: 1)]
        let fast = try JSONDecoder().decode(VideoEffectSettings.self, from: JSONEncoder().encode(strobe))
        try check(fast.valid && fast.strobeShowsNegative(at: 3+2.0/30, fps: 30), "Two-times footage uses playback seconds after saving")
        strobe.strobeTimeMap = nil
        let hz = strobe.parameters.firstIndex { $0.id == "frequency" }!
        strobe.parameters[hz].setKeyframe(at: 3, value: .number(4))
        strobe.parameters[hz].setKeyframe(at: 3.2, value: .number(8))
        try check(strobe.strobeShowsNegative(at: 3.21, fps: 30) && !strobe.strobeShowsNegative(at: 3.24, fps: 30), "Rate changes preserve accumulated phase")
        var split = VideoEffectSettings(.kaleidoscope)
        let angle = split.parameters.firstIndex { $0.id == "splitAngle" }!
        split.parameters[angle].setKeyframe(at: 0, value: .number(170))
        split.parameters[angle].setKeyframe(at: 1, value: .number(-170))
        try check(split.number("splitAngle", at: 0.5) == -180, "Animating across the angle boundary takes the short arc")
        let count = split.parameters.firstIndex { $0.id == "divisions" }!
        split.parameters[count].setKeyframe(at: 0, value: .number(2))
        split.parameters[count].setKeyframe(at: 1, value: .number(9))
        try check(split.number("divisions", at: 0.99) == 2 && split.number("divisions", at: 1) == 9, "Animated divisions change in whole wedges")
        var previousSplit = split
        previousSplit.parameters.removeAll { ["sourcePanX", "sourcePanY", "sourceAngle"].contains($0.id) }
        let upgraded = try JSONDecoder().decode(VideoEffectSettings.self, from: JSONEncoder().encode(previousSplit))
        try check(upgraded == split && upgraded.valid, "Existing Kaleidoscope edits reopen with neutral source pan and rotation")
        let pan = split.parameters.firstIndex { $0.id == "sourcePanX" }!
        split.parameters[pan].setKeyframe(at: 0, value: .number(-0.4))
        split.parameters[pan].setKeyframe(at: 1, value: .number(0.8))
        var oldPanned = split
        oldPanned.parameters.removeAll { $0.id == "sourceAngle" }
        let reopened = try JSONDecoder().decode(VideoEffectSettings.self, from: JSONEncoder().encode(oldPanned))
        try check(reopened == split, "An existing panned take keeps its framing with zero source rotation")
        let turn = split.parameters.firstIndex { $0.id == "sourceAngle" }!
        split.parameters[turn].setKeyframe(at: 0, value: .number(-160))
        split.parameters[turn].setKeyframe(at: 1, value: .number(140))
        let savedSplit = try JSONDecoder().decode(VideoEffectSettings.self, from: JSONEncoder().encode(split))
        try check(savedSplit.number("sourceAngle", at: 0.5) == 170 && savedSplit.number("splitAngle", at: 0.5) == -180,
                  "Independent source and split rotations animate along their own short arcs")
        try check(abs(savedSplit.number("sourcePanX", at: 0.5)-0.2) < 1e-9 && savedSplit.number("centerX", at: 0.5) == 0.5,
                  "Source pan animates independently of the split after reopening")
        let testSize = CGSize(width: 320, height: 180), pivot = CGPoint(x: 0.42, y: 0.63)
        for n in 2...9 {
            let span = 2 * Double.pi / Double(n), axis = -53.0 * Double.pi / 180
            for sector in 0..<n {
                let theta = axis + (Double(sector) + 0.27) * span
                let start = CGPoint(x: pivot.x + 40*cos(theta)/testSize.width, y: pivot.y + 40*sin(theta)/testSize.height)
                let transform = kaleidoscopeDragTransform(start: start, center: pivot, size: testSize, angle: 37, divisions: n, sourceAngle: 73)
                let mirrored = n.isMultiple(of: 2) && !sector.isMultiple(of: 2)
                let sourceAngle = axis + (mirrored ? 0.73 : 0.27) * span - 73 * Double.pi / 180
                let radial = CGPoint(x: cos(theta), y: sin(theta)).applying(transform)
                let tangent = CGPoint(x: -sin(theta), y: cos(theta)).applying(transform)
                let sign = mirrored ? -1.0 : 1.0
                try check(hypot(radial.x-cos(sourceAngle), radial.y-sin(sourceAngle)) < 1e-9 &&
                          hypot(tangent.x+sign*sin(sourceAngle), tangent.y-sign*cos(sourceAngle)) < 1e-9,
                          "Dragging the touched copy follows the finger in sector \(sector) of \(n)")
            }
        }
        let correction=VideoEffectSettings(.colorCorrection)
        try check(correction.parameters.allSatisfy { $0.animatable },"Every correction control supports keyframes")
        let order=VideoEffectSettings.ordered([.init(.silentTint),correction,.init(.noir),.init(.chromaKey)])
        try check(order.map(\.kind)==[.chromaKey,.colorCorrection,.silentTint,.noir],"Correction precedes looks without changing their relative order")
        try check(Set(ColorCorrectionControls.light+ColorCorrectionControls.advanced+ColorCorrectionControls.color)==Set(correction.kind.descriptor.parameters.map(\.id)),"Every correction knob appears exactly once in its inspector")
        var animated=correction
        let exposure=animated.parameters.firstIndex {$0.id=="exposure"}!
        animated.parameters[exposure].setKeyframe(at:0,value:.number(-1));animated.parameters[exposure].setKeyframe(at:2,value:.number(1))
        let animatedCopy=try JSONDecoder().decode(VideoEffectSettings.self,from:JSONEncoder().encode(animated))
        try check(animatedCopy.number("exposure",at:1)==0 && animatedCopy==animated,"Correction animation survives save/reopen with source-time interpolation")
        struct SavedEffects: Decodable { var videoEffects: [VideoEffectSettings]? }
        let known = VideoEffectSettings(.silentTint)
        let item = try JSONSerialization.jsonObject(with: JSONEncoder().encode(known))
        let mixed: [Any] = [["kind":"dutchAngle"], item, ["kind":"futureEffect", "parameters":"unrecognized layout"]]
        let recipe = try JSONDecoder().decode(SupportedVideoEffects.self, from: JSONSerialization.data(withJSONObject: mixed))
        try check(recipe.values == [known], "Unknown effects are skipped without discarding recognized neighbors")
        let nested = try JSONDecoder().decode(SavedEffects.self, from: JSONSerialization.data(withJSONObject: ["videoEffects":mixed]))
        try check(nested.videoEffects == [known], "Synthesized project-field decoding skips unknown effects")
        let empty = try JSONDecoder().decode(SavedEffects.self, from: Data("{\"videoEffects\":[{\"kind\":\"futureEffect\"}]}".utf8))
        try check(empty.videoEffects?.isEmpty == true, "An entirely unknown stack becomes empty")
        for kind in VideoEffectID.allCases {
            var candidate=VideoEffectSettings(kind);candidate.algorithm=2
            let supported=[VideoEffectID.colorIsolation,.chromaKey].contains(kind)
            try check(candidate.valid==supported && candidate.usesTemporalMatte==supported,"Temporal matte version is accepted only by the techniques that implement it")
            if supported {
                let copy=try JSONDecoder().decode(VideoEffectSettings.self,from:JSONEncoder().encode(candidate))
                try check(copy.algorithm==2 && copy.valid && copy.usesModernPersonMask && !copy.usesAutoMaskStream,"Temporal recipes preserve their version and raw-person-mask routing")
            }
        }
        for kind in [VideoEffectMatteKind.isolation,.key] {
            for fps in [24.0,30,60,240] {
                let times=(0..<100).map {Double($0)/fps}
                let window=VideoEffectTemporalWindow.make(times:times,at:times[60],start:0,kind:kind)!
                try check(window.indices.count==kind.capacity && abs(window.weights.reduce(0,+)-1)<1e-12 && window.tailBound<0.001,"Temporal matte windows bound their EMA tail at every source rate")
                let raw=window.indices.map {Double(($0*17)%29)/28}
                let recursive=raw.dropFirst().reduce(raw[0]) {$0*kind.prior+$1*(1-kind.prior)}
                try check(abs(zip(raw,window.weights).map(*).reduce(0,+)-recursive)<1e-12,"Finite-window weights equal an EMA initialized at the oldest source frame")
                let beginning=VideoEffectTemporalWindow.make(times:times,at:times[61],start:times[60]+0.001,kind:kind)!
                try check(beginning.indices==[60,61] && beginning.tailBound==0,"A mid-frame effect starts on the frame already displayed")
                let cut=VideoEffectTemporalWindow.make(times:times,at:times[61],start:0,kind:kind,cuts:[60])!
                try check(cut.indices==[60,61] && cut.tailBound==0,"An internal scene cut closes the temporal window")
            }
            let gapTimes=[0.0,0.03,0.08,0.6,0.64]
            let gap=VideoEffectTemporalWindow.make(times:gapTimes,at:0.64,start:0,kind:kind)!
            try check(gap.indices==[3,4] && gap.tailBound==0,"A capture discontinuity resets the matte history")
        }
        let sections = VideoEffectLibrarySection.allCases
        try check(sections == [.colorStyle, .cameraFrame, .time, .background], "The library opens on the four effect categories")
        for live in [false, true] {
            let available = sections.flatMap { $0.effects(live: live).map(\.id) }
            let expected = VideoEffectID.allCases.filter { !live || $0.descriptor.mode != .edit }
            try check(available.count == expected.count && Set(available) == Set(expected), "Every available individual effect appears exactly once")
        }
        // Previously applied Silent Era looks were stored as four ordinary effects.
        var tint = VideoEffectSettings(.silentTint)
        tint.set("tint", .choice("Night Blue"))
        let savedStack = [VideoEffectSettings(.expressionism), tint, VideoEffectSettings(.sixteenMM), VideoEffectSettings(.undercranking)]
        let decodedStack = try JSONDecoder().decode(SupportedVideoEffects.self, from: JSONEncoder().encode(savedStack))
        try check(decodedStack.values == savedStack, "Saved component effects retain their order, identities and settings")
        for live in [false,true] {
            let key=VideoEffectSettings(.chromaKey)
            try check(key.parameters.filter {VideoEffectParameterVisibility.visible($0,effect:key,live:live)}.allSatisfy {!["fit","backgroundX","backgroundY","backgroundZoom","media","matchStrength"].contains($0.id)},"Solid backgrounds hide irrelevant framing and color-match controls in both inspectors")
            var isolation=VideoEffectSettings(.colorIsolation);isolation.set("mode",.choice("The subject"))
            try check(isolation.parameters.filter {VideoEffectParameterVisibility.visible($0,effect:isolation,live:live)}.allSatisfy {!["color","range"].contains($0.id)},"Subject isolation hides color selection in both inspectors")
        }
        for live in [false,true] {
            func visible(_ id:String,_ e:VideoEffectSettings)->Bool {VideoEffectParameterVisibility.visible(e.parameters.first {$0.id==id}!,effect:e,live:live)}
            var key=VideoEffectSettings(.chromaKey)
            try check(!key.toggle("personHint") && !visible("screenColor",key),"New keys do not imply automatic person cutout or show an ignored manual color")
            key.set("autoScreen",.toggle(false))
            try check(visible("screenColor",key) && !visible("screenType",key),"Manual key infers screen type from a supported green/blue sample")
            key.set("cleanPlate",.media("plate.png"))
            try check(!visible("screenColor",key) && !visible("autoScreen",key),"A clean plate replaces the color reference")
            var bg=VideoEffectSettings(.autoBackground)
            try check(!visible("backgroundBlur",bg) && visible("portraitBlur",bg),"Original blur has one meaningful radius control")
            bg.set("background",.choice("Image"))
            try check(visible("media",bg) && !visible("fit",bg) && !visible("backgroundBrightness",bg),"Media controls wait for a real image")
            bg.set("media",.media("picture.png"))
            try check(visible("fit",bg) && visible("backgroundBrightness",bg),"Imported backgrounds expose their controls")
            var crash=VideoEffectSettings(.crashZoom)
            try check(!visible("hold",crash) && !visible("targetX",crash),"A non-returning tracked zoom hides ineffective hold and manual target controls")
            crash.set("return",.toggle(true));crash.set("trackFace",.toggle(false))
            try check(visible("hold",crash) && (visible("targetX",crash) == !live),"Returning/manual zoom exposes its active controls")
            crash.releaseTime=2
            try check(!visible("return",crash) && !visible("hold",crash),"Recorded manual return owns its timing; ignored automatic controls stay hidden")
            var quant=VideoEffectSettings(.quantization)
            let palette=quant.parameters.first {$0.id=="palette"}!
            try check(!VideoEffectParameterVisibility.choices(palette,effect:quant).contains("Saved"),"Saved cannot be selected before a palette exists")
            quant.palette=[EffectRGB(0,0,0),EffectRGB(1,1,1)]
            try check(VideoEffectParameterVisibility.choices(palette,effect:quant).contains("Saved"),"Saved palettes remain selectable")
        }
        try check(ChromaScreen.accepts(EffectRGB(0,1,0)) && ChromaScreen.accepts(EffectRGB(0,0,1)),"Green and blue screen samples are supported")
        try check(!ChromaScreen.accepts(EffectRGB(0.8,0.75,0.65)) && !ChromaScreen.accepts(EffectRGB(1,0,0)) && !ChromaScreen.accepts(EffectRGB(0.5,0.5,0.5)),"Beige, red and neutral screen samples cannot silently select an unsupported key")
        for hue in [0.0,60,120,180,240,300,359] {
            let color=IsolationHue.color(hue)
            try check(IsolationHue.accepts(color) && abs(IsolationHue.degrees(color)-hue)<0.0001,"Hue controls offer only meaningful chromatic targets")
        }
        try check(!IsolationHue.accepts(EffectRGB(0,0,0)) && !IsolationHue.accepts(EffectRGB(1,1,1)) && !IsolationHue.accepts(EffectRGB(0.5,0.5,0.5)),"Neutral samples must not silently isolate red")
        var parameter = EffectParameter("value", "Value", .slider(min: 0, max: 1, defaultValue: 0, step: 0.01))
        parameter.setKeyframe(at: 1, value: .number(0)); parameter.setKeyframe(at: 3, value: .number(1))
        try check(parameter.value(at: 2) == .number(0.5) && parameter.valid, "Continuous interpolation")
        parameter.setKeyframe(at: 2, value: .number(99)); try check(parameter.keyframes.count == 2, "Reject out-of-range keyframes")
        var categorical = EffectParameter("mode", "Mode", .picker(options: ["A", "B"], defaultValue: "A"))
        categorical.setKeyframe(at: 0, value: .choice("A")); categorical.setKeyframe(at: 2, value: .choice("B"))
        try check(categorical.value(at: 1.99) == .choice("A") && categorical.value(at: 2) == .choice("B"), "Categorical keyframes hold until their time")
        let chain = VideoEffectSettings.ordered([.init(.widescreen), .init(.sixteenMM), .init(.noir), .init(.chromaKey)])
        try check(chain.map(\.kind) == [.chromaKey, .noir, .sixteenMM, .widescreen], "Fixed pipeline order")
        var invalid = VideoEffectSettings(.noir); invalid.parameters[0].kind = .slider(min: -100, max: 100, defaultValue: 0, step: 1)
        try check(!invalid.valid, "Documents cannot redefine parameter bounds")
        let canonical=try JSONDecoder().decode(VideoEffectSettings.self,from:JSONEncoder().encode(invalid))
        try check(canonical.valid && canonical.parameters[0].kind==VideoEffectSettings(.noir).parameters[0].kind,"Decoded parameter metadata comes from the installed catalogue")
        var old=VideoEffectSettings(.undercranking)
        old.parameters[old.parameters.firstIndex(where:{$0.id=="speed"})!].animatable=false
        let migrated=try JSONDecoder().decode(VideoEffectSettings.self,from:JSONEncoder().encode(old))
        try check(migrated.valid && migrated.parameters.first(where:{$0.id=="speed"})!.animatable,"Catalogue animation upgrades preserve old projects")
        for rgb in [SIMD3<Double>(0.1,0.4,0.8), SIMD3<Double>(1,0,0), SIMD3<Double>(0.25,0.25,0.25)] {
            try check(simd_distance(rgb, EffectColorMath.linearFromLab(EffectColorMath.lab(rgb))) < 0.000001, "Oklab round trip")
        }
        let samples = (0..<2304).map { i in SIMD3<Double>(Double(i % 64)/63, Double(i / 64)/35, 0.1) }
        let a = EffectPaletteAnalysis.analyze(samples, count: 4, seed: 23), b = EffectPaletteAnalysis.analyze(samples, count: 4, seed: 23)
        try check(a == b && a.colors.count == 4, "Deterministic palette sampling")
        let flat = EffectPaletteAnalysis.analyze(Array(repeating: SIMD3<Double>(repeating: 0.25), count: 60), count: 3)
        let lights = [SIMD3<Double>(1,0,0), SIMD3<Double>(0,1,0), SIMD3<Double>(0,0,1)]
        let colored = EffectPaletteAnalysis.analyze(lights, count: 3, previous: flat)
        for light in lights {
            let expected = EffectColorMath.prepared(light)
            try check(colored.colors.contains { simd_distance(EffectColorMath.linear($0), expected) < 0.005 }, "A neutral opening frame must not trap color clusters")
        }
        let dark = (0..<100).map { SIMD3<Double>(repeating: Double($0)/1000) }
        try check(EffectPaletteAnalysis.analyze(dark, count: 2).thresholds[0] < 0.1, "B&W threshold follows scene median, not 0.5")
        for fps in [12.0,16,18,24] {
            let indices = Set((0..<30).map { VideoEffectTime.heldTime(Double($0)/30, fps: fps) })
            try check(indices.count == Int(fps), "Exact \(fps)fps cadence at 30fps output")
        }
        var super8=VideoEffectSettings(.superEight,start:0,end:4),under=VideoEffectSettings(.undercranking,start:0,end:4)
        under.set("speed",.number(1))
        for fps in [30.0,60] {
            let cadence=VideoEffectCadenceClock(effects:[super8])
            var previous = -1,held=0.0
            for frame in 0..<Int(fps*4) {
                let time=Double(frame)/fps,hold=cadence.hold(at:time)!
                if hold.index != previous {held=time;previous=hold.index}
                let selected=VideoEffectTime.firstFrame(atOrAfter:hold.boundary,fps:fps)
                try check(abs(selected-held)<0.00001,"Super 8 export chooses the same first source frame as live capture at \(fps)fps")
            }
        }
        for fps in [12.0,16,18] {
            var effect=under;effect.end=12;effect.set("fps",.number(fps))
            let clock=VideoEffectCadenceClock(effects:[effect])
            for frame in 0..<300 {
                let nominal=Double(frame)/30
                let jitter=frame==0 ? 0 : (frame.isMultiple(of:2) ? 0.00004 : -0.00004)-Double(frame)*0.00000000033
                let live=VideoEffectTime.captureTime(nominal+jitter)
                let file=VideoEffectTime.captureTime(nominal)
                try check(clock.hold(at:live)!.index==clock.hold(at:file)!.index && VideoEffectTime.frameIndex(live,fps:30)==VideoEffectTime.frameIndex(file,fps:30),"Camera clock jitter cannot change held frames or grain seeds")
            }
        }
        let fpsIndex=super8.parameters.firstIndex(where:{$0.id=="fps"})!
        super8.parameters[fpsIndex].setKeyframe(at:0,value:.number(24))
        super8.parameters[fpsIndex].setKeyframe(at:1.37,value:.number(18))
        let rates:[(start:Double,end:Double,rate:Double)]=(0..<40).map { index in
            let t=Double(index);return (t/10,(t+1)/10,1+t/80)
        }
        for effects in [[super8],[super8,under],[under,super8]] {
            let clock=VideoEffectCadenceClock(effects:effects,rates:rates)
            var lastIndex = -1,lastTime = -1.0
            for frame in 0..<240 {
                let time=Double(frame)/60,hold=clock.hold(at:time)!
                try check(hold.index>=lastIndex && hold.boundary>=lastTime-0.00001 && hold.boundary<=time+0.00001,"Animated cadence and speed never rewind the chosen frame")
                lastIndex=hold.index;lastTime=hold.boundary
            }
        }
        let combined=VideoEffectCadenceClock(effects:[super8,under])
        let single=VideoEffectCadenceClock(effects:[under])
        for frame in 0..<120 {
            let t=Double(frame)/30
            try check(abs(combined.hold(at:t)!.boundary-single.hold(at:t)!.boundary)<0.00001,"The slower cadence governs a combined look independently of enabling order")
        }
        let first = VideoEffectTime.dollyTarget(zoom: 1, referenceHeight: 0.4, observedHeight: 0.2, range: 1...4)
        let settled = VideoEffectTime.dollyTarget(zoom: first, referenceHeight: 0.4, observedHeight: 0.4, range: 1...4)
        try check(first == 2 && settled == 2, "Dolly controller does not undo its zoom when subject height settles")
        var late=VideoEffectSettings(.crashZoom,start:3,end:8);late.releaseTime=6
        let trimmed=VideoEffectSettings.capturedRecipe([late],duration:4)
        try check(trimmed.count==1 && trimmed[0].valid && trimmed[0].end==4 && trimmed[0].releaseTime==nil,"Stopping mid-move retains a valid recipe")
        try check(VideoEffectSettings.capturedRecipe([late],duration:2).isEmpty,"A trigger beyond the saved take never invalidates the recording")
        late.start=0;late.phaseOffset=2;late.releaseTime = -0.1
        try check(late.valid,"A carried manual return can begin before the take")
        var editable=VideoEffectSettings(.crashZoom,start:1,end:2);editable.phaseOffset=0
        editable.set("return",.toggle(true));editable.set("speed",.number(0.5));editable.set("hold",.number(3))
        editable.refreshCapturedCrashEnd(limit:8)
        try check(abs(editable.end-5.08)<0.000001 && editable.valid,"Extending captured crash timing does not clip its return")
        editable.set("return",.toggle(false));editable.refreshCapturedCrashEnd(limit:7)
        try check(editable.end==7,"Turning off automatic return holds until the next trigger or clip end")
        editable.releaseTime=3;editable.refreshCapturedCrashEnd(limit:7)
        try check(editable.end==3.5,"A manual return follows the edited push duration")
        let capturedMove=editable
        editable.retimeCapturedCrash(after:capturedMove,limit:2)
        try check(editable==capturedMove,"Opening a split captured move preserves its saved timing and downstream analysis")
        editable.set("amount",.number(3));editable.retimeCapturedCrash(after:capturedMove,limit:2)
        try check(editable.end==capturedMove.end,"Changing framing does not implicitly shorten a captured move")
        let beforeTiming=editable
        editable.set("speed",.number(0.3));editable.retimeCapturedCrash(after:beforeTiming,limit:7)
        try check(editable.end==3.3,"An explicit timing edit refreshes a captured return")
        for latency in 0...4 {
            var follower=DollyZoomFollower(referenceHeight:0.25,zoom:1,range:1...4,time:0)
            var commands=[Double](repeating:1,count:300)
            for frame in 1..<300 {
                let time=Double(frame)/30,measuredFrame=max(0,frame-latency)
                let distance=1+min(4,Double(measuredFrame)/30)*0.2
                if frame.isMultiple(of:2) { follower.observe(height:0.25/distance*commands[measuredFrame],appliedZoom:commands[measuredFrame],time:Double(measuredFrame)/30) }
                commands[frame]=follower.value(at:time)
            }
            try check(abs(follower.zoom-1.8)<0.01,"Dolly follower converges with delayed measurements")
            let before=follower.zoom
            for frame in 300..<350 { _=follower.value(at:Double(frame)/30) }
            try check(abs(follower.zoom-before)<0.01,"Lost subject eases to a hold without resetting framing")
        }
        let history=CaptureZoomHistory();history.record(time:1,zoom:1,lens:"main");history.record(time:1.1,zoom:1.5,lens:"main")
        try check(history.frame(at:1.15)?.zoom==1 && history.frame(at:1.2)?.zoom==1.5,"Frame zoom lookup accounts for ISP delay")
        history.record(time:1.3,zoom:1,lens:"front")
        try check(history.frame(at:1.31)?.lens=="front" && history.frame(at:1.31)?.zoom==1,"Switching lens clears stale zoom history")
        // A short digital move can start and end within the hardware's latency.
        // Frames can reach the compositor after all of these commands were issued.
        let pinch = CaptureZoomHistory()
        pinch.record(time: 10, zoom: 1, lens: "main")
        pinch.record(time: 10.02, zoom: 1, lens: "main", selectedZoom: 1.4, manualCenter: .init(x: 0.54, y: 0.5))
        pinch.record(time: 10.05, zoom: 1, lens: "main", selectedZoom: 1.1, manualCenter: CameraFraming.middle)
        pinch.record(time: 10.07, zoom: 1, lens: "main")
        try check(pinch.frame(at: 10.05)?.selectedZoom == 1.1, "An exposed frame keeps its own manual crop")
        for time in [10.07, 10.09, 10.12] {
            let frame = pinch.frame(at: time)
            try check(frame != nil && frame?.selectedZoom == nil && frame?.manualCenter == nil,
                      "A completed pinch must never reapply a previous crop after reaching one X")
        }
        for actualDelay in 0...4 {
            var follower=DollyZoomFollower(referenceHeight:0.25,zoom:1,range:1...4,time:0)
            var commands=[Double](repeating:1,count:300)
            for frame in 1..<300 {
                let measured=max(0,frame-(frame%3+1)),actual=max(0,measured-actualDelay),estimated=max(0,measured-2)
                let distance=1+min(4,Double(measured)/30)*0.2
                if frame.isMultiple(of:2) && !frame.isMultiple(of:22) {
                    follower.observe(height:0.25/distance*commands[actual],appliedZoom:commands[estimated],time:Double(measured)/30)
                }
                commands[frame]=follower.value(at:Double(frame)/30)
            }
            try check(abs(commands[180]-1.8)<0.02 && commands.max()!<1.8*1.03,"Dolly feedback remains stable with delayed, jittered and dropped Vision samples and a two-frame ISP error")
        }
        for kind in [VideoEffectID.colorIsolation,.chromaKey] {
            let current=VideoEffectSettings(kind)
            try check(current.algorithm==2 && current.usesTemporalMatte,"New key and isolation recipes enable validated temporal processing")
            for version in [Int?.none,1] {
                var value=try JSONSerialization.jsonObject(with:JSONEncoder().encode(current)) as! [String:Any]
                if let version {value["algorithm"]=version} else {value.removeValue(forKey:"algorithm")}
                let restored=try JSONDecoder().decode(VideoEffectSettings.self,from:JSONSerialization.data(withJSONObject:value))
                try check(restored.algorithm==version && !restored.usesTemporalMatte && restored.valid,"Existing recipes keep their original spatial processing after reopening")
            }
        }
        let modern=VideoEffectSettings(.autoBackground)
        var legacyJSON=try JSONSerialization.jsonObject(with:JSONEncoder().encode(modern)) as! [String:Any]
        legacyJSON.removeValue(forKey:"algorithm")
        let legacy=try JSONDecoder().decode(VideoEffectSettings.self,from:JSONSerialization.data(withJSONObject:legacyJSON))
        try check(modern.algorithm==1 && legacy.algorithm==nil && legacy.valid,"Absent algorithm version preserves legacy recipes instead of silently enabling new processing")
        var placement=VideoEffectBackgroundPlacement(canvas:CGSize(width:1080,height:1080),media:CGSize(width:1920,height:1080),fill:true)
        placement.apply(.pan(CGPoint(x:0.1,y:0.2)))
        try check(abs(placement.x-(0.5-0.1/(16.0/9-1)))<1e-9 && placement.y==0.5,"Fill dragging follows the finger and locks the axis with no overflow")
        placement.apply(.pan(CGPoint(x:100,y:-100)))
        try check(placement.x==0 && placement.y==0.5,"Background drag clamps at image edges")
        var fit=VideoEffectBackgroundPlacement(canvas:CGSize(width:1080,height:1080),media:CGSize(width:1920,height:1080),fill:false)
        fit.apply(.pan(CGPoint(x:0.1,y:0.1)))
        try check(fit.x==0.5 && abs(fit.y-(0.5+0.1/(1-9.0/16)))<1e-9,"Fit positioning moves inside the letterbox without exposing outside the canvas")
        var anchored=VideoEffectBackgroundPlacement(zoom:2,canvas:CGSize(width:1000,height:1000),media:CGSize(width:1000,height:1000),fill:true)
        anchored.apply(.pinch(factor:1.5,from:CGPoint(x:0.3,y:0.7),to:CGPoint(x:0.35,y:0.65)))
        let imageX=(0.3+0.5)/2,imageY=(0.7+0.5)/2
        try check(abs(-2*anchored.x+imageX*3-0.35)<1e-9 && abs(-2*anchored.y+imageY*3-0.65)<1e-9,"Off-center pinch keeps the same image point under the moving fingers")
        anchored.apply(.pinch(factor:0.01,from:CGPoint(x:0.5,y:0.5),to:CGPoint(x:0.5,y:0.5)))
        try check(anchored.zoom==1 && anchored.movementLocked,"Background cannot shrink below Fit/Fill minimum")
        var locked=VideoEffectBackgroundPlacement(x:0.2,y:0.3,canvas:CGSize(width:100,height:100),media:CGSize(width:100,height:100),fill:true)
        locked.apply(.pan(CGPoint(x:0.1,y:0.2)))
        try check(locked.x==0.2 && locked.y==0.3,"Locked axes preserve latent positioning values for later zoom keyframes")
        var budget=VideoEffectLiveBudget()
        for _ in 0..<120 {budget.observe(gpu:0.009,wall:0.02,sourceLongSide:1920,renderLongSide:1920)}
        try check(budget.quality == .full && budget.maximumLongSide==nil,"Affordable live looks retain full resolution")
        for i in 0..<90 {budget.observe(gpu:i.isMultiple(of:15) ? 0.015 : 0.005,wall:0.02,sourceLongSide:1920,renderLongSide:1920)}
        try check(budget.quality == .full && budget.maximumLongSide==1280,"Sparse p95 failures reduce resolution before changing the shader appearance")
        for _ in 0..<100 {budget.observe(gpu:0.014,wall:0.025,sourceLongSide:1920,renderLongSide:1280)}
        try check(budget.quality == .full && budget.maximumLongSide==960,"Heavy 720p previews retain full shaders at 540p")
        for _ in 0..<100 {budget.observe(gpu:0.0106,wall:0.018,sourceLongSide:1920,renderLongSide:960)}
        try check(budget.quality == .full && budget.maximumLongSide==864,"Small budget overruns reduce resolution again while preserving full shaders")
        for _ in 0..<120 {budget.observe(gpu:0.005,wall:0.01,sourceLongSide:1920,renderLongSide:864)}
        try check(budget.maximumLongSide==864,"Preview quality stays stable instead of pumping after recovery")
        for (current,next) in [(864.0,768.0),(768.0,640.0)] {
            for _ in 0..<100 {budget.observe(gpu:0.018,wall:0.03,sourceLongSide:1920,renderLongSide:current)}
            try check(budget.maximumLongSide==next && budget.quality == .full,"Resolution fallback preserves the full effect processing down to 360p")
        }
        for _ in 0..<100 {budget.observe(gpu:0.018,wall:0.03,sourceLongSide:1920,renderLongSide:640)}
        try check(budget.quality == .lite && budget.maximumLongSide==640,"Lite processing is reserved for exhausted resolution fallbacks")
        var isolated=VideoEffectLiveBudget()
        for i in 0..<180 {isolated.observe(gpu:i.isMultiple(of:30) ? 0.015 : 0.005,wall:0.02,sourceLongSide:1920,renderLongSide:1920)}
        try check(isolated.maximumLongSide==nil,"Isolated spikes below the p95 allowance do not reduce resolution")
        var overloaded=VideoEffectLiveBudget()
        for _ in 0..<24 {overloaded.observe(gpu:0.060,wall:0.070,sourceLongSide:3840,renderLongSide:3840)}
        try check(overloaded.maximumLongSide==nil,"Startup adaptation first collects actual GPU evidence")
        overloaded.observe(gpu:0.060,wall:0.070,sourceLongSide:3840,renderLongSide:3840)
        try check(overloaded.maximumLongSide==1280 && overloaded.quality == .full,"A sustained 5x overload skips unaffordable preview sizes without changing shaders")
        for _ in 0..<30 {overloaded.observe(gpu:0.060,wall:0.070,sourceLongSide:3840,renderLongSide:3840)}
        try check(overloaded.maximumLongSide==1280,"Late measurements at the discarded size do not force another reduction")
        for _ in 0..<120 {overloaded.observe(gpu:0.009,wall:0.020,sourceLongSide:3840,renderLongSide:1280)}
        try check(overloaded.maximumLongSide==1280,"The affordable predicted size remains stable")
        var cold=VideoEffectLiveBudget()
        for i in 0..<90 {cold.observe(gpu:i==0 ? 0.100 : 0.008,wall:0.015,sourceLongSide:3840,renderLongSide:3840)}
        try check(cold.maximumLongSide==nil,"A single cold pipeline spike does not reduce an affordable look")
        var ramp=VideoEffectLiveBudget()
        for i in 0..<180 {ramp.observe(gpu:i<15 ? 0.022 : 0.009,wall:0.020,sourceLongSide:1920,renderLongSide:1920)}
        try check(ramp.maximumLongSide==nil,"A startup frequency ramp does not permanently degrade an affordable look")
        var fixedCost=VideoEffectLiveBudget()
        for _ in 0..<25 {fixedCost.observe(gpu:0.030,wall:0.035,sourceLongSide:1920,renderLongSide:1920)}
        let fixedSize=fixedCost.maximumLongSide ?? 1920
        try check(fixedCost.quality == .full && 0.003+0.027*pow(fixedSize/1920,2)<=0.010,"Startup prediction allows fixed GPU costs on a 1080p source")
        let newChain=VideoEffectLiveBudget()
        try check(newChain.maximumLongSide==nil && newChain.quality == .full,"Changing the enabled chain starts a new full-quality assessment")
        var warm=VideoEffectLiveBudget();warm.thermal(serious:true,critical:false)
        try check(warm.quality == .full && warm.maximumLongSide==1280,"Serious thermal state first reduces only preview resolution")
        warm.thermal(serious:false,critical:true)
        try check(warm.quality == .lite && warm.maximumLongSide==960,"Critical thermal state uses the final emergency fallback without changing the recording")
        print("PASS: \(VideoEffectID.allCases.count) typed effects, bounds, keyframes, fixed order, palettes, fractional cadence and dolly feedback")
    }
}
