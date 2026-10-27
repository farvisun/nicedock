import SwiftUI

enum ClockWidgets {
    @MainActor @ViewBuilder
    static func view(_ w: WidgetInstance) -> some View {
        switch w.kind {
        case .clockDigital: ClockDigitalView(w: w)
        case .clockSeconds: ClockSecondsView(w: w)
        case .clockDate: ClockTimeDateView(w: w)
        case .timeHero: ClockHeroView(w: w)
        case .dateTile: ClockDateTileView(w: w)
        case .dayDate: ClockDayDateView(w: w)
        case .dateTimeWeather: ClockDateTimeWeatherView(w: w)
        case .worldClock: ClockWorldView(w: w)
        case .flipClock: ClockFlipView(w: w)
        case .analogDark: ClockAnalogView(w: w, light: false)
        case .analogLight: ClockAnalogView(w: w, light: true)
        case .pixelClock: ClockPixelView(w: w)
        case .timer: ClockTimerTile(w: w)
        case .stopwatch: ClockStopwatchTile(w: w)
        case .pomodoro: ClockPomodoroTile(w: w)
        case .drinkWater, .posture: ClockReminderTile(w: w)
        default: Tile(width: w.kind.spec.width) { Text(w.kind.spec.localizedTitle).dock(11) }
        }
    }

    @MainActor @ViewBuilder
    static func menu(_ w: WidgetInstance) -> some View {
        switch w.kind {
        case .timer: ClockTimerMenu(w: w)
        case .stopwatch: ClockStopwatchMenu(w: w)
        case .pomodoro: ClockPomodoroMenu(w: w)
        case .drinkWater, .posture: ClockReminderMenu(w: w)
        default: EmptyView()
        }
    }
}

// MARK: - Shared helpers

extension DockPalette {
    /// Large clock digits. The palette's primary already carries the references' ≈86 % white (219/255)
    /// in the dark styles, so the numerals use it as is.
    var clockInk: Color { primary }
}

enum ClockTime {
    /// The current second, floored — anchors per-second timelines on whole seconds.
    static func alignedSecond() -> Date { Date(timeIntervalSinceReferenceDate: floor(Date.timeIntervalSinceReferenceDate)) }

    /// A past date aligned with `end`'s sub-second phase so countdown ticks land on digit changes.
    static func anchor(before end: Date) -> Date {
        end.addingTimeInterval(-ceil(max(0, end.timeIntervalSinceNow)) - 1)
    }
}

enum ClockFormat {
    /// English uses the reference's fixed pattern; every other language gets the localized template.
    static func date(_ d: Date, en pattern: String, template: String) -> String {
        Localizer.language == .en ? Fmt.fixed(pattern).string(from: d) : Fmt.date(d, template)
    }

    /// "0:13.0" — duration with tenths, localized decimal separator.
    static func tenths(_ t: TimeInterval) -> String {
        let s = Fmt.duration(t, tenths: true)
        return Fmt.nativeDigits ? s.replacingOccurrences(of: ".", with: "٫") : s
    }

    /// Countdown string from whole seconds.
    static func countdown(_ seconds: TimeInterval) -> String { Fmt.duration(max(0, seconds)) }

    /// Estedad's numerals sit ~8 % of the size above the optical centre; drop them back so
    /// Persian/Arabic clocks line up with the Latin layout.
    static func digitDrop(_ size: CGFloat) -> CGFloat {
        Localizer.language.usesEstedad && AppStore.estedadEnabled ? size * 0.08 : 0
    }
}

/// Re-renders on minute boundaries, or on every whole second when `seconds` is true.
struct ClockTicker<Content: View>: View {
    var seconds = false
    @ViewBuilder var content: (Date) -> Content

    var body: some View {
        if seconds {
            TimelineView(.periodic(from: ClockTime.alignedSecond(), by: 1)) { ctx in content(ReferenceScene.date(ctx.date)) }
        } else {
            TimelineView(.everyMinute) { ctx in content(ReferenceScene.date(ctx.date)) }
        }
    }
}

/// Digits that should never be reordered by the bidi algorithm.
struct ClockDigits: View {
    var text: String
    var size: CGFloat
    var weight: Font.Weight = .semibold
    var color: Color?
    var tracking: CGFloat = 0
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p

    var body: some View {
        // Left-to-right isolate: keeps "۰:۱۳٫۰" in reading order inside RTL layouts.
        Text(verbatim: "\u{2066}" + text + "\u{2069}")
            .tracking(m.u(tracking))
            .font(.dock(m.u(size), weight, mono: true))
            .foregroundStyle(color ?? p.clockInk)
            .lineLimit(1)
            .fixedSize()
            .offset(y: ClockFormat.digitDrop(m.u(size)))
            .environment(\.layoutDirection, .leftToRight)
    }
}

// MARK: - Digital clocks

private struct ClockDigitalView: View {
    let w: WidgetInstance
    @Environment(\.metrics) private var m
    var body: some View {
        Tile(width: w.kind.spec.width) {
            ClockTicker { date in
                ClockDigits(text: Fmt.clock(date), size: 28)
                    .offset(x: m.u(0.5), y: m.u(0.5))
            }
        }
    }
}

private struct ClockSecondsView: View {
    let w: WidgetInstance
    @Environment(\.metrics) private var m
    var body: some View {
        Tile(width: w.kind.spec.width) {
            ClockTicker(seconds: true) { date in
                ClockDigits(text: Fmt.clock(date, seconds: true), size: 22)
                    .offset(x: m.u(0.5), y: m.u(0.5))
            }
        }
    }
}

private struct ClockTimeDateView: View {
    let w: WidgetInstance
    @Environment(\.palette) private var p
    @Environment(\.metrics) private var m
    var body: some View {
        Tile(width: w.kind.spec.width, padding: EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6), alignment: .leading) {
            ClockTicker { date in
                VStack(alignment: .leading, spacing: m.u(3)) {
                    ClockDigits(text: Fmt.clock(date), size: 26)
                    Text(ClockFormat.date(date, en: "EEE d MMM", template: "EEEdMMM"))
                        .dock(10.75, .semibold, p.secondary)
                        .minimumScaleFactor(0.8)
                }
                .offset(y: m.u(0.25))
            }
        }
    }
}

/// The cooldock.app hero time card (80 px CSS tile scaled to 62 pt).
private struct ClockHeroView: View {
    let w: WidgetInstance
    @Environment(\.palette) private var p
    var body: some View {
        Tile(width: w.kind.spec.width) {
            ClockTicker { date in
                VStack(spacing: 0) {
                    ClockDigits(text: Fmt.clock(date), size: 23.25)
                    Text(ClockFormat.date(date, en: "EEE, MMM d", template: "EEEMMMd"))
                        .dock(9.3, .medium, p.secondary)
                        .minimumScaleFactor(0.8)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { Panels.shared.toggle(w.id) { CalMonthPanel() } }
    }
}

private struct ClockDateTileView: View {
    let w: WidgetInstance
    @Environment(\.palette) private var p
    @Environment(\.metrics) private var m
    var body: some View {
        Tile(width: w.kind.spec.width) {
            ClockTicker { date in
                VStack(spacing: 0) {
                    ClockDigits(text: Fmt.dayNumber(date), size: 32, weight: .bold, tracking: 0.1)
                    Text(Fmt.monthShort(date))
                        .dock(11, .semibold, p.secondary)
                        .minimumScaleFactor(0.7)
                }
                .offset(y: m.u(0.25))
            }
        }
    }
}

private struct ClockDayDateView: View {
    let w: WidgetInstance
    @Environment(\.palette) private var p
    @Environment(\.metrics) private var m
    var body: some View {
        Tile(width: w.kind.spec.width, padding: EdgeInsets(top: 0, leading: 5, bottom: 0, trailing: 5), alignment: .leading) {
            ClockTicker { date in
                VStack(alignment: .leading, spacing: m.u(3)) {
                    Text(Fmt.weekday(date))
                        .dock(12, .semibold, p.secondary)
                    Text(ClockFormat.date(date, en: "MMMM d", template: "MMMMd"))
                        .dock(20, .semibold, p.clockInk)
                        .minimumScaleFactor(0.7)
                }
                .offset(y: m.u(0.5))
            }
        }
    }
}

private struct ClockDateTimeWeatherView: View {
    let w: WidgetInstance
    @Environment(\.palette) private var p
    @Environment(\.metrics) private var m
    private var weather: WeatherService { .shared }

    var body: some View {
        let city = w.string("city")
        Tile(width: w.kind.spec.width, padding: .hv(6, 0)) {
            ClockTicker { date in
                VStack(spacing: m.u(2)) {
                    Text(ClockFormat.date(date, en: "MMM d, EEEE", template: "MMMdEEEE"))
                        .dock(13.5, .semibold, p.clockInk)
                        .minimumScaleFactor(0.75)
                    HStack(spacing: m.u(4.5)) {
                        ClockDigits(text: Fmt.clock(date), size: 13.5)
                        if let snap = weather.snapshot(city) {
                            Image(systemName: WeatherCode.symbol(snap.code, isDay: snap.isDay))
                                .font(.system(size: m.u(12), weight: .semibold))
                                .foregroundStyle(p.primary.opacity(0.45))
                            Text(Fmt.temp(snap.temp)).dock(13.5, .semibold, p.clockInk)
                        }
                    }
                }
                .offset(y: m.u(1))
            }
        }
        .task(id: city) {
            guard !ClockAlerts.isRenderHarness else { return }
            await WeatherService.shared.keepFresh(city)
        }
    }
}

private struct ClockWorldView: View {
    let w: WidgetInstance
    @Environment(\.palette) private var p
    @Environment(\.metrics) private var m

    private var zone: TimeZone { TimeZone(identifier: w.string("zone").trimmingCharacters(in: .whitespaces)) ?? .current }

    private var label: String {
        let custom = w.string("label").trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty { return custom }
        let id = zone.identifier
        return (id.split(separator: "/").last.map(String.init) ?? id).replacingOccurrences(of: "_", with: " ")
    }

    /// "+3:30" relative to local time; UTC offset when the zone matches local time.
    private func offset(_ date: Date) -> String {
        let local = TimeZone.current.secondsFromGMT(for: date)
        let there = zone.secondsFromGMT(for: date)
        let diff = there - local
        func fmt(_ seconds: Int) -> String {
            let sign = seconds < 0 ? "−" : "+"
            let a = abs(seconds)
            let h = a / 3600, mins = (a % 3600) / 60
            return sign + (mins == 0 ? "\(h)" : String(format: "%d:%02d", h, mins))
        }
        return Fmt.digits(diff == 0 ? L("UTC") + fmt(there) : fmt(diff))
    }

    private func marker(_ date: Date) -> String {
        guard let f = Fmt.fixed("a").copy() as? DateFormatter else { return "" }
        f.timeZone = zone
        return f.string(from: date)
    }

    var body: some View {
        Tile(width: w.kind.spec.width, padding: EdgeInsets(top: 0, leading: 9, bottom: 0, trailing: 9), alignment: .leading) {
            ClockTicker { date in
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: m.u(4)) {
                        Text(label).dock(11, .semibold, p.secondary)
                        Spacer(minLength: 0)
                        Text(verbatim: offset(date)).dock(11, .semibold, p.tertiary, mono: true)
                            .environment(\.layoutDirection, .leftToRight)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: m.u(2)) {
                        ClockDigits(text: Fmt.clock(date, zone: zone), size: 26)
                        if !Fmt.uses24h {
                            Text(marker(date)).dock(10, .semibold, p.secondary)
                        }
                    }
                }
                .offset(y: m.u(1))
            }
        }
    }
}
