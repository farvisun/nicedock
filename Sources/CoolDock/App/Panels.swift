import AppKit
import SwiftUI

/// Floating panel used for expanded widget views and setup sheets.
final class PopPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 3)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        isFloatingPanel = true
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Presents one widget panel at a time above (or below) the dock.
@MainActor
final class Panels {
    static let shared = Panels()
    private var panel: PopPanel?
    private var host: DockHostingView<AnyView>?
    private(set) var currentID: AnyHashable?
    private var monitors: [Any] = []
    private var anchorX: CGFloat = 0
    private weak var dock: DockWindow?
    private var size: CGSize = .zero

    var isOpen: Bool { panel?.isVisible == true }

    func toggle<V: View>(_ id: AnyHashable, takeFocus: Bool = true, @ViewBuilder content: () -> V) {
        if currentID == id, isOpen { close(); return }
        show(id, takeFocus: takeFocus, content: content)
    }

    func show<V: View>(_ id: AnyHashable, takeFocus: Bool = true, @ViewBuilder content: () -> V) {
        close()
        let store = AppStore.shared
        dock = DockController.shared.activeWindow
        anchorX = NSEvent.mouseLocation.x
        currentID = id
        size = .zero

        let body = content()
        let root = PanelChrome { body }
            .environment(\.palette, store.palette)
            .environment(\.metrics, DockMetrics(scale: 1, spacing: store.settings.widgetSpacing, cornerRadius: store.settings.cornerRadius))
            .environment(\.layoutDirection, store.layoutDirection)
            .environment(\.locale, Fmt.locale)
            .environment(\.calendar, Fmt.calendar)

        let p = panel ?? PopPanel()
        let h = DockHostingView(rootView: AnyView(root))
        h.sizingOptions = [.intrinsicContentSize]
        h.translatesAutoresizingMaskIntoConstraints = true
        h.onSizeChange = { [weak self] size in self?.resize(size) }
        p.contentView = h
        p.appearance = NSAppearance(named: store.palette.isLight ? .aqua : .darkAqua)
        panel = p
        host = h
        resize(h.intrinsicContentSize)
        p.alphaValue = 0
        p.orderFrontRegardless()
        if takeFocus { p.makeKey() }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            p.animator().alphaValue = 1
        }
        installMonitors()
    }

    private func resize(_ newSize: CGSize) {
        guard let panel, newSize.width > 1, newSize != size else { return }
        size = newSize
        let screen = dock?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        let dockFrame = dock?.panel.frame ?? NSRect(x: vf.midX, y: vf.minY, width: 0, height: 80)
        let atTop = dock?.model.atTop ?? false
        var x = anchorX - newSize.width / 2
        x = min(max(x, vf.minX + 8), vf.maxX - newSize.width - 8)
        var y = atTop ? dockFrame.minY - 8 - newSize.height : dockFrame.maxY + 6
        if y + newSize.height > vf.maxY { y = vf.maxY - newSize.height - 6 }
        if y < vf.minY { y = vf.minY + 6 }
        panel.setFrame(NSRect(x: x.rounded(), y: y.rounded(), width: newSize.width, height: newSize.height), display: true)
    }

    func close() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        currentID = nil
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        panel.contentView = nil
        host = nil
        if AppStore.shared.settings.scenario.isReveal { dock?.scheduleAutoHide() }
    }

    private func installMonitors() {
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { _ in
            MainActor.assumeIsolated { Panels.shared.close() }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown], handler: { event in
            MainActor.assumeIsolated {
                if event.type == .keyDown, event.keyCode == 53 { Panels.shared.close(); return nil }
                if event.type == .leftMouseDown, let w = event.window, w !== Panels.shared.panel, !(w is DockPanel) {
                    Panels.shared.close()
                }
                return event
            }
        }) { monitors.append(m) }
    }
}

/// Visual container for panels — same material family as the dock plate.
struct PanelChrome<Content: View>: View {
    @Environment(\.palette) private var p
    @ViewBuilder var content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        content()
            .padding(14)
            .foregroundStyle(p.primary)
            .background {
                ZStack {
                    if !AppStore.shared.reduceTransparency && !p.isLight {
                        VisualEffectBlur(material: .hudWindow, appearance: .darkAqua)
                    }
                    shape.fill(p.isLight ? Color(white: 0.98) : Color.black.opacity(AppStore.shared.reduceTransparency ? 0.95 : 0.72))
                }
                .clipShape(shape)
            }
            .overlay(shape.strokeBorder(p.plateStroke, lineWidth: 1))
            .clipShape(shape)
            .fixedSize()
    }
}

struct SizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

/// Standard header used at the top of widget panels.
struct PanelHeader<Trailing: View>: View {
    @Environment(\.palette) private var p
    var title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.dock(15, .bold)).foregroundStyle(p.primary)
                if let subtitle { Text(subtitle).font(.dock(11, .medium)).foregroundStyle(p.secondary) }
            }
            Spacer(minLength: 12)
            trailing()
        }
    }
}

extension PanelHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}
