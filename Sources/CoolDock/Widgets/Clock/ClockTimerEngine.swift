import AppKit
import Foundation
import Observation
import UserNotifications

// MARK: - Runtime state (in memory, keyed by widget id)

/// A countdown expressed with absolute dates so nothing has to tick while it runs.
struct ClockCountdown: Equatable {
    var duration: TimeInterval
    var end: Date? = nil
    var pausedRemaining: TimeInterval? = nil

    var isRunning: Bool { end != nil }
    var isPaused: Bool { end == nil && pausedRemaining != nil }
    var isIdle: Bool { end == nil && pausedRemaining == nil }

    func remaining(at now: Date) -> TimeInterval {
        if let end { return max(0, end.timeIntervalSince(now)) }
        return pausedRemaining ?? duration
    }

    /// Whole seconds shown on screen ("4:19" while 258 s < remaining ≤ 259 s).
    func displaySeconds(at now: Date) -> TimeInterval { ceil(remaining(at: now) - 0.05) }

    func elapsedFraction(at now: Date) -> Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, 1 - remaining(at: now) / duration))
    }

    mutating func start(_ now: Date) {
        let left = remaining(at: now)
        end = now.addingTimeInterval(left > 0 ? left : duration)
        pausedRemaining = nil
    }

    mutating func pause(_ now: Date) {
        pausedRemaining = remaining(at: now)
        end = nil
    }
}

struct ClockStopwatch: Equatable {
    var accumulated: TimeInterval = 0
    var startedAt: Date? = nil
    /// Cumulative split times, oldest first.
    var laps: [TimeInterval] = []

    var isRunning: Bool { startedAt != nil }
    func elapsed(at now: Date) -> TimeInterval { accumulated + (startedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0) }
}

enum ClockPomodoroPhase: String {
    case focus, shortBreak, longBreak

    var title: String {
        switch self {
        case .focus: return L("Focus")
        case .shortBreak: return L("Break")
        case .longBreak: return L("Long Break")
        }
    }
}

struct ClockPomodoroConfig: Equatable {
    var focus: TimeInterval
    var short: TimeInterval
    var long: TimeInterval
    var rounds: Int
    var sound: Bool

    init(_ w: WidgetInstance) {
        focus = TimeInterval(max(1, w.int("focus", 25))) * 60
        short = TimeInterval(max(1, w.int("short", 5))) * 60
        long = TimeInterval(max(1, w.int("long", 15))) * 60
        rounds = max(1, w.int("rounds", 4))
        sound = w.bool("sound", true)
    }

    func duration(_ phase: ClockPomodoroPhase) -> TimeInterval {
        switch phase {
        case .focus: return focus
        case .shortBreak: return short
        case .longBreak: return long
        }
    }
}

struct ClockPomodoro: Equatable {
    var phase: ClockPomodoroPhase = .focus
    var round = 1
    var countdown: ClockCountdown
}

/// Drink-water / posture reminder cycle.
struct ClockReminder: Equatable {
    var interval: TimeInterval
    /// When the current cycle ends. `nil` while reminders are paused.
    var due: Date?
    /// Last notification posted for the current cycle (re-reminds every interval while overdue).
    var notifiedAt: Date? = nil
    var count = 0
    var countDay = Date()
    /// Last time the user confirmed ("I drank"), used for the refill animation.
    var confirmedAt: Date? = nil
    var levelAtConfirm: Double = 1

    var isPaused: Bool { due == nil }

    func remaining(at now: Date) -> TimeInterval { due.map { max(0, $0.timeIntervalSince(now)) } ?? interval }
    func isOverdue(at now: Date) -> Bool { due.map { now >= $0 } ?? false }

    /// Remaining fraction of the cycle (1 = just confirmed, 0 = due).
    func level(at now: Date) -> Double {
        guard interval > 0 else { return 0 }
        let target = min(1, max(0, remaining(at: now) / interval))
        // Ease the refill after a confirmation instead of jumping.
        if let confirmedAt {
            let t = now.timeIntervalSince(confirmedAt) / 0.9
            if t >= 0 && t < 1 {
                let eased = 1 - pow(1 - t, 3)
                return levelAtConfirm + (target - levelAtConfirm) * eased
            }
        }
        return target
    }

    func todayCount(at now: Date) -> Int { Calendar.current.isDate(countDay, inSameDayAs: now) ? count : 0 }

    var nextAlert: Date? {
        guard let due else { return nil }
        if let notifiedAt, notifiedAt >= due { return notifiedAt.addingTimeInterval(interval) }
        return due
    }
}

// MARK: - Engine

/// Owns every clock-family runtime: timers, stopwatches, pomodoros and reminders.
/// State lives in memory (survives profile switches). End times are absolute dates; a single
/// one-shot `Timer` wakes the engine only at the next due date — nothing ticks per second.
@MainActor
@Observable
final class ClockTimerEngine {
    static let shared = ClockTimerEngine()

    private(set) var timers: [UUID: ClockCountdown] = [:]
    private(set) var stopwatches: [UUID: ClockStopwatch] = [:]
    private(set) var pomodoros: [UUID: ClockPomodoro] = [:]
    private(set) var reminders: [UUID: ClockReminder] = [:]

    @ObservationIgnored private var wake: Timer?
    /// The engine's clock. Tests move it forward instead of waiting.
    @ObservationIgnored var now: () -> Date = { Date() }
    @ObservationIgnored private var wakeObserver: Any?

    /// `--scene reference` only (seeded by `ClockScene`): the state every rendered instance shows,
    /// dated against `ReferenceScene.now`. Never read in the normal app.
    @ObservationIgnored var sceneTimer: ClockCountdown?
    @ObservationIgnored var sceneStopwatch: ClockStopwatch?
    @ObservationIgnored var scenePomodoro: ClockPomodoro?
    @ObservationIgnored var sceneReminder: ClockReminder?

    static let timerPresets = [1, 3, 5, 10, 15, 25, 45, 60]

    private init() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ClockTimerEngine.shared.processDue() }
        }
    }

    // MARK: Timer

    func timer(_ w: WidgetInstance) -> ClockCountdown {
        if ReferenceScene.isActive, let s = sceneTimer { return s }
        let configured = TimeInterval(max(1, w.int("minutes", 5))) * 60
        guard var s = timers[w.id] else { return ClockCountdown(duration: configured) }
        if s.isIdle { s.duration = configured }
        return s
    }

    func toggleTimer(_ w: WidgetInstance) {
        let now = self.now()
        var s = timer(w)
        if s.isRunning {
            s.pause(now)
        } else {
            s.start(now)
            ClockAlerts.prepare()
        }
        timers[w.id] = s
        reschedule()
    }

    func cancelTimer(_ w: WidgetInstance) {
        timers[w.id] = nil
        reschedule()
    }

    /// Picks a preset: stores it as the widget's duration and starts right away.
    func startTimer(_ w: WidgetInstance, minutes: Int) {
        let duration = TimeInterval(minutes) * 60
        if w.int("minutes", 5) != minutes {
            AppStore.shared.updateWidget(w.id) { $0.config["minutes"] = String(minutes) }
        }
        timers[w.id] = ClockCountdown(duration: duration, end: now().addingTimeInterval(duration))
        ClockAlerts.prepare()
        reschedule()
    }

    // MARK: Stopwatch

    func stopwatch(_ id: UUID) -> ClockStopwatch {
        if ReferenceScene.isActive, let s = sceneStopwatch { return s }
        return stopwatches[id] ?? ClockStopwatch()
    }

    func toggleStopwatch(_ id: UUID) {
        var s = stopwatch(id)
        let now = self.now()
        if let started = s.startedAt {
            s.accumulated += now.timeIntervalSince(started)
            s.startedAt = nil
        } else {
            s.startedAt = now
        }
        stopwatches[id] = s
    }

    func lap(_ id: UUID) {
        guard var s = stopwatches[id], s.isRunning else { return }
        s.laps.append(s.elapsed(at: now()))
        stopwatches[id] = s
    }

    func resetStopwatch(_ id: UUID) { stopwatches[id] = nil }

    // MARK: Pomodoro

    func pomodoro(_ w: WidgetInstance) -> ClockPomodoro {
        if ReferenceScene.isActive, let s = scenePomodoro { return s }
        let cfg = ClockPomodoroConfig(w)
        guard var s = pomodoros[w.id] else { return ClockPomodoro(countdown: ClockCountdown(duration: cfg.focus)) }
        if s.countdown.isIdle { s.countdown.duration = cfg.duration(s.phase) }
        s.round = min(s.round, cfg.rounds)
        return s
    }

    func togglePomodoro(_ w: WidgetInstance) {
        let now = self.now()
        var s = pomodoro(w)
        if s.countdown.isRunning {
            s.countdown.pause(now)
        } else {
            s.countdown.start(now)
            ClockAlerts.prepare()
        }
        pomodoros[w.id] = s
        reschedule()
    }

    func skipPhase(_ w: WidgetInstance) {
        let s = pomodoro(w)
        pomodoros[w.id] = advanced(s, cfg: ClockPomodoroConfig(w), autoStart: s.countdown.isRunning, now: now())
        reschedule()
    }

    func resetPomodoro(_ w: WidgetInstance) {
        pomodoros[w.id] = nil
        reschedule()
    }

    private func advanced(_ s: ClockPomodoro, cfg: ClockPomodoroConfig, autoStart: Bool, now: Date) -> ClockPomodoro {
        var next = s
        switch s.phase {
        case .focus:
            next.phase = s.round >= cfg.rounds ? .longBreak : .shortBreak
        case .shortBreak:
            next.phase = .focus
            next.round = min(s.round + 1, cfg.rounds)
        case .longBreak:
            next.phase = .focus
            next.round = 1
        }
        let duration = cfg.duration(next.phase)
        next.countdown = ClockCountdown(duration: duration, end: autoStart ? now.addingTimeInterval(duration) : nil)
        return next
    }

    // MARK: Reminders (drink water, posture)

    func reminder(_ id: UUID) -> ClockReminder? {
        if ReferenceScene.isActive, let s = sceneReminder { return s }
        return reminders[id]
    }

    private static func interval(_ w: WidgetInstance) -> TimeInterval {
        TimeInterval(max(1, w.int("interval", w.kind == .posture ? 45 : 30))) * 60
    }

    /// Starts the reminder cycle the first time the widget appears and follows interval edits.
    func registerReminder(_ w: WidgetInstance) {
        guard !ReferenceScene.isActive else { return }
        let interval = Self.interval(w)
        if var s = reminders[w.id] {
            guard s.interval != interval else { return }
            if let due = s.due { s.due = due.addingTimeInterval(interval - s.interval) }
            s.interval = interval
            reminders[w.id] = s
        } else {
            reminders[w.id] = ClockReminder(interval: interval, due: now().addingTimeInterval(interval))
        }
        reschedule()
    }

    /// "I drank" / "Sat up": counts it and restarts the interval.
    func confirmReminder(_ w: WidgetInstance) {
        let now = self.now()
        var s = reminders[w.id] ?? ClockReminder(interval: Self.interval(w), due: now)
        s.interval = Self.interval(w)
        s.levelAtConfirm = s.level(at: now)
        s.confirmedAt = now
        s.count = s.todayCount(at: now) + 1
        s.countDay = now
        s.due = now.addingTimeInterval(s.interval)
        s.notifiedAt = nil
        reminders[w.id] = s
        ClockAlerts.prepare()
        reschedule()
    }

    func toggleReminderPause(_ w: WidgetInstance) {
        let now = self.now()
        var s = reminders[w.id] ?? ClockReminder(interval: Self.interval(w), due: now)
        if s.isPaused {
            s.levelAtConfirm = 0
            s.confirmedAt = now
            s.due = now.addingTimeInterval(s.interval)
            s.notifiedAt = nil
        } else {
            s.due = nil
        }
        reminders[w.id] = s
        reschedule()
    }

    // MARK: Scheduling

    private func reschedule() {
        wake?.invalidate()
        wake = nil
        var next: Date?
        func consider(_ d: Date?) {
            guard let d else { return }
            if next == nil || d < next! { next = d }
        }
        timers.values.forEach { consider($0.end) }
        pomodoros.values.forEach { consider($0.countdown.end) }
        reminders.values.forEach { consider($0.nextAlert) }
        guard let next else { return }
        let t = Timer(fire: max(next, Date().addingTimeInterval(0.05)), interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { ClockTimerEngine.shared.processDue() }
        }
        t.tolerance = 0.25
        RunLoop.main.add(t, forMode: .common)
        wake = t
    }

    private func widgetExists(_ id: UUID) -> WidgetInstance? {
        for profile in AppStore.shared.profiles {
            if let w = profile.widgets.first(where: { $0.id == id }) { return w }
        }
        return nil
    }

    /// Handles everything that has come due, then arms the next wake-up.
    func processDue() {
        let now = self.now()

        for (id, s) in timers {
            guard let end = s.end, end <= now else { continue }
            timers[id] = nil
            guard widgetExists(id) != nil else { continue }
            ClockAlerts.post(title: L("Timer Done"),
                             body: Fmt.digits(L("Your %@ timer has finished.", Fmt.duration(s.duration))),
                             sound: true)
        }

        for (id, s) in pomodoros {
            guard let end = s.countdown.end, end <= now else { continue }
            guard let w = widgetExists(id) else { pomodoros[id] = nil; continue }
            let cfg = ClockPomodoroConfig(w)
            let next = advanced(s, cfg: cfg, autoStart: true, now: max(end, now.addingTimeInterval(-1)))
            pomodoros[id] = next
            if s.phase == .focus {
                ClockAlerts.post(title: L("Focus Complete"),
                                 body: next.phase == .longBreak ? L("Time for a long break.") : L("Time for a short break."),
                                 sound: cfg.sound)
            } else {
                ClockAlerts.post(title: L("Break Over"),
                                 body: Fmt.digits(L("Focus round %d of %d has started.", next.round, cfg.rounds)),
                                 sound: cfg.sound)
            }
        }

        for (id, s) in reminders {
            guard let alert = s.nextAlert, alert <= now else { continue }
            guard let w = widgetExists(id) else { reminders[id] = nil; continue }
            var updated = s
            updated.notifiedAt = now
            reminders[id] = updated
            if w.kind == .posture {
                ClockAlerts.post(title: L("Posture Check"), body: L("Sit up straight and relax your shoulders."), sound: true)
            } else {
                ClockAlerts.post(title: L("Drink Water"), body: L("Time for a glass of water."), sound: true)
            }
        }

        reschedule()
    }
}

// MARK: - Alerts

/// User notifications + sound. Authorization is requested lazily on the first user action that
/// will need it, never during `--render` and never without a real app bundle.
@MainActor
enum ClockAlerts {
    static let isRenderHarness = CommandLine.arguments.contains("--render")
    private static var authRequested = false

    private static var canNotify: Bool {
        !isRenderHarness && Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    static func prepare() {
        guard canNotify, !authRequested else { return }
        authRequested = true
        let center = UNUserNotificationCenter.current()
        if center.delegate == nil { center.delegate = ClockNotificationPresenter.shared }
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Receives every alert instead of the sound and the notification (tests).
    static var sink: ((_ title: String, _ body: String, _ sound: Bool) -> Void)?

    static func post(title: String, body: String, sound: Bool) {
        if let sink { sink(title, body, sound); return }
        guard !isRenderHarness else { return }
        if sound { NSSound(named: "Glass")?.play() }
        guard canNotify else { return }
        prepare()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: "cooldock.clock." + UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}

/// Shows banners even while CoolDock is the active app (the dock is often frontmost when a timer ends).
final class ClockNotificationPresenter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = ClockNotificationPresenter()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}
