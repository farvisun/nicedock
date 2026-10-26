import AppKit
import Observation
import Photos
import SwiftUI

// MARK: - YouTube video (120 pt)

enum MediaYouTube {
    /// Extracts the 11-character id from watch?v=, youtu.be/, shorts/, embed/ and live/ URLs (or a bare id).
    static func videoID(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let valid: (String) -> Bool = { id in
            id.count == 11 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        }
        if valid(s) { return s }
        guard let comps = URLComponents(string: s.contains("://") ? s : "https://" + s), let host = comps.host?.lowercased() else { return nil }
        if host.hasSuffix("youtube.com") || host.hasSuffix("youtube-nocookie.com") {
            if let v = comps.queryItems?.first(where: { $0.name == "v" })?.value, valid(v) { return v }
            let parts = comps.path.split(separator: "/").map(String.init)
            if let i = parts.firstIndex(where: { ["shorts", "embed", "live", "v"].contains($0) }), i + 1 < parts.count, valid(parts[i + 1]) {
                return parts[i + 1]
            }
        }
        if host.hasSuffix("youtu.be"), let first = comps.path.split(separator: "/").first.map(String.init), valid(first) { return first }
        return nil
    }

    private nonisolated(unsafe) static let memory = NSCache<NSString, NSImage>()

    static func cached(_ id: String) -> NSImage? { memory.object(forKey: id as NSString) }

    /// Thumbnail decoded to ≤240 px; the small JPEG is kept on disk so relaunches are instant.
    @MainActor static func thumbnail(_ id: String) async -> NSImage? {
        if let hit = memory.object(forKey: id as NSString) { return hit }
        let file = DiskCache.dir.appendingPathComponent("yt-\(id).jpg")
        let cg: CGImage? = await Task.detached(priority: .utility) {
            if let data = try? Data(contentsOf: file) { return MediaImageIO.thumbnail(data: data, maxPixel: 240) }
            guard let url = URL(string: "https://img.youtube.com/vi/\(id)/mqdefault.jpg"),
                  let data = try? await Net.data(url) else { return nil }
            try? data.write(to: file, options: .atomic)
            return MediaImageIO.thumbnail(data: data, maxPixel: 240)
        }.value
        guard let cg else { return nil }
        let img = MediaImageIO.image(cg)
        memory.setObject(img, forKey: id as NSString)
        return img
    }
}

struct MediaYouTubeTile: View {
    let w: WidgetInstance
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    @State private var image: NSImage?

    var body: some View {
        let url = w.string("url")
        let id = MediaYouTube.videoID(url)
        Tile(width: w.kind.spec.width, padding: id == nil ? nil : .all(4)) {
            if let id {
                let shape = RoundedRectangle(cornerRadius: max(m.tileRadius - m.u(4), m.u(4)), style: .continuous)
                ZStack {
                    if let thumb = image ?? MediaYouTube.cached(id) {
                        Image(nsImage: thumb).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                    } else {
                        shape.fill(p.control)
                    }
                    MediaYouTubeBadge()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(shape)
                .contentShape(shape)
                .onTapGesture { Open.url(url) }
                .task(id: id) {
                    image = MediaYouTube.cached(id)
                    // Retry every 5 min while visible if the thumbnail could not be fetched (offline).
                    while !Task.isCancelled {
                        if let img = await MediaYouTube.thumbnail(id) { image = img; break }
                        try? await Task.sleep(for: .seconds(300))
                    }
                }
            } else {
                MediaCompactMessage(symbol: "play.rectangle", text: L("Add a video URL"), tint: .cdRed)
                    .contentShape(Rectangle())
                    .onTapGesture { WidgetSetup.customize(w) }
            }
        }
    }
}

/// Red rounded play badge (brand surface).
private struct MediaYouTubeBadge: View {
    @Environment(\.metrics) private var m
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: m.u(5.5), style: .continuous).fill(Color(hex: "#FF0033"))
            Image(systemName: "play.fill").font(.system(size: m.u(9), weight: .bold)).foregroundStyle(.white)
        }
        .frame(width: m.u(27), height: m.u(19))
        .shadow(color: .black.opacity(0.35), radius: m.u(3), y: m.u(1))
    }
}

// MARK: - Recent photo (62 pt)

@Observable
@MainActor
final class MediaPhotoModel {
    static let shared = MediaPhotoModel()

    private(set) var status: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    private(set) var image: NSImage?
    private(set) var empty = false
    @ObservationIgnored private var assetID: String?
    @ObservationIgnored private var users = 0
    @ObservationIgnored private var observer: MediaPhotoObserver?

    var authorized: Bool { status == .authorized || status == .limited }

    func attach() {
        users += 1
        activate()
    }

    private func activate() {
        status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard authorized, users > 0 else { return }
        if observer == nil {
            let o = MediaPhotoObserver()
            PHPhotoLibrary.shared().register(o)
            observer = o
        }
        load()
    }

    func detach() {
        users = max(0, users - 1)
        guard users == 0, let o = observer else { return }
        PHPhotoLibrary.shared().unregisterChangeObserver(o)
        observer = nil
    }

    /// Only ever called from a click — never on appear.
    func requestAccess() {
        if status == .notDetermined {
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in
                Task { @MainActor in MediaPhotoModel.shared.activate() }
            }
        } else {
            MediaEnv.openPrivacyPane("Privacy_Photos")
        }
    }

    func load() {
        guard authorized else { return }
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        opts.fetchLimit = 1
        guard let asset = PHAsset.fetchAssets(with: .image, options: opts).firstObject else {
            image = nil; assetID = nil; empty = true
            return
        }
        empty = false
        guard asset.localIdentifier != assetID || image == nil else { return }
        assetID = asset.localIdentifier
        let ro = PHImageRequestOptions()
        ro.deliveryMode = .opportunistic
        ro.resizeMode = .fast
        ro.isNetworkAccessAllowed = true
        let id = asset.localIdentifier
        PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 140, height: 140), contentMode: .aspectFill, options: ro) { img, _ in
            guard let img else { return }
            Task { @MainActor in
                let model = MediaPhotoModel.shared
                if model.assetID == id { model.image = img }
            }
        }
    }
}

private final class MediaPhotoObserver: NSObject, PHPhotoLibraryChangeObserver {
    func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in MediaPhotoModel.shared.load() }
    }
}

struct MediaRecentPhotoTile: View {
    let w: WidgetInstance
    @Environment(\.metrics) private var m

    var body: some View {
        let model = MediaPhotoModel.shared
        Tile(width: w.kind.spec.width) {
            if !model.authorized {
                MediaCompactMessage(symbol: model.status == .notDetermined ? "photo" : "lock.fill",
                                    text: model.status == .notDetermined ? L("Allow Photos") : L("Photos access off"), tint: .cdYellow)
                    .contentShape(Rectangle())
                    .onTapGesture { model.requestAccess() }
            } else if let image = model.image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                    .frame(width: m.u(w.kind.spec.width), height: m.tileHeight)
                    .clipped()
                    .contentShape(Rectangle())
                    .onTapGesture { Open.bundle("com.apple.Photos") }
            } else {
                MediaCompactMessage(symbol: "photo.on.rectangle", text: model.empty ? L("No photos") : L("Photos"), tint: .cdYellow)
                    .contentShape(Rectangle())
                    .onTapGesture { Open.bundle("com.apple.Photos") }
            }
        }
        .onAppear { model.attach() }
        .onDisappear { model.detach() }
    }
}

// MARK: - Wallpaper (100 pt)

@Observable
@MainActor
final class MediaWallpaperModel {
    static let shared = MediaWallpaperModel()

    private(set) var image: NSImage?
    private(set) var busy = false
    @ObservationIgnored private var currentURL: URL?
    @ObservationIgnored private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var users = 0

    nonisolated static let imageTypes: Set<String> = ["heic", "heif", "jpg", "jpeg", "png", "tif", "tiff", "webp", "bmp"]

    func attach() {
        users += 1
        if tokens.isEmpty {
            let ws = NSWorkspace.shared.notificationCenter
            let reload: @Sendable (Notification) -> Void = { _ in Task { @MainActor in await MediaWallpaperModel.shared.refresh() } }
            tokens.append((ws, ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main, using: reload)))
            let nc = NotificationCenter.default
            tokens.append((nc, nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main, using: reload)))
            let dnc = DistributedNotificationCenter.default()
            tokens.append((dnc, dnc.addObserver(forName: NSNotification.Name("com.apple.desktop"), object: nil, queue: .main, using: reload)))
        }
        Task { await refresh() }
    }

    func detach() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        tokens.forEach { $0.0.removeObserver($0.1) }
        tokens.removeAll()
    }

    func refresh(force: Bool = false) async {
        guard let screen = NSScreen.main ?? NSScreen.screens.first,
              let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return }
        if !force, url == currentURL, image != nil { return }
        currentURL = url
        let cg = await Task.detached(priority: .utility) { Self.thumbnail(for: url) }.value
        image = cg.map(MediaImageIO.image)
    }

    /// Desktop pictures can be folders, `.madesktop` stubs (with a thumbnail path) or real images.
    nonisolated static func thumbnail(for url: URL) -> CGImage? {
        var target = url
        if url.pathExtension.lowercased() == "madesktop",
           let dict = NSDictionary(contentsOf: url), let thumb = dict["thumbnailPath"] as? String {
            target = URL(fileURLWithPath: thumb)
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir), !isDir.boolValue else { return nil }
        return MediaImageIO.thumbnail(url: target, maxPixel: 220)
    }

    nonisolated static func images(in dir: URL) -> [URL] {
        guard let items = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey],
                                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [URL] = []
        for case let u as URL in items where imageTypes.contains(u.pathExtension.lowercased()) {
            out.append(u)
            if out.count >= 2000 { break }
        }
        return out
    }

    /// Picks a random image from `folder` (excluding the current one) and applies it to every screen.
    func next(folder: String) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let dir = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath)
        let current = currentURL?.standardizedFileURL
        let files: [URL] = await Task.detached(priority: .userInitiated) { Self.images(in: dir) }.value
        let pool = files.filter { $0.standardizedFileURL != current }
        guard let pick = (pool.isEmpty ? files : pool).randomElement() else {
            NSSound.beep()
            return
        }
        for screen in NSScreen.screens {
            let opts = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
            do { try NSWorkspace.shared.setDesktopImageURL(pick, for: screen, options: opts) } catch { NSLog("CoolDock wallpaper: \(error)") }
        }
        await refresh(force: true)
    }
}

struct MediaWallpaperTile: View {
    let w: WidgetInstance
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    @State private var hovering = false

    var body: some View {
        let model = MediaWallpaperModel.shared
        Tile(width: w.kind.spec.width, padding: .all(4)) {
            let shape = RoundedRectangle(cornerRadius: max(m.tileRadius - m.u(4), m.u(4)), style: .continuous)
            ZStack {
                if let image = model.image {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                } else {
                    shape.fill(p.control)
                    Image(systemName: "photo.on.rectangle").font(.system(size: m.u(16), weight: .semibold)).foregroundStyle(p.secondary)
                }
                if hovering || model.busy {
                    Color.black.opacity(0.28)
                    Image(systemName: "shuffle")
                        .font(.system(size: m.u(14), weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.4), radius: m.u(2))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(shape)
            .contentShape(shape)
            .animation(.easeOut(duration: 0.15), value: hovering)
        }
        .onHover { hovering = $0 }
        .onTapGesture { Task { await model.next(folder: w.string("path")) } }
        .help(L("Next Wallpaper"))
        .onAppear { model.attach() }
        .onDisappear { model.detach() }
        .onWidgetRefresh(w.id) { Task { await model.refresh(force: true) } }
    }
}
