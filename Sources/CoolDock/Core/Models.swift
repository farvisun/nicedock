import Foundation
import SwiftUI

// MARK: - Widget instance & profiles

/// Conditional visibility rule (right-click → Visibility).
enum VisibilityRule: String, Codable, CaseIterable, Identifiable {
    case always, whilePlaying, cpuHigh, memoryHigh, temperatureHigh, lowBattery, beforeMeetings, inZoomMeeting, whileRunning
    var id: String { rawValue }
    var title: String {
        switch self {
        case .always: return L("Always visible")
        case .whilePlaying: return L("Show while playing")
        case .cpuHigh: return L("Show when CPU is high")
        case .memoryHigh: return L("Show when memory is high")
        case .temperatureHigh: return L("Show when temperature is high")
        case .lowBattery: return L("Show on low battery")
        case .beforeMeetings: return L("Show before meetings")
        case .inZoomMeeting: return L("Show while in a Zoom meeting")
        case .whileRunning: return L("Show while running")
        }
    }
}

struct WidgetInstance: Codable, Identifiable, Hashable {
    var id = UUID()
    var kind: WidgetKind
    var config: [String: String] = [:]
    var visibility: VisibilityRule = .always

    init(kind: WidgetKind, config: [String: String] = [:]) {
        self.kind = kind
        self.config = kind.spec.defaults.merging(config) { _, new in new }
    }

    func string(_ key: String, _ fallback: String = "") -> String {
        if let v = config[key], !v.isEmpty { return v }
        return kind.spec.defaults[key] ?? fallback
    }
    func int(_ key: String, _ fallback: Int = 0) -> Int { Int(string(key)) ?? fallback }
    func double(_ key: String, _ fallback: Double = 0) -> Double { Double(string(key)) ?? fallback }
    func bool(_ key: String, _ fallback: Bool = false) -> Bool {
        let v = string(key)
        return v.isEmpty ? fallback : (v == "1" || v == "true")
    }
    func list(_ key: String) -> [String] {
        string(key).split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }
}

struct DockProfile: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var symbol: String = "square.grid.2x2"
    var widgets: [WidgetInstance] = []

    /// Symbols offered for profile tabs (Settings → Profiles and the AI Assistant).
    static let symbolChoices = ["house", "briefcase", "cpu", "music.note", "moon", "sun.max", "leaf", "flame", "graduationcap", "gamecontroller",
                                "paintbrush", "chart.bar", "airplane", "cup.and.saucer", "heart", "star", "bolt", "terminal", "camera", "book"]
    static let maxProfiles = 8
    static let maxNameLength = 24
}

// MARK: - Categories

enum WidgetCategory: String, CaseIterable, Identifiable, Codable {
    case apps, folders, clocks, calendar, reminders, weather, system, controls, media, photos
    case mail, notes, phone, stocks, crypto, finance, commerce, analytics, developer, social, ai, utilities

    var id: String { rawValue }
    var title: String {
        switch self {
        case .apps: return L("Apps")
        case .folders: return L("Folders & Files")
        case .clocks: return L("Clocks")
        case .calendar: return L("Calendar")
        case .reminders: return L("Reminders & Tasks")
        case .weather: return L("Weather")
        case .system: return L("System")
        case .controls: return L("Controls")
        case .media: return L("Media")
        case .photos: return L("Photos")
        case .mail: return L("Mail")
        case .notes: return L("Notes")
        case .phone: return L("Phone")
        case .stocks: return L("Stocks")
        case .crypto: return L("Crypto")
        case .finance: return L("Finance")
        case .commerce: return L("Commerce")
        case .analytics: return L("Analytics")
        case .developer: return L("Developer")
        case .social: return L("Social")
        case .ai: return L("AI")
        case .utilities: return L("Utilities")
        }
    }
    var symbol: String {
        switch self {
        case .apps: return "app.badge"
        case .folders: return "folder"
        case .clocks: return "clock"
        case .calendar: return "calendar"
        case .reminders: return "checklist"
        case .weather: return "cloud.sun"
        case .system: return "cpu"
        case .controls: return "switch.2"
        case .media: return "play.circle"
        case .photos: return "photo"
        case .mail: return "envelope"
        case .notes: return "note.text"
        case .phone: return "person.crop.circle"
        case .stocks: return "chart.line.uptrend.xyaxis"
        case .crypto: return "bitcoinsign.circle"
        case .finance: return "dollarsign.circle"
        case .commerce: return "bag"
        case .analytics: return "chart.bar"
        case .developer: return "chevron.left.forwardslash.chevron.right"
        case .social: return "person.2"
        case .ai: return "sparkles"
        case .utilities: return "wrench.and.screwdriver"
        }
    }
    var tint: Color {
        switch self {
        case .apps: return .cdBlue
        case .folders: return .cdCyan
        case .clocks: return .cdOrange
        case .calendar: return .cdRed
        case .reminders: return .cdOrange
        case .weather: return .cdTeal
        case .system: return .cdGreen
        case .controls: return .cdIndigo
        case .media: return .cdPink
        case .photos: return .cdYellow
        case .mail: return .cdBlue
        case .notes: return .cdYellow
        case .phone: return .cdGreen
        case .stocks: return .cdGreen
        case .crypto: return .cdOrange
        case .finance: return .cdMint
        case .commerce: return .cdGreen
        case .analytics: return .cdPurple
        case .developer: return .cdGray
        case .social: return .cdPink
        case .ai: return .cdOrange
        case .utilities: return .cdBrown
        }
    }
}

// MARK: - Config schema

struct ConfigOption: Hashable {
    let value: String
    let title: String
}

enum ConfigFieldType {
    case text(placeholder: String)
    case multiline(placeholder: String)
    case secret(placeholder: String)
    case number(min: Double, max: Double, step: Double, unit: String)
    case toggle
    case choice([ConfigOption])
    case color
    case app
    case apps
    case folder
    case city
    case contacts
}

struct ConfigField {
    let key: String
    let title: String
    let type: ConfigFieldType
    var help: String? = nil
    /// Shown only while another field has one of these values (provider-specific fields). Several fields may share
    /// a key when their conditions never overlap (e.g. one token field per provider with its own placeholder).
    var shownWhen: (key: String, values: Set<String>)? = nil

    func isShown(in w: WidgetInstance) -> Bool {
        guard let rule = shownWhen else { return true }
        return rule.values.contains(w.string(rule.key))
    }
}
