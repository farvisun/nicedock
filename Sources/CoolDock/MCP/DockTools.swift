import Foundation

/// Everything the assistant tools read or change. Also the layout of state.json (`AppStore.Persisted`).
struct DockState: Codable, Equatable {
    var settings: Settings
    var profiles: [DockProfile]
    var activeProfileID: UUID

    /// First-launch state, as `AppStore` creates it.
    static func fresh() -> DockState {
        let profiles = AppStore.defaultProfiles()
        return DockState(settings: Settings(), profiles: profiles, activeProfileID: profiles[0].id)
    }

    var activeIndex: Int { profiles.firstIndex { $0.id == activeProfileID } ?? 0 }
}

/// Work the running app does after applying a tool (Keychain and widget refreshes never run in the `--mcp` process).
enum DockEffect: Equatable {
    case removeSecrets(UUID)
    case copySecrets(from: UUID, to: UUID)
    case refresh(UUID)
}

/// A tool error the assistant should read: reported as an `isError` tool result, not a JSON-RPC error.
struct ToolFailure: Error, Equatable, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

struct ToolOutcome {
    var result: JSONValue
    var changed = false
    var effects: [DockEffect] = []
}

/// Validates and executes the dock tools against a `DockState`. Pure: the running app and the
/// offline (state.json) path run exactly the same code, so validation and gating cannot drift apart.
enum DockTools {
    enum Source: String {
        case app
        case savedState = "saved_state"
    }

    static let disabledMessage = "The AI Assistant is disabled in NiceDock Settings. Ask the user to turn on Enable AI Assistant in NiceDock Settings → Privacy & Permissions → AI Assistant."
    static let readOnlyMessage = "NiceDock is read-only; turn on Allow Changes in Settings → AI Assistant (NiceDock Settings → Privacy & Permissions) to let assistants change it."

    /// Safety model: nothing works until the user enables the assistant; changes also need Allow Changes.
    static func gate(_ tool: AssistantTool, enabled: Bool, allowChanges: Bool) throws {
        guard enabled else { throw ToolFailure(disabledMessage) }
        if tool.access == .change && !allowChanges { throw ToolFailure(readOnlyMessage) }
    }

    static func gate(_ tool: AssistantTool, settings: Settings) throws {
        try gate(tool, enabled: settings.assistantEnabled, allowChanges: settings.assistantAllowsChanges)
    }

    static func run(_ name: String, _ arguments: [String: JSONValue], state: inout DockState, source: Source) throws -> ToolOutcome {
        guard let tool = AssistantTools.named(name) else {
            throw ToolFailure("Unknown tool '\(name)'. Tools: \(AssistantTools.all.map(\.name).joined(separator: ", ")).")
        }
        try gate(tool, settings: state.settings)
        let args = try ToolArgs(tool: tool, values: arguments)
        let before = state
        var outcome: ToolOutcome
        switch name {
        case "get_dock": outcome = ToolOutcome(result: summary(state, source: source))
        case "list_widget_kinds": outcome = ToolOutcome(result: try kinds(args))
        case "add_widget": outcome = try addWidget(args, &state)
        case "remove_widget": outcome = try removeWidget(args, &state)
        case "move_widget": outcome = try moveWidget(args, &state)
        case "update_widget_config": outcome = try updateWidget(args, &state)
        case "set_appearance": outcome = try setAppearance(args, &state)
        case "set_layout": outcome = try setLayout(args, &state)
        case "set_language": outcome = try setLanguage(args, &state)
        case "switch_profile": outcome = try switchProfile(args, &state)
        case "create_profile": outcome = try createProfile(args, &state)
        case "rename_profile": outcome = try renameProfile(args, &state)
        default: throw ToolFailure("\(name) runs in the MCP server, not on the dock state.")
        }
        outcome.changed = state != before
        if source == .savedState, outcome.changed, case .object(var o) = outcome.result {
            o["note"] = "NiceDock isn't running: the change was saved and appears when NiceDock starts."
            outcome.result = .object(o)
        }
        return outcome
    }

    // MARK: - Reading

    static func summary(_ state: DockState, source: Source) -> JSONValue {
        let s = state.settings
        var o: [String: JSONValue] = [
            "source": .string(source.rawValue),
            "assistant": ["enabled": .bool(s.assistantEnabled), "allow_changes": .bool(s.assistantAllowsChanges)],
            "appearance": appearanceJSON(s),
            "layout": layoutJSON(s),
            "language": languageJSON(s),
            "active_profile": profileRef(state, state.activeIndex),
            "profiles": .array(state.profiles.indices.map { profileJSON(state, $0) }),
            "limits": ["max_profiles": .int(DockProfile.maxProfiles), "profile_name_length": .int(DockProfile.maxNameLength)]
        ]
        if source == .savedState {
            o["note"] = "NiceDock isn't running; this is its saved state. Changes are saved and appear when it starts."
        }
        return .object(o)
    }

    static func appearanceJSON(_ s: Settings) -> JSONValue {
        [
            "dock_style": .string(s.dockStyle.rawValue), "widget_surface": .string(s.widgetSurface.rawValue), "theme": .string(s.appTheme.rawValue),
            "scale": .double(s.dockScale), "spacing": .double(s.widgetSpacing), "corner_radius": .double(s.cornerRadius),
            "overflow": .string(s.overflow.rawValue), "monochrome": .bool(s.monochrome), "tile_backgrounds": .bool(s.tileBackgrounds),
            "shadow": .bool(s.shadow), "reduce_transparency": .bool(s.reduceTransparency), "icon_style": .string(s.iconStyle.rawValue),
            "animations": .bool(s.animations)
        ]
    }

    static func layoutJSON(_ s: Settings) -> JSONValue {
        [
            "scenario": .string(s.scenario.rawValue), "position": .string(s.fixedPosition.rawValue), "edge_distance": .double(s.edgeDistance),
            "alignment": .string(s.alignment.rawValue), "show_delay": .double(s.showDelay), "hide_delay": .double(s.hideDelay),
            "trigger_size": .double(s.triggerSize), "hide_on_window_hover": .bool(s.hideOnWindowHover),
            "hide_during_fullscreen": .bool(s.hideDuringFullscreen), "screens": .string(s.screensMode.rawValue)
        ]
    }

    static func languageJSON(_ s: Settings) -> JSONValue {
        [
            "language": .string(s.language.rawValue), "resolved": .string(s.language.resolved.rawValue),
            "calendar": .string(s.calendarSystem.rawValue), "digits": .string(s.digitStyle.rawValue),
            "clock": .string(s.clockStyle.rawValue), "use_estedad": .bool(s.useEstedad)
        ]
    }

    static func profileRef(_ state: DockState, _ i: Int) -> JSONValue {
        let p = state.profiles[i]
        return ["id": .string(p.id.uuidString), "name": .string(p.name), "index": .int(i)]
    }

    static func profileJSON(_ state: DockState, _ i: Int) -> JSONValue {
        let p = state.profiles[i]
        return [
            "id": .string(p.id.uuidString), "name": .string(p.name), "symbol": .string(p.symbol), "index": .int(i),
            "active": .bool(p.id == state.activeProfileID),
            "widgets": .array(p.widgets.enumerated().map { widgetJSON($1, position: $0) })
        ]
    }

    static func widgetJSON(_ w: WidgetInstance, position: Int) -> JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(w.id.uuidString), "kind": .string(w.kind.rawValue), "title": .string(w.kind.spec.title), "position": .int(position)
        ]
        let config = configJSON(w)
        if !config.isEmpty { o["config"] = .object(config) }
        if w.visibility != .always { o["visibility"] = .string(w.visibility.rawValue) }
        return .object(o)
    }

    /// Declared settings only (internal widget state such as todo items stays private); secrets are never read.
    static func configJSON(_ w: WidgetInstance) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for f in w.kind.spec.fields {
            switch f.type {
            case .secret, .contacts: continue
            case .toggle: out[f.key] = .bool(w.bool(f.key))
            case .number: out[f.key] = Double(w.string(f.key)).map(JSONValue.double) ?? .string(w.string(f.key))
            case .multiline, .apps: out[f.key] = .strings(w.list(f.key))
            default: out[f.key] = .string(w.string(f.key))
            }
        }
        return out
    }

    static func kinds(_ args: ToolArgs) throws -> JSONValue {
        var list = WidgetCatalog.browsable
        if let category = try args.choice("category", WidgetCategory.self) { list = list.filter { $0.spec.category == category } }
        if args.has("kind") { list = [try kindArgument(args, "kind")] }
        return [
            "count": .int(list.count),
            "categories": .strings(WidgetCategory.allCases.map(\.rawValue)),
            "kinds": .array(list.map(kindJSON))
        ]
    }

    static func kindJSON(_ kind: WidgetKind) -> JSONValue {
        let spec = kind.spec
        var o: [String: JSONValue] = [
            "kind": .string(kind.rawValue), "title": .string(spec.title), "description": .string(spec.summary),
            "category": .string(spec.category.rawValue), "width": .double(Double(spec.width))
        ]
        if spec.connected { o["connected"] = true }
        if !spec.visibility.isEmpty { o["visibility"] = .strings(([VisibilityRule.always] + spec.visibility).map(\.rawValue)) }
        if !spec.fields.isEmpty { o["fields"] = .array(spec.fields.map { fieldJSON($0, defaults: spec.defaults) }) }
        return .object(o)
    }

    static func fieldJSON(_ f: ConfigField, defaults: [String: String]) -> JSONValue {
        var o: [String: JSONValue] = ["key": .string(f.key), "title": .string(f.title)]
        let def = defaults[f.key]
        switch f.type {
        case .text: o["type"] = "string"
        case .multiline: o["type"] = "list"; o["format"] = "array of strings, or one item per line"
        case .secret:
            o["type"] = "secret"; o["settable"] = false
            o["note"] = "Stored in the macOS Keychain; the user enters it in NiceDock (right-click the widget → Customize…)."
        case .number(let min, let max, let step, let unit):
            o["type"] = "number"; o["minimum"] = .double(min); o["maximum"] = .double(max); o["step"] = .double(step)
            if !unit.isEmpty { o["unit"] = .string(unit) }
        case .toggle: o["type"] = "boolean"
        case .choice(let options):
            o["type"] = "choice"
            o["options"] = .array(options.map { ["value": .string($0.value), "title": .string($0.title)] })
        case .color: o["type"] = "color"; o["format"] = "#RRGGBB or a colour name"
        case .app: o["type"] = "app"; o["format"] = "path of an .app bundle, or an app name such as Safari"
        case .apps: o["type"] = "apps"; o["format"] = "array of .app paths or app names"
        case .folder: o["type"] = "folder"; o["format"] = "absolute folder path (~ allowed)"
        case .city: o["type"] = "location"; o["format"] = "city name or \"latitude,longitude\"; empty uses the current location"
        case .contacts:
            o["type"] = "contacts"; o["settable"] = false
            o["note"] = "Chosen from Contacts in NiceDock (right-click the widget → Customize…)."
        }
        if let def {
            switch f.type {
            case .toggle: o["default"] = .bool(def == "1" || def == "true")
            case .number: o["default"] = Double(def).map(JSONValue.double) ?? .string(def)
            case .multiline, .apps: o["default"] = .strings(def.split(separator: "\n").map(String.init))
            default: o["default"] = .string(def)
            }
        }
        if let help = f.help { o["help"] = .string(help) }
        return .object(o)
    }

    // MARK: - Widgets

    static func addWidget(_ args: ToolArgs, _ state: inout DockState) throws -> ToolOutcome {
        let kind = try kindArgument(args, "kind")
        guard kind.spec.browsable else {
            throw ToolFailure("'\(kind.rawValue)' can't be added as a widget (running apps are a Dock setting in NiceDock Settings → Dock).")
        }
        let p = try profileIndex(args.values["profile"], state)
        let count = state.profiles[p].widgets.count
        var position = try args.int("position", in: -1...count) ?? count
        if position == -1 { position = count }
        var widget = WidgetInstance(kind: kind)
        try applyConfig(args.object("config") ?? [:], to: &widget)
        if let rule = try visibilityArgument(args, kind) { widget.visibility = rule }
        state.profiles[p].widgets.insert(widget, at: position)
        return ToolOutcome(result: [
            "message": .string("Added \(kind.spec.title) to \(state.profiles[p].name) at position \(position)."),
            "widget": widgetJSON(widget, position: position),
            "profile": profileRef(state, p)
        ])
    }

    static func removeWidget(_ args: ToolArgs, _ state: inout DockState) throws -> ToolOutcome {
        let (p, i) = try widgetLocation(args, state)
        let widget = state.profiles[p].widgets.remove(at: i)
        return ToolOutcome(result: [
            "message": .string("Removed \(widget.kind.spec.title) from \(state.profiles[p].name)."),
            "removed": widgetJSON(widget, position: i),
            "profile": profileRef(state, p)
        ], effects: [.removeSecrets(widget.id)])
    }

    static func moveWidget(_ args: ToolArgs, _ state: inout DockState) throws -> ToolOutcome {
        let (p, i) = try widgetLocation(args, state)
        let target = args.has("profile") ? try profileIndex(args.values["profile"], state) : p
        let widget = state.profiles[p].widgets[i]
        let slots = target == p ? state.profiles[p].widgets.count - 1 : state.profiles[target].widgets.count
        var position = try args.int("position", in: -1...slots) ?? 0
        if position == -1 { position = slots }
        state.profiles[p].widgets.remove(at: i)
        state.profiles[target].widgets.insert(widget, at: position)
        let place = target == p ? "position \(position)" : "\(state.profiles[target].name) at position \(position)"
        return ToolOutcome(result: [
            "message": .string("Moved \(widget.kind.spec.title) to \(place)."),
            "widget": widgetJSON(widget, position: position),
            "profile": profileRef(state, target)
        ])
    }

    static func updateWidget(_ args: ToolArgs, _ state: inout DockState) throws -> ToolOutcome {
        guard args.has("config") || args.has("visibility") else { throw ToolFailure("Nothing to change: pass config and/or visibility.") }
        let (p, i) = try widgetLocation(args, state)
        var widget = state.profiles[p].widgets[i]
        try applyConfig(args.object("config") ?? [:], to: &widget)
        if let rule = try visibilityArgument(args, widget.kind) { widget.visibility = rule }
        state.profiles[p].widgets[i] = widget
        return ToolOutcome(result: [
            "message": .string("Updated \(widget.kind.spec.title) in \(state.profiles[p].name)."),
            "widget": widgetJSON(widget, position: i)
        ], effects: [.refresh(widget.id)])
    }

    // MARK: - Settings

    static func setAppearance(_ args: ToolArgs, _ state: inout DockState) throws -> ToolOutcome {
        try args.requireAny()
        var s = state.settings
        if let v = try args.choice("dock_style", DockStyle.self, aliases: ["liquid": .liquidGlass, "light": .lightGlass, "dark": .darkGlass, "clear": .transparent]) {
            guard DockStyle.available.contains(v) else { throw ToolFailure("liquidGlass needs macOS 26. Available styles: \(DockStyle.available.map(\.rawValue).joined(separator: ", ")).") }
            s.dockStyle = v
        }
        if let v = try args.choice("widget_surface", WidgetSurface.self) { s.widgetSurface = v }
        if let v = try args.choice("theme", AppTheme.self, aliases: ["system": .auto, "automatic": .auto]) { s.appTheme = v }
        if let v = try args.double("scale", in: 0.7...1.4, step: 0.05) { s.dockScale = v }
        if let v = try args.double("spacing", in: 0...20, step: 1, unit: "pt") { s.widgetSpacing = v }
        if let v = try args.double("corner_radius", in: 4...22, step: 0.5, unit: "pt") { s.cornerRadius = v }
        if let v = try args.choice("overflow", OverflowMode.self) { s.overflow = v }
        if let v = try args.bool("monochrome") { s.monochrome = v }
        if let v = try args.bool("tile_backgrounds") { s.tileBackgrounds = v }
        if let v = try args.bool("shadow") { s.shadow = v }
        if let v = try args.bool("reduce_transparency") { s.reduceTransparency = v }
        if let v = try args.choice("icon_style", AppIconStyle.self, aliases: ["default": .standard]) { s.iconStyle = v }
        if let v = try args.bool("animations") { s.animations = v }
        state.settings = s
        return ToolOutcome(result: ["message": .string("Appearance updated: \(args.changedList)."), "appearance": appearanceJSON(s)])
    }

    static func setLayout(_ args: ToolArgs, _ state: inout DockState) throws -> ToolOutcome {
        try args.requireAny()
        var s = state.settings
        var notes: [String] = []
        let scenario = try args.choice("scenario", LayoutScenario.self, aliases: [
            "swap": .swapBottom, "reveal": .revealBottom, "top": .revealTop, "replace": .replaceDock, "autohide": .replaceAutoHide, "float": .floating
        ])
        if let scenario { s.scenario = scenario }
        if let v = try args.choice("position", ScreenPosition.self, aliases: ["top": .topCenter, "bottom": .bottomCenter]) {
            s.fixedPosition = v
            if scenario == nil && s.scenario != .fixed {
                s.scenario = .fixed
                notes.append("Switched the layout scenario to fixed so the position applies.")
            } else if s.scenario != .fixed {
                notes.append("position only applies to the fixed scenario.")
            }
        }
        if let v = try args.double("edge_distance", in: 0...80, step: 1, unit: "pt") { s.edgeDistance = v }
        if let v = try args.choice("alignment", DockAlignment.self) { s.alignment = v }
        if let v = try args.double("show_delay", in: 0...2, step: 0.05, unit: "s") { s.showDelay = v }
        if let v = try args.double("hide_delay", in: 0...3, step: 0.05, unit: "s") { s.hideDelay = v }
        if let v = try args.double("trigger_size", in: 1...60, step: 1, unit: "px") { s.triggerSize = v }
        if let v = try args.bool("hide_on_window_hover") { s.hideOnWindowHover = v }
        if let v = try args.bool("hide_during_fullscreen") { s.hideDuringFullscreen = v }
        if let v = try args.choice("screens", ScreensMode.self) { s.screensMode = v }
        state.settings = s
        var result: [String: JSONValue] = ["message": .string("Layout updated: \(args.changedList)."), "layout": layoutJSON(s)]
        if !notes.isEmpty { result["notes"] = .strings(notes) }
        return ToolOutcome(result: .object(result))
    }

    static func setLanguage(_ args: ToolArgs, _ state: inout DockState) throws -> ToolOutcome {
        try args.requireAny()
        var s = state.settings
        if args.has("language") { s.language = try languageArgument(args) }
        if let v = try args.choice("calendar", CalendarSystem.self, aliases: ["solarhijri": .persian, "jalali": .persian, "hijri": .islamic]) { s.calendarSystem = v }
        if let v = try args.choice("digits", DigitStyle.self, aliases: ["western": .latin, "arabic": .latin, "persian": .native, "local": .native]) { s.digitStyle = v }
        if let v = try args.choice("clock", ClockStyle.self, aliases: ["24": .h24, "24h": .h24, "24hour": .h24, "12": .h12, "12h": .h12, "12hour": .h12]) { s.clockStyle = v }
        if let v = try args.bool("use_estedad") { s.useEstedad = v }
        state.settings = s
        return ToolOutcome(result: ["message": .string("Language settings updated: \(args.changedList)."), "language": languageJSON(s)])
    }

    // MARK: - Profiles

    static func switchProfile(_ args: ToolArgs, _ state: inout DockState) throws -> ToolOutcome {
        let p = try profileIndex(args.values["profile"], state)
        state.activeProfileID = state.profiles[p].id
        return ToolOutcome(result: ["message": .string("Switched to \(state.profiles[p].name)."), "active_profile": profileRef(state, p)])
    }

    static func createProfile(_ args: ToolArgs, _ state: inout DockState) throws -> ToolOutcome {
        guard state.profiles.count < DockProfile.maxProfiles else {
            throw ToolFailure("NiceDock keeps at most \(DockProfile.maxProfiles) profiles; rename or reuse one instead.")
        }
        let name = try profileName(args, state, excluding: nil)
        var profile = DockProfile(name: name)
        var effects: [DockEffect] = []
        if args.has("duplicate_from") {
            let source = state.profiles[try profileIndex(args.values["duplicate_from"], state)]
            profile.symbol = source.symbol
            profile.widgets = source.widgets.map { w in
                var copy = w
                copy.id = UUID()
                effects.append(.copySecrets(from: w.id, to: copy.id))
                return copy
            }
        }
        if let symbol = try symbolArgument(args) { profile.symbol = symbol }
        state.profiles.append(profile)
        let activate = try args.bool("activate") ?? true
        if activate { state.activeProfileID = profile.id }
        let i = state.profiles.count - 1
        return ToolOutcome(result: [
            "message": .string("Created profile \(name)\(activate ? " and switched to it" : "")."),
            "profile": profileJSON(state, i)
        ], effects: effects)
    }

    static func renameProfile(_ args: ToolArgs, _ state: inout DockState) throws -> ToolOutcome {
        guard args.has("name") || args.has("symbol") else { throw ToolFailure("Nothing to change: pass name and/or symbol.") }
        let p = try profileIndex(args.values["profile"], state)
        let old = state.profiles[p].name
        if args.has("name") { state.profiles[p].name = try profileName(args, state, excluding: p) }
        if let symbol = try symbolArgument(args) { state.profiles[p].symbol = symbol }
        return ToolOutcome(result: [
            "message": .string(old == state.profiles[p].name ? "Updated profile \(old)." : "Renamed \(old) to \(state.profiles[p].name)."),
            "profile": profileRef(state, p)
        ])
    }

    static func profileName(_ args: ToolArgs, _ state: DockState, excluding: Int?) throws -> String {
        let name = (try args.string("name") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ToolFailure("name can't be empty.") }
        guard name.count <= DockProfile.maxNameLength else {
            throw ToolFailure("name is \(name.count) characters; profile names have at most \(DockProfile.maxNameLength).")
        }
        if let clash = state.profiles.indices.first(where: { $0 != excluding && state.profiles[$0].name.lowercased() == name.lowercased() }) {
            throw ToolFailure("A profile named \(state.profiles[clash].name) already exists (index \(clash)).")
        }
        return name
    }

    static func symbolArgument(_ args: ToolArgs) throws -> String? {
        guard let symbol = try args.string("symbol") else { return nil }
        guard DockProfile.symbolChoices.contains(symbol) else {
            throw ToolFailure("Unknown symbol '\(symbol)'. Valid symbols: \(DockProfile.symbolChoices.joined(separator: ", ")).")
        }
        return symbol
    }

    // MARK: - Lookups

    static func normalized(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

    static func kindArgument(_ args: ToolArgs, _ key: String) throws -> WidgetKind {
        let raw = try args.string(key) ?? ""
        let n = normalized(raw)
        if let kind = WidgetKind.allCases.first(where: { normalized($0.rawValue) == n }) ?? WidgetKind.allCases.first(where: { normalized($0.spec.title) == n }) {
            return kind
        }
        throw ToolFailure("Unknown widget kind '\(raw)'. Valid kinds: \(WidgetCatalog.browsable.map(\.rawValue).joined(separator: ", ")). Call list_widget_kinds for details.")
    }

    static func languageArgument(_ args: ToolArgs) throws -> AppLanguage {
        let raw = try args.string("language") ?? ""
        let n = normalized(raw)
        let aliases: [String: AppLanguage] = ["farsi": .fa, "zh": .zhHans, "chinese": .zhHans, "zhcn": .zhHans, "simplifiedchinese": .zhHans,
                                              "default": .system, "auto": .system, "automatic": .system]
        if let lang = AppLanguage.allCases.first(where: {
            normalized($0.rawValue) == n || normalized($0.englishName) == n || $0.nativeName.lowercased() == raw.lowercased()
        }) ?? aliases[n] {
            return lang
        }
        throw ToolFailure("Unknown language '\(raw)'. Valid languages: \(AppLanguage.allCases.map { "\($0.rawValue) (\($0.englishName))" }.joined(separator: ", ")).")
    }

    static func visibilityArgument(_ args: ToolArgs, _ kind: WidgetKind) throws -> VisibilityRule? {
        guard let rule = try args.choice("visibility", VisibilityRule.self) else { return nil }
        let allowed = [VisibilityRule.always] + kind.spec.visibility
        guard allowed.contains(rule) else {
            throw ToolFailure("\(kind.rawValue) supports visibility \(allowed.map(\.rawValue).joined(separator: ", ")); '\(rule.rawValue)' isn't one of them.")
        }
        return rule
    }

    static func profileList(_ state: DockState) -> String {
        state.profiles.enumerated().map { "\($0) \($1.name) (\($1.id.uuidString))" }.joined(separator: "; ")
    }

    /// Profile by index (number or numeric string), id, unique id prefix or name. nil → active profile.
    static func profileIndex(_ ref: JSONValue?, _ state: DockState) throws -> Int {
        guard let ref, ref != .null else { return state.activeIndex }
        if let i = ref.intValue {
            guard state.profiles.indices.contains(i) else { throw ToolFailure("No profile at index \(i). Profiles: \(profileList(state)).") }
            return i
        }
        guard let raw = ref.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            throw ToolFailure("profile must be a profile id, name or index, got \(ref.brief).")
        }
        if let i = Int(raw) {
            guard state.profiles.indices.contains(i) else { throw ToolFailure("No profile at index \(i). Profiles: \(profileList(state)).") }
            return i
        }
        let lower = raw.lowercased()
        if let i = state.profiles.firstIndex(where: { $0.id.uuidString.lowercased() == lower || $0.name.lowercased() == lower }) { return i }
        let prefixed = state.profiles.indices.filter { state.profiles[$0].id.uuidString.lowercased().hasPrefix(lower) }
        if lower.count >= 4, prefixed.count == 1 { return prefixed[0] }
        throw ToolFailure("No profile '\(raw)'. Profiles: \(profileList(state)).")
    }

    static func widgetLocation(_ args: ToolArgs, _ state: DockState) throws -> (profile: Int, index: Int) {
        let raw = (try args.string("widget_id") ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var matches: [(Int, Int)] = []
        for (p, profile) in state.profiles.enumerated() {
            for (i, w) in profile.widgets.enumerated() {
                let id = w.id.uuidString.lowercased()
                if id == raw { return (p, i) }
                if raw.count >= 4 && id.hasPrefix(raw) { matches.append((p, i)) }
            }
        }
        if matches.count == 1 { return matches[0] }
        if matches.count > 1 { throw ToolFailure("Widget id '\(raw)' is ambiguous; use the full id from get_dock.") }
        throw ToolFailure("No widget with id '\(raw)'. Call get_dock for the current widget ids.")
    }

    // MARK: - Widget settings

    /// Validates `input` against the kind's fields and writes it into `widget.config`. null restores a default.
    static func applyConfig(_ input: [String: JSONValue], to widget: inout WidgetInstance) throws {
        let spec = widget.kind.spec
        for key in input.keys.sorted() {
            let value = input[key]!
            guard let field = spec.fields.first(where: { $0.key == key }) else {
                if spec.fields.isEmpty { throw ToolFailure("\(widget.kind.rawValue) has no settings.") }
                throw ToolFailure("Unknown setting '\(key)' for \(widget.kind.rawValue). Valid settings: \(spec.fields.map(\.key).joined(separator: ", ")).")
            }
            if value == .null {
                widget.config[key] = spec.defaults[key]
                continue
            }
            widget.config[key] = try configValue(field, value, kind: widget.kind)
        }
    }

    static func configValue(_ f: ConfigField, _ value: JSONValue, kind: WidgetKind) throws -> String {
        let name = "\(kind.rawValue).\(f.key)"
        func text(_ limit: Int = 2000) throws -> String {
            let s: String
            switch value {
            case .string(let v): s = v
            case .number, .bool: s = value.brief
            default: throw ToolFailure("\(name) must be a string, got \(value.brief).")
            }
            guard s.count <= limit else { throw ToolFailure("\(name) is too long (\(s.count) characters, at most \(limit)).") }
            return s
        }
        func lines() throws -> [String] {
            switch value {
            case .array(let items):
                return try items.map { item in
                    guard let s = item.stringValue ?? (item.doubleValue != nil ? item.brief : nil) else {
                        throw ToolFailure("\(name) must be a list of strings, got \(item.brief) in the list.")
                    }
                    return s.trimmingCharacters(in: .whitespacesAndNewlines)
                }.filter { !$0.isEmpty }
            case .string(let s): return s.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            default: throw ToolFailure("\(name) must be a list (array of strings), got \(value.brief).")
            }
        }
        switch f.type {
        case .secret:
            throw ToolFailure("\(name) is a secret. Tokens never pass through the assistant: ask the user to paste it in NiceDock (right-click the widget → Customize…).")
        case .contacts:
            throw ToolFailure("\(name) is chosen from Contacts in NiceDock (right-click the widget → Customize…).")
        case .text: return try text()
        case .city: return try text(100).trimmingCharacters(in: .whitespacesAndNewlines)
        case .multiline:
            let items = try lines()
            guard items.count <= 50 else { throw ToolFailure("\(name) takes at most 50 items.") }
            return items.joined(separator: "\n")
        case .number(let min, let max, let step, let unit):
            let number: Double?
            switch value {
            case .number(let n): number = n
            case .string(let s): number = Double(s.trimmingCharacters(in: .whitespaces))
            default: number = nil
            }
            guard let number, number.isFinite else { throw ToolFailure("\(name) must be a number, got \(value.brief).") }
            guard number >= min && number <= max else {
                throw ToolFailure("\(name) must be between \(ToolArgs.format(min)) and \(ToolArgs.format(max))\(unit.isEmpty ? "" : " " + unit); got \(ToolArgs.format(number)).")
            }
            let snapped = Swift.min(max, Swift.max(min, (number / step).rounded() * step))
            return snapped == snapped.rounded() ? String(Int(snapped)) : String(snapped)
        case .toggle:
            switch value {
            case .bool(let b): return b ? "1" : "0"
            case .number(let n) where n == 0 || n == 1: return n == 1 ? "1" : "0"
            case .string(let s) where ["true", "1", "on", "yes"].contains(s.lowercased()): return "1"
            case .string(let s) where ["false", "0", "off", "no"].contains(s.lowercased()): return "0"
            default: throw ToolFailure("\(name) must be true or false, got \(value.brief).")
            }
        case .choice(let options):
            let raw = try text()
            if let match = options.first(where: { $0.value.lowercased() == raw.lowercased() })
                ?? options.first(where: { normalized($0.title) == normalized(raw) }) {
                return match.value
            }
            throw ToolFailure("\(name) must be one of \(options.map(\.value).joined(separator: ", ")); got '\(raw)'.")
        case .color:
            let raw = try text()
            guard let hex = WallpaperColor.hex(raw) else {
                throw ToolFailure("\(name) must be a colour like #30D158 or a name (\(WallpaperColor.names.joined(separator: ", "))); got '\(raw)'.")
            }
            return hex
        case .app: return try appPath(try text(), name)
        case .apps:
            let items = try lines()
            guard items.count <= 40 else { throw ToolFailure("\(name) takes at most 40 apps.") }
            return try items.map { try appPath($0, name) }.joined(separator: "\n")
        case .folder:
            let path = try text(1024).trimmingCharacters(in: .whitespacesAndNewlines)
            guard path.hasPrefix("/") || path.hasPrefix("~") else { throw ToolFailure("\(name) must be an absolute folder path such as ~/Documents; got '\(path)'.") }
            return path
        }
    }

    /// Folders apps live in. Only these are looked into, so resolving a name never touches privacy-protected folders.
    static var appFolders: [String] {
        ["/Applications", "/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities",
         (NSHomeDirectory() as NSString).appendingPathComponent("Applications")]
    }

    static func appPath(_ raw: String, _ name: String) throws -> String {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let fm = FileManager.default
        if input.hasPrefix("/") || input.hasPrefix("~") {
            let path = (input as NSString).expandingTildeInPath
            guard path.hasSuffix(".app") else { throw ToolFailure("\(name) must be an .app bundle path; got '\(input)'.") }
            if appFolders.contains(where: { path.hasPrefix($0 + "/") }), !fm.fileExists(atPath: path) {
                throw ToolFailure("No app at \(path).")
            }
            return path
        }
        let bundle = input.hasSuffix(".app") ? input : input + ".app"
        for folder in appFolders {
            let path = (folder as NSString).appendingPathComponent(bundle)
            if fm.fileExists(atPath: path) { return path }
        }
        if bundle.lowercased() == "finder.app" { return "/System/Library/CoreServices/Finder.app" }
        throw ToolFailure("Couldn't find an app named '\(input)' in /Applications or /System/Applications; pass the full .app path.")
    }
}

/// Typed access to a tool's arguments with validation messages an assistant can act on.
struct ToolArgs {
    let tool: AssistantTool
    let values: [String: JSONValue]

    init(tool: AssistantTool, values: [String: JSONValue]) throws {
        let allowed = tool.argumentNames
        for key in values.keys.sorted() where !allowed.contains(key) {
            throw ToolFailure(allowed.isEmpty
                ? "\(tool.name) takes no arguments (got '\(key)')."
                : "Unknown argument '\(key)' for \(tool.name). Valid arguments: \(allowed.sorted().joined(separator: ", ")).")
        }
        for key in tool.required where values[key] == nil || values[key] == .null {
            throw ToolFailure("Missing required argument '\(key)' for \(tool.name).")
        }
        self.tool = tool
        self.values = values
    }

    func has(_ key: String) -> Bool { values[key].map { $0 != .null } ?? false }

    /// Arguments that were passed, for confirmation messages.
    var changedList: String {
        values.keys.filter(has).sorted().map { key in "\(key)=\(values[key]!.stringValue ?? values[key]!.brief)" }.joined(separator: ", ")
    }

    func requireAny() throws {
        guard values.keys.contains(where: has) else {
            throw ToolFailure("Pass at least one of: \(tool.argumentNames.sorted().joined(separator: ", ")).")
        }
    }

    func string(_ key: String) throws -> String? {
        guard let v = values[key], v != .null else { return nil }
        switch v {
        case .string(let s): return s
        case .number: return v.brief
        default: throw ToolFailure("\(key) must be a string, got \(v.brief).")
        }
    }

    func object(_ key: String) throws -> [String: JSONValue]? {
        guard let v = values[key], v != .null else { return nil }
        guard let o = v.objectValue else { throw ToolFailure("\(key) must be an object of setting → value, got \(v.brief).") }
        return o
    }

    func bool(_ key: String) throws -> Bool? {
        guard let v = values[key], v != .null else { return nil }
        switch v {
        case .bool(let b): return b
        case .string(let s) where ["true", "false"].contains(s.lowercased()): return s.lowercased() == "true"
        default: throw ToolFailure("\(key) must be true or false, got \(v.brief).")
        }
    }

    func int(_ key: String, in range: ClosedRange<Int>) throws -> Int? {
        guard let v = values[key], v != .null else { return nil }
        guard let n = v.intValue ?? v.stringValue.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) else {
            throw ToolFailure("\(key) must be a whole number, got \(v.brief).")
        }
        guard range.contains(n) else { throw ToolFailure("\(key) must be between \(range.lowerBound) and \(range.upperBound); got \(n).") }
        return n
    }

    /// Number within `range`, snapped to the slider step Settings uses.
    func double(_ key: String, in range: ClosedRange<Double>, step: Double, unit: String = "") throws -> Double? {
        guard let v = values[key], v != .null else { return nil }
        guard let n = v.doubleValue ?? v.stringValue.flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }), n.isFinite else {
            throw ToolFailure("\(key) must be a number, got \(v.brief).")
        }
        guard range.contains(n) else {
            throw ToolFailure("\(key) must be between \(Self.format(range.lowerBound)) and \(Self.format(range.upperBound))\(unit.isEmpty ? "" : " " + unit); got \(Self.format(n)).")
        }
        let snapped = ((n / step).rounded() * step * 1000).rounded() / 1000
        return min(range.upperBound, max(range.lowerBound, snapped))
    }

    func choice<E: RawRepresentable & CaseIterable>(_ key: String, _ type: E.Type, aliases: [String: E] = [:]) throws -> E? where E.RawValue == String {
        guard let raw = try string(key) else { return nil }
        let n = DockTools.normalized(raw)
        if let match = E.allCases.first(where: { DockTools.normalized($0.rawValue) == n }) ?? aliases[n] { return match }
        throw ToolFailure("Unknown \(key) '\(raw)'. Valid values: \(E.allCases.map(\.rawValue).joined(separator: ", ")).")
    }

    static func format(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(v) }
}
