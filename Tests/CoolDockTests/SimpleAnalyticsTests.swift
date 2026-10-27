import Foundation
import Testing
@testable import CoolDock

/// Real keyless responses from the public `simpleanalytics.com` stats JSON, captured with curl on
/// 2026-10-27 (`https://simpleanalytics.com/simpleanalytics.com.json?version=6&fields=pageviews,visitors,histogram&start=…&end=today&timezone=Asia/Tehran`,
/// plus the `version=5` form from the docs). Docs: https://docs.simpleanalytics.com/api/stats
@Suite struct SimpleAnalyticsTests {
    let start = TestDate.local(2026, 10, 21)

    @Test func sevenDaysV6() throws {
        let raw = try Fixture.object("simpleanalytics/v6-7d-2026-10-27.json")
        let snap = try ConnSimpleAnalytics.parse(raw, start: start)
        let histogram = ConnJSON.array(raw["histogram"])
        #expect(snap.value == 3269)
        #expect(snap.metrics[ConnKey.pageviews] == 4872)
        #expect(snap.series.count == 7)
        #expect(snap.series == histogram.map { ($0["visitors"] as! NSNumber).doubleValue })
        // Total visitors equal the sum of the daily histogram.
        #expect(snap.series.reduce(0, +) == snap.value)
        #expect(snap.series.first == 588 && snap.series.last == 79)
        #expect(snap.seriesStart == start && snap.seriesStep == 86_400)
        // One histogram row per local day from `start`.
        #expect(histogram.compactMap { $0["date"] as? String } == (0..<7).map { ConnDate.day(ConnDate.calendar.date(byAdding: .day, value: $0, to: start)!) })
    }

    @Test func otherRanges() throws {
        let month = try ConnSimpleAnalytics.parse(try Fixture.object("simpleanalytics/v6-30d-2026-10-27.json"), start: TestDate.local(2026, 9, 28))
        #expect(month.value == 16506 && month.metrics[ConnKey.pageviews] == 21841)
        #expect(month.series.count == 30 && month.series.reduce(0, +) == 16506)

        let today = try ConnSimpleAnalytics.parse(try Fixture.object("simpleanalytics/v6-1d-2026-10-27.json"), start: TestDate.local(2026, 10, 27))
        #expect(today.value == 79 && today.metrics[ConnKey.pageviews] == 105 && today.series == [79])

        let v5 = try ConnSimpleAnalytics.parse(try Fixture.object("simpleanalytics/v5-7d-2026-10-27.json"), start: start)
        #expect(v5.value == 3229 && v5.metrics[ConnKey.pageviews] == 4823 && v5.series.reduce(0, +) == 3229)
    }

    @Test func unknownOrPrivateSite() throws {
        // HTTP 404 {"ok":false,"error":"View not found"} — the parser surfaces the API's message.
        #expect(throws: ConnError("View not found")) {
            try ConnSimpleAnalytics.parse(try Fixture.object("simpleanalytics/v6-private-2026-10-27.json"), start: start)
        }
    }

    @Test func requestMatchesDocumentedQuery() throws {
        let url = try ConnSimpleAnalytics.request(site: " https://simpleanalytics.com/ ", range: .week, now: TestDate.local(2026, 10, 27, 9))
        let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let q = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(comps.host == "simpleanalytics.com" && comps.path == "/simpleanalytics.com.json")
        #expect(q["version"] == "6" && q["fields"] == "pageviews,visitors,histogram")
        #expect(q["start"] == "2026-10-21" && q["end"] == "today")
    }

    @MainActor @Test func publicSitesNeedNoKey() {
        let w = WidgetInstance(kind: .simpleAnalytics, config: ["site": "simpleanalytics.com", "range": "7d"])
        #expect(ConnService.isConfigured(w, token: nil))
        let empty = WidgetInstance(kind: .simpleAnalytics, config: ["range": "7d"])
        #expect(!ConnService.isConfigured(empty, token: nil))
    }
}

extension ConnError: Equatable {
    public static func == (a: ConnError, b: ConnError) -> Bool { a.message == b.message }
}
