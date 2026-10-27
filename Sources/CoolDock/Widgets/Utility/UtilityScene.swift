import CoreAudio
import Foundation

/// Reference-scene data for this family (see `ReferenceScene`). Returns nil for kinds it doesn't own.
enum UtilityScene {
    @MainActor static func prepare(_ kind: WidgetKind, _ variant: String?) -> [String: String]? {
        switch kind {
        case .audioControls:
            // MacBook speakers at 58 %, AirPods Pro and an external display as the other outputs.
            UtilAudioService.shared.seedReference([
                UtilAudioDevice(id: 1, name: "MacBook Pro Speakers", transport: kAudioDeviceTransportTypeBuiltIn),
                UtilAudioDevice(id: 2, name: "AirPods Pro", transport: kAudioDeviceTransportTypeBluetooth),
                UtilAudioDevice(id: 3, name: "Studio Display", transport: kAudioDeviceTransportTypeDisplayPort)
            ], current: 1, volume: 0.58)
            return [:]
        case .quickToggles:
            UtilToggleService.shared.seedReference(wifi: true, bluetooth: true, darkMode: false, keepAwake: true)
            return [:]
        case .converter:
            // 500 USD → 436,03 EUR.
            UtilFX.seedReference("USD", "EUR", rate: 0.87206)
            return ["amount": "500", "from": "USD", "to": "EUR"]
        case .voiceMemo:
            // Waveform heights (pt) of the reference frame on a 17 pt canvas.
            let heights: [Double] = [3, 6, 9, 14, 12, 8, 16, 10, 6, 4, 9, 13, 17, 12, 8, 5]
            let levels = heights.map { Float(max(0, ($0 / 17 - 0.12) / 0.88)) }
            UtilVoiceRecorder.shared.seedReference(recording: variant == "recording", elapsed: 14, levels: levels)
            return [:]
        case .emoji, .colorPicker, .screenshots, .recentScreenshots, .searchWeb:
            return [:]
        default:
            return nil
        }
    }
}
