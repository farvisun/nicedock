import AppKit
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, appearance, layout, screens, dock, profiles, widgets, shortcuts, language, privacy, performance, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return L("General")
        case .appearance: return L("Appearance")
        case .layout: return L("Layout")
        case .screens: return L("Screens")
        case .dock: return L("Dock")
        case .profiles: return L("Profiles")
        case .widgets: return L("Widgets")
        case .shortcuts: return L("Shortcuts")
        case .language: return L("Language & Region")
        case .privacy: return L("Privacy & Permissions")
        case .performance: return L("Performance")
        case .about: return L("About")
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .appearance: return "paintpalette.fill"
        case .layout: return "rectangle.bottomhalf.inset.filled"
        case .screens: return "display.2"
        case .dock: return "dock.rectangle"
        case .profiles: return "person.2.crop.square.stack.fill"
        case .widgets: return "square.grid.2x2.fill"
        case .shortcuts: return "command"
        case .language: return "globe"
        case .privacy: return "hand.raised.fill"
        case .performance: return "gauge.with.dots.needle.67percent"
        case .about: return "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: return .cdGray
        case .appearance: return .cdPink
        case .layout: return .cdBlue
        case .screens: return .cdIndigo
        case .dock: return .cdTeal
        case .profiles: return .cdOrange
        case .widgets: return .cdPurple
        case .shortcuts: return Color(white: 0.35)
        case .language: return .cdGreen
        case .privacy: return .cdBlue
        case .performance: return .cdRed
        case .about: return .cdGray
        }
    }

    var group: Int {
        switch self {
        case .general, .appearance, .layout, .screens: return 0
        case .dock, .profiles, .widgets, .shortcuts: return 1
        case .language, .privacy, .performance: return 2
        case .about: return 3
        }
    }
}

@MainActor
enum SettingsWindow {
    private static let host = WindowHost(id: "settings")
    private static let nav = SettingsNavigation()

    /// `anchor` scrolls to a section with that `.id` once the pane is shown.
    static func show(pane: SettingsPane? = nil, anchor: String? = nil) {
        if let pane { nav.pane = pane }
        nav.anchor = anchor
        Panels.shared.close()
        host.show(title: L("NiceDock Settings"), size: NSSize(width: 860, height: 640), minSize: NSSize(width: 760, height: 520), toolbar: true) {
            SettingsRoot(nav: nav).id(AppStore.shared.languageRevision)
        }
    }

    /// Re-renders the open window (used after language changes so titles update).
    static func refreshIfOpen() {
        if host.isVisible { show() }
    }
}

@Observable
@MainActor
final class SettingsNavigation {
    var pane: SettingsPane = .general
    var search = ""
    var anchor: String?
}

struct SettingsRoot: View {
    @Bindable var nav: SettingsNavigation
    private var store: AppStore { .shared }

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { nav.pane }, set: { if let p = $0 { nav.pane = p } })) {
                ForEach(0..<4) { group in
                    Section {
                        ForEach(SettingsPane.allCases.filter { $0.group == group && matches($0) }) { pane in
                            NavigationLink(value: pane) {
                                Label {
                                    Text(pane.title).font(.ui(13))
                                } icon: {
                                    SettingsIcon(symbol: pane.symbol, tint: pane.tint)
                                }
                            }
                            // The link's own press does nothing here (the list's selection drives the detail), so
                            // VoiceOver's VO-Space and Voice Control's "Click Appearance" left the pane unchanged.
                            .accessibilityAction { nav.pane = pane }
                        }
                    }
                }
            }
            .searchable(text: $nav.search, placement: .sidebar, prompt: L("Search"))
            .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
        } detail: {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        pane(nav.pane)
                    }
                    .frame(maxWidth: 680, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 22)
                }
                .onAppear { scrollToAnchor(proxy) }
                .onChange(of: nav.anchor) { scrollToAnchor(proxy) }
            }
            .navigationTitle(nav.pane.title)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .onReceive(NotificationCenter.default.publisher(for: .coolDockLanguageChanged)) { _ in
            DispatchQueue.main.async { SettingsWindow.refreshIfOpen() }
        }
    }

    private func scrollToAnchor(_ proxy: ScrollViewProxy) {
        guard let anchor = nav.anchor else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(anchor, anchor: .top) }
            nav.anchor = nil
        }
    }

    private func matches(_ pane: SettingsPane) -> Bool {
        let q = nav.search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty || pane.title.lowercased().contains(q) || pane.rawValue.contains(q) || SettingsSearchIndex.keywords(pane).contains { $0.lowercased().contains(q) }
    }

    @ViewBuilder private func pane(_ p: SettingsPane) -> some View {
        switch p {
        case .general: GeneralPane()
        case .appearance: AppearancePane()
        case .layout: LayoutPane()
        case .screens: ScreensPane()
        case .dock: DockPane()
        case .profiles: ProfilesPane()
        case .widgets: WidgetsPane()
        case .shortcuts: ShortcutsPane()
        case .language: LanguagePane()
        case .privacy: PrivacyPane()
        case .performance: PerformancePane()
        case .about: AboutPane()
        }
    }
}

enum SettingsSearchIndex {
    static func keywords(_ pane: SettingsPane) -> [String] {
        switch pane {
        case .general: return [L("Launch at login"), L("Menu bar"), L("Weather units"), L("Screenshots"), L("Diagnostics")]
        case .appearance: return [L("Dock Style"), L("Dock Size"), L("Widget Spacing"), L("Monochrome"), L("Transparency"), L("Corner Radius"), L("Theme")]
        case .layout: return [L("Position"), L("Reveal"), L("Floating"), L("Fullscreen"), L("Auto-Hide"), L("Windows"), L("Reserve Dock Space"), L("Hide on Window Hover")]
        case .screens: return [L("Displays"), L("Monitor")]
        case .dock: return [L("Running apps"), L("Folders"), L("Drag")]
        case .profiles: return [L("Profile switcher")]
        case .widgets: return [L("Visibility"), L("Customize"), L("App Volume"), L("Remember volume per app")]
        case .shortcuts: return [L("Hotkey"), L("Keyboard")]
        case .language: return ["فارسی", "Persian", "Estedad", L("Calendar"), L("Digits"), L("24-hour")]
        case .privacy: return [L("Permissions"), L("Keychain"), L("Credentials"), L("Encrypted File"), L("Accessibility"), L("Calendar Feeds"), "ICS", "webcal", L("AI Assistant"), "MCP", "Claude", "Codex", "Cursor", "VS Code"]
        case .performance: return [L("Memory"), L("CPU"), L("Cache")]
        case .about: return [L("Version")]
        }
    }
}

// MARK: - Building blocks

struct SettingsIcon: View {
    var symbol: String
    var tint: Color
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).fill(tint.gradient))
    }
}

/// Grouped card section in the System Settings style.
struct SettingsGroup<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title).font(.ui(13, .semibold)).foregroundStyle(.secondary).padding(.leading, 4)
            }
            VStack(spacing: 0) {
                _VariadicView.Tree(DividedLayout()) { content() }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
            if let footer {
                Text(footer).font(.ui(11.5)).foregroundStyle(.secondary).padding(.horizontal, 4).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 20)
    }
}

private struct DividedLayout: _VariadicView_MultiViewRoot {
    @ViewBuilder
    func body(children: _VariadicView.Children) -> some View {
        let last = children.last?.id
        ForEach(children) { child in
            child.padding(.horizontal, 12).padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading)
            if child.id != last { Divider().padding(.leading, 12) }
        }
    }
}

/// Label/control row.
struct SettingsRow<Control: View>: View {
    var title: String
    var subtitle: String? = nil
    var symbol: String? = nil
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if let symbol {
                Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.ui(13))
                if let subtitle {
                    Text(subtitle).font(.ui(11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            control()
        }
    }
}

struct ToggleRow: View {
    var title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle) {
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }
}

struct SliderRow: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 1
    var minLabel: String? = nil
    var maxLabel: String? = nil
    var format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.ui(13))
                Spacer()
                Text(format(value)).font(.ui(12, .medium)).foregroundStyle(.secondary).monospacedDigit()
            }
            HStack(spacing: 8) {
                if let minLabel { Text(minLabel).font(.ui(11)).foregroundStyle(.secondary) }
                Slider(value: $value, in: range, step: step).controlSize(.small)
                if let maxLabel { Text(maxLabel).font(.ui(11)).foregroundStyle(.secondary) }
            }
        }
    }
}

/// Binding into AppStore.settings by key path.
@MainActor
func setting<T>(_ kp: WritableKeyPath<Settings, T>) -> Binding<T> {
    Binding(get: { AppStore.shared.settings[keyPath: kp] }, set: { AppStore.shared.settings[keyPath: kp] = $0 })
}

struct PaneHeader: View {
    var pane: SettingsPane
    var subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            SettingsIcon(symbol: pane.symbol, tint: pane.tint, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(pane.title).font(.ui(20, .bold))
                Text(subtitle).font(.ui(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 22)
    }
}
