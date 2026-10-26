import SwiftUI

/// Current conditions, forecasts, sun and wind widgets backed by `WeatherService`.
enum WeatherWidgets {
    @MainActor @ViewBuilder
    static func view(_ w: WidgetInstance) -> some View {
        switch w.kind {
        case .weatherCompact: WeatherCompactWidget(w: w)
        case .weatherHero: WeatherHeroWidget(w: w)
        case .weatherLocation: WeatherLocationWidget(w: w)
        case .forecastDays: WeatherDaysWidget(w: w)
        case .weatherToday: WeatherTodayWidget(w: w)
        case .weatherCondition: WeatherConditionWidget(w: w)
        case .forecastHourly: WeatherHourlyWidget(w: w)
        case .sunriseSunset: WeatherSunWidget(w: w)
        case .wind: WeatherWindWidget(w: w)
        default: Tile(width: w.kind.spec.width) { Text(w.kind.spec.localizedTitle).dock(11) }
        }
    }

    @MainActor @ViewBuilder
    static func menu(_ w: WidgetInstance) -> some View {
        let city = w.string("city")
        Button(L("Show Forecast…")) { Panels.shared.show(w.id) { WeatherPanel(city: city) } }
        Divider()
    }
}

// MARK: - Compact: glyph + temperature

struct WeatherCompactWidget: View {
    @Environment(\.metrics) private var m
    let w: WidgetInstance

    var body: some View {
        WeatherTile(w: w) { s in
            HStack(spacing: m.u(5.5)) {
                WeatherGlyph(code: s.code, isDay: s.isDay, size: 17)
                Text(verbatim: Fmt.temp(s.temp)).dock(23.5, .semibold)
            }
        }
    }
}

// MARK: - Condition: big glyph + "Rain, 21°"

struct WeatherConditionWidget: View {
    @Environment(\.metrics) private var m
    let w: WidgetInstance

    var body: some View {
        WeatherTile(w: w, padding: .hv(6, 0)) { s in
            VStack(spacing: m.u(4)) {
                WeatherGlyph(code: s.code, isDay: s.isDay, size: 28).frame(height: m.u(33))
                Text(verbatim: WeatherCode.title(s.code) + L(", ") + Fmt.temp(s.temp)).dock(10, .bold).minimumScaleFactor(0.75)
                    .offset(y: m.u(1))
            }
            .offset(y: m.u(0.5))
        }
    }
}

// MARK: - Location details

struct WeatherLocationWidget: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    let w: WidgetInstance

    var body: some View {
        WeatherTile(w: w, padding: EdgeInsets(top: 0, leading: 6.5, bottom: 0, trailing: 6)) { s in
            HStack(spacing: m.u(6)) {
                VStack(alignment: .leading, spacing: m.u(5)) {
                    Text(s.weatherPlace).dock(12, .bold).truncationMode(.tail).minimumScaleFactor(0.85)
                    HStack(spacing: m.u(9)) {
                        detail("wind", Fmt.speed(s.windSpeed))
                        detail("drop.fill", WeatherFmt.precip(s.today?.precip ?? s.precipitation))
                    }
                    .fixedSize()
                }
                .layoutPriority(1)
                Spacer(minLength: m.u(4))
                WeatherGlyph(code: s.code, isDay: s.isDay, size: 16)
                    .padding(.trailing, m.u(0.5))
                Text(verbatim: Fmt.temp(s.temp)).dock(30, .semibold, mono: true).fixedSize()
            }
        }
    }

    private func detail(_ symbol: String, _ value: String) -> some View {
        HStack(spacing: m.u(3.5)) {
            Image(systemName: symbol).font(.system(size: m.u(8.5), weight: .semibold)).foregroundStyle(p.weatherGlyph)
            Text(verbatim: value).dock(10.5, .bold, p.secondary)
        }
    }
}

// MARK: - Four-day forecast with dividers

struct WeatherDaysWidget: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    let w: WidgetInstance

    var body: some View {
        WeatherTile(w: w, padding: .hv(6, 6)) { s in
            HStack(spacing: 0) {
                ForEach(Array(s.days.prefix(4).enumerated()), id: \.offset) { i, d in
                    if i > 0 { Rectangle().fill(p.tileStroke).frame(width: m.u(0.5)).padding(.vertical, m.u(1)) }
                    VStack(spacing: m.u(2)) {
                        Text(verbatim: WeatherFmt.dayLabel(i, d.date, s.timeZone)).dock(9, .bold, p.tertiary).minimumScaleFactor(0.75)
                            .offset(y: m.u(1))
                        WeatherGlyph(code: d.code, size: 13).frame(height: m.u(17))
                        Text(verbatim: Fmt.temp(d.high)).dock(10.5, .bold)
                    }
                    .offset(y: m.u(-0.5))
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

// MARK: - Big temperature + three days

struct WeatherTodayWidget: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    let w: WidgetInstance

    var body: some View {
        WeatherTile(w: w, padding: EdgeInsets(top: 0, leading: 7, bottom: 0, trailing: 8)) { s in
            HStack(alignment: .center, spacing: m.u(6)) {
                VStack(alignment: .leading, spacing: m.u(1)) {
                    Text(verbatim: Fmt.temp(s.temp)).dock(31, .semibold, mono: true)
                    Text(L("Today")).dock(9, .bold, p.secondary).offset(y: m.u(-1))
                }
                Spacer(minLength: 0)
                HStack(spacing: m.u(9)) {
                    ForEach(Array(s.days.dropFirst().prefix(3).enumerated()), id: \.offset) { _, d in
                        VStack(spacing: m.u(2.5)) {
                            Text(verbatim: WeatherFmt.weekday(d.date, s.timeZone)).dock(8.5, .bold, p.secondary).minimumScaleFactor(0.7)
                                .offset(y: m.u(2.5))
                            WeatherGlyph(code: d.code, size: 12).frame(height: m.u(15))
                            Text(verbatim: Fmt.temp(d.high)).dock(10.5, .bold)
                        }
                        .frame(width: m.u(25))
                    }
                }
            }
        }
    }
}

// MARK: - Hero card (homepage)

struct WeatherHeroWidget: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    let w: WidgetInstance

    var body: some View {
        WeatherTile(w: w, padding: .hv(15, 0)) { s in
            HStack(alignment: .center, spacing: m.u(12)) {
                VStack(alignment: .leading, spacing: m.u(1)) {
                    Text(verbatim: Fmt.temp(s.temp)).dock(23.25, .semibold, mono: true)
                    Text(L("Today")).dock(10, .medium, p.secondary)
                }
                Spacer(minLength: 0)
                HStack(spacing: m.u(15.5)) {
                    ForEach(Array(s.days.dropFirst().prefix(3).enumerated()), id: \.offset) { _, d in
                        VStack(spacing: m.u(3)) {
                            Text(verbatim: WeatherFmt.weekday(d.date, s.timeZone)).dock(8.5, .bold, p.secondary)
                            WeatherGlyph(code: d.code, size: 13.5, outline: true, color: p.primary).frame(height: m.u(15.5))
                            Text(verbatim: Fmt.temp(d.high)).dock(9.3, .medium, mono: true)
                        }
                        .frame(minWidth: m.u(20))
                    }
                }
                .fixedSize()
            }
        }
    }
}

// MARK: - Hourly strip

struct WeatherHourlyWidget: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    let w: WidgetInstance

    var body: some View {
        WeatherTile(w: w, padding: .hv(0, 0)) { s in
            HStack(spacing: 0) {
                column(L("Now"), code: s.code, isDay: s.isDay, temp: s.temp, now: true)
                ForEach(Array(s.weatherUpcomingHours.prefix(6).enumerated()), id: \.offset) { _, h in
                    column(WeatherFmt.hour(h.time, s.timeZone), code: h.code, isDay: h.isDay, temp: h.temp, now: false)
                }
            }
        }
    }

    private func column(_ label: String, code: Int, isDay: Bool, temp: Double, now: Bool) -> some View {
        VStack(spacing: m.u(2.5)) {
            Text(verbatim: label).dock(now ? 9 : 8.5, now ? .bold : .semibold, now ? p.primary : p.secondary).minimumScaleFactor(0.7)
                .frame(height: m.u(11))
                .offset(y: m.u(now ? 0.5 : 2.5))
            WeatherGlyph(code: code, isDay: isDay, size: 11).frame(height: m.u(14))
            Text(verbatim: Fmt.temp(temp)).dock(10.5, .bold)
        }
        .offset(y: m.u(-0.5))
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Sunrise & sunset arc

struct WeatherSunWidget: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    let w: WidgetInstance

    var body: some View {
        WeatherTile(w: w, padding: EdgeInsets(top: 0, leading: 6, bottom: 4, trailing: 4)) { s in
            TimelineView(.everyMinute) { ctx in
                let rise = s.today?.sunrise, set = s.today?.sunset
                ZStack(alignment: .bottom) {
                    WeatherSunArc(progress: Self.progress(now: ctx.date, rise: rise, set: set))
                        .padding(EdgeInsets(top: 0, leading: m.u(-6), bottom: m.u(-4), trailing: m.u(-4)))
                    HStack(spacing: m.u(4.5)) {
                        Image(systemName: "sunrise.fill").font(.system(size: m.u(10), weight: .semibold)).foregroundStyle(p.accent(.cdOrange))
                        Text(verbatim: rise.map { WeatherFmt.time($0, s.timeZone) } ?? "—").dock(12, .bold)
                        Spacer(minLength: 0)
                        Text(verbatim: set.map { WeatherFmt.time($0, s.timeZone) } ?? "—").dock(12, .bold)
                        Image(systemName: "sunset.fill").font(.system(size: m.u(10), weight: .semibold)).foregroundStyle(p.accent(.cdOrange))
                    }
                    .frame(height: m.u(15))
                }
            }
            .environment(\.layoutDirection, .leftToRight)
        }
    }

    /// 0…1 between sunrise and sunset, nil at night.
    private static func progress(now: Date, rise: Date?, set: Date?) -> Double? {
        guard let rise, let set, set > rise, now >= rise, now <= set else { return nil }
        return now.timeIntervalSince(rise) / set.timeIntervalSince(rise)
    }
}

/// Shallow sun path with a grey → orange → grey gradient and the sun's current position.
private struct WeatherSunArc: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    var progress: Double?

    var body: some View {
        Canvas { ctx, size in
            let endY = m.u(24.5), peakY = m.u(13)
            let p0 = CGPoint(x: m.u(5.5), y: endY)
            let p2 = CGPoint(x: size.width - m.u(2.5), y: endY)
            let c = CGPoint(x: size.width / 2, y: 2 * peakY - endY)
            var path = Path()
            path.move(to: p0)
            path.addQuadCurve(to: p2, control: c)
            let grey = p.primary.opacity(0.42)
            let sun = p.accent(Color(hex: "#FDB63B"))
            ctx.stroke(path, with: .linearGradient(Gradient(stops: [.init(color: grey, location: 0), .init(color: sun, location: 0.5), .init(color: grey, location: 1)]),
                                                   startPoint: p0, endPoint: p2),
                       style: StrokeStyle(lineWidth: m.u(1.75), lineCap: .round))
            if let t = progress {
                let u = 1 - t
                let pt = CGPoint(x: u * u * p0.x + 2 * u * t * c.x + t * t * p2.x, y: u * u * p0.y + 2 * u * t * c.y + t * t * p2.y)
                let glow = m.u(16), dot = m.u(8)
                ctx.fill(Path(ellipseIn: CGRect(x: pt.x - glow / 2, y: pt.y - glow / 2, width: glow, height: glow)),
                         with: .radialGradient(Gradient(colors: [sun.opacity(0.55), sun.opacity(0)]), center: pt, startRadius: 0, endRadius: glow / 2))
                ctx.fill(Path(ellipseIn: CGRect(x: pt.x - dot / 2, y: pt.y - dot / 2, width: dot, height: dot)), with: .color(sun))
            }
        }
    }
}

// MARK: - Wind with compass rose

struct WeatherWindWidget: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    let w: WidgetInstance

    var body: some View {
        WeatherTile(w: w, padding: EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 8)) { s in
            HStack(spacing: m.u(12)) {
                WeatherCompass(direction: s.windDirection, size: 49.5)
                VStack(alignment: .leading, spacing: m.u(2.5)) {
                    Text(verbatim: Fmt.speed(s.windSpeed)).dock(18.5, .bold)
                    Text(L("%@ wind", WeatherCode.compass(s.windDirection))).dock(9, .bold, p.secondary)
                    Text(L("Gusts %@", Fmt.speed(s.windGusts))).dock(9, .bold, p.tertiary)
                }
                .offset(y: m.u(0.5))
                Spacer(minLength: 0)
            }
        }
    }
}

/// Compass rose with the arrow pointing where the wind blows to. Geographic, so always left-to-right.
struct WeatherCompass: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    var direction: Double
    var size: CGFloat

    private static let marks: [(String, Double, Bool)] = [
        ("N", 0, true), ("NE", 45, false), ("E", 90, true), ("SE", 135, false),
        ("S", 180, true), ("SW", 225, false), ("W", 270, true), ("NW", 315, false)
    ]

    var body: some View {
        let s = m.u(size)
        ZStack {
            Circle().strokeBorder(p.primary.opacity(0.17), lineWidth: m.u(1))
            Canvas { ctx, sz in
                let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
                let r = sz.width / 2
                for k in 0..<8 {
                    let a = (22.5 + Double(k) * 45) * .pi / 180
                    let r0 = r * 0.77, r1 = r * 0.88
                    var tick = Path()
                    tick.move(to: CGPoint(x: c.x + CGFloat(sin(a)) * r0, y: c.y - CGFloat(cos(a)) * r0))
                    tick.addLine(to: CGPoint(x: c.x + CGFloat(sin(a)) * r1, y: c.y - CGFloat(cos(a)) * r1))
                    ctx.stroke(tick, with: .color(p.primary.opacity(0.2)), style: StrokeStyle(lineWidth: max(m.u(0.6), 0.5), lineCap: .round))
                }
            }
            ForEach(Self.marks, id: \.0) { label, angle, major in
                let a = angle * .pi / 180
                let rr = s * 0.39
                Text(L(label))
                    .font(.dock(m.u(major ? 7.5 : 5), major ? .heavy : .bold))
                    .foregroundStyle(major ? p.primary.opacity(0.85) : p.tertiary)
                    .fixedSize()
                    .offset(x: CGFloat(sin(a)) * rr, y: -CGFloat(cos(a)) * rr)
            }
            Image(systemName: "location.fill")
                .font(.system(size: m.u(11), weight: .bold))
                .foregroundStyle(p.primary.opacity(0.8))
                .rotationEffect(.degrees(direction + 180 - 45))
                .animation(.easeOut(duration: 0.4), value: direction)
        }
        .frame(width: s, height: s)
        .environment(\.layoutDirection, .leftToRight)
    }
}
