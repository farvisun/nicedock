import Foundation
import Observation

// MARK: - Snapshot

/// Last known metrics for one connected widget. Persisted so tiles show instantly after launch.
struct ConnSnapshot: Codable, Equatable {
    /// Config signature the values belong to (kind + config). A changed range/site discards it.
    var signature = ""
    var updated = Date()
    /// Primary metric (revenue, visitors, followers, tokens…).
    var value: Double?
    /// ISO 4217 code when `value` is money.
    var currency: String?
    /// Secondary named metrics, see `ConnKey`.
    var metrics: [String: Double] = [:]
    /// Text facts (status, display name).
    var text: [String: String] = [:]
    /// Chart values, oldest first.
    var series: [Double] = []
    var seriesStart: Date?
    /// Bucket width in seconds; 0 = irregular samples (follower history).
    var seriesStep: Double = 86_400
    /// Values are approximations (local price table, public events…).
    var estimate = false

    func metric(_ key: String) -> Double? { metrics[key] }
}

/// Metric keys shared by providers and views.
enum ConnKey {
    static let orders = "orders", aov = "aov", valueDelta = "valueDelta", ordersDelta = "ordersDelta", aovDelta = "aovDelta"
    static let clicks = "clicks", leads = "leads", sales = "sales", saleAmount = "saleAmount"
    static let sentToday = "sentToday", sentMonth = "sentMonth", deliveredRate = "deliveredRate", bounced = "bounced"
    static let today = "today", week = "week", streak = "streak", total = "total"
    static let requests = "requests", authRequests = "auth", restRequests = "rest", storageRequests = "storage", realtimeRequests = "realtime"
    static let inputTokens = "in", outputTokens = "out", cacheWrite = "cacheWrite", cacheRead = "cacheRead", cost = "cost", calls = "calls"
    static let revenue = "revenue", pageviews = "pageviews", sessions = "sessions"
    static let status = "status", name = "name", region = "region", sourceNote = "note"
    /// AI usage: headline unit (`ConnAIUnit`), list-price value of a billed amount, quota reset time.
    static let unit = "unit", grossCost = "grossCost", reset = "reset", window = "window"
}

// MARK: - Store

/// Single source of truth for every connected tile. Keyed by widget id; refreshed by
/// `keepFresh` loops owned by the visible tiles (`.task(id:)`), so nothing runs while hidden.
@MainActor
@Observable
final class ConnMetricStore {
    static let shared = ConnMetricStore()

    private(set) var snapshots: [UUID: ConnSnapshot] = [:]
    private(set) var errors: [UUID: String] = [:]
    private(set) var loading: Set<UUID> = []

    @ObservationIgnored private var inFlight = Set<UUID>()
    @ObservationIgnored private var forced = Set<UUID>()
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private static let cacheKey = "connected-metrics"

    private init() {
        guard !ConnEnv.isRendering, let cached = DiskCache.load([String: ConnSnapshot].self, Self.cacheKey) else { return }
        let horizon = Date().addingTimeInterval(-45 * 86_400)
        for (key, snap) in cached where snap.updated > horizon {
            if let id = UUID(uuidString: key) { snapshots[id] = snap }
        }
    }

    func snapshot(_ w: WidgetInstance) -> ConnSnapshot? {
        #if DEBUG
        if ConnSample.enabled { return ConnSample.snapshot(w) }
        #endif
        guard let s = snapshots[w.id], s.signature == ConnService.signature(w) else { return nil }
        return s
    }

    func error(_ w: WidgetInstance) -> String? {
        #if DEBUG
        if ConnSample.enabled { return nil }
        #endif
        return errors[w.id]
    }

    func isLoading(_ w: WidgetInstance) -> Bool { loading.contains(w.id) }

    /// Long-lived refresh loop for one tile; cancelled with the view's task.
    func keepFresh(_ w: WidgetInstance) async {
        #if DEBUG
        if ConnSample.enabled { return }
        #endif
        while !Task.isCancelled {
            await refresh(w)
            try? await Task.sleep(for: .seconds(ConnService.interval(w)))
        }
    }

    /// Marks the widget so the next `refresh` ignores the freshness window.
    func requestRefresh(_ id: UUID) { forced.insert(id) }

    func refresh(_ w: WidgetInstance) async {
        let id = w.id
        let signature = ConnService.signature(w)
        let force = forced.remove(id) != nil
        if !force, let s = snapshots[id], s.signature == signature,
           Date().timeIntervalSince(s.updated) < ConnService.interval(w) - 20 { return }
        let token = ConnEnv.token(id)
        guard ConnService.isConfigured(w, token: token), !inFlight.contains(id) else { return }
        inFlight.insert(id)
        loading.insert(id)
        defer {
            inFlight.remove(id)
            loading.remove(id)
        }
        do {
            var snap = try await ConnProviders.fetch(w, token: token)
            try Task.checkCancellation()
            snap.signature = signature
            snap.updated = Date()
            if ConnService.keepsHistory(w.kind) { snap = Self.mergeHistory(snap, previous: snapshots[id]) }
            snapshots[id] = snap
            if errors[id] != nil { errors[id] = nil }
            scheduleSave()
        } catch is CancellationError {
        } catch let e as URLError where e.code == .cancelled {
        } catch {
            let message = ConnService.message(for: error)
            if errors[id] != message { errors[id] = message }
        }
    }

    /// Follower-style metrics have no history endpoint, so keep one local sample per day.
    private static func mergeHistory(_ snap: ConnSnapshot, previous: ConnSnapshot?) -> ConnSnapshot {
        guard let value = snap.value else { return snap }
        var out = snap
        let today = ConnDate.day(Date())
        var series = previous?.signature == snap.signature ? previous?.series ?? [] : []
        if previous?.text["historyDay"] == today, !series.isEmpty { series.removeLast() }
        series.append(value)
        out.series = Array(series.suffix(30))
        out.seriesStep = 0
        out.text["historyDay"] = today
        return out
    }

    private func scheduleSave() {
        guard !ConnEnv.isRendering else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            var out: [String: ConnSnapshot] = [:]
            for (id, snap) in self.snapshots { out[id.uuidString] = snap }
            DiskCache.save(out, Self.cacheKey)
        }
    }
}

// MARK: - Per-kind service facts

enum ConnService {
    static func name(_ w: WidgetInstance) -> String {
        switch w.kind {
        case .polarRevenue: return "Polar"
        case .stripeRevenue: return "Stripe"
        case .dodoRevenue: return "Dodo Payments"
        case .shopifyChart, .shopifyToday, .shopifyOverview: return "Shopify"
        case .plausible, .visitorsChart: return "Plausible"
        case .simpleAnalytics: return "Simple Analytics"
        case .dataFast: return "DataFast"
        case .dubStats: return "Dub"
        case .resendStats: return "Resend"
        case .githubContributions: return "GitHub"
        case .supabase: return "Supabase"
        case .socialX: return "X"
        case .socialTikTok: return "TikTok"
        case .socialYouTube: return "YouTube"
        case .aiUsage: return ConnAIProvider(w).name
        default: return w.kind.spec.localizedTitle
        }
    }

    static func brand(_ w: WidgetInstance) -> ConnBrand {
        switch w.kind {
        case .polarRevenue: return .polar
        case .stripeRevenue: return .stripe
        case .dodoRevenue: return .dodo
        case .shopifyChart, .shopifyToday, .shopifyOverview: return .shopify
        case .plausible: return .plausible
        case .visitorsChart: return .visitors
        case .simpleAnalytics: return .simpleAnalytics
        case .dataFast: return .dataFast
        case .dubStats: return .dub
        case .resendStats: return .resend
        case .githubContributions: return .github
        case .supabase: return .supabase
        case .socialX: return .x
        case .socialTikTok: return .tiktok
        case .socialYouTube: return .youtube
        case .aiUsage: return ConnAIProvider(w).brand
        default: return .github
        }
    }

    static func range(_ w: WidgetInstance) -> ConnRange { ConnRange(w.string("range")) }

    static func hasRange(_ kind: WidgetKind) -> Bool {
        kind.spec.fields.contains { $0.key == "range" }
    }

    /// Social counters have no history endpoint; we record our own.
    static func keepsHistory(_ kind: WidgetKind) -> Bool {
        [.socialX, .socialTikTok, .socialYouTube].contains(kind)
    }

    static func usesLocalLogs(_ w: WidgetInstance) -> Bool {
        w.kind == .aiUsage && ConnAIProvider(w).isLocal
    }

    static func isConfigured(_ w: WidgetInstance, token: String?) -> Bool {
        #if DEBUG
        if ConnSample.enabled { return true }
        #endif
        let hasToken = !(token ?? "").isEmpty
        func has(_ key: String) -> Bool { !w.string(key).trimmingCharacters(in: .whitespaces).isEmpty }
        switch w.kind {
        case .shopifyChart, .shopifyToday, .shopifyOverview: return hasToken && has("shop")
        case .plausible, .visitorsChart: return hasToken && has("site")
        // Public Simple Analytics sites need no key.
        case .simpleAnalytics: return has("site")
        case .githubContributions: return has("user") || hasToken
        case .supabase: return hasToken && has("project")
        case .socialX: return hasToken && has("user")
        case .socialYouTube: return hasToken && has("channel")
        case .aiUsage:
            switch ConnAIProvider(w) {
            // Gemini can borrow the gcloud login; it always needs the project.
            case .gemini: return has("project")
            default: return usesLocalLogs(w) || hasToken
            }
        default: return hasToken
        }
    }

    /// Everything that changes what the numbers mean. Tokens are deliberately excluded (persisted).
    static func signature(_ w: WidgetInstance) -> String {
        let keys = w.kind.spec.fields.map(\.key).filter { $0 != "token" }.sorted()
        return ([w.kind.rawValue] + keys.map { "\($0)=\(w.string($0).trimmingCharacters(in: .whitespaces).lowercased())" })
            .joined(separator: "|")
    }

    /// Refresh cadence: 5 min for "today" ranges, 10–15 min otherwise.
    static func interval(_ w: WidgetInstance) -> TimeInterval {
        if w.kind == .shopifyToday || (hasRange(w.kind) && range(w) == .day) { return 300 }
        switch w.kind {
        case .githubContributions, .socialX, .socialTikTok, .socialYouTube: return 900
        case .aiUsage: return 600
        case .resendStats, .supabase: return 600
        default: return 720
        }
    }

    static func dashboardURL(_ w: WidgetInstance) -> URL? {
        let s: String
        func clean(_ key: String) -> String {
            w.string(key).trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        switch w.kind {
        case .polarRevenue: s = "https://polar.sh/dashboard"
        case .stripeRevenue: s = "https://dashboard.stripe.com/balance"
        case .dodoRevenue: s = "https://app.dodopayments.com/"
        case .shopifyChart, .shopifyToday, .shopifyOverview:
            let shop = ConnShopify.normalizedShop(w.string("shop"))
            s = shop.isEmpty ? "https://admin.shopify.com/" : "https://\(shop)/admin"
        case .plausible, .visitorsChart:
            let host = ConnPlausible.host(w)
            s = "\(host)/\(clean("site").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "")"
        case .simpleAnalytics: s = "https://dashboard.simpleanalytics.com/\(clean("site"))"
        case .dataFast: s = "https://datafa.st/dashboard"
        case .dubStats: s = "https://app.dub.co/"
        case .resendStats: s = "https://resend.com/emails"
        case .githubContributions:
            let user = clean("user")
            s = user.isEmpty ? "https://github.com/" : "https://github.com/\(user)"
        case .supabase:
            let ref = clean("project")
            s = ref.isEmpty ? "https://supabase.com/dashboard/projects" : "https://supabase.com/dashboard/project/\(ref)"
        case .socialX:
            s = "https://x.com/\(clean("user").trimmingCharacters(in: CharacterSet(charactersIn: "@")))"
        case .socialTikTok: s = "https://www.tiktok.com/"
        case .socialYouTube:
            let ch = clean("channel")
            s = ch.hasPrefix("UC") ? "https://www.youtube.com/channel/\(ch)" : "https://www.youtube.com/\(ch.hasPrefix("@") ? ch : "@" + ch)"
        case .aiUsage:
            let provider = ConnAIProvider(w)
            if provider == .gemini, let project = clean("project").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed), !project.isEmpty {
                s = "https://console.cloud.google.com/apis/api/generativelanguage.googleapis.com/metrics?project=\(project)"
            } else {
                s = provider.dashboard
            }
        default: return nil
        }
        return URL(string: s)
    }

    static func message(for error: Error) -> String {
        switch error {
        case let e as Net.HTTPError: return e.errorDescription ?? L("Request failed")
        case let e as ConnError: return e.message
        case let e as URLError:
            switch e.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .dnsLookupFailed: return L("Offline")
            case .timedOut: return L("Timed out")
            case .userAuthenticationRequired: return L("Check your token")
            default: return L("Network error")
            }
        case is DecodingError: return L("Unexpected response")
        default:
            if (error as NSError).domain == NSCocoaErrorDomain { return L("Unexpected response") }
            return L("Request failed")
        }
    }
}

// MARK: - Dispatch

enum ConnProviders {
    /// Runs off the main actor (nonisolated async); parsing happens here too.
    static func fetch(_ w: WidgetInstance, token: String?) async throws -> ConnSnapshot {
        let range = ConnService.range(w)
        func need() throws -> String {
            guard let token, !token.isEmpty else { throw ConnError(L("Add your API token")) }
            return token
        }
        switch w.kind {
        case .polarRevenue: return try await ConnPolar.fetch(token: need(), range: range)
        case .stripeRevenue: return try await ConnStripe.fetch(token: need(), range: range)
        case .dodoRevenue: return try await ConnDodo.fetch(token: need(), range: range)
        case .shopifyChart, .shopifyOverview:
            return try await ConnShopify.fetch(shop: w.string("shop"), token: need(), range: range)
        case .shopifyToday:
            return try await ConnShopify.fetch(shop: w.string("shop"), token: need(), range: .day)
        case .plausible, .visitorsChart:
            return try await ConnPlausible.fetch(host: ConnPlausible.host(w), site: w.string("site"), token: need(), range: range)
        case .simpleAnalytics: return try await ConnSimpleAnalytics.fetch(site: w.string("site"), token: token, range: range)
        case .dataFast: return try await ConnDataFast.fetch(token: need(), range: range)
        case .dubStats: return try await ConnDub.fetch(token: need(), range: range)
        case .resendStats: return try await ConnResend.fetch(token: need())
        case .githubContributions: return try await ConnGitHub.fetch(user: w.string("user"), token: token)
        case .supabase: return try await ConnSupabase.fetch(project: w.string("project"), token: need())
        case .socialX: return try await ConnSocial.x(user: w.string("user"), token: need())
        case .socialTikTok: return try await ConnSocial.tiktok(token: need())
        case .socialYouTube: return try await ConnSocial.youtube(channel: w.string("channel"), key: need())
        case .aiUsage:
            switch ConnAIProvider(w) {
            case .claudeCode: return try await ConnLocalUsage.shared.claudeCode(range: range)
            case .codex: return try await ConnLocalUsage.shared.codex(range: range)
            case .opencode: return try await ConnLocalUsage.shared.opencode(range: range)
            case .antigravity: return try await ConnAntigravity.fetch()
            case .anthropic: return try await ConnAIUsageAPI.anthropic(key: need(), range: range)
            case .openai: return try await ConnAIUsageAPI.openai(key: need(), range: range)
            case .cursor: return try await ConnAIUsageAPI.cursor(key: need(), email: w.string("email"), range: range)
            case .copilot: return try await ConnAIUsageAPI.copilot(token: need(), user: w.string("user"), range: range)
            case .gemini:
                let project = w.string("project")
                guard !project.trimmingCharacters(in: .whitespaces).isEmpty else { throw ConnError(L("Add your API token")) }
                let oauth: String
                if let token, !token.isEmpty { oauth = token } else { oauth = try await ConnCLI.gcloudToken() }
                return try await ConnAIUsageAPI.gemini(project: project, token: oauth, range: range)
            case .perplexity: return try await ConnAIUsageAPI.perplexity(key: need(), email: w.string("email"), range: range)
            case .xai: return try await ConnAIUsageAPI.xai(key: need(), range: range)
            case .zai: return try await ConnAIUsageAPI.zai(key: need(), region: w.string("region"), range: range)
            }
        default: throw ConnError(L("Not supported"))
        }
    }
}
