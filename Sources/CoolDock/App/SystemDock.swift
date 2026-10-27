import AppKit

/// Coordinates with the macOS Dock (auto-hide state, "replace" scenarios).
@MainActor
final class SystemDock {
    static let shared = SystemDock()
    private let domain = "com.apple.dock" as CFString
    private let backupKey = "NiceDockDockBackup"
    /// Receives every change NiceDock would make to the macOS Dock instead of making it (`--ui-probe`: the system Dock's
    /// preferences must never change while the probe clicks through Settings).
    var interceptor: ((String) -> Void)?

    var autohides: Bool {
        CFPreferencesAppSynchronize(domain)
        return (CFPreferencesCopyAppValue("autohide" as CFString, domain) as? Bool) ?? false
    }

    /// Height of the macOS Dock when it sits at the bottom (0 if hidden or on a side).
    func reservedBottom(on screen: NSScreen) -> CGFloat { screen.visibleFrame.minY - screen.frame.minY }

    func setAutohide(_ on: Bool) {
        if let interceptor { interceptor("setAutohide(\(on))"); return }
        CFPreferencesSetAppValue("autohide" as CFString, on as CFBoolean, domain)
        CFPreferencesAppSynchronize(domain)
        restartDock()
    }

    /// What a layout scenario asks of the macOS Dock: hidden while NiceDock replaces it, else as the user had it.
    enum Intent: Equatable { case hide, restore }

    nonisolated static func intent(for scenario: LayoutScenario) -> Intent {
        scenario == .replaceDock || scenario == .replaceAutoHide ? .hide : .restore
    }

    /// Applies the macOS Dock side-effects a layout scenario needs.
    func apply(for scenario: LayoutScenario) {
        switch Self.intent(for: scenario) {
        case .hide: hideSystemDock()
        case .restore: restore()
        }
    }

    private func hideSystemDock() {
        if let interceptor { interceptor("hide"); return }
        let defaults = UserDefaults.standard
        if defaults.dictionary(forKey: backupKey) == nil {
            CFPreferencesAppSynchronize(domain)
            var backup: [String: Any] = ["autohide": autohides]
            if let delay = CFPreferencesCopyAppValue("autohide-delay" as CFString, domain) as? Double { backup["autohide-delay"] = delay }
            defaults.set(backup, forKey: backupKey)
        }
        CFPreferencesSetAppValue("autohide" as CFString, kCFBooleanTrue, domain)
        CFPreferencesSetAppValue("autohide-delay" as CFString, 1000.0 as CFNumber, domain)
        CFPreferencesAppSynchronize(domain)
        restartDock()
    }

    /// Restores the macOS Dock to how it was before NiceDock replaced it.
    func restore() {
        let defaults = UserDefaults.standard
        guard let backup = defaults.dictionary(forKey: backupKey) else { return }
        if let interceptor { interceptor("restore"); return }
        CFPreferencesSetAppValue("autohide" as CFString, (backup["autohide"] as? Bool ?? false) as CFBoolean, domain)
        if let delay = backup["autohide-delay"] as? Double {
            CFPreferencesSetAppValue("autohide-delay" as CFString, delay as CFNumber, domain)
        } else {
            CFPreferencesSetAppValue("autohide-delay" as CFString, nil, domain)
        }
        CFPreferencesAppSynchronize(domain)
        defaults.removeObject(forKey: backupKey)
        restartDock()
    }

    private func restartDock() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["Dock"]
        try? p.run()
    }

    func openDockSettings() {
        Open.url("x-apple.systempreferences:com.apple.preference.dock")
    }
}
