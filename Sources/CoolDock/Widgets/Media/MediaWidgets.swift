import AppKit
import ImageIO
import SwiftUI

/// Media, photos, mail, notes and phone widgets.
enum MediaWidgets {
    @MainActor @ViewBuilder
    static func view(_ w: WidgetInstance) -> some View {
        switch w.kind {
        case .nowPlaying: MediaNowPlayingTile(w: w)
        case .nowPlayingHero: MediaNowPlayingHeroTile(w: w)
        case .backgroundSounds: MediaSoundsTile(w: w)
        case .youtubeVideo: MediaYouTubeTile(w: w)
        case .recentPhoto: MediaRecentPhotoTile(w: w)
        case .wallpaper: MediaWallpaperTile(w: w)
        case .mail: MediaMailTile(w: w)
        case .mailLatest: MediaMailLatestTile(w: w)
        case .notes: MediaNotesTile(w: w)
        case .quickContacts: MediaContactsTile(w: w)
        case .contactCard: MediaContactCardTile(w: w)
        default: Tile(width: w.kind.spec.width) { Text(w.kind.spec.localizedTitle).dock(11) }
        }
    }

    @MainActor @ViewBuilder
    static func menu(_ w: WidgetInstance) -> some View {
        switch w.kind {
        case .nowPlaying, .nowPlayingHero:
            let np = NowPlayingService.shared
            if np.hasTrack {
                Button(np.isPlaying ? L("Pause") : L("Play")) { np.playPause() }
                Button(L("Next Track")) { np.next() }
                Button(L("Previous Track")) { np.previous() }
            }
            if !np.appName.isEmpty {
                Button(L("Open %@", np.appName)) { np.openPlayer() }
            } else if !np.hasTrack || np.player != nil {
                // A command-line player has no app to open.
                Button(np.player == .spotify ? L("Open Spotify") : L("Open Music")) { np.openPlayer() }
            }
            Divider()
        case .backgroundSounds:
            let engine = MediaSoundEngine.shared
            let current = MediaNoise(rawValue: w.string("sound")) ?? .rain
            Button(engine.isPlaying ? L("Stop") : L("Play")) { MediaSoundsTile.toggle(w) }
            Menu(L("Sound")) {
                ForEach(MediaNoise.allCases) { s in
                    Button { MediaSoundsTile.select(s, for: w) } label: {
                        if s == current { Label(s.title, systemImage: "checkmark") } else { Text(s.title) }
                    }
                }
            }
            Button(L("Sound & Volume…")) { MediaSoundsTile.openPanel(w) }
            Divider()
        case .youtubeVideo:
            Button(L("Open Video")) { Open.url(w.string("url")) }
            Button(L("Copy Link")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(w.string("url"), forType: .string)
            }
            Divider()
        case .recentPhoto:
            Button(L("Open Photos")) { Open.bundle("com.apple.Photos") }
            Divider()
        case .wallpaper:
            Button(L("Next Wallpaper")) { Task { await MediaWallpaperModel.shared.next(folder: w.string("path")) } }
            Button(L("Open Folder")) { Open.path(w.string("path")) }
            Divider()
        case .mail, .mailLatest:
            Button(L("Open Mail")) { Open.bundle(MediaMailService.bundleID) }
            Button(L("New Message")) { Open.url("mailto:") }
            Divider()
        case .notes:
            Button(L("Open Notes")) { Open.bundle(MediaNotesService.bundleID) }
            Button(L("New Note")) { MediaNotesService.shared.newNote() }
            Divider()
        case .quickContacts:
            Button(L("Open Contacts")) { Open.bundle("com.apple.AddressBook") }
            Divider()
        case .contactCard:
            MediaContactCardTile.menu(w)
        default:
            EmptyView()
        }
    }
}

// MARK: - Shared helpers (Media family)

enum MediaEnv {
    /// `--render` harness runs must never trigger permission prompts or AppleScript.
    static let isRender = CommandLine.arguments.contains("--render")
    /// `COOLDOCK_DEMO=1` fills private-data widgets with sample content (reference comparisons).
    static let demo = ProcessInfo.processInfo.environment["COOLDOCK_DEMO"] == "1"

    static func openPrivacyPane(_ anchor: String) {
        Open.url("x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }
}

/// Thread-safe image decoding straight to small thumbnails (never holds full-size bitmaps).
enum MediaImageIO {
    static func thumbnail(url: URL, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return thumbnail(src, maxPixel: maxPixel)
    }

    static func thumbnail(data: Data, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return thumbnail(src, maxPixel: maxPixel)
    }

    private static func thumbnail(_ src: CGImageSource, maxPixel: Int) -> CGImage? {
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    static func image(_ cg: CGImage) -> NSImage {
        NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2))
    }
}

/// Compact message for narrow tiles (62–100 pt) where `TileMessage` would not fit.
struct MediaCompactMessage: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    var symbol: String
    var text: String
    var tint: Color = .cdOrange

    var body: some View {
        VStack(spacing: m.u(4)) {
            Image(systemName: symbol)
                .font(.system(size: m.u(15), weight: .semibold))
                .foregroundStyle(p.accent(tint))
            Text(text)
                .font(.dock(m.u(8.5), .semibold))
                .foregroundStyle(p.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, m.u(4))
    }
}

/// Round compose button used by the mail and notes tiles.
struct MediaComposeButton: View {
    @Environment(\.palette) private var p
    var action: () -> Void

    var body: some View {
        CircleButton(symbol: "square.and.pencil", size: 38, fill: p.controlStrong.opacity(0.9), iconScale: 0.4, action: action)
            .help(L("New"))
    }
}
