import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Folder window of the Folder and Dropbox tiles: search, sorting, kind filters and multi-level navigation with a
// breadcrumb bar, all usable from the keyboard. Subfolders preview their first items like Dock stacks.

// MARK: - Sorting, filtering, search

enum AppsFolderSort: String, CaseIterable, Sendable {
    case name, added, modified, size, kind

    var title: String {
        switch self {
        case .name: return L("Name")
        case .added: return L("Date Added")
        case .modified: return L("Date Modified")
        case .size: return L("Size")
        case .kind: return L("Kind")
        }
    }

    /// Names and kinds read A→Z, dates and sizes newest / biggest first (as in Finder).
    var defaultAscending: Bool { self == .name || self == .kind }
}

enum AppsFolderFilter: String, CaseIterable, Sendable {
    case all, folders, documents, images, media, apps, archives

    var title: String {
        switch self {
        case .all: return L("All Kinds")
        case .folders: return L("Folders")
        case .documents: return L("Documents")
        case .images: return L("Images")
        case .media: return L("Audio & Video")
        case .apps: return L("Apps")
        case .archives: return L("Archives")
        }
    }

    var symbol: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .folders: return "folder"
        case .documents: return "doc.text"
        case .images: return "photo"
        case .media: return "play.rectangle"
        case .apps: return "app"
        case .archives: return "archivebox"
        }
    }
}

enum AppsFolderQuery {
    private static let documentTypes: [UTType] = [.text, .pdf, .compositeContent, .presentation, .spreadsheet, .epub, .rtf, .rtfd]
    private static let documentIDs: Set<String> = [
        "com.apple.iwork.pages.sffpages", "com.apple.iwork.numbers.sffnumbers", "com.apple.iwork.keynote.sffkey",
        "com.apple.iwork.pages.pages", "com.apple.iwork.numbers.numbers", "com.apple.iwork.keynote.key",
        "org.openxmlformats.wordprocessingml.document", "com.microsoft.word.doc", "org.oasis-open.opendocument.text"
    ]

    /// The kind filter an item belongs to (`.all` for anything none of the others cover).
    static func category(_ item: AppsFileItem) -> AppsFolderFilter {
        if item.isFolder { return .folders }
        let ext = item.url.pathExtension.lowercased()
        guard let type = UTType(item.type) ?? UTType(filenameExtension: ext) else { return ext == "app" ? .apps : .all }
        if ext == "app" || type.conforms(to: .application) { return .apps }
        if type.conforms(to: .image) { return .images }
        if type.conforms(to: .audiovisualContent) { return .media }
        if type.conforms(to: .archive) || type.conforms(to: .diskImage) { return .archives }
        if documentIDs.contains(type.identifier) || documentTypes.contains(where: type.conforms(to:)) { return .documents }
        return .all
    }

    /// Every word of `query` appears in the name (case and diacritics ignored).
    static func matches(_ name: String, _ query: String) -> Bool {
        query.split(whereSeparator: \.isWhitespace).allSatisfy { name.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil }
    }

    static func apply(_ items: [AppsFileItem], query: String, filter: AppsFolderFilter, sort: AppsFolderSort, ascending: Bool) -> [AppsFileItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let kept = items.filter { item in
            (filter == .all || category(item) == filter) && (q.isEmpty || matches(item.name, q))
        }
        func byName(_ a: AppsFileItem, _ b: AppsFileItem) -> Bool { a.name.localizedStandardCompare(b.name) == .orderedAscending }
        return kept.sorted { a, b in
            switch sort {
            case .name:
                let r = a.name.localizedStandardCompare(b.name)
                return r == .orderedSame ? a.url.path < b.url.path : (r == .orderedAscending) == ascending
            case .added:
                return a.date == b.date ? byName(a, b) : (a.date < b.date) == ascending
            case .modified:
                return a.modified == b.modified ? byName(a, b) : (a.modified < b.modified) == ascending
            case .size:
                // Folders have no size: they go after the files when biggest-first, before them when smallest-first.
                let sa = a.size ?? -1, sb = b.size ?? -1
                return sa == sb ? byName(a, b) : (sa < sb) == ascending
            case .kind:
                if a.isFolder != b.isFolder { return a.isFolder == ascending }
                let r = a.kind.localizedStandardCompare(b.kind)
                return r == .orderedSame ? byName(a, b) : (r == .orderedAscending) == ascending
            }
        }
    }
}

// MARK: - Breadcrumbs

struct AppsFolderCrumb: Hashable, Sendable {
    let title: String
    let path: String
}

/// Where the folder window is, below the folder the tile shows. Never climbs above that root.
struct AppsFolderTrail: Equatable, Sendable {
    let root: String
    private(set) var path: String

    init(root: String) {
        self.root = AppsFolderTrail.standardize(root)
        path = self.root
    }

    static func standardize(_ path: String) -> String {
        var p = URL(fileURLWithPath: AppsFS.expand(path)).standardizedFileURL.path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    private var components: [String] {
        guard path != root else { return [] }
        return path.dropFirst(root == "/" ? 1 : root.count + 1).split(separator: "/").map(String.init)
    }

    var depth: Int { components.count }
    var canGoUp: Bool { path != root }

    /// Root first. `title` names each level (the root's title is the tile's name).
    func crumbs(rootTitle: String, title: (String) -> String = { ($0 as NSString).lastPathComponent }) -> [AppsFolderCrumb] {
        var out = [AppsFolderCrumb(title: rootTitle, path: root)]
        var current = root
        for c in components {
            current = current == "/" ? "/" + c : current + "/" + c
            out.append(AppsFolderCrumb(title: title(current), path: current))
        }
        return out
    }

    /// Opens a folder inside the root (any depth). Returns false (and stays put) for anything outside it.
    @discardableResult
    mutating func enter(_ dir: String) -> Bool {
        let d = AppsFolderTrail.standardize(dir)
        guard d != path, d == root || d.hasPrefix(root == "/" ? "/" : root + "/") else { return false }
        path = d
        return true
    }

    mutating func up() {
        guard canGoUp else { return }
        path = (path as NSString).deletingLastPathComponent
    }

    /// Jumps to crumb `index` (0 = root).
    mutating func jump(to index: Int) {
        let list = crumbs(rootTitle: "")
        guard list.indices.contains(index) else { return }
        path = list[index].path
    }
}

// MARK: - Model

@Observable
@MainActor
final class AppsFolderBrowser {
    let rootTitle: String
    let widgetID: UUID?
    private(set) var trail: AppsFolderTrail
    private(set) var items: [AppsFileItem] = []
    private(set) var visible: [AppsFileItem] = []
    private(set) var loaded = false
    private(set) var missing = false
    private(set) var denied = false
    private(set) var sort: AppsFolderSort
    private(set) var ascending: Bool
    var query = "" { didSet { if query != oldValue { refilter(); selection = nil } } }
    var filter: AppsFolderFilter = .all { didSet { if filter != oldValue { refilter(); selection = nil } } }
    var selection: Int?
    @ObservationIgnored private var watcher: AppsDirWatcher?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var reselect: String?
    @ObservationIgnored private var active = false
    nonisolated private static let cap = 5000

    init(path: String, title: String, widget: WidgetInstance? = nil) {
        rootTitle = title
        widgetID = widget?.id
        trail = AppsFolderTrail(root: path)
        let s = widget.flatMap { AppsFolderSort(rawValue: $0.string("sort")) } ?? .added
        sort = s
        ascending = widget.flatMap { w in w.string("sortOrder").isEmpty ? nil : w.string("sortOrder") == "ascending" } ?? s.defaultAscending
        if AppsEnv.rendering {
            if let w = widget, ReferenceScene.isActive { applyScene(w) }
            apply(AppsFS.listNow(trail.path, limit: Self.cap))
        }
    }

    var path: String { trail.path }
    var title: String { trail.canGoUp ? FileManager.default.displayName(atPath: path) : rootTitle }
    var crumbs: [AppsFolderCrumb] { trail.crumbs(rootTitle: rootTitle) { FileManager.default.displayName(atPath: $0) } }

    func start() {
        guard !AppsEnv.rendering else { return }
        active = true
        load(after: 0)
        watch()
    }

    func stop() {
        active = false
        watcher = nil
        work?.cancel()
    }

    // Navigation

    func enter(_ item: AppsFileItem) {
        guard item.isFolder else { return }
        var t = trail
        guard t.enter(item.url.path) else { return }
        moved(to: t, select: nil)
    }

    func up() {
        guard trail.canGoUp else { return }
        var t = trail
        t.up()
        moved(to: t, select: trail.path)
    }

    func jump(to index: Int) {
        var t = trail
        t.jump(to: index)
        guard t != trail else { return }
        moved(to: t, select: crumbs.indices.contains(index + 1) ? crumbs[index + 1].path : nil)
    }

    /// The previous listing stays up until the new one arrives (milliseconds), so the panel never flashes a spinner.
    private func moved(to t: AppsFolderTrail, select: String?) {
        trail = t
        query = ""
        selection = nil
        reselect = select
        missing = false
        denied = false
        watcher = nil
        guard active else { return }
        load(after: 0)
        watch()
    }

    /// Opens an item: folders drill in (⌘ reveals them in Finder), files open (⌘ reveals).
    func open(_ item: AppsFileItem) {
        if item.isFolder && !NSEvent.modifierFlags.contains(.command) { enter(item) } else { AppsFileOps.open(item.url) }
    }

    // Sorting

    func setSort(_ s: AppsFolderSort) {
        guard s != sort else { return }
        sort = s
        ascending = s.defaultAscending
        persistSort()
    }

    func setAscending(_ value: Bool) {
        guard value != ascending else { return }
        ascending = value
        persistSort()
    }

    private func persistSort() {
        refilter()
        guard let id = widgetID, !AppsEnv.rendering else { return }
        let s = sort.rawValue, order = ascending ? "ascending" : "descending"
        AppStore.shared.updateWidget(id) { inst in
            inst.config["sort"] = s
            inst.config["sortOrder"] = order
        }
    }

    // Keyboard

    func move(_ delta: Int) {
        guard !visible.isEmpty else { return }
        guard let current = selection else { selection = 0; return }
        selection = min(max(current + delta, 0), visible.count - 1)
    }

    func openSelection() {
        guard !visible.isEmpty else { return }
        open(visible[min(selection ?? 0, visible.count - 1)])
    }

    // Loading

    private func watch() {
        watcher = AppsDirWatcher(path: path) { [weak self] in self?.load(after: 0.3) }
    }

    private func load(after delay: Double) {
        work?.cancel()
        let dir = path
        work = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) { AppsFS.listNow(dir, limit: AppsFolderBrowser.cap) }.value
            guard !Task.isCancelled, let self, self.path == dir else { return }
            self.apply(result)
        }
    }

    private func apply(_ result: [AppsFileItem]?) {
        items = result ?? []
        missing = result == nil && !AppsFS.exists(path, directory: true)
        denied = result == nil && !missing
        loaded = true
        refilter()
        if let target = reselect, let i = visible.firstIndex(where: { $0.url.path == target }) { selection = i }
        reselect = nil
    }

    private func refilter() {
        visible = AppsFolderQuery.apply(items, query: query, filter: filter, sort: sort, ascending: ascending)
        if let s = selection, s >= visible.count { selection = visible.isEmpty ? nil : visible.count - 1 }
    }

    /// Reference-scene state (render harness only): sub-folder, search, filter and keyboard selection.
    private func applyScene(_ w: WidgetInstance) {
        let sub = w.string("scene.sub")
        if !sub.isEmpty { trail.enter(trail.root + "/" + sub) }
        query = w.string("scene.query")
        filter = AppsFolderFilter(rawValue: w.string("scene.filter")) ?? .all
        selection = Int(w.string("scene.select"))
    }
}

// MARK: - Subfolder previews

/// First items of subfolders (cached for a minute), never read across into a different protected location.
@MainActor
enum AppsFolderPreviews {
    private static var cache: [String: (at: Date, urls: [URL])] = [:]

    nonisolated static func allowed(_ path: String, root: String) -> Bool {
        let zone = AppsFS.protectedZone(path)
        return zone == nil || zone == AppsFS.protectedZone(root)
    }

    static func cached(_ url: URL) -> [URL]? {
        guard let hit = cache[url.path], Date().timeIntervalSince(hit.at) < 60 else { return nil }
        return hit.urls
    }

    static func loadNow(_ url: URL, root: String) -> [URL] {
        guard allowed(url.path, root: root) else { return [] }
        return store(url, (AppsFS.listNow(url.path, limit: 3) ?? []).map(\.url))
    }

    static func load(_ url: URL, root: String) async -> [URL] {
        if let hit = cached(url) { return hit }
        guard allowed(url.path, root: root) else { return [] }
        let path = url.path
        let found = await Task.detached(priority: .utility) { (AppsFS.listNow(path, limit: 3) ?? []).map(\.url) }.value
        return store(url, found)
    }

    private static func store(_ url: URL, _ urls: [URL]) -> [URL] {
        if cache.count > 400 { cache.removeAll() }
        cache[url.path] = (Date(), urls)
        return urls
    }
}

/// Grid icon: files show their icon / thumbnail, folders show their first items on the folder, like a Dock stack.
private struct AppsFolderItemIcon: View {
    let item: AppsFileItem
    let root: String
    @State private var preview: [URL]

    init(item: AppsFileItem, root: String) {
        self.item = item
        self.root = root
        let initial = item.isFolder ? (AppsEnv.rendering ? AppsFolderPreviews.loadNow(item.url, root: root) : AppsFolderPreviews.cached(item.url) ?? []) : []
        _preview = State(initialValue: initial)
    }

    var body: some View {
        if item.isFolder {
            AppsFileIcon(url: item.url, size: 46, thumbnail: false)
                .overlay(alignment: .bottom) {
                    if !preview.isEmpty {
                        HStack(spacing: -5) {
                            ForEach(preview, id: \.self) { url in
                                AppsFileIcon(url: url, size: 17)
                                    .shadow(color: .black.opacity(0.3), radius: 0.8, y: 0.5)
                            }
                        }
                        .padding(.bottom, 8)
                        .allowsHitTesting(false)
                    }
                }
                .task(id: item.url) {
                    guard !AppsEnv.rendering else { return }
                    preview = await AppsFolderPreviews.load(item.url, root: root)
                }
        } else {
            AppsFileIcon(url: item.url, size: 46)
        }
    }
}

// MARK: - Keyboard

/// Local key monitor scoped to the pop-up panel (arrows, Return, ⌘↑, Delete).
@MainActor
private final class AppsPanelKeys {
    private var token: Any?

    func start(_ handle: @escaping @MainActor (NSEvent) -> Bool) {
        stop()
        guard !AppsEnv.rendering else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { event.window is PopPanel && handle(event) ? nil : event }
        }
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }
}

// MARK: - Panel

/// Folder window (Folder and Dropbox tiles).
struct AppsFolderPanel: View {
    @Environment(\.palette) private var p
    @Environment(\.layoutDirection) private var direction
    @State private var browser: AppsFolderBrowser
    @State private var keys = AppsPanelKeys()
    private let columns = 5
    private static let cell: CGFloat = 74

    init(path: String, title: String, widget: WidgetInstance? = nil) {
        _browser = State(initialValue: AppsFolderBrowser(path: path, title: title, widget: widget))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(title: browser.title, subtitle: AppsFS.shortLocation(browser.path)) {
                AppsPanelButton(symbol: "folder", title: L("Open in Finder")) {
                    Open.path(browser.path)
                    Panels.shared.close()
                }
            }
            if browser.trail.canGoUp { AppsCrumbBar(browser: browser) }
            if browser.loaded && !browser.items.isEmpty {
                AppsSearchField(text: $browser.query, placeholder: L("Search this folder"))
                controls
            }
            content
        }
        .frame(width: CGFloat(columns) * Self.cell + CGFloat(columns - 1) * 2)
        .onAppear {
            browser.start()
            keys.start(handle)
        }
        .onDisappear {
            browser.stop()
            keys.stop()
        }
    }

    /// Sort and kind chips with the item count; long translations drop the count, then stack the chips,
    /// so no label is ever cut.
    private var controls: some View {
        let n = browser.visible.count
        let count = Text(n == 1 ? L("1 item") : L("%d items", n)).font(.dock(11, .medium)).foregroundStyle(p.secondary).lineLimit(1).fixedSize()
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { sortChip; filterChip; Spacer(minLength: 6); count }
            HStack(spacing: 6) { sortChip; filterChip; Spacer(minLength: 0) }
            VStack(alignment: .leading, spacing: 6) { sortChip; filterChip }
        }
    }

    private var sortChip: some View {
        AppsChip(symbol: "arrow.up.arrow.down", title: browser.sort.title, accessory: browser.ascending ? "chevron.up" : "chevron.down") {
            AppsPopUp.show { m in
                for s in AppsFolderSort.allCases { m.item(s.title, checked: browser.sort == s) { browser.setSort(s) } }
                m.separator()
                m.item(L("Ascending"), checked: browser.ascending) { browser.setAscending(true) }
                m.item(L("Descending"), checked: !browser.ascending) { browser.setAscending(false) }
            }
        }
        .help(L("Sort By"))
    }

    private var filterChip: some View {
        AppsChip(symbol: browser.filter.symbol, title: browser.filter.title, accessory: "chevron.down", active: browser.filter != .all) {
            AppsPopUp.show { m in
                for f in AppsFolderFilter.allCases {
                    m.item(f.title, checked: browser.filter == f) { browser.filter = f }
                    if f == .all { m.separator() }
                }
            }
        }
        .help(L("Show"))
    }

    @ViewBuilder private var content: some View {
        if !browser.loaded {
            if AppsEnv.rendering { Color.clear.frame(height: 140) } else { ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 140) }
        } else if browser.missing {
            AppsPanelMessage(symbol: "questionmark.folder", text: L("Folder not found"))
        } else if browser.denied {
            AppsPanelMessage.denied
        } else if browser.items.isEmpty {
            AppsPanelMessage(symbol: "folder", text: L("This folder is empty"))
        } else if browser.visible.isEmpty {
            AppsPanelMessage(symbol: "magnifyingglass", text: L("No matching items"), height: 120)
        } else {
            grid
            Text(L("Return opens · ⌘↑ goes up · ⌘-click shows in Finder"))
                .font(.dock(10.5, .medium)).foregroundStyle(p.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var grid: some View {
        let list = browser.visible
        return ScrollViewReader { proxy in
            AppsScroll(height: AppsGrid.height(count: list.count, columns: columns, icon: 46),
                       max: AppsGrid.height(count: columns * 4, columns: columns, icon: 46) + 44) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.cell), spacing: 2), count: columns), spacing: AppsGrid.spacing) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, item in
                        AppsGridCell(title: item.name, highlighted: browser.selection == i, dragURL: item.url, width: Self.cell) {
                            browser.selection = i
                            browser.open(item)
                        } icon: {
                            AppsFolderItemIcon(item: item, root: browser.trail.root)
                        }
                        .id(item.id)
                        .contextMenu {
                            if item.isFolder {
                                Button(L("Open")) { browser.enter(item) }
                                Button(L("Open in Finder")) { Open.path(item.url.path); Panels.shared.close() }
                            } else {
                                Button(L("Open")) { AppsFileOps.open(item.url) }
                                Button(L("Show in Finder")) { Open.reveal(item.url.path); Panels.shared.close() }
                            }
                        }
                    }
                }
            }
            .onChange(of: browser.selection) { _, index in
                guard let index, list.indices.contains(index) else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(list[index].id) }
            }
        }
    }

    /// Arrow keys move the selection (left / right only while the search is empty), Return opens it, ⌘↑ / ⌘[ /
    /// Delete go up a level, ⌘↓ opens. Returns true when the key was used.
    private func handle(_ e: NSEvent) -> Bool {
        let cmd = e.modifierFlags.contains(.command)
        let rtl = direction == .rightToLeft
        switch e.keyCode {
        case 126 where cmd, 33 where cmd:
            guard browser.trail.canGoUp else { return false }
            browser.up()
        case 125 where cmd, 36, 76:
            browser.openSelection()
        case 51 where browser.query.isEmpty && browser.trail.canGoUp:
            browser.up()
        case 123 where browser.query.isEmpty: browser.move(rtl ? 1 : -1)
        case 124 where browser.query.isEmpty: browser.move(rtl ? -1 : 1)
        case 126: browser.move(-columns)
        case 125: browser.move(columns)
        default: return false
        }
        return true
    }
}

/// "‹  Studio › Projects › 2026" — click a level to go back to it; long trails fold their middle into "…".
private struct AppsCrumbBar: View {
    @Environment(\.palette) private var p
    let browser: AppsFolderBrowser

    var body: some View {
        let crumbs = browser.crumbs
        let folded = crumbs.count > 4
        let shown: [Int] = folded ? [0] + Array(crumbs.indices.suffix(2)) : Array(crumbs.indices)
        HStack(spacing: 3) {
            Button { browser.up() } label: {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(p.primary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(p.control))
                    .contentShape(Circle())
            }
            .buttonStyle(PressableStyle())
            .help(L("Enclosing Folder"))
            .padding(.trailing, 3)
            ForEach(shown, id: \.self) { i in
                if i != 0 { separator }
                if folded && i == shown[1] {
                    Button {
                        AppsPopUp.show { m in
                            for j in 1..<shown[1] { m.item(crumbs[j].title) { browser.jump(to: j) } }
                        }
                    } label: {
                        Text(verbatim: "…").font(.dock(12, .semibold)).foregroundStyle(p.secondary)
                    }
                    .buttonStyle(.plain)
                    separator
                }
                let last = i == crumbs.count - 1
                Button { browser.jump(to: i) } label: {
                    Text(crumbs[i].title)
                        .font(.dock(12, last ? .bold : .medium))
                        .foregroundStyle(last ? p.primary : p.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .layoutPriority(last ? 1 : 0)
            }
            Spacer(minLength: 0)
        }
    }

    private var separator: some View {
        Image(systemName: "chevron.forward").font(.system(size: 8.5, weight: .bold)).foregroundStyle(p.tertiary)
    }
}

// MARK: - Reference-scene renders (render harness only)

/// Synthetic folder used by the `folder-panel*` scene frames, created on demand in the temporary directory.
enum AppsSceneFolder {
    static var root: String { AppsSceneFiles.base.appendingPathComponent("Studio").path }

    static func prepare() -> String {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: root, isDirectory: true)
        try? fm.removeItem(at: base)
        let now = ReferenceScene.defaultNow
        let tree: [(String, Int, Double)] = [
            // path, size in bytes, days before the scene date (modification date)
            ("Clients/Acme Brief.pdf", 182_000, 3), ("Clients/Logo.png", 64_000, 9), ("Clients/Contract.docx", 41_000, 12),
            ("Invoices/Invoice 0142.pdf", 28_000, 20), ("Invoices/Invoice 0143.pdf", 29_000, 2),
            ("Photos/Beach.jpg", 2_400_000, 30), ("Photos/Sunset.jpg", 3_100_000, 31), ("Photos/Team.png", 1_200_000, 15),
            ("Projects/2026/Launch Plan.txt", 6_000, 1), ("Projects/2026/Roadmap.pdf", 220_000, 4),
            ("Projects/2026/Mockups/Home.png", 900_000, 5), ("Projects/2026/Mockups/Settings.png", 850_000, 5),
            ("Projects/2026/Budget.csv", 12_000, 6), ("Projects/2026/Kickoff.mov", 48_000_000, 8),
            ("Projects/Archive/Old Notes.txt", 3_000, 200),
            ("Annual Report 2026.pdf", 1_450_000, 1), ("Report Draft.docx", 96_000, 2), ("Meeting Notes.txt", 4_000, 0.2),
            ("Screenshot.png", 740_000, 0.5), ("Trip Video.mov", 312_000_000, 40), ("Podcast Episode.mp3", 58_000_000, 11),
            ("Design Assets.zip", 25_000_000, 16), ("گزارش سالانه.pdf", 510_000, 7)
        ]
        for (rel, size, days) in tree {
            let url = base.appendingPathComponent(rel)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: url.path, contents: Data(count: min(size, 64)))
            if let h = try? FileHandle(forWritingTo: url) { try? h.truncate(atOffset: UInt64(size)); try? h.close() }
            try? fm.setAttributes([.modificationDate: now.addingTimeInterval(-days * 86_400)], ofItemAtPath: url.path)
        }
        for dir in ["Clients", "Invoices", "Photos", "Projects", "Projects/2026", "Projects/2026/Mockups", "Projects/Archive"] {
            try? fm.setAttributes([.modificationDate: now.addingTimeInterval(-86_400)], ofItemAtPath: base.appendingPathComponent(dir).path)
        }
        return root
    }
}

/// Panel chrome for scene renders (the live panel's blur can't be drawn by the render harness).
struct AppsScenePanel<Content: View>: View {
    @Environment(\.palette) private var p
    @ViewBuilder var content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        content()
            .padding(14)
            .foregroundStyle(p.primary)
            .background(shape.fill(Color(white: 0.11)))
            .overlay(shape.strokeBorder(p.plateStroke, lineWidth: 1))
            .clipShape(shape)
            .padding(10)
            .environment(\.metrics, DockMetrics(scale: 1, spacing: AppStore.shared.settings.widgetSpacing, cornerRadius: AppStore.shared.settings.cornerRadius))
            .fixedSize()
    }
}
