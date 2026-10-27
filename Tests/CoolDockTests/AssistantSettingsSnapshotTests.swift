import AppKit
import SwiftUI
import Testing
@testable import CoolDock

/// Offscreen render of Settings → Privacy & Permissions → AI Assistant in English and Persian (right-to-left,
/// snippets stay left-to-right). Opt-in, because it touches `AppStore.shared`:
///
///     COOLDOCK_SETTINGS_SNAPSHOT=<dir> swift test --filter AssistantSettingsSnapshotTests
///
/// No window is shown and the user's saved state is never read or written (temporary support directory).
@MainActor
@Suite struct AssistantSettingsSnapshotTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["COOLDOCK_SETTINGS_SNAPSHOT"] != nil))
    func renderEnglishAndPersian() throws {
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["COOLDOCK_SETTINGS_SNAPSHOT"]!)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        AppPaths.overrideDirectory = AssistantFixture.tempDirectory()
        AppStore.persistenceEnabled = false
        AssistantSetup.pathOverride = "/Applications/CoolDock.app/Contents/MacOS/CoolDock"
        DockFonts.registerBundledFonts()
        let store = AppStore.shared
        store.settings.assistantEnabled = true
        for lang in [AppLanguage.en, .fa] {
            store.settings.language = lang
            let root = VStack(alignment: .leading, spacing: 0) { AIAssistantGroup() }
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .frame(width: 680)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.layoutDirection, store.layoutDirection)
                .environment(\.locale, Fmt.locale)
            let view = NSHostingView(rootView: root)
            view.appearance = NSAppearance(named: .aqua)
            view.frame = NSRect(origin: .zero, size: view.fittingSize)
            view.layoutSubtreeIfNeeded()
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: out.appendingPathComponent("ai-assistant-\(lang.rawValue).png"))
        }
    }
}
