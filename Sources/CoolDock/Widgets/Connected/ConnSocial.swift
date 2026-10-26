import Foundation

private typealias J = ConnJSON

/// Follower counters. History for the panel chart is recorded locally by the store.
enum ConnSocial {
    static func x(user raw: String, token: String) async throws -> ConnSnapshot {
        var user = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = user.range(of: "/", options: .backwards) { user = String(user[r.upperBound...]) }
        user = user.trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        guard !user.isEmpty, let encoded = user.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw ConnError(L("Add your username"))
        }
        let url = try ConnHTTP.url("https://api.x.com/2/users/by/username/\(encoded)", [("user.fields", "public_metrics")])
        let obj = try await ConnHTTP.object(url, headers: ConnHTTP.bearer(token))
        guard let followers = J.num(J.path(obj, "data.public_metrics.followers_count")) else {
            throw ConnError(J.str(J.array(obj["errors"]).first?["detail"]) ?? L("User not found"))
        }
        var snap = ConnSnapshot()
        snap.value = followers
        snap.text[ConnKey.name] = J.str(J.path(obj, "data.name"))
        return snap
    }

    static func tiktok(token: String) async throws -> ConnSnapshot {
        let url = try ConnHTTP.url("https://open.tiktokapis.com/v2/user/info/", [("fields", "follower_count,display_name")])
        let obj = try await ConnHTTP.object(url, headers: ConnHTTP.bearer(token))
        if let code = J.str(J.path(obj, "error.code")), code != "ok" {
            throw ConnError(J.str(J.path(obj, "error.message")).flatMap { $0.isEmpty ? nil : $0 } ?? L("Check your token"))
        }
        guard let followers = J.num(J.path(obj, "data.user.follower_count")) else { throw ConnError(L("Unexpected response")) }
        var snap = ConnSnapshot()
        snap.value = followers
        snap.text[ConnKey.name] = J.str(J.path(obj, "data.user.display_name"))
        return snap
    }

    static func youtube(channel raw: String, key: String) async throws -> ConnSnapshot {
        var channel = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if channel.contains("youtube.com/") {
            let parts = channel.split(separator: "/").map(String.init)
            if let i = parts.firstIndex(of: "channel"), i + 1 < parts.count { channel = parts[i + 1] } else if let handle = parts.first(where: { $0.hasPrefix("@") }) { channel = handle }
        }
        guard !channel.isEmpty else { throw ConnError(L("Add your channel")) }
        let isID = channel.hasPrefix("UC") && channel.count == 24 && !channel.contains("@")
        let selector = isID ? ("id", channel) : ("forHandle", channel.hasPrefix("@") ? channel : "@" + channel)
        let url = try ConnHTTP.url("https://www.googleapis.com/youtube/v3/channels", [("part", "statistics,snippet"), selector, ("key", key)])
        let obj = try await ConnHTTP.object(url)
        guard let item = J.array(obj["items"]).first else { throw ConnError(L("Channel not found")) }
        if (J.path(item, "statistics.hiddenSubscriberCount") as? Bool) == true { throw ConnError(L("Subscriber count is hidden")) }
        guard let subs = J.num(J.path(item, "statistics.subscriberCount")) else { throw ConnError(L("Unexpected response")) }
        var snap = ConnSnapshot()
        snap.value = subs
        snap.text[ConnKey.name] = J.str(J.path(item, "snippet.title"))
        return snap
    }
}
