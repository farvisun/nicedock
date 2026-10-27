import SwiftUI

/// Stocks (Yahoo Finance) and crypto (Binance) widgets.
enum FinanceWidgets {
    @MainActor @ViewBuilder
    static func view(_ w: WidgetInstance) -> some View {
        switch w.kind {
        case .stockQuote: FinQuoteTile(w: w, key: FinKey(.stock, w.string("symbol", "AAPL")))
        case .cryptoQuote: FinQuoteTile(w: w, key: FinKey(.crypto, w.string("symbol", "BTC")))
        case .stockChart: FinChartTile(w: w, key: FinKey(.stock, w.string("symbol", "AAPL")))
        case .cryptoChart: FinChartTile(w: w, key: FinKey(.crypto, w.string("symbol", "ETH")))
        case .stockWatchlist: FinWatchlistTile(w: w, keys: keys(w, .stock))
        case .cryptoWatchlist: FinWatchlistTile(w: w, keys: keys(w, .crypto))
        default: Tile(width: w.kind.spec.width) { Text(w.kind.spec.localizedTitle).dock(11) }
        }
    }

    @MainActor @ViewBuilder
    static func menu(_ w: WidgetInstance) -> some View {
        switch w.kind {
        case .stockQuote, .stockChart, .cryptoQuote, .cryptoChart:
            let key = FinKey(w.kind.spec.category == .crypto ? .crypto : .stock, w.string("symbol"))
            Button(key.webTitle) { Open.url(key.webURL) }
            Divider()
        default:
            EmptyView()
        }
    }

    static func keys(_ w: WidgetInstance, _ market: FinMarket) -> [FinKey] {
        var seen = Set<String>()
        return w.list("symbols").map { FinKey(market, $0) }.filter { !$0.symbol.isEmpty && seen.insert($0.id).inserted }.prefix(3).map { $0 }
    }

    @MainActor static func openPanel(_ id: AnyHashable, _ key: FinKey) {
        Panels.shared.toggle(id) { FinPanel(key: key) }
    }
}

/// Market green / red as the reference frames draw them (softer than the system accents).
extension Color {
    fileprivate static let finUp = Color(red: 50 / 255, green: 199 / 255, blue: 115 / 255)
    fileprivate static let finDown = Color(red: 255 / 255, green: 82 / 255, blue: 82 / 255)
}

// MARK: - Quote (173 pt): "AAPL Apple Inc." / big price / "+3.29 (+1.12%)"

private struct FinQuoteTile: View {
    let w: WidgetInstance
    let key: FinKey
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p

    var body: some View {
        let svc = FinService.shared
        let q = svc.quote(key)
        Tile(width: w.kind.spec.width, padding: EdgeInsets(top: 0, leading: 13, bottom: 0, trailing: 10), alignment: .leading) {
            if q == nil, let err = svc.error(key) {
                TileMessage(symbol: "exclamationmark.triangle.fill", text: "\(key.symbol) · \(err)")
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: m.u(4)) {
                        Text(verbatim: key.symbol).dock(10, .bold)
                        if let name = q?.name, name != key.symbol {
                            // The company name is SF Pro 9 medium in the reference frame.
                            Text(verbatim: name).dock(9, .medium, p.secondary, design: .default)
                        }
                    }
                    T(q.map(FinFormat.price) ?? "—").dock(22, .bold, q == nil ? p.tertiary : nil, mono: true)
                        .minimumScaleFactor(0.55)
                        .padding(.top, m.u(2))
                    T(q.map(FinFormat.change) ?? " ").dock(10, .semibold, p.accent(q?.isUp == false ? .finDown : .finUp))
                        .padding(.top, m.u(2))
                }
            }
        }
        .onTapGesture { FinanceWidgets.openPanel(w.id, key) }
        .task(id: key) { await svc.keepFresh([key], chart: false) }
        .onWidgetRefresh(w.id) { Task { await svc.ensure(key, chart: false, force: true) } }
    }
}

// MARK: - Chart (149 pt): symbol, price and % on top, sparkline below

private struct FinChartTile: View {
    let w: WidgetInstance
    let key: FinKey
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p

    var body: some View {
        let svc = FinService.shared
        let q = svc.quote(key)
        let color: Color = q?.isUp == false ? .finDown : .finUp
        Tile(width: w.kind.spec.width) {
            if q == nil, let err = svc.error(key) {
                TileMessage(symbol: "exclamationmark.triangle.fill", text: "\(key.symbol) · \(err)")
            } else {
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: m.u(4)) {
                        Text(verbatim: key.symbol).dock(10, .bold)
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: m.u(1)) {
                            // Bold with proportional digits, ending exactly on the column's edge, which sits a quarter
                            // device pixel inside the whole-pixel layout in the reference frame.
                            let price = Fmt.digits(q.map(FinFormat.price) ?? "—")
                            Text(verbatim: price).dock(11.25, .bold, q == nil ? p.tertiary : nil)
                                .minimumScaleFactor(0.6)
                                .runTrailing(price, 11.25, .bold)
                                .transformEffect(CGAffineTransform(translationX: m.u(-0.125), y: 0))
                            T(q.map(FinFormat.percent) ?? " ").dock(9, .semibold, p.accent(color), mono: true)
                        }
                    }
                    .padding(.leading, m.u(13))
                    .padding(.trailing, m.u(12))
                    .padding(.top, m.u(6))
                    Spacer(minLength: 0)
                    // Line at 80 % so the area fill and stroke read softer, as in the reference.
                    FinSparkline(values: FinSparkline.smoothed(q?.points ?? [], buckets: 20), color: p.accent(color).opacity(0.8), lineWidth: m.u(2),
                                 fillOpacity: 0.4)
                        .frame(height: m.u(21.75))
                        .padding(.leading, m.u(14))
                        .padding(.trailing, m.u(13.75))
                        .padding(.bottom, m.u(6.5))
                }
            }
        }
        .onTapGesture { FinanceWidgets.openPanel(w.id, key) }
        .task(id: key) { await svc.keepFresh([key], chart: true) }
        .onWidgetRefresh(w.id) { Task { await svc.ensure(key, chart: true, force: true) } }
    }
}

/// `AreaSparkline` scaled to the series' own range; always left-to-right.
private struct FinSparkline: View {
    var values: [Double]
    var color: Color
    var lineWidth: CGFloat
    var fillOpacity: Double

    var body: some View {
        let lo = values.min() ?? 0, hi = values.max() ?? 1
        let span = max(hi - lo, abs(hi) * 0.001, 0.000_001)
        AreaSparkline(values: values, color: color, lineWidth: lineWidth, fillOpacity: fillOpacity,
                      minValue: hi - span, maxValue: hi)
            .environment(\.layoutDirection, .leftToRight)
    }

    /// Bucket-averages dense intraday data so the small chart reads as a calm line.
    static func smoothed(_ v: [Double], buckets: Int) -> [Double] {
        guard v.count > buckets * 2 else { return v }
        let size = Double(v.count) / Double(buckets)
        var out = (0..<buckets).map { i -> Double in
            let a = Int(Double(i) * size), b = max(a + 1, Int(Double(i + 1) * size))
            let slice = v[a..<min(b, v.count)]
            return slice.reduce(0, +) / Double(slice.count)
        }
        out[0] = v[0]
        out[buckets - 1] = v[v.count - 1]
        return out
    }
}

// MARK: - Watchlist (224 pt): three rows of symbol / price / change

private struct FinWatchlistTile: View {
    let w: WidgetInstance
    let keys: [FinKey]
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p

    var body: some View {
        let svc = FinService.shared
        Tile(width: w.kind.spec.width, padding: EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12)) {
            if keys.isEmpty {
                TileMessage(symbol: "list.number", text: L("Add symbols"), tint: .cdGreen)
                    .contentShape(Rectangle())
                    .onTapGesture { WidgetSetup.customize(w) }
            } else {
                VStack(spacing: 0) {
                    ForEach(keys) { k in
                        row(k, svc.quote(k), svc.error(k))
                            .frame(height: m.u(16))
                            .contentShape(Rectangle())
                            .onTapGesture { FinanceWidgets.openPanel("\(w.id)-\(k.id)", k) }
                    }
                }
            }
        }
        .task(id: keys) { await svc.keepFresh(keys, chart: false) }
        .onWidgetRefresh(w.id) { Task { for k in keys { await svc.ensure(k, chart: false, force: true) } } }
    }

    private func row(_ k: FinKey, _ q: FinQuote?, _ err: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(verbatim: k.symbol).dock(10, .bold)
                .frame(width: m.u(48), alignment: .leading)
            T(q.map(FinFormat.price) ?? "—").dock(10, .semibold, q == nil ? p.tertiary : nil, mono: true)
            Spacer(minLength: m.u(6))
            if let q {
                T(FinFormat.percent(q)).dock(9, .semibold, p.accent(q.isUp ? .finUp : .finDown), mono: true)
            } else if err != nil {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: m.u(9.5))).foregroundStyle(p.accent(.cdOrange))
                    .help(err ?? "")
            }
        }
    }
}

// MARK: - Panel: bigger chart, day range, open / previous close, link out

private struct FinPanel: View {
    let key: FinKey
    @Environment(\.palette) private var p

    var body: some View {
        let svc = FinService.shared
        let q = svc.quote(key)
        let color: Color = q?.isUp == false ? .finDown : .finUp
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(title: key.symbol, subtitle: q?.name ?? (key.market == .crypto ? FinService.coinNames[key.symbol] : nil)) {
                if let q {
                    VStack(alignment: .trailing, spacing: 2) {
                        T(FinFormat.price(q)).font(.dock(17, .bold).monospacedDigit()).foregroundStyle(p.primary)
                        T(FinFormat.change(q)).font(.dock(11.5, .semibold).monospacedDigit()).foregroundStyle(p.accent(color))
                    }
                }
            }
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(p.control.opacity(0.5))
                if let q, q.points.count > 1 {
                    FinPanelChart(quote: q, color: color)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 12)
                } else if let err = svc.error(key) {
                    Text(err).font(.dock(11, .medium)).foregroundStyle(p.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 300, height: 128)
            if let q {
                let crypto = key.market == .crypto
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    GridRow {
                        stat(crypto ? L("24h Open") : LD("stock.openPrice", "Open"), q.open.map { FinFormat.value($0, like: q) })
                        stat(crypto ? L("24h Range") : L("Day Range"), range(q))
                    }
                    GridRow {
                        stat(L("Prev. Close"), q.prevClose.map { FinFormat.value($0, like: q) })
                        stat(L("Updated"), Fmt.clock(q.fetched))
                    }
                }
            }
            Button { Panels.shared.close(); Open.url(key.webURL) } label: {
                HStack(spacing: 6) {
                    Text(key.webTitle)
                    Image(systemName: "arrow.up.forward").flipsForRTL()
                }
                .font(.dock(12, .semibold))
                .foregroundStyle(p.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(p.control))
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
        }
        .frame(width: 300)
        .task(id: key) { await svc.ensure(key, chart: true) }
    }

    private func range(_ q: FinQuote) -> String? {
        guard let lo = q.low, let hi = q.high else { return nil }
        return FinFormat.ltr(FinFormat.value(lo, like: q) + " – " + FinFormat.value(hi, like: q))
    }

    private func stat(_ title: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.dock(10.5, .medium)).foregroundStyle(p.secondary)
            T(value ?? "—").font(.dock(13, .semibold).monospacedDigit()).foregroundStyle(p.primary)
        }
        .frame(width: 140, alignment: .leading)
    }
}

/// Larger sparkline with a dashed previous-close / open reference line.
private struct FinPanelChart: View {
    let quote: FinQuote
    let color: Color
    @Environment(\.palette) private var p

    var body: some View {
        let base = quote.prevClose ?? quote.open
        let vals = quote.points
        let lo = min(vals.min() ?? 0, base ?? .infinity)
        let hi = max(vals.max() ?? 1, base ?? -.infinity)
        let lw: CGFloat = 2
        ZStack {
            if let base {
                Canvas { ctx, size in
                    let span = max(hi - lo, 0.000_001)
                    let y = lw + (size.height - lw * 2) * (1 - CGFloat((base - lo) / span))
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    ctx.stroke(path, with: .color(p.tertiary), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            AreaSparkline(values: vals, color: color, lineWidth: lw, fillOpacity: 0.3, minValue: lo, maxValue: hi)
        }
        .environment(\.layoutDirection, .leftToRight)
    }
}
