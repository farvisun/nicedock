import AppKit
import Foundation
import MediaPlayer
import Testing
@testable import CoolDock

/// System-wide Now Playing. `mediaremote/probe-stream.jsonl` is the helper's real output (bundled helper, macOS 27.0.1)
/// while a probe process published a track through MPNowPlayingInfoCenter: ready, the track, the same track once its
/// artwork arrived, after a `pause` command, and after the probe quit.
@MainActor
@Suite struct MediaRemoteStreamTests {
    func updates() throws -> [MediaRemoteBridge.Update] {
        var buffer = MediaRemoteBridge.LineBuffer()
        let data = try Fixture.data("mediaremote/probe-stream.jsonl")
        // Feed it in awkward chunks: lines must survive being split anywhere.
        var lines: [Data] = []
        var i = data.startIndex
        while i < data.endIndex {
            let end = min(i + 977, data.endIndex)
            lines += buffer.append(data[i..<end])
            i = end
        }
        return try lines.map { try JSONDecoder().decode(MediaRemoteBridge.Update.self, from: $0) }
    }

    @Test func decodesTheRealStream() throws {
        let u = try updates()
        #expect(u.map(\.type) == ["ready", "info", "info", "info", "none"])
        #expect(u[1].title == "CoolDock Probe Song" && u[1].artist == "Probe Artist" && u[1].album == "Probe Album")
        #expect(u[1].duration == 200 && u[1].elapsed == 42 && u[1].rate == 1 && u[1].playing == true)
        #expect(u[1].artworkID == nil && u[2].artworkID != nil && u[2].artwork != nil)
        // The paused update keeps the artwork id but does not resend the bytes.
        #expect(u[3].playing == false && u[3].artworkID == u[2].artworkID && u[3].artwork == nil)
    }

    @Test func serviceFollowsTheStream() throws {
        let u = try updates()
        let np = NowPlayingService()
        let sampled = Date(timeIntervalSince1970: u[1].timestamp!)

        np.apply(u[1], now: sampled.addingTimeInterval(5))
        #expect(np.title == "CoolDock Probe Song" && np.artist == "Probe Artist" && np.isPlaying)
        #expect(np.duration == 200)
        // 42 s at the sample time, 5 s later while playing.
        #expect(abs(np.position(at: sampled.addingTimeInterval(5)) - 47) < 0.001)
        #expect(np.artwork == nil)

        np.apply(u[2], now: sampled.addingTimeInterval(6))
        let art = try #require(np.artwork)
        #expect(art.size.width > 0 && art.size.width <= 80)  // decoded straight to a 160 px (2×) thumbnail

        np.apply(u[3], now: sampled.addingTimeInterval(60))
        #expect(!np.isPlaying)
        #expect(np.position(at: sampled.addingTimeInterval(500)) == 42)  // paused: frozen at the reported elapsed time
        #expect(np.artwork === art)                                      // same artwork id: not decoded again

        np.apply(u[4])
        #expect(!np.hasTrack && np.artwork == nil && np.appName.isEmpty)
    }

    @Test func positionIsClampedAndRateAware() {
        let np = NowPlayingService()
        let t0 = Date(timeIntervalSince1970: 1_000)
        np.apply(.init(type: "info", title: "Long", duration: 100, elapsed: 90, timestamp: 1_000, rate: 2, playing: true), now: t0.addingTimeInterval(10))
        #expect(np.position(at: t0.addingTimeInterval(10)) == 100)  // 90 + 10 s × 2, clamped to the duration
        np.apply(.init(type: "info", title: "", playing: true))
        #expect(!np.hasTrack)  // an untitled session is treated as nothing playing
    }

    @Test func playingAppResolvesFromParentBundle() {
        // A browser plays through a web content process: the parent app is what the user knows.
        let safari = NowPlayingService.app(bundle: "com.apple.Safari", pid: nil)
        #expect(safari.bundleID == "com.apple.Safari" && safari.name == "Safari")
        // No usable bundle id (a helper process): fall back to the running app behind the pid.
        if let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first {
            let byPID = NowPlayingService.app(bundle: "not.an.app.example", pid: dock.processIdentifier)
            #expect(byPID.bundleID == "com.apple.dock" && byPID.name == dock.localizedName)
        }
        #expect(NowPlayingService.app(bundle: "invalid.bundle.id.example", pid: nil).name.isEmpty)
    }
}

/// End to end against the real MediaRemote daemon: builds the helper from `Helpers/MediaRemote`, publishes a track
/// from this test process, reads it back through `MediaRemoteBridge`, and pauses it with a remote command.
/// Opt-in (it briefly becomes the system's Now Playing app): `COOLDOCK_LIVE_MEDIA=1 swift test --filter MediaRemoteLive`.
/// It skips itself when another app is already playing, so it never sends a command to your music.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["COOLDOCK_LIVE_MEDIA"] == "1"))
struct MediaRemoteLiveTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func buildHelper() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nicedock-mediaremote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = Self.repo.appendingPathComponent("Helpers/MediaRemote")
        try FileManager.default.copyItem(at: src.appendingPathComponent("mediaremote.pl"), to: dir.appendingPathComponent("mediaremote.pl"))
        let clang = Process()
        clang.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        clang.arguments = ["clang", "-dynamiclib", "-fobjc-arc", "-O2", "-framework", "Foundation", "-mmacosx-version-min=14.0",
                           src.appendingPathComponent("CoolDockMediaRemote.m").path, "-o", dir.appendingPathComponent("libCoolDockMediaRemote.dylib").path]
        try clang.run()
        clang.waitUntilExit()
        #expect(clang.terminationStatus == 0)
        return dir
    }

    final class Log { var updates: [MediaRemoteBridge.Update] = [] }

    /// Polls (the bridge delivers on the main queue) until `match` holds or the timeout passes.
    func wait(_ timeout: Double, _ match: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if match() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return match()
    }

    @Test func publishesReadsAndPauses() async throws {
        MediaRemoteBridge.directoryOverride = try buildHelper()
        defer { MediaRemoteBridge.directoryOverride = nil }

        let log = Log()
        let bridge = MediaRemoteBridge()
        bridge.onUpdate = { log.updates.append($0) }
        bridge.start()
        defer { bridge.stop() }

        // Whatever is current before we publish anything.
        #expect(await wait(5) { bridge.isReady && !log.updates.isEmpty })
        if let before = log.updates.last, before.playing == true {
            Issue.record("Another app is playing (\(before.title ?? "?")); not taking over its Now Playing session.")
            return
        }

        let center = MPNowPlayingInfoCenter.default()
        let commands = MPRemoteCommandCenter.shared()
        var paused = false
        let pauseTarget = commands.pauseCommand.addTarget { _ in paused = true; center.playbackState = .paused; return .success }
        let playTarget = commands.playCommand.addTarget { _ in center.playbackState = .playing; return .success }
        defer {
            commands.pauseCommand.removeTarget(pauseTarget)
            commands.playCommand.removeTarget(playTarget)
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
        }
        center.nowPlayingInfo = [MPMediaItemPropertyTitle: "NiceDock Live Probe", MPMediaItemPropertyArtist: "Test Suite",
                                 MPMediaItemPropertyPlaybackDuration: 180.0, MPNowPlayingInfoPropertyElapsedPlaybackTime: 12.0,
                                 MPNowPlayingInfoPropertyPlaybackRate: 1.0]
        center.playbackState = .playing

        func probe(playing: Bool) -> MediaRemoteBridge.Update? {
            log.updates.last { $0.title == "NiceDock Live Probe" && $0.playing == playing }
        }
        #expect(await wait(8) { probe(playing: true) != nil })
        let mine = try #require(probe(playing: true))
        #expect(mine.pid == ProcessInfo.processInfo.processIdentifier)
        #expect(mine.artist == "Test Suite" && mine.duration == 180)

        let service = NowPlayingService()
        service.apply(mine)
        #expect(service.title == "NiceDock Live Probe" && service.isPlaying && service.player == nil)

        bridge.send("pause")
        let reported = await wait(8) { probe(playing: false) != nil }
        #expect(paused, "the pause command reached this process")
        #expect(reported, "MediaRemote reported the paused state back")
    }
}
