import AppKit
import SwiftUI

/// System family: rings, live graphs and peripheral batteries. All live values come from
/// `SystemMonitor.shared`, which only samples while one of these tiles (or the details panel) is on screen.
enum SystemWidgets {
    @MainActor @ViewBuilder
    static func view(_ w: WidgetInstance) -> some View {
        switch w.kind {
        case .batteryRing: SysBatteryRing(w: w)
        case .cpuRing: SysCPURing(w: w)
        case .memoryRing: SysMemoryRing(w: w)
        case .storageRing: SysStorageRing(w: w)
        case .temperatureRing: SysTemperatureRing(w: w)
        case .cpuGraph: SysCPUGraph(w: w)
        case .networkGraph: SysNetworkGraph(w: w)
        case .devicesBattery: SysDevicesBatteryView(w: w)
        default: Tile(width: w.kind.spec.width) { Text(w.kind.spec.localizedTitle).dock(11) }
        }
    }

    @MainActor @ViewBuilder
    static func menu(_ w: WidgetInstance) -> some View {
        if w.kind == .devicesBattery {
            Button(L("Refresh")) { Task { await SysDeviceBatteryService.shared.refresh() } }
            Button(L("Bluetooth Settings…")) { Open.url("x-apple.systempreferences:com.apple.BluetoothSettings") }
        } else {
            Button(L("Show Details")) { SysDetails.toggle(w) }
            Button(L("Open Activity Monitor")) { Open.bundle("com.apple.ActivityMonitor") }
        }
        Divider()
    }
}

// MARK: - Details panel entry

@MainActor
enum SysDetails {
    static func toggle(_ w: WidgetInstance) {
        Panels.shared.toggle(w.id) { SysDetailsPanel(focus: w.kind) }
    }
}

// MARK: - Ring tiles

/// Ring matching the reference frames: 42 pt centre-line diameter, 4 pt stroke, round caps.
struct SysRing<Center: View>: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    var value: Double
    var color: Color
    var gradient = false
    var glow = false
    var diameter: CGFloat = 42
    var lineWidth: CGFloat = 4
    @ViewBuilder var center: () -> Center

    var body: some View {
        let clamped = max(0, min(1, value))
        let accent = p.accent(color)
        // The reference rings brighten towards their left edge; the gradient stays horizontal on screen.
        let light = p.monochrome ? SysColor.lighten(accent, 0.22) : (SysTint.light(color) ?? SysColor.lighten(accent, 0.22))
        let style: AnyShapeStyle = gradient
            ? AnyShapeStyle(LinearGradient(stops: [.init(color: light, location: 0), .init(color: accent, location: 0.67)],
                                           startPoint: .leading, endPoint: .trailing))
            : AnyShapeStyle(accent)
        ZStack {
            Circle().stroke(p.track.opacity(0.85), lineWidth: m.u(lineWidth))
            Circle()
                .trim(from: 0, to: clamped)
                .rotation(.degrees(-90))
                .stroke(style, style: StrokeStyle(lineWidth: m.u(lineWidth), lineCap: .round))
                .shadow(color: glow ? accent.opacity(0.55) : .clear, radius: glow ? m.u(3) : 0)
            center()
        }
        .frame(width: m.u(diameter), height: m.u(diameter))
    }
}

/// 70 pt ring tile: glyph above a number (or a glyph alone).
struct SysRingTile<Glyph: View>: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    var value: Double
    var color: Color
    var label: String?
    var gradient = true
    var glow = false
    var width: CGFloat = 70
    /// Vertical offsets of glyph and number from the ring centre (they differ slightly per glyph in the reference).
    var glyphY: CGFloat = -8
    var labelY: CGFloat = 7.5
    var ringY: CGFloat = 0
    @ViewBuilder var glyph: () -> Glyph

    var body: some View {
        Tile(width: width) {
            SysRing(value: value, color: color, gradient: gradient, glow: glow) {
                ZStack {
                    glyph()
                        .foregroundStyle(p.accent(color))
                        .offset(y: m.u(label == nil ? 0 : glyphY))
                    if let label {
                        Text(verbatim: label)
                            .dock(12.25, .bold, mono: true)
                            .minimumScaleFactor(0.6)
                            .frame(width: m.u(34))
                            .offset(y: m.u(labelY))
                    }
                }
            }
            .offset(y: m.u(ringY))
        }
    }
}

private struct SysGlyph: View {
    @Environment(\.metrics) private var m
    var symbol: String
    var size: CGFloat = 11
    var body: some View {
        Image(systemName: symbol).font(.system(size: m.u(size), weight: .semibold))
    }
}

struct SysBatteryRing: View {
    let w: WidgetInstance
    private var mon: SystemMonitor { .shared }

    var body: some View {
        let level = mon.hasBattery ? mon.battery : 1
        let color: Color = !mon.hasBattery || mon.charging || mon.onAC ? SysTint.green : (level <= 0.1 ? .cdRed : (level <= 0.2 ? SysTint.orange : SysTint.green))
        SysRingTile(value: level, color: color, label: mon.hasBattery ? Fmt.int(Int((level * 100).rounded())) : L("AC"),
                    gradient: true, glow: true, labelY: 7.75) {
            SysGlyph(symbol: symbol(level), size: 11.5)
        }
        .onTapGesture { SysDetails.toggle(w) }
        .demand(SystemMonitor.shared)
    }

    private func symbol(_ level: Double) -> String {
        if !mon.hasBattery { return "powerplug.fill" }
        if mon.charging { return "bolt.fill" }
        if mon.onAC { return "powerplug.fill" }
        switch level {
        case ..<0.13: return "battery.0percent"
        case ..<0.38: return "battery.25percent"
        case ..<0.63: return "battery.50percent"
        case ..<0.88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

struct SysCPURing: View {
    let w: WidgetInstance
    private var mon: SystemMonitor { .shared }
    var body: some View {
        SysRingTile(value: mon.cpu, color: SysTint.cyan, label: Fmt.int(Int((mon.cpu * 100).rounded())), labelY: 7.4) {
            SysGlyph(symbol: "cpu", size: 11)
        }
        .onTapGesture { SysDetails.toggle(w) }
        .demand(SystemMonitor.shared)
    }
}

struct SysMemoryRing: View {
    let w: WidgetInstance
    private var mon: SystemMonitor { .shared }
    var body: some View {
        SysRingTile(value: mon.memory, color: SysTint.blue, label: Fmt.int(Int((mon.memory * 100).rounded())), glyphY: -7.5, labelY: 6.4) {
            SysGlyph(symbol: "memorychip", size: 11)
        }
        .onTapGesture { SysDetails.toggle(w) }
        .demand(SystemMonitor.shared)
    }
}

struct SysStorageRing: View {
    let w: WidgetInstance
    private var mon: SystemMonitor { .shared }
    var body: some View {
        let used = mon.diskTotalGB > 0 ? 1 - mon.diskFreeGB / mon.diskTotalGB : 0
        SysRingTile(value: used, color: SysTint.orange, label: Fmt.int(Int(mon.diskFreeGB.rounded())), glyphY: -7.75, labelY: 5.9, ringY: 0.5) {
            SysGlyph(symbol: "internaldrive.fill", size: 11)
        }
        .onTapGesture { SysDetails.toggle(w) }
        .demand(SystemMonitor.shared)
    }
}

struct SysTemperatureRing: View {
    let w: WidgetInstance
    private var mon: SystemMonitor { .shared }
    var body: some View {
        let t = mon.temperature
        let fraction = t.map { ($0 - 20) / 80 } ?? SysThermal.fraction(mon.thermal)
        let color: Color = t.map { $0 >= 85 ? .cdRed : ($0 >= 70 ? .cdOrange : .cdGreen) } ?? SysThermal.color(mon.thermal)
        let label = t.map { Fmt.temperature($0, unit: AppStore.shared.settings.temperatureUnit.resolved) } ?? SysThermal.shortLabel(mon.thermal)
        SysRingTile(value: fraction, color: color, label: label, gradient: true) {
            SysGlyph(symbol: "thermometer.medium", size: 12)
        }
        .onTapGesture { SysDetails.toggle(w) }
        .demand(SystemMonitor.shared)
    }
}

enum SysThermal {
    static func fraction(_ s: ProcessInfo.ThermalState) -> Double {
        switch s {
        case .nominal: return 0.25
        case .fair: return 0.5
        case .serious: return 0.75
        case .critical: return 1
        @unknown default: return 0.25
        }
    }
    static func color(_ s: ProcessInfo.ThermalState) -> Color {
        switch s {
        case .nominal: return .cdGreen
        case .fair: return .cdYellow
        case .serious: return .cdOrange
        case .critical: return .cdRed
        @unknown default: return .cdGreen
        }
    }
    static func shortLabel(_ s: ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal: return L("OK")
        case .fair: return L("Fair")
        case .serious: return L("High")
        case .critical: return L("Max")
        @unknown default: return L("OK")
        }
    }
    static func label(_ s: ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal: return L("Normal")
        case .fair: return L("Fair")
        case .serious: return L("Serious")
        case .critical: return L("Critical")
        @unknown default: return L("Normal")
        }
    }
}

enum SysColor {
    static func lighten(_ c: Color, _ amount: CGFloat) -> Color {
        let ns = NSColor(c).usingColorSpace(.sRGB) ?? .white
        return Color(nsColor: ns.blended(withFraction: amount, of: .white) ?? ns)
    }
}

// MARK: - Graphs

/// Autoscaled chart bounds: keep some headroom above the peak so lines never touch the top edge.
private func sysChartMax(_ values: [Double], floor minimum: Double) -> Double {
    max((values.max() ?? 0) * 1.18, minimum)
}

/// Graph line colours measured from the reference frames (the tints drawn at ≈ 95 % / 92 % opacity).
enum SysGraphColor {
    static let cyan = Color(red: 59 / 255, green: 203 / 255, blue: 244 / 255)
    static let indigo = Color(red: 102 / 255, green: 116 / 255, blue: 237 / 255)
}

/// The reference frames use the macOS 26 dark system tints, which differ from the shared accent palette.
enum SysTint {
    static let cyan = Color(red: 60 / 255, green: 211 / 255, blue: 254 / 255)
    static let blue = Color(red: 0, green: 145 / 255, blue: 1)
    static let orange = Color(red: 1, green: 146 / 255, blue: 48 / 255)
    static let green = Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255)
    static let indigo = Color(red: 109 / 255, green: 124 / 255, blue: 1)

    /// Left-edge colour of the ring gradients, measured per tint.
    static func light(_ c: Color) -> Color? {
        switch c {
        case green: return Color(red: 79 / 255, green: 222 / 255, blue: 116 / 255)
        case orange: return Color(red: 1, green: 176 / 255, blue: 93 / 255)
        case blue: return Color(red: 46 / 255, green: 175 / 255, blue: 1)
        default: return nil
        }
    }
}

/// Line + area chart drawn like the reference graphs: the line can fade towards the right edge,
/// the fill gradient spans the area's own bounds (peak → baseline) and the canvas clips the line caps.
private struct SysAreaChart: View {
    struct Series {
        var values: [Double]
        var color: Color
        var fill: Double = 0
        var fade: Double = 1
        var width: CGFloat = 2
    }

    @Environment(\.palette) private var p
    @Environment(\.metrics) private var m
    var series: [Series]
    var top: Double
    /// Top of the plot area inside the canvas (unrounded, so graphs can sit between pixel rows).
    var plotTop: CGFloat = 0
    var lineWidth: CGFloat = 2

    var body: some View {
        Canvas { ctx, size in
            let inset = m.u(lineWidth) * 0.375
            let span = max(top, 0.000_001)
            let y0 = m.u(plotTop), plotHeight = size.height - y0
            for s in series where s.values.count > 1 {
                let lw = m.u(s.width)
                let step = size.width / CGFloat(s.values.count - 1)
                let pts = s.values.enumerated().map { i, v in
                    CGPoint(x: CGFloat(i) * step, y: y0 + inset + (plotHeight - inset * 2) * (1 - CGFloat(min(max(v, 0), span) / span)))
                }
                let line = Path.smooth(pts)
                let accent = p.accent(s.color)
                if s.fill > 0 {
                    var area = line
                    area.addLine(to: CGPoint(x: size.width, y: size.height))
                    area.addLine(to: CGPoint(x: 0, y: size.height))
                    area.closeSubpath()
                    let peak = max(0, (pts.map(\.y).min() ?? 0) - inset)
                    let gradient = Gradient(stops: [
                        .init(color: accent.opacity(s.fill), location: 0),
                        .init(color: accent.opacity(s.fill * 0.34), location: 0.5),
                        .init(color: accent.opacity(0), location: 1)
                    ])
                    ctx.fill(area, with: .linearGradient(gradient, startPoint: CGPoint(x: 0, y: peak), endPoint: CGPoint(x: 0, y: size.height)))
                }
                let stroke: GraphicsContext.Shading = s.fade < 1
                    ? .linearGradient(Gradient(colors: [accent, accent.opacity(s.fade)]), startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0))
                    : .color(accent)
                ctx.stroke(line, with: stroke, style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))
            }
        }
        .clipped()
    }
}

/// Header row + chart shared by the CPU and network graphs.
private struct SysGraphLayout<Header: View>: View {
    @Environment(\.metrics) private var m
    var width: CGFloat
    var series: [SysAreaChart.Series]
    var top: Double
    /// Chart canvas top; the canvas always ends 6 pt above the tile bottom (the reference frames' baseline).
    var chartTop: CGFloat = 18.5
    @ViewBuilder var header: () -> Header

    var body: some View {
        Tile(width: width) {
            ZStack(alignment: .topLeading) {
                header()
                    .padding(.leading, m.u(6))
                    .padding(.trailing, m.u(6))
                    .frame(height: m.u(18))
                    .padding(.top, m.u(4))
                SysAreaChart(series: series, top: top, plotTop: chartTop)
                    .frame(height: m.u(56))
                    .padding(.horizontal, m.u(6))
                    .environment(\.layoutDirection, .leftToRight)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

struct SysCPUGraph: View {
    let w: WidgetInstance
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    private var mon: SystemMonitor { .shared }

    var body: some View {
        SysGraphLayout(width: w.kind.spec.width,
                       series: [.init(values: mon.cpuHistory, color: SysGraphColor.cyan, fill: 0.36, fade: 0.75)],
                       top: sysChartMax(mon.cpuHistory, floor: 0.08)) {
            HStack(spacing: m.u(3.5)) {
                Image(systemName: "cpu")
                    .font(.system(size: m.u(10), weight: .semibold))
                    .foregroundStyle(p.accent(SysTint.cyan))
                    .offset(y: m.u(0.5))
                Text(L("CPU")).dock(9, .semibold, p.secondary)
                Spacer(minLength: m.u(4))
                Text(verbatim: Fmt.percent(mon.cpu)).dock(11, .bold, mono: true)
            }
        }
        .onTapGesture { SysDetails.toggle(w) }
        .demand(SystemMonitor.shared)
    }
}

struct SysNetworkGraph: View {
    let w: WidgetInstance
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    private var mon: SystemMonitor { .shared }

    var body: some View {
        SysGraphLayout(width: w.kind.spec.width,
                       series: [.init(values: mon.downHistory, color: SysGraphColor.cyan, fill: 0.29),
                                .init(values: mon.upHistory, color: SysGraphColor.indigo, width: 1.85)],
                       top: sysChartMax(mon.downHistory + mon.upHistory, floor: 4_000), chartTop: 18.0) {
            HStack(spacing: m.u(2)) {
                Image(systemName: "arrow.down")
                    .font(.system(size: m.u(8), weight: .bold))
                    .foregroundStyle(p.accent(SysTint.cyan))
                Text(verbatim: Fmt.bytes(mon.downRate, perSecond: true, short: true)).dock(10.75, .bold, mono: true).lineLimit(1).minimumScaleFactor(0.7).offset(y: m.u(0.45))
                Spacer(minLength: m.u(4))
                Text(verbatim: Fmt.bytes(mon.upRate, perSecond: true, short: true)).dock(10.75, .bold, mono: true).lineLimit(1).minimumScaleFactor(0.7).offset(y: m.u(0.45))
                Image(systemName: "arrow.up")
                    .font(.system(size: m.u(8), weight: .bold))
                    .foregroundStyle(p.accent(SysTint.indigo))
            }
            .offset(y: m.u(0.5))
        }
        .onTapGesture { SysDetails.toggle(w) }
        .demand(SystemMonitor.shared)
    }
}
