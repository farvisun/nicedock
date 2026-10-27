import Foundation

/// Reference-scene data for this family (see `ReferenceScene`). Returns nil for kinds it doesn't own.
enum ClockScene {
    @MainActor static func prepare(_ kind: WidgetKind, _ variant: String?) -> [String: String]? {
        let engine = ClockTimerEngine.shared
        switch kind {
        case .clockDigital, .clockSeconds, .clockDate, .dateTile, .dayDate, .flipClock:
            // "12:34", "12:34:56", "Sun 14 Jun", "Sunday / June 14".
            ReferenceScene.now = at(2026, 6, 14, 12, 34, 56)
            return [:]
        case .analogDark, .analogLight:
            // Hour hand on 9, minute hand on 12, seconds hand at 326.3° (54.38 s).
            ReferenceScene.now = at(2026, 6, 14, 9, 0, 54.383)
            return [:]
        case .timer:
            // A running 5-minute timer with 4:19 left.
            let now = ReferenceScene.now
            engine.sceneTimer = ClockCountdown(duration: 300, end: now.addingTimeInterval(259))
            return ["minutes": "5"]
        case .stopwatch:
            // Paused at 0:13.0.
            engine.sceneStopwatch = ClockStopwatch(accumulated: 13, startedAt: nil)
            return [:]
        case .pomodoro:
            // Focus round 2 of 4, running, 18:42 left. The frame's ring is drawn at 58 % rather than
            // 18:42 / 25:00, so the seeded countdown carries the duration that yields that ring.
            let now = ReferenceScene.now
            engine.scenePomodoro = ClockPomodoro(phase: .focus, round: 2,
                                                 countdown: ClockCountdown(duration: 1938, end: now.addingTimeInterval(1122)))
            return ["focus": "25", "rounds": "4"]
        case .drinkWater:
            // 18:42 left, "Every 30 min". The frame's water sits at 63.3 % (not 18:42 / 30:00), so the seeded
            // cycle is 1772.8 s long; the clock's phase within the 4 s wave period poses the swell.
            ReferenceScene.now = ReferenceScene.defaultNow.addingTimeInterval(wavePhase)
            let now = ReferenceScene.now
            engine.sceneReminder = ClockReminder(interval: 1772.8, due: now.addingTimeInterval(1122))
            return ["interval": "30"]
        default:
            return nil
        }
    }

    /// Seconds added to the (whole-minute) scene clock for `drinkWater` so the animated wave matches the frame.
    static let wavePhase: TimeInterval = 1.719

    private static func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Double) -> Date {
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute, c.second) = (y, mo, d, h, mi, Int(s))
        let whole = Calendar(identifier: .gregorian).date(from: c) ?? ReferenceScene.defaultNow
        return whole.addingTimeInterval(s - Double(Int(s)))
    }
}
