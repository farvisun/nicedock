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
                WeatherGlyph(code: s.code, isDay: s.isDay, size: 17).offset(y: m.u(0.5))
                Text(verbatim: Fmt.temp(s.temp)).dock(23.5, .semibold)
            }
        }
    }
}

// MARK: - Condition: big glyph + "Rain, 21°"

struct WeatherConditionWidget: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    let w: WidgetInstance

    var body: some View {
        WeatherTile(w: w, padding: .hv(6, 0)) { s in
            VStack(spacing: m.u(4)) {
                WeatherGlyph(code: s.code, isDay: s.isDay, size: 30, color: p.primary.opacity(0.54)).frame(height: m.u(33))
                    .offset(y: m.u(1))
                Text(verbatim: WeatherCode.title(s.code) + L(", ") + Fmt.temp(s.temp)).dock(9.75, .bold).minimumScaleFactor(0.75)
                    .offset(y: m.u(2))
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
        WeatherTile(w: w, padding: EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 5)) { s in
            HStack(spacing: m.u(6)) {
                VStack(alignment: .leading, spacing: m.u(5)) {
                    Text(s.weatherPlace).dock(12, .semibold).truncationMode(.tail).minimumScaleFactor(0.85)
                        .offset(y: m.u(0.5))
                    // Long units (Persian «کیلومتر/ساعت») tighten the gap, then shrink, instead of pushing the temperature out.
                    ViewThatFits(in: .horizontal) {
                        details(s, spacing: 12).fixedSize()
                        details(s, spacing: 6).fixedSize()
                        details(s, spacing: 5).minimumScaleFactor(0.75)
                    }
                    .offset(y: m.u(-0.5))
                }
                .layoutPriority(1)
                Spacer(minLength: m.u(4))
                WeatherGlyph(code: s.code, isDay: s.isDay, size: 16)
                    .padding(.trailing, m.u(-1.5))
                Text(verbatim: Fmt.temp(s.temp)).dock(28, .semibold, mono: true).fixedSize()
            }
        }
    }

    private func details(_ s: WeatherSnapshot, spacing: CGFloat) -> some View {
        HStack(spacing: m.u(spacing)) {
            detail("wind", Fmt.speed(s.windSpeed))
            detail("drop.fill", WeatherFmt.precip(s.today?.precip ?? s.precipitation))
        }
    }

    private func detail(_ symbol: String, _ value: String) -> some View {
        HStack(spacing: m.u(3.5)) {
            Image(systemName: symbol).font(.system(size: m.u(7.5), weight: .semibold)).foregroundStyle(p.weatherGlyph)
            Text(verbatim: value).dock(9.75, .semibold, p.secondary)
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
                    if i > 0 { Rectangle().fill(p.primary.opacity(0.07)).frame(width: m.u(0.5), height: m.u(38)) }
                    WeatherColumn(label: WeatherFmt.dayLabel(i, d.date, s.timeZone), labelFont: (8.25, .semibold), labelColor: p.weatherFaint,
                                  code: d.code, glyph: 13.3, temp: Fmt.temp(d.high), tempFont: (10, .bold), gaps: (2, 2))
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
        WeatherTile(w: w, padding: EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 7.5)) { s in
            HStack(alignment: .center, spacing: m.u(6)) {
                VStack(alignment: .leading, spacing: m.u(1)) {
                    Text(verbatim: Fmt.temp(s.temp)).dock(31, .semibold, mono: true)
                    Text(L("Today")).dock(9, .semibold, p.secondary).offset(y: m.u(-1))
                }
                Spacer(minLength: 0)
                HStack(spacing: m.u(9)) {
                    ForEach(Array(s.days.dropFirst().prefix(3).enumerated()), id: \.offset) { _, d in
                        WeatherColumn(label: WeatherFmt.weekday(d.date, s.timeZone), labelFont: (8.5, .semibold), labelColor: p.secondary,
                                      code: d.code, glyph: 12.3, temp: Fmt.temp(d.high), tempFont: (10.5, .bold), gaps: (1.5, 2.5))
                            .offset(y: m.u(0.5))
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
        WeatherColumn(label: label, labelFont: now ? (8.25, .bold) : (8, .semibold), labelColor: now ? p.primary : p.secondary,
                      code: code, isDay: isDay, glyph: 11.25, temp: Fmt.temp(temp), tempFont: (10.25, .semibold), gaps: (1.5, 2.5))
            .offset(y: m.u(0.4))
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
                    WeatherSunArc(progress: Self.progress(now: ReferenceScene.date(ctx.date), rise: rise, set: set))
                        .padding(EdgeInsets(top: 0, leading: m.u(-6), bottom: m.u(-4), trailing: m.u(-4)))
                    HStack(spacing: m.u(3.5)) {
                        Image(systemName: "sunrise.fill").font(.system(size: m.u(8.85), weight: .semibold)).foregroundStyle(p.accent(WeatherSunArc.orange))
                            .offset(y: m.u(0.6))
                        Text(verbatim: rise.map { WeatherFmt.time($0, s.timeZone) } ?? "—").dock(11.75, .semibold)
                        Spacer(minLength: 0)
                        Text(verbatim: set.map { WeatherFmt.time($0, s.timeZone) } ?? "—").dock(11.75, .semibold)
                        Image(systemName: "sunset.fill").font(.system(size: m.u(8.85), weight: .semibold)).foregroundStyle(p.accent(WeatherSunArc.orange))
                            .offset(y: m.u(0.6))
                    }
                    .frame(height: m.u(15))
                    .padding(.trailing, m.u(-1.5))
                    .offset(y: m.u(-0.75))
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
    /// Sunrise/sunset glyph orange from the reference frame.
    static let orange = Color(hex: "#FF9230")

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
            HStack(spacing: m.u(10)) {
                WeatherCompass(direction: s.windDirection, size: 50)
                VStack(alignment: .leading, spacing: m.u(2.5)) {
                    speed(Fmt.speed(s.windSpeed))
                        .padding(.leading, m.u(1.5))
                        .offset(y: m.u(-1.25))
                    Text(L("%@ wind", WeatherCode.compass(s.windDirection))).dock(8.75, .bold, p.secondary).lineLimit(1).minimumScaleFactor(0.7)
                    Text(L("Gusts %@", Fmt.speed(s.windGusts))).dock(8.65, .bold, p.weatherFaint).lineLimit(1).minimumScaleFactor(0.7)
                        .offset(y: m.u(1.5))
                }
                .offset(y: m.u(-0.5))
                Spacer(minLength: 0)
            }
        }
    }

    /// Short units ("7 km/h") stay one run; long ones (Persian «کیلومتر/ساعت») drop to a smaller secondary run.
    @ViewBuilder private func speed(_ text: String) -> some View {
        if let space = text.firstIndex(of: " "), text.distance(from: space, to: text.endIndex) > 5 {
            HStack(alignment: .firstTextBaseline, spacing: m.u(3)) {
                Text(verbatim: String(text[..<space])).dock(18.5, .bold)
                Text(verbatim: String(text[text.index(after: space)...])).dock(9.5, .bold, p.secondary).lineLimit(1).minimumScaleFactor(0.7)
            }
        } else {
            Text(verbatim: text).dock(18.5, .bold).lineLimit(1).minimumScaleFactor(0.6)
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
                for k in 0..<16 {
                    let a = Double(k) * 22.5 * .pi / 180
                    let r0 = r * 0.77, r1 = r * 0.88
                    var tick = Path()
                    tick.move(to: CGPoint(x: c.x + CGFloat(sin(a)) * r0, y: c.y - CGFloat(cos(a)) * r0))
                    tick.addLine(to: CGPoint(x: c.x + CGFloat(sin(a)) * r1, y: c.y - CGFloat(cos(a)) * r1))
                    ctx.stroke(tick, with: .color(p.primary.opacity(0.28)), style: StrokeStyle(lineWidth: max(m.u(0.6), 0.5), lineCap: .round))
                }
            }
            // Intercardinal labels only fit as abbreviations (NE); long localized names leave just the tick.
            ForEach(Self.marks.filter { $0.2 || L($0.0).count <= 3 }, id: \.0) { label, angle, major in
                let a = angle * .pi / 180
                let rr = s * 0.39
                Text(L(label))
                    .font(.dock(m.u(major ? 7.5 : 5), major ? .bold : .semibold))
                    .foregroundStyle(major ? p.primary.opacity(0.83) : p.secondary)
                    .fixedSize()
                    .offset(x: CGFloat(sin(a)) * rr, y: -CGFloat(cos(a)) * rr)
            }
            Image(systemName: "location.fill")
                .font(.system(size: m.u(10.5), weight: .bold))
                .foregroundStyle(p.primary.opacity(0.8))
                // Centre the arrow's visual mass on the rose (the glyph sits high-right in its frame).
                .offset(x: m.u(-0.7), y: m.u(1.2))
                .rotationEffect(.degrees(direction + 180 - 45))
                .animation(.easeOut(duration: 0.4), value: direction)
        }
        .frame(width: s, height: s)
        .environment(\.layoutDirection, .leftToRight)
    }
}
