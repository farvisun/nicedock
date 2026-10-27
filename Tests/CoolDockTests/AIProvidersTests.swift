import Foundation
import SQLite3
import Testing
@testable import CoolDock

// Parser tests for the AI usage sources added after Claude Code / Codex / Anthropic / OpenAI.
// API sources use documentation-schema fixtures (doc URL on each suite); OpenCode uses real rows from this
// Mac's database with all content removed; Z.ai and Antigravity document no response schema, so their
// fixtures are shape fixtures (see the suite comments). The live auth answers are in LiveAuthAITests.

/// Cursor Admin API, `POST /teams/filtered-usage-events` — verbatim response examples of
/// https://cursor.com/docs/account/teams/admin-api ("Get Usage Events Data", incl. the service-account example).
@Suite struct CursorUsageTests {
    @Test func usageEventsPage() throws {
        var tally = ConnTally()
        var buckets = ConnBuckets(range: .week, now: TestDate.local(2025, 6, 27, 12))
        var tokenEvents = 0
        let more = ConnAIUsageAPI.addCursorEvents(try Fixture.object("cursor/usage-events-docs-2026-10-27.json"),
                                                  tally: &tally, buckets: &buckets, tokenEvents: &tokenEvents)
        #expect(more) // pagination.hasNextPage
        #expect(tally.input == 5931 && tally.output == 761) // 126 + 5805, 450 + 311
        #expect(tally.cacheWrite == 18076 && tally.cacheRead == 11964) // 6112 + 11964
        // `chargedCents` is what was billed (the request-based event has no tokenUsage but costs 8 cents).
        let cents: Double = 21.36232 + 37.33 + 8
        #expect(tally.cost.near(cents / 100))
        #expect(tally.calls == 3 && tokenEvents == 2)
        // Timestamps are millisecond strings: both token events land on 2025-06-26/27.
        let first: Double = 126 + 450 + 6112 + 11964, second: Double = 5805 + 311 + 11964
        #expect(buckets.values.reduce(0, +) == first + second)

        let last = ConnAIUsageAPI.addCursorEvents(try Fixture.object("cursor/usage-events-service-account-docs-2026-10-27.json"),
                                                  tally: &tally, buckets: &buckets, tokenEvents: &tokenEvents)
        #expect(!last && tally.calls == 4)
    }

    /// Pages until `hasNextPage` is false; one request body per page; billed cost, not an estimate.
    @Test func pagesAndSnapshot() async throws {
        let now = TestDate.local(2025, 6, 27, 12)
        let pages = [try Fixture.data("cursor/usage-events-docs-2026-10-27.json"),
                     try Fixture.data("cursor/usage-events-service-account-docs-2026-10-27.json")]
        let replay = LiveReplay([LiveReplay.Route(matches: { $0.url?.host == "api.cursor.com" }, reply: { req in
            let body = req.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let page = (body["page"] as? Int) ?? 1
            return (pages[min(page, 2) - 1], HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/2", headerFields: nil)!)
        })])
        let snap = try await replay.run { try await ConnAIUsageAPI.cursor(key: "crsr_x", email: " dev@company.com ", range: .week, now: now) }
        #expect(replay.requests.count == 2)
        let bodies = replay.requests.compactMap { $0.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
        #expect(bodies.map { $0["page"] as? Int } == [1, 2])
        #expect(bodies.allSatisfy { $0["email"] as? String == "dev@company.com" && $0["pageSize"] as? Int == 1000 })
        #expect(bodies.first?["startDate"] as? Int64 == ConnAIUsageAPI.ms(ConnRange.week.start(now)))
        #expect(replay.requests.first?.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("crsr_x:".utf8).base64EncodedString())
        #expect(snap.aiUnit == .tokens && !snap.estimate)
        let cents: Double = 21.36232 * 2 + 37.33 + 8
        #expect(snap.metrics[ConnKey.calls] == 4 && snap.metrics[ConnKey.cost]!.near(cents / 100))
    }

    /// Request-based plans: events without token counts → the tile counts requests.
    @Test func requestBasedPlanCountsRequests() async throws {
        let body = #"{"usageEvents":[{"timestamp":"1750978339901","kind":"Included in Business","chargedCents":8},{"timestamp":"1750978339902","chargedCents":0}],"pagination":{"hasNextPage":false}}"#
        let replay = LiveReplay([.ok("https://api.cursor.com/teams/filtered-usage-events", json: body)])
        let snap = try await replay.run { try await ConnAIUsageAPI.cursor(key: "crsr_x", email: "", range: .week, now: TestDate.local(2025, 6, 27, 12)) }
        #expect(snap.aiUnit == .requests && snap.value == 2)
        let bodies = replay.requests.compactMap { $0.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
        #expect(bodies.first?["email"] == nil)
    }
}

/// GitHub billing usage report for a user — https://docs.github.com/en/rest/billing/usage#get-billing-usage-report-for-a-user.
/// The first item is the documented example verbatim; the Copilot items follow its schema with Copilot's
/// product/SKU names (https://docs.github.com/en/billing/concepts/product-billing/github-copilot-premium-requests).
@Suite struct CopilotUsageTests {
    let now = TestDate.local(2026, 10, 27, 12)

    @Test func premiumRequests() throws {
        var usage = ConnCopilotUsage(range: .week, now: now)
        usage.add(try Fixture.object("copilot/billing-usage-docs-2026-10-27.json"))
        // Actions items (and the 2023 one) are ignored; 100 + 114 premium requests.
        #expect(usage.quantity == 214 && usage.net.near(3.36) && usage.gross.near(8.56) && !usage.credits)
        let snap = usage.snapshot(now: now)
        #expect(snap.aiUnit == .requests && snap.value == 214 && snap.currency == "USD")
        #expect(snap.series.reduce(0, +) == 214)
        let rows = ConnAIText.rows(snap)
        #expect(rows.map(\.0) == [L("Requests"), L("Cost"), L("List price")])
        #expect(rows[2].1 == ConnFmt.money(8.56, "USD", decimals: 2))
    }

    @Test func aiCredits() throws {
        var usage = ConnCopilotUsage(range: .day, now: now)
        usage.add(try Fixture.object("copilot/billing-usage-docs-2026-10-27.json")) // nothing today
        usage.add(try Fixture.object("copilot/billing-usage-ai-credits-docs-2026-10-27.json"))
        let snap = usage.snapshot(now: now)
        #expect(snap.aiUnit == .credits && snap.value == 100 && snap.metrics[ConnKey.cost] == 1.0)
    }

    @Test func periods() {
        #expect(ConnAIUsageAPI.copilotPeriods(range: .day, now: now).map { [$0.year, $0.month, $0.day ?? 0] } == [[2026, 10, 27]])
        #expect(ConnAIUsageAPI.copilotPeriods(range: .week, now: now).map { [$0.year, $0.month, $0.day ?? 0] } == [[2026, 10, 0]])
        #expect(ConnAIUsageAPI.copilotPeriods(range: .month, now: now).map { [$0.year, $0.month, $0.day ?? 0] } == [[2026, 9, 0], [2026, 10, 0]])
        let january = TestDate.local(2027, 1, 10, 12)
        #expect(ConnAIUsageAPI.copilotPeriods(range: .month, now: january).map { [$0.year, $0.month] } == [[2026, 12], [2027, 1]])
    }

    /// No user name → `GET /user` resolves the token's login first.
    @Test func resolvesLogin() async throws {
        let replay = LiveReplay([
            .ok("https://api.github.com/user", json: #"{"login":"octocat"}"#),
            .ok("https://api.github.com/users/octocat/settings/billing/usage", fixture: "copilot/billing-usage-docs-2026-10-27.json"),
        ])
        let snap = try await replay.run { try await ConnAIUsageAPI.copilot(token: "ghp_x", user: "", range: .month, now: now) }
        #expect(replay.requests.map { $0.url?.path } == ["/user", "/users/octocat/settings/billing/usage", "/users/octocat/settings/billing/usage"])
        #expect(replay.requests.dropFirst().map { queryOf($0)["month"] } == ["9", "10"])
        // The stub answers both months with the same items, so the October ones count twice.
        #expect(snap.value == 428)
    }
}

/// Cloud Monitoring `projects.timeSeries.list` — schema of
/// https://cloud.google.com/monitoring/api/ref_v3/rest/v3/projects.timeSeries/list and
/// https://cloud.google.com/monitoring/api/ref_v3/rest/v3/TimeSeries (`int64Value` is a decimal string).
/// AI Studio API keys have no usage endpoint (https://ai.google.dev/gemini-api/docs/billing: usage is in the
/// AI Studio dashboard), so the widget reads the project's Generative Language API request count.
@Suite struct GeminiUsageTests {
    let now = TestDate.local(2026, 10, 27, 12)

    @Test func requestCountSeries() throws {
        var buckets = ConnBuckets(range: .week, now: now)
        let total = ConnAIUsageAPI.addGeminiSeries(try Fixture.object("gemini/timeseries-docs-2026-10-27.json"), buckets: &buckets)
        #expect(total == 162)
        #expect(buckets.values.reduce(0, +) == 157) // the 10-10 point is outside the week
    }

    @Test func pagesWithToken() async throws {
        let first = try Fixture.data("gemini/timeseries-docs-2026-10-27.json")
        let replay = LiveReplay([LiveReplay.Route(matches: { $0.url?.host == "monitoring.googleapis.com" }, reply: { req in
            let body = queryOf(req)["pageToken"] == nil ? first : Data(#"{"timeSeries":[]}"#.utf8)
            return (body, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/2", headerFields: nil)!)
        })])
        let snap = try await replay.run { try await ConnAIUsageAPI.gemini(project: "my-project-123", token: "ya29.x", range: .week, now: now) }
        #expect(replay.requests.count == 2 && queryOf(replay.requests.last)["pageToken"] == "page-2")
        #expect(replay.requests.first?.url?.path == "/v3/projects/my-project-123/timeSeries")
        #expect(queryOf(replay.requests.first)["filter"] == ConnAIUsageAPI.geminiFilter)
        #expect(snap.aiUnit == .requests && snap.value == 162 && snap.metrics[ConnKey.cost] == nil)
        #expect(ConnAIText.detail(snap) == " ")
    }
}

/// Perplexity Analytics API `GET /v1/analytics/computer/usage` — verbatim example of
/// https://docs.perplexity.ai/docs/admin/computer-analytics-api (`credit_usage`, unix-second buckets).
@Suite struct PerplexityUsageTests {
    @Test func creditBuckets() throws {
        var buckets = ConnBuckets(range: .week, now: TestDate.local(2025, 5, 3, 12))
        let page = ConnAIUsageAPI.addPerplexityBuckets(try Fixture.object("perplexity/credit-usage-docs-2026-10-27.json"), buckets: &buckets)
        #expect(page.total == 350 && page.next == nil && buckets.values.reduce(0, +) == 350)
        let more = ConnAIUsageAPI.addPerplexityBuckets(["data": [], "has_more": true, "next_page": "cursor-2"], buckets: &buckets)
        #expect(more.next == "cursor-2")
    }

    @Test func creditsAndQueries() async throws {
        let replay = LiveReplay([
            LiveReplay.Route(matches: { queryOf($0)["dataset"] == "query_volume" }, reply: { req in
                (Data(#"{"data":[{"start_time":1746057600,"count":42}],"has_more":false}"#.utf8),
                 HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/2", headerFields: nil)!)
            }),
            .ok(ConnAIUsageAPI.perplexityUsage, fixture: "perplexity/credit-usage-docs-2026-10-27.json"),
        ])
        let snap = try await replay.run { try await ConnAIUsageAPI.perplexity(key: "pplx-x", email: "", range: .week, now: TestDate.local(2025, 5, 3, 12)) }
        #expect(snap.aiUnit == .credits && snap.value == 350 && snap.metrics[ConnKey.calls] == 42)
        #expect(ConnAIText.detail(snap) == L("%@ queries", Fmt.compact(42)))

        // A member filter only applies to credits (query volume is organization-wide): no second request.
        let member = LiveReplay([.ok(ConnAIUsageAPI.perplexityUsage, fixture: "perplexity/credit-usage-docs-2026-10-27.json")])
        let one = try await member.run { try await ConnAIUsageAPI.perplexity(key: "pplx-x", email: "me@company.com", range: .day, now: TestDate.local(2025, 5, 3, 12)) }
        #expect(member.requests.count == 1 && one.metrics[ConnKey.calls] == nil)
        let q = queryOf(member.requests.first)
        #expect(q["user_email"] == "me@company.com" && q["bucket_width"] == "1h" && q["limit"] == "24")
    }
}

/// xAI Management API — verbatim examples of https://docs.x.ai/developers/rest-api-reference/management/billing
/// (`POST /v1/billing/teams/{team_id}/usage`) and https://docs.x.ai/developers/rest-api-reference/management/auth
/// (`GET /auth/management-keys/validation`).
@Suite struct XAIUsageTests {
    @Test func usageSeries() throws {
        var buckets = ConnBuckets(range: .month, now: TestDate.local(2025, 10, 10, 12))
        let usd = ConnAIUsageAPI.addXAIUsage(try Fixture.object("xai/usage-docs-2026-10-27.json"), buckets: &buckets)
        #expect(usd.near(0.89984095))
        #expect(buckets.values.reduce(0, +).near(0.89984095))
    }

    @Test func teamOfKey() throws {
        #expect(ConnAIUsageAPI.xaiTeam(try Fixture.object("xai/validation-docs-2026-10-27.json")) == "65c1e471-205f-4566-9c5a-07198badf4ce")
        #expect(ConnAIUsageAPI.xaiTeam(["teamId": "t1", "scope": "SCOPE_USER"]) == "t1")
        #expect(ConnAIUsageAPI.xaiTeam(["scope": "SCOPE_USER"]) == nil)
    }

    @Test func spendSnapshot() async throws {
        let replay = LiveReplay([
            .ok("https://management-api.x.ai/auth/management-keys/validation", fixture: "xai/validation-docs-2026-10-27.json"),
            .ok("https://management-api.x.ai/v1/billing/teams/65c1e471-205f-4566-9c5a-07198badf4ce/usage", fixture: "xai/usage-docs-2026-10-27.json"),
        ])
        let now = TestDate.local(2025, 10, 10, 12)
        let snap = try await replay.run { try await ConnAIUsageAPI.xai(key: "xai-x", range: .day, now: now) }
        #expect(snap.aiUnit == .usd && snap.value!.near(0.89984095) && snap.currency == "USD")
        #expect(ConnAIText.value(snap) == ConnFmt.money(0.89984095, "USD", decimals: 2))
        let body = try #require(replay.requests.last?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        let request = try #require(body["analyticsRequest"] as? [String: Any])
        let window = try #require(request["timeRange"] as? [String: Any])
        // Today: hourly, from local midnight to the end of the current hour.
        #expect(request["timeUnit"] as? String == "TIME_UNIT_HOUR")
        #expect(window["startTime"] as? String == "2025-10-10 00:00:00" && window["endTime"] as? String == "2025-10-10 13:00:00")

        let userKey = LiveReplay([.ok("https://management-api.x.ai/auth/management-keys/validation", json: #"{"scope":"SCOPE_USER"}"#)])
        let message = await userKey.message { try await ConnAIUsageAPI.xai(key: "xai-x", range: .week, now: now) }
        #expect(message == L("Use a team management key"))
    }
}

/// Z.ai / BigModel Coding Plan monitor (`/api/monitor/usage/model-usage`). Z.ai publishes no response schema for
/// it; the endpoint and headers come from Z.ai's own plugin (github.com/zai-org/zai-coding-plugins,
/// glm-plan-usage/skills/usage-query-skill/scripts/query-usage.mjs). The fixture is a shape fixture following a
/// third-party client's test data (dates moved), so only the envelope and series structure are asserted.
@Suite struct ZaiUsageTests {
    let now = TestDate.local(2026, 10, 26, 12)

    @Test func modelUsage() throws {
        let snap = try ConnAIUsageAPI.parseZaiUsage(try Fixture.object("zai/model-usage-shape-2026-10-27.json"), range: .day, now: now)
        #expect(snap.value == 175 && snap.text[ConnKey.name] == "glm-4.6")
        #expect(snap.series.count == 13 && snap.series[8] == 150 && snap.series[9] == 25) // local wall-clock hours
        #expect(snap.aiUnit == .tokens && ConnAIText.detail(snap) == "glm-4.6")
        #expect(ConnAIText.rows(snap).map(\.0) == [L("Tokens"), L("Model")])
    }

    @Test func envelopeCodes() {
        #expect(throws: ConnError(L("Check your token"))) { try ConnAIUsageAPI.zaiCheck(["code": 401, "msg": "token expired or incorrect", "success": false]) }
        #expect(throws: ConnError(L("Check your token"))) { try ConnAIUsageAPI.zaiCheck(["code": 1001, "success": false]) }
        #expect(throws: ConnError(L("Rate limited"))) { try ConnAIUsageAPI.zaiCheck(["code": 1302, "success": false]) }
        #expect(throws: ConnError(L("Unexpected response"))) { try ConnAIUsageAPI.zaiCheck(["code": 500, "success": false]) }
        #expect(throws: Never.self) { try ConnAIUsageAPI.zaiCheck(["code": 200, "success": true]) }
    }

    @Test func wallClock() {
        let d = TestDate.local(2026, 10, 26, 9, 5)
        #expect(ConnAIUsageAPI.wallClock(d) == "2026-10-26 09:05:00")
        #expect(ConnAIUsageAPI.parseWallClock("2026-10-26 09:05") == d && ConnAIUsageAPI.parseWallClock("2026-10-26") == TestDate.local(2026, 10, 26))
    }
}

/// Antigravity CLI `/usage` in print mode (`agy -p "/usage" --output-format json`;
/// https://antigravity.google/docs/cli/commands/usage). The JSON layout is not documented: the fixture is a
/// shape fixture following a third-party client's synthetic test payload. No CLI is run in tests.
@Suite struct AntigravityUsageTests {
    @Test func quotaReport() throws {
        let snap = try ConnAntigravity.parseReport(try Fixture.object("antigravity/usage-report-shape-2026-10-27.json"))
        #expect(snap.aiUnit == .quota && snap.value == 0.86)
        #expect(snap.text[ConnKey.name] == "Gemini Models" && snap.text[ConnKey.window] == "weekly")
        #expect(ConnDate.parse(snap.text[ConnKey.reset]) == TestDate.utc("2026-09-17T18:40:27Z"))
        #expect((0..<4).map { snap.metrics["quota.\($0)"] } == [0.86, 0.95, 0.89, 1.0])
        #expect(snap.text["quota.2"] == "Claude and GPT models · weekly")
        #expect(ConnAIText.value(snap) == Fmt.percent(0.86))
        let w = WidgetInstance(kind: .aiUsage, config: ["provider": "antigravity"])
        #expect(ConnAIText.caption(w, snap) == "\(L("quota left")) · weekly")
        #expect(ConnAIText.caption(w, nil) == L("quota left"))
        #expect(ConnAIText.rows(snap).count == 5) // four buckets + reset
    }

    @Test func failures() {
        #expect(throws: ConnError(L("Sign in to Antigravity"))) {
            try ConnAntigravity.parseReport(["status": "ERROR", "response": "Please sign in to continue"])
        }
        #expect(throws: ConnError(L("Unexpected response"))) { try ConnAntigravity.parseReport(["status": "ERROR", "response": "boom"]) }
        #expect(throws: ConnError(L("No usage data"))) {
            try ConnAntigravity.parseReport(["status": "SUCCESS", "command": ["name": "usage", "data": ["groups": []]]])
        }
    }
}

/// OpenCode's SQLite store (https://opencode.ai/docs/troubleshooting#storage). The fixture holds real rows of
/// this Mac's `opencode.db` (2026-10-27) reduced to ids, times, model ids, cost and token counts: every row of
/// one day in `session_message`, twelve rows present in both tables (migrated), assistant rows only in the
/// older `message` table and a few user/system rows. The expected numbers were tallied independently in
/// Python from the same rows.
@Suite struct OpenCodeUsageTests {
    func database() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cooldock-opencode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open(dir.appendingPathComponent("opencode.db").path, &db) == SQLITE_OK else { throw ConnError("sqlite open") }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, try Fixture.string("opencode/opencode-redacted-2026-10-27.sql"), nil, nil, nil) == SQLITE_OK else {
            throw ConnError("sqlite exec")
        }
        return dir
    }

    @Test func dayOfSessionMessages() throws {
        let dir = try database()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = TestDate.local(2026, 10, 18, 12)
        let rows = try ConnOpenCode.scan(roots: [dir], since: ConnRange.week.start(now))
        let snap = ConnOpenCode.aggregate(rows, range: .week, now: now)
        // 37 assistant rows on 2026-10-17; user / idle / model-switch rows are ignored.
        #expect(snap.metrics[ConnKey.calls] == 37)
        let output: Double = 2290 + 5430, prompt: Double = 152_911 + 1_033_664
        #expect(snap.metrics[ConnKey.outputTokens] == output) // output + reasoning
        #expect(snap.metrics[ConnKey.cacheRead] == 1_033_664 && snap.metrics[ConnKey.cacheWrite] == 0)
        #expect(snap.metrics[ConnKey.inputTokens] == prompt)
        #expect(snap.value == prompt + output)
        #expect(snap.metrics[ConnKey.cost] == 0 && snap.estimate)
        #expect(snap.series.reduce(0, +) == snap.value)
        // Opened read-only: nothing was written next to the database.
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["opencode.db"])
    }

    @Test func migratedRowsCountOnce() throws {
        let dir = try database()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = TestDate.local(2026, 8, 3, 12)
        let snap = ConnOpenCode.aggregate(try ConnOpenCode.scan(roots: [dir], since: ConnRange.month.start(now)), range: .month, now: now)
        #expect(snap.metrics[ConnKey.calls] == 12)
        let prompt: Double = 62_793 + 113_152
        #expect(snap.metrics[ConnKey.inputTokens] == prompt && snap.metrics[ConnKey.outputTokens] == 3951)

        let all = try ConnOpenCode.readDatabase(dir.appendingPathComponent("opencode.db"), sinceMS: 0)
        #expect(all.count == 54 && Set(all.map(\.id)).count == 54)
        #expect(all.map(\.input).reduce(0, +) == 520_152 && all.map(\.output).reduce(0, +) == 14_944)
        #expect(all.map(\.reasoning).reduce(0, +) == 6132 && all.map(\.cacheRead).reduce(0, +) == 1_146_944)
        #expect(all.map(\.cost).reduce(0, +).near(0.07500628))
    }

    @Test func legacyOnlyRowWithCost() throws {
        let dir = try database()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = TestDate.local(2026, 4, 26, 12)
        let snap = ConnOpenCode.aggregate(try ConnOpenCode.scan(roots: [dir], since: ConnRange.month.start(now)), range: .month, now: now)
        // Only in the `message` table (never migrated); a paid model, so OpenCode recorded a cost.
        #expect(snap.metrics[ConnKey.calls] == 1 && snap.metrics[ConnKey.cost]!.near(0.07500628))
        let prompt: Double = 50_513 + 128
        #expect(snap.metrics[ConnKey.inputTokens] == prompt && snap.metrics[ConnKey.outputTokens] == 967)
        #expect(ConnAIText.detail(snap).hasPrefix("≈ "))
        // Rows after `now` (later days) are not counted.
        let earlier = ConnOpenCode.aggregate(try ConnOpenCode.scan(roots: [dir], since: .distantPast), range: .week, now: TestDate.local(2026, 4, 20, 12))
        #expect(earlier.metrics[ConnKey.calls] == 0)
    }

    /// Pre-database installs: `storage/message/<session>/<message>.json` (redacted real files).
    @Test func legacyJSONFiles() throws {
        let now = TestDate.local(2026, 2, 20, 12)
        let rows = try ConnOpenCode.scan(roots: [Fixture.url("opencode/legacy")], since: ConnRange.week.start(now))
        let snap = ConnOpenCode.aggregate(rows, range: .week, now: now)
        #expect(rows.count == 3) // the user message is skipped
        let input: Double = 4553 + 6724 + 10626, output: Double = 168 + 337 + 269
        #expect(snap.metrics[ConnKey.calls] == 3 && snap.metrics[ConnKey.inputTokens] == input)
        #expect(snap.metrics[ConnKey.outputTokens] == output)
    }

    @Test func noData() {
        #expect(throws: ConnError(L("No OpenCode data found"))) { try ConnOpenCode.scan(roots: [], since: .distantPast) }
    }
}

/// The setup form shows only the fields of the chosen provider.
@Suite struct AIUsageSetupTests {
    func shown(_ provider: String) -> [String] {
        let w = WidgetInstance(kind: .aiUsage, config: ["provider": provider])
        return WidgetKind.aiUsage.spec.fields.filter { $0.isShown(in: w) }.map(\.key)
    }

    @Test func fieldsPerProvider() {
        #expect(shown("claudeCode") == ["provider", "range"])
        #expect(shown("opencode") == ["provider", "range"])
        #expect(shown("antigravity") == ["provider"])
        #expect(shown("cursor") == ["provider", "token", "email", "range"])
        #expect(shown("copilot") == ["provider", "token", "user", "range"])
        #expect(shown("gemini") == ["provider", "project", "token", "range"])
        #expect(shown("perplexity") == ["provider", "email", "token", "range"])
        #expect(shown("xai") == ["provider", "token", "range"])
        #expect(shown("zai") == ["provider", "token", "region", "range"])
        // Exactly one token field per keyed provider.
        for p in ConnAIProvider.allCases where !p.isLocal {
            #expect(shown(p.rawValue).filter { $0 == "token" }.count == 1, "\(p)")
        }
    }

    @Test func configured() {
        func ok(_ config: [String: String], _ token: String?) -> Bool {
            ConnService.isConfigured(WidgetInstance(kind: .aiUsage, config: config), token: token)
        }
        #expect(ok(["provider": "opencode"], nil) && ok(["provider": "antigravity"], nil))
        #expect(!ok(["provider": "cursor"], nil) && ok(["provider": "cursor"], "crsr_x"))
        #expect(!ok(["provider": "gemini"], "ya29.x") && ok(["provider": "gemini", "project": "p-1"], nil))
    }
}
