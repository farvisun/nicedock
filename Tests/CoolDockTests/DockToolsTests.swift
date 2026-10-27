import Foundation
import Testing
@testable import CoolDock

/// Safety model: everything is off until the user enables the assistant; changes also need Allow Changes.
@Suite struct AssistantGatingTests {
    @Test func defaultsAreOff() {
        let s = Settings()
        #expect(!s.assistantEnabled)
        #expect(!s.assistantAllowsChanges)
        #expect(!DockState.fresh().settings.assistantEnabled)
    }

    @Test func disabledBlocksEveryTool() {
        for tool in AssistantTools.all where !tool.isWallpaper {
            var state = AssistantFixture.state(enabled: false, allowChanges: true)
            let before = state
            // Even malformed arguments get the disabled answer first.
            let message = AssistantFixture.failure(tool.name, ["bogus": 1], on: &state)
            #expect(message?.contains("disabled in CoolDock Settings") == true, "\(tool.name): \(message ?? "nil")")
            #expect(state == before)
        }
    }

    @Test func readOnlyBlocksChanges() throws {
        for name in AssistantFixture.mutatingTools where !["set_wallpaper"].contains(name) {
            var state = AssistantFixture.state(enabled: true, allowChanges: false)
            let before = state
            let message = AssistantFixture.failure(name, [:], on: &state)
            #expect(message?.contains("read-only; turn on Allow Changes in Settings → AI Assistant") == true, "\(name): \(message ?? "nil")")
            #expect(state == before)
        }
        var state = AssistantFixture.state(enabled: true, allowChanges: false)
        let dock = try AssistantFixture.run("get_dock", on: &state)
        #expect(dock.result["assistant"]?["allow_changes"] == false)
        #expect(!dock.changed)
        #expect(try AssistantFixture.run("list_widget_kinds", on: &state).result["count"]?.intValue == WidgetCatalog.browsable.count)
    }

    @Test func wallpaperGating() throws {
        let dir = AssistantFixture.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var applied: [URL] = []
        let router = AssistantFixture.router(dir: dir, desktop: { applied.append($0); return 2 })
        let stateURL = dir.appendingPathComponent("state.json")

        // No state file at all: the assistant was never enabled.
        #expect(throws: ToolFailure(DockTools.disabledMessage)) { try router.call("preview_wallpaper", [:]) }

        try AssistantFixture.write(AssistantFixture.state(enabled: true, allowChanges: false), to: stateURL)
        #expect(throws: ToolFailure(DockTools.readOnlyMessage)) { try router.call("set_wallpaper", ["mood": "calm"]) }
        #expect(applied.isEmpty)
        let preview = try router.call("preview_wallpaper", ["mood": "calm"])
        #expect(FileManager.default.fileExists(atPath: preview["path"]?.stringValue ?? ""), "previews are allowed while read-only")
        #expect(applied.isEmpty)

        try AssistantFixture.write(AssistantFixture.state(enabled: true, allowChanges: true), to: stateURL)
        let set = try router.call("set_wallpaper", ["mood": "calm"])
        #expect(set["displays"] == 2)
        #expect(applied.map(\.path) == [preview["path"]?.stringValue ?? ""], "the same request reuses the identical image")
    }
}

/// Validation and effects of each dock tool on an in-memory state.
@Suite struct DockToolsTests {
    static func fresh() -> DockState { AssistantFixture.state() }

    @Test func getDockSummary() throws {
        var state = Self.fresh()
        state.settings.cornerRadius = 15
        let r = try AssistantFixture.run("get_dock", on: &state).result
        #expect(r["source"] == "app")
        #expect(r["appearance"]?["corner_radius"] == 15)
        #expect(r["appearance"]?["dock_style"] == "darkGlass")
        #expect(r["layout"]?["scenario"] == "fixed")
        #expect(r["language"]?["language"] == "system")
        let profiles = try #require(r["profiles"]?.arrayValue)
        #expect(profiles.count == 3)
        #expect(profiles[0]["active"] == true)
        let widgets = try #require(profiles[0]["widgets"]?.arrayValue)
        #expect(widgets.count == state.profiles[0].widgets.count)
        #expect(widgets[0]["id"]?.stringValue == state.profiles[0].widgets[0].id.uuidString)
        #expect(widgets[0]["kind"] == "timeHero")
        let folder = try #require(widgets.first { $0["kind"] == "appFolder" })
        #expect(folder["config"]?["name"] == "Favorites")
        #expect(folder["config"]?["apps"]?.arrayValue?.count == 4)
        #expect(r["active_profile"]?["name"] == "Home")
    }

    @Test func getDockNeverShowsSecrets() throws {
        var state = Self.fresh()
        state.profiles[0].widgets.append(WidgetInstance(kind: .githubContributions, config: ["user": "octocat", "token": "ghp_leak"]))
        let text = try AssistantFixture.run("get_dock", on: &state).result.text()
        #expect(text.contains("octocat"))
        #expect(!text.contains("ghp_leak"))
    }

    @Test func listWidgetKinds() throws {
        var state = Self.fresh()
        let all = try AssistantFixture.run("list_widget_kinds", on: &state).result
        #expect(all["count"]?.intValue == WidgetCatalog.browsable.count)
        #expect(all["kinds"]?.arrayValue?.contains { $0["kind"] == "runningApps" } == false)
        let weather = try AssistantFixture.run("list_widget_kinds", ["category": "weather"], on: &state).result
        #expect(weather["kinds"]?.arrayValue?.allSatisfy { $0["category"] == "weather" } == true)
        let pomodoro = try #require(try AssistantFixture.run("list_widget_kinds", ["kind": "Pomodoro"], on: &state).result["kinds"]?.arrayValue?.first)
        #expect(pomodoro["title"] == "Pomodoro")
        #expect(pomodoro["width"] == 175)
        let focus = try #require(pomodoro["fields"]?.arrayValue?.first { $0["key"] == "focus" })
        #expect(focus["type"] == "number")
        #expect(focus["minimum"] == 5)
        #expect(focus["default"] == 25)
        let stripe = try #require(try AssistantFixture.run("list_widget_kinds", ["kind": "stripeRevenue"], on: &state).result["kinds"]?.arrayValue?.first)
        let token = try #require(stripe["fields"]?.arrayValue?.first { $0["key"] == "token" })
        #expect(token["settable"] == false)
        #expect(AssistantFixture.failure("list_widget_kinds", ["category": "toys"], on: &state)?.contains("Valid values: apps") == true)
    }

    @Test func addWidget() throws {
        var state = Self.fresh()
        let count = state.profiles[0].widgets.count
        let r = try AssistantFixture.run("add_widget", ["kind": "flipClock", "position": 1], on: &state)
        #expect(r.changed)
        #expect(state.profiles[0].widgets.count == count + 1)
        #expect(state.profiles[0].widgets[1].kind == .flipClock)
        #expect(r.result["widget"]?["id"]?.stringValue == state.profiles[0].widgets[1].id.uuidString)

        // English title, profile by name, config with type coercion, appended by default.
        _ = try AssistantFixture.run("add_widget", ["kind": "Pomodoro", "profile": "work", "config": ["focus": 50, "sound": false]], on: &state)
        let pomodoro = try #require(state.profiles[1].widgets.last)
        #expect(pomodoro.kind == .pomodoro)
        #expect(pomodoro.config["focus"] == "50")
        #expect(pomodoro.config["sound"] == "0")
        #expect(pomodoro.config["short"] == "5", "defaults stay")

        _ = try AssistantFixture.run("add_widget", ["kind": "progressRing", "profile": 2, "position": 0,
                                                    "config": ["period": "Week", "color": "teal"]], on: &state)
        #expect(state.profiles[2].widgets[0].config["period"] == "week")
        #expect(state.profiles[2].widgets[0].config["color"] == "#139A9A")

        _ = try AssistantFixture.run("add_widget", ["kind": "appFolder", "config": ["name": "Tools", "apps": ["Calculator", "/System/Applications/Notes.app"]]], on: &state)
        let folder = try #require(state.profiles[0].widgets.last)
        #expect(folder.config["apps"] == "/System/Applications/Calculator.app\n/System/Applications/Notes.app")

        _ = try AssistantFixture.run("add_widget", ["kind": "cpuRing", "visibility": "cpuHigh"], on: &state)
        #expect(state.profiles[0].widgets.last?.visibility == .cpuHigh)
    }

    @Test func addWidgetValidation() {
        var state = Self.fresh()
        let before = state
        func fails(_ args: [String: JSONValue], _ needle: String) {
            let message = AssistantFixture.failure("add_widget", args, on: &state)
            #expect(message?.contains(needle) == true, "\(args) → \(message ?? "nil")")
        }
        fails([:], "Missing required argument 'kind'")
        fails(["kind": "laserClock"], "Valid kinds: app, appFolder")
        fails(["kind": "runningApps"], "can't be added")
        fails(["kind": "timer", "colour": "red"], "Unknown argument 'colour'")
        fails(["kind": "timer", "position": 99], "position must be between -1 and")
        fails(["kind": "timer", "profile": "Gaming"], "No profile 'Gaming'. Profiles: 0 Home")
        fails(["kind": "timer", "profile": 9], "No profile at index 9")
        fails(["kind": "timer", "config": ["seconds": 5]], "Valid settings: minutes")
        fails(["kind": "cpuRing", "config": ["x": 1]], "cpuRing has no settings")
        fails(["kind": "timer", "config": ["minutes": 500]], "between 1 and 240 min")
        fails(["kind": "timer", "config": ["minutes": "soon"]], "must be a number")
        fails(["kind": "timer", "config": "minutes=5"], "must be an object")
        fails(["kind": "searchWeb", "config": ["engine": "altavista"]], "one of google, duckduckgo")
        fails(["kind": "pixelClock", "config": ["color": "blurple"]], "must be a colour")
        fails(["kind": "analogDark", "config": ["seconds": "maybe"]], "true or false")
        fails(["kind": "stripeRevenue", "config": ["token": "rk_live_x"]], "Tokens never pass through the assistant")
        fails(["kind": "quickContacts", "config": ["contacts": "abc"]], "chosen from Contacts")
        fails(["kind": "app", "config": ["path": "NoSuchAppHere"]], "Couldn't find an app named")
        fails(["kind": "app", "config": ["path": "/Applications/NoSuchAppHere.app"]], "No app at")
        fails(["kind": "folder", "config": ["path": "Documents"]], "absolute folder path")
        fails(["kind": "timer", "visibility": "whilePlaying"], "timer supports visibility always")
        fails(["kind": "timer", "visibility": "sometimes"], "Valid values: always")
        #expect(state == before)
    }

    @Test func removeWidget() throws {
        var state = Self.fresh()
        let target = state.profiles[1].widgets[2]
        let r = try AssistantFixture.run("remove_widget", ["widget_id": .string(String(target.id.uuidString.prefix(8)).lowercased())], on: &state)
        #expect(!state.profiles[1].widgets.contains { $0.id == target.id })
        #expect(r.effects == [.removeSecrets(target.id)])
        #expect(AssistantFixture.failure("remove_widget", ["widget_id": .string(target.id.uuidString)], on: &state)?.contains("No widget with id") == true)
        #expect(AssistantFixture.failure("remove_widget", [:], on: &state)?.contains("Missing required argument 'widget_id'") == true)
    }

    @Test func moveWidget() throws {
        var state = Self.fresh()
        let first = state.profiles[0].widgets[0]
        let last = state.profiles[0].widgets.count - 1
        _ = try AssistantFixture.run("move_widget", ["widget_id": .string(first.id.uuidString), "position": -1], on: &state)
        #expect(state.profiles[0].widgets.last?.id == first.id)
        _ = try AssistantFixture.run("move_widget", ["widget_id": .string(first.id.uuidString), "position": 0, "profile": "System"], on: &state)
        #expect(state.profiles[2].widgets.first?.id == first.id)
        #expect(state.profiles[0].widgets.count == last)
        let message = AssistantFixture.failure("move_widget", ["widget_id": .string(first.id.uuidString), "position": 40], on: &state)
        #expect(message?.contains("position must be between -1 and") == true)
    }

    @Test func updateWidgetConfig() throws {
        var state = Self.fresh()
        let id = try #require(state.profiles[0].widgets.first { $0.kind == .progressRing }?.id)
        let r = try AssistantFixture.run("update_widget_config", ["widget_id": .string(id.uuidString), "config": ["period": "year", "color": "#abc"]], on: &state)
        #expect(r.effects == [.refresh(id)])
        var w = try #require(state.profiles[0].widgets.first { $0.id == id })
        #expect(w.config["period"] == "year")
        #expect(w.config["color"] == "#AABBCC")
        _ = try AssistantFixture.run("update_widget_config", ["widget_id": .string(id.uuidString), "config": ["color": .null]], on: &state)
        w = try #require(state.profiles[0].widgets.first { $0.id == id })
        #expect(w.config["color"] == "#30D158", "null restores the default")
        #expect(AssistantFixture.failure("update_widget_config", ["widget_id": .string(id.uuidString)], on: &state)?.contains("Nothing to change") == true)
    }

    @Test func setAppearance() throws {
        var state = Self.fresh()
        let r = try AssistantFixture.run("set_appearance", ["dock_style": "white", "scale": 1.12, "corner_radius": "16.3", "monochrome": true, "theme": "dark"], on: &state)
        #expect(state.settings.dockStyle == .white)
        #expect(state.settings.dockScale == 1.1, "snapped to the 0.05 slider step")
        #expect(state.settings.cornerRadius == 16.5)
        #expect(state.settings.monochrome)
        #expect(state.settings.appTheme == .dark)
        #expect(r.result["appearance"]?["dock_style"] == "white")
        #expect(AssistantFixture.failure("set_appearance", ["dock_style": "neon"], on: &state)?.contains("Valid values: lightGlass, liquidGlass, darkGlass") == true)
        #expect(AssistantFixture.failure("set_appearance", ["scale": 3], on: &state)?.contains("between 0.7 and 1.4") == true)
        #expect(AssistantFixture.failure("set_appearance", ["shadow": "yes please"], on: &state)?.contains("true or false") == true)
        #expect(AssistantFixture.failure("set_appearance", [:], on: &state)?.contains("Pass at least one of") == true)
        let liquid = AssistantFixture.failure("set_appearance", ["dock_style": "liquidGlass"], on: &state)
        if DockStyle.available.contains(.liquidGlass) { #expect(liquid == nil) } else { #expect(liquid?.contains("needs macOS 26") == true) }
    }

    @Test func setLayout() throws {
        var state = Self.fresh()
        state.settings.scenario = .swapBottom
        let r = try AssistantFixture.run("set_layout", ["position": "topRight"], on: &state)
        #expect(state.settings.scenario == .fixed)
        #expect(state.settings.fixedPosition == .topRight)
        #expect(r.result["notes"]?.arrayValue?.isEmpty == false)
        _ = try AssistantFixture.run("set_layout", ["scenario": "revealTop", "show_delay": 0.42, "screens": "all", "hide_on_window_hover": true], on: &state)
        #expect(state.settings.scenario == .revealTop)
        #expect(state.settings.showDelay == 0.4)
        #expect(state.settings.screensMode == .all)
        #expect(state.settings.hideOnWindowHover)
        #expect(AssistantFixture.failure("set_layout", ["scenario": "sideways"], on: &state)?.contains("Valid values: swapBottom") == true)
        #expect(AssistantFixture.failure("set_layout", ["edge_distance": -4], on: &state)?.contains("between 0 and 80") == true)
    }

    @Test func setLanguage() throws {
        var state = Self.fresh()
        _ = try AssistantFixture.run("set_language", ["language": "Persian", "calendar": "persian", "digits": "native", "clock": "24h"], on: &state)
        #expect(state.settings.language == .fa)
        #expect(state.settings.calendarSystem == .persian)
        #expect(state.settings.digitStyle == .native)
        #expect(state.settings.clockStyle == .h24)
        _ = try AssistantFixture.run("set_language", ["language": "zh"], on: &state)
        #expect(state.settings.language == .zhHans)
        _ = try AssistantFixture.run("set_language", ["language": "日本語"], on: &state)
        #expect(state.settings.language == .ja)
        #expect(AssistantFixture.failure("set_language", ["language": "klingon"], on: &state)?.contains("fa (Persian)") == true)
    }

    @Test func profiles() throws {
        var state = Self.fresh()
        _ = try AssistantFixture.run("switch_profile", ["profile": 2], on: &state)
        #expect(state.activeProfileID == state.profiles[2].id)
        _ = try AssistantFixture.run("switch_profile", ["profile": "home"], on: &state)
        #expect(state.activeIndex == 0)

        let created = try AssistantFixture.run("create_profile", ["name": "Focus", "symbol": "moon", "duplicate_from": "Work"], on: &state)
        let focus = try #require(state.profiles.last)
        #expect(focus.name == "Focus")
        #expect(focus.symbol == "moon")
        #expect(state.activeProfileID == focus.id)
        #expect(focus.widgets.map(\.kind) == state.profiles[1].widgets.map(\.kind))
        #expect(Set(focus.widgets.map(\.id)).isDisjoint(with: state.profiles[1].widgets.map(\.id)))
        #expect(created.effects.count == focus.widgets.count)

        _ = try AssistantFixture.run("create_profile", ["name": "Quiet", "activate": false], on: &state)
        #expect(state.activeProfileID == focus.id)
        #expect(AssistantFixture.failure("create_profile", ["name": "focus"], on: &state)?.contains("already exists") == true)
        #expect(AssistantFixture.failure("create_profile", ["name": .string(String(repeating: "x", count: 25))], on: &state)?.contains("at most 24") == true)
        #expect(AssistantFixture.failure("create_profile", ["name": "  "], on: &state)?.contains("can't be empty") == true)
        #expect(AssistantFixture.failure("create_profile", ["name": "A", "symbol": "pizza"], on: &state)?.contains("Valid symbols: house") == true)
        for i in 0..<3 { _ = try AssistantFixture.run("create_profile", ["name": .string("P\(i)")], on: &state) }
        #expect(state.profiles.count == 8)
        #expect(AssistantFixture.failure("create_profile", ["name": "Ninth"], on: &state)?.contains("at most 8 profiles") == true)

        _ = try AssistantFixture.run("rename_profile", ["profile": "Quiet", "name": "Calm", "symbol": "leaf"], on: &state)
        #expect(state.profiles.contains { $0.name == "Calm" && $0.symbol == "leaf" })
        #expect(AssistantFixture.failure("rename_profile", ["profile": "Calm", "name": "Home"], on: &state)?.contains("already exists") == true)
        #expect(AssistantFixture.failure("rename_profile", ["profile": "Calm"], on: &state)?.contains("Nothing to change") == true)
        #expect(AssistantFixture.failure("switch_profile", ["profile": "Gaming"], on: &state)?.contains("No profile 'Gaming'") == true)
    }

    @Test func unchangedValuesAreNotChanges() throws {
        var state = Self.fresh()
        let r = try AssistantFixture.run("set_appearance", ["dock_style": "darkGlass"], on: &state)
        #expect(!r.changed)
    }
}

/// The offline path (CoolDock not running): the same tools on state.json in a temp directory.
@Suite struct StateFileApplyTests {
    @Test func appliesAndPersists() throws {
        let dir = AssistantFixture.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("state.json")
        var start = AssistantFixture.state()
        start.settings.cornerRadius = 17
        start.settings.calendarFeeds = [CalendarFeed(name: "A", url: "https://example.com/a.ics")]
        try AssistantFixture.write(start, to: url)
        let router = AssistantFixture.router(dir: dir)

        let r = try router.call("add_widget", ["kind": "flipClock", "profile": "Work"])
        #expect(r["note"]?.stringValue?.contains("isn't running") == true)
        let saved = try DockStateFile(url: url).load()
        #expect(saved.profiles[1].widgets.last?.kind == .flipClock)
        #expect(saved.settings.cornerRadius == 17, "untouched settings survive")
        #expect(saved.settings.calendarFeeds?.first?.name == "A")
        #expect(saved.settings.assistantEnabled)

        _ = try router.call("set_appearance", ["dock_style": "black"])
        #expect(try DockStateFile(url: url).load().settings.dockStyle == .black)
        let dock = try router.call("get_dock", [:])
        #expect(dock["source"] == "saved_state")
        #expect(dock["appearance"]?["dock_style"] == "black")
    }

    @Test func missingStateIsDisabledAndNotCreated() throws {
        let dir = AssistantFixture.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let router = AssistantFixture.router(dir: dir)
        #expect(throws: ToolFailure(DockTools.disabledMessage)) { try router.call("get_dock", [:]) }
        #expect(throws: ToolFailure(DockTools.disabledMessage)) { try router.call("add_widget", ["kind": "timer"]) }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("state.json").path))
    }

    @Test func readOnlyAndFailuresLeaveTheFileAlone() throws {
        let dir = AssistantFixture.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("state.json")
        try AssistantFixture.write(AssistantFixture.state(enabled: true, allowChanges: false), to: url)
        let bytes = try Data(contentsOf: url)
        let router = AssistantFixture.router(dir: dir)
        #expect(throws: ToolFailure(DockTools.readOnlyMessage)) { try router.call("remove_widget", ["widget_id": "abcd"]) }
        #expect(try Data(contentsOf: url) == bytes)

        try AssistantFixture.write(AssistantFixture.state(), to: url)
        let allowed = try Data(contentsOf: url)
        #expect(throws: ToolFailure.self) { try router.call("add_widget", ["kind": "nope"]) }
        #expect(try Data(contentsOf: url) == allowed)
    }

    @Test func corruptStateIsNeverOverwritten() throws {
        let dir = AssistantFixture.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("state.json")
        try Data("{\"settings\": {".utf8).write(to: url)
        let router = AssistantFixture.router(dir: dir)
        do {
            _ = try router.call("add_widget", ["kind": "timer"])
            Issue.record("expected a failure")
        } catch let f as ToolFailure {
            #expect(f.message.contains("couldn't be read"))
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "{\"settings\": {")
    }

    @Test func stateFilesWithoutAssistantKeysStillLoad() throws {
        // Files written before the assistant existed have no aiAssistantEnabled / aiAllowChanges keys.
        let data = try JSONEncoder().encode(DockState.fresh())
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("aiAssistantEnabled"))
        let decoded = try JSONDecoder().decode(DockState.self, from: data)
        #expect(!decoded.settings.assistantEnabled)
        #expect(!decoded.settings.assistantAllowsChanges)
    }
}

/// The running-app path: a socket server answering with `AssistantService`, as the app does.
@Suite struct AssistantBridgeTests {
    @Test func routesToTheRunningAppAndFallsBack() throws {
        let dir = AssistantFixture.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let socket = dir.appendingPathComponent("a.sock").path
        let live = LockedState(AssistantFixture.state())
        let server = AssistantSocketServer(path: socket) { live.respond($0) }
        try server.start()
        let router = AssistantFixture.router(dir: dir, socket: socket)

        let added = try router.call("add_widget", ["kind": "stopwatch"])
        #expect(added["note"] == nil)
        #expect(live.current.profiles[0].widgets.last?.kind == .stopwatch)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("state.json").path), "the app owns the state while it runs")
        #expect(try router.call("get_dock", [:])["source"] == "app")
        let access = try router.access()
        #expect(access.enabled && access.allowChanges)
        #expect(throws: ToolFailure.self) { try router.call("add_widget", ["kind": "nope"]) }

        // A second app instance must not steal the socket.
        let other = AssistantSocketServer(path: socket) { _ in .null }
        #expect(throws: ToolFailure.self) { try other.start() }

        server.stop()
        #expect(throws: ToolFailure(DockTools.disabledMessage)) { try router.call("get_dock", [:]) }
    }

    @Test func staleSocketFallsBackToStateFile() throws {
        let dir = AssistantFixture.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let socket = dir.appendingPathComponent("a.sock").path
        // A crashed app leaves the socket file behind with nobody listening.
        let fd = try UnixSocket.listen(socket)
        close(fd)
        #expect(FileManager.default.fileExists(atPath: socket))
        try AssistantFixture.write(AssistantFixture.state(), to: dir.appendingPathComponent("state.json"))
        let router = AssistantFixture.router(dir: dir, socket: socket)
        #expect(try router.call("get_dock", [:])["source"] == "saved_state")
    }

    @Test func malformedBridgeRequests() {
        var state = AssistantFixture.state()
        #expect(AssistantService.respond(["op": "explode"], state: &state, source: .app).reply["ok"] == false)
        #expect(AssistantService.respond(["op": "tool"], state: &state, source: .app).reply["error"] == "Missing tool name.")
        let reply = AssistantService.respond(["op": "tool", "name": "get_dock"], state: &state, source: .app).reply
        #expect(reply["ok"] == true)
        #expect(throws: ToolFailure("boom")) { try AssistantService.unwrap(["ok": false, "error": "boom"]) }
    }

    @Test func setupSnippets() {
        let s = AssistantSetup.snippets(path: "/Applications/CoolDock.app/Contents/MacOS/CoolDock")
        #expect(s.claudeCode == #"claude mcp add cooldock -- "/Applications/CoolDock.app/Contents/MacOS/CoolDock" --mcp"#)
        #expect(s.codex == "[mcp_servers.cooldock]\ncommand = \"/Applications/CoolDock.app/Contents/MacOS/CoolDock\"\nargs = [\"--mcp\"]")
        let cursor = try? JSONValue.parse(s.cursor)
        #expect(cursor?["mcpServers"]?["cooldock"]?["args"] == ["--mcp"])
        let vscode = try? JSONValue.parse(s.vscode)
        #expect(vscode?["servers"]?["cooldock"]?["type"] == "stdio")
        #expect(vscode?["servers"]?["cooldock"]?["command"] == "/Applications/CoolDock.app/Contents/MacOS/CoolDock")
        #expect(AssistantSetup.shellQuoted("/a b/$x\"y") == #""/a b/\$x\"y""#)
    }

    @Test func socketPathFitsSunPath() {
        let deep = URL(fileURLWithPath: "/tmp/" + String(repeating: "deep/", count: 30))
        let path = AppPaths.socketPath(in: deep)
        #expect(path.utf8.count < 104)
        #expect(path == AppPaths.socketPath(in: deep), "the app and the MCP process must agree")
        #expect(UnixSocket.address(path) != nil)
        let short = URL(fileURLWithPath: "/Users/me/Library/Application Support/CoolDock")
        #expect(AppPaths.socketPath(in: short) == "/Users/me/Library/Application Support/CoolDock/assistant.sock")
    }
}
