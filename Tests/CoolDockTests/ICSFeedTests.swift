import Foundation
import Testing
@testable import CoolDock

/// Real subscription feeds in `Tests/Fixtures/ics/`, downloaded with curl on 2026-10-27:
///
/// * `google-us-holidays-…` — https://calendar.google.com/calendar/ical/en.usa%23holiday%40group.v.calendar.google.com/public/basic.ics
///   317 all-day events 2021–2031, folded and escaped descriptions.
/// * `icloud-us-holidays-…` — https://calendars.icloud.com/holidays/us_en.ics (`curl --compressed`)
///   YEARLY rules with COUNT, BYMONTH and ordinal BYDAY, DTSTART only (no DTEND).
/// * `llvm-community-…` — https://calendar.google.com/calendar/ical/calendar%40llvm.org/public/basic.ics
///   947 VEVENTs, 15 TZIDs with VTIMEZONEs, weekly/biweekly/monthly rules with WKST, UNTIL, EXDATE and RECURRENCE-ID
///   overrides. ATTENDEE/ORGANIZER properties (personal e-mail addresses) were removed; every other byte is as downloaded.
/// * `wordpress-meetings-…` — https://make.wordpress.org/meetings.ics
///   UTC weekly, biweekly and monthly BYDAY rules running since 2015, one EXDATE.
///
/// `matchesIndependentExpansion` compares every occurrence in a 2026-10-19 … 2026-12-14 window with the output of
/// `Tests/Scripts/ics_oracle.py` (python-dateutil rrule + zoneinfo, in `Tests/Fixtures/ics/expected/`); the other
/// tests pin specific real events.
@Suite struct ICSFeedTests {
    static let utc = TimeZone(identifier: "UTC")!
    static let feeds = ["google-us-holidays", "icloud-us-holidays", "llvm-community", "wordpress-meetings"]

    static func feed(_ name: String) throws -> ICS.Feed { ICS.parse(try Fixture.data("ics/\(name)-2026-10-27.ics")) }

    static func iso(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
    static func isoString(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }

    /// "yyyy-MM-dd" of `date` in `zone` (Gregorian).
    static func day(_ date: Date, _ zone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    static func occurrences(_ feed: ICS.Feed, _ from: String, _ to: String, title: String? = nil, local: TimeZone = utc) -> [ICS.Occurrence] {
        ICS.occurrences(feed.events, from: iso(from), to: iso(to), local: local).filter { title == nil || $0.title == title }
    }

    // MARK: Cross-check

    @Test(arguments: feeds)
    func matchesIndependentExpansion(_ name: String) throws {
        let feed = try Self.feed(name)
        let got = ICS.occurrences(feed.events, from: Self.iso("2026-10-19T00:00:00Z"), to: Self.iso("2026-12-14T00:00:00Z"), local: Self.utc).map { o in
            let start = o.allDay ? Self.day(o.start, Self.utc) : Self.isoString(o.start)
            let end = o.allDay ? Self.day(o.end, Self.utc) : Self.isoString(o.end)
            return [o.uid, start, end, o.title.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")].joined(separator: "\t")
        }
        let expected = try Fixture.string("ics/expected/\(name)-2026-10-27.oracle-2026-10-19_2026-12-14.tsv")
            .split(separator: "\n").map(String.init)
        #expect(!expected.isEmpty)
        let missing = Set(expected).subtracting(got), extra = Set(got).subtracting(expected)
        #expect(missing.isEmpty, "missing: \(missing.sorted().prefix(5))")
        #expect(extra.isEmpty, "extra: \(extra.sorted().prefix(5))")
        #expect(got.count == expected.count, "duplicates")
    }

    // MARK: Google: Holidays in United States

    @Test func googleHolidaysAreAllDay() throws {
        let feed = try Self.feed("google-us-holidays")
        #expect(feed.name == "Holidays in United States")
        #expect(feed.events.count == 317)
        #expect(feed.events.allSatisfy { $0.allDay && $0.rule == nil && !$0.cancelled })

        // The week the widgets were rendered in, read in this Mac's own time zone.
        let local = TimeZone.current
        let week = ICS.occurrences(feed.events, from: TestDate.local(2026, 10, 27), to: TestDate.local(2026, 11, 4), local: local)
        #expect(week.map(\.title) == ["Halloween", "Daylight Saving Time ends", "Election Day"])
        #expect(week.map(\.start) == [TestDate.local(2026, 10, 31), TestDate.local(2026, 11, 1), TestDate.local(2026, 11, 3)])
        #expect(week.map(\.end) == [TestDate.local(2026, 11, 1), TestDate.local(2026, 11, 2), TestDate.local(2026, 11, 4)])
        #expect(week.allSatisfy({ $0.allDay }))

        // Folded and escaped DESCRIPTION.
        let halloween = try #require(feed.events.first { $0.uid == "20261031_jg75kt4ps505q4u01pbpictp2o@google.com" })
        #expect(halloween.notes == "Observance\nTo hide observances, go to Google Calendar Settings > Holidays in United States")
    }

    @Test func googleThanksgivingIsTheFourthThursday() throws {
        let feed = try Self.feed("google-us-holidays")
        let days = Self.occurrences(feed, "2021-01-01T00:00:00Z", "2032-01-01T00:00:00Z", title: "Thanksgiving Day").map { Self.day($0.start, Self.utc) }
        #expect(days == ["2021-11-25", "2022-11-24", "2023-11-23", "2024-11-28", "2025-11-27", "2026-11-26",
                         "2027-11-25", "2028-11-23", "2029-11-22", "2030-11-28", "2031-11-27"])
    }

    // MARK: iCloud: US Holidays (rules) vs Google (dates)

    @Test func iCloudRulesMatchGoogleDates() throws {
        let apple = try Self.feed("icloud-us-holidays"), google = try Self.feed("google-us-holidays")
        #expect(apple.name == "US Holidays")
        #expect(apple.events.count == 122)
        #expect(apple.events.filter { $0.rule != nil }.count == 28)
        #expect(apple.events.allSatisfy { $0.allDay && $0.end == nil })

        let thanksgiving = Self.occurrences(apple, "2025-01-01T00:00:00Z", "2031-01-01T00:00:00Z", title: "Thanksgiving").map { Self.day($0.start, Self.utc) }
        // FREQ=YEARLY;COUNT=5;BYDAY=4TH;BYMONTH=11 from 2025: five Novembers, then nothing.
        #expect(thanksgiving == ["2025-11-27", "2026-11-26", "2027-11-25", "2028-11-23", "2029-11-22"])
        let memorial = Self.occurrences(apple, "2025-01-01T00:00:00Z", "2031-01-01T00:00:00Z", title: "Memorial Day").map { Self.day($0.start, Self.utc) }
        #expect(memorial == ["2025-05-26", "2026-05-25", "2027-05-31", "2028-05-29", "2029-05-28"])

        // Every rule-based iCloud holiday lands on the same days as Google's explicit dates, 2025–2029.
        func normalized(_ title: String) -> String {
            let t = title.replacingOccurrences(of: "’", with: "'")
            return ["Thanksgiving": "Thanksgiving Day", "Daylight Saving Time": "Daylight Saving Time starts",
                    "Daylight Saving Time End": "Daylight Saving Time ends"][t] ?? t
        }
        func byTitle(_ feed: ICS.Feed) -> [String: [String]] {
            Dictionary(grouping: Self.occurrences(feed, "2025-01-01T00:00:00Z", "2030-01-01T00:00:00Z"), by: { normalized($0.title) })
                .mapValues { $0.map { Self.day($0.start, Self.utc) } }
        }
        let a = byTitle(apple), g = byTitle(google)
        let ruled = Set(apple.events.filter { $0.rule != nil }.map { normalized($0.summary) })
        let shared = ruled.intersection(g.keys)
        #expect(shared.count >= 20, "\(shared.sorted())")
        for name in shared.sorted() {
            #expect(a[name] == g[name], "\(name)")
            #expect(a[name]?.count == 5, "\(name)")
        }
    }

    // MARK: LLVM community calendar

    @Test func llvmFeedShape() throws {
        let feed = try Self.feed("llvm-community")
        #expect(feed.name == "calendar@llvm.org")
        #expect(feed.events.count == 947)
        #expect(feed.events.filter { $0.rule != nil }.count == 270)
        #expect(feed.events.filter { $0.recurrenceID != nil }.count == 514)
        // Every TZID in the feed is an IANA name the system knows.
        #expect(feed.events.allSatisfy { e in
            if e.allDay { return true }
            if case .named = e.start.zone { return true }
            return e.start.zone == .utc
        })
    }

    @Test func llvmBiweeklyPacificMeetingCrossesDaylightSaving() throws {
        let feed = try Self.feed("llvm-community")
        // DTSTART;TZID=America/Los_Angeles:20260331T090000, RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=TU, 50 minutes.
        let o = Self.occurrences(feed, "2026-10-01T00:00:00Z", "2026-12-01T00:00:00Z", title: "Modules discussion")
        #expect(o.map { Self.isoString($0.start) } == ["2026-10-13T16:00:00Z", "2026-10-27T16:00:00Z", "2026-11-10T17:00:00Z", "2026-11-24T17:00:00Z"])
        #expect(o.allSatisfy { $0.end.timeIntervalSince($0.start) == 50 * 60 })
        let first = try #require(o.first)
        #expect(first.location == "https://princeton.zoom.us/j/97915651167?pwd=MXJ1T2lhc3Z5QWlYbUFnMTZYQlNRdz09, US-SVL-CRSM1240-3-M-Roquefort (4) [GVC]")
        #expect(CalendarService.meetingURL(url: first.url, location: first.location, notes: first.notes)?.absoluteString
                == "https://princeton.zoom.us/j/97915651167?pwd=MXJ1T2lhc3Z5QWlYbUFnMTZYQlNRdz09")
    }

    @Test func llvmBerlinSeriesWithMovedInstance() throws {
        let feed = try Self.feed("llvm-community")
        // Biweekly Tuesdays 16:30 Berlin from 29 Sep; the 27 Oct instance was moved to 3 Nov (RECURRENCE-ID).
        let o = Self.occurrences(feed, "2026-09-28T00:00:00Z", "2026-12-01T00:00:00Z", title: "Lifetime Safety breakout group sync")
        #expect(o.map { Self.isoString($0.start) }
                == ["2026-09-29T14:30:00Z", "2026-10-13T14:30:00Z", "2026-11-03T15:30:00Z", "2026-11-10T15:30:00Z", "2026-11-24T15:30:00Z"])
    }

    @Test func llvmExdatesAndUntil() throws {
        let feed = try Self.feed("llvm-community")
        // EXDATE;TZID=Europe/Berlin:20261028T160000 removes one instance of a biweekly Wednesday meeting.
        let area = Self.occurrences(feed, "2026-10-01T00:00:00Z", "2026-12-01T00:00:00Z", title: "LLVM area team meeting")
        #expect(area.map { Self.isoString($0.start) } == ["2026-10-14T14:00:00Z", "2026-11-11T15:00:00Z", "2026-11-25T15:00:00Z"])
        // Fourth-Wednesday office hours (Europe/Brussels) with the same day excluded.
        let office = Self.occurrences(feed, "2026-10-20T00:00:00Z", "2026-12-01T00:00:00Z", title: "Kristof Beyls LLVM office hours")
        #expect(office.map { Self.isoString($0.start) } == ["2026-11-11T08:30:00Z", "2026-11-25T08:30:00Z"])
        // Asia/Kolkata, FREQ=MONTHLY;UNTIL=20270311T153000Z;BYDAY=2TH: UNTIL itself is the last instance.
        let openmp = Self.occurrences(feed, "2026-10-01T00:00:00Z", "2028-01-01T00:00:00Z", title: "OpenMP work for llvm-project/flang")
            .filter { $0.start >= Self.iso("2026-11-01T00:00:00Z") }
        #expect(openmp.map { Self.isoString($0.start) }
                == ["2026-11-12T15:30:00Z", "2026-12-10T15:30:00Z", "2027-01-14T15:30:00Z", "2027-02-11T15:30:00Z", "2027-03-11T15:30:00Z"])
    }

    @Test func feedDownloadsAreValidated() async throws {
        let (ics, body) = try await CalendarFeedService.decode(try Fixture.data("ics/wordpress-meetings-2026-10-27.ics"))
        #expect(ics.events.count == 37 && body.hasPrefix("BEGIN:VCALENDAR"))
        // A login page or error document instead of a calendar.
        await #expect(throws: CalendarFeedService.FeedError.self) {
            _ = try await CalendarFeedService.decode(Data("<!doctype html><title>Sign in</title>".utf8))
        }
    }

    @Test func llvmExpandsQuickly() throws {
        let data = try Fixture.data("ics/llvm-community-2026-10-27.ics")
        let clock = ContinuousClock()
        var count = 0
        let elapsed = clock.measure {
            let feed = ICS.parse(data)
            count = ICS.occurrences(feed.events, from: Self.iso("2026-10-27T00:00:00Z"), to: Self.iso("2026-11-04T00:00:00Z")).count
        }
        #expect(count > 10)
        #expect(elapsed < .seconds(3), "\(elapsed)")
    }

    // MARK: Make WordPress meetings

    @Test func wordpressRulesRunningForYears() throws {
        let feed = try Self.feed("wordpress-meetings")
        #expect(feed.name == "Making WordPress Meetings")
        #expect(feed.events.count == 37)
        // FREQ=MONTHLY;BYDAY=2TU,4TU since 26 May 2015.
        let themes = Self.occurrences(feed, "2026-11-01T00:00:00Z", "2026-12-01T00:00:00Z", title: "Themes: Themes Team Biweekly Chat")
        #expect(themes.map { Self.isoString($0.start) } == ["2026-11-10T15:00:00Z", "2026-11-24T15:00:00Z"])
        // FREQ=WEEKLY;INTERVAL=2 since 12 Dec 2017.
        let tide = Self.occurrences(feed, "2026-11-01T00:00:00Z", "2026-12-01T00:00:00Z", title: "Tide: Tide Weekly Chat")
        #expect(tide.map { Self.isoString($0.start) } == ["2026-11-03T18:00:00Z", "2026-11-17T18:00:00Z"])
        // FREQ=MONTHLY on the 28th with EXDATE:20261128T140000Z.
        let training = Self.occurrences(feed, "2026-10-01T00:00:00Z", "2027-01-01T00:00:00Z", title: "Training: Training Team  Office Hours")
        #expect(training.map { Self.isoString($0.start) } == ["2026-10-28T14:00:00Z", "2026-12-28T14:00:00Z"])
    }
}
