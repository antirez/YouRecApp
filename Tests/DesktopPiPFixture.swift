#if DEBUG && targetEnvironment(macCatalyst)
import SwiftUI
import ScreenCaptureKit
import CoreImage
import Darwin

/// The recorder view and writer are production code. Only the source selection
/// and destination are under test control. Normal projects are never opened.
struct DesktopPiPFixture: View {
    let id: UUID
    static var runID: UUID? {
        guard CommandLine.arguments.contains("--desktop-pip-regression"),
              let raw = ProcessInfo.processInfo.environment["YOUREC_PIP_RUN"] else { return nil }
        return UUID(uuidString: raw)
    }
    @StateObject private var camera = DesktopRecorder()
    @State private var movie: URL?
    @State private var failure: String?
    private var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("YouRecPiPRegression", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }
    var body: some View {
        VStack(spacing: 0) {
            DesktopRecorderView(camera: camera, project: nil, start: {
                camera.start(in: folder, projectID: id, destination: .append)
            }, newProject: {}, projects: {}, edit: {}, inserting: false)
            if let failure = failure ?? camera.error {
                Text(failure).accessibilityIdentifier("fixture.failure")
            }
            if let movie {
                Text(movie.path).accessibilityIdentifier("fixture.movie")
            }
            Button("Finish test") {
                camera.suspend()
                try? FileManager.default.removeItem(at: folder)
                movie = nil
            }.accessibilityIdentifier("fixture.finish")
        }
        .task {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                camera.onSegment = { url, indexed in movie = url; indexed(true) }
                if CommandLine.arguments.contains("--physical-pip-inputs") {
                    let filter = try await chartFilter()
                    try await camera.preparePiPRegression(chart: filter, cameraFrame: nil, screenFrame: nil)
                } else {
                    let screen = try solid(red: 0.92, green: 0.05, blue: 0.87)
                    let inset = try solid(red: 0.07, green: 0.85, blue: 0.14)
                    try await camera.preparePiPRegression(chart: nil, cameraFrame: inset, screenFrame: screen)
                }
            } catch { failure = error.localizedDescription }
        }
    }

    private func solid(red: CGFloat, green: CGFloat, blue: CGFloat) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32BGRA, attributes, &buffer) == kCVReturnSuccess,
              let buffer else { throw CocoaError(.coderInvalidValue) }
        let bounds = CGRect(x: 0, y: 0, width: 640, height: 360)
        let color = CIColor(red: red, green: green, blue: blue)
        CIContext().render(CIImage(color: color).cropped(to: bounds), to: buffer, bounds: bounds,
                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return buffer
    }

    @MainActor private func chartFilter() async throws -> SCContentFilter {
        // Only the hardware-test script places this small AppKit helper in the
        // Debug app. Resolve the exact window from Apple's own-process list.
        guard let frameworks = Bundle.main.privateFrameworksURL,
              let handle = dlopen(frameworks.appendingPathComponent("DesktopPiPChart.dylib").path, RTLD_NOW),
              let entry = dlsym(handle, "YouRecOpenChart") else {
            throw NSError(domain: "YouRecTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing hardware test chart"])
        }
        let openChart = unsafeBitCast(entry, to: (@convention(c) () -> UInt32).self)
        let openChartID = openChart()
        var windowIDs: [CGWindowID] = []
        for _ in 0..<50 {
            let owned = try await SCShareableContent.currentProcess.windows
            windowIDs = owned.map(\.windowID)
            if let window = owned.first(where: { $0.windowID == openChartID }) {
                return SCContentFilter(desktopIndependentWindow: window)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NSError(domain: "YouRecTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not find chart window \(openChartID) among \(windowIDs)"])
    }
}
#endif
