import Foundation
import Observation

enum FinMarket: String, Codable {
    case stock, crypto

    /// Stocks refresh every 5 min, crypto every 2 min (only while a tile is visible).
    var interval: TimeInterval { self == .stock ? 300 : 120 }
}

struct FinKey: Hashable, Identifiable {
    let market: FinMarket
    let symbol: String

    init(_ market: FinMarket, _ raw: String) {
        self.market = market
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if market == .crypto {
            s = s.replacingOccurrences(of: "/", with: "").replacingOccurrences(of: "-", with: "")
            if s.hasSuffix("USDT"), s.count > 4 { s = String(s.dropLast(4)) }
        }
        symbol = s
    }

    var id: String { "\(market.rawValue):\(symbol)" }

    /// Page on Yahoo Finance / Binance for the "Open in …" button.
    var webURL: String {
        switch market {
        case .stock: return "https://finance.yahoo.com/quote/\(symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol)"
        case .crypto: return "https://www.binance.com/en/trade/\(symbol)_USDT"
        }
    }

    var webTitle: String { market == .stock ? L("Open in Yahoo Finance") : L("Open in Binance") }
}

struct FinQuote: Codable, Equatable {
    var symbol: String
    var name: String
    var price: Double
    var change: Double
    var percent: Double
    var open: Double?
    var prevClose: Double?
    var high: Double?
    var low: Double?
    var points: [Double]
    var fetched: Date

    var isUp: Bool { change >= 0 }
}

/// Yahoo Finance (stocks) and Binance (crypto) quotes with a disk cache. Errors keep the stale value.
@Observable
@MainActor
final class FinService {
    static let shared = FinService()

    private(set) var quotes: [String: FinQuote]
    private(set) var errors: [String: String] = [:]
    @ObservationIgnored private var inFlight = Set<String>()
    @ObservationIgnored private var chartFetched: [String: Date] = [:]
    @ObservationIgnored private var binanceRetry = Date.distantPast

    private init() {
        quotes = DiskCache.load([String: FinQuote].self, "fin-quotes") ?? [:]
    }

    func quote(_ k: FinKey) -> FinQuote? { quotes[k.id] }
    func error(_ k: FinKey) -> String? { errors[k.id] }

    /// Refresh loop for a visible tile; lives inside `.task(id:)` so it stops with the view.
    func keepFresh(_ keys: [FinKey], chart: Bool) async {
        guard let market = keys.first?.market else { return }
        while !Task.isCancelled {
            for k in keys where !Task.isCancelled { await ensure(k, chart: chart) }
            try? await Task.sleep(for: .seconds(market.interval))
        }
    }

    func ensure(_ k: FinKey, chart: Bool, force: Bool = false) async {
        guard !k.symbol.isEmpty, !inFlight.contains(k.id) else { return }
        let fresh = k.market.interval - 10
        if !force, let q = quotes[k.id], Date().timeIntervalSince(q.fetched) < fresh,
           !chart || Date().timeIntervalSince(chartFetched[k.id] ?? .distantPast) < fresh || (k.market == .stock && !q.points.isEmpty) {
            return
        }
        inFlight.insert(k.id)
        defer { inFlight.remove(k.id) }
        do {
            let q: FinQuote
            switch k.market {
            case .stock: q = try await Self.fetchYahoo(k.symbol, interval: "5m")
            case .crypto: q = try await fetchCrypto(k, chart: chart)
            }
            quotes[k.id] = q
            errors[k.id] = nil
            DiskCache.save(quotes, "fin-quotes")
        } catch {
            errors[k.id] = (error as? LocalizedError)?.errorDescription ?? L("Offline")
        }
    }

    /// Binance first; where it is blocked or unreachable, Yahoo Finance's `<SYM>-USD` pair (Binance is skipped for 30 min).
    private func fetchCrypto(_ k: FinKey, chart: Bool) async throws -> FinQuote {
        if Date() >= binanceRetry {
            do {
                var q = try await Self.fetchBinance(k.symbol)
                if chart {
                    q.points = (try? await Self.fetchKlines(k.symbol)) ?? quotes[k.id]?.points ?? []
                    chartFetched[k.id] = Date()
                } else {
                    q.points = quotes[k.id]?.points ?? []
                }
                return q
            } catch let e as FinError where e.invalidSymbol {
                // Not listed against USDT on Binance — Yahoo may still know it.
            } catch {
                binanceRetry = Date().addingTimeInterval(1800)
            }
        }
        var q = try await Self.fetchYahoo("\(k.symbol)-USD", interval: "15m")
        q.symbol = k.symbol
        q.name = Self.coinNames[k.symbol] ?? q.name.replacingOccurrences(of: " USD", with: "")
        chartFetched[k.id] = Date()
        return q
    }

    // MARK: Yahoo Finance

    private nonisolated static let browserUA = ["User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"]

    struct FinError: LocalizedError {
        var invalidSymbol = true
        var errorDescription: String? { L("Not found") }
    }

    /// Yahoo answers cookie-less browser user agents with 429 while the app's own agent
    /// (`Net.session` default) gets data, so the browser agent is only the last resort.
    nonisolated static let yahooAttempts: [(host: String, headers: [String: String])] = [
        ("query1.finance.yahoo.com", [:]), ("query2.finance.yahoo.com", [:]), ("query1.finance.yahoo.com", browserUA)
    ]

    private nonisolated static func fetchYahoo(_ symbol: String, interval: String) async throws -> FinQuote {
        let sym = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol
        var lastError: Error = FinError()
        for attempt in yahooAttempts {
            guard let url = URL(string: "https://\(attempt.host)/v8/finance/chart/\(sym)?range=1d&interval=\(interval)") else { continue }
            do {
                return try parseYahooChart(try await Net.json(url, headers: attempt.headers), symbol: symbol, fetched: Date())
            } catch let e as Net.HTTPError where e.status == 404 {
                throw e
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// `/v8/finance/chart` → quote. Change is against `chartPreviousClose`; null candles are skipped.
    nonisolated static func parseYahooChart(_ root: Any, symbol: String, fetched: Date) throws -> FinQuote {
        guard let chart = (root as? [String: Any])?["chart"] as? [String: Any],
              let result = (chart["result"] as? [[String: Any]])?.first,
              let meta = result["meta"] as? [String: Any],
              let price = num(meta["regularMarketPrice"]) else { throw FinError() }
        let quote = ((result["indicators"] as? [String: Any])?["quote"] as? [[String: Any]])?.first
        let closes = (quote?["close"] as? [Any])?.compactMap(num) ?? []
        let opens = (quote?["open"] as? [Any])?.compactMap(num) ?? []
        let prev = num(meta["chartPreviousClose"]) ?? num(meta["previousClose"]) ?? closes.first ?? price
        let change = price - prev
        let name = (meta["longName"] as? String) ?? (meta["shortName"] as? String) ?? symbol
        return FinQuote(symbol: symbol, name: name, price: price, change: change, percent: prev != 0 ? change / prev * 100 : 0,
                        open: opens.first, prevClose: prev, high: num(meta["regularMarketDayHigh"]), low: num(meta["regularMarketDayLow"]),
                        points: closes.isEmpty ? [prev, price] : closes, fetched: fetched)
    }

    // MARK: Binance (public market-data mirror as second host; short timeouts keep the fallback quick)

    private nonisolated static let binanceHosts = ["https://api.binance.com", "https://data-api.binance.vision"]

    private nonisolated static func binance(_ path: String) async throws -> Any {
        var lastError: Error = FinError(invalidSymbol: false)
        for host in binanceHosts {
            guard let url = URL(string: host + path) else { continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = 6
            do {
                let (data, response) = try await Net.session.data(for: req)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                if status == 400 { throw FinError() } // unknown symbol
                guard (200..<300).contains(status) else { throw Net.HTTPError(status: status, body: "") }
                return try JSONSerialization.jsonObject(with: data)
            } catch let e as FinError {
                throw e
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private nonisolated static func fetchBinance(_ symbol: String) async throws -> FinQuote {
        try parseBinanceTicker(try await binance("/api/v3/ticker/24hr?symbol=\(symbol)USDT"), symbol: symbol, fetched: Date())
    }

    /// `/api/v3/ticker/24hr` (decimal strings) → quote.
    nonisolated static func parseBinanceTicker(_ obj: Any, symbol: String, fetched: Date) throws -> FinQuote {
        guard let t = obj as? [String: Any], let price = num(t["lastPrice"]) else { throw FinError() }
        let change = num(t["priceChange"]) ?? 0
        return FinQuote(symbol: symbol, name: coinNames[symbol] ?? symbol, price: price, change: change,
                        percent: num(t["priceChangePercent"]) ?? 0, open: num(t["openPrice"]), prevClose: num(t["prevClosePrice"]),
                        high: num(t["highPrice"]), low: num(t["lowPrice"]), points: [], fetched: fetched)
    }

    private nonisolated static func fetchKlines(_ symbol: String) async throws -> [Double] {
        try parseKlines(try await binance("/api/v3/klines?symbol=\(symbol)USDT&interval=15m&limit=96"))
    }

    /// `/api/v3/klines` rows `[openTime, open, high, low, close, …]` → closes, oldest first.
    nonisolated static func parseKlines(_ obj: Any) throws -> [Double] {
        guard let rows = obj as? [[Any]] else { throw FinError() }
        return rows.compactMap { $0.count > 4 ? num($0[4]) : nil }
    }

    private nonisolated static func num(_ v: Any?) -> Double? {
        if let n = v as? NSNumber, !(v is NSNull) { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    nonisolated static let coinNames: [String: String] = [
        "BTC": "Bitcoin", "ETH": "Ethereum", "SOL": "Solana", "BNB": "BNB", "XRP": "XRP", "ADA": "Cardano", "DOGE": "Dogecoin",
        "TRX": "TRON", "TON": "Toncoin", "AVAX": "Avalanche", "DOT": "Polkadot", "LINK": "Chainlink", "MATIC": "Polygon",
        "POL": "Polygon", "LTC": "Litecoin", "SHIB": "Shiba Inu", "BCH": "Bitcoin Cash", "ATOM": "Cosmos", "XLM": "Stellar",
        "UNI": "Uniswap", "NEAR": "NEAR", "APT": "Aptos", "ARB": "Arbitrum", "OP": "Optimism", "SUI": "Sui", "PEPE": "Pepe",
        "ETC": "Ethereum Classic", "FIL": "Filecoin", "XMR": "Monero", "AAVE": "Aave", "USDC": "USD Coin"
    ]
}

/// Number formatting shared by the finance tiles. Signed strings are wrapped in an LTR embedding so
/// "+3.29 (+1.12%)" keeps its sign on the left inside right-to-left layouts.
enum FinFormat {
    static func decimals(_ price: Double) -> Int {
        let a = abs(price)
        return a >= 1 ? 2 : a >= 0.01 ? 4 : 6
    }

    static func price(_ q: FinQuote) -> String { Fmt.number(q.price, decimals: decimals(q.price)) }
    static func value(_ v: Double, like q: FinQuote) -> String { Fmt.number(v, decimals: decimals(q.price)) }
    static func percent(_ q: FinQuote) -> String { ltr(Fmt.signedPercent(q.percent)) }
    static func change(_ q: FinQuote) -> String {
        ltr(Fmt.signed(q.change, decimals: decimals(q.price)) + " (" + Fmt.signedPercent(q.percent) + ")")
    }
    static func ltr(_ s: String) -> String { "\u{202A}" + s + "\u{202C}" }
}
