import Foundation
import Observation
import SwiftUI

/// A subscribed iCalendar (ICS / webcal) feed. The list lives in `Settings.calendarFeeds`; links that carry a
/// secret token (Google's "secret address", iCloud/Outlook published links, …) are kept in the Keychain instead.
struct CalendarFeed: Codable, Equatable, Hashable, Identifiable {
    var id = UUID()
    /// User-visible name; empty until the user types one or the feed reports `X-WR-CALNAME`.
    var name = ""
    var color = CalendarFeed.palette[0]
    /// The link, or nil when it is stored in the Keychain (`Secrets`, key `secretKey`).
    var url: String?
    /// Host shown in Settings (the only part of a private link that is displayed).
    var host = ""
    var enabled = true

    static let secretKey = "feedURL"
    static let palette = ["#007AFF", "#34C759", "#FF9500", "#AF52DE", "#FF2D55", "#5AC8FA", "#FFCC00", "#FF3B30", "#A2845E"]

    var isPrivate: Bool { url == nil }
    var link: String? { url ?? Secrets.get(id, Self.secretKey) }
    var displayName: String { name.isEmpty ? host : name }

    static func nextColor(after hex: String) -> String {
        let i = palette.firstIndex(of: hex.uppercased()) ?? -1
        return palette[(i + 1) % palette.count]
    }

    /// webcal:// and webcals:// become https://, a bare host gets https://. Nil for anything that isn't an http(s) link.
    static func normalize(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(where: \.isWhitespace) else { return nil }
        let lower = s.lowercased()
        if lower.hasPrefix("webcals://") { s = "https://" + s.dropFirst(10) } else if lower.hasPrefix("webcal://") {
            s = "https://" + s.dropFirst(9)
        } else if !lower.contains("://") {
            // "mailto:…", "file:…": another scheme. "host:8080/…" is a port, not a scheme.
            let head = lower.prefix { $0 != "/" }
            if let colon = head.firstIndex(of: ":"), !(head[head.index(after: colon)...].first?.isNumber ?? false) { return nil }
            s = "https://" + s
        }
        guard var c = URLComponents(string: s), let scheme = c.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = c.host, host.contains(".") || host == "localhost" else { return nil }
        c.scheme = scheme
        return c.url
    }

    /// True for links that work as a password: anyone holding them can read the calendar.
    static func isSecret(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        let path = url.path.lowercased()
        if url.user != nil || url.password != nil { return true }
        if host.hasSuffix("google.com") {
            if path.contains("/private-") { return true }
            if path.contains("/public/") { return false }
        }
        if host == "calendars.icloud.com" && path.hasPrefix("/holidays/") { return false }
        if host.hasSuffix("icloud.com") && path.contains("/published/") { return true }
        if (host.hasPrefix("outlook.") || host.hasSuffix(".outlook.com") || host.hasSuffix("office365.com")) && path.contains("/calendar/") { return true }
        if host == "user.fm" || host.hasSuffix(".fastmail.com") { return true }
        let credentialNames = ["token", "key", "secret", "auth", "sig", "signature", "pass", "password", "passphrase", "access", "private", "hash"]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            let name = item.name.lowercased()
            if credentialNames.contains(where: { name.contains($0) }) { return true }
        }
        // A long random-looking path segment (letters and digits, no "@") is almost always an access token.
        return url.pathComponents.contains { seg in
            let s = seg.removingPercentEncoding ?? seg
            return s.count >= 20 && !s.contains("@") && !s.contains(".") && s.contains(where: \.isNumber) && s.contains(where: \.isLetter)
        }
    }
}

/// Fetches and expands the subscribed feeds for the calendar widgets. Demand-driven: `CalendarService` starts it
/// while a calendar widget is on screen; it then refreshes every 15 minutes, off the main thread, and keeps the
/// last download in `DiskCache` so tiles fill instantly after launch. Nothing runs in the reference scene.
@Observable
@MainActor
final class CalendarFeedService {
    static let shared = CalendarFeedService()
    static let refreshInterval: TimeInterval = 15 * 60

    struct Status: Equatable {
        var updated: Date?
        var events = 0
        var error: String?
        var loading = false
    }

    enum FeedError: Error { case notCalendar }

    private(set) var status: [UUID: Status] = [:]
    /// Set by "Add calendar feed…" so Settings focuses the link field when it appears.
    var focusAdd = false

    @ObservationIgnored private var parsed: [UUID: ICS.Feed] = [:]
    @ObservationIgnored private var fetched: [UUID: Date] = [:]
    @ObservationIgnored private var inFlight = Set<UUID>()
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var expandedKey = ""
    @ObservationIgnored private var expanded: [DockEvent] = []

    private struct Cached: Codable {
        var fetched: Date
        var body: String
    }

    var feeds: [CalendarFeed] {
        if RenderHarness.isActive { return Self.renderFeeds }
        return AppStore.shared.settings.calendarFeeds ?? []
    }

    var hasFeeds: Bool { !ReferenceScene.isActive && feeds.contains { $0.enabled } }

    // MARK: Lifecycle

    func start() {
        guard loop == nil, !ReferenceScene.isActive else { return }
        loop = Task { [weak self] in
            await self?.restore()
            while !Task.isCancelled {
                await self?.refresh(force: false)
                try? await Task.sleep(for: .seconds(Self.refreshInterval))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Downloads every enabled feed that is older than the refresh interval (or all of them when forced).
    func refresh(force: Bool) async {
        guard !RenderHarness.isActive, !ReferenceScene.isActive else { return }
        for feed in feeds where feed.enabled { await refresh(feed, force: force) }
    }

    private func refresh(_ feed: CalendarFeed, force: Bool) async {
        let id = feed.id
        if !force, let t = fetched[id], Date().timeIntervalSince(t) < Self.refreshInterval - 20 { return }
        guard !inFlight.contains(id) else { return }
        guard let link = feed.link, let url = CalendarFeed.normalize(link) else {
            status[id, default: Status()].error = L("Private link missing — add the feed again")
            return
        }
        inFlight.insert(id)
        status[id, default: Status()].loading = true
        defer {
            inFlight.remove(id)
            status[id]?.loading = false
        }
        do {
            let data = try await Net.data(url, headers: ["Accept": "text/calendar, text/plain;q=0.8, */*;q=0.5"])
            let (ics, body) = try await Self.decode(data)
            try Task.checkCancellation()
            let now = Date()
            apply(id, ics, fetched: now)
            DiskCache.save(Cached(fetched: now, body: body), Self.cacheKey(id))
        } catch is CancellationError {
        } catch let e as URLError where e.code == .cancelled {
        } catch {
            status[id, default: Status()].error = Self.message(error)
        }
    }

    /// Last downloads from disk (or the developer render files), parsed off the main thread.
    private func restore() async {
        if RenderHarness.isActive {
            for feed in Self.renderFeeds {
                guard let path = feed.url.flatMap(URL.init(string:)), let data = try? Data(contentsOf: path),
                      let (ics, _) = try? await Self.decode(data) else { continue }
                apply(feed.id, ics, fetched: Date())
            }
            return
        }
        for feed in feeds where parsed[feed.id] == nil {
            let key = Self.cacheKey(feed.id)
            let restored: (Date, ICS.Feed)? = await Task.detached(priority: .utility) {
                guard let cached = DiskCache.load(Cached.self, key) else { return nil }
                return (cached.fetched, ICS.parse(cached.body))
            }.value
            if let (date, ics) = restored, parsed[feed.id] == nil { apply(feed.id, ics, fetched: date) }
        }
    }

    nonisolated static func decode(_ data: Data) async throws -> (ICS.Feed, String) {
        try await Task.detached(priority: .utility) {
            let body = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
            guard body.range(of: "BEGIN:VCALENDAR", options: .caseInsensitive) != nil else { throw FeedError.notCalendar }
            return (ICS.parse(body), body)
        }.value
    }

    private func apply(_ id: UUID, _ ics: ICS.Feed, fetched date: Date) {
        parsed[id] = ics
        fetched[id] = date
        status[id] = Status(updated: date, events: ics.events.count)
        if !RenderHarness.isActive, let name = ics.name, let feed = feeds.first(where: { $0.id == id }), feed.name.isEmpty {
            mutate { list in
                if let i = list.firstIndex(where: { $0.id == id }) { list[i].name = String(name.prefix(40)) }
            }
        }
        invalidate()
    }

    private func invalidate() {
        expandedKey = ""
        CalendarService.shared.reloadEvents()
    }

    static func message(_ error: Error) -> String {
        if let e = error as? Net.HTTPError, [401, 403, 404, 410].contains(e.status) { return L("Link not found or no longer shared") }
        if error is FeedError { return L("Not an iCalendar feed") }
        return error.localizedDescription
    }

    private static func cacheKey(_ id: UUID) -> String { "calfeed-" + id.uuidString }

    // MARK: Events

    /// Occurrences of every enabled feed overlapping [from, to), cached per window and feed list.
    func events(from: Date, to: Date) -> [DockEvent] {
        guard !ReferenceScene.isActive else { return [] }
        let active = feeds.filter { $0.enabled && parsed[$0.id] != nil }
        let key = "\(from.timeIntervalSince1970)|\(to.timeIntervalSince1970)|\(TimeZone.current.identifier)|"
            + active.map { "\($0.id)\($0.color)\($0.name)" }.joined(separator: ",")
        if key == expandedKey { return expanded }
        var out: [DockEvent] = []
        for feed in active {
            guard let ics = parsed[feed.id] else { continue }
            let color = Color(hex: feed.color)
            let calendar = feed.name.isEmpty ? (ics.name ?? feed.host) : feed.name
            for o in ICS.occurrences(ics.events, from: from, to: to) {
                out.append(DockEvent(id: "\(feed.id.uuidString)|\(o.uid)|\(Int(o.start.timeIntervalSince1970))",
                                     title: o.title.isEmpty ? L("Untitled") : o.title, start: o.start, end: o.end, allDay: o.allDay,
                                     color: color, calendar: calendar,
                                     meetingURL: CalendarService.meetingURL(url: o.url, location: o.location,
                                                                            notes: [o.conference, o.notes].compactMap { $0 }.joined(separator: "\n")),
                                     location: o.location))
            }
        }
        expanded = out
        expandedKey = key
        return out
    }

    // MARK: Editing (Settings)

    /// Adds a feed and downloads it right away. Returns a message when the link can't be used.
    func add(_ raw: String) -> String? {
        guard let url = CalendarFeed.normalize(raw) else { return L("Enter a webcal:// or https:// link to an .ics calendar.") }
        let absolute = url.absoluteString
        if feeds.contains(where: { $0.link.flatMap(CalendarFeed.normalize)?.absoluteString == absolute }) { return L("This feed is already added.") }
        var feed = CalendarFeed()
        feed.host = url.host ?? ""
        let used = Set(feeds.map(\.color))
        feed.color = CalendarFeed.palette.first { !used.contains($0) } ?? CalendarFeed.palette[feeds.count % CalendarFeed.palette.count]
        if CalendarFeed.isSecret(url) {
            Secrets.set(absolute, feed.id, CalendarFeed.secretKey)
        } else {
            feed.url = absolute
        }
        mutate { $0.append(feed) }
        Task { await refresh(feed, force: true) }
        return nil
    }

    func remove(_ id: UUID) {
        Secrets.set(nil, id, CalendarFeed.secretKey)
        try? FileManager.default.removeItem(at: DiskCache.url(Self.cacheKey(id)))
        parsed[id] = nil
        fetched[id] = nil
        status[id] = nil
        mutate { $0.removeAll { $0.id == id } }
        invalidate()
    }

    func update(_ id: UUID, _ change: (inout CalendarFeed) -> Void) {
        mutate { list in
            if let i = list.firstIndex(where: { $0.id == id }) { change(&list[i]) }
        }
        if let feed = feeds.first(where: { $0.id == id }), feed.enabled, parsed[id] == nil { Task { await refresh(feed, force: true) } }
        invalidate()
    }

    private func mutate(_ change: (inout [CalendarFeed]) -> Void) {
        guard !RenderHarness.isActive else { return }
        var list = AppStore.shared.settings.calendarFeeds ?? []
        change(&list)
        AppStore.shared.settings.calendarFeeds = list
    }

    // MARK: Developer renders

    /// `COOLDOCK_ICS_FILE=/a.ics:/b.ics CoolDock --render <dir> <kinds>` shows local ICS files instead of the saved
    /// feeds (no network, no Keychain). Read only by the render harness, never in the reference scene.
    nonisolated static let renderFiles: [String] = {
        guard RenderHarness.isActive, !ReferenceScene.isActive,
              let raw = ProcessInfo.processInfo.environment["COOLDOCK_ICS_FILE"], !raw.isEmpty else { return [] }
        return raw.split(separator: ":").map(String.init)
    }()

    static let renderFeeds: [CalendarFeed] = renderFiles.enumerated().map { i, path in
        var feed = CalendarFeed()
        feed.id = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", i + 1)) ?? UUID()
        feed.color = palette(i)
        feed.url = URL(fileURLWithPath: path).absoluteString
        feed.host = (path as NSString).lastPathComponent
        return feed
    }

    private static func palette(_ i: Int) -> String { CalendarFeed.palette[i % CalendarFeed.palette.count] }
}
