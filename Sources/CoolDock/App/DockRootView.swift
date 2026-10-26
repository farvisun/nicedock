import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let coolDockWidget = UTType(exportedAs: "app.cooldock.widget-kind")
}

struct DockRootView: View {
    @Bindable var model: DockWindowModel
    private var store: AppStore { .shared }

    var body: some View {
        let s = store.settings
        let natural = naturalWidth()
        let fitScale = s.overflow == .adapt && natural > model.availableWidth ? model.availableWidth / natural : 1
        let metrics = DockMetrics(scale: s.dockScale * fitScale, spacing: s.widgetSpacing, cornerRadius: s.cornerRadius)
        let showTabs = s.showProfileSwitcher && store.profiles.count > 1 && (model.hovering || store.browserOpen)

        VStack(spacing: 6) {
            if !model.atTop { ProfileTabs(model: model).opacity(showTabs ? 1 : 0).allowsHitTesting(showTabs) }
            DockPlate(model: model)
            if model.atTop { ProfileTabs(model: model).opacity(showTabs ? 1 : 0).allowsHitTesting(showTabs) }
        }
        .animation(s.animations ? .easeOut(duration: 0.18) : nil, value: showTabs)
        .padding(.horizontal, 2)
        .environment(\.palette, store.palette)
        .environment(\.metrics, metrics)
        .environment(\.layoutDirection, store.layoutDirection)
        .environment(\.locale, Fmt.locale)
        .environment(\.calendar, Fmt.calendar)
        .id(store.languageRevision)
        .fixedSize()
    }

    /// Width at scale 1 used by "Adapt Size".
    private func naturalWidth() -> CGFloat {
        let s = store.settings
        let widgets = store.activeProfile.widgets
        let widths = widgets.reduce(CGFloat(0)) { $0 + $1.kind.spec.width * CGFloat(s.dockScale) }
        let gaps = CGFloat(max(0, widgets.count - 1)) * CGFloat(s.widgetSpacing * s.dockScale)
        return widths + gaps + DockMetrics.basePadding * 2 * CGFloat(s.dockScale) + 8
    }
}

// MARK: - Plate

struct DockPlate: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    @Bindable var model: DockWindowModel
    private var store: AppStore { .shared }
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        let s = store.settings
        let shape = RoundedRectangle(cornerRadius: m.plateRadius, style: .continuous)
        content
            .padding(m.padding)
            .background { plateBackground(shape: shape, style: s.dockStyle) }
            .overlay { if s.dockStyle != .transparent && s.dockStyle != .liquidGlass { shape.strokeBorder(p.plateStroke, lineWidth: 0.5) } }
            .clipShape(shape)
            .contentShape(shape)
            .gesture(plateDrag)
            .contextMenu { DockContextMenu() }
            .onDrop(of: [.coolDockWidget, .fileURL], isTargeted: nil) { providers in handleDrop(providers) }
            .shadow(color: .black.opacity(s.shadow && s.dockStyle != .transparent ? 0.28 : 0), radius: 12, y: 4)
            .padding(.vertical, s.shadow ? 10 : 0)
            .padding(.horizontal, s.shadow ? 14 : 0)
    }

    @ViewBuilder private var content: some View {
        let widgets = store.activeProfile.widgets
        if !model.revealed && store.settings.pauseWhenHidden && model.lastStripSize != .zero {
            // Hidden dock: unmount widgets so their timers and services stop, keep the footprint.
            Color.clear.frame(width: model.lastStripSize.width, height: model.lastStripSize.height)
        } else if widgets.isEmpty && store.settings.runningApps == .hidden {
            EmptyDockPrompt()
        } else if store.settings.overflow == .scroll {
            ScrollView(.horizontal, showsIndicators: false) { WidgetStrip(model: model) }
                .frame(maxWidth: model.availableWidth - m.padding * 2 - 28)
        } else {
            WidgetStrip(model: model)
                .background(GeometryReader { g in Color.clear.onAppear { model.lastStripSize = g.size }.onChange(of: g.size) { _, v in model.lastStripSize = v } })
        }
    }

    @ViewBuilder
    private func plateBackground(shape: RoundedRectangle, style: DockStyle) -> some View {
        let reduce = store.reduceTransparency
        switch style {
        case .liquidGlass:
            if #available(macOS 26, *), !reduce {
                Color.clear.glassEffect(.regular, in: shape)
            } else {
                ZStack { VisualEffectBlur(material: .hudWindow); shape.fill(Color.black.opacity(0.25)) }
            }
        case .lightGlass:
            ZStack {
                if !reduce { VisualEffectBlur(material: .hudWindow, appearance: .darkAqua) }
                shape.fill(p.plate)
            }
        case .darkGlass:
            ZStack {
                if !reduce { VisualEffectBlur(material: .hudWindow, appearance: .darkAqua) }
                shape.fill(p.plate)
            }
        case .white, .black:
            shape.fill(p.plate)
        case .transparent:
            Color.clear
        }
    }

    /// Plate background drag: moves a floating dock, otherwise swipes between profiles.
    private var plateDrag: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { v in
                if model.floating {
                    DockController.shared.window(for: model.screenID)?.floatingDrag(began: dragOffset == 0, ended: false)
                    dragOffset = 1
                }
            }
            .onEnded { v in
                if model.floating {
                    DockController.shared.window(for: model.screenID)?.floatingDrag(began: false, ended: true)
                    dragOffset = 0
                } else if store.settings.dragToSwitchProfiles && !Panels.shared.isOpen && !store.browserOpen && !DragState.reordering {
                    let dx = v.translation.width * (store.layoutDirection == .rightToLeft ? -1 : 1)
                    if abs(dx) > 50 { store.switchProfile(by: dx < 0 ? 1 : -1) }
                }
            }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.coolDockWidget.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.coolDockWidget.identifier) { data, _ in
                guard let data, let raw = String(data: data, encoding: .utf8), let kind = WidgetKind(rawValue: raw) else { return }
                DispatchQueue.main.async { WidgetSetup.add(kind) }
            }
            return true
        }
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async {
                    if url.pathExtension == "app" {
                        AppStore.shared.addWidget(.app, config: ["path": url.path])
                    } else {
                        var isDir: ObjCBool = false
                        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                        if isDir.boolValue { AppStore.shared.addWidget(.folder, config: ["path": url.path]) }
                    }
                }
            }
            return true
        }
        return false
    }
}

struct EmptyDockPrompt: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    var body: some View {
        Button { WidgetBrowser.show() } label: {
            HStack(spacing: m.u(8)) {
                Image(systemName: "plus.circle.fill").font(.system(size: m.u(20)))
                Text(L("Open Widgets")).font(.dock(m.u(14), .semibold))
            }
            .foregroundStyle(p.primary)
            .padding(.horizontal, m.u(18))
            .frame(height: m.tileHeight)
            .background(RoundedRectangle(cornerRadius: m.tileRadius, style: .continuous).fill(p.tileFill))
        }
        .buttonStyle(PressableStyle())
    }
}

// MARK: - Widget strip with ⌘-drag reordering

@MainActor
enum DragState {
    static var reordering = false
    /// Stable id for the virtual running-apps cluster.
    static let runningAppsID = UUID(uuidString: "00000000-0000-0000-0000-00000000A115")!
}

struct WidgetFramesKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) { value.merge(nextValue()) { $1 } }
}

struct WidgetStrip: View {
    @Environment(\.metrics) private var m
    @Bindable var model: DockWindowModel
    private var store: AppStore { .shared }
    @State private var frames: [UUID: CGRect] = [:]
    @State private var dragging: UUID?
    @State private var dragX: CGFloat = 0
    @State private var target: Int?
    private let visibility = VisibilityEvaluator.shared

    var body: some View {
        let shown = withRunningApps(store.activeProfile.widgets.filter { visibility.isVisible($0) })
        HStack(spacing: m.gap) {
            ForEach(shown) { w in
                WidgetHost(instance: w)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: WidgetFramesKey.self, value: [w.id: g.frame(in: .named("strip"))])
                    })
                    .offset(x: dragging == w.id ? dragX : 0)
                    .zIndex(dragging == w.id ? 10 : 0)
                    .scaleEffect(dragging == w.id ? 1.04 : 1)
                    .opacity(dragging == w.id ? 0.92 : 1)
                    .simultaneousGesture(reorderGesture(for: w))
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .coordinateSpace(name: "strip")
        .onPreferenceChange(WidgetFramesKey.self) { frames = $0 }
        .animation(store.settings.animations ? .spring(response: 0.32, dampingFraction: 0.82) : nil, value: shown.map(\.id))
    }

    /// Inserts the running-apps cluster according to Settings → Dock.
    private func withRunningApps(_ list: [WidgetInstance]) -> [WidgetInstance] {
        let placement = store.settings.runningApps
        guard placement != .hidden else { return list }
        var running = WidgetInstance(kind: .runningApps)
        running.id = DragState.runningAppsID
        var out = list
        let appKinds: Set<WidgetKind> = [.app, .appFolder, .applications]
        switch placement {
        case .hidden: break
        case .left: out.insert(running, at: 0)
        case .right: out.append(running)
        case .beforeApps: out.insert(running, at: out.firstIndex { appKinds.contains($0.kind) } ?? 0)
        case .afterApps: out.insert(running, at: (out.lastIndex { appKinds.contains($0.kind) }).map { $0 + 1 } ?? out.count)
        }
        return out
    }

    private func canReorder(_ w: WidgetInstance) -> Bool {
        if w.id == DragState.runningAppsID { return false }
        if store.browserOpen { return true }
        if NSEvent.modifierFlags.contains(.command) { return true }
        let isApp = [.app, .appFolder, .folder, .applications, .trash].contains(w.kind)
        return isApp && store.settings.dragAppsToRearrange
    }

    private func reorderGesture(for w: WidgetInstance) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named("strip"))
            .onChanged { v in
                if dragging == nil {
                    guard canReorder(w) else { return }
                    dragging = w.id
                    DragState.reordering = true
                    Panels.shared.close()
                }
                guard dragging == w.id, let f = frames[w.id] else { return }
                dragX = v.translation.width
                let center = f.midX + v.translation.width
                let ordered = store.activeProfile.widgets.compactMap { inst in frames[inst.id].map { (inst.id, $0) } }
                var idx = 0
                for (id, rect) in ordered where id != w.id {
                    if store.layoutDirection == .rightToLeft ? center < rect.midX : center > rect.midX { idx += 1 }
                }
                target = idx
            }
            .onEnded { _ in
                if let id = dragging, let t = target {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { store.moveWidget(id, to: t) }
                }
                dragging = nil
                dragX = 0
                target = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { DragState.reordering = false }
            }
    }
}

// MARK: - Profile tabs

struct ProfileTabs: View {
    @Environment(\.palette) private var p
    @Bindable var model: DockWindowModel
    private var store: AppStore { .shared }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(store.profiles.enumerated()), id: \.element.id) { i, profile in
                let active = profile.id == store.activeProfileID
                Button { store.switchProfile(to: i) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: profile.symbol).font(.system(size: 10, weight: .semibold))
                        Text(profile.name).font(.ui(11.5, .semibold))
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .foregroundStyle(active ? (p.isLight ? Color.white : Color.black) : p.secondary)
                    .background(Capsule().fill(active ? (p.isLight ? Color.black.opacity(0.85) : Color.white.opacity(0.92)) : Color.clear))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            if model.floating {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(p.tertiary)
                    .frame(width: 26, height: 24)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { _ in DockController.shared.window(for: model.screenID)?.floatingDrag(began: false, ended: false) }
                        .onEnded { _ in DockController.shared.window(for: model.screenID)?.floatingDrag(began: false, ended: true) })
            }
        }
        .padding(3)
        .background {
            ZStack {
                if !store.reduceTransparency { VisualEffectBlur(material: .hudWindow, appearance: p.isLight ? .aqua : .darkAqua) }
                Capsule().fill(p.isLight ? Color.white.opacity(0.7) : Color.black.opacity(0.55))
            }
            .clipShape(Capsule())
        }
        .overlay(Capsule().strokeBorder(p.plateStroke, lineWidth: 0.5))
    }
}

// MARK: - Dock context menu (empty area)

struct DockContextMenu: View {
    private var store: AppStore { .shared }

    var body: some View {
        Button(store.browserOpen ? L("Close Widgets") : L("Widgets…")) { WidgetBrowser.toggle() }
        Button(L("Settings…")) { SettingsWindow.show() }
        Divider()
        if store.profiles.count > 1 {
            Menu(L("Switch Profile")) {
                ForEach(Array(store.profiles.enumerated()), id: \.element.id) { i, p in
                    Button { store.switchProfile(to: i) } label: {
                        if p.id == store.activeProfileID { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                    }
                }
            }
        }
        Button(L("New Profile")) { store.newProfile() }.disabled(store.profiles.count >= 8)
        let conditional = store.activeProfile.widgets.filter { $0.visibility != .always }
        if !conditional.isEmpty {
            Menu(L("Hidden Widgets")) {
                ForEach(conditional) { w in
                    let hidden = !VisibilityEvaluator.shared.isVisible(w)
                    Button("\(w.kind.spec.localizedTitle) — \(w.visibility.title)\(hidden ? " · " + L("hidden now") : "")") {
                        store.updateWidget(w.id) { $0.visibility = .always }
                    }
                }
                Divider()
                Button(L("Always Show All")) {
                    for w in conditional { store.updateWidget(w.id) { $0.visibility = .always } }
                }
            }
        }
        Divider()
        Menu(L("Layout")) {
            ForEach(LayoutScenario.allCases) { sc in
                Button { store.settings.scenario = sc } label: {
                    if store.settings.scenario == sc { Label(sc.title, systemImage: "checkmark") } else { Text(sc.title) }
                }
            }
            Divider()
            Button(L("Reset Layout")) { DockController.shared.resetLayout() }
        }
        Button(L("Hide CoolDock")) { DockController.shared.toggleVisibility() }
        Divider()
        Button(L("Quit CoolDock")) { NSApp.terminate(nil) }
    }
}
