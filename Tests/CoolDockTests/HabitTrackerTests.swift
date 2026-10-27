import Foundation
import Testing
@testable import CoolDock

/// Habit Tracker day and streak math (`Widgets/Calendar/CalendarHabitModel.swift`).
@Suite struct HabitTrackerTests {
    let today = CalHabitDay(year: 2026, month: 6, day: 18) // Thursday

    private func habit(_ daysAgo: [Int], perWeek: Int? = nil, from today: CalHabitDay? = nil) -> CalHabit {
        let t = today ?? self.today
        return CalHabit(name: "H", symbol: "book.fill", color: "#30D158", perWeek: perWeek, days: daysAgo.map { t.adding(-$0).key }.sorted())
    }

    private static func calendar(_ zone: String, _ id: Calendar.Identifier = .gregorian, firstWeekday: Int = 1) -> Calendar {
        var c = Calendar(identifier: id)
        c.timeZone = TimeZone(identifier: zone)!
        c.firstWeekday = firstWeekday
        return c
    }

    private static func date(_ zone: String, _ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        calendar(zone).date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    // MARK: Civil days

    @Test func civilDaysMatchFoundation() {
        let g = Self.calendar("UTC")
        var date = Self.date("UTC", 1999, 12, 25, 12)
        for _ in 0..<3000 {
            let c = g.dateComponents([.year, .month, .day, .weekday], from: date)
            let day = CalHabitDay(year: c.year!, month: c.month!, day: c.day!)
            #expect(day.ymd == (c.year!, c.month!, c.day!))
            #expect(day.weekday == c.weekday!)
            #expect(CalHabitDay(key: day.key) == day)
            #expect(CalHabitDay(date, in: g) == day)
            date = g.date(byAdding: .day, value: 1, to: date)!
        }
        #expect(today.key == "2026-06-18")
        #expect(today.weekday == 5)
        #expect(CalHabitDay(year: 2028, month: 3, day: 1).adding(-1).key == "2028-02-29")
        #expect(CalHabitDay(key: "2026-13-01") == nil && CalHabitDay(key: "junk") == nil)
    }

    @Test func persianCalendarSameCivilDay() {
        // 28 Khordad 1405 is 18 June 2026; the stored key stays Gregorian whatever calendar the user reads it in.
        let persian = Self.calendar("Asia/Tehran", .persian, firstWeekday: 7)
        let date = persian.date(from: DateComponents(year: 1405, month: 3, day: 28, hour: 23, minute: 50))!
        #expect(CalHabitDay(date, in: persian) == today)
        #expect(CalHabitDay(date, in: persian).key == "2026-06-18")
        let back = persian.dateComponents([.year, .month, .day], from: today.date(in: persian))
        #expect(back.year == 1405 && back.month == 3 && back.day == 28)
    }

    @Test func toggleKeepsSortedKeys() {
        var h = habit([2, 0])
        h.toggle(today.adding(-1))
        #expect(h.days == ["2026-06-16", "2026-06-17", "2026-06-18"])
        h.toggle(today)
        #expect(h.days == ["2026-06-16", "2026-06-17"])
        #expect(!h.isChecked(today) && h.isChecked(today.adding(-1)))
    }

    @Test func storeRoundTrip() {
        let list = [habit([0, 1, 2]), habit([3], perWeek: 4)]
        #expect(CalHabitStore.decode(CalHabitStore.encode(list)) == list)
        #expect(CalHabitStore.decode("not json").isEmpty)
        #expect(CalHabitStore.decode(nil).isEmpty)
    }

    // MARK: Daily streaks

    @Test func dailyStreak() {
        let s = CalHabitMath.stats(habit([0, 1, 2, 3, 4, 6, 7]), today: today, firstWeekday: 1)
        #expect(s.unit == .days && s.current == 5 && s.best == 5 && s.doneToday && s.progress == 1)

        // Today still open: yesterday's run is alive.
        let open = CalHabitMath.stats(habit([1, 2, 3]), today: today, firstWeekday: 1)
        #expect(open.current == 3 && !open.doneToday && open.progress == 0)

        // Missed yesterday and today: broken.
        #expect(CalHabitMath.stats(habit([2, 3, 4]), today: today, firstWeekday: 1).current == 0)

        // Best run from history.
        let history = habit([0, 10, 11, 12, 13, 14, 15, 16, 30, 31])
        let hs = CalHabitMath.stats(history, today: today, firstWeekday: 1)
        #expect(hs.current == 1 && hs.best == 7)
        #expect(CalHabitMath.stats(habit([]), today: today, firstWeekday: 1) == CalHabitStats(unit: .days, current: 0, best: 0, doneToday: false, weekCount: 0, weekTarget: 7))
    }

    // MARK: Weekly goals

    @Test func weeklyGoalStreak() {
        // Sunday-first weeks; today is Thursday, so this week is daysAgo 0…4, week k back is 7k-2 … 7k+4.
        // Three earlier weeks with 3 check-ins, this week 2 so far (in progress: doesn't break the streak).
        let earlier = [6, 8, 10, 13, 15, 17, 20, 22, 24]
        let inProgress = CalHabitMath.stats(habit([1, 3] + earlier, perWeek: 3), today: today, firstWeekday: 1)
        #expect(inProgress.unit == .weeks && inProgress.current == 3 && inProgress.weekCount == 2 && inProgress.weekTarget == 3)
        #expect(abs(inProgress.progress - 2.0 / 3.0) < 1e-9)

        // Meeting the goal this week extends the streak.
        let met = CalHabitMath.stats(habit([0, 1, 3] + earlier, perWeek: 3), today: today, firstWeekday: 1)
        #expect(met.current == 4 && met.progress == 1 && met.best == 4)

        // A short week (only 2) in between ends the run; the best run is kept.
        let broken = CalHabitMath.stats(habit([0, 1, 3, 6, 8, 13, 15, 17, 20, 22, 24, 27, 29, 31], perWeek: 3), today: today, firstWeekday: 1)
        #expect(broken.current == 1 && broken.best == 3)

        // A finished week below the goal (last week) breaks it even while this week is open.
        #expect(CalHabitMath.stats(habit([1, 13, 15, 17], perWeek: 3), today: today, firstWeekday: 1).current == 0)

        // Goals are clamped to 1…6 a week.
        #expect(habit([], perWeek: 9).weeklyTarget == 6 && habit([], perWeek: 0).weeklyTarget == 1 && habit([]).weeklyTarget == nil)
    }

    @Test func persianWeeksStartOnSaturday() {
        // Friday 12 June and Saturday 13 June: one Sunday-first week, but two Saturday-first (Persian) weeks.
        let fri = today.adding(-6), sat = today.adding(-5)
        #expect(fri.weekday == 6 && sat.weekday == 7)
        #expect(fri.weekStart(1) == sat.weekStart(1))
        #expect(fri.weekStart(7) != sat.weekStart(7))
        #expect(sat.weekStart(7) == sat && today.weekStart(7) == sat)

        let h = habit([5, 6], perWeek: 1) // Sat 13, Fri 12
        let gregorian = CalHabitMath.stats(h, today: today, firstWeekday: 1)
        let persian = CalHabitMath.stats(h, today: today, firstWeekday: 7)
        #expect(gregorian.weekCount == 0 && gregorian.current == 1)   // both in last week
        #expect(persian.weekCount == 1 && persian.current == 2)       // this week (Sat) met, last week (Fri) met
    }

    // MARK: Clock changes

    @Test func dstDaysAreWholeDays() {
        // New York springs forward on 8 March 2026 and falls back on 1 November 2026.
        let ny = Self.calendar("America/New_York")
        let nights = [(3, 6), (3, 7), (3, 8), (3, 9), (3, 10)].map { Self.date("America/New_York", 2026, $0.0, $0.1, 23, 30) }
        let days = nights.map { CalHabitDay($0, in: ny) }
        #expect(zip(days, days.dropFirst()).allSatisfy { $1.number - $0.number == 1 })
        let h = CalHabit(name: "H", symbol: "s", color: "#000000", days: days.map(\.key))
        #expect(CalHabitMath.stats(h, today: days.last!, firstWeekday: 1).current == 5)

        // The trap integer days avoid: 24 hours after 23:30 on 7 March is already 9 March.
        let plus24h = nights[1].addingTimeInterval(86_400)
        #expect(CalHabitDay(plus24h, in: ny).key == "2026-03-09")

        // Early-morning check-ins around the fall-back night (25-hour day) stay one per day.
        let mornings = [(10, 31), (11, 1), (11, 2)].map { Self.date("America/New_York", 2026, $0.0, $0.1, 0, 30) }
        let fall = mornings.map { CalHabitDay($0, in: ny).key }
        #expect(fall == ["2026-10-31", "2026-11-01", "2026-11-02"])
        let plus24hFall = mornings[1].addingTimeInterval(86_400)
        #expect(CalHabitDay(plus24hFall, in: ny).key == "2026-11-01") // 24 h after 00:30 on 1 Nov is 23:30 the same day
    }

    @Test func timeZoneChange() {
        // Checked in Tehran on 15–17 June and at 01:00 on 18 June, then flew to Los Angeles where it is still 17 June.
        let tehran = Self.calendar("Asia/Tehran")
        let instants = [(15, 21), (16, 21), (17, 21), (18, 1)].map { Self.date("Asia/Tehran", 2026, 6, $0.0, $0.1) }
        let h = CalHabit(name: "H", symbol: "s", color: "#000000", days: instants.map { CalHabitDay($0, in: tehran).key })
        #expect(h.days == ["2026-06-15", "2026-06-16", "2026-06-17", "2026-06-18"])

        let la = Self.calendar("America/Los_Angeles")
        let now = Self.date("America/Los_Angeles", 2026, 6, 17, 15)
        let todayLA = CalHabitDay(now, in: la)
        #expect(todayLA.key == "2026-06-17")
        let s = CalHabitMath.stats(h, today: todayLA, firstWeekday: 1)
        // The stored days don't move with the clock, today counts as done, and the "tomorrow" check-in keeps the run.
        #expect(s.doneToday && s.current == 4)

        // Same instant seen from Tehran: it is already 18 June there.
        #expect(CalHabitDay(now, in: tehran).key == "2026-06-18")
    }

    // MARK: Grid

    @Test func twelveWeekGrid() {
        for first in [1, 2, 7] {
            let weeks = CalHabitMath.grid(weeks: 12, today: today, firstWeekday: first)
            #expect(weeks.count == 12 && weeks.allSatisfy { $0.count == 7 })
            #expect(weeks.allSatisfy { $0[0].weekday == first })
            #expect(weeks.last!.contains(today) && !weeks.dropLast().joined().contains(today))
            #expect(zip(weeks.joined(), weeks.joined().dropFirst()).allSatisfy { $1.number - $0.number == 1 })
        }
    }

    @MainActor @Test func tileWidthsAreWholePoints() {
        for n in 0...7 {
            let w = CalHabitWidget.width(cells: n)
            #expect(w == w.rounded() && w >= 62)
        }
        #expect(CalHabitWidget.width(cells: 3) == 148) // the catalog width
    }
}
