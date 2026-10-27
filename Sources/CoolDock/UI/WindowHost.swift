import AppKit
import SwiftUI

/// Shared helper for CoolDock's regular windows (Settings, Widgets, Setup, Onboarding).
@MainActor
final class WindowHost: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    private let id: String
    var onClose: (() -> Void)?

    init(id: String) { self.id = id }

    var isVisible: Bool { window?.isVisible == true }

    func show<V: View>(title: String, size: NSSize, minSize: NSSize? = nil, resizable: Bool = true, toolbar: Bool = false,
                       level: NSWindow.Level = .normal, content: () -> V) {
        let store = AppStore.shared
        let root = content()
            .environment(\.layoutDirection, store.layoutDirection)
            .environment(\.locale, Fmt.locale)
            .environment(\.calendar, Fmt.calendar)
            .font(.ui())

        if let window {
            // Title first: a `navigationTitle` in the new content (Settings: the pane's name) then wins, as it does
            // when the window is created. Set afterwards, it replaced the pane's name until the next pane change.
            window.title = title
            window.contentView = NSHostingView(rootView: AnyView(root))
            window.level = level
            bringToFront(window)
            return
        }

        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        if resizable { style.insert(.resizable) }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        w.title = title
        w.identifier = NSUserInterfaceItemIdentifier(id)
        w.isReleasedWhenClosed = false
        w.titlebarAppearsTransparent = true
        w.titleVisibility = toolbar ? .hidden : .visible
        w.level = level
        if let minSize { w.contentMinSize = minSize }
        if toolbar {
            let tb = NSToolbar(identifier: id)
            tb.showsBaselineSeparator = false
            w.toolbar = tb
            w.toolbarStyle = .unified
        }
        w.contentView = NSHostingView(rootView: AnyView(root))
        w.setFrameAutosaveName("CoolDock.\(id)")
        if !w.setFrameUsingName("CoolDock.\(id)") { w.center() }
        w.delegate = self
        window = w
        bringToFront(w)
    }

    private func bringToFront(_ w: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
    }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        onClose?()
        // Drop the SwiftUI tree so closed windows hold no memory.
        DispatchQueue.main.async { [weak self] in
            self?.window?.contentView = nil
            self?.window = nil
        }
    }
}
