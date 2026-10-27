import AppKit
import AVFoundation
import Contacts
import CoreLocation
import EventKit
import Photos
import SwiftUI

// MARK: - Profiles

struct ProfilesPane: View {
    @State private var editing: UUID?
    private var store: AppStore { .shared }
    static let symbols = DockProfile.symbolChoices

    var body: some View {
        PaneHeader(pane: .profiles, subtitle: L("Named Dock layouts for different workflows. Each keeps its own widgets and order. Up to eight."))
        SettingsGroup(title: L("Profiles")) {
            ForEach(Array(store.profiles.enumerated()), id: \.element.id) { i, p in
                HStack(spacing: 10) {
                    Menu {
                        ForEach(Self.symbols, id: \.self) { sym in
                            Button { rename(p.id) { $0.symbol = sym } } label: { Label(sym, systemImage: sym) }
                        }
                    } label: {
                        SettingsIcon(symbol: p.symbol, tint: p.id == store.activeProfileID ? .accentColor : .cdGray, size: 26)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()

                    TextField(L("Name"), text: Binding(get: { p.name }, set: { v in rename(p.id) { $0.name = String(v.prefix(24)) } }))
                        .textFieldStyle(.plain).font(.ui(13, .medium))
                    Text(L("%d widgets", p.widgets.count)).font(.ui(11)).foregroundStyle(.secondary)
                    if p.id == store.activeProfileID {
                        Text(L("Active")).font(.ui(10, .semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15))).foregroundStyle(Color.accentColor)
                    } else {
                        Button(L("Switch")) { store.switchProfile(to: i) }.controlSize(.small)
                    }
                    Menu {
                        Button(L("Duplicate")) { store.newProfile(duplicating: p) }.disabled(store.profiles.count >= 8)
                        Button(L("Move Up")) { move(i, -1) }.disabled(i == 0)
                        Button(L("Move Down")) { move(i, 1) }.disabled(i == store.profiles.count - 1)
                        Divider()
                        Button(L("Delete"), role: .destructive) { store.deleteProfile(p.id) }.disabled(store.profiles.count <= 1)
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
                }
            }
        }
        HStack {
            Button { store.newProfile() } label: { Label(L("New Profile"), systemImage: "plus") }.disabled(store.profiles.count >= 8)
            Spacer()
        }
        .padding(.bottom, 20)
        SettingsGroup(title: L("Switching")) {
            ToggleRow(title: L("Show profile switcher on hover"), subtitle: L("Turn off to use the Dock's right-click Switch Profile menu instead."), isOn: setting(\.showProfileSwitcher))
            ToggleRow(title: L("Drag to switch profiles"), subtitle: L("Swipe horizontally across the Dock."), isOn: setting(\.dragToSwitchProfiles))
        }
    }

    private func rename(_ id: UUID, _ f: (inout DockProfile) -> Void) {
        if let i = store.profiles.firstIndex(where: { $0.id == id }) { f(&store.profiles[i]) }
    }

    private func move(_ i: Int, _ d: Int) {
        let j = i + d
        guard store.profiles.indices.contains(j) else { return }
        store.profiles.swapAt(i, j)
        HotKeys.shared.install()
    }
}

// MARK: - Widgets (active profile manager)

struct WidgetsPane: View {
    private var store: AppStore { .shared }

    var body: some View {
        let profile = store.activeProfile
        PaneHeader(pane: .widgets, subtitle: L("Manage the widgets of the active profile. Drag to reorder, or ⌘-drag directly in the Dock."))
        HStack {
            Picker(L("Profile"), selection: Binding(get: { store.activeProfileID }, set: { id in if let i = store.profiles.firstIndex(where: { $0.id == id }) { store.switchProfile(to: i) } })) {
                ForEach(store.profiles) { Label($0.name, systemImage: $0.symbol).tag($0.id) }
            }
            .frame(width: 240)
            Spacer()
            Button { WidgetBrowser.show() } label: { Label(L("Add Widgets…"), systemImage: "plus") }
                .buttonStyle(.borderedProminent)
        }
        .padding(.bottom, 12)

        if profile.widgets.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "square.dashed").font(.system(size: 36)).foregroundStyle(.secondary)
                Text(L("This profile has no widgets yet.")).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 160)
        } else {
            List {
                ForEach(profile.widgets) { w in
                    WidgetManagerRow(instance: w)
                }
                .onMove { from, to in store.updateActive { $0.widgets.move(fromOffsets: from, toOffset: to) } }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .frame(minHeight: CGFloat(min(profile.widgets.count, 9)) * 44 + 12)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        }
    }
}

struct WidgetManagerRow: View {
    let instance: WidgetInstance
    private var store: AppStore { .shared }

    var body: some View {
        let spec = instance.kind.spec
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
            SettingsIcon(symbol: spec.symbol, tint: spec.category.tint, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(rowTitle(spec)).font(.ui(13, .medium))
                Text(spec.category.title + (instance.visibility == .always ? "" : " · " + instance.visibility.title))
                    .font(.ui(11)).foregroundStyle(.secondary)
            }
            Spacer()
            if spec.visibility.count > 0 {
                Picker("", selection: Binding(get: { instance.visibility }, set: { v in store.updateWidget(instance.id) { $0.visibility = v } })) {
                    ForEach([VisibilityRule.always] + spec.visibility) { Text($0.title).tag($0) }
                }
                .labelsHidden().frame(width: 170).controlSize(.small)
            }
            if !spec.fields.isEmpty {
                Button(L("Customize…")) { WidgetSetup.customize(instance) }.controlSize(.small)
            }
            Button(role: .destructive) { store.removeWidget(instance.id) } label: { Image(systemName: "minus.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(Color.cdRed)
                .help(L("Remove"))
        }
        .padding(.vertical, 3)
    }

    private func rowTitle(_ spec: WidgetSpec) -> String {
        switch instance.kind {
        case .app:
            let path = instance.string("path")
            return path.isEmpty ? spec.localizedTitle : FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
        case .folder, .dropbox:
            let path = instance.string("path")
            return path.isEmpty ? spec.localizedTitle : FileManager.default.displayName(atPath: (path as NSString).expandingTildeInPath)
        case .appFolder: return instance.string("name", spec.localizedTitle)
        default: return spec.localizedTitle
        }
    }
}

// MARK: - Privacy

struct PrivacyPane: View {
    @State private var refresh = 0
    @State private var axTrusted = AXIsProcessTrusted()
    private var store: AppStore { .shared }

    var body: some View {
        PaneHeader(pane: .privacy, subtitle: L("CoolDock is local-first. It only asks for a permission when a widget needs it."))
        SettingsGroup(title: L("Permissions")) {
            PermissionRow(title: L("Calendars"), detail: L("Events, agendas and meetings"), symbol: "calendar", tint: .cdRed,
                          status: Self.ekStatus(.event)) { Task { await CalendarService.shared.requestEvents(); refresh += 1 } }
            PermissionRow(title: L("Reminders"), detail: L("Reminders widget"), symbol: "checklist", tint: .cdOrange,
                          status: Self.ekStatus(.reminder)) { Task { await CalendarService.shared.requestReminders(); refresh += 1 } }
            PermissionRow(title: L("Contacts"), detail: L("Quick Contacts"), symbol: "person.crop.circle", tint: .cdGray,
                          status: Self.contactsStatus()) { CNContactStore().requestAccess(for: .contacts) { _, _ in DispatchQueue.main.async { refresh += 1 } } }
            PermissionRow(title: L("Location"), detail: L("Local weather"), symbol: "location.fill", tint: .cdBlue,
                          status: Self.locationStatus()) { Task { await WeatherService.shared.ensure("", force: true); refresh += 1 } }
            PermissionRow(title: L("Photos"), detail: L("Recent Photo"), symbol: "photo", tint: .cdYellow,
                          status: Self.photosStatus()) { PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in DispatchQueue.main.async { refresh += 1 } } }
            PermissionRow(title: L("Microphone"), detail: L("Voice Memo"), symbol: "mic.fill", tint: .cdPink,
                          status: Self.micStatus()) { AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { refresh += 1 } } }
            PermissionRow(title: L("Accessibility"), detail: L("Window previews, keyboard lock and window space"), symbol: "accessibility", tint: .cdBlue,
                          status: axTrusted ? .granted : .notDetermined) {
                let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                axTrusted = AXIsProcessTrustedWithOptions(opts)
            }
            PermissionRow(title: L("Automation"), detail: L("Music, Spotify, Mail, Notes and System Events — asked per app on first use"), symbol: "gearshape.2", tint: .cdIndigo,
                          status: .info) { Open.url("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") }
        }
        .id(refresh)
        CalendarFeedsGroup()
        AIAssistantGroup()
        SettingsGroup(title: L("Credential Storage"), footer: L("Connected widgets store tokens only on this Mac in your login Keychain. CoolDock has no cloud account and never syncs credentials.")) {
            SettingsRow(title: L("macOS Keychain"), subtitle: L("Recommended. Protected by your login keychain."), symbol: "key.fill") {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.cdGreen)
            }
            SettingsRow(title: L("Remove all saved credentials")) {
                Button(L("Remove…"), role: .destructive) {
                    let alert = NSAlert()
                    alert.messageText = L("Remove all saved credentials?")
                    alert.informativeText = L("Connected widgets will ask you to connect again.")
                    alert.addButton(withTitle: L("Remove"))
                    alert.addButton(withTitle: L("Cancel"))
                    if alert.runModal() == .alertFirstButtonReturn { Secrets.wipe() }
                }
            }
        }
    }

    enum PermStatus { case granted, denied, notDetermined, info }

    static func ekStatus(_ type: EKEntityType) -> PermStatus {
        switch EKEventStore.authorizationStatus(for: type) {
        case .fullAccess, .authorized: return .granted
        case .denied, .restricted, .writeOnly: return .denied
        default: return .notDetermined
        }
    }
    static func contactsStatus() -> PermStatus {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        default: return .notDetermined
        }
    }
    static func locationStatus() -> PermStatus {
        switch CLLocationManager().authorizationStatus {
        case .authorizedAlways: return .granted
        case .denied, .restricted: return .denied
        default: return .notDetermined
        }
    }
    static func photosStatus() -> PermStatus {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited: return .granted
        case .denied, .restricted: return .denied
        default: return .notDetermined
        }
    }
    static func micStatus() -> PermStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        default: return .notDetermined
        }
    }
}

struct PermissionRow: View {
    var title: String
    var detail: String
    var symbol: String
    var tint: Color
    var status: PrivacyPane.PermStatus
    var request: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            SettingsIcon(symbol: symbol, tint: tint, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.ui(13, .medium))
                Text(detail).font(.ui(11)).foregroundStyle(.secondary)
            }
            Spacer()
            switch status {
            case .granted:
                Label(L("Allowed"), systemImage: "checkmark.circle.fill").font(.ui(11.5, .medium)).foregroundStyle(Color.cdGreen)
            case .denied:
                Button(L("Open System Settings")) { Open.url("x-apple.systempreferences:com.apple.preference.security?Privacy") }.controlSize(.small)
            case .notDetermined:
                Button(L("Allow…"), action: request).controlSize(.small)
            case .info:
                Button(L("Review"), action: request).controlSize(.small)
            }
        }
    }
}
