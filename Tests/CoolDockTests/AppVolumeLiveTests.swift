import AVFoundation
import CoreAudio
import Foundation
import Testing
@testable import CoolDock

/// End to end against the real Core Audio HAL: plays a quiet generated tone with `/usr/bin/afplay`, finds its process
/// object through `UtilAppVolumeService`, sets it to 50 % and reads the peak meters measured inside the IO block
/// (output ≈ 0.5 × input), mutes it (output exactly 0), and checks that the tap and its private aggregate are gone
/// from the HAL when the volume returns to 100 % and when afplay exits.
///
/// Opt-in (it plays a short, quiet tone and may trigger the System Audio Recording prompt):
///
///     COOLDOCK_LIVE_AUDIO=1 swift test --filter AppVolumeLive
///
/// While the tap exists the original output is muted, so the tone is only heard at the tested gain.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["COOLDOCK_LIVE_AUDIO"] == "1"))
struct AppVolumeLiveTests {
    /// 220 Hz stereo sine at `amplitude` (0.1 ≈ −20 dBFS), float CAF in a temp directory.
    static func tone(seconds: Double, amplitude: Float) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cooldock-appvolume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("tone.caf")
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: true))
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: true)
        let frames = AVAudioFrameCount(48000 * seconds)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let data = try #require(buffer.floatChannelData)[0]
        for i in 0..<Int(frames) {
            let v = amplitude * sinf(Float(i) * 2 * .pi * 220 / 48000)
            data[2 * i] = v
            data[2 * i + 1] = v
        }
        try file.write(from: buffer)
        return url
    }

    /// Lets the main queue deliver Core Audio listener callbacks until `match` holds.
    func wait(_ timeout: Double, _ match: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if match() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return match()
    }

    /// Device UIDs and tap UIDs this process can see (its private aggregates and taps included).
    static func halUIDs() -> (devices: Set<String>, taps: Set<String>) {
        let devices = Set(UtilCA.deviceIDs().compactMap { UtilCA.string($0, kAudioDevicePropertyDeviceUID) })
        var a = UtilCA.address(kAudioHardwarePropertyTapList)
        var size: UInt32 = 0
        var taps: [AudioObjectID] = []
        if AudioObjectGetPropertyDataSize(UtilCA.system, &a, 0, nil, &size) == noErr, size > 0 {
            taps = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
            if AudioObjectGetPropertyData(UtilCA.system, &a, 0, nil, &size, &taps) != noErr { taps = [] }
        }
        return (devices, Set(taps.compactMap { UtilCA.string($0, kAudioTapPropertyUID) }))
    }

    static func exists(_ uids: (aggregate: String, tap: String)) -> (aggregate: Bool, tap: Bool) {
        let hal = halUIDs()
        return (hal.devices.contains(uids.aggregate), hal.taps.contains(uids.tap.uppercased()) || hal.taps.contains(uids.tap))
    }

    static func log(_ line: String) {
        print("AppVolumeLive: \(line)")
    }

    @Test func gainMuteAndTeardown() async throws {
        let url = try Self.tone(seconds: 5, amplitude: 0.1)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let storage = UtilAppVolumeMemoryStorage()
        let service = UtilAppVolumeService(storage: storage)
        service.saveDelay = 0
        service.subscribe("live-test")
        defer {
            service.unsubscribe("live-test")
            service.shutdown()
        }

        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = [url.path]
        try player.run()
        defer { if player.isRunning { player.terminate() } }
        let pid = player.processIdentifier

        // 1. afplay shows up as an app producing sound, with no tap at 100 %.
        let appeared = await wait(5) { service.apps.contains { $0.pids.contains(pid) } }
        #expect(appeared, "afplay's process object is listed and running output")
        if !appeared {
            Self.log("apps known: " + service.allApps.map { "\($0.id) pids \($0.pids) running \($0.running)" }.joined(separator: "; "))
        }
        let app = try #require(service.apps.first { $0.pids.contains(pid) })
        let key = app.id
        Self.log("afplay pid \(pid) → key \(key), process objects \(app.processes)")
        #expect(!service.hasTap(key))

        // 2. 50 %: output peak ≈ 0.5 × input peak, measured in the IO block.
        let t0 = Date()
        service.setVolume(0.5, for: key)
        #expect(await wait(3) { service.tapped.contains(key) }, "tap built")
        let built = Date().timeIntervalSince(t0)
        #expect(await wait(3) { (service.debugMeters(key)?.cycles ?? 0) > 0 }, "IO running")
        let firstCycle = Date().timeIntervalSince(t0)
        #expect(await wait(3) { (service.debugMeters(key)?.input ?? 0) > 0.05 }, "the tap receives afplay's audio")
        Self.log(String(format: "setVolume → tap built %.0f ms, first IO cycle %.0f ms, afplay's audio in the IO block %.0f ms",
                        built * 1000, firstCycle * 1000, Date().timeIntervalSince(t0) * 1000))
        try await Task.sleep(for: .milliseconds(100))
        service.debugResetMeters(key)
        let c0 = service.debugMeters(key)?.cycles ?? 0
        try await Task.sleep(for: .milliseconds(500))
        let half = try #require(service.debugMeters(key))
        Self.log(String(format: "50 %%: input peak %.5f, output peak %.5f, ratio %.5f over %u IO cycles (build %.0f ms)",
                        half.input, half.output, half.output / max(half.input, 1e-9), half.cycles &- c0, built * 1000))
        #expect(half.input > 0.09 && half.input < 0.11, "the 0.1 tone")
        #expect(abs(half.output - 0.5 * half.input) <= 0.005 * half.input)
        let uids = try #require(service.debugUIDs(key))
        #expect(Self.exists(uids) == (true, true), "private aggregate and tap are visible to this process")

        // 3. Mute: output exactly 0 while the input keeps arriving.
        service.setMuted(true, for: key)
        try await Task.sleep(for: .milliseconds(100))
        service.debugResetMeters(key)
        try await Task.sleep(for: .milliseconds(500))
        let muted = try #require(service.debugMeters(key))
        Self.log(String(format: "muted: input peak %.5f, output peak %.5f", muted.input, muted.output))
        #expect(muted.input > 0.09)
        #expect(muted.output == 0)

        // 4. Back to 100 % (unmute, then the slider to the end): the tap and aggregate are destroyed.
        service.setMuted(false, for: key)
        service.setVolume(1, for: key)
        let removed = await wait(3) { !service.hasTap(key) && Self.exists(uids) == (false, false) }
        #expect(removed, "no tap at 100 %")
        Self.log("100 %: tap \(service.hasTap(key) ? "present" : "removed"), aggregate in HAL: \(Self.exists(uids).aggregate), tap in HAL: \(Self.exists(uids).tap)")
        #expect(storage.saved[key] == nil, "100 % is not stored")

        // 5. 50 % again, then afplay exits: its tap goes with it.
        service.setVolume(0.5, for: key)
        #expect(await wait(3) { service.tapped.contains(key) })
        let again = try #require(service.debugUIDs(key))
        #expect(storage.saved[key]?.volume == 0.5, "persisted by key")
        #expect(await wait(8) { !player.isRunning }, "the tone ends")
        let gone = await wait(3) { !service.hasTap(key) && Self.exists(again) == (false, false) }
        #expect(gone, "afplay exited: tap removed")
        Self.log("afplay exited (status \(player.terminationStatus)): tap \(service.hasTap(key) ? "present" : "removed"), aggregate in HAL: \(Self.exists(again).aggregate)")
        #expect(!service.apps.contains { $0.id == key })
        #expect(service.level(key).volume == 0.5, "remembered for the next run")

        // 6. A new afplay gets the remembered 50 % as soon as it appears (no slider involved), and quitting
        //    (`shutdown`, as in applicationWillTerminate) removes the tap and aggregate from the HAL.
        let second = Process()
        second.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        second.arguments = [url.path]
        try second.run()
        defer { if second.isRunning { second.terminate() } }
        #expect(await wait(5) { service.tapped.contains(key) && service.apps.contains { $0.pids.contains(second.processIdentifier) } },
                "remembered level applied to the new process")
        #expect(await wait(3) { (service.debugMeters(key)?.input ?? 0) > 0.05 })
        service.debugResetMeters(key)
        try await Task.sleep(for: .milliseconds(300))
        let remembered = try #require(service.debugMeters(key))
        Self.log(String(format: "second afplay, remembered 50 %%: input %.5f, output %.5f", remembered.input, remembered.output))
        #expect(abs(remembered.output - 0.5 * remembered.input) <= 0.005 * remembered.input)
        let last = try #require(service.debugUIDs(key))
        #expect(service.shutdown(), "teardown finished within the quit timeout")
        #expect(!service.hasTap(key))
        #expect(await wait(2) { Self.exists(last) == (false, false) }, "nothing left in the HAL after quit")
        Self.log("shutdown: aggregate in HAL \(Self.exists(last).aggregate), tap in HAL \(Self.exists(last).tap)")
    }
}
