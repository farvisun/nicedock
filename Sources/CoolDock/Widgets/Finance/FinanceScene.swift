import Foundation

/// Reference-scene data for this family (see `ReferenceScene`). Returns nil for kinds it doesn't own.
///
/// Seeds `FinService` with fixed quotes; in the scene `FinService.ensure` never touches the network.
enum FinanceScene {
    @MainActor static func prepare(_ kind: WidgetKind, _ variant: String?) -> [String: String]? {
        switch kind {
        case .stockQuote, .stockChart:
            seed([aapl], .stock)
            return ["symbol": "AAPL"]
        case .stockWatchlist:
            seed([aapl, quote("MSFT", "Microsoft Corporation", 378.91, percent: -3.79),
                  quote("NVDA", "NVIDIA Corporation", 204.65, percent: 0.51)], .stock)
            return ["symbols": "AAPL\nMSFT\nNVDA"]
        case .cryptoQuote, .cryptoChart, .cryptoWatchlist:
            seed([quote("BTC", "Bitcoin", 104_250, percent: 1.84, points: wave(104_250, 0.012)),
                  quote("ETH", "Ethereum", 3_912.4, percent: -0.62, points: wave(3_912.4, -0.008)),
                  quote("SOL", "Solana", 171.25, percent: 2.41, points: wave(171.25, 0.02))], .crypto)
            return kind == .cryptoWatchlist ? ["symbols": "BTC\nETH\nSOL"] : ["symbol": kind == .cryptoQuote ? "BTC" : "ETH"]
        default:
            return nil
        }
    }

    /// Intraday AAPL closes traced from the reference chart (opens high, dips, recovers, drifts to the close).
    private static let aaplPoints: [Double] = [
        298.21, 298.00, 297.83, 297.62, 297.39, 297.12, 297.05, 297.24, 297.49, 297.76, 297.98, 297.94, 297.67, 297.38,
        297.07, 296.77, 296.50, 296.28, 296.07, 295.99, 296.11, 296.08, 295.92, 295.78, 295.86, 296.04, 296.00, 295.95
    ]

    private static var aapl: FinQuote { quote("AAPL", "Apple Inc.", 295.95, percent: 1.12, change: 3.29, points: aaplPoints) }

    private static func quote(_ symbol: String, _ name: String, _ price: Double, percent: Double, change: Double? = nil,
                              points: [Double] = []) -> FinQuote {
        let prev = price / (1 + percent / 100)
        let pts = points.isEmpty ? [prev, price] : points
        return FinQuote(symbol: symbol, name: name, price: price, change: change ?? price - prev, percent: percent,
                        open: pts.first, prevClose: prev, high: pts.max(), low: pts.min(), points: pts, fetched: ReferenceScene.now)
    }

    /// A calm deterministic intraday path ending at `price` (`drift` = relative change across the day).
    private static func wave(_ price: Double, _ drift: Double) -> [Double] {
        (0..<24).map { i in
            let t = Double(i) / 23
            return price * (1 - drift * (1 - t) + 0.004 * sin(t * 9) * (1 - t))
        }
    }

    @MainActor private static func seed(_ quotes: [FinQuote], _ market: FinMarket) {
        FinService.shared.seedScene(quotes.map { (FinKey(market, $0.symbol), $0) })
    }
}
