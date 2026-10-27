import CoreGraphics
import Foundation
import Testing
@testable import CoolDock

/// Window Manager frame math (`Widgets/Utility/UtilWindowLayout.swift`). Cocoa coordinates: origin at the bottom
/// left of the primary display, y up.
@Suite struct WindowManagerTests {
    /// Primary 1440×900 MacBook: 25 pt menu bar, 70 pt macOS Dock at the bottom.
    let primary = UtilWinScreen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900), usable: CGRect(x: 0, y: 70, width: 1440, height: 805))
    /// 1920×1080 display to the right, its bottom 180 pt lower; menu bar only.
    let right = UtilWinScreen(frame: CGRect(x: 1440, y: -180, width: 1920, height: 1080), usable: CGRect(x: 1440, y: -180, width: 1920, height: 1055))
    /// 1280×800 display to the left and above (negative x).
    let left = UtilWinScreen(frame: CGRect(x: -1280, y: 900, width: 1280, height: 800), usable: CGRect(x: -1280, y: 900, width: 1280, height: 775))

    private var screens: [UtilWinScreen] { [primary, right, left] }

    private func target(_ action: UtilWinAction, _ window: CGRect, _ screens: [UtilWinScreen]? = nil) -> CGRect? {
        UtilWinMath.target(action, window: window, screens: screens ?? self.screens)
    }

    @Test func halvesAndMaximize() {
        let win = CGRect(x: 100, y: 200, width: 800, height: 500)
        #expect(target(.leftHalf, win) == CGRect(x: 0, y: 70, width: 720, height: 805))
        #expect(target(.rightHalf, win) == CGRect(x: 720, y: 70, width: 720, height: 805))
        #expect(target(.maximize, win) == primary.usable)
        // Top/bottom halves share the edge exactly (805 is odd: one gets the extra point).
        let top = target(.topHalf, win)!, bottom = target(.bottomHalf, win)!
        #expect(top.maxY == 875 && bottom.minY == 70 && top.minY == bottom.maxY)
        #expect(top.height + bottom.height == 805 && top.width == 1440)
    }

    @Test func thirdsQuartersShareEdges() {
        let win = CGRect(x: 100, y: 200, width: 800, height: 500)
        let thirds = [UtilWinAction.leftThird, .centerThird, .rightThird].map { target($0, win)! }
        #expect(thirds.map(\.width) == [480, 480, 480])
        #expect(thirds[0].maxX == thirds[1].minX && thirds[1].maxX == thirds[2].minX && thirds[2].maxX == 1440)
        #expect(target(.leftTwoThirds, win)!.width == 960 && target(.rightTwoThirds, win)!.minX == 480)
        let q = [UtilWinAction.topLeft, .topRight, .bottomLeft, .bottomRight].map { target($0, win)! }
        let area: CGFloat = q.reduce(CGFloat(0)) { $0 + $1.width * $1.height }
        #expect(area == CGFloat(1440 * 805))
        #expect(q[0].minX == 0 && q[1].maxX == 1440 && q[2].minY == 70 && q[0].maxY == 875)

        // Odd widths: neighbouring halves still meet without a gap or overlap.
        let odd = [UtilWinScreen(frame: CGRect(x: 0, y: 0, width: 1441, height: 901), usable: CGRect(x: 0, y: 0, width: 1441, height: 901))]
        let l = target(.leftHalf, win, odd)!, r = target(.rightHalf, win, odd)!
        #expect(l.maxX == r.minX && l.width + r.width == 1441)
    }

    @Test func centerKeepsSizeAndFits() {
        let win = CGRect(x: 100, y: 200, width: 800, height: 600)
        let c = target(.center, win)!
        #expect(c.size == win.size)
        #expect(abs(c.midX - primary.usable.midX) <= 0.5 && abs(c.midY - primary.usable.midY) <= 0.5)
        let huge = target(.center, CGRect(x: 0, y: 0, width: 1500, height: 2000))!
        #expect(huge == primary.usable)
    }

    @Test func otherDisplaysAndNegativeOrigins() {
        // Mostly on the right display (straddling the edge) → that display's left half.
        let straddling = CGRect(x: 1300, y: 100, width: 900, height: 600)
        #expect(UtilWinMath.screenIndex(for: straddling, in: screens) == 1)
        #expect(target(.leftHalf, straddling) == CGRect(x: 1440, y: -180, width: 960, height: 1055))
        // Display left of and above the primary.
        let onLeft = CGRect(x: -1000, y: 1000, width: 500, height: 400)
        #expect(UtilWinMath.screenIndex(for: onLeft, in: screens) == 2)
        #expect(target(.leftHalf, onLeft) == CGRect(x: -1280, y: 900, width: 640, height: 775))
        #expect(target(.rightHalf, onLeft) == CGRect(x: -640, y: 900, width: 640, height: 775))
        // Off every display: nearest one.
        #expect(UtilWinMath.screenIndex(for: CGRect(x: 5000, y: 0, width: 100, height: 100), in: screens) == 1)
    }

    @Test func nextDisplay() {
        // Order is left to right: left (-1280) → primary (0) → right (1440) → wraps to left.
        #expect(UtilWinMath.displayOrder(screens) == [2, 0, 1])
        let leftHalfOnPrimary = CGRect(x: 0, y: 70, width: 720, height: 805)
        #expect(target(.nextDisplay, leftHalfOnPrimary) == CGRect(x: 1440, y: -180, width: 960, height: 1055))
        let maxOnRight = right.usable
        #expect(target(.nextDisplay, maxOnRight) == left.usable)

        // A free window keeps its size and relative place in the free space.
        let free = CGRect(x: 320, y: 70 + 102, width: 800, height: 600) // centred horizontally, 102 of 205 pt free height up
        let moved = target(.nextDisplay, free)!
        #expect(moved.size == free.size)
        #expect(moved.minX == 1440 + 560 && moved.minY == (-180 + 455.0 * 102 / 205).rounded())
        // Too big for the next display: shrunk to fit.
        let big = target(.nextDisplay, CGRect(x: 1500, y: -100, width: 1800, height: 1000))!
        #expect(big.width <= left.usable.width && big.height <= left.usable.height && left.usable.contains(big))

        // One display: nothing to move to.
        #expect(target(.nextDisplay, free, [primary]) == nil)
    }

    @Test func coolDockInset() {
        let visible = primary.usable
        // Docked at the bottom: windows stop above it.
        let bottom = UtilWinMath.usable(visible: visible, dock: CGRect(x: 400, y: 4, width: 640, height: 86))
        #expect(bottom == CGRect(x: 0, y: 90, width: 1440, height: 785))
        // Docked under the menu bar.
        let top = UtilWinMath.usable(visible: visible, dock: CGRect(x: 400, y: 790, width: 640, height: 80))
        #expect(top == CGRect(x: 0, y: 70, width: 1440, height: 720))
        // A dock on another display, or none, changes nothing.
        #expect(UtilWinMath.usable(visible: visible, dock: CGRect(x: 2000, y: -170, width: 600, height: 80)) == visible)
        #expect(UtilWinMath.usable(visible: visible, dock: nil) == visible)
        // Maximize respects it.
        let docked = [UtilWinScreen(frame: primary.frame, usable: bottom)]
        #expect(target(.maximize, CGRect(x: 10, y: 100, width: 300, height: 300), docked) == bottom)
    }

    @Test func coordinateFlip() {
        // AX/CG: origin top-left of the primary display. A window at the very top under the menu bar:
        let ax = CGRect(x: 0, y: 25, width: 1440, height: 400)
        let cocoa = UtilWinMath.flip(ax, primaryHeight: 900)
        #expect(cocoa == CGRect(x: 0, y: 475, width: 1440, height: 400))
        #expect(UtilWinMath.flip(cocoa, primaryHeight: 900) == ax)
        // Display below the primary has AX y beyond 900.
        #expect(UtilWinMath.flip(CGRect(x: 1440, y: 950, width: 100, height: 100), primaryHeight: 900).minY == -150)
    }

    @Test func layoutsAreGeographic() {
        // The math takes no layout direction: "left half" is the left of the display in every language,
        // including displays at negative x; the glyphs draw the same region.
        for s in screens {
            let win = CGRect(x: s.frame.midX - 100, y: s.frame.midY - 100, width: 200, height: 200)
            #expect(target(.leftHalf, win)!.minX == s.usable.minX)
            #expect(target(.rightHalf, win)!.maxX == s.usable.maxX)
        }
        #expect(UtilWinAction.leftHalf.glyphRegion.minX == 0 && UtilWinAction.rightHalf.glyphRegion.maxX == 1)
    }

    @Test func arrangeGrid() {
        let area = primary.usable
        #expect(UtilWinMath.grid(0, in: area).isEmpty)
        #expect(UtilWinMath.grid(1, in: area) == [area])
        let two = UtilWinMath.grid(2, in: area)
        #expect(two == [CGRect(x: 0, y: 70, width: 720, height: 805), CGRect(x: 720, y: 70, width: 720, height: 805)])
        #expect(UtilWinMath.grid(3, in: area).map(\.width) == [480, 480, 480])
        for n in 4...12 {
            let rects = UtilWinMath.grid(n, in: area)
            #expect(rects.count == n)
            #expect(rects.reduce(0) { $0 + $1.width * $1.height } == area.width * area.height, "\(n)")
            #expect(rects.allSatisfy { area.contains($0) })
            #expect(rects[0].minX == area.minX && rects[0].maxY == area.maxY) // frontmost top left
        }
        // Five: three on top, two sharing the bottom row.
        let five = UtilWinMath.grid(5, in: area)
        #expect(five[0].width == 480 && five[3].width == 720 && five[3].minY == 70)
    }

    @Test func windowListParsing() {
        let infos: [[String: Any]] = [
            [kCGWindowLayer as String: 0, kCGWindowOwnerPID as String: 42, kCGWindowNumber as String: 7, kCGWindowOwnerName as String: "Safari",
             kCGWindowName as String: "Apple", kCGWindowAlpha as String: 1.0,
             kCGWindowBounds as String: ["X": 10, "Y": 30, "Width": 900, "Height": 700]],
            // Title hidden without Screen Recording.
            [kCGWindowLayer as String: 0, kCGWindowOwnerPID as String: 43, kCGWindowNumber as String: 8, kCGWindowOwnerName as String: "Notes",
             kCGWindowName as String: "", kCGWindowBounds as String: ["X": 0, "Y": 0, "Width": 500, "Height": 400]],
            [kCGWindowLayer as String: 0, kCGWindowOwnerPID as String: 42, kCGWindowNumber as String: 9, kCGWindowOwnerName as String: "Safari",
             kCGWindowBounds as String: ["X": 50, "Y": 60, "Width": 900, "Height": 700]],
            // Menu bar item, tiny, invisible and own windows are skipped.
            [kCGWindowLayer as String: 25, kCGWindowOwnerPID as String: 44, kCGWindowNumber as String: 10, kCGWindowBounds as String: ["X": 0, "Y": 0, "Width": 30, "Height": 24]],
            [kCGWindowLayer as String: 0, kCGWindowOwnerPID as String: 45, kCGWindowNumber as String: 11, kCGWindowBounds as String: ["X": 0, "Y": 0, "Width": 20, "Height": 20]],
            [kCGWindowLayer as String: 0, kCGWindowOwnerPID as String: 46, kCGWindowNumber as String: 12, kCGWindowAlpha as String: 0.0,
             kCGWindowBounds as String: ["X": 0, "Y": 0, "Width": 800, "Height": 600]],
            [kCGWindowLayer as String: 0, kCGWindowOwnerPID as String: 1, kCGWindowNumber as String: 13, kCGWindowBounds as String: ["X": 0, "Y": 0, "Width": 800, "Height": 600]]
        ]
        let entries = UtilWinList.parse(infos, ownPID: 1)
        #expect(entries.map(\.id) == [7, 8, 9])
        #expect(entries[0].title == "Apple" && entries[1].title == nil && entries[0].frame == CGRect(x: 10, y: 30, width: 900, height: 700))
        let groups = UtilWinList.group(entries)
        #expect(groups.map(\.pid) == [42, 43] && groups[0].windows.map(\.id) == [7, 9])
    }

    @MainActor @Test func tileItemsAndWidth() {
        let defaults = WidgetInstance(kind: .windowManager)
        #expect(UtilWindowsView.items(defaults) == UtilWinAction.tileDefaults)
        #expect(UtilWindowsView.width(buttons: UtilWindowsView.items(defaults).count + 1) == WidgetKind.windowManager.spec.width)
        let custom = WidgetInstance(kind: .windowManager, config: ["items": "topHalf\n bogus\nbottomHalf\ntopHalf\nnextDisplay"])
        #expect(UtilWindowsView.items(custom) == [.topHalf, .bottomHalf, .nextDisplay])
        for n in 1...8 { #expect(UtilWindowsView.width(buttons: n) == UtilWindowsView.width(buttons: n).rounded()) }
    }
}
