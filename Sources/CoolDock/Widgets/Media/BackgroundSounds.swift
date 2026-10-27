import AVFoundation
import Observation
import SwiftUI

// MARK: - Sounds

enum MediaNoise: String, CaseIterable, Identifiable {
    case rain, ocean, brown, pink, white
    var id: String { rawValue }

    var title: String {
        switch self {
        case .rain: return L("Rain")
        case .ocean: return L("Ocean")
        case .brown: return L("Brown Noise")
        case .pink: return L("Pink Noise")
        case .white: return L("White Noise")
        }
    }

    var shortTitle: String {
        switch self {
        case .rain: return L("Rain")
        case .ocean: return L("Ocean")
        case .brown: return L("Brown")
        case .pink: return L("Pink")
        case .white: return L("White")
        }
    }

    var symbol: String {
        switch self {
        case .rain: return "cloud.rain.fill"
        case .ocean: return "water.waves"
        case .brown: return "waveform.path"
        case .pink: return "waveform"
        case .white: return "aqi.medium"
        }
    }

    fileprivate var code: Int32 {
        switch self {
        case .white: return 0
        case .pink: return 1
        case .brown: return 2
        case .rain: return 3
        case .ocean: return 4
        }
    }
}

// MARK: - Engine

/// Procedural noise player. The audio engine only exists while a sound is playing (or fading out).
@Observable
@MainActor
final class MediaSoundEngine {
    static let shared = MediaSoundEngine()

    private(set) var isPlaying = false
    private(set) var sound: MediaNoise = .rain
    private(set) var volume: Double = 0.6

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private let generator = MediaNoiseGenerator()
    @ObservationIgnored private var teardownTask: Task<Void, Never>?
    @ObservationIgnored private var configObserver: NSObjectProtocol?

    /// The audio engine exists (playing, or fading out for 1.2 s after Stop).
    var isEngineRunning: Bool { engine != nil }

    func play(_ s: MediaNoise, volume v: Double) {
        teardownTask?.cancel()
        teardownTask = nil
        sound = s
        setVolume(v)
        generator.requestedKind = s.code
        generator.target = 1
        if engine == nil && !startEngine() { return }
        isPlaying = true
    }

    func stop() {
        guard isPlaying else { return }
        isPlaying = false
        generator.target = 0
        teardownTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled, let self, !self.isPlaying else { return }
            self.stopEngine()
        }
    }

    func setVolume(_ v: Double) {
        volume = max(0, min(1, v))
        generator.volume = Float(volume * volume) // perceptual curve
    }

    private func startEngine() -> Bool {
        let e = AVAudioEngine()
        let hw = e.outputNode.outputFormat(forBus: 0)
        let rate = hw.sampleRate > 0 ? hw.sampleRate : 48_000
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { return false }
        generator.prepare(sampleRate: Float(rate))
        let source = Self.makeSource(format: format, generator: generator)
        e.attach(source)
        e.connect(source, to: e.mainMixerNode, format: format)
        e.prepare()
        do {
            try e.start()
        } catch {
            NSLog("NiceDock sounds: \(error)")
            return false
        }
        engine = e
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: e, queue: .main) { _ in
            MainActor.assumeIsolated { MediaSoundEngine.shared.restartAfterDeviceChange() }
        }
        return true
    }

    /// Built outside the main actor so the render block is not actor-isolated (it runs on the audio thread).
    private nonisolated static func makeSource(format: AVAudioFormat, generator gen: MediaNoiseGenerator) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { _, _, frameCount, bufferList in
            gen.render(frames: Int(frameCount), buffers: UnsafeMutableAudioBufferListPointer(bufferList))
            return noErr
        }
    }

    private func stopEngine() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine?.stop()
        engine = nil
        generator.reset()
    }

    /// Output device changed (headphones, AirPlay): rebuild at the new sample rate.
    private func restartAfterDeviceChange() {
        let wasPlaying = isPlaying
        stopEngine()
        if wasPlaying {
            generator.target = 1
            if !startEngine() { isPlaying = false }
        }
    }
}

/// Render-thread noise synthesis. Parameters are single words written from the main thread.
private final class MediaNoiseGenerator: @unchecked Sendable {
    var requestedKind: Int32 = 3
    var target: Float = 0
    var volume: Float = 0.36

    private struct Channel {
        var b0: Float = 0, b1: Float = 0, b2: Float = 0, b3: Float = 0, b4: Float = 0, b5: Float = 0, b6: Float = 0
        var brown: Float = 0
        // band-pass biquad state (rain)
        var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
        // droplet resonator
        var dropAmp: Float = 0, dropDecay: Float = 0, dropPhase: Float = 0, dropStep: Float = 0
        // low-pass for ocean wash
        var lp: Float = 0
    }

    private var left = Channel()
    private var right = Channel()
    private var kind: Int32 = 3
    private var gain: Float = 0
    private var level: Float = 0
    private var rate: Float = 48_000
    private var fadeCoef: Float = 0.0001
    private var levelCoef: Float = 0.001
    private var seed: UInt32 = 0x9E37_79B9
    private var lfoPhase: Double = 0
    private var lfoStep: Double = 0
    // band-pass coefficients
    private var bb0: Float = 0, bb2: Float = 0, ba1: Float = 0, ba2: Float = 0

    func prepare(sampleRate: Float) {
        rate = sampleRate
        fadeCoef = 1 - expf(-1 / (0.28 * sampleRate))   // ~1 s fade in/out
        levelCoef = 1 - expf(-1 / (0.05 * sampleRate))
        lfoStep = 1 / (9.5 * Double(sampleRate))         // ~9.5 s wave period
        // RBJ band-pass (constant 0 dB peak), centre 2.2 kHz, Q 0.7
        let w0 = 2 * Float.pi * 2200 / sampleRate
        let alpha = sinf(w0) / (2 * 0.7)
        let a0 = 1 + alpha
        bb0 = alpha / a0
        bb2 = -alpha / a0
        ba1 = -2 * cosf(w0) / a0
        ba2 = (1 - alpha) / a0
    }

    func reset() {
        left = Channel(); right = Channel(); gain = 0
    }

    @inline(__always) private func white() -> Float {
        seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
        return Float(seed) / Float(UInt32.max) * 2 - 1
    }

    @inline(__always) private func unit() -> Float { (white() + 1) * 0.5 }

    func render(frames: Int, buffers: UnsafeMutableAudioBufferListPointer) {
        guard buffers.count > 0, let l = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return }
        let r = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil
        let wanted = requestedKind
        let goal = target
        let vol = volume
        for i in 0..<frames {
            // Switching sounds dips to silence first, then swaps generators.
            let effectiveGoal: Float = wanted != kind ? 0 : goal
            gain += (effectiveGoal - gain) * fadeCoef
            if wanted != kind && gain < 0.002 { kind = wanted; left = Channel(); right = Channel() }
            level += (vol - level) * levelCoef
            lfoPhase += lfoStep
            if lfoPhase >= 1 { lfoPhase -= 1 }
            let a = sample(&left, lfoOffset: 0)
            let b = sample(&right, lfoOffset: 0.07)
            let g = gain * level
            l[i] = a * g
            r?[i] = b * g
        }
    }

    @inline(__always) private func sample(_ c: inout Channel, lfoOffset: Double) -> Float {
        let w = white()
        switch kind {
        case 0: // white
            return w * 0.22
        case 1: // pink (Paul Kellet, refined)
            return pink(&c, w) * 0.12
        case 2: // brown
            c.brown = (c.brown + 0.02 * w) / 1.02
            return c.brown * 3.2
        case 3: // rain: band-passed hiss + droplets + soft rumble
            let y = bb0 * w + bb2 * c.x2 - ba1 * c.y1 - ba2 * c.y2
            c.x2 = c.x1; c.x1 = w; c.y2 = c.y1; c.y1 = y
            c.brown = (c.brown + 0.02 * w) / 1.02
            if c.dropAmp < 0.001, unit() < 22 / rate {
                c.dropAmp = 0.12 + 0.35 * unit()
                c.dropDecay = expf(-1 / ((0.003 + 0.01 * unit()) * rate))
                c.dropStep = 2 * Float.pi * (1800 + 3800 * unit()) / rate
                c.dropPhase = 0
            }
            var drop: Float = 0
            if c.dropAmp >= 0.001 {
                drop = c.dropAmp * sinf(c.dropPhase)
                c.dropPhase += c.dropStep
                if c.dropPhase > 2 * Float.pi { c.dropPhase -= 2 * Float.pi }
                c.dropAmp *= c.dropDecay
            }
            return y * 0.5 + drop * 0.5 + c.brown * 0.9
        default: // ocean: brown noise swelling with a slow LFO, plus a hiss on the crest
            c.brown = (c.brown + 0.02 * w) / 1.02
            var ph = lfoPhase + lfoOffset
            if ph >= 1 { ph -= 1 }
            let swell = Float(0.5 - 0.5 * cos(2 * Double.pi * ph))
            let env = 0.18 + 0.82 * swell * swell
            c.lp += (w - c.lp) * 0.08
            return c.brown * 3.4 * env + c.lp * 0.35 * swell * swell * swell
        }
    }

    @inline(__always) private func pink(_ c: inout Channel, _ w: Float) -> Float {
        c.b0 = 0.99886 * c.b0 + w * 0.0555179
        c.b1 = 0.99332 * c.b1 + w * 0.0750759
        c.b2 = 0.96900 * c.b2 + w * 0.1538520
        c.b3 = 0.86650 * c.b3 + w * 0.3104856
        c.b4 = 0.55000 * c.b4 + w * 0.5329522
        c.b5 = -0.7616 * c.b5 - w * 0.0168980
        let out = c.b0 + c.b1 + c.b2 + c.b3 + c.b4 + c.b5 + c.b6 + w * 0.5362
        c.b6 = w * 0.115926
        return out
    }
}

// MARK: - Tile (64 pt)

struct MediaSoundsTile: View {
    let w: WidgetInstance
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p

    var body: some View {
        let playing = MediaSoundEngine.shared.isPlaying
        Tile(width: w.kind.spec.width) {
            MediaSoundBars(animating: playing, color: playing ? p.accent(.cdTeal) : p.primary.opacity(0.885))
                .offset(y: m.u(-0.75))
        }
        .gesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in Self.openPanel(w) }
            .exclusively(before: TapGesture().onEnded { Self.toggle(w) }))
        .help(playing ? MediaSoundEngine.shared.sound.title : w.kind.spec.localizedTitle)
        .accessibilityPress { Self.toggle(w) }
        .accessibilityLabel(w.kind.spec.localizedTitle)
        .accessibilityValue(playing ? MediaSoundEngine.shared.sound.title : L("Off"))
        .accessibilityAction(named: L("Background Sounds")) { Self.openPanel(w) }
    }

    static func sound(_ w: WidgetInstance) -> MediaNoise { MediaNoise(rawValue: w.string("sound")) ?? .rain }
    static func volume(_ w: WidgetInstance) -> Double { w.double("volume", 0.6) }

    @MainActor static func toggle(_ w: WidgetInstance) {
        let engine = MediaSoundEngine.shared
        if engine.isPlaying { engine.stop() } else { engine.play(sound(w), volume: volume(w)) }
    }

    @MainActor static func select(_ s: MediaNoise, for w: WidgetInstance) {
        AppStore.shared.updateWidget(w.id) { $0.config["sound"] = s.rawValue }
        MediaSoundEngine.shared.play(s, volume: volume(w))
    }

    @MainActor static func openPanel(_ w: WidgetInstance) {
        Panels.shared.toggle(w.id) { MediaSoundsPanel(w: w, selected: sound(w), volume: volume(w)) }
    }
}

/// Five rounded bars (reference glyph); breathes gently only while playing.
private struct MediaSoundBars: View {
    @Environment(\.metrics) private var m
    var animating: Bool
    var color: Color
    private static let heights: [CGFloat] = [12, 16, 12, 8, 15]
    private static let speeds: [Double] = [5.1, 3.7, 6.3, 4.4, 5.6]

    var body: some View {
        if animating {
            TimelineView(.animation(minimumInterval: 0.12)) { ctx in
                bars(ctx.date.timeIntervalSinceReferenceDate)
            }
        } else {
            bars(nil)
        }
    }

    private func bars(_ t: Double?) -> some View {
        HStack(spacing: m.u(2)) {
            ForEach(0..<5, id: \.self) { i in
                let base = Self.heights[i]
                let h = t.map { base * (0.62 + 0.38 * (0.5 + 0.5 * sin($0 * Self.speeds[i] + Double(i) * 1.7))) } ?? base
                Capsule().fill(color).frame(width: m.u(3), height: m.u(h))
            }
        }
        .frame(height: m.u(16))
    }
}

// MARK: - Panel

private struct MediaSoundsPanel: View {
    let w: WidgetInstance
    @State var selected: MediaNoise
    @State var volume: Double
    @Environment(\.palette) private var p

    var body: some View {
        let engine = MediaSoundEngine.shared
        VStack(alignment: .leading, spacing: 14) {
            PanelHeader(title: L("Background Sounds"), subtitle: engine.isPlaying ? engine.sound.title : L("Off")) {
                CircleButton(symbol: engine.isPlaying ? "stop.fill" : "play.fill", size: 30) {
                    if engine.isPlaying { engine.stop() } else { engine.play(selected, volume: volume) }
                }
            }
            HStack(spacing: 8) {
                ForEach(MediaNoise.allCases) { s in
                    TileIconButton(symbol: s.symbol, label: s.shortTitle, tint: s == selected ? .cdTeal : nil,
                                   selected: s == selected && engine.isPlaying, size: CGSize(width: 54, height: 50)) {
                        selected = s
                        MediaSoundsTile.select(s, for: w)
                    }
                }
            }
            HStack(spacing: 10) {
                Image(systemName: "speaker.fill").foregroundStyle(p.secondary)
                Slider(value: $volume, in: 0...1) { editing in
                    if !editing {
                        let v = volume
                        AppStore.shared.updateWidget(w.id) { $0.config["volume"] = String(format: "%.2f", v) }
                    }
                }
                .controlSize(.small)
                .onChange(of: volume) { _, v in engine.setVolume(v) }
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(p.secondary)
            }
            .font(.system(size: 11, weight: .semibold))
        }
        .frame(width: 302)
    }
}
