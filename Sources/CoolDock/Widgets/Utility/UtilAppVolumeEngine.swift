import AppKit
import AudioToolbox
import CoreAudio
import Darwin

// Per-app volume through Core Audio process taps (macOS 14.2+).
//
// An app whose volume is below 100 % or muted gets a private tap on its audio processes (`CATapDescription`,
// stereo mixdown, `.muted`: the app's own output stops reaching the hardware) inside a private aggregate device
// whose main sub-device is the default output. The aggregate's IO block plays the tapped input back multiplied by
// the app's gain. At 100 % and unmuted there is no tap at all. This file holds the pure, testable parts (levels,
// gain math, the real-time render routine, the aggregate description, process grouping and the tap plan) and the
// tap object itself; `UtilAppVolumeService` decides when taps exist.

// MARK: - Levels & gain math

/// One app's volume (0…1, linear amplitude) and mute. Persisted by app key (bundle id, or the executable path for
/// tools without one) in `Settings.appVolumes`; only non-default levels are kept.
struct UtilAppVolumeLevel: Codable, Equatable {
    var volume: Double = 1
    var muted = false

    static let unity = UtilAppVolumeLevel()

    /// 100 % and not muted: nothing to do for this app (no tap).
    var isDefault: Bool { !muted && UtilAppVolumeMath.clamp(volume) >= UtilAppVolumeMath.unitySnap }
}

enum UtilAppVolumeMath {
    /// Slider values at or above this count as 100 % (so dragging to the end removes the tap).
    static let unitySnap = 0.995

    /// 0…1; NaN and infinities fall back to 100 % (never silence an app by accident).
    static func clamp(_ v: Double) -> Double { v.isFinite ? min(1, max(0, v)) : 1 }

    /// Clamped, with the last half percent at either end snapped to 0 / 100 %.
    static func snapped(_ v: Double) -> Double {
        let c = clamp(v)
        if c >= unitySnap { return 1 }
        if c <= 1 - unitySnap { return 0 }
        return c
    }

    /// Linear gain the IO block multiplies the tapped samples by.
    static func gain(_ level: UtilAppVolumeLevel) -> Float { level.muted ? 0 : Float(clamp(level.volume)) }

    static func needsTap(_ level: UtilAppVolumeLevel) -> Bool { !level.isDefault }
}

// MARK: - Real-time render

enum UtilAppVolumeDSP {
    /// Shared between the main thread and the HAL IO thread through one heap pointer (no locks): the main thread
    /// only stores `target` (an aligned 32-bit store) and resets the meters; the IO thread owns `current`.
    struct State {
        var target: Float
        var current: Float
        /// Debug meters: highest absolute input / output sample since the last reset.
        var inPeak: Float = 0
        var outPeak: Float = 0
        var cycles: UInt32 = 0
    }

    static func supports(_ f: AudioStreamBasicDescription) -> Bool {
        f.mFormatID == kAudioFormatLinearPCM && f.mFormatFlags & kAudioFormatFlagIsFloat != 0 && f.mBitsPerChannel == 32
    }

    /// Copies the tapped input to the output × gain. Real-time safe: no allocation, no locks, no Objective-C or
    /// reference counting, only pointer arithmetic over the buffer lists. Gain changes ramp across one buffer.
    /// Channel mapping: output channel k plays input channel k; a mono output gets (L + R) / 2; extra output channels
    /// and frames without input are silent.
    static func render(_ input: UnsafePointer<AudioBufferList>, _ output: UnsafeMutablePointer<AudioBufferList>,
                       _ s: UnsafeMutablePointer<State>) {
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outs = UnsafeMutableAudioBufferListPointer(output)
        let target = s.pointee.target
        let start = s.pointee.current
        let sample = MemoryLayout<Float>.size

        var inChannels = 0
        var frames = Int.max
        var inPeak: Float = 0
        for b in ins {
            let ch = Int(b.mNumberChannels)
            guard ch > 0, let d = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let n = Int(b.mDataByteSize) / (sample * ch)
            frames = min(frames, n)
            inChannels += ch
            for i in 0..<(n * ch) {
                let v = abs(d[i])
                if v > inPeak { inPeak = v }
            }
        }
        if inChannels == 0 { frames = 0 }

        var outChannels = 0
        for b in outs { outChannels += Int(b.mNumberChannels) }
        let mono = outChannels == 1 && inChannels >= 2

        var outPeak: Float = 0
        var base = 0
        for b in outs {
            let och = Int(b.mNumberChannels)
            defer { base += och }
            guard och > 0, let od = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let oFrames = Int(b.mDataByteSize) / (sample * och)
            let n = min(oFrames, frames)
            let step = n > 0 ? (target - start) / Float(n) : 0
            for j in 0..<och {
                if mono, let l = channel(ins, 0), let r = channel(ins, 1) {
                    var g = start
                    for f in 0..<n {
                        g += step
                        let v = (l.ptr[f * l.stride] + r.ptr[f * r.stride]) * 0.5 * g
                        od[f * och + j] = v
                        if abs(v) > outPeak { outPeak = abs(v) }
                    }
                } else if base + j < inChannels, let src = channel(ins, base + j) {
                    var g = start
                    for f in 0..<n {
                        g += step
                        let v = src.ptr[f * src.stride] * g
                        od[f * och + j] = v
                        if abs(v) > outPeak { outPeak = abs(v) }
                    }
                } else {
                    for f in 0..<n { od[f * och + j] = 0 }
                }
                for f in n..<oFrames { od[f * och + j] = 0 }
            }
        }
        s.pointee.current = target
        if inPeak > s.pointee.inPeak { s.pointee.inPeak = inPeak }
        if outPeak > s.pointee.outPeak { s.pointee.outPeak = outPeak }
        s.pointee.cycles &+= 1
    }

    /// First sample of global input channel `k` and the stride between its frames.
    @inline(__always)
    private static func channel(_ ins: UnsafeMutableAudioBufferListPointer, _ k: Int) -> (ptr: UnsafeMutablePointer<Float>, stride: Int)? {
        var base = 0
        for b in ins {
            let ch = Int(b.mNumberChannels)
            if k < base + ch, let d = b.mData?.assumingMemoryBound(to: Float.self) { return (d + (k - base), ch) }
            base += ch
        }
        return nil
    }
}

// MARK: - Aggregate device

enum UtilAppVolumeAggregate {
    /// UIDs of NiceDock's private aggregates (hidden from the Audio widget's output list).
    static let uidPrefix = "app.nicedock.appvolume."

    /// Private aggregate: the default output as its main (clock) sub-device plus one drift-compensated tap.
    static func description(outputUID: String, tapUID: String, uid: String) -> [String: Any] {
        [
            kAudioAggregateDeviceNameKey: "NiceDock App Volume",
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]]
        ]
    }
}

// MARK: - Processes → apps

/// One Core Audio process object (`kAudioHardwarePropertyProcessObjectList`).
struct UtilAudioProcess: Equatable {
    var object: AudioObjectID
    var pid: pid_t
    var bundleID: String
    var running: Bool
}

/// Who a process plays for: the app responsible for it (Safari for its WebKit GPU process, Chrome for its helpers).
struct UtilAudioIdentity: Equatable {
    var key: String
    var name: String
    var iconPath: String?
}

/// An app with one or more audio processes. `running` = at least one of them is producing output.
struct UtilAudioApp: Identifiable, Equatable {
    var id: String
    var name: String
    var iconPath: String?
    var processes: [AudioObjectID]
    var pids: [pid_t]
    var running: Bool
}

/// What the main thread knows about a tap it asked for.
struct UtilAppVolumeTapSnapshot: Equatable {
    var processes: [AudioObjectID]
    var gain: Float
    var running: Bool
}

enum UtilAppVolumeAction: Equatable {
    case create(key: String, processes: [AudioObjectID], gain: Float, running: Bool)
    case update(key: String, processes: [AudioObjectID])
    case gain(key: String, Float)
    case run(key: String, Bool)
    case destroy(key: String)
}

enum UtilAppVolumeModel {
    /// Process objects that appeared / disappeared since the last list.
    static func diff(old: Set<AudioObjectID>, new: [AudioObjectID]) -> (added: [AudioObjectID], removed: [AudioObjectID]) {
        let fresh = Set(new)
        return (new.filter { !old.contains($0) }, old.filter { !fresh.contains($0) }.sorted())
    }

    /// Groups processes by the app they belong to. `identity` returns nil for processes to skip (NiceDock itself).
    static func group(_ processes: [UtilAudioProcess], identity: (UtilAudioProcess) -> UtilAudioIdentity?) -> [UtilAudioApp] {
        var order: [String] = []
        var apps: [String: UtilAudioApp] = [:]
        for p in processes.sorted(by: { $0.object < $1.object }) {
            guard let who = identity(p) else { continue }
            if var app = apps[who.key] {
                app.processes.append(p.object)
                if !app.pids.contains(p.pid) { app.pids.append(p.pid) }
                app.running = app.running || p.running
                if app.iconPath == nil { app.iconPath = who.iconPath }
                apps[who.key] = app
            } else {
                order.append(who.key)
                apps[who.key] = UtilAudioApp(id: who.key, name: who.name, iconPath: who.iconPath, processes: [p.object], pids: [p.pid], running: p.running)
            }
        }
        return order.compactMap { apps[$0] }
    }

    /// The tap changes that make `taps` match `levels` for `apps` (every app with audio processes, playing or not:
    /// a paused app keeps its tap with IO stopped, so it resumes at its own volume without a full-volume blip).
    /// Destroys come first. `allowed` = false (permission denied) removes every tap; `blocked` keys never get one.
    static func plan(apps: [UtilAudioApp], levels: [String: UtilAppVolumeLevel], taps: [String: UtilAppVolumeTapSnapshot],
                     allowed: Bool, blocked: Set<String> = []) -> [UtilAppVolumeAction] {
        var wanted: [String: UtilAudioApp] = [:]
        if allowed {
            for app in apps where !app.processes.isEmpty && !blocked.contains(app.id) {
                if let level = levels[app.id], UtilAppVolumeMath.needsTap(level) { wanted[app.id] = app }
            }
        }
        var actions: [UtilAppVolumeAction] = taps.keys.sorted().filter { wanted[$0] == nil }.map { .destroy(key: $0) }
        for app in apps where wanted[app.id] != nil {
            let gain = UtilAppVolumeMath.gain(levels[app.id] ?? .unity)
            guard let tap = taps[app.id] else {
                actions.append(.create(key: app.id, processes: app.processes, gain: gain, running: app.running))
                continue
            }
            if tap.processes != app.processes { actions.append(.update(key: app.id, processes: app.processes)) }
            if tap.gain != gain { actions.append(.gain(key: app.id, gain)) }
            if tap.running != app.running { actions.append(.run(key: app.id, app.running)) }
        }
        return actions
    }
}

// MARK: - System lookups

enum UtilAudioProcessInfo {
    private typealias ResponsibleFunction = @convention(c) (pid_t) -> pid_t
    /// libquarantine's `responsibility_get_pid_responsible_for_pid` (what Activity Monitor groups by); nil if absent.
    private static let responsible: ResponsibleFunction? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: ResponsibleFunction.self)
    }()

    static func responsiblePID(_ pid: pid_t) -> pid_t {
        guard let responsible else { return pid }
        let r = responsible(pid)
        return r > 0 ? r : pid
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard n > 0 else { return nil }
        return buffer.withUnsafeBufferPointer { $0.baseAddress.map { String(cString: $0) } }
    }

    /// The app a process plays for. Never NiceDock itself: our own aggregate IO shows up as a playing process.
    @MainActor static func identity(pid: pid_t, bundleID: String) -> UtilAudioIdentity? {
        let own = getpid()
        guard pid > 0, pid != own else { return nil }
        for candidate in [responsiblePID(pid), pid] where candidate != own {
            if let app = NSRunningApplication(processIdentifier: candidate), let id = app.bundleIdentifier, !id.isEmpty {
                return UtilAudioIdentity(key: id, name: app.localizedName ?? id, iconPath: app.bundleURL?.path)
            }
        }
        let path = executablePath(pid)
        if !bundleID.isEmpty {
            return UtilAudioIdentity(key: bundleID, name: path.map { ($0 as NSString).lastPathComponent } ?? bundleID, iconPath: nil)
        }
        guard let path else { return nil }
        return UtilAudioIdentity(key: path, name: (path as NSString).lastPathComponent, iconPath: nil)
    }
}

/// macOS "System Audio Recording" (TCC service kTCCServiceAudioCapture). The public API has no status query, so this
/// asks TCC's preflight (read-only, never prompts); `.unknown` when it isn't available or not decided yet.
enum UtilAudioCapturePermission {
    enum Status { case granted, denied, unknown }

    static let settingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"

    private typealias PreflightFunction = @convention(c) (CFString, CFDictionary?) -> Int32
    private static let preflight: PreflightFunction? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW),
              let sym = dlsym(handle, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(sym, to: PreflightFunction.self)
    }()

    static func status() -> Status {
        guard let preflight else { return .unknown }
        switch preflight("kTCCServiceAudioCapture" as CFString, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .unknown
        }
    }
}

// MARK: - Tap

/// One app's process tap + private aggregate + IO proc. `setGain` and the meters may be used from any thread
/// (lock-free stores into `state`); every other method runs on `UtilAppVolumeService.queue`.
final class UtilAppVolumeTap: @unchecked Sendable {
    let key: String
    private let state: UnsafeMutablePointer<UtilAppVolumeDSP.State>

    private struct Resources {
        var tap: AudioObjectID
        var tapUID: String
        var aggregate: AudioObjectID
        var aggregateUID: String
        var proc: AudioDeviceIOProcID
    }

    private var resources: Resources?
    private var processes: [AudioObjectID] = []
    private var outputUID: String?
    private var wantsRun = false
    private var started = false

    init(key: String, gain: Float) {
        self.key = key
        state = .allocate(capacity: 1)
        state.initialize(to: UtilAppVolumeDSP.State(target: gain, current: gain))
    }

    deinit {
        teardown()
        state.deinitialize(count: 1)
        state.deallocate()
    }

    // MARK: Any thread

    func setGain(_ gain: Float) { state.pointee.target = gain }

    var meters: (input: Float, output: Float, cycles: UInt32) { (state.pointee.inPeak, state.pointee.outPeak, state.pointee.cycles) }

    func resetMeters() {
        state.pointee.inPeak = 0
        state.pointee.outPeak = 0
    }

    // MARK: Engine queue

    var isBuilt: Bool { resources != nil }
    var isStarted: Bool { started }
    var aggregateUID: String? { resources?.aggregateUID }
    var tapUID: String? { resources?.tapUID }

    /// Creates (or replaces) the tap and aggregate. A replacement is made before the old one is destroyed, and the old
    /// IO stops before the new one starts: both taps mute the app meanwhile, so there is no full-volume blip.
    @discardableResult
    func build(processes: [AudioObjectID], outputUID: String?, running: Bool? = nil) -> OSStatus {
        self.processes = processes
        self.outputUID = outputUID
        if let running { wantsRun = running }
        guard let outputUID else {
            teardown()
            return OSStatus(kAudioHardwareBadDeviceError)
        }
        let made = make(processes: processes, outputUID: outputUID)
        guard let fresh = made.resources else { return made.status }
        if let old = resources {
            if started { AudioDeviceStop(old.aggregate, old.proc) }
            started = false
            destroy(old)
        }
        resources = fresh
        if wantsRun { start() }
        return noErr
    }

    /// New process list for the same app (a browser spawned another audio helper).
    @discardableResult
    func update(processes: [AudioObjectID]) -> OSStatus { build(processes: processes, outputUID: outputUID) }

    /// The default output device changed (nil: there is none right now).
    @discardableResult
    func retarget(outputUID: String?) -> OSStatus { build(processes: processes, outputUID: outputUID) }

    /// IO runs only while the app is producing sound; a stopped tap still mutes the app.
    func setRunning(_ on: Bool) {
        wantsRun = on
        if on { start() } else { stop() }
    }

    func teardown() {
        stop()
        if let r = resources { destroy(r) }
        resources = nil
    }

    private func start() {
        guard let r = resources, !started else { return }
        started = AudioDeviceStart(r.aggregate, r.proc) == noErr
    }

    private func stop() {
        guard let r = resources, started else { return }
        AudioDeviceStop(r.aggregate, r.proc)
        started = false
    }

    private func make(processes: [AudioObjectID], outputUID: String) -> (resources: Resources?, status: OSStatus) {
        guard #available(macOS 14.2, *) else { return (nil, OSStatus(kAudioHardwareUnsupportedOperationError)) }
        guard !processes.isEmpty else { return (nil, OSStatus(kAudioHardwareIllegalOperationError)) }
        let desc = CATapDescription(stereoMixdownOfProcesses: processes)
        desc.name = "NiceDock App Volume"
        desc.muteBehavior = .muted
        desc.isPrivate = true
        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(desc, &tap)
        guard status == noErr else { return (nil, status) }
        let tapUID = desc.uuid.uuidString
        guard let format = UtilCA.get(tap, UtilCA.address(kAudioTapPropertyFormat), AudioStreamBasicDescription()),
              UtilAppVolumeDSP.supports(format) else {
            AudioHardwareDestroyProcessTap(tap)
            return (nil, OSStatus(kAudioHardwareUnsupportedOperationError))
        }

        let uid = UtilAppVolumeAggregate.uidPrefix + UUID().uuidString
        let dict = UtilAppVolumeAggregate.description(outputUID: outputUID, tapUID: tapUID, uid: uid)
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggregate)
        guard status == noErr else {
            AudioHardwareDestroyProcessTap(tap)
            return (nil, status)
        }
        guard Self.outputIsFloat(aggregate) else {
            AudioHardwareDestroyAggregateDevice(aggregate)
            AudioHardwareDestroyProcessTap(tap)
            return (nil, OSStatus(kAudioHardwareUnsupportedOperationError))
        }

        let shared = state
        var proc: AudioDeviceIOProcID?
        // nil queue: the block runs on the HAL's real-time IO thread.
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, nil) { _, input, _, output, _ in
            UtilAppVolumeDSP.render(input, output, shared)
        }
        guard status == noErr, let proc else {
            AudioHardwareDestroyAggregateDevice(aggregate)
            AudioHardwareDestroyProcessTap(tap)
            return (nil, status == noErr ? OSStatus(kAudioHardwareUnspecifiedError) : status)
        }
        return (Resources(tap: tap, tapUID: tapUID, aggregate: aggregate, aggregateUID: uid, proc: proc), noErr)
    }

    private func destroy(_ r: Resources) {
        AudioDeviceDestroyIOProcID(r.aggregate, r.proc)
        AudioHardwareDestroyAggregateDevice(r.aggregate)
        if #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(r.tap) }
    }

    /// Every output stream of the aggregate uses 32-bit float samples (what `render` writes).
    private static func outputIsFloat(_ device: AudioObjectID) -> Bool {
        var a = UtilCA.address(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &a, 0, nil, &size) == noErr, size > 0 else { return false }
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, &streams) == noErr else { return false }
        return streams.allSatisfy { stream in
            UtilCA.get(stream, UtilCA.address(kAudioStreamPropertyVirtualFormat), AudioStreamBasicDescription()).map(UtilAppVolumeDSP.supports) ?? false
        }
    }
}
