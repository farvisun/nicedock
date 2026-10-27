import Foundation

private typealias J = ConnJSON

// Each provider splits into `fetch` (HTTP) and a pure `parse` (decoded JSON in, snapshot out).

func connCleanSite(_ raw: String) -> String {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    for prefix in ["https://", "http://"] where s.lowercased().hasPrefix(prefix) { s.removeFirst(prefix.count) }
    return s.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
}

// MARK: - Plausible (also powers the Visitors Chart)

enum ConnPlausible {
    static func host(_ w: WidgetInstance) -> String {
        var h = w.string("host", "https://plausible.io").trimmingCharacters(in: .whitespacesAndNewlines)
        if h.isEmpty { h = "https://plausible.io" }
        if !h.lowercased().hasPrefix("http") { h = "https://" + h }
        while h.hasSuffix("/") { h.removeLast() }
        return h
    }

    static func period(_ range: ConnRange) -> String { range == .day ? "day" : range.rawValue }

    static func fetch(host: String, site: String, token: String, range: ConnRange) async throws -> ConnSnapshot {
        let site = connCleanSite(site)
        let period = period(range)
        let headers = ConnHTTP.bearer(token)
        let aggURL = try ConnHTTP.url("\(host)/api/v1/stats/aggregate", [("site_id", site), ("period", period), ("metrics", "visitors,pageviews")])
        let tsURL = try ConnHTTP.url("\(host)/api/v1/stats/timeseries", [("site_id", site), ("period", period), ("metrics", "visitors")])
        async let aggregate = ConnHTTP.object(aggURL, headers: headers)
        async let timeseries = ConnHTTP.object(tsURL, headers: headers)

        let agg = try await aggregate
        return try parse(aggregate: agg, timeseries: try? await timeseries, range: range, now: Date())
    }

    /// `aggregate` → visitors / pageviews; `timeseries` (optional) → chart. "Today" keeps hours up to now.
    static func parse(aggregate agg: [String: Any], timeseries: [String: Any]?, range: ConnRange, now: Date) throws -> ConnSnapshot {
        guard let visitors = J.num(J.path(agg, "results.visitors.value")) else { throw ConnError(L("Unexpected response")) }
        var series = timeseries.map { J.array($0["results"]).map { J.num($0["visitors"]) ?? 0 } } ?? []
        if range == .day {
            let hour = ConnDate.calendar.component(.hour, from: now)
            series = Array(series.prefix(max(hour + 1, 2)))
        }
        var snap = ConnSnapshot()
        snap.value = visitors
        snap.metrics[ConnKey.pageviews] = J.num(J.path(agg, "results.pageviews.value"))
        snap.series = series
        snap.seriesStart = range.start(now)
        snap.seriesStep = range.step
        return snap
    }
}

// MARK: - Simple Analytics

/// Stats JSON API. Public sites need no key; private ones take an `Api-Key`.
enum ConnSimpleAnalytics {
    static func request(site: String, range: ConnRange, now: Date) throws -> URL {
        try ConnHTTP.url("https://simpleanalytics.com/\(connCleanSite(site)).json", [
            ("version", "6"), ("fields", "pageviews,visitors,histogram"),
            ("start", ConnDate.day(range.start(now))), ("end", "today"), ("timezone", TimeZone.current.identifier)
        ])
    }

    static func fetch(site: String, token: String?, range: ConnRange) async throws -> ConnSnapshot {
        let now = Date()
        let key = (token ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let obj: [String: Any]
        do {
            obj = try await ConnHTTP.object(request(site: site, range: range, now: now), headers: key.isEmpty ? [:] : ["Api-Key": key])
        } catch let e as Net.HTTPError where key.isEmpty && [401, 403, 404].contains(e.status) {
            // Without a key only public sites resolve; anything else needs one.
            throw ConnError(L("Add your API token"))
        }
        return try parse(obj, start: range.start(now))
    }

    static func parse(_ obj: [String: Any], start: Date) throws -> ConnSnapshot {
        if let message = J.str(obj["error"]) ?? J.str(J.path(obj, "error.message")) { throw ConnError(message) }
        guard let visitors = J.num(obj["visitors"]) else { throw ConnError(L("Unexpected response")) }
        var snap = ConnSnapshot()
        snap.value = visitors
        snap.metrics[ConnKey.pageviews] = J.num(obj["pageviews"])
        snap.series = J.array(obj["histogram"]).map { J.num($0["visitors"]) ?? 0 }
        snap.seriesStart = start
        snap.seriesStep = 86_400
        return snap
    }
}

// MARK: - DataFast

/// Schema is young and may change — read visitors/revenue defensively.
enum ConnDataFast {
    static func fetch(token: String, range: ConnRange) async throws -> ConnSnapshot {
        let now = Date()
        let start = range.start(now)
        let headers = ConnHTTP.bearer(token)
        let window = [("startAt", ConnDate.iso(start)), ("endAt", ConnDate.iso(now)), ("timezone", TimeZone.current.identifier)]
        let overviewURL = try ConnHTTP.url("https://datafa.st/api/v1/analytics/overview", window)
        let seriesURL = try ConnHTTP.url("https://datafa.st/api/v1/analytics/timeseries", window + [("interval", range == .day ? "hour" : "day"), ("fields", "visitors")])
        async let overview = ConnHTTP.json(overviewURL, headers: headers)
        async let timeseries = ConnHTTP.json(seriesURL, headers: headers)

        let obj = try await overview
        return try parse(overview: obj, timeseries: try? await timeseries, range: range, now: now)
    }

    static func parse(overview obj: Any, timeseries ts: Any?, range: ConnRange, now: Date) throws -> ConnSnapshot {
        guard let visitors = J.findNumber(obj, keys: ["visitors", "uniqueVisitors", "unique_visitors", "visitorCount"]) else {
            throw ConnError(L("Unexpected response"))
        }
        var snap = ConnSnapshot()
        snap.value = visitors
        snap.metrics[ConnKey.revenue] = J.findNumber(obj, keys: ["revenue", "totalRevenue", "total_revenue"])
        snap.metrics[ConnKey.sessions] = J.findNumber(obj, keys: ["sessions", "totalSessions"])
        snap.metrics[ConnKey.pageviews] = J.findNumber(obj, keys: ["pageviews", "pageViews", "page_views"])
        // Overview nests its row in `data: [{…, currency}]`; time series keeps `currency` on top.
        let row = J.array(J.dict(obj)?["data"]).first
        snap.currency = (J.dict(obj).flatMap { J.str($0["currency"]) } ?? J.str(J.path(obj, "data.currency")) ?? J.str(row?["currency"]))?.uppercased()
        if let ts, let points = J.findArray(ts, keys: ["data", "timeseries", "results", "series"]) {
            snap.series = points.map { J.num($0["visitors"]) ?? J.num($0["value"]) ?? 0 }
        }
        snap.seriesStart = range.start(now)
        snap.seriesStep = range.step
        return snap
    }
}

// MARK: - Dub

enum ConnDub {
    static func fetch(token: String, range: ConnRange) async throws -> ConnSnapshot {
        let interval = range == .day ? "24h" : range.rawValue
        let headers = ConnHTTP.bearer(token)
        let base = [("event", "composite"), ("interval", interval), ("timezone", TimeZone.current.identifier)]
        let countURL = try ConnHTTP.url("https://api.dub.co/analytics", base + [("groupBy", "count")])
        let seriesURL = try ConnHTTP.url("https://api.dub.co/analytics", base + [("groupBy", "timeseries")])
        async let counts = ConnHTTP.json(countURL, headers: headers)
        async let timeseries = ConnHTTP.json(seriesURL, headers: headers)

        let c = try await counts
        return parse(counts: c, timeseries: try? await timeseries, range: range)
    }

    /// `groupBy=count` object (or one-element array) + optional `groupBy=timeseries` rows.
    static func parse(counts c: Any, timeseries ts: Any?, range: ConnRange) -> ConnSnapshot {
        let totals = (c as? [String: Any]) ?? (c as? [[String: Any]])?.first ?? [:]
        var snap = ConnSnapshot()
        let clicks = J.num(totals["clicks"]) ?? 0
        snap.value = clicks
        snap.metrics[ConnKey.clicks] = clicks
        snap.metrics[ConnKey.leads] = J.num(totals["leads"]) ?? 0
        snap.metrics[ConnKey.sales] = J.num(totals["sales"]) ?? 0
        if let amount = J.num(totals["saleAmount"]) { snap.metrics[ConnKey.saleAmount] = amount / 100 }
        snap.currency = "USD"
        if let ts {
            let points = J.array(ts)
            snap.series = points.map { J.num($0["clicks"]) ?? 0 }
            snap.seriesStart = points.first.flatMap { ConnDate.parse($0["start"]) }
        }
        snap.seriesStep = range == .day ? 3600 : 86_400
        return snap
    }
}
