import AppKit
import IOKit
import SwiftUI

/// Pop-up panel shown when a system tile is clicked: CPU, memory, disk, network, power, thermals and top processes.
struct SysDetailsPanel: View {
    var focus: WidgetKind
    @Environment(\.palette) private var p
    @State private var procs: [SysProcess] = []
    @State private var health: SysBatteryHealth?
    @State private var lastFetch = Date.distantPast
    private var mon: SystemMonitor { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(title: L("System"), subtitle: SysHostInfo.subtitle) {
                Button { Open.bundle("com.apple.ActivityMonitor") } label: {
                    Image(systemName: "waveform.path.ecg.rectangle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(p.secondary)
                }
                .buttonStyle(.plain)
                .help(L("Open Activity Monitor"))
            }
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    cpuCard
                    memoryCard
                }
                GridRow {
                    diskCard
                    networkCard
                }
                GridRow {
                    powerCard
                    thermalCard
                }
            }
            if !procs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Top Processes")).font(.dock(11, .semibold)).foregroundStyle(p.secondary)
                    ForEach(procs) { proc in
                        HStack(spacing: 8) {
                            Text(verbatim: proc.name).font(.dock(12, .medium)).foregroundStyle(p.primary).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(verbatim: Fmt.bytes(proc.memory)).font(.dock(11, .medium, mono: true)).foregroundStyle(p.secondary)
                            Text(verbatim: Fmt.number(proc.cpu, decimals: 1) + Fmt.digits("%"))
                                .font(.dock(12, .bold, mono: true)).foregroundStyle(p.primary)
                                .frame(minWidth: 48, alignment: .trailing)
                        }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(p.control))
            }
        }
        .frame(width: 330)
        .demand(SystemMonitor.shared)
        .task {
            health = await SysBatteryHealth.read()
            await refreshProcesses()
        }
        .onChange(of: mon.cpuHistory) { _, _ in
            guard Date().timeIntervalSince(lastFetch) > 4 else { return }
            Task { await refreshProcesses() }
        }
    }

    private func refreshProcesses() async {
        lastFetch = Date()
        procs = await SysProcess.top(5)
    }

    // MARK: Cards

    private var cpuCard: some View {
        SysStatCard(symbol: "cpu", color: .cdCyan, title: L("CPU"), value: Fmt.percent(mon.cpu),
                    detail: L("%d cores", ProcessInfo.processInfo.activeProcessorCount), highlighted: focus == .cpuRing || focus == .cpuGraph) {
            AreaSparkline(values: mon.cpuHistory, color: .cdCyan, lineWidth: 1.5, fillOpacity: 0.3, minValue: 0, maxValue: max(mon.cpuHistory.max() ?? 0, 0.1) * 1.15)
        }
    }

    private var memoryCard: some View {
        SysStatCard(symbol: "memorychip", color: .cdBlue, title: L("Memory"), value: Fmt.percent(mon.memory),
                    detail: L("%@ of %@ GB", Fmt.number(mon.memoryUsedGB, decimals: 1), Fmt.number(mon.memoryTotalGB, decimals: 0)),
                    highlighted: focus == .memoryRing) {
            SysBar(value: mon.memory, color: .cdBlue)
        }
    }

    private var diskCard: some View {
        let used = mon.diskTotalGB > 0 ? 1 - mon.diskFreeGB / mon.diskTotalGB : 0
        return SysStatCard(symbol: "internaldrive.fill", color: .cdOrange, title: L("Storage"),
                           value: L("%@ GB", Fmt.int(Int(mon.diskFreeGB.rounded()))),
                           detail: L("free of %@ GB", Fmt.int(Int(mon.diskTotalGB.rounded()))), highlighted: focus == .storageRing) {
            SysBar(value: used, color: .cdOrange)
        }
    }

    private var networkCard: some View {
        let top = max((mon.downHistory + mon.upHistory).max() ?? 0, 4_000) * 1.15
        return SysStatCard(symbol: "arrow.up.arrow.down", color: .cdIndigo, title: L("Network"),
                           value: "↓ " + Fmt.bytes(mon.downRate, perSecond: true),
                           detail: "↑ " + Fmt.bytes(mon.upRate, perSecond: true), highlighted: focus == .networkGraph) {
            ZStack {
                AreaSparkline(values: mon.downHistory, color: .cdCyan, lineWidth: 1.5, fillOpacity: 0.3, minValue: 0, maxValue: top)
                AreaSparkline(values: mon.upHistory, color: .cdIndigo, lineWidth: 1.5, fillOpacity: 0, minValue: 0, maxValue: top)
            }
        }
    }

    @ViewBuilder private var powerCard: some View {
        if mon.hasBattery {
            SysStatCard(symbol: mon.charging ? "bolt.fill" : "battery.75percent", color: .cdGreen, title: L("Battery"),
                        value: Fmt.percent(mon.battery), detail: batteryDetail, highlighted: focus == .batteryRing) {
                SysBar(value: mon.battery, color: mon.battery <= 0.2 && !mon.onAC ? .cdOrange : .cdGreen)
            }
        } else {
            SysStatCard(symbol: "powerplug.fill", color: .cdGreen, title: L("Power"), value: L("AC"),
                        detail: L("No battery"), highlighted: focus == .batteryRing) { EmptyView() }
        }
    }

    private var batteryDetail: String {
        var parts: [String] = []
        if mon.charging {
            parts.append(L("Charging"))
        } else if mon.onAC {
            parts.append(L("On power adapter"))
        } else if let mins = mon.batteryTimeRemaining {
            parts.append(L("%@ left", Fmt.digits(String(format: "%d:%02d", mins / 60, mins % 60))))
        }
        if let health {
            parts.append(L("Health %@", Fmt.percent(health.health)))
            if health.cycles > 0 { parts.append(L("%@ cycles", Fmt.int(health.cycles))) }
        }
        return parts.joined(separator: " · ")
    }

    private var thermalCard: some View {
        let t = mon.temperature
        let value = t.map { Fmt.temperature($0, unit: AppStore.shared.settings.temperatureUnit.resolved) } ?? SysThermal.label(mon.thermal)
        return SysStatCard(symbol: "thermometer.medium", color: t.map { $0 >= 85 ? .cdRed : ($0 >= 70 ? .cdOrange : .cdGreen) } ?? SysThermal.color(mon.thermal),
                           title: L("Temperature"), value: value,
                           detail: L("Thermal state: %@", SysThermal.label(mon.thermal)), highlighted: focus == .temperatureRing) {
            SysBar(value: t.map { ($0 - 20) / 80 } ?? SysThermal.fraction(mon.thermal),
                   color: t.map { $0 >= 85 ? .cdRed : ($0 >= 70 ? .cdOrange : .cdGreen) } ?? SysThermal.color(mon.thermal))
        }
    }
}

private struct SysStatCard<Chart: View>: View {
    @Environment(\.palette) private var p
    var symbol: String
    var color: Color
    var title: String
    var value: String
    var detail: String
    var highlighted: Bool
    @ViewBuilder var chart: () -> Chart

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(p.accent(color))
                Text(title).font(.dock(11, .semibold)).foregroundStyle(p.secondary)
            }
            Text(verbatim: value).font(.dock(19, .bold, mono: true)).foregroundStyle(p.primary).lineLimit(1).minimumScaleFactor(0.7)
            Text(verbatim: detail).font(.dock(10, .medium)).foregroundStyle(p.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            chart()
                .frame(height: 20)
                .environment(\.layoutDirection, .leftToRight)
        }
        .padding(10)
        .frame(width: 157, height: 108, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(p.control))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(highlighted ? p.accent(color).opacity(0.7) : p.tileStroke, lineWidth: highlighted ? 1.5 : 0.5))
    }
}

private struct SysBar: View {
    @Environment(\.palette) private var p
    var value: Double
    var color: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(p.track)
                Capsule().fill(p.accent(color)).frame(width: max(6, g.size.width * max(0, min(1, value))))
            }
        }
        .frame(height: 6)
        .frame(maxHeight: .infinity, alignment: .bottom)
    }
}

// MARK: - Data helpers

enum SysHostInfo {
    static let subtitle: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let name = Host.current().localizedName ?? "Mac"
        return name + " · macOS " + Fmt.digits("\(v.majorVersion).\(v.minorVersion)")
    }()
}

struct SysProcess: Identifiable, Sendable {
    var id: String { name + "\(pid)" }
    let pid: Int
    let name: String
    let cpu: Double
    let memory: Double

    /// Top processes by CPU from `ps` (spawned off the main thread, only while the panel is open).
    static func top(_ n: Int) async -> [SysProcess] {
        await Task.detached(priority: .utility) { () -> [SysProcess] in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/ps")
            proc.arguments = ["-Aceo", "pid=,pcpu=,rss=,comm=", "-r"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice
            do { try proc.run() } catch { return [] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard let text = String(data: data, encoding: .utf8) else { return [] }
            var out: [SysProcess] = []
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
                guard parts.count == 4, let pid = Int(parts[0]), let cpu = Double(parts[1]), let rss = Double(parts[2]) else { continue }
                out.append(SysProcess(pid: pid, name: String(parts[3]), cpu: cpu, memory: rss * 1024))
                if out.count >= n { break }
            }
            return out
        }.value
    }
}

struct SysBatteryHealth: Sendable {
    let health: Double
    let cycles: Int

    /// Reads design vs. current full-charge capacity from the smart battery service.
    static func read() async -> SysBatteryHealth? {
        await Task.detached(priority: .utility) { () -> SysBatteryHealth? in
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
            guard service != 0 else { return nil }
            defer { IOObjectRelease(service) }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any] else { return nil }
            let design = (dict["DesignCapacity"] as? Int) ?? 0
            let maxCap = (dict["AppleRawMaxCapacity"] as? Int) ?? (dict["NominalChargeCapacity"] as? Int) ?? (dict["MaxCapacity"] as? Int) ?? 0
            let cycles = (dict["CycleCount"] as? Int) ?? 0
            guard design > 0, maxCap > 0 else { return nil }
            return SysBatteryHealth(health: min(1, Double(maxCap) / Double(design)), cycles: cycles)
        }.value
    }
}
