import Foundation
import Testing
@testable import CoolDock

/// The network-backed widgets end to end against the real services: weather (Open-Meteo geocoding + forecast),
/// stocks (Yahoo Finance), crypto (Binance, falling back to Yahoo's `<SYM>-USD` pair) and currency rates
/// (Frankfurter, falling back to open.er-api.com). Drives the same service objects the tiles use.
/// Opt-in because it needs the internet: `COOLDOCK_LIVE_NET=1 swift test --filter NetworkLive`.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["COOLDOCK_LIVE_NET"] == "1"))
struct NetworkLiveTests {
    @Test func weatherForANamedCity() async throws {
        let weather = WeatherService.shared
        await weather.ensure("Tehran", force: true)
        #expect(weather.error("Tehran") == nil, "weather error: \(weather.error("Tehran") ?? "")")
        let s = try #require(weather.snapshot("Tehran"))
        #expect(s.place.localizedCaseInsensitiveContains("Tehran"))
        #expect((-60...60).contains(s.temp) && (0...100).contains(s.humidity) && s.windSpeed >= 0)
        #expect(s.hours.count >= 12 && s.days.count >= 5)
        #expect(s.today?.sunrise != nil && s.today?.sunset != nil)
        print("NetworkLive weather: \(s.place) \(s.temp) °C, code \(s.code), \(s.hours.count) hours, \(s.days.count) days, tz \(s.timeZone)")
    }

    @Test func stockQuoteWithIntradayChart() async throws {
        let fin = FinService.shared
        let key = FinKey(.stock, "AAPL")
        await fin.ensure(key, chart: true, force: true)
        #expect(fin.error(key) == nil, "stock error: \(fin.error(key) ?? "")")
        let q = try #require(fin.quote(key))
        #expect(q.price > 0 && q.points.count > 1)
        print("NetworkLive stock: \(q.symbol) \(q.name) \(q.price) (\(String(format: "%+.2f", q.percent)) %), \(q.points.count) points")
    }

    @Test func cryptoQuoteWithChart() async throws {
        let fin = FinService.shared
        let key = FinKey(.crypto, "BTC")
        await fin.ensure(key, chart: true, force: true)
        #expect(fin.error(key) == nil, "crypto error: \(fin.error(key) ?? "")")
        let q = try #require(fin.quote(key))
        #expect(q.price > 1000 && q.name == "Bitcoin" && q.points.count > 1)
        print("NetworkLive crypto: \(q.symbol) \(q.price) (\(String(format: "%+.2f", q.percent)) %), \(q.points.count) points")
    }

    @Test func currencyRate() async throws {
        let r = try await UtilFX.rate("USD", "EUR")
        #expect((0.5...1.5).contains(r))
        print("NetworkLive fx: 1 USD = \(r) EUR")
    }
}
