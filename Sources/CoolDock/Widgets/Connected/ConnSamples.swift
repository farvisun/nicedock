#if DEBUG
import SwiftUI

/// DEBUG-only sample values matching the reference frames, for render-harness checks:
///
///     CD_SAMPLE=1 ./.build/debug/CoolDock --render /tmp/out category:finance
///     CD_SAMPLE=panel …   # renders the expanded panel instead of the tile
enum ConnSample {
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

    static func snapshot(_ w: WidgetInstance) -> ConnSnapshot? {
        var s = ConnSnapshot()
        s.signature = ConnService.signature(w)
        s.updated = Date().addingTimeInterval(-240)
        let range = ConnService.range(w)
        s.seriesStart = range.start()
        s.seriesStep = range.step
        let n = 30
        let rising = (0..<n).map { i -> Double in 100 + pow(Double(i) / Double(n - 1), 2.6) * 70 }
        let wavy = (0..<60).map { i -> Double in 50 + Double(i) * 0.32 + 3.2 * sin(Double(i) * 0.95) }
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
            s.series = rising
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
            let pattern: [Double] = [6, 9, 4, 8, 10, 7, 3, 9, 11, 8, 5, 10, 9, 2]
            s.series = (0..<91).map { pattern[$0 % pattern.count] }
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
        default:
            return nil
        }
        return s
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
