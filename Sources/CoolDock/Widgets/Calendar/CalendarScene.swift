import SwiftUI

/// Reference-scene data for this family (see `ReferenceScene`). Returns nil for kinds it doesn't own.
///
/// The frames were captured on Thursday 18 June 2026; each widget gets the events, reminders and clock its frame shows.
enum CalendarScene {
    @MainActor static func prepare(_ kind: WidgetKind, _ variant: String?) -> [String: String]? {
        let at = WeatherScene.at
        switch kind {
        case .agenda, .calendarToday:
            // Two visible events plus three more later the same evening ("+3").
            set(events: [
                event("standup", "Team standup", at(2026, 6, 18, 21, 30), at(2026, 6, 18, 22, 0), "#007AFF"),
                event("review", "Design review", at(2026, 6, 18, 23, 30), at(2026, 6, 19, 0, 30), "#AF52DE"),
                event("x1", "Focus", at(2026, 6, 18, 23, 40), at(2026, 6, 18, 23, 50), "#34C759"),
                event("x2", "Call", at(2026, 6, 18, 23, 45), at(2026, 6, 18, 23, 55), "#FF9500"),
                event("x3", "Wrap-up", at(2026, 6, 18, 23, 50), at(2026, 6, 18, 23, 59), "#007AFF")
            ])
        case .nextMeeting:
            ReferenceScene.now = at(2026, 6, 18, 10, 22)
            set(events: [event("sync", "Product Sync", at(2026, 6, 18, 10, 30), at(2026, 6, 18, 11, 15), "#007AFF",
                               url: URL(string: "https://zoom.us/j/0"))])
        case .weekStrip:
            set(events: [])
            WeatherScene.seed()
        case .reminders:
            // Low priority ("!") due tonight, a date-only one tomorrow, and an overdue one.
            set(events: [], reminders: [
                reminder("Send invoice", at(2026, 6, 18, 22, 24), "#007AFF", priority: 9),
                reminder("Buy groceries", at(2026, 6, 19, 0, 0), "#34C759"),
                reminder("Call dentist", at(2026, 6, 17, 0, 0), "#FF9500")
            ])
        case .dayProgress:
            ReferenceScene.now = at(2026, 6, 18, 20, 30)   // 85 %, 21 of 24 hours lit
        case .monthProgress:
            ReferenceScene.now = at(2026, 6, 19, 0, 0)     // exactly 18 of 30 days: 60 %
        case .yearProgress:
            ReferenceScene.now = at(2026, 6, 25, 8, 0)     // 48 %, 25 of 52 weeks lit
        case .habitTracker:
            // Thursday 18 June: four habits, two checked today. Variants: -empty (no habits), and the panel as -panel,
            // -weeks, -editor and -new (panel without habits). Panels skip the blur ImageRenderer can't draw.
            if CalHabitPanel.sceneVariant != nil { AppStore.shared.settings.reduceTransparency = true }
            if variant == "empty" || variant == "new" { return [:] }
            let today = CalHabitDay(ReferenceScene.now, in: CalHabitClock.calendar)
            return ["habits": CalHabitStore.encode(CalHabitSamples.list(today: today)), "view": "week"]
        default:
            return nil
        }
        return [:]
    }

    @MainActor private static func set(events: [DockEvent], reminders: [DockReminder] = []) {
        CalendarService.shared.setSceneData(events: events, reminders: reminders)
    }

    /// Scene content, not UI copy: built positionally so the l10n extractor doesn't take the titles for keys.
    private static func reminder(_ name: String, _ due: Date, _ hex: String, priority: Int = 0) -> DockReminder {
        DockReminder(id: name, title: name, due: due, color: Color(hex: hex), priority: priority)
    }

    private static func event(_ id: String, _ title: String, _ start: Date, _ end: Date, _ hex: String, url: URL? = nil) -> DockEvent {
        DockEvent(id: id, title: title, start: start, end: end, allDay: false, color: Color(hex: hex), calendar: "Work", meetingURL: url, location: nil)
    }
}

/// Believable habit history relative to `today` (reference scene and the widget browser preview). Built positionally
/// so the l10n extractor doesn't take the names for keys; Persian renders get Persian names.
enum CalHabitSamples {
    static func list(today: CalHabitDay) -> [CalHabit] {
        let fa = Localizer.language == .fa
        // Read: 12-day streak after an earlier 21-day run. Workout: 3 a week, 2 of 3 so far this week, six full weeks before.
        let readOlder: [Int] = [36, 38, 41, 44, 45, 47, 50, 52, 55, 57, 60, 61, 63, 66, 70, 73, 77, 80]
        let read: [Int] = Array(0...11) + Array(13...33) + readOlder
        let fullWeeks: [Int] = (1...6).flatMap { (k: Int) -> [Int] in [7 * k + 3, 7 * k + 1, 7 * k - 1] }
        let workout: [Int] = [3, 1] + fullWeeks + [52, 59, 66, 68, 70, 73, 75, 77]
        let meditateOlder: [Int] = [8, 9, 10, 12, 15, 16, 20, 22, 23, 24, 25, 29, 31, 36, 37, 40, 43, 44, 45, 50, 51, 55, 58, 62, 64, 69, 71, 75, 78, 82]
        let meditate: [Int] = Array(1...5) + meditateOlder
        let water = [0, 1, 2, 4, 5, 7, 9, 10, 11, 12, 14, 17, 18, 21, 24, 25, 26, 28, 31, 33, 34, 35, 38, 42, 45, 46, 49, 52, 53, 56, 59, 60, 63, 67, 70, 74, 77, 81]
        return [
            habit(1, fa ? "مطالعه" : "Read", "book.fill", "#FF9F0A", nil, read, today),
            habit(2, fa ? "ورزش" : "Workout", "figure.run", "#30D158", 3, workout, today),
            habit(3, fa ? "مدیتیشن" : "Meditate", "figure.mind.and.body", "#BF5AF2", nil, meditate, today),
            habit(4, fa ? "نوشیدن آب" : "Drink water", "drop.fill", "#0A84FF", nil, water, today)
        ]
    }

    /// `daysAgo` are offsets back from `today`.
    private static func habit(_ n: Int, _ name: String, _ symbol: String, _ hex: String, _ perWeek: Int?, _ daysAgo: [Int], _ today: CalHabitDay) -> CalHabit {
        CalHabit(id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n)) ?? UUID(),
                 name: name, symbol: symbol, color: hex, perWeek: perWeek,
                 days: Set(daysAgo).map { today.adding(-$0) }.sorted().map(\.key))
    }
}
