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

    @MainActor private static var icons: [String: (image: NSImage, scale: CGFloat)] = [:]

    /// App icon as the reference frames show it, never the system-styled icon, so renders don't depend on this
    /// Mac's icon appearance or light/dark mode: the frame's own asset when there is one (full-bleed artwork,
    /// drawn at the icon grid's 81.5 % content size), else the bundle's flat .icns artwork. Finder's frame uses
    /// the classic artwork that CoreTypes still ships.
    @MainActor static func icon(_ path: String) -> (image: NSImage, scale: CGFloat)? {
        if let cached = icons[path] { return cached }
        let name = (path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "").lowercased()
        var found: (NSImage, CGFloat)?
        if let asset = ReferenceScene.asset("app-\(name)-72.webp") {
            found = (asset, 0.815)
        } else if name == "finder", let classic = NSImage(contentsOfFile: "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/FinderIcon.icns") {
            found = (classic, 1)
        } else if let bundle = Bundle(path: path), let file = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String {
            let icns = file.hasSuffix(".icns") ? file : file + ".icns"
            found = bundle.url(forResource: icns, withExtension: nil).flatMap(NSImage.init(contentsOf:)).map { ($0, 1) }
        }
        if let found { icons[path] = found }
        return found
    }
}
