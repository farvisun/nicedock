import CoreGraphics
import Foundation

// Pure geometry and state for the two window-aware Layout options:
//   • Reserve Dock Space — other apps' windows end at the Dock's edge (`ReserveSpace`).
//   • Hide on Window Hover — the Dock fades while a window overlaps it (`HoverHideMachine`, `HoverHideBoard`).
// Nothing here touches AppKit or Accessibility, so every rule is unit-tested (Tests/CoolDockTests/DockSpaceTests.swift).
//
// Coordinates: global Quartz / Accessibility space — origin at the top-left corner of the primary display (the one with
// the menu bar), y grows downwards. AX window positions and `CGWindowListCopyWindowInfo` bounds use it as-is; AppKit
// rects are converted with `ReserveSpace.quartz(_:primaryHeight:)`.

/// Which edge of its display a dock keeps free.
enum DockEdge: Equatable {
    case bottom, top
}

/// The room one display's NiceDock keeps free.
struct DockReservation: Equatable {
    var displayID: String
    /// Whole display.
    var screen: CGRect
    /// Display minus the menu bar and the macOS Dock (`NSScreen.visibleFrame`).
    var visible: CGRect
    /// The Dock plate.
    var dock: CGRect
    var edge: DockEdge
    /// Space left between a window and the plate.
    var gap: CGFloat

    /// `edge` nil picks the edge nearest to the plate (used for floating docks).
    init(displayID: String, screen: CGRect, visible: CGRect, dock: CGRect, edge: DockEdge? = nil, gap: CGFloat = 6) {
        self.displayID = displayID
        self.screen = screen
        self.visible = visible
        self.dock = dock
        self.edge = edge ?? (dock.midY >= visible.midY ? .bottom : .top)
        self.gap = gap
    }

    /// Windows have to end above (bottom dock) or start below (top dock) this y.
    var limit: CGFloat {
        edge == .bottom ? dock.minY - gap : dock.maxY + gap
    }

    /// The plate plus the gap on its window-facing side: a window touching this area gets moved.
    var keepOut: CGRect {
        edge == .bottom
            ? CGRect(x: dock.minX, y: dock.minY - gap, width: dock.width, height: dock.height + gap)
            : CGRect(x: dock.minX, y: dock.minY, width: dock.width, height: dock.height + gap)
    }
}

enum ReserveSpace {
    /// Windows are never squeezed below this height, even when the app reports no minimum size.
    static let floorHeight: CGFloat = 80
    /// Frames closer than this are treated as equal (AX rounds to whole points, apps snap to pixels).
    static let tolerance: CGFloat = 1

    /// AppKit rect (bottom-left origin, y up) → Quartz / AX rect (top-left origin of the primary display, y down).
    static func quartz(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Quartz / AX point → AppKit point (for the pointer / AX positions).
    static func appKit(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The reservation a window collides with (largest overlap), if any.
    static func reservation(for window: CGRect, in reservations: [DockReservation]) -> DockReservation? {
        var best: (DockReservation, CGFloat)?
        for r in reservations {
            let i = window.intersection(r.keepOut)
            guard !i.isNull, i.width >= tolerance, i.height >= tolerance else { continue }
            let area = i.width * i.height
            if best == nil || area > best!.1 { best = (r, area) }
        }
        return best?.0
    }

    /// New frame for `window` so it leaves room for the dock it overlaps, or nil when it already fits, covers the whole
    /// display (fullscreen) or doesn't touch any dock. A window that fits in the free height is moved and keeps its size;
    /// a taller one keeps its top (never above the menu bar) and is shortened, but not below `minSize.height`.
    static func adjusted(_ window: CGRect, minSize: CGSize = .zero, in reservations: [DockReservation]) -> CGRect? {
        guard let r = reservation(for: window, in: reservations) else { return nil }
        return adjusted(window, minSize: minSize, in: r)
    }

    static func adjusted(_ window: CGRect, minSize: CGSize = .zero, in r: DockReservation) -> CGRect? {
        let i = window.intersection(r.keepOut)
        guard !i.isNull, i.width >= tolerance, i.height >= tolerance else { return nil }
        // Fullscreen-sized windows (own Space or covering the menu bar) are left alone.
        if window.minX <= r.screen.minX + tolerance, window.maxX >= r.screen.maxX - tolerance,
           window.minY <= r.screen.minY + tolerance, window.maxY >= r.screen.maxY - tolerance { return nil }
        let minHeight = max(minSize.height, min(floorHeight, window.height))
        var f = window
        switch r.edge {
        case .bottom:
            let top = r.visible.minY
            let limit = r.limit
            guard window.maxY > limit + tolerance else { return nil }
            if window.height <= limit - top {
                f.origin.y = limit - window.height
            } else {
                let newTop = max(top, min(window.minY, limit - minHeight))
                f.origin.y = newTop
                f.size.height = max(limit - newTop, minHeight)
            }
        case .top:
            let bottom = r.visible.maxY
            let limit = r.limit
            guard window.minY < limit - tolerance else { return nil }
            if window.height <= bottom - limit {
                f.origin.y = limit
            } else {
                let newBottom = min(bottom, max(window.maxY, limit + minHeight))
                f.origin.y = limit
                f.size.height = max(newBottom - limit, minHeight)
            }
        }
        f = f.integral(keepingSize: true)
        return same(f, window) ? nil : f
    }

    static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
}

private extension CGRect {
    /// Rounds the origin and size to whole points (AX setters take points; fractional values make apps fight back).
    func integral(keepingSize: Bool) -> CGRect {
        CGRect(x: minX.rounded(), y: minY.rounded(), width: width.rounded(), height: height.rounded())
    }
}

/// Stops NiceDock from fighting an app that keeps putting its window back: at most `limit` adjustments of one window
/// per `window` seconds, then that window is left alone for `cooldown` seconds.
struct AdjustmentLimiter {
    var limit = 3
    var window: TimeInterval = 4
    var cooldown: TimeInterval = 30
    private var history: [AnyHashable: [TimeInterval]] = [:]
    private var blockedUntil: [AnyHashable: TimeInterval] = [:]

    /// Records an adjustment and returns whether it may happen.
    mutating func allow(_ key: AnyHashable, now: TimeInterval) -> Bool {
        if let until = blockedUntil[key] {
            if now < until { return false }
            blockedUntil[key] = nil
            history[key] = nil
        }
        var recent = (history[key] ?? []).filter { now - $0 < window }
        if recent.count >= limit {
            blockedUntil[key] = now + cooldown
            history[key] = nil
            return false
        }
        recent.append(now)
        history[key] = recent
        return true
    }

    mutating func forget(_ key: AnyHashable) {
        history[key] = nil
        blockedUntil[key] = nil
    }

    mutating func reset() {
        history.removeAll()
        blockedUntil.removeAll()
    }
}

/// How a burst of window notifications came about, which decides whether "Also After Dragging" applies.
struct WindowChangeBurst: Equatable {
    /// A notification arrived while the left mouse button was down: the user is dragging or resizing the window.
    var dragSeen = false
    /// A resize / creation / restore arrived with the button up: the system or the app placed the window
    /// (zoom, tile — including tiling after a drag —, restore, new window, window-manager shortcut).
    var automatic = false
    var created = false

    mutating func record(created isCreated: Bool = false, resized: Bool = false, restored: Bool = false, mouseDown: Bool) {
        if isCreated { created = true }
        if mouseDown {
            dragSeen = true
        } else if isCreated || resized || restored || !dragSeen {
            automatic = true
        }
    }

    /// The user put the window where it is by hand.
    var isManual: Bool { dragSeen && !automatic }

    /// Whether NiceDock may move the window out of the dock area.
    func shouldAdjust(afterDragging: Bool) -> Bool { !isManual || afterDragging }
}

// MARK: - Hide on Window Hover

/// One display's "Hide on Window Hover" state.
///
/// * `shown` — nothing overlaps the Dock (or something holds it open).
/// * `faded` — another app's window overlaps it: the Dock is transparent and clicks pass through to the window.
/// * `peeking` — still overlapped, but the pointer rested on the Dock area, so it is visible and clickable until the
///   pointer has been away for `grace` seconds.
///
/// A click, drag or scroll in the Dock area while faded is meant for the window underneath, so it restarts the
/// `dwell` wait instead of revealing the Dock.
struct HoverHideMachine: Equatable {
    enum Phase: Equatable {
        case shown, faded, peeking
    }

    struct Input: Equatable {
        /// Another app's window overlaps this display's Dock.
        var overlap = false
        /// The pointer is over the Dock plate.
        var pointerInside = false
        /// The current pointer event is a click, drag or scroll (or a button is held).
        var pointerBusy = false
        /// A Dock pop-up, the widget browser or a modal is open, so the Dock must stay.
        var holdOpen = false
    }

    static let dwell: TimeInterval = 0.5
    static let grace: TimeInterval = 0.4

    private(set) var phase: Phase = .shown
    private(set) var restSince: TimeInterval?
    private(set) var awaySince: TimeInterval?

    @discardableResult
    mutating func step(_ input: Input, now: TimeInterval) -> Phase {
        if !input.overlap || input.holdOpen {
            phase = .shown
            restSince = nil
            awaySince = nil
            return phase
        }
        switch phase {
        case .shown:
            // A window just started to overlap. Don't pull the Dock out from under a resting pointer.
            if input.pointerInside && !input.pointerBusy {
                phase = .peeking
                awaySince = nil
            } else {
                phase = .faded
                restSince = nil
            }
        case .faded:
            if input.pointerInside && !input.pointerBusy {
                let since = restSince ?? now
                restSince = since
                if now - since >= Self.dwell {
                    phase = .peeking
                    restSince = nil
                    awaySince = nil
                }
            } else {
                restSince = nil
            }
        case .peeking:
            if input.pointerInside {
                awaySince = nil
            } else {
                let since = awaySince ?? now
                awaySince = since
                if now - since >= Self.grace {
                    phase = .faded
                    awaySince = nil
                    restSince = nil
                }
            }
        }
        return phase
    }

    /// When `step` must run again without a new event (dwell or grace expiry), else nil.
    var deadline: TimeInterval? {
        switch phase {
        case .shown: return nil
        case .faded: return restSince.map { $0 + Self.dwell }
        case .peeking: return awaySince.map { $0 + Self.grace }
        }
    }

    var isFaded: Bool { phase == .faded }
}

/// "Hide on Window Hover" for every display: one independent machine per display id.
struct HoverHideBoard: Equatable {
    private(set) var machines: [String: HoverHideMachine] = [:]

    /// Steps every display present in `inputs`; displays that disappeared are dropped.
    @discardableResult
    mutating func step(_ inputs: [String: HoverHideMachine.Input], now: TimeInterval) -> [String: HoverHideMachine.Phase] {
        var next: [String: HoverHideMachine] = [:]
        var phases: [String: HoverHideMachine.Phase] = [:]
        for (id, input) in inputs {
            var m = machines[id] ?? HoverHideMachine()
            phases[id] = m.step(input, now: now)
            next[id] = m
        }
        machines = next
        return phases
    }

    func phase(_ id: String) -> HoverHideMachine.Phase { machines[id]?.phase ?? .shown }

    /// Earliest dwell / grace expiry across displays.
    var deadline: TimeInterval? { machines.values.compactMap(\.deadline).min() }

    /// Pointer events are only needed while some display is faded or peeking.
    var needsPointerTracking: Bool { machines.values.contains { $0.phase != .shown } }

    mutating func reset() { machines.removeAll() }
}

/// Overlap test used by Hide on Window Hover (Quartz coordinates).
enum WindowOverlap {
    /// Windows smaller than this (tool tips, drag images, tiny utility windows) never hide the Dock.
    static let minimumSide: CGFloat = 40

    static func overlaps(_ window: CGRect, dock: CGRect) -> Bool {
        guard window.width >= minimumSide, window.height >= minimumSide else { return false }
        let i = window.intersection(dock)
        return !i.isNull && i.width >= 2 && i.height >= 2
    }
}
