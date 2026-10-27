import AppKit

/// Menu bar icon and its menu (Widgets, Settings, Layout, Help, Quit).
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private var item: NSStatusItem?

    func setVisible(_ visible: Bool) {
        if visible, item == nil {
            let i = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            if let button = i.button {
                let image = NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: "CoolDock")
                image?.isTemplate = true
                button.image = image
            }
            item = i
            rebuildMenu()
        } else if !visible, let i = item {
            NSStatusBar.system.removeStatusItem(i)
            item = nil
        }
    }

    func rebuildMenu() {
        guard let item else { return }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let store = AppStore.shared
        let s = store.settings

        if !s.onboardingDone {
            menu.addItem(action(L("Continue Setup"), #selector(showOnboarding)))
        }
        menu.addItem(action(store.browserOpen ? L("Close Widgets") : L("Widgets"), #selector(toggleWidgets)))
        menu.addItem(action(L("Settings…"), #selector(showSettings), key: ","))
        menu.addItem(.separator())

        let layout = NSMenuItem(title: L("Layout"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for sc in LayoutScenario.allCases {
            if sc == .fixed {
                let fixed = NSMenuItem(title: sc.title, action: nil, keyEquivalent: "")
                fixed.state = s.scenario == .fixed ? .on : .off
                let positions = NSMenu()
                for pos in ScreenPosition.allCases {
                    let it = NSMenuItem(title: pos.title, action: #selector(pickPosition(_:)), keyEquivalent: "")
                    it.target = self
                    it.representedObject = pos.rawValue
                    it.state = s.scenario == .fixed && s.fixedPosition == pos ? .on : .off
                    positions.addItem(it)
                }
                fixed.submenu = positions
                sub.addItem(fixed)
            } else {
                let it = NSMenuItem(title: sc.title, action: #selector(pickScenario(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = sc.rawValue
                it.state = s.scenario == sc ? .on : .off
                sub.addItem(it)
            }
        }
        sub.addItem(.separator())
        sub.addItem(action(L("Reset Layout"), #selector(resetLayout)))
        layout.submenu = sub
        menu.addItem(layout)

        if store.profiles.count > 1 {
            let profiles = NSMenuItem(title: L("Profiles"), action: nil, keyEquivalent: "")
            let pm = NSMenu()
            for (i, p) in store.profiles.enumerated() {
                let it = NSMenuItem(title: p.name, action: #selector(pickProfile(_:)), keyEquivalent: "")
                it.target = self
                it.tag = i
                it.state = p.id == store.activeProfileID ? .on : .off
                it.image = NSImage(systemSymbolName: p.symbol, accessibilityDescription: nil)
                pm.addItem(it)
            }
            profiles.submenu = pm
            menu.addItem(profiles)
        }
        menu.addItem(action(store.dockHidden ? L("Show CoolDock") : L("Hide CoolDock"), #selector(toggleDock)))
        menu.addItem(.separator())

        let help = NSMenuItem(title: L("Help"), action: nil, keyEquivalent: "")
        let hm = NSMenu()
        hm.addItem(action(L("Export Diagnostics…"), #selector(exportDiagnostics)))
        hm.addItem(action(L("Contact"), #selector(contact)))
        hm.addItem(action(L("Show Onboarding"), #selector(showOnboarding)))
        help.submenu = hm
        menu.addItem(help)
        menu.addItem(.separator())
        menu.addItem(action(L("Quit CoolDock"), #selector(quit), key: "q"))
    }

    private func action(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        it.target = self
        return it
    }

    @objc private func toggleWidgets() { WidgetBrowser.toggle() }
    @objc private func showSettings() { SettingsWindow.show() }
    @objc private func showOnboarding() { OnboardingWindow.show() }
    @objc private func resetLayout() { DockController.shared.resetLayout() }
    @objc private func toggleDock() { DockController.shared.toggleVisibility() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func contact() { Open.url("mailto:support@cooldock.app") }
    @objc private func exportDiagnostics() { Diagnostics.export() }

    @objc private func pickScenario(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let sc = LayoutScenario(rawValue: raw) { AppStore.shared.settings.scenario = sc }
    }

    @objc private func pickPosition(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let pos = ScreenPosition(rawValue: raw) else { return }
        var s = AppStore.shared.settings
        s.scenario = .fixed
        s.fixedPosition = pos
        AppStore.shared.settings = s
    }

    @objc private func pickProfile(_ sender: NSMenuItem) { AppStore.shared.switchProfile(to: sender.tag) }
}

enum Diagnostics {
    @MainActor
    static func report() -> String {
        let store = AppStore.shared
        let info = Bundle.main.infoDictionary ?? [:]
        let mem = Self.memoryFootprintMB()
        var lines = [
            "CoolDock \(info["CFBundleShortVersionString"] as? String ?? "dev") (\(info["CFBundleVersion"] as? String ?? "0"))",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Memory footprint: \(String(format: "%.1f", mem)) MB",
            "Language: \(store.resolvedLanguage.rawValue)  Calendar: \(Fmt.calendar.identifier)",
            "Scenario: \(store.settings.scenario.rawValue)  Screens: \(store.settings.screensMode.rawValue)",
            "Displays: \(NSScreen.screens.map { "\($0.localizedName) \(Int($0.frame.width))x\(Int($0.frame.height))" }.joined(separator: ", "))",
            "Windows: hideOnWindowHover=\(store.settings.hideOnWindowHover) reserveDockSpace=\(store.settings.reservesDockSpace) afterDragging=\(store.settings.reservesAfterDragging) accessibility=\(AXIsProcessTrusted())",
            "Credential storage: \(Secrets.backend.rawValue)",
            "Profiles: \(store.profiles.count)"
        ]
        for p in store.profiles {
            lines.append("  • \(p.name): " + p.widgets.map(\.kind.rawValue).joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    static func memoryFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    @MainActor
    static func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "CoolDock-Diagnostics.txt"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            try? report().write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
