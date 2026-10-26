import SwiftUI

enum FinanceWidgets {
    @MainActor @ViewBuilder
    static func view(_ w: WidgetInstance) -> some View {
        Tile(width: w.kind.spec.width) { Text(w.kind.spec.localizedTitle).dock(11) }
    }

    @MainActor @ViewBuilder
    static func menu(_ w: WidgetInstance) -> some View {
        EmptyView()
    }
}
