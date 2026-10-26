import SwiftUI

/// Finance, commerce, analytics, developer, social and AI widgets backed by third-party APIs
/// (or local logs). Data lives in `ConnMetricStore`; every tile owns a cancellable refresh loop.
enum ConnectedWidgets {
    @MainActor @ViewBuilder
    static func view(_ w: WidgetInstance) -> some View {
        #if DEBUG
        if ConnSample.panel {
            ConnSample.panelPreview(ConnSample.override(w))
        } else {
            tile(ConnSample.override(w))
        }
        #else
        tile(w)
        #endif
    }

    @MainActor @ViewBuilder
    private static func tile(_ w: WidgetInstance) -> some View {
        switch w.kind {
        case .polarRevenue, .stripeRevenue, .dodoRevenue, .plausible, .simpleAnalytics, .dataFast:
            ConnValueTile(w: w)
        case .shopifyChart, .visitorsChart:
            ConnChartTile(w: w)
        case .shopifyToday:
            ConnShopifyTodayTile(w: w)
        case .shopifyOverview, .dubStats, .resendStats, .supabase:
            ConnTableTile(w: w)
        case .githubContributions:
            ConnGitHubTile(w: w)
        case .socialX, .socialTikTok, .socialYouTube:
            ConnSocialTile(w: w)
        case .aiUsage:
            ConnAITile(w: w)
        default:
            Tile(width: w.kind.spec.width) { Text(w.kind.spec.localizedTitle).dock(11) }
        }
    }

    @MainActor @ViewBuilder
    static func menu(_ w: WidgetInstance) -> some View {
        if let url = ConnService.dashboardURL(w) {
            Button(L("Open %@", ConnService.name(w))) { Open.url(url.absoluteString) }
        }
    }
}

// MARK: - Shell (setup, errors, refresh loop, click → panel)

struct ConnTileState {
    var snap: ConnSnapshot?
    var error: String?
    /// The visible value is from an earlier refresh; the latest one failed.
    var stale: Bool { error != nil && snap != nil }
}

private struct ConnShell<Content: View>: View {
    let w: WidgetInstance
    @ViewBuilder var content: (ConnTileState) -> Content
    @State private var tick = 0

    var body: some View {
        let store = ConnMetricStore.shared
        let token = ConnEnv.token(w.id)
        let configured = ConnService.isConfigured(w, token: token)
        let snap = store.snapshot(w)
        let error = store.error(w)
        Button {
            if configured {
                Panels.shared.toggle(w.id) { ConnPanel(w: w) }
            } else {
                WidgetSetup.customize(w)
            }
        } label: {
            Tile(width: w.kind.spec.width) {
                if !configured {
                    TileMessage(symbol: "link.circle.fill", text: L("Connect %@", ConnService.name(w)))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if snap == nil, let error {
                    TileMessage(symbol: "exclamationmark.triangle.fill", text: error)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    content(ConnTileState(snap: snap, error: error))
                }
            }
        }
        .buttonStyle(ConnTilePress())
        .if(error != nil) { $0.help(error ?? "") }
        .task(id: "\(ConnService.signature(w))#\(token?.hashValue ?? 0)#\(tick)#\(configured)") {
            guard configured else { return }
            await store.keepFresh(w)
        }
        .onWidgetRefresh(w.id) {
            store.requestRefresh(w.id)
            tick &+= 1
        }
    }
}

/// Positions children by baseline inside the full tile (see `connBaseline`).
private struct ConnCanvas<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            content()
        }
    }
}

private let dash = "—"

// MARK: - Value tile (Polar, Stripe, Dodo, Plausible, Simple Analytics, DataFast)

private struct ConnValueTile: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    let w: WidgetInstance

    var body: some View {
        ConnShell(w: w) { state in
            let width = w.kind.spec.width
            let range = ConnService.range(w)
            ConnCanvas {
                T(value(state.snap))
                    .dock(19.5, .bold, state.snap == nil ? p.tertiary : nil, mono: true)
                    .minimumScaleFactor(0.5)
                    .frame(maxWidth: m.u(width - 34), alignment: .leading)
                    .padding(.leading, m.u(6))
                    .connBaseline(m.u(32.75))
                ConnCaption(text: "\(caption) · \(range.caption)", stale: state.stale)
                    .frame(maxWidth: m.u(width - 12), alignment: .leading)
                    .padding(.leading, m.u(6))
                    .connBaseline(m.u(47.5))
                ConnBrandMark(brand: ConnService.brand(w), size: 18)
                    .padding(.top, m.u(7.5))
                    .padding(.trailing, m.u(7))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var caption: String {
        switch w.kind {
        case .polarRevenue, .stripeRevenue, .dodoRevenue: return L("net revenue")
        default: return L("visitors")
        }
    }

    private func value(_ s: ConnSnapshot?) -> String {
        guard let v = s?.value else { return dash }
        switch w.kind {
        case .polarRevenue, .stripeRevenue, .dodoRevenue: return ConnFmt.money(v, s?.currency)
        default: return ConnFmt.count(v)
        }
    }
}

// MARK: - Chart tile (Shopify Trend, Visitors Chart)

private struct ConnChartTile: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    let w: WidgetInstance

    var body: some View {
        ConnShell(w: w) { state in
            let width = w.kind.spec.width
            let s = state.snap
            ConnCanvas {
                T(value(s))
                    .dock(18.5, .bold, s == nil ? p.tertiary : nil, mono: true)
                    .minimumScaleFactor(0.5)
                    .frame(maxWidth: m.u(width - 36), alignment: .leading)
                    .padding(.leading, m.u(6))
                    .connBaseline(m.u(23))
                ConnCaption(text: caption(s), stale: state.stale)
                    .frame(maxWidth: m.u(width - 36), alignment: .leading)
                    .padding(.leading, m.u(6))
                    .connBaseline(m.u(36.5))
                ConnBrandMark(brand: ConnService.brand(w), size: 18)
                    .padding(.top, m.u(7))
                    .padding(.trailing, m.u(7.5))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                ConnSparkline(values: s?.series ?? [], colors: colors, lineWidth: m.u(1.8), fillOpacity: 0.2)
                    .frame(height: m.u(16))
                    .padding(.horizontal, m.u(4.5))
                    .padding(.top, m.u(41))
            }
        }
    }

    private var colors: [Color] {
        w.kind == .shopifyChart ? [Color(hex: "#80B03D")] : [Color(hex: "#F39033"), Color(hex: "#EC5A35")]
    }

    private func value(_ s: ConnSnapshot?) -> String {
        guard let v = s?.value else { return dash }
        return w.kind == .shopifyChart ? ConnFmt.money(v, s?.currency) : ConnFmt.count(v)
    }

    private func caption(_ s: ConnSnapshot?) -> String {
        let range = ConnService.range(w).caption
        if w.kind == .shopifyChart {
            let n = Int(s?.metric(ConnKey.orders) ?? 0)
            return "\(L("%@ orders", Fmt.int(n))) · \(range)"
        }
        return "\(L("visitors")) · \(range)"
    }
}

// MARK: - Shopify Today

private struct ConnShopifyTodayTile: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    let w: WidgetInstance

    var body: some View {
        ConnShell(w: w) { state in
            let s = state.snap
            let width = w.kind.spec.width
            ConnCanvas {
                ConnBigMark(brand: .shopify, icon: true, pill: ConnRange.day.pill)
                    .padding(.leading, m.u(13))
                    .frame(maxHeight: .infinity)
                Text(L("Today")).dock(9.25, .semibold, p.secondary)
                    .padding(.leading, m.u(65))
                    .connBaseline(m.u(15.5))
                T(s?.value.map { ConnFmt.money($0, s?.currency) } ?? dash)
                    .dock(20, .bold, s == nil ? p.tertiary : nil, mono: true)
                    .minimumScaleFactor(0.5)
                    .frame(maxWidth: m.u(width - 65 - 8), alignment: .leading)
                    .padding(.leading, m.u(65))
                    .connBaseline(m.u(39))
                HStack(alignment: .firstTextBaseline, spacing: m.u(4)) {
                    Text(L("total sales")).dock(9.25, .semibold, p.secondary)
                    if let d = s?.metric(ConnKey.valueDelta) {
                        T(ConnFmt.delta(d)).dock(9.25, .semibold, p.accent(d >= 0 ? .cdGreen : .cdRed))
                    }
                    if state.stale { ConnWarning() }
                }
                .padding(.leading, m.u(65))
                .connBaseline(m.u(54.5))
            }
        }
    }
}

// MARK: - Icon + three-row table (Shopify Overview, Dub, Resend, Supabase)

private struct ConnTableRow: Identifiable {
    var id: String { label }
    let label: String
    let value: String
    var delta: Double?
    var dot: Color?
}

private struct ConnTableTile: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    let w: WidgetInstance

    var body: some View {
        ConnShell(w: w) { state in
            let rows = rows(state.snap)
            let hasDeltas = w.kind == .shopifyOverview
            let leading: CGFloat = hasDeltas ? 63 : 65
            ConnCanvas {
                ConnBigMark(brand: ConnService.brand(w), icon: [.shopifyOverview, .resendStats, .supabase].contains(w.kind), pill: pill)
                    .padding(.leading, m.u(hasDeltas ? 11 : 13))
                    .frame(maxHeight: .infinity)
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(row.label).dock(10, .semibold, p.secondary)
                        if i == rows.count - 1, state.stale { ConnWarning().padding(.leading, m.u(3)) }
                        Spacer(minLength: m.u(4))
                        if let dot = row.dot {
                            Circle().fill(p.accent(dot)).frame(width: m.u(6), height: m.u(6)).padding(.trailing, m.u(4))
                                .alignmentGuide(.firstTextBaseline) { $0[.bottom] + m.u(0.5) }
                        }
                        T(row.value).dock(10, .bold, state.snap == nil ? p.tertiary : nil, mono: true)
                            .minimumScaleFactor(0.6)
                        if hasDeltas, let d = row.delta {
                            T(ConnFmt.delta(d)).dock(8.5, .semibold, p.accent(d >= 0 ? .cdGreen : .cdRed))
                                .fixedSize()
                                .padding(.leading, m.u(6))
                        }
                    }
                    .padding(.leading, m.u(leading))
                    .padding(.trailing, m.u(hasDeltas ? 13.5 : 14))
                    .connBaseline(m.u(19.5 + CGFloat(i) * 15))
                }
            }
        }
    }

    private var pill: String? {
        switch w.kind {
        case .shopifyOverview, .dubStats: return ConnService.range(w).pill
        case .supabase: return L("24H")
        default: return nil
        }
    }

    private func rows(_ s: ConnSnapshot?) -> [ConnTableRow] {
        func n(_ key: String) -> String { s?.metric(key).map(ConnFmt.count) ?? dash }
        switch w.kind {
        case .shopifyOverview:
            return [
                ConnTableRow(label: L("Sales"), value: s?.value.map { ConnFmt.money($0, s?.currency, decimals: abs($0) >= 1000 ? 0 : 2) } ?? dash,
                             delta: s?.metric(ConnKey.valueDelta)),
                ConnTableRow(label: L("Orders"), value: n(ConnKey.orders), delta: s?.metric(ConnKey.ordersDelta)),
                ConnTableRow(label: L("AVG Order"), value: s?.metric(ConnKey.aov).map { ConnFmt.money($0, s?.currency, decimals: 2) } ?? dash,
                             delta: s?.metric(ConnKey.aovDelta))
            ]
        case .dubStats:
            return [
                ConnTableRow(label: L("Clicks"), value: n(ConnKey.clicks)),
                ConnTableRow(label: L("Leads"), value: n(ConnKey.leads)),
                ConnTableRow(label: L("Sales"), value: n(ConnKey.sales))
            ]
        case .resendStats:
            return [
                ConnTableRow(label: L("Sent today"), value: n(ConnKey.sentToday)),
                ConnTableRow(label: L("Delivered"), value: s?.metric(ConnKey.deliveredRate).map { Fmt.percent($0) } ?? dash),
                ConnTableRow(label: L("This month"), value: n(ConnKey.sentMonth))
            ]
        default: // Supabase
            let status = s?.text[ConnKey.status]
            return [
                ConnTableRow(label: L("Status"), value: s == nil ? dash : ConnStatus.title(status), dot: s == nil ? nil : ConnStatus.color(status)),
                ConnTableRow(label: L("Requests"), value: n(ConnKey.requests)),
                ConnTableRow(label: L("Auth"), value: n(ConnKey.authRequests))
            ]
        }
    }
}

/// Supabase health → label/colour.
enum ConnStatus {
    static func title(_ status: String?) -> String {
        switch ConnSupabase.health(status) {
        case .healthy: return L("Healthy")
        case .starting: return L("Starting")
        case .paused: return L("Paused")
        case .failing: return L("Unhealthy")
        }
    }

    static func color(_ status: String?) -> Color {
        switch ConnSupabase.health(status) {
        case .healthy: return .cdGreen
        case .starting: return .cdYellow
        case .paused: return .cdGray
        case .failing: return .cdRed
        }
    }
}

// MARK: - GitHub contributions

private struct ConnGitHubTile: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    let w: WidgetInstance

    var body: some View {
        ConnShell(w: w) { state in
            let s = state.snap
            ConnCanvas {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    stat(s?.metric(ConnKey.today), L("today"))
                    Spacer(minLength: m.u(3))
                    stat(s?.metric(ConnKey.week), L("week"))
                    Spacer(minLength: m.u(3))
                    HStack(alignment: .firstTextBaseline, spacing: m.u(2)) {
                        Text(verbatim: "🔥").font(.system(size: m.u(8.5)))
                        T(s?.metric(ConnKey.streak).map { Fmt.int(Int($0)) } ?? dash).dock(8.5, .bold, mono: true)
                        Text(L("streak")).dock(7.25, .bold, p.secondary)
                        if state.stale { ConnWarning() }
                    }
                    .layoutPriority(1)
                }
                .minimumScaleFactor(0.75)
                .padding(.leading, m.u(6.5))
                .padding(.trailing, m.u(7))
                .connBaseline(m.u(13.5))
                ConnContributionGrid(counts: s?.series ?? [], columns: 13, rows: 4, dot: m.u(7))
                    .frame(height: m.u(34))
                    .padding(.horizontal, m.u(8))
                    .padding(.top, m.u(19.5))
            }
        }
    }

    private func stat(_ v: Double?, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: m.u(2.5)) {
            T(v.map { Fmt.int(Int($0)) } ?? dash).dock(8.5, .bold, mono: true)
            Text(label).dock(8.5, .bold, p.secondary)
        }
    }
}

// MARK: - Social followers

private struct ConnSocialTile: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    let w: WidgetInstance

    var body: some View {
        ConnShell(w: w) { state in
            let s = state.snap
            ConnCanvas {
                ConnBrandMark(brand: ConnService.brand(w), size: 44)
                    .padding(.leading, m.u(3))
                    .frame(maxHeight: .infinity)
                T(s?.value.map(Fmt.compact) ?? dash)
                    .dock(20, .bold, s == nil ? p.tertiary : nil, mono: true)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: m.u(w.kind.spec.width - 64), alignment: .leading)
                    .padding(.leading, m.u(56.5))
                    .connBaseline(m.u(33))
                ConnCaption(text: w.kind == .socialYouTube ? L("subscribers") : L("followers"), size: 9.5, stale: state.stale)
                    .padding(.leading, m.u(56.5))
                    .connBaseline(m.u(47.5))
            }
        }
    }
}

// MARK: - AI usage

private struct ConnAITile: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    let w: WidgetInstance

    var body: some View {
        ConnShell(w: w) { state in
            let s = state.snap
            let width = w.kind.spec.width
            ConnCanvas {
                T(s?.value.map(Fmt.compact) ?? dash)
                    .dock(20, .bold, s == nil ? p.tertiary : nil, mono: true)
                    .frame(maxWidth: m.u(width - 36), alignment: .leading)
                    .padding(.leading, m.u(6))
                    .connBaseline(m.u(26))
                ConnCaption(text: "\(L("tokens")) · \(ConnService.range(w).caption)", stale: state.stale)
                    .padding(.leading, m.u(6))
                    .connBaseline(m.u(41.5))
                Text(costLine(s)).dock(8.25, .semibold, p.tertiary)
                    .frame(maxWidth: m.u(width - 12), alignment: .leading)
                    .padding(.leading, m.u(6))
                    .connBaseline(m.u(53.5))
                ConnBrandMark(brand: ConnService.brand(w), size: 18)
                    .padding(.top, m.u(7))
                    .padding(.trailing, m.u(7.5))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private func costLine(_ s: ConnSnapshot?) -> String {
        guard let s else { return " " }
        let cost = ConnFmt.money(s.metric(ConnKey.cost) ?? 0, s.currency ?? "USD", decimals: 2)
        let input = Fmt.compact(s.metric(ConnKey.inputTokens) ?? 0)
        return "\(s.estimate ? "≈ " : "")\(cost) · \(L("in %@", input))"
    }
}
