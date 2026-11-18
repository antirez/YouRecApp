import XCTest
import ImageIO

final class PlaybackEndUITests: XCTestCase {
    private func activate(_ button: XCUIElement) {
        #if targetEnvironment(macCatalyst)
        button.click()
        #else
        button.tap()
        #endif
    }

    // Read the picture itself, away from transport controls and letterboxing.
    private func centerColor(_ preview: XCUIElement) throws -> [Int] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(preview.screenshot().pngRepresentation as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let center = try XCTUnwrap(image.cropping(to: bounds.insetBy(dx: bounds.width * 0.38, dy: bounds.height * 0.38)))
        var samples = [UInt8](repeating: 0, count: 4)
        try samples.withUnsafeMutableBytes { bytes in
            let ctx = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            ctx.draw(center, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return samples.prefix(3).map(Int.init)
    }

    func testLastSourceFrameAtPlaybackEnd() throws { try checkEnding() }
    func testLastCompositedFrameAtPlaybackEnd() throws { try checkEnding(["--graded-ending"]) }
    func testAudioOnlyTailStaysBlack() throws { try checkEnding(["--audio-only-ending"]) }

    private func checkEnding(_ options: [String] = []) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let session = UUID().uuidString
        app.launchEnvironment["YOUREC_RECOVERY_TEST_RUN"] = session
        app.launchEnvironment["YOUREC_LIBRARY_TEST_RUN"] = session
        app.launchArguments = ["--editor-preview", "--reset-ui-fixture", "--playback-end-fixture"] + options
        app.launch()
        let next = app.buttons["transport.nextChange"], previous = app.buttons["transport.previousChange"]
        let play = app.buttons["Play"], pause = app.buttons["Pause playback"]
        let clock = app.staticTexts["editor.playhead"], duration = app.staticTexts["editor.duration"]
        let preview = app.descendants(matching: .any)["editor.preview"].firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 30))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: next)
        waitForExpectations(timeout: 30)
        XCTAssertEqual(duration.label, "0:04.03")
        XCTAssertEqual(clock.label, "0:00.00")

        func waitForEnd() {
            expectation(for: NSPredicate(format: "label == %@", duration.label), evaluatedWith: clock)
            waitForExpectations(timeout: 10)
        }
        func assertFinalPicture(_ view: XCUIElement, line: UInt = #line) throws {
            let rgb = try centerColor(view)
            if options.contains("--audio-only-ending") {
                XCTAssertLessThan(rgb.max()!, 10, "The audio tail should be black: \(rgb)", line: line)
            } else if options.contains("--graded-ending") {
                XCTAssertGreaterThan(rgb.min()!, 100, "The last frame should have the bright mono grade: \(rgb)", line: line)
                XCTAssertLessThan(rgb.max()! - rgb.min()!, 10, "The last frame should be neutral gray: \(rgb)", line: line)
            } else {
                XCTAssertGreaterThan(rgb[1], 170, "Expected the green final frame: \(rgb)", line: line)
                XCTAssertGreaterThan(rgb[1] - max(rgb[0], rgb[2]), 100, "Expected green to dominate the final frame: \(rgb)", line: line)
            }
        }
        activate(play)
        waitForEnd()
        XCTAssertTrue(play.waitForExistence(timeout: 4))
        try assertFinalPicture(preview)
        activate(app.buttons["editor.fullPreview"])
        let full = app.descendants(matching: .any)["fullPreview.preview"].firstMatch
        XCTAssertTrue(full.waitForExistence(timeout: 5))
        try assertFinalPicture(full)
        activate(app.buttons["Done"])
        XCTAssertTrue(previous.waitForExistence(timeout: 5))
        activate(previous)
        XCTAssertEqual(clock.label, "0:04.00")
        try assertFinalPicture(preview)
        activate(next)
        waitForEnd()
        try assertFinalPicture(preview)
        activate(play)
        XCTAssertTrue(pause.waitForExistence(timeout: 4))
        activate(pause)
        XCTAssertNotEqual(clock.label, duration.label, "Replay should start at the beginning")
    }
}
