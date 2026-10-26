import AppKit
import EventKit
import Observation
import SwiftUI

struct DockEvent: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
    let color: Color
    let calendar: String
    let meetingURL: URL?
    let location: String?

    var isNow: Bool { start <= Date() && end > Date() }
}

struct DockReminder: Identifiable, Equatable {
    let id: String
    let title: String
    let due: Date?
    let color: Color
    let priority: Int
    var overdue: Bool { (due.map { $0 < Date() } ?? false) }
}

/// EventKit access for calendar and reminder widgets. Refreshes on store change notifications only.
@Observable
@MainActor
final class CalendarService {
    static let shared = CalendarService()

    private(set) var eventsAccess: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    private(set) var remindersAccess: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .reminder)
    private(set) var upcoming: [DockEvent] = []
    private(set) var reminders: [DockReminder] = []
    private(set) var eventDays: Set<String> = []

    @ObservationIgnored let store = EKEventStore()
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var eventSubscribers = 0
    @ObservationIgnored private var reminderSubscribers = 0
    @ObservationIgnored private var minuteTimer: Timer?

    var hasEventAccess: Bool { eventsAccess == .fullAccess || eventsAccess == .authorized }
    var hasReminderAccess: Bool { remindersAccess == .fullAccess || remindersAccess == .authorized }

    init() {
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
            MainActor.assumeIsolated { CalendarService.shared.reload() }
        }
    }

    // MARK: Access

    func requestEvents() async {
        _ = try? await store.requestFullAccessToEvents()
        eventsAccess = EKEventStore.authorizationStatus(for: .event)
        reload()
    }

    func requestReminders() async {
        _ = try? await store.requestFullAccessToReminders()
        remindersAccess = EKEventStore.authorizationStatus(for: .reminder)
        reload()
    }

    // MARK: Subscriptions

    func subscribeEvents() {
        eventSubscribers += 1
        if eventSubscribers == 1 {
            if eventsAccess == .notDetermined && !RenderHarness.isActive { Task { await requestEvents() } } else { reloadEvents() }
            startMinuteTimer()
        }
    }
    func unsubscribeEvents() { eventSubscribers = max(0, eventSubscribers - 1); stopTimerIfIdle() }

    func subscribeReminders() {
        reminderSubscribers += 1
        if reminderSubscribers == 1 {
            if remindersAccess == .notDetermined && !RenderHarness.isActive { Task { await requestReminders() } } else { reloadReminders() }
        }
    }
    func unsubscribeReminders() { reminderSubscribers = max(0, reminderSubscribers - 1) }

    private func startMinuteTimer() {
        guard minuteTimer == nil else { return }
        let t = Timer(timeInterval: 60, repeats: true) { _ in MainActor.assumeIsolated { CalendarService.shared.reloadEvents() } }
        t.tolerance = 10
        RunLoop.main.add(t, forMode: .common)
        minuteTimer = t
    }

    private func stopTimerIfIdle() {
        if eventSubscribers == 0 { minuteTimer?.invalidate(); minuteTimer = nil }
    }

    func reload() {
        if eventSubscribers > 0 { reloadEvents() }
        if reminderSubscribers > 0 { reloadReminders() }
    }

    // MARK: Events

    func reloadEvents() {
        eventsAccess = EKEventStore.authorizationStatus(for: .event)
        guard hasEventAccess else { upcoming = []; return }
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: 8, to: start)!
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate)
            .filter { $0.status != .canceled && $0.endDate > Date() }
            .sorted { $0.startDate < $1.startDate }
            .prefix(40)
            .map { e in
                DockEvent(id: e.eventIdentifier ?? UUID().uuidString, title: e.title ?? L("Untitled"), start: e.startDate, end: e.endDate,
                          allDay: e.isAllDay, color: Color(nsColor: e.calendar.color ?? .systemBlue), calendar: e.calendar.title,
                          meetingURL: Self.meetingURL(e), location: e.location)
            }
        let fresh = Array(events)
        if fresh != upcoming { upcoming = fresh }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        eventDays = Set(fresh.map { fmt.string(from: $0.start) })
    }

    var todayEvents: [DockEvent] { upcoming.filter { Calendar.current.isDateInToday($0.start) || $0.isNow } }
    var nextMeeting: DockEvent? { upcoming.first { !$0.allDay && $0.end > Date() } }

    /// True when a timed event is ongoing or starts within `minutes`.
    func meetingSoon(within minutes: Double = 15) -> Bool {
        guard let n = nextMeeting else { return false }
        return n.isNow || n.start.timeIntervalSinceNow < minutes * 60
    }

    static func meetingURL(_ e: EKEvent) -> URL? {
        if let url = e.url, isMeeting(url.absoluteString) { return url }
        let haystack = [e.location, e.notes].compactMap { $0 }.joined(separator: " ")
        let pattern = #"https?://[^\s<>"]*(zoom\.us|meet\.google\.com|teams\.microsoft\.com|teams\.live\.com|webex\.com|whereby\.com|meet\.jit\.si|around\.co|gather\.town|facetime\.apple\.com)[^\s<>"]*"#
        if let r = haystack.range(of: pattern, options: .regularExpression) { return URL(string: String(haystack[r])) }
        return e.url
    }

    private static func isMeeting(_ s: String) -> Bool {
        ["zoom.us", "meet.google", "teams.", "webex", "whereby", "jit.si", "facetime"].contains { s.contains($0) }
    }

    func open(_ event: DockEvent) {
        if let url = event.meetingURL { NSWorkspace.shared.open(url) } else { Open.bundle("com.apple.iCal") }
    }

    // MARK: Reminders

    func reloadReminders() {
        remindersAccess = EKEventStore.authorizationStatus(for: .reminder)
        guard hasReminderAccess else { reminders = []; return }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        store.fetchReminders(matching: predicate) { items in
            let mapped = (items ?? []).map { r in
                DockReminder(id: r.calendarItemIdentifier, title: r.title ?? "", due: r.dueDateComponents?.date,
                             color: Color(nsColor: r.calendar.color ?? .systemOrange), priority: r.priority)
            }
            .sorted { a, b in
                switch (a.due, b.due) {
                case let (x?, y?): return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a.title < b.title
                }
            }
            Task { @MainActor in CalendarService.shared.reminders = Array(mapped.prefix(30)) }
        }
    }

    func complete(_ reminder: DockReminder) {
        guard let item = store.calendarItem(withIdentifier: reminder.id) as? EKReminder else { return }
        item.isCompleted = true
        try? store.save(item, commit: true)
        reminders.removeAll { $0.id == reminder.id }
    }

    func addReminder(_ title: String) {
        guard hasReminderAccess, !title.isEmpty else { return }
        let r = EKReminder(eventStore: store)
        r.title = title
        r.calendar = store.defaultCalendarForNewReminders()
        try? store.save(r, commit: true)
        reloadReminders()
    }
}

/// Demand wrapper so views can `.demand(CalendarDemand.events)`.
@MainActor
final class CalendarDemand: DemandDriven {
    static let events = CalendarDemand(reminders: false)
    static let reminders = CalendarDemand(reminders: true)
    private let isReminders: Bool
    private var ids = Set<String>()
    init(reminders: Bool) { isReminders = reminders }
    func subscribe(_ id: String) {
        guard ids.insert(id).inserted else { return }
        isReminders ? CalendarService.shared.subscribeReminders() : CalendarService.shared.subscribeEvents()
    }
    func unsubscribe(_ id: String) {
        guard ids.remove(id) != nil else { return }
        isReminders ? CalendarService.shared.unsubscribeReminders() : CalendarService.shared.unsubscribeEvents()
    }
}
