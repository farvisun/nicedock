import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        DockFonts.registerBundledFonts()
        let store = AppStore.shared
        store.applyAppTheme()
        buildMainMenu()

        statusItem = StatusItemController()
        statusItem?.setVisible(store.settings.showMenuBarIcon)

        SystemDock.shared.apply(for: store.settings.scenario)
        DockController.shared.start()
        HotKeys.shared.install()

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                AppStore.shared.systemReduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            }
        }
        NotificationCenter.default.addObserver(forName: .coolDockSettingsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                let s = AppStore.shared.settings
                self?.statusItem?.setVisible(s.showMenuBarIcon)
                self?.statusItem?.rebuildMenu()
                self?.buildMainMenu()
                HotKeys.shared.install()
            }
        }

        if !store.settings.onboardingDone {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { OnboardingWindow.show() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppStore.shared.saveNow()
        SystemDock.shared.restore()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindow.show()
        return false
    }

    /// Minimal main menu so ⌘, ⌘W ⌘Q and text editing shortcuts work in our windows.
    func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("About CoolDock"), action: #selector(showAbout), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Settings…"), action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Quit CoolDock"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: L("Edit"))
        edit.addItem(withTitle: L("Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: L("Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: L("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: L("Window"))
        window.addItem(withTitle: L("Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }

    @objc func showSettings() { SettingsWindow.show() }
    @objc func showAbout() { SettingsWindow.show(pane: .about) }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("CoolDock login item: \(error.localizedDescription)")
        }
    }

    static func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
