import AppKit
import SwiftUI

// Settings sections for the system-level options: Layout → Windows / Dock Space and Privacy → Credential Storage.
// Both take optional overrides so the evidence renders (Tests/CoolDockTests/SystemSettingsRenderTests.swift) can show
// every state without Accessibility trust or a real credential store.

// MARK: - Layout → Windows / Dock Space

struct WindowSettingsSection: View {
    /// Accessibility trust to show instead of the live value (renders only).
    var trustOverride: Bool? = nil
    @State private var trusted = AXIsProcessTrusted()
    private var store: AppStore { .shared }

    var body: some View {
        let s = store.settings
        let ax = trustOverride ?? trusted
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup(title: L("Windows")) {
                ToggleRow(title: L("Hide on Window Hover"),
                          subtitle: L("Fade CoolDock on a display while another app's window overlaps it. Clicks reach the window; rest the pointer on the Dock to bring it back."),
                          isOn: setting(\.hideOnWindowHover))
                ToggleRow(title: L("Hide During Fullscreen"), subtitle: L("Hide CoolDock on a display while an app or video is fullscreen."), isOn: setting(\.hideDuringFullscreen))
            }
            SettingsGroup(title: L("Dock Space"), footer: footer(s)) {
                ToggleRow(title: L("Reserve Dock Space"),
                          subtitle: L("Windows that open, zoom, tile or restore end at the Dock's edge instead of covering it."),
                          isOn: setting(\.reservesDockSpace))
                    .disabled(!ax)
                ToggleRow(title: L("Also After Dragging"),
                          subtitle: L("Also move windows you drag or resize over the Dock."),
                          isOn: setting(\.reservesAfterDragging))
                    .disabled(!ax || !s.reservesDockSpace)
                if !ax {
                    SettingsNoticeRow(title: L("Needs Accessibility access"),
                                      detail: L("Only used to read and set the position and size of other apps' windows.")) {
                        Button(L("Allow Accessibility…")) { Self.requestAccess() }
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in trusted = AXIsProcessTrusted() }
        .onReceive(DistributedNotificationCenter.default().publisher(for: Notification.Name("com.apple.accessibility.api"))) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { trusted = AXIsProcessTrusted() }
        }
    }

    private func footer(_ s: Settings) -> String {
        var lines = [L("macOS doesn't let apps change the usable screen area, so CoolDock moves other apps' windows with Accessibility. Panels, dialogs, minimized and fullscreen windows are left alone.")]
        if s.scenario.isReveal { lines.append(L("Not used while CoolDock auto-hides in this layout.")) }
        if s.screensMode == .all { lines.append(L("Each display keeps room for its own Dock.")) }
        return lines.joined(separator: "\n")
    }

    nonisolated(unsafe) private static var prompted = false

    /// Only on the user's click. The first click shows the system prompt (which also adds CoolDock to Privacy & Security
    /// → Accessibility); later clicks open that list directly, since a dismissed prompt may not come back.
    static func requestAccess() {
        guard !AXIsProcessTrusted() else { return }
        if prompted {
            Open.url("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        } else {
            prompted = true
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
    }
}

// MARK: - Privacy → Credential Storage

struct CredentialStorageGroup: View {
    /// State to show instead of the live store (renders only).
    var statusOverride: CredentialStatus? = nil
    @State private var status = Secrets.status()

    var body: some View {
        let st = statusOverride ?? status
        SettingsGroup(title: L("Credential Storage"), footer: footer(st)) {
            CredentialBackendRow(title: L("macOS Keychain"), detail: L("Protected by your login keychain."), symbol: "key.fill", tint: .cdGray,
                                 recommended: true, selected: st.backend == .keychain) { choose(.keychain) }
            CredentialBackendRow(title: L("Encrypted File"),
                                 detail: L("AES-256-GCM file tied to this Mac, for Macs where the login Keychain can't be unlocked reliably."),
                                 symbol: "lock.doc.fill", tint: .cdIndigo, recommended: false, selected: st.backend == .encryptedFile) { choose(.encryptedFile) }
            if st.backend == .encryptedFile { fileRow(st) }
            SettingsRow(title: L("Remove all saved credentials")) {
                Button(L("Remove…"), role: .destructive) { removeAll() }
            }
        }
        .onAppear { if statusOverride == nil { status = Secrets.status() } }
    }

    @ViewBuilder private func fileRow(_ st: CredentialStatus) -> some View {
        switch st.file {
        case .ready(let count):
            SettingsRow(title: L("Credential file"), subtitle: Self.isolatePath(st.filePath) + " · " + L("%d saved", count), symbol: "doc") {
                Button(L("Show in Finder")) { reveal(st.filePath) }
            }
        case .none:
            SettingsRow(title: L("Credential file"), subtitle: L("Created when you connect a widget."), symbol: "doc") { EmptyView() }
        case .unreadable(let error):
            SettingsNoticeRow(title: L("Can't read the credential file"),
                              detail: error.message + " " + L("After a reset, connect those widgets again.")) {
                Button(L("Reset File…"), role: .destructive) { resetFile() }
            }
        }
    }

    private func footer(_ st: CredentialStatus) -> String {
        var lines = [L("Connected widgets store tokens only on this Mac. CoolDock has no cloud account and never syncs credentials.")]
        if st.backend == .encryptedFile {
            lines.append(L("The encrypted file can't be read if it is copied off this Mac, but apps and people using your macOS account can decrypt it. The Keychain is the stronger option."))
        }
        return lines.joined(separator: "\n")
    }

    /// Paths stay left-to-right inside Persian and Arabic text.
    static func isolatePath(_ path: String) -> String {
        AppStore.shared.layoutDirection == .rightToLeft ? "\u{2066}" + path + "\u{2069}" : path
    }

    // MARK: Actions

    private func choose(_ target: CredentialBackend) {
        guard target != Secrets.backend else { return }
        let alert = NSAlert()
        if target == .encryptedFile {
            alert.messageText = L("Store credentials in an encrypted file?")
            alert.informativeText = L("CoolDock moves your saved tokens out of the Keychain into an encrypted file tied to this Mac. Use this only if the login Keychain keeps asking for its password or fails to unlock.")
        } else {
            alert.messageText = L("Move credentials back to the Keychain?")
            alert.informativeText = L("CoolDock moves your saved tokens from the encrypted file into your login Keychain and deletes the file.")
        }
        alert.addButton(withTitle: L("Move Credentials"))
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let result = try Secrets.switchBackend(to: target)
            if !result.unreadable.isEmpty {
                let note = NSAlert()
                note.messageText = L("%d credentials couldn't be moved", result.unreadable.count)
                note.informativeText = L("They couldn't be read from the old storage. Connect those widgets again.")
                note.runModal()
            }
        } catch {
            let fail = NSAlert()
            fail.alertStyle = .warning
            fail.messageText = L("Credentials weren't moved")
            fail.informativeText = (error as? CredentialError)?.message ?? error.localizedDescription
            fail.runModal()
        }
        status = Secrets.status()
    }

    private func removeAll() {
        let alert = NSAlert()
        alert.messageText = L("Remove all saved credentials?")
        alert.informativeText = L("Connected widgets will ask you to connect again.")
        alert.addButton(withTitle: L("Remove"))
        alert.addButton(withTitle: L("Cancel"))
        if alert.runModal() == .alertFirstButtonReturn { Secrets.wipe() }
        status = Secrets.status()
    }

    private func resetFile() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Reset the encrypted credential file?")
        alert.informativeText = L("The unreadable file is renamed and kept next to the new one. Connected widgets will ask you to connect again.")
        alert.addButton(withTitle: L("Reset"))
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try Secrets.resetEncryptedFile() } catch {
            let fail = NSAlert()
            fail.messageText = (error as? CredentialError)?.message ?? error.localizedDescription
            fail.runModal()
        }
        status = Secrets.status()
    }

    private func reveal(_ path: String) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

struct CredentialBackendRow: View {
    var title: String
    var detail: String
    var symbol: String
    var tint: Color
    var recommended: Bool
    var selected: Bool
    var choose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            SettingsIcon(symbol: symbol, tint: tint, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.ui(13, .medium))
                    if recommended {
                        Text(L("Recommended")).font(.ui(9.5, .bold)).padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.cdGreen.opacity(0.18))).foregroundStyle(Color.cdGreen)
                            .fixedSize()
                    }
                }
                Text(detail).font(.ui(11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            if selected {
                Label(L("In Use"), systemImage: "checkmark.circle.fill").font(.ui(11.5, .medium)).foregroundStyle(Color.cdGreen)
            } else {
                Button(L("Switch…"), action: choose).controlSize(.small)
            }
        }
    }
}

/// A row that needs the user's attention: orange warning glyph, title, explanation and an action.
struct SettingsNoticeRow<Action: View>: View {
    var title: String
    var detail: String
    @ViewBuilder var action: () -> Action

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.cdOrange).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.ui(13, .medium))
                Text(detail).font(.ui(11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            action()
        }
    }
}
