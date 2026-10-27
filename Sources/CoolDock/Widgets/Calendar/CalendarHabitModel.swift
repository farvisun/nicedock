import Foundation

// MARK: - Civil day

/// A calendar day without time or zone, stored as its Julian Day Number.
///
/// Check-ins are civil dates ("the 18th"), not instants: day arithmetic is integer arithmetic, so DST days with
/// 23 or 25 hours and time-zone changes never shift or split a check-in. Which civil day "now" is comes from the
/// user's calendar (`Fmt.calendar`, its time zone and first weekday); the Persian and Gregorian calendars share
/// midnight, so a day keeps its identity when the user switches calendars.
struct CalHabitDay: Hashable, Comparable {
    let number: Int

    init(number: Int) { self.number = number }

    /// Proleptic Gregorian year/month/day.
    init(year: Int, month: Int, day: Int) {
        let a = (14 - month) / 12
        let y = year + 4800 - a
        let m = month + 12 * a - 3
        number = day + (153 * m + 2) / 5 + 365 * y + y / 4 - y / 100 + y / 400 - 32045
    }

    /// The civil day `date` falls on in `calendar`'s time zone.
    init(_ date: Date, in calendar: Calendar) {
        var g = Calendar(identifier: .gregorian)
        g.timeZone = calendar.timeZone
        let c = g.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year ?? 2000, month: c.month ?? 1, day: c.day ?? 1)
    }

    /// Parses the stored "yyyy-MM-dd" form.
    init?(key: String) {
        let parts = key.split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    var ymd: (year: Int, month: Int, day: Int) {
        let a = number + 32044
        let b = (4 * a + 3) / 146_097
        let c = a - 146_097 * b / 4
        let d = (4 * c + 3) / 1461
        let e = c - 1461 * d / 4
        let m = (5 * e + 2) / 153
        return (100 * b + d - 4800 + m / 10, m + 3 - 12 * (m / 10), e - (153 * m + 2) / 5 + 1)
    }

    /// Stored form, always ASCII Gregorian ("2026-06-18") whatever calendar the user reads it in.
    var key: String {
        let v = ymd
        return String(format: "%04d-%02d-%02d", v.year, v.month, v.day)
    }

    /// 1 = Sunday … 7 = Saturday (the `Calendar` convention).
    var weekday: Int { (number + 1) % 7 + 1 }

    func adding(_ days: Int) -> CalHabitDay { CalHabitDay(number: number + days) }

    /// First day of the week containing this day, for a calendar whose weeks start on `firstWeekday`.
    func weekStart(_ firstWeekday: Int) -> CalHabitDay { adding(-((weekday - firstWeekday + 7) % 7)) }

    /// Noon of this day in `calendar`'s zone (for formatting with the user's calendar and locale).
    func date(in calendar: Calendar) -> Date {
        var g = Calendar(identifier: .gregorian)
        g.timeZone = calendar.timeZone
        let v = ymd
        return g.date(from: DateComponents(year: v.year, month: v.month, day: v.day, hour: 12)) ?? Date()
    }

    static func < (a: CalHabitDay, b: CalHabitDay) -> Bool { a.number < b.number }
}

// MARK: - Habit

struct CalHabit: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var symbol: String
    var color: String
    /// nil = every day; 1…6 = that many days a week.
    var perWeek: Int?
    /// Checked days, "yyyy-MM-dd", ascending.
    var days: [String] = []

    var checked: Set<CalHabitDay> { Set(days.compactMap(CalHabitDay.init(key:))) }

    func isChecked(_ day: CalHabitDay) -> Bool { days.contains(day.key) }

    mutating func toggle(_ day: CalHabitDay) {
        let k = day.key
        if let i = days.firstIndex(of: k) { days.remove(at: i) } else { days.append(k); days.sort() }
    }

    /// Weekly goal clamped to 1…6, or nil for a daily habit.
    var weeklyTarget: Int? { perWeek.map { max(1, min(6, $0)) } }
}

// MARK: - Streak math (pure; see HabitTrackerTests)

struct CalHabitStats: Equatable {
    enum Unit { case days, weeks }
    var unit: Unit
    /// Current streak: consecutive days (daily habits) or weeks that met the goal (weekly habits).
    var current: Int
    var best: Int
    var doneToday: Bool
    /// Check-ins in the current week.
    var weekCount: Int
    /// Days needed this week (7 for daily habits).
    var weekTarget: Int

    /// Ring fill on the tile: today for daily habits, the week's goal for weekly ones.
    var progress: Double {
        switch unit {
        case .days: return doneToday ? 1 : 0
        case .weeks: return min(1, Double(weekCount) / Double(max(1, weekTarget)))
        }
    }
}

enum CalHabitMath {
    static func stats(_ habit: CalHabit, today: CalHabitDay, firstWeekday: Int) -> CalHabitStats {
        let checked = habit.checked
        let week = today.weekStart(firstWeekday)
        let count = weekCount(checked, week: week)
        if let target = habit.weeklyTarget {
            return CalHabitStats(unit: .weeks, current: weeklyStreak(checked, target: target, today: today, firstWeekday: firstWeekday),
                                 best: bestWeeklyRun(checked, target: target, today: today, firstWeekday: firstWeekday),
                                 doneToday: checked.contains(today), weekCount: count, weekTarget: target)
        }
        return CalHabitStats(unit: .days, current: dailyStreak(checked, today: today), best: bestDailyRun(checked),
                             doneToday: checked.contains(today), weekCount: count, weekTarget: 7)
    }

    /// Consecutive checked days ending today — or yesterday, since today is still open. A check-in dated tomorrow
    /// (made in a zone that is already a day ahead, before travelling west) also extends the run.
    static func dailyStreak(_ checked: Set<CalHabitDay>, today: CalHabitDay) -> Int {
        [today.adding(1), today, today.adding(-1)].map { run(checked, endingAt: $0) }.max() ?? 0
    }

    static func run(_ checked: Set<CalHabitDay>, endingAt day: CalHabitDay) -> Int {
        var n = 0
        var d = day
        while checked.contains(d) { n += 1; d = d.adding(-1) }
        return n
    }

    static func bestDailyRun(_ checked: Set<CalHabitDay>) -> Int {
        var best = 0
        for d in checked where !checked.contains(d.adding(-1)) {
            var n = 1
            while checked.contains(d.adding(n)) { n += 1 }
            best = max(best, n)
        }
        return best
    }

    static func weekCount(_ checked: Set<CalHabitDay>, week start: CalHabitDay) -> Int {
        (0..<7).reduce(0) { $0 + (checked.contains(start.adding($1)) ? 1 : 0) }
    }

    /// Consecutive weeks that met `target`, ending with this week once it meets the goal, otherwise with last week
    /// (an unfinished week never breaks a streak).
    static func weeklyStreak(_ checked: Set<CalHabitDay>, target: Int, today: CalHabitDay, firstWeekday: Int) -> Int {
        var week = today.weekStart(firstWeekday)
        if weekCount(checked, week: week) < target { week = week.adding(-7) }
        var n = 0
        while weekCount(checked, week: week) >= target { n += 1; week = week.adding(-7) }
        return n
    }

    static func bestWeeklyRun(_ checked: Set<CalHabitDay>, target: Int, today: CalHabitDay, firstWeekday: Int) -> Int {
        guard let first = checked.min() else { return 0 }
        let last = max(today, checked.max() ?? today).weekStart(firstWeekday)
        var week = first.weekStart(firstWeekday)
        var best = 0, n = 0
        while week <= last {
            if weekCount(checked, week: week) >= target { n += 1; best = max(best, n) } else { n = 0 }
            week = week.adding(7)
        }
        return best
    }

    /// The last `weeks` weeks (oldest first), each as its seven days starting at the calendar's first weekday.
    static func grid(weeks: Int, today: CalHabitDay, firstWeekday: Int) -> [[CalHabitDay]] {
        let current = today.weekStart(firstWeekday)
        return (0..<weeks).reversed().map { back in
            let start = current.adding(-7 * back)
            return (0..<7).map { start.adding($0) }
        }
    }
}

// MARK: - Clock

enum CalHabitClock {
    /// The user's calendar (Persian for fa) in the current time zone, so "today" follows the Mac when it travels.
    static var calendar: Calendar {
        var cal = Fmt.calendar
        cal.timeZone = .current
        return cal
    }

    static func today(_ now: Date = Date()) -> CalHabitDay { CalHabitDay(ReferenceScene.date(now), in: calendar) }
}

// MARK: - Choices

enum CalHabitStyle {
    static let symbols = [
        "book.fill", "figure.run", "dumbbell.fill", "figure.walk", "bicycle", "figure.mind.and.body", "drop.fill", "leaf.fill",
        "bed.double.fill", "fork.knife", "cup.and.saucer.fill", "pills.fill", "heart.fill", "brain.head.profile", "pencil", "music.note",
        "guitars.fill", "paintbrush.fill", "graduationcap.fill", "laptopcomputer", "globe", "sun.max.fill", "moon.fill", "sparkles"
    ]
    /// The shared accents (Theme.swift) as hex so they persist in the widget config.
    static let colors = ["#30D158", "#0A84FF", "#FF9F0A", "#FF453A", "#FF375F", "#BF5AF2", "#5E5CE6", "#40C8E0", "#FFD60A", "#63E6E2"]

    /// Defaults for the n-th new habit, so a quick list of habits still gets distinct looks.
    static func fresh(_ name: String, index: Int) -> CalHabit {
        let looks = [("book.fill", "#FF9F0A"), ("figure.run", "#30D158"), ("drop.fill", "#0A84FF"), ("figure.mind.and.body", "#BF5AF2"),
                     ("pencil", "#FF375F"), ("bed.double.fill", "#5E5CE6"), ("leaf.fill", "#40C8E0"), ("music.note", "#FFD60A")]
        let look = looks[index % looks.count]
        return CalHabit(name: name, symbol: look.0, color: look.1, perWeek: nil)
    }
}
