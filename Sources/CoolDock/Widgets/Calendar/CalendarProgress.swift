import SwiftUI

// MARK: - Period math

/// Elapsed fraction of a calendar period, using `Fmt.calendar` so Persian months and years are honoured.
enum CalPeriod: String {
    case day, week, month, year

    func fraction(_ now: Date) -> Double {
        let cal = Fmt.calendar
        let component: Calendar.Component
        switch self {
        case .day: component = .day
        case .week: component = .weekOfYear
        case .month: component = .month
        case .year: component = .year
        }
        guard let interval = cal.dateInterval(of: component, for: now), interval.duration > 0 else { return 0 }
        return max(0, min(1, now.timeIntervalSince(interval.start) / interval.duration))
    }

    /// Whole percent, rounded down so 100 % only shows at the very end.
    func percentText(_ now: Date) -> String { Fmt.percent(floor(fraction(now) * 100) / 100) }
}

// MARK: - Dot-grid progress (day / month / year)

struct CalProgressGridWidget: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    let w: WidgetInstance

    var body: some View {
        TimelineView(.everyMinute) { ctx in
            let g = layout(ctx.date)
            Tile(width: w.kind.spec.width) {
                VStack(spacing: 0) {
                    CalDotGrid(total: g.total, filled: g.filled, columns: g.columns, pitch: m.u(g.pitch))
                        .frame(height: m.u(36))
                        .padding(.top, m.u(7))
                    Spacer(minLength: 0)
                    HStack(alignment: .firstTextBaseline, spacing: m.u(4)) {
                        Text(verbatim: g.label).dock(9, .bold, p.secondary).minimumScaleFactor(0.75)
                        Spacer(minLength: 0)
                        Text(verbatim: g.period.percentText(ctx.date)).dock(9.5, .bold, mono: true)
                    }
                    .padding(EdgeInsets(top: 0, leading: m.u(6), bottom: m.u(4.5), trailing: m.u(5.5)))
                }
            }
        }
    }

    private struct Layout {
        var period: CalPeriod
        var total: Int
        var filled: Int
        var columns: Int
        var label: String
        var pitch: CGFloat
    }

    private func layout(_ now: Date) -> Layout {
        let cal = Fmt.calendar
        switch w.kind {
        case .dayProgress:
            let f = CalPeriod.day.fraction(now)
            return Layout(period: .day, total: 24, filled: lit(f, 24), columns: 8, label: Fmt.date(now, "MMMMd"), pitch: 12)
        case .monthProgress:
            let days = cal.range(of: .day, in: .month, for: now)?.count ?? 30
            let columns = Int(ceil(Double(days) / 3))
            let f = CalPeriod.month.fraction(now)
            return Layout(period: .month, total: days, filled: lit(f, days), columns: columns, label: Fmt.date(now, "MMMMy"),
                          pitch: min(10.1, 101 / CGFloat(columns)))
        default:
            let f = CalPeriod.year.fraction(now)
            return Layout(period: .year, total: 52, filled: lit(f, 52), columns: 13, label: Fmt.year(now), pitch: 9)
        }
    }

    /// Dots up to and including the current unit are lit.
    private func lit(_ fraction: Double, _ total: Int) -> Int { max(1, min(total, Int(ceil(fraction * Double(total))))) }
}

/// Fixed-pitch dot grid drawn in one Canvas pass, centred in its frame. Always left-to-right like a chart.
struct CalDotGrid: View {
    @Environment(\.palette) private var p
    var total: Int
    var filled: Int
    var columns: Int
    /// Centre-to-centre distance; shrinks to fit when the frame is smaller.
    var pitch: CGFloat
    var dotRatio: CGFloat = 0.82

    var body: some View {
        Canvas { ctx, size in
            guard total > 0, columns > 0 else { return }
            let rows = Int(ceil(Double(total) / Double(columns)))
            let step = min(pitch, size.width / CGFloat(columns), size.height / CGFloat(max(rows, 1)))
            let d = step * dotRatio
            let x0 = (size.width - step * CGFloat(columns)) / 2
            let y0 = (size.height - step * CGFloat(rows)) / 2
            let on = p.primary.opacity(0.88)
            let off = p.primary.opacity(0.13)
            for i in 0..<total {
                let r = i / columns, c = i % columns
                let cx = x0 + (CGFloat(c) + 0.5) * step
                let cy = y0 + (CGFloat(r) + 0.5) * step
                ctx.fill(Path(ellipseIn: CGRect(x: cx - d / 2, y: cy - d / 2, width: d, height: d)), with: .color(i < filled ? on : off))
            }
        }
        .environment(\.layoutDirection, .leftToRight)
    }
}

// MARK: - Progress ring

struct CalProgressRingWidget: View {
    @Environment(\.metrics) private var m
    let w: WidgetInstance

    var body: some View {
        let period = CalPeriod(rawValue: w.string("period", "day")) ?? .day
        let color = Color(hex: w.string("color", "#30D158"))
        TimelineView(.everyMinute) { ctx in
            Tile(width: w.kind.spec.width) {
                RingGauge(value: period.fraction(ctx.date), color: color, lineWidth: 6.2, diameter: 46.5) {
                    Text(verbatim: period.percentText(ctx.date)).dock(12, .semibold, mono: true).minimumScaleFactor(0.7)
                        .padding(.horizontal, m.u(7))
                }
                .environment(\.layoutDirection, .leftToRight)
            }
            .help(Self.title(period, ctx.date))
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // Click cycles day → week → month → year.
            let order: [CalPeriod] = [.day, .week, .month, .year]
            let next = order[((order.firstIndex(of: period) ?? 0) + 1) % order.count]
            AppStore.shared.updateWidget(w.id) { $0.config["period"] = next.rawValue }
        }
    }

    private static func title(_ period: CalPeriod, _ now: Date) -> String {
        switch period {
        case .day: return L("Day Progress") + " · " + Fmt.date(now, "MMMMd")
        case .week: return L("Week Progress")
        case .month: return L("Month Progress") + " · " + Fmt.date(now, "MMMMy")
        case .year: return L("Year Progress") + " · " + Fmt.year(now)
        }
    }
}
