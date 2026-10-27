#if DEBUG
import AppKit
import ApplicationServices
import AVFoundation

/// Dev aid: `CoolDock --ui-probe [--out <file.json>] [--dump <file.json>]` runs the real app (the normal
/// `AppDelegate` launch: Dock window, menu bar item, hot keys, the Settings window) and then operates it the way a
/// screen reader or a UI-scripting tool would: through the Accessibility API on its own windows. It opens Settings,
/// selects each of the 12 panes by pressing its sidebar row, operates a control in every pane (switches, sliders,
/// segments, buttons with an in-app effect), switches the language to Persian and back, and drives the controls of
/// 15 widgets in the Dock (start/pause/reset timers, confirm reminders, type into the calculator, add and remove a
/// task and a habit, …). Each effect is read back through Accessibility and confirmed in `AppStore.shared` or the
/// widget's engine, then the previous value is restored.
///
/// Side effects stay in the process: persistence is off, the support and cache folders are `COOLDOCK_SUPPORT_DIR`
/// (else a temporary folder), copy buttons write to a private pasteboard, URLs are captured instead of opened, timer
/// alerts go to a sink (no sound, no notification permission), and every change CoolDock would make to the macOS Dock
/// is captured instead of made. (macOS still keeps the app's usual URL cache and window frames under its bundle id.) Controls with outside effects (Dock auto-hide, the "replace" layouts, Launch at Login, permission
/// requests, Reset, Export Diagnostics, Clear Cache, System Settings, the screen colour sampler, recording, the system
/// Character Viewer, Wi-Fi / Bluetooth / system toggles) are only checked for presence, never pressed.
///
/// Prints one line per pane and widget, writes the full report to `--out` (JSON), and quits through the normal
/// terminate path (`applicationWillTerminate`) with exit status 0 only when every check passed.
@MainActor
enum UIProbe {
    static private(set) var active = false
    private static var outPath: String?
    private static var dumpPath: String?
    private static var exitCode: Int32 = 1
    private static var tempSupport: URL?
    private static var started = Date()

    // Captured outside effects.
    private static var openedURLs: [String] = []
    private static var dockChanges: [String] = []
    private static var alerts: [String] = []
    private static let pasteboard = NSPasteboard(name: NSPasteboard.Name("app.cooldock.ui-probe.\(UUID().uuidString)"))

    static func prepareIfRequested() {
        let args = CommandLine.arguments
        guard args.contains("--ui-probe") else { return }
        active = true
        started = Date()
        outPath = args.firstIndex(of: "--out").flatMap { args.count > $0 + 1 ? args[$0 + 1] : nil }
        dumpPath = args.firstIndex(of: "--dump").flatMap { args.count > $0 + 1 ? args[$0 + 1] : nil }
        AppStore.persistenceEnabled = false
        if (ProcessInfo.processInfo.environment["COOLDOCK_SUPPORT_DIR"] ?? "").isEmpty {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cooldock-uiprobe-\(UUID().uuidString)", isDirectory: true)
            AppPaths.overrideDirectory = dir
            tempSupport = dir
        }
        AppPaths.overrideCacheDirectory = AppPaths.supportDirectory.appendingPathComponent("Caches", isDirectory: true)
        NSWindow.allowsAutomaticWindowTabbing = false
        Open.interceptor = { url in MainActor.assumeIsolated { openedURLs.append(url.absoluteString) } }
        SystemDock.shared.interceptor = { change in dockChanges.append(change) }
        ClockAlerts.sink = { title, body, _ in MainActor.assumeIsolated { alerts.append(title + ": " + body) } }
        UtilPasteboard.board = pasteboard
        dockPrefsBefore = dockPrefs()
        seed()
        NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                _ = Task { @MainActor in await run() }
            }
        }
        // Watchdogs: a stuck step ends the run with a report (main thread), a stuck main thread ends the process.
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
            guard !finished else { return }
            let c = Case("pane", "watchdog")
            c.fail("the probe did not finish within 120 s")
            cases.append(c)
            finish()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 180) {
            fputs("ui-probe: the main thread is stuck; exiting without the terminate path\n", stderr)
            _exit(3)
        }
    }

    static let kinds: [WidgetKind] = [.timer, .stopwatch, .pomodoro, .drinkWater, .posture, .calculator, .converter, .emoji, .colorPicker,
                                      .todo, .habitTracker, .voiceMemo, .backgroundSounds, .youtubeVideo, .quickToggles]

    /// English, the default "Fixed" layout, onboarding done, and one profile holding the widgets under test.
    /// Background Sounds plays at volume 0 so pressing it is never audible.
    private static func seed() {
        let store = AppStore.shared
        var s = store.settings
        s.onboardingDone = true
        s.language = .en
        s.scenario = .fixed
        store.settings = s
        let widgets = kinds.map { kind -> WidgetInstance in
            kind == .backgroundSounds ? WidgetInstance(kind: kind, config: ["volume": "0"]) : WidgetInstance(kind: kind)
        }
        let profile = DockProfile(name: "UI Probe", symbol: "checkmark.seal", widgets: widgets)
        store.profiles = [profile]
        store.activeProfileID = profile.id
    }

    // MARK: - Report

    @MainActor
    final class Case {
        let group: String
        let name: String
        var elements: [String] = []
        var steps: [[String: Any]] = []
        var failures: [String] = []
        var notes: [String] = []

        init(_ group: String, _ name: String) {
            self.group = group
            self.name = name
        }

        var passed: Bool { failures.isEmpty && !steps.isEmpty }

        func step(_ action: String, _ before: Any?, _ after: Any?, _ ok: Bool, _ detail: String? = nil) {
            var d: [String: Any] = ["action": action, "ok": ok]
            if let before { d["before"] = before }
            if let after { d["after"] = after }
            if let detail { d["detail"] = detail }
            steps.append(d)
            if !ok { failures.append(action + (detail.map { " — " + $0 } ?? "")) }
        }

        func fail(_ message: String) { failures.append(message) }

        var json: [String: Any] {
            ["name": name, "passed": passed, "elements": elements, "steps": steps, "failures": failures, "notes": notes]
        }
    }

    private static var cases: [Case] = []
    private static var dockPrefsBefore: [String: String] = [:]

    /// `com.apple.dock` autohide and autohide-delay as `defaults read` shows them ("absent" when unset).
    private static func dockPrefs() -> [String: String] {
        let domain = "com.apple.dock" as CFString
        CFPreferencesAppSynchronize(domain)
        var out: [String: String] = [:]
        for key in ["autohide", "autohide-delay"] {
            let v = CFPreferencesCopyAppValue(key as CFString, domain)
            out[key] = v.map { "\($0)" } ?? "absent"
        }
        return out
    }

    // MARK: - Helpers

    static func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Polls `condition` while the app keeps running (SwiftUI updates, timers, AX requests).
    @discardableResult
    static func wait(_ timeout: Double = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            await sleep(0.05)
        }
        return condition()
    }

    /// Bidi isolates (U+2066…U+2069) wrap numbers in descriptions; compare without them.
    static func clean(_ s: String?) -> String {
        (s ?? "").unicodeScalars.filter { !(0x2066...0x2069).contains($0.value) && $0.value != 0x200E && $0.value != 0x200F }
            .map(String.init).joined()
    }

    static func summary(_ el: AXUIElement) -> String {
        var parts = [ProbeAX.role(el).replacingOccurrences(of: "AX", with: "")]
        let label = clean(ProbeAX.label(el))
        if !label.isEmpty { parts.append("\"\(label)\"") }
        if let id = ProbeAX.identifier(el) { parts.append("[\(id)]") }
        if !ProbeAX.enabled(el) { parts.append("(disabled)") }
        return parts.joined(separator: " ")
    }

    // MARK: - Run

    static func run() async {
        await sleep(1.2)
        _ = await wait(5) { DockController.shared.activeWindow?.panel.isVisible == true }
        if let dumpPath {
            await dump(to: dumpPath)
        } else {
            await settingsSuite()
            await widgetSuite()
        }
        finish()
    }

    private static var finished = false

    private static func finish() {
        guard !finished else { return }
        finished = true
        Panels.shared.close()
        let dockAfter = dockPrefs()
        let dockUnchanged = dockAfter == dockPrefsBefore && dockChanges.isEmpty
        let passed = !cases.isEmpty && cases.allSatisfy(\.passed) && dockUnchanged
        let panes = cases.filter { $0.group == "pane" }
        let widgets = cases.filter { $0.group == "widget" }
        let report: [String: Any] = [
            "probe": "CoolDock --ui-probe",
            "date": ISO8601DateFormatter().string(from: started),
            "seconds": (Date().timeIntervalSince(started) * 10).rounded() / 10,
            "accessibilityTrusted": AXIsProcessTrusted(),
            "passed": passed,
            "panes": panes.map(\.json),
            "widgets": widgets.map(\.json),
            "systemDock": ["before": dockPrefsBefore, "after": dockAfter, "unchanged": dockUnchanged, "interceptedChanges": dockChanges],
            "openedURLs": openedURLs,
            "alerts": alerts,
            "summary": ["panes": "\(panes.filter(\.passed).count)/\(panes.count)", "widgets": "\(widgets.filter(\.passed).count)/\(widgets.count)"]
        ]
        if let outPath, let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: outPath))
        }
        for c in cases {
            let line = "\(c.passed ? "PASS" : "FAIL")  \(c.group) \(c.name): \(c.steps.count) steps"
                + (c.failures.isEmpty ? "" : " — " + c.failures.joined(separator: "; "))
            print(line)
        }
        print("system Dock prefs \(dockUnchanged ? "unchanged" : "CHANGED") \(dockAfter)")
        print("ui-probe: panes \(panes.filter(\.passed).count)/\(panes.count), widgets \(widgets.filter(\.passed).count)/\(widgets.count), "
              + "\(String(format: "%.1f", Date().timeIntervalSince(started))) s — \(passed ? "PASS" : "FAIL")")
        exitCode = passed ? 0 : 1
        // Close every window through Accessibility, as a user would, then quit like ⌘Q.
        for w in NSApp.windows where w.isVisible && w.styleMask.contains(.closable) {
            if let ax = ProbeAX.window(of: w), let close = ProbeAX.children(ax).first(where: { ProbeAX.subrole($0) == kAXCloseButtonSubrole }) {
                ProbeAX.press(close)
            } else {
                w.close()
            }
        }
        NSApp.terminate(nil)
    }

    /// Called at the end of `applicationWillTerminate`, after the app's own cleanup.
    static func didTerminate() {
        guard active else { return }
        pasteboard.releaseGlobally()
        if let caches = AppPaths.overrideCacheDirectory { try? FileManager.default.removeItem(at: caches) }
        if let tempSupport { try? FileManager.default.removeItem(at: tempSupport) }
        fflush(stdout)
        exit(exitCode)
    }

    /// `--dump`: the Accessibility tree of the Dock and of every Settings pane (development aid).
    private static func dump(to path: String) async {
        var out: [String: Any] = [:]
        if let ax = dockAX() { out["dock"] = ProbeAX.dump(ax) }
        for pane in SettingsPane.allCases {
            SettingsWindow.show(pane: pane)
            await sleep(0.6)
            if let ax = settingsAX() { out["settings-\(pane.rawValue)"] = ProbeAX.dump(ax) }
        }
        if let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        exitCode = 0
        NSApp.terminate(nil)
    }
}

// MARK: - Settings

extension UIProbe {
    static func settingsWindow() -> NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == "settings" && $0.isVisible }
    }

    static func settingsAX() -> AXUIElement? { settingsWindow().flatMap(ProbeAX.window(of:)) }

    /// The split view's two columns: [sidebar, detail].
    static func columns() -> (sidebar: AXUIElement, detail: AXUIElement)? {
        guard let win = settingsAX(),
              let split = ProbeAX.descendants(win, maxDepth: 4).first(where: { ProbeAX.role($0) == kAXSplitGroupRole }) else { return nil }
        let groups = ProbeAX.children(split).filter { ProbeAX.role($0) == kAXGroupRole }
        guard groups.count >= 2,
              let outline = ProbeAX.descendants(groups[0], maxDepth: 4).first(where: { ProbeAX.role($0) == kAXOutlineRole }),
              let scroll = ProbeAX.descendants(groups[groups.count - 1], maxDepth: 3).first(where: { ProbeAX.role($0) == kAXScrollAreaRole })
        else { return nil }
        return (outline, scroll)
    }

    static func detail() -> AXUIElement? { columns()?.detail }

    static func detailElements() -> [AXUIElement] { detail().map { ProbeAX.descendants($0) } ?? [] }

    /// First element of `role` after the static text `label`, in reading order (the control of a settings row).
    static func control(after label: String, role: String) -> AXUIElement? {
        let all = detailElements()
        guard let i = all.firstIndex(where: { ProbeAX.role($0) == kAXStaticTextRole && ProbeAX.stringValue($0) == label }) else { return nil }
        return all[(i + 1)...].first { ProbeAX.role($0) == role }
    }

    static func button(_ description: String, in elements: [AXUIElement]? = nil, prefix: Bool = false) -> AXUIElement? {
        (elements ?? detailElements()).first {
            let d = clean(ProbeAX.desc($0) ?? ProbeAX.title($0))
            return [kAXButtonRole, kAXRadioButtonRole].contains(ProbeAX.role($0)) && (prefix ? d.hasPrefix(description) : d == description)
        }
    }

    static func headerText() -> String? {
        detailElements().first { ProbeAX.role($0) == kAXStaticTextRole }.flatMap(ProbeAX.stringValue)
    }

    static func settingsSuite() async {
        SettingsWindow.show(pane: .general)
        guard await wait(5, { columns() != nil }) else {
            let c = Case("pane", "window")
            c.fail("Settings window has no sidebar / detail in Accessibility")
            cases.append(c)
            return
        }
        // Start from a pane other than General so selecting General is a real change too.
        if let row = sidebarRow(SettingsPane.about.title) { ProbeAX.press(row) }
        _ = await wait(2) { settingsAX().flatMap(ProbeAX.title) == SettingsPane.about.title }
        for pane in SettingsPane.allCases {
            let c = Case("pane", pane.rawValue)
            cases.append(c)
            guard await select(pane, c) else { continue }
            switch pane {
            case .general: await general(c)
            case .appearance: await appearance(c)
            case .layout: await layout(c)
            case .screens: await screens(c)
            case .dock: await dockPane(c)
            case .profiles: await profiles(c)
            case .widgets: await widgetsPane(c)
            case .shortcuts: await shortcuts(c)
            case .language: await language(c)
            case .privacy: await privacy(c)
            case .performance: await performance(c)
            case .about: await about(c)
            }
        }
    }

    static func sidebarRow(_ title: String) -> AXUIElement? {
        guard let outline = columns()?.sidebar else { return nil }
        return ProbeAX.descendants(outline).first { ProbeAX.desc($0) == title && ProbeAX.actions($0).contains(kAXPressAction) }
    }

    /// Presses the pane's sidebar row and waits for the detail header and the window title to show the pane.
    static func select(_ pane: SettingsPane, _ c: Case) async -> Bool {
        let title = pane.title
        let beforeTitle = settingsAX().flatMap(ProbeAX.title)
        let beforeHeader = headerText()
        guard let row = sidebarRow(title) else {
            c.fail("sidebar row \"\(title)\" not found")
            return false
        }
        c.elements.append("sidebar row " + summary(row))
        let pressed = ProbeAX.press(row)
        // About has no pane header; its first text is the app name.
        let expectedHeader = pane == .about ? "CoolDock" : title
        let ok = await wait(3) { settingsAX().flatMap(ProbeAX.title) == title && headerText() == expectedHeader }
        c.step("press sidebar row \"\(title)\"", ["windowTitle": beforeTitle ?? "", "header": beforeHeader ?? ""],
               ["windowTitle": settingsAX().flatMap(ProbeAX.title) ?? "", "header": headerText() ?? ""], pressed && ok)
        if !ok, let cell = row as AXUIElement?, let axRow = ancestor(of: cell, role: kAXRowRole) {
            ProbeAX.set(axRow, kAXSelectedAttribute, kCFBooleanTrue)
            let selected = await wait(3) { settingsAX().flatMap(ProbeAX.title) == title && headerText() == expectedHeader }
            c.notes.append("fallback AXSelected on the row: \(selected ? "selects the pane" : "no effect")")
            return selected
        }
        return ok
    }

    static func ancestor(of el: AXUIElement, role: String) -> AXUIElement? {
        var cur = ProbeAX.parent(el)
        while let c = cur, ProbeAX.role(c) != role { cur = ProbeAX.parent(c) }
        return cur
    }

    // MARK: Generic controls

    /// Presses the switch of a settings row, checks the model flipped and the switch's AXValue followed, then presses it again.
    static func switchRow(_ c: Case, _ label: String, _ read: @escaping () -> Bool) async {
        guard let box = control(after: label, role: kAXCheckBoxRole) else { c.fail("switch \"\(label)\" not found"); return }
        c.elements.append("\"\(label)\" " + summary(box))
        let before = read()
        let axBefore = ProbeAX.number(box)
        ProbeAX.press(box)
        let flipped = await wait(2) { read() != before && control(after: label, role: kAXCheckBoxRole).flatMap(ProbeAX.number) != axBefore }
        c.step("press switch \"\(label)\"", ["model": before, "AXValue": axBefore ?? -1],
               ["model": read(), "AXValue": control(after: label, role: kAXCheckBoxRole).flatMap(ProbeAX.number) ?? -1], flipped)
        if let again = control(after: label, role: kAXCheckBoxRole) { ProbeAX.press(again) }
        let restored = await wait(2) { read() == before }
        c.step("press it again (restore)", nil, ["model": read()], restored)
    }

    /// Steps a slider up with AXIncrement and back with AXDecrement.
    static func sliderRow(_ c: Case, _ label: String, _ read: @escaping () -> Double) async {
        guard let slider = control(after: label, role: kAXSliderRole) else { c.fail("slider \"\(label)\" not found"); return }
        c.elements.append("\"\(label)\" " + summary(slider) + " value \(ProbeAX.number(slider) ?? -1)")
        let before = read()
        let axBefore = ProbeAX.number(slider)
        ProbeAX.perform(slider, kAXIncrementAction)
        let moved = await wait(2) { read() > before }
        let axAfter = control(after: label, role: kAXSliderRole).flatMap(ProbeAX.number)
        c.step("AXIncrement slider \"\(label)\"", ["model": before, "AXValue": axBefore ?? -1], ["model": read(), "AXValue": axAfter ?? -1],
               moved && axAfter != axBefore)
        if let s = control(after: label, role: kAXSliderRole) { ProbeAX.perform(s, kAXDecrementAction) }
        let restored = await wait(2) { abs(read() - before) < 0.0001 }
        c.step("AXDecrement (restore)", nil, ["model": read()], restored)
    }

    /// Presses a segment of the segmented control after `label`, then the originally selected one.
    static func segment(_ c: Case, _ label: String, choose: String, _ read: @escaping () -> String, expect: String) async {
        guard let group = control(after: label, role: kAXRadioGroupRole) else { c.fail("segmented control \"\(label)\" not found"); return }
        let segments = ProbeAX.children(group)
        c.elements.append("\"\(label)\" segments " + segments.map { clean(ProbeAX.desc($0)) + "=\(Int(ProbeAX.number($0) ?? -1))" }.joined(separator: ", "))
        guard let original = segments.first(where: { ProbeAX.number($0) == 1 }).flatMap(ProbeAX.desc),
              let target = segments.first(where: { ProbeAX.desc($0) == choose }) else { c.fail("segment \"\(choose)\" not found"); return }
        let before = read()
        ProbeAX.press(target)
        let ok = await wait(2) { read() == expect }
        let selected = control(after: label, role: kAXRadioGroupRole).map(ProbeAX.children)?.first { ProbeAX.number($0) == 1 }.flatMap(ProbeAX.desc)
        c.step("press segment \"\(choose)\" of \"\(label)\"", ["model": before, "selected": original], ["model": read(), "selected": selected ?? ""],
               ok && selected == choose)
        if let back = control(after: label, role: kAXRadioGroupRole).map(ProbeAX.children)?.first(where: { ProbeAX.desc($0) == original }) {
            ProbeAX.press(back)
        }
        let restored = await wait(2) { read() == before }
        c.step("press segment \"\(original)\" (restore)", nil, ["model": read()], restored)
    }

    /// Records that a button is there and enabled, without pressing it (outside effects).
    static func present(_ c: Case, _ description: String, prefix: Bool = false) {
        if let b = button(description, prefix: prefix) {
            c.elements.append(summary(b) + " — present, not pressed")
            c.step("check \"\(description)\" exists and is enabled (not pressed)", nil, ["enabled": ProbeAX.enabled(b)], ProbeAX.enabled(b))
        } else {
            c.step("check \"\(description)\" exists", nil, nil, false, "not found")
        }
    }

    // MARK: Panes

    static func general(_ c: Case) async {
        let store = AppStore.shared
        await switchRow(c, L("Show menu bar icon")) { store.settings.showMenuBarIcon }
        for b in [L("Choose Folder…"), L("Export…"), L("Reset…")] { present(c, b) }
        if let toggle = control(after: L("Launch CoolDock at login"), role: kAXCheckBoxRole) {
            c.elements.append("\"Launch CoolDock at login\" " + summary(toggle) + " — present, not pressed")
        }
    }

    static func appearance(_ c: Case) async {
        let store = AppStore.shared
        await segment(c, L("Theme"), choose: AppTheme.dark.title, { store.settings.appTheme.rawValue }, expect: AppTheme.dark.rawValue)
        await sliderRow(c, L("Dock Size")) { store.settings.dockScale }
        await switchRow(c, L("Dock shadow")) { store.settings.shadow }
    }

    static func layout(_ c: Case) async {
        let store = AppStore.shared
        await sliderRow(c, L("Distance from Bottom Edge")) { store.settings.edgeDistance }
        // Fixed layout: the six-position grid. Bottom Left, then back to Bottom Center.
        let before = store.settings.fixedPosition
        if let left = button(ScreenPosition.bottomLeft.title) {
            c.elements.append(summary(left))
            ProbeAX.press(left)
            let ok = await wait(2) { store.settings.fixedPosition == .bottomLeft }
            c.step("press Screen Position \"\(ScreenPosition.bottomLeft.title)\"", before.rawValue, store.settings.fixedPosition.rawValue, ok)
            if let center = button(ScreenPosition.bottomCenter.title) { ProbeAX.press(center) }
            let back = await wait(2) { store.settings.fixedPosition == before }
            c.step("press \"\(ScreenPosition.bottomCenter.title)\" (restore)", nil, store.settings.fixedPosition.rawValue, back)
        } else {
            c.step("find Screen Position buttons by name", nil, nil, false, "unlabeled")
        }
        // Never pressed: they change the macOS Dock's preferences.
        for b in [L("Turn On Dock Auto-Hide"), L("Turn Off Dock Auto-Hide")] where button(b) != nil { present(c, b) }
        for sc in [LayoutScenario.replaceDock, .replaceAutoHide] { present(c, sc.title + ",", prefix: true) }
    }

    static func screens(_ c: Case) async {
        let store = AppStore.shared
        await segment(c, L("Show CoolDock on"), choose: ScreensMode.all.title, { store.settings.screensMode.rawValue }, expect: ScreensMode.all.rawValue)
    }

    static func dockPane(_ c: Case) async {
        let store = AppStore.shared
        await switchRow(c, L("Show running indicators")) { store.settings.showRunningIndicators }
        await switchRow(c, L("Open Folders in Finder")) { store.settings.openFoldersInFinder }
    }

    static func profiles(_ c: Case) async {
        let store = AppStore.shared
        await switchRow(c, L("Show profile switcher on hover")) { store.settings.showProfileSwitcher }
        // New Profile adds and activates a profile; it is then removed again (the model's delete, as the menu would).
        if let add = button(L("New Profile")) {
            c.elements.append(summary(add))
            let before = store.profiles.count
            let active = store.activeProfileID
            ProbeAX.press(add)
            let ok = await wait(2) { store.profiles.count == before + 1 }
            let listed = await wait(2) { detailElements().contains { ProbeAX.role($0) == kAXTextFieldRole && ProbeAX.stringValue($0) == store.profiles.last?.name } }
            c.step("press \"New Profile\"", ["profiles": before], ["profiles": store.profiles.count, "newRowInPane": listed], ok && listed)
            if let added = store.profiles.last, added.id != active {
                store.deleteProfile(added.id)
                store.switchProfile(to: store.profiles.firstIndex { $0.id == active } ?? 0)
            }
            let restored = await wait(2) { store.profiles.count == before && store.activeProfileID == active }
            c.step("remove it again (setup)", nil, ["profiles": store.profiles.count], restored)
        }
    }

    static func widgetsPane(_ c: Case) async {
        let store = AppStore.shared
        await switchRow(c, L("Remember volume per app")) { store.settings.remembersAppVolumes }
        let rows = detailElements().filter { ProbeAX.role($0) == kAXRowRole }.count
        c.step("widget list shows the active profile", nil, ["rows": rows, "widgets": store.activeProfile.widgets.count],
               rows == store.activeProfile.widgets.count)
    }

    static func shortcuts(_ c: Case) async {
        let store = AppStore.shared
        await switchRow(c, L("Hide and Show Dock")) { store.settings.toggleHotKey.enabled }
        await switchRow(c, L("Switch Profile")) { store.settings.profileHotKeysEnabled }
    }

    static func privacy(_ c: Case) async {
        let store = AppStore.shared
        let allowLabel = L("Allow Changes")
        let allowBefore = control(after: allowLabel, role: kAXCheckBoxRole).map(ProbeAX.enabled)
        c.elements.append("\"Allow Changes\" switch enabled: \(allowBefore.map { "\($0)" } ?? "missing")")
        // Enable AI Assistant: the model flips, and the dependent "Allow Changes" switch becomes enabled.
        guard let enable = control(after: L("Enable AI Assistant"), role: kAXCheckBoxRole) else { c.fail("Enable AI Assistant switch not found"); return }
        let before = store.settings.assistantEnabled
        ProbeAX.press(enable)
        let on = await wait(2) { store.settings.assistantEnabled != before && control(after: allowLabel, role: kAXCheckBoxRole).map(ProbeAX.enabled) == true }
        let access = detailElements().first { ProbeAX.role($0) == kAXStaticTextRole && ProbeAX.stringValue($0) == L("Read-only") } != nil
        c.step("press switch \"Enable AI Assistant\"", ["model": before, "allowChangesEnabled": allowBefore ?? false],
               ["model": store.settings.assistantEnabled, "allowChangesEnabled": control(after: allowLabel, role: kAXCheckBoxRole).map(ProbeAX.enabled) ?? false,
                "accessShowsReadOnly": access], on && access)
        if let again = control(after: L("Enable AI Assistant"), role: kAXCheckBoxRole) { ProbeAX.press(again) }
        let off = await wait(2) { store.settings.assistantEnabled == before && control(after: allowLabel, role: kAXCheckBoxRole).map(ProbeAX.enabled) == false }
        c.step("press it again (restore)", nil, ["model": store.settings.assistantEnabled], off)
        // Permission rows: whatever they show is read, never pressed.
        let perms = [L("Calendars"), L("Reminders"), L("Contacts"), L("Location"), L("Photos"), L("Microphone"), L("Accessibility"), L("Automation")]
        let all = detailElements()
        var rows: [String: String] = [:]
        for p in perms {
            guard let i = all.firstIndex(where: { ProbeAX.role($0) == kAXStaticTextRole && ProbeAX.stringValue($0) == p }) else { continue }
            let state = all[(i + 1)...].prefix(3).first { el in
                let r = ProbeAX.role(el)
                return r == kAXButtonRole || (r == kAXStaticTextRole && ProbeAX.stringValue(el) == L("Allowed"))
            }
            rows[p] = state.map { ProbeAX.role($0) == kAXButtonRole ? "button \"\(ProbeAX.desc($0) ?? "")\"" + (ProbeAX.enabled($0) ? "" : " disabled") : "Allowed" } ?? "?"
        }
        c.step("read the permission rows (not pressed)", nil, rows, rows.count == perms.count && !rows.values.contains("?"))
    }

    static func performance(_ c: Case) async {
        let store = AppStore.shared
        await sliderRow(c, L("System stats interval")) { store.settings.systemSampleInterval }
        await switchRow(c, L("Pause widgets while CoolDock is hidden")) { store.settings.pauseWhenHidden }
        present(c, L("Clear Cache"))
    }

    static func about(_ c: Case) async {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = L("Version %@ (%@)", info["CFBundleShortVersionString"] as? String ?? "1.0", info["CFBundleVersion"] as? String ?? "1")
        let shown = detailElements().contains { ProbeAX.stringValue($0) == version }
        c.step("version line", nil, version, shown)
        present(c, L("Show Onboarding"))
        present(c, L("Export Diagnostics…"))
        // Widgets… opens the Widget Browser window; it is closed again with its close button.
        guard let b = button(L("Widgets…")) else { c.fail("Widgets… button not found"); return }
        c.elements.append(summary(b))
        let store = AppStore.shared
        ProbeAX.press(b)
        let browser = { NSApp.windows.first { $0.identifier?.rawValue == "widgets" && $0.isVisible } }
        let opened = await wait(3) { browser() != nil && store.browserOpen }
        let axWindow = browser().flatMap(ProbeAX.window(of:))
        c.step("press \"Widgets…\"", ["browserOpen": false], ["browserOpen": store.browserOpen, "axWindow": axWindow.flatMap(ProbeAX.title) ?? ""],
               opened && axWindow != nil)
        if let ax = axWindow, let close = ProbeAX.children(ax).first(where: { ProbeAX.subrole($0) == kAXCloseButtonSubrole }) {
            ProbeAX.press(close)
        }
        let closed = await wait(3) { browser() == nil && !store.browserOpen }
        c.step("press the browser's close button", nil, ["browserOpen": store.browserOpen], closed)
        // Back to the front for the rest of the run.
        SettingsWindow.show()
    }

    // MARK: Language

    static func sidebarIsRight() -> Bool? {
        guard let cols = columns(), let s = ProbeAX.frame(cols.sidebar), let d = ProbeAX.frame(cols.detail) else { return nil }
        return s.midX > d.midX
    }

    /// Font of a static text as Accessibility reports it (AXAttributedStringForRange → AXFont).
    static func fontName(_ el: AXUIElement) -> String? {
        guard let s = ProbeAX.stringValue(el) else { return nil }
        var range = CFRange(location: 0, length: (s as NSString).length)
        guard let rv = AXValueCreate(.cfRange, &range) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXAttributedStringForRangeParameterizedAttribute as CFString, rv, &out) == .success,
              let attr = out as? NSAttributedString, attr.length > 0 else { return nil }
        let attrs = attr.attributes(at: 0, effectiveRange: nil)
        if let font = attrs[NSAttributedString.Key("AXFont")] as? [String: Any] {
            return (font["AXFontName"] as? String) ?? (font["AXFontFamily"] as? String)
        }
        if let font = attrs[.font] as? NSFont { return font.fontName }
        return nil
    }

    static func language(_ c: Case) async {
        let store = AppStore.shared
        await segment(c, L("Time format"), choose: ClockStyle.h24.title, { store.settings.clockStyle.rawValue }, expect: ClockStyle.h24.rawValue)

        let before = store.settings.language
        let ltr = sidebarIsRight()
        guard let fa = button("فارسی,", prefix: true) else { c.fail("Persian language button not found"); return }
        c.elements.append(summary(fa))
        ProbeAX.press(fa)
        let switched = await wait(3) { store.settings.language == .fa }
        // The window re-renders in Persian: right-to-left, so the sidebar moves to the right-hand side.
        let faTitle = SettingsPane.language.title
        let rtl = await wait(4) { sidebarIsRight() == true && settingsAX().flatMap(ProbeAX.title) == faTitle && headerText() == faTitle }
        let header = detailElements().first { ProbeAX.role($0) == kAXStaticTextRole }
        let font = header.flatMap(fontName)
        let estedad = AppStore.estedadEnabled && Localizer.language.usesEstedad && NSFont(name: "Estedad-Regular", size: 13) != nil
        c.step("press \"فارسی\" (Persian)", ["language": before.rawValue, "sidebarOnRight": ltr ?? false],
               ["language": store.settings.language.rawValue, "sidebarOnRight": sidebarIsRight() ?? false,
                "windowTitle": settingsAX().flatMap(ProbeAX.title) ?? "", "header": headerText() ?? "", "headerFont": font ?? "n/a",
                "estedadActive": estedad],
               switched && rtl && ltr == false && estedad && (font.map { $0.hasPrefix("Estedad") } ?? true))

        // Estedad switch, operated in Persian, then back on.
        await switchRow(c, L("Use Estedad for Persian and Arabic")) { store.settings.useEstedad }
        let fontAfter = detailElements().first { ProbeAX.role($0) == kAXStaticTextRole }.flatMap(fontName)
        c.notes.append("header font after the Estedad switch round trip: \(fontAfter ?? "n/a")")

        guard let en = button("English,", prefix: true) else { c.fail("English language button not found"); return }
        ProbeAX.press(en)
        let back = await wait(3) { store.settings.language == .en }
        let ltrAgain = await wait(4) { sidebarIsRight() == false && settingsAX().flatMap(ProbeAX.title) == SettingsPane.language.title }
        c.step("press \"English\" (restore)", nil, ["language": store.settings.language.rawValue, "sidebarOnRight": sidebarIsRight() ?? true,
                                                    "windowTitle": settingsAX().flatMap(ProbeAX.title) ?? ""], back && ltrAgain)
    }
}

// MARK: - Widgets

extension UIProbe {
    static func dockAX() -> AXUIElement? {
        DockController.shared.activeWindow.flatMap { ProbeAX.window(of: $0.panel) }
    }

    /// The widget's elements in the Dock: everything carrying its name as Accessibility help (the Dock's tooltip).
    static func elements(_ kind: WidgetKind) -> [AXUIElement] {
        guard let dock = dockAX() else { return [] }
        let name = kind.spec.localizedTitle
        var out: [AXUIElement] = []
        func walk(_ el: AXUIElement, inside: Bool) {
            for child in ProbeAX.children(el) {
                let mine = inside || ProbeAX.help(child) == name
                if mine { out.append(child) }
                walk(child, inside: mine)
            }
        }
        walk(dock, inside: false)
        return out
    }

    static func instance(_ kind: WidgetKind) -> WidgetInstance? {
        AppStore.shared.activeProfile.widgets.first { $0.kind == kind }
    }

    static func byID(_ kind: WidgetKind, _ symbol: String) -> AXUIElement? {
        elements(kind).first { ProbeAX.identifier($0) == symbol }
    }

    static func panelAX() -> AXUIElement? {
        NSApp.windows.first { $0 is PopPanel && $0.isVisible }.flatMap(ProbeAX.window(of:))
    }

    static func widgetSuite() async {
        // Settings stays open behind; the Dock is a separate window.
        guard await wait(3, { dockAX() != nil }) else {
            let c = Case("widget", "dock")
            c.fail("the Dock window is not reachable through Accessibility")
            cases.append(c)
            return
        }
        for kind in kinds {
            let c = Case("widget", kind.rawValue)
            cases.append(c)
            c.elements = elements(kind).map(summary)
            if c.elements.isEmpty { c.fail("no Accessibility elements"); continue }
            switch kind {
            case .timer: await timer(c)
            case .stopwatch: await stopwatch(c)
            case .pomodoro: await pomodoro(c)
            case .drinkWater, .posture: await reminder(c, kind)
            case .calculator: await calculator(c)
            case .converter: await converter(c)
            case .emoji: await emoji(c)
            case .colorPicker: await colorPicker(c)
            case .todo: await todo(c)
            case .habitTracker: await habit(c)
            case .voiceMemo: voiceMemo(c)
            case .backgroundSounds: await sounds(c)
            case .youtubeVideo: await youtube(c)
            case .quickToggles: quickToggles(c)
            default: break
            }
            Panels.shared.close()
        }
    }

    // MARK: Clocks

    /// The time a clock widget shows: the description of its display button or its time text.
    static func clockText(_ kind: WidgetKind) -> String? {
        let els = elements(kind)
        if kind == .pomodoro {
            return els.filter { ProbeAX.role($0) == kAXStaticTextRole }.map { clean(ProbeAX.stringValue($0)) }.first { $0.contains(":") }
        }
        return els.first { ProbeAX.role($0) == kAXButtonRole && ProbeAX.identifier($0) == nil }.map { clean(ProbeAX.desc($0)) }
    }

    /// Two reads 1.2 s apart.
    static func frozen(_ kind: WidgetKind) async -> (String, String) {
        let a = clockText(kind) ?? ""
        await sleep(1.2)
        return (a, clockText(kind) ?? "")
    }

    static func timer(_ c: Case) async {
        let before = clockText(.timer)
        guard let play = byID(.timer, "play.fill") else { c.fail("Play button not found"); return }
        ProbeAX.press(play)
        let running = await wait(3) { byID(.timer, "pause.fill") != nil && clockText(.timer) != before }
        c.step("press Play", before, clockText(.timer), running)
        if let pause = byID(.timer, "pause.fill") { ProbeAX.press(pause) }
        let paused = await wait(2) { byID(.timer, "play.fill") != nil }
        let (a, b) = await frozen(.timer)
        c.step("press Pause", nil, ["read1": a, "read2 (1.2 s later)": b], paused && a == b && a != before)
        guard let cancel = byID(.timer, "xmark") else { c.fail("Cancel button not found"); return }
        ProbeAX.press(cancel)
        let reset = await wait(2) { clockText(.timer) == before && byID(.timer, "xmark") == nil }
        c.step("press Cancel (reset)", b, clockText(.timer), reset)
    }

    static func stopwatch(_ c: Case) async {
        let before = clockText(.stopwatch)
        guard let play = byID(.stopwatch, "play.fill") else { c.fail("Play button not found"); return }
        let resetDisabled = byID(.stopwatch, "arrow.counterclockwise").map { !ProbeAX.enabled($0) } ?? false
        ProbeAX.press(play)
        let running = await wait(3) { byID(.stopwatch, "pause.fill") != nil }
        await sleep(1.3)
        let during = clockText(.stopwatch)
        c.step("press Play, wait 1.3 s", ["time": before ?? "", "resetDisabled": resetDisabled], ["time": during ?? ""], running && during != before)
        if let pause = byID(.stopwatch, "pause.fill") { ProbeAX.press(pause) }
        let paused = await wait(2) { byID(.stopwatch, "play.fill") != nil }
        let (a, b) = await frozen(.stopwatch)
        c.step("press Pause", nil, ["read1": a, "read2 (1.2 s later)": b], paused && a == b)
        guard let reset = byID(.stopwatch, "arrow.counterclockwise"), ProbeAX.enabled(reset) else { c.fail("Reset not enabled"); return }
        ProbeAX.press(reset)
        let zero = await wait(2) { clockText(.stopwatch) == before && byID(.stopwatch, "arrow.counterclockwise").map(ProbeAX.enabled) == false }
        c.step("press Reset", b, clockText(.stopwatch), zero)
    }

    static func phaseText() -> String? {
        elements(.pomodoro).first { ProbeAX.role($0) == kAXStaticTextRole }.flatMap(ProbeAX.stringValue)
    }

    static func pomodoro(_ c: Case) async {
        let before = clockText(.pomodoro)
        let phase = phaseText()
        guard let play = byID(.pomodoro, "play.fill") else { c.fail("Play button not found"); return }
        ProbeAX.press(play)
        let running = await wait(3) { byID(.pomodoro, "pause.fill") != nil && clockText(.pomodoro) != before }
        c.step("press Play", ["phase": phase ?? "", "time": before ?? ""], ["time": clockText(.pomodoro) ?? ""], running)
        if let pause = byID(.pomodoro, "pause.fill") { ProbeAX.press(pause) }
        let paused = await wait(2) { byID(.pomodoro, "play.fill") != nil }
        let (a, b) = await frozen(.pomodoro)
        c.step("press Pause", nil, ["read1": a, "read2 (1.2 s later)": b], paused && a == b)
        guard let skip = byID(.pomodoro, "forward.fill") else { c.fail("Skip button not found"); return }
        ProbeAX.press(skip)
        let skipped = await wait(2) { phaseText() != phase }
        c.step("press Skip Phase", ["phase": phase ?? "", "time": b], ["phase": phaseText() ?? "", "time": clockText(.pomodoro) ?? ""], skipped)
    }

    static func reminder(_ c: Case, _ kind: WidgetKind) async {
        guard let w = instance(kind) else { c.fail("widget missing"); return }
        let engine = ClockTimerEngine.shared
        let button = { elements(kind).first { ProbeAX.role($0) == kAXButtonRole } }
        // The countdown starts when the tile appears; it has been running since launch.
        let before = button().map { clean(ProbeAX.desc($0)) }
        let countBefore = engine.reminder(w.id)?.todayCount(at: Date()) ?? 0
        guard let b = button() else { c.fail("reminder button not found"); return }
        ProbeAX.press(b)
        let interval = engine.reminder(w.id)?.interval ?? 0
        let ok = await wait(2) { (engine.reminder(w.id)?.todayCount(at: Date()) ?? 0) == countBefore + 1 }
        // The countdown restarts at the full interval (allow 2 s for the read).
        let restarted = await wait(2) { (button().map { seconds(clean(ProbeAX.desc($0))) } ?? 0) >= interval - 2 }
        let after = button().map { clean(ProbeAX.desc($0)) }
        c.step("press the tile (\(kind == .posture ? "I sat up straight" : "I drank water"))", ["countdown": before ?? "", "count": countBefore],
               ["countdown": after ?? "", "count": engine.reminder(w.id)?.todayCount(at: Date()) ?? 0],
               ok && restarted && seconds(before ?? "") < interval - 2)
    }

    /// "29:57, Every 30 min" → 1797 (minutes:seconds before the comma).
    static func seconds(_ s: String) -> Double {
        let parts = (s.split(separator: ",").first ?? "").split(separator: ":").compactMap { Double(UtilDigits.normalize(String($0)).trimmingCharacters(in: .whitespaces)) }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    // MARK: Utilities

    static func pasteboardString() -> String? { pasteboard.string(forType: .string) }

    /// Presses an inline field (calculator, converter amount), sets its text through AXValue and returns the field.
    static func type(_ kind: WidgetKind, into fieldText: AXUIElement, _ text: String, _ c: Case) async -> AXUIElement? {
        ProbeAX.press(fieldText)
        guard await wait(2, { elements(kind).contains { ProbeAX.role($0) == kAXTextFieldRole } }),
              let field = elements(kind).first(where: { ProbeAX.role($0) == kAXTextFieldRole }) else {
            c.fail("pressing the field did not show a text field")
            return nil
        }
        ProbeAX.set(field, kAXFocusedAttribute, kCFBooleanTrue)
        await sleep(0.1)
        let err = ProbeAX.set(field, kAXValueAttribute, text as CFString)
        if err != .success { c.notes.append("AXValue set returned \(err.rawValue)") }
        return elements(kind).first { ProbeAX.role($0) == kAXTextFieldRole }
    }

    static func calculator(_ c: Case) async {
        let texts = { elements(.calculator).filter { ProbeAX.role($0) == kAXStaticTextRole } }
        guard let input = elements(.calculator).first(where: { ProbeAX.actions($0).contains(kAXPressAction) }) else {
            c.fail("the expression field has no press action")
            return
        }
        c.elements.append("expression " + summary(input) + " actions \(ProbeAX.actions(input))")
        let result = { texts().last.flatMap(ProbeAX.stringValue) }
        let before = result()
        guard let field = await type(.calculator, into: input, "12*(3+4)", c) else { return }
        let computed = await wait(2) { result() == Fmt.digits("84") }
        c.step("press the field, set AXValue \"12*(3+4)\"", before, result(), computed)
        ProbeAX.perform(field, kAXConfirmAction)
        let copied = await wait(2) { pasteboardString() == "84" }
        c.step("AXConfirm (Return copies the result)", nil, ["pasteboard": pasteboardString() ?? ""], copied)
        if let f = elements(.calculator).first(where: { ProbeAX.role($0) == kAXTextFieldRole }) {
            ProbeAX.set(f, kAXValueAttribute, "" as CFString)
        }
        let cleared = await wait(2) { result() == Fmt.digits("0") }
        c.step("clear the field (restore)", nil, result(), cleared)
    }

    static func converter(_ c: Case) async {
        guard let w = instance(.converter) else { c.fail("widget missing"); return }
        let codes = {
            elements(.converter).filter { ProbeAX.role($0) == kAXButtonRole && ProbeAX.identifier($0) == nil }.map { clean(ProbeAX.desc($0)) }
                .filter { $0.count == 3 && $0.allSatisfy(\.isUppercase) }
        }
        let before = codes()
        guard let swap = byID(.converter, "arrow.up.arrow.down") else { c.fail("swap button not found"); return }
        ProbeAX.press(swap)
        let swapped = await wait(2) { codes() == before.reversed() && (instance(.converter)?.string("from") ?? "") == before.last }
        c.step("press Swap Currencies", before, codes(), swapped)
        if let again = byID(.converter, "arrow.up.arrow.down") { ProbeAX.press(again) }
        let back = await wait(2) { codes() == before }
        c.step("press it again (restore)", nil, codes(), back)
        // Amount: an inline field like the calculator's.
        let amountBefore = w.string("amount", "500")
        let amountField = {
            elements(.converter).first { ProbeAX.actions($0).contains(kAXPressAction) && UtilDigits.parseAmount(clean(ProbeAX.label($0))) != nil }
        }
        guard let amount = amountField() else {
            c.fail("the amount field has no press action")
            return
        }
        guard let field = await type(.converter, into: amount, "250", c) else { return }
        ProbeAX.perform(field, kAXConfirmAction)
        let saved = await wait(2) { instance(.converter)?.config["amount"] == "250" }
        // Return ends editing: the field turns back into the amount text.
        _ = await wait(2) { amountField().map { clean(ProbeAX.label($0)) } == Fmt.digits("250") }
        let shown = amountField().map { clean(ProbeAX.label($0)) } ?? ""
        c.step("press the amount, set AXValue \"250\", AXConfirm (Return)", ["saved": amountBefore],
               ["saved": instance(.converter)?.config["amount"] ?? "", "shown": shown], saved && shown == Fmt.digits("250"))
        if let again = amountField(),
           let f = await type(.converter, into: again, amountBefore, c) {
            ProbeAX.perform(f, kAXConfirmAction)
        }
        let restored = await wait(2) { instance(.converter)?.config["amount"] == amountBefore }
        c.step("set it back to \(amountBefore) (restore)", nil, instance(.converter)?.config["amount"] ?? "", restored)
        let rate = elements(.converter).filter { ProbeAX.role($0) == kAXStaticTextRole }.last.flatMap(ProbeAX.stringValue) ?? ""
        c.notes.append("result shown: \"\(rate)\" (the rate needs the network; not part of the check)")
    }

    static func emoji(_ c: Case) async {
        let buttons = elements(.emoji).filter { ProbeAX.role($0) == kAXButtonRole }
        guard let first = buttons.first, let symbol = ProbeAX.desc(first) else { c.fail("no emoji buttons"); return }
        let label = { (elements(.emoji).filter { ProbeAX.role($0) == kAXButtonRole }.first).flatMap(ProbeAX.desc) }
        ProbeAX.press(first)
        let copied = await wait(2) { pasteboardString() == symbol }
        let feedback = await wait(1) { label() != symbol }
        c.step("press \(symbol)", nil, ["pasteboard": pasteboardString() ?? "", "button shows": label() ?? ""], copied && feedback)
        let reverted = await wait(2.5) { label() == symbol }
        c.step("the confirmation goes away", nil, label(), reverted)
        if let add = byID(.emoji, "plus") {
            c.step("\"Add\" (Character Viewer) exists and is enabled (not pressed)", nil, ProbeAX.enabled(add), ProbeAX.enabled(add))
        }
    }

    static func colorPicker(_ c: Case) async {
        guard let w = instance(.colorPicker) else { c.fail("widget missing"); return }
        let hex = UtilColorPickerView.colors(w)[0]
        guard let swatch = elements(.colorPicker).first(where: { ProbeAX.desc($0) == hex }) else {
            c.step("find the swatch \(hex) by name", nil, nil, false, "swatches are unlabeled")
            return
        }
        ProbeAX.press(swatch)
        let copied = await wait(2) { pasteboardString() == hex }
        c.step("press swatch \(hex)", nil, ["pasteboard": pasteboardString() ?? ""], copied)
        if let picker = byID(.colorPicker, "eyedropper") {
            c.step("eyedropper (screen sampler) exists and is enabled (not pressed)", nil, ProbeAX.enabled(picker), ProbeAX.enabled(picker))
        }
    }

    static func todo(_ c: Case) async {
        let title = "UI probe task"
        let count = { CalTodoStore.items(instance(.todo)).count }
        guard let tile = elements(.todo).first(where: { ProbeAX.actions($0).contains(kAXPressAction) }) else {
            c.fail("the tile has no press action")
            return
        }
        ProbeAX.press(tile)
        let opened = await wait(2) { panelAX().map { ProbeAX.descendants($0).contains { ProbeAX.role($0) == kAXTextFieldRole } } == true }
        c.step("press the tile", ["panel": false], ["panel": opened], opened)
        guard let panel = panelAX(), let field = ProbeAX.descendants(panel).first(where: { ProbeAX.role($0) == kAXTextFieldRole }) else { return }
        c.elements += ProbeAX.descendants(panel).filter { [kAXTextFieldRole, kAXButtonRole].contains(ProbeAX.role($0)) }.map { "panel " + summary($0) }
        ProbeAX.set(field, kAXFocusedAttribute, kCFBooleanTrue)
        ProbeAX.set(field, kAXValueAttribute, title as CFString)
        ProbeAX.perform(field, kAXConfirmAction)
        let added = await wait(2) { count() == 1 }
        let shown = await wait(2) { elements(.todo).contains { ProbeAX.stringValue($0) == title || ProbeAX.desc($0)?.contains(title) == true } }
        c.step("type \"\(title)\" in the panel's field, AXConfirm", 0, ["items": count(), "tileShowsIt": shown], added && shown)
        // Remove it with the panel row's delete button.
        let row = panelAX().flatMap { p in ProbeAX.descendants(p).first { el in ProbeAX.actions(el).contains { $0.contains("Name:" + L("Delete")) } } }
        guard let row, let action = ProbeAX.actions(row).first(where: { $0.contains("Name:" + L("Delete")) }) else {
            c.step("find the row's Delete action", nil, nil, false, "not found (Delete only shows on hover)")
            return
        }
        ProbeAX.perform(row, action)
        let removed = await wait(2) { count() == 0 }
        let empty = await wait(2) { elements(.todo).contains { (ProbeAX.desc($0) ?? ProbeAX.stringValue($0) ?? "").contains(L("Nothing to do")) } }
        c.step("perform the row's Delete action", 1, ["items": count(), "tileEmptyAgain": empty], removed && empty)
    }

    static func habit(_ c: Case) async {
        let name = "Probe habit"
        let habits = { CalHabitStore.habits(instance(.habitTracker)) }
        guard let tile = elements(.habitTracker).first(where: { ProbeAX.actions($0).contains(kAXPressAction) }) else {
            c.fail("the empty tile has no press action")
            return
        }
        ProbeAX.press(tile)
        let opened = await wait(2) { panelAX().map { ProbeAX.descendants($0).contains { ProbeAX.role($0) == kAXTextFieldRole } } == true }
        c.step("press \"Add a habit\"", ["panel": false], ["panel": opened], opened)
        guard let panel = panelAX(), let field = ProbeAX.descendants(panel).first(where: { ProbeAX.role($0) == kAXTextFieldRole }) else { return }
        ProbeAX.set(field, kAXFocusedAttribute, kCFBooleanTrue)
        ProbeAX.set(field, kAXValueAttribute, name as CFString)
        ProbeAX.perform(field, kAXConfirmAction)
        let added = await wait(2) { habits().map(\.name) == [name] }
        let ring = { elements(.habitTracker).first { ProbeAX.role($0) == kAXButtonRole && ProbeAX.desc($0) == name } }
        let shown = await wait(2) { ring() != nil }
        c.step("type \"\(name)\" in the panel's field, AXConfirm", 0, ["habits": habits().map(\.name), "ringOnTile": shown], added && shown)
        // Check it off for today from the tile, then uncheck.
        let today = CalHabitClock.today()
        if let r = ring() { ProbeAX.press(r) }
        let done = await wait(2) { habits().first?.isChecked(today) == true }
        c.step("press the habit ring on the tile", ["doneToday": false], ["doneToday": habits().first?.isChecked(today) ?? false], done)
        if let r = ring() { ProbeAX.press(r) }
        let undone = await wait(2) { habits().first?.isChecked(today) == false }
        c.step("press it again", nil, ["doneToday": habits().first?.isChecked(today) ?? true], undone)
        // Delete: the panel asks once ("Delete"), then deletes.
        guard let p = panelAX() else { c.fail("panel closed"); return }
        let first = ProbeAX.descendants(p).first { ProbeAX.role($0) == kAXButtonRole && ProbeAX.help($0) == L("Delete") }
        guard let first else { c.step("find the habit's Delete button", nil, nil, false, "not found"); return }
        ProbeAX.press(first)
        _ = await wait(2) { panelAX().map { ProbeAX.descendants($0).contains { ProbeAX.help($0) == L("Deletes the habit and its history") } } == true }
        if let confirm = panelAX().flatMap({ ProbeAX.descendants($0).first { ProbeAX.help($0) == L("Deletes the habit and its history") } }) {
            ProbeAX.press(confirm)
        }
        let removed = await wait(2) { habits().isEmpty }
        let empty = await wait(2) { elements(.habitTracker).contains { (ProbeAX.desc($0) ?? ProbeAX.stringValue($0) ?? "").contains(L("Add a habit")) } }
        c.step("press Delete, then confirm", 1, ["habits": habits().count, "tileEmptyAgain": empty], removed && empty)
    }

    static func voiceMemo(_ c: Case) {
        // Pressing would record (and ask for the microphone the first time): only check the control is there.
        guard let tile = elements(.voiceMemo).first(where: { ProbeAX.actions($0).contains(kAXPressAction) }) else {
            c.step("record control has a press action", nil, nil, false, "no press action")
            return
        }
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        let status = mic == .authorized ? "authorized" : mic == .denied ? "denied" : mic == .restricted ? "restricted" : "notDetermined"
        let actions = ProbeAX.actions(tile)
        c.step("record control: button, enabled, press action (not pressed)", nil,
               ["role": ProbeAX.role(tile), "enabled": ProbeAX.enabled(tile), "actions": actions, "label": ProbeAX.desc(tile) ?? "", "microphone": status],
               ProbeAX.enabled(tile) && ProbeAX.role(tile) == kAXButtonRole)
        c.step("Recordings… is reachable as a named action", nil, actions.filter { $0.contains(L("Recordings…")) },
               actions.contains { $0.contains(L("Recordings…")) })
    }

    static func sounds(_ c: Case) async {
        guard let w = instance(.backgroundSounds) else { c.fail("widget missing"); return }
        let engine = MediaSoundEngine.shared
        guard MediaSoundsTile.volume(w) == 0 else { c.step("volume is 0 before pressing", nil, MediaSoundsTile.volume(w), false, "skipped: not silent"); return }
        guard let tile = elements(.backgroundSounds).first(where: { ProbeAX.actions($0).contains(kAXPressAction) }) else {
            c.fail("the tile has no press action")
            return
        }
        let value = { elements(.backgroundSounds).first.flatMap(ProbeAX.stringValue) }
        let before = value()
        ProbeAX.press(tile)
        let playing = await wait(2) { engine.isPlaying && value() == MediaSoundsTile.sound(w).title }
        c.step("press the tile (plays at volume 0)", ["AXValue": before ?? "", "playing": false],
               ["AXValue": value() ?? "", "playing": engine.isPlaying, "volume": engine.volume], playing && engine.volume == 0)
        if let t = elements(.backgroundSounds).first(where: { ProbeAX.actions($0).contains(kAXPressAction) }) { ProbeAX.press(t) }
        let stopped = await wait(2) { !engine.isPlaying && value() == before }
        c.step("press it again (stop)", nil, ["AXValue": value() ?? "", "playing": engine.isPlaying], stopped)
    }

    static func youtube(_ c: Case) async {
        guard let w = instance(.youtubeVideo) else { c.fail("widget missing"); return }
        guard let tile = elements(.youtubeVideo).first(where: { ProbeAX.actions($0).contains(kAXPressAction) }) else {
            c.fail("the video has no press action")
            return
        }
        let count = openedURLs.count
        ProbeAX.press(tile)
        let opened = await wait(2) { openedURLs.count == count + 1 }
        c.step("press the video (URL captured, not opened)", nil, openedURLs.last ?? "", opened && openedURLs.last == w.string("url"))
    }

    static func quickToggles(_ c: Case) {
        // Wi-Fi, Bluetooth and the rest change the Mac: read only.
        let buttons = elements(.quickToggles).filter { ProbeAX.role($0) == kAXButtonRole }
        let states = buttons.map { "\(ProbeAX.desc($0) ?? "?")=\(ProbeAX.stringValue($0) ?? "?")" }
        let labelled = buttons.allSatisfy { !(ProbeAX.desc($0) ?? "").isEmpty }
        c.step("read every toggle's name and state (not pressed)", nil, states, !buttons.isEmpty && labelled && buttons.allSatisfy(ProbeAX.enabled))
    }
}
#endif
