import Foundation
import Testing
@testable import CoolDock

/// X API v2 — verbatim success example of https://docs.x.com/x-api/fundamentals/fields (this endpoint
/// with `user.fields=…public_metrics`) and the not-found body of
/// https://docs.x.com/x-api/users/lookup/quickstart/user-lookup ; endpoint https://docs.x.com/x-api/users/get-user-by-username
@Suite struct XTests {
    @Test func followers() throws {
        let snap = try ConnSocial.parseX(try Fixture.object("x/user-by-username-docs-2026-10-27.json"))
        #expect(snap.value == 570842 && snap.text[ConnKey.name] == "X Developers")
    }

    @Test func notFoundSurfacesDetail() throws {
        #expect(throws: ConnError("Could not find user with username: [nonexistent_user].")) {
            try ConnSocial.parseX(try Fixture.object("x/user-not-found-docs-2026-10-27.json"))
        }
        // Problem bodies (application/problem+json) carry `detail` at the top level.
        #expect(throws: ConnError("The 'query' parameter is required.")) {
            try ConnSocial.parseX(["title": "Invalid Request", "detail": "The 'query' parameter is required.", "type": "https://api.x.com/2/problems/invalid-request"])
        }
    }

    @Test func usernameInput() {
        #expect(ConnSocial.xUsername(" https://x.com/XDevelopers ") == "XDevelopers")
        #expect(ConnSocial.xUsername("@jack") == "jack")
    }
}

/// TikTok Display API — https://developers.tiktok.com/doc/tiktok-api-v2-get-user-info : response is
/// `{data: {user: {...}}, error: {code, message, log_id}}`. The docs' only example requests other
/// fields, so the success fixture is built from the field table (`follower_count` int64,
/// `display_name` string); the error is the verbatim struct of https://developers.tiktok.com/doc/tiktok-api-v2-error-handling
@Suite struct TikTokTests {
    @Test func followers() throws {
        let snap = try ConnSocial.parseTikTok(try Fixture.object("tiktok/user-info-docs-2026-10-27.json"))
        #expect(snap.value == 48213 && snap.text[ConnKey.name] == "Acme Studio")
    }

    @Test func errorCode() throws {
        #expect(throws: ConnError("Access token is invalid, please refresh token and retry")) {
            try ConnSocial.parseTikTok(try Fixture.object("tiktok/user-info-error-docs-2026-10-27.json"))
        }
    }
}

/// YouTube Data API v3 channels.list — https://developers.google.com/youtube/v3/docs/channels/list and the
/// channel resource https://developers.google.com/youtube/v3/docs/channels (statistics counts are
/// string-encoded uint64 per the discovery document; `subscriberCount` rounded to 3 significant figures).
@Suite struct YouTubeTests {
    @Test func subscribers() throws {
        let snap = try ConnSocial.parseYouTube(try Fixture.object("youtube/channels-list-docs-2026-10-27.json"))
        #expect(snap.value == 2_510_000 && snap.text[ConnKey.name] == "Google for Developers")
    }

    @Test func hiddenAndMissing() throws {
        var raw = try Fixture.object("youtube/channels-list-docs-2026-10-27.json")
        var item = ConnJSON.array(raw["items"])[0]
        item["statistics"] = ["viewCount": "1", "hiddenSubscriberCount": true, "videoCount": "2"]
        raw["items"] = [item]
        #expect(throws: ConnError(L("Subscriber count is hidden"))) { try ConnSocial.parseYouTube(raw) }

        // No match: `items` empty or omitted.
        #expect(throws: ConnError(L("Channel not found"))) { try ConnSocial.parseYouTube(["kind": "youtube#channelListResponse", "items": [Any]()]) }
        #expect(throws: ConnError(L("Channel not found"))) { try ConnSocial.parseYouTube(["kind": "youtube#channelListResponse", "pageInfo": ["totalResults": 0]]) }
    }

    @Test func channelSelector() {
        #expect(ConnSocial.youtubeSelector("https://www.youtube.com/channel/UC_x5XG1OV2P6uZZ5FSM9Ttw")! == ("id", "UC_x5XG1OV2P6uZZ5FSM9Ttw"))
        #expect(ConnSocial.youtubeSelector("https://www.youtube.com/@GoogleDevelopers/videos")! == ("forHandle", "@GoogleDevelopers"))
        #expect(ConnSocial.youtubeSelector("mkbhd")! == ("forHandle", "@mkbhd"))
        #expect(ConnSocial.youtubeSelector("  ") == nil)
    }
}
