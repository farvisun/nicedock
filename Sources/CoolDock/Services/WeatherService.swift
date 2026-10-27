import CoreLocation
import Foundation
import Observation

struct WeatherSnapshot: Codable, Equatable {
    struct Hour: Codable, Equatable { var time: Date; var temp: Double; var code: Int; var isDay: Bool; var precipChance: Int }
    struct Day: Codable, Equatable { var date: Date; var high: Double; var low: Double; var code: Int; var sunrise: Date?; var sunset: Date?; var precip: Double }

    var place: String
    var fetched: Date
    var timeZone: String
    var temp: Double
    var feelsLike: Double
    var code: Int
    var isDay: Bool
    var humidity: Int
    var windSpeed: Double // km/h
    var windDirection: Double
    var windGusts: Double
    var precipitation: Double // mm
    var hours: [Hour]
    var days: [Day]

    var today: Day? { days.first }
}

/// Open-Meteo backed weather with location resolution, caching and demand-driven refresh.
@Observable
@MainActor
final class WeatherService: NSObject, CLLocationManagerDelegate {
    static let shared = WeatherService()

    private(set) var snapshots: [String: WeatherSnapshot] = [:]
    private(set) var errors: [String: String] = [:]
    private(set) var locationDenied = false

    @ObservationIgnored private var inFlight = Set<String>()
    @ObservationIgnored private var geocoded: [String: (lat: Double, lon: Double, name: String)] = [:]
    @ObservationIgnored private var manager: CLLocationManager?
    @ObservationIgnored private var current: (lat: Double, lon: Double, name: String)?
    @ObservationIgnored private var locationWaiters: [CheckedContinuation<(Double, Double, String)?, Never>] = []

    private let refreshInterval: TimeInterval = 30 * 60

    override init() {
        super.init()
        if !ReferenceScene.isActive, let cached = DiskCache.load([String: WeatherSnapshot].self, "weather") { snapshots = cached }
    }

    var unit: TemperatureUnit { AppStore.shared.settings.temperatureUnit.resolved }

    func snapshot(_ city: String) -> WeatherSnapshot? { snapshots[key(city)] }
    func error(_ city: String) -> String? { errors[key(city)] }

    private func key(_ city: String) -> String { city.trimmingCharacters(in: .whitespaces).lowercased() }

    /// Fetches if missing or stale. Call from `.task`.
    func ensure(_ city: String, force: Bool = false) async {
        guard !ReferenceScene.isActive else { return }
        let k = key(city)
        if !force, let s = snapshots[k], Date().timeIntervalSince(s.fetched) < refreshInterval { return }
        guard !inFlight.contains(k) else { return }
        inFlight.insert(k)
        defer { inFlight.remove(k) }
        do {
            guard let loc = try await resolve(city) else {
                errors[k] = L("Location unavailable")
                return
            }
            let snap = try await fetch(lat: loc.lat, lon: loc.lon, name: loc.name)
            snapshots[k] = snap
            errors[k] = nil
            DiskCache.save(snapshots, "weather")
        } catch {
            errors[k] = (error as? LocalizedError)?.errorDescription ?? L("Offline")
        }
    }

    /// Long-lived refresh loop for a widget; cancelled automatically with the view's task.
    func keepFresh(_ city: String) async {
        while !Task.isCancelled {
            await ensure(city)
            try? await Task.sleep(for: .seconds(refreshInterval / 2))
        }
    }

    /// Deterministic conditions for `--scene reference` renders; nothing is fetched or cached there.
    func setSceneSnapshot(_ snapshot: WeatherSnapshot, city: String = "") {
        guard ReferenceScene.isActive else { return }
        snapshots[key(city)] = snapshot
        errors[key(city)] = nil
    }

    // MARK: Location

    private func resolve(_ city: String) async throws -> (lat: Double, lon: Double, name: String)? {
        let trimmed = city.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            if let current { return current }
            if !RenderHarness.isActive, let loc = await currentLocation() { current = loc; return loc }
            return try await ipLocation()
        }
        if let hit = geocoded[trimmed.lowercased()] { return hit }
        // Accept "lat,lon" directly.
        let parts = trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 2, let lat = Double(parts[0]), let lon = Double(parts[1]) { return (lat, lon, trimmed) }
        var comps = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        let lang = Localizer.language == .fa ? "fa" : Localizer.language.rawValue.prefix(2).description
        comps.queryItems = [.init(name: "name", value: trimmed), .init(name: "count", value: "1"), .init(name: "language", value: lang)]
        let obj = try await Net.json(comps.url!) as? [String: Any]
        guard let first = (obj?["results"] as? [[String: Any]])?.first,
              let lat = first["latitude"] as? Double, let lon = first["longitude"] as? Double else { return nil }
        let result = (lat, lon, (first["name"] as? String) ?? trimmed)
        geocoded[trimmed.lowercased()] = result
        return result
    }

    private func ipLocation() async throws -> (lat: Double, lon: Double, name: String)? {
        let obj = try await Net.json(URL(string: "https://ipwho.is/")!) as? [String: Any]
        guard let lat = obj?["latitude"] as? Double, let lon = obj?["longitude"] as? Double else { return nil }
        let r = (lat, lon, (obj?["city"] as? String) ?? "")
        current = r
        return r
    }

    private func currentLocation() async -> (lat: Double, lon: Double, name: String)? {
        let m = manager ?? CLLocationManager()
        manager = m
        m.delegate = self
        m.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        switch m.authorizationStatus {
        case .denied, .restricted:
            locationDenied = true
            return nil
        case .notDetermined:
            m.requestWhenInUseAuthorization()
        default: break
        }
        return await withCheckedContinuation { cont in
            locationWaiters.append(cont)
            m.requestLocation()
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.finishLocation(nil) }
        }.map { (lat: $0.0, lon: $0.1, name: $0.2) }
    }

    private func finishLocation(_ value: (Double, Double, String)?) {
        let waiters = locationWaiters
        locationWaiters.removeAll()
        waiters.forEach { $0.resume(returning: value) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        CLGeocoder().reverseGeocodeLocation(loc) { marks, _ in
            let name = marks?.first?.locality ?? marks?.first?.name ?? ""
            Task { @MainActor in self.finishLocation((loc.coordinate.latitude, loc.coordinate.longitude, name)) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finishLocation(nil) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.locationDenied = status == .denied || status == .restricted
            if status == .authorizedAlways { manager.requestLocation() }
        }
    }

    // MARK: Fetch

    private func fetch(lat: Double, lon: Double, name: String) async throws -> WeatherSnapshot {
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            .init(name: "latitude", value: String(lat)), .init(name: "longitude", value: String(lon)),
            .init(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,is_day,wind_speed_10m,wind_direction_10m,wind_gusts_10m,precipitation"),
            .init(name: "hourly", value: "temperature_2m,weather_code,is_day,precipitation_probability"),
            .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,sunrise,sunset,precipitation_sum"),
            .init(name: "timezone", value: "auto"), .init(name: "forecast_days", value: "7"), .init(name: "timeformat", value: "unixtime")
        ]
        guard let obj = try await Net.json(comps.url!) as? [String: Any],
              let cur = obj["current"] as? [String: Any] else { throw Net.HTTPError(status: 0, body: "") }
        let tz = obj["timezone"] as? String ?? TimeZone.current.identifier
        func num(_ d: [String: Any]?, _ k: String) -> Double { (d?[k] as? NSNumber)?.doubleValue ?? 0 }
        func arr(_ d: [String: Any]?, _ k: String) -> [Double] { (d?[k] as? [Any])?.map { ($0 as? NSNumber)?.doubleValue ?? 0 } ?? [] }

        let hourly = obj["hourly"] as? [String: Any]
        let hTimes = arr(hourly, "time"), hTemp = arr(hourly, "temperature_2m"), hCode = arr(hourly, "weather_code")
        let hDay = arr(hourly, "is_day"), hProb = arr(hourly, "precipitation_probability")
        let now = Date().timeIntervalSince1970 - 3600
        var hours: [WeatherSnapshot.Hour] = []
        for i in hTimes.indices where hTimes[i] >= now && hours.count < 24 {
            hours.append(.init(time: Date(timeIntervalSince1970: hTimes[i]), temp: hTemp[safe: i] ?? 0, code: Int(hCode[safe: i] ?? 0),
                               isDay: (hDay[safe: i] ?? 1) > 0, precipChance: Int(hProb[safe: i] ?? 0)))
        }
        let daily = obj["daily"] as? [String: Any]
        let dTimes = arr(daily, "time"), dMax = arr(daily, "temperature_2m_max"), dMin = arr(daily, "temperature_2m_min")
        let dCode = arr(daily, "weather_code"), dRise = arr(daily, "sunrise"), dSet = arr(daily, "sunset"), dPrec = arr(daily, "precipitation_sum")
        let days = dTimes.indices.map { i in
            WeatherSnapshot.Day(date: Date(timeIntervalSince1970: dTimes[i]), high: dMax[safe: i] ?? 0, low: dMin[safe: i] ?? 0, code: Int(dCode[safe: i] ?? 0),
                                sunrise: dRise[safe: i].map { Date(timeIntervalSince1970: $0) }, sunset: dSet[safe: i].map { Date(timeIntervalSince1970: $0) },
                                precip: dPrec[safe: i] ?? 0)
        }
        return WeatherSnapshot(place: name, fetched: Date(), timeZone: tz, temp: num(cur, "temperature_2m"), feelsLike: num(cur, "apparent_temperature"),
                               code: Int(num(cur, "weather_code")), isDay: num(cur, "is_day") > 0, humidity: Int(num(cur, "relative_humidity_2m")),
                               windSpeed: num(cur, "wind_speed_10m"), windDirection: num(cur, "wind_direction_10m"), windGusts: num(cur, "wind_gusts_10m"),
                               precipitation: num(cur, "precipitation"), hours: hours, days: days)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// WMO weather interpretation codes → SF Symbols and localized descriptions.
enum WeatherCode {
    static func symbol(_ code: Int, isDay: Bool = true) -> String {
        switch code {
        case 0: return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1: return isDay ? "sun.min.fill" : "moon.fill"
        case 2: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51, 53, 55, 56, 57: return "cloud.drizzle.fill"
        case 61, 63, 80, 81: return isDay ? "cloud.rain.fill" : "cloud.moon.rain.fill"
        case 65, 82: return "cloud.heavyrain.fill"
        case 66, 67: return "cloud.sleet.fill"
        case 71, 73, 75, 77, 85, 86: return "cloud.snow.fill"
        case 95: return "cloud.bolt.rain.fill"
        case 96, 99: return "cloud.bolt.fill"
        default: return "cloud.fill"
        }
    }

    static func title(_ code: Int) -> String {
        switch code {
        case 0: return L("Clear Sky")
        case 1: return L("Mostly Clear")
        case 2: return L("Partly Cloudy")
        case 3: return L("Cloudy")
        case 45, 48: return L("Fog")
        case 51, 53, 55: return L("Drizzle")
        case 56, 57: return L("Freezing Drizzle")
        case 61, 80: return L("Light Rain")
        case 63, 81: return L("Rain")
        case 65, 82: return L("Heavy Rain")
        case 66, 67: return L("Freezing Rain")
        case 71, 85: return L("Light Snow")
        case 73, 75, 86: return L("Snow")
        case 77: return L("Snow Grains")
        case 95: return L("Thunderstorm")
        case 96, 99: return L("Thunderstorm & Hail")
        default: return L("Cloudy")
        }
    }

    static func compass(_ degrees: Double) -> String {
        let dirs = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let i = Int((degrees + 22.5).truncatingRemainder(dividingBy: 360) / 45)
        return L(dirs[max(0, min(7, i))])
    }
}

extension Fmt {
    @MainActor static func temp(_ celsius: Double) -> String {
        temperature(celsius, unit: AppStore.shared.settings.temperatureUnit.resolved)
    }

    @MainActor static func speed(_ kmh: Double) -> String {
        if AppStore.shared.settings.temperatureUnit.resolved == .fahrenheit {
            return int(Int((kmh / 1.609).rounded())) + " " + L("mph")
        }
        return int(Int(kmh.rounded())) + " " + L("km/h")
    }
}
