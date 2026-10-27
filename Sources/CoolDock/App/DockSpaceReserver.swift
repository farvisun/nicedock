import AppKit
import ApplicationServices

/// Reserve Dock Space (Settings → Layout → Dock Space).
///
/// macOS gives third-party apps no way to shrink `NSScreen.visibleFrame`, so NiceDock does what a window manager does:
/// it listens to Accessibility window notifications (`WindowEventHub`) and, when a standard window of another app
/// overlaps a visible NiceDock, moves it up (or down for a top Dock) — or shortens it when it is too tall — so it ends at
/// the Dock's edge. The geometry is `ReserveSpace` (pure, unit-tested).
///
/// Rules: only standard windows (no panels, sheets, dialogs), never minimized or fullscreen ones, never NiceDock's own.
/// Notifications are coalesced (180 ms) and a window being dragged or resized is left alone until the mouse button is
/// released; whether a window the user put there by hand is moved depends on "Also After Dragging". Each display
/// reserves room for its own Dock. An app that keeps putting a window back is left alone after three tries
/// (`AdjustmentLimiter`), so NiceDock never fights it.
@MainActor
final class DockSpaceReserver {
    static let shared = DockSpaceReserver()

    private(set) var isEnabled = false
    private var afterDragging = false
    /// Windows waiting for the debounce, with how their changes came about.
    private var pending: [AXWindowKey: WindowChangeBurst] = [:]
    /// Windows queued by a full pass (not by a notification of their own).
    private var rescanned: Set<AXWindowKey> = []
    /// Windows the user dragged over the Dock while "Also After Dragging" was off.
    private var manual: Set<AXWindowKey> = []
    /// Heights apps refused to go below.
    private var minHeights: [AXWindowKey: CGFloat] = [:]
    private var limiter = AdjustmentLimiter()
    private var flushWork: DispatchWorkItem?
    private var geometryWork: DispatchWorkItem?
    private var lastKeepOut: [CGRect] = []

    /// Reservations of the Docks currently on screen (set by `DockController`).
    var reservations: () -> [DockReservation] = { [] }

    func configure(enabled: Bool, afterDragging: Bool) {
        let on = enabled && !RenderHarness.isActive
        let widened = afterDragging && !self.afterDragging
        self.afterDragging = afterDragging
        if on && !isEnabled {
            isEnabled = true
            WindowEventHub.shared.subscribe("reserve") { event in DockSpaceReserver.shared.handle(event) }
        } else if !on && isEnabled {
            isEnabled = false
            WindowEventHub.shared.unsubscribe("reserve")
            reset()
        } else if on && widened {
            // Windows placed by hand are now in scope too.
            manual.removeAll()
            rescan()
        }
    }

    /// The Dock moved, resized, appeared or hid: windows overlapping the new area are moved once.
    func dockGeometryChanged() {
        guard isEnabled else { return }
        geometryWork?.cancel()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                let me = DockSpaceReserver.shared
                guard me.isEnabled, me.reservations().map(\.keepOut) != me.lastKeepOut else { return }
                me.rescan()
            }
        }
        geometryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func reset() {
        flushWork?.cancel()
        geometryWork?.cancel()
        pending.removeAll()
        rescanned.removeAll()
        manual.removeAll()
        minHeights.removeAll()
        limiter.reset()
        lastKeepOut = []
    }

    // MARK: Events

    private func handle(_ event: WindowEventHub.Event) {
        guard isEnabled else { return }
        if event.kind == .resync {
            rescan()
            return
        }
        guard let window = event.window else { return }
        let key = AXWindowKey(window)
        var burst = pending[key] ?? WindowChangeBurst()
        burst.record(created: event.kind == .created, resized: event.kind == .resized, restored: event.kind == .restored, mouseDown: event.mouseDown)
        pending[key] = burst
        rescanned.remove(key)
        scheduleFlush(after: 0.18)
    }

    private func rescan() {
        lastKeepOut = reservations().map(\.keepOut)
        guard !lastKeepOut.isEmpty else { return }
        for (_, window) in WindowEventHub.shared.allWindows() {
            let key = AXWindowKey(window)
            guard pending[key] == nil else { continue }
            var burst = WindowChangeBurst()
            burst.record(mouseDown: false)
            pending[key] = burst
            rescanned.insert(key)
        }
        scheduleFlush(after: 0.05)
    }

    private func scheduleFlush(after delay: TimeInterval) {
        flushWork?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { DockSpaceReserver.shared.flush() } }
        flushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func flush() {
        flushWork = nil
        guard isEnabled, !pending.isEmpty else { return }
        // Never move a window out from under the pointer: wait until a drag or live resize ends.
        if NSEvent.pressedMouseButtons & 1 != 0, pending.values.contains(where: \.dragSeen) {
            scheduleFlush(after: 0.2)
            return
        }
        let batch = pending
        let fromRescan = rescanned
        pending.removeAll()
        rescanned.removeAll()
        let res = reservations()
        guard !res.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        var created: [AXWindowKey] = []
        for (key, burst) in batch {
            process(key, burst, rescan: fromRescan.contains(key), reservations: res, now: now)
            if burst.created { created.append(key) }
        }
        // Apps often restore a new window's saved frame a moment after creating it: look once more.
        if !created.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                MainActor.assumeIsolated {
                    let me = DockSpaceReserver.shared
                    guard me.isEnabled else { return }
                    for key in created where me.pending[key] == nil {
                        var burst = WindowChangeBurst()
                        burst.record(mouseDown: false)
                        me.pending[key] = burst
                    }
                    me.scheduleFlush(after: 0.05)
                }
            }
        }
    }

    // MARK: Adjusting

    private func process(_ key: AXWindowKey, _ burst: WindowChangeBurst, rescan: Bool, reservations res: [DockReservation], now: TimeInterval) {
        let window = key.element
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        guard pid != ProcessInfo.processInfo.processIdentifier,
              let info = AXWindowInfo.snapshot(window),
              info.standard, !info.minimized, !info.fullscreen, info.canMove || info.canResize else { return }

        if rescan {
            if manual.contains(key) && !afterDragging { return }
        } else if !burst.shouldAdjust(afterDragging: afterDragging) {
            manual.insert(key)
            return
        } else {
            manual.remove(key)
        }

        let minHeight = info.canResize ? (minHeights[key] ?? 0) : info.frame.height
        guard let target = ReserveSpace.adjusted(info.frame, minSize: CGSize(width: 0, height: minHeight), in: res),
              limiter.allow(key, now: now) else { return }
        apply(target, to: window, key: key, from: info, reservations: res)
    }

    private func apply(_ target: CGRect, to window: AXUIElement, key: AXWindowKey, from info: AXWindowInfo.Snapshot, reservations res: [DockReservation]) {
        let current = info.frame
        let moves = abs(target.minX - current.minX) > 0.5 || abs(target.minY - current.minY) > 0.5
        let resizes = info.canResize && abs(target.height - current.height) > 0.5
        // Shrink before moving up (a tall window can't move first), move before growing.
        if resizes && target.height < current.height { AXWindowInfo.setSize(window, target.size) }
        if moves && info.canMove { AXWindowInfo.setPosition(window, target.origin) }
        if resizes && target.height > current.height { AXWindowInfo.setSize(window, target.size) }

        // Apps may refuse to go below their minimum height: remember it and move the window instead.
        guard let actual = AXWindowInfo.frame(window) else { return }
        if actual.height > target.height + ReserveSpace.tolerance {
            minHeights[key] = actual.height
            if info.canMove, let retry = ReserveSpace.adjusted(actual, minSize: CGSize(width: 0, height: actual.height), in: res) {
                AXWindowInfo.setPosition(window, retry.origin)
            }
        }
    }
}
