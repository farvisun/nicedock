import AppKit
import ApplicationServices
import SwiftUI

// Notification badges of running apps, read from the macOS Dock's accessibility tree (each Dock item's
// `AXStatusLabel` is the app's `NSDockTile.badgeLabel`). No private API; it needs Accessibility, and without it the
// tiles simply show no badges — nothing ever prompts.

// MARK: - Label formatting

enum AppsBadgeLabel {
    /// Dock-style badge text from an app's raw label: plain counts get grouping ("1,234") and turn compact from
    /// 10,000 ("12K"); anything else ("99+", "!", "New") is shown as the app wrote it, with native digits.
    /// Empty and "0" labels mean no badge.
    static func format(_ raw: String?, number: (Int) -> String = Fmt.int, compact: (Double) -> String = Fmt.compact,
                       digits: (String) -> String = Fmt.digits) -> String? {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if let n = count(text) {
            guard n > 0 else { return nil }
            return n >= 10_000 ? compact(Double(n)) : number(n)
        }
        let capped = text.count > 9 ? String(text.prefix(8)) + "…" : text
        return digits(capped)
    }

    /// The number in a label made only of digits (ASCII, Persian or Arabic-Indic) and grouping marks.
    static func count(_ text: String) -> Int? {
        var value = 0
        var sawDigit = false
        for scalar in text.unicodeScalars {
            let v = scalar.value
            let digit: UInt32?
            switch v {
            case 48...57: digit = v - 48
            case 0x06F0...0x06F9: digit = v - 0x06F0
            case 0x0660...0x0669: digit = v - 0x0660
            default: digit = nil
            }
            if let digit {
                sawDigit = true
                guard value < Int.max / 10 else { return nil }
                value = value * 10 + Int(digit)
            } else if !",.'\u{066C}\u{060C}\u{00A0}\u{202F} ".unicodeScalars.contains(scalar) {
                return nil
            }
        }
        return sawDigit ? value : nil
    }
}

// MARK: - Dock badge service

@Observable
@MainActor
final class AppsDockBadges: DemandDriven {
    static let shared = AppsDockBadges()
    /// Raw badge label per app bundle path (standardized).
    private(set) var labels: [String: String] = [:]
    @ObservationIgnored private var subscribers = Set<String>()
    @ObservationIgnored private var timer: DispatchSourceTimer?
    @ObservationIgnored private let queue = DispatchQueue(label: "app.cooldock.dock-badges", qos: .utility)
    @ObservationIgnored private var seeded: [String: String]?

    func subscribe(_ id: String) {
        guard !AppsEnv.rendering else { return }
        subscribers.insert(id)
        if timer == nil { start() }
    }

    func unsubscribe(_ id: String) {
        subscribers.remove(id)
        if subscribers.isEmpty {
            timer?.cancel()
            timer = nil
        }
    }

    /// Formatted badge for the app at `path`, nil when it has none.
    func badge(_ path: String?) -> String? {
        guard let path else { return nil }
        let key = Self.key(path)
        return AppsBadgeLabel.format(seeded?[key] ?? labels[key])
    }

    /// Deterministic labels for `--scene reference` renders only.
    func seedReference(_ raw: [String: String]) {
        guard ReferenceScene.isActive else { return }
        seeded = Dictionary(uniqueKeysWithValues: raw.map { (Self.key($0.key), $0.value) })
    }

    nonisolated static func key(_ path: String) -> String {
        var p = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    private func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 2.0, leeway: .milliseconds(500))
        t.setEventHandler {
            let fresh = AppsDockBadges.read() ?? [:]
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if AppsDockBadges.shared.labels != fresh { AppsDockBadges.shared.labels = fresh }
                }
            }
        }
        t.resume()
        timer = t
    }

    /// Dock ▸ AXList ▸ application items: `AXURL` (the app) → `AXStatusLabel`. Nil without Accessibility.
    nonisolated static func read() -> [String: String]? {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        return labels(in: AppsAX.app(dock.processIdentifier, timeout: 0.5))
    }

    /// Badge labels of the item lists directly under `app` (the Dock's application element), by app path. No trust
    /// check: `read()` makes it; an element that refuses Accessibility simply yields no labels.
    nonisolated static func labels(in app: AXUIElement) -> [String: String] {
        let attrs = ["AXStatusLabel", kAXURLAttribute] as CFArray
        var out: [String: String] = [:]
        for list in AppsAX.elements(app, kAXChildrenAttribute) where AppsAX.string(list, kAXRoleAttribute) == kAXListRole {
            for item in AppsAX.elements(list, kAXChildrenAttribute) {
                // One round trip per item; items without a badge report an AXError value for the label.
                var raw: CFArray?
                guard AXUIElementCopyMultipleAttributeValues(item, attrs, AXCopyMultipleAttributeOptions(rawValue: 0), &raw) == .success,
                      let values = raw as? [AnyObject], values.count == 2,
                      let label = values[0] as? String, !label.isEmpty,
                      CFGetTypeID(values[1]) == CFURLGetTypeID() else { continue }
                out[key((values[1] as! URL).path)] = label
            }
        }
        return out
    }
}

// MARK: - View

/// Red Dock badge for an app icon's top trailing corner.
struct AppsDockBadge: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    var text: String

    var body: some View {
        Text(verbatim: text)
            .font(.dock(m.u(11), .semibold, mono: true))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(p.monochrome ? (p.isLight ? Color.white : Color.black) : Color.white)
            .padding(.horizontal, m.u(5))
            .frame(minWidth: m.u(19), minHeight: m.u(19))
            .background(Capsule().fill(p.monochrome ? p.primary : Color.cdRed))
            .shadow(color: .black.opacity(0.25), radius: m.u(1), y: m.u(0.5))
    }
}

extension View {
    /// Overlays the app's Dock badge (when it has one) on an app icon.
    func appsBadge(_ text: String?) -> some View {
        overlay(alignment: .topTrailing) {
            if let text { AppsBadgeOverlay(text: text) }
        }
    }
}

private struct AppsBadgeOverlay: View {
    @Environment(\.metrics) private var m
    var text: String

    var body: some View {
        AppsDockBadge(text: text)
            .alignmentGuide(.top) { d in d[.top] + m.u(3) }
            .alignmentGuide(.trailing) { d in d[.trailing] - m.u(4) }
            .allowsHitTesting(false)
    }
}
