import AppKit
import SwiftUI

// MARK: - Today's events (calendar icon + two rows)

struct CalTodayWidget: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    let w: WidgetInstance

    var body: some View {
        let svc = CalendarService.shared
        Tile(width: w.kind.spec.width, padding: EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 13)) {
            HStack(spacing: m.u(12)) {
                CalAppIcon(size: 36).offset(y: m.u(0.5))
                VStack(alignment: .leading, spacing: 0) {
                    Text(L("Today")).dock(10, .semibold, p.secondary)
                        .frame(height: m.u(14), alignment: .bottom)
                        .offset(y: m.u(-1))
                    if CalData.hasEvents {
                        rows
                    } else {
                        CalLine(dot: p.accent(.cdOrange), title: L("Allow Calendar access"), titleColor: p.secondary)
                            .contentShape(Rectangle())
                            .onTapGesture { CalAccess.request(reminders: false) }
                        CalLine(dot: nil, title: L("Add calendar feed…"), titleColor: p.tertiary)
                            .contentShape(Rectangle())
                            .onTapGesture { CalFeedLink.add() }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .offset(y: m.u(1))
            }
        }
        .onTapGesture {
            if CalData.hasEvents { Panels.shared.toggle(w.id) { CalMonthPanel() } } else { CalAccess.request(reminders: false) }
        }
        .demand(CalendarDemand.events)
        .onWidgetRefresh(w.id) { svc.refreshEvents() }
    }

    @ViewBuilder private var rows: some View {
        let today = Array(CalData.today.prefix(2))
        if today.isEmpty {
            CalLine(dot: nil, title: L("No more events"), titleColor: p.secondary)
            if let next = CalData.upcoming.first {
                CalLine(dot: p.accent(next.color), title: next.title, trailing: CalText.when(next))
            } else {
                CalLine(dot: nil, title: L("Enjoy your day"), titleColor: p.tertiary)
            }
        } else {
            ForEach(today) { e in CalLine(dot: p.accent(e.color), title: e.title, trailing: CalText.when(e)) }
            if today.count == 1 { Color.clear.frame(height: m.u(16)) }
        }
    }
}

/// One event row: coloured dot, title (SF Pro medium, like Calendar) and right-aligned time.
private struct CalLine: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    var dot: Color?
    var title: String
    var titleColor: Color?
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: m.u(5)) {
            if let dot {
                Circle().fill(dot).frame(width: m.u(5), height: m.u(5))
                    .alignmentGuide(.firstTextBaseline) { d in d.height + m.u(0.5) }
            }
            Text(title).dock(10, .medium, titleColor ?? p.primary, design: .default).truncationMode(.tail)
                .offset(y: m.u(0.5))
            Spacer(minLength: m.u(6))
            if let trailing { Text(trailing).dock(9, .semibold, p.secondary, mono: true).layoutPriority(1).offset(y: m.u(0.5)) }
        }
        .frame(height: m.u(16))
    }
}

// MARK: - Agenda (date block + coloured titles)

struct CalAgendaWidget: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    let w: WidgetInstance

    var body: some View {
        let svc = CalendarService.shared
        TimelineView(.everyMinute) { ctx in
            let now = ReferenceScene.date(ctx.date)
            Tile(width: w.kind.spec.width, padding: EdgeInsets(top: 6.5, leading: 5.5, bottom: 6.5, trailing: 8)) {
                HStack(spacing: m.u(8)) {
                    dateBlock(now)
                    if CalData.hasEvents { events(now) } else { access }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        .onTapGesture {
            if CalData.hasEvents { Panels.shared.toggle(w.id) { CalMonthPanel() } } else { CalAccess.request(reminders: false) }
        }
        .demand(CalendarDemand.events)
        .onWidgetRefresh(w.id) { svc.refreshEvents() }
    }

    private func dateBlock(_ now: Date) -> some View {
        VStack(spacing: m.u(1)) {
            Text(verbatim: Fmt.dayNumber(now)).dock(22, .bold, mono: true)
            Text(verbatim: Fmt.monthShort(now)).dock(9, .semibold, p.secondary).minimumScaleFactor(0.7)
                .offset(x: m.u(-0.5))
        }
        .padding(.top, m.u(1))
        .frame(width: m.u(43.5))
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: m.u(8), style: .continuous).fill(p.calWell))
    }

    @ViewBuilder private func events(_ now: Date) -> some View {
        let today = CalData.upcoming.filter { Fmt.calendar.isDate($0.start, inSameDayAs: now) || $0.isNow }
        let shown = Array((today.isEmpty ? CalData.upcoming : today).prefix(2))
        let extra = today.count - shown.count
        if shown.isEmpty {
            VStack(alignment: .leading, spacing: m.u(2)) {
                Text(L("No upcoming events")).dock(10, .bold)
                Text(L("Your calendar is clear")).dock(9, .semibold, p.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: m.u(4)) {
                ForEach(shown) { e in
                    VStack(alignment: .leading, spacing: m.u(1)) {
                        Text(e.title).dock(10, .semibold, p.accent(e.color), design: .default)
                        Text(verbatim: today.isEmpty ? Fmt.relativeDay(e.start) + " " + CalText.range(e) : CalText.range(e))
                            .dock(9, .medium, p.secondary, mono: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .offset(y: m.u(0.5))
            .overlay(alignment: .bottomTrailing) {
                if extra > 0 {
                    Text(verbatim: "+" + Fmt.int(extra)).dock(8, .bold, p.secondary).offset(x: m.u(0.5))
                        .padding(.horizontal, m.u(5.5)).frame(height: m.u(14))
                        .background(Capsule().fill(p.control.opacity(0.65)))
                        .padding(.trailing, m.u(-2))
                        .offset(y: m.u(0.25))
                }
            }
        }
    }

    private var access: some View {
        VStack(alignment: .leading, spacing: m.u(2)) {
            Text(L("Allow Calendar access")).dock(10, .bold, p.accent(.cdOrange))
                .contentShape(Rectangle())
                .onTapGesture { CalAccess.request(reminders: false) }
            Text(L("Add calendar feed…")).dock(9, .semibold, p.secondary)
                .contentShape(Rectangle())
                .onTapGesture { CalFeedLink.add() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Week strip

struct CalWeekStripWidget: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    let w: WidgetInstance

    var body: some View {
        let svc = CalendarService.shared
        let city = w.string("city")
        TimelineView(.everyMinute) { ctx in
            let start = Fmt.calendar.startOfDay(for: ReferenceScene.date(ctx.date))
            Tile(width: w.kind.spec.width, padding: EdgeInsets(top: 5, leading: 6, bottom: 4.5, trailing: 6)) {
                VStack(spacing: m.u(2.5)) {
                    HStack(spacing: m.u(3.5)) {
                        Text(verbatim: Fmt.month(start)).dock(9, .bold).offset(y: m.u(-0.5))
                        Spacer(minLength: 4)
                        if let s = WeatherService.shared.snapshot(city) {
                            Image(systemName: WeatherCode.symbol(s.code, isDay: s.isDay))
                                .font(.system(size: m.u(11), weight: .medium))
                                .foregroundStyle(p.weatherGlyph)
                                .offset(y: m.u(-0.25))
                            Text(verbatim: Fmt.temp(s.temp)).dock(9, .semibold, mono: true).offset(x: m.u(-0.5), y: m.u(-0.5))
                        }
                    }
                    .padding(.trailing, m.u(-0.5))
                    .frame(height: m.u(14))
                    HStack(spacing: m.u(2)) {
                        ForEach(0..<7, id: \.self) { i in
                            let day = Fmt.calendar.date(byAdding: .day, value: i, to: start) ?? start
                            pill(day, today: i == 0, events: CalData.hasEvents && CalData.eventDays.contains(CalText.dayKey(day)))
                        }
                    }
                }
            }
        }
        .onTapGesture { Panels.shared.toggle(w.id) { CalMonthPanel() } }
        .demand(CalendarDemand.events)
        .task(id: city) { await WeatherService.shared.keepFresh(city) }
        .onWidgetRefresh(w.id) {
            svc.refreshEvents()
            Task { await WeatherService.shared.ensure(city, force: true) }
        }
    }

    private func pill(_ day: Date, today: Bool, events: Bool) -> some View {
        VStack(spacing: m.u(0)) {
            // Today's pill is bold white on blue; the other days are semibold.
            Text(verbatim: CalText.weekdayNarrow(day)).dock(9, today ? .bold : .semibold, today ? p.calOnAccent : p.secondary).minimumScaleFactor(0.7)
                .offset(y: m.u(-0.5))
            Text(verbatim: Fmt.dayNumber(day)).dock(13, today ? .bold : .semibold, today ? p.calOnAccent : p.primary, mono: true)
                .offset(y: m.u(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: m.u(8), style: .continuous).fill(today ? p.accent(CalBrand.todayBlue) : p.control.opacity(0.4)))
        .overlay(alignment: .bottom) {
            if events {
                Circle().fill(today ? p.calOnAccent : p.secondary).frame(width: m.u(3), height: m.u(3)).padding(.bottom, m.u(2.5))
            }
        }
    }
}

// MARK: - Next meeting

struct CalNextMeetingWidget: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    let w: WidgetInstance

    var body: some View {
        let svc = CalendarService.shared
        TimelineView(.everyMinute) { ctx in
            let now = ReferenceScene.date(ctx.date)
            let next = CalData.hasEvents ? CalData.nextMeeting : nil
            Tile(width: w.kind.spec.width, padding: EdgeInsets(top: 0, leading: 13, bottom: 0, trailing: 11)) {
                HStack(spacing: m.u(12)) {
                    CalAppIcon(size: 36)
                    VStack(alignment: .leading, spacing: m.u(3)) {
                        if let e = next {
                            // The meeting title is SF Pro 11 semibold in the reference frame (like other list titles).
                            Text(e.title).dock(11, .semibold, design: .default)
                            HStack(spacing: m.u(5)) {
                                Text(verbatim: CalText.range(e)).dock(9, .semibold, p.secondary)
                                Text(verbatim: CalText.countdown(e, now: now))
                                    .dock(9, .semibold, e.start <= now ? p.accent(.cdGreen) : p.secondary)
                            }
                        } else if !CalData.hasEvents {
                            Text(L("Allow Calendar access")).dock(11, .bold)
                                .contentShape(Rectangle())
                                .onTapGesture { CalAccess.request(reminders: false) }
                            Text(L("Add calendar feed…")).dock(9, .semibold, p.secondary)
                                .contentShape(Rectangle())
                                .onTapGesture { CalFeedLink.add() }
                        } else {
                            Text(L("No upcoming meetings")).dock(11, .bold)
                            Text(L("Your calendar is clear")).dock(9, .semibold, p.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let e = next { joinButton(e) }
                }
            }
        }
        .onTapGesture {
            guard CalData.hasEvents else { CalAccess.request(reminders: false); return }
            if let e = CalData.nextMeeting { svc.open(e) } else { Panels.shared.toggle(w.id) { CalMonthPanel() } }
        }
        .demand(CalendarDemand.events)
        .onWidgetRefresh(w.id) { svc.refreshEvents() }
    }

    private func joinButton(_ e: DockEvent) -> some View {
        let video = e.meetingURL != nil
        return Button { CalendarService.shared.open(e) } label: {
            Image(systemName: video ? "video.fill" : "calendar")
                .font(.system(size: m.u(video ? 11.2 : 12.5), weight: .semibold))
                .foregroundStyle(video ? p.calOnAccent : p.primary)
                .offset(y: m.u(video ? 0.75 : 0))
                .frame(width: m.u(28), height: m.u(28))
                .background(Circle().fill(video ? p.accent(CalBrand.zoomBlue) : p.control))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .help(video ? L("Join") : L("Open Calendar"))
    }
}

// MARK: - Zoom meeting timer

struct CalZoomWidget: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    let w: WidgetInstance

    var body: some View {
        let zoom = ZoomDetector.shared
        let start = zoom.inMeeting ? zoom.meetingStart : nil
        Tile(width: w.kind.spec.width, padding: .hv(12, 0)) {
            HStack(spacing: m.u(8)) {
                VStack(alignment: .leading, spacing: m.u(1)) {
                    HStack(spacing: m.u(4)) {
                        Circle().fill(start != nil ? p.accent(.cdRed) : p.tertiary).frame(width: m.u(6), height: m.u(6))
                        Text(L("Zoom")).dock(10, .bold, p.secondary)
                    }
                    if let start {
                        TimelineView(.periodic(from: start, by: 1)) { ctx in
                            Text(verbatim: Fmt.duration(ctx.date.timeIntervalSince(start))).dock(20, .semibold, mono: true)
                        }
                    } else {
                        Text(L("No meeting")).dock(13, .semibold, p.secondary)
                    }
                }
                Spacer(minLength: 0)
                Button { Open.bundle("us.zoom.xos") } label: {
                    if start != nil {
                        Text(L("Leave")).dock(11, .bold, p.calOnAccent)
                            .padding(.horizontal, m.u(10)).frame(height: m.u(26))
                            .background(Capsule().fill(p.accent(.cdRed)))
                    } else {
                        Image(systemName: "video.fill").font(.system(size: m.u(12), weight: .semibold))
                            .foregroundStyle(p.calOnAccent)
                            .frame(width: m.u(30), height: m.u(30))
                            .background(Circle().fill(p.accent(CalBrand.zoomBlue)))
                    }
                }
                .buttonStyle(PressableStyle())
                .help(L("Open Zoom"))
            }
        }
        .onTapGesture { Open.bundle("us.zoom.xos") }
    }
}
