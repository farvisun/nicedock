import AppKit
import SwiftUI

/// Favicons fetched once per host and kept on disk (`Caches/NiceDock/favicons`), small in memory.
@MainActor
final class UtilFavicons {
    static let shared = UtilFavicons()
    private let cache = NSCache<NSString, NSImage>()
    private var inflight: [String: Task<NSImage?, Never>] = [:]
    private let dir: URL = {
        let d = DiskCache.dir.appendingPathComponent("favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    func cached(_ host: String) -> NSImage? { cache.object(forKey: host as NSString) }

    func image(for host: String) async -> NSImage? {
        guard !host.isEmpty else { return nil }
        if let hit = cache.object(forKey: host as NSString) { return hit }
        if let running = inflight[host] { return await running.value }
        let file = dir.appendingPathComponent(host.replacingOccurrences(of: "/", with: "_") + ".png")
        let task = Task<NSImage?, Never> {
            let data: Data? = await Task.detached(priority: .utility) { try? Data(contentsOf: file) }.value
            if let data, let img = NSImage(data: data) { return img }
            guard let url = URL(string: "https://www.google.com/s2/favicons?domain=\(host)&sz=64"),
                  let fetched = try? await Net.data(url), let img = NSImage(data: fetched) else { return nil }
            try? fetched.write(to: file, options: .atomic)
            return img
        }
        inflight[host] = task
        let img = await task.value
        inflight[host] = nil
        if let img { cache.setObject(img, forKey: host as NSString) }
        return img
    }
}

struct UtilBookmarksView: View {
    let w: WidgetInstance
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p

    private var urls: [URL] {
        w.list("urls").compactMap { raw in
            let s = raw.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty else { return nil }
            return URL(string: s.contains("://") ? s : "https://" + s)
        }
    }

    var body: some View {
        let all = urls
        let overflow = all.count > 4
        let shown = Array(all.prefix(overflow ? 3 : 4))
        Tile(width: w.kind.spec.width) {
            if all.isEmpty {
                TileMessage(symbol: "bookmark", text: L("Add links"), tint: .cdBlue)
                    .onTapGesture { WidgetSetup.customize(w) }
            } else {
                HStack(spacing: m.u(6)) {
                    ForEach(shown, id: \.self) { UtilFaviconButton(url: $0, size: 28) }
                    if overflow {
                        Button { UtilBookmarksPanel.toggle(w, urls: all) } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: m.u(13), weight: .bold))
                                .foregroundStyle(p.secondary)
                                .frame(width: m.u(28), height: m.u(28))
                                .background(RoundedRectangle(cornerRadius: m.u(8), style: .continuous).fill(p.control))
                        }
                        .buttonStyle(PressableStyle())
                        .help(L("All bookmarks"))
                    }
                }
            }
        }
    }
}

private struct UtilFaviconButton: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    let url: URL
    var size: CGFloat
    @State private var image: NSImage?

    private var host: String { url.host?.replacingOccurrences(of: "www.", with: "") ?? url.absoluteString }

    var body: some View {
        Button { NSWorkspace.shared.open(url) } label: {
            ZStack {
                RoundedRectangle(cornerRadius: m.u(size * 0.28), style: .continuous).fill(p.control)
                if let image = image ?? UtilFavicons.shared.cached(url.host ?? "") {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: m.u(size * 0.64), height: m.u(size * 0.64))
                        .clipShape(RoundedRectangle(cornerRadius: m.u(3), style: .continuous))
                } else {
                    Text(verbatim: String(host.prefix(1)).uppercased())
                        .dock(size * 0.42, .bold, p.secondary)
                }
            }
            .frame(width: m.u(size), height: m.u(size))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .help(host)
        .task(id: url.host) { image = await UtilFavicons.shared.image(for: url.host ?? "") }
        .onDrag { NSItemProvider(object: url as NSURL) }
    }
}

@MainActor
enum UtilBookmarksPanel {
    static func toggle(_ w: WidgetInstance, urls: [URL]) {
        Panels.shared.toggle(w.id) { UtilBookmarksPanelView(urls: urls) }
    }
}

private struct UtilBookmarksPanelView: View {
    @Environment(\.palette) private var p
    let urls: [URL]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelHeader(title: L("Bookmarks"))
            ForEach(urls, id: \.self) { url in
                Button {
                    NSWorkspace.shared.open(url)
                    Panels.shared.close()
                } label: {
                    HStack(spacing: 10) {
                        UtilFaviconButton(url: url, size: 24).allowsHitTesting(false)
                        Text(verbatim: url.host?.replacingOccurrences(of: "www.", with: "") ?? url.absoluteString)
                            .font(.dock(12.5, .medium)).foregroundStyle(p.primary).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 240)
    }
}
