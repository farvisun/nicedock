#if DEBUG
import AppKit
import ApplicationServices

/// Accessibility on NiceDock's own windows, for `--ui-probe`. A process needs no Accessibility permission for its own
/// pid: reading the tree, pressing, and setting values all work untrusted. Every call goes through the same
/// `AXUIElement` API a screen reader or UI-scripting tool would use; nothing here reaches into SwiftUI or the models.
@MainActor
enum ProbeAX {
    static let pid = ProcessInfo.processInfo.processIdentifier

    static let app: AXUIElement = {
        let a = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        AXUIElementSetMessagingTimeout(a, 3)
        return a
    }()

    // MARK: Attributes

    static func raw(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func string(_ el: AXUIElement, _ name: String) -> String? {
        guard let s = raw(el, name) as? String, !s.isEmpty else { return nil }
        return s
    }

    static func role(_ el: AXUIElement) -> String { string(el, kAXRoleAttribute) ?? "" }
    static func subrole(_ el: AXUIElement) -> String? { string(el, kAXSubroleAttribute) }
    static func title(_ el: AXUIElement) -> String? { string(el, kAXTitleAttribute) }
    static func desc(_ el: AXUIElement) -> String? { string(el, kAXDescriptionAttribute) }
    static func help(_ el: AXUIElement) -> String? { string(el, kAXHelpAttribute) }
    static func identifier(_ el: AXUIElement) -> String? { string(el, kAXIdentifierAttribute) }
    static func enabled(_ el: AXUIElement) -> Bool { (raw(el, kAXEnabledAttribute) as? Bool) ?? true }
    static func selected(_ el: AXUIElement) -> Bool? { raw(el, kAXSelectedAttribute) as? Bool }

    /// AXValue as a plain value: String, number (Double), or nil.
    static func value(_ el: AXUIElement) -> Any? {
        guard let v = raw(el, kAXValueAttribute) else { return nil }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.doubleValue }
        return nil
    }

    static func stringValue(_ el: AXUIElement) -> String? { value(el) as? String }
    static func number(_ el: AXUIElement) -> Double? { value(el) as? Double }

    static func children(_ el: AXUIElement) -> [AXUIElement] {
        (raw(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    static func parent(_ el: AXUIElement) -> AXUIElement? {
        guard let v = raw(el, kAXParentAttribute), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    /// Frame in screen coordinates, top-left origin (as Accessibility reports it).
    static func frame(_ el: AXUIElement) -> CGRect? { UtilAX.frame(el) }

    static func actions(_ el: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(el, &names) == .success, let list = names as? [String] else { return [] }
        return list
    }

    static func settable(_ el: AXUIElement, _ name: String) -> Bool {
        var ok: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(el, name as CFString, &ok) == .success && ok.boolValue
    }

    /// What a person would read on the element: title, description, value or help, in that order.
    static func label(_ el: AXUIElement) -> String {
        title(el) ?? desc(el) ?? stringValue(el) ?? help(el) ?? ""
    }

    // MARK: Actions

    @discardableResult
    static func perform(_ el: AXUIElement, _ action: String = kAXPressAction) -> AXError {
        AXUIElementPerformAction(el, action as CFString)
    }

    @discardableResult
    static func press(_ el: AXUIElement) -> Bool { perform(el) == .success }

    @discardableResult
    static func set(_ el: AXUIElement, _ name: String, _ value: CFTypeRef) -> AXError {
        AXUIElementSetAttributeValue(el, name as CFString, value)
    }

    // MARK: Tree

    /// Pre-order walk (reading order) under `root`, root excluded.
    static func descendants(_ root: AXUIElement, maxDepth: Int = 40) -> [AXUIElement] {
        var out: [AXUIElement] = []
        func walk(_ el: AXUIElement, _ depth: Int) {
            guard depth < maxDepth else { return }
            for c in children(el) {
                out.append(c)
                walk(c, depth + 1)
            }
        }
        walk(root, 0)
        return out
    }

    static func windows() -> [AXUIElement] { (raw(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] }

    /// The Accessibility element of one of this process's windows (matched by window number).
    static func window(of w: NSWindow) -> AXUIElement? {
        let id = CGWindowID(w.windowNumber)
        if let match = windows().first(where: { UtilAX.windowID($0) == id }) { return match }
        // Panels that are not listed under AXWindows: hit-test the middle of the window.
        let f = w.frame
        guard let primary = NSScreen.screens.first else { return nil }
        let point = CGPoint(x: f.midX, y: primary.frame.maxY - f.midY)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success, var el = hit else { return nil }
        while role(el) != kAXWindowRole, let p = parent(el) { el = p }
        return role(el) == kAXWindowRole ? el : nil
    }

    // MARK: Description (JSON)

    static func describe(_ el: AXUIElement) -> [String: Any] {
        var d: [String: Any] = ["role": role(el)]
        if let s = subrole(el) { d["subrole"] = s }
        if let s = title(el) { d["title"] = s }
        if let s = desc(el) { d["description"] = s }
        if let s = help(el) { d["help"] = s }
        if let s = identifier(el) { d["identifier"] = s }
        if let v = value(el) { d["value"] = v }
        if !enabled(el) { d["enabled"] = false }
        if let f = frame(el) { d["frame"] = [Int(f.minX), Int(f.minY), Int(f.width), Int(f.height)] }
        let acts = actions(el).filter { $0 != "AXShowMenu" && $0 != "AXScrollToVisible" }
        if !acts.isEmpty { d["actions"] = acts }
        return d
    }

    static func dump(_ el: AXUIElement, depth: Int = 0, maxDepth: Int = 40) -> [String: Any] {
        var d = describe(el)
        if depth < maxDepth {
            let kids = children(el).map { dump($0, depth: depth + 1, maxDepth: maxDepth) }
            if !kids.isEmpty { d["children"] = kids }
        }
        return d
    }
}
#endif
