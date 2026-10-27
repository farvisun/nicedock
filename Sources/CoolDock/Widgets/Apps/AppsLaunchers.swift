import AppKit
import SwiftUI

// MARK: - App

/// Bare app icon: launch / activate, open dropped files with the app, running dot.
struct AppsAppTile: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    let w: WidgetInstance
    @State private var targeted = false

    var body: some View {
        let path = AppsLaunch.resolve(w.string("path"))
        let settings = AppStore.shared.settings
        if ReferenceScene.isActive, ReferenceScene.variant == "badges" {
            // Scene render of Dock badges (`app-badges` frame) with the flat scene artwork; see AppsScene.
            HStack(spacing: m.gap) {
                ForEach(AppsScene.badgeApps, id: \.self) { app in
                    AppsBareSlot {
                        Group {
                            if let art = AppsScene.icon(app) {
                                Image(nsImage: art.image).resizable().interpolation(.high)
                                    .frame(width: m.u(54 * art.scale), height: m.u(54 * art.scale))
                                    .frame(width: m.u(54), height: m.u(54))
                            } else {
                                Color.clear.frame(width: m.u(54), height: m.u(54))
                            }
                        }
                        .appsBadge(AppsDockBadges.shared.badge(app))
                    }
                }
            }
        } else if ReferenceScene.isActive, ReferenceScene.variant == "menu" {
            // Scene render of the native app menus (`app-menu` frame); see AppsScene.
            // A running app with Quit / ⌥ Force Quit: the render process itself.
            let contexts = ([path] + AppsScene.menuApps.dropFirst()).map { AppsAppMenu.Context(path: $0) }
                + [AppsAppMenu.Context(path: Bundle.main.bundlePath, app: .current)]
            Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 16) {
                ForEach([0, 3], id: \.self) { row in
                    GridRow {
                        ForEach(row..<min(row + 3, contexts.count), id: \.self) { i in
                            AppsSceneMenu(title: AppsLaunch.displayName(contexts[i].path ?? ""), menu: AppsAppMenu.build(contexts[i]))
                        }
                    }
                }
            }
            .padding(12)
        } else if path.isEmpty || !AppsFS.exists(path) {
            Button { WidgetSetup.customize(w) } label: {
                AppsBareSlot {
                    RoundedRectangle(cornerRadius: m.u(10), style: .continuous)
                        .strokeBorder(p.tertiary, style: StrokeStyle(lineWidth: m.u(1.5), dash: [m.u(4), m.u(3)]))
                        .frame(width: m.u(42), height: m.u(42))
                        .overlay(Image(systemName: "plus").font(.system(size: m.u(15), weight: .semibold)).foregroundStyle(p.secondary))
                }
            }
            .buttonStyle(PressableStyle())
            .help(L("Choose an app"))
        } else {
            let running = AppsLaunch.running(path) != nil
            Button { AppsLaunch.open(path) } label: {
                AppsBareSlot(dot: running && settings.showRunningIndicators, targeted: targeted) {
                    AppIcon(path: path, size: 54).appsIconStyle()
                        .appsBadge(running ? AppsDockBadges.shared.badge(path) : nil)
                }
            }
            .buttonStyle(PressableStyle())
            .appsFileDrop($targeted) { providers in
                AppsDrop.files(providers) { urls in AppsLaunch.open(urls, with: path) }
            }
            .appsAppMenu { AppsAppMenu.Context(path: path) }
            .demand(AppsDockBadges.shared)
            .task(id: path) { AppsAppMenu.prefetch(path) }
            .accessibilityLabel(AppsLaunch.displayName(path))
            .help(settings.showAppLabelsOnHover ? AppsLaunch.displayName(path) : "")
        }
    }
}

// MARK: - App Folder

struct AppsAppFolderTile: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    let w: WidgetInstance
    @State private var targeted = false

    var body: some View {
        let apps = w.list("apps").prefix(4).map(AppsLaunch.resolve)
        let tint = w.string("color")
        // Untinted folders sit on a slightly lighter plate than other tiles (as in the reference frame).
        let plain: AnyShapeStyle? = p.drawTiles ? AnyShapeStyle(p.primary.opacity(0.09)) : nil
        let fill: AnyShapeStyle? = tint.isEmpty ? plain : AnyShapeStyle(p.monochrome ? p.controlStrong : Color(hex: tint).opacity(0.45))
        Button {
            Panels.shared.toggle(w.id) { AppsAppFolderPanel(id: w.id, fallback: w) }
        } label: {
            Tile(width: w.kind.spec.width, fill: fill) {
                AppsIconQuad(paths: apps, rowGap: 2)
                    .offset(y: m.u(-0.125))
            }
        }
        .buttonStyle(PressableStyle())
        .appsDropRing(targeted)
        .appsFileDrop($targeted) { providers in
            AppsDrop.files(providers) { urls in
                let added = urls.filter { $0.pathExtension == "app" }.map(\.path)
                guard !added.isEmpty else { return }
                AppStore.shared.updateWidget(w.id) { inst in
                    var list = inst.list("apps")
                    for a in added where !list.contains(a) { list.append(a) }
                    inst.config["apps"] = list.joined(separator: "\n")
                }
            }
        }
        .help(w.string("name"))
    }
}

private struct AppsAppFolderPanel: View {
    @Environment(\.palette) private var p
    let id: UUID
    let fallback: WidgetInstance

    var body: some View {
        let w = AppStore.shared.widget(id) ?? fallback
        let apps = w.list("apps").map(AppsLaunch.resolve).filter { AppsFS.exists($0) }
        let columns = max(1, min(4, apps.count))
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(title: w.string("name", L("Apps")), subtitle: apps.count == 1 ? L("1 app") : L("%d apps", apps.count)) {
                AppsPanelButton(symbol: "slider.horizontal.3", title: L("Edit")) {
                    Panels.shared.close()
                    WidgetSetup.customize(w)
                }
            }
            if apps.isEmpty {
                AppsPanelMessage(symbol: "square.grid.2x2", text: L("Drop apps on the folder to add them."))
            } else {
                AppsScroll(height: AppsGrid.height(count: apps.count, columns: columns, icon: 50),
                           max: AppsGrid.height(count: columns * 4, columns: columns, icon: 50) + 46) {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(78), spacing: 4), count: columns), spacing: 4) {
                        ForEach(apps, id: \.self) { path in
                            AppsGridCell(title: AppsLaunch.displayName(path), dragURL: URL(fileURLWithPath: path), width: 78, truncation: .tail) {
                                AppsLaunch.open(path)
                                Panels.shared.close()
                            } icon: {
                                AppIcon(path: path, size: 50)
                                    .appsBadge(AppsLaunch.running(path) != nil ? AppsDockBadges.shared.badge(path) : nil)
                            }
                            .appsAppMenu { AppsAppMenu.Context(path: path, folder: id, inPanel: true) }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 300, alignment: .leading)
    }
}

// MARK: - Applications

struct AppsApplicationsTile: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    let w: WidgetInstance

    var body: some View {
        Button {
            AppsLibrary.shared.load()
            Panels.shared.toggle(w.id) { AppsLibraryPanel() }
        } label: {
            AppsBareSlot { AppsLauncherGlyph().appsIconStyle() }
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(L("Applications"))
        .help(AppStore.shared.settings.showAppLabelsOnHover ? L("Applications") : "")
    }
}

/// Launcher icon: colourful rounded square with a 3×3 grid, sized like a real app icon's artwork.
private struct AppsLauncherGlyph: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p

    var body: some View {
        let side = m.u(44)
        let shape = RoundedRectangle(cornerRadius: side * 0.225, style: .continuous)
        let colors: [Color] = [.cdPink, .cdOrange, .cdYellow, .cdGreen, .cdTeal, .cdBlue, .cdIndigo, .cdPurple, .cdRed]
        ZStack {
            if p.monochrome {
                shape.fill(p.controlStrong)
            } else {
                shape.fill(LinearGradient(colors: [Color(white: 0.30), Color(white: 0.12)], startPoint: .top, endPoint: .bottom))
                shape.strokeBorder(Color.white.opacity(0.14), lineWidth: m.u(0.75))
            }
            VStack(spacing: m.u(3.6)) {
                ForEach(0..<3, id: \.self) { r in
                    HStack(spacing: m.u(3.6)) {
                        ForEach(0..<3, id: \.self) { c in
                            RoundedRectangle(cornerRadius: m.u(2.6), style: .continuous)
                                .fill(p.monochrome ? p.primary : colors[r * 3 + c])
                                .frame(width: m.u(8.6), height: m.u(8.6))
                        }
                    }
                }
            }
        }
        .frame(width: side, height: side)
        .shadow(color: .black.opacity(0.3), radius: m.u(1.5), y: m.u(1))
    }
}

private struct AppsLibraryPanel: View {
    @Environment(\.palette) private var p
    @State private var query = ""
    private var library: AppsLibrary { .shared }
    private let columns = 5

    var body: some View {
        let list = library.filtered(query)
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(title: L("Applications"), subtitle: library.loaded ? (list.count == 1 ? L("1 app") : L("%d apps", list.count)) : nil) {
                AppsPanelButton(symbol: "folder", title: L("Open in Finder")) {
                    Open.path("/Applications")
                    Panels.shared.close()
                }
            }
            AppsSearchField(text: $query, placeholder: L("Search apps")) {
                if let first = list.first { launch(first) }
            }
            if !library.loaded {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 300)
            } else if list.isEmpty {
                AppsPanelMessage(symbol: "magnifyingglass", text: L("No apps found"), height: 300)
            } else {
                ScrollView(.vertical) {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(76), spacing: 2), count: columns), spacing: 4) {
                        ForEach(list) { app in
                            AppsGridCell(title: app.name, dragURL: URL(fileURLWithPath: app.path), truncation: .tail) {
                                launch(app)
                            } icon: {
                                AppIcon(path: app.path, size: 46)
                            }
                        }
                    }
                }
                .frame(height: 300)
            }
        }
        .frame(width: CGFloat(columns) * 76 + CGFloat(columns - 1) * 2)
    }

    private func launch(_ app: AppsAppEntry) {
        AppsLaunch.open(app.path)
        Panels.shared.close()
    }
}

// MARK: - App Switcher

struct AppsSwitcherTile: View {
    let w: WidgetInstance

    var body: some View {
        Button {
            Panels.shared.toggle(w.id) { AppsRunningPanel() }
        } label: {
            Tile(width: w.kind.spec.width) { AppsGridGlyph() }
        }
        .buttonStyle(PressableStyle())
    }
}

/// Running apps gallery; frontmost highlighted, click switches.
private struct AppsRunningPanel: View {
    @Environment(\.palette) private var p

    var body: some View {
        let running = RunningApps.shared
        let apps = running.apps
        let columns = max(1, min(5, apps.count))
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(title: L("Running Apps"), subtitle: apps.count == 1 ? L("1 app open") : L("%d apps open", apps.count))
            if apps.isEmpty {
                AppsPanelMessage(symbol: "app.dashed", text: L("No apps are running"))
            } else {
                AppsScroll(height: AppsGrid.height(count: apps.count, columns: columns, icon: 48),
                           max: AppsGrid.height(count: columns * 4, columns: columns, icon: 48) + 45) {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(76), spacing: 2), count: columns), spacing: 4) {
                        ForEach(apps, id: \.processIdentifier) { app in
                            AppsGridCell(title: app.localizedName ?? "", highlighted: app.processIdentifier == running.frontmost, truncation: .tail) {
                                AppsLaunch.activate(app)
                                Panels.shared.close()
                            } icon: {
                                AppsRunningIcon(app: app, size: 48)
                                    .opacity(app.isHidden ? 0.5 : 1)
                                    .appsBadge(AppsDockBadges.shared.badge(app.bundleURL?.path))
                            }
                            .appsAppMenu { AppsAppMenu.Context(path: app.bundleURL?.path, app: app, inPanel: true) }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 280, alignment: .leading)
        .demand(AppsDockBadges.shared)
    }
}

/// Icon for a running app (bundle icon via the shared cache, falling back to the process icon).
private struct AppsRunningIcon: View {
    @Environment(\.metrics) private var m
    let app: NSRunningApplication
    var size: CGFloat

    var body: some View {
        if let path = AppsLaunch.iconPath(app) {
            AppIcon(path: path, size: size)
        } else if let icon = app.icon {
            Image(nsImage: icon).resizable().interpolation(.high).frame(width: m.u(size), height: m.u(size))
        } else {
            Color.clear.frame(width: m.u(size), height: m.u(size))
        }
    }
}

// MARK: - Running Apps

/// Live cluster of running apps not already pinned in the active profile.
struct AppsRunningAppsTile: View {
    @Environment(\.metrics) private var m
    let w: WidgetInstance

    var body: some View {
        let settings = AppStore.shared.settings
        let running = RunningApps.shared
        let pinned = Set(AppStore.shared.activeProfile.widgets.filter { $0.kind == .app }.compactMap { AppsLaunch.bundleID($0.string("path")) })
        let apps = running.apps.filter { app in app.bundleIdentifier.map { !pinned.contains($0) } ?? true }
        if settings.runningAppsCollapsed {
            Button {
                Panels.shared.toggle(w.id) { AppsRunningPanel() }
            } label: {
                Tile(width: 62) {
                    if apps.isEmpty {
                        AppsGridGlyph()
                    } else {
                        AppsIconQuad(paths: apps.prefix(4).compactMap { AppsLaunch.iconPath($0) })
                    }
                }
            }
            .buttonStyle(PressableStyle())
        } else if apps.isEmpty {
            Color.clear.frame(width: 0, height: m.tileHeight)
        } else {
            HStack(spacing: m.gap) {
                ForEach(apps, id: \.processIdentifier) { app in
                    Button { AppsLaunch.activate(app) } label: {
                        AppsBareSlot(dot: settings.showRunningIndicators) {
                            AppsRunningIcon(app: app, size: 54)
                                .appsIconStyle()
                                .opacity(app.isHidden ? 0.55 : 1)
                                .appsBadge(AppsDockBadges.shared.badge(app.bundleURL?.path))
                        }
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel(app.localizedName ?? "")
                    .help(settings.showAppLabelsOnHover ? (app.localizedName ?? "") : "")
                    // Native app menu (Keep in Dock lives in Options ▸); the cluster's own items follow it.
                    .appsAppMenu { AppsAppMenu.Context(path: app.bundleURL?.path, app: app) }
                    .task(id: app.processIdentifier) { if let path = app.bundleURL?.path { AppsAppMenu.prefetch(path) } }
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: apps.map(\.processIdentifier))
            .demand(AppsDockBadges.shared)
        }
    }
}
