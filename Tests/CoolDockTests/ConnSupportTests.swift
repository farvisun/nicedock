import Foundation
import Testing
@testable import CoolDock

/// Shared plumbing every provider relies on: RFC 8288 `Link` parsing, tolerant dates, minor units.
@Suite struct ConnSupportTests {
    // MARK: Link header

    @Test func linkNextOnly() {
        let h = #"<https://shop.myshopify.com/admin/api/2024-10/orders.json?limit=250&page_info=abc>; rel="next""#
        #expect(ConnHTTP.nextLink(header: h)?.absoluteString == "https://shop.myshopify.com/admin/api/2024-10/orders.json?limit=250&page_info=abc")
    }

    @Test func linkPreviousAndNext() {
        let h = #"<https://s.myshopify.com/admin/api/2024-10/orders.json?limit=250&page_info=prev1>; rel="previous", <https://s.myshopify.com/admin/api/2024-10/orders.json?limit=250&page_info=next1>; rel="next""#
        #expect(ConnHTTP.nextLink(header: h)?.query == "limit=250&page_info=next1")
    }

    @Test func linkLastPageHasNoNext() {
        let h = #"<https://s.myshopify.com/admin/api/2024-10/orders.json?limit=250&page_info=prev1>; rel="previous""#
        #expect(ConnHTTP.nextLink(header: h) == nil)
        #expect(ConnHTTP.nextLink(header: nil) == nil)
    }

    @Test func linkTargetWithUnencodedCommas() {
        // The old split-on-every-comma parser lost this link (and with it every page after the first).
        let h = #"<https://s.myshopify.com/admin/api/2024-10/orders.json?limit=250&fields=total_price,created_at,currency,cancelled_at&page_info=xyz>; rel="next""#
        #expect(ConnHTTP.nextLink(header: h)?.absoluteString.hasSuffix("fields=total_price,created_at,currency,cancelled_at&page_info=xyz") == true)
    }

    @Test func linkMultiValueRelAndUnquoted() {
        #expect(ConnHTTP.nextLink(header: #"<https://a.example/p2>; rel="next last""#)?.absoluteString == "https://a.example/p2")
        #expect(ConnHTTP.nextLink(header: "<https://a.example/p3>; rel=next")?.absoluteString == "https://a.example/p3")
        #expect(ConnHTTP.nextLink(header: #"<https://a.example/first>; rel="first", <https://a.example/p4>; title="x"; rel="next""#)?.absoluteString == "https://a.example/p4")
    }

    @Test func linkFromHTTPResponse() throws {
        let r = try #require(HTTPURLResponse(url: URL(string: "https://x.example")!, statusCode: 200, httpVersion: nil,
                                             headerFields: ["link": #"<https://x.example/2>; rel="next""#]))
        #expect(ConnHTTP.nextLink(r)?.absoluteString == "https://x.example/2")
    }

    // MARK: Dates

    @Test func isoVariants() {
        let base = TestDate.utc("2023-04-03T22:13:42Z")
        #expect(ConnDate.parse("2023-04-03T22:13:42Z") == base)
        #expect(ConnDate.parse("2023-04-03T22:13:42.000Z") == base)
        #expect(ConnDate.parse("2023-04-04T01:43:42+03:30") == base)
        #expect(ConnDate.parse("2023-04-03T22:13:42") == base) // no zone → UTC
        #expect(abs(ConnDate.parse("2023-04-03T22:13:42.5Z")!.timeIntervalSince(base) - 0.5) < 1e-6)
    }

    @Test func resendPostgresTimestamp() throws {
        // https://resend.com/docs/api-reference/emails/list-emails — "2026-04-03 22:13:42.674981+00"
        let d = try #require(ConnDate.parse("2026-04-03 22:13:42.674981+00"))
        #expect(abs(d.timeIntervalSince(TestDate.utc("2026-04-03T22:13:42Z")) - 0.674981) < 1e-3)
        #expect(ConnDate.parse("2023-04-03 22:13:42.67+00") != nil)
    }

    @Test func minutePrecisionTimestamp() throws {
        // Supabase's OpenAPI `date-time` pattern allows "YYYY-MM-DDTHH:MM" (seconds optional).
        #expect(ConnDate.parse("2024-01-01T04:24Z") == TestDate.utc("2024-01-01T04:24:00Z"))
        #expect(ConnDate.parse("2024-01-01T04:24") == TestDate.utc("2024-01-01T04:24:00Z"))
    }

    @Test func unixAndDateOnly() {
        #expect(ConnDate.parse(1_700_000_000) == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(ConnDate.parse(1_700_000_000_123 as Int64) == Date(timeIntervalSince1970: 1_700_000_000.123))
        #expect(ConnDate.parse("2026-10-27") == TestDate.local(2026, 10, 27))
        #expect(ConnDate.parse("garbage") == nil)
    }

    // MARK: Money & buckets

    @Test func minorUnits() {
        #expect(ConnMoney.fromMinor(1234, "usd") == 12.34)
        #expect(ConnMoney.fromMinor(1234, "JPY") == 1234)
        #expect(ConnMoney.fromMinor(500, "krw") == 500)
    }

    @Test func dailyBucketsAreLocalCalendarDays() {
        let now = TestDate.local(2026, 10, 27, 15)
        var b = ConnBuckets(range: .week, now: now)
        #expect(b.start == TestDate.local(2026, 10, 21) && b.values.count == 7)
        b.add(5, at: TestDate.local(2026, 10, 21, 0, 1))
        b.add(2, at: TestDate.local(2026, 10, 27, 14))
        b.add(9, at: TestDate.local(2026, 10, 20, 23, 59)) // before range: ignored
        #expect(b.values == [5, 0, 0, 0, 0, 0, 2])
    }

    @Test func hourlyBucketsTrimToNow() {
        let now = TestDate.local(2026, 10, 27, 9, 30)
        var b = ConnBuckets(range: .day, now: now)
        b.add(1, at: TestDate.local(2026, 10, 27, 9, 10))
        #expect(b.values.count == 24)
        #expect(b.trimmed(now: now).count == 10 && b.trimmed(now: now).last == 1)
    }
}
