import AppKit
import Observation
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// Captures with `/usr/sbin/screencapture` and lists recent screenshots.
@Observable
@MainActor
final class UtilScreenshotService {
    static let shared = UtilScreenshotService()

    enum Mode { case window, selection, screen }

    struct Shot: Identifiable, Hashable, Sendable {
        var id: String { url.path }
        let url: URL
        let date: Date
    }

    private(set) var recent: [Shot] = []
    private(set) var scanning = false
    /// Bumps after every capture so open panels rescan.
    private(set) var revision = 0

    /// User setting, else the system screenshot location, else the Desktop.
    static var folder: URL {
        if let custom = AppStore.shared.settings.screenshotFolder, !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        if let loc = CFPreferencesCopyAppValue("location" as CFString, "com.apple.screencapture" as CFString) as? String, !loc.isEmpty {
            return URL(fileURLWithPath: (loc as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    private static let nameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f
    }()

    func capture(_ mode: Mode, toClipboard: Bool) {
        Panels.shared.close()
        var args: [String]
        switch mode {
        case .window: args = ["-iW"]
        case .selection: args = ["-i"]
        case .screen: args = []
        }
        if toClipboard {
            args.append("-c")
        } else {
            let dir = Self.folder
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let name = "Screenshot " + Self.nameFormatter.string(from: Date()) + ".png"
            args.append(dir.appendingPathComponent(name).path)
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        proc.arguments = args
        proc.terminationHandler = { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { UtilScreenshotService.shared.revision &+= 1 } }
        }
        do { try proc.run() } catch { NSSound.beep() }
    }

    /// Scans the screenshot folder, Desktop and ~/Pictures/Screenshots (only when the panel opens).
    func rescan() async {
        guard !UtilEnv.rendering else { return }
        scanning = true
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dirs = [Self.folder, home.appendingPathComponent("Desktop"), home.appendingPathComponent("Pictures/Screenshots")]
        let shots = await Task.detached(priority: .utility) { () -> [Shot] in
            let fm = FileManager.default
            let exts: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "gif"]
            var seen = Set<String>()
            var out: [Shot] = []
            for dir in dirs where seen.insert(dir.standardizedFileURL.path).inserted {
                guard let urls = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles]) else { continue }
                for url in urls where exts.contains(url.pathExtension.lowercased()) {
                    let name = url.lastPathComponent
                    guard name.hasPrefix("Screenshot") || name.hasPrefix("Screen Shot") || name.hasPrefix("CleanShot") else { continue }
                    let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                    out.append(Shot(url: url, date: date))
                }
            }
            return Array(out.sorted { $0.date > $1.date }.prefix(12))
        }.value
        recent = shots
        scanning = false
    }

    func trash(_ shot: Shot) {
        NSWorkspace.shared.recycle([shot.url]) { _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { UtilScreenshotService.shared.recent.removeAll { $0 == shot } }
            }
        }
    }
}

/// Small QuickLook thumbnails, cached by path + modification date.
enum UtilThumbnails {
    nonisolated(unsafe) private static let cache = NSCache<NSString, NSImage>()

    static func cached(_ url: URL) -> NSImage? { cache.object(forKey: url.path as NSString) }

    static func load(_ url: URL, size: CGSize) async -> NSImage? {
        if let hit = cached(url) { return hit }
        let req = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: 2, representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) else { return nil }
        let img = rep.nsImage
        cache.setObject(img, forKey: url.path as NSString)
        return img
    }
}

// MARK: - Capture buttons

struct UtilScreenshotsView: View {
    let w: WidgetInstance
    @Environment(\.metrics) private var m

    /// Violet of the reference "full screen" button (between system purple and indigo); still routed through `p.accent`.
    static let violet = Color(red: 148 / 255, green: 107 / 255, blue: 250 / 255)

    var body: some View {
        Tile(width: w.kind.spec.width) {
            HStack(spacing: m.u(8)) {
                UtilShotButton(symbol: "macwindow.on.rectangle", tint: .cdBlue, help: L("Capture Window")) { clip in
                    UtilScreenshotService.shared.capture(.window, toClipboard: clip)
                }
                UtilShotButton(symbol: "selection.pin.in.out", tint: .cdGreen, help: L("Capture Selection")) { clip in
                    UtilScreenshotService.shared.capture(.selection, toClipboard: clip)
                }
                UtilShotButton(symbol: "rectangle.inset.filled", tint: UtilScreenshotsView.violet, help: L("Capture Screen")) { clip in
                    UtilScreenshotService.shared.capture(.screen, toClipboard: clip)
                }
            }
        }
    }
}

private struct UtilShotButton: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    var symbol: String
    var tint: Color
    var help: String
    var action: (_ toClipboard: Bool) -> Void

    /// Point size, weight and sub-pixel vertical nudge per symbol, matched to the reference frame
    /// (the crop glyph is drawn larger and lighter there).
    private var glyph: (size: CGFloat, weight: Font.Weight, nudge: CGFloat) {
        symbol == "selection.pin.in.out" ? (14.5, .medium, 0.25) : (14, .semibold, 0)
    }

    var body: some View {
        let accent = p.accent(tint)
        Button { action(NSEvent.modifierFlags.contains(.option)) } label: {
            Image(systemName: symbol)
                .font(.system(size: m.u(glyph.size), weight: glyph.weight))
                .foregroundStyle(accent)
                .transformEffect(CGAffineTransform(translationX: 0, y: m.u(glyph.nudge)))
                .frame(width: m.u(40), height: m.u(40))
                .background(Circle().fill(accent.opacity(0.11)))
                .overlay(Circle().strokeBorder(accent.opacity(0.14), lineWidth: m.u(0.75)))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .help(help + " — " + L("⌥-click to copy to the clipboard"))
    }
}

// MARK: - Recent screenshots

struct UtilRecentScreenshotsTile: View {
    let w: WidgetInstance
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p

    var body: some View {
        Tile(width: w.kind.spec.width) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: m.u(20), weight: .semibold))
                .foregroundStyle(p.secondary)
                // The reference glyph sits off the pixel grid (half a device pixel low).
                .transformEffect(CGAffineTransform(translationX: m.u(-0.5), y: m.u(0.25)))
        }
        .onTapGesture { UtilRecentScreenshotsPanel.toggle(w) }
    }
}

@MainActor
enum UtilRecentScreenshotsPanel {
    static func toggle(_ w: WidgetInstance) {
        Panels.shared.toggle(w.id) { UtilRecentScreenshotsPanelView() }
    }
}

private struct UtilRecentScreenshotsPanelView: View {
    @Environment(\.palette) private var p
    private var service: UtilScreenshotService { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(title: L("Recent Screenshots"), subtitle: UtilScreenshotService.folder.lastPathComponent) {
                HStack(spacing: 10) {
                    Button { UtilScreenshotService.shared.capture(.selection, toClipboard: false) } label: {
                        Image(systemName: "camera.viewfinder").font(.system(size: 13, weight: .semibold))
                    }
                    .help(L("Capture Selection"))
                    Button { Open.path(UtilScreenshotService.folder.path) } label: {
                        Image(systemName: "folder").font(.system(size: 13, weight: .semibold))
                    }
                    .help(L("Open Screenshots Folder"))
                }
                .buttonStyle(.plain)
                .foregroundStyle(p.secondary)
            }
            if service.recent.isEmpty {
                Text(service.scanning ? L("Looking for screenshots…") : L("No screenshots yet."))
                    .font(.dock(12, .medium)).foregroundStyle(p.tertiary)
                    .frame(width: 318, height: 80)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(100), spacing: 9), count: 3), spacing: 9) {
                    ForEach(service.recent) { UtilShotCell(shot: $0) }
                }
                .frame(width: 318)
            }
        }
        .task(id: service.revision) { await service.rescan() }
    }
}

private struct UtilShotCell: View {
    @Environment(\.palette) private var p
    let shot: UtilScreenshotService.Shot
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(p.control)
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .padding(3)
                } else {
                    Image(systemName: "photo").foregroundStyle(p.tertiary)
                }
            }
            .frame(width: 100, height: 66)
            Text(verbatim: UtilRelative.string(shot.date)).font(.dock(9.5, .medium)).foregroundStyle(p.secondary).lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            NSWorkspace.shared.open(shot.url)
            Panels.shared.close()
        }
        .onDrag { NSItemProvider(contentsOf: shot.url) ?? NSItemProvider() }
        .help(shot.url.lastPathComponent)
        .contextMenu {
            Button(L("Open")) { NSWorkspace.shared.open(shot.url) }
            Button(L("Show in Finder")) { Open.reveal(shot.url.path) }
            Button(L("Copy")) {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.writeObjects([shot.url as NSURL])
                if let img = NSImage(contentsOf: shot.url) { pb.writeObjects([img]) }
            }
            Divider()
            Button(L("Move to Trash"), role: .destructive) { UtilScreenshotService.shared.trash(shot) }
        }
        .task(id: shot.url) { image = await UtilThumbnails.load(shot.url, size: CGSize(width: 100, height: 66)) }
    }
}
