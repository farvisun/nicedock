import SwiftUI

/// Expanded view for any connected tile: headline metric, larger chart, details, freshness,
/// "Open dashboard" and "Connection & Settings…".
struct ConnPanel: View {
    @Environment(\.palette) private var p
    let w: WidgetInstance

    var body: some View {
        let store = ConnMetricStore.shared
        let s = store.snapshot(w)
        let error = store.error(w)
        VStack(alignment: .leading, spacing: 14) {
            header(loading: store.isLoading(w))
            if let s {
                headline(s)
                chart(s)
                details(s)
            } else {
                Text(error ?? L("Loading…"))
                    .font(.dock(12, .medium))
                    .foregroundStyle(p.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            }
            footer(s, error: error)
            HStack(spacing: 8) {
                if let url = ConnService.dashboardURL(w) {
                    ConnPanelButton(title: L("Open dashboard"), symbol: "arrow.up.right") {
                        Panels.shared.close()
                        Open.url(url.absoluteString)
                    }
                }
                Spacer(minLength: 8)
                ConnPanelButton(title: L("Connection & Settings…"), symbol: nil) {
                    Panels.shared.close()
                    WidgetSetup.customize(w)
                }
            }
        }
        .frame(width: 316)
    }

    // MARK: Sections

    private func header(loading: Bool) -> some View {
        HStack(spacing: 10) {
            ConnBrandMark(brand: ConnService.brand(w), size: 30, icon: [.shopifyToday, .shopifyOverview, .resendStats, .supabase].contains(w.kind))
            VStack(alignment: .leading, spacing: 1) {
                Text(w.kind.spec.localizedTitle).font(.dock(15, .bold)).foregroundStyle(p.primary).lineLimit(1)
                Text(subtitle).font(.dock(11, .medium)).foregroundStyle(p.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                NotificationCenter.default.post(name: .coolDockRefresh, object: w.id)
            } label: {
                Group {
                    if loading {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                    } else {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .bold)).foregroundStyle(p.secondary)
                    }
                }
                .frame(width: 26, height: 26)
                .background(Circle().fill(p.control))
                .contentShape(Circle())
            }
            .buttonStyle(PressableStyle())
            .help(L("Refresh"))
        }
    }

    private func headline(_ s: ConnSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            T(ConnPanelText.headline(w, s)).font(.dock(30, .bold, mono: true)).foregroundStyle(p.primary)
                .lineLimit(1).minimumScaleFactor(0.5)
            Text(ConnPanelText.caption(w, s)).font(.dock(11, .medium)).foregroundStyle(p.secondary).lineLimit(1)
        }
    }

    @ViewBuilder private func chart(_ s: ConnSnapshot) -> some View {
        if w.kind == .githubContributions {
            ConnContributionGrid(counts: s.series, columns: 13, rows: 7, dot: 12)
                .frame(height: 120)
        } else if s.series.count > 1 {
            VStack(spacing: 4) {
                ConnSparkline(values: s.series, colors: ConnPanelText.chartColors(w), lineWidth: 2, fillOpacity: 0.28)
                    .frame(height: 78)
                HStack {
                    Text(axisStart(s)).font(.dock(10, .medium)).foregroundStyle(p.tertiary)
                    Spacer()
                    Text(L("Now")).font(.dock(10, .medium)).foregroundStyle(p.tertiary)
                }
                .environment(\.layoutDirection, .leftToRight)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(p.control.opacity(0.6)))
        }
    }

    private func details(_ s: ConnSnapshot) -> some View {
        let rows = ConnPanelText.rows(w, s)
        return VStack(spacing: 7) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline) {
                    Text(row.0).font(.dock(12, .medium)).foregroundStyle(p.secondary)
                    Spacer(minLength: 12)
                    T(row.1).font(.dock(12, .semibold, mono: true)).foregroundStyle(p.primary).lineLimit(1)
                }
            }
        }
    }

    private func footer(_ s: ConnSnapshot?, error: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let s {
                HStack(spacing: 4) {
                    Image(systemName: "clock").font(.system(size: 9, weight: .semibold))
                    Text(updated(s.updated))
                    if let note = ConnPanelText.note(w, s) { Text(verbatim: "·"); Text(note) }
                }
                .font(.dock(10.5, .medium))
                .foregroundStyle(p.tertiary)
                .lineLimit(1)
            }
            if let error {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(p.accent(.cdOrange))
                    Text(error).foregroundStyle(p.secondary)
                }
                .font(.dock(10.5, .medium))
                .lineLimit(2)
            }
        }
    }

    // MARK: Text

    private var subtitle: String {
        if ConnService.hasRange(w.kind), w.kind != .shopifyToday { return "\(ConnService.name(w)) · \(ConnService.range(w).title)" }
        switch w.kind {
        case .shopifyToday: return "\(ConnService.name(w)) · \(ConnRange.day.title)"
        case .resendStats: return "\(ConnService.name(w)) · \(L("This month"))"
        case .supabase: return "\(ConnService.name(w)) · \(L("Last 24 hours"))"
        case .githubContributions: return "\(ConnService.name(w)) · \(L("Last 13 weeks"))"
        case .socialX:
            let user = w.string("user").trimmingCharacters(in: CharacterSet(charactersIn: "@ "))
            return user.isEmpty ? ConnService.name(w) : "\(ConnService.name(w)) · @\(user)"
        case .socialYouTube:
            let ch = w.string("channel").trimmingCharacters(in: .whitespaces)
            return ch.isEmpty ? ConnService.name(w) : "\(ConnService.name(w)) · \(ch)"
        default: return ConnService.name(w)
        }
    }

    private func updated(_ d: Date) -> String {
        let cal = Fmt.calendar
        let when = cal.isDateInToday(d) ? Fmt.clock(d) : "\(Fmt.relativeDay(d)) \(Fmt.clock(d))"
        return L("Updated %@", when)
    }

    private func axisStart(_ s: ConnSnapshot) -> String {
        guard let start = s.seriesStart, s.seriesStep > 0 else { return "" }
        return s.seriesStep < 86_400 && s.seriesStep > 0 ? Fmt.clock(start) : Fmt.date(start, "MMMd")
    }
}

/// Panel copy per kind.
enum ConnPanelText {
    static func headline(_ w: WidgetInstance, _ s: ConnSnapshot) -> String {
        let v = s.value ?? 0
        switch w.kind {
        case .polarRevenue, .stripeRevenue, .dodoRevenue, .shopifyChart, .shopifyToday, .shopifyOverview:
            return ConnFmt.money(v, s.currency)
        case .socialX, .socialTikTok, .socialYouTube, .aiUsage:
            return Fmt.compact(v)
        case .supabase:
            return s.value == nil ? ConnStatus.title(s.text[ConnKey.status]) : ConnFmt.count(v)
        default:
            return ConnFmt.count(v)
        }
    }

    static func caption(_ w: WidgetInstance, _ s: ConnSnapshot) -> String {
        let range = ConnService.range(w).caption
        switch w.kind {
        case .polarRevenue, .stripeRevenue, .dodoRevenue: return "\(L("net revenue")) · \(range)"
        case .shopifyChart, .shopifyOverview: return "\(L("total sales")) · \(range)"
        case .shopifyToday: return "\(L("total sales")) · \(ConnRange.day.caption)"
        case .plausible, .visitorsChart, .simpleAnalytics, .dataFast: return "\(L("visitors")) · \(range)"
        case .dubStats: return "\(L("clicks")) · \(range)"
        case .resendStats: return L("emails sent today")
        case .githubContributions: return L("contributions today")
        case .supabase: return s.value == nil ? (s.text[ConnKey.name] ?? "") : "\(L("API requests")) · \(L("last 24h"))"
        case .socialX, .socialTikTok: return s.text[ConnKey.name].map { "\(L("followers")) · \($0)" } ?? L("followers")
        case .socialYouTube: return s.text[ConnKey.name].map { "\(L("subscribers")) · \($0)" } ?? L("subscribers")
        case .aiUsage: return "\(L("tokens")) · \(range)"
        default: return ""
        }
    }

    static func rows(_ w: WidgetInstance, _ s: ConnSnapshot) -> [(String, String)] {
        func n(_ key: String) -> String { s.metric(key).map(ConnFmt.count) ?? "—" }
        func money(_ v: Double?, _ decimals: Int? = nil) -> String { v.map { ConnFmt.money($0, s.currency, decimals: decimals) } ?? "—" }
        func withDelta(_ text: String, _ d: Double?) -> String { d.map { "\(text)  \(ConnFmt.delta($0))" } ?? text }
        switch w.kind {
        case .polarRevenue, .stripeRevenue, .dodoRevenue:
            let orders = s.metric(ConnKey.orders) ?? 0
            return [(L("Payments"), n(ConnKey.orders)),
                    (L("Average payment"), orders > 0 ? money((s.value ?? 0) / orders, 2) : "—")]
        case .shopifyChart, .shopifyToday, .shopifyOverview:
            return [(L("Sales"), withDelta(money(s.value), s.metric(ConnKey.valueDelta))),
                    (L("Orders"), withDelta(n(ConnKey.orders), s.metric(ConnKey.ordersDelta))),
                    (L("AVG Order"), withDelta(money(s.metric(ConnKey.aov), 2), s.metric(ConnKey.aovDelta)))]
        case .plausible, .visitorsChart, .simpleAnalytics:
            return [(L("Visitors"), ConnFmt.count(s.value ?? 0)),
                    (L("Pageviews"), n(ConnKey.pageviews))]
        case .dataFast:
            var rows = [(L("Visitors"), ConnFmt.count(s.value ?? 0))]
            if s.metric(ConnKey.sessions) != nil { rows.append((L("Sessions"), n(ConnKey.sessions))) }
            if let r = s.metric(ConnKey.revenue) { rows.append((L("Revenue"), ConnFmt.money(r, s.currency ?? "USD"))) }
            return rows
        case .dubStats:
            var rows = [(L("Clicks"), n(ConnKey.clicks)), (L("Leads"), n(ConnKey.leads)), (L("Sales"), n(ConnKey.sales))]
            if let amount = s.metric(ConnKey.saleAmount) { rows.append((L("Revenue"), ConnFmt.money(amount, "USD"))) }
            return rows
        case .resendStats:
            return [(L("Sent today"), n(ConnKey.sentToday)), (L("This month"), n(ConnKey.sentMonth)),
                    (L("Delivered"), s.metric(ConnKey.deliveredRate).map { Fmt.percent($0) } ?? "—"),
                    (L("Bounced"), n(ConnKey.bounced))]
        case .githubContributions:
            var rows = [(L("Today"), n(ConnKey.today)), (L("Last 7 days"), n(ConnKey.week)),
                        (L("Current streak"), L("%@ days", n(ConnKey.streak)))]
            if s.metric(ConnKey.total) != nil { rows.append((L("Past year"), n(ConnKey.total))) }
            return rows
        case .supabase:
            var rows = [(L("Status"), ConnStatus.title(s.text[ConnKey.status]))]
            if let name = s.text[ConnKey.name] { rows.append((L("Project"), name)) }
            if s.value != nil {
                rows += [(L("REST"), n(ConnKey.restRequests)), (L("Auth"), n(ConnKey.authRequests)),
                         (L("Storage"), n(ConnKey.storageRequests)), (L("Realtime"), n(ConnKey.realtimeRequests))]
            }
            return rows
        case .socialX, .socialTikTok, .socialYouTube:
            var rows = [(w.kind == .socialYouTube ? L("Subscribers") : L("Followers"), ConnFmt.count(s.value ?? 0))]
            if s.series.count > 1, let first = s.series.first, let last = s.series.last {
                let change = last - first
                rows.append((L("Change"), (change >= 0 ? "+" : "−") + ConnFmt.count(abs(change))))
            }
            return rows
        case .aiUsage:
            var rows = [(L("Input"), Fmt.compact(s.metric(ConnKey.inputTokens) ?? 0)),
                        (L("Output"), Fmt.compact(s.metric(ConnKey.outputTokens) ?? 0))]
            if (s.metric(ConnKey.cacheRead) ?? 0) > 0 || (s.metric(ConnKey.cacheWrite) ?? 0) > 0 {
                rows.append((L("Cache write / read"), "\(Fmt.compact(s.metric(ConnKey.cacheWrite) ?? 0)) / \(Fmt.compact(s.metric(ConnKey.cacheRead) ?? 0))"))
            }
            rows.append((s.estimate ? L("Estimated cost") : L("Cost"), ConnFmt.money(s.metric(ConnKey.cost) ?? 0, "USD", decimals: 2)))
            if let calls = s.metric(ConnKey.calls), calls > 0 { rows.append((L("Requests"), ConnFmt.count(calls))) }
            return rows
        default:
            return []
        }
    }

    static func note(_ w: WidgetInstance, _ s: ConnSnapshot) -> String? {
        guard s.estimate else { return nil }
        switch w.kind {
        case .githubContributions: return L("approximate (public activity)")
        case .aiUsage: return L("cost estimated from list prices")
        default: return L("estimate")
        }
    }

    static func chartColors(_ w: WidgetInstance) -> [Color] {
        switch ConnService.brand(w) {
        case .shopify: return [Color(hex: "#80B03D")]
        case .visitors, .simpleAnalytics: return [Color(hex: "#F39033"), Color(hex: "#EC5A35")]
        case .plausible: return [Color(hex: "#8B87F8"), Color(hex: "#5850EC")]
        case .stripe: return [Color(hex: "#7A73FF")]
        case .dodo: return [Color(hex: "#C8F23A")]
        case .supabase: return [Color(hex: "#3ECF8E")]
        case .claude: return [Color(hex: "#DE7356")]
        case .youtube: return [.cdRed]
        case .tiktok: return [Color(hex: "#25F4EE"), Color(hex: "#FE2C55")]
        case .dataFast: return [.cdOrange]
        case .codex, .openai: return [.cdTeal]
        default: return [.cdBlue]
        }
    }
}

private struct ConnPanelButton: View {
    @Environment(\.palette) private var p
    var title: String
    var symbol: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title).lineLimit(1).fixedSize()
                if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .bold)).flipsForRTL() }
            }
            .font(.dock(11.5, .semibold))
            .foregroundStyle(p.primary)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(Capsule().fill(p.control))
            .overlay(Capsule().strokeBorder(p.tileStroke, lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
    }
}
