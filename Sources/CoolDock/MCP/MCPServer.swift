import Darwin
import Foundation

/// JSON-RPC error with a standard code.
struct RPCError: Error, Equatable {
    let code: Int
    let message: String

    static let parseError = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602
    static let internalError = -32603
}

/// `NiceDock --mcp`: Model Context Protocol server over stdio (JSON-RPC 2.0, one message per line).
///
/// Starts before NSApplication exists, never opens a window and never asks for a permission; tools that
/// touch the dock talk to the running app (see `AssistantRouter`).
final class MCPServer {
    static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    static let serverName = "nicedock"

    static let instructions = """
    NiceDock is the user's second Dock with live widgets on this Mac. Start with get_dock (current settings, \
    profiles and widget ids) and list_widget_kinds (kinds and their settings). Tools are read-only until the user \
    turns on Allow Changes in NiceDock Settings → Privacy & Permissions → AI Assistant. set_wallpaper paints a \
    wallpaper from mood, style, color, time_of_day, season and weather and applies it; preview_wallpaper only saves it.
    """

    private(set) var protocolVersion = protocolVersions[0]
    private(set) var initialized = false
    private let call: (String, [String: JSONValue]) throws -> JSONValue

    init(call: @escaping (String, [String: JSONValue]) throws -> JSONValue) {
        self.call = call
    }

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    // MARK: Framing

    /// One input line → one output line (nil for notifications, responses and blank lines).
    func handle(line: String) -> String? {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard let message = try? JSONValue.parse(text) else {
            return Self.error(id: .null, RPCError(code: RPCError.parseError, message: "Parse error: not valid JSON")).text()
        }
        return handle(message: message)?.text()
    }

    func handle(message: JSONValue) -> JSONValue? {
        if case .array(let batch) = message {
            guard !batch.isEmpty else { return Self.error(id: .null, RPCError(code: RPCError.invalidRequest, message: "Invalid Request: empty batch")) }
            let replies = batch.compactMap(handleOne)
            return replies.isEmpty ? nil : .array(replies)
        }
        return handleOne(message)
    }

    private func handleOne(_ message: JSONValue) -> JSONValue? {
        guard case .object(let o) = message else {
            return Self.error(id: .null, RPCError(code: RPCError.invalidRequest, message: "Invalid Request: expected a JSON-RPC object"))
        }
        let id = o["id"]
        if let id, id.stringValue == nil, id.doubleValue == nil, id != .null {
            return Self.error(id: .null, RPCError(code: RPCError.invalidRequest, message: "Invalid Request: id must be a string or a number"))
        }
        guard o["jsonrpc"]?.stringValue == "2.0" else {
            return Self.error(id: id ?? .null, RPCError(code: RPCError.invalidRequest, message: "Invalid Request: jsonrpc must be \"2.0\""))
        }
        guard let method = o["method"]?.stringValue else {
            // A response to a request we never sent: nothing to answer.
            if o["result"] != nil || o["error"] != nil { return nil }
            return Self.error(id: id ?? .null, RPCError(code: RPCError.invalidRequest, message: "Invalid Request: method is missing"))
        }
        let isNotification = id == nil
        let params: [String: JSONValue]
        switch o["params"] {
        case nil, .null?: params = [:]
        case .object(let p)?: params = p
        default:
            return isNotification ? nil : Self.error(id: id!, RPCError(code: RPCError.invalidParams, message: "Invalid params: params must be an object"))
        }
        do {
            let result = try dispatch(method, params, isNotification: isNotification)
            return isNotification ? nil : ["jsonrpc": "2.0", "id": id!, "result": result]
        } catch let e as RPCError {
            return isNotification ? nil : Self.error(id: id!, e)
        } catch {
            return isNotification ? nil : Self.error(id: id!, RPCError(code: RPCError.internalError, message: "Internal error: \(error.localizedDescription)"))
        }
    }

    static func error(id: JSONValue, _ e: RPCError) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .int(e.code), "message": .string(e.message)]]
    }

    // MARK: Methods

    private func dispatch(_ method: String, _ params: [String: JSONValue], isNotification: Bool) throws -> JSONValue {
        switch method {
        case "initialize": return try initialize(params)
        case "notifications/initialized":
            initialized = true
            return .null
        case "ping": return .object([:])
        case "tools/list": return AssistantTools.listing
        case "tools/call": return try toolCall(params)
        default:
            if method.hasPrefix("notifications/") { return .null }   // cancelled, progress, roots/list_changed…: nothing to do
            throw RPCError(code: RPCError.methodNotFound, message: "Method not found: \(method)")
        }
    }

    private func initialize(_ params: [String: JSONValue]) throws -> JSONValue {
        guard let requested = params["protocolVersion"]?.stringValue else {
            throw RPCError(code: RPCError.invalidParams, message: "Invalid params: protocolVersion is required")
        }
        // Echo a version we speak; otherwise offer our latest and let the client decide.
        protocolVersion = Self.protocolVersions.contains(requested) ? requested : Self.protocolVersions[0]
        return [
            "protocolVersion": .string(protocolVersion),
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": .string(Self.serverName), "title": "NiceDock", "version": .string(Self.version)],
            "instructions": .string(Self.instructions)
        ]
    }

    private func toolCall(_ params: [String: JSONValue]) throws -> JSONValue {
        guard let name = params["name"]?.stringValue else {
            throw RPCError(code: RPCError.invalidParams, message: "Invalid params: name is required")
        }
        guard AssistantTools.named(name) != nil else {
            throw RPCError(code: RPCError.invalidParams, message: "Unknown tool: \(name)")
        }
        let arguments: [String: JSONValue]
        switch params["arguments"] {
        case nil, .null?: arguments = [:]
        case .object(let a)?: arguments = a
        default: throw RPCError(code: RPCError.invalidParams, message: "Invalid params: arguments must be an object")
        }
        do {
            let result = try call(name, arguments)
            return Self.toolResult(result.text(), isError: false)
        } catch let failure as ToolFailure {
            return Self.toolResult(failure.message, isError: true)
        } catch {
            return Self.toolResult(error.localizedDescription, isError: true)
        }
    }

    static func toolResult(_ text: String, isError: Bool) -> JSONValue {
        ["content": [["type": "text", "text": .string(text)]], "isError": .bool(isError)]
    }

    // MARK: stdio

    /// Runs until stdin closes. Logs go to stderr; stdout carries only protocol messages.
    static func runStdio() -> Never {
        signal(SIGPIPE, SIG_IGN)
        let router = AssistantRouter.live()
        let server = MCPServer(call: router.call)
        fputs("NiceDock MCP server \(version) ready on stdio\n", stderr)
        while let line = readLine(strippingNewline: true) {
            autoreleasepool {
                if let reply = server.handle(line: line) { writeOut(reply + "\n") }
            }
        }
        exit(0)
    }

    private static func writeOut(_ text: String) {
        let data = Data(text.utf8)
        data.withUnsafeBytes { raw in
            guard var p = raw.baseAddress else { return }
            var left = raw.count
            while left > 0 {
                let n = write(STDOUT_FILENO, p, left)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { exit(0) }   // client went away
                p += n
                left -= n
            }
        }
    }
}
