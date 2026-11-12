import Foundation
import AVFoundation
import ImageIO
import CoreImage

/// Inspect an isolated, physical-camera capture copied to root/capture.mov.
/// Keep evidence of the native signal, the editor's viewing conversion and the
/// actual exported movie. This never reads or writes a device project.
func inspectLogRecording(root: URL) async throws {
    let url = root.appendingPathComponent("capture.mov"), asset = AVURLAsset(url: root.appendingPathComponent("capture.mov"))
    let track = try await asset.loadTracks(withMediaType: .video).first!
    let formats = try await track.load(.formatDescriptions)
    try require(formats.contains { LogColor.profile($0) != nil }, "Physical recording carries Log metadata")
    let duration = try await asset.load(.duration).seconds
    let reader = try VideoEffectSourceReader(url: url, hdr: false, capacity: 2)
    let context = CIContext(options: [.cacheIntermediates: false])
    func save(_ picture: CIImage, _ name: String) throws {
        guard let cg = context.createCGImage(picture, from: picture.extent),
              let output = CGImageDestinationCreateWithURL(root.appendingPathComponent(name).appendingPathExtension("png") as CFURL, "public.png" as CFString, 1, nil) else { throw ProjectError.invalidMedia }
        CGImageDestinationAddImage(output, cg, nil); try require(CGImageDestinationFinalize(output), "Save inspection frame")
    }
    let at = min(1.2, duration / 2), source = try reader.frame(at: at)
    try save(LogColor.display(source), "source-with-viewing-transform")
    let sidecar = root.appendingPathComponent("capture.effects.json")
    let effects = FileManager.default.fileExists(atPath: sidecar.path)
        ? try JSONDecoder().decode(SupportedVideoEffects.self, from: Data(contentsOf: sidecar)).values : []
    var project = Project(title: "Physical Log QA")
    project.append(SourceMedia(filename: "capture.mov", duration: duration, videoEffects: VideoEffectSettings.capturedRecipe(effects, duration: duration)))
    let media = try await MediaRenderer.timeline(project: project, folder: root)
    let preview = AVAssetImageGenerator(asset: media.composition); preview.videoComposition = media.videoComposition
    try save(CIImage(cgImage: try await preview.image(at: CMTime(seconds: at, preferredTimescale: 600)).image), "editor-preview")
    let output = root.appendingPathComponent("editor-export.mov")
    _ = try await MediaRenderer.render(project: project, folder: root, destination: output) { _ in }
    try save(try VideoEffectSourceReader(url: output, hdr: false).frame(at: at), "editor-export")
    print("PASS: physical Log recording decoded, previewed and exported", formats.compactMap { LogColor.profile($0)?.rawValue }, "effects:", effects.map { $0.kind.rawValue })
}

func colorGradeTests(root: URL) async throws {
    try localRecoveryTests()
    let identity = "TITLE \"Identity\"\nLUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n"
    let cube = try CubeLUT(data: Data(identity.utf8))
    try require(cube.dimension == 2 && cube.rgba.count == 8 * 16, "CUBE lattice and channel count")
    let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
    let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    func image(_ r: Float, _ g: Float, _ b: Float) -> CIImage {
        let values: [Float] = [r, g, b, 1]
        return CIImage(bitmapData: values.withUnsafeBytes { Data($0) }, bytesPerRow: 16, size: CGSize(width: 1, height: 1), format: .RGBAf, colorSpace: space)
    }
    func pixel(_ image: CIImage) -> [Float] {
        var values = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &values, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: space)
        return values
    }
    let source = image(0.18, 0.4, 0.7), copied = pixel(cube.apply(to: source))
    try require(abs(copied[0] - 0.18) < 0.002 && abs(copied[2] - 0.7) < 0.002, "Identity LUT preserves channel order")
    let domain = try CubeLUT(data: Data(("DOMAIN_MIN -1 -1 -1\nDOMAIN_MAX 1 1 1\n" + identity).utf8))
    try require(abs(pixel(domain.apply(to: image(0, 0, 0)))[0] - 0.5) < 0.002, "Non-default CUBE domains are respected")
    let curve = try CubeLUT(data: Data("LUT_1D_SIZE 3\n0 0 0\n0.25 0.5 0.75\n1 1 1\n".utf8))
    let curvePixel = pixel(curve.apply(to: image(0.5, 0.5, 0.5)))
    try require(abs(curvePixel[0] - 0.25) < 0.002 && abs(curvePixel[2] - 0.75) < 0.002, "Standalone 1D LUT preserves independent channels")
    for invalid in ["LUT_3D_SIZE 999999\n", identity + "0 0 0\n", identity.replacingOccurrences(of: "1 1 1", with: "nan 1 1"), "LUT_1D_SIZE 2\n" + identity,
                    "DOMAIN_MIN 1 1 1\nDOMAIN_MAX 1 1 1\n" + identity, "LUT_3D_SIZE 2\n0 0 0\n"] {
        do { _ = try CubeLUT(data: Data(invalid.utf8)); throw NSError(domain: "Accepted malformed LUT", code: 1) }
        catch is LUTError {}
    }
    let folder = root.appendingPathComponent("color-grade-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let importedURL = folder.appendingPathComponent("external.cube"); try Data(identity.utf8).write(to: importedURL)
    let lut = try LUTAssets.ingest(importedURL, folder: folder)
    try FileManager.default.removeItem(at: importedURL)
    _ = try LUTAssets.load(lut, folder: folder)
    let identityLook = pixel(ColorLUT.apply(ColorSettings(imported: lut), to: source, folder: folder))
    try require(zip(identityLook, pixel(source)).allSatisfy { abs($0 - $1) < 0.003 }, "Rec709 import round-trips through explicit LUT color space")
    let warm = pixel(ColorLUT.apply(ColorSettings(look: .goldenHour), to: source))
    try require(abs(warm[0] - 0.18) > 0.005, "Creative looks visibly change the image")
    let balance = pixel(ColorLUT.apply(ColorSettings(look: .warm, amount: 0, exposure: 1), to: source))
    try require(abs(balance[0] - 0.36) < 0.003, "Look zero retains exposure adjustment")
    try require(!ColorSettings(amount: 0, imported: lut).isIdentity, "Zero-strength LUT remains available to re-edit")
    for value in [-0.05, 0, 0.005, 0.01, 0.18, 1, 8] {
        try require(abs(LogColor.decodeValue(LogColor.encodeValue(value)) - value) < 0.00001, "Apple Log curve reference round-trip")
    }
    // Distinct, recoverable source highlights must survive the viewing shoulder.
    // The old exponential curve made both these patches effectively white.
    let bright = pixel(LogColor.display(image(4, 4, 4)))[0]
    let brighter = pixel(LogColor.display(image(8, 8, 8)))[0]
    try require(brighter - bright > 0.01, "Log viewing preserves bright highlight separation")
    try require(abs(pixel(LogColor.display(image(0.18, 0.18, 0.18)))[0] - 0.18) < 0.0001, "Log viewing preserves middle gray")
    for amount in [-1.0, -0.5, 0, 0.5, 1] {
        var previous: Float = -1
        for index in 0...256 {
            let value = Float(index) / 16
            let adjusted = pixel(LogColor.highlights(image(value, value, value), amount: amount))[0]
            try require(adjusted.isFinite && adjusted > previous, "Highlights stay monotonic and finite over extended scene range")
            previous = adjusted
        }
        for value: Float in [0, 0.02, 0.18, 0.3, 0.35] {
            try require(abs(pixel(LogColor.highlights(image(value, value, value), amount: amount))[0] - value) < 0.0001, "Highlights preserve shadows and midtones at every strength")
        }
    }
    let recovered = pixel(ColorLUT.apply(ColorSettings(highlights: -1), to: image(4, 4, 4), sourceLog: .appleLog2))[0]
    try require(recovered < bright - 0.1 && recovered > 0.6, "Selective recovery restores headroom without flattening white to middle gray")
    let unchanged = pixel(ColorLUT.apply(ColorSettings(highlights: -1), to: image(0.18, 0.18, 0.18), sourceLog: .appleLog2))[0]
    try require(abs(unchanged - 0.18) < 0.0001, "Recovery preserves source middle gray through the complete grade")
    let zeroStrength = pixel(ColorLUT.apply(ColorSettings(look: .warm, amount: 0, highlights: -1), to: image(4, 4, 4), sourceLog: .appleLog2))[0]
    try require(abs(zeroStrength - recovered) < 0.0001, "Highlight recovery remains active at zero creative strength")
    try require(!ColorSettings(highlights: -0.5).isIdentity && ColorSettings(highlights: -0.5).valid, "Highlights-only grade remains editable")
    try require(!ColorSettings(highlights: .nan).valid && !ColorSettings(highlights: 2).valid, "Invalid highlight settings rejected")
    for profile in [LUTInput.appleLog, .appleLog2] {
        let scene = image(0.18, 0.5, 2)
        let decoded = LogColor.decode(LogColor.encode(scene, profile: profile), profile: profile)
        try require(zip(pixel(decoded), pixel(scene)).allSatisfy { abs($0 - $1) < 0.006 }, "Log GPU curve and gamut round-trip")
        let baseline = ColorLUT.apply(ColorSettings(), to: scene, sourceLog: profile)
        let zero = ColorLUT.apply(ColorSettings(look: .warm, amount: 0), to: scene, sourceLog: profile)
        try require(zip(pixel(baseline), pixel(zero)).allSatisfy { abs($0 - $1) < 0.0001 }, "0% creative look retains Log viewing conversion")
        try require(pixel(baseline)[2] < 2, "Log highlights are display-mapped without modifying source values")
    }
    var project = Project(title: "LUT persistence")
    project.append(SourceMedia(filename: "source.mp4", duration: 4))
    var edit = project.edit; edit.clips[0].color = ColorSettings(imported: lut, exposure: 0.5, highlights: -0.6, localRecovery: 0.65)
    project.commit(edit); project.undo(); try project.validate()
    try require(project.effectFiles.contains(lut.filename), "Undo retains immutable LUT payload for redo/archive")
    let reopened = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
    try require(reopened.effectFiles.contains(lut.filename), "LUT ownership survives project reopening")
    try FileManager.default.copyItem(at: root.appendingPathComponent("source.mp4"), to: folder.appendingPathComponent("source.mp4"))
    let archive = folder.appendingPathComponent("grade.yourec")
    try await ProjectArchive.export(project, folder: folder, destination: archive) { _ in }
    let disk = ProjectDisk(root: folder.appendingPathComponent("restored"))
    var restored = try await ProjectArchive.restore(archive, disk: disk) { _ in }
    restored.redo(); try restored.validate()
    _ = try LUTAssets.load(restored.edit.clips[0].color!.imported!, folder: disk.folder(restored.id))
    try require(restored.edit.clips[0].color?.exposure == 0.5, "Archived LUT and grade survive restore and redo")
    try require(restored.edit.clips[0].color?.highlights == -0.6, "Highlight correction survives archive, reopen and redo")
    try require(restored.edit.clips[0].color?.localRecovery == 0.65, "Local recovery survives archive, reopen and redo")
    let grade = SavedGrade(name: "Recovered highlights", settings: edit.clips[0].color!)
    let decodedGrade = try JSONDecoder().decode(SavedGrade.self, from: JSONEncoder().encode(grade))
    try require(decodedGrade.settings.highlights == -0.6, "Named grades retain highlights")
    try require(decodedGrade.settings.localRecovery == 0.65, "Named grades retain local recovery")
    var unsafe = lut; unsafe.filename = "../outside.cube"
    try require(!unsafe.valid, "LUT references cannot escape project folder")
    print("PASS: CUBE validation, color domains, Apple Log math, balance, immutable history assets")
}

func localRecoveryTests() throws {
    let width = 64, height = 64, radius = 4
    let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .workingFormat: CIFormat.RGBAf.rawValue])
    // Independent CPU reference: spatially varying bright texture beside dark
    // midtones. A constant patch alone cannot detect a broken local filter.
    let values: [Double] = (0..<width*height).map { i in
        let x = i % width, y = i / width
        return x < 24 ? 0.18 : 2.7 + 0.7 * Double(y) / Double(height) + 0.14 * sin(Double(x)*1.7) * cos(Double(y)*0.9)
    }
    func mean(_ input: [Double]) -> [Double] {
        (0..<input.count).map { i in
            var total = 0.0
            for dy in -radius...radius { for dx in -radius...radius {
                total += input[min(height-1,max(0,i/width+dy))*width + min(width-1,max(0,i%width+dx))]
            } }
            return total / Double((2*radius+1)*(2*radius+1))
        }
    }
    func view(_ y: Double) -> Double { y <= 0.6 ? y : 0.6 + 0.4*(y-0.6)/(y-0.2) }
    let logY = values.map(log2), moments = mean(logY), squares = mean(logY.map { $0*$0 })
    let a = zip(moments,squares).map { m,s in let v=max(0,s-m*m);return v/(v+0.12) }
    let b = zip(moments,a).map { $0*(1-$1) }, ma=mean(a), mb=mean(b)
    let reference: [Double] = values.indices.map { i in
        let baseLog=ma[i]*logY[i]+mb[i],base=exp2(baseLog)
        let adjusted=base <= 0.35 ? base : 0.35+log1p(12*(base-0.35))/12
        let local=view(adjusted)*exp2(logY[i]-baseLog)
        return local <= 0.9 ? local : 0.9+0.1*(local-0.9)/(local-0.8)
    }
    let rgba: [Float]=values.flatMap { [Float($0),Float($0),Float($0),Float(1)] }
    let scene=CIImage(bitmapData:rgba.withUnsafeBytes { Data($0) },bytesPerRow:width*16,size:CGSize(width:width,height:height),format:.RGBAf,colorSpace:nil)
    func pixels(_ image: CIImage) -> [Float] {
        var out=[Float](repeating:0,count:rgba.count)
        context.render(image,toBitmap:&out,rowBytes:width*16,bounds:scene.extent,format:.RGBAf,colorSpace:nil)
        return out
    }
    try require(LogColor.localRecovery(scene,amount:0) === scene, "Zero recovery bypasses the entire spatial graph")
    try require(LogColor.localRecovery(scene,amount:.nan) === scene, "Invalid runtime strength cannot poison rendering")
    for strength in [0.0,0.25,0.5,1.0] {
        let output=pixels(ColorLUT.apply(ColorSettings(localRecovery:strength),to:scene,sourceLog:.appleLog2))
        let errors=values.indices.map { abs(Double(output[$0*4]) - ((1-strength)*view(values[$0])+strength*reference[$0])) }
        try require(output.allSatisfy(\.isFinite) && errors.max()! < 0.0002, "Spatial Log recovery matches CPU reference at \(strength)")
        try require(abs(Double(output[(height/2*width+4)*4])-0.18)<0.00001, "Local recovery retains midtones away from bright boundaries")
    }
    let sdr=pixels(ColorLUT.apply(ColorSettings(localRecovery:1),to:scene))
    try require(zip(sdr,rgba).allSatisfy { abs($0-$1)<0.00001 }, "Recovery saved in a grade never changes SDR footage")
    try require(!ColorSettings(localRecovery:0.5).isIdentity && ColorSettings(localRecovery:0.5).valid, "Recovery alone is a persistent grade")
    try require(!ColorSettings(localRecovery:1.01).valid && !ColorSettings(localRecovery:.nan).valid, "Out-of-range recovery is rejected")
    print("PASS: local recovery GPU/CPU spatial parity, strength, bypass and Log-only scope")
}

func logWriterTests(root: URL) async throws {
    guard #available(macOS 26, *) else { return }
    let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    for profile in [LUTInput.appleLog, .appleLog2] {
        let writer = CaptureSegmentWriter()
        let url = root.appendingPathComponent("writer-\(profile.rawValue)-\(UUID().uuidString).mov")
        var buffer: CVPixelBuffer?
        try require(CVPixelBufferCreate(nil, 128, 72, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess, "Log fixture allocation")
        let pixel = buffer!
        LogColor.tag(pixel, profile: profile)
        var flat = CIImage(color: CIColor(red: 0.49, green: 0.42, blue: 0.36)).cropped(to: CGRect(x: 0, y: 0, width: 128, height: 72))
        for (index, value) in [0.18, 2.0, 4.0, 8.0].enumerated() {
            let code = LogColor.encodeValue(value)
            let patch = CIImage(color: CIColor(red: code, green: code, blue: code)).cropped(to: CGRect(x: 64 + index * 16, y: 0, width: 16, height: 72))
            flat = patch.composited(over: flat)
        }
        context.render(flat, to: pixel, bounds: flat.extent, colorSpace: nil)
        var format: CMVideoFormatDescription?
        try require(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixel, formatDescriptionOut: &format) == noErr, "Log fixture format")
        let began = CMClockGetTime(CMClockGetHostTimeClock())
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writer.onFinish = { _, error in
                // This fixture intentionally feeds video only. The production
                // writer correctly reports the missing microphone after padding.
                if let error, !((error as NSError).domain == "YouRecCapture" && (error as NSError).code == 3) { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
            writer.startRecording(to: url)
            Task {
                for index in 0..<15 {
                    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: began + CMTime(value: Int64(index), timescale: 30), decodeTimeStamp: .invalid)
                    var sample: CMSampleBuffer?
                    CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixel, formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample)
                    if let sample { writer.queue.async { writer.appendVideo(sample) } }
                    try? await Task.sleep(for: .milliseconds(35))
                }
                writer.stopRecording()
            }
        }
        let asset = AVURLAsset(url: url), track = try await asset.loadTracks(withMediaType: .video).first!
        let formats = try await track.load(.formatDescriptions)
        print("Log writer \(profile.rawValue):", formats.map { CMFormatDescriptionGetExtensions($0) })
        try require(formats.contains { LogColor.profile($0) == profile }, "Writer preserves \(profile.title) profile metadata")
        try require(formats.allSatisfy { !VideoColor.isHDR($0) }, "Log is not mislabeled HLG")
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange])
        reader.add(output); try require(reader.startReading(), "Log fixture decode")
        let decoded = output.copyNextSampleBuffer()!.imageBuffer!
        try require(LogColor.profile(decoded) == profile, "Decoded Log buffers retain interpretation")
        var rgb = [Float](repeating: 0, count: 4)
        let codes = CIImage(cvPixelBuffer: decoded, options: [.colorSpace: NSNull()])
        context.render(codes, toBitmap: &rgb, rowBytes: 16, bounds: CGRect(x: 40, y: 30, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        try require(abs(rgb[0] - 0.49) < 0.012 && abs(rgb[1] - 0.42) < 0.012 && abs(rgb[2] - 0.36) < 0.012, "Encoder retains flat Log code values instead of baking viewing transform")
        reader.cancelReading()
        var project = Project(title: "Log export")
        project.append(SourceMedia(filename: url.lastPathComponent, duration: try await asset.load(.duration).seconds))
        let media = try await MediaRenderer.timeline(project: project, folder: root)
        try require(media.videoComposition.customVideoCompositorClass != nil, "Ungraded Log uses technical viewing conversion")
        let generator = AVAssetImageGenerator(asset: media.composition)
        generator.videoComposition = media.videoComposition
        let preview = try await generator.image(at: CMTime(seconds: 0.2, preferredTimescale: 600)).image
        let displayContext = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
        func measured(_ picture: CIImage, x: Int = 40) -> [Float] {
            var values = [Float](repeating: 0, count: 4)
            displayContext.render(picture, toBitmap: &values, rowBytes: 16, bounds: CGRect(x: x, y: 30, width: 1, height: 1), format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
            return values
        }
        let expected = measured(LogColor.display(LogColor.image(decoded)))
        let actual = measured(CIImage(cgImage: preview))
        try require(zip(expected, actual).allSatisfy { abs($0 - $1) < 0.018 }, "Log timeline preview matches explicit camera transform")
        let thumbnailSource = try await LogThumbnailSource.make(url: url)
        try require(thumbnailSource != nil, "Log thumbnail uses explicit interpretation")
        let thumbnail = try await thumbnailSource!.image(at: 0.2, maximumSize: CGSize(width: 128, height: 128))
        try require(zip(expected, measured(CIImage(cgImage: thumbnail))).allSatisfy { abs($0 - $1) < 0.018 }, "Log thumbnail matches editor viewing conversion")
        var edit = project.edit; edit.clips[0].color = ColorSettings(look: .mono, highlights: -0.7, localRecovery: 0.7)
        project.commit(edit)
        let exported = root.appendingPathComponent("graded-\(profile.rawValue)-\(UUID().uuidString).mov")
        _ = try await MediaRenderer.render(project: project, folder: root, destination: exported) { _ in }
        let rendered = try VideoEffectSourceReader(url: exported, hdr: false, capacity: 2).frame(at: 0.2)
        let result = measured(rendered)
        try require(abs(result[0] - result[1]) < 0.012 && abs(result[1] - result[2]) < 0.012, "Creative look is baked into normal Log export")
        let referenceImage = ColorLUT.apply(ColorSettings(look: .mono, highlights: -0.7, localRecovery: 0.7), to: LogColor.image(decoded), sourceLog: profile)
        let reference = measured(referenceImage)
        try require(zip(reference, result).allSatisfy { abs($0 - $1) < 0.018 }, "Log preview and export share grading transform")
        let correctedMedia = try await MediaRenderer.timeline(project: project, folder: root)
        let correctedGenerator = AVAssetImageGenerator(asset: correctedMedia.composition); correctedGenerator.videoComposition = correctedMedia.videoComposition
        let correctedPreview = CIImage(cgImage: try await correctedGenerator.image(at: CMTime(seconds: 0.2, preferredTimescale: 600)).image)
        for x in [72, 88, 104, 120] {
            let expectedPatch = measured(referenceImage, x: x)
            try require(zip(expectedPatch, measured(rendered, x: x)).allSatisfy { abs($0 - $1) < 0.025 }, "Highlight patches survive graded export")
            try require(zip(expectedPatch, measured(correctedPreview, x: x)).allSatisfy { abs($0 - $1) < 0.025 }, "Highlight preview and export agree")
        }
        try require(measured(rendered, x: 120)[0] - measured(rendered, x: 104)[0] > 0.015, "Saved video retains bright texture separation")
        try require(abs(measured(rendered, x: 72)[0] - measured(CIImage(cgImage: preview), x: 72)[0]) < 0.02, "Highlight recovery does not darken saved midtones")
        // An intentionally non-identity cube exposes accidental bypasses in
        // actual preview/export, including a Log-input LUT with no double curve.
        let cubeURL = root.appendingPathComponent("export-check.cube")
        try "LUT_3D_SIZE 2\n0 0 0\n0 0 1\n0 1 0\n0 1 1\n1 0 0\n1 0 1\n1 1 0\n1 1 1\n".write(to: cubeURL, atomically: true, encoding: .utf8)
        for input in [LUTInput.rec709, profile] {
            var lut = try LUTAssets.ingest(cubeURL, folder: root); lut.input = input
            let grade = ColorSettings(imported: lut, exposure: 0.3, highlights: -0.7, localRecovery: 0.7)
            edit.clips[0].color = grade; project.commit(edit)
            let graded = try await MediaRenderer.timeline(project: project, folder: root)
            let still = AVAssetImageGenerator(asset: graded.composition); still.videoComposition = graded.videoComposition
            let stillImage = try await still.image(at: CMTime(seconds: 0.2, preferredTimescale: 600)).image
            let expectedImport = measured(ColorLUT.apply(grade, to: LogColor.image(decoded), folder: root, sourceLog: profile))
            try require(zip(expectedImport, measured(CIImage(cgImage: stillImage))).allSatisfy { abs($0 - $1) < 0.018 }, "Imported \(input.title) LUT preview uses its declared domain")
            let outputURL = root.appendingPathComponent("imported-\(UUID().uuidString).mov")
            _ = try await MediaRenderer.render(project: project, folder: root, destination: outputURL) { _ in }
            let outputPicture = try VideoEffectSourceReader(url: outputURL, hdr: false, capacity: 2).frame(at: 0.2)
            try require(zip(expectedImport, measured(outputPicture)).allSatisfy { abs($0 - $1) < 0.018 }, "Imported LUT export matches preview")
            for x in [72, 88, 104, 120] {
                let expectedPatch = measured(ColorLUT.apply(grade, to: LogColor.image(decoded), folder: root, sourceLog: profile), x: x)
                try require(zip(expectedPatch, measured(outputPicture, x: x)).allSatisfy { abs($0 - $1) < 0.03 }, "Highlight recovery precedes imported LUT in its declared input domain")
            }
        }
        var restoration = VideoEffectSettings(.nightFix, start: 0, end: project.edit.duration)
        restoration.set("brightness", .number(0)); restoration.set("mode", .choice("Medium"))
        edit.clips[0].color = nil; edit.clips[0].videoEffects = [restoration]; project.commit(edit)
        let restored = try await MediaRenderer.timeline(project: project, folder: root)
        let instruction = restored.videoComposition.instructions.compactMap { $0 as? VideoToolInstruction }.first
        try require(instruction?.nightFix?.hdr == true, "Log restoration cache preserves scene highlight headroom")
        let restoredGenerator = AVAssetImageGenerator(asset: restored.composition); restoredGenerator.videoComposition = restored.videoComposition
        let restoredImage = try await restoredGenerator.image(at: CMTime(seconds: 0.2, preferredTimescale: 600)).image
        try require(measured(CIImage(cgImage: restoredImage)).allSatisfy { $0.isFinite }, "Log plus temporal Night fix renders successfully")
    }
    print("PASS: production capture writer preserves Apple Log/Log 2 codes and metadata")
}

private func coverSamplingTests() throws {
    let footage = [EditInterval(0...1), EditInterval(0.5...2), EditInterval(20...21)]
    let pool = CoverFramePool(picture: footage, scope: [EditInterval(1...2), EditInterval(12...20.5)])
    try require(pool.count == 45, "Overlapping video layers count once and gaps are skipped")
    var previous: [Int] = []
    for _ in 0..<100 {
        let picks = pool.picks(replacing: previous)
        try require(picks.count == 9 && zip(picks, picks.dropFirst()).allSatisfy { $0 < $1 }, "Nine ordered cover choices")
        try require(zip(previous, picks).allSatisfy { $0 != $1 }, "Update replaces every choice with an alternative")
        for (band, pick) in picks.enumerated() {
            let time = pool.time(of: pick).seconds
            try require((band*5..<(band+1)*5).contains(pick), "Sample the whole available span")
            try require((1..<2).contains(time) || (20..<20.5).contains(time), "Only sample selected visible video, before the end boundary")
        }
        previous = picks
    }
    let short = CoverFramePool(picture: footage, scope: [EditInterval(0...0.2)])
    try require(short.picks(replacing: []) == Array(0..<6), "Six-frame range shows six distinct frames")
    let subframe = CoverFramePool(picture: footage, scope: [EditInterval(0.040...0.045)])
    try require(subframe.count == 1 && subframe.time(of: 0) == EditTime(0.040), "Subframe selection stays inside its range")
    let empty = CoverFramePool(picture: footage, scope: [EditInterval(5...7)])
    try require(empty.picks(replacing: []).isEmpty, "A gap has no cover candidates")
}

func videoToolsTests(root: URL) async throws {
    try coverSamplingTests()
    try await colorGradeTests(root: root)
    try effectQuickRemovalTests()
    try splitEffectScopeTests()
    try cropRotationAndUnknownEffectTests()
    var project = Project(title: "Tool persistence and timing")
    project.append(SourceMedia(filename: "source.mp4", duration: 4))
    var edit = project.edit
    edit.clips[0].speed = SpeedSettings(rate: 2)
    edit.clips[0].texts = [TextOverlay(text: "Hello", start: 1, end: 3)]
    edit.clips[0].color = ColorSettings(look: .warm, amount: 0.5)
    project.commit(edit)
    try project.validate()
    let split = TimelineEditing.split(edit, at: 0.8)
    try require(split.clips.count == 2 && abs(split.clips[0].end - 1.6) < 0.00001 && abs(split.duration - 2) < 0.00001, "Speed-aware split uses source coordinates and preserves duration")
    let removed = TimelineEditing.removing(0.5...1.5, from: edit)
    try require(removed.clips.count == 2 && removed.clips[0].end == 1 && removed.clips[1].start == 3 && removed.duration == 1, "Ripple removal maps through speed")
    let (scoped, ids) = TimelineEditing.scoped(edit, range: 0.5...1.5)
    try require(scoped.clips.count == 3 && ids.count == 1 && scoped.clips[1].start == 1 && scoped.clips[1].end == 3, "Tool scope isolates exactly the selected source range")
    var pauseClip = edit.clips[0]
    pauseClip.pauses = PauseSettings(cuts: [SourceInterval(start: 1, end: 2)])
    try require(pauseClip.duration == 1.5 && pauseClip.sourceTime(at: 0.5) == 2 && pauseClip.timelineTime(forSource: 3) == 1, "Pauses and speed compose without drifting effect timing")
    let pauseSplit = TimelineEditing.split(EditState(clips: [pauseClip]), at: 0.5)
    try require(abs(pauseSplit.duration - pauseClip.duration) < 0.000001, "Splitting at a removed pause preserves output duration")
    let trimmed = TimelineEditing.trimmed(pauseClip, left: true, by: 0.5, sourceDuration: 4)
    try require(trimmed.start == 2 && trimmed.duration == 1, "Trim handles follow timeline distance through speed and skipped pauses")
    let minimal = TimelineEditing.trimmed(pauseClip, left: false, by: -100, sourceDuration: 4)
    try require(minimal.duration >= TimelineEditing.frame - 0.000001, "Trim never produces a fully skipped, invalid clip")
    var restored = pauseClip; restored.pauses = nil
    try require(restored.duration == 2 && restored.texts == pauseClip.texts, "Removing Pauses restores media and retains other effects")
    let wave = SourceWaveform(duration: 4, peaks: (0..<400).map { (100..<250).contains($0) ? Float(0.001) : Float(0.2) })
    let settings = PauseSettings(thresholdDB: -40, minimum: 0.6, before: 0.1, after: 0.2, levelMode: nil)
    let cuts = PauseDetector.detect(wave: wave, clip: project.history[0].clips.first ?? TimelineClip(sourceID: project.sources[0].id, start: 0, end: 4), settings: settings)
    try require(cuts.count == 1 && abs(cuts[0].start - 1.1) < 0.001 && abs(cuts[0].end - 2.3) < 0.001, "Pause detector retains independent pre/post speech padding")
    project.undo()
    var reopened = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project)); reopened.redo(); try reopened.validate()
    try require(reopened.edit == edit, "All tool settings survive undo/redo and document reopening")
    var longProject = Project(title: "Pause history size")
    longProject.append(SourceMedia(filename: "long.mp4", duration: 720))
    var longEdit = longProject.edit
    let candidates = (0..<140).map { DetectedPause(raw: SourceInterval(start: Double($0) * 5 + 1, end: Double($0) * 5 + 1.7), enabled: !$0.isMultiple(of: 7)) }
    longEdit.clips[0].pauses = PauseSettings(cuts: candidates.filter(\.enabled).map { SourceInterval(start: $0.raw.start + 0.1, end: $0.raw.end - 0.2) }, candidates: candidates, analyzed: SourceInterval(start: 0, end: 720))
    longProject.commit(longEdit)
    for index in 1...40 { longProject.commit(TimelineEditing.split(longProject.edit, at: Double(index) * 14)) }
    try longProject.validate()
    let historyEncoder = JSONEncoder(); historyEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let historyBytes = try historyEncoder.encode(longProject).count
    let historyDisk = ProjectDisk(root: root.appendingPathComponent("pause-history-size"))
    try historyDisk.save(longProject)
    let manifest = historyDisk.folder(longProject.id).appendingPathComponent("project.json")
    let manifestBytes = try Data(contentsOf: manifest).count
    let payloads = try FileManager.default.contentsOfDirectory(at: historyDisk.folder(longProject.id).appendingPathComponent("History"), includingPropertiesForKeys: nil)
    let payloadBytes = try payloads.map { try Data(contentsOf: $0).count }
    // The project manifest now references immutable snapshots; inline archive
    // JSON includes both video and audio maps, so its old 3 MB bound is obsolete.
    try require(manifestBytes < 32_000 && (payloadBytes.max() ?? 0) < 150_000 && payloadBytes.reduce(0, +) < 3_000_000,
                "Pause history stores a small manifest and bounded immutable snapshots: \(manifestBytes), \(payloadBytes.max() ?? 0), \(payloadBytes.reduce(0, +)) bytes")
    try require(longProject.edit.clips.allSatisfy { clip in (clip.pauses?.candidates ?? []).allSatisfy { $0.raw.start < clip.end && $0.raw.end > clip.start } }, "Split pieces keep only their own pause metadata")
    print("TOOLS: 12-minute / 140-pause / 40-split history \(historyBytes) bytes pretty-printed")
    print("TOOLS: persistence, selection, speed/pause source mapping passed")
    for source in [CGSize(width: 1920, height: 1080), CGSize(width: 1080, height: 1920)] {
        for aspect in [16.0 / 9, 9.0 / 16, 1.0, 4.0 / 5] {
            let canvas = OutputShape.canvas(source: source, aspect: aspect)
            for zoom in [1.0, 2.0, 8.0] {
                let area = CropSettings(x: 0.98, y: 0.02, zoom: zoom).rect(source: source, canvas: canvas)
                try require(area.minX >= -0.00001 && area.minY >= -0.00001 && area.maxX <= source.width + 0.00001 && area.maxY <= source.height + 0.00001, "Crop at an edge always stays inside the source")
                try require(abs(area.width / area.height - canvas.width / canvas.height) < 0.00001, "Crop never stretches the selected area")
            }
        }
    }
    let oddSource = CGSize(width: 1179, height: 2556), evenCanvas = CGSize(width: 1180, height: 2556)
    try require(CropSettings().isFullFrame(source: oddSource, canvas: evenCanvas), "Even-pixel rounding of odd imported media does not create a crop")
    try require(!CropSettings(zoom: 1.01).isFullFrame(source: oddSource, canvas: evenCanvas), "A deliberate zoom remains an edit on odd imported media")
    try require(!CropSettings().isFullFrame(source: oddSource, canvas: CGSize(width: 1080, height: 1920)), "A different aspect still crops odd imported media")
    var cropEdit = reopened.edit
    cropEdit.outputSize = CGSize(width: 360, height: 640)
    cropEdit.clips[0].crop = CropSettings(x: 0.75, y: 0.3, zoom: 2, rotation: 17)
    var cropProject = reopened; cropProject.commit(cropEdit)
    var cropReopened = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(cropProject))
    cropReopened.undo(); cropReopened.redo(); try cropReopened.validate()
    try require(cropReopened.edit == cropEdit, "Crop and output format survive reopening and undo/redo")
    let cropSplit = TimelineEditing.split(cropEdit, at: 1)
    try require(cropSplit.outputSize == cropEdit.outputSize && cropSplit.clips.allSatisfy { $0.crop == cropEdit.clips[0].crop }, "Splitting preserves crop identity and output format")
    if CommandLine.arguments.contains("--core-only") { return }
    let folder = root.appendingPathComponent("tools", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: root.appendingPathComponent("source.mp4"), to: folder.appendingPathComponent("source.mp4"))
    for rate in [0.5, 2.0] {
        var candidate = reopened
        var state = candidate.edit; state.clips[0].speed = SpeedSettings(rate: rate); state.clips[0].texts = nil; state.clips[0].color = nil
        candidate.commit(state)
        let output = folder.appendingPathComponent("speed-\(rate).mp4")
        _ = try await MediaRenderer.render(project: candidate, folder: folder, destination: output) { _ in }
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        print("TOOLS: checking \(rate)× duration \(duration), expected \(4 / rate)")
        try require(abs(duration - 4 / rate) < 0.04, "Speed export duration matches timeline")
        let pcm = folder.appendingPathComponent("speed-\(rate).caf")
        _ = try await MediaRenderer.processedAudio(asset: asset, duration: duration, effects: [], outputURL: pcm) { _ in }
        let file = try AVAudioFile(forReading: pcm, commonFormat: .pcmFormatFloat32, interleaved: false)
        file.framePosition = 24000
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48000)!
        try file.read(into: buffer)
        let samples = buffer.floatChannelData![0]
        var crossings = 0
        for index in 1..<Int(buffer.frameLength) { if samples[index - 1] <= 0 && samples[index] > 0 { crossings += 1 } }
        let frequency = Double(crossings) * 48000 / Double(buffer.frameLength)
        try require(abs(frequency - 1000) < 15, "Pitch stays at 1 kHz for \(rate)× export, measured \(frequency)")
        print("TOOLS: \(rate)× exported \(duration)s, retained pitch \(frequency) Hz")
    }
    // Exercise the real custom compositor and exported output, not just settings.
    var visual = reopened
    var visualState = visual.edit; visualState.clips[0].speed = nil
    visualState.clips[0].color = ColorSettings(look: .mono)
    visualState.clips[0].texts = [TextOverlay(text: "YouRec", start: 1, end: 3, x: 0.5, y: 0.5, size: 0.15, style: .highlight, color: .yellow)]
    visual.commit(visualState)
    let visualOutput = folder.appendingPathComponent("text-lut.mp4")
    _ = try await MediaRenderer.render(project: visual, folder: folder, destination: visualOutput) { _ in }
    let media = try await MediaRenderer.timeline(project: visual, folder: folder)
    try require(media.playbackVideoComposition != nil, "Visual effects are active in editor playback")
    let previewGenerator = AVAssetImageGenerator(asset: media.composition); previewGenerator.videoComposition = media.videoComposition
    previewGenerator.requestedTimeToleranceBefore = .zero; previewGenerator.requestedTimeToleranceAfter = .zero
    let exportGenerator = AVAssetImageGenerator(asset: AVURLAsset(url: visualOutput)); exportGenerator.appliesPreferredTrackTransform = true
    exportGenerator.requestedTimeToleranceBefore = .zero; exportGenerator.requestedTimeToleranceAfter = .zero
    func rgb(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { memory in
            let context = CGContext(data: memory.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }
    for time in [0.5, 1.5, 3.5] {
        let stamp = CMTime(seconds: time, preferredTimescale: 60000)
        let preview = try await previewGenerator.image(at: stamp).image
        let exported = try await exportGenerator.image(at: stamp).image
        try require(exported.width == 640 && exported.height == 360, "Compositor preserves landscape orientation")
        let a = rgb(preview), b = rgb(exported)
        let error = zip(a, b).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(a.count)
        let diagnostic = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".benchmarks/tools-qa")
        try FileManager.default.createDirectory(at: diagnostic, withIntermediateDirectories: true)
        for (name, image) in [("preview", preview), ("export", exported)] {
            if let destination = CGImageDestinationCreateWithURL(diagnostic.appendingPathComponent("\(name)-\(time).png") as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, image, nil); CGImageDestinationFinalize(destination)
            }
        }
        print("TOOLS: visual error \(error), preview color \(String(describing: preview.colorSpace)), export color \(String(describing: exported.colorSpace))")
        try require(error < 8, "Text/LUT preview matches export (mean channel error \(error))")
        var colored = 0
        for index in stride(from: 0, to: b.count, by: 4) { if abs(Int(b[index]) - Int(b[index + 2])) > 35 { colored += 1 } }
        if time == 1.5 { try require(colored > 200, "Colored title appears inside its time range") }
        else { try require(colored < 100, "Title absent outside its range and Mono LUT removes chroma") }
        print("TOOLS: text/LUT frame \(time)s matches export, error \(error), colored pixels \(colored)")
    }

    let portraitURL = folder.appendingPathComponent("portrait.mp4")
    try FileManager.default.copyItem(at: root.appendingPathComponent("portrait.mp4"), to: portraitURL)
    var portrait = Project(title: "Portrait tools")
    portrait.append(SourceMedia(filename: "portrait.mp4", duration: 4))
    var portraitState = portrait.edit
    portraitState.clips[0].stabilization = StabilizationSettings(level: .light)
    portrait.commit(portraitState)
    let pose = StabilizationPose(x: 4, y: -3, angle: 0.02)
    let knownPlan = StabilizationPlan(size: CGSize(width: 640, height: 360), samples: [StabilizationSample(time: 0, pose: pose, segment: 0)], zoom: 1.1, strengthLimited: false, trackingFraction: 1)
    let defaultMedia = try await MediaRenderer.timeline(project: portrait, folder: folder, stabilizationPlans: [portraitState.clips[0].id: knownPlan])
    // Compare geometry in the same output color space; an untagged SD fixture
    // otherwise makes the native compositor choose Composite NTSC by default.
    defaultMedia.videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
    defaultMedia.videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
    defaultMedia.videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
    portraitState.clips[0].color = ColorSettings(look: .natural); portrait.commit(portraitState)
    let customMedia = try await MediaRenderer.timeline(project: portrait, folder: folder, stabilizationPlans: [portraitState.clips[0].id: knownPlan])
    var frames: [[UInt8]] = []
    for media in [defaultMedia, customMedia] {
        let generator = AVAssetImageGenerator(asset: media.composition); generator.videoComposition = media.videoComposition
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let frame = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 60000)).image
        try require(frame.width == 360 && frame.height == 640, "Portrait orientation retained with stabilization and LUT compositor")
        let diagnostic = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".benchmarks/tools-qa/portrait-\(frames.count).png")
        if let destination = CGImageDestinationCreateWithURL(diagnostic as CFURL, "public.png" as CFString, 1, nil) { CGImageDestinationAddImage(destination, frame, nil); CGImageDestinationFinalize(destination) }
        print("TOOLS: portrait \(frames.count), colors \(String(describing: frame.colorSpace))")
        frames.append(rgb(frame))
    }
    let alignmentError = zip(frames[0], frames[1]).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(frames[0].count)
    try require(alignmentError < 6, "Custom compositor matches native stabilization/orientation: \(alignmentError)")
    print("TOOLS: portrait stabilization alignment error \(alignmentError)")
    var combination = reopened
    var combined = combination.edit
    combined.clips[0].speed = SpeedSettings(rate: 1.5)
    combined.clips[0].pauses = PauseSettings(cuts: [SourceInterval(start: 1, end: 2)], candidates: [DetectedPause(raw: SourceInterval(start: 0.88, end: 2.18))])
    combined = TimelineEditing.split(combined, at: 1)
    combination.commit(combined); try combination.validate()
    let combinedOutput = folder.appendingPathComponent("combined.mp4")
    _ = try await MediaRenderer.render(project: combination, folder: folder, destination: combinedOutput) { _ in }
    let combinedDuration = try await AVURLAsset(url: combinedOutput).load(.duration).seconds
    try require(abs(combinedDuration - 2) < 0.04, "Combined pauses, speed, text, color and split export correct duration")
    print("TOOLS: combined pause/speed/text/LUT/split exported \(combinedDuration)s")

    var mixed = Project(title: "Mixed orientation text")
    mixed.append(SourceMedia(filename: "source.mp4", duration: 4))
    mixed.append(SourceMedia(filename: "portrait.mp4", duration: 4))
    var mixedEdit = mixed.edit
    mixedEdit.clips[1].texts = [TextOverlay(text: "Bottom caption", start: 0, end: 4, x: 0.5, y: 0.8, style: .box)]
    mixed.commit(mixedEdit)
    let fullMedia = try await MediaRenderer.timeline(project: mixed, folder: folder)
    var subset = mixed; var subsetEdit = mixedEdit; subsetEdit.clips = [mixedEdit.clips[1]]; subset.commit(subsetEdit)
    let survivingPortrait = try await MediaRenderer.timeline(project: subset, folder: folder)
    try require(survivingPortrait.videoComposition.renderSize == CGSize(width: 360, height: 640),
                "Deleting the only landscape video respects the surviving source's portrait track transform")
    var prepended = mixed
    var reordered = prepended.edit; reordered.clips.reverse(); prepended.commit(reordered)
    let reorderedMedia = try await MediaRenderer.timeline(project: prepended, folder: folder)
    try require(reorderedMedia.videoComposition.renderSize == CGSize(width: 640, height: 360),
                "A portrait clip moved ahead of the landscape reference cannot change the project canvas")
    let projectCanvas = try await MediaRenderer.canvas(project: mixed, folder: folder)
    let scopedMedia = try await MediaRenderer.timeline(project: subset, folder: folder, canvasSize: projectCanvas)
    var mixedFrames: [[UInt8]] = []
    for (media, time) in [(fullMedia, 5.0), (scopedMedia, 1.0)] {
        let generator = AVAssetImageGenerator(asset: media.composition); generator.videoComposition = media.videoComposition
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let frame = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 60000)).image
        try require(frame.width == 640 && frame.height == 360, "Scoped tool preview uses the entire project's canvas")
        mixedFrames.append(rgb(frame))
    }
    let mixedError = zip(mixedFrames[0], mixedFrames[1]).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(mixedFrames[0].count)
    try require(mixedError < 1, "Mixed-orientation text placement matches full-project export, error \(mixedError)")
    print("TOOLS: mixed-orientation scoped text matches full timeline, error \(mixedError)")
    try FileManager.default.copyItem(at: root.appendingPathComponent("audio-tail.mp4"), to: folder.appendingPathComponent("audio-tail.mp4"))
    let tailDuration = try await AVURLAsset(url: folder.appendingPathComponent("audio-tail.mp4")).load(.duration).seconds
    var tail = Project(title: "Longer audio track"); tail.append(SourceMedia(filename: "audio-tail.mp4", duration: tailDuration))
    var tailEdit = tail.edit; tailEdit.clips[0].color = ColorSettings(look: .warm)
    tailEdit.clips[0].texts = [TextOverlay(text: "Outro", start: 3.5, end: tailDuration)]
    tail.commit(tailEdit)
    let tailOutput = folder.appendingPathComponent("tail-export.mp4")
    _ = try await MediaRenderer.render(project: tail, folder: folder, destination: tailOutput) { _ in }
    let tailExportDuration = try await AVURLAsset(url: tailOutput).load(.duration).seconds
    try require(abs(tailExportDuration - tailDuration) < 0.04, "Custom compositor exports audio extending past the last video frame")
    print("TOOLS: empty video tail with text/LUT exports \(tailExportDuration)s")

    var cropBase = Project(title: "Crop visual geometry")
    cropBase.append(SourceMedia(filename: "source.mp4", duration: 4))
    var baseEdit = cropBase.edit; baseEdit.clips[0].color = ColorSettings(look: .natural)
    cropBase.commit(baseEdit)
    let baselineMedia = try await MediaRenderer.timeline(project: cropBase, folder: folder)
    let baselineGenerator = AVAssetImageGenerator(asset: baselineMedia.composition); baselineGenerator.videoComposition = baselineMedia.videoComposition
    baselineGenerator.requestedTimeToleranceBefore = .zero; baselineGenerator.requestedTimeToleranceAfter = .zero
    let baselineFrame = try await baselineGenerator.image(at: CMTime(seconds: 1, preferredTimescale: 60000)).image
    var cropped = cropBase; var croppedEdit = baseEdit
    croppedEdit.clips[0].crop = CropSettings(x: 0.75, y: 0.25, zoom: 2)
    cropped.commit(croppedEdit)
    let cropOutput = folder.appendingPathComponent("crop.mp4")
    _ = try await MediaRenderer.render(project: cropped, folder: folder, destination: cropOutput) { _ in }
    let cropMedia = try await MediaRenderer.timeline(project: cropped, folder: folder)
    let cropGenerator = AVAssetImageGenerator(asset: cropMedia.composition); cropGenerator.videoComposition = cropMedia.videoComposition
    cropGenerator.requestedTimeToleranceBefore = .zero; cropGenerator.requestedTimeToleranceAfter = .zero
    let cropFrame = try await cropGenerator.image(at: CMTime(seconds: 1, preferredTimescale: 60000)).image
    let selected = baselineFrame.cropping(to: CGRect(x: 320, y: 0, width: 320, height: 180))!
    let expectedContext = CGContext(data: nil, width: 640, height: 360, bitsPerComponent: 8, bytesPerRow: 640 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    expectedContext.interpolationQuality = .high; expectedContext.draw(selected, in: CGRect(x: 0, y: 0, width: 640, height: 360))
    let expectedPixels = rgb(expectedContext.makeImage()!), cropPixels = rgb(cropFrame)
    let cropError = zip(expectedPixels, cropPixels).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(cropPixels.count)
    try require(cropError < 8, "Actual crop matches the chosen top-right source area: \(cropError)")
    let cropExportGenerator = AVAssetImageGenerator(asset: AVURLAsset(url: cropOutput)); cropExportGenerator.appliesPreferredTrackTransform = true
    let cropExport = try await cropExportGenerator.image(at: CMTime(seconds: 1, preferredTimescale: 60000)).image
    let cropExportError = zip(rgb(cropExport), cropPixels).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(cropPixels.count)
    try require(cropExportError < 8, "Crop preview matches exported pixels: \(cropExportError)")
    for angle in [17.0, 90.0] {
        var paths: [[UInt8]] = []
        for custom in [false, true] {
            var rotated = cropBase, state = baseEdit
            state.clips[0].color = custom ? ColorSettings(look: .natural) : nil
            state.clips[0].crop = CropSettings(rotation: angle); rotated.commit(state)
            let media = try await MediaRenderer.timeline(project: rotated, folder: folder)
            media.videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
            media.videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
            media.videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
            let generator = AVAssetImageGenerator(asset: media.composition); generator.videoComposition = media.videoComposition
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            let frame = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 60000)).image
            let preview = rgb(frame); paths.append(preview)
            let output = folder.appendingPathComponent("rotation-\(angle)-\(custom).mp4")
            _ = try await MediaRenderer.render(project: rotated, folder: folder, destination: output) {_ in}
            let exported = AVAssetImageGenerator(asset: AVURLAsset(url: output)); exported.appliesPreferredTrackTransform = true
            exported.requestedTimeToleranceBefore = .zero; exported.requestedTimeToleranceAfter = .zero
            let pixels = rgb(try await exported.image(at: CMTime(seconds: 1, preferredTimescale: 60000)).image)
            let error = zip(preview,pixels).reduce(0.0) {$0+abs(Double($1.0)-Double($1.1))}/Double(preview.count)
            try require(error < 8, "Rotated crop preview matches export at \(angle)°, custom \(custom): \(error)")
            if angle == 90 {
                let turned = CIImage(cgImage: baselineFrame).oriented(.right)
                let scale = 640.0/turned.extent.width
                let expected = turned.transformed(by: CGAffineTransform(translationX: -turned.extent.midX, y: -turned.extent.midY))
                    .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    .transformed(by: CGAffineTransform(translationX: 320, y: 180))
                let image = CIContext().createCGImage(expected, from: CGRect(x: 0,y: 0,width: 640,height: 360))!
                let directionError = zip(preview,rgb(image)).reduce(0.0) {$0+abs(Double($1.0)-Double($1.1))}/Double(preview.count)
                try require(directionError < 8, "90° is clockwise and fills the unchanged canvas: \(directionError)")
            }
        }
        let agreement = zip(paths[0],paths[1]).reduce(0.0) {$0+abs(Double($1.0)-Double($1.1))}/Double(paths[0].count)
        try require(agreement < 8, "Native and custom crop rotation agree at \(angle)°: \(agreement)")
    }
    var formatEdit = cropped.edit; formatEdit.outputSize = CGSize(width: 360, height: 640); cropped.commit(formatEdit)
    let verticalMedia = try await MediaRenderer.timeline(project: cropped, folder: folder)
    try require(verticalMedia.videoComposition.renderSize == CGSize(width: 360, height: 640), "Portrait format changes the actual render dimensions")
    var nativeCrop = cropped; var nativeEdit = cropped.edit; nativeEdit.clips[0].color = nil; nativeCrop.commit(nativeEdit)
    let nativeCropMedia = try await MediaRenderer.timeline(project: nativeCrop, folder: folder)
    try require(nativeCropMedia.playbackVideoComposition != nil && nativeCropMedia.videoComposition.customVideoCompositorClass == nil, "Crop-only playback uses the native compositor with its framing transform active")
    let verticalOutput = folder.appendingPathComponent("vertical-crop.mp4")
    _ = try await MediaRenderer.render(project: nativeCrop, folder: folder, destination: verticalOutput) { _ in }
    let verticalTrack = try await AVURLAsset(url: verticalOutput).loadTracks(withMediaType: .video).first!
    let verticalSize = try await verticalTrack.load(.naturalSize)
    try require(verticalSize == CGSize(width: 360, height: 640), "Native crop export retains the pinned vertical size")
    var pinnedMixed = mixed, pinnedEdit = mixed.edit
    pinnedEdit.outputSize = CGSize(width: 640, height: 360); pinnedEdit.clips[0].crop = CropSettings(zoom: 2)
    pinnedEdit.clips.reverse(); pinnedMixed.commit(pinnedEdit)
    let pinnedCanvas = try await MediaRenderer.canvas(project: pinnedMixed, folder: folder)
    let pinnedMedia = try await MediaRenderer.timeline(project: pinnedMixed, folder: folder)
    try require(pinnedCanvas == CGSize(width: 640, height: 360) && pinnedMedia.videoComposition.renderSize == pinnedCanvas, "Reordering portrait footage to the front cannot change a pinned canvas")
    var portraitCrop = portrait, portraitCropEdit = portrait.edit
    portraitCropEdit.clips[0].crop = CropSettings(x: 0.35, y: 0.7, zoom: 1.8); portraitCrop.commit(portraitCropEdit)
    var cropPaths: [[UInt8]] = []
    for custom in [false, true] {
        portraitCropEdit.clips[0].color = custom ? ColorSettings(look: .natural) : nil; portraitCrop.commit(portraitCropEdit)
        let media = try await MediaRenderer.timeline(project: portraitCrop, folder: folder, stabilizationPlans: [portraitCropEdit.clips[0].id: knownPlan])
        media.videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        media.videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        media.videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        let generator = AVAssetImageGenerator(asset: media.composition); generator.videoComposition = media.videoComposition
        let frame = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 60000)).image
        try require(frame.width == 360 && frame.height == 640, "Crop respects portrait metadata with stabilization")
        cropPaths.append(rgb(frame))
    }
    let portraitCropError = zip(cropPaths[0], cropPaths[1]).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(cropPaths[0].count)
    try require(portraitCropError < 8, "Crop + portrait rotation + stabilization agrees on native/custom paths: \(portraitCropError)")
    print("CROP: portrait stabilization/compositor alignment \(portraitCropError), native vertical export and pinned reorder passed")
    print("CROP: selected-area error \(cropError), preview/export error \(cropExportError); geometry, format and persistent undo passed")

    // Mirrors are verified against decoded pixels on both native and custom paths.
    for axes in [(true, false), (false, true), (true, true)] {
        var mirrorProject = cropBase, state = baseEdit
        state.clips[0].mirror = MirrorSettings(horizontal: axes.0, vertical: axes.1); mirrorProject.commit(state)
        let media = try await MediaRenderer.timeline(project: mirrorProject, folder: folder)
        let generator = AVAssetImageGenerator(asset: media.composition); generator.videoComposition = media.videoComposition
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let actual = rgb(try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 60000)).image)
        let original = rgb(baselineFrame)
        var error = 0.0
        for y in 0..<360 { for x in 0..<640 {
            let from = ((axes.1 ? 359 - y : y) * 640 + (axes.0 ? 639 - x : x)) * 4
            let to = (y * 640 + x) * 4
            for channel in 0..<3 { error += abs(Double(actual[to + channel]) - Double(original[from + channel])) }
        } }
        try require(error / (640 * 360 * 3) < 8, "Horizontal/vertical mirror reflects actual pixels without changing framing")
    }
    let alphaBounds = CGRect(x: 0, y: 0, width: 1, height: 1)
    let alphaContext = CIContext()
    for amount in [0.0, 0.5, 1.0] {
        let blend = ImageOverlayRenderer.composite(CIImage(color: .white).cropped(to: alphaBounds), opacity: amount,
                                                   over: CIImage(color: .black).cropped(to: alphaBounds))
        let rendered = alphaContext.createCGImage(blend, from: alphaBounds, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
        let pixel = rgb(rendered)
        try require(abs(Double(pixel[0]) - amount * 255) < 3, "Image opacity matches the encoded-space placement preview at zero, half and full strength")
    }
    let translucentBox = ImageOverlayRenderer.composite(CIImage(color: CIColor(red: 0.02, green: 0.02, blue: 0.02, alpha: 0.82)).cropped(to: alphaBounds), opacity: 1,
                                                       over: CIImage(color: .white).cropped(to: alphaBounds))
    let boxPixel = rgb(alphaContext.createCGImage(translucentBox, from: alphaBounds, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!)
    try require(boxPixel[0] < 60, "Translucent text backgrounds retain their preview contrast instead of turning gray during export")
    let bitmap = CGContext(data: nil, width: 100, height: 50, bitsPerComponent: 8, bytesPerRow: 400, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    bitmap.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)); bitmap.fill(CGRect(x: 10, y: 10, width: 80, height: 30))
    let imageURL = folder.appendingPathComponent("image-test.png")
    let imageDestination = CGImageDestinationCreateWithURL(imageURL as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(imageDestination, bitmap.makeImage()!, nil); CGImageDestinationFinalize(imageDestination)
    var overlayProject = cropBase, overlayEdit = baseEdit
    overlayEdit.clips[0].color = ColorSettings(look: .mono)
    overlayEdit.clips[0].mirror = MirrorSettings(horizontal: true)
    overlayEdit.clips[0].images = [ImageOverlay(filename: "image-test.png", start: 1, end: 2, x: 0.75, y: 0.25)]
    overlayProject.commit(overlayEdit); try overlayProject.validate()
    let imageOutput = folder.appendingPathComponent("image-export.mp4")
    _ = try await MediaRenderer.render(project: overlayProject, folder: folder, destination: imageOutput) { _ in }
    let imageGenerator = AVAssetImageGenerator(asset: AVURLAsset(url: imageOutput))
    imageGenerator.requestedTimeToleranceBefore = .zero; imageGenerator.requestedTimeToleranceAfter = .zero
    for time in [0.5, 1.5, 2.5] {
        let pixels = rgb(try await imageGenerator.image(at: CMTime(seconds: time, preferredTimescale: 60000)).image)
        var colored = 0, xSum = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            if pixels[index] > 180 && pixels[index + 1] < 70 && pixels[index + 2] > 180 { colored += 1; xSum += Double((index / 4) % 640) }
        }
        if time == 1.5 { try require(colored > 1000 && xSum / Double(colored) > 440, "Image remains on the right over mirrored footage, with its original color and transparency") }
        else { try require(colored < 100, "Image disappears outside its duration") }
    }
    overlayProject.undo()
    let imageArchive = root.appendingPathComponent("image-project.zip")
    try await ProjectArchive.export(overlayProject, folder: folder, destination: imageArchive) { _ in }
    let imageDisk = ProjectDisk(root: root.appendingPathComponent("image-restored"))
    var archived = try await ProjectArchive.restore(imageArchive, disk: imageDisk) { _ in }
    try require(archived.canRedo && FileManager.default.fileExists(atPath: imageDisk.folder(archived.id).appendingPathComponent("image-test.png").path), "An image referenced only by redo history travels with the project archive")
    archived.redo(); try require(archived.edit == overlayEdit, "Archived image, mirror, and placement reopen exactly")
    try require(archived.schemaVersion == 6, "Older builds must reject new visual edits instead of silently discarding them")
    try FileManager.default.removeItem(at: imageDisk.folder(archived.id).appendingPathComponent("image-test.png"))
    let missingImageArchive = root.appendingPathComponent("missing-image-project.zip")
    try await ProjectArchive.export(archived, folder: imageDisk.folder(archived.id), destination: missingImageArchive) { _ in }
    let missingImageRestored = try await ProjectArchive.restore(missingImageArchive, disk: imageDisk) { _ in }
    try require(missingImageRestored.edit == overlayEdit && missingImageRestored.sources == archived.sources,
                "A missing overlay never prevents backing up recordings and full editing history")
    print("TOOLS: exact boundary insertion/cut, mirror pixels, image timing/orientation/transparency and archive redo passed")

}

private func effectQuickRemovalTests() throws {
    var project=Project(title:"Quick removal")
    project.append(SourceMedia(filename:"source.mp4",duration:8))
    let source=project.edit
    var edit=TimelineEditing.split(source,at:4)
    let look=VideoEffectSettings(.noir,start:0,end:8),other=VideoEffectSettings(.silentTint,start:0,end:8)
    let overlay=TextOverlay(text:"Keep the other section",start:0,end:8),speed=SpeedSettings(rate:2)
    for i in edit.clips.indices {edit.clips[i].videoEffects=[look,other];edit.clips[i].texts=[overlay];edit.clips[i].speed=speed}
    let all=Set(edit.clips.map(\.id))
    let request=ToolRequest(tool:.videoEffects,range:0...edit.duration,scopeTitle:"Both",effectID:look.id,clipIDs:all)
    let removed=edit.removingTool(request)
    try require(removed.clips.allSatisfy {$0.videoEffects==[other] && $0.texts==[overlay] && $0.speed==speed},"Quick removal follows shared effect identity and preserves other effects")
    try require(removed.clips.map(\.start)==edit.clips.map(\.start) && removed.clips.map(\.end)==edit.clips.map(\.end),"Removing an effect never trims source footage")
    let overlayRemoval=edit.removingTool(ToolRequest(tool:.text,range:0...2,scopeTitle:"This section",effectID:overlay.id,clipIDs:[edit.clips[0].id]))
    try require(overlayRemoval.clips[0].texts?.isEmpty==true && overlayRemoval.clips[1].texts==[overlay],"Removing a separated overlay respects the same scope as editing it")
    let regular=edit.removingTool(ToolRequest(tool:.speed,range:0...4,scopeTitle:"Speed",effectID:speed.id,clipIDs:all))
    try require(regular.duration==8 && regular.clips.allSatisfy {$0.speed==nil && $0.videoEffects==[look,other]},"Removing speed restores timing and keeps other tools")
    project.commit(edit);project.commit(removed);project.undo()
    try require(project.edit==edit,"One Undo restores the deleted effect and its complete settings")
    project.redo();try project.validate()
    try require(project.edit==removed && project.sources.count==1,"Redo removes the effect without deleting source media")
    let held=TimelineEditing.freezing(source,at:3)
    let unfrozen=held.0.removingTool(ToolRequest(tool:.videoEffects,range:3...6,scopeTitle:"Hold",effectID:held.1))
    try require(unfrozen.duration==8 && unfrozen.clips.allSatisfy {$0.frozenFrame==nil} && unfrozen.clips.first?.start==0 && unfrozen.clips.last?.end==8,"Deleting Freeze Frame removes only inserted hold time")
    var joined=TimelineEditing.split(source,at:4);let transition=ClipTransition(nextClipID:joined.clips[1].id,duration:1)
    joined=joined.settingTransition(transition,at:1)
    let cut=joined.removingTool(ToolRequest(tool:.transition,range:3...4,scopeTitle:"Boundary",effectID:transition.id,boundaryIndex:1))
    try require(cut.duration==source.duration && cut.clips[0].transition==nil && cut.timeline.video[0].end==cut.timeline.video[1].start,"Deleting a transition restores a straight cut with all source footage")
    print("PASS: quick effect removal preserves footage, scope, unrelated effects, Undo/Redo and transition/hold timing")
}

func cropRotationAndUnknownEffectTests() throws {
    for source in [CGSize(width:1920,height:1080),CGSize(width:1080,height:1920)] {
        for aspect in [16.0/9,9.0/16,1.0,4.0/5] {
            let canvas=OutputShape.canvas(source:source,aspect:aspect)
            for angle in [-180.0,-135,-90,-45,-17,0,17,45,90,135,180] {
                for zoom in [1.0,2,8] {
                    let crop=CropSettings(x:0.98,y:0.02,zoom:zoom,rotation:angle)
                    let inverse=crop.transform(source:source,canvas:canvas).inverted()
                    for corner in [CGPoint.zero,CGPoint(x:canvas.width,y:0),CGPoint(x:0,y:canvas.height),CGPoint(x:canvas.width,y:canvas.height)] {
                        let point=corner.applying(inverse)
                        try require(point.x >= -0.00001 && point.y >= -0.00001 && point.x <= source.width+0.00001 && point.y <= source.height+0.00001,"Rotation, aspect, pan and zoom never expose an empty corner")
                    }
                }
            }
        }
    }
    try require(!CropSettings(rotation:180).isFullFrame(source:CGSize(width:1920,height:1080),canvas:CGSize(width:1920,height:1080)),"An upside-down full frame remains a real edit")
    var project=Project(title:"Unknown effects")
    project.append(SourceMedia(filename:"source.mp4",duration:4,videoEffects:[VideoEffectSettings(.noir)]))
    project.commit(TimelineEditing.split(project.edit,at:2))
    func inject(_ object:Any)->Any {
        if let dict=object as? [String:Any] {
            return dict.mapValues {inject($0)}.merging(dict["videoEffects"].map {value in ["videoEffects":(value as! [Any])+[["kind":"dutchAngle"],["kind":"futureEffect"]]]} ?? [:]) {_,new in new}
        }
        if let array=object as? [Any] {return array.map(inject)}
        return object
    }
    let object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(project))
    var reopened=try JSONDecoder().decode(Project.self,from:JSONSerialization.data(withJSONObject:inject(object)))
    try reopened.validate()
    try require(reopened.sources==project.sources && reopened.history==project.history && reopened.id==project.id,"Unknown effects in sources and every history entry are ignored; known edits remain")
    reopened.undo();reopened.redo();try reopened.validate()
    print("PASS: rotated crop coverage and unknown-effect project/history loading")
}

private func splitEffectScopeTests() throws {
    var project = Project(title: "Independent split effects")
    project.append(SourceMedia(filename: "source.mp4", duration: 8))
    var state = project.edit
    state.clips[0].videoEffects = [VideoEffectSettings(.noir, start: 0, end: 8), VideoEffectSettings(.silentTint, start: 0, end: 8)]
    state.clips[0].texts = [TextOverlay(text: "Across the cut", start: 0, end: 8)]
    state.clips[0].images = [ImageOverlay(filename: "image-overlay.png", end: 8)]
    state.clips[0].crop = CropSettings(zoom: 1.2)
    state.clips[0].color = ColorSettings(look: .warm)
    state.clips[0].mirror = MirrorSettings(horizontal: true)
    state.clips[0].speed = SpeedSettings(rate: 1)
    state.clips[0].stabilization = StabilizationSettings(level: .standard, id: UUID())
    state.timeline.enhance([AudioEffect(kind: .gain, amount: -3)], selection: state.timeline.entireSelection())
    state = TimelineEditing.split(state, at: 4)
    let left = state.clips[0].id, right = state.clips[1].id
    for region in state.toolRegions where region.clipID == left {
        let request = state.request(for: region)
        try require(request.clipIDs == [left] && request.videoScope(in: state).1 == [left], "A split badge scopes only its own picture: \(region.tool)")
        let removed = state.removingTool(request)
        try require(removed.clips.first { $0.id == right } == state.clips[1], "Removing \(region.tool) leaves the other split's complete settings untouched")
        try require(!removed.toolRegions.contains { $0.clipID == left && $0.effectID == region.effectID }, "The chosen section actually loses \(region.tool)")
        let both = state.request(for: region, selection: TimelineSelection(video: [left, right]))
        try require(both.clipIDs == [left, right], "Explicit multiple selection can still edit a shared effect together")
        try require(!state.removingTool(both).toolRegions.contains { $0.effectID == region.effectID }, "Explicit multi-remove affects both selected sections")
    }
    let look = state.toolRegions.first { $0.clipID == left && $0.tool == .videoEffects }!
    let partial = state.request(for: look, selection: TimelineSelection(video: [left], range: EditInterval(1...3)))
    let removedRange = state.removingTool(partial)
    try require(removedRange.toolRegions.filter { $0.effectID == look.effectID }.map(\.range) == [0...1, 3...4, 4...8], "A marked-range removal preserves the effect before and after the range, including the other split")
    let joined = EditState(timeline: try state.timeline.joining(state.timeline.entireSelection()).timeline)
    let (draft, ids) = joined.request(for: look).videoScope(in: joined)
    try require(ids == [left] && draft == joined, "A horizontal link does not silently expand a badge's edit scope")

    let audio = state.toolRegions.first { $0.tool == .enhanceAudio }!
    let otherAudio = state.timeline.audio[1]
    let audioRequest = state.request(for: audio, selection: state.timeline.selection(of: left))
    let audioRemoved = state.removingTool(audioRequest)
    try require(audioRemoved.timeline.audio[0].enhancements.isEmpty && audioRemoved.timeline.audio[1] == otherAudio, "Audio-chain removal after Split preserves the other section")
    let audioPart = state.request(for: audio, selection: TimelineSelection(audio: [audio.clipID], range: EditInterval(1...3)))
    let audioRange = state.removingTool(audioPart)
    try require(audioRange.timeline.audio[0].enhancements.map(\.interval) == [EditInterval(0...1), EditInterval(3...4)] && audioRange.timeline.audio[1] == otherAudio, "Partial audio-chain removal retains both outside ranges and the neighboring clip")
    var editedAudio = state
    editedAudio.timeline.enhance([AudioEffect(kind: .gain, amount: -9)], selection: audioRequest.targets!, effectID: audio.effectID)
    try require(editedAudio.timeline.audio[1] == otherAudio && editedAudio.timeline.audio[0] != state.timeline.audio[0], "Editing a split chain is independent as well as removing it")
    project.commit(state); project.commit(audioRemoved)
    var reopened = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
    reopened.undo(); try require(reopened.edit == state, "Undo after reopening restores both split chains")
    reopened.redo(); try require(reopened.edit == audioRemoved, "Redo after reopening preserves the untouched split")
    print("PASS: split effect edit/removal scopes, explicit multi-selection, marked ranges, horizontal links and reopened Undo/Redo")
}
