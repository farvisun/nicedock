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
        let style: AnyShapeStyle = gradient
            ? AnyShapeStyle(LinearGradient(colors: [SysColor.lighten(accent, 0.22), accent], startPoint: .leading, endPoint: .trailing))
            : AnyShapeStyle(accent)
        ZStack {
            Circle().stroke(p.track, lineWidth: m.u(lineWidth))
            Circle()
                .trim(from: 0, to: clamped)
                .stroke(style, style: StrokeStyle(lineWidth: m.u(lineWidth), lineCap: .round))
                .rotationEffect(.degrees(-90))
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
    var gradient = false
    var glow = false
    var width: CGFloat = 70
    @ViewBuilder var glyph: () -> Glyph

    var body: some View {
        Tile(width: width) {
            SysRing(value: value, color: color, gradient: gradient, glow: glow) {
                ZStack {
                    glyph()
                        .foregroundStyle(p.accent(color))
                        .offset(y: m.u(label == nil ? 0 : -8))
                    if let label {
                        Text(verbatim: label)
                            .dock(13, .bold, mono: true)
                            .minimumScaleFactor(0.6)
                            .frame(width: m.u(34))
                            .offset(y: m.u(7.5))
                    }
                }
            }
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
        let color: Color = !mon.hasBattery || mon.charging || mon.onAC ? .cdGreen : (level <= 0.1 ? .cdRed : (level <= 0.2 ? .cdOrange : .cdGreen))
        SysRingTile(value: level, color: color, label: mon.hasBattery ? Fmt.int(Int((level * 100).rounded())) : L("AC"),
                    gradient: true, glow: true) {
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
        SysRingTile(value: mon.cpu, color: .cdCyan, label: Fmt.int(Int((mon.cpu * 100).rounded()))) {
            SysGlyph(symbol: "cpu", size: 12)
        }
        .onTapGesture { SysDetails.toggle(w) }
        .demand(SystemMonitor.shared)
    }
}

struct SysMemoryRing: View {
    let w: WidgetInstance
    private var mon: SystemMonitor { .shared }
    var body: some View {
        SysRingTile(value: mon.memory, color: .cdBlue, label: Fmt.int(Int((mon.memory * 100).rounded()))) {
            SysGlyph(symbol: "memorychip", size: 12)
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
        SysRingTile(value: used, color: .cdOrange, label: Fmt.int(Int(mon.diskFreeGB.rounded())), gradient: true) {
            SysGlyph(symbol: "internaldrive.fill", size: 11.5)
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

struct SysCPUGraph: View {
    let w: WidgetInstance
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    private var mon: SystemMonitor { .shared }

    var body: some View {
        Tile(width: w.kind.spec.width) {
            VStack(spacing: 0) {
                HStack(spacing: m.u(4)) {
                    Image(systemName: "cpu")
                        .font(.system(size: m.u(10), weight: .semibold))
                        .foregroundStyle(p.accent(.cdCyan))
                    Text(L("CPU")).dock(10, .semibold, p.secondary)
                    Spacer(minLength: m.u(4))
                    Text(verbatim: Fmt.percent(mon.cpu)).dock(12, .bold, mono: true)
                }
                .padding(.horizontal, m.u(7))
                .frame(height: m.u(18))
                .padding(.top, m.u(4))
                AreaSparkline(values: mon.cpuHistory, color: .cdCyan, lineWidth: m.u(2), fillOpacity: 0.3,
                              minValue: 0, maxValue: sysChartMax(mon.cpuHistory, floor: 0.08))
                    .frame(height: m.u(34))
                    .padding(.horizontal, m.u(6))
                    .environment(\.layoutDirection, .leftToRight)
                Spacer(minLength: 0)
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
        let top = sysChartMax(mon.downHistory + mon.upHistory, floor: 4_000)
        Tile(width: w.kind.spec.width) {
            VStack(spacing: 0) {
                HStack(spacing: m.u(3)) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: m.u(9.5), weight: .bold))
                        .foregroundStyle(p.accent(.cdCyan))
                    Text(verbatim: Fmt.bytes(mon.downRate, perSecond: true)).dock(12, .bold, mono: true)
                    Spacer(minLength: m.u(4))
                    Text(verbatim: Fmt.bytes(mon.upRate, perSecond: true)).dock(12, .bold, p.primary.opacity(0.82), mono: true)
                    Image(systemName: "arrow.up")
                        .font(.system(size: m.u(9.5), weight: .bold))
                        .foregroundStyle(p.accent(.cdIndigo))
                }
                .padding(.horizontal, m.u(7))
                .frame(height: m.u(18))
                .padding(.top, m.u(4))
                ZStack {
                    AreaSparkline(values: mon.downHistory, color: .cdCyan, lineWidth: m.u(2), fillOpacity: 0.3, minValue: 0, maxValue: top)
                    AreaSparkline(values: mon.upHistory, color: .cdIndigo, lineWidth: m.u(2), fillOpacity: 0, minValue: 0, maxValue: top)
                }
                .frame(height: m.u(34))
                .padding(.horizontal, m.u(6))
                .environment(\.layoutDirection, .leftToRight)
                Spacer(minLength: 0)
            }
        }
        .onTapGesture { SysDetails.toggle(w) }
        .demand(SystemMonitor.shared)
    }
}
