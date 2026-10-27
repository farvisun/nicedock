import AppKit
import ApplicationServices
import Observation

/// Moves, resizes, raises, minimizes and closes other apps' windows through the Accessibility API.
///
/// Tile buttons act on the focused window of the last app the user was in: CoolDock's dock and panels never
/// activate CoolDock, and a CoolDock window that does become active (Settings) is skipped. Permission is only read
/// with `AXIsProcessTrusted()` — never the prompting variant; the user grants it in System Settings. Developer
/// renders (`--render`) never touch real windows.
@Observable
@MainActor
final class UtilWindowService: DemandDriven {
    static let shared = UtilWindowService()

    private(set) var trusted = false
    /// Windows for the panel, grouped by app in z-order.
    private(set) var groups: [UtilWinGroup] = []
    /// Focused window of the target app (the panel's default layout target).
    private(set) var focusedID: CGWindowID?

    @ObservationIgnored private var subscribers = Set<String>()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var targetPID: pid_t = 0
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var seeded = false

    private var ownPID: pid_t { ProcessInfo.processInfo.processIdentifier }

    /// Deterministic state for `--scene reference` renders. No effect outside the scene.
    func seedReference(trusted: Bool, groups: [UtilWinGroup] = [], focused: CGWindowID? = nil) {
        guard ReferenceScene.isActive else { return }
        seeded = true
        self.trusted = trusted
        self.groups = groups
        focusedID = focused
    }

    func subscribe(_ id: String) {
        guard !ReferenceScene.isActive else { return }
        subscribers.insert(id)
        guard subscribers.count == 1 else { return }
        refreshTrust()
        note(NSWorkspace.shared.frontmostApplication)
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { UtilWindowService.shared.note(app) }
        })
    }

    func unsubscribe(_ id: String) {
        subscribers.remove(id)
        guard subscribers.isEmpty else { return }
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        pollTask?.cancel()
        pollTask = nil
    }

    private func note(_ app: NSRunningApplication?) {
        if let app, app.processIdentifier != ownPID, app.activationPolicy == .regular { targetPID = app.processIdentifier }
        refreshTrust()
    }

    // MARK: Permission

    @discardableResult func refreshTrust() -> Bool {
        if seeded { return trusted }
        let now = AXIsProcessTrusted()
        if now != trusted { trusted = now }
        return now
    }

    /// Opens Privacy & Security → Accessibility and notices the switch for the next few minutes.
    func requestAccess() {
        guard !UtilEnv.rendering else { return }
        Open.url("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            for _ in 0..<90 {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                if self.refreshTrust() {
                    self.reload()
                    return
                }
            }
        }
    }

    private func canAct() -> Bool {
        guard !UtilEnv.rendering else { return false }
        guard refreshTrust() else { requestAccess(); return false }
        return true
    }

    // MARK: Targets

    private var targetApp: pid_t? {
        if targetPID != 0, let app = NSRunningApplication(processIdentifier: targetPID), !app.isTerminated { return targetPID }
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ownPID { return front.processIdentifier }
        return nil
    }

    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func screens() -> [UtilWinScreen] {
        NSScreen.screens.map { UtilWinScreen(frame: $0.frame, usable: UtilWinMath.usable(visible: $0.visibleFrame, dock: coolDockFrame(on: $0))) }
    }

    /// CoolDock's dock on `screen` while it stays docked there (reveal and floating docks don't reserve space).
    static func coolDockFrame(on screen: NSScreen) -> CGRect? {
        let store = AppStore.shared
        let scenario = store.settings.scenario
        guard !scenario.isReveal, scenario != .floating, !store.dockHidden,
              let dock = DockController.shared.window(for: DockController.stableID(screen)), dock.panel.isVisible else { return nil }
        return dock.panel.frame
    }

    // MARK: Actions

    /// Tile button: `action` on the focused window of the app that was in front before the click.
    @discardableResult func perform(_ action: UtilWinAction) -> Bool {
        guard canAct(), let pid = targetApp, let win = UtilAX.focusedWindow(pid) else { return false }
        return apply(action, to: win, pid: pid)
    }

    @discardableResult func perform(_ action: UtilWinAction, on entry: UtilWinEntry) -> Bool {
        guard canAct(), let win = UtilAX.window(pid: entry.pid, id: entry.id, frame: entry.frame) else { return false }
        if entry.minimized { UtilAX.setBool(win, kAXMinimizedAttribute, false) }
        let ok = apply(action, to: win, pid: entry.pid)
        reloadSoon()
        return ok
    }

    private func apply(_ action: UtilWinAction, to win: AXUIElement, pid: pid_t) -> Bool {
        guard let frame = UtilAX.frame(win) else { return false }
        let h = Self.primaryHeight
        guard let target = UtilWinMath.target(action, window: UtilWinMath.flip(frame, primaryHeight: h), screens: Self.screens()) else { return false }
        UtilAX.setFrame(win, UtilWinMath.flip(target, primaryHeight: h), pid: pid)
        return true
    }

    func focus(_ entry: UtilWinEntry) {
        guard !UtilEnv.rendering else { return }
        if refreshTrust(), let win = UtilAX.window(pid: entry.pid, id: entry.id, frame: entry.frame) {
            if entry.minimized { UtilAX.setBool(win, kAXMinimizedAttribute, false) }
            UtilAX.raise(win)
        }
        NSRunningApplication(processIdentifier: entry.pid)?.activate(options: [])
        targetPID = entry.pid
        focusedID = entry.id
        reloadSoon()
    }

    func toggleMinimized(_ entry: UtilWinEntry) {
        guard canAct(), let win = UtilAX.window(pid: entry.pid, id: entry.id, frame: entry.frame) else { return }
        UtilAX.setBool(win, kAXMinimizedAttribute, !entry.minimized)
        reloadSoon()
    }

    func close(_ entry: UtilWinEntry) {
        guard canAct(), let win = UtilAX.window(pid: entry.pid, id: entry.id, frame: entry.frame) else { return }
        UtilAX.close(win)
        reloadSoon()
    }

    /// Tiles the visible windows on the display of the focused window (or the main display), frontmost first.
    @discardableResult func arrangeAll() -> Bool {
        guard canAct() else { return false }
        let h = Self.primaryHeight
        let screens = Self.screens()
        var index = NSScreen.screens.firstIndex { $0 == NSScreen.main } ?? 0
        if let pid = targetApp, let win = UtilAX.focusedWindow(pid), let f = UtilAX.frame(win),
           let i = UtilWinMath.screenIndex(for: UtilWinMath.flip(f, primaryHeight: h), in: screens) {
            index = i
        }
        guard screens.indices.contains(index) else { return false }
        let windows = onScreenEntries().filter {
            UtilWinMath.screenIndex(for: UtilWinMath.flip($0.frame, primaryHeight: h), in: screens) == index
        }.prefix(12)
        let rects = UtilWinMath.grid(windows.count, in: screens[index].usable)
        for (entry, rect) in zip(windows, rects) {
            if let win = UtilAX.window(pid: entry.pid, id: entry.id, frame: entry.frame) {
                UtilAX.setFrame(win, UtilWinMath.flip(rect, primaryHeight: h), pid: entry.pid)
            }
        }
        reloadSoon()
        return !windows.isEmpty
    }

    // MARK: Listing

    /// Visible normal windows of regular apps, front to back (CGWindowList; titles only with Screen Recording).
    private func onScreenEntries() -> [UtilWinEntry] {
        let infos = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        return UtilWinList.parse(infos, ownPID: ownPID).compactMap { e in
            guard let app = NSRunningApplication(processIdentifier: e.pid), app.activationPolicy == .regular else { return nil }
            var e = e
            e.appName = app.localizedName ?? e.appName
            e.appPath = app.bundleURL?.path
            return e
        }
    }

    /// Rebuilds the panel list. With Accessibility, titles come from AXTitle (no Screen Recording needed) and
    /// minimized windows are added; the AX calls run off the main thread with a short timeout per app.
    func reload() {
        guard !seeded, !UtilEnv.rendering else { return }
        let entries = onScreenEntries()
        guard refreshTrust() else {
            groups = UtilWinList.group(entries)
            focusedID = nil
            return
        }
        let pids = Array(Set(entries.map(\.pid) + RunningApps.shared.apps.map(\.processIdentifier)))
        let target = targetApp
        Task.detached(priority: .userInitiated) {
            let snapshot = UtilAX.snapshot(pids: pids, focusedPID: target)
            await MainActor.run { UtilWindowService.shared.merge(entries, snapshot) }
        }
    }

    private func merge(_ cg: [UtilWinEntry], _ ax: UtilAXSnapshot) {
        var entries = cg
        for i in entries.indices {
            guard let infos = ax.windows[entries[i].pid] else { continue }
            let match = infos.first { $0.id == entries[i].id } ?? infos.first { $0.frame.map { UtilAX.near($0, entries[i].frame) } ?? false }
            if let title = match?.title, !title.isEmpty { entries[i].title = title }
        }
        var synthetic: CGWindowID = .max
        for pid in ax.windows.keys.sorted() {
            guard let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular else { continue }
            for info in ax.windows[pid] ?? [] where info.minimized {
                let id = info.id ?? { synthetic -= 1; return synthetic }()
                guard !entries.contains(where: { $0.id == id }) else { continue }
                entries.append(UtilWinEntry(id: id, pid: pid, appName: app.localizedName ?? "", appPath: app.bundleURL?.path,
                                            title: info.title.flatMap { $0.isEmpty ? nil : $0 }, frame: info.frame ?? .zero, minimized: true))
            }
        }
        // Minimized windows go to the end of their app.
        let fresh = UtilWinList.group(entries).map { g in
            var g = g
            g.windows = g.windows.filter { !$0.minimized } + g.windows.filter(\.minimized)
            return g
        }
        if fresh != groups { groups = fresh }
        focusedID = ax.focused
    }

    private func reloadSoon() {
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            reload()
        }
    }
}

// MARK: - Accessibility calls

struct UtilAXWindowInfo: Sendable {
    var id: CGWindowID?
    var title: String?
    var minimized: Bool
    var frame: CGRect?
}

struct UtilAXSnapshot: Sendable {
    var windows: [pid_t: [UtilAXWindowInfo]] = [:]
    var focused: CGWindowID?
}

/// Thin wrappers over AXUIElement. Every call is synchronous IPC to the other app, bounded by a short timeout.
enum UtilAX {
    private typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    /// `_AXUIElementGetWindow` (HIServices, private but stable since 10.6) maps an AX window to its CGWindowID; when it
    /// is missing, windows are matched by frame instead.
    private static let getWindow: GetWindowFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(sym, to: GetWindowFn.self)
    }()

    /// The messaging timeout is per element, so every element handed out gets the short one (a hung app must not
    /// stall the dock for the default 6 s).
    @discardableResult private static func timed(_ el: AXUIElement) -> AXUIElement {
        AXUIElementSetMessagingTimeout(el, 0.4)
        return el
    }

    static func app(_ pid: pid_t) -> AXUIElement { timed(AXUIElementCreateApplication(pid)) }

    private static func raw(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func element(_ el: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = raw(el, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return timed(v as! AXUIElement)
    }

    static func windows(_ pid: pid_t) -> [AXUIElement] {
        ((raw(app(pid), kAXWindowsAttribute) as? [AXUIElement]) ?? []).map(timed)
    }

    static func windowID(_ el: AXUIElement) -> CGWindowID? {
        guard let getWindow else { return nil }
        var id: CGWindowID = 0
        return getWindow(el, &id) == .success && id != 0 ? id : nil
    }

    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let pv = raw(el, kAXPositionAttribute), let sv = raw(el, kAXSizeAttribute),
              CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(pv as! AXValue, .cgPoint, &p), AXValueGetValue(sv as! AXValue, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }

    static func bool(_ el: AXUIElement, _ name: String) -> Bool? { raw(el, name) as? Bool }

    static func setBool(_ el: AXUIElement, _ name: String, _ value: Bool) {
        AXUIElementSetAttributeValue(el, name as CFString, (value ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef)
    }

    static func focusedWindow(_ pid: pid_t) -> AXUIElement? {
        let a = app(pid)
        if let w = element(a, kAXFocusedWindowAttribute) { return w }
        if let w = element(a, kAXMainWindowAttribute) { return w }
        return windows(pid).first { bool($0, kAXMinimizedAttribute) != true }
    }

    static func window(pid: pid_t, id: CGWindowID, frame: CGRect) -> AXUIElement? {
        let list = windows(pid)
        if let w = list.first(where: { windowID($0) == id }) { return w }
        return list.first { frame.width > 0 && (UtilAX.frame($0).map { near($0, frame) } ?? false) }
    }

    static func near(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2 && abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
    }

    /// Size, position, size again: the first resize lets the window fit the target display, the second fixes apps
    /// that clamp their size to the display they were on. Enhanced UI (set by assistive apps) makes some apps animate
    /// every step, so it is switched off for the move.
    static func setFrame(_ el: AXUIElement, _ r: CGRect, pid: pid_t) {
        let a = app(pid)
        let enhanced = bool(a, "AXEnhancedUserInterface") == true
        if enhanced { setBool(a, "AXEnhancedUserInterface", false) }
        setSize(el, r.size)
        setPosition(el, r.origin)
        setSize(el, r.size)
        if enhanced { setBool(a, "AXEnhancedUserInterface", true) }
    }

    private static func setPosition(_ el: AXUIElement, _ point: CGPoint) {
        var p = point
        if let v = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, v) }
    }

    private static func setSize(_ el: AXUIElement, _ size: CGSize) {
        var s = size
        if let v = AXValueCreate(.cgSize, &s) { AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, v) }
    }

    static func raise(_ el: AXUIElement) {
        AXUIElementPerformAction(el, kAXRaiseAction as CFString)
        setBool(el, kAXMainAttribute, true)
    }

    static func close(_ el: AXUIElement) {
        if let button = element(el, kAXCloseButtonAttribute) { AXUIElementPerformAction(button, kAXPressAction as CFString) }
    }

    /// Titles, minimized state and frames of every window of `pids`, plus the focused window of `focusedPID`.
    nonisolated static func snapshot(pids: [pid_t], focusedPID: pid_t?) -> UtilAXSnapshot {
        var out = UtilAXSnapshot()
        for pid in pids {
            out.windows[pid] = windows(pid).map { w in
                UtilAXWindowInfo(id: windowID(w), title: raw(w, kAXTitleAttribute) as? String,
                                 minimized: bool(w, kAXMinimizedAttribute) == true, frame: frame(w))
            }
        }
        if let focusedPID, let w = focusedWindow(focusedPID) { out.focused = windowID(w) }
        return out
    }
}
