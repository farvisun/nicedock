import Foundation
import SwiftUI

enum AppTheme: String, Codable, CaseIterable, Identifiable {
    case auto, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return L("Auto")
        case .light: return L("Light")
        case .dark: return L("Dark")
        }
    }
}

enum LayoutScenario: String, Codable, CaseIterable, Identifiable {
    case swapBottom, revealBottom, fixed, revealTop, revealSide, replaceDock, replaceAutoHide, floating
    var id: String { rawValue }
    var title: String {
        switch self {
        case .swapBottom: return L("Swap at the Bottom")
        case .revealBottom: return L("Reveal at the Bottom")
        case .fixed: return L("Fixed")
        case .revealTop: return L("Reveal on Top")
        case .revealSide: return L("Reveal from the Side")
        case .replaceDock: return L("Replace the macOS Dock")
        case .replaceAutoHide: return L("Replace & Auto-Hide")
        case .floating: return L("Floating")
        }
    }
    var summary: String {
        switch self {
        case .swapBottom: return L("NiceDock stays at the bottom; move to the edge and the auto-hiding macOS Dock takes over.")
        case .revealBottom: return L("Hidden until the pointer reaches the bottom edge, then slides up above the macOS Dock.")
        case .fixed: return L("Always visible at one of twelve screen positions.")
        case .revealTop: return L("Hidden until the pointer reaches the top edge, then reveals below the menu bar.")
        case .revealSide: return L("Hidden until the pointer reaches the left or right edge, then slides in as a column.")
        case .replaceDock: return L("Hide the macOS Dock while NiceDock runs and keep NiceDock fixed at the bottom or a side.")
        case .replaceAutoHide: return L("Hide the macOS Dock and reveal NiceDock only at its screen edge.")
        case .floating: return L("Drag NiceDock anywhere on the selected display.")
        }
    }
    var symbol: String {
        switch self {
        case .swapBottom: return "arrow.up.arrow.down.square"
        case .revealBottom: return "rectangle.bottomhalf.inset.filled"
        case .fixed: return "pin"
        case .revealTop: return "rectangle.tophalf.inset.filled"
        case .revealSide: return "rectangle.lefthalf.inset.filled"
        case .replaceDock: return "dock.rectangle"
        case .replaceAutoHide: return "eye.slash"
        case .floating: return "hand.draw"
        }
    }
    var isReveal: Bool { self == .revealBottom || self == .revealTop || self == .revealSide || self == .replaceAutoHide }
    var isTop: Bool { self == .revealTop }
    /// Hides the macOS Dock and takes its place at `Settings.replaceSide`.
    var isReplace: Bool { self == .replaceDock || self == .replaceAutoHide }
    var recommended: Bool { self == .swapBottom }
}

/// Where a fixed Dock sits. Top and bottom positions are rows; left and right positions are columns along a side edge.
enum ScreenPosition: String, Codable, CaseIterable, Identifiable {
    case topLeft, topCenter, topRight, bottomLeft, bottomCenter, bottomRight
    case leftTop, leftCenter, leftBottom, rightTop, rightCenter, rightBottom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .topLeft: return L("Top Left")
        case .topCenter: return L("Top Center")
        case .topRight: return L("Top Right")
        case .bottomLeft: return L("Bottom Left")
        case .bottomCenter: return L("Bottom Center")
        case .bottomRight: return L("Bottom Right")
        case .leftTop: return L("Left Top")
        case .leftCenter: return L("Left Center")
        case .leftBottom: return L("Left Bottom")
        case .rightTop: return L("Right Top")
        case .rightCenter: return L("Right Center")
        case .rightBottom: return L("Right Bottom")
        }
    }
    var isTop: Bool { self == .topLeft || self == .topCenter || self == .topRight }
    var edge: DockSide {
        switch self {
        case .topLeft, .topCenter, .topRight: return .top
        case .bottomLeft, .bottomCenter, .bottomRight: return .bottom
        case .leftTop, .leftCenter, .leftBottom: return .left
        case .rightTop, .rightCenter, .rightBottom: return .right
        }
    }
    /// Alignment along the Dock's own axis: `.left` is the start (left of a row, top of a column).
    var alignment: DockAlignment {
        switch self {
        case .topLeft, .bottomLeft, .leftTop, .rightTop: return .left
        case .topCenter, .bottomCenter, .leftCenter, .rightCenter: return .center
        case .topRight, .bottomRight, .leftBottom, .rightBottom: return .right
        }
    }
}

/// The screen edge a Dock lives on. Left and right Docks are vertical columns.
enum DockSide: String, Codable, CaseIterable, Identifiable, Sendable {
    case bottom, top, left, right
    var id: String { rawValue }
    var isVertical: Bool { self == .left || self == .right }
    var title: String {
        switch self {
        case .bottom: return L("Bottom")
        case .top: return L("Top")
        case .left: return L("Left")
        case .right: return L("Right")
        }
    }
}

/// Alignment along the Dock's axis. On a vertical Dock `.left` means top and `.right` means bottom.
enum DockAlignment: String, Codable, CaseIterable, Identifiable {
    case center, left, right
    var id: String { rawValue }
    var title: String {
        switch self {
        case .center: return L("Center")
        case .left: return L("Left")
        case .right: return L("Right")
        }
    }
    func title(vertical: Bool) -> String {
        guard vertical else { return title }
        switch self {
        case .center: return L("Center")
        case .left: return L("Top")
        case .right: return L("Bottom")
        }
    }
}

enum OverflowMode: String, Codable, CaseIterable, Identifiable {
    case adapt, scroll
    var id: String { rawValue }
    var title: String { self == .adapt ? L("Adapt Size") : L("Scroll") }
}

enum ScreensMode: String, Codable, CaseIterable, Identifiable {
    case one, attached, all
    var id: String { rawValue }
    var title: String {
        switch self {
        case .one: return L("One Display")
        case .attached: return L("Attached Displays")
        case .all: return L("All Displays")
        }
    }
}

enum RunningAppsPlacement: String, Codable, CaseIterable, Identifiable {
    case hidden, left, beforeApps, afterApps, right
    var id: String { rawValue }
    var title: String {
        switch self {
        case .hidden: return L("Don't show")
        case .left: return L("Left side")
        case .beforeApps: return L("Before apps")
        case .afterApps: return L("After apps")
        case .right: return L("Right side")
        }
    }
}

enum AppIconStyle: String, Codable, CaseIterable, Identifiable {
    case standard, auto, dark, monochrome
    var id: String { rawValue }
    var title: String {
        switch self {
        case .standard: return L("Default")
        case .auto: return L("Auto")
        case .dark: return L("Dark")
        case .monochrome: return L("Monochrome")
        }
    }
}

struct HotKeySpec: Codable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32 // Carbon modifier mask
    var enabled: Bool = true
}

struct KnownDisplay: Codable, Hashable, Identifiable {
    var id: String // stable UUID string from CGDisplayCreateUUIDFromDisplayID
    var name: String
    var customName: String?
    var builtIn: Bool
    var attached: Bool = true
    var lastSeen: Date = Date()
    var displayName: String { customName?.isEmpty == false ? customName! : name }
}

/// Everything the user can configure. Persisted as JSON.
struct Settings: Codable, Equatable {
    // General
    var launchAtLogin = false
    var showMenuBarIcon = true
    var temperatureUnit: TemperatureUnit = .automatic
    var screenshotFolder: String? = nil
    var onboardingDone = false

    // Language & region
    var language: AppLanguage = .system
    var calendarSystem: CalendarSystem = .automatic
    var digitStyle: DigitStyle = .automatic
    var clockStyle: ClockStyle = .automatic
    var useEstedad = true

    // Appearance
    var appTheme: AppTheme = .auto
    var dockStyle: DockStyle = .darkGlass
    var widgetSurface: WidgetSurface = .glass
    var dockScale: Double = 1.0
    var widgetSpacing: Double = 6
    var cornerRadius: Double = 11.5
    var overflow: OverflowMode = .adapt
    var monochrome = false
    var tileBackgrounds = true
    var reduceTransparency = false
    var iconStyle: AppIconStyle = .standard
    var shadow = true
    var animations = true

    // Layout
    var scenario: LayoutScenario = .fixed
    var fixedPosition: ScreenPosition = .bottomCenter
    var edgeDistance: Double = 8
    var alignment: DockAlignment = .center
    var showDelay: Double = 0
    var hideDelay: Double = 0
    var triggerSize: Double = 3
    var hideOnWindowHover = false
    var hideDuringFullscreen = true
    var floatingOrigins: [String: CGPointCodable] = [:]

    // Screens
    var screensMode: ScreensMode = .one
    var preferredDisplay: String? = nil
    var displays: [KnownDisplay] = []

    // Dock
    var runningApps: RunningAppsPlacement = .hidden
    var runningAppsCollapsed = false
    var openFoldersInFinder = false
    var dragAppsToRearrange = false
    var showProfileSwitcher = true
    var dragToSwitchProfiles = true
    var showAppLabelsOnHover = true
    var showRunningIndicators = true

    // Shortcuts
    var toggleHotKey = HotKeySpec(keyCode: 2 /* D */, modifiers: 0x1000 | 0x0800 | 0x0100) // ⌃⌥⌘
    var profileHotKeyModifiers: UInt32 = 0x1000 | 0x0800 | 0x0100
    var profileHotKeysEnabled = true

    // Performance
    var systemSampleInterval: Double = 2
    var pauseWhenHidden = true

    // Calendar
    /// ICS/webcal subscriptions shown by the calendar widgets (secret links live in the Keychain, see `CalendarFeed`).
    /// Optional on purpose: synthesized `Decodable` treats a missing optional key as nil, so state files written
    /// before this setting existed still load. New settings must follow the same rule.
    var calendarFeeds: [CalendarFeed]? = nil

    // Windows (Layout → Dock Space). Optional for the same reason; read and bind through the non-optional accessors.
    /// Other apps' windows end at the Dock's edge when they open, zoom, tile or restore (needs Accessibility).
    var reserveDockSpace: Bool? = nil
    /// Reserve Dock Space also moves windows the user dragged or resized over the Dock.
    var reserveAfterDragging: Bool? = nil

    var reservesDockSpace: Bool {
        get { reserveDockSpace ?? false }
        set { reserveDockSpace = newValue }
    }

    var reservesAfterDragging: Bool {
        get { reserveAfterDragging ?? false }
        set { reserveAfterDragging = newValue }
    }

    // Side Docks. Optional for the same reason as `calendarFeeds`; read and bind through the non-optional accessors.
    /// Edge for Reveal from the Side: left (nil) or right.
    var revealEdge: DockSide? = nil
    /// Edge for Replace the macOS Dock and Replace & Auto-Hide: bottom (nil), left or right.
    var replaceEdge: DockSide? = nil
    /// Floating Dock laid out as a column.
    var floatingVertical: Bool? = nil

    /// Left or right; any other stored value reads as left.
    var revealSideEdge: DockSide {
        get { revealEdge == .right ? .right : .left }
        set { revealEdge = newValue == .right ? .right : .left }
    }

    /// Bottom, left or right; top reads as bottom (the macOS Dock never sits at the top).
    var replaceSide: DockSide {
        get { replaceEdge?.isVertical == true ? replaceEdge! : .bottom }
        set { replaceEdge = newValue.isVertical ? newValue : .bottom }
    }

    var floatsVertically: Bool {
        get { floatingVertical ?? false }
        set { floatingVertical = newValue }
    }

    // AI Assistant (MCP). Optional for the same reason as `calendarFeeds`; nil means off.
    /// MCP clients may read NiceDock (`NiceDock --mcp`). Off by default: every tool answers "disabled".
    var aiAssistantEnabled: Bool? = nil
    /// MCP clients may also change NiceDock. Off by default: the assistant is read-only.
    var aiAllowChanges: Bool? = nil

    var assistantEnabled: Bool {
        get { aiAssistantEnabled ?? false }
        set { aiAssistantEnabled = newValue }
    }

    var assistantAllowsChanges: Bool {
        get { aiAllowChanges ?? false }
        set { aiAllowChanges = newValue }
    }

    // App Volume (macOS 14.2+). Optional for the same reason as `calendarFeeds`.
    /// Volume and mute per app, keyed by bundle id (executable path for tools without one). Only changed apps are kept.
    var appVolumes: [String: UtilAppVolumeLevel]? = nil
    /// Restore each app's volume the next time it plays. nil means on.
    var appVolumeRemember: Bool? = nil

    var remembersAppVolumes: Bool {
        get { appVolumeRemember ?? true }
        set { appVolumeRemember = newValue }
    }
}

extension Settings {
    /// Settings → Screens → Move Up / Move Down. With Attached Displays the first connected one in this order wins.
    mutating func moveDisplay(_ id: String, by delta: Int) {
        guard let i = displays.firstIndex(where: { $0.id == id }) else { return }
        displays.swapAt(i, max(0, min(displays.count - 1, i + delta)))
    }

    /// Settings → Screens → Rename…. An empty name shows the display's own name again.
    mutating func renameDisplay(_ id: String, to name: String) {
        guard let i = displays.firstIndex(where: { $0.id == id }) else { return }
        displays[i].customName = name.trimmingCharacters(in: .whitespaces)
    }
}

struct CGPointCodable: Codable, Equatable {
    var x: Double
    var y: Double
}
