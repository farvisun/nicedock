import AppKit
import Observation
import SwiftUI

/// Watches launches/quits of one app so tiles can flip between live data and "Open …" instantly.
@MainActor
private final class MediaAppWatcher {
    private var tokens: [NSObjectProtocol] = []

    init(bundleID: String, onChange: @escaping @MainActor (Bool) -> Void) {
        let nc = NSWorkspace.shared.notificationCenter
        for (name, running) in [(NSWorkspace.didLaunchApplicationNotification, true), (NSWorkspace.didTerminateApplicationNotification, false)] {
            tokens.append(nc.addObserver(forName: name, object: nil, queue: .main) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == bundleID else { return }
                MainActor.assumeIsolated { onChange(running) }
            })
        }
    }
}

// MARK: - Mail service

struct MediaMailSnapshot: Codable, Equatable {
    var unread: Int
    var today: Int
    var sender: String
    var subject: String
}

/// Unread mail via AppleScript — only while Mail is already running (never launches it).
@Observable
@MainActor
final class MediaMailService {
    static let shared = MediaMailService()
    static let bundleID = "com.apple.mail"

    private(set) var running = Script.isRunning(MediaMailService.bundleID)
    private(set) var snapshot: MediaMailSnapshot? = DiskCache.load(MediaMailSnapshot.self, "media-mail")
    @ObservationIgnored private var lastFetch = Date.distantPast
    @ObservationIgnored private var inFlight = false
    @ObservationIgnored private var watcher: MediaAppWatcher?
    /// Whether Mail runs, and the AppleScript bridge. Tests stand in for both, so no Automation prompt appears.
    @ObservationIgnored var isRunning: (String) -> Bool = { Script.isRunning($0) }
    @ObservationIgnored var runScript: (String) async -> NSAppleEventDescriptor? = { await Script.run($0) }

    private init() {
        watcher = MediaAppWatcher(bundleID: Self.bundleID) { running in
            let s = MediaMailService.shared
            s.running = running
            if running { Task { try? await Task.sleep(for: .seconds(3)); await s.refresh(force: true) } }
        }
    }

    /// Two-minute refresh loop for a visible tile (cancelled with the view's task).
    func keepFresh() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(120))
        }
    }

    func refresh(force: Bool = false) async {
        running = isRunning(Self.bundleID)
        guard running, !MediaEnv.isRender, !inFlight else { return }
        guard force || Date().timeIntervalSince(lastFetch) > 60 else { return }
        inFlight = true
        defer { inFlight = false }
        let src = """
        tell application "Mail"
            set n to unread count of inbox
            set t to 0
            set s to ""
            set subj to ""
            if n > 0 then
                try
                    set d to current date
                    set time of d to 0
                    set t to count of (messages of inbox whose read status is false and date received is greater than or equal to d)
                end try
                try
                    set m to first message of inbox whose read status is false
                    set s to extract name from (sender of m)
                    set subj to subject of m
                end try
            end if
            return {n, t, s, subj}
        end tell
        """
        guard let d = await runScript(src), d.numberOfItems >= 4 else { return }
        lastFetch = Date()
        let snap = MediaMailSnapshot(unread: Int(d.atIndex(1)?.int32Value ?? 0), today: Int(d.atIndex(2)?.int32Value ?? 0),
                                     sender: d.atIndex(3)?.stringValue ?? "", subject: d.atIndex(4)?.stringValue ?? "")
        if snap != snapshot {
            snapshot = snap
            DiskCache.save(snap, "media-mail")
        }
    }

    /// What tiles display: live data, sample data for demo renders, or nil when Mail is closed.
    var display: MediaMailSnapshot? {
        if ReferenceScene.isActive { return MediaScene.mail }
        if MediaEnv.demo { return MediaMailSnapshot(unread: 12, today: 3, sender: "Alex Morgan", subject: "Project kickoff timeline") }
        return running ? snapshot : nil
    }
}

// MARK: - Mail tiles

/// Mail app-style icon: blue gradient squircle with a frosted glass envelope (brand surface).
struct MediaMailIcon: View {
    @Environment(\.metrics) private var m
    var size: CGFloat = 36

    var body: some View {
        let s = m.u(size)
        Canvas { ctx, sz in
            let w = sz.width, h = sz.height
            let tile = AppIconFinish.shape(sz)
            ctx.fill(tile, with: .linearGradient(Gradient(colors: [Color(hex: "#5CC4F7"), Color(hex: "#1B6EFB")]),
                                                 startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
            // Frosted body with a soft drop shadow, lighter fold lines, opaque white top flap.
            let body = CGRect(x: w * 0.126, y: h * 0.249, width: w * 0.75, height: h * 0.5)
            let bodyPath = Path(roundedRect: body, cornerRadius: w * 0.05, style: .continuous)
            var shadowCtx = ctx
            shadowCtx.addFilter(.shadow(color: Color(hex: "#0A3C9B").opacity(0.3), radius: w * 0.03, y: w * 0.02))
            shadowCtx.fill(bodyPath, with: .linearGradient(Gradient(colors: [.white.opacity(0.9), .white.opacity(0.5)]),
                                                           startPoint: CGPoint(x: 0, y: body.minY), endPoint: CGPoint(x: 0, y: body.maxY)))
            var inner = ctx
            inner.clip(to: bodyPath)
            var folds = Path()
            folds.move(to: CGPoint(x: body.minX, y: body.maxY))
            folds.addLine(to: CGPoint(x: body.midX, y: body.minY + body.height * 0.4))
            folds.addLine(to: CGPoint(x: body.maxX, y: body.maxY))
            inner.stroke(folds, with: .color(.white.opacity(0.5)), lineWidth: w * 0.03)
            var flap = Path()
            flap.move(to: CGPoint(x: body.minX, y: body.minY))
            flap.addLine(to: CGPoint(x: body.midX, y: body.minY + body.height * 0.66))
            flap.addLine(to: CGPoint(x: body.maxX, y: body.minY))
            flap.closeSubpath()
            inner.fill(flap, with: .color(.white))
            inner.stroke(flap, with: .color(.white), style: StrokeStyle(lineWidth: w * 0.04, lineJoin: .round))
        }
        .frame(width: s, height: s)
        .appIconSoftness(s)
    }
}

struct MediaMailTile: View {
    let w: WidgetInstance
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p

    var body: some View {
        let svc = MediaMailService.shared
        let snap = svc.display
        Tile(width: w.kind.spec.width, padding: EdgeInsets(top: 1, leading: 16, bottom: 0, trailing: 13)) {
            HStack(spacing: 0) {
                MediaMailIcon(size: 36)
                VStack(alignment: .leading, spacing: m.u(1)) {
                    if let snap {
                        // 22 pt, half a device pixel left of the column (the frame's sub-pixel placement).
                        T(Fmt.int(snap.unread)).dock(22, .bold, mono: true)
                            .transformEffect(CGAffineTransform(translationX: m.u(-0.25), y: 0))
                        HStack(spacing: m.u(4)) {
                            Text(L("Unread"))
                            if snap.today > 0 {
                                Text(verbatim: "·")
                                Text(L("+%@ today", Fmt.int(snap.today)))
                            }
                        }
                        // Tabular digits like the count above ("+3" is as wide as in the reference frame).
                        .font(.dock(m.u(9), .semibold, mono: true))
                        .foregroundStyle(p.secondary)
                        .lineLimit(1)
                        .padding(.leading, m.u(-0.75))
                    } else {
                        Text(L("Mail")).dock(19, .bold)
                        Text(L("Open Mail")).dock(9, .semibold, p.secondary)
                    }
                }
                .padding(.leading, m.u(12.5))
                Spacer(minLength: m.u(6))
                MediaComposeButton { Open.url("mailto:") }
            }
        }
        .onTapGesture { Open.bundle(MediaMailService.bundleID) }
        .task { await svc.keepFresh() }
        .onWidgetRefresh(w.id) { Task { await svc.refresh(force: true) } }
    }
}

struct MediaMailLatestTile: View {
    let w: WidgetInstance
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p

    var body: some View {
        let svc = MediaMailService.shared
        let snap = svc.display
        Tile(width: w.kind.spec.width, padding: EdgeInsets(top: 1, leading: 17, bottom: 0, trailing: 13)) {
            HStack(spacing: 0) {
                MediaMailIcon(size: 36)
                VStack(alignment: .leading, spacing: m.u(2)) {
                    if let snap, snap.unread > 0 {
                        Text(snap.sender.isEmpty ? L("New mail") : L("%@ sent", snap.sender)).dock(9, .medium, p.secondary)
                        Text(snap.subject.isEmpty ? L("(No Subject)") : snap.subject).dock(13, .bold)
                            .padding(.top, m.u(1))
                        if snap.unread > 1 {
                            Text(L("+%@ more unread", Fmt.int(snap.unread - 1))).dock(9, .medium, p.secondary)
                                .padding(.top, m.u(1))
                        }
                    } else if snap != nil {
                        Text(L("Inbox")).dock(9, .medium, p.secondary)
                        Text(L("No unread mail")).dock(13, .bold)
                        Text(L("All caught up")).dock(9, .medium, p.secondary)
                    } else {
                        Text(L("Mail")).dock(13, .bold)
                        Text(L("Open Mail")).dock(9, .medium, p.secondary)
                    }
                }
                .offset(y: m.u(-0.25))
                .padding(.leading, m.u(12))
                Spacer(minLength: m.u(6))
                MediaComposeButton { Open.url("mailto:") }
            }
        }
        .onTapGesture { Open.bundle(MediaMailService.bundleID) }
        .task { await svc.keepFresh() }
        .onWidgetRefresh(w.id) { Task { await svc.refresh(force: true) } }
    }
}

// MARK: - Notes service

struct MediaNoteSnapshot: Codable, Equatable {
    var title: String
    var body: String
    var count: Int
}

@Observable
@MainActor
final class MediaNotesService {
    static let shared = MediaNotesService()
    static let bundleID = "com.apple.Notes"

    private(set) var running = Script.isRunning(MediaNotesService.bundleID)
    private(set) var snapshot: MediaNoteSnapshot? = DiskCache.load(MediaNoteSnapshot.self, "media-notes")
    @ObservationIgnored private var lastFetch = Date.distantPast
    @ObservationIgnored private var inFlight = false
    @ObservationIgnored private var watcher: MediaAppWatcher?
    /// Whether Notes runs, and the AppleScript bridge. Tests stand in for both, so no Automation prompt appears.
    @ObservationIgnored var isRunning: (String) -> Bool = { Script.isRunning($0) }
    @ObservationIgnored var runScript: (String) async -> NSAppleEventDescriptor? = { await Script.run($0) }

    private init() {
        watcher = MediaAppWatcher(bundleID: Self.bundleID) { running in
            let s = MediaNotesService.shared
            s.running = running
            if running { Task { try? await Task.sleep(for: .seconds(2)); await s.refresh(force: true) } }
        }
    }

    func keepFresh() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(120))
        }
    }

    func refresh(force: Bool = false) async {
        running = isRunning(Self.bundleID)
        guard running, !MediaEnv.isRender, !inFlight else { return }
        guard force || Date().timeIntervalSince(lastFetch) > 60 else { return }
        inFlight = true
        defer { inFlight = false }
        // Pick the most recently modified note that is not in Recently Deleted.
        let src = """
        tell application "Notes"
            set ds to modification date of every note
            set c to count of ds
            if c = 0 then return {"", "", 0}
            repeat 5 times
                set best to 0
                set bestDate to missing value
                repeat with i from 1 to c
                    set d to item i of ds
                    if d is not missing value then
                        if bestDate is missing value then
                            set bestDate to d
                            set best to i
                        else if d > bestDate then
                            set bestDate to d
                            set best to i
                        end if
                    end if
                end repeat
                if best = 0 then exit repeat
                set n to note best
                set isTrash to false
                try
                    if name of container of n is "Recently Deleted" then set isTrash to true
                end try
                if not isTrash then
                    set t to plaintext of n
                    if (length of t) > 400 then set t to text 1 thru 400 of t
                    return {name of n, t, c}
                end if
                set item best of ds to missing value
            end repeat
            return {"", "", c}
        end tell
        """
        guard let d = await runScript(src), d.numberOfItems >= 3 else { return }
        lastFetch = Date()
        let title = d.atIndex(1)?.stringValue ?? ""
        let snap = MediaNoteSnapshot(title: title, body: Self.preview(d.atIndex(2)?.stringValue ?? "", title: title),
                                     count: Int(d.atIndex(3)?.int32Value ?? 0))
        if snap != snapshot {
            snapshot = snap
            DiskCache.save(snap, "media-notes")
        }
    }

    /// First ~80 characters of the body, without the title line, whitespace collapsed.
    static func preview(_ text: String, title: String) -> String {
        var lines = text.components(separatedBy: .newlines)
        if let first = lines.first, first.trimmingCharacters(in: .whitespaces) == title.trimmingCharacters(in: .whitespaces) {
            lines.removeFirst()
        }
        let flat = lines.joined(separator: " ").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return flat.count > 80 ? String(flat.prefix(80)) + "…" : flat
    }

    func newNote() {
        Task {
            let ok = await Script.run("""
            tell application "Notes"
                activate
                set n to make new note with properties {body:""}
                try
                    show n
                end try
                return true
            end tell
            """)
            if ok == nil { Open.bundle(Self.bundleID) }
            await refresh(force: true)
        }
    }

    var display: MediaNoteSnapshot? {
        if ReferenceScene.isActive { return MediaScene.note }
        if MediaEnv.demo { return MediaNoteSnapshot(title: "Meeting notes", body: "Discuss launch timeline and assign owners for each workstream.", count: 8) }
        return running ? snapshot : nil
    }
}

// MARK: - Notes tile

/// Notes app-style icon: white paper with a yellow header, perforation and ruled lines (brand surface).
struct MediaNotesIcon: View {
    @Environment(\.metrics) private var m
    var size: CGFloat = 36

    var body: some View {
        let s = m.u(size)
        Canvas { ctx, sz in
            let w = sz.width, h = sz.height
            let shape = AppIconFinish.shape(sz)
            ctx.clip(to: shape)
            ctx.fill(Path(CGRect(origin: .zero, size: sz)), with: .linearGradient(Gradient(colors: [Color(hex: "#FBFBFA"), Color(hex: "#EAEAEA")]),
                                                                                    startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
            let band = h * 0.255
            ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: band)),
                     with: .linearGradient(Gradient(colors: [Color(hex: "#FFD933"), Color(hex: "#FFD62F")]), startPoint: .zero, endPoint: CGPoint(x: 0, y: band)))
            // perforation dots
            let dots = 15
            let r = max(0.35, w * 0.012)
            for i in 0..<dots {
                let x = w * 0.09 + (w * 0.82) * CGFloat(i) / CGFloat(dots - 1)
                ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: band + h * 0.03 - r, width: r * 2, height: r * 2)), with: .color(Color(hex: "#CFC9B6")))
            }
            // ruled lines
            for y in [0.488, 0.74] {
                ctx.fill(Path(CGRect(x: w * 0.13, y: h * y, width: w * 0.74, height: max(0.5, h * 0.022))), with: .color(Color(hex: "#CDCDCD")))
            }
        }
        .frame(width: s, height: s)
        .appIconSoftness(s)
    }
}

struct MediaNotesTile: View {
    let w: WidgetInstance
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p

    var body: some View {
        let svc = MediaNotesService.shared
        let snap = svc.display
        Tile(width: w.kind.spec.width, padding: EdgeInsets(top: 1, leading: 16, bottom: 0, trailing: 13)) {
            HStack(spacing: 0) {
                MediaNotesIcon(size: 36)
                VStack(alignment: .leading, spacing: m.u(2)) {
                    if let snap, !snap.title.isEmpty {
                        // Note title and snippet use SF Pro (not Rounded), like Notes.
                        Text(snap.title).dock(11, .semibold, design: .default)
                        if !snap.body.isEmpty {
                            Text(snap.body)
                                .font(.dock(m.u(9), .medium, design: .default))
                                .foregroundStyle(p.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else if snap != nil {
                        Text(L("No notes")).dock(11, .bold)
                        Text(L("Create a new note")).dock(9, .semibold, p.secondary)
                    } else {
                        Text(L("Notes")).dock(11, .bold)
                        Text(L("Open Notes")).dock(9, .semibold, p.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, m.u(12))
                Spacer(minLength: m.u(8))
                MediaComposeButton { svc.newNote() }
            }
        }
        .onTapGesture { Open.bundle(MediaNotesService.bundleID) }
        .task { await svc.keepFresh() }
        .onWidgetRefresh(w.id) { Task { await svc.refresh(force: true) } }
    }
}
