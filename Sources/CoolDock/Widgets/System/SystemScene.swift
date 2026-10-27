import Foundation

/// Reference-scene data for this family (see `ReferenceScene`). Returns nil for kinds it doesn't own.
enum SystemScene {
    @MainActor static func prepare(_ kind: WidgetKind, _ variant: String?) -> [String: String]? {
        nil
    }
}
