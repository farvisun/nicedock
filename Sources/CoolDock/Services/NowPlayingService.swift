import AppKit
import Observation

/// Serialized AppleScript execution off the main thread.
enum Script {
    private static let queue = DispatchQueue(label: "app.nicedock.applescript", qos: .userInitiated)

    @discardableResult
    static func run(_ source: String) async -> NSAppleEventDescriptor? {
        if RenderHarness.isActive { return nil }
        return await withCheckedContinuation { cont in
            queue.async {
                var error: NSDictionary?
                let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
                if let error { NSLog("NiceDock AppleScript: \(error)") }
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

/// Now Playing for whatever app owns the system's Now Playing session (MediaRemote through `MediaRemoteBridge`),
/// falling back to Apple Music and Spotify via their distributed notifications and AppleScript. No polling while idle.
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
    /// The app playing, e.g. "Safari" or "Spotify" (empty until known).
    private(set) var appName = ""
    private(set) var appBundleID: String?
    @ObservationIgnored private var positionBase: Double = 0
    @ObservationIgnored private var positionStamp = Date()
    @ObservationIgnored private var artworkKey = ""
    @ObservationIgnored private var started = false
    @ObservationIgnored private var remote: MediaRemoteBridge?
    /// MediaRemote is answering: it is the source of truth and the AppleScript paths stay quiet.
    private var remoteActive: Bool { remote?.isReady == true }

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
        startRemote()
        Task { await refreshFromPlayers() }
    }

    private func startRemote() {
        guard !ReferenceScene.isActive, !MediaEnv.demo, MediaRemoteBridge.isAvailable else { return }
        let bridge = MediaRemoteBridge()
        bridge.onUpdate = { [weak self] in self?.apply($0) }
        bridge.onUnavailable = { [weak self] in
            self?.remote = nil
            Task { await self?.refreshFromPlayers() }
        }
        remote = bridge
        bridge.start()
    }

    /// One MediaRemote message (see `Helpers/MediaRemote/CoolDockMediaRemote.m`).
    func apply(_ u: MediaRemoteBridge.Update, now: Date = Date()) {
        guard u.type == "info", let t = u.title, !t.isEmpty else { clear(); return }
        player = nil
        title = t
        artist = u.artist ?? ""
        album = u.album ?? ""
        duration = max(0, u.duration ?? 0)
        isPlaying = u.playing ?? ((u.rate ?? 0) > 0)
        // `elapsed` was sampled at `timestamp`; carry it forward to now while playing.
        var elapsed = u.elapsed ?? 0
        if isPlaying, let stamp = u.timestamp { elapsed += max(0, now.timeIntervalSince1970 - stamp) * max(u.rate ?? 1, 0) }
        positionBase = duration > 0 ? min(elapsed, duration) : elapsed
        positionStamp = now
        let app = Self.app(bundle: u.parent ?? u.bundle, pid: u.pid)
        appBundleID = app.bundleID
        appName = app.name
        if let id = u.artworkID {
            if id != artworkKey {
                artworkKey = id
                artwork = u.artwork.flatMap { Data(base64Encoded: $0) }.flatMap { Self.downsample($0) }
            }
        } else {
            artworkKey = ""
            artwork = nil
        }
    }

    /// Resolves the playing app: the client's parent app (a browser for its web content process), else its pid.
    static func app(bundle: String?, pid: Int32?) -> (bundleID: String?, name: String) {
        if let bundle, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            return (bundle, FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
        }
        if let pid, pid > 0, let app = NSRunningApplication(processIdentifier: pid) {
            return (app.bundleIdentifier ?? bundle, app.localizedName ?? "")
        }
        return (bundle, "")
    }

    private func handle(_ p: Player, _ info: [AnyHashable: Any]) {
        guard !remoteActive else { return }
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
        appName = p.rawValue
        appBundleID = p == .music ? "com.apple.Music" : "com.spotify.client"
        if p == .music, let ms = info["Total Time"] as? Double { duration = ms / 1000 }
        if p == .spotify, let ms = info["Duration"] as? Double { duration = ms / 1000 }
        if let pos = info["Playback Position"] as? Double { positionBase = pos; positionStamp = Date() }
        Task { await refreshPosition(); await refreshArtwork() }
    }

    private func clear() {
        player = nil; title = ""; artist = ""; album = ""; isPlaying = false; artwork = nil; duration = 0; artworkKey = ""
        appName = ""; appBundleID = nil
    }

    func refreshFromPlayers() async {
        guard !remoteActive else { return }
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
            appName = p.rawValue
            appBundleID = bundle
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

    func playPause() {
        let pos = position()
        if remoteActive { remote?.send(isPlaying ? "pause" : "play") } else { command("playpause") }
        isPlaying.toggle(); positionBase = pos; positionStamp = Date()
    }
    func next() { if remoteActive { remote?.send("next") } else { command("next track") } }
    func previous() { if remoteActive { remote?.send("previous") } else { command("previous track") } }

    func openPlayer() {
        Open.bundle(appBundleID ?? (player == .spotify ? "com.spotify.client" : "com.apple.Music"))
    }

    private func command(_ cmd: String) {
        let p = player ?? .music
        Task { _ = await Script.run("tell application \"\(p.rawValue)\" to \(cmd)") }
    }
}
