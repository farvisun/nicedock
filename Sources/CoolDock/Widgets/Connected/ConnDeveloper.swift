import Foundation

private typealias J = ConnJSON

// MARK: - Resend

/// Lists recent emails (newest first) and counts today / this month and the delivered share.
enum ConnResend {
    private static let deliveredEvents: Set<String> = ["delivered", "opened", "clicked"]
    private static let pendingEvents: Set<String> = ["queued", "scheduled"]

    static func fetch(token: String) async throws -> ConnSnapshot {
        let cal = ConnDate.calendar
        let now = Date()
        let today = cal.startOfDay(for: now)
        let month = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? today
        let headers = ConnHTTP.bearer(token)

        var emails: [(date: Date, event: String)] = []
        var after: String?
        for _ in 0..<10 {
            var query = [("limit", "100")]
            if let after { query.append(("after", after)) }
            let obj = try await ConnHTTP.object(ConnHTTP.url("https://api.resend.com/emails", query), headers: headers)
            let page = J.array(obj["data"])
            for e in page {
                guard let d = ConnDate.parse(e["created_at"]) else { continue }
                emails.append((d, (J.str(e["last_event"]) ?? "").lowercased()))
            }
            let oldest = emails.last?.date ?? now
            guard (obj["has_more"] as? Bool) == true, oldest >= month, let last = J.str(page.last?["id"]) else { break }
            after = last
            try Task.checkCancellation()
        }

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

/// Contribution calendar via GraphQL (token) or an approximation from public events (no token).
enum ConnGitHub {
    /// Days kept for the tile grid and the panel (13 weeks).
    static let days = 91

    static func fetch(user rawUser: String, token: String?) async throws -> ConnSnapshot {
        let user = rawUser.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "@/"))
        if let token, !token.isEmpty { return try await graphQL(user: user, token: token) }
        guard !user.isEmpty else { throw ConnError(L("Add your GitHub username")) }
        return try await publicEvents(user: user)
    }

    private static func graphQL(user: String, token: String) async throws -> ConnSnapshot {
        let selection = "contributionsCollection { contributionCalendar { totalContributions weeks { contributionDays { contributionCount date } } } }"
        let query = user.isEmpty
            ? "query { viewer { \(selection) } }"
            : "query($login: String!) { user(login: $login) { \(selection) } }"
        var payload: [String: Any] = ["query": query]
        if !user.isEmpty { payload["variables"] = ["login": user] }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let obj = try await ConnHTTP.object(URL(string: "https://api.github.com/graphql")!, headers: ConnHTTP.bearer(token), method: "POST", body: body)
        if let message = J.str(J.array(obj["errors"]).first?["message"]) { throw ConnError(message) }
        let root = J.dict(J.path(obj, user.isEmpty ? "data.viewer" : "data.user"))
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
        days.sort { $0.0 < $1.0 }
        // Drop days after "today" (calendar may run to the end of the UTC day).
        let todayKey = ConnDate.day(Date())
        while let last = days.last, last.0 > todayKey { days.removeLast() }
        var snap = summarize(days.map(\.1), lastDay: days.last.flatMap { ConnDate.parse($0.0) } ?? Date())
        snap.metrics[ConnKey.total] = J.num(calendar["totalContributions"])
        return snap
    }

    private static func publicEvents(user: String) async throws -> ConnSnapshot {
        let cal = ConnDate.calendar
        let today = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        var buckets = ConnBuckets(start: start, step: 86_400, count: days)
        let headers = ["Accept": "application/vnd.github+json"]
        let user = user.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? user
        for page in 1...3 {
            let url = try ConnHTTP.url("https://api.github.com/users/\(user)/events", [("per_page", "100"), ("page", String(page))])
            let events = J.array(try await ConnHTTP.json(url, headers: headers))
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
            if events.count < 100 { break }
            try Task.checkCancellation()
        }
        var snap = summarize(buckets.values, lastDay: today)
        snap.estimate = true
        return snap
    }

    /// Today / last 7 days / current streak (today may still be empty without breaking it).
    private static func summarize(_ counts: [Double], lastDay: Date) -> ConnSnapshot {
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
        var snap = ConnSnapshot()
        snap.text[ConnKey.status] = J.str(p["status"]) ?? "UNKNOWN"
        snap.text[ConnKey.name] = J.str(p["name"])
        snap.text[ConnKey.region] = J.str(p["region"])

        if let usage = try? await usageObj, let rows = J.findArray(usage, keys: ["result", "data"]) {
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
