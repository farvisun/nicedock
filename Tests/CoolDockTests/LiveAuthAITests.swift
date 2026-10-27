import Foundation
import Testing
@testable import CoolDock

// Live no-key / fake-key answers for the AI usage sources added with Cursor, GitHub Copilot, Gemini API,
// Perplexity, Grok (xAI) and GLM / Z.ai, captured with curl on 2026-10-27 (see LiveAuthTests for the format
// and docs/verification/providers.md). OpenCode and Antigravity read local data and have no endpoint.

@Suite struct LiveAuthAITests {
    let now = TestDate.utc("2026-10-27T01:36:00Z")
    let checkToken = L("Check your token")

    func load(_ name: String) throws -> LiveExchange { try LiveExchange.load(name) }

    @Test func cursor() async throws {
        let invalid = try load("cursor-usage-invalid"), nokey = try load("cursor-usage-nokey")
        let control = try load("cursor-control-badroute"), controlNoKey = try load("cursor-control-badroute-nokey")
        // The Admin API routes before it authenticates: a misspelled path is 404 with or without a key.
        #expect(invalid.status == 401 && nokey.status == 401 && control.status == 404 && controlNoKey.status == 404)
        #expect(invalid.string("message") == "Invalid Team API Key" && nokey.string("message") == "Invalid Team API Key")
        #expect(control.string("message") == "Route POST:/teams/filtered-usage-eventz not found")

        let replay = LiveReplay([.live(invalid)])
        let message = await replay.message { try await ConnAIUsageAPI.cursor(key: "crsr_invalid", email: "", range: .week, now: now) }
        #expect(message == checkToken)
        #expect(replay.requests.count == 1)
        expectSameRequest(replay.requests.first, invalid, volatile: ["startDate", "endDate"])
    }

    @Test func copilot() async throws {
        let usage = try load("copilot-usage-invalid"), nokey = try load("copilot-usage-nokey"), user = try load("copilot-user-invalid")
        let control = try load("copilot-control-badroute"), controlNoKey = try load("copilot-control-badroute-nokey")
        // GitHub routes first: the misspelled billing path is 404 even with a (bad) token.
        #expect(usage.status == 401 && nokey.status == 401 && user.status == 401 && control.status == 404 && controlNoKey.status == 404)
        #expect(usage.string("message") == "Bad credentials" && nokey.string("message") == "Requires authentication")
        #expect(control.string("message") == "Not Found")

        let replay = LiveReplay([.live(usage)])
        let message = await replay.message { try await ConnAIUsageAPI.copilot(token: "ghp_invalid", user: " @octocat ", range: .week, now: now) }
        #expect(message == checkToken)
        expectSameRequest(replay.requests.first, usage)

        // No user name: the token's login is looked up first, and its 401 stops there.
        let me = LiveReplay([.live(user)])
        let meMessage = await me.message { try await ConnAIUsageAPI.copilot(token: "ghp_invalid", user: "", range: .week, now: now) }
        #expect(meMessage == checkToken && me.requests.count == 1)
        expectSameRequest(me.requests.first, user)

        // github/rest-api-description: the path, its parameters and `GET /user`.
        let spec = try LiveSpec.load("copilot-spec")
        #expect(spec.servers == ["https://api.github.com"] && spec.operation("GET", "/user") != nil)
        let op = try #require(spec.operation("GET", "/users/{username}/settings/billing/usage"))
        #expect(op.names == ["username", "year", "month", "day"])
        let day = LiveReplay([.ok("https://api.github.com/users/octocat/settings/billing/usage", json: #"{"usageItems":[]}"#)])
        _ = try await day.run { try await ConnAIUsageAPI.copilot(token: "ghp_invalid", user: "octocat", range: .day, now: now) }
        #expect(Set(queryOf(day.requests.first).keys) == ["year", "month", "day"])
    }

    @Test func gemini() async throws {
        let invalid = try load("gemini-timeseries-invalid"), nokey = try load("gemini-timeseries-nokey"), apiKey = try load("gemini-timeseries-apikey")
        let control = try load("gemini-control-badroute"), controlNoKey = try load("gemini-control-badroute-nokey")
        // Google's front end 404s the misspelled method before auth; ours reaches ListTimeSeries.
        #expect(invalid.status == 401 && nokey.status == 401 && apiKey.status == 401 && control.status == 404 && controlNoKey.status == 404)
        #expect(control.responseHeaders["content-type"]?.hasPrefix("text/html") == true)
        for ex in [invalid, nokey, apiKey] {
            let info = ConnJSON.array(ConnJSON.path(ex.json, "error.details")).first
            #expect(ConnJSON.str(ConnJSON.path(info, "metadata.method")) == "google.monitoring.v3.MetricService.ListTimeSeries", "\(ex.name)")
        }
        // Why the widget takes an OAuth token (or the gcloud login) and not the Gemini API key.
        #expect(apiKey.string("error.message")?.hasPrefix("API keys are not supported by this API.") == true)
        #expect(ConnJSON.str(ConnJSON.path(ConnJSON.array(ConnJSON.path(invalid.json, "error.details")).first, "reason")) == "ACCESS_TOKEN_TYPE_UNSUPPORTED")

        let replay = LiveReplay([.live(invalid)])
        let message = await replay.message { try await ConnAIUsageAPI.gemini(project: " cooldock-demo ", token: "ya29.invalid", range: .week, now: now) }
        #expect(message == checkToken)
        expectSameRequest(replay.requests.first, invalid, volatile: ["interval.startTime", "interval.endTime"])

        // The live discovery document: parameter names and enum values the app sends.
        let spec = try LiveSpec.load("gemini-spec")
        let op = try #require(spec.operation("GET", "/v3/projects/{projectsId}/timeSeries"))
        let q = queryOf(replay.requests.first)
        #expect(Set(q.keys).isSubset(of: op.names))
        #expect(op.enumValues("aggregation.perSeriesAligner").contains(q["aggregation.perSeriesAligner"] ?? ""))
        #expect(op.enumValues("aggregation.crossSeriesReducer").contains(q["aggregation.crossSeriesReducer"] ?? ""))
    }

    @Test func perplexity() async throws {
        let credits = try load("perplexity-credits-invalid"), nokey = try load("perplexity-credits-nokey"), queries = try load("perplexity-queries-invalid")
        let control = try load("perplexity-control-badroute"), controlNoKey = try load("perplexity-control-badroute-nokey")
        #expect(credits.status == 401 && nokey.status == 401 && queries.status == 401 && control.status == 404 && controlNoKey.status == 404)
        #expect(credits.string("error.type") == "invalid_api_key")

        let replay = LiveReplay([.live(credits)])
        let message = await replay.message { try await ConnAIUsageAPI.perplexity(key: "pplx-invalid", email: "", range: .week, now: now) }
        #expect(message == checkToken)
        expectSameRequest(replay.requests.first, credits, volatile: ["start_time"])

        // Query volume is optional: its live 401 leaves the credit total.
        let both = LiveReplay([.live(queries, keys: ["dataset"]),
                               .ok(ConnAIUsageAPI.perplexityUsage, fixture: "perplexity/credit-usage-docs-2026-10-27.json")])
        let snap = try await both.run { try await ConnAIUsageAPI.perplexity(key: "pplx-invalid", email: "", range: .week, now: now) }
        #expect(snap.value == 350 && snap.metrics[ConnKey.calls] == nil)
        expectSameRequest(both.request("/v1/analytics/computer/usage", ["dataset": "query_volume"]), queries, volatile: ["start_time"])

        // docs.perplexity.ai/openapi.json: names, required ones and enums.
        let spec = try LiveSpec.load("perplexity-spec")
        #expect(spec.servers == ["https://api.perplexity.ai"])
        let op = try #require(spec.operation("GET", "/v1/analytics/computer/usage"))
        for request in both.requests {
            let q = queryOf(request)
            #expect(Set(q.keys).isSubset(of: op.names) && op.required.isSubset(of: Set(q.keys)))
            #expect(op.enumValues("dataset").contains(q["dataset"] ?? "") && op.enumValues("bucket_width").contains(q["bucket_width"] ?? ""))
        }
    }

    @Test func xai() async throws {
        let validation = try load("xai-validation-invalid"), nokey = try load("xai-validation-nokey"), usage = try load("xai-usage-invalid")
        let control = try load("xai-control-badroute"), controlNoKey = try load("xai-control-badroute-nokey")
        let usageControl = try load("xai-usage-control-badroute")
        // gRPC-style codes: 16 UNAUTHENTICATED on our paths, 5 NOT_FOUND on misspelled ones even with a key.
        #expect(validation.status == 401 && nokey.status == 401 && usage.status == 401)
        #expect(control.status == 404 && controlNoKey.status == 404 && usageControl.status == 404)
        #expect(ConnJSON.num(validation.object["code"]) == 16 && ConnJSON.num(usageControl.object["code"]) == 5)
        #expect(validation.responseHeaders["www-authenticate"] == "Invalid bearer token. Please ensure you use a valid management key.")

        let replay = LiveReplay([.live(validation)])
        let message = await replay.message { try await ConnAIUsageAPI.xai(key: "xai-mgmt-invalid", range: .week, now: now) }
        #expect(message == checkToken && replay.requests.count == 1)
        expectSameRequest(replay.requests.first, validation)

        // With the documented validation answer the app goes on to the team's usage endpoint.
        let team = LiveReplay([.ok("https://management-api.x.ai/auth/management-keys/validation", fixture: "xai/validation-docs-2026-10-27.json"),
                               .live(usage)])
        let teamMessage = await team.message { try await ConnAIUsageAPI.xai(key: "xai-mgmt-invalid", range: .week, now: now) }
        #expect(teamMessage == checkToken)
        expectSameRequest(team.request("/v1/billing/teams/65c1e471-205f-4566-9c5a-07198badf4ce/usage"), usage,
                          volatile: ["startTime", "endTime", "timezone"])
    }

    @Test func zai() async throws {
        let invalid = try load("zai-usage-invalid"), nokey = try load("zai-usage-nokey"), bearer = try load("zai-usage-invalid-bearer")
        let china = try load("zai-bigmodel-invalid")
        let control = try load("zai-control-badroute"), controlNoKey = try load("zai-control-badroute-nokey")
        // Errors are HTTP 200 envelopes. Z.ai authenticates before routing (a misspelled path gets the same
        // answers), so the route rests on Z.ai's own plugin source, which calls exactly this path.
        for ex in [invalid, nokey, bearer, china, control, controlNoKey] {
            #expect(ex.status == 200 && (ex.object["success"] as? Bool) == false, "\(ex.name)")
            #expect(throws: ConnError(checkToken), "\(ex.name)") { try ConnAIUsageAPI.zaiCheck(ex.object) }
        }
        #expect(ConnJSON.num(invalid.object["code"]) == 401 && ConnJSON.num(nokey.object["code"]) == 1001)
        #expect(invalid.string("msg") == "token expired or incorrect")

        let replay = LiveReplay([.live(invalid)])
        let message = await replay.message { try await ConnAIUsageAPI.zai(key: "zai-invalid", region: "global", range: .week, now: now) }
        #expect(message == checkToken)
        expectSameRequest(replay.requests.first, invalid, volatile: ["startTime", "endTime"])
        // The raw key, as the official plugin sends it (no `Bearer`).
        #expect(replay.requests.first?.value(forHTTPHeaderField: "Authorization") == "zai-invalid")

        let cn = LiveReplay([.live(china)])
        let cnMessage = await cn.message { try await ConnAIUsageAPI.zai(key: "zai-invalid", region: "china", range: .week, now: now) }
        #expect(cnMessage == checkToken)
        expectSameRequest(cn.requests.first, china, volatile: ["startTime", "endTime"])
    }
}
