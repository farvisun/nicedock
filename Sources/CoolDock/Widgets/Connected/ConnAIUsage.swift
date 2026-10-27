import Darwin
import Foundation

private typealias J = ConnJSON

// MARK: - Prices (USD per million tokens) — estimates only

struct ConnPrice {
    var input: Double
    var output: Double
    var cacheWrite: Double
    var cacheRead: Double
}

enum ConnPrices {
    /// Anthropic list prices by model family (cache write 5 min = 1.25× input; 1 h = 2× input).
    static func claude(_ model: String) -> ConnPrice {
        let m = model.lowercased()
        func p(_ i: Double, _ o: Double, read: Double? = nil) -> ConnPrice {
            ConnPrice(input: i, output: o, cacheWrite: i * 1.25, cacheRead: read ?? i * 0.1)
        }
        if m.contains("fable") || m.contains("mythos") { return p(10, 50, read: m.contains("5-1") ? 0.25 : 1) }
        if m.contains("opus") {
            if m.contains("opus-5-5") { return p(4, 20, read: 0.2) }
            if ["opus-5", "opus-4-8", "opus-4-7", "opus-4-6", "opus-4-5"].contains(where: { m.contains($0) }) { return p(5, 25) }
            return p(15, 75)
        }
        if m.contains("sonnet") { return m.contains("sonnet-5") ? p(2, 10, read: 0.2) : p(3, 15) }
        if m.contains("haiku") {
            if m.contains("haiku-5") { return p(0.1, 0.5) }
            if m.contains("haiku-4") { return p(1, 5) }
            return m.contains("3-5") ? p(0.8, 4) : p(0.25, 1.25)
        }
        return p(3, 15)
    }

    /// OpenAI list prices; `cacheRead` is the cached-input rate.
    static func openai(_ model: String) -> ConnPrice {
        let m = model.lowercased()
        func p(_ i: Double, _ o: Double, _ cached: Double) -> ConnPrice { ConnPrice(input: i, output: o, cacheWrite: i, cacheRead: cached) }
        if m.contains("nano") { return p(0.05, 0.4, 0.005) }
        if m.contains("codex-mini") { return p(1.5, 6, 0.375) }
        if m.contains("4.1-mini") { return p(0.4, 1.6, 0.1) }
        if m.contains("4o-mini") { return p(0.15, 0.6, 0.075) }
        if m.contains("mini") { return p(0.25, 2, 0.025) }
        if m.contains("gpt-4.1") { return p(2, 8, 0.5) }
        if m.contains("gpt-4o") { return p(2.5, 10, 1.25) }
        if m.hasPrefix("o3") { return p(2, 8, 0.5) }
        if m.hasPrefix("o4") { return p(1.1, 4.4, 0.275) }
        return p(1.25, 10, 0.125)
    }
}

/// Token tally shared by local scanners and API providers.
struct ConnTally {
    var input = 0.0, output = 0.0, cacheWrite = 0.0, cacheRead = 0.0, cost = 0.0, calls = 0.0

    var promptSide: Double { input + cacheWrite + cacheRead }
    var total: Double { promptSide + output }

    func snapshot(series: ConnBuckets, now: Date, estimate: Bool) -> ConnSnapshot {
        var snap = ConnSnapshot()
        snap.value = total
        snap.currency = "USD"
        snap.metrics[ConnKey.inputTokens] = promptSide
        snap.metrics[ConnKey.outputTokens] = output
        snap.metrics[ConnKey.cacheWrite] = cacheWrite
        snap.metrics[ConnKey.cacheRead] = cacheRead
        snap.metrics[ConnKey.cost] = cost
        snap.metrics[ConnKey.calls] = calls
        snap.series = series.trimmed(now: now)
        snap.seriesStart = series.start
        snap.seriesStep = series.step
        snap.estimate = estimate
        return snap
    }
}

// MARK: - Local logs (Claude Code, Codex)

enum ConnLogSource: String, Sendable { case claude, codex }

/// One assistant message / token_count event, compacted (32 bytes) for incremental re-aggregation.
struct ConnLogEntry: Sendable {
    var key: UInt64          // message+request hash for de-duplication (0 = none)
    var time: UInt32         // unix seconds
    var input: Float
    var output: Float
    var cacheWrite: Float
    var cacheRead: Float
    var cost: Float
}

/// Per-file scan state. JSONL logs are append-only, so refreshes only read new bytes.
struct ConnLogFile: Sendable {
    var offset = 0           // bytes consumed (through the last complete line)
    var mtime = Date.distantPast
    var entries: [ConnLogEntry] = []
    // Codex keeps cumulative totals per session; remember where we were.
    var model = ""
    var prevInput = 0.0, prevCached = 0.0, prevOutput = 0.0
}

/// Scans local JSONL logs off the main thread. File results are cached per path (only appended
/// bytes are read on refresh) and aggregated snapshots are cached for 10 minutes.
actor ConnLocalUsage {
    static let shared = ConnLocalUsage()

    private var results: [String: (at: Date, snap: ConnSnapshot)] = [:]
    private var files: [ConnLogSource: [String: ConnLogFile]] = [:]
    private var scanning: [ConnLogSource: Task<[String: ConnLogFile], Error>] = [:]

    func claudeCode(range: ConnRange) async throws -> ConnSnapshot { try await usage(.claude, range: range) }
    func codex(range: ConnRange) async throws -> ConnSnapshot { try await usage(.codex, range: range) }

    private func usage(_ source: ConnLogSource, range: ConnRange) async throws -> ConnSnapshot {
        let key = "\(source.rawValue).\(range.rawValue)"
        if let hit = results[key], Date().timeIntervalSince(hit.at) < 600 { return hit.snap }
        // One scan per source at a time; a waiting caller then runs its own (cheap, incremental) pass.
        while let running = scanning[source] { _ = try? await running.value }
        let previous = files[source] ?? [:]
        let since = range.start()
        let task = Task.detached(priority: .utility) { try ConnLogScanner.update(source, previous, since: since) }
        scanning[source] = task
        defer { scanning[source] = nil }
        let updated = try await task.value
        files[source] = updated
        let snap = ConnLogScanner.aggregate(updated, range: range)
        results[key] = (Date(), snap)
        return snap
    }
}

/// Byte-level JSONL scanning: `memmem` for the few keys we need, no full JSON parse.
enum ConnLogScanner {
    static func roots(_ source: ConnLogSource) -> [URL] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var paths: [URL]
        switch source {
        case .claude:
            paths = [".claude/projects", ".config/claude/projects"].map { home.appendingPathComponent($0, isDirectory: true) }
            if let custom = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
                paths.append(URL(fileURLWithPath: (custom as NSString).expandingTildeInPath).appendingPathComponent("projects"))
            }
        case .codex:
            paths = [".codex/sessions", ".codex/archived_sessions"].map { home.appendingPathComponent($0, isDirectory: true) }
        }
        return paths.filter { fm.fileExists(atPath: $0.path) }
    }

    /// `roots` overrides the default log folders (tests point it at fixture directories).
    static func update(_ source: ConnLogSource, _ previous: [String: ConnLogFile], since: Date, roots custom: [URL]? = nil) throws -> [String: ConnLogFile] {
        let roots = custom ?? roots(source)
        guard !roots.isEmpty else {
            throw ConnError(source == .claude ? L("No Claude Code logs found") : L("No Codex logs found"))
        }
        // Keep cached files up to the longest range so 7d and 30d widgets don't evict each other.
        let horizon = Date().addingTimeInterval(-32 * 86_400)
        var out = previous.filter { $0.value.mtime >= horizon }
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        for root in roots {
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walker where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      let mtime = values.contentModificationDate, mtime >= since,
                      let size = values.fileSize else { continue }
                var file = out[url.path] ?? ConnLogFile()
                if size < file.offset { file = ConnLogFile() } // rewritten
                if size > file.offset { scan(source, url, &file) }
                file.mtime = mtime
                out[url.path] = file
            }
        }
        return out
    }

    /// Reads bytes after `file.offset` and appends entries for every complete line.
    private static func scan(_ source: ConnLogSource, _ url: URL, _ file: inout ConnLogFile) {
        let data: Data
        if file.offset == 0 {
            guard let mapped = try? Data(contentsOf: url, options: [.alwaysMapped]) else { return }
            data = mapped
        } else {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return }
            defer { try? handle.close() }
            guard (try? handle.seek(toOffset: UInt64(file.offset))) != nil, let tail = try? handle.readToEnd() else { return }
            data = tail
        }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let p = raw.baseAddress?.assumingMemoryBound(to: UInt8.self), raw.count > 0 else { return }
            // Only complete lines; a partially written last line is picked up next time.
            var n = raw.count
            while n > 0, p[n - 1] != 10 { n -= 1 }
            guard n > 0 else { return }
            let buffer = UnsafeBufferPointer(start: p, count: n)
            switch source {
            case .claude: scanClaude(buffer, &file)
            case .codex: scanCodex(buffer, &file)
            }
            file.offset += n
        }
    }

    private static func scanClaude(_ b: UnsafeBufferPointer<UInt8>, _ file: inout ConnLogFile) {
        ConnBytes.forEachLine(b, containing: [Needle.usage]) { line, hit, _ in
            // Timestamp is a top-level key after `message`; fall back to the first occurrence.
            guard let tsRange = line.value(after: Needle.timestamp, from: hit) ?? line.value(after: Needle.timestamp, from: 0),
                  let date = line.date(tsRange) else { return }
            let model = line.string(line.value(after: Needle.model, from: 0)) ?? ""
            if model == "<synthetic>" { return }
            // Streaming writes one line per content block (output_tokens grows until the last one);
            // resumed sessions copy history into new files — hash message + request ids so each
            // call counts once (`aggregate` keeps the most complete line).
            var hash = ConnFNV()
            if let r = line.value(after: Needle.messageID, from: 0) { hash.add(line, r) }
            if let r = line.value(after: Needle.requestID, from: 0) { hash.add(line, r) }

            let input = line.number(after: Needle.inputTokens, from: hit) ?? 0
            let output = line.number(after: Needle.outputTokens, from: hit) ?? 0
            let write = line.number(after: Needle.cacheCreation, from: hit) ?? 0
            let read = line.number(after: Needle.cacheRead, from: hit) ?? 0
            let write1h = min(line.number(after: Needle.ephemeral1h, from: hit) ?? 0, write)
            let price = ConnPrices.claude(model)
            let cost = (input * price.input + output * price.output + read * price.cacheRead
                        + (write - write1h) * price.cacheWrite + write1h * price.input * 2) / 1_000_000
            file.entries.append(ConnLogEntry(key: hash.used ? hash.value : 0, time: UInt32(max(date.timeIntervalSince1970, 0)),
                                             input: Float(input), output: Float(output), cacheWrite: Float(write),
                                             cacheRead: Float(read), cost: Float(cost)))
        }
    }

    private static func scanCodex(_ b: UnsafeBufferPointer<UInt8>, _ file: inout ConnLogFile) {
        ConnBytes.forEachLine(b, containing: [Needle.totalUsage, Needle.model]) { line, hit, which in
            if which == 1 {
                if let m = line.string(line.value(after: Needle.model, from: 0)) { file.model = m }
                return
            }
            let input = line.number(after: Needle.inputTokens, from: hit) ?? 0
            let cached = line.number(after: Needle.cachedInput, from: hit) ?? 0
            let output = line.number(after: Needle.outputTokens, from: hit) ?? 0
            // Totals are cumulative per session; a drop means the counter was reset.
            let reset = input < file.prevInput || output < file.prevOutput
            let dIn = reset ? input : input - file.prevInput
            let dCached = reset ? cached : max(cached - file.prevCached, 0)
            let dOut = reset ? output : output - file.prevOutput
            file.prevInput = input
            file.prevCached = cached
            file.prevOutput = output
            guard dIn + dOut > 0, let ts = line.value(after: Needle.timestamp, from: 0), let date = line.date(ts) else { return }
            let price = ConnPrices.openai(file.model)
            let uncached = max(dIn - dCached, 0)
            let cost = (uncached * price.input + dCached * price.cacheRead + dOut * price.output) / 1_000_000
            file.entries.append(ConnLogEntry(key: 0, time: UInt32(max(date.timeIntervalSince1970, 0)),
                                             input: Float(uncached), output: Float(dOut), cacheWrite: 0,
                                             cacheRead: Float(dCached), cost: Float(cost)))
        }
    }

    static func aggregate(_ files: [String: ConnLogFile], range: ConnRange, now: Date = Date()) -> ConnSnapshot {
        let start = UInt32(max(range.start(now).timeIntervalSince1970, 0))
        var buckets = ConnBuckets(range: range, now: now)
        var tally = ConnTally()
        func add(_ e: ConnLogEntry) {
            tally.input += Double(e.input)
            tally.output += Double(e.output)
            tally.cacheWrite += Double(e.cacheWrite)
            tally.cacheRead += Double(e.cacheRead)
            tally.cost += Double(e.cost)
            tally.calls += 1
            buckets.add(Double(e.input + e.output + e.cacheWrite + e.cacheRead), at: Date(timeIntervalSince1970: TimeInterval(e.time)))
        }
        // Lines of one streamed message share a key but only the last carries the final
        // output_tokens (earlier blocks log a partial count) — keep the largest per key.
        var keyed: [UInt64: ConnLogEntry] = [:]
        for file in files.values {
            for e in file.entries where e.time >= start {
                guard e.key != 0 else { add(e); continue }
                if let kept = keyed[e.key], kept.output >= e.output { continue }
                keyed[e.key] = e
            }
        }
        keyed.values.forEach(add)
        return tally.snapshot(series: buckets, now: now, estimate: true)
    }

    private enum Needle {
        static let usage = Array(#""usage":{"input_tokens":"#.utf8)
        static let timestamp = Array(#""timestamp":""#.utf8)
        static let model = Array(#""model":""#.utf8)
        static let messageID = Array(#""id":"msg_"#.utf8)
        static let requestID = Array(#""requestId":""#.utf8)
        static let inputTokens = Array(#""input_tokens":"#.utf8)
        static let outputTokens = Array(#""output_tokens":"#.utf8)
        static let cacheCreation = Array(#""cache_creation_input_tokens":"#.utf8)
        static let cacheRead = Array(#""cache_read_input_tokens":"#.utf8)
        static let ephemeral1h = Array(#""ephemeral_1h_input_tokens":"#.utf8)
        static let totalUsage = Array(#""total_token_usage":{"#.utf8)
        static let cachedInput = Array(#""cached_input_tokens":"#.utf8)
    }
}

/// FNV-1a 64-bit over id bytes (stable, allocation-free).
private struct ConnFNV {
    var value: UInt64 = 0xcbf2_9ce4_8422_2325
    var used = false
    mutating func add(_ line: ConnLine, _ r: Range<Int>) {
        for i in r {
            value ^= UInt64(line.base[i])
            value = value &* 0x0000_0100_0000_01B3
        }
        value ^= 0x7C // separator
        used = true
    }
}

/// One JSONL line inside a scanned buffer.
private struct ConnLine {
    let base: UnsafePointer<UInt8>
    let count: Int

    func find(_ needle: [UInt8], from: Int) -> Int? {
        guard from < count else { return nil }
        return needle.withUnsafeBytes { n -> Int? in
            guard let hit = memmem(base + from, count - from, n.baseAddress, n.count) else { return nil }
            return base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
        }
    }

    /// Range of the string value that follows `needle` (which ends with an opening quote).
    func value(after needle: [UInt8], from: Int) -> Range<Int>? {
        guard let i = find(needle, from: from) else { return nil }
        let s = i + needle.count
        var e = s
        while e < count, base[e] != 34 { e += 1 }
        return s..<e
    }

    func string(_ r: Range<Int>?) -> String? {
        guard let r, !r.isEmpty, r.count < 200 else { return nil }
        return String(decoding: UnsafeBufferPointer(start: base + r.lowerBound, count: r.count), as: UTF8.self)
    }

    func date(_ r: Range<Int>) -> Date? {
        ConnDate.fastISO(UnsafeBufferPointer(start: base + r.lowerBound, count: r.count))
    }

    func number(after needle: [UInt8], from: Int) -> Double? {
        guard let i = find(needle, from: from) else { return nil }
        var j = i + needle.count
        while j < count, base[j] == 32 { j += 1 }
        var v = 0.0
        var any = false
        while j < count, base[j] >= 48, base[j] <= 57 { v = v * 10 + Double(base[j] - 48); j += 1; any = true }
        return any ? v : nil
    }
}

private enum ConnBytes {
    /// Visits lines (in order) that contain one of `needles`; `which` is the index of the first match.
    static func forEachLine(_ b: UnsafeBufferPointer<UInt8>, containing needles: [[UInt8]], _ body: (ConnLine, Int, Int) -> Void) {
        guard let p = b.baseAddress else { return }
        let n = b.count
        func search(_ k: Int, from pos: Int) -> Int? {
            guard pos < n else { return nil }
            return needles[k].withUnsafeBytes { nb -> Int? in
                guard let h = memmem(p + pos, n - pos, nb.baseAddress, nb.count) else { return nil }
                return p.distance(to: h.assumingMemoryBound(to: UInt8.self))
            }
        }
        // Next hit per needle, recomputed only once we've moved past it (keeps the scan linear).
        var next: [Int?] = needles.indices.map { search($0, from: 0) }
        var pos = 0
        while pos < n {
            var best: (offset: Int, which: Int)?
            for k in needles.indices {
                if let h = next[k], h < pos { next[k] = search(k, from: pos) }
                if let h = next[k], h < (best?.offset ?? .max) { best = (h, k) }
            }
            guard let best else { return }
            var start = best.offset
            while start > 0, p[start - 1] != 10 { start -= 1 }
            let end: Int
            if let nl = memchr(p + best.offset, 10, n - best.offset) {
                end = p.distance(to: nl.assumingMemoryBound(to: UInt8.self))
            } else {
                end = n
            }
            body(ConnLine(base: p + start, count: end - start), best.offset - start, best.which)
            pos = end + 1
        }
    }
}

// MARK: - Admin APIs (Anthropic, OpenAI)

/// HTTP loops here; the per-page parsing (`add…Usage`, `…CostPage`) is pure so fixtures can cover it.
enum ConnAIUsageAPI {
    static func anthropic(key: String, range: ConnRange) async throws -> ConnSnapshot {
        let now = Date()
        let start = range.start(now)
        let headers = ["x-api-key": key, "anthropic-version": "2023-06-01"]
        let width = range == .day ? "1h" : "1d"
        var buckets = ConnBuckets(range: range, now: now)
        var tally = ConnTally()
        var page: String?
        for _ in 0..<6 {
            var query = [("starting_at", ConnDate.isoUTC(start)), ("bucket_width", width), ("limit", range == .day ? "24" : "31"), ("group_by[]", "model")]
            if let page { query.append(("page", page)) }
            let obj = try await ConnHTTP.object(ConnHTTP.url("https://api.anthropic.com/v1/organizations/usage_report/messages", query), headers: headers)
            guard let next = addAnthropicUsage(obj, start: start, tally: &tally, buckets: &buckets) else { break }
            page = next
        }
        var estimate = true
        // Prefer the billed amount when the cost report is available (amounts are decimal cents).
        if let cost = try? await anthropicCost(headers: headers, start: start) {
            tally.cost = cost
            estimate = false
        }
        return tally.snapshot(series: buckets, now: now, estimate: estimate)
    }

    /// Adds one usage-report page to the tally (cost estimated from list prices); returns the next page cursor.
    static func addAnthropicUsage(_ obj: [String: Any], start: Date, tally: inout ConnTally, buckets: inout ConnBuckets) -> String? {
        for bucket in J.array(obj["data"]) {
            let at = ConnDate.parse(bucket["starting_at"]) ?? start
            for r in J.array(bucket["results"]) {
                let input = J.num(r["uncached_input_tokens"]) ?? 0
                let output = J.num(r["output_tokens"]) ?? 0
                let read = J.num(r["cache_read_input_tokens"]) ?? 0
                let w5 = J.num(J.path(r, "cache_creation.ephemeral_5m_input_tokens")) ?? 0
                let w1 = J.num(J.path(r, "cache_creation.ephemeral_1h_input_tokens")) ?? 0
                let price = ConnPrices.claude(J.str(r["model"]) ?? "")
                tally.input += input
                tally.output += output
                tally.cacheRead += read
                tally.cacheWrite += w5 + w1
                tally.cost += (input * price.input + output * price.output + read * price.cacheRead + w5 * price.cacheWrite + w1 * price.input * 2) / 1_000_000
                buckets.add(input + output + read + w5 + w1, at: at)
            }
        }
        return nextPage(obj)
    }

    private static func anthropicCost(headers: [String: String], start: Date) async throws -> Double {
        var total = 0.0
        var page: String?
        for _ in 0..<4 {
            var query = [("starting_at", ConnDate.isoUTC(start)), ("bucket_width", "1d"), ("limit", "31")]
            if let page { query.append(("page", page)) }
            let obj = try await ConnHTTP.object(ConnHTTP.url("https://api.anthropic.com/v1/organizations/cost_report", query), headers: headers)
            let p = anthropicCostPage(obj)
            total += p.dollars
            guard let next = p.next else { break }
            page = next
        }
        return total
    }

    /// Cost-report page → USD (amounts are decimal strings in cents) and the next page cursor.
    static func anthropicCostPage(_ obj: [String: Any]) -> (dollars: Double, next: String?) {
        var total = 0.0
        for bucket in J.array(obj["data"]) {
            for r in J.array(bucket["results"]) { total += (J.num(r["amount"]) ?? 0) / 100 }
        }
        return (total, nextPage(obj))
    }

    static func openai(key: String, range: ConnRange) async throws -> ConnSnapshot {
        let now = Date()
        let start = range.start(now)
        let headers = ConnHTTP.bearer(key)
        let width = range == .day ? "1h" : "1d"
        var buckets = ConnBuckets(range: range, now: now)
        var tally = ConnTally()
        var page: String?
        for _ in 0..<6 {
            var query = [("start_time", String(Int(start.timeIntervalSince1970))), ("bucket_width", width),
                         ("limit", range == .day ? "24" : "31"), ("group_by", "model")]
            if let page { query.append(("page", page)) }
            let obj = try await ConnHTTP.object(ConnHTTP.url("https://api.openai.com/v1/organization/usage/completions", query), headers: headers)
            guard let next = addOpenAIUsage(obj, start: start, tally: &tally, buckets: &buckets) else { break }
            page = next
        }
        var estimate = true
        if let cost = try? await openaiCost(headers: headers, start: start) {
            tally.cost = cost
            estimate = false
        }
        return tally.snapshot(series: buckets, now: now, estimate: estimate)
    }

    /// Adds one completions-usage page; returns the next page cursor. `input_tokens` includes
    /// cached and cache-write tokens, so both are split out of it.
    static func addOpenAIUsage(_ obj: [String: Any], start: Date, tally: inout ConnTally, buckets: inout ConnBuckets) -> String? {
        for bucket in J.array(obj["data"]) {
            let at = ConnDate.parse(bucket["start_time"]) ?? start
            for r in J.array(bucket["results"]) {
                let input = J.num(r["input_tokens"]) ?? 0
                let cached = J.num(r["input_cached_tokens"]) ?? 0
                let written = min(J.num(r["input_cache_write_tokens"]) ?? 0, max(input - cached, 0))
                let output = J.num(r["output_tokens"]) ?? 0
                let price = ConnPrices.openai(J.str(r["model"]) ?? "")
                let uncached = max(input - cached - written, 0)
                tally.input += uncached
                tally.cacheRead += cached
                tally.cacheWrite += written
                tally.output += output
                tally.calls += J.num(r["num_model_requests"]) ?? 0
                tally.cost += (uncached * price.input + cached * price.cacheRead + written * price.cacheWrite + output * price.output) / 1_000_000
                buckets.add(input + output, at: at)
            }
        }
        return nextPage(obj)
    }

    private static func openaiCost(headers: [String: String], start: Date) async throws -> Double {
        var total = 0.0
        var page: String?
        for _ in 0..<4 {
            var query = [("start_time", String(Int(start.timeIntervalSince1970))), ("bucket_width", "1d"), ("limit", "31")]
            if let page { query.append(("page", page)) }
            let obj = try await ConnHTTP.object(ConnHTTP.url("https://api.openai.com/v1/organization/costs", query), headers: headers)
            let p = openaiCostPage(obj)
            total += p.dollars
            guard let next = p.next else { break }
            page = next
        }
        return total
    }

    /// Costs page → USD (`amount.value` is dollars) and the next page cursor.
    static func openaiCostPage(_ obj: [String: Any]) -> (dollars: Double, next: String?) {
        var total = 0.0
        for bucket in J.array(obj["data"]) {
            for r in J.array(bucket["results"]) { total += J.num(J.path(r, "amount.value")) ?? 0 }
        }
        return (total, nextPage(obj))
    }

    /// `has_more` + `next_page` (both APIs share the shape).
    static func nextPage(_ obj: [String: Any]) -> String? {
        guard (obj["has_more"] as? Bool) == true, let next = J.str(obj["next_page"]) else { return nil }
        return next
    }
}
