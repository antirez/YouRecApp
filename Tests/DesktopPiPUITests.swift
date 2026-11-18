#if targetEnvironment(macCatalyst)
import XCTest
import AVFoundation
import ImageIO
import Vision

final class DesktopPiPUITests: XCTestCase {
    private func openTimeline(realProject: Bool = false, extraArguments: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        let env = ProcessInfo.processInfo.environment
        let session = realProject ? env["YOUREC_DESKTOP_TIMELINE_RUN"] ?? UUID().uuidString : UUID().uuidString
        app.launchEnvironment["YOUREC_RECOVERY_TEST_RUN"] = session
        app.launchEnvironment["YOUREC_LIBRARY_TEST_RUN"] = session
        if realProject { app.launchEnvironment["YOUREC_EDITOR_FIXTURE_TITLE"] = env["YOUREC_DESKTOP_TIMELINE_PROJECT"] }
        app.launchArguments = ["--editor-preview"] + extraArguments
        app.launch()
        let blade = app.buttons["Blade"]
        XCTAssertTrue(blade.waitForExistence(timeout: 30))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: app.buttons["Play"])
        waitForExpectations(timeout: 60)
        return app
    }

    func testDesktopEffectOptions() throws {
        let app = openTimeline(extraArguments: ["--reset-ui-fixture", "--title-preview-fixture"])
        app.buttons["Next change"].click()
        let name = app.buttons["effect.text"].firstMatch
        let dots = app.buttons["effect.text.options"].firstMatch
        XCTAssertTrue(dots.waitForExistence(timeout: 12))
        func checkMenu() {
            XCTAssertTrue(app.buttons["effect.editRange"].waitForExistence(timeout: 8))
            XCTAssertTrue(app.buttons["effect.confirmRemove"].isHittable)
            app.buttons["effect.cancelRemove"].click()
            XCTAssertTrue(app.popovers.firstMatch.waitForNonExistence(timeout: 5))
        }
        dots.click(); checkMenu()
        name.rightClick(); checkMenu()
        name.click(); XCTAssertTrue(app.descendants(matching: .any)["tool.text.input"].firstMatch.waitForExistence(timeout: 12))
        app.buttons["tool.cancel"].click()
    }

    func testDesktopEditorDecisionHeaders() throws {
        let app = openTimeline()
        func item(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
        for (tool, cancelID, applyID) in [("text", "tool.cancel", "tool.apply"),
                                          ("crop", "tool.cancel", "tool.apply"),
                                          ("videoEffects", "Cancel", "videoEffects.apply")] {
            let shortcut = item("tools." + tool)
            XCTAssertTrue(shortcut.waitForExistence(timeout: 8)); shortcut.click()
            let cancel = app.buttons[cancelID], apply = app.buttons[applyID]
            XCTAssertTrue(cancel.waitForExistence(timeout: 8))
            XCTAssertTrue(apply.exists && cancel.isHittable)
            XCTAssertGreaterThanOrEqual(cancel.frame.width, 80)
            XCTAssertGreaterThanOrEqual(apply.frame.width, 80)
            XCTAssertGreaterThan(apply.frame.minX - cancel.frame.maxX, 30)
            let header = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            header.name = "Header " + tool; header.lifetime = .keepAlways; add(header)
            cancel.click()
            XCTAssertTrue(item("editor.toolsSidebar").waitForExistence(timeout: 8))
        }
    }

    func testDesktopDurationUsesIndependentBoundaries() throws {
        let app = openTimeline(extraArguments: ["--reset-ui-fixture"])
        func item(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
        XCTAssertFalse(app.buttons["Tools"].exists)
        let range = item("tools.range")
        XCTAssertTrue(range.waitForExistence(timeout: 8)); range.click()
        let four = item("selection.duration.4"), custom = item("selection.duration.custom")
        XCTAssertTrue(four.waitForExistence(timeout: 8)); four.click(); custom.click()
        let start = item("selection.start.later"), end = item("selection.end.earlier")
        XCTAssertTrue(start.waitForExistence(timeout: 5)); start.click()
        func time(_ id: String) -> String {
            let control = item(id)
            return control.value as? String ?? control.label
        }
        XCTAssertEqual(time("selection.start.time"), "0:00.03")
        XCTAssertEqual(time("selection.end.time"), "0:04.00")
        end.click()
        XCTAssertEqual(time("selection.rangeTime"), "0:03.93")
        let picture = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        picture.name = "Desktop duration controls"; picture.lifetime = .keepAlways; add(picture)
        item("selection.rangeDone").click()
        XCTAssertTrue(range.waitForExistence(timeout: 8))
        XCTAssertTrue((range.value as? String ?? "").contains("0:03.97"))
    }

    func testDesktopLinkedTimelineAndMoveDecisions() throws {
        let app = openTimeline(extraArguments: ["--reset-ui-fixture", "--multiselect-fixture", "--move-snap-fixture"])
        func item(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
        let timeline = item("editor.timeline"), ruler = item("timeline.ruler")
        func fit() {
            app.buttons["Timeline view span"].click()
            app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Whole project' OR title == 'Whole project'")).firstMatch.click()
        }
        func shot(_ element: XCUIElement, _ name: String) {
            let attachment = XCTAttachment(screenshot: element.screenshot())
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        fit()
        let first = item("timeline.video.1"), second = item("timeline.video.2")
        let point = second.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.55))
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)).click()
        point.click(forDuration: 0.75, thenDragTo: point)
        app.buttons["Link"].click()
        XCTAssertTrue(first.label.contains("group of 4"))
        shot(timeline, "Desktop joined selection")
        app.buttons["editor.clearSelection"].click()
        shot(timeline, "Desktop joined filmstrip")
        item("timeline.audio.2").coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.55)).click()
        XCTAssertTrue(first.isSelected && second.isSelected)
        let y = ruler.frame.minY
        app.buttons["Move"].click()
        let cancel = app.buttons["Cancel"], done = app.buttons["Done"]
        XCTAssertTrue(cancel.isHittable && done.isHittable)
        XCTAssertGreaterThanOrEqual(cancel.frame.width, 80)
        XCTAssertGreaterThanOrEqual(done.frame.height, 39)
        XCTAssertGreaterThanOrEqual(done.frame.minX - cancel.frame.maxX, 5)
        XCTAssertEqual(cancel.frame.midY, done.frame.midY, accuracy: 1)
        XCTAssertEqual(y, ruler.frame.minY, accuracy: 1)
        shot(app.windows.firstMatch, "Desktop Move actions")
        item("move.choose").click()
        XCTAssertTrue(item("move.destinationPrompt").label.contains("Click"))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(done.isHittable)
        item("move.next").click()
        cancel.click()
        fit()
        XCTAssertTrue((first.value as? String ?? "").hasPrefix("0.000"))
        app.buttons["Move"].click()
        item("move.next").click()
        app.typeKey(.return, modifierFlags: [])
        XCTAssertFalse(done.exists)
        fit()
        XCTAssertFalse((first.value as? String ?? "").hasPrefix("0.000"))
        app.buttons["Undo"].click()
        XCTAssertTrue((first.value as? String ?? "").hasPrefix("0.000"))
    }

    func testGroupedTitleCanBeSelectedAndMovedByMouse() throws {
        let app = openTimeline()
        func item(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
        XCTAssertFalse(app.buttons["Tools"].exists)
        let text = item("tools.text")
        XCTAssertTrue(text.waitForExistence(timeout: 10)); text.click()
        let input = item("tool.text.input")
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        XCTAssertEqual(input.placeholderValue, "Text")
        item("tool.apply").click()
        let badge = item("effect.text")
        XCTAssertTrue(badge.waitForExistence(timeout: 10)); badge.click()
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        XCTAssertEqual(input.value as? String, "Text", "An untouched starter is a real, saved title")
        item("tool.cancel").click()
        app.buttons["Undo"].click()
        text.click()
        let grouped = item("title.layout").descendants(matching: .any).matching(
            NSPredicate(format: "label == 'Label + headline' OR title == 'Label + headline'")).firstMatch
        XCTAssertTrue(grouped.waitForExistence(timeout: 10)); grouped.click()
        XCTAssertEqual(input.value as? String, "Second text")
        item("title.layout").descendants(matching: .any).matching(
            NSPredicate(format: "label == 'Single text' OR title == 'Single text'")).firstMatch.click()
        XCTAssertEqual(input.placeholderValue, "Text")
        input.click(); input.typeText("Desk title")
        XCTAssertEqual(input.value as? String, "Desk title")
        grouped.click()
        XCTAssertEqual(input.value as? String, "Desk title")
        let overlay = item("tool.text.overlay")
        XCTAssertTrue(overlay.waitForExistence(timeout: 10))
        overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.30, dy: 0.19)).click()
        XCTAssertTrue(item("tool.text.label").waitForExistence(timeout: 5))
        let before = overlay.frame
        let center = overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.click(forDuration: 0.12, thenDragTo: center.withOffset(CGVector(dx: 0, dy: -28)))
        XCTAssertLessThan(overlay.frame.midY, before.midY - 14)
        item("tool.apply").click()
        XCTAssertTrue(item("effect.text").waitForExistence(timeout: 12))
        item("effect.text").click()
        XCTAssertEqual(item("tool.text.input").value as? String, "Desk title")
    }

    func testWheelZoomAndFilmstripDragPreservePlayhead() throws {
        let app = openTimeline()
        func item(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
        let ruler = item("timeline.ruler"), video = item("timeline.video.1")
        func times() throws -> (left: Double, right: Double) {
            let pieces = try XCTUnwrap(ruler.value as? String).components(separatedBy: " to ")
            func seconds(_ value: String?) throws -> Double {
                let clock = try XCTUnwrap(value).split(separator: ":")
                return try XCTUnwrap(Double(clock.first ?? "")) * 60 + XCTUnwrap(Double(clock.last ?? ""))
            }
            return (try seconds(pieces.first), try seconds(pieces.last))
        }
        app.buttons["Timeline view span"].click()
        let ten = app.descendants(matching: .any).matching(NSPredicate(format: "label == '10 seconds' OR title == '10 seconds'")).firstMatch
        XCTAssertTrue(ten.waitForExistence(timeout: 5)); ten.click()
        let playhead = app.staticTexts["editor.playhead"].label
        let point = video.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5))
        let old = try times()
        point.click(forDuration: 0.12, thenDragTo: video.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)))
        let panned = try times()
        XCTAssertGreaterThan(panned.left, old.left)
        let pointerFraction = (point.screenPoint.x - ruler.frame.minX) / ruler.frame.width
        func timeAtPointer(_ range: (left: Double, right: Double)) -> Double {
            range.left + Double(pointerFraction) * (range.right - range.left)
        }
        point.hover()
        point.scroll(byDeltaX: 0, deltaY: 20)
        let zoomed = try times()
        // XCTest generates precise, unphased scrolls. Their sign follows the Mac's scroll preference.
        XCTAssertGreaterThan(abs((zoomed.right - zoomed.left) - (panned.right - panned.left)), 0.1)
        XCTAssertEqual(timeAtPointer(zoomed), timeAtPointer(panned), accuracy: 0.05)
        point.scroll(byDeltaX: 0, deltaY: -20)
        let restored = try times()
        XCTAssertEqual(restored.left, panned.left, accuracy: 0.05)
        XCTAssertEqual(restored.right, panned.right, accuracy: 0.05)
        XCTAssertEqual(app.staticTexts["editor.playhead"].label, playhead)
        XCTAssertFalse(app.buttons["editor.clearSelection"].exists)
    }

    func testTimelinePaletteShowsBothShortcutsOnHover() throws {
        let app = openTimeline()
        let window = app.windows.firstMatch
        for (mode, shortcut) in [("select", "Select (A)"), ("blade", "Blade (B)")] {
            let button = app.buttons["timeline.mode." + mode]
            button.hover()
            let deadline = Date.now.addingTimeInterval(5)
            var visible = false
            while Date.now < deadline {
                let screenshot = window.screenshot()
                let request = VNRecognizeTextRequest()
                request.usesLanguageCorrection = false
                request.recognitionLanguages = ["en-US"]
                try VNImageRequestHandler(data: screenshot.pngRepresentation).perform([request])
                if let tip = request.results?.first(where: { $0.topCandidates(1).first?.string.contains(shortcut) == true }) {
                    let tipBottom = window.frame.minY + (1 - tip.boundingBox.minY) * window.frame.height
                    XCTAssertLessThan(tipBottom, button.frame.minY, "The shortcut should leave the tool visible")
                    let attachment = XCTAttachment(screenshot: screenshot)
                    attachment.name = shortcut; attachment.lifetime = .keepAlways; add(attachment)
                    visible = true
                    break
                }
            }
            XCTAssertTrue(visible, "Hover should show " + shortcut)
        }
    }

    func testBladeClicksAndSelectionKeepTimelineInPlace() throws {
        let app = openTimeline()
        func item(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
        let ruler = item("timeline.ruler"), video = item("timeline.video.1"), audio = item("timeline.audio.1")
        let selectMode = app.buttons["timeline.mode.select"], bladeMode = app.buttons["timeline.mode.blade"]
        let play = app.buttons["Play"], elapsed = item("editor.playhead"), total = item("editor.duration")
        XCTAssertTrue(selectMode.isSelected)
        XCTAssertEqual(bladeMode.frame.midY, play.frame.midY, accuracy: 2)
        XCTAssertLessThan(bladeMode.frame.maxX, elapsed.frame.minX)
        XCTAssertEqual(play.frame.midX, ruler.frame.midX, accuracy: 4)
        XCTAssertLessThan(abs(elapsed.frame.maxX - app.buttons["Previous bookmark"].frame.minX), 20)
        XCTAssertLessThan(abs(total.frame.minX - app.buttons["Next bookmark"].frame.maxX), 20)
        bladeMode.click(); XCTAssertTrue(bladeMode.isSelected)
        selectMode.click(); XCTAssertTrue(selectMode.isSelected)
        let baseline = [ruler.frame, video.frame, audio.frame, item("editor.preview").frame]
        XCTAssertGreaterThan(baseline[0].height, 24)
        func assertRowsStayPut() {
            for (before, after) in zip(baseline, [ruler.frame, video.frame, audio.frame, item("editor.preview").frame]) {
                XCTAssertEqual(before.minY, after.minY, accuracy: 0.6)
                XCTAssertEqual(before.height, after.height, accuracy: 0.6)
            }
        }
        let quarter = video.coordinate(withNormalizedOffset: CGVector(dx: 0.26, dy: 0.6))
        quarter.click()
        XCTAssertTrue(app.buttons["editor.clearSelection"].waitForExistence(timeout: 5))
        assertRowsStayPut()
        app.buttons["editor.clearSelection"].click()
        assertRowsStayPut()
        app.typeKey("b", modifierFlags: [])
        XCTAssertTrue(bladeMode.isSelected)
        quarter.hover()
        quarter.click()
        XCTAssertTrue(item("timeline.video.2").waitForExistence(timeout: 6))
        XCTAssertTrue(item("timeline.audio.2").exists)
        let second = item("timeline.video.2").coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5))
        second.click()
        XCTAssertTrue(item("timeline.video.3").waitForExistence(timeout: 6))
        XCTAssertTrue(item("timeline.audio.3").exists)
        assertRowsStayPut()
        app.typeKey("a", modifierFlags: [])
        XCTAssertTrue(selectMode.isSelected)
        item("timeline.video.2").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(app.buttons["editor.clearSelection"].waitForExistence(timeout: 5))
        XCTAssertFalse(item("timeline.video.4").exists)
        app.buttons["Undo"].click()
        XCTAssertFalse(item("timeline.video.3").exists)

        // Detached sound is independently editable, even under a picture.
        item("timeline.video.2").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        let unlink = app.buttons["Unlink"]
        XCTAssertTrue(unlink.waitForExistence(timeout: 5)); unlink.click()
        let sound = item("timeline.audio.2").coordinate(withNormalizedOffset: CGVector(dx: 0.47, dy: 0.5))
        sound.hover()
        app.typeKey("b", modifierFlags: [])
        sound.click()
        XCTAssertTrue(item("timeline.audio.3").waitForExistence(timeout: 5))
        XCTAssertFalse(item("timeline.video.3").exists)
        app.typeKey("a", modifierFlags: [])
    }

    func testScissorsPreviewMatchesCutAndDetachedAudio() throws {
        let app = openTimeline()
        func item(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
        let timeline = item("editor.timeline")
        let video = item("timeline.video.1"), audio = item("timeline.audio.1")
        let position = app.staticTexts["editor.playhead"].label
        let point = video.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.76))
        point.hover()
        let before = timeline.screenshot()
        app.typeKey("b", modifierFlags: [])
        let hover = timeline.screenshot()
        func guide(in lane: XCUIElement, near x: CGFloat, from a: XCUIScreenshot, to b: XCUIScreenshot) throws -> CGFloat? {
            let surface = timeline.frame
            let region = CGRect(x: x - 15, y: lane.frame.minY + 3, width: 30, height: lane.frame.height - 6)
            let width = Int(region.width), height = Int(region.height)
            func gray(_ screenshot: XCUIScreenshot) throws -> [UInt8] {
                let source = try XCTUnwrap(CGImageSourceCreateWithData(screenshot.pngRepresentation as CFData, nil))
                let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
                let crop = region.offsetBy(dx: -surface.minX, dy: -surface.minY)
                    .applying(CGAffineTransform(scaleX: CGFloat(image.width) / surface.width, y: CGFloat(image.height) / surface.height))
                let strip = try XCTUnwrap(image.cropping(to: crop))
                var bytes = [UInt8](repeating: 0, count: width * height)
                try bytes.withUnsafeMutableBytes { buffer in
                    let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height,
                        bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0))
                    context.draw(strip, in: CGRect(x: 0, y: 0, width: width, height: height))
                }
                return bytes
            }
            let first = try gray(a), second = try gray(b)
            // Count separated marks, so a solid playhead or cursor can't pass as a dotted guide.
            let runs = (0..<width).map { column in
                var count = 0, previous = false
                for row in 0..<height {
                    let i = row * width + column
                    let changed = abs(Int(first[i]) - Int(second[i])) > 24
                    if changed && !previous { count += 1 }
                    previous = changed
                }
                return count
            }
            guard let maxRuns = runs.max(), maxRuns >= max(4, height / 10), let column = runs.firstIndex(of: maxRuns) else { return nil }
            return region.minX + CGFloat(column) + 0.5
        }
        let videoX = try XCTUnwrap(guide(in: video, near: point.screenPoint.x, from: before, to: hover))
        let audioX = try XCTUnwrap(guide(in: audio, near: point.screenPoint.x, from: before, to: hover))
        XCTAssertEqual(videoX, audioX, accuracy: 2)
        XCTAssertEqual(app.staticTexts["editor.playhead"].label, position)
        item("timeline.ruler").coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5)).hover()
        XCTAssertNil(try guide(in: video, near: videoX, from: before, to: timeline.screenshot()))
        point.click()
        let next = item("timeline.video.2")
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        XCTAssertEqual(videoX, (video.frame.maxX + next.frame.minX) / 2, accuracy: 2)
        app.typeKey("a", modifierFlags: [])
        next.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        app.buttons["Unlink"].click()
        let sound = item("timeline.audio.2")
        let detachedPoint = sound.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.8))
        detachedPoint.hover()
        let detached = timeline.screenshot()
        app.typeKey("b", modifierFlags: [])
        let active = timeline.screenshot()
        XCTAssertNotNil(try guide(in: sound, near: detachedPoint.screenPoint.x, from: detached, to: active))
        XCTAssertNil(try guide(in: next, near: detachedPoint.screenPoint.x, from: detached, to: active))
        app.typeKey("a", modifierFlags: [])
        XCTAssertNil(try guide(in: sound, near: detachedPoint.screenPoint.x, from: detached, to: timeline.screenshot()))
    }

    func testEffectAndSelectionControlsShareOneRow() throws {
        let app = openTimeline(extraArguments: ["--navigation-fixture"])
        func item(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
        let ruler = item("timeline.ruler"), video = item("timeline.video.2")
        app.buttons["Timeline view span"].click()
        let whole = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Whole project' OR title == 'Whole project'")).firstMatch
        XCTAssertTrue(whole.waitForExistence(timeout: 5)); whole.click()
        // Video 2 spans 6–12 seconds, with a text overlay at 8–10.
        let preview = item("editor.preview")
        let positions = [ruler.frame, video.frame, preview.frame]
        let x = (video.frame.midX - ruler.frame.minX) / ruler.frame.width
        ruler.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.5)).click()
        XCTAssertTrue(item("effect.text").waitForExistence(timeout: 5))
        video.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).click()
        XCTAssertTrue(app.buttons["editor.clearSelection"].waitForExistence(timeout: 5))
        XCTAssertEqual(positions, [ruler.frame, video.frame, preview.frame])
        app.buttons["editor.clearSelection"].click()
        XCTAssertTrue(item("effect.text").waitForExistence(timeout: 5))
        XCTAssertEqual(positions, [ruler.frame, video.frame, preview.frame])
    }

    func testRulerScrubsVisiblePictureBeforeMouseUp() throws {
        try XCTSkipUnless(CGPreflightPostEventAccess(), "This test posts separate mouse-down, drag and mouse-up events on the Mac.")
        let app = openTimeline()
        func item(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
        let ruler = item("timeline.ruler"), preview = item("editor.preview")
        let playhead = app.staticTexts["editor.playhead"]
        app.buttons["Timeline view span"].click()
        let whole = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Whole project' OR title == 'Whole project'")).firstMatch
        XCTAssertTrue(whole.waitForExistence(timeout: 5))
        whole.click()
        let span = try XCTUnwrap(ruler.value as? String)
        let points = [0.20, 0.49, 0.82].map { ruler.coordinate(withNormalizedOffset: CGVector(dx: $0, dy: 0.5)) }

        // Compare the middle of the video itself, away from the preview controls.
        func picture() throws -> [UInt8] {
            let src = try XCTUnwrap(CGImageSourceCreateWithData(preview.screenshot().pngRepresentation as CFData, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
            let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            let center = try XCTUnwrap(image.cropping(to: rect.insetBy(dx: rect.width / 4, dy: rect.height / 4)))
            var pixels = [UInt8](repeating: 0, count: 32 * 24)
            try pixels.withUnsafeMutableBytes { buffer in
                let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 32, height: 24,
                    bitsPerComponent: 8, bytesPerRow: 32, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0))
                context.draw(center, in: CGRect(x: 0, y: 0, width: 32, height: 24))
            }
            return pixels
        }
        func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
            Double(zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(a.count)
        }
        let references = try points.map { point in
            point.click()
            return (time: playhead.label, image: try picture())
        }
        for (a, b) in zip(references, references.dropFirst()) {
            XCTAssertGreaterThan(difference(a.image, b.image), 5, "Use a fixture with visibly different shots.")
        }

        var pointer = points[0].screenPoint
        func send(_ type: CGEventType) throws {
            let event = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: pointer, mouseButton: .left))
            event.post(tap: .cghidEventTap)
        }
        try send(.mouseMoved)
        try send(.leftMouseDown)
        defer { try? send(.leftMouseUp) }
        for index in [0, 1, 2, 1] {
            if index != 0 {
                pointer = points[index].screenPoint
                try send(.leftMouseDragged)
            }
            let reference = references[index]
            expectation(for: NSPredicate(format: "label == %@", reference.time), evaluatedWith: playhead)
            waitForExpectations(timeout: 4)
            let deadline = Date().addingTimeInterval(3)
            var delta = try difference(reference.image, picture())
            while delta > 2 && Date() < deadline { delta = try difference(reference.image, picture()) }
            XCTAssertLessThanOrEqual(delta, 2, "The held pointer must show the same picture as clicking here.")
        }
        XCTAssertEqual(ruler.value as? String, span)
    }

    func testDesktopRulerAndSpaceOnProject() throws {
        let app = openTimeline(realProject: true)
        func item(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
        let ruler = item("timeline.ruler"), time = app.staticTexts["editor.playhead"]
        app.buttons["Timeline view span"].click()
        let one = app.descendants(matching: .any).matching(NSPredicate(format: "label == '1 second' OR title == '1 second'")).firstMatch
        XCTAssertTrue(one.waitForExistence(timeout: 5)); one.click()
        let from = ruler.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5))
        let to = ruler.coordinate(withNormalizedOffset: CGVector(dx: 0.24, dy: 0.5))
        let original = try XCTUnwrap(ruler.value as? String)
        let before = time.label
        from.click()
        let anchor = time.label
        XCTAssertNotEqual(before, anchor)
        XCTAssertEqual(ruler.value as? String, original)
        app.typeKey("b", modifierFlags: [])
        from.click(forDuration: 0.55, thenDragTo: to)
        XCTAssertEqual(ruler.value as? String, original)
        XCTAssertNotEqual(time.label, anchor)
        let dragEnd = time.label
        to.click()
        XCTAssertEqual(time.label, dragEnd)
        to.click(forDuration: 0.12, thenDragTo: from)
        XCTAssertEqual(time.label, anchor)
        XCTAssertEqual(ruler.value as? String, original)
        app.typeKey("a", modifierFlags: [])
        app.typeKey(.space, modifierFlags: [])
        XCTAssertTrue(app.buttons["Pause playback"].waitForExistence(timeout: 4))
        let first = time.label
        expectation(for: NSPredicate(format: "label != %@", first), evaluatedWith: time)
        waitForExpectations(timeout: 3)
        app.typeKey(.space, modifierFlags: [])
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 4))
        let stopped = time.label
        Thread.sleep(forTimeInterval: 0.25)
        XCTAssertEqual(time.label, stopped)
        app.buttons["Play"].click()
        XCTAssertTrue(app.buttons["Pause playback"].waitForExistence(timeout: 4))
        app.buttons["Pause playback"].click()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 4))
    }

    func testProjectsFolderPreferenceAndFinderAction() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["YOUREC_LIBRARY_TEST_RUN"] = UUID().uuidString
        app.launch()
        let settings = app.buttons["projects.settings"]
        func openSettings() {
            XCTAssertTrue(settings.waitForExistence(timeout: 15))
            settings.click()
            XCTAssertTrue(app.buttons["library.change"].waitForExistence(timeout: 8))
        }
        openSettings()
        let location = app.staticTexts["library.path"]
        let previous = location.label
        XCTAssertTrue(previous.hasSuffix("/YouRec"), previous)
        let newFolder = FileManager.default.temporaryDirectory.appendingPathComponent("YouRec-Library-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: newFolder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: newFolder) }
        XCTAssertTrue(app.buttons["library.change"].isEnabled)
        app.buttons["library.change"].click()
        Thread.sleep(forTimeInterval: 0.5)
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(newFolder.path); app.typeKey(.return, modifierFlags: [])
        let choose = app.buttons["Open"].firstMatch
        if choose.waitForExistence(timeout: 3) { choose.click() } else { app.typeKey(.return, modifierFlags: []) }
        let changed = NSPredicate(format: "label ENDSWITH %@", "/" + newFolder.lastPathComponent)
        expectation(for: changed, evaluatedWith: location); waitForExpectations(timeout: 15)
        app.buttons["Done"].click()
        app.buttons["New project"].click()
        let finderProjects = newFolder.appendingPathComponent("Projects")
        let ids = try FileManager.default.contentsOfDirectory(atPath: finderProjects.path).filter { UUID(uuidString: $0) != nil }
        let id = try XCTUnwrap(ids.first); XCTAssertEqual(ids.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: finderProjects.appendingPathComponent(id + "/project.json").path))
        app.terminate()
        app.launch()
        openSettings()
        XCTAssertTrue(changed.evaluate(with: location))
        app.buttons["Done"].click()
        let actions = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Actions for '")).firstMatch
        if !actions.waitForExistence(timeout: 8) {
            add(XCTAttachment(screenshot: app.windows.firstMatch.screenshot()))
            XCTFail("Missing project menu. " + app.windows.firstMatch.debugDescription)
            return
        }
        actions.click()
        let reveal = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Reveal in Finder' OR title == 'Reveal in Finder' OR identifier == %@", "project.reveal." + id)).firstMatch
        XCTAssertTrue(reveal.waitForExistence(timeout: 5)); reveal.click()
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        XCTAssertTrue(finder.wait(for: .runningForeground, timeout: 8))
        // Finder's column view titles the window with the selected folder.
        // Icon/list views can expose its name in the selection-specific menu.
        let chosenProject = finder.descendants(matching: .any).matching(
            NSPredicate(format: "title == %@ OR label CONTAINS %@", id, id)
        ).firstMatch
        XCTAssertTrue(chosenProject.waitForExistence(timeout: 8))
    }

    func testDraggingAndResizingRecordedInset() throws { try recordAndCheck(physical: false) }

    func testDraggingAndResizingBuiltInCameraOverWindow() throws {
        guard ProcessInfo.processInfo.environment["YOUREC_PIP_HARDWARE"] == "1" else {
            throw XCTSkip("Run scripts/test-mac-pip.sh --hardware on a Mac with an authorized camera.")
        }
        try recordAndCheck(physical: true)
    }

    private func recordAndCheck(physical: Bool) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--desktop-pip-regression"] + (physical ? ["--physical-pip-inputs"] : [])
        app.launchEnvironment["YOUREC_PIP_RUN"] = UUID().uuidString
        app.launch()
        addTeardownBlock {
            let record = app.buttons["desktop.record"]
            if record.exists, record.isEnabled, record.label == "Stop recording" {
                record.click()
                _ = app.staticTexts["fixture.movie"].waitForExistence(timeout: 10)
            }
            let finish = app.buttons["fixture.finish"]
            if finish.exists, finish.isEnabled { finish.click() }
            app.terminate()
        }

        let preview = app.otherElements["desktop.preview"]
        let inset = app.descendants(matching: .any)["desktop.pip"].firstMatch
        let record = app.buttons["desktop.record"]
        guard inset.waitForExistence(timeout: physical ? 180 : 12) else {
            let failure = app.staticTexts["fixture.failure"]
            XCTFail(failure.exists ? failure.label : "Both inputs must produce a frame before recording.")
            return
        }
        let bounds = CGRect(origin: .zero, size: preview.frame.size)
        let picture = AVMakeRect(aspectRatio: CGSize(width: 16, height: 9), insideRect: bounds)
        XCTAssertGreaterThan(picture.width, 200)
        let initial = CGRect(x: 0.68, y: 0.12, width: 0.18, height: 0.32)
        let moved = initial.offsetBy(dx: -0.55, dy: 0.45)
        let resized = CGRect(x: moved.minX, y: moved.minY - 0.20, width: moved.width + 0.1125, height: moved.height + 0.20)
        func coordinate(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
            preview.coordinate(withNormalizedOffset: CGVector(dx: (picture.minX+x*picture.width)/bounds.width,
                                                             dy: (picture.minY+y*picture.height)/bounds.height))
        }
        func verifyPreview(_ expected: CGRect) throws {
            let screenshot = preview.screenshot()
            add(XCTAttachment(screenshot: screenshot))
            let source = try XCTUnwrap(CGImageSourceCreateWithData(screenshot.pngRepresentation as CFData, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let scaleX = CGFloat(image.width) / bounds.width, scaleY = CGFloat(image.height) / bounds.height
            let crop = picture.applying(CGAffineTransform(scaleX: scaleX, y: scaleY))
            let fitted = try XCTUnwrap(image.cropping(to: crop))
            try Self.checkInset(fitted, expected: expected)
        }
        try verifyPreview(initial)
        record.click()
        XCTAssertEqual(record.label, "Stop recording")
        Thread.sleep(forTimeInterval: 0.6)
        coordinate(initial.midX, initial.midY).click(forDuration: 0.12, thenDragTo: coordinate(moved.midX, moved.midY))
        Thread.sleep(forTimeInterval: 0.4)
        try verifyPreview(moved)
        coordinate(moved.maxX, moved.minY).click(forDuration: 0.12, thenDragTo: coordinate(resized.maxX, resized.minY))
        Thread.sleep(forTimeInterval: 0.4)
        try verifyPreview(resized)
        Thread.sleep(forTimeInterval: 0.4)
        record.click()

        let saved = app.staticTexts["fixture.movie"]
        XCTAssertTrue(saved.waitForExistence(timeout: 15), app.debugDescription)
        let file = URL(fileURLWithPath: saved.label)
        XCTAssertEqual(file.deletingLastPathComponent().lastPathComponent, app.launchEnvironment["YOUREC_PIP_RUN"])
        let asset = AVURLAsset(url: file)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 320, height: 180)
        let duration = asset.duration.seconds
        XCTAssertGreaterThan(duration, 1.0)
        let phases = [initial, moved, resized]
        var next = 0, consecutive = 0
        for tick in 0..<Int(duration * 12) where next < phases.count {
            let time = CMTime(value: Int64(tick), timescale: 12)
            let image = try generator.copyCGImage(at: time, actualTime: nil)
            if let seen = try Self.insetBounds(image), Self.matches(seen, phases[next]) {
                consecutive += 1
                if consecutive == 3 {
                    print("Movie PiP phase", next, "at", time.seconds, "bounds", seen)
                    next += 1
                    consecutive = 0
                }
            } else {
                consecutive = 0
            }
        }
        XCTAssertEqual(next, phases.count, "The saved movie must hold initial → moved → enlarged in order")
        let end = CMTime(seconds: duration - 1.0 / 30, preferredTimescale: 600)
        let final = try generator.copyCGImage(at: end, actualTime: nil)
        try Self.checkInset(final, expected: resized)

    }

    // Measure the rendered pixels independently of the layout model.
    private static func insetBounds(_ image: CGImage) throws -> CGRect? {
        let w = 240, h = 135
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let ctx = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                    bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var xs = [Int](repeating: 0, count: w)
        var ys = [Int](repeating: 0, count: h)
        var chartPixels = 0
        // ScreenCaptureKit can frame a window with a dark shadow. All three
        // target positions are inside this border, even after resizing.
        let horizontal = (w / 12)..<(w - w / 12)
        let vertical = (h / 12)..<(h - h / 12)
        for y in vertical {
            for x in horizontal {
                let offset = (y * w + x) * 4
                let r = Int(bytes[offset]), g = Int(bytes[offset + 1]), b = Int(bytes[offset + 2])
                if min(r, b) > 12 && min(r, b) * 10 > g * 14 + 16 {
                    chartPixels += 1
                } else {
                    xs[x] += 1
                    ys[y] += 1
                }
            }
        }
        // Use the longest continuous run in each projection. A pointer,
        // resize handle or a thin strip at the window edge isn't an inset.
        func extent(_ projection: [Int], crossLength: Int) -> Range<Int>? {
            let threshold = max(crossLength / 10, projection.sorted()[projection.count * 9 / 10] / 2)
            var best = 0..<0, start = 0
            for i in 0...projection.count {
                if i == projection.count || projection[i] < threshold {
                    if i - start > best.count { best = start..<i }
                    start = i + 1
                }
            }
            return best.count > projection.count / 12 ? best : nil
        }
        guard chartPixels > horizontal.count * vertical.count / 2, let x = extent(xs, crossLength: h),
              let y = extent(ys, crossLength: w) else { return nil }
        return CGRect(x: CGFloat(x.lowerBound) / CGFloat(w), y: CGFloat(y.lowerBound) / CGFloat(h),
                      width: CGFloat(x.count) / CGFloat(w), height: CGFloat(y.count) / CGFloat(h))
    }

    private static func matches(_ seen: CGRect, _ expected: CGRect) -> Bool {
        zip([seen.minX,seen.minY,seen.maxX,seen.maxY], [expected.minX,expected.minY,expected.maxX,expected.maxY])
            .allSatisfy { abs($0-$1) < 0.023 }
    }
    private static func checkInset(_ image: CGImage, expected: CGRect,
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        let seen = try XCTUnwrap(try insetBounds(image), "No inset over the chart", file: file, line: line)
        XCTAssertTrue(matches(seen, expected), "Inset \(seen), expected \(expected)", file: file, line: line)
    }
}
#endif
