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
    /// The Dock plate inside the hosting view (top-left origin), measured by `DockPlate`. Read imperatively by
    /// Reserve Dock Space and Hide on Window Hover, so changes don't re-render anything.
    @ObservationIgnored var plateFrame: CGRect = .zero

    init(screenID: String) { self.screenID = screenID }

    /// Hidden with "Pause widgets while CoolDock is hidden" on: the strip is unmounted (timers and services stop)
    /// and an empty frame of its last size keeps the footprint.
    var widgetsPaused: Bool { !revealed && AppStore.shared.settings.pauseWhenHidden && lastStripSize != .zero }
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
    private var suppressed = false // fullscreen
    /// Hide on Window Hover: transparent and click-through while another app's window overlaps the Dock.
    private(set) var windowFaded = false

    var isSuppressed: Bool { suppressed }

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
        return Self.frame(settings, screenID: screenID, size: size, visible: screen.visibleFrame, full: screen.frame, revealed: revealed)
    }

    /// Where the Dock panel goes for the Layout settings (scenario, position, alignment, edge distance, floating origin)
    /// on a display with `full` and `visible` frames. Hidden reveal scenarios park the panel just off the edge.
    nonisolated static func frame(_ settings: Settings, screenID: String, size: CGSize, visible vf: NSRect, full: NSRect, revealed: Bool) -> NSRect {
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
        if panel.frame != frame {
            panel.setFrame(frame, display: true, animate: false)
            DockController.shared.dockGeometryChanged()
        }
    }

    /// The Dock plate on screen (AppKit coordinates). Falls back to the panel minus the shadow margin before the
    /// plate has been measured.
    var plateScreenFrame: NSRect {
        let f = panel.frame
        let p = model.plateFrame
        guard p.width > 1, p.height > 1, p.maxX <= f.width + 1, p.maxY <= f.height + 1 else {
            let inset: (CGFloat, CGFloat) = settings.shadow ? (14, 10) : (0, 0)
            return f.insetBy(dx: inset.0, dy: inset.1)
        }
        return NSRect(x: f.minX + p.minX, y: f.maxY - p.maxY, width: p.width, height: p.height)
    }

    // MARK: Triggers

    private func installTrigger() {
        let scenario = settings.scenario
        let needsBottom = scenario == .revealBottom || scenario == .replaceAutoHide || scenario == .swapBottom
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
        if settings.hideOnWindowHover { DockController.shared.stepWindowHover() }
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
        let alpha = restingAlpha
        panel.ignoresMouseEvents = windowFaded
        defer { DockController.shared.dockGeometryChanged() }
        if !panel.isVisible {
            var start = target
            if animated && settings.animations { start = targetFrame(revealed: false) }
            if settings.scenario.isReveal == false && start == target { panel.alphaValue = animated ? 0 : alpha }
            panel.setFrame(start, display: false)
            panel.orderFrontRegardless()
        }
        guard animated && settings.animations else {
            panel.alphaValue = alpha
            panel.setFrame(target, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            panel.animator().alphaValue = alpha
            panel.animator().setFrame(target, display: true)
        }
    }

    /// Opacity of a shown Dock: 0 while Hide on Window Hover has faded it.
    private var restingAlpha: CGFloat { windowFaded ? 0 : 1 }

    /// Hide on Window Hover: fades the Dock out (clicks pass through to the window underneath) or back in. The panel
    /// stays ordered in and keeps its frame, so only opacity changes.
    func setWindowFaded(_ faded: Bool) {
        guard faded != windowFaded else { return }
        windowFaded = faded
        guard isShown, panel.isVisible else { return }
        panel.ignoresMouseEvents = faded
        let alpha = restingAlpha
        guard settings.animations else {
            panel.alphaValue = alpha
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = faded ? 0.24 : 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: faded ? .easeIn : .easeOut)
            panel.animator().alphaValue = alpha
        }
    }

    func hide(animated: Bool) {
        isShown = false
        panel.ignoresMouseEvents = true
        defer { DockController.shared.dockGeometryChanged() }
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

    /// Fullscreen suppression independent of scenario.
    func setSuppressed(_ value: Bool) {
        guard value != suppressed else { return }
        suppressed = value
        if value { hide(animated: true) } else if !settings.scenario.isReveal { show(animated: true) }
    }

    // MARK: Floating drag

    private var dragStart: (mouse: NSPoint, origin: NSPoint)?
    var isBeingDragged: Bool { dragStart != nil }

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
    private var lastScenario: LayoutScenario?

    // Hide on Window Hover
    private var hoverBoard = HoverHideBoard()
    private var overlapping: Set<String> = []
    private var overlapPoll: Timer?
    private var hoverWake: Timer?
    private var hoverWakeAt: TimeInterval?
    private var pointerMonitors: [Any] = []
    private var overlapRefreshWork: DispatchWorkItem?

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
                MainActor.assumeIsolated {
                    DockController.shared.evaluateFullscreen()
                    DockController.shared.windowsMayHaveChanged(after: 0.3)
                }
            })
        }
        for name in [NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            observers.append(wnc.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { DockController.shared.windowsMayHaveChanged(after: 0.3) }
            })
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(wnc.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { DockController.shared.rebuild() }
            })
        }
        DockSpaceReserver.shared.reservations = { DockController.shared.dockReservations() }
        lastScenario = AppStore.shared.settings.scenario
        rebuild()
        configureOverlapWatch()
        configureReserve()
    }

    private func settingsChanged() {
        let s = AppStore.shared.settings
        if s.scenario != lastScenario {
            SystemDock.shared.apply(for: s.scenario)
            lastScenario = s.scenario
        }
        rebuild()
        configureOverlapWatch()
        configureReserve()
    }

    /// A Dock moved, resized, appeared or disappeared.
    func dockGeometryChanged() {
        DockSpaceReserver.shared.dockGeometryChanged()
        if AppStore.shared.settings.hideOnWindowHover { windowsMayHaveChanged(after: 0.1) }
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
        let screens = NSScreen.screens
        let ids = screens.map(Self.stableID)
        let builtIn = screens.first { CGDisplayIsBuiltin(Self.displayID($0)) != 0 }.map(Self.stableID)
        let targets = Self.targetIDs(AppStore.shared.settings, connected: ids, builtIn: builtIn, main: NSScreen.main.map(Self.stableID))
        return targets.compactMap { id in screens.first { Self.stableID($0) == id } }
    }

    /// Displays (stable ids, in `connected` order) that get a Dock under Settings → Screens. One Display: the preferred
    /// display, else the built-in one, else the main one. Attached Displays: the first attached display in the list
    /// that is connected, or none.
    nonisolated static func targetIDs(_ s: Settings, connected: [String], builtIn: String?, main: String?) -> [String] {
        guard let first = connected.first else { return [] }
        switch s.screensMode {
        case .all:
            return connected
        case .one:
            if let pref = s.preferredDisplay, connected.contains(pref) { return [pref] }
            return [builtIn ?? main ?? first]
        case .attached:
            return s.displays.first { $0.attached && connected.contains($0.id) }.map { [$0.id] } ?? []
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

    // MARK: Reserve Dock Space

    private func configureReserve() {
        let s = AppStore.shared.settings
        // Auto-hiding layouts leave the screen to the windows, like the auto-hiding macOS Dock.
        DockSpaceReserver.shared.configure(enabled: s.reservesDockSpace && !s.scenario.isReveal, afterDragging: s.reservesAfterDragging)
        DockSpaceReserver.shared.dockGeometryChanged()
    }

    /// Room each visible Dock keeps free, in Quartz coordinates. Hidden, suppressed and auto-hiding Docks reserve nothing.
    func dockReservations() -> [DockReservation] {
        let s = AppStore.shared.settings
        guard s.reservesDockSpace, !s.scenario.isReveal, !AppStore.shared.dockHidden,
              let primary = NSScreen.screens.first?.frame.maxY else { return [] }
        return windows.values.compactMap { w in
            guard w.isShown, !w.isSuppressed, w.panel.isVisible else { return nil }
            return DockReservation(displayID: w.screenID,
                                   screen: ReserveSpace.quartz(w.screen.frame, primaryHeight: primary),
                                   visible: ReserveSpace.quartz(w.screen.visibleFrame, primaryHeight: primary),
                                   dock: ReserveSpace.quartz(w.plateScreenFrame, primaryHeight: primary),
                                   edge: w.plateTop ? .top : .bottom)
        }
        .sorted { $0.displayID < $1.displayID }
    }

    // MARK: Hide on Window Hover
    //
    // Per display: a Dock fades out (opacity only, panel stays put, clicks pass through) while another app's window
    // overlaps its plate, and comes back when the overlap ends or the pointer rests on the Dock area (`HoverHideMachine`).
    // Overlap comes from one `CGWindowListCopyWindowInfo` pass (~1 ms): on Accessibility window events when trusted, on
    // app / Space switches, and from a 1 s poll (tolerance 0.4 s) that only runs while the option is on. Pointer
    // monitors are installed only while some Dock is faded or peeking.

    private func configureOverlapWatch() {
        let on = AppStore.shared.settings.hideOnWindowHover && !RenderHarness.isActive
        guard on else {
            guard overlapPoll != nil || !overlapping.isEmpty || hoverBoard.needsPointerTracking else { return }
            overlapPoll?.invalidate()
            overlapPoll = nil
            WindowEventHub.shared.unsubscribe("hover")
            overlapping.removeAll()
            hoverBoard.reset()
            setPointerTracking(false)
            scheduleHoverWake(nil)
            windows.values.forEach { $0.setWindowFaded(false) }
            return
        }
        if overlapPoll == nil {
            let t = Timer(timeInterval: 1.0, repeats: true) { _ in
                MainActor.assumeIsolated { DockController.shared.refreshOverlap() }
            }
            t.tolerance = 0.4
            RunLoop.main.add(t, forMode: .common)
            overlapPoll = t
            WindowEventHub.shared.subscribe("hover") { event in
                // Moves arrive many times a second during a drag; one refresh per burst is enough.
                DockController.shared.windowsMayHaveChanged(after: event.kind == .resync ? 0 : 0.08)
            }
        }
        refreshOverlap()
    }

    /// Re-reads window overlap shortly (coalesced).
    func windowsMayHaveChanged(after delay: TimeInterval) {
        guard overlapPoll != nil else { return }
        overlapRefreshWork?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { DockController.shared.refreshOverlap() } }
        overlapRefreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func refreshOverlap() {
        guard overlapPoll != nil, let primary = NSScreen.screens.first?.frame.maxY else { return }
        var plates: [String: CGRect] = [:]
        for (id, w) in windows where w.isShown && w.panel.isVisible {
            plates[id] = ReserveSpace.quartz(w.plateScreenFrame, primaryHeight: primary)
        }
        overlapping = plates.isEmpty ? [] : FullscreenDetector.docksOverlapped(plates)
        stepWindowHover()
    }

    /// Feeds the current overlap and pointer state to every display's machine and applies the result.
    func stepWindowHover(pointerBusy: Bool = false) {
        guard overlapPoll != nil else { return }
        let store = AppStore.shared
        let mouse = NSEvent.mouseLocation
        let busy = pointerBusy || NSEvent.pressedMouseButtons != 0
        let holdAll = Panels.shared.isOpen || store.browserOpen || NSApp.modalWindow != nil
        var inputs: [String: HoverHideMachine.Input] = [:]
        for (id, w) in windows {
            let plate = w.plateScreenFrame.insetBy(dx: -2, dy: -2)
            let inside = NSMouseInRect(mouse, plate, false)
            inputs[id] = HoverHideMachine.Input(overlap: overlapping.contains(id), pointerInside: inside, pointerBusy: inside && busy,
                                                holdOpen: holdAll || w.isBeingDragged)
        }
        let phases = hoverBoard.step(inputs, now: ProcessInfo.processInfo.systemUptime)
        for (id, phase) in phases { windows[id]?.setWindowFaded(phase == .faded) }
        setPointerTracking(hoverBoard.needsPointerTracking)
        scheduleHoverWake(hoverBoard.deadline)
    }

    private func setPointerTracking(_ on: Bool) {
        if on == !pointerMonitors.isEmpty { return }
        if !on {
            pointerMonitors.forEach(NSEvent.removeMonitor)
            pointerMonitors.removeAll()
            return
        }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .otherMouseDown, .scrollWheel]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { e in
            let type = e.type
            MainActor.assumeIsolated { DockController.shared.pointerEvent(type) }
        }) { pointerMonitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { e in
            let type = e.type
            MainActor.assumeIsolated { DockController.shared.pointerEvent(type) }
            return e
        }) { pointerMonitors.append(l) }
    }

    private func pointerEvent(_ type: NSEvent.EventType) {
        // A window drag just ended: its final position decides the overlap.
        if type == .leftMouseUp { windowsMayHaveChanged(after: 0.05) }
        stepWindowHover(pointerBusy: type != .mouseMoved)
    }

    private func scheduleHoverWake(_ at: TimeInterval?) {
        guard at != hoverWakeAt else { return }
        hoverWake?.invalidate()
        hoverWake = nil
        hoverWakeAt = at
        guard let at else { return }
        let delay = max(0.01, at - ProcessInfo.processInfo.systemUptime)
        hoverWake = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated {
                DockController.shared.hoverWakeAt = nil
                DockController.shared.hoverWake = nil
                DockController.shared.stepWindowHover()
            }
        }
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

    /// Ids of the Docks (plates in Quartz coordinates) that another app's visible normal window overlaps.
    /// One window-list pass for every display.
    static func docksOverlapped(_ plates: [String: CGRect]) -> Set<String> {
        let me = ProcessInfo.processInfo.processIdentifier
        var hit = Set<String>()
        for info in windows() {
            if hit.count == plates.count { break }
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? Int32) != me,
                  ((info[kCGWindowAlpha as String] as? Double) ?? 1) > 0.05,
                  let b = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let rect = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            for (id, plate) in plates where !hit.contains(id) && WindowOverlap.overlaps(rect, dock: plate) { hit.insert(id) }
        }
        return hit
    }
}
