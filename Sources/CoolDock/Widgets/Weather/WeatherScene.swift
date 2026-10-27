import Foundation

/// Reference-scene data for this family (see `ReferenceScene`). Returns nil for kinds it doesn't own.
///
/// The frames show one mock forecast: 21° and partly cloudy, light SW wind, a Sunday with sunrise 6:12 and
/// sunset 20:18, the hours from 21:00 cooling by a degree each, and Mon 22° cloudy / Tue 19° rain / Wed 21°.
enum WeatherScene {
    @MainActor static func prepare(_ kind: WidgetKind, _ variant: String?) -> [String: String]? {
        switch kind {
        case .weatherCompact, .weatherLocation, .weatherToday, .forecastDays, .forecastHourly, .sunriseSunset, .wind:
            // Sunday evening, just after sunset, so the arc shows no sun and the hourly strip starts at 21:00.
            ReferenceScene.now = at(2026, 6, 21, 20, 30)
            seed()
        case .weatherCondition:
            seed(code: 63)
        case .dateTimeWeather:
            // The frame reads "Jun 24, Saturday 14:32" (a Saturday in 2023).
            ReferenceScene.now = at(2023, 6, 24, 14, 32)
            seed()
        default:
            return nil
        }
        return [:]
    }

    /// Injects the mock conditions for the default (current-location) city. `code` is the WMO weather code.
    @MainActor static func seed(code: Int = 2) {
        if AppStore.shared.settings.temperatureUnit.resolved != .celsius { AppStore.shared.settings.temperatureUnit = .celsius }
        let day0 = at(2026, 6, 21, 0, 0)
        func day(_ i: Int, _ high: Double, _ code: Int) -> WeatherSnapshot.Day {
            let d = Calendar.current.date(byAdding: .day, value: i, to: day0) ?? day0
            return .init(date: d, high: high, low: high - 8, code: code, sunrise: d.addingTimeInterval(6 * 3600 + 12 * 60),
                         sunset: d.addingTimeInterval(20 * 3600 + 18 * 60), precip: 0)
        }
        let days = [day(0, 24, 2), day(1, 22, 3), day(2, 19, 63), day(3, 21, 2), day(4, 23, 1), day(5, 24, 0), day(6, 22, 2)]
        let firstHour = at(2026, 6, 21, 21, 0)
        let hours: [WeatherSnapshot.Hour] = (0..<24).map { (i: Int) -> WeatherSnapshot.Hour in
            let time = firstHour.addingTimeInterval(Double(i) * 3600)
            let temp = Double(20 - min(i, 8))
            return WeatherSnapshot.Hour(time: time, temp: temp, code: i % 2 == 0 ? 3 : 2, isDay: true, precipChance: 0)
        }
        let snap = WeatherSnapshot(place: "Location", fetched: ReferenceScene.now, timeZone: TimeZone.current.identifier, temp: 21, feelsLike: 21,
                                   code: code, isDay: true, humidity: 60, windSpeed: 18, windDirection: 225, windGusts: 28, precipitation: 0,
                                   hours: hours, days: days)
        WeatherService.shared.setSceneSnapshot(snap)
    }

    static func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi)) ?? ReferenceScene.defaultNow
    }
}
