import Foundation

/// One MCP tool: name, description and JSON Schema of its arguments.
struct AssistantTool {
    enum Access {
        /// Reads CoolDock; allowed while the assistant is read-only.
        case read
        /// Renders a wallpaper file into CoolDock's own folder without applying it; allowed while read-only.
        case preview
        /// Changes the dock, a profile or the desktop; needs Allow Changes.
        case change
    }

    let name: String
    let displayName: String
    let description: String
    let access: Access
    let properties: [String: JSONValue]
    var required: [String] = []
    var idempotent = false
    var destructive = false

    var argumentNames: Set<String> { Set(properties.keys) }
    var isWallpaper: Bool { name == "set_wallpaper" || name == "preview_wallpaper" }

    var inputSchema: JSONValue {
        var o: [String: JSONValue] = ["type": "object", "properties": .object(properties), "additionalProperties": false]
        if !required.isEmpty { o["required"] = .strings(required) }
        return .object(o)
    }

    /// Entry of a `tools/list` result.
    var listing: JSONValue {
        .object([
            "name": .string(name),
            "title": .string(displayName),
            "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": .object([
                "title": .string(displayName),
                "readOnlyHint": .bool(access != .change),
                "destructiveHint": .bool(destructive),
                "idempotentHint": .bool(idempotent || access != .change),
                "openWorldHint": false
            ])
        ])
    }
}

/// JSON Schema fragments.
enum Schema {
    static func string(_ description: String, oneOf values: [String]? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["type": "string", "description": .string(description)]
        if let values { o["enum"] = .strings(values) }
        return .object(o)
    }

    static func integer(_ description: String, min: Int? = nil, max: Int? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["type": "integer", "description": .string(description)]
        if let min { o["minimum"] = .int(min) }
        if let max { o["maximum"] = .int(max) }
        return .object(o)
    }

    static func number(_ description: String, min: Double, max: Double) -> JSONValue {
        .object(["type": "number", "description": .string(description), "minimum": .double(min), "maximum": .double(max)])
    }

    static func boolean(_ description: String) -> JSONValue {
        .object(["type": "boolean", "description": .string(description)])
    }

    static func object(_ description: String) -> JSONValue {
        .object(["type": "object", "description": .string(description), "additionalProperties": true])
    }

    static func raw<E: RawRepresentable & CaseIterable>(_ type: E.Type) -> [String] where E.RawValue == String {
        E.allCases.map(\.rawValue)
    }
}

enum AssistantTools {
    static let profileArgument = Schema.string("Profile id, name, or 0-based index. Defaults to the active profile.")
    static let widgetArgument = Schema.string("Widget id from get_dock (a unique prefix of at least 4 characters also works).")

    static let wallpaperProperties: [String: JSONValue] = [
        "mood": Schema.string("Feeling of the image.", oneOf: Schema.raw(WallpaperMood.self)),
        "style": Schema.string("Composition. Omit to let CoolDock pick one that suits the other parameters.", oneOf: Schema.raw(WallpaperStyle.self)),
        "color": Schema.string("Dominant colour: a name (\(WallpaperColor.names.prefix(12).joined(separator: ", ")), …) or a hex value like #3A7BD5."),
        "time_of_day": Schema.string("Light of the scene.", oneOf: Schema.raw(WallpaperTime.self)),
        "season": Schema.string("Season palette.", oneOf: Schema.raw(WallpaperSeason.self)),
        "weather": Schema.string("Weather effects.", oneOf: Schema.raw(WallpaperWeather.self)),
        "variation": Schema.integer("Another take on the same parameters (0 = first). The same parameters and variation always give the same image.", min: 0, max: 9999)
    ]

    static let all: [AssistantTool] = [
        AssistantTool(
            name: "get_dock", displayName: "Get Dock",
            description: "Summary of CoolDock: appearance (dock style, size, spacing, corner radius, theme…), layout scenario and position, language, and every profile with its widgets (ids, kinds, positions, settings). Call this first; ids from here are used by the other tools.",
            access: .read, properties: [:]),
        AssistantTool(
            name: "list_widget_kinds", displayName: "List Widget Kinds",
            description: "Catalog of widget kinds that can be added: kind id, English title, category, width in points and each setting with its type, allowed values and default.",
            access: .read,
            properties: [
                "category": Schema.string("Only kinds in this category.", oneOf: Schema.raw(WidgetCategory.self)),
                "kind": Schema.string("Only this kind (id or English title).")
            ]),
        AssistantTool(
            name: "add_widget", displayName: "Add Widget",
            description: "Adds a widget to a profile. Settings not given keep their defaults; see list_widget_kinds for kinds and settings. API tokens can't be set here — the user enters them in CoolDock.",
            access: .change,
            properties: [
                "kind": Schema.string("Widget kind id, e.g. flipClock, weatherHero, stockQuote (or its English title)."),
                "profile": profileArgument,
                "position": Schema.integer("0-based position in the profile. Omit (or -1) to append at the end.", min: -1),
                "config": Schema.object("Widget settings as key → value (strings, numbers, booleans; lists as arrays)."),
                "visibility": Schema.string("When the widget shows. Only rules listed for the kind are accepted.", oneOf: Schema.raw(VisibilityRule.self))
            ],
            required: ["kind"]),
        AssistantTool(
            name: "remove_widget", displayName: "Remove Widget",
            description: "Removes a widget from its profile, including any API token saved for it.",
            access: .change, properties: ["widget_id": widgetArgument], required: ["widget_id"], destructive: true),
        AssistantTool(
            name: "move_widget", displayName: "Move Widget",
            description: "Moves a widget to another position, optionally into another profile.",
            access: .change,
            properties: [
                "widget_id": widgetArgument,
                "position": Schema.integer("New 0-based position. -1 moves it to the end.", min: -1),
                "profile": Schema.string("Target profile id, name, or 0-based index. Omit to stay in the current profile.")
            ],
            required: ["widget_id", "position"], idempotent: true),
        AssistantTool(
            name: "update_widget_config", displayName: "Update Widget Settings",
            description: "Changes some settings of a widget; other settings stay as they are. A null value restores that setting's default.",
            access: .change,
            properties: [
                "widget_id": widgetArgument,
                "config": Schema.object("Settings to change, key → value. See list_widget_kinds for the kind's settings."),
                "visibility": Schema.string("When the widget shows. Only rules listed for the kind are accepted.", oneOf: Schema.raw(VisibilityRule.self))
            ],
            required: ["widget_id"], idempotent: true),
        AssistantTool(
            name: "set_appearance", displayName: "Set Appearance",
            description: "Changes how the Dock looks. Pass only what should change.",
            access: .change,
            properties: [
                "dock_style": Schema.string("Dock bar style (liquidGlass needs macOS 26).", oneOf: Schema.raw(DockStyle.self)),
                "widget_surface": Schema.string("Widget tiles on the transparent dock style.", oneOf: Schema.raw(WidgetSurface.self)),
                "theme": Schema.string("CoolDock windows: follow macOS, light or dark.", oneOf: Schema.raw(AppTheme.self)),
                "scale": Schema.number("Dock size, 1 = 100 %.", min: 0.7, max: 1.4),
                "spacing": Schema.number("Space between widgets in points.", min: 0, max: 20),
                "corner_radius": Schema.number("Widget corner radius in points.", min: 4, max: 22),
                "overflow": Schema.string("When widgets don't fit: shrink them or scroll.", oneOf: Schema.raw(OverflowMode.self)),
                "monochrome": Schema.boolean("Remove accent colours from charts, controls and chrome."),
                "tile_backgrounds": Schema.boolean("Frosted fills and outlines around each widget."),
                "shadow": Schema.boolean("Shadow under the Dock."),
                "reduce_transparency": Schema.boolean("Solid fills instead of glass blur."),
                "icon_style": Schema.string("App icon style.", oneOf: Schema.raw(AppIconStyle.self)),
                "animations": Schema.boolean("Animate showing, hiding and switching.")
            ],
            idempotent: true),
        AssistantTool(
            name: "set_layout", displayName: "Set Layout",
            description: "Changes where the Dock sits and how it reveals. Setting position alone switches to the fixed scenario.",
            access: .change,
            properties: [
                "scenario": Schema.string("swapBottom: bottom, macOS Dock takes over at the edge · revealBottom/revealTop: hidden until the pointer reaches the edge · fixed: always visible at `position` · replaceDock / replaceAutoHide: hide the macOS Dock · floating: drag anywhere.", oneOf: Schema.raw(LayoutScenario.self)),
                "position": Schema.string("Screen position for the fixed scenario.", oneOf: Schema.raw(ScreenPosition.self)),
                "edge_distance": Schema.number("Distance from the screen edge in points.", min: 0, max: 80),
                "alignment": Schema.string("Horizontal alignment for the reveal and replace scenarios.", oneOf: Schema.raw(DockAlignment.self)),
                "show_delay": Schema.number("Reveal delay in seconds.", min: 0, max: 2),
                "hide_delay": Schema.number("Hide delay in seconds.", min: 0, max: 3),
                "trigger_size": Schema.number("Reveal trigger area in pixels.", min: 1, max: 60),
                "hide_on_window_hover": Schema.boolean("Fade out when another window overlaps the Dock."),
                "hide_during_fullscreen": Schema.boolean("Hide while an app or video is fullscreen."),
                "screens": Schema.string("Displays that show CoolDock.", oneOf: Schema.raw(ScreensMode.self))
            ],
            idempotent: true),
        AssistantTool(
            name: "set_language", displayName: "Set Language",
            description: "Changes CoolDock's language and regional formats. Changes apply instantly.",
            access: .change,
            properties: [
                "language": Schema.string("Language code (system follows macOS).", oneOf: Schema.raw(AppLanguage.self)),
                "calendar": Schema.string("Calendar system.", oneOf: Schema.raw(CalendarSystem.self)),
                "digits": Schema.string("Digit shapes.", oneOf: Schema.raw(DigitStyle.self)),
                "clock": Schema.string("Time format.", oneOf: Schema.raw(ClockStyle.self)),
                "use_estedad": Schema.boolean("Use the Estedad typeface for Persian and Arabic.")
            ],
            idempotent: true),
        AssistantTool(
            name: "switch_profile", displayName: "Switch Profile",
            description: "Makes another profile the active one shown in the Dock.",
            access: .change, properties: ["profile": Schema.string("Profile id, name, or 0-based index.")], required: ["profile"], idempotent: true),
        AssistantTool(
            name: "create_profile", displayName: "Create Profile",
            description: "Creates a profile (CoolDock keeps up to 8), empty or as a copy of another one, and makes it active unless activate is false.",
            access: .change,
            properties: [
                "name": Schema.string("Profile name, up to 24 characters."),
                "symbol": Schema.string("SF Symbol shown on the profile tab.", oneOf: DockProfile.symbolChoices),
                "duplicate_from": Schema.string("Copy the widgets of this profile (id, name, or 0-based index)."),
                "activate": Schema.boolean("Switch to the new profile (default true).")
            ],
            required: ["name"]),
        AssistantTool(
            name: "rename_profile", displayName: "Rename Profile",
            description: "Renames a profile and/or changes its symbol.",
            access: .change,
            properties: [
                "profile": Schema.string("Profile id, name, or 0-based index."),
                "name": Schema.string("New name, up to 24 characters."),
                "symbol": Schema.string("New SF Symbol.", oneOf: DockProfile.symbolChoices)
            ],
            required: ["profile"], idempotent: true),
        AssistantTool(
            name: "set_wallpaper", displayName: "Set Wallpaper",
            description: "Paints a wallpaper on this Mac from mood, style, colour, time of day, season and weather (all optional), at the main display's pixel size, saves it in CoolDock's Wallpapers folder and sets it as the desktop picture on every display. Returns the file path.",
            access: .change, properties: wallpaperProperties, idempotent: true),
        AssistantTool(
            name: "preview_wallpaper", displayName: "Preview Wallpaper",
            description: "Same as set_wallpaper but only paints and saves the image and returns its path; the desktop is not changed.",
            access: .preview, properties: wallpaperProperties)
    ]

    static func named(_ name: String) -> AssistantTool? { all.first { $0.name == name } }

    static var listing: JSONValue { .object(["tools": .array(all.map(\.listing))]) }
}
