import Foundation
import Testing
@testable import CoolDock

/// Real Open-Meteo and ipwho.is responses captured with curl on 2026-10-27, using the exact query
/// the app sends (`WeatherService.fetch` / `resolve`).
@Suite struct WeatherTests {
    let forecastFile = "openmeteo/forecast-berlin-2026-10-27.json"

    @Test func forecastCurrentConditions() throws {
        let raw = try Fixture.object(forecastFile)
        let current = try #require(raw["current"] as? [String: Any])
        let now = Date(timeIntervalSince1970: try #require(current["time"] as? Double))
        let snap = try WeatherService.parseForecast(raw, name: "Berlin", now: now)

        #expect(snap.place == "Berlin")
        #expect(snap.timeZone == "Europe/Berlin")
        #expect(snap.fetched == now)
        // Values straight from the fixture's `current` block.
        #expect(snap.temp == current["temperature_2m"] as? Double)
        #expect(snap.temp == 7.5)
        #expect(snap.feelsLike == 4.8)
        #expect(snap.humidity == 80)
        #expect(snap.code == 3)
        #expect(snap.isDay == false)
        #expect(snap.windSpeed == 8.7)
        #expect(snap.windDirection == 187)
        #expect(snap.windGusts == 18)
        #expect(snap.precipitation == 0)
    }

    @Test func forecastHoursStartAnHourBeforeNow() throws {
        let raw = try Fixture.object(forecastFile)
        let current = try #require(raw["current"] as? [String: Any])
        let now = Date(timeIntervalSince1970: try #require(current["time"] as? Double))
        let snap = try WeatherService.parseForecast(raw, name: "Berlin", now: now)

        let hourly = try #require(raw["hourly"] as? [String: Any])
        let times = try #require(hourly["time"] as? [Double])
        let temps = try #require(hourly["temperature_2m"] as? [Double])
        let probs = try #require(hourly["precipitation_probability"] as? [Double])
        let first = try #require(times.firstIndex { $0 >= now.timeIntervalSince1970 - 3600 })

        #expect(snap.hours.count == 24)
        for (k, hour) in snap.hours.enumerated() {
            #expect(hour.time == Date(timeIntervalSince1970: times[first + k]))
            #expect(hour.temp == temps[first + k])
            #expect(hour.precipChance == Int(probs[first + k]))
        }
        #expect(snap.hours.first!.time.timeIntervalSince(now) >= -3600)
        // Hourly steps are exactly one hour apart.
        #expect(zip(snap.hours, snap.hours.dropFirst()).allSatisfy { $1.time.timeIntervalSince($0.time) == 3600 })
    }

    @Test func forecastSevenDays() throws {
        let raw = try Fixture.object(forecastFile)
        let snap = try WeatherService.parseForecast(raw, name: "Berlin", now: Date(timeIntervalSince1970: 1_793_060_100))
        let daily = try #require(raw["daily"] as? [String: Any])

        #expect(snap.days.count == 7)
        #expect(snap.days.map(\.high) == daily["temperature_2m_max"] as? [Double])
        #expect(snap.days.map(\.low) == daily["temperature_2m_min"] as? [Double])
        #expect(snap.days.map(\.code) == (daily["weather_code"] as? [Int]))
        #expect(snap.days.map(\.precip) == daily["precipitation_sum"] as? [Double])
        #expect(snap.days.map { $0.sunrise!.timeIntervalSince1970 } == daily["sunrise"] as? [Double])
        #expect(snap.days.map { $0.sunset!.timeIntervalSince1970 } == daily["sunset"] as? [Double])
        #expect(snap.today?.high == 14.8 && snap.today?.low == 7.3)
        // Sunrise before sunset, both on the forecast day.
        for day in snap.days {
            #expect(day.sunrise! > day.date && day.sunset! > day.sunrise! && day.sunset!.timeIntervalSince(day.date) < 86_400)
        }
    }

    @Test func forecastWithoutCurrentBlockFails() {
        #expect(throws: (any Error).self) { try WeatherService.parseForecast(["hourly": [:]], name: "", now: Date()) }
    }

    @Test func geocodingFirstMatch() throws {
        let berlin = try #require(WeatherService.parseGeocoding(try Fixture.json("openmeteo/geocoding-berlin-2026-10-27.json"), fallbackName: "berlin"))
        #expect(berlin.lat == 52.52437 && berlin.lon == 13.41053 && berlin.name == "Berlin")

        let tokyo = try #require(WeatherService.parseGeocoding(try Fixture.json("openmeteo/geocoding-tokyo-ja-2026-10-27.json"), fallbackName: "Tokyo"))
        #expect(tokyo.name == "東京都" && tokyo.lat == 35.6895 && tokyo.lon == 139.69171)

        // No match: the API omits `results` entirely.
        #expect(WeatherService.parseGeocoding(try Fixture.json("openmeteo/geocoding-nowhere-2026-10-27.json"), fallbackName: "x") == nil)
    }

    @Test func ipLocation() throws {
        let loc = try #require(WeatherService.parseIPLocation(try Fixture.json("ipwhois/ipwhois-8.8.8.8-2026-10-27.json")))
        #expect(loc.lat == 37.3393939 && loc.lon == -121.8949553 && loc.name == "San Jose")
    }
}
