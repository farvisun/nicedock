import AppKit
import CoreServices
import Foundation
import UniformTypeIdentifiers

// App-specific knowledge for the app menus: Chromium profiles and launch arguments, mail and document apps,
// and the per-app recent documents macOS keeps for the Dock. Everything here is pure or read-only and cached.

// MARK: - Parsed file cache

/// Parsed contents of small files, re-read only when the file's modification date changes. Thread-safe, so
/// a background prefetch can warm it and the menu reads it on the main thread.
final class AppsParsedFileCache<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: (stamp: Date, value: Value)] = [:]

    func value(at url: URL, parse: (Data) -> Value) -> Value? {
        guard let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return nil }
        lock.lock()
        if let hit = store[url.path], hit.stamp == stamp {
            lock.unlock()
            return hit.value
        }
        lock.unlock()
        guard let data = try? Data(contentsOf: url) else { return nil }
        let value = parse(data)
        lock.lock()
        store[url.path] = (stamp, value)
        lock.unlock()
        return value
    }
}

// MARK: - Chromium browsers

/// One Chromium-based browser channel: where its profiles live and how it opens private windows.
struct AppsChromium: Hashable, Sendable {
    let bundleID: String
    /// Folder under `~/Library/Application Support` that holds the channel's `Local State`.
    let dataDir: String
    /// Command-line switch that opens a private window.
    let privateSwitch: String
    /// English menu title of the private window item (localized at the point of use).
    let privateTitle: String

    struct Profile: Hashable, Sendable, Identifiable {
        /// Profile folder name ("Default", "Profile 1"), passed as `--profile-directory`.
        let directory: String
        let name: String
        var id: String { directory }
    }

    enum Launch: Hashable, Sendable {
        case newWindow
        case privateWindow
        case profile(String)
    }

    private static func chrome(_ id: String, _ dir: String) -> AppsChromium {
        AppsChromium(bundleID: id, dataDir: dir, privateSwitch: "--incognito", privateTitle: "New Incognito Window")
    }

    private static func brave(_ id: String, _ dir: String) -> AppsChromium {
        AppsChromium(bundleID: id, dataDir: dir, privateSwitch: "--incognito", privateTitle: "New Private Window")
    }

    private static func edge(_ id: String, _ dir: String) -> AppsChromium {
        AppsChromium(bundleID: id, dataDir: dir, privateSwitch: "--inprivate", privateTitle: "New InPrivate Window")
    }

    static let all: [AppsChromium] = [
        chrome("com.google.Chrome", "Google/Chrome"),
        chrome("com.google.Chrome.beta", "Google/Chrome Beta"),
        chrome("com.google.Chrome.dev", "Google/Chrome Dev"),
        chrome("com.google.Chrome.canary", "Google/Chrome Canary"),
        chrome("org.chromium.Chromium", "Chromium"),
        brave("com.brave.Browser", "BraveSoftware/Brave-Browser"),
        brave("com.brave.Browser.beta", "BraveSoftware/Brave-Browser-Beta"),
        brave("com.brave.Browser.dev", "BraveSoftware/Brave-Browser-Dev"),
        brave("com.brave.Browser.nightly", "BraveSoftware/Brave-Browser-Nightly"),
        edge("com.microsoft.edgemac", "Microsoft Edge"),
        edge("com.microsoft.edgemac.Beta", "Microsoft Edge Beta"),
        edge("com.microsoft.edgemac.Dev", "Microsoft Edge Dev"),
        edge("com.microsoft.edgemac.Canary", "Microsoft Edge Canary"),
        brave("com.vivaldi.Vivaldi", "Vivaldi"),
        brave("com.vivaldi.Vivaldi.snapshot", "Vivaldi Snapshot")
    ]

    /// `privateTitle` in the UI language (literal keys, so `scripts/l10n.py extract` sees them).
    var localizedPrivateTitle: String {
        switch privateTitle {
        case "New Incognito Window": return L("New Incognito Window")
        case "New InPrivate Window": return L("New InPrivate Window")
        default: return L("New Private Window")
        }
    }

    static func spec(_ bundleID: String?) -> AppsChromium? {
        guard let bundleID else { return nil }
        return all.first { $0.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    /// `Local State` of this channel under `support` (default `~/Library/Application Support`).
    func localState(in support: URL = AppsChromium.supportDir) -> URL {
        support.appendingPathComponent(dataDir, isDirectory: true).appendingPathComponent("Local State")
    }

    /// `~/Library/Application Support` (a synthetic folder in reference-scene renders).
    static var supportDir: URL {
        if ReferenceScene.isActive { return AppsSceneFiles.base.appendingPathComponent("Support", isDirectory: true) }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    /// Profiles from a `Local State` JSON: `profile.info_cache` maps folder → `{ "name": … }`. Ordered like the
    /// browser's own profile menu (`profile.profiles_order` when present, else Default first, then by folder).
    static func profiles(localState data: Data) -> [Profile] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let profile = root["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: Any] else { return [] }
        var out: [Profile] = []
        for (dir, raw) in cache {
            guard !dir.isEmpty, dir != "System Profile", dir != "Guest Profile" else { continue }
            let info = raw as? [String: Any] ?? [:]
            if (info["is_ephemeral"] as? Bool) == true || (info["is_omitted_from_profile_list"] as? Bool) == true { continue }
            let names = [info["name"], info["shortcut_name"], info["gaia_given_name"], info["gaia_name"]].compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            out.append(Profile(directory: dir, name: names.first { !$0.isEmpty } ?? dir))
        }
        let order = (profile["profiles_order"] as? [String]) ?? []
        func rank(_ p: Profile) -> Int { order.firstIndex(of: p.directory) ?? (p.directory == "Default" ? -1 : order.count) }
        return out.sorted { a, b in
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra < rb }
            return a.directory.localizedStandardCompare(b.directory) == .orderedAscending
        }
    }

    /// Arguments for `/usr/bin/open`: `-n` asks the running browser (or a fresh launch) to open the window on the
    /// current Space; Chromium forwards the switches to the existing process.
    func openArguments(appPath: String, _ launch: Launch) -> [String] {
        var args = ["-na", appPath, "--args"]
        switch launch {
        case .newWindow: args.append("--new-window")
        case .privateWindow: args.append(privateSwitch)
        case .profile(let dir): args += ["--profile-directory=\(dir)", "--new-window"]
        }
        return args
    }

    private static let cache = AppsParsedFileCache<[Profile]>()

    /// Cached profiles of this channel (re-read when `Local State` changes). Empty when not installed / unreadable.
    func profiles(in support: URL = AppsChromium.supportDir) -> [Profile] {
        AppsChromium.cache.value(at: localState(in: support), parse: AppsChromium.profiles(localState:)) ?? []
    }
}

// MARK: - Mail and document apps

enum AppsKnownApps {
    static let safari: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]
    static let notion = "notion.id"

    /// Mail clients that get "New Message". They all handle `mailto:`; Spark also has its own compose URL.
    static let mail: Set<String> = [
        "com.apple.mail", "com.microsoft.Outlook", "com.readdle.smartemail-Mac", "com.readdle.SparkDesktop",
        "com.readdle.SparkDesktop.appstore", "it.bloop.airmail2", "com.mimestream.Mimestream", "io.canarymail.mac",
        "org.mozilla.thunderbird", "com.freron.MailMate", "com.superhuman.electron", "com.missiveapp.osx"
    ]

    /// Scriptable document apps that get "New Document" (`make new document`).
    static let documents: Set<String> = ["com.apple.iWork.Pages", "com.apple.iWork.Numbers", "com.apple.iWork.Keynote", "com.apple.TextEdit"]

    /// Apps whose "New Window" command has a known shortcut (key, with ⇧) when its title doesn't say "window".
    static let windowShortcuts: [String: (key: String, shift: Bool)] = [
        "com.apple.finder": ("N", false), "com.apple.Terminal": ("N", false), "com.googlecode.iterm2": ("N", false),
        "com.mitchellh.ghostty": ("N", false), "dev.warp.Warp-Stable": ("N", false), "company.thebrowser.Browser": ("N", false),
        "org.mozilla.firefox": ("N", false), "com.apple.Safari": ("N", false), "com.apple.SafariTechnologyPreview": ("N", false),
        "notion.id": ("N", true), "com.microsoft.VSCode": ("N", true), "com.todesktop.230313mzl4w4u92": ("N", true),
        "dev.zed.Zed": ("N", true), "com.sublimetext.4": ("N", true), "md.obsidian": ("N", true)
    ]

    /// Compose URL for a mail app: Spark's own scheme when it declares it, `mailto:` for everyone else.
    static func composeURL(bundleID: String, schemes: Set<String>) -> URL {
        if bundleID.hasPrefix("com.readdle."), schemes.contains("readdle-spark") { return URL(string: "readdle-spark://compose")! }
        return URL(string: "mailto:")!
    }

    /// URL schemes an app declares in its Info.plist (lowercased).
    static func schemes(_ bundle: Bundle?) -> Set<String> {
        let types = bundle?.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        return Set(types.flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }.map { $0.lowercased() })
    }
}

// MARK: - Recent documents

/// The per-app "Open Recent" list macOS keeps for the Dock:
/// `~/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments/<bundle id>.sfl3`
/// (`.sfl2` before macOS 13). It's a keyed archive of `{ items: [{ Bookmark: Data, … }] }`, newest first. Read-only.
enum AppsRecentDocs {
    struct Entry: Hashable, Sendable, Identifiable {
        let url: URL
        let name: String
        var id: String { url.path }
    }

    /// The system's folder of per-app lists (a synthetic folder in reference-scene renders).
    static var folder: URL {
        if ReferenceScene.isActive { return AppsSceneFiles.base.appendingPathComponent("Recents", isDirectory: true) }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments", isDirectory: true)
    }

    /// The list file for `bundleID` (newest format first, file names are usually the lowercased bundle id).
    static func file(bundleID: String, in folder: URL = folder) -> URL? {
        let fm = FileManager.default
        for ext in ["sfl3", "sfl2"] {
            for name in [bundleID.lowercased(), bundleID] {
                let url = folder.appendingPathComponent("\(name).\(ext)")
                if fm.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }

    /// Decodes the archive's bookmarks into file URLs without resolving them (no disk or network access).
    static func decode(_ data: Data) -> [Entry] {
        bookmarks(in: data).compactMap { bookmark in
            guard let path = URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: bookmark)?.path, !path.isEmpty else { return nil }
            let url = URL(fileURLWithPath: path)
            return Entry(url: url, name: url.lastPathComponent)
        }
    }

    static func bookmarks(in data: Data) -> [Data] {
        let classes: [AnyClass] = [NSDictionary.self, NSArray.self, NSString.self, NSData.self, NSNumber.self, NSUUID.self, NSDate.self, NSURL.self, NSNull.self]
        if let root = (try? NSKeyedUnarchiver.unarchivedObject(ofClasses: classes, from: data)) as? NSDictionary,
           let items = root["items"] as? [Any] {
            return items.compactMap { ($0 as? NSDictionary)?["Bookmark"] as? Data }
        }
        // Unknown classes in the archive: fall back to the raw object table, where bookmarks keep their order.
        guard let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let objects = plist["$objects"] as? [Any] else { return [] }
        let magic = Data("book".utf8)
        return objects.compactMap { $0 as? Data }.filter { $0.starts(with: magic) }
    }

    private static let cache = AppsParsedFileCache<[Entry]>()

    /// Up to `limit` recent documents of the app that still exist, with Finder display names. Cached per file.
    /// Recent macOS versions keep the Dock's lists behind Full Disk Access; without it the list comes from Spotlight
    /// (see `spotlightEntries`), computed in the background so opening a menu never waits on a query.
    static func entries(bundleID: String, limit: Int = 10, in folder: URL = folder) -> [Entry] {
        guard let file = file(bundleID: bundleID, in: folder) else {
            return folder == Self.folder && !ReferenceScene.isActive ? AppsRecentSpotlight.shared.entries(bundleID: bundleID, limit: limit) : []
        }
        let all = cache.value(at: file) { data in
            decode(data).map { Entry(url: $0.url, name: FileManager.default.displayName(atPath: $0.url.path)) }
        } ?? []
        var seen = Set<String>()
        return Array(all.filter { FileManager.default.fileExists(atPath: $0.url.path) && seen.insert($0.url.path).inserted }.prefix(limit))
    }

    /// Document types `app` opens by default (what a double-click in Finder would open it with).
    static func defaultTypes(of app: URL) -> [UTType] {
        guard let info = Bundle(url: app)?.infoDictionary, let docs = info["CFBundleDocumentTypes"] as? [[String: Any]] else { return [] }
        var types: [UTType] = []
        for d in docs {
            types += (d["LSItemContentTypes"] as? [String] ?? []).compactMap { UTType($0) }
            types += (d["CFBundleTypeExtensions"] as? [String] ?? []).filter { $0 != "*" }.compactMap { UTType(filenameExtension: $0) }
        }
        let me = app.standardizedFileURL
        var seen = Set<String>()
        return types.filter { t in
            seen.insert(t.identifier).inserted && NSWorkspace.shared.urlForApplication(toOpen: t)?.standardizedFileURL == me
        }
    }

    /// Spotlight query for files used since `days` ago whose type is one of `types`.
    static func query(_ types: [UTType], days: Int = 60) -> String {
        let clause = types.prefix(24).map { "kMDItemContentTypeTree == \"\($0.identifier)\"" }.joined(separator: " || ")
        return "kMDItemLastUsedDate >= $time.today(-\(days)) && (\(clause))"
    }

    /// Paths that are not documents a person opened: app support data, caches, hidden and trashed files.
    static func isUserDocument(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        if path.hasPrefix(home + "/Library/") || path.hasPrefix(home + "/.Trash/") || path.hasPrefix("/System/") || path.hasPrefix("/Library/") { return false }
        if path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { return false }
        return !path.contains(".app/")
    }
}

/// Spotlight-backed recent documents per app (no permission needed): files used recently that open in that app by
/// default, newest first. Results are cached for a minute and refreshed off the main thread.
final class AppsRecentSpotlight: @unchecked Sendable {
    static let shared = AppsRecentSpotlight()
    private let lock = NSLock()
    private var store: [String: (at: Date, entries: [AppsRecentDocs.Entry])] = [:]
    private var running = Set<String>()

    /// Cached entries now; schedules a refresh when missing or older than a minute.
    func entries(bundleID: String, limit: Int) -> [AppsRecentDocs.Entry] {
        lock.lock()
        let hit = store[bundleID]
        let stale = hit.map { Date().timeIntervalSince($0.at) > 60 } ?? true
        let start = stale && running.insert(bundleID).inserted
        lock.unlock()
        if start {
            DispatchQueue.global(qos: .utility).async {
                let fresh = Self.search(bundleID: bundleID, limit: 10)
                self.lock.lock()
                self.store[bundleID] = (Date(), fresh)
                self.running.remove(bundleID)
                self.lock.unlock()
            }
        }
        return Array((hit?.entries ?? []).prefix(limit))
    }

    /// Synchronous Spotlight search (call off the main thread).
    static func search(bundleID: String, limit: Int) -> [AppsRecentDocs.Entry] {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return [] }
        let types = AppsRecentDocs.defaultTypes(of: app)
        guard !types.isEmpty, let q = MDQueryCreate(kCFAllocatorDefault, AppsRecentDocs.query(types) as CFString, nil, nil) else { return [] }
        MDQuerySetMaxCount(q, 500)
        guard MDQueryExecute(q, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
        var found: [(path: String, used: Date)] = []
        for i in 0..<MDQueryGetResultCount(q) {
            guard let raw = MDQueryGetResultAtIndex(q, i) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String, AppsRecentDocs.isUserDocument(path) else { continue }
            let used = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date ?? .distantPast
            found.append((path, used))
        }
        let me = app.standardizedFileURL
        var out: [AppsRecentDocs.Entry] = []
        for f in found.sorted(by: { $0.used > $1.used }) where out.count < limit {
            let url = URL(fileURLWithPath: f.path)
            // Exact check per file: a subtype can have a different default app.
            guard NSWorkspace.shared.urlForApplication(toOpen: url)?.standardizedFileURL == me else { continue }
            out.append(.init(url: url, name: FileManager.default.displayName(atPath: f.path)))
        }
        return out
    }
}
