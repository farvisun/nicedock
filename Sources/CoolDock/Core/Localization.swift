import Foundation

/// Languages CoolDock ships with. English strings are the lookup keys, so `en` needs no table.
enum AppLanguage: String, CaseIterable, Codable, Identifiable {
    case system
    case en
    case fa
    case ar
    case de
    case fr
    case es
    case tr
    case ru
    case zhHans = "zh-Hans"
    case ja

    var id: String { rawValue }

    /// Language actually used once `system` has been resolved against the user's preferred languages.
    var resolved: AppLanguage {
        guard self == .system else { return self }
        for preferred in Locale.preferredLanguages {
            let code = preferred.lowercased()
            if code.hasPrefix("zh-hans") || code.hasPrefix("zh-cn") || code.hasPrefix("zh-sg") { return .zhHans }
            let base = String(code.prefix(2))
            if let match = AppLanguage(rawValue: base), match != .system { return match }
        }
        return .en
    }

    var isRTL: Bool { self == .fa || self == .ar }

    /// Persian and Arabic render with the bundled Estedad typeface.
    var usesEstedad: Bool { self == .fa || self == .ar }

    var localeIdentifier: String {
        switch self {
        case .system: return resolved.localeIdentifier
        case .en: return "en_US"
        case .fa: return "fa_IR"
        case .ar: return "ar"
        case .de: return "de_DE"
        case .fr: return "fr_FR"
        case .es: return "es_ES"
        case .tr: return "tr_TR"
        case .ru: return "ru_RU"
        case .zhHans: return "zh_Hans_CN"
        case .ja: return "ja_JP"
        }
    }

    /// Name of the language written in that language.
    var nativeName: String {
        switch self {
        case .system: return L("System Default")
        case .en: return "English"
        case .fa: return "فارسی"
        case .ar: return "العربية"
        case .de: return "Deutsch"
        case .fr: return "Français"
        case .es: return "Español"
        case .tr: return "Türkçe"
        case .ru: return "Русский"
        case .zhHans: return "简体中文"
        case .ja: return "日本語"
        }
    }

    var englishName: String {
        switch self {
        case .system: return "System"
        case .en: return "English"
        case .fa: return "Persian"
        case .ar: return "Arabic"
        case .de: return "German"
        case .fr: return "French"
        case .es: return "Spanish"
        case .tr: return "Turkish"
        case .ru: return "Russian"
        case .zhHans: return "Chinese (Simplified)"
        case .ja: return "Japanese"
        }
    }
}

/// Runtime string lookup that can switch language without relaunching.
/// Tables are plain `.strings` files in `Resources/<code>.lproj/Localizable.strings`.
enum Localizer {
    nonisolated(unsafe) private static var table: [String: String] = [:]
    nonisolated(unsafe) private(set) static var language: AppLanguage = .en

    static func activate(_ requested: AppLanguage) {
        let lang = requested.resolved
        language = lang
        table = lang == .en ? [:] : loadTable(lang.rawValue)
    }

    static func loadTable(_ code: String) -> [String: String] {
        let candidates = [
            Bundle.main.url(forResource: "Localizable", withExtension: "strings", subdirectory: "\(code).lproj"),
            Bundle.main.resourceURL?.appendingPathComponent("\(code).lproj/Localizable.strings"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Resources/\(code).lproj/Localizable.strings")
        ]
        for case let url? in candidates {
            if let dict = NSDictionary(contentsOf: url) as? [String: String] { return dict }
        }
        return [:]
    }

    static func string(_ key: String) -> String {
        if let value = table[key], !value.isEmpty { return value }
        return key
    }
}

/// Localized string for an English key.
@inline(__always)
func L(_ key: String) -> String { Localizer.string(key) }

/// Localized format string; numeric arguments are rendered with the active number system.
func L(_ key: String, _ args: CVarArg...) -> String {
    let format = Localizer.string(key)
    return String(format: format, locale: Fmt.locale, arguments: args)
}
