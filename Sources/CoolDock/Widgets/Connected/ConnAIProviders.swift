import Foundation

private typealias J = ConnJSON

// MARK: - What a provider counts

/// The headline unit of an AI usage snapshot (`ConnSnapshot.text[ConnKey.unit]`; absent = tokens).
/// Token providers keep the original tile; the others swap the value and caption.
enum ConnAIUnit: String {
    case tokens, requests, credits, usd, quota
}

extension ConnSnapshot {
    var aiUnit: ConnAIUnit { text[ConnKey.unit].flatMap(ConnAIUnit.init(rawValue:)) ?? .tokens }
}

/// Every AI usage source the widget offers (`provider` config value).
enum ConnAIProvider: String, CaseIterable {
    case claudeCode, codex, opencode, antigravity, anthropic, openai, cursor, copilot, gemini, perplexity, xai, zai

    init(_ w: WidgetInstance) { self = ConnAIProvider(rawValue: w.string("provider")) ?? .claudeCode }

    /// Reads files or a CLI on this Mac (no API key).
    var isLocal: Bool { [.claudeCode, .codex, .opencode, .antigravity].contains(self) }

    var name: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        case .antigravity: return "Antigravity"
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        case .cursor: return "Cursor"
        case .copilot: return "GitHub Copilot"
        case .gemini: return "Gemini API"
        case .perplexity: return "Perplexity"
        case .xai: return "Grok"
        case .zai: return "Z.ai"
        }
    }

    var brand: ConnBrand {
        switch self {
        case .claudeCode, .anthropic: return .claude
        case .codex: return .codex
        case .openai: return .openai
        case .opencode: return .opencode
        case .antigravity: return .antigravity
        case .cursor: return .cursor
        case .copilot: return .copilot
        case .gemini: return .gemini
        case .perplexity: return .perplexity
        case .xai: return .grok
        case .zai: return .zai
        }
    }

    var dashboard: String {
        switch self {
        case .claudeCode: return "https://claude.ai/settings/usage"
        case .codex: return "https://chatgpt.com/codex/settings/usage"
        case .anthropic: return "https://console.anthropic.com/usage"
        case .openai: return "https://platform.openai.com/usage"
        case .opencode: return "https://opencode.ai/"
        case .antigravity: return "https://antigravity.google/docs/cli/commands/usage"
        case .cursor: return "https://cursor.com/dashboard?tab=usage"
        case .copilot: return "https://github.com/settings/billing/usage"
        case .gemini: return "https://aistudio.google.com/usage"
        case .perplexity: return "https://www.perplexity.ai/"
        case .xai: return "https://console.x.ai/"
        case .zai: return "https://z.ai/manage-apikey/billing"
        }
    }
}

// MARK: - Keyed APIs (Cursor, GitHub Copilot, Gemini, Perplexity, xAI, Z.ai)

/// Like the Anthropic/OpenAI providers: the HTTP loops are thin, the per-page parsing is pure (`add…`, `parse…`)
/// so documentation-schema fixtures can cover it, and every request goes through `ConnHTTP` (`Net.transport` in tests).
extension ConnAIUsageAPI {
    static func ms(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded()) }

    /// `yyyy-MM-dd HH:mm:ss` in the user's time zone (xAI and Z.ai take local wall-clock times).
    static func wallClock(_ d: Date) -> String {
        let c = ConnDate.calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
        return String(format: "%04d-%02d-%02d %02d:%02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    /// Parses `yyyy-MM-dd[ HH:mm[:ss]]` as local wall-clock time.
    static func parseWallClock(_ s: String) -> Date? {
        let parts = s.split(whereSeparator: { $0 == " " || $0 == "T" || $0 == "-" || $0 == ":" }).compactMap { Int($0) }
        guard parts.count >= 3 else { return nil }
        var c = DateComponents()
        c.year = parts[0]; c.month = parts[1]; c.day = parts[2]
        c.hour = parts.count > 3 ? parts[3] : 0
        c.minute = parts.count > 4 ? parts[4] : 0
        c.second = parts.count > 5 ? parts[5] : 0
        return ConnDate.calendar.date(from: c)
    }

    // MARK: Cursor (Admin API)

    static let cursorEvents = URL(string: "https://api.cursor.com/teams/filtered-usage-events")!

    /// Cursor Admin API `POST /teams/filtered-usage-events` (Basic auth, key as user name). Cost is `chargedCents`,
    /// the billed amount, so no estimate. `email` narrows a team key to one member ("personal" usage).
    static func cursor(key: String, email: String, range: ConnRange, now: Date = Date()) async throws -> ConnSnapshot {
        let start = range.start(now)
        let headers = ["Authorization": "Basic " + Data("\(key):".utf8).base64EncodedString()]
        let member = email.trimmingCharacters(in: .whitespaces)
        var buckets = ConnBuckets(range: range, now: now)
        var tally = ConnTally()
        var tokenEvents = 0
        for page in 1...10 {
            var body: [String: Any] = ["startDate": ms(start), "endDate": ms(now), "page": page, "pageSize": 1000]
            if !member.isEmpty { body["email"] = member }
            let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            let obj = try await ConnHTTP.object(cursorEvents, headers: headers, method: "POST", body: data)
            let more = addCursorEvents(obj, tally: &tally, buckets: &buckets, tokenEvents: &tokenEvents)
            if !more { break }
        }
        var snap = tally.snapshot(series: buckets, now: now, estimate: false)
        // Request-based plans log events without token counts: count requests instead.
        if tokenEvents == 0, tally.calls > 0 {
            snap.value = tally.calls
            snap.text[ConnKey.unit] = ConnAIUnit.requests.rawValue
        }
        return snap
    }

    /// One `usageEvents` page → tally; returns whether `pagination.hasNextPage`.
    static func addCursorEvents(_ obj: [String: Any], tally: inout ConnTally, buckets: inout ConnBuckets, tokenEvents: inout Int) -> Bool {
        for e in J.array(obj["usageEvents"]) {
            let at = J.num(e["timestamp"]).map { Date(timeIntervalSince1970: $0 / 1000) }
            if let usage = J.dict(e["tokenUsage"]) {
                let input = J.num(usage["inputTokens"]) ?? 0, output = J.num(usage["outputTokens"]) ?? 0
                let write = J.num(usage["cacheWriteTokens"]) ?? 0, read = J.num(usage["cacheReadTokens"]) ?? 0
                tally.input += input
                tally.output += output
                tally.cacheWrite += write
                tally.cacheRead += read
                tokenEvents += 1
                if let at { buckets.add(input + output + write + read, at: at) }
            }
            tally.cost += (J.num(e["chargedCents"]) ?? J.num(J.path(e, "tokenUsage.totalCents")) ?? 0) / 100
            tally.calls += 1
        }
        return (J.path(obj, "pagination.hasNextPage") as? Bool) == true
    }

    // MARK: GitHub Copilot (billing usage REST API)

    static let gitHubVersion = "2026-03-10"

    /// `GET /users/{username}/settings/billing/usage?year&month[&day]` for every month the range touches, keeping the
    /// Copilot items (premium requests / AI credits). Needs a classic token of the account that pays for Copilot;
    /// an empty user name is resolved with `GET /user`.
    static func copilot(token: String, user: String, range: ConnRange, now: Date = Date()) async throws -> ConnSnapshot {
        let headers = ["Authorization": "Bearer \(token)", "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": gitHubVersion]
        var login = user.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "@")))
        if login.isEmpty {
            let me = try await ConnHTTP.object(URL(string: "https://api.github.com/user")!, headers: headers)
            guard let name = J.str(me["login"]), !name.isEmpty else { throw ConnError(L("Unexpected response")) }
            login = name
        }
        guard let path = login.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { throw ConnError(L("Invalid address")) }
        var usage = ConnCopilotUsage(range: range, now: now)
        for period in copilotPeriods(range: range, now: now) {
            var query = [("year", String(period.year)), ("month", String(period.month))]
            if let day = period.day { query.append(("day", String(day))) }
            let obj = try await ConnHTTP.object(ConnHTTP.url("https://api.github.com/users/\(path)/settings/billing/usage", query), headers: headers)
            usage.add(obj)
        }
        return usage.snapshot(now: now)
    }

    /// Calendar months (or today's date) that cover the range, oldest first.
    static func copilotPeriods(range: ConnRange, now: Date) -> [(year: Int, month: Int, day: Int?)] {
        let cal = ConnDate.calendar
        let today = cal.dateComponents([.year, .month, .day], from: now)
        if range == .day { return [(today.year ?? 0, today.month ?? 0, today.day)] }
        let first = cal.dateComponents([.year, .month], from: range.start(now))
        var out = [(year: first.year ?? 0, month: first.month ?? 0, day: Int?.none)]
        if first.year != today.year || first.month != today.month { out.append((today.year ?? 0, today.month ?? 0, nil)) }
        return out
    }

    // MARK: Gemini API (Cloud Monitoring)

    /// Generative Language API traffic of one Google Cloud project: `serviceruntime.googleapis.com/api/request_count`
    /// on `consumed_api`, summed per hour. Cloud Monitoring needs an OAuth access token (it rejects API keys, as the
    /// live capture shows); AI Studio keys have no usage endpoint.
    static let geminiFilter = #"metric.type="serviceruntime.googleapis.com/api/request_count" AND resource.type="consumed_api" AND resource.labels.service="generativelanguage.googleapis.com""#

    static func gemini(project: String, token: String, range: ConnRange, now: Date = Date()) async throws -> ConnSnapshot {
        let id = project.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, let path = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { throw ConnError(L("Invalid address")) }
        var buckets = ConnBuckets(range: range, now: now)
        var total = 0.0
        var pageToken: String?
        for _ in 0..<5 {
            var query = [("filter", geminiFilter), ("interval.startTime", ConnDate.isoUTC(range.start(now))), ("interval.endTime", ConnDate.isoUTC(now)),
                         ("aggregation.alignmentPeriod", "3600s"), ("aggregation.perSeriesAligner", "ALIGN_DELTA"),
                         ("aggregation.crossSeriesReducer", "REDUCE_SUM")]
            if let pageToken { query.append(("pageToken", pageToken)) }
            let url = try ConnHTTP.url("https://monitoring.googleapis.com/v3/projects/\(path)/timeSeries", query)
            let obj = try await ConnHTTP.object(url, headers: ConnHTTP.bearer(token))
            total += addGeminiSeries(obj, buckets: &buckets)
            guard let next = J.str(obj["nextPageToken"]), !next.isEmpty else { break }
            pageToken = next
        }
        var snap = ConnSnapshot()
        snap.value = total
        snap.metrics[ConnKey.calls] = total
        snap.text[ConnKey.unit] = ConnAIUnit.requests.rawValue
        snap.series = buckets.trimmed(now: now)
        snap.seriesStart = buckets.start
        snap.seriesStep = buckets.step
        return snap
    }

    /// `timeSeries[].points[]` (`value.int64Value` is a decimal string) → total; bucketed by the point's start.
    static func addGeminiSeries(_ obj: [String: Any], buckets: inout ConnBuckets) -> Double {
        var total = 0.0
        for series in J.array(obj["timeSeries"]) {
            for point in J.array(series["points"]) {
                let v = J.num(J.path(point, "value.int64Value")) ?? J.num(J.path(point, "value.doubleValue")) ?? 0
                total += v
                if let at = ConnDate.parse(J.path(point, "interval.startTime")) ?? ConnDate.parse(J.path(point, "interval.endTime")) {
                    buckets.add(v, at: at)
                }
            }
        }
        return total
    }

    // MARK: Perplexity (Analytics API)

    /// `GET /v1/analytics/computer/usage?dataset=credit_usage` (organization analytics key). Credits are the headline;
    /// organization query volume (daily only, no member filter) fills the request count when it applies.
    static func perplexity(key: String, email: String, range: ConnRange, now: Date = Date()) async throws -> ConnSnapshot {
        let headers = ConnHTTP.bearer(key)
        let start = String(Int(range.start(now).timeIntervalSince1970))
        let member = email.trimmingCharacters(in: .whitespaces)
        var buckets = ConnBuckets(range: range, now: now)
        var credits = 0.0
        var page: String?
        for _ in 0..<6 {
            var query = [("dataset", "credit_usage"), ("start_time", start), ("bucket_width", range == .day ? "1h" : "1d"), ("limit", range == .day ? "24" : "31")]
            if !member.isEmpty { query.append(("user_email", member)) }
            if let page { query.append(("page", page)) }
            let obj = try await ConnHTTP.object(ConnHTTP.url(perplexityUsage, query), headers: headers)
            let p = addPerplexityBuckets(obj, buckets: &buckets)
            credits += p.total
            guard let next = p.next else { break }
            page = next
        }
        var snap = ConnSnapshot()
        snap.value = credits
        snap.text[ConnKey.unit] = ConnAIUnit.credits.rawValue
        snap.series = buckets.trimmed(now: now)
        snap.seriesStart = buckets.start
        snap.seriesStep = buckets.step
        if member.isEmpty, range != .day {
            var ignored = ConnBuckets(range: range, now: now)
            let query = [("dataset", "query_volume"), ("start_time", start), ("bucket_width", "1d"), ("limit", "31")]
            if let obj = try? await ConnHTTP.object(ConnHTTP.url(perplexityUsage, query), headers: headers) {
                snap.metrics[ConnKey.calls] = addPerplexityBuckets(obj, buckets: &ignored).total
            }
        }
        return snap
    }

    static let perplexityUsage = "https://api.perplexity.ai/v1/analytics/computer/usage"

    /// `data[]` buckets (`start_time` unix seconds, `count`) → total and the `next_page` cursor.
    static func addPerplexityBuckets(_ obj: [String: Any], buckets: inout ConnBuckets) -> (total: Double, next: String?) {
        var total = 0.0
        for b in J.array(obj["data"]) {
            let n = J.num(b["count"]) ?? 0
            total += n
            if let at = ConnDate.parse(b["start_time"]) { buckets.add(n, at: at) }
        }
        return (total, nextPage(obj))
    }

    // MARK: Grok (xAI Management API)

    /// Validates the management key (→ team id), then `POST /v1/billing/teams/{team}/usage` summing `usd` per day
    /// (per hour for today) in the user's time zone. Amounts are billed dollars.
    static func xai(key: String, range: ConnRange, now: Date = Date()) async throws -> ConnSnapshot {
        let headers = ConnHTTP.bearer(key)
        let info = try await ConnHTTP.object(URL(string: "https://management-api.x.ai/auth/management-keys/validation")!, headers: headers)
        guard let team = xaiTeam(info), let teamPath = team.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw ConnError(L("Use a team management key"))
        }
        let cal = ConnDate.calendar
        let start = range.start(now)
        let end: Date
        if range == .day {
            let hour = cal.dateInterval(of: .hour, for: now)?.start ?? now
            end = hour.addingTimeInterval(3600)
        } else {
            end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) ?? now
        }
        let body: [String: Any] = ["analyticsRequest": [
            "timeRange": ["startTime": wallClock(start), "endTime": wallClock(end), "timezone": ConnDate.zone.identifier],
            "timeUnit": range == .day ? "TIME_UNIT_HOUR" : "TIME_UNIT_DAY",
            "values": [["name": "usd", "aggregation": "AGGREGATION_SUM"]],
            "groupBy": [String](), "filters": [String]()
        ]]
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let obj = try await ConnHTTP.object(URL(string: "https://management-api.x.ai/v1/billing/teams/\(teamPath)/usage")!,
                                            headers: headers, method: "POST", body: data)
        var buckets = ConnBuckets(range: range, now: now)
        let usd = addXAIUsage(obj, buckets: &buckets)
        var snap = ConnSnapshot()
        snap.value = usd
        snap.currency = "USD"
        snap.metrics[ConnKey.cost] = usd
        snap.text[ConnKey.unit] = ConnAIUnit.usd.rawValue
        snap.series = buckets.trimmed(now: now)
        snap.seriesStart = buckets.start
        snap.seriesStep = buckets.step
        return snap
    }

    /// Team the key acts for: `scopeId` of a team-scoped key, else the deprecated `teamId`.
    static func xaiTeam(_ info: [String: Any]) -> String? {
        if J.str(info["scope"]) == "SCOPE_TEAM", let id = J.str(info["scopeId"]), !id.isEmpty { return id }
        if let id = J.str(info["teamId"]), !id.isEmpty { return id }
        return nil
    }

    /// `timeSeries[].dataPoints[]` (`timestamp` UTC, `values[0]` = usd) → total.
    static func addXAIUsage(_ obj: [String: Any], buckets: inout ConnBuckets) -> Double {
        var total = 0.0
        for series in J.array(obj["timeSeries"]) {
            for point in J.array(series["dataPoints"]) {
                let v = (point["values"] as? [Any])?.first.flatMap(J.num) ?? 0
                total += v
                if let at = ConnDate.parse(point["timestamp"]) { buckets.add(v, at: at) }
            }
        }
        return total
    }

    // MARK: GLM / Z.ai (Coding Plan monitor)

    /// `GET /api/monitor/usage/model-usage?startTime&endTime` — the endpoint Z.ai's own `glm-plan-usage` plugin
    /// queries, with the raw key in `Authorization`. Errors arrive as HTTP 200 with `success: false` (seen live).
    static func zai(key: String, region: String, range: ConnRange, now: Date = Date()) async throws -> ConnSnapshot {
        let host = region == "china" ? "https://open.bigmodel.cn" : "https://api.z.ai"
        let cal = ConnDate.calendar
        let hour = cal.dateInterval(of: .hour, for: now)?.start ?? now
        let query = [("startTime", wallClock(range.start(now))), ("endTime", wallClock(hour.addingTimeInterval(3599)))]
        let obj = try await ConnHTTP.object(ConnHTTP.url(host + "/api/monitor/usage/model-usage", query), headers: ["Authorization": key])
        return try parseZaiUsage(obj, range: range, now: now)
    }

    static func parseZaiUsage(_ obj: [String: Any], range: ConnRange, now: Date) throws -> ConnSnapshot {
        try zaiCheck(obj)
        let data = J.dict(obj["data"]) ?? [:]
        let labels = (data["x_time"] as? [Any])?.map { J.str($0) ?? "" } ?? []
        var buckets = ConnBuckets(range: range, now: now)
        var total = 0.0
        var top: (name: String, tokens: Double)?
        for model in J.array(data["modelDataList"]) {
            let values = (model["tokensUsage"] as? [Any]) ?? []
            var sum = 0.0
            for (i, raw) in values.enumerated() {
                let v = max(J.num(raw) ?? 0, 0)
                sum += v
                if i < labels.count, let at = parseWallClock(labels[i]) { buckets.add(v, at: at) }
            }
            total += sum
            if sum > (top?.tokens ?? 0) { top = (J.str(model["modelName"]) ?? "", sum) }
        }
        var snap = ConnSnapshot()
        snap.value = total
        snap.series = buckets.trimmed(now: now)
        snap.seriesStart = buckets.start
        snap.seriesStep = buckets.step
        if let top, !top.name.isEmpty { snap.text[ConnKey.name] = top.name }
        return snap
    }

    /// Z.ai envelope: `{"code":200,"success":true,"data":…}`; documented error codes otherwise
    /// (https://docs.z.ai/api-reference/api-code).
    static func zaiCheck(_ obj: [String: Any]) throws {
        let code = Int(J.num(obj["code"]) ?? 0)
        if (obj["success"] as? Bool) == true, code == 200 || code == 0 { return }
        switch code {
        case 401, 1000, 1001, 1002, 1003, 1004, 1005, 1220: throw ConnError(L("Check your token"))
        case 429, 1113, 1302, 1305, 1308...1321: throw ConnError(L("Rate limited"))
        default: throw ConnError(L("Unexpected response"))
        }
    }
}

/// GitHub billing usage items → Copilot quantity (premium requests or AI credits) and billed dollars per day.
struct ConnCopilotUsage {
    var buckets: ConnBuckets
    var quantity = 0.0, net = 0.0, gross = 0.0
    var credits = false

    init(range: ConnRange, now: Date) { buckets = ConnBuckets(range: range, now: now) }

    mutating func add(_ obj: [String: Any]) {
        for item in J.array(obj["usageItems"]) {
            guard (J.str(item["product"]) ?? "").localizedCaseInsensitiveContains("copilot"),
                  let day = ConnDate.parse(item["date"]), buckets.index(day) != nil else { continue }
            let q = J.num(item["quantity"]) ?? J.num(item["netQuantity"]) ?? 0
            quantity += q
            net += J.num(item["netAmount"]) ?? 0
            gross += J.num(item["grossAmount"]) ?? 0
            if (J.str(item["unitType"]) ?? "").localizedCaseInsensitiveContains("credit") { credits = true }
            buckets.add(q, at: day)
        }
    }

    func snapshot(now: Date) -> ConnSnapshot {
        var snap = ConnSnapshot()
        snap.value = quantity
        snap.currency = "USD"
        snap.metrics[ConnKey.calls] = quantity
        snap.metrics[ConnKey.cost] = net
        snap.metrics[ConnKey.grossCost] = gross
        snap.text[ConnKey.unit] = (credits ? ConnAIUnit.credits : ConnAIUnit.requests).rawValue
        snap.series = buckets.trimmed(now: now)
        snap.seriesStart = buckets.start
        snap.seriesStep = buckets.step
        return snap
    }
}

// MARK: - Tile and panel copy

extension ConnAIProvider {
    /// Headline unit before the first snapshot arrives (placeholder captions).
    var unit: ConnAIUnit {
        switch self {
        case .copilot, .gemini: return .requests
        case .perplexity: return .credits
        case .xai: return .usd
        case .antigravity: return .quota
        default: return .tokens
        }
    }
}

enum ConnAIText {
    static func unit(_ w: WidgetInstance, _ s: ConnSnapshot?) -> ConnAIUnit { s?.aiUnit ?? ConnAIProvider(w).unit }

    static func value(_ s: ConnSnapshot) -> String {
        let v = s.value ?? 0
        switch s.aiUnit {
        case .usd: return ConnFmt.money(v, s.currency ?? "USD", decimals: abs(v) >= 1000 ? 0 : 2)
        case .quota: return Fmt.percent(v)
        case .tokens, .requests, .credits: return Fmt.compact(v)
        }
    }

    static func noun(_ unit: ConnAIUnit) -> String {
        switch unit {
        case .tokens: return L("tokens")
        case .requests: return L("requests")
        case .credits: return L("credits")
        case .usd: return L("spend")
        case .quota: return L("quota left")
        }
    }

    /// "tokens · last 7d" · "requests · today" · "quota left · weekly".
    static func caption(_ w: WidgetInstance, _ s: ConnSnapshot?) -> String {
        let unit = unit(w, s)
        guard unit == .quota else { return "\(noun(unit)) · \(ConnService.range(w).caption)" }
        guard let window = s?.text[ConnKey.window], !window.isEmpty else { return noun(unit) }
        return "\(noun(unit)) · \(window)"
    }

    /// Small third line: "≈ $42.80 · in 892K" for token providers (unchanged), the billed amount, the top model,
    /// query count or quota reset otherwise.
    static func detail(_ s: ConnSnapshot?) -> String {
        guard let s else { return " " }
        func money(_ v: Double) -> String { ConnFmt.money(v, s.currency ?? "USD", decimals: 2) }
        switch s.aiUnit {
        case .tokens:
            guard let cost = s.metric(ConnKey.cost) else { return s.text[ConnKey.name] ?? " " }
            let input = Fmt.compact(s.metric(ConnKey.inputTokens) ?? 0)
            return "\(s.estimate ? "≈ " : "")\(money(cost)) · \(L("in %@", input))"
        case .requests, .credits:
            var parts: [String] = []
            if let cost = s.metric(ConnKey.cost) { parts.append(money(cost)) }
            if s.aiUnit == .credits, let queries = s.metric(ConnKey.calls) { parts.append(L("%@ queries", Fmt.compact(queries))) }
            return parts.isEmpty ? " " : parts.joined(separator: " · ")
        case .usd:
            return " "
        case .quota:
            var parts: [String] = []
            if let group = s.text[ConnKey.name], !group.isEmpty { parts.append(group) }
            if let reset = ConnDate.parse(s.text[ConnKey.reset]) { parts.append(L("resets %@", resetText(reset))) }
            return parts.isEmpty ? " " : parts.joined(separator: " · ")
        }
    }

    static func resetText(_ d: Date) -> String {
        Fmt.calendar.isDateInToday(d) ? Fmt.clock(d) : "\(Fmt.date(d, "MMMd")) \(Fmt.clock(d))"
    }

    /// Panel detail rows.
    static func rows(_ s: ConnSnapshot) -> [(String, String)] {
        func money(_ v: Double) -> String { ConnFmt.money(v, s.currency ?? "USD", decimals: 2) }
        switch s.aiUnit {
        case .tokens:
            guard s.metric(ConnKey.inputTokens) != nil else {
                var rows = [(L("Tokens"), Fmt.compact(s.value ?? 0))]
                if let model = s.text[ConnKey.name] { rows.append((L("Model"), model)) }
                return rows
            }
            var rows = [(L("Input"), Fmt.compact(s.metric(ConnKey.inputTokens) ?? 0)),
                        (L("Output"), Fmt.compact(s.metric(ConnKey.outputTokens) ?? 0))]
            if (s.metric(ConnKey.cacheRead) ?? 0) > 0 || (s.metric(ConnKey.cacheWrite) ?? 0) > 0 {
                rows.append((L("Cache write / read"), "\(Fmt.compact(s.metric(ConnKey.cacheWrite) ?? 0)) / \(Fmt.compact(s.metric(ConnKey.cacheRead) ?? 0))"))
            }
            rows.append((s.estimate ? L("Estimated cost") : L("Cost"), money(s.metric(ConnKey.cost) ?? 0)))
            if let calls = s.metric(ConnKey.calls), calls > 0 { rows.append((L("Requests"), ConnFmt.count(calls))) }
            return rows
        case .requests, .credits:
            var rows = [(s.aiUnit == .credits ? L("Credits") : L("Requests"), ConnFmt.count(s.value ?? 0))]
            if s.aiUnit == .credits, let queries = s.metric(ConnKey.calls) { rows.append((L("Queries"), ConnFmt.count(queries))) }
            if let cost = s.metric(ConnKey.cost) { rows.append((L("Cost"), money(cost))) }
            if let gross = s.metric(ConnKey.grossCost), gross > (s.metric(ConnKey.cost) ?? 0) + 0.005 { rows.append((L("List price"), money(gross))) }
            return rows
        case .usd:
            return [(L("Cost"), money(s.value ?? 0))]
        case .quota:
            var rows: [(String, String)] = []
            for i in 0..<6 {
                guard let label = s.text["quota.\(i)"], let left = s.metrics["quota.\(i)"] else { break }
                rows.append((label, Fmt.percent(left)))
            }
            if let reset = ConnDate.parse(s.text[ConnKey.reset]) { rows.append((L("Resets"), resetText(reset))) }
            return rows
        }
    }
}
