import AppKit
import AVFoundation
import Carbon.HIToolbox
import Contacts
import EventKit
import SwiftUI
import Testing
@testable import CoolDock

// MARK: - Shared harness (also used by SettingsBehaviourTests)

/// One test at a time for everything that touches process-wide state (`AppStore.shared`, the clock engine, the
/// active language). Other suites never touch that state, so they keep running in parallel.
actor SharedStateLock {
    static let shared = SharedStateLock()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}

struct SharedStateTrait: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        await SharedStateLock.shared.acquire()
        do {
            try await function()
        } catch {
            await SharedStateLock.shared.release()
            throw error
        }
        await SharedStateLock.shared.release()
    }
}

extension Trait where Self == SharedStateTrait {
    /// Serialises the test against every other test that changes the app's shared state.
    static var sharedState: Self { SharedStateTrait() }
}

/// The real `AppStore.shared`, isolated: state and caches live in this test process's temporary folder
/// (`AppPaths.testRoot`), saving is off, English is active, the user's Library, clipboard and Dock are never touched.
@MainActor
enum Behaviour {
    private static var prepared = false

    static var store: AppStore {
        prepare()
        return AppStore.shared
    }

    static func prepare() {
        guard !prepared else { return }
        prepared = true
        AppStore.persistenceEnabled = false
        _ = NSApplication.shared
        let s = AppStore.shared
        s.systemReduceTransparency = false
        if s.settings.language != .en { s.settings.language = .en }
    }

    /// A fresh temporary folder (removed by the caller).
    static func tempDirectory(_ name: String = "behaviour") -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cooldock-\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Adds a widget to the active profile, as the Widget Browser does, and returns it as stored.
    @discardableResult
    static func addWidget(_ kind: WidgetKind, _ config: [String: String] = [:]) -> WidgetInstance {
        store.addWidget(kind, config: config)
        return store.activeProfile.widgets.last!
    }

    static func current(_ w: WidgetInstance) -> WidgetInstance { store.widget(w.id) ?? w }

    /// Runs `body` with `language` (and region options) active, then restores the previous settings.
    /// Synchronous on the main actor, so no other main-actor work sees the switch.
    static func withLanguage(_ language: AppLanguage, digits: DigitStyle = .automatic, calendar: CalendarSystem = .automatic,
                             clock: ClockStyle = .automatic, estedad: Bool = true, _ body: () throws -> Void) rethrows {
        let saved = store.settings
        defer { store.settings = saved }
        var s = saved
        s.language = language
        s.digitStyle = digits
        s.calendarSystem = calendar
        s.clockStyle = clock
        s.useEstedad = estedad
        store.settings = s
        try body()
    }

    /// Lets the main actor run queued work (debounced saves, async disk writes) until `condition` holds.
    static func wait(upTo seconds: Double = 3, until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }
}

/// A clock the tests move by hand.
@MainActor
final class TestClock {
    var now: Date
    init(_ start: Date = TestDate.local(2031, 3, 12, 12, 0)) { now = start }
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

/// Alerts the clock engine posts; nothing plays and no notification is sent while it is installed.
@MainActor
final class AlertLog {
    struct Alert: Equatable { var title: String; var body: String; var sound: Bool }
    private(set) var alerts: [Alert] = []
    init() { ClockAlerts.sink = { [unowned self] in self.alerts.append(Alert(title: $0, body: $1, sound: $2)) } }
    func stop() { ClockAlerts.sink = nil }
}

// MARK: - Timer, Stopwatch, Pomodoro, Drink Water, Posture

/// `ClockTimerEngine.shared` with a hand-moved clock. Alerts go to `AlertLog` (no sound, no notification).
@MainActor
@Suite(.serialized, .sharedState)
struct ClockWidgetBehaviourTests {
    let engine = ClockTimerEngine.shared
    let clock = TestClock()
    let log = AlertLog()

    init() {
        Behaviour.prepare()
        let clock = clock
        engine.now = { clock.now }
    }

    private func finish(_ widgets: WidgetInstance...) {
        for w in widgets {
            engine.cancelTimer(w)
            engine.resetPomodoro(w)
            engine.resetStopwatch(w.id)
            Behaviour.store.removeWidget(w.id)
        }
        engine.processDue() // drops reminder state of removed widgets and disarms the wake-up timer
        engine.now = { Date() }
        log.stop()
    }

    @Test func timerStartsPausesResumesAndResets() {
        let w = Behaviour.addWidget(.timer, ["minutes": "5"])
        defer { finish(w) }

        var t = engine.timer(w)
        #expect(t.isIdle && t.duration == 300)
        #expect(ClockFormat.countdown(t.displaySeconds(at: clock.now)) == "5:00")

        engine.toggleTimer(w) // start
        t = engine.timer(w)
        #expect(t.isRunning && t.end == clock.now.addingTimeInterval(300))

        clock.advance(61)
        t = engine.timer(w)
        #expect(ClockFormat.countdown(t.displaySeconds(at: clock.now)) == "3:59")
        #expect(abs(t.elapsedFraction(at: clock.now) - 61.0 / 300) < 1e-9)

        engine.toggleTimer(w) // pause
        t = engine.timer(w)
        #expect(t.isPaused && t.remaining(at: clock.now) == 239)
        clock.advance(600)
        #expect(engine.timer(w).remaining(at: clock.now) == 239, "a paused timer doesn't run down")

        engine.toggleTimer(w) // resume
        #expect(engine.timer(w).end == clock.now.addingTimeInterval(239))

        engine.cancelTimer(w) // reset (✕)
        t = engine.timer(w)
        #expect(t.isIdle && t.remaining(at: clock.now) == 300)
        #expect(log.alerts.isEmpty)
    }

    @Test func finishingTimerAlertsOnceAndResets() {
        let w = Behaviour.addWidget(.timer)
        defer { finish(w) }

        engine.startTimer(w, minutes: 1) // preset: saved as the widget's duration and started
        #expect(Behaviour.current(w).config["minutes"] == "1")
        #expect(engine.timer(w).isRunning)

        clock.advance(59)
        engine.processDue()
        #expect(log.alerts.isEmpty && engine.timer(w).isRunning)

        clock.advance(1)
        engine.processDue()
        #expect(log.alerts == [AlertLog.Alert(title: "Timer Done", body: "Your 1:00 timer has finished.", sound: true)])
        #expect(engine.timer(w).isIdle)

        engine.processDue()
        #expect(log.alerts.count == 1, "finished once, alerted once")
    }

    @Test func timerOfARemovedWidgetEndsSilently() {
        let w = Behaviour.addWidget(.timer, ["minutes": "1"])
        engine.toggleTimer(w)
        Behaviour.store.removeWidget(w.id)
        clock.advance(120)
        engine.processDue()
        #expect(log.alerts.isEmpty)
        #expect(engine.timer(w).isIdle)
        finish(w)
    }

    @Test func stopwatchRunsPausesLapsAndResets() {
        let w = Behaviour.addWidget(.stopwatch)
        defer { finish(w) }
        let id = w.id

        #expect(!engine.stopwatch(id).isRunning && engine.stopwatch(id).elapsed(at: clock.now) == 0)
        engine.lap(id)
        #expect(engine.stopwatch(id).laps.isEmpty, "no laps before it runs")

        engine.toggleStopwatch(id)
        clock.advance(12.5)
        engine.lap(id)
        clock.advance(0.75)
        engine.lap(id)
        engine.toggleStopwatch(id) // pause at 13.25 s

        var s = engine.stopwatch(id)
        #expect(!s.isRunning && s.accumulated == 13.25 && s.laps == [12.5, 13.25])
        clock.advance(100)
        #expect(engine.stopwatch(id).elapsed(at: clock.now) == 13.25, "paused time doesn't count")
        engine.lap(id)
        #expect(engine.stopwatch(id).laps.count == 2, "Lap is disabled while paused")
        #expect(ClockFormat.tenths(13.25) == "0:13.2")

        engine.toggleStopwatch(id) // resume
        clock.advance(3661)
        s = engine.stopwatch(id)
        #expect(s.elapsed(at: clock.now) == 3674.25)
        #expect(ClockFormat.tenths(s.elapsed(at: clock.now)) == "1:01:14.2")

        engine.resetStopwatch(id)
        s = engine.stopwatch(id)
        #expect(!s.isRunning && s.laps.isEmpty && s.elapsed(at: clock.now) == 0)
    }

    @Test func stopwatchDigitsFollowTheLanguage() {
        Behaviour.withLanguage(.fa) {
            #expect(ClockFormat.tenths(75.5) == "۱:۱۵٫۵")
        }
        Behaviour.withLanguage(.ar) {
            #expect(ClockFormat.tenths(75.5) == "١:١٥٫٥")
        }
        Behaviour.withLanguage(.fa, digits: .latin) {
            #expect(ClockFormat.tenths(75.5) == "1:15.5")
        }
    }

    @Test func pomodoroCyclesFocusBreaksAndLongBreak() {
        let w = Behaviour.addWidget(.pomodoro, ["focus": "25", "short": "5", "long": "15", "rounds": "2", "sound": "0"])
        defer { finish(w) }

        var p = engine.pomodoro(w)
        #expect(p.phase == .focus && p.round == 1 && p.countdown.isIdle && p.countdown.duration == 25 * 60)

        engine.togglePomodoro(w)
        #expect(engine.pomodoro(w).countdown.isRunning)

        clock.advance(25 * 60)
        engine.processDue()
        p = engine.pomodoro(w)
        #expect(p.phase == .shortBreak && p.round == 1 && p.countdown.isRunning && p.countdown.duration == 5 * 60)

        clock.advance(5 * 60)
        engine.processDue()
        p = engine.pomodoro(w)
        #expect(p.phase == .focus && p.round == 2)

        clock.advance(25 * 60)
        engine.processDue()
        p = engine.pomodoro(w)
        #expect(p.phase == .longBreak && p.round == 2 && p.countdown.duration == 15 * 60, "the last round ends in a long break")

        clock.advance(15 * 60)
        engine.processDue()
        p = engine.pomodoro(w)
        #expect(p.phase == .focus && p.round == 1, "after the long break the cycle starts over")

        #expect(log.alerts == [
            AlertLog.Alert(title: "Focus Complete", body: "Time for a short break.", sound: false),
            AlertLog.Alert(title: "Break Over", body: "Focus round 2 of 2 has started.", sound: false),
            AlertLog.Alert(title: "Focus Complete", body: "Time for a long break.", sound: false),
            AlertLog.Alert(title: "Break Over", body: "Focus round 1 of 2 has started.", sound: false)
        ])
    }

    @Test func pomodoroSkipPauseAndReset() {
        let w = Behaviour.addWidget(.pomodoro, ["rounds": "4"])
        defer { finish(w) }

        engine.togglePomodoro(w)
        clock.advance(60)
        engine.skipPhase(w) // running: the next phase starts right away
        var p = engine.pomodoro(w)
        #expect(p.phase == .shortBreak && p.countdown.isRunning && p.countdown.end == clock.now.addingTimeInterval(5 * 60))

        engine.togglePomodoro(w) // pause
        #expect(engine.pomodoro(w).countdown.isPaused)
        engine.skipPhase(w) // paused: the next phase waits for Start
        p = engine.pomodoro(w)
        #expect(p.phase == .focus && p.round == 2 && p.countdown.isIdle && p.countdown.duration == 25 * 60)
        #expect(Fmt.digits("\(p.round)/\(ClockPomodoroConfig(w).rounds)") == "2/4")

        engine.resetPomodoro(w)
        p = engine.pomodoro(w)
        #expect(p.phase == .focus && p.round == 1 && p.countdown.isIdle)
        #expect(log.alerts.isEmpty, "skipping never alerts")
    }

    @Test func drinkWaterRemindsConfirmsAndPauses() {
        let w = Behaviour.addWidget(.drinkWater, ["interval": "30"])
        defer { finish(w) }

        #expect(engine.reminder(w.id) == nil)
        engine.registerReminder(w) // the tile appears
        var r = engine.reminder(w.id)!
        #expect(r.due == clock.now.addingTimeInterval(1800) && !r.isPaused && r.todayCount(at: clock.now) == 0)
        #expect(r.level(at: clock.now) == 1)

        clock.advance(900)
        #expect(engine.reminder(w.id)!.level(at: clock.now) == 0.5)
        clock.advance(900)
        engine.processDue()
        #expect(log.alerts == [AlertLog.Alert(title: "Drink Water", body: "Time for a glass of water.", sound: true)])
        #expect(engine.reminder(w.id)!.isOverdue(at: clock.now))

        engine.processDue()
        #expect(log.alerts.count == 1)
        clock.advance(1800)
        engine.processDue()
        #expect(log.alerts.count == 2, "while overdue it reminds again every interval")

        engine.confirmReminder(w) // "I Drank Water"
        r = engine.reminder(w.id)!
        #expect(r.todayCount(at: clock.now) == 1 && r.due == clock.now.addingTimeInterval(1800) && r.notifiedAt == nil)
        #expect(r.level(at: clock.now) == 0, "the glass refills from empty…")
        #expect(r.level(at: clock.now.addingTimeInterval(1)) > 0.99, "…within a second")
        engine.confirmReminder(w)
        #expect(engine.reminder(w.id)!.todayCount(at: clock.now) == 2)

        engine.toggleReminderPause(w)
        r = engine.reminder(w.id)!
        #expect(r.isPaused && r.remaining(at: clock.now) == 1800)
        clock.advance(4 * 3600)
        engine.processDue()
        #expect(log.alerts.count == 2, "paused reminders stay quiet")

        engine.toggleReminderPause(w)
        #expect(engine.reminder(w.id)!.due == clock.now.addingTimeInterval(1800))
        #expect(engine.reminder(w.id)!.todayCount(at: clock.now) == 2, "pausing keeps today's count")
    }

    @Test func reminderCountsSurviveProfileSwitchesAndResetNextDay() {
        let store = Behaviour.store
        let w = Behaviour.addWidget(.posture)
        defer { finish(w) }
        engine.registerReminder(w)
        #expect(engine.reminder(w.id)!.interval == 45 * 60, "posture defaults to every 45 minutes")

        engine.confirmReminder(w)
        engine.confirmReminder(w)
        let home = store.activeIndex
        store.switchProfile(to: (home + 1) % store.profiles.count)
        store.switchProfile(to: home)
        #expect(engine.reminder(w.id)!.todayCount(at: clock.now) == 2)

        // Editing the interval moves the due time by the difference.
        let due = engine.reminder(w.id)!.due!
        store.updateWidget(w.id) { $0.config["interval"] = "60" }
        engine.registerReminder(Behaviour.current(w))
        #expect(engine.reminder(w.id)!.interval == 3600 && engine.reminder(w.id)!.due == due.addingTimeInterval(15 * 60))

        clock.advance(61 * 60)
        engine.processDue()
        #expect(log.alerts == [AlertLog.Alert(title: "Posture Check", body: "Sit up straight and relax your shoulders.", sound: true)])

        clock.advance(24 * 3600)
        #expect(engine.reminder(w.id)!.todayCount(at: clock.now) == 0, "a new day starts at zero")
        engine.confirmReminder(Behaviour.current(w))
        #expect(engine.reminder(w.id)!.todayCount(at: clock.now) == 1)
    }

    @Test func reminderOfARemovedWidgetIsDropped() {
        let w = Behaviour.addWidget(.drinkWater)
        engine.registerReminder(w)
        Behaviour.store.removeWidget(w.id)
        clock.advance(3600)
        engine.processDue()
        #expect(log.alerts.isEmpty && engine.reminder(w.id) == nil)
        finish(w)
    }
}

// MARK: - Calculator

@MainActor
@Suite(.sharedState)
struct CalculatorBehaviourTests {
    init() { Behaviour.prepare() }

    func eval(_ s: String) -> Double? { UtilCalc.evaluate(s) }

    @Test func precedenceParenthesesAndPowers() {
        #expect(eval("2 + 3 × 4") == 14)
        #expect(eval("(2 + 3) × 4") == 20)
        #expect(eval("2 + 3 * 4 - 6 / 2") == 11)
        #expect(eval("2^3^2") == 512, "powers are right-associative")
        #expect(eval("-2^2") == -4)
        #expect(eval("((1 + 2) * (3 + 4))") == 21)
        #expect(eval("2(3 + 4)") == 14, "implicit multiplication")
        #expect(eval("√16 + sqrt(9)") == 7)
        #expect(eval("2π") == 2 * Double.pi)
    }

    @Test func operatorSymbolsAndDecimals() {
        #expect(eval("10 ÷ 4") == 2.5)
        #expect(eval("7 − 2") == 5)
        #expect(eval("3 x 3") == 9)
        #expect(eval("6:3") == 2)
        #expect(eval("1.5 + .25") == 1.75)
        #expect(eval("1,234 + 1") == 1235, "comma before three digits groups thousands")
        #expect(eval("3,5 × 2") == 7, "otherwise it is a decimal comma")
    }

    @Test func percentAndModulo() {
        #expect(eval("50%") == 0.5)
        #expect(eval("200 + 10%") == 220)
        #expect(eval("200 - 10%") == 180)
        #expect(eval("200 × 10%") == 20)
        #expect(eval("10 % 3") == 1)
    }

    @Test func invalidInputAndDivisionByZero() {
        for s in ["", "   ", "5 / 0", "0 ÷ 0", "5 % 0", "2 +", "(1 + 2", "abc", "√-4", "1e3", "9^999"] {
            #expect(eval(s) == nil, "\(s)")
        }
    }

    @Test func persianAndArabicDigits() {
        #expect(eval("۱۲ × ۳") == 36)
        #expect(eval("٤٫٥ + ١") == 5.5)
        #expect(eval("۱۰۰ + ۱۰٪") == 110)
    }

    @Test func resultDisplayFollowsTheLocale() {
        let g = Fmt.locale.groupingSeparator ?? ",", d = Fmt.locale.decimalSeparator ?? "."
        #expect(UtilCalc.display(1234.5) == "1\(g)234\(d)5")
        #expect(UtilCalc.display(eval("0.1 + 0.2")!) == "0\(d)3", "float noise is rounded away")
        #expect(UtilCalc.display(1e16) == "1e+16")
        Behaviour.withLanguage(.fa) {
            #expect(UtilCalc.display(1234.5) == "۱٬۲۳۴٫۵")
            #expect(UtilCalc.display(1e16) == "۱e+۱۶")
        }
        Behaviour.withLanguage(.ar) {
            #expect(UtilCalc.display(1234.5) == "١٬٢٣٤٫٥")
        }
        // The pasteboard always gets plain ASCII.
        #expect(UtilCalc.plain(14) == "14")
        #expect(UtilCalc.plain(2.5) == "2.5")
        #expect(UtilCalc.plain(1.0 / 3) == "0.3333333333")
        #expect(UtilCalc.plain(-7) == "-7")
    }
}

// MARK: - Converter

@MainActor
@Suite(.serialized, .sharedState)
struct ConverterBehaviourTests {
    init() { Behaviour.prepare() }

    @Test func amountParsingAcceptsLocalDigitsAndSeparators() {
        let cases: [(String, Double?)] = [
            ("500", 500), (" 1,234.5 ", 1234.5), ("1.234,5", 1234.5), ("1,5", 1.5), ("1,234", 1234), ("1,234,567", 1_234_567),
            ("1'000", 1000), ("۱۲۳٫۵", 123.5), ("١٬٢٣٤", 1234), ("۵۰۰", 500), ("", nil), ("abc", nil), ("inf", nil), ("nan", nil)
        ]
        for (raw, value) in cases { #expect(UtilDigits.parseAmount(raw) == value, "\(raw)") }
    }

    @Test func typedAmountIsStoredCompactlyAndHugeAmountsDontCrash() {
        #expect(UtilConverterView.storedAmount("500") == "500")
        #expect(UtilConverterView.storedAmount("12.50") == "12.5")
        #expect(UtilConverterView.storedAmount("۱٬۰۰۰") == "1000")
        #expect(UtilConverterView.storedAmount("x") == nil)
        // Used to trap in `Int(v)` (beyond Int.max) and crash the app.
        #expect(UtilConverterView.storedAmount("99999999999999999999") == "1e+20")
        #expect(UtilDigits.parseAmount(UtilConverterView.storedAmount("99999999999999999999")!) == 1e20)
    }

    @Test func conversionUsesTheRateAndLocalDigits() {
        let d = Fmt.locale.decimalSeparator ?? ".", g = Fmt.locale.groupingSeparator ?? ","
        #expect(UtilConverterView.converted(500, rate: 0.9206) == "460\(d)30")
        #expect(UtilConverterView.converted(200_000, rate: 1.5) == "300\(g)000", "whole units from 100,000 up")
        Behaviour.withLanguage(.fa) {
            #expect(UtilConverterView.converted(500, rate: 0.9206) == "۴۶۰٫۳۰")
        }
    }

    @Test func swapExchangesTheCurrencies() {
        let store = Behaviour.store
        let w = Behaviour.addWidget(.converter, ["from": "USD", "to": "JPY"])
        defer { store.removeWidget(w.id) }
        UtilConverterView.swap(w)
        #expect(Behaviour.current(w).string("from") == "JPY" && Behaviour.current(w).string("to") == "USD")
        UtilConverterView.swap(Behaviour.current(w))
        #expect(Behaviour.current(w).string("from") == "USD" && Behaviour.current(w).string("to") == "JPY")
    }

    @Test func exchangeRatesAreCachedForTwelveHours() async throws {
        let clock = TestClock()
        var fetches: [String] = []
        var next: Result<Double, Error> = .success(0.92)
        UtilFX.now = { clock.now }
        UtilFX.fetcher = { from, to in
            fetches.append(from + to)
            return try next.get()
        }
        let (from, to) = ("XTS", "XXX") // ISO 4217 test codes, never real rates
        defer {
            UtilFX.fetcher = { _, _ in throw URLError(.notConnectedToInternet) }
            UtilFX.now = { Date() }
            UtilFX.clearMemory()
            try? FileManager.default.removeItem(at: DiskCache.url(UtilFX.key(from, to)))
            try? FileManager.default.removeItem(at: DiskCache.url(UtilFX.key("XTS", "XBA")))
        }

        #expect(try await UtilFX.rate("USD", "USD") == 1 && fetches.isEmpty)
        #expect(UtilFX.cached(from, to) == nil)
        #expect(try await UtilFX.rate(from, to) == 0.92)
        #expect(fetches == ["XTSXXX"])
        #expect(UtilFX.cached(from, to) == 0.92)

        clock.advance(UtilFX.ttl - 60)
        next = .success(0.5)
        #expect(try await UtilFX.rate(from, to) == 0.92, "fresh for 12 hours")
        #expect(fetches.count == 1)

        // Written to the disk cache (in the test folder), so a relaunch shows it instantly.
        await Behaviour.wait { DiskCache.load(UtilFXRate.self, UtilFX.key(from, to)) != nil }
        #expect(DiskCache.dir.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        UtilFX.clearMemory()
        #expect(UtilFX.cached(from, to) == 0.92)

        clock.advance(120) // now past the TTL
        next = .success(0.95)
        #expect(try await UtilFX.rate(from, to) == 0.95)
        #expect(fetches.count == 2)

        clock.advance(UtilFX.ttl + 1)
        next = .failure(URLError(.notConnectedToInternet))
        #expect(try await UtilFX.rate(from, to) == 0.95, "offline: the stale rate beats nothing")

        await #expect(throws: URLError.self) { try await UtilFX.rate("XTS", "XBA") }
    }
}

// MARK: - Emoji & Color Picker

@MainActor
@Suite(.serialized, .sharedState)
struct EmojiAndColorBehaviourTests {
    init() { Behaviour.prepare() }

    @Test func emojiKeepOrderLimitToNineAndStayWhole() {
        let defaults = WidgetInstance(kind: .emoji)
        #expect(UtilEmojiView.items(defaults) == ["😂", "✨", "✅", "🔥", "🥹", "🙏", "💡", "🚀", "❤️"])

        let mixed = WidgetInstance(kind: .emoji, config: ["emoji": "👍🏽, 🇮🇷 👨‍👩‍👧\n🏳️‍🌈,a"])
        #expect(UtilEmojiView.items(mixed) == ["👍🏽", "🇮🇷", "👨‍👩‍👧", "🏳️‍🌈", "a"], "skin tones, flags and ZWJ sequences count once")

        let many = WidgetInstance(kind: .emoji, config: ["emoji": "1️⃣2️⃣3️⃣4️⃣5️⃣6️⃣7️⃣8️⃣9️⃣🔟"])
        #expect(UtilEmojiView.items(many).count == 9 && UtilEmojiView.items(many).last == "9️⃣", "the tenth cell is the + button")
    }

    @Test func emojiChoicePersistsWithTheProfile() throws {
        let store = Behaviour.store
        let w = Behaviour.addWidget(.emoji)
        defer { store.removeWidget(w.id) }
        store.updateWidget(w.id) { $0.config["emoji"] = "🍕🌮🍣" }
        let saved = try JSONDecoder().decode(DockState.self, from: JSONEncoder().encode(store.dockState))
        let restored = try #require(saved.profiles.flatMap(\.widgets).first { $0.id == w.id })
        #expect(UtilEmojiView.items(restored) == ["🍕", "🌮", "🍣"])
    }

    @Test func colorSwatchesFillUpWithDefaultsOnce() {
        func colors(_ raw: String?) -> [String] {
            UtilColorPickerView.colors(WidgetInstance(kind: .colorPicker, config: raw.map { ["colors": $0] } ?? [:]))
        }
        #expect(colors(nil) == ["#EE5450", "#3499DC", "#FAC716"])
        #expect(colors("ff0000") == ["#ff0000", "#EE5450", "#3499DC"])
        #expect(colors("#12345, #00FF0080, #00FF00") == ["#00FF0080", "#00FF00", "#EE5450"], "6- and 8-digit values only")
        // A saved lowercase default used to appear twice ("#ee5450" and "#EE5450").
        #expect(colors("#ee5450") == ["#ee5450", "#3499DC", "#FAC716"])
    }

    @Test func pickedColorsBecomeTheNewestOfThree() {
        let store = Behaviour.store
        let w = Behaviour.addWidget(.colorPicker)
        defer { store.removeWidget(w.id) }

        #expect(UtilColorPicking.hex(NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1)) == "#FF8000")
        #expect(UtilColorPicking.hex(NSColor(calibratedWhite: 1, alpha: 1)) == "#FFFFFF")
        #expect(UtilColorPicking.hex(NSColor(patternImage: NSImage(size: NSSize(width: 2, height: 2)))) == nil)

        UtilColorPicking.remember("#112233", for: w)
        #expect(UtilColorPickerView.colors(Behaviour.current(w)) == ["#112233", "#EE5450", "#3499DC"])
        UtilColorPicking.remember("#3499DC", for: w)
        #expect(UtilColorPickerView.colors(Behaviour.current(w)) == ["#3499DC", "#112233", "#EE5450"])
        UtilColorPicking.remember("#EE5450", for: w)
        #expect(Behaviour.current(w).config["colors"] == "#EE5450\n#3499DC\n#112233", "no duplicates, newest first, three kept")
    }

    @Test func colorDetailsFormats() {
        let rows = UtilColorMath.formats("#3499dc")
        #expect(rows.map(\.0) == ["HEX", "RGB", "HSL", "SwiftUI"])
        #expect(rows.map(\.1) == ["#3499DC", "rgb(52, 153, 220)", "hsl(204, 71%, 53%)", "Color(red: 0.204, green: 0.600, blue: 0.863)"])
        let orange = UtilColorMath.rgb("#FF8000"), gray = UtilColorMath.hsl("#808080")
        #expect(orange.r == 255 && orange.g == 128 && orange.b == 0)
        #expect(gray.h == 0 && gray.s == 0 && gray.l == 50)
        #expect(UtilColorMath.isLight("#FAC716") && !UtilColorMath.isLight("#3499DC"))
    }
}

// MARK: - Clipboard

/// A private, uniquely named pasteboard and a scratch defaults file: the user's clipboard and preferences are
/// never read or written (checked through `NSPasteboard.general.changeCount`).
@MainActor
@Suite(.serialized, .sharedState)
struct ClipboardBehaviourTests {
    let pasteboard = NSPasteboard.withUniqueName()
    let folder = Behaviour.tempDirectory("clipboard")
    let defaults: UserDefaults
    let generalChange = NSPasteboard.general.changeCount

    init() {
        defaults = UserDefaults(suiteName: folder.appendingPathComponent("defaults").path)!
    }

    func cleanUp() {
        pasteboard.releaseGlobally()
        defaults.removePersistentDomain(forName: folder.appendingPathComponent("defaults").path)
        try? FileManager.default.removeItem(at: folder)
        #expect(NSPasteboard.general.changeCount == generalChange, "the user's clipboard was not touched")
    }

    func copy(_ text: String, types extra: [NSPasteboard.PasteboardType] = [], into svc: UtilClipboardService) {
        pasteboard.declareTypes([.string] + extra, owner: nil)
        pasteboard.setString(text, forType: .string)
        svc.tick()
    }

    func texts(_ svc: UtilClipboardService) -> [String] { svc.items.compactMap(\.text) }

    @Test func capturesDedupesAndSkipsSecrets() {
        defer { cleanUp() }
        let svc = UtilClipboardService(pasteboard: pasteboard, defaults: defaults)
        svc.enableCapture() // the user's opt-in (saved in the scratch defaults)
        #expect(svc.captureAllowed && defaults.bool(forKey: UtilClipboardService.optInKey))

        copy("alpha", into: svc)
        copy("beta", into: svc)
        copy("alpha", into: svc)
        #expect(texts(svc) == ["alpha", "beta"], "copying again moves it to the top")

        copy("   \n", into: svc)
        copy("hunter2", types: [.init("org.nspasteboard.ConcealedType")], into: svc)
        copy("otp 123456", types: [.init("org.nspasteboard.TransientType")], into: svc)
        #expect(texts(svc) == ["alpha", "beta"], "blank, concealed and transient items are skipped")

        svc.tick()
        #expect(svc.count == 2, "no change, no read")
    }

    @Test func keepsThirtyTextsAndPinnedItemsSurvive() {
        defer { cleanUp() }
        let svc = UtilClipboardService(pasteboard: pasteboard, defaults: defaults)
        svc.enableCapture()
        for i in 0..<35 { copy("item \(i)", into: svc) }
        #expect(svc.count == UtilClipboardService.maxText)
        #expect(texts(svc).first == "item 34" && texts(svc).last == "item 5")

        let keep = svc.items.first { $0.text == "item 10" }!
        svc.togglePin(keep)
        #expect(svc.items.first?.text == "item 10" && svc.items.first?.pinned == true)
        #expect(defaults.stringArray(forKey: UtilClipboardService.pinnedKey) == ["item 10"])

        for i in 100..<140 { copy("item \(i)", into: svc) }
        #expect(svc.items.first?.text == "item 10", "pinned items stay on top and are never trimmed")
        #expect(svc.items.filter { !$0.pinned }.count == UtilClipboardService.maxText)

        svc.clear()
        #expect(texts(svc) == ["item 10"], "Clear History keeps pinned items")

        // A relaunch restores the pins.
        let relaunched = UtilClipboardService(pasteboard: pasteboard, defaults: defaults)
        #expect(texts(relaunched) == ["item 10"] && relaunched.items[0].pinned)

        relaunched.remove(relaunched.items[0])
        #expect(relaunched.count == 0 && defaults.stringArray(forKey: UtilClipboardService.pinnedKey) == [])
    }

    @Test func copyingAnItemBackPutsItOnThePasteboard() {
        defer { cleanUp() }
        let svc = UtilClipboardService(pasteboard: pasteboard, defaults: defaults)
        svc.enableCapture()
        copy("first", into: svc)
        copy("second", into: svc)
        svc.copy(svc.items.first { $0.text == "first" }!)
        #expect(pasteboard.string(forType: .string) == "first")
        #expect(texts(svc) == ["first", "second"])
        svc.tick()
        #expect(svc.count == 2, "its own write is not captured twice")
    }
}

// MARK: - To-do

@MainActor
@Suite(.serialized, .sharedState)
struct TodoBehaviourTests {
    init() { Behaviour.prepare() }

    @Test func addCompleteDeleteAndPersist() throws {
        let store = Behaviour.store
        let w = Behaviour.addWidget(.todo)
        defer { store.removeWidget(w.id) }
        func items() -> [CalTodoItem] { CalTodoStore.items(store.widget(w.id)) }

        #expect(items().isEmpty)
        CalTodoStore.add("Buy milk", to: w.id)
        CalTodoStore.add("Ship 1.0", to: w.id)
        CalTodoStore.add("Call mom", to: w.id)
        #expect(items().map(\.title) == ["Buy milk", "Ship 1.0", "Call mom"], "new tasks go to the end")

        CalTodoStore.remove(items()[1].id, from: w.id) // checked off
        #expect(items().map(\.title) == ["Buy milk", "Call mom"])

        // The list lives in the widget's config, so it is saved with state.json.
        let state = try JSONDecoder().decode(DockState.self, from: JSONEncoder().encode(store.dockState))
        let restored = try #require(state.profiles.flatMap(\.widgets).first { $0.id == w.id })
        #expect(CalTodoStore.items(restored) == items())

        CalTodoStore.remove(items()[0].id, from: w.id) // deleted
        CalTodoStore.remove(UUID(), from: w.id) // unknown id: nothing happens
        #expect(items().map(\.title) == ["Call mom"])
        #expect(CalTodoStore.items(WidgetInstance(kind: .todo, config: ["items": "not json"])).isEmpty)
    }
}

// MARK: - Voice Memo

/// Stands in for `AVAudioRecorder`: nothing is recorded, the microphone is never opened.
final class FakeCapture: UtilVoiceCapture {
    var calls: [String] = []
    var recordSucceeds = true
    func record() -> Bool { calls.append("record"); return recordSucceeds }
    func pause() { calls.append("pause") }
    func stop() { calls.append("stop") }
    func updateMeters() { calls.append("meter") }
    func averagePower(forChannel channelNumber: Int) -> Float { -24 }
    func peakPower(forChannel channelNumber: Int) -> Float { -24 }
}

@MainActor
@Suite(.serialized, .sharedState)
struct VoiceMemoBehaviourTests {
    let folder = Behaviour.tempDirectory("memos")
    let savedDirectory = UtilVoiceRecorder.directory
    let clock = TestClock(TestDate.local(2026, 10, 27, 14, 5))

    init() { UtilVoiceRecorder.directory = folder }

    func cleanUp() {
        Open.interceptor = nil
        UtilVoiceRecorder.directory = savedDirectory
        try? FileManager.default.removeItem(at: folder)
    }

    func recorder(_ status: AVAuthorizationStatus, capture: FakeCapture, made: @escaping (URL) -> Void = { _ in }) -> UtilVoiceRecorder {
        let r = UtilVoiceRecorder()
        r.authorization = { status }
        r.makeRecorder = { url in made(url); return capture }
        let clock = clock
        r.now = { clock.now }
        return r
    }

    @Test func recordPauseResumeStop() {
        defer { cleanUp() }
        let capture = FakeCapture()
        var files: [URL] = []
        let rec = recorder(.authorized, capture: capture) { files.append($0) }

        rec.start()
        #expect(rec.state == .recording && rec.isActive)
        #expect(files == [folder.appendingPathComponent("Memo 2026-10-27 at 14.05.00.m4a")])
        clock.advance(5)
        #expect(rec.elapsed == 5)

        rec.togglePause()
        #expect(rec.state == .paused)
        clock.advance(100)
        #expect(rec.elapsed == 5, "paused time isn't counted")
        rec.togglePause()
        clock.advance(2)
        #expect(rec.state == .recording && rec.elapsed == 7)

        let levels = rec.sampleLevels(at: Date())
        #expect(abs(levels.last! - pow(0.5, 1.6)) < 1e-6, "-24 dB shows as a half-height bar (perceptual curve)")

        rec.start() // already recording: ignored
        #expect(files.count == 1)

        rec.stop()
        #expect(rec.state == .idle && rec.elapsed == 0)
        #expect(capture.calls.filter { $0 != "meter" } == ["record", "pause", "record", "stop"])
    }

    @Test func deniedMicrophoneOpensPrivacySettingsInsteadOfRecording() {
        defer { cleanUp() }
        var opened: [URL] = []
        Open.interceptor = { opened.append($0) }
        var files: [URL] = []
        let rec = recorder(.denied, capture: FakeCapture()) { files.append($0) }
        rec.start()
        #expect(rec.permissionDenied && rec.state == .idle && files.isEmpty)
        #expect(opened.map(\.absoluteString) == ["x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"])
    }

    @Test func recorderThatFailsToStartReportsIt() {
        defer { cleanUp() }
        let capture = FakeCapture()
        capture.recordSucceeds = false
        let rec = recorder(.authorized, capture: capture)
        rec.start()
        #expect(rec.failed && rec.state == .idle)
    }

    @Test func fileNamesSortByTimeAndLibraryListsRecordingsNewestFirst() async throws {
        defer { cleanUp() }
        #expect(UtilVoiceRecorder.fileName(for: TestDate.local(2026, 1, 2, 3, 4)) == "Memo 2026-01-02 at 03.04.00.m4a")

        // A real half-second WAV of silence (written, never played), two placeholders and files the list ignores.
        let wav = folder.appendingPathComponent("Memo older.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
        do {
            let file = try AVAudioFile(forWriting: wav, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4000)!
            buffer.frameLength = 4000
            try file.write(from: buffer)
        }
        let fm = FileManager.default
        for name in ["Memo newest.m4a", "Memo middle.caf", "notes.txt", ".hidden.m4a"] {
            fm.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data("x".utf8))
        }
        let base = TestDate.local(2026, 10, 1)
        for (i, name) in ["Memo older.wav", "Memo middle.caf", "Memo newest.m4a"].enumerated() {
            try fm.setAttributes([.creationDate: base.addingTimeInterval(Double(i) * 60)], ofItemAtPath: folder.appendingPathComponent(name).path)
        }

        let rec = recorder(.authorized, capture: FakeCapture())
        await rec.reload()
        #expect(rec.recordings.map(\.url.lastPathComponent) == ["Memo newest.m4a", "Memo middle.caf", "Memo older.wav"])
        #expect(abs(rec.recordings[2].duration - 0.5) < 0.01)
        #expect(rec.recordings[0].duration == 0, "an unreadable file still lists, without a length")
    }
}

// MARK: - Background Sounds

/// Plays only at volume 0 (the generator's output is multiplied by 0) and stops at once; waits for the engine to
/// shut down so nothing is left running.
@MainActor
@Suite(.serialized, .sharedState)
struct BackgroundSoundsBehaviourTests {
    init() { Behaviour.prepare() }

    @Test func soundAndVolumeComeFromTheWidget() {
        #expect(MediaSoundsTile.sound(WidgetInstance(kind: .backgroundSounds)) == .rain)
        #expect(MediaSoundsTile.sound(WidgetInstance(kind: .backgroundSounds, config: ["sound": "ocean"])) == .ocean)
        #expect(MediaSoundsTile.sound(WidgetInstance(kind: .backgroundSounds, config: ["sound": "thunder"])) == .rain)
        #expect(MediaSoundsTile.volume(WidgetInstance(kind: .backgroundSounds)) == 0.6)
        #expect(MediaSoundsTile.volume(WidgetInstance(kind: .backgroundSounds, config: ["volume": "0.25"])) == 0.25)
        #expect(MediaNoise.allCases.map(\.title) == ["Rain", "Ocean", "Brown Noise", "Pink Noise", "White Noise"])
    }

    @Test func selectingASoundSavesItAndPlaysSilentlyThenStops() async {
        let engine = MediaSoundEngine.shared
        let store = Behaviour.store
        let w = Behaviour.addWidget(.backgroundSounds, ["volume": "0"])
        defer { store.removeWidget(w.id) }
        #expect(!engine.isPlaying)

        engine.setVolume(1.7)
        #expect(engine.volume == 1)
        engine.setVolume(-1)
        #expect(engine.volume == 0)

        MediaSoundsTile.select(.pink, for: w)
        #expect(Behaviour.current(w).config["sound"] == "pink")
        #expect(engine.isPlaying && engine.sound == .pink && engine.volume == 0)

        MediaSoundsTile.toggle(Behaviour.current(w)) // tap: stop
        #expect(!engine.isPlaying)
        MediaSoundsTile.toggle(Behaviour.current(w)) // tap: play the saved sound at the saved volume (0)
        #expect(engine.isPlaying && engine.sound == .pink && engine.volume == 0)
        engine.stop()
        #expect(!engine.isPlaying)

        await Behaviour.wait { !engine.isEngineRunning }
        #expect(!engine.isEngineRunning, "the audio engine shuts down after the fade-out")
    }
}

// MARK: - YouTube

@Suite struct YouTubeBehaviourTests {
    @Test func videoIDFromEveryLinkShape() {
        let id = "dQw4w9WgXcQ"
        for raw in [
            id, "  \(id)\n",
            "https://www.youtube.com/watch?v=\(id)", "https://youtube.com/watch?v=\(id)&t=42s", "https://m.youtube.com/watch?app=desktop&v=\(id)",
            "youtube.com/watch?v=\(id)", "https://music.youtube.com/watch?v=\(id)&list=RD",
            "https://youtu.be/\(id)", "https://youtu.be/\(id)?si=abc&t=10", "YOUTU.BE/\(id)",
            "https://www.youtube.com/shorts/\(id)?feature=share", "https://www.youtube.com/embed/\(id)",
            "https://www.youtube-nocookie.com/embed/\(id)?rel=0", "https://www.youtube.com/live/\(id)", "https://www.youtube.com/v/\(id)"
        ] {
            #expect(MediaYouTube.videoID(raw) == id, "\(raw)")
        }
    }

    @Test func rejectsWhatIsNotAVideo() {
        for raw in ["", "hello", "https://www.youtube.com/", "https://www.youtube.com/watch?v=short", "https://vimeo.com/76979871",
                    "https://www.youtube.com/@apple", "https://youtu.be/", "https://example.com/watch?v=dQw4w9WgXcQ",
                    "https://www.youtube.com/watch?v=dQw4w9WgXc!"] {
            #expect(MediaYouTube.videoID(raw) == nil, "\(raw)")
        }
    }
}

// MARK: - Devices Battery

@Suite struct DevicesBatteryBehaviourTests {
    /// `system_profiler SPBluetoothDataType -json -detailLevel basic` layout (macOS 13+), with sample devices.
    static let profiler = """
    {"SPBluetoothDataType":[{
      "controller_properties":{"controller_address":"00:00:00:00:00:00","controller_state":"attrib_on"},
      "device_connected":[
        {"AirPods Pro":{"device_address":"AA:BB:CC:00:00:01","device_batteryLevelCase":"50%","device_batteryLevelLeft":"80%",
                        "device_batteryLevelRight":"75%","device_minorType":"Headphones"}},
        {"MX Master 3S":{"device_address":"AA:BB:CC:00:00:02","device_batteryLevelMain":"60%","device_minorType":"Mouse"}},
        {"Magic Keyboard":{"device_address":"AA:BB:CC:00:00:03","device_batteryLevelMain":"91 %","device_minorType":"Keyboard"}},
        {"JBL Flip 5":{"device_address":"AA:BB:CC:00:00:04","device_minorType":"Speaker"}},
        {"Sony WH-1000XM5":{"device_batteryLevel":"40%","device_minorType":"Headset"}}
      ],
      "device_not_connected":[{"Old Mouse":{"device_address":"AA:BB:CC:00:00:05","device_batteryLevelMain":"10%"}}]
    }]}
    """

    @Test func bluetoothReportParsing() {
        let devices = SysDeviceBatteryService.parseProfiler(Data(Self.profiler.utf8))
        #expect(devices == [
            SysPeripheral(id: "AA:BB:CC:00:00:01", name: "AirPods Pro", percent: 75, symbol: "airpodspro"),
            SysPeripheral(id: "AA:BB:CC:00:00:02", name: "MX Master 3S", percent: 60, symbol: "magicmouse"),
            SysPeripheral(id: "AA:BB:CC:00:00:03", name: "Magic Keyboard", percent: 91, symbol: "keyboard"),
            SysPeripheral(id: "Sony WH-1000XM5", name: "Sony WH-1000XM5", percent: 40, symbol: "headphones")
        ], "lowest earbud wins, the case is ignored, devices without a level and disconnected ones are skipped")
        #expect(SysDeviceBatteryService.parseProfiler(Data("not json".utf8)).isEmpty)
        #expect(SysDeviceBatteryService.parseProfiler(Data(#"{"SPBluetoothDataType":[{}]}"#.utf8)).isEmpty)
    }

    @Test func hidRegistryEntries() {
        func device(_ props: [String: Any]) -> SysPeripheral? { SysDeviceBatteryService.peripheral { props[$0] } }
        #expect(device(["BatteryPercent": NSNumber(value: 77), "Product": "Magic Trackpad", "SerialNumber": "F0T123"])
                == SysPeripheral(id: "F0T123", name: "Magic Trackpad", percent: 77, symbol: "rectangle.and.hand.point.up.left"))
        #expect(device(["BatteryPercent": NSNumber(value: 104), "Product": "Magic Mouse", "DeviceAddress": "aa-bb"])
                == SysPeripheral(id: "aa-bb", name: "Magic Mouse", percent: 100, symbol: "magicmouse"))
        #expect(device(["BatteryPercent": NSNumber(value: 5)]) == SysPeripheral(id: "Device", name: "Device", percent: 5, symbol: "dot.radiowaves.left.and.right"))
        #expect(device(["BatteryPercent": NSNumber(value: 0), "Product": "Dead"]) == nil)
        #expect(device(["Product": "No battery"]) == nil)
    }

    @Test func hidAndBluetoothListsMergeWithoutDuplicates() {
        let hid = [SysPeripheral(id: "1", name: "Magic Keyboard", percent: 90, symbol: "keyboard")]
        let bt = SysDeviceBatteryService.parseProfiler(Data(Self.profiler.utf8))
        let merged = SysDeviceBatteryService.merged(hid: hid, profiler: bt)
        #expect(merged.map(\.name) == ["Magic Keyboard", "AirPods Pro", "MX Master 3S", "Sony WH-1000XM5"])
        #expect(merged[0].percent == 90, "the HID reading wins")
    }

    @Test func symbols() {
        #expect(SysDeviceBatteryService.symbol(for: "AirPods Max", minor: nil) == "airpodsmax")
        #expect(SysDeviceBatteryService.symbol(for: "Beats Studio", minor: nil) == "beats.headphones")
        #expect(SysDeviceBatteryService.symbol(for: "DualSense Wireless Controller", minor: nil) == "gamecontroller")
        #expect(SysDeviceBatteryService.symbol(for: "Living Room", minor: "Speaker") == "hifispeaker")
        #expect(SysDeviceBatteryService.symbol(for: "Gadget", minor: nil) == "dot.radiowaves.left.and.right")
    }
}

// MARK: - Separator & Space

/// Lays the real views out (no window) and measures them.
@MainActor
@Suite struct SeparatorAndSpaceBehaviourTests {
    func size<V: View>(_ view: V, scale: CGFloat = 1) -> CGSize {
        NSHostingView(rootView: view.environment(\.metrics, DockMetrics(scale: scale))).fittingSize
    }

    @Test func separatorIsNinePointsWideAndTileHigh() {
        #expect(size(UtilSeparator()) == CGSize(width: 9, height: 62))
        #expect(size(UtilSeparator(), scale: 2) == CGSize(width: 18, height: 124))
        #expect(WidgetKind.separator.spec.width == 9 && WidgetKind.separator.spec.bare)
    }

    @Test func spaceFollowsItsWidthWithinFourToTwoHundred() {
        func space(_ width: String?) -> WidgetInstance { WidgetInstance(kind: .space, config: width.map { ["width": $0] } ?? [:]) }
        #expect(size(UtilSpace(w: space(nil))) == CGSize(width: 24, height: 62))
        #expect(size(UtilSpace(w: space("100"))) == CGSize(width: 100, height: 62))
        #expect(size(UtilSpace(w: space("1"))).width == 4)
        #expect(size(UtilSpace(w: space("500"))).width == 200)
        #expect(size(UtilSpace(w: space("abc"))).width == 24)
        #expect(size(UtilSpace(w: space("30")), scale: 2) == CGSize(width: 60, height: 124))
    }
}

// MARK: - Reminders, Contacts, Contact Card, Mail, Notes without permission

/// Permission and app state are pinned through seams: no prompt can appear, no AppleScript runs, nothing is read
/// from or written to the user's Reminders, Calendar, Contacts, Mail or Notes, and System Settings never opens.
@MainActor
@Suite(.serialized, .sharedState)
struct PermissionDeniedBehaviourTests {
    init() { Behaviour.prepare() }

    @Test func remindersWithoutAccessShowThePromptAndNeverWrite() {
        CalendarService.authorizationStatus = { _ in .denied }
        defer { CalendarService.authorizationStatus = { EKEventStore.authorizationStatus(for: $0) } }
        let svc = CalendarService.shared
        svc.reloadReminders()
        #expect(!svc.hasReminderAccess && !CalData.hasReminders && svc.reminders.isEmpty)

        svc.addReminder("CoolDock test — must never be saved") // no access: refused before EventKit is asked
        svc.complete(DockReminder(id: "cooldock-test-missing", title: "x", due: nil, color: .red, priority: 0))
        #expect(svc.reminders.isEmpty)

        // The widget appearing doesn't ask again once the user has answered (denied).
        CalendarDemand.reminders.subscribe("behaviour-test")
        CalendarDemand.reminders.unsubscribe("behaviour-test")
        #expect(svc.remindersAccess == .denied)

        CalendarService.authorizationStatus = { $0 == .event ? .writeOnly : .denied }
        svc.reloadEvents()
        #expect(!svc.hasEventAccess && svc.upcoming.isEmpty, "write-only Calendar access can't feed the widgets")
        #expect(!CalData.hasEvents, "no access and no feeds: the tiles ask for access")
    }

    @Test func contactsWithoutAccessOpenPrivacySettingsInsteadOfReading() async {
        MediaContactsModel.authorizationStatus = { .denied }
        var opened: [URL] = []
        Open.interceptor = { opened.append($0) }
        defer {
            MediaContactsModel.authorizationStatus = { CNContactStore.authorizationStatus(for: .contacts) }
            Open.interceptor = nil
        }
        let model = MediaContactsModel.shared
        model.refreshStatus()
        #expect(!model.authorized && model.accessPrompt == "Contacts access off")

        await model.load(["cooldock-test-id"], force: true)
        #expect(model.contacts(["cooldock-test-id"]) == nil, "nothing is fetched without access")

        model.requestAccess(then: []) // the tile's click: already answered, so System Settings instead of a prompt
        #expect(opened.map(\.absoluteString) == ["x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts"])

        MediaContactsModel.authorizationStatus = { .notDetermined }
        model.refreshStatus()
        #expect(model.accessPrompt == "Allow Contacts access")
        #expect(WidgetInstance(kind: .contactCard).list("contact").isEmpty, "an unconfigured card has nobody to look up")
    }

    @Test func contactActionsBuildTheRightLinks() {
        let c = MediaContact(id: "x", name: "Maya Johnson", initials: "MJ", phone: "+1 (555) 010-0100", email: "maya@example.com")
        #expect(c.dialablePhone == "+15550100100" && c.handle == "+15550100100")
        #expect(MediaContactAction.call.url(for: c) == "tel:+15550100100")
        #expect(MediaContactAction.video.url(for: c) == "facetime:+15550100100")
        #expect(MediaContactAction.message.url(for: c) == "sms:+15550100100")
        let mailOnly = MediaContact(id: "y", name: "Leo", initials: "L", phone: nil, email: "leo@example.com")
        #expect(mailOnly.handle == "leo@example.com" && MediaContactAction.call.url(for: mailOnly) == nil)
        #expect(MediaContactAction.message.url(for: mailOnly) == "imessage:leo@example.com")
    }

    @Test func mailAndNotesNeverScriptAClosedAppAndKeepQuietWhenRefused() async {
        let mail = MediaMailService.shared, notes = MediaNotesService.shared
        var scripts: [String] = []
        let runScript: (String) async -> NSAppleEventDescriptor? = { src in scripts.append(src); return nil } // Automation refused
        mail.runScript = runScript
        notes.runScript = runScript
        defer {
            mail.isRunning = { Script.isRunning($0) }
            notes.isRunning = { Script.isRunning($0) }
            mail.runScript = { await Script.run($0) }
            notes.runScript = { await Script.run($0) }
        }

        mail.isRunning = { _ in false }
        notes.isRunning = { _ in false }
        await mail.refresh(force: true)
        await notes.refresh(force: true)
        #expect(scripts.isEmpty, "closed apps are never launched or asked")
        #expect(mail.display == nil && notes.snapshot == nil)

        mail.isRunning = { $0 == MediaMailService.bundleID }
        notes.isRunning = { $0 == MediaNotesService.bundleID }
        await mail.refresh(force: true)
        await notes.refresh(force: true)
        #expect(scripts.count == 2)
        #expect(mail.display == nil && notes.snapshot == nil, "a refused script leaves the tile as it was")
        #expect(DiskCache.load(MediaMailSnapshot.self, "media-mail") == nil)
    }

    @Test func notePreviewDropsTheTitleAndCollapsesWhitespace() {
        #expect(MediaNotesService.preview("Groceries\nmilk\n\n  eggs\tbread", title: "Groceries") == "milk eggs bread")
        #expect(MediaNotesService.preview("Other first line\nbody", title: "Title") == "Other first line body")
        let flat = Array(repeating: "word", count: 30).joined(separator: " ")
        #expect(MediaNotesService.preview(flat.replacingOccurrences(of: " ", with: "\n"), title: "") == String(flat.prefix(80)) + "…",
                "about 80 characters, then an ellipsis")
    }
}
