# Accessibility code paths on real windows (27 Oct 2026, macOS 27.0.1)

CoolDock moves, raises, minimizes and closes other apps' windows, lists them, presses an app's own File ▸ New Window
and reads Dock badges through the Accessibility API. Other apps need the user to grant CoolDock Accessibility in
System Settings; shell-launched processes on this Mac never get it (`AXIsProcessTrusted()` is false). A process needs
no permission for its **own** windows, though, so `AXLiveTests` opens real `NSWindow`s in the test process and hands
the test process's pid to CoolDock's real functions. Apart from the pid, these are the calls CoolDock makes on any app.

```bash
COOLDOCK_LIVE_AX=1 swift test --filter AXLive     # opt-in: puts windows on screen for ~20 s
```

The test process becomes a regular AppKit app (`setActivationPolicy(.regular)`, a main menu with a File menu, then
`finishLaunching()`; without that last call every AX request to the process fails with kAXErrorNotImplemented). It
opens windows titled "AX Probe A", "AX Probe B", … and every action gets entries filtered to its own pid, so no other
app's window is touched. Nothing is persisted (`AppStore.persistenceEnabled = false`, support folder in `$TMPDIR`,
removed at exit).

## Result

11 tests, **6 consecutive passing runs of the final suite** (18.4–19.1 s each; the numbers below are from them). An
earlier version passed 4 runs in a row, then failed 3 of 3 in a later session at "raise another window right after a
restore" (see "Restoring a window from the Dock" below); the final suite no longer depends on that timing. Plain
`swift test` skips the 11 (361 listed, 350 run, all passing).

| What ran against real windows | CoolDock code | Checked | Numbers |
|---|---|---|---|
| Window list: CGWindowList entries, front to back | `UtilWindowService.onScreenEntries(excluding:)`, `UtilWinList` | own windows listed with pid, app name, AX-space frame; z-order A before B; CoolDock's own pid excluded | 3 windows |
| AX window ↔ CGWindowID | `UtilAX.windowID` (`_AXUIElementGetWindow`), `UtilAX.window(pid:id:frame:)` | id equals `NSWindow.windowNumber`; lookup by id, and by frame when the id is unknown; no match for a foreign frame | 3 windows |
| Frames | `UtilAX.frame`, `AXWindowInfo.frame/snapshot` | equal to the flipped `NSWindow.frame`; standard, movable, resizable (non-resizable window: `canResize` false) | exact |
| Panel snapshot off the main thread | `UtilAX.snapshot` (as `reload()` runs it), `merge` | titles from AXTitle with CGWindowList titles blanked (no Screen Recording); focused window; minimized windows appended at the end of their app | 20–22 ms for 3 windows |
| Every Window Manager layout | `UtilWinActions.apply` (behind the tile buttons and the panel) | expected frame computed independently from `NSScreen.visibleFrame` (1512 × 884 at y 65); `UtilWindowService.screens()` equals the visible frames (no CoolDock Dock in the process) | 16 actions; 8 exact, 8 full-height layouts 1 pt short at the bottom (see below); Next Display returns false, frame unchanged (one display) |
| Tile button target | `UtilWinActions.apply(_:toFocusedWindowOf:)` | acts on the app's focused window | exact |
| CoolDock docked at the bottom / under the menu bar | `UtilWinMath.usable` → `apply(…, screens:)` | Maximize, Left Half, Bottom Right stop at the Dock's edge and never overlap it | within 1 pt |
| AXEnhancedUserInterface | `UtilAX.setFrame` | the flag is switched off for the move and is back on afterwards | restored |
| Layout on a minimized window | `UtilWinActions.apply(_:to:)` with `minimized` | restored and placed; the frame survives the end of the restore animation | exact |
| Bring to Front, Minimize, Restore, Close | `UtilWinActions.raise/setMinimized/close`, `AppsAX.raise` (menu window item) | z-order changes, AXMain moves, minimized state round-trips through the panel entry, close button pressed | minimize 513–527 ms, restore 636–652 ms |
| Arrange All | `UtilWinActions.arrange` | 4 windows → 2 × 2 grid, frontmost top left | within 1 pt |
| App menu window list | `AppsAppMenu.build(_:trusted:)`, `AppsAX.windows` | one item per window in the app's order, the main one checked, then New Window; the real (untrusted) `build(_:)` shows neither and offers "Show Windows & Badges…" | — |
| Generic New Window | `AppsAX.fileMenu`, `newWindowItem`, `pressNewWindow` | AX reads the menu bar as Apple, app, File; File ▸ New Window ⌘N is pressed and its action opens a window | 1 window |
| Safari-style profile / private windows | `newWindowItem`, `profileWindowItems`, `privateWindowItem`, `press` | "New Window ▸" resolves to its ⌘N child; profiles = the submenu items; ⇧⌘N = New Private Window; each press opens its window | 3 windows |
| Window events | `WindowEventHub.attach` (the worker behind `observe`), `AXWindowInfo.setSize/setPosition` | moved (app move and AX move), resized, created (and the new window watched), restored; mouse up; closed windows leave `allWindows()` | exactly 1 event per change (2 per move before the fix) |
| Dock badges | `AppsDockBadges.read()`, `labels(in:)` | untrusted: `read()` returns nil at once; the Dock refuses the process (kAXErrorAPIDisabled) and `labels(in:)` returns nothing; no window of the system's Accessibility prompt agent appears. The parser over a Dock-shaped tree served by the process (AXList ▸ items with AXURL / AXStatusLabel, one without a label, one empty) | gate 0 ms; Dock refused in 22–32 ms; 2 of 4 items labelled |

## Bug found and fixed

- **Every window event arrived twice.** `WindowEventHub` registered moved, resized and restored notifications on the
  app element *and* on each window. The app element already receives its windows' notifications, so each move, resize
  and restore reached Reserve Dock Space and Hide on Window Hover twice. Each window now registers only its
  destruction, plus whatever the app element refused (`Sources/CoolDock/App/WindowEvents.swift`). Live: 2 moved
  events per move before, 1 after; resize and restore 1 each.

## Found, not CoolDock bugs

- **Full-height layouts end 1 pt above the Dock.** AppKit clamps a window resized through Accessibility so its bottom
  edge stays at `visibleFrame.minY + 1`. Left/Right Half, Maximize, the thirds and two-thirds come out 883 pt tall at
  y 66 instead of 884 at y 65; the left, top and right edges are exact. Moves are not clamped (Bottom Half and the
  bottom quarters land exactly), `NSWindow.setFrame` gives the exact frame, and no order of size and position avoids
  it (size → position → size, position first, 1 pt into the menu bar first, 1 pt lower first; `AXFrame` is not
  settable). The suite asserts exactly this: every other edge exact, the bottom within 1 pt.
- **"Prefer tabs when opening documents: Always"** (this Mac) merges an app's new windows into one tab group. Then
  Accessibility and CGWindowList both show only the selected tab, so the window list shows one entry per tab group.
  The suite turns tabbing off for its own windows.
- **Restoring a window from the Dock activates its app**, and a Bring to Front for a *different* window of the same
  app, sent while that activation is still landing, can be reordered by AppKit afterwards. In CoolDock the restored
  window is the one brought forward (and its app is activated), so the suite raises other windows before it restores
  any, and checks the minimized-window raise right away.
- **AppKit stops the main run loop** to end its own waits (blocks queued while windows move, and the Dock's answers to
  minimize / restore). In CoolDock `NSApplication.run()` simply goes on. Between tests, though, the test runner's main
  thread sits in Swift's async-main `CFRunLoopRun()`, which returns and exits the process. The suite therefore runs
  synchronously, pumps through `NSApp.nextEvent`, and from the first gap between tests on runs the session inside a
  loop that keeps going when stopped. An exit guard fails the run (exit 70) if the process ever ends early.

## What changed for testability (no behaviour change for users)

The Accessibility trust check stays at every entry point; the work behind it moved into functions that take a pid or
window:

- `UtilWindowService.perform/focus/toggleMinimized/close/arrangeAll` check trust (and ask for it), then call
  `UtilWinActions.apply/raise/setMinimized/close/arrange`. `onScreenEntries(excluding:)` and `merge` are callable.
- `AppsAppMenu.build(_:)` passes the real trust to `build(_:trusted:)`. `AppsAppCommands.newWindow` checks trust,
  then calls `AppsAX.pressNewWindow`. Safari's private window uses `AppsAX.privateWindowItem`. `AppsAX.raise(_:of:)`
  is `raise(_:)` (the AX half) plus activation.
- `AppsDockBadges.read()` checks trust, then reads `labels(in:)`.
- `WindowEventHub.observe(_:)` keeps its gates (hub running, i.e. trusted; never CoolDock itself; regular apps), then
  calls `attach(_:)`.

No `--window-probe` dev tool was added: it could only probe CoolDock's own windows here, which this suite covers.

## The boundary

- **Other apps** need the user's Accessibility grant, and it can't be granted from a shell on this Mac. With it, the
  same functions run with another app's pid; only the pid differs.
- The windows here are AppKit windows. Apps with their own Accessibility implementation (Chromium/Electron, Qt, Java)
  answer the same attributes and actions but may differ in details such as the 1 pt clamp.
- Not exercised: Next Display (one display connected; its math is unit-tested), the permission request itself
  (`requestAccess()` opens System Settings), activating another app, real Dock badge labels (the Dock refuses
  untrusted processes; the parser ran on a Dock-shaped tree), and Reserve Dock Space's decisions (its AX reads and
  setters ran; the reserver itself skips CoolDock's own windows).
