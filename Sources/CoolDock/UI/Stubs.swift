import AppKit
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable { case general, about; var id: String { rawValue } }

@MainActor enum SettingsWindow {
    static func show(pane: SettingsPane = .general) {}
}
@MainActor enum WidgetBrowser {
    static func show() {}
    static func toggle() {}
}
@MainActor enum OnboardingWindow { static func show() {} }
@MainActor enum WidgetSetup {
    static func add(_ kind: WidgetKind) { AppStore.shared.addWidget(kind) }
    static func customize(_ w: WidgetInstance) {}
}
