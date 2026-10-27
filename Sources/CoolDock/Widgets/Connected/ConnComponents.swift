import SwiftUI

// MARK: - Formatting

enum ConnFmt {
    /// "$12,450" · "143,86 US$" · "$1.2M". Whole units at ≥ 1 000, cents below.
    static func money(_ value: Double, _ code: String?, decimals: Int? = nil) -> String {
        guard let code, !code.isEmpty else { return count(value) }
        if abs(value) >= 1_000_000 {
            let s = currency(value / 1_000_000, code, decimals: 1)
            return insertSuffix(L("M"), into: s)
        }
        return currency(value, code, decimals: decimals ?? (abs(value) >= 1000 ? 0 : 2))
    }

    /// "1 284" / "12K" / "1.2M" (compact above 100 000 so tiles never overflow).
    static func count(_ value: Double) -> String {
        if abs(value) >= 100_000 { return Fmt.compact(value) }
        guard let loc = ConnectedScene.numberLocale else { return Fmt.int(Int(value.rounded())) }
        return value.rounded().formatted(.number.precision(.fractionLength(0)).locale(loc))
    }

    /// `Fmt.currency`, or the reference frame's locale while rendering the reference scene.
    private static func currency(_ value: Double, _ code: String, decimals: Int) -> String {
        guard let loc = ConnectedScene.numberLocale else { return Fmt.currency(value, code: code, decimals: decimals) }
        return value.formatted(.currency(code: code).precision(.fractionLength(decimals)).locale(loc))
    }

    /// "↑ 27%" / "↓ 4%".
    static func delta(_ d: Double) -> String {
        (d >= 0 ? "↑ " : "↓ ") + Fmt.percent(abs(d))
    }

    /// Puts a magnitude suffix right after the last digit ("$1.2" → "$1.2M", "1,2 US$" → "1,2M US$").
    private static func insertSuffix(_ suffix: String, into s: String) -> String {
        guard let i = s.lastIndex(where: { $0.isNumber }) else { return s + suffix }
        var out = s
        out.insert(contentsOf: suffix, at: out.index(after: i))
        return out
    }
}

// MARK: - Layout helpers

extension View {
    /// Places the view so its first text baseline sits `y` points below the top of the
    /// enclosing `ZStack(alignment: .top…)`. Font-agnostic (works for Estedad too).
    func connBaseline(_ y: CGFloat) -> some View {
        alignmentGuide(.top) { $0[.firstTextBaseline] - y }
    }
}

/// Tiny warning glyph shown next to a caption when the last refresh failed (value is stale).
struct ConnWarning: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p

    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: m.u(8), weight: .bold))
            .foregroundStyle(p.accent(.cdOrange))
    }
}

/// Caption line: secondary text plus a stale-data glyph when needed.
struct ConnCaption: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    var text: String
    var size: CGFloat = 9
    var stale = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: m.u(3)) {
            // Captions are SF Pro medium in the reference frames (not the tiles' Rounded).
            Text(text).dock(size, .medium, p.secondary, design: .default)
            if stale { ConnWarning() }
        }
    }
}

// MARK: - Charts

/// Smoothed line with a horizontal colour gradient and a soft area fill. Always left-to-right.
struct ConnSparkline: View {
    @Environment(\.palette) private var p
    var values: [Double]
    var colors: [Color]
    var lineWidth: CGFloat = 1.8
    var fillOpacity: Double = 0.22
    var smooth = true

    var body: some View {
        Canvas { ctx, size in
            let accents = colors.map { p.accent($0) }
            guard let first = accents.first else { return }
            let inset = lineWidth / 2 + 0.5
            guard values.count > 1 else {
                // Not enough points: a quiet baseline keeps the layout steady.
                var line = Path()
                line.move(to: CGPoint(x: inset, y: size.height - inset))
                line.addLine(to: CGPoint(x: size.width - inset, y: size.height - inset))
                ctx.stroke(line, with: .color(first.opacity(0.35)), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                return
            }
            let lo = values.min() ?? 0
            let hi = values.max() ?? 1
            let flat = hi - lo < 0.000_001
            let span = flat ? 1 : hi - lo
            let step = (size.width - inset * 2) / CGFloat(values.count - 1)
            let pts = values.enumerated().map { i, v in
                CGPoint(x: inset + CGFloat(i) * step,
                        y: flat ? size.height * 0.7 : inset + (size.height - inset * 2) * (1 - CGFloat((v - lo) / span)))
            }
            let line = smooth ? Path.smooth(pts) : Path.polyline(pts)
            var area = line
            area.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: size.height))
            area.addLine(to: CGPoint(x: pts[0].x, y: size.height))
            area.closeSubpath()
            let tint = accents[accents.count - 1]
            ctx.fill(area, with: .linearGradient(Gradient(colors: [tint.opacity(fillOpacity), tint.opacity(0)]),
                                                 startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            let shading: GraphicsContext.Shading = accents.count > 1
                ? .linearGradient(Gradient(colors: accents), startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: size.width, y: 0))
                : .color(first)
            ctx.stroke(line, with: shading, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
        .environment(\.layoutDirection, .leftToRight)
    }
}

/// GitHub-style contribution dots. Days fill columns top-to-bottom, oldest at the leading edge.
struct ConnContributionGrid: View {
    @Environment(\.palette) private var p
    var counts: [Double]
    var columns: Int
    var rows: Int
    var dot: CGFloat
    var color: Color = .cdGreen

    var body: some View {
        Canvas { ctx, size in
            let total = columns * rows
            let days = Array(counts.suffix(total))
            let padded = Array(repeating: -1.0, count: max(total - days.count, 0)) + days
            let levels = Self.levels(days)
            let ramp = color == .cdGreen && !p.monochrome ? Self.greens : (1...4).map { p.accent(color).opacity([0.42, 0.62, 0.82, 1][$0 - 1]) }
            let pitchX = columns > 1 ? (size.width - dot) / CGFloat(columns - 1) : 0
            let pitchY = rows > 1 ? (size.height - dot) / CGFloat(rows - 1) : 0
            for i in 0..<total {
                let c = i / rows, r = i % rows
                let rect = CGRect(x: CGFloat(c) * pitchX, y: CGFloat(r) * pitchY, width: dot, height: dot)
                let v = padded[i]
                let fill: Color
                if v < 0 {
                    fill = p.primary.opacity(0.06)
                } else {
                    let level = levels(v)
                    fill = level == 0 ? p.primary.opacity(0.12) : ramp[level - 1]
                }
                ctx.fill(Path(ellipseIn: rect), with: .color(fill))
            }
        }
        .environment(\.layoutDirection, .leftToRight)
    }

    /// GitHub-style green ramp (levels 1–4); the top two are measured from the reference frame.
    static let greens: [Color] = [Color(hex: "#1B6A35"), Color(hex: "#24853F"), Color(hex: "#2EA14E"), Color(hex: "#42C464")]

    /// Four intensity levels relative to the 90th percentile of active days, so one outlier
    /// day doesn't wash out the rest of the grid.
    static func levels(_ values: [Double]) -> (Double) -> Int {
        let nz = values.filter { $0 > 0 }.sorted()
        guard !nz.isEmpty else { return { _ in 0 } }
        let ref = max(nz[min(nz.count - 1, Int(Double(nz.count - 1) * 0.9))], 1)
        return { v in
            guard v > 0 else { return 0 }
            return max(1, min(4, Int((v / ref * 4).rounded(.up))))
        }
    }
}

/// Subtle press feedback for whole-tile buttons.
struct ConnTilePress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
