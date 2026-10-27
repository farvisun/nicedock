import AppKit
import ApplicationServices
import Carbon
import SwiftUI

// Dock-style right-click menu for apps: window list, New Window / private / profile windows, app-specific actions,
// Open Recent, Options ▸ (Keep in Dock, Open at Login, Show in Finder), Show All Windows, Hide, Quit (⌥ Force Quit).
// It's a real NSMenu, built when the menu opens, so ⌥ swaps Quit for Force Quit live and the window list is current.

// MARK: - NSMenu building

/// Closure behind a menu item (kept alive by the item's `representedObject`; `target` is weak).
private final class AppsMenuAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire(_ sender: Any?) { run() }
}

@MainActor
final class AppsMenuBuilder {
    let menu: NSMenu

    init(title: String = "") {
        menu = NSMenu(title: title)
        menu.autoenablesItems = false
        if AppStore.shared.layoutDirection == .rightToLeft { menu.userInterfaceLayoutDirection = .rightToLeft }
    }

    @discardableResult
    func item(_ title: String, checked: Bool = false, image: NSImage? = nil, _ action: (() -> Void)?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.keyEquivalentModifierMask = []
        if let action {
            let box = AppsMenuAction(action)
            item.target = box
            item.action = #selector(AppsMenuAction.fire(_:))
            item.representedObject = box
        }
        item.isEnabled = action != nil
        item.state = checked ? .on : .off
        item.image = image
        menu.addItem(item)
        return item
    }

    /// ⌥ variant of the previous item, swapped in while Option is held (Quit → Force Quit).
    func alternate(_ title: String, _ action: @escaping () -> Void) {
        let alt = item(title, action)
        alt.keyEquivalentModifierMask = .option
        alt.isAlternate = true
    }

    func separator() {
        if let last = menu.items.last, !last.isSeparatorItem { menu.addItem(.separator()) }
    }

    /// Adds a submenu; omitted when the builder adds nothing.
    func submenu(_ title: String, image: NSImage? = nil, _ build: (AppsMenuBuilder) -> Void) {
        let sub = AppsMenuBuilder(title: title)
        build(sub)
        let built = sub.finish()
        guard !built.items.isEmpty else { return }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = built
        item.image = image
        menu.addItem(item)
    }

    func finish() -> NSMenu {
        while let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) }
        while let first = menu.items.first, first.isSeparatorItem { menu.removeItem(first) }
        return menu
    }
}

/// Pops up a menu of choices at the mouse (panel sort / filter chips).
@MainActor
enum AppsPopUp {
    static func show(_ build: (AppsMenuBuilder) -> Void) {
        guard !AppsEnv.rendering else { return }
        let b = AppsMenuBuilder()
        build(b)
        let menu = b.finish()
        guard !menu.items.isEmpty else { return }
        if let event = NSApp.currentEvent, let view = event.window?.contentView {
            menu.popUp(positioning: nil, at: view.convert(event.locationInWindow, from: nil), in: view)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }
}

// MARK: - Right-click anchor

/// Transparent overlay that takes right-clicks (and ⌃-clicks) only, shows the native menu, and appends the
/// widget's standard SwiftUI items (Customize…, Widgets…, Remove) from the context menu underneath.
final class AppsMenuAnchorView: NSView {
    var build: (@MainActor () -> NSMenu?)?

    /// Only a right-click (or ⌃-click) that is happening now lands here; everything else (clicks, hover, drops,
    /// tooltips) goes to the SwiftUI tile underneath. The age check ignores a stale `currentEvent`.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent, ProcessInfo.processInfo.systemUptime - event.timestamp < 1 else { return nil }
        let menuClick = event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        return menuClick ? super.hitTest(point) : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func rightMouseDown(with event: NSEvent) { present(event) }
    override func mouseDown(with event: NSEvent) { present(event) }

    private func present(_ event: NSEvent) {
        guard let menu = build?() else { return }
        var borrowed: (menu: NSMenu, items: [NSMenuItem])?
        if let host = hostingView(), let standard = host.menu(for: event), standard !== menu, !standard.items.isEmpty {
            let items = standard.items
            standard.removeAllItems()
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            items.forEach(menu.addItem)
            borrowed = (standard, items)
        }
        guard !menu.items.isEmpty else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
        // Hand SwiftUI its items back (unless it rebuilt the menu meanwhile).
        if let borrowed {
            for item in borrowed.items where item.menu === menu { menu.removeItem(item) }
            if borrowed.menu.items.isEmpty { borrowed.items.forEach(borrowed.menu.addItem) }
        }
    }

    private func hostingView() -> NSView? {
        var view = superview
        while let current = view {
            if String(describing: type(of: current)).contains("HostingView") { return current }
            view = current.superview
        }
        return nil
    }
}

private struct AppsMenuAnchor: NSViewRepresentable {
    let build: @MainActor () -> NSMenu?
    func makeNSView(context: Context) -> AppsMenuAnchorView { AppsMenuAnchorView() }
    func updateNSView(_ view: AppsMenuAnchorView, context: Context) { view.build = build }
}

extension View {
    /// Native right-click menu built when it opens. No-op in the render harness.
    @ViewBuilder
    func appsNativeMenu(_ build: @escaping @MainActor () -> NSMenu?) -> some View {
        if AppsEnv.rendering { self } else { overlay(AppsMenuAnchor(build: build)) }
    }

    /// The Dock-style app menu for one app (pinned tile, running app, folder or switcher cell).
    func appsAppMenu(_ context: @escaping @MainActor () -> AppsAppMenu.Context) -> some View {
        appsNativeMenu { AppsAppMenu.build(context()) }
    }
}

// MARK: - Accessibility (windows, menu bar)

/// Accessibility reads of other apps. All calls use a short messaging timeout so a hung app can't stall the dock.
/// Nothing here prompts: callers check `trusted` and only `requestTrust()` after an explicit click.
enum AppsAX {
    static var trusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func app(_ pid: pid_t, timeout: Float = 0.25) -> AXUIElement {
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, timeout)
        return el
    }

    /// Whether the app answers Accessibility queries at all (within the timeout).
    static func responsive(_ pid: pid_t) -> Bool {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(app(pid), kAXRoleAttribute as CFString, &v) == .success
    }

    static func value(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v
    }

    static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        guard let v = value(el, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func elements(_ el: AXUIElement, _ attr: String) -> [AXUIElement] {
        (value(el, attr) as? [AXUIElement]) ?? []
    }

    static func string(_ el: AXUIElement, _ attr: String) -> String? { value(el, attr) as? String }
    static func bool(_ el: AXUIElement, _ attr: String) -> Bool? { (value(el, attr) as? NSNumber)?.boolValue }

    // Windows

    struct Window {
        let element: AXUIElement
        let title: String
        let minimized: Bool
        let main: Bool
    }

    /// The app's standard windows and dialogs, in the app's own (front-to-back) order.
    static func windows(_ pid: pid_t) -> [Window] {
        let app = app(pid)
        let main = element(app, kAXMainWindowAttribute)
        return elements(app, kAXWindowsAttribute).compactMap { win in
            let sub = string(win, kAXSubroleAttribute)
            guard sub == nil || sub == kAXStandardWindowSubrole || sub == kAXDialogSubrole else { return nil }
            return Window(element: win, title: string(win, kAXTitleAttribute) ?? "",
                          minimized: bool(win, kAXMinimizedAttribute) ?? false, main: main.map { CFEqual($0, win) } ?? false)
        }
    }

    /// Brings one window forward (un-minimizing it) and activates its app.
    @MainActor static func raise(_ w: Window, of app: NSRunningApplication) {
        raise(w)
        AppsLaunch.activate(app)
    }

    /// The Accessibility half of `raise(_:of:)`: un-minimize, make it the main window, raise it.
    static func raise(_ w: Window) {
        if w.minimized { AXUIElementSetAttributeValue(w.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
        AXUIElementSetAttributeValue(w.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(w.element, kAXRaiseAction as CFString)
    }

    // Menu bar

    struct MenuItem {
        let element: AXUIElement
        let title: String
        /// Key equivalent, uppercased ("N").
        let key: String
        /// AX modifier bits: 0 = ⌘ only, 1 = ⇧⌘, 2 = ⌥⌘, 4 = ⌃⌘.
        let modifiers: Int
        let enabled: Bool
        let children: [MenuItem]
    }

    /// Items of the app's third menu-bar menu (File; Shell in Terminal), one submenu level deep.
    static func fileMenu(_ pid: pid_t) -> [MenuItem]? {
        let app = app(pid)
        guard let bar = element(app, kAXMenuBarAttribute) else { return nil }
        let tops = elements(bar, kAXChildrenAttribute)
        guard tops.count > 2, let menu = elements(tops[2], kAXChildrenAttribute).first else { return nil }
        return items(of: menu, depth: 1)
    }

    private static func items(of menu: AXUIElement, depth: Int) -> [MenuItem] {
        let attrs = [kAXTitleAttribute, kAXMenuItemCmdCharAttribute, kAXMenuItemCmdModifiersAttribute, kAXEnabledAttribute] as CFArray
        return elements(menu, kAXChildrenAttribute).compactMap { el in
            var raw: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(el, attrs, AXCopyMultipleAttributeOptions(rawValue: 0), &raw) == .success,
                  let values = raw as? [Any], values.count == 4 else { return nil }
            let title = values[0] as? String ?? ""
            guard !title.isEmpty else { return nil }
            let children = depth > 0 ? (elements(el, kAXChildrenAttribute).first.map { items(of: $0, depth: depth - 1) } ?? []) : []
            return MenuItem(element: el, title: title, key: (values[1] as? String ?? "").uppercased(),
                            modifiers: (values[2] as? NSNumber)?.intValue ?? 0, enabled: (values[3] as? NSNumber)?.boolValue ?? true,
                            children: children)
        }
    }

    static func first(_ items: [MenuItem], where match: (MenuItem) -> Bool) -> MenuItem? {
        for item in items {
            if match(item) { return item }
            if let hit = first(item.children, where: match) { return hit }
        }
        return nil
    }

    @discardableResult
    static func press(_ item: MenuItem) -> Bool { AXUIElementPerformAction(item.element, kAXPressAction as CFString) == .success }

    /// Presses the app's own New Window command (File menu). No trust check: the caller makes it.
    @discardableResult
    static func pressNewWindow(_ pid: pid_t, bundleID: String?) -> Bool {
        guard let items = fileMenu(pid), let item = newWindowItem(items, bundleID: bundleID) else { return false }
        return press(item)
    }

    /// "New Window" in the languages NiceDock ships (apps follow the system language): both words must appear.
    private static let windowWords: [(String, String)] = [
        ("new", "window"), ("neu", "fenster"), ("nouvelle", "fenêtre"), ("nueva", "ventana"), ("nuova", "finestra"),
        ("nova", "janela"), ("yeni", "pencere"), ("нов", "окно"), ("新建", "窗口"), ("新規", "ウインドウ"), ("新規", "ウィンドウ"),
        ("جدید", "پنجره"), ("جديدة", "نافذة")
    ]
    private static let privateWords = ["private", "privat", "privé", "privada", "privata", "incognito", "inprivate", "gizli",
                                       "приват", "инкогнито", "无痕", "隐私", "プライベート", "シークレット", "خصوصی", "خاصة"]

    static func isNewWindow(_ title: String) -> Bool {
        let t = title.lowercased()
        return windowWords.contains { t.contains($0.0) && t.contains($0.1) } && !privateWords.contains { t.contains($0) }
    }

    /// The menu item that opens a plain new window (a "New Window ▸" submenu resolves to its ⌘N child).
    static func newWindowItem(_ items: [MenuItem], bundleID: String?) -> MenuItem? {
        var hit = first(items) { $0.enabled && isNewWindow($0.title) }
        if hit == nil, let id = bundleID, let sc = AppsKnownApps.windowShortcuts[id] {
            hit = first(items) { $0.enabled && $0.key == sc.key && $0.modifiers == (sc.shift ? 1 : 0) }
        }
        if let parent = hit, !parent.children.isEmpty {
            hit = parent.children.first { $0.key == "N" && $0.modifiers == 0 } ?? parent.children.first { $0.enabled }
        }
        return hit
    }

    /// Safari's File ▸ New Private Window (⇧⌘N).
    static func privateWindowItem(_ items: [MenuItem]) -> MenuItem? {
        first(items) { $0.enabled && $0.key == "N" && $0.modifiers == 1 }
    }

    /// Safari profiles: with profiles, File ▸ New Window is a submenu of "New <Profile> Window" items.
    static func profileWindowItems(_ items: [MenuItem]) -> [MenuItem] {
        guard let parent = first(items, where: { isNewWindow($0.title) && !$0.children.isEmpty }) else { return [] }
        return parent.children.filter { $0.enabled && !privateWords.contains(where: $0.title.lowercased().contains) }
    }
}

// MARK: - Open at Login

/// Login items through System Events, the supported way to add *other* apps (SMAppService only registers the
/// caller's own app and helpers; LSSharedFileList is deprecated and ignored for session login items since macOS 13).
/// It needs a one-time Automation consent for System Events, so nothing is read until the user has used the
/// feature once or consent is already granted; the checkmark shows the last known state.
@MainActor
final class AppsLoginItems {
    static let shared = AppsLoginItems()
    private(set) var paths: Set<String>?
    private var busy = false
    private var checkedAt = Date.distantPast
    private static let consentKey = "AppsLoginItemsConsent"
    private static let systemEvents = "com.apple.systemevents"

    func isEnabled(_ path: String) -> Bool { paths?.contains(Self.normalize(path)) ?? false }

    func refresh(force: Bool = false) {
        guard !AppsEnv.rendering, !busy, force || Date().timeIntervalSince(checkedAt) > 15 else { return }
        guard force || UserDefaults.standard.bool(forKey: Self.consentKey) || Self.automationAllowed() else { return }
        busy = true
        Task {
            let result = await Script.run("tell application id \"com.apple.systemevents\" to get the path of every login item")
            self.busy = false
            self.checkedAt = Date()
            if let result { self.paths = Self.parse(result) }
        }
    }

    func set(_ path: String, enabled: Bool) {
        let p = Script.escape(Self.normalize(path))
        let source = enabled
            ? "tell application id \"com.apple.systemevents\" to make login item at end with properties {path:\"\(p)\", hidden:false}"
            : "tell application id \"com.apple.systemevents\" to delete (every login item whose path is \"\(p)\" or path is \"\(p)/\")"
        Task {
            if await Script.run(source) != nil {
                UserDefaults.standard.set(true, forKey: Self.consentKey)
                var known = self.paths ?? []
                if enabled { known.insert(Self.normalize(path)) } else { known.remove(Self.normalize(path)) }
                self.paths = known
            }
            self.busy = false
            self.refresh(force: true)
        }
    }

    static func parse(_ d: NSAppleEventDescriptor) -> Set<String> {
        guard d.numberOfItems > 0 else { return d.stringValue.map { [normalize($0)] } ?? [] }
        return Set((1...d.numberOfItems).compactMap { d.atIndex($0)?.stringValue }.map(normalize))
    }

    static func normalize(_ path: String) -> String {
        var s = (path as NSString).standardizingPath
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// Automation consent for System Events, checked without asking (only answerable while it runs).
    private static func automationAllowed() -> Bool {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: systemEvents).isEmpty else { return false }
        let target = NSAppleEventDescriptor(bundleIdentifier: systemEvents)
        return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false) == 0
    }
}

// MARK: - Commands

@MainActor
enum AppsAppCommands {
    private static func openTool(_ args: [String]) {
        guard !AppsEnv.rendering else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = args
        try? p.run()
    }

    static func chromium(_ spec: AppsChromium, path: String, _ launch: AppsChromium.Launch) {
        openTool(spec.openArguments(appPath: path, launch))
    }

    /// New window on the current Space: the app's own File ▸ New Window command (Accessibility), Safari via
    /// AppleScript without it, or a plain launch when the app isn't running.
    static func newWindow(path: String, app: NSRunningApplication?, bundleID: String?) {
        if let spec = AppsChromium.spec(bundleID) { chromium(spec, path: path, .newWindow); return }
        guard let app, !app.isTerminated else { AppsLaunch.open(path); return }
        if AppsAX.trusted, AppsAX.pressNewWindow(app.processIdentifier, bundleID: bundleID) {
            activateSoon(app)
        } else if let id = bundleID, AppsKnownApps.safari.contains(id) {
            Task {
                _ = await Script.run("tell application id \"\(Script.escape(id))\"\nmake new document\nactivate\nend tell")
            }
        } else if !AppsAX.trusted {
            AppsAX.requestTrust()
        } else {
            AppsLaunch.activate(app)
        }
    }

    /// Safari's File ▸ New Private Window (⇧⌘N), launching Safari first when needed.
    static func safariPrivateWindow(path: String, bundleID: String) {
        guard AppsAX.trusted else { AppsAX.requestTrust(); return }
        pressWhenReady(path: path, bundleID: bundleID, find: AppsAX.privateWindowItem)
    }

    /// One of Safari's "New <Profile> Window" items, by title.
    static func safariProfileWindow(path: String, bundleID: String, title: String) {
        guard AppsAX.trusted else { AppsAX.requestTrust(); return }
        pressWhenReady(path: path, bundleID: bundleID) { items in
            AppsAX.profileWindowItems(items).first { $0.title == title }
        }
    }

    private static func pressWhenReady(path: String, bundleID: String, find: @escaping ([AppsAX.MenuItem]) -> AppsAX.MenuItem?) {
        Task {
            if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty { AppsLaunch.open(path) }
            for _ in 0..<24 {
                if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first, app.isFinishedLaunching,
                   let items = AppsAX.fileMenu(app.processIdentifier), let item = find(items) {
                    if AppsAX.press(item) { activateSoon(app) }
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private static func activateSoon(_ app: NSRunningApplication) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { AppsLaunch.activate(app) }
    }

    static func newMessage(path: String) {
        let bundle = Bundle(path: path)
        let url = AppsKnownApps.composeURL(bundleID: bundle?.bundleIdentifier ?? "", schemes: AppsKnownApps.schemes(bundle))
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: path), configuration: cfg)
    }

    static func newDocument(bundleID: String) {
        Task { _ = await Script.run("tell application id \"\(Script.escape(bundleID))\"\nmake new document\nactivate\nend tell") }
    }

    /// App Exposé for the app: activate it, then ask Mission Control for "application windows".
    static func showAllWindows(_ app: NSRunningApplication) {
        AppsLaunch.activate(app)
        let tool = "/System/Applications/Mission Control.app/Contents/MacOS/Mission Control"
        guard FileManager.default.isExecutableFile(atPath: tool) else {
            app.activate(options: [.activateAllWindows])
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = ["2"]
            try? p.run()
        }
    }
}

// MARK: - The app menu

@MainActor
enum AppsAppMenu {
    struct Context {
        var path: String?
        var app: NSRunningApplication?
        /// App Folder widget the app is shown in (adds Options ▸ Remove from Folder).
        var folder: UUID? = nil
        /// Shown from a pop-up panel: close it before acting.
        var inPanel = false
    }

    static func build(_ ctx: Context) -> NSMenu {
        // Renders never read other apps (window titles are personal data).
        build(ctx, trusted: !AppsEnv.rendering && AppsAX.trusted)
    }

    /// The menu with Accessibility reads (window list, File menu) on or off. `build(_:)` passes the real trust; the
    /// live tests pass `true` for the test process itself, whose windows need no permission.
    static func build(_ ctx: Context, trusted: Bool) -> NSMenu {
        let b = AppsMenuBuilder()
        let path = ctx.path.map(AppsLaunch.resolve) ?? ctx.app?.bundleURL?.path
        let app = ctx.app.flatMap { $0.isTerminated ? nil : $0 } ?? path.flatMap(AppsLaunch.running)
        let id = app?.bundleIdentifier ?? path.flatMap(AppsLaunch.bundleID)
        let finder = id == "com.apple.finder"
        func run(_ action: @escaping () -> Void) -> () -> Void {
            { if ctx.inPanel { Panels.shared.close() }; action() }
        }

        // One cheap probe first: a hung app costs a single short timeout, not one per query.
        let readable = app.map { trusted && AppsAX.responsive($0.processIdentifier) } ?? false

        if let app, readable {
            for w in AppsAX.windows(app.processIdentifier).prefix(24) {
                b.item(w.title.isEmpty ? (app.localizedName ?? "") : w.title, checked: w.main, run { AppsAX.raise(w, of: app) })
            }
            b.separator()
        }

        if let path {
            let fileMenu = (readable && AppsChromium.spec(id) == nil) ? app.flatMap { AppsAX.fileMenu($0.processIdentifier) } : nil
            actions(b, path: path, app: app, id: id, fileMenu: fileMenu, run: run)
            b.separator()
            b.submenu(L("Options")) { o in
                options(o, path: path, running: app != nil, folder: ctx.folder, trusted: trusted, login: !finder, run: run)
            }
            b.separator()
        }

        if let app {
            b.item(L("Show All Windows"), run { AppsAppCommands.showAllWindows(app) })
            if app.isHidden { b.item(L("Show"), run { app.unhide() }) } else { b.item(L("Hide"), run { app.hide() }) }
            // Like the Dock, Finder can't be quit from here.
            if !finder {
                b.item(L("Quit"), run { app.terminate() })
                b.alternate(L("Force Quit"), run { app.forceTerminate() })
            }
        } else if let path {
            b.item(L("Open"), run { AppsLaunch.open(path) })
        }
        AppsLoginItems.shared.refresh()
        return b.finish()
    }

    private static func actions(_ b: AppsMenuBuilder, path: String, app: NSRunningApplication?, id: String?, fileMenu: [AppsAX.MenuItem]?,
                                run: (@escaping () -> Void) -> () -> Void) {
        if let spec = AppsChromium.spec(id) {
            b.item(L("New Window"), run { AppsAppCommands.chromium(spec, path: path, .newWindow) })
            b.item(spec.localizedPrivateTitle, run { AppsAppCommands.chromium(spec, path: path, .privateWindow) })
            let profiles = spec.profiles()
            if profiles.count > 1 {
                b.submenu(L("New Window with Profile")) { s in
                    for p in profiles { s.item(p.name, run { AppsAppCommands.chromium(spec, path: path, .profile(p.directory)) }) }
                }
            }
        } else if let id, AppsKnownApps.safari.contains(id) {
            b.item(L("New Window"), run { AppsAppCommands.newWindow(path: path, app: app, bundleID: id) })
            b.item(L("New Private Window"), run { AppsAppCommands.safariPrivateWindow(path: path, bundleID: id) })
            let profiles = fileMenu.map(AppsAX.profileWindowItems) ?? []
            if profiles.count > 1 {
                b.submenu(L("New Window with Profile")) { s in
                    for p in profiles { s.item(p.title, run { AppsAppCommands.safariProfileWindow(path: path, bundleID: id, title: p.title) }) }
                }
            }
        } else if offersNewWindow(id: id, running: app != nil, fileMenu: fileMenu) {
            b.item(L("New Window"), run { AppsAppCommands.newWindow(path: path, app: app, bundleID: id) })
        }
        if let id, AppsKnownApps.mail.contains(id) {
            b.item(L("New Message"), run { AppsAppCommands.newMessage(path: path) })
        }
        if let id, AppsKnownApps.documents.contains(id) {
            b.item(L("New Document"), run { AppsAppCommands.newDocument(bundleID: id) })
        }
        if let id {
            let recents = AppsRecentDocs.entries(bundleID: id)
            if !recents.isEmpty {
                b.submenu(L("Open Recent")) { s in
                    for r in recents { s.item(r.name, image: IconCache.icon(path: r.url.path, size: 16), run { AppsLaunch.open([r.url], with: path) }) }
                }
            }
        }
    }

    /// Known window apps always; others only when their File menu has a New Window command (needs Accessibility).
    private static func offersNewWindow(id: String?, running: Bool, fileMenu: [AppsAX.MenuItem]?) -> Bool {
        if let id, AppsKnownApps.windowShortcuts[id] != nil { return running || id == AppsKnownApps.notion }
        guard running, let fileMenu else { return false }
        return AppsAX.newWindowItem(fileMenu, bundleID: id) != nil
    }

    private static func options(_ o: AppsMenuBuilder, path: String, running: Bool, folder: UUID?, trusted: Bool, login: Bool,
                                run: (@escaping () -> Void) -> () -> Void) {
        let pins = AppsLaunch.pinned(path)
        let unpin = { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { pins.forEach(AppStore.shared.removeWidget) } }
        if pins.isEmpty {
            o.item(L("Keep in Dock"), run { AppStore.shared.addWidget(.app, config: ["path": path]) })
        } else if running {
            o.item(L("Keep in Dock"), checked: true, run(unpin))
        } else {
            o.item(L("Remove from Dock"), run(unpin))
        }
        if let folder {
            o.item(L("Remove from Folder"), run {
                AppStore.shared.updateWidget(folder) { inst in
                    inst.config["apps"] = inst.list("apps").filter { AppsLaunch.resolve($0) != path }.joined(separator: "\n")
                }
            })
        }
        if login {
            let on = AppsLoginItems.shared.isEnabled(path)
            o.item(L("Open at Login"), checked: on, run { AppsLoginItems.shared.set(path, enabled: !on) })
        }
        o.separator()
        o.item(L("Show in Finder"), run { Open.reveal(path) })
        if !trusted {
            o.separator()
            o.item(L("Show Windows & Badges…"), run { AppsAX.requestTrust() })
        }
    }

    /// Warms the profile and recent-document caches off the main thread so the menu opens instantly.
    static func prefetch(_ path: String) {
        guard !AppsEnv.rendering, let id = AppsLaunch.bundleID(AppsLaunch.resolve(path)) else { return }
        Task.detached(priority: .utility) {
            _ = AppsChromium.spec(id)?.profiles()
            _ = AppsRecentDocs.entries(bundleID: id)
        }
    }
}
