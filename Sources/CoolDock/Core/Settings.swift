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
    case swapBottom, revealBottom, fixed, revealTop, replaceDock, replaceAutoHide, floating
    var id: String { rawValue }
    var title: String {
        switch self {
        case .swapBottom: return L("Swap at the Bottom")
        case .revealBottom: return L("Reveal at the Bottom")
        case .fixed: return L("Fixed")
        case .revealTop: return L("Reveal on Top")
        case .replaceDock: return L("Replace the macOS Dock")
        case .replaceAutoHide: return L("Replace & Auto-Hide")
        case .floating: return L("Floating")
        }
    }
    var summary: String {
        switch self {
        case .swapBottom: return L("CoolDock stays at the bottom; move to the edge and the auto-hiding macOS Dock takes over.")
        case .revealBottom: return L("Hidden until the pointer reaches the bottom edge, then slides up above the macOS Dock.")
        case .fixed: return L("Always visible at one of six screen positions.")
        case .revealTop: return L("Hidden until the pointer reaches the top edge, then reveals below the menu bar.")
        case .replaceDock: return L("Hide the macOS Dock while CoolDock runs and keep CoolDock fixed at the bottom.")
        case .replaceAutoHide: return L("Hide the macOS Dock and reveal CoolDock only at the bottom edge.")
        case .floating: return L("Drag CoolDock anywhere on the selected display.")
        }
    }
    var symbol: String {
        switch self {
        case .swapBottom: return "arrow.up.arrow.down.square"
        case .revealBottom: return "rectangle.bottomhalf.inset.filled"
        case .fixed: return "pin"
        case .revealTop: return "rectangle.tophalf.inset.filled"
        case .replaceDock: return "dock.rectangle"
        case .replaceAutoHide: return "eye.slash"
        case .floating: return "hand.draw"
        }
    }
    var isReveal: Bool { self == .revealBottom || self == .revealTop || self == .replaceAutoHide }
    var isTop: Bool { self == .revealTop }
    var recommended: Bool { self == .swapBottom }
}

enum ScreenPosition: String, Codable, CaseIterable, Identifiable {
    case topLeft, topCenter, topRight, bottomLeft, bottomCenter, bottomRight
    var id: String { rawValue }
    var title: String {
        switch self {
        case .topLeft: return L("Top Left")
        case .topCenter: return L("Top Center")
        case .topRight: return L("Top Right")
        case .bottomLeft: return L("Bottom Left")
        case .bottomCenter: return L("Bottom Center")
        case .bottomRight: return L("Bottom Right")
        }
    }
    var isTop: Bool { self == .topLeft || self == .topCenter || self == .topRight }
    var alignment: DockAlignment {
        switch self {
        case .topLeft, .bottomLeft: return .left
        case .topCenter, .bottomCenter: return .center
        case .topRight, .bottomRight: return .right
        }
    }
}

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
    var dockStyle: DockStyle = .lightGlass
    var widgetSurface: WidgetSurface = .glass
    var dockScale: Double = 1.0
    var widgetSpacing: Double = 6
    var cornerRadius: Double = 12
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
}

struct CGPointCodable: Codable, Equatable {
    var x: Double
    var y: Double
}
