import Foundation
import Testing
@testable import CoolDock

/// Replays fixture pages for providers whose `fetch` takes a `ConnSend`; records requested URLs.
final class FixtureServer: @unchecked Sendable {
    private(set) var requests: [URL] = []
    private let lock = NSLock()
    let route: (URL) throws -> (file: String, headers: [String: String])

    init(_ route: @escaping (URL) throws -> (file: String, headers: [String: String])) { self.route = route }

    var send: ConnSend {
        { [self] url, _ in
            lock.lock(); requests.append(url); lock.unlock()
            let r = try route(url)
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: r.headers)!
            return (try Fixture.data(r.file), response)
        }
    }

    static func query(_ url: URL) -> [String: String] {
        Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }) { a, _ in a }
    }
}

// MARK: - Stripe

/// Fixtures follow https://docs.stripe.com/api/balance_transactions/list and
/// https://docs.stripe.com/api/balance_transactions/object (list envelope `object/url/has_more/data`,
/// `net` = `amount - fee` in minor units, `created` in Unix seconds, lowercase `currency`);
/// cursor pagination per https://docs.stripe.com/api/pagination (`starting_after` = last id).
@Suite struct StripeTests {
    let now = TestDate.local(2026, 10, 27, 15)

    @Test func pageCursor() throws {
        let p1 = ConnStripe.page(try Fixture.object("stripe/balance-transactions-page1-docs-2026-10-27.json"))
        #expect(p1.items.count == 5 && p1.next == "txn_3QaA1LkdIwHu7ix0paymnt5")
        let p2 = ConnStripe.page(try Fixture.object("stripe/balance-transactions-page2-docs-2026-10-27.json"))
        #expect(p2.items.count == 4 && p2.next == nil)
    }

    @Test func netRevenueOverWindow() async throws {
        let server = FixtureServer { url in
            let q = FixtureServer.query(url)
            return (q["starting_after"] == nil ? "stripe/balance-transactions-page1-docs-2026-10-27.json"
                                               : "stripe/balance-transactions-page2-docs-2026-10-27.json", [:])
        }
        let snap = try await ConnStripe.fetch(token: "sk_test_x", range: .week, now: now, send: server.send)

        // Two requests: the second continues after the last id of page 1.
        #expect(server.requests.count == 2)
        let first = FixtureServer.query(server.requests[0])
        #expect(first["created[gte]"] == String(Int(TestDate.local(2026, 10, 21).timeIntervalSince1970)) && first["limit"] == "100")
        #expect(FixtureServer.query(server.requests[1])["starting_after"] == "txn_3QaA1LkdIwHu7ix0paymnt5")

        // USD (6 revenue rows) beats EUR (1). Net cents: 4825 − 1000 + 2397 + 1911 + 1000 − 500 = 8633;
        // stripe_fee and payout rows are not revenue.
        #expect(snap.currency == "USD")
        #expect(snap.value!.near(86.33))
        #expect(snap.metrics[ConnKey.orders] == 3) // charge ×2 + payment
        #expect(snap.seriesStart == TestDate.local(2026, 10, 21) && snap.seriesStep == 86_400)
        let expected: [Double] = [-5.00, 29.11, 0, 23.97, -10.00, 48.25, 0] // 10-21 … 10-27
        #expect(snap.series.count == 7 && zip(snap.series, expected).allSatisfy { $0.near($1) })
        #expect(snap.series.reduce(0, +).near(86.33))
    }

    @Test func currencyMinorUnits() {
        func txn(_ net: Double, _ currency: String) -> [String: Any] {
            ["id": "txn_1", "object": "balance_transaction", "type": "charge", "currency": currency, "net": net, "created": 1_793_016_000]
        }
        // https://docs.stripe.com/currencies — zero-decimal JPY, three-decimal KWD (×1000, last digit 0), UGX kept two-decimal.
        #expect(ConnStripe.parse([txn(1200, "jpy")], range: .week, now: now).value == 1200)
        #expect(ConnStripe.parse([txn(5120, "kwd")], range: .week, now: now).value!.near(5.12))
        #expect(ConnStripe.parse([txn(50_000, "ugx")], range: .week, now: now).value == 500)
        #expect(ConnStripe.parse([txn(1999, "eur")], range: .week, now: now).value!.near(19.99))
    }
}

// MARK: - Shopify

/// Fixtures follow the Order resource (https://shopify.dev/docs/api/admin-rest/latest/resources/order:
/// `total_price` / `current_total_price` decimal strings in shop currency, ISO 8601 `created_at` with
/// offset, `cancelled_at` null unless cancelled, `test`) and the Shop resource (`shop.currency`).
/// Pagination per https://shopify.dev/docs/api/usage/pagination-rest (`Link` header, `rel="next"`).
@Suite struct ShopifyTests {
    let now = TestDate.local(2026, 10, 27, 15)
    let nextURL = "https://acme.myshopify.com/admin/api/2024-10/orders.json?limit=250&fields=total_price,current_total_price,created_at,currency,cancelled_at,test&page_info=eyJsYXN0X2lkIjo1ODA5MTQ2MjQ5Mzg1fQ"

    @Test func paginatesViaLinkHeader() async throws {
        let server = FixtureServer { [nextURL] url in
            if url.absoluteString == nextURL {
                return ("shopify/orders-page2-docs-2026-10-27.json",
                        ["Link": "<https://acme.myshopify.com/admin/api/2024-10/orders.json?limit=250&page_info=prev>; rel=\"previous\""])
            }
            return ("shopify/orders-page1-docs-2026-10-27.json", ["Link": "<\(nextURL)>; rel=\"next\""])
        }
        let snap = try await ConnShopify.fetch(shop: "Acme", token: "shpat_x", range: .week, now: now, send: server.send)

        #expect(server.requests.count == 2) // page 1, then the rel="next" target; no shop.json (currency known)
        let q = FixtureServer.query(server.requests[0])
        #expect(server.requests[0].host == "acme.myshopify.com")
        #expect(q["status"] == "any" && q["limit"] == "250" && q["fields"]?.contains("current_total_price") == true)
        #expect(ConnDate.parse(q["created_at_min"]) == TestDate.local(2026, 10, 14)) // previous period start
        #expect(server.requests[1].absoluteString == nextURL)

        // Current week (10-21…): 120.00 + 60.50 (refund-adjusted current_total_price) + 200.00;
        // the cancelled and the test order are skipped. Previous week: 150 + 50 + 0 (fully refunded).
        #expect(snap.currency == "USD")
        #expect(snap.value!.near(380.5))
        #expect(snap.metrics[ConnKey.orders] == 3)
        #expect(snap.metrics[ConnKey.aov]!.near(380.5 / 3))
        #expect(snap.metrics[ConnKey.valueDelta]!.near((380.5 - 200) / 200))
        #expect(snap.metrics[ConnKey.ordersDelta] == 0)
        #expect(snap.metrics[ConnKey.aovDelta]!.near((380.5 / 3 - 200.0 / 3) / (200.0 / 3)))
        #expect(snap.series == [0, 200, 0, 0, 60.5, 120, 0])
    }

    @Test func docsLinkHeaderForm() {
        // Verbatim shape from the pagination docs (backtick-wrapped targets, unquoted rel),
        // with the {shop}/{api_version} placeholders filled in.
        let h = "`https://acme.myshopify.com/admin/api/2024-10/customers.json?page_info=abcdefg&limit=3`; rel=previous, `https://acme.myshopify.com/admin/api/2024-10/customers.json?page_info=opqrstu&limit=3`; rel=next"
        #expect(ConnHTTP.nextLink(header: h)?.query == "page_info=opqrstu&limit=3")
    }

    @Test func shopCurrencyFallback() async throws {
        let server = FixtureServer { url in
            url.path.hasSuffix("shop.json") ? ("shopify/shop-docs-2026-10-27.json", [:]) : ("shopify/empty-orders-docs-2026-10-27.json", [:])
        }
        let snap = try await ConnShopify.fetch(shop: "https://acme.myshopify.com/admin", token: "shpat_x", range: .day, now: now, send: server.send)
        #expect(server.requests.map(\.lastPathComponent) == ["orders.json", "shop.json"])
        #expect(snap.currency == "EUR" && snap.value == 0 && snap.metrics[ConnKey.valueDelta] == nil)
    }

    @Test func todayComparesWithYesterdaySoFar() {
        let w = ConnShopify.window(range: .day, now: now)
        #expect(w.start == TestDate.local(2026, 10, 27) && w.prevStart == TestDate.local(2026, 10, 26))
        #expect(w.prevEnd == TestDate.local(2026, 10, 26, 15))
    }

    @Test func shopDomainNormalisation() {
        #expect(ConnShopify.normalizedShop(" Acme ") == "acme.myshopify.com")
        #expect(ConnShopify.normalizedShop("https://shop.example.com/admin") == "shop.example.com")
    }
}

// MARK: - Dodo Payments

/// Fixture follows https://docs.dodopayments.com/api-reference/payments/get-payments (`items[]` only;
/// required item fields, `status` nullable, `refund_status` partial/full/null, uppercase `currency`) and
/// `total_amount` "in the currency's smallest unit" per https://docs.dodopayments.com/api-reference/payments/get-payments-1.
@Suite struct DodoTests {
    let now = TestDate.local(2026, 10, 27, 15)

    @Test func succeededRevenue() throws {
        let items = ConnJSON.array(try Fixture.object("dodo/payments-docs-2026-10-27.json")["items"])
        #expect(items.count == 8)
        let snap = ConnDodo.parse(items, range: .week, now: now)
        // 2999 + 4999 (partially refunded, still revenue) + 10000; skipped: full refund, failed,
        // null status, processing; EUR is the minority currency.
        #expect(snap.currency == "USD")
        #expect(snap.value!.near(179.98))
        #expect(snap.metrics[ConnKey.orders] == 3)
        #expect(snap.series == [0, 100, 0, 0, 49.99, 29.99, 0])
    }

    @Test func requestIsZeroBased() throws {
        let url = try ConnDodo.request(base: "https://test.dodopayments.com", start: TestDate.utc("2026-10-20T20:30:00Z"), page: 0)
        let q = FixtureServer.query(url)
        #expect(url.path == "/payments" && q["page_number"] == "0" && q["page_size"] == "100")
        #expect(q["created_at_gte"] == "2026-10-20T20:30:00Z")
    }

    @Test func threeDecimalCurrency() {
        let kwd: [String: Any] = ["status": "succeeded", "currency": "KWD", "total_amount": 5120, "created_at": "2026-10-26T12:00:00Z"]
        #expect(ConnDodo.parse([kwd], range: .week, now: now).value!.near(5.12))
    }
}

// MARK: - Polar

/// Fixture follows https://polar.sh/docs/api-reference/metrics/get (`MetricsResponse`: `periods[]` with
/// `timestamp` + optional numeric/null metrics, `totals`, `metrics` descriptors); "Currency values are
/// output in cents" (https://polar.sh/docs/features/analytics).
@Suite struct PolarTests {
    let now = TestDate.local(2026, 10, 27, 15)

    @Test func netRevenueFromTotals() throws {
        let raw = try Fixture.object("polar/metrics-docs-2026-10-27.json")
        let snap = ConnPolar.parse(raw, range: .week, now: now)
        #expect(snap.value!.near(158.685)) // totals.net_revenue 15868.5 cents
        #expect(snap.currency == "USD")
        #expect(snap.metrics[ConnKey.orders] == 7)
        #expect(snap.series.count == 7)
        // Every period that starts inside the local window lands in a bucket.
        let start = TestDate.local(2026, 10, 21)
        let inWindow = ConnJSON.array(raw["periods"]).filter { ConnDate.parse($0["timestamp"])! >= start }
        #expect(snap.series.reduce(0, +).near(inWindow.compactMap { ConnJSON.num($0["net_revenue"]) }.reduce(0, +) / 100))
    }

    @Test func sumsPeriodsWithoutTotals() throws {
        var raw = try Fixture.object("polar/metrics-docs-2026-10-27.json")
        raw["totals"] = [String: Any]()
        let snap = ConnPolar.parse(raw, range: .week, now: now)
        #expect(snap.value!.near(158.685) && snap.metrics[ConnKey.orders] == 7)
    }

    @Test func requestParameters() throws {
        let q = FixtureServer.query(try ConnPolar.request(range: .day, now: now))
        #expect(q["start_date"] == "2026-10-27" && q["end_date"] == "2026-10-27" && q["interval"] == "hour")
        #expect(FixtureServer.query(try ConnPolar.request(range: .month, now: now))["start_date"] == "2026-09-28")
    }
}
