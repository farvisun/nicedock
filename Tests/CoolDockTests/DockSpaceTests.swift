import CoreGraphics
import Foundation
import Testing
@testable import CoolDock

/// Reserve Dock Space geometry (Quartz coordinates: origin top-left of the primary display, y down).
///
/// Primary display: 1512 × 982 pt (14" MacBook Pro), 37 pt menu bar, macOS Dock auto-hidden → visible 0,37 1512×941.
/// Secondary display: 1920 × 1080 to the right, 200 pt higher, 25 pt menu bar.
@Suite struct ReserveSpaceTests {
    static let primary = CGRect(x: 0, y: 0, width: 1512, height: 982)
    static let primaryVisible = CGRect(x: 0, y: 37, width: 1512, height: 941)
    static let secondary = CGRect(x: 1512, y: -200, width: 1920, height: 1080)
    static let secondaryVisible = CGRect(x: 1512, y: -175, width: 1920, height: 1055)

    /// 600 × 78 plate centred 8 pt above the bottom edge → top edge at 896, limit 890.
    static let bottomDock = DockReservation(displayID: "A", screen: primary, visible: primaryVisible,
                                            dock: CGRect(x: 456, y: 896, width: 600, height: 78), edge: .bottom)
    /// Same plate 8 pt below the menu bar → bottom edge at 123, limit 129.
    static let topDock = DockReservation(displayID: "A", screen: primary, visible: primaryVisible,
                                         dock: CGRect(x: 456, y: 45, width: 600, height: 78), edge: .top)
    static let secondaryDock = DockReservation(displayID: "B", screen: secondary, visible: secondaryVisible,
                                               dock: CGRect(x: 2172, y: 794, width: 600, height: 78), edge: .bottom)

    // MARK: Bottom dock

    @Test func reservationEdgesAndLimits() {
        #expect(Self.bottomDock.limit == 890)
        #expect(Self.bottomDock.keepOut == CGRect(x: 456, y: 890, width: 600, height: 84))
        #expect(Self.topDock.limit == 129)
        #expect(Self.topDock.keepOut == CGRect(x: 456, y: 45, width: 600, height: 84))
    }

    @Test func zoomedWindowIsShortenedToTheDockEdge() {
        let zoomed = Self.primaryVisible
        #expect(ReserveSpace.adjusted(zoomed, in: [Self.bottomDock]) == CGRect(x: 0, y: 37, width: 1512, height: 853))
    }

    @Test func leftHalfTileThatReachesUnderTheDockIsShortened() {
        let leftHalf = CGRect(x: 0, y: 37, width: 756, height: 941)
        #expect(ReserveSpace.adjusted(leftHalf, in: [Self.bottomDock]) == CGRect(x: 0, y: 37, width: 756, height: 853))
    }

    @Test func partlyOverlappingWindowMovesUpAndKeepsItsSize() {
        let w = CGRect(x: 300, y: 600, width: 800, height: 400) // bottom at 1000, 110 pt under the limit
        #expect(ReserveSpace.adjusted(w, in: [Self.bottomDock]) == CGRect(x: 300, y: 490, width: 800, height: 400))
    }

    @Test func windowThatOverlapsOnlyTheGapIsMoved() {
        let w = CGRect(x: 500, y: 300, width: 400, height: 593) // ends at 893: inside the 6 pt gap above the plate
        #expect(ReserveSpace.adjusted(w, in: [Self.bottomDock]) == CGRect(x: 500, y: 297, width: 400, height: 593))
    }

    @Test func alreadyFittingWindowsAreUntouched() {
        #expect(ReserveSpace.adjusted(CGRect(x: 300, y: 100, width: 800, height: 700), in: [Self.bottomDock]) == nil)
        // Ending exactly at the limit.
        #expect(ReserveSpace.adjusted(CGRect(x: 300, y: 90, width: 800, height: 800), in: [Self.bottomDock]) == nil)
        // Beside a centred dock: no horizontal overlap with the plate.
        #expect(ReserveSpace.adjusted(CGRect(x: 0, y: 500, width: 400, height: 478), in: [Self.bottomDock]) == nil)
        #expect(ReserveSpace.adjusted(CGRect(x: 1100, y: 500, width: 412, height: 478), in: [Self.bottomDock]) == nil)
        // No reservations at all (feature off, Dock hidden or auto-hiding).
        #expect(ReserveSpace.adjusted(Self.primaryVisible, in: []) == nil)
    }

    @Test func windowsNeverGoAboveTheMenuBar() {
        let w = CGRect(x: 100, y: 0, width: 800, height: 990) // starts under the menu bar
        let r = try! #require(ReserveSpace.adjusted(w, in: [Self.bottomDock]))
        #expect(r.minY == Self.primaryVisible.minY)
        #expect(r.maxY == Self.bottomDock.limit)
    }

    @Test func tallWindowBelowTheMenuBarKeepsItsTop() {
        let w = CGRect(x: 0, y: 100, width: 800, height: 870) // too tall to move above the limit
        #expect(ReserveSpace.adjusted(w, in: [Self.bottomDock]) == CGRect(x: 0, y: 100, width: 800, height: 790))
    }

    @Test func fullscreenWindowsAreLeftAlone() {
        #expect(ReserveSpace.adjusted(Self.primary, in: [Self.bottomDock]) == nil)
        #expect(ReserveSpace.adjusted(Self.primary.insetBy(dx: -1, dy: -1), in: [Self.bottomDock]) == nil)
    }

    // MARK: Min size

    @Test func minimumHeightMovesTheWindowUpBeforeShortening() {
        let w = CGRect(x: 0, y: 100, width: 800, height: 870)
        #expect(ReserveSpace.adjusted(w, minSize: CGSize(width: 0, height: 830), in: [Self.bottomDock])
            == CGRect(x: 0, y: 60, width: 800, height: 830))
    }

    @Test func minimumHeightTallerThanTheFreeSpaceKeepsTheTopAtTheMenuBar() {
        // The app can't be shorter than 900 pt: best effort is the top of the visible area; it still covers the Dock a bit.
        let r = ReserveSpace.adjusted(Self.primaryVisible, minSize: CGSize(width: 0, height: 900), in: [Self.bottomDock])
        #expect(r == CGRect(x: 0, y: 37, width: 1512, height: 900))
        // And it is stable: the next event for that window changes nothing (no loop).
        #expect(ReserveSpace.adjusted(r!, minSize: CGSize(width: 0, height: 900), in: [Self.bottomDock]) == nil)
    }

    @Test func fixedSizeWindowIsOnlyMoved() {
        let w = CGRect(x: 200, y: 400, width: 500, height: 560)
        let r = ReserveSpace.adjusted(w, minSize: w.size, in: [Self.bottomDock])
        #expect(r == CGRect(x: 200, y: 330, width: 500, height: 560))
    }

    @Test func neverSqueezedBelowTheFloorHeight() {
        // A floating dock high on the screen leaves almost no room above it.
        let high = DockReservation(displayID: "A", screen: Self.primary, visible: Self.primaryVisible,
                                   dock: CGRect(x: 456, y: 600, width: 600, height: 78), edge: .bottom) // limit 594
        let w = CGRect(x: 400, y: 37, width: 700, height: 941)
        let r = try! #require(ReserveSpace.adjusted(w, in: [high]))
        #expect(r == CGRect(x: 400, y: 37, width: 700, height: 557))
        // A plate right under the menu bar in bottom mode leaves 37 pt: the window keeps the floor height instead.
        let tooHigh = DockReservation(displayID: "A", screen: Self.primary, visible: Self.primaryVisible,
                                      dock: CGRect(x: 456, y: 80, width: 600, height: 78), edge: .bottom) // limit 74
        #expect(ReserveSpace.adjusted(w, in: [tooHigh]) == CGRect(x: 400, y: 37, width: 700, height: ReserveSpace.floorHeight))
    }

    // MARK: Top and floating docks

    @Test func topDockPushesWindowsDown() {
        let w = CGRect(x: 200, y: 37, width: 1000, height: 600)
        #expect(ReserveSpace.adjusted(w, in: [Self.topDock]) == CGRect(x: 200, y: 129, width: 1000, height: 600))
        #expect(ReserveSpace.adjusted(Self.primaryVisible, in: [Self.topDock]) == CGRect(x: 0, y: 129, width: 1512, height: 849))
        #expect(ReserveSpace.adjusted(CGRect(x: 200, y: 129, width: 1000, height: 600), in: [Self.topDock]) == nil)
    }

    @Test func floatingDockUsesTheNearestEdge() {
        let upper = DockReservation(displayID: "A", screen: Self.primary, visible: Self.primaryVisible, dock: CGRect(x: 456, y: 200, width: 600, height: 78))
        let lower = DockReservation(displayID: "A", screen: Self.primary, visible: Self.primaryVisible, dock: CGRect(x: 456, y: 700, width: 600, height: 78))
        #expect(upper.edge == .top)
        #expect(lower.edge == .bottom)
        let w = CGRect(x: 500, y: 250, width: 300, height: 300)
        #expect(ReserveSpace.adjusted(w, in: [upper]) == CGRect(x: 500, y: 284, width: 300, height: 300))
        #expect(ReserveSpace.adjusted(CGRect(x: 500, y: 600, width: 300, height: 300), in: [lower]) == CGRect(x: 500, y: 394, width: 300, height: 300))
    }

    // MARK: Several displays

    @Test func quartzConversionForADisplayAboveThePrimary() {
        // AppKit: the secondary display's origin is 102 pt above the primary's bottom edge.
        let appKit = CGRect(x: 1512, y: 102, width: 1920, height: 1080)
        #expect(ReserveSpace.quartz(appKit, primaryHeight: 982) == Self.secondary)
        #expect(ReserveSpace.appKit(Self.secondary, primaryHeight: 982) == appKit)
        // A plate 8 pt above the primary's bottom edge.
        #expect(ReserveSpace.quartz(CGRect(x: 456, y: 8, width: 600, height: 78), primaryHeight: 982) == Self.bottomDock.dock)
    }

    @Test func eachDisplayKeepsRoomForItsOwnDock() {
        let both = [Self.bottomDock, Self.secondaryDock]
        #expect(ReserveSpace.adjusted(Self.secondaryVisible, in: both) == CGRect(x: 1512, y: -175, width: 1920, height: 963))
        #expect(ReserveSpace.adjusted(Self.primaryVisible, in: both) == CGRect(x: 0, y: 37, width: 1512, height: 853))
    }

    @Test func displayWithoutANiceDockIsUntouched() {
        // One Display mode: only the secondary has a Dock.
        #expect(ReserveSpace.adjusted(Self.primaryVisible, in: [Self.secondaryDock]) == nil)
        #expect(ReserveSpace.adjusted(Self.secondaryVisible, in: [Self.bottomDock]) == nil)
    }

    @Test func windowSpanningTwoDisplaysFollowsTheDockItCoversMost() {
        // Covers 356 × 70 pt of A's keep-out area and 28 × 84 pt of B's.
        let w = CGRect(x: 700, y: 500, width: 1500, height: 460)
        let r = try! #require(ReserveSpace.reservation(for: w, in: [Self.bottomDock, Self.secondaryDock]))
        #expect(r.displayID == "A")
        #expect(ReserveSpace.adjusted(w, in: [Self.bottomDock, Self.secondaryDock]) == CGRect(x: 700, y: 430, width: 1500, height: 460))
    }

    @Test func adjustingTwiceChangesNothing() {
        let windows = [Self.primaryVisible, CGRect(x: 300, y: 600, width: 800, height: 400), CGRect(x: 0, y: 100, width: 800, height: 870),
                       CGRect(x: 100, y: 0, width: 800, height: 990), Self.secondaryVisible]
        for w in windows {
            for res in [[Self.bottomDock, Self.secondaryDock], [Self.topDock]] {
                if let once = ReserveSpace.adjusted(w, in: res) { #expect(ReserveSpace.adjusted(once, in: res) == nil, "\(w)") }
            }
        }
    }

    // MARK: Drag classification and the anti-fight limiter

    @Test func dragClassification() {
        var drag = WindowChangeBurst()
        drag.record(mouseDown: true)
        drag.record(mouseDown: true)
        drag.record(mouseDown: false) // trailing move echo after the button went up
        #expect(drag.isManual)
        #expect(!drag.shouldAdjust(afterDragging: false))
        #expect(drag.shouldAdjust(afterDragging: true))

        var tileAfterDrag = WindowChangeBurst()
        tileAfterDrag.record(mouseDown: true)
        tileAfterDrag.record(resized: true, mouseDown: false) // macOS tiles the window on release
        #expect(!tileAfterDrag.isManual)
        #expect(tileAfterDrag.shouldAdjust(afterDragging: false))

        var created = WindowChangeBurst()
        created.record(created: true, mouseDown: false)
        #expect(created.created && !created.isManual)

        var zoom = WindowChangeBurst()
        zoom.record(resized: true, mouseDown: false)
        zoom.record(mouseDown: false)
        #expect(zoom.shouldAdjust(afterDragging: false))

        var restore = WindowChangeBurst()
        restore.record(restored: true, mouseDown: false)
        #expect(restore.shouldAdjust(afterDragging: false))
    }

    @Test func limiterStopsFightingAndRecovers() {
        var limiter = AdjustmentLimiter()
        // (time, window, expected) — the fourth try within 4 s means the app keeps putting the window back.
        let script: [(TimeInterval, String, Bool)] = [(0, "w", true), (0.5, "w", true), (1, "w", true), (1.5, "w", false),
                                                     (1.5, "other", true), (20, "w", false), (32, "w", true), (40, "w", true)]
        let results = script.map { limiter.allow($0.1, now: $0.0) }
        #expect(results == script.map(\.2))
    }
}

/// Hide on Window Hover state machine.
@Suite struct HoverHideTests {
    typealias Input = HoverHideMachine.Input

    static let idle = Input()
    static let covered = Input(overlap: true)
    static let coveredRest = Input(overlap: true, pointerInside: true)
    static let coveredClick = Input(overlap: true, pointerInside: true, pointerBusy: true)

    @Test func staysShownWithoutOverlap() {
        var m = HoverHideMachine()
        do { let phase = m.step(Self.idle, now: 0); #expect(phase == .shown) }
        do { let phase = m.step(Input(pointerInside: true), now: 1); #expect(phase == .shown) }
        #expect(m.deadline == nil)
    }

    @Test func fadesWhileAWindowOverlapsAndReturnsWhenItLeaves() {
        var m = HoverHideMachine()
        do { let phase = m.step(Self.covered, now: 0); #expect(phase == .faded) }
        #expect(m.isFaded)
        do { let phase = m.step(Self.covered, now: 5); #expect(phase == .faded) }
        do { let phase = m.step(Self.idle, now: 6); #expect(phase == .shown) }
    }

    @Test func restingPointerRevealsAfterTheDwell() {
        var m = HoverHideMachine()
        m.step(Self.covered, now: 0)
        do { let phase = m.step(Self.coveredRest, now: 1); #expect(phase == .faded) }
        #expect(m.deadline == 1 + HoverHideMachine.dwell)
        do { let phase = m.step(Self.coveredRest, now: 1.3); #expect(phase == .faded) }
        do { let phase = m.step(Self.coveredRest, now: 1.5); #expect(phase == .peeking) }
        #expect(!m.isFaded)
    }

    @Test func clicksInTheDockAreaGoToTheWindow() {
        var m = HoverHideMachine()
        m.step(Self.covered, now: 0)
        m.step(Self.coveredRest, now: 1)
        // Clicking, dragging or scrolling while faded restarts the wait: those events belong to the window below.
        do { let phase = m.step(Self.coveredClick, now: 1.4); #expect(phase == .faded) }
        #expect(m.restSince == nil)
        do { let phase = m.step(Self.coveredRest, now: 1.6); #expect(phase == .faded) }
        do { let phase = m.step(Self.coveredRest, now: 2.0); #expect(phase == .faded) }
        do { let phase = m.step(Self.coveredRest, now: 2.1); #expect(phase == .peeking) }
    }

    @Test func pointerLeavingFadesAgainAfterTheGrace() {
        var m = HoverHideMachine()
        m.step(Self.covered, now: 0)
        m.step(Self.coveredRest, now: 1)
        m.step(Self.coveredRest, now: 1.5)
        #expect(m.phase == .peeking)
        do { let phase = m.step(Self.coveredClick, now: 1.6); #expect(phase == .peeking) } // clicking the visible Dock is fine
        do { let phase = m.step(Self.covered, now: 2); #expect(phase == .peeking) }
        #expect(m.deadline == 2 + HoverHideMachine.grace)
        do { let phase = m.step(Self.coveredRest, now: 2.2); #expect(phase == .peeking) } // came back in time
        do { let phase = m.step(Self.covered, now: 3); #expect(phase == .peeking) }
        do { let phase = m.step(Self.covered, now: 3.5); #expect(phase == .faded) }
    }

    @Test func overlapEndingWhilePeekingShowsTheDock() {
        var m = HoverHideMachine()
        m.step(Self.covered, now: 0)
        m.step(Self.coveredRest, now: 1)
        m.step(Self.coveredRest, now: 2)
        do { let phase = m.step(Input(pointerInside: true), now: 3); #expect(phase == .shown) }
    }

    @Test func overlapStartingUnderARestingPointerKeepsTheDock() {
        var m = HoverHideMachine()
        do { let phase = m.step(Self.coveredRest, now: 0); #expect(phase == .peeking) }
        // …but dragging a window over the Dock (button held) fades it.
        var drag = HoverHideMachine()
        do { let phase = drag.step(Self.coveredClick, now: 0); #expect(phase == .faded) }
    }

    @Test func openPopUpsHoldTheDock() {
        var m = HoverHideMachine()
        m.step(Self.covered, now: 0)
        do { let phase = m.step(Input(overlap: true, holdOpen: true), now: 1); #expect(phase == .shown) }
        do { let phase = m.step(Self.covered, now: 2); #expect(phase == .faded) }
    }

    @Test func eachDisplayHasItsOwnState() {
        var board = HoverHideBoard()
        var phases = board.step(["A": Self.covered, "B": Self.idle], now: 0)
        #expect(phases == ["A": .faded, "B": .shown])
        #expect(board.needsPointerTracking)
        // The pointer rests on B's Dock: nothing changes on A.
        phases = board.step(["A": Self.covered, "B": Input(pointerInside: true)], now: 1)
        #expect(phases == ["A": .faded, "B": .shown])
        // The pointer rests on A's Dock area: A is revealed after the dwell, B unaffected.
        board.step(["A": Self.coveredRest, "B": Self.idle], now: 2)
        #expect(board.deadline == 2 + HoverHideMachine.dwell)
        phases = board.step(["A": Self.coveredRest, "B": Self.idle], now: 2.6)
        #expect(phases == ["A": .peeking, "B": .shown])
        // A window now covers B as well while A is peeking.
        phases = board.step(["A": Self.coveredRest, "B": Self.covered], now: 3)
        #expect(phases == ["A": .peeking, "B": .faded])
        // A display that goes away is dropped; the overlap on A ends.
        phases = board.step(["A": Self.idle], now: 4)
        #expect(phases == ["A": .shown])
        #expect(board.machines.keys.sorted() == ["A"])
        #expect(!board.needsPointerTracking)
        #expect(board.deadline == nil)
    }

    @Test func overlapGeometry() {
        let dock = CGRect(x: 456, y: 896, width: 600, height: 78)
        #expect(WindowOverlap.overlaps(CGRect(x: 0, y: 37, width: 1512, height: 941), dock: dock))
        #expect(!WindowOverlap.overlaps(CGRect(x: 0, y: 37, width: 1512, height: 859), dock: dock)) // ends at the plate's top
        #expect(!WindowOverlap.overlaps(CGRect(x: 0, y: 37, width: 1512, height: 860), dock: dock)) // 1 pt: touching
        #expect(!WindowOverlap.overlaps(CGRect(x: 500, y: 900, width: 30, height: 20), dock: dock)) // tooltip-sized
        #expect(!WindowOverlap.overlaps(CGRect(x: 0, y: 500, width: 456, height: 478), dock: dock)) // beside it
    }
}
