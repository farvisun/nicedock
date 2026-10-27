import AppKit
import Foundation
import SwiftUI
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

/// The 15 network tiles drawn with the data the services just fetched, from this (firewall-allowed) test process.
/// `COOLDOCK_LIVE_NET=1 COOLDOCK_EVIDENCE_DIR=<dir> swift test --filter NetworkTilesLive` writes one PNG per tile
/// (same 2× ImageRenderer path and 8-bit sRGB output as `--render`).
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["COOLDOCK_LIVE_NET"] == "1"
                         && ProcessInfo.processInfo.environment["COOLDOCK_EVIDENCE_DIR"] != nil))
struct NetworkTilesLiveTests {
    static let kinds: [WidgetKind] = [.weatherCompact, .weatherHero, .weatherLocation, .forecastDays, .weatherToday, .weatherCondition,
                                      .forecastHourly, .sunriseSunset, .wind, .stockQuote, .stockChart, .stockWatchlist,
                                      .cryptoQuote, .cryptoChart, .cryptoWatchlist]

    @Test func tilesShowLiveData() async throws {
        let dir = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["COOLDOCK_EVIDENCE_DIR"]))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        AppStore.persistenceEnabled = false
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        DockFonts.registerBundledFonts()
        let store = AppStore.shared

        let city = "Tehran"
        await WeatherService.shared.ensure(city, force: true)
        let weather = try #require(WeatherService.shared.snapshot(city))
        let symbols: [(FinMarket, String)] = [(.stock, "AAPL"), (.stock, "MSFT"), (.stock, "NVDA"), (.crypto, "BTC"), (.crypto, "ETH"), (.crypto, "SOL")]
        for (market, symbol) in symbols { await FinService.shared.ensure(FinKey(market, symbol), chart: true, force: true) }
        for (market, symbol) in symbols {
            let k = FinKey(market, symbol)
            #expect(FinService.shared.quote(k) != nil, "\(symbol): \(FinService.shared.error(k) ?? "no quote")")
        }

        // Mount like the dock does so each tile's loaders run, then draw.
        let instances = Self.kinds.map { kind -> WidgetInstance in
            switch kind {
            case .stockQuote, .stockChart: return WidgetInstance(kind: kind, config: ["symbol": "AAPL"])
            case .cryptoQuote, .cryptoChart: return WidgetInstance(kind: kind, config: ["symbol": "BTC"])
            case .stockWatchlist, .cryptoWatchlist: return WidgetInstance(kind: kind)
            default: return WidgetInstance(kind: kind, config: ["city": city])
            }
        }
        let mount = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 4000, height: 200), styleMask: .borderless, backing: .buffered, defer: false)
        mount.contentView = NSHostingView(rootView: HStack(spacing: 6) { ForEach(instances) { WidgetHost(instance: $0) } }
            .environment(\.palette, store.palette).environment(\.metrics, store.metrics))
        mount.orderFrontRegardless()
        defer { mount.contentView = nil; mount.close() }
        try await Task.sleep(for: .seconds(4))

        for w in instances {
            let view = WidgetHost(instance: w)
                .background(Color(red: 11 / 255, green: 11 / 255, blue: 11 / 255))
                .environment(\.palette, store.palette)
                .environment(\.metrics, store.metrics)
                .environment(\.layoutDirection, store.layoutDirection)
                .environment(\.locale, Fmt.locale)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let cg = try #require(renderer.cgImage)
            try #require(RenderHarness.png(cg)).write(to: dir.appendingPathComponent("\(w.kind.rawValue).png"))
        }
        print("NetworkTilesLive: \(instances.count) tiles, weather \(weather.place) \(weather.temp) °C → \(dir.path)")
    }
}
