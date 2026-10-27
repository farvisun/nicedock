import AppKit
import SwiftUI

// MARK: - Tile

/// Window Manager tile: round layout buttons in the Quick Toggles rhythm, plus one that opens the window list.
/// The row stays left-to-right in every language because the layouts are geographic.
struct UtilWindowsView: View {
    let w: WidgetInstance
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    private var service: UtilWindowService { .shared }

    static func items(_ w: WidgetInstance) -> [UtilWinAction] {
        var seen = Set<UtilWinAction>()
        let list = w.list("items")
            .compactMap { UtilWinAction(rawValue: $0.trimmingCharacters(in: .whitespaces)) }
            .filter { seen.insert($0).inserted }
        return Array((list.isEmpty ? UtilWinAction.tileDefaults : list).prefix(7))
    }

    /// Whole-point width for `buttons` circles: 13 pt padding, 40 pt circles, 8 pt gaps.
    static func width(buttons: Int) -> CGFloat { CGFloat(18 + 48 * buttons) }

    var body: some View {
        if UtilWindowPanel.sceneVariant {
            UtilWindowPanel.scenePreview(w)
        } else {
            tile
        }
    }

    private var tile: some View {
        let items = Self.items(w)
        return Tile(width: Self.width(buttons: items.count + 1)) {
            if service.trusted {
                HStack(spacing: m.u(8)) {
                    ForEach(items) { UtilWinButton(action: $0) }
                    UtilWinMoreButton { UtilWindowPanel.toggle(w) }
                }
                .environment(\.layoutDirection, .leftToRight)
            } else {
                TileMessage(symbol: "hand.raised.fill", text: L("Allow Accessibility to move and resize windows"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { service.requestAccess() }
                    .help(L("Opens Privacy & Security → Accessibility"))
            }
        }
        .demand(service)
    }
}

private struct UtilWinButton: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    var action: UtilWinAction
    /// Brief ring after a click: accent when the window moved, red when there was nothing to move.
    @State private var result: Bool?

    var body: some View {
        let accent = p.accent(action.tint)
        let ring = result == false ? p.accent(.cdRed) : accent
        Button(action: run) {
            UtilWinGlyph(action: action, color: accent)
                .frame(width: m.u(40), height: m.u(40))
                .background(Circle().fill(accent.opacity(0.11)))
                .overlay(Circle().strokeBorder(ring.opacity(result == nil ? 0.18 : 0.9), lineWidth: m.u(result == nil ? 0.75 : 2)))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .help(action.title)
    }

    private func run() {
        let ok = UtilWindowService.shared.perform(action)
        withAnimation(.easeOut(duration: 0.12)) { result = ok }
        Task {
            try? await Task.sleep(for: .milliseconds(650))
            withAnimation(.easeOut(duration: 0.25)) { result = nil }
        }
    }
}

private struct UtilWinMoreButton: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "ellipsis")
                .font(.system(size: m.u(15), weight: .bold))
                .foregroundStyle(p.secondary)
                .frame(width: m.u(40), height: m.u(40))
                .background(Circle().fill(p.primary.opacity(0.065)))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .help(L("Windows & More Layouts"))
    }
}

/// A screen outline with the target area filled (Next Display uses the two-display symbol).
struct UtilWinGlyph: View {
    @Environment(\.metrics) private var m
    var action: UtilWinAction
    var color: Color
    var scale: CGFloat = 1

    var body: some View {
        let k = m.u(scale)
        if action == .nextDisplay {
            Image(systemName: "display.2")
                .font(.system(size: 14 * k, weight: .semibold))
                .foregroundStyle(color)
        } else {
            let region = action.glyphRegion
            Canvas { ctx, size in
                let line = 1.5 * k
                let outer = CGRect(origin: .zero, size: size).insetBy(dx: line / 2, dy: line / 2)
                ctx.stroke(Path(roundedRect: outer, cornerRadius: 3.2 * k), with: .color(color), lineWidth: line)
                let inner = CGRect(origin: .zero, size: size).insetBy(dx: 3 * k, dy: 3 * k)
                ctx.fill(Path(roundedRect: inner, cornerRadius: 1.4 * k), with: .color(color.opacity(0.22)))
                let area = CGRect(x: inner.minX + region.minX * inner.width, y: inner.minY + region.minY * inner.height,
                                  width: region.width * inner.width, height: region.height * inner.height)
                ctx.fill(Path(roundedRect: area, cornerRadius: 1.4 * k), with: .color(color))
            }
            .frame(width: 18.5 * k, height: 14 * k)
            .environment(\.layoutDirection, .leftToRight)
        }
    }
}

// MARK: - Panel

@MainActor
enum UtilWindowPanel {
    static func toggle(_ w: WidgetInstance) {
        Panels.shared.toggle(w.id) { UtilWindowPanelView() }
    }

    static func show(_ w: WidgetInstance) {
        Panels.shared.show(w.id) { UtilWindowPanelView() }
    }

    /// `--scene reference` frames `windowManager-panel` and `-panel-locked` draw the panel instead of the tile.
    nonisolated static var sceneVariant: Bool { ReferenceScene.isActive && ReferenceScene.variant?.hasPrefix("panel") == true }

    static func scenePreview(_ w: WidgetInstance) -> some View {
        PanelChrome { UtilWindowPanelView() }
    }
}

/// Open windows grouped by app with focus / minimize / close, the full layout grid for the selected window
/// (top/bottom halves, thirds, quarters…) and Arrange All.
struct UtilWindowPanelView: View {
    @Environment(\.palette) private var p
    @State private var selected: CGWindowID?
    @State private var arranged: Bool?
    private var service: UtilWindowService { .shared }

    private static let layoutRows: [[UtilWinAction]] = [
        [.leftHalf, .rightHalf, .topHalf, .bottomHalf, .topLeft, .topRight, .bottomLeft, .bottomRight],
        [.leftThird, .centerThird, .rightThird, .leftTwoThirds, .rightTwoThirds, .maximize, .center, .nextDisplay]
    ]

    var body: some View {
        let groups = service.groups
        let all = groups.flatMap(\.windows)
        let target = all.first { $0.id == (selected ?? service.focusedID) } ?? all.first { !$0.minimized }
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(title: L("Windows"), subtitle: all.count == 1 ? L("1 window") : L("%@ windows", Fmt.int(all.count))) {
                Button(action: arrange) {
                    Label(L("Arrange All"), systemImage: "square.grid.2x2")
                        .font(.dock(11.5, .semibold))
                        .foregroundStyle(service.trusted ? p.primary : p.tertiary)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(Capsule().fill(arranged == false ? p.accent(.cdRed).opacity(0.3) : p.control))
                }
                .buttonStyle(PressableStyle())
                .disabled(!service.trusted)
                .help(L("Tile the visible windows of this display side by side"))
            }
            if !service.trusted { permission }
            layouts(target)
            if all.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "macwindow").font(.system(size: 22, weight: .medium)).foregroundStyle(p.tertiary)
                    Text(L("No open windows")).font(.dock(12, .medium)).foregroundStyle(p.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 90)
            } else {
                UtilWinScroll(maxHeight: Self.listLimit) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(groups) { g in group(g, target: target?.id) }
                    }
                }
            }
        }
        .frame(width: 360)
        .demand(service)
        .onAppear { service.reload() }
    }

    @MainActor static var listLimit: CGFloat {
        let dock = DockController.shared.activeWindow
        let screen = dock?.screen ?? NSScreen.main
        let room = (screen?.visibleFrame.height ?? 800) - (dock?.panel.frame.height ?? 80)
        return max(140, min(420, room - 260))
    }

    private var permission: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hand.raised.fill").font(.system(size: 17, weight: .semibold)).foregroundStyle(p.accent(.cdOrange))
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Accessibility access needed")).font(.dock(12.5, .bold)).foregroundStyle(p.primary)
                Text(L("NiceDock moves, resizes and closes windows with the macOS Accessibility API. Turn NiceDock on in Privacy & Security → Accessibility."))
                    .font(.dock(11, .medium)).foregroundStyle(p.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button { service.requestAccess() } label: {
                    Text(L("Open Privacy Settings")).font(.dock(11.5, .semibold)).foregroundStyle(p.calOnAccent)
                        .padding(.horizontal, 10).frame(height: 24)
                        .background(Capsule().fill(p.accent(.cdOrange)))
                }
                .buttonStyle(PressableStyle())
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(p.accent(.cdOrange).opacity(0.12)))
    }

    private func layouts(_ target: UtilWinEntry?) -> some View {
        let enabled = service.trusted && target != nil
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(L("Move & Resize")).font(.dock(10.5, .semibold)).foregroundStyle(p.secondary)
                if let target {
                    Text(verbatim: "·").font(.dock(10.5, .semibold)).foregroundStyle(p.tertiary)
                    Text(verbatim: Self.name(target, in: service.groups)).font(.dock(10.5, .semibold)).foregroundStyle(p.primary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            VStack(spacing: 6) {
                ForEach(0..<Self.layoutRows.count, id: \.self) { row in
                    HStack(spacing: 6) {
                        ForEach(Self.layoutRows[row]) { action in
                            Button { if let target { service.perform(action, on: target) } } label: {
                                UtilWinGlyph(action: action, color: p.accent(action.tint), scale: 0.9)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 30)
                                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(p.control))
                                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(PressableStyle())
                            .help(action.title)
                        }
                    }
                }
            }
            .environment(\.layoutDirection, .leftToRight)
            .opacity(enabled ? 1 : 0.45)
            .disabled(!enabled)
        }
    }

    private func group(_ g: UtilWinGroup, target: CGWindowID?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 7) {
                if let path = g.appPath, ReferenceScene.isActive, let art = AppsScene.icon(path) {
                    // Scene renders use the flat bundle artwork (system icons render as HDR and vary by Mac).
                    Image(nsImage: art.image).resizable().interpolation(.high)
                        .frame(width: 18 * art.scale, height: 18 * art.scale)
                        .frame(width: 18, height: 18)
                } else if let path = g.appPath {
                    AppIcon(path: path, size: 18)
                } else {
                    Image(systemName: "app.dashed").font(.system(size: 15)).foregroundStyle(p.tertiary).frame(width: 18, height: 18)
                }
                Text(verbatim: g.appName).font(.dock(12, .bold)).foregroundStyle(p.primary).lineLimit(1)
                Spacer(minLength: 6)
                Text(verbatim: Fmt.int(g.windows.count)).font(.dock(10.5, .semibold)).foregroundStyle(p.tertiary)
            }
            .padding(.horizontal, 6)
            .frame(height: 24)
            ForEach(Array(g.windows.enumerated()), id: \.element.id) { i, win in
                UtilWinRow(entry: win, title: Self.title(win, index: i, in: g), selected: win.id == target) {
                    selected = win.id
                }
            }
        }
    }

    /// Window title, or the app name / "Window 2" when the title is unavailable (no Screen Recording or Accessibility).
    static func title(_ win: UtilWinEntry, index: Int, in g: UtilWinGroup) -> String {
        if let t = win.title, !t.isEmpty { return t }
        return g.windows.count == 1 ? g.appName : L("Window %@", Fmt.int(index + 1))
    }

    static func name(_ win: UtilWinEntry, in groups: [UtilWinGroup]) -> String {
        guard let g = groups.first(where: { $0.pid == win.pid }), let i = g.windows.firstIndex(where: { $0.id == win.id }) else { return win.appName }
        let t = title(win, index: i, in: g)
        return t == g.appName ? t : g.appName + " — " + t
    }

    private func arrange() {
        let ok = service.arrangeAll()
        withAnimation(.easeOut(duration: 0.15)) { arranged = ok }
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            withAnimation { arranged = nil }
        }
    }
}

private struct UtilWinRow: View {
    @Environment(\.palette) private var p
    @State private var hover = false
    var entry: UtilWinEntry
    var title: String
    var selected: Bool
    var onSelect: () -> Void
    private var service: UtilWindowService { .shared }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .strokeBorder(selected ? p.accent(.cdBlue) : p.tertiary, lineWidth: entry.minimized ? 1.2 : 0)
                .background(Circle().fill(entry.minimized ? Color.clear : (selected ? p.accent(.cdBlue) : p.tertiary)))
                .frame(width: 6, height: 6)
            Text(verbatim: title)
                .font(.dock(12, selected ? .semibold : .medium))
                .foregroundStyle(entry.minimized ? p.secondary : p.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            if entry.minimized {
                Text(L("Minimized")).font(.dock(9.5, .semibold)).foregroundStyle(p.secondary)
                    .padding(.horizontal, 5).frame(height: 15)
                    .background(Capsule().fill(p.control))
                    .fixedSize()
            }
            Spacer(minLength: 6)
            HStack(spacing: 4) {
                // Bringing the app forward works without Accessibility; minimize and close need it.
                small("arrow.up.forward.app", L("Bring to Front")) { service.focus(entry) }
                Group {
                    small(entry.minimized ? "arrow.up.square" : "minus", entry.minimized ? L("Restore") : L("Minimize")) { service.toggleMinimized(entry) }
                    small("xmark", L("Close Window")) { service.close(entry) }
                }
                .opacity(service.trusted ? 1 : 0.4)
                .disabled(!service.trusted)
            }
            .opacity(hover || selected ? 1 : 0.55)
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? p.controlStrong : (hover ? p.control : Color.clear)))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hover = $0 }
        .help(L("Click to choose the window to move and resize"))
        .contextMenu {
            Button(L("Bring to Front")) { service.focus(entry) }
            Divider()
            ForEach(UtilWinAction.allCases) { action in
                Button(action.title) { service.perform(action, on: entry) }
            }
            Divider()
            Button(entry.minimized ? L("Restore") : L("Minimize")) { service.toggleMinimized(entry) }
            Button(L("Close Window")) { service.close(entry) }
        }
    }

    private func small(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(p.secondary)
                .frame(width: 20, height: 20)
                .background(Circle().fill(p.control))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .help(help)
    }
}

private struct UtilWinHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Sizes to its content and scrolls only beyond `maxHeight`.
private struct UtilWinScroll<Content: View>: View {
    var maxHeight: CGFloat
    @ViewBuilder var content: () -> Content
    @State private var height: CGFloat = 0

    var body: some View {
        if ReferenceScene.isActive {
            // ImageRenderer can't draw an NSScrollView.
            content()
        } else {
            ScrollView(.vertical, showsIndicators: height > maxHeight) {
                content().background(GeometryReader { g in Color.clear.preference(key: UtilWinHeightKey.self, value: g.size.height) })
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(max(height, 1), maxHeight))
            .onPreferenceChange(UtilWinHeightKey.self) { height = $0 }
        }
    }
}
