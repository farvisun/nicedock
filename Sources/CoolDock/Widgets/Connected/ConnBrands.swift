import SwiftUI

/// Services drawn by `ConnBrandMark`.
enum ConnBrand {
    case polar, stripe, dodo, shopify, plausible, simpleAnalytics, visitors, dataFast
    case dub, resend, github, supabase, x, tiktok, youtube, claude, codex, openai
}

/// Drawn brand marks (no bundled artwork). `icon` = rounded-square "app icon" variant used for the
/// large 44 pt marks; otherwise a round badge. Brand surfaces keep their own colours.
struct ConnBrandMark: View {
    @Environment(\.metrics) private var m
    var brand: ConnBrand
    var size: CGFloat = 18
    var icon = false

    var body: some View {
        let s = m.u(size)
        mark(s)
            .frame(width: s, height: s)
            .compositingGroup()
            .environment(\.layoutDirection, .leftToRight)
            .accessibilityHidden(true)
    }

    private func squircle(_ s: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: s * 0.225, style: .continuous)
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    @ViewBuilder private func mark(_ s: CGFloat) -> some View {
        switch brand {
        case .polar:
            ZStack {
                Circle().fill(Color.black.opacity(0.1))
                Circle().strokeBorder(Color.white.opacity(0.42), lineWidth: max(s * 0.055, 0.8))
                Group {
                    Ellipse().stroke(Color.white, lineWidth: s * 0.05).frame(width: s * 0.61, height: s * 0.61)
                    Ellipse().stroke(Color.white, lineWidth: s * 0.05).frame(width: s * 0.43, height: s * 0.61)
                    Ellipse().stroke(Color.white, lineWidth: s * 0.05).frame(width: s * 0.26, height: s * 0.61)
                }
            }
        case .stripe:
            ZStack {
                (icon ? AnyShape(squircle(s)) : AnyShape(Circle())).fill(Color(hex: "#635BFF"))
                Text(verbatim: "S").font(.system(size: s * 0.6, weight: .heavy, design: .rounded)).foregroundStyle(Color.white)
            }
        case .dodo:
            ZStack {
                Circle().fill(Color(hex: "#C7FA1E"))
                Circle().strokeBorder(Color(hex: "#DAF88E"), lineWidth: s / 18)
                ConnGlyph(d: ConnBrandPaths.dodo, viewBox: ConnBrandPaths.unit100)
                    .fill(Color(hex: "#0D0D0D"), style: FillStyle(eoFill: true))
            }
        case .shopify:
            ZStack {
                if icon {
                    // Shopify's own icon artwork has rounder corners than the system squircle.
                    RoundedRectangle(cornerRadius: s * 0.26, style: .continuous)
                        .fill(LinearGradient(colors: [Color.white, Color(hex: "#ECECEC")], startPoint: .top, endPoint: .bottom))
                } else {
                    Circle().fill(Color.white)
                }
                ConnShopifyBag()
                    .frame(width: s * (icon ? 0.79 : 0.694), height: s * (icon ? 0.739 : 0.694))
                    .offset(x: icon ? -s * 0.01 : 0)
            }
        case .plausible:
            ZStack {
                Circle().fill(LinearGradient(colors: [Color.white, Color(hex: "#ECECF1")], startPoint: .top, endPoint: .bottom))
                ConnPlausibleP()
                    .fill(LinearGradient(colors: [Color(hex: "#7E80EC"), Color(hex: "#5A4DDF"), Color(hex: "#5446DC")],
                                         startPoint: .topTrailing, endPoint: .bottomLeading))
                    .frame(width: s * 0.58, height: s * 0.78)
                    .overlay(ConnPlausibleSpark().stroke(Color.white, style: StrokeStyle(lineWidth: max(s * 0.035, 0.7), lineCap: .round, lineJoin: .round)))
                    .offset(x: s * 0.04)
            }
        case .simpleAnalytics, .visitors:
            ZStack(alignment: .topLeading) {
                Circle().fill(Color(hex: "#FDFDFD"))
                bar(s, x: 0.108, width: 0.211, top: 0.292, color: Color(hex: "#F2C3B3"))
                bar(s, x: 0.417, width: 0.166, top: 0.125, color: Color(hex: "#E26440"))
                bar(s, x: 0.708, width: 0.167, top: 0.403, color: Color(hex: "#F2C3B3"))
            }
        case .dataFast:
            BrandBadge(brand: .dataFast, size: size)
        case .dub:
            ConnDubShape().fill(Color.white, style: FillStyle(eoFill: true)).clipShape(Circle())
        case .resend:
            ZStack {
                (icon ? AnyShape(squircle(s)) : AnyShape(Circle())).fill(Color.black)
                ConnGlyph(d: ConnBrandPaths.resend)
                    .fill(LinearGradient(colors: [Color(white: 0.98), Color(white: 0.33)], startPoint: .top, endPoint: .bottom))
                    .frame(width: s * 0.511, height: s * 0.511)
            }
        case .github:
            BrandBadge(brand: .github, size: size)
        case .supabase:
            ZStack {
                (icon ? AnyShape(squircle(s)) : AnyShape(Circle())).fill(Color(hex: "#1C1C1C"))
                (icon ? AnyShape(squircle(s)) : AnyShape(Circle())).stroke(Color.white.opacity(0.12), lineWidth: 1)
                Image(systemName: "bolt.fill").font(.system(size: s * 0.5))
                    .foregroundStyle(LinearGradient(colors: [Color(hex: "#3ECF8E"), Color(hex: "#24935F")], startPoint: .top, endPoint: .bottom))
            }
        case .x:
            ZStack {
                Circle().fill(Color.black)
                ConnGlyph(d: ConnBrandPaths.x).fill(Color.white).frame(width: s * 0.568, height: s * 0.568)
            }
        case .tiktok:
            ZStack {
                Circle().fill(Color.white)
                ZStack {
                    ConnGlyph(d: ConnBrandPaths.tiktok).fill(Color(hex: "#2CCAD1")).offset(x: -s * 0.023, y: -s * 0.023)
                    ConnGlyph(d: ConnBrandPaths.tiktok).fill(Color(hex: "#F2264A")).offset(x: s * 0.023, y: s * 0.023)
                    ConnGlyph(d: ConnBrandPaths.tiktok).fill(Color.black)
                }
                .frame(width: s * 0.567, height: s * 0.535)
                .offset(x: s * 0.0125)
            }
        case .youtube:
            ZStack {
                Circle().fill(Color(hex: "#FF2732"))
                ConnGlyph(d: ConnBrandPaths.youtube).fill(Color.white, style: FillStyle(eoFill: true))
                    .frame(width: s * 0.659, height: s * 0.659)
            }
        case .claude:
            ZStack {
                Circle().fill(Color(hex: "#D57554"))
                Circle().strokeBorder(Color(hex: "#E6AE9A"), lineWidth: s / 18)
                ConnGlyph(d: ConnBrandPaths.claude).fill(Color(hex: "#FCF2ED")).frame(width: s * 0.72, height: s * 0.72)
            }
        case .codex:
            BrandBadge(brand: .codex, size: size)
        case .openai:
            BrandBadge(brand: .openai, size: size)
        }
    }

    /// One Simple Analytics bar, in fractions of the mark (all bars end at 85 %).
    private func bar(_ s: CGFloat, x: CGFloat, width: CGFloat, top: CGFloat, color: Color) -> some View {
        RoundedRectangle(cornerRadius: s * 0.02, style: .continuous).fill(color)
            .frame(width: s * width, height: s * (0.847 - top))
            .offset(x: s * x, y: s * top)
    }
}

/// Glyph outlines for the drawn marks (Simple Icons, CC0; Dodo traced from its badge, 0…100 units).
private enum ConnBrandPaths {
    static let unit100 = CGRect(x: 0, y: 0, width: 100, height: 100)
    static let shopify = "M15.337 23.979l7.216-1.561s-2.604-17.613-2.625-17.73c-.018-.116-.114-.192-.211-.192s-1.929-.136-1.929-.136-1.275-1.274-1.439-1.411c-.045-.037-.075-.057-.121-.074l-.914 21.104h.023zM11.71 11.305s-.81-.424-1.774-.424c-1.447 0-1.504.906-1.504 1.141 0 1.232 3.24 1.715 3.24 4.629 0 2.295-1.44 3.76-3.406 3.76-2.354 0-3.54-1.465-3.54-1.465l.646-2.086s1.245 1.066 2.28 1.066c.675 0 .975-.545.975-.932 0-1.619-2.654-1.694-2.654-4.359-.034-2.237 1.571-4.416 4.827-4.416 1.257 0 1.875.361 1.875.361l-.945 2.715-.02.01zM11.17.83c.136 0 .271.038.405.135-.984.465-2.064 1.639-2.508 3.992-.656.213-1.293.405-1.889.578C7.697 3.75 8.951.84 11.17.84V.83zm1.235 2.949v.135c-.754.232-1.583.484-2.394.736.466-1.777 1.333-2.645 2.085-2.971.193.501.309 1.176.309 2.1zm.539-2.234c.694.074 1.141.867 1.429 1.755-.349.114-.735.231-1.158.366v-.252c0-.752-.096-1.371-.271-1.871v.002zm2.992 1.289c-.02 0-.06.021-.078.021s-.289.075-.714.21c-.423-1.233-1.176-2.37-2.508-2.37h-.115C12.135.209 11.669 0 11.265 0 8.159 0 6.675 3.877 6.21 5.846c-1.194.365-2.063.636-2.16.674-.675.213-.694.232-.772.87-.075.462-1.83 14.063-1.83 14.063L15.009 24l.927-21.166z"
    static let x = "M14.234 10.162 22.977 0h-2.072l-7.591 8.824L7.251 0H.258l9.168 13.343L.258 24H2.33l8.016-9.318L16.749 24h6.993zm-2.837 3.299-.929-1.329L3.076 1.56h3.182l5.965 8.532.929 1.329 7.754 11.09h-3.182z"
    static let tiktok = "M12.525.02c1.31-.02 2.61-.01 3.91-.02.08 1.53.63 3.09 1.75 4.17 1.12 1.11 2.7 1.62 4.24 1.79v4.03c-1.44-.05-2.89-.35-4.2-.97-.57-.26-1.1-.59-1.62-.93-.01 2.92.01 5.84-.02 8.75-.08 1.4-.54 2.79-1.35 3.94-1.31 1.92-3.58 3.17-5.91 3.21-1.43.08-2.86-.31-4.08-1.03-2.02-1.19-3.44-3.37-3.65-5.71-.02-.5-.03-1-.01-1.49.18-1.9 1.12-3.72 2.58-4.96 1.66-1.44 3.98-2.13 6.15-1.72.02 1.48-.04 2.96-.04 4.44-.99-.32-2.15-.23-3.02.37-.63.41-1.11 1.04-1.36 1.75-.21.51-.15 1.07-.14 1.61.24 1.64 1.82 3.02 3.5 2.87 1.12-.01 2.19-.66 2.77-1.61.19-.33.4-.67.41-1.06.1-1.79.06-3.57.07-5.36.01-4.03-.01-8.05.02-12.07z"
    static let youtube = "M23.498 6.186a3.016 3.016 0 0 0-2.122-2.136C19.505 3.545 12 3.545 12 3.545s-7.505 0-9.377.505A3.017 3.017 0 0 0 .502 6.186C0 8.07 0 12 0 12s0 3.93.502 5.814a3.016 3.016 0 0 0 2.122 2.136c1.871.505 9.376.505 9.376.505s7.505 0 9.377-.505a3.015 3.015 0 0 0 2.122-2.136C24 15.93 24 12 24 12s0-3.93-.502-5.814zM9.545 15.568V8.432L15.818 12l-6.273 3.568z"
    static let resend = "M14.679 0c4.648 0 7.413 2.765 7.413 6.434s-2.765 6.434-7.413 6.434H12.33L24 24h-8.245l-8.88-8.44c-.636-.588-.93-1.273-.93-1.86 0-.831.587-1.565 1.713-1.883l4.574-1.224c1.737-.465 2.936-1.81 2.936-3.572 0-2.153-1.761-3.4-3.939-3.4H0V0z"
    static let claude = "m4.7144 15.9555 4.7174-2.6471.079-.2307-.079-.1275h-.2307l-.7893-.0486-2.6956-.0729-2.3375-.0971-2.2646-.1214-.5707-.1215-.5343-.7042.0546-.3522.4797-.3218.686.0608 1.5179.1032 2.2767.1578 1.6514.0972 2.4468.255h.3886l.0546-.1579-.1336-.0971-.1032-.0972L6.973 9.8356l-2.55-1.6879-1.3356-.9714-.7225-.4918-.3643-.4614-.1578-1.0078.6557-.7225.8803.0607.2246.0607.8925.686 1.9064 1.4754 2.4893 1.8336.3643.3035.1457-.1032.0182-.0728-.164-.2733-1.3539-2.4467-1.445-2.4893-.6435-1.032-.17-.6194c-.0607-.255-.1032-.4674-.1032-.7285L6.287.1335 6.6997 0l.9957.1336.419.3642.6192 1.4147 1.0018 2.2282 1.5543 3.0296.4553.8985.2429.8318.091.255h.1579v-.1457l.1275-1.706.2368-2.0947.2307-2.6957.0789-.7589.3764-.9107.7468-.4918.5828.2793.4797.686-.0668.4433-.2853 1.8517-.5586 2.9021-.3643 1.9429h.2125l.2429-.2429.9835-1.3053 1.6514-2.0643.7286-.8196.85-.9046.5464-.4311h1.0321l.759 1.1293-.34 1.1657-1.0625 1.3478-.8804 1.1414-1.2628 1.7-.7893 1.36.0729.1093.1882-.0183 2.8535-.607 1.5421-.2794 1.8396-.3157.8318.3886.091.3946-.3278.8075-1.967.4857-2.3072.4614-3.4364.8136-.0425.0304.0486.0607 1.5482.1457.6618.0364h1.621l3.0175.2247.7892.522.4736.6376-.079.4857-1.2142.6193-1.6393-.3886-3.825-.9107-1.3113-.3279h-.1822v.1093l1.0929 1.0686 2.0035 1.8092 2.5075 2.3314.1275.5768-.3218.4554-.34-.0486-2.2039-1.6575-.85-.7468-1.9246-1.621h-.1275v.17l.4432.6496 2.3436 3.5214.1214 1.0807-.17.3521-.6071.2125-.6679-.1214-1.3721-1.9246L14.38 17.959l-1.1414-1.9428-.1397.079-.674 7.2552-.3156.3703-.7286.2793-.6071-.4614-.3218-.7468.3218-1.4753.3886-1.9246.3157-1.53.2853-1.9004.17-.6314-.0121-.0425-.1397.0182-1.4328 1.9672-2.1796 2.9446-1.7243 1.8456-.4128.164-.7164-.3704.0667-.6618.4008-.5889 2.386-3.0357 1.4389-1.882.929-1.0868-.0062-.1579h-.0546l-6.3385 4.1164-1.1293.1457-.4857-.4554.0608-.7467.2307-.2429 1.9064-1.3114Z"
    static let dodo = "M54.2 85.4 34.7 85.4 27.9 76.4 20.1 62.5 16.9 54.2 16.0 43.1 17.8 31.9 16.8 29.2 19.9 26.4 20.8 23.0 40.3 22.3 48.6 25.2 59.7 36.1 70.8 36.5 79.2 38.9 84.7 41.7 88.7 45.8 89.6 51.4 88.9 62.5 87.6 65.3 84.7 67.1 79.2 61.1 70.8 59.5 54.2 61.0 51.4 62.5 50.5 68.1 56.6 84.7ZM58.6 56.9 61.1 54.2 61.1 45.8 63.9 40.3 62.5 38.9 56.9 38.7 45.8 30.6 34.7 31.0 30.6 37.5 30.6 45.8 33.9 51.4 40.3 55.6 56.9 57.9ZM45.8 43.5 40.3 44.2 39.1 43.1 38.9 40.3 43.1 36.2 47.2 40.3Z"
}

/// Shopify's bag: lit front with handle loops and the "S" cut out, darker side face, softly shaded "S".
private struct ConnShopifyBag: View {
    var body: some View {
        GeometryReader { g in
            let u = g.size.width / 24
            ZStack {
                // Front face with the handle loops cut out; the side face and the seam between them.
                ConnGlyph(d: ConnBrandPaths.shopify, parts: [2, 3, 4, 5])
                    .fill(LinearGradient(stops: [.init(color: Color(hex: "#9AD626"), location: 0), .init(color: Color(hex: "#7DB42B"), location: 0.5),
                                                 .init(color: Color(hex: "#66953C"), location: 1)], startPoint: .top, endPoint: .bottom),
                          style: FillStyle(eoFill: true))
                ConnGlyph(d: ConnBrandPaths.shopify, parts: [0])
                    .fill(LinearGradient(colors: [Color(hex: "#78AA1C"), Color(hex: "#436B1C")], startPoint: .top, endPoint: .bottom))
                ConnGlyph(d: "M14.95 24 15.9 2.8 16.3 2.88 15.4 24Z")
                    .fill(LinearGradient(colors: [Color(hex: "#86BC22"), Color(hex: "#557F2C")], startPoint: .top, endPoint: .bottom))
                // The "S" sits a little higher and further right in the app icon than in the flat logo.
                ConnGlyph(d: ConnBrandPaths.shopify, parts: [1])
                    .fill(LinearGradient(stops: [.init(color: .white, location: 0.35), .init(color: Color(hex: "#DAE7CA"), location: 0.85)],
                                         startPoint: .top, endPoint: .bottom))
                    .scaleEffect(1.06)
                    .offset(x: u * 0.75, y: -u * 1.1)
            }
        }
    }
}

/// Dub's "d": a disc with a round counter and a slot down to the counter's foot that frees the stem.
private struct ConnDubShape: Shape {
    func path(in r: CGRect) -> Path {
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + r.width * x, y: r.minY + r.height * y) }
        var p = Path(ellipseIn: r)
        let radius: CGFloat = 0.247, slotLeft: CGFloat = 0.625, slotRight: CGFloat = 0.75, slotBottom: CGFloat = 0.75
        // Counter ∪ slot as one outline: down the slot's left edge, the long way round the counter, back up the slot.
        let half = asin((slotLeft - 0.5) / radius)  // angle of the slot edge from 12 o'clock
        p.move(to: pt(slotLeft, -0.01))
        let steps = 72
        for i in 0...steps {
            let a = -.pi / 2 + half - CGFloat(i) / CGFloat(steps) * (2 * .pi - 2 * (.pi / 2 - half))
            p.addLine(to: pt(0.5 + radius * cos(a), 0.5 + radius * sin(a)))
        }
        p.addLine(to: pt(slotLeft, slotBottom))
        p.addLine(to: pt(slotRight, slotBottom))
        p.addLine(to: pt(slotRight, -0.01))
        p.closeSubpath()
        return p
    }
}

/// Plausible's rounded "P" block.
private struct ConnPlausibleP: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.addRoundedRect(in: CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height * 0.7),
                         cornerSize: CGSize(width: r.width * 0.34, height: r.width * 0.34), style: .continuous)
        p.addRoundedRect(in: CGRect(x: r.minX, y: r.minY + r.height * 0.3, width: r.width * 0.46, height: r.height * 0.7),
                         cornerSize: CGSize(width: r.width * 0.2, height: r.width * 0.2), style: .continuous)
        return p
    }
}

/// The white trend line across the Plausible "P".
private struct ConnPlausibleSpark: Shape {
    func path(in r: CGRect) -> Path {
        let pts: [(CGFloat, CGFloat)] = [(0, 0.538), (0.103, 0.474), (0.172, 0.449), (0.224, 0.481), (0.328, 0.481), (0.407, 0.397),
                                         (0.552, 0.263), (0.638, 0.301), (0.707, 0.308), (0.914, 0.212)]
        return Path.polyline(pts.map { CGPoint(x: r.minX + r.width * $0.0, y: r.minY + r.height * $0.1) })
    }
}

// MARK: - Range pill

/// Small dark chip ("7D", "TDY") overlapping the corner of a large brand icon.
struct ConnRangePill: View {
    @Environment(\.metrics) private var m
    var text: String

    var body: some View {
        Text(verbatim: text)
            .font(.dock(m.u(7), .bold))
            .foregroundStyle(Color.white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, m.u(3.25))
            .frame(minWidth: m.u(12.5), minHeight: m.u(12.5))
            .background(Capsule().fill(Color.black.opacity(0.72)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.17), lineWidth: m.u(1)))
    }
}

/// Large 44 pt brand icon with an optional range pill at its bottom-leading corner.
struct ConnBigMark: View {
    @Environment(\.metrics) private var m
    @Environment(\.layoutDirection) private var direction
    var brand: ConnBrand
    var icon: Bool
    var pill: String?

    var body: some View {
        ConnBrandMark(brand: brand, size: 44, icon: icon)
            .overlay(alignment: .bottomLeading) {
                if let pill {
                    // Hangs 2.25 pt outside the icon's corner.
                    ConnRangePill(text: pill)
                        .offset(x: m.u(direction == .rightToLeft ? 2.25 : -2.25), y: m.u(2.25))
                }
            }
    }
}

// MARK: - SVG path data

/// Brand glyph from SVG path data (M L H V C S Q T A Z, absolute and relative), scaled from `viewBox`
/// into the shape's rect. Glyph outlines come from Simple Icons (CC0).
struct ConnGlyph: Shape {
    var d: String
    var viewBox = CGRect(x: 0, y: 0, width: 24, height: 24)
    /// Keeps only these subpaths (in drawing order) when set, e.g. one face of a multi-part logo.
    var parts: [Int]?

    func path(in r: CGRect) -> Path {
        let subpaths = ConnSVG.subpaths(d)
        var base = Path()
        for (i, sub) in subpaths.enumerated() where parts?.contains(i) ?? true { base.addPath(sub) }
        let sx = r.width / viewBox.width, sy = r.height / viewBox.height
        return base.applying(CGAffineTransform(a: sx, b: 0, c: 0, d: sy, tx: r.minX - viewBox.minX * sx, ty: r.minY - viewBox.minY * sy))
    }
}

enum ConnSVG {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: [Path]] = [:]

    /// Parsed subpaths (split at each moveto), cached per path string.
    static func subpaths(_ d: String) -> [Path] {
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[d] { return hit }
        let parsed = parse(d)
        cache[d] = parsed
        return parsed
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private static func parse(_ d: String) -> [Path] {
        var out: [Path] = []
        var path = Path()
        var scanner = ConnSVGScanner(Array(d.utf8))
        var cur = CGPoint.zero, start = CGPoint.zero
        var lastCtrl: CGPoint?, lastQuad: CGPoint?
        var cmd: UInt8 = 0
        func flush() {
            if !path.isEmpty { out.append(path) }
            path = Path()
        }
        while let c = scanner.command(after: cmd) {
            cmd = c
            let rel = c >= 97
            let base = rel ? cur : .zero
            func pt() -> CGPoint? {
                guard let x = scanner.number(), let y = scanner.number() else { return nil }
                return CGPoint(x: base.x + x, y: base.y + y)
            }
            var ctrl: CGPoint?, quad: CGPoint?
            switch c | 32 {
            case UInt8(ascii: "m"):
                guard let p = pt() else { return out }
                flush()
                path.move(to: p)
                cur = p; start = p
                cmd = rel ? UInt8(ascii: "l") : UInt8(ascii: "L")
            case UInt8(ascii: "l"):
                guard let p = pt() else { return out }
                path.addLine(to: p); cur = p
            case UInt8(ascii: "h"):
                guard let x = scanner.number() else { return out }
                cur = CGPoint(x: base.x + x, y: cur.y); path.addLine(to: cur)
            case UInt8(ascii: "v"):
                guard let y = scanner.number() else { return out }
                cur = CGPoint(x: cur.x, y: (rel ? cur.y : 0) + y); path.addLine(to: cur)
            case UInt8(ascii: "c"):
                guard let c1 = pt(), let c2 = pt(), let p = pt() else { return out }
                path.addCurve(to: p, control1: c1, control2: c2); cur = p; ctrl = c2
            case UInt8(ascii: "s"):
                guard let c2 = pt(), let p = pt() else { return out }
                let c1 = lastCtrl.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                path.addCurve(to: p, control1: c1, control2: c2); cur = p; ctrl = c2
            case UInt8(ascii: "q"):
                guard let q = pt(), let p = pt() else { return out }
                path.addQuadCurve(to: p, control: q); cur = p; quad = q
            case UInt8(ascii: "t"):
                guard let p = pt() else { return out }
                let q = lastQuad.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                path.addQuadCurve(to: p, control: q); cur = p; quad = q
            case UInt8(ascii: "a"):
                guard let rx = scanner.number(), let ry = scanner.number(), let rot = scanner.number(),
                      let large = scanner.flag(), let sweep = scanner.flag(), let p = pt() else { return out }
                arc(&path, from: cur, to: p, rx: rx, ry: ry, rotation: rot, large: large, sweep: sweep)
                cur = p
            case UInt8(ascii: "z"):
                path.closeSubpath(); cur = start
            default:
                return out
            }
            lastCtrl = ctrl
            lastQuad = quad
        }
        flush()
        return out
    }

    /// SVG elliptical arc (endpoint form) as cubic Béziers.
    private static func arc(_ path: inout Path, from p0: CGPoint, to p1: CGPoint, rx: CGFloat, ry: CGFloat, rotation: CGFloat,
                            large: Bool, sweep: Bool) {
        var rx = abs(rx), ry = abs(ry)
        guard rx > 0, ry > 0, p0 != p1 else { path.addLine(to: p1); return }
        let phi = rotation * .pi / 180, cp = cos(phi), sp = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cp * dx + sp * dy, y1 = -sp * dx + cp * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var k = sqrt(max(0, num / den))
        if large == sweep { k = -k }
        let cxp = k * rx * y1 / ry, cyp = -k * ry * x1 / rx
        let cx = cp * cxp - sp * cyp + (p0.x + p1.x) / 2, cy = sp * cxp + cp * cyp + (p0.y + p1.y) / 2
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let t1 = angle(1, 0, (x1 - cxp) / rx, (y1 - cyp) / ry)
        var dt = angle((x1 - cxp) / rx, (y1 - cyp) / ry, (-x1 - cxp) / rx, (-y1 - cyp) / ry)
        if !sweep && dt > 0 { dt -= 2 * .pi } else if sweep && dt < 0 { dt += 2 * .pi }
        let segments = max(1, Int(ceil(abs(dt) / (.pi / 2))))
        let step = dt / CGFloat(segments)
        let alpha = 4 / 3 * tan(step / 4)
        func point(_ t: CGFloat) -> CGPoint {
            CGPoint(x: cx + rx * cos(t) * cp - ry * sin(t) * sp, y: cy + rx * cos(t) * sp + ry * sin(t) * cp)
        }
        func deriv(_ t: CGFloat) -> CGPoint {
            CGPoint(x: -rx * sin(t) * cp - ry * cos(t) * sp, y: -rx * sin(t) * sp + ry * cos(t) * cp)
        }
        var t = t1
        for _ in 0..<segments {
            let a = point(t), b = point(t + step), da = deriv(t), db = deriv(t + step)
            path.addCurve(to: b, control1: CGPoint(x: a.x + alpha * da.x, y: a.y + alpha * da.y),
                          control2: CGPoint(x: b.x - alpha * db.x, y: b.y - alpha * db.y))
            t += step
        }
    }
}

/// Tokenizer for SVG path data (handles "-.5.5", exponents and packed arc flags).
private struct ConnSVGScanner {
    let s: [UInt8]
    var i = 0
    init(_ s: [UInt8]) { self.s = s }

    private mutating func skip() {
        while i < s.count, s[i] == 32 || s[i] == 44 || s[i] == 9 || s[i] == 10 || s[i] == 13 { i += 1 }
    }

    private static func isLetter(_ c: UInt8) -> Bool { (c | 32) >= 97 && (c | 32) <= 122 && (c | 32) != 101 }

    /// Next command letter, or the previous one repeated when more numbers follow.
    mutating func command(after previous: UInt8) -> UInt8? {
        skip()
        guard i < s.count else { return nil }
        if Self.isLetter(s[i]) {
            defer { i += 1 }
            return s[i]
        }
        return previous == 0 ? nil : previous
    }

    mutating func flag() -> Bool? {
        skip()
        guard i < s.count, s[i] == 48 || s[i] == 49 else { return nil }
        defer { i += 1 }
        return s[i] == 49
    }

    mutating func number() -> CGFloat? {
        skip()
        let begin = i
        if i < s.count, s[i] == 43 || s[i] == 45 { i += 1 }
        var dot = false
        while i < s.count {
            let c = s[i]
            if c >= 48 && c <= 57 {
                i += 1
            } else if c == 46 && !dot {
                dot = true; i += 1
            } else if (c == 101 || c == 69), i > begin {
                i += 1
                if i < s.count, s[i] == 43 || s[i] == 45 { i += 1 }
            } else {
                break
            }
        }
        guard i > begin, let v = Double(String(decoding: s[begin..<i], as: UTF8.self)) else { return nil }
        return CGFloat(v)
    }
}
