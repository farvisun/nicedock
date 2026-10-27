import AppKit
import Observation
import SwiftUI

/// Root state: settings, profiles and transient dock UI flags.
@Observable
@MainActor
final class AppStore {
    static let shared = AppStore()

    /// Mirrors `settings.useEstedad` for non-isolated font lookups.
    nonisolated(unsafe) static var estedadEnabled = true
    /// Disabled by the render harness so developer renders never touch the user's saved state.
    nonisolated(unsafe) static var persistenceEnabled = true

    var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            applyDerived(old: oldValue)
            scheduleSave()
        }
    }

    var profiles: [DockProfile] { didSet { scheduleSave() } }
    var activeProfileID: UUID { didSet { scheduleSave() } }

    // Transient UI state (not persisted)
    var browserOpen = false
    var dockHidden = false
    var editingWidget: UUID?
    var hoveringDock = false
    var languageRevision = 0
    var systemReduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency

    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private let fileURL: URL

    private init() {
        AppPaths.ensureSupportDirectory()
        fileURL = AppPaths.stateFile

        if let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode(Persisted.self, from: data), !saved.profiles.isEmpty {
            settings = saved.settings
            profiles = saved.profiles
            activeProfileID = saved.profiles.contains { $0.id == saved.activeProfileID } ? saved.activeProfileID : saved.profiles[0].id
        } else {
            let defaults = AppStore.defaultProfiles()
            settings = Settings()
            profiles = defaults
            activeProfileID = defaults[0].id
        }
        AppStore.estedadEnabled = settings.useEstedad
        Localizer.activate(settings.language)
        Fmt.configure(language: settings.language, calendar: settings.calendarSystem, digits: settings.digitStyle, clock: settings.clockStyle)
    }

    /// state.json layout, shared with the AI Assistant's offline path (`DockStateFile`).
    typealias Persisted = DockState

    // MARK: Derived

    var resolvedLanguage: AppLanguage { settings.language.resolved }
    var layoutDirection: LayoutDirection { resolvedLanguage.isRTL ? .rightToLeft : .leftToRight }

    var palette: DockPalette {
        DockPalette.make(style: settings.dockStyle, surface: settings.widgetSurface, monochrome: settings.monochrome,
                         tiles: settings.tileBackgrounds, reduceTransparency: reduceTransparency)
    }

    var reduceTransparency: Bool { settings.reduceTransparency || systemReduceTransparency }

    var metrics: DockMetrics {
        DockMetrics(scale: settings.dockScale, spacing: settings.widgetSpacing, cornerRadius: settings.cornerRadius)
    }

    var activeProfile: DockProfile {
        profiles.first { $0.id == activeProfileID } ?? profiles[0]
    }

    var activeIndex: Int { profiles.firstIndex { $0.id == activeProfileID } ?? 0 }

    private func applyDerived(old: Settings) {
        if settings.language != old.language || settings.calendarSystem != old.calendarSystem
            || settings.digitStyle != old.digitStyle || settings.clockStyle != old.clockStyle || settings.useEstedad != old.useEstedad {
            AppStore.estedadEnabled = settings.useEstedad
            Localizer.activate(settings.language)
            Fmt.configure(language: settings.language, calendar: settings.calendarSystem, digits: settings.digitStyle, clock: settings.clockStyle)
            languageRevision &+= 1
            NotificationCenter.default.post(name: .coolDockLanguageChanged, object: nil)
        }
        if settings.appTheme != old.appTheme { applyAppTheme() }
        NotificationCenter.default.post(name: .coolDockSettingsChanged, object: nil)
    }

    func applyAppTheme() {
        switch settings.appTheme {
        case .auto: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    // MARK: Persistence

    private func scheduleSave() {
        guard AppStore.persistenceEnabled else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func saveNow() {
        guard AppStore.persistenceEnabled else { return }
        let snapshot = Persisted(settings: settings, profiles: profiles, activeProfileID: activeProfileID)
        let url = fileURL
        DispatchQueue.global(qos: .utility).async {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? enc.encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
    }

    // MARK: Profile & widget mutations

    func updateActive(_ mutate: (inout DockProfile) -> Void) {
        guard let i = profiles.firstIndex(where: { $0.id == activeProfileID }) else { return }
        mutate(&profiles[i])
    }

    func addWidget(_ kind: WidgetKind, config: [String: String] = [:], at index: Int? = nil) {
        let instance = WidgetInstance(kind: kind, config: config)
        updateActive { p in
            if let index, index >= 0, index <= p.widgets.count { p.widgets.insert(instance, at: index) } else { p.widgets.append(instance) }
        }
    }

    func removeWidget(_ id: UUID) {
        Secrets.removeAll(for: id)
        updateActive { $0.widgets.removeAll { $0.id == id } }
    }

    func updateWidget(_ id: UUID, _ mutate: (inout WidgetInstance) -> Void) {
        updateActive { p in
            if let i = p.widgets.firstIndex(where: { $0.id == id }) { mutate(&p.widgets[i]) }
        }
    }

    func moveWidget(_ id: UUID, to newIndex: Int) {
        updateActive { p in
            guard let from = p.widgets.firstIndex(where: { $0.id == id }) else { return }
            let item = p.widgets.remove(at: from)
            p.widgets.insert(item, at: max(0, min(newIndex, p.widgets.count)))
        }
    }

    func widget(_ id: UUID) -> WidgetInstance? { activeProfile.widgets.first { $0.id == id } }

    func switchProfile(to index: Int) {
        guard profiles.indices.contains(index) else { return }
        if activeProfileID != profiles[index].id {
            withAnimation(settings.animations ? .spring(response: 0.35, dampingFraction: 0.86) : nil) {
                activeProfileID = profiles[index].id
            }
        }
    }

    func switchProfile(by delta: Int) {
        let n = profiles.count
        guard n > 1 else { return }
        switchProfile(to: (activeIndex + delta + n) % n)
    }

    @discardableResult
    func newProfile(named name: String? = nil, duplicating source: DockProfile? = nil) -> DockProfile? {
        guard profiles.count < 8 else { return nil }
        var p = DockProfile(name: name ?? L("Profile %d", profiles.count + 1))
        if let source {
            p.name = String((source.name + " " + LD("profile.copySuffix", "Copy")).prefix(24))
            p.symbol = source.symbol
            p.widgets = source.widgets.map { var w = $0; let old = w.id; w.id = UUID(); Secrets.copyAll(from: old, to: w.id); return w }
        }
        profiles.append(p)
        activeProfileID = p.id
        return p
    }

    func deleteProfile(_ id: UUID) {
        guard profiles.count > 1, let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[i].widgets.forEach { Secrets.removeAll(for: $0.id) }
        profiles.remove(at: i)
        if activeProfileID == id { activeProfileID = profiles[max(0, i - 1)].id }
    }

    func resetEverything() {
        let defaults = AppStore.defaultProfiles()
        settings = Settings()
        profiles = defaults
        activeProfileID = defaults[0].id
    }

    // MARK: AI Assistant

    /// What the assistant tools read and edit (see `DockTools`).
    var dockState: DockState { DockState(settings: settings, profiles: profiles, activeProfileID: activeProfileID) }

    /// Applies a state produced by an assistant tool exactly like a change made in Settings: animated,
    /// propagated through the usual didSet hooks and saved by the regular debounce.
    func applyAssistantState(_ state: DockState, effects: [DockEffect]) {
        withAnimation(settings.animations ? .spring(response: 0.35, dampingFraction: 0.86) : nil) {
            if profiles != state.profiles { profiles = state.profiles }
            if activeProfileID != state.activeProfileID, state.profiles.contains(where: { $0.id == state.activeProfileID }) {
                activeProfileID = state.activeProfileID
            }
            if settings != state.settings { settings = state.settings }
        }
        for effect in effects {
            switch effect {
            case .removeSecrets(let id): Secrets.removeAll(for: id)
            case .copySecrets(let from, let to): Secrets.copyAll(from: from, to: to)
            case .refresh(let id): NotificationCenter.default.post(name: .coolDockRefresh, object: id)
            }
        }
    }

    // MARK: Defaults

    nonisolated static func defaultProfiles() -> [DockProfile] {
        func w(_ k: WidgetKind, _ c: [String: String] = [:]) -> WidgetInstance { WidgetInstance(kind: k, config: c) }
        let home = DockProfile(name: L("Home"), symbol: "house", widgets: [
            w(.timeHero), w(.weatherHero),
            w(.appFolder, ["name": "Favorites", "apps": "/Applications/Safari.app\n/System/Applications/Music.app\n/System/Applications/Notes.app\n/System/Applications/Calendar.app"]),
            w(.progressRing), w(.nowPlayingHero), w(.separator), w(.cpuRing), w(.memoryRing), w(.downloads)
        ])
        let work = DockProfile(name: L("Work"), symbol: "briefcase", widgets: [
            w(.agenda), w(.nextMeeting), w(.reminders), w(.pomodoro), w(.separator), w(.mail), w(.searchWeb)
        ])
        let system = DockProfile(name: L("System"), symbol: "cpu", widgets: [
            w(.cpuGraph), w(.networkGraph), w(.batteryRing), w(.storageRing), w(.audioControls), w(.quickToggles), w(.screenshots)
        ])
        return [home, work, system]
    }
}

extension Notification.Name {
    static let coolDockLanguageChanged = Notification.Name("CoolDockLanguageChanged")
    static let coolDockSettingsChanged = Notification.Name("CoolDockSettingsChanged")
}
