import Foundation
import Testing
@testable import CoolDock

// Real-network evidence for every connected provider without an account: on 2026-10-27 each widget's
// request was replayed with curl against the live service (same URL, method, query, headers and body,
// with no credential or an obviously fake one) and the answers were stored in Tests/Fixtures/live-auth.
// The tests below check that (1) the endpoint exists (auth error, not "no such route" — with a control
// request to a misspelled path where the service routes before it authenticates), (2) the app still sends
// exactly the request that was replayed, and (3) the widget turns the real answer into the right message.
// See docs/verification/providers.md.

// MARK: - Recorded exchanges

/// One live request/response pair: `live-auth/<name>-2026-10-27.txt` (`>` request line, headers, blank,
/// optional body; `<` status line, kept response headers, blank; then an excerpt of a non-JSON body)
/// plus the verbatim JSON body (ids redacted) in the sibling `.json`.
struct LiveExchange: Sendable {
    static let day = "2026-10-27"

    let name: String
    let method: String
    let url: URL
    /// Lower-cased names.
    let requestHeaders: [String: String]
    let requestBody: String?
    let status: Int
    let responseHeaders: [String: String]
    let body: Data

    static func load(_ name: String) throws -> LiveExchange {
        let base = "live-auth/\(name)-\(day)"
        var request: [String] = [], response: [String] = [], excerpt: [String] = []
        for line in try Fixture.string(base + ".txt").components(separatedBy: "\n") where !line.hasPrefix("#") {
            if line.hasPrefix(">") {
                request.append(strip(line))
            } else if line.hasPrefix("<") {
                response.append(strip(line))
            } else if !line.isEmpty {
                excerpt.append(line)
            }
        }
        let first = request.first?.split(separator: " ", maxSplits: 1).map(String.init) ?? []
        guard first.count == 2, let url = URL(string: first[1]),
              let status = response.first?.split(separator: " ").dropFirst().first.flatMap({ Int($0) }) else {
            throw ConnError("Malformed live fixture \(name)")
        }
        let requestEnd = request.firstIndex(of: "") ?? request.count
        let responseEnd = response.firstIndex(of: "") ?? response.count
        let jsonPath = base + ".json"
        let body = FileManager.default.fileExists(atPath: Fixture.url(jsonPath).path)
            ? try Fixture.data(jsonPath) : Data(excerpt.joined(separator: "\n").utf8)
        return LiveExchange(
            name: name, method: first[0], url: url,
            requestHeaders: headers(request[1..<requestEnd], lowercased: true),
            requestBody: request.count > requestEnd + 1 ? request[(requestEnd + 1)...].joined(separator: "\n") : nil,
            status: status, responseHeaders: headers(response[1..<responseEnd], lowercased: false), body: body)
    }

    private static func strip(_ line: String) -> String {
        var s = line.dropFirst()
        if s.first == " " { s = s.dropFirst() }
        return String(s)
    }

    private static func headers(_ lines: ArraySlice<String>, lowercased: Bool) -> [String: String] {
        var out: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            out[lowercased ? key.lowercased() : key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return out
    }

    var response: HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/2", headerFields: responseHeaders)!
    }

    /// The error the app's HTTP layer raises for this response, and what the widget then shows.
    var appError: Net.HTTPError { Net.HTTPError(response: response, data: body) }
    var appMessage: String { ConnService.message(for: appError) }

    var json: Any? { try? JSONSerialization.jsonObject(with: body) }
    var object: [String: Any] { (json as? [String: Any]) ?? [:] }
    var text: String { String(decoding: body, as: UTF8.self) }
    func string(_ path: String) -> String? { ConnJSON.str(ConnJSON.path(json, path)) }

    /// Shopify's CSP `report-uri` names the controller#action that handled the request (even on a 401).
    var shopifyRoute: String? {
        guard let csp = responseHeaders["content-security-policy"], let target = csp.components(separatedBy: "report-uri ").last,
              let items = URLComponents(string: "https://shop.invalid" + target)?.queryItems else { return nil }
        func value(_ name: String) -> String { items.first(where: { $0.name == name })?.value ?? "" }
        return "\(value("source[controller]"))#\(value("source[action]"))"
    }
}

/// Provider-published API description extract (`live-auth/<provider>-spec-2026-10-27.json`).
struct LiveSpec {
    struct Operation {
        let method: String
        let path: String
        let parameters: [[String: Any]]

        var names: Set<String> { Set(parameters.compactMap { $0["name"] as? String }) }
        var required: Set<String> { Set(parameters.filter { ($0["required"] as? Bool) == true }.compactMap { $0["name"] as? String }) }
        func enumValues(_ name: String) -> [String] {
            (parameters.first { ($0["name"] as? String) == name }?["enum"] as? [Any])?.compactMap { $0 as? String } ?? []
        }
    }

    let servers: [String]
    let operations: [Operation]

    static func load(_ name: String) throws -> LiveSpec {
        let obj = try Fixture.object("live-auth/\(name)-\(LiveExchange.day).json")
        let ops = ConnJSON.array(obj["operations"]).map {
            Operation(method: ConnJSON.str($0["method"]) ?? "", path: ConnJSON.str($0["path"]) ?? "", parameters: ConnJSON.array($0["parameters"]))
        }
        return LiveSpec(servers: (obj["servers"] as? [Any])?.compactMap { $0 as? String } ?? [], operations: ops)
    }

    func operation(_ method: String, _ path: String) -> Operation? { operations.first { $0.method == method && $0.path == path } }
}

// MARK: - Replaying them through the app

/// Stands in for the network (`Net.transport`) while a provider runs: answers matching requests with a
/// recorded live response (or a 200 documentation-schema body) and records every request the app sends.
final class LiveReplay: @unchecked Sendable {
    struct Route: Sendable {
        let matches: @Sendable (URLRequest) -> Bool
        let reply: @Sendable (URLRequest) -> (Data, URLResponse)

        /// Requests to the exchange's host + path (and equal values for `keys`) get the recorded answer.
        static func live(_ ex: LiveExchange, keys: [String] = []) -> Route {
            Route(matches: { sameEndpoint($0.url, ex.url, keys: keys) }, reply: { _ in (ex.body, ex.response) })
        }

        /// HTTP 200 with a fixture file (or inline JSON) for host + path.
        static func ok(_ address: String, fixture: String? = nil, json: String = "{}") -> Route {
            let target = URL(string: address)!
            let body = fixture.flatMap { try? Fixture.data($0) } ?? Data(json.utf8)
            return Route(matches: { sameEndpoint($0.url, target, keys: []) }, reply: { req in
                (body, HTTPURLResponse(url: req.url ?? target, statusCode: 200, httpVersion: "HTTP/2", headerFields: ["Content-Type": "application/json"])!)
            })
        }
    }

    private let routes: [Route]
    private let lock = NSLock()
    private var log: [URLRequest] = []

    init(_ routes: [Route]) { self.routes = routes }

    var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return log
    }

    /// First request to `path` whose query has the given values.
    func request(_ path: String, _ query: [String: String] = [:]) -> URLRequest? {
        requests.first { r in
            guard let url = r.url, let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.percentEncodedPath == path else { return false }
            return query.allSatisfy { k, v in c.queryItems?.first(where: { $0.name == k })?.value == v }
        }
    }

    private func record(_ req: URLRequest) {
        lock.lock(); defer { lock.unlock() }
        log.append(req)
    }

    var transport: Net.Transport {
        { [self] req in
            record(req)
            guard let route = routes.first(where: { $0.matches(req) }) else { throw URLError(.unsupportedURL) }
            return route.reply(req)
        }
    }

    func run<T>(_ body: () async throws -> T) async throws -> T {
        try await Net.$transport.withValue(transport) { try await body() }
    }

    func failure(_ body: () async throws -> Any) async -> Error? {
        do { _ = try await run(body); return nil } catch { return error }
    }

    /// The message the connected widget shows for what `body` throws (nil = it succeeded).
    func message(_ body: () async throws -> Any) async -> String? {
        await failure(body).map { ConnService.message(for: $0) }
    }
}

func sameEndpoint(_ a: URL?, _ b: URL, keys: [String]) -> Bool {
    guard let a, let ca = URLComponents(url: a, resolvingAgainstBaseURL: false), let cb = URLComponents(url: b, resolvingAgainstBaseURL: false),
          ca.host == cb.host, ca.percentEncodedPath == cb.percentEncodedPath else { return false }
    return keys.allSatisfy { k in ca.queryItems?.first(where: { $0.name == k })?.value == cb.queryItems?.first(where: { $0.name == k })?.value }
}

func queryOf(_ request: URLRequest?) -> [String: String] {
    guard let url = request?.url else { return [:] }
    return Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }) { a, _ in a }
}

/// The app's request equals the one replayed with curl: method, host, path, query names (in order, also
/// percent-encoded) and values, the headers the app sets, and the JSON body. `volatile` values depend on the
/// clock or time zone; they only have to be dates/timestamps (or `TimeZone.current` for `timezone`).
func expectSameRequest(_ sent: URLRequest?, _ ex: LiveExchange, volatile: Set<String> = [], sourceLocation: SourceLocation = #_sourceLocation) {
    guard let sent, let url = sent.url, let a = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let b = URLComponents(url: ex.url, resolvingAgainstBaseURL: false) else {
        Issue.record("\(ex.name): the app sent no matching request", sourceLocation: sourceLocation)
        return
    }
    #expect((sent.httpMethod ?? "GET") == ex.method, "\(ex.name): method", sourceLocation: sourceLocation)
    #expect(a.scheme == b.scheme && a.host == b.host && a.percentEncodedPath == b.percentEncodedPath,
            "\(ex.name): \(url.absoluteString) vs \(ex.url.absoluteString)", sourceLocation: sourceLocation)
    let sentItems = a.queryItems ?? [], recorded = b.queryItems ?? []
    #expect(sentItems.map(\.name) == recorded.map(\.name), "\(ex.name): query names", sourceLocation: sourceLocation)
    #expect((a.percentEncodedQueryItems ?? []).map(\.name) == (b.percentEncodedQueryItems ?? []).map(\.name),
            "\(ex.name): encoded query names", sourceLocation: sourceLocation)
    for (x, y) in zip(a.percentEncodedQueryItems ?? [], b.percentEncodedQueryItems ?? []) where !volatile.contains(x.name.removingPercentEncoding ?? x.name) {
        #expect(x.value == y.value, "\(ex.name): \(x.name)", sourceLocation: sourceLocation)
    }
    for item in sentItems where volatile.contains(item.name) {
        let v = item.value ?? ""
        if item.name == "timezone" {
            #expect(v == TimeZone.current.identifier, sourceLocation: sourceLocation)
        } else {
            #expect(ConnDate.parse(v) != nil || Int(v) != nil, "\(ex.name): \(item.name)=\(v)", sourceLocation: sourceLocation)
        }
    }

    // Headers: everything the app sets was sent; everything sent beyond URLSession's own defaults
    // (User-Agent from `Net.session`, Accept-Encoding, Accept-Language, `Accept: */*`) came from the app.
    let appHeaders = Dictionary((sent.allHTTPHeaderFields ?? [:]).map { ($0.key.lowercased(), $0.value) }) { a, _ in a }
    for (k, v) in appHeaders { #expect(ex.requestHeaders[k] == v, "\(ex.name): header \(k)", sourceLocation: sourceLocation) }
    var sessionDefaults: Set = ["user-agent", "accept-encoding", "accept-language"]
    if ex.requestHeaders["accept"] == "*/*", appHeaders["accept"] == nil { sessionDefaults.insert("accept") }
    #expect(Set(ex.requestHeaders.keys).subtracting(sessionDefaults) == Set(appHeaders.keys), "\(ex.name): header set", sourceLocation: sourceLocation)
    #expect(ex.requestHeaders["user-agent"] == Net.session.configuration.httpAdditionalHeaders?["User-Agent"] as? String,
            sourceLocation: sourceLocation)

    if let recorded = ex.requestBody {
        let mine = sent.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? NSDictionary
        let theirs = (try? JSONSerialization.jsonObject(with: Data(recorded.utf8))) as? NSDictionary
        #expect(mine != nil && mine == theirs, "\(ex.name): body", sourceLocation: sourceLocation)
    } else {
        #expect(sent.httpBody == nil, "\(ex.name): unexpected body", sourceLocation: sourceLocation)
    }
}

// MARK: - Tests

@Suite struct LiveAuthTests {
    /// When the requests were replayed (2026-10-27 05:06 in Asia/Tehran).
    let now = TestDate.utc("2026-10-27T01:36:00Z")
    let checkToken = L("Check your token")

    func load(_ name: String) throws -> LiveExchange { try LiveExchange.load(name) }

    /// Every live no-key / fake-key answer → the message the widget shows.
    static let liveMessages: [(String, String)] = [
        ("stripe-nokey", "Check your token"), ("stripe-invalid", "Check your token"),
        ("polar-nokey", "Check your token"), ("polar-invalid", "Check your token"),
        ("dodo-live-nokey", "Check your token"), ("dodo-live-invalid", "Check your token"), ("dodo-test-invalid", "Check your token"),
        ("shopify-devstore-nokey", "Check your token"), ("shopify-devstore-invalid", "Check your token"),
        ("shopify-devstore-shop-invalid", "Check your token"), ("shopify-retired-2024-10-invalid", "Check your token"),
        ("shopify-unknownshop-invalid", "Not found"),
        ("plausible-aggregate-nokey", "Check your token"), ("plausible-aggregate-invalid", "Check your token"),
        ("plausible-timeseries-invalid", "Check your token"),
        ("simpleanalytics-private-invalid", "Not found"),
        ("datafast-overview-nokey", "Check your token"), ("datafast-overview-invalid", "Check your token"),
        ("datafast-timeseries-invalid", "Check your token"),
        ("dub-count-nokey", "Check your token"), ("dub-count-invalid", "Check your token"), ("dub-timeseries-invalid", "Check your token"),
        ("resend-nokey", "Check your token"), ("resend-invalid", "Check your token"),
        ("github-graphql-user-invalid", "Check your token"), ("github-graphql-viewer-invalid", "Check your token"),
        ("github-graphql-user-nokey", "Rate limited"),
        ("supabase-project-nokey", "Check your token"), ("supabase-project-invalid", "Check your token"),
        ("supabase-usage-invalid", "Check your token"),
        ("linear-nokey", "Check your token"), ("linear-invalid", "Check your token"), ("linear-invalid-bearer", "Check your token"),
        ("x-nokey", "Check your token"), ("x-invalid", "Check your token"),
        ("tiktok-nokey", "Check your token"), ("tiktok-invalid", "Check your token"),
        ("youtube-nokey", "Check your token"), ("youtube-invalid", "Check your token"), ("youtube-id-invalid", "Check your token"),
        ("anthropic-usage-nokey", "Check your token"), ("anthropic-usage-invalid", "Check your token"),
        ("anthropic-cost-invalid", "Check your token"),
        ("openai-usage-nokey", "Check your token"), ("openai-usage-invalid", "Check your token"), ("openai-cost-invalid", "Check your token"),
    ]

    @Test(arguments: liveMessages)
    func liveAnswerMapsToWidgetMessage(_ name: String, _ english: String) throws {
        let ex = try load(name)
        #expect([400, 401, 403, 404].contains(ex.status), "\(name): HTTP \(ex.status)")
        #expect(ex.appMessage == L(english), "\(name): HTTP \(ex.status) → \(ex.appMessage)")
    }

    @MainActor @Test func missingCredentialNeverReachesTheNetwork() async {
        let replay = LiveReplay([])
        let widgets = [
            WidgetInstance(kind: .stripeRevenue), WidgetInstance(kind: .polarRevenue), WidgetInstance(kind: .dodoRevenue),
            WidgetInstance(kind: .shopifyChart, config: ["shop": "your-development-store"]),
            WidgetInstance(kind: .plausible, config: ["site": "plausible.io"]), WidgetInstance(kind: .dataFast),
            WidgetInstance(kind: .dubStats), WidgetInstance(kind: .resendStats),
            WidgetInstance(kind: .supabase, config: ["project": "abcdefghijklmnopqrst"]),
            WidgetInstance(kind: .socialX, config: ["user": "XDevelopers"]), WidgetInstance(kind: .socialTikTok),
            WidgetInstance(kind: .socialYouTube, config: ["channel": "@GoogleDevelopers"]),
            WidgetInstance(kind: .aiUsage, config: ["provider": "anthropic"]), WidgetInstance(kind: .aiUsage, config: ["provider": "openai"]),
        ]
        for w in widgets {
            let message = await replay.message { try await ConnProviders.fetch(w, token: nil) }
            #expect(message == L("Add your API token"), "\(w.kind)")
        }
        #expect(replay.requests.isEmpty)
    }

    // MARK: Payments

    @Test func stripe() async throws {
        let invalid = try load("stripe-invalid"), nokey = try load("stripe-nokey"), control = try load("stripe-control-badroute")
        // Stripe routes before it authenticates: a misspelled path is 404 even with a bad key, so 401 proves the route.
        #expect(invalid.status == 401 && nokey.status == 401 && control.status == 404)
        #expect(control.string("error.message")?.hasPrefix("Unrecognized request URL (GET: /v1/balance_transactionz)") == true)
        #expect(invalid.string("error.type") == "invalid_request_error" && invalid.string("error.message") == "Invalid API Key provided: sk_test_***alid")
        #expect(nokey.string("error.message")?.hasPrefix("You did not provide an API key.") == true)
        #expect(invalid.responseHeaders["www-authenticate"] == #"Bearer realm="Stripe""#)

        let replay = LiveReplay([.live(invalid)])
        let message = await replay.message { try await ConnStripe.fetch(token: "sk_test_invalid", range: .week, now: now) }
        #expect(message == checkToken)
        #expect(replay.requests.count == 1)
        expectSameRequest(replay.requests.first, invalid, volatile: ["created[gte]"])
    }

    @Test func polar() async throws {
        let invalid = try load("polar-invalid"), nokey = try load("polar-nokey"), noSlash = try load("polar-noslash-nokey")
        let unknown = try load("polar-control-badroute-nokey"), unknownWithToken = try load("polar-control-badroute")
        // Without a token Polar routes first (our path 401, a misspelled one 404); with one it authenticates first.
        #expect(nokey.status == 401 && unknown.status == 404 && unknown.string("detail") == "Not Found" && unknownWithToken.status == 401)
        // The slash-less form redirects to the app's canonical `/v1/metrics/`.
        let location = noSlash.responseHeaders["location"].flatMap { URLComponents(string: $0) }
        #expect(noSlash.status == 307 && location?.host == "api.polar.sh" && location?.percentEncodedPath == "/v1/metrics/")
        #expect(invalid.status == 401 && invalid.string("error") == "invalid_token")
        #expect(invalid.responseHeaders["www-authenticate"]?.contains(#"error="invalid_token""#) == true)

        let replay = LiveReplay([.live(invalid)])
        let message = await replay.message { try await ConnPolar.fetch(token: "polar_oat_invalid", range: .week) }
        #expect(message == checkToken)
        expectSameRequest(replay.requests.first, invalid, volatile: ["start_date", "end_date", "timezone"])

        // Polar's published OpenAPI document (production + sandbox servers).
        let spec = try LiveSpec.load("polar-spec")
        #expect(spec.servers.contains("https://api.polar.sh"))
        let op = try #require(spec.operation("GET", "/v1/metrics/"))
        let sent = queryOf(replay.requests.first)
        #expect(Set(sent.keys).isSubset(of: op.names) && op.required.isSubset(of: Set(sent.keys)))
        for range in [ConnRange.day, .week, .month] {
            let interval = queryOf(URLRequest(url: try ConnPolar.request(range: range, now: now)))["interval"] ?? ""
            #expect(op.enumValues("interval").contains(interval), "\(range)")
        }
        #expect(op.enumValues("timezone").contains("Asia/Tehran"))
        // `timezone` is an enum: every zone macOS reports must be in it, or Polar rejects the request.
        let zones = Set(op.enumValues("timezone"))
        let rejected = TimeZone.knownTimeZoneIdentifiers.filter { !zones.contains($0) }
        #expect(rejected.isEmpty, "\(rejected)")
    }

    @Test func dodo() async throws {
        let live = try load("dodo-live-invalid"), test = try load("dodo-test-invalid"), nokey = try load("dodo-live-nokey")
        let control = try load("dodo-control-badroute")
        #expect(live.status == 401 && test.status == 401 && nokey.status == 401 && live.string("error") == "Unauthorized")
        // The edge blocks paths outside the API schema (403 HTML); `/payments` reaches the API's own 401.
        #expect(control.status == 403 && control.text.contains("not part of the Dodo Payments API schema"))

        let replay = LiveReplay([.live(live), .live(test)])
        let message = await replay.message { try await ConnDodo.fetch(token: "invalid", range: .week) }
        #expect(message == checkToken)
        // A key rejected in live mode is retried once in test mode (test keys only work there).
        #expect(replay.requests.map { $0.url?.host } == ["live.dodopayments.com", "test.dodopayments.com"])
        expectSameRequest(replay.requests.first, live, volatile: ["created_at_gte"])
        expectSameRequest(replay.requests.last, test, volatile: ["created_at_gte"])
    }

    @Test func shopify() async throws {
        let invalid = try load("shopify-devstore-invalid"), nokey = try load("shopify-devstore-nokey")
        let shop = try load("shopify-devstore-shop-invalid"), unknownShop = try load("shopify-unknownshop-invalid")
        let control = try load("shopify-control-badroute"), retired = try load("shopify-retired-2024-10-invalid")
        let bogusVersion = try load("shopify-control-badversion")
        #expect(invalid.status == 401 && nokey.status == 401 && shop.status == 401)
        #expect(invalid.string("errors") == "[API] Invalid API key or access token (unrecognized login or wrong password)")
        // Shopify authenticates before routing, but names the controller that took the request.
        #expect(invalid.shopifyRoute == "admin/orders#index" && shop.shopifyRoute == "admin/shops#show")
        #expect(control.status == 401 && control.shopifyRoute == "admin/errors#error_404")
        // The version is not checked up front: the app's old pin (2024-10, retired) and a bogus 1999-01 also
        // reach orders — Shopify serves retired versions with the oldest accessible one. The app now pins 2026-10.
        #expect(retired.url.path.hasPrefix("/admin/api/2024-10/") && retired.shopifyRoute == "admin/orders#index")
        #expect(bogusVersion.shopifyRoute == "admin/orders#index")
        #expect(ConnShopify.apiVersion == "2026-10" && invalid.url.path.hasPrefix("/admin/api/2026-10/"))
        #expect(unknownShop.status == 404 && unknownShop.string("errors") == "Not Found")

        let replay = LiveReplay([.live(invalid)])
        let message = await replay.message {
            try await ConnShopify.fetch(shop: "your-development-store", token: "shpat_invalid", range: .week, now: now)
        }
        #expect(message == checkToken)
        expectSameRequest(replay.requests.first, invalid, volatile: ["created_at_min"])

        let missing = LiveReplay([.live(unknownShop)])
        let missingMessage = await missing.message {
            try await ConnShopify.fetch(shop: "https://cooldock-no-such-shop-7f3a.myshopify.com/admin", token: "shpat_invalid", range: .week, now: now)
        }
        #expect(missingMessage == L("Not found"))
        expectSameRequest(missing.requests.first, unknownShop, volatile: ["created_at_min"])

        // No orders → the currency comes from shop.json (optional: its failure leaves the USD default).
        let empty = LiveReplay([.ok("https://your-development-store.myshopify.com/admin/api/2026-10/orders.json", json: #"{"orders":[]}"#), .live(shop)])
        let snap = try await empty.run {
            try await ConnShopify.fetch(shop: "your-development-store", token: "shpat_invalid", range: .week, now: now)
        }
        #expect(snap.currency == "USD" && snap.value == 0)
        expectSameRequest(empty.request("/admin/api/2026-10/shop.json"), shop)
    }

    // MARK: Analytics

    @Test func plausible() async throws {
        let aggregate = try load("plausible-aggregate-invalid"), series = try load("plausible-timeseries-invalid")
        let nokey = try load("plausible-aggregate-nokey"), control = try load("plausible-control-badroute")
        // Unknown API paths answer 406 (no JSON route), ours the Stats API's own 401 messages.
        #expect(aggregate.status == 401 && series.status == 401 && nokey.status == 401 && control.status == 406)
        #expect(nokey.string("error")?.hasPrefix("Missing API key.") == true)
        #expect(aggregate.string("error")?.hasPrefix("Invalid API key or site ID.") == true)

        let replay = LiveReplay([.live(aggregate), .live(series)])
        let message = await replay.message {
            try await ConnPlausible.fetch(host: "https://plausible.io", site: "https://plausible.io/", token: "invalid", range: .week)
        }
        #expect(message == checkToken)
        expectSameRequest(replay.request("/api/v1/stats/aggregate"), aggregate)
        expectSameRequest(replay.request("/api/v1/stats/timeseries"), series)
    }

    @Test func simpleAnalytics() async throws {
        let privateNoKey = try load("simpleanalytics-private-nokey"), privateKey = try load("simpleanalytics-private-invalid")
        let publicNoKey = try load("simpleanalytics-public-nokey"), publicKey = try load("simpleanalytics-public-invalid")
        // Unknown / private sites: 404 "View not found" with or without a key. Public sites: 200 even with a bad key.
        #expect(privateNoKey.status == 404 && privateKey.status == 404 && privateKey.string("error") == "View not found")
        #expect(publicNoKey.status == 200 && publicKey.status == 200)
        let volatile: Set = ["start", "timezone"]

        let noKey = LiveReplay([.live(privateNoKey)])
        let noKeyMessage = await noKey.message {
            try await ConnSimpleAnalytics.fetch(site: "cooldock-no-such-site.example", token: nil, range: .week)
        }
        #expect(noKeyMessage == L("Add your API token"))
        expectSameRequest(noKey.requests.first, privateNoKey, volatile: volatile)

        let withKey = LiveReplay([.live(privateKey)])
        let withKeyMessage = await withKey.message {
            try await ConnSimpleAnalytics.fetch(site: "cooldock-no-such-site.example", token: "sa_api_key_invalid", range: .week)
        }
        #expect(withKeyMessage == L("Not found"))
        expectSameRequest(withKey.requests.first, privateKey, volatile: volatile)

        // Real successful answers from the keyless public mode go through the parser.
        for (ex, key) in [(publicNoKey, nil), (publicKey, "sa_api_key_invalid")] as [(LiveExchange, String?)] {
            let replay = LiveReplay([.live(ex)])
            let snap = try await replay.run { try await ConnSimpleAnalytics.fetch(site: "simpleanalytics.com", token: key, range: .week) }
            let histogram = ConnJSON.array(ex.object["histogram"])
            #expect(snap.value == 3287 && snap.metrics[ConnKey.pageviews] == 4892)
            #expect(snap.series == histogram.map { ConnJSON.num($0["visitors"]) ?? -1 } && snap.series.count == 7)
            #expect(histogram.first?["date"] as? String == "2026-10-21" && histogram.last?["date"] as? String == "2026-10-27")
            expectSameRequest(replay.requests.first, ex, volatile: volatile)
        }
    }

    @Test func dataFast() async throws {
        let overview = try load("datafast-overview-invalid"), series = try load("datafast-timeseries-invalid")
        let nokey = try load("datafast-overview-nokey"), control = try load("datafast-control-badroute")
        #expect(overview.status == 401 && series.status == 401 && nokey.status == 401 && control.status == 404)
        // Vercel names the route that served each request.
        #expect(overview.responseHeaders["x-matched-path"] == "/api/v1/analytics/overview")
        #expect(series.responseHeaders["x-matched-path"] == "/api/v1/analytics/timeseries")
        #expect(control.responseHeaders["x-matched-path"] == "/404")
        #expect(overview.string("status") == "error" && overview.string("error.message") == "Unauthorized: Invalid API Key")
        #expect(nokey.string("error.message") == "Unauthorized: Missing or invalid Authorization header")
        // The live error envelope is not mistaken for data.
        #expect(throws: ConnError(L("Unexpected response"))) {
            try ConnDataFast.parse(overview: overview.object, timeseries: series.object, range: .week, now: now)
        }

        let replay = LiveReplay([.live(overview), .live(series)])
        let message = await replay.message { try await ConnDataFast.fetch(token: "df_invalid", range: .week) }
        #expect(message == checkToken)
        let volatile: Set = ["startAt", "endAt", "timezone"]
        expectSameRequest(replay.request("/api/v1/analytics/overview"), overview, volatile: volatile)
        expectSameRequest(replay.request("/api/v1/analytics/timeseries"), series, volatile: volatile)
    }

    @Test func dub() async throws {
        let count = try load("dub-count-invalid"), series = try load("dub-timeseries-invalid")
        let nokey = try load("dub-count-nokey"), control = try load("dub-control-badroute")
        #expect(count.status == 401 && series.status == 401 && nokey.status == 401 && control.status == 404)
        #expect(count.responseHeaders["x-matched-path"] == "/api/analytics" && control.responseHeaders["x-matched-path"] == "/404")
        #expect(count.string("error.code") == "unauthorized" && count.string("error.message") == "Unauthorized: Invalid API key.")
        #expect(nokey.string("error.message") == "Missing Authorization header.")

        let replay = LiveReplay([.live(count, keys: ["groupBy"]), .live(series, keys: ["groupBy"])])
        let message = await replay.message { try await ConnDub.fetch(token: "dub_invalid", range: .week) }
        #expect(message == checkToken)
        expectSameRequest(replay.request("/analytics", ["groupBy": "count"]), count, volatile: ["timezone"])
        expectSameRequest(replay.request("/analytics", ["groupBy": "timeseries"]), series, volatile: ["timezone"])
    }

    // MARK: Developer

    @Test func resend() async throws {
        let invalid = try load("resend-invalid"), nokey = try load("resend-nokey")
        let control = try load("resend-control-badroute"), controlNoKey = try load("resend-control-badroute-nokey")
        // An unknown key is HTTP 400 `validation_error` (as documented), not 401/403.
        #expect(invalid.status == 400 && invalid.string("name") == "validation_error" && invalid.string("message") == "API key is invalid")
        #expect(nokey.status == 401 && nokey.string("name") == "missing_api_key")
        // Regression: by status alone the widget said "Request failed (400)".
        #expect(Net.HTTPError(status: 400, body: invalid.text).errorDescription == L("Request failed (%d)", 400))
        #expect(invalid.appError.hint == .badCredential)
        // Resend authenticates before routing (a misspelled path gets the same answers), so the route is
        // checked against Resend's published OpenAPI document instead.
        #expect(control.status == 400 && controlNoKey.status == 401)

        let replay = LiveReplay([.live(invalid)])
        let message = await replay.message { try await ConnResend.fetch(token: "re_invalid", now: now) }
        #expect(message == checkToken)
        expectSameRequest(replay.requests.first, invalid)

        let spec = try LiveSpec.load("resend-spec")
        let op = try #require(spec.operation("GET", "/emails"))
        #expect(spec.servers == ["https://api.resend.com"] && Set(queryOf(replay.requests.first).keys).isSubset(of: op.names))
        #expect(op.names.isSuperset(of: ["limit", "after"]))
    }

    @Test func gitHubGraphQL() async throws {
        let user = try load("github-graphql-user-invalid"), viewer = try load("github-graphql-viewer-invalid")
        let control = try load("github-control-badroute")
        #expect(user.status == 401 && viewer.status == 401 && user.string("message") == "Bad credentials")
        #expect(control.status == 404 && control.string("message") == "Not Found")

        let replay = LiveReplay([.live(user)])
        let message = await replay.message { try await ConnGitHub.fetch(user: "@torvalds", token: "ghp_invalid") }
        #expect(message == checkToken)
        expectSameRequest(replay.requests.first, user)

        let viewerReplay = LiveReplay([.live(viewer)])
        let viewerMessage = await viewerReplay.message { try await ConnGitHub.fetch(user: "", token: "ghp_invalid") }
        #expect(viewerMessage == checkToken)
        expectSameRequest(viewerReplay.requests.first, viewer)
    }

    @Test func gitHubRateLimit() async throws {
        // GraphQL without a token got GitHub's primary-rate-limit answer: 403, `x-ratelimit-remaining: 0`.
        let limited = try load("github-graphql-user-nokey")
        #expect(limited.status == 403 && limited.responseHeaders["x-ratelimit-remaining"] == "0")
        #expect(limited.responseHeaders["x-ratelimit-resource"] == "graphql" && limited.string("message")?.hasPrefix("API rate limit exceeded") == true)
        // Regression: a bare 403 reads "Check your token" — wrong when the limit is spent.
        #expect(Net.HTTPError(status: 403, body: limited.text).errorDescription == checkToken)
        #expect(limited.appMessage == L("Rate limited"))

        let replay = LiveReplay([.live(limited)])
        let message = await replay.message { try await ConnGitHub.fetch(user: "torvalds", token: "ghp_invalid") }
        #expect(message == L("Rate limited"))

        // Documented (not reproducible without an account): a spent GraphQL limit can also be HTTP 200 + `errors`.
        #expect(throws: ConnError(L("Rate limited"))) {
            try ConnGitHub.parseGraphQL(["errors": [["message": "API rate limit exceeded for user ID 1."]]], viewer: false, now: now, rateRemaining: "0")
        }
        // GitHub's secondary limit: 403 with `retry-after`.
        let secondary = HTTPURLResponse(url: limited.url, statusCode: 403, httpVersion: "HTTP/2", headerFields: ["Retry-After": "60"])!
        #expect(Net.HTTPError(response: secondary, data: Data()).errorDescription == L("Rate limited"))
    }

    @Test func supabase() async throws {
        let project = try load("supabase-project-invalid"), usage = try load("supabase-usage-invalid"), nokey = try load("supabase-project-nokey")
        let control = try load("supabase-control-badroute"), controlNoKey = try load("supabase-control-badroute-nokey")
        #expect(project.status == 401 && usage.status == 401 && nokey.status == 401)
        #expect(nokey.string("message") == "No access token provided" && project.string("message") == "JWT could not be decoded")
        // Auth comes before routing (a misspelled path is 401 too), so the paths are checked against the
        // Management API's live OpenAPI document.
        #expect(control.status == 401 && controlNoKey.status == 401)

        let replay = LiveReplay([.live(project), .live(usage)])
        let message = await replay.message { try await ConnSupabase.fetch(project: " abcdefghijklmnopqrst ", token: "sbp_invalid") }
        #expect(message == checkToken)
        expectSameRequest(replay.request("/v1/projects/abcdefghijklmnopqrst"), project)
        expectSameRequest(replay.request("/v1/projects/abcdefghijklmnopqrst/analytics/endpoints/usage.api-counts"), usage)

        let spec = try LiveSpec.load("supabase-spec")
        #expect(spec.servers == ["https://api.supabase.com"] && spec.operation("GET", "/v1/projects/{ref}") != nil)
        let op = try #require(spec.operation("GET", "/v1/projects/{ref}/analytics/endpoints/usage.api-counts"))
        let interval = queryOf(replay.request("/v1/projects/abcdefghijklmnopqrst/analytics/endpoints/usage.api-counts"))["interval"]
        #expect(interval == "1day" && op.enumValues("interval").contains("1day"))
    }

    @Test func linear() async throws {
        let invalid = try load("linear-invalid"), nokey = try load("linear-nokey"), bearer = try load("linear-invalid-bearer")
        let control = try load("linear-control-badroute")
        #expect(invalid.status == 401 && nokey.status == 401 && bearer.status == 401)
        #expect(control.status == 404 && control.text.contains("Cannot POST /graphqlz"))
        let first = ConnJSON.array(invalid.object["errors"]).first
        #expect(ConnJSON.str(ConnJSON.path(first, "extensions.code")) == "AUTHENTICATION_ERROR")
        // The GraphQL parser maps the same body on its own (in case it arrives with another status).
        #expect(throws: CalLinearAPI.GraphQLError.self) { try CalLinearAPI.parse(invalid.json as Any) }

        let replay = LiveReplay([.live(invalid)])
        let error = await replay.failure { try await CalLinearAPI.fetch(token: "lin_api_invalid") }
        #expect((error as? LocalizedError)?.errorDescription == checkToken)
        expectSameRequest(replay.requests.first, invalid)
        // Personal API keys go in `Authorization` as they are (no `Bearer`).
        #expect(replay.requests.first?.value(forHTTPHeaderField: "Authorization") == "lin_api_invalid")
    }

    // MARK: Social

    @Test func x() async throws {
        let invalid = try load("x-invalid"), nokey = try load("x-nokey"), control = try load("x-control-badroute")
        #expect(invalid.status == 401 && nokey.status == 401 && control.status == 404 && control.body.isEmpty)
        #expect(invalid.responseHeaders["content-type"] == "application/problem+json")
        #expect(invalid.string("title") == "Unauthorized" && invalid.string("detail") == "Unauthorized")

        let replay = LiveReplay([.live(invalid)])
        let message = await replay.message { try await ConnSocial.x(user: "https://x.com/XDevelopers", token: "invalid") }
        #expect(message == checkToken)
        expectSameRequest(replay.requests.first, invalid)
    }

    @Test func tikTok() async throws {
        let invalid = try load("tiktok-invalid"), nokey = try load("tiktok-nokey"), control = try load("tiktok-control-badroute")
        #expect(invalid.status == 401 && nokey.status == 401 && control.status == 404)
        #expect(invalid.string("error.code") == "access_token_invalid")
        // Same `{data, error}` envelope the parser reads; it would surface TikTok's message.
        #expect(throws: ConnError("The access token is invalid or not found in the request.")) { try ConnSocial.parseTikTok(invalid.object) }

        let replay = LiveReplay([.live(invalid)])
        let message = await replay.message { try await ConnSocial.tiktok(token: "act.invalid") }
        #expect(message == checkToken)
        expectSameRequest(replay.requests.first, invalid)
    }

    @Test func youTube() async throws {
        let handle = try load("youtube-invalid"), id = try load("youtube-id-invalid"), nokey = try load("youtube-nokey")
        let control = try load("youtube-control-badroute")
        #expect(handle.status == 400 && id.status == 400 && nokey.status == 403 && control.status == 404)
        let details = ConnJSON.array(ConnJSON.path(handle.json, "error.details"))
        #expect(details.contains { ConnJSON.str($0["reason"]) == "API_KEY_INVALID" && ConnJSON.str(ConnJSON.path($0, "metadata.service")) == "youtube.googleapis.com" })
        #expect(handle.string("error.status") == "INVALID_ARGUMENT" && nokey.string("error.status") == "PERMISSION_DENIED")
        // Regression: by status alone a wrong key read "Request failed (400)".
        #expect(Net.HTTPError(status: 400, body: handle.text).errorDescription == L("Request failed (%d)", 400))

        let replay = LiveReplay([.live(handle)])
        let message = await replay.message { try await ConnSocial.youtube(channel: "https://www.youtube.com/@GoogleDevelopers", key: "invalid") }
        #expect(message == checkToken)
        expectSameRequest(replay.requests.first, handle)

        let byID = LiveReplay([.live(id)])
        let idMessage = await byID.message { try await ConnSocial.youtube(channel: "UC_x5XG1OV2P6uZZ5FSM9Ttw", key: "invalid") }
        #expect(idMessage == checkToken)
        expectSameRequest(byID.requests.first, id)

        // The live discovery document: every parameter the app sends exists, `part` is the only required one.
        let spec = try LiveSpec.load("youtube-spec")
        let op = try #require(spec.operation("GET", "/youtube/v3/channels"))
        #expect(op.required == ["part"])
        for request in replay.requests + byID.requests { #expect(Set(queryOf(request).keys).isSubset(of: op.names)) }

        // Documented quota error (https://developers.google.com/youtube/v3/docs/errors): retry later, not "check your key".
        let quota = #"{"error":{"code":403,"message":"The request cannot be completed because you have exceeded your quota.","errors":[{"message":"The request cannot be completed because you have exceeded your quota.","domain":"youtube.quota","reason":"quotaExceeded"}]}}"#
        let response = HTTPURLResponse(url: handle.url, statusCode: 403, httpVersion: "HTTP/2", headerFields: nil)!
        #expect(Net.HTTPError(response: response, data: Data(quota.utf8)).errorDescription == L("Rate limited"))
    }

    // MARK: AI usage

    @Test func anthropic() async throws {
        let usage = try load("anthropic-usage-invalid"), cost = try load("anthropic-cost-invalid"), nokey = try load("anthropic-usage-nokey")
        let sub = try load("anthropic-control-badroute"), prefix = try load("anthropic-control-prefix"), top = try load("anthropic-control-toplevel")
        #expect(usage.status == 401 && cost.status == 401 && nokey.status == 401)
        #expect(usage.string("error.type") == "authentication_error" && usage.string("error.message") == "API key is invalid.")
        #expect(nokey.string("error.message") == "x-api-key header is required" && usage.responseHeaders["x-should-retry"] == "false")
        // Only the `/v1/organizations/` family is discriminated live: other prefixes 404 before auth,
        // anything below it authenticates first.
        #expect(prefix.status == 404 && top.status == 404 && prefix.string("error.type") == "not_found_error" && sub.status == 401)

        let replay = LiveReplay([.live(usage)])
        let message = await replay.message { try await ConnAIUsageAPI.anthropic(key: "sk-ant-admin01-invalid", range: .week) }
        #expect(message == checkToken)
        expectSameRequest(replay.requests.first, usage, volatile: ["starting_at"])

        // The cost report is optional: its live 401 leaves the list-price estimate.
        let costReplay = LiveReplay([
            .ok("https://api.anthropic.com/v1/organizations/usage_report/messages", fixture: "anthropic/usage-report-window-docs-2026-10-27.json"),
            .live(cost),
        ])
        let snap = try await costReplay.run { try await ConnAIUsageAPI.anthropic(key: "sk-ant-admin01-invalid", range: .week) }
        #expect(snap.estimate)
        expectSameRequest(costReplay.request("/v1/organizations/cost_report"), cost, volatile: ["starting_at"])
    }

    @Test func openAI() async throws {
        let usage = try load("openai-usage-invalid"), cost = try load("openai-cost-invalid"), nokey = try load("openai-usage-nokey")
        let control = try load("openai-control-badroute")
        #expect(usage.status == 401 && cost.status == 401 && nokey.status == 401 && control.status == 404)
        #expect(usage.string("error.code") == "invalid_api_key" && usage.string("error.type") == "invalid_request_error")
        #expect(nokey.string("error.message") == "Missing bearer or basic authentication in header")
        #expect(usage.responseHeaders["www-authenticate"] == #"Bearer realm="OpenAI API""#)

        let replay = LiveReplay([.live(usage)])
        let message = await replay.message { try await ConnAIUsageAPI.openai(key: "sk-admin-invalid", range: .week) }
        #expect(message == checkToken)
        expectSameRequest(replay.requests.first, usage, volatile: ["start_time"])

        let costReplay = LiveReplay([
            .ok("https://api.openai.com/v1/organization/usage/completions", json: #"{"object":"page","data":[],"has_more":false,"next_page":null}"#),
            .live(cost),
        ])
        let snap = try await costReplay.run { try await ConnAIUsageAPI.openai(key: "sk-admin-invalid", range: .week) }
        #expect(snap.estimate)
        let costRequest = costReplay.request("/v1/organization/costs")
        expectSameRequest(costRequest, cost, volatile: ["start_time"])

        // openai/openai-openapi: parameter names, enums and the documented `limit` maximum for daily buckets.
        let spec = try LiveSpec.load("openai-spec")
        for (request, path) in [(replay.requests.first, "/organization/usage/completions"), (costRequest, "/organization/costs")] {
            let op = try #require(spec.operation("GET", path))
            let q = queryOf(request)
            #expect(Set(q.keys).isSubset(of: op.names) && op.required.isSubset(of: Set(q.keys)), "\(path)")
            #expect(op.enumValues("bucket_width").contains(q["bucket_width"] ?? ""), "\(path)")
            if let group = q["group_by"] { #expect(op.enumValues("group_by").contains(group)) }
            #expect((Int(q["limit"] ?? "") ?? 0) <= 31)
        }
    }
}
