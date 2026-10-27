import SwiftUI

// MARK: - Tile wrapper

/// Weather tile: keeps the city fresh while visible, shows a skeleton while loading and an actionable
/// message on errors. Click opens the forecast panel.
struct WeatherTile<Content: View>: View {
    let w: WidgetInstance
    var padding: EdgeInsets? = nil
    @ViewBuilder var content: (WeatherSnapshot) -> Content

    var body: some View {
        let city = w.string("city")
        let svc = WeatherService.shared
        let snap = svc.snapshot(city)
        let error = snap == nil ? svc.error(city) : nil
        Tile(width: w.kind.spec.width, padding: error == nil ? padding : nil) {
            if let snap {
                content(snap)
            } else if let error {
                TileMessage(symbol: city.isEmpty ? "location.slash.fill" : "exclamationmark.triangle.fill", text: error)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                content(WeatherSnapshot.weatherSkeleton)
                    .redacted(reason: .placeholder)
                    .opacity(0.45)
                    .allowsHitTesting(false)
            }
        }
        .onTapGesture {
            if snap != nil {
                Panels.shared.toggle(w.id) { WeatherPanel(city: city) }
            } else if error == L("Location unavailable") {
                WidgetSetup.customize(w)
            } else if error != nil {
                Task { await WeatherService.shared.ensure(city, force: true) }
            }
        }
        .task(id: city) { await WeatherService.shared.keepFresh(city) }
        .onWidgetRefresh(w.id) { Task { await WeatherService.shared.ensure(city, force: true) } }
    }
}

extension WeatherSnapshot {
    /// Neutral layout skeleton rendered redacted while the first fetch runs (never shown as data).
    static let weatherSkeleton: WeatherSnapshot = {
        let start = Calendar.current.startOfDay(for: Date())
        let hours = (0..<24).map { WeatherSnapshot.Hour(time: Date().addingTimeInterval(Double($0) * 3600), temp: 0, code: 3, isDay: true, precipChance: 0) }
        let days = (0..<7).map { i in
            WeatherSnapshot.Day(date: start.addingTimeInterval(Double(i) * 86_400), high: 0, low: 0, code: 3, sunrise: nil, sunset: nil, precip: 0)
        }
        return WeatherSnapshot(place: "———", fetched: .distantPast, timeZone: TimeZone.current.identifier, temp: 0, feelsLike: 0, code: 3,
                               isDay: true, humidity: 0, windSpeed: 0, windDirection: 0, windGusts: 0, precipitation: 0, hours: hours, days: days)
    }()

    /// Hours strictly after now (the current hour is represented by the "Now" reading).
    var weatherUpcomingHours: [Hour] {
        let now = ReferenceScene.date()
        return hours.filter { $0.time > now }
    }

    var weatherPlace: String { place.isEmpty ? L("Current Location") : place }
}

// MARK: - Glyph

/// Condition glyph. Filled grey like the references; `outline` for the hero card.
struct WeatherGlyph: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    var code: Int
    var isDay = true
    var size: CGFloat
    var outline = false
    var color: Color? = nil
    var weight: Font.Weight = .regular

    var body: some View {
        let name = WeatherCode.symbol(code, isDay: isDay)
        Image(systemName: outline && name.hasSuffix(".fill") ? String(name.dropLast(5)) : name)
            .symbolRenderingMode(.monochrome)
            .font(.system(size: m.u(size), weight: weight))
            .foregroundStyle(color ?? p.weatherGlyph)
    }
}

extension DockPalette {
    /// Muted grey used for condition glyphs.
    var weatherGlyph: Color { primary.opacity(0.47) }
    /// Faintest label grey (forecast day names, gusts).
    var weatherFaint: Color { tertiary.opacity(0.75) }
}

/// Forecast column: label, glyph and temperature at their natural heights, centred as a group, so a glyph that
/// hangs lower (rain) lifts its label like the reference frames do.
struct WeatherColumn: View {
    @Environment(\.metrics) private var m
    var label: String
    var labelFont: (CGFloat, Font.Weight)
    var labelColor: Color
    var code: Int
    var isDay = true
    var glyph: CGFloat
    var temp: String
    var tempFont: (CGFloat, Font.Weight)
    /// Label → glyph and glyph → temperature gaps.
    var gaps: (CGFloat, CGFloat) = (2, 2)
    /// Vertical offset of the label and temperature (not the glyph).
    var textNudge: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            Text(verbatim: label).dock(labelFont.0, labelFont.1, labelColor).lineLimit(1).minimumScaleFactor(0.7)
                .offset(y: m.u(textNudge))
            WeatherGlyph(code: code, isDay: isDay, size: glyph).padding(.top, m.u(gaps.0)).padding(.bottom, m.u(gaps.1))
            Text(verbatim: temp).dock(tempFont.0, tempFont.1, mono: true).lineLimit(1)
                .offset(y: m.u(textNudge))
        }
    }
}

// MARK: - Formatting in the location's time zone

@MainActor
enum WeatherFmt {
    private static var cache: [String: DateFormatter] = [:]

    private static func formatter(_ pattern: String, _ tz: String) -> DateFormatter {
        let key = "\(pattern)|\(tz)|\(Fmt.locale.identifier)|\(Fmt.calendar.identifier)"
        if let f = cache[key] { return f }
        let f = DateFormatter()
        f.locale = Fmt.locale
        f.calendar = Fmt.calendar
        f.timeZone = TimeZone(identifier: tz) ?? .current
        f.dateFormat = pattern
        if cache.count > 32 { cache.removeAll() }
        cache[key] = f
        return f
    }

    /// "21" / "9PM"
    static func hour(_ d: Date, _ tz: String) -> String { formatter(Fmt.uses24h ? "HH" : "ha", tz).string(from: d) }
    /// "6:12" / "20:18"
    static func time(_ d: Date, _ tz: String) -> String { formatter(Fmt.uses24h ? "H:mm" : "h:mm", tz).string(from: d) }
    /// `compact` swaps long RTL names (Persian «پنجشنبه») for their short form («۵ش») in narrow columns.
    static func weekday(_ d: Date, _ tz: String, compact: Bool = true) -> String {
        let s = formatter("EEE", tz).string(from: d)
        guard compact, s.count > 4, Localizer.language.isRTL else { return s }
        return formatter("EEEEEE", tz).string(from: d)
    }

    static func dayLabel(_ index: Int, _ d: Date, _ tz: String, compact: Bool = true) -> String {
        switch index {
        case 0: return L("Today")
        case 1: return L("Tomorrow")
        default: return weekday(d, tz, compact: compact)
        }
    }

    static func precip(_ mm: Double) -> String {
        if AppStore.shared.settings.temperatureUnit.resolved == .fahrenheit {
            let inches = mm / 25.4
            return Fmt.number(inches, decimals: inches == 0 ? 0 : 2) + " " + L("in")
        }
        let decimals = mm > 0 && mm < 10 && mm != mm.rounded() ? 1 : 0
        return Fmt.number(mm, decimals: decimals) + " " + L("mm")
    }
}

// MARK: - Panel

/// Expanded weather: current conditions, details, the next hours and a 7-day list with range bars.
struct WeatherPanel: View {
    @Environment(\.palette) private var p
    let city: String

    var body: some View {
        let svc = WeatherService.shared
        Group {
            if let s = svc.snapshot(city) {
                content(s)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "cloud").font(.system(size: 16, weight: .medium)).foregroundStyle(p.tertiary)
                    Text(svc.error(city) ?? L("Loading…")).font(.dock(12, .semibold)).foregroundStyle(p.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 80)
            }
        }
        .frame(width: 330)
    }

    private func content(_ s: WeatherSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        if city.trimmingCharacters(in: .whitespaces).isEmpty {
                            Image(systemName: "location.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(p.secondary)
                        }
                        Text(s.weatherPlace).font(.dock(15, .bold)).foregroundStyle(p.primary).lineLimit(1)
                    }
                    Text(WeatherCode.title(s.code)).font(.dock(12, .medium)).foregroundStyle(p.secondary)
                    if let t = s.today {
                        Text(L("H:%@  L:%@", Fmt.temp(t.high), Fmt.temp(t.low))).font(.dock(11, .semibold)).foregroundStyle(p.tertiary)
                    }
                }
                Spacer(minLength: 8)
                WeatherGlyph(code: s.code, isDay: s.isDay, size: 30, color: p.primary.opacity(0.75))
                Text(verbatim: Fmt.temp(s.temp)).font(.dock(42, .semibold)).foregroundStyle(p.primary)
            }

            HStack(spacing: 6) {
                stat("thermometer.medium", L("Feels like"), Fmt.temp(s.feelsLike))
                stat("humidity.fill", L("Humidity"), Fmt.percent(Double(s.humidity) / 100))
                stat("wind", L("Wind"), Fmt.speed(s.windSpeed))
                stat("drop.fill", L("Precip."), WeatherFmt.precip(s.today?.precip ?? s.precipitation))
            }

            hourly(s)

            VStack(spacing: 0) {
                let lo = s.days.map(\.low).min() ?? 0
                let hi = s.days.map(\.high).max() ?? 1
                ForEach(Array(s.days.enumerated()), id: \.offset) { i, d in
                    HStack(spacing: 8) {
                        Text(verbatim: WeatherFmt.dayLabel(i, d.date, s.timeZone, compact: false)).font(.dock(12, .semibold)).foregroundStyle(p.primary)
                            .lineLimit(1).frame(width: 74, alignment: .leading)
                        WeatherGlyph(code: d.code, size: 14, color: p.secondary).frame(width: 24)
                        // Low → bar → high reads as a chart, so it stays left-to-right.
                        HStack(spacing: 8) {
                            Text(verbatim: Fmt.temp(d.low)).font(.dock(12, .semibold)).foregroundStyle(p.tertiary).frame(width: 34, alignment: .trailing)
                            WeatherRangeBar(low: d.low, high: d.high, minAll: lo, maxAll: hi).frame(height: 4)
                            Text(verbatim: Fmt.temp(d.high)).font(.dock(12, .semibold)).foregroundStyle(p.primary).frame(width: 34, alignment: .trailing)
                        }
                        .environment(\.layoutDirection, .leftToRight)
                    }
                    .frame(height: 27)
                }
            }

            Text(L("Updated %@ · Open-Meteo", Fmt.clock(s.fetched))).font(.dock(10, .medium)).foregroundStyle(p.tertiary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func stat(_ symbol: String, _ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 9, weight: .bold))
                Text(title).lineLimit(1).minimumScaleFactor(0.8)
            }
            .font(.dock(9.5, .semibold)).foregroundStyle(p.tertiary)
            Text(verbatim: value).font(.dock(13, .bold)).foregroundStyle(p.primary).lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(p.control))
    }

    private func hourly(_ s: WeatherSnapshot) -> some View {
        HStack(spacing: 0) {
            hourCell(L("Now"), code: s.code, isDay: s.isDay, temp: s.temp, chance: nil, highlight: true)
            ForEach(Array(s.weatherUpcomingHours.prefix(7).enumerated()), id: \.offset) { _, h in
                hourCell(WeatherFmt.hour(h.time, s.timeZone), code: h.code, isDay: h.isDay, temp: h.temp, chance: h.precipChance >= 30 ? h.precipChance : nil, highlight: false)
            }
        }
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(p.control))
    }

    private func hourCell(_ label: String, code: Int, isDay: Bool, temp: Double, chance: Int?, highlight: Bool) -> some View {
        VStack(spacing: 4) {
            Text(verbatim: label).font(.dock(10.5, highlight ? .bold : .semibold)).foregroundStyle(highlight ? p.primary : p.secondary)
            WeatherGlyph(code: code, isDay: isDay, size: 14, color: p.secondary).frame(height: 16)
            Text(verbatim: Fmt.temp(temp)).font(.dock(12.5, .bold)).foregroundStyle(p.primary)
            Text(verbatim: chance.map { Fmt.percent(Double($0) / 100) } ?? " ").font(.dock(8.5, .bold)).foregroundStyle(p.accent(.cdCyan))
        }
        .frame(maxWidth: .infinity)
    }
}

/// Day temperature range on the week's scale. A chart, so always left-to-right.
struct WeatherRangeBar: View {
    @Environment(\.palette) private var p
    var low: Double
    var high: Double
    var minAll: Double
    var maxAll: Double

    var body: some View {
        Canvas { ctx, size in
            let span = max(maxAll - minAll, 1)
            let track = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2)
            ctx.fill(track, with: .color(p.track))
            let x0 = size.width * CGFloat((low - minAll) / span)
            let x1 = max(x0 + size.height, size.width * CGFloat((high - minAll) / span))
            let bar = Path(roundedRect: CGRect(x: x0, y: 0, width: x1 - x0, height: size.height), cornerRadius: size.height / 2)
            ctx.fill(bar, with: .linearGradient(Gradient(colors: [p.accent(Self.tint(low)), p.accent(Self.tint(high))]),
                                                startPoint: CGPoint(x: x0, y: 0), endPoint: CGPoint(x: x1, y: 0)))
        }
        .environment(\.layoutDirection, .leftToRight)
    }

    private static func tint(_ c: Double) -> Color {
        switch c {
        case ..<0: return .cdBlue
        case ..<10: return .cdCyan
        case ..<18: return .cdTeal
        case ..<24: return .cdGreen
        case ..<30: return .cdYellow
        case ..<36: return .cdOrange
        default: return .cdRed
        }
    }
}
