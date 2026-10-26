import SwiftUI

/// Calendar, progress, reminders, todo and Linear widgets.
enum CalendarWidgets {
    @MainActor @ViewBuilder
    static func view(_ w: WidgetInstance) -> some View {
        switch w.kind {
        case .calendarToday: CalTodayWidget(w: w)
        case .agenda: CalAgendaWidget(w: w)
        case .weekStrip: CalWeekStripWidget(w: w)
        case .nextMeeting: CalNextMeetingWidget(w: w)
        case .zoomMeeting: CalZoomWidget(w: w)
        case .dayProgress, .monthProgress, .yearProgress: CalProgressGridWidget(w: w)
        case .progressRing: CalProgressRingWidget(w: w)
        case .reminders: CalRemindersWidget(w: w)
        case .todo: CalTodoWidget(w: w)
        case .linear: CalLinearWidget(w: w)
        default: Tile(width: w.kind.spec.width) { Text(w.kind.spec.localizedTitle).dock(11) }
        }
    }

    @MainActor @ViewBuilder
    static func menu(_ w: WidgetInstance) -> some View {
        switch w.kind {
        case .calendarToday, .agenda, .weekStrip, .nextMeeting:
            Button(L("Show Month…")) { Panels.shared.show(w.id) { CalMonthPanel() } }
            Button(L("Open Calendar")) { Open.bundle("com.apple.iCal") }
            Divider()
        case .zoomMeeting:
            Button(L("Open Zoom")) { Open.bundle("us.zoom.xos") }
            Divider()
        case .reminders:
            Button(L("Show All Reminders…")) { Panels.shared.show(w.id) { CalRemindersPanel() } }
            Button(L("Open Reminders")) { Open.bundle("com.apple.reminders") }
            Divider()
        case .todo:
            let id = w.id
            Button(L("Show List…")) { Panels.shared.show(id) { CalTodoPanel(id: id) } }
            if !CalTodoStore.items(w).isEmpty {
                Button(L("Clear All Tasks"), role: .destructive) { CalTodoStore.mutate(id) { $0.removeAll() } }
            }
            Divider()
        case .linear:
            Button(L("Open Linear")) { Open.url("https://linear.app") }
            Divider()
        default:
            EmptyView()
        }
    }
}
