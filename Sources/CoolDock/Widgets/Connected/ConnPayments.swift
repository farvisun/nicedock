import Foundation

private typealias J = ConnJSON

// Each provider splits into `fetch` (HTTP, pagination) and pure `parse`/`summarize` functions
// (decoded JSON in, `ConnSnapshot` out) so the parsing is covered by fixture tests.

// MARK: - Polar

/// GET /v1/metrics — `periods[].revenue` (cents, USD) plus `totals`.
enum ConnPolar {
    static func request(range: ConnRange, now: Date) throws -> URL {
        try ConnHTTP.url("https://api.polar.sh/v1/metrics/", [
            ("start_date", ConnDate.day(range.start(now))), ("end_date", ConnDate.day(now)),
            ("interval", range == .day ? "hour" : "day"), ("timezone", TimeZone.current.identifier)
        ])
    }

    static func fetch(token: String, range: ConnRange) async throws -> ConnSnapshot {
        let now = Date()
        let obj = try await ConnHTTP.object(request(range: range, now: now), headers: ConnHTTP.bearer(token))
        return parse(obj, range: range, now: now)
    }

    static func parse(_ obj: [String: Any], range: ConnRange, now: Date) -> ConnSnapshot {
        func revenue(_ d: [String: Any]?) -> Double? { J.num(d?["net_revenue"]) ?? J.num(d?["revenue"]) }

        var buckets = ConnBuckets(range: range, now: now)
        var sum = 0.0
        var orders = 0.0
        for period in J.array(obj["periods"]) {
            let cents = revenue(period) ?? 0
            sum += cents
            orders += J.num(period["orders"]) ?? 0
            if let d = ConnDate.parse(period["timestamp"]) { buckets.add(cents / 100, at: d) }
        }
        let totals = J.dict(obj["totals"])
        var snap = ConnSnapshot()
        snap.value = (revenue(totals) ?? sum) / 100
        snap.currency = "USD"
        snap.metrics[ConnKey.orders] = J.num(totals?["orders"]) ?? orders
        snap.series = buckets.trimmed(now: now)
        snap.seriesStart = buckets.start
        snap.seriesStep = buckets.step
        return snap
    }
}

// MARK: - Stripe

/// Balance transactions since the range start; net of fees and refunds in the dominant currency.
enum ConnStripe {
    /// Sales, their refunds and the reversals of those (a failed refund returns the funds).
    static let revenueTypes: Set<String> = ["charge", "payment", "refund", "payment_refund", "payment_failure_refund",
                                            "refund_failure", "payment_reversal"]

    static func fetch(token: String, range: ConnRange, now: Date = Date(), send: ConnSend = ConnHTTP.live) async throws -> ConnSnapshot {
        let start = range.start(now)
        var items: [[String: Any]] = []
        var after: String?
        for _ in 0..<10 {
            var query = [("created[gte]", String(Int(start.timeIntervalSince1970))), ("limit", "100")]
            if let after { query.append(("starting_after", after)) }
            let (data, _) = try await send(ConnHTTP.url("https://api.stripe.com/v1/balance_transactions", query), ConnHTTP.bearer(token))
            let p = page(try ConnJSON.object(data))
            items += p.items
            guard let next = p.next else { break }
            after = next
            try Task.checkCancellation()
        }
        return parse(items, range: range, now: now)
    }

    /// One list page → its items and the `starting_after` cursor for the next page (nil = last page).
    static func page(_ obj: [String: Any]) -> (items: [[String: Any]], next: String?) {
        let items = J.array(obj["data"])
        guard (obj["has_more"] as? Bool) == true, let last = J.str(items.last?["id"]) else { return (items, nil) }
        return (items, last)
    }

    static func parse(_ items: [[String: Any]], range: ConnRange, now: Date) -> ConnSnapshot {
        let relevant = items.filter { revenueTypes.contains(J.str($0["type"]) ?? "") }
        var counts: [String: Int] = [:]
        for item in relevant { counts[(J.str(item["currency"]) ?? "usd").lowercased(), default: 0] += 1 }
        let currency = (counts.max { $0.value < $1.value }?.key ?? "usd").uppercased()

        var buckets = ConnBuckets(range: range, now: now)
        var net = 0.0
        var charges = 0.0
        for item in relevant where (J.str(item["currency"]) ?? "usd").uppercased() == currency {
            guard let minor = J.num(item["net"]) else { continue }
            let v = ConnMoney.fromStripe(minor, currency)
            net += v
            if ["charge", "payment"].contains(J.str(item["type"]) ?? "") { charges += 1 }
            if let d = ConnDate.parse(item["created"]) { buckets.add(v, at: d) }
        }
        var snap = ConnSnapshot()
        snap.value = net
        snap.currency = currency
        snap.metrics[ConnKey.orders] = charges
        snap.series = buckets.trimmed(now: now)
        snap.seriesStart = buckets.start
        snap.seriesStep = buckets.step
        return snap
    }
}

// MARK: - Dodo Payments

/// GET /payments — sums `total_amount` (minor units) of succeeded payments. Falls back to the
/// test environment when a live call is unauthorized (test keys only work there).
enum ConnDodo {
    static let pageSize = 100

    static func fetch(token: String, range: ConnRange) async throws -> ConnSnapshot {
        do {
            return try await fetch(base: "https://live.dodopayments.com", token: token, range: range)
        } catch let e as Net.HTTPError where e.status == 401 {
            return try await fetch(base: "https://test.dodopayments.com", token: token, range: range)
        }
    }

    static func request(base: String, start: Date, page: Int) throws -> URL {
        try ConnHTTP.url("\(base)/payments", [
            ("created_at_gte", ConnDate.isoUTC(start)), ("page_size", String(pageSize)), ("page_number", String(page))
        ])
    }

    private static func fetch(base: String, token: String, range: ConnRange) async throws -> ConnSnapshot {
        let now = Date()
        let start = range.start(now)
        var items: [[String: Any]] = []
        for page in 0..<10 {
            let obj = try await ConnHTTP.object(request(base: base, start: start, page: page), headers: ConnHTTP.bearer(token))
            let batch = J.array(obj["items"])
            items += batch
            if batch.count < pageSize { break }
            try Task.checkCancellation()
        }
        return parse(items, range: range, now: now)
    }

    /// Succeeded payments (fully refunded ones stay "succeeded" with `refund_status: "full"` — skipped).
    static func parse(_ items: [[String: Any]], range: ConnRange, now: Date) -> ConnSnapshot {
        let paid = items.filter {
            (J.str($0["status"]) ?? "").lowercased() == "succeeded" && (J.str($0["refund_status"]) ?? "").lowercased() != "full"
        }
        var counts: [String: Int] = [:]
        for p in paid { counts[(J.str(p["currency"]) ?? "USD").uppercased(), default: 0] += 1 }
        let currency = counts.max { $0.value < $1.value }?.key ?? "USD"

        var buckets = ConnBuckets(range: range, now: now)
        var total = 0.0
        var orders = 0.0
        for p in paid where (J.str(p["currency"]) ?? "USD").uppercased() == currency {
            let v = ConnMoney.fromMinor(J.num(p["total_amount"]) ?? 0, currency)
            total += v
            orders += 1
            if let d = ConnDate.parse(p["created_at"]) { buckets.add(v, at: d) }
        }
        var snap = ConnSnapshot()
        snap.value = total
        snap.currency = currency
        snap.metrics[ConnKey.orders] = orders
        snap.series = buckets.trimmed(now: now)
        snap.seriesStart = buckets.start
        snap.seriesStep = buckets.step
        return snap
    }
}

// MARK: - Shopify

/// Admin REST orders for the current and previous equal-length period (for ↑/↓ deltas).
enum ConnShopify {
    struct Order: Equatable {
        var date: Date
        var amount: Double
    }

    struct Window: Equatable {
        var start: Date
        var prevStart: Date
        var prevEnd: Date
    }

    static func normalizedShop(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["https://", "http://"] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        if !s.isEmpty, !s.contains(".") { s += ".myshopify.com" }
        return s
    }

    /// Current range plus the previous equal-length period. "Today so far" compares with
    /// yesterday up to the same time; longer ranges with the full previous period.
    static func window(range: ConnRange, now: Date) -> Window {
        let cal = ConnDate.calendar
        let start = range.start(now)
        let prevStart = cal.date(byAdding: .day, value: -range.days, to: start) ?? start.addingTimeInterval(-Double(range.days) * 86_400)
        let prevEnd = range == .day ? now.addingTimeInterval(-86_400) : start
        return Window(start: start, prevStart: prevStart, prevEnd: prevEnd)
    }

    static func ordersURL(host: String, since: Date) throws -> URL {
        try ConnHTTP.url("https://\(host)/admin/api/2024-10/orders.json", [
            ("status", "any"), ("created_at_min", ConnDate.iso(since)), ("limit", "250"),
            ("fields", "total_price,current_total_price,created_at,currency,cancelled_at,test")
        ])
    }

    static func fetch(shop: String, token: String, range: ConnRange, now: Date = Date(), send: ConnSend = ConnHTTP.live) async throws -> ConnSnapshot {
        let host = normalizedShop(shop)
        guard !host.isEmpty else { throw ConnError(L("Add your store domain")) }
        let headers = ["X-Shopify-Access-Token": token]
        let win = window(range: range, now: now)

        var next: URL? = try ordersURL(host: host, since: win.prevStart)
        var orders: [Order] = []
        var currency: String?
        var pages = 0
        while let url = next, pages < 12 {
            let (data, response) = try await send(url, headers)
            let page = try parseOrders(data)
            orders += page.orders
            if currency == nil { currency = page.currency }
            next = ConnHTTP.nextLink(response)
            pages += 1
            try Task.checkCancellation()
        }
        if currency == nil {
            let shopURL = try ConnHTTP.url("https://\(host)/admin/api/2024-10/shop.json", [("fields", "currency")])
            currency = shopCurrency(try? await ConnJSON.object(send(shopURL, headers).0))
        }
        return summarize(orders, currency: currency, range: range, now: now)
    }

    /// One `orders.json` page → non-cancelled, non-test orders and the first order's currency.
    /// Amounts prefer `current_total_price` (after refunds and edits) over the original `total_price`.
    static func parseOrders(_ data: Data) throws -> (orders: [Order], currency: String?) {
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        var orders: [Order] = []
        var currency: String?
        for o in J.array(obj?["orders"]) {
            if let c = o["cancelled_at"], !(c is NSNull) { continue }
            if (o["test"] as? Bool) == true { continue }
            guard let d = ConnDate.parse(o["created_at"]), let amount = J.num(o["current_total_price"]) ?? J.num(o["total_price"]) else { continue }
            if currency == nil { currency = J.str(o["currency"]) }
            orders.append(Order(date: d, amount: amount))
        }
        return (orders, currency)
    }

    static func shopCurrency(_ obj: [String: Any]?) -> String? { J.str(J.path(obj, "shop.currency")) }

    static func summarize(_ orders: [Order], currency: String?, range: ConnRange, now: Date) -> ConnSnapshot {
        let win = window(range: range, now: now)
        var buckets = ConnBuckets(range: range, now: now)
        var sales = 0.0, count = 0.0, prevSales = 0.0, prevCount = 0.0
        for o in orders {
            if o.date >= win.start {
                sales += o.amount
                count += 1
                buckets.add(o.amount, at: o.date)
            } else if o.date >= win.prevStart, o.date < win.prevEnd {
                prevSales += o.amount
                prevCount += 1
            }
        }
        func delta(_ cur: Double, _ prev: Double) -> Double? { prev > 0 ? (cur - prev) / prev : nil }
        let aov = count > 0 ? sales / count : 0
        let prevAOV = prevCount > 0 ? prevSales / prevCount : 0

        var snap = ConnSnapshot()
        snap.value = sales
        snap.currency = (currency ?? "USD").uppercased()
        snap.metrics[ConnKey.orders] = count
        snap.metrics[ConnKey.aov] = aov
        snap.metrics[ConnKey.valueDelta] = delta(sales, prevSales)
        snap.metrics[ConnKey.ordersDelta] = delta(count, prevCount)
        snap.metrics[ConnKey.aovDelta] = delta(aov, prevAOV)
        snap.series = buckets.trimmed(now: now)
        snap.seriesStart = buckets.start
        snap.seriesStep = buckets.step
        return snap
    }
}
