import Darwin
import Foundation
import IOKit
import IOKit.ps
import Observation

/// Samples CPU, memory, network, disk and power. Runs only while at least one widget subscribes.
@Observable
@MainActor
final class SystemMonitor {
    static let shared = SystemMonitor()

    private(set) var cpu: Double = 0
    private(set) var cpuHistory: [Double] = Array(repeating: 0, count: 40)
    private(set) var memory: Double = 0
    private(set) var memoryUsedGB: Double = 0
    private(set) var memoryTotalGB: Double = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    private(set) var downRate: Double = 0
    private(set) var upRate: Double = 0
    private(set) var downHistory: [Double] = Array(repeating: 0, count: 40)
    private(set) var upHistory: [Double] = Array(repeating: 0, count: 40)
    private(set) var diskFreeGB: Double = 0
    private(set) var diskTotalGB: Double = 0
    private(set) var battery: Double = 1
    private(set) var charging = false
    private(set) var hasBattery = false
    private(set) var onAC = true
    private(set) var batteryTimeRemaining: Int?
    private(set) var thermal: ProcessInfo.ThermalState = .nominal
    private(set) var temperature: Double?

    @ObservationIgnored private var subscribers = Set<String>()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastTicks: [UInt64]?
    @ObservationIgnored private var lastNet: (rx: UInt64, tx: UInt64, t: TimeInterval)?
    @ObservationIgnored private var tickCount = 0

    func subscribe(_ id: String) {
        subscribers.insert(id)
        if timer == nil { startTimer() }
    }

    func unsubscribe(_ id: String) {
        subscribers.remove(id)
        if subscribers.isEmpty { timer?.invalidate(); timer = nil }
    }

    private func startTimer() {
        sample()
        let interval = max(1, AppStore.shared.settings.systemSampleInterval)
        let t = Timer(timeInterval: interval, repeats: true) { _ in MainActor.assumeIsolated { SystemMonitor.shared.sample() } }
        t.tolerance = interval * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func sample() {
        tickCount += 1
        sampleCPU()
        sampleMemory()
        sampleNetwork()
        if tickCount % 5 == 1 { samplePower() }
        if tickCount % 30 == 1 { sampleDisk() }
        thermal = ProcessInfo.processInfo.thermalState
        if tickCount % 3 == 1 { temperature = TemperatureSensors.cpuTemperature() }
    }

    // MARK: CPU

    private func sampleCPU() {
        var count: mach_msg_type_number_t = 0
        var info: processor_info_array_t?
        var cpus: natural_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpus, &info, &count) == KERN_SUCCESS, let info else { return }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(count) * MemoryLayout<integer_t>.stride)) }
        var ticks = [UInt64](repeating: 0, count: 4)
        for i in 0..<Int(cpus) {
            let base = Int(CPU_STATE_MAX) * i
            ticks[0] += UInt64(info[base + Int(CPU_STATE_USER)])
            ticks[1] += UInt64(info[base + Int(CPU_STATE_SYSTEM)])
            ticks[2] += UInt64(info[base + Int(CPU_STATE_IDLE)])
            ticks[3] += UInt64(info[base + Int(CPU_STATE_NICE)])
        }
        if let last = lastTicks {
            let user = Double(ticks[0] &- last[0]), sys = Double(ticks[1] &- last[1])
            let idle = Double(ticks[2] &- last[2]), nice = Double(ticks[3] &- last[3])
            let total = user + sys + idle + nice
            if total > 0 {
                let v = (user + sys + nice) / total
                cpu = v
                cpuHistory.removeFirst()
                cpuHistory.append(v)
            }
        }
        lastTicks = ticks
    }

    // MARK: Memory

    private func sampleMemory() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return }
        let page = Double(vm_kernel_page_size)
        let used = (Double(stats.active_count) + Double(stats.wire_count) + Double(stats.compressor_page_count)) * page
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        memoryUsedGB = used / 1_073_741_824
        memory = min(1, used / total)
    }

    // MARK: Network

    private func sampleNetwork() {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return }
        defer { freeifaddrs(ifaddr) }
        var rx: UInt64 = 0, tx: UInt64 = 0
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let flags = Int32(p.pointee.ifa_flags)
            if let addr = p.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK), (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0,
               let data = p.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) {
                let name = String(cString: p.pointee.ifa_name)
                if name.hasPrefix("en") || name.hasPrefix("pdp_ip") {
                    rx += UInt64(data.pointee.ifi_ibytes)
                    tx += UInt64(data.pointee.ifi_obytes)
                }
            }
            ptr = p.pointee.ifa_next
        }
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastNet, now > last.t {
            let dt = now - last.t
            downRate = rx >= last.rx ? Double(rx - last.rx) / dt : 0
            upRate = tx >= last.tx ? Double(tx - last.tx) / dt : 0
            downHistory.removeFirst(); downHistory.append(downRate)
            upHistory.removeFirst(); upHistory.append(upRate)
        }
        lastNet = (rx, tx, now)
    }

    // MARK: Disk

    /// "Important usage" capacity needs an XPC round-trip (~50 ms), so it runs off the main thread and rarely.
    private func sampleDisk() {
        DispatchQueue.global(qos: .utility).async {
            let url = URL(fileURLWithPath: "/")
            guard let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) else { return }
            let free = Double(v.volumeAvailableCapacityForImportantUsage ?? 0) / 1_000_000_000
            let total = Double(v.volumeTotalCapacity ?? 0) / 1_000_000_000
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let m = SystemMonitor.shared
                    if abs(m.diskFreeGB - free) > 0.05 { m.diskFreeGB = free }
                    if m.diskTotalGB != total { m.diskTotalGB = total }
                }
            }
        }
    }

    // MARK: Power

    private func samplePower() {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { hasBattery = false; return }
        hasBattery = false
        for src in list {
            guard let d = IOPSGetPowerSourceDescription(blob, src)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            hasBattery = true
            let cur = Double(d[kIOPSCurrentCapacityKey] as? Int ?? 0)
            let max = Double(d[kIOPSMaxCapacityKey] as? Int ?? 100)
            battery = max > 0 ? cur / max : 0
            charging = d[kIOPSIsChargingKey] as? Bool ?? false
            onAC = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let t = d[kIOPSTimeToEmptyKey] as? Int ?? -1
            batteryTimeRemaining = t > 0 ? t : nil
        }
    }
}

/// Reads die temperature through the HID event system (Apple Silicon). Returns nil when unavailable.
enum TemperatureSensors {
    private typealias ClientCreate = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatching = @convention(c) (AnyObject, CFDictionary) -> Int32
    private typealias CopyServices = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyEvent = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias GetFloat = @convention(c) (AnyObject, Int32) -> Double

    nonisolated(unsafe) private static var handle: UnsafeMutableRawPointer? = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)

    static func cpuTemperature() -> Double? {
        guard let h = handle,
              let c = dlsym(h, "IOHIDEventSystemClientCreate"),
              let m = dlsym(h, "IOHIDEventSystemClientSetMatching"),
              let s = dlsym(h, "IOHIDEventSystemClientCopyServices"),
              let e = dlsym(h, "IOHIDServiceClientCopyEvent"),
              let f = dlsym(h, "IOHIDEventGetFloatValue") else { return nil }
        let create = unsafeBitCast(c, to: ClientCreate.self)
        let setMatching = unsafeBitCast(m, to: SetMatching.self)
        let copyServices = unsafeBitCast(s, to: CopyServices.self)
        let copyEvent = unsafeBitCast(e, to: CopyEvent.self)
        let getFloat = unsafeBitCast(f, to: GetFloat.self)
        guard let client = create(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }
        let matching = ["PrimaryUsagePage": 0xFF00, "PrimaryUsage": 5] as CFDictionary
        _ = setMatching(client, matching)
        guard let services = copyServices(client)?.takeRetainedValue() as? [AnyObject], !services.isEmpty else { return nil }
        let kTemperatureEvent: Int64 = 15
        let field = Int32(kTemperatureEvent << 16)
        var values: [Double] = []
        for service in services {
            if let event = copyEvent(service, kTemperatureEvent, 0, 0)?.takeRetainedValue() {
                let v = getFloat(event, field)
                if v > 10 && v < 130 { values.append(v) }
            }
        }
        guard !values.isEmpty else { return nil }
        values.sort()
        // Upper quartile approximates the hottest CPU die sensors without single-sensor spikes.
        return values[min(values.count - 1, values.count * 3 / 4)]
    }
}
