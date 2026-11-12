import SwiftUI
import Security

@main
struct YouRecApp: App {
    @UIApplicationDelegateAdaptor(RecordingAppDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}


final class RecordingAppDelegate: NSObject, UIApplicationDelegate, URLSessionDelegate {
    // Earlier betas could leave an OS-managed transfer, a staging copy of the
    // movie and a channel credential after an upgrade. The originals live elsewhere.
    private static let retiredSessionID = "com.antirez.yourec.youtube.upload"
    private var retiringSession: URLSession?
    private var retiredEventsCompletion: (() -> Void)?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if application.isProtectedDataAvailable { cleanUpRetiredUploader() }
        return true
    }

    func applicationProtectedDataDidBecomeAvailable(_ application: UIApplication) {
        cleanUpRetiredUploader()
    }

    private func cleanUpRetiredUploader() {
        let flag = "retiredUploaderRemoved"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        let manager = FileManager.default
        let folder = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YouTubeTransfer", isDirectory: true)
        if manager.fileExists(atPath: folder.path) {
            cancelRetiredSession()
            do { try manager.removeItem(at: folder) } catch { return }
        }
        let status = SecItemDelete([kSecClass: kSecClassGenericPassword,
                                    kSecAttrService: "com.antirez.yourec.youtube",
                                    kSecAttrAccount: "channel"] as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            UserDefaults.standard.set(true, forKey: flag)
        }
    }

    private func cancelRetiredSession() {
        guard retiringSession == nil else { return }
        let config = URLSessionConfiguration.background(withIdentifier: Self.retiredSessionID)
        retiringSession = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        retiringSession?.invalidateAndCancel()
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == Self.retiredSessionID else { completionHandler(); return }
        retiredEventsCompletion = completionHandler
        cancelRetiredSession()
    }

    nonisolated func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        Task { @MainActor in
            self.retiringSession = nil
            self.retiredEventsCompletion?()
            self.retiredEventsCompletion = nil
        }
    }

    private static var awakeReasons = Set<String>()
    static func keepAwake(_ reason: String, active: Bool) {
        if active { awakeReasons.insert(reason) } else { awakeReasons.remove(reason) }
        UIApplication.shared.isIdleTimerDisabled = !awakeReasons.isEmpty
    }
    private static var allowedOrientations: UIInterfaceOrientationMask = .allButUpsideDown
    private static var pendingSaveTask: UIBackgroundTaskIdentifier = .invalid
    static func protectPendingSave() {
        guard pendingSaveTask == .invalid else { return }
        pendingSaveTask = UIApplication.shared.beginBackgroundTask(withName: "Finish recording save") {
            finishedPendingSave()
        }
    }
    static func finishedPendingSave() {
        guard pendingSaveTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(pendingSaveTask)
        pendingSaveTask = .invalid
    }
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.allowedOrientations
    }
    static func setOrientationLock(_ orientation: UIInterfaceOrientation?, animated: Bool = true) {
        switch orientation {
        case .portrait: allowedOrientations = .portrait
        case .landscapeLeft: allowedOrientations = .landscapeLeft
        case .landscapeRight: allowedOrientations = .landscapeRight
        case .portraitUpsideDown: allowedOrientations = .portraitUpsideDown
        default: allowedOrientations = .allButUpsideDown
        }
        let update = {
            for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
                for window in scene.windows {
                    window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
                    window.rootViewController?.presentedViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
                }
            }
        }
        if animated { update() } else { UIView.performWithoutAnimation(update) }
    }
}
