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

    var isNow: Bool {
        let now = ReferenceScene.date()
        return start <= now && end > now
    }
}

struct DockReminder: Identifiable, Equatable {
    let id: String
    let title: String
    let due: Date?
    let color: Color
    let priority: Int
    var overdue: Bool { (due.map { $0 < ReferenceScene.date() } ?? false) }
}

/// EventKit access for calendar and reminder widgets, merged with subscribed ICS feeds (`CalendarFeedService`).
/// Refreshes on store change notifications and a minute timer while a calendar widget is visible.
@Observable
@MainActor
final class CalendarService {
    static let shared = CalendarService()

    private(set) var eventsAccess: EKAuthorizationStatus = CalendarService.authorizationStatus(.event)
    private(set) var remindersAccess: EKAuthorizationStatus = CalendarService.authorizationStatus(.reminder)
    private(set) var upcoming: [DockEvent] = []
    private(set) var reminders: [DockReminder] = []
    private(set) var eventDays: Set<String> = []

    @ObservationIgnored let store = EKEventStore()
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var eventSubscribers = 0
    @ObservationIgnored private var reminderSubscribers = 0
    @ObservationIgnored private var minuteTimer: Timer?

    var hasEventAccess: Bool { eventsAccess == .fullAccess }
    /// Something to show events from: Calendar access or at least one enabled calendar feed.
    var hasEventSource: Bool { hasEventAccess || CalendarFeedService.shared.hasFeeds }
    var hasReminderAccess: Bool { remindersAccess == .fullAccess }

    /// Calendar / Reminders permission as TCC reports it. Tests pin it, so they never see the user's real data.
    nonisolated(unsafe) static var authorizationStatus: (EKEntityType) -> EKAuthorizationStatus = { EKEventStore.authorizationStatus(for: $0) }

    init() {
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
            MainActor.assumeIsolated { CalendarService.shared.reload() }
        }
    }

    // MARK: Access

    func requestEvents() async {
        _ = try? await store.requestFullAccessToEvents()
        eventsAccess = CalendarService.authorizationStatus(.event)
        reload()
    }

    func requestReminders() async {
        _ = try? await store.requestFullAccessToReminders()
        remindersAccess = CalendarService.authorizationStatus(.reminder)
        reload()
    }

    // MARK: Subscriptions

    func subscribeEvents() {
        eventSubscribers += 1
        if eventSubscribers == 1 {
            // With a calendar feed the widgets already have events: ask for Calendar access only when the user does.
            if eventsAccess == .notDetermined && !RenderHarness.isActive && !CalendarFeedService.shared.hasFeeds {
                Task { await requestEvents() }
            } else {
                reloadEvents()
            }
            startMinuteTimer()
            CalendarFeedService.shared.start()
        }
    }
    func unsubscribeEvents() {
        eventSubscribers = max(0, eventSubscribers - 1)
        stopTimerIfIdle()
        if eventSubscribers == 0 { CalendarFeedService.shared.stop() }
    }

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
        guard !ReferenceScene.isActive else { return }
        eventsAccess = CalendarService.authorizationStatus(.event)
        let now = Date()
        let cal = Calendar.current
        let start = cal.startOfDay(for: now)
        let end = cal.date(byAdding: .day, value: 8, to: start)!
        var events: [DockEvent] = []
        if hasEventAccess {
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
            events = store.events(matching: predicate)
                .filter { $0.status != .canceled && $0.endDate > now }
                .map { e in
                    DockEvent(id: e.eventIdentifier ?? UUID().uuidString, title: e.title ?? L("Untitled"), start: e.startDate, end: e.endDate,
                              allDay: e.isAllDay, color: Color(nsColor: e.calendar.color ?? .systemBlue), calendar: e.calendar.title,
                              meetingURL: Self.meetingURL(e), location: e.location)
                }
        }
        events += CalendarFeedService.shared.events(from: start, to: end).filter { $0.end > now }
        let merged = Self.merge(events)
        let fresh = Array(merged.prefix(40))
        if fresh != upcoming { upcoming = fresh }
        // Day dots cover the whole window, also past the 40 listed events (busy feeds).
        eventDays = Self.dayKeys(merged)
    }

    /// Calendar events first, then feed events; a feed copy of an event Calendar already has (same title, start
    /// and all-day flag, e.g. the same calendar subscribed in both) is dropped. Sorted by start.
    nonisolated static func merge(_ events: [DockEvent]) -> [DockEvent] {
        var seen = Set<String>()
        let unique = events.filter { e in
            seen.insert("\(e.title.lowercased())|\(e.start.timeIntervalSince1970)|\(e.allDay)").inserted
        }
        let sorted = unique.enumerated().sorted { a, b in
            a.element.start != b.element.start ? a.element.start < b.element.start : a.offset < b.offset
        }
        return sorted.map(\.element)
    }

    /// Re-reads Calendar and re-downloads the feeds (widget Refresh menu).
    func refreshEvents() {
        reloadEvents()
        Task { await CalendarFeedService.shared.refresh(force: true) }
    }

    private static func dayKeys(_ events: [DockEvent]) -> Set<String> {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return Set(events.map { fmt.string(from: $0.start) })
    }

    var todayEvents: [DockEvent] { upcoming.filter { Calendar.current.isDate($0.start, inSameDayAs: ReferenceScene.date()) || $0.isNow } }
    var nextMeeting: DockEvent? { upcoming.first { !$0.allDay && $0.end > ReferenceScene.date() } }

    /// True when a timed event is ongoing or starts within `minutes`.
    func meetingSoon(within minutes: Double = 15) -> Bool {
        guard let n = nextMeeting else { return false }
        return n.isNow || n.start.timeIntervalSince(ReferenceScene.date()) < minutes * 60
    }

    static func meetingURL(_ e: EKEvent) -> URL? { meetingURL(url: e.url, location: e.location, notes: e.notes) }

    /// Video-call link of an event (EventKit or feed): its URL when that is a meeting link, else the first meeting
    /// link in the location or notes, else its URL.
    nonisolated static func meetingURL(url: URL?, location: String?, notes: String?) -> URL? {
        if let url, isMeeting(url.absoluteString) { return url }
        let haystack = [location, notes].compactMap { $0 }.joined(separator: " ")
        let pattern = #"https?://[^\s<>"]*(zoom\.us|meet\.google\.com|teams\.microsoft\.com|teams\.live\.com|webex\.com|whereby\.com|meet\.jit\.si|around\.co|gather\.town|facetime\.apple\.com)[^\s<>"]*"#
        if let r = haystack.range(of: pattern, options: .regularExpression) {
            // "https://zoom.us/j/1, Room 4" — punctuation that ends the sentence isn't part of the link.
            let link = String(haystack[r]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:)]}>'"))
            return URL(string: link)
        }
        return url
    }

    nonisolated private static func isMeeting(_ s: String) -> Bool {
        ["zoom.us", "meet.google", "teams.", "webex", "whereby", "jit.si", "facetime"].contains { s.contains($0) }
    }

    func open(_ event: DockEvent) {
        if let url = event.meetingURL { NSWorkspace.shared.open(url) } else { Open.bundle("com.apple.iCal") }
    }

    // MARK: Reminders

    func reloadReminders() {
        guard !ReferenceScene.isActive else { return }
        remindersAccess = CalendarService.authorizationStatus(.reminder)
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
        guard hasReminderAccess, let item = store.calendarItem(withIdentifier: reminder.id) as? EKReminder else { return }
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

    // MARK: Reference scene

    /// Deterministic events and reminders for `--scene reference` renders; EventKit is never queried there.
    func setSceneData(events: [DockEvent], reminders: [DockReminder]) {
        guard ReferenceScene.isActive else { return }
        eventsAccess = .fullAccess
        remindersAccess = .fullAccess
        upcoming = events
        eventDays = Self.dayKeys(events)
        self.reminders = reminders
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
