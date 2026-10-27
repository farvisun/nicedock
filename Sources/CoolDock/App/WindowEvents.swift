import AppKit
import ApplicationServices

/// Accessibility notifications for other apps' windows: created, moved, resized and restored (deminiaturized).
///
/// One `AXObserver` per running regular app, registered on the app element and on each of its windows. Observers exist
/// only while a feature subscribes (Reserve Dock Space, Hide on Window Hover) *and* CoolDock is trusted for
/// Accessibility; nothing is polled, so an idle desktop costs nothing. CoolDock never asks for the permission by itself:
/// the hub starts when the user grants it (the system posts `com.apple.accessibility.api` when trust changes).
@MainActor
final class WindowEventHub {
    static let shared = WindowEventHub()

    enum Kind: Equatable {
        case created, moved, resized, restored
        /// The hub (re)started and every window should be looked at once.
        case resync
    }

    struct Event {
        let pid: pid_t
        let window: AXUIElement?
        let kind: Kind
        /// The left mouse button was down when the notification arrived (a drag or live resize).
        let mouseDown: Bool
    }

    private final class AppObservation {
        let observer: AXObserver
        let app: AXUIElement
        var windows: [AXWindowKey] = []
        init(observer: AXObserver, app: AXUIElement) {
            self.observer = observer
            self.app = app
        }
    }

    private var subscribers: [String: (Event) -> Void] = [:]
    private var apps: [pid_t: AppObservation] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    private var trustObserver: NSObjectProtocol?
    private(set) var isRunning = false

    private static let appNotifications = [kAXWindowCreatedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification,
                                           kAXWindowDeminiaturizedNotification]
    private static let windowNotifications = [kAXWindowMovedNotification, kAXWindowResizedNotification, kAXWindowDeminiaturizedNotification,
                                              kAXUIElementDestroyedNotification]

    func subscribe(_ id: String, _ handler: @escaping (Event) -> Void) {
        let wasRunning = isRunning
        subscribers[id] = handler
        reconcile()
        // A fresh start already broadcast a resync; a late subscriber gets its own.
        if wasRunning { handler(Event(pid: 0, window: nil, kind: .resync, mouseDown: false)) }
    }

    func unsubscribe(_ id: String) {
        guard subscribers.removeValue(forKey: id) != nil else { return }
        reconcile()
    }

    var observedPIDs: [pid_t] { Array(apps.keys) }

    /// Starts or stops observation to match subscribers and the current Accessibility trust.
    func reconcile() {
        let wanted = !subscribers.isEmpty && !RenderHarness.isActive
        if wanted, trustObserver == nil {
            trustObserver = DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main) { _ in
                // The trust database is updated just after the notification.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { MainActor.assumeIsolated { WindowEventHub.shared.reconcile() } }
            }
        } else if !wanted, let t = trustObserver {
            DistributedNotificationCenter.default().removeObserver(t)
            trustObserver = nil
        }
        if wanted && AXIsProcessTrusted() { start() } else { stop() }
    }

    private func start() {
        guard !isRunning else { return }
        isRunning = true
        for app in NSWorkspace.shared.runningApplications { observe(app) }
        let wnc = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(wnc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            // AX isn't ready the instant an app launches; its first windows still arrive as "created".
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated { WindowEventHub.shared.observe(app) } }
        })
        workspaceObservers.append(wnc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated { WindowEventHub.shared.forget(pid) }
        })
        // Apps that were busy at start (or launched as background agents and became regular) are picked up on activation.
        workspaceObservers.append(wnc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated {
                if WindowEventHub.shared.apps[app.processIdentifier] == nil { WindowEventHub.shared.observe(app) }
            }
        })
        broadcast(Event(pid: 0, window: nil, kind: .resync, mouseDown: false))
    }

    private func stop() {
        guard isRunning else { return }
        isRunning = false
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        for pid in Array(apps.keys) { forget(pid) }
    }

    private func observe(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard isRunning, apps[pid] == nil, pid != ProcessInfo.processInfo.processIdentifier,
              app.activationPolicy == .regular, !app.isTerminated else { return }
        var created: AXObserver?
        guard AXObserverCreate(pid, windowEventCallback, &created) == .success, let observer = created else { return }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.5)
        var registered = 0
        for name in Self.appNotifications where AXObserverAddNotification(observer, element, name as CFString, nil) == .success {
            registered += 1
        }
        guard registered > 0 else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        let entry = AppObservation(observer: observer, app: element)
        apps[pid] = entry
        for window in AXWindowInfo.windows(of: element) { watch(window, in: entry) }
    }

    private func forget(_ pid: pid_t) {
        guard let entry = apps.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(entry.observer), .defaultMode)
    }

    /// Windows of the observed apps (for a full pass after enabling or when the Dock moves).
    func allWindows() -> [(pid: pid_t, window: AXUIElement)] {
        apps.flatMap { pid, entry in AXWindowInfo.windows(of: entry.app).map { (pid, $0) } }
    }

    private func watch(_ window: AXUIElement, in entry: AppObservation) {
        let key = AXWindowKey(window)
        guard !entry.windows.contains(key) else { return }
        for name in Self.windowNotifications { AXObserverAddNotification(entry.observer, window, name as CFString, nil) }
        entry.windows.append(key)
    }

    fileprivate func receive(_ element: AXUIElement, _ name: String) {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard let entry = apps[pid] else { return }
        let kind: Kind
        switch name {
        case kAXWindowCreatedNotification:
            watch(element, in: entry)
            kind = .created
        case kAXWindowMovedNotification: kind = .moved
        case kAXWindowResizedNotification: kind = .resized
        case kAXWindowDeminiaturizedNotification: kind = .restored
        case kAXUIElementDestroyedNotification:
            let key = AXWindowKey(element)
            entry.windows.removeAll { $0 == key }
            return
        default: return
        }
        broadcast(Event(pid: pid, window: element, kind: kind, mouseDown: NSEvent.pressedMouseButtons & 1 != 0))
    }

    private func broadcast(_ event: Event) {
        for handler in subscribers.values { handler(event) }
    }
}

/// C callback: AX delivers on the run loop the source was added to (main).
private let windowEventCallback: AXObserverCallback = { _, element, notification, _ in
    MainActor.assumeIsolated { WindowEventHub.shared.receive(element, notification as String) }
}

/// Hashable identity of an AX window (`CFEqual` / `CFHash`: two references to the same window compare equal).
struct AXWindowKey: Hashable {
    let element: AXUIElement
    init(_ element: AXUIElement) { self.element = element }
    static func == (a: AXWindowKey, b: AXWindowKey) -> Bool { CFEqual(a.element, b.element) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
}

/// Reads and writes the few window attributes CoolDock needs.
enum AXWindowInfo {
    struct Snapshot {
        var frame: CGRect
        var standard: Bool
        var minimized: Bool
        var fullscreen: Bool
        var canMove: Bool
        var canResize: Bool
    }

    static func windows(of app: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    static func snapshot(_ w: AXUIElement) -> Snapshot? {
        AXUIElementSetMessagingTimeout(w, 0.5)
        guard let frame = frame(w) else { return nil }
        let role = string(w, kAXRoleAttribute)
        let subrole = string(w, kAXSubroleAttribute)
        var movable = DarwinBoolean(false), sizable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(w, kAXPositionAttribute as CFString, &movable)
        AXUIElementIsAttributeSettable(w, kAXSizeAttribute as CFString, &sizable)
        return Snapshot(frame: frame,
                        standard: role == kAXWindowRole && subrole == kAXStandardWindowSubrole,
                        minimized: bool(w, kAXMinimizedAttribute),
                        fullscreen: bool(w, "AXFullScreen"),
                        canMove: movable.boolValue,
                        canResize: sizable.boolValue)
    }

    static func frame(_ w: AXUIElement) -> CGRect? {
        var pos: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &size) == .success,
              let pos, let size, CFGetTypeID(pos) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(pos as! AXValue, .cgPoint, &p), AXValueGetValue(size as! AXValue, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }

    @discardableResult
    static func setPosition(_ w: AXUIElement, _ point: CGPoint) -> Bool {
        var p = point
        guard let v = AXValueCreate(.cgPoint, &p) else { return false }
        return AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, v) == .success
    }

    @discardableResult
    static func setSize(_ w: AXUIElement, _ size: CGSize) -> Bool {
        var s = size
        guard let v = AXValueCreate(.cgSize, &s) else { return false }
        return AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, v) == .success
    }

    private static func string(_ w: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func bool(_ w: AXUIElement, _ attribute: String) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, attribute as CFString, &value) == .success else { return false }
        return (value as? Bool) ?? false
    }
}
