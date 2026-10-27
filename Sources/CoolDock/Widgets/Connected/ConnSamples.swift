import SwiftUI

/// Sample values matching the reference frames in `docs/reference`. Used by the `--scene reference`
/// render in every build (through `ConnectedScene`) and, in DEBUG builds, by harness checks:
///
///     CD_SAMPLE=1 ./.build/debug/CoolDock --render /tmp/out category:finance
///     CD_SAMPLE=panel …   # renders the expanded panel instead of the tile
enum ConnSample {
    static func snapshot(_ w: WidgetInstance) -> ConnSnapshot? {
        var s = ConnSnapshot()
        s.signature = ConnService.signature(w)
        s.updated = Date().addingTimeInterval(-240)
        let range = ConnService.range(w)
        s.seriesStart = range.start()
        s.seriesStep = range.step
        let n = 30
        let rising = (0..<n).map { i -> Double in 100 + pow(Double(i) / Double(n - 1), 2.6) * 70 }
        // Traced from the reference charts (least-squares fit of the smoothed line, 0…100).
        let sales: [Double] = [0, 6.2, 11.8, 16.5, 18.1, 15.9, 10.6, 6.8, 7.6, 14.4, 23.6, 31.3, 33.8, 31.3, 27.0, 24.5,
                               24.8, 25.2, 28.5, 35.1, 47.2, 63.5, 81.5, 100].map { 400 + $0 * 3 }
        let wavy: [Double] = [0, 6.4, 10.2, 8.5, 5.6, 11.9, 19.3, 17.7, 13.8, 20.1, 29.2, 27.8, 21.7, 25.7, 33.5, 32.2,
                              25.5, 30.3, 41.7, 42.6, 36.6, 39.4, 50.4, 51.6, 43.3, 45.0, 57.0, 59.4, 50.8, 50.8, 63.2, 67.8,
                              60.0, 59.1, 71.2, 76.8, 69.1, 66.9, 79.7, 87.6, 78.2, 73.3, 85.6, 95.2, 87.0, 80.5, 88.4, 100].map { 150 + $0 * 0.4 }
        switch w.kind {
        case .polarRevenue:
            s.value = 12_450; s.currency = "USD"; s.metrics[ConnKey.orders] = 214; s.series = rising
        case .stripeRevenue:
            s.value = 4_310; s.currency = "USD"; s.metrics[ConnKey.orders] = 87; s.series = rising
        case .dodoRevenue:
            s.value = 8_920; s.currency = "USD"; s.metrics[ConnKey.orders] = 131; s.series = rising
        case .shopifyChart, .shopifyToday, .shopifyOverview:
            s.value = 6_042; s.currency = "USD"
            s.metrics[ConnKey.orders] = 42
            s.metrics[ConnKey.aov] = 143.86
            s.metrics[ConnKey.valueDelta] = w.kind == .shopifyToday ? 0.27 : 0.22
            s.metrics[ConnKey.ordersDelta] = 0.17
            s.metrics[ConnKey.aovDelta] = 0.05
            s.series = sales
        case .plausible, .simpleAnalytics, .dataFast, .visitorsChart:
            s.value = 1_284; s.metrics[ConnKey.pageviews] = 3_910; s.series = wavy
        case .dubStats:
            s.value = 12_500
            s.metrics[ConnKey.clicks] = 12_500; s.metrics[ConnKey.leads] = 820; s.metrics[ConnKey.sales] = 96
            s.metrics[ConnKey.saleAmount] = 4_820; s.series = wavy
        case .resendStats:
            s.value = 42
            s.metrics[ConnKey.sentToday] = 42; s.metrics[ConnKey.sentMonth] = 847
            s.metrics[ConnKey.deliveredRate] = 0.93; s.metrics[ConnKey.bounced] = 6
            s.series = (0..<27).map { 20 + Double(($0 * 7) % 23) }
        case .githubContributions:
            // 14 weeks × 4 rows; every third cell (reading row by row) a shade darker, as in the reference.
            s.series = (0..<56).map { day in (day % 4 * 14 + day / 4) % 3 == 2 ? 7 : 10 }
            s.value = 5
            s.metrics[ConnKey.today] = 5; s.metrics[ConnKey.week] = 23; s.metrics[ConnKey.streak] = 12
            s.metrics[ConnKey.total] = 1_942
            s.seriesStep = 86_400
        case .supabase:
            s.value = 12_400; s.text[ConnKey.status] = "ACTIVE_HEALTHY"; s.text[ConnKey.name] = "production"
            s.metrics[ConnKey.requests] = 12_400; s.metrics[ConnKey.authRequests] = 830
            s.metrics[ConnKey.restRequests] = 10_900; s.metrics[ConnKey.storageRequests] = 520; s.metrics[ConnKey.realtimeRequests] = 150
            s.series = wavy; s.seriesStep = 3600
        case .socialX, .socialTikTok, .socialYouTube:
            s.value = 12_000; s.text[ConnKey.name] = "CoolDock"
            s.series = (0..<14).map { 11_200 + Double($0) * 60 }; s.seriesStep = 0; s.seriesStart = nil
        case .aiUsage:
            s.value = 1_200_000; s.currency = "USD"
            s.metrics[ConnKey.inputTokens] = 892_000; s.metrics[ConnKey.outputTokens] = 308_000
            s.metrics[ConnKey.cost] = 42.80; s.metrics[ConnKey.calls] = 1_284
            s.series = rising
            aiSample(ConnAIProvider(w), &s, wavy: wavy)
        default:
            return nil
        }
        return s
    }

    /// Per-provider shapes for the AI tile (Claude Code / Codex / admin APIs keep the reference sample above).
    private static func aiSample(_ provider: ConnAIProvider, _ s: inout ConnSnapshot, wavy: [Double]) {
        func unit(_ u: ConnAIUnit) { s.text[ConnKey.unit] = u.rawValue }
        switch provider {
        case .cursor:
            s.value = 3_420_000; s.estimate = false
            s.metrics = [ConnKey.inputTokens: 2_910_000, ConnKey.outputTokens: 510_000, ConnKey.cacheRead: 2_380_000,
                         ConnKey.cacheWrite: 120_000, ConnKey.cost: 18.62, ConnKey.calls: 412]
            s.series = wavy
        case .opencode:
            s.value = 2_150_000; s.estimate = true  // OpenCode's own list-price figure
            s.metrics = [ConnKey.inputTokens: 2_030_000, ConnKey.outputTokens: 120_000, ConnKey.cacheRead: 1_870_000,
                         ConnKey.cacheWrite: 9_000, ConnKey.cost: 3.55, ConnKey.calls: 296]
            s.series = wavy
        case .copilot:
            s.value = 214; s.estimate = false; unit(.requests)
            s.metrics = [ConnKey.calls: 214, ConnKey.cost: 3.36, ConnKey.grossCost: 8.56]
            s.series = wavy.map { $0 / 30 }
        case .gemini:
            s.value = 18_420; unit(.requests)
            s.metrics = [ConnKey.calls: 18_420]
            s.series = wavy
        case .perplexity:
            s.value = 12_850; unit(.credits)
            s.metrics = [ConnKey.calls: 1_930]
            s.series = wavy
        case .xai:
            s.value = 27.45; s.estimate = false; unit(.usd)
            s.metrics = [ConnKey.cost: 27.45]
            s.series = wavy.map { $0 / 40 }
        case .zai:
            s.value = 41_700_000; unit(.tokens)
            s.metrics = [:]
            s.text[ConnKey.name] = "glm-5.3"
            s.series = wavy
        case .antigravity:
            s.value = 0.72; unit(.quota)
            s.metrics = ["quota.0": 0.72, "quota.1": 0.91, "quota.2": 0.95, "quota.3": 1]
            s.text[ConnKey.name] = "Gemini Models"; s.text[ConnKey.window] = "5h"
            s.text["quota.0"] = "Gemini Models · 5h"; s.text["quota.1"] = "Gemini Models · weekly"
            s.text["quota.2"] = "Claude and GPT models · 5h"; s.text["quota.3"] = "Claude and GPT models · weekly"
            s.text[ConnKey.reset] = ConnDate.isoUTC(Date().addingTimeInterval(3 * 3600 + 1200))
            s.series = []; s.seriesStep = 0; s.seriesStart = nil
        case .claudeCode, .codex, .anthropic, .openai:
            break
        }
    }
}

#if DEBUG
extension ConnSample {
    static let mode = ProcessInfo.processInfo.environment["CD_SAMPLE"] ?? ""
    static let enabled = !mode.isEmpty && mode != "0"
    static var panel: Bool { mode == "panel" }

    /// `CD_CONN_CONFIG="user=octocat;range=30d"` merges config into harness instances (live checks).
    static func override(_ w: WidgetInstance) -> WidgetInstance {
        guard let raw = ProcessInfo.processInfo.environment["CD_CONN_CONFIG"], !raw.isEmpty else { return w }
        var out = w
        for pair in raw.split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { out.config[kv[0]] = kv[1] }
        }
        return out
    }

    /// Panel preview for the harness (no blur — ImageRenderer can't capture NSVisualEffectView).
    @MainActor @ViewBuilder
    static func panelPreview(_ w: WidgetInstance) -> some View {
        ConnPanel(w: w)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(white: 0.1)))
    }
}
#endif
