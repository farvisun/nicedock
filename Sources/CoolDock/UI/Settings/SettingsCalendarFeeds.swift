import SwiftUI

/// "Calendar Feeds" section of Privacy & Permissions: ICS / webcal subscriptions the calendar widgets show next to
/// (or instead of) Calendar access.
struct CalendarFeedsGroup: View {
    static let anchor = "calendarFeeds"
    @State private var draft = ""
    @State private var problem: String?
    @FocusState private var linkFocused: Bool
    private var svc: CalendarFeedService { .shared }

    var body: some View {
        SettingsGroup(title: L("Calendar Feeds"),
                      footer: L("Subscribe to iCalendar (.ics) links from Google Calendar, iCloud, Outlook or any webcal:// address. Calendar widgets show their events even without Calendar access. Private links are kept in your Keychain.")) {
            ForEach(svc.feeds) { CalendarFeedRow(feed: $0) }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "link").foregroundStyle(.secondary).frame(width: 18)
                    TextField(L("webcal:// or https:// link"), text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .font(.ui(12.5))
                        .focused($linkFocused)
                        .onSubmit(add)
                    Button(L("Add Feed"), action: add)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let problem {
                    Text(problem).font(.ui(11)).foregroundStyle(Color.cdRed).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .id(Self.anchor)
        .onAppear {
            guard svc.focusAdd else { return }
            svc.focusAdd = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { linkFocused = true }
        }
    }

    private func add() {
        problem = svc.add(draft)
        if problem == nil { draft = "" }
    }
}

private struct CalendarFeedRow: View {
    let feed: CalendarFeed
    private var svc: CalendarFeedService { .shared }

    var body: some View {
        let status = svc.status[feed.id] ?? .init()
        HStack(spacing: 10) {
            Button { svc.update(feed.id) { $0.color = CalendarFeed.nextColor(after: $0.color) } } label: {
                Circle().fill(Color(hex: feed.color))
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                    .frame(width: 14, height: 14)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("Change color"))
            VStack(alignment: .leading, spacing: 1) {
                TextField(feed.host, text: Binding(get: { feed.name }, set: { v in svc.update(feed.id) { $0.name = String(v.prefix(40)) } }))
                    .textFieldStyle(.plain)
                    .font(.ui(13, .medium))
                Text(detail(status))
                    .font(.ui(11))
                    .foregroundStyle(status.error == nil ? Color.secondary : Color.cdRed)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if status.loading { ProgressView().controlSize(.small) }
            Toggle("", isOn: Binding(get: { feed.enabled }, set: { v in svc.update(feed.id) { $0.enabled = v } }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
            Button(role: .destructive) { svc.remove(feed.id) } label: { Image(systemName: "minus.circle.fill") }
                .buttonStyle(.plain)
                .foregroundStyle(Color.cdRed)
                .help(L("Remove"))
        }
    }

    private func detail(_ s: CalendarFeedService.Status) -> String {
        // Host names stay left-to-right inside Persian/Arabic text; the RLM keeps the line's reading order.
        let rtl = Localizer.language.isRTL
        var parts = [rtl ? "\u{2066}\(feed.host)\u{2069}" : feed.host]
        if feed.isPrivate { parts.append(L("Private link in Keychain")) }
        if let error = s.error {
            parts.append(error)
        } else if let updated = s.updated {
            parts.append(s.events == 1 ? L("%d event", 1) : L("%d events", s.events))
            let when = Fmt.calendar.isDateInToday(updated) ? Fmt.clock(updated) : "\(Fmt.relativeDay(updated)) \(Fmt.clock(updated))"
            parts.append(L("Updated %@", when))
        } else if s.loading {
            parts.append(L("Updating…"))
        }
        return (rtl ? "\u{200F}" : "") + parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
