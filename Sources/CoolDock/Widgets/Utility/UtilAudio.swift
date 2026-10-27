import AppKit
import AudioToolbox
import CoreAudio
import Observation
import SwiftUI

// MARK: - CoreAudio helpers

/// Thin, failure-tolerant wrappers over the CoreAudio HAL property API.
enum UtilCA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func has(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var a = address
        return AudioObjectHasProperty(object, &a)
    }

    static func settable(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var a = address
        var flag: DarwinBoolean = false
        return AudioObjectHasProperty(object, &a) && AudioObjectIsPropertySettable(object, &a, &flag) == noErr && flag.boolValue
    }

    static func get<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ initial: T) -> T? {
        var a = address
        guard AudioObjectHasProperty(object, &a) else { return nil }
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0) }
        return status == noErr ? value : nil
    }

    @discardableResult
    static func set<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: T) -> Bool {
        guard settable(object, address) else { return false }
        var a = address
        var v = value
        let status = withUnsafeMutablePointer(to: &v) { AudioObjectSetPropertyData(object, &a, 0, nil, UInt32(MemoryLayout<T>.size), $0) }
        return status == noErr
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var a = address(selector)
        guard AudioObjectHasProperty(object, &a) else { return nil }
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &ref) { AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0) }
        guard status == noErr, let ref else { return nil }
        return ref.takeRetainedValue() as String
    }

    static func deviceIDs() -> [AudioDeviceID] {
        var a = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func hasOutput(_ id: AudioDeviceID) -> Bool {
        var a = address(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr && size > 0
    }

    static let volumeElements: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain, 1, 2]
}

struct UtilAudioDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
    let transport: UInt32

    var symbol: String {
        let n = name.lowercased()
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            if n.contains("headphone") { return "headphones" }
            if n.contains("macbook") { return "laptopcomputer" }
            if n.contains("imac") { return "desktopcomputer" }
            if n.contains("mac mini") || n.contains("mac studio") { return "macmini" }
            return "hifispeaker"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            if n.contains("airpods max") { return "airpodsmax" }
            if n.contains("airpods pro") { return "airpodspro" }
            if n.contains("airpods") { return "airpods" }
            if n.contains("beats") { return "beats.headphones" }
            if n.contains("homepod") { return "homepod" }
            if n.contains("speaker") || n.contains("boom") || n.contains("soundlink") { return "hifispeaker" }
            return "headphones"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return "tv"
        case kAudioDeviceTransportTypeAirPlay:
            return "airplayaudio"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate:
            return "waveform"
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeThunderbolt, kAudioDeviceTransportTypeFireWire:
            return n.contains("head") ? "headphones" : "hifispeaker"
        default:
            return "speaker.wave.2"
        }
    }

    /// Short label that fits inside a 46 pt button ("MacBook", "AirPods", "Display").
    var shortName: String {
        let n = name.lowercased()
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            if n.contains("headphone") { return L("Headphones") }
            if n.contains("macbook") { return "MacBook" }
            if n.contains("imac") { return "iMac" }
            return name.replacingOccurrences(of: " Speakers", with: "")
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return name.count <= 9 ? name : L("Display")
        default:
            if n.contains("airpods max") { return "AirPods Max" }
            if n.contains("airpods") { return "AirPods" }
            if name.count <= 10 { return name }
            let cleaned = name.replacingOccurrences(of: "’s ", with: "'s ")
            if let r = cleaned.range(of: "'s ") { return String(cleaned[r.upperBound...]) }
            return name
        }
    }

    /// Ordering for the quick buttons: built-in first, then headphones, displays, the rest.
    var rank: Int {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return 0
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return 1
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return 2
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeThunderbolt: return 3
        case kAudioDeviceTransportTypeAirPlay: return 4
        default: return 5
        }
    }
}

// MARK: - Service

/// Output devices, default output and volume, kept current through CoreAudio property listeners (no polling).
@Observable
@MainActor
final class UtilAudioService: DemandDriven {
    static let shared = UtilAudioService()

    private(set) var outputs: [UtilAudioDevice] = []
    private(set) var current: AudioDeviceID = 0
    private(set) var volume: Double = 0
    private(set) var muted = false
    private(set) var hasVolume = false

    var currentDevice: UtilAudioDevice? { outputs.first { $0.id == current } }

    @ObservationIgnored private var subscribers = Set<String>()
    @ObservationIgnored private var systemBlock: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var deviceBlock: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var deviceAddresses: [AudioObjectPropertyAddress] = []
    @ObservationIgnored private var listenedDevice: AudioDeviceID = 0

    private static let systemSelectors = [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices]

    func subscribe(_ id: String) {
        // Reference renders show seeded devices (`seedReference`), never the machine's own.
        guard !ReferenceScene.isActive else { return }
        subscribers.insert(id)
        if subscribers.count == 1 { start() }
    }

    /// Deterministic outputs for `--scene reference` renders. No effect outside the scene.
    func seedReference(_ devices: [UtilAudioDevice], current: AudioDeviceID, volume: Double) {
        guard ReferenceScene.isActive else { return }
        outputs = devices
        self.current = current
        self.volume = volume
        muted = false
        hasVolume = true
    }

    func unsubscribe(_ id: String) {
        subscribers.remove(id)
        if subscribers.isEmpty { stop() }
    }

    private func start() {
        reloadDevices()
        reloadDefault()
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            MainActor.assumeIsolated {
                UtilAudioService.shared.reloadDevices()
                UtilAudioService.shared.reloadDefault()
            }
        }
        systemBlock = block
        for selector in Self.systemSelectors {
            var a = UtilCA.address(selector)
            AudioObjectAddPropertyListenerBlock(UtilCA.system, &a, DispatchQueue.main, block)
        }
    }

    private func stop() {
        if let block = systemBlock {
            for selector in Self.systemSelectors {
                var a = UtilCA.address(selector)
                AudioObjectRemovePropertyListenerBlock(UtilCA.system, &a, DispatchQueue.main, block)
            }
        }
        systemBlock = nil
        removeDeviceListeners()
    }

    func reloadDevices() {
        let list = UtilCA.deviceIDs().compactMap { id -> UtilAudioDevice? in
            guard UtilCA.hasOutput(id) else { return nil }
            if let hidden = UtilCA.get(id, UtilCA.address(kAudioDevicePropertyIsHidden), UInt32(0)), hidden != 0 { return nil }
            let name = UtilCA.string(id, kAudioObjectPropertyName) ?? L("Output")
            if name.hasPrefix("CADefaultDeviceAggregate") { return nil }
            if UtilCA.string(id, kAudioDevicePropertyDeviceUID)?.hasPrefix(UtilAppVolumeAggregate.uidPrefix) == true { return nil }
            let transport = UtilCA.get(id, UtilCA.address(kAudioDevicePropertyTransportType), UInt32(0)) ?? 0
            return UtilAudioDevice(id: id, name: name, transport: transport)
        }
        .sorted { ($0.rank, $0.name) < ($1.rank, $1.name) }
        if list != outputs { outputs = list }
    }

    func reloadDefault() {
        let id = UtilCA.get(UtilCA.system, UtilCA.address(kAudioHardwarePropertyDefaultOutputDevice), AudioDeviceID(0)) ?? 0
        if id != current { current = id }
        if id != listenedDevice { installDeviceListeners(id) }
        readVolume()
    }

    func readVolume() {
        let dev = current
        guard dev != 0 else { hasVolume = false; return }
        var values: [Float32] = []
        if let v = UtilCA.get(dev, UtilCA.address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput), Float32(0)) {
            values = [v]
        } else {
            for ch: AudioObjectPropertyElement in [1, 2] {
                if let v = UtilCA.get(dev, UtilCA.address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, ch), Float32(0)) { values.append(v) }
            }
        }
        hasVolume = !values.isEmpty
        let v = values.isEmpty ? 1 : Double(values.reduce(0, +)) / Double(values.count)
        if abs(v - volume) > 0.001 { volume = v }
        let m = (UtilCA.get(dev, UtilCA.address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput), UInt32(0)) ?? 0) != 0
        if m != muted { muted = m }
    }

    func setVolume(_ value: Double) {
        let dev = current
        guard dev != 0 else { return }
        let v = Float32(max(0, min(1, value)))
        volume = Double(v)
        if !UtilCA.set(dev, UtilCA.address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput), v) {
            for ch: AudioObjectPropertyElement in [1, 2] {
                UtilCA.set(dev, UtilCA.address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, ch), v)
            }
        }
        if muted && v > 0 { setMuted(false) }
    }

    func setMuted(_ on: Bool) {
        let dev = current
        guard dev != 0 else { return }
        if UtilCA.set(dev, UtilCA.address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput), UInt32(on ? 1 : 0)) {
            muted = on
        }
    }

    func toggleMute() { setMuted(!muted) }

    func select(_ id: AudioDeviceID) {
        guard id != current else { return }
        if UtilCA.set(UtilCA.system, UtilCA.address(kAudioHardwarePropertyDefaultOutputDevice), id) {
            reloadDefault()
        }
    }

    private func installDeviceListeners(_ dev: AudioDeviceID) {
        removeDeviceListeners()
        listenedDevice = dev
        guard dev != 0 else { return }
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            MainActor.assumeIsolated { UtilAudioService.shared.readVolume() }
        }
        var addrs = UtilCA.volumeElements
            .map { UtilCA.address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, $0) }
            .filter { UtilCA.has(dev, $0) }
        let mute = UtilCA.address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        if UtilCA.has(dev, mute) { addrs.append(mute) }
        for addr in addrs {
            var a = addr
            AudioObjectAddPropertyListenerBlock(dev, &a, DispatchQueue.main, block)
        }
        deviceBlock = block
        deviceAddresses = addrs
    }

    private func removeDeviceListeners() {
        if let block = deviceBlock, listenedDevice != 0 {
            for addr in deviceAddresses {
                var a = addr
                AudioObjectRemovePropertyListenerBlock(listenedDevice, &a, DispatchQueue.main, block)
            }
        }
        deviceBlock = nil
        deviceAddresses = []
        listenedDevice = 0
    }
}

// MARK: - Views

struct UtilAudioView: View {
    let w: WidgetInstance
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    private var audio: UtilAudioService { .shared }

    var body: some View {
        if UtilAudioPanel.sceneVariant {
            PanelChrome { UtilAudioPanelView() }
        } else {
            tile
        }
    }

    private var tile: some View {
        let others = Array(audio.outputs.filter { $0.id != audio.current && $0.rank < 5 }.prefix(2))
        return Tile(width: w.kind.spec.width, padding: EdgeInsets(top: 5.5, leading: 6, bottom: 6.5, trailing: 6)) {
            if let device = audio.currentDevice {
                HStack(spacing: m.u(6)) {
                    mainPanel(device)
                    ForEach(others) { d in
                        UtilOutputButton(device: d) { audio.select(d.id) }
                    }
                }
            } else {
                TileMessage(symbol: "speaker.slash", text: L("No output device"), tint: .cdGray)
            }
        }
        .demand(UtilAudioService.shared)
    }

    private func mainPanel(_ device: UtilAudioDevice) -> some View {
        let shape = RoundedRectangle(cornerRadius: m.u(8), style: .continuous)
        return VStack(alignment: .leading, spacing: m.u(3.5)) {
            Button { UtilAudioPanel.toggle(w) } label: {
                HStack(spacing: m.u(7)) {
                    Image(systemName: device.symbol)
                        .font(.system(size: m.u(9), weight: .medium))
                        .foregroundStyle(p.secondary)
                        .frame(width: m.u(13))
                    Text(verbatim: device.shortName).dock(9, .bold, design: .default)
                        .truncationMode(.tail)
                        .offset(x: m.u(-0.5))
                    Spacer(minLength: 0)
                }
                .frame(height: m.u(14))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(device.name)
            HStack(spacing: m.u(4)) {
                Button { audio.toggleMute() } label: {
                    Image(systemName: speakerSymbol)
                        .font(.system(size: m.u(10.25), weight: .medium))
                        .foregroundStyle(audio.muted ? p.secondary : p.primary)
                        .padding(.leading, m.u(-1.5))
                        .frame(width: m.u(13), height: m.u(12), alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .help(audio.muted ? L("Unmute") : L("Mute"))
                UtilVolumeSlider(value: audio.muted ? 0 : audio.volume, enabled: audio.hasVolume) { audio.setVolume($0) }
                Text(verbatim: Fmt.percent(audio.muted ? 0 : audio.volume))
                    .dock(8, .semibold, p.secondary, mono: true)
                    .padding(.trailing, m.u(-1))
                    .frame(minWidth: m.u(20.5), alignment: .trailing)
            }
            .frame(height: m.u(12))
        }
        .offset(y: m.u(-1.75))
        .padding(.horizontal, m.u(6))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(shape.fill(p.primary.opacity(0.045)))
        .overlay(shape.strokeBorder(p.primary.opacity(0.075), lineWidth: 0.5))
    }

    private var speakerSymbol: String {
        if audio.muted || audio.volume <= 0.001 { return "speaker.slash.fill" }
        if audio.volume < 0.34 { return "speaker.wave.1.fill" }
        if audio.volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}

private struct UtilOutputButton: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    var device: UtilAudioDevice
    var action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: m.u(8), style: .continuous)
        Button(action: action) {
            VStack(spacing: m.u(2.5)) {
                Image(systemName: device.symbol)
                    .font(.system(size: m.u(14), weight: .semibold))
                    .foregroundStyle(p.secondary)
                    .frame(height: m.u(17))
                    .offset(y: m.u(-0.5))
                    // An identity transform keeps the centred glyph at its fractional position (no pixel snapping),
                    // as in the reference frame.
                    .transformEffect(.identity)
                Text(verbatim: device.shortName).dock(8, .semibold, p.secondary, design: .default)
                    .minimumScaleFactor(0.75)
                    .padding(.horizontal, m.u(2))
            }
            .frame(width: m.u(46))
            .frame(maxHeight: .infinity)
            .background(shape.fill(p.primary.opacity(0.045)))
            .overlay(shape.strokeBorder(p.primary.opacity(0.075), lineWidth: 0.5))
            .contentShape(shape)
        }
        .buttonStyle(PressableStyle())
        .help(device.name)
    }
}

/// Capsule volume slider. Drawn left-to-right and mirrored as a whole in RTL, so it fills from the
/// leading edge in both directions (drag locations stay in the unmirrored local space).
struct UtilVolumeSlider: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    var value: Double
    var enabled = true
    var thickness: CGFloat = 11
    var onChange: (Double) -> Void

    var body: some View {
        GeometryReader { g in
            let width = g.size.width, height = g.size.height
            let knob = height
            let x = knob / 2 + (width - knob) * max(0, min(1, value))
            ZStack(alignment: .leading) {
                Capsule().fill(p.primary.opacity(0.09))
                Capsule().fill(p.primary.opacity(0.84)).frame(width: max(knob, x))
                Circle()
                    .fill(p.isLight ? p.primary : Color.white.opacity(0.96))
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                    .offset(x: x - knob / 2)
            }
            .frame(height: height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                guard enabled, width > knob else { return }
                onChange(Double((v.location.x - knob / 2) / (width - knob)))
            })
        }
        .frame(height: m.u(thickness))
        .opacity(enabled ? 1 : 0.4)
        .environment(\.layoutDirection, .leftToRight)
        .flipsForRTL()
    }
}

@MainActor
enum UtilAudioPanel {
    static func toggle(_ w: WidgetInstance) {
        Panels.shared.toggle(w.id) { UtilAudioPanelView() }
    }

    /// `--scene reference` frame `audioControls-panel` draws the panel (with its App Volume section) instead of the tile.
    nonisolated static var sceneVariant: Bool { ReferenceScene.isActive && ReferenceScene.variant == "panel" }
}

private struct UtilAudioPanelView: View {
    @Environment(\.palette) private var p
    private var audio: UtilAudioService { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(title: L("Sound Output")) {
                Button { Open.url("x-apple.systempreferences:com.apple.Sound-Settings.extension") } label: {
                    Image(systemName: "gearshape").font(.system(size: 13, weight: .semibold)).foregroundStyle(p.secondary)
                }
                .buttonStyle(.plain)
                .help(L("Sound Settings…"))
            }
            HStack(spacing: 8) {
                Image(systemName: "speaker.fill").font(.system(size: 11)).foregroundStyle(p.secondary)
                UtilVolumeSlider(value: audio.muted ? 0 : audio.volume, enabled: audio.hasVolume) { audio.setVolume($0) }
                Image(systemName: "speaker.wave.3.fill").font(.system(size: 11)).foregroundStyle(p.secondary)
            }
            VStack(spacing: 2) {
                ForEach(audio.outputs) { d in
                    Button { audio.select(d.id) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: d.symbol)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(d.id == audio.current ? p.primary : p.secondary)
                                .frame(width: 26, height: 26)
                                .background(Circle().fill(d.id == audio.current ? p.accent(.cdBlue) : p.control))
                            Text(verbatim: d.name).font(.dock(12.5, .medium)).foregroundStyle(p.primary).lineLimit(1)
                            Spacer(minLength: 8)
                            if d.id == audio.current {
                                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(p.accent(.cdBlue))
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if UtilAppVolumeService.supported { UtilAppVolumeSection(showsTitle: true) }
        }
        .frame(width: 280)
        .demand(UtilAudioService.shared)
    }
}
