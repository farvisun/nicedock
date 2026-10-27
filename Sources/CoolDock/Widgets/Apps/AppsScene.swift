import AppKit
import SwiftUI

/// Reference-scene data for this family (see `ReferenceScene`). Returns nil for kinds it doesn't own.
enum AppsScene {
    @MainActor static func prepare(_ kind: WidgetKind, _ variant: String?) -> [String: String]? {
        switch kind {
        case .appFolder:
            return ["apps": ["/System/Library/CoreServices/Finder.app", "/System/Applications/Music.app",
                             "/System/Applications/Photos.app", "/System/Applications/Mail.app"].joined(separator: "\n")]
        case .appSwitcher, .downloads, .findFiles:
            return [:]
        case .folder:
            return folderScene(variant)
        case .app where variant == "badges":
            // Raw labels as apps set them; the tiles format them ("1234" → "1,234", "15000" → "15K").
            AppsDockBadges.shared.seedReference(Dictionary(uniqueKeysWithValues: zip(badgeApps, ["3", "99+", "1234", "15000"])))
            return ["path": badgeApps[0]]
        case .app where variant == "menu":
            return ["path": AppsSceneFiles.prepareMenus()]
        default:
            return nil
        }
    }

    /// Apps of the `app-badges` frame.
    static let badgeApps = ["/System/Applications/Mail.app", "/System/Applications/Messages.app",
                            "/System/Applications/Calendar.app", "/System/Applications/App Store.app"]

    /// Apps whose menus the `app-menu` frame shows (the first is the synthetic Chromium app, filled in by `prepare`).
    static let menuApps = ["", "/System/Library/CoreServices/Finder.app", "/System/Applications/TextEdit.app", "/System/Applications/Mail.app"]

    /// Folder window frames (`folder-panel`, `folder-panelNested`, `folder-panelSearch`, `folder-panelSorted`) over a
    /// synthetic folder, and `folder-colors` (the Folder Color palette on the folder icon).
    @MainActor private static func folderScene(_ variant: String?) -> [String: String]? {
        switch variant {
        case "panel": return ["path": AppsSceneFolder.prepare(), "sort": "name"]
        case "panelNested": return ["path": AppsSceneFolder.prepare(), "sort": "name", "scene.sub": "Projects/2026"]
        case "panelSearch":
            return ["path": AppsSceneFolder.prepare(), "sort": "modified", "scene.query": "report", "scene.filter": "documents"]
        case "panelSorted": return ["path": AppsSceneFolder.prepare(), "sort": "size", "scene.select": "1"]
        case "colors": return ["path": AppsSceneFolder.prepare()]
        default: return nil
        }
    }

    @MainActor private static var icons: [String: (image: NSImage, scale: CGFloat)] = [:]

    /// App icon as the reference frames show it, never the system-styled icon, so renders don't depend on this
    /// Mac's icon appearance or light/dark mode: the frame's own asset when there is one (full-bleed artwork,
    /// drawn at the icon grid's 81.5 % content size; Mail and Photos are the older artwork cut from the frame since
    /// macOS no longer ships it), else the bundle's flat .icns artwork. Finder's frame uses the classic artwork that
    /// CoreTypes still ships.
    @MainActor static func icon(_ path: String) -> (image: NSImage, scale: CGFloat)? {
        if let cached = icons[path] { return cached }
        let name = (path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "").lowercased()
        var found: (NSImage, CGFloat)?
        if let asset = ReferenceScene.asset("app-\(name)-72.webp") ?? ReferenceScene.asset("frame-app-\(name).png") {
            found = (asset, 0.815)
        } else if name == "finder", let classic = NSImage(contentsOfFile: "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/FinderIcon.icns") {
            found = (classic, 1)
        } else if let bundle = Bundle(path: path), let file = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String {
            let icns = file.hasSuffix(".icns") ? file : file + ".icns"
            found = bundle.url(forResource: icns, withExtension: nil).flatMap(NSImage.init(contentsOf:)).map { ($0, 1) }
        }
        if let found { icons[path] = found }
        return found
    }
}

// MARK: - Synthetic data for the app-menu frame (render harness only)

enum AppsSceneFiles {
    static var base: URL { URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("CoolDockScene", isDirectory: true) }

    /// A stand-in Chromium app (Chrome Canary's bundle id, so it's never the user's running browser), its
    /// `Local State` with three synthetic profiles, and Dock recent-document lists for Finder and TextEdit that point
    /// at the synthetic folder. Returns the stand-in app's path.
    @MainActor static func prepareMenus() -> String {
        let fm = FileManager.default
        let studio = URL(fileURLWithPath: AppsSceneFolder.prepare(), isDirectory: true)
        let app = base.appendingPathComponent("Apps/Google Chrome Canary.app", isDirectory: true)
        try? fm.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let info: NSDictionary = ["CFBundleIdentifier": "com.google.Chrome.canary", "CFBundleName": "Google Chrome Canary", "CFBundlePackageType": "APPL"]
        info.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true)

        let spec = AppsChromium.spec("com.google.Chrome.canary")!
        let state = spec.localState()
        try? fm.createDirectory(at: state.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = #"{"profile":{"info_cache":{"Default":{"name":"Personal"},"Profile 1":{"name":"Work"},"Profile 2":{"name":"Side Project"}},"profiles_order":["Default","Profile 2","Profile 1"]}}"#
        try? Data(json.utf8).write(to: state)

        let recents = AppsRecentDocs.folder
        try? fm.createDirectory(at: recents, withIntermediateDirectories: true)
        writeRecents(["Annual Report 2026.pdf", "Projects/2026/Roadmap.pdf", "Clients/Contract.docx"].map { studio.appendingPathComponent($0) },
                     to: recents.appendingPathComponent("com.apple.finder.sfl3"))
        writeRecents(["Meeting Notes.txt", "Projects/2026/Launch Plan.txt"].map { studio.appendingPathComponent($0) },
                     to: recents.appendingPathComponent("com.apple.textedit.sfl3"))
        return app.path
    }

    /// Same shape as the system's `.sfl3` (a keyed archive of `{ items: [{ Bookmark, uuid, visibility }] }`).
    private static func writeRecents(_ urls: [URL], to file: URL) {
        let items: [NSDictionary] = urls.compactMap { url in
            guard let bookmark = try? url.bookmarkData() else { return nil }
            return ["Bookmark": bookmark, "uuid": UUID().uuidString, "visibility": 0]
        }
        let root: NSDictionary = ["items": items, "properties": NSDictionary()]
        try? (try? NSKeyedArchiver.archivedData(withRootObject: root, requiringSecureCoding: false))?.write(to: file)
    }
}

/// Render-only picture of menus built by `AppsAppMenu.build` (the harness can't draw an NSMenu): items in menu
/// order, submenus expanded under their item, the ⌥ alternate marked. The live menu also lists the app's windows
/// (Accessibility) and ends with the widget's own items (Customize…, Widgets…, Remove).
struct AppsSceneMenu: View {
    @Environment(\.palette) private var p
    let title: String
    let menu: NSMenu

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: title).font(.dock(11, .semibold)).foregroundStyle(p.secondary).padding(.horizontal, 6)
            VStack(alignment: .leading, spacing: 0) { rows(menu.items, depth: 0) }
                .padding(5)
                .frame(width: 300, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(white: 0.16)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        }
    }

    private func rows(_ items: [NSMenuItem], depth: Int) -> AnyView {
        AnyView(ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            if item.isSeparatorItem {
                Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1).padding(.vertical, 4).padding(.horizontal, 8)
            } else {
                row(item, depth: depth)
                if let sub = item.submenu { rows(sub.items, depth: depth + 1) }
            }
        })
    }

    private func row(_ item: NSMenuItem, depth: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).opacity(item.state == .on ? 1 : 0).frame(width: 12)
            if let image = item.image { Image(nsImage: image).resizable().frame(width: 16, height: 16) }
            Text(verbatim: item.title).font(.system(size: 13)).lineLimit(1)
            Spacer(minLength: 8)
            if item.isAlternate { Text(verbatim: "⌥").font(.system(size: 12)).foregroundStyle(p.secondary) }
            if item.submenu != nil { Image(systemName: "chevron.forward").font(.system(size: 10, weight: .semibold)) }
        }
        .foregroundStyle(item.isEnabled || item.submenu != nil ? p.primary : p.tertiary)
        .padding(.leading, CGFloat(depth) * 18 + 6)
        .padding(.trailing, 8)
        .frame(height: 22)
        .background(depth > 0 ? Color.white.opacity(0.04) : .clear)
    }
}
