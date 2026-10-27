import AppKit
import Darwin
import Foundation

// The `--mcp` process is separate from the running app. Tool calls travel over a Unix-domain socket in
// Application Support (owner-only, peer uid checked) as one JSON line each way:
//
//     → {"v":1,"op":"tool","name":"add_widget","arguments":{…}}     ← {"ok":true,"result":{…}} | {"ok":false,"error":"…"}
//     → {"v":1,"op":"access"}                                         ← {"ok":true,"result":{"enabled":…,"allow_changes":…}}
//
// The app applies the change through AppStore (animated, persisted by its debounce). When no app answers,
// the MCP process runs the same `DockTools` on state.json under a file lock; the app loads it on next launch.

// MARK: - Socket plumbing

enum UnixSocket {
    static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: bytes)
            buf[bytes.count] = 0
        }
        return addr
    }

    private static func configure(_ fd: Int32, timeout: TimeInterval) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Connected socket, or nil when nobody listens at `path`.
    static func connect(_ path: String, timeout: TimeInterval) -> Int32? {
        guard var addr = address(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        configure(fd, timeout: timeout)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { close(fd); return nil }
        return fd
    }

    /// Listening socket at `path`, readable and writable by this user only.
    static func listen(_ path: String) throws -> Int32 {
        guard var addr = address(path) else { throw ToolFailure("Socket path too long: \(path)") }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ToolFailure("socket() failed: \(errno)") }
        let previous = umask(0o077)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(previous)
        guard bound == 0 else { let e = errno; close(fd); throw ToolFailure("bind() failed: \(e)") }
        chmod(path, 0o600)
        guard Darwin.listen(fd, 16) == 0 else { let e = errno; close(fd); unlink(path); throw ToolFailure("listen() failed: \(e)") }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        return fd
    }

    static func accept(_ listener: Int32, timeout: TimeInterval) -> Int32? {
        let fd = Darwin.accept(listener, nil, nil)
        guard fd >= 0 else { return nil }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)   // accepted sockets inherit O_NONBLOCK on BSD
        configure(fd, timeout: timeout)
        return fd
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var p = raw.baseAddress else { return true }
            var left = raw.count
            while left > 0 {
                let n = write(fd, p, left)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { return false }
                p += n
                left -= n
            }
            return true
        }
    }

    /// Bytes up to the first newline (or EOF); nil on timeout, error or when `limit` is exceeded.
    static func readLine(_ fd: Int32, limit: Int) -> Data? {
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return n == 0 && !out.isEmpty ? out : nil }
            if let nl = buffer[0..<n].firstIndex(of: 0x0A) {
                out.append(contentsOf: buffer[0..<nl])
                return out
            }
            out.append(contentsOf: buffer[0..<n])
            if out.count > limit { return nil }
        }
    }

    static func isOwnUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0, gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
    }
}

/// App side: accepts one request per connection and answers with `handler` (called on a background queue).
final class AssistantSocketServer: @unchecked Sendable {
    let path: String
    private let handler: (JSONValue) -> JSONValue
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?
    private let acceptQueue = DispatchQueue(label: "app.cooldock.assistant.accept")
    private let workQueue = DispatchQueue(label: "app.cooldock.assistant.work", attributes: .concurrent)

    init(path: String, handler: @escaping (JSONValue) -> JSONValue) {
        self.path = path
        self.handler = handler
    }

    func start() throws {
        if let other = UnixSocket.connect(path, timeout: 1) {
            close(other)
            throw ToolFailure("Another CoolDock already answers on \(path).")
        }
        let fd = try UnixSocket.listen(path)
        listener = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    func stop() {
        guard let source else { return }
        source.cancel()
        self.source = nil
        unlink(path)
    }

    private func acceptPending() {
        while let client = UnixSocket.accept(listener, timeout: 15) {
            workQueue.async { [self] in serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        guard UnixSocket.isOwnUser(client), let line = UnixSocket.readLine(client, limit: 1 << 20) else { return }
        let reply: JSONValue
        if let request = try? JSONValue.parse(line) {
            reply = handler(request)
        } else {
            reply = ["ok": false, "error": "Malformed request."]
        }
        _ = UnixSocket.writeAll(client, reply.encoded() + Data([0x0A]))
    }
}

/// MCP side: one request, one reply.
struct AssistantAppClient {
    enum Outcome {
        case unavailable
        case reply(JSONValue)
    }

    let path: String
    var timeout: TimeInterval = 15

    func send(_ request: JSONValue) throws -> Outcome {
        guard FileManager.default.fileExists(atPath: path), let fd = UnixSocket.connect(path, timeout: timeout) else { return .unavailable }
        defer { close(fd) }
        guard UnixSocket.writeAll(fd, request.encoded() + Data([0x0A])) else { throw ToolFailure("Couldn't send the request to CoolDock.") }
        guard let line = UnixSocket.readLine(fd, limit: 16 << 20) else { throw ToolFailure("CoolDock didn't answer in time. Try again.") }
        return .reply(try JSONValue.parse(line))
    }
}

// MARK: - Request handling (shared by the app and tests)

enum AssistantService {
    static func failure(_ message: String) -> JSONValue { ["ok": false, "error": .string(message)] }

    /// Answers one bridge request against `state`. Returns the reply and, for tool calls that ran, their outcome.
    static func respond(_ request: JSONValue, state: inout DockState, source: DockTools.Source) -> (reply: JSONValue, outcome: ToolOutcome?) {
        switch request["op"]?.stringValue {
        case "access":
            let s = state.settings
            return (["ok": true, "result": ["enabled": .bool(s.assistantEnabled), "allow_changes": .bool(s.assistantAllowsChanges)]], nil)
        case "tool":
            guard let name = request["name"]?.stringValue else { return (failure("Missing tool name."), nil) }
            do {
                let outcome = try DockTools.run(name, request["arguments"]?.objectValue ?? [:], state: &state, source: source)
                return (["ok": true, "result": outcome.result], outcome)
            } catch let f as ToolFailure {
                return (failure(f.message), nil)
            } catch {
                return (failure(error.localizedDescription), nil)
            }
        default:
            return (failure("Unknown request."), nil)
        }
    }

    static func unwrap(_ reply: JSONValue) throws -> JSONValue {
        if reply["ok"]?.boolValue == true { return reply["result"] ?? .null }
        throw ToolFailure(reply["error"]?.stringValue ?? "CoolDock returned an unexpected answer.")
    }
}

/// Running app: listens while CoolDock runs and applies tool calls through AppStore on the main actor.
@MainActor
enum AssistantBridge {
    private static var server: AssistantSocketServer?

    static func start() {
        guard server == nil else { return }
        AppPaths.ensureSupportDirectory()
        let server = AssistantSocketServer(path: AppPaths.assistantSocket) { request in
            DispatchQueue.main.sync { MainActor.assumeIsolated { AssistantBridge.handle(request) } }
        }
        do {
            try server.start()
            self.server = server
        } catch {
            NSLog("CoolDock AI Assistant: \(error)")
        }
    }

    static func stop() {
        server?.stop()
        server = nil
    }

    static func handle(_ request: JSONValue) -> JSONValue {
        let store = AppStore.shared
        var state = store.dockState
        let (reply, outcome) = AssistantService.respond(request, state: &state, source: .app)
        if let outcome, outcome.changed { store.applyAssistantState(state, effects: outcome.effects) }
        return reply
    }
}

// MARK: - Offline path: state.json

/// Reads and writes CoolDock's saved state exactly like AppStore does, under an exclusive lock.
struct DockStateFile {
    let url: URL

    func load() throws -> DockState {
        guard FileManager.default.fileExists(atPath: url.path) else { return .fresh() }
        guard let data = try? Data(contentsOf: url), var state = try? JSONDecoder().decode(DockState.self, from: data), !state.profiles.isEmpty else {
            throw ToolFailure("CoolDock's saved settings (\(url.path)) couldn't be read. Open CoolDock once, then try again.")
        }
        if !state.profiles.contains(where: { $0.id == state.activeProfileID }) { state.activeProfileID = state.profiles[0].id }
        return state
    }

    func save(_ state: DockState) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try enc.encode(state).write(to: url, options: .atomic)
        } catch {
            throw ToolFailure("Couldn't save CoolDock's settings: \(error.localizedDescription)")
        }
    }

    func withLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path + ".lock", O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return try body() }
        defer { flock(fd, LOCK_UN); close(fd) }
        flock(fd, LOCK_EX)
        return try body()
    }
}

// MARK: - Routing (MCP process)

/// Sends each tool call to the running app, or applies it to state.json when CoolDock isn't running.
/// Wallpapers are painted in the MCP process so the Dock never stalls.
struct AssistantRouter {
    var stateFile: DockStateFile
    var socketPath: String
    var wallpaperDirectory: URL
    var screenSize: () -> (width: Int, height: Int)
    var setDesktop: (URL) throws -> Int
    var timeout: TimeInterval = 15

    static func live() -> AssistantRouter {
        AssistantRouter(stateFile: DockStateFile(url: AppPaths.stateFile), socketPath: AppPaths.assistantSocket,
                        wallpaperDirectory: AppPaths.wallpapers, screenSize: WallpaperStudio.mainDisplayPixelSize,
                        setDesktop: { url in try MainActor.assumeIsolated { try DesktopPicture.setOnAllScreens(url) } })
    }

    private var client: AssistantAppClient { AssistantAppClient(path: socketPath, timeout: timeout) }

    func call(_ name: String, _ arguments: [String: JSONValue]) throws -> JSONValue {
        guard let tool = AssistantTools.named(name) else { throw ToolFailure("Unknown tool '\(name)'.") }
        if tool.isWallpaper { return try wallpaper(tool, arguments) }
        switch try client.send(["v": 1, "op": "tool", "name": .string(name), "arguments": .object(arguments)]) {
        case .reply(let reply):
            return try AssistantService.unwrap(reply)
        case .unavailable:
            guard tool.access == .change else {
                var state = try stateFile.load()
                return try DockTools.run(name, arguments, state: &state, source: .savedState).result
            }
            return try stateFile.withLock {
                var state = try stateFile.load()
                let outcome = try DockTools.run(name, arguments, state: &state, source: .savedState)
                if outcome.changed { try stateFile.save(state) }
                return outcome.result
            }
        }
    }

    func access() throws -> (enabled: Bool, allowChanges: Bool) {
        switch try client.send(["v": 1, "op": "access"]) {
        case .reply(let reply):
            let r = try AssistantService.unwrap(reply)
            return (r["enabled"]?.boolValue ?? false, r["allow_changes"]?.boolValue ?? false)
        case .unavailable:
            let s = try stateFile.load().settings
            return (s.assistantEnabled, s.assistantAllowsChanges)
        }
    }

    func wallpaper(_ tool: AssistantTool, _ arguments: [String: JSONValue]) throws -> JSONValue {
        let access = try access()
        try DockTools.gate(tool, enabled: access.enabled, allowChanges: access.allowChanges)
        let request = try WallpaperRequest(arguments: arguments)
        let size = screenSize()
        let output = try autoreleasepool {
            try WallpaperStudio.generate(request, width: size.width, height: size.height, directory: wallpaperDirectory)
        }
        var result: [String: JSONValue] = [
            "path": .string(output.url.path), "width": .int(output.width), "height": .int(output.height),
            "description": .string(request.summary), "parameters": request.parametersJSON
        ]
        if tool.name == "set_wallpaper" {
            let displays = try setDesktop(output.url)
            result["displays"] = .int(displays)
            result["message"] = .string("Wallpaper set on \(displays) display\(displays == 1 ? "" : "s").")
        } else {
            result["message"] = "Preview saved. Call set_wallpaper with the same parameters to use it."
        }
        return .object(result)
    }
}

@MainActor
enum DesktopPicture {
    /// Sets `url` as the desktop picture of every display (current Space), filling the screen.
    static func setOnAllScreens(_ url: URL) throws -> Int {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { throw ToolFailure("No display found.") }
        let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue, .allowClipping: true
        ]
        do {
            for screen in screens { try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options) }
        } catch {
            throw ToolFailure("macOS refused the wallpaper: \(error.localizedDescription)")
        }
        return screens.count
    }
}
