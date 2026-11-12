#if DEBUG || os(macOS)
    import AVFoundation
    import CoreImage
    import Foundation

    func effectAnimationTests(root: URL) async throws {
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() {
                throw NSError(domain: "EffectAnimationChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
            }
        }

        var timing = EffectTiming(curve: .riseHoldReturn, rise: 1, release: 1)
        let frame = 1.0 / 30
        func f(_ t: Double) -> Double { timing.fraction(at: t, duration: 5, frame: frame) }
        try require(
            f(0) == 0 && f(0.5) == 0.5 && f(1) == 1 && f(4) == 1 && f(4.5) < 0.5 && f(5 - frame) == 0,
            "One second to B, three at B, one back to A")
        timing.curve = .riseAndHold
        try require(f(4.99) == 1 && timing.endpoint(.b, duration: 5, frame: frame) == 1, "Reach B early and hold to the end")
        for rise in [0.5, 1.0, 2.0] {
            timing.rise = rise
            try require(timing.previewPosition(1, following: nil, duration: 5, frame: frame) == 1,
                        "Dragging the peak across an inspected frame must keep the playhead there")
            try require(timing.previewPosition(1, following: .b, duration: 5, frame: frame) == rise,
                        "Explicitly editing B follows the peak to its new frame")
        }
        for curve in EffectCurve.allCases {
            timing.curve = curve
            for length in [frame, 0.1, 1, 5, 500] {
                for t in [-0.5, 0, length / 8, length / 2, length - frame, length + 1] {
                    try require(
                        (0...1).contains(timing.fraction(at: t, duration: length, frame: frame)),
                        "Every curve stays bounded on short selections")
                }
            }
        }
        var project = Project(title: "Animated grade, image and crop")
        project.append(SourceMedia(filename: "source.mp4", duration: 4))
        let clip = project.edit.clips[0]
        func animation(_ a: EffectPose, _ b: EffectPose) -> EffectAnimation {
            var motion = EffectAnimation(a, duration: clip.duration)
            motion.b = b
            motion.timing = EffectTiming(curve: .riseHoldReturn, rise: 1, release: 1)
            return motion.anchored(to: clip, offset: 0)
        }
        let bitmap = CIImage(color: CIColor(red: 1, green: 0.35, blue: 0.02)).cropped(
            to: CGRect(x: 0, y: 0, width: 100, height: 100))
        try CIContext().writePNGRepresentation(
            of: bitmap, to: root.appendingPathComponent("image-animation-overlay.png"), format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB())
        var crop = CropSettings()
        var grade = ColorSettings()
        var image = ImageOverlay(filename: "image-animation-overlay.png", start: 0, end: 4, x: 0.2)
        crop.motion = animation(crop.pose, CropSettings(x: 0.65, y: 0.42, zoom: 2, rotation: 8).pose)
        grade.motion = animation(grade.pose, ColorSettings(look: .mono).pose)
        var endImage = image
        endImage.x = 0.82
        endImage.y = 0.75
        endImage.width = 0.8
        endImage.opacity = 0.5
        image.motion = animation(image.pose, endImage.pose)
        var correction = VideoEffectSettings(.colorCorrection, start: 0, end: 4)
        var endCorrection = correction
        endCorrection.set("exposure", .number(-0.8))
        correction.motion = animation(correction.correctionPose(at: 0), endCorrection.correctionPose(at: 0))
        var state = project.edit
        state.clips[0].crop = crop
        state.clips[0].color = grade
        state.clips[0].images = [image]
        state.clips[0].videoEffects = [correction]
        project.commit(state)
        try project.validate()
        let decoded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        try decoded.validate()
        let split = TimelineEditing.split(decoded.edit, at: 1.5)
        try require(
            split.clips.count == 2 && split.clips[1].crop?.motion == crop.motion
                && split.clips[1].images?.first?.motion == image.motion, "Splitting retains source-anchored animation")
        func generator(_ p: Project) async throws -> AVAssetImageGenerator {
            let media = try await MediaRenderer.timeline(project: p, folder: root)
            let g = AVAssetImageGenerator(asset: media.composition)
            g.videoComposition = media.videoComposition
            g.requestedTimeToleranceBefore = .zero
            g.requestedTimeToleranceAfter = .zero
            return g
        }
        func samples(_ generator: AVAssetImageGenerator, _ seconds: Double) async throws -> [UInt8] {
            let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 60000)).image
            var bytes = [UInt8](repeating: 0, count: 64 * 36 * 4)
            bytes.withUnsafeMutableBytes { raw in
                let context = CGContext(
                    data: raw.baseAddress, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 64 * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 36))
            }
            return bytes
        }
        func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
            Double(zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(a.count)
        }
        func staticProject(_ e: EffectEndpoint) -> Project {
            var project = decoded
            var edit = project.edit
            edit.clips[0].crop = crop.applying(crop.motion![e])
            edit.clips[0].color = grade.applying(grade.motion![e])
            edit.clips[0].images = [image.applying(image.motion![e])]
            var fixed = correction
            fixed.motion = nil
            for (id, n) in correction.motion![e].values { fixed.set(id, .number(n)) }
            edit.clips[0].videoEffects = [fixed]
            project.commit(edit)
            return project
        }
        var cut = decoded
        cut.commit(split)
        let preview = try await generator(decoded)
        let afterSplit = try await generator(cut)
        let a = try await generator(staticProject(.a))
        let b = try await generator(staticProject(.b))
        let url = root.appendingPathComponent("animated-output.mp4")
        _ = try await MediaRenderer.render(project: decoded, folder: root, destination: url) { _ in }
        let export = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        export.requestedTimeToleranceBefore = .zero
        export.requestedTimeToleranceAfter = .zero
        for t in [0.0, 0.5, 1, 2, 3, 3.5, 4 - frame] {
            let picture = try await samples(preview, t)
            let exported = try await samples(export, t)
            let splitPicture = try await samples(afterSplit, t)
            let mae = difference(picture, exported)
            try require(mae < 5, "Animated preview/export pixel difference at \(t): \(mae)")
            try require(difference(picture, splitPicture) < 1, "A split changes the animated frame at \(t)")
            if t == 0 || t == 4 - frame || (1...3).contains(t) {
                let expected = try await samples((1...3).contains(t) ? b : a, t)
                let other = try await samples((1...3).contains(t) ? a : b, t)
                try require(
                    difference(picture, expected) < 1 && difference(picture, other) > 5, "Wrong A/B endpoint at \(t)")
            }
        }
        // Compare the very same frame after retiming. An endpoint-only check
        // cannot distinguish timing changes between the same two looks.
        var retimed = decoded
        var changed = decoded.edit
        let newTiming = EffectTiming(curve: .riseHoldReturn, rise: 1.9, release: 1.9, ramp: .easeIn)
        changed.clips[0].crop?.motion?.timing = newTiming
        changed.clips[0].color?.motion?.timing = newTiming
        changed.clips[0].images?[0].motion?.timing = newTiming
        changed.clips[0].videoEffects?[0].motion?.timing = newTiming
        retimed.commit(changed)
        let refreshed = try await generator(retimed)
        let newURL = root.appendingPathComponent("retimed-output.mp4")
        _ = try await MediaRenderer.render(project: retimed, folder: root, destination: newURL) { _ in }
        let retimedExport = AVAssetImageGenerator(asset: AVURLAsset(url: newURL))
        retimedExport.requestedTimeToleranceBefore = .zero
        retimedExport.requestedTimeToleranceAfter = .zero
        for t in [1.0, 3.0, 3.5] {
            let current = try await samples(refreshed, t)
            let previous = try await samples(preview, t)
            let encoded = try await samples(retimedExport, t)
            try require(difference(current, previous) > 2, "Timing change must visibly change the sampled frame at \(t)")
            try require(difference(current, encoded) < 5, "Retimed preview/export mismatch at \(t)")
        }
        var layers = Project(title: "Overlapping pictures")
        layers.append(SourceMedia(filename: "source.mp4", duration: 4))
        try FileManager.default.linkItem(
            at: root.appendingPathComponent("source.mp4"), to: root.appendingPathComponent("source-two.mp4"))
        layers.append(SourceMedia(filename: "source-two.mp4", duration: 4))
        var overlap = layers.edit
        let back = overlap.timeline.video[0].id
        let front = overlap.timeline.video[1].id
        overlap.timeline.video[1].start = .zero
        overlap.timeline.audio[1].start = .zero
        overlap.timeline.video[1].content.color = ColorSettings(look: .mono)
        var first = VideoPlacement()
        first.order = 1
        var last = first
        last.x = 0.72
        last.y = 0.6
        last.width = 0.5
        last.height = 0.55
        last.framing.zoom = 1.7
        first.motion = animation(first.pose, last.pose)
        var layout = VideoPlacementRegion(participants: [back, front], videos: [back: VideoPlacement(), front: first])
        overlap.timeline.placements = [layout]
        layers.commit(overlap)
        let moving = try await generator(layers)
        let placedURL = root.appendingPathComponent("placement-export.mp4")
        _ = try await MediaRenderer.render(project: layers, folder: root, destination: placedURL) { _ in }
        let placedExport = AVAssetImageGenerator(asset: AVURLAsset(url: placedURL))
        placedExport.requestedTimeToleranceBefore = .zero
        placedExport.requestedTimeToleranceAfter = .zero
        for t in [0.0, 0.5, 2.0, 3.5] {
            let pose = first.motion!.pose(at: t)
            layout.videos[front] = first.applying(pose)
            overlap.timeline.placements = [layout]
            layers.commit(overlap)
            let fixed = try await generator(layers)
            let actual = try await samples(moving, t)
            let expected = try await samples(fixed, t)
            let encoded = try await samples(placedExport, t)
            try require(
                difference(actual, expected) < 1 && difference(actual, encoded) < 5,
                "Animated placement differs from reference at \(t)")
        }
        print("PASS: five animated tools, persistence, split continuity and preview/export comparisons")
    }

    #if os(iOS)
        @MainActor
        func runEffectAnimationDiagnostics() async {
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("EffectAnimationQA-" + UUID().uuidString)
            let run = CommandLine.arguments.compactMap(UUID.init(uuidString:)).last ?? UUID()
            let report = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(
                "EffectAnimationQA-" + run.uuidString + ".txt")
            let result: String
            do {
                try fm.createDirectory(at: root, withIntermediateDirectories: true)
                guard let fixture = Bundle.main.url(forResource: "editor-fixture", withExtension: "mp4") else {
                    throw ProjectError.missingMedia
                }
                try fm.copyItem(at: fixture, to: root.appendingPathComponent("source.mp4"))
                try await effectAnimationTests(root: root)
                result = "PASS: five tools, checked decoded exports and preview frames"
            } catch { result = "FAIL: " + error.localizedDescription }
            try? (Date().description + " " + result).write(to: report, atomically: true, encoding: .utf8)
        }
    #endif
#endif
