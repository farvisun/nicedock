import AppKit
import SwiftUI

/// Snapshot of the current track (from `NowPlayingService`, or sample data in demo renders).
private struct MediaTrack {
    var title: String
    var artist: String
    var artwork: NSImage?
    var isPlaying: Bool
    var duration: Double
    var position: (Date) -> Double

    @MainActor static var current: MediaTrack? {
        if ReferenceScene.isActive {
            guard let t = MediaScene.track else { return nil }
            return MediaTrack(title: t.name, artist: t.artist, artwork: t.artwork, isPlaying: t.isPlaying, duration: t.duration,
                              position: { _ in t.position })
        }
        if MediaEnv.demo {
            return MediaTrack(title: "First Person Shooter (feat. J. Cole)", artist: "Drake", artwork: nil,
                              isPlaying: false, duration: 247, position: { _ in 3 })
        }
        let np = NowPlayingService.shared
        guard np.hasTrack else { return nil }
        return MediaTrack(title: np.title, artist: np.artist.isEmpty ? np.album : np.artist, artwork: np.artwork,
                          isPlaying: np.isPlaying, duration: np.duration, position: { np.position(at: $0) })
    }
}

// MARK: - Now Playing (241 pt)

struct MediaNowPlayingTile: View {
    let w: WidgetInstance
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p

    var body: some View {
        Tile(width: w.kind.spec.width, padding: EdgeInsets(top: 0, leading: 5.85, bottom: 0, trailing: 5.6)) {
            if let track = MediaTrack.current {
                HStack(spacing: 0) {
                    MediaArtwork(image: track.artwork, size: 49.2, radius: 6.5)
                        .onTapGesture { NowPlayingService.shared.openPlayer() }
                    VStack(alignment: .leading, spacing: 0) {
                        MediaMarquee(text: track.title, size: 11, weight: .bold,
                                     frozenScroll: ReferenceScene.isActive ? MediaScene.track?.titleScroll : nil)
                        Text(track.artist).dock(9.5, .medium, p.secondary)
                            .padding(.leading, m.u(-0.5))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, m.u(2.25))
                        progress(track)
                            .padding(.top, m.u(2.5))
                    }
                    .frame(width: m.u(85))
                    .offset(y: m.u(-0.625))
                    .padding(.leading, m.u(8.45))
                    Spacer(minLength: 0)
                    MediaTransport(isPlaying: track.isPlaying, small: 19.5, large: 29.5, spacing: 5.1, smallIcon: 7.8, largeIcon: 12.3)
                }
            } else {
                MediaNothingPlaying(artSize: 49)
            }
        }
        .onAppear { if !MediaEnv.isRender { NowPlayingService.shared.start() } }
    }

    @ViewBuilder private func progress(_ t: MediaTrack) -> some View {
        if t.isPlaying {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                MediaProgressBar(fraction: t.duration > 0 ? t.position(ctx.date) / t.duration : 0)
            }
        } else {
            MediaProgressBar(fraction: t.duration > 0 ? t.position(Date()) / t.duration : 0)
        }
    }
}

// MARK: - Now Playing hero (232 pt): art | title/artist | controls

struct MediaNowPlayingHeroTile: View {
    let w: WidgetInstance
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p

    var body: some View {
        Tile(width: w.kind.spec.width, padding: EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 7)) {
            if let track = MediaTrack.current {
                HStack(spacing: m.u(7.5)) {
                    MediaArtwork(image: track.artwork, size: 46.5, radius: 8)
                        .onTapGesture { NowPlayingService.shared.openPlayer() }
                    VStack(alignment: .leading, spacing: m.u(2)) {
                        MediaMarquee(text: track.title, size: 12, weight: .bold)
                        Text(track.artist).dock(9.5, .semibold, p.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity)
                    MediaTransport(isPlaying: track.isPlaying, small: 23, large: 31, spacing: 4)
                }
            } else {
                MediaNothingPlaying(artSize: 46.5)
            }
        }
        .onAppear { if !MediaEnv.isRender { NowPlayingService.shared.start() } }
    }
}

// MARK: - Pieces

private struct MediaNothingPlaying: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    var artSize: CGFloat

    var body: some View {
        HStack(spacing: m.u(8)) {
            MediaArtwork(image: nil, size: artSize, radius: 6.5)
            VStack(alignment: .leading, spacing: m.u(2)) {
                Text(L("Nothing playing")).dock(12.5, .bold)
                Text(L("Open Music")).dock(10.5, .semibold, p.secondary)
            }
            Spacer(minLength: 0)
            CircleButton(symbol: "play.fill", size: 30, iconScale: 0.41) { Open.bundle("com.apple.Music") }
                .help(L("Open Music"))
        }
        .contentShape(Rectangle())
        .onTapGesture { Open.bundle("com.apple.Music") }
    }
}

/// Album artwork (rounded square) with a music-note placeholder.
private struct MediaArtwork: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    var image: NSImage?
    var size: CGFloat
    var radius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: m.u(radius), style: .continuous)
        ZStack {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                shape.fill(p.controlStrong)
                Image(systemName: "music.note")
                    .font(.system(size: m.u(size * 0.4), weight: .semibold))
                    .foregroundStyle(p.secondary)
            }
        }
        .frame(width: m.u(size), height: m.u(size))
        .clipShape(shape)
        .contentShape(shape)
    }
}

/// ◀◀ ▶ ▶▶ circles. Media transport always reads left-to-right.
private struct MediaTransport: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    var isPlaying: Bool
    var small: CGFloat
    var large: CGFloat
    var spacing: CGFloat
    /// Glyph point sizes; default to a fixed share of the circle.
    var smallIcon: CGFloat? = nil
    var largeIcon: CGFloat? = nil

    var body: some View {
        let np = NowPlayingService.shared
        let icon = p.primary.opacity(0.9)
        HStack(spacing: m.u(spacing)) {
            CircleButton(symbol: "backward.fill", size: small, fill: p.control.opacity(0.7), foreground: icon, iconScale: smallIcon.map { $0 / small } ?? 0.39) { np.previous() }
                .help(L("Previous Track"))
            CircleButton(symbol: isPlaying ? "pause.fill" : "play.fill", size: large, fill: p.controlStrong.opacity(0.64), foreground: icon,
                         iconScale: largeIcon.map { $0 / large } ?? 0.41) { np.playPause() }
                .help(isPlaying ? L("Pause") : L("Play"))
            CircleButton(symbol: "forward.fill", size: small, fill: p.control.opacity(0.7), foreground: icon, iconScale: smallIcon.map { $0 / small } ?? 0.39) { np.next() }
                .help(L("Next Track"))
        }
        .environment(\.layoutDirection, .leftToRight)
    }
}

/// Thin capsule track with a white elapsed bar that starts as a dot.
private struct MediaProgressBar: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    var fraction: Double

    var body: some View {
        let h = m.u(4.5)
        GeometryReader { g in
            let f = CGFloat(max(0, min(1, fraction.isFinite ? fraction : 0)))
            ZStack(alignment: .leading) {
                Capsule().fill(p.track)
                Capsule().fill(p.primary.opacity(0.7)).frame(width: max(h, g.size.width * f))
            }
        }
        .frame(height: h)
        .environment(\.layoutDirection, .leftToRight)
    }
}

/// Single-line title clipped at the edge; scrolls to reveal the rest while hovered.
private struct MediaMarquee: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    var text: String
    var size: CGFloat
    var weight: Font.Weight
    /// Fixed scroll position (pt) for deterministic renders; nil = live hover marquee.
    var frozenScroll: CGFloat? = nil
    @State private var hovering = false
    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0

    @Environment(\.layoutDirection) private var uiDirection

    var body: some View {
        let overflow = max(0, textWidth - boxWidth)
        let scrolling = hovering && overflow > 1
        // Lay out in the title's own direction so an overflowing title always shows its beginning
        // (an English title inside a Persian UI starts at the left).
        let textDirection: LayoutDirection = Self.isRTL(text) ? .rightToLeft : .leftToRight
        let alignment: Alignment = overflow > 1 || frozenScroll != nil || textDirection == uiDirection ? .leading : .trailing
        Text(text)
            .font(.dock(m.u(size), weight))
            .foregroundStyle(p.primary)
            .lineLimit(1)
            .fixedSize()
            .background(GeometryReader { g in Color.clear.preference(key: MediaWidthKey.self, value: g.size.width) })
            .offset(x: frozenScroll.map { -m.u($0) } ?? (scrolling ? -overflow : 0))
            .animation(scrolling ? .linear(duration: Double(overflow / m.u(22))).delay(0.5).repeatForever(autoreverses: true)
                                 : .easeOut(duration: 0.2), value: scrolling)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: alignment)
            .background(GeometryReader { g in Color.clear.preference(key: MediaBoxWidthKey.self, value: g.size.width) })
            .clipped()
            .environment(\.layoutDirection, textDirection)
            .onPreferenceChange(MediaWidthKey.self) { textWidth = $0 }
            .onPreferenceChange(MediaBoxWidthKey.self) { boxWidth = $0 }
            .onHover { hovering = $0 }
    }

    /// Direction of the first strong character (Hebrew / Arabic script → right-to-left).
    static func isRTL(_ s: String) -> Bool {
        for u in s.unicodeScalars {
            switch u.value {
            case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF: return true
            default: if u.properties.isAlphabetic { return false }
            }
        }
        return false
    }
}

private struct MediaWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct MediaBoxWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
