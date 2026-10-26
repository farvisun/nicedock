import AppKit
import Observation

/// Serialized AppleScript execution off the main thread.
enum Script {
    private static let queue = DispatchQueue(label: "app.cooldock.applescript", qos: .userInitiated)

    @discardableResult
    static func run(_ source: String) async -> NSAppleEventDescriptor? {
        await withCheckedContinuation { cont in
            queue.async {
                var error: NSDictionary?
                let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
                if let error { NSLog("CoolDock AppleScript: \(error)") }
                cont.resume(returning: error == nil ? result : nil)
            }
        }
    }

    static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// Now Playing for Apple Music and Spotify, driven by their distributed notifications (no polling while idle).
@Observable
@MainActor
final class NowPlayingService {
    static let shared = NowPlayingService()

    enum Player: String { case music = "Music", spotify = "Spotify" }

    private(set) var player: Player?
    private(set) var title = ""
    private(set) var artist = ""
    private(set) var album = ""
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    private(set) var artwork: NSImage?
    @ObservationIgnored private var positionBase: Double = 0
    @ObservationIgnored private var positionStamp = Date()
    @ObservationIgnored private var artworkKey = ""
    @ObservationIgnored private var started = false

    var hasTrack: Bool { !title.isEmpty }

    func position(at date: Date = Date()) -> Double {
        let p = positionBase + (isPlaying ? date.timeIntervalSince(positionStamp) : 0)
        return duration > 0 ? min(p, duration) : p
    }

    func start() {
        guard !started else { return }
        started = true
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: NSNotification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main) { note in
            let info = note.userInfo ?? [:]
            MainActor.assumeIsolated { NowPlayingService.shared.handle(.music, info) }
        }
        dnc.addObserver(forName: NSNotification.Name("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main) { note in
            let info = note.userInfo ?? [:]
            MainActor.assumeIsolated { NowPlayingService.shared.handle(.spotify, info) }
        }
        Task { await refreshFromPlayers() }
    }

    private func handle(_ p: Player, _ info: [AnyHashable: Any]) {
        let state = info["Player State"] as? String ?? ""
        if state == "Stopped" {
            if player == p { clear() }
            return
        }
        player = p
        title = info["Name"] as? String ?? title
        artist = info["Artist"] as? String ?? ""
        album = info["Album"] as? String ?? ""
        isPlaying = state == "Playing"
        if p == .music, let ms = info["Total Time"] as? Double { duration = ms / 1000 }
        if p == .spotify, let ms = info["Duration"] as? Double { duration = ms / 1000 }
        if let pos = info["Playback Position"] as? Double { positionBase = pos; positionStamp = Date() }
        Task { await refreshPosition(); await refreshArtwork() }
    }

    private func clear() {
        player = nil; title = ""; artist = ""; album = ""; isPlaying = false; artwork = nil; duration = 0; artworkKey = ""
    }

    func refreshFromPlayers() async {
        for p in [Player.spotify, .music] {
            let bundle = p == .music ? "com.apple.Music" : "com.spotify.client"
            guard Script.isRunning(bundle) else { continue }
            let src = """
            tell application "\(p.rawValue)"
                if player state is stopped then return {"stopped"}
                set t to current track
                return {player state as string, name of t, artist of t, album of t, duration of t, player position}
            end tell
            """
            guard let d = await Script.run(src), d.numberOfItems >= 6 else { continue }
            let state = d.atIndex(1)?.stringValue ?? ""
            player = p
            title = d.atIndex(2)?.stringValue ?? ""
            artist = d.atIndex(3)?.stringValue ?? ""
            album = d.atIndex(4)?.stringValue ?? ""
            let dur = d.atIndex(5)?.doubleValue ?? 0
            duration = p == .spotify ? dur / 1000 : dur
            positionBase = d.atIndex(6)?.doubleValue ?? 0
            positionStamp = Date()
            isPlaying = state == "playing"
            await refreshArtwork()
            return
        }
    }

    private func refreshPosition() async {
        guard let p = player else { return }
        let bundle = p == .music ? "com.apple.Music" : "com.spotify.client"
        guard Script.isRunning(bundle), let d = await Script.run("tell application \"\(p.rawValue)\" to return player position") else { return }
        positionBase = d.doubleValue
        positionStamp = Date()
    }

    private func refreshArtwork() async {
        guard let p = player else { return }
        let key = "\(p.rawValue)|\(title)|\(album)"
        guard key != artworkKey else { return }
        artworkKey = key
        switch p {
        case .spotify:
            guard let d = await Script.run("tell application \"Spotify\" to return artwork url of current track"),
                  let s = d.stringValue, let url = URL(string: s),
                  let data = try? await Net.data(url) else { artwork = nil; return }
            artwork = Self.downsample(data)
        case .music:
            guard let d = await Script.run("tell application \"Music\" to tell artwork 1 of current track to return raw data") else { artwork = nil; return }
            artwork = Self.downsample(d.data)
        }
    }

    /// Keep artwork tiny in memory: decode straight to a 160 px thumbnail.
    static func downsample(_ data: Data, maxPixel: Int = 160) -> NSImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return NSImage(data: data) }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
    }

    // MARK: Controls

    func playPause() { command("playpause"); isPlaying.toggle(); positionBase = position(); positionStamp = Date() }
    func next() { command("next track") }
    func previous() { command("previous track") }

    func openPlayer() {
        Open.bundle(player == .spotify ? "com.spotify.client" : "com.apple.Music")
    }

    private func command(_ cmd: String) {
        let p = player ?? .music
        Task { await Script.run("tell application \"\(p.rawValue)\" to \(cmd)") }
    }
}
