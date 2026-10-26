import AppKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

// Shared plumbing for the Apps & Files family: file listing, directory watching, drops,
// file operations, app launching, thumbnails and the small panel building blocks.

// MARK: - Environment

enum AppsEnv {
    /// True inside the `--render` developer harness: never touch protected folders or ask for permissions there.
    static let rendering = CommandLine.arguments.contains("--render")
}

extension DockPalette {
    /// Neutral glyph colour of the Apps & Files tiles (≈55 % of primary, as in the reference frames).
    var appsGlyph: Color { primary.opacity(0.55) }
}

// MARK: - File items & listing

struct AppsFileItem: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let date: Date
    let size: Int64?
    let isFolder: Bool
    var id: String { url.path }
}

enum AppsFS {
    static func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }

    static func exists(_ path: String, directory: Bool = false) -> Bool {
        var isDir: ObjCBool = false
        let ok = FileManager.default.fileExists(atPath: expand(path), isDirectory: &isDir)
        return ok && (!directory || isDir.boolValue)
    }

    /// "~/Documents/Work" for display.
    static func abbreviated(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

    /// One-line location: "~/Documents" or "…/Parent/Folder" when long.
    static func shortLocation(_ path: String) -> String {
        let short = abbreviated(path)
        guard short.count > 36 else { return short }
        let parts = short.split(separator: "/").suffix(2)
        return "…/" + parts.joined(separator: "/")
    }

    private static let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .creationDateKey, .contentModificationDateKey,
                                                 .fileSizeKey, .isDirectoryKey, .isPackageKey, .localizedNameKey]

    /// Newest-first (by date added) listing, done off the main thread. `nil` when unreadable / missing.
    static func list(_ dir: String, limit: Int) async -> [AppsFileItem]? {
        await Task.detached(priority: .userInitiated) { listNow(dir, limit: limit) }.value
    }

    static func listNow(_ dir: String, limit: Int) -> [AppsFileItem]? {
        let url = URL(fileURLWithPath: expand(dir), isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return nil }
        var items = urls.map(item(for:))
        items.sort { $0.date > $1.date }
        return Array(items.prefix(limit))
    }

    static func item(for u: URL) -> AppsFileItem {
        let v = try? u.resourceValues(forKeys: Set(keys))
        let folder = (v?.isDirectory ?? false) && !(v?.isPackage ?? false)
        let date = v?.addedToDirectoryDate ?? v?.creationDate ?? v?.contentModificationDate ?? .distantPast
        return AppsFileItem(url: u, name: v?.localizedName ?? u.lastPathComponent, date: date,
                            size: folder ? nil : v?.fileSize.map(Int64.init), isFolder: folder)
    }
}

/// Event-driven (kqueue) watcher for a directory's entries. No polling.
final class AppsDirWatcher {
    private let source: DispatchSourceFileSystemObject

    init?(path: String, onChange: @escaping @MainActor () -> Void) {
        let fd = open(AppsFS.expand(path), O_EVTONLY)
        guard fd >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { onChange() } }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit { source.cancel() }
}

/// Newest items of one folder, optionally kept live while something is on screen.
@Observable
@MainActor
final class AppsFolderModel {
    let path: String
    let limit: Int
    private(set) var items: [AppsFileItem] = []
    private(set) var loaded = false
    private(set) var missing = false
    @ObservationIgnored private var watcher: AppsDirWatcher?
    @ObservationIgnored private var work: Task<Void, Never>?

    init(path: String, limit: Int) {
        self.path = path
        self.limit = limit
    }

    func start(watch: Bool) {
        reload(after: 0)
        if watch, watcher == nil {
            watcher = AppsDirWatcher(path: path) { [weak self] in self?.reload(after: 0.3) }
        }
    }

    func stop() {
        watcher = nil
        work?.cancel()
    }

    func reload(after delay: Double) {
        work?.cancel()
        let path = path, limit = limit
        work = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            let result = await AppsFS.list(path, limit: limit)
            guard !Task.isCancelled, let self else { return }
            self.items = result ?? []
            self.missing = result == nil && !AppsFS.exists(path, directory: true)
            self.loaded = true
        }
    }
}

// MARK: - Drops & file operations

enum AppsDrop {
    private final class Bag: @unchecked Sendable {
        let lock = NSLock()
        var urls: [URL] = []
        func add(_ u: URL) { lock.lock(); urls.append(u); lock.unlock() }
    }

    /// Loads file URLs from dropped providers and hands them over on the main thread.
    static func files(_ providers: [NSItemProvider], _ done: @escaping @MainActor ([URL]) -> Void) -> Bool {
        let candidates = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        guard !candidates.isEmpty else { return false }
        let group = DispatchGroup()
        let bag = Bag()
        for provider in candidates {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { bag.add(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let urls = bag.urls
            MainActor.assumeIsolated { if !urls.isEmpty { done(urls) } }
        }
        return true
    }
}

enum AppsFileOps {
    /// Moves files into `dir` (copies across volumes or when ⌥ is held). Off the main thread.
    @discardableResult
    static func transfer(_ urls: [URL], into dir: String, copy forceCopy: Bool) async -> Int {
        let target = URL(fileURLWithPath: AppsFS.expand(dir), isDirectory: true)
        return await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let targetVolume = try? target.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
            var done = 0
            for src in urls {
                if src.deletingLastPathComponent().standardizedFileURL.path == target.standardizedFileURL.path { continue }
                if target.standardizedFileURL.path.hasPrefix(src.standardizedFileURL.path + "/") { continue }
                let dest = uniqueDestination(for: src.lastPathComponent, in: target)
                let srcVolume = try? src.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
                let sameVolume = srcVolume != nil && srcVolume?.isEqual(targetVolume) == true
                do {
                    if sameVolume && !forceCopy { try fm.moveItem(at: src, to: dest) } else { try fm.copyItem(at: src, to: dest) }
                    done += 1
                } catch {
                    NSLog("CoolDock: file transfer failed: \(error.localizedDescription)")
                }
            }
            return done
        }.value
    }

    /// Moves files to the Trash (ejects volumes). Off the main thread.
    @discardableResult
    static func trash(_ urls: [URL]) async -> Int {
        let volumes = urls.filter { (try? $0.resourceValues(forKeys: [.isVolumeKey]).isVolume) == true }
        for v in volumes { try? NSWorkspace.shared.unmountAndEjectDevice(at: v) }
        let files = urls.filter { !volumes.contains($0) }
        return await Task.detached(priority: .userInitiated) {
            var done = 0
            for u in files {
                do { try FileManager.default.trashItem(at: u, resultingItemURL: nil); done += 1 } catch {
                    NSLog("CoolDock: trash failed: \(error.localizedDescription)")
                }
            }
            return done
        }.value + volumes.count
    }

    static func uniqueDestination(for name: String, in dir: URL) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(name)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var i = 2
        repeat {
            candidate = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)")
            i += 1
        } while fm.fileExists(atPath: candidate.path) && i < 1000
        return candidate
    }

    /// Opens a file; ⌘-click reveals it in Finder instead.
    @MainActor static func open(_ url: URL, closePanel: Bool = true) {
        if NSEvent.modifierFlags.contains(.command) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url)
        }
        if closePanel { Panels.shared.close() }
    }

    static func dragProvider(_ url: URL) -> NSItemProvider {
        NSItemProvider(contentsOf: url) ?? NSItemProvider(object: url as NSURL)
    }
}

enum AppsSound {
    static func trash() {
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/dock/drag to trash.aif"
        NSSound(contentsOfFile: path, byReference: true)?.play()
    }
}

// MARK: - Apps: lookup, launching, activation

@MainActor
enum AppsLaunch {
    private static var ids: [String: String] = [:]
    private static var names: [String: String] = [:]
    private static var resolved: [String: String] = [:]

    /// Configured app path, repaired when the app lives elsewhere (e.g. Finder is in CoreServices).
    static func resolve(_ path: String) -> String {
        let p = AppsFS.expand(path)
        if let hit = resolved[p] { return hit }
        guard !p.isEmpty, !FileManager.default.fileExists(atPath: p) else { return p }
        let name = (p as NSString).lastPathComponent
        let dirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities",
                    "/System/Library/CoreServices", NSHomeDirectory() + "/Applications"]
        guard let hit = dirs.map({ $0 + "/" + name }).first(where: { FileManager.default.fileExists(atPath: $0) }) else { return p }
        resolved[p] = hit
        return hit
    }

    static func bundleID(_ path: String) -> String? {
        let p = AppsFS.expand(path)
        if let hit = ids[p] { return hit.isEmpty ? nil : hit }
        let id = Bundle(path: p)?.bundleIdentifier ?? ""
        ids[p] = id
        return id.isEmpty ? nil : id
    }

    static func displayName(_ path: String) -> String {
        let p = AppsFS.expand(path)
        if let hit = names[p] { return hit }
        var name = FileManager.default.displayName(atPath: p)
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        names[p] = name
        return name
    }

    /// The running instance of the app at `path` (matched by bundle id, then by resolved path).
    static func running(_ path: String) -> NSRunningApplication? {
        let apps = RunningApps.shared.apps
        if let id = bundleID(path) { return apps.first { $0.bundleIdentifier == id } }
        let resolved = URL(fileURLWithPath: AppsFS.expand(path)).resolvingSymlinksInPath().path
        return apps.first { $0.bundleURL?.resolvingSymlinksInPath().path == resolved }
    }

    /// Dock click semantics: launch, or bring the running app (and its windows) forward.
    static func open(_ path: String) {
        if let app = running(path), app.isHidden { app.unhide() }
        Open.app(path)
    }

    static func activate(_ app: NSRunningApplication) {
        if app.isHidden { app.unhide() }
        if let url = app.bundleURL {
            Open.app(url.path)
        } else {
            app.activate(options: [.activateAllWindows])
        }
    }

    static func open(_ files: [URL], with appPath: String) {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.open(files, withApplicationAt: URL(fileURLWithPath: AppsFS.expand(appPath)), configuration: cfg)
    }

    static func iconPath(_ app: NSRunningApplication) -> String? { app.bundleURL?.path }
}

/// "Show in Finder / Hide / Quit / Force Quit" items for one app.
struct AppsAppActions: View {
    var path: String?
    var app: NSRunningApplication?

    var body: some View {
        if let path { Button(L("Show in Finder")) { Open.reveal(path) } }
        if let app, !app.isTerminated {
            Divider()
            if app.isHidden {
                Button(L("Show")) { app.unhide() }
            } else {
                Button(L("Hide")) { app.hide() }
            }
            Button(L("Quit")) { app.terminate() }
            Button(L("Force Quit")) { app.forceTerminate() }
        }
    }
}

// MARK: - Installed apps (Applications widget)

struct AppsAppEntry: Identifiable, Hashable, Sendable {
    let path: String
    let name: String
    var id: String { path }
}

@Observable
@MainActor
final class AppsLibrary {
    static let shared = AppsLibrary()
    private(set) var apps: [AppsAppEntry] = []
    private(set) var loaded = false
    @ObservationIgnored private var scanning = false
    @ObservationIgnored private var scannedAt = Date.distantPast

    /// Scans once (off the main thread) and re-scans at most every 10 minutes.
    func load() {
        guard !scanning, Date().timeIntervalSince(scannedAt) > 600 || !loaded else { return }
        scanning = true
        Task {
            let found = await Task.detached(priority: .userInitiated) { AppsLibrary.scan() }.value
            self.apps = found
            self.loaded = true
            self.scanning = false
            self.scannedAt = Date()
        }
    }

    func filtered(_ query: String) -> [AppsAppEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return apps }
        let hits = apps.filter { $0.name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        return hits.sorted { a, b in
            let pa = a.name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil
            let pb = b.name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil
            return pa != pb ? pa : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    nonisolated static func scan() -> [AppsAppEntry] {
        let fm = FileManager.default
        let roots = ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"]
        var paths: [String] = []
        func visit(_ dir: String, depth: Int) {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for n in names where !n.hasPrefix(".") {
                let p = (dir as NSString).appendingPathComponent(n)
                if n.hasSuffix(".app") {
                    paths.append(p)
                } else if depth < 2 {
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue { visit(p, depth: depth + 1) }
                }
            }
        }
        roots.forEach { visit($0, depth: 0) }
        paths.append("/System/Library/CoreServices/Finder.app")
        var seen = Set<String>()
        var out: [AppsAppEntry] = []
        for p in paths {
            let key = URL(fileURLWithPath: p).resolvingSymlinksInPath().path
            guard seen.insert(key).inserted else { continue }
            var name = fm.displayName(atPath: p)
            if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
            out.append(AppsAppEntry(path: p, name: name))
        }
        return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

// MARK: - Spotlight (Find Files, Recent Files)

/// Thin NSMetadataQuery wrapper. Runs only on demand and stops as soon as results are gathered.
@Observable
@MainActor
final class AppsSpotlight {
    struct Hit: Identifiable, Hashable {
        let url: URL
        let name: String
        let date: Date?
        var id: String { url.path }
    }

    private(set) var hits: [Hit] = []
    private(set) var searching = false
    private(set) var term = ""
    @ObservationIgnored private var query: NSMetadataQuery?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var limit = 30
    @ObservationIgnored private var gatherCap = 400
    @ObservationIgnored private var rank: ((Hit) -> Int)?

    /// Files whose name contains `text`, newest first with prefix matches on top.
    func find(_ text: String, limit: Int = 30) {
        let clean = text.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "?", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { clear(); return }
        term = clean
        let predicate = NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemFSNameKey, "*\(clean)*")
        rank = { hit in
            if hit.name.range(of: clean, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil { return 0 }
            return 1
        }
        run(predicate, scopes: [NSMetadataQueryLocalComputerScope],
            sort: [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)], limit: limit, gatherCap: 400)
    }

    /// Files used in the last `days` days.
    func recents(days: Int = 7, limit: Int = 20) {
        term = ""
        let since = Date().addingTimeInterval(-Double(days) * 86_400)
        let predicate = NSPredicate(format: "%K >= %@", "kMDItemLastUsedDate", since as NSDate)
        rank = nil
        run(predicate, scopes: [NSMetadataQueryUserHomeScope],
            sort: [NSSortDescriptor(key: "kMDItemLastUsedDate", ascending: false)], limit: limit, gatherCap: 600)
    }

    func clear() {
        stop()
        hits = []
        term = ""
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        query?.stop()
        query = nil
        searching = false
    }

    private func run(_ predicate: NSPredicate, scopes: [Any], sort: [NSSortDescriptor], limit: Int, gatherCap: Int) {
        stop()
        guard !AppsEnv.rendering else { return }
        self.limit = limit
        self.gatherCap = gatherCap
        let q = NSMetadataQuery()
        q.predicate = predicate
        q.searchScopes = scopes
        q.sortDescriptors = sort
        q.notificationBatchingInterval = 0.15
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: q, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.collect(final: true) }
        })
        observers.append(nc.addObserver(forName: .NSMetadataQueryGatheringProgress, object: q, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.collect(final: false) }
        })
        query = q
        searching = true
        if !q.start() { stop() }
    }

    private func collect(final done: Bool) {
        guard let q = query else { return }
        let final = done || q.resultCount >= gatherCap
        q.disableUpdates()
        let home = NSHomeDirectory()
        var out: [Hit] = []
        let n = q.resultCount
        var i = 0
        while i < n && out.count < limit * 3 {
            defer { i += 1 }
            guard let item = q.result(at: i) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            if path.contains("/.") || path.contains("/node_modules/") || path.hasPrefix(home + "/Library/") || path.hasPrefix("/System/") || path.hasPrefix("/Library/")
                || path.hasPrefix("/private/") || path.hasPrefix("/usr/") { continue }
            if term.isEmpty {
                // Recents: skip apps and folders.
                if path.hasSuffix(".app") { continue }
                let type = item.value(forAttribute: "kMDItemContentType") as? String
                if type == "public.folder" || type == "com.apple.application-bundle" { continue }
            }
            let name = (item.value(forAttribute: NSMetadataItemDisplayNameKey) as? String) ?? (path as NSString).lastPathComponent
            let date = (item.value(forAttribute: "kMDItemLastUsedDate") as? Date) ?? (item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date)
            out.append(Hit(url: URL(fileURLWithPath: path), name: name, date: date))
        }
        if let rank {
            out = out.enumerated().sorted { a, b in
                let ra = rank(a.element), rb = rank(b.element)
                return ra != rb ? ra < rb : a.offset < b.offset
            }.map(\.element)
        }
        hits = Array(out.prefix(limit))
        if final { stop() } else { q.enableUpdates() }
    }
}

// MARK: - Thumbnails

/// Downsampled Quick Look thumbnails for images, movies and PDFs (cached, generated off the main thread).
enum AppsThumbs {
    nonisolated(unsafe) private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 200
        return c
    }()

    static func wants(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .movie) || type.conforms(to: .pdf)
    }

    static func cached(_ url: URL, size: CGFloat) -> NSImage? { cache.object(forKey: key(url, size)) }

    static func image(_ url: URL, size: CGFloat) async -> NSImage? {
        let k = key(url, size)
        if let hit = cache.object(forKey: k) { return hit }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size), scale: 2, representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        let img = rep.nsImage
        cache.setObject(img, forKey: k)
        return img
    }

    private static func key(_ url: URL, _ size: CGFloat) -> NSString { "\(url.path)#\(Int(size))" as NSString }
}

/// File icon that upgrades to a Quick Look thumbnail when one is available.
struct AppsFileIcon: View {
    @Environment(\.metrics) private var m
    var url: URL
    var size: CGFloat
    var thumbnail = true
    @State private var thumb: NSImage?

    var body: some View {
        let s = m.u(size)
        ZStack {
            if let thumb {
                Image(nsImage: thumb)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: s * 0.08, style: .continuous))
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
            } else {
                Image(nsImage: IconCache.icon(path: url.path, size: s))
                    .resizable()
                    .interpolation(.high)
            }
        }
        .frame(width: s, height: s)
        .task(id: url) {
            guard thumbnail, !AppsEnv.rendering, AppsThumbs.wants(url) else { return }
            if let hit = AppsThumbs.cached(url, size: s) { thumb = hit; return }
            thumb = await AppsThumbs.image(url, size: s)
        }
    }
}

// MARK: - Dates

enum AppsDates {
    /// "14:32", "Yesterday", "Monday", "Mar 3", "Mar 3, 2023".
    static func short(_ date: Date) -> String {
        let cal = Fmt.calendar
        if cal.isDateInToday(date) { return Fmt.clock(date) + (Fmt.ampm(date).map { " " + $0 } ?? "") }
        if cal.isDateInYesterday(date) { return L("Yesterday") }
        if let days = cal.dateComponents([.day], from: date, to: Date()).day, days < 6, days >= 0 { return Fmt.weekday(date) }
        let sameYear = cal.component(.year, from: date) == cal.component(.year, from: Date())
        return Fmt.date(date, sameYear ? "MMMd" : "yMMMd")
    }
}

// MARK: - Async helpers

enum AppsTask {
    /// Suspends until the surrounding task is cancelled (keeps `.task` scoped resources alive).
    static func untilCancelled() async {
        while !Task.isCancelled { try? await Task.sleep(for: .seconds(86_400)) }
    }
}
