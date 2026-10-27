import Foundation
import Testing
@testable import CoolDock

/// Dub — fixtures are the verbatim examples of https://dub.co/docs/concepts/analytics/introduction
/// (`groupBy=count` object; `groupBy=timeseries` rows with `start`), extended to 7 days. Schema per
/// https://dub.co/docs/api-reference/endpoint/retrieve-analytics (`saleAmount` "in cents").
@Suite struct DubTests {
    @Test func countsAndSeries() throws {
        let snap = ConnDub.parse(counts: try Fixture.json("dub/analytics-count-docs-2026-10-27.json"),
                                 timeseries: try Fixture.json("dub/analytics-timeseries-docs-2026-10-27.json"), range: .week)
        #expect(snap.value == 100 && snap.metrics[ConnKey.clicks] == 100)
        #expect(snap.metrics[ConnKey.leads] == 5 && snap.metrics[ConnKey.sales] == 2)
        #expect(snap.metrics[ConnKey.saleAmount] == 50) // 5000 cents
        #expect(snap.currency == "USD")
        #expect(snap.series == [10, 15, 12, 20, 18, 16, 9])
        #expect(snap.seriesStart == TestDate.utc("2026-10-21T00:00:00Z") && snap.seriesStep == 86_400)
    }

    @Test func countsWithoutSeries() throws {
        let snap = ConnDub.parse(counts: [["clicks": 7, "leads": 0, "sales": 0, "saleAmount": 0]], timeseries: nil, range: .day)
        #expect(snap.value == 7 && snap.series.isEmpty && snap.seriesStep == 3600)
    }
}

/// DataFast — verbatim overview example of https://datafa.st/docs/api/website/analytics/overview
/// (`{status, data: [row]}`, `currency` inside the row) and the time-series shape of
/// https://datafa.st/docs/api/website/analytics/timeseries (`data[]` with `timestamp`, `currency`-less).
@Suite struct DataFastTests {
    let now = TestDate.local(2026, 10, 27, 15)

    @Test func overviewAndSeries() throws {
        let snap = try ConnDataFast.parse(overview: try Fixture.json("datafast/overview-docs-2026-10-27.json"),
                                          timeseries: try Fixture.json("datafast/timeseries-docs-2026-10-27.json"), range: .week, now: now)
        #expect(snap.value == 12450)
        #expect(snap.metrics[ConnKey.revenue] == 28450)
        #expect(snap.metrics[ConnKey.sessions] == 16890 && snap.metrics[ConnKey.pageviews] == 16890)
        // Was nil before: the overview keeps `currency` inside `data[0]`.
        #expect(snap.currency == "USD")
        #expect(snap.series == [528, 601, 433, 389, 412, 575, 233])
        #expect(snap.series.reduce(0, +) == 3171) // equals `totals.visitors`
        #expect(snap.seriesStart == TestDate.local(2026, 10, 21))
    }

    @Test func errorEnvelopeIsRejected() {
        // {"status":"error","error":{"code":401,"message":"Unauthorized: Invalid API Key"}}
        let body: [String: Any] = ["status": "error", "error": ["code": 401, "message": "Unauthorized: Invalid API Key"]]
        #expect(throws: ConnError.self) { try ConnDataFast.parse(overview: body, timeseries: nil, range: .week, now: now) }
    }
}

/// Plausible Stats API v1 — aggregate fixture is the verbatim example of
/// https://plausible.io/docs/stats-api-v1 (`results.<metric>.value`); time series rows use the
/// documented `{date, visitors}` shape (daily `YYYY-MM-DD`; hourly rows for `period=day`).
@Suite struct PlausibleTests {
    @Test func weekAggregateAndSeries() throws {
        let now = TestDate.local(2026, 10, 27, 15)
        let snap = try ConnPlausible.parse(aggregate: try Fixture.object("plausible/aggregate-docs-2026-10-27.json"),
                                           timeseries: try Fixture.object("plausible/timeseries-7d-docs-2026-10-27.json"), range: .week, now: now)
        #expect(snap.value == 201524 && snap.metrics[ConnKey.pageviews] == 673814)
        #expect(snap.series == [28012, 30441, 29873, 21540, 19977, 31208, 40473])
        #expect(snap.seriesStart == TestDate.local(2026, 10, 21) && snap.seriesStep == 86_400)
    }

    @Test func todayKeepsHoursUpToNow() throws {
        let now = TestDate.local(2026, 10, 27, 9, 30)
        let snap = try ConnPlausible.parse(aggregate: try Fixture.object("plausible/aggregate-docs-2026-10-27.json"),
                                           timeseries: try Fixture.object("plausible/timeseries-day-docs-2026-10-27.json"), range: .day, now: now)
        #expect(snap.series.count == 10 && snap.series.last == 1377 && snap.seriesStep == 3600)
        #expect(snap.seriesStart == TestDate.local(2026, 10, 27))
    }

    @Test func missingVisitorsThrows() {
        // {"error":"Invalid API key or site ID. …"}
        #expect(throws: ConnError.self) {
            try ConnPlausible.parse(aggregate: ["error": "Invalid API key or site ID."], timeseries: nil, range: .week, now: Date())
        }
        #expect(ConnPlausible.period(.day) == "day" && ConnPlausible.period(.week) == "7d" && ConnPlausible.period(.month) == "30d")
    }
}
