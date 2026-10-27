#if DEBUG
import AppKit

/// Dev aid: `CoolDock --menu-probe <app path> [--redact] [--perform "Title" | "Sub/Title"]… [--step s]`
/// builds the real right-click menu of an app tile (the same `AppsAppMenu.build` the Dock uses), prints it as JSON,
/// then fires the given items one by one and reports the app's state after each. Nothing is saved
/// (persistence is off); `--redact` replaces personal titles (Open Recent files, browser profiles) with counts.
@MainActor
enum MenuProbe {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--menu-probe"), args.count > i + 1 else { return false }
        AppStore.persistenceEnabled = false
        let path = args[i + 1]
        let redact = args.contains("--redact")
        let step = args.firstIndex(of: "--step").flatMap { args.count > $0 + 1 ? Double(args[$0 + 1]) : nil } ?? 2.5
        let actions = args.indices.filter { args[$0] == "--perform" && args.count > $0 + 1 }.map { args[$0 + 1] }

        // Let the login-item and recent-document caches warm up like they do while the Dock is running.
        AppsAppMenu.prefetch(path)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            let menu = AppsAppMenu.build(.init(path: path))
            emit(["event": "menu", "app": path, "state": state(path), "items": tree(menu, redact: redact)])
            perform(actions, in: menu, path: path, step: step)
        }
        return true
    }

    private static func perform(_ queue: [String], in menu: NSMenu, path: String, step: Double) {
        guard let next = queue.first else {
            emit(["event": "done", "state": state(path)])
            exit(0)
        }
        // Rebuild before every action: like the real menu, items reflect the app's current state.
        let fresh = AppsAppMenu.build(.init(path: path))
        if let item = find(next.split(separator: "/").map(String.init), in: fresh), let action = item.action {
            NSApp.sendAction(action, to: item.target, from: item)
            emit(["event": "performed", "item": next])
        } else {
            emit(["event": "missing", "item": next])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + step) {
            emit(["event": "after", "item": next, "state": state(path)])
            perform(Array(queue.dropFirst()), in: fresh, path: path, step: step)
        }
    }

    private static func find(_ titles: [String], in menu: NSMenu) -> NSMenuItem? {
        guard let first = titles.first, let item = menu.items.first(where: { $0.title == first }) else { return nil }
        if titles.count == 1 { return item }
        return item.submenu.flatMap { find(Array(titles.dropFirst()), in: $0) }
    }

    private static func tree(_ menu: NSMenu, redact: Bool, personal: Bool = false) -> [[String: Any]] {
        if redact && personal { return [["redacted": menu.items.count]] }
        return menu.items.map { item in
            if item.isSeparatorItem { return ["separator": true] }
            var d: [String: Any] = ["title": item.title, "enabled": item.isEnabled]
            if item.state == .on { d["checked"] = true }
            if item.isAlternate { d["alternate"] = "⌥" }
            if let sub = item.submenu {
                let isPersonal = [L("Open Recent"), L("New Window with Profile")].contains(item.title)
                d["submenu"] = tree(sub, redact: redact, personal: isPersonal)
            }
            return d
        }
    }

    private static func state(_ path: String) -> [String: Any] {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: AppsLaunch.bundleID(path) ?? "")
        let pids = Set(apps.map(\.processIdentifier))
        // Owner pid and layer are readable without Screen Recording; titles are not needed.
        let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .filter { ($0[kCGWindowLayer as String] as? Int) == 0 && pids.contains(($0[kCGWindowOwnerPID as String] as? Int32) ?? -1) }
        return ["running": !apps.isEmpty, "hidden": apps.contains(where: \.isHidden), "active": apps.contains(where: \.isActive),
                "onScreenWindows": windows.count, "keptInDock": !AppsLaunch.pinned(path).isEmpty]
    }

    private static func emit(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
}
#endif
