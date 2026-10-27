import Foundation

/// Dependency-free RFC 5545 (iCalendar) reader for calendar subscription feeds: Google Calendar, iCloud,
/// Outlook, Fastmail or any webcal:// link.
///
/// Covers what real feeds contain: line unfolding, VEVENT with DTSTART/DTEND/DURATION (all-day dates, UTC,
/// floating and TZID times; a TZID the system doesn't know falls back to the feed's VTIMEZONE), text unescaping,
/// STATUS:CANCELLED, RRULE (DAILY/WEEKLY/MONTHLY/YEARLY with INTERVAL, COUNT, UNTIL, BYDAY, BYMONTHDAY, BYMONTH,
/// BYSETPOS, WKST), RDATE, EXDATE and RECURRENCE-ID overrides.
///
/// Times stay wall-clock values in their own zone and are placed on the timeline per occurrence, so a weekly
/// 09:00 Los Angeles meeting stays at 09:00 local time across daylight-saving changes.
enum ICS {
    // MARK: Model

    /// A parsed feed: calendar name/colour hints and its VEVENTs.
    struct Feed: Sendable {
        var name: String?
        var color: String?
        var events: [Event]
    }

    /// One VEVENT as written in the feed: a single event, a series master or a RECURRENCE-ID override.
    struct Event: Sendable {
        var uid: String
        var summary: String
        var start: Time
        var end: Time?
        var duration: Duration?
        var location: String?
        var notes: String?
        var url: URL?
        /// Conference link from vendor properties (X-GOOGLE-CONFERENCE, Teams).
        var conference: String?
        var rule: Rule?
        var rdates: [Time] = []
        var exdates: [Time] = []
        var recurrenceID: Time?
        var cancelled = false

        init(uid: String, summary: String, start: Time) {
            self.uid = uid
            self.summary = summary
            self.start = start
        }

        var allDay: Bool { start.isDate }
    }

    /// A concrete instance on the timeline.
    struct Occurrence: Equatable, Sendable {
        var uid: String
        var title: String
        var start: Date
        var end: Date
        var allDay: Bool
        var location: String?
        var notes: String?
        var url: URL?
        var conference: String?
    }

    /// DATE or DATE-TIME: wall-clock seconds since 1970 as written (no offset applied) and the clock it belongs to.
    struct Time: Equatable, Sendable {
        var wall: Int
        var zone: Zone
        var isDate: Bool

        var day: Int { ICS.floorDiv(wall, 86_400) }

        func instant(local: TimeZone = .current) -> Date {
            Date(timeIntervalSince1970: TimeInterval(ICS.seconds(wall, zone, local: local)))
        }
    }

    enum Zone: Equatable, Sendable {
        case utc
        /// No zone given: the reader's local time (all-day dates use it too).
        case floating
        case named(TimeZone)
        /// A VTIMEZONE whose TZID the system doesn't know (Outlook "Customized Time Zone", …).
        case rules(ZoneRules)
    }

    struct Duration: Equatable, Sendable {
        /// Nominal days (weeks × 7 + days): calendar days, so "P1D" across a DST change is still one day.
        var days: Int
        /// Exact seconds (hours, minutes, seconds).
        var seconds: Int
    }

    struct Rule: Equatable, Sendable {
        enum Frequency: String, Sendable { case daily = "DAILY", weekly = "WEEKLY", monthly = "MONTHLY", yearly = "YEARLY" }
        /// BYDAY entry: weekday 0 = Sunday … 6 = Saturday; ordinal 0 = every such weekday, 2 = second, -1 = last.
        struct Day: Equatable, Sendable {
            var ordinal: Int
            var weekday: Int
        }

        var freq: Frequency
        var interval = 1
        var count: Int?
        var until: Time?
        var byDay: [Day] = []
        var byMonthDay: [Int] = []
        var byMonth: [Int] = []
        var bySetPos: [Int] = []
        var weekStart = 1

        static let weekdays = ["SU": 0, "MO": 1, "TU": 2, "WE": 3, "TH": 4, "FR": 5, "SA": 6]

        /// `zone` is DTSTART's: a floating UNTIL is read in it. Sub-daily frequencies return nil (shown once).
        init?(_ value: String, zone: Zone) {
            var parts: [String: String] = [:]
            for item in value.split(separator: ";") {
                let kv = item.split(separator: "=", maxSplits: 1)
                if kv.count == 2 { parts[kv[0].trimmingCharacters(in: .whitespaces).uppercased()] = kv[1].trimmingCharacters(in: .whitespaces) }
            }
            guard let freq = parts["FREQ"].flatMap({ Frequency(rawValue: $0.uppercased()) }) else { return nil }
            self.freq = freq
            interval = max(1, Int(parts["INTERVAL"] ?? "") ?? 1)
            count = Int(parts["COUNT"] ?? "").map { max(1, $0) }
            if let u = parts["UNTIL"], var t = ICS.time(u, params: [:], zones: nil) {
                if t.zone == .floating && !t.isDate { t.zone = zone }
                until = t
            }
            func ints(_ key: String, _ range: ClosedRange<Int>) -> [Int] {
                (parts[key] ?? "").split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "+", with: "")) }
                    .filter { $0 != 0 && range.contains(abs($0)) }
            }
            byMonthDay = ints("BYMONTHDAY", 1...31)
            byMonth = ints("BYMONTH", 1...12).filter { $0 > 0 }
            bySetPos = ints("BYSETPOS", 1...366)
            byDay = (parts["BYDAY"] ?? "").split(separator: ",").compactMap { raw in
                let s = raw.trimmingCharacters(in: .whitespaces).uppercased()
                guard s.count >= 2, let wd = Self.weekdays[String(s.suffix(2))] else { return nil }
                let prefix = s.dropLast(2).replacingOccurrences(of: "+", with: "")
                guard prefix.isEmpty || Int(prefix) != nil else { return nil }
                return Day(ordinal: Int(prefix) ?? 0, weekday: wd)
            }
            weekStart = parts["WKST"].flatMap { Self.weekdays[$0.uppercased()] } ?? 1
        }
    }

    /// Offsets from a VTIMEZONE definition, used when its TZID isn't in the system database.
    struct ZoneRules: Equatable, Sendable {
        struct Observance: Equatable, Sendable {
            /// DTSTART: local wall time (in the old offset) the observance begins.
            var start: Int
            var offsetFrom: Int
            var offsetTo: Int
            var rule: Rule?
            var rdates: [Int]

            func latestOnset(atOrBefore t: Int) -> Int? {
                guard start <= t else { return rdates.filter { $0 <= t }.max() }
                var best = start
                for r in rdates where r <= t { best = max(best, r) }
                if let rule {
                    let until = rule.until?.wall
                    let walls = ICS.recurrenceWalls(start: start, rule: rule, from: t - 2 * 366 * 86_400, to: t + 1) { w in until.map { w > $0 } ?? false }
                    if let last = walls.last { best = max(best, last) }
                }
                return best
            }
        }

        var observances: [Observance]

        init?(_ c: Component) {
            var list: [Observance] = []
            for child in c.children where child.name == "STANDARD" || child.name == "DAYLIGHT" {
                guard let startValue = child.first("DTSTART")?.value, let start = ICS.wallClock(startValue)?.wall,
                      let to = child.first("TZOFFSETTO").flatMap({ ICS.utcOffset($0.value) }) else { continue }
                let from = child.first("TZOFFSETFROM").flatMap { ICS.utcOffset($0.value) } ?? to
                let rule = child.first("RRULE").flatMap { Rule($0.value, zone: .floating) }
                let rdates = child.all("RDATE").flatMap { $0.value.split(separator: ",").compactMap { ICS.wallClock(String($0))?.wall } }
                list.append(Observance(start: start, offsetFrom: from, offsetTo: to, rule: rule, rdates: rdates))
            }
            guard !list.isEmpty else { return nil }
            observances = list
        }

        /// UTC offset in effect at a local wall time: the observance with the latest onset at or before it.
        func offset(atWall t: Int) -> Int {
            var best: (onset: Int, offset: Int)?
            for o in observances {
                guard let onset = o.latestOnset(atOrBefore: t) else { continue }
                if best.map({ onset > $0.onset }) ?? true { best = (onset, o.offsetTo) }
            }
            return best?.offset ?? observances.min { $0.start < $1.start }?.offsetFrom ?? 0
        }
    }

    // MARK: Parsing

    static func parse(_ data: Data) -> Feed { parse(bytes: [UInt8](data)) }
    static func parse(_ text: String) -> Feed { parse(bytes: Array(text.utf8)) }

    private static func parse(bytes: [UInt8]) -> Feed {
        var definitions: [String: Component] = [:]
        var vevents: [Component] = []
        var name: String?
        var color: String?
        func collect(_ c: Component) {
            switch c.name {
            case "VCALENDAR":
                if name == nil { name = c.first("X-WR-CALNAME").map { text($0.value) }.flatMap(nonEmpty) }
                if color == nil { color = c.first("X-APPLE-CALENDAR-COLOR").flatMap { hexColor($0.value) } }
                c.children.forEach(collect)
            case "VTIMEZONE":
                if let id = c.first("TZID")?.value { definitions[id] = c }
            case "VEVENT":
                vevents.append(c)
            default:
                break
            }
        }
        components(lines(bytes)).forEach(collect)
        let zones = ZoneResolver(definitions)
        return Feed(name: name, color: color, events: vevents.compactMap { event($0, zones: zones) })
    }

    struct Property: Sendable {
        var name: String
        var params: [String: String]
        var value: String
    }

    struct Component: Sendable {
        var name: String
        var properties: [Property] = []
        var children: [Component] = []

        func first(_ name: String) -> Property? { properties.first { $0.name == name } }
        func all(_ name: String) -> [Property] { properties.filter { $0.name == name } }
    }

    /// Content lines with folding undone (CRLF or LF followed by one space or tab). Works on bytes, so a fold that
    /// splits a multi-byte UTF-8 character still joins correctly.
    static func lines(_ bytes: [UInt8]) -> [[UInt8]] {
        var out: [[UInt8]] = []
        out.reserveCapacity(bytes.count / 48)
        var current: [UInt8] = []
        let n = bytes.count
        var i = n >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF ? 3 : 0
        while i < n {
            let b = bytes[i]
            if b == 0x0D || b == 0x0A {
                var j = i + 1
                if b == 0x0D, j < n, bytes[j] == 0x0A { j += 1 }
                if j < n, bytes[j] == 0x20 || bytes[j] == 0x09 { i = j + 1; continue }
                if !current.isEmpty { out.append(current); current = [] }
                i = j
                continue
            }
            current.append(b)
            i += 1
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// `NAME;PARAM=value;PARAM="quoted:value":VALUE`. Names and parameter keys are upper-cased.
    static func property(_ u: [UInt8]) -> Property? {
        let n = u.count
        var i = 0
        while i < n, u[i] != 0x3B, u[i] != 0x3A { i += 1 }
        guard i > 0, i < n else { return nil }
        let name = String(decoding: u[0..<i], as: UTF8.self).uppercased()
        var params: [String: String] = [:]
        while i < n, u[i] == 0x3B {
            i += 1
            let keyStart = i
            while i < n, u[i] != 0x3D, u[i] != 0x3B, u[i] != 0x3A { i += 1 }
            let key = String(decoding: u[keyStart..<i], as: UTF8.self).uppercased()
            var value: [UInt8] = []
            if i < n, u[i] == 0x3D {
                i += 1
                var quoted = false
                while i < n {
                    let c = u[i]
                    if c == 0x22 { quoted.toggle(); i += 1; continue }
                    if !quoted, c == 0x3B || c == 0x3A { break }
                    value.append(c)
                    i += 1
                }
            }
            if !key.isEmpty { params[key] = String(decoding: value, as: UTF8.self) }
        }
        guard i < n, u[i] == 0x3A else { return nil }
        return Property(name: name, params: params, value: String(decoding: u[(i + 1)...], as: UTF8.self))
    }

    static func components(_ lines: [[UInt8]]) -> [Component] {
        var stack: [Component] = []
        var roots: [Component] = []
        func close() {
            guard let done = stack.popLast() else { return }
            if stack.isEmpty { roots.append(done) } else { stack[stack.count - 1].children.append(done) }
        }
        for line in lines {
            guard let p = property(line) else { continue }
            switch p.name {
            case "BEGIN": stack.append(Component(name: p.value.trimmingCharacters(in: .whitespaces).uppercased()))
            case "END": close()
            default: if !stack.isEmpty { stack[stack.count - 1].properties.append(p) }
            }
        }
        while !stack.isEmpty { close() }
        return roots
    }

    /// TEXT value unescaping: `\n`/`\N` → newline, `\,` `\;` `\\` → the character (lenient for others).
    static func text(_ raw: String) -> String {
        guard raw.contains("\\") else { return raw }
        var out = ""
        out.reserveCapacity(raw.count)
        var escaping = false
        for ch in raw {
            if escaping {
                out.append(ch == "n" || ch == "N" ? "\n" : ch)
                escaping = false
            } else if ch == "\\" {
                escaping = true
            } else {
                out.append(ch)
            }
        }
        if escaping { out.append("\\") }
        return out
    }

    private static func event(_ c: Component, zones: ZoneResolver) -> Event? {
        guard let dtstart = c.first("DTSTART"), let start = time(dtstart.value, params: dtstart.params, zones: zones) else { return nil }
        let summary = c.first("SUMMARY").map { text($0.value).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        let uid = c.first("UID").map { $0.value.trimmingCharacters(in: .whitespaces) }.flatMap(nonEmpty) ?? "\(summary)|\(dtstart.value)"
        var e = Event(uid: uid, summary: summary, start: start)
        e.location = c.first("LOCATION").map { text($0.value).trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap(nonEmpty)
        e.notes = c.first("DESCRIPTION").map { text($0.value) }.flatMap(nonEmpty)
        e.url = c.first("URL").flatMap { URL(string: $0.value.trimmingCharacters(in: .whitespaces)) }
        e.conference = ["X-GOOGLE-CONFERENCE", "X-MICROSOFT-SKYPETEAMSMEETINGURL", "X-MICROSOFT-ONLINEMEETINGCONFLINK"]
            .lazy.compactMap { c.first($0).map { text($0.value) }.flatMap(nonEmpty) }.first
        e.end = c.first("DTEND").flatMap { time($0.value, params: $0.params, zones: zones) }
        if e.end == nil { e.duration = c.first("DURATION").flatMap { duration($0.value) } }
        e.rule = c.first("RRULE").flatMap { Rule($0.value, zone: start.zone) }
        e.rdates = c.all("RDATE").flatMap { times($0, zones: zones) }
        e.exdates = c.all("EXDATE").flatMap { times($0, zones: zones) }
        e.recurrenceID = c.first("RECURRENCE-ID").flatMap { time($0.value, params: $0.params, zones: zones) }
        e.cancelled = c.first("STATUS")?.value.trimmingCharacters(in: .whitespaces).uppercased() == "CANCELLED"
        return e
    }

    /// Comma-separated DATE/DATE-TIME list (RDATE, EXDATE); PERIOD values keep their start.
    private static func times(_ p: Property, zones: ZoneResolver) -> [Time] {
        p.value.split(separator: ",").compactMap { item in
            let start = item.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            return time(start, params: p.params, zones: zones)
        }
    }

    static func time(_ value: String, params: [String: String], zones: ZoneResolver?) -> Time? {
        guard let parsed = wallClock(value) else { return nil }
        if parsed.isDate || params["VALUE"]?.uppercased() == "DATE" {
            return Time(wall: floorDiv(parsed.wall, 86_400) * 86_400, zone: .floating, isDate: true)
        }
        if parsed.utc { return Time(wall: parsed.wall, zone: .utc, isDate: false) }
        if let tzid = params["TZID"], let zones { return Time(wall: parsed.wall, zone: zones.zone(tzid), isDate: false) }
        return Time(wall: parsed.wall, zone: .floating, isDate: false)
    }

    /// "20261027" (date), "20261027T090000" (local or TZID), "20261027T090000Z" (UTC) → wall seconds.
    static func wallClock(_ raw: String) -> (wall: Int, isDate: Bool, utc: Bool)? {
        let u = Array(raw.trimmingCharacters(in: .whitespaces).utf8)
        func num(_ at: Int, _ len: Int) -> Int? {
            guard at + len <= u.count else { return nil }
            var v = 0
            for k in at..<(at + len) {
                let c = u[k]
                guard c >= 0x30, c <= 0x39 else { return nil }
                v = v * 10 + Int(c - 0x30)
            }
            return v
        }
        guard let y = num(0, 4), let m = num(4, 2), let d = num(6, 2), (1...12).contains(m), (1...31).contains(d) else { return nil }
        let base = days(y, m, d) * 86_400
        guard u.count > 8 else { return (base, true, false) }
        guard u[8] == 0x54 || u[8] == 0x74, let hh = num(9, 2), let mm = num(11, 2), hh < 24, mm < 60 else { return nil }
        let ss = min(num(13, 2) ?? 0, 59)
        let utc = u.last == 0x5A || u.last == 0x7A
        return (base + hh * 3600 + mm * 60 + ss, false, utc)
    }

    /// "+0530", "-0800", "+023000" → seconds east of UTC.
    static func utcOffset(_ raw: String) -> Int? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard let sign = s.first, sign == "+" || sign == "-" else { return nil }
        let digits = s.dropFirst()
        guard digits.count == 4 || digits.count == 6, digits.allSatisfy(\.isASCII), let v = Int(digits) else { return nil }
        let secs = digits.count == 4 ? (v / 100) * 3600 + (v % 100) * 60 : (v / 10_000) * 3600 + (v / 100 % 100) * 60 + v % 100
        return sign == "-" ? -secs : secs
    }

    /// "PT1H30M", "P1D", "P2W", "-PT15M", "P1DT12H".
    static func duration(_ raw: String) -> Duration? {
        var s = Substring(raw.trimmingCharacters(in: .whitespaces).uppercased())
        var sign = 1
        if s.hasPrefix("-") { sign = -1; s = s.dropFirst() } else if s.hasPrefix("+") { s = s.dropFirst() }
        guard s.hasPrefix("P") else { return nil }
        s = s.dropFirst()
        var days = 0, seconds = 0, number = "", inTime = false, any = false
        for ch in s {
            if ch.isASCII, ch.isNumber { number.append(ch); continue }
            if ch == "T" { inTime = true; continue }
            guard let n = Int(number) else { return nil }
            number = ""
            switch (ch, inTime) {
            case ("W", false): days += 7 * n
            case ("D", false): days += n
            case ("H", true): seconds += 3600 * n
            case ("M", true): seconds += 60 * n
            case ("S", true): seconds += n
            default: return nil
            }
            any = true
        }
        guard any, number.isEmpty else { return nil }
        return Duration(days: sign * days, seconds: sign * seconds)
    }

    private static func nonEmpty(_ s: String) -> String? { s.isEmpty ? nil : s }

    /// "#FF2968" or "#FF2968FF" → "#FF2968".
    private static func hexColor(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("#"), s.count == 7 || s.count == 9, s.dropFirst().allSatisfy(\.isHexDigit) else { return nil }
        return String(s.prefix(7)).uppercased()
    }

    // MARK: Time zones

    /// Resolves TZID parameters: the system database first (also for Mozilla-style "/mozilla.org/…/Europe/Berlin"
    /// paths and Windows names like "W. Europe Standard Time"), then the feed's VTIMEZONE definition.
    final class ZoneResolver {
        private let definitions: [String: Component]
        private var cache: [String: Zone] = [:]

        init(_ definitions: [String: Component]) { self.definitions = definitions }

        func zone(_ tzid: String) -> Zone {
            if let z = cache[tzid] { return z }
            let z = resolve(tzid)
            cache[tzid] = z
            return z
        }

        private func resolve(_ raw: String) -> Zone {
            let id = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\" ").union(.whitespaces))
            if let tz = TimeZone(identifier: id) { return .named(tz) }
            let parts = id.split(separator: "/")
            for n in [3, 2] where parts.count > n {
                if let tz = TimeZone(identifier: parts.suffix(n).joined(separator: "/")) { return .named(tz) }
            }
            let definition = definitions[raw] ?? definitions[id]
            if let loc = definition?.first("X-LIC-LOCATION")?.value, let tz = TimeZone(identifier: loc.trimmingCharacters(in: .whitespaces)) {
                return .named(tz)
            }
            if let mapped = ICS.windowsZones[id], let tz = TimeZone(identifier: mapped) { return .named(tz) }
            if let definition, let rules = ZoneRules(definition) { return .rules(rules) }
            if let tz = TimeZone(abbreviation: id) { return .named(tz) }
            return .floating
        }
    }

    /// Windows time zone names Outlook/Exchange writes as TZID, mapped to IANA (CLDR windowsZones, "001" territory).
    static let windowsZones: [String: String] = [
        "Dateline Standard Time": "Etc/GMT+12", "Hawaiian Standard Time": "Pacific/Honolulu", "Alaskan Standard Time": "America/Anchorage",
        "Pacific Standard Time": "America/Los_Angeles", "US Mountain Standard Time": "America/Phoenix", "Mountain Standard Time": "America/Denver",
        "Central Standard Time": "America/Chicago", "Central America Standard Time": "America/Guatemala",
        "Central Standard Time (Mexico)": "America/Mexico_City", "Canada Central Standard Time": "America/Regina",
        "Eastern Standard Time": "America/New_York", "US Eastern Standard Time": "America/Indianapolis", "SA Pacific Standard Time": "America/Bogota",
        "Atlantic Standard Time": "America/Halifax", "Newfoundland Standard Time": "America/St_Johns",
        "E. South America Standard Time": "America/Sao_Paulo", "Argentina Standard Time": "America/Buenos_Aires",
        "UTC": "UTC", "Coordinated Universal Time": "UTC", "GMT Standard Time": "Europe/London", "Greenwich Standard Time": "Atlantic/Reykjavik",
        "W. Europe Standard Time": "Europe/Berlin", "Central Europe Standard Time": "Europe/Budapest", "Romance Standard Time": "Europe/Paris",
        "Central European Standard Time": "Europe/Warsaw", "W. Central Africa Standard Time": "Africa/Lagos",
        "GTB Standard Time": "Europe/Bucharest", "E. Europe Standard Time": "Europe/Chisinau", "FLE Standard Time": "Europe/Kiev",
        "Egypt Standard Time": "Africa/Cairo", "South Africa Standard Time": "Africa/Johannesburg", "Israel Standard Time": "Asia/Jerusalem",
        "Turkey Standard Time": "Europe/Istanbul", "Russian Standard Time": "Europe/Moscow", "Arab Standard Time": "Asia/Riyadh",
        "Arabic Standard Time": "Asia/Baghdad", "Iran Standard Time": "Asia/Tehran", "Arabian Standard Time": "Asia/Dubai",
        "Pakistan Standard Time": "Asia/Karachi", "India Standard Time": "Asia/Calcutta", "Sri Lanka Standard Time": "Asia/Colombo",
        "Nepal Standard Time": "Asia/Katmandu", "Bangladesh Standard Time": "Asia/Dhaka", "SE Asia Standard Time": "Asia/Bangkok",
        "China Standard Time": "Asia/Shanghai", "Singapore Standard Time": "Asia/Singapore", "Taipei Standard Time": "Asia/Taipei",
        "W. Australia Standard Time": "Australia/Perth", "Tokyo Standard Time": "Asia/Tokyo", "Korea Standard Time": "Asia/Seoul",
        "Cen. Australia Standard Time": "Australia/Adelaide", "AUS Central Standard Time": "Australia/Darwin",
        "E. Australia Standard Time": "Australia/Brisbane", "AUS Eastern Standard Time": "Australia/Sydney",
        "New Zealand Standard Time": "Pacific/Auckland"
    ]

    static func seconds(_ wall: Int, _ zone: Zone, local: TimeZone) -> Int {
        switch zone {
        case .utc: return wall
        case .floating: return resolve(wall, in: local)
        case .named(let tz): return resolve(wall, in: tz)
        case .rules(let rules): return wall - rules.offset(atWall: wall)
        }
    }

    /// Local wall time → UTC seconds. Ambiguous times (clocks going back) take the first instant; times inside a
    /// spring-forward gap use the offset from before the gap (RFC 5545 §3.3.5).
    static func resolve(_ wall: Int, in tz: TimeZone) -> Int {
        func offset(_ t: Int) -> Int { tz.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(t))) }
        let guess = wall - offset(wall)
        let before = offset(guess - 43_200), after = offset(guess + 43_200)
        if before == after { return wall - before }
        let valid = [wall - before, wall - after].filter { offset($0) == wall - $0 }
        return valid.min() ?? wall - before
    }

    // MARK: Recurrence

    /// Every occurrence overlapping [from, to), sorted by start. All-day dates and floating times use `local`.
    static func occurrences(_ events: [Event], from: Date, to: Date, local: TimeZone = .current) -> [Occurrence] {
        let lo = Int(from.timeIntervalSince1970.rounded(.down)), hi = Int(to.timeIntervalSince1970.rounded(.up))
        var moved: [String: [Event]] = [:]
        for e in events where e.recurrenceID != nil { moved[e.uid, default: []].append(e) }
        var out: [Occurrence] = []

        func place(_ e: Event, _ t: Time, _ span: Span) {
            let start = seconds(t.wall, t.zone, local: local)
            var end: Int
            switch span {
            case .days(let n): end = seconds(t.wall + n * 86_400, t.zone, local: local)
            case .exact(let s): end = start + s
            case .nominal(let d, let s): end = seconds(t.wall + d * 86_400, t.zone, local: local) + s
            }
            end = max(end, start)
            guard start < hi, end > lo || (end == start && start >= lo) else { return }
            out.append(Occurrence(uid: e.uid, title: e.summary, start: Date(timeIntervalSince1970: TimeInterval(start)),
                                  end: Date(timeIntervalSince1970: TimeInterval(end)), allDay: t.isDate, location: e.location,
                                  notes: e.notes, url: e.url, conference: e.conference))
        }

        for e in events {
            guard !e.cancelled else { continue }
            let span = Span(e, local: local)
            if e.recurrenceID != nil || (e.rule == nil && e.rdates.isEmpty) {
                // Cheap reject before resolving zones: wall clocks are within ±14 h of UTC.
                if e.start.wall > hi + 50_400 || e.start.wall + span.maxSeconds < lo - 50_400 { continue }
                place(e, e.start, span)
                continue
            }
            let replaced = Set((moved[e.uid] ?? []).compactMap { $0.recurrenceID.map { seconds($0.wall, $0.zone, local: local) } })
            let exInstants = Set(e.exdates.filter { !$0.isDate }.map { seconds($0.wall, $0.zone, local: local) })
            let exDays = Set(e.exdates.filter(\.isDate).map(\.day))
            func skip(_ t: Time) -> Bool {
                let instant = seconds(t.wall, t.zone, local: local)
                return replaced.contains(instant) || exInstants.contains(instant) || exDays.contains(t.day)
            }
            var walls = [e.start.wall]
            if let rule = e.rule {
                let margin = span.maxSeconds + 2 * 86_400
                walls = recurrenceWalls(start: e.start.wall, rule: rule, from: lo - margin, to: hi + 2 * 86_400,
                                        pastUntil: untilCheck(rule.until, e.start, local: local))
            }
            for w in walls {
                let t = Time(wall: w, zone: e.start.zone, isDate: e.start.isDate)
                if !skip(t) { place(e, t, span) }
            }
            for r in e.rdates where !skip(r) { place(e, r, span) }
        }
        return out.sorted { ($0.start, $0.allDay ? 0 : 1, $0.title) < ($1.start, $1.allDay ? 0 : 1, $1.title) }
    }

    /// How long one instance lasts.
    private enum Span {
        case days(Int)
        case exact(Int)
        case nominal(days: Int, seconds: Int)

        init(_ e: Event, local: TimeZone) {
            if e.start.isDate {
                if let end = e.end { self = .days(max(1, end.day - e.start.day)) } else if let d = e.duration {
                    self = .days(max(1, d.days + d.seconds / 86_400))
                } else { self = .days(1) }
            } else if let end = e.end {
                self = .exact(max(0, ICS.seconds(end.wall, end.zone, local: local) - ICS.seconds(e.start.wall, e.start.zone, local: local)))
            } else if let d = e.duration {
                self = d.days == 0 ? .exact(max(0, d.seconds)) : .nominal(days: max(0, d.days), seconds: d.seconds)
            } else {
                self = .exact(0)
            }
        }

        var maxSeconds: Int {
            switch self {
            case .days(let n): return n * 86_400
            case .exact(let s): return s
            case .nominal(let d, let s): return d * 86_400 + max(0, s) + 3600
            }
        }
    }

    /// UNTIL is inclusive. Dates compare by day; a UTC UNTIL compares instants; a floating one compares wall clocks.
    private static func untilCheck(_ until: Time?, _ start: Time, local: TimeZone) -> (Int) -> Bool {
        guard let until else { return { _ in false } }
        if until.isDate || start.isDate {
            let day = until.day
            return { floorDiv($0, 86_400) > day }
        }
        if until.zone == start.zone || until.zone == .floating {
            let wall = until.wall
            return { $0 > wall }
        }
        let limit = seconds(until.wall, until.zone, local: local)
        let zone = start.zone
        return { seconds($0, zone, local: local) > limit }
    }

    /// Wall-clock start times of a recurrence inside [from, to), ascending. `start` (DTSTART) is always the first
    /// instance and counts towards COUNT (RFC 5545 §3.8.5.3); `pastUntil` says whether a candidate is after UNTIL.
    static func recurrenceWalls(start: Int, rule: Rule, from: Int, to: Int, pastUntil: (Int) -> Bool) -> [Int] {
        let startDay = floorDiv(start, 86_400)
        let timeOfDay = start - startDay * 86_400
        let s = civil(startDay)
        var out: [Int] = []
        if start >= from && start < to { out.append(start) }
        var produced = 1
        if let c = rule.count, produced >= c { return out }
        let toDay = floorDiv(to, 86_400)
        var k = rule.count == nil ? skipPeriods(rule, startDay: startDay, start: s, fromDay: floorDiv(from, 86_400)) : 0
        for _ in 0..<200_000 {
            let (first, days) = period(rule, k, startDay: startDay, start: s)
            if first > toDay { break }
            for day in days {
                let t = day * 86_400 + timeOfDay
                if t <= start { continue }
                if pastUntil(t) { return out }
                produced += 1
                if let c = rule.count, produced > c { return out }
                if t >= to { return out }
                if t >= from { out.append(t) }
            }
            k += 1
        }
        return out
    }

    /// Whole periods that end before `fromDay` (only without COUNT, which needs every instance counted).
    private static func skipPeriods(_ r: Rule, startDay: Int, start s: (y: Int, m: Int, d: Int), fromDay: Int) -> Int {
        let gap = fromDay - startDay
        guard gap > 62 else { return 0 }
        let f = civil(fromDay)
        switch r.freq {
        case .daily: return max(0, gap / r.interval - 2)
        case .weekly: return max(0, gap / (7 * r.interval) - 2)
        case .monthly: return max(0, ((f.y - s.y) * 12 + f.m - s.m) / r.interval - 2)
        case .yearly: return max(0, (f.y - s.y) / r.interval - 2)
        }
    }

    /// The k-th period's first day and its candidate days, ascending.
    private static func period(_ r: Rule, _ k: Int, startDay: Int, start s: (y: Int, m: Int, d: Int)) -> (first: Int, days: [Int]) {
        switch r.freq {
        case .daily:
            let day = startDay + k * r.interval
            return (day, dailyMatch(day, r) ? [day] : [])
        case .weekly:
            let weekFirst = startDay - mod(weekday(startDay) - r.weekStart, 7) + 7 * k * r.interval
            let wds = r.byDay.isEmpty ? [weekday(startDay)] : r.byDay.map(\.weekday)
            var days = Set(wds.map { weekFirst + mod($0 - r.weekStart, 7) }).sorted()
            if !r.byMonth.isEmpty { days = days.filter { r.byMonth.contains(civil($0).m) } }
            return (weekFirst, setPositions(days, r))
        case .monthly:
            let index = s.y * 12 + (s.m - 1) + k * r.interval
            let y = floorDiv(index, 12), m = mod(index, 12) + 1
            let first = days(y, m, 1)
            guard r.byMonth.isEmpty || r.byMonth.contains(m) else { return (first, []) }
            return (first, setPositions(monthDays(y, m, r, defaultDay: s.d), r))
        case .yearly:
            let y = s.y + k * r.interval
            var out: [Int] = []
            if !r.byMonth.isEmpty {
                for m in Set(r.byMonth).sorted() {
                    if r.byDay.isEmpty && r.byMonthDay.isEmpty {
                        if s.d <= monthLength(y, m) { out.append(days(y, m, s.d)) }
                    } else {
                        out += monthDays(y, m, r, defaultDay: s.d)
                    }
                }
            } else if !r.byMonthDay.isEmpty {
                for m in 1...12 { out += monthDays(y, m, r, defaultDay: s.d) }
            } else if !r.byDay.isEmpty {
                out = yearWeekdays(y, r.byDay)
            } else if s.d <= monthLength(y, s.m) {
                out = [days(y, s.m, s.d)]
            }
            return (days(y, 1, 1), setPositions(Set(out).sorted(), r))
        }
    }

    private static func dailyMatch(_ day: Int, _ r: Rule) -> Bool {
        guard !r.byMonth.isEmpty || !r.byDay.isEmpty || !r.byMonthDay.isEmpty else { return true }
        let c = civil(day)
        if !r.byMonth.isEmpty && !r.byMonth.contains(c.m) { return false }
        if !r.byDay.isEmpty && !r.byDay.contains(where: { $0.weekday == weekday(day) }) { return false }
        if !r.byMonthDay.isEmpty {
            let length = monthLength(c.y, c.m)
            if !r.byMonthDay.contains(where: { ($0 > 0 ? $0 : length + $0 + 1) == c.d }) { return false }
        }
        return true
    }

    /// Days of one month picked by BYMONTHDAY and/or BYDAY (ordinals count within the month), else DTSTART's day.
    private static func monthDays(_ y: Int, _ m: Int, _ r: Rule, defaultDay: Int) -> [Int] {
        let first = days(y, m, 1), length = monthLength(y, m)
        var picked: Set<Int>?
        if !r.byMonthDay.isEmpty {
            picked = Set(r.byMonthDay.compactMap { md in
                let d = md > 0 ? md : length + md + 1
                return (1...length).contains(d) ? d : nil
            })
        }
        if !r.byDay.isEmpty {
            var set = Set<Int>()
            let firstWeekday = weekday(first)
            for wd in r.byDay {
                let all = Array(stride(from: 1 + mod(wd.weekday - firstWeekday, 7), through: length, by: 7))
                if wd.ordinal == 0 { set.formUnion(all) } else if wd.ordinal > 0, wd.ordinal <= all.count {
                    set.insert(all[wd.ordinal - 1])
                } else if wd.ordinal < 0, -wd.ordinal <= all.count {
                    set.insert(all[all.count + wd.ordinal])
                }
            }
            picked = picked.map { $0.intersection(set) } ?? set
        }
        let dom = picked.map { $0.sorted() } ?? (defaultDay <= length ? [defaultDay] : [])
        return dom.map { first + $0 - 1 }
    }

    /// BYDAY in a YEARLY rule without BYMONTH: ordinals count within the year ("20MO" = 20th Monday).
    private static func yearWeekdays(_ y: Int, _ byDay: [Rule.Day]) -> [Int] {
        let first = days(y, 1, 1), end = days(y + 1, 1, 1)
        var set = Set<Int>()
        for wd in byDay {
            let all = Array(stride(from: first + mod(wd.weekday - weekday(first), 7), to: end, by: 7))
            if wd.ordinal == 0 { set.formUnion(all) } else if wd.ordinal > 0, wd.ordinal <= all.count {
                set.insert(all[wd.ordinal - 1])
            } else if wd.ordinal < 0, -wd.ordinal <= all.count {
                set.insert(all[all.count + wd.ordinal])
            }
        }
        return set.sorted()
    }

    private static func setPositions(_ days: [Int], _ r: Rule) -> [Int] {
        guard !r.bySetPos.isEmpty, !days.isEmpty else { return days }
        let n = days.count
        return Set(r.bySetPos.compactMap { p in p > 0 ? (p <= n ? days[p - 1] : nil) : (-p <= n ? days[n + p] : nil) }).sorted()
    }

    // MARK: Civil calendar (proleptic Gregorian, days since 1970-01-01)

    static func floorDiv(_ a: Int, _ b: Int) -> Int { a >= 0 ? a / b : -((-a + b - 1) / b) }
    static func mod(_ a: Int, _ b: Int) -> Int { ((a % b) + b) % b }

    static func days(_ y: Int, _ m: Int, _ d: Int) -> Int {
        let yy = m <= 2 ? y - 1 : y
        let era = floorDiv(yy, 400)
        let yoe = yy - era * 400
        let doy = (153 * ((m + 9) % 12) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func civil(_ day: Int) -> (y: Int, m: Int, d: Int) {
        let z = day + 719_468
        let era = floorDiv(z, 146_097)
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }

    /// 0 = Sunday … 6 = Saturday (1970-01-01 was a Thursday).
    static func weekday(_ day: Int) -> Int { mod(day + 4, 7) }

    static func monthLength(_ y: Int, _ m: Int) -> Int {
        if m == 2 { return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 ? 29 : 28 }
        return [4, 6, 9, 11].contains(m) ? 30 : 31
    }
}
