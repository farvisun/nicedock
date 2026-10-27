import CoreGraphics
import SwiftUI

/// Window layouts. Raw values are persisted in the Window Manager's `items` config — never rename.
/// Layouts are geographic: "left half" is the left of the screen in every language.
enum UtilWinAction: String, CaseIterable, Identifiable {
    case leftHalf, rightHalf, topHalf, bottomHalf, maximize, center
    case leftThird, centerThird, rightThird, leftTwoThirds, rightTwoThirds
    case topLeft, topRight, bottomLeft, bottomRight
    case nextDisplay

    var id: String { rawValue }

    var title: String {
        switch self {
        case .leftHalf: return L("Left Half")
        case .rightHalf: return L("Right Half")
        case .topHalf: return L("Top Half")
        case .bottomHalf: return L("Bottom Half")
        case .maximize: return L("Maximize")
        case .center: return L("Center")
        case .leftThird: return L("Left Third")
        case .centerThird: return L("Center Third")
        case .rightThird: return L("Right Third")
        case .leftTwoThirds: return L("Left Two Thirds")
        case .rightTwoThirds: return L("Right Two Thirds")
        case .topLeft: return L("Top Left Quarter")
        case .topRight: return L("Top Right Quarter")
        case .bottomLeft: return L("Bottom Left Quarter")
        case .bottomRight: return L("Bottom Right Quarter")
        case .nextDisplay: return L("Next Display")
        }
    }

    /// Target area as a unit rect with a top-left origin (x right, y down), or nil for actions that keep the size.
    var region: CGRect? {
        let t: CGFloat = 1 / 3
        switch self {
        case .leftHalf: return CGRect(x: 0, y: 0, width: 0.5, height: 1)
        case .rightHalf: return CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        case .topHalf: return CGRect(x: 0, y: 0, width: 1, height: 0.5)
        case .bottomHalf: return CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
        case .maximize: return CGRect(x: 0, y: 0, width: 1, height: 1)
        case .leftThird: return CGRect(x: 0, y: 0, width: t, height: 1)
        case .centerThird: return CGRect(x: t, y: 0, width: t, height: 1)
        case .rightThird: return CGRect(x: 2 * t, y: 0, width: t, height: 1)
        case .leftTwoThirds: return CGRect(x: 0, y: 0, width: 2 * t, height: 1)
        case .rightTwoThirds: return CGRect(x: t, y: 0, width: 2 * t, height: 1)
        case .topLeft: return CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        case .topRight: return CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)
        case .bottomLeft: return CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)
        case .bottomRight: return CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        case .center, .nextDisplay: return nil
        }
    }

    /// Area drawn in the button glyph (top-left unit rect).
    var glyphRegion: CGRect {
        region ?? CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
    }

    var tint: Color {
        switch self {
        case .leftHalf, .rightHalf, .topHalf, .bottomHalf: return .cdBlue
        case .maximize: return .cdGreen
        case .center: return .cdOrange
        case .leftThird, .centerThird, .rightThird, .leftTwoThirds, .rightTwoThirds: return .cdTeal
        case .topLeft, .topRight, .bottomLeft, .bottomRight: return .cdIndigo
        case .nextDisplay: return .cdPurple
        }
    }

    /// Default tile buttons (the panel button is always added after them).
    static let tileDefaults: [UtilWinAction] = [.leftHalf, .rightHalf, .maximize, .center, .nextDisplay]
}

/// One display as the frame math sees it, in Cocoa coordinates (origin bottom-left of the primary display, y up).
struct UtilWinScreen: Equatable {
    /// `NSScreen.frame`.
    var frame: CGRect
    /// Area windows may use: `NSScreen.visibleFrame` (menu bar and macOS Dock removed) minus NiceDock's own dock.
    var usable: CGRect
}

/// Pure frame math for the Window Manager (unit-tested in WindowManagerTests).
enum UtilWinMath {
    /// Accessibility / CoreGraphics window coordinates (origin top-left of the primary display, y down) ⇄ Cocoa.
    /// The conversion is its own inverse.
    static func flip(_ r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    /// `visible` without the strip a docked NiceDock covers at its bottom or top edge.
    static func usable(visible: CGRect, dock: CGRect?) -> CGRect {
        guard let dock, dock.width > 0, dock.height > 0, dock.intersects(visible) else { return visible }
        var r = visible
        if dock.midY < visible.midY {
            let top = min(dock.maxY, visible.maxY)
            r.size.height = visible.maxY - top
            r.origin.y = top
        } else {
            r.size.height = max(0, max(dock.minY, visible.minY) - visible.minY)
        }
        return r.height >= 100 ? r : visible
    }

    /// The display holding most of the window (nearest centre when it is off every display).
    static func screenIndex(for window: CGRect, in screens: [UtilWinScreen]) -> Int? {
        guard !screens.isEmpty else { return nil }
        var best: (index: Int, area: CGFloat)?
        for (i, s) in screens.enumerated() {
            let overlap = s.frame.intersection(window)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > 0, area > (best?.area ?? 0) { best = (i, area) }
        }
        if let best { return best.index }
        let c = CGPoint(x: window.midX, y: window.midY)
        return screens.indices.min { a, b in distance(c, screens[a].frame) < distance(c, screens[b].frame) }
    }

    private static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        hypot(p.x - r.midX, p.y - r.midY)
    }

    /// A unit region (top-left origin) placed in `area`. Edges are rounded independently, so neighbouring regions
    /// (halves, thirds, quarters) share their edges without gaps or overlap.
    static func place(_ unit: CGRect, in area: CGRect) -> CGRect {
        let x0 = (area.minX + unit.minX * area.width).rounded()
        let x1 = (area.minX + unit.maxX * area.width).rounded()
        let top0 = (area.maxY - unit.minY * area.height).rounded()
        let top1 = (area.maxY - unit.maxY * area.height).rounded()
        return CGRect(x: x0, y: top1, width: x1 - x0, height: top0 - top1)
    }

    /// Same size (shrunk to fit), centred in `area`.
    static func centered(_ window: CGRect, in area: CGRect) -> CGRect {
        let w = min(window.width, area.width), h = min(window.height, area.height)
        return CGRect(x: (area.midX - w / 2).rounded(), y: (area.midY - h / 2).rounded(), width: w.rounded(), height: h.rounded())
    }

    /// New frame (Cocoa coordinates) for `action`, or nil when it does not apply (one display for Next Display).
    static func target(_ action: UtilWinAction, window: CGRect, screens: [UtilWinScreen]) -> CGRect? {
        guard let i = screenIndex(for: window, in: screens) else { return nil }
        let area = screens[i].usable
        if let unit = action.region { return place(unit, in: area) }
        switch action {
        case .center: return centered(window, in: area)
        case .nextDisplay: return moved(window, from: i, screens: screens)
        default: return nil
        }
    }

    /// Displays left to right (then bottom to top); Next Display walks this order and wraps around.
    static func displayOrder(_ screens: [UtilWinScreen]) -> [Int] {
        screens.indices.sorted { a, b in
            let fa = screens[a].frame, fb = screens[b].frame
            return fa.minX != fb.minX ? fa.minX < fb.minX : fa.minY < fb.minY
        }
    }

    /// Moves to the next display. A window in a known layout gets the same layout there; any other keeps its size
    /// (shrunk to fit) and its relative position in the free space.
    static func moved(_ window: CGRect, from index: Int, screens: [UtilWinScreen]) -> CGRect? {
        guard screens.count > 1 else { return nil }
        let order = displayOrder(screens)
        guard let pos = order.firstIndex(of: index) else { return nil }
        let src = screens[index].usable, dst = screens[order[(pos + 1) % order.count]].usable
        for action in UtilWinAction.allCases {
            if let unit = action.region, close(place(unit, in: src), window) { return place(unit, in: dst) }
        }
        let w = min(window.width, dst.width), h = min(window.height, dst.height)
        func along(_ offset: CGFloat, _ free: CGFloat, _ newFree: CGFloat) -> CGFloat {
            free > 0 ? max(0, min(1, offset / free)) * newFree : newFree / 2
        }
        let x = dst.minX + along(window.minX - src.minX, src.width - window.width, dst.width - w)
        let y = dst.minY + along(window.minY - src.minY, src.height - window.height, dst.height - h)
        return CGRect(x: x.rounded(), y: y.rounded(), width: w.rounded(), height: h.rounded())
    }

    private static func close(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 3) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    /// "Arrange All": `count` windows side by side (up to three), otherwise a grid filled row by row from the top
    /// left; the last row shares its width among the windows left over. Frontmost window first.
    static func grid(_ count: Int, in area: CGRect) -> [CGRect] {
        guard count > 0 else { return [] }
        let columns = count <= 3 ? count : Int(ceil(Double(count).squareRoot()))
        let rows = Int(ceil(Double(count) / Double(columns)))
        return (0..<count).map { i in
            let row = i / columns
            let inRow = row == rows - 1 ? count - columns * (rows - 1) : columns
            let column = i % columns
            let unit = CGRect(x: CGFloat(column) / CGFloat(inRow), y: CGFloat(row) / CGFloat(rows),
                              width: 1 / CGFloat(inRow), height: 1 / CGFloat(rows))
            return place(unit, in: area)
        }
    }
}

// MARK: - Window list (CGWindowList)

/// One window of another app as listed by CGWindowListCopyWindowInfo (titles need Screen Recording there; with
/// Accessibility they come from the window's AXTitle instead).
struct UtilWinEntry: Identifiable, Equatable {
    var id: CGWindowID
    var pid: pid_t
    var appName: String
    var appPath: String?
    var title: String?
    /// CoreGraphics/Accessibility coordinates (top-left origin).
    var frame: CGRect
    var minimized = false
}

struct UtilWinGroup: Identifiable, Equatable {
    var pid: pid_t
    var appName: String
    var appPath: String?
    var windows: [UtilWinEntry]
    var id: pid_t { pid }
}

enum UtilWinList {
    /// Normal windows of other processes, front to back: layer 0, visible, at least 60×40 pt.
    static func parse(_ infos: [[String: Any]], ownPID: pid_t) -> [UtilWinEntry] {
        infos.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != ownPID,
                  let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let b = info[kCGWindowBounds as String] as? [String: Any] else { return nil }
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            func v(_ k: String) -> CGFloat { CGFloat((b[k] as? NSNumber)?.doubleValue ?? 0) }
            let frame = CGRect(x: v("X"), y: v("Y"), width: v("Width"), height: v("Height"))
            guard alpha > 0.01, frame.width >= 60, frame.height >= 40 else { return nil }
            let name = (info[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return UtilWinEntry(id: number, pid: pid, appName: (info[kCGWindowOwnerName as String] as? String) ?? "",
                                title: name, frame: frame)
        }
    }

    /// Groups by app in z-order of each app's frontmost window.
    static func group(_ entries: [UtilWinEntry]) -> [UtilWinGroup] {
        var order: [pid_t] = []
        var byPID: [pid_t: [UtilWinEntry]] = [:]
        for e in entries {
            if byPID[e.pid] == nil { order.append(e.pid) }
            byPID[e.pid, default: []].append(e)
        }
        return order.compactMap { pid in
            guard let list = byPID[pid], let first = list.first else { return nil }
            return UtilWinGroup(pid: pid, appName: first.appName, appPath: first.appPath, windows: list)
        }
    }
}
