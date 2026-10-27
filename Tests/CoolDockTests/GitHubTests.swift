import Foundation
import Testing
@testable import CoolDock

/// Real responses captured with curl on 2026-10-27 (keyless):
/// - `https://github.com/users/torvalds/contributions` (public calendar fragment, 367 cells)
/// - `https://github.com/users/ghost/contributions` (account without a calendar)
/// - `https://api.github.com/users/torvalds/events?per_page=100&page=1`
/// Expected numbers were computed independently with a Python regex pass over the same HTML.
@Suite struct GitHubTests {
    let calendar = "github/contributions-torvalds-2026-10-27.html"
    let now = TestDate.local(2026, 10, 27, 12)

    @Test func calendarCellsAndTotal() throws {
        let html = try Fixture.string(calendar)
        let days = ConnGitHub.calendarDays(html)
        #expect(days.count == 367)
        #expect(days.map(\.date).min() == "2025-10-26" && days.map(\.date).max() == "2026-10-27")
        #expect(Set(days.map(\.date)).count == 367) // one cell per day
        let sum = days.map(\.count).reduce(0, +)
        #expect(sum == 3948)
        // The heading total equals the sum of the calendar cells.
        #expect(ConnGitHub.calendarTotal(html) == sum)
    }

    @Test func calendarSnapshot() throws {
        let snap = try ConnGitHub.parseCalendarHTML(try Fixture.string(calendar), now: now)
        let byDay = Dictionary(uniqueKeysWithValues: ConnGitHub.calendarDays(try Fixture.string(calendar)).map { ($0.date, $0.count) })

        #expect(snap.estimate == false)
        #expect(snap.metrics[ConnKey.total] == 3948)
        #expect(snap.series.count == ConnGitHub.days)
        #expect(snap.series.reduce(0, +) == 1485)              // last 91 days
        #expect(snap.metrics[ConnKey.today] == 0)              // 2026-10-27, captured just after midnight UTC
        #expect(snap.value == 0)
        #expect(snap.metrics[ConnKey.week] == 125)             // 2026-10-21 … 2026-10-27
        #expect(snap.series.suffix(3) == [17, 9, 0])           // 10-25, 10-26, 10-27
        #expect(snap.seriesStart == TestDate.local(2026, 7, 29))
        #expect(snap.seriesStep == 86_400)

        // Streak: today is still empty, so count back from yesterday while days are non-zero.
        var streak = 0
        var day = TestDate.local(2026, 10, 26)
        while let c = byDay[ConnDate.day(day)], c > 0 { streak += 1; day = ConnDate.calendar.date(byAdding: .day, value: -1, to: day)! }
        #expect(streak > 0 && snap.metrics[ConnKey.streak] == Double(streak))
    }

    @Test func calendarDropsDaysAfterToday() throws {
        // Viewed from a time zone where it is still 2026-10-26, the trailing 10-27 cell is dropped.
        let snap = try ConnGitHub.parseCalendarHTML(try Fixture.string(calendar), now: TestDate.local(2026, 10, 26, 22))
        #expect(snap.series.last == 9 && snap.metrics[ConnKey.today] == 9)
    }

    @Test func tooltipLabels() {
        #expect(ConnGitHub.labelCount("10 contributions on October 26th.") == 10)
        #expect(ConnGitHub.labelCount("1 contribution on November 2nd.") == 1)
        #expect(ConnGitHub.labelCount("No contributions on October 17th.") == 0)
        #expect(ConnGitHub.labelCount("1,204 contributions on May 1st.") == 1204)
        // Older markup carried the count as an attribute.
        let legacy = #"<rect width="10" class="ContributionCalendar-day" data-date="2023-01-02" data-count="7" data-level="2"></rect>"#
        #expect(ConnGitHub.calendarDays(legacy).map(\.count) == [7])
    }

    @Test func emptyCalendarThrowsSoFetchFallsBack() throws {
        #expect(throws: ConnError.self) { try ConnGitHub.parseCalendarHTML(try Fixture.string("github/contributions-ghost-2026-10-27.html"), now: now) }
        #expect(throws: ConnError.self) { try ConnGitHub.parseCalendarHTML(try Fixture.string("github/contributions-notauser-2026-10-27.html"), now: now) }
    }

    @Test func publicEventsApproximation() throws {
        let events = ConnJSON.array(try Fixture.json("github/events-torvalds-2026-10-27.json"))
        #expect(events.count == 100)
        var buckets = ConnGitHub.eventBuckets(now: now)
        ConnGitHub.addEvents(events, to: &buckets)
        // 93 PushEvents (payloads no longer carry commit counts → 1 each) + 1 created repository.
        #expect(buckets.values.reduce(0, +) == 94)
        let snap = ConnGitHub.summarizeEvents(buckets, now: now)
        #expect(snap.estimate && snap.series.count == ConnGitHub.days)
        // Far below the real calendar (1485 over the same 91 days) — why the calendar is preferred.
        #expect(snap.series.reduce(0, +) < 1485)
    }

    /// GraphQL `contributionCalendar` shape from https://docs.github.com/en/graphql/reference/objects#contributioncalendar
    @Test func graphQLCalendar() throws {
        var weeks: [[String: Any]] = []
        var day = TestDate.local(2026, 7, 26)
        var expected: [Double] = []
        for w in 0..<14 {
            var days: [[String: Any]] = []
            for d in 0..<7 {
                let count = (w * 7 + d) % 5
                days.append(["contributionCount": count, "date": ConnDate.day(day)])
                if day <= now { expected.append(Double(count)) }
                day = ConnDate.calendar.date(byAdding: .day, value: 1, to: day)!
            }
            weeks.append(["contributionDays": days])
        }
        let obj: [String: Any] = ["data": ["user": ["contributionsCollection": ["contributionCalendar": ["totalContributions": 1234, "weeks": weeks]]]]]
        let snap = try ConnGitHub.parseGraphQL(obj, viewer: false, now: now)
        #expect(snap.metrics[ConnKey.total] == 1234)
        #expect(snap.series == Array(expected.suffix(91)))
        #expect(snap.metrics[ConnKey.week] == expected.suffix(7).reduce(0, +))

        #expect(throws: ConnError.self) { try ConnGitHub.parseGraphQL(["data": ["user": NSNull()]], viewer: false, now: now) }
        let err: [String: Any] = ["errors": [["type": "NOT_FOUND", "message": "Could not resolve to a User with the login of 'zz'."]]]
        #expect(throws: ConnError.self) { try ConnGitHub.parseGraphQL(err, viewer: false, now: now) }
    }

    @Test func usernameCleanup() {
        #expect(ConnGitHub.cleanUser(" @torvalds/ ") == "torvalds")
    }
}
