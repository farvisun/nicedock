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
