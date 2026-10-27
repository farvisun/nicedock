import AppKit
import CoreAudio
import Observation

// MARK: - Storage

/// Where per-app levels persist. The app uses `Settings` (saved with the rest of `state.json`); tests use memory.
@MainActor
protocol UtilAppVolumeStorage: AnyObject {
    var remember: Bool { get set }
    func load() -> [String: UtilAppVolumeLevel]
    func save(_ levels: [String: UtilAppVolumeLevel])
}

@MainActor
final class UtilAppVolumeSettingsStorage: UtilAppVolumeStorage {
    var remember: Bool {
        get { AppStore.shared.settings.remembersAppVolumes }
        set { if AppStore.shared.settings.remembersAppVolumes != newValue { AppStore.shared.settings.remembersAppVolumes = newValue } }
    }

    func load() -> [String: UtilAppVolumeLevel] { AppStore.shared.settings.appVolumes ?? [:] }

    func save(_ levels: [String: UtilAppVolumeLevel]) {
        // Developer renders and tests never write the user's state.
        guard AppStore.persistenceEnabled else { return }
        let value = levels.isEmpty ? nil : levels
        if AppStore.shared.settings.appVolumes != value { AppStore.shared.settings.appVolumes = value }
    }
}

@MainActor
final class UtilAppVolumeMemoryStorage: UtilAppVolumeStorage {
    var remember = true
    private(set) var saved: [String: UtilAppVolumeLevel] = [:]
    private(set) var saves = 0

    init(_ saved: [String: UtilAppVolumeLevel] = [:]) { self.saved = saved }

    func load() -> [String: UtilAppVolumeLevel] { saved }
    func save(_ levels: [String: UtilAppVolumeLevel]) {
        saved = levels
        saves += 1
    }
}

// MARK: - Service

/// Per-app volume and mute (macOS 14.2+). Lists the apps producing sound from Core Audio's process objects and keeps
/// one process tap per app whose volume is below 100 % or muted (`UtilAppVolumeTap`). Event-driven only: listeners on
/// the process list, each process's IsRunningOutput and the default output device; no timers.
///
/// The listeners run while an App Volume view is on screen or while any app has a non-default level (its tap has to
/// follow the app). Tap work (create, start, stop, destroy) runs on `queue`, off the main thread.
@Observable
@MainActor
final class UtilAppVolumeService: DemandDriven {
    static let shared = UtilAppVolumeService(storage: UtilAppVolumeSettingsStorage(), monitor: !ReferenceScene.isActive,
                                             taps: !RenderHarness.isActive, observeSettings: true)

    nonisolated static let queue = DispatchQueue(label: "app.cooldock.app-volume", qos: .userInitiated)

    /// Process taps exist from macOS 14.2; before that the widget and the Audio panel section are hidden.
    nonisolated static var supported: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    /// Apps producing sound right now; the one that started most recently first.
    private(set) var apps: [UtilAudioApp] = []
    private(set) var levels: [String: UtilAppVolumeLevel] = [:]
    /// System Audio Recording was denied: no taps, sliders disabled, a hint explains how to allow it.
    private(set) var permissionDenied = false
    /// A tap has been waiting on Core Audio for over a second: the first one of a session waits there until the user
    /// answers macOS's System Audio Recording prompt (the app stays muted meanwhile), so the views point at it.
    private(set) var awaitingPermission = false
    /// Apps whose tap could not be created this session (slider disabled).
    private(set) var failed: Set<String> = []
    /// Apps whose tap is built (the app plays through NiceDock).
    private(set) var tapped: Set<String> = []
    private(set) var remember: Bool

    let isSupported: Bool

    @ObservationIgnored private let storage: UtilAppVolumeStorage
    @ObservationIgnored private let monitorAllowed: Bool
    @ObservationIgnored private let tapsAllowed: Bool
    @ObservationIgnored var saveDelay: TimeInterval = 0.6
    @ObservationIgnored private var sceneMode = false
    @ObservationIgnored private var subscribers = Set<String>()
    @ObservationIgnored private var listening = false
    @ObservationIgnored private var processes: [AudioObjectID: UtilAudioProcess] = [:]
    @ObservationIgnored private var identities: [AudioObjectID: UtilAudioIdentity] = [:]
    @ObservationIgnored private(set) var allApps: [UtilAudioApp] = []
    @ObservationIgnored private var since: [String: Date] = [:]
    @ObservationIgnored private var taps: [String: UtilAppVolumeTap] = [:]
    @ObservationIgnored private var snapshots: [String: UtilAppVolumeTapSnapshot] = [:]
    @ObservationIgnored private var outputUID: String?
    @ObservationIgnored private var systemBlocks: [(AudioObjectPropertySelector, AudioObjectPropertyListenerBlock)] = []
    @ObservationIgnored private var runningBlocks: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private var lastSaved: [String: UtilAppVolumeLevel] = [:]
    @ObservationIgnored private var permissionChecks = 0
    @ObservationIgnored private var buildsInFlight = 0
    @ObservationIgnored private var isShutDown = false
    @ObservationIgnored private var settingsObserver: NSObjectProtocol?

    /// `monitor`: may read Core Audio's process list. `taps`: may create taps (never in developer renders).
    init(storage: UtilAppVolumeStorage, monitor: Bool = true, taps: Bool = true, observeSettings: Bool = false) {
        self.storage = storage
        isSupported = Self.supported
        monitorAllowed = monitor
        tapsAllowed = taps
        remember = storage.remember
        levels = storage.load().filter { !$0.value.isDefault }
        lastSaved = levels
        if observeSettings {
            settingsObserver = NotificationCenter.default.addObserver(forName: .coolDockSettingsChanged, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncFromStorage() }
            }
        }
    }

    // MARK: Reading

    func level(_ key: String) -> UtilAppVolumeLevel { levels[key] ?? .unity }

    /// The slider can change this app (supported, allowed, its tap didn't fail).
    func canControl(_ key: String) -> Bool { isSupported && !permissionDenied && !failed.contains(key) }

    /// Apps with a changed volume or mute (Settings → Reset All).
    var changedCount: Int { levels.count }

    func hasTap(_ key: String) -> Bool { taps[key] != nil }

    // MARK: Changing

    func setVolume(_ value: Double, for key: String) {
        guard canControl(key) else { return }
        var level = self.level(key)
        level.volume = UtilAppVolumeMath.snapped(value)
        if level.muted && level.volume > 0 { level.muted = false }
        store(level, for: key)
    }

    func setMuted(_ on: Bool, for key: String) {
        guard canControl(key) else { return }
        var level = self.level(key)
        level.muted = on
        // Unmuting at 0 % would stay silent: come back at full volume instead.
        if !on && level.volume <= 0 { level.volume = 1 }
        store(level, for: key)
    }

    func toggleMute(_ key: String) { setMuted(!level(key).muted, for: key) }

    /// Every app back to 100 % and unmuted; removes all taps.
    func resetAll() {
        levels.removeAll()
        failed.removeAll()
        saveNow()
        reconcile()
        updateActivation()
    }

    func setRemember(_ on: Bool) {
        storage.remember = on
        remember = on
        if on {
            saveNow()
        } else {
            saveWork?.cancel()
            saveWork = nil
            lastSaved = [:]
            storage.save([:])
        }
    }

    private func store(_ level: UtilAppVolumeLevel, for key: String) {
        if level.isDefault { levels[key] = nil } else { levels[key] = level }
        scheduleSave()
        updateActivation()
        reconcile()
    }

    // MARK: Persistence

    private func scheduleSave() {
        guard remember else { return }
        saveWork?.cancel()
        guard saveDelay > 0 else { saveNow(); return }
        // Slider drags change the level many times a second; Settings (and its observers) see the final value only.
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.saveNow() } }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDelay, execute: work)
    }

    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        guard remember else { return }
        lastSaved = levels
        storage.save(levels)
    }

    /// Settings changed elsewhere (Reset NiceDock, another profile import): follow the stored levels.
    private func syncFromStorage() {
        if storage.remember != remember { remember = storage.remember }
        guard remember, saveWork == nil else { return }
        let stored = storage.load().filter { !$0.value.isDefault }
        guard stored != lastSaved else { return }
        lastSaved = stored
        levels = stored
        reconcile()
        updateActivation()
    }

    // MARK: Demand

    func subscribe(_ id: String) {
        guard !sceneMode else { return }
        subscribers.insert(id)
        refreshPermission()
        updateActivation()
    }

    func unsubscribe(_ id: String) {
        subscribers.remove(id)
        updateActivation()
    }

    /// At launch: starts following apps when remembered levels exist.
    func bootstrap() { updateActivation() }

    /// At quit: removes every tap and aggregate and stops listening. Waits at most `timeout` for the engine queue:
    /// the first IO proc of a session can sit in Core Audio until the user answers the System Audio Recording prompt,
    /// and quitting must not hang on that (private taps and aggregates end with the process anyway).
    @discardableResult
    func shutdown(timeout: TimeInterval = 1.5) -> Bool {
        saveNow()
        isShutDown = true
        let all = Array(taps.values)
        taps.removeAll()
        snapshots.removeAll()
        tapped.removeAll()
        let done = DispatchGroup()
        Self.queue.async(group: done) { all.forEach { $0.teardown() } }
        let finished = done.wait(timeout: .now() + timeout) == .success
        stopListening()
        return finished
    }

    private var needsEngine: Bool {
        isSupported && monitorAllowed && !sceneMode && !isShutDown && (!subscribers.isEmpty || levels.values.contains(where: UtilAppVolumeMath.needsTap))
    }

    private func updateActivation() {
        if needsEngine, !listening { startListening() } else if !needsEngine, listening { stopListening() }
    }

    // MARK: Core Audio listeners

    private func startListening() {
        listening = true
        let list: AudioObjectPropertyListenerBlock = { [weak self] _, _ in MainActor.assumeIsolated { self?.reloadProcesses() } }
        let output: AudioObjectPropertyListenerBlock = { [weak self] _, _ in MainActor.assumeIsolated { self?.outputChanged() } }
        for (selector, block) in [(kAudioHardwarePropertyProcessObjectList, list), (kAudioHardwarePropertyDefaultOutputDevice, output)] {
            var a = UtilCA.address(selector)
            if AudioObjectAddPropertyListenerBlock(UtilCA.system, &a, DispatchQueue.main, block) == noErr { systemBlocks.append((selector, block)) }
        }
        outputUID = Self.defaultOutputUID()
        reloadProcesses()
    }

    private func stopListening() {
        listening = false
        for (selector, block) in systemBlocks {
            var a = UtilCA.address(selector)
            AudioObjectRemovePropertyListenerBlock(UtilCA.system, &a, DispatchQueue.main, block)
        }
        systemBlocks.removeAll()
        for id in Array(runningBlocks.keys) { removeRunningListener(id) }
        processes.removeAll()
        identities.removeAll()
        allApps = []
        since.removeAll()
        if !apps.isEmpty { apps = [] }
    }

    /// IsRunningOutput is read on every notification, but on macOS 27 only IsRunning posts change notifications
    /// (IsRunningOutput never does), so both are observed.
    private static let runningSelectors = [kAudioProcessPropertyIsRunning, kAudioProcessPropertyIsRunningOutput]

    private func addRunningListener(_ id: AudioObjectID) {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in MainActor.assumeIsolated { self?.runningChanged(id) } }
        var added = false
        for selector in Self.runningSelectors {
            var a = UtilCA.address(selector)
            if AudioObjectAddPropertyListenerBlock(id, &a, DispatchQueue.main, block) == noErr { added = true }
        }
        if added { runningBlocks[id] = block }
    }

    private func removeRunningListener(_ id: AudioObjectID) {
        guard let block = runningBlocks.removeValue(forKey: id) else { return }
        for selector in Self.runningSelectors {
            var a = UtilCA.address(selector)
            AudioObjectRemovePropertyListenerBlock(id, &a, DispatchQueue.main, block)
        }
    }

    func reloadProcesses() {
        guard listening else { return }
        let ids = Self.processObjectIDs()
        let change = UtilAppVolumeModel.diff(old: Set(processes.keys), new: ids)
        for id in change.removed {
            removeRunningListener(id)
            processes[id] = nil
            identities[id] = nil
        }
        for id in change.added {
            guard let p = Self.readProcess(id) else { continue }
            processes[id] = p
            // NiceDock's own process (our aggregate IO) has no identity and needs no listener.
            guard let who = UtilAudioProcessInfo.identity(pid: p.pid, bundleID: p.bundleID) else { continue }
            identities[id] = who
            addRunningListener(id)
        }
        regroup()
    }

    private func runningChanged(_ id: AudioObjectID, recheck: Bool = true) {
        guard var p = processes[id] else { return }
        let running = Self.isRunningOutput(id)
        // IO started but the output stream isn't active yet: look once more in a moment (not a poll).
        if recheck, !running, (UtilCA.get(id, UtilCA.address(kAudioProcessPropertyIsRunning), UInt32(0)) ?? 0) != 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                MainActor.assumeIsolated { self?.runningChanged(id, recheck: false) }
            }
        }
        guard running != p.running else { return }
        p.running = running
        processes[id] = p
        regroup()
    }

    private func outputChanged() {
        let uid = Self.defaultOutputUID()
        guard uid != outputUID else { return }
        outputUID = uid
        failed.removeAll()
        for (key, tap) in taps {
            buildStarted()
            Self.queue.async { [weak self] in
                let status = tap.retarget(outputUID: uid)
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.finished(key, tap, status) } }
            }
        }
        reconcile()
    }

    // MARK: Model

    /// Test hook: replace the process list without Core Audio.
    func injectApps(_ list: [UtilAudioApp]) {
        apply(list)
    }

    private func regroup() {
        let list = UtilAppVolumeModel.group(Array(processes.values)) { identities[$0.object] }
        apply(list)
    }

    private func apply(_ list: [UtilAudioApp]) {
        let now = Date()
        let keys = Set(list.map(\.id))
        for app in allApps where !keys.contains(app.id) {
            failed.remove(app.id)
            // Without "Remember volume per app" a level lasts while the app runs.
            if !remember { levels[app.id] = nil }
        }
        allApps = list
        for app in list {
            if app.running { if since[app.id] == nil { since[app.id] = now } } else { since[app.id] = nil }
        }
        for key in Array(since.keys) where !keys.contains(key) { since[key] = nil }
        let playing = list.filter(\.running).sorted {
            let a = since[$0.id] ?? now, b = since[$1.id] ?? now
            return a != b ? a > b : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        if playing != apps { apps = playing }
        reconcile()
        updateActivation()
    }

    // MARK: Taps

    private func reconcile() {
        guard tapsAllowed, !sceneMode, !isShutDown else { return }
        var actions = UtilAppVolumeModel.plan(apps: allApps, levels: levels, taps: snapshots, allowed: !permissionDenied, blocked: failed)
        if actions.contains(where: { if case .create = $0 { return true } else { return false } }),
           UtilAudioCapturePermission.status() == .denied {
            permissionDenied = true
            actions = UtilAppVolumeModel.plan(apps: allApps, levels: levels, taps: snapshots, allowed: false)
        }
        actions.forEach(perform)
    }

    private func perform(_ action: UtilAppVolumeAction) {
        switch action {
        case let .create(key, processes, gain, running):
            let tap = UtilAppVolumeTap(key: key, gain: gain)
            taps[key] = tap
            snapshots[key] = UtilAppVolumeTapSnapshot(processes: processes, gain: gain, running: running)
            let uid = outputUID ?? Self.defaultOutputUID()
            buildStarted()
            Self.queue.async { [weak self] in
                let status = tap.build(processes: processes, outputUID: uid, running: running)
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.finished(key, tap, status) } }
            }
        case let .update(key, processes):
            guard let tap = taps[key] else { return }
            snapshots[key]?.processes = processes
            buildStarted()
            Self.queue.async { [weak self] in
                let status = tap.update(processes: processes)
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.finished(key, tap, status) } }
            }
        case let .gain(key, gain):
            snapshots[key]?.gain = gain
            taps[key]?.setGain(gain)
        case let .run(key, on):
            guard let tap = taps[key] else { return }
            snapshots[key]?.running = on
            Self.queue.async { tap.setRunning(on) }
        case let .destroy(key):
            snapshots[key] = nil
            tapped.remove(key)
            guard let tap = taps.removeValue(forKey: key) else { return }
            Self.queue.async { tap.teardown() }
        }
    }

    /// Result of a build on `queue`. A failed tap is removed and its app left alone (slider disabled).
    private func buildStarted() {
        buildsInFlight += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.buildsInFlight > 0, !self.awaitingPermission else { return }
                self.awaitingPermission = true
            }
        }
    }

    private func finished(_ key: String, _ tap: UtilAppVolumeTap, _ status: OSStatus) {
        buildsInFlight = max(0, buildsInFlight - 1)
        if buildsInFlight == 0, awaitingPermission { awaitingPermission = false }
        guard taps[key] === tap else { return }
        if status == noErr {
            tapped.insert(key)
            schedulePermissionChecks()
            return
        }
        NSLog("NiceDock App Volume: no tap for \(key) (OSStatus \(status))")
        taps[key] = nil
        snapshots[key] = nil
        tapped.remove(key)
        failed.insert(key)
        if levels.removeValue(forKey: key) != nil { scheduleSave() }
        Self.queue.async { tap.teardown() }
    }

    // MARK: Permission

    /// Re-reads System Audio Recording (when a view appears and shortly after a tap starts, in case the user just
    /// answered the prompt). Denied removes every tap so apps play normally again.
    func refreshPermission() {
        guard isSupported, tapsAllowed, !sceneMode else { return }
        let denied = UtilAudioCapturePermission.status() == .denied
        guard denied != permissionDenied else { return }
        permissionDenied = denied
        reconcile()
    }

    private func schedulePermissionChecks() {
        guard permissionChecks == 0 else { return }
        for delay in [1.5, 6.0] {
            permissionChecks += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    self?.permissionChecks -= 1
                    self?.refreshPermission()
                }
            }
        }
    }

    // MARK: Debug / tests

    /// Peak meters measured inside the IO block (input = the app's own signal, output = after gain).
    func debugMeters(_ key: String) -> (input: Float, output: Float, cycles: UInt32)? { taps[key]?.meters }

    func debugResetMeters(_ key: String) { taps[key]?.resetMeters() }

    /// Aggregate and tap UIDs of `key`'s tap once it is built (read on the engine queue).
    func debugUIDs(_ key: String) -> (aggregate: String, tap: String)? {
        guard let tap = taps[key] else { return nil }
        return Self.queue.sync { tap.aggregateUID.flatMap { a in tap.tapUID.map { (a, $0) } } }
    }

    // MARK: Reference scene

    /// Deterministic apps and levels for `--scene reference` renders. No effect outside the scene.
    func seedReference(apps: [UtilAudioApp], levels: [String: UtilAppVolumeLevel], denied: Bool = false) {
        guard ReferenceScene.isActive else { return }
        sceneMode = true
        self.apps = apps
        self.levels = levels
        permissionDenied = denied
        failed = []
    }

    // MARK: HAL reads

    nonisolated static func processObjectIDs() -> [AudioObjectID] {
        var a = UtilCA.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(UtilCA.system, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(UtilCA.system, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { $0 != 0 }
    }

    nonisolated static func readProcess(_ id: AudioObjectID) -> UtilAudioProcess? {
        guard let pid = UtilCA.get(id, UtilCA.address(kAudioProcessPropertyPID), pid_t(0)), pid > 0 else { return nil }
        return UtilAudioProcess(object: id, pid: pid, bundleID: UtilCA.string(id, kAudioProcessPropertyBundleID) ?? "", running: isRunningOutput(id))
    }

    nonisolated static func isRunningOutput(_ id: AudioObjectID) -> Bool {
        (UtilCA.get(id, UtilCA.address(kAudioProcessPropertyIsRunningOutput), UInt32(0)) ?? 0) != 0
    }

    nonisolated static func defaultOutputUID() -> String? {
        guard let dev = UtilCA.get(UtilCA.system, UtilCA.address(kAudioHardwarePropertyDefaultOutputDevice), AudioDeviceID(0)), dev != 0 else { return nil }
        return UtilCA.string(dev, kAudioDevicePropertyDeviceUID)
    }
}
