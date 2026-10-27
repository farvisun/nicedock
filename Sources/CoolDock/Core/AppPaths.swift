import Foundation

/// Files CoolDock keeps in Application Support. One place so the app, the `--mcp` server and the tests agree.
///
/// `COOLDOCK_SUPPORT_DIR` (environment) or `AppPaths.overrideDirectory` (tests) replaces
/// `~/Library/Application Support/CoolDock`, so tests and the end-to-end MCP run never touch the user's state.
enum AppPaths {
    nonisolated(unsafe) static var overrideDirectory: URL?

    static var supportDirectory: URL {
        if let overrideDirectory { return overrideDirectory }
        if let env = ProcessInfo.processInfo.environment["COOLDOCK_SUPPORT_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CoolDock", isDirectory: true)
    }

    static var stateFile: URL { supportDirectory.appendingPathComponent("state.json") }

    static var wallpapers: URL { supportDirectory.appendingPathComponent("Wallpapers", isDirectory: true) }

    /// Unix-domain socket the running app listens on for AI Assistant commands (owner-only, 0600).
    /// `sun_path` holds 104 bytes on macOS; very long support paths fall back to a per-user name in /tmp.
    static var assistantSocket: String { socketPath(in: supportDirectory) }

    static func socketPath(in directory: URL) -> String {
        let path = directory.appendingPathComponent("assistant.sock").path
        if path.utf8.count < 100 { return path }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in directory.path.utf8 { hash = (hash ^ UInt64(b)) &* 0x0000_0100_0000_01B3 }
        return "/tmp/cooldock-\(getuid())-\(String(hash, radix: 36)).sock"
    }

    static func ensureSupportDirectory() {
        try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
    }
}
