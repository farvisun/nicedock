import AppKit
import SwiftUI

/// Wraps one widget: routes to its family view and attaches the standard right-click menu.
struct WidgetHost: View {
    let instance: WidgetInstance

    var body: some View {
        WidgetFactory.view(for: instance)
            .environment(\.widget, instance)
            .contextMenu { WidgetMenu(instance: instance) }
            .help(instance.kind.spec.bare ? "" : instance.kind.spec.localizedTitle)
    }
}

enum WidgetFactory {
    @MainActor @ViewBuilder
    static func view(for w: WidgetInstance) -> some View {
        switch w.kind.spec.category {
        case .apps, .folders:
            if w.kind == .bookmarks || w.kind == .searchWeb { UtilityWidgets.view(w) } else { AppsWidgets.view(w) }
        case .clocks: ClockWidgets.view(w)
        case .calendar, .reminders: CalendarWidgets.view(w)
        case .weather: WeatherWidgets.view(w)
        case .system: SystemWidgets.view(w)
        case .controls, .utilities: UtilityWidgets.view(w)
        case .media, .photos, .mail, .notes, .phone: MediaWidgets.view(w)
        case .stocks, .crypto: FinanceWidgets.view(w)
        case .finance, .commerce, .analytics, .developer, .social, .ai: ConnectedWidgets.view(w)
        }
    }
}

private struct WidgetKey: EnvironmentKey {
    static let defaultValue = WidgetInstance(kind: .space)
}

extension EnvironmentValues {
    /// The instance being rendered (for config lookups inside nested views).
    var widget: WidgetInstance {
        get { self[WidgetKey.self] }
        set { self[WidgetKey.self] = newValue }
    }
}

extension Notification.Name {
    /// Posted with `object` = widget UUID (or nil for all) when the user chooses Refresh.
    static let coolDockRefresh = Notification.Name("CoolDockRefresh")
}

struct WidgetMenu: View {
    let instance: WidgetInstance
    private var store: AppStore { .shared }

    var body: some View {
        let spec = instance.kind.spec
        WidgetExtraMenu(instance: instance)
        if !spec.fields.isEmpty {
            Button(spec.connected ? L("Connection & Settings…") : L("Customize…")) { WidgetSetup.customize(instance) }
        }
        if spec.connected || [.weatherCompact, .weatherHero, .weatherLocation, .forecastDays, .weatherToday, .weatherCondition, .forecastHourly, .sunriseSunset, .wind,
                                 .dateTimeWeather, .weekStrip, .stockQuote, .stockChart, .stockWatchlist, .cryptoQuote, .cryptoChart, .cryptoWatchlist,
                                 .mail, .mailLatest, .notes, .reminders, .calendarToday, .agenda, .nextMeeting, .converter].contains(instance.kind) {
            Button(L("Refresh")) { NotificationCenter.default.post(name: .coolDockRefresh, object: instance.id) }
        }
        let rules = [VisibilityRule.always] + spec.visibility
        if rules.count > 1 {
            Menu(L("Visibility")) {
                ForEach(rules) { rule in
                    Button { store.updateWidget(instance.id) { $0.visibility = rule } } label: {
                        if instance.visibility == rule { Label(rule.title, systemImage: "checkmark") } else { Text(rule.title) }
                    }
                }
            }
        }
        Divider()
        Button(L("Widgets…")) { WidgetBrowser.show() }
        Button(L("Settings…")) { SettingsWindow.show() }
        Divider()
        Button(L("Remove"), role: .destructive) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { store.removeWidget(instance.id) }
        }
    }
}

/// Kind-specific menu items placed above the standard ones.
struct WidgetExtraMenu: View {
    let instance: WidgetInstance
    var body: some View {
        let w = instance
        switch w.kind.spec.category {
        case .apps, .folders:
            if w.kind == .bookmarks || w.kind == .searchWeb { UtilityWidgets.menu(w) } else { AppsWidgets.menu(w) }
        case .clocks: ClockWidgets.menu(w)
        case .calendar, .reminders: CalendarWidgets.menu(w)
        case .weather: WeatherWidgets.menu(w)
        case .system: SystemWidgets.menu(w)
        case .controls, .utilities: UtilityWidgets.menu(w)
        case .media, .photos, .mail, .notes, .phone: MediaWidgets.menu(w)
        case .stocks, .crypto: FinanceWidgets.menu(w)
        case .finance, .commerce, .analytics, .developer, .social, .ai: ConnectedWidgets.menu(w)
        }
    }
}
