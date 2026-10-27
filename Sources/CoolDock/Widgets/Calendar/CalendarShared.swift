import AppKit
import SwiftUI

// MARK: - Calendar.app style icon

/// Calendar.app-like glyph: white rounded square, red top band and a dot grid with today's slot in red.
/// Brand artwork, so the colours are fixed (like an app icon) rather than palette-driven.
struct CalAppIcon: View {
    @Environment(\.metrics) private var m
    var size: CGFloat = 36
    var date = ReferenceScene.date()

    var body: some View {
        let slot = Self.todaySlot(date)
        Canvas { ctx, sz in
            let w = sz.width, h = sz.height
            let shape = Path(roundedRect: CGRect(origin: .zero, size: sz), cornerRadius: w * 0.225, style: .continuous)
            ctx.clip(to: shape)
            ctx.fill(shape, with: .linearGradient(Gradient(colors: [Color(white: 1), Color(white: 0.925)]),
                                                  startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
            let band = h * 0.255
            ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: band)),
                     with: .linearGradient(Gradient(colors: [Color(hex: "#FF636A"), Color(hex: "#F5333E")]),
                                           startPoint: .zero, endPoint: CGPoint(x: 0, y: band)))
            let dot = max(w * 0.045, 1)
            let red = w * 0.1
            for row in 0..<4 {
                for col in Self.columns(row) {
                    // Column pitch and first column measured from the reference frames' dot centres.
                    let c = CGPoint(x: w * (0.179 + 0.107 * CGFloat(col)), y: h * (0.418 + 0.134 * CGFloat(row)))
                    let d = (row == slot.row && col == slot.col) ? red : dot
                    let color = (row == slot.row && col == slot.col) ? Color(hex: "#F5333E") : Color(white: 0.12)
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)), with: .color(color))
                }
            }
        }
        .frame(width: m.u(size), height: m.u(size))
        .environment(\.layoutDirection, .leftToRight)
    }

    /// Stylised month: a short first and last week like the system icon.
    private static func columns(_ row: Int) -> ClosedRange<Int> {
        switch row {
        case 0: return 2...6
        case 3: return 0...4
        default: return 0...6
        }
    }

    /// Today's weekday column and week row, folded into the stylised 4-row grid.
    static func todaySlot(_ date: Date) -> (row: Int, col: Int) {
        var cal = Fmt.calendar
        // The reference frames come from a Sunday-first locale; keep scene renders independent of this Mac's region.
        if ReferenceScene.isActive { cal.firstWeekday = 1 }
        let col = (cal.component(.weekday, from: date) - cal.firstWeekday + 7) % 7
        var row = min(3, max(0, cal.component(.weekOfMonth, from: date) - 1))
        if row == 0 && col < 2 { row = 1 }
        if row == 3 && col > 4 { row = 2 }
        return (row, col)
    }
}

// MARK: - Data access

/// Thin read layer over `CalendarService` used by every calendar/reminder widget.
@MainActor
enum CalData {
    private static var svc: CalendarService { .shared }
    /// Calendar access or a calendar feed: either one fills the event widgets.
    static var hasEvents: Bool { svc.hasEventSource }
    static var hasReminders: Bool { svc.hasReminderAccess }
    static var upcoming: [DockEvent] { svc.upcoming }
    static var today: [DockEvent] { svc.todayEvents }
    static var nextMeeting: DockEvent? { svc.nextMeeting }
    static var eventDays: Set<String> { svc.eventDays }
    static var reminders: [DockReminder] { svc.reminders }
}

// MARK: - Shared formatting

@MainActor
enum CalText {
    static func range(_ e: DockEvent) -> String {
        if e.allDay { return L("All day") }
        // A leading RLM makes the start time read first in right-to-left languages.
        return (Localizer.language.isRTL ? "\u{200F}" : "") + Fmt.clock(e.start) + " – " + Fmt.clock(e.end)
    }

    /// "8m", "2h", "now", or the day for events further out.
    static func countdown(_ e: DockEvent, now: Date) -> String {
        if e.start <= now { return L("now") }
        let dt = e.start.timeIntervalSince(now)
        if dt < 12 * 3600 { return Fmt.minutesLeft(dt) }
        return Fmt.relativeDay(e.start)
    }

    /// Start time for today's events, otherwise the day.
    static func when(_ e: DockEvent, now: Date = ReferenceScene.date()) -> String {
        let today = Fmt.calendar.isDate(e.start, inSameDayAs: now) || e.isNow
        if e.allDay { return today ? L("All day") : Fmt.relativeDay(e.start) }
        return today ? Fmt.clock(e.start) : Fmt.relativeDay(e.start)
    }

    /// Due label for reminders and issues. Date-only due dates are midnight and only overdue from the next day.
    static func due(_ date: Date?, dateOnly: Bool? = nil, now: Date = ReferenceScene.date()) -> (text: String, overdue: Bool)? {
        guard let date else { return nil }
        let cal = Fmt.calendar
        let parts = cal.dateComponents([.hour, .minute], from: date)
        let onlyDate = dateOnly ?? (parts.hour == 0 && parts.minute == 0)
        let overdue = onlyDate ? date < cal.startOfDay(for: now) : date < now
        if overdue { return (L("Overdue"), true) }
        if cal.isDate(date, inSameDayAs: now) { return (onlyDate ? L("Today") : Fmt.clock(date), false) }
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(date, inSameDayAs: tomorrow) { return (L("Tomorrow"), false) }
        if date.timeIntervalSince(now) < 6 * 86_400 { return (Fmt.weekdayShort(date), false) }
        return (Fmt.date(date, "MMMd"), false)
    }

    /// Same key format `CalendarService.eventDays` uses.
    static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func dayKey(_ date: Date) -> String { dayKeyFormatter.string(from: date) }

    /// Short weekday that fits narrow cells (Persian/Arabic full names are long).
    static func weekdayNarrow(_ date: Date) -> String {
        let s = Fmt.weekdayShort(date)
        guard s.count > 3, Localizer.language.isRTL else { return s }
        let cal = Fmt.calendar
        let i = cal.component(.weekday, from: date) - 1
        let symbols = cal.veryShortStandaloneWeekdaySymbols
        return symbols.indices.contains(i) ? symbols[i] : s
    }
}

extension DockPalette {
    /// Foreground for glyphs and text drawn on an accent fill (white, or inverted in Monochrome mode).
    var calOnAccent: Color { monochrome ? (isLight ? Color(white: 0.97) : Color(white: 0.06)) : Color(white: 1) }
    /// Very soft inset fill used for chips and day cells.
    var calWell: Color { control.opacity(0.5) }
}

// MARK: - Permission

@MainActor
enum CalAccess {
    /// Requests access; when the user already declined, opens the privacy pane instead.
    static func request(reminders: Bool) {
        Task { @MainActor in
            let svc = CalendarService.shared
            let undetermined = reminders ? svc.remindersAccess == .notDetermined : svc.eventsAccess == .notDetermined
            if reminders { await svc.requestReminders() } else { await svc.requestEvents() }
            let granted = reminders ? svc.hasReminderAccess : svc.hasEventAccess
            if !granted && !undetermined {
                Open.url("x-apple.systempreferences:com.apple.preference.security?" + (reminders ? "Privacy_Reminders" : "Privacy_Calendars"))
            }
        }
    }
}

/// "Add calendar feed…": Settings → Privacy & Permissions → Calendar Feeds, link field focused.
@MainActor
enum CalFeedLink {
    static func add() {
        CalendarFeedService.shared.focusAdd = true
        SettingsWindow.show(pane: .privacy, anchor: CalendarFeedsGroup.anchor)
    }
}

struct CalAccessMessage: View {
    var reminders: Bool

    var body: some View {
        TileMessage(symbol: reminders ? "checklist" : "calendar.badge.exclamationmark",
                    text: reminders ? L("Allow Reminders access") : L("Allow Calendar access"))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { CalAccess.request(reminders: reminders) }
    }
}

// MARK: - Month panel

/// Expanded calendar: month grid (Gregorian or Persian), event dots and the upcoming list.
struct CalMonthPanel: View {
    @Environment(\.palette) private var p
    @State private var anchor = Date()

    var body: some View {
        let now = Date()
        let isCurrent = Fmt.calendar.isDate(anchor, equalTo: now, toGranularity: .month)
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(title: Fmt.date(anchor, "MMMMy"), subtitle: Fmt.date(now, "EEEEMMMMd")) {
                HStack(spacing: 2) {
                    navButton("chevron.backward") { shift(-1) }
                    Button { withAnimation(.easeOut(duration: 0.15)) { anchor = Date() } } label: {
                        Text(L("Today")).font(.dock(11, .semibold)).foregroundStyle(isCurrent ? p.tertiary : p.primary)
                            .padding(.horizontal, 8).frame(height: 22)
                            .background(Capsule().fill(p.control))
                    }
                    .buttonStyle(PressableStyle())
                    .disabled(isCurrent)
                    navButton("chevron.forward") { shift(1) }
                }
            }
            CalMonthGrid(month: anchor, eventDays: CalData.hasEvents ? CalData.eventDays : [])
            Rectangle().fill(p.tileStroke).frame(height: 1)
            if CalData.hasEvents {
                CalUpcomingList(events: Array(CalData.upcoming.prefix(6)))
            } else {
                Button { CalAccess.request(reminders: false) } label: {
                    Label(L("Allow Calendar access"), systemImage: "lock.fill")
                        .font(.dock(12, .semibold)).foregroundStyle(p.primary)
                        .frame(maxWidth: .infinity).frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(p.control))
                }
                .buttonStyle(PressableStyle())
                Button { CalFeedLink.add() } label: {
                    Label(L("Add calendar feed…"), systemImage: "link")
                        .font(.dock(12, .semibold)).foregroundStyle(p.primary)
                        .frame(maxWidth: .infinity).frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(p.control))
                }
                .buttonStyle(PressableStyle())
            }
            Button { Panels.shared.close(); Open.bundle("com.apple.iCal") } label: {
                HStack(spacing: 4) {
                    Text(L("Open Calendar"))
                    Image(systemName: "arrow.up.forward").font(.system(size: 9, weight: .bold))
                }
                .font(.dock(11, .semibold)).foregroundStyle(p.secondary)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(width: 266)
        .demand(CalendarDemand.events)
    }

    private func shift(_ months: Int) {
        if let d = Fmt.calendar.date(byAdding: .month, value: months, to: anchor) {
            withAnimation(.easeOut(duration: 0.15)) { anchor = d }
        }
    }

    private func navButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(p.secondary)
                .frame(width: 22, height: 22).background(Circle().fill(p.control))
        }
        .buttonStyle(PressableStyle())
    }
}

/// Month grid honouring `Fmt.calendar` (Persian months, first weekday) and the layout direction.
struct CalMonthGrid: View {
    @Environment(\.palette) private var p
    var month: Date
    var eventDays: Set<String>

    private let cell: CGFloat = 38

    var body: some View {
        let cal = Fmt.calendar
        let weeks = Self.weeks(for: month, cal: cal)
        let symbols = Self.weekdaySymbols(cal)
        VStack(spacing: 2) {
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { i in
                    Text(symbols[i]).font(.dock(10, .semibold)).foregroundStyle(p.tertiary).frame(width: cell, height: 18)
                }
            }
            ForEach(weeks.indices, id: \.self) { r in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { c in
                        if let day = weeks[r][c] { dayCell(day, cal: cal) } else { Color.clear.frame(width: cell, height: 30) }
                    }
                }
            }
        }
    }

    private func dayCell(_ day: Date, cal: Calendar) -> some View {
        let today = cal.isDateInToday(day)
        let hasEvents = eventDays.contains(CalText.dayKey(day))
        return VStack(spacing: 2) {
            Text(verbatim: Fmt.dayNumber(day))
                .font(.dock(12.5, today ? .bold : .medium))
                .foregroundStyle(today ? p.calOnAccent : p.primary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(today ? p.accent(.cdRed) : Color.clear))
            Circle().fill(hasEvents ? p.secondary : Color.clear).frame(width: 4, height: 4)
        }
        .frame(width: cell, height: 30)
    }

    static func weekdaySymbols(_ cal: Calendar) -> [String] {
        let base = cal.veryShortStandaloneWeekdaySymbols
        guard base.count == 7 else { return Array(repeating: "", count: 7) }
        return (0..<7).map { base[(cal.firstWeekday - 1 + $0) % 7] }
    }

    static func weeks(for month: Date, cal: Calendar) -> [[Date?]] {
        guard let interval = cal.dateInterval(of: .month, for: month),
              let count = cal.range(of: .day, in: .month, for: month)?.count else { return [] }
        let lead = (cal.component(.weekday, from: interval.start) - cal.firstWeekday + 7) % 7
        var cells: [Date?] = Array(repeating: nil, count: lead)
        for i in 0..<count { cells.append(cal.date(byAdding: .day, value: i, to: interval.start)) }
        while cells.count % 7 != 0 { cells.append(nil) }
        return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<$0 + 7]) }
    }
}

/// Upcoming events grouped by day, used by the calendar panel.
struct CalUpcomingList: View {
    @Environment(\.palette) private var p
    var events: [DockEvent]

    var body: some View {
        if events.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "calendar.badge.checkmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(p.accent(.cdGreen))
                Text(L("No upcoming events")).font(.dock(12, .semibold)).foregroundStyle(p.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(events.enumerated()), id: \.element.id) { i, e in
                    if i == 0 || !Fmt.calendar.isDate(e.start, inSameDayAs: events[i - 1].start) {
                        Text(Self.dayTitle(e.start)).font(.dock(10.5, .bold)).foregroundStyle(p.tertiary)
                            .padding(.top, i == 0 ? 0 : 4)
                    }
                    CalPanelEventRow(event: e)
                }
            }
        }
    }

    private static func dayTitle(_ d: Date) -> String {
        let cal = Fmt.calendar
        if cal.isDateInToday(d) || cal.isDateInTomorrow(d) { return Fmt.relativeDay(d) + " · " + Fmt.date(d, "MMMd") }
        return Fmt.date(d, "EEEEMMMd")
    }
}

private struct CalPanelEventRow: View {
    @Environment(\.palette) private var p
    @State private var hover = false
    var event: DockEvent

    var body: some View {
        Button { Panels.shared.close(); CalendarService.shared.open(event) } label: {
            HStack(spacing: 9) {
                Capsule().fill(p.accent(event.color)).frame(width: 3.5, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.title).font(.dock(12.5, .semibold)).foregroundStyle(p.primary).lineLimit(1)
                    Text(verbatim: CalText.range(event)).font(.dock(10.5, .medium)).foregroundStyle(p.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                if event.meetingURL != nil {
                    Image(systemName: "video.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(p.calOnAccent)
                        .frame(width: 24, height: 24).background(Circle().fill(p.accent(CalBrand.zoomBlue)))
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hover ? p.control : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

enum CalBrand {
    static let zoomBlue = Color(hex: "#0B6FE6")
    /// Today's cell in the week strip (Calendar.app blue).
    static let todayBlue = Color(hex: "#007AFF")
    /// Reminders' due/priority orange.
    static let alertOrange = Color(hex: "#FF9230")
}
