import SwiftUI

/// Reference-scene data for this family (see `ReferenceScene`). Returns nil for kinds it doesn't own.
///
/// Tiles read the seeded snapshot through `snapshot(_:)` instead of `ConnMetricStore`, so the scene never
/// touches tokens, the Keychain or the network, and the live store is left alone.
enum ConnectedScene {
    private static let kinds: Set<WidgetKind> = [
        .polarRevenue, .stripeRevenue, .dodoRevenue, .shopifyChart, .shopifyToday, .shopifyOverview,
        .plausible, .simpleAnalytics, .dataFast, .visitorsChart, .dubStats, .resendStats, .githubContributions,
        .supabase, .socialX, .socialTikTok, .socialYouTube, .aiUsage
    ]

    /// Loaded data for the kind being rendered.
    nonisolated(unsafe) private static var seeded: [WidgetKind: ConnSnapshot] = [:]

    /// Number locale the reference frame was captured with. The site formats most figures with the
    /// browser locale ("1 284", "6 042 US$", "42,80 US$") but hard-codes US dollars for Polar and Dodo.
    nonisolated(unsafe) private(set) static var locale: Locale?

    @MainActor static func prepare(_ kind: WidgetKind, _ variant: String?) -> [String: String]? {
        guard kinds.contains(kind) else { return nil }
        let config: [String: String]
        switch kind {
        case .polarRevenue, .stripeRevenue, .dodoRevenue: config = ["range": "30d"]
        case .shopifyToday: config = ["range": "1d", "shop": "cooldock.myshopify.com"]
        case .shopifyChart, .shopifyOverview: config = ["range": "7d", "shop": "cooldock.myshopify.com"]
        case .plausible, .visitorsChart, .simpleAnalytics: config = ["range": "7d", "site": "cooldock.app"]
        case .dubStats: config = ["range": "7d"]
        case .githubContributions: config = ["user": "cooldock"]
        case .socialX: config = ["user": "cooldock"]
        case .socialYouTube: config = ["channel": "@cooldock"]
        // `aiUsage-<provider>` renders another source's tile with its sample shape (no reference frame).
        case .aiUsage: config = ["provider": variant.flatMap(ConnAIProvider.init(rawValue:))?.rawValue ?? "claudeCode", "range": "7d"]
        default: config = [:]
        }
        let usd = [.polarRevenue, .stripeRevenue, .dodoRevenue].contains(kind) || (kind == .aiUsage && variant != nil)
        locale = Locale(identifier: usd ? "en_US" : "sv_SE")
        seeded = [:]
        seeded[kind] = ConnSample.snapshot(WidgetInstance(kind: kind, config: config))
        return config
    }

    /// Seeded tile data while rendering the reference scene; always nil in the app.
    static func snapshot(_ w: WidgetInstance) -> ConnSnapshot? {
        guard ReferenceScene.isActive else { return nil }
        return seeded[w.kind]
    }

    /// Scene number locale, only while the app language is English (other languages keep their own).
    static var numberLocale: Locale? {
        guard ReferenceScene.isActive, Fmt.locale.language.languageCode == .english else { return nil }
        return locale
    }

    // MARK: - Per-frame alignment

    /// Parts of a tile that the reference frames place independently.
    enum Part { case value, caption, mark, chart, icon, rows }

    /// Sibling tiles on the site are not laid out identically: the same design sits up to 1 pt apart from
    /// one frame to the next (Plausible vs Simple Analytics, X vs YouTube…). Live tiles share one layout;
    /// in the scene each part is shifted by what was measured for that frame. Values are 2× pixels.
    private static let nudges: [WidgetKind: [Part: (Double, Double)]] = [
        .polarRevenue: [.value: (-2, 0), .caption: (-1, 0)],
        .dodoRevenue: [.value: (0, -1), .caption: (1, -1), .mark: (0, -1)],
        .simpleAnalytics: [.value: (-2, -2), .caption: (-2, -2), .mark: (0, -2)],
        .shopifyChart: [.caption: (1, 0), .mark: (0, 1)],
        .visitorsChart: [.value: (-2, -2), .caption: (-2, -2), .chart: (-2, -2), .mark: (0, -1)],
        .shopifyToday: [.icon: (0, 1)],
        .shopifyOverview: [.icon: (0, 1), .rows: (0, 1)],
        .socialX: [.icon: (4, 0), .value: (1, 0), .caption: (1, 0)],
        .socialTikTok: [.icon: (2, 0), .value: (-1, 0), .caption: (-1, 0)],
        .socialYouTube: [.value: (-3, 0), .caption: (-3, 0)]
    ]

    static func nudge(_ kind: WidgetKind, _ part: Part) -> CGSize {
        guard ReferenceScene.isActive, let d = nudges[kind]?[part] else { return .zero }
        return CGSize(width: d.0 / 2, height: d.1 / 2)
    }
}

extension View {
    /// Applies the reference-scene offset for one part of a connected tile (no-op in the app).
    func connNudge(_ kind: WidgetKind, _ part: ConnectedScene.Part) -> some View {
        modifier(ConnNudge(offset: ConnectedScene.nudge(kind, part)))
    }
}

private struct ConnNudge: ViewModifier {
    @Environment(\.metrics) private var m
    var offset: CGSize
    func body(content: Content) -> some View {
        if offset == .zero {
            content
        } else {
            content.offset(x: m.u(offset.width), y: m.u(offset.height))
        }
    }
}
