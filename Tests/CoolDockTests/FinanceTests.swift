import Foundation
import Testing
@testable import CoolDock

/// Real Yahoo Finance `/v8/finance/chart` and Binance `/api/v3` responses captured with curl on
/// 2026-10-27 using the app's URLs (Yahoo with the app's own `CoolDock/1.0 (macOS)` user agent —
/// the Safari agent the app used to send got HTTP 429 from both Yahoo hosts).
@Suite struct FinanceTests {
    static let symbols = ["AAPL", "MSFT", "NVDA", "BTC-USD", "ETH-USD"]

    @Test(arguments: symbols)
    func yahooChartMatchesFixtureMeta(_ symbol: String) throws {
        let raw = try Fixture.json("yahoo/chart-\(symbol)-2026-10-27.json")
        let result = try #require((((raw as? [String: Any])?["chart"] as? [String: Any])?["result"] as? [[String: Any]])?.first)
        let meta = try #require(result["meta"] as? [String: Any])
        let quote = try #require(((result["indicators"] as? [String: Any])?["quote"] as? [[String: Any]])?.first)
        let closes = (quote["close"] as? [Any] ?? []).compactMap { $0 as? Double }
        let opens = (quote["open"] as? [Any] ?? []).compactMap { $0 as? Double }
        let fetched = Date(timeIntervalSince1970: 1_793_060_000)

        let q = try FinService.parseYahooChart(raw, symbol: symbol, fetched: fetched)
        let price = try #require(meta["regularMarketPrice"] as? Double)
        let prev = try #require(meta["chartPreviousClose"] as? Double)
        #expect(q.symbol == symbol)
        #expect(q.price == price)
        #expect(q.prevClose == prev)
        #expect(q.change.near(price - prev))
        #expect(q.percent.near((price - prev) / prev * 100))
        #expect(q.name == meta["longName"] as? String)
        #expect(q.high == meta["regularMarketDayHigh"] as? Double)
        #expect(q.low == meta["regularMarketDayLow"] as? Double)
        #expect(q.open == opens.first)
        #expect(q.points == closes && !closes.isEmpty)
        #expect(q.fetched == fetched)
    }

    @Test func yahooSpecificValues() throws {
        let aapl = try FinService.parseYahooChart(try Fixture.json("yahoo/chart-AAPL-2026-10-27.json"), symbol: "AAPL", fetched: Date())
        #expect(aapl.price == 343.91 && aapl.prevClose == 347.725 && aapl.name == "Apple Inc.")
        #expect(aapl.change.near(-3.815, 1e-9) && !aapl.isUp)
        #expect(aapl.points.count == 79) // 5-minute candles of a full session

        let nvda = try FinService.parseYahooChart(try Fixture.json("yahoo/chart-NVDA-2026-10-27.json"), symbol: "NVDA", fetched: Date())
        #expect(nvda.price == 216 && nvda.isUp && nvda.percent.near((216 - 210.96) / 210.96 * 100))

        let btc = try FinService.parseYahooChart(try Fixture.json("yahoo/chart-BTC-USD-2026-10-27.json"), symbol: "BTC-USD", fetched: Date())
        #expect(btc.price == 80133.53 && btc.name == "Bitcoin USD")
    }

    @Test func yahooUnknownSymbolThrows() throws {
        // {"chart":{"result":null,"error":{"code":"Not Found",…}}} (served with HTTP 404)
        #expect(throws: FinService.FinError.self) {
            try FinService.parseYahooChart(try Fixture.json("yahoo/chart-NOTASYMBOLX-2026-10-27.json"), symbol: "NOTASYMBOLX", fetched: Date())
        }
    }

    @Test func yahooPrefersAppUserAgent() {
        // First attempts must not override the session's own User-Agent (see suite comment).
        #expect(FinService.yahooAttempts.first?.headers.isEmpty == true)
        #expect(FinService.yahooAttempts.filter { $0.headers.isEmpty }.map(\.host) == ["query1.finance.yahoo.com", "query2.finance.yahoo.com"])
    }

    @Test(arguments: ["binance/ticker24hr-BTCUSDT-2026-10-27.json", "binance/vision-ticker24hr-BTCUSDT-2026-10-27.json"])
    func binanceTickerMatchesFixture(_ file: String) throws {
        let raw = try #require(try Fixture.json(file) as? [String: Any])
        func field(_ k: String) -> Double? { (raw[k] as? String).flatMap(Double.init) }
        let q = try FinService.parseBinanceTicker(raw, symbol: "BTC", fetched: Date(timeIntervalSince1970: 1_793_060_000))
        #expect(q.price == field("lastPrice") && q.price == 80294.39)
        #expect(q.change == field("priceChange"))
        #expect(q.percent == field("priceChangePercent"))
        #expect(q.open == field("openPrice") && q.prevClose == field("prevClosePrice"))
        #expect(q.high == field("highPrice") && q.low == field("lowPrice"))
        #expect(q.name == "Bitcoin" && q.symbol == "BTC" && q.points.isEmpty)
    }

    @Test func binanceTickerValues() throws {
        // api.binance.com (reachable from this network on 2026-10-27).
        let q = try FinService.parseBinanceTicker(try Fixture.json("binance/ticker24hr-BTCUSDT-2026-10-27.json"), symbol: "BTC", fetched: Date())
        #expect(q.change == 74.6 && q.percent == 0.093 && q.isUp)
        #expect(q.open == 80219.79 && q.prevClose == 80219.8 && q.high == 80844.7 && q.low == 79368.67)
    }

    @Test func binanceKlinesCloseColumn() throws {
        let raw = try Fixture.json("binance/vision-klines-BTCUSDT-2026-10-27.json")
        let rows = try #require(raw as? [[Any]])
        let closes = try FinService.parseKlines(raw)
        #expect(closes.count == 96)
        #expect(closes == rows.map { Double($0[4] as! String)! })
        // Fetched seconds apart: the newest 15-minute candle closes at the ticker's last price.
        #expect(closes.last == 80294.39)
    }

    @Test func binanceInvalidSymbol() throws {
        // HTTP 400 {"code":-1121,"msg":"Invalid symbol."}
        #expect(throws: FinService.FinError.self) {
            try FinService.parseBinanceTicker(try Fixture.json("binance/vision-ticker24hr-NOPECOINUSDT-2026-10-27.json"), symbol: "NOPECOIN", fetched: Date())
        }
    }
}
