import AppKit
import SwiftUI

// MARK: - Shared task row

/// Reminders-style row: list-coloured circle, bold title, optional "!" priority and a right-aligned due label.
struct CalTaskRow: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    var title: String
    var color: Color
    var prefix: String? = nil
    var priority: String? = nil
    var trailing: String? = nil
    var trailingAlert = false
    var done = false
    var onToggle: (() -> Void)? = nil
    var onOpen: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: m.u(2.5)) {
            circle.alignmentGuide(.firstTextBaseline) { d in d.height - m.u(5.4) }
            HStack(alignment: .firstTextBaseline, spacing: m.u(4)) {
                if let prefix { Text(verbatim: prefix).dock(8.5, .semibold, p.tertiary, mono: true).layoutPriority(1) }
                Text(title).dock(10, .semibold, done ? p.tertiary : p.primary).truncationMode(.tail)
                if let priority { Text(verbatim: priority).dock(10, .heavy, p.accent(.cdOrange)).padding(.leading, m.u(2)).layoutPriority(1) }
            }
            .contentShape(Rectangle())
            .onTapGesture { onOpen?() }
            Spacer(minLength: m.u(6))
            if let trailing {
                Text(verbatim: trailing).dock(9, .bold, trailingAlert ? p.accent(.cdOrange) : p.secondary, mono: true).layoutPriority(1)
            }
        }
        .frame(height: m.u(16))
    }

    @ViewBuilder private var circle: some View {
        let accent = p.accent(color)
        let glyph = ZStack {
            Circle().strokeBorder(accent, lineWidth: m.u(1.3))
            if done {
                Circle().fill(accent)
                Image(systemName: "checkmark").font(.system(size: m.u(6), weight: .heavy)).foregroundStyle(p.calOnAccent)
            }
        }
        .frame(width: m.u(10), height: m.u(10))
        .padding(m.u(3))
        .contentShape(Rectangle())
        if let onToggle {
            Button(action: onToggle) { glyph }.buttonStyle(PressableStyle())
        } else {
            glyph.onTapGesture { onOpen?() }
        }
    }
}

/// Priority marks like Reminders: high !!!, medium !!, low !.
private func calReminderPriority(_ p: Int) -> String? {
    switch p {
    case 1...4: return "!!!"
    case 5: return "!!"
    case 6...9: return "!"
    default: return nil
    }
}

private let calRemindersBundle = "com.apple.reminders"

/// Hides a just-completed row after a short check animation.
@MainActor
private func calAfterCheck(_ action: @escaping @MainActor () -> Void) {
    Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(650))
        withAnimation(.easeOut(duration: 0.2)) { action() }
    }
}

/// Small inline message used for empty lists.
private struct CalListMessage: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    var symbol: String
    var title: String
    var subtitle: String
    var tint: Color = .cdGreen

    var body: some View {
        HStack(spacing: m.u(8)) {
            Image(systemName: symbol).font(.system(size: m.u(17), weight: .semibold)).foregroundStyle(p.accent(tint))
            VStack(alignment: .leading, spacing: m.u(1)) {
                Text(title).dock(11.5, .bold)
                Text(subtitle).dock(9.5, .semibold, p.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, m.u(6))
    }
}

// MARK: - Reminders

struct CalRemindersWidget: View {
    @Environment(\.metrics) private var m
    @State private var checking: Set<String> = []
    let w: WidgetInstance

    var body: some View {
        let svc = CalendarService.shared
        TimelineView(.everyMinute) { ctx in
            Tile(width: w.kind.spec.width, padding: EdgeInsets(top: 8, leading: 2, bottom: 6, trailing: 5)) {
                if !CalData.hasReminders {
                    CalAccessMessage(reminders: true)
                } else if CalData.reminders.isEmpty {
                    CalListMessage(symbol: "checkmark.circle.fill", title: L("All done"), subtitle: L("Click to add a reminder"))
                } else {
                    VStack(spacing: 0) {
                        ForEach(CalData.reminders.prefix(3)) { r in
                            let due = CalText.due(r.due, now: ctx.date)
                            CalTaskRow(title: r.title, color: r.color, priority: calReminderPriority(r.priority),
                                       trailing: due?.text, trailingAlert: due?.overdue ?? false, done: checking.contains(r.id),
                                       onToggle: { complete(r) }, onOpen: { Open.bundle(calRemindersBundle) })
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .onTapGesture {
            if CalData.hasReminders { Panels.shared.toggle(w.id) { CalRemindersPanel() } } else { CalAccess.request(reminders: true) }
        }
        .demand(CalendarDemand.reminders)
        .onWidgetRefresh(w.id) { svc.reloadReminders() }
    }

    private func complete(_ r: DockReminder) {
        guard !checking.contains(r.id) else { return }
        withAnimation(.easeOut(duration: 0.15)) { _ = checking.insert(r.id) }
        calAfterCheck {
            CalendarService.shared.complete(r)
            checking.remove(r.id)
        }
    }
}

struct CalRemindersPanel: View {
    @Environment(\.palette) private var p
    @State private var draft = ""
    @State private var checking: Set<String> = []

    var body: some View {
        let items = CalData.reminders
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(title: L("Reminders"), subtitle: items.isEmpty ? L("All done") : L("%d open", items.count)) {
                Button { Panels.shared.close(); Open.bundle(calRemindersBundle) } label: {
                    Image(systemName: "arrow.up.forward.app").font(.system(size: 13, weight: .semibold)).foregroundStyle(p.secondary)
                }
                .buttonStyle(.plain)
                .help(L("Open Reminders"))
            }
            CalPanelList(count: items.count) {
                ForEach(items) { r in
                    let due = CalText.due(r.due)
                    CalPanelTaskRow(title: r.title, color: r.color, priority: calReminderPriority(r.priority), trailing: due?.text,
                                    trailingAlert: due?.overdue ?? false, done: checking.contains(r.id),
                                    onToggle: { complete(r) }, onDelete: nil)
                }
            }
            CalAddField(placeholder: L("New Reminder"), text: $draft) {
                CalendarService.shared.addReminder($0)
            }
        }
        .frame(width: 290)
        .demand(CalendarDemand.reminders)
    }

    private func complete(_ r: DockReminder) {
        guard !checking.contains(r.id) else { return }
        withAnimation(.easeOut(duration: 0.15)) { _ = checking.insert(r.id) }
        calAfterCheck {
            CalendarService.shared.complete(r)
            checking.remove(r.id)
        }
    }
}

// MARK: - Panel building blocks

/// Vertical list that scrolls only once it gets long (panels size to their content).
private struct CalPanelList<Content: View>: View {
    var count: Int
    @ViewBuilder var content: () -> Content

    var body: some View {
        let stack = VStack(spacing: 1) { content() }
        if count > 9 {
            ScrollView { stack }.frame(height: 9 * 29)
        } else {
            stack
        }
    }
}

private struct CalPanelTaskRow: View {
    @Environment(\.palette) private var p
    @State private var hover = false
    var title: String
    var color: Color
    var priority: String?
    var trailing: String?
    var trailingAlert = false
    var done: Bool
    var onToggle: () -> Void
    var onDelete: (() -> Void)?

    var body: some View {
        HStack(spacing: 9) {
            Button(action: onToggle) {
                ZStack {
                    Circle().strokeBorder(p.accent(color), lineWidth: 1.5)
                    if done {
                        Circle().fill(p.accent(color))
                        Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(p.calOnAccent)
                    }
                }
                .frame(width: 16, height: 16)
                .contentShape(Circle())
            }
            .buttonStyle(PressableStyle())
            Text(title).font(.dock(12.5, .semibold)).foregroundStyle(done ? p.tertiary : p.primary).lineLimit(1)
            if let priority { Text(verbatim: priority).font(.dock(12, .heavy)).foregroundStyle(p.accent(.cdOrange)) }
            Spacer(minLength: 8)
            if hover, let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(p.secondary)
                        .frame(width: 18, height: 18).background(Circle().fill(p.control))
                }
                .buttonStyle(PressableStyle())
                .help(L("Delete"))
            } else if let trailing {
                Text(verbatim: trailing).font(.dock(11, .semibold)).foregroundStyle(trailingAlert ? p.accent(.cdOrange) : p.secondary)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hover ? p.control : Color.clear))
        .onHover { hover = $0 }
    }
}

private struct CalAddField: View {
    @Environment(\.palette) private var p
    @FocusState private var focused: Bool
    var placeholder: String
    @Binding var text: String
    var onAdd: (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(p.accent(.cdBlue))
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.dock(12.5, .medium))
                .foregroundStyle(p.primary)
                .focused($focused)
                .onSubmit(submit)
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(p.control))
        .onAppear { focused = true }
    }

    private func submit() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        onAdd(t)
        text = ""
    }
}

// MARK: - Local todo

struct CalTodoItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var created = Date()
}

@MainActor
enum CalTodoStore {
    static func items(_ w: WidgetInstance?) -> [CalTodoItem] {
        guard let raw = w?.config["items"], let data = raw.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([CalTodoItem].self, from: data)) ?? []
    }

    static func mutate(_ id: UUID, _ change: (inout [CalTodoItem]) -> Void) {
        var list = items(AppStore.shared.widget(id))
        change(&list)
        let json = (try? JSONEncoder().encode(list)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        AppStore.shared.updateWidget(id) { $0.config["items"] = json }
    }
}

struct CalTodoWidget: View {
    @State private var checking: Set<UUID> = []
    let w: WidgetInstance

    var body: some View {
        let items = CalTodoStore.items(w)
        Tile(width: w.kind.spec.width, padding: EdgeInsets(top: 8, leading: 2, bottom: 6, trailing: 5)) {
            if items.isEmpty {
                CalListMessage(symbol: "checkmark.circle.fill", title: L("Nothing to do"), subtitle: L("Click to add a task"))
            } else {
                VStack(spacing: 0) {
                    ForEach(items.prefix(3)) { item in
                        CalTaskRow(title: item.title, color: .cdOrange, done: checking.contains(item.id),
                                   onToggle: { complete(item) }, onOpen: { openPanel() })
                    }
                    Spacer(minLength: 0)
                }
                .overlay(alignment: .bottomTrailing) {
                    if items.count > 3 { CalMoreChip(count: items.count - 3) }
                }
            }
        }
        .onTapGesture { openPanel() }
    }

    private func openPanel() {
        let id = w.id
        Panels.shared.toggle(id) { CalTodoPanel(id: id) }
    }

    private func complete(_ item: CalTodoItem) {
        guard !checking.contains(item.id) else { return }
        withAnimation(.easeOut(duration: 0.15)) { _ = checking.insert(item.id) }
        let id = w.id
        calAfterCheck {
            CalTodoStore.mutate(id) { $0.removeAll { $0.id == item.id } }
            checking.remove(item.id)
        }
    }
}

private struct CalMoreChip: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    var count: Int
    var body: some View {
        Text(verbatim: "+" + Fmt.int(count)).dock(9, .bold, p.secondary)
            .padding(.horizontal, m.u(5)).frame(height: m.u(14))
            .background(Capsule().fill(p.control.opacity(0.65)))
    }
}

struct CalTodoPanel: View {
    @Environment(\.palette) private var p
    @State private var draft = ""
    @State private var checking: Set<UUID> = []
    let id: UUID

    var body: some View {
        let items = CalTodoStore.items(AppStore.shared.widget(id))
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(title: L("Todo"), subtitle: items.isEmpty ? L("Nothing to do") : L("%d open", items.count))
            if !items.isEmpty {
                CalPanelList(count: items.count) {
                    ForEach(items) { item in
                        CalPanelTaskRow(title: item.title, color: .cdOrange, priority: nil, trailing: nil, done: checking.contains(item.id),
                                        onToggle: { complete(item) },
                                        onDelete: { withAnimation(.easeOut(duration: 0.2)) { CalTodoStore.mutate(id) { $0.removeAll { $0.id == item.id } } } })
                    }
                }
            }
            CalAddField(placeholder: L("New Task"), text: $draft) { title in
                withAnimation(.easeOut(duration: 0.2)) { CalTodoStore.mutate(id) { $0.append(CalTodoItem(title: title)) } }
            }
        }
        .frame(width: 290)
    }

    private func complete(_ item: CalTodoItem) {
        guard !checking.contains(item.id) else { return }
        withAnimation(.easeOut(duration: 0.15)) { _ = checking.insert(item.id) }
        let id = id
        calAfterCheck {
            CalTodoStore.mutate(id) { $0.removeAll { $0.id == item.id } }
            checking.remove(item.id)
        }
    }
}

// MARK: - Linear

struct CalLinearIssue: Codable, Identifiable, Equatable {
    var id: String { identifier }
    let identifier: String
    let title: String
    let dueDate: String?
    let priority: Int
    let url: String
    let stateName: String
    let stateColor: String
}

enum CalLinearAPI {
    static let query = """
    query { viewer { assignedIssues(first: 20, filter: { state: { type: { nin: ["completed", "canceled"] } } }, orderBy: updatedAt) { nodes { identifier title dueDate priority url state { name color } } } } }
    """

    struct GraphQLError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func fetch(token: String) async throws -> [CalLinearIssue] {
        let body = try JSONSerialization.data(withJSONObject: ["query": query])
        let obj = try await Net.json(URL(string: "https://api.linear.app/graphql")!,
                                     headers: ["Authorization": token, "Content-Type": "application/json"],
                                     method: "POST", body: body) as? [String: Any]
        if let errors = obj?["errors"] as? [[String: Any]], let first = errors.first {
            let ext = first["extensions"] as? [String: Any]
            if (ext?["code"] as? String) == "AUTHENTICATION_ERROR" { throw GraphQLError(message: L("Check your token")) }
            throw GraphQLError(message: (first["message"] as? String) ?? L("Request failed"))
        }
        let nodes = (((obj?["data"] as? [String: Any])?["viewer"] as? [String: Any])?["assignedIssues"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        let issues = nodes.compactMap { n -> CalLinearIssue? in
            guard let identifier = n["identifier"] as? String, let title = n["title"] as? String else { return nil }
            let state = n["state"] as? [String: Any]
            return CalLinearIssue(identifier: identifier, title: title, dueDate: n["dueDate"] as? String,
                                  priority: (n["priority"] as? NSNumber)?.intValue ?? 0, url: (n["url"] as? String) ?? "",
                                  stateName: (state?["name"] as? String) ?? "", stateColor: (state?["color"] as? String) ?? "#8E8E93")
        }
        // Due issues first (soonest on top), the rest keep Linear's "recently updated" order.
        return issues.enumerated().sorted { a, b in
            switch (a.element.dueDate, b.element.dueDate) {
            case let (x?, y?): return x == y ? a.offset < b.offset : x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }

    static let dueParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func priorityMark(_ p: Int) -> String? {
        switch p {
        case 1: return "!!"
        case 2: return "!"
        default: return nil
        }
    }
}

struct CalLinearWidget: View {
    @Environment(\.metrics) private var m
    @State private var issues: [CalLinearIssue]?
    @State private var error: String?
    @State private var tick = 0
    let w: WidgetInstance

    var body: some View {
        let token = Secrets.get(w.id, "token")
        TimelineView(.everyMinute) { ctx in
            Tile(width: w.kind.spec.width, padding: EdgeInsets(top: 8, leading: 2, bottom: 6, trailing: 5)) {
                if token == nil {
                    TileMessage(symbol: "link.badge.plus", text: L("Connect Linear"), tint: .cdIndigo)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture { WidgetSetup.customize(w) }
                } else if let issues, !issues.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(issues.prefix(3)) { issue in
                            let due = CalText.due(issue.dueDate.flatMap { CalLinearAPI.dueParser.date(from: $0) }, dateOnly: true, now: ctx.date)
                            CalTaskRow(title: issue.title, color: Color(hex: issue.stateColor), prefix: issue.identifier,
                                       priority: CalLinearAPI.priorityMark(issue.priority), trailing: due?.text,
                                       trailingAlert: due?.overdue ?? false, onOpen: { Open.url(issue.url) })
                        }
                        Spacer(minLength: 0)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if issues.count > 3 && issues.prefix(3).allSatisfy({ $0.dueDate == nil }) { CalMoreChip(count: issues.count - 3) }
                    }
                } else if issues != nil {
                    CalListMessage(symbol: "checkmark.circle.fill", title: L("No open issues"), subtitle: L("Linear"), tint: .cdIndigo)
                } else if let error {
                    TileMessage(symbol: "exclamationmark.triangle.fill", text: error)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture { tick += 1 }
                } else {
                    CalListMessage(symbol: "line.3.diagonal", title: L("Linear"), subtitle: L("Loading…"), tint: .cdIndigo)
                        .opacity(0.6)
                }
            }
        }
        .task(id: "\(token ?? "")#\(tick)") { await run(token) }
        .onWidgetRefresh(w.id) { tick += 1 }
    }

    private var cacheKey: String { "linear-" + w.id.uuidString }

    private func run(_ token: String?) async {
        guard let token else { issues = nil; return }
        if issues == nil { issues = DiskCache.load([CalLinearIssue].self, cacheKey) }
        while !Task.isCancelled {
            do {
                let fresh = try await CalLinearAPI.fetch(token: token)
                if fresh != issues { issues = fresh }
                error = nil
                DiskCache.save(fresh, cacheKey)
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { return }
                self.error = (error as? LocalizedError)?.errorDescription ?? L("Offline")
            }
            try? await Task.sleep(for: .seconds(600))
        }
    }
}
