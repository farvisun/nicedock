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
                Circle().fill(Color.black)
                Circle().strokeBorder(Color.white.opacity(0.42), lineWidth: max(s * 0.055, 0.8))
                Group {
                    Circle().stroke(Color.white, lineWidth: s * 0.045).frame(width: s * 0.56, height: s * 0.56)
                    Ellipse().stroke(Color.white, lineWidth: s * 0.045).frame(width: s * 0.34, height: s * 0.56)
                    Ellipse().stroke(Color.white, lineWidth: s * 0.045).frame(width: s * 0.12, height: s * 0.56)
                }
            }
        case .stripe:
            ZStack {
                (icon ? AnyShape(squircle(s)) : AnyShape(Circle())).fill(Color(hex: "#635BFF"))
                Text(verbatim: "S").font(.system(size: s * 0.6, weight: .heavy, design: .rounded)).foregroundStyle(Color.white)
            }
        case .dodo:
            ZStack {
                Circle().fill(Color(hex: "#C8F23A"))
                Image(systemName: "bird.fill").font(.system(size: s * 0.5, weight: .black)).foregroundStyle(Color.black)
                    .scaleEffect(x: -1, y: 1)
            }
        case .shopify:
            ZStack {
                if icon {
                    squircle(s).fill(LinearGradient(colors: [Color.white, Color(white: 0.9)], startPoint: .top, endPoint: .bottom))
                } else {
                    Circle().fill(Color.white)
                }
                ConnShopifyBag()
                    .frame(width: s * (icon ? 0.64 : 0.64), height: s * (icon ? 0.74 : 0.72))
                    .offset(y: -s * 0.01)
            }
        case .plausible:
            ZStack {
                Circle().fill(LinearGradient(colors: [Color.white, Color(hex: "#E4E4EC")], startPoint: .top, endPoint: .bottom))
                ConnPlausibleP()
                    .fill(LinearGradient(colors: [Color(hex: "#9A98FB"), Color(hex: "#5850EC"), Color(hex: "#3B32C8")], startPoint: .topTrailing, endPoint: .bottomLeading))
                    .frame(width: s * 0.54, height: s * 0.66)
                    .overlay(ConnPlausibleSpark().stroke(Color.white, style: StrokeStyle(lineWidth: max(s * 0.035, 0.7), lineCap: .round, lineJoin: .round)))
                    .offset(x: s * 0.01)
            }
        case .simpleAnalytics, .visitors:
            ZStack {
                Circle().fill(LinearGradient(colors: [Color.white, Color(hex: "#EDEDED")], startPoint: .top, endPoint: .bottom))
                HStack(alignment: .bottom, spacing: s * 0.06) {
                    RoundedRectangle(cornerRadius: s * 0.05, style: .continuous).fill(Color(hex: "#F3BCA9")).frame(width: s * 0.15, height: s * 0.36)
                    RoundedRectangle(cornerRadius: s * 0.05, style: .continuous).fill(Color(hex: "#E5603C")).frame(width: s * 0.15, height: s * 0.6)
                    RoundedRectangle(cornerRadius: s * 0.05, style: .continuous).fill(Color(hex: "#F3BCA9")).frame(width: s * 0.15, height: s * 0.36)
                }
                .offset(y: s * 0.02)
            }
        case .dataFast:
            BrandBadge(brand: .dataFast, size: size)
        case .dub:
            ZStack {
                Circle().fill(Color.white)
                Circle().fill(Color.black).frame(width: s * 0.5, height: s * 0.5).offset(x: -s * 0.04, y: s * 0.06)
                Rectangle().fill(Color.black).frame(width: s * 0.09, height: s * 0.62).offset(x: s * 0.165, y: -s * 0.19)
            }
            .clipShape(Circle())
        case .resend:
            ZStack {
                (icon ? AnyShape(squircle(s)) : AnyShape(Circle())).fill(Color(hex: "#050505"))
                (icon ? AnyShape(squircle(s)) : AnyShape(Circle())).stroke(Color.white.opacity(0.14), lineWidth: 1)
                Text(verbatim: "R")
                    .font(.system(size: s * 0.6, weight: .heavy, design: .default))
                    .foregroundStyle(LinearGradient(colors: [Color.white, Color(white: 0.55), Color(white: 0.8)], startPoint: .top, endPoint: .bottom))
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
                Circle().strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                Text(verbatim: "𝕏").font(.system(size: s * 0.7, weight: .regular)).foregroundStyle(Color.white)
            }
        case .tiktok:
            ZStack {
                Circle().fill(Color.white)
                ZStack {
                    Image(systemName: "music.note").foregroundStyle(Color(hex: "#25F4EE")).offset(x: -s * 0.025, y: -s * 0.02)
                    Image(systemName: "music.note").foregroundStyle(Color(hex: "#FE2C55")).offset(x: s * 0.025, y: s * 0.02)
                    Image(systemName: "music.note").foregroundStyle(Color.black)
                }
                .font(.system(size: s * 0.6, weight: .black))
            }
        case .youtube:
            ZStack {
                Circle().fill(Color(hex: "#F5212E"))
                RoundedRectangle(cornerRadius: s * 0.11, style: .continuous).fill(Color.white).frame(width: s * 0.56, height: s * 0.4)
                ConnPlayTriangle().fill(Color(hex: "#F5212E")).frame(width: s * 0.15, height: s * 0.17).offset(x: s * 0.015)
            }
        case .claude:
            ZStack {
                Circle().fill(Color(hex: "#DE7356"))
                ConnStarburst(rays: 12).stroke(Color.white, style: StrokeStyle(lineWidth: max(s * 0.065, 0.8), lineCap: .round))
                    .frame(width: s * 0.66, height: s * 0.66)
            }
        case .codex:
            BrandBadge(brand: .codex, size: size)
        case .openai:
            BrandBadge(brand: .openai, size: size)
        }
    }
}

/// Shopify's shopping bag: lit front face, darker side face, handle loop and a white "S".
private struct ConnShopifyBag: View {
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack(alignment: .topLeading) {
                ConnBagHandle()
                    .stroke(Color(hex: "#95BF47"), style: StrokeStyle(lineWidth: w * 0.075, lineCap: .round))
                ConnBagFace(side: false).fill(LinearGradient(colors: [Color(hex: "#9DC74C"), Color(hex: "#7AAE3A")], startPoint: .top, endPoint: .bottom))
                ConnBagFace(side: true).fill(Color(hex: "#5E8E3E"))
                Text(verbatim: "S")
                    .font(.system(size: h * 0.56, weight: .black, design: .rounded)).italic()
                    .foregroundStyle(Color.white)
                    .position(x: w * 0.4, y: h * 0.66)
            }
        }
    }
}

private struct ConnBagFace: Shape {
    var side: Bool
    func path(in r: CGRect) -> Path {
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + r.width * x, y: r.minY + r.height * y) }
        var p = Path()
        if side {
            p.addLines([pt(0.72, 0.25), pt(0.86, 0.23), pt(1.0, 0.95), pt(0.8, 1.0)])
        } else {
            p.addLines([pt(0.06, 0.32), pt(0.72, 0.25), pt(0.8, 1.0), pt(0.0, 0.93)])
        }
        p.closeSubpath()
        return p
    }
}

private struct ConnBagHandle: Shape {
    func path(in r: CGRect) -> Path {
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + r.width * x, y: r.minY + r.height * y) }
        var p = Path()
        p.move(to: pt(0.24, 0.34))
        p.addCurve(to: pt(0.62, 0.27), control1: pt(0.24, -0.06), control2: pt(0.6, -0.06))
        p.move(to: pt(0.4, 0.3))
        p.addCurve(to: pt(0.66, 0.08), control1: pt(0.42, 0.1), control2: pt(0.56, 0.02))
        return p
    }
}

/// Plausible's rounded "P" block.
private struct ConnPlausibleP: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.addRoundedRect(in: CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height * 0.7), cornerSize: CGSize(width: r.width * 0.34, height: r.width * 0.34), style: .continuous)
        p.addRoundedRect(in: CGRect(x: r.minX, y: r.minY + r.height * 0.3, width: r.width * 0.46, height: r.height * 0.7), cornerSize: CGSize(width: r.width * 0.2, height: r.width * 0.2), style: .continuous)
        return p
    }
}

/// The white trend line across the Plausible "P".
private struct ConnPlausibleSpark: Shape {
    func path(in r: CGRect) -> Path {
        Path.polyline([
            CGPoint(x: r.minX + r.width * 0.06, y: r.minY + r.height * 0.6),
            CGPoint(x: r.minX + r.width * 0.36, y: r.minY + r.height * 0.4),
            CGPoint(x: r.minX + r.width * 0.56, y: r.minY + r.height * 0.48),
            CGPoint(x: r.minX + r.width * 0.92, y: r.minY + r.height * 0.22)
        ])
    }
}

private struct ConnPlayTriangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// Claude's radiating starburst (alternating ray lengths).
private struct ConnStarburst: Shape {
    var rays: Int
    func path(in r: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: r.midX, y: r.midY)
        let outer = min(r.width, r.height) / 2
        for i in 0..<rays {
            let a = Double(i) / Double(rays) * 2 * .pi + 0.13
            let len = i % 2 == 0 ? outer : outer * 0.82
            let inner = outer * 0.2
            p.move(to: CGPoint(x: c.x + CGFloat(cos(a)) * inner, y: c.y + CGFloat(sin(a)) * inner))
            p.addLine(to: CGPoint(x: c.x + CGFloat(cos(a)) * len, y: c.y + CGFloat(sin(a)) * len))
        }
        return p
    }
}

// MARK: - Range pill

/// Small dark chip ("7D", "TDY") overlapping the corner of a large brand icon.
struct ConnRangePill: View {
    @Environment(\.metrics) private var m
    var text: String

    var body: some View {
        Text(verbatim: text)
            .font(.dock(m.u(8), .heavy))
            .foregroundStyle(Color.white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, m.u(3.5))
            .frame(height: m.u(9.5))
            .background(Capsule().fill(Color.black.opacity(0.82)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5))
    }
}

/// Large 44 pt brand icon with an optional range pill at its bottom-leading corner.
struct ConnBigMark: View {
    @Environment(\.metrics) private var m
    var brand: ConnBrand
    var icon: Bool
    var pill: String?

    var body: some View {
        ConnBrandMark(brand: brand, size: 44, icon: icon)
            .overlay(alignment: .bottomLeading) {
                if let pill {
                    ConnRangePill(text: pill)
                        .alignmentGuide(.leading) { $0[.leading] + m.u(2) }
                        .alignmentGuide(.bottom) { $0[.bottom] + m.u(1) }
                }
            }
    }
}
