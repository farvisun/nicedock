import AppKit

/// Deterministic content for `--render … --scene reference`.
///
/// Each widget family seeds the same data the frames in `docs/reference` show (time, prices, track, …),
/// so renders can be pixel-diffed against them with `scripts/pixel-diff.sh`. Nothing here runs in the
/// normal app: `isActive` is only true for that render flag.
enum ReferenceScene {
    nonisolated static let isActive: Bool = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--scene"), args.count > i + 1 else { return false }
        return args[i + 1] == "reference"
    }()

    /// 18 June 2026, 12:34 local time: the moment most reference frames were captured at.
    nonisolated static let defaultNow: Date = {
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute, c.second) = (2026, 6, 18, 12, 34, 0)
        return Calendar(identifier: .gregorian).date(from: c) ?? Date()
    }()

    /// Frozen clock for the widget being rendered. Families may move it in `prepare`.
    nonisolated(unsafe) static var now: Date = defaultNow
    /// Optional state suffix from the frame name, e.g. `voiceMemo-recording` → "recording".
    nonisolated(unsafe) static var variant: String?

    /// Content assets the reference frames were made with (album art, avatars, app icons), kept in the
    /// source checkout at `docs/reference/assets`; the harness runs from `build/NiceDock.app`.
    nonisolated static var assetsURL: URL {
        Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/reference/assets")
    }

    nonisolated static func asset(_ name: String) -> NSImage? {
        NSImage(contentsOf: assetsURL.appendingPathComponent(name))
    }

    /// The frozen clock inside the scene, `live` everywhere else.
    @inline(__always) nonisolated static func date(_ live: Date = Date()) -> Date { isActive ? now : live }

    /// Resets the clock and lets the owning family seed data for `kind`.
    /// Returns config overrides for the rendered instance (empty when the family has none).
    @MainActor static func prepare(_ kind: WidgetKind, variant: String?) -> [String: String] {
        now = defaultNow
        self.variant = variant
        for family in families {
            if let config = family(kind, variant) { return config }
        }
        return [:]
    }

    @MainActor private static let families: [(WidgetKind, String?) -> [String: String]?] = [
        AppsScene.prepare, ClockScene.prepare, CalendarScene.prepare, WeatherScene.prepare, SystemScene.prepare,
        UtilityScene.prepare, MediaScene.prepare, FinanceScene.prepare, ConnectedScene.prepare
    ]
}
