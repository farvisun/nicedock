import AppKit
import Observation
import SwiftUI

// MARK: - Windows

/// Borderless, non-activating panel that can still take keyboard focus for in-dock text fields.
final class DockPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = true
        isFloatingPanel = true
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that accepts first click and reports hover at the AppKit level
/// (SwiftUI hover is unreliable while the app is inactive).
final class DockHostingView<Content: View>: NSHostingView<Content> {
    var onHover: ((Bool) -> Void)?
    /// Called (coalesced) whenever the SwiftUI content's ideal size changes.
    var onSizeChange: ((CGSize) -> Void)?
    private var area: NSTrackingArea?
    private var sizePending = false

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        guard onSizeChange != nil, !sizePending else { return }
        sizePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.sizePending = false
            self.onSizeChange?(self.intrinsicContentSize)
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover?(false)
    }
}

/// Thin, almost invisible strip at a screen edge that reveals the dock.
final class TriggerWindow: NSPanel {
    var onEnter: (() -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = NSColor(white: 0, alpha: 0.002)
        hasShadow = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 2)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        ignoresMouseEvents = false
        let v = TriggerView()
        v.owner = self
        contentView = v
    }

    final class TriggerView: NSView {
        weak var owner: TriggerWindow?
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
        }
        override func mouseEntered(with event: NSEvent) { owner?.onEnter?() }
    }
}

// MARK: - Per-window model

@Observable
@MainActor
final class DockWindowModel {
    let screenID: String
    var availableWidth: CGFloat = 1200
    var atTop = false
    var floating = false
    var hovering = false
    var revealed = true
    var lastStripSize: CGSize = .zero

    init(screenID: String) { self.screenID = screenID }
}

// MARK: - Dock window (one per display)

@MainActor
final class DockWindow {
    let screenID: String
    private(set) var screen: NSScreen
    let panel = DockPanel()
    let model: DockWindowModel
    private var host: DockHostingView<AnyView>!
    private var trigger: TriggerWindow?
    private var contentSize: CGSize = .zero
    private var hideWork: DispatchWorkItem?
    private var showWork: DispatchWorkItem?
    private var swapTimer: Timer?
    private(set) var isShown = false
    private var suppressed = false // fullscreen / window overlap / manual toggle

    var store: AppStore { .shared }
    var settings: Settings { store.settings }

    init(screen: NSScreen, id: String) {
        self.screen = screen
        self.screenID = id
        model = DockWindowModel(screenID: id)
        let root = DockRootView(model: model)
        host = DockHostingView(rootView: AnyView(root))
        host.sizingOptions = [.intrinsicContentSize]
        host.translatesAutoresizingMaskIntoConstraints = true
        host.onHover = { [weak self] inside in self?.hoverChanged(inside) }
        host.onSizeChange = { [weak self] size in self?.contentSizeChanged(size) }
        panel.contentView = host
        contentSize = host.intrinsicContentSize
    }

    func teardown() {
        hideWork?.cancel(); showWork?.cancel(); swapTimer?.invalidate()
        trigger?.orderOut(nil)
        trigger = nil
        panel.orderOut(nil)
    }

    func update(screen: NSScreen) {
        self.screen = screen
        configure()
    }

    // MARK: Layout

    var plateTop: Bool {
        switch settings.scenario {
        case .revealTop: return true
        case .fixed: return settings.fixedPosition.isTop
        case .floating:
            let o = settings.floatingOrigins[screenID]
            return o.map { CGFloat($0.y) > screen.frame.midY } ?? false
        default: return false
        }
    }

    /// Applies scenario settings: trigger strips, initial visibility, position.
    func configure() {
        let scenario = settings.scenario
        model.atTop = plateTop
        model.floating = scenario == .floating
        model.availableWidth = screen.visibleFrame.width - 24
        installTrigger()
        layout(animated: false)
        if scenario.isReveal {
            if isShown && !model.hovering { hide(animated: false) } else if !isShown { hide(animated: false) }
        } else if !suppressed {
            show(animated: false)
        }
    }

    private func contentSizeChanged(_ size: CGSize) {
        guard size != contentSize, size.width > 1, size.width < 20_000 else { return }
        contentSize = size
        layout(animated: false)
    }

    func targetFrame(revealed: Bool = true) -> NSRect {
        let size = contentSize == .zero ? CGSize(width: 400, height: 120) : contentSize
        let vf = screen.visibleFrame
        let full = screen.frame
        let edge = CGFloat(settings.edgeDistance)
        var x: CGFloat
        var y: CGFloat

        func alignX(_ alignment: DockAlignment) -> CGFloat {
            switch alignment {
            case .center: return vf.midX - size.width / 2
            case .left: return vf.minX + edge
            case .right: return vf.maxX - size.width - edge
            }
        }

        switch settings.scenario {
        case .fixed:
            x = alignX(settings.fixedPosition.alignment)
            y = settings.fixedPosition.isTop ? vf.maxY - edge - size.height : vf.minY + edge
        case .floating:
            if let o = settings.floatingOrigins[screenID] {
                x = CGFloat(o.x); y = CGFloat(o.y)
            } else {
                x = vf.midX - size.width / 2
                y = vf.minY + edge
            }
            x = min(max(x, full.minX), full.maxX - size.width)
            y = min(max(y, full.minY), vf.maxY - size.height)
        case .revealTop:
            x = alignX(settings.alignment)
            y = vf.maxY - edge - size.height
            if !revealed { y = vf.maxY + 4 }
        case .swapBottom, .replaceDock, .replaceAutoHide, .revealBottom:
            x = alignX(settings.alignment)
            let base = settings.scenario == .revealBottom ? vf.minY : full.minY
            y = base + edge
            if !revealed { y = full.minY - size.height - 4 }
        }
        return NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    func layout(animated: Bool) {
        let frame = targetFrame(revealed: isShown || !settings.scenario.isReveal)
        if panel.frame != frame { panel.setFrame(frame, display: true, animate: false) }
    }

    // MARK: Triggers

    private func installTrigger() {
        let scenario = settings.scenario
        let needsBottom = scenario == .revealBottom || scenario == .replaceAutoHide || scenario == .swapBottom || settings.hideOnWindowHover
        let needsTop = scenario == .revealTop
        guard needsBottom || needsTop else {
            trigger?.orderOut(nil); trigger = nil
            return
        }
        let t = trigger ?? TriggerWindow()
        let h = max(1, CGFloat(settings.triggerSize))
        let f = screen.frame
        let rect = needsTop
            ? NSRect(x: f.minX, y: f.maxY - h, width: f.width, height: h)
            : NSRect(x: f.minX, y: f.minY, width: f.width, height: scenario == .swapBottom ? 2 : h)
        t.setFrame(rect, display: false)
        t.onEnter = { [weak self] in self?.triggerEntered() }
        t.orderFrontRegardless()
        trigger = t
    }

    private func triggerEntered() {
        switch settings.scenario {
        case .swapBottom:
            // Let the auto-hiding macOS Dock take over; come back once the pointer leaves its zone.
            hide(animated: true)
            startSwapWatch()
        default:
            hideWork?.cancel()
            showWork?.cancel()
            let delay = settings.showDelay
            if delay <= 0 { reveal() } else {
                let work = DispatchWorkItem { [weak self] in self?.reveal() }
                showWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            }
        }
    }

    private func reveal() {
        suppressedByOverlap = false
        show(animated: true)
    }

    private func startSwapWatch() {
        swapTimer?.invalidate()
        let threshold = screen.frame.minY + max(110, contentSize.height + 40)
        swapTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { t.invalidate(); return }
                if NSEvent.mouseLocation.y > threshold || !NSScreen.screens.contains(self.screen) {
                    t.invalidate()
                    self.swapTimer = nil
                    if !self.suppressed { self.show(animated: true) }
                }
            }
        }
    }

    private func hoverChanged(_ inside: Bool) {
        model.hovering = inside
        store.hoveringDock = inside
        if inside {
            hideWork?.cancel()
        } else if settings.scenario.isReveal {
            scheduleAutoHide()
        }
    }

    func scheduleAutoHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if Panels.shared.isOpen || self.store.browserOpen || self.model.hovering || NSApp.modalWindow != nil {
                self.scheduleAutoHide()
                return
            }
            self.hide(animated: true)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.35, settings.hideDelay), execute: work)
    }

    // MARK: Show / hide

    func show(animated: Bool) {
        guard !store.dockHidden else { return }
        isShown = true
        model.revealed = true
        let target = targetFrame(revealed: true)
        panel.ignoresMouseEvents = false
        if !panel.isVisible {
            var start = target
            if animated && settings.animations { start = targetFrame(revealed: false) }
            if settings.scenario.isReveal == false && start == target { panel.alphaValue = animated ? 0 : 1 }
            panel.setFrame(start, display: false)
            panel.orderFrontRegardless()
        }
        guard animated && settings.animations else {
            panel.alphaValue = 1
            panel.setFrame(target, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(target, display: true)
        }
    }

    func hide(animated: Bool) {
        isShown = false
        panel.ignoresMouseEvents = true
        let target = settings.scenario == .fixed || settings.scenario == .floating ? panel.frame : targetFrame(revealed: false)
        guard animated && settings.animations, panel.isVisible else {
            panel.alphaValue = 0
            panel.orderOut(nil)
            model.revealed = false
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isShown else { return }
                self.panel.orderOut(nil)
                self.model.revealed = false
            }
        })
    }

    /// Fullscreen / overlap suppression independent of scenario.
    var suppressedByOverlap = false
    func setSuppressed(_ value: Bool) {
        guard value != suppressed else { return }
        suppressed = value
        if value { hide(animated: true) } else if !settings.scenario.isReveal { show(animated: true) }
    }

    // MARK: Floating drag

    private var dragStart: (mouse: NSPoint, origin: NSPoint)?

    func floatingDrag(began: Bool, ended: Bool) {
        let mouse = NSEvent.mouseLocation
        if began || dragStart == nil { dragStart = (mouse, panel.frame.origin) }
        guard let start = dragStart else { return }
        let origin = NSPoint(x: start.origin.x + mouse.x - start.mouse.x, y: start.origin.y + mouse.y - start.mouse.y)
        panel.setFrameOrigin(origin)
        if ended {
            dragStart = nil
            store.settings.floatingOrigins[screenID] = CGPointCodable(x: Double(origin.x), y: Double(origin.y))
            model.atTop = plateTop
        }
    }
}

// MARK: - Controller

@MainActor
final class DockController {
    static let shared = DockController()
    private(set) var windows: [String: DockWindow] = [:]
    private var observers: [NSObjectProtocol] = []
    private var overlapTimer: Timer?
    private var lastScenario: LayoutScenario?

    func start() {
        let nc = NotificationCenter.default
        let wnc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DockController.shared.rebuild() }
        })
        observers.append(nc.addObserver(forName: .coolDockSettingsChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DockController.shared.settingsChanged() }
        })
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(wnc.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { DockController.shared.evaluateFullscreen() }
            })
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(wnc.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { DockController.shared.rebuild() }
            })
        }
        lastScenario = AppStore.shared.settings.scenario
        rebuild()
        configureOverlapWatch()
    }

    private func settingsChanged() {
        let s = AppStore.shared.settings
        if s.scenario != lastScenario {
            SystemDock.shared.apply(for: s.scenario)
            lastScenario = s.scenario
        }
        rebuild()
        configureOverlapWatch()
    }

    // MARK: Screens

    nonisolated static func displayID(_ screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    nonisolated static func stableID(_ screen: NSScreen) -> String {
        let did = displayID(screen)
        if let uuid = CGDisplayCreateUUIDFromDisplayID(did)?.takeRetainedValue() {
            return CFUUIDCreateString(nil, uuid) as String
        }
        return "display-\(did)"
    }

    private func registerDisplays() {
        let store = AppStore.shared
        var known = store.settings.displays
        var changed = false
        for screen in NSScreen.screens {
            let id = Self.stableID(screen)
            if let i = known.firstIndex(where: { $0.id == id }) {
                if Date().timeIntervalSince(known[i].lastSeen) > 3600 { known[i].lastSeen = Date(); changed = true }
            } else {
                known.append(KnownDisplay(id: id, name: screen.localizedName, builtIn: CGDisplayIsBuiltin(Self.displayID(screen)) != 0))
                changed = true
            }
        }
        if changed { store.settings.displays = known }
    }

    func targetScreens() -> [NSScreen] {
        let s = AppStore.shared.settings
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return [] }
        switch s.screensMode {
        case .all:
            return screens
        case .one:
            if let pref = s.preferredDisplay, let match = screens.first(where: { Self.stableID($0) == pref }) { return [match] }
            return [screens.first { CGDisplayIsBuiltin(Self.displayID($0)) != 0 } ?? NSScreen.main ?? screens[0]]
        case .attached:
            for d in s.displays where d.attached {
                if let match = screens.first(where: { Self.stableID($0) == d.id }) { return [match] }
            }
            return []
        }
    }

    func rebuild() {
        registerDisplays()
        let targets = targetScreens()
        let ids = Set(targets.map(Self.stableID))
        for (id, w) in windows where !ids.contains(id) {
            w.teardown()
            windows[id] = nil
        }
        for screen in targets {
            let id = Self.stableID(screen)
            if let w = windows[id] { w.update(screen: screen) } else {
                let w = DockWindow(screen: screen, id: id)
                windows[id] = w
                w.configure()
            }
        }
        evaluateFullscreen()
    }

    /// Dock on the display under the pointer (or any).
    var activeWindow: DockWindow? {
        let mouse = NSEvent.mouseLocation
        return windows.values.first { NSMouseInRect(mouse, $0.screen.frame, false) } ?? windows.values.first
    }

    func window(for id: String) -> DockWindow? { windows[id] }

    // MARK: Visibility

    func toggleVisibility() {
        let store = AppStore.shared
        store.dockHidden.toggle()
        for w in windows.values {
            if store.dockHidden { w.hide(animated: true) } else { w.show(animated: true) }
        }
    }

    func resetLayout() {
        let store = AppStore.shared
        var s = store.settings
        s.screensMode = .one
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) {
            s.preferredDisplay = Self.stableID(screen)
        }
        s.scenario = .floating
        s.floatingOrigins = [:]
        s.hideDuringFullscreen = false
        s.hideOnWindowHover = false
        store.dockHidden = false
        store.settings = s
        SystemDock.shared.restore()
        rebuild()
        windows.values.forEach { $0.show(animated: true) }
    }

    /// Hides docks on displays that currently show a fullscreen app.
    func evaluateFullscreen() {
        let s = AppStore.shared.settings
        guard s.hideDuringFullscreen else {
            windows.values.forEach { $0.setSuppressed(false) }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            let covered = FullscreenDetector.fullscreenScreens()
            for w in DockController.shared.windows.values {
                w.setSuppressed(covered.contains(DockController.displayID(w.screen)))
            }
        }
    }

    private func configureOverlapWatch() {
        overlapTimer?.invalidate()
        overlapTimer = nil
        guard AppStore.shared.settings.hideOnWindowHover else {
            windows.values.forEach { if $0.suppressedByOverlap { $0.suppressedByOverlap = false; $0.show(animated: true) } }
            return
        }
        overlapTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            MainActor.assumeIsolated {
                for w in DockController.shared.windows.values where !w.model.hovering {
                    let overlapping = FullscreenDetector.windowOverlaps(w.panel.frame, screen: w.screen)
                    if overlapping != w.suppressedByOverlap {
                        w.suppressedByOverlap = overlapping
                        if overlapping { w.hide(animated: true) } else if !AppStore.shared.settings.scenario.isReveal { w.show(animated: true) }
                    }
                }
            }
        }
        overlapTimer?.tolerance = 0.3
    }
}

@MainActor
enum FullscreenDetector {
    private static func windows() -> [[String: Any]] {
        (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
    }

    static func fullscreenScreens() -> Set<CGDirectDisplayID> {
        let me = ProcessInfo.processInfo.processIdentifier
        var result = Set<CGDirectDisplayID>()
        let list = windows()
        for screen in NSScreen.screens {
            let id = DockController.displayID(screen)
            let bounds = CGDisplayBounds(id)
            for info in list {
                guard (info[kCGWindowLayer as String] as? Int) == 0,
                      (info[kCGWindowOwnerPID as String] as? Int32) != me,
                      let b = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
                let rect = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
                if rect.equalTo(bounds) || (rect.contains(bounds) && rect.width >= bounds.width) {
                    result.insert(id)
                    break
                }
            }
        }
        return result
    }

    /// Whether another app's normal window overlaps a dock frame (AppKit coordinates).
    static func windowOverlaps(_ frame: NSRect, screen: NSScreen) -> Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        guard let primary = NSScreen.screens.first else { return false }
        let cgRect = CGRect(x: frame.minX, y: primary.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
        for info in windows() {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? Int32) != me,
                  let b = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let rect = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            if rect.width > 80 && rect.height > 80 && rect.intersects(cgRect) { return true }
        }
        return false
    }
}
