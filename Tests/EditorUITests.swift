import XCTest
import ObjectiveC

final class EditorUITests: XCTestCase {
    func testLiquidGlassShowcase() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["YOUREC_RECORD_SHOWCASE"] == "1" || environment["TEST_RUNNER_YOUREC_RECORD_SHOWCASE"] == "1" else {
            throw XCTSkip("Run explicitly with the staged simulator showcase image")
        }
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--recorder-controls-test", "--liquid-glass-showcase", "-fitRecordedFrame", "NO", "-zoomTransitionSeconds", "0",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL", "-liveVideoEffects", "<5b5d>"]
        app.launch()
        XCTAssertTrue(app.staticTexts["recorder.projectTitle"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["recorder.projectTitle"].label, "Neon Coast")
        func pause(_ seconds: Double = 1) { Thread.sleep(forTimeInterval: seconds) }
        func marker(_ name: String) {
            FileHandle.standardOutput.write(Data("YOUREC_SHOWCASE_\(name) \(Date().timeIntervalSince1970)\n".utf8))
        }
        func shot(_ name: String) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        marker("BEGIN"); pause(2)
        shot("Showcase camera")
        app.buttons["recorder.zoom"].tap(); pause(1.2)
        XCTAssertTrue(app.buttons["recorder.zoom.preset.10"].isHittable)
        shot("Showcase zoom glass")
        app.buttons["recorder.zoom"].tap()

        app.buttons["recorder.microphone"].tap(); pause()
        XCTAssertFalse(app.buttons["recorder.gainReset"].exists)
        let gain = app.sliders["recorder.gain"]
        gain.adjust(toNormalizedSliderPosition: 1); pause(0.6)
        dragRecordingGainToZero(gain, fromUpperEnd: true); pause(1.3)
        XCTAssertTrue(app.staticTexts["recorder.gainValue"].label.replacingOccurrences(of: ",", with: ".").contains("+0.0"))
        shot("Showcase microphone zero detent")
        app.buttons["recorder.gainMicrophone"].tap(); pause(0.7)
        app.buttons["Studio Wireless"].tap(); pause(0.7)
        app.buttons["recorder.audioDone"].tap()

        app.buttons["recorder.settings"].tap(); pause(1.2)
        shot("Showcase settings compact")
        expandCameraSheet(in: app); pause()
        let settingsList = app.descendants(matching: .any)["recorder.settingsControls"].firstMatch
        revealInViewport(app.staticTexts["recorder.colorNotice"], scroll: settingsList); pause()
        shot("Showcase camera settings typography")
        revealInViewport(app.switches["recorder.mirrorPreview"], scroll: settingsList); pause()
        shot("Showcase settings expanded")
        XCTAssertFalse(app.staticTexts["This project"].exists)
        app.buttons["recorder.settingsDone"].tap()

        app.buttons["recorder.videoEffects"].tap(); pause(1.2)
        expandLiveEffects(in: app); pause()
        app.buttons["liveEffects.section.colorStyle"].coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0))
            .withOffset(CGVector(dx: 0, dy: 3)).tap(); pause(1.2)
        XCTAssertTrue(app.navigationBars["Color & style"].exists)
        shot("Showcase effects navigation")
        app.buttons["liveEffects.add.colorCorrection"].coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0))
            .withOffset(CGVector(dx: 0, dy: 3)).tap(); pause()
        app.sliders["colorCorrection.slider.exposure"].adjust(toNormalizedSliderPosition: 0.58); pause()
        app.buttons["colorCorrection.value.exposure"].tap(); pause(0.5)
        backFromLiveEffects(in: app); pause(0.6)
        shot("Showcase applied effects toolbar")
        app.buttons["liveEffects.actions"].tap(); pause()
        shot("Showcase effects actions menu")
        app.buttons["liveEffects.clear"].tap(); pause(0.7)
        dismissLiveEffects(in: app); pause(2)
        shot("Showcase closing camera")
        marker("END")
    }

    func testRecorderCreditsAndBundledLicenses() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--recorder-controls-test"]
        app.launch()
        let settings = app.buttons["recorder.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 20))
        settings.tap()
        expandCameraSheet(in: app)
        let credits = app.buttons["recorder.credits"]
        for _ in 0..<10 {
            if credits.exists && credits.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(credits.isHittable)
        credits.tap()
        XCTAssertTrue(app.navigationBars["Credits"].waitForExistence(timeout: 5))
        let copyright = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Copyright (C) 2026 by Salvatore Sanfilippo.")).firstMatch
        XCTAssertTrue(copyright.exists)
        XCTAssertTrue(copyright.label.contains("MIT License"))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Camera credits"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["credits.notices"].tap()
        let document = app.textViews["credits.licenseText"]
        XCTAssertTrue(document.waitForExistence(timeout: 5))
        let notices = document.value as? String ?? ""
        for attribution in ["Permission is hereby granted", "2026 Salvatore Sanfilippo", "RNNoise", "LavaSR", "ZIPFoundation", "DeepFilterNet3", "Qwen3-ASR", "VoiceFixer", "PocketFFT", "Creative Commons Attribution 4.0"] {
            XCTAssertTrue(notices.contains(attribution), "Missing bundled notice for \(attribution)")
        }
        app.navigationBars["License notices"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["credits.notices"].waitForExistence(timeout: 5))
        app.navigationBars["Credits"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Camera settings"].waitForExistence(timeout: 5))
    }

    private func revealInViewport(_ element: XCUIElement, scroll: XCUIElement, swipeX: CGFloat = 0.5) {
        for _ in 0..<16 {
            let viewport = scroll.frame.insetBy(dx: 0, dy: 25)
            if element.exists && element.isHittable && viewport.contains(CGPoint(x: element.frame.midX, y: element.frame.midY)) { return }
            let downward = element.exists && element.frame.midY < viewport.midY
            let a = scroll.coordinate(withNormalizedOffset: CGVector(dx: swipeX, dy: downward ? 0.4 : 0.65))
            let b = scroll.coordinate(withNormalizedOffset: CGVector(dx: swipeX, dy: downward ? 0.65 : 0.4))
            a.press(forDuration: 0.05, thenDragTo: b, withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        XCTFail("Could not reveal \(element.identifier) inside the scroll viewport")
    }
    func testLUTSwitchKeepsSelectedFrame() throws {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--frame-clock-fixture"]; app.launch()
        openTool("color", in: app); waitForTool(app)
        let seek = app.sliders["Tool preview position"], preview = app.otherElements["tool.preview"]
        let settings = app.scrollViews["tool.settings"]
        func choose(_ name: String) {
            let button = app.buttons["tool.look." + name]
            revealInViewport(button, scroll: settings); button.tap()
        }
        func pixels() throws -> [UInt8] {
            let image = try XCTUnwrap(preview.screenshot().image.cgImage)
            var bytes = [UInt8](repeating: 0, count: 96 * 96 * 4)
            let context = try XCTUnwrap(CGContext(data: &bytes, width: 96, height: 96, bitsPerComponent: 8, bytesPerRow: 96 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 96, height: 96)); return bytes
        }
        func frameDifference(_ a: [UInt8], _ b: [UInt8]) -> Double {
            // Inspect the timecode, excluding the unchanged letterbox bars.
            var sum = 0.0, count = 0
            for y in 32..<64 { for x in 36..<60 { for channel in 0..<3 {
                let i = (y * 96 + x) * 4 + channel
                sum += abs(Double(a[i]) - Double(b[i])); count += 1
            } } }
            return sum / Double(count)
        }
        var previous: [UInt8]?
        for fraction in [0.72, 0.18, 0.53] {
            seek.adjust(toNormalizedSliderPosition: fraction)
            Thread.sleep(forTimeInterval: 0.5)
            let position = app.staticTexts["tool.position"].label, reference = try pixels()
            if let previous {
                XCTAssertGreaterThan(frameDifference(previous, reference), 2, "The fixture must distinguish seeks; a static image cannot expose a stale-frame bug")
            }
            previous = reference
            choose("warm"); choose("cool"); choose("mono"); waitForTool(app)
            XCTAssertEqual(app.staticTexts["tool.position"].label, position)
            XCTAssertTrue(app.buttons["tool.look.mono"].isSelected)
            let monochrome = try pixels()
            func chroma(_ bytes: [UInt8]) -> Double {
                var sum = 0.0
                for i in stride(from: 0, to: bytes.count, by: 4) {
                    let high = max(bytes[i], max(bytes[i+1], bytes[i+2]))
                    let low = min(bytes[i], min(bytes[i+1], bytes[i+2]))
                    sum += Double(high) - Double(low)
                }
                return sum / Double(bytes.count / 4)
            }
            XCTAssertGreaterThan(chroma(reference), chroma(monochrome) + 5, "The rendered image must use the selected LUT")
            choose("natural"); waitForTool(app)
            XCTAssertEqual(app.staticTexts["tool.position"].label, position)
            Thread.sleep(forTimeInterval: 0.2)
            let current = try pixels()
            XCTAssertLessThan(frameDifference(reference, current), 0.15, "Returning to Natural must render the same actual frame, not just retain the seek label")
            let shot = XCTAttachment(screenshot: preview.screenshot()); shot.name = "LUT frame at " + position; shot.lifetime = .keepAlways; add(shot)
        }
        app.buttons["tool.cancel"].tap()
    }

    func testSubtitleNavigationAndTranscriptTwoTaps() throws {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--subtitles-ui-fixture", "--navigation-fixture"]; app.launch()
        let next = app.buttons["Next change"], position = app.staticTexts["editor.playhead"]
        XCTAssertTrue(next.waitForExistence(timeout: 30))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: next); waitForExpectations(timeout: 30)
        func at(_ value: String) { expectation(for: NSPredicate(format: "label == %@", value), evaluatedWith: position); waitForExpectations(timeout: 5) }
        next.tap(); at("0:00.40")
        next.tap(); at("0:06.00")
        next.press(forDuration: 0.65); at("0:08.00")
        openTool("subtitles", in: app)
        let seek = app.sliders["subtitles.seek"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: seek); waitForExpectations(timeout: 30)
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'subtitles.transcript.'"))
        let controls = app.scrollViews["subtitles.controls"]
        revealInViewport(rows.firstMatch, scroll: controls)
        let row = app.buttons[rows.firstMatch.identifier]
        row.tap()
        XCTAssertTrue(row.isSelected); XCTAssertFalse(app.buttons["subtitles.saveText"].exists, "First tap only seeks and selects")
        let other = app.buttons[rows.element(boundBy: 1).identifier]
        revealInViewport(other, scroll: controls)
        other.tap()
        XCTAssertTrue(other.isSelected); XCTAssertFalse(app.buttons["subtitles.saveText"].exists)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Transcript row selected without keyboard"; shot.lifetime = .keepAlways; add(shot)
        other.tap()
        XCTAssertTrue(app.buttons["subtitles.saveText"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["subtitles.text"].exists || app.textViews["subtitles.text"].exists)
        app.buttons["Cancel edit"].tap(); app.buttons["Cancel"].firstMatch.tap()
    }

    private func expandSheet(in app: XCUIApplication, title: String) {
        let bar = app.navigationBars[title]
        XCTAssertTrue(bar.waitForExistence(timeout: 8))
        let before = bar.frame.minY
        guard before > app.frame.height * 0.2 else { return }
        let grabber = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: -10))
        grabber.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)))
        expectation(for: NSPredicate { _, _ in bar.frame.minY < before - 80 }, evaluatedWith: bar)
        waitForExpectations(timeout: 8)
    }

    private func expandCameraSheet(in app: XCUIApplication) { expandSheet(in: app, title: "Camera settings") }
    private func expandLiveEffects(in app: XCUIApplication) {
        let bar = app.navigationBars.firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 8))
        expandSheet(in: app, title: bar.identifier)
    }
    private func backFromLiveEffects(in app: XCUIApplication) {
        let back = app.navigationBars.buttons.matching(identifier: "BackButton").firstMatch
        (back.exists ? back : app.navigationBars.firstMatch.buttons.element(boundBy: 0)).tap()
    }
    private func dismissLiveEffects(in app: XCUIApplication) {
        let close = app.buttons["liveEffects.done"]
        if close.exists { close.tap(); return }
        let bar = app.navigationBars.firstMatch
        for _ in 0..<2 {
            guard bar.exists else { return }
            let grabber = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: -10))
            grabber.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)), withVelocity: .fast, thenHoldForDuration: 0)
            if bar.waitForNonExistence(timeout: 2) { return }
        }
        XCTFail("The effects sheet must dismiss through its public downward gesture")
    }
    private func clearLiveEffects(in app: XCUIApplication) {
        let actions = app.buttons["liveEffects.actions"]
        if !actions.exists, app.navigationBars.buttons.matching(identifier: "BackButton").firstMatch.exists {
            backFromLiveEffects(in: app)
        }
        guard actions.exists else { return }
        actions.tap()
        let clear = app.buttons["liveEffects.clear"]
        XCTAssertTrue(clear.waitForExistence(timeout: 3)); clear.tap()
    }
    private func openMoreCameraSettings(in app: XCUIApplication) {
        let settings = app.buttons["recorder.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 20)); settings.tap()
        expandCameraSheet(in: app)
    }

    func testCameraToolbarClearsPictureEdge() {
        continueAfterFailure = false
        let device = XCUIDevice.shared
        device.orientation = .portrait
        defer { device.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--recorder-controls-test", "-fitRecordedFrame", "YES"]
        app.launch()
        let record = app.buttons["recorder.record"], preview = app.otherElements["recorder.preview"]
        let controls = [app.buttons["recorder.microphone"], app.descendants(matching: .any)["recorder.projectDuration"].firstMatch,
                        app.buttons["recorder.videoEffects"], app.buttons["recorder.settings"]]
        XCTAssertTrue(record.waitForExistence(timeout: 20))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: record)
        waitForExpectations(timeout: 25)
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft, .landscapeRight] {
            device.orientation = orientation
            expectation(for: NSPredicate { _, _ in
                let frame = preview.frame
                return !frame.isEmpty && (frame.width > frame.height) == orientation.isLandscape
            }, evaluatedWith: app)
            waitForExpectations(timeout: 8)
            let picture = preview.frame
            let row = controls.map(\.frame).reduce(CGRect.null) { $0.union($1) }
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "Viewfinder toolbar \(orientation.rawValue)"; shot.lifetime = .keepAlways; add(shot)
            print("Viewfinder \(orientation.rawValue): picture \(picture), toolbar \(row)")
            XCTAssertGreaterThanOrEqual(row.minY - picture.minY, 11)
            XCTAssertGreaterThanOrEqual(row.minX - picture.minX, 11)
            XCTAssertGreaterThanOrEqual(picture.maxX - row.maxX, 11)
            XCTAssertTrue(app.buttons["recorder.settings"].isHittable)
            let library = app.buttons["Projects"], scissors = app.buttons["Edit this project"]
            XCTAssertEqual(library.frame.width, scissors.frame.width, accuracy: 1)
            XCTAssertEqual(library.frame.height, scissors.frame.height, accuracy: 1)
            let capture = record.frame.union(library.frame).union(scissors.frame)
            XCTAssertGreaterThanOrEqual(picture.maxY - capture.maxY, 11)
            XCTAssertGreaterThanOrEqual(capture.minX - picture.minX, 11)
            XCTAssertGreaterThanOrEqual(picture.maxX - capture.maxX, 11)
            let axis: KeyPath<CGRect, CGFloat> = orientation.isLandscape ? \.midX : \.midY
            XCTAssertEqual(library.frame[keyPath: axis], record.frame[keyPath: axis], accuracy: 1)
            XCTAssertEqual(scissors.frame[keyPath: axis], record.frame[keyPath: axis], accuracy: 1)
        }
        // The layout chooser opens below the same row after returning to portrait.
        device.orientation = .portrait
        expectation(for: NSPredicate { _, _ in
            let window = app.windows.firstMatch.frame
            return window.height > window.width && preview.frame.height > preview.frame.width
        }, evaluatedWith: app)
        waitForExpectations(timeout: 8)
        setDualMode(true, in: app)
        app.buttons["recorder.dualLayout"].tap()
        let firstLayout = app.buttons["recorder.layout.floating"]
        XCTAssertTrue(firstLayout.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(firstLayout.frame.minY - controls.map(\.frame.maxY).max()!, 7)
        app.buttons["Done"].tap()
        let top = app.buttons["recorder.settings"].frame.minY
        useEmptyRecordingProject(in: app)
        record.tap()
        XCTAssertTrue(app.buttons["Stop recording"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.buttons["recorder.settings"].frame.minY, top, accuracy: 1)
        let take = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        take.name = "Toolbar during dual recording"; take.lifetime = .keepAlways; add(take)
        record.tap()
        expectation(for: NSPredicate(format: "enabled == true AND label == 'Record into this project'"), evaluatedWith: record)
        waitForExpectations(timeout: 20)
        setDualMode(false, in: app)
        #if !targetEnvironment(simulator)
        app.buttons["Projects"].tap()
        let resume = app.buttons["Continue recording"].firstMatch
        XCTAssertTrue(resume.waitForExistence(timeout: 10)); resume.tap()
        let edit = app.buttons["Edit this project"]
        expectation(for: NSPredicate(format: "enabled == true AND hittable == true"), evaluatedWith: edit)
        waitForExpectations(timeout: 15)
        edit.tap()
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 20))
        #endif
    }

    func testCameraSettingsHierarchy() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication(); app.launchArguments = ["--recorder-controls-test"]; app.launch()
        let settings = app.buttons["recorder.settings"], done = app.buttons["recorder.settingsDone"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15)); settings.tap()
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertEqual(done.label.lowercased(), "close")
        let light = app.descendants(matching: .any)["recorder.frontLight"]
        XCTAssertTrue(light.isHittable)
        XCTAssertEqual(light.value as? String, "Off")
        light.tap(); XCTAssertEqual(light.value as? String, "On")
        light.press(forDuration: 0.7)
        XCTAssertTrue(app.alerts["Camera assist"].waitForExistence(timeout: 3))
        app.alerts["Camera assist"].buttons["OK"].tap()
        XCTAssertEqual(light.value as? String, "On", "Asking for help must not toggle the setting")
        light.tap(); XCTAssertEqual(light.value as? String, "Off")
        XCTAssertFalse(app.staticTexts["This project"].exists)
        XCTAssertFalse(app.buttons["recorder.moreSettings"].exists)
        let bar = app.navigationBars["Camera settings"], collapsedTop = bar.frame.minY
        let collapsed = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        collapsed.name = "Camera settings collapsed"; collapsed.lifetime = .keepAlways; add(collapsed)
        expandCameraSheet(in: app)
        XCTAssertLessThan(bar.frame.minY, collapsedTop - 80)
        let list = app.descendants(matching: .any)["recorder.settingsControls"].firstMatch
        revealInViewport(app.staticTexts["recorder.colorNotice"], scroll: list)
        XCTAssertTrue(app.staticTexts["recorder.colorNotice"].isHittable)
        let color = XCTAttachment(screenshot: app.screenshot())
        color.name = "Camera settings typography and segmented recording color"; color.lifetime = .keepAlways; add(color)
        let mirror = app.switches["recorder.mirrorPreview"]
        for _ in 0..<8 { if mirror.exists && mirror.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(mirror.isHittable, "Detailed settings live in the expanded sheet")
        XCTAssertEqual(app.buttons.matching(identifier: "recorder.settingsDone").count, 1)
        let expanded = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        expanded.name = "Camera settings expanded"; expanded.lifetime = .keepAlways; add(expanded)
        XCUIDevice.shared.orientation = .landscapeRight
        expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: app); waitForExpectations(timeout: 10)
        XCTAssertTrue(done.isHittable)
        done.tap(); XCTAssertTrue(settings.waitForExistence(timeout: 5)); settings.tap()
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["recorder.moreSettings"].exists)
        done.tap()
    }

    func testCameraSettingsAtAccessibilityTextSize() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--recorder-controls-test", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch(); openMoreCameraSettings(in: app)
        let notice = app.staticTexts["recorder.colorNotice"]
        revealInViewport(notice, scroll: app.descendants(matching: .any)["recorder.settingsControls"].firstMatch)
        XCTAssertTrue(notice.isHittable)
        let colorNotice = XCTAttachment(screenshot: app.screenshot())
        colorNotice.name = "Color notice wraps at accessibility text size"; colorNotice.lifetime = .keepAlways; add(colorNotice)
        let mirror = app.switches["recorder.mirrorPreview"]
        for _ in 0..<12 { if mirror.exists && mirror.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(mirror.isHittable)
        XCTAssertFalse(app.buttons["recorder.moreSettings"].exists)
        app.buttons["recorder.settingsDone"].tap()
        XCTAssertTrue(app.buttons["recorder.settings"].isHittable)
    }

    func testCameraStartupPhysical() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--dual-capture-ui-test"]
        func checkPreview(_ name: String) {
            let record = app.buttons["recorder.record"]
            XCTAssertTrue(record.waitForExistence(timeout: 20))
            expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: record); waitForExpectations(timeout: 20)
            Thread.sleep(forTimeInterval: 1)
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
            XCTAssertFalse(app.buttons["Dismiss warning"].exists, app.debugDescription)
            XCTAssertFalse(app.alerts.firstMatch.exists, app.debugDescription)
        }
        app.launch(); checkPreview("Initial camera")
        let settings = app.buttons["recorder.settings"]
        settings.tap()
        let logSupported = app.buttons["recorder.color.log"].isEnabled
        app.buttons[logSupported ? "recorder.color.log" : "recorder.color.hdr"].tap()
        let expectedMode = logSupported ? "Log" : "HDR"
        expectation(for: NSPredicate(format: "selected == true"), evaluatedWith: app.buttons["recorder.color." + expectedMode.lowercased()]); waitForExpectations(timeout: 20)
        app.buttons["recorder.settingsDone"].tap()
        for index in 0..<4 {
            app.terminate(); app.launch(); checkPreview("Cold camera \(index)")
            XCTAssertTrue((settings.value as? String)?.hasSuffix(expectedMode) == true)
            app.buttons["Projects"].tap()
            XCTAssertTrue(app.buttons["Record"].waitForExistence(timeout: 10), app.debugDescription); app.buttons["Record"].tap()
            checkPreview("Return to camera \(index)")
            XCUIDevice.shared.press(.home); app.activate(); checkPreview("Foreground camera \(index)")
        }
    }
    /// Physical 17 Pro matrix; run explicitly after archiving its preferences.
    func testLogCapturePhysical() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--dual-capture-ui-test"]; app.launch()
        let camera = app.buttons["recorder.camera"], record = app.buttons["recorder.record"], settings = app.buttons["recorder.settings"]
        XCTAssertTrue(camera.waitForExistence(timeout: 25))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: camera); waitForExpectations(timeout: 20)
        camera.tap(); app.buttons["Rear main"].firstMatch.tap()
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: settings); waitForExpectations(timeout: 20)
        settings.tap()
        let log = app.buttons["recorder.color.log"]
        XCTAssertTrue(log.waitForExistence(timeout: 5)); XCTAssertTrue(log.isEnabled)
        log.tap()
        expectation(for: NSPredicate(format: "selected == true"), evaluatedWith: log); waitForExpectations(timeout: 20)
        app.buttons["recorder.settingsDone"].tap()
        func screenshot(_ name: String) {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
        }
        screenshot("Physical Log idle preview")
        for index in 0..<2 {
            expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: record); waitForExpectations(timeout: 20)
            record.tap()
            expectation(for: NSPredicate(format: "label == 'Stop recording'"), evaluatedWith: record); waitForExpectations(timeout: 20)
            Thread.sleep(forTimeInterval: 1.5); screenshot("Physical Log recording \(index)")
            settings.tap()
            XCTAssertFalse(app.buttons["recorder.color.sdr"].isEnabled, "Format cannot change halfway through a take")
            app.buttons["recorder.settingsDone"].tap()
            if index == 0 {
                for name in ["Rear ultrawide", "Rear tele"] {
                    camera.tap(); app.buttons[name].firstMatch.tap()
                    expectation(for: NSPredicate(format: "value == %@ AND enabled == true", name), evaluatedWith: camera); waitForExpectations(timeout: 20)
                    XCTAssertTrue((settings.value as? String)?.hasSuffix("Log") == true)
                    Thread.sleep(forTimeInterval: 0.7); screenshot("Physical Log switch to " + name)
                }
                record.tap()
            } else {
                camera.tap(); app.buttons["Front main"].firstMatch.tap()
                // The physical 17 Pro advertises native Log on its front camera
                // too; verify the negotiated mode rather than assuming rear-only.
                expectation(for: NSPredicate(format: "value == 'Front main' AND enabled == true"), evaluatedWith: camera); waitForExpectations(timeout: 20)
                XCTAssertTrue((settings.value as? String)?.hasSuffix("Log") == true)
                Thread.sleep(forTimeInterval: 1); screenshot("Physical Log switch to front")
                for name in ["Front ultrawide (portrait)", "Front ultrawide (landscape)"] {
                    camera.tap(); app.buttons[name].firstMatch.tap()
                    expectation(for: NSPredicate(format: "value == %@ AND enabled == true", name), evaluatedWith: camera); waitForExpectations(timeout: 20)
                    XCTAssertTrue((settings.value as? String)?.hasSuffix("Log") == true, "Framing changes must not silently downgrade an active Log take")
                    Thread.sleep(forTimeInterval: 0.7); screenshot("Physical Log request " + name)
                    if app.buttons["Dismiss warning"].exists { app.buttons["Dismiss warning"].tap() }
                }
                app.buttons["Pause recording"].tap()
                expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: settings); waitForExpectations(timeout: 20)
                settings.tap(); app.buttons["recorder.color.sdr"].tap()
                expectation(for: NSPredicate(format: "selected == true"), evaluatedWith: app.buttons["recorder.color.sdr"]); waitForExpectations(timeout: 20)
                app.buttons["recorder.settingsDone"].tap()
                app.buttons["Finish paused recording"].tap()
            }
            expectation(for: NSPredicate(format: "label == 'Record into this project' AND enabled == true"), evaluatedWith: record); waitForExpectations(timeout: 25)
        }
        settings.tap(); app.buttons["recorder.color.sdr"].tap()
        expectation(for: NSPredicate(format: "selected == true"), evaluatedWith: app.buttons["recorder.color.sdr"]); waitForExpectations(timeout: 20)
        app.buttons["recorder.settingsDone"].tap()
        screenshot("Physical return from Log to SDR")
    }
    func testRecordingColorMenu() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--recorder-controls-test"]; app.launch()
        let settings = app.buttons["recorder.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10)); settings.tap()
        let log = app.buttons["recorder.color.log"]
        XCTAssertTrue(log.waitForExistence(timeout: 5)); XCTAssertFalse(log.isEnabled)
        for mode in ["sdr", "hdr"] {
            let button = app.buttons["recorder.color." + mode]
            button.tap(); XCTAssertTrue(button.isSelected)
        }
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Recording color menu"; shot.lifetime = .keepAlways; add(shot)
    }
    func testLogLocalRecoveryWorkflow() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--log-recovery-ui-fixture", "--reset-ui-fixture"]
        app.launch(); openTool("color", in: app); waitForTool(app)
        let slider=app.sliders["color.recovery"],reset=app.buttons["color.recovery.reset"],natural=app.buttons["color.recovery.natural"]
        XCTAssertTrue(slider.waitForExistence(timeout:10));XCTAssertTrue(slider.isHittable)
        XCTAssertEqual(reset.value as? String,"0%")
        natural.tap();waitForTool(app);XCTAssertEqual(reset.value as? String,"100%")
        expectation(for:NSPredicate(format:"value BEGINSWITH 'Frame visible'"),evaluatedWith:app.otherElements["tool.preview"]);waitForExpectations(timeout:20)
        func shot(_ name:String) {let attachment=XCTAttachment(screenshot:XCUIScreen.main.screenshot());attachment.name=name;attachment.lifetime = .keepAlways;add(attachment)}
        shot("Local recovery Natural portrait")
        app.buttons["Play tool preview"].tap()
        expectation(for:NSPredicate {_,_ in app.staticTexts["tool.position"].label != "0:00.00"},evaluatedWith:app);waitForExpectations(timeout:10)
        XCTAssertTrue(app.buttons["Pause tool preview"].waitForExistence(timeout:5));app.buttons["Pause tool preview"].tap()
        shot("Local recovery during playback")
        slider.adjust(toNormalizedSliderPosition:0.45);waitForTool(app)
        let saved=reset.value as? String
        XCTAssertNotEqual(saved,"0%");XCTAssertNotEqual(saved,"100%")
        app.buttons["tool.apply"].tap()
        XCTAssertTrue(app.buttons["effect.color"].firstMatch.waitForExistence(timeout:15))
        app.buttons["Undo"].tap();XCTAssertFalse(app.buttons["effect.color"].firstMatch.exists)
        app.buttons["Redo"].tap();XCTAssertTrue(app.buttons["effect.color"].firstMatch.waitForExistence(timeout:15))
        app.buttons["effect.color"].firstMatch.tap();waitForTool(app)
        XCTAssertEqual(reset.value as? String,saved,"Recovery-only grade survives Apply and Undo/Redo")
        XCUIDevice.shared.orientation = .landscapeLeft
        expectation(for:NSPredicate {_,_ in app.frame.width > app.frame.height},evaluatedWith:app);waitForExpectations(timeout:10)
        XCTAssertTrue(slider.isHittable);reset.tap();waitForTool(app);XCTAssertEqual(reset.value as? String,"0%")
        natural.tap();waitForTool(app)
        app.buttons["tool.before"].tap();waitForTool(app);shot("Local recovery bypass landscape")
        app.buttons["tool.after"].tap();waitForTool(app);shot("Local recovery Natural landscape")
        app.buttons["tool.apply"].tap()
        XCUIDevice.shared.orientation = .portrait
        app.terminate();app.launchArguments=["--editor-preview","--log-recovery-ui-fixture"];app.launch()
        XCTAssertTrue(app.buttons["effect.color"].firstMatch.waitForExistence(timeout:25))
        app.buttons["effect.color"].firstMatch.tap();waitForTool(app);XCTAssertEqual(reset.value as? String,"100%")
        app.buttons["tool.cancel"].tap()
        app.buttons["Export"].tap()
        if app.buttons["Export video"].waitForExistence(timeout:3) {app.buttons["Export video"].tap()}
        XCTAssertTrue(app.buttons["Share latest export"].waitForExistence(timeout:90));shot("Local recovery finished export")
        app.buttons["Done"].tap()
    }
    func testColorHighlightsWorkflow() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]; app.launch()
        openTool("color", in: app); waitForTool(app)
        let slider = app.sliders["color.highlights"], reset = app.buttons["color.highlights.reset"]
        XCTAssertTrue(slider.isHittable, "Highlight recovery is visible without expanding another section")
        slider.adjust(toNormalizedSliderPosition: 0.25); waitForTool(app)
        let saved = reset.value as? String
        XCTAssertLessThan(Double(saved ?? "") ?? 0, -20)
        let portrait = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); portrait.name = "Highlight recovery portrait"; portrait.lifetime = .keepAlways; add(portrait)
        app.buttons["tool.apply"].tap()
        XCTAssertTrue(app.buttons["effect.color"].firstMatch.waitForExistence(timeout: 15))
        app.buttons["effect.color"].firstMatch.tap(); waitForTool(app)
        XCTAssertEqual(reset.value as? String, saved, "A highlights-only grade survives Apply and reopen")
        XCUIDevice.shared.orientation = .landscapeLeft
        expectation(for: NSPredicate { _, _ in app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height }, evaluatedWith: app); waitForExpectations(timeout: 10)
        XCTAssertTrue(slider.isHittable); reset.tap(); waitForTool(app)
        XCTAssertEqual(reset.value as? String, "+0")
        slider.adjust(toNormalizedSliderPosition: 0.15); waitForTool(app)
        app.buttons["tool.before"].tap(); waitForTool(app)
        app.buttons["tool.after"].tap(); waitForTool(app)
        let landscape = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); landscape.name = "Highlight recovery landscape"; landscape.lifetime = .keepAlways; add(landscape)
        app.buttons["tool.cancel"].tap()
        XCUIDevice.shared.orientation = .portrait
    }
    func testColorImportAndSavedGrade() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]; app.launch()
        openTool("color", in: app); waitForTool(app)
        app.buttons["color.import"].tap()
        let browse = app.tabBars["DOC.browsingModeTabBar"].buttons["Browse"]
        if browse.waitForExistence(timeout: 5) { browse.tap() }
        let local = app.cells["DOC.sidebar.item.On My iPhone"]
        if local.waitForExistence(timeout: 3) { local.tap() }
        let file = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "QA-Identity")).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 10)); file.tap()
        waitForTool(app)
        XCTAssertTrue(app.staticTexts["QA Identity"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.segmentedControls["color.library"].buttons["Imported"].isSelected)
        let settings = app.scrollViews["tool.settings"]
        let save = app.buttons["color.saveGrade"]
        for _ in 0..<4 { if save.isHittable { break }; settings.swipeUp() }
        XCTAssertTrue(save.isHittable); save.tap()
        let alert = app.alerts["Save grade"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5)); alert.textFields.firstMatch.tap()
        let field = alert.textFields.firstMatch
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (field.value as? String ?? "").count) + "QA Identity UI test")
        alert.buttons["Save"].tap()
        for _ in 0..<4 { if app.segmentedControls["color.library"].isHittable { break }; settings.swipeDown() }
        app.segmentedControls["color.library"].buttons["Grades"].tap()
        XCTAssertTrue(app.buttons["QA Identity UI test"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["QA Identity UI test"].firstMatch.tap(); waitForTool(app)
        app.buttons["tool.apply"].tap()
        XCTAssertTrue(app.buttons["effect.color"].firstMatch.waitForExistence(timeout: 15))
        app.buttons["effect.color"].firstMatch.tap(); waitForTool(app)
        XCTAssertTrue(app.staticTexts["QA Identity"].firstMatch.exists)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Imported LUT and saved grade"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["tool.cancel"].tap()

    }
    func testColorLibraryWorkflow() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]; app.launch()
        openTool("color", in: app); waitForTool(app)
        let warm = app.buttons["tool.look.warm"]
        XCTAssertTrue(warm.waitForExistence(timeout: 15)); warm.tap(); waitForTool(app)
        XCTAssertTrue(warm.isSelected, "A thumbnail must not intercept taps on adjacent cards")
        if app.buttons["Favorite look"].value as? String != "On" { app.buttons["Favorite look"].tap() }
        app.segmentedControls["color.library"].buttons["Favorites"].tap()
        XCTAssertTrue(app.segmentedControls["color.library"].buttons["Favorites"].isSelected, "Thumbnail hit areas must not cover the library selector")
        XCTAssertTrue(warm.waitForExistence(timeout: 5))
        app.buttons["tool.before"].tap(); waitForTool(app)
        app.buttons["tool.after"].tap(); waitForTool(app)
        let portrait = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); portrait.name = "LUT library portrait"; portrait.lifetime = .keepAlways; add(portrait)
        XCUIDevice.shared.orientation = .landscapeLeft
        expectation(for: NSPredicate { _, _ in app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height }, evaluatedWith: app)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(app.buttons["tool.apply"].waitForExistence(timeout: 10))
        app.segmentedControls["color.library"].buttons["Built-in"].tap()
        waitForTool(app)
        let landscape = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); landscape.name = "LUT library landscape"; landscape.lifetime = .keepAlways; add(landscape)
        // Library lives in the scrolling pane; preview controls remain reachable.
        XCTAssertTrue(app.buttons["tool.before"].isHittable)
        app.buttons["tool.apply"].tap()
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 20))
        app.buttons["effect.color"].firstMatch.tap(); waitForTool(app)
        XCTAssertTrue(app.buttons["tool.look.warm"].isSelected)
        app.buttons["tool.cancel"].tap()
        XCUIDevice.shared.orientation = .portrait
    }
    func testAudioCensorPublicWorkflow() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]; app.launch()
        openTool("censorAudio", in: app)
        XCTAssertTrue(app.alerts["Mark the sound to censor"].waitForExistence(timeout: 5))
        app.buttons["Got it"].tap(); app.buttons["Done"].tap()
        app.buttons["Mark start"].tap(); seekTimeline(fraction: 0.15, in: app); app.buttons["Mark end"].tap()
        openTool("censorAudio", in: app)
        XCTAssertTrue(app.buttons["censor.apply"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.otherElements["censor.preparing"].exists)
        let controls = app.scrollViews["censor.controls"]
        let endBefore = app.staticTexts["censor.end"].label
        app.buttons["censor.end.later"].tap()
        XCTAssertNotEqual(app.staticTexts["censor.end"].label, endBefore)
        app.buttons["censor.end.earlier"].tap()
        let track = app.switches.matching(NSPredicate(format: "identifier BEGINSWITH 'censor.track.'")).firstMatch
        XCTAssertTrue(track.waitForExistence(timeout: 5)); track.tap()
        XCTAssertFalse(app.buttons["censor.apply"].isEnabled); track.tap()
        XCTAssertTrue(app.buttons["censor.apply"].isEnabled)
        for _ in 0..<8 { if app.sliders["censor.frequency"].isHittable { break }; controls.swipeUp() }
        app.segmentedControls["censor.waveform"].buttons["Triangle"].tap()
        app.sliders["censor.frequency"].adjust(toNormalizedSliderPosition: 0.35)
        for _ in 0..<6 { if app.segmentedControls["censor.envelope"].isHittable { break }; controls.swipeUp() }
        app.segmentedControls["censor.envelope"].buttons["Pulsed"].tap()
        let portrait = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); portrait.name = "Censor portrait"; portrait.lifetime = .keepAlways; add(portrait)
        app.buttons["censor.play"].tap()
        expectation(for: NSPredicate(format: "label == 'Pause'"), evaluatedWith: app.buttons["censor.play"]); waitForExpectations(timeout: 45)
        app.buttons["censor.play"].tap()
        XCUIDevice.shared.orientation = .landscapeRight
        expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: app); waitForExpectations(timeout: 10)
        let landscape = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); landscape.name = "Censor landscape"; landscape.lifetime = .keepAlways; add(landscape)
        app.buttons["censor.apply"].tap()
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 25))
        XCUIDevice.shared.orientation = .portrait
        app.buttons["editor.clearSelection"].tap()
        let badge = app.buttons.matching(NSPredicate(format: "identifier == 'effect.censorAudio'")).firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 10), app.debugDescription); badge.tap()
        XCTAssertTrue(app.buttons["censor.remove"].waitForExistence(timeout: 10))
        for _ in 0..<8 { if app.buttons["censor.remove"].isHittable { break }; controls.swipeUp() }
        app.buttons["censor.remove"].tap()
        XCTAssertTrue(app.buttons["Undo"].waitForExistence(timeout: 20)); app.buttons["Undo"].tap()
        XCTAssertTrue(badge.waitForExistence(timeout: 20))
    }

    func testExportActionsAndProjectZip() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let title = "Project ZIP and export · UI test"
        app.launchEnvironment["YOUREC_EDITOR_FIXTURE_TITLE"] = title
        app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["Export"].waitForExistence(timeout: 30))
        app.buttons["Export"].tap()
        let export = app.buttons["Export video"]
        if export.waitForExistence(timeout: 4) { export.tap() }
        let share = app.buttons["Share latest export"]
        XCTAssertTrue(share.waitForExistence(timeout: 90))
        XCTAssertTrue(share.isHittable)
        XCTAssertTrue(app.buttons["Save to Photos"].isHittable)
        app.navigationBars["Export"].buttons["Done"].tap()
        app.buttons["Back to projects"].tap()
        app.buttons["Actions for " + title].tap()
        app.buttons["Zip project"].tap()
        XCTAssertTrue(app.buttons["Save or share ZIP"].waitForExistence(timeout: 40))
        app.buttons["Done"].firstMatch.tap()
    }

    func testZipLongProjectFromBrowser() throws {
        guard let title = ProcessInfo.processInfo.environment["YOUREC_ZIP_FIXTURE_TITLE"] else {
            throw XCTSkip("Requires a long project staged in the isolated editor fixture library")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["YOUREC_EDITOR_FIXTURE_TITLE"] = title
        app.launchArguments = ["--editor-preview"]
        app.launch()
        let duration = app.staticTexts["editor.duration"]
        expectation(for: NSPredicate(format: "label MATCHES %@", "[1-9][0-9]*:[0-9]{2}[.][0-9]{2}"), evaluatedWith: duration)
        waitForExpectations(timeout: 80)
        app.buttons["Back to projects"].tap()
        app.buttons["Actions for " + title].tap()
        app.buttons["Zip project"].tap()
        XCTAssertTrue(app.buttons["Save or share ZIP"].waitForExistence(timeout: 120))
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Actions for " + title].isHittable)
    }

    func testVoiceRecordingAppendAndInsert() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]
        app.launchEnvironment["YOUREC_EDITOR_FIXTURE_TITLE"] = "Voice recording · UI test"
        app.launch()
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 25))
        seekTimeline(fraction: 0.25, in: app)
        let insertion = app.staticTexts["editor.playhead"].label
        let originalLength = app.staticTexts["editor.duration"].label
        openTool("addAudio", in: app)
        XCTAssertTrue(app.buttons["audioImport.record"].waitForExistence(timeout: 8))
        app.buttons["audioImport.record"].tap()
        let record = app.buttons["voice.record"], play = app.buttons["voice.play"]
        let done = app.buttons["voice.done"], mic = app.buttons["voice.mic"]
        let clock = app.staticTexts["voice.time"]
        XCTAssertTrue(record.waitForExistence(timeout: 8))
        XCTAssertFalse(done.isEnabled); XCTAssertFalse(play.isEnabled)
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: mic); waitForExpectations(timeout: 10)
        let currentMic = mic.label
        mic.tap()
        let option = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != 'voice.mic'", currentMic)).firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5), app.debugDescription)
        option.tap()
        record.tap()
        XCTAssertEqual(record.label, "Stop")
        Thread.sleep(forTimeInterval: 1.4)
        record.tap()
        XCTAssertEqual(record.label, "Record more")
        let first = try XCTUnwrap(clock.value as? String)
        XCTAssertNotEqual(first, "0:00.00")
        let take = XCTAttachment(screenshot: app.screenshot()); take.name = "Voice recording after first pass"; take.lifetime = .keepAlways; add(take)
        play.tap()
        XCTAssertEqual(play.label, "Stop")
        expectation(for: NSPredicate(format: "label == 'Play'"), evaluatedWith: play); waitForExpectations(timeout: 12)
        XCTAssertEqual(clock.value as? String, first)
        record.tap()
        Thread.sleep(forTimeInterval: 1.1)
        record.tap()
        let both = try XCTUnwrap(clock.value as? String)
        XCTAssertNotEqual(both, first)
        play.tap()
        expectation(for: NSPredicate(format: "label == 'Stop'"), evaluatedWith: play); waitForExpectations(timeout: 8)
        // A new take during playback must append to the end, even when the
        // audition is still playing the first pass.
        record.tap()
        XCTAssertEqual(record.label, "Stop")
        Thread.sleep(forTimeInterval: 0.6)
        done.tap()
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 25), app.debugDescription)
        let inserted = app.buttons["timeline.audio.2"]
        XCTAssertTrue(inserted.waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["editor.playhead"].label, insertion)
        XCTAssertEqual(app.staticTexts["editor.duration"].label, originalLength)
        XCTAssertFalse(app.buttons["timeline.audio.3"].exists)
        app.buttons["Undo"].tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: inserted); waitForExpectations(timeout: 8)
        app.buttons["Redo"].tap()
        XCTAssertTrue(inserted.waitForExistence(timeout: 8))
        app.buttons["Export"].tap()
        let export = app.buttons["Export video"]
        XCTAssertTrue(export.waitForExistence(timeout: 6)); export.tap()
        XCTAssertTrue(app.buttons["Share latest export"].waitForExistence(timeout: 90), app.debugDescription)
        app.buttons["Done"].tap()
    }

    func testVoiceRecordingStartOverAndCancel() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]
        app.launchEnvironment["YOUREC_EDITOR_FIXTURE_TITLE"] = "Voice discard · UI test"
        app.launch()
        openTool("addAudio", in: app)
        XCTAssertTrue(app.buttons["audioImport.record"].waitForExistence(timeout: 8))
        app.buttons["audioImport.record"].tap()
        let record = app.buttons["voice.record"], play = app.buttons["voice.play"], done = app.buttons["voice.done"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: record); waitForExpectations(timeout: 10)
        record.tap(); Thread.sleep(forTimeInterval: 0.6)
        app.buttons["voice.startOver"].tap(); app.alerts.buttons["Keep take"].tap()
        XCTAssertTrue(play.isEnabled)
        app.buttons["voice.startOver"].tap(); app.alerts.buttons["Discard"].tap()
        XCTAssertFalse(done.isEnabled); XCTAssertFalse(play.isEnabled)
        XCTAssertEqual(app.staticTexts["voice.time"].value as? String, "0:00.00")
        XCTAssertEqual(record.label, "Record")
        record.tap(); Thread.sleep(forTimeInterval: 0.7)
        XCUIDevice.shared.press(.home); app.activate()
        expectation(for: NSPredicate(format: "label == 'Record more'"), evaluatedWith: record); waitForExpectations(timeout: 8)
        XCTAssertTrue(play.isEnabled)
        XCUIDevice.shared.orientation = .landscapeRight
        defer { XCUIDevice.shared.orientation = .portrait }
        expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: app); waitForExpectations(timeout: 8)
        XCTAssertTrue(done.isHittable); XCTAssertTrue(record.isHittable); XCTAssertTrue(play.isHittable)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Voice recording in landscape"; shot.lifetime = .keepAlways; add(shot)
        record.tap(); Thread.sleep(forTimeInterval: 0.5); record.tap()
        XCTAssertTrue(play.isEnabled)
        app.buttons["voice.cancel"].tap(); app.alerts.buttons["Discard"].tap()
        XCTAssertTrue(app.buttons["audioImport.files"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["timeline.audio.2"].exists)
    }

    func testAudioImportFilesEntry() throws {
        // Device fixture: generated WAV in iCloud Drive/YouRec Audio QA 154.
        // This exercises a real security-scoped Files import, not app-private storage.
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]; app.launch()
        openTool("addAudio", in: app)
        XCTAssertTrue(app.buttons["audioImport.files"].waitForExistence(timeout: 8)); app.buttons["audioImport.files"].tap()
        let browse = app.buttons.matching(NSPredicate(format: "label IN %@ AND identifier != 'BackButton'", ["Sfoglia", "Browse"])).firstMatch
        XCTAssertTrue(browse.waitForExistence(timeout: 10)); browse.tap()
        if app.buttons["BackButton"].exists { app.buttons["BackButton"].tap() }
        let cloud = app.cells.matching(NSPredicate(format: "label CONTAINS 'iCloud Drive'")).firstMatch
        XCTAssertTrue(cloud.waitForExistence(timeout: 10), app.debugDescription); cloud.tap()
        let qa = app.cells.matching(NSPredicate(format: "label BEGINSWITH 'YouRec Audio QA 154'")).firstMatch
        for _ in 0..<20 { if qa.isHittable { break }; app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(qa.waitForExistence(timeout: 10), app.debugDescription); qa.tap()
        let audio = app.cells.matching(NSPredicate(format: "label BEGINSWITH 'YouRec test tone'")).firstMatch
        XCTAssertTrue(audio.waitForExistence(timeout: 10), app.debugDescription); audio.tap()
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 30), app.debugDescription)
        let second = app.buttons["timeline.audio.2"]
        XCTAssertTrue(second.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(app.staticTexts["editor.duration"].label, "0:18.00", "Adding sound must not shift the existing picture")
        app.buttons["Undo"].tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: second); waitForExpectations(timeout: 15)
        app.buttons["Redo"].tap(); XCTAssertTrue(second.waitForExistence(timeout: 15))
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Imported independent audio layer"; shot.lifetime = .keepAlways; add(shot)
    }

    func testAudioToolsLargeText() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        openTool("addAudio", in: app)
        XCTAssertTrue(app.buttons["audioImport.files"].waitForExistence(timeout: 10))
        for _ in 0..<5 { if app.buttons["audioImport.files"].isHittable { break }; app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(app.buttons["audioImport.files"].isHittable)
        let imported = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); imported.name = "Add audio large text"; imported.lifetime = .keepAlways; add(imported)
        app.buttons["Cancel"].firstMatch.tap()
        let editorScroll = app.scrollViews["editor.controlsScroll"]
        for button in ["Mark start", "Next change", "Mark end"] {
            revealInViewport(app.buttons[button], scroll: editorScroll)
            app.buttons[button].tap()
        }
        openTool("censorAudio", in: app)
        XCTAssertTrue(app.buttons["censor.apply"].waitForExistence(timeout: 10)); XCTAssertTrue(app.buttons["censor.apply"].isHittable)
        let portrait = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); portrait.name = "Censor large text portrait"; portrait.lifetime = .keepAlways; add(portrait)
        let controls = app.scrollViews["censor.controls"]
        for _ in 0..<8 { if app.sliders["censor.level"].isHittable { break }; controls.swipeUp() }
        XCTAssertTrue(app.sliders["censor.level"].isHittable)
        XCUIDevice.shared.orientation = .landscapeRight
        expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: app); waitForExpectations(timeout: 10)
        XCTAssertTrue(app.buttons["censor.apply"].isHittable); XCTAssertTrue(app.buttons["censor.play"].isHittable)
        let landscape = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); landscape.name = "Censor large text landscape"; landscape.lifetime = .keepAlways; add(landscape)
        app.buttons["Cancel"].firstMatch.tap(); XCUIDevice.shared.orientation = .portrait
    }

    func testReachableEffectHelpAndSubtitleRemoval() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--subtitles-ui-fixture", "--long-subtitles-ui-fixture"]; app.launch()
        openTool("subtitles", in: app)
        XCTAssertTrue(app.buttons["subtitles.apply"].waitForExistence(timeout: 15))
        let remove = app.buttons["subtitles.remove"], controls = app.scrollViews["subtitles.controls"]
        for _ in 0..<6 { if remove.isHittable { break }; controls.swipeUp() }
        XCTAssertTrue(remove.isHittable, "Removal must be before the unbounded transcript")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Subtitle removal before long transcript"; shot.lifetime = .keepAlways; add(shot)
        remove.tap(); XCTAssertTrue(app.buttons["Remove all subtitles"].waitForExistence(timeout: 5)); app.buttons.matching(identifier: "Cancel").allElementsBoundByIndex.last!.tap()
        app.buttons["Cancel"].firstMatch.tap()
        openTool("videoEffects", in: app); openEffectSection("colorStyle", in: app)
        let tint = app.buttons["videoEffects.add.silentTint"]
        for _ in 0..<5 { if tint.isHittable { break }; app.scrollViews["videoEffects.controls"].swipeUp() }; tint.tap()
        let help = app.buttons["effectHelp.silentTint"]
        XCTAssertTrue(help.waitForExistence(timeout: 15)); XCTAssertTrue(help.isHittable); help.tap()
        XCTAssertTrue(app.staticTexts["Film technique"].waitForExistence(timeout: 5))
        let helpShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); helpShot.name = "Effect help sheet"; helpShot.lifetime = .keepAlways; add(helpShot)
        XCUIDevice.shared.orientation = .landscapeRight
        XCTAssertTrue(app.staticTexts["Film technique"].waitForExistence(timeout: 5))
        app.buttons["inspectorHelp.done"].tap()
        XCTAssertTrue(help.waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .portrait
    }

    func testLivePictureDuringInterfaceTurns() {
        continueAfterFailure = false
        let device = XCUIDevice.shared, app = XCUIApplication()
        device.orientation = .portrait
        defer { device.orientation = .portrait }
        app.launchArguments = ["--recorder-controls-test", "--probe-preview-rotation"]
        #if targetEnvironment(simulator)
        app.launchArguments.append("--interface-turn-fixture")
        #endif
        // A prelaunched camera keeps the instrumented screen recording short enough
        // to retain every frame of the turn on a wirelessly connected phone.
        if ProcessInfo.processInfo.environment["YOUREC_TURN_PRELAUNCHED"] == "1", app.state == .runningForeground {
            app.activate()
        } else { app.launch() }
        XCTAssertTrue(app.buttons["recorder.camera"].waitForExistence(timeout: 20))
        let turns: [UIDeviceOrientation] = [.landscapeLeft, .landscapeRight, .landscapeLeft, .portrait, .landscapeRight, .portrait]
        for (index, orientation) in turns.enumerated() {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "Camera before turn \(index) to \(orientation.rawValue)"; shot.lifetime = .keepAlways; add(shot)
            device.orientation = orientation
            // End-point screenshots miss a preview that spins and then snaps back.
            for step in 0..<3 {
                let image = XCUIScreen.main.screenshot().image
                let scale = 800 / max(image.size.width, image.size.height)
                let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                let format = UIGraphicsImageRendererFormat(); format.scale = 1
                let jpeg = UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.8) { _ in
                    image.draw(in: CGRect(origin: .zero, size: size))
                }
                let sample = XCTAttachment(data: jpeg, uniformTypeIdentifier: "public.jpeg")
                sample.name = "Turning \(index) to \(orientation.rawValue) sample \(step)"
                sample.lifetime = .keepAlways; add(sample)
            }
            expectation(for: NSPredicate { _, _ in
                let size = app.windows.firstMatch.frame.size
                return (size.width > size.height) == orientation.isLandscape
            }, evaluatedWith: app)
            waitForExpectations(timeout: 5)
            let preview = app.descendants(matching: .any)["recorder.preview"].firstMatch
            let interface: UIInterfaceOrientation = orientation == .portrait ? .portrait :
                orientation == .landscapeLeft ? .landscapeRight : .landscapeLeft
            XCTAssertTrue((preview.value as? String)?.contains("System turn \(interface.rawValue): 0 ms") == true,
                          "The actual window should accept the turn without animating the camera picture")
        }
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "Camera after turns"; shot.lifetime = .keepAlways; add(shot)
    }

    func testRecorderRotationResponsiveness() { checkRecorderRotation(stabilized: false) }
    func testStabilizedRecorderRotation() { checkRecorderRotation(stabilized: true) }

    func testDualRecorderRotation() { checkRecorderRotation(stabilized: false, dual: true) }
    func testSplitRecorderRotation() { checkRecorderRotation(stabilized: true, dual: true, split: true) }

    func testSwitchingToTwoCamerasClosesZoomPresets() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--recorder-controls-test"]
        app.launch()
        let zoom = app.buttons["recorder.zoom"]
        let duration = app.descendants(matching: .any)["recorder.zoom.duration"].firstMatch
        XCTAssertTrue(zoom.waitForExistence(timeout: 15))
        zoom.tap()
        XCTAssertTrue(duration.waitForExistence(timeout: 3))
        setDualMode(true, in: app)
        XCTAssertTrue(app.buttons["recorder.dualLayout"].exists)
        XCTAssertFalse(duration.exists)
        setDualMode(false, in: app)
        XCTAssertTrue(zoom.exists)
        XCTAssertFalse(duration.exists)
        zoom.tap()
        XCTAssertTrue(duration.waitForExistence(timeout: 3))
    }

    private func checkRecorderRotation(stabilized: Bool, dual: Bool = false, split: Bool = false) {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--recorder-controls-test", "--probe-preview-rotation",
                               "-dualStabilization", stabilized ? "YES" : "NO", "-dualFaceFollow", "NO"]
        if ProcessInfo.processInfo.environment["YOUREC_TURN_PRELAUNCHED"] == "1", app.state == .runningForeground {
            app.activate()
        } else { app.launch() }
        if dual {
            setDualMode(true, in: app)
            app.buttons["recorder.dualLayout"].tap()
            app.buttons[split ? "recorder.layout.sideBySide" : "recorder.layout.floating"].tap()
            app.buttons["Done"].tap()
            if split { app.buttons["recorder.dualSwap"].tap() }
        }
        let record = app.buttons["recorder.record"], preview = app.descendants(matching: .any)["recorder.preview"].firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 40))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: record); waitForExpectations(timeout: 45)
        func turn(_ orientation: UIDeviceOrientation) {
            XCUIDevice.shared.orientation = orientation
            expectation(for: NSPredicate { _, _ in
                let size = app.windows.firstMatch.frame.size
                return (size.width > size.height) == orientation.isLandscape
            }, evaluatedWith: app)
            waitForExpectations(timeout: 8)
            Thread.sleep(forTimeInterval: 0.45)
        }
        func capture(_ name: String) {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = name; shot.lifetime = .keepAlways; add(shot)
        }
        func captureTiming(_ name: String) {
            if let text = preview.value as? String {
                print("\(name): \(text)")
                let info = XCTAttachment(string: text); info.name = name; info.lifetime = .keepAlways; add(info)
            }
        }
        capture("Rotation · portrait camera preview")
        for _ in 0..<2 { turn(.landscapeLeft); turn(.portrait); turn(.landscapeRight); turn(.portrait) }
        turn(.landscapeLeft); capture("Rotation · landscape camera preview"); captureTiming("Idle preview timing")
        #if !targetEnvironment(simulator)
        if dual {
            // Measure the first matching composite actually presented on screen,
            // not just the window turning or the capture request returning.
            let report = preview.value as? String ?? ""
            let values = report.components(separatedBy: "; dual presented (ms): ").last?
                .components(separatedBy: ";").first?.split(separator: ",").compactMap { Int($0) } ?? []
            XCTAssertEqual(values.count, 9, report)
            XCTAssertLessThan(values.max() ?? .max, 350, report)
        }
        useEmptyRecordingProject(in: app)
        record.tap(); XCTAssertTrue(app.buttons["Stop recording"].waitForExistence(timeout: 12))
        capture("Rotation · landscape recording")
        XCUIDevice.shared.orientation = .portrait; Thread.sleep(forTimeInterval: 0.55)
        XCTAssertEqual(record.label, "Stop recording")
        capture("Rotation · locked take")
        // XCTest hit coordinates follow the simulated device orientation.
        // Return them to the recording window's fixed orientation before tapping.
        turn(.landscapeLeft)
        record.tap()
        expectation(for: NSPredicate(format: "enabled == true AND label == 'Record into this project'"), evaluatedWith: record)
        waitForExpectations(timeout: 20)
        #endif
        turn(.portrait)
        XCTAssertTrue(preview.exists)
        captureTiming("Final preview timing")
        #if !targetEnvironment(simulator)
        app.buttons["Edit this project"].tap()
        let play = app.buttons["Play"]
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 20)
        play.tap()
        XCTAssertTrue(app.buttons["Pause playback"].waitForExistence(timeout: 10))
        capture("Rotation · saved landscape take in editor")
        #endif
    }

    func testLiveEffectsHeader() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication(); app.launchArguments = ["--recorder-controls-test", "-liveVideoEffects", "<5b5d>"]; app.launch()
        let effects = app.buttons["recorder.videoEffects"]
        XCTAssertTrue(effects.waitForExistence(timeout: 15)); effects.tap()
        let done = app.buttons["liveEffects.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertEqual(done.label.lowercased(), "close")
        XCTAssertFalse(app.buttons["Expand controls"].exists); XCTAssertFalse(app.buttons["Collapse controls"].exists)
        let bar = app.navigationBars["Video effects"], collapsedTop = bar.frame.minY
        expandLiveEffects(in: app)
        XCTAssertLessThan(bar.frame.minY, collapsedTop - 80)
        if app.buttons["liveEffects.browse"].exists { app.buttons["liveEffects.browse"].tap() }
        app.buttons["liveEffects.section.colorStyle"].tap()
        let category = app.navigationBars["Color & style"]
        XCTAssertTrue(category.waitForExistence(timeout: 5))
        XCTAssertTrue(category.staticTexts["Color & style"].exists)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "Effects category with native navigation"; shot.lifetime = .keepAlways; add(shot)
        backFromLiveEffects(in: app)
        XCTAssertFalse(category.exists)
        XCUIDevice.shared.orientation = .landscapeRight
        expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: app); waitForExpectations(timeout: 10)
        XCTAssertTrue(done.isHittable); done.tap()
        XCTAssertTrue(effects.waitForExistence(timeout: 5))
    }

    func testLiveEffectCardsAcceptBlankAreaTaps() throws { try liveEffectCardBlankAreaTaps(largeText: false) }
    func testLiveEffectCardsAcceptBlankAreaTapsAtLargeTextSize() throws { try liveEffectCardBlankAreaTaps(largeText: true) }

    func testLiveEffectsToolbarActionsAndDismissal() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--recorder-controls-test", "-liveVideoEffects", "<5b5d>"]
        app.launch()
        let effects = app.buttons["recorder.videoEffects"]
        XCTAssertTrue(effects.waitForExistence(timeout: 15)); effects.tap()
        let close = app.buttons["liveEffects.done"], browse = app.buttons["liveEffects.browse"]
        let actions = app.buttons["liveEffects.actions"], clear = app.buttons["liveEffects.clear"]
        XCTAssertTrue(close.waitForExistence(timeout: 5)); XCTAssertFalse(browse.exists)
        expandLiveEffects(in: app)
        func addCorrection() {
            app.buttons["liveEffects.section.colorStyle"].tap()
            app.buttons["liveEffects.add.colorCorrection"].tap()
            XCTAssertTrue(browse.waitForExistence(timeout: 5))
            XCTAssertFalse(close.exists, "The inspector uses Add without a competing Close button")
        }
        addCorrection()
        let inspector = XCTAttachment(screenshot: app.screenshot())
        inspector.name = "Effect editor with neutral Add only"; inspector.lifetime = .keepAlways; add(inspector)
        backFromLiveEffects(in: app)
        XCTAssertTrue(actions.waitForExistence(timeout: 5)); XCTAssertTrue(browse.exists)
        XCTAssertFalse(close.exists); XCTAssertFalse(clear.exists)
        actions.tap(); XCTAssertTrue(clear.waitForExistence(timeout: 3))
        let menu = XCTAttachment(screenshot: app.screenshot())
        menu.name = "Applied effect actions menu"; menu.lifetime = .keepAlways; add(menu)
        clear.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 5)); XCTAssertFalse(browse.exists)
        XCTAssertTrue(app.buttons["liveEffects.section.colorStyle"].exists)
        addCorrection()
        dismissLiveEffects(in: app)
        XCTAssertTrue(effects.isHittable)
        effects.tap(); XCTAssertTrue(actions.waitForExistence(timeout: 5))
        XCTAssertFalse(close.exists)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        XCTAssertTrue(actions.waitForNonExistence(timeout: 5), "Tapping the viewfinder outside the compact sheet dismisses it")
        XCTAssertTrue(effects.isHittable)
    }

    private func liveEffectCardBlankAreaTaps(largeText: Bool) throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--recorder-controls-test", "-liveVideoEffects", "<5b5d>"]
        if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        XCTAssertTrue(app.buttons["recorder.videoEffects"].waitForExistence(timeout: 15))
        app.buttons["recorder.videoEffects"].tap()
        expandLiveEffects(in: app)
        let category = app.buttons["liveEffects.section.colorStyle"]
        XCTAssertTrue(category.waitForExistence(timeout: 5))
        // The top padding is visibly inside the glass card, outside every glyph.
        func tapPadding(_ card: XCUIElement) {
            card.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0)).withOffset(CGVector(dx: 0, dy: 3)).tap()
        }
        tapPadding(category)
        XCTAssertTrue(app.navigationBars["Color & style"].waitForExistence(timeout: 3), "The empty part of a category card must open it")
        let effectCard = app.buttons["liveEffects.add.colorCorrection"]
        revealInViewport(effectCard, scroll: app.scrollViews["liveEffects.controls"])
        tapPadding(effectCard)
        XCTAssertTrue(app.sliders["colorCorrection.slider.exposure"].waitForExistence(timeout: 5), "The empty part of an effect card must add and open it")
        XCTAssertFalse(app.buttons["liveEffects.done"].exists)
        XCTAssertTrue(app.buttons["liveEffects.browse"].exists)
        backFromLiveEffects(in: app)
        XCTAssertTrue(app.buttons["Color Correction"].waitForExistence(timeout: 5), "The effect was added to the applied list")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = largeText ? "Effect added through card padding at large text size" : "Effect added through card padding"
        shot.lifetime = .keepAlways; add(shot)
        dismissLiveEffects(in: app)
    }

    func testTapPreviewDismissesAppliedEffectsAndPreservesFocus() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--recorder-controls-test", "--probe-lens-controls", "-liveVideoEffects", "<5b5d>"]
        app.launch()
        let effects = app.buttons["recorder.videoEffects"], done = app.buttons["liveEffects.browse"]
        let preview = app.otherElements["recorder.preview"]
        XCTAssertTrue(effects.waitForExistence(timeout: 20))
        let focus = app.descendants(matching: .any)["recorder.focus"].firstMatch
        if focus.label == "Manual focus" { focus.tap() }
        let first = preview.coordinate(withNormalizedOffset: CGVector(dx: 0.28, dy: 0.28))
        let second = preview.coordinate(withNormalizedOffset: CGVector(dx: 0.70, dy: 0.32))
        first.tap()
        effects.tap()
        let clear = app.buttons["liveEffects.actions"]
        if clear.exists { clearLiveEffects(in: app) }
        openEffectSection("cameraFrame", in: app, live: true)
        app.buttons["liveEffects.add.kaleidoscope"].tap()
        XCTAssertTrue(app.buttons["liveEffects.done"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["liveEffects.browse"].exists, "Direct preview tools keep Close as their single toolbar action")
        backFromLiveEffects(in: app)
        let row = app.buttons["Kaleidoscope"]
        app.switches["Enable Kaleidoscope"].tap()
        XCTAssertEqual(row.value as? String, "Off")
        #if !targetEnvironment(simulator)
        func focusPoint() throws -> String {
            let value = try XCTUnwrap(preview.value as? String)
            return try XCTUnwrap(value.split(separator: " ").first { $0.hasPrefix("afPoint=") }.map(String.init))
        }
        let initialFocus = try focusPoint()
        #endif
        second.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 5))
        XCTAssertTrue(effects.isHittable)
        effects.tap()
        XCTAssertEqual(row.value as? String, "Off")
        #if !targetEnvironment(simulator)
        XCTAssertEqual(try focusPoint(), initialFocus, "Dismissing the panel must consume the tap")
        dismissLiveEffects(in: app)
        second.tap()
        effects.tap()
        XCTAssertNotEqual(try focusPoint(), initialFocus, "The next viewfinder tap should focus normally")
        #endif
        clearLiveEffects(in: app)
        openEffectSection("cameraFrame", in: app, live: true)
        app.buttons["liveEffects.add.crashZoom"].tap()
        second.tap()
        XCTAssertTrue(done.exists, "The Crash Zoom inspector uses a picture tap to select its subject")
        backFromLiveEffects(in: app)
        second.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 5), "An enabled zoom in the stack must still allow dismissal while browsing")
        effects.tap(); clearLiveEffects(in: app)
        dismissLiveEffects(in: app)
    }

    func testLiveEffectHelpInLandscape() throws {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--recorder-controls-test"]; app.launch()
        XCTAssertTrue(app.buttons["recorder.videoEffects"].waitForExistence(timeout: 20)); app.buttons["recorder.videoEffects"].tap()
        // Do not clear somebody's live effects to prepare a help-only test.
        if app.buttons["liveEffects.actions"].waitForExistence(timeout: 2) { throw XCTSkip("Live effects are already configured; preserve them") }
        XCTAssertFalse(app.buttons["liveEffects.section.presets"].exists)
        openEffectSection("colorStyle", in: app, live: true)
        app.buttons["liveEffects.add.silentTint"].tap()
        let help = app.buttons["effectHelp.silentTint"]
        XCTAssertTrue(help.waitForExistence(timeout: 10)); help.tap()
        XCTAssertTrue(app.staticTexts["Film technique"].waitForExistence(timeout: 10))
        XCUIDevice.shared.orientation = .landscapeRight
        expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: app); waitForExpectations(timeout: 10)
        XCTAssertTrue(app.staticTexts["Film technique"].exists)
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); image.name = "Live help landscape"; image.lifetime = .keepAlways; add(image)
        app.buttons["inspectorHelp.done"].tap()
        XCTAssertTrue(app.buttons["inspectorHelp.done"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(help.waitForExistence(timeout: 10))
        backFromLiveEffects(in: app)
        let clear = app.buttons["liveEffects.actions"]
        XCTAssertTrue(clear.waitForExistence(timeout: 10)); clearLiveEffects(in: app)
        dismissLiveEffects(in: app); XCUIDevice.shared.orientation = .portrait
    }

    func testSubtitlePlacementAndInspection() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--subtitles-ui-fixture"]; app.launch()
        openTool("subtitles", in: app)
        let seek = app.sliders["subtitles.seek"]
        XCTAssertTrue(seek.waitForExistence(timeout: 30))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: seek); waitForExpectations(timeout: 30)
        seek.adjust(toNormalizedSliderPosition: 0.08)
        let caption = app.otherElements["subtitles.placement"], preview = app.otherElements["subtitles.preview"]
        XCTAssertTrue(caption.waitForExistence(timeout: 10))
        let original = caption.value as? String
        preview.pinch(withScale: 2, velocity: 1)
        let reset = app.buttons["editor.preview.resetZoom"]
        XCTAssertTrue(reset.waitForExistence(timeout: 5))
        preview.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.2)).press(forDuration: 0.05, thenDragTo: preview.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.2)))
        reset.tap()
        XCTAssertEqual(caption.value as? String, original, "Inspecting must not move or resize exported captions")
        XCTAssertTrue((preview.value as? String ?? "").contains("1.00× view"))
        caption.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.05, thenDragTo: preview.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.35)))
        XCTAssertNotEqual(caption.value as? String, original, "Dragging the actual caption changes placement")
        let moved = caption.value as? String
        caption.pinch(withScale: 1.5, velocity: 1)
        XCTAssertNotEqual(caption.value as? String, moved, "Pinching the caption resizes the series")
        XCTAssertFalse(reset.exists, "Caption pinch must not zoom the inspection view")
        let resized = caption.value as? String
        app.buttons["subtitles.inspect"].tap()
        preview.pinch(withScale: 2, velocity: 1)
        XCTAssertTrue(reset.waitForExistence(timeout: 5)); reset.tap()
        app.buttons["subtitles.inspect"].tap()
        XCTAssertEqual(caption.value as? String, resized, "Explicit inspection works without changing even a large caption")
        let appearance = app.buttons["Appearance"]
        for _ in 0..<5 { if appearance.isHittable { break }; app.scrollViews["subtitles.controls"].swipeUp() }
        appearance.tap()
        let controls = app.scrollViews["subtitles.controls"]
        let fonts = app.buttons["subtitles.tab.Font"]
        revealInViewport(fonts,scroll:controls); fonts.tap()
        let face = app.buttons["subtitles.face.sourceserif4"]
        revealInViewport(face,scroll:controls); face.tap()
        XCTAssertTrue((caption.value as? String ?? "").contains("Source Serif 4"))
        let portrait = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); portrait.name = "Caption placement and fonts portrait"; portrait.lifetime = .keepAlways; add(portrait)
        let placed = caption.value as? String
        XCUIDevice.shared.orientation = .landscapeRight
        expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: app); waitForExpectations(timeout: 10)
        XCTAssertEqual(caption.value as? String, placed, "Device rotation cannot change subtitle placement")
        let landscape = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); landscape.name = "Caption placement landscape"; landscape.lifetime = .keepAlways; add(landscape)
        app.buttons["subtitles.apply"].tap()
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 20))
        app.terminate(); app.launchArguments = ["--editor-preview"]; app.launch(); openTool("subtitles", in: app)
        let again = app.sliders["subtitles.seek"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: again); waitForExpectations(timeout: 30)
        again.adjust(toNormalizedSliderPosition: 0.5)
        XCTAssertTrue(caption.waitForExistence(timeout: 10)); XCTAssertEqual(caption.value as? String, placed)
        app.buttons["Cancel"].firstMatch.tap()
    }

    func testToolPreviewInspectionDoesNotEditText() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]; app.launch()
        openTool("text", in: app)
        XCTAssertTrue(app.buttons["tool.preview.inspect"].waitForExistence(timeout: 20))
        let field = app.textFields["tool.text.input"].exists ? app.textFields["tool.text.input"] : app.textViews["tool.text.input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("Inspection stays separate")
        app.buttons["Done"].firstMatch.tap()
        let text = app.images["tool.text.overlay"].exists ? app.images["tool.text.overlay"] : app.otherElements["tool.text.overlay"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        let before = text.frame
        app.buttons["tool.preview.inspect"].tap()
        let preview = app.otherElements["tool.preview.inspection"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5)); preview.pinch(withScale: 2, velocity: 1)
        XCTAssertTrue(app.buttons["tool.preview.resetZoom"].waitForExistence(timeout: 5))
        preview.swipeLeft(); app.buttons["tool.preview.resetZoom"].tap()
        XCTAssertTrue((preview.value as? String ?? "").contains("1.00× view"))
        preview.pinch(withScale: 0.5, velocity: -1)
        XCTAssertFalse(app.buttons["tool.preview.resetZoom"].exists)
        app.buttons["tool.preview.inspect"].tap()
        XCTAssertEqual(text.frame, before, "Inspection does not resize exported text")
        app.buttons["tool.cancel"].tap()
    }

    func testSubtitleEditorWorkflow() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--subtitles-ui-fixture"]; app.launch()
        func open() {
            openTool("subtitles", in: app)
            XCTAssertTrue(app.buttons["subtitles.apply"].waitForExistence(timeout: 15))
        }
        func reveal(_ element: XCUIElement) {
            for _ in 0..<7 { if element.isHittable { return }; app.scrollViews["subtitles.controls"].swipeUp() }
            XCTAssertTrue(element.isHittable)
        }
        open()
        let step = app.steppers["subtitles.maxWords"]; reveal(step)
        XCTAssertTrue(step.isEnabled)
        step.buttons["subtitles.maxWords-Increment"].tap()
        XCTAssertEqual(step.value as? String, "7")
        app.sliders["subtitles.seek"].adjust(toNormalizedSliderPosition: 0.1)
        let portrait = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); portrait.name = "Subtitles portrait"; portrait.lifetime = .keepAlways; add(portrait)
        XCUIDevice.shared.orientation = .landscapeRight
        expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: app); waitForExpectations(timeout: 10)
        let landscape = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); landscape.name = "Subtitles landscape"; landscape.lifetime = .keepAlways; add(landscape)
        XCUIDevice.shared.orientation = .portrait
        expectation(for: NSPredicate { _, _ in app.frame.width < app.frame.height }, evaluatedWith: app); waitForExpectations(timeout: 10)
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'subtitles.sentence.'")).firstMatch
        reveal(row); row.tap()
        let field = app.textFields["subtitles.text"].exists ? app.textFields["subtitles.text"] : app.textViews["subtitles.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (field.value as? String ?? "").count) + "Corrected subtitle text.")
        let save = app.buttons["subtitles.saveText"]; reveal(save); save.tap()
        app.buttons["subtitles.apply"].tap()
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 20))
        app.terminate(); app.launchArguments = ["--editor-preview"]; app.launch(); open()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Corrected subtitle text.'")).firstMatch.waitForExistence(timeout: 10))
        let remove = app.buttons["subtitles.remove"]; reveal(remove); remove.tap()
        app.buttons.matching(identifier: "Remove all subtitles").allElementsBoundByIndex.last!.tap(); app.buttons["subtitles.apply"].tap()
        XCTAssertTrue(app.buttons["Undo"].waitForExistence(timeout: 20)); app.buttons["Undo"].tap()
        open()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Corrected subtitle text.'")).firstMatch.waitForExistence(timeout: 10))
        app.buttons["Cancel"].firstMatch.tap()
    }

    func testCopyFullTranscriptFromMarkedRange() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["YOUREC_EDITOR_FIXTURE_TITLE"] = "Copy transcript · UI test"
        app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--subtitles-ui-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["Mark start"].waitForExistence(timeout: 30))
        seekTimeline(fraction: 0.35, in: app); app.buttons["Mark start"].tap()
        seekTimeline(fraction: 0.65, in: app); app.buttons["Mark end"].tap()
        openTool("subtitles", in: app)
        let controls = app.scrollViews["subtitles.controls"], copy = app.buttons["subtitles.copyTranscript"]
        let sentence = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'subtitles.sentence.'")).firstMatch
        func openSentence() -> XCUIElement {
            revealInViewport(sentence, scroll: controls)
            sentence.tap()
            return app.textFields["subtitles.text"].exists ? app.textFields["subtitles.text"] : app.textViews["subtitles.text"]
        }
        let field = openSentence()
        XCTAssertFalse(copy.isEnabled)
        let original = try XCTUnwrap(field.value as? String)
        let corrected = "Edited sentence!"
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: original.count) + corrected)
        XCTAssertEqual(field.value as? String, corrected)
        app.buttons["subtitles.saveText"].tap()
        revealInViewport(copy, scroll: controls); copy.tap()
        XCTAssertEqual(copy.label, "Transcript copied")

        // Paste with the system text menu, in the same app that wrote the clipboard.
        let destination = openSentence()
        let existing = try XCTUnwrap(destination.value as? String)
        destination.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        destination.press(forDuration: 0.8)
        let paste = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Paste' OR label == 'Incolla'")).firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 5)); paste.tap()
        let full = "This is the opening sentence. We can correct these words. Captions follow the spoken audio. Change the style while watching. Short phrases are easy to read. The final sentence ends here."
        XCTAssertTrue(full.contains(original))
        XCTAssertEqual(destination.value as? String, full.replacingOccurrences(of: original, with: corrected))
        app.buttons["Cancel edit"].tap()
    }

    func testSubtitleSelectedRangeAndStaleGrouping() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--subtitles-ui-fixture", "--multiselect-fixture"]; app.launch()
        let play = app.buttons["Play"]
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 30)
        app.buttons["Timeline view span"].tap(); app.buttons["Whole project"].tap()
        let clip = app.buttons["timeline.video.2"]
        XCTAssertTrue(clip.waitForExistence(timeout: 20)); clip.tap()
        app.buttons["Unlink"].tap()
        let clear = app.buttons["editor.clearSelection"]; XCTAssertTrue(clear.waitForExistence(timeout: 10)); clear.tap(); clip.tap()
        XCTAssertTrue(clip.isSelected); XCTAssertFalse(app.buttons["timeline.audio.2"].isSelected)
        openTool("subtitles", in: app)
        XCTAssertTrue(app.buttons["subtitles.apply"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '0:06.00–0:12.00'")).firstMatch.exists)
        XCTAssertFalse(app.steppers["subtitles.maxWords"].isEnabled)
        XCTAssertTrue(app.buttons["subtitles.copyTranscript"].isEnabled)
        XCTAssertTrue(app.staticTexts["subtitles.stale"].exists)
        let seek = app.sliders["subtitles.seek"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: seek); waitForExpectations(timeout: 20)
        seek.adjust(toNormalizedSliderPosition: 0)
        XCTAssertTrue(app.staticTexts["0:06.00"].waitForExistence(timeout: 5))
        // Drag through the end stop. XCTest’s normalized adjustment can release
        // a point early on hardware, which is a full frame for this range.
        seek.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: seek.coordinate(withNormalizedOffset: CGVector(dx: 1.08, dy: 0.5)))
        XCTAssertTrue(app.staticTexts["0:11.97"].waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Selected range and stale transcript"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["Cancel"].firstMatch.tap()
    }

    func testInlineTranscriptionCancelAndRetry() throws {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--subtitle-speech-fixture"]
        app.launch(); openTool("subtitles", in: app)
        let start = app.buttons["subtitles.transcribe"], cancel = app.buttons["subtitles.cancelJob"]
        XCTAssertTrue(start.waitForExistence(timeout: 25))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: start); waitForExpectations(timeout: 25)
        start.tap(); XCTAssertTrue(cancel.waitForExistence(timeout: 8)); cancel.tap()
        XCTAssertTrue(start.waitForExistence(timeout: 3))
        XCTAssertFalse(cancel.exists)
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: start); waitForExpectations(timeout: 20)
        start.tap()
        XCTAssertTrue(app.steppers["subtitles.maxWords"].waitForExistence(timeout: 120))
    }

    func testSubtitleSpeechGenerationPhysical() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--subtitle-speech-fixture"]; app.launch()
        openTool("subtitles", in: app)
        let transcribe = app.buttons["subtitles.transcribe"]
        XCTAssertTrue(transcribe.waitForExistence(timeout: 30))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: transcribe); waitForExpectations(timeout: 30)
        transcribe.tap()
        let step = app.steppers["subtitles.maxWords"]
        XCTAssertTrue(step.waitForExistence(timeout: 120), "Real edited audio should produce captions")
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: step); waitForExpectations(timeout: 30)
        step.buttons["subtitles.maxWords-Decrement"].tap()
        app.sliders["subtitles.seek"].adjust(toNormalizedSliderPosition: 0.25)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Real speech subtitles"; shot.lifetime = .keepAlways; add(shot)
        let play = app.buttons["Play subtitles preview"]; XCTAssertTrue(play.waitForExistence(timeout: 20)); play.tap()
        XCTAssertTrue(app.buttons["Pause subtitles preview"].waitForExistence(timeout: 5)); app.buttons["Pause subtitles preview"].tap()
        app.buttons["subtitles.apply"].tap()
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 20))
        let applied = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); applied.name = "Applied real speech subtitles"; applied.lifetime = .keepAlways; add(applied)
    }

    private var recorderReturnToPortrait: Bool?
    override func tearDownWithError() throws {
        if let portrait = recorderReturnToPortrait {
            XCUIDevice.shared.orientation = portrait ? .portrait : .landscapeRight
            recorderReturnToPortrait = nil
        }
        try super.tearDownWithError()
    }
    func testDualCameraSimulatorControls() throws { try dualCameraControls(physical: false) }
    func testDualCameraPhysicalControls() throws { try dualCameraControls(physical: true) }
    func testDualCameraPhysicalPortraitControls() throws { try dualCameraControls(physical: true, portrait: true) }
    func testDualCameraPortraitControls() throws { try dualCameraControls(physical: false, portrait: true) }
    private func launchDualLayoutRecorder(physical: Bool) throws -> XCUIApplication {
        let app = XCUIApplication()
        // Supply the initial layout through the argument domain, independently of the last take.
        let data = try JSONEncoder().encode(DualCameraLayout())
        let hex = data.map { String(format: "%02x", $0) }.joined()
        app.launchArguments = [physical ? "--dual-capture-ui-test" : "--recorder-controls-test",
                               "-dualCameraLayout", "<\(hex)>"]
        app.launch()
        return app
    }
    private func setDualMode(_ enabled: Bool, in app: XCUIApplication) {
        app.buttons["recorder.settings"].tap()
        let toggle = app.switches["recorder.dualEnabled"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: toggle); waitForExpectations(timeout: 20)
        if (toggle.value as? String == "1") != enabled {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
        expectation(for: NSPredicate(format: "value == %@ AND enabled == true", enabled ? "1" : "0"), evaluatedWith: toggle)
        waitForExpectations(timeout: 20)
        app.buttons["recorder.settingsDone"].tap()
    }
    func testTwoCameraSupportedPairs() throws { try twoCameraSupportedPairs(assists: false) }
    func testTwoCameraAssistedPairs() throws { try twoCameraSupportedPairs(assists: true) }
    private func twoCameraSupportedPairs(assists: Bool) throws {
        continueAfterFailure = false; recorderReturnToPortrait = true
        XCUIDevice.shared.orientation = .portrait
        let app = try launchDualLayoutRecorder(physical: true)
        let dual = app.buttons["recorder.settings"], record = app.buttons["recorder.record"]
        XCTAssertTrue(dual.waitForExistence(timeout: 25))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: dual); waitForExpectations(timeout: 20)
        setDualMode(true, in: app)
        if assists {
            dual.tap()
            let stabilize = app.descendants(matching: .any)["recorder.dualStabilization"], follow = app.descendants(matching: .any)["recorder.dualFaceFollow"]
            if stabilize.value as? String != "On" { stabilize.tap() }
            expectation(for: NSPredicate(format: "enabled == true AND value == 'On'"), evaluatedWith: stabilize); waitForExpectations(timeout: 20)
            if follow.value as? String != "On" { follow.tap() }
            app.buttons["recorder.settingsDone"].tap()
        }
        app.buttons["recorder.dualLayout"].tap()
        app.buttons["recorder.layout.sideBySide"].tap(); app.buttons["Done"].tap()
        dual.tap()
        let first = app.buttons["recorder.dualFirst"], second = app.buttons["recorder.dualSecond"]
        func lensNames() -> [String] { app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Rear ' OR label BEGINSWITH 'Front '")).allElementsBoundByIndex.map(\.label) }
        first.tap(); let cameras = lensNames(); XCTAssertFalse(cameras.isEmpty)
        app.buttons[cameras[0]].tap()
        var tested = Set<String>()
        for name in cameras {
            expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: first); waitForExpectations(timeout: 20)
            first.tap(); app.buttons[name].tap()
            expectation(for: NSPredicate(format: "enabled == true AND value == %@", name), evaluatedWith: first); waitForExpectations(timeout: 20)
            second.tap(); let partners = lensNames()
            XCTAssertFalse(partners.isEmpty); XCTAssertFalse(partners.contains(name), "A camera cannot occupy both slots")
            app.buttons[partners[0]].tap()
            for partner in partners {
                expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: second); waitForExpectations(timeout: 20)
                second.tap(); app.buttons[partner].tap()
                expectation(for: NSPredicate(format: "enabled == true AND value == %@", partner), evaluatedWith: second); waitForExpectations(timeout: 20)
                XCTAssertEqual(first.value as? String, name, "Selecting the second camera keeps the first")
                let pair = [name, partner].sorted().joined(separator: " + ")
                guard tested.insert(pair).inserted else { continue }
                let controls = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); controls.name = "Camera choices: " + pair; controls.lifetime = .keepAlways; add(controls)
                app.buttons["recorder.settingsDone"].tap()
                record.tap(); expectation(for: NSPredicate(format: "label == 'Stop recording'"), evaluatedWith: record); waitForExpectations(timeout: 20)
                Thread.sleep(forTimeInterval: 1.5)
                let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Pair: " + pair; shot.lifetime = .keepAlways; add(shot)
                record.tap(); expectation(for: NSPredicate(format: "label == 'Record into this project' AND enabled == true"), evaluatedWith: record); waitForExpectations(timeout: 25)
                dual.tap()
            }
        }
        // Review the same setup panel in landscape without changing capture code.
        app.buttons["recorder.settingsDone"].tap(); XCUIDevice.shared.orientation = .landscapeRight
        expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height && dual.isHittable }, evaluatedWith: app); waitForExpectations(timeout: 10)
        dual.tap()
        XCTAssertTrue(first.isHittable); XCTAssertTrue(second.isHittable)
        let landscape = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); landscape.name = "Dual camera settings landscape"; landscape.lifetime = .keepAlways; add(landscape)
        app.buttons["recorder.settingsDone"].tap()
        setDualMode(false, in: app)
        XCTAssertTrue(app.buttons["recorder.flip"].waitForExistence(timeout: 20))
    }

    func testDualInsetShapePhysical() throws { try dualInsetShape(physical: true) }
    func testDualAssistPhysical() throws { try dualAssist(physical: true) }
    func testDualAssistSimulator() throws { try dualAssist(physical: false) }
    private func assertFrontLightCorner(in app: XCUIApplication) {
        let bulb = app.buttons["recorder.frontLightBulb"]
        XCTAssertTrue(bulb.isHittable)
        let target = bulb.frame, screen = app.frame, shutter = app.buttons["recorder.record"].frame
        let leftCorner = screen.width > screen.height && shutter.midX > screen.midX
        let insetX = leftCorner ? target.midX - screen.minX : screen.maxX - target.midX
        XCTAssertTrue((22...44).contains(insetX), "Horizontal corner inset: \(insetX)")
        XCTAssertTrue((22...44).contains(screen.maxY - target.midY), "Bulb must be in the bottom corner")
        XCTAssertGreaterThanOrEqual(target.width, 44); XCTAssertGreaterThanOrEqual(target.height, 44)
        XCTAssertFalse(target.intersects(shutter))
        for name in ["Edit this project", "Pause recording", "recorder.bookmark"] {
            let button = app.buttons[name]
            if button.exists { XCTAssertFalse(target.intersects(button.frame), name) }
        }
    }

    func testFrontLightWhileRecording() throws {
        continueAfterFailure = false
        recorderReturnToPortrait = true
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--recorder-controls-test"]
        app.launch()
        let menu = app.buttons["recorder.settings"]
        let light = app.descendants(matching: .any)["recorder.frontLight"]
        let bulb = app.buttons["recorder.frontLightBulb"]
        let opacity = app.sliders["recorder.frontLightOpacity"]
        let close = app.buttons["Close front light controls"]
        let record = app.buttons["recorder.record"]
        func waitEnabled(_ item: XCUIElement) {
            expectation(for: NSPredicate(format: "exists == true AND enabled == true"), evaluatedWith: item)
            waitForExpectations(timeout: 25)
        }
        func screenshot(_ name: String) {
            let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            image.name = name; image.lifetime = .keepAlways; add(image)
        }
        func toggleInCameraControls() {
            menu.tap(); XCTAssertTrue(light.waitForExistence(timeout: 5))
            light.tap(); app.buttons["recorder.settingsDone"].tap()
        }
        waitEnabled(menu)
        // Starting with the two cameras off also exercises entry from the single-camera menu.
        setDualMode(false, in: app)
        let flip = app.buttons["recorder.flip"]
        if flip.label == "Switch to front camera" { flip.tap(); waitEnabled(flip) }
        XCTAssertFalse(bulb.exists)
        toggleInCameraControls()
        XCTAssertTrue(bulb.waitForExistence(timeout: 5))
        bulb.tap()
        app.buttons["Wide"].tap(); app.buttons["Warm"].tap()
        opacity.adjust(toNormalizedSliderPosition: 1)
        XCTAssertTrue(app.buttons["Wide"].isSelected); XCTAssertTrue(app.buttons["Warm"].isSelected)
        screenshot("Front light portrait settings")
        close.tap()
        XCTAssertEqual(bulb.value as? String, "Wide, Warm, 100%")
        record.tap()
        expectation(for: NSPredicate(format: "label == 'Stop recording'"), evaluatedWith: record)
        waitForExpectations(timeout: 20)
        screenshot("Front light portrait recording")
        bulb.tap(); opacity.adjust(toNormalizedSliderPosition: 0.5)
        let midOpacity = try XCTUnwrap(opacity.value as? String)
        // XCTest drags the thumb by screen coordinates; the nearest step varies by device.
        XCTAssertFalse(["0%", "100%"].contains(midOpacity), midOpacity)
        close.tap()
        XCTAssertEqual(bulb.value as? String, "Wide, Warm, " + midOpacity)
        screenshot("Front light portrait recording translucent")
        bulb.tap(); opacity.adjust(toNormalizedSliderPosition: 0); close.tap()
        XCTAssertEqual(bulb.value as? String, "Wide, Warm, 0%")
        screenshot("Front light portrait transparent with bulb")
        bulb.tap(); opacity.adjust(toNormalizedSliderPosition: 0.5)
        let savedOpacity = try XCTUnwrap(opacity.value as? String)
        XCTAssertFalse(["0%", "100%"].contains(savedOpacity), savedOpacity)
        app.buttons["Turn off front light"].tap()
        XCTAssertFalse(bulb.exists); XCTAssertEqual(record.label, "Stop recording")
        screenshot("Front light portrait recording off")
        toggleInCameraControls()
        XCTAssertEqual(bulb.value as? String, "Wide, Warm, " + savedOpacity)
        record.tap()
        expectation(for: NSPredicate(format: "label == 'Record into this project' AND enabled == true"), evaluatedWith: record)
        waitForExpectations(timeout: 25)

        // Keep a short, uninterrupted take for comparing saved frames with the lit display.
        bulb.tap(); opacity.adjust(toNormalizedSliderPosition: 1); close.tap()
        record.tap()
        expectation(for: NSPredicate(format: "label == 'Stop recording'"), evaluatedWith: record)
        waitForExpectations(timeout: 20)
        screenshot("Front light portrait second take")
        record.tap()
        expectation(for: NSPredicate(format: "label == 'Record into this project' AND enabled == true"), evaluatedWith: record)
        waitForExpectations(timeout: 25)

        XCUIDevice.shared.orientation = .landscapeRight
        expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: app)
        waitForExpectations(timeout: 10)
        setDualMode(true, in: app)
        bulb.tap(); app.buttons["Thin"].tap(); app.buttons["Cool"].tap()
        screenshot("Front light landscape settings")
        close.tap()
        XCTAssertEqual(bulb.value as? String, "Thin, Cool, 100%")
        assertFrontLightCorner(in: app)
        record.tap()
        expectation(for: NSPredicate(format: "label == 'Stop recording'"), evaluatedWith: record)
        waitForExpectations(timeout: 20)
        screenshot("Front light landscape dual recording")
        bulb.tap(); app.buttons["Turn off front light"].tap()
        record.tap()
        expectation(for: NSPredicate(format: "label == 'Record into this project' AND enabled == true"), evaluatedWith: record)
        waitForExpectations(timeout: 25)
        setDualMode(false, in: app)
    }

    func testFrontLightCustomColor() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--recorder-controls-test"]
        app.launch()
        let controls = app.buttons["recorder.settings"]
        let bulb = app.buttons["recorder.frontLightBulb"]
        let custom = app.buttons["Custom"]
        let close = app.buttons["Close front light controls"]
        let record = app.buttons["recorder.record"]
        func openLight() {
            expectation(for: NSPredicate(format: "exists == true AND enabled == true"), evaluatedWith: controls)
            waitForExpectations(timeout: 25)
            controls.tap()
            app.descendants(matching: .any)["recorder.frontLight"].tap()
            app.buttons["recorder.settingsDone"].tap()
            bulb.tap()
        }
        openLight()
        for preset in ["White", "Warm", "Cool"] {
            app.buttons[preset].tap()
            XCTAssertTrue(app.buttons[preset].isSelected)
        }
        app.buttons["Wide"].tap()
        app.sliders["recorder.frontLightOpacity"].adjust(toNormalizedSliderPosition: 1)
        close.tap(); record.tap()
        expectation(for: NSPredicate(format: "label == 'Stop recording'"), evaluatedWith: record)
        waitForExpectations(timeout: 20)
        bulb.tap()
        custom.tap()
        // The system picker uses the phone's language, independently of YouRec's test language.
        let grid = app.buttons.matching(NSPredicate(format: "label IN %@", ["Grid", "Griglia"])).firstMatch
        XCTAssertTrue(grid.waitForExistence(timeout: 10)); grid.tap()
        let green = app.otherElements.matching(NSPredicate(format: "label MATCHES[c] '(green|verde) [0-9]+'")).firstMatch
        XCTAssertTrue(green.isHittable); green.tap()
        let sheet = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        sheet.name = "Front light custom color picker"; sheet.lifetime = .keepAlways; add(sheet)
        let closePicker = app.buttons.matching(NSPredicate(format: "label IN[c] %@", ["close", "chiudi"])).firstMatch
        closePicker.tap()
        XCTAssertTrue(closePicker.waitForNonExistence(timeout: 5))
        XCTAssertTrue(custom.isSelected)
        let selectedColor = try XCTUnwrap(custom.value as? String)
        XCTAssertTrue(["green", "verde"].contains { selectedColor.localizedCaseInsensitiveContains($0) }, selectedColor)
        close.tap()
        assertFrontLightCorner(in: app)
        XCTAssertEqual(record.label, "Stop recording")
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Custom green front light during take"; screenshot.lifetime = .keepAlways; add(screenshot)
        record.tap()
        expectation(for: NSPredicate(format: "label == 'Record into this project' AND enabled == true"), evaluatedWith: record)
        waitForExpectations(timeout: 25)
        app.terminate(); app.launch(); openLight()
        XCTAssertTrue(custom.isSelected); XCTAssertEqual(custom.value as? String, selectedColor)
        app.buttons["White"].tap(); custom.tap()
        XCTAssertTrue(grid.waitForExistence(timeout: 6))
        closePicker.tap()
        XCTAssertTrue(closePicker.waitForNonExistence(timeout: 5))
        XCTAssertTrue(custom.isSelected); XCTAssertEqual(custom.value as? String, selectedColor)
        app.buttons["Turn off front light"].tap()
    }

    func testFrontLightLeavingRecorder() throws {
        continueAfterFailure = false
        recorderReturnToPortrait = true
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--recorder-controls-test"]
        app.launch()
        let menu = app.buttons["recorder.settings"]
        let light = app.descendants(matching: .any)["recorder.frontLight"]
        let bulb = app.buttons["recorder.frontLightBulb"]
        func openControls() {
            expectation(for: NSPredicate(format: "exists == true AND enabled == true"), evaluatedWith: menu)
            waitForExpectations(timeout: 25); menu.tap()
        }
        openControls()
        XCTAssertEqual(light.value as? String, "Off")
        light.tap(); app.buttons["recorder.settingsDone"].tap()
        assertFrontLightCorner(in: app)
        bulb.tap()
        app.buttons["Medium"].tap(); app.buttons["Warm"].tap()
        app.sliders["recorder.frontLightOpacity"].adjust(toNormalizedSliderPosition: 1)
        app.buttons["Close front light controls"].tap()
        app.buttons["Projects"].tap()
        XCTAssertFalse(bulb.exists)
        app.buttons["Record"].tap()
        openControls()
        XCTAssertEqual(light.value as? String, "Off")
        light.tap(); app.buttons["recorder.settingsDone"].tap()
        XCTAssertEqual(bulb.value as? String, "Medium, Warm, 100%")
        openControls(); light.tap(); app.buttons["recorder.settingsDone"].tap()
        XCTAssertFalse(bulb.exists)
    }

    private func checkStabilizationHelp(in app: XCUIApplication, control: XCUIElement) {
        control.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.7)
        let help = app.alerts["Camera assist"]
        XCTAssertTrue(help.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Camera stabilized")).firstMatch.waitForExistence(timeout: 5))
        help.buttons["OK"].tap()
    }

    func testSingleCameraAssists() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--recorder-controls-test"]
        app.launch()
        let menu = app.buttons["recorder.settings"], close = app.buttons["recorder.settingsDone"]
        let two = app.switches["recorder.dualEnabled"], record = app.buttons["recorder.record"]
        let stabilize = app.descendants(matching: .any)["recorder.dualStabilization"]
        let follow = app.descendants(matching: .any)["recorder.dualFaceFollow"]
        func shot(_ name: String) {
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        func awaitValue(_ control: XCUIElement, _ value: String) {
            expectation(for: NSPredicate(format: "value == %@", value), evaluatedWith: control)
            waitForExpectations(timeout: 12)
        }
        XCTAssertTrue(menu.waitForExistence(timeout: 25))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: menu); waitForExpectations(timeout: 20)
        menu.tap()
        XCTAssertEqual(two.value as? String, "0")
        shot("Single camera menu")
        XCTAssertTrue(stabilize.isHittable); XCTAssertTrue(follow.isHittable)
        let originalStab = stabilize.value as? String, originalFollow = follow.value as? String
        if originalStab == "On" { stabilize.tap(); awaitValue(stabilize, "Off") }
        if originalFollow == "On" { follow.tap(); awaitValue(follow, "Off") }
        let assistY = stabilize.frame.minY, camerasY = two.frame.minY
        close.tap(); shot("Single camera unassisted")
        menu.tap(); stabilize.tap(); awaitValue(stabilize, "On")
        XCTAssertFalse(app.staticTexts["Camera stabilized"].exists)
        checkStabilizationHelp(in: app, control: stabilize)
        XCTAssertEqual(follow.value as? String, "Off")
        XCTAssertEqual(two.value as? String, "0"); close.tap()
        shot("Single camera stabilized")
        menu.tap(); follow.tap(); awaitValue(follow, "On")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label IN %@", ["Looking for a face", "Following face", "Holding last framing"])).firstMatch.exists)
        XCTAssertEqual(stabilize.frame.minY, assistY, accuracy: 1)
        XCTAssertEqual(two.frame.minY, camerasY, accuracy: 1)
        shot("Camera settings with both assists enabled"); close.tap()
        record.tap()
        expectation(for: NSPredicate(format: "label == 'Stop recording'"), evaluatedWith: record); waitForExpectations(timeout: 20)
        shot("Single camera assisted recording")
        #if !targetEnvironment(simulator)
        let preview = app.otherElements["recorder.preview"]
        let marker = preview.coordinate(withNormalizedOffset: CGVector(dx: 0.68, dy: 0.36))
        print("Assisted focus point", marker.screenPoint, "preview bounds", preview.frame)
        marker.tap(); shot("Single camera assisted AF target")
        #endif
        menu.tap(); XCTAssertFalse(stabilize.isEnabled); XCTAssertTrue(follow.isEnabled)
        checkStabilizationHelp(in: app, control: stabilize)
        XCTAssertFalse(two.isEnabled)
        XCTAssertFalse(app.buttons["recorder.color.sdr"].isEnabled)
        XCTAssertFalse(app.buttons["recorder.color.hdr"].isEnabled)
        XCTAssertTrue(app.buttons["recorder.settingsDone"].isHittable)
        shot("Camera controls during single recording")
        XCTAssertEqual(two.value as? String, "0")
        follow.tap(); awaitValue(follow, "Off"); close.tap()
        shot("Single camera recording follow off")
        record.tap()
        expectation(for: NSPredicate(format: "label == 'Record into this project' AND enabled == true"), evaluatedWith: record); waitForExpectations(timeout: 25)
        menu.tap()
        if originalStab == "Off" { stabilize.tap(); awaitValue(stabilize, "Off") }
        if originalFollow == "On" { follow.tap(); awaitValue(follow, "On") }
        close.tap()
    }
    #if !targetEnvironment(simulator)
    func testFrontCameraFollowAtTwoTimesZoom() throws { try checkFrontFollowAtTwoTimes(stabilized: false) }
    func testStabilizedFrontCameraFollowAtTwoTimesZoom() throws { try checkFrontFollowAtTwoTimes(stabilized: true) }
    private func checkFrontFollowAtTwoTimes(stabilized: Bool) throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--recorder-controls-test", "--probe-follow-zoom"]
        if ProcessInfo.processInfo.environment["YOUREC_PRELAUNCHED_FOLLOW_FIXTURE"] == "1" {
            // Some Xcode/iOS combinations can drive the controls but cannot
            // launch the application with debugger injection. Attach only to
            // the explicitly prelaunched, instrumented recorder fixture.
            app.activate()
            let fixture = app.otherElements["recorder.preview"]
            expectation(for: NSPredicate(format: "value BEGINSWITH 'camera '"), evaluatedWith: fixture)
            waitForExpectations(timeout: 18)
        } else { app.launch() }
        let menu = app.buttons["recorder.settings"], close = app.buttons["recorder.settingsDone"]
        let follow = app.descendants(matching: .any)["recorder.dualFaceFollow"]
        let zoom = app.buttons["recorder.zoom"], record = app.buttons["recorder.record"]
        let preview = app.otherElements["recorder.preview"]
        func wait(_ control: XCUIElement, _ predicate: NSPredicate) {
            expectation(for: predicate, evaluatedWith: control); waitForExpectations(timeout: 22)
        }
        func shot(_ name: String) {
            print(name, preview.value ?? "", "zoom", zoom.value ?? "", "viewport", preview.frame)
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); attachment.name = name
            attachment.lifetime = .keepAlways; add(attachment)
        }
        func toggle() { menu.tap(); follow.tap(); close.tap() }
        XCTAssertTrue(menu.waitForExistence(timeout: 20)); wait(menu, NSPredicate(format: "enabled == true"))
        menu.tap()
        if follow.value as? String == "On" { follow.tap() }
        let stabilization = app.descendants(matching: .any)["recorder.dualStabilization"]
        if (stabilization.value as? String == "On") != stabilized { stabilization.tap() }
        close.tap()
        app.buttons["recorder.flip"].tap()
        wait(app.buttons["recorder.camera"], NSPredicate(format: "value BEGINSWITH 'Front' AND enabled == true"))
        if stabilized {
            menu.tap()
            checkStabilizationHelp(in: app, control: stabilization)
            close.tap()
        }
        zoom.tap()
        app.buttons["recorder.zoom.preset.20"].doubleTap()
        wait(zoom, NSPredicate(format: "value == '2.0'")); zoom.tap()
        shot("Front 2x before follow")
        toggle()
        record.tap(); wait(record, NSPredicate(format: "label == 'Stop recording'"))
        Thread.sleep(forTimeInterval: 1.3)
        shot("Front 2x following")
        let assisted = (preview.value as? String ?? "").split(separator: " ")
        toggle(); Thread.sleep(forTimeInterval: 1.3)
        shot("Front 2x following off")
        let unassisted = (preview.value as? String ?? "").split(separator: " ")
        record.tap(); wait(record, NSPredicate(format: "label == 'Record into this project' AND enabled == true"))
        XCTAssertEqual(zoom.value as? String, "2.0")
        XCTAssertEqual(assisted.count, 7); XCTAssertEqual(unassisted.count, 7)
        let cameraZoom = try XCTUnwrap(Double(unassisted[1]))
        XCTAssertGreaterThan(cameraZoom, 1.3)
        XCTAssertEqual(try XCTUnwrap(Double(assisted[1])), 1, accuracy: 0.035, "The tracker needs the full lens view at 2×")
        XCTAssertEqual(try XCTUnwrap(Double(assisted[3])), 1 / cameraZoom, accuracy: 0.025, "Use the selected zoom as pan room")
        XCTAssertEqual(try XCTUnwrap(Double(unassisted[3])), 1, accuracy: 0.002)
        toggle()
        zoom.tap()
        let three = app.buttons["recorder.zoom.preset.30"]
        if three.exists && three.isHittable {
            three.doubleTap(); wait(zoom, NSPredicate(format: "value == '3.0'"))
            wait(preview, NSPredicate(format: "value BEGINSWITH 'camera 1.000'"))
            app.buttons["recorder.zoom.preset.20"].doubleTap()
            wait(zoom, NSPredicate(format: "value == '2.0'"))
        }
        zoom.tap()
        let lens = app.buttons["recorder.camera"]
        app.buttons["recorder.flip"].tap(); wait(lens, NSPredicate(format: "value BEGINSWITH 'Rear' AND enabled == true"))
        app.buttons["recorder.flip"].tap(); wait(lens, NSPredicate(format: "value BEGINSWITH 'Front' AND enabled == true"))
        wait(zoom, NSPredicate(format: "value == '2.0'"))
        wait(preview, NSPredicate(format: "value BEGINSWITH 'camera 1.000'"))
        toggle()
    }

    func testAssistsFollowCameraModeAndFrontPreview() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--dual-capture-ui-test"]
        app.launch()
        let menu = app.buttons["recorder.settings"], close = app.buttons["recorder.settingsDone"]
        let follow = app.descendants(matching: .any)["recorder.dualFaceFollow"]
        let stabilize = app.descendants(matching: .any)["recorder.dualStabilization"]
        let two = app.switches["recorder.dualEnabled"], camera = app.buttons["recorder.camera"]
        let record = app.buttons["recorder.record"]
        func wait(_ element: XCUIElement, _ predicate: NSPredicate) {
            expectation(for: predicate, evaluatedWith: element); waitForExpectations(timeout: 20)
        }
        func shoot(_ name: String) {
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        XCTAssertTrue(menu.waitForExistence(timeout: 20)); wait(menu, NSPredicate(format: "enabled == true"))
        menu.tap(); app.buttons["recorder.color.sdr"].tap()
        wait(app.buttons["recorder.color.sdr"], NSPredicate(format: "selected == true"))
        expandCameraSheet(in: app)
        let quality = app.buttons["recorder.quality"]
        for _ in 0..<7 { if quality.exists && quality.isHittable { break }; app.swipeUp() }
        quality.tap(); app.buttons["1080p · 30 fps"].tap(); app.buttons["recorder.settingsDone"].tap()
        menu.tap()
        if follow.value as? String != "On" { follow.tap() }
        if stabilize.value as? String != "On" { stabilize.tap() }
        two.tap(); wait(two, NSPredicate(format: "value == '1' AND enabled == true"))
        XCTAssertEqual(follow.value as? String, "On"); XCTAssertEqual(stabilize.value as? String, "On")
        two.tap(); wait(two, NSPredicate(format: "value == '0' AND enabled == true"))
        XCTAssertEqual(follow.value as? String, "On"); XCTAssertEqual(stabilize.value as? String, "On")
        close.tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        wait(app, NSPredicate { _, _ in app.frame.width > app.frame.height })
        app.buttons["recorder.flip"].tap(); wait(camera, NSPredicate(format: "value BEGINSWITH 'Front' AND enabled == true"))
        print("Landscape preview bounds", app.otherElements["recorder.preview"].frame, "window", app.frame)
        shoot("Front landscape with both assists")
        record.tap(); wait(record, NSPredicate(format: "label == 'Stop recording'"))
        shoot("Front landscape recording with both assists")
        app.buttons["recorder.flip"].tap(); wait(camera, NSPredicate(format: "value BEGINSWITH 'Rear' AND enabled == true"))
        wait(record, NSPredicate(format: "label == 'Stop recording'"))
        shoot("Rear landscape after assisted recording switch")
        XCTAssertFalse(app.buttons["Dismiss warning"].exists)
        record.tap(); wait(record, NSPredicate(format: "label == 'Record into this project' AND enabled == true"))
        menu.tap(); follow.tap(); stabilize.tap(); close.tap()
    }
    #endif
    private func dualAssist(physical: Bool) throws {
        continueAfterFailure = false; recorderReturnToPortrait = true
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = [physical ? "--dual-capture-ui-test" : "--recorder-controls-test"]; app.launch()
        let dual = app.buttons["recorder.settings"], record = app.buttons["recorder.record"]
        XCTAssertTrue(dual.waitForExistence(timeout: 25))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: dual); waitForExpectations(timeout: 20)
        setDualMode(true, in: app); dual.tap()
        let stabilize = app.descendants(matching: .any)["recorder.dualStabilization"], follow = app.descendants(matching: .any)["recorder.dualFaceFollow"]
        XCTAssertTrue(stabilize.isHittable); XCTAssertTrue(follow.isHittable)
        if stabilize.value as? String != "On" { stabilize.tap() }
        expectation(for: NSPredicate(format: "enabled == true AND value == 'On'"), evaluatedWith: stabilize); waitForExpectations(timeout: 20)
        if follow.value as? String != "On" { follow.tap() }
        XCTAssertEqual(follow.value as? String, "On")
        XCTAssertFalse(app.staticTexts["Both cameras stabilized"].exists)
        follow.press(forDuration: 0.7)
        XCTAssertTrue(app.alerts["Camera assist"].waitForExistence(timeout: 3)); app.alerts.buttons["OK"].tap()
        XCTAssertEqual(follow.value as? String, "On", "Long press explains without toggling")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Dual assist portrait"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["recorder.settingsDone"].tap()
        app.buttons["recorder.dualLayout"].tap(); app.buttons["recorder.layout.sideBySide"].tap(); app.buttons["Done"].tap()
        record.tap(); expectation(for: NSPredicate(format: "label == 'Stop recording'"), evaluatedWith: record); waitForExpectations(timeout: 20)
        dual.tap(); XCTAssertFalse(stabilize.isEnabled); XCTAssertTrue(follow.isEnabled)
        follow.tap(); XCTAssertEqual(follow.value as? String, "Off"); follow.tap(); XCTAssertEqual(follow.value as? String, "On")
        app.buttons["recorder.settingsDone"].tap()
        try twoFingerGesture(in: app.otherElements["recorder.dualPicture.0"], dx: 0, dy: 0, scale: 1.3)
        dual.tap(); XCTAssertEqual(follow.value as? String, "On", "Zoom keeps face following enabled")
        app.buttons["recorder.settingsDone"].tap()
        let picture = app.otherElements["recorder.dualPicture.0"]
        let before = (picture.value as? String ?? "").split(separator: " ")
        try twoFingerGesture(in: picture, dx: 25, dy: 0, scale: 1.2)
        let after = (picture.value as? String ?? "").split(separator: " ")
        XCTAssertEqual(before.count, 6); XCTAssertEqual(after.count, 6)
        XCTAssertNotEqual(before[1], after[1], "A combined gesture pans the picture")
        XCTAssertGreaterThan(try XCTUnwrap(Double(after[5])), try XCTUnwrap(Double(before[5])), "A combined gesture also changes zoom")
        dual.tap(); XCTAssertEqual(follow.value as? String, "Off", "Manual pan stops face following")
        app.buttons["recorder.settingsDone"].tap()
        app.buttons["Pause recording"].tap()
        expectation(for: NSPredicate(format: "label == 'Resume recording' AND enabled == true"), evaluatedWith: record); waitForExpectations(timeout: 25)
        dual.tap(); XCTAssertTrue(stabilize.isEnabled); stabilize.tap()
        expectation(for: NSPredicate(format: "enabled == true AND value == 'Off'"), evaluatedWith: stabilize); waitForExpectations(timeout: 20)
        app.buttons["recorder.settingsDone"].tap(); record.tap()
        expectation(for: NSPredicate(format: "label == 'Stop recording'"), evaluatedWith: record); waitForExpectations(timeout: 20)
        record.tap(); expectation(for: NSPredicate(format: "label == 'Record into this project' AND enabled == true"), evaluatedWith: record); waitForExpectations(timeout: 25)
        XCUIDevice.shared.orientation = .landscapeRight
        expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height && dual.isHittable }, evaluatedWith: app); waitForExpectations(timeout: 10)
        dual.tap()
        XCTAssertTrue(stabilize.isHittable); XCTAssertTrue(follow.isHittable)
        let wide = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); wide.name = "Dual assist landscape"; wide.lifetime = .keepAlways; add(wide)
        app.buttons["recorder.settingsDone"].tap(); setDualMode(false, in: app)
    }
    func testDualInsetShapeSimulator() throws { try dualInsetShape(physical: false) }

    func testDualInsetCanvasLimitsPhysical() throws {
        continueAfterFailure = true; recorderReturnToPortrait = true
        for landscape in [false, true] {
            XCUIDevice.shared.orientation = landscape ? .landscapeRight : .portrait
            let app = try launchDualLayoutRecorder(physical: true)
            let record = app.buttons["recorder.record"]
            XCTAssertTrue(app.buttons["recorder.settings"].waitForExistence(timeout: 25))
            setDualMode(true, in: app)
            app.buttons["recorder.dualLayout"].tap(); app.buttons["recorder.layout.floating"].tap()
            let inset = app.otherElements["recorder.dualPicture.1"]
            inset.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: landscape ? 0.65 : 0.58)))
            for round in [false, true] {
                app.buttons["recorder.insetShape." + (round ? "circle" : "rectangle")].tap()
                // Start inside the inset and spread along a diagonal to retain its shape.
                for _ in 0..<3 { try twoFingerGesture(in: inset, dx: 0, dy: 0, scale: 2, separation: CGVector(dx: 55, dy: 55), centerFraction: CGPoint(x: 0.5, y: 0.55)) }
                record.tap(); expectation(for: NSPredicate(format: "label == 'Stop recording'"), evaluatedWith: record); waitForExpectations(timeout: 20)
                let expandedWidth = inset.frame.width
                try twoFingerGesture(in: inset, dx: 0, dy: 0, scale: 0.8, separation: CGVector(dx: 70, dy: 70), centerFraction: CGPoint(x: 0.5, y: 0.55))
                XCTAssertLessThan(inset.frame.width, expandedWidth*0.95, "Shrink works immediately at the limit, including while recording")
                try twoFingerGesture(in: inset, dx: 0, dy: 0, scale: 2, separation: CGVector(dx: 55, dy: 55), centerFraction: CGPoint(x: 0.5, y: 0.55))
                Thread.sleep(forTimeInterval: 1)
                let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "\(landscape ? "Landscape" : "Portrait") \(round ? "circle" : "square") at canvas limit"; shot.lifetime = .keepAlways; add(shot)
                record.tap(); expectation(for: NSPredicate(format: "label == 'Record into this project' AND enabled == true"), evaluatedWith: record); waitForExpectations(timeout: 25)
                let canvas = app.otherElements["recorder.dualPicture.0"].frame
                XCTAssertEqual(inset.frame.width, min(canvas.width, canvas.height), accuracy: 2, "PiP reaches the canvas edge")
                XCTAssertEqual(inset.frame.width, inset.frame.height, accuracy: 2, "Proportional pinch preserves the shape")
            }
            app.buttons["recorder.insetShape.rectangle"].tap()
            for _ in 0..<3 {
                try twoFingerGesture(in: inset, dx: 0, dy: 0, scale: 2, separation: landscape ? CGVector(dx: 55, dy: 0) : CGVector(dx: 0, dy: 55), centerFraction: CGPoint(x: 0.5, y: 0.55))
            }
            let canvas = app.otherElements["recorder.dualPicture.0"].frame
            XCTAssertEqual(inset.frame.width, canvas.width, accuracy: 2)
            XCTAssertEqual(inset.frame.height, canvas.height, accuracy: 2)
            record.tap(); expectation(for: NSPredicate(format: "label == 'Stop recording'"), evaluatedWith: record); waitForExpectations(timeout: 20)
            Thread.sleep(forTimeInterval: 1)
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "\(landscape ? "Landscape" : "Portrait") full-canvas rectangle"; shot.lifetime = .keepAlways; add(shot)
            record.tap(); expectation(for: NSPredicate(format: "label == 'Record into this project' AND enabled == true"), evaluatedWith: record); waitForExpectations(timeout: 25)
            app.buttons["Done"].tap(); setDualMode(false, in: app)
        }
    }
    func testDualNewShapesPhysical() throws { try dualNewShapes(physical: true) }
    func testDualNewShapesSimulator() throws { try dualNewShapes(physical: false) }
    private func dualNewShapes(physical: Bool) throws {
        continueAfterFailure = false; recorderReturnToPortrait = !physical
        XCUIDevice.shared.orientation = .portrait
        let app = try launchDualLayoutRecorder(physical: physical)
        let dual = app.buttons["recorder.settings"], record = app.buttons["recorder.record"]
        XCTAssertTrue(dual.waitForExistence(timeout: 25))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: dual); waitForExpectations(timeout: 20)
        setDualMode(true, in: app); app.buttons["recorder.dualLayout"].tap()
        app.buttons["recorder.layout.diagonal"].tap()
        let flip = app.buttons["recorder.diagonalFlip"]
        XCTAssertEqual(flip.value as? String, "Top right to bottom left")
        flip.tap(); XCTAssertEqual(flip.value as? String, "Top left to bottom right")
        flip.tap(); XCTAssertEqual(flip.value as? String, "Top right to bottom left")
        flip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.7)))
        XCTAssertEqual(flip.value as? String, "Top right to bottom left", "Divider cannot be dragged")
        let upper = app.otherElements["recorder.dualPicture.0"], lower = app.otherElements["recorder.dualPicture.1"]
        let beforeUpper = upper.value as? String, beforeLower = lower.value as? String
        try twoFingerGesture(in: upper, dx: 0, dy: 0, scale: 1.4, separation: CGVector(dx: 45, dy: 0), centerFraction: CGPoint(x: 0.25, y: 0.38))
        XCTAssertNotEqual(upper.value as? String, beforeUpper); XCTAssertEqual(lower.value as? String, beforeLower)
        let afterUpper = upper.value as? String
        try twoFingerGesture(in: lower, dx: 0, dy: 0, scale: 1.4, separation: CGVector(dx: 45, dy: 0), centerFraction: CGPoint(x: 0.72, y: 0.72))
        XCTAssertNotEqual(lower.value as? String, beforeLower); XCTAssertEqual(upper.value as? String, afterUpper)
        record.tap(); expectation(for: NSPredicate(format: "label == 'Stop recording'"), evaluatedWith: record); waitForExpectations(timeout: 20)
        flip.tap(); app.buttons["recorder.dualSwap"].tap()
        var shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Diagonal portrait recording"; shot.lifetime = .keepAlways; add(shot)
        record.tap(); expectation(for: NSPredicate(format: "label == 'Record into this project' AND enabled == true"), evaluatedWith: record); waitForExpectations(timeout: 25)
        app.buttons["recorder.layout.floating"].tap()
        app.buttons["recorder.insetShape.circle"].tap()
        let inset = app.otherElements["recorder.dualPicture.1"]
        // Move away from the layout toolbar before testing the inset pinch.
        inset.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.63)))
        let circle = inset.frame
        XCTAssertEqual(circle.width, circle.height, accuracy: 1)
        try twoFingerGesture(in: inset, dx: 0, dy: 0, scale: 1.4, separation: CGVector(dx: 45, dy: 0), centerFraction: CGPoint(x: 0.5, y: 0.5))
        XCTAssertGreaterThan(inset.frame.width, circle.width*1.15)
        XCTAssertEqual(inset.frame.width, inset.frame.height, accuracy: 1)
        try twoFingerGesture(in: inset, dx: 0, dy: 0, scale: 0.8, separation: CGVector(dx: 0, dy: 45), centerFraction: CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(inset.frame.width, inset.frame.height, accuracy: 1)
        record.tap(); expectation(for: NSPredicate(format: "label == 'Stop recording'"), evaluatedWith: record); waitForExpectations(timeout: 20)
        shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Circle portrait recording"; shot.lifetime = .keepAlways; add(shot)
        record.tap(); expectation(for: NSPredicate(format: "label == 'Record into this project' AND enabled == true"), evaluatedWith: record); waitForExpectations(timeout: 25)
        app.buttons["Done"].tap()
        XCUIDevice.shared.orientation = .landscapeRight
        app.buttons["recorder.dualLayout"].tap()
        XCTAssertEqual(inset.frame.width, inset.frame.height, accuracy: 1)
        shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Circle landscape"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["recorder.layout.diagonal"].tap(); flip.tap()
        shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Diagonal landscape"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["recorder.layout.floating"].tap(); app.buttons["recorder.insetShape.rectangle"].tap()
        XCTAssertTrue(app.buttons["recorder.insetShape.circle"].isHittable)
        app.buttons["Done"].tap(); setDualMode(false, in: app)
    }
    private func dualInsetShape(physical: Bool) throws {
        continueAfterFailure = false; recorderReturnToPortrait = true
        XCUIDevice.shared.orientation = .portrait
        let app = try launchDualLayoutRecorder(physical: physical)
        let dual = app.buttons["recorder.settings"], record = app.buttons["recorder.record"]
        XCTAssertTrue(dual.waitForExistence(timeout: 25))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: dual); waitForExpectations(timeout: 20)
        setDualMode(true, in: app); app.buttons["recorder.dualLayout"].tap()
        app.buttons["recorder.layout.floating"].tap()
        let inset = app.otherElements["recorder.dualPicture.1"]
        let square = inset.frame
        let center = CGPoint(x: 0.5, y: 0.5)
        try twoFingerGesture(in: inset, dx: 0, dy: 0, scale: 1.4,
                             separation: CGVector(dx: min(70, square.width * 0.7), dy: 0), centerFraction: center)
        let wide = inset.frame
        XCTAssertGreaterThan(wide.width, square.width*1.2); XCTAssertEqual(wide.height, square.height, accuracy: 2)
        try twoFingerGesture(in: inset, dx: 0, dy: 0, scale: 0.6,
                             separation: CGVector(dx: 0, dy: min(70, wide.height * 0.7)), centerFraction: center)
        let short = inset.frame
        XCTAssertEqual(short.width, wide.width, accuracy: 2); XCTAssertLessThan(short.height, wide.height*0.9)
        record.tap(); expectation(for: NSPredicate(format: "label == 'Stop recording'"), evaluatedWith: record); waitForExpectations(timeout: 20)
        let span = min(40, min(short.width, short.height) * 0.7)
        try twoFingerGesture(in: inset, dx: 0, dy: 0, scale: 1.4,
                             separation: CGVector(dx: span, dy: span), centerFraction: center)
        let resized = inset.frame
        XCTAssertGreaterThan(resized.width, short.width*1.1)
        XCTAssertEqual(resized.width/resized.height, short.width/short.height, accuracy: 0.03)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Rectangular inset recording"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["recorder.dualSwap"].tap()
        XCTAssertEqual(inset.frame.width, resized.width, accuracy: 2); XCTAssertEqual(inset.frame.height, resized.height, accuracy: 2)
        record.tap(); expectation(for: NSPredicate(format: "label == 'Record into this project' AND enabled == true"), evaluatedWith: record); waitForExpectations(timeout: 25)
        app.buttons["Done"].tap(); setDualMode(false, in: app)
    }

    private func dualCameraControls(physical: Bool, portrait: Bool = false) throws {
        recorderReturnToPortrait = !physical || portrait
        continueAfterFailure = false
        XCUIDevice.shared.orientation = portrait ? .portrait : .landscapeRight
        let app = try launchDualLayoutRecorder(physical: physical)
        let camera = app.buttons["recorder.camera"], record = app.buttons["recorder.record"]
        XCTAssertTrue(camera.waitForExistence(timeout: 25))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: camera); waitForExpectations(timeout: 20)
        // XCTest can launch a new app in portrait after the simulator was
        // turned on the Home Screen. Exercise the requested layout in-app.
        if !portrait && app.windows.firstMatch.frame.width < app.windows.firstMatch.frame.height {
            XCUIDevice.shared.orientation = .portrait
            XCUIDevice.shared.orientation = .landscapeRight
            expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: app)
            waitForExpectations(timeout: 8)
        }
        setDualMode(true, in: app)
        let swap = app.buttons["recorder.dualSwap"]
        XCTAssertTrue(swap.waitForExistence(timeout: 20), app.debugDescription)
        let side = app.buttons["recorder.layout.sideBySide"]
        if !side.exists { app.buttons["recorder.dualLayout"].tap() }
        XCTAssertTrue(side.waitForExistence(timeout: 5)); side.tap()
        XCTAssertFalse(app.buttons["Reset layout"].exists)
        let divider = app.images["recorder.divider"].exists ? app.images["recorder.divider"] : app.otherElements["recorder.divider"]
        XCTAssertTrue(divider.waitForExistence(timeout: 5))
        let start = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 55, dy: 0)))
        XCTAssertNotEqual(divider.value as? String, "50 percent")
        let picture = app.otherElements["recorder.dualPicture.0"]
        picture.pinch(withScale: 1.3, velocity: 1)
        XCTAssertFalse((picture.value as? String ?? "").hasSuffix("zoom 1.000"))
        let otherPicture = app.otherElements["recorder.dualPicture.1"]
        let firstFraming = try XCTUnwrap(picture.value as? String)
        let secondFraming = try XCTUnwrap(otherPicture.value as? String)
        XCTAssertNotEqual(firstFraming, secondFraming)
        swap.tap()
        XCTAssertEqual(picture.value as? String, secondFraming)
        XCTAssertEqual(otherPicture.value as? String, firstFraming)
        swap.tap()
        XCTAssertEqual(picture.value as? String, firstFraming)
        XCTAssertEqual(otherPicture.value as? String, secondFraming)
        if portrait {
            let beforePan = picture.value as? String
            try twoFingerGesture(in: picture, dx: 38, dy: 0)
            XCTAssertNotEqual(picture.value as? String, beforePan, "Two-finger pan changes framing through real touch delivery")
        }
        // Keep both fingers inside the picture and clear of the recorder controls.
        try twoFingerGesture(in: picture, dx: 0, dy: 0, scale: 0.15)
        XCTAssertTrue((picture.value as? String ?? "").hasSuffix("zoom 1.000"), "Zoom out stops at aspect fill: \(picture.value ?? "missing")")
        record.tap(); expectation(for: NSPredicate(format: "label == 'Stop recording'"), evaluatedWith: record); waitForExpectations(timeout: 20)
        let recordedFrame = app.windows.firstMatch.frame
        XCUIDevice.shared.orientation = portrait ? .landscapeRight : .portrait
        XCTAssertEqual(app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height, recordedFrame.width > recordedFrame.height, "Active take keeps its orientation")
        swap.tap()
        let top = app.buttons["recorder.layout.topAndBottom"]; top.tap()
        let topShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); topShot.name = "Two cameras top and bottom"; topShot.lifetime = .keepAlways; add(topShot)
        app.buttons["recorder.layout.floating"].tap()
        let inset = app.otherElements["recorder.dualPicture.1"]
        let old = inset.frame
        let insetCenter = inset.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        insetCenter.press(forDuration: 0.1, thenDragTo: insetCenter.withOffset(CGVector(dx: -35, dy: 35)))
        XCTAssertNotEqual(inset.frame, old)
        if portrait {
            let span = min(inset.frame.width, inset.frame.height) * 0.5
            try twoFingerGesture(in: inset, dx: 0, dy: 0, scale: 1.4,
                                 separation: CGVector(dx: span, dy: span), centerFraction: CGPoint(x: 0.5, y: 0.5))
        }
        else { inset.pinch(withScale: 1.4, velocity: 1) }
        XCTAssertGreaterThan(inset.frame.width*inset.frame.height, old.width*old.height)
        app.buttons["Done"].tap()
        app.buttons["recorder.microphone"].tap()
        let gain = app.sliders["recorder.gain"]
        XCTAssertTrue(gain.waitForExistence(timeout: 5)); gain.adjust(toNormalizedSliderPosition: 1)
        XCTAssertTrue(app.staticTexts["recorder.gainValue"].label.replacingOccurrences(of: ",", with: ".").contains("12.0"))
        dragRecordingGainToZero(gain, fromUpperEnd: true)
        XCTAssertTrue(app.staticTexts["recorder.gainValue"].label.replacingOccurrences(of: ",", with: ".").contains("0.0"))
        if !physical {
            app.buttons["recorder.gainMicrophone"].tap()
            app.buttons["Wireless test mic"].tap()
            XCTAssertTrue(app.buttons["recorder.gainMicrophone"].label.contains("Wireless test mic"))
        }

        app.buttons["recorder.audioDone"].tap()
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Two cameras floating while recording"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["Pause recording"].tap()
        expectation(for: NSPredicate(format: "label == 'Resume recording'"), evaluatedWith: record); waitForExpectations(timeout: 20)
        record.tap(); expectation(for: NSPredicate(format: "label == 'Stop recording'"), evaluatedWith: record); waitForExpectations(timeout: 20)
        record.tap(); expectation(for: NSPredicate(format: "label == 'Record into this project' AND enabled == true"), evaluatedWith: record); waitForExpectations(timeout: 30)
        if physical {
            XCUIDevice.shared.press(.home)
            Thread.sleep(forTimeInterval: 4)
            app.activate()
            expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: record); waitForExpectations(timeout: 15)
            record.tap(); expectation(for: NSPredicate(format: "label == 'Stop recording'"), evaluatedWith: record); waitForExpectations(timeout: 20)
            record.tap(); expectation(for: NSPredicate(format: "label == 'Record into this project' AND enabled == true"), evaluatedWith: record); waitForExpectations(timeout: 20)
            XCTAssertFalse(app.staticTexts["Two-camera preview is unavailable. Pause and choose the cameras again."].exists)
        }
        setDualMode(false, in: app)
        XCTAssertTrue(app.buttons["recorder.flip"].waitForExistence(timeout: 20))
        XCUIDevice.shared.orientation = physical && !portrait ? .landscapeRight : .portrait
    }

    private func twoFingerGesture(in element: XCUIElement, dx: CGFloat, dy: CGFloat, scale: CGFloat = 1, separation: CGVector = CGVector(dx: 0, dy: 100), centerFraction: CGPoint = CGPoint(x: 0.5, y: 0.62), hold: Double = 0, releaseScale: CGFloat? = nil, beforeSynthesis: (() -> Void)? = nil) throws {
        func instance(_ name: String) throws -> AnyObject {
            let type = try XCTUnwrap(NSClassFromString(name)); return try XCTUnwrap(class_createInstance(type, 0)) as AnyObject
        }
        func implementation(_ object: AnyObject, _ name: String) throws -> IMP {
            let method = try XCTUnwrap(class_getInstanceMethod(object_getClass(object), NSSelectorFromString(name)))
            return method_getImplementation(method)
        }
        let event = try instance("XCSynthesizedEventRecord")
        typealias InitEvent = @convention(c) (AnyObject, Selector, NSString, Int) -> Unmanaged<AnyObject>
        // The low-level synthesizer takes portrait screen coordinates, whereas
        // XCUI element frames follow the current interface orientation.
        let screen = XCUIApplication().windows.firstMatch.frame.size
        // Recording can hold the interface in portrait after the handset rotates.
        let orientation = screen.height > screen.width ? UIDeviceOrientation.portrait : XCUIDevice.shared.orientation
        func screenPoint(_ point: CGPoint) -> CGPoint {
            switch orientation {
            case .landscapeRight: return CGPoint(x: point.y, y: screen.width-point.x)
            case .landscapeLeft: return CGPoint(x: screen.height-point.y, y: point.x)
            case .portraitUpsideDown: return CGPoint(x: screen.width-point.x, y: screen.height-point.y)
            default: return point
            }
        }
        _ = try unsafeBitCast(implementation(event, "initWithName:interfaceOrientation:"), to: InitEvent.self)(event, NSSelectorFromString("initWithName:interfaceOrientation:"), "Two-finger pan", 1)
        let center = CGPoint(x: element.frame.minX + element.frame.width*centerFraction.x, y: element.frame.minY + element.frame.height*centerFraction.y)
        for side in [-0.5, 0.5] {
            let x = separation.dx * side, y = separation.dy * side
            let path = try instance("XCPointerEventPath"), start = CGPoint(x: center.x+x, y: center.y+y)
            typealias PointCall = @convention(c) (AnyObject, Selector, CGPoint, Double) -> Void
            typealias InitPath = @convention(c) (AnyObject, Selector, CGPoint, Double) -> Unmanaged<AnyObject>
            _ = try unsafeBitCast(implementation(path, "initForTouchAtPoint:offset:"), to: InitPath.self)(path, NSSelectorFromString("initForTouchAtPoint:offset:"), screenPoint(start), 0)
            let move = try unsafeBitCast(implementation(path, "moveToPoint:atOffset:"), to: PointCall.self)
            move(path, NSSelectorFromString("moveToPoint:atOffset:"), screenPoint(start), 0.1)
            for step in 1...12 { move(path, NSSelectorFromString("moveToPoint:atOffset:"), screenPoint(CGPoint(x: start.x+(dx+x*(scale-1))*CGFloat(step)/12, y: start.y+(dy+y*(scale-1))*CGFloat(step)/12)), 0.1+Double(step)*0.04) }
            if let releaseScale {
                let last = CGPoint(x: center.x + dx + x * releaseScale, y: center.y + dy + y * releaseScale)
                move(path, NSSelectorFromString("moveToPoint:atOffset:"), screenPoint(last), 0.62)
            }
            typealias Lift = @convention(c) (AnyObject, Selector, Double) -> Void
            try unsafeBitCast(implementation(path, "liftUpAtOffset:"), to: Lift.self)(path, NSSelectorFromString("liftUpAtOffset:"), 0.65 + hold)
            typealias Add = @convention(c) (AnyObject, Selector, AnyObject) -> Void
            try unsafeBitCast(implementation(event, "addPointerEventPath:"), to: Add.self)(event, NSSelectorFromString("addPointerEventPath:"), path)
        }
        typealias Synthesize = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>) -> Bool
        var error: NSError?
        beforeSynthesis?()
        let success = try unsafeBitCast(implementation(event, "synthesizeWithError:"), to: Synthesize.self)(event, NSSelectorFromString("synthesizeWithError:"), &error)
        XCTAssertTrue(success, error?.description ?? "Two-finger event failed")
    }

    func testReviewRangeToolThenDeleteAndAudioOnlySplit() throws {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--multiselect-fixture"]; app.launch()
        let play = app.buttons["Play"]
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 45)
        func frame(_ id: String) throws -> Int {
            let clock = app.staticTexts[id].label.split(separator: ":")
            let minutes = try XCTUnwrap(clock.first.flatMap { Int($0) })
            let seconds = try XCTUnwrap(clock.last.flatMap { Double($0) })
            return minutes * 60 * 30 + Int((seconds * 30).rounded())
        }
        seekTimeline(fraction: 2.0/18, in: app); app.buttons["Mark start"].tap()
        let startFrame = try frame("editor.playhead")
        seekTimeline(fraction: 8.0/18, in: app); app.buttons["Mark end"].tap()
        let endFrame = try frame("editor.playhead")
        XCTAssertGreaterThan(endFrame, startFrame)
        openTool("color", in: app); app.buttons["tool.look.warm"].tap(); waitForTool(app); app.buttons["tool.apply"].tap()
        let delete = app.buttons["Delete selection"]
        XCTAssertTrue(delete.waitForExistence(timeout: 20)); delete.tap()
        XCTAssertEqual(try frame("editor.duration"), 18 * 30 - (endFrame - startFrame), "Delete removes exactly the frames marked on screen")
        app.buttons["Undo"].tap(); XCTAssertEqual(app.staticTexts["editor.duration"].label, "0:18.00")
        app.buttons["Undo"].tap()
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 45)
        app.buttons["timeline.audio.2"].tap(); app.buttons["Unlink"].tap()
        app.buttons["editor.clearSelection"].tap(); app.buttons["timeline.audio.2"].tap()
        seekTimeline(fraction: 7.0/18, in: app)
        let position = app.staticTexts["editor.playhead"].label
        app.buttons["Split"].tap()
        XCTAssertEqual(app.staticTexts["editor.playhead"].label, position, "Audio-only Split must stay at the split")
        XCTAssertEqual(app.staticTexts["editor.duration"].label, "0:18.00")
        XCTAssertTrue(app.buttons["timeline.audio.4"].exists)
        XCTAssertFalse(app.buttons["timeline.video.4"].exists, "The detached picture stays in one piece")
        XCTAssertFalse(app.buttons["editor.clearSelection"].exists)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Review fixes: retained range and audio split"; shot.lifetime = .keepAlways; add(shot)
    }

    func testReviewInvalidRecipeRecoveryDoesNotRepeat() throws { try reviewRecovery(invalidRecipe: true) }
    func testExplicitUnsavedEditAndRetry() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["YOUREC_RECOVERY_TEST_RUN"] = UUID().uuidString
        app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--recovery-save-fault"]
        app.launchEnvironment["YOUREC_EDITOR_FIXTURE_TITLE"] = "Save failure QA"
        app.launch()
        let play = app.buttons["Play"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 40)
        seekTimeline(fraction: 0.35, in: app)
        app.buttons["Split"].tap()
        let alert = app.alerts["YouRec"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        alert.buttons["OK"].tap()
        XCTAssertTrue(app.buttons["Retry save"].waitForExistence(timeout: 5))
        app.buttons["Retry save"].tap()
        XCTAssertTrue(app.buttons["Retry save"].waitForNonExistence(timeout: 10))
        app.terminate()
        app.launchArguments = ["--editor-preview"]; app.launch()
        let undo = app.buttons["Undo"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: undo); waitForExpectations(timeout: 30)
        undo.tap()
        XCTAssertTrue(app.buttons["Redo"].isEnabled)
    }
    func testOpenOriginalsWithoutProjectIndex() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["YOUREC_RECOVERY_TEST_RUN"] = UUID().uuidString
        app.launchArguments = ["--editor-preview", "--recovery-originals-fixture"]
        app.launch()
        let browser = app.buttons["Back to projects"]
        XCTAssertTrue(browser.waitForExistence(timeout: 30)); browser.tap()
        let open = app.buttons["recovery.originals.134DFF48-A310-4C9B-AB49-E0F6FBDF8292"]
        for _ in 0..<40 where !open.isHittable { app.swipeUp(velocity: .fast) }
        XCTAssertTrue(open.exists); open.tap()
        XCTAssertTrue(app.buttons["Save original Original QA interview.mp4"].waitForExistence(timeout: 10))
        app.buttons["Create recovered project"].tap()
        let result = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Created'")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 20))
        app.buttons["Done"].firstMatch.tap()
    }
    func testReplacementExportSurvivesFullDisk() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["YOUREC_RECOVERY_TEST_RUN"] = UUID().uuidString
        app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]
        app.launchEnvironment["YOUREC_EDITOR_FIXTURE_TITLE"] = "Full export QA " + UUID().uuidString.prefix(6)
        app.launch()
        let export = app.buttons["Export"]
        XCTAssertTrue(export.waitForExistence(timeout: 30))
        export.tap(); app.buttons["Export video"].tap()
        XCTAssertTrue(app.buttons["Save to Photos"].waitForExistence(timeout: 120))
        app.terminate()
        app.launchArguments = ["--editor-preview", "--recovery-full-export"]; app.launch()
        let play = app.buttons["Play"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 40)
        seekTimeline(fraction: 0.35, in: app); app.buttons["Split"].tap()
        export.tap(); app.buttons["Export video"].tap()
        XCTAssertTrue(app.buttons["Resume export"].waitForExistence(timeout: 90))
        XCTAssertTrue(app.staticTexts["Previous export"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Save previous movie to Photos"].waitForExistence(timeout: 5))
    }
    func testReviewUnfinishedRecordingRecoveryDoesNotRepeat() throws { try reviewRecovery(invalidRecipe: false) }
    private func reviewRecovery(invalidRecipe: Bool) throws {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--broken-recovery-fixture", "--recovery-ui-check"]
        app.launchEnvironment["YOUREC_RECOVERY_TEST_RUN"] = UUID().uuidString
        let name = invalidRecipe ? "Playable sidecar QA" : "Unfinished take QA"
        app.launchEnvironment["YOUREC_EDITOR_FIXTURE_TITLE"] = name
        if invalidRecipe { app.launchArguments.append("--invalid-recipe-recovery-fixture") }
        app.launch()
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 50))
        let notice = app.buttons["Dismiss recovery notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 15))
        notice.tap()
        app.buttons["Back to projects"].tap()
        app.buttons["Actions for " + name].tap()
        if invalidRecipe {
            app.buttons["Original recordings"].tap()
            XCTAssertTrue(app.buttons["Save original 1790000000000-interrupted.mov"].waitForExistence(timeout: 10))
        } else {
            app.buttons["Unfinished recordings"].tap()
            XCTAssertTrue(app.buttons["Save file"].waitForExistence(timeout: 10))
        }
        app.buttons["Done"].firstMatch.tap()
        if !invalidRecipe {
            app.buttons["Actions for " + name].tap()
            app.buttons["Zip project"].tap()
            XCTAssertTrue(app.buttons["Save or share ZIP"].waitForExistence(timeout: 45))
            app.buttons["Done"].firstMatch.tap()
        }
        app.terminate()
        app.launchArguments = ["--editor-preview", "--recovery-ui-check"]; app.launch()
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["Dismiss recovery notice"].exists, "Recovery must run once")
        if invalidRecipe { XCTAssertEqual(app.staticTexts["editor.duration"].label, "0:36.00") }
    }

    func testReviewTransitionInsideHorizontalLink() throws {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--multiselect-fixture"]; app.launch()
        let play = app.buttons["Play"]
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 45)
        app.buttons["Timeline view span"].tap(); app.buttons["Whole project"].tap()
        app.buttons["timeline.video.1"].tap(); app.buttons["timeline.video.2"].press(forDuration: 0.65)
        app.buttons["Link"].tap(); app.buttons["editor.clearSelection"].tap()
        seekTimeline(fraction: 1.0/3, in: app)
        openTimelineTransition(in: app)
        let apply = app.buttons["transition.apply"]
        expectation(for: NSPredicate(format: "exists == true AND enabled == true"), evaluatedWith: apply); waitForExpectations(timeout: 60)
        apply.tap()
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 20))
        XCTAssertEqual(app.staticTexts["editor.duration"].label, "0:17.50")
        XCTAssertFalse(app.alerts["Editor"].exists)
        XCTAssertTrue(app.buttons["timeline.transition.1"].exists)
        app.buttons["Undo"].tap(); XCTAssertEqual(app.staticTexts["editor.duration"].label, "0:18.00")
    }

    func testTimelineControlsAndCompactLabels() throws {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--multiselect-fixture"]; app.launch()
        let timeline = app.otherElements["editor.timeline"], span = app.buttons["Timeline view span"], full = app.buttons["editor.fullPreview"]
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 30))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: app.buttons["Play"]); waitForExpectations(timeout: 30)
        func shot(_ title: String) { let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); image.name = title; image.lifetime = .keepAlways; add(image) }
        for pose in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = pose
            expectation(for: NSPredicate { _,_ in (pose == .portrait) == (app.frame.height > app.frame.width) }, evaluatedWith: app); waitForExpectations(timeout: 10)
            XCTAssertGreaterThanOrEqual(span.frame.width, 44); XCTAssertGreaterThanOrEqual(span.frame.height, 44)
            XCTAssertGreaterThanOrEqual(span.frame.minX, timeline.frame.maxX - 50)
            XCTAssertGreaterThanOrEqual(span.frame.minY, timeline.frame.minY + 20)
            XCTAssertLessThanOrEqual(span.frame.maxY, timeline.frame.minY + 70)
            XCTAssertGreaterThanOrEqual(full.frame.width, 44); XCTAssertGreaterThanOrEqual(full.frame.height, 44)
            XCTAssertFalse(full.frame.intersects(app.buttons["Export"].frame), "Fullscreen must not overlap Export")
            let export = app.buttons["Export"]
            XCTAssertEqual(app.buttons.matching(identifier: "Export").count, 1)
            XCTAssertEqual(export.frame.midY, app.buttons["Split"].frame.midY, accuracy: 1)
            XCTAssertGreaterThanOrEqual(export.frame.minX, app.buttons["Tools"].frame.maxX)
            XCTAssertGreaterThanOrEqual(export.frame.width, 44); XCTAssertGreaterThanOrEqual(export.frame.height, 44)
            export.tap(); XCTAssertTrue(app.buttons["Export video"].waitForExistence(timeout: 5))
            app.buttons["Done"].tap()
            XCTAssertGreaterThanOrEqual(full.frame.minX, app.otherElements["editor.preview"].frame.maxX - 60)
            XCTAssertFalse(app.buttons["editor.bookmarks"].exists)
            XCTAssertFalse(app.staticTexts["Full"].exists); XCTAssertFalse(app.staticTexts["Marks"].exists)
            for (edge, choice) in [(0.08, "10 seconds"), (0.92, "Whole project")] {
                span.coordinate(withNormalizedOffset: CGVector(dx: edge, dy: edge)).tap()
                XCTAssertTrue(app.buttons[choice].waitForExistence(timeout: 5)); app.buttons[choice].tap()
                expectation(for: NSPredicate(format: "value == %@", choice), evaluatedWith: span); waitForExpectations(timeout: 5)
            }
            XCTAssertEqual(app.buttons["timeline.audio.1"].frame.maxY, timeline.frame.maxY, accuracy: 1, "No empty strip below the waveform")
            for direction in ["Previous bookmark", "Next bookmark"] {
                app.buttons[direction].tap(); XCTAssertTrue(app.staticTexts["No marks yet"].waitForExistence(timeout: 5))
                XCTAssertTrue(app.staticTexts["While recording, tap Mark to remember a moment in your video—for example, a mistake to cut or a take to keep."].exists)
                if direction == "Next bookmark" { shot("Bookmark explanation \(pose.rawValue)") }
                app.buttons["Got it"].tap()
            }
            full.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            XCTAssertTrue(app.sliders["Full preview position"].waitForExistence(timeout: 5))
            app.buttons["fullPreview.nextBookmark"].tap(); XCTAssertTrue(app.staticTexts["No marks yet"].waitForExistence(timeout: 5))
            app.buttons["Got it"].tap(); app.buttons["Done"].tap()
            shot("Preview and timeline controls \(pose.rawValue)")
        }
        full.tap(); app.sliders["Full preview position"].adjust(toNormalizedSliderPosition: 0.3)
        app.buttons["Bookmarks"].tap(); app.buttons["Add bookmark here"].tap(); app.buttons["Done"].tap()
        let markedTime = app.staticTexts["editor.playhead"].label
        app.buttons["Next change"].tap(); app.buttons["Previous bookmark"].tap()
        XCTAssertEqual(app.staticTexts["editor.playhead"].label, markedTime)
        app.buttons["Previous change"].tap(); app.buttons["Next bookmark"].tap()
        XCTAssertEqual(app.staticTexts["editor.playhead"].label, markedTime)
        XCTAssertFalse(app.staticTexts["No marks yet"].exists)
        app.buttons["timeline.video.2"].tap()
        XCTAssertTrue(app.buttons["timeline.video.2"].isSelected)
        XCTAssertTrue(app.buttons["timeline.audio.2"].isSelected)
    }

    func testReopenProjectWithBackgroundVideo() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--background-position-fixture", "--recovery-ui-check"]
        app.launch()
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.alerts["YouRec"].exists, "Background video must not be recovered as a new recording")
        let duration = app.staticTexts["editor.duration"].label
        app.buttons["Undo"].tap()
        app.terminate(); app.launchArguments = ["--editor-preview", "--recovery-ui-check"]; app.launch()
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.alerts["YouRec"].exists, "An undone background must not become a recording either")
        XCTAssertEqual(app.staticTexts["editor.duration"].label, duration)
        XCTAssertTrue(app.buttons["Redo"].isEnabled)
        app.buttons["Redo"].tap()
        XCTAssertEqual(app.staticTexts["editor.duration"].label, duration)
    }

    func testCompactTransitionJoinSelectionAndHistory() throws {
        continueAfterFailure=false;XCUIDevice.shared.orientation = .portrait
        let app=XCUIApplication();app.launchArguments=["--editor-preview","--reset-ui-fixture","--multiselect-fixture"];app.launch()
        let play=app.buttons["Play"],timeline=app.otherElements["editor.timeline"],marker=app.buttons["timeline.transition.1"]
        func ready() {
            XCTAssertTrue(play.waitForExistence(timeout:30));expectation(for:NSPredicate(format:"enabled == true"),evaluatedWith:play);waitForExpectations(timeout:45)
        }
        func compact() {
            XCTAssertTrue((timeline.value as? String ?? "").contains("1 video lanes, 1 audio lanes"),String(describing:timeline.value))
            for kind in ["video","audio"] {
                let a=app.buttons["timeline.\(kind).1"],b=app.buttons["timeline.\(kind).2"]
                XCTAssertEqual(a.frame.minY,b.frame.minY,accuracy:0.5)
                XCTAssertLessThanOrEqual(a.frame.maxX,b.frame.minX,"Transition cards cannot cover each other")
            }
        }
        func shot(_ title:String) {let image=XCTAttachment(screenshot:XCUIScreen.main.screenshot());image.name=title;image.lifetime = .keepAlways;add(image)}
        ready();app.buttons["Timeline view span"].tap();app.buttons["Whole project"].tap()
        timeline.coordinate(withNormalizedOffset:.zero).withOffset(CGVector(dx:48+(timeline.frame.width-96)/3,dy:10)).tap()
        openTimelineTransition(in: app)
        let apply=app.buttons["transition.apply"]
        XCTAssertTrue(apply.waitForExistence(timeout:30));chooseTransitionDuration("1", in: app)
        expectation(for:NSPredicate(format:"enabled == true"),evaluatedWith:apply);waitForExpectations(timeout:45);apply.tap();ready()
        XCTAssertTrue(marker.waitForExistence(timeout:10));compact()
        XCTAssertEqual(app.staticTexts["editor.duration"].label,"0:17.00")
        app.buttons["timeline.video.1"].tap();app.buttons["Move"].tap()
        XCTAssertTrue((timeline.value as? String ?? "").contains("2 video lanes, 2 audio lanes"),"Move exposes the transition handles")
        app.buttons["Cancel"].tap();ready();compact()
        app.buttons["timeline.video.2"].tap();XCTAssertTrue(app.buttons["timeline.video.2"].isSelected)
        app.buttons["Copy selection"].tap()
        app.buttons["editor.clearSelection"].tap()
        timeline.coordinate(withNormalizedOffset:.zero).withOffset(CGVector(dx:16,dy:10)).tap()
        XCTAssertTrue(app.buttons["editor.paste"].exists,"Paste stays available at a straight boundary")
        app.buttons["timeline.video.2"].tap()
        marker.tap();XCTAssertFalse(app.buttons["timeline.video.2"].isSelected)
        XCTAssertEqual(app.staticTexts["editor.playhead"].label,"0:05.50")
        let chip=app.buttons["editor.transition"]
        XCTAssertTrue(chip.waitForExistence(timeout:5),"The transition control appears even with a populated clipboard")
        XCTAssertFalse(app.buttons["effect.placement"].exists,"A transition alone does not display a default Placement chip")
        XCTAssertGreaterThanOrEqual(chip.frame.minY - timeline.frame.maxY, 5, "Effects have breathing room above")
        XCTAssertGreaterThanOrEqual(app.buttons["Split"].frame.minY - chip.frame.maxY, 5, "Effects do not touch the action row")
        shot("Compact transition join portrait")
        chip.tap();XCTAssertTrue(apply.waitForExistence(timeout:30));chooseTransitionDuration("2", in: app)
        expectation(for:NSPredicate(format:"enabled == true"),evaluatedWith:apply);waitForExpectations(timeout:45);apply.tap();ready();compact()
        XCTAssertEqual(app.staticTexts["editor.duration"].label,"0:16.00")
        app.buttons["Undo"].tap();ready();compact();XCTAssertEqual(app.staticTexts["editor.duration"].label,"0:17.00")
        app.buttons["Redo"].tap();ready();compact();XCTAssertEqual(app.staticTexts["editor.duration"].label,"0:16.00")
        app.terminate();app.launchArguments=["--editor-preview"];app.launch();ready()
        app.buttons["Timeline view span"].tap();app.buttons["Whole project"].tap();compact()
        play.tap();XCTAssertTrue(app.buttons["Pause playback"].waitForExistence(timeout:5));marker.tap()
        XCTAssertTrue(play.waitForExistence(timeout:5));XCTAssertTrue(chip.exists)
        XCTAssertEqual(app.staticTexts["editor.playhead"].label,"0:05.00")
        XCUIDevice.shared.orientation = .landscapeLeft
        expectation(for:NSPredicate {_,_ in app.frame.width>app.frame.height},evaluatedWith:app);waitForExpectations(timeout:10)
        compact();marker.tap();XCTAssertTrue(chip.exists);shot("Compact transition join landscape")
        XCUIDevice.shared.orientation = .portrait
        expectation(for:NSPredicate {_,_ in app.frame.height>app.frame.width},evaluatedWith:app);waitForExpectations(timeout:10)
        marker.tap();chip.press(forDuration:0.7)
        XCTAssertTrue(app.buttons["effect.confirmRemove"].waitForExistence(timeout:5));app.buttons["effect.confirmRemove"].tap();ready()
        XCTAssertFalse(marker.exists)
        compact();XCTAssertEqual(app.staticTexts["editor.duration"].label,"0:18.00","Toolbar removal restores the full straight-cut sequence")
        app.buttons["Undo"].tap();ready();compact();XCTAssertTrue(marker.exists)
    }

    func testTimelineSpanMenuDuringPlayback() throws {
        continueAfterFailure=false;XCUIDevice.shared.orientation = .portrait
        let app=XCUIApplication();app.launchArguments=["--editor-preview","--reset-ui-fixture"];app.launch()
        let play=app.buttons["Play"],span=app.buttons["Timeline view span"],clock=app.staticTexts["editor.playhead"]
        XCTAssertTrue(play.waitForExistence(timeout:30));expectation(for:NSPredicate(format:"enabled == true"),evaluatedWith:play);waitForExpectations(timeout:30)
        play.tap();XCTAssertTrue(app.buttons["Pause playback"].waitForExistence(timeout:5))
        for choice in ["1 second","10 seconds"] {
            span.tap();XCTAssertTrue(app.buttons[choice].waitForExistence(timeout:5))
            let before=clock.label
            expectation(for:NSPredicate(format:"label != %@",before),evaluatedWith:clock);waitForExpectations(timeout:5)
            app.buttons[choice].tap()
            expectation(for:NSPredicate(format:"value == %@",choice),evaluatedWith:span);waitForExpectations(timeout:5)
            XCTAssertTrue(app.buttons["Pause playback"].exists,"Changing span keeps playback running")
        }
        app.buttons["Pause playback"].tap()
    }

    // The host sends SIGKILL. XCTest termination and tapping Stop both give
    // the writer an opportunity to finish, which would invalidate this test.
    func testRecoverExternallyInterruptedCameraTake() throws {
        let env = ProcessInfo.processInfo.environment
        guard let seconds = env["YOUREC_EXTERNAL_KILL_SECONDS"].flatMap(Double.init) else {
            throw XCTSkip("Requires the external device kill controller")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--recorder-controls-test", "--recording-safety-clock", "-captureQuality",
                               env["YOUREC_KILL_QUALITY"] ?? "hd1080", "-captureColorMode", env["YOUREC_KILL_COLOR"] ?? "sdr", "-liveVideoEffects", "<5b5d>"]
        app.launch()
        if env["YOUREC_KILL_DUAL"] == "1" { setDualMode(true, in: app) }
        useEmptyRecordingProject(in: app)
        let record = app.buttons["recorder.record"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: record); waitForExpectations(timeout: 35)
        record.tap()
        expectation(for: NSPredicate(format: "label == 'Stop recording'"), evaluatedWith: record); waitForExpectations(timeout: 20)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Real recording before abrupt termination"; shot.lifetime = .keepAlways; add(shot)
        print("YOUREC_KILL_TEST_ARMED")
        let died = expectation(description: "Recorder killed externally")
        DispatchQueue.global().async {
            let until = Date().addingTimeInterval(seconds + 90)
            while Date() < until {
                if app.state == .notRunning { died.fulfill(); return }
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        wait(for: [died], timeout: seconds + 100)
        app.launch()
        XCTAssertTrue(record.waitForExistence(timeout: 40))
    }

    func testStopRecordingAcceptsWholeButtonArea() throws {
        continueAfterFailure=false;XCUIDevice.shared.orientation = .portrait
        let app=XCUIApplication();app.launchArguments=["--recorder-controls-test"];app.launch()
        let record=app.buttons["recorder.record"]
        XCTAssertTrue(record.waitForExistence(timeout:20));useEmptyRecordingProject(in: app)
        for pose in [UIDeviceOrientation.portrait,.landscapeLeft,.landscapeRight] {
            XCUIDevice.shared.orientation=pose
            expectation(for:NSPredicate {_,_ in (pose == .portrait)==(app.frame.height>app.frame.width)},evaluatedWith:app);waitForExpectations(timeout:10)
            for point in [CGVector(dx:0.2,dy:0.5),CGVector(dx:0.8,dy:0.5),CGVector(dx:0.5,dy:0.2),CGVector(dx:0.5,dy:0.8)] {
                expectation(for:NSPredicate(format:"enabled == true"),evaluatedWith:record);waitForExpectations(timeout:15)
                record.tap();expectation(for:NSPredicate(format:"label == 'Stop recording'"),evaluatedWith:record);waitForExpectations(timeout:15)
                // These points lie between the stop square and its outer ring.
                record.coordinate(withNormalizedOffset:point).tap()
                expectation(for:NSPredicate(format:"label == 'Record into this project' AND enabled == true"),evaluatedWith:record);waitForExpectations(timeout:20)
            }
        }
        XCUIDevice.shared.orientation = .portrait
    }

    func testMuteWholeProjectPreviewAndUndo() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]
        app.launch()
        let volume = app.buttons["audio.quickGain"], mute = app.switches["Mute"]
        func openVolume() {
            XCTAssertTrue(volume.waitForExistence(timeout: 30))
            expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: volume)
            waitForExpectations(timeout: 25)
            volume.tap()
            XCTAssertTrue(mute.waitForExistence(timeout: 10))
            XCTAssertTrue(app.staticTexts["audioTool.scope"].label.hasPrefix("Whole project"))
        }
        openVolume()
        XCTAssertEqual(mute.value as? String, "0")
        mute.tap()
        XCTAssertTrue(app.staticTexts["Selection is silent or muted"].waitForExistence(timeout: 20))
        app.buttons["Play preview"].tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 10))
        app.buttons["Pause"].tap()
        app.buttons["Cancel"].tap()
        openVolume()
        XCTAssertEqual(mute.value as? String, "0", "Cancel must discard the mute")
        mute.tap()
        app.buttons["Apply"].tap()
        openVolume()
        XCTAssertEqual(mute.value as? String, "1")
        mute.tap()
        app.buttons["Apply"].tap()
        XCTAssertTrue(app.buttons["Undo"].waitForExistence(timeout: 10))
        app.buttons["Undo"].tap()
        openVolume()
        XCTAssertEqual(mute.value as? String, "1", "Undo must restore the committed mute")
        app.buttons["Cancel"].tap()
    }

    func testVolumeWithoutSelectionAppliesToWholeProject() throws {
        continueAfterFailure=false;XCUIDevice.shared.orientation = .portrait
        let app=XCUIApplication();app.launchArguments=["--editor-preview","--reset-ui-fixture","--multiselect-fixture"];app.launch()
        let play=app.buttons["Play"],gain=app.buttons["audio.quickGain"],slider=app.sliders["audio.gainSlider"]
        func ready() {XCTAssertTrue(play.waitForExistence(timeout:30));expectation(for:NSPredicate(format:"enabled == true"),evaluatedWith:play);waitForExpectations(timeout:30)}
        func level(_ text:String) {expectation(for:NSPredicate(format:"value BEGINSWITH %@",text),evaluatedWith:gain);waitForExpectations(timeout:20)}
        ready();XCTAssertTrue(gain.isEnabled);level("+0.0 dB")
        gain.tap();XCTAssertTrue(slider.waitForExistence(timeout:20))
        XCTAssertTrue(app.staticTexts["audioTool.scope"].label.hasPrefix("Whole project · All audio"))
        app.buttons["Cancel"].tap()
        app.buttons["Timeline view span"].tap();app.buttons["Whole project"].tap()
        let first=app.buttons["timeline.audio.1"].coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5))
        first.press(forDuration:0.1,thenDragTo:first.withOffset(CGVector(dx:0,dy:-32)))
        level("+4.0 dB");app.buttons["editor.clearSelection"].tap();level("Mixed")
        gain.tap();XCTAssertTrue(slider.waitForExistence(timeout:20));XCTAssertTrue(app.staticTexts["Mixed levels"].exists)
        app.buttons["Apply"].tap();level("Mixed") // No chosen level preserves all individual values.
        gain.tap();XCTAssertTrue(slider.waitForExistence(timeout:20));slider.adjust(toNormalizedSliderPosition:1)
        app.buttons["Apply"].tap();ready();level("+12.0 dB")
        for number in 1...3 {app.buttons["timeline.audio.\(number)"].tap();level("+12.0 dB");app.buttons["editor.clearSelection"].tap()}
        app.buttons["Undo"].tap();ready();level("Mixed")
        for number in 1...3 {app.buttons["timeline.audio.\(number)"].tap();level(number==1 ? "+4.0 dB" : "+0.0 dB");app.buttons["editor.clearSelection"].tap()}
        app.buttons["Redo"].tap();ready();level("+12.0 dB")
        app.terminate();app.launchArguments=["--editor-preview"];app.launch();ready();level("+12.0 dB")
        gain.tap();XCTAssertTrue(slider.waitForExistence(timeout:20))
        XCTAssertTrue(app.staticTexts["audioTool.scope"].label.hasPrefix("Whole project · All audio"))
        let shot=XCTAttachment(screenshot:XCUIScreen.main.screenshot());shot.name="Whole-project volume with no selection";shot.lifetime = .keepAlways;add(shot)
        app.buttons["Cancel"].tap()
        // Selecting an unlinked picture is not permission to change unrelated sound.
        app.buttons["Timeline view span"].tap();app.buttons["Whole project"].tap()
        app.buttons["timeline.video.1"].tap();app.buttons["Unlink"].tap();ready()
        app.buttons["timeline.video.1"].tap();XCTAssertFalse(gain.isEnabled)
        app.buttons["editor.clearSelection"].tap();XCTAssertTrue(gain.isEnabled)
    }

    func testQuickGainKeepsPlaybackButHorizontalScrubPauses() throws {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]; app.launch()
        let play = app.buttons["Play"], pause = app.buttons["Pause playback"], timeline = app.otherElements["editor.timeline"]
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 45)
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.30)).tap()
        play.tap(); XCTAssertTrue(pause.waitForExistence(timeout: 10))
        let gain = app.buttons["audio.quickGain"], time = app.staticTexts["editor.playhead"]
        let start = app.buttons["timeline.audio.1"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -32)))
        expectation(for: NSPredicate(format: "value BEGINSWITH '+4.0 dB'"), evaluatedWith: gain); waitForExpectations(timeout: 20)
        let anchor = time.label
        expectation(for: NSPredicate(format: "label != %@", anchor), evaluatedWith: time); waitForExpectations(timeout: 10)
        XCTAssertTrue(pause.exists, "Releasing the gain gesture must resume the committed preview")
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: -125, dy: -24)))
        XCTAssertTrue((gain.value as? String)?.hasPrefix("+4.0 dB") == true)
        // This begins horizontally, so it is a scrub, not a gain adjustment.
        XCTAssertTrue(play.waitForExistence(timeout: 5), "A horizontal waveform drag pauses playback")
        let afterScrub = time.label
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(time.label, afterScrub, "Scrubbing stays paused after lifting the finger")
    }

    func testRepeatedQuickVolumeOnMarkedRange() throws {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]; app.launch()
        let play = app.buttons["Play"], timeline = app.otherElements["editor.timeline"]
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 45)
        app.buttons["Timeline view span"].tap(); app.buttons["Whole project"].tap()
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.60, dy: 0.03)).tap()
        app.buttons["Mark start"].tap()
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.03)).tap()
        app.buttons["Mark end"].tap()
        let gain = app.buttons["audio.quickGain"]
        var start = app.buttons["timeline.audio.1"].coordinate(withNormalizedOffset: CGVector(dx: 0.68, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -32)))
        expectation(for: NSPredicate(format: "value == '+4.0 dB'"), evaluatedWith: gain); waitForExpectations(timeout: 20)
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: gain); waitForExpectations(timeout: 20)
        start = app.buttons["timeline.audio.2"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -16)))
        expectation(for: NSPredicate(format: "value == '+6.0 dB'"), evaluatedWith: gain); waitForExpectations(timeout: 20)
        app.buttons["Undo"].tap()
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: gain); waitForExpectations(timeout: 20)
        app.buttons["timeline.audio.2"].tap() // Undo clears selection; inspect the restored range, not the mixed whole project.
        expectation(for: NSPredicate(format: "value == '+4.0 dB'"), evaluatedWith: gain); waitForExpectations(timeout: 20)
    }

    func testMixedVolumeGesturePreservesIndividualUndo() throws {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--multiselect-fixture"]; app.launch()
        let play = app.buttons["Play"], timeline = app.otherElements["editor.timeline"]
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 45)
        app.buttons["Timeline view span"].tap(); app.buttons["Whole project"].tap()
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.30)).tap()
        let gain = app.buttons["audio.quickGain"]
        let start = app.buttons["timeline.audio.1"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -32)))
        expectation(for: NSPredicate(format: "value == '+4.0 dB'"), evaluatedWith: gain); waitForExpectations(timeout: 20)
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.65)).press(forDuration: 0.6)
        XCTAssertEqual(gain.value as? String, "Mixed")
        gain.tap(); XCTAssertTrue(app.staticTexts["Mixed levels"].waitForExistence(timeout: 20))
        app.buttons["Apply"].tap()
        XCTAssertEqual(gain.value as? String, "Mixed", "Opening and applying must preserve each original level")
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -32)))
        expectation(for: NSPredicate(format: "value == '+6.5 dB'"), evaluatedWith: gain); waitForExpectations(timeout: 20)
        app.buttons["Undo"].tap()
        expectation(for: NSPredicate(format: "value == 'Mixed'"), evaluatedWith: gain); waitForExpectations(timeout: 20)
    }

    func testWaveformGainReturnsToZero() throws {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]; app.launch()
        let gain = app.buttons["audio.quickGain"]
        func level(_ value: String) {
            expectation(for: NSPredicate(format: "value BEGINSWITH %@ AND enabled == true", value), evaluatedWith: gain); waitForExpectations(timeout: 30)
        }
        XCTAssertTrue(gain.waitForExistence(timeout: 30)); level("+0.0 dB")
        for _ in 0..<2 {
            let start = app.buttons["timeline.audio.1"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -96)))
            level("+12.0 dB")
            let reset = app.buttons["timeline.audio.1"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            reset.press(forDuration: 0.1, thenDragTo: reset.withOffset(CGVector(dx: 0, dy: 96)))
            level("+0.0 dB")
        }
        app.buttons["Undo"].tap(); level("+12.0 dB")
        app.buttons["Redo"].tap(); level("+0.0 dB")
        app.terminate(); app.launchArguments = ["--editor-preview"]; app.launch(); level("+0.0 dB")
    }

    func testSplitEffectRemovalIsIndependent() throws {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]; app.launch()
        openTool("videoEffects", in: app); openEffectSection("colorStyle", in: app)
        app.buttons["videoEffects.add.silentTint"].tap()
        let apply = app.buttons["videoEffects.apply"], play = app.buttons["Play"], timeline = app.otherElements["editor.timeline"]
        func applyEffect() {
            expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: apply); waitForExpectations(timeout: 45)
            apply.tap()
            expectation(for: NSPredicate(format: "exists == true AND enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 30)
        }
        func seek(_ fraction: CGFloat) {
            timeline.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 48 + (timeline.frame.width - 96) * fraction, dy: 10)).tap()
        }
        applyEffect()
        app.buttons["Timeline view span"].tap(); app.buttons["Whole project"].tap()
        seek(0.5); app.buttons["Split"].tap()
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 30)
        let effect = app.buttons["effect.videoEffects"].firstMatch
        seek(0.25); XCTAssertTrue(effect.waitForExistence(timeout: 10))
        effect.press(forDuration: 0.8); app.buttons["effect.confirmRemove"].tap()
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 30)
        XCTAssertFalse(effect.exists)
        seek(0.75); XCTAssertTrue(effect.waitForExistence(timeout: 10), "The other split keeps its effect")
        app.buttons["Undo"].tap()
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 30)
        seek(0.25); effect.tap()
        XCTAssertTrue(app.buttons["videoEffects.apply"].waitForExistence(timeout: 15))
        let row = app.cells.containing(.button, identifier: "Silent Tint").firstMatch
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)).press(forDuration: 0.05, thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)), withVelocity: .slow, thenHoldForDuration: 0.1)
        let remove = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "videoEffects.delete.")).firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5)); remove.tap(); applyEffect()
        XCTAssertFalse(effect.exists)
        seek(0.75); XCTAssertTrue(effect.waitForExistence(timeout: 10), "Inspector removal also stays on the chosen split")
        app.terminate(); app.launchArguments = ["--editor-preview"]; app.launch()
        expectation(for: NSPredicate(format: "exists == true AND enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 30)
        app.buttons["Timeline view span"].tap(); app.buttons["Whole project"].tap()
        seek(0.25); XCTAssertFalse(effect.exists)
        seek(0.75); XCTAssertTrue(effect.waitForExistence(timeout: 10))
    }

    func testStudioRestorationPreviewApplyAndBypass() throws {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--audio-preview-probe"]; app.launch()
        let play = app.buttons["Play"]
        XCTAssertTrue(play.waitForExistence(timeout: 30)); expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 40)
        openTool("enhanceAudio", in: app)
        func ready() { expectation(for: NSPredicate(format: "label == 'Ready'"), evaluatedWith: app.staticTexts["audio.previewState"]); waitForExpectations(timeout: 180) }
        XCTAssertTrue(app.buttons["Add filter"].isEnabled); XCTAssertEqual(app.staticTexts["audio.previewState"].label, "Idle"); app.buttons["Add filter"].tap(); app.buttons["Studio restoration"].tap()
        let fader = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH 'audio.fader.'")).firstMatch
        XCTAssertTrue(fader.waitForExistence(timeout: 5)); XCTAssertEqual(fader.label, "Studio restoration amount")
        app.buttons["Play preview"].tap(); ready()
        let probe = app.staticTexts["audio.previewPCMProbe"]
        XCTAssertTrue(probe.label.contains("bypass=no")); XCTAssertFalse(probe.label.contains("nan"))
        app.buttons["Bypass"].tap(); app.buttons["Play preview"].tap(); ready(); XCTAssertTrue(probe.label.contains("bypass=yes"))
        app.buttons["Bypass on"].tap(); app.buttons["Play preview"].tap(); ready()
        if app.buttons["Pause"].exists { app.buttons["Pause"].tap() }
        let portrait = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); portrait.name = "Studio restoration portrait"; portrait.lifetime = .keepAlways; add(portrait)
        XCUIDevice.shared.orientation = .landscapeLeft
        expectation(for: NSPredicate { _,_ in app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height }, evaluatedWith: app.windows.firstMatch); waitForExpectations(timeout: 10)
        app.buttons["Play preview"].tap(); app.buttons["Pause"].tap()
        expectation(for: NSPredicate { _,_ in fader.isHittable && app.windows.firstMatch.frame.contains(fader.frame) }, evaluatedWith: fader); waitForExpectations(timeout: 10)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Studio restoration landscape"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["Apply"].tap()
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 40)
        openTool("enhanceAudio", in: app); XCTAssertEqual(app.staticTexts["audio.previewState"].label, "Idle")
        XCTAssertEqual(fader.label, "Studio restoration amount", "Saved model and settings reopen")
        app.buttons["Cancel"].tap(); XCUIDevice.shared.orientation = .portrait
    }

    func testEnhanceAudioOnDemandWindow() throws {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--tracks-overlap-fixture", "--audio-preview-probe"]; app.launch()
        let play = app.buttons["Play"], timeline = app.otherElements["editor.timeline"]
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 40)
        app.buttons["Timeline view span"].tap(); app.buttons["Whole project"].tap()
        timeline.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: timeline.frame.width / 2, dy: 10)).tap()
        openTool("enhanceAudio", in: app)
        let state = app.staticTexts["audio.previewState"], position = app.staticTexts["audioTool.position"]
        XCTAssertEqual(state.label, "Idle"); XCTAssertTrue(app.buttons["Add filter"].isEnabled)
        XCTAssertFalse(app.staticTexts["audioTool.preparing"].exists)
        let numbers = (position.value as? String ?? "").components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted).compactMap(Double.init)
        XCTAssertEqual(numbers.count, 3); XCTAssertEqual(numbers[1] - numbers[0], 10, accuracy: 0.04)
        XCTAssertEqual(numbers[2] - numbers[0], 5, accuracy: 0.04)
        app.buttons["Add filter"].tap(); app.buttons["Studio restoration"].tap()
        XCTAssertEqual(state.label, "Idle", "Adding an expensive filter must not start processing")
        app.buttons["Play preview"].tap()
        XCTAssertTrue(app.buttons["Cancel preview"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Add filter"].isEnabled); XCTAssertTrue(app.buttons["Apply"].isEnabled)
        app.buttons["Add filter"].tap(); app.buttons["Output gain"].tap()
        expectation(for: NSPredicate(format: "label == 'Idle'"), evaluatedWith: state); waitForExpectations(timeout: 10)
        XCTAssertFalse(app.staticTexts["audioTool.preparing"].exists, "Editing cancels preparation and waits for Play")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "On-demand audio controls during cancelled neural preview"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["Cancel"].tap()
    }

    func testEnhanceAudioRangePlayback() throws {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--tracks-overlap-fixture"]; app.launch()
        let mark = app.buttons["Mark start"], timeline = app.otherElements["editor.timeline"]
        XCTAssertTrue(mark.waitForExistence(timeout: 30))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: mark); waitForExpectations(timeout: 40)
        app.buttons["Timeline view span"].tap(); app.buttons["Whole project"].tap()
        func point(_ t: Double) -> XCUICoordinate { timeline.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 48 + (timeline.frame.width-96)*t/18, dy: 10)) }
        point(5.6).tap(); mark.tap(); point(7).tap(); app.buttons["Mark end"].tap()
        openTool("enhanceAudio", in: app)
        let play = app.buttons["Play preview"], position = app.staticTexts["audioTool.position"]
        func ready() { expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: app.buttons["Apply"]); waitForExpectations(timeout: 30) }
        func numbers() -> [Double] { (position.value as? String ?? "").components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted).compactMap(Double.init) }
        ready(); let range = numbers(); XCTAssertEqual(range.count, 3); XCTAssertGreaterThan(range[0], 5); XCTAssertLessThan(range[1], 7.5)
        for _ in 0..<2 {
            play.tap(); XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 3))
            expectation(for: NSPredicate(format: "exists == true"), evaluatedWith: play); waitForExpectations(timeout: 6)
            XCTAssertGreaterThanOrEqual(numbers()[2], range[0]); XCTAssertLessThanOrEqual(numbers()[2], range[1] + 0.04)
        }
        app.buttons["Bypass"].tap(); ready(); play.tap()
        expectation(for: NSPredicate(format: "exists == true"), evaluatedWith: play); waitForExpectations(timeout: 6)
        XCTAssertLessThanOrEqual(numbers()[2], range[1] + 0.04)
        app.buttons["Cancel"].tap()
    }

    func testEnhanceAudioPlaysLatestGainAndBypass() throws {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--audio-preview-probe"]; app.launch()
        let play = app.buttons["Play"]
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 40)
        openTool("enhanceAudio", in: app)
        let previewPlay = app.buttons["Play preview"], probe = app.staticTexts["audio.previewPCMProbe"]
        func ready() {
            expectation(for: NSPredicate(format: "label == 'Ready'"), evaluatedWith: app.staticTexts["audio.previewState"]); waitForExpectations(timeout: 60)
        }
        func rms() -> Double {
            let text = probe.label.components(separatedBy: ";")[0].replacingOccurrences(of: "rms=", with: "")
            return Double(text) ?? -999
        }
        XCTAssertEqual(app.staticTexts["audio.previewState"].label, "Idle"); previewPlay.tap(); ready(); if app.buttons["Pause"].exists { app.buttons["Pause"].tap() }; let baseline = rms(); XCTAssertGreaterThan(baseline, -80)
        app.buttons["Add filter"].tap(); app.buttons["Output gain"].tap()
        let fader = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH 'audio.fader.'")).firstMatch
        XCTAssertTrue(fader.waitForExistence(timeout: 5))
        let center = fader.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.press(forDuration: 0.1, thenDragTo: center.withOffset(CGVector(dx: 0, dy: -fader.frame.height / 4)), withVelocity: .slow, thenHoldForDuration: 0.1)
        let selectedGain = Double((fader.value as? String ?? "").replacingOccurrences(of: " dB", with: "").replacingOccurrences(of: ",", with: ".")) ?? -999
        XCTAssertGreaterThan(selectedGain, 0.8)
        previewPlay.tap(); ready()
        XCTAssertEqual(rms() - baseline, selectedGain, accuracy: 0.15, "Play must render the edited gain without a separate Preview step")
        XCTAssertTrue(probe.label.contains("volume=1.0000"), "Listening-level matching must not cancel intentional gain")
        app.buttons["Bypass"].tap(); previewPlay.tap(); ready()
        XCTAssertEqual(rms(), baseline, accuracy: 0.05)
        app.buttons["Bypass on"].tap(); previewPlay.tap(); ready()
        XCTAssertEqual(rms() - baseline, selectedGain, accuracy: 0.15)
        if app.buttons["Pause"].exists { app.buttons["Pause"].tap() }
        let reset = app.buttons["Reset selected effect"]
        if !reset.isHittable { app.scrollViews.firstMatch.swipeUp() }
        reset.tap()
        previewPlay.tap(); ready()
        XCTAssertEqual(rms(), baseline, accuracy: 0.15, "Returning the filter to zero must restore the original level")
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Enhance latest gain and bypass"; attachment.lifetime = .keepAlways; add(attachment)
        app.buttons["Apply"].tap()
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 40)
    }

    func testVolumeResetClearsAudition() throws {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--gain-preview-probe"]; app.launch()
        let gain = app.buttons["audio.quickGain"]
        XCTAssertTrue(gain.waitForExistence(timeout: 30))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: gain); waitForExpectations(timeout: 30)
        gain.tap()
        let slider = app.sliders["audio.gainSlider"], probe = app.staticTexts["audio.gainPreviewProbe"]
        XCTAssertTrue(slider.waitForExistence(timeout: 20))
        expectation(for: NSPredicate(format: "label == 'Committed gain'"), evaluatedWith: probe); waitForExpectations(timeout: 30)
        slider.adjust(toNormalizedSliderPosition: 1)
        expectation(for: NSPredicate(format: "label == '+12.0 dB'"), evaluatedWith: probe); waitForExpectations(timeout: 5)
        app.buttons["Reset to 0 dB"].tap()
        expectation(for: NSPredicate(format: "label == 'Committed gain'"), evaluatedWith: probe); waitForExpectations(timeout: 10)
        app.buttons["Play preview"].tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5))
        app.buttons["Apply"].tap()
        expectation(for: NSPredicate(format: "value == '+0.0 dB'"), evaluatedWith: gain); waitForExpectations(timeout: 20)
    }

    func testWaveformSwipeDirectFeedbackAndCancel() throws {
        continueAfterFailure=false;XCUIDevice.shared.orientation = .portrait
        let app=XCUIApplication();app.launchArguments=["--editor-preview","--reset-ui-fixture","--capture-waveform-gain"];app.launch()
        let play=app.buttons["Play"],gain=app.buttons["audio.quickGain"],audio=app.buttons["timeline.audio.1"]
        XCTAssertTrue(play.waitForExistence(timeout:30));expectation(for:NSPredicate(format:"enabled == true"),evaluatedWith:play);waitForExpectations(timeout:45)
        XCTAssertTrue(gain.isEnabled,"Volume is also available for the whole project")
        let height=audio.frame.height,start=audio.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5))
        start.press(forDuration:0.1,thenDragTo:start.withOffset(CGVector(dx:0,dy:-32)),withVelocity:.slow,thenHoldForDuration:0.8)
        expectation(for:NSPredicate(format:"value == '+4.0 dB'"),evaluatedWith:gain);waitForExpectations(timeout:20)
        XCTAssertEqual(audio.frame.height,height,accuracy:0.5,"Only waveform amplitude changes, never row height")
        XCTAssertFalse(app.sliders["audio.gainSlider"].exists)
        start.press(forDuration:0.1,thenDragTo:start.withOffset(CGVector(dx:0,dy:16)),withVelocity:.slow,thenHoldForDuration:0.2)
        expectation(for:NSPredicate(format:"value == '+2.0 dB'"),evaluatedWith:gain);waitForExpectations(timeout:20)
        app.buttons["Undo"].tap();expectation(for:NSPredicate(format:"value == '+4.0 dB'"),evaluatedWith:gain);waitForExpectations(timeout:20)
        let wide=app.otherElements["editor.timeline"]
        XCUIDevice.shared.orientation = .landscapeLeft
        expectation(for:NSPredicate {_,_ in app.windows.firstMatch.frame.width>app.windows.firstMatch.frame.height},evaluatedWith:app.windows.firstMatch);waitForExpectations(timeout:10)
        let from=audio.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)),wideHeight=audio.frame.height
        from.press(forDuration:0.1,thenDragTo:from.withOffset(CGVector(dx:0,dy:-16)))
        expectation(for:NSPredicate(format:"value == '+6.0 dB'"),evaluatedWith:gain);waitForExpectations(timeout:20)
        XCTAssertEqual(audio.frame.height,wideHeight,accuracy:0.5)
        XCTAssertTrue(wide.frame.contains(audio.frame));XCTAssertFalse(app.sliders["audio.gainSlider"].exists)
        XCUIDevice.shared.orientation = .portrait
    }

    func testAudioLaneHeightDoesNotChangeWithSelection() throws {
        continueAfterFailure=false;XCUIDevice.shared.orientation = .portrait
        let app=XCUIApplication();app.launchArguments=["--editor-preview","--reset-ui-fixture","--multiselect-fixture"];app.launch()
        let play=app.buttons["Play"],timeline=app.otherElements["editor.timeline"]
        func ready() {XCTAssertTrue(play.waitForExistence(timeout:30));expectation(for:NSPredicate(format:"enabled == true"),evaluatedWith:play);waitForExpectations(timeout:30)}
        ready();app.buttons["Timeline view span"].tap();app.buttons["Whole project"].tap()
        let cards=(1...3).flatMap {n in [app.buttons["timeline.video.\(n)"],app.buttons["timeline.audio.\(n)"]]}
        func geometry()->[CGRect] {cards.map {$0.frame.offsetBy(dx:-timeline.frame.minX,dy:-timeline.frame.minY)}}
        func unchanged(_ baseline:[CGRect],_ context:String) {
            for (i,frame) in geometry().enumerated() {
                XCTAssertEqual(frame.height,baseline[i].height,accuracy:0.5,"\(cards[i].label) height changed: \(context)")
                XCTAssertEqual(frame.minY,baseline[i].minY,accuracy:0.5,"\(cards[i].label) moved vertically: \(context)")
            }
        }
        let portrait=geometry()
        let video=app.buttons["timeline.video.2"],audio=app.buttons["timeline.audio.2"]
        video.tap();XCTAssertTrue(video.isSelected);unchanged(portrait,"select linked clip")
        video.tap();XCTAssertFalse(video.isSelected);unchanged(portrait,"deselect linked clip")
        audio.tap();XCTAssertTrue(audio.isSelected);unchanged(portrait,"select from waveform")
        app.buttons["Unlink"].tap();ready();unchanged(portrait,"unlink")
        video.tap();XCTAssertTrue(video.isSelected);unchanged(portrait,"select only picture")
        audio.tap();XCTAssertTrue(audio.isSelected);unchanged(portrait,"select only audio")
        app.buttons["timeline.audio.1"].press(forDuration:0.7);unchanged(portrait,"add audio to selection")
        app.buttons["editor.clearSelection"].tap();unchanged(portrait,"clear selection")
        let ruler=timeline.coordinate(withNormalizedOffset:.zero)
        ruler.withOffset(CGVector(dx:48+(timeline.frame.width-96)*0.25,dy:10)).tap();app.buttons["Mark start"].tap();unchanged(portrait,"start range")
        ruler.withOffset(CGVector(dx:48+(timeline.frame.width-96)*0.6,dy:10)).tap();app.buttons["Mark end"].tap();unchanged(portrait,"complete range")
        app.buttons["editor.clearSelection"].tap();unchanged(portrait,"clear range")
        XCTAssertEqual(video.frame.height,80,accuracy:0.5,"Video gets the former larger audio row")
        XCTAssertEqual(audio.frame.height,44,accuracy:0.5,"Audio gets the former smaller video row")
        let shot=XCTAttachment(screenshot:XCUIScreen.main.screenshot());shot.name="Stable unselected waveform height";shot.lifetime = .keepAlways;add(shot)
        XCUIDevice.shared.orientation = .landscapeLeft
        expectation(for:NSPredicate {_,_ in app.windows.firstMatch.frame.width>app.windows.firstMatch.frame.height},evaluatedWith:app.windows.firstMatch);waitForExpectations(timeout:10)
        let landscape=geometry()
        audio.tap();unchanged(landscape,"landscape audio selection")
        audio.tap();unchanged(landscape,"landscape deselection")
        let wide=XCTAttachment(screenshot:XCUIScreen.main.screenshot());wide.name="Stable waveform landscape";wide.lifetime = .keepAlways;add(wide)
        XCUIDevice.shared.orientation = .portrait
    }

    func testSpeechWaveformZoomViews() throws {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--speech-waveform-fixture", "--reset-ui-fixture"]; app.launch()
        let play = app.buttons["Play"], timeline = app.otherElements["editor.timeline"]
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 45)
        app.buttons["Timeline view span"].tap(); app.buttons["Whole project"].tap()
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.30)).tap()
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.60, dy: 0.03)).tap()
        for span in ["Whole project", "10 seconds", "1 second"] {
            app.buttons["Timeline view span"].tap(); app.buttons[span].tap()
            if span == "1 second" {
                let anchor = app.staticTexts["editor.playhead"].label
                play.tap()
                expectation(for: NSPredicate(format: "label != %@", anchor), evaluatedWith: app.staticTexts["editor.playhead"]); waitForExpectations(timeout: 10)
                app.buttons["Pause playback"].tap()
            }
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Recorded speech waveform " + span; shot.lifetime = .keepAlways; add(shot)
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        expectation(for:NSPredicate {_,_ in app.windows.firstMatch.frame.width>app.windows.firstMatch.frame.height},evaluatedWith:app.windows.firstMatch);waitForExpectations(timeout:10)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Recorded speech waveform landscape"; shot.lifetime = .keepAlways; add(shot)
        XCUIDevice.shared.orientation = .portrait
        expectation(for:NSPredicate {_,_ in app.windows.firstMatch.frame.height>app.windows.firstMatch.frame.width},evaluatedWith:app.windows.firstMatch);waitForExpectations(timeout:10)
        // At the detailed view, place a cut on the quiet side of the next onset.
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.30, dy: 0.03)).tap()
        app.buttons["Split"].tap()
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 30)
        let cut = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); cut.name = "Spoken phrase cut at waveform gap"; cut.lifetime = .keepAlways; add(cut)
        let before = app.staticTexts["editor.playhead"].label
        play.tap()
        expectation(for: NSPredicate(format: "label != %@", before), evaluatedWith: app.staticTexts["editor.playhead"]); waitForExpectations(timeout: 10)
        app.buttons["Pause playback"].tap()
        app.buttons["Undo"].tap()
    }

    func testVolumeClippingFeedback() throws {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--capture-waveform-gain"]; app.launch()
        let play = app.buttons["Play"], timeline = app.otherElements["editor.timeline"]
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 45)
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.30)).tap()
        let gain = app.buttons["audio.quickGain"]
        XCTAssertTrue(gain.isEnabled, "Volume also works for linked video/audio")
        gain.tap()
        let slider = app.sliders["audio.gainSlider"]
        XCTAssertTrue(slider.waitForExistence(timeout: 20))
        slider.adjust(toNormalizedSliderPosition: 1)
        expectation(for: NSPredicate(format: "value CONTAINS 'Clipping'"), evaluatedWith: slider); waitForExpectations(timeout: 30)
        let warning = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); warning.name = "Red gain thumb at sample overload"; warning.lifetime = .keepAlways; add(warning)
        slider.adjust(toNormalizedSliderPosition: 40.0 / 52)
        expectation(for: NSPredicate(format: "NOT (value CONTAINS 'Clipping')"), evaluatedWith: slider); waitForExpectations(timeout: 10)
        app.buttons["Cancel"].tap()
        XCTAssertEqual(gain.value as? String, "+0.0 dB", "Cancel preserves the original gain")
        let start = app.buttons["timeline.audio.1"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -96)), withVelocity: .slow, thenHoldForDuration: 0.4)
        expectation(for: NSPredicate(format: "value CONTAINS 'Clipping'"), evaluatedWith: gain); waitForExpectations(timeout: 30)
        app.buttons["Undo"].tap()
        expectation(for: NSPredicate(format: "value BEGINSWITH '+0.0 dB'"), evaluatedWith: gain); waitForExpectations(timeout: 15)
    }

    func testQuickVolumeGestureUndoAndPersistence() throws {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]; app.launch()
        let play = app.buttons["Play"], timeline = app.otherElements["editor.timeline"]
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 45)
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.30)).tap()
        app.buttons["Unlink"].tap()
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 30)
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.65)).tap()
        let gain = app.buttons["audio.quickGain"]
        XCTAssertTrue(gain.isEnabled)
        let start = app.buttons["timeline.audio.1"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -32)))
        expectation(for: NSPredicate(format: "value == '+4.0 dB'"), evaluatedWith: gain); waitForExpectations(timeout: 20)
        app.buttons["Undo"].tap()
        expectation(for: NSPredicate(format: "value == '+0.0 dB'"), evaluatedWith: gain); waitForExpectations(timeout: 20)
        app.buttons["Redo"].tap()
        expectation(for: NSPredicate(format: "value == '+4.0 dB'"), evaluatedWith: gain); waitForExpectations(timeout: 20)
        let buttonStart=gain.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5))
        buttonStart.press(forDuration:0.1,thenDragTo:buttonStart.withOffset(CGVector(dx:0,dy:-32)))
        XCTAssertEqual(gain.value as? String,"+4.0 dB","Volume button has no drag action")
        XCTAssertFalse(app.sliders["audio.gainSlider"].exists,"Dragging opens no volume inspector")
        // Sideways cancellation changes neither gain nor history.
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: -125, dy: -24)))
        XCTAssertEqual(gain.value as? String, "+4.0 dB")
        app.buttons["Timeline view span"].tap(); app.buttons["1 second"].tap()
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Fine waveform and quick volume"; shot.lifetime = .keepAlways; add(shot)
        gain.tap()
        XCTAssertTrue(app.sliders["audio.gainSlider"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].tap()
        app.terminate(); app.launchArguments = ["--editor-preview"]; app.launch()
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 45)
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.65)).tap()
        XCTAssertEqual(gain.value as? String, "+4.0 dB")
    }

    func testRearHorizonRecording() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        let baseline = env["YOUREC_LEVEL_BASELINE"] == "1"
        let dual = env["YOUREC_LEVEL_PAIR"] == "1"
        let hdr = env["YOUREC_LEVEL_HDR"] == "1"
        let checkDefault = env["YOUREC_LEVEL_DEFAULT"] == "1"
        XCUIDevice.shared.orientation = env["YOUREC_LEVEL_LANDSCAPE"] == "1" ? .landscapeRight : .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--recorder-controls-test", "--probe-lens-controls", "--probe-level-horizon", "-fitRecordedFrame", "YES",
                               "-liveVideoEffects", "<5b5d>",
                               "-captureQuality", hdr ? "ultraHD4K" : "hd1080", "-captureColorMode", hdr ? "hdr" : "sdr",
                               "-dualStabilization", hdr ? "YES" : "NO", "-dualFaceFollow", hdr ? "YES" : "NO"]
        app.launch()
        let settings = app.buttons["recorder.settings"], record = app.buttons["recorder.record"]
        let level = app.descendants(matching: .any)["recorder.levelHorizon"]
        XCTAssertTrue(settings.waitForExistence(timeout: 35))
        let lens = app.buttons["recorder.camera"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: lens); waitForExpectations(timeout: 25)
        lens.tap()
        #if targetEnvironment(simulator)
        app.buttons["Rear wide"].tap()
        #else
        app.buttons["Rear main"].tap()
        #endif
        if hdr {
            app.buttons["recorder.videoEffects"].tap()
            openEffectSection("colorStyle", in: app, live: true)
            app.buttons["liveEffects.add.bleachBypass"].tap()
            dismissLiveEffects(in: app)
        }
        if dual {
            setDualMode(true, in: app)
            app.buttons["recorder.dualLayout"].tap()
            app.buttons["recorder.layout.sideBySide"].tap(); app.buttons["Done"].tap()
        }
        useEmptyRecordingProject(in: app)
        func take(_ name: String) {
            let preview = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); preview.name = name + " preview"; preview.lifetime = .keepAlways; add(preview)
            record.tap()
            XCTAssertTrue(app.buttons["Stop recording"].waitForExistence(timeout: 15))
            Thread.sleep(forTimeInterval: 1.3)
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = name + " recording"; shot.lifetime = .keepAlways; add(shot)
            if name == "Level on" {
                settings.tap(); XCTAssertFalse(level.isEnabled)
                app.buttons["recorder.settingsDone"].tap()
            }
            record.tap()
            expectation(for: NSPredicate(format: "enabled == true AND label == 'Record into this project'"), evaluatedWith: record)
            waitForExpectations(timeout: 30)
        }
        if !baseline {
            settings.tap()
            XCTAssertTrue(level.waitForExistence(timeout: 5))
            if level.value as? String == "On" { level.tap() }
            app.buttons["recorder.settingsDone"].tap()
            XCTAssertTrue(level.waitForNonExistence(timeout: 5))
        }
        take("Level off")
        if !baseline {
            settings.tap(); level.tap(); XCTAssertEqual(level.value as? String, "On")
            expandCameraSheet(in: app)
            app.buttons["recorder.levelAngle"].tap()
            let slider = app.sliders["recorder.levelAngleSlider"]
            XCTAssertTrue(slider.waitForExistence(timeout: 5))
            if checkDefault {
                XCTAssertTrue(app.staticTexts["9°"].exists, "First use must show the default before touching the slider")
            } else {
                slider.adjust(toNormalizedSliderPosition: hdr ? 2.5/9.5 : 1)
                XCTAssertTrue(app.staticTexts[hdr ? "3°" : "10°"].exists)
            }
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Max angle live framing"; shot.lifetime = .keepAlways; add(shot)
            app.buttons["recorder.levelAngleDone"].tap()
            app.buttons["recorder.settingsDone"].tap()
            Thread.sleep(forTimeInterval: 1)
            take("Level on")
            if hdr && !dual {
                let flip = app.buttons["recorder.flip"]
                for rear in [false, true] {
                    flip.tap()
                    expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: lens)
                    waitForExpectations(timeout: 20)
                    settings.tap()
                    XCTAssertEqual(level.isEnabled, rear)
                    XCTAssertEqual(level.value as? String, rear ? "On" : "Off")
                    if rear { level.tap() }
                    app.buttons["recorder.settingsDone"].tap()
                }
            } else {
                settings.tap(); level.tap(); app.buttons["recorder.settingsDone"].tap()
            }
        }
        if dual { setDualMode(false, in: app) }
    }

    func testHorizonAnglePreviewKeepsTheToggleOff() throws {
        #if targetEnvironment(simulator)
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--recorder-controls-test"]
        app.launch()
        let lens = app.buttons["recorder.camera"], settings = app.buttons["recorder.settings"]
        XCTAssertTrue(lens.waitForExistence(timeout: 15))
        lens.tap(); app.buttons["Rear wide"].tap()
        settings.tap()
        let level = app.switches["recorder.levelHorizon"]
        if level.value as? String == "On" { level.tap() }
        expandCameraSheet(in: app)
        app.buttons["recorder.levelAngle"].tap()
        let preview = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Preview only'")).firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home); app.activate()
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        app.buttons["recorder.levelAngleDone"].tap()
        XCTAssertTrue(app.navigationBars["Camera settings"].waitForExistence(timeout: 5))
        app.buttons["recorder.settingsDone"].tap()
        settings.tap()
        XCTAssertEqual(level.value as? String, "Off")
        #else
        throw XCTSkip("Checks camera-settings navigation with the simulator fixture")
        #endif
    }

    private func useEmptyRecordingProject(in app: XCUIApplication) {
        let start = app.buttons["recorder.newProject"]
        if start.exists { start.tap() }
    }

    private func launchRecorderWithFootage(in app: XCUIApplication, title: String) {
        app.launchEnvironment["YOUREC_EDITOR_FIXTURE_TITLE"] = title
        app.launchArguments = ["--recorder-controls-test", "--editor-preview", "--reset-ui-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["Back to projects"].waitForExistence(timeout: 30))
        app.terminate()
        app.launchArguments = ["--recorder-controls-test"]
        app.launch()
    }

    func testRecorderDurationDistinguishesContinuingProject() throws {
        continueAfterFailure = false
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        launchRecorderWithFootage(in: app, title: "Recorder duration · UI test")

        let clock = app.descendants(matching: .any)["recorder.projectDuration"]
        func checkClock(_ state: String, duration: String? = nil, red: Bool) throws {
            expectation(for: NSPredicate(format: "label == %@", state), evaluatedWith: clock)
            waitForExpectations(timeout: 15)
            if let duration { XCTAssertEqual(clock.value as? String, duration) }
            let shot = clock.screenshot()
            let attachment = XCTAttachment(screenshot: shot)
            attachment.name = state; attachment.lifetime = .keepAlways; add(attachment)
            let image = try XCTUnwrap(shot.image.cgImage)
            // Check the background across the badge, allowing for the white digits and rounded corners.
            let width = 32, height = 16
            var rgba = [UInt8](repeating: 0, count: width * height * 4)
            let context = try XCTUnwrap(CGContext(data: &rgba, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let redPixels = stride(from: 0, to: rgba.count, by: 4).filter { i in
                Int(rgba[i]) - Int(max(rgba[i + 1], rgba[i + 2])) > 55
            }.count
            XCTAssertEqual(redPixels > width * height / 2, red, "Clock color for \(state)")
        }
        try checkClock("Ready to continue recording", duration: "00:18", red: true)
        app.buttons["Projects"].tap(); app.buttons["Continue recording"].firstMatch.tap()
        XCUIDevice.shared.orientation = .landscapeRight
        expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: app)
        waitForExpectations(timeout: 10)
        try checkClock("Ready to continue recording", duration: "00:18", red: true)
        app.buttons["recorder.record"].tap()
        try checkClock("Recording", red: true)
        app.buttons["Pause recording"].tap()
        try checkClock("Paused", red: true)
        app.buttons["recorder.newProject"].tap()
        try checkClock("Ready", duration: "00:00", red: false)
    }

    func testStartNewProjectSelectsOneEditableRecordingDestination() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        let originalTitle = "Recorder destination · UI test"
        launchRecorderWithFootage(in: app, title: originalTitle)
        let record = app.buttons["recorder.record"], newProject = app.buttons["recorder.newProject"]
        XCTAssertTrue(newProject.waitForExistence(timeout: 15))
        XCTAssertEqual(record.value as? String, originalTitle)
        let projectTitle = app.staticTexts["recorder.projectTitle"]
        XCTAssertEqual(projectTitle.label, originalTitle)
        let titleShot = XCTAttachment(screenshot: app.screenshot())
        titleShot.name = "Current project title in camera header"; titleShot.lifetime = .keepAlways; add(titleShot)
        app.buttons["Projects"].tap()
        let projectsBefore = app.buttons.matching(identifier: "Continue recording").count
        app.buttons["Record"].tap()
        newProject.doubleTap()
        XCTAssertFalse(newProject.waitForExistence(timeout: 2), "An empty destination must keep Start new project hidden")
        XCTAssertEqual(record.label, "Record into this project", "Creating a project must not start recording")
        XCTAssertNotEqual(record.value as? String, originalTitle)
        let destination = try XCTUnwrap(record.value as? String)
        app.terminate(); app.launch()
        XCTAssertTrue(record.waitForExistence(timeout: 15))
        XCTAssertEqual(record.value as? String, destination, "Relaunch continues into the chosen project")
        XCTAssertEqual(projectTitle.label, destination)
        XCTAssertFalse(newProject.exists)
        app.buttons["Edit this project"].tap()
        let empty = app.staticTexts["Your timeline is empty"]
        XCTAssertTrue(empty.waitForExistence(timeout: 10))
        app.buttons["Tools"].tap(); app.buttons["tools.addVideo"].tap()
        XCTAssertTrue(app.buttons["From Photos"].isHittable)
        app.buttons["editor.recordHere"].tap()
        let finish = app.buttons["recorder.finishInsertion"]
        XCTAssertTrue(finish.waitForExistence(timeout: 10))
        XCTAssertFalse(newProject.exists)
        finish.tap()
        XCTAssertTrue(empty.waitForExistence(timeout: 10))
        app.buttons["Back to projects"].tap()
        XCTAssertEqual(app.buttons.matching(identifier: "Continue recording").count, projectsBefore + 1)
        XCTAssertTrue(app.buttons["Rename " + originalTitle].exists, "The previous project is still in the library")
        app.buttons["Record"].tap()
        XCTAssertEqual(record.value as? String, destination)
        #if !targetEnvironment(simulator)
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: record)
        waitForExpectations(timeout: 15)
        record.tap()
        XCTAssertTrue(app.buttons["Stop recording"].waitForExistence(timeout: 15))
        let clock = app.descendants(matching: .any)["recorder.projectDuration"]
        expectation(for: NSPredicate(format: "label == 'Recording' AND value != '00:00'"), evaluatedWith: clock)
        waitForExpectations(timeout: 8)
        record.tap()
        XCTAssertTrue(newProject.waitForExistence(timeout: 15))
        XCTAssertEqual(record.value as? String, destination)
        app.buttons["Edit this project"].tap()
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 15))
        XCTAssertFalse(empty.exists)
        XCTAssertNotEqual(app.staticTexts["editor.duration"].label, "0:00.00")
        #endif
    }

    func testRecorderProjectMarkAndCameraSafeControls() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--recorder-controls-test"]; app.launch()
        let record = app.buttons["recorder.record"], newProject = app.buttons["recorder.newProject"]
        XCTAssertTrue(record.waitForExistence(timeout: 15))
        useEmptyRecordingProject(in: app)
        let destination = try XCTUnwrap(record.value as? String)
        for pose in [UIDeviceOrientation.landscapeLeft, .landscapeRight, .portrait] {
            XCUIDevice.shared.orientation = pose
            let settled = NSPredicate { _, _ in
                guard record.isHittable else { return false }
                if pose == .portrait { return app.frame.height > app.frame.width && record.frame.midY > app.frame.height * 0.65 }
                guard app.frame.width > app.frame.height else { return false }
                return pose == .landscapeLeft ? record.frame.midX > app.frame.width * 0.75 : record.frame.midX < app.frame.width * 0.25
            }
            expectation(for: settled, evaluatedWith: app); waitForExpectations(timeout: 15)
            record.tap()
            let mark = app.buttons["recorder.bookmark"]
            XCTAssertTrue(mark.waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["Projects"].exists)
            XCTAssertFalse(newProject.exists)
            if pose != .portrait { XCTAssertEqual(mark.frame.midX, record.frame.midX, accuracy: 2) }
            mark.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertEqual(mark.value as? String, "Bookmark added")
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Recorder controls \(pose.rawValue)"; shot.lifetime = .keepAlways; add(shot)
            app.buttons["Pause recording"].tap()
            XCTAssertFalse(app.buttons["Projects"].exists); XCTAssertTrue(mark.exists); XCTAssertFalse(mark.isEnabled)
            record.tap(); XCTAssertTrue(mark.waitForExistence(timeout: 5))
            record.tap()
            #if targetEnvironment(simulator)
            // The simulated camera changes capture state without writing media.
            XCTAssertFalse(newProject.exists)
            #else
            XCTAssertTrue(newProject.waitForExistence(timeout: 15), "Saving the first take makes this a continuing project")
            #endif
            XCTAssertEqual(record.value as? String, destination, "Stop/resume keeps the same project")
        }
    }

    func testDeletionKeepsLogicalPlayhead() throws {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--multiselect-fixture"]; app.launch()
        let play = app.buttons["Play"], timeline = app.otherElements["editor.timeline"]
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 45)
        func position() -> Double { Double((timeline.value as? String ?? "").components(separatedBy: " seconds")[0]) ?? -1 }
        app.buttons["Timeline view span"].tap(); app.buttons["Whole project"].tap()
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.27)).tap()
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.03)).tap()
        let before = position(); XCTAssertGreaterThan(before, 12)
        app.buttons["Delete selection"].tap()
        expectation(for: NSPredicate { _, _ in abs(position() - (before - 6)) < 0.04 && play.isEnabled }, evaluatedWith: app)
        waitForExpectations(timeout: 30)
        XCTAssertEqual(app.staticTexts["editor.duration"].label, "0:12.00")
        play.tap()
        expectation(for: NSPredicate { _, _ in position() > before - 6 + 0.2 }, evaluatedWith: app); waitForExpectations(timeout: 10)
        app.buttons["Pause playback"].tap()
        app.buttons["Undo"].tap()
        expectation(for: NSPredicate { _, _ in abs(position() - before) < 0.04 && play.isEnabled }, evaluatedWith: app); waitForExpectations(timeout: 30)
        // Detach the first picture, delete it, and retain the gap/clock.
        app.buttons["Timeline view span"].tap(); app.buttons["Whole project"].tap()
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.27)).tap()
        app.buttons["Unlink"].tap()
        app.buttons["editor.clearSelection"].tap()
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.27)).tap()
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.03)).tap()
        let detachedPosition = position()
        app.buttons["Delete, leave gap"].tap()
        expectation(for: NSPredicate { _, _ in abs(position() - detachedPosition) < 0.04 && play.isEnabled }, evaluatedWith: app); waitForExpectations(timeout: 30)
        XCTAssertEqual(app.staticTexts["editor.duration"].label, "0:18.00")
    }

    func testRangeDeletionKeepsLogicalPlayhead() throws {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]; app.launch()
        let play = app.buttons["Play"], timeline = app.otherElements["editor.timeline"]
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 45)
        func position() -> Double { Double((timeline.value as? String ?? "").components(separatedBy: " seconds")[0]) ?? -1 }
        func scrub(_ fraction: Double) { timeline.coordinate(withNormalizedOffset: CGVector(dx: fraction, dy: 0.03)).tap() }
        app.buttons["Timeline view span"].tap(); app.buttons["Whole project"].tap()
        scrub(0.18); app.buttons["Mark start"].tap(); let start = position()
        scrub(0.40); app.buttons["Mark end"].tap(); let end = position()
        XCTAssertGreaterThan(end - start, 2)
        scrub(0.82); let before = position()
        app.buttons["Delete selection"].tap()
        expectation(for: NSPredicate { _, _ in abs(position() - (before - end + start)) < 0.04 && play.isEnabled }, evaluatedWith: app)
        waitForExpectations(timeout: 30)
        app.buttons["Undo"].tap()
        expectation(for: NSPredicate { _, _ in abs(position() - before) < 0.04 && play.isEnabled }, evaluatedWith: app); waitForExpectations(timeout: 30)
        app.buttons["Redo"].tap()
        expectation(for: NSPredicate { _, _ in abs(position() - (before - end + start)) < 0.04 && play.isEnabled }, evaluatedWith: app); waitForExpectations(timeout: 30)
    }

    func testLandscapeSelfieShowsEntireFrame() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--recorder-controls-test", "--front-landscape-preview-test"]
        app.launch()
        let camera = app.buttons["recorder.camera"]
        XCTAssertTrue(camera.waitForExistence(timeout: 15))
        let preview = app.otherElements["recorder.preview"]
        camera.tap(); app.buttons["Rear wide"].tap()
        for attempt in 0..<2 {
            camera.tap()
            XCTAssertTrue(app.buttons["Front ultrawide (portrait)"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["Front ultrawide (landscape)"].exists)
            XCTAssertFalse(app.buttons["Front · landscape, phone upright"].exists)
            if attempt == 0 {
                let menu = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                menu.name = "Portrait and landscape camera entries"; menu.lifetime = .keepAlways; add(menu)
            }
            app.buttons["Front ultrawide (landscape)"].tap()
            XCTAssertEqual(camera.value as? String, "Front ultrawide (landscape)")
            expectation(for: NSPredicate(format: "value == %@", "Landscape, entire recorded frame"), evaluatedWith: preview)
            waitForExpectations(timeout: 10)
            XCTAssertEqual(preview.frame.width / preview.frame.height, 16 / 9.0, accuracy: 0.015)
            XCTAssertGreaterThan(preview.frame.width, app.frame.width * 0.95)
            XCTAssertLessThan(preview.frame.height, app.frame.height * 0.4)
            XCTAssertGreaterThanOrEqual(preview.frame.minY - app.buttons["recorder.settings"].frame.maxY, 11,
                                        "A wide selfie leaves enough space for the whole toolbar above the picture")
            for button in [app.buttons["Projects"], app.buttons["recorder.record"], app.buttons["Edit this project"]] {
                XCTAssertGreaterThanOrEqual(button.frame.minY - preview.frame.maxY, 11,
                                            "The capture group fits beneath the landscape selfie")
            }
            if attempt == 1 {
                // Adding, bypassing and clearing an effect must leave a raw
                // landscape preview visible, even when the chain becomes empty.
                app.buttons["recorder.videoEffects"].tap()
                openEffectSection("colorStyle", in: app, live: true)
                app.buttons["liveEffects.add.silentTint"].tap()
                let disable = app.buttons["Disable effect"]
                XCTAssertTrue(disable.waitForExistence(timeout: 10)); disable.tap()
                backFromLiveEffects(in: app)
                let clear = app.buttons["liveEffects.actions"]
                XCTAssertTrue(clear.waitForExistence(timeout: 5)); clearLiveEffects(in: app)
                dismissLiveEffects(in: app)
            }
            // Geometry alone could pass with a cropped or hidden image. Inspect
            // all four colored edges of the synthetic camera buffer on screen.
            let ready = NSPredicate { _, _ in
                let shot = app.screenshot().image
                guard let cg = shot.cgImage else { return false }
                let scale = CGFloat(cg.width) / app.frame.width
                func rgb(_ x: CGFloat, _ y: CGFloat) -> [UInt8] {
                    let point = CGPoint(x: preview.frame.minX + x * preview.frame.width,
                                        y: preview.frame.minY + y * preview.frame.height)
                    guard let pixel = cg.cropping(to: CGRect(x: point.x * scale, y: point.y * scale, width: 1, height: 1)) else { return [] }
                    var values = [UInt8](repeating: 0, count: 4)
                    let color = CGColorSpace(name: CGColorSpace.sRGB)!
                    let context = CGContext(data: &values, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                            space: color, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                    context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                    return values
                }
                let left = rgb(0.025, 0.5), right = rgb(0.975, 0.5), top = rgb(0.5, 0.025), bottom = rgb(0.5, 0.975)
                guard [left, right, top, bottom].allSatisfy({ $0.count == 4 }) else { return false }
                return left[0] > 180 && left[1] < 80 && left[2] < 80
                    && right[2] > 180 && right[0] < 80 && right[1] < 80
                    && top[1] > 180 && top[0] < 80 && top[2] < 80
                    && bottom[0] > 180 && bottom[1] > 180 && bottom[2] < 80
            }
            expectation(for: ready, evaluatedWith: app); waitForExpectations(timeout: 20)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Full landscape selfie \(attempt + 1)"; screenshot.lifetime = .keepAlways; add(screenshot)
            camera.tap(); app.buttons["Front ultrawide (portrait)"].tap()
            XCTAssertEqual(camera.value as? String, "Front ultrawide (portrait)")
            expectation(for: NSPredicate(format: "value != %@", "Landscape, entire recorded frame"), evaluatedWith: preview)
            waitForExpectations(timeout: 10)
            XCTAssertGreaterThan(preview.frame.height, app.frame.height * 0.8)
            let nativePreview = NSPredicate { _, _ in
                guard let image = preview.screenshot().image.cgImage,
                      let pixel = image.cropping(to: CGRect(x: image.width / 2, y: image.height / 2, width: 1, height: 1)) else { return false }
                var rgba = [UInt8](repeating: 0, count: 4)
                let context = CGContext(data: &rgba, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                return rgba[0] < 20 && rgba[1] < 20 && rgba[2] < 20
            }
            expectation(for: nativePreview, evaluatedWith: preview); waitForExpectations(timeout: 10)
        }
    }

    func testMultiSelectionLinkAndDelete() throws {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--multiselect-fixture"]; app.launch()
        let play = app.buttons["Play"]
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 45)
        app.buttons["Timeline view span"].tap(); app.buttons["Whole project"].tap()
        let timeline = app.otherElements["editor.timeline"]
        let first = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.27))
        let middle = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.27))
        let last = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.27))
        app.buttons["Link"].tap()
        XCTAssertTrue(app.alerts["Editor"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts.staticTexts.containing(NSPredicate(format: "label CONTAINS 'long-press'")).firstMatch.exists)
        app.alerts.buttons["OK"].tap()
        first.tap(); middle.press(forDuration: 0.65)
        XCTAssertTrue((timeline.value as? String ?? "").contains("2 videos + 2 audio parts"))
        app.buttons["Link"].tap()
        XCTAssertTrue(app.buttons["Unlink"].waitForExistence(timeout: 15))
        app.buttons["editor.clearSelection"].tap(); middle.tap()
        XCTAssertTrue((timeline.value as? String ?? "").contains("2 videos + 2 audio parts"), "Tap selects the glued sequence")
        app.buttons["Delete selection"].tap()
        XCTAssertEqual(app.staticTexts["editor.duration"].label, "0:06.00")
        app.buttons["Undo"].tap()
        XCTAssertEqual(app.staticTexts["editor.duration"].label, "0:18.00")
        app.buttons["Undo"].tap()
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 30)
        first.tap(); last.press(forDuration: 0.65)
        app.buttons["Link"].tap()
        XCTAssertTrue(app.alerts.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Non-contiguous'")).firstMatch.waitForExistence(timeout: 5))
        app.alerts.buttons["OK"].tap()
        last.press(forDuration: 0.65)
        XCTAssertTrue((timeline.value as? String ?? "").contains("1 video + 1 audio part"), "Long-press removes just the other group")
        let magnet = app.descendants(matching: .any)["editor.snap"]
        let initial = magnet.value as? String
        magnet.tap(); XCTAssertNotEqual(magnet.value as? String, initial)
        magnet.tap(); XCTAssertEqual(magnet.value as? String, initial)
        app.buttons["Move"].tap()
        XCTAssertTrue(magnet.isEnabled && magnet.isHittable)
        magnet.tap(); XCTAssertNotEqual(magnet.value as? String, initial)
        magnet.tap()
        app.buttons["Cancel"].tap()
        let portrait = XCTAttachment(screenshot: app.screenshot()); portrait.name = "Multiple selection and magnet portrait"; portrait.lifetime = .keepAlways; add(portrait)
        XCUIDevice.shared.orientation = .landscapeLeft
        // Hittable can still describe the old portrait layout during rotation.
        // Wait for the actual window geometry, then exercise the relocated icon.
        expectation(for: NSPredicate { _, _ in
            app.frame.width > app.frame.height && magnet.isHittable && app.frame.contains(magnet.frame)
        }, evaluatedWith: app); waitForExpectations(timeout: 10)
        magnet.tap(); XCTAssertNotEqual(magnet.value as? String, initial)
        magnet.tap(); XCTAssertEqual(magnet.value as? String, initial)
        // Capture the screen: app.screenshot() crops against stale portrait
        // coordinates on this simulator after a window rotation.
        let landscape = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); landscape.name = "Multiple selection and magnet landscape"; landscape.lifetime = .keepAlways; add(landscape)
        XCUIDevice.shared.orientation = .portrait
    }

    private func clipboardEditor() -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["YOUREC_EDITOR_FIXTURE_TITLE"] = "Clipboard workflow · UI test"
        app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--multiselect-fixture"]
        app.launch()
        let span = app.buttons["Timeline view span"]
        XCTAssertTrue(span.waitForExistence(timeout: 30))
        span.tap(); app.buttons["Whole project"].tap()
        return app
    }

    private func clipboardDuration(_ label: String, in app: XCUIApplication) {
        expectation(for: NSPredicate(format: "label == %@", label), evaluatedWith: app.staticTexts["editor.duration"])
        waitForExpectations(timeout: 12)
    }

    func testClipboardCopyIntoCutsAndBothEnds() {
        let app = clipboardEditor(), paste = app.buttons["editor.paste"]
        func item(_ n: Int) -> XCUIElement { app.buttons["timeline.video.\(n)"] }
        XCTAssertFalse(paste.exists || app.buttons["Move here"].exists)
        app.buttons["timeline.add.end"].tap(); XCTAssertFalse(app.buttons["addVideo.pasteHere"].exists)
        XCTAssertTrue(app.buttons["From Photos"].isHittable); app.buttons["Cancel"].tap()
        app.buttons["Next change"].tap()
        XCTAssertTrue(app.buttons["editor.transition"].isHittable); XCTAssertFalse(paste.exists)
        item(3).tap(); item(1).press(forDuration: 0.65)
        XCTAssertTrue(item(1).isSelected && item(3).isSelected && !paste.exists)
        let copy = app.buttons["editor.copy"], cut = app.buttons["editor.cut"], trash = app.buttons["Delete selection"]
        defer { XCUIDevice.shared.orientation = .portrait }
        for orientation in [UIDeviceOrientation.portrait, .landscapeRight] {
            XCUIDevice.shared.orientation = orientation
            expectation(for: NSPredicate { _, _ in
                let window = app.windows.firstMatch.frame
                return (window.width > window.height) == orientation.isLandscape && copy.isHittable && cut.isHittable && trash.isHittable
            }, evaluatedWith: app)
            waitForExpectations(timeout: 10)
            for button in [copy, cut] {
                XCTAssertGreaterThanOrEqual(button.frame.width, 44)
                XCTAssertGreaterThanOrEqual(button.frame.height, 44)
            }
            XCTAssertEqual(copy.frame.minY, cut.frame.minY, accuracy: 0.5)
            XCTAssertEqual(copy.frame.height, cut.frame.height, accuracy: 0.5)
            XCTAssertLessThanOrEqual(copy.frame.maxX, cut.frame.minX)
            XCTAssertLessThanOrEqual(cut.frame.maxX, trash.frame.minX)
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = orientation.isLandscape ? "Copy and Cut in landscape" : "Copy and Cut in portrait"
            shot.lifetime = .keepAlways; add(shot)
            if orientation == .portrait {
                let row = app.scrollViews.containing(.button, identifier: "editor.copy").firstMatch
                let detail = XCTAttachment(screenshot: row.screenshot())
                detail.name = "Selection toolbar"; detail.lifetime = .keepAlways; add(detail)
            }
        }
        copy.tap(); clipboardDuration("0:18.00", in: app)
        XCUIDevice.shared.orientation = .portrait
        expectation(for: NSPredicate { _, _ in app.windows.firstMatch.frame.width < app.windows.firstMatch.frame.height && paste.isHittable }, evaluatedWith: app)
        waitForExpectations(timeout: 10)
        XCTAssertFalse(item(1).isSelected); XCTAssertTrue(paste.isHittable && app.buttons["editor.transition"].isHittable)
        paste.tap(); clipboardDuration("0:30.00", in: app)
        XCTAssertTrue(item(2).isSelected && item(3).isSelected)
        app.buttons["Undo"].tap(); clipboardDuration("0:18.00", in: app)
        for side in ["end","start"] {
            app.buttons["timeline.add." + side].tap()
            let edgePaste = app.buttons["addVideo.pasteHere"]
            XCTAssertTrue(edgePaste.isHittable); XCTAssertTrue(app.buttons["editor.recordHere"].isHittable)
            edgePaste.tap(); clipboardDuration("0:30.00", in: app)
            XCTAssertEqual(app.staticTexts["editor.playhead"].label, side == "end" ? "0:18.00" : "0:00.00")
            app.buttons["Undo"].tap(); clipboardDuration("0:18.00", in: app)
        }
        app.buttons["Clear clipboard"].tap(); XCTAssertFalse(paste.exists)
    }

    func testSplitClearsSelectionAndCutsAtThePlayhead() {
        let app = clipboardEditor()
        let split = app.buttons["Split"], clear = app.buttons["editor.clearSelection"]
        let fourthVideo = app.buttons["timeline.video.4"], fourthAudio = app.buttons["timeline.audio.4"]
        func cutMiddleClip() {
            seekTimeline(fraction: 0.5, in: app)
            let playhead = app.staticTexts["editor.playhead"].label
            XCTAssertTrue(clear.exists)
            split.tap()
            XCTAssertTrue(fourthVideo.waitForExistence(timeout: 5))
            XCTAssertTrue(fourthAudio.exists)
            XCTAssertFalse(clear.exists)
            XCTAssertTrue(app.buttons["Mark start"].exists)
            XCTAssertEqual(app.staticTexts["editor.playhead"].label, playhead)
            XCTAssertEqual(app.staticTexts["editor.duration"].label, "0:18.00")
            app.buttons["Undo"].tap()
            XCTAssertTrue(fourthVideo.waitForNonExistence(timeout: 5))
            XCTAssertFalse(fourthAudio.exists)
        }

        app.buttons["timeline.video.1"].tap()
        app.buttons["timeline.video.3"].press(forDuration: 0.65)
        XCTAssertTrue(app.buttons["timeline.video.1"].isSelected && app.buttons["timeline.video.3"].isSelected)
        cutMiddleClip()

        app.buttons["timeline.video.1"].tap()
        seekTimeline(fraction: 0.08, in: app); app.buttons["Mark start"].tap()
        seekTimeline(fraction: 0.22, in: app); app.buttons["Mark end"].tap()
        cutMiddleClip()

        app.buttons["timeline.audio.1"].tap()
        app.buttons["Mark start"].tap()
        cutMiddleClip()
    }

    func testDismissingSelectionPreservesPlayback() {
        let app = clipboardEditor()
        let clip = app.buttons["timeline.video.1"]
        clip.tap()
        app.buttons["Play"].tap()
        let pause = app.buttons["Pause playback"]
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        let clear = app.buttons["editor.clearSelection"]
        if !clear.isHittable { app.scrollViews.containing(.button, identifier: "editor.copy").firstMatch.swipeLeft() }
        clear.tap()
        XCTAssertFalse(clear.exists)
        XCTAssertTrue(pause.isHittable)
        let playhead = app.staticTexts["editor.playhead"]
        let after = playhead.label
        expectation(for: NSPredicate(format: "label != %@", after), evaluatedWith: playhead)
        waitForExpectations(timeout: 3)
        pause.tap()
        clip.tap()
        app.buttons["editor.clearSelection"].tap()
        XCTAssertTrue(app.buttons["Play"].isHittable)
    }

    func testClipboardCutRangeAndEmptyTimeline() {
        let app = clipboardEditor(), paste = app.buttons["editor.paste"]
        app.buttons["Mark start"].tap()
        XCTAssertFalse(app.buttons["editor.cut"].isEnabled || app.buttons["editor.copy"].isEnabled)
        seekTimeline(fraction: 0.25, in: app); app.buttons["Mark end"].tap()
        app.buttons["editor.cut"].tap(); XCTAssertTrue(paste.waitForExistence(timeout: 8))
        let shorter = app.staticTexts["editor.duration"].label
        XCTAssertNotEqual(shorter, "0:18.00")
        seekTimeline(fraction: 0.5, in: app)
        paste.tap(); clipboardDuration("0:18.00", in: app)
        app.buttons["Undo"].tap(); clipboardDuration(shorter, in: app)
        app.buttons["Undo"].tap(); clipboardDuration("0:18.00", in: app)

        // Refit after Undo restores a longer timeline. The waveform row also
        // stays clear of the time-span control over the final thumbnail.
        app.buttons["Timeline view span"].tap(); app.buttons["Whole project"].tap()
        app.buttons["timeline.audio.1"].tap()
        for n in 2...3 { app.buttons["timeline.audio.\(n)"].press(forDuration: 0.65) }
        for n in 1...3 { XCTAssertTrue(app.buttons["timeline.video.\(n)"].isSelected) }
        app.buttons["editor.cut"].tap(); clipboardDuration("0:00.00", in: app)
        XCTAssertTrue(paste.isHittable); paste.tap(); clipboardDuration("0:18.00", in: app)
        app.buttons["Undo"].tap(); clipboardDuration("0:00.00", in: app)
        app.buttons["Redo"].tap(); clipboardDuration("0:18.00", in: app)
        app.buttons["Export"].tap()
        let export = app.buttons["Export video"]
        XCTAssertTrue(export.waitForExistence(timeout: 12)); export.tap()
        XCTAssertTrue(app.buttons["Save to Photos"].waitForExistence(timeout: 120))
    }

    func testClipboardPasteAtDissolve() {
        let app = clipboardEditor()
        app.buttons["timeline.video.3"].tap(); app.buttons["editor.copy"].tap()
        app.buttons["Next change"].tap()
        app.buttons["editor.transition"].tap()
        selectTransitionStyle("dissolve", in: app)
        let apply = app.buttons["transition.apply"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: apply); waitForExpectations(timeout: 30)
        apply.tap()
        let badge = app.buttons["timeline.transition.1"]
        XCTAssertTrue(badge.waitForExistence(timeout: 15)); badge.tap()
        let paste = app.buttons["editor.paste"]
        XCTAssertEqual(paste.value as? String, "Replaces transition")
        paste.tap(); clipboardDuration("0:24.00", in: app)
        XCTAssertFalse(badge.exists)
        app.buttons["Undo"].tap(); XCTAssertTrue(badge.waitForExistence(timeout: 12))
    }

    func testClipboardDetachedAudioDestination() {
        let app = clipboardEditor()
        for n in 1...3 {
            app.buttons["timeline.video.\(n)"].tap(); app.buttons["Unlink"].tap()
            expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: app.buttons["Play"]); waitForExpectations(timeout: 20)
        }
        app.buttons["editor.clearSelection"].tap()
        app.buttons["timeline.audio.3"].tap(); app.buttons["editor.copy"].tap()
        app.buttons["Next change"].tap()
        for picture in [true, false] {
            app.buttons["editor.paste"].tap()
            app.buttons[picture ? "Video · V1 | V2" : "Audio · A1 | A2"].tap()
            clipboardDuration(picture ? "0:18.00" : "0:24.00", in: app)
            let audio = app.buttons["timeline.audio.4"]
            XCTAssertTrue(audio.isSelected); XCTAssertTrue((audio.value as? String ?? "").hasPrefix("6.000 "))
            XCTAssertTrue((app.buttons["timeline.audio.2"].value as? String ?? "").hasPrefix(picture ? "6.000 " : "12.000 "))
            XCTAssertTrue((app.buttons["timeline.video.2"].value as? String ?? "").hasPrefix("6.000 "))
            app.buttons["Undo"].tap(); XCTAssertFalse(audio.exists)
        }
    }

    private func checkMoveButtonLayout(in app: XCUIApplication) {
        let left = app.buttons["move.previous"].frame
        let right = app.buttons["move.next"].frame
        let target = app.buttons["move.choose"].frame
        XCTAssertEqual(left.width, 44, accuracy: 0.5)
        XCTAssertEqual(left.height, 48, accuracy: 0.5)
        for frame in [right, target] {
            XCTAssertEqual(frame.width, left.width, accuracy: 0.5)
            XCTAssertEqual(frame.height, left.height, accuracy: 0.5)
            XCTAssertEqual(frame.midY, left.midY, accuracy: 0.5)
        }
        let gap = right.minX - left.maxX
        XCTAssertEqual(gap, 6, accuracy: 0.5)
        XCTAssertEqual(target.minX - right.maxX, gap, accuracy: 0.5)
    }

    func testMoveByCutAndChooseTimelineBoundary() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--multiselect-fixture", "--move-snap-fixture"]
        app.launch()
        let play = app.buttons["Play"], chooser = app.buttons["move.choose"], previous = app.buttons["move.previous"], next = app.buttons["move.next"]
        func ready() {
            XCTAssertTrue(play.waitForExistence(timeout: 30))
            expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 30)
        }
        func item(_ n: Int, _ kind: String = "video") -> XCUIElement { app.buttons["timeline.\(kind).\(n)"] }
        func time(_ n: Int, _ kind: String = "video") -> Double {
            Double((item(n, kind).value as? String ?? "").components(separatedBy: " to ")[0]) ?? -1
        }
        func fit() { app.buttons["Timeline view span"].tap(); app.buttons["Whole project"].tap() }
        func shot(_ name: String) {
            let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image)
        }
        ready(); fit()
        let magnet = app.descendants(matching: .any)["editor.snap"]
        let wasOn = magnet.value as? String == "On"
        if wasOn { magnet.tap() }
        defer { if wasOn && magnet.exists && magnet.value as? String == "Off" { magnet.tap() } }
        item(2).tap(); app.buttons["Move"].tap()
        checkMoveButtonLayout(in: app)
        next.tap(); XCTAssertEqual(time(2), 14); XCTAssertEqual(time(2, "audio"), 14)
        next.tap(); XCTAssertFalse(next.isEnabled); XCTAssertEqual(app.staticTexts["editor.playhead"].label, "0:20.00")
        XCTAssertEqual(app.staticTexts["editor.duration"].label, "0:26.00")
        previous.tap(); previous.tap(); XCTAssertEqual(time(2), 6); previous.tap(); XCTAssertFalse(previous.isEnabled)
        chooser.tap()
        let prompt = app.descendants(matching: .any)["move.destinationPrompt"].firstMatch
        XCTAssertTrue(prompt.label.contains("Tap a dashed cyan line on the timeline"))
        XCTAssertTrue(prompt.label.contains("Your selection will start there."))
        XCTAssertFalse(prompt.frame.intersects(app.buttons["Back to Move"].frame))
        app.buttons["Back to Move"].tap(); XCTAssertEqual(time(2), 0, "Back only closes the chooser")
        chooser.tap(); fit()
        let target = app.buttons["timeline.moveBoundary.3360000"] // 14 seconds on the project edit clock.
        XCTAssertTrue(target.isHittable); shot("Pick a cut on the timeline")
        target.tap(); fit(); XCTAssertTrue(chooser.isHittable)
        XCTAssertEqual(time(2), 14); XCTAssertEqual(time(3), 14)
        shot("Move preview at a chosen cut")
        app.buttons["Cancel"].tap(); ready()
        XCTAssertEqual(time(2), 6); XCTAssertTrue(item(2).isSelected)
        XCTAssertEqual(app.staticTexts["editor.playhead"].label, "0:00.00")
        app.buttons["Move"].tap(); app.buttons["editor.moveScope.left"].tap()
        XCTAssertFalse(previous.isEnabled)
        chooser.tap(); target.tap(); app.buttons["Done"].tap(); ready(); fit()
        XCTAssertEqual(time(1), 8); XCTAssertEqual(time(2), 14); XCTAssertEqual(time(2, "audio"), 14); XCTAssertEqual(time(3), 14)
        app.buttons["Undo"].tap(); ready(); XCTAssertEqual(time(1), 0); XCTAssertEqual(time(2), 6)
        XCTAssertEqual(app.staticTexts["editor.playhead"].label, "0:00.00")
        app.buttons["Redo"].tap(); ready(); XCTAssertEqual(time(2), 14)
    }

    func testPickOffscreenCutForDetachedAudio() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--multiselect-fixture"]
        app.launch()
        let timeline = app.otherElements["editor.timeline"], span = app.buttons["Timeline view span"]
        XCTAssertTrue(span.waitForExistence(timeout: 30))
        span.tap(); app.buttons["Whole project"].tap()
        app.buttons["timeline.video.3"].tap(); app.buttons["Unlink"].tap()
        let play = app.buttons["Play"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 25)
        app.buttons["timeline.audio.3"].tap()
        XCTAssertTrue(app.buttons["timeline.audio.3"].isSelected); XCTAssertFalse(app.buttons["timeline.video.3"].isSelected)
        app.buttons["Move"].tap(); app.buttons["move.choose"].tap()
        span.tap(); app.buttons["10 seconds"].tap()
        let target = app.buttons["timeline.moveBoundary.1440000"]
        XCTAssertFalse(target.exists, "Six seconds is offscreen at this span with the playhead at zero")
        timeline.pinch(withScale: 1.5, velocity: 1)
        XCTAssertEqual(span.value as? String, "Custom")
        span.tap(); app.buttons["10 seconds"].tap()
        let from = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.7))
        let to = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.22, dy: 0.7))
        from.press(forDuration: 0.15, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.5)
        XCTAssertTrue(target.waitForExistence(timeout: 5)); target.tap()
        XCTAssertEqual(app.descendants(matching: .any)["move.anchor"].value as? String, "0:06.00")
        app.buttons["Done"].tap()
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 25)
        span.tap(); app.buttons["Whole project"].tap()
        XCTAssertTrue((app.buttons["timeline.audio.3"].value as? String ?? "").hasPrefix("6.000 "))
        XCTAssertTrue((app.buttons["timeline.video.3"].value as? String ?? "").hasPrefix("12.000 "))
        app.buttons["Undo"].tap()
        XCTAssertTrue((app.buttons["timeline.audio.3"].value as? String ?? "").hasPrefix("12.000 "))
    }

    func testChooseBetweenSubframeMoveBoundaries() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--multiselect-fixture", "--close-move-cuts-fixture"]
        app.launch()
        let play = app.buttons["Play"]
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 30)
        app.buttons["Timeline view span"].tap(); app.buttons["Whole project"].tap()
        app.buttons["timeline.video.1"].tap(); app.buttons["Move"].tap()
        XCUIDevice.shared.orientation = .landscapeRight
        expectation(for: NSPredicate { _, _ in app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height && app.buttons["move.choose"].isHittable }, evaluatedWith: app)
        waitForExpectations(timeout: 10)
        checkMoveButtonLayout(in: app)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "Move buttons in landscape"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["move.choose"].tap()
        // Refit to the wider viewport so both subframe neighbors occupy one marker.
        app.buttons["Timeline view span"].tap(); app.buttons["Whole project"].tap()
        app.buttons["timeline.moveBoundary.2880000"].tap()
        XCTAssertTrue(app.navigationBars["Choose a start time"].waitForExistence(timeout: 5))
        let subframe = app.buttons["move.choice.2880001"]
        XCTAssertTrue(subframe.isHittable); XCTAssertNotEqual(subframe.label, app.buttons["move.choice.2880000"].label)
        subframe.tap()
        let anchor = app.descendants(matching: .any)["move.anchor"]
        expectation(for: NSPredicate(format: "value == %@", "0:12.000004"), evaluatedWith: anchor); waitForExpectations(timeout: 8)
        app.buttons["move.previous"].tap(); XCTAssertEqual(anchor.value as? String, "0:12.000000")
        app.buttons["Cancel"].tap()
    }

    func testMoveScopeBarMovesContiguousClipsAndRestoresSelection() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--multiselect-fixture"]
        app.launch()
        let timeline = app.otherElements["editor.timeline"]
        let move = app.buttons["Move"], export = app.buttons["Export"]
        func scope(_ name: String) -> XCUIElement { app.buttons["editor.moveScope." + name] }
        func item(_ n: Int, _ kind: String = "video") -> XCUIElement { app.buttons["timeline.\(kind).\(n)"] }
        func start(_ n: Int, _ kind: String = "video") -> Double {
            let value = item(n, kind).value as? String ?? ""
            return Double(value.components(separatedBy: " to ")[0]) ?? -100
        }
        func ready() {
            let play = app.buttons["Play"]
            expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play)
            waitForExpectations(timeout: 30)
        }
        func shot(_ name: String) {
            let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            image.name = name; image.lifetime = .keepAlways; add(image)
        }
        XCTAssertTrue(export.waitForExistence(timeout: 25)); ready()
        app.buttons["Timeline view span"].tap(); app.buttons["Whole project"].tap()
        let magnet = app.descendants(matching: .any)["editor.snap"]
        if magnet.value as? String == "On" { magnet.tap() }
        item(2).tap(); move.tap()
        XCTAssertTrue(scope("selected").isSelected); XCTAssertFalse(export.exists)
        scope("both").tap()
        for i in 1...3 { XCTAssertTrue(item(i).isSelected); XCTAssertTrue(item(i, "audio").isSelected) }
        scope("right").tap(); XCTAssertFalse(item(1).isSelected); XCTAssertTrue(item(3).isSelected)
        shot("Move with right · portrait")
        XCUIDevice.shared.orientation = .landscapeRight
        expectation(for: NSPredicate { _, _ in app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height && scope("right").isHittable }, evaluatedWith: app)
        waitForExpectations(timeout: 10)
        shot("Move with right · landscape")
        XCUIDevice.shared.orientation = .portrait
        expectation(for: NSPredicate { _, _ in app.windows.firstMatch.frame.width < app.windows.firstMatch.frame.height && scope("right").isHittable }, evaluatedWith: app)
        waitForExpectations(timeout: 10)
        let middle = item(2).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let scale = (timeline.frame.width - 96) / 18
        middle.press(forDuration: 0.1, thenDragTo: middle.withOffset(CGVector(dx: 2 * scale, dy: 0)))
        let delta = start(2) - 6
        XCTAssertEqual(delta, 2, accuracy: 0.15)
        XCTAssertEqual(start(3, "audio"), 12 + delta, accuracy: 0.002)
        scope("left").tap()
        XCTAssertTrue(item(1).isSelected); XCTAssertFalse(item(3).isSelected)
        XCTAssertEqual(start(1), delta, accuracy: 0.002); XCTAssertEqual(start(3), 12, accuracy: 0.002)
        app.buttons["Done"].tap(); ready()
        XCTAssertTrue(export.isHittable); XCTAssertEqual(start(1, "audio"), delta, accuracy: 0.002)
        app.buttons["Undo"].tap(); ready()
        XCTAssertEqual(start(1), 0); XCTAssertEqual(start(2), 6); XCTAssertEqual(start(3), 12)

        item(2).tap(); move.tap()
        XCTAssertTrue(scope("selected").isSelected)
        app.buttons["move.previous"].tap()
        scope("left").tap(); XCTAssertEqual(start(2), 6)
        scope("selected").tap(); XCTAssertEqual(start(2), 0, accuracy: 0.001)
        app.buttons["Cancel"].tap(); ready(); XCTAssertEqual(start(2), 6)
    }

    func testMoveOverlapKeepsBothLanesDuringDragAndAfterReopen() throws {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--multiselect-fixture"]
        app.launch()
        let play = app.buttons["Play"], timeline = app.otherElements["editor.timeline"]
        func ready() {
            XCTAssertTrue(play.waitForExistence(timeout: 30))
            expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play)
            waitForExpectations(timeout: 45)
        }
        func lanes(_ video: Int, _ audio: Int) {
            XCTAssertTrue((timeline.value as? String ?? "").contains("\(video) video lanes, \(audio) audio lanes"), String(describing: timeline.value))
        }
        func shot(_ name: String) {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = name; shot.lifetime = .keepAlways; add(shot)
        }
        ready()
        app.buttons["Timeline view span"].tap(); app.buttons["Whole project"].tap()
        let magnet = app.descendants(matching: .any)["editor.snap"]
        if magnet.value as? String == "On" { magnet.tap() }
        lanes(1, 1)
        let from = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.27))
        from.tap(); app.buttons["Move"].tap()
        let scale = (timeline.frame.width - 96) / 18
        from.press(forDuration: 0.1, thenDragTo: from.withOffset(CGVector(dx: -3 * scale, dy: 0)))
        shot("Move draft must show both overlapping pictures")
        lanes(2, 2)
        let moved = app.buttons["timeline.video.2"]
        let start = Double((moved.value as? String ?? "").components(separatedBy: " to ")[0]) ?? -1
        XCTAssertEqual(start, 3, accuracy: 1.0 / 30, "Move includes the initial touch recognition distance")
        for kind in ["video", "audio"] { for number in 1...2 {
            let card = app.buttons["timeline.\(kind).\(number)"]
            XCTAssertTrue(card.exists); XCTAssertGreaterThanOrEqual(card.frame.height, 30, "Both overlapping pictures and waveforms must be visibly usable")
            XCTAssertTrue(timeline.frame.contains(card.frame), "Visible card frame stays inside the timeline")
        } }
        app.buttons["Done"].tap(); ready(); lanes(2, 2)
        shot("Committed overlap keeps both pictures")
        XCTAssertEqual(app.staticTexts["editor.duration"].label, "0:18.00")
        app.buttons["Undo"].tap(); ready(); lanes(1, 1)
        app.buttons["Redo"].tap(); ready(); lanes(2, 2)
        app.terminate(); app.launchArguments = ["--editor-preview"]; app.launch(); ready(); lanes(2, 2)
        shot("Overlap survives reopen")
    }

    func testMoveRepeatedDragsCancelAndDeleteReveal() throws {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--multiselect-fixture"]; app.launch()
        let play = app.buttons["Play"], timeline = app.otherElements["editor.timeline"]
        func ready() {
            XCTAssertTrue(play.waitForExistence(timeout: 30))
            expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 45)
        }
        func lanes(_ video: Int, _ audio: Int) {
            XCTAssertTrue((timeline.value as? String ?? "").contains("\(video) video lanes, \(audio) audio lanes"), String(describing: timeline.value))
        }
        func point(_ time: Double, row: Int = 0) -> XCUICoordinate {
            timeline.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 48 + time * (timeline.frame.width - 96) / 18, dy: 20 + Double(row) * 46 + 23))
        }
        func drag(_ from: Double, _ to: Double) { point(from).press(forDuration: 0.1, thenDragTo: point(to)) }
        ready(); app.buttons["Timeline view span"].tap(); app.buttons["Whole project"].tap()
        let magnet = app.descendants(matching: .any)["editor.snap"]
        if magnet.value as? String == "On" { magnet.tap() }
        point(9).tap(); app.buttons["Unlink"].tap(); ready()
        point(9).tap(); app.buttons["Move"].tap()
        drag(9, 6); lanes(2, 1)
        // A second drag uses the moved item's new row/position and accumulates.
        drag(6, 5); lanes(2, 1)
        app.buttons["Cancel"].tap(); ready(); lanes(1, 1)
        XCTAssertEqual(app.staticTexts["editor.duration"].label, "0:18.00")
        app.buttons["Move"].tap(); drag(9, 6); lanes(2, 1)
        app.buttons["Done"].tap(); ready(); lanes(2, 1)
        // Select the lower picture beneath the overlap, and move it too.
        point(4, row: 1).tap(); app.buttons["Move"].tap()
        let lower = app.buttons["timeline.video.1"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        lower.press(forDuration: 0.1, thenDragTo: lower.withOffset(CGVector(dx: (timeline.frame.width - 96) / 18, dy: 0)))
        lanes(2, 2)
        app.buttons["Cancel"].tap(); ready(); lanes(2, 1)
        // The overlay alone is detached. Deleting it must expose the lower
        // picture, keep all audio, and preserve project timing.
        point(6).tap(); app.buttons["Delete, leave gap"].tap(); ready(); lanes(1, 1)
        XCTAssertEqual(app.staticTexts["editor.duration"].label, "0:18.00")
        app.buttons["Undo"].tap(); ready(); lanes(2, 1)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Repeated moves and delete Undo preserve both pictures"; shot.lifetime = .keepAlways; add(shot)
    }

    func testRangeMoveCancelAndTrimIntoOverlap() throws {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--multiselect-fixture"]; app.launch()
        let play = app.buttons["Play"], timeline = app.otherElements["editor.timeline"]
        func ready() {
            XCTAssertTrue(play.waitForExistence(timeout: 30))
            expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 45)
        }
        func point(_ time: Double, y: Double) -> XCUICoordinate {
            timeline.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 48 + time * (timeline.frame.width - 96) / 18, dy: y))
        }
        func lanes(_ video: Int) { XCTAssertTrue((timeline.value as? String ?? "").contains("\(video) video lanes"), String(describing: timeline.value)) }
        ready(); app.buttons["Timeline view span"].tap(); app.buttons["Whole project"].tap()
        let magnet = app.descendants(matching: .any)["editor.snap"]
        if magnet.value as? String == "On" { magnet.tap() }
        point(9, y: 43).tap()
        point(7, y: 10).tap(); app.buttons["Mark start"].tap()
        point(10, y: 10).tap(); app.buttons["Mark end"].tap()
        app.buttons["Move"].tap()
        point(8.5, y: 43).press(forDuration: 0.1, thenDragTo: point(4.5, y: 43)); lanes(2)
        app.buttons["Cancel"].tap(); ready(); lanes(1)
        XCTAssertTrue((timeline.value as? String ?? "").contains("Range"), "Cancel restores the marked scope")
        app.buttons["Move"].tap()
        point(8.5, y: 43).press(forDuration: 0.1, thenDragTo: point(4.5, y: 43)); lanes(2)
        app.buttons["Done"].tap(); ready(); lanes(2)
        XCTAssertEqual(app.staticTexts["editor.duration"].label, "0:18.00")
        app.buttons["Undo"].tap(); ready(); lanes(1)
        // Extending an edge reveals source footage; it must create a second
        // lane, rather than erase or silently trim the neighboring item.
        point(3, y: 43).tap()
        point(6, y: 43).press(forDuration: 0.1, thenDragTo: point(7.5, y: 43)); ready(); lanes(2)
        let end = Double((app.buttons["timeline.video.1"].value as? String ?? "").components(separatedBy: " to ").last?.components(separatedBy: " ")[0] ?? "") ?? -1
        XCTAssertEqual(end, 7.5, accuracy: 0.06, "Trim includes the initial touch recognition distance")
        XCTAssertEqual(app.staticTexts["editor.duration"].label, "0:18.00")
        app.buttons["Undo"].tap(); ready(); lanes(1)
        app.buttons["Redo"].tap(); ready(); lanes(2)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Trim extension creates an editable overlap"; shot.lifetime = .keepAlways; add(shot)
    }

    func testMoveBuildsThreeLayersAndPlacementCanEditThem() throws {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--multiselect-fixture"]; app.launch()
        let play = app.buttons["Play"], timeline = app.otherElements["editor.timeline"]
        func ready() {
            XCTAssertTrue(play.waitForExistence(timeout: 30))
            expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 45)
        }
        func point(_ time: Double) -> XCUICoordinate {
            timeline.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 48 + time * (timeline.frame.width - 96) / 18, dy: 43))
        }
        func lanes(_ count: Int) { XCTAssertTrue((timeline.value as? String ?? "").contains("\(count) video lanes, \(count) audio lanes"), String(describing: timeline.value)) }
        ready(); app.buttons["Timeline view span"].tap(); app.buttons["Whole project"].tap()
        let magnet = app.descendants(matching: .any)["editor.snap"]
        if magnet.value as? String == "On" { magnet.tap() }
        for (from, to, count) in [(9.0, 5.0, 2), (15.0, 6.0, 3)] {
            point(from).tap(); app.buttons["Move"].tap()
            point(from).press(forDuration: 0.1, thenDragTo: point(to)); lanes(count)
            app.buttons["Done"].tap(); ready(); lanes(count)
        }
        for kind in ["video", "audio"] { for number in 1...3 {
            let card = app.buttons["timeline.\(kind).\(number)"]
            XCTAssertTrue(card.exists); XCTAssertGreaterThanOrEqual(card.frame.height, 30)
            XCTAssertTrue(timeline.frame.contains(card.frame), "All six cards fit the portrait timeline")
        } }
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Three layers created using public Move gestures"; shot.lifetime = .keepAlways; add(shot)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["Show more timeline lanes"].waitForExistence(timeout: 10), "Compact landscape keeps overflow audio discoverable")
        app.buttons["Show more timeline lanes"].tap()
        XCTAssertGreaterThanOrEqual(app.buttons["timeline.audio.1"].frame.height, 30, "Overflow control reveals the bottom waveform")
        XCUIDevice.shared.orientation = .portrait
        expectation(for: NSPredicate { _, _ in app.frame.height > app.frame.width }, evaluatedWith: app); waitForExpectations(timeout: 10)
        app.buttons["Full"].tap(); app.sliders["Full preview position"].adjust(toNormalizedSliderPosition: 0.5); app.buttons["Done"].tap()
        openTimelinePlacement(in: app)
        XCTAssertTrue(app.buttons["Layout"].waitForExistence(timeout: 30))
        app.buttons["Layout"].tap(); app.buttons["Side by side"].tap()
        app.buttons["Apply"].tap(); ready(); lanes(3)
        app.buttons["Undo"].tap(); ready(); lanes(3)
        app.buttons["Undo"].tap(); ready(); lanes(2)
        app.buttons["Redo"].tap(); ready(); lanes(3)
        app.terminate(); app.launchArguments = ["--editor-preview"]; app.launch(); ready(); lanes(3)
    }

    func testMoveSnapsNeighborAndCanBeDisabled() throws {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--multiselect-fixture", "--move-snap-fixture"]; app.launch()
        let play = app.buttons["Play"]
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 45)
        app.buttons["Timeline view span"].tap(); app.buttons["Whole project"].tap()
        let timeline = app.otherElements["editor.timeline"]
        let magnet = app.descendants(matching: .any)["editor.snap"]
        if magnet.value as? String != "On" { magnet.tap() }
        for snapped in [true, false] {
            let from = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.83, dy: 0.27))
            from.tap(); app.buttons["Move"].tap()
            if !snapped { magnet.tap() }
            let scale = (timeline.frame.width - 96) / 20
            let to = from.withOffset(CGVector(dx: -2.3 * scale, dy: 0))
            from.press(forDuration: 0.1, thenDragTo: to)
            if snapped { XCTAssertTrue((timeline.value as? String ?? "").contains("Snapped at 12.00"), String(describing: timeline.value)) }
            else { XCTAssertFalse((timeline.value as? String ?? "").contains("Snapped at")) }
            app.buttons["Done"].tap()
            expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 30)
            if snapped { XCTAssertEqual(app.staticTexts["editor.duration"].label, "0:18.00", "Move closes the gap exactly") }
            else { XCTAssertNotEqual(app.staticTexts["editor.duration"].label, "0:18.00", "Snap off preserves free placement") }
            app.buttons["Undo"].tap()
            expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 30)
            XCTAssertEqual(app.staticTexts["editor.duration"].label, "0:20.00")
        }
        magnet.tap()
    }

    func testSnappedFractionalBoundaryShowsVideo() throws {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--subtitles-ui-fixture", "--multiselect-fixture", "--move-snap-fixture", "--fractional-snap-fixture"]
        app.launch()
        let play = app.buttons["Play"], timeline = app.otherElements["editor.timeline"]
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 30)
        app.buttons["Timeline view span"].tap(); app.buttons["Whole project"].tap()
        let magnet = app.descendants(matching: .any)["editor.snap"], wasOn = magnet.value as? String == "On"
        if !wasOn { magnet.tap() }
        let from = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.83, dy: 0.27))
        from.tap(); app.buttons["Move"].tap()
        let scale = (timeline.frame.width - 96) / 20
        from.press(forDuration: 0.1, thenDragTo: from.withOffset(CGVector(dx: -2.3 * scale, dy: 0)))
        XCTAssertTrue((timeline.value as? String ?? "").contains("Snapped at 12.00"))
        app.buttons["Done"].tap()
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 30)
        app.buttons["Timeline view span"].tap(); app.buttons["Whole project"].tap()
        for fraction in [0.2, 0.85, 0.4] {
            seekTimeline(fraction: fraction, in: app)
            seekTimeline(fraction: 12.0 / 18, in: app)
            XCTAssertEqual(app.staticTexts["editor.playhead"].label, "0:12.00")
            Thread.sleep(forTimeInterval: 0.4)
            let preview = app.otherElements["editor.preview"]
            let image = try XCTUnwrap(preview.screenshot().image.cgImage)
            let center = try XCTUnwrap(image.cropping(to: CGRect(x: image.width / 2 - 8, y: image.height / 2 - 8, width: 16, height: 16)))
            var rgb = [UInt8](repeating: 0, count: 4)
            let context = try XCTUnwrap(CGContext(data: &rgb, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.draw(center, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            XCTAssertGreaterThan(Int(rgb[0]) + Int(rgb[1]) + Int(rgb[2]), 30, "An exactly snapped cut must show picture, never black")
        }
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Exact snapped boundary has picture"; shot.lifetime = .keepAlways; add(shot)
        if !wasOn { magnet.tap() }
    }

    func testLinkIntersectionCancelApplyUndo() throws {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--link-intersection-fixture"]; app.launch()
        let play = app.buttons["Play"]
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 45)
        app.buttons["Timeline view span"].tap(); app.buttons["Whole project"].tap()
        let timeline = app.otherElements["editor.timeline"]
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.16, dy: 0.27)).tap()
        app.buttons["Link"].tap()
        XCTAssertTrue(app.alerts["Editor"].waitForExistence(timeout: 5)); app.alerts.buttons["OK"].tap()
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.43, dy: 0.27)).press(forDuration: 0.65)
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.70, dy: 0.27)).press(forDuration: 0.65)
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.55)).press(forDuration: 0.65)
        XCTAssertTrue((timeline.value as? String ?? "").contains("3 videos + 1 audio part"))
        app.buttons["Link"].tap()
        XCTAssertTrue(app.alerts["Link shared time only?"].waitForExistence(timeout: 5))
        app.alerts.buttons["Cancel"].tap()
        XCTAssertEqual(app.staticTexts["editor.duration"].label, "0:21.00")
        XCTAssertTrue((timeline.value as? String ?? "").contains("3 videos + 1 audio part"))
        app.buttons["Link"].tap(); app.alerts.buttons["Link intersection"].tap()
        XCTAssertTrue(app.buttons["Unlink"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["editor.duration"].label, "0:21.00")
        app.buttons["Undo"].tap()
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 30)
        XCTAssertEqual(app.staticTexts["editor.duration"].label, "0:21.00")
        app.buttons["Redo"].tap()
        XCTAssertEqual(app.staticTexts["editor.duration"].label, "0:21.00")
    }

    func testIndependentTracksWorkflow() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]; app.launch()
        let play = app.buttons["Play"]
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 45)
        let timeline = app.otherElements["editor.timeline"]
        XCTAssertTrue(timeline.exists)
        app.buttons["timeline.video.1"].tap()
        XCTAssertTrue(app.buttons["Unlink"].isEnabled)
        app.buttons["Unlink"].tap()
        XCTAssertTrue(app.buttons["Link"].waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 30)
        app.buttons["timeline.audio.1"].tap()
        XCTAssertTrue(app.buttons["timeline.audio.1"].isSelected && !app.buttons["timeline.video.1"].isSelected)
        XCTAssertTrue(app.buttons["Volume"].isEnabled)
        app.buttons["Volume"].tap()
        XCTAssertTrue(app.sliders["audio.gainSlider"].waitForExistence(timeout: 20))
        app.sliders["audio.gainSlider"].adjust(toNormalizedSliderPosition: 0.7)
        app.buttons["Apply"].tap()
        XCTAssertTrue(app.buttons["Move"].waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: app.buttons["Move"]); waitForExpectations(timeout: 30)
        app.buttons["Move"].tap()
        XCTAssertTrue(app.buttons["move.next"].waitForExistence(timeout: 5))
        app.buttons["move.next"].tap()
        XCTAssertFalse(app.buttons["Tools"].exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 10))
        let duration = app.staticTexts["editor.duration"].label
        XCTAssertEqual(duration, "0:36.00", "Moving independent audio after the picture preserves the full audio tail")
        app.buttons["Undo"].tap()
        XCTAssertEqual(app.staticTexts["editor.duration"].label, "0:18.00")
        app.buttons["Timeline view span"].tap(); app.buttons["Whole project"].tap()
        let portrait = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); portrait.name = "Tracks portrait"; portrait.lifetime = .keepAlways; add(portrait)
        app.buttons["Full"].tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.sliders["Full preview position"].exists)
        app.sliders["Full preview position"].adjust(toNormalizedSliderPosition: 0.5)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 5))
        XCTAssertNotEqual(app.staticTexts["editor.playhead"].label, "0:00.00")
        XCUIDevice.shared.orientation = .landscapeLeft
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: app.buttons["Tools"]); waitForExpectations(timeout: 10)
        let landscape = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); landscape.name = "Tracks landscape"; landscape.lifetime = .keepAlways; add(landscape)
        XCTAssertTrue(app.buttons["Tools"].isHittable)
        app.buttons["Tools"].tap()
        let enhance = app.buttons["tools.enhanceAudio"]
        let toolsScroll = app.scrollViews["tools.content"]
        XCTAssertTrue(toolsScroll.waitForExistence(timeout: 10))
        for _ in 0..<10 {
            if enhance.exists && enhance.frame.minY > 80 && enhance.frame.maxY < app.frame.maxY - 25 { break }
            let down = enhance.exists && enhance.frame.minY < 80
            toolsScroll.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: down ? 0.4 : 0.75)).press(forDuration: 0.05, thenDragTo: toolsScroll.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: down ? 0.75 : 0.4)))
        }
        XCTAssertTrue(enhance.isHittable); enhance.tap()
        XCTAssertTrue(app.buttons["Add filter"].waitForExistence(timeout: 20))
        app.buttons["Add filter"].tap(); app.buttons["Low-cut filter"].tap()
        app.buttons["Apply"].tap()
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 20))
        XCUIDevice.shared.orientation = .portrait
    }

    func testRangeSelectionWithOverlappingTracks() throws {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--tracks-overlap-fixture"]; app.launch()
        let mark = app.buttons["Mark start"], timeline = app.otherElements["editor.timeline"]
        XCTAssertTrue(mark.waitForExistence(timeout: 30))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: mark); waitForExpectations(timeout: 45)
        app.buttons["Timeline view span"].tap(); app.buttons["Whole project"].tap()
        func point(_ seconds: Double, _ y: Double) -> XCUICoordinate {
            timeline.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 48 + (timeline.frame.width - 96) * seconds / 18, dy: y))
        }
        func selectRange() {
            point(5.6, 10).tap(); mark.tap()
            point(7, 10).tap(); app.buttons["Mark end"].tap()
            XCTAssertTrue((timeline.value as? String)?.contains("Range") == true)
        }
        selectRange()
        let all = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); all.name = "Start End highlight only the affected time"; all.lifetime = .keepAlways; add(all)
        // Scope membership must not make the first tap act as deselection.
        point(6, 20 + 46 + 22).tap()
        XCTAssertTrue((timeline.value as? String)?.hasSuffix("1 video") == true)
        XCTAssertFalse((timeline.value as? String)?.contains("Range") == true)
        XCTAssertTrue(app.buttons["Move"].isEnabled)
        selectRange()
        XCTAssertTrue((timeline.value as? String)?.hasSuffix("Video") == true)
        let scoped = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); scoped.name = "Range on one video leaves other tracks plain"; scoped.lifetime = .keepAlways; add(scoped)
        // A horizontal drag at the clip's original edge scrubs; it must not
        // trim the whole clip while a smaller range is active.
        let edge = point(4.5, 20 + 46 + 22)
        edge.press(forDuration: 0.08, thenDragTo: edge.withOffset(CGVector(dx: 35, dy: 0)))
        XCTAssertTrue((timeline.value as? String)?.contains("Range") == true)
        XCTAssertEqual(app.staticTexts["editor.duration"].label, "0:18.00")
        app.buttons["editor.clearSelection"].tap()
        XCTAssertTrue((timeline.value as? String)?.contains("No selection") == true)
        point(6, 20 + 46 + 22).tap(); XCTAssertTrue(app.buttons["Move"].isEnabled)
        point(6, 20 + 46 + 22).tap(); XCTAssertFalse(app.buttons["Move"].isEnabled)
    }

    func testPlacementIsAvailableFromTheOverlapOnly() {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--tracks-overlap-fixture"]
        app.launch()
        let tools = app.buttons["Tools"], chip = app.buttons["effect.placement"]
        XCTAssertTrue(tools.waitForExistence(timeout: 25))
        seekTimeline(fraction: 0.1, in: app); XCTAssertFalse(chip.exists)
        seekTimeline(fraction: 0.34, in: app)
        openTimelinePlacement(in: app)
        let layout = app.buttons["Layout"]
        XCTAssertTrue(layout.waitForExistence(timeout: 10)); layout.tap(); app.buttons["Side by side"].tap()
        app.buttons["Apply"].tap()
        XCTAssertTrue(chip.waitForExistence(timeout: 10))
        tools.tap()
        let content = app.scrollViews["tools.content"]
        XCTAssertTrue(content.waitForExistence(timeout: 5))
        for _ in 0..<3 {
            XCTAssertFalse(app.buttons["tools.placement"].exists)
            XCTAssertFalse(app.buttons["tools.existing.placement"].exists)
            content.swipeUp()
        }
        app.buttons["Done"].tap()
        app.buttons["timeline.video.3"].tap()
        XCTAssertTrue(app.buttons["editor.clearSelection"].isHittable)
        openTimelinePlacement(in: app); XCTAssertTrue(layout.waitForExistence(timeout: 8)); app.buttons["Cancel"].tap()
        app.buttons["Copy selection"].tap(); app.buttons["editor.clearSelection"].tap()
        XCTAssertTrue(app.buttons["editor.paste"].isHittable)
        openTimelinePlacement(in: app); XCTAssertTrue(layout.waitForExistence(timeout: 8)); app.buttons["Cancel"].tap()
        seekTimeline(fraction: 0.1, in: app); XCTAssertFalse(chip.exists)
    }

    func testPlacementTouchTargetsVisibleInset() throws {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--tracks-overlap-fixture"]; app.launch()
        let full = app.buttons["Full"]
        XCTAssertTrue(full.waitForExistence(timeout: 30)); expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: full); waitForExpectations(timeout: 45)
        full.tap(); app.sliders["Full preview position"].adjust(toNormalizedSliderPosition: 0.34); app.buttons["Done"].tap(); openTimelinePlacement(in: app)
        let layout = app.buttons["Layout"], picker = app.buttons["placement.video"]
        XCTAssertTrue(layout.waitForExistence(timeout: 30)); layout.tap(); app.buttons["Picture in picture"].tap()
        func edge(_ name: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: "placement.crop." + name).firstMatch }
        XCTAssertTrue(edge("left").waitForExistence(timeout: 30))
        let x = (edge("left").frame.midX + edge("right").frame.midX) / 2, y = (edge("top").frame.midY + edge("bottom").frame.midY) / 2
        let preview = app.otherElements["placement.preview"]
        preview.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2)).tap()
        XCTAssertTrue((picker.value as? String ?? "").contains("V1"), "Tap outside the insets selects the background")
        let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
        start.press(forDuration: 0.08, thenDragTo: start.withOffset(CGVector(dx: -20, dy: 10)))
        XCTAssertTrue((picker.value as? String ?? "").contains("V3"), "Dragging the visible inset selects it, even after selecting the background")
        XCTAssertEqual((edge("left").frame.midX + edge("right").frame.midX) / 2, x - 20, accuracy: 3)
        XCTAssertEqual((edge("top").frame.midY + edge("bottom").frame.midY) / 2, y + 10, accuracy: 3)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Direct drag selects visible inset over background"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["Cancel"].tap()
    }

    func testPlainTransitionOverlapUsesTransitionControl() throws {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]; app.launch()
        let full = app.buttons["Full"]
        func ready() { XCTAssertTrue(full.waitForExistence(timeout: 30)); expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: full); waitForExpectations(timeout: 45) }
        ready(); full.tap(); app.sliders["Full preview position"].adjust(toNormalizedSliderPosition: 0.5); app.buttons["Done"].tap(); app.buttons["Split"].tap()
        openTimelineTransition(in: app)
        let apply = app.buttons["transition.apply"]
        expectation(for: NSPredicate(format: "exists == true AND enabled == true"), evaluatedWith: apply); waitForExpectations(timeout: 40); apply.tap()
        ready(); full.tap(); app.sliders["Full preview position"].adjust(toNormalizedSliderPosition: 0.5); app.buttons["Done"].tap()
        XCTAssertFalse(app.buttons["effect.placement"].exists)
        let transition = app.buttons.matching(NSPredicate(format: "identifier IN %@", ["editor.transition", "effect.transition"])).firstMatch
        XCTAssertTrue(transition.waitForExistence(timeout: 5)); transition.tap()
        XCTAssertTrue(app.buttons["transition.apply"].waitForExistence(timeout: 10)); app.buttons["Cancel"].tap()
    }

    func testPlacementReorderResizeAndPan() throws {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--tracks-overlap-fixture"]; app.launch()
        let full = app.buttons["Full"]
        func ready() { XCTAssertTrue(full.waitForExistence(timeout: 30)); expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: full); waitForExpectations(timeout: 45) }
        func open() { ready(); full.tap(); app.sliders["Full preview position"].adjust(toNormalizedSliderPosition: 0.34); app.buttons["Done"].tap(); openTimelinePlacement(in: app) }
        func handle(_ edge: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: "placement.crop." + edge).firstMatch }
        func handles() { XCTAssertTrue(handle("left").waitForExistence(timeout: 30)) }
        let picker = app.buttons["placement.video"], controls = app.scrollViews["placement.controls"]
        func selected() -> String { picker.label + " " + (picker.value as? String ?? "") }
        func reveal(_ element: XCUIElement) { for _ in 0..<6 { if element.isHittable { break }; controls.swipeUp() }; XCTAssertTrue(element.isHittable) }
        open(); handles()
        XCTAssertTrue(selected().contains("V3") && selected().contains("front"), selected())
        let back = app.buttons["Send to back"]; reveal(back); back.tap()
        XCTAssertTrue(selected().contains("V3") && selected().contains("back"), "Selection stays on the explicitly reordered layer")
        app.buttons["Apply"].tap(); open(); handles()
        XCTAssertTrue(selected().contains("V2") && selected().contains("front"), "Reopening selects the saved foreground, not the former top layer")
        let layout = app.buttons["Layout"]; reveal(layout); layout.tap(); app.buttons["Cover"].tap(); handles()
        XCTAssertTrue(selected().contains("V2") && selected().contains("front"), "Layout changes retain the chosen layer order")
        let preview = app.otherElements["placement.preview"]
        let width = handle("right").frame.midX - handle("left").frame.midX
        let centerBefore = CGPoint(x: (handle("right").frame.midX + handle("left").frame.midX) / 2, y: (handle("top").frame.midY + handle("bottom").frame.midY) / 2)
        preview.pinch(withScale: 0.65, velocity: -1)
        XCTAssertEqual((handle("right").frame.midX + handle("left").frame.midX) / 2, centerBefore.x, accuracy: 3, "Symmetric pinch must not drag the window sideways")
        XCTAssertEqual((handle("top").frame.midY + handle("bottom").frame.midY) / 2, centerBefore.y, accuracy: 3)
        let smaller = handle("right").frame.midX - handle("left").frame.midX
        XCTAssertLessThan(smaller, width * 0.85, "Pinch resizes the selected video window")
        XCTAssertGreaterThan(smaller, width * 0.45)
        let x = (handle("right").frame.midX + handle("left").frame.midX) / 2
        let y = (handle("top").frame.midY + handle("bottom").frame.midY) / 2
        let origin = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
        origin.press(forDuration: 0.08, thenDragTo: origin.withOffset(CGVector(dx: -24, dy: 16)))
        XCTAssertEqual((handle("right").frame.midX + handle("left").frame.midX) / 2, x - 24, accuracy: 3, "Pan keeps the whole finger displacement")
        XCTAssertEqual((handle("top").frame.midY + handle("bottom").frame.midY) / 2, y + 16, accuracy: 3)
        let cropped = handle("left"), touch = cropped.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        touch.press(forDuration: 0.08, thenDragTo: touch.withOffset(CGVector(dx: 15, dy: 0)))
        XCTAssertNotEqual(cropped.value as? String, "0% cropped")
        let margin = cropped.value as? String
        let reframe = app.switches["Reframe inside window"]; reveal(reframe); reframe.tap()
        let fixedWindow = CGRect(x: handle("left").frame.midX, y: handle("top").frame.midY,
                                 width: handle("right").frame.midX - handle("left").frame.midX,
                                 height: handle("bottom").frame.midY - handle("top").frame.midY)
        let beforeZoom = preview.screenshot().pngRepresentation
        preview.pinch(withScale: 1.8, velocity: 1)
        XCTAssertNotEqual(preview.screenshot().pngRepresentation, beforeZoom, "Reframe pinch changes the picture inside the window")
        XCTAssertEqual(handle("left").frame.midX, fixedWindow.minX, accuracy: 1)
        XCTAssertEqual(handle("right").frame.midX, fixedWindow.maxX, accuracy: 1)
        let pan = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: fixedWindow.midX, dy: fixedWindow.midY))
        pan.press(forDuration: 0.08, thenDragTo: pan.withOffset(CGVector(dx: 14, dy: 10)))
        XCTAssertEqual(handle("top").frame.midY, fixedWindow.minY, accuracy: 1, "Reframing does not move or resize the cropped window")
        XCTAssertEqual(handle("bottom").frame.midY, fixedWindow.maxY, accuracy: 1)
        app.buttons["Apply"].tap(); ready(); app.buttons["Undo"].tap(); app.buttons["Redo"].tap()
        app.terminate(); app.launchArguments = ["--editor-preview"]; app.launch(); open(); handles()
        XCTAssertTrue(selected().contains("V2") && selected().contains("front"))
        XCTAssertEqual(handle("left").value as? String, margin, "Resize, pan and crop survive Undo/Redo and reopening")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Reordered resized panned and cropped overlap"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["Cancel"].tap()
    }

    func testPlacementPreviewStaysInsideOverlap() throws {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--tracks-overlap-fixture"]; app.launch()
        let full = app.buttons["Full"]
        XCTAssertTrue(full.waitForExistence(timeout: 30)); expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: full); waitForExpectations(timeout: 45)
        full.tap(); app.sliders["Full preview position"].adjust(toNormalizedSliderPosition: 0.34); app.buttons["Done"].tap()
        openTimelinePlacement(in: app)
        let controls = app.scrollViews["placement.controls"], play = app.buttons["Play preview"]
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        for _ in 0..<5 { if play.isHittable { break }; controls.swipeUp() }
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 30)
        play.tap(); XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5))
        XCTAssertTrue(play.waitForExistence(timeout: 5), "Arrange preview must stop at the overlap boundary, before unrelated footage")
        let position = app.sliders["Overlap preview position"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: position); waitForExpectations(timeout: 20)
        position.adjust(toNormalizedSliderPosition: 0.2)
        let edge = app.descendants(matching: .any).matching(identifier: "placement.crop.left").firstMatch
        XCTAssertTrue(edge.waitForExistence(timeout: 30), "Choosing a new frame restores live arrangement handles")
        let clock = app.staticTexts["placement.time"], chosen = clock.label
        let touch = edge.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        touch.press(forDuration: 0.08, thenDragTo: touch.withOffset(CGVector(dx: 20, dy: 0)))
        XCTAssertEqual(clock.label, chosen, "Editing keeps the chosen preview frame instead of returning to the panel's opening frame")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Placement preview stopped inside overlap"; shot.lifetime = .keepAlways; add(shot)
    }

    func testPlacementEdgeCrop() throws {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--tracks-overlap-fixture"]; app.launch()
        let full = app.buttons["Full"]
        XCTAssertTrue(full.waitForExistence(timeout: 30)); expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: full); waitForExpectations(timeout: 45)
        full.tap(); app.sliders["Full preview position"].adjust(toNormalizedSliderPosition: 0.34); app.buttons["Done"].tap()
        openTimelinePlacement(in: app)
        func handle(_ edge: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: "placement.crop." + edge).firstMatch }
        for edge in ["left", "right", "top", "bottom"] { XCTAssertTrue(handle(edge).waitForExistence(timeout: 30)); XCTAssertEqual(handle(edge).value as? String, "0% cropped") }
        var saved: [String: String] = [:]
        for (edge, dx, dy) in [("left", 35.0, 0.0), ("right", -25.0, 0.0), ("top", 0.0, 30.0), ("bottom", 0.0, -25.0)] {
            let element = handle(edge), start = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let opposite = handle(edge == "left" ? "right" : edge == "right" ? "left" : edge == "top" ? "bottom" : "top")
            let fixedEdge = dx != 0 ? opposite.frame.midX : opposite.frame.midY
            let movedEdge = dx != 0 ? element.frame.midX : element.frame.midY
            XCTAssertTrue(element.isHittable)
            start.press(forDuration: 0.08, thenDragTo: start.withOffset(CGVector(dx: dx, dy: dy)))
            expectation(for: NSPredicate(format: "value != %@", "0% cropped"), evaluatedWith: element); waitForExpectations(timeout: 10)
            saved[edge] = element.value as? String
            XCTAssertEqual(dx != 0 ? opposite.frame.midX : opposite.frame.midY, fixedEdge, accuracy: 1, "Crop does not move the opposite edge")
            XCTAssertEqual(dx != 0 ? element.frame.midX : element.frame.midY, movedEdge + (dx != 0 ? dx : dy), accuracy: 2, "Edge follows the full finger movement without recognition slop")
        }
        let portrait = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); portrait.name = "Placement four independent crop edges"; portrait.lifetime = .keepAlways; add(portrait)
        app.buttons["Apply"].tap(); XCTAssertTrue(full.waitForExistence(timeout: 20)); expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: full); waitForExpectations(timeout: 30)
        app.buttons["Undo"].tap(); app.buttons["Redo"].tap()
        app.terminate(); app.launchArguments = ["--editor-preview"]; app.launch()
        XCTAssertTrue(full.waitForExistence(timeout: 30)); expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: full); waitForExpectations(timeout: 30)
        full.tap(); app.sliders["Full preview position"].adjust(toNormalizedSliderPosition: 0.34); app.buttons["Done"].tap(); openTimelinePlacement(in: app)
        XCTAssertTrue(handle("left").waitForExistence(timeout: 30))
        for edge in saved.keys { XCTAssertEqual(handle(edge).value as? String, saved[edge], "Crop survives Undo/Redo and reopening") }
        XCUIDevice.shared.orientation = .landscapeLeft
        expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: app); waitForExpectations(timeout: 10)
        let controls = app.scrollViews["placement.controls"], reset = app.buttons["placement.resetCrop"]
        for _ in 0..<5 { if reset.isHittable { break }; controls.swipeUp() }
        XCTAssertTrue(reset.isEnabled); reset.tap()
        for edge in saved.keys { XCTAssertEqual(handle(edge).value as? String, "0% cropped") }
        app.buttons["Cancel"].tap(); openTimelinePlacement(in: app)
        XCTAssertTrue(handle("left").waitForExistence(timeout: 30))
        for edge in saved.keys { XCTAssertEqual(handle(edge).value as? String, saved[edge], "Cancel discards Reset crop") }
        let landscape = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); landscape.name = "Placement crop landscape"; landscape.lifetime = .keepAlways; add(landscape)
        // A narrow PiP has less inward hit area than UIKit's usual pan slop.
        // It must still accept an inward crop and follow the complete drag.
        XCUIDevice.shared.orientation = .portrait
        let layout = app.buttons["Layout"]
        for _ in 0..<5 { if layout.isHittable { break }; controls.swipeDown() }
        layout.tap(); app.buttons["Picture in picture"].tap()
        let smallLeft = handle("left")
        XCTAssertTrue(smallLeft.waitForExistence(timeout: 10))
        let origin = smallLeft.frame.midX, touch = smallLeft.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        touch.press(forDuration: 0.08, thenDragTo: touch.withOffset(CGVector(dx: 12, dy: 0)))
        XCTAssertEqual(smallLeft.frame.midX, origin + 12, accuracy: 2, "A narrow PiP accepts inward crop drags")
        XCTAssertNotEqual(smallLeft.value as? String, "0% cropped")
        app.buttons["Cancel"].tap()
    }

    func testOverlapPlacementAndBookmarks() throws {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--tracks-overlap-fixture"]; app.launch()
        let full = app.buttons["Full"]
        XCTAssertTrue(full.waitForExistence(timeout: 30)); expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: full); waitForExpectations(timeout: 45)
        app.buttons["Timeline view span"].tap(); app.buttons["Whole project"].tap()
        let timeline = app.otherElements["editor.timeline"]
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.4)).press(forDuration: 0.05, thenDragTo: timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.4)))
        XCTAssertNotEqual(app.staticTexts["editor.playhead"].label, "0:00.00", "Fit timeline pans scrub")
        // This fixture needs only four lanes, which now all fit without an
        // overflow button. The six-lane Move test exercises real overflow.
        for number in 1...2 { XCTAssertGreaterThanOrEqual(app.buttons["timeline.audio.\(number)"].frame.height, 30) }
        full.tap(); app.sliders["Full preview position"].adjust(toNormalizedSliderPosition: 0.34)
        app.buttons["Bookmarks"].tap(); app.buttons["Add bookmark here"].tap()
        XCTAssertTrue(app.buttons["Previous bookmark"].firstMatch.isEnabled)
        app.buttons["Done"].tap()
        openTimelinePlacement(in: app)
        XCTAssertTrue(app.buttons["Layout"].waitForExistence(timeout: 30))
        app.buttons["Layout"].tap(); app.buttons["Side by side"].tap()
        let apply = app.buttons["Apply"]
        XCTAssertTrue(app.buttons["Bring to front"].isHittable)
        app.buttons["Bring to front"].tap()
        let preview = app.otherElements["placement.preview"]
        if preview.exists { preview.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).press(forDuration: 0.05, thenDragTo: preview.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5))) }
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Three overlapping pictures in Placement"; shot.lifetime = .keepAlways; add(shot)
        apply.tap(); XCTAssertTrue(full.waitForExistence(timeout: 20))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: full); waitForExpectations(timeout: 45)
        app.buttons["Undo"].tap(); app.buttons["Redo"].tap()
        app.terminate(); app.launchArguments = ["--editor-preview"]; app.launch()
        XCTAssertTrue(full.waitForExistence(timeout: 30))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: full); waitForExpectations(timeout: 45)
        XCTAssertTrue(app.buttons["Previous bookmark"].firstMatch.isEnabled, "Bookmark survives reopening with placement history")
    }

    func testImportedCinematicBokehAvailability() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--editor-preview","--reset-ui-fixture","--depth-ui-fixture"];app.launch()
        openTool("videoEffects",in:app)
        let wide=app.buttons["videoEffects.add.widescreen"],controls=app.scrollViews["videoEffects.controls"]
        openEffectSection("cameraFrame",in:app)
        for _ in 0..<8 {if wide.isHittable {break};controls.swipeUp()}
        XCTAssertTrue(wide.isHittable);wide.tap()
        let bokeh=app.switches["Oval bokeh"]
        XCTAssertTrue(bokeh.waitForExistence(timeout:40),"Original Cinematic imports should expose depth bokeh after analysis")
        for _ in 0..<8 {if bokeh.isHittable {break};controls.swipeUp()}
        XCTAssertTrue(bokeh.isHittable)
        #if targetEnvironment(simulator)
        XCTAssertFalse(bokeh.isEnabled)
        XCTAssertTrue(app.staticTexts["Cinematic depth editing requires a physical iPhone."].exists)
        #else
        XCTAssertTrue(bokeh.isEnabled);bokeh.tap()
        #endif
        let apply=app.buttons["videoEffects.apply"]
        expectation(for:NSPredicate(format:"enabled == true"),evaluatedWith:apply);waitForExpectations(timeout:30)
        #if !targetEnvironment(simulator)
        XCTAssertEqual(bokeh.value as? String,"1")
        #endif
        let portrait=XCTAttachment(screenshot:XCUIScreen.main.screenshot());portrait.name="Cinematic bokeh portrait";portrait.lifetime = .keepAlways;add(portrait)
        XCUIDevice.shared.orientation = .landscapeLeft
        for _ in 0..<8 {if bokeh.isHittable {break};controls.swipeUp()}
        XCTAssertTrue(bokeh.isHittable)
        let landscape=XCTAttachment(screenshot:XCUIScreen.main.screenshot());landscape.name="Cinematic bokeh landscape";landscape.lifetime = .keepAlways;add(landscape)
        apply.tap();XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout:15))
        app.buttons["Tools"].tap()
        let existing=app.buttons["tools.existing.videoEffects"]
        for _ in 0..<6 {if existing.isHittable {break};app.scrollViews.firstMatch.swipeUp()}
        XCTAssertTrue(existing.isHittable);existing.tap()
        let appliedWide=app.buttons["Widescreen 1953"].firstMatch
        XCTAssertTrue(appliedWide.waitForExistence(timeout:15));appliedWide.tap()
        XCTAssertTrue(bokeh.waitForExistence(timeout:30))
        #if !targetEnvironment(simulator)
        XCTAssertEqual(bokeh.value as? String,"1")
        #endif
        XCUIDevice.shared.orientation = .portrait
    }

    func testAutoBackgroundExportMakesPictureProgress() throws { try checkBackgroundExport(crop: false) }
    func testAutoBackgroundFillExportMakesPictureProgress() throws { try checkBackgroundExport(crop: true) }

    func testAutoBackgroundFillPublishesMovie() throws { try checkBackgroundExport(crop: true, complete: true) }

    private func checkBackgroundExport(crop: Bool, complete: Bool = false) throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["YOUREC_EDITOR_FIXTURE_TITLE"] = complete ? "Auto Background export QA · Completed" : "Auto Background export QA · " + (crop ? "Crop" : "Plain")
        app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]
        if complete { app.launchArguments.append("--background-fill-export-fixture") }
        else if !crop { app.launchArguments.append("--background-export-fixture") }
        app.launch()
        if crop && !complete {
            openTool("crop", in: app); waitForTool(app)
            app.buttons["crop.shape"].tap(); app.buttons["1:1"].tap(); waitForTool(app)
            app.buttons["tool.apply"].tap()
            XCTAssertTrue(app.buttons["effect.crop"].firstMatch.waitForExistence(timeout: 15))
            openTool("videoEffects", in: app)
            openEffectSection("background", in: app)
            app.buttons["videoEffects.add.autoBackground"].tap()
            let apply = app.buttons["videoEffects.apply"]
            expectation(for: NSPredicate(format: "exists == true AND enabled == true"), evaluatedWith: apply)
            waitForExpectations(timeout: 20)
            XCTAssertFalse(app.descendants(matching: .any)["videoEffects.refinement"].exists)
            apply.tap()
            XCTAssertTrue(app.buttons["effect.videoEffects"].firstMatch.waitForExistence(timeout: 15))
        }
        let export = app.buttons["Export"]
        XCTAssertTrue(export.waitForExistence(timeout: 40))
        let play = app.buttons["Play"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 45)
        XCTAssertFalse(app.descendants(matching: .any)["editor.effectRefinement"].exists)
        export.tap()
        let start = app.buttons["Export video"]
        XCTAssertTrue(start.waitForExistence(timeout: 8)); start.tap()
        let progress = app.progressIndicators["export.progress"], done = app.buttons["Share latest export"]
        let prepared = NSPredicate { _, _ in
            done.exists || (progress.exists && ["Checking audio", "Encoding audio", "Rendering video"].contains(where: progress.label.hasPrefix))
        }
        expectation(for: prepared, evaluatedWith: app); waitForExpectations(timeout: 40)
        let advanced = NSPredicate { _, _ in
            if done.exists { return true }
            return progress.exists && progress.label == "Rendering video with Auto Background"
        }
        expectation(for: advanced, evaluatedWith: app); waitForExpectations(timeout: 240)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = crop ? "Encoding Auto Background with Fill" : "Encoding Auto Background"
        shot.lifetime = .keepAlways; add(shot)
        if !done.exists {
            let first = progress.value as? String
            expectation(for: NSPredicate { _, _ in done.exists || (progress.exists && progress.value as? String != first) }, evaluatedWith: app)
            waitForExpectations(timeout: 180)
        }
        if complete {
            XCTAssertTrue(done.waitForExistence(timeout: 7200))
            XCTAssertTrue(app.buttons["Save to Photos"].isHittable)
        }
        if done.exists { app.navigationBars["Export"].buttons["Done"].tap() }
        else {
            let exportBar = app.navigationBars["Export"]
            exportBar.buttons["Cancel"].tap()
            XCTAssertTrue(start.waitForExistence(timeout: 15), "Cancelling stops in-flight mask processing.")
            exportBar.buttons["Done"].tap()
        }
    }

    func testEffectRefinementKeepsPlaybackAndPosition() throws {
        continueAfterFailure=false
        let app=XCUIApplication()
        app.launchArguments=["--editor-preview","--reset-ui-fixture","--effect-refinement-fixture","--slow-video-effect-preparation"]
        app.launch()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout:20))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Applying video effects")).firstMatch.waitForExistence(timeout:5))
        app.buttons["Play"].tap()
        let ready=app.staticTexts["Effects applied · pause playback to see the result"]
        XCTAssertTrue(ready.waitForExistence(timeout:40),"Refinement error: \(app.buttons["Retry applying effects"].exists ? app.buttons["Retry applying effects"].value as? String ?? "unknown" : "none")")
        XCTAssertTrue(app.buttons["Pause playback"].exists,"Finishing analysis must not interrupt playback")
        app.buttons["Pause playback"].tap()
        let position=app.staticTexts["editor.playhead"].label
        expectation(for:NSPredicate(format:"exists == false"),evaluatedWith:ready);waitForExpectations(timeout:10)
        XCTAssertEqual(app.staticTexts["editor.playhead"].label,position,"Installing the accurate preview must preserve the playhead")
        app.buttons["Play"].tap();XCTAssertTrue(app.buttons["Pause playback"].waitForExistence(timeout:5))
        app.buttons["Pause playback"].tap()
        let parked = app.staticTexts["editor.playhead"].label
        app.otherElements["editor.preview"].tap()
        XCTAssertTrue(app.buttons["Pause playback"].waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "label != %@", parked), evaluatedWith: app.staticTexts["editor.playhead"])
        waitForExpectations(timeout: 5)
        app.otherElements["editor.preview"].tap()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 5))
    }

    func testLiveEffectFrameToolsRemainCancellable() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--recorder-controls-test"]; app.launch()
        let effects = app.buttons["recorder.videoEffects"]
        XCTAssertTrue(effects.waitForExistence(timeout: 15)); effects.tap()
        let clear=app.buttons["liveEffects.actions"],liveControls=app.scrollViews["liveEffects.controls"]
        if clear.waitForExistence(timeout:3) {
            for _ in 0..<8 {if clear.isHittable {break};liveControls.swipeUp()}
            XCTAssertTrue(clear.isHittable);clearLiveEffects(in: app)
        }
        openEffectSection("colorStyle",in:app,live:true)
        expandLiveEffects(in: app)
        let isolation = app.buttons["liveEffects.add.colorIsolation"]
        let controls = app.scrollViews["liveEffects.controls"]
        // A full swipe flicks past several rows in the compact live drawer.
        // Drag a fraction of its viewport and pause before release, as a user
        // scrolling to a specific effect would do, rather than overshooting it.
        for _ in 0..<12 {
            if isolation.isHittable {break}
            let start=controls.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.8))
            let end=controls.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.4))
            start.press(forDuration:0.05,thenDragTo:end,withVelocity:.slow,thenHoldForDuration:0.15)
        }
        XCTAssertTrue(isolation.isHittable); isolation.tap()
        expandLiveEffects(in: app)
        let pick = app.buttons["liveEffects.pickColor"]
        for _ in 0..<8 { if pick.isHittable { break }; controls.swipeUp() }
        XCTAssertTrue(pick.isHittable); pick.tap()
        let cancel = app.buttons["liveEffects.cancelFrameTool"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5)); XCTAssertTrue(cancel.isHittable)
        XCTAssertFalse(app.buttons["Expand controls"].isHittable)
        let portrait = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); portrait.name = "Live color picker portrait"; portrait.lifetime = .keepAlways; add(portrait)
        XCUIDevice.shared.orientation = .landscapeLeft
        expectation(for:NSPredicate { _,_ in app.windows.firstMatch.frame.width>app.windows.firstMatch.frame.height },evaluatedWith:app.windows.firstMatch)
        waitForExpectations(timeout:5)
        let bar=app.otherElements["liveEffects.frameToolBar"]
        expectation(for:NSPredicate { _,_ in bar.frame.minX>=0 && bar.frame.maxX<=app.windows.firstMatch.frame.width && bar.frame.maxY<=app.windows.firstMatch.frame.height },evaluatedWith:bar)
        waitForExpectations(timeout:5)
        XCTAssertTrue(cancel.isHittable)
        let settled=expectation(description:"Rotation settles")
        DispatchQueue.main.asyncAfter(deadline:.now()+0.6) { settled.fulfill() };wait(for:[settled],timeout:2)
        let preview=app.otherElements["recorder.preview"]
        XCTAssertTrue(preview.exists)
        XCTAssertLessThanOrEqual(preview.frame.maxY,bar.frame.minY+2)
        let landscape = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); landscape.name = "Live color picker landscape"; landscape.lifetime = .keepAlways; add(landscape)
        preview.coordinate(withNormalizedOffset: CGVector(dx: 0.52, dy: 0.47)).tap()
        // A camera without a sampleable frame can keep the picker open for another try.
        if !app.buttons["liveEffects.browse"].waitForExistence(timeout: 2) { cancel.tap() }
        XCTAssertTrue(app.buttons["liveEffects.browse"].waitForExistence(timeout: 5), "A color sample must return to the inspector")
        XCUIDevice.shared.orientation = .portrait
        dismissLiveEffects(in: app); XCTAssertTrue(effects.isHittable)
    }

    private func moveAndTurnSplit(in app: XCUIApplication) {
        let center = app.descendants(matching: .any)["kaleidoscope.center"].firstMatch
        let handle = app.descendants(matching: .any)["kaleidoscope.rotation"].firstMatch
        XCTAssertTrue(center.waitForExistence(timeout: 12))
        let before = center.value as? String
        let pivot = center.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        pivot.press(forDuration: 0.15, thenDragTo: pivot.withOffset(CGVector(dx: 26, dy: 9)))
        XCTAssertNotEqual(center.value as? String, before, "Dragging pans the split")
        XCTAssertTrue(handle.isHittable)
        let startAngle = handle.value as? String
        let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        // A quarter-turn about the actual displayed pivot, even for a mirrored preview.
        let c = center.frame, h = handle.frame
        let dx = h.midX - c.midX, dy = h.midY - c.midY
        start.press(forDuration: 0.15, thenDragTo: start.withOffset(CGVector(dx: -dy-dx, dy: dx-dy)))
        XCTAssertNotEqual(handle.value as? String, startAngle, "The rotation handle turns the split")
    }

    private func readyForOpticalEdit(_ app: XCUIApplication) {
        let apply = app.buttons["videoEffects.apply"]
        expectation(for: NSPredicate(format: "exists == true AND enabled == true"), evaluatedWith: apply)
        waitForExpectations(timeout: 25)
    }

    @discardableResult private func exerciseSplit(in app: XCUIApplication) -> [String] {
        let source = app.descendants(matching: .any)["kaleidoscope.source"].firstMatch
        let center = app.descendants(matching: .any)["kaleidoscope.center"].firstMatch
        let angle = app.descendants(matching: .any)["kaleidoscope.rotation"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 12))
        let initial = [center.value as? String, angle.value as? String]
        let original = source.value as? String
        let start = source.coordinate(withNormalizedOffset: CGVector(dx: 0.23, dy: 0.34))
        start.press(forDuration: 0.12, thenDragTo: start.withOffset(CGVector(dx: 18, dy: 10)))
        XCTAssertEqual([center.value as? String, angle.value as? String], initial)
        XCTAssertNotEqual(source.value as? String, original)
        let panned = source.value as? String
        moveAndTurnSplit(in: app)
        XCTAssertEqual(source.value as? String, panned)
        twistSource(in: app, radians: .pi / 4)
        return [center, angle, source].map { $0.value as? String ?? "" }
    }

    private func twistSource(in app: XCUIApplication, radians: CGFloat) {
        let source = app.descendants(matching: .any)["kaleidoscope.source"].firstMatch
        let center = app.descendants(matching: .any)["kaleidoscope.center"].firstMatch
        let angle = app.descendants(matching: .any)["kaleidoscope.rotation"].firstMatch
        let before = source.value as? String, pan = sourcePanReadout(source)
        let stationary = [center.value as? String, angle.value as? String]
        source.rotate(radians, withVelocity: radians < 0 ? -1.8 : 1.8)
        XCTAssertNotEqual(source.value as? String, before, "Twisting the picture turns the source")
        XCTAssertEqual([center.value as? String, angle.value as? String], stationary, "A two-finger turn keeps the split stationary")
        XCTAssertEqual(sourcePanReadout(source), pan)
    }

    private func sourcePanReadout(_ source: XCUIElement) -> String? {
        (source.value as? String)?.components(separatedBy: " · Rotation").first
    }

    private func exerciseFineSourceRotation(in app: XCUIApplication, controls: XCUIElement, live: Bool) {
        let disclosure = app.buttons["Fine adjustments"]
        revealInViewport(disclosure, scroll: controls, swipeX: 0.025); disclosure.tap()
        let slider = app.sliders[live ? "Source rotation" : "videoEffects.slider.sourceAngle"]
        revealInViewport(slider, scroll: controls, swipeX: 0.025)
        let source = app.descendants(matching: .any)["kaleidoscope.source"].firstMatch
        let split = app.descendants(matching: .any)["kaleidoscope.rotation"].firstMatch
        let originalPan = sourcePanReadout(source), originalSplit = split.value as? String
        let old = slider.value as? String
        slider.adjust(toNormalizedSliderPosition: 0.77)
        let value = slider.value as? String
        XCTAssertNotEqual(value, old); XCTAssertTrue(value?.hasSuffix("°") == true)
        XCTAssertTrue((source.value as? String)?.hasSuffix("Rotation " + (value ?? "")) == true)
        XCTAssertEqual(sourcePanReadout(source), originalPan); XCTAssertEqual(split.value as? String, originalSplit)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Fine source rotation"; shot.lifetime = .keepAlways; add(shot)
        revealInViewport(disclosure, scroll: controls, swipeX: 0.025); disclosure.tap()
    }

    func testKaleidoscopeEditorPositionAndCounts() throws {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]
        app.launch(); openTool("videoEffects", in: app); openEffectSection("cameraFrame", in: app)
        app.buttons["videoEffects.add.kaleidoscope"].tap()
        let controls = app.scrollViews["videoEffects.controls"]
        readyForOpticalEdit(app)
        let source = app.descendants(matching: .any)["kaleidoscope.source"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        let left = source.coordinate(withNormalizedOffset: CGVector(dx: 0.19, dy: 0.67))
        let right = source.coordinate(withNormalizedOffset: CGVector(dx: 0.77, dy: 0.67))
        left.press(forDuration: 0.12, thenDragTo: left.withOffset(CGVector(dx: 12, dy: 0)))
        XCTAssertTrue((source.value as? String)?.hasPrefix("X -") == true, "A rightward drag on the mirrored copy moves the source left")
        right.press(forDuration: 0.12, thenDragTo: right.withOffset(CGVector(dx: 12, dy: 0)))
        XCTAssertEqual(sourcePanReadout(source), "X 0% · Y 0%")
        for n in 2...9 {
            let button = app.buttons["Divisions " + String(n)]
            revealInViewport(button, scroll: controls); button.tap()
            XCTAssertTrue(button.isSelected)
        }
        readyForOpticalEdit(app)
        exerciseFineSourceRotation(in: app, controls: controls, live: false)
        let stored = exerciseSplit(in: app)
        XCTAssertFalse(app.buttons["videoEffects.panSource"].exists)
        XCTAssertFalse(app.buttons["videoEffects.positionSplit"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Direct Kaleidoscope editor"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["videoEffects.apply"].tap(); app.buttons["effect.videoEffects"].firstMatch.tap()
        let edit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'videoEffects.edit.'")).firstMatch
        if edit.waitForExistence(timeout: 2) { edit.tap() }
        readyForOpticalEdit(app)
        XCTAssertEqual(["center", "rotation", "source"].map { app.descendants(matching: .any)["kaleidoscope." + $0].firstMatch.value as? String ?? "" }, stored)
    }

    private func configureLiveSplit(in app: XCUIApplication, divisions: Int) {
        app.buttons["recorder.videoEffects"].tap()
        let clear = app.buttons["liveEffects.actions"], controls = app.scrollViews["liveEffects.controls"]
        if clear.waitForExistence(timeout: 2) { clearLiveEffects(in: app) }
        openEffectSection("cameraFrame", in: app, live: true)
        app.buttons["liveEffects.add.kaleidoscope"].tap()
        let count = app.buttons["Divisions " + String(divisions)]
        revealInViewport(count, scroll: controls); count.tap()
        exerciseFineSourceRotation(in: app, controls: controls, live: true)
        exerciseSplit(in: app)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Direct Kaleidoscope camera"; shot.lifetime = .keepAlways; add(shot)
        dismissLiveEffects(in: app)
    }

    private func exerciseRGB(in app: XCUIApplication, controls: XCUIElement) {
        func pad(_ id: String) -> XCUIElement { app.descendants(matching: .any)["rgbOffset." + id].firstMatch }
        let names = ["red", "green", "blue"]
        let first = XCTAttachment(screenshot: app.screenshot()); first.name = "RGB first open"; first.lifetime = .keepAlways; add(first)
        revealInViewport(pad("green"), scroll: controls)
        let neutral = names.map { pad($0).value as? String }
        XCTAssertEqual(neutral, Array(repeating: "X 0% · Y 0%", count: 3))
        for (i, name) in names.enumerated() {
            let before = names.map { pad($0).value as? String }
            let point = pad(name).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
            point.press(forDuration: 0.12, thenDragTo: point.withOffset(CGVector(dx: i == 1 ? 0 : 13, dy: i == 1 ? 16 : i == 2 ? -13 : 7)))
            for (j, other) in names.enumerated() {
                if j == i { XCTAssertNotEqual(pad(other).value as? String, before[j]) }
                else { XCTAssertEqual(pad(other).value as? String, before[j]) }
            }
        }
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "RGB pads"; shot.lifetime = .keepAlways; add(shot)
        pad("green").doubleTap()
        XCTAssertEqual(pad("green").value as? String, neutral[1])
    }

    func testOpticalColorAndStrobeEditor() throws {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]
        app.launch(); openTool("videoEffects", in: app); openEffectSection("colorStyle", in: app)
        let controls = app.scrollViews["videoEffects.controls"]
        let rgb = app.buttons["videoEffects.add.rgbOffset"]; revealInViewport(rgb, scroll: controls); rgb.tap()
        readyForOpticalEdit(app); exerciseRGB(in: app, controls: controls)
        app.buttons["videoEffects.browse"].tap()
        openEffectSection("time", in: app); app.buttons["videoEffects.add.negativeStrobe"].tap()
        let rate = app.buttons["Cycles per second 12"]
        revealInViewport(rate, scroll: controls); rate.tap(); XCTAssertTrue(rate.isSelected)
        let duration = app.switches["Limit duration"]
        revealInViewport(duration, scroll: controls); duration.tap()
        XCTAssertTrue(app.sliders["videoEffects.slider.burstLength"].exists)
        readyForOpticalEdit(app); app.buttons["videoEffects.apply"].tap()
        XCTAssertTrue(app.buttons["effect.videoEffects"].firstMatch.waitForExistence(timeout: 10))
    }

    #if targetEnvironment(simulator)
    func testKaleidoscopeLiveGuide() throws {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--recorder-controls-test", "--front-landscape-preview-test"]
        app.launch(); configureLiveSplit(in: app, divisions: 9)
        XCTAssertFalse(app.descendants(matching: .any)["kaleidoscope.guide"].exists)
        app.buttons["recorder.camera"].tap(); app.buttons["Front ultrawide (portrait)"].tap()
        XCUIDevice.shared.orientation = .landscapeLeft; defer { XCUIDevice.shared.orientation = .portrait }
        app.buttons["recorder.videoEffects"].tap()
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'liveEffects.edit.'")).firstMatch.tap()
        exerciseSplit(in: app)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Direct camera gestures landscape"; shot.lifetime = .keepAlways; add(shot)
    }
    func testRGBAndStrobeCamera() throws {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--recorder-controls-test", "--front-landscape-preview-test"]
        app.launch(); app.buttons["recorder.videoEffects"].tap()
        let controls = app.scrollViews["liveEffects.controls"]
        let clear = app.buttons["liveEffects.actions"]
        if clear.waitForExistence(timeout: 2) { clearLiveEffects(in: app) }
        openEffectSection("colorStyle", in: app, live: true)
        let rgb = app.buttons["liveEffects.add.rgbOffset"]; revealInViewport(rgb, scroll: controls); rgb.tap()
        exerciseRGB(in: app, controls: controls)
        app.buttons["liveEffects.browse"].tap()
        openEffectSection("time", in: app, live: true); app.buttons["liveEffects.add.negativeStrobe"].tap()
        let slow = app.buttons["Cycles per second 1"]
        revealInViewport(slow, scroll: controls); slow.tap()
        let limit = app.switches["Limit duration"]
        revealInViewport(limit, scroll: controls)
        if limit.value as? String == "1" { limit.tap() }
        let audition = app.buttons["liveEffects.tryStrobe"]
        revealInViewport(audition, scroll: controls)
        func luminance() throws -> Int {
            let screen = try XCTUnwrap(XCUIScreen.main.screenshot().image.cgImage)
            let width = CGFloat(screen.width), height = CGFloat(screen.height)
            let patch = try XCTUnwrap(screen.cropping(to: CGRect(x: width*0.2, y: height*0.25, width: width*0.08, height: height*0.06)))
            var pixel = [UInt8](repeating: 0, count: 4)
            let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(patch, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return pixel.prefix(3).reduce(0) { $0 + Int($1) } / 3
        }
        let original = try luminance()
        audition.tap()
        let deadline = Date().addingTimeInterval(3)
        var peak = original
        while Date() < deadline {
            peak = max(peak, try luminance())
            Thread.sleep(forTimeInterval: 0.12)
        }
        XCTAssertGreaterThan(peak - original, 90, "The public audition actually shows the inverted live picture")
        XCTAssertLessThan(abs(try luminance() - original), 8, "A completed audition restores the ordinary camera preview")
        dismissLiveEffects(in: app)
        XCTAssertTrue(app.buttons["recorder.record"].isHittable)
    }
    #endif

    func testKaleidoscopeCameraRecording() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires camera footage")
        #else
        continueAfterFailure = false; recorderReturnToPortrait = true
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--recorder-controls-test"]
        app.launch()
        let record = app.buttons["recorder.record"]
        XCTAssertTrue(record.waitForExistence(timeout: 25))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: record); waitForExpectations(timeout: 25)
        setDualMode(false, in: app)
        useEmptyRecordingProject(in: app)
        configureLiveSplit(in: app, divisions: 3)
        for side in 0..<2 {
            expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: record); waitForExpectations(timeout: 20)
            record.tap()
            expectation(for: NSPredicate(format: "label == 'Stop recording'"), evaluatedWith: record); waitForExpectations(timeout: 25)
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "Live Kaleidoscope camera " + String(side + 1); shot.lifetime = .keepAlways; add(shot)
            sleep(2)
            record.tap()
            expectation(for: NSPredicate(format: "label == 'Record into this project' AND enabled == true"), evaluatedWith: record); waitForExpectations(timeout: 25)
            if side == 0 {
                app.buttons["recorder.flip"].tap()
                app.buttons["recorder.videoEffects"].tap()
                app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'liveEffects.edit.'")).firstMatch.tap()
                let fourth = app.buttons["Divisions 4"]
                revealInViewport(fourth, scroll: app.scrollViews["liveEffects.controls"]); fourth.tap()
                twistSource(in: app, radians: -.pi / 5)
                dismissLiveEffects(in: app)
            }
        }
        app.buttons["Edit this project"].tap()
        XCTAssertTrue(app.buttons["Export"].waitForExistence(timeout: 30)); app.buttons["Export"].tap()
        XCTAssertTrue(app.buttons["Export video"].waitForExistence(timeout: 10)); app.buttons["Export video"].tap()
        XCTAssertTrue(app.buttons["Share latest export"].waitForExistence(timeout: 120))
        #endif
    }

    func testRGBAndStrobePhysicalRecording() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires real camera input")
        #else
        continueAfterFailure = false
        recorderReturnToPortrait = true
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--recorder-controls-test"]
        app.launch()
        let record = app.buttons["recorder.record"]
        func waitForRecordButton(_ label: String? = nil) {
            let predicate = label.map { NSPredicate(format: "label == %@ AND enabled == true", $0) }
                ?? NSPredicate(format: "enabled == true AND exists == true")
            expectation(for: predicate, evaluatedWith: record)
            waitForExpectations(timeout: 25)
        }
        func capture(_ name: String) {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = name; shot.lifetime = .keepAlways; add(shot)
        }

        waitForRecordButton(); setDualMode(false, in: app)
        useEmptyRecordingProject(in: app)
        app.buttons["recorder.videoEffects"].tap()
        let clear = app.buttons["liveEffects.actions"], controls = app.scrollViews["liveEffects.controls"]
        if clear.waitForExistence(timeout: 2) { clearLiveEffects(in: app) }
        openEffectSection("colorStyle", in: app, live: true)
        let rgb = app.buttons["liveEffects.add.rgbOffset"]
        revealInViewport(rgb, scroll: controls); rgb.tap()
        exerciseRGB(in: app, controls: controls)

        app.buttons["liveEffects.browse"].tap(); openEffectSection("time", in: app, live: true)
        app.buttons["liveEffects.add.negativeStrobe"].tap()
        let slow = app.buttons["Cycles per second 1"]
        revealInViewport(slow, scroll: controls); slow.tap()
        let limit = app.switches["Limit duration"]
        revealInViewport(limit, scroll: controls)
        if limit.value as? String == "1" { limit.tap() }
        let audition = app.buttons["liveEffects.tryStrobe"]
        revealInViewport(audition, scroll: controls)
        capture("RGB camera before audition")
        audition.tap()
        for i in 0..<5 {
            capture("RGB strobe audition " + String(i))
            Thread.sleep(forTimeInterval: 0.18)
        }
        dismissLiveEffects(in: app); waitForRecordButton(); record.tap()
        waitForRecordButton("Stop recording")
        for i in 0..<8 {
            capture("RGB strobe recording " + String(i))
            Thread.sleep(forTimeInterval: 0.22)
        }
        record.tap(); waitForRecordButton("Record into this project")
        app.buttons["Edit this project"].tap()
        XCTAssertTrue(app.buttons["Export"].waitForExistence(timeout: 30)); app.buttons["Export"].tap()
        XCTAssertTrue(app.buttons["Export video"].waitForExistence(timeout: 10)); app.buttons["Export video"].tap()
        XCTAssertTrue(app.buttons["Share latest export"].waitForExistence(timeout: 120))
        #endif
    }

    func testAutoBackgroundPhysicalRecording() throws {
        continueAfterFailure=false;recorderReturnToPortrait=true
        XCUIDevice.shared.orientation = .portrait
        let app=XCUIApplication();app.launchArguments=["--recorder-controls-test"];app.launch()
        let camera=app.buttons["recorder.camera"],record=app.buttons["recorder.record"]
        XCTAssertTrue(camera.waitForExistence(timeout:25))
        expectation(for:NSPredicate(format:"enabled == true"),evaluatedWith:camera);waitForExpectations(timeout:20)
        setDualMode(false,in:app)
        camera.tap()
        let front=app.buttons.matching(NSPredicate(format:"label BEGINSWITH[c] 'Front' AND NOT label CONTAINS[c] 'landscape'")).firstMatch
        XCTAssertTrue(front.waitForExistence(timeout:5));front.tap()
        useEmptyRecordingProject(in: app)
        app.buttons["recorder.videoEffects"].tap()
        let clear=app.buttons["liveEffects.actions"],controls=app.scrollViews["liveEffects.controls"]
        if clear.waitForExistence(timeout:2) {
            for _ in 0..<8 {if clear.isHittable {break};controls.swipeUp()}
            clearLiveEffects(in: app)
        }
        openEffectSection("background",in:app,live:true)
        app.buttons["liveEffects.add.autoBackground"].tap();expandLiveEffects(in: app)
        let background=app.buttons["Blur original"]
        for _ in 0..<8 {if background.isHittable {break};controls.swipeUp()}
        XCTAssertTrue(background.isHittable);background.tap();app.buttons["Solid"].tap();dismissLiveEffects(in: app)
        for run in 0..<2 {
            expectation(for:NSPredicate(format:"enabled == true"),evaluatedWith:record);waitForExpectations(timeout:20)
            let idle=XCTAttachment(screenshot:XCUIScreen.main.screenshot());idle.name="Auto Background idle \(run)";idle.lifetime = .keepAlways;add(idle)
            record.tap();expectation(for:NSPredicate(format:"label == 'Stop recording'"),evaluatedWith:record);waitForExpectations(timeout:20)
            let recording=expectation(description:"Observe real camera recording")
            DispatchQueue.main.asyncAfter(deadline:.now()+6) {recording.fulfill()};wait(for:[recording],timeout:10)
            let shot=XCTAttachment(screenshot:XCUIScreen.main.screenshot());shot.name="Auto Background recording \(run)";shot.lifetime = .keepAlways;add(shot)
            record.tap();expectation(for:NSPredicate(format:"label == 'Record into this project' AND enabled == true"),evaluatedWith:record);waitForExpectations(timeout:20)
            if run==0 {app.buttons["recorder.flip"].tap()}
        }
        XCTAssertFalse(app.alerts.firstMatch.exists)
        app.buttons["Edit this project"].tap()
        XCTAssertTrue(app.buttons["Export"].waitForExistence(timeout:60));app.buttons["Export"].tap()
        XCTAssertTrue(app.buttons["Export video"].waitForExistence(timeout:10));app.buttons["Export video"].tap()
        XCTAssertTrue(app.buttons["Share latest export"].waitForExistence(timeout:120))
        let export=XCTAttachment(screenshot:XCUIScreen.main.screenshot());export.name="Auto Background saved export";export.lifetime = .keepAlways;add(export)
        app.buttons["Done"].tap()
    }

    func testEffectPreviewsStayWithinSelectedRange() throws {
        continueAfterFailure=false;XCUIDevice.shared.orientation = .portrait
        let app=XCUIApplication();app.launchArguments=["--editor-preview","--reset-ui-fixture","--tracks-overlap-fixture"];app.launch()
        let mark=app.buttons["Mark start"],timeline=app.otherElements["editor.timeline"]
        XCTAssertTrue(mark.waitForExistence(timeout:30))
        expectation(for:NSPredicate(format:"enabled == true"),evaluatedWith:mark);waitForExpectations(timeout:45)
        app.buttons["Timeline view span"].tap();app.buttons["Whole project"].tap()
        func point(_ t:Double)->XCUICoordinate {timeline.coordinate(withNormalizedOffset:.zero).withOffset(CGVector(dx:48+(timeline.frame.width-96)*t/18,dy:10))}
        point(5.6).tap();mark.tap();point(7).tap();app.buttons["Mark end"].tap()
        openTool("videoEffects",in:app);openEffectSection("colorStyle",in:app)
        app.buttons["videoEffects.add.nightFix"].tap()
        let apply=app.buttons["videoEffects.apply"],slider=app.sliders["Preview position"]
        func ready() {expectation(for:NSPredicate(format:"exists == true AND enabled == true"),evaluatedWith:apply);waitForExpectations(timeout:40)}
        func numbers(_ element:XCUIElement)->[Double] {(element.value as? String ?? "").components(separatedBy:CharacterSet(charactersIn:"0123456789.").inverted).compactMap(Double.init)}
        ready();let bounds=numbers(slider);XCTAssertEqual(bounds.count,3)
        XCTAssertGreaterThan(bounds[0],5);XCTAssertLessThan(bounds[1],7.5)
        slider.adjust(toNormalizedSliderPosition:0);XCTAssertEqual(numbers(slider)[2],bounds[0],accuracy:0.04)
        slider.adjust(toNormalizedSliderPosition:1);XCTAssertLessThanOrEqual(numbers(slider)[2],bounds[1])
        app.buttons["Play preview"].tap()
        expectation(for:NSPredicate(format:"exists == true"),evaluatedWith:app.buttons["Play preview"]);waitForExpectations(timeout:6)
        XCTAssertLessThanOrEqual(numbers(slider)[2],bounds[1]+0.04)
        app.buttons["videoEffects.compare"].tap();ready();XCTAssertEqual(Array(numbers(slider).prefix(2)),Array(bounds.prefix(2)))
        app.buttons["Play preview"].tap()
        expectation(for:NSPredicate(format:"exists == true"),evaluatedWith:app.buttons["Play preview"]);waitForExpectations(timeout:6)
        let shot=XCTAttachment(screenshot:XCUIScreen.main.screenshot());shot.name="Selected range effects preview";shot.lifetime = .keepAlways;add(shot)
        app.buttons["Cancel"].tap();openTool("enhanceAudio",in:app)
        let audioPosition=app.staticTexts["audioTool.position"],play=app.buttons["Play preview"]
        XCTAssertTrue(play.waitForExistence(timeout:30));expectation(for:NSPredicate(format:"enabled == true"),evaluatedWith:play);waitForExpectations(timeout:40)
        XCTAssertEqual(Array(numbers(audioPosition).prefix(2)),Array(bounds.prefix(2)))
        play.tap();expectation(for:NSPredicate(format:"exists == true"),evaluatedWith:play);waitForExpectations(timeout:6)
        XCTAssertLessThanOrEqual(numbers(audioPosition)[2],bounds[1]+0.04)
        play.tap();expectation(for:NSPredicate(format:"exists == true"),evaluatedWith:play);waitForExpectations(timeout:6)
        XCTAssertGreaterThanOrEqual(numbers(audioPosition)[2],bounds[0])
        app.buttons["Bypass"].tap()
        expectation(for:NSPredicate(format:"enabled == true"),evaluatedWith:play);waitForExpectations(timeout:30)
        play.tap();expectation(for:NSPredicate(format:"exists == true"),evaluatedWith:play);waitForExpectations(timeout:6)
        XCTAssertLessThanOrEqual(numbers(audioPosition)[2],bounds[1]+0.04)
        app.buttons["Cancel"].tap()
    }

    func testNightFixSampleThenResumeFullApplication() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["YOUREC_EDITOR_FIXTURE_TITLE"] = "Effect application " + UUID().uuidString
        app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--slow-video-effect-preparation"]
        app.launch()
        openTool("videoEffects", in: app)
        openEffectSection("colorStyle", in: app)
        app.buttons["videoEffects.add.nightFix"].tap()
        let slider = app.sliders["Preview position"]
        XCTAssertTrue(slider.waitForExistence(timeout: 15))
        slider.adjust(toNormalizedSliderPosition: 0.50)
        let modes = app.segmentedControls["nightFix.mode"]
        if !modes.isHittable { app.scrollViews["videoEffects.controls"].swipeUp() }
        modes.buttons["Medium"].tap()
        let sample = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "10 s preview")).firstMatch
        XCTAssertTrue(sample.waitForExistence(timeout: 8))
        let stop = app.buttons["videoEffects.stopSample"], resume = app.buttons["videoEffects.resumeSample"]
        XCTAssertTrue(stop.waitForExistence(timeout: 8)); stop.tap()
        XCTAssertTrue(app.staticTexts["Preview stopped"].waitForExistence(timeout: 4))
        XCTAssertTrue(resume.isHittable); resume.tap()
        XCTAssertTrue(stop.waitForExistence(timeout: 6))
        app.buttons["videoEffects.apply"].tap()
        let applying = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Applying Night fix")).firstMatch
        XCTAssertTrue(applying.waitForExistence(timeout: 12))
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(applying.waitForExistence(timeout: 15))
        app.terminate()
        app.launchArguments = ["--editor-preview", "--slow-video-effect-preparation"]
        app.launch()
        XCTAssertTrue(applying.waitForExistence(timeout: 20))
        let undo = app.buttons["editor.undoApplication"]
        XCTAssertTrue(undo.waitForExistence(timeout: 10)); undo.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: applying)
        waitForExpectations(timeout: 15)
        XCTAssertTrue(app.buttons["Redo"].isEnabled)
        app.buttons["Redo"].tap()
        XCTAssertTrue(applying.waitForExistence(timeout: 12))
        let effect = app.buttons["effect.videoEffects"].firstMatch
        XCTAssertTrue(effect.waitForExistence(timeout: 5)); effect.press(forDuration: 0.8)
        app.buttons["effect.confirmRemove"].tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: applying)
        waitForExpectations(timeout: 8)
        XCTAssertFalse(effect.exists)

    }

    func testNightFixControlsApplyAndReopen() throws {
        continueAfterFailure=false;XCUIDevice.shared.orientation = .portrait
        let app=XCUIApplication();app.launchArguments=["--editor-preview","--reset-ui-fixture"];app.launch()
        openTool("videoEffects",in:app);openEffectSection("colorStyle",in:app)
        let add=app.buttons["videoEffects.add.nightFix"];XCTAssertTrue(add.waitForExistence(timeout:15));add.tap()
        let apply=app.buttons["videoEffects.apply"],controls=app.scrollViews["videoEffects.controls"]
        func ready() {expectation(for:NSPredicate(format:"exists == true AND enabled == true"),evaluatedWith:apply);waitForExpectations(timeout:45)}
        func show(_ item:XCUIElement) {
            for _ in 0..<12 {
                if item.isHittable && item.frame.minY >= controls.frame.minY+8 && item.frame.maxY <= controls.frame.maxY-20 {break}
                let up=item.frame.midY>controls.frame.midY
                let a=controls.coordinate(withNormalizedOffset:CGVector(dx:0.08,dy:up ? 0.8 : 0.25)),b=controls.coordinate(withNormalizedOffset:CGVector(dx:0.08,dy:up ? 0.25 : 0.8))
                a.press(forDuration:0.05,thenDragTo:b,withVelocity:.slow,thenHoldForDuration:0.1)
            }
            XCTAssertTrue(item.isHittable)
        }
        ready()
        let scrubber = app.sliders["Preview position"]
        app.buttons["Play preview"].tap()
        for position in [0.72, 0.17, 0.61, 0.12] { scrubber.adjust(toNormalizedSliderPosition: position) }
        let modes=app.segmentedControls["nightFix.mode"]
        show(modes);XCTAssertTrue(modes.buttons["Fast"].isSelected)
        XCTAssertFalse(app.otherElements["videoEffects.refinement"].exists)
        modes.buttons["Precise"].tap();ready();modes.buttons["Medium"].tap();ready()
        XCTAssertTrue(modes.buttons["Medium"].isSelected)
        let modeShot=XCTAttachment(screenshot:XCUIScreen.main.screenshot());modeShot.name="Night fix three modes";modeShot.lifetime = .keepAlways;self.add(modeShot)
        let brightness=app.sliders["videoEffects.slider.brightness"],reduction=app.sliders["videoEffects.slider.reduction"]
        show(brightness);brightness.adjust(toNormalizedSliderPosition:0.75);ready()
        show(reduction);reduction.adjust(toNormalizedSliderPosition:1);ready();XCTAssertEqual(reduction.value as? String,"300%")
        XCTAssertTrue(app.staticTexts["nightFix.strongWarning"].exists)
        let portrait=XCTAttachment(screenshot:XCUIScreen.main.screenshot());portrait.name="Night fix portrait controls";portrait.lifetime = .keepAlways;self.add(portrait)
        XCUIDevice.shared.orientation = .landscapeLeft
        expectation(for:NSPredicate {_,_ in app.windows.firstMatch.frame.width>app.windows.firstMatch.frame.height},evaluatedWith:app.windows.firstMatch);waitForExpectations(timeout:5)
        XCTAssertTrue(app.buttons["videoEffects.compare"].isHittable);app.buttons["videoEffects.compare"].tap();ready();app.buttons["videoEffects.compare"].tap();ready()
        let landscape=XCTAttachment(screenshot:XCUIScreen.main.screenshot());landscape.name="Night fix landscape controls";landscape.lifetime = .keepAlways;self.add(landscape)
        apply.tap();XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout:15));app.buttons["Undo"].tap();app.buttons["Redo"].tap()
        app.terminate();app.launchArguments=["--editor-preview"];app.launch();XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout:30));app.buttons["Tools"].tap()
        let existing=app.buttons["tools.existing.videoEffects"]
        for _ in 0..<6 {if existing.isHittable {break};app.scrollViews.firstMatch.swipeUp()};existing.tap();ready()
        app.buttons.matching(NSPredicate(format:"label == 'Night fix' AND identifier BEGINSWITH 'videoEffects.edit.'")).firstMatch.tap()
        show(modes);XCTAssertTrue(modes.buttons["Medium"].isSelected,"Mode survives Apply, Undo/Redo and reopening")
        show(reduction);XCTAssertEqual(reduction.value as? String,"300%","Noise reduction slider remains at its 300% maximum after reopening")
        app.buttons["Cancel"].tap();XCUIDevice.shared.orientation = .portrait
    }

    func testColorCorrectionControlsApplyAndReopen() throws {
        continueAfterFailure=false;XCUIDevice.shared.orientation = .portrait
        let app=XCUIApplication();app.launchArguments=["--editor-preview","--reset-ui-fixture"];app.launch()
        openTool("videoEffects",in:app);openEffectSection("colorStyle",in:app)
        let addEffect=app.buttons["videoEffects.add.colorCorrection"]
        XCTAssertTrue(addEffect.waitForExistence(timeout:15));addEffect.tap()
        let apply=app.buttons["videoEffects.apply"],controls=app.scrollViews["videoEffects.controls"]
        func ready() {expectation(for:NSPredicate(format:"exists == true AND enabled == true"),evaluatedWith:apply);waitForExpectations(timeout:40)}
        func scroll(up:Bool) {
            // Scroll from the panel gutter, away from native slider thumbs.
            let start=controls.coordinate(withNormalizedOffset:CGVector(dx:0.015,dy:up ? 0.85 : 0.25))
            let end=controls.coordinate(withNormalizedOffset:CGVector(dx:0.015,dy:up ? 0.25 : 0.85))
            start.press(forDuration:0.05,thenDragTo:end,withVelocity:.slow,thenHoldForDuration:0.1)
        }
        func show(_ item:XCUIElement) {for _ in 0..<8 {if item.isHittable {break};scroll(up:true)};XCTAssertTrue(item.isHittable)}
        ready()
        let exposure=app.sliders["colorCorrection.slider.exposure"],exposureValue=app.buttons["colorCorrection.value.exposure"]
        XCTAssertTrue(exposure.isHittable);exposure.adjust(toNormalizedSliderPosition:0.65);ready()
        XCTAssertNotEqual(exposureValue.value as? String,"+0.00 EV")
        exposureValue.tap();ready();XCTAssertEqual(exposureValue.value as? String,"+0.00 EV")
        app.staticTexts["Exposure"].press(forDuration:0.8)
        XCTAssertTrue(app.alerts["Exposure"].waitForExistence(timeout:5));app.buttons["Got it"].tap()
        let animation = app.buttons["effect.animation"]
        if !animation.isHittable { revealInViewport(animation,scroll:controls,swipeX:0.015) }
        endpointAction("B",in:app); ready()
        show(exposure); exposure.adjust(toNormalizedSliderPosition:0.6); ready()
        XCTAssertNotEqual(exposureValue.value as? String,"+0.00 EV")
        if !animation.isHittable { revealInViewport(animation,scroll:controls,swipeX:0.015) }
        endpointAction("Remove animation",in:app); ready()
        let tabs=app.segmentedControls["colorCorrection.tabs"]
        tabs.buttons["Color"].tap()
        let saturation=app.sliders["colorCorrection.slider.saturation"],satValue=app.buttons["colorCorrection.value.saturation"]
        show(saturation);saturation.adjust(toNormalizedSliderPosition:0);ready();
        saturation.coordinate(withNormalizedOffset:CGVector(dx:0.03,dy:0.5)).press(forDuration:0.1,thenDragTo:saturation.coordinate(withNormalizedOffset:CGVector(dx:-0.15,dy:0.5)));ready();XCTAssertEqual(satValue.value as? String,"0%")
        let portrait=XCTAttachment(screenshot:XCUIScreen.main.screenshot());portrait.name="Color correction portrait";portrait.lifetime = .keepAlways;self.add(portrait)
        app.buttons["videoEffects.compare"].tap();ready();app.buttons["videoEffects.compare"].tap();ready()
        XCUIDevice.shared.orientation = .landscapeLeft
        expectation(for:NSPredicate {_,_ in app.windows.firstMatch.frame.width>app.windows.firstMatch.frame.height},evaluatedWith:app.windows.firstMatch);waitForExpectations(timeout:5)
        let settled=expectation(description:"Rotation settles");DispatchQueue.main.asyncAfter(deadline:.now()+0.8) {settled.fulfill()};wait(for:[settled],timeout:2)
        XCTAssertTrue(app.buttons["videoEffects.compare"].isHittable)
        XCTAssertTrue(tabs.buttons["Color"].isSelected,"Rotating keeps the chosen correction section")
        let landscape=XCTAttachment(screenshot:XCUIScreen.main.screenshot());landscape.name="Color correction landscape";landscape.lifetime = .keepAlways;self.add(landscape)
        apply.tap();XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout:10))
        app.buttons["Undo"].tap();app.buttons["Redo"].tap()
        app.terminate();app.launchArguments=["--editor-preview"];app.launch()
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout:25));app.buttons["Tools"].tap()
        let existing=app.buttons["tools.existing.videoEffects"]
        for _ in 0..<6 {if existing.isHittable {break};app.scrollViews.firstMatch.swipeUp()};existing.tap();ready()
        app.buttons.matching(NSPredicate(format:"label == 'Color Correction' AND identifier BEGINSWITH 'videoEffects.edit.'")).firstMatch.tap()
        XCUIDevice.shared.orientation = .portrait
        tabs.buttons["Color"].tap();show(satValue);XCTAssertEqual(satValue.value as? String,"0%")
        let reset=app.buttons["colorCorrection.resetAll"];show(reset);reset.tap()
        app.buttons["Reset all adjustments"].tap();ready()
        for _ in 0..<8 {if satValue.isHittable {break};scroll(up:false)}
        XCTAssertEqual(satValue.value as? String,"100%")
        app.buttons["Cancel"].tap();XCUIDevice.shared.orientation = .portrait
    }

    func testLiveColorCorrectionControls() throws {
        continueAfterFailure=false;XCUIDevice.shared.orientation = .portrait
        let app=XCUIApplication();app.launchArguments=["--recorder-controls-test"];app.launch()
        XCTAssertTrue(app.buttons["recorder.videoEffects"].waitForExistence(timeout:20));app.buttons["recorder.videoEffects"].tap()
        let clear=app.buttons["liveEffects.actions"],controls=app.scrollViews["liveEffects.controls"]
        if clear.waitForExistence(timeout:2) {for _ in 0..<8 {if clear.isHittable {break};controls.swipeUp()};clearLiveEffects(in: app)}
        openEffectSection("colorStyle",in:app,live:true)
        app.buttons["liveEffects.add.colorCorrection"].tap()
        expandLiveEffects(in: app)
        let exposure=app.sliders["colorCorrection.slider.exposure"]
        XCTAssertTrue(exposure.waitForExistence(timeout:10));exposure.adjust(toNormalizedSliderPosition:0.65)
        app.buttons["colorCorrection.value.exposure"].tap()
        XCTAssertEqual(app.buttons["colorCorrection.value.exposure"].value as? String,"+0.00 EV")
        app.segmentedControls["colorCorrection.tabs"].buttons["Color"].tap()
        let temperature=app.sliders["colorCorrection.slider.temperature"]
        temperature.adjust(toNormalizedSliderPosition:0.7)
        XCTAssertNotEqual(app.buttons["colorCorrection.value.temperature"].value as? String,"0")
        let image=XCTAttachment(screenshot:XCUIScreen.main.screenshot());image.name="Live color correction";image.lifetime = .keepAlways;add(image)
        backFromLiveEffects(in: app);clearLiveEffects(in: app);dismissLiveEffects(in: app)
    }

    func testWidescreenOnSelectedClipPlaybackAndApply() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview"]
        app.launchEnvironment["YOUREC_EDITOR_FIXTURE_TITLE"] = "Widescreen · UI test"
        app.launch()
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 30))
        seekTimeline(fraction: 0.92, in: app)
        let seventh = app.buttons["timeline.video.7"]
        if app.buttons["Whole project"].exists { app.buttons["Whole project"].tap() }
        if seventh.exists {
            seventh.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.83)).tap()
        }
        let tools = app.buttons["Tools"]
        expectation(for: NSPredicate(format: "enabled == true AND hittable == true"), evaluatedWith: tools)
        waitForExpectations(timeout: 50)
        openTool("videoEffects", in: app)
        let addEffect = app.buttons["Add effect"]
        if addEffect.exists { addEffect.tap() }
        openEffectSection("cameraFrame", in: app)
        let wide = app.buttons["videoEffects.add.widescreen"]
        let controls = app.scrollViews["videoEffects.controls"]
        for _ in 0..<6 { if wide.isHittable { break }; controls.swipeUp() }
        wide.tap()
        let apply = app.buttons["videoEffects.apply"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: apply)
        waitForExpectations(timeout: 60)
        app.sliders["Preview position"].adjust(toNormalizedSliderPosition: 0.60)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Widescreen 1953 preview"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["Play preview"].tap()
        XCTAssertTrue(app.buttons["Pause preview"].waitForExistence(timeout: 8))
        let scrubber = app.sliders["Preview position"]
        for fraction in [0.2, 0.68, 0.12, 0.55, 0.22] { scrubber.adjust(toNormalizedSliderPosition: fraction) }
        apply.tap()
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 25))
        let play = app.buttons["Play"].firstMatch
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play)
        waitForExpectations(timeout: 40)
        play.tap()
        XCTAssertTrue(app.buttons["Pause playback"].firstMatch.waitForExistence(timeout: 8))
        app.buttons["Pause playback"].firstMatch.tap()
        app.buttons["Undo"].tap()
    }

    func testVideoEffectsPreviewApplyAndReopen() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]; app.launch()
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 25))
        openTool("videoEffects", in: app)
        openEffectSection("colorStyle",in:app)
        let tint = app.buttons["videoEffects.add.silentTint"]
        XCTAssertTrue(tint.waitForExistence(timeout: 15))
        for _ in 0..<5 {if tint.isHittable {break};app.scrollViews["videoEffects.controls"].swipeUp()}
        tint.tap()
        let apply = app.buttons["videoEffects.apply"]
        expectation(for: NSPredicate(format: "exists == true AND enabled == true"), evaluatedWith: apply); waitForExpectations(timeout: 30)
        XCTAssertTrue(app.buttons["videoEffects.compare"].exists)
        app.buttons["videoEffects.compare"].tap()
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: apply); waitForExpectations(timeout: 30)
        app.buttons["videoEffects.compare"].tap()
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: apply); waitForExpectations(timeout: 30)
        let portrait = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); portrait.name = "Video effects portrait"; portrait.lifetime = .keepAlways; add(portrait)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["videoEffects.compare"].waitForExistence(timeout: 5))
        let landscape = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); landscape.name = "Video effects landscape"; landscape.lifetime = .keepAlways; add(landscape)
        apply.tap()
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 10))
        app.buttons["Tools"].tap()
        let existing = app.buttons["tools.existing.videoEffects"]
        for _ in 0..<6 { if existing.isHittable { break }; app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(existing.isHittable); existing.tap()
        XCTAssertTrue(app.buttons["videoEffects.apply"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Silent Tint"].exists)
        XCUIDevice.shared.orientation = .portrait
    }

    func testAddingAnEffectPreservesBackgroundAndSupportsCancel() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--background-position-fixture"]; app.launch()
        let apply = app.buttons["videoEffects.apply"], controls = app.scrollViews["videoEffects.controls"]
        func ready() {
            expectation(for: NSPredicate(format: "exists == true AND enabled == true"), evaluatedWith: apply)
            waitForExpectations(timeout: 45)
        }
        func addTint() {
            app.buttons["videoEffects.browse"].tap(); openEffectSection("colorStyle", in: app)
            app.buttons["videoEffects.add.silentTint"].tap(); ready()
            app.buttons["videoEffects.back"].tap()
        }
        openTool("videoEffects", in: app); ready(); addTint()
        XCTAssertTrue(app.buttons["Chroma Key"].firstMatch.exists); app.buttons["Cancel"].tap()
        openTool("videoEffects", in: app); ready(); XCTAssertFalse(app.buttons["Silent Tint"].exists)
        addTint(); apply.tap(); XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 10))
        openTool("videoEffects", in: app); ready()
        XCTAssertTrue(app.buttons["Silent Tint"].exists); app.buttons["Chroma Key"].firstMatch.tap()
        let position = app.buttons["videoEffects.positionBackground"]
        for _ in 0..<5 { if position.isHittable { break }; controls.swipeUp() }
        XCTAssertTrue(position.isHittable, "Adding an individual effect retains the imported background")
    }

    func testBackgroundPositionPanPinchRevertAndKeep() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--editor-preview","--reset-ui-fixture","--background-position-fixture"];app.launch()
        openTool("videoEffects",in:app)
        let effect=app.buttons["Chroma Key"].firstMatch
        if effect.waitForExistence(timeout:10) {effect.tap()}
        let position=app.buttons["videoEffects.positionBackground"]
        let controls=app.scrollViews["videoEffects.controls"]
        for _ in 0..<6 {if position.isHittable {break};controls.swipeUp()}
        XCTAssertTrue(position.isHittable)
        let preview=app.otherElements["videoEffects.preview"],bar=app.otherElements["videoEffects.positionBar"]
        func enter() {
            position.tap()
            expectation(for:NSPredicate(format:"exists == true AND enabled == true"),evaluatedWith:app.buttons["videoEffects.positionDone"]);waitForExpectations(timeout:30)
        }
        enter();XCTAssertFalse(app.buttons["Play preview"].isEnabled);let original=bar.value as? String
        let center=preview.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)),right=preview.coordinate(withNormalizedOffset:CGVector(dx:0.7,dy:0.5))
        center.press(forDuration:0.1,thenDragTo:right)
        XCTAssertNotEqual(bar.value as? String,original)
        preview.pinch(withScale:1.3,velocity:1)
        XCTAssertTrue(app.buttons["videoEffects.positionRevert"].isHittable)
        app.buttons["videoEffects.positionRevert"].tap()
        expectation(for:NSPredicate(format:"enabled == true"),evaluatedWith:position);waitForExpectations(timeout:30)
        enter();XCTAssertEqual(bar.value as? String,original)
        center.press(forDuration:0.1,thenDragTo:right)
        let moved=bar.value as? String
        app.buttons["videoEffects.positionDone"].tap()
        expectation(for:NSPredicate(format:"enabled == true"),evaluatedWith:position);waitForExpectations(timeout:30)
        enter();XCTAssertEqual(bar.value as? String,moved)
        XCUIDevice.shared.orientation = .landscapeLeft
        let settled=expectation(description:"Rotation settles");DispatchQueue.main.asyncAfter(deadline:.now()+1){settled.fulfill()};wait(for:[settled],timeout:3)
        XCTAssertTrue(app.buttons["videoEffects.positionDone"].isHittable)
        XCTAssertLessThanOrEqual(preview.frame.maxY,bar.frame.minY+2)
        let shot=XCTAttachment(screenshot:XCUIScreen.main.screenshot());shot.name="Background positioning landscape";shot.lifetime = .keepAlways;add(shot)
        app.buttons["videoEffects.positionDone"].tap();XCUIDevice.shared.orientation = .portrait
    }

    func testSavingQuantizationPaletteFromPreview() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]
        app.launch()
        openTool("videoEffects", in: app)
        openEffectSection("colorStyle", in: app)
        let controls = app.scrollViews["videoEffects.controls"]
        let add = app.buttons["videoEffects.add.quantization"]
        revealInViewport(add, scroll: controls)
        add.tap()
        let save = app.buttons["Save palette from this frame"]
        revealInViewport(save, scroll: controls)
        save.tap()
        XCTAssertTrue(app.staticTexts["Palette saved in this project"].waitForExistence(timeout: 20))
        let apply = app.buttons["videoEffects.apply"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: apply)
        waitForExpectations(timeout: 40)
        apply.tap()
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 20))
    }

    func testVideoEffectColorPickerAndInspection() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--editor-preview","--reset-ui-fixture"];app.launch()
        openTool("videoEffects",in:app)
        openEffectSection("colorStyle",in:app)
        let controls=app.scrollViews["videoEffects.controls"],isolation=app.buttons["videoEffects.add.colorIsolation"]
        revealInViewport(isolation, scroll: controls)
        XCTAssertTrue(isolation.isHittable);isolation.tap()
        let apply=app.buttons["videoEffects.apply"]
        func ready() { expectation(for:NSPredicate(format:"exists == true AND enabled == true"),evaluatedWith:apply);waitForExpectations(timeout:45) }
        ready()
        let pick=app.buttons["videoEffects.pickColor"]
        revealInViewport(pick, scroll: controls)
        XCTAssertTrue(pick.isHittable);pick.tap();ready()
        let preview=app.otherElements["videoEffects.preview"]
        XCTAssertTrue(app.buttons["videoEffects.cancelPick"].exists)
        preview.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).tap();ready()
        XCTAssertFalse(app.buttons["videoEffects.cancelPick"].exists)
        preview.pinch(withScale:2,velocity:1)
        let reset=app.buttons["editor.preview.resetZoom"]
        XCTAssertTrue(reset.isHittable);XCTAssertTrue(app.buttons["videoEffects.compare"].isHittable)
        let inspected=preview.value as? String
        app.buttons["videoEffects.compare"].tap();ready()
        XCTAssertEqual(preview.value as? String,inspected,"Comparing the original preserves inspection framing")
        app.buttons["videoEffects.compare"].tap();ready();XCTAssertEqual(preview.value as? String,inspected)
        let screenshot=XCTAttachment(screenshot:XCUIScreen.main.screenshot());screenshot.name="Effect colour picker and inspection";screenshot.lifetime = .keepAlways;add(screenshot)
        reset.tap();XCTAssertFalse(reset.exists)
        apply.tap();XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout:10))
    }

    func testEffectLibrarySectionsAndWrappedChoices() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--editor-preview","--reset-ui-fixture"];app.launch()
        openTool("videoEffects",in:app)
        let controls=app.scrollViews["videoEffects.controls"],apply=app.buttons["videoEffects.apply"]
        func ready() {expectation(for:NSPredicate(format:"exists == true AND enabled == true"),evaluatedWith:apply);waitForExpectations(timeout:45)}
        // Every category is reached with vertical scrolling only, in both layouts.
        for orientation in [UIDeviceOrientation.portrait,.landscapeLeft] {
            XCUIDevice.shared.orientation=orientation
            XCTAssertFalse(app.buttons["videoEffects.section.presets"].exists)
            for (section,effect) in [("colorStyle","videoEffects.add.silentTint"),("cameraFrame","videoEffects.add.dollyZoom"),("time","videoEffects.add.freezeFrame"),("background","videoEffects.add.autoBackground")] {
                openEffectSection(section,in:app)
                XCTAssertTrue(app.buttons[effect].waitForExistence(timeout:5))
                XCTAssertTrue(app.buttons["videoEffects.back"].isHittable);app.buttons["videoEffects.back"].tap()
            }
            let shot=XCTAttachment(screenshot:XCUIScreen.main.screenshot());shot.name="Effect sections \(orientation == .portrait ? "portrait" : "landscape")";shot.lifetime = .keepAlways;add(shot)
        }
        XCUIDevice.shared.orientation = .portrait
        openEffectSection("colorStyle",in:app)
        let quant=app.buttons["videoEffects.add.quantization"]
        for _ in 0..<12 {if quant.isHittable {break};controls.swipeUp()}
        XCTAssertTrue(quant.isHittable);quant.tap();ready()
        let last=app.buttons["Colors 16"],first=app.buttons["Colors 2"]
        for _ in 0..<8 {if last.isHittable {break};controls.swipeUp()}
        XCTAssertTrue(first.isHittable);XCTAssertTrue(last.isHittable,"All color-count choices fit without horizontal scrolling")
        last.tap();ready();app.buttons["videoEffects.back"].tap()
        let quantRow=app.buttons["Quantization"].firstMatch
        XCTAssertTrue(quantRow.isHittable)
        let toggle=app.switches["Enable Quantization"]
        XCTAssertEqual(toggle.value as? String,"1");toggle.tap();ready();XCTAssertEqual(toggle.value as? String,"0")
        app.buttons["videoEffects.browse"].tap(); openEffectSection("colorStyle", in: app)
        app.buttons["videoEffects.add.silentTint"].tap(); ready(); app.buttons["videoEffects.back"].tap()
        XCTAssertTrue(app.buttons["Silent Tint"].exists); XCTAssertTrue(quantRow.exists)
        XCTAssertEqual(toggle.value as? String, "0", "Adding an individual effect keeps the existing stack")
    }

    func testEffectSwipeAndTimelineRemoval() throws {
        continueAfterFailure=false
        XCUIDevice.shared.orientation = .portrait
        let app=XCUIApplication();app.launchArguments=["--editor-preview","--reset-ui-fixture"];app.launch()
        openTool("videoEffects",in:app);openEffectSection("colorStyle",in:app)
        app.buttons["videoEffects.add.silentTint"].tap()
        app.buttons["videoEffects.back"].tap();app.buttons["videoEffects.browse"].tap();openEffectSection("colorStyle",in:app)
        let noir=app.buttons["videoEffects.add.threeStrip"],controls=app.scrollViews["videoEffects.controls"]
        for _ in 0..<8 {if noir.isHittable {break};controls.swipeUp()}
        XCTAssertTrue(noir.isHittable);noir.tap();app.buttons["videoEffects.back"].tap()
        let apply=app.buttons["videoEffects.apply"]
        expectation(for:NSPredicate(format:"exists == true AND enabled == true"),evaluatedWith:apply);waitForExpectations(timeout:45)
        let row=app.cells.containing(.button,identifier:"Three-Strip").firstMatch
        XCTAssertTrue(row.exists)
        row.coordinate(withNormalizedOffset:CGVector(dx:0.7,dy:0.5)).press(forDuration:0.05,thenDragTo:row.coordinate(withNormalizedOffset:CGVector(dx:0.3,dy:0.5)),withVelocity:.slow,thenHoldForDuration:0.1)
        let delete=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","videoEffects.delete.")).firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout:5));delete.tap()
        XCTAssertFalse(app.buttons["Three-Strip"].exists);XCTAssertTrue(app.buttons["Silent Tint"].exists)
        expectation(for:NSPredicate(format:"exists == true AND enabled == true"),evaluatedWith:apply);waitForExpectations(timeout:45)
        apply.tap();XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout:15))
        let bubble=app.buttons["effect.videoEffects"].firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout:10));bubble.press(forDuration:0.8)
        let confirm=app.buttons["effect.confirmRemove"],cancel=app.buttons["effect.cancelRemove"]
        XCTAssertTrue(confirm.waitForExistence(timeout:5));XCTAssertTrue(cancel.isHittable)
        XCTAssertFalse(app.buttons["videoEffects.apply"].exists,"Long press must not open the inspector")
        let shot=XCTAttachment(screenshot:XCUIScreen.main.screenshot());shot.name="Timeline effect removal controls";shot.lifetime = .keepAlways;add(shot)
        cancel.tap();XCTAssertTrue(bubble.exists)
        XCUIDevice.shared.orientation = .landscapeLeft
        expectation(for:NSPredicate {_,_ in app.windows.firstMatch.frame.width>app.windows.firstMatch.frame.height},evaluatedWith:app.windows.firstMatch);waitForExpectations(timeout:5)
        let settled=expectation(description:"Rotation settles")
        DispatchQueue.main.asyncAfter(deadline:.now()+0.6) {settled.fulfill()};wait(for:[settled],timeout:2)
        bubble.press(forDuration:0.8);XCTAssertTrue(cancel.waitForExistence(timeout:5));XCTAssertTrue(cancel.isHittable);XCTAssertTrue(confirm.isHittable)
        let landscape=XCTAttachment(screenshot:XCUIScreen.main.screenshot());landscape.name="Timeline removal landscape";landscape.lifetime = .keepAlways;add(landscape)
        confirm.tap()
        XCTAssertFalse(bubble.exists);app.buttons["Undo"].tap();XCTAssertTrue(bubble.waitForExistence(timeout:10))
        bubble.tap();XCTAssertTrue(app.buttons["videoEffects.apply"].waitForExistence(timeout:15))
        XCUIDevice.shared.orientation = .portrait
    }

    func testChromaScreenControlsAndLiveSwipe() throws {
        continueAfterFailure=false
        XCUIDevice.shared.orientation = .portrait
        let app=XCUIApplication();app.launchArguments=["--recorder-controls-test"];app.launch()
        XCTAssertTrue(app.buttons["recorder.videoEffects"].waitForExistence(timeout:15));app.buttons["recorder.videoEffects"].tap()
        if app.buttons["liveEffects.actions"].waitForExistence(timeout:2) {clearLiveEffects(in: app)}
        openEffectSection("background",in:app,live:true);app.buttons["liveEffects.add.chromaKey"].tap()
        expandLiveEffects(in: app)
        let controls=app.scrollViews["liveEffects.controls"],detect=app.switches["Detect green / blue screen"]
        for _ in 0..<6 {if detect.isHittable {break};controls.swipeUp()}
        XCTAssertTrue(detect.isHittable);detect.tap()
        XCTAssertTrue(app.buttons["Green"].waitForExistence(timeout:5));XCTAssertTrue(app.buttons["Blue"].exists)
        app.buttons["Blue"].tap();XCTAssertTrue(app.buttons["effects.sampleScreen"].exists)
        let shot=XCTAttachment(screenshot:XCUIScreen.main.screenshot());shot.name="Supported screen colors";shot.lifetime = .keepAlways;add(shot)
        backFromLiveEffects(in: app)
        let row=app.cells.containing(.button,identifier:"Chroma Key").firstMatch
        XCTAssertTrue(row.exists)
        row.coordinate(withNormalizedOffset:CGVector(dx:0.7,dy:0.5)).press(forDuration:0.05,thenDragTo:row.coordinate(withNormalizedOffset:CGVector(dx:0.3,dy:0.5)),withVelocity:.slow,thenHoldForDuration:0.1)
        let delete=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","liveEffects.delete.")).firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout:5));delete.tap()
        XCTAssertTrue(app.buttons["liveEffects.section.background"].waitForExistence(timeout:5))
        XCTAssertFalse(app.buttons["Chroma Key"].exists)
    }

    private func openEffectSection(_ section:String,in app:XCUIApplication,live:Bool=false) {
        let prefix=live ? "liveEffects" : "videoEffects"
        let button=app.buttons[prefix+".section."+section],controls=app.scrollViews[prefix+".controls"]
        XCTAssertTrue(button.waitForExistence(timeout:15))
        for _ in 0..<6 {if button.isHittable {break};controls.swipeUp()}
        XCTAssertTrue(button.isHittable);button.tap()
    }

    private func selectTransitionStyle(_ name: String, in app: XCUIApplication) {
        for _ in 0..<8 { if app.buttons["transition.stylePicker"].isHittable { break }; app.scrollViews["transition.controls"].swipeDown() }
        app.buttons["transition.stylePicker"].tap()
        let style = app.buttons["transition.style." + name]
        XCTAssertTrue(style.waitForExistence(timeout: 5))
        for _ in 0..<5 { if style.isHittable { break }; app.scrollViews.firstMatch.swipeUp() }
        style.tap()
    }

    func testExpandedTransitionControlsAndAudioPersistence() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]; app.launch()
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 25))
        let timeline = app.otherElements["editor.timeline"]
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.85)).tap(); app.buttons["Split"].tap()
        openTimelineTransition(in: app)
        let apply = app.buttons["transition.apply"]
        func ready() { expectation(for: NSPredicate(format: "exists == true AND enabled == true"), evaluatedWith: apply); waitForExpectations(timeout: 40) }
        func show(_ element: XCUIElement) {
            for _ in 0..<8 { if element.isHittable { break }; app.scrollViews["transition.controls"].swipeUp() }
            XCTAssertTrue(element.isHittable)
        }
        ready()
        for (style, control) in [("fadeBlack", "transition.fadeColor"), ("wipe", "transition.wipeEdge"), ("hitchcock", "transition.luminanceOrder"), ("whip", "transition.axis"), ("flashCut", "transition.flashes"), ("still", "transition.stillExit"), ("defocus", "transition.blur")] {
            selectTransitionStyle(style, in: app)
            let element = app.descendants(matching: .any)[control].firstMatch; show(element)
            if style == "wipe" { app.segmentedControls[control].buttons["Hard edge"].tap(); app.sliders["transition.wipeAngle"].adjust(toNormalizedSliderPosition: 0.65) }
            if style == "hitchcock" { app.segmentedControls[control].buttons["Highlights first"].tap() }
            if style == "whip" {
                XCTAssertTrue((app.buttons["transition.timing"].value as? String ?? "").replacingOccurrences(of: ",", with: ".").hasPrefix("0.27"), "Whip starts at eight frames")
                chooseTransitionDuration("1", in: app)
            }
            if style == "still" { app.segmentedControls[control].buttons["Dissolve"].tap() }
            ready()
        }
        let earlier = app.buttons["transition.audioEarlier"]; show(earlier); earlier.tap(); earlier.tap()
        let blend = app.sliders["transition.audioBlend"]; show(blend); blend.adjust(toNormalizedSliderPosition: 0.04)
        ready()
        let shorter = app.buttons["transition.audioShorter"]; show(shorter); shorter.tap()
        let longer = app.buttons["transition.audioLonger"]; longer.tap(); ready()
        let offset = app.staticTexts["transition.audioOffset.value"].label
        let blendValue = app.staticTexts["transition.audioBlend.value"].label
        XCTAssertTrue(offset.replacingOccurrences(of: ",", with: ".").hasPrefix("-0.20"))
        let portrait = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); portrait.name = "Transition audio timing portrait"; portrait.lifetime = .keepAlways; add(portrait)
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        show(app.buttons["transition.audioLonger"])
        app.scrollViews["transition.controls"].swipeUp()
        let landscape = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); landscape.name = "Transition audio timing landscape"; landscape.lifetime = .keepAlways; add(landscape)
        apply.tap(); XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 15))
        let reopen = app.buttons.matching(NSPredicate(format: "identifier IN %@", ["editor.transition", "effect.transition"])).firstMatch
        XCTAssertTrue(reopen.waitForExistence(timeout: 10)); reopen.tap(); ready()
        show(blend)
        XCTAssertEqual(app.staticTexts["transition.audioOffset.value"].label, offset)
        XCTAssertEqual(app.staticTexts["transition.audioBlend.value"].label, blendValue)
        app.buttons["Cancel"].tap()
        app.buttons["Undo"].tap(); app.buttons["Redo"].tap()
        XCTAssertTrue(reopen.waitForExistence(timeout: 10)); reopen.tap(); ready(); show(blend)
        XCTAssertEqual(app.staticTexts["transition.audioOffset.value"].label, offset)
        XCTAssertEqual(app.staticTexts["transition.audioBlend.value"].label, blendValue)
        app.buttons["Cancel"].tap()
    }

    func testTransitionsBoundarySplitFramingAndHistory() throws {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]; app.launch()
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 25))
        let originalDuration = app.staticTexts["editor.duration"].label
        seekTimeline(fraction: 0.25, in: app)
        XCTAssertFalse(app.buttons["editor.transition"].exists)
        app.buttons["Tools"].tap()
        XCTAssertTrue(app.scrollViews["tools.content"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["tools.transition"].exists)
        app.buttons["Done"].tap()
        let timeline = app.otherElements["editor.timeline"]
        app.buttons["Timeline view span"].tap(); app.buttons["Whole project"].tap()
        timeline.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: timeline.frame.width * 0.5, dy: 10)).tap()
        app.buttons["Split"].tap()
        openTimelineTransition(in: app)
        let apply = app.buttons["transition.apply"]
        expectation(for: NSPredicate(format: "exists == true AND enabled == true"), evaluatedWith: apply); waitForExpectations(timeout: 40)
        selectTransitionStyle("split", in: app)
        XCTAssertTrue(app.segmentedControls["transition.axis"].buttons["Top / bottom"].isSelected, "Portrait footage starts with two useful wide panes")
        app.segmentedControls["transition.axis"].buttons["Left / right"].tap()
        selectTransitionStyle("dissolve", in: app); selectTransitionStyle("split", in: app)
        XCTAssertTrue(app.segmentedControls["transition.axis"].buttons["Left / right"].isSelected, "Changing styles preserves the chosen axis")
        chooseTransitionDuration("0.5", in: app)
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: apply); waitForExpectations(timeout: 40)
        let surface = app.otherElements["transition.framing"]
        XCTAssertTrue(surface.exists)
        let initialFraming = surface.value as? String
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1, thenDragTo: surface.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5)))
        XCTAssertNotEqual(surface.value as? String, initialFraming, "Dragging the divider changes its position")
        let divided = surface.value as? String
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.4)).press(forDuration: 0.1, thenDragTo: surface.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.4)))
        XCTAssertNotEqual(surface.value as? String, divided, "Dragging within a picture changes its framing")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Transition split portrait framing"; shot.lifetime = .keepAlways; add(shot)
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(app.segmentedControls["transition.axis"].waitForExistence(timeout: 5))
        app.segmentedControls["transition.axis"].buttons["Top / bottom"].tap()
        let landscape = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); landscape.name = "Transition split landscape controls"; landscape.lifetime = .keepAlways; add(landscape)
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: apply); waitForExpectations(timeout: 40)
        app.buttons["transition.play"].tap()
        XCTAssertTrue(app.buttons["Pause transition"].waitForExistence(timeout: 5))
        apply.tap()
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 15))
        XCTAssertNotEqual(app.staticTexts["editor.duration"].label, originalDuration)
        let overlapDuration = app.staticTexts["editor.duration"].label
        let transitionChip = app.buttons.matching(NSPredicate(format: "identifier IN %@", ["editor.transition", "effect.transition"])).firstMatch
        XCTAssertTrue(transitionChip.waitForExistence(timeout: 10)); transitionChip.tap()
        XCTAssertTrue(app.buttons["transition.remove"].waitForExistence(timeout: 10), "The transition chip reopens its settings")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 15))
        app.buttons["Next change"].tap()
        openTool("text", in: app)
        let textInput = app.textFields["tool.text.input"].exists ? app.textFields["tool.text.input"] : app.textViews["tool.text.input"]
        textInput.tap(); textInput.typeText("Over the join")
        if app.buttons["Done"].exists { app.buttons["Done"].tap() }
        waitForTool(app)
        app.buttons["tool.cancel"].tap()
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 15))
        app.buttons["Previous change"].tap()
        app.buttons["Undo"].tap(); XCTAssertEqual(app.staticTexts["editor.duration"].label, originalDuration)
        app.buttons["Redo"].tap(); XCTAssertEqual(app.staticTexts["editor.duration"].label, overlapDuration)
        let reopen = app.buttons.matching(NSPredicate(format: "identifier IN %@", ["editor.transition", "effect.transition"])).firstMatch
        XCTAssertTrue(reopen.waitForExistence(timeout: 15)); reopen.tap()
        XCTAssertTrue(app.buttons["transition.remove"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["transition.remove"].label,"Remove transition")
        XCTAssertFalse(app.buttons["Restore straight cut"].exists,"There is a single removal action")
        for _ in 0..<8 { if app.buttons["transition.remove"].isHittable { break }; app.scrollViews["transition.controls"].swipeUp() }
        XCTAssertTrue(app.buttons["transition.remove"].isHittable)
        let removalShot=XCTAttachment(screenshot:XCUIScreen.main.screenshot());removalShot.name="Single transition removal action";removalShot.lifetime = .keepAlways;add(removalShot)
        app.buttons["transition.remove"].tap()
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["editor.duration"].label, originalDuration, "Remove transition restores a straight cut")
        app.buttons["Undo"].tap()
        XCTAssertEqual(app.staticTexts["editor.duration"].label, overlapDuration)
        XCTAssertTrue(reopen.waitForExistence(timeout: 15))
        app.buttons["Redo"].tap()
        XCTAssertEqual(app.staticTexts["editor.duration"].label, originalDuration,"Redo restores the straight cut again")
    }

    func testTransitionBesideOneFrameClip() throws {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--one-frame-fixture"]; app.launch()
        XCTAssertTrue(app.buttons["Next change"].waitForExistence(timeout: 25))
        app.buttons["Next change"].tap()
        openTimelineTransition(in: app)
        let slider = app.sliders["transition.duration"]
        XCTAssertTrue(slider.waitForExistence(timeout: 15))
        XCTAssertFalse(slider.isEnabled, "A one-frame clip has no adjustable blend duration")
        let controls = app.scrollViews["transition.controls"], timing = app.buttons["transition.timing"]
        revealInViewport(timing, scroll: controls); timing.tap()
        XCTAssertFalse(app.buttons["transition.duration.0.5"].isEnabled)
        timing.tap()
        selectTransitionStyle("still", in: app)
        chooseTransitionDuration("60", in: app)
        XCTAssertEqual(timing.value as? String, "60 s", "A freeze can extend beyond its source clip")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 10))
    }

    func testTransitionOpeningCancelAndApply() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]; app.launch()
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 25))
        let duration = app.staticTexts["editor.duration"].label
        openTimelineTransition(in: app)
        let apply = app.buttons["transition.apply"]
        expectation(for: NSPredicate(format: "exists == true AND enabled == true"), evaluatedWith: apply); waitForExpectations(timeout: 40)
        selectTransitionStyle("fadeBlack", in: app)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 10)); XCTAssertFalse(app.buttons["Undo"].isEnabled)
        openTimelineTransition(in: app)
        expectation(for: NSPredicate(format: "exists == true AND enabled == true"), evaluatedWith: apply); waitForExpectations(timeout: 40)
        func displayedDuration() -> Double {
            let text = (app.buttons["transition.timing"].value as? String ?? "").replacingOccurrences(of: ",", with: ".")
            return Double(text.components(separatedBy: " ").first ?? "") ?? -1
        }
        for seconds in [0.5, 4, 7, 15] {
            let id = seconds == seconds.rounded() ? String(Int(seconds)) : String(seconds)
            chooseTransitionDuration(id, in: app)
            XCTAssertEqual(displayedDuration(), seconds)
        }
        let controls = app.scrollViews["transition.controls"]
        revealInViewport(app.buttons["transition.timing"], scroll: controls)
        app.buttons["transition.timing"].tap()
        let minute = app.buttons["transition.duration.60"]
        revealInViewport(minute, scroll: controls)
        XCTAssertFalse(minute.isEnabled)
        let quickPicks = XCTAttachment(screenshot: app.screenshot())
        quickPicks.name = "Transition duration choices at a clip boundary"
        quickPicks.lifetime = .keepAlways; add(quickPicks)
        revealInViewport(app.buttons["transition.timing"], scroll: controls)
        app.buttons["transition.timing"].tap()
        revealInViewport(app.sliders["transition.duration"], scroll: controls)
        app.sliders["transition.duration"].adjust(toNormalizedSliderPosition: 0.85)
        XCTAssertGreaterThan(displayedDuration(), 10, "Long footage permits durations beyond the old ten-second cap")
        expectation(for: NSPredicate(format: "exists == true AND enabled == true"), evaluatedWith: apply); waitForExpectations(timeout: 40)
        apply.tap()
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 15)); XCTAssertEqual(app.staticTexts["editor.duration"].label, duration)
        app.buttons["Undo"].tap(); XCTAssertEqual(app.staticTexts["editor.duration"].label, duration)
    }

    func testTransitionLargeText() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityM"]; app.launch()
        openTimelineTransition(in: app)
        let apply = app.buttons["transition.apply"]
        expectation(for: NSPredicate(format: "exists == true AND enabled == true"), evaluatedWith: apply); waitForExpectations(timeout: 40)
        XCTAssertTrue(app.buttons["Cancel"].isHittable); XCTAssertTrue(apply.isHittable)
        for _ in 0..<5 { if app.sliders["transition.duration"].isHittable { break }; app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(app.sliders["transition.duration"].isHittable)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Transition large text"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["Cancel"].tap()
    }

    func testSettingsLongPressExplainsWithoutToggling() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]; app.launch()
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 25)); app.buttons["Tools"].tap()
        defer { XCUIDevice.shared.orientation = .portrait }
        let items = [("tools.settings.snap", "Snap to cuts", "clip boundaries"), ("tools.settings.matchLevels", "Match listening levels", "preview volume only")]
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            for (id, title, phrase) in items {
                let card = app.descendants(matching: .any)[id]
                for _ in 0..<5 { if card.exists && card.isHittable { break }; app.scrollViews.firstMatch.swipeUp() }
                let initial = card.value as! String
                card.press(forDuration: 0.8)
                let explanation = app.alerts[title]
                XCTAssertTrue(explanation.waitForExistence(timeout: 5))
                XCTAssertTrue(explanation.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", phrase)).firstMatch.exists)
                if id == "tools.settings.matchLevels" {
                    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Setting explanation \(orientation.rawValue)"; shot.lifetime = .keepAlways; add(shot)
                }
                explanation.buttons["Got it"].tap()
                XCTAssertEqual(card.value as? String, initial, "Holding to read must never change the preference")
                card.tap(); XCTAssertEqual(card.value as? String, initial == "On" ? "Off" : "On", "A regular tap still toggles")
                card.tap(); XCTAssertEqual(card.value as? String, initial)
            }
            if orientation == .portrait {
                let card = app.descendants(matching: .any)["tools.settings.matchLevels"]
                let initial = card.value as? String
                let start = card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -90)))
                XCTAssertFalse(app.alerts.firstMatch.exists, "Scrolling from a card must not open help")
                XCTAssertEqual(card.value as? String, initial, "Scrolling must not toggle the preference")
            }
        }
        app.buttons["Done"].tap()
    }

    func testTimelineClipBoundariesAndNumberBadges() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]; app.launch()
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 25))
        // Give every piece an effect to check the compact number/FX layout.
        openTool("mirror", in: app); app.switches["tool.mirror.horizontal"].tap(); waitForTool(app); app.buttons["tool.apply"].tap()
        XCTAssertTrue(app.buttons["Split"].waitForExistence(timeout: 10))
        for index in 1...3 {
            seekTimeline(fraction: Double(index) / 10, in: app)
            app.buttons["Split"].tap()
        }
        app.buttons["Timeline zoom"].tap(); app.buttons["1 second"].tap()
        let timeline = app.otherElements["editor.timeline"]
        XCTAssertTrue(timeline.isHittable)
        func shot(_ title: String) { let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = title; a.lifetime = .keepAlways; add(a) }
        shot("Rounded clip boundaries portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        expectation(for: NSPredicate { _, _ in app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height }, evaluatedWith: app); waitForExpectations(timeout: 8)
        shot("Clip numbers with FX in landscape")
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.34)).tap()
        XCTAssertTrue(app.buttons["Delete clip"].waitForExistence(timeout: 5), "Rounded appearance preserves clip selection")
        shot("Rounded selected clip")
        app.buttons["Timeline zoom"].tap(); app.buttons["Whole project"].tap()
        shot("Narrow clips at whole project zoom")
    }

    func testEditorSettingsCardsAndRecordingScope() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]; app.launch()
        let snap = app.descendants(matching: .any)["tools.settings.snap"], levels = app.descendants(matching: .any)["tools.settings.matchLevels"]
        func showSettings() {
            XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 25)); app.buttons["Tools"].tap()
            XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
            for _ in 0..<5 { if levels.exists && levels.isHittable { break }; app.scrollViews.firstMatch.swipeUp() }
            XCTAssertTrue(snap.isHittable); XCTAssertTrue(levels.isHittable)
        }
        func shot(_ name: String) { let item = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); item.name = name; item.lifetime = .keepAlways; add(item) }
        showSettings()
        let snapInitial = snap.value as! String, levelsInitial = levels.value as! String
        snap.tap(); XCTAssertEqual(snap.value as? String, snapInitial == "On" ? "Off" : "On")
        levels.tap(); XCTAssertEqual(levels.value as? String, levelsInitial == "On" ? "Off" : "On")
        XCTAssertTrue(snap.isHittable, "Toggles keep the Tools panel open")
        XCTAssertFalse(app.switches["recorder.hdr"].exists)
        shot("Tools settings portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        expectation(for: NSPredicate { _, _ in app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height }, evaluatedWith: app); waitForExpectations(timeout: 8)
        for _ in 0..<5 { if levels.isHittable { break }; app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(snap.isHittable); XCTAssertTrue(levels.isHittable)
        shot("Tools settings landscape")
        app.buttons["Done"].tap()
        XCTAssertFalse(app.buttons["Undo"].isEnabled, "Editor preferences are not project edits")
        app.buttons["Audio filters"].tap()
        let audioLevels = app.switches["audio.matchLevels"]
        XCTAssertTrue(audioLevels.waitForExistence(timeout: 5))
        for _ in 0..<5 { if audioLevels.isHittable { break }; app.scrollViews.firstMatch.swipeUp() }
        XCTAssertEqual(audioLevels.value as? String, levelsInitial == "On" ? "0" : "1")
        audioLevels.tap(); app.buttons["Done"].tap()
        showSettings(); XCTAssertEqual(levels.value as? String, levelsInitial)
        app.terminate(); app.launch()
        showSettings(); XCTAssertEqual(snap.value as? String, snapInitial == "On" ? "Off" : "On")
        XCTAssertEqual(levels.value as? String, levelsInitial)
        snap.tap(); XCTAssertEqual(snap.value as? String, snapInitial)
        XCUIDevice.shared.orientation = .portrait
        app.terminate(); app.launchArguments = ["--recorder-controls-test"]; app.launch()
        XCTAssertTrue(app.buttons["recorder.settings"].waitForExistence(timeout: 15)); openMoreCameraSettings(in: app)
        XCTAssertTrue(app.switches["recorder.mirrorPreview"].waitForExistence(timeout: 5))
        for _ in 0..<5 { if app.buttons["recorder.transition"].exists { break }; app.swipeUp() }
        XCTAssertTrue(app.buttons["recorder.transition"].exists)
        XCTAssertFalse(app.switches["Snap to cuts"].exists)
        XCTAssertFalse(app.buttons["tools.settings.snap"].exists)
        XCTAssertFalse(app.staticTexts["Editing"].exists)
        app.buttons["recorder.settingsDone"].tap()
    }

    func testEditorSettingsLargeText() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityM"]; app.launch()
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 25)); app.buttons["Tools"].tap()
        let snap = app.descendants(matching: .any)["tools.settings.snap"], levels = app.descendants(matching: .any)["tools.settings.matchLevels"]
        let bottom = app.windows.firstMatch.frame.maxY - 30
        for _ in 0..<8 { if levels.exists && levels.isHittable && levels.frame.maxY <= bottom { break }; app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(snap.isHittable); XCTAssertTrue(levels.isHittable)
        XCTAssertLessThanOrEqual(levels.frame.maxY, bottom, "The full card and label must be visible")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Tools settings large text"; shot.lifetime = .keepAlways; add(shot)
        let initial = levels.value as? String
        levels.press(forDuration: 0.8)
        let help = app.alerts["Match listening levels"]
        XCTAssertTrue(help.waitForExistence(timeout: 5)); XCTAssertTrue(help.buttons["Got it"].isHittable)
        let helpShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); helpShot.name = "Setting explanation large text"; helpShot.lifetime = .keepAlways; add(helpShot)
        help.buttons["Got it"].tap(); XCTAssertEqual(levels.value as? String, initial)
        app.buttons["Done"].tap()
    }

    // Requires an 18-second speech/quiet fixture; scripts/make-pauses-fixture.sh creates a public synthetic equivalent.
    func testPausesReview() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]; app.launch()
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 25))
        defer { XCUIDevice.shared.orientation = .portrait }
        let originalDuration = app.staticTexts["editor.duration"].label
        openTool("pauses", in: app); waitForTool(app)
        func shot(_ name: String) { let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a) }
        XCTAssertTrue(app.buttons["tool.pauses.listen"].isHittable, "Review must be accessible without scrolling")
        XCTAssertTrue(app.buttons["Next pause"].isHittable)
        shot("Pauses review portrait")
        let initial = app.staticTexts["tool.position"].label
        app.buttons["Next pause"].tap()
        XCTAssertNotEqual(app.staticTexts["tool.position"].label, initial, "Next pause must seek the preview")
        app.buttons["tool.before"].tap(); waitForTool(app)
        let anchor = app.staticTexts["tool.position"].label
        app.buttons["tool.pauses.listen"].tap()
        expectation(for: NSPredicate(format: "label == %@", "Listen to pause"), evaluatedWith: app.buttons["tool.pauses.listen"])
        waitForExpectations(timeout: 10)
        XCTAssertEqual(app.staticTexts["tool.position"].label, anchor)
        app.buttons["tool.after"].tap(); waitForTool(app)
        let summary = app.staticTexts["tool.pauses.summary"].label
        app.segmentedControls["tool.pauses.cut"].buttons["Keep"].tap(); waitForTool(app)
        XCTAssertNotEqual(app.staticTexts["tool.pauses.summary"].label, summary)
        XCUIDevice.shared.orientation = .landscapeLeft
        expectation(for: NSPredicate { _, _ in app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height }, evaluatedWith: app)
        waitForExpectations(timeout: 8)
        XCTAssertTrue(app.buttons["tool.pauses.listen"].isHittable)
        XCTAssertTrue(app.buttons["Next pause"].isHittable)
        shot("Pauses review landscape")
        XCUIDevice.shared.orientation = .portrait
        app.buttons["tool.apply"].tap()
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 10))
        let editedDuration = app.staticTexts["editor.duration"].label
        XCTAssertNotEqual(editedDuration, originalDuration)
        app.buttons["Undo"].tap(); XCTAssertEqual(app.staticTexts["editor.duration"].label, originalDuration)
        app.buttons["Redo"].tap(); XCTAssertEqual(app.staticTexts["editor.duration"].label, editedDuration)
        app.terminate(); app.launchArguments = ["--editor-preview"]; app.launch()
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 25)); app.buttons["Tools"].tap()
        XCTAssertTrue(app.buttons["tools.existing.pauses"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["tools.existing.pauses"].firstMatch.tap(); waitForTool(app)
        app.buttons["Next pause"].tap()
        XCTAssertEqual(app.segmentedControls["tool.pauses.cut"].buttons["Keep"].isSelected, true)
        for _ in 0..<4 { if app.buttons["tool.remove"].isHittable { break }; app.scrollViews.firstMatch.swipeUp() }
        app.buttons["tool.remove"].tap()
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["editor.duration"].label, originalDuration)
    }

    func testPausesDetectsCutsAndRestoresTheFullTimeline() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview"]
        app.launchEnvironment["YOUREC_EDITOR_FIXTURE_TITLE"] = "Pauses · room tone QA"
        app.launch()
        let duration = app.staticTexts["editor.duration"], play = app.buttons["Play"]
        XCTAssertTrue(play.waitForExistence(timeout: 60))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 90)
        let original = duration.label
        openTool("pauses", in: app)
        let summary = app.staticTexts["tool.pauses.summary"], apply = app.buttons["tool.apply"]
        XCTAssertTrue(summary.waitForExistence(timeout: 120))
        let detected = summary.label
        XCTAssertFalse(detected.hasPrefix("0 cuts"), detected)
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: apply); waitForExpectations(timeout: 90)
        let report = XCTAttachment(string: original + " · " + detected); report.name = "Detected pauses"; report.lifetime = .keepAlways; add(report)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Pauses review"; shot.lifetime = .keepAlways; add(shot)
        let settings = app.buttons["tool.pauses.settings"], scroll = app.scrollViews["tool.settings"]
        revealInViewport(settings, scroll: scroll); settings.tap()
        let automatic = app.switches["Automatic silence level"]
        revealInViewport(automatic, scroll: scroll)
        XCTAssertEqual(automatic.value as? String, "1")
        automatic.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertTrue(app.sliders["Silence below"].waitForExistence(timeout: 10))
        automatic.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        expectation(for: NSPredicate(format: "label == %@", detected), evaluatedWith: summary); waitForExpectations(timeout: 90)
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: apply); waitForExpectations(timeout: 90)
        apply.tap()
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 20))
        let edited = duration.label
        XCTAssertNotEqual(edited, original)
        app.buttons["Undo"].tap(); XCTAssertEqual(duration.label, original)
        app.buttons["Redo"].tap(); XCTAssertEqual(duration.label, edited)
        app.terminate(); app.launch()
        XCTAssertTrue(duration.waitForExistence(timeout: 60)); XCTAssertEqual(duration.label, edited)
        app.buttons["Undo"].tap(); XCTAssertEqual(duration.label, original)
    }

    func testPausesSettingsUpdateAndKeepDecisions() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]; app.launch()
        openTool("pauses", in: app); waitForTool(app)
        app.segmentedControls["tool.pauses.cut"].buttons["Keep"].tap(); waitForTool(app)
        app.buttons["tool.pauses.settings"].tap()
        let minimum = app.sliders["Minimum pause"]
        for _ in 0..<4 { if minimum.isHittable { break }; app.scrollViews.firstMatch.swipeUp() }
        minimum.adjust(toNormalizedSliderPosition: 1)
        let noPauses = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "No pauses found.")).firstMatch
        XCTAssertTrue(noPauses.waitForExistence(timeout: 10), "Settings must re-detect automatically")
        XCTAssertFalse(app.buttons["tool.apply"].isEnabled, "An empty detection must not create an effect")
        minimum.adjust(toNormalizedSliderPosition: 0.17); waitForTool(app)
        for _ in 0..<4 { if app.segmentedControls["tool.pauses.cut"].isHittable { break }; app.scrollViews.firstMatch.swipeDown() }
        XCTAssertTrue(app.segmentedControls["tool.pauses.cut"].buttons["Keep"].isSelected, "A temporary threshold must not erase manual Keep decisions")
        app.buttons["tool.cancel"].tap()
    }

    // An opt-in test for an isolated copy of an existing real project whose
    // pause decisions were saved by the energy-only detector.
    func testRescanSavedSpeechPauses() throws {
        let environment = ProcessInfo.processInfo.environment
        let title = environment["YOUREC_PAUSE_SAVED_FIXTURE"] ?? ""
        try XCTSkipIf(title.isEmpty, "Needs a staged, previously analyzed dialogue project")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview"]
        app.launchEnvironment["YOUREC_EDITOR_FIXTURE_TITLE"] = title
        app.launch()
        let tools = app.buttons["Tools"], duration = app.staticTexts["editor.duration"]
        XCTAssertTrue(tools.waitForExistence(timeout: 60))
        let original = duration.label
        tools.tap()
        let existing = app.buttons["tools.existing.pauses"].firstMatch
        revealInViewport(existing, scroll: app.scrollViews["tools.content"])
        existing.tap()
        let summary = app.staticTexts["tool.pauses.summary"], scan = app.buttons["tool.pauses.find"]
        XCTAssertTrue(scan.waitForExistence(timeout: 60))
        let prior = summary.label
        scan.tap()
        expectation(for: NSPredicate { _, _ in summary.exists && summary.label != prior }, evaluatedWith: summary)
        waitForExpectations(timeout: 180)
        let apply = app.buttons["tool.apply"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: apply)
        waitForExpectations(timeout: 90)
        let report = XCTAttachment(string: prior + " → " + summary.label)
        report.name = "Saved and rescanned pause decisions"; report.lifetime = .keepAlways; add(report)
        apply.tap()
        XCTAssertTrue(tools.waitForExistence(timeout: 30))
        let updated = duration.label
        XCTAssertNotEqual(updated, original)
        func checkHistory(_ action: String, duration expected: String) {
            let button = app.buttons[action]
            expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: button)
            waitForExpectations(timeout: 60)
            button.tap()
            expectation(for: NSPredicate(format: "label == %@", expected), evaluatedWith: duration)
            waitForExpectations(timeout: 30)
        }
        checkHistory("Undo", duration: original)
        checkHistory("Redo", duration: updated)
        app.terminate(); app.launch()
        XCTAssertTrue(duration.waitForExistence(timeout: 60)); XCTAssertEqual(duration.label, updated)
    }

    func testPausesLargeText() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityM"]; app.launch()
        openTool("pauses", in: app); waitForTool(app)
        defer { XCUIDevice.shared.orientation = .portrait }
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            Thread.sleep(forTimeInterval: 0.5)
            XCTAssertTrue(app.buttons["tool.cancel"].isHittable)
            XCTAssertTrue(app.buttons["tool.apply"].isHittable)
            for _ in 0..<4 { if app.buttons["tool.pauses.listen"].isHittable { break }; app.scrollViews.firstMatch.swipeUp() }
            XCTAssertTrue(app.buttons["tool.pauses.listen"].isHittable)
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Pauses large text \(orientation.rawValue)"; shot.lifetime = .keepAlways; add(shot)
        }
        app.buttons["tool.cancel"].tap()
    }

    func testCutPasteAndMirrorWorkspace() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]; app.launch()
        XCTAssertTrue(app.buttons["Mark start"].waitForExistence(timeout: 25))
        let originalDuration = app.staticTexts["editor.duration"].label
        app.buttons["Mark start"].tap()
        seekTimeline(fraction: 0.25, in: app)
        app.buttons["Mark end"].tap()
        XCTAssertTrue(app.buttons["editor.cut"].isHittable)
        XCTAssertTrue(app.buttons["Delete selection"].isHittable)
        XCTAssertTrue(app.buttons["editor.clearSelection"].isHittable)
        Thread.sleep(forTimeInterval: 0.4) // Capture the settled label, not its transition.
        let selection = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); selection.name = "Cut auxiliary bar portrait"; selection.lifetime = .keepAlways; add(selection)
        app.buttons["editor.cut"].tap()
        XCTAssertNotEqual(app.staticTexts["editor.duration"].label, originalDuration)
        XCTAssertTrue(app.buttons["editor.paste"].waitForExistence(timeout: 5)); app.buttons["editor.paste"].tap()
        XCTAssertEqual(app.staticTexts["editor.duration"].label, originalDuration)
        XCTAssertTrue(app.buttons["editor.clearSelection"].isHittable)
        app.buttons["editor.clearSelection"].tap()
        openTool("mirror", in: app); waitForTool(app)
        app.switches["tool.mirror.horizontal"].tap(); waitForTool(app)
        app.buttons["tool.apply"].tap()
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 8))
        app.buttons["Tools"].tap()
        XCTAssertTrue(app.buttons["tools.mirror"].waitForExistence(timeout: 5))
        let tools = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); tools.name = "Tools grouped portrait"; tools.lifetime = .keepAlways; add(tools)
        app.buttons["Done"].tap()
        app.buttons["Undo"].tap()
        app.buttons["Redo"].tap()
        app.buttons["Timeline view span"].tap()
        XCTAssertTrue(app.buttons["1 second"].exists)
        XCTAssertFalse(app.buttons["Snap to cuts"].exists || app.switches["Snap to cuts"].exists)
    }

    func testImageOverlayFromPhotosAndReedit() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]; app.launch()
        openTool("image", in: app)
        app.buttons["tool.image.choose"].tap()
        let cell = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 10), app.debugDescription)
        cell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        waitForTool(app)
        let overlay = app.images["tool.image.overlay"].exists ? app.images["tool.image.overlay"] : app.otherElements["tool.image.overlay"]
        XCTAssertTrue(overlay.waitForExistence(timeout: 10), app.debugDescription)
        app.sliders["Image size"].adjust(toNormalizedSliderPosition: 0.15)
        let timing = app.buttons["overlay.timing"], settings = app.scrollViews["tool.settings"]
        revealInViewport(timing, scroll: settings); timing.tap()
        let eight = app.buttons["overlay.duration.8"]
        revealInViewport(eight, scroll: settings); eight.tap()
        XCTAssertTrue(eight.isSelected)
        waitForTool(app)
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); image.name = "Image workspace portrait"; image.lifetime = .keepAlways; add(image)
        app.buttons["tool.apply"].tap()
        XCTAssertTrue(app.buttons["effect.image"].waitForExistence(timeout: 10)); app.buttons["effect.image"].tap(); waitForTool(app)
        XCTAssertEqual(timing.value as? String, "8 s")
        XCTAssertTrue(app.buttons["Replace image"].exists || app.buttons["tool.image.choose"].exists)
        app.sliders["Image opacity"].adjust(toNormalizedSliderPosition: 0.6)
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 1) // Wait for UIKit's rotation/layout animation.
        let landscape = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); landscape.name = "Image workspace landscape"; landscape.lifetime = .keepAlways; add(landscape)
        app.buttons["tool.apply"].tap()
        XCUIDevice.shared.orientation = .portrait
        app.buttons["Undo"].tap(); app.buttons["Redo"].tap()
    }

    private func confirmPhotoVideos(in app: XCUIApplication) {
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Add' OR label BEGINSWITH 'Add (' OR label == 'Choose' OR label == 'Done'")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription)
        confirm.tap()
    }

    func testAddVideoFromPhotosAtPlayheadAndUndo() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]; app.launch()
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 25))
        let original = app.staticTexts["editor.duration"].label
        app.buttons["Tools"].tap(); app.buttons["tools.addVideo"].tap()
        XCTAssertTrue(app.buttons["From Photos"].waitForExistence(timeout: 5))
        let portrait = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); portrait.name = "Add video portrait"; portrait.lifetime = .keepAlways; add(portrait)
        XCUIDevice.shared.orientation = .landscapeRight
        expectation(for: NSPredicate { _, _ in app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height }, evaluatedWith: app)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(app.buttons["From Photos"].isHittable)
        XCTAssertTrue(app.buttons["editor.recordHere"].isHittable)
        let landscape = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); landscape.name = "Add video landscape"; landscape.lifetime = .keepAlways; add(landscape)
        XCUIDevice.shared.orientation = .portrait
        app.buttons["From Photos"].tap()
        let cell = app.images.matching(identifier: "PXGGridLayout-Info")
            .matching(NSPredicate(format: "label BEGINSWITH[c] 'Video,'")).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 10), app.debugDescription); cell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        confirmPhotoVideos(in: app)
        expectation(for: NSPredicate(format: "label != %@", original), evaluatedWith: app.staticTexts["editor.duration"])
        waitForExpectations(timeout: 30)
        XCTAssertNotEqual(app.staticTexts["editor.duration"].label, original)
        app.buttons["Undo"].tap(); XCTAssertEqual(app.staticTexts["editor.duration"].label, original)
        app.buttons["Redo"].tap(); XCTAssertNotEqual(app.staticTexts["editor.duration"].label, original)
    }

    func testAddVideoCanBeCancelledAtPlayhead() throws {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]
        app.launchEnvironment["YOUREC_EDITOR_FIXTURE_TITLE"] = "Batch cancel QA"
        app.launch()
        let tools = app.buttons["Tools"], duration = app.staticTexts["editor.duration"]
        XCTAssertTrue(tools.waitForExistence(timeout: 30)); let before = duration.label
        tools.tap(); app.buttons["tools.addVideo"].tap(); app.buttons["From Photos"].tap()
        let close = app.buttons["Cancel"]
        XCTAssertTrue(close.waitForExistence(timeout: 12)); close.tap()
        XCTAssertTrue(app.buttons["From Photos"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["editor.recordHere"].isHittable)
        app.navigationBars.buttons.element(boundBy: 0).tap(); app.buttons["Done"].tap()
        XCTAssertTrue(tools.waitForExistence(timeout: 10)); XCTAssertEqual(duration.label, before)
        XCTAssertFalse(app.buttons["Undo"].isEnabled)
    }

    func testTimelineAddButtonClearsClosingTransition() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 25))
        seekTimeline(fraction: 1, in: app)
        openTimelineTransition(in: app)
        selectTransitionStyle("fadeBlack", in: app)
        let apply = app.buttons["transition.apply"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: apply)
        waitForExpectations(timeout: 30)
        apply.tap()
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 20))
        let plus = app.buttons["timeline.add.end"]
        let badge = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'timeline.transition.'")).firstMatch
        for span in ["1 second", "Whole project"] {
            app.buttons["Timeline view span"].tap(); app.buttons[span].tap()
            XCTAssertTrue(plus.isHittable && badge.isHittable)
            XCTAssertFalse(plus.frame.intersects(badge.frame), "Add and the fade need independent tap targets in \(span)")
            XCTAssertEqual(plus.frame.width, 44, accuracy: 1)
            if span == "1 second" {
                XCTAssertGreaterThanOrEqual(plus.frame.midX - badge.frame.midX, 47)
            }
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "Closing transition and add at \(span)"; shot.lifetime = .keepAlways; add(shot)
            plus.tap()
            XCTAssertTrue(app.staticTexts["Add video or photo at end"].waitForExistence(timeout: 5))
            app.buttons["Cancel"].tap()
            badge.tap()
            XCTAssertFalse(app.staticTexts["Add video or photo at end"].exists)
        }
    }

    #if targetEnvironment(simulator)
    // Seed Photos with a screenshot and a one-second movie before this test.
    func testScreenshotAndMovieAtTimelineStart() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]
        app.launchEnvironment["YOUREC_EDITOR_FIXTURE_TITLE"] = "Mixed Photos insertion"
        app.launch()
        let start = app.buttons["timeline.add.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 25))
        start.tap()
        app.buttons["From Photos"].tap()
        let cells = app.images.matching(identifier: "PXGGridLayout-Info")
        let photo = cells.matching(NSPredicate(format: "label CONTAINS[c] 'photo' OR label CONTAINS[c] 'screenshot'")).firstMatch
        let movie = cells.matching(NSPredicate(format: "label BEGINSWITH[c] 'Video, one second'")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(movie.exists, app.debugDescription)
        for item in [photo, movie] {
            item.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        confirmPhotoVideos(in: app)
        let first = app.buttons["timeline.video.1"], duration = app.staticTexts["editor.duration"]
        let imported = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == '0:22.00'"), object: duration)
        XCTAssertEqual(XCTWaiter.wait(for: [imported], timeout: 45), .completed, app.debugDescription)
        XCTAssertEqual(first.value as? String, "0.000 to 3.000 seconds")
        XCTAssertEqual(duration.label, "0:22.00")
        app.buttons["Undo"].tap()
        XCTAssertEqual(duration.label, "0:18.00")
        app.buttons["Redo"].tap()
        XCTAssertEqual(first.value as? String, "0.000 to 3.000 seconds")
        XCTAssertEqual(duration.label, "0:22.00")
        app.buttons["Export"].tap()
        let export = app.buttons["Export video"]
        XCTAssertTrue(export.waitForExistence(timeout: 10))
        export.tap()
        XCTAssertTrue(app.buttons["Share latest export"].waitForExistence(timeout: 120), app.debugDescription)
    }

    // Seed Photos with a one-second video before running this interaction test.
    func testTimelineAddVideoShortcuts() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--multiselect-fixture", "--move-snap-fixture"]
        app.launch()
        let span = app.buttons["Timeline view span"]
        XCTAssertTrue(span.waitForExistence(timeout: 25))
        seekTimeline(fraction: 0.65, in: app)
        let ends = XCTAttachment(screenshot: app.screenshot())
        ends.name = "Timeline add buttons at whole-project fit"; ends.lifetime = .keepAlways; add(ends)
        let playhead = app.staticTexts["editor.playhead"].label
        for (id, title) in [("start", "Add video or photo at start"), ("end", "Add video or photo at end")] {
            let button = app.buttons["timeline.add." + id]
            XCTAssertTrue(button.isHittable); button.tap()
            XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["From Photos"].isHittable)
            XCTAssertTrue(app.buttons["editor.recordHere"].isHittable)
            app.buttons["Cancel"].tap()
            XCTAssertEqual(app.staticTexts["editor.playhead"].label, playhead)
        }
        let gap = app.buttons["timeline.add.gap.2880000"] // 12 s on the exact edit clock.
        XCTAssertFalse(gap.exists, "The two-second gap is too narrow at whole-project fit")
        span.tap(); app.buttons["10 seconds"].tap()
        XCTAssertTrue(gap.waitForExistence(timeout: 5))
        let inside = XCTAttachment(screenshot: app.screenshot())
        inside.name = "Add inside a picture gap"; inside.lifetime = .keepAlways; add(inside)
        gap.tap()
        XCTAssertTrue(app.staticTexts["Add video or photo in gap"].waitForExistence(timeout: 5))
        app.buttons["From Photos"].tap()
        let first = app.images.matching(identifier: "PXGGridLayout-Info")
            .matching(NSPredicate(format: "label BEGINSWITH[c] 'Video, one second'")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 8))
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        confirmPhotoVideos(in: app)
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 25))
        XCTAssertEqual(app.buttons["timeline.video.3"].value as? String, "12.000 to 13.000 seconds")
        XCTAssertEqual(app.buttons["timeline.video.4"].value as? String, "14.000 to 20.000 seconds")
        app.buttons["Undo"].tap()
        XCTAssertTrue(gap.waitForExistence(timeout: 8))
    }

    // This test selects and exports all three seeded Photos fixtures.
    func testBatchVideosFromPhotosAndUnusedTakes() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]
        app.launchEnvironment["YOUREC_EDITOR_FIXTURE_TITLE"] = "Ordered video insertion QA " + UUID().uuidString.prefix(8)
        app.launch()
        let tools = app.buttons["Tools"], duration = app.staticTexts["editor.duration"]
        XCTAssertTrue(tools.waitForExistence(timeout: 25))
        let original = duration.label
        let timeline = app.otherElements["editor.timeline"]
        app.buttons["Timeline view span"].tap(); app.buttons["Whole project"].tap()
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.04)).tap()
        func openAdd() { tools.tap(); app.buttons["tools.addVideo"].tap() }
        func changed() {
            expectation(for: NSPredicate(format: "label != %@", original), evaluatedWith: duration)
            waitForExpectations(timeout: 60)
        }
        openAdd(); app.buttons["From Photos"].tap()
        let cells = app.images.matching(identifier: "PXGGridLayout-Info")
            .matching(NSPredicate(format: "label BEGINSWITH[c] 'Video,'"))
        let third = cells.element(boundBy: 2).waitForExistence(timeout: 12)
        let grid = XCTAttachment(screenshot: app.screenshot()); grid.name = "Photos grid"; grid.lifetime = .keepAlways; add(grid)
        XCTAssertTrue(third, "Seed three videos in Photos before running this test. " + app.debugDescription)
        for index in [2,0,1] {
            let cell = cells.element(boundBy: index)
            cell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        let order = XCTAttachment(screenshot: app.screenshot()); order.name = "Ordered Photos selection"; order.lifetime = .keepAlways; add(order)
        confirmPhotoVideos(in: app); changed()
        let added = duration.label
        app.buttons["Export"].tap()
        XCTAssertTrue(app.buttons["Export video"].waitForExistence(timeout: 10))
        app.buttons["Export video"].tap()
        XCTAssertTrue(app.buttons["Share latest export"].waitForExistence(timeout: 120))
        app.buttons["Done"].tap()
        app.buttons["Undo"].tap(); XCTAssertEqual(duration.label, original)
        app.buttons["Redo"].tap(); XCTAssertEqual(duration.label, added)
        app.buttons["Undo"].tap(); XCTAssertEqual(duration.label, original)

        openAdd(); app.buttons["addVideo.unused"].tap()
        let available = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'addVideo.take.'"))
        XCTAssertTrue(available.element(boundBy: 2).waitForExistence(timeout: 10))
        let takeIDs = available.allElementsBoundByIndex.map(\.identifier)
        app.buttons[takeIDs[2]].tap(); app.buttons[takeIDs[0]].tap()
        let first = app.descendants(matching: .any)["addVideo.ordered.1"].firstMatch
        let second = app.descendants(matching: .any)["addVideo.ordered.2"].firstMatch
        XCTAssertTrue(first.exists && second.exists)
        let firstLabel = first.label, secondLabel = second.label
        let handles = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'Reorder'"))
        XCTAssertTrue(handles.element(boundBy: 1).waitForExistence(timeout: 5), app.debugDescription)
        let lower = handles.element(boundBy: 1).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let upper = handles.element(boundBy: 0).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        lower.press(forDuration: 0.45, thenDragTo: upper)
        XCTAssertNotEqual(first.label, firstLabel); XCTAssertNotEqual(second.label, secondLabel)
        let insert = app.buttons["addVideo.insertTakes"]
        XCTAssertEqual(insert.label, "Insert 2")
        let queue = XCTAttachment(screenshot: app.screenshot()); queue.name = "Unused takes playback order"; queue.lifetime = .keepAlways; add(queue)
        insert.tap(); changed()
        app.buttons["Undo"].tap(); XCTAssertEqual(duration.label, original)
        app.buttons["Redo"].tap(); changed()
    }
    #endif

    func testMissingImageCanBeRemoved() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--missing-image-fixture"]; app.launch()
        XCTAssertTrue(app.alerts["Editor"].waitForExistence(timeout: 25)); app.alerts["Editor"].buttons["OK"].tap()
        app.buttons["Tools"].tap()
        let entry = app.buttons["tools.existing.image"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        for _ in 0..<5 { if entry.isHittable { break }; app.swipeUp() }
        entry.tap()
        let remove = app.buttons["tool.remove"]
        XCTAssertTrue(remove.waitForExistence(timeout: 10))
        for _ in 0..<5 { if remove.isHittable { break }; app.swipeUp() }
        remove.tap()
        let preview = app.otherElements["editor.preview"]
        expectation(for: NSPredicate(format: "value BEGINSWITH 'Frame visible'"), evaluatedWith: preview)
        waitForExpectations(timeout: 15)
        XCTAssertFalse(app.alerts["Editor"].exists)
    }

    func testReviewSpeedAndScrubStaysPaused() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]; app.launch()
        let speed = app.buttons["editor.reviewSpeed"]
        XCTAssertTrue(speed.waitForExistence(timeout: 25))
        speed.tap(); app.buttons["editor.reviewSpeed.1.5"].tap()
        XCTAssertEqual((speed.value as? String)?.replacingOccurrences(of: ",", with: "."), "1.5×")
        app.buttons["Play"].tap()
        XCTAssertTrue(app.buttons["Pause playback"].waitForExistence(timeout: 5))
        let timeline = app.otherElements["editor.timeline"]
        timeline.swipeLeft(velocity: .slow)
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 5), "Scrubbing stays paused after release")
        let stopped = app.staticTexts["editor.playhead"].label
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(app.staticTexts["editor.playhead"].label, stopped)
        XCTAssertEqual((speed.value as? String)?.replacingOccurrences(of: ",", with: "."), "1.5×")
        timeline.swipeRight(velocity: .slow)
        XCTAssertTrue(app.buttons["Play"].exists, "Scrubbing a paused video stays paused")
        XCTAssertFalse(app.buttons["Undo"].isEnabled, "Review speed never changes the edit")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height && speed.frame.maxY < app.frame.height - 60 }, evaluatedWith: app)
        waitForExpectations(timeout: 10)
        speed.tap()
        XCTAssertTrue(app.buttons["editor.reviewSpeed.3.0"].isHittable)
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); image.name = "Review speed landscape"; image.lifetime = .keepAlways; add(image)
    }

    func testInspectionZoomAndDeferredPlay() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]; app.launch()
        let preview = app.otherElements["editor.preview"], reset = app.buttons["editor.preview.resetZoom"]
        XCTAssertTrue(preview.waitForExistence(timeout: 25))
        expectation(for: NSPredicate(format: "value BEGINSWITH 'Frame visible'"), evaluatedWith: preview); waitForExpectations(timeout: 15)
        XCTAssertFalse(reset.exists)
        preview.pinch(withScale: 2, velocity: 1)
        XCTAssertTrue(reset.waitForExistence(timeout: 5))
        XCTAssertFalse((preview.value as? String ?? "").contains("1.00× view"))
        preview.swipeLeft(); XCTAssertTrue(reset.isHittable)
        reset.tap(); XCTAssertFalse(reset.exists)
        XCTAssertTrue((preview.value as? String ?? "").contains("1.00× view"))
        preview.pinch(withScale: 0.5, velocity: -1)
        XCTAssertFalse(reset.exists)
        XCTAssertTrue((preview.value as? String ?? "").contains("1.00× view"))
        XCTAssertFalse(app.buttons["Undo"].isEnabled, "Inspection never edits the project")
        preview.pinch(withScale: 2, velocity: 1)
        app.buttons["Play"].tap(); XCTAssertTrue(app.buttons["Pause playback"].waitForExistence(timeout: 5))
        XCTAssertTrue(reset.isHittable); reset.tap()
    }
    func testDoubleTapPlayRestoresPlayhead() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]; app.launch()
        let play = app.buttons["Play"]
        XCTAssertTrue(play.waitForExistence(timeout: 25))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 30)
        seekTimeline(fraction: 0.25, in: app)
        let position = app.staticTexts["editor.playhead"].label
        play.doubleTap()
        XCTAssertTrue(app.buttons["Pause playback"].waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "label == %@", position), evaluatedWith: app.staticTexts["editor.playhead"])
        waitForExpectations(timeout: 8)
        XCTAssertTrue(app.buttons["Play"].exists)
        app.buttons["Mark start"].tap()
        seekTimeline(fraction: 0.5, in: app)
        app.buttons["Mark end"].tap()
        let cutPosition = app.staticTexts["editor.playhead"].label
        app.buttons["Preview cut"].tap()
        XCTAssertTrue(app.buttons["Pause playback"].waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "label == %@", cutPosition), evaluatedWith: app.staticTexts["editor.playhead"])
        waitForExpectations(timeout: 8)
        XCTAssertTrue(app.buttons["Play"].exists)
    }

    private func seekTimeline(fraction: Double, in app: XCUIApplication) {
        let timeline = app.otherElements["editor.timeline"]
        app.buttons["Timeline view span"].tap(); app.buttons["Whole project"].tap()
        timeline.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 48 + (timeline.frame.width-96)*fraction, dy: 10)).tap()
    }

    func testCutAndEffectNavigationGestures() throws {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--navigation-fixture"]; app.launch()
        let next = app.buttons["Next change"], previous = app.buttons["Previous change"], position = app.staticTexts["editor.playhead"]
        XCTAssertTrue(next.waitForExistence(timeout: 30))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: next); waitForExpectations(timeout: 30)
        func at(_ seconds: String) {
            expectation(for: NSPredicate(format: "label == %@", seconds), evaluatedWith: position); waitForExpectations(timeout: 5)
        }
        XCTAssertFalse(previous.isEnabled)
        next.tap(); at("0:06.00")
        previous.tap(); at("0:00.00")
        next.press(forDuration: 0.65); at("0:08.00")
        Thread.sleep(forTimeInterval: 0.5); at("0:08.00") // No trailing tap on release.
        next.tap(); at("0:10.00")
        next.tap(); at("0:12.00")
        previous.press(forDuration: 0.65); at("0:10.00")
        previous.press(forDuration: 0.65); at("0:08.00")
        app.buttons["Mark start"].tap()
        next.tap(); at("0:10.00")
        app.buttons["Mark end"].tap()
        XCTAssertTrue(app.buttons["editor.clearSelection"].isHittable, "Change jumps preserve range marking")
        app.buttons["editor.clearSelection"].tap()
        previous.press(forDuration: 0.65); previous.press(forDuration: 0.65); at("0:00.00")
        // A new plain split updates tap anchors; long press still skips it.
        seekTimeline(fraction: 0.2, in: app)
        let splitAt = position.label
        app.buttons["Split"].tap()
        XCTAssertTrue(app.buttons["Undo"].isEnabled)
        previous.press(forDuration: 0.65); at("0:00.00")
        next.tap(); at(splitAt)
        app.buttons["Undo"].tap()
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: next); waitForExpectations(timeout: 20)
        previous.press(forDuration: 0.65); at("0:00.00")
        next.tap(); at("0:06.00")
        XCUIDevice.shared.orientation = .landscapeLeft
        expectation(for: NSPredicate { _,_ in app.frame.width > app.frame.height }, evaluatedWith: app); waitForExpectations(timeout: 10)
        XCTAssertGreaterThanOrEqual(next.frame.width, 44)
        next.press(forDuration: 0.65); at("0:08.00")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Change navigation landscape"; shot.lifetime = .keepAlways; add(shot)
    }

    func testPreviewTapAndFullChangeNavigation() throws {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--navigation-fixture"]; app.launch()
        let preview = app.otherElements["editor.preview"]
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 30))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: app.buttons["Play"]); waitForExpectations(timeout: 30)
        preview.tap(); XCTAssertTrue(app.buttons["Pause playback"].waitForExistence(timeout: 5))
        preview.tap(); XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 5))
        preview.pinch(withScale: 2, velocity: 1)
        XCTAssertTrue(app.buttons["editor.preview.resetZoom"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Play"].exists, "Pinch must not toggle playback")
        preview.swipeLeft(); XCTAssertTrue(app.buttons["Play"].exists)
        app.buttons["editor.preview.resetZoom"].tap(); XCTAssertTrue(app.buttons["Play"].exists)
        app.buttons["Next change"].press(forDuration: 0.65)
        XCTAssertEqual(app.staticTexts["editor.playhead"].label, "0:08.00")
        preview.tap(); XCTAssertTrue(app.buttons["Pause playback"].waitForExistence(timeout: 5))
        app.buttons["Next change"].tap()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 5), "Jump pauses playback")
        let stopped = app.staticTexts["editor.playhead"].label
        Thread.sleep(forTimeInterval: 0.5); XCTAssertEqual(app.staticTexts["editor.playhead"].label, stopped)
        // Ruler tap while playing is also an explicit pause.
        preview.tap(); seekTimeline(fraction: 0.3, in: app)
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 5))
        app.buttons["Previous change"].press(forDuration: 0.65)
        app.buttons["editor.fullPreview"].tap()
        XCTAssertTrue(app.sliders["Full preview position"].waitForExistence(timeout: 5))
        app.buttons["fullPreview.nextChange"].press(forDuration: 0.65)
        XCTAssertEqual(app.staticTexts["fullPreview.playhead"].label, "0:08.00")
        app.buttons["fullPreview.previousChange"].tap(); XCTAssertEqual(app.staticTexts["fullPreview.playhead"].label, "0:06.00")
        app.buttons["fullPreview.previousChange"].press(forDuration: 0.65); XCTAssertEqual(app.staticTexts["fullPreview.playhead"].label, "0:00.00")
        app.otherElements["fullPreview.preview"].tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["Done"]); waitForExpectations(timeout: 6)
        app.otherElements["fullPreview.preview"].tap(); XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["fullPreview.playPause"].label, "Play", "Tap with hidden controls pauses and shows them")
        app.otherElements["fullPreview.preview"].tap()
        let slider = app.sliders["Full preview position"]
        slider.adjust(toNormalizedSliderPosition: 0.5)
        expectation(for: NSPredicate(format: "label == 'Play'"), evaluatedWith: app.buttons["fullPreview.playPause"]); waitForExpectations(timeout: 5)
        Thread.sleep(forTimeInterval: 0.5); XCTAssertEqual(app.buttons["fullPreview.playPause"].label, "Play")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Full preview change controls"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["Done"].tap()
    }

    private func openTimelinePlacement(in app: XCUIApplication) {
        let button = app.buttons["effect.placement"]
        XCTAssertTrue(button.waitForExistence(timeout: 8)); button.tap()
    }

    private func chooseTransitionDuration(_ seconds: String, in app: XCUIApplication) {
        let controls = app.scrollViews["transition.controls"]
        let timing = app.buttons["transition.timing"]
        let preset = app.buttons["transition.duration." + seconds]
        revealInViewport(timing, scroll: controls)
        if !preset.exists { timing.tap() }
        revealInViewport(preset, scroll: controls)
        preset.tap()
        XCTAssertTrue(preset.isSelected)
        revealInViewport(timing, scroll: controls)
        timing.tap()
    }

    private func openTimelineTransition(in app: XCUIApplication) {
        let button = app.buttons["editor.transition"]
        let scroll = app.scrollViews["editor.controlsScroll"]
        if scroll.exists { revealInViewport(button, scroll: scroll) }
        XCTAssertTrue(button.waitForExistence(timeout: 8)); button.tap()
    }

    private func openTool(_ name: String, in app: XCUIApplication) {
        let tools = app.buttons["Tools"]
        let editorScroll = app.scrollViews["editor.controlsScroll"]
        if editorScroll.exists { revealInViewport(tools, scroll: editorScroll) }
        XCTAssertTrue(tools.waitForExistence(timeout: 25)); tools.tap()
        let choice = app.buttons["tools." + name]
        XCTAssertTrue(app.scrollViews["tools.content"].waitForExistence(timeout: 5))
        let content = app.scrollViews["tools.content"]
        for _ in 0..<12 {
            let safeTop = app.navigationBars["Tools"].frame.maxY + 8, safeBottom = app.frame.maxY - 50
            if choice.exists && choice.isHittable && choice.frame.minY >= safeTop && choice.frame.maxY <= safeBottom { break }
            let downward = choice.exists && choice.frame.minY < safeTop
            let start = content.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: downward ? 0.4 : 0.7))
            let end = content.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: downward ? 0.7 : 0.4))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        XCTAssertTrue(choice.waitForExistence(timeout: 5)); choice.tap()
        if ["videoEffects", "enhanceAudio", "volume", "subtitles", "addAudio", "addVideo", "censorAudio"].contains(name) { return }
        XCTAssertTrue(app.buttons["tool.apply"].waitForExistence(timeout: 5))
    }
    private func waitForTool(_ app: XCUIApplication) {
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: app.buttons["tool.apply"])
        waitForExpectations(timeout: 90)
    }
    private func revealCrop(_ control: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 {if control.isHittable {break};app.scrollViews["crop.settings"].swipeUp()}
        XCTAssertTrue(control.isHittable)
    }
    private func animationFixture(_ arguments: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--reset-ui-fixture"] + arguments
        app.launchEnvironment["YOUREC_RECOVERY_TEST_RUN"] = UUID().uuidString
        app.launch()
        return app
    }
    private func endpointAction(_ title: String, in app: XCUIApplication) {
        let menu = app.buttons["effect.animation"]
        XCTAssertTrue(menu.waitForExistence(timeout:20))
        menu.tap()
        let choice = app.buttons[title].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout:5))
        choice.tap()
    }
    private func chooseEffectCurve(_ title: String, in app: XCUIApplication) {
        app.buttons["effect.curve"].tap()
        XCTAssertTrue(app.buttons[title].firstMatch.waitForExistence(timeout:5))
        app.buttons[title].firstMatch.tap()
    }
    private func previewRGB(_ view: XCUIElement) throws -> [UInt8] {
        let image = try XCTUnwrap(view.screenshot().image.cgImage)
        var bytes = [UInt8](repeating: 0, count: 64 * 64 * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 64, height: 64, bitsPerComponent: 8,
                bytesPerRow: 64 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        return bytes
    }
    func testCropRetimingRedrawsExistingPreviewAtSameFrame() throws {
        let app = animationFixture(["--frame-clock-fixture"])
        openTool("crop", in: app); waitForTool(app)
        endpointAction("B", in: app); waitForTool(app)
        app.otherElements["crop.canvas"].pinch(withScale: 2.5, velocity: 2)
        endpointAction("Done", in: app)
        app.buttons["crop.preview"].tap(); waitForTool(app)
        let scrubber = app.sliders["Crop preview position"]
        scrubber.adjust(toNormalizedSliderPosition: 0.46)
        let at = scrubber.value as? String
        let picture = app.otherElements["crop.result"]
        func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
            zip(a,b).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(a.count)
        }
        let linear = try previewRGB(picture)
        chooseEffectCurve("Ease in", in: app); waitForTool(app)
        XCTAssertEqual(scrubber.value as? String, at)
        XCTAssertGreaterThan(difference(linear, try previewRGB(picture)), 1)
        chooseEffectCurve("Linear", in: app); waitForTool(app)
        XCTAssertLessThan(difference(linear, try previewRGB(picture)), 0.5)
    }
    func testLUTRetimingUpdatesInspectedFrameAndBothRamps() throws {
        let app = animationFixture(["--frame-clock-fixture"])
        openTool("color", in: app); waitForTool(app)
        endpointAction("B", in: app); waitForTool(app)
        let inspector = app.scrollViews["tool.settings"]
        func reveal(_ control: XCUIElement) { revealInViewport(control, scroll: inspector, swipeX: 0.03) }
        let mono = app.buttons["tool.look.mono"]
        reveal(mono); mono.tap(); waitForTool(app)
        let picture = app.otherElements["tool.preview"], seek = app.sliders["Tool preview position"]
        func chroma() throws -> Double {
            let bytes = try previewRGB(picture)
            var sum = 0
            for i in stride(from: 0, to: bytes.count, by: 4) {
                let rgb = bytes[i...i+2]
                sum += Int(rgb.max()!) - Int(rgb.min()!)
            }
            return Double(sum) / Double(bytes.count / 4)
        }
        func curve(_ name: String) {
            reveal(app.buttons["effect.curve"]); chooseEffectCurve(name, in: app); waitForTool(app)
        }
        func time(_ label: String, _ fraction: CGFloat) {
            let slider = app.sliders[label]
            reveal(slider); slider.adjust(toNormalizedSliderPosition: fraction); waitForTool(app)
        }
        seek.adjust(toNormalizedSliderPosition: 0.5)
        let middle = app.staticTexts["tool.position"].label
        let linear = try chroma()
        curve("Ease in")
        XCTAssertEqual(app.staticTexts["tool.position"].label, middle)
        XCTAssertGreaterThan(try chroma(), linear + 2)
        curve("Rise, hold & return")
        let hold = try chroma()
        time("Rise time", 0.96)
        XCTAssertEqual(app.staticTexts["tool.position"].label, middle)
        XCTAssertGreaterThan(try chroma(), hold + 2)
        time("Rise time", 0.12)
        seek.adjust(toNormalizedSliderPosition: 0.76)
        let late = app.staticTexts["tool.position"].label
        let beforeReturn = try chroma()
        time("Return time", 0.95)
        XCTAssertEqual(app.staticTexts["tool.position"].label, late)
        XCTAssertGreaterThan(try chroma(), beforeReturn + 2)
    }
    func testEndpointCropReturnAndReopen() {
        let app = animationFixture()
        openTool("crop",in:app); waitForTool(app)
        endpointAction("B",in:app); waitForTool(app)
        let surface = app.otherElements["crop.canvas"]
        surface.pinch(withScale:1.8,velocity:1)
        let second = surface.value as? String
        chooseEffectCurve("Rise, hold & return",in:app); waitForTool(app)
        let screenshot = XCTAttachment(screenshot:XCUIScreen.main.screenshot())
        screenshot.name = "Crop · A and B timing"; screenshot.lifetime = .keepAlways; add(screenshot)
        endpointAction("A",in:app); waitForTool(app)
        XCTAssertNotEqual(surface.value as? String, second)
        endpointAction("B",in:app); waitForTool(app)
        app.buttons["Play crop preview"].tap()
        let pause = app.buttons["Pause crop preview"]
        XCTAssertTrue(pause.waitForExistence(timeout:15)); pause.tap(); waitForTool(app)
        XCTAssertEqual(surface.value as? String, second)
        app.buttons["Play crop preview"].tap()
        XCTAssertTrue(pause.waitForExistence(timeout:15))
        XCTAssertTrue(app.buttons["Play crop preview"].waitForExistence(timeout:35))
        waitForTool(app)
        XCTAssertEqual(surface.value as? String,second,"Completing the preview returns to B as well")
        endpointAction("Done",in:app)
        app.buttons["tool.apply"].tap()
        let chip = app.buttons["effect.crop"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout:25)); chip.tap(); waitForTool(app)
        XCTAssertEqual(app.buttons["effect.curve"].value as? String,"Rise, hold & return")
        endpointAction("B",in:app); waitForTool(app)
        XCTAssertEqual(surface.value as? String,second)
        endpointAction("Remove animation",in:app)
        XCTAssertFalse(app.buttons["effect.curve"].exists)
        XCTAssertEqual(surface.value as? String,second)
    }
    func testEndpointLUTAndImageControls() {
        let app = animationFixture()
        for tool in ["color","image"] {
            openTool(tool,in:app)
            if tool == "color" { waitForTool(app) }
            endpointAction("B",in:app)
            if tool == "color" {
                let inspector = app.scrollViews["tool.settings"]
                let mono = app.buttons["tool.look.mono"]
                revealInViewport(mono,scroll:inspector,swipeX:0.03); mono.tap(); waitForTool(app)
                revealInViewport(app.buttons["effect.curve"],scroll:inspector,swipeX:0.03)
            }
            chooseEffectCurve("Rise & hold",in:app)
            XCTAssertTrue(app.staticTexts.containing(NSPredicate(format:"label BEGINSWITH 'Hold B for'")).firstMatch.exists)
            endpointAction("A",in:app)
            endpointAction("Done",in:app)
            XCTAssertTrue(app.buttons["effect.curve"].exists)
            endpointAction("Remove animation",in:app)
            XCTAssertFalse(app.buttons["effect.curve"].exists)
            app.buttons["tool.cancel"].tap()
        }
    }
    func testEndpointIndependentRiseAndReturn() {
        let app = animationFixture()
        openTool("crop",in:app); waitForTool(app)
        endpointAction("B",in:app); waitForTool(app)
        let curve = app.buttons["effect.curve"]
        XCTAssertEqual(curve.value as? String, "Linear")
        XCTAssertGreaterThanOrEqual(curve.frame.height, 44)
        func capture(_ name: String) {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = name; shot.lifetime = .keepAlways; add(shot)
        }
        capture("Linear curve selector")
        curve.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.5)).tap()
        app.buttons["Rise, hold & return"].tap(); waitForTool(app)
        let inspector = app.scrollViews["crop.settings"]
        let ramp = app.buttons["effect.ramp"]
        ramp.tap(); app.buttons["Ease out"].tap()
        XCTAssertEqual(ramp.value as? String, "Ease out")
        XCTAssertEqual(curve.value as? String, "Rise, hold & return")
        let rise = app.sliders["Rise time"], release = app.sliders["Return time"]
        let held = app.staticTexts.containing(NSPredicate(format:"label BEGINSWITH 'Hold B for'")).firstMatch
        let original = held.label
        revealInViewport(rise,scroll:inspector,swipeX:0.02)
        rise.adjust(toNormalizedSliderPosition:0.25); waitForTool(app)
        XCTAssertNotEqual(held.label,original)
        let afterRise = held.label
        revealInViewport(release,scroll:inspector,swipeX:0.02)
        release.adjust(toNormalizedSliderPosition:0.4); waitForTool(app)
        XCTAssertNotEqual(held.label,afterRise)
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        expectation(for: NSPredicate { _, _ in
            app.frame.width > app.frame.height && inspector.frame.midX > app.frame.midX
        }, evaluatedWith: app)
        waitForExpectations(timeout: 10)
        revealInViewport(curve, scroll: inspector)
        capture("Landscape curve and ramp selectors")
        curve.tap(); app.buttons["Linear"].tap()
        XCTAssertEqual(curve.value as? String, "Linear")
    }

    func testImageRetimingRedrawsOverlayAtScrubbedFrame() {
        let app = animationFixture()
        openTool("image", in: app)
        app.buttons["tool.image.choose"].tap()
        let photo = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        waitForTool(app)
        endpointAction("B", in: app)
        let settings = app.scrollViews["tool.settings"], size = app.sliders["Image size"]
        revealInViewport(size, scroll: settings, swipeX: 0.03)
        size.adjust(toNormalizedSliderPosition: 0.8)
        let overlay = app.descendants(matching: .any).matching(identifier: "tool.image.overlay").firstMatch
        let endpointWidth = overlay.frame.width
        app.sliders["Tool preview position"].adjust(toNormalizedSliderPosition: 0.46)
        let midWidth = overlay.frame.width, time = app.staticTexts["tool.position"].label
        XCTAssertGreaterThan(abs(endpointWidth - midWidth), 4)
        revealInViewport(app.buttons["effect.curve"], scroll: settings, swipeX: 0.03)
        chooseEffectCurve("Ease in", in: app)
        XCTAssertEqual(app.staticTexts["tool.position"].label, time)
        XCTAssertGreaterThan(abs(overlay.frame.width - midWidth), 4)
    }

    func testEndpointCorrectionControls() {
        let app = animationFixture()
        openTool("videoEffects",in:app); openEffectSection("colorStyle",in:app)
        app.buttons["videoEffects.add.colorCorrection"].tap()
        endpointAction("B",in:app)
        let slider = app.sliders["Preview position"]
        slider.adjust(toNormalizedSliderPosition: 0.45)
        let frame = slider.value as? String
        chooseEffectCurve("Ease out",in:app)
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: app.buttons["videoEffects.apply"])
        waitForExpectations(timeout: 30)
        XCTAssertEqual(slider.value as? String, frame)
        endpointAction("Done",in:app); endpointAction("Remove animation",in:app)
        XCTAssertFalse(app.buttons["effect.curve"].exists)
    }
    func testEndpointOverlapPlacementControls() {
        let app = animationFixture(["--tracks-overlap-fixture"])
        let full = app.buttons["Full"]
        XCTAssertTrue(full.waitForExistence(timeout:30))
        expectation(for:NSPredicate(format:"enabled == true"),evaluatedWith:full); waitForExpectations(timeout:45)
        full.tap(); app.sliders["Full preview position"].adjust(toNormalizedSliderPosition:0.34); app.buttons["Done"].tap()
        openTimelinePlacement(in:app)
        endpointAction("A",in:app); endpointAction("B",in:app)
        let seek = app.sliders["Overlap preview position"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: seek)
        waitForExpectations(timeout: 30)
        seek.adjust(toNormalizedSliderPosition: 0.35)
        let inspected = app.staticTexts["placement.time"].label
        chooseEffectCurve("Rise & hold",in:app)
        XCTAssertEqual(app.staticTexts["placement.time"].label, inspected)
        endpointAction("Done",in:app); app.buttons["Apply"].tap()
        openTimelinePlacement(in:app)
        XCTAssertEqual(app.buttons["effect.curve"].value as? String,"Rise & hold")
    }

    func testCropRotationPreviewPersistenceAndUndo() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--editor-preview","--reset-ui-fixture"];app.launch()
        openTool("crop",in:app);waitForTool(app)
        let canvas=app.otherElements["crop.canvas"],turn=app.buttons["crop.rotate90"],reset=app.buttons["crop.rotationReset"]
        XCTAssertTrue(turn.isHittable)
        for angle in ["90.0","180.0","-90.0","0.0"] {
            turn.tap();XCTAssertTrue((canvas.value as? String ?? "").contains("Rotation \(angle) degrees"))
        }
        let slider=app.sliders["crop.rotation"];slider.adjust(toNormalizedSliderPosition:0.55)
        XCTAssertFalse((canvas.value as? String ?? "").contains("Rotation 0.0 degrees"))
        canvas.pinch(withScale:1.8,velocity:1)
        let before=canvas.value as? String
        canvas.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).press(forDuration:0.05,thenDragTo:canvas.coordinate(withNormalizedOffset:CGVector(dx:0.65,dy:0.5)))
        XCTAssertNotEqual(canvas.value as? String,before,"Dragging still changes framing after rotation")
        let portrait=XCTAttachment(screenshot:XCUIScreen.main.screenshot());portrait.name="Crop rotation portrait";portrait.lifetime = .keepAlways;add(portrait)
        reset.tap();XCTAssertTrue((canvas.value as? String ?? "").contains("Rotation 0.0 degrees"))
        turn.tap();let saved=canvas.value as? String
        app.buttons["crop.preview"].tap();waitForTool(app)
        app.buttons["Play crop preview"].tap();XCTAssertTrue(app.buttons["Pause crop preview"].exists)
        app.buttons["tool.apply"].tap();XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout:10))
        app.buttons["effect.crop"].firstMatch.tap();waitForTool(app);XCTAssertEqual(canvas.value as? String,saved)
        XCUIDevice.shared.orientation = .landscapeLeft
        expectation(for:NSPredicate {_,_ in app.windows.firstMatch.frame.width>app.windows.firstMatch.frame.height},evaluatedWith:app);waitForExpectations(timeout:8)
        XCTAssertTrue(turn.isHittable);XCTAssertTrue(slider.isHittable);XCTAssertTrue(app.buttons["tool.apply"].isHittable)
        let landscape=XCTAttachment(screenshot:XCUIScreen.main.screenshot());landscape.name="Crop rotation landscape";landscape.lifetime = .keepAlways;add(landscape)
        app.buttons["tool.cancel"].tap();app.buttons["Undo"].tap();XCTAssertFalse(app.buttons["effect.crop"].exists)
        app.buttons["Redo"].tap();app.terminate();app.launchArguments=["--editor-preview"];app.launch()
        app.buttons["effect.crop"].firstMatch.tap();waitForTool(app);XCTAssertEqual(canvas.value as? String,saved)
        app.buttons["tool.remove"].tap();XCTAssertFalse(app.buttons["effect.crop"].exists)
        XCUIDevice.shared.orientation = .portrait
    }
    func testCropFramingShapeCancelReeditAndUndo() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]; app.launch()
        openTool("crop", in: app); waitForTool(app)
        app.buttons["tool.apply"].tap()
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Undo"].isEnabled, "A neutral crop does not add an edit")
        XCTAssertFalse(app.buttons["effect.crop"].exists)
        openTool("crop", in: app); waitForTool(app)
        let canvas = app.otherElements["crop.canvas"]
        XCTAssertTrue(canvas.isHittable)
        canvas.pinch(withScale: 2, velocity: 1)
        XCTAssertFalse((canvas.value as? String ?? "").contains("Zoom 1.0 times"))
        canvas.swipeLeft()
        let edgePosition = canvas.value as? String
        app.buttons["crop.shape"].tap(); app.buttons["9:16"].tap(); waitForTool(app)
        XCTAssertEqual(canvas.value as? String, edgePosition, "Changing shape must not reveal a position hidden beyond the previous crop edge")
        app.buttons["crop.shape"].tap(); app.collectionViews.buttons["Original"].tap(); waitForTool(app)
        revealCrop(app.buttons["crop.reset"],in:app);app.buttons["crop.reset"].tap()
        XCTAssertTrue((canvas.value as? String ?? "").contains("Zoom 1.0 times"))
        revealCrop(app.sliders["Crop zoom"],in:app);app.sliders["Crop zoom"].adjust(toNormalizedSliderPosition: 0.2)
        let frame = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); frame.name = "Crop framing portrait"; frame.lifetime = .keepAlways; add(frame)
        app.buttons["crop.preview"].tap(); waitForTool(app)
        app.buttons["Play crop preview"].tap(); XCTAssertTrue(app.buttons["Pause crop preview"].exists)
        app.buttons["tool.cancel"].tap()
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 10)); XCTAssertFalse(app.buttons["Undo"].isEnabled)
        openTool("crop", in: app); waitForTool(app)
        app.buttons["crop.shape"].tap(); app.buttons["1:1"].tap(); waitForTool(app)
        revealCrop(app.sliders["Crop zoom"],in:app);app.sliders["Crop zoom"].adjust(toNormalizedSliderPosition: 0.15)
        let zoom = canvas.value as? String
        app.buttons["tool.apply"].tap()
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["editor.duration"].label, "0:18.00")
        app.buttons["effect.crop"].firstMatch.tap(); waitForTool(app)
        XCTAssertEqual(canvas.value as? String, zoom)
        XCTAssertTrue(app.buttons["crop.shape"].label.contains("1:1"))
        app.buttons["tool.cancel"].tap(); app.buttons["Undo"].tap()
        XCTAssertFalse(app.buttons["effect.crop"].exists)
        app.buttons["Redo"].tap(); XCTAssertTrue(app.buttons["effect.crop"].waitForExistence(timeout: 10))
        app.terminate(); app.launchArguments = ["--editor-preview"]; app.launch()
        XCTAssertTrue(app.buttons["effect.crop"].waitForExistence(timeout: 25)); app.buttons["effect.crop"].firstMatch.tap(); waitForTool(app)
        XCTAssertEqual(canvas.value as? String, zoom)
        let remove = app.buttons["tool.remove"]
        for _ in 0..<5 { if remove.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(remove.isHittable); remove.tap()
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 10)); XCTAssertFalse(app.buttons["effect.crop"].exists)
    }
    func testCropLandscapeAndAccessibleControls() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityM"]; app.launch()
        openTool("crop", in: app); waitForTool(app)
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        expectation(for: NSPredicate { _, _ in app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height }, evaluatedWith: app); waitForExpectations(timeout: 8)
        XCTAssertTrue(app.buttons["tool.apply"].isHittable); XCTAssertTrue(app.buttons["tool.cancel"].isHittable)
        revealCrop(app.sliders["Crop zoom"],in:app);app.sliders["Crop zoom"].adjust(toNormalizedSliderPosition: 0.25)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Crop landscape accessible type"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["crop.preview"].tap(); waitForTool(app)
        XCTAssertTrue(app.buttons["Play crop preview"].isHittable)
        app.buttons["tool.cancel"].tap()
    }
    func testTextEndSliderCanReachOneFrameAndGrowAgain() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]
        app.launchEnvironment["YOUREC_EDITOR_FIXTURE_TITLE"] = "Title trim QA"
        app.launch()
        openTool("text", in: app)
        let field = app.textFields["tool.text.input"].exists ? app.textFields["tool.text.input"] : app.textViews["tool.text.input"]
        field.tap(); field.typeText("Timing")
        if app.buttons["Done"].firstMatch.exists { app.buttons["Done"].firstMatch.tap() }
        let controls = app.scrollViews["tool.settings"]
        let timing = app.buttons["overlay.timing"]
        revealInViewport(timing, scroll: controls); timing.tap()
        let end = app.sliders["Text end"]
        revealInViewport(end, scroll: controls)
        end.adjust(toNormalizedSliderPosition: 0)
        XCTAssertEqual(app.staticTexts["tool.duration"].label, "0:00.03")
        XCTAssertFalse(app.sliders["Text start"].isEnabled, "Both handles must keep the final frame")
        end.adjust(toNormalizedSliderPosition: 0.5)
        waitForTool(app)
        let pickedDuration = app.staticTexts["tool.duration"].label
        XCTAssertNotEqual(pickedDuration, "0:00.03")
        app.buttons["tool.apply"].tap()
        let title = app.buttons["effect.text"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10)); title.tap()
        waitForTool(app)
        XCTAssertEqual(app.staticTexts["tool.duration"].label, pickedDuration)
        app.buttons["tool.cancel"].tap()
    }

    func testTitleDurationQuickPicksAndCustomEnd() throws { checkOverlayDurations(tool: "text", title: "Text") }
    func testImageDurationQuickPicksAndCustomEnd() throws { checkOverlayDurations(tool: "image", title: "Image") }
    private func checkOverlayDurations(tool: String, title: String) {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--long-title-ui-fixture"]
        app.launchEnvironment["YOUREC_EDITOR_FIXTURE_TITLE"] = title + " timing QA"
        app.launch()
        openTool(tool, in: app)
        let controls = app.scrollViews["tool.settings"]
        let timing = app.buttons["overlay.timing"]
        revealInViewport(timing, scroll: controls); timing.tap()
        let duration = app.staticTexts["tool.duration"]
        for seconds in Array(1...10) + [15, 30, 60] {
            let choice = app.buttons["overlay.duration.\(seconds)"]
            revealInViewport(choice, scroll: controls)
            choice.tap()
            XCTAssertTrue(choice.isSelected)
            let expected = String(format: "%d:%05.2f", seconds / 60, Double(seconds % 60))
            expectation(for: NSPredicate(format: "label == %@", expected), evaluatedWith: duration)
            waitForExpectations(timeout: 8)
        }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = title + " duration quick picks"; shot.lifetime = .keepAlways; add(shot)
        XCUIDevice.shared.orientation = .landscapeLeft
        expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: app)
        waitForExpectations(timeout: 8)
        let start = app.sliders[title + " start"]
        revealInViewport(start, scroll: controls); start.adjust(toNormalizedSliderPosition: 0.5)
        let originalStart = start.value as? String
        let long = app.buttons["overlay.duration.60"]
        revealInViewport(long, scroll: controls)
        XCTAssertFalse(long.isEnabled)
        app.buttons["overlay.duration.30"].tap()
        expectation(for: NSPredicate(format: "label == %@", "0:30.00"), evaluatedWith: duration); waitForExpectations(timeout: 8)
        revealInViewport(start, scroll: controls)
        XCTAssertEqual(start.value as? String, originalStart)
        let toEnd = app.buttons["overlay.toEnd"]
        revealInViewport(toEnd, scroll: controls); toEnd.tap()
        expectation(for: NSPredicate(format: "label != %@", "0:30.00"), evaluatedWith: duration); waitForExpectations(timeout: 8)
        app.buttons["tool.cancel"].tap()
    }

    private func chooseQAFont(_ filename: String, in app: XCUIApplication) throws {
        XCTAssertTrue(app.navigationBars["FullDocumentManagerViewControllerNavigationBar"].waitForExistence(timeout: 12), "Import should open the system Files picker")
        let stem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        let file = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@ OR label BEGINSWITH %@", stem, stem + ",", filename)).firstMatch
        if !file.exists {
            let tabs = app.tabBars["DOC.browsingModeTabBar"]
            let browse = tabs.buttons.matching(NSPredicate(format: "label IN %@", ["Browse", "Sfoglia"])).firstMatch
            if browse.exists && !browse.isSelected { browse.tap() }
            let local = app.cells.matching(NSPredicate(format: "identifier IN {'DOC.sidebar.item.On My iPhone','DOC.sidebar.item.iPhone'} OR label IN %@", ["On My iPhone", "Sul mio iPhone", "Su iPhone"])).firstMatch
            let back = app.navigationBars["FullDocumentManagerViewControllerNavigationBar"].buttons["BackButton"]
            for _ in 0..<5 where !local.exists && back.exists { back.tap() }
            if local.waitForExistence(timeout: 2) { local.tap() }
            let group = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'YouRec Font QA'")).firstMatch
            guard group.waitForExistence(timeout: 8) else {
                throw XCTSkip("Copy Tests/Fixtures/Fonts to On My iPhone/YouRec Font QA to exercise the native Files picker.")
            }
            group.tap()
        }
        XCTAssertTrue(file.waitForExistence(timeout: 10), "Missing QA font in the Files picker"); file.tap()
        for name in ["Open", "Apri"] where app.buttons[name].exists && app.buttons[name].isEnabled { app.buttons[name].tap(); break }
    }

    func testFontCollectionImportedFromSubtitleInspector() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--subtitles-ui-fixture"]
        app.launchEnvironment["YOUREC_RECOVERY_TEST_RUN"] = UUID().uuidString
        app.launch()
        openTool("subtitles", in: app)
        let controls = app.scrollViews["subtitles.controls"]
        for name in ["Appearance", "subtitles.tab.Font", "subtitles.fonts.import"] {
            let button = app.buttons[name]; revealInViewport(button, scroll: controls); button.tap()
        }
        let add = app.buttons["fonts.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 15)); add.tap()
        try chooseQAFont("YouRec-QA-Ink-Family.otc", in: app)
        let bold = app.buttons["Use YouRec QA Ink Bold"]
        XCTAssertTrue(bold.waitForExistence(timeout: 15))
        let sample = XCTAttachment(screenshot: app.screenshot()); sample.name = "Imported font collection"; sample.lifetime = .keepAlways; self.add(sample)
        bold.tap()
        let face = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'subtitles.face.import:' AND label == 'YouRec QA Ink Bold'")).firstMatch
        XCTAssertTrue(face.waitForExistence(timeout: 10)); XCTAssertTrue(face.isSelected)
        app.buttons["subtitles.apply"].tap()
    }

    // The native Files picker reads the original test font from On My iPhone /
    // YouRec Font QA. The project and the imported library both use this run's UUID.
    func testImportFontFromTitleReuseInSubtitlesAndRemoveFromSettings() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--subtitles-ui-fixture"]
        app.launchEnvironment["YOUREC_RECOVERY_TEST_RUN"] = UUID().uuidString
        app.launch()
        func tap(_ item: XCUIElement, in scroll: XCUIElement) {
            revealInViewport(item, scroll: scroll)
            XCTAssertTrue(item.isHittable); item.tap()
        }
        func fontTab(_ prefix: String, in scroll: XCUIElement) {
            tap(app.buttons[prefix + ".tab.Font"], in: scroll)
        }
        func selectedFace(_ prefix: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", prefix + ".face.import:", "YouRec QA Triangle Regular")).firstMatch
        }
        openTool("text", in: app)
        let input = app.textFields["tool.text.input"].exists ? app.textFields["tool.text.input"] : app.textViews["tool.text.input"]
        input.tap(); input.typeText("Font draft")
        if app.buttons["Done"].firstMatch.exists { app.buttons["Done"].firstMatch.tap() }
        let draftText = try XCTUnwrap(input.value as? String)
        XCTAssertTrue(draftText.contains("Font draft"))
        let titleControls = app.scrollViews["tool.settings"]
        fontTab("title", in: titleControls)
        tap(app.buttons["title.fonts.import"], in: titleControls)
        let add = app.buttons["fonts.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10)); add.tap()
        try chooseQAFont("YouRec-QA-Triangle.ttf", in: app)
        let chosen = selectedFace("title")
        XCTAssertTrue(chosen.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(chosen.isSelected)
        XCTAssertEqual(input.value as? String, draftText)
        app.buttons["tool.apply"].tap()

        openTool("subtitles", in: app)
        let controls = app.scrollViews["subtitles.controls"]
        tap(app.buttons["Appearance"], in: controls); fontTab("subtitles", in: controls)
        tap(app.buttons["subtitles.fonts.import"], in: controls)
        let use = app.buttons["Use YouRec QA Triangle Regular"]
        XCTAssertTrue(use.waitForExistence(timeout: 10)); use.tap()
        XCTAssertTrue(selectedFace("subtitles").waitForExistence(timeout: 10))
        XCTAssertTrue(selectedFace("subtitles").isSelected)
        app.buttons["subtitles.apply"].tap()

        app.buttons["Tools"].tap()
        let list = app.scrollViews["tools.content"]
        tap(app.buttons["tools.settings.fonts"], in: list)
        let remove = app.buttons["Remove YouRec-QA-Triangle.ttf"]
        XCTAssertTrue(remove.waitForExistence(timeout: 8)); remove.tap(); app.buttons["Remove from library"].tap()
        XCTAssertTrue(remove.waitForNonExistence(timeout: 8))
        app.terminate(); app.launchArguments = ["--editor-preview"]; app.launch()
        XCTAssertTrue(app.buttons["effect.text"].firstMatch.waitForExistence(timeout: 30))
        app.buttons["effect.text"].firstMatch.tap(); fontTab("title", in: titleControls)
        XCTAssertTrue(selectedFace("title").isSelected)
        XCTAssertEqual(input.value as? String, draftText)
        app.buttons["tool.cancel"].tap()
        openTool("subtitles", in: app); tap(app.buttons["Appearance"], in: controls); fontTab("subtitles", in: controls)
        XCTAssertTrue(selectedFace("subtitles").isSelected)
    }

    func testTitleOutlineGradientMotionAndExport() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]
        app.launchEnvironment["YOUREC_EDITOR_FIXTURE_TITLE"] = "Title design QA"
        app.launch()
        openTool("text", in: app)
        let field = app.textFields["tool.text.input"].exists ? app.textFields["tool.text.input"] : app.textViews["tool.text.input"]
        field.tap(); field.typeText("ORIZZONTE")
        if app.buttons["Done"].firstMatch.exists { app.buttons["Done"].firstMatch.tap() }
        let controls = app.scrollViews["tool.settings"]
        func button(_ name: String) {
            let item = app.buttons[name]
            revealInViewport(item, scroll: controls); item.tap()
        }
        func tab(_ name: String) {
            // The categories are at the top of the inspector.
            for _ in 0..<10 {
                let item = app.buttons["title.tab." + name]
                if item.exists && item.isHittable && controls.frame.contains(CGPoint(x:item.frame.midX,y:item.frame.midY)) { item.tap(); return }
                controls.swipeDown()
            }
            XCTFail("Could not open " + name)
        }
        tab("Outline")
        let outline = app.switches["title.outline"]
        revealInViewport(outline,scroll:controls); outline.tap()
        tab("Looks"); button("title.look.Headline")
        tab("Outline")
        revealInViewport(outline,scroll:controls); XCTAssertEqual(outline.value as? String,"1")
        tab("Fill")
        let gradient = app.segmentedControls["title.fillMode"].buttons["Gradient"]
        revealInViewport(gradient,scroll:controls); gradient.tap()
        button("title.gradient.Lagoon")
        let shot = XCTAttachment(screenshot:app.screenshot()); shot.name="Title gradient gallery"; shot.lifetime = .keepAlways; add(shot)
        tab("Motion"); button("title.motion.drift")
        let exit = app.segmentedControls.buttons["Exit"].firstMatch
        revealInViewport(exit,scroll:controls); exit.tap(); button("title.motion.wipe"); button("title.replay")
        let readout=app.staticTexts["tool.position"]
        expectation(for:NSPredicate(format:"label != '0:00.00'"),evaluatedWith:readout); waitForExpectations(timeout:8)
        app.buttons["tool.apply"].tap()
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout:20))
        app.buttons["effect.text"].firstMatch.tap()
        tab("Fill"); XCTAssertTrue(app.buttons["title.gradient.Lagoon"].exists)
        XCTAssertTrue(app.buttons["title.gradient.Lagoon"].isSelected)
        tab("Motion")
        XCTAssertTrue(app.buttons["title.motion.drift"].isSelected)
        app.buttons["tool.cancel"].tap()
        app.buttons["Export"].tap(); app.buttons["Export video"].tap()
        XCTAssertTrue(app.buttons["Save to Photos"].waitForExistence(timeout:120))
    }

    func testSavedTitleLookInAnotherProjectsCaptions() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        let name = "Studio " + String(UUID().uuidString.prefix(6))
        app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]
        app.launchEnvironment["YOUREC_EDITOR_FIXTURE_TITLE"] = "Channel style title QA"
        app.launch()
        openTool("text", in: app)
        var controls = app.scrollViews["tool.settings"]
        func tap(_ name: String) {
            let item = app.buttons[name]
            revealInViewport(item, scroll: controls)
            item.tap()
        }
        tap("title.look.Sunset mono")
        tap("Save as channel style")
        let alert = app.alerts["Save channel style"]
        alert.textFields["Style name"].tap()
        alert.textFields["Style name"].typeText(name)
        alert.buttons["Save"].tap()
        app.terminate()
        app.launchEnvironment["YOUREC_EDITOR_FIXTURE_TITLE"] = "Channel style captions QA"
        app.launchArguments.append("--subtitles-ui-fixture")
        app.launch()
        openTool("subtitles", in: app)
        controls = app.scrollViews["subtitles.controls"]
        tap("Appearance")
        tap("subtitles.look." + name)
        tap("subtitles.tab.Fill")
        let sunset = app.buttons["subtitles.gradient.Sunset"]
        revealInViewport(sunset, scroll: controls)
        XCTAssertTrue(sunset.isSelected, "A channel style must carry its gradient into another project's subtitles")
        tap("First color")
        tap("Sample video frame")
        let sample = app.descendants(matching: .any).matching(identifier: "title.frameSample").firstMatch
        XCTAssertTrue(sample.waitForExistence(timeout: 20))
        sample.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.45)).tap()
        XCTAssertTrue(sample.waitForNonExistence(timeout: 5))
        let stopHex = app.textFields["First color hex"]
        revealInViewport(stopHex, scroll: controls)
        let sampled = try XCTUnwrap(stopHex.value as? String)
        XCTAssertEqual(sampled.count, 6)
        XCTAssertNotEqual(sampled, "FFF0BA", "Sampling the underlying video must update the first gradient stop")
        tap("First color")
        for _ in 0..<12 {
            if app.buttons["subtitles.tab.Looks"].isHittable { break }
            controls.swipeDown()
        }
        tap("subtitles.tab.Looks")
        tap("Delete " + name)
        app.buttons["Delete style"].tap()
        XCTAssertTrue(app.buttons["subtitles.look." + name].waitForNonExistence(timeout: 5))
    }

    func testToolsTextReeditRemoveAndUndo() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]; app.launch()
        openTool("text", in: app)
        let input = app.textFields["tool.text.input"].exists ? app.textFields["tool.text.input"] : app.textViews["tool.text.input"]
        XCTAssertTrue(input.exists); input.tap()
        let value = input.value as? String ?? ""
        input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count) + "Hello YouRec")
        if app.buttons["Done"].exists { app.buttons["Done"].firstMatch.tap() }
        let palette = app.buttons["title.tab.Looks"]
        revealInViewport(palette,scroll:app.scrollViews["tool.settings"]); palette.tap()
        let film = app.buttons["title.look.Film title"]
        revealInViewport(film,scroll:app.scrollViews["tool.settings"]); film.tap()
        if app.buttons["Done"].exists { app.buttons["Done"].tap() }
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Text canvas"; shot.lifetime = .keepAlways; add(shot)
        waitForTool(app); app.buttons["tool.apply"].tap()
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 10))
        let editorShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); editorShot.name = "Text effect in editor status bar"; editorShot.lifetime = .keepAlways; add(editorShot)
        app.buttons["effect.text"].firstMatch.tap()
        XCTAssertTrue(app.buttons["tool.remove"].waitForExistence(timeout: 10))
        let reopened = app.textFields["tool.text.input"].exists ? app.textFields["tool.text.input"] : app.textViews["tool.text.input"]
        XCTAssertEqual(reopened.value as? String, "Hello YouRec")
        app.buttons["tool.remove"].tap()
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 10)); app.buttons["Undo"].tap()
        app.buttons["effect.text"].firstMatch.tap()
        XCTAssertTrue(app.buttons["tool.remove"].waitForExistence(timeout: 10)); app.buttons["tool.cancel"].tap()
    }
    func testToolsSpeedColorPausesAndLandscape() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]; app.launch()
        openTool("speed", in: app); app.buttons["2×"].tap(); waitForTool(app)
        app.buttons["tool.apply"].tap()
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["editor.duration"].label, "0:09.00")
        openTool("color", in: app); app.buttons["tool.look.warm"].tap(); waitForTool(app)
        XCUIDevice.shared.orientation = .landscapeLeft
        expectation(for: NSPredicate { _, _ in app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height }, evaluatedWith: app)
        waitForExpectations(timeout: 8)
        XCTAssertTrue(app.buttons["tool.apply"].isHittable); XCTAssertTrue(app.buttons["tool.before"].isHittable)
        app.buttons["tool.before"].tap(); waitForTool(app); app.buttons["tool.after"].tap(); waitForTool(app)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Tools landscape"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["tool.apply"].tap()
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 10))
        let editorShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); editorShot.name = "Effects in landscape editor status bar"; editorShot.lifetime = .keepAlways; add(editorShot)
        XCUIDevice.shared.orientation = .portrait
        openTool("pauses", in: app)
        // At 2× the fixture's one-second silences last only half a second,
        // below the default 0.6 s minimum: there is no cut to Apply.
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'No pauses found.'")).firstMatch.waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["Play tool preview"].isEnabled)
        XCTAssertTrue(app.buttons["tool.pauses.settings"].exists)
        app.buttons["tool.cancel"].tap()
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 10))
        app.buttons["Undo"].tap(); app.buttons["Undo"].tap()
        XCTAssertEqual(app.staticTexts["editor.duration"].label, "0:18.00")
    }
    func testStabilizationApplyCompareUndoAndCancel() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]; app.launch()
        openTool("stabilize", in: app); waitForTool(app)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "0:18.00", "s preview")).firstMatch.exists)
        app.buttons["tool.before"].tap(); waitForTool(app)
        app.buttons["tool.after"].tap(); waitForTool(app)
        app.buttons["tool.level.strong"].tap(); waitForTool(app)
        app.buttons["tool.apply"].tap()
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 10)); app.buttons["Undo"].tap()
        openTool("stabilize", in: app); app.buttons["tool.level.off"].tap(); waitForTool(app)
        app.buttons["tool.cancel"].tap()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 10)); app.buttons["Play"].tap()
        XCTAssertTrue(app.buttons["Pause playback"].waitForExistence(timeout: 4))
    }
    func testLongStabilizationSurvivesInspectorAndCancel() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--long-stabilization-ui"]
        app.launchEnvironment["YOUREC_EDITOR_FIXTURE_TITLE"] = "Stabilization review " + UUID().uuidString
        app.launch()
        let duration = app.staticTexts["editor.duration"]
        XCTAssertTrue(duration.waitForExistence(timeout: 90))
        XCTAssertEqual(duration.label, "20:00.00")
        openTool("stabilize", in: app)
        app.buttons["tool.apply"].tap()
        let undo = app.buttons["editor.undoApplication"]
        XCTAssertTrue(undo.waitForExistence(timeout: 20))
        let chip = app.buttons["effect.stabilize"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 10)); chip.tap()
        let status = app.staticTexts["stabilize.savedStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 8))
        XCTAssertTrue(status.label.contains("Applying stabilization"), status.label)
        func percent(_ label: String) -> Int? {
            label.split(separator: " ").first(where: { $0.hasSuffix("%") }).flatMap { Int($0.dropLast()) }
        }
        expectation(for: NSPredicate { _, _ in (percent(status.label) ?? 0) >= 15 }, evaluatedWith: status)
        waitForExpectations(timeout: 180)
        let before = try XCTUnwrap(percent(status.label))
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "Saved stabilization while applying"; shot.lifetime = .keepAlways; add(shot)
        XCTAssertTrue(app.buttons["stabilize.done"].isHittable)
        XCTAssertFalse(app.buttons["tool.apply"].exists)
        app.buttons["tool.level.strong"].tap()
        XCTAssertEqual(app.buttons["tool.apply"].label, "Apply changes")
        app.buttons["tool.cancel"].tap()
        XCTAssertTrue(undo.waitForExistence(timeout: 8))
        let editorProgress = app.staticTexts["editor.applicationProgress"]
        XCTAssertTrue(editorProgress.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(percent(editorProgress.label)), before)
        chip.tap()
        XCTAssertTrue(app.buttons["tool.level.standard"].isSelected)
        let finished = NSPredicate(format: "label == %@", "Applied · Standard")
        expectation(for: finished, evaluatedWith: status)
        waitForExpectations(timeout: 900)
        XCTAssertTrue(app.buttons["stabilize.previewSaved"].isHittable)
        app.buttons["stabilize.done"].tap()
        XCTAssertFalse(undo.exists)
        let play = app.buttons["Play"]
        let head = app.staticTexts["editor.playhead"], parked = head.label
        XCTAssertTrue(play.isEnabled); play.tap()
        XCTAssertTrue(app.buttons["Pause playback"].waitForExistence(timeout: 8))
        expectation(for: NSPredicate(format: "label != %@", parked), evaluatedWith: head)
        waitForExpectations(timeout: 8)
        app.buttons["Pause playback"].tap()
        app.terminate(); app.launch()
        XCTAssertTrue(chip.waitForExistence(timeout: 30))
        chip.tap()
        app.buttons["stabilize.previewSaved"].tap()
        let sampleDuration = app.staticTexts["tool.duration"]
        XCTAssertTrue(sampleDuration.waitForExistence(timeout: 8))
        app.buttons["tool.level.strong"].tap()
        app.buttons["tool.apply"].tap()
        XCTAssertTrue(chip.waitForExistence(timeout: 15)); chip.tap()
        expectation(for: NSPredicate(format: "label == %@", "Applied · Strong"), evaluatedWith: status)
        waitForExpectations(timeout: 45)
        app.buttons["stabilize.done"].tap()
        app.buttons["Undo"].tap()
        XCTAssertTrue(chip.waitForExistence(timeout: 8))
        app.buttons["Undo"].tap()
        XCTAssertFalse(chip.exists, "Inspecting or cancelling added an undo step")
        XCTAssertEqual(duration.label, "20:00.00")
    }

    func testStabilizationLandscapeAndLargeText() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityM"]; app.launch()
        openTool("stabilize", in: app)
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        expectation(for: NSPredicate { _, _ in app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height }, evaluatedWith: app)
        waitForExpectations(timeout: 8)
        XCTAssertTrue(app.buttons["tool.cancel"].isHittable); XCTAssertTrue(app.buttons["tool.apply"].isHittable)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Tools landscape large type"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["tool.cancel"].tap()
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        XCUIDevice.shared.orientation = .portrait
    }

    func testAudioLandscapeSidebarAndListeningControls() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]; app.launch()
        XCTAssertTrue(app.buttons["Audio filters"].waitForExistence(timeout: 20)); app.buttons["Audio filters"].tap()
        for name in ["AI voice isolation", "AI studio clarity", "Voice EQ", "Low-cut filter"] {
            app.buttons["Add filter"].tap(); app.buttons[name].tap()
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let details = app.scrollViews["audio.details"], strips = app.scrollViews["audio.strips"]
        XCTAssertTrue(details.waitForExistence(timeout: 5))
        expectation(for: NSPredicate { _, _ in app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height }, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        XCTAssertGreaterThan(strips.frame.width, details.frame.width * 1.75, "Columns receive most of the landscape width")
        let match = app.switches["audio.matchLevels"]
        for name in ["AI voice isolation amount", "AI studio clarity amount", "Voice EQ gain", "Low-cut filter cutoff"] {
            let fader = app.otherElements[name]
            XCTAssertTrue(fader.isHittable, "Four columns fit without horizontal scrolling")
            fader.tap()
            XCTAssertGreaterThanOrEqual(match.frame.minY, details.frame.maxY + 8, "Listening controls stay below the sidebar")
            XCTAssertTrue(app.buttons["Reset selected effect"].isHittable)
        }
        app.otherElements["AI voice isolation amount"].tap()
        app.buttons["Noise reduction model"].tap(); app.buttons["DeepFilterNet3"].tap()
        let before = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); before.name = "Narrow landscape sidebar"; before.lifetime = .keepAlways; add(before)
        // Exercise the nested scroller in both directions, then interact with
        // the controls immediately below it: overflow must not intercept them.
        for dy in [0.85, 0.15] {
            details.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: details.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: dy)))
        }
        XCTAssertTrue(match.isHittable)
        let old = match.value as? String; match.tap(); XCTAssertNotEqual(match.value as? String, old)
        XCTAssertGreaterThanOrEqual(match.frame.minY, details.frame.maxY + 8)
        let after = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); after.name = "Listening controls after sidebar scrolling"; after.lifetime = .keepAlways; add(after)
    }

    func testAudioStripDownwardDragAndReset() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]; app.launch()
        XCTAssertTrue(app.buttons["Audio filters"].waitForExistence(timeout: 20)); app.buttons["Audio filters"].tap()
        app.buttons["Add filter"].tap(); app.buttons["Output gain"].tap()
        let gain = app.otherElements["Output gain"]
        let neutral = gain.value as? String
        let top = gain.frame.minY
        gain.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .press(forDuration: 0.05, thenDragTo: gain.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)))
        XCTAssertTrue((gain.value as? String ?? "").hasPrefix("-"))
        XCTAssertEqual(gain.frame.minY, top, accuracy: 2, "The sheet stays still during downward adjustment")
        app.buttons["Reset selected effect"].tap(); XCTAssertEqual(gain.value as? String, neutral)
        app.buttons["Done"].tap(); app.buttons["Undo"].tap(); app.buttons["Audio filters"].tap()
        XCTAssertTrue((gain.value as? String ?? "").hasPrefix("-"), "Reset is independently undoable")
    }

    func testAudioStripHorizontalScrollPreservesValues() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]; app.launch()
        XCTAssertTrue(app.buttons["Audio filters"].waitForExistence(timeout: 20)); app.buttons["Audio filters"].tap()
        for name in ["AI voice isolation", "AI studio clarity", "Voice EQ", "Low-cut filter", "Output gain", "Low-cut filter"] {
            app.buttons["Add filter"].tap(); app.buttons[name].tap()
        }
        let faders = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH 'audio.fader.'"))
        let values = Dictionary(uniqueKeysWithValues: faders.allElementsBoundByIndex.map { ($0.identifier, $0.value as? String ?? "") })
        let first = app.otherElements["AI voice isolation amount"]
        XCTAssertFalse(first.isHittable)
        let last = faders.element(boundBy: 5)
        let start = last.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -240, dy: 0)))
        // A swipe in the opposite direction must reveal the earlier stages.
        let row = app.scrollViews["audio.strips"]
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.75))
            .press(forDuration: 0.05, thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.75)))
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.75))
            .press(forDuration: 0.05, thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.75)))
        XCTAssertTrue(first.isHittable)
        for fader in faders.allElementsBoundByIndex { XCTAssertEqual(fader.value as? String, values[fader.identifier]) }
        first.tap(); XCTAssertTrue(app.buttons["Noise reduction model"].exists)
        XCTAssertTrue(app.buttons["audio.original"].isHittable)
    }

    func testAudioStripLargeTextAndLandscape() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityM"]
        app.launch(); XCTAssertTrue(app.buttons["Audio filters"].waitForExistence(timeout: 20))
        app.buttons["Audio filters"].tap()
        for name in ["AI voice isolation", "Voice EQ"] { app.buttons["Add filter"].tap(); app.buttons[name].tap() }
        XCTAssertTrue(app.otherElements["Voice EQ gain"].isHittable)
        XCTAssertTrue(app.buttons["Voice EQ enabled"].isHittable)
        XCTAssertTrue(app.buttons["Apply & listen"].isHittable)
        let portrait = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); portrait.name = "Audio strips large text portrait"; portrait.lifetime = .keepAlways; add(portrait)
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
        expectation(for: NSPredicate { _, _ in app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height }, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.buttons["audio.original"].isHittable)
        XCTAssertTrue(app.buttons["Apply & listen"].isHittable)
        XCTAssertTrue(app.buttons["Done"].isHittable)
        XCTAssertTrue(app.buttons["Add filter"].isHittable)
        XCTAssertGreaterThanOrEqual(app.buttons["Done"].frame.minY, 0)
        let eq = app.otherElements["Voice EQ gain"]
        XCTAssertTrue(eq.isHittable)
        XCTAssertLessThanOrEqual(eq.frame.maxY, app.windows.firstMatch.frame.maxY - 29, "The fader stays above the system gesture area")
        XCTAssertTrue(app.sliders["EQ frequency"].isHittable, "Selected settings remain visible alongside the faders")
        XCTAssertTrue(app.buttons["Reset selected effect"].isHittable)
        XCTAssertTrue(app.buttons["Remove effect"].isHittable)
        let previous = eq.value as? String
        eq.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            .press(forDuration: 0.05, thenDragTo: eq.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
        XCTAssertNotEqual(eq.value as? String, previous)
        let landscape = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); landscape.name = "Audio strips large text landscape"; landscape.lifetime = .keepAlways; add(landscape)
        app.buttons["Done"].tap()
    }

    func testAudioStripAdjustmentReorderAndHistory() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]; app.launch()
        XCTAssertTrue(app.buttons["Audio filters"].waitForExistence(timeout: 20))
        app.buttons["Audio filters"].tap()
        for name in ["AI voice isolation", "AI studio clarity", "Voice EQ", "Output gain"] {
            app.buttons["Add filter"].tap(); app.buttons[name].tap()
        }
        let gain = app.otherElements["Output gain"]
        XCTAssertTrue(gain.waitForExistence(timeout: 5), app.debugDescription)
        let neutral = gain.value as? String
        XCTAssertTrue(neutral?.contains("0") == true)
        // Selection taps must never jump the primary value.
        gain.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        XCTAssertEqual(gain.value as? String, neutral)
        gain.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.70))
            .press(forDuration: 0.05, thenDragTo: gain.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)))
        let adjusted = gain.value as? String
        XCTAssertNotEqual(adjusted, neutral)
        XCTAssertTrue(app.buttons["Done"].isHittable, "Adjusting must not dismiss the sheet")
        app.buttons["Done"].tap(); app.buttons["Undo"].tap(); app.buttons["Audio filters"].tap()
        XCTAssertEqual(gain.value as? String, neutral, "One undo restores the entire gesture")
        app.buttons["Done"].tap(); app.buttons["Redo"].tap(); app.buttons["Audio filters"].tap()
        XCTAssertEqual(gain.value as? String, adjusted)
        gain.tap()
        let power = app.buttons["Output gain enabled"]
        power.tap(); XCTAssertEqual(power.value as? String, "Off")
        XCTAssertEqual(gain.value as? String, (adjusted ?? "") + ", bypassed")
        power.tap(); XCTAssertEqual(gain.value as? String, adjusted)
        let gainGrip = app.otherElements["Reorder Output gain"]
        let studioGrip = app.otherElements["Reorder AI studio clarity"]
        XCTAssertTrue(gainGrip.exists, app.debugDescription)
        gainGrip.press(forDuration: 0.7, thenDragTo: studioGrip)
        expectation(for: NSPredicate(format: "value == 'Position 2'"), evaluatedWith: gainGrip); waitForExpectations(timeout: 5)
        XCTAssertEqual(gain.value as? String, adjusted, "Reordering preserves settings")
        app.buttons["Done"].tap(); app.buttons["Undo"].tap(); app.buttons["Audio filters"].tap()
        XCTAssertEqual(gainGrip.value as? String, "Position 4", "A drop creates one undo step")
        app.buttons["Done"].tap(); app.buttons["Redo"].tap(); app.buttons["Audio filters"].tap()
        XCTAssertEqual(gainGrip.value as? String, "Position 2")
        app.otherElements["Voice EQ gain"].tap()
        XCTAssertTrue(app.sliders["EQ frequency"].exists)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Four audio strips and EQ settings"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["Done"].tap(); app.terminate(); app.launchArguments = ["--editor-preview"]; app.launch()
        XCTAssertTrue(app.buttons["Audio filters"].waitForExistence(timeout: 20)); app.buttons["Audio filters"].tap()
        XCTAssertEqual(gainGrip.value as? String, "Position 2")
        XCTAssertEqual(gain.value as? String, adjusted)
    }

    func testFlipRemembersBothSides() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--recorder-controls-test"]; app.launch()
        let camera = app.buttons["recorder.camera"], flip = app.buttons["recorder.flip"]
        XCTAssertTrue(flip.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: flip); waitForExpectations(timeout: 5)
        XCTAssertLessThanOrEqual(flip.frame.maxX, camera.frame.minX)
        flip.tap(); XCTAssertEqual(camera.value as? String, "Front")
        camera.tap(); app.buttons["Front wide"].tap()
        flip.tap(); XCTAssertEqual(camera.value as? String, "Rear wide")
        camera.tap(); app.buttons["Rear telephoto"].tap()
        flip.tap(); XCTAssertEqual(camera.value as? String, "Front wide")
        flip.tap(); XCTAssertEqual(camera.value as? String, "Rear telephoto")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Recorder flip button"; shot.lifetime = .keepAlways; add(shot)
    }

    func testClearStartAndCompletedRange() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]; app.launch()
        let timeline = app.otherElements["editor.timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 20))
        let initialDuration = app.staticTexts["editor.duration"].label
        let clear = app.buttons["editor.clearSelection"]
        app.buttons["Mark start"].tap()
        XCTAssertTrue(clear.isHittable); XCTAssertTrue(clear.staticTexts["Clear"].exists)
        clear.tap(); XCTAssertTrue(app.buttons["Mark start"].exists); XCTAssertFalse(app.buttons["Undo"].isEnabled)
        app.buttons["Mark start"].tap()
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.7))
            .press(forDuration: 0.1, thenDragTo: timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.7)))
        app.buttons["Mark end"].tap()
        XCTAssertTrue(app.buttons["Delete range"].exists); XCTAssertTrue(clear.isHittable)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Clear selected range"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["Preview cut"].tap(); clear.tap()
        XCTAssertTrue(app.buttons["Mark start"].exists); XCTAssertFalse(app.buttons["Delete range"].exists)
        XCTAssertEqual(app.staticTexts["editor.duration"].label, initialDuration)
        XCTAssertFalse(app.buttons["Undo"].isEnabled); XCTAssertFalse(app.buttons["Redo"].isEnabled)
        XCTAssertTrue(app.buttons["Original"].isEnabled)
    }

    func testRecorderCameraMenuWithLiveReadings() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--recorder-controls-test"]; app.launch()
        let camera = app.buttons["recorder.camera"]
        XCTAssertTrue(camera.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: camera); waitForExpectations(timeout: 5)
        for name in ["Front", "Rear telephoto", "Rear wide", "Front"] {
            camera.tap()
            let option = app.buttons[name]
            XCTAssertTrue(option.waitForExistence(timeout: 5))
            option.tap()
            expectation(for: NSPredicate(format: "value == %@", name), evaluatedWith: camera); waitForExpectations(timeout: 5)
        }
    }

    func testRecorderTransitionMenuWithLiveReadings() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--recorder-controls-test"]; app.launch()
        XCTAssertTrue(app.buttons["recorder.settings"].waitForExistence(timeout: 10))
        openMoreCameraSettings(in: app)
        let transition = app.buttons["recorder.transition"]
        XCTAssertTrue(transition.waitForExistence(timeout: 5))
        for value in ["2 seconds", "5 seconds", "Instant", "3 seconds"] {
            transition.tap()
            let option = app.buttons[value]
            XCTAssertTrue(option.waitForExistence(timeout: 5)); option.tap()
            expectation(for: NSPredicate(format: "value == %@", value), evaluatedWith: transition); waitForExpectations(timeout: 5)
        }
        app.buttons["recorder.settingsDone"].tap(); app.terminate(); app.launch()
        openMoreCameraSettings(in: app)
        XCTAssertTrue(transition.waitForExistence(timeout: 5)); XCTAssertEqual(transition.value as? String, "3 seconds")
    }

    func testTakeMicrophoneSelectionAndPriorityAfterStop() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--recorder-controls-test"] // separate project store; real audio on device
        app.launch()
        let mic = app.buttons["recorder.microphone"], record = app.buttons["recorder.record"]
        let picker = app.buttons["recorder.gainMicrophone"]
        func waitFor(_ element: XCUIElement, _ predicate: NSPredicate) {
            expectation(for: predicate, evaluatedWith: element)
            waitForExpectations(timeout: 25)
        }
        func dismissAudioControls() {
            app.buttons["recorder.audioDone"].tap()
        }
        XCTAssertTrue(record.waitForExistence(timeout: 30))
        waitFor(record, NSPredicate(format: "enabled == true"))
        record.tap()
        waitFor(record, NSPredicate(format: "label == 'Stop recording'"))
        let initialInput = mic.value as? String
        mic.tap(); picker.tap()
        let choices = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'recorder.input.'"))
        XCTAssertTrue(choices.firstMatch.waitForExistence(timeout: 8))
        let names = choices.allElementsBoundByIndex.map(\.label)
        let highest = names[0], picked = names.count > 1 ? names[1] : highest
        print("Available microphone priority: " + names.joined(separator: ", ") + ". Selecting: " + picked)
        XCTAssertEqual(initialInput, highest)
        choices.matching(NSPredicate(format: "label == %@", picked)).firstMatch.tap()
        waitFor(picker, NSPredicate(format: "label CONTAINS %@", picked))
        dismissAudioControls()
        app.buttons["Pause recording"].tap()
        waitFor(record, NSPredicate(format: "label == 'Resume recording'"))
        XCTAssertEqual(mic.value as? String, picked)
        record.tap()
        waitFor(record, NSPredicate(format: "label == 'Stop recording'"))
        XCTAssertEqual(mic.value as? String, picked)
        record.tap()
        waitFor(record, NSPredicate(format: "label == 'Record into this project' AND enabled == true"))
        waitFor(mic, NSPredicate(format: "value == %@", highest))
    }

    func testMicrophoneInlineNoticeAndInputNavigation() { checkMicrophonePanel(accessibilityText: false) }
    func testMicrophoneInlineNoticeAtLargeTextSize() { checkMicrophonePanel(accessibilityText: true) }

    private func dragRecordingGainToZero(_ slider: XCUIElement, fromUpperEnd: Bool) {
        let inset = slider.frame.height / 2
        let track = slider.frame.width - 2 * inset
        let origin = slider.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
        let start = origin.withOffset(CGVector(dx: fromUpperEnd ? slider.frame.width - inset : 1, dy: 0))
        let zero = origin.withOffset(CGVector(dx: inset + track * (40.0 / 52.0), dy: 0))
        start.press(forDuration: 0.1, thenDragTo: zero, withVelocity: .slow, thenHoldForDuration: 0.1)
    }

    private func checkMicrophonePanel(accessibilityText: Bool) {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication(); app.launchArguments = ["--recorder-controls-test"]
        if accessibilityText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        let mic = app.buttons["recorder.microphone"]
        XCTAssertTrue(mic.waitForExistence(timeout: 15))
        for pose in [UIDeviceOrientation.portrait, .landscapeRight] {
            XCUIDevice.shared.orientation = pose
            expectation(for: NSPredicate { _, _ in (app.frame.width > app.frame.height) == pose.isLandscape }, evaluatedWith: app); waitForExpectations(timeout: 10)
            mic.tap()
            XCTAssertFalse(app.buttons["recorder.audioInfo"].exists)
            XCTAssertEqual(app.buttons["recorder.audioDone"].label.lowercased(), "close")
            let picker = app.buttons["recorder.gainMicrophone"]
            XCTAssertTrue(picker.waitForExistence(timeout: 5)); picker.tap()
            let chosen = pose == .portrait ? "Wireless test mic" : "Built-In Microphone"
            XCTAssertTrue(app.buttons[chosen].waitForExistence(timeout: 5)); app.buttons[chosen].tap()
            expectation(for: NSPredicate(format: "label CONTAINS %@", chosen), evaluatedWith: picker); waitForExpectations(timeout: 5)
            let bar = app.navigationBars["Microphone"], top = bar.frame.minY
            let notice = app.staticTexts["recorder.volumeNotice"]
            let content = app.descendants(matching: .any)["recorder.audioControls"].firstMatch
            XCTAssertFalse(app.buttons["recorder.gainReset"].exists)
            let gain = app.sliders["recorder.gain"]
            for _ in 0..<24 {
                if gain.exists && gain.isHittable { break }
                let viewport = content.frame.intersection(app.frame)
                let top = max(viewport.minY, bar.frame.maxY) + 8
                let bottom = viewport.maxY - 16
                let origin = app.coordinate(withNormalizedOffset: .zero)
                let start = origin.withOffset(CGVector(dx: viewport.midX, dy: top + (bottom - top) * 0.8))
                let end = origin.withOffset(CGVector(dx: viewport.midX, dy: top + (bottom - top) * 0.45))
                start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.15)
            }
            gain.adjust(toNormalizedSliderPosition: 1)
            XCTAssertTrue(app.staticTexts["recorder.gainValue"].label.contains("12"))
            dragRecordingGainToZero(gain, fromUpperEnd: true)
            XCTAssertTrue(app.staticTexts["recorder.gainValue"].label.replacingOccurrences(of: ",", with: ".").contains("+0.0"), "The gain slider snaps to zero from above: \(app.staticTexts["recorder.gainValue"].label), slider \(gain.value ?? "nil"), frame \(gain.frame)")
            gain.adjust(toNormalizedSliderPosition: 0)
            XCTAssertTrue(app.staticTexts["recorder.gainValue"].label.contains("−") || app.staticTexts["recorder.gainValue"].label.contains("-"))
            dragRecordingGainToZero(gain, fromUpperEnd: false)
            XCTAssertTrue(app.staticTexts["recorder.gainValue"].label.replacingOccurrences(of: ",", with: ".").contains("+0.0"), "The gain slider snaps to zero from below: \(app.staticTexts["recorder.gainValue"].label)")
            for _ in 0..<10 { if notice.exists && notice.isHittable { break }; content.swipeUp() }
            XCTAssertTrue(notice.isHittable)
            content.swipeUp()
            XCTAssertEqual(bar.frame.minY, top, accuracy: 3, "Scrolling volume controls must not expand the microphone panel")
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "Fixed microphone panel \(pose.rawValue), large text \(accessibilityText)"; shot.lifetime = .keepAlways; add(shot)
            app.buttons["recorder.audioDone"].tap()
            XCTAssertEqual(mic.value as? String, chosen)
        }
    }

    func testRecorderMicrophoneAndQualityMenusWithLiveReadings() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--recorder-controls-test"]; app.launch()
        let mic = app.buttons["recorder.microphone"]
        XCTAssertTrue(mic.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "value == 'Built-In Microphone'"), evaluatedWith: mic); waitForExpectations(timeout: 5)
        for name in ["Wireless test mic", "Built-In Microphone"] {
            mic.tap(); app.buttons["recorder.gainMicrophone"].tap()
            let option = app.buttons[name]
            XCTAssertTrue(option.waitForExistence(timeout: 5)); option.tap()
            app.buttons["recorder.audioDone"].tap()
            expectation(for: NSPredicate(format: "value == %@", name), evaluatedWith: mic); waitForExpectations(timeout: 5)
        }
        openMoreCameraSettings(in: app)
        let quality = app.buttons["recorder.quality"]
        for _ in 0..<5 { if quality.exists && quality.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(quality.isHittable)
        for name in ["4K · 30 fps", "1080p · 30 fps"] {
            quality.tap(); let option = app.buttons[name]
            XCTAssertTrue(option.waitForExistence(timeout: 5)); option.tap()
            expectation(for: NSPredicate(format: "value == %@", name), evaluatedWith: quality); waitForExpectations(timeout: 5)
        }
    }

    private func zoomTimePicker(in app: XCUIApplication) -> XCUIElement {
        let picker = app.descendants(matching: .any).matching(identifier: "recorder.transition").firstMatch
        for _ in 0..<6 {
            if picker.exists && picker.isHittable { break }
            app.swipeUp()
        }
        return picker
    }

    func testFrontTwoFingerPan() throws { try exerciseCameraPan(front: true, timed: true) }
    func testRearTwoFingerPan() throws { try exerciseCameraPan(front: false, timed: false) }
    func testZoomOutShowsLiveSurroundings() throws { try exerciseCameraPan(front: false, timed: true, lookWider: true) }
    func testFrontZoomOutShowsLiveSurroundings() throws { try exerciseCameraPan(front: true, timed: true, lookWider: true) }
    func testLandscapeZoomOutShowsLiveSurroundings() throws { try exerciseCameraPan(front: true, timed: true, lookWider: true, landscape: true) }

    private func exerciseCameraPan(front: Bool, timed: Bool, lookWider: Bool = false, landscape: Bool = false) throws {
        continueAfterFailure = false
        recorderReturnToPortrait = true
        XCUIDevice.shared.orientation = landscape ? .landscapeRight : .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--recorder-controls-test", "--probe-lens-controls", "-fitRecordedFrame", "YES",
                               "-zoomTransitionSeconds", timed ? "3" : "0", "-captureQuality", "hd1080", "-captureColorMode", "sdr"]
        let preview = app.otherElements["recorder.preview"]
        if ProcessInfo.processInfo.environment["YOUREC_PRELAUNCHED_PINCH_FIXTURE"] == "1" {
            app.activate()
            expectation(for: NSPredicate(format: "value CONTAINS 'format='"), evaluatedWith: preview)
            waitForExpectations(timeout: 16)
        } else { app.launch() }
        #if targetEnvironment(simulator)
        let name = front ? "Front" : "Rear wide"
        #else
        let name = front ? "Front main" : "Rear main"
        #endif
        let lens = app.buttons["recorder.camera"], zoom = app.buttons["recorder.zoom"], record = app.buttons["recorder.record"]
        XCTAssertTrue(lens.waitForExistence(timeout: 20))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: lens); waitForExpectations(timeout: 15)
        lens.tap(); app.buttons[name].firstMatch.tap()
        expectation(for: NSPredicate(format: "value == %@ AND enabled == true", name), evaluatedWith: lens); waitForExpectations(timeout: 15)
        zoom.tap()
        XCTAssertEqual(app.otherElements["recorder.zoom.duration"].value as? String, timed ? "3 seconds" : "Instant")
        for (key, value) in [("10","1.0"), ("20","2.0")] {
            let preset = app.descendants(matching: .any)["recorder.zoom.preset." + key].firstMatch
            if timed { preset.doubleTap() } else { preset.tap() }
            expectation(for: NSPredicate(format: "value == %@", value), evaluatedWith: zoom); waitForExpectations(timeout: 6)
        }
        zoom.tap()
        func shot(_ phase: String) {
            let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            image.name = "Pan " + name + " " + phase; image.lifetime = .keepAlways; add(image)
        }
        func center() -> CGPoint {
            let value = preview.value as? String ?? ""
            guard let coordinates = value.components(separatedBy: " pan=").dropFirst().first?.split(separator: " ").first else { return CGPoint(x: 0.5, y: 0.5) }
            let numbers = coordinates.split(separator: ",").compactMap { Double($0) }
            return numbers.count == 2 ? CGPoint(x: numbers[0], y: numbers[1]) : CGPoint(x: 0.5, y: 0.5)
        }
        shot("start"); print("Pan camera configuration", name, preview.frame, preview.value ?? "")
        record.tap()
        expectation(for: NSPredicate(format: "label == 'Stop recording'"), evaluatedWith: record); waitForExpectations(timeout: 15)
        let initial = center()
        let travel = preview.frame.width * 0.20
        // A slightly uneven parallel drag should still keep exactly 2×.
        let held = XCTestExpectation(description: "Capture the framing while both fingers are down")
        try twoFingerGesture(in: preview, dx: travel, dy: 0, scale: front ? 1.018 : 1, separation: CGVector(dx: 0, dy: 75),
                             centerFraction: CGPoint(x: 0.42, y: 0.46), hold: 1.25) {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.95) {
                shot("held"); held.fulfill()
            }
        }
        let released = Date(), first = center()
        if timed { Thread.sleep(forTimeInterval: max(0, 1.5 - Date().timeIntervalSince(released))) }
        let middle = center()
        if timed { Thread.sleep(forTimeInterval: max(0, 3.45 - Date().timeIntervalSince(released))) }
        let final = center(); shot("panned")
        XCTAssertEqual(zoom.value as? String, "2.0")
        try twoFingerGesture(in: preview, dx: -travel, dy: travel / 2, scale: 1.5,
                             separation: CGVector(dx: 92, dy: 0), centerFraction: CGPoint(x: 0.57, y: 0.43))
        if timed { Thread.sleep(forTimeInterval: 3.5) }
        let combined = center(), finalZoom = Double(zoom.value as? String ?? "") ?? 0; shot("combined")
        if lookWider {
            // The previous edit moved the recorded 3× crop off-center. The
            // capture output now has a genuinely wider sensor image to show.
            let heldWide = XCTestExpectation(description: "See outside the recording crop while composing")
            try twoFingerGesture(in: preview, dx: 0, dy: 0, scale: 0.55,
                                 separation: CGVector(dx: 160, dy: 0), hold: 1.5) {
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1.05) {
                    shot("wideHeld"); heldWide.fulfill()
                }
            }
            Thread.sleep(forTimeInterval: 3.5)
            wait(for: [heldWide], timeout: 5)
            shot("wider")
            XCTAssertLessThan(Double(zoom.value as? String ?? "") ?? 10, finalZoom - 0.7)
        }
        record.tap()
        expectation(for: NSPredicate(format: "label == 'Record into this project' AND enabled == true"), evaluatedWith: record)
        waitForExpectations(timeout: 25)
        wait(for: [held], timeout: 8)
        print("Pan centers in preview coordinates", name, initial, first, middle, final, combined, "zoom", finalZoom)
        XCTAssertEqual(final.x, initial.x - 0.1, accuracy: 0.025, "Dragging the picture right reveals the left side")
        XCTAssertEqual(final.y, initial.y, accuracy: 0.016)
        XCTAssertGreaterThan(combined.x, final.x + 0.045); XCTAssertLessThan(combined.y, final.y - 0.012)
        XCTAssertGreaterThan(finalZoom, 2.5)
        if timed {
            XCTAssertEqual(first.x, initial.x, accuracy: 0.018)
            XCTAssertLessThan(middle.x, first.x - 0.012); XCTAssertGreaterThan(middle.x, final.x + 0.012)
        } else { XCTAssertEqual(first.x, final.x, accuracy: 0.015) }
    }

    func testRearCameraPinchZoom() throws { try exerciseRecorderPinch(front: false) }
    func testFrontCameraPinchZoom() throws { try exerciseRecorderPinch(front: true) }
    func testTimedFrontPinchZoom() throws { try exerciseRecorderPinch(front: true, timed: true) }
    func testTimedRearPinchZoom() throws { try exerciseRecorderPinch(front: false, timed: true) }
    func testIdleNativeZoomOutShowsLiveFrame() throws { try exerciseRecorderPinch(front: false, timed: true, composeBeforeTake: true) }
    func testNativeZoomOutHoldsShotUntilRelease() throws { try exerciseRecorderPinch(front: false, timed: true, nativeStart: true) }

    func testPinchReturnsToOneX() throws { try checkReturnToOneX(seconds: 0) }
    func testTimedPinchReturnsToOneX() throws { try checkReturnToOneX(seconds: 1) }
    func testStabilizedTimedPinchReturnsToOneX() throws { try checkReturnToOneX(seconds: 1, stabilized: true) }
    func testHDRPinchReturnsToOneX() throws { try checkReturnToOneX(seconds: 0, hdr: true) }
    func testTimedHDRPinchReturnsToOneX() throws { try checkReturnToOneX(seconds: 1, hdr: true) }

    private func checkReturnToOneX(seconds: Int, hdr: Bool = false, stabilized: Bool = false) throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--recorder-controls-test", "--probe-lens-controls",
                               "-zoomTransitionSeconds", String(seconds), "-fitRecordedFrame", "YES",
                               "-captureQuality", hdr ? "ultraHD4K" : "hd1080", "-captureColorMode", hdr ? "hdr" : "sdr",
                               "-captureHDR", hdr ? "YES" : "NO",
                               "-dualFaceFollow", "NO", "-dualStabilization", stabilized ? "YES" : "NO"]
        app.launch()
        let lens = app.buttons["recorder.camera"], zoom = app.buttons["recorder.zoom"]
        let record = app.buttons["recorder.record"], preview = app.otherElements["recorder.preview"]
        XCTAssertTrue(lens.waitForExistence(timeout: 30))
        expectation(for: NSPredicate(format: "enabled == YES"), evaluatedWith: lens); waitForExpectations(timeout: 25)
        lens.tap()
        #if targetEnvironment(simulator)
        app.buttons["Rear wide"].tap()
        #else
        app.buttons["Rear main"].tap()
        #endif
        zoom.tap()
        app.descendants(matching: .any)["recorder.zoom.preset.10"].firstMatch.doubleTap()
        expectation(for: NSPredicate(format: "value == '1.0'"), evaluatedWith: zoom); waitForExpectations(timeout: 6)
        zoom.tap()
        useEmptyRecordingProject(in: app)
        record.tap()
        XCTAssertTrue(app.buttons["Stop recording"].waitForExistence(timeout: 12))
        func shot(_ title: String) {
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = title; attachment.lifetime = .keepAlways; add(attachment)
        }
        shot("One X before pinch")
        var landed: [Double] = []
        for offset: CGFloat in [0, 0.13] {
            let center = CGPoint(x: 0.5 + offset, y: 0.5)
            try twoFingerGesture(in: preview, dx: 0, dy: 0, scale: 2.2,
                                 separation: CGVector(dx: 110, dy: 0), centerFraction: center)
            expectation(for: NSPredicate { _, _ in (Double(zoom.value as? String ?? "") ?? 0) >= 2 },
                        evaluatedWith: zoom); waitForExpectations(timeout: 8)
            Thread.sleep(forTimeInterval: 0.5)
            try twoFingerGesture(in: preview, dx: 0, dy: 0, scale: 0.34,
                                 separation: CGVector(dx: 200, dy: 0), centerFraction: center,
                                 releaseScale: 0.38)
            Thread.sleep(forTimeInterval: Double(seconds) + 0.5)
            landed.append(try XCTUnwrap(Double(zoom.value as? String ?? "")))
            shot(offset == 0 ? "One X after centered pinch" : "One X after off-center pinch")
        }
        record.tap()
        expectation(for: NSPredicate(format: "label == 'Record into this project' AND enabled == YES"), evaluatedWith: record)
        waitForExpectations(timeout: 20)
        XCTAssertEqual(landed, [1, 1], "Easing finger pressure below the lens minimum must keep the complete wide frame")
    }

    private func exerciseRecorderPinch(front: Bool, timed: Bool = false, composeBeforeTake: Bool = false, nativeStart: Bool = false) throws {
        continueAfterFailure = false
        recorderReturnToPortrait = true
        let landscape = !front && !timed
        XCUIDevice.shared.orientation = landscape ? .landscapeRight : .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--recorder-controls-test", "--probe-lens-controls", "-fitRecordedFrame", "YES",
                               "-zoomTransitionSeconds", timed ? "3" : "0"]
        if timed { app.launchArguments += ["-captureQuality", "hd1080", "-captureColorMode", "sdr", "-captureHDR", "NO"] }
        if ProcessInfo.processInfo.environment["YOUREC_PRELAUNCHED_PINCH_FIXTURE"] == "1" {
            app.activate()
            let probe = app.otherElements["recorder.preview"]
            expectation(for: NSPredicate(format: "value CONTAINS ' fitted='"), evaluatedWith: probe)
            waitForExpectations(timeout: 18)
        } else { app.launch() }
        let lens = app.buttons["recorder.camera"], zoom = app.buttons["recorder.zoom"]
        let preview = app.otherElements["recorder.preview"], record = app.buttons["recorder.record"]
        #if targetEnvironment(simulator)
        let name = front ? "Front" : "Rear wide"
        #else
        let name = front ? "Front main" : "Rear main"
        #endif
        func shot(_ phase: String) {
            let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            image.name = "Pinch " + name + " " + phase; image.lifetime = .keepAlways; add(image)
        }
        func currentZoom() -> Double { Double(zoom.value as? String ?? "") ?? -1 }
        XCTAssertTrue(lens.waitForExistence(timeout: 25))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: lens); waitForExpectations(timeout: 20)
        lens.tap(); app.buttons[name].firstMatch.tap()
        expectation(for: NSPredicate(format: "value == %@ AND enabled == true", name), evaluatedWith: lens)
        waitForExpectations(timeout: 20)
        let start = timed && !front ? 2.0 : 1.0
        zoom.tap()
        XCTAssertEqual(app.otherElements["recorder.zoom.duration"].value as? String, timed ? "3 seconds" : "Instant")
        if composeBeforeTake || nativeStart {
            app.descendants(matching: .any)["recorder.zoom.preset.10"].firstMatch.doubleTap()
            expectation(for: NSPredicate(format: "value == '1.0'"), evaluatedWith: zoom); waitForExpectations(timeout: 6)
        }
        let preset = app.descendants(matching: .any)[start == 2 ? "recorder.zoom.preset.20" : "recorder.zoom.preset.10"].firstMatch
        if timed { preset.doubleTap() } else { preset.tap() }
        expectation(for: NSPredicate(format: "value == %@", String(format: "%.1f", start)), evaluatedWith: zoom)
        waitForExpectations(timeout: 6)
        zoom.tap()
        print("Pinch camera configuration", name, "screen", preview.frame, preview.value ?? "")
        shot("start")
        #if !targetEnvironment(simulator)
        XCTAssertEqual(preview.frame.width / preview.frame.height, landscape ? 16.0 / 9 : 9.0 / 16, accuracy: 0.02,
                       "Fit the camera preview once, including before a take begins")
        #endif
        func startTake() {
            record.tap()
            expectation(for: NSPredicate(format: "label == 'Stop recording'"), evaluatedWith: record); waitForExpectations(timeout: 20)
        }
        if !composeBeforeTake { startTake() }
        // Keep both fingers in the uncovered part of the picture. Hold the target so
        // a ramp mistakenly started on change would already be visible at release.
        let heldPicture = XCTestExpectation(description: "Capture the on-screen framing while both fingers are down")
        try twoFingerGesture(in: preview, dx: 0, dy: 0, scale: start == 2 ? 0.58 : 1.95,
                             separation: CGVector(dx: 120, dy: 0), centerFraction: CGPoint(x: 0.5, y: nativeStart ? 0.5 : 0.45), hold: 1.3) {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.95) {
                shot("held")
                heldPicture.fulfill()
            }
        }
        let released = Date()
        let first = currentZoom()
        shot("released")
        if timed { Thread.sleep(forTimeInterval: max(0, 1.45 - Date().timeIntervalSince(released))) }
        let halfway = currentZoom()
        if timed { Thread.sleep(forTimeInterval: max(0, 3.45 - Date().timeIntervalSince(released))) }
        let reached = currentZoom()
        shot("settled")
        var wide: Double?
        if !timed {
            try twoFingerGesture(in: preview, dx: 0, dy: 0, scale: 0.53, separation: CGVector(dx: 150, dy: 0))
            shot("after pinch")
            wide = currentZoom()
        }
        if composeBeforeTake { startTake(); Thread.sleep(forTimeInterval: 1.0) }
        record.tap()
        expectation(for: NSPredicate(format: "label == 'Record into this project' AND enabled == true"), evaluatedWith: record)
        waitForExpectations(timeout: 25)
        wait(for: [heldPicture], timeout: 8)
        print("Pinch readings", name, "timed", timed, "start/release/middle/end", start, first, halfway, reached)
        let direction = start == 2 ? -1.0 : 1.0
        XCTAssertGreaterThan((reached - start) * direction, 0.25)
        if timed {
            XCTAssertEqual(first, start, accuracy: 0.2)
            XCTAssertGreaterThan((halfway - first) * direction, 0.05)
            XCTAssertGreaterThan((reached - halfway) * direction, 0.05)
        } else if let wide {
            XCTAssertLessThan(wide, reached - 0.2, "Pinching inward must widen the same lens")
        }
    }

    func testRecorderZoomDoubleTapOverride() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--recorder-controls-test"]; app.launch()
        XCTAssertTrue(app.buttons["recorder.settings"].waitForExistence(timeout: 10))
        openMoreCameraSettings(in: app)
        zoomTimePicker(in: app).tap(); app.buttons["5 seconds"].tap(); app.buttons["recorder.settingsDone"].tap()
        let zoom = app.buttons["recorder.zoom"]
        zoom.tap()
        let three = app.buttons["recorder.zoom.preset.30"]
        let duration = app.otherElements["recorder.zoom.duration"]
        three.doubleTap()
        expectation(for: NSPredicate(format: "value == '3.0'"), evaluatedWith: zoom); waitForExpectations(timeout: 2)
        XCTAssertEqual(duration.value as? String, "5 seconds", "The override does not change the saved duration")
        // A normal tap still uses the longer saved time.
        app.buttons["recorder.zoom.preset.10"].tap()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertNotEqual(zoom.value as? String, "1.0")
        expectation(for: NSPredicate(format: "value == '1.0'"), evaluatedWith: zoom); waitForExpectations(timeout: 6)
        // Instant is the dangerous case: the first tap must not jump before
        // the recognizer has decided whether this is a double tap.
        openMoreCameraSettings(in: app)
        zoomTimePicker(in: app).tap(); app.buttons["Instant"].tap(); app.buttons["recorder.settingsDone"].tap()
        three.doubleTap()
        XCTAssertNotEqual(zoom.value as? String, "3.0", "Double tapping an instant preset must still animate")
        expectation(for: NSPredicate(format: "value == '3.0'"), evaluatedWith: zoom); waitForExpectations(timeout: 2)
        XCTAssertEqual(duration.value as? String, "Instant")
    }

    func testSixToOneZoomPresets() throws { try exerciseSixToOneZoom(stabilized: false) }
    func testStabilizedSixToOneZoomPresets() throws { try exerciseSixToOneZoom(stabilized: true) }

    private func exerciseSixToOneZoom(stabilized: Bool) throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        let mode = ProcessInfo.processInfo.environment["YOUREC_PRESET_TEST_COLOR"] ?? "sdr"
        app.launchArguments = ["--recorder-controls-test", "--probe-lens-controls", "-zoomTransitionSeconds", "5",
                               "-captureQuality", mode == "hdr" ? "ultraHD4K" : "hd1080",
                               "-captureColorMode", mode, "-fitRecordedFrame", "YES",
                               "-dualFaceFollow", "NO", "-dualStabilization", stabilized ? "YES" : "NO"]
        app.launch()
        let lens = app.buttons["recorder.camera"], zoom = app.buttons["recorder.zoom"]
        let record = app.buttons["recorder.record"], preview = app.otherElements["recorder.preview"]
        let one = app.buttons["recorder.zoom.preset.10"], six = app.buttons["recorder.zoom.preset.60"]
        func waitForZoom(_ value: String, timeout: TimeInterval = 5) {
            expectation(for: NSPredicate(format: "value == %@", value), evaluatedWith: zoom)
            waitForExpectations(timeout: timeout)
        }
        XCTAssertTrue(lens.waitForExistence(timeout: 30))
        expectation(for: NSPredicate(format: "enabled == YES"), evaluatedWith: lens); waitForExpectations(timeout: 25)
        lens.tap()
        #if targetEnvironment(simulator)
        app.buttons["Rear wide"].tap()
        #else
        app.buttons["Rear main"].tap()
        expectation(for: NSPredicate(format: "value CONTAINS %@", "stabilized=\(stabilized)"), evaluatedWith: preview)
        waitForExpectations(timeout: 10)
        #endif
        zoom.tap(); one.doubleTap(); waitForZoom("1.0")
        XCTAssertEqual(app.otherElements["recorder.zoom.duration"].value as? String, "5 seconds")
        six.doubleTap(); waitForZoom("6.0")
        one.doubleTap(); waitForZoom("1.0")
        useEmptyRecordingProject(in: app); record.tap()
        XCTAssertTrue(app.buttons["Stop recording"].waitForExistence(timeout: 15))
        if !six.exists { zoom.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        for _ in 0..<2 {
            six.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap(); waitForZoom("6.0")
            Thread.sleep(forTimeInterval: 0.35)
            one.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap(); waitForZoom("1.0")
            Thread.sleep(forTimeInterval: 0.35)
        }
        // Reverse both an ordinary push-in and a compensated pull-out.
        six.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
        one.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap(); waitForZoom("1.0")
        six.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap(); waitForZoom("6.0")
        one.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
        six.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap(); waitForZoom("6.0")
        one.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap(); waitForZoom("1.0")
        if stabilized {
            // A single tap uses the user's five-second transition in the same take.
            six.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            waitForZoom("6.0", timeout: 8)
            Thread.sleep(forTimeInterval: 0.6)
            one.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            waitForZoom("1.0", timeout: 8)
            Thread.sleep(forTimeInterval: 0.6)
        }
        print("Preset recording geometry:", preview.value ?? "")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "Full frame after 6x preset"; shot.lifetime = .keepAlways; add(shot)
        record.tap()
        expectation(for: NSPredicate(format: "label == 'Record into this project' AND enabled == YES"), evaluatedWith: record)
        waitForExpectations(timeout: 25)
    }

    func testTapZoomDurationShowsTemporaryHint() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--recorder-controls-test"]
        app.launch()
        let zoom = app.buttons["recorder.zoom"]
        XCTAssertTrue(zoom.waitForExistence(timeout: 20))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: zoom)
        waitForExpectations(timeout: 20)
        zoom.tap()
        let duration = app.otherElements["recorder.zoom.duration"]
        let initialTime = duration.value as? String, initialZoom = zoom.value as? String
        let hint = app.staticTexts["Swipe up/down to change zoom time"]
        XCTAssertFalse(hint.exists)
        duration.tap()
        XCTAssertTrue(hint.waitForExistence(timeout: 2))
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "Zoom time tap hint"; shot.lifetime = .keepAlways; add(shot)
        XCTAssertTrue(hint.waitForNonExistence(timeout: 5))
        XCTAssertTrue(duration.isHittable)
        XCTAssertEqual(duration.value as? String, initialTime)
        XCTAssertEqual(zoom.value as? String, initialZoom)
    }

    func testRecorderZoomDurationSwipeAndPersistence() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--recorder-controls-test"]; app.launch()
        XCTAssertTrue(app.buttons["recorder.settings"].waitForExistence(timeout: 10))
        openMoreCameraSettings(in: app)
        zoomTimePicker(in: app).tap(); app.buttons["5 seconds"].tap(); app.buttons["recorder.settingsDone"].tap()
        app.buttons["recorder.zoom"].tap()
        let duration = app.otherElements["recorder.zoom.duration"]
        XCTAssertTrue(duration.isHittable)
        func drag(_ points: CGFloat) {
            let start = duration.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: points)))
        }
        drag(-57); XCTAssertEqual(duration.value as? String, "7 seconds")
        XCTAssertFalse(app.staticTexts["Swipe up/down to change zoom time"].exists)
        drag(57); XCTAssertEqual(duration.value as? String, "5 seconds")
        XCTAssertEqual(app.buttons["recorder.zoom"].value as? String, "1.0", "Adjusting time does not change framing")
        drag(-29); XCTAssertEqual(duration.value as? String, "6 seconds")
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["recorder.zoom"].waitForExistence(timeout: 10)); app.buttons["recorder.zoom"].tap()
        XCTAssertEqual(duration.value as? String, "6 seconds")
        openMoreCameraSettings(in: app)
        XCTAssertEqual(zoomTimePicker(in: app).value as? String, "6 seconds")
        zoomTimePicker(in: app).tap(); app.buttons["Instant"].tap(); app.buttons["recorder.settingsDone"].tap()
        XCTAssertTrue(duration.isHittable, "Zero duration stays adjustable")
        drag(29); XCTAssertEqual(duration.value as? String, "Instant")
        drag(-29); XCTAssertEqual(duration.value as? String, "1 second")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        expectation(for: NSPredicate { _, _ in app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height }, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(duration.isHittable)
        drag(-29); XCTAssertEqual(duration.value as? String, "2 seconds")
        XCTAssertTrue(app.buttons["recorder.zoom.preset.60"].isHittable)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Zoom presets and swipe duration landscape"; shot.lifetime = .keepAlways; add(shot)
    }

    func testFixedFocusAndPeakingFeedback() throws {
        #if targetEnvironment(simulator)
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--recorder-controls-test", "--fixed-focus-fixture"]; app.launch()
        let focus = app.descendants(matching: .any)["recorder.focus"].firstMatch
        XCTAssertTrue(focus.waitForExistence(timeout: 20))
        expectation(for: NSPredicate(format: "label == 'Fixed focus' AND enabled == true"), evaluatedWith: focus)
        waitForExpectations(timeout: 10)
        focus.tap()
        let hint = app.staticTexts["recorder.focusFeedback"]
        XCTAssertEqual(hint.label, "This lens has fixed focus")
        let before = (focus.value as? String)?.contains("Peaking on") == true
        focus.press(forDuration: 0.65)
        XCTAssertEqual(hint.label, before ? "Focus peaking off" : "Focus peaking on")
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: hint); waitForExpectations(timeout: 4)
        focus.press(forDuration: 0.65)
        #else
        throw XCTSkip("Fixed-lens simulator fixture")
        #endif
    }

    func testPhysicalLensControlsAndRecordingOutline() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires physical lens capabilities")
        #else
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--recorder-controls-test", "--probe-lens-controls"]
        app.launch()
        let lens = app.buttons["recorder.camera"], preview = app.otherElements["recorder.preview"]
        let focus = app.descendants(matching: .any)["recorder.focus"].firstMatch
        let rec = app.buttons["recorder.record"]
        func wait(_ control: XCUIElement, _ predicate: NSPredicate) {
            expectation(for: predicate, evaluatedWith: control); waitForExpectations(timeout: 20)
        }
        func select(_ name: String) {
            lens.tap(); app.buttons[name].firstMatch.tap()
            wait(lens, NSPredicate(format: "value == %@ AND enabled == true", name))
        }
        func shot(_ name: String) {
            let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); image.name = name
            image.lifetime = .keepAlways; add(image)
        }
        XCTAssertTrue(lens.waitForExistence(timeout: 25))
        wait(lens, NSPredicate(format: "enabled == true"))
        for name in ["Front main", "Rear ultrawide"] {
            select(name)
            print("Actual lens", name, preview.value ?? "", focus.label)
            preview.coordinate(withNormalizedOffset: CGVector(dx: 0.32, dy: 0.43)).tap()
            shot(name + " tap focus")
        }
        rec.tap(); wait(rec, NSPredicate(format: "label == 'Stop recording'"))
        shot("Ultra wide recording")
        app.buttons["recorder.zoom"].tap()
        app.descendants(matching: .any)["recorder.zoom.preset.10"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 2)
        print("After 1x", lens.value ?? "", preview.value ?? "")
        let chosen = lens.value as? String
        shot("After 1x while recording")
        rec.tap(); wait(rec, NSPredicate(format: "label == 'Record into this project'"))
        XCTAssertEqual(chosen, "Rear main")
        #endif
    }

    func testRecorderFocusPeakingManualSwipeAndAutofocusTarget() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--recorder-controls-test"]
        app.launch()
        let focus = app.descendants(matching: .any).matching(identifier: "recorder.focus").firstMatch
        XCTAssertTrue(focus.waitForExistence(timeout: 25))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: focus)
        waitForExpectations(timeout: 20)
        func peaking() -> Bool { (focus.value as? String)?.contains("Peaking on") == true }
        func lens() throws -> Int {
            let value = try XCTUnwrap(focus.value as? String)
            let number = value.split(separator: "%").first?.split(separator: " ").last
            return try XCTUnwrap(number.flatMap { Int($0) }, "Physical lens value in \(value)")
        }
        func shot(_ name: String) {
            let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            image.name = name; image.lifetime = .keepAlways; add(image)
        }
        let originalPeaking = peaking()
        if originalPeaking { focus.press(forDuration: 0.7) }
        if focus.label == "Manual focus" { focus.tap() }
        XCTAssertEqual(focus.label, "Autofocus")
        let preview = app.otherElements["recorder.preview"]
        #if !targetEnvironment(simulator)
        let target = preview.coordinate(withNormalizedOffset: CGVector(dx: 0.68, dy: 0.36))
        print("Focus marker screen point", target.screenPoint, "preview bounds", preview.frame)
        target.tap()
        shot("AF tap target")
        #endif
        focus.press(forDuration: 0.7)
        XCTAssertTrue(peaking()); XCTAssertEqual(focus.label, "Autofocus")
        focus.tap()
        XCTAssertEqual(focus.label, "Manual focus"); XCTAssertTrue(peaking())
        let initial = try lens()
        // Start near either end without trying to drive beyond the physical stop.
        let direction: CGFloat = initial > 55 ? 1 : -1
        let origin = focus.coordinate(withNormalizedOffset: CGVector(dx: 0.28, dy: 0.5))
        origin.press(forDuration: 0.65, thenDragTo: origin.withOffset(CGVector(dx: 0, dy: direction * 48)))
        let first = try lens()
        XCTAssertGreaterThan((first - initial) * (direction > 0 ? -1 : 1), 6)
        XCTAssertTrue(peaking(), "Holding before dragging must only move the lens")
        origin.press(forDuration: 0.08, thenDragTo: origin.withOffset(CGVector(dx: 0, dy: -direction * 25)))
        let second = try lens()
        XCTAssertGreaterThan((second - first) * (direction > 0 ? 1 : -1), 2)
        let record = app.buttons["recorder.record"]
        record.tap()
        expectation(for: NSPredicate(format: "label == 'Stop recording'"), evaluatedWith: record)
        waitForExpectations(timeout: 20)
        shot("Recording with peaking")
        focus.press(forDuration: 0.7)
        XCTAssertFalse(peaking()); XCTAssertEqual(focus.label, "Manual focus")
        shot("Recording without peaking")
        XCTAssertEqual(try lens(), second, accuracy: 2, "Toggling peaking preserves the lens position")
        origin.press(forDuration: 0.08, thenDragTo: origin.withOffset(CGVector(dx: 0, dy: direction * 30)))
        XCTAssertGreaterThan(((try lens()) - second) * (direction > 0 ? -1 : 1), 3, "The MF swipe also moves the lens during a take")
        focus.press(forDuration: 0.7)
        XCTAssertTrue(peaking())
        focus.tap()
        XCTAssertEqual(focus.label, "Autofocus"); XCTAssertTrue(peaking())
        #if !targetEnvironment(simulator)
        target.tap()
        shot("Recording AF target with peaking")
        #endif
        record.tap()
        app.terminate(); app.launch()
        XCTAssertTrue(focus.waitForExistence(timeout: 20))
        XCTAssertTrue(peaking(), "Peaking survives reopening the recorder")
        if !originalPeaking { focus.press(forDuration: 0.7) }
    }

    #if !targetEnvironment(simulator)
    func testFocusPeakingOverLiveEffectOnFrontCamera() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--recorder-controls-test"]
        app.launch()
        let focus = app.descendants(matching: .any).matching(identifier: "recorder.focus").firstMatch
        let flip = app.buttons["recorder.flip"]
        XCTAssertTrue(flip.waitForExistence(timeout: 25))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: flip)
        waitForExpectations(timeout: 20)
        let changedCamera = !(app.buttons["recorder.camera"].value as? String ?? "").hasPrefix("Front")
        if changedCamera { flip.tap() }
        expectation(for: NSPredicate(format: "value BEGINSWITH 'Front'"), evaluatedWith: app.buttons["recorder.camera"])
        waitForExpectations(timeout: 15)
        let originalPeaking = (focus.value as? String)?.contains("Peaking on") == true
        if originalPeaking { focus.press(forDuration: 0.7) }
        let effects = app.buttons["recorder.videoEffects"]
        effects.tap()
        if app.buttons["liveEffects.actions"].waitForExistence(timeout: 2) { throw XCTSkip("Preserve existing live effect stack") }
        openEffectSection("colorStyle", in: app, live: true)
        app.buttons["liveEffects.add.silentTint"].tap()
        dismissLiveEffects(in: app)
        func shot(_ name: String) {
            let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            image.name = name; image.lifetime = .keepAlways; add(image)
        }
        shot("Front effect without peaking")
        focus.press(forDuration: 0.7)
        XCTAssertTrue((focus.value as? String)?.contains("Peaking on") == true)
        shot("Front effect with peaking")
        let target = app.otherElements["recorder.preview"].coordinate(withNormalizedOffset: CGVector(dx: 0.32, dy: 0.39))
        print("Front effect target screen point", target.screenPoint)
        target.tap(); shot("Front effect AF target")
        if !originalPeaking { focus.press(forDuration: 0.7) }
        effects.tap()
        if !app.buttons["liveEffects.actions"].exists, app.navigationBars.buttons.matching(identifier: "BackButton").firstMatch.exists { backFromLiveEffects(in: app) }
        clearLiveEffects(in: app); dismissLiveEffects(in: app)
        if changedCamera { flip.tap() }
    }
    #endif

    func testRecorderZoomAndFocusReadingsStayLive() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--recorder-controls-test"]; app.launch()
        let camera = app.buttons["recorder.camera"]
        XCTAssertTrue(camera.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: camera); waitForExpectations(timeout: 5)
        openMoreCameraSettings(in: app)
        zoomTimePicker(in: app).tap(); app.buttons["2 seconds"].tap(); app.buttons["recorder.settingsDone"].tap()
        let zoom = app.buttons["recorder.zoom"]
        zoom.tap()
        let preset = app.buttons["recorder.zoom.preset.30"]
        preset.tap()
        expectation(for: NSPredicate(format: "value == '3.0'"), evaluatedWith: zoom); waitForExpectations(timeout: 5)
        XCTAssertTrue(preset.isSelected)
        camera.tap(); app.buttons["Front"].tap()
        XCTAssertEqual(zoom.value as? String, "1.0"); XCTAssertFalse(preset.isSelected)
        camera.tap(); app.buttons["Rear wide"].tap()
        XCTAssertEqual(zoom.value as? String, "3.0"); XCTAssertTrue(preset.isSelected)
        let focus = app.descendants(matching: .any).matching(identifier: "recorder.focus").firstMatch
        XCTAssertEqual(focus.value as? String, "Auto")
        focus.tap(); XCTAssertEqual(focus.label, "Manual focus")
        focus.tap(); XCTAssertEqual(focus.value as? String, "Auto")
    }

    func testAudioComparisonFromEditorWhilePlaying() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]; app.launch()
        XCTAssertTrue(app.buttons["Audio filters"].waitForExistence(timeout: 20))
        app.buttons["Audio filters"].tap(); app.buttons["Add filter"].tap(); app.buttons["Low-cut filter"].tap()
        app.buttons["Apply & listen"].tap()
        XCTAssertTrue(app.buttons["Applied"].waitForExistence(timeout: 30))
        app.buttons["Done"].tap(); app.buttons["Play"].tap()
        for mode in ["original", "processed", "original"] {
            let choice = app.buttons["editor." + mode]
            choice.tap()
            expectation(for: NSPredicate(format: "value == 'Selected'"), evaluatedWith: choice); waitForExpectations(timeout: 5)
            XCTAssertTrue(app.buttons["Pause playback"].waitForExistence(timeout: 5))
        }
    }

    func testVoiceIsolationModelPersistence() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]
        app.launch()
        XCTAssertTrue(app.otherElements["editor.timeline"].waitForExistence(timeout: 20))
        app.buttons["Audio filters"].tap(); app.buttons["Add filter"].tap(); app.buttons["AI voice isolation"].tap()
        let model = app.buttons["Noise reduction model"]
        XCTAssertTrue(model.waitForExistence(timeout: 5)); XCTAssertEqual(model.value as? String, "RNNoise")
        model.tap(); app.buttons["DeepFilterNet3"].tap()
        XCTAssertEqual(model.value as? String, "DeepFilterNet3")
        XCTAssertTrue(app.otherElements["AI voice isolation amount"].isHittable)
        app.buttons["audio.processed"].tap()
        XCTAssertTrue(app.buttons["Applied"].waitForExistence(timeout: 90))
        XCTAssertEqual(app.buttons["audio.processed"].value as? String, "Selected")
        app.buttons["Play audio preview"].tap(); app.buttons["audio.original"].tap()
        XCTAssertTrue(app.buttons["Pause audio preview"].waitForExistence(timeout: 5))
        app.buttons["audio.processed"].tap()
        XCTAssertTrue(app.buttons["Pause audio preview"].exists)
        app.buttons["Pause audio preview"].tap(); app.buttons["Done"].tap()
        app.terminate(); app.launchArguments = ["--editor-preview"]; app.launch()
        XCTAssertTrue(app.buttons["Audio filters"].waitForExistence(timeout: 20))
        app.buttons["Audio filters"].tap()
        XCTAssertTrue(model.waitForExistence(timeout: 5)); XCTAssertEqual(model.value as? String, "DeepFilterNet3")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Offline voice model choice"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["Done"].tap(); app.buttons["Undo"].tap()
        app.buttons["Audio filters"].tap(); XCTAssertEqual(model.value as? String, "RNNoise")
        app.buttons["Done"].tap(); app.buttons["Redo"].tap()
        app.buttons["Audio filters"].tap(); XCTAssertEqual(model.value as? String, "DeepFilterNet3")
    }

    func testCutWhileAudioIsProcessing() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--slow-audio-preview"]
        app.launch()
        let timeline = app.otherElements["editor.timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 20))
        app.buttons["Audio filters"].tap(); app.buttons["Add filter"].tap(); app.buttons["Low-cut filter"].tap()
        app.buttons["Apply & listen"].tap(); app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Mark start"].isEnabled)
        app.buttons["Mark start"].tap()
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.7)).press(forDuration: 0.1, thenDragTo: timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.7)))
        app.buttons["Mark end"].tap(); app.buttons["Delete range"].tap()
        let edited = app.staticTexts["editor.duration"].label
        XCTAssertNotEqual(edited, "0:18.00")
        expectation(for: NSPredicate(format: "value == 'Selected'"), evaluatedWith: app.buttons["editor.processed"]); waitForExpectations(timeout: 30)
        XCTAssertEqual(app.staticTexts["editor.duration"].label, edited, "Processing does not restore an old edit")
        let seconds = edited.split(separator: ":").last.map(String.init) ?? ""
        let correctPreview = NSPredicate { _, _ in (app.otherElements["editor.preview"].value as? String ?? "").contains(seconds + " seconds") }
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: correctPreview, object: app)], timeout: 10)
        XCTAssertEqual(result, .completed, "Expected preview duration \(edited); actual preview: \(app.otherElements["editor.preview"].value ?? "missing")")
        XCTAssertTrue(app.buttons["Undo"].isEnabled)
    }

    #if !targetEnvironment(simulator)
    func testSidewaysCaptureFitsPortraitPreview() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--recorder-controls-test", "--framing-locked-sideways"]
        app.launch()
        let preview = app.otherElements["recorder.preview"], record = app.buttons["recorder.record"]
        XCTAssertTrue(record.waitForExistence(timeout: 30))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: record)
        waitForExpectations(timeout: 30)
        XCTAssertTrue(preview.waitForExistence(timeout: 8))
        func checkFrame(_ name: String) {
            XCTAssertGreaterThan(preview.frame.height, preview.frame.width * 1.4)
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = name; shot.lifetime = .keepAlways; add(shot)
        }
        checkFrame("Sideways sensor in portrait window – preview")
        record.tap()
        expectation(for: NSPredicate(format: "label == 'Stop recording'"), evaluatedWith: record)
        waitForExpectations(timeout: 20)
        checkFrame("Sideways sensor in portrait window – recording")
        record.tap()
        XCTAssertTrue(app.buttons["recorder.settings"].waitForExistence(timeout: 15))
    }
    #endif

    func testRecordingAlertProtectionControl() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--recorder-controls-test"]
        app.launch()
        let protection = app.switches["recorder.protectAudio"]
        func open() {
            openMoreCameraSettings(in: app)
            for _ in 0..<8 {
                if protection.exists, protection.isHittable,
                   protection.frame.midY < app.frame.maxY - 90 { break }
                app.swipeUp()
            }
            XCTAssertTrue(protection.isEnabled)
        }
        func toggle(to value: String) {
            protection.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
            expectation(for: NSPredicate(format: "value == %@", value), evaluatedWith: protection)
            waitForExpectations(timeout: 5)
        }
        open()
        let original = protection.value as? String ?? "0", changed = original == "0" ? "1" : "0"
        toggle(to: changed)
        app.buttons["recorder.settingsDone"].tap(); open()
        XCTAssertEqual(protection.value as? String, changed)
        toggle(to: original)
        app.buttons["recorder.settingsDone"].tap()
    }

    func testDeletingPortraitTakeChangesPreviewAndExportToLandscape() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["YOUREC_EDITOR_FIXTURE_TITLE"] = "Mixed camera orientations · UI test"
        app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--mixed-canvas-fixture"]
        app.launch()
        func ready() {
            let play = app.buttons["Play"]
            XCTAssertTrue(play.waitForExistence(timeout: 30))
            expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play)
            waitForExpectations(timeout: 30)
        }
        func checkFormat(portrait: Bool, export: Bool = false) throws {
            ready()
            seekTimeline(fraction: 0.27, in: app)
            expectation(for: NSPredicate(format: "value BEGINSWITH 'Frame visible'"), evaluatedWith: app.otherElements["editor.preview"])
            waitForExpectations(timeout: 10)
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = portrait ? "Portrait editor" : "Landscape editor"; shot.lifetime = .keepAlways; add(shot)
            app.buttons["Export"].tap()
            let settings = app.buttons["export.settings"]
            XCTAssertTrue(settings.waitForExistence(timeout: 10))
            let summary = try XCTUnwrap(settings.value as? String)
            let dimensions = summary.components(separatedBy: " · ")[0].components(separatedBy: " × ").compactMap(Int.init)
            XCTAssertEqual(dimensions.count, 2)
            XCTAssertEqual(dimensions[0] < dimensions[1], portrait, summary)
            if export {
                if app.buttons["Export video"].exists { app.buttons["Export video"].tap() }
                XCTAssertTrue(app.buttons["Share latest export"].waitForExistence(timeout: 90))
            }
            app.buttons["Done"].tap()
        }
        try checkFormat(portrait: true)
        app.buttons["Timeline view span"].tap(); app.buttons["Whole project"].tap()
        app.buttons["timeline.video.1"].tap(); app.buttons["Delete selection"].tap()
        try checkFormat(portrait: false)
        app.buttons["Undo"].tap(); try checkFormat(portrait: true)
        app.buttons["Redo"].tap(); try checkFormat(portrait: false)
        app.terminate(); app.launchArguments = ["--editor-preview"]; app.launch()
        try checkFormat(portrait: false, export: true)
        // Choosing the ratio already shown is a deliberate fixed format.
        app.buttons["Undo"].tap(); ready()
        app.buttons["timeline.video.1"].tap()
        openTool("crop", in: app); waitForTool(app)
        app.buttons["crop.shape"].tap(); app.buttons["9:16"].tap(); app.buttons["tool.apply"].tap()
        ready()
        if !app.buttons["Delete selection"].exists { app.buttons["timeline.video.1"].tap() }
        app.buttons["Delete selection"].tap()
        try checkFormat(portrait: true)
        openTool("crop", in: app); waitForTool(app)
        app.buttons["crop.shape"].tap(); app.collectionViews.buttons["Original"].tap()
        app.buttons["tool.apply"].tap(); try checkFormat(portrait: false)

    }

    func testExportSettingsPersistAndNewFormatCanBeSaved() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview"]
        app.launchEnvironment["YOUREC_EDITOR_FIXTURE_TITLE"] = "Export formats · UI test"
        app.launch()
        let settings = app.buttons["export.settings"]
        func openExport() {
            XCTAssertTrue(app.buttons["Export"].waitForExistence(timeout: 25))
            app.buttons["Export"].tap()
            XCTAssertTrue(settings.waitForExistence(timeout: 8))
        }
        func choose(_ id: String, _ value: String) {
            app.buttons[id].tap()
            app.buttons[value].firstMatch.tap()
        }
        func exportAndSave() {
            let export = app.buttons["Export video"]
            if export.exists { export.tap() }
            let share = app.buttons["Share latest export"]
            XCTAssertTrue(share.waitForExistence(timeout: 120))
            let save = app.buttons["Save to Photos"]
            if save.exists {
                XCTAssertTrue(save.isHittable)
                save.tap()
                let permission = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
                if permission.waitForExistence(timeout: 2) {
                    let allow = permission.buttons.matching(NSPredicate(format: "(label CONTAINS[c] 'Allow' AND NOT label CONTAINS[c] 'Don') OR label BEGINSWITH[c] 'Consenti'")).firstMatch
                    if allow.exists { allow.tap() }
                }
            }
            XCTAssertTrue(app.staticTexts["Saved to Photos"].waitForExistence(timeout: 20))
        }
        openExport()
        settings.tap()
        choose("export.rate", "30 fps")
        choose("export.resolution", "Project size")
        choose("export.codec", "H.264 · Compatibility")
        settings.tap()
        exportAndSave()
        settings.tap()
        choose("export.resolution", "720p")
        choose("export.rate", "60 fps")
        choose("export.codec", "H.265 · HEVC")
        XCTAssertTrue(app.buttons["Export video"].isHittable)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "Export settings"; shot.lifetime = .keepAlways; add(shot)
        app.terminate()
        app.launch()
        openExport()
        XCTAssertTrue((settings.value as? String)?.contains("60 fps · H.265") == true)
        XCTAssertTrue(app.buttons["Export video"].isHittable)
        exportAndSave()
    }

    func testExportPausesAndResumesAfterReopening() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]
        app.launch()
        let export = app.buttons["Export"]
        XCTAssertTrue(export.waitForExistence(timeout: 25))
        // Make this export distinct from any earlier fixture result.
        seekTimeline(fraction: 0.45, in: app)
        app.buttons["Split"].tap()
        export.tap()
        // Ensure the job is still running when XCTest finishes its tap and presses Home.
        app.buttons["export.settings"].tap()
        app.buttons["export.resolution"].tap()
        app.buttons["4K"].tap()
        app.buttons["Export video"].tap()
        XCUIDevice.shared.press(.home)
        app.activate()
        let resume = app.buttons["Resume export"]
        XCTAssertTrue(resume.waitForExistence(timeout: 20))
        XCTAssertFalse(app.alerts["Editor"].exists)
        app.terminate()
        app.launchArguments = ["--editor-preview"]
        app.launch()
        XCTAssertTrue(resume.waitForExistence(timeout: 25))
        resume.tap()
        let progress = app.progressIndicators["export.progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 8))
        XCTAssertFalse(progress.label.isEmpty)
        XCTAssertTrue((progress.value as? String)?.contains("%") == true)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "One export bar with the current operation and overall percentage"
        shot.lifetime = .keepAlways; add(shot)
        XCTAssertTrue(app.buttons["Share latest export"].waitForExistence(timeout: 120))
        XCTAssertTrue(app.buttons["Save to Photos"].isHittable)
        XCTAssertFalse(resume.exists)
    }

    func testScrubAtSelectedEdgeRequiresHoldToTrim() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]
        app.launch()
        let span = app.buttons["Timeline view span"]
        XCTAssertTrue(span.waitForExistence(timeout: 25)); span.tap(); app.buttons["Whole project"].tap()
        let card = app.buttons["timeline.video.1"]
        XCTAssertTrue(card.waitForExistence(timeout: 10)); card.tap()
        let duration = app.staticTexts["editor.duration"]
        let original = duration.label
        let edge = card.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        let middle = card.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5))
        edge.press(forDuration: 0.04, thenDragTo: middle)
        XCTAssertEqual(duration.label, original)
        XCTAssertNotEqual(app.staticTexts["editor.playhead"].label, "0:00.00")
        edge.press(forDuration: 0.65, thenDragTo: middle)
        expectation(for: NSPredicate(format: "label != %@", original), evaluatedWith: duration)
        waitForExpectations(timeout: 6)
        app.buttons["Undo"].tap()
        XCTAssertEqual(duration.label, original)
    }

    func testCompletionChimeArrivesWithShareAndSave() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--observe-export-chime"]
        let stagedProject = ProcessInfo.processInfo.environment["YOUREC_LONG_EXPORT_TEST_PROJECT"]
        if let stagedProject {
            app.launchEnvironment["YOUREC_EDITOR_FIXTURE_TITLE"] = stagedProject
        } else {
            app.launchEnvironment["YOUREC_RECOVERY_TEST_RUN"] = UUID().uuidString
        }
        app.launch()
        let export = app.buttons["Export"]
        let resume = app.buttons["Resume export"]
        if stagedProject == nil || !resume.waitForExistence(timeout: 4) {
            XCTAssertTrue(export.waitForExistence(timeout: 60))
            export.tap()
        }
        let chimeName = "com.antirez.yourec.tests.exportChime"
        let chime = XCTDarwinNotificationExpectation(notificationName: chimeName)
        (resume.exists ? resume : app.buttons["Export video"]).tap()
        let progress = app.progressIndicators["export.progress"]
        if stagedProject != nil {
            XCTAssertTrue(progress.waitForExistence(timeout: 10))
            XCTAssertNotEqual(progress.value as? String, "100%")
        }
        wait(for: [chime], timeout: stagedProject == nil ? 120 : 1800)
        XCTAssertFalse(progress.exists)
        XCTAssertTrue(app.buttons["Share latest export"].isHittable)
        XCTAssertTrue(app.buttons["Save to Photos"].isHittable)
        let duplicate = XCTDarwinNotificationExpectation(notificationName: chimeName)
        duplicate.isInverted = true
        app.buttons["Done"].tap()
        export.tap()
        XCTAssertTrue(app.buttons["Share latest export"].isHittable)
        wait(for: [duplicate], timeout: 1)
    }

    func testExportToPhotos() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]
        app.launch()
        XCTAssertTrue(app.otherElements["editor.timeline"].waitForExistence(timeout: 20))
        app.buttons["Export"].tap()
        let export = app.buttons["Export video"]
        if export.waitForExistence(timeout: 2) { export.tap() }
        XCTAssertTrue(app.buttons["Share latest export"].waitForExistence(timeout: 60))
        XCTAssertFalse(app.buttons["Export video"].exists, "An unchanged exported edit cannot be exported accidentally again")
        for title in ["Share latest export","Save to Photos","Done"] {
            let button=app.buttons[title]
            XCTAssertTrue(button.isHittable,"Completed export actions must be reachable without scrolling: \(title)")
            XCTAssertTrue(app.windows.firstMatch.frame.contains(button.frame),"Export action must be fully visible: \(title)")
        }
        let shot=XCTAttachment(screenshot:XCUIScreen.main.screenshot());shot.name="Export actions visible in portrait";shot.lifetime = .keepAlways;add(shot)
        app.buttons["Done"].tap();app.buttons["Export"].tap()
        for title in ["Share latest export","Save to Photos"] {
            XCTAssertTrue(app.buttons[title].isHittable,"Reopening a completed export exposes its actions without scrolling")
            XCTAssertTrue(app.windows.firstMatch.frame.contains(app.buttons[title].frame))
        }
        app.buttons["Save to Photos"].tap()
        // A fresh physical-device install can show the add-only Photos prompt.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let permission = springboard.alerts.firstMatch
        if permission.waitForExistence(timeout: 2) {
            let allow = permission.buttons.matching(NSPredicate(format: "(label CONTAINS[c] 'Allow' AND NOT label CONTAINS[c] 'Don') OR label BEGINSWITH[c] 'Consenti'")).firstMatch
            if allow.exists { allow.tap() }
        }
        XCTAssertTrue(app.staticTexts["Saved to Photos"].waitForExistence(timeout: 15))
        XCUIDevice.shared.orientation = .landscapeLeft
        expectation(for:NSPredicate {_,_ in app.frame.width > app.frame.height},evaluatedWith:app);waitForExpectations(timeout:10)
        for title in ["Share latest export","Done"] {
            XCTAssertTrue(app.windows.firstMatch.frame.contains(app.buttons[title].frame),"Export actions stay visible in landscape: \(title)")
        }
        XCTAssertTrue(app.windows.firstMatch.frame.contains(app.staticTexts["Saved to Photos"].frame))
        XCTAssertTrue(app.buttons["Share latest export"].isHittable)
        let wideShot=XCTAttachment(screenshot:XCUIScreen.main.screenshot());wideShot.name="Export actions visible in landscape";wideShot.lifetime = .keepAlways;add(wideShot)
        XCUIDevice.shared.orientation = .portrait
    }

    func testAudioWarningBelongsToExport() throws {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--export-audio-warning-fixture"]; app.launch()
        let play = app.buttons["Play"], warning = app.staticTexts["Audio may distort"], dismiss = app.buttons["export.dismissAudioWarning"]
        func ready() {
            XCTAssertTrue(play.waitForExistence(timeout: 30))
            expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 30)
        }
        func exported() {
            app.buttons["Export"].tap()
            let start = app.buttons["Export video"]
            if start.waitForExistence(timeout: 2) { start.tap() }
            XCTAssertTrue(app.buttons["Share latest export"].waitForExistence(timeout: 60))
        }
        ready(); XCTAssertFalse(warning.exists); exported()
        XCTAssertTrue(warning.waitForExistence(timeout: 5))
        XCTAssertTrue(dismiss.exists, app.buttons.debugDescription)
        for pose in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = pose
            expectation(for: NSPredicate { _,_ in (pose == .portrait) == (app.frame.height > app.frame.width) }, evaluatedWith: app); waitForExpectations(timeout: 10)
            for title in ["Share latest export", "Save to Photos", "Done", "export.dismissAudioWarning"] {
                XCTAssertTrue(app.buttons[title].isHittable, "Warning cannot hide the export actions")
                XCTAssertTrue(app.frame.contains(app.buttons[title].frame))
            }
            XCTAssertTrue(app.frame.contains(warning.frame))
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Export audio warning \(pose.rawValue)"; shot.lifetime = .keepAlways; add(shot)
        }
        app.buttons["Done"].tap(); ready()
        XCTAssertFalse(warning.exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Audio clips.'")).firstMatch.exists)
        app.buttons["Export"].tap(); XCTAssertTrue(warning.waitForExistence(timeout: 5))
        dismiss.tap(); XCTAssertFalse(warning.exists)
        app.buttons["Done"].tap(); app.buttons["Export"].tap(); XCTAssertFalse(warning.exists, "Dismissal belongs to this export")
        app.buttons["Done"].tap(); XCUIDevice.shared.orientation = .portrait; ready()
        app.buttons["audio.quickGain"].tap()
        let slider = app.sliders["audio.gainSlider"]
        XCTAssertTrue(slider.waitForExistence(timeout: 10)); slider.adjust(toNormalizedSliderPosition: 0.15)
        app.buttons["Apply"].tap(); ready()
        // The old file's warning must not describe a different edited mix.
        app.buttons["Export"].tap(); XCTAssertFalse(warning.exists)
        app.buttons["Export video"].tap()
        XCTAssertTrue(app.buttons["Share latest export"].waitForExistence(timeout: 60))
        XCTAssertFalse(warning.exists, "Reduced final Volume clears the warning despite the loud cached enhancement")
        XCTAssertTrue(app.buttons["Save to Photos"].isHittable)
        app.buttons["Done"].tap(); ready(); app.buttons["Undo"].tap(); ready(); exported()
        XCTAssertTrue(warning.waitForExistence(timeout: 5), "Dismissing an old export cannot hide a newly measured overload")
        app.buttons["Done"].tap(); ready(); XCTAssertFalse(warning.exists)
    }

    func testReexportCanSaveToPhotos() throws {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--multiselect-fixture"]; app.launch()
        let play = app.buttons["Play"]
        func ready() {
            XCTAssertTrue(play.waitForExistence(timeout:30))
            expectation(for:NSPredicate(format:"enabled == true"),evaluatedWith:play); waitForExpectations(timeout:30)
        }
        func exportAndSave(_ title:String) {
            app.buttons["Export"].tap()
            XCTAssertTrue(app.buttons["Export video"].waitForExistence(timeout:5))
            XCTAssertFalse(app.staticTexts["Saved to Photos"].exists,"A stale export's confirmation is not shown for unexported edits")
            app.buttons["Export video"].tap()
            XCTAssertTrue(app.staticTexts["Exported"].waitForExistence(timeout:60))
            let save = app.buttons["Save to Photos"]
            XCTAssertTrue(save.isHittable,"Every new export can be saved to Photos")
            XCTAssertFalse(app.staticTexts["Saved to Photos"].exists,"An earlier export's save status cannot hide the new save action")
            let shot = XCTAttachment(screenshot:XCUIScreen.main.screenshot()); shot.name = title; shot.lifetime = .keepAlways; add(shot)
            save.tap()
            let permission = XCUIApplication(bundleIdentifier:"com.apple.springboard").alerts.firstMatch
            if permission.waitForExistence(timeout:2) {
                let allow = permission.buttons.matching(NSPredicate(format:"(label CONTAINS[c] 'Allow' AND NOT label CONTAINS[c] 'Don') OR label BEGINSWITH[c] 'Consenti'")).firstMatch
                if allow.exists { allow.tap() }
            }
            XCTAssertTrue(app.staticTexts["Saved to Photos"].waitForExistence(timeout:20))
            app.buttons["Done"].tap()
        }
        ready(); exportAndSave("First export ready to save")
        ready(); app.buttons["Timeline view span"].tap(); app.buttons["Whole project"].tap()
        app.buttons["timeline.video.3"].tap(); app.buttons["Delete selection"].tap(); ready()
        XCTAssertEqual(app.staticTexts["editor.duration"].label,"0:12.00")
        exportAndSave("Edited export ready to save")
        app.buttons["Export"].tap()
        XCTAssertTrue(app.staticTexts["Saved to Photos"].waitForExistence(timeout:5))
        XCTAssertFalse(app.buttons["Earlier exports"].exists)
        app.buttons["Done"].tap()
        app.buttons["Undo"].tap(); ready()
        XCTAssertEqual(app.staticTexts["editor.duration"].label,"0:18.00")
        XCUIDevice.shared.orientation = .landscapeLeft
        expectation(for:NSPredicate {_,_ in app.frame.width>app.frame.height},evaluatedWith:app); waitForExpectations(timeout:10)
        exportAndSave("Third export ready to save in landscape")
    }

    func testExpiredProjectsPromptCancelReviewDelete() throws {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--retention-ui-fixture", "--reset-retention-fixture"]
        app.launch()
        let prompt = app.alerts["Delete older projects?"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 15))
        XCTAssertTrue(prompt.buttons["Delete 1 project"].exists)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "Expired projects confirmation"; shot.lifetime = .keepAlways; add(shot)
        prompt.buttons["Not now"].tap()
        let deleted = app.buttons["Recently deleted (3)"]
        XCTAssertTrue(deleted.waitForExistence(timeout: 5)); deleted.tap()
        XCTAssertTrue(app.buttons["Restore Old deleted project"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Restore Recent deleted project"].exists)
        XCTAssertTrue(app.buttons["Restore Unknown deletion date"].exists)
        app.buttons["Done"].tap()
        XCTAssertFalse(prompt.exists, "Dismissing Recently deleted does not reopen the cleanup prompt")
        app.buttons.matching(identifier: "Edit").firstMatch.tap()
        let back = app.buttons["Back to projects"]
        XCTAssertTrue(back.waitForExistence(timeout: 10)); back.tap()
        XCTAssertTrue(prompt.waitForExistence(timeout: 10)); prompt.buttons["Review"].tap()
        XCTAssertTrue(app.buttons["Restore Old deleted project"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        app.terminate(); app.launchArguments = ["--retention-ui-fixture"]; app.launch()
        XCTAssertTrue(prompt.waitForExistence(timeout: 15)); prompt.buttons["Delete 1 project"].tap()
        XCTAssertTrue(app.buttons["Recently deleted (2)"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Actions for Active project"].exists)
        app.buttons["Recently deleted (2)"].tap()
        XCTAssertFalse(app.buttons["Restore Old deleted project"].exists)
        XCTAssertTrue(app.buttons["Restore Recent deleted project"].exists)
        XCTAssertTrue(app.buttons["Restore Unknown deletion date"].exists)
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["Actions for Active project"].waitForExistence(timeout: 15))
        XCTAssertFalse(prompt.exists, "No prompt when only recent or untracked deletions remain")
    }

    func testExpiredProjectsWithUnreadableDate() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--retention-ui-fixture", "--reset-retention-fixture", "--retention-corrupt-fixture"]
        app.launch()
        let prompt = app.alerts["Delete older projects?"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 15))
        XCTAssertTrue(prompt.buttons["Delete 2 projects"].exists)
        prompt.buttons["Delete 2 projects"].tap()
        let deleted = app.buttons["Recently deleted (3)"]
        XCTAssertTrue(deleted.waitForExistence(timeout: 5)); deleted.tap()
        XCTAssertTrue(app.buttons["Restore Unreadable deletion date"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Restore Old deleted project"].exists)
        XCTAssertFalse(app.buttons["Restore Second old deleted project"].exists)
        XCTAssertTrue(app.staticTexts["Deletion date unavailable · excluded from bulk cleanup"].exists)
        XCTAssertFalse(app.alerts["YouRec"].exists)
    }

    private func coverDimensions(_ app: XCUIApplication) -> [Int] {
        let description = app.images["cover.image"].value as? String ?? ""
        return description.components(separatedBy: "×").compactMap { Int($0.filter(\.isNumber)) }
    }

    func testSelectCoverSharesAnEditedFrameAndRespectsTheMarkedRange() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--frame-clock-fixture"]
        app.launchEnvironment["YOUREC_RECOVERY_TEST_RUN"] = UUID().uuidString
        app.launch()
        let tools = app.buttons["Tools"], selector = app.buttons["tools.cover"]
        let update = app.buttons["cover.update"]
        let frames = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'cover.frame.'"))
        func open() {
            XCTAssertTrue(tools.waitForExistence(timeout: 30))
            tools.tap(); XCTAssertTrue(selector.waitForExistence(timeout: 10))
            expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: selector)
            waitForExpectations(timeout: 30)
            selector.tap(); XCTAssertTrue(frames.firstMatch.waitForExistence(timeout: 15))
        }
        func evidence(_ name: String) {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = name; shot.lifetime = .keepAlways; add(shot)
        }
        open()
        XCTAssertTrue(app.staticTexts["Whole project"].exists)
        let first = frames.firstMatch.label
        update.tap()
        XCTAssertNotEqual(frames.firstMatch.label, first)
        let candidate = frames.firstMatch.label
        evidence("Cover choices")
        frames.firstMatch.tap()
        let share = app.buttons["cover.share"]
        XCTAssertTrue(share.waitForExistence(timeout: 25))
        XCTAssertEqual(coverDimensions(app), [720, 1280])
        let stamp = String(candidate.dropFirst("Frame at ".count))
        XCTAssertTrue(app.navigationBars[stamp].exists)
        evidence("Edited cover at " + stamp)
        share.tap()
        let activities = app.otherElements["ActivityListView"]
        XCTAssertTrue(activities.waitForExistence(timeout: 12))
        XCTAssertTrue(app.navigationBars.matching(NSPredicate(format: "identifier ENDSWITH '.jpg'")).firstMatch.exists)
        #if targetEnvironment(simulator)
        let save = activities.cells["Save Image"]
        XCTAssertTrue(save.isHittable)
        save.tap()
        #else
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.22)).tap()
        #endif
        let detailBack = app.navigationBars[stamp].buttons.firstMatch
        XCTAssertTrue(detailBack.waitForExistence(timeout: 10)); detailBack.tap()
        XCTAssertEqual(frames.firstMatch.label, candidate)
        app.navigationBars["Select cover"].buttons.firstMatch.tap()
        app.buttons["Done"].tap()
        seekTimeline(fraction: 0.24, in: app); app.buttons["Mark start"].tap()
        let start = app.staticTexts["editor.playhead"].label
        seekTimeline(fraction: 0.72, in: app); app.buttons["Mark end"].tap()
        let end = app.staticTexts["editor.playhead"].label
        open()
        XCTAssertTrue(app.staticTexts["Selected range"].exists)
        XCTAssertTrue(app.staticTexts[start + " – " + end].exists)
        for _ in 0..<2 {
            for button in frames.allElementsBoundByIndex {
                let time = String(button.label.dropFirst("Frame at ".count))
                XCTAssertGreaterThanOrEqual(time, start); XCTAssertLessThan(time, end)
            }
            update.tap()
        }
        XCUIDevice.shared.orientation = .landscapeRight
        expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height && update.isHittable }, evaluatedWith: app)
        waitForExpectations(timeout: 12)
        frames.firstMatch.tap(); XCTAssertTrue(share.waitForExistence(timeout: 15)); XCTAssertTrue(share.isHittable)
        evidence("Landscape cover")
    }

    func testSelectCoverUsesTheSurvivingLandscapeClip() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--mixed-canvas-fixture"]
        app.launchEnvironment["YOUREC_RECOVERY_TEST_RUN"] = UUID().uuidString
        app.launch()
        let span = app.buttons["Timeline view span"]
        XCTAssertTrue(span.waitForExistence(timeout: 30))
        span.tap(); app.buttons["Whole project"].tap()
        app.buttons["timeline.video.1"].tap(); app.buttons["Delete selection"].tap()
        app.buttons["timeline.video.1"].tap()
        app.buttons["Tools"].tap()
        let cover = app.buttons["tools.cover"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: cover); waitForExpectations(timeout: 15)
        cover.tap()
        XCTAssertTrue(app.staticTexts["Selected clips"].exists)
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'cover.frame.'")).firstMatch.tap()
        let share = app.buttons["cover.share"]
        XCTAssertTrue(share.waitForExistence(timeout: 15))
        let image = app.images["cover.image"]
        XCTAssertEqual(coverDimensions(app), [1280, 720])
        XCTAssertGreaterThan(image.frame.width, image.frame.height)
        #if targetEnvironment(simulator)
        share.tap()
        let save = app.otherElements["ActivityListView"].cells["Save Image"]
        XCTAssertTrue(save.waitForExistence(timeout: 12)); save.tap()
        #endif
    }

    func testExportMovieFromCatalogueCard() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        let title = "Catalogue export"
        app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]
        app.launchEnvironment["YOUREC_EDITOR_FIXTURE_TITLE"] = title
        app.launchEnvironment["YOUREC_RECOVERY_TEST_RUN"] = UUID().uuidString
        app.launch()
        let back = app.buttons["Back to projects"]
        XCTAssertTrue(back.waitForExistence(timeout: 30)); back.tap()
        app.buttons["Actions for " + title].tap(); app.buttons["Duplicate project"].tap()
        let other = title + " copy"
        let otherButton = app.buttons["Export video for " + other]
        XCTAssertTrue(otherButton.waitForExistence(timeout: 12))
        let target = app.buttons["Export video for " + title]
        let scroll = app.scrollViews.firstMatch
        revealInViewport(target, scroll: scroll)
        XCTAssertGreaterThanOrEqual(target.frame.width, 44); XCTAssertGreaterThanOrEqual(target.frame.height, 44)
        XCTAssertGreaterThan(target.frame.midX, 0.75 * app.frame.width)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Catalogue export action"; shot.lifetime = .keepAlways; add(shot)
        target.tap()
        let heading = app.staticTexts["export.project"]
        XCTAssertTrue(heading.waitForExistence(timeout: 10)); XCTAssertEqual(heading.label, title)
        let settings = app.buttons["export.settings"]
        expectation(for: NSPredicate(format: "value CONTAINS '720 × 1280'"), evaluatedWith: settings)
        waitForExpectations(timeout: 12)
        app.buttons["Export video"].tap()
        let share = app.buttons["Share latest export"]
        XCTAssertTrue(share.waitForExistence(timeout: 120))
        XCTAssertTrue(app.buttons["Save to Photos"].isHittable)
        share.tap()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 12))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.14)).tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(target.waitForExistence(timeout: 10))
        revealInViewport(target, scroll: scroll); target.tap()
        XCTAssertTrue(share.waitForExistence(timeout: 10), "Reopening the same card reuses the finished movie")
        app.buttons["Done"].tap()

        // The bottom Edit tab still opens the recording project chosen before export.
        app.buttons["catalogue.tab.2"].tap()
        XCTAssertTrue(app.staticTexts[other].waitForExistence(timeout: 20))
        let clip = app.buttons["timeline.video.1"]
        XCTAssertTrue(clip.waitForExistence(timeout: 15))
        clip.tap(); app.buttons["Delete selection"].tap(); back.tap()
        XCTAssertTrue(otherButton.waitForExistence(timeout: 10)); XCTAssertFalse(otherButton.isEnabled)
        XCTAssertTrue(target.isEnabled)
    }

    func testCatalogueExportSavesTheChosenVideoFormat() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]
        app.launchEnvironment["YOUREC_EDITOR_FIXTURE_TITLE"] = "Catalogue format QA"
        app.launchEnvironment["YOUREC_RECOVERY_TEST_RUN"] = UUID().uuidString
        app.launch()
        let back = app.buttons["Back to projects"]
        XCTAssertTrue(back.waitForExistence(timeout: 30)); back.tap()
        app.buttons["Export video for Catalogue format QA"].tap()
        let settings = app.buttons["export.settings"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: settings)
        waitForExpectations(timeout: 15); settings.tap()
        app.buttons["export.resolution"].tap(); app.buttons["720p"].tap()
        app.buttons["export.rate"].tap(); app.buttons["60 fps"].tap()
        app.buttons["export.codec"].tap(); app.buttons["H.265 · HEVC"].tap()
        XCTAssertTrue((settings.value as? String)?.contains("60 fps · H.265") == true)
        app.buttons["Export video"].tap()
        XCUIDevice.shared.press(.home); app.activate()
        let resume = app.buttons["Resume export"]
        XCTAssertTrue(resume.waitForExistence(timeout: 20)); resume.tap()
        let shared = app.buttons["Share latest export"]
        expectation(for: NSPredicate { _, _ in shared.exists || app.alerts.firstMatch.exists }, evaluatedWith: app)
        waitForExpectations(timeout: 100)
        XCTAssertTrue(shared.exists, app.alerts.firstMatch.exists ? app.alerts.firstMatch.label : "Missing export")
    }

    func testCatalogueExportAtAccessibilityTextSize() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launchEnvironment["YOUREC_EDITOR_FIXTURE_TITLE"] = "Accessible catalogue"
        app.launchEnvironment["YOUREC_RECOVERY_TEST_RUN"] = UUID().uuidString
        app.launch()
        let back = app.buttons["Back to projects"]
        XCTAssertTrue(back.waitForExistence(timeout: 25)); back.tap()
        let export = app.buttons["Export video for Accessible catalogue"]
        revealInViewport(export, scroll: app.scrollViews.firstMatch)
        XCTAssertTrue(export.isHittable)
        XCTAssertGreaterThanOrEqual(export.frame.width, 44); XCTAssertGreaterThanOrEqual(export.frame.height, 44)
        let edit = app.scrollViews.firstMatch.buttons["Edit"]
        XCTAssertLessThan(edit.frame.maxX, export.frame.minX)
        XCTAssertEqual(edit.frame.midY, export.frame.midY, accuracy: 1)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Catalogue at large text"; shot.lifetime = .keepAlways; add(shot)
        export.tap(); XCTAssertTrue(app.buttons["Export video"].waitForExistence(timeout: 10))
        app.buttons["Done"].tap(); XCTAssertTrue(export.waitForExistence(timeout: 10))
    }

    func testDuplicateProjectFromBrowser() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        let title = "Interview · UI test"
        app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]
        app.launchEnvironment["YOUREC_EDITOR_FIXTURE_TITLE"] = title
        app.launchEnvironment["YOUREC_RECOVERY_TEST_RUN"] = UUID().uuidString
        app.launch()
        let split = app.buttons["Split"], back = app.buttons["Back to projects"]
        XCTAssertTrue(split.waitForExistence(timeout: 30))
        seekTimeline(fraction: 0.35, in: app); split.tap()
        XCTAssertTrue(app.buttons["Undo"].isEnabled)
        back.tap()
        app.buttons["Actions for " + title].tap(); app.buttons["Duplicate project"].tap()
        let firstCopy = app.buttons["Actions for " + title + " copy"]
        XCTAssertTrue(firstCopy.waitForExistence(timeout: 20)); XCTAssertTrue(firstCopy.isHittable)
        let selectedEdit = app.buttons.matching(identifier: "Edit").firstMatch
        selectedEdit.tap()
        XCTAssertTrue(app.staticTexts[title + " copy"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Undo"].isEnabled)
        app.buttons["Undo"].tap()
        XCTAssertTrue(app.buttons["Redo"].isEnabled)
        back.tap(); firstCopy.tap(); app.buttons["Duplicate project"].tap()
        let secondCopy = app.buttons["Actions for " + title + " copy 2"]
        XCTAssertTrue(secondCopy.waitForExistence(timeout: 15)); XCTAssertTrue(secondCopy.isHittable)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Selected project duplicate"; shot.lifetime = .keepAlways; add(shot)
        app.launchArguments = ["--editor-preview"]
        app.terminate(); app.launch()
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["Undo"].isEnabled)
        XCTAssertFalse(app.buttons["Redo"].isEnabled, "Undo on the copy left the original at its split")
    }

    func testLibraryRenameDeleteRestore() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["Back to projects"].waitForExistence(timeout: 20))
        app.buttons["Back to projects"].tap()
        app.buttons["Actions for Studio notes · UI test"].tap()
        app.buttons["Rename"].tap()
        let field = app.textFields["Project name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.press(forDuration: 1)
        if app.menuItems["Select All"].exists { app.menuItems["Select All"].tap(); field.typeText("QA library project") }
        else { field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (field.value as? String ?? "").count) + "QA library project") }
        app.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["Actions for QA library project"].waitForExistence(timeout: 5))
        app.buttons["Actions for QA library project"].tap()
        app.buttons["Move to Recently deleted"].tap()
        let deleted = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Recently deleted ('")).firstMatch
        if !deleted.isHittable { app.swipeUp() }
        deleted.tap()
        app.buttons["Restore QA library project"].tap()
        app.buttons["Done"].tap()
        app.swipeDown()
        app.buttons["Actions for QA library project"].tap(); app.buttons["Rename"].tap()
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (field.value as? String ?? "").count) + "Studio notes · UI test")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["Actions for Studio notes · UI test"].waitForExistence(timeout: 5))
    }

    func testEditorPrimaryActionOrder() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]; app.launch()
        let export = app.buttons["Export"], split = app.buttons["Split"], tools = app.buttons["Tools"]
        XCTAssertTrue(export.waitForExistence(timeout: 25))
        for pose in [UIDeviceOrientation.portrait, .landscapeRight] {
            XCUIDevice.shared.orientation = pose
            expectation(for: NSPredicate { _, _ in
                let frame = app.windows.firstMatch.frame
                return (frame.height > frame.width) == (pose == .portrait)
            }, evaluatedWith: app); waitForExpectations(timeout: 10)
            let mark = app.buttons[pose == .portrait ? "Mark start" : "Mark end"]
            if pose == .landscapeRight {
                tools.tap(); XCTAssertTrue(app.navigationBars["Tools"].waitForExistence(timeout: 5)); app.buttons["Done"].tap()
            }
            let row = [mark, split, tools, export]
            for button in row {
                XCTAssertTrue(button.isHittable)
                XCTAssertGreaterThanOrEqual(button.frame.height, 44)
                XCTAssertEqual(button.frame.midY, export.frame.midY, accuracy: 1)
            }
            for (left, right) in zip(row, row.dropFirst()) { XCTAssertLessThan(left.frame.maxX, right.frame.minX) }
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = pose == .portrait ? "Editor actions portrait" : "Editor actions landscape"
            shot.lifetime = .keepAlways; add(shot)
            if pose == .portrait {
                seekTimeline(fraction: 0.35, in: app); split.tap()
                XCTAssertTrue(app.buttons["Undo"].isEnabled); app.buttons["Undo"].tap()
                mark.tap(); XCTAssertTrue(app.buttons["Mark end"].exists)
            }
        }
        export.tap(); XCTAssertTrue(app.navigationBars["Export"].waitForExistence(timeout: 5)); app.buttons["Done"].tap()
    }

    func testLandscapeAndLargeText() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        app.launch()
        for pose in [UIDeviceOrientation.portrait, .landscapeRight] {
            XCUIDevice.shared.orientation = pose
            expectation(for: NSPredicate { _, _ in
                let frame = app.windows.firstMatch.frame
                return (frame.height > frame.width) == (pose == .portrait)
            }, evaluatedWith: app)
            waitForExpectations(timeout: 15)
            let scroll = app.scrollViews["editor.controlsScroll"]
            XCTAssertTrue(scroll.waitForExistence(timeout: 12))
            for _ in 0..<5 { if app.staticTexts["editor.playhead"].isHittable { break }; scroll.swipeDown() }
            XCTAssertTrue(app.staticTexts["editor.playhead"].isHittable)
            XCTAssertTrue(app.staticTexts["editor.duration"].isHittable)
            let export = app.buttons["Export"], mark = app.buttons["Mark start"], split = app.buttons["Split"], tools = app.buttons["Tools"]
            revealInViewport(split, scroll: scroll)
            XCTAssertEqual(mark.frame.midY, split.frame.midY, accuracy: 1)
            XCTAssertLessThan(mark.frame.maxX, split.frame.minX)
            revealInViewport(export, scroll: scroll)
            XCTAssertEqual(tools.frame.midY, export.frame.midY, accuracy: 1)
            XCTAssertLessThan(tools.frame.maxX, export.frame.minX)
            XCTAssertLessThan(split.frame.maxY, export.frame.minY)
            XCTAssertEqual(export.frame.height, split.frame.height, accuracy: 1)
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = pose == .portrait ? "Accessible editor portrait" : "Accessible editor landscape"
            shot.lifetime = .keepAlways; add(shot)
            app.buttons["Export"].tap()
            XCTAssertTrue(app.navigationBars["Export"].waitForExistence(timeout: 8))
            app.buttons["Done"].tap()
        }
    }

    func testVolumeFadesOnOuterSelectedClips() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--multiselect-fixture"]
        app.launch()
        let tools = app.buttons["Tools"], volume = app.buttons["audio.quickGain"]
        XCTAssertTrue(tools.waitForExistence(timeout: 25))
        seekTimeline(fraction: 1.0 / 3, in: app)
        tools.tap()
        XCTAssertTrue(app.scrollViews["tools.content"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["tools.transition"].exists)
        app.buttons["Done"].tap()
        openTimelineTransition(in: app)
        XCTAssertTrue(app.buttons["transition.apply"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].tap()
        app.buttons["timeline.video.2"].tap(); app.buttons["timeline.video.3"].press(forDuration: 0.65)
        volume.tap()
        let scroll = app.scrollViews["audioTool.controls"]
        func duration(_ edge: String) -> XCUIElement { app.buttons["volume." + edge + ".duration"] }
        func change(_ edge: String, to time: String) {
            let button = duration(edge)
            revealInViewport(button, scroll: scroll, swipeX: 0.94); button.tap()
            let field = app.alerts.textFields.firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap()
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (field.value as? String ?? "").count) + time)
            app.alerts.buttons["Set"].tap()
        }
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        let fadeSlider = app.sliders["Fade in"]
        revealInViewport(fadeSlider, scroll: scroll, swipeX: 0.94)
        fadeSlider.adjust(toNormalizedSliderPosition: 0.5)
        XCTAssertNotEqual(duration("fadeIn").value as? String, "0 seconds")
        change("fadeIn", to: "1.2"); change("fadeOut", to: "0.6")
        XCTAssertTrue(app.staticTexts["volume.fadeIn.target"].label.hasPrefix("Audio 2"))
        XCTAssertTrue(app.staticTexts["volume.fadeOut.target"].label.hasPrefix("Audio 3"))
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "Volume fades on two selected clips"; shot.lifetime = .keepAlways; add(shot)
        let listen = app.buttons["volume.fadeOut.listen"]
        revealInViewport(listen, scroll: scroll, swipeX: 0.94); listen.tap()
        let clock = app.staticTexts["audioTool.position"]
        expectation(for: NSPredicate(format: "value BEGINSWITH '16.40 to 18.00'"), evaluatedWith: clock); waitForExpectations(timeout: 15)
        app.buttons["Apply"].tap(); XCTAssertTrue(tools.waitForExistence(timeout: 12))
        // Reopen each timeline clip to verify the actual committed edge and its neighbor.
        func check(_ number: Int, _ intro: String, _ outro: String) {
            let clip = app.buttons["timeline.video.\(number)"]
            if clip.isSelected { app.buttons["editor.clearSelection"].tap() }
            clip.tap(); volume.tap()
            revealInViewport(duration("fadeOut"), scroll: scroll, swipeX: 0.94)
            XCTAssertEqual((duration("fadeIn").value as? String)?.replacingOccurrences(of: ",", with: "."), intro + " seconds")
            XCTAssertEqual((duration("fadeOut").value as? String)?.replacingOccurrences(of: ",", with: "."), outro + " seconds")
            app.buttons["Cancel"].tap()
        }
        check(1, "0", "0"); check(2, "1.2", "0"); check(3, "0", "0.6")
        app.buttons["Undo"].tap(); check(2, "0", "0"); check(3, "0", "0")
    }

    func testUnchangedRangeVolumePreservesClips() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["Mark start"].waitForExistence(timeout: 15))
        seekTimeline(fraction: 0.2, in: app); app.buttons["Mark start"].tap()
        seekTimeline(fraction: 0.55, in: app); app.buttons["Mark end"].tap()
        app.buttons["audio.quickGain"].tap()
        let apply = app.buttons["Apply"]
        XCTAssertTrue(apply.waitForExistence(timeout: 12)); apply.tap()
        XCTAssertTrue(app.buttons["Tools"].waitForExistence(timeout: 12))
        for lane in ["video", "audio"] {
            let count = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "timeline." + lane + ".")).count
            XCTAssertEqual(count, 1)
        }
    }

    func testCutUndoReopenAndAudioChain() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--reset-ui-fixture"]
        app.launch()
        let timeline = app.otherElements["editor.timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 30), app.debugDescription)
        let preview = app.otherElements["editor.preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        let visible = NSPredicate(format: "value BEGINSWITH 'Frame visible'")
        expectation(for: visible, evaluatedWith: preview)
        waitForExpectations(timeout: 15)
        let initial = app.staticTexts["editor.duration"].label
        app.buttons["Mark start"].tap()
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.7))
            .press(forDuration: 0.1, thenDragTo: timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.7)))
        app.buttons["Mark end"].tap()
        XCTAssertTrue(app.buttons["Delete range"].waitForExistence(timeout: 3))
        app.buttons["Preview cut"].doubleTap()
        XCTAssertTrue(app.staticTexts["Previewing cut"].waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: app.buttons["Original"]); waitForExpectations(timeout: 10)
        app.buttons["Delete range"].tap()
        XCTAssertNotEqual(app.staticTexts["editor.duration"].label, initial)
        app.buttons["Undo"].tap()
        XCTAssertEqual(app.staticTexts["editor.duration"].label, initial)
        XCTAssertTrue(app.buttons["Redo"].isEnabled)
        app.launchArguments = ["--editor-preview"]
        app.terminate(); app.launch()
        XCTAssertTrue(timeline.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["Redo"].isEnabled, "Redo persists across relaunch")
        app.buttons["Redo"].tap()
        XCTAssertNotEqual(app.staticTexts["editor.duration"].label, initial)
        app.buttons["Undo"].tap()
        app.buttons["Audio filters"].tap()
        app.buttons["Add filter"].tap()
        app.buttons["Low-cut filter"].tap()
        XCTAssertTrue(app.buttons["Low-cut filter enabled"].waitForExistence(timeout: 5))
        app.buttons["Apply & listen"].tap()
        XCTAssertTrue(app.buttons["Applied"].waitForExistence(timeout: 30))
        app.buttons["Done"].tap()
        XCTAssertEqual(app.buttons["editor.processed"].value as? String, "Selected")
        app.buttons["Play"].tap()
        let beforeComparison = app.staticTexts["editor.playhead"].label
        app.buttons["Original"].tap()
        XCTAssertTrue(app.buttons["Original"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Pause playback"].waitForExistence(timeout: 5), "A/B keeps playing")
        expectation(for: NSPredicate { _, _ in app.staticTexts["editor.playhead"].label != beforeComparison }, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        app.buttons["Pause playback"].tap()
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Editor after cutting and audio processing"; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
