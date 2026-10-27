import AppKit
import ApplicationServices
import Foundation
import Testing
@testable import CoolDock

// Accessibility code paths end to end against real windows. A process needs no Accessibility permission to drive
// its own windows, so the test process opens windows of its own ("AX Probe A", "AX Probe B", …) and hands its own pid
// to NiceDock's real functions: the same AX calls the Window Manager, the window list, the app menu, window events
// and Dock badges make on other apps (which do need the permission; apart from the pid the code path is identical).
// Opt-in, because it puts windows on screen for a few seconds and briefly shows the test runner in the Dock:
//
//     COOLDOCK_LIVE_AX=1 swift test --filter AXLive
//
// It never touches another app's windows: every action gets entries filtered to this process.
// See docs/verification/apps/accessibility-live.md.
//
// The main run loop. AppKit stops the main run loop to end its own waits: blocks it queues while windows move,
// resize or reorder, and the Dock's answers to minimize / restore (HIServices `_DCXTransactionComplete`). A stop ends
// whichever run is innermost. In NiceDock that is `NSApplication.run()`, which simply goes on; in the test runner it
// can be Swift's async-main `CFRunLoopRun()` (between tests), which then returns and exits the process. So:
// the tests are synchronous and pump events through `NSApp.nextEvent` (AppKit's own wait), and from the first gap
// between tests on the session runs inside a loop that keeps going when stopped, like `NSApplication.run()`
// (`axLiveInstallRunLoop`). An exit guard fails the run should it still end early.

// MARK: - Harness

/// Last step reached (reported by the exit guard).
nonisolated(unsafe) var axLiveBreadcrumb = "start"
/// True from a test's start until its windows are closed.
nonisolated(unsafe) var axLiveInTest = false
nonisolated(unsafe) var axLiveLoopRunning = false
/// Stand-in for NiceDock's Application Support folder, removed when the process exits.
nonisolated(unsafe) var axLiveSupportDir: URL?

/// Queues the session loop for the next gap between tests (a block runs at the next block pass of any run, so one
/// that comes up inside a test just queues itself again).
func axLiveInstallRunLoop() {
    CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
        guard !axLiveLoopRunning else { return }
        guard !axLiveInTest else { axLiveInstallRunLoop(); return }
        axLiveLoopRunning = true
        // Never returns: the rest of the session (the main queue included) runs in here; the runner ends the
        // process with exit() when it is done.
        while true { _ = CFRunLoopRunInMode(.defaultMode, 1e9, false) }
    }
}

@MainActor
enum AXLive {
    static let pid = ProcessInfo.processInfo.processIdentifier
    static let menuTarget = AXLiveMenuTarget()
    private static var prepared = false
    /// Every window the suite opened (closed after each test).
    static var opened: [NSWindow] = []

    /// One-time: a regular AppKit app with a main menu. `finishLaunching()` is what makes AppKit answer
    /// Accessibility requests; without it every AX call on this process fails (kAXErrorNotImplemented).
    static func prepare() {
        guard !prepared else { return }
        prepared = true
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("nicedock-axlive-\(UUID().uuidString)")
        axLiveSupportDir = support
        AppPaths.overrideDirectory = support
        AppStore.persistenceEnabled = false
        // With "Prefer tabs when opening documents: Always" (System Settings ▸ Desktop & Dock) the probe windows would
        // merge into one tab group, and only the selected tab is a window to Accessibility and CGWindowList.
        NSWindow.allowsAutomaticWindowTabbing = false
        axLiveInstallRunLoop()
        // A normal end leaves through the runner's async main; a stopped run loop leaves through the drain loop.
        atexit {
            if let dir = axLiveSupportDir { try? FileManager.default.removeItem(at: dir) }
            let stack = Thread.callStackSymbols
            guard stack.contains(where: { $0.contains("swift_task_asyncMainDrainQueue") }),
                  !stack.contains(where: { $0.contains("async_Main") }) else { return }
            fflush(stdout)
            fputs("AXLive: the test process ended early (main run loop stopped); the run is incomplete. Last step: \(axLiveBreadcrumb)\n", stderr)
            _exit(70)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        installFileMenu(plain: true)
        app.finishLaunching()
        pump(0.3)
    }

    /// File menu as the third menu-bar item (Apple, app, File), like every Cocoa app.
    static func installFileMenu(plain: Bool) {
        let main = NSMenu()
        let appItem = NSMenuItem(title: "AX Probe", action: nil, keyEquivalent: "")
        appItem.submenu = NSMenu(title: "AX Probe")
        main.addItem(appItem)
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let file = NSMenu(title: "File")
        func item(_ title: String, _ key: String, _ mods: NSEvent.ModifierFlags) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: #selector(AXLiveMenuTarget.open(_:)), keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = menuTarget
            return i
        }
        if plain {
            file.addItem(item("New Window", "n", .command))
        } else {
            // Safari with profiles: New Window ▸ one item per profile, plus New Private Window (⇧⌘N).
            let parent = NSMenuItem(title: "New Window", action: nil, keyEquivalent: "")
            let sub = NSMenu(title: "New Window")
            sub.addItem(item("New Work Window", "n", .command))
            sub.addItem(item("New Personal Window", "", []))
            parent.submenu = sub
            file.addItem(parent)
            file.addItem(item("New Private Window", "n", [.command, .shift]))
        }
        file.addItem(.separator())
        file.addItem(item("Close", "w", .command))
        fileItem.submenu = file
        main.addItem(fileItem)
        NSApp.mainMenu = main
    }

    /// Runs AppKit's event loop: window-server events, AX requests from other threads and AX observer notifications
    /// are all delivered here.
    static func pump(_ seconds: Double) {
        let until = Date().addingTimeInterval(seconds)
        repeat {
            if let e = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01), inMode: .default, dequeue: true) {
                NSApp.sendEvent(e)
            }
        } while Date() < until
    }

    /// Pumps until `condition` holds or `timeout` passes.
    @discardableResult
    static func wait(_ timeout: Double = 3, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            pump(0.02)
        }
        return condition()
    }

    static var screen: NSScreen { NSScreen.main ?? NSScreen.screens[0] }
    static var primaryHeight: CGFloat { NSScreen.screens[0].frame.height }

    /// A titled, resizable window at `frame` (Cocoa coordinates), ordered front.
    static func window(_ title: String, _ frame: CGRect, resizable: Bool = true) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        let w = NSWindow(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.animationBehavior = .none
        w.title = title
        w.setFrame(frame, display: false)
        w.orderFront(nil)
        opened.append(w)
        return w
    }

    /// A frame inside the main display's visible area, `dx`/`dy` points from its bottom-left corner.
    static func spot(_ dx: CGFloat, _ dy: CGFloat, _ w: CGFloat = 560, _ h: CGFloat = 380) -> CGRect {
        let v = screen.visibleFrame
        return CGRect(x: v.minX + dx, y: v.minY + dy, width: w, height: h)
    }

    /// Closes every probe window and lets the window server's answers arrive before the test returns.
    static func closeAll() {
        axLiveBreadcrumb = "closeAll"
        // Minimized windows are closed where they are (restoring first would leave a Dock transaction running).
        for w in opened + menuTarget.windows {
            w.orderOut(nil)
            w.close()
        }
        opened.removeAll()
        menuTarget.windows.removeAll()
        menuTarget.titles.removeAll()
        pump(0.6)
        axLiveInTest = false
    }

    /// The window in Accessibility / CoreGraphics coordinates (top-left origin, y down).
    static func axFrame(_ w: NSWindow) -> CGRect { UtilWinMath.flip(w.frame, primaryHeight: primaryHeight) }

    static func id(_ w: NSWindow) -> CGWindowID { CGWindowID(w.windowNumber) }

    /// This process's on-screen windows as NiceDock's window list sees them (pid 0 is excluded instead of NiceDock's own).
    static func entries() -> [UtilWinEntry] {
        UtilWindowService.onScreenEntries(excluding: 0).filter { $0.pid == pid }
    }

    static func entry(_ w: NSWindow) -> UtilWinEntry? { entries().first { $0.id == id(w) } }

    /// This process's window numbers in on-screen z-order, front to back.
    static func zOrder() -> [CGWindowID] {
        let infos = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        return infos.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0 else { return nil }
            return (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        }
    }

    static func axWindow(_ w: NSWindow) -> AXUIElement? { UtilAX.windows(pid).first { UtilAX.windowID($0) == id(w) } }

    static func near(_ a: CGRect, _ b: CGRect, _ tolerance: CGFloat = 1) -> Bool {
        error(a, b) <= tolerance
    }

    static func error(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(abs(a.minX - b.minX), abs(a.minY - b.minY), abs(a.width - b.width), abs(a.height - b.height))
    }

    /// Runs `work` on a background thread (as `UtilWindowService.reload()` does) while the main thread keeps
    /// serving this process's Accessibility requests.
    static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) -> T? {
        let box = AXLiveBox<T>()
        DispatchQueue.global(qos: .userInitiated).async { box.set(work()) }
        wait(10) { box.get() != nil }
        return box.get()
    }
}

final class AXLiveBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    func get() -> T? { lock.lock(); defer { lock.unlock() }; return value }
}

/// Target of the probe's File menu: every item opens a window titled after it.
@MainActor
final class AXLiveMenuTarget: NSObject {
    var windows: [NSWindow] = []
    var titles: [String] = []

    @objc func open(_ sender: NSMenuItem) {
        if sender.title == "Close" { NSApp.keyWindow?.close(); return }
        let n = windows.count + 1
        let w = NSWindow(contentRect: AXLive.spot(260 + CGFloat(n) * 24, 140, 420, 300), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.animationBehavior = .none
        w.title = "AX Probe \(sender.title) \(n)"
        w.orderFront(nil)
        windows.append(w)
        titles.append(sender.title)
    }
}

// MARK: - Expected Window Manager frames

/// Independent of `UtilWinMath`: the layouts as a table of unit edges (left, right, top, bottom; y down from the top
/// of the area), placed with each edge rounded on its own.
enum AXLiveExpect {
    static func unit(_ a: UtilWinAction) -> (CGFloat, CGFloat, CGFloat, CGFloat)? {
        let t: CGFloat = 1 / 3
        switch a {
        case .leftHalf: return (0, 0.5, 0, 1)
        case .rightHalf: return (0.5, 1, 0, 1)
        case .topHalf: return (0, 1, 0, 0.5)
        case .bottomHalf: return (0, 1, 0.5, 1)
        case .maximize: return (0, 1, 0, 1)
        case .leftThird: return (0, t, 0, 1)
        case .centerThird: return (t, 2 * t, 0, 1)
        case .rightThird: return (2 * t, 1, 0, 1)
        case .leftTwoThirds: return (0, 2 * t, 0, 1)
        case .rightTwoThirds: return (t, 1, 0, 1)
        case .topLeft: return (0, 0.5, 0, 0.5)
        case .topRight: return (0.5, 1, 0, 0.5)
        case .bottomLeft: return (0, 0.5, 0.5, 1)
        case .bottomRight: return (0.5, 1, 0.5, 1)
        case .center, .nextDisplay: return nil
        }
    }

    /// Cocoa frame the window must end up with, nil when the action does not apply.
    static func frame(_ a: UtilWinAction, window: CGRect, area: CGRect) -> CGRect? {
        if let (l, r, t, b) = unit(a) {
            let x0 = (area.minX + l * area.width).rounded(), x1 = (area.minX + r * area.width).rounded()
            let top = (area.maxY - t * area.height).rounded(), bottom = (area.maxY - b * area.height).rounded()
            return CGRect(x: x0, y: bottom, width: x1 - x0, height: top - bottom)
        }
        if a == .center {
            let w = min(window.width, area.width), h = min(window.height, area.height)
            return CGRect(x: (area.midX - w / 2).rounded(), y: (area.midY - h / 2).rounded(), width: w.rounded(), height: h.rounded())
        }
        // Next Display: nothing to move to on one display; with more, the move itself is unit-tested math.
        return nil
    }
}

// MARK: - Badge fixture

/// A Dock-shaped accessibility tree inside a probe window: an AXList of items that carry `AXURL` and (some)
/// `AXStatusLabel`, like the macOS Dock's application items.
final class AXLiveDockList: NSView {
    var items: [AXLiveDockItem] = []
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .list }
    override func accessibilityChildren() -> [Any]? { items }
}

final class AXLiveDockItem: NSAccessibilityElement {
    static let statusLabel = NSAccessibility.Attribute(rawValue: "AXStatusLabel")
    static let dockItem = NSAccessibility.Role(rawValue: "AXDockItem")
    let url: URL
    let label: String?

    init(_ path: String, _ label: String?, parent: NSView) {
        url = URL(fileURLWithPath: path)
        self.label = label
        super.init()
        setAccessibilityParent(parent)
        setAccessibilityRole(Self.dockItem)
        setAccessibilityFrameInParentSpace(NSRect(x: 0, y: 0, width: 40, height: 40))
    }

    override func accessibilityAttributeNames() -> [NSAccessibility.Attribute] {
        var names: [NSAccessibility.Attribute] = [.role, .parent, .url, .position, .size]
        if label != nil { names.append(Self.statusLabel) }
        return names
    }

    override func accessibilityAttributeValue(_ attribute: NSAccessibility.Attribute) -> Any? {
        switch attribute {
        case Self.statusLabel: return label
        case .url: return url
        case .role: return Self.dockItem.rawValue
        case .parent: return accessibilityParent()
        case .position: return NSValue(point: accessibilityFrame().origin)
        case .size: return NSValue(size: accessibilityFrame().size)
        default: return nil
        }
    }
}

// MARK: - Suite

@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["COOLDOCK_LIVE_AX"] == "1"))
struct AXLiveTests {
    init() {
        axLiveInTest = true
        AXLive.prepare()
        axLiveBreadcrumb = "init"
    }

    // MARK: Listing

    @Test func windowListTitlesIDsAndFrames() throws {
        defer { AXLive.closeAll() }
        let b = AXLive.window("AX Probe B", AXLive.spot(260, 160))
        let a = AXLive.window("AX Probe A", AXLive.spot(120, 90))
        let fixed = AXLive.window("AX Probe Fixed", AXLive.spot(420, 40, 360, 240), resizable: false)
        a.orderFront(nil)
        #expect(AXLive.wait { AXLive.axWindow(a) != nil && AXLive.axWindow(b) != nil && AXLive.axWindow(fixed) != nil })

        // AX window → CGWindowID through _AXUIElementGetWindow, frames in AX coordinates, lookups by id and by frame.
        for w in [a, b, fixed] {
            let el = try #require(UtilAX.window(pid: AXLive.pid, id: AXLive.id(w), frame: .zero))
            #expect(UtilAX.windowID(el) == AXLive.id(w))
            #expect(UtilAX.frame(el) == AXLive.axFrame(w))
            let byFrame = try #require(UtilAX.window(pid: AXLive.pid, id: 0, frame: AXLive.axFrame(w)))
            #expect(UtilAX.windowID(byFrame) == AXLive.id(w), "frame fallback when the id is unknown")
        }
        #expect(UtilAX.window(pid: AXLive.pid, id: 0, frame: CGRect(x: 1, y: 1, width: 7, height: 7)) == nil)

        // CGWindowList: front to back, this process's windows only when NiceDock's own pid is excluded.
        let entries = AXLive.entries()
        let ids = entries.map(\.id)
        #expect(Set(ids).isSuperset(of: [AXLive.id(a), AXLive.id(b), AXLive.id(fixed)]))
        #expect(ids.firstIndex(of: AXLive.id(a))! < ids.firstIndex(of: AXLive.id(b))!, "A was ordered in front of B")
        for w in [a, b] {
            let e = try #require(AXLive.entry(w))
            #expect(e.frame == AXLive.axFrame(w) && e.appName == NSRunningApplication.current.localizedName && !e.minimized)
        }
        #expect(!UtilWindowService.onScreenEntries(excluding: AXLive.pid).contains { $0.pid == AXLive.pid }, "own windows are skipped")

        // The panel's Accessibility snapshot, taken off the main thread as `reload()` does.
        let pid = AXLive.pid
        let started = Date()
        let snap = try #require(AXLive.offMain { UtilAX.snapshot(pids: [pid], focusedPID: pid) })
        let snapTime = Date().timeIntervalSince(started)
        let infos = snap.windows[pid] ?? []
        for w in [a, b, fixed] {
            let info = try #require(infos.first { $0.id == AXLive.id(w) })
            #expect(info.title == w.title && !info.minimized && info.frame == AXLive.axFrame(w))
        }
        #expect(snap.focused.map { [AXLive.id(a), AXLive.id(b), AXLive.id(fixed)].contains($0) } == true)

        // Titles come from AXTitle even when CGWindowList has none (no Screen Recording).
        let untitled = entries.map { e -> UtilWinEntry in var e = e; e.title = nil; return e }
        UtilWindowService.shared.merge(untitled, snap)
        let group = try #require(UtilWindowService.shared.groups.first { $0.pid == pid })
        #expect(group.windows.first { $0.id == AXLive.id(a) }?.title == "AX Probe A")
        #expect(group.windows.first { $0.id == AXLive.id(b) }?.title == "AX Probe B")
        #expect(UtilWindowService.shared.focusedID == snap.focused)

        // The app menu's reader: standard windows in the app's order, with the main one marked.
        let menuWindows = AppsAX.windows(pid)
        #expect(Set(menuWindows.map(\.title)).isSuperset(of: ["AX Probe A", "AX Probe B", "AX Probe Fixed"]))
        #expect(menuWindows.allSatisfy { !$0.minimized } && menuWindows.filter(\.main).count <= 1)

        // What Reserve Dock Space reads before it moves a window.
        let elA = try #require(AXLive.axWindow(a)), elFixed = try #require(AXLive.axWindow(fixed))
        let info = try #require(AXWindowInfo.snapshot(elA))
        #expect(info.standard && info.canMove && info.canResize && !info.minimized && !info.fullscreen && info.frame == AXLive.axFrame(a))
        let fixedInfo = try #require(AXWindowInfo.snapshot(elFixed))
        #expect(fixedInfo.canMove && !fixedInfo.canResize)
        print("AXLive list: \(entries.count) own windows listed, snapshot of \(infos.count) windows in \(Int(snapTime * 1000)) ms")
    }

    // MARK: Window Manager

    @Test func everyLayoutLandsOnTheExpectedFrame() throws {
        defer { AXLive.closeAll() }
        let start = AXLive.spot(150, 120, 640, 420)
        let a = AXLive.window("AX Probe A", start)
        #expect(AXLive.wait { AXLive.entry(a) != nil })

        // No NiceDock Dock in the test process: the usable area is the display's visible frame.
        let screens = NSScreen.screens
        #expect(UtilWindowService.screens() == screens.map { UtilWinScreen(frame: $0.frame, usable: $0.visibleFrame) })
        let area = AXLive.screen.visibleFrame

        var worst: CGFloat = 0
        var off: [String] = []
        for action in UtilWinAction.allCases {
            a.setFrame(start, display: false)
            #expect(AXLive.wait { AXLive.entry(a)?.frame == AXLive.axFrame(a) })
            let entry = try #require(AXLive.entry(a))
            let expected = AXLiveExpect.frame(action, window: start, area: area)
            let applied = UtilWinActions.apply(action, to: entry)
            if action == .nextDisplay && screens.count > 1 {
                // The destination is the (unit-tested) move math; here it only has to leave this display.
                #expect(applied)
                #expect(AXLive.wait { a.screen != AXLive.screen }, "\(action)")
                continue
            }
            #expect(applied == (expected != nil), "\(action)")
            let target = expected ?? start
            let landed = AXLive.wait { AXLive.near(a.frame, target) }
            #expect(landed, "\(action): \(a.frame) ≠ \(target)")
            AXLive.pump(0.05)
            let error = AXLive.error(a.frame, target)
            if error > 0 { off.append("\(action.rawValue) \(a.frame) vs \(target)") }
            worst = max(worst, error)
            // AppKit clamps a window resized through Accessibility to end 1 pt above the visible bottom (no ordering
            // of size and position avoids it); every other edge lands exactly.
            #expect(a.frame.minX == target.minX && a.frame.width == target.width && a.frame.maxY == target.maxY, "\(action)")
            #expect(a.frame.minY == target.minY || (target.minY == area.minY && a.frame.minY == area.minY + 1), "\(action)")
        }

        // The tile buttons act on the app's focused window.
        a.setFrame(start, display: false)
        let focused = try #require(UtilAX.focusedWindow(AXLive.pid))
        #expect(UtilAX.windowID(focused) == AXLive.id(a))
        #expect(UtilWinActions.apply(.rightHalf, toFocusedWindowOf: AXLive.pid))
        let right = AXLiveExpect.frame(.rightHalf, window: start, area: area)!
        #expect(AXLive.wait { AXLive.near(a.frame, right) })
        print("AXLive layouts: \(UtilWinAction.allCases.count) actions on \(screens.count) display(s), visible \(area), worst error \(worst) pt \(off)")
    }

    @Test func layoutsKeepClearOfADockedNiceDock() throws {
        defer { AXLive.closeAll() }
        let start = AXLive.spot(150, 120, 640, 420)
        let a = AXLive.window("AX Probe A", start)
        #expect(AXLive.wait { AXLive.entry(a) != nil })
        let s = AXLive.screen
        let visible = s.visibleFrame
        // A NiceDock docked at the bottom (86 pt tall, 4 pt margin), then one under the menu bar.
        let bottomDock = CGRect(x: visible.midX - 320, y: visible.minY + 4, width: 640, height: 86)
        let topDock = CGRect(x: visible.midX - 320, y: visible.maxY - 84, width: 640, height: 80)
        for (dock, usable) in [(bottomDock, CGRect(x: visible.minX, y: visible.minY + 90, width: visible.width, height: visible.height - 90)),
                               (topDock, CGRect(x: visible.minX, y: visible.minY, width: visible.width, height: visible.height - 84))] {
            let screens = NSScreen.screens.map { scr in
                UtilWinScreen(frame: scr.frame, usable: scr == s ? UtilWinMath.usable(visible: scr.visibleFrame, dock: dock) : scr.visibleFrame)
            }
            for action in [UtilWinAction.maximize, .leftHalf, .bottomRight] {
                a.setFrame(start, display: false)
                #expect(AXLive.wait { AXLive.entry(a)?.frame == AXLive.axFrame(a) })
                let entry = try #require(AXLive.entry(a))
                #expect(UtilWinActions.apply(action, to: entry, screens: screens))
                let expected = AXLiveExpect.frame(action, window: start, area: usable)!
                #expect(AXLive.wait { AXLive.near(a.frame, expected) }, "\(action) with dock \(dock): \(a.frame) ≠ \(expected)")
                #expect(!a.frame.insetBy(dx: 0.5, dy: 0.5).intersects(dock), "\(action) overlaps the dock")
            }
        }
    }

    @Test func enhancedUserInterfaceIsRestoredAfterAMove() throws {
        defer { AXLive.closeAll() }
        let a = AXLive.window("AX Probe A", AXLive.spot(150, 120))
        #expect(AXLive.wait { AXLive.entry(a) != nil })
        let app = UtilAX.app(AXLive.pid)
        UtilAX.setBool(app, "AXEnhancedUserInterface", true)
        defer { UtilAX.setBool(app, "AXEnhancedUserInterface", false) }
        let enhanced = UtilAX.bool(app, "AXEnhancedUserInterface")
        let entry = try #require(AXLive.entry(a))
        #expect(UtilWinActions.apply(.leftHalf, to: entry))
        let expected = AXLiveExpect.frame(.leftHalf, window: a.frame, area: AXLive.screen.visibleFrame)!
        #expect(AXLive.wait { AXLive.near(a.frame, expected) })
        // Switched off for the move and back on afterwards (when the app keeps the flag at all).
        #expect(UtilAX.bool(app, "AXEnhancedUserInterface") == enhanced)
        print("AXLive enhanced UI: app reports \(String(describing: enhanced)) after setting it")
    }

    @Test func raiseMinimizeRestoreAndClose() throws {
        defer { AXLive.closeAll() }
        let b = AXLive.window("AX Probe B", AXLive.spot(260, 160))
        let a = AXLive.window("AX Probe A", AXLive.spot(120, 90))
        a.orderFront(nil)
        #expect(AXLive.wait { AXLive.zOrder().prefix(2) == [AXLive.id(a), AXLive.id(b)] })
        let entryA = try #require(AXLive.entry(a)), entryB = try #require(AXLive.entry(b))
        let pid = AXLive.pid

        // Bring to Front: B (behind A) moves in front and becomes the main window.
        #expect(UtilWinActions.raise(entryB))
        #expect(AXLive.wait { AXLive.zOrder().first == AXLive.id(b) }, "z-order \(AXLive.zOrder())")
        #expect(AXLive.wait { AppsAX.windows(pid).first(where: \.main)?.title == "AX Probe B" })

        // The app menu's window item: raise A (the menu then activates the app, which is not done here).
        let menuA = try #require(AppsAX.windows(pid).first { $0.title == "AX Probe A" })
        AppsAX.raise(menuA)
        #expect(AXLive.wait { AXLive.zOrder().first == AXLive.id(a) })
        #expect(AXLive.wait { AppsAX.windows(pid).first(where: \.main)?.title == "AX Probe A" })

        // Minimize: the window leaves the screen, and the panel lists it at the end of its app, minimized.
        var started = Date()
        #expect(UtilWinActions.setMinimized(entryA, true))
        #expect(AXLive.wait(5) { a.isMiniaturized })
        let minimizeTime = Date().timeIntervalSince(started)
        #expect(AXLive.wait { AXLive.entry(a) == nil })
        let snap = try #require(AXLive.offMain { UtilAX.snapshot(pids: [pid], focusedPID: nil) })
        #expect(snap.windows[pid]?.first { $0.id == AXLive.id(a) }?.minimized == true)
        UtilWindowService.shared.merge(AXLive.entries(), snap)
        let listed = try #require(UtilWindowService.shared.groups.first { $0.pid == pid }?.windows)
        let minimized = try #require(listed.first { $0.id == AXLive.id(a) })
        #expect(minimized.minimized && minimized.title == "AX Probe A" && listed.last?.id == minimized.id)

        // Restore from the panel's entry. macOS activates the app as the window comes back from the Dock.
        started = Date()
        #expect(UtilWinActions.setMinimized(minimized, false))
        #expect(AXLive.wait(5) { !a.isMiniaturized && a.isVisible })
        let restoreTime = Date().timeIntervalSince(started)
        #expect(AXLive.wait { AXLive.entry(a) != nil })

        // Bring to Front on a minimized window restores it, brings it forward and makes it the main window. (Where
        // AppKit leaves it once a restore-triggered activation of the app lands is up to AppKit; see the doc.)
        #expect(UtilWinActions.setMinimized(entryB, true))
        #expect(AXLive.wait(5) { b.isMiniaturized })
        var minimizedB = entryB
        minimizedB.minimized = true
        #expect(UtilWinActions.raise(minimizedB))
        #expect(AXLive.wait(5) { !b.isMiniaturized && b.isVisible && AXLive.zOrder().first == AXLive.id(b) })
        #expect(AXLive.wait { AppsAX.windows(pid).first(where: \.main)?.title == "AX Probe B" })
        AXLive.pump(0.8)

        // Close Window presses the window's close button.
        #expect(UtilWinActions.close(entryB))
        #expect(AXLive.wait { !b.isVisible && AXLive.axWindow(b) == nil && AXLive.entry(b) == nil })
        #expect(a.isVisible)
        print("AXLive minimize \(Int(minimizeTime * 1000)) ms, restore \(Int(restoreTime * 1000)) ms")
    }

    @Test func layoutOnAMinimizedWindowRestoresAndPlacesIt() throws {
        defer { AXLive.closeAll() }
        let start = AXLive.spot(150, 120, 640, 420)
        let a = AXLive.window("AX Probe A", start)
        #expect(AXLive.wait { AXLive.entry(a) != nil })
        var entry = try #require(AXLive.entry(a))
        #expect(UtilWinActions.setMinimized(entry, true))
        #expect(AXLive.wait(5) { a.isMiniaturized })
        entry.minimized = true
        #expect(UtilWinActions.apply(.leftHalf, to: entry))
        let expected = AXLiveExpect.frame(.leftHalf, window: start, area: AXLive.screen.visibleFrame)!
        #expect(AXLive.wait(5) { !a.isMiniaturized && AXLive.near(a.frame, expected) }, "\(a.frame) ≠ \(expected), minimized \(a.isMiniaturized)")
        // Still there once the restore animation is over.
        AXLive.pump(0.8)
        #expect(AXLive.near(a.frame, expected), "\(a.frame) ≠ \(expected)")
    }

    @Test func arrangeAllTilesThisProcessWindows() throws {
        defer { AXLive.closeAll() }
        let windows = (0..<4).map { i in AXLive.window("AX Probe \(["A", "B", "C", "D"][i])", AXLive.spot(80 + CGFloat(i) * 70, 60 + CGFloat(i) * 40, 500, 340)) }
        windows.reversed().forEach { $0.orderFront(nil) }
        #expect(AXLive.wait { AXLive.zOrder().prefix(4) == windows.map(AXLive.id)[...] })
        let entries = AXLive.entries()
        #expect(entries.map(\.id) == windows.map(AXLive.id))
        #expect(UtilWinActions.arrange(entries, focusedPID: AXLive.pid))
        let area = AXLive.screen.visibleFrame
        // Two rows of two, frontmost top left; edges rounded independently.
        let expected: [CGRect] = [(0, 0.5, 0, 0.5), (0.5, 1, 0, 0.5), (0, 0.5, 0.5, 1), (0.5, 1, 0.5, 1)].map { l, r, t, b in
            let x0 = (area.minX + l * area.width).rounded(), x1 = (area.minX + r * area.width).rounded()
            let top = (area.maxY - t * area.height).rounded(), bottom = (area.maxY - b * area.height).rounded()
            return CGRect(x: x0, y: bottom, width: x1 - x0, height: top - bottom)
        }
        #expect(AXLive.wait { zip(windows, expected).allSatisfy { AXLive.near($0.frame, $1) } },
                "\(windows.map(\.frame)) ≠ \(expected)")
    }

    // MARK: App menu

    @Test func appMenuWindowListAndNewWindow() throws {
        defer { AXLive.closeAll(); AXLive.installFileMenu(plain: true) }
        AXLive.installFileMenu(plain: true)
        let b = AXLive.window("AX Probe B", AXLive.spot(260, 160))
        let a = AXLive.window("AX Probe A", AXLive.spot(120, 90))
        a.orderFront(nil)
        let pid = AXLive.pid
        #expect(AXLive.wait { AppsAX.windows(pid).count >= 2 })
        #expect(AppsAX.responsive(pid))

        // The File menu as AX reports it (Apple, app, File): New Window ⌘N.
        let file = try #require(AppsAX.fileMenu(pid))
        let item = try #require(AppsAX.newWindowItem(file, bundleID: nil))
        #expect(item.title == "New Window" && item.key == "N" && item.modifiers == 0 && item.enabled)

        // The right-click menu with Accessibility: one item per window (main one checked), then New Window.
        let menu = AppsAppMenu.build(.init(app: .current), trusted: true)
        let titles = menu.items.map(\.title)
        let windows = AppsAX.windows(pid)
        #expect(Array(titles.prefix(windows.count)) == windows.map(\.title))
        #expect(titles.contains("AX Probe A") && titles.contains("AX Probe B"))
        if let main = windows.first(where: \.main) {
            #expect(menu.items.first { $0.title == main.title }?.state == .on)
        }
        #expect(menu.items.first { $0.title == L("New Window") }?.isEnabled == true)
        // Without it: no window list, no File-menu New Window, and the Options submenu offers the permission.
        // The real entry point: this process is not trusted, so it builds the same menu.
        #expect(!AppsAX.trusted)
        let plain = AppsAppMenu.build(.init(app: .current))
        #expect(!plain.items.contains { $0.title.hasPrefix("AX Probe") || $0.title == L("New Window") })
        #expect(plain.items.first { $0.title == L("Options") }?.submenu?.items.contains { $0.title == L("Show Windows & Badges…") } == true)

        // New Window: the menu item's command, pressed through Accessibility.
        let before = AppsAX.windows(pid).count
        #expect(AppsAX.pressNewWindow(pid, bundleID: nil))
        #expect(AXLive.wait { AXLive.menuTarget.titles == ["New Window"] })
        let created = try #require(AXLive.menuTarget.windows.first)
        #expect(AXLive.wait { AppsAX.windows(pid).count == before + 1 && AXLive.entry(created) != nil })
        #expect(AppsAX.windows(pid).contains { $0.title == "AX Probe New Window 1" })
        _ = b
    }

    @Test func safariStyleProfileAndPrivateWindowItems() throws {
        defer { AXLive.closeAll(); AXLive.installFileMenu(plain: true) }
        AXLive.installFileMenu(plain: false)
        let pid = AXLive.pid
        let file = try #require(AppsAX.fileMenu(pid))
        // A "New Window ▸" submenu resolves to its ⌘N child; profiles are the submenu's items; private is ⇧⌘N.
        #expect(AppsAX.newWindowItem(file, bundleID: nil)?.title == "New Work Window")
        #expect(AppsAX.profileWindowItems(file).map(\.title) == ["New Work Window", "New Personal Window"])
        let privateItem = try #require(AppsAX.privateWindowItem(file))
        #expect(privateItem.title == "New Private Window")
        #expect(AppsAX.press(privateItem))
        let personal = try #require(AppsAX.profileWindowItems(file).first { $0.title == "New Personal Window" })
        #expect(AppsAX.press(personal))
        #expect(AppsAX.pressNewWindow(pid, bundleID: nil))
        #expect(AXLive.wait { AXLive.menuTarget.titles.count == 3 })
        #expect(AXLive.menuTarget.titles == ["New Private Window", "New Personal Window", "New Work Window"])
    }

    // MARK: Window events

    @Test func windowEventsFromRealWindows() throws {
        let hub = WindowEventHub.shared
        let log = AXLiveEventLog()
        hub.subscribe("axlive") { log.events.append($0) }
        defer {
            hub.forget(AXLive.pid)
            hub.unsubscribe("axlive")
            AXLive.closeAll()
        }
        let a = AXLive.window("AX Probe A", AXLive.spot(120, 90))
        #expect(AXLive.wait { AXLive.axWindow(a) != nil })
        // Not trusted here, so the hub itself does not run; the observer is attached to this process directly.
        #expect(!hub.isRunning)
        #expect(hub.attach(AXLive.pid))
        #expect(hub.observedPIDs.contains(AXLive.pid))
        #expect(hub.allWindows().contains { $0.pid == AXLive.pid && UtilAX.windowID($0.window) == AXLive.id(a) })

        func events(_ kind: WindowEventHub.Kind, _ w: NSWindow) -> [WindowEventHub.Event] {
            log.events.filter { $0.kind == kind && $0.pid == AXLive.pid && $0.window.flatMap(UtilAX.windowID) == AXLive.id(w) }
        }

        // Each change arrives once (the app element already delivers its windows' notifications).
        func settledCount(_ kind: WindowEventHub.Kind, _ w: NSWindow) -> Int {
            AXLive.wait { !events(kind, w).isEmpty }
            AXLive.pump(0.4)
            return events(kind, w).count
        }

        // Moved by the app itself.
        log.events.removeAll()
        a.setFrameOrigin(NSPoint(x: a.frame.minX + 40, y: a.frame.minY + 30))
        let moves = settledCount(.moved, a)
        #expect(moves == 1, "events per move")
        #expect(events(.moved, a).allSatisfy { !$0.mouseDown })

        // Resized and moved through AXWindowInfo (Reserve Dock Space's setters).
        let el = try #require(AXLive.axWindow(a))
        log.events.removeAll()
        #expect(AXWindowInfo.setSize(el, CGSize(width: 610, height: 405)))
        let resizes = settledCount(.resized, a)
        #expect(resizes == 1, "events per resize")
        #expect(a.frame.size == CGSize(width: 610, height: 405))
        let origin = CGPoint(x: AXLive.axFrame(a).minX + 25, y: AXLive.axFrame(a).minY + 15)
        log.events.removeAll()
        #expect(AXWindowInfo.setPosition(el, origin))
        #expect(settledCount(.moved, a) == 1)
        #expect(AXLive.axFrame(a).origin == origin && AXWindowInfo.frame(el)?.origin == origin)

        // A new window: "created", and it is watched from then on.
        log.events.removeAll()
        let b = AXLive.window("AX Probe B", AXLive.spot(300, 150))
        #expect(AXLive.wait { !events(.created, b).isEmpty })
        #expect(hub.allWindows().contains { UtilAX.windowID($0.window) == AXLive.id(b) })
        b.setFrameOrigin(NSPoint(x: b.frame.minX + 20, y: b.frame.minY))
        #expect(AXLive.wait { !events(.moved, b).isEmpty })

        // Minimized and restored: "restored".
        b.miniaturize(nil)
        #expect(AXLive.wait(5) { b.isMiniaturized })
        log.events.removeAll()
        b.deminiaturize(nil)
        #expect(AXLive.wait(5) { !events(.restored, b).isEmpty })
        AXLive.pump(0.8)
        let restores = events(.restored, b).count
        #expect(restores == 1, "events per restore")

        // Closed: no longer among the hub's windows.
        b.close()
        #expect(AXLive.wait { !hub.allWindows().contains { UtilAX.windowID($0.window) == AXLive.id(b) } })
        print("AXLive events: per change \(moves) moved, \(resizes) resized, \(restores) restored")
    }

    // MARK: Dock badges

    @Test func dockBadgesDegradeCleanlyAndParseADockShapedTree() throws {
        defer { AXLive.closeAll() }
        // Without Accessibility the reader returns nothing at once and never asks: the system's prompt agent
        // (universalAccessAuthWarn, resident) shows no window.
        func promptWindows() -> Int {
            let infos = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
            return infos.filter { (($0[kCGWindowOwnerName as String] as? String) ?? "").lowercased().contains("universalaccess") }.count
        }
        let promptsBefore = promptWindows()
        var started = Date()
        #expect(!AXIsProcessTrusted())
        #expect(AppsDockBadges.read() == nil)
        let gateTime = Date().timeIntervalSince(started)
        #expect(gateTime < 0.1)
        // The Dock itself refuses this process (kAXErrorAPIDisabled): no labels, no hang, no crash.
        let dock = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first)
        started = Date()
        #expect(AppsDockBadges.labels(in: AppsAX.app(dock.processIdentifier, timeout: 0.5)).isEmpty)
        let refusedTime = Date().timeIntervalSince(started)
        #expect(refusedTime < 0.6)
        #expect(!AppsAX.responsive(dock.processIdentifier))
        AXLive.pump(1)
        #expect(promptWindows() == promptsBefore, "no Accessibility prompt appeared")
        #expect(!AXIsProcessTrusted())

        // The same parser over a Dock-shaped tree served by this process: AXList ▸ items with AXURL and AXStatusLabel.
        let w = AXLive.window("AX Probe Dock", AXLive.spot(200, 100, 420, 120))
        let list = AXLiveDockList(frame: NSRect(x: 0, y: 0, width: 420, height: 120))
        list.items = [AXLiveDockItem("/System/Applications/Mail.app", "12", parent: list),
                      AXLiveDockItem("/System/Applications/Messages.app", nil, parent: list),
                      AXLiveDockItem("/Applications/Safari.app/", "•", parent: list),
                      AXLiveDockItem("/System/Applications/Calendar.app", "", parent: list)]
        w.contentView = list
        #expect(AXLive.wait { AXLive.axWindow(w) != nil })
        let root = try #require(AXLive.axWindow(w))
        let labels = AppsDockBadges.labels(in: root)
        #expect(labels == ["/System/Applications/Mail.app": "12", "/Applications/Safari.app": "•"])
        #expect(AppsBadgeLabel.format(labels["/System/Applications/Mail.app"], number: { "\($0)" }) == "12")
        print("AXLive badges: gate \(Int(gateTime * 1000)) ms, Dock refused in \(Int(refusedTime * 1000)) ms, synthetic tree \(labels.count) labels")
    }
}

@MainActor
final class AXLiveEventLog {
    var events: [WindowEventHub.Event] = []
}
