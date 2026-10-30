import Foundation
@testable import CoolDock

/// Shared fixtures for the AI Assistant (MCP) tests.
enum AssistantFixture {
    /// GitHub Actions (and most CI) sets CI=true.
    static var onCI: Bool { ProcessInfo.processInfo.environment["CI"] != nil }

    static func state(enabled: Bool = true, allowChanges: Bool = true) -> DockState {
        var s = DockState.fresh()
        s.settings.assistantEnabled = enabled
        s.settings.assistantAllowsChanges = allowChanges
        return s
    }

    /// Fresh short temp directory (Unix socket paths must stay under 104 bytes).
    static func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cd-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func write(_ state: DockState, to url: URL) throws {
        try DockStateFile(url: url).save(state)
    }

    /// Runs a tool on `state` and returns the tool error message, or nil if it succeeded.
    static func failure(_ name: String, _ args: [String: JSONValue] = [:], on state: inout DockState) -> String? {
        do {
            _ = try DockTools.run(name, args, state: &state, source: .app)
            return nil
        } catch let f as ToolFailure {
            return f.message
        } catch {
            return "\(error)"
        }
    }

    static func run(_ name: String, _ args: [String: JSONValue] = [:], on state: inout DockState) throws -> ToolOutcome {
        try DockTools.run(name, args, state: &state, source: .app)
    }

    /// Router that never touches the user's files or desktop.
    static func router(dir: URL, socket: String? = nil, desktop: @escaping (URL) throws -> Int = { _ in
        throw ToolFailure("setDesktop must not run in this test")
    }) -> AssistantRouter {
        AssistantRouter(stateFile: DockStateFile(url: dir.appendingPathComponent("state.json")),
                        socketPath: socket ?? dir.appendingPathComponent("assistant.sock").path,
                        wallpaperDirectory: dir.appendingPathComponent("Wallpapers", isDirectory: true),
                        screenSize: { (96, 60) }, setDesktop: desktop, timeout: 5)
    }

    static let mutatingTools = AssistantTools.all.filter { $0.access == .change }.map(\.name)
    static let readingTools = AssistantTools.all.filter { $0.access != .change }.map(\.name)
}

/// Thread-safe box for state shared with the socket server's background queue.
final class LockedState: @unchecked Sendable {
    private let lock = NSLock()
    private var value: DockState
    init(_ value: DockState) { self.value = value }

    func respond(_ request: JSONValue) -> JSONValue {
        lock.lock(); defer { lock.unlock() }
        return AssistantService.respond(request, state: &value, source: .app).reply
    }

    var current: DockState { lock.lock(); defer { lock.unlock() }; return value }
}
