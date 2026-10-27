import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        DockFonts.registerBundledFonts()
        let store = AppStore.shared
        if let i = CommandLine.arguments.firstIndex(of: "--lang"), CommandLine.arguments.count > i + 1,
           let lang = AppLanguage(rawValue: CommandLine.arguments[i + 1]) {
            store.settings.language = lang
        }
        store.applyAppTheme()
        buildMainMenu()

        statusItem = StatusItemController()
        statusItem?.setVisible(store.settings.showMenuBarIcon)

        SystemDock.shared.apply(for: store.settings.scenario)
        DockController.shared.start()
        HotKeys.shared.install()
        AssistantBridge.start()
        // Remembered per-app volumes apply as soon as those apps play.
        UtilAppVolumeService.shared.bootstrap()

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

        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--settings") {
            let pane = args.count > i + 1 ? SettingsPane(rawValue: args[i + 1]) : nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { SettingsWindow.show(pane: pane ?? .general) }
        } else if args.contains("--widgets") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { WidgetBrowser.show() }
        } else if args.contains("--onboarding") || !store.settings.onboardingDone {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { OnboardingWindow.show() }
        }
        #if DEBUG
        // Dev aids: `--profile 2` switches profile; `--tap 0.42` clicks the dock at 42% of its width so panels can be inspected without UI scripting.
        if let i = args.firstIndex(of: "--profile"), args.count > i + 1, let index = Int(args[i + 1]) {
            store.switchProfile(to: index)
        }
        if let i = args.firstIndex(of: "--tap"), args.count > i + 1, let fraction = Double(args[i + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { Self.syntheticTap(fraction) }
        }
        #endif
    }

    #if DEBUG
    private static func syntheticTap(_ fraction: Double) {
        guard let window = DockController.shared.activeWindow?.panel, let view = window.contentView else { return }
        let point = NSPoint(x: view.bounds.width * fraction, y: view.bounds.midY)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let e = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                window.sendEvent(e)
            }
        }
    }
    #endif

    func applicationWillTerminate(_ notification: Notification) {
        AssistantBridge.stop()
        UtilAppVolumeService.shared.shutdown()
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
