import AppKit
import ApplicationServices
import CoreWLAN
import IOKit.pwr_mgt
import Observation
import SwiftUI

enum UtilToggleKind: String, CaseIterable, Identifiable {
    case wifi, bluetooth, darkMode, keepAwake, keyboardLock, hideDesktop
    var id: String { rawValue }

    var title: String {
        switch self {
        case .wifi: return L("Wi-Fi")
        case .bluetooth: return L("Bluetooth")
        case .darkMode: return L("Dark Mode")
        case .keepAwake: return L("Keep Awake")
        case .keyboardLock: return L("Keyboard Cleaning Lock")
        case .hideDesktop: return L("Hide Desktop Icons")
        }
    }

    var accent: Color {
        switch self {
        case .wifi, .bluetooth: return UtilTint.toggleBlue
        case .darkMode: return .cdIndigo
        case .keepAwake: return UtilTint.toggleOrange
        case .keyboardLock: return .cdRed
        case .hideDesktop: return .cdTeal
        }
    }
}

// MARK: - Service

/// System switches. State is read on demand and refreshed by notifications/delegates — never polled.
@Observable
@MainActor
final class UtilToggleService: DemandDriven {
    static let shared = UtilToggleService()

    private(set) var wifiOn = false
    private(set) var wifiAvailable = false
    private(set) var bluetoothOn = false
    private(set) var bluetoothAvailable = false
    private(set) var darkMode = false
    private(set) var keepAwake = false
    private(set) var lockRemaining = 0
    private(set) var desktopHidden = false

    @ObservationIgnored private var subscribers = Set<String>()
    @ObservationIgnored private var assertion: IOPMAssertionID = 0
    @ObservationIgnored private var themeObserver: NSObjectProtocol?
    @ObservationIgnored private var activeObserver: NSObjectProtocol?
    @ObservationIgnored private var wifiDelegate: UtilWiFiDelegate?
    @ObservationIgnored private var lockTask: Task<Void, Never>?

    /// Deterministic switch states for `--scene reference` renders. No effect outside the scene.
    func seedReference(wifi: Bool, bluetooth: Bool, darkMode: Bool, keepAwake: Bool) {
        guard ReferenceScene.isActive else { return }
        (wifiOn, wifiAvailable, bluetoothOn, bluetoothAvailable) = (wifi, true, bluetooth, true)
        self.darkMode = darkMode
        self.keepAwake = keepAwake
        lockRemaining = 0
        desktopHidden = false
    }

    func subscribe(_ id: String) {
        // Reference renders keep their seeded states instead of reading this Mac's.
        guard !ReferenceScene.isActive else { return }
        subscribers.insert(id)
        guard subscribers.count == 1 else { return }
        refreshAll()
        themeObserver = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { UtilToggleService.shared.readDarkMode() }
        }
        // Bluetooth / Finder changes made elsewhere are picked up whenever the user comes back to the dock.
        activeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                UtilToggleService.shared.readBluetooth()
                UtilToggleService.shared.readDesktop()
            }
        }
        if !UtilEnv.rendering {
            let delegate = UtilWiFiDelegate()
            wifiDelegate = delegate
            let client = CWWiFiClient.shared()
            client.delegate = delegate
            try? client.startMonitoringEvent(with: .powerDidChange)
        }
    }

    func unsubscribe(_ id: String) {
        subscribers.remove(id)
        guard subscribers.isEmpty else { return }
        if let o = themeObserver { DistributedNotificationCenter.default().removeObserver(o) }
        if let o = activeObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        themeObserver = nil
        activeObserver = nil
        if wifiDelegate != nil {
            try? CWWiFiClient.shared().stopMonitoringAllEvents()
            CWWiFiClient.shared().delegate = nil
            wifiDelegate = nil
        }
    }

    func refreshAll() {
        readWiFi()
        readBluetooth()
        readDarkMode()
        readDesktop()
    }

    func isOn(_ kind: UtilToggleKind) -> Bool {
        switch kind {
        case .wifi: return wifiOn
        case .bluetooth: return bluetoothOn
        case .darkMode: return darkMode
        case .keepAwake: return keepAwake
        case .keyboardLock: return lockRemaining > 0
        case .hideDesktop: return desktopHidden
        }
    }

    func toggle(_ kind: UtilToggleKind) {
        switch kind {
        case .wifi: setWiFi(!wifiOn)
        case .bluetooth: setBluetooth(!bluetoothOn)
        case .darkMode: toggleDarkMode()
        case .keepAwake: setKeepAwake(!keepAwake)
        case .keyboardLock: lockRemaining > 0 ? endKeyboardLock() : startKeyboardLock()
        case .hideDesktop: setDesktopHidden(!desktopHidden)
        }
    }

    // MARK: Wi-Fi

    func readWiFi() {
        let iface = CWWiFiClient.shared().interface()
        wifiAvailable = iface != nil
        wifiOn = iface?.powerOn() ?? false
    }

    private func setWiFi(_ on: Bool) {
        guard let iface = CWWiFiClient.shared().interface() else { return }
        do {
            try iface.setPower(on)
            wifiOn = on
        } catch {
            Open.url("x-apple.systempreferences:com.apple.wifi-settings-extension")
        }
    }

    // MARK: Bluetooth (private IOBluetooth preference calls, resolved at runtime)

    func readBluetooth() {
        guard let state = UtilBluetoothPower.get() else { bluetoothAvailable = false; return }
        bluetoothAvailable = true
        bluetoothOn = state
    }

    private func setBluetooth(_ on: Bool) {
        guard UtilBluetoothPower.set(on) else {
            Open.url("x-apple.systempreferences:com.apple.BluetoothSettings")
            return
        }
        bluetoothOn = on
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            readBluetooth()
        }
    }

    // MARK: Appearance

    func readDarkMode() {
        let style = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleInterfaceStyle"] as? String
        darkMode = style?.lowercased() == "dark"
    }

    private func toggleDarkMode() {
        darkMode.toggle()
        Task {
            await Script.run("tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode")
            readDarkMode()
        }
    }

    // MARK: Keep awake

    private func setKeepAwake(_ on: Bool) {
        if on {
            guard assertion == 0 else { keepAwake = true; return }
            var id: IOPMAssertionID = 0
            let ok = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "NiceDock Keep Awake" as CFString, &id)
            if ok == kIOReturnSuccess { assertion = id; keepAwake = true }
        } else {
            if assertion != 0 { IOPMAssertionRelease(assertion) }
            assertion = 0
            keepAwake = false
        }
    }

    // MARK: Keyboard cleaning lock

    private func startKeyboardLock() {
        guard AXIsProcessTrusted() else {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
            return
        }
        guard UtilKeyboardTap.start() else { return }
        lockRemaining = 30
        lockTask?.cancel()
        lockTask = Task { [weak self] in
            while let self, self.lockRemaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                self.lockRemaining -= 1
            }
            self?.endKeyboardLock()
        }
    }

    func endKeyboardLock() {
        lockTask?.cancel()
        lockTask = nil
        UtilKeyboardTap.stop()
        lockRemaining = 0
    }

    // MARK: Desktop icons

    func readDesktop() {
        let value = CFPreferencesCopyAppValue("CreateDesktop" as CFString, "com.apple.finder" as CFString)
        if let b = value as? Bool { desktopHidden = !b }
        else if let s = value as? String { desktopHidden = ["0", "false", "no"].contains(s.lowercased()) }
        else { desktopHidden = false }
    }

    private func setDesktopHidden(_ hidden: Bool) {
        desktopHidden = hidden
        Task.detached(priority: .userInitiated) {
            UtilToggleService.run("/usr/bin/defaults", ["write", "com.apple.finder", "CreateDesktop", "-bool", hidden ? "false" : "true"])
            UtilToggleService.run("/usr/bin/killall", ["Finder"])
        }
    }

    nonisolated static func run(_ tool: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
        } catch {}
    }
}

/// CoreWLAN power events (delivered on a private queue).
private final class UtilWiFiDelegate: NSObject, CWEventDelegate {
    func powerStateDidChangeForWiFiInterface(withName interfaceName: String) {
        DispatchQueue.main.async { MainActor.assumeIsolated { UtilToggleService.shared.readWiFi() } }
    }
}

/// `IOBluetoothPreferenceGet/SetControllerPowerState` looked up with dlsym. Only used when the app bundle declares
/// a Bluetooth usage description (otherwise TCC would terminate the process) and never inside the render harness.
enum UtilBluetoothPower {
    private typealias GetFn = @convention(c) () -> Int32
    private typealias SetFn = @convention(c) (Int32) -> Void
    nonisolated(unsafe) private static var handle: UnsafeMutableRawPointer? = {
        guard allowed else { return nil }
        return dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_LAZY)
    }()

    private static var allowed: Bool {
        !UtilEnv.rendering && Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") != nil
    }

    static func get() -> Bool? {
        guard let h = handle, let sym = dlsym(h, "IOBluetoothPreferenceGetControllerPowerState") else { return nil }
        return unsafeBitCast(sym, to: GetFn.self)() != 0
    }

    static func set(_ on: Bool) -> Bool {
        guard let h = handle, let sym = dlsym(h, "IOBluetoothPreferenceSetControllerPowerState") else { return false }
        unsafeBitCast(sym, to: SetFn.self)(on ? 1 : 0)
        return true
    }
}

/// Session event tap that swallows keyboard (and media key) events while the cleaning lock is on.
enum UtilKeyboardTap {
    nonisolated(unsafe) private static var tap: CFMachPort?
    nonisolated(unsafe) private static var source: CFRunLoopSource?

    static func start() -> Bool {
        guard tap == nil else { return true }
        let types: [UInt32] = [CGEventType.keyDown.rawValue, CGEventType.keyUp.rawValue, CGEventType.flagsChanged.rawValue, 14 /* NX_SYSDEFINED */]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1)) }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = UtilKeyboardTap.tap { CGEvent.tapEnable(tap: t, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            return nil
        }, userInfo: nil) else { return false }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        source = src
        return true
    }

    static func stop() {
        if let port = tap { CGEvent.tapEnable(tap: port, enable: false); CFMachPortInvalidate(port) }
        if let src = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        tap = nil
        source = nil
    }
}

// MARK: - Views

struct UtilTogglesView: View {
    let w: WidgetInstance
    @Environment(\.metrics) private var m

    private var items: [UtilToggleKind] {
        var seen = Set<UtilToggleKind>()
        return w.list("items")
            .compactMap { UtilToggleKind(rawValue: $0.trimmingCharacters(in: .whitespaces)) }
            .filter { seen.insert($0).inserted }
    }

    var body: some View {
        Tile(width: w.kind.spec.width) {
            HStack(spacing: m.u(8)) {
                ForEach(items) { UtilToggleButton(kind: $0) }
            }
        }
        .demand(UtilToggleService.shared)
    }
}

private struct UtilToggleButton: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    var kind: UtilToggleKind
    private var service: UtilToggleService { .shared }

    var body: some View {
        let on = service.isOn(kind)
        let showsRing = on && kind != .darkMode
        let accent = p.accent(kind.accent)
        Button { service.toggle(kind) } label: {
            glyph(on: on)
                .frame(width: m.u(40), height: m.u(40))
                .background(Circle().fill(showsRing ? accent.opacity(0.16) : p.primary.opacity(0.065)))
                .overlay {
                    // The reference rings brighten towards the top.
                    if showsRing {
                        Circle().strokeBorder(LinearGradient(stops: [.init(color: p.monochrome ? accent : UtilTint.lighten(accent, 0.23), location: 0),
                                                                     .init(color: accent, location: 0.7)],
                                                             startPoint: .top, endPoint: .bottom), lineWidth: m.u(2))
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .help(helpText(on))
        .accessibilityLabel(kind.title)
        .accessibilityValue(on ? L("On") : L("Off"))
        .animation(.easeOut(duration: 0.18), value: on)
    }

    @ViewBuilder private func glyph(on: Bool) -> some View {
        let accent = p.accent(kind.accent)
        switch kind {
        case .wifi:
            Image(systemName: on ? "wifi" : "wifi.slash")
                .font(.system(size: m.u(14.5), weight: .medium))
                .modifier(UtilGlyphNudge())
                .foregroundStyle(on ? accent : p.secondary)
        case .bluetooth:
            UtilBluetoothRune()
                .stroke(on ? accent : p.secondary, style: StrokeStyle(lineWidth: m.u(1.5), lineCap: .round, lineJoin: .round))
                .frame(width: m.u(7.5), height: m.u(13))
                .modifier(UtilGlyphNudge(x: -0.25, y: 0))
        case .darkMode:
            Image(systemName: on ? "moon.fill" : "sun.max.fill")
                .font(.system(size: m.u(14.5), weight: .semibold))
                .modifier(UtilGlyphNudge(x: -0.25))
                .foregroundStyle(on ? p.primary : p.secondary)
        case .keepAwake:
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: m.u(14), weight: .semibold))
                .modifier(UtilGlyphNudge())
                .foregroundStyle(on ? accent : p.secondary)
        case .keyboardLock:
            if service.lockRemaining > 0 {
                Text(verbatim: Fmt.int(service.lockRemaining)).dock(14, .bold, accent, mono: true)
            } else {
                Image(systemName: "keyboard")
                    .font(.system(size: m.u(14), weight: .semibold))
                    .modifier(UtilGlyphNudge())
                    .foregroundStyle(p.secondary)
            }
        case .hideDesktop:
            Image(systemName: on ? "eye.slash" : "menubar.dock.rectangle")
                .font(.system(size: m.u(14), weight: .semibold))
                .foregroundStyle(on ? accent : p.secondary)
        }
    }

    private func helpText(_ on: Bool) -> String {
        switch kind {
        case .keyboardLock:
            return on ? L("Keyboard locked — click to unlock") : L("Lock the keyboard for 30 seconds to clean it")
        case .darkMode:
            return on ? L("Switch to Light Mode") : L("Switch to Dark Mode")
        default:
            return kind.title + " — " + (on ? L("On") : L("Off"))
        }
    }
}

/// The Bluetooth rune (SF Symbols has no public glyph for it).
struct UtilBluetoothRune: Shape {
    func path(in r: CGRect) -> Path {
        var path = Path()
        let x0 = r.minX, x1 = r.maxX, xm = r.midX
        let y0 = r.minY, y1 = r.maxY, h = r.height
        path.move(to: CGPoint(x: x0, y: y0 + h * 0.27))
        path.addLine(to: CGPoint(x: x1, y: y0 + h * 0.73))
        path.addLine(to: CGPoint(x: xm, y: y1))
        path.addLine(to: CGPoint(x: xm, y: y0))
        path.addLine(to: CGPoint(x: x1, y: y0 + h * 0.27))
        path.addLine(to: CGPoint(x: x0, y: y0 + h * 0.73))
        return path
    }
}

/// Sub-pixel placement of a toggle glyph: the reference symbols sit half a device pixel below the
/// circle's centre (`.offset` would snap that to a whole pixel).
private struct UtilGlyphNudge: ViewModifier {
    @Environment(\.metrics) private var m
    var x: CGFloat = 0
    var y: CGFloat = 0.25

    func body(content: Content) -> some View {
        content.transformEffect(CGAffineTransform(translationX: m.u(x), y: m.u(y)))
    }
}
