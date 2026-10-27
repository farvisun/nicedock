import AppKit
import IOKit
import Observation
import SwiftUI

/// One Bluetooth peripheral that reports a battery level.
struct SysPeripheral: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let percent: Int
    let symbol: String
}

/// Battery levels of keyboards, mice, trackpads and headphones.
/// Reads the HID registry (`AppleDeviceManagementHIDEventService`) and, for audio devices such as AirPods,
/// the Bluetooth report from `system_profiler`. Refreshed every 5 minutes only while a tile is visible.
@Observable
@MainActor
final class SysDeviceBatteryService {
    static let shared = SysDeviceBatteryService()
    private(set) var devices: [SysPeripheral] = []
    private(set) var loaded = false
    @ObservationIgnored private var inFlight = false

    func refresh() async {
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }
        let skipProfiler = CommandLine.arguments.contains("--render")
        let list = await Task.detached(priority: .utility) { () -> [SysPeripheral] in
            let hid = SysDeviceBatteryService.readHID()
            return skipProfiler ? hid : SysDeviceBatteryService.merged(hid: hid, profiler: SysDeviceBatteryService.readProfiler())
        }.value
        if list != devices { devices = list }
        loaded = true
    }

    nonisolated static func readHID() -> [SysPeripheral] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var out: [SysPeripheral] = []
        var seen = Set<String>()
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            let device = peripheral { key in
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard let device, seen.insert(device.id).inserted else { continue }
            out.append(device)
        }
        return out
    }

    /// One `AppleDeviceManagementHIDEventService` entry, read through `prop` (registry key → value). Nil without a
    /// battery level above 0. Keyed by serial number, else Bluetooth address, else name.
    nonisolated static func peripheral(_ prop: (String) -> Any?) -> SysPeripheral? {
        guard let percent = (prop("BatteryPercent") as? NSNumber)?.intValue, percent > 0 else { return nil }
        let name = (prop("Product") as? String) ?? "Device"
        let key = (prop("SerialNumber") as? String) ?? (prop("DeviceAddress") as? String) ?? name
        return SysPeripheral(id: key, name: name, percent: min(100, percent), symbol: symbol(for: name, minor: nil))
    }

    /// HID devices first, then Bluetooth devices the HID registry didn't already list (same name, any case).
    nonisolated static func merged(hid: [SysPeripheral], profiler: [SysPeripheral]) -> [SysPeripheral] {
        let known = Set(hid.map { $0.name.lowercased() })
        return hid + profiler.filter { !known.contains($0.name.lowercased()) }
    }

    /// Connected Bluetooth devices with battery fields (AirPods report left/right/case).
    nonisolated static func readProfiler() -> [SysPeripheral] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        proc.arguments = ["SPBluetoothDataType", "-json", "-detailLevel", "basic"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return parseProfiler(data)
    }

    /// `system_profiler SPBluetoothDataType -json` output → connected devices that report a battery level. With
    /// several levels (AirPods left / right / case) the lowest earbud counts; the case is ignored.
    nonisolated static func parseProfiler(_ data: Data) -> [SysPeripheral] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        var out: [SysPeripheral] = []
        for section in sections {
            guard let connected = section["device_connected"] as? [[String: Any]] else { continue }
            for entry in connected {
                for (name, value) in entry {
                    guard let info = value as? [String: Any] else { continue }
                    let levels = ["device_batteryLevelMain", "device_batteryLevelLeft", "device_batteryLevelRight", "device_batteryLevel"]
                        .compactMap { (info[$0] as? String).flatMap { Int($0.filter(\.isNumber)) } }
                    guard let level = levels.min() else { continue }
                    let id = (info["device_address"] as? String) ?? name
                    out.append(SysPeripheral(id: id, name: name, percent: level, symbol: symbol(for: name, minor: info["device_minorType"] as? String)))
                }
            }
        }
        return out
    }

    nonisolated static func symbol(for name: String, minor: String?) -> String {
        let n = name.lowercased()
        if n.contains("keyboard") { return "keyboard" }
        if n.contains("trackpad") { return "rectangle.and.hand.point.up.left" }
        if n.contains("mouse") { return "magicmouse" }
        if n.contains("airpods max") { return "airpodsmax" }
        if n.contains("airpods pro") { return "airpodspro" }
        if n.contains("airpods") { return "airpods" }
        if n.contains("beats") { return "beats.headphones" }
        if n.contains("controller") || n.contains("dualsense") || n.contains("xbox") { return "gamecontroller" }
        if n.contains("pencil") { return "applepencil" }
        switch minor?.lowercased() {
        case "headphones", "headset": return "headphones"
        case "speaker": return "hifispeaker"
        case "keyboard": return "keyboard"
        case "mouse": return "magicmouse"
        default: return "dot.radiowaves.left.and.right"
        }
    }
}

struct SysDevicesBatteryView: View {
    let w: WidgetInstance
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    private var service: SysDeviceBatteryService { .shared }

    var body: some View {
        let devices = Array(service.devices.prefix(3))
        Tile(width: w.kind.spec.width, padding: .hv(11, 6)) {
            if devices.isEmpty {
                HStack(spacing: m.u(8)) {
                    Image(systemName: "keyboard")
                        .font(.system(size: m.u(17), weight: .medium))
                        .foregroundStyle(p.tertiary)
                    Text(service.loaded ? L("No devices") : L("Devices")).dock(11, .semibold, p.tertiary)
                }
            } else {
                VStack(spacing: m.u(devices.count == 3 ? 3 : 6)) {
                    ForEach(devices) { d in row(d, compact: devices.count == 3) }
                }
            }
        }
        .help(service.devices.map { "\($0.name) \(Fmt.percent(Double($0.percent) / 100))" }.joined(separator: "\n"))
        .onTapGesture { Open.url("x-apple.systempreferences:com.apple.BluetoothSettings") }
        .task {
            while !Task.isCancelled {
                await service.refresh()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    private func row(_ d: SysPeripheral, compact: Bool) -> some View {
        let level = Double(d.percent) / 100
        let color: Color = d.percent <= 10 ? .cdRed : (d.percent <= 20 ? .cdOrange : .cdGreen)
        return HStack(spacing: m.u(6)) {
            Image(systemName: d.symbol)
                .font(.system(size: m.u(compact ? 10.5 : 12), weight: .semibold))
                .foregroundStyle(p.secondary)
                .frame(width: m.u(18))
            Text(verbatim: d.name).dock(compact ? 10 : 11, .medium, p.secondary)
                .truncationMode(.tail)
            Spacer(minLength: m.u(4))
            Text(verbatim: Fmt.percent(level)).dock(compact ? 11 : 12, .bold, mono: true)
            ZStack(alignment: .leading) {
                Capsule().fill(p.track)
                Capsule().fill(p.accent(color)).frame(width: m.u(18) * max(0.12, level))
            }
            .frame(width: m.u(18), height: m.u(compact ? 6 : 7))
            .environment(\.layoutDirection, .leftToRight)
        }
        .frame(height: m.u(compact ? 14 : 18))
    }
}
