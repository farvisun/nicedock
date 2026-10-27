import CoreGraphics
import Foundation
import ImageIO

// MARK: - Parameters

enum WallpaperMood: String, CaseIterable {
    case calm, serene, happy, energetic, cozy, dreamy, romantic, mysterious, dramatic, melancholy, focused, playful
}

enum WallpaperStyle: String, CaseIterable {
    case gradient, mesh, blobs, aurora, bokeh, waves, dunes, mountains, minimal

    var isScenic: Bool { self == .waves || self == .dunes || self == .mountains || self == .minimal }
}

enum WallpaperTime: String, CaseIterable {
    case dawn, sunrise, morning, noon, afternoon, goldenHour = "golden_hour", sunset, dusk, evening, night, midnight
}

enum WallpaperSeason: String, CaseIterable {
    case spring, summer, autumn, winter
}

enum WallpaperWeather: String, CaseIterable {
    case clear, sunny, partlyCloudy = "partly_cloudy", cloudy, overcast, rain, storm, snow, fog, windy
}

/// Colour names accepted by `set_wallpaper` and by colour settings of widgets.
enum WallpaperColor {
    static let table: [(String, String)] = [
        ("red", "#E5383B"), ("crimson", "#B3122E"), ("coral", "#FF7F6B"), ("salmon", "#F4978E"), ("orange", "#F77F00"),
        ("amber", "#FFB000"), ("peach", "#FFBE98"), ("gold", "#E9B949"), ("yellow", "#FFD60A"), ("lime", "#A7D129"),
        ("green", "#2DAA4F"), ("emerald", "#0F9D73"), ("olive", "#7A8B3C"), ("mint", "#7FD8BE"), ("teal", "#139A9A"),
        ("turquoise", "#2EC4B6"), ("cyan", "#3BC9DB"), ("sky", "#5AB0F0"), ("blue", "#2F6FDE"), ("navy", "#14234B"),
        ("indigo", "#4B3FB5"), ("violet", "#7F4FD9"), ("purple", "#8E3FB8"), ("lavender", "#B9A6E8"), ("magenta", "#D63AAF"),
        ("pink", "#F48FB1"), ("rose", "#E0607E"), ("brown", "#7B4A2D"), ("beige", "#E6D5B8"), ("sand", "#D8B98A"),
        ("cream", "#F6EFD9"), ("white", "#F7F8FA"), ("silver", "#C3C9D1"), ("gray", "#8A9099"), ("grey", "#8A9099"),
        ("slate", "#55606E"), ("charcoal", "#2E3239"), ("black", "#0C0D10")
    ]
    static let aliases = ["skyblue": "sky", "lightblue": "sky", "babyblue": "sky", "darkblue": "navy", "royalblue": "blue", "aqua": "cyan",
                          "fuchsia": "magenta", "hotpink": "magenta", "lilac": "lavender", "forest": "emerald", "darkgreen": "emerald",
                          "maroon": "crimson", "burgundy": "crimson", "tan": "sand", "ivory": "cream", "offwhite": "cream", "darkgray": "charcoal",
                          "darkgrey": "charcoal", "lightgray": "silver", "lightgrey": "silver"]
    static var names: [String] { table.map(\.0) }

    /// Canonical "#RRGGBB" for a hex value (#RGB, #RRGGBB, with or without #) or a colour name.
    static func hex(_ input: String) -> String? {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let letters = raw.filter { $0.isLetter }
        let name = aliases[letters] ?? letters
        if let hit = table.first(where: { $0.0 == name }) { return hit.1 }
        var hex = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        guard hex.count == 3 || hex.count == 6, hex.allSatisfy(\.isHexDigit) else { return nil }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        return "#" + hex.uppercased()
    }
}

/// A validated `set_wallpaper` / `preview_wallpaper` request. Same request → same image.
struct WallpaperRequest: Equatable {
    var mood: WallpaperMood?
    var style: WallpaperStyle?
    var colorName: String?
    var colorHex: String?
    var time: WallpaperTime?
    var season: WallpaperSeason?
    var weather: WallpaperWeather?
    var variation = 0

    init(mood: WallpaperMood? = nil, style: WallpaperStyle? = nil, color: String? = nil, time: WallpaperTime? = nil,
         season: WallpaperSeason? = nil, weather: WallpaperWeather? = nil, variation: Int = 0) {
        self.mood = mood
        self.style = style
        self.colorHex = color.flatMap(WallpaperColor.hex)
        self.colorName = color.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        self.time = time
        self.season = season
        self.weather = weather
        self.variation = variation
    }

    init(arguments: [String: JSONValue]) throws {
        guard let tool = AssistantTools.named("preview_wallpaper") else { throw ToolFailure("Wallpaper tools are unavailable.") }
        let args = try ToolArgs(tool: tool, values: arguments)
        self.init()
        mood = try args.choice("mood", WallpaperMood.self, aliases: ["peaceful": .calm, "relaxed": .calm, "joyful": .happy, "cheerful": .happy,
                                                                    "warm": .cozy, "sad": .melancholy, "moody": .mysterious, "dark": .mysterious,
                                                                    "epic": .dramatic, "fun": .playful, "productive": .focused, "love": .romantic])
        style = try args.choice("style", WallpaperStyle.self, aliases: ["meshgradient": .mesh, "abstract": .mesh, "landscape": .mountains,
                                                                      "mountain": .mountains, "desert": .dunes, "ocean": .waves, "sea": .waves,
                                                                      "northernlights": .aurora, "lights": .bokeh, "shapes": .blobs, "flat": .minimal])
        time = try args.choice("time_of_day", WallpaperTime.self, aliases: ["goldenhour": .goldenHour, "midday": .noon, "twilight": .dusk, "sundown": .sunset])
        season = try args.choice("season", WallpaperSeason.self, aliases: ["fall": .autumn])
        weather = try args.choice("weather", WallpaperWeather.self, aliases: ["rainy": .rain, "snowy": .snow, "foggy": .fog, "mist": .fog, "misty": .fog,
                                                                            "stormy": .storm, "thunderstorm": .storm, "cloud": .cloudy, "clouds": .cloudy,
                                                                            "partlycloudy": .partlyCloudy, "wind": .windy])
        if let color = try args.string("color") {
            guard let hex = WallpaperColor.hex(color) else {
                throw ToolFailure("Unknown color '\(color)'. Use a hex value like #3A7BD5 or one of: \(WallpaperColor.names.joined(separator: ", ")).")
            }
            colorHex = hex
            colorName = color.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        variation = try args.int("variation", in: 0...9999) ?? 0
    }

    var canonical: String {
        "mood=\(mood?.rawValue ?? "");style=\(style?.rawValue ?? "");color=\(colorHex ?? "");time=\(time?.rawValue ?? "");"
            + "season=\(season?.rawValue ?? "");weather=\(weather?.rawValue ?? "");variation=\(variation)"
    }

    var seed: UInt64 { Wallpaper.fnv1a(canonical) }

    /// Shapes depend on style, mood, colour and variation only, so the same scene keeps its place when time, season or weather change.
    var layoutSeed: UInt64 { Wallpaper.fnv1a("layout|\(resolvedStyle.rawValue)|\(mood?.rawValue ?? "")|\(colorHex ?? "")|\(variation)") }

    var resolvedStyle: WallpaperStyle {
        if let style { return style }
        let night = time == .night || time == .midnight || time == .evening || mood == .mysterious
        let scenic = time != nil || season != nil || [.rain, .snow, .storm, .fog].contains(weather)
        var options: [WallpaperStyle] = scenic ? [.mountains, .dunes, .waves, .minimal] : [.mesh, .blobs, .gradient, .waves, .bokeh]
        if night && (weather == nil || weather == .clear) { options.append(.aurora) }
        return options[Int(seed % UInt64(options.count))]
    }

    var summary: String {
        let parts = [mood?.rawValue, colorName.map { $0.hasPrefix("#") ? $0.uppercased() : $0 }, season?.rawValue, time.map { $0.rawValue.replacingOccurrences(of: "_", with: " ") },
                     weather.map { $0.rawValue.replacingOccurrences(of: "_", with: " ") }].compactMap { $0 }
        let head = parts.isEmpty ? "CoolDock" : parts.joined(separator: ", ")
        return "\(head) — \(resolvedStyle.rawValue)\(variation > 0 ? " #\(variation)" : "")"
    }

    var fileStem: String {
        let parts = [mood?.rawValue, season?.rawValue, time?.rawValue, weather?.rawValue, resolvedStyle.rawValue].compactMap { $0 }
        let slug = parts.joined(separator: "-").replacingOccurrences(of: "_", with: "-")
        // The render version is part of the name so an improved painter never reuses an older file.
        let hash = Wallpaper.fnv1a("v\(Wallpaper.renderVersion)|" + canonical)
        return "cooldock-\(slug)-\(String(format: "%08llx", hash & 0xFFFF_FFFF))"
    }

    var parametersJSON: JSONValue {
        [
            "mood": .optional(mood?.rawValue), "style": .string(resolvedStyle.rawValue), "color": .optional(colorHex),
            "time_of_day": .optional(time?.rawValue), "season": .optional(season?.rawValue), "weather": .optional(weather?.rawValue),
            "variation": .int(variation)
        ]
    }
}

// MARK: - Colour math

struct RGB: Equatable {
    var r: Double, g: Double, b: Double

    init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }

    init(_ hex: String) {
        let v = UInt32(hex.dropFirst(), radix: 16) ?? 0
        self.init(Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    init(h: Double, s: Double, v: Double) {
        let h6 = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let c = v * s, x = c * (1 - abs(h6.truncatingRemainder(dividingBy: 2) - 1)), m = v - c
        let (r, g, b): (Double, Double, Double)
        switch Int(h6) {
        case 0: (r, g, b) = (c, x, 0)
        case 1: (r, g, b) = (x, c, 0)
        case 2: (r, g, b) = (0, c, x)
        case 3: (r, g, b) = (0, x, c)
        case 4: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        self.init(r + m, g + m, b + m)
    }

    var hsv: (h: Double, s: Double, v: Double) {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h = 0.0
        if d > 0 {
            if mx == r { h = 60 * ((g - b) / d).truncatingRemainder(dividingBy: 6) } else if mx == g { h = 60 * ((b - r) / d + 2) } else { h = 60 * ((r - g) / d + 4) }
        }
        return ((h + 360).truncatingRemainder(dividingBy: 360), mx == 0 ? 0 : d / mx, mx)
    }

    var luma: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    func mix(_ o: RGB, _ t: Double) -> RGB { RGB(r + (o.r - r) * t, g + (o.g - g) * t, b + (o.b - b) * t) }

    func adjusted(sat: Double = 1, bri: Double = 1) -> RGB {
        let c = hsv
        return RGB(h: c.h, s: min(1, max(0, c.s * sat)), v: min(1, max(0, c.v * bri)))
    }

    /// Rotates the hue toward `target` (degrees) by `amount` along the shorter arc.
    func hue(toward target: Double, _ amount: Double) -> RGB {
        let c = hsv
        var d = (target - c.h).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return RGB(h: c.h + d * amount, s: c.s, v: c.v)
    }

    func rotated(_ degrees: Double) -> RGB { let c = hsv; return RGB(h: c.h + degrees, s: c.s, v: c.v) }

    func cg(_ alpha: Double = 1) -> CGColor {
        CGColor(srgbRed: min(1, max(0, r)), green: min(1, max(0, g)), blue: min(1, max(0, b)), alpha: alpha)
    }

    static let white = RGB(1, 1, 1)
    static let black = RGB(0, 0, 0)
}

/// Deterministic PRNG (SplitMix64).
struct SplitMix64 {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> Double { Double(next() >> 11) / Double(UInt64(1) << 53) }
    mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * unit() }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(max(1, n))) }
    mutating func pick<T>(_ items: [T]) -> T { items[int(items.count)] }
}

// MARK: - Palette

struct WallpaperPalette {
    var sky: [RGB]          // top, middle, horizon
    var glow: RGB           // sun / light colour
    var accent: RGB
    var land: [RGB]         // far, near
    var night: Double       // 0 day … 1 deep night
    var sun: Double?        // sun height above the horizon 0…1; nil = sun not visible
    var moon = false

    var all: [RGB] { sky + [glow, accent] + land }

    mutating func map(_ f: (RGB) -> RGB) {
        sky = sky.map(f); glow = f(glow); accent = f(accent); land = land.map(f)
    }

    func landColor(_ t: Double) -> RGB { land[0].mix(land[1], t) }
}

struct WallpaperEffects {
    var clouds = 0.0, darkClouds = false, rain = 0.0, snow = 0.0, fog = 0.0, wind = 0.0, lightning = false, stars = 0.0
    var sunAlpha = 1.0
}

enum Wallpaper {
    /// Bump when the painting changes so earlier files are not reused.
    static let renderVersion = 1

    static func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01B3 }
        return h
    }

    private static func p(_ sky: [String], _ glow: String, _ accent: String, _ land: [String], night: Double = 0, sun: Double? = nil, moon: Bool = false) -> WallpaperPalette {
        WallpaperPalette(sky: sky.map(RGB.init), glow: RGB(glow), accent: RGB(accent), land: land.map(RGB.init), night: night, sun: sun, moon: moon)
    }

    static func timePalette(_ t: WallpaperTime) -> WallpaperPalette {
        switch t {
        case .dawn: return p(["#1F2B52", "#6B5B95", "#F3A683"], "#FFD3A5", "#F78FB3", ["#4A4A7A", "#2A2B4F"], night: 0.35, sun: 0.0)
        case .sunrise: return p(["#3B5998", "#E8A0A0", "#FFD39B"], "#FFE7B0", "#FF9A76", ["#6C6F9E", "#353A63"], night: 0.1, sun: 0.07)
        case .morning: return p(["#4A9FE3", "#9ED0F2", "#E6F4FA"], "#FFF7DB", "#FFD36E", ["#7FAF8A", "#3F7A57"], sun: 0.45)
        case .noon: return p(["#1F7DD8", "#5EB3F0", "#CBEAFB"], "#FFFFFF", "#FFE08A", ["#6FB36A", "#2F7D3E"], sun: 0.85)
        case .afternoon: return p(["#3D8BD6", "#86BFEA", "#F2E2C2"], "#FFF1C9", "#F7B267", ["#8DAF68", "#557A3A"], sun: 0.55)
        case .goldenHour: return p(["#E98D4E", "#F6C177", "#FCE6B0"], "#FFF2C6", "#E76F51", ["#B98250", "#6B4428"], sun: 0.18)
        case .sunset: return p(["#2D2A6E", "#C1447E", "#FF8C55"], "#FFC46B", "#FF5E62", ["#5B2C55", "#26142F"], night: 0.15, sun: 0.05)
        case .dusk: return p(["#141A3C", "#4A3B7A", "#C76D8E"], "#F4A27E", "#9D7BD8", ["#2C2552", "#141230"], night: 0.55)
        case .evening: return p(["#0E1A35", "#22386C", "#5A70AA"], "#A7B8EC", "#7C9CFF", ["#1C2748", "#0D1429"], night: 0.75, moon: true)
        case .night: return p(["#050817", "#0B1638", "#1B2D62"], "#8EA6FF", "#5E7CE2", ["#0B132D", "#050A19"], night: 1, moon: true)
        case .midnight: return p(["#020309", "#060A21", "#0F173C"], "#6E7ED8", "#4A5BC2", ["#070B1D", "#020511"], night: 1, moon: true)
        }
    }

    static func seasonPalette(_ s: WallpaperSeason) -> WallpaperPalette {
        switch s {
        case .spring: return p(["#8EC9F0", "#CFE9F7", "#FDE2EA"], "#FFF6E5", "#F48FB1", ["#A8D58A", "#5E9B47"], sun: 0.6)
        case .summer: return p(["#1B86E0", "#5CB8F2", "#FFF3B8"], "#FFFBE6", "#FFB703", ["#3FA36B", "#1D6B45"], sun: 0.75)
        case .autumn: return p(["#D9895B", "#F2BE8A", "#FBE3C4"], "#FFEFD2", "#C2410C", ["#B5652A", "#6B2F12"], sun: 0.3)
        case .winter: return p(["#93B5D3", "#D3E2EF", "#F3F7FB"], "#FFFFFF", "#8FB8DE", ["#E3ECF4", "#AFC4D8"], sun: 0.25)
        }
    }

    static func moodPalette(_ m: WallpaperMood) -> WallpaperPalette {
        switch m {
        case .calm: return p(["#7FA7C9", "#B9D3E3", "#E8F1F2"], "#FFFFFF", "#86C5C2", ["#8FB5B8", "#4F7F86"], sun: 0.35)
        case .serene: return p(["#9CC7C4", "#D7E9E2", "#F6F1E7"], "#FFFDF5", "#E8C9A0", ["#A3C4BC", "#5E8C82"], sun: 0.4)
        case .happy: return p(["#FFB347", "#FFD56B", "#FFF4C2"], "#FFFFFF", "#4ECDC4", ["#9ED56B", "#4FA34A"], sun: 0.6)
        case .energetic: return p(["#FF006E", "#FB5607", "#FFBE0B"], "#FFF3B0", "#3A86FF", ["#8338EC", "#3A0CA3"], sun: 0.3)
        case .cozy: return p(["#5C3A2E", "#B9714B", "#F0C38E"], "#FFE1A8", "#E07A5F", ["#7A4B35", "#3B2219"], night: 0.2, sun: 0.12)
        case .dreamy: return p(["#B8A4E3", "#F3C4DE", "#C9E4F8"], "#FFFFFF", "#F9D8FF", ["#A99BD8", "#7C6FB5"], sun: 0.4)
        case .romantic: return p(["#6D1A45", "#D9527F", "#FFC1D3"], "#FFE3EC", "#FF8FAB", ["#8C2F5A", "#45132E"], night: 0.1, sun: 0.15)
        case .mysterious: return p(["#081226", "#1A2A4A", "#355C7D"], "#6FD3C9", "#5BC0BE", ["#13213D", "#070E1F"], night: 0.8, moon: true)
        case .dramatic: return p(["#0B0A0F", "#5E0B15", "#C1121F"], "#FFB703", "#FB8500", ["#2B0A10", "#0B0507"], night: 0.3, sun: 0.1)
        case .melancholy: return p(["#2E3D4F", "#5C7185", "#A7B4C2"], "#DCE3EA", "#8DA9C4", ["#46586B", "#26323F"], night: 0.2)
        case .focused: return p(["#0E1C2F", "#1F3A5C", "#4D6E91"], "#CFE0F5", "#7FA6D6", ["#1A2D45", "#0B1626"], night: 0.4)
        case .playful: return p(["#7B2FF7", "#F107A3", "#FFB86B"], "#FFF3D6", "#00D1FF", ["#3A86FF", "#06D6A0"], sun: 0.35)
        }
    }

    static func colorPalette(_ c: RGB) -> WallpaperPalette {
        let hsv = c.hsv
        if hsv.s < 0.12 {
            let dark = hsv.v < 0.35
            return WallpaperPalette(sky: [c.adjusted(bri: dark ? 0.6 : 0.62), c, c.mix(.white, 0.55)], glow: c.mix(.white, 0.85),
                                    accent: c.mix(.white, dark ? 0.35 : 0.2), land: [c.adjusted(bri: 0.5), c.adjusted(bri: 0.28)],
                                    night: dark ? 0.7 : 0, sun: dark ? nil : 0.35, moon: dark)
        }
        return WallpaperPalette(sky: [RGB(h: hsv.h - 12, s: min(1, hsv.s * 1.05), v: hsv.v * 0.5), c, c.mix(.white, 0.55)],
                                glow: c.mix(.white, 0.82), accent: c.rotated(38).adjusted(sat: 0.9),
                                land: [RGB(h: hsv.h + 14, s: hsv.s, v: hsv.v * 0.48), RGB(h: hsv.h + 20, s: hsv.s, v: hsv.v * 0.26)],
                                night: hsv.v < 0.35 ? 0.6 : 0, sun: hsv.v < 0.35 ? nil : 0.35, moon: hsv.v < 0.35)
    }

    static func palette(_ r: WallpaperRequest) -> WallpaperPalette {
        var pal: WallpaperPalette
        var fromMood = false, fromColor = false
        if let t = r.time { pal = timePalette(t) } else if let s = r.season { pal = seasonPalette(s) } else if let m = r.mood {
            pal = moodPalette(m); fromMood = true
        } else if let hex = r.colorHex {
            pal = colorPalette(RGB(hex)); fromColor = true
        } else {
            var rng = SplitMix64(r.seed)
            pal = moodPalette(rng.pick(WallpaperMood.allCases)); fromMood = true
        }

        if let season = r.season, r.time != nil {
            let sp = seasonPalette(season)
            pal.land = zip(pal.land, sp.land).map { timeLand, seasonLand in
                let t = timeLand.hsv, s = seasonLand.hsv
                let bright = season == .winter ? min(0.95, t.v * 1.9 + 0.08) : t.v
                return RGB(h: s.h, s: t.s + (s.s - t.s) * 0.75, v: bright)
            }
            pal.accent = pal.accent.mix(sp.accent, 0.5)
            switch season {
            case .winter: pal.sky = pal.sky.map { $0.adjusted(sat: 0.72) }
            case .autumn: pal.sky = pal.sky.map { $0.hue(toward: 28, 0.12) }
            case .spring: pal.sky = pal.sky.map { $0.hue(toward: 330, 0.05).adjusted(sat: 0.95, bri: 1.03) }
            case .summer: pal.sky = pal.sky.map { $0.adjusted(sat: 1.1) }
            }
        }

        if let mood = r.mood, !fromMood {
            let (sat, bri, hue, amount): (Double, Double, Double?, Double)
            switch mood {
            case .calm: (sat, bri, hue, amount) = (0.8, 1.0, 205, 0.12)
            case .serene: (sat, bri, hue, amount) = (0.75, 1.04, 170, 0.1)
            case .happy: (sat, bri, hue, amount) = (1.15, 1.08, 48, 0.12)
            case .energetic: (sat, bri, hue, amount) = (1.3, 1.05, nil, 0)
            case .cozy: (sat, bri, hue, amount) = (0.95, 0.88, 28, 0.18)
            case .dreamy: (sat, bri, hue, amount) = (0.7, 1.08, 290, 0.18)
            case .romantic: (sat, bri, hue, amount) = (1.05, 1.0, 340, 0.22)
            case .mysterious: (sat, bri, hue, amount) = (0.9, 0.72, 225, 0.15)
            case .dramatic: (sat, bri, hue, amount) = (1.2, 0.85, 355, 0.1)
            case .melancholy: (sat, bri, hue, amount) = (0.55, 0.85, 215, 0.15)
            case .focused: (sat, bri, hue, amount) = (0.7, 0.92, 215, 0.1)
            case .playful: (sat, bri, hue, amount) = (1.25, 1.05, nil, 0)
            }
            pal.map { c in
                let shifted = hue.map { c.hue(toward: $0, amount) } ?? c
                return shifted.adjusted(sat: sat, bri: bri)
            }
            if mood == .playful { pal.accent = pal.accent.rotated(120) }
            if mood == .mysterious { pal.night = max(pal.night, 0.6) }
        }

        if let hex = r.colorHex, !fromColor {
            let target = RGB(hex), t = target.hsv
            if t.s < 0.12 {
                pal.map { $0.adjusted(sat: 0.25).mix(RGB(h: 0, s: 0, v: t.v), 0.25) }
            } else {
                pal.map { c in
                    let shifted = c.hue(toward: t.h, 0.6)
                    let s = shifted.hsv
                    return RGB(h: s.h, s: min(1, max(s.s, t.s * 0.55)), v: s.v)
                }
                pal.accent = target.adjusted(bri: pal.night > 0.5 ? 0.85 : 1)
            }
        }

        if let w = r.weather {
            switch w {
            case .clear: pal.map { $0.adjusted(sat: 1.05) }
            case .sunny: pal.map { $0.adjusted(sat: 1.1, bri: 1.04) }
            case .partlyCloudy: pal.map { $0.adjusted(sat: 0.92) }
            case .cloudy: pal.map { $0.adjusted(sat: 0.65).mix(RGB(h: 0, s: 0, v: $0.luma), 0.3) }
            case .overcast: pal.map { $0.adjusted(sat: 0.45).mix(RGB(h: 0, s: 0, v: $0.luma), 0.5) }; pal.sun = nil
            case .rain: pal.map { $0.adjusted(sat: 0.5, bri: 0.78).mix(RGB("#5B6B7A"), 0.35) }; pal.sun = nil
            case .storm: pal.map { $0.adjusted(sat: 0.5, bri: 0.55).mix(RGB("#2B2F4A"), 0.45) }; pal.sun = nil
            case .snow:
                pal.sky = pal.sky.map { $0.adjusted(sat: 0.55, bri: 1.08).mix(RGB("#EEF3F8"), pal.night > 0.5 ? 0.12 : 0.35) }
                pal.land = pal.land.map { $0.adjusted(sat: 0.4).mix(RGB("#EEF3F8"), pal.night > 0.5 ? 0.3 : 0.6) }
                pal.sun = nil
            case .fog:
                let haze = pal.sky[2].mix(.white, 0.5)
                pal.map { $0.adjusted(sat: 0.5).mix(haze, 0.42) }
            case .windy: break
            }
        }
        return pal
    }

    static func effects(_ r: WallpaperRequest, _ pal: WallpaperPalette) -> WallpaperEffects {
        var fx = WallpaperEffects()
        fx.stars = pal.night > 0.3 ? pal.night : 0
        switch r.weather {
        case .partlyCloudy?: fx.clouds = 0.35; fx.stars *= 0.6
        case .cloudy?: fx.clouds = 0.7; fx.stars *= 0.2; fx.sunAlpha = 0.45
        case .overcast?: fx.clouds = 1; fx.stars = 0
        case .rain?: fx.clouds = 0.9; fx.darkClouds = true; fx.rain = 1; fx.stars = 0
        case .storm?: fx.clouds = 1; fx.darkClouds = true; fx.rain = 1.6; fx.lightning = true; fx.stars = 0
        case .snow?: fx.clouds = 0.55; fx.snow = 1; fx.stars *= 0.2
        case .fog?: fx.fog = 1; fx.stars = 0; fx.sunAlpha = 0.4
        case .windy?: fx.wind = 1; fx.clouds = 0.3
        default: break
        }
        return fx
    }
}

// MARK: - Rendering

/// Paints wallpapers with Core Graphics only (no window server, no UI). Deterministic for a request and size.
struct WallpaperRenderer {
    let request: WallpaperRequest
    let width: Int
    let height: Int

    private var w: Double { Double(width) }
    private var h: Double { Double(height) }
    /// Length unit: 1 at 1000 px on the short side.
    private var u: Double { Double(min(width, height)) / 1000 }
    /// Counts of stars, raindrops… scale with the area relative to a 2880×1800 display.
    private var area: Double { w * h / (2880 * 1800) }

    static let space = CGColorSpace(name: CGColorSpace.sRGB)!

    func render() -> CGImage? {
        guard width > 0, height > 0, let ctx = Self.context(width, height) else { return nil }
        let pal = Wallpaper.palette(request)
        let fx = Wallpaper.effects(request, pal)
        let style = request.resolvedStyle
        var rng = SplitMix64(request.layoutSeed)
        var detail = SplitMix64(request.seed ^ 0x5DEECE66D)

        ctx.translateBy(x: 0, y: h)
        ctx.scaleBy(x: 1, y: -1)   // top-left origin from here on
        ctx.interpolationQuality = .high

        let horizon: Double
        switch style {
        case .mountains: horizon = 0.62
        case .dunes: horizon = 0.6
        case .waves: horizon = 0.56
        case .minimal: horizon = 0.66
        default: horizon = 0.7
        }
        let sunX = rng.range(0.28, 0.72)

        switch style {
        case .gradient:
            fillVertical(ctx, [pal.sky[0], pal.sky[1], pal.sky[2], pal.landColor(0.2), pal.land[1]], [0, 0.38, 0.62, 0.86, 1])
            glow(ctx, x: sunX, y: 0.55, radius: 0.75, color: pal.glow, alpha: 0.55)
            glow(ctx, x: rng.pick([0.08, 0.92]), y: rng.range(0.1, 0.3), radius: 0.6, color: pal.accent, alpha: 0.35)
            stars(ctx, fx.stars * 0.7, below: 0.6, &detail)
        case .mesh:
            mesh(ctx, pal, &rng)
            stars(ctx, fx.stars * 0.5, below: 0.55, &detail)
        case .blobs:
            mesh(ctx, pal, &rng)
            blobs(ctx, pal, &rng)
        case .aurora:
            fillVertical(ctx, [pal.sky[0].adjusted(bri: 0.35), pal.sky[1].adjusted(bri: 0.4), pal.sky[2].adjusted(bri: 0.45)], [0, 0.55, 1])
            stars(ctx, max(fx.stars, 0.8), below: 0.85, &detail)
            aurora(ctx, pal, &rng)
            ridges(ctx, pal, &rng, horizon: 0.78, layers: 2, dark: true)
        case .bokeh:
            fillVertical(ctx, [pal.sky[0], pal.sky[1], pal.sky[2], pal.land[0]], [0, 0.45, 0.75, 1])
            stars(ctx, fx.stars * 0.5, below: 0.7, &detail)
            bokeh(ctx, pal, &rng)
        case .waves, .dunes, .mountains, .minimal:
            // The horizon colour continues below the horizon, so gaps between land layers read as distant haze.
            fillVertical(ctx, [pal.sky[0], pal.sky[1], pal.sky[2]], [0, horizon * 0.62, horizon])
            stars(ctx, fx.stars, below: horizon * 0.95, &detail)
            celestial(ctx, pal, fx, x: sunX, horizon: horizon)
            if fx.clouds > 0 { clouds(ctx, pal, fx, &detail, horizon: horizon) }
            switch style {
            case .mountains: ridges(ctx, pal, &rng, horizon: horizon, layers: 4, dark: false, snowCaps: request.season == .winter || request.weather == .snow)
            case .dunes: dunes(ctx, pal, &rng, horizon: horizon)
            case .waves: waves(ctx, pal, &rng, horizon: horizon)
            default: water(ctx, pal, fx, x: sunX, horizon: horizon)
            }
        }

        if !style.isScenic && fx.clouds > 0.5 { clouds(ctx, pal, fx, &detail, horizon: 0.75) }
        if fx.fog > 0 { fog(ctx, pal, &detail, horizon: horizon) }
        if fx.lightning { lightning(ctx, &detail) }
        if fx.rain > 0 { rain(ctx, fx.rain, &detail) }
        if fx.snow > 0 { snow(ctx, fx.snow, &detail) }
        if fx.wind > 0 { wind(ctx, &detail) }
        vignette(ctx, strength: pal.sky[1].luma > 0.6 ? 0.1 : 0.22)
        grain(ctx)
        return ctx.makeImage()
    }

    static func context(_ width: Int, _ height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    // MARK: Helpers

    private func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * w, y: y * h) }

    private func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
        CGGradient(colorsSpace: Self.space, colors: colors as CFArray, locations: locations)!
    }

    private func fillVertical(_ ctx: CGContext, _ colors: [RGB], _ stops: [Double], from y0: Double = 0, to y1: Double = 1) {
        ctx.drawLinearGradient(gradient(colors.map { $0.cg() }, stops.map { CGFloat($0) }), start: pt(0, y0), end: pt(0, y1),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    /// Radial light; `radius` is a fraction of the width.
    private func glow(_ ctx: CGContext, x: Double, y: Double, radius: Double, color: RGB, alpha: Double) {
        ctx.drawRadialGradient(gradient([color.cg(alpha), color.cg(alpha * 0.35), color.cg(0)], [0, 0.45, 1]),
                               startCenter: pt(x, y), startRadius: 0, endCenter: pt(x, y), endRadius: radius * w, options: [])
    }

    /// Draws `image` over the whole canvas the right way up (the canvas is flipped).
    private func drawUpright(_ ctx: CGContext, _ image: CGImage, alpha: Double = 1, blend: CGBlendMode = .normal) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: h)
        ctx.scaleBy(x: 1, y: -1)
        ctx.setAlpha(alpha)
        ctx.setBlendMode(blend)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.restoreGState()
    }

    /// Paints into a canvas `factor` times smaller, then scales it up: a cheap, deterministic blur for soft shapes.
    private func soft(_ ctx: CGContext, factor: Double, alpha: Double = 1, blend: CGBlendMode = .normal, _ draw: (CGContext) -> Void) {
        let sw = max(2, Int(w / factor)), sh = max(2, Int(h / factor))
        guard let small = Self.context(sw, sh) else { return }
        small.translateBy(x: 0, y: CGFloat(sh))
        small.scaleBy(x: CGFloat(sw) / w, y: -CGFloat(sh) / h)
        draw(small)
        if let image = small.makeImage() { drawUpright(ctx, image, alpha: alpha, blend: blend) }
    }

    private func softDisc(_ ctx: CGContext, x: Double, y: Double, r: Double, color: RGB, alpha: Double) {
        let c = CGPoint(x: x, y: y)
        ctx.drawRadialGradient(gradient([color.cg(alpha), color.cg(alpha * 0.8), color.cg(0)], [0, 0.55, 1]),
                               startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])
    }

    // MARK: Backgrounds

    /// Mesh-like blend: palette colours at scattered points, mixed with Gaussian weights on a coarse grid and scaled up smoothly.
    private func mesh(_ ctx: CGContext, _ pal: WallpaperPalette, _ rng: inout SplitMix64) {
        let colors = [pal.sky[0], pal.sky[1], pal.sky[2], pal.accent.mix(pal.sky[1], 0.35), pal.glow.mix(pal.sky[2], 0.5), pal.land[0], pal.land[1]]
        var points: [(x: Double, y: Double, c: RGB)] = []
        for (i, c) in colors.enumerated() {
            let col = Double(i % 3), row = Double(i / 3)
            points.append((x: (col + rng.range(0.15, 0.85)) / 3, y: (row + rng.range(0.1, 0.9)) / 3, c: c))
        }
        let gw = 320, gh = max(2, Int(Double(gw) * h / w))
        let aspect = w / h
        let phase1 = rng.range(0, 6.28), phase2 = rng.range(0, 6.28)
        let sigma2 = 2 * 0.3 * 0.3
        var bytes = [UInt8](repeating: 255, count: gw * gh * 4)
        for j in 0..<gh {
            let v0 = Double(j) / Double(gh - 1)
            for i in 0..<gw {
                let u0 = Double(i) / Double(gw - 1)
                let uu = u0 + 0.07 * sin(6.283 * v0 * 1.3 + phase1)
                let vv = v0 + 0.07 * sin(6.283 * u0 * 1.1 + phase2)
                var r = 0.0, g = 0.0, b = 0.0, total = 0.0
                for p in points {
                    let dx = (uu - p.x) * aspect, dy = vv - p.y
                    let weight = exp(-(dx * dx + dy * dy) / sigma2) + 1e-4
                    r += p.c.r * weight; g += p.c.g * weight; b += p.c.b * weight; total += weight
                }
                let o = (j * gw + i) * 4
                bytes[o] = UInt8(max(0, min(255, r / total * 255)))
                bytes[o + 1] = UInt8(max(0, min(255, g / total * 255)))
                bytes[o + 2] = UInt8(max(0, min(255, b / total * 255)))
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: gw, height: gh, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: gw * 4, space: Self.space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
                                  decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return }
        drawUpright(ctx, image)
    }

    private func blobs(_ ctx: CGContext, _ pal: WallpaperPalette, _ rng: inout SplitMix64) {
        let colors = [pal.accent, pal.glow, pal.sky[2], pal.accent.rotated(30), pal.sky[0].mix(.white, 0.25)]
        var rng2 = rng
        soft(ctx, factor: 4, blend: pal.sky[1].luma > 0.5 ? .normal : .screen) { c in
            for color in colors {
                let r = rng2.range(0.18, 0.34) * w
                softDisc(c, x: rng2.range(0.05, 0.95) * w, y: rng2.range(0.05, 0.95) * h, r: r, color: color, alpha: rng2.range(0.45, 0.75))
            }
        }
        rng = rng2
        for _ in 0..<3 {
            let r = rng.range(0.06, 0.16) * w
            let rect = CGRect(x: rng.range(0.05, 0.95) * w - r, y: rng.range(0.05, 0.95) * h - r, width: 2 * r, height: 2 * r)
            ctx.setFillColor(RGB.white.cg(0.07))
            ctx.fillEllipse(in: rect)
            ctx.setStrokeColor(RGB.white.cg(0.18))
            ctx.setLineWidth(max(1, 1.4 * u))
            ctx.strokeEllipse(in: rect)
        }
    }

    /// Curtains of light: each ribbon is a stack of bands that fade upward along a wavy base line, softened by `soft`.
    private func aurora(_ ctx: CGContext, _ pal: WallpaperPalette, _ rng: inout SplitMix64) {
        let base = pal.accent.hsv
        let colors = [RGB(h: base.h, s: max(0.55, base.s), v: 0.95), RGB(h: base.h + 55, s: 0.6, v: 0.9), RGB(h: base.h - 70, s: 0.55, v: 0.85)]
        var rng2 = rng
        soft(ctx, factor: 4, blend: .screen) { c in
            for (k, color) in colors.enumerated() {
                let baseY = rng2.range(0.34, 0.48) + Double(k) * 0.06
                let a1 = rng2.range(0.04, 0.08), f1 = rng2.range(0.8, 1.6), p1 = rng2.range(0, 6.28)
                let a2 = rng2.range(0.01, 0.025), f2 = rng2.range(3, 5), p2 = rng2.range(0, 6.28)
                let tall = rng2.range(0.14, 0.26)
                let xs = stride(from: -0.02, through: 1.02, by: 0.004).map { $0 }
                func bottom(_ x: Double) -> Double { baseY + a1 * sin(6.283 * f1 * x + p1) + a2 * sin(6.283 * f2 * x + p2) }
                func height(_ x: Double) -> Double { tall * (0.55 + 0.45 * (0.5 + 0.5 * sin(6.283 * 2.3 * x + p2))) }
                let bands = 10
                for band in 0..<bands {
                    let lo = Double(band) / Double(bands), hi = Double(band + 1) / Double(bands)
                    let path = CGMutablePath()
                    path.addLines(between: xs.map { pt($0, bottom($0) - height($0) * hi) } + xs.reversed().map { pt($0, bottom($0) - height($0) * lo) })
                    path.closeSubpath()
                    c.addPath(path)
                    c.setFillColor(color.cg(0.24 * pow(1 - lo, 1.4)))
                    c.fillPath()
                }
                // Faint vertical rays give the curtain its texture.
                for _ in 0..<40 {
                    let x = rng2.unit()
                    let y = bottom(x), hgt = height(x) * rng2.range(0.6, 1.1)
                    c.setStrokeColor(color.mix(.white, 0.3).cg(rng2.range(0.08, 0.2)))
                    c.setLineWidth(rng2.range(1.5, 4) * u)
                    c.move(to: pt(x, y))
                    c.addLine(to: pt(x + rng2.range(-0.004, 0.004), y - hgt))
                    c.strokePath()
                }
            }
        }
        rng = rng2
    }

    private func bokeh(_ ctx: CGContext, _ pal: WallpaperPalette, _ rng: inout SplitMix64) {
        let colors = [pal.glow, pal.accent, pal.sky[2], pal.accent.rotated(-25)]
        var rng2 = rng
        let count = 46
        soft(ctx, factor: 3, blend: .screen) { c in
            for _ in 0..<count {
                let r = rng2.range(0.012, 0.075) * Double(min(width, height))
                softDisc(c, x: rng2.unit() * w, y: rng2.range(0.05, 0.95) * h, r: r, color: rng2.pick(colors), alpha: rng2.range(0.15, 0.45))
            }
        }
        rng = rng2
        ctx.saveGState()
        ctx.setBlendMode(.screen)
        for _ in 0..<14 {
            let r = rng.range(0.015, 0.05) * Double(min(width, height))
            let rect = CGRect(x: rng.unit() * w - r, y: rng.range(0.1, 0.9) * h - r, width: 2 * r, height: 2 * r)
            let color = rng.pick(colors)
            ctx.setFillColor(color.cg(0.12))
            ctx.fillEllipse(in: rect)
            ctx.setStrokeColor(color.cg(0.22))
            ctx.setLineWidth(max(1, 1.2 * u))
            ctx.strokeEllipse(in: rect)
        }
        ctx.restoreGState()
    }

    // MARK: Sky

    private func stars(_ ctx: CGContext, _ amount: Double, below limit: Double, _ rng: inout SplitMix64) {
        guard amount > 0 else { return }
        let count = Int(420 * amount * area)
        for _ in 0..<count {
            let x = rng.unit() * w, y = pow(rng.unit(), 1.4) * limit * h
            let r = rng.range(0.35, 1.25) * u * 1.6
            let a = rng.range(0.25, 0.95) * min(1, amount + 0.2)
            ctx.setFillColor(RGB.white.cg(a))
            ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
            if rng.unit() < 0.04 { softDisc(ctx, x: x, y: y, r: r * 6, color: RGB(0.85, 0.9, 1), alpha: 0.25) }
        }
    }

    private func celestial(_ ctx: CGContext, _ pal: WallpaperPalette, _ fx: WallpaperEffects, x: Double, horizon: Double) {
        if let sun = pal.sun {
            let y = horizon - sun * (horizon - 0.14)
            glow(ctx, x: x, y: y, radius: 0.55, color: pal.glow, alpha: 0.6 * fx.sunAlpha)
            let r = (sun < 0.2 ? 62 : 46) * u
            let c = pt(x, y)
            ctx.drawRadialGradient(gradient([RGB.white.cg(fx.sunAlpha), pal.glow.mix(.white, 0.5).cg(fx.sunAlpha), pal.glow.cg(fx.sunAlpha * 0.95), pal.glow.cg(0)], [0, 0.55, 0.92, 1]),
                                   startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])
        } else if pal.moon && fx.clouds < 0.8 {
            let c = pt(1 - x, 0.2)
            glow(ctx, x: 1 - x, y: 0.2, radius: 0.25, color: RGB(0.8, 0.85, 1), alpha: 0.22)
            let r = 34 * u
            ctx.setFillColor(RGB("#F2EFE6").cg(fx.fog > 0 ? 0.5 : 0.96))
            ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            ctx.setFillColor(RGB("#B9B4A6").cg(0.18))
            for (dx, dy, k) in [(-0.3, -0.2, 0.28), (0.25, 0.1, 0.2), (-0.05, 0.38, 0.16)] {
                let rr = r * k
                ctx.fillEllipse(in: CGRect(x: c.x + dx * r - rr, y: c.y + dy * r - rr, width: 2 * rr, height: 2 * rr))
            }
        } else if pal.night < 0.5 {
            glow(ctx, x: x, y: horizon, radius: 0.6, color: pal.glow, alpha: 0.4)
        }
    }

    private func clouds(_ ctx: CGContext, _ pal: WallpaperPalette, _ fx: WallpaperEffects, _ rng: inout SplitMix64, horizon: Double) {
        let light = pal.night > 0.5 ? pal.sky[2].mix(.white, 0.15) : RGB.white.mix(pal.sky[1], 0.15)
        let color = fx.darkClouds ? pal.sky[0].mix(RGB("#3A3F4B"), 0.5) : light
        let count = Int(4 + 10 * fx.clouds)
        var rng2 = rng
        soft(ctx, factor: 5, alpha: fx.darkClouds ? 0.92 : 0.85) { c in
            if fx.clouds >= 0.9 {
                c.drawLinearGradient(gradient([color.cg(0.85), color.cg(0.55), color.cg(0)], [0, 0.6, 1]), start: pt(0, 0), end: pt(0, horizon * 0.8), options: [])
            }
            for _ in 0..<count {
                let cx = rng2.unit() * w, cy = rng2.range(0.06, horizon * 0.62) * h
                let cw = rng2.range(0.12, 0.3) * w * (fx.wind > 0 ? 1.6 : 1)
                for _ in 0..<8 {
                    let r = rng2.range(0.18, 0.42) * cw
                    softDisc(c, x: cx + rng2.range(-0.5, 0.5) * cw, y: cy + rng2.range(-0.12, 0.12) * cw, r: r, color: color, alpha: rng2.range(0.35, 0.65))
                }
            }
        }
        rng = rng2
    }

    // MARK: Land

    /// Ridges from midpoint displacement with atmospheric haze toward the horizon colour.
    private func ridges(_ ctx: CGContext, _ pal: WallpaperPalette, _ rng: inout SplitMix64, horizon: Double, layers: Int, dark: Bool, snowCaps: Bool = false) {
        for layer in 0..<layers {
            let t = Double(layer) / Double(max(1, layers - 1))
            let base = horizon - 0.08 + t * (dark ? 0.12 : 0.24)
            let amp = (0.2 - t * 0.1) * (dark ? 0.6 : 1)
            var heights = [Double](repeating: 0, count: 65)
            heights[0] = rng.range(-0.5, 0.5); heights[64] = rng.range(-0.5, 0.5)
            var step = 64, scale = 1.0
            while step > 1 {
                let half = step / 2
                var i = half
                while i < 64 {
                    heights[i] = (heights[i - half] + heights[i + half]) / 2 + rng.range(-1, 1) * scale
                    i += step
                }
                step = half
                scale *= 0.55
            }
            let path = CGMutablePath()
            path.move(to: pt(0, 1.02))
            var points: [CGPoint] = []
            for (i, v) in heights.enumerated() { points.append(pt(Double(i) / 64, base - v * amp * 0.5)) }
            path.addLine(to: points[0])
            for i in 1..<points.count {
                let mid = CGPoint(x: (points[i - 1].x + points[i].x) / 2, y: (points[i - 1].y + points[i].y) / 2)
                path.addQuadCurve(to: mid, control: points[i - 1])
            }
            path.addLine(to: points.last!)
            path.addLine(to: pt(1, 1.02))
            path.closeSubpath()

            let haze = dark ? 0.0 : (1 - t) * 0.55
            var top = pal.landColor(t).mix(pal.sky[2], haze)
            var bottom = pal.landColor(min(1, t + 0.25)).mix(pal.sky[2], haze * 0.6)
            if dark { top = pal.land[1].adjusted(bri: 0.45); bottom = pal.land[1].adjusted(bri: 0.3) }
            let minY = points.map(\.y).min() ?? CGFloat(base * h)
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            ctx.drawLinearGradient(gradient([top.cg(), bottom.cg()], [0, 1]), start: CGPoint(x: 0, y: minY), end: pt(0, min(1, base + 0.3)),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            if snowCaps && layer < 2 {
                ctx.drawLinearGradient(gradient([RGB.white.cg(0.85), RGB.white.cg(0)], [0, 1]), start: CGPoint(x: 0, y: minY),
                                       end: CGPoint(x: 0, y: minY + CGFloat(amp * 0.35 * h)), options: [])
            }
            ctx.restoreGState()
        }
    }

    private func dunes(_ ctx: CGContext, _ pal: WallpaperPalette, _ rng: inout SplitMix64, horizon: Double) {
        let layers = 4
        for layer in 0..<layers {
            let t = Double(layer) / Double(layers - 1)
            let base = horizon + t * 0.24 - 0.04
            let a1 = rng.range(0.025, 0.06), f1 = rng.range(0.6, 1.4), p1 = rng.range(0, 6.28)
            let a2 = rng.range(0.008, 0.02), f2 = rng.range(2, 3.5), p2 = rng.range(0, 6.28)
            let path = CGMutablePath()
            path.move(to: pt(0, 1.02))
            var crest: [CGPoint] = []
            var x = 0.0
            while x <= 1.0001 {
                crest.append(pt(x, base + a1 * sin(6.283 * f1 * x + p1) + a2 * sin(6.283 * f2 * x + p2)))
                x += 0.01
            }
            path.addLines(between: [pt(0, 1.02)] + crest + [pt(1, 1.02)])
            path.closeSubpath()
            let lit = pal.landColor(t).mix(pal.glow, 0.28 * (1 - t)).mix(pal.sky[2], (1 - t) * 0.35)
            let shade = pal.landColor(min(1, t + 0.3)).adjusted(bri: 0.85)
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            ctx.drawLinearGradient(gradient([lit.cg(), shade.cg()], [0, 1]), start: pt(0, base - a1), end: pt(0, base + 0.22),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            ctx.restoreGState()
            let line = CGMutablePath()
            line.addLines(between: crest)
            ctx.addPath(line)
            ctx.setStrokeColor(pal.glow.cg(0.22 * (1 - t * 0.5)))
            ctx.setLineWidth(max(1, 2.2 * u))
            ctx.strokePath()
        }
    }

    private func waves(_ ctx: CGContext, _ pal: WallpaperPalette, _ rng: inout SplitMix64, horizon: Double) {
        let layers = 5
        let palette = [pal.sky[2].mix(pal.accent, 0.3), pal.accent.mix(pal.sky[1], 0.4), pal.accent, pal.landColor(0.3), pal.land[1]]
        for layer in 0..<layers {
            let t = Double(layer) / Double(layers - 1)
            let base = horizon + t * 0.3 - 0.02
            let a1 = rng.range(0.02, 0.045), f1 = rng.range(0.8, 1.6), p1 = rng.range(0, 6.28)
            let a2 = rng.range(0.006, 0.014), f2 = rng.range(3, 5), p2 = rng.range(0, 6.28)
            var crest: [CGPoint] = []
            var x = 0.0
            while x <= 1.0001 {
                crest.append(pt(x, base + a1 * sin(6.283 * f1 * x + p1) + a2 * sin(6.283 * f2 * x + p2)))
                x += 0.005
            }
            let path = CGMutablePath()
            path.addLines(between: [pt(0, 1.02)] + crest + [pt(1, 1.02)])
            path.closeSubpath()
            let color = palette[layer]
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 5 * u), blur: CGFloat(26 * u), color: RGB.black.cg(0.2))
            ctx.addPath(path)
            ctx.setFillColor(color.cg())
            ctx.fillPath()
            ctx.restoreGState()
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            ctx.drawLinearGradient(gradient([color.mix(.white, 0.14).cg(), color.adjusted(bri: 0.8).cg()], [0, 1]), start: pt(0, base - a1),
                                   end: pt(0, base + 0.28), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            ctx.restoreGState()
            let line = CGMutablePath()
            line.addLines(between: crest)
            ctx.addPath(line)
            ctx.setStrokeColor(RGB.white.cg(0.16))
            ctx.setLineWidth(max(1, 1.6 * u))
            ctx.strokePath()
        }
    }

    /// Calm water below a flat horizon with the light reflected in streaks.
    private func water(_ ctx: CGContext, _ pal: WallpaperPalette, _ fx: WallpaperEffects, x: Double, horizon: Double) {
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: horizon * h, width: w, height: h - horizon * h))
        fillVertical(ctx, [pal.sky[2].mix(pal.land[0], 0.5), pal.land[0], pal.land[1]], [0, 0.35, 1], from: horizon, to: 1)
        ctx.restoreGState()
        let light = pal.sun != nil ? pal.glow : (pal.moon ? RGB("#F2EFE6") : pal.accent)
        var y = horizon + 0.008
        var k = 0
        while y < 0.98 {
            let spread = 0.03 + (y - horizon) * 0.5
            let alpha = 0.32 * (1 - (y - horizon) / (1 - horizon)) * fx.sunAlpha
            ctx.setFillColor(light.cg(alpha))
            let wobble = sin(Double(k) * 1.7) * 0.012
            ctx.fill(CGRect(x: (x - spread / 2 + wobble) * w, y: y * h, width: spread * w, height: max(1, 2 * u)))
            y += 0.012 + (y - horizon) * 0.03
            k += 1
        }
        ctx.setFillColor(pal.glow.cg(0.35))
        ctx.fill(CGRect(x: 0, y: horizon * h, width: w, height: max(1, 1.2 * u)))
    }

    // MARK: Weather

    private func fog(_ ctx: CGContext, _ pal: WallpaperPalette, _ rng: inout SplitMix64, horizon: Double) {
        let color = pal.sky[2].mix(.white, 0.45)
        var rng2 = rng
        soft(ctx, factor: 8, alpha: 0.9) { c in
            for i in 0..<6 {
                let y = horizon - 0.12 + Double(i) * 0.07 + rng2.range(-0.02, 0.02)
                let rect = CGRect(x: -0.3 * w + rng2.range(-0.1, 0.1) * w, y: (y - 0.05) * h, width: 1.6 * w, height: 0.1 * h)
                c.setFillColor(color.cg(rng2.range(0.25, 0.45)))
                c.fillEllipse(in: rect)
            }
        }
        rng = rng2
        ctx.setFillColor(color.cg(0.14))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    }

    private func rain(_ ctx: CGContext, _ amount: Double, _ rng: inout SplitMix64) {
        let count = Int(950 * amount * area)
        let angle = 0.22
        ctx.setLineCap(.round)
        for _ in 0..<count {
            let x = rng.range(-0.1, 1.05) * w, y = rng.unit() * h
            let len = rng.range(0.018, 0.05) * h
            ctx.setStrokeColor(RGB(0.85, 0.9, 1).cg(rng.range(0.06, 0.2)))
            ctx.setLineWidth(max(0.6, rng.range(0.8, 1.6) * u))
            ctx.move(to: CGPoint(x: x, y: y))
            ctx.addLine(to: CGPoint(x: x - len * angle, y: y + len))
            ctx.strokePath()
        }
    }

    private func snow(_ ctx: CGContext, _ amount: Double, _ rng: inout SplitMix64) {
        var rng2 = rng
        soft(ctx, factor: 3) { c in
            for _ in 0..<Int(90 * amount * area) {
                softDisc(c, x: rng2.unit() * w, y: rng2.unit() * h, r: rng2.range(6, 14) * u, color: .white, alpha: rng2.range(0.3, 0.6))
            }
        }
        rng = rng2
        for _ in 0..<Int(800 * amount * area) {
            let r = rng.range(0.7, 2.6) * u
            ctx.setFillColor(RGB.white.cg(rng.range(0.45, 0.95)))
            ctx.fillEllipse(in: CGRect(x: rng.unit() * w - r, y: rng.unit() * h - r, width: 2 * r, height: 2 * r))
        }
    }

    private func wind(_ ctx: CGContext, _ rng: inout SplitMix64) {
        ctx.setLineCap(.round)
        for _ in 0..<16 {
            let x = rng.range(-0.1, 0.9), y = rng.range(0.08, 0.6), len = rng.range(0.15, 0.35), bend = rng.range(-0.03, 0.03)
            ctx.move(to: pt(x, y))
            ctx.addQuadCurve(to: pt(x + len, y + bend * 0.3), control: pt(x + len / 2, y + bend))
            ctx.setStrokeColor(RGB.white.cg(rng.range(0.08, 0.16)))
            ctx.setLineWidth(max(1, rng.range(1, 2) * u))
            ctx.strokePath()
        }
    }

    private func lightning(_ ctx: CGContext, _ rng: inout SplitMix64) {
        let x0 = rng.range(0.2, 0.8)
        glow(ctx, x: x0, y: 0.18, radius: 0.35, color: RGB(0.85, 0.82, 1), alpha: 0.35)
        var points = [pt(x0, 0.08)]
        var x = x0, y = 0.08
        while y < 0.5 {
            x += rng.range(-0.03, 0.03); y += rng.range(0.03, 0.06)
            points.append(pt(x, y))
        }
        let path = CGMutablePath()
        path.addLines(between: points)
        for (width, alpha) in [(10.0, 0.12), (4.0, 0.35), (1.6, 0.95)] {
            ctx.addPath(path)
            ctx.setStrokeColor(RGB(0.95, 0.95, 1).cg(alpha))
            ctx.setLineWidth(max(1, width * u))
            ctx.setLineJoin(.round)
            ctx.strokePath()
        }
    }

    // MARK: Finish

    private func vignette(_ ctx: CGContext, strength: Double) {
        let c = pt(0.5, 0.5)
        let r = sqrt(w * w + h * h) / 2
        ctx.drawRadialGradient(gradient([RGB.black.cg(0), RGB.black.cg(0), RGB.black.cg(strength)], [0, 0.6, 1]),
                               startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [.drawsAfterEndLocation])
    }

    /// Fine film grain (fixed noise tile) keeps the long gradients from banding.
    private func grain(_ ctx: CGContext) {
        let n = 128
        var rng = SplitMix64(0xC001_D0C4)
        var bytes = [UInt8](repeating: 0, count: n * n)
        for i in 0..<bytes.count { bytes[i] = UInt8(truncatingIfNeeded: 128 + Int(rng.range(-1, 1) * 64)) }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let tile = CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: n, space: CGColorSpaceCreateDeviceGray(),
                                 bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil,
                                 shouldInterpolate: false, intent: .defaultIntent) else { return }
        ctx.saveGState()
        ctx.setAlpha(0.07)
        ctx.setBlendMode(.overlay)
        ctx.interpolationQuality = .none
        let side = CGFloat(n) * CGFloat(max(1, u))
        ctx.draw(tile, in: CGRect(x: 0, y: 0, width: side, height: side), byTiling: true)
        ctx.restoreGState()
    }
}

// MARK: - Files and desktop

enum WallpaperStudio {
    struct Output: Equatable {
        let url: URL
        let width: Int
        let height: Int
    }

    /// Pixel size of the main display (the one with the menu bar). No window server UI, no permission prompt.
    static func mainDisplayPixelSize() -> (width: Int, height: Int) {
        let id = CGMainDisplayID()
        if let mode = CGDisplayCopyDisplayMode(id), mode.pixelWidth > 0, mode.pixelHeight > 0 {
            return (mode.pixelWidth, mode.pixelHeight)
        }
        let w = CGDisplayPixelsWide(id), h = CGDisplayPixelsHigh(id)
        return w > 0 && h > 0 ? (w, h) : (2880, 1800)
    }

    /// Renders (or reuses the identical earlier render) and saves a JPEG under `directory`.
    static func generate(_ request: WallpaperRequest, width: Int, height: Int, directory: URL = AppPaths.wallpapers, keep: Int = 24) throws -> Output {
        guard (16...16384).contains(width), (16...16384).contains(height) else {
            throw ToolFailure("Wallpaper size \(width)×\(height) is out of range.")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(request.fileStem)-\(width)x\(height).jpg")
        if !fm.fileExists(atPath: url.path) {
            guard let image = WallpaperRenderer(request: request, width: width, height: height).render() else {
                throw ToolFailure("Couldn't paint the wallpaper.")
            }
            let temp = directory.appendingPathComponent(".\(UUID().uuidString).jpg")
            guard let dest = CGImageDestinationCreateWithURL(temp as CFURL, "public.jpeg" as CFString, 1, nil) else {
                throw ToolFailure("Couldn't write to \(directory.path).")
            }
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.93] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { throw ToolFailure("Couldn't save the wallpaper.") }
            _ = try? fm.removeItem(at: url)
            try fm.moveItem(at: temp, to: url)
        } else {
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        }
        prune(directory, keep: keep, except: url)
        return Output(url: url, width: width, height: height)
    }

    /// Keeps the newest `keep` generated wallpapers.
    static func prune(_ directory: URL, keep: Int, except: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let generated = items.filter { $0.lastPathComponent.hasPrefix("cooldock-") && $0.pathExtension == "jpg" && $0.lastPathComponent != except.lastPathComponent }
        let dated = generated.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for (url, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(max(0, keep - 1)) { try? fm.removeItem(at: url) }
    }
}
