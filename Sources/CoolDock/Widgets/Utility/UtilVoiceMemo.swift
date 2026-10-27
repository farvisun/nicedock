import AppKit
import AVFoundation
import Observation
import SwiftUI

/// Records m4a voice memos into ~/Music/CoolDock Voice Memos and plays them back.
@Observable
@MainActor
final class UtilVoiceRecorder {
    static let shared = UtilVoiceRecorder()

    enum State { case idle, recording, paused }

    struct Recording: Identifiable, Hashable, Sendable {
        var id: URL { url }
        let url: URL
        let date: Date
        let duration: TimeInterval
    }

    private(set) var state: State = .idle
    private(set) var recordings: [Recording] = []
    private(set) var playing: URL?
    private(set) var permissionDenied = false
    private(set) var failed = false

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private let playerDelegate = UtilVoicePlayerDelegate()
    @ObservationIgnored private var accumulated: TimeInterval = 0
    @ObservationIgnored private var resumedAt: Date?
    @ObservationIgnored private(set) var levels = [Float](repeating: 0, count: 16)
    @ObservationIgnored private var lastLevelAt = Date.distantPast

    static let directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Music/CoolDock Voice Memos", isDirectory: true)

    private static let nameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f
    }()

    var elapsed: TimeInterval { accumulated + (resumedAt.map { Date().timeIntervalSince($0) } ?? 0) }
    var isActive: Bool { state != .idle }

    /// Frozen recorder state for `--scene reference` renders (no microphone). No effect outside the scene.
    func seedReference(recording: Bool, elapsed: TimeInterval, levels: [Float]) {
        guard ReferenceScene.isActive else { return }
        state = recording ? .recording : .idle
        accumulated = recording ? elapsed : 0
        resumedAt = nil
        self.levels = levels
        permissionDenied = false
        failed = false
    }

    // MARK: Recording

    /// User action only — may show the microphone permission prompt.
    func start() {
        guard state == .idle, !UtilEnv.rendering else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            begin()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if granted { UtilVoiceRecorder.shared.begin() } else { UtilVoiceRecorder.shared.permissionDenied = true }
                    }
                }
            }
        default:
            permissionDenied = true
            Open.url("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        }
    }

    private func begin() {
        permissionDenied = false
        failed = false
        stopPlayback()
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            let url = Self.directory.appendingPathComponent("Memo " + Self.nameFormatter.string(from: Date()) + ".m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.isMeteringEnabled = true
            guard r.record() else { failed = true; return }
            recorder = r
            accumulated = 0
            resumedAt = Date()
            levels = [Float](repeating: 0, count: levels.count)
            state = .recording
        } catch {
            failed = true
        }
    }

    func togglePause() {
        guard let r = recorder else { return }
        switch state {
        case .recording:
            r.pause()
            accumulated = elapsed
            resumedAt = nil
            state = .paused
        case .paused:
            r.record()
            resumedAt = Date()
            state = .recording
        case .idle:
            break
        }
    }

    func stop() {
        recorder?.stop()
        recorder = nil
        resumedAt = nil
        accumulated = 0
        state = .idle
        Task { await reload() }
    }

    /// Called from the recording tile's timeline; reads the meter at most every 75 ms.
    /// Mutates only observation-ignored storage, so it is safe to call while rendering.
    func sampleLevels(at date: Date) -> [Float] {
        guard state == .recording, let r = recorder else { return levels }
        if date.timeIntervalSince(lastLevelAt) >= 0.075 {
            lastLevelAt = date
            r.updateMeters()
            let avg = r.averagePower(forChannel: 0), peak = r.peakPower(forChannel: 0)
            let db = avg * 0.6 + peak * 0.4
            let norm = max(0, min(1, (db + 48) / 48))
            levels.removeFirst()
            levels.append(pow(norm, 1.6))
        }
        return levels
    }

    // MARK: Library

    func reload() async {
        let dir = Self.directory
        recordings = await Task.detached(priority: .utility) { () -> [Recording] in
            let fm = FileManager.default
            guard let urls = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles]) else { return [] }
            return urls.filter { ["m4a", "caf", "wav"].contains($0.pathExtension.lowercased()) }
                .map { url in
                    let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                    let duration = (try? AVAudioFile(forReading: url)).map { Double($0.length) / max(1, $0.fileFormat.sampleRate) } ?? 0
                    return Recording(url: url, date: date, duration: duration)
                }
                .sorted { $0.date > $1.date }
        }.value
    }

    func play(_ rec: Recording) {
        if playing == rec.url { stopPlayback(); return }
        stopPlayback()
        guard let p = try? AVAudioPlayer(contentsOf: rec.url) else { return }
        p.delegate = playerDelegate
        p.play()
        player = p
        playing = rec.url
    }

    func stopPlayback() {
        player?.stop()
        player = nil
        playing = nil
    }

    fileprivate func playbackFinished() {
        player = nil
        playing = nil
    }

    func delete(_ rec: Recording) {
        if playing == rec.url { stopPlayback() }
        NSWorkspace.shared.recycle([rec.url]) { _, _ in
            Task { @MainActor in await UtilVoiceRecorder.shared.reload() }
        }
    }
}

private final class UtilVoicePlayerDelegate: NSObject, AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { MainActor.assumeIsolated { UtilVoiceRecorder.shared.playbackFinished() } }
    }
}

// MARK: - Tile

struct UtilVoiceMemoView: View {
    let w: WidgetInstance
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    @State private var hover = false
    private var rec: UtilVoiceRecorder { .shared }

    var body: some View {
        Group {
            if rec.isActive {
                recordingTile
                    .transition(.opacity)
            } else {
                idleTile
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: rec.isActive)
    }

    private var idleTile: some View {
        // Decorative arc, as long as in the reference frame.
        SysRingTile(value: 0.477, color: rec.permissionDenied || rec.failed ? .cdRed : .cdGreen, label: nil, ringY: -0.5) {
            Image(systemName: rec.permissionDenied ? "mic.slash.fill" : "mic.fill")
                .font(.system(size: m.u(12.75), weight: .semibold))
        }
        .overlay(alignment: .topTrailing) {
            if hover {
                Button { UtilVoiceMemoPanel.toggle(w) } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: m.u(7.5), weight: .bold))
                        .foregroundStyle(p.primary)
                        .frame(width: m.u(16), height: m.u(16))
                        .background(Circle().fill(p.controlStrong))
                }
                .buttonStyle(PressableStyle())
                .padding(m.u(4))
                .help(L("Recordings…"))
                .transition(.opacity)
            }
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.option) { UtilVoiceMemoPanel.toggle(w) } else { rec.start() }
        }
        .help(rec.permissionDenied ? L("Microphone access is off — click to open Privacy settings") : L("Click to record · ⌥-click for recordings"))
    }

    private var recordingTile: some View {
        let red = p.accent(UtilTint.red)
        let redLight = p.monochrome ? red : UtilTint.redLight
        return Tile(width: 170, padding: EdgeInsets(top: 0, leading: 5.5, bottom: 0, trailing: 6.5)) {
            HStack(spacing: 0) {
                TimelineView(.animation(minimumInterval: 0.08, paused: rec.state != .recording)) { ctx in
                    HStack(spacing: 0) {
                        // Shrinks rather than overflowing once recordings pass ten minutes.
                        Text(verbatim: Fmt.duration(rec.elapsed))
                            .dock(21, .bold, mono: true)
                            .minimumScaleFactor(0.6)
                        Spacer(minLength: m.u(2.5))
                        let levels = rec.sampleLevels(at: ctx.date)
                        UtilWaveform(levels: levels, color: red, topColor: redLight)
                            .frame(width: m.u(CGFloat(levels.count) * 3), height: m.u(17))
                            .opacity(rec.state == .paused ? 0.45 : 1)
                    }
                }
                Spacer(minLength: m.u(2.5)).frame(maxWidth: m.u(2.5))
                Button { rec.togglePause() } label: {
                    Group {
                        if rec.state == .paused {
                            Image(systemName: "play.fill").font(.system(size: m.u(8.5), weight: .black))
                        } else {
                            HStack(spacing: m.u(1)) {
                                RoundedRectangle(cornerRadius: m.u(0.6)).frame(width: m.u(2), height: m.u(7))
                                RoundedRectangle(cornerRadius: m.u(0.6)).frame(width: m.u(2), height: m.u(7))
                            }
                        }
                    }
                    .foregroundStyle(p.primary.opacity(0.81))
                    .frame(width: m.u(22), height: m.u(22))
                    .background(Circle().fill(p.primary.opacity(0.19)))
                    .contentShape(Circle())
                }
                .buttonStyle(PressableStyle())
                .help(rec.state == .paused ? L("Resume") : L("Pause"))
                .padding(.trailing, m.u(3))
                Button { rec.stop() } label: {
                    RoundedRectangle(cornerRadius: m.u(2), style: .continuous)
                        .fill(Color.white)
                        .frame(width: m.u(10), height: m.u(10))
                        .offset(y: m.u(0.5))
                        .frame(width: m.u(32), height: m.u(32))
                        .background(Circle().fill(LinearGradient(stops: [.init(color: redLight, location: 0), .init(color: red, location: 0.66)],
                                                                 startPoint: .top, endPoint: .bottom)))
                        .contentShape(Circle())
                }
                .buttonStyle(PressableStyle())
                .help(L("Stop and save"))
            }
            .offset(y: m.u(0.5))
        }
    }
}

/// Mirrored level bars, newest on the right (always left-to-right).
struct UtilWaveform: View {
    var levels: [Float]
    var color: Color
    /// Optional lighter colour at the top (the reference bars brighten upwards).
    var topColor: Color? = nil

    var body: some View {
        Canvas { ctx, size in
            let n = levels.count
            guard n > 0 else { return }
            let step = size.width / CGFloat(n)
            let bar = max(1, step * 0.667)
            let shading: GraphicsContext.Shading = topColor.map {
                .linearGradient(Gradient(stops: [.init(color: $0, location: 0), .init(color: color, location: 0.7)]),
                                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height))
            } ?? .color(color)
            var bars = Path()
            for (i, v) in levels.enumerated() {
                let h = max(bar, size.height * CGFloat(0.12 + 0.88 * Double(v)))
                let rect = CGRect(x: CGFloat(i) * step + (step - bar) / 2, y: (size.height - h) / 2, width: bar, height: h)
                bars.addPath(Path(roundedRect: rect, cornerRadius: bar / 2))
            }
            ctx.fill(bars, with: shading)
        }
        .environment(\.layoutDirection, .leftToRight)
    }
}

// MARK: - Panel

@MainActor
enum UtilVoiceMemoPanel {
    static func toggle(_ w: WidgetInstance) {
        Panels.shared.toggle(w.id) { UtilVoiceMemoPanelView() }
    }
}

private struct UtilVoiceMemoPanelView: View {
    @Environment(\.palette) private var p
    private var rec: UtilVoiceRecorder { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(title: L("Voice Memos"), subtitle: L("%@ recordings", Fmt.int(rec.recordings.count))) {
                HStack(spacing: 10) {
                    Button { Open.path(UtilVoiceRecorder.directory.path) } label: {
                        Image(systemName: "folder").font(.system(size: 13, weight: .semibold)).foregroundStyle(p.secondary)
                    }
                    .help(L("Show in Finder"))
                    Button {
                        Panels.shared.close()
                        rec.start()
                    } label: {
                        Image(systemName: "record.circle").font(.system(size: 15, weight: .semibold)).foregroundStyle(p.accent(.cdRed))
                    }
                    .help(L("Record"))
                    .disabled(rec.isActive)
                }
                .buttonStyle(.plain)
            }
            if rec.recordings.isEmpty {
                Text(L("Click the microphone to record your first memo."))
                    .font(.dock(12, .medium)).foregroundStyle(p.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(rec.recordings) { row($0) }
                    }
                }
                .frame(height: min(CGFloat(rec.recordings.count) * 42, 336))
            }
        }
        .frame(width: 300)
        .task { await rec.reload() }
    }

    private func row(_ r: UtilVoiceRecorder.Recording) -> some View {
        let isPlaying = rec.playing == r.url
        return HStack(spacing: 10) {
            Button { rec.play(r) } label: {
                Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(isPlaying ? p.primary : p.accent(.cdRed))
                    .flipsForRTL()
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(isPlaying ? p.accent(.cdRed) : p.control))
            }
            .buttonStyle(PressableStyle())
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: Fmt.date(r.date, "MMMdjmm")).font(.dock(12, .semibold)).foregroundStyle(p.primary).lineLimit(1)
                Text(verbatim: Fmt.duration(r.duration)).font(.dock(10.5, .medium, mono: true)).foregroundStyle(p.secondary)
            }
            Spacer(minLength: 6)
            Button { Open.reveal(r.url.path) } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(p.secondary).frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help(L("Show in Finder"))
            Button { rec.delete(r) } label: {
                Image(systemName: "trash").font(.system(size: 11, weight: .semibold)).foregroundStyle(p.secondary).frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help(L("Move to Trash"))
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .onDrag { NSItemProvider(contentsOf: r.url) ?? NSItemProvider() }
    }
}
