import AppKit
import Sparkle

/// Sparkle, checking the appcast published with each GitHub release. Updates are verified with the
/// EdDSA key in Info.plist (`SUPublicEDKey`); the app itself is only ad-hoc signed.
@MainActor
final class AppUpdater: NSObject, SPUStandardUserDriverDelegate {
    static let shared = AppUpdater()

    private var controller: SPUStandardUpdaterController!

    /// False when running from `swift run`, where there is no bundle to replace.
    static var isAvailable: Bool { Bundle.main.bundlePath.hasSuffix(".app") }

    private override init() {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: Self.isAvailable, updaterDelegate: nil, userDriverDelegate: self
        )
    }

    var canCheck: Bool { Self.isAvailable && controller.updater.canCheckForUpdates }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    @objc func checkNow() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    // MARK: SPUStandardUserDriverDelegate

    /// NiceDock has no Dock icon, so bring it forward before Sparkle shows a window.
    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        Task { @MainActor in NSApp.activate(ignoringOtherApps: true) }
    }
}
