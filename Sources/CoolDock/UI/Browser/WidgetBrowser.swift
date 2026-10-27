import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The widget library: categories, search, live previews, click or drag to add.
@MainActor
enum WidgetBrowser {
    private static let host: WindowHost = {
        let h = WindowHost(id: "widgets")
        h.onClose = { AppStore.shared.browserOpen = false }
        return h
    }()

    static func show() {
        Panels.shared.close()
        AppStore.shared.browserOpen = true
        host.show(title: L("Widgets"), size: NSSize(width: 980, height: 660), minSize: NSSize(width: 760, height: 480), toolbar: true, level: .floating) {
            WidgetBrowserView()
        }
    }

    static func toggle() {
        if host.isVisible { host.close() } else { show() }
    }
}

struct WidgetBrowserView: View {
    @State private var category: WidgetCategory?
    @State private var query = ""
    @State private var justAdded: WidgetKind?
    @FocusState private var searchFocused: Bool
    private var store: AppStore { .shared }

    var body: some View {
        NavigationSplitView {
            List(selection: $category) {
                Section {
                    row(nil, title: L("All Widgets"), symbol: "square.grid.2x2", tint: .accentColor, count: WidgetCatalog.browsable.count)
                }
                Section(L("Categories")) {
                    ForEach(WidgetCategory.allCases.filter { c in WidgetCatalog.browsable.contains { $0.spec.category == c } }) { c in
                        row(c, title: c.title, symbol: c.symbol, tint: c.tint, count: WidgetCatalog.browsable.filter { $0.spec.category == c }.count)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            VStack(spacing: 0) {
                header
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 14)], alignment: .leading, spacing: 14) {
                        ForEach(filtered) { kind in
                            WidgetCard(kind: kind, added: justAdded == kind) { add(kind) }
                        }
                    }
                    .padding(18)
                }
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .background(KeyCommand(key: "f", modifiers: .command) { searchFocused = true })
    }

    private func row(_ c: WidgetCategory?, title: String, symbol: String, tint: Color, count: Int) -> some View {
        HStack {
            Label { Text(title) } icon: { SettingsIcon(symbol: symbol, tint: tint, size: 20) }
            Spacer()
            Text(Fmt.int(count)).font(.ui(11)).foregroundStyle(.secondary)
        }
        .tag(c as WidgetCategory?)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(category?.title ?? L("All Widgets")).font(.ui(18, .bold))
                Text(L("Click a card to add it to “%@”, or drag it into a specific place in the Dock.", store.activeProfile.name))
                    .font(.ui(11.5)).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L("Search widgets"), text: $query).textFieldStyle(.plain).focused($searchFocused).frame(width: 200)
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain) }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var filtered: [WidgetKind] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return WidgetCatalog.browsable.filter { k in
            let spec = k.spec
            if let category, spec.category != category { return false }
            guard !q.isEmpty else { return true }
            return spec.localizedTitle.lowercased().contains(q) || spec.title.lowercased().contains(q)
                || spec.localizedSummary.lowercased().contains(q) || spec.category.title.lowercased().contains(q) || k.rawValue.lowercased().contains(q)
        }
    }

    private func add(_ kind: WidgetKind) {
        WidgetSetup.add(kind)
        withAnimation(.spring(response: 0.3)) { justAdded = kind }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if justAdded == kind { justAdded = nil } }
    }
}

struct WidgetCard: View {
    let kind: WidgetKind
    var added: Bool
    var onAdd: () -> Void
    @State private var hovering = false
    private var store: AppStore { .shared }

    var body: some View {
        let spec = kind.spec
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                WallpaperBackdrop().opacity(0.9)
                WidgetHost(instance: WidgetBrowserSamples.instance(kind))
                    .allowsHitTesting(false)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(store.palette.plate == .clear ? Color.black.opacity(0.35) : store.palette.plate))
                    .environment(\.palette, store.palette)
                    .environment(\.metrics, DockMetrics(scale: previewScale(spec.width), spacing: 6, cornerRadius: store.settings.cornerRadius))
                    .environment(\.layoutDirection, store.layoutDirection)
            }
            .frame(height: 108)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(spec.localizedTitle).font(.ui(13, .semibold))
                        if spec.connected {
                            Text(L("Connected")).font(.ui(9.5, .bold)).padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Color.cdPurple.opacity(0.16))).foregroundStyle(Color.cdPurple)
                        }
                    }
                    Text(spec.localizedSummary).font(.ui(11)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button(action: onAdd) {
                    Image(systemName: added ? "checkmark.circle.fill" : "plus.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(added ? Color.cdGreen : Color.accentColor)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .help(L("Add to Dock"))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(hovering ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08), lineWidth: hovering ? 1.5 : 1))
        .scaleEffect(hovering ? 1.01 : 1)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
        .onTapGesture(count: 1, perform: onAdd)
        .onDrag {
            let p = NSItemProvider()
            p.registerDataRepresentation(forTypeIdentifier: UTType.coolDockWidget.identifier, visibility: .all) { done in
                done(kind.rawValue.data(using: .utf8), nil)
                return nil
            }
            return p
        }
    }

    private func previewScale(_ width: CGFloat) -> CGFloat {
        let maxW: CGFloat = 270
        return min(1, maxW / max(width, 1))
    }
}

/// Instances used for previews (stable ids so live data loads once per card).
@MainActor
enum WidgetBrowserSamples {
    private static var cache: [WidgetKind: WidgetInstance] = [:]
    static func instance(_ kind: WidgetKind) -> WidgetInstance {
        if let i = cache[kind] { return i }
        var config: [String: String] = [:]
        switch kind {
        case .app: config["path"] = "/System/Applications/Calendar.app"
        default: break
        }
        let i = WidgetInstance(kind: kind, config: config)
        cache[kind] = i
        return i
    }
}

/// Invisible button that registers a keyboard shortcut.
struct KeyCommand: View {
    var key: KeyEquivalent
    var modifiers: EventModifiers
    var action: () -> Void
    var body: some View {
        Button("", action: action).keyboardShortcut(key, modifiers: modifiers).opacity(0).frame(width: 0, height: 0)
    }
}
