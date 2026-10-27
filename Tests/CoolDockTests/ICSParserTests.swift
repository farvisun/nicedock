import Foundation
import SwiftUI
import Testing
@testable import CoolDock

/// Handcrafted iCalendar snippets, one RFC 5545 rule per test. RFC examples are quoted from §3.8.5.3.
@Suite struct ICSParserTests {
    static let utc = TimeZone(identifier: "UTC")!
    static let la = TimeZone(identifier: "America/Los_Angeles")!

    static func calendar(_ lines: [String]) -> String {
        (["BEGIN:VCALENDAR", "VERSION:2.0"] + lines + ["END:VCALENDAR"]).joined(separator: "\r\n") + "\r\n"
    }

    static func event(_ lines: [String]) -> String { calendar(["BEGIN:VEVENT"] + lines + ["END:VEVENT"]) }

    static func iso(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    static func expand(_ text: String, _ from: String, _ to: String, local: TimeZone = utc) -> [ICS.Occurrence] {
        ICS.occurrences(ICS.parse(text).events, from: iso(from), to: iso(to), local: local)
    }

    /// Start instants as ISO strings (UTC).
    static func starts(_ text: String, _ from: String, _ to: String, local: TimeZone = utc) -> [String] {
        expand(text, from, to, local: local).map { ISO8601DateFormatter().string(from: $0.start) }
    }

    static func series(_ dtstart: String, _ rule: String, extra: [String] = []) -> String {
        event(["UID:s", "SUMMARY:Series", dtstart, rule] + extra)
    }

    // MARK: Content lines

    @Test func unfoldsFoldedLines() {
        // CRLF + space, LF + tab, and a fold that splits "é" (C3 A9) between two lines.
        var bytes = Array("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:a\r\nDTSTART:20261027T090000Z\r\nSUMMARY:Caf".utf8)
        bytes += [0xC3, 0x0D, 0x0A, 0x20, 0xA9]
        bytes += Array(" au lait\n\tet croissant\r\nDESCRIPTION:line one\r\n  two\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n".utf8)
        let events = ICS.parse(Data(bytes)).events
        #expect(events.count == 1)
        #expect(events.first?.summary == "Café au laitet croissant")
        // Unfolding removes the line break and exactly one whitespace character.
        #expect(events.first?.notes == "line one two")
    }

    @Test func quotedParameters() throws {
        let p = try #require(ICS.property(Array(#"ATTENDEE;CN="Doe, Jane: PM";ROLE=REQ-PARTICIPANT:mailto:jane@example.com"#.utf8)))
        #expect(p.name == "ATTENDEE")
        #expect(p.params["CN"] == "Doe, Jane: PM")
        #expect(p.params["ROLE"] == "REQ-PARTICIPANT")
        #expect(p.value == "mailto:jane@example.com")

        let e = try #require(ICS.parse(Self.event(["UID:q", #"DTSTART;TZID="America/New_York":20260105T090000"#,
                                                    "summary;LANGUAGE=en:Stand-up"])).events.first)
        #expect(e.summary == "Stand-up")
        #expect(e.start.instant() == Self.iso("2026-01-05T14:00:00Z"))
    }

    @Test func textUnescaping() throws {
        let e = try #require(ICS.parse(Self.event(["UID:t", "DTSTART:20261027T090000Z", #"SUMMARY:Lunch\, then \;review\\notes"#,
                                                    #"DESCRIPTION:line 1\nline 2\NThree"#, #"LOCATION:Room 4\, Floor 2"#])).events.first)
        #expect(e.summary == #"Lunch, then ;review\notes"#)
        #expect(e.notes == "line 1\nline 2\nThree")
        #expect(e.location == "Room 4, Floor 2")
    }

    @Test func feedMetadata() {
        let feed = ICS.parse(Self.calendar(["X-WR-CALNAME:Team\\, Berlin", "X-APPLE-CALENDAR-COLOR:#ff2968FF"]))
        #expect(feed.name == "Team, Berlin")
        #expect(feed.color == "#FF2968")
        #expect(feed.events.isEmpty)
    }

    // MARK: Dates and times

    @Test func allDayDates() {
        let text = Self.calendar([
            "BEGIN:VEVENT", "UID:one", "DTSTART;VALUE=DATE:20261031", "SUMMARY:Halloween", "END:VEVENT",
            "BEGIN:VEVENT", "UID:three", "DTSTART;VALUE=DATE:20261102", "DTEND;VALUE=DATE:20261105", "SUMMARY:Trip", "END:VEVENT",
            "BEGIN:VEVENT", "UID:dur", "DTSTART;VALUE=DATE:20261110", "DURATION:P2D", "SUMMARY:Offsite", "END:VEVENT"
        ])
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let o = Self.expand(text, "2026-10-01T00:00:00Z", "2026-12-01T00:00:00Z", local: tokyo)
        #expect(o.map(\.title) == ["Halloween", "Trip", "Offsite"])
        #expect(o.allSatisfy({ $0.allDay }))
        // Midnight in the reader's zone; no DTEND means one day; DTEND is exclusive.
        #expect(o[0].start == Self.iso("2026-10-30T15:00:00Z") && o[0].end == Self.iso("2026-10-31T15:00:00Z"))
        #expect(o[1].start == Self.iso("2026-11-01T15:00:00Z") && o[1].end == Self.iso("2026-11-04T15:00:00Z"))
        #expect(o[2].end.timeIntervalSince(o[2].start) == 2 * 86_400)

        // A day that has 25 hours (US daylight saving ends on 1 Nov 2026) still runs midnight to midnight.
        let ny = Self.expand(Self.event(["UID:d", "DTSTART;VALUE=DATE:20261101", "SUMMARY:DST"]),
                             "2026-10-31T00:00:00Z", "2026-11-03T00:00:00Z", local: TimeZone(identifier: "America/New_York")!)
        #expect(ny.first?.start == Self.iso("2026-11-01T04:00:00Z"))
        #expect(ny.first?.end == Self.iso("2026-11-02T05:00:00Z"))
    }

    @Test func utcAndFloatingTimes() {
        let utcEvent = Self.event(["UID:u", "DTSTART:20261027T160000Z", "DTEND:20261027T163000Z", "SUMMARY:UTC"])
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        #expect(Self.expand(utcEvent, "2026-10-27T00:00:00Z", "2026-10-28T00:00:00Z", local: tokyo).first?.start == Self.iso("2026-10-27T16:00:00Z"))

        // Floating: the same wall clock wherever the reader is.
        let floating = Self.event(["UID:f", "DTSTART:20261027T090000", "DTEND:20261027T100000", "SUMMARY:Local"])
        #expect(Self.starts(floating, "2026-10-26T00:00:00Z", "2026-10-28T00:00:00Z", local: tokyo) == ["2026-10-27T00:00:00Z"])
        #expect(Self.starts(floating, "2026-10-26T00:00:00Z", "2026-10-28T00:00:00Z", local: Self.la) == ["2026-10-27T16:00:00Z"])
    }

    @Test func tzidAcrossDaylightSaving() throws {
        let text = Self.calendar([
            "BEGIN:VEVENT", "UID:a", "DTSTART;TZID=America/Los_Angeles:20261027T090000", "DTEND;TZID=America/Los_Angeles:20261027T095000", "SUMMARY:A", "END:VEVENT",
            "BEGIN:VEVENT", "UID:b", "DTSTART;TZID=America/Los_Angeles:20261103T090000", "SUMMARY:B", "END:VEVENT",
            "BEGIN:VEVENT", "UID:c", "DTSTART;TZID=Europe/Berlin:20261020T163000", "SUMMARY:C", "END:VEVENT",
            "BEGIN:VEVENT", "UID:d", "DTSTART;TZID=Europe/Berlin:20261027T163000", "SUMMARY:D", "END:VEVENT"
        ])
        let o = ICS.occurrences(ICS.parse(text).events, from: Self.iso("2026-10-01T00:00:00Z"), to: Self.iso("2026-12-01T00:00:00Z"))
        let byTitle = Dictionary(uniqueKeysWithValues: o.map { ($0.title, $0) })
        #expect(byTitle["A"]?.start == Self.iso("2026-10-27T16:00:00Z"))   // PDT, UTC-7
        #expect(byTitle["A"]?.end == Self.iso("2026-10-27T16:50:00Z"))
        #expect(byTitle["B"]?.start == Self.iso("2026-11-03T17:00:00Z"))   // PST, UTC-8
        #expect(byTitle["C"]?.start == Self.iso("2026-10-20T14:30:00Z"))   // CEST
        #expect(byTitle["D"]?.start == Self.iso("2026-10-27T15:30:00Z"))   // CET after 25 Oct
        let zone = try #require(ICS.parse(text).events.first?.start.zone)
        #expect(zone == .named(Self.la))
    }

    @Test func ambiguousAndMissingLocalTimes() {
        // 01:30 happens twice on 1 Nov 2026 in Los Angeles: the first (PDT) one counts.
        #expect(ICS.resolve(ICS.days(2026, 11, 1) * 86_400 + 5400, in: Self.la) == Int(Self.iso("2026-11-01T08:30:00Z").timeIntervalSince1970))
        // 02:30 doesn't exist on 8 Mar 2026: read with the offset before the gap (PST), i.e. 03:30 PDT.
        #expect(ICS.resolve(ICS.days(2026, 3, 8) * 86_400 + 9000, in: Self.la) == Int(Self.iso("2026-03-08T10:30:00Z").timeIntervalSince1970))
        // Berlin's repeated 02:30 on 25 Oct 2026: CEST first.
        let berlin = TimeZone(identifier: "Europe/Berlin")!
        #expect(ICS.resolve(ICS.days(2026, 10, 25) * 86_400 + 9000, in: berlin) == Int(Self.iso("2026-10-25T00:30:00Z").timeIntervalSince1970))
    }

    @Test func unknownTZIDsFallBack() throws {
        let vtimezone = [
            "BEGIN:VTIMEZONE", "TZID:Customized Time Zone",
            "BEGIN:STANDARD", "DTSTART:16010101T020000", "TZOFFSETFROM:-0700", "TZOFFSETTO:-0800", "RRULE:FREQ=YEARLY;BYDAY=1SU;BYMONTH=11", "END:STANDARD",
            "BEGIN:DAYLIGHT", "DTSTART:16010101T020000", "TZOFFSETFROM:-0800", "TZOFFSETTO:-0700", "RRULE:FREQ=YEARLY;BYDAY=2SU;BYMONTH=3", "END:DAYLIGHT",
            "END:VTIMEZONE",
            "BEGIN:VTIMEZONE", "TZID:Berlin office", "X-LIC-LOCATION:Europe/Berlin", "END:VTIMEZONE"
        ]
        func ev(_ uid: String, _ dtstart: String) -> [String] { ["BEGIN:VEVENT", "UID:\(uid)", "SUMMARY:\(uid)", dtstart, "END:VEVENT"] }
        let text = Self.calendar(vtimezone
            + ev("windows", "DTSTART;TZID=Pacific Standard Time:20260701T100000")
            + ev("mozilla", "DTSTART;TZID=/mozilla.org/20050126_1/America/New_York:20260701T100000")
            + ev("lic", "DTSTART;TZID=Berlin office:20260701T100000")
            + ev("rulesSummer", "DTSTART;TZID=Customized Time Zone:20260701T100000")
            + ev("rulesWinter", "DTSTART;TZID=Customized Time Zone:20261201T100000")
            + ev("rulesBeforeSwitch", "DTSTART;TZID=Customized Time Zone:20261101T003000")
            + ev("rulesAfterSwitch", "DTSTART;TZID=Customized Time Zone:20261101T030000")
            + ev("unknown", "DTSTART;TZID=Nowhere/Special:20260701T100000"))
        let events = Dictionary(uniqueKeysWithValues: ICS.parse(text).events.map { ($0.uid, $0) })
        func at(_ uid: String) -> Date? { events[uid]?.start.instant(local: Self.utc) }
        #expect(at("windows") == Self.iso("2026-07-01T17:00:00Z"))
        #expect(at("mozilla") == Self.iso("2026-07-01T14:00:00Z"))
        #expect(at("lic") == Self.iso("2026-07-01T08:00:00Z"))
        #expect(at("rulesSummer") == Self.iso("2026-07-01T17:00:00Z"))
        #expect(at("rulesWinter") == Self.iso("2026-12-01T18:00:00Z"))
        #expect(at("rulesBeforeSwitch") == Self.iso("2026-11-01T07:30:00Z"))
        #expect(at("rulesAfterSwitch") == Self.iso("2026-11-01T11:00:00Z"))
        guard case .rules = try #require(events["rulesSummer"]).start.zone else { Issue.record("expected VTIMEZONE rules"); return }
        // No definition at all: read as local (floating) time rather than dropped.
        #expect(events["unknown"]?.start.zone == .floating)
        #expect(at("unknown") == Self.iso("2026-07-01T10:00:00Z"))
    }

    @Test func durations() {
        #expect(ICS.duration("PT1H30M") == .init(days: 0, seconds: 5400))
        #expect(ICS.duration("P1D") == .init(days: 1, seconds: 0))
        #expect(ICS.duration("P2W") == .init(days: 14, seconds: 0))
        #expect(ICS.duration("-PT15M") == .init(days: 0, seconds: -900))
        #expect(ICS.duration("P1DT12H") == .init(days: 1, seconds: 43_200))
        #expect(ICS.duration("+PT45S") == .init(days: 0, seconds: 45))
        for bad in ["", "P", "PT", "1H", "PT1D", "P1H", "PXD"] { #expect(ICS.duration(bad) == nil, "\(bad)") }

        // DURATION instead of DTEND: exact hours, nominal days (P1D over the DST change is 25 h).
        let text = Self.calendar([
            "BEGIN:VEVENT", "UID:h", "SUMMARY:Hours", "DTSTART;TZID=America/Los_Angeles:20261027T090000", "DURATION:PT1H30M", "END:VEVENT",
            "BEGIN:VEVENT", "UID:d", "SUMMARY:Day", "DTSTART;TZID=America/Los_Angeles:20261031T090000", "DURATION:P1D", "END:VEVENT"
        ])
        let o = Self.expand(text, "2026-10-26T00:00:00Z", "2026-11-05T00:00:00Z")
        #expect(o.first { $0.title == "Hours" }?.end == Self.iso("2026-10-27T17:30:00Z"))
        #expect(o.first { $0.title == "Day" }?.end == Self.iso("2026-11-01T17:00:00Z"))
    }

    // MARK: Status

    @Test func cancelledEventsAreSkipped() {
        let text = Self.calendar([
            "BEGIN:VEVENT", "UID:gone", "SUMMARY:Gone", "DTSTART:20261028T100000Z", "STATUS:CANCELLED", "END:VEVENT",
            "BEGIN:VEVENT", "UID:series-gone", "SUMMARY:Series gone", "DTSTART:20261026T100000Z", "RRULE:FREQ=DAILY", "STATUS:cancelled", "END:VEVENT",
            "BEGIN:VEVENT", "UID:w", "SUMMARY:Weekly", "DTSTART:20261026T120000Z", "RRULE:FREQ=WEEKLY;COUNT=3", "STATUS:CONFIRMED", "END:VEVENT",
            // One instance of the weekly series was called off.
            "BEGIN:VEVENT", "UID:w", "SUMMARY:Weekly", "RECURRENCE-ID:20261102T120000Z", "DTSTART:20261102T120000Z", "STATUS:CANCELLED", "END:VEVENT"
        ])
        let o = Self.expand(text, "2026-10-20T00:00:00Z", "2026-12-01T00:00:00Z")
        #expect(o.map { ISO8601DateFormatter().string(from: $0.start) } == ["2026-10-26T12:00:00Z", "2026-11-09T12:00:00Z"])
        #expect(o.allSatisfy { $0.title == "Weekly" })
    }

    // MARK: Recurrence

    @Test func dailyIntervalCount() {
        let text = Self.series("DTSTART:20261101T080000Z", "RRULE:FREQ=DAILY;INTERVAL=2;COUNT=4")
        #expect(Self.starts(text, "2026-10-01T00:00:00Z", "2027-01-01T00:00:00Z")
                == ["2026-11-01T08:00:00Z", "2026-11-03T08:00:00Z", "2026-11-05T08:00:00Z", "2026-11-07T08:00:00Z"])
    }

    @Test func dailyFilteredByWeekday() {
        // Work days only (a common Google/Outlook shape).
        let text = Self.series("DTSTART:20261030T090000Z", "RRULE:FREQ=DAILY;BYDAY=MO,TU,WE,TH,FR;COUNT=4")
        #expect(Self.starts(text, "2026-10-01T00:00:00Z", "2027-01-01T00:00:00Z")
                == ["2026-10-30T09:00:00Z", "2026-11-02T09:00:00Z", "2026-11-03T09:00:00Z", "2026-11-04T09:00:00Z"])
    }

    @Test func weeklyByDay() {
        let text = Self.series("DTSTART;TZID=Europe/Berlin:20261102T100000", "RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR;COUNT=6")
        #expect(Self.starts(text, "2026-10-01T00:00:00Z", "2027-01-01T00:00:00Z")
                == ["2026-11-02T09:00:00Z", "2026-11-04T09:00:00Z", "2026-11-06T09:00:00Z",
                    "2026-11-09T09:00:00Z", "2026-11-11T09:00:00Z", "2026-11-13T09:00:00Z"])
    }

    @Test func weekStartChangesBiweeklyResults() {
        // RFC 5545: "An example where the days generated makes a difference because of WKST".
        let mo = Self.series("DTSTART;TZID=America/New_York:19970805T090000", "RRULE:FREQ=WEEKLY;INTERVAL=2;COUNT=4;BYDAY=TU,SU;WKST=MO")
        #expect(Self.starts(mo, "1997-08-01T00:00:00Z", "1997-10-01T00:00:00Z")
                == ["1997-08-05T13:00:00Z", "1997-08-10T13:00:00Z", "1997-08-19T13:00:00Z", "1997-08-24T13:00:00Z"])
        let su = Self.series("DTSTART;TZID=America/New_York:19970805T090000", "RRULE:FREQ=WEEKLY;INTERVAL=2;COUNT=4;BYDAY=TU,SU;WKST=SU")
        #expect(Self.starts(su, "1997-08-01T00:00:00Z", "1997-10-01T00:00:00Z")
                == ["1997-08-05T13:00:00Z", "1997-08-17T13:00:00Z", "1997-08-19T13:00:00Z", "1997-08-31T13:00:00Z"])
    }

    @Test func monthlyRules() {
        // RFC 5545: "Monthly on the first Friday for 10 occurrences".
        let firstFriday = Self.series("DTSTART;TZID=America/New_York:19970905T090000", "RRULE:FREQ=MONTHLY;COUNT=10;BYDAY=1FR")
        let days = Self.expand(firstFriday, "1997-01-01T00:00:00Z", "1999-01-01T00:00:00Z").map { ICSFeedTests.day($0.start, TimeZone(identifier: "America/New_York")!) }
        #expect(days == ["1997-09-05", "1997-10-03", "1997-11-07", "1997-12-05", "1998-01-02",
                         "1998-02-06", "1998-03-06", "1998-04-03", "1998-05-01", "1998-06-05"])

        // RFC 5545: "Monthly on the second-to-last Monday of the month for 6 months".
        let secondLast = Self.series("DTSTART;TZID=America/New_York:19970922T090000", "RRULE:FREQ=MONTHLY;COUNT=6;BYDAY=-2MO")
        #expect(Self.expand(secondLast, "1997-01-01T00:00:00Z", "1999-01-01T00:00:00Z").map { ICSFeedTests.day($0.start, Self.utc) }
                == ["1997-09-22", "1997-10-20", "1997-11-17", "1997-12-22", "1998-01-19", "1998-02-16"])

        // Last day of the month, and DTSTART on the 31st skipping shorter months.
        let lastDay = Self.series("DTSTART;VALUE=DATE:20260131", "RRULE:FREQ=MONTHLY;BYMONTHDAY=-1;COUNT=4")
        #expect(Self.expand(lastDay, "2026-01-01T00:00:00Z", "2027-01-01T00:00:00Z").map { ICSFeedTests.day($0.start, Self.utc) }
                == ["2026-01-31", "2026-02-28", "2026-03-31", "2026-04-30"])
        let the31st = Self.series("DTSTART;VALUE=DATE:20260131", "RRULE:FREQ=MONTHLY;COUNT=5")
        #expect(Self.expand(the31st, "2026-01-01T00:00:00Z", "2027-01-01T00:00:00Z").map { ICSFeedTests.day($0.start, Self.utc) }
                == ["2026-01-31", "2026-03-31", "2026-05-31", "2026-07-31", "2026-08-31"])

        // RFC 5545: "The last work day of the month" (BYSETPOS).
        let lastWorkday = Self.series("DTSTART:20261030T170000Z", "RRULE:FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1;COUNT=3")
        #expect(Self.starts(lastWorkday, "2026-01-01T00:00:00Z", "2027-02-01T00:00:00Z")
                == ["2026-10-30T17:00:00Z", "2026-11-30T17:00:00Z", "2026-12-31T17:00:00Z"])
    }

    @Test func yearlyRules() {
        // US Thanksgiving: fourth Thursday in November.
        let thanksgiving = Self.series("DTSTART;VALUE=DATE:20261126", "RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=4TH;COUNT=3")
        #expect(Self.expand(thanksgiving, "2026-01-01T00:00:00Z", "2030-01-01T00:00:00Z").map { ICSFeedTests.day($0.start, Self.utc) }
                == ["2026-11-26", "2027-11-25", "2028-11-23"])
        // 29 February only exists in leap years.
        let leap = Self.series("DTSTART;VALUE=DATE:20240229", "RRULE:FREQ=YEARLY;COUNT=3")
        #expect(Self.expand(leap, "2024-01-01T00:00:00Z", "2040-01-01T00:00:00Z").map { ICSFeedTests.day($0.start, Self.utc) }
                == ["2024-02-29", "2028-02-29", "2032-02-29"])
        // US Memorial Day: last Monday in May, every other year.
        let memorial = Self.series("DTSTART;VALUE=DATE:20260525", "RRULE:FREQ=YEARLY;INTERVAL=2;BYMONTH=5;BYDAY=-1MO;COUNT=3")
        #expect(Self.expand(memorial, "2026-01-01T00:00:00Z", "2040-01-01T00:00:00Z").map { ICSFeedTests.day($0.start, Self.utc) }
                == ["2026-05-25", "2028-05-29", "2030-05-27"])
    }

    @Test func untilIsInclusive() {
        // UTC UNTIL on a TZID series (the LLVM "OpenMP work for flang" shape): the instance at UNTIL is included.
        let monthly = Self.series("DTSTART;TZID=Asia/Kolkata:20261112T210000", "RRULE:FREQ=MONTHLY;UNTIL=20270311T153000Z;INTERVAL=1;BYDAY=2TH")
        #expect(Self.starts(monthly, "2026-01-01T00:00:00Z", "2028-01-01T00:00:00Z")
                == ["2026-11-12T15:30:00Z", "2026-12-10T15:30:00Z", "2027-01-14T15:30:00Z", "2027-02-11T15:30:00Z", "2027-03-11T15:30:00Z"])
        // DATE UNTIL on an all-day series.
        let daily = Self.series("DTSTART;VALUE=DATE:20261101", "RRULE:FREQ=DAILY;UNTIL=20261105")
        #expect(Self.expand(daily, "2026-10-01T00:00:00Z", "2026-12-01T00:00:00Z").count == 5)
        // Floating UNTIL is read in DTSTART's zone.
        let local = Self.series("DTSTART;TZID=America/Los_Angeles:20261102T090000", "RRULE:FREQ=DAILY;UNTIL=20261104T090000")
        #expect(Self.starts(local, "2026-10-01T00:00:00Z", "2026-12-01T00:00:00Z").count == 3)
    }

    @Test func exdatesRemoveInstances() {
        let text = Self.series("DTSTART;TZID=America/Los_Angeles:20261102T090000", "RRULE:FREQ=DAILY;COUNT=6", extra: [
            "EXDATE;TZID=America/Los_Angeles:20261103T090000,20261105T090000",
            "EXDATE:20261106T170000Z"
        ])
        #expect(Self.starts(text, "2026-10-01T00:00:00Z", "2026-12-01T00:00:00Z")
                == ["2026-11-02T17:00:00Z", "2026-11-04T17:00:00Z", "2026-11-07T17:00:00Z"])
        let allDay = Self.series("DTSTART;VALUE=DATE:20261101", "RRULE:FREQ=DAILY;COUNT=4", extra: ["EXDATE;VALUE=DATE:20261102,20261104"])
        #expect(Self.expand(allDay, "2026-10-01T00:00:00Z", "2026-12-01T00:00:00Z").map { ICSFeedTests.day($0.start, Self.utc) }
                == ["2026-11-01", "2026-11-03"])
    }

    @Test func recurrenceIDMovesAnInstance() {
        let text = Self.calendar([
            "BEGIN:VEVENT", "UID:sync", "SUMMARY:Sync", "DTSTART;TZID=Europe/Berlin:20261013T163000", "DTEND;TZID=Europe/Berlin:20261013T173000",
            "RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=TU", "END:VEVENT",
            "BEGIN:VEVENT", "UID:sync", "SUMMARY:Sync (moved)", "RECURRENCE-ID;TZID=Europe/Berlin:20261027T163000",
            "DTSTART;TZID=Europe/Berlin:20261029T120000", "DTEND;TZID=Europe/Berlin:20261029T130000", "END:VEVENT"
        ])
        let o = Self.expand(text, "2026-10-12T00:00:00Z", "2026-11-15T00:00:00Z")
        #expect(o.map(\.title) == ["Sync", "Sync (moved)", "Sync"])
        #expect(o.map { ISO8601DateFormatter().string(from: $0.start) } == ["2026-10-13T14:30:00Z", "2026-10-29T11:00:00Z", "2026-11-10T15:30:00Z"])
        #expect(o[1].end.timeIntervalSince(o[1].start) == 3600)
    }

    @Test func rdatesAddInstances() {
        let text = Self.series("DTSTART:20261102T100000Z", "RRULE:FREQ=WEEKLY;COUNT=2", extra: ["RDATE:20261104T150000Z,20261120T100000Z"])
        #expect(Self.starts(text, "2026-10-01T00:00:00Z", "2026-12-01T00:00:00Z")
                == ["2026-11-02T10:00:00Z", "2026-11-04T15:00:00Z", "2026-11-09T10:00:00Z", "2026-11-20T10:00:00Z"])
    }

    @Test func longRunningSeriesSkipAhead() {
        // No COUNT: whole periods before the window are skipped; with COUNT every instance is walked. Same result.
        let window = ("2026-11-01T00:00:00Z", "2026-12-01T00:00:00Z")
        for rule in ["FREQ=DAILY;INTERVAL=3", "FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,TH", "FREQ=MONTHLY;BYDAY=2WE,-1FR", "FREQ=YEARLY;BYMONTH=11;BYDAY=1SU"] {
            let open = Self.series("DTSTART:20100101T080000Z", "RRULE:" + rule)
            let counted = Self.series("DTSTART:20100101T080000Z", "RRULE:" + rule + ";COUNT=100000")
            let a = Self.starts(open, window.0, window.1), b = Self.starts(counted, window.0, window.1)
            #expect(!a.isEmpty && a == b, "\(rule)")
        }
        let daily = Self.expand(Self.series("DTSTART:20100101T080000Z", "RRULE:FREQ=DAILY;INTERVAL=3"), window.0, window.1)
        #expect(daily.count == 10)
        #expect(daily.allSatisfy { ICS.floorDiv(Int($0.start.timeIntervalSince1970), 86_400) % 3 == ICS.days(2010, 1, 1) % 3 })
    }

    @Test func subDailyRulesShowOnce() {
        let text = Self.series("DTSTART:20261102T100000Z", "RRULE:FREQ=HOURLY;COUNT=5")
        #expect(ICS.parse(text).events.first?.rule == nil)
        #expect(Self.starts(text, "2026-11-01T00:00:00Z", "2026-11-03T00:00:00Z") == ["2026-11-02T10:00:00Z"])
    }

    @Test func ruleParsing() throws {
        let r = try #require(ICS.Rule("FREQ=MONTHLY;INTERVAL=2;BYDAY=+2TU,-1FR,SA;BYMONTHDAY=1,-3;BYMONTH=1,6;BYSETPOS=1,-1;WKST=SU;COUNT=7", zone: .utc))
        #expect(r.freq == .monthly && r.interval == 2 && r.count == 7 && r.weekStart == 0)
        #expect(r.byDay == [.init(ordinal: 2, weekday: 2), .init(ordinal: -1, weekday: 5), .init(ordinal: 0, weekday: 6)])
        #expect(r.byMonthDay == [1, -3] && r.byMonth == [1, 6] && r.bySetPos == [1, -1])
        #expect(ICS.Rule("INTERVAL=2", zone: .utc) == nil)
        #expect(ICS.Rule("FREQ=SECONDLY", zone: .utc) == nil)
    }

    // MARK: Meeting links (shared with EventKit events)

    @Test func meetingLinks() {
        // Zoom in LOCATION followed by a room name: the comma isn't part of the link.
        #expect(CalendarService.meetingURL(url: nil, location: "https://princeton.zoom.us/j/979?pwd=MXJ1, Room 4", notes: nil)?.absoluteString
                == "https://princeton.zoom.us/j/979?pwd=MXJ1")
        // A meeting URL property wins; a plain URL property loses to a meeting link in the notes.
        #expect(CalendarService.meetingURL(url: URL(string: "https://meet.google.com/abc-defg-hij"), location: "Office", notes: nil)?.absoluteString
                == "https://meet.google.com/abc-defg-hij")
        #expect(CalendarService.meetingURL(url: URL(string: "https://example.com/agenda"), location: nil,
                                           notes: "Join: https://teams.microsoft.com/l/meetup-join/19%3a1 (Teams).")?.absoluteString
                == "https://teams.microsoft.com/l/meetup-join/19%3a1")
        #expect(CalendarService.meetingURL(url: URL(string: "https://example.com/agenda"), location: "Room 1", notes: "Bring slides")?.absoluteString
                == "https://example.com/agenda")
        #expect(CalendarService.meetingURL(url: nil, location: "Room 1", notes: nil) == nil)
    }

    // MARK: Feed links

    @Test func feedLinkNormalization() {
        #expect(CalendarFeed.normalize("webcal://p23-calendars.icloud.com/published/2/abc")?.absoluteString == "https://p23-calendars.icloud.com/published/2/abc")
        #expect(CalendarFeed.normalize("  WEBCALS://example.com/cal.ics \n")?.absoluteString == "https://example.com/cal.ics")
        #expect(CalendarFeed.normalize("calendar.google.com/calendar/ical/x/public/basic.ics")?.absoluteString
                == "https://calendar.google.com/calendar/ical/x/public/basic.ics")
        #expect(CalendarFeed.normalize("http://intranet.example.org/team.ics")?.scheme == "http")
        for bad in ["", "ftp://example.com/a.ics", "file:///Users/me/a.ics", "not a link", "https://", "mailto:a@b.c"] {
            #expect(CalendarFeed.normalize(bad) == nil, "\(bad)")
        }
    }

    @Test func secretFeedLinks() {
        func secret(_ s: String) -> Bool { CalendarFeed.isSecret(CalendarFeed.normalize(s)!) }
        // Google "secret address in iCal format" vs the public address.
        #expect(secret("https://calendar.google.com/calendar/ical/jane%40gmail.com/private-0123456789abcdef0123456789abcdef/basic.ics"))
        #expect(!secret("https://calendar.google.com/calendar/ical/en.usa%23holiday%40group.v.calendar.google.com/public/basic.ics"))
        #expect(!secret("https://calendar.google.com/calendar/ical/calendar%40llvm.org/public/basic.ics"))
        // iCloud published calendars carry a token; Apple's holiday calendars are public.
        #expect(secret("webcal://p52-caldav.icloud.com/published/2/MTIzNDU2Nzg5MDEyMzQ1Ngabcdefghij"))
        #expect(!secret("https://calendars.icloud.com/holidays/us_en.ics"))
        #expect(secret("https://outlook.office365.com/owa/calendar/1a2b3c4d@example.com/5e6f7a8b9c0d1e2f3a4b/calendar.ics"))
        #expect(secret("https://user.fm/calendar/v1-0123456789abcdef/Calendar.ics"))
        #expect(secret("https://example.com/feed.ics?token=abc"))
        #expect(secret("https://me:pw@example.com/feed.ics"))
        #expect(secret("https://cal.example.com/u/9f8e7d6c5b4a39281706f5e4/feed"))
        #expect(!secret("https://make.wordpress.org/meetings.ics"))
        #expect(!secret("https://www.example.edu/events/academic-calendar.ics"))
    }

    // MARK: Merging with Calendar events

    @MainActor @Test func mergeDropsDuplicatesAndSorts() {
        func e(_ id: String, _ title: String, _ start: String, allDay: Bool = false) -> DockEvent {
            DockEvent(id: id, title: title, start: Self.iso(start), end: Self.iso(start).addingTimeInterval(3600), allDay: allDay,
                      color: .blue, calendar: id, meetingURL: nil, location: nil)
        }
        let merged = CalendarService.merge([
            e("ek1", "Standup", "2026-10-28T09:00:00Z"), e("ek2", "Review", "2026-10-27T15:00:00Z"),
            e("feed1", "standup", "2026-10-28T09:00:00Z"), e("feed2", "Halloween", "2026-10-28T09:00:00Z", allDay: true),
            e("feed3", "Standup", "2026-10-29T09:00:00Z")
        ])
        #expect(merged.map(\.id) == ["ek2", "ek1", "feed2", "feed3"])
    }
}
