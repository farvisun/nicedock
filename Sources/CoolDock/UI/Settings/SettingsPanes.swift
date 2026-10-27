import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

// MARK: - General

struct GeneralPane: View {
    @State private var loginEnabled = LoginItem.isEnabled
    private var store: AppStore { .shared }

    var body: some View {
        PaneHeader(pane: .general, subtitle: L("Startup behaviour, the menu bar icon, units and diagnostics."))
        SettingsGroup(title: L("Startup")) {
            SettingsRow(title: L("Launch CoolDock at login"), subtitle: LoginItem.needsApproval ? L("Waiting for approval in System Settings → Login Items.") : nil) {
                HStack {
                    if LoginItem.needsApproval { Button(L("Open Login Items")) { LoginItem.openSystemSettings() } }
                    Toggle("", isOn: Binding(get: { loginEnabled }, set: { LoginItem.set($0); loginEnabled = LoginItem.isEnabled; store.settings.launchAtLogin = $0 }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            }
            ToggleRow(title: L("Show menu bar icon"), subtitle: L("You can still open Settings by right-clicking the Dock."), isOn: setting(\.showMenuBarIcon))
        }
        SettingsGroup(title: L("Weather")) {
            SettingsRow(title: L("Temperature unit")) {
                Picker("", selection: setting(\.temperatureUnit)) {
                    ForEach(TemperatureUnit.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().frame(width: 200)
            }
        }
        SettingsGroup(title: L("Screenshots"), footer: L("Recent Screenshots reads the macOS screenshot folder, Desktop and Pictures/Screenshots automatically.")) {
            SettingsRow(title: L("Screenshot folder"), subtitle: store.settings.screenshotFolder ?? L("Automatic locations")) {
                HStack {
                    if store.settings.screenshotFolder != nil {
                        Button(L("Use Automatic Locations")) { store.settings.screenshotFolder = nil }
                    }
                    Button(store.settings.screenshotFolder == nil ? L("Choose Folder…") : L("Change Folder…")) {
                        if let url = FilePickers.folder() { store.settings.screenshotFolder = url.path }
                    }
                }
            }
        }
        SettingsGroup(title: L("Support")) {
            SettingsRow(title: L("Export Diagnostics"), subtitle: L("Saves a support file. Secrets are never included.")) {
                Button(L("Export…")) { Diagnostics.export() }
            }
            SettingsRow(title: L("Show Onboarding")) { Button(L("Show")) { OnboardingWindow.show() } }
            SettingsRow(title: L("Reset CoolDock"), subtitle: L("Restores default settings and profiles.")) {
                Button(L("Reset…"), role: .destructive) { confirmReset() }
            }
        }
    }

    private func confirmReset() {
        let alert = NSAlert()
        alert.messageText = L("Reset all settings and profiles?")
        alert.informativeText = L("Your widgets, profiles and preferences return to their defaults. Saved credentials are kept.")
        alert.addButton(withTitle: L("Reset"))
        alert.addButton(withTitle: L("Cancel"))
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn { store.resetEverything() }
    }
}

// MARK: - Appearance

struct AppearancePane: View {
    private var store: AppStore { .shared }

    var body: some View {
        let s = store.settings
        PaneHeader(pane: .appearance, subtitle: L("Scale, density, colours and surfaces of the Dock."))
        DockPreview().padding(.bottom, 20)

        SettingsGroup(title: L("App appearance"), footer: L("Affects CoolDock windows. Dock Style controls the Dock bar separately.")) {
            SettingsRow(title: L("Theme")) {
                Picker("", selection: setting(\.appTheme)) { ForEach(AppTheme.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 220)
            }
        }

        SettingsGroup(title: L("Dock Style")) {
            StylePicker()
            if s.dockStyle == .transparent {
                SettingsRow(title: L("Widget surface")) {
                    Picker("", selection: setting(\.widgetSurface)) { ForEach(WidgetSurface.allCases) { Text($0.title).tag($0) } }
                        .labelsHidden().frame(width: 180)
                }
            }
        }

        SettingsGroup(title: L("Size and spacing")) {
            SliderRow(title: L("Dock Size"), value: setting(\.dockScale), range: 0.7...1.4, step: 0.05, minLabel: L("Small"), maxLabel: L("Large")) {
                Fmt.percent($0)
            }
            SliderRow(title: L("Widget Spacing"), value: setting(\.widgetSpacing), range: 0...20, step: 1, minLabel: L("Compact"), maxLabel: L("Spacious")) {
                Fmt.int(Int($0)) + " " + L("pt")
            }
            SliderRow(title: L("Corner Radius"), value: setting(\.cornerRadius), range: 4...22, step: 0.5, minLabel: L("Square"), maxLabel: L("Round")) {
                Fmt.number($0, decimals: $0 == $0.rounded() ? 0 : 1) + " " + L("pt")
            }
            SettingsRow(title: L("When widgets don't fit")) {
                Picker("", selection: setting(\.overflow)) { ForEach(OverflowMode.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 200)
            }
        }

        SettingsGroup(title: L("Widget presentation")) {
            SettingsRow(title: L("Widget Colors"), subtitle: L("Monochrome removes accent colours from charts, controls and chrome.")) {
                Picker("", selection: setting(\.monochrome)) {
                    Text(L("Colorful")).tag(false)
                    Text(L("Monochrome")).tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 200)
            }
            if s.dockStyle != .transparent {
                ToggleRow(title: L("Tile backgrounds & borders"), subtitle: L("Frosted fills and outlines around each widget."), isOn: setting(\.tileBackgrounds))
            }
            ToggleRow(title: L("Dock shadow"), isOn: setting(\.shadow))
            SettingsRow(title: L("App Icon Style")) {
                Picker("", selection: setting(\.iconStyle)) { ForEach(AppIconStyle.allCases) { Text($0.title).tag($0) } }
                    .labelsHidden().frame(width: 160)
            }
        }

        SettingsGroup(title: L("Performance"), footer: L("Reduce transparency replaces glass blur with solid fills — much lighter on the GPU with several displays. Enabled automatically when macOS Reduce Transparency is on.")) {
            ToggleRow(title: L("Reduce transparency"), isOn: setting(\.reduceTransparency))
            ToggleRow(title: L("Animations"), isOn: setting(\.animations))
        }
    }
}

struct StylePicker: View {
    private var store: AppStore { .shared }

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
            ForEach(DockStyle.available) { style in
                let selected = store.settings.dockStyle == style
                Button { store.settings.dockStyle = style } label: {
                    VStack(spacing: 6) {
                        StyleSwatch(style: style).frame(height: 54)
                        Text(style.title).font(.ui(11.5, selected ? .semibold : .regular))
                    }
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? Color.accentColor.opacity(0.12) : .clear))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 2 : 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
}

struct StyleSwatch: View {
    var style: DockStyle
    var body: some View {
        let palette = DockPalette.make(style: style, surface: .glass, monochrome: false, tiles: true, reduceTransparency: false)
        ZStack {
            WallpaperBackdrop()
            HStack(spacing: 3) {
                ForEach(0..<3) { i in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(palette.tileFill)
                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(palette.tileStroke, lineWidth: 0.5))
                        .overlay(Capsule().fill(palette.primary.opacity(0.85)).frame(width: 10, height: 2.5))
                        .frame(width: i == 1 ? 24 : 16, height: 20)
                }
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(style == .liquidGlass ? Color.white.opacity(0.25) : palette.plate))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(palette.plateStroke, lineWidth: 0.5))
        }
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// Soft green-hills gradient inspired by the CoolDock hero scene.
struct WallpaperBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: "#F4EBD0"), Color(hex: "#C9D6A3"), Color(hex: "#5E7F3B"), Color(hex: "#2F4A1E")], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color.white.opacity(0.65), .clear], center: UnitPoint(x: 0.4, y: 0.25), startRadius: 0, endRadius: 160)
        }
    }
}

/// Live preview of the active profile's first widgets with the current style.
struct DockPreview: View {
    private var store: AppStore { .shared }

    var body: some View {
        let s = store.settings
        let widgets = Array(store.activeProfile.widgets.prefix(4))
        let metrics = DockMetrics(scale: min(1, s.dockScale) * 0.82, spacing: s.widgetSpacing, cornerRadius: s.cornerRadius)
        let shape = RoundedRectangle(cornerRadius: metrics.plateRadius, style: .continuous)
        ZStack(alignment: .bottom) {
            WallpaperBackdrop()
            HStack(spacing: metrics.gap) {
                ForEach(widgets) { WidgetHost(instance: $0).allowsHitTesting(false) }
            }
            .padding(metrics.padding)
            .background {
                if s.dockStyle == .lightGlass || s.dockStyle == .darkGlass || s.dockStyle == .liquidGlass {
                    ZStack { if !store.reduceTransparency { VisualEffectBlur(material: .hudWindow, blending: .withinWindow) }; shape.fill(store.palette.plate) }
                } else { shape.fill(store.palette.plate) }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(store.palette.plateStroke, lineWidth: 0.5))
            .shadow(color: .black.opacity(s.shadow ? 0.3 : 0), radius: 10, y: 4)
            .padding(.bottom, 18)
            .environment(\.palette, store.palette)
            .environment(\.metrics, metrics)
        }
        .frame(height: 150)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
    }
}

// MARK: - Layout

struct LayoutPane: View {
    @State private var dockAutohides = SystemDock.shared.autohides
    private var store: AppStore { .shared }

    var body: some View {
        let s = store.settings
        PaneHeader(pane: .layout, subtitle: L("Where CoolDock sits and how it works with the macOS Dock."))
        SettingsGroup(title: L("Layout scenario")) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(LayoutScenario.allCases) { sc in ScenarioCard(scenario: sc, selected: s.scenario == sc) { store.settings.scenario = sc } }
            }
            .padding(.vertical, 4)
        }

        SettingsGroup(title: L("Placement")) {
            if s.scenario == .fixed {
                SettingsRow(title: L("Screen Position")) { PositionGrid() }
            }
            if s.scenario != .floating {
                SliderRow(title: s.scenario.isTop || (s.scenario == .fixed && s.fixedPosition.isTop) ? L("Distance from Top Edge") : L("Distance from Bottom Edge"),
                          value: setting(\.edgeDistance), range: 0...80, step: 1) { Fmt.int(Int($0)) + " " + L("pt") }
            }
            if s.scenario != .fixed && s.scenario != .floating {
                SettingsRow(title: L("Alignment")) {
                    Picker("", selection: setting(\.alignment)) { ForEach(DockAlignment.allCases) { Text($0.title).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                }
            }
            if s.scenario == .floating {
                SettingsRow(title: L("Floating position"), subtitle: L("Drag the Dock by its background or the handle next to the profile tabs.")) {
                    Button(L("Recenter")) { store.settings.floatingOrigins = [:] }
                }
            }
        }

        if s.scenario.isReveal || s.scenario == .swapBottom {
            SettingsGroup(title: L("Reveal"), footer: L("If the macOS Dock also auto-hides at the bottom edge, a trigger area of 20–40 px keeps CoolDock's zone above the macOS Dock's.")) {
                SliderRow(title: L("Show Delay"), value: setting(\.showDelay), range: 0...2, step: 0.05) { Fmt.number($0, decimals: 2) + " " + L("s") }
                SliderRow(title: L("Hide Delay"), value: setting(\.hideDelay), range: 0...3, step: 0.05) { Fmt.number($0, decimals: 2) + " " + L("s") }
                SliderRow(title: L("Trigger Area Size"), value: setting(\.triggerSize), range: 1...60, step: 1) { Fmt.int(Int($0)) + " " + L("px") }
            }
        }

        WindowSettingsSection()

        SettingsGroup(title: L("macOS Dock")) {
            SettingsRow(title: dockAutohides ? L("The macOS Dock auto-hides") : L("The macOS Dock is always visible"),
                        subtitle: needsHint(s.scenario)) {
                HStack {
                    Button(dockAutohides ? L("Turn Off Dock Auto-Hide") : L("Turn On Dock Auto-Hide")) {
                        SystemDock.shared.setAutohide(!dockAutohides)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { dockAutohides = SystemDock.shared.autohides }
                    }
                    Button(L("Desktop & Dock…")) { SystemDock.shared.openDockSettings() }
                }
            }
        }
    }

    private func needsHint(_ sc: LayoutScenario) -> String? {
        switch sc {
        case .swapBottom where !dockAutohides: return L("Swap at the Bottom needs the macOS Dock set to auto-hide.")
        case .revealBottom where dockAutohides: return L("Reveal at the Bottom works best with the macOS Dock always visible.")
        default: return nil
        }
    }
}

struct ScenarioCard: View {
    var scenario: LayoutScenario
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                ScenarioDiagram(scenario: scenario).frame(width: 64, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(scenario.title).font(.ui(12.5, .semibold))
                    if scenario.recommended {
                        Text(L("Recommended")).font(.ui(9.5, .bold)).padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.cdGreen.opacity(0.18))).foregroundStyle(Color.cdGreen)
                            .fixedSize()
                    }
                    Text(scenario.summary).font(.ui(11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.03)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Tiny schematic of a screen showing where the dock lives for a scenario.
struct ScenarioDiagram: View {
    var scenario: LayoutScenario
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(LinearGradient(colors: [Color(hex: "#9DB7E8"), Color(hex: "#6C8FD6")], startPoint: .top, endPoint: .bottom))
                Rectangle().fill(.white.opacity(0.6)).frame(height: 3).position(x: w / 2, y: 1.5)
                let bar = RoundedRectangle(cornerRadius: 2.5)
                switch scenario {
                case .swapBottom:
                    bar.fill(.black.opacity(0.85)).frame(width: w * 0.55, height: 7).position(x: w / 2, y: h - 7)
                    Image(systemName: "arrow.up.arrow.down").font(.system(size: 7, weight: .bold)).foregroundStyle(.white).position(x: w * 0.88, y: h - 7)
                case .revealBottom:
                    bar.fill(.black.opacity(0.85)).frame(width: w * 0.55, height: 7).position(x: w / 2, y: h - 14)
                    bar.fill(.white.opacity(0.7)).frame(width: w * 0.4, height: 4).position(x: w / 2, y: h - 4)
                case .fixed:
                    bar.fill(.black.opacity(0.85)).frame(width: w * 0.55, height: 7).position(x: w / 2, y: 10)
                case .revealTop:
                    bar.fill(.black.opacity(0.85)).frame(width: w * 0.55, height: 7).position(x: w / 2, y: 10)
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).foregroundStyle(.white).position(x: w / 2, y: 21)
                case .replaceDock:
                    bar.fill(.black.opacity(0.85)).frame(width: w * 0.7, height: 8).position(x: w / 2, y: h - 6)
                case .replaceAutoHide:
                    bar.fill(.black.opacity(0.35)).frame(width: w * 0.7, height: 8).position(x: w / 2, y: h - 6)
                case .floating:
                    bar.fill(.black.opacity(0.85)).frame(width: w * 0.5, height: 7).position(x: w * 0.42, y: h * 0.55)
                }
            }
        }
    }
}

struct PositionGrid: View {
    private var store: AppStore { .shared }
    var body: some View {
        let rows: [[ScreenPosition]] = [[.topLeft, .topCenter, .topRight], [.bottomLeft, .bottomCenter, .bottomRight]]
        VStack(spacing: 4) {
            ForEach(0..<2) { r in
                HStack(spacing: 4) {
                    ForEach(rows[r]) { pos in
                        let selected = store.settings.fixedPosition == pos
                        Button { store.settings.fixedPosition = pos } label: {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(selected ? Color.accentColor : Color.primary.opacity(0.12))
                                .frame(width: 34, height: 16)
                        }
                        .buttonStyle(.plain)
                        .help(pos.title)
                    }
                }
            }
        }
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
    }
}

// MARK: - Screens

struct ScreensPane: View {
    @State private var renaming: String?
    @State private var newName = ""
    private var store: AppStore { .shared }

    var body: some View {
        let s = store.settings
        let connected = Set(NSScreen.screens.map(DockController.stableID))
        let displays = s.displays.sorted { (connected.contains($0.id) ? 0 : 1, 0) < (connected.contains($1.id) ? 0 : 1, 0) }
        PaneHeader(pane: .screens, subtitle: L("Choose which displays host CoolDock. Disconnected displays are remembered."))
        SettingsGroup {
            SettingsRow(title: L("Show CoolDock on")) {
                Picker("", selection: setting(\.screensMode)) { ForEach(ScreensMode.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 330)
            }
        }
        SettingsGroup(title: L("Displays"), footer: footer(s.screensMode)) {
            ForEach(displays) { d in
                let isConnected = connected.contains(d.id)
                HStack(spacing: 10) {
                    Image(systemName: d.builtIn ? "laptopcomputer" : "display").font(.system(size: 18)).foregroundStyle(isConnected ? Color.accentColor : .secondary).frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        if renaming == d.id {
                            TextField(L("Name"), text: $newName, onCommit: { commitRename(d.id) }).textFieldStyle(.roundedBorder).frame(width: 200)
                        } else {
                            Text(d.displayName).font(.ui(13, .medium))
                        }
                        Text(isConnected ? (d.builtIn ? L("Built-in · Connected") : L("External · Connected")) : L("Last seen %@", Fmt.date(d.lastSeen, "MMMd")))
                            .font(.ui(11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    switch s.screensMode {
                    case .one:
                        Button(s.preferredDisplay == d.id ? L("Preferred") : L("Use This Display")) { store.settings.preferredDisplay = d.id }
                            .disabled(s.preferredDisplay == d.id)
                    case .attached:
                        Toggle(L("Attached"), isOn: Binding(get: { d.attached }, set: { v in mutate(d.id) { $0.attached = v } })).toggleStyle(.checkbox)
                    case .all:
                        EmptyView()
                    }
                    Menu {
                        Button(L("Identify")) { identify(d.id) }
                        Button(L("Rename…")) { renaming = d.id; newName = d.customName ?? d.name }
                        Button(L("Move Up")) { move(d.id, -1) }
                        Button(L("Move Down")) { move(d.id, 1) }
                        if !isConnected { Divider(); Button(L("Forget"), role: .destructive) { store.settings.displays.removeAll { $0.id == d.id } } }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
                }
            }
        }
        HStack {
            Button(L("Identify Displays")) { NSScreen.screens.forEach { identify(DockController.stableID($0)) } }
            Spacer()
        }
    }

    private func footer(_ mode: ScreensMode) -> String {
        switch mode {
        case .one: return L("If the preferred display is disconnected, CoolDock moves to the built-in display and returns when it comes back.")
        case .attached: return L("The highest attached display in the list wins. If none is connected, CoolDock stays hidden.")
        case .all: return L("A copy of CoolDock appears on every connected display with the same profile.")
        }
    }

    private func mutate(_ id: String, _ f: (inout KnownDisplay) -> Void) {
        if let i = store.settings.displays.firstIndex(where: { $0.id == id }) { f(&store.settings.displays[i]) }
    }

    private func commitRename(_ id: String) {
        mutate(id) { $0.customName = newName.trimmingCharacters(in: .whitespaces) }
        renaming = nil
    }

    private func move(_ id: String, _ delta: Int) {
        var list = store.settings.displays
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        let j = max(0, min(list.count - 1, i + delta))
        list.swapAt(i, j)
        store.settings.displays = list
    }

    private func identify(_ id: String) {
        guard let screen = NSScreen.screens.first(where: { DockController.stableID($0) == id }),
              let d = store.settings.displays.first(where: { $0.id == id }) else { return }
        DisplayIdentifier.flash(d.displayName, on: screen)
    }
}

@MainActor
enum DisplayIdentifier {
    static func flash(_ name: String, on screen: NSScreen) {
        let size = NSSize(width: 420, height: 120)
        let f = screen.frame
        let w = NSPanel(contentRect: NSRect(x: f.midX - size.width / 2, y: f.midY - size.height / 2, width: size.width, height: size.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.level = .screenSaver
        w.isOpaque = false
        w.backgroundColor = .clear
        w.contentView = NSHostingView(rootView: Text(name).font(.ui(30, .bold)).foregroundStyle(.white)
            .frame(width: size.width, height: size.height)
            .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.black.opacity(0.8))))
        w.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { w.orderOut(nil) }
    }
}

// MARK: - Dock

struct DockPane: View {
    var body: some View {
        PaneHeader(pane: .dock, subtitle: L("Running apps, folders and dragging behaviour."))
        SettingsGroup(title: L("Running apps")) {
            SettingsRow(title: L("Show running apps")) {
                Picker("", selection: setting(\.runningApps)) { ForEach(RunningAppsPlacement.allCases) { Text($0.title).tag($0) } }
                    .labelsHidden().frame(width: 180)
            }
            if AppStore.shared.settings.runningApps != .hidden {
                SettingsRow(title: L("Display")) {
                    Picker("", selection: setting(\.runningAppsCollapsed)) {
                        Text(L("Show all")).tag(false)
                        Text(L("Collapsed")).tag(true)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 200)
                }
            }
            ToggleRow(title: L("Show running indicators"), isOn: setting(\.showRunningIndicators))
        }
        SettingsGroup(title: L("Folders")) {
            ToggleRow(title: L("Open Folders in Finder"), subtitle: L("Off: browse folder contents in an in-Dock gallery."), isOn: setting(\.openFoldersInFinder))
        }
        SettingsGroup(title: L("Dragging"), footer: L("With the option off, a plain drag across the Dock switches profiles and ⌘-drag moves any item.")) {
            ToggleRow(title: L("Drag apps to rearrange"), subtitle: L("Move app and folder icons with a plain drag, like the macOS Dock."), isOn: setting(\.dragAppsToRearrange))
            ToggleRow(title: L("Drag to switch profiles"), isOn: setting(\.dragToSwitchProfiles))
        }
    }
}

// MARK: - Shortcuts

struct ShortcutsPane: View {
    private var store: AppStore { .shared }

    var body: some View {
        let s = store.settings
        PaneHeader(pane: .shortcuts, subtitle: L("Global shortcuts work even when another app is focused."))
        SettingsGroup(title: L("Dock")) {
            SettingsRow(title: L("Hide and Show Dock")) {
                HStack {
                    ShortcutRecorder(spec: setting(\.toggleHotKey))
                    Button(L("Reset")) { store.settings.toggleHotKey = Settings().toggleHotKey }
                    Toggle("", isOn: setting(\.toggleHotKey.enabled)).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            }
        }
        SettingsGroup(title: L("Profiles"), footer: L("The first profile uses 0, the second 1, and so on. Reordering profiles changes the numbers.")) {
            SettingsRow(title: L("Switch Profile")) {
                HStack {
                    ModifierRecorder(mask: setting(\.profileHotKeyModifiers))
                    Text(L("+ number")).foregroundStyle(.secondary)
                    Button(L("Reset")) { store.settings.profileHotKeyModifiers = Settings().profileHotKeyModifiers }
                    Toggle("", isOn: setting(\.profileHotKeysEnabled)).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            }
            ForEach(Array(store.profiles.enumerated()), id: \.element.id) { i, p in
                HStack {
                    Image(systemName: p.symbol).frame(width: 18).foregroundStyle(.secondary)
                    Text(p.name)
                    if p.id == store.activeProfileID { Text(L("Active")).font(.ui(10, .semibold)).foregroundStyle(Color.accentColor) }
                    Spacer()
                    KeyCaps(text: HotKeys.modifierString(s.profileHotKeyModifiers) + Fmt.digits("\(i)"))
                }
                .opacity(s.profileHotKeysEnabled ? 1 : 0.4)
            }
        }
        SettingsGroup(title: L("Useful controls")) {
            SettingsRow(title: L("Open Settings")) { KeyCaps(text: "⌘,") }
            SettingsRow(title: L("Search widgets")) { KeyCaps(text: "⌘F") }
            SettingsRow(title: L("Reorder widgets"), subtitle: L("Hold ⌘ while dragging a widget.")) { KeyCaps(text: "⌘ + drag") }
        }
    }
}

struct KeyCaps: View {
    var text: String
    var body: some View {
        Text(text).font(.system(size: 12, weight: .medium, design: .rounded)).padding(.horizontal, 8).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.15)))
            .environment(\.layoutDirection, .leftToRight)
    }
}

/// Click, then press a key combination.
struct ShortcutRecorder: View {
    @Binding var spec: HotKeySpec
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? L("Type shortcut…") : HotKeys.display(spec))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .frame(minWidth: 90)
                .environment(\.layoutDirection, .leftToRight)
        }
        .buttonStyle(.bordered)
        .tint(recording ? .accentColor : nil)
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        HotKeys.shared.uninstall()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == UInt16(kVK_Escape) { stop(); return nil }
            let mods = HotKeys.carbonMask(e.modifierFlags)
            guard mods != 0 else { NSSound.beep(); return nil }
            if mods == UInt32(cmdKey), e.keyCode == UInt16(kVK_ANSI_Comma) { NSSound.beep(); return nil }
            spec = HotKeySpec(keyCode: UInt32(e.keyCode), modifiers: mods, enabled: true)
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        HotKeys.shared.install()
    }
}

/// Records only a modifier combination (for the profile number prefix).
struct ModifierRecorder: View {
    @Binding var mask: UInt32
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button { recording ? stop() : start() } label: {
            Text(recording ? L("Hold modifiers…") : HotKeys.modifierString(mask)).font(.system(size: 12, weight: .medium, design: .rounded)).frame(minWidth: 70)
        }
        .buttonStyle(.bordered)
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { e in
            if e.type == .keyDown { stop(); return nil }
            let m = HotKeys.carbonMask(e.modifierFlags)
            if m != 0 && m.nonzeroBitCount >= 2 { mask = m }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: - Language

struct LanguagePane: View {
    private var store: AppStore { .shared }

    var body: some View {
        let s = store.settings
        PaneHeader(pane: .language, subtitle: L("Language, calendar, digits and typeface. Changes apply instantly."))
        LanguagePreview().padding(.bottom, 20)
        SettingsGroup(title: L("Language")) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], spacing: 8) {
                ForEach(AppLanguage.allCases) { lang in
                    let selected = s.language == lang
                    Button { store.settings.language = lang } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(lang == .system ? L("System Default") : lang.nativeName).font(lang.usesEstedad ? .custom("Estedad-SemiBold", size: 13) : .system(size: 13, weight: .semibold))
                            Text(lang == .system ? lang.resolved.nativeName : lang.englishName).font(.ui(10.5)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(9)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.03)))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 2 : 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
        SettingsGroup(title: L("Region")) {
            SettingsRow(title: L("Calendar")) {
                Picker("", selection: setting(\.calendarSystem)) { ForEach(CalendarSystem.allCases) { Text($0.title).tag($0) } }.labelsHidden().frame(width: 200)
            }
            SettingsRow(title: L("Digits")) {
                Picker("", selection: setting(\.digitStyle)) { ForEach(DigitStyle.allCases) { Text($0.title).tag($0) } }.labelsHidden().frame(width: 200)
            }
            SettingsRow(title: L("Time format")) {
                Picker("", selection: setting(\.clockStyle)) { ForEach(ClockStyle.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented).labelsHidden().frame(width: 240)
            }
        }
        SettingsGroup(title: L("Typeface"), footer: L("Estedad is an open-source Persian typeface (SIL Open Font License) bundled with CoolDock.")) {
            ToggleRow(title: L("Use Estedad for Persian and Arabic"), isOn: setting(\.useEstedad))
        }
    }
}

struct LanguagePreview: View {
    var body: some View {
        TimelineView(.everyMinute) { ctx in
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: Fmt.clock(ctx.date)).font(.dock(34, .semibold, mono: true))
                    Text(verbatim: Fmt.date(ctx.date, "EEEEMMMMdy")).font(.dock(13, .medium)).foregroundStyle(.secondary)
                }
                Divider().frame(height: 50)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: Fmt.compact(12_450) + " · " + Fmt.percent(0.48) + " · " + Fmt.temp(21)).font(.dock(16, .semibold))
                    Text(L("Your smart second Dock")).font(.dock(13, .medium)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        }
    }
}

// MARK: - Performance

struct PerformancePane: View {
    @State private var footprint = Diagnostics.memoryFootprintMB()
    @State private var cpu: Double = 0
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    private var store: AppStore { .shared }

    var body: some View {
        PaneHeader(pane: .performance, subtitle: L("CoolDock samples only what visible widgets need and pauses everything else."))
        HStack(spacing: 12) {
            StatCard(title: L("Memory"), value: Fmt.number(footprint, decimals: 1) + " " + L("MB"), symbol: "memorychip", tint: .cdBlue)
            StatCard(title: L("CPU"), value: Fmt.number(cpu * 100, decimals: 1) + Fmt.digits("%"), symbol: "cpu", tint: .cdGreen)
            StatCard(title: L("Widgets"), value: Fmt.int(store.activeProfile.widgets.count), symbol: "square.grid.2x2", tint: .cdPurple)
        }
        .padding(.bottom, 20)
        .onReceive(timer) { _ in
            footprint = Diagnostics.memoryFootprintMB()
            cpu = ProcessCPU.shared.sample()
        }
        SettingsGroup(title: L("Sampling")) {
            SliderRow(title: L("System stats interval"), value: setting(\.systemSampleInterval), range: 1...10, step: 1) { L("%@ s", Fmt.int(Int($0))) }
            ToggleRow(title: L("Pause widgets while CoolDock is hidden"), isOn: setting(\.pauseWhenHidden))
        }
        SettingsGroup(title: L("Rendering")) {
            ToggleRow(title: L("Reduce transparency"), subtitle: L("Solid fills instead of live blur."), isOn: setting(\.reduceTransparency))
            ToggleRow(title: L("Animations"), isOn: setting(\.animations))
        }
        SettingsGroup(title: L("Caches")) {
            SettingsRow(title: L("Clear cached data"), subtitle: L("Weather, quotes, favicons and thumbnails are re-downloaded when needed.")) {
                Button(L("Clear Cache")) { DiskCache.clear(); IconCache.purge(); URLCache.shared.removeAllCachedResponses() }
            }
        }
    }
}

struct StatCard: View {
    var title: String
    var value: String
    var symbol: String
    var tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.ui(11.5, .medium)).foregroundStyle(tint)
            Text(value).font(.dock(22, .bold, mono: true))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

/// CPU usage of this process (fraction of one core) between samples.
@MainActor
final class ProcessCPU {
    static let shared = ProcessCPU()
    private var last: (cpu: Double, wall: TimeInterval)?

    func sample() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        let wall = ProcessInfo.processInfo.systemUptime
        defer { last = (cpu, wall) }
        guard let last, wall > last.wall else { return 0 }
        return max(0, (cpu - last.cpu) / (wall - last.wall))
    }
}

// MARK: - About

struct AboutPane: View {
    var body: some View {
        let info = Bundle.main.infoDictionary ?? [:]
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text(verbatim: "CoolDock").font(.ui(26, .bold))
            Text(L("Your smart second Dock")).font(.ui(14)).foregroundStyle(.secondary)
            Text(L("Version %@ (%@)", info["CFBundleShortVersionString"] as? String ?? "1.0", info["CFBundleVersion"] as? String ?? "1"))
                .font(.ui(12)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button(L("Widgets…")) { WidgetBrowser.show() }
                Button(L("Show Onboarding")) { OnboardingWindow.show() }
                Button(L("Export Diagnostics…")) { Diagnostics.export() }
            }
            .padding(.top, 6)
            Divider().padding(.vertical, 10)
            VStack(spacing: 6) {
                Text(L("Inspired by cooldock.app. Built natively with Swift and SwiftUI.")).font(.ui(11.5)).foregroundStyle(.secondary)
                Text(L("Persian typeface: Estedad by Amin Abedi — SIL Open Font License 1.1.")).font(.ui(11.5)).foregroundStyle(.secondary)
                Text(L("Weather data: Open-Meteo. Currency rates: Frankfurter.")).font(.ui(11.5)).foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 20)
    }
}

// MARK: - File pickers

@MainActor
enum FilePickers {
    static func folder(start: String? = nil) -> URL? {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.canCreateDirectories = true
        if let start { p.directoryURL = URL(fileURLWithPath: (start as NSString).expandingTildeInPath) }
        NSApp.activate(ignoringOtherApps: true)
        return p.runModal() == .OK ? p.url : nil
    }

    static func apps(multiple: Bool) -> [URL] {
        let p = NSOpenPanel()
        p.canChooseDirectories = false
        p.canChooseFiles = true
        p.allowsMultipleSelection = multiple
        p.allowedContentTypes = [.applicationBundle]
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        NSApp.activate(ignoringOtherApps: true)
        return p.runModal() == .OK ? p.urls : []
    }
}
