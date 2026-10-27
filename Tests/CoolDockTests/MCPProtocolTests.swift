import Foundation
import Testing
@testable import CoolDock

/// JSON-RPC 2.0 framing, MCP lifecycle methods and error codes of `NiceDock --mcp`.
@Suite struct MCPProtocolTests {
    /// Server whose tools echo their arguments (or fail with a tool error for `remove_widget`).
    static func server() -> MCPServer {
        MCPServer { name, args in
            if name == "remove_widget" { throw ToolFailure("No widget with id 'x'.") }
            return ["tool": .string(name), "arguments": .object(args)]
        }
    }

    static func reply(_ server: MCPServer, _ line: String) throws -> JSONValue {
        let out = try #require(server.handle(line: line))
        #expect(!out.contains("\n"), "newline-delimited framing needs single-line messages")
        return try JSONValue.parse(out)
    }

    static func initialize(_ version: String) -> String {
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"\#(version)","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#
    }

    @Test(arguments: ["2025-06-18", "2025-03-26", "2024-11-05"])
    func initializeEchoesSupportedVersions(_ version: String) throws {
        let s = Self.server()
        let r = try Self.reply(s, Self.initialize(version))
        #expect(r["jsonrpc"] == "2.0")
        #expect(r["id"] == 1)
        let result = try #require(r["result"])
        #expect(result["protocolVersion"]?.stringValue == version)
        #expect(result["capabilities"]?["tools"] != nil)
        #expect(result["serverInfo"]?["name"] == "nicedock")
        #expect(result["serverInfo"]?["version"]?.stringValue?.isEmpty == false)
        #expect(result["instructions"]?.stringValue?.contains("get_dock") == true)
        #expect(s.protocolVersion == version)
    }

    @Test func initializeOffersLatestForUnknownVersion() throws {
        let r = try Self.reply(Self.server(), Self.initialize("2099-01-01"))
        #expect(r["result"]?["protocolVersion"]?.stringValue == "2025-06-18")
    }

    @Test func initializeNeedsProtocolVersion() throws {
        let r = try Self.reply(Self.server(), #"{"jsonrpc":"2.0","id":"a","method":"initialize","params":{}}"#)
        #expect(r["error"]?["code"] == .int(RPCError.invalidParams))
        #expect(r["id"] == "a")
    }

    @Test func notificationsGetNoReply() {
        let s = Self.server()
        #expect(s.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        #expect(s.initialized)
        #expect(s.handle(line: #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":3}}"#) == nil)
        #expect(s.handle(line: #"{"jsonrpc":"2.0","method":"some/unknown"}"#) == nil, "errors for notifications are never sent")
        #expect(s.handle(line: "") == nil)
        #expect(s.handle(line: "   \r") == nil)
    }

    @Test func pingAnswersEmptyObject() throws {
        let r = try Self.reply(Self.server(), #"{"jsonrpc":"2.0","id":7,"method":"ping"}"#)
        #expect(r["result"] == .object([:]))
        #expect(r["id"] == 7)
    }

    @Test func parseErrorHasNullID() throws {
        let r = try Self.reply(Self.server(), #"{"jsonrpc":"2.0","id":1,"method""#)
        #expect(r["error"]?["code"] == .int(RPCError.parseError))
        #expect(r["id"] == .null)
    }

    @Test func invalidRequests() throws {
        let s = Self.server()
        #expect(try Self.reply(s, "42")["error"]?["code"] == .int(RPCError.invalidRequest))
        let noVersion = try Self.reply(s, #"{"id":5,"method":"ping"}"#)
        #expect(noVersion["error"]?["code"] == .int(RPCError.invalidRequest))
        #expect(noVersion["id"] == 5)
        #expect(try Self.reply(s, #"{"jsonrpc":"2.0","id":5}"#)["error"]?["code"] == .int(RPCError.invalidRequest))
        let badID = try Self.reply(s, #"{"jsonrpc":"2.0","id":{"x":1},"method":"ping"}"#)
        #expect(badID["error"]?["code"] == .int(RPCError.invalidRequest))
        #expect(badID["id"] == .null)
        #expect(try Self.reply(s, "[]")["error"]?["code"] == .int(RPCError.invalidRequest))
        let badParams = try Self.reply(s, #"{"jsonrpc":"2.0","id":9,"method":"tools/list","params":[1]}"#)
        #expect(badParams["error"]?["code"] == .int(RPCError.invalidParams))
    }

    @Test func clientResponsesAreIgnored() {
        #expect(Self.server().handle(line: #"{"jsonrpc":"2.0","id":1,"result":{}}"#) == nil)
    }

    @Test func unknownMethodKeepsStringID() throws {
        let r = try Self.reply(Self.server(), #"{"jsonrpc":"2.0","id":"req-1","method":"resources/list"}"#)
        #expect(r["error"]?["code"] == .int(RPCError.methodNotFound))
        #expect(r["id"] == "req-1")
    }

    @Test func batchesAnswerEachRequest() throws {
        let r = try Self.reply(Self.server(), #"[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/initialized"},{"jsonrpc":"2.0","id":2,"method":"nope"}]"#)
        let items = try #require(r.arrayValue)
        #expect(items.count == 2)
        #expect(items[0]["result"] == .object([:]))
        #expect(items[1]["error"]?["code"] == .int(RPCError.methodNotFound))
    }

    @Test func toolCallEnvelope() throws {
        let s = Self.server()
        let ok = try Self.reply(s, #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_dock","arguments":{}}}"#)
        #expect(ok["result"]?["isError"] == false)
        let content = try #require(ok["result"]?["content"]?.arrayValue?.first)
        #expect(content["type"] == "text")
        let payload = try JSONValue.parse(try #require(content["text"]?.stringValue))
        #expect(payload["tool"] == "get_dock")

        let failed = try Self.reply(s, #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"remove_widget","arguments":{"widget_id":"x"}}}"#)
        #expect(failed["result"]?["isError"] == true, "tool failures are results the model can read, not protocol errors")
        #expect(failed["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue?.contains("No widget") == true)

        let noArgs = try Self.reply(s, #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"get_dock"}}"#)
        #expect(noArgs["result"]?["isError"] == false)
    }

    @Test func toolCallProtocolErrors() throws {
        let s = Self.server()
        let unknown = try Self.reply(s, #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"format_disk"}}"#)
        #expect(unknown["error"]?["code"] == .int(RPCError.invalidParams))
        #expect(unknown["error"]?["message"]?.stringValue?.contains("format_disk") == true)
        let noName = try Self.reply(s, #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{}}"#)
        #expect(noName["error"]?["code"] == .int(RPCError.invalidParams))
        let badArgs = try Self.reply(s, #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_dock","arguments":"x"}}"#)
        #expect(badArgs["error"]?["code"] == .int(RPCError.invalidParams))
    }

    @Test func jsonValueRoundTrip() throws {
        let text = #"{"a":[1,2.5,true,null,"x\ny"],"b":{"c":-3},"d":"/path/é"}"#
        let v = try JSONValue.parse(text)
        #expect(v["a"]?.arrayValue?.count == 5)
        #expect(v["a"]?.arrayValue?[2] == .bool(true))
        #expect(v["a"]?.arrayValue?[0] == .number(1))
        #expect(v["b"]?["c"]?.intValue == -3)
        #expect(try JSONValue.parse(v.text()) == v)
        #expect(v.text() == #"{"a":[1,2.5,true,null,"x\ny"],"b":{"c":-3},"d":"/path/é"}"#)
    }
}

/// `tools/list`: every tool has a usable JSON Schema.
@Suite struct MCPToolSchemaTests {
    static let expected = ["get_dock", "list_widget_kinds", "add_widget", "remove_widget", "move_widget", "update_widget_config",
                           "set_appearance", "set_layout", "set_language", "switch_profile", "create_profile", "rename_profile",
                           "set_wallpaper", "preview_wallpaper"]

    @Test func listsEveryTool() throws {
        let r = try MCPProtocolTests.reply(MCPProtocolTests.server(), #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        let tools = try #require(r["result"]?["tools"]?.arrayValue)
        #expect(tools.compactMap { $0["name"]?.stringValue } == Self.expected)
    }

    @Test func schemasAreValid() throws {
        let types: Set<String> = ["string", "integer", "number", "boolean", "object", "array"]
        for tool in AssistantTools.listing["tools"]?.arrayValue ?? [] {
            let name = try #require(tool["name"]?.stringValue)
            #expect(name.allSatisfy { $0.isLowercase || $0 == "_" }, "\(name)")
            #expect((tool["description"]?.stringValue?.count ?? 0) > 20, "\(name) needs a description")
            let schema = try #require(tool["inputSchema"])
            #expect(schema["type"] == "object", "\(name)")
            #expect(schema["additionalProperties"] == false, "\(name)")
            let properties = try #require(schema["properties"]?.objectValue, "\(name)")
            for required in schema["required"]?.arrayValue ?? [] {
                #expect(properties[required.stringValue ?? ""] != nil, "\(name): required \(required.brief) must be a property")
            }
            for (key, property) in properties {
                #expect(types.contains(property["type"]?.stringValue ?? ""), "\(name).\(key) type")
                #expect(property["description"]?.stringValue?.isEmpty == false, "\(name).\(key) description")
                if let values = property["enum"]?.arrayValue {
                    #expect(!values.isEmpty && values.allSatisfy { $0.stringValue != nil }, "\(name).\(key) enum")
                }
            }
            let readOnly = tool["annotations"]?["readOnlyHint"]?.boolValue
            #expect(readOnly == (AssistantTools.named(name)?.access != .change), "\(name) readOnlyHint")
            // The schema must also be plain JSON for any client.
            #expect((try? JSONSerialization.jsonObject(with: schema.encoded())) != nil)
        }
    }

    @Test func schemaEnumsMatchTheApp() {
        let add = AssistantTools.named("add_widget")!
        #expect(add.properties["visibility"]?["enum"] == .strings(VisibilityRule.allCases.map(\.rawValue)))
        let appearance = AssistantTools.named("set_appearance")!
        #expect(appearance.properties["dock_style"]?["enum"] == .strings(DockStyle.allCases.map(\.rawValue)))
        let layout = AssistantTools.named("set_layout")!
        #expect(layout.properties["scenario"]?["enum"] == .strings(LayoutScenario.allCases.map(\.rawValue)))
        #expect(layout.properties["position"]?["enum"] == .strings(ScreenPosition.allCases.map(\.rawValue)))
        let language = AssistantTools.named("set_language")!
        #expect(language.properties["language"]?["enum"]?.arrayValue?.count == AppLanguage.allCases.count)
    }
}
