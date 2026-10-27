import AppKit

/// Reference-scene data for this family (see `ReferenceScene`). Returns nil for kinds it doesn't own.
enum AppsScene {
    @MainActor static func prepare(_ kind: WidgetKind, _ variant: String?) -> [String: String]? {
        switch kind {
        case .appFolder:
            return ["apps": ["/System/Library/CoreServices/Finder.app", "/System/Applications/Music.app",
                             "/System/Applications/Photos.app", "/System/Applications/Mail.app"].joined(separator: "\n")]
        case .appSwitcher, .downloads, .findFiles:
            return [:]
        default:
            return nil
        }
    }

    @MainActor private static var icons: [String: NSImage] = [:]

    /// App icon as the reference frames show it: the bundle's own flat .icns artwork, never the system-styled
    /// icon, so renders don't depend on this Mac's icon appearance or light/dark mode.
    @MainActor static func icon(_ path: String) -> NSImage? {
        if let cached = icons[path] { return cached }
        var image: NSImage?
        if let bundle = Bundle(path: path), let file = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String {
            let icns = file.hasSuffix(".icns") ? file : file + ".icns"
            image = bundle.url(forResource: icns, withExtension: nil).flatMap(NSImage.init(contentsOf:))
        }
        icons[path] = image
        return image
    }
}
