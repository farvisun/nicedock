import AppKit
import SwiftUI

// MARK: - Trash

/// Trash full/empty state. ~/.Trash can't be listed without Full Disk Access, so the entry count is
/// derived from the directory's link count (APFS: 2 + entries); refreshed on demand, never polled.
@Observable
@MainActor
final class AppsTrash {
    static let shared = AppsTrash()
    private(set) var full = false
    let url = URL(fileURLWithPath: NSHomeDirectory() + "/.Trash", isDirectory: true)
    @ObservationIgnored private var observer: NSObjectProtocol?

    private init() {
        refresh()
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppsTrash.shared.refresh() }
        }
    }

    func refresh() {
        let fm = FileManager.default
        if !AppsEnv.rendering, let names = try? fm.contentsOfDirectory(atPath: url.path) {
            set(names.contains { $0 != ".DS_Store" && $0 != ".localized" })
            return
        }
        let links = ((try? fm.attributesOfItem(atPath: url.path))?[.referenceCount] as? NSNumber)?.intValue ?? 2
        set(links > 2)
    }

    private func set(_ value: Bool) { if full != value { full = value } }

    func drop(_ urls: [URL]) {
        Task {
            let n = await AppsFileOps.trash(urls)
            if n > 0 { AppsSound.trash() }
            self.refresh()
        }
    }

    func open() { NSWorkspace.shared.open(url) }

    func empty() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = L("Are you sure you want to permanently erase the items in the Trash?")
        alert.informativeText = L("You can’t undo this action.")
        alert.addButton(withTitle: L("Empty Trash"))
        alert.addButton(withTitle: L("Cancel"))
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            await Script.run("tell application \"Finder\" to empty trash")
            self.refresh()
        }
    }

    var iconPath: String {
        let base = "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/"
        let path = base + (full ? "FullTrashIcon.icns" : "TrashIcon.icns")
        return FileManager.default.fileExists(atPath: path) ? path : url.path
    }
}

/// Loads `.icns` artwork once per path (used for the Trash states).
private enum AppsArtwork {
    nonisolated(unsafe) private static var cache: [String: NSImage] = [:]

    static func image(_ path: String) -> NSImage {
        if let hit = cache[path] { return hit }
        let img = path.hasSuffix(".icns") ? (NSImage(contentsOfFile: path) ?? NSWorkspace.shared.icon(forFile: path)) : NSWorkspace.shared.icon(forFile: path)
        cache[path] = img
        return img
    }
}

struct AppsTrashTile: View {
    @Environment(\.metrics) private var m
    @State private var targeted = false
    private var trash: AppsTrash { .shared }

    var body: some View {
        Button { trash.open() } label: {
            AppsBareSlot(targeted: targeted) {
                Image(nsImage: AppsArtwork.image(trash.iconPath))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: m.u(54), height: m.u(54))
                    .appsIconStyle()
            }
        }
        .buttonStyle(PressableStyle())
        .appsFileDrop($targeted) { providers in
            AppsDrop.files(providers) { urls in trash.drop(urls) }
        }
        .accessibilityLabel(L("Trash"))
        .onHover { if $0 { trash.refresh() } }
        .onAppear { trash.refresh() }
        .help(AppStore.shared.settings.showAppLabelsOnHover ? L("Trash") : "")
    }
}

// MARK: - Folder & Dropbox

/// Bare folder icon (or stack preview of the newest items); click opens the gallery or Finder.
struct AppsFolderTile: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    @Environment(\.layoutDirection) private var direction
    let w: WidgetInstance
    @State private var targeted = false
    @State private var model: AppsFolderModel?

    var body: some View {
        let path = AppsFS.expand(w.string("path", "~/Documents"))
        let stack = w.string("display") == "stack"
        let tint = w.string("color")
        let missing = !AppsFS.exists(path, directory: true)
        Button {
            if missing {
                WidgetSetup.customize(w)
            } else if AppStore.shared.settings.openFoldersInFinder {
                Open.path(path)
            } else {
                Panels.shared.toggle(w.id) { AppsFolderPanel(path: path, title: AppsFolderTile.title(path)) }
            }
        } label: {
            AppsBareSlot(targeted: targeted) {
                ZStack {
                    if stack, let items = model?.items, !items.isEmpty {
                        AppsStackPreview(items: Array(items.prefix(3)))
                    } else {
                        AppIcon(path: missing ? "/System/Library/CoreServices/Finder.app/Contents/Resources" : path, size: 54)
                            .modifier(AppsFolderTint(hex: tint))
                            .opacity(missing ? 0.45 : 1)
                    }
                    if missing {
                        Image(systemName: "questionmark.circle.fill")
                            .font(.system(size: m.u(16), weight: .semibold))
                            .foregroundStyle(p.accent(.cdOrange))
                            .offset(x: m.u(direction == .rightToLeft ? -15 : 15), y: m.u(13))
                    }
                }
            }
        }
        .buttonStyle(PressableStyle())
        .appsFileDrop($targeted) { providers in
            AppsDrop.files(providers) { urls in
                let copy = NSEvent.modifierFlags.contains(.option)
                Task {
                    await AppsFileOps.transfer(urls, into: path, copy: copy)
                    model?.reload(after: 0)
                }
            }
        }
        .task(id: stack ? path : "") {
            guard stack, !missing, !AppsEnv.rendering else { model = nil; return }
            let mdl = AppsFolderModel(path: path, limit: 3)
            model = mdl
            mdl.start(watch: true)
            await AppsTask.untilCancelled()
            mdl.stop()
        }
        .accessibilityLabel(AppsFolderTile.title(path))
        .help(AppStore.shared.settings.showAppLabelsOnHover ? AppsFolderTile.title(path) : "")
    }

    static func title(_ path: String) -> String { FileManager.default.displayName(atPath: AppsFS.expand(path)) }
}

/// Optional colour tint for folder icons (grayscale × colour keeps the folder's shading).
private struct AppsFolderTint: ViewModifier {
    @Environment(\.palette) private var p
    var hex: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if hex.isEmpty || p.monochrome {
            content
        } else {
            content.saturation(0).colorMultiply(Color(hex: hex)).brightness(0.06)
        }
    }
}

/// Dock-style pile of the three newest items.
private struct AppsStackPreview: View {
    let items: [AppsFileItem]
    private let angles: [Double] = [0, -7, 6]
    private let offsets: [CGFloat] = [0, -3, -6]

    var body: some View {
        ZStack {
            ForEach(Array(items.enumerated().reversed()), id: \.element.id) { i, item in
                AppsFileIcon(url: item.url, size: 44)
                    .rotationEffect(.degrees(angles[min(i, 2)]))
                    .offset(y: offsets[min(i, 2)])
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
            }
        }
    }
}

/// Gallery of a folder's newest items (also used by Dropbox).
private struct AppsFolderPanel: View {
    @Environment(\.palette) private var p
    let path: String
    let title: String
    @State private var model: AppsFolderModel
    private let columns = 5

    init(path: String, title: String) {
        self.path = path
        self.title = title
        _model = State(initialValue: AppsFolderModel(path: path, limit: 30))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(title: title, subtitle: AppsFS.shortLocation(path)) {
                AppsPanelButton(symbol: "folder", title: L("Open in Finder")) {
                    Open.path(path)
                    Panels.shared.close()
                }
            }
            if !model.loaded {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 140)
            } else if model.missing {
                AppsPanelMessage(symbol: "questionmark.folder", text: L("Folder not found"))
            } else if model.items.isEmpty {
                AppsPanelMessage(symbol: "folder", text: L("This folder is empty"))
            } else {
                AppsScroll(height: AppsGrid.height(count: model.items.count, columns: columns, icon: 46),
                           max: AppsGrid.height(count: columns * 4, columns: columns, icon: 46) + 44) {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(74), spacing: 2), count: columns), spacing: 4) {
                        ForEach(model.items) { item in
                            AppsGridCell(title: item.name, dragURL: item.url, width: 74) {
                                AppsFileOps.open(item.url)
                            } icon: {
                                AppsFileIcon(url: item.url, size: 46)
                            }
                            .contextMenu {
                                Button(L("Open")) { AppsFileOps.open(item.url) }
                                Button(L("Show in Finder")) { Open.reveal(item.url.path); Panels.shared.close() }
                            }
                        }
                    }
                }
                Text(L("⌘-click to show in Finder")).font(.dock(10.5, .medium)).foregroundStyle(p.tertiary)
            }
        }
        .frame(width: CGFloat(columns) * 74 + CGFloat(columns - 1) * 2)
        .onAppear { model.start(watch: true) }
        .onDisappear { model.stop() }
    }
}

struct AppsDropboxTile: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    @Environment(\.layoutDirection) private var direction
    let w: WidgetInstance
    @State private var targeted = false

    var body: some View {
        let path = AppsDropboxTile.resolve(w.string("path", "~/Library/CloudStorage/Dropbox"))
        Button {
            if let path, AppStore.shared.settings.openFoldersInFinder {
                Open.path(path)
            } else {
                Panels.shared.toggle(w.id) {
                    if let path {
                        AppsFolderPanel(path: path, title: L("Dropbox"))
                    } else {
                        AppsDropboxMissingPanel(w: w)
                    }
                }
            }
        } label: {
            Tile(width: w.kind.spec.width) {
                AppsDropboxMark()
                    .frame(width: m.u(28), height: m.u(26))
                    .opacity(path == nil ? 0.4 : 1)
                    .overlay(alignment: .bottomTrailing) {
                        if path == nil {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: m.u(12), weight: .bold))
                                .foregroundStyle(p.accent(.cdOrange))
                                .offset(x: m.u(direction == .rightToLeft ? -6 : 6), y: m.u(5))
                        }
                    }
            }
        }
        .buttonStyle(PressableStyle())
        .appsDropRing(targeted)
        .appsFileDrop($targeted) { providers in
            guard let path else { return false }
            return AppsDrop.files(providers) { urls in
                let copy = NSEvent.modifierFlags.contains(.option)
                Task { await AppsFileOps.transfer(urls, into: path, copy: copy) }
            }
        }
    }

    @MainActor private static var lookups: [String: (path: String?, at: Date)] = [:]

    /// Configured folder, or the first Dropbox folder found in CloudStorage / home (cached briefly).
    @MainActor static func resolve(_ configured: String) -> String? {
        let p = AppsFS.expand(configured)
        if AppsFS.exists(p, directory: true) { return p }
        guard !AppsEnv.rendering else { return nil }
        if let hit = lookups[p], Date().timeIntervalSince(hit.at) < 30 { return hit.path }
        let found = search()
        lookups[p] = (found, Date())
        return found
    }

    private static func search() -> String? {
        let cloud = NSHomeDirectory() + "/Library/CloudStorage"
        if let names = try? FileManager.default.contentsOfDirectory(atPath: cloud),
           let hit = names.sorted().first(where: { $0.hasPrefix("Dropbox") }) {
            return cloud + "/" + hit
        }
        let legacy = NSHomeDirectory() + "/Dropbox"
        return AppsFS.exists(legacy, directory: true) ? legacy : nil
    }
}

private struct AppsDropboxMissingPanel: View {
    let w: WidgetInstance

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(title: L("Dropbox"))
            AppsPanelMessage(symbol: "shippingbox", text: L("Dropbox folder not found.\nInstall Dropbox or choose its folder."), height: 110)
            HStack {
                Spacer()
                AppsPanelButton(symbol: "folder.badge.gearshape", title: L("Choose Folder…")) {
                    Panels.shared.close()
                    WidgetSetup.customize(w)
                }
            }
        }
        .frame(width: 280)
    }
}

/// The Dropbox "open box" mark drawn from its geometry (no bundled artwork).
private struct AppsDropboxMark: View {
    @Environment(\.palette) private var p

    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width / 42.5, size.height / 39.6)
            let ox = (size.width - 42.5 * s) / 2, oy = (size.height - 39.6 * s) / 2
            func poly(_ pts: [(CGFloat, CGFloat)]) -> Path {
                var path = Path()
                path.addLines(pts.map { CGPoint(x: ox + $0.0 * s, y: oy + $0.1 * s) })
                path.closeSubpath()
                return path
            }
            var all = Path()
            all.addPath(poly([(12.5, 0), (0, 8.1), (8.7, 15.1), (21.3, 7.3)]))
            all.addPath(poly([(30.1, 0), (42.5, 8.1), (33.9, 15.1), (21.3, 7.3)]))
            all.addPath(poly([(0, 21.9), (12.5, 30.1), (21.3, 22.7), (8.7, 15.1)]))
            all.addPath(poly([(42.5, 21.9), (30.1, 30.1), (21.3, 22.7), (33.9, 15.1)]))
            all.addPath(poly([(21.4, 24.3), (12.6, 31.6), (8.8, 29.1), (8.8, 31.9), (21.4, 39.4), (33.9, 31.9), (33.9, 29.1), (30.2, 31.6)]))
            ctx.fill(all, with: .color(p.accent(Color(hex: "#0061FF"))))
        }
    }
}

// MARK: - Downloads

struct AppsDownloadsTile: View {
    @Environment(\.metrics) private var m
    let w: WidgetInstance
    @State private var targeted = false

    var body: some View {
        let path = NSHomeDirectory() + "/Downloads"
        Button {
            if AppStore.shared.settings.openFoldersInFinder {
                Open.path(path)
            } else {
                Panels.shared.toggle(w.id) { AppsDownloadsPanel(path: path) }
            }
        } label: {
            Tile(width: w.kind.spec.width) { AppsGlyph(symbol: "arrow.down.circle.fill", size: 22, weight: .semibold) }
        }
        .buttonStyle(PressableStyle())
        .appsDropRing(targeted)
        .appsFileDrop($targeted) { providers in
            AppsDrop.files(providers) { urls in
                let copy = NSEvent.modifierFlags.contains(.option)
                Task { await AppsFileOps.transfer(urls, into: path, copy: copy) }
            }
        }
    }
}

private struct AppsDownloadsPanel: View {
    @Environment(\.palette) private var p
    let path: String
    @State private var model: AppsFolderModel

    init(path: String) {
        self.path = path
        _model = State(initialValue: AppsFolderModel(path: path, limit: 24))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(title: L("Downloads"), subtitle: AppsFS.shortLocation(path)) {
                AppsPanelButton(symbol: "folder", title: L("Open Downloads")) {
                    Open.path(path)
                    Panels.shared.close()
                }
            }
            if !model.loaded {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 120)
            } else if model.items.isEmpty {
                AppsPanelMessage(symbol: "arrow.down.circle", text: model.missing ? L("Downloads folder not found") : L("No downloads yet"))
            } else {
                AppsScroll(height: CGFloat(model.items.count) * 42, max: 42 * 9) {
                    LazyVStack(spacing: 0) {
                        ForEach(model.items) { item in
                            AppsFileRow(url: item.url, title: item.name, detail: AppsDownloadsPanel.detail(item))
                                .contextMenu {
                                    Button(L("Open")) { AppsFileOps.open(item.url) }
                                    Button(L("Show in Finder")) { Open.reveal(item.url.path); Panels.shared.close() }
                                    Divider()
                                    Button(L("Move to Trash")) { AppsTrash.shared.drop([item.url]) }
                                }
                        }
                    }
                }
            }
        }
        .frame(width: 340)
        .onAppear { model.start(watch: true) }
        .onDisappear { model.stop() }
    }

    static func detail(_ item: AppsFileItem) -> String {
        let date = AppsDates.short(item.date)
        guard let size = item.size else { return date }
        return Fmt.bytes(Double(size)) + " · " + date
    }
}

// MARK: - Recent Files

struct AppsRecentTile: View {
    let w: WidgetInstance

    var body: some View {
        Button {
            Panels.shared.toggle(w.id) { AppsRecentPanel() }
        } label: {
            Tile(width: w.kind.spec.width) { AppsGlyph(symbol: "clock.fill", size: 22, weight: .semibold) }
        }
        .buttonStyle(PressableStyle())
    }
}

private struct AppsRecentPanel: View {
    @Environment(\.palette) private var p
    @State private var search = AppsSpotlight()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(title: L("Recent Files"), subtitle: L("Last 7 days"))
            if search.searching && search.hits.isEmpty {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 120)
            } else if search.hits.isEmpty {
                AppsPanelMessage(symbol: "clock", text: L("No recent files"))
            } else {
                AppsScroll(height: CGFloat(search.hits.count) * 42, max: 42 * 9) {
                    LazyVStack(spacing: 0) {
                        ForEach(search.hits) { hit in
                            AppsFileRow(url: hit.url, title: hit.name, detail: AppsRecentPanel.detail(hit))
                                .contextMenu {
                                    Button(L("Open")) { AppsFileOps.open(hit.url) }
                                    Button(L("Show in Finder")) { Open.reveal(hit.url.path); Panels.shared.close() }
                                }
                        }
                    }
                }
            }
        }
        .frame(width: 340)
        .onAppear { search.recents(days: 7, limit: 20) }
        .onDisappear { search.stop() }
    }

    static func detail(_ hit: AppsSpotlight.Hit) -> String {
        let folder = AppsFS.abbreviated(hit.url.deletingLastPathComponent().path)
        guard let date = hit.date else { return folder }
        return AppsDates.short(date) + " · " + folder
    }
}

// MARK: - File Shelf

struct AppsShelfTile: View {
    @Environment(\.metrics) private var m
    @Environment(\.layoutDirection) private var direction
    let w: WidgetInstance
    @State private var targeted = false

    var body: some View {
        let items = AppsShelfTile.items(w.id, fallback: w)
        Button {
            Panels.shared.toggle(w.id) { AppsShelfPanel(id: w.id, fallback: w) }
        } label: {
            Tile(width: w.kind.spec.width) {
                AppsGlyph(symbol: items.isEmpty ? "tray.fill" : "tray.full.fill", size: 21, weight: .semibold)
                    .overlay(alignment: .topTrailing) {
                        if !items.isEmpty { AppsBadge(count: items.count).offset(x: m.u(direction == .rightToLeft ? -11 : 11), y: -m.u(10)) }
                    }
            }
        }
        .buttonStyle(PressableStyle())
        .appsDropRing(targeted)
        .appsFileDrop($targeted) { providers in
            AppsDrop.files(providers) { urls in AppsShelfTile.add(urls.map(\.path), to: w.id) }
        }
    }

    static func items(_ id: UUID, fallback: WidgetInstance) -> [String] {
        (AppStore.shared.widget(id) ?? fallback).list("items")
    }

    static func add(_ paths: [String], to id: UUID) {
        AppStore.shared.updateWidget(id) { inst in
            var list = inst.list("items")
            for p in paths where !list.contains(p) { list.append(p) }
            inst.config["items"] = list.joined(separator: "\n")
        }
    }

    static func remove(_ path: String?, from id: UUID) {
        AppStore.shared.updateWidget(id) { inst in
            inst.config["items"] = path.map { p in inst.list("items").filter { $0 != p }.joined(separator: "\n") } ?? ""
        }
    }
}

private struct AppsShelfPanel: View {
    @Environment(\.palette) private var p
    let id: UUID
    let fallback: WidgetInstance

    var body: some View {
        let paths = AppsShelfTile.items(id, fallback: fallback).reversed().map { $0 }
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(title: L("File Shelf"), subtitle: paths.isEmpty ? nil : (paths.count == 1 ? L("1 file") : L("%d files", paths.count))) {
                if !paths.isEmpty {
                    AppsPanelButton(symbol: "xmark", title: L("Clear All")) { AppsShelfTile.remove(nil, from: id) }
                }
            }
            if paths.isEmpty {
                AppsPanelMessage(symbol: "tray.and.arrow.down", text: L("Drop files on the shelf to hold them here,\nthen drag them anywhere."))
            } else {
                AppsScroll(height: CGFloat(paths.count) * 42, max: 42 * 8) {
                    LazyVStack(spacing: 0) {
                        ForEach(paths, id: \.self) { path in
                            let url = URL(fileURLWithPath: path)
                            let exists = AppsFS.exists(path)
                            AppsFileRow(url: url, title: FileManager.default.displayName(atPath: path),
                                        detail: exists ? AppsFS.abbreviated(url.deletingLastPathComponent().path) : L("Missing"),
                                        dimmed: !exists) {
                                Button { AppsShelfTile.remove(path, from: id) } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 14))
                                        .foregroundStyle(p.tertiary)
                                        .contentShape(Circle())
                                }
                                .buttonStyle(PressableStyle())
                                .help(L("Remove from Shelf"))
                            }
                        }
                    }
                }
                Text(L("Drag files out to move or copy them. ⌘-click shows them in Finder."))
                    .font(.dock(10.5, .medium)).foregroundStyle(p.tertiary)
            }
        }
        .frame(width: 340)
    }
}

// MARK: - AirDrop

struct AppsAirDropTile: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    let w: WidgetInstance
    @State private var targeted = false

    var body: some View {
        Button {
            let app = "/System/Library/CoreServices/Finder.app/Contents/Applications/AirDrop.app"
            if FileManager.default.fileExists(atPath: app) { Open.app(app) } else { Open.bundle("com.apple.finder") }
        } label: {
            Tile(width: w.kind.spec.width) {
                AppsAirDropGlyph(color: targeted ? p.accent(.cdBlue) : p.appsGlyph)
                    .frame(width: m.u(26), height: m.u(26))
            }
        }
        .buttonStyle(PressableStyle())
        .appsDropRing(targeted)
        .appsFileDrop($targeted) { providers in
            AppsDrop.files(providers) { urls in
                guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
                    NSSound.beep()
                    return
                }
                NSApp.activate()
                service.perform(withItems: urls)
            }
        }
    }
}

/// AirDrop mark: centre dot inside concentric arcs open at the bottom.
private struct AppsAirDropGlyph: View {
    @Environment(\.metrics) private var m
    var color: Color

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let unit = min(size.width, size.height) / 26
            let line = 2.1 * unit
            for r in [5.2, 8.6, 12.0] {
                var arc = Path()
                arc.addArc(center: c, radius: r * unit, startAngle: .degrees(125), endAngle: .degrees(55), clockwise: false)
                ctx.stroke(arc, with: .color(color), style: StrokeStyle(lineWidth: line, lineCap: .round))
            }
            let d = 3.4 * unit
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)), with: .color(color))
        }
    }
}
