import Foundation

// Shared plumbing for connected-service providers: HTTP with response headers, defensive JSON
// access, tolerant date parsing, range math and time bucketing. Nothing here touches the main actor.

/// Process-wide flags for the connected family.
enum ConnEnv {
    /// `--render` harness runs must not touch the Keychain (it can prompt) or other protected stores.
    static let isRendering = CommandLine.arguments.contains("--render")

    /// Widget credential, never read while rendering offscreen.
    static func token(_ id: UUID) -> String? {
        if isRendering { return nil }
        return Secrets.get(id, "token")?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Provider error with a user-facing message (shown in the tile tooltip / panel).
struct ConnError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - HTTP

/// GET with headers → body + response. Paginating providers take one so tests can replay pages.
typealias ConnSend = (URL, [String: String]) async throws -> (Data, HTTPURLResponse)

enum ConnHTTP {
    static let live: ConnSend = { url, headers in try await send(url, headers: headers) }

    /// GET/POST returning body and response so callers can follow `Link` pagination.
    static func send(_ url: URL, headers: [String: String] = [:], method: String = "GET", body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        req.httpMethod = method
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await Net.load(req)
        guard let http = response as? HTTPURLResponse else { throw ConnError(L("Offline")) }
        if !(200..<300).contains(http.statusCode) { throw Net.HTTPError(response: http, data: data) }
        return (data, http)
    }

    static func json(_ url: URL, headers: [String: String] = [:], method: String = "GET", body: Data? = nil) async throws -> Any {
        let (data, _) = try await send(url, headers: headers, method: method, body: body)
        return try ConnJSON.decode(data)
    }

    static func object(_ url: URL, headers: [String: String] = [:], method: String = "GET", body: Data? = nil) async throws -> [String: Any] {
        let (data, _) = try await send(url, headers: headers, method: method, body: body)
        return try ConnJSON.object(data)
    }

    static func bearer(_ token: String) -> [String: String] { ["Authorization": "Bearer \(token)"] }

    static func url(_ base: String, _ query: [(String, String)] = []) throws -> URL {
        guard var comps = URLComponents(string: base) else { throw ConnError(L("Invalid address")) }
        if !query.isEmpty {
            comps.queryItems = (comps.queryItems ?? []) + query.map { URLQueryItem(name: $0.0, value: $0.1) }
            // `+` in ISO dates must survive as a literal plus.
            comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = comps.url else { throw ConnError(L("Invalid address")) }
        return url
    }

    /// `<https://…?page_info=abc>; rel="next"` → URL
    static func nextLink(_ response: HTTPURLResponse) -> URL? {
        nextLink(header: response.value(forHTTPHeaderField: "Link"))
    }

    /// RFC 8288 `Link` header → the `rel="next"` target. Entries are split on commas *outside*
    /// `<…>` so targets that carry unencoded commas (e.g. `fields=a,b`) survive.
    static func nextLink(header raw: String?) -> URL? {
        guard var link = raw else { return nil }
        // Shopify's pagination docs render targets in backticks (`…`; rel=next) — accept that too.
        if !link.contains("<"), link.contains("`") {
            var open = true
            link = String(link.map { c -> Character in
                guard c == "`" else { return c }
                defer { open.toggle() }
                return open ? "<" : ">"
            })
        }
        var rest = Substring(link)
        while let open = rest.firstIndex(of: "<") {
            guard let close = rest[open...].firstIndex(of: ">") else { return nil }
            let target = rest[rest.index(after: open)..<close]
            let params = rest[rest.index(after: close)...]
            let paramsEnd = params.firstIndex(of: "<") ?? params.endIndex
            if linkRelations(params[..<paramsEnd]).contains("next") { return URL(string: String(target)) }
            rest = params[paramsEnd...]
        }
        return nil
    }

    /// `; rel="previous next"` / `; rel=next` → ["previous", "next"]
    private static func linkRelations(_ params: Substring) -> [String] {
        for param in params.split(separator: ";") {
            let pair = param.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "rel" else { continue }
            let value = pair[1].trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\",")))
            return value.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        }
        return []
    }
}

// MARK: - Error responses

extension Net.HTTPError {
    /// Non-2xx response → error whose message follows what the provider means, not only the status.
    /// Each rule matches a response captured live (Tests/Fixtures/live-auth) or the provider's error docs.
    init(response http: HTTPURLResponse, data: Data) {
        self.init(status: http.statusCode, body: String(decoding: data.prefix(300), as: UTF8.self))
        hint = Self.hint(status: http.statusCode, remaining: http.value(forHTTPHeaderField: "X-RateLimit-Remaining"),
                         retryAfter: http.value(forHTTPHeaderField: "Retry-After"), data: data)
    }

    static func hint(status: Int, remaining: String? = nil, retryAfter: String? = nil, data: Data) -> Hint {
        if status == 429 { return .rateLimited }
        // GitHub: an exhausted primary limit is 403 (or 429) with `x-ratelimit-remaining: 0`; a
        // secondary limit is 403 with `retry-after`.
        if status == 403, remaining?.trimmingCharacters(in: .whitespaces) == "0" || retryAfter != nil { return .rateLimited }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .none }

        // Google APIs (YouTube): `error.errors[].reason` / `error.details[].reason`.
        let google = ConnJSON.dict(obj["error"])
        let reasons = Set((ConnJSON.array(google?["errors"]) + ConnJSON.array(google?["details"])).compactMap { ConnJSON.str($0["reason"]) })
        if !reasons.isDisjoint(with: ["quotaExceeded", "rateLimitExceeded", "userRateLimitExceeded", "dailyLimitExceeded", "RATE_LIMIT_EXCEEDED"]) {
            return .rateLimited
        }
        if !reasons.isDisjoint(with: ["API_KEY_INVALID", "keyInvalid", "keyExpired", "API_KEY_SERVICE_BLOCKED"]) { return .badCredential }

        // GraphQL (Linear): `errors[].extensions.code`.
        let codes = Set(ConnJSON.array(obj["errors"]).compactMap { ConnJSON.str(ConnJSON.path($0, "extensions.code")) })
        if codes.contains("RATELIMITED") { return .rateLimited }
        if codes.contains("AUTHENTICATION_ERROR") { return .badCredential }

        // Resend: an unknown key is HTTP 400 `validation_error` "API key is invalid".
        switch ConnJSON.str(obj["name"]) {
        case "missing_api_key", "invalid_api_key", "restricted_api_key": return .badCredential
        case "rate_limit_exceeded": return .rateLimited
        case "validation_error" where (ConnJSON.str(obj["message"]) ?? "").localizedCaseInsensitiveContains("API key"): return .badCredential
        default: return .none
        }
    }
}

// MARK: - JSON access

enum ConnJSON {
    static func decode(_ data: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// Top-level JSON object or `Unexpected response`.
    static func object(_ data: Data) throws -> [String: Any] {
        guard let obj = try decode(data) as? [String: Any] else { throw ConnError(L("Unexpected response")) }
        return obj
    }

    static func dict(_ v: Any?) -> [String: Any]? { v as? [String: Any] }
    static func array(_ v: Any?) -> [[String: Any]] { (v as? [Any])?.compactMap { $0 as? [String: Any] } ?? [] }

    static func num(_ v: Any?) -> Double? {
        switch v {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    static func str(_ v: Any?) -> String? {
        switch v {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    /// Follows a dotted path: `path(obj, "data.user.follower_count")`.
    static func path(_ v: Any?, _ p: String) -> Any? {
        var cur = v
        for key in p.split(separator: ".") {
            guard let d = cur as? [String: Any] else { return nil }
            cur = d[String(key)]
        }
        return cur
    }

    /// Breadth-first search for the first numeric value under any of `keys` (case-insensitive).
    static func findNumber(_ v: Any?, keys: [String], maxDepth: Int = 5) -> Double? {
        let wanted = Set(keys.map { $0.lowercased() })
        var queue: [(Any, Int)] = v.map { [($0, 0)] } ?? []
        var i = 0
        while i < queue.count {
            let (node, depth) = queue[i]; i += 1
            if let d = node as? [String: Any] {
                for (k, value) in d where wanted.contains(k.lowercased()) {
                    if let n = num(value) { return n }
                    if let inner = value as? [String: Any], let n = num(inner["value"] ?? inner["total"] ?? inner["count"]) { return n }
                }
                if depth < maxDepth { d.values.forEach { queue.append(($0, depth + 1)) } }
            } else if let a = node as? [Any], depth < maxDepth {
                a.forEach { queue.append(($0, depth + 1)) }
            }
        }
        return nil
    }

    /// First array of objects found under one of `keys` (BFS), for schema-tolerant time series.
    static func findArray(_ v: Any?, keys: [String], maxDepth: Int = 4) -> [[String: Any]]? {
        let wanted = Set(keys.map { $0.lowercased() })
        var queue: [(Any, Int)] = v.map { [($0, 0)] } ?? []
        var i = 0
        while i < queue.count {
            let (node, depth) = queue[i]; i += 1
            if let d = node as? [String: Any] {
                for (k, value) in d where wanted.contains(k.lowercased()) {
                    let arr = array(value)
                    if !arr.isEmpty { return arr }
                }
                if depth < maxDepth { d.values.forEach { queue.append(($0, depth + 1)) } }
            } else if let a = node as? [Any], depth < maxDepth {
                if let objs = node as? [[String: Any]], !objs.isEmpty, depth == 0 { return objs }
                a.forEach { queue.append(($0, depth + 1)) }
            }
        }
        return nil
    }
}

// MARK: - Dates

enum ConnDate {
    /// Gregorian calendar in the user's time zone — API dates are always Gregorian.
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    /// `YYYY-MM-DD` in the local time zone.
    static func day(_ d: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// RFC 3339 / ISO 8601 with time zone offset.
    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f.string(from: d)
    }

    static func isoUTC(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    /// Parses ISO 8601 (with or without fractions / offset), `2023-04-03 22:13:42.67+00`,
    /// date-only strings and unix seconds/milliseconds.
    static func parse(_ v: Any?) -> Date? {
        if let n = v as? NSNumber, !(v is String) {
            let t = n.doubleValue
            return Date(timeIntervalSince1970: t > 10_000_000_000 ? t / 1000 : t)
        }
        guard var s = v as? String, s.count >= 10 else { return nil }
        if let fast = fastISO(s) { return fast }
        s = s.replacingOccurrences(of: " ", with: "T")
        if s.count == 10 {
            var c = DateComponents()
            let parts = s.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            c.year = parts[0]; c.month = parts[1]; c.day = parts[2]
            return calendar.date(from: c)
        }
        // "+00" → "+00:00"
        if let r = s.range(of: #"[+-]\d{2}$"#, options: .regularExpression) { s.replaceSubrange(r, with: s[r] + ":00") }
        // ISO 8601 without seconds, e.g. Supabase's "2024-01-01T04:24Z" → "…T04:24:00Z"
        if s.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(Z|[+-]\d{2}:\d{2})?$"#, options: .regularExpression) != nil {
            s.insert(contentsOf: ":00", at: s.index(s.startIndex, offsetBy: 16))
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        // No zone at all → treat as UTC.
        if !s.hasSuffix("Z"), s.range(of: #"[+-]\d{2}:\d{2}$"#, options: .regularExpression) == nil {
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: s + "Z") { return d }
            f.formatOptions = [.withInternetDateTime]
            return f.date(from: s + "Z")
        }
        return nil
    }

    /// Allocation-free parser for `YYYY-MM-DDTHH:MM:SS(.fff)Z` — the format of every JSONL log line.
    static func fastISO(_ s: String) -> Date? {
        var u = Array(s.utf8.prefix(32))
        return u.withUnsafeMutableBufferPointer { fastISO(UnsafeBufferPointer($0)) }
    }

    static func fastISO(_ b: UnsafeBufferPointer<UInt8>) -> Date? {
        guard b.count >= 20, b[4] == 45, b[7] == 45, b[10] == 84 || b[10] == 32, b[13] == 58, b[16] == 58 else { return nil }
        func n(_ i: Int, _ len: Int) -> Int? {
            var v = 0
            for k in i..<(i + len) {
                let c = b[k]
                guard c >= 48, c <= 57 else { return nil }
                v = v * 10 + Int(c - 48)
            }
            return v
        }
        guard let y = n(0, 4), let mo = n(5, 2), let d = n(8, 2), let h = n(11, 2), let mi = n(14, 2), let se = n(17, 2) else { return nil }
        var i = 19
        var frac = 0.0
        if i < b.count, b[i] == 46 {
            i += 1
            var scale = 0.1
            while i < b.count, b[i] >= 48, b[i] <= 57 { frac += Double(b[i] - 48) * scale; scale /= 10; i += 1 }
        }
        guard i < b.count, b[i] == 90 else { return nil } // only 'Z'
        // Days from civil (Howard Hinnant).
        let yy = mo <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let mp = (mo + 9) % 12
        let doy = (153 * mp + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146_097 + doe - 719_468
        let secs = Double(days * 86_400 + h * 3600 + mi * 60 + se) + frac
        return Date(timeIntervalSince1970: secs)
    }
}

// MARK: - Ranges

enum ConnRange: String {
    case day = "1d", week = "7d", month = "30d"

    init(_ raw: String) { self = ConnRange(rawValue: raw) ?? .week }

    var days: Int {
        switch self {
        case .day: return 1
        case .week: return 7
        case .month: return 30
        }
    }

    /// Start of the range (local midnight `days - 1` days ago).
    func start(_ now: Date = Date()) -> Date {
        let cal = ConnDate.calendar
        let today = cal.startOfDay(for: now)
        return cal.date(byAdding: .day, value: -(days - 1), to: today) ?? today
    }

    /// Bucket width for charts: hours for "today", days otherwise.
    var step: TimeInterval { self == .day ? 3600 : 86_400 }
    var bucketCount: Int { self == .day ? 24 : days }

    /// "today" · "last 7d" · "last 30 days" (matches the reference captions).
    var caption: String {
        switch self {
        case .day: return L("today")
        case .week: return L("last 7d")
        case .month: return L("last 30 days")
        }
    }

    /// Compact pill label drawn over brand icons.
    var pill: String {
        switch self {
        case .day: return L("TDY")
        case .week: return L("7D")
        case .month: return L("30D")
        }
    }

    var title: String {
        switch self {
        case .day: return L("Today")
        case .week: return L("Last 7 days")
        case .month: return L("Last 30 days")
        }
    }
}

/// Accumulates values into fixed-width time buckets.
struct ConnBuckets {
    let start: Date
    let step: TimeInterval
    var values: [Double]

    init(start: Date, step: TimeInterval, count: Int) {
        self.start = start
        self.step = step
        values = Array(repeating: 0, count: max(count, 1))
    }

    init(range: ConnRange, now: Date = Date()) {
        self.init(start: range.start(now), step: range.step, count: range.bucketCount)
    }

    func index(_ date: Date) -> Int? {
        let t = date.timeIntervalSince(start)
        guard t >= 0 else { return nil }
        let i: Int
        if step >= 86_400 {
            // Calendar days (DST-safe).
            let cal = ConnDate.calendar
            i = cal.dateComponents([.day], from: cal.startOfDay(for: start), to: cal.startOfDay(for: date)).day ?? Int(t / step)
        } else {
            i = Int(t / step)
        }
        return i < values.count ? i : nil
    }

    mutating func add(_ value: Double, at date: Date) {
        if let i = index(date) { values[i] += value }
    }

    /// Drops trailing future buckets (e.g. hours after now) so lines end at "now".
    func trimmed(now: Date = Date()) -> [Double] {
        guard step < 86_400 else { return values }
        let n = min(values.count, max(Int(now.timeIntervalSince(start) / step) + 1, 2))
        return Array(values.prefix(n))
    }
}

// MARK: - Money

enum ConnMoney {
    /// ISO 4217 currencies without minor units.
    private static let zeroDecimal: Set<String> = ["BIF", "CLP", "DJF", "GNF", "JPY", "KMF", "KRW", "MGA", "PYG", "RWF", "UGX", "VND", "VUV", "XAF", "XOF", "XPF"]
    /// ISO 4217 currencies with three minor digits (amounts in fils / baisa / millimes).
    private static let threeDecimal: Set<String> = ["BHD", "IQD", "JOD", "KWD", "LYD", "OMR", "TND"]

    static func fromMinor(_ amount: Double, _ currency: String) -> Double {
        let c = currency.uppercased()
        if zeroDecimal.contains(c) { return amount }
        return threeDecimal.contains(c) ? amount / 1000 : amount / 100
    }

    /// Stripe amounts: ISO minor units, except UGX which Stripe keeps two-decimal for backward
    /// compatibility (https://docs.stripe.com/currencies#special-cases).
    static func fromStripe(_ amount: Double, _ currency: String) -> Double {
        currency.uppercased() == "UGX" ? amount / 100 : fromMinor(amount, currency)
    }
}
