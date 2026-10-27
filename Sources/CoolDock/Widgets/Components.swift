import AppKit
import SwiftUI

// MARK: - Tile chrome

/// Standard widget tile: fixed height, frosted fill and hairline border.
/// `width` is expressed at scale 1 (points at Dock Size = 100 %).
struct Tile<Content: View>: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    @Environment(\.displayScale) private var displayScale
    var width: CGFloat
    var padding: EdgeInsets? = nil
    var fill: AnyShapeStyle? = nil
    var alignment: Alignment = .center
    /// Corner radius in points at scale 1 (nil = the dock's tile radius) and curve style.
    var radius: CGFloat? = nil
    var cornerStyle: RoundedCornerStyle = .continuous
    @ViewBuilder var content: () -> Content

    var body: some View {
        // The hairline border sits just outside the layout frame (as in the reference frames), so tiles
        // read as the same size while their interiors line up pixel for pixel.
        let outset = m.tileOutset
        let r = radius.map { m.u($0) } ?? m.tileRadius
        let shape = RoundedRectangle(cornerRadius: r, style: cornerStyle)
        let outer = RoundedRectangle(cornerRadius: r + outset, style: cornerStyle)
        let lw = 1 / max(displayScale, 1)
        content()
            .padding(padding.map { EdgeInsets(top: m.u($0.top), leading: m.u($0.leading), bottom: m.u($0.bottom), trailing: m.u($0.trailing)) } ?? EdgeInsets())
            .frame(width: m.u(width), height: m.tileHeight, alignment: alignment)
            .clipShape(shape)
            .background {
                if p.drawTiles {
                    outer.fill(fill ?? AnyShapeStyle(p.tileFill))
                        .overlay(outer.strokeBorder(p.tileStroke, lineWidth: lw))
                        .padding(-outset)
                } else if let fill {
                    outer.fill(fill).padding(-outset)
                }
            }
            .contentShape(shape)
    }
}

/// Convenience padding tokens.
extension EdgeInsets {
    static func all(_ v: CGFloat) -> EdgeInsets { EdgeInsets(top: v, leading: v, bottom: v, trailing: v) }
    static func hv(_ h: CGFloat, _ v: CGFloat) -> EdgeInsets { EdgeInsets(top: v, leading: h, bottom: v, trailing: h) }
}

// MARK: - Text helpers

extension Text {
    /// Dock text with active font rules and digit localization applied by the caller.
    /// `design: .default` selects SF Pro instead of SF Pro Rounded (list titles in the reference frames).
    func dock(_ size: CGFloat, _ weight: Font.Weight = .semibold, _ color: Color? = nil, mono: Bool = false,
              design: Font.Design = .rounded) -> some View {
        modifier(DockTextStyle(size: size, weight: weight, color: color, mono: mono, design: design))
    }
}

struct DockTextStyle: ViewModifier {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    var size: CGFloat
    var weight: Font.Weight
    var color: Color?
    var mono: Bool
    var design: Font.Design = .rounded
    func body(content: Content) -> some View {
        content
            .font(.dock(m.u(size), weight, design: design, mono: mono))
            .foregroundStyle(color ?? p.primary)
            .lineLimit(1)
    }
}

/// Text with localized digits (Persian/Arabic numerals when enabled).
func T(_ s: String) -> Text { Text(verbatim: Fmt.digits(s)) }

// MARK: - Sub-pixel text placement

/// SwiftUI sizes a `Text` up to whole device pixels and draws the run from the frame's leading edge, so a
/// trailing-aligned label ends up to a device pixel short of the edge. Browsers (the cooldock.app frames) end the
/// run exactly there. `TextRun.slack` is that rounding: the frame width minus the run's advance, measured with the
/// same system font through Core Text.
@MainActor
enum TextRun {
    private static var cache: [String: CGFloat] = [:]

    static func slack(_ s: String, size: CGFloat, weight: Font.Weight, design: Font.Design, mono: Bool, scale: CGFloat) -> CGFloat {
        // Estedad (Persian/Arabic) runs keep SwiftUI's placement.
        guard !(Localizer.language.usesEstedad && AppStore.estedadEnabled), !s.isEmpty, scale > 0 else { return 0 }
        let key = "\(s)|\(size)|\(weight)|\(design)|\(mono)|\(scale)"
        if let hit = cache[key] { return hit }
        var font = NSFont.systemFont(ofSize: size, weight: nsWeight(weight))
        if design != .default, let d = font.fontDescriptor.withDesign(design == .rounded ? .rounded : design == .monospaced ? .monospaced : .serif) {
            font = NSFont(descriptor: d, size: size) ?? font
        }
        if mono {
            let d = font.fontDescriptor.addingAttributes([.featureSettings: [[
                NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector
            ]]])
            font = NSFont(descriptor: d, size: size) ?? font
        }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: font]))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let slack = max(0, (width * scale).rounded(.up) / scale - width)
        if cache.count > 512 { cache.removeAll() }
        cache[key] = slack
        return slack
    }

    private static func nsWeight(_ w: Font.Weight) -> NSFont.Weight {
        switch w {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        default: return .regular
        }
    }
}

extension View {
    /// Trailing-aligned `.dock` text: moves the run by its pixel rounding so it ends exactly on the trailing edge.
    /// `s` is the displayed string (after `Fmt.digits`); size/weight/design/mono as passed to `.dock`.
    func runTrailing(_ s: String, _ size: CGFloat, _ weight: Font.Weight = .semibold, design: Font.Design = .rounded,
                     mono: Bool = false) -> some View {
        modifier(TextRunShift(s: s, size: size, weight: weight, design: design, mono: mono))
    }
}

private struct TextRunShift: ViewModifier {
    @Environment(\.metrics) private var m
    @Environment(\.displayScale) private var scale
    @Environment(\.layoutDirection) private var direction
    var s: String
    var size: CGFloat
    var weight: Font.Weight
    var design: Font.Design
    var mono: Bool

    func body(content: Content) -> some View {
        // Left-to-right only: right-to-left rows keep SwiftUI's placement.
        let dx = direction == .leftToRight
            ? TextRun.slack(s, size: m.u(size), weight: weight, design: design, mono: mono, scale: scale) : 0
        if dx == 0 {
            content
        } else {
            // `transformEffect` keeps the fractional offset (`.offset` snaps to whole device pixels).
            content.transformEffect(CGAffineTransform(translationX: dx, y: 0))
        }
    }
}

// MARK: - Ring gauge

struct RingGauge<Center: View>: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    var value: Double
    var color: Color
    var lineWidth: CGFloat = 7
    var diameter: CGFloat = 50
    var gradient = false
    @ViewBuilder var center: () -> Center

    var body: some View {
        let clamped = max(0, min(1, value))
        let accent = p.accent(color)
        ZStack {
            Circle().stroke(p.track, lineWidth: m.u(lineWidth))
            Circle()
                .trim(from: 0, to: clamped)
                .stroke(gradient ? AnyShapeStyle(AngularGradient(colors: [accent.opacity(0.55), accent], center: .center, startAngle: .degrees(0), endAngle: .degrees(360 * clamped))) : AnyShapeStyle(accent),
                        style: StrokeStyle(lineWidth: m.u(lineWidth), lineCap: .round))
                .rotationEffect(.degrees(-90))
            center()
        }
        .frame(width: m.u(diameter), height: m.u(diameter))
        // Rings always fill clockwise from 12 o'clock, also in right-to-left languages.
        .environment(\.layoutDirection, .leftToRight)
    }
}

/// Ring tile used by battery, CPU, memory, storage, temperature, voice memo.
struct RingTile: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    var value: Double
    var color: Color
    var symbol: String
    var label: String
    var width: CGFloat = 70

    var body: some View {
        Tile(width: width) {
            RingGauge(value: value, color: color, lineWidth: 6.5, diameter: 48) {
                VStack(spacing: 0) {
                    Image(systemName: symbol)
                        .font(.system(size: m.u(11), weight: .semibold))
                        .foregroundStyle(p.accent(color))
                    T(label).dock(13.5, .bold, mono: true)
                }
            }
        }
    }
}

// MARK: - Charts

/// Smoothed line with gradient area fill. Values are normalised to the drawing rect.
struct AreaSparkline: View {
    @Environment(\.palette) private var p
    var values: [Double]
    var color: Color
    var lineWidth: CGFloat = 2
    var fillOpacity: Double = 0.35
    var minValue: Double? = nil
    var maxValue: Double? = nil
    var smooth = true

    var body: some View {
        Canvas { ctx, size in
            guard values.count > 1 else { return }
            let lo = minValue ?? (values.min() ?? 0)
            let hi = maxValue ?? (values.max() ?? 1)
            let span = max(hi - lo, 0.000_001)
            let step = size.width / CGFloat(values.count - 1)
            let inset = lineWidth
            let pts = values.enumerated().map { i, v in
                CGPoint(x: CGFloat(i) * step, y: inset + (size.height - inset * 2) * (1 - CGFloat((v - lo) / span)))
            }
            let line = smooth ? Path.smooth(pts) : Path.polyline(pts)
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            let accent = p.accent(color)
            ctx.fill(area, with: .linearGradient(Gradient(colors: [accent.opacity(fillOpacity), accent.opacity(0)]),
                                                 startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            ctx.stroke(line, with: .color(accent), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
    }
}

extension Path {
    static func polyline(_ pts: [CGPoint]) -> Path {
        var path = Path()
        guard let first = pts.first else { return path }
        path.move(to: first)
        pts.dropFirst().forEach { path.addLine(to: $0) }
        return path
    }

    /// Catmull-Rom → cubic Bézier smoothing.
    static func smooth(_ pts: [CGPoint]) -> Path {
        var path = Path()
        guard pts.count > 2 else { return polyline(pts) }
        path.move(to: pts[0])
        for i in 0..<(pts.count - 1) {
            let p0 = i > 0 ? pts[i - 1] : pts[i]
            let p1 = pts[i], p2 = pts[i + 1]
            let p3 = i + 2 < pts.count ? pts[i + 2] : p2
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }
}

// MARK: - Dot grid (progress widgets)

struct DotGrid: View {
    @Environment(\.palette) private var p
    var total: Int
    var filled: Int
    var columns: Int
    var color: Color? = nil
    var dimOpacity: Double = 0.18

    var body: some View {
        Canvas { ctx, size in
            let rows = Int(ceil(Double(total) / Double(columns)))
            let cell = min(size.width / CGFloat(columns), size.height / CGFloat(max(rows, 1)))
            let d = cell * 0.78
            let xOff = (size.width - cell * CGFloat(columns)) / 2
            let yOff = (size.height - cell * CGFloat(rows)) / 2
            let on = color.map { p.accent($0) } ?? p.primary
            for i in 0..<total {
                let r = i / columns, c = i % columns
                let rect = CGRect(x: xOff + CGFloat(c) * cell + (cell - d) / 2, y: yOff + CGFloat(r) * cell + (cell - d) / 2, width: d, height: d)
                ctx.fill(Path(ellipseIn: rect), with: .color(i < filled ? on : p.primary.opacity(dimOpacity)))
            }
        }
    }
}

// MARK: - Buttons

struct CircleButton: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    var symbol: String
    var size: CGFloat = 30
    var fill: Color? = nil
    var foreground: Color? = nil
    var iconScale: CGFloat = 0.42
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: m.u(size * iconScale), weight: .bold))
                .foregroundStyle(foreground ?? p.primary)
                .frame(width: m.u(size), height: m.u(size))
                .background(Circle().fill(fill ?? p.control))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Square-ish icon button used inside tiles (screenshots, audio outputs).
struct TileIconButton: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    var symbol: String
    var label: String? = nil
    var tint: Color? = nil
    var selected = false
    var size = CGSize(width: 46, height: 46)
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: m.u(3)) {
                Image(systemName: symbol)
                    .font(.system(size: m.u(label == nil ? 18 : 15), weight: .semibold))
                    .foregroundStyle(tint.map { p.accent($0) } ?? p.secondary)
                if let label { Text(label).dock(8.5, .semibold, p.secondary) }
            }
            .frame(width: m.u(size.width), height: m.u(size.height))
            .background(RoundedRectangle(cornerRadius: m.u(9), style: .continuous).fill(selected ? p.controlStrong : p.control))
            .overlay(RoundedRectangle(cornerRadius: m.u(9), style: .continuous).strokeBorder(p.tileStroke, lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }
}

// MARK: - App icons

/// The site's Notes, Mail and Calendar icons are bitmaps the browser resamples: their squircle has rounder corners
/// than the system mask (26 % of the side), its edge sits a fraction of a device pixel inside the icon box and
/// every edge is slightly soft. Drawn icons use this shape and `appIconSoftness` to read the same.
enum AppIconFinish {
    /// The icon's squircle in a canvas of `size`.
    static func shape(_ size: CGSize) -> Path {
        let inset = size.width * 0.1 / 36
        let r = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
        return Path(roundedRect: r, cornerRadius: size.width * 0.26 - inset, style: .continuous)
    }
}

extension View {
    /// Hands a tile's click (an `onTapGesture` or gesture) to Accessibility as its press action. A gesture alone is
    /// invisible there: VoiceOver, Voice Control, Switch Control and UI scripting find no button and no AXPress.
    /// `combine` reads the tile's text as one button; `contain` keeps controls inside the tile (rows, rings) reachable.
    func accessibilityPress(combine: Bool = true, _ action: @escaping () -> Void) -> some View {
        accessibilityElement(children: combine ? .combine : .contain)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, action)
    }

    /// Resampling softness of the site's app icon bitmaps (a quarter point at 36 pt).
    func appIconSoftness(_ side: CGFloat) -> some View {
        blur(radius: side * 0.25 / 36)
    }
}

/// Thread-safe, size-bucketed NSWorkspace icon cache. Icons are rendered once at the needed pixel size.
enum IconCache {
    nonisolated(unsafe) private static var cache = NSCache<NSString, NSImage>()

    static func icon(path: String, size: CGFloat) -> NSImage {
        let px = Int(size * 2)
        let key = "\(path)#\(px)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let src = NSWorkspace.shared.icon(forFile: (path as NSString).expandingTildeInPath)
        let img = NSImage(size: NSSize(width: size, height: size))
        img.addRepresentation(src.bestRepresentation(for: NSRect(x: 0, y: 0, width: px, height: px), context: nil, hints: nil) ?? src.representations.first ?? NSBitmapImageRep())
        cache.setObject(img, forKey: key)
        return img
    }

    static func symbolIcon(_ type: String, size: CGFloat) -> NSImage {
        let key = "type:\(type)#\(Int(size))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let img = NSWorkspace.shared.icon(for: .init(filenameExtension: type) ?? .data)
        img.size = NSSize(width: size, height: size)
        cache.setObject(img, forKey: key)
        return img
    }

    static func purge() { cache.removeAllObjects() }
}

struct AppIcon: View {
    @Environment(\.metrics) private var m
    @Environment(\.colorScheme) private var scheme
    var path: String
    var size: CGFloat

    var body: some View {
        let style = AppStore.shared.settings.iconStyle
        let dark = style == .dark || (style == .auto && NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        Image(nsImage: IconCache.icon(path: path, size: m.u(size)))
            .resizable()
            .interpolation(.high)
            .frame(width: m.u(size), height: m.u(size))
            .saturation(style == .monochrome ? 0 : (dark ? 0.75 : 1))
            .brightness(dark ? -0.18 : 0)
    }
}

// MARK: - Empty / setup states

/// Compact in-tile message for unconfigured widgets, missing permissions or errors.
struct TileMessage: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    var symbol: String
    var text: String
    var tint: Color = .cdOrange

    var body: some View {
        HStack(spacing: m.u(6)) {
            Image(systemName: symbol).foregroundStyle(p.accent(tint)).font(.system(size: m.u(13), weight: .semibold))
            Text(text).font(.dock(m.u(10.5), .semibold)).foregroundStyle(p.secondary).lineLimit(2).multilineTextAlignment(.leading)
        }
        .padding(.horizontal, m.u(10))
    }
}

// MARK: - Brand marks (drawn, not bundled artwork)

struct BrandBadge: View {
    @Environment(\.metrics) private var m
    enum Brand { case x, tiktok, youtube, shopify, polar, plausible, simpleAnalytics, dataFast, dodo, dub, resend, github, linear, stripe, supabase, claude, openai, codex }
    var brand: Brand
    var size: CGFloat = 22

    var body: some View {
        let s = m.u(size)
        ZStack {
            switch brand {
            case .x:
                Circle().fill(Color.black)
                Text(verbatim: "𝕏").font(.system(size: s * 0.56, weight: .bold)).foregroundStyle(.white)
            case .tiktok:
                Circle().fill(Color.white)
                ZStack {
                    Image(systemName: "music.note").foregroundStyle(Color(hex: "#25F4EE")).offset(x: -s * 0.03, y: -s * 0.03)
                    Image(systemName: "music.note").foregroundStyle(Color(hex: "#FE2C55")).offset(x: s * 0.03, y: s * 0.03)
                    Image(systemName: "music.note").foregroundStyle(.black)
                }.font(.system(size: s * 0.5, weight: .black))
            case .youtube:
                Circle().fill(Color(hex: "#FF0000"))
                RoundedRectangle(cornerRadius: s * 0.1, style: .continuous).fill(.white).frame(width: s * 0.5, height: s * 0.36)
                Image(systemName: "play.fill").font(.system(size: s * 0.2)).foregroundStyle(Color(hex: "#FF0000"))
            case .shopify:
                RoundedRectangle(cornerRadius: s * 0.24, style: .continuous).fill(.white)
                Image(systemName: "bag.fill").font(.system(size: s * 0.58)).foregroundStyle(Color(hex: "#95BF47"))
                Text(verbatim: "S").font(.system(size: s * 0.3, weight: .heavy, design: .rounded)).foregroundStyle(.white).offset(y: s * 0.06)
            case .polar:
                Circle().fill(.white)
                Circle().strokeBorder(.black, lineWidth: s * 0.07).padding(s * 0.12)
                Ellipse().strokeBorder(.black, lineWidth: s * 0.06).frame(width: s * 0.36, height: s * 0.7)
                Rectangle().fill(.black).frame(width: s * 0.06, height: s * 0.7)
            case .plausible:
                Circle().fill(Color(hex: "#5850EC"))
                Text(verbatim: "P").font(.system(size: s * 0.55, weight: .heavy, design: .rounded)).foregroundStyle(.white)
            case .simpleAnalytics, .dataFast:
                Circle().fill(.white)
                HStack(alignment: .bottom, spacing: s * 0.07) {
                    Capsule().frame(width: s * 0.13, height: s * 0.42)
                    Capsule().frame(width: s * 0.13, height: s * 0.58)
                    Capsule().frame(width: s * 0.13, height: s * 0.32)
                }.foregroundStyle(brand == .dataFast ? Color(hex: "#E8642C") : Color(hex: "#F06A47"))
            case .dodo:
                Circle().fill(Color(hex: "#C5F23C"))
                Image(systemName: "bird.fill").font(.system(size: s * 0.5)).foregroundStyle(.black)
            case .dub:
                Circle().fill(.white)
                Text(verbatim: "d").font(.system(size: s * 0.72, weight: .black, design: .rounded)).foregroundStyle(.black).offset(y: -s * 0.04)
            case .resend:
                RoundedRectangle(cornerRadius: s * 0.24, style: .continuous).fill(.black)
                Text(verbatim: "R").font(.system(size: s * 0.6, weight: .black)).foregroundStyle(.white).italic()
            case .github:
                Circle().fill(.white)
                Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: s * 0.38, weight: .bold)).foregroundStyle(.black)
            case .linear:
                Circle().fill(Color(hex: "#5E6AD2"))
                Image(systemName: "line.3.diagonal").font(.system(size: s * 0.45, weight: .bold)).foregroundStyle(.white)
            case .stripe:
                RoundedRectangle(cornerRadius: s * 0.24, style: .continuous).fill(Color(hex: "#635BFF"))
                Text(verbatim: "S").font(.system(size: s * 0.6, weight: .heavy, design: .rounded)).foregroundStyle(.white)
            case .supabase:
                Circle().fill(Color(hex: "#1C1C1C"))
                Image(systemName: "bolt.fill").font(.system(size: s * 0.52)).foregroundStyle(Color(hex: "#3ECF8E"))
            case .claude:
                Circle().fill(Color(hex: "#D97757"))
                Image(systemName: "asterisk").font(.system(size: s * 0.56, weight: .heavy)).foregroundStyle(.white)
            case .openai, .codex:
                Circle().fill(.white)
                Image(systemName: "hexagon").font(.system(size: s * 0.5, weight: .bold)).foregroundStyle(.black)
            }
        }
        .frame(width: s, height: s)
        .compositingGroup()
    }
}

// MARK: - Misc

extension View {
    @ViewBuilder func `if`<V: View>(_ condition: Bool, transform: (Self) -> V) -> some View {
        if condition { transform(self) } else { self }
    }

    /// Flip horizontally in RTL for directional glyphs (arrows, play/next).
    func flipsForRTL() -> some View { modifier(FlipForRTL()) }
}

private struct FlipForRTL: ViewModifier {
    @Environment(\.layoutDirection) private var dir
    func body(content: Content) -> some View { content.scaleEffect(x: dir == .rightToLeft ? -1 : 1, y: 1) }
}

/// Opens URLs, apps and files.
enum Open {
    /// Receives the URL instead of opening it (tests: System Settings panes, apps and pages never open).
    nonisolated(unsafe) static var interceptor: ((URL) -> Void)?

    static func url(_ s: String) {
        guard let u = URL(string: s) else { return }
        if let interceptor { interceptor(u); return }
        NSWorkspace.shared.open(u)
    }
    static func path(_ p: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: (p as NSString).expandingTildeInPath))
    }
    static func app(_ path: String) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg)
    }
    static func bundle(_ id: String) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { app(url.path) }
    }
    static func reveal(_ p: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: (p as NSString).expandingTildeInPath)])
    }
}
