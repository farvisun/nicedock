# Habit Tracker and Window Manager

Two widgets from cooldock.app's changelog that the clone was missing: **Habit Tracker** (v1.8, editor in v2.0.9) and
**Window Manager** (v1.6). cooldock.app has no reference frame for either, so these renders are the visual check;
`scripts/chrome-check.sh` checks that both tiles use the reference tile chrome.

| Folder | Command | Shows |
|---|---|---|
| `scene-en/`, `scene-fa/` | `NiceDock --render <dir> habitTracker,habitTracker-empty,habitTracker-panel,habitTracker-weeks,habitTracker-editor,habitTracker-new,windowManager,windowManager-locked,windowManager-panel,windowManager-panel-locked --scene reference --lang en\|fa --style darkGlass` | Fixed data on Thursday 18 June 2026: four habits with history, two checked today. The window list has Safari, Notes, Terminal, Finder (one window minimized) and Music. `-panel`, `-weeks`, `-editor`, `-new` and `-panel-locked` show the panels in place of the tile. |
| `live-en/`, `live-fa/` | `NiceDock --render <dir> habitTracker,windowManager --lang en\|fa` | The real first-run state: no habits yet ("Add a habit"), and Accessibility not granted to the unsigned build ("Allow Accessibility…"). |
| `sheet-tiles.png` | ImageMagick | All tiles side by side: English on the left, Persian on the right (scene, then live). |
| `sheet-panels-en.png`, `sheet-panels-fa.png` | ImageMagick | Habits this week, habits over the last 12 weeks, the editor with one habit open, the empty panel, the window list, and the window list without Accessibility. |

What was checked in the renders:

* Both tiles are 124 px tall with whole-point widths. The habit tile is 24 + 36·n + 8·(n−1) pt (192 pt for four habits, 168 pt
  when empty). The window manager is 18 + 48·buttons pt (306 pt for the five default layouts plus the panel button).
  `chrome-check`: 99.99 % corner match for both.
* Persian: Estedad font, Persian digits (۱۲ روز, ۲ از ۴), Persian weekday initials, and weeks that start on Saturday
  (ش … ج). The habit row, panel rows, editor and segmented controls are mirrored. Rings still fill clockwise, and the
  12-week grid stays left to right like the other charts.
* Window layouts stay geographic in every language: the tile's button row and the panel's layout grid are always
  left to right, and "left half" means the left of the screen.
* No truncation or overlap in either language. Long Persian strings wrap inside the panel's permission card, and the
  empty-state lines scale down if needed.
* Scene renders draw the panels with the real `PanelChrome`. Two things are swapped only while rendering: text fields
  render as plain text, and the list is not wrapped in a `ScrollView`, because ImageRenderer cannot draw those AppKit
  controls. App icons in scene renders use the flat bundle artwork, as the app tiles already do, because system icons
  render in HDR (PQ).

Other checks (27 Oct 2026): `swift test` passes 166 tests, 22 of them new (`HabitTrackerTests`, `WindowManagerTests`).
`scripts/pixel-diff.sh` stays at a 99.55 % mean over 74 frames. `scripts/chrome-check.sh` passes 29/29 tiles that have
no site frame. `python3 scripts/l10n.py check` reports 1163 strings × 10 languages with 0 missing.

No Accessibility call is made while rendering. The service returns before any AX action when `--render` is set, and
scene renders use seeded windows. The app only reads `AXIsProcessTrusted()`, never the prompting variant.
