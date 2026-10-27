import SwiftUI

/// Services that only do work while something on screen needs them.
@MainActor
protocol DemandDriven: AnyObject {
    func subscribe(_ id: String)
    func unsubscribe(_ id: String)
}

extension SystemMonitor: DemandDriven {}

private struct DemandModifier: ViewModifier {
    let service: DemandDriven
    @State private var token = UUID().uuidString

    func body(content: Content) -> some View {
        content
            .onAppear { service.subscribe(token) }
            .onDisappear { service.unsubscribe(token) }
    }
}

extension View {
    /// Keeps `service` running while this view is on screen.
    func demand(_ service: DemandDriven) -> some View { modifier(DemandModifier(service: service)) }

    /// Calls `action` when the user picks Refresh for this widget (or a global refresh).
    func onWidgetRefresh(_ id: UUID, perform action: @escaping () -> Void) -> some View {
        onReceive(NotificationCenter.default.publisher(for: .coolDockRefresh)) { note in
            if note.object == nil || (note.object as? UUID) == id { action() }
        }
    }
}

/// Tiny JSON disk cache shared by network-backed services (instant display after launch).
enum DiskCache {
    static let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("CoolDock", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static func url(_ key: String) -> URL {
        let safe = key.map { $0.isLetter || $0.isNumber ? $0 : "_" }
        return dir.appendingPathComponent(String(safe.prefix(120)) + ".json")
    }

    static func load<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let data = try? Data(contentsOf: url(key)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, _ key: String) {
        let u = url(key)
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(value) { try? data.write(to: u, options: .atomic) }
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}

/// Shared URLSession with a small memory cache and sensible timeouts.
enum Net {
    static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.urlCache = URLCache(memoryCapacity: 2_000_000, diskCapacity: 20_000_000)
        cfg.httpAdditionalHeaders = ["User-Agent": "CoolDock/1.0 (macOS)"]
        return URLSession(configuration: cfg)
    }()

    struct HTTPError: LocalizedError {
        /// What the response body/headers say beyond the status code (see `HTTPError(response:data:)`).
        enum Hint { case none, badCredential, rateLimited }

        let status: Int
        let body: String
        var hint = Hint.none

        var errorDescription: String? {
            switch hint {
            case .rateLimited: return L("Rate limited")
            case .badCredential: return L("Check your token")
            case .none: break
            }
            switch status {
            case 401, 403: return L("Check your token")
            case 404: return L("Not found")
            case 429: return L("Rate limited")
            default: return L("Request failed (%d)", status)
            }
        }
    }

    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// Replaces the network for the current task tree (tests replay recorded responses); nil = `session`.
    @TaskLocal static var transport: Transport?

    static func load(_ req: URLRequest) async throws -> (Data, URLResponse) {
        if let transport { return try await transport(req) }
        return try await session.data(for: req)
    }

    static func data(_ url: URL, headers: [String: String] = [:], method: String = "GET", body: Data? = nil) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await load(req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HTTPError(response: http, data: data)
        }
        return data
    }

    static func json(_ url: URL, headers: [String: String] = [:], method: String = "GET", body: Data? = nil) async throws -> Any {
        let data = try await data(url, headers: headers, method: method, body: body)
        return try JSONSerialization.jsonObject(with: data)
    }
}
