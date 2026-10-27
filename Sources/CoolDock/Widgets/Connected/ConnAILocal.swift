import Foundation
import SQLite3

private typealias J = ConnJSON

// MARK: - OpenCode (local SQLite + legacy JSON)

/// One assistant message with token usage, as OpenCode records it (`tokens.input` excludes cached input;
/// `reasoning` is billed as output; `cost` is OpenCode's own list-price figure, 0 for free/subscription models).
struct ConnOpenCodeMessage: Equatable, Sendable {
    var id: String
    var time: Double            // unix milliseconds
    var input = 0.0, output = 0.0, reasoning = 0.0, cacheRead = 0.0, cacheWrite = 0.0, cost = 0.0
}

/// OpenCode keeps sessions in `~/.local/share/opencode/opencode.db` (https://opencode.ai/docs/troubleshooting#storage).
/// Two generations live side by side: `message` (role + tokens in `data`) and the newer `session_message`
/// (`type = 'assistant'`); migrated rows keep their id in both, so rows are merged by id. Installs from before the
/// database read `storage/message/<session>/<message>.json`. Everything is opened read-only.
enum ConnOpenCode {
    static func roots() -> [URL] {
        let env = ProcessInfo.processInfo.environment
        var dirs: [URL] = []
        if let xdg = env["XDG_DATA_HOME"], !xdg.isEmpty {
            dirs.append(URL(fileURLWithPath: (xdg as NSString).expandingTildeInPath).appendingPathComponent("opencode", isDirectory: true))
        }
        dirs.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/opencode", isDirectory: true))
        var seen = Set<String>()
        return dirs.filter { FileManager.default.fileExists(atPath: $0.path) && seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// `opencode.db` plus channel databases (`opencode-<channel>.db`) and an explicit `OPENCODE_DB`.
    static func databases(in dir: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var out = names.filter { $0.hasPrefix("opencode") && $0.hasSuffix(".db") }.sorted().map { dir.appendingPathComponent($0) }
        if let custom = ProcessInfo.processInfo.environment["OPENCODE_DB"], !custom.isEmpty {
            let url = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, relativeTo: dir)
            if FileManager.default.fileExists(atPath: url.path), !out.contains(url) { out.append(url) }
        }
        return out
    }

    /// Assistant messages created at or after `since`, keyed by message id.
    static func scan(roots custom: [URL]? = nil, since: Date) throws -> [String: ConnOpenCodeMessage] {
        let roots = custom ?? roots()
        guard !roots.isEmpty else { throw ConnError(L("No OpenCode data found")) }
        let sinceMS = since.timeIntervalSince1970 * 1000
        var out: [String: ConnOpenCodeMessage] = [:]
        for root in roots {
            var sawDatabase = false
            for db in databases(in: root) {
                guard let rows = try? readDatabase(db, sinceMS: sinceMS) else { continue }
                sawDatabase = true
                for row in rows where out[row.id] == nil { out[row.id] = row }
            }
            // Pre-database installs (the JSON files are migrated into the database, then left behind).
            if !sawDatabase {
                for row in readLegacy(root.appendingPathComponent("storage/message", isDirectory: true), sinceMS: sinceMS) where out[row.id] == nil {
                    out[row.id] = row
                }
            }
        }
        return out
    }

    static func readDatabase(_ url: URL, sinceMS: Double) throws -> [ConnOpenCodeMessage] {
        let db = try ConnSQLite(readOnly: url)
        let tables = db.tables()
        let fields = "id, time_created, json_extract(data,'$.tokens.input'), json_extract(data,'$.tokens.output'), json_extract(data,'$.tokens.reasoning'), json_extract(data,'$.tokens.cache.read'), json_extract(data,'$.tokens.cache.write'), json_extract(data,'$.cost')"
        var out: [ConnOpenCodeMessage] = []
        var ids = Set<String>()
        func collect(_ sql: String) throws {
            try db.each(sql, int64: Int64(sinceMS)) { s in
                guard let id = ConnSQLite.text(s, 0), ids.insert(id).inserted else { return }
                var m = ConnOpenCodeMessage(id: id, time: sqlite3_column_double(s, 1))
                m.input = sqlite3_column_double(s, 2)
                m.output = sqlite3_column_double(s, 3)
                m.reasoning = sqlite3_column_double(s, 4)
                m.cacheRead = sqlite3_column_double(s, 5)
                m.cacheWrite = sqlite3_column_double(s, 6)
                m.cost = sqlite3_column_double(s, 7)
                out.append(m)
            }
        }
        if tables.contains("session_message") {
            try collect("SELECT \(fields) FROM session_message WHERE type = 'assistant' AND time_created >= ?1")
        }
        if tables.contains("message") {
            try collect("SELECT \(fields) FROM message WHERE time_created >= ?1 AND json_extract(data,'$.role') = 'assistant'")
        }
        return out
    }

    static func readLegacy(_ dir: URL, sinceMS: Double) -> [ConnOpenCodeMessage] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return [] }
        let since = Date(timeIntervalSince1970: sinceMS / 1000)
        var out: [ConnOpenCodeMessage] = []
        for case let url as URL in walker where url.pathExtension == "json" {
            if let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, mtime < since { continue }
            guard let data = try? Data(contentsOf: url), let obj = try? ConnJSON.object(data), let m = legacyMessage(obj, fallbackID: url.deletingPathExtension().lastPathComponent),
                  m.time >= sinceMS else { continue }
            out.append(m)
        }
        return out
    }

    /// `{"id","role":"assistant","time":{"created"},"cost","tokens":{"input","output","reasoning","cache":{"read","write"}}}`
    static func legacyMessage(_ obj: [String: Any], fallbackID: String) -> ConnOpenCodeMessage? {
        guard J.str(obj["role"]) == "assistant", let created = J.num(J.path(obj, "time.created")) else { return nil }
        var m = ConnOpenCodeMessage(id: J.str(obj["id"]) ?? fallbackID, time: created)
        m.input = J.num(J.path(obj, "tokens.input")) ?? 0
        m.output = J.num(J.path(obj, "tokens.output")) ?? 0
        m.reasoning = J.num(J.path(obj, "tokens.reasoning")) ?? 0
        m.cacheRead = J.num(J.path(obj, "tokens.cache.read")) ?? 0
        m.cacheWrite = J.num(J.path(obj, "tokens.cache.write")) ?? 0
        m.cost = J.num(obj["cost"]) ?? 0
        return m
    }

    static func aggregate(_ rows: [String: ConnOpenCodeMessage], range: ConnRange, now: Date = Date()) -> ConnSnapshot {
        let start = range.start(now).timeIntervalSince1970 * 1000
        let end = now.addingTimeInterval(3600).timeIntervalSince1970 * 1000  // tolerate small clock skew, not later days
        var buckets = ConnBuckets(range: range, now: now)
        var tally = ConnTally()
        for m in rows.values where m.time >= start && m.time <= end {
            tally.input += m.input
            tally.output += m.output + m.reasoning
            tally.cacheRead += m.cacheRead
            tally.cacheWrite += m.cacheWrite
            tally.cost += m.cost
            tally.calls += 1
            buckets.add(m.input + m.output + m.reasoning + m.cacheRead + m.cacheWrite, at: Date(timeIntervalSince1970: m.time / 1000))
        }
        return tally.snapshot(series: buckets, now: now, estimate: true)
    }
}

/// Minimal read-only SQLite access (system libsqlite3, JSON1 built in).
final class ConnSQLite {
    private let db: OpaquePointer

    /// Opens read-only; if that fails (e.g. a WAL database whose `-shm` can't be created), retries `immutable=1`.
    init(readOnly url: URL) throws {
        var handle: OpaquePointer?
        if sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let h = handle,
           sqlite3_exec(h, "SELECT count(*) FROM sqlite_master", nil, nil, nil) == SQLITE_OK {
            db = h
        } else {
            sqlite3_close(handle)
            handle = nil
            var comps = URLComponents()
            comps.scheme = "file"
            comps.path = url.path
            comps.queryItems = [URLQueryItem(name: "immutable", value: "1")]
            guard let uri = comps.string,
                  sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let h = handle else {
                sqlite3_close(handle)
                throw ConnError(L("Unexpected response"))
            }
            db = h
        }
        sqlite3_busy_timeout(db, 2000)
    }

    deinit { sqlite3_close(db) }

    func tables() -> Set<String> {
        var out = Set<String>()
        try? each("SELECT name FROM sqlite_master WHERE type = 'table'", int64: nil) { s in
            if let name = Self.text(s, 0) { out.insert(name) }
        }
        return out
    }

    func each(_ sql: String, int64: Int64?, _ row: (OpaquePointer) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            sqlite3_finalize(stmt)
            throw ConnError(L("Unexpected response"))
        }
        defer { sqlite3_finalize(s) }
        if let int64 { sqlite3_bind_int64(s, 1, int64) }
        while true {
            let rc = sqlite3_step(s)
            if rc == SQLITE_ROW { row(s); continue }
            if rc == SQLITE_DONE { return }
            throw ConnError(L("Unexpected response"))
        }
    }

    static func text(_ s: OpaquePointer, _ column: Int32) -> String? {
        guard let p = sqlite3_column_text(s, column) else { return nil }
        return String(cString: p)
    }
}

// MARK: - Antigravity (agy CLI usage report)

/// Antigravity has no usage API. Its CLI documents a read-only `/usage` report (https://antigravity.google/docs/cli/commands/usage)
/// that print mode emits as a structured payload (`agy -p "/usage" --output-format json`, changelog). No model prompt is
/// sent; the report lists the plan's quota buckets per model group with the remaining fraction and reset time.
enum ConnAntigravity {
    static func executable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/agy", "/opt/homebrew/bin/agy", "/usr/local/bin/agy", "\(home)/.antigravity/bin/agy"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    static func fetch(now: Date = Date()) async throws -> ConnSnapshot {
        guard let agy = executable() else { throw ConnError(L("Antigravity CLI not found")) }
        let out = try await ConnCLI.run(agy, ["-p", "/usage", "--output-format", "json", "--print-timeout", "60s"],
                                        env: ["AGY_CLI_DISABLE_AUTO_UPDATE": "true"], timeout: 90)
        guard let obj = try? ConnJSON.object(out) else { throw ConnError(L("Unexpected response")) }
        return try parseReport(obj, now: now)
    }

    /// `{"status":"SUCCESS","command":{"name":"usage","data":{"groups":[{"name","buckets":[{"name","window",
    /// "remaining_fraction","reset_time"}]}]}}}` → the tightest bucket as the headline, every bucket for the panel.
    static func parseReport(_ obj: [String: Any], now: Date = Date()) throws -> ConnSnapshot {
        if let status = J.str(obj["status"]), status != "SUCCESS" {
            let text = (J.str(obj["response"]) ?? "") + " " + (J.str(obj["error"]) ?? "")
            if text.localizedCaseInsensitiveContains("sign in") || text.localizedCaseInsensitiveContains("login") || text.localizedCaseInsensitiveContains("auth") {
                throw ConnError(L("Sign in to Antigravity"))
            }
            throw ConnError(L("Unexpected response"))
        }
        var rows: [(group: String, window: String, remaining: Double, reset: Date?)] = []
        for group in J.array(J.path(obj, "command.data.groups")) {
            let groupName = J.str(group["name"]) ?? ""
            for bucket in J.array(group["buckets"]) {
                guard let remaining = J.num(bucket["remaining_fraction"]) else { continue }
                let window = J.str(bucket["window"]) ?? J.str(bucket["name"]) ?? ""
                rows.append((groupName, window, min(max(remaining, 0), 1), ConnDate.parse(bucket["reset_time"])))
            }
        }
        guard let tightest = rows.min(by: { $0.remaining < $1.remaining }) else { throw ConnError(L("No usage data")) }
        var snap = ConnSnapshot()
        snap.value = tightest.remaining
        snap.text[ConnKey.unit] = ConnAIUnit.quota.rawValue
        snap.text[ConnKey.name] = tightest.group
        snap.text[ConnKey.window] = tightest.window
        if let reset = tightest.reset { snap.text[ConnKey.reset] = ConnDate.isoUTC(reset) }
        for (i, row) in rows.prefix(6).enumerated() {
            snap.text["quota.\(i)"] = [row.group, row.window].filter { !$0.isEmpty }.joined(separator: " · ")
            snap.metrics["quota.\(i)"] = row.remaining
        }
        snap.seriesStep = 0
        return snap
    }
}

// MARK: - CLI runner (Antigravity, gcloud)

/// Runs a user-installed CLI without a shell: minimal environment, private working directory, `open`/`xdg-open` shims that
/// fail (so a lapsed login can't pop a browser), stdout capped at 1 MB, terminated on timeout or cancellation.
/// Never used while rendering.
enum ConnCLI {
    static func run(_ exe: URL, _ args: [String], env extra: [String: String] = [:], timeout: TimeInterval) async throws -> Data {
        if ConnEnv.isRendering { throw ConnError(L("Offline")) }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("cooldock-cli-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for shim in ["open", "xdg-open"] {
            let url = dir.appendingPathComponent(shim)
            try Data("#!/bin/sh\nexit 1\n".utf8).write(to: url)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        defer { try? fm.removeItem(at: dir) }

        let process = Process()
        process.executableURL = exe
        process.arguments = args
        process.currentDirectoryURL = dir
        var env = ["HOME": fm.homeDirectoryForCurrentUser.path,
                   "PATH": "\(dir.path):\(exe.deletingLastPathComponent().path):/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
                   "TMPDIR": NSTemporaryDirectory(), "LANG": "en_US.UTF-8", "BROWSER": dir.appendingPathComponent("open").path,
                   "NO_COLOR": "1", "TERM": "dumb", "CI": "1"]
        env.merge(extra) { $1 }
        process.environment = env
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let box = ConnCLIOutput()
        stdout.fileHandleForReading.readabilityHandler = { h in box.append(h.availableData) }
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { p in cont.resume(returning: p.terminationStatus) }
                do { try process.run() } catch {
                    process.terminationHandler = nil
                    cont.resume(throwing: ConnError(L("Request failed")))
                    return
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { if process.isRunning { process.terminate() } }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        // Children (MCP servers) may keep the pipe open; take what arrived and stop listening.
        try? await Task.sleep(for: .milliseconds(150))
        stdout.fileHandleForReading.readabilityHandler = nil
        try Task.checkCancellation()
        let data = box.data
        guard status == 0 || !data.isEmpty else { throw ConnError(L("Request failed")) }
        return data
    }

    /// `gcloud auth print-access-token` for the signed-in account (Cloud Monitoring needs OAuth, not an API key).
    static func gcloudToken() async throws -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["/opt/homebrew/bin/gcloud", "/usr/local/bin/gcloud", "\(home)/google-cloud-sdk/bin/gcloud",
                          "/opt/homebrew/share/google-cloud-sdk/bin/gcloud", "/usr/local/share/google-cloud-sdk/bin/gcloud"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw ConnError(L("Add your API token"))
        }
        let data = try await run(URL(fileURLWithPath: path), ["auth", "print-access-token", "--quiet"], timeout: 30)
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.hasPrefix("ya29.") || (token.count > 20 && !token.contains(" ")) else { throw ConnError(L("Check your token")) }
        return token
    }
}

private final class ConnCLIOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        if buffer.count < 1_000_000 { buffer.append(chunk.prefix(1_000_000 - buffer.count)) }
    }

    var data: Data {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }
}
