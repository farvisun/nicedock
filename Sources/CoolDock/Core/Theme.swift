import AppKit
import SwiftUI

// MARK: - Fonts

enum DockFonts {
    /// Registers bundled fonts (Estedad) for this process only.
    static func registerBundledFonts() {
        let fm = FileManager.default
        var urls: [URL] = []
        if let dir = Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
           let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            urls += items
        }
        let dev = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Resources/Fonts")
        if urls.isEmpty, let items = try? fm.contentsOfDirectory(at: dev, includingPropertiesForKeys: nil) {
            urls += items
        }
        for url in urls where ["ttf", "otf"].contains(url.pathExtension.lowercased()) {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    static func estedadName(_ weight: Font.Weight) -> String {
        switch weight {
        case .ultraLight, .thin: return "Estedad-ExtraLight"
        case .light: return "Estedad-Light"
        case .regular: return "Estedad-Regular"
        case .medium: return "Estedad-Medium"
        case .semibold: return "Estedad-SemiBold"
        case .bold: return "Estedad-Bold"
        case .heavy, .black: return "Estedad-ExtraBold"
        default: return "Estedad-Regular"
        }
    }

    static func estedadNSFont(_ size: CGFloat, weight: Font.Weight = .regular) -> NSFont {
        NSFont(name: estedadName(weight), size: size) ?? .systemFont(ofSize: size)
    }
}

extension Font {
    /// The CoolDock widget typeface. Uses SF Pro Rounded for Latin scripts and Estedad for Persian/Arabic.
    static func dock(_ size: CGFloat, _ weight: Font.Weight = .semibold, design: Font.Design = .rounded, mono: Bool = false) -> Font {
        if Localizer.language.usesEstedad && AppStore.estedadEnabled {
            // Estedad has taller Arabic-script ascenders; trim slightly to sit on the same baseline grid.
            return .custom(DockFonts.estedadName(weight), fixedSize: size * 0.94)
        }
        let f = Font.system(size: size, weight: weight, design: design)
        return mono ? f.monospacedDigit() : f
    }

    /// Text style for chrome (settings, browser) — still swaps to Estedad for Persian.
    static func ui(_ size: CGFloat = 13, _ weight: Font.Weight = .regular) -> Font {
        if Localizer.language.usesEstedad && AppStore.estedadEnabled {
            return .custom(DockFonts.estedadName(weight), fixedSize: size * 0.96)
        }
        return .system(size: size, weight: weight)
    }
}

// MARK: - Accent colors (Apple system palette, dark variants as used on the dock)

extension Color {
    static let cdGreen = Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255)
    static let cdBlue = Color(red: 10 / 255, green: 132 / 255, blue: 255 / 255)
    static let cdOrange = Color(red: 255 / 255, green: 159 / 255, blue: 10 / 255)
    static let cdRed = Color(red: 255 / 255, green: 69 / 255, blue: 58 / 255)
    static let cdPink = Color(red: 255 / 255, green: 55 / 255, blue: 95 / 255)
    static let cdPurple = Color(red: 191 / 255, green: 90 / 255, blue: 242 / 255)
    static let cdIndigo = Color(red: 94 / 255, green: 92 / 255, blue: 230 / 255)
    static let cdCyan = Color(red: 100 / 255, green: 210 / 255, blue: 255 / 255)
    static let cdTeal = Color(red: 64 / 255, green: 200 / 255, blue: 224 / 255)
    static let cdMint = Color(red: 99 / 255, green: 230 / 255, blue: 226 / 255)
    static let cdYellow = Color(red: 255 / 255, green: 214 / 255, blue: 10 / 255)
    static let cdBrown = Color(red: 172 / 255, green: 142 / 255, blue: 104 / 255)
    static let cdGray = Color(red: 142 / 255, green: 142 / 255, blue: 147 / 255)

    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r, g, b, a: Double
        if s.count == 8 {
            r = Double((v >> 24) & 0xFF) / 255; g = Double((v >> 16) & 0xFF) / 255
            b = Double((v >> 8) & 0xFF) / 255; a = Double(v & 0xFF) / 255
        } else {
            r = Double((v >> 16) & 0xFF) / 255; g = Double((v >> 8) & 0xFF) / 255
            b = Double(v & 0xFF) / 255; a = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return String(format: "#%02X%02X%02X", Int(ns.redComponent * 255), Int(ns.greenComponent * 255), Int(ns.blueComponent * 255))
    }
}

// MARK: - Dock styles

enum DockStyle: String, Codable, CaseIterable, Identifiable {
    case lightGlass, liquidGlass, darkGlass, white, black, transparent
    var id: String { rawValue }
    var title: String {
        switch self {
        case .lightGlass: return L("Light Glass")
        case .liquidGlass: return L("Liquid Glass")
        case .darkGlass: return L("Dark Glass")
        case .white: return L("White")
        case .black: return L("Black")
        case .transparent: return L("Transparent")
        }
    }
    static var available: [DockStyle] {
        if #available(macOS 26, *) { return allCases }
        return allCases.filter { $0 != .liquidGlass }
    }
}

enum WidgetSurface: String, Codable, CaseIterable, Identifiable {
    case glass, darkGlass, white, black
    var id: String { rawValue }
    var title: String {
        switch self {
        case .glass: return L("Glass")
        case .darkGlass: return L("Dark Glass")
        case .white: return L("White")
        case .black: return L("Black")
        }
    }
}

/// Semantic colors for everything drawn on the dock. Widgets never hardcode white/black.
struct DockPalette {
    var primary: Color
    var secondary: Color
    var tertiary: Color
    var tileFill: Color
    var tileStroke: Color
    var control: Color
    var controlStrong: Color
    var track: Color
    var plate: Color
    var plateStroke: Color
    var isLight: Bool
    var monochrome: Bool
    var drawTiles: Bool

    func accent(_ c: Color) -> Color { monochrome ? primary : c }
    func accentSoft(_ c: Color) -> Color { monochrome ? control : c.opacity(0.22) }

    static func make(style: DockStyle, surface: WidgetSurface, monochrome: Bool, tiles: Bool, reduceTransparency: Bool) -> DockPalette {
        let lightContent: Bool
        switch style {
        case .white: lightContent = true
        case .transparent: lightContent = surface == .white
        default: lightContent = false
        }
        let fg: Color = lightContent ? Color(white: 0.06) : .white
        var p = DockPalette(
            primary: fg,
            secondary: fg.opacity(0.6),
            tertiary: fg.opacity(0.36),
            tileFill: fg.opacity(lightContent ? 0.05 : 0.10),
            tileStroke: fg.opacity(lightContent ? 0.08 : 0.10),
            control: fg.opacity(lightContent ? 0.07 : 0.10),
            controlStrong: fg.opacity(lightContent ? 0.12 : 0.18),
            track: fg.opacity(lightContent ? 0.08 : 0.10),
            plate: .black.opacity(0.9),
            plateStroke: .white.opacity(0.10),
            isLight: lightContent,
            monochrome: monochrome,
            drawTiles: tiles || style == .transparent
        )
        switch style {
        case .lightGlass:
            p.plate = reduceTransparency ? Color(white: 0.16) : Color.black.opacity(0.32)
            p.plateStroke = .white.opacity(0.16)
        case .liquidGlass:
            p.plate = .clear
            p.tileFill = .white.opacity(0.14)
            p.tileStroke = .white.opacity(0.18)
        case .darkGlass:
            p.plate = reduceTransparency ? Color(white: 0.06) : Color.black.opacity(0.9)
        case .white:
            p.plate = Color(white: 0.97)
            p.plateStroke = .black.opacity(0.08)
        case .black:
            p.plate = .black
            p.plateStroke = .white.opacity(0.08)
        case .transparent:
            p.plate = .clear
            p.plateStroke = .clear
            switch surface {
            case .glass: p.tileFill = reduceTransparency ? Color(white: 0.18) : .black.opacity(0.35)
            case .darkGlass: p.tileFill = reduceTransparency ? Color(white: 0.08) : .black.opacity(0.85)
            case .white: p.tileFill = Color(white: 0.97)
            case .black: p.tileFill = .black
            }
        }
        return p
    }
}

/// Size tokens. Every widget dimension is expressed at scale 1 and multiplied through `u`.
struct DockMetrics {
    var scale: CGFloat = 1
    var spacing: CGFloat = 6
    var cornerRadius: CGFloat = 12

    static let baseTileHeight: CGFloat = 62
    static let basePadding: CGFloat = 8

    @inline(__always) func u(_ v: CGFloat) -> CGFloat { v * scale }
    var tileHeight: CGFloat { Self.baseTileHeight * scale }
    var padding: CGFloat { Self.basePadding * scale }
    var gap: CGFloat { spacing * scale }
    var tileRadius: CGFloat { cornerRadius * scale }
    var plateRadius: CGFloat { (cornerRadius + Self.basePadding) * scale }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = DockPalette.make(style: .darkGlass, surface: .glass, monochrome: false, tiles: true, reduceTransparency: false)
}
private struct MetricsKey: EnvironmentKey { static let defaultValue = DockMetrics() }

extension EnvironmentValues {
    var palette: DockPalette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
    var metrics: DockMetrics {
        get { self[MetricsKey.self] }
        set { self[MetricsKey.self] = newValue }
    }
}

// MARK: - Visual effect bridge

struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    var appearance: NSAppearance.Name? = .darkAqua

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        v.isEmphasized = false
        if let appearance { v.appearance = NSAppearance(named: appearance) }
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
        if let appearance { v.appearance = NSAppearance(named: appearance) }
    }
}
