import CoreAudio
import CoreGraphics
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
            // -panel: the popover with its App Volume section (panels render without blur offscreen).
            if variant == "panel" {
                AppStore.shared.settings.reduceTransparency = true
                seedAppVolume(nil)
            }
            return [:]
        case .appVolume:
            // Tile: Music, Safari, Zoom (muted). Variants: -panel, -denied, -empty, -panel-denied.
            if variant?.hasPrefix("panel") == true { AppStore.shared.settings.reduceTransparency = true }
            seedAppVolume(variant)
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
        case .windowManager:
            // Accessibility granted (variant -locked: not yet); -panel shows the window list with Safari's front window
            // selected; -panel-locked is the list without Accessibility or Screen Recording (CGWindowList gives no titles).
            let panel = variant?.hasPrefix("panel") == true
            let locked = variant == "locked" || variant == "panel-locked"
            if panel { AppStore.shared.settings.reduceTransparency = true }
            UtilWindowService.shared.seedReference(trusted: !locked, groups: panel ? sceneWindows(titles: !locked) : [], focused: locked ? nil : 1)
            return [:]
        case .emoji, .colorPicker, .screenshots, .recentScreenshots, .searchWeb:
            return [:]
        default:
            return nil
        }
    }

    /// App Volume scene apps (content, not UI copy). Zoom isn't installed on most Macs: it uses the drawn stand-in icon.
    @MainActor private static func seedAppVolume(_ variant: String?) {
        func app(_ id: String, _ name: String, _ path: String?, _ object: AudioObjectID) -> UtilAudioApp {
            UtilAudioApp(id: id, name: name, iconPath: path, processes: [object], pids: [pid_t(object)], running: true)
        }
        let apps = variant?.hasSuffix("empty") == true ? [] : [
            app("com.apple.Music", "Music", "/System/Applications/Music.app", 201),
            app("com.apple.Safari", "Safari", "/Applications/Safari.app", 202),
            app("us.zoom.xos", "Zoom", nil, 203)
        ]
        UtilAppVolumeService.shared.seedReference(apps: apps, levels: [
            "com.apple.Music": UtilAppVolumeLevel(volume: 0.72, muted: false),
            "com.apple.Safari": UtilAppVolumeLevel(volume: 0.35, muted: false),
            "us.zoom.xos": UtilAppVolumeLevel(volume: 0.8, muted: true)
        ], denied: variant?.hasSuffix("denied") == true)
    }

    /// Scene windows (content, not UI copy: built positionally so the l10n extractor skips them).
    private static func sceneWindows(titles: Bool) -> [UtilWinGroup] {
        let fa = Localizer.language == .fa
        func win(_ id: CGWindowID, _ pid: pid_t, _ app: String, _ path: String, _ name: String?, minimized: Bool = false) -> UtilWinEntry {
            UtilWinEntry(id: id, pid: pid, appName: app, appPath: path, title: titles ? name : nil,
                         frame: CGRect(x: 0, y: 25, width: 900, height: 600), minimized: minimized)
        }
        // Minimized windows only show up through Accessibility.
        return UtilWinList.group([
            win(1, 101, "Safari", "/Applications/Safari.app", fa ? "ویکی‌پدیا، دانشنامهٔ آزاد" : "Apple (United States)"),
            win(2, 101, "Safari", "/Applications/Safari.app", "GitHub — farvisun/cooooldock"),
            win(3, 102, "Notes", "/System/Applications/Notes.app", fa ? "فهرست خرید" : "Groceries"),
            win(4, 103, "Terminal", "/System/Applications/Utilities/Terminal.app", "cooooldock — zsh — 120×40"),
            win(5, 104, "Finder", "/System/Library/CoreServices/Finder.app", fa ? "دانلودها" : "Downloads"),
            win(6, 104, "Finder", "/System/Library/CoreServices/Finder.app", fa ? "برنامه‌ها" : "Applications", minimized: true),
            win(7, 105, "Music", "/System/Applications/Music.app", nil)
        ].filter { titles || !$0.minimized })
    }
}
