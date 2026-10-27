import AppKit
import SwiftUI
import Testing
@testable import CoolDock

/// Evidence renders of the Settings sections added for Reserve Dock Space, Hide on Window Hover and the encrypted
/// credential file, in English and Persian. Opt-in (it opens an offscreen window and switches the app language):
///
///     COOLDOCK_EVIDENCE_DIR=$PWD/docs/verification/system swift test --filter SystemSettingsRender
///
/// The sections take their Accessibility trust and credential state as overrides, so every state renders without
/// permissions, the Keychain or a credential file. Persistence is off: the user's state file is never written.
@Suite(.serialized) struct SystemSettingsRenderTests {
    static let outDir = ProcessInfo.processInfo.environment["COOLDOCK_EVIDENCE_DIR"]

    @MainActor @Test(.enabled(if: outDir != nil)) func renderSections() throws {
        let dir = URL(fileURLWithPath: try #require(Self.outDir))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        AppStore.persistenceEnabled = false
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        DockFonts.registerBundledFonts()
        let store = AppStore.shared
        defer { store.settings.language = .en }

        let path = "~/Library/Application Support/NiceDock/credentials.cdvault"
        for lang in [AppLanguage.en, .fa] {
            var s = Settings()
            s.language = lang
            s.scenario = .fixed
            s.hideOnWindowHover = true
            store.settings = s
            let rtl = lang.isRTL
            let code = lang.rawValue

            // No Accessibility access yet: Reserve Dock Space and Also After Dragging are disabled, with the button.
            try Self.render(WindowSettingsSection(trustOverride: false), "\(code)-layout-windows-no-access", rtl: rtl, in: dir)

            // Access granted, Reserve Dock Space on, All Displays: the per-display footer line appears.
            s.reservesDockSpace = true
            s.screensMode = .all
            store.settings = s
            try Self.render(WindowSettingsSection(trustOverride: true), "\(code)-layout-windows-reserve-on", rtl: rtl, in: dir)

            // An auto-hiding layout: the toggle stays, the footer says it isn't used there.
            s.scenario = .revealBottom
            s.reservesAfterDragging = true
            s.screensMode = .one
            store.settings = s
            try Self.render(WindowSettingsSection(trustOverride: true), "\(code)-layout-windows-autohide", rtl: rtl, in: dir)

            try Self.render(CredentialStorageGroup(statusOverride: CredentialStatus(backend: .keychain, file: .none, filePath: path)),
                            "\(code)-privacy-credentials-keychain", rtl: rtl, in: dir)
            try Self.render(CredentialStorageGroup(statusOverride: CredentialStatus(backend: .encryptedFile, file: .ready(count: 3), filePath: path)),
                            "\(code)-privacy-credentials-file", rtl: rtl, in: dir)
            try Self.render(CredentialStorageGroup(statusOverride: CredentialStatus(backend: .encryptedFile, file: .unreadable(.tampered), filePath: path)),
                            "\(code)-privacy-credentials-unreadable", rtl: rtl, in: dir)
        }
    }

    /// Lays the section out at the Settings detail width (680 pt + 28 pt margins), light appearance, 2× pixels.
    @MainActor static func render<V: View>(_ view: V, _ name: String, rtl: Bool, in dir: URL) throws {
        let root = VStack(alignment: .leading, spacing: 0) { view }
            .frame(width: 680, alignment: .topLeading)
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
            .environment(\.locale, Fmt.locale)
            .environment(\.calendar, Fmt.calendar)
            .font(.ui())
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: .aqua)
        host.userInterfaceLayoutDirection = rtl ? .rightToLeft : .leftToRight
        let size = host.fittingSize
        let window = EvidenceWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()

        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: dir.appendingPathComponent("\(name).png"))
        window.contentView = nil
        window.close()
    }
}

/// Draws controls in their active (key window) look, as in the open Settings window.
private final class EvidenceWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}
