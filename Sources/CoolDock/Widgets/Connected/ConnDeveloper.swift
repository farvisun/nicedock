import Foundation

private typealias J = ConnJSON

// Each provider splits into `fetch` (HTTP, pagination) and pure parse/summarize functions.

// MARK: - Resend

/// Lists recent emails (newest first) and counts today / this month and the delivered share.
enum ConnResend {
    static let deliveredEvents: Set<String> = ["delivered", "opened", "clicked"]
    static let pendingEvents: Set<String> = ["queued", "scheduled"]

    struct Email: Equatable {
        var date: Date
        var event: String
    }

    static func fetch(token: String, now: Date = Date(), send: ConnSend = ConnHTTP.live) async throws -> ConnSnapshot {
        let month = monthStart(now)
        let headers = ConnHTTP.bearer(token)

        var emails: [Email] = []
        var after: String?
        for _ in 0..<10 {
            var query = [("limit", "100")]
            if let after { query.append(("after", after)) }
            let (data, _) = try await send(ConnHTTP.url("https://api.resend.com/emails", query), headers)
            let p = page(try ConnJSON.object(data))
            emails += p.emails
            let oldest = emails.last?.date ?? now
            guard p.hasMore, oldest >= month, let last = p.lastID else { break }
            after = last
            try Task.checkCancellation()
        }
        return summarize(emails, now: now)
    }

    static func monthStart(_ now: Date) -> Date {
        let cal = ConnDate.calendar
        return cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? cal.startOfDay(for: now)
    }

    /// One `GET /emails` page → emails with a parseable date, `has_more` and the cursor id.
    static func page(_ obj: [String: Any]) -> (emails: [Email], hasMore: Bool, lastID: String?) {
        let items = J.array(obj["data"])
        let emails = items.compactMap { e -> Email? in
            guard let d = ConnDate.parse(e["created_at"]) else { return nil }
            return Email(date: d, event: (J.str(e["last_event"]) ?? "").lowercased())
        }
        return (emails, (obj["has_more"] as? Bool) == true, J.str(items.last?["id"]))
    }

    static func summarize(_ emails: [Email], now: Date) -> ConnSnapshot {
        let cal = ConnDate.calendar
        let today = cal.startOfDay(for: now)
        let month = monthStart(now)
        let thisMonth = emails.filter { $0.date >= month }
        let settled = thisMonth.filter { !pendingEvents.contains($0.event) }
        let delivered = settled.filter { deliveredEvents.contains($0.event) }.count
        let bounced = settled.filter { $0.event == "bounced" || $0.event == "complained" }.count
        let days = (cal.dateComponents([.day], from: month, to: today).day ?? 0) + 1
        var buckets = ConnBuckets(start: month, step: 86_400, count: days)
        thisMonth.forEach { buckets.add(1, at: $0.date) }

        var snap = ConnSnapshot()
        let sentToday = Double(thisMonth.filter { $0.date >= today }.count)
        snap.value = sentToday
        snap.metrics[ConnKey.sentToday] = sentToday
        snap.metrics[ConnKey.sentMonth] = Double(thisMonth.count)
        snap.metrics[ConnKey.deliveredRate] = settled.isEmpty ? nil : Double(delivered) / Double(settled.count)
        snap.metrics[ConnKey.bounced] = Double(bounced)
        snap.series = buckets.values
        snap.seriesStart = month
        snap.seriesStep = 86_400
        return snap
    }
}

// MARK: - GitHub

/// Contribution calendar via GraphQL (token) or, keyless, the public profile calendar
/// (`github.com/users/<user>/contributions`); public events are the last-resort approximation.
enum ConnGitHub {
    /// Days kept for the tile grid and the panel (13 weeks).
    static let days = 91

    static func cleanUser(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "@/"))
    }

    static func fetch(user rawUser: String, token: String?) async throws -> ConnSnapshot {
        let user = cleanUser(rawUser)
        if let token, !token.isEmpty { return try await graphQL(user: user, token: token) }
        guard !user.isEmpty else { throw ConnError(L("Add your GitHub username")) }
        do {
            return try await publicCalendar(user: user)
        } catch let e as Net.HTTPError where e.status == 404 {
            throw ConnError(L("User not found"))
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as URLError where e.code == .cancelled {
            throw e
        } catch {
            // Calendar markup changed or github.com unreachable — approximate from the REST API.
            return try await publicEvents(user: user)
        }
    }

    // MARK: GraphQL (token)

    private static func graphQL(user: String, token: String) async throws -> ConnSnapshot {
        let selection = "contributionsCollection { contributionCalendar { totalContributions weeks { contributionDays { contributionCount date } } } }"
        let query = user.isEmpty
            ? "query { viewer { \(selection) } }"
            : "query($login: String!) { user(login: $login) { \(selection) } }"
        var payload: [String: Any] = ["query": query]
        if !user.isEmpty { payload["variables"] = ["login": user] }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await ConnHTTP.send(URL(string: "https://api.github.com/graphql")!, headers: ConnHTTP.bearer(token), method: "POST", body: body)
        return try parseGraphQL(try ConnJSON.object(data), viewer: user.isEmpty, now: Date(),
                                rateRemaining: response.value(forHTTPHeaderField: "X-RateLimit-Remaining"))
    }

    /// An exhausted GraphQL limit is HTTP 200 + `errors` with `x-ratelimit-remaining: 0`
    /// (https://docs.github.com/en/graphql/overview/rate-limits-and-query-limits-for-the-graphql-api).
    static func parseGraphQL(_ obj: [String: Any], viewer: Bool, now: Date, rateRemaining: String? = nil) throws -> ConnSnapshot {
        let errors = J.array(obj["errors"])
        if !errors.isEmpty, rateRemaining?.trimmingCharacters(in: .whitespaces) == "0" { throw ConnError(L("Rate limited")) }
        if let message = J.str(errors.first?["message"]) { throw ConnError(message) }
        let root = J.dict(J.path(obj, viewer ? "data.viewer" : "data.user"))
        guard let calendar = J.dict(J.path(root, "contributionsCollection.contributionCalendar")) else {
            throw ConnError(L("User not found"))
        }
        var days: [(String, Double)] = []
        for week in J.array(calendar["weeks"]) {
            for day in J.array(week["contributionDays"]) {
                guard let date = J.str(day["date"]) else { continue }
                days.append((date, J.num(day["contributionCount"]) ?? 0))
            }
        }
        var snap = summarize(days: days, now: now)
        snap.metrics[ConnKey.total] = J.num(calendar["totalContributions"])
        return snap
    }

    // MARK: Public calendar (no token)

    private static func publicCalendar(user: String) async throws -> ConnSnapshot {
        let path = user.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? user
        let url = try ConnHTTP.url("https://github.com/users/\(path)/contributions")
        let (data, _) = try await ConnHTTP.send(url, headers: ["Accept": "text/html"])
        return try parseCalendarHTML(String(decoding: data, as: UTF8.self), now: Date())
    }

    /// Profile calendar fragment → same snapshot as the GraphQL path (not an estimate).
    static func parseCalendarHTML(_ html: String, now: Date) throws -> ConnSnapshot {
        let days = calendarDays(html)
        guard !days.isEmpty else { throw ConnError(L("Unexpected response")) }
        var snap = summarize(days: days, now: now)
        snap.metrics[ConnKey.total] = calendarTotal(html) ?? days.map(\.count).reduce(0, +)
        return snap
    }

    /// `(YYYY-MM-DD, count)` per calendar cell. Counts come from the cell's `data-count` (older
    /// markup) or its `<tool-tip for="…">N contributions on …</tool-tip>` label ("No contributions" = 0).
    static func calendarDays(_ html: String) -> [(date: String, count: Double)] {
        var labels: [String: String] = [:]
        for m in html.matches(of: #/<tool-tip\b([^>]*)>([^<]*)</tool-tip>/#) {
            if let target = attribute("for", in: m.output.1) { labels[target] = String(m.output.2) }
        }
        var out: [(date: String, count: Double)] = []
        for m in html.matches(of: #/<(?:td|rect)\b([^>]*)>/#) {
            let attrs = m.output.1
            guard attrs.contains("ContributionCalendar-day"), let date = attribute("data-date", in: attrs), date.count == 10 else { continue }
            if let raw = attribute("data-count", in: attrs), let n = Double(raw) {
                out.append((date, n))
            } else if let id = attribute("id", in: attrs), let label = labels[id] {
                out.append((date, labelCount(label)))
            } else {
                out.append((date, 0))
            }
        }
        return out
    }

    /// "1,234 contributions on …" → 1234; "No contributions on …" → 0.
    static func labelCount(_ label: String) -> Double {
        let digits = label.trimmingCharacters(in: .whitespacesAndNewlines).prefix { $0.isNumber || $0 == "," }
        return Double(digits.replacingOccurrences(of: ",", with: "")) ?? 0
    }

    /// Heading "3,948 contributions in the last year".
    static func calendarTotal(_ html: String) -> Double? {
        guard let m = html.firstMatch(of: #/([\d,]+)\s+contributions?\s+in\s+the\s+last\s+year/#) else { return nil }
        return Double(m.output.1.replacingOccurrences(of: ",", with: ""))
    }

    private static func attribute(_ name: String, in attrs: Substring) -> String? {
        guard let r = attrs.range(of: " \(name)=\"") ?? (attrs.hasPrefix("\(name)=\"") ? attrs.range(of: "\(name)=\"") : nil) else { return nil }
        let rest = attrs[r.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    // MARK: Public events (approximation)

    private static func publicEvents(user: String) async throws -> ConnSnapshot {
        let now = Date()
        var buckets = eventBuckets(now: now)
        let headers = ["Accept": "application/vnd.github+json"]
        let user = user.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? user
        for page in 1...3 {
            let url = try ConnHTTP.url("https://api.github.com/users/\(user)/events", [("per_page", "100"), ("page", String(page))])
            let events = J.array(try await ConnHTTP.json(url, headers: headers))
            addEvents(events, to: &buckets)
            if events.count < 100 { break }
            try Task.checkCancellation()
        }
        return summarizeEvents(buckets, now: now)
    }

    static func eventBuckets(now: Date) -> ConnBuckets {
        let cal = ConnDate.calendar
        let today = cal.startOfDay(for: now)
        let start = cal.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        return ConnBuckets(start: start, step: 86_400, count: days)
    }

    /// Counts commits, opened PRs/issues, reviews and new repositories per local day.
    static func addEvents(_ events: [[String: Any]], to buckets: inout ConnBuckets) {
        for e in events {
            guard let d = ConnDate.parse(e["created_at"]) else { continue }
            let payload = J.dict(e["payload"])
            let action = J.str(payload?["action"]) ?? ""
            switch J.str(e["type"]) ?? "" {
            case "PushEvent":
                buckets.add(max(J.num(payload?["distinct_size"]) ?? J.num(payload?["size"]) ?? 1, 1), at: d)
            case "PullRequestEvent", "IssuesEvent":
                if action == "opened" { buckets.add(1, at: d) }
            case "PullRequestReviewEvent":
                buckets.add(1, at: d)
            case "CreateEvent":
                if J.str(payload?["ref_type"]) == "repository" { buckets.add(1, at: d) }
            default: break
            }
        }
    }

    static func summarizeEvents(_ buckets: ConnBuckets, now: Date) -> ConnSnapshot {
        var snap = summarize(buckets.values, lastDay: ConnDate.calendar.startOfDay(for: now))
        snap.estimate = true
        return snap
    }

    // MARK: Summary

    /// Sorted `(YYYY-MM-DD, count)` days, minus any after "today" (calendars may run to the end of the UTC day).
    static func summarize(days unsorted: [(String, Double)], now: Date) -> ConnSnapshot {
        var days = unsorted.sorted { $0.0 < $1.0 }
        let todayKey = ConnDate.day(now)
        while let last = days.last, last.0 > todayKey { days.removeLast() }
        return summarize(days.map(\.1), lastDay: days.last.flatMap { ConnDate.parse($0.0) } ?? now)
    }

    /// Today / last 7 days / current streak (today may still be empty without breaking it).
    static func summarize(_ counts: [Double], lastDay: Date) -> ConnSnapshot {
        let recent = Array(counts.suffix(days))
        var streak = 0
        var i = recent.count - 1
        if i >= 0, recent[i] == 0 { i -= 1 }
        while i >= 0, recent[i] > 0 { streak += 1; i -= 1 }
        var snap = ConnSnapshot()
        snap.value = recent.last ?? 0
        snap.metrics[ConnKey.today] = recent.last ?? 0
        snap.metrics[ConnKey.week] = recent.suffix(7).reduce(0, +)
        snap.metrics[ConnKey.streak] = Double(streak)
        snap.series = recent
        snap.seriesStart = ConnDate.calendar.date(byAdding: .day, value: -(recent.count - 1), to: ConnDate.calendar.startOfDay(for: lastDay))
        snap.seriesStep = 86_400
        return snap
    }
}

// MARK: - Supabase

/// Management API: project status plus API request counts over the last day.
enum ConnSupabase {
    static func fetch(project: String, token: String) async throws -> ConnSnapshot {
        let ref = project.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ref.isEmpty else { throw ConnError(L("Add your project ref")) }
        let headers = ConnHTTP.bearer(token)
        let projectURL = try ConnHTTP.url("https://api.supabase.com/v1/projects/\(ref)")
        let usageURL = try ConnHTTP.url("https://api.supabase.com/v1/projects/\(ref)/analytics/endpoints/usage.api-counts", [("interval", "1day")])
        async let projectObj = ConnHTTP.object(projectURL, headers: headers)
        async let usageObj = ConnHTTP.json(usageURL, headers: headers)

        let p = try await projectObj
        return parse(project: p, usage: try? await usageObj)
    }

    static func parse(project p: [String: Any], usage: Any?) -> ConnSnapshot {
        var snap = ConnSnapshot()
        snap.text[ConnKey.status] = J.str(p["status"]) ?? "UNKNOWN"
        snap.text[ConnKey.name] = J.str(p["name"])
        snap.text[ConnKey.region] = J.str(p["region"])

        if let usage, let rows = J.findArray(usage, keys: ["result", "data"]) {
            var rest = 0.0, auth = 0.0, storage = 0.0, realtime = 0.0
            var points: [(Date, Double)] = []
            for row in rows {
                let r = J.num(row["total_rest_requests"]) ?? 0
                let a = J.num(row["total_auth_requests"]) ?? 0
                let s = J.num(row["total_storage_requests"]) ?? 0
                let t = J.num(row["total_realtime_requests"]) ?? 0
                var sum = r + a + s + t
                if sum == 0 {
                    // Unknown column names — add every "*requests*" number.
                    sum = row.filter { $0.key.lowercased().contains("request") }.compactMap { J.num($0.value) }.reduce(0, +)
                }
                rest += r; auth += a; storage += s; realtime += t
                points.append((ConnDate.parse(row["timestamp"]) ?? .distantPast, sum))
            }
            points.sort { $0.0 < $1.0 }
            let total = points.map(\.1).reduce(0, +)
            snap.value = total
            snap.metrics[ConnKey.requests] = total
            snap.metrics[ConnKey.restRequests] = rest
            snap.metrics[ConnKey.authRequests] = auth
            snap.metrics[ConnKey.storageRequests] = storage
            snap.metrics[ConnKey.realtimeRequests] = realtime
            snap.series = points.map(\.1)
            snap.seriesStart = points.first.map(\.0).flatMap { $0 == .distantPast ? nil : $0 }
            if points.count > 1, points[0].0 != .distantPast {
                snap.seriesStep = points[1].0.timeIntervalSince(points[0].0)
            } else {
                snap.seriesStep = 3600
            }
        }
        return snap
    }

    enum Health { case healthy, starting, paused, failing }

    static func health(_ status: String?) -> Health {
        switch (status ?? "").uppercased() {
        case "ACTIVE_HEALTHY": return .healthy
        case "COMING_UP", "RESTORING", "UPGRADING", "PAUSING", "RESIZING", "RESTARTING", "GOING_DOWN", "INIT": return .starting
        case "INACTIVE", "PAUSED": return .paused
        default: return .failing
        }
    }
}
