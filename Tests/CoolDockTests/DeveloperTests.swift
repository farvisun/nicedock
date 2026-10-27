import Foundation
import Testing
@testable import CoolDock

/// Resend — fixtures follow https://resend.com/docs/api-reference/emails/list-emails (verbatim item
/// shape incl. the Postgres-style `created_at` "2026-04-03 22:13:42.674981+00", `object/has_more/data`
/// envelope) and cursor pagination per https://resend.com/docs/api-reference/pagination (`after=<id>`).
@Suite(.timeZone("UTC")) struct ResendTests {
    let now = TestDate.local(2026, 10, 27, 15)

    @Test func pagesUntilPreviousMonth() async throws {
        let server = FixtureServer { url in
            FixtureServer.query(url)["after"] == nil ? ("resend/emails-page1-docs-2026-10-27.json", [:])
                                                     : ("resend/emails-page2-docs-2026-10-27.json", [:])
        }
        let snap = try await ConnResend.fetch(token: "re_x", now: now, send: server.send)

        // Page 2 still says has_more, but it already reaches September — no third request.
        #expect(server.requests.count == 2)
        #expect(FixtureServer.query(server.requests[0])["limit"] == "100")
        #expect(FixtureServer.query(server.requests[1])["after"] == "d3f2e5a6-7182-4c93-adb4-e5f60718293a")

        #expect(snap.value == 2 && snap.metrics[ConnKey.sentToday] == 2)
        #expect(snap.metrics[ConnKey.sentMonth] == 9)  // the 09-30 email is last month
        // Settled (queued excluded) = 8; delivered/opened/clicked = 4.
        #expect(snap.metrics[ConnKey.deliveredRate] == 0.5)
        #expect(snap.metrics[ConnKey.bounced] == 2)     // bounced + complained
        #expect(snap.seriesStart == TestDate.local(2026, 10, 1) && snap.series.count == 27)
        #expect(snap.series[1] == 2 && snap.series[19] == 5 && snap.series[26] == 2 && snap.series.reduce(0, +) == 9)
    }

    @Test func everyDocumentedDateParses() throws {
        for file in ["resend/emails-page1-docs-2026-10-27.json", "resend/emails-page2-docs-2026-10-27.json"] {
            let raw = try Fixture.object(file)
            #expect(ConnResend.page(raw).emails.count == ConnJSON.array(raw["data"]).count)
        }
        let first = try #require(ConnResend.page(try Fixture.object("resend/emails-page1-docs-2026-10-27.json")).emails.first)
        #expect(abs(first.date.timeIntervalSince(TestDate.utc("2026-10-27T12:02:42Z")) - 0.674981) < 1e-3)
    }
}

/// Supabase Management API — fixtures follow the OpenAPI spec https://api.supabase.com/api/v1-json
/// (`V1ProjectWithDatabaseResponse`; usage.api-counts `{result: [{timestamp, total_*_requests}]}` with
/// the spec's minute-precision `date-time` pattern), see also
/// https://supabase.com/docs/reference/api/v1-get-project-usage-api-count
@Suite(.timeZone("UTC")) struct SupabaseTests {
    @Test func projectAndRequestCounts() throws {
        let snap = ConnSupabase.parse(project: try Fixture.object("supabase/project-docs-2026-10-27.json"),
                                      usage: try Fixture.json("supabase/usage-api-counts-docs-2026-10-27.json"))
        #expect(snap.text[ConnKey.status] == "ACTIVE_HEALTHY" && ConnSupabase.health(snap.text[ConnKey.status]) == .healthy)
        #expect(snap.text[ConnKey.name] == "acme-production" && snap.text[ConnKey.region] == "eu-central-1")
        #expect(snap.value == 1200 && snap.metrics[ConnKey.requests] == 1200)
        #expect(snap.metrics[ConnKey.restRequests] == 1085 && snap.metrics[ConnKey.authRequests] == 40)
        #expect(snap.metrics[ConnKey.storageRequests] == 71 && snap.metrics[ConnKey.realtimeRequests] == 4)
        // Rows sorted by time; timestamps without seconds parse (they used to become distantPast).
        #expect(snap.series == [440, 310, 450, 0])
        #expect(snap.seriesStart == TestDate.utc("2026-10-26T12:00:00Z") && snap.seriesStep == 3600)
    }

    @Test func errorOnlyUsageKeepsStatus() throws {
        // 200 with `error` and no `result` (allowed by the spec).
        let snap = ConnSupabase.parse(project: try Fixture.object("supabase/project-docs-2026-10-27.json"), usage: ["error": "analytics unavailable"])
        #expect(snap.value == nil && snap.series.isEmpty && snap.text[ConnKey.status] == "ACTIVE_HEALTHY")
    }

    @Test func documentedStatuses() {
        #expect(ConnSupabase.health("COMING_UP") == .starting && ConnSupabase.health("RESTORING") == .starting)
        #expect(ConnSupabase.health("INACTIVE") == .paused)
        #expect(ConnSupabase.health("ACTIVE_UNHEALTHY") == .failing && ConnSupabase.health("INIT_FAILED") == .failing)
    }
}

/// Linear GraphQL — fixture follows the schema https://github.com/linear/linear/blob/master/packages/sdk/src/schema.graphql
/// (`IssueConnection.nodes`, `priority: Float!` 0–4, `dueDate: TimelessDate`, `WorkflowState.color` hex);
/// the auth error is the live 401 body. Docs: https://linear.app/developers/graphql
@Suite(.timeZone("UTC")) struct LinearTests {
    @Test func dueIssuesFirst() throws {
        let issues = try CalLinearAPI.parse(try Fixture.json("linear/assigned-issues-docs-2026-10-27.json"))
        #expect(issues.map(\.identifier) == ["ENG-355", "ENG-377", "ENG-398", "ENG-412", "ENG-360"])
        #expect(issues.map(\.priority) == [4, 1, 3, 2, 0])
        #expect(issues[1].dueDate == "2026-10-28" && CalLinearAPI.priorityMark(issues[1].priority) == "!!")
        #expect(issues[3].stateName == "In Progress" && issues[3].stateColor == "#f2c94c")
        #expect(issues[0].url == "https://linear.app/acme/issue/ENG-355/fix-overdue-invoice-email")
        #expect(CalLinearAPI.dueParser.date(from: issues[0].dueDate!) != nil)
    }

    @Test func authenticationError() throws {
        #expect(throws: CalLinearAPI.GraphQLError.self) { try CalLinearAPI.parse(try Fixture.json("linear/auth-error-2026-10-27.json")) }
        do { _ = try CalLinearAPI.parse(try Fixture.json("linear/auth-error-2026-10-27.json")) } catch let e as CalLinearAPI.GraphQLError {
            #expect(e.message == L("Check your token"))
        }
    }

    @Test func queryExcludesClosedStates() {
        #expect(CalLinearAPI.query.contains(#"nin: ["completed", "canceled", "duplicate"]"#))
    }
}
