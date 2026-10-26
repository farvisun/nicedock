import AppKit
import SwiftUI

/// Apps & Files family: app icons, folders, Trash, Downloads, shelves, Spotlight and app switching.
enum AppsWidgets {
    @MainActor @ViewBuilder
    static func view(_ w: WidgetInstance) -> some View {
        switch w.kind {
        case .app: AppsAppTile(w: w)
        case .appFolder: AppsAppFolderTile(w: w)
        case .applications: AppsApplicationsTile(w: w)
        case .trash: AppsTrashTile()
        case .folder: AppsFolderTile(w: w)
        case .downloads: AppsDownloadsTile(w: w)
        case .recentFiles: AppsRecentTile(w: w)
        case .fileShelf: AppsShelfTile(w: w)
        case .airDrop: AppsAirDropTile(w: w)
        case .dropbox: AppsDropboxTile(w: w)
        case .findFiles: AppsFindTile(w: w)
        case .appSwitcher: AppsSwitcherTile(w: w)
        case .runningApps: AppsRunningAppsTile(w: w)
        default: Tile(width: w.kind.spec.width) { Text(w.kind.spec.localizedTitle).dock(11) }
        }
    }

    @MainActor @ViewBuilder
    static func menu(_ w: WidgetInstance) -> some View {
        switch w.kind {
        case .app:
            let path = AppsLaunch.resolve(w.string("path"))
            if !path.isEmpty, AppsFS.exists(path) {
                AppsAppActions(path: path, app: AppsLaunch.running(path))
                Divider()
            }
        case .appFolder:
            Button(L("Open All")) { w.list("apps").map(AppsLaunch.resolve).forEach(AppsLaunch.open) }
            Divider()
        case .applications:
            Button(L("Open Applications Folder")) { Open.path("/Applications") }
            Divider()
        case .trash:
            Button(L("Open")) { AppsTrash.shared.open() }
            Button(L("Empty Trash")) { AppsTrash.shared.empty() }
            Divider()
        case .folder:
            let path = AppsFS.expand(w.string("path", "~/Documents"))
            Button(L("Open in Finder")) { Open.path(path) }.disabled(!AppsFS.exists(path, directory: true))
            Divider()
        case .dropbox:
            if let path = AppsDropboxTile.resolve(w.string("path", "~/Library/CloudStorage/Dropbox")) {
                Button(L("Open in Finder")) { Open.path(path) }
                Divider()
            }
        case .downloads:
            Button(L("Open in Finder")) { Open.path(NSHomeDirectory() + "/Downloads") }
            Divider()
        case .fileShelf:
            Button(L("Clear Shelf")) { AppsShelfTile.remove(nil, from: w.id) }
                .disabled(AppsShelfTile.items(w.id, fallback: w).isEmpty)
            Divider()
        case .airDrop:
            Button(L("Open AirDrop")) {
                let app = "/System/Library/CoreServices/Finder.app/Contents/Applications/AirDrop.app"
                if FileManager.default.fileExists(atPath: app) { Open.app(app) } else { Open.bundle("com.apple.finder") }
            }
            Divider()
        case .runningApps:
            Button(AppStore.shared.settings.runningAppsCollapsed ? L("Show All Running Apps") : L("Collapse Running Apps")) {
                AppStore.shared.settings.runningAppsCollapsed.toggle()
            }
            Divider()
        default:
            EmptyView()
        }
    }
}
