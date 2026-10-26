import Foundation

private typealias J = ConnJSON

// MARK: - Polar

/// GET /v1/metrics — `periods[].revenue` (cents, USD) plus `totals`.
enum ConnPolar {
    static func fetch(token: String, range: ConnRange) async throws -> ConnSnapshot {
        let now = Date()
        let start = range.start(now)
        let url = try ConnHTTP.url("https://api.polar.sh/v1/metrics/", [
            ("start_date", ConnDate.day(start)), ("end_date", ConnDate.day(now)),
            ("interval", range == .day ? "hour" : "day"), ("timezone", TimeZone.current.identifier)
        ])
        let obj = try await ConnHTTP.object(url, headers: ConnHTTP.bearer(token))
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
    private static let revenueTypes: Set<String> = ["charge", "payment", "refund", "payment_refund", "payment_failure_refund"]

    static func fetch(token: String, range: ConnRange) async throws -> ConnSnapshot {
        let now = Date()
        let start = range.start(now)
        var items: [[String: Any]] = []
        var after: String?
        for _ in 0..<10 {
            var query = [("created[gte]", String(Int(start.timeIntervalSince1970))), ("limit", "100")]
            if let after { query.append(("starting_after", after)) }
            let obj = try await ConnHTTP.object(ConnHTTP.url("https://api.stripe.com/v1/balance_transactions", query), headers: ConnHTTP.bearer(token))
            let page = J.array(obj["data"])
            items += page
            guard (obj["has_more"] as? Bool) == true, let last = J.str(page.last?["id"]) else { break }
            after = last
            try Task.checkCancellation()
        }

        let relevant = items.filter { revenueTypes.contains(J.str($0["type"]) ?? "") }
        var counts: [String: Int] = [:]
        for item in relevant { counts[(J.str(item["currency"]) ?? "usd").lowercased(), default: 0] += 1 }
        let currency = (counts.max { $0.value < $1.value }?.key ?? "usd").uppercased()

        var buckets = ConnBuckets(range: range, now: now)
        var net = 0.0
        var charges = 0.0
        for item in relevant where (J.str(item["currency"]) ?? "usd").uppercased() == currency {
            guard let minor = J.num(item["net"]) else { continue }
            let v = ConnMoney.fromMinor(minor, currency)
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
    static func fetch(token: String, range: ConnRange) async throws -> ConnSnapshot {
        do {
            return try await fetch(base: "https://live.dodopayments.com", token: token, range: range)
        } catch let e as Net.HTTPError where e.status == 401 {
            return try await fetch(base: "https://test.dodopayments.com", token: token, range: range)
        }
    }

    private static func fetch(base: String, token: String, range: ConnRange) async throws -> ConnSnapshot {
        let now = Date()
        let start = range.start(now)
        var items: [[String: Any]] = []
        for page in 0..<10 {
            let url = try ConnHTTP.url("\(base)/payments", [
                ("created_at_gte", ConnDate.isoUTC(start)), ("page_size", "100"), ("page_number", String(page))
            ])
            let obj = try await ConnHTTP.object(url, headers: ConnHTTP.bearer(token))
            let batch = J.array(obj["items"])
            items += batch
            if batch.count < 100 { break }
            try Task.checkCancellation()
        }
        let paid = items.filter { (J.str($0["status"]) ?? "").lowercased() == "succeeded" }
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
    static func normalizedShop(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["https://", "http://"] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        if !s.isEmpty, !s.contains(".") { s += ".myshopify.com" }
        return s
    }

    static func fetch(shop: String, token: String, range: ConnRange) async throws -> ConnSnapshot {
        let host = normalizedShop(shop)
        guard !host.isEmpty else { throw ConnError(L("Add your store domain")) }
        let headers = ["X-Shopify-Access-Token": token]
        let cal = ConnDate.calendar
        let now = Date()
        let start = range.start(now)
        let prevStart = cal.date(byAdding: .day, value: -range.days, to: start) ?? start.addingTimeInterval(-Double(range.days) * 86_400)
        // "Today so far" compares with yesterday up to the same time; longer ranges with the full previous period.
        let prevEnd = range == .day ? now.addingTimeInterval(-86_400) : start

        var next: URL? = try ConnHTTP.url("https://\(host)/admin/api/2024-10/orders.json", [
            ("status", "any"), ("created_at_min", ConnDate.iso(prevStart)), ("limit", "250"),
            ("fields", "total_price,created_at,currency,cancelled_at")
        ])
        var orders: [(date: Date, amount: Double)] = []
        var currency: String?
        var pages = 0
        while let url = next, pages < 12 {
            let (data, response) = try await ConnHTTP.send(url, headers: headers)
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            for o in J.array(obj?["orders"]) {
                if let c = o["cancelled_at"], !(c is NSNull) { continue }
                guard let d = ConnDate.parse(o["created_at"]), let amount = J.num(o["total_price"]) else { continue }
                if currency == nil { currency = J.str(o["currency"]) }
                orders.append((d, amount))
            }
            next = ConnHTTP.nextLink(response)
            pages += 1
            try Task.checkCancellation()
        }
        if currency == nil {
            let shopObj = try? await ConnHTTP.object(ConnHTTP.url("https://\(host)/admin/api/2024-10/shop.json", [("fields", "currency")]), headers: headers)
            currency = J.str(J.path(shopObj, "shop.currency"))
        }

        var buckets = ConnBuckets(range: range, now: now)
        var sales = 0.0, count = 0.0, prevSales = 0.0, prevCount = 0.0
        for o in orders {
            if o.date >= start {
                sales += o.amount
                count += 1
                buckets.add(o.amount, at: o.date)
            } else if o.date >= prevStart, o.date < prevEnd {
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
