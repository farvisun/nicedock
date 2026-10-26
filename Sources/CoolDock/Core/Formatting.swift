import Foundation

enum CalendarSystem: String, Codable, CaseIterable, Identifiable {
    case automatic, gregorian, persian, islamic
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return L("Automatic")
        case .gregorian: return L("Gregorian")
        case .persian: return L("Persian (Solar Hijri)")
        case .islamic: return L("Islamic (Hijri)")
        }
    }
}

enum DigitStyle: String, Codable, CaseIterable, Identifiable {
    case automatic, latin, native
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return L("Automatic")
        case .latin: return L("Latin (0123)")
        case .native: return L("Native (۰۱۲۳)")
        }
    }
}

enum ClockStyle: String, Codable, CaseIterable, Identifiable {
    case automatic, h24, h12
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return L("Automatic")
        case .h24: return L("24-hour")
        case .h12: return L("12-hour")
        }
    }
}

/// Central, cached formatters. Rebuilt whenever language or region preferences change.
enum Fmt {
    nonisolated(unsafe) private(set) static var locale = Locale(identifier: "en_US")
    nonisolated(unsafe) private(set) static var calendar = Calendar(identifier: .gregorian)
    nonisolated(unsafe) private(set) static var uses24h = true
    nonisolated(unsafe) private(set) static var nativeDigits = false

    nonisolated(unsafe) private static var cache: [String: DateFormatter] = [:]
    nonisolated(unsafe) private static var decimal = NumberFormatter()
    nonisolated(unsafe) private static var percent = NumberFormatter()

    static func configure(language: AppLanguage, calendar system: CalendarSystem, digits: DigitStyle, clock: ClockStyle) {
        let lang = language.resolved
        var identifier = lang == .en ? (Locale.current.identifier.hasPrefix("en") ? Locale.current.identifier : "en_US") : lang.localeIdentifier
        let wantsNative: Bool
        switch digits {
        case .automatic: wantsNative = lang == .fa || lang == .ar
        case .native: wantsNative = true
        case .latin: wantsNative = false
        }
        nativeDigits = wantsNative && (lang == .fa || lang == .ar)
        if !nativeDigits && (lang == .fa || lang == .ar) { identifier += "@numbers=latn" }
        if nativeDigits && lang == .fa { identifier = "fa_IR@numbers=arabext" }
        if nativeDigits && lang == .ar { identifier = "ar@numbers=arab" }

        let calendarID: Calendar.Identifier
        switch system {
        case .automatic: calendarID = lang == .fa ? .persian : .gregorian
        case .gregorian: calendarID = .gregorian
        case .persian: calendarID = .persian
        case .islamic: calendarID = .islamicUmmAlQura
        }
        var cal = Calendar(identifier: calendarID)
        let loc = Locale(identifier: identifier)
        cal.locale = loc
        cal.firstWeekday = lang == .fa ? 7 : Calendar.current.firstWeekday
        locale = loc
        calendar = cal

        switch clock {
        case .h24: uses24h = true
        case .h12: uses24h = false
        case .automatic:
            let template = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: Locale.current) ?? "H"
            uses24h = !template.contains("a")
        }

        cache.removeAll()
        let dec = NumberFormatter()
        dec.locale = loc
        dec.numberStyle = .decimal
        decimal = dec
        let pct = NumberFormatter()
        pct.locale = loc
        pct.numberStyle = .percent
        pct.maximumFractionDigits = 0
        percent = pct
    }

    // MARK: Dates

    static func formatter(_ template: String) -> DateFormatter {
        if let f = cache[template] { return f }
        let f = DateFormatter()
        f.locale = locale
        f.calendar = calendar
        f.setLocalizedDateFormatFromTemplate(template)
        cache[template] = f
        return f
    }

    static func fixed(_ format: String) -> DateFormatter {
        let key = "#" + format
        if let f = cache[key] { return f }
        let f = DateFormatter()
        f.locale = locale
        f.calendar = calendar
        f.dateFormat = format
        cache[key] = f
        return f
    }

    static func date(_ date: Date, _ template: String) -> String { formatter(template).string(from: date) }

    /// "12:34" or "12:34:56" without AM/PM marker; honours the 12/24h preference.
    static func clock(_ date: Date, seconds: Bool = false, zone: TimeZone? = nil) -> String {
        let pattern = (uses24h ? "HH:mm" : "h:mm") + (seconds ? ":ss" : "")
        let f = fixed(pattern)
        if let zone {
            let copy = f.copy() as! DateFormatter
            copy.timeZone = zone
            return copy.string(from: date)
        }
        return f.string(from: date)
    }

    static func ampm(_ date: Date) -> String? {
        uses24h ? nil : fixed("a").string(from: date)
    }

    static func weekdayShort(_ date: Date) -> String { fixed("EEE").string(from: date) }
    static func weekday(_ date: Date) -> String { fixed("EEEE").string(from: date) }
    static func monthShort(_ date: Date) -> String { fixed("MMM").string(from: date) }
    static func month(_ date: Date) -> String { fixed("LLLL").string(from: date) }
    static func dayNumber(_ date: Date) -> String { fixed("d").string(from: date) }
    static func year(_ date: Date) -> String { fixed("y").string(from: date) }

    static func relativeDay(_ date: Date) -> String {
        let cal = calendar
        if cal.isDateInToday(date) { return L("Today") }
        if cal.isDateInTomorrow(date) { return L("Tomorrow") }
        if cal.isDateInYesterday(date) { return L("Yesterday") }
        return weekdayShort(date)
    }

    static func duration(_ interval: TimeInterval, tenths: Bool = false) -> String {
        let total = max(0, interval)
        let h = Int(total) / 3600
        let m = (Int(total) % 3600) / 60
        let s = Int(total) % 60
        var out: String
        if h > 0 { out = String(format: "%d:%02d:%02d", h, m, s) } else { out = String(format: "%d:%02d", m, s) }
        if tenths { out += String(format: ".%d", Int((total - floor(total)) * 10)) }
        return digits(out)
    }

    static func minutesLeft(_ interval: TimeInterval) -> String {
        let m = Int(ceil(interval / 60))
        if m >= 60 { return L("%dh", m / 60) }
        return L("%dm", m)
    }

    // MARK: Numbers

    /// Replace ASCII digits with the active native digit set.
    static func digits(_ s: String) -> String {
        guard nativeDigits else { return s }
        let base: UInt32 = Localizer.language == .ar ? 0x0660 : 0x06F0
        var out = ""
        out.reserveCapacity(s.count)
        for scalar in s.unicodeScalars {
            if scalar.value >= 48 && scalar.value <= 57, let u = UnicodeScalar(base + scalar.value - 48) {
                out.unicodeScalars.append(u)
            } else if scalar == "%" {
                out.unicodeScalars.append("٪")
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    static func int(_ value: Int) -> String {
        decimal.maximumFractionDigits = 0
        return decimal.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func number(_ value: Double, decimals: Int = 0) -> String {
        decimal.minimumFractionDigits = decimals
        decimal.maximumFractionDigits = decimals
        let s = decimal.string(from: NSNumber(value: value)) ?? String(value)
        decimal.minimumFractionDigits = 0
        return s
    }

    static func percent(_ fraction: Double) -> String {
        percent.string(from: NSNumber(value: fraction)) ?? "\(Int(fraction * 100))%"
    }

    /// 12K, 1.2M, 3.4B
    static func compact(_ value: Double) -> String {
        let a = abs(value)
        let sign = value < 0 ? "-" : ""
        let (v, suffix): (Double, String)
        switch a {
        case 1_000_000_000...: (v, suffix) = (a / 1_000_000_000, L("B"))
        case 1_000_000...: (v, suffix) = (a / 1_000_000, L("M"))
        case 10_000...: (v, suffix) = (a / 1_000, L("K"))
        default: return sign + int(Int(a))
        }
        let decimals = v < 10 && v != floor(v) ? 1 : 0
        return sign + number(v, decimals: decimals) + suffix
    }

    static func currency(_ value: Double, code: String, decimals: Int? = nil) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .currency
        f.currencyCode = code
        if let decimals {
            f.minimumFractionDigits = decimals
            f.maximumFractionDigits = decimals
        }
        return f.string(from: NSNumber(value: value)) ?? "\(code) \(value)"
    }

    static func signedPercent(_ value: Double, decimals: Int = 2) -> String {
        let sign = value >= 0 ? "+" : "−"
        return digits(sign) + number(abs(value), decimals: decimals) + digits("%")
    }

    static func signed(_ value: Double, decimals: Int = 2) -> String {
        let sign = value >= 0 ? "+" : "−"
        return sign + number(abs(value), decimals: decimals)
    }

    static func bytes(_ value: Double, perSecond: Bool = false) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = value
        var i = 0
        while v >= 1000 && i < units.count - 1 { v /= 1000; i += 1 }
        let decimals = v < 10 && i > 0 ? 1 : 0
        return number(v, decimals: decimals) + " " + L(units[i]) + (perSecond ? L("/s") : "")
    }

    static func temperature(_ celsius: Double, unit: TemperatureUnit, symbolOnly: Bool = true) -> String {
        let v = unit == .fahrenheit ? celsius * 9 / 5 + 32 : celsius
        return int(Int(v.rounded())) + "°"
    }
}

enum TemperatureUnit: String, Codable, CaseIterable, Identifiable {
    case automatic, celsius, fahrenheit
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return L("Automatic")
        case .celsius: return L("Celsius (°C)")
        case .fahrenheit: return L("Fahrenheit (°F)")
        }
    }
    var resolved: TemperatureUnit {
        guard self == .automatic else { return self }
        return Locale.current.measurementSystem == .us ? .fahrenheit : .celsius
    }
}
