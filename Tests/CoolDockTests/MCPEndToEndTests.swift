import Foundation
import Testing
@testable import CoolDock

/// Spawns the built `NiceDock --mcp` binary with a temporary HOME and support directory and talks to it over
/// stdin/stdout like an MCP client. Set `COOLDOCK_MCP_TRANSCRIPT=<file>` / `COOLDOCK_MCP_TRANSCRIPT_CHANGES=<file>` to
/// save the exchanged JSON.
// Spawning the server under the test runner's parallel load hangs on GitHub's macOS runners (it starts fine on
// its own there, see the "MCP server starts" CI step), so these run locally only.
@Suite(.disabled(if: AssistantFixture.onCI, "spawns NiceDock --mcp; runs locally only"))
struct MCPEndToEndTests {
    static var binary: URL? {
        var candidates: [URL] = []
        if let bundle = Bundle.allBundles.first(where: { $0.bundlePath.hasSuffix(".xctest") }) {
            candidates.append(bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("NiceDock"))
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        candidates += [".build/debug/CoolDock", ".build/arm64-apple-macosx/debug/CoolDock", ".build/x86_64-apple-macosx/debug/CoolDock"]
            .map { root.appendingPathComponent($0) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Writes `lines` to the server's stdin, closes it and returns stdout lines (the server exits on EOF).
    static func exchange(_ lines: [String], home: URL) throws -> (replies: [String], status: Int32, stderr: String) {
        let exe = try #require(binary, "build the NiceDock product first (swift build)")
        let process = Process()
        process.executableURL = exe
        process.arguments = ["--mcp"]
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home.path
        env["COOLDOCK_SUPPORT_DIR"] = home.appendingPathComponent("Library/Application Support/NiceDock").path
        process.environment = env
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        // Drain both pipes while writing so a large reply can never block the server.
        let out = Drain(output.fileHandleForReading), err = Drain(errors.fileHandleForReading)
        input.fileHandleForWriting.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        try input.fileHandleForWriting.close()
        let finished = out.wait(30) && err.wait(5)
        if !finished { process.terminate(); Issue.record("NiceDock --mcp did not exit after stdin closed") }
        process.waitUntilExit()
        return (out.text.split(separator: "\n").map(String.init), process.terminationStatus, err.text)
    }

    /// Reads a pipe to EOF on a background queue.
    final class Drain: @unchecked Sendable {
        private var data = Data()
        private let done = DispatchSemaphore(value: 0)

        init(_ handle: FileHandle) {
            DispatchQueue.global().async { [self] in
                data = handle.readDataToEndOfFile()
                done.signal()
            }
        }

        func wait(_ seconds: Double) -> Bool { done.wait(timeout: .now() + seconds) == .success }
        var text: String { String(decoding: data, as: UTF8.self) }
    }

    @Test func initializeListAndGetDock() throws {
        let home = AssistantFixture.tempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let support = home.appendingPathComponent("Library/Application Support/NiceDock")
        var state = AssistantFixture.state(enabled: true, allowChanges: false)
        state.settings.dockStyle = .lightGlass
        try AssistantFixture.write(state, to: support.appendingPathComponent("state.json"))
        let before = try Data(contentsOf: support.appendingPathComponent("state.json"))

        let requests = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"nicedock-e2e","version":"1.0"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_dock","arguments":{}}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"add_widget","arguments":{"kind":"flipClock"}}}"#,
            #"{"jsonrpc":"2.0","id":5,"method":"ping"}"#
        ]
        let (replies, status, stderr) = try Self.exchange(requests, home: home)
        #expect(status == 0)
        #expect(stderr.contains("ready"))
        #expect(replies.count == 5, "one reply per request, none for the notification")
        let parsed = try replies.map(JSONValue.parse)
        #expect(parsed.map { $0["id"] } == [1, 2, 3, 4, 5])

        #expect(parsed[0]["result"]?["protocolVersion"] == "2025-06-18")
        #expect(parsed[0]["result"]?["serverInfo"]?["name"] == "nicedock")

        let tools = try #require(parsed[1]["result"]?["tools"]?.arrayValue)
        #expect(tools.count == AssistantTools.all.count)
        #expect(tools.allSatisfy { $0["inputSchema"]?["type"] == "object" })

        #expect(parsed[2]["result"]?["isError"] == false)
        let dockText = try #require(parsed[2]["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
        let dock = try JSONValue.parse(dockText)
        #expect(dock["source"] == "saved_state")
        #expect(dock["appearance"]?["dock_style"] == "lightGlass")
        #expect(dock["profiles"]?.arrayValue?.count == 3)
        #expect(dock["profiles"]?.arrayValue?.first?["widgets"]?.arrayValue?.first?["id"]?.stringValue == state.profiles[0].widgets[0].id.uuidString)

        #expect(parsed[3]["result"]?["isError"] == true)
        #expect(parsed[3]["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue?.contains("read-only") == true)
        #expect(parsed[4]["result"] == .object([:]))
        #expect(try Data(contentsOf: support.appendingPathComponent("state.json")) == before, "read-only never writes")

        Self.saveTranscript(requests, replies, env: "COOLDOCK_MCP_TRANSCRIPT")
    }

    /// With Allow Changes on and NiceDock not running, changes land in state.json; previews never touch the desktop.
    @Test func changesWithoutTheRunningApp() throws {
        let home = AssistantFixture.tempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let support = home.appendingPathComponent("Library/Application Support/NiceDock")
        let state = AssistantFixture.state(enabled: true, allowChanges: true)
        try AssistantFixture.write(state, to: support.appendingPathComponent("state.json"))
        let requests = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"nicedock-e2e","version":"1.0"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"add_widget","arguments":{"kind":"flipClock","profile":"Work","position":0}}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"set_appearance","arguments":{"dock_style":"black","corner_radius":14}}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"add_widget","arguments":{"kind":"timer","config":{"minutes":999}}}}"#,
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"preview_wallpaper","arguments":{"mood":"calm","time_of_day":"dusk","season":"autumn"}}}"#
        ]
        let (replies, status, _) = try Self.exchange(requests, home: home)
        #expect(status == 0)
        let parsed = try replies.map(JSONValue.parse)
        try #require(parsed.count == 5)
        func payload(_ i: Int) throws -> JSONValue {
            try JSONValue.parse(try #require(parsed[i]["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue))
        }
        #expect(parsed[1]["result"]?["isError"] == false)
        #expect(try payload(1)["note"]?.stringValue?.contains("isn't running") == true)
        #expect(parsed[3]["result"]?["isError"] == true, "out-of-range settings are rejected")
        let preview = try payload(4)
        let path = try #require(preview["path"]?.stringValue)
        #expect(path.hasPrefix(support.appendingPathComponent("Wallpapers").path))
        #expect(FileManager.default.fileExists(atPath: path))
        #expect((preview["width"]?.intValue ?? 0) > 0)

        let saved = try DockStateFile(url: support.appendingPathComponent("state.json")).load()
        #expect(saved.profiles[1].widgets.first?.kind == .flipClock)
        #expect(saved.profiles[0].widgets.count == state.profiles[0].widgets.count, "the rejected timer was not added")
        #expect(saved.settings.dockStyle == .black)
        #expect(saved.settings.cornerRadius == 14)
        Self.saveTranscript(requests, replies, env: "COOLDOCK_MCP_TRANSCRIPT_CHANGES")
    }

    static func saveTranscript(_ requests: [String], _ replies: [String], env: String) {
        guard let path = ProcessInfo.processInfo.environment[env] else { return }
        var lines: [String] = []
        var replyIndex = 0
        for request in requests {
            lines.append("→ " + request)
            if (try? JSONValue.parse(request))?["id"] != nil, replyIndex < replies.count {
                lines.append("← " + replies[replyIndex])
                replyIndex += 1
            }
        }
        try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    @Test func disabledByDefaultAndMalformedInput() throws {
        let home = AssistantFixture.tempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let (replies, status, _) = try Self.exchange([
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"old","version":"0"}}}"#,
            "not json",
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_dock"}}"#
        ], home: home)
        #expect(status == 0)
        let parsed = try replies.map(JSONValue.parse)
        try #require(parsed.count == 3)
        #expect(parsed[0]["result"]?["protocolVersion"] == "2024-11-05")
        #expect(parsed[1]["error"]?["code"] == .int(RPCError.parseError))
        #expect(parsed[2]["result"]?["isError"] == true)
        #expect(parsed[2]["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue?.contains("disabled in NiceDock Settings") == true)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/Application Support/NiceDock/state.json").path))
    }
}
