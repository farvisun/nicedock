import SwiftUI

// MARK: - Flip clock

/// Four split-flap cards that fill the tile edge to edge (no tile chrome, as in the reference).
struct ClockFlipView: View {
    let w: WidgetInstance
    @Environment(\.metrics) private var m

    var body: some View {
        ClockTicker { date in
            let g = Self.glyphs(Fmt.clock(date))
            HStack(spacing: 0) {
                ClockFlipCard(glyph: g[0])
                Spacer().frame(width: m.u(3.5))
                ClockFlipCard(glyph: g[1])
                Spacer().frame(width: m.u(5))
                ClockFlipCard(glyph: g[2])
                Spacer().frame(width: m.u(3.5))
                ClockFlipCard(glyph: g[3])
            }
            .padding(.horizontal, m.u(1))
            // The reference cards sit half a point low.
            .offset(y: m.u(0.5))
        }
        .frame(width: m.u(w.kind.spec.width), height: m.tileHeight)
        .environment(\.layoutDirection, .leftToRight)
        .contentShape(Rectangle())
    }

    /// "9:41" → [" ", "9", "4", "1"]; "12:34" → ["1", "2", "3", "4"].
    static func glyphs(_ s: String) -> [String] {
        let parts = s.split(separator: ":").map { $0.map(String.init) }
        var hours = parts.first ?? []
        let minutes = parts.count > 1 ? parts[1] : []
        while hours.count < 2 { hours.insert("", at: 0) }
        var out = Array(hours.suffix(2)) + Array(minutes.prefix(2))
        while out.count < 4 { out.append("") }
        return out
    }
}

private struct ClockFlipCard: View {
    var glyph: String
    @State private var from: String?
    @State private var progress: Double = 1
    @Environment(\.metrics) private var m

    var body: some View {
        ClockFlipStack(old: from ?? glyph, new: glyph, progress: progress)
            .frame(maxWidth: .infinity)
            .frame(height: m.tileHeight)
            .clipShape(RoundedRectangle(cornerRadius: m.u(6), style: .continuous))
            .onChange(of: glyph) { old, _ in
                from = old
                progress = 0
                withAnimation(.easeIn(duration: 0.5)) { progress = 1 }
            }
    }
}

/// Static halves plus the falling flap; `progress` 0 → 1 drives the flip.
private struct ClockFlipStack: View, Animatable {
    var old: String
    var new: String
    var progress: Double
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let flipping = progress < 1
        ZStack {
            VStack(spacing: 0) {
                ClockFlipHalf(glyph: new, top: true)
                ClockFlipHalf(glyph: flipping ? old : new, top: false)
            }
            if flipping {
                if progress < 0.5 {
                    ClockFlipHalf(glyph: old, top: true, opaque: true)
                        .rotation3DEffect(.degrees(progress * 180), axis: (x: -1, y: 0, z: 0), anchor: .bottom, perspective: 0.45)
                        .frame(maxHeight: .infinity, alignment: .top)
                } else {
                    ClockFlipHalf(glyph: new, top: false, opaque: true)
                        .rotation3DEffect(.degrees((1 - progress) * 180), axis: (x: 1, y: 0, z: 0), anchor: .top, perspective: 0.45)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            // The split: a faint 2 pt highlight drawn over the numeral (≈24 % white in the reference).
            Rectangle()
                .fill(p.primary.opacity(p.isLight ? 0.25 : 0.28))
                .frame(height: m.u(2))
        }
    }
}

private struct ClockFlipHalf: View {
    var glyph: String
    var top: Bool
    var opaque = false
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p

    private var fill: Color {
        if opaque { return Color(white: p.isLight ? (top ? 0.92 : 0.88) : (top ? 0.13 : 0.18)) }
        return p.primary.opacity(p.isLight ? (top ? 0.06 : 0.09) : (top ? 0.114 : 0.174))
    }

    var body: some View {
        let h = m.tileHeight
        ZStack {
            fill
            Text(verbatim: glyph)
                .font(.dock(m.u(41.5), .bold, mono: true))
                .foregroundStyle(p.clockInk)
                .offset(y: ClockFormat.digitDrop(m.u(41.5)))
                .frame(maxWidth: .infinity)
                .frame(height: h)
                .frame(height: h / 2, alignment: top ? .top : .bottom)
                .clipped()
        }
        .frame(height: h / 2)
    }
}

// MARK: - Analog clocks

struct ClockAnalogView: View {
    let w: WidgetInstance
    let light: Bool
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p

    var body: some View {
        let seconds = w.bool("seconds", true)
        let diameter = m.u(50)
        // The reference faces sit a little right of and below the tile centre.
        let shift = CGSize(width: light ? 1 : 0.5, height: 0.5)
        Tile(width: w.kind.spec.width) {
            ClockTicker(seconds: seconds) { date in
                let hands = ClockHands(date)
                Canvas { ctx, size in
                    if light {
                        ClockAnalogDraw.light(ctx, size: size, hands: hands, seconds: seconds)
                    } else {
                        ClockAnalogDraw.dark(ctx, size: size, hands: hands, seconds: seconds, ink: p.clockInk,
                                             ring: p.primary.opacity(0.151), second: p.accent(ClockTint.stopwatch),
                                             hub: p.primary.opacity(0.87))
                    }
                }
                .frame(width: diameter, height: diameter)
                .offset(x: m.u(shift.width), y: m.u(shift.height))
            }
        }
        .environment(\.layoutDirection, .leftToRight)
    }
}

/// Hand angles in degrees, clockwise from 12.
private struct ClockHands {
    var hour: Double
    var minute: Double
    var second: Double

    init(_ date: Date) {
        let c = Calendar.current.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        let s = Double(c.second ?? 0), mi = Double(c.minute ?? 0), h = Double((c.hour ?? 0) % 12)
        if ReferenceScene.isActive {
            // The reference frames pose a quartz movement: hour and minute hands on their marks,
            // the seconds hand at a fractional second.
            second = (s + Double(c.nanosecond ?? 0) / 1e9) * 6
            minute = mi * 6
            hour = (h + mi / 60) * 30
            return
        }
        second = s * 6
        minute = (mi + s / 60) * 6
        hour = (h + mi / 60 + s / 3600) * 30
    }
}

private enum ClockAnalogDraw {
    static let lightHand = Color(white: 0.12)
    static let lightHub = Color(white: 0.18)
    static let lightTick = Color(white: 0.28)
    static let lightDot = Color(white: 0.75)
    static let lightRing = Color(white: 0.95)
    static let lightEdge = Color(white: 0.9)
    static let lightRed = Color(red: 232 / 255, green: 61 / 255, blue: 51 / 255)

    /// Point at `radius` along `degrees` (clockwise from 12) from `c`.
    static func point(_ c: CGPoint, _ degrees: Double, _ radius: CGFloat) -> CGPoint {
        let a = (degrees - 90) * .pi / 180
        return CGPoint(x: c.x + radius * CGFloat(cos(a)), y: c.y + radius * CGFloat(sin(a)))
    }

    /// Point `radius` along the hand and `side` across it (positive = clockwise side).
    static func point(_ c: CGPoint, _ degrees: Double, _ radius: CGFloat, side: CGFloat) -> CGPoint {
        let p = point(c, degrees, radius)
        let a = degrees * .pi / 180
        return CGPoint(x: p.x + side * CGFloat(cos(a)), y: p.y + side * CGFloat(sin(a)))
    }

    static func hand(_ ctx: GraphicsContext, _ c: CGPoint, _ degrees: Double, length: CGFloat, tail: CGFloat, width: CGFloat, color: Color, cap: CGLineCap = .round) {
        var path = Path()
        path.move(to: point(c, degrees + 180, tail))
        path.addLine(to: point(c, degrees, length))
        ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: cap))
    }

    /// A hand that narrows from `base` at the hub to `tip`, with a straight counterweight of `tailWidth`.
    static func taperedHand(_ ctx: GraphicsContext, _ c: CGPoint, _ degrees: Double, length: CGFloat, base: CGFloat, tip: CGFloat,
                            tail: CGFloat, tailWidth: CGFloat, color: Color) {
        var path = Path()
        path.move(to: point(c, degrees, -tail, side: -tailWidth / 2))
        path.addLine(to: point(c, degrees, 0, side: -base / 2))
        path.addLine(to: point(c, degrees, length, side: -tip / 2))
        path.addLine(to: point(c, degrees, length, side: tip / 2))
        path.addLine(to: point(c, degrees, 0, side: base / 2))
        path.addLine(to: point(c, degrees, -tail, side: tailWidth / 2))
        path.closeSubpath()
        ctx.fill(path, with: .color(color))
    }

    static func disc(_ ctx: GraphicsContext, _ c: CGPoint, _ r: CGFloat, _ color: Color) {
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(color))
    }

    /// Classic white face: a soft rim, a faint inner ring, minute dots, hour ticks (longer quarters),
    /// tapered black hour/minute hands and a thin red seconds hand.
    static func light(_ ctx: GraphicsContext, size: CGSize, hands: ClockHands, seconds: Bool) {
        let d = min(size.width, size.height)
        let k = d / 50 // design units → points
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let face = CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
        ctx.fill(Path(ellipseIn: face), with: .radialGradient(
            Gradient(stops: [.init(color: .white, location: 0), .init(color: .white, location: 0.94),
                             .init(color: lightEdge, location: 0.98), .init(color: lightEdge, location: 1)]),
            center: c, startRadius: 0, endRadius: d / 2))
        let ringR = 21.55 * k
        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - ringR, y: c.y - ringR, width: ringR * 2, height: ringR * 2)),
                   with: .color(lightRing), lineWidth: 0.7 * k)

        // Minute dots.
        let dot = 1.1 * k
        for i in 0..<60 where i % 5 != 0 {
            let pt = point(c, Double(i) * 6, 19.2 * k)
            ctx.fill(Path(CGRect(x: pt.x - dot / 2, y: pt.y - dot / 2, width: dot, height: dot)), with: .color(lightDot))
        }
        // Hour ticks: the quarters are longer and heavier.
        for i in 0..<12 {
            let quarter = i % 3 == 0
            var path = Path()
            path.move(to: point(c, Double(i) * 30, (quarter ? 17.3 : 17.6) * k))
            path.addLine(to: point(c, Double(i) * 30, (quarter ? 21.5 : 21.1) * k))
            ctx.stroke(path, with: .color(lightTick),
                       style: StrokeStyle(lineWidth: (quarter ? 2 : 1) * k, lineCap: .round))
        }

        taperedHand(ctx, c, hands.hour, length: 13.35 * k, base: 3 * k, tip: 1.05 * k,
                    tail: 3.65 * k, tailWidth: 1.3 * k, color: lightHand)
        taperedHand(ctx, c, hands.minute, length: 19.35 * k, base: 1.9 * k, tip: 1.1 * k,
                    tail: 4.75 * k, tailWidth: 1.4 * k, color: lightHand)
        disc(ctx, c, 2.5 * k, lightHub)
        if seconds {
            taperedHand(ctx, c, hands.second, length: 20.75 * k, base: 0.75 * k, tip: 0.2 * k,
                        tail: 5.5 * k, tailWidth: 0.7 * k, color: lightRed)
        }
        disc(ctx, c, 1.05 * k, lightRed)
    }

    /// Minimal dark face: a faint ring, white hour and minute hands, a long blue seconds hand.
    static func dark(_ ctx: GraphicsContext, size: CGSize, hands: ClockHands, seconds: Bool, ink: Color, ring: Color, second: Color, hub: Color) {
        let d = min(size.width, size.height)
        let k = d / 50
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d).insetBy(dx: 0.5 * k, dy: 0.5 * k)),
                   with: .color(ring), lineWidth: 1 * k)
        hand(ctx, c, hands.hour, length: 11 * k, tail: 1 * k, width: 2 * k, color: ink)
        hand(ctx, c, hands.minute, length: 18 * k, tail: 1.8 * k, width: 0.85 * k, color: ink, cap: .butt)
        if seconds {
            hand(ctx, c, hands.second, length: 20 * k, tail: 1.85 * k, width: 0.95 * k, color: second, cap: .butt)
        }
        disc(ctx, c, 1.5 * k, hub)
    }
}

// MARK: - Pixel clock

/// Dot-matrix time (5 × 7 dots per digit) in the widget's accent colour over dim off-dots.
struct ClockPixelView: View {
    let w: WidgetInstance
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p

    var body: some View {
        let accent = p.accent(Color(hex: w.string("color", "#30D158")))
        Tile(width: w.kind.spec.width, padding: .hv(11, 12)) {
            ClockTicker { date in
                let text = Fmt.clock(date)
                Canvas { ctx, size in
                    ClockDotMatrix.draw(text, in: ctx, size: size, on: accent, off: accent.opacity(0.12))
                }
            }
        }
        .environment(\.layoutDirection, .leftToRight)
    }
}

enum ClockDotMatrix {
    /// Column bitmaps (5 wide × 7 tall) for Latin, Persian (۰–۹) and Arabic-Indic (٠–٩) digits.
    private static let glyphs: [Character: [String]] = {
        var g: [Character: [String]] = [
            "0": [".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
            "1": ["..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###."],
            "2": [".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####"],
            "3": [".###.", "#...#", "....#", "..##.", "....#", "#...#", ".###."],
            "4": ["...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#."],
            "5": ["#####", "#....", "####.", "....#", "....#", "#...#", ".###."],
            "6": ["..##.", ".#...", "#....", "####.", "#...#", "#...#", ".###."],
            "7": ["#####", "....#", "...#.", "..#..", ".#...", ".#...", ".#..."],
            "8": [".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###."],
            "9": [".###.", "#...#", "#...#", ".####", "....#", "...#.", ".##.."]
        ]
        let persian: [[String]] = [
            [".....", ".....", "..#..", ".#.#.", "..#..", ".....", "....."], // ۰
            [".#...", "..#..", "..#..", "..#..", "..#..", "..#..", "..#.."], // ۱
            ["#...#", "#...#", ".###.", ".#...", "..#..", "..#..", "..#.."], // ۲
            ["#.#.#", "#.#.#", ".#.#.", ".#...", "..#..", "..#..", "..#.."], // ۳
            ["..###", ".#...", "..##.", ".#...", "#....", "#....", ".###."], // ۴
            ["..#..", ".#.#.", "#...#", "#...#", "#...#", "#.#.#", ".#.#."], // ۵
            ["####.", "....#", "....#", "...#.", "..#..", ".#...", "#...."], // ۶
            ["#...#", "#...#", ".#.#.", ".#.#.", ".#.#.", "..#..", "..#.."], // ۷
            ["..#..", "..#..", ".#.#.", ".#.#.", ".#.#.", "#...#", "#...#"], // ۸
            [".###.", "#...#", "#...#", ".####", "....#", "....#", "....#"]  // ۹
        ]
        for (i, rows) in persian.enumerated() {
            g[Character(UnicodeScalar(0x06F0 + i)!)] = rows
            g[Character(UnicodeScalar(0x0660 + i)!)] = rows
        }
        // Arabic-Indic 4, 5, 6 differ from the Persian forms.
        g["٤"] = ["...##", "..#..", ".#...", "..##.", ".#...", "#....", ".####"]
        g["٥"] = [".....", "..#..", ".#.#.", "#...#", "#...#", ".#.#.", "..#.."]
        g["٦"] = ["####.", "....#", "....#", "....#", "....#", "....#", "....#"]
        return g
    }()

    private static func columns(_ ch: Character) -> Int { ch == ":" ? 1 : 5 }

    static func draw(_ text: String, in ctx: GraphicsContext, size: CGSize, on: Color, off: Color) {
        let chars = Array(text)
        guard !chars.isEmpty else { return }
        let cols = chars.reduce(0) { $0 + columns($1) } + chars.count - 1
        let pitch = min(size.width / CGFloat(cols), size.height / 7)
        let d = pitch * 0.78
        let x0 = (size.width - pitch * CGFloat(cols)) / 2
        let y0 = (size.height - pitch * 7) / 2

        var lit = Path()
        var dim = Path()
        var col = 0
        for (i, ch) in chars.enumerated() {
            let w = columns(ch)
            let rows: [String]
            if ch == ":" {
                rows = [".", ".", "#", ".", "#", ".", "."]
            } else {
                rows = glyphs[ch] ?? Array(repeating: ".....", count: 7)
            }
            for r in 0..<7 {
                let bits = Array(rows[r])
                for c in 0..<w {
                    let rect = CGRect(x: x0 + CGFloat(col + c) * pitch + (pitch - d) / 2, y: y0 + CGFloat(r) * pitch + (pitch - d) / 2, width: d, height: d)
                    if c < bits.count, bits[c] == "#" { lit.addEllipse(in: rect) } else { dim.addEllipse(in: rect) }
                }
            }
            col += w
            // Dim spacer column between characters keeps the matrix uniform.
            if i < chars.count - 1 {
                for r in 0..<7 {
                    dim.addEllipse(in: CGRect(x: x0 + CGFloat(col) * pitch + (pitch - d) / 2, y: y0 + CGFloat(r) * pitch + (pitch - d) / 2, width: d, height: d))
                }
                col += 1
            }
        }
        ctx.fill(dim, with: .color(off))
        ctx.fill(lit, with: .color(on))
    }
}
