import AudioToolbox
import CoreAudio
import Foundation
import Testing
@testable import CoolDock

// Per-app volume: gain math, the real-time render routine on synthetic buffer lists, the aggregate description,
// process grouping / diffing / the tap plan, and persistence by bundle id. No Core Audio objects are created here;
// the end-to-end run against the real HAL is `AppVolumeLiveTests` (opt-in).

@Suite struct AppVolumeMathTests {
    typealias M = UtilAppVolumeMath

    @Test func clampsAndSnaps() {
        #expect(M.clamp(-0.4) == 0)
        #expect(M.clamp(1.7) == 1)
        #expect(M.clamp(0.42) == 0.42)
        #expect(M.clamp(.nan) == 1, "never silence an app by accident")
        #expect(M.clamp(.infinity) == 1)
        #expect(M.snapped(0.996) == 1)
        #expect(M.snapped(0.004) == 0)
        #expect(M.snapped(0.5) == 0.5)
        #expect(M.snapped(2) == 1)
    }

    @Test func gainIsLinearAndMuteIsZero() {
        #expect(M.gain(UtilAppVolumeLevel(volume: 0.5, muted: false)) == 0.5)
        #expect(M.gain(UtilAppVolumeLevel(volume: 0.25, muted: false)) == 0.25)
        #expect(M.gain(UtilAppVolumeLevel(volume: 0.8, muted: true)) == 0)
        #expect(M.gain(UtilAppVolumeLevel(volume: 3, muted: false)) == 1, "no boost above 100 %")
        #expect(M.gain(UtilAppVolumeLevel(volume: -1, muted: false)) == 0)
    }

    @Test func onlyChangedLevelsNeedATap() {
        #expect(!M.needsTap(.unity))
        #expect(!M.needsTap(UtilAppVolumeLevel(volume: 0.999, muted: false)))
        #expect(M.needsTap(UtilAppVolumeLevel(volume: 0.99, muted: false)))
        #expect(M.needsTap(UtilAppVolumeLevel(volume: 1, muted: true)))
        #expect(M.needsTap(UtilAppVolumeLevel(volume: 0, muted: false)))
        #expect(UtilAppVolumeLevel(volume: 1, muted: false).isDefault)
    }
}

/// Buffer lists built by hand: `layout` = (channels, frames) per buffer, interleaved within a buffer.
final class TestBufferList {
    let list: UnsafeMutableAudioBufferListPointer
    private var data: [UnsafeMutablePointer<Float>] = []
    private let layout: [(channels: Int, frames: Int)]

    init(_ layout: [(channels: Int, frames: Int)], fill: (_ buffer: Int, _ frame: Int, _ channel: Int) -> Float = { _, _, _ in 0 }) {
        self.layout = layout
        list = AudioBufferList.allocate(maximumBuffers: max(1, layout.count))
        list.count = layout.count
        for (i, l) in layout.enumerated() {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: max(1, l.channels * l.frames))
            for f in 0..<l.frames { for c in 0..<l.channels { p[f * l.channels + c] = fill(i, f, c) } }
            list[i] = AudioBuffer(mNumberChannels: UInt32(l.channels), mDataByteSize: UInt32(l.channels * l.frames * 4), mData: p)
            data.append(p)
        }
    }

    deinit {
        data.forEach { $0.deallocate() }
        free(list.unsafeMutablePointer)
    }

    func sample(_ buffer: Int, _ frame: Int, _ channel: Int) -> Float { data[buffer][frame * layout[buffer].channels + channel] }
}

@Suite struct AppVolumeDSPTests {
    func state(_ gain: Float, current: Float? = nil) -> UnsafeMutablePointer<UtilAppVolumeDSP.State> {
        let s = UnsafeMutablePointer<UtilAppVolumeDSP.State>.allocate(capacity: 1)
        s.initialize(to: UtilAppVolumeDSP.State(target: gain, current: current ?? gain))
        return s
    }

    func render(_ input: TestBufferList, _ output: TestBufferList, _ s: UnsafeMutablePointer<UtilAppVolumeDSP.State>) {
        UtilAppVolumeDSP.render(input.list.unsafePointer, output.list.unsafeMutablePointer, s)
    }

    /// A deterministic test signal in −0.8…0.8, different per channel.
    static func signal(_ f: Int, _ c: Int) -> Float { 0.8 * sinf(Float(f) * 0.05 + Float(c) * 1.3) }

    @Test func stereoAtHalfGain() {
        let input = TestBufferList([(2, 512)]) { _, f, c in Self.signal(f, c) }
        let output = TestBufferList([(2, 512)]) { _, _, _ in 9 }  // garbage that must be overwritten
        let s = state(0.5)
        defer { s.deallocate() }
        render(input, output, s)
        for f in 0..<512 { for c in 0..<2 { #expect(output.sample(0, f, c) == input.sample(0, f, c) * 0.5) } }
        #expect(abs(s.pointee.outPeak - 0.5 * s.pointee.inPeak) < 1e-6)
        #expect(s.pointee.inPeak > 0.79)
        #expect(s.pointee.cycles == 1)
    }

    @Test func gainChangeRampsAcrossOneBuffer() {
        let input = TestBufferList([(2, 100)]) { _, _, _ in 1 }
        let output = TestBufferList([(2, 100)])
        let s = state(0, current: 1)
        defer { s.deallocate() }
        render(input, output, s)
        #expect(abs(output.sample(0, 0, 0) - 0.99) < 1e-5)
        #expect(abs(output.sample(0, 49, 1) - 0.5) < 1e-5)
        #expect(abs(output.sample(0, 99, 0)) < 1e-5)
        #expect(s.pointee.current == 0)
        // Next buffer: settled at the target.
        render(input, output, s)
        #expect((0..<100).allSatisfy { output.sample(0, $0, 0) == 0 && output.sample(0, $0, 1) == 0 })
    }

    @Test func muteIsExactSilence() {
        let input = TestBufferList([(2, 256)]) { _, f, c in Self.signal(f, c) }
        let output = TestBufferList([(2, 256)]) { _, _, _ in 1 }
        let s = state(0)
        defer { s.deallocate() }
        render(input, output, s)
        #expect((0..<256).allSatisfy { output.sample(0, $0, 0) == 0 && output.sample(0, $0, 1) == 0 })
        #expect(s.pointee.outPeak == 0)
        #expect(s.pointee.inPeak > 0.5)
    }

    @Test func stereoToMonoAverages() {
        let input = TestBufferList([(2, 64)]) { _, f, c in c == 0 ? 0.6 : Float(f) / 64 }
        let output = TestBufferList([(1, 64)])
        let s = state(0.5)
        defer { s.deallocate() }
        render(input, output, s)
        for f in 0..<64 { #expect(abs(output.sample(0, f, 0) - (0.6 + Float(f) / 64) * 0.5 * 0.5) < 1e-6) }
    }

    @Test func extraOutputChannelsAndBuffersAreSilent() {
        // Stereo tap → a 4-channel device with two stereo buffers: channels 0/1 carry the app, 2/3 are silent.
        let input = TestBufferList([(2, 128)]) { _, f, c in Self.signal(f, c) }
        let output = TestBufferList([(2, 128), (2, 128)]) { _, _, _ in 5 }
        let s = state(1)
        defer { s.deallocate() }
        render(input, output, s)
        for f in 0..<128 {
            #expect(output.sample(0, f, 0) == input.sample(0, f, 0) && output.sample(0, f, 1) == input.sample(0, f, 1))
            #expect(output.sample(1, f, 0) == 0 && output.sample(1, f, 1) == 0)
        }
    }

    @Test func nonInterleavedInputAndShortInput() {
        // Two mono input buffers (non-interleaved), 100 frames, into a 128-frame stereo output: the tail is zeroed.
        let input = TestBufferList([(1, 100), (1, 100)]) { b, f, _ in b == 0 ? 0.25 : -Float(f) / 200 }
        let output = TestBufferList([(2, 128)]) { _, _, _ in 7 }
        let s = state(0.5)
        defer { s.deallocate() }
        render(input, output, s)
        #expect(output.sample(0, 10, 0) == 0.125)
        #expect(abs(output.sample(0, 10, 1) + 0.025) < 1e-7)
        #expect((100..<128).allSatisfy { output.sample(0, $0, 0) == 0 && output.sample(0, $0, 1) == 0 })
    }

    @Test func noInputPlaysSilence() {
        let input = TestBufferList([])
        let output = TestBufferList([(2, 32)]) { _, _, _ in 3 }
        let s = state(1)
        defer { s.deallocate() }
        render(input, output, s)
        #expect((0..<32).allSatisfy { output.sample(0, $0, 0) == 0 && output.sample(0, $0, 1) == 0 })
        #expect(s.pointee.inPeak == 0 && s.pointee.outPeak == 0)
    }

    @Test func onlyFloat32PCMIsSupported() {
        var f = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        #expect(UtilAppVolumeDSP.supports(f))
        f.mFormatFlags = kAudioFormatFlagIsSignedInteger
        #expect(!UtilAppVolumeDSP.supports(f))
        f.mFormatFlags = kAudioFormatFlagIsFloat
        f.mBitsPerChannel = 64
        #expect(!UtilAppVolumeDSP.supports(f))
    }
}

@Suite struct AppVolumeAggregateTests {
    @Test func privateAggregateWithOutputAndOneTap() throws {
        let d = UtilAppVolumeAggregate.description(outputUID: "BuiltInSpeakerDevice", tapUID: "TAP-UUID", uid: "app.cooldock.appvolume.X")
        #expect(d[kAudioAggregateDeviceUIDKey] as? String == "app.cooldock.appvolume.X")
        #expect((d[kAudioAggregateDeviceUIDKey] as? String)?.hasPrefix(UtilAppVolumeAggregate.uidPrefix) == true)
        #expect(d[kAudioAggregateDeviceNameKey] as? String == "CoolDock App Volume")
        #expect(d[kAudioAggregateDeviceMainSubDeviceKey] as? String == "BuiltInSpeakerDevice")
        #expect(d[kAudioAggregateDeviceIsPrivateKey] as? Bool == true)
        #expect(d[kAudioAggregateDeviceIsStackedKey] as? Bool == false)
        #expect(d[kAudioAggregateDeviceTapAutoStartKey] as? Bool == true)
        let subs = try #require(d[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]])
        #expect(subs.count == 1 && subs[0][kAudioSubDeviceUIDKey] as? String == "BuiltInSpeakerDevice")
        let taps = try #require(d[kAudioAggregateDeviceTapListKey] as? [[String: Any]])
        #expect(taps.count == 1)
        #expect(taps[0][kAudioSubTapUIDKey] as? String == "TAP-UUID")
        #expect(taps[0][kAudioSubTapDriftCompensationKey] as? Bool == true)
        // The literal keys Core Audio reads.
        #expect(Set(d.keys) == ["name", "uid", "master", "private", "stacked", "tapautostart", "subdevices", "taps"])
        // Bridges to the CFDictionary the HAL takes.
        let cf = d as CFDictionary
        #expect(CFDictionaryGetCount(cf) == 8)
    }
}

@Suite struct AppVolumeProcessTests {
    typealias Model = UtilAppVolumeModel

    @Test func diffsProcessObjectLists() {
        let d = Model.diff(old: [10, 11, 12], new: [11, 12, 13, 14])
        #expect(d.added == [13, 14])
        #expect(d.removed == [10])
        let same = Model.diff(old: [1, 2], new: [2, 1])
        #expect(same.added.isEmpty && same.removed.isEmpty)
        #expect(Model.diff(old: [], new: [5]).added == [5])
        #expect(Model.diff(old: [5], new: []).removed == [5])
    }

    static let processes = [
        UtilAudioProcess(object: 107, pid: 3869, bundleID: "com.google.Chrome.helper", running: true),
        UtilAudioProcess(object: 109, pid: 1757, bundleID: "com.google.Chrome", running: false),
        UtilAudioProcess(object: 108, pid: 6815, bundleID: "com.google.Chrome.helper", running: false),
        UtilAudioProcess(object: 120, pid: 900, bundleID: "", running: true),           // afplay
        UtilAudioProcess(object: 130, pid: 42, bundleID: "app.cooldock.CoolDock", running: true),  // ourselves
        UtilAudioProcess(object: 140, pid: 77, bundleID: "com.apple.WebKit.GPU", running: false)
    ]

    /// Real attribution from this Mac's process list: Chrome's helpers → Chrome; WebKit GPU → Safari.
    static func identity(_ p: UtilAudioProcess) -> UtilAudioIdentity? {
        switch p.pid {
        case 3869, 1757, 6815: return UtilAudioIdentity(key: "com.google.Chrome", name: "Google Chrome", iconPath: "/Applications/Google Chrome.app")
        case 900: return UtilAudioIdentity(key: "/usr/bin/afplay", name: "afplay", iconPath: nil)
        case 77: return UtilAudioIdentity(key: "com.apple.Safari", name: "Safari", iconPath: "/Applications/Safari.app")
        default: return nil
        }
    }

    @Test func groupsHelpersUnderTheirApp() {
        let apps = Model.group(Self.processes, identity: Self.identity)
        #expect(apps.map(\.id) == ["com.google.Chrome", "/usr/bin/afplay", "com.apple.Safari"])
        let chrome = apps[0]
        #expect(chrome.processes == [107, 108, 109])
        #expect(Set(chrome.pids) == [3869, 1757, 6815])
        #expect(chrome.running, "one playing helper makes the app playing")
        #expect(apps[1].running && apps[1].name == "afplay" && apps[1].iconPath == nil)
        #expect(!apps[2].running)
        #expect(!apps.contains { $0.pids.contains(42) }, "CoolDock never lists itself")
    }

    func app(_ id: String, _ processes: [AudioObjectID], running: Bool = true) -> UtilAudioApp {
        UtilAudioApp(id: id, name: id, iconPath: nil, processes: processes, pids: processes.map { pid_t($0) }, running: running)
    }

    @Test func planCreatesOnlyForChangedLevels() {
        let apps = [app("music", [1]), app("safari", [2]), app("zoom", [3], running: false)]
        let levels = ["music": UtilAppVolumeLevel(volume: 0.5, muted: false),
                      "safari": UtilAppVolumeLevel(volume: 1, muted: false),
                      "zoom": UtilAppVolumeLevel(volume: 1, muted: true),
                      "gone": UtilAppVolumeLevel(volume: 0.2, muted: false)]
        let actions = Model.plan(apps: apps, levels: levels, taps: [:], allowed: true)
        #expect(actions == [.create(key: "music", processes: [1], gain: 0.5, running: true),
                            .create(key: "zoom", processes: [3], gain: 0, running: false)])
    }

    @Test func planFollowsGainProcessesRunningAndTeardown() {
        let taps = ["music": UtilAppVolumeTapSnapshot(processes: [1], gain: 0.5, running: true),
                    "chrome": UtilAppVolumeTapSnapshot(processes: [7], gain: 0.3, running: false),
                    "afplay": UtilAppVolumeTapSnapshot(processes: [9], gain: 0.5, running: true)]
        let apps = [app("music", [1]), app("chrome", [7, 8])]
        let levels = ["music": UtilAppVolumeLevel(volume: 0.25, muted: false),
                      "chrome": UtilAppVolumeLevel(volume: 0.3, muted: false),
                      "afplay": UtilAppVolumeLevel(volume: 0.5, muted: false)]
        // afplay exited (no longer in apps): its tap goes; Chrome spawned a helper and started playing; Music got quieter.
        #expect(Model.plan(apps: apps, levels: levels, taps: taps, allowed: true) == [
            .destroy(key: "afplay"),
            .gain(key: "music", 0.25),
            .update(key: "chrome", processes: [7, 8]),
            .run(key: "chrome", true)
        ])
        // Back to 100 %: the tap goes.
        var unity = levels
        unity["music"] = .unity
        #expect(Model.plan(apps: [apps[0]], levels: unity, taps: ["music": taps["music"]!], allowed: true) == [.destroy(key: "music")])
        // Permission denied: every tap goes, nothing is created.
        #expect(Model.plan(apps: apps, levels: levels, taps: taps, allowed: false) == [.destroy(key: "afplay"), .destroy(key: "chrome"), .destroy(key: "music")])
        // A failed app is never retried in the same session.
        #expect(Model.plan(apps: [app("x", [4])], levels: ["x": UtilAppVolumeLevel(volume: 0.4)], taps: [:], allowed: true, blocked: ["x"]).isEmpty)
        // An app without process objects gets no tap.
        #expect(Model.plan(apps: [app("y", [])], levels: ["y": UtilAppVolumeLevel(volume: 0.4)], taps: [:], allowed: true).isEmpty)
    }
}

@MainActor
@Suite struct AppVolumePersistenceTests {
    func service(_ storage: UtilAppVolumeMemoryStorage) -> UtilAppVolumeService {
        let s = UtilAppVolumeService(storage: storage, monitor: false, taps: false)
        s.saveDelay = 0
        return s
    }

    @Test func settingsRoundTripKeyedByBundleID() throws {
        var settings = Settings()
        settings.appVolumes = ["com.apple.Music": UtilAppVolumeLevel(volume: 0.3, muted: false),
                               "us.zoom.xos": UtilAppVolumeLevel(volume: 1, muted: true),
                               "/usr/bin/afplay": UtilAppVolumeLevel(volume: 0.5, muted: false)]
        settings.remembersAppVolumes = false
        let data = try JSONEncoder().encode(settings)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let stored = try #require(json["appVolumes"] as? [String: [String: Any]])
        #expect(stored["com.apple.Music"]?["volume"] as? Double == 0.3)
        #expect(stored["us.zoom.xos"]?["muted"] as? Bool == true)
        let back = try JSONDecoder().decode(Settings.self, from: data)
        #expect(back == settings)
        #expect(!back.remembersAppVolumes)
    }

    @Test func stateFilesFromBeforeAppVolumeStillLoad() throws {
        let data = try JSONEncoder().encode(Settings())
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["appVolumes"] = nil
        json["appVolumeRemember"] = nil
        let old = try JSONDecoder().decode(Settings.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.appVolumes == nil)
        #expect(old.remembersAppVolumes, "remember is on by default")
    }

    @Test func levelsPersistByKeyAndDefaultsArePruned() {
        let storage = UtilAppVolumeMemoryStorage()
        let s = service(storage)
        s.setVolume(0.3, for: "com.apple.Music")
        s.setMuted(true, for: "us.zoom.xos")
        #expect(storage.saved == ["com.apple.Music": UtilAppVolumeLevel(volume: 0.3, muted: false),
                                  "us.zoom.xos": UtilAppVolumeLevel(volume: 1, muted: true)])
        // Dragging to the end (snapped) or unmuting at 100 % removes the entry.
        s.setVolume(0.997, for: "com.apple.Music")
        s.setMuted(false, for: "us.zoom.xos")
        #expect(storage.saved.isEmpty)
        #expect(s.level("com.apple.Music") == .unity)

        // Moving the slider while muted unmutes (like the system volume); unmuting at 0 % comes back at 100 %.
        s.setMuted(true, for: "a")
        s.setVolume(0.4, for: "a")
        #expect(s.level("a") == UtilAppVolumeLevel(volume: 0.4, muted: false))
        s.setVolume(0, for: "a")
        s.setMuted(true, for: "a")
        s.setMuted(false, for: "a")
        #expect(s.level("a") == .unity)

        // A new session reads the saved levels back.
        s.setVolume(0.6, for: "com.apple.Safari")
        let next = service(storage)
        #expect(next.level("com.apple.Safari").volume == 0.6)
        #expect(next.changedCount == 1)

        next.resetAll()
        #expect(storage.saved.isEmpty && next.changedCount == 0)
    }

    @Test func rememberOffKeepsLevelsOnlyWhileTheAppRuns() {
        let storage = UtilAppVolumeMemoryStorage(["com.apple.Music": UtilAppVolumeLevel(volume: 0.3, muted: false)])
        let s = service(storage)
        let music = UtilAudioApp(id: "com.apple.Music", name: "Music", iconPath: nil, processes: [1], pids: [1], running: true)
        s.injectApps([music])
        s.setRemember(false)
        #expect(storage.saved.isEmpty && !storage.remember)
        s.setVolume(0.5, for: "com.apple.Music")
        #expect(storage.saved.isEmpty, "nothing is written while remember is off")
        #expect(s.level("com.apple.Music").volume == 0.5)
        s.injectApps([])
        #expect(s.level("com.apple.Music") == .unity, "the level ends with the app")

        // Remember on: the level outlives the app.
        s.setRemember(true)
        s.injectApps([music])
        s.setVolume(0.2, for: "com.apple.Music")
        s.injectApps([])
        #expect(s.level("com.apple.Music").volume == 0.2)
        #expect(storage.saved["com.apple.Music"]?.volume == 0.2)
    }

    @Test func playingAppsNewestFirst() {
        let s = service(UtilAppVolumeMemoryStorage())
        func app(_ id: String, running: Bool = true) -> UtilAudioApp {
            UtilAudioApp(id: id, name: id, iconPath: nil, processes: [1], pids: [1], running: running)
        }
        s.injectApps([app("Music"), app("Safari")])
        #expect(s.apps.map(\.id) == ["Music", "Safari"], "same start time: by name")
        s.injectApps([app("Music"), app("Safari"), app("Zoom"), app("Idle", running: false)])
        #expect(s.apps.map(\.id) == ["Zoom", "Music", "Safari"], "the app that just started comes first; silent apps are hidden")
    }
}
