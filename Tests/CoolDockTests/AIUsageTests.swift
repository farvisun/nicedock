import Foundation
import Testing
@testable import CoolDock

/// Anthropic Admin API — verbatim examples of
/// https://platform.claude.com/docs/en/api/beta/organization/usage_report/retrieve_messages and
/// https://platform.claude.com/docs/en/api/beta/organization/cost_report/retrieve (`amount` is a decimal
/// string in cents: "123.45" = $1.23), plus a second usage page inside the widget window.
@Suite struct AnthropicUsageTests {
    let now = TestDate.local(2026, 10, 27, 15)

    @Test func usagePages() throws {
        var tally = ConnTally()
        var buckets = ConnBuckets(range: .week, now: now)
        let start = ConnRange.week.start(now)
        let next = ConnAIUsageAPI.addAnthropicUsage(try Fixture.object("anthropic/usage-report-docs-2026-10-27.json"), start: start, tally: &tally, buckets: &buckets)
        #expect(next == "page_MjAyNS0wNS0xNFQwMDowMDowMFo=")
        #expect(tally.input == 1500 && tally.output == 500 && tally.cacheRead == 200 && tally.cacheWrite == 0)
        // claude-opus-5-5 list price: $4 in / $20 out / $0.20 cache read per MTok.
        let opusCost: Double = 1500 * 4.0 + 500 * 20.0 + 200 * 0.2
        #expect(tally.cost.near(opusCost / 1_000_000))
        #expect(buckets.values.allSatisfy { $0 == 0 }) // 2025-08-01 is outside the window

        let last = ConnAIUsageAPI.addAnthropicUsage(try Fixture.object("anthropic/usage-report-window-docs-2026-10-27.json"), start: start, tally: &tally, buckets: &buckets)
        #expect(last == nil) // has_more false / next_page null
        #expect(tally.input == 13500) // 1500 + 2000 + 10000
        #expect(tally.output == 9500) // 500 + 8000 + 1000
        #expect(tally.cacheRead == 200 + 50000)
        #expect(tally.cacheWrite == 5000) // 4000 × 5 min + 1000 × 1 h
        // Bucket for 2026-10-25 UTC holds both models' tokens.
        #expect(buckets.values.reduce(0, +) == 76000) // 2000 + 8000 + 50000 + 5000 + 10000 + 1000

        let snap = tally.snapshot(series: buckets, now: now, estimate: true)
        #expect(snap.value == tally.total && snap.metrics[ConnKey.inputTokens] == tally.promptSide)
    }

    @Test func costReportInCents() throws {
        let page = ConnAIUsageAPI.anthropicCostPage(try Fixture.object("anthropic/cost-report-docs-2026-10-27.json"))
        #expect(page.dollars.near(1.2378912))
        #expect(page.next == "page_MjAyNS0wNS0xNFQwMDowMDowMFo=")
    }
}

/// OpenAI Admin API — verbatim examples of
/// https://developers.openai.com/api/reference/resources/admin/subresources/organization/subresources/usage/methods/completions
/// and …/methods/costs (`input_tokens` includes cached and cache-write tokens; `amount.value` in dollars;
/// Unix-second bucket times).
@Suite struct OpenAIUsageTests {
    @Test func completionsSplitsInput() throws {
        let raw = try Fixture.object("openai/usage-completions-docs-2026-10-27.json")
        let result = ConnJSON.array(ConnJSON.array(raw["data"])[0]["results"])[0]
        var tally = ConnTally()
        var buckets = ConnBuckets(range: .week, now: Date())
        let next = ConnAIUsageAPI.addOpenAIUsage(raw, start: Date(), tally: &tally, buckets: &buckets)
        #expect(next == "page_AAAAAGdGxdEiJdKOAAAAAGcqsYA=")
        // Matches the documented breakdown 1000 = 400 cached + 100 cache-write + 500 uncached.
        #expect(tally.input == ConnJSON.num(result["input_uncached_tokens"]))
        #expect(tally.cacheRead == 400 && tally.cacheWrite == 100 && tally.output == 500)
        #expect(tally.promptSide == ConnJSON.num(result["input_tokens"]))
        #expect(tally.calls == 5)
        // model null → default price $1.25 in / $10 out / $0.125 cached.
        let listCost: Double = 500 * 1.25 + 400 * 0.125 + 100 * 1.25 + 500 * 10.0
        #expect(tally.cost.near(listCost / 1_000_000))
    }

    @Test func costsInDollars() throws {
        let page = ConnAIUsageAPI.openaiCostPage(try Fixture.object("openai/costs-docs-2026-10-27.json"))
        #expect(page.dollars == 0.06 && page.next == nil)
    }
}

/// Local Claude Code / Codex JSONL scanning. The fixtures mirror the structure of real log lines on
/// this Mac (keys, nesting, streaming duplicates, resumed sessions) with all content redacted.
@Suite struct LocalLogsTests {
    let now = TestDate.local(2026, 10, 27, 12)

    @Test func claudeCodeFixture() throws {
        let files = try ConnLogScanner.update(.claude, [:], since: .distantPast, roots: [Fixture.url("claude-code/projects")])
        #expect(files.count == 2)
        let snap = ConnLogScanner.aggregate(files, range: .month, now: now)
        // msg A streamed twice (5 then 273 output tokens) → the final line counts; msg B appears in
        // both files → once; the id-less line counts; <synthetic> and the 09-01 call are excluded.
        #expect(snap.metrics[ConnKey.outputTokens] == 1223) // 273 + 900 + 50
        #expect(snap.metrics[ConnKey.cacheWrite] == 24425)
        #expect(snap.metrics[ConnKey.cacheRead] == 57435) // 16435 + 41000
        #expect(snap.metrics[ConnKey.inputTokens] == 81972) // (2 + 10 + 100) + 24425 + (16435 + 41000)
        #expect(snap.metrics[ConnKey.calls] == 3)
        #expect(snap.value == snap.metrics[ConnKey.inputTokens]! + snap.metrics[ConnKey.outputTokens]!)
        // Opus 5.5: 1 h cache writes at 2× input; Sonnet 5: $2 / $10.
        let msgA: Double = 2 * 4.0 + 273 * 20.0 + 16435 * 0.2 + 24425 * 8.0
        let msgB: Double = 10 * 4.0 + 900 * 20.0 + 41000 * 0.2
        let sonnet: Double = 100 * 2.0 + 50 * 10.0
        #expect(snap.metrics[ConnKey.cost]!.near((msgA + msgB + sonnet) / 1_000_000, 1e-6))
        #expect(snap.estimate)
    }

    @Test func codexFixture() throws {
        let files = try ConnLogScanner.update(.codex, [:], since: .distantPast, roots: [Fixture.url("codex/sessions")])
        #expect(files.count == 2)
        let snap = ConnLogScanner.aggregate(files, range: .month, now: now)
        // Cumulative totals → per-event deltas; the repeated event adds nothing.
        #expect(snap.metrics[ConnKey.cacheRead] == 40000) // 13184 + 26816
        #expect(snap.metrics[ConnKey.outputTokens] == 600)
        #expect(snap.metrics[ConnKey.inputTokens] == 50000) // uncached 10000 + cached 40000
        #expect(snap.metrics[ConnKey.calls] == 2)
        let codexCost: Double = 10000 * 1.25 + 40000 * 0.125 + 600 * 10.0
        #expect(snap.metrics[ConnKey.cost]!.near(codexCost / 1_000_000, 1e-6))
    }

    @Test func incrementalRescanReadsOnlyNewLines() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cooldock-logs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let lines = try Fixture.string("claude-code/projects/-Users-demo-app/0b6f4c0e-session-a.jsonl").split(separator: "\n", omittingEmptySubsequences: true)
        let file = dir.appendingPathComponent("s.jsonl")
        // First two lines + half of the third (a write in progress).
        let partial = lines[0] + "\n" + lines[1] + "\n" + lines[2].prefix(40)
        try Data(partial.utf8).write(to: file)
        var files = try ConnLogScanner.update(.claude, [:], since: .distantPast, roots: [dir])
        #expect(ConnLogScanner.aggregate(files, range: .month, now: now).metrics[ConnKey.outputTokens] == 5)

        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
        files = try ConnLogScanner.update(.claude, files, since: .distantPast, roots: [dir])
        let snap = ConnLogScanner.aggregate(files, range: .month, now: now)
        #expect(snap.metrics[ConnKey.outputTokens] == 1173) // 273 + 900
        #expect(snap.metrics[ConnKey.calls] == 2)
    }

    // MARK: Real logs (opt-in)

    static let verifyRealLogs = ProcessInfo.processInfo.environment["COOLDOCK_VERIFY_LOCAL_LOGS"] == "1"

    /// Scans this Mac's real ~/.claude and ~/.codex logs and compares the totals with an independent
    /// `json.loads` tally (`Tests/Scripts/usage_tally.py`) over exactly the bytes the scanner consumed.
    /// Run with `COOLDOCK_VERIFY_LOCAL_LOGS=1 swift test --filter LocalLogsTests`.
    @Test(.enabled(if: verifyRealLogs), arguments: [ConnLogSource.claude, .codex])
    func realLogsMatchIndependentTally(_ source: ConnLogSource) throws {
        let now = Date()
        let range = ConnRange.month
        let since = range.start(now)
        let files = try ConnLogScanner.update(source, [:], since: since)
        let snap = ConnLogScanner.aggregate(files, range: range, now: now)

        let manifest: [String: Any] = [
            "source": source.rawValue,
            "start": Int(max(since.timeIntervalSince1970, 0)),
            "files": Dictionary(uniqueKeysWithValues: files.map { ($0.key, $0.value.offset) })
        ]
        let manifestURL = FileManager.default.temporaryDirectory.appendingPathComponent("cooldock-usage-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        defer { try? FileManager.default.removeItem(at: manifestURL) }

        let python = Process()
        python.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        python.arguments = ["-I", Fixture.root.deletingLastPathComponent().appendingPathComponent("Scripts/usage_tally.py").path, manifestURL.path]
        let out = Pipe()
        python.standardOutput = out
        try python.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        python.waitUntilExit()
        #expect(python.terminationStatus == 0)
        let expected = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Double])

        let m = snap.metrics
        print("[\(source.rawValue)] files=\(files.count) app: in=\(m[ConnKey.inputTokens]!) out=\(m[ConnKey.outputTokens]!) cw=\(m[ConnKey.cacheWrite]!) cr=\(m[ConnKey.cacheRead]!) calls=\(m[ConnKey.calls]!) | python: \(expected)")
        #expect(m[ConnKey.outputTokens] == expected["output"])
        #expect(m[ConnKey.cacheWrite] == expected["cacheWrite"])
        #expect(m[ConnKey.cacheRead] == expected["cacheRead"])
        #expect(m[ConnKey.inputTokens] == expected["input"]! + expected["cacheWrite"]! + expected["cacheRead"]!)
        #expect(m[ConnKey.calls] == expected["calls"])
        #expect((m[ConnKey.calls] ?? 0) > 0)
    }
}
