import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Dock building blocks

/// 62 pt slot for bare icon widgets (apps, trash, folders) with an optional running dot.
struct AppsBareSlot<Content: View>: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    var dot = false
    var targeted = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .scaleEffect(targeted ? 1.1 : 1)
            .brightness(targeted ? 0.06 : 0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: targeted)
            .frame(width: m.u(62), height: m.tileHeight)
            .overlay(alignment: .bottom) {
                if dot {
                    Circle()
                        .fill(p.primary.opacity(0.75))
                        .frame(width: m.u(4), height: m.u(4))
                        .offset(y: -m.u(1.5))
                }
            }
            .contentShape(Rectangle())
    }
}

/// Applies the user's app icon style (Settings → Appearance) to dock icons.
struct AppsIconStyle: ViewModifier {
    @Environment(\.palette) private var p

    @ViewBuilder
    func body(content: Content) -> some View {
        switch AppStore.shared.settings.iconStyle {
        case .standard: content
        case .monochrome: content.saturation(0)
        case .dark: content.saturation(0.85).brightness(-0.1)
        case .auto:
            if p.isLight { content } else { content.saturation(0.9).brightness(-0.06) }
        }
    }
}

extension View {
    func appsIconStyle() -> some View { modifier(AppsIconStyle()) }

    /// File-URL drop target. Skipped in the render harness (ImageRenderer can't draw drop targets).
    @ViewBuilder
    func appsFileDrop(_ targeted: Binding<Bool>, perform: @escaping ([NSItemProvider]) -> Bool) -> some View {
        if AppsEnv.rendering {
            self
        } else {
            onDrop(of: [.fileURL], isTargeted: targeted, perform: perform)
        }
    }

    /// Accent ring shown while files are dragged over a tile.
    func appsDropRing(_ on: Bool) -> some View { modifier(AppsDropRing(on: on)) }
}

private struct AppsDropRing: ViewModifier {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    var on: Bool

    func body(content: Content) -> some View {
        content.overlay {
            if on {
                RoundedRectangle(cornerRadius: m.tileRadius, style: .continuous)
                    .strokeBorder(p.accent(.cdBlue), lineWidth: m.u(2))
                    .background(RoundedRectangle(cornerRadius: m.tileRadius, style: .continuous).fill(p.accentSoft(.cdBlue).opacity(0.5)))
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.12), value: on)
    }
}

/// SF Symbol glyph in the neutral tile style (downloads, recent files, shelf…).
struct AppsGlyph: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    var symbol: String
    var size: CGFloat
    var weight: Font.Weight = .semibold
    var color: Color? = nil

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: m.u(size), weight: weight))
            .foregroundStyle(color ?? p.appsGlyph)
    }
}

/// 2×2 outline squares (App Switcher), drawn to match the reference.
struct AppsGridGlyph: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    var cell: CGFloat = 8.5
    var gap: CGFloat = 1.5
    var line: CGFloat = 1.85

    var body: some View {
        // Plain circular corners: the reference glyph's cells are not squircles.
        let shape = RoundedRectangle(cornerRadius: m.u(2), style: .circular)
        VStack(spacing: m.u(gap)) {
            ForEach(0..<2, id: \.self) { _ in
                HStack(spacing: m.u(gap)) {
                    ForEach(0..<2, id: \.self) { _ in
                        shape.strokeBorder(p.appsGlyph, lineWidth: m.u(line)).frame(width: m.u(cell), height: m.u(cell))
                    }
                }
            }
        }
    }
}

/// 2×2 grid of app icons (App Folder tile, collapsed Running Apps).
struct AppsIconQuad: View {
    @Environment(\.metrics) private var m
    var paths: [String]
    var icon: CGFloat = 27
    var rowGap: CGFloat = 1.5

    var body: some View {
        VStack(spacing: m.u(rowGap)) {
            ForEach(0..<2, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<2, id: \.self) { col in
                        let i = row * 2 + col
                        if i < paths.count, ReferenceScene.isActive, let art = AppsScene.icon(paths[i]) {
                            Image(nsImage: art.image).resizable().interpolation(.high)
                                .frame(width: m.u(icon * art.scale), height: m.u(icon * art.scale))
                                .frame(width: m.u(icon), height: m.u(icon))
                        } else if i < paths.count {
                            AppIcon(path: paths[i], size: icon).appsIconStyle()
                        } else {
                            Color.clear.frame(width: m.u(icon), height: m.u(icon))
                        }
                    }
                }
            }
        }
    }
}

/// Small count badge for tiles.
struct AppsBadge: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    var count: Int

    var body: some View {
        T(count > 99 ? "99+" : Fmt.int(count))
            .font(.dock(m.u(10), .bold, mono: true))
            .foregroundStyle(p.monochrome ? (p.isLight ? Color.white : Color.black) : Color.white)
            .padding(.horizontal, m.u(4.5))
            .frame(minWidth: m.u(16), minHeight: m.u(16))
            .background(Capsule().fill(p.accent(.cdBlue)))
    }
}

// MARK: - Panel building blocks

/// Compact capsule button for panel headers and footers.
struct AppsPanelButton: View {
    @Environment(\.palette) private var p
    var symbol: String? = nil
    var title: String
    var role: ButtonRole? = nil
    var action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold)) }
                Text(title).font(.dock(11.5, .semibold)).lineLimit(1)
            }
            .foregroundStyle(role == .destructive ? p.accent(.cdRed) : p.primary)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(p.control))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
    }
}

/// Grid metrics shared by the gallery panels (cell = 7 + icon + 5 + label + 3).
enum AppsGrid {
    static let spacing: CGFloat = 4

    /// Two lines of the 11 pt name: SF Pro Rounded lines are 13 pt, Estedad's (Persian, Arabic) 17 pt.
    static var labelHeight: CGFloat { Localizer.language.usesEstedad ? 34 : 28 }

    static func height(count: Int, columns: Int, icon: CGFloat) -> CGFloat {
        let rows = (count + max(columns, 1) - 1) / max(columns, 1)
        return CGFloat(rows) * (icon + 15 + labelHeight) + CGFloat(max(rows - 1, 0)) * spacing
    }
}

/// Icon + name cell for app and file galleries. Click opens, optional drag-out.
struct AppsGridCell<Icon: View>: View {
    @Environment(\.palette) private var p
    var title: String
    var highlighted = false
    var dragURL: URL? = nil
    var width: CGFloat = 76
    var truncation: Text.TruncationMode = .middle
    var action: () -> Void
    @ViewBuilder var icon: () -> Icon
    @State private var hover = false

    var body: some View {
        VStack(spacing: 5) {
            icon()
            Text(title)
                .font(.dock(11, .medium))
                .foregroundStyle(p.primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(truncation)
                .frame(width: width - 8, height: AppsGrid.labelHeight, alignment: .top)
        }
        .padding(.top, 7)
        .padding(.bottom, 3)
        .frame(width: width)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(highlighted ? p.controlStrong : (hover ? p.control : .clear)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: action)
        .if(dragURL != nil) { v in v.onDrag { AppsFileOps.dragProvider(dragURL!) } }
    }
}

/// One file row: icon, name, detail line, optional trailing accessory. Click opens (⌘ reveals), drag-out.
struct AppsFileRow<Trailing: View>: View {
    @Environment(\.palette) private var p
    var url: URL
    var title: String
    var detail: String
    var dimmed = false
    var action: (() -> Void)? = nil
    @ViewBuilder var trailing: () -> Trailing
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            AppsFileIcon(url: url, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.dock(12.5, .semibold)).foregroundStyle(p.primary).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.dock(10.5, .medium)).foregroundStyle(p.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            trailing()
        }
        .opacity(dimmed ? 0.45 : 1)
        .padding(.horizontal, 8)
        .frame(height: 42)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(hover ? p.control : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { if let action { action() } else { AppsFileOps.open(url) } }
        .onDrag { AppsFileOps.dragProvider(url) }
    }
}

extension AppsFileRow where Trailing == EmptyView {
    init(url: URL, title: String, detail: String, dimmed: Bool = false, action: (() -> Void)? = nil) {
        self.init(url: url, title: title, detail: detail, dimmed: dimmed, action: action) { EmptyView() }
    }
}

/// Centered empty / error state inside panels.
struct AppsPanelMessage: View {
    @Environment(\.palette) private var p
    var symbol: String
    var text: String
    var height: CGFloat = 140

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 24, weight: .medium)).foregroundStyle(p.tertiary)
            Text(text).font(.dock(12, .medium)).foregroundStyle(p.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: height)
    }

    /// Shown when Files & Folders privacy blocks a read, with a shortcut to the right Settings pane.
    static var denied: some View {
        VStack(spacing: 10) {
            AppsPanelMessage(symbol: "lock.fill", text: L("CoolDock can’t read this folder. Allow access in Privacy & Security → Files & Folders."), height: 0)
                .frame(maxWidth: 300)
            AppsPanelButton(symbol: "hand.raised", title: L("Privacy Settings…")) {
                Open.url("x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")
                Panels.shared.close()
            }
        }
        .frame(maxWidth: .infinity, minHeight: 140)
    }
}

/// Rounded search field used inside panels.
struct AppsSearchField: View {
    @Environment(\.palette) private var p
    @Binding var text: String
    var placeholder: String
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold)).foregroundStyle(p.secondary)
            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(placeholder).font(.dock(13, .medium)).foregroundStyle(p.tertiary).lineLimit(1).allowsHitTesting(false)
                }
                if AppsEnv.rendering {
                    // The render harness can't draw AppKit text fields.
                    Text(verbatim: text).font(.dock(13, .medium)).foregroundStyle(p.primary).lineLimit(1)
                } else {
                    TextField("", text: $text)
                        .textFieldStyle(.plain)
                        .font(.dock(13, .medium))
                        .foregroundStyle(p.primary)
                        .focused($focused)
                        .onSubmit(onSubmit)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(p.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(p.control))
        .onAppear { DispatchQueue.main.async { focused = true } }
    }
}

/// Scroll container whose height follows its content up to `max`.
struct AppsScroll<Content: View>: View {
    var height: CGFloat
    var max: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        if AppsEnv.rendering {
            // The render harness can't draw AppKit scroll views: show the first screenful.
            content().frame(height: min(height, max), alignment: .top).clipped()
        } else {
            ScrollView(.vertical, showsIndicators: height > max) { content() }
                .frame(height: min(height, max))
        }
    }
}

/// Capsule chip that opens a pop-up menu (sort, kind filter in the folder window).
struct AppsChip: View {
    @Environment(\.palette) private var p
    var symbol: String
    var title: String
    var accessory: String = "chevron.down"
    var active = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                Text(title).font(.dock(11.5, .semibold)).lineLimit(1).fixedSize()
                Image(systemName: accessory).font(.system(size: 8, weight: .bold)).opacity(0.7)
            }
            .foregroundStyle(active ? p.accent(.cdBlue) : p.primary)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(active ? p.accentSoft(.cdBlue) : p.control))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
    }
}

// MARK: - Folder colours

struct AppsFolderColor: Hashable {
    let title: String
    /// Empty for the system folder colour.
    let hex: String
}

enum AppsFolderColors {
    static let palette: [AppsFolderColor] = [
        AppsFolderColor(title: "Default", hex: ""), AppsFolderColor(title: "Blue", hex: "#0A84FF"),
        AppsFolderColor(title: "Purple", hex: "#BF5AF2"), AppsFolderColor(title: "Pink", hex: "#FF375F"),
        AppsFolderColor(title: "Red", hex: "#FF453A"), AppsFolderColor(title: "Orange", hex: "#FF9F0A"),
        AppsFolderColor(title: "Yellow", hex: "#FFD60A"), AppsFolderColor(title: "Green", hex: "#30D158"),
        AppsFolderColor(title: "Teal", hex: "#40C8E0"), AppsFolderColor(title: "Graphite", hex: "#8E8E93")
    ]

    nonisolated(unsafe) private static var swatches: [String: NSImage] = [:]

    /// 12 pt colour dot for menu items (outlined for Default).
    static func swatch(_ hex: String) -> NSImage {
        if let hit = swatches[hex] { return hit }
        let img = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            let dot = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
            if hex.isEmpty {
                NSColor.secondaryLabelColor.setStroke()
                dot.lineWidth = 1.2
                dot.stroke()
            } else {
                NSColor(Color(hex: hex)).setFill()
                dot.fill()
            }
            return true
        }
        img.isTemplate = false
        swatches[hex] = img
        return img
    }
}

/// Right-click ▸ Folder Color for Folder and App Folder tiles; persisted in the widget's `color`.
struct AppsFolderColorMenu: View {
    let w: WidgetInstance

    var body: some View {
        let current = w.string("color").uppercased()
        Menu(L("Folder Color")) {
            ForEach(AppsFolderColors.palette, id: \.self) { c in
                Toggle(isOn: Binding(get: { current == c.hex.uppercased() }, set: { _ in set(c.hex) })) {
                    Label { Text(L(c.title)) } icon: { Image(nsImage: AppsFolderColors.swatch(c.hex)) }
                        .labelStyle(.titleAndIcon)
                }
            }
            Divider()
            Button(L("Custom…")) { WidgetSetup.customize(w) }
        }
    }

    private func set(_ hex: String) {
        AppStore.shared.updateWidget(w.id) { $0.config["color"] = hex.isEmpty ? nil : hex }
    }
}
