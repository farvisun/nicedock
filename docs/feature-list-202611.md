# NiceDock feature research — November 2026

Competitor scan and proposed feature list for NiceDock, the native macOS "second Dock with live widgets".
Written 2026-11-04. Scope: what NiceDock ships today, what comparable Mac apps ship or users ask for, and
65 proposed features that fit NiceDock's local-first model (no account, no telemetry, credentials in the Keychain).

## How to read this document

Every feature has the same fields:

- **What**: what it does.
- **Join / stay**: why it brings users in or keeps them.
- **Competitors**: who ships it. "CoolDock roadmap" means a user request on [cooldock.app/roadmap](https://cooldock.app/roadmap),
  not a shipped CoolDock feature.
- **Status**: **Has**, **Partial**, **Missing** or **In progress**. Each status was checked with `grep` over `Sources/`;
  the evidence is given in brackets. Paths are relative to `Sources/CoolDock/`.
- **Complexity**: Low / Medium / High, and the parts of the code it touches.
- **Priority**: 1 (skip for now) to 5 (do next), with a one-line reason.
- **Don't Go**: what not to build as part of the feature.

**Backend flag.** No feature here needs a NiceDock server. A few call a third-party cloud API with the user's own
token (Todoist, Slack, Teams, GitHub, GitLab). They are marked **[3rd-party API]** and work the same way as the
existing Connected widgets. One feature that would need hosting is marked **[hosting]**, together with a static,
backend-free alternative.

## 1. What NiceDock ships today (baseline)

Sources: `README.md`, `docs/WIDGET_GUIDE.md`, `docs/ai-assistant.md`, `Core/WidgetCatalog.swift`, `Core/Settings.swift`.

- **111 widget kinds** in 9 groups: apps and files (App, App Folder, Applications, Trash, Folder, Downloads, Recent Files,
  File Shelf, AirDrop, Dropbox, Find Files, App Switcher, Running Apps); clocks and focus (Flip, Analog, World, Pixel, Timer,
  Stopwatch, Pomodoro, Drink Water, Posture…); calendar and tasks (Today, Agenda, Week, Next Meeting with one-click join for
  Zoom, Meet, Teams, Webex and others, progress rings, Reminders, Todo, Habit Tracker, Linear); 9 weather widgets (Open-Meteo,
  no key); system (Battery, CPU, Memory, Storage, Temperature, CPU History, Network, Devices Battery, Audio output switching,
  per-app App Volume, Quick Toggles, Clipboard history, Screenshots, Voice Memo, Emoji); utilities (Color Picker, Converter,
  Calculator, Bookmarks, Search Web, Window Manager with snap layouts); media (Now Playing from any app, Background Sounds,
  YouTube, Recent Photo, Wallpaper, Mail, Notes, Contacts); markets (stocks, crypto); Connected (Stripe, Polar, Dodo, Shopify,
  Plausible, Simple Analytics, DataFast, Dub, Resend, GitHub, Supabase, X, TikTok, YouTube, AI Usage for Claude Code, Codex,
  Cursor, Copilot, Gemini and more).
- **Layout**: 7 scenarios (Swap at the Bottom, Reveal at the Bottom, Fixed at 6 positions, Reveal on Top, Replace the macOS Dock,
  Replace & Auto-Hide, Floating); one / attached / all displays; Reserve Dock Space moves other windows off the Dock
  (Accessibility); hide in full screen; show and hide delays; trigger size.
- **Profiles**: up to 8, switched by hover tabs, swipe or ⌃⌥⌘0…7.
- **Widget visibility rules**: always, while playing, CPU / memory / temperature high, low battery, before meetings, in a Zoom
  meeting, while an app is running (`Core/Models.swift` `VisibilityRule`).
- **Apps**: app tiles with badges read through Accessibility (`Widgets/Apps/AppsBadges.swift`), right-click
  window list, New Window / private window / browser profiles, Open Recent, ⌥ Force Quit, files dropped on an app tile open
  with that app.
- **Appearance**: 6 dock styles (incl. Liquid Glass), 4 widget surfaces, light / dark / auto, size, spacing, radius,
  monochrome, reduce transparency, icon styles, shadow, animations.
- **Language**: 10 languages, full RTL, Persian with Estedad, Solar Hijri calendar, Persian digits.
- **AI Assistant**: stdio MCP server (`NiceDock --mcp`) with 14 tools, read-only by default; local procedural wallpaper painter.
- **Platform**: Sparkle auto-update, Homebrew cask, diagnostics export (`App/StatusItemController.swift`), demand-driven
  services, ~30 MB memory, 476 tests.
- **In progress**: a vertical dock on the left or right screen edge.

## 2. Competitor landscape

| Product | Type | What matters for NiceDock |
| --- | --- | --- |
| **CoolDock** (AppitStudio) | Second Dock with 160+ live widgets; €14.99/yr or €29.99 lifetime | The design inspiration. Public roadmap with ~160 user requests: vertical dock, Home Assistant, Slack and Teams, widget templates, layout copying between Macs, community widgets, per-display profiles, hover previews, Smart Auto-Hide, notch trigger. |
| **uBar 4/5** (Brawer) | Dock replacement and taskbar | Window previews and grouping, app flashes / progress / status / per-app CPU+RAM, all four edges, multi-row, a bar on every monitor, disk eject, Bluetooth devices, "Command" (type or speak to control the Mac). |
| **ActiveDock 2** (MacPlus) | Customizable Dock replacement | Start menu launcher, window previews, groups and folders, custom icons, themes, any edge and position, multi-monitor, app exclusion. |
| **DockDoor** | Free OSS add-on to the macOS Dock (Pro beta $20) | Hover window previews, ⌥Tab window switcher, folder pop, synced lyrics, gestures, AppleScript and CLI control, no analytics. |
| **Docky** (GPLv3) | Dock replacement | Smart Stacks, community `.dockywidget` bundles through a widget store, fullscreen Launchpad, live window switcher, custom icons, scripted actions, themes and profiles. |
| **Docktor** (pre-release) | Widgets in the empty space beside the Dock | Four widgets plus hover previews; shows that "widgets next to the Dock" is a growing niche. |
| **Dockset** (Oct 2026) | Several Docks, switched by gesture / hotkey / Focus | Focus-mode switching, extra Dock with Apple-style widgets, AirDrop drop zone, settings export, no account. |
| **DockFlow** | Dock presets (Setapp, $14.99/yr) | Presets that launch apps, browser profiles and IDE projects; Shortcuts and Focus integration. |
| **DockFix** | Dock customizer and replacement (€14.99) | Native-looking magnification, window previews, custom app icons, community presets / themes. |
| **Dockside** (Hachipoo) | File shelf beside the Dock ($5.99) | Drop zones with actions (Clop, Dropshare, Shortcuts, scripts), quick notes, clipboard history, offline, no data collection. |
| **HyperDock** | Window previews for the macOS Dock | Large previews incl. minimized windows, special previews for Calendar and music; marked discontinued on AlternativeTo. |
| **Übersicht**, **SketchyBar** | Scriptable desktop widgets / status bar | Shell command → widget, refresh interval, per-display and per-space config, plugin ecosystems. |
| **WidgetWall**, **Widgetsmith**, macOS desktop widgets | Desktop widgets | Countdown / count-up, photo frames, sizes and colours per widget; Apple's widgets come in small/medium/large. |
| **Raycast** | Launcher with extensions and AI | Extension store, Quick AI, floating notes; sets user expectations for type-to-do-anything. |
| **Stats**, **iStat Menus 7** | System monitors | GPU, fans, sensors, Bluetooth devices, public IP; iStat **Rules** notify on CPU, disk, network, weather; no analytics. |
| **Bartender 7**, **Ice** | Menu bar managers | **Triggers** (show battery when unplugged, VPN on public Wi-Fi, mic in meetings), profiles, notch handling, search. |
| **Hammerspoon** | Lua automation | Power users script window and app behaviour; shows demand for scriptable hooks. |

**What drives adoption and retention in this category** (from the sources and the CoolDock roadmap):

1. *First-minute value*: a good layout without setup (templates, sensible defaults). Utility apps lose most users in the
   first sessions, so the first "aha" has to happen during onboarding.
2. *Context awareness*: the setup changes by itself with the time, Focus, display or task (DockFlow, Dockset, Bartender
   Triggers, iStat Rules). This is what makes users keep an app running all day.
3. *Window handling*: hover previews and a window switcher are the most common features in Dock replacements (uBar,
   ActiveDock, DockDoor, Docky, DockFix, Docktor).
4. *Extensibility*: scripts, plugins and community widgets (Übersicht, SketchyBar, Docky, Raycast) create long-tail value
   and community content.
5. *Safety of experimentation*: export, import, undo, sync between Macs. Several CoolDock roadmap requests ask for this.
6. *Trust*: privacy statements (DockDoor, Dockside, iStat Menus), no subscription, notarized builds.

## 3. Proposed features

### A. Dock layout and placement

#### 1. Vertical dock on the left or right edge
- **What:** Run NiceDock as a vertical column on the left or right edge, with widgets stacked top to bottom.
- **Join / stay:** The most visible layout request; wide screens have spare horizontal space, and users with a left-side
  macOS Dock can't use NiceDock comfortably today.
- **Competitors:** uBar, ActiveDock, Dockside (any edge); CoolDock roadmap ("Vertical CoolDock layout alongside the native Dock", "SideCoolDock").
- **Status:** **In progress** (being built now; no vertical cases in `Core/Settings.swift` `ScreenPosition` yet).
- **Complexity:** High · `App/DockController.swift`, `App/DockRootView.swift`, `Core/Settings.swift`, every widget's width/height
  assumptions, Reserve Dock Space, MCP `set_layout`.
- **Priority:** 5 — the most-requested layout and already under way; finish it before new layouts.
- **Don't Go:** Don't build a second set of "vertical" widget designs; reuse the 62 pt tile and let wide widgets open as panels.

#### 2. Follow the macOS Dock's position and size
- **What:** Read the system Dock's orientation (`com.apple.dock` `orientation`, `tilesize`) and place NiceDock so the two never
  overlap; offer "match native Dock height".
- **Join / stay:** Removes a whole class of "it overlaps my Dock" bugs that make people uninstall in the first hour.
- **Competitors:** CoolDock roadmap ("App dock position breaks when the macOS Dock is vertical", "Match native Dock height").
- **Status:** **Missing** (`App/SystemDock.swift` reads only `autohide`; `grep orientation` finds nothing).
- **Complexity:** Low · `App/SystemDock.swift`, `App/DockController.swift`.
- **Priority:** 4 — cheap and it protects first impressions; pairs naturally with the vertical dock.
- **Don't Go:** Don't write the user's Dock preferences beyond what the Replace scenarios already back up and restore.

#### 3. Notch-aware top layout
- **What:** On MacBooks with a notch, split a top-edge dock around the notch, or use the notch as the reveal trigger.
- **Join / stay:** Laptop users are the majority; a top dock that hides under the notch looks broken.
- **Competitors:** Bartender ("Beat the notch"); CoolDock roadmap ("Notch-specific trigger and expanding dock layout").
- **Status:** **Missing** (no `safeAreaInsets` / `auxiliaryTopLeftArea` in `Sources/`).
- **Complexity:** Medium · `App/DockController.swift`, reveal triggers, `Core/Settings.swift`.
- **Priority:** 3 — good for laptop users of Reveal on Top, but a smaller audience than bottom layouts.
- **Don't Go:** Don't build a "Dynamic Island" clone with animations and notifications; keep it a layout option.

#### 4. Per-display profiles
- **What:** Let each display show its own profile (e.g. apps on the laptop, analytics on the external monitor).
- **Join / stay:** Multi-monitor users are heavy users; giving each screen a job makes NiceDock part of the desk setup.
- **Competitors:** uBar ("Every monitor. Its own bar."), SketchyBar (per-display config); CoolDock roadmap ("Use Multiple Cooldocks Simultaneously with Different Profiles").
- **Status:** **Missing** (`ScreensMode` is one / attached / all, all showing the active profile; no per-display profile key).
- **Complexity:** Medium · `Core/Settings.swift` (`KnownDisplay`), `App/DockController.swift`, profile switcher, MCP `switch_profile`.
- **Priority:** 4 — strong pull for the power-user segment, and the per-display panels already exist.
- **Don't Go:** Don't allow different appearance per display in v1; profile only.

#### 5. Two docks at once
- **What:** Run a second NiceDock bar at another edge (e.g. widgets on top, apps at the bottom), each with its own profile.
- **Join / stay:** Lets users split "glanceable info" from "launching", a layout CoolDock users already try to fake.
- **Competitors:** Dockset (several Docks); CoolDock roadmap ("Windows respect top CoolDock and bottom native Dock").
- **Status:** **Missing** (one `scenario` / `fixedPosition` per app in `Core/Settings.swift`).
- **Complexity:** High · `App/DockController.swift`, `Core/AppStore.swift` (docks as a list), Reserve Dock Space, Settings UI.
- **Priority:** 2 — real demand, but per-display profiles cover most of it for less work.
- **Don't Go:** Don't go beyond two bars; no free-form desktop widget canvas (that is a different product).

#### 6. Hover magnification and launch feedback
- **What:** Optional magnification of app tiles on hover and a bounce or pulse while an app launches.
- **Join / stay:** Makes NiceDock feel like a real Dock; users who replace the macOS Dock miss this feedback.
- **Competitors:** DockFix ("same magnification"), macOS Dock; CoolDock roadmap ("bounce effect just like mac dock").
- **Status:** **Missing** (`grep magnif` only finds the `magnifyingglass` symbol; no launch bounce).
- **Complexity:** Medium · `Widgets/Apps/AppsUI.swift`, `App/DockRootView.swift` (layout must not jitter), Appearance settings.
- **Priority:** 2 — polish rather than a reason to install; keep it off by default.
- **Don't Go:** Don't magnify widgets, only app tiles; don't let magnification resize the panel window.

#### 7. Multi-row dock
- **What:** Let the dock grow to two or three rows (or columns in vertical mode) instead of scrolling or shrinking.
- **Join / stay:** Users who add many widgets hit the width limit; rows keep everything visible.
- **Competitors:** uBar ("Expandable Rows", up to five); CoolDock roadmap ("Adaptive sizing without scrolling").
- **Status:** **Partial** (`OverflowMode` adapt or scroll only).
- **Complexity:** High · `App/DockRootView.swift`, reorder logic, Reserve Dock Space height.
- **Priority:** 2 — useful at the edges, but conflicts with the "slim strip" design; revisit after the vertical dock.
- **Don't Go:** Don't build a grid editor; rows fill in order.

### B. Profiles and automation

#### 8. Switch profiles with Focus modes
- **What:** Map each macOS Focus (Work, Personal, Sleep…) to a profile, applied when the Focus changes, using a Focus Filter
  (App Intents `SetFocusFilterIntent`).
- **Join / stay:** "My dock changes when I start work" is the stickiest behaviour in this category, and it uses a system
  feature users already set up.
- **Competitors:** Dockset, DockFlow (Shortcuts and Focus integration), Bartender (profiles).
- **Status:** **Missing** (no `AppIntent` or `FocusFilter` in `Sources/`).
- **Complexity:** Medium · new `App/Intents/`, `Core/AppStore.swift` (switch profile), Settings → Profiles.
- **Priority:** 5 — high retention value, small surface, fully local.
- **Don't Go:** Don't read the Focus state through private APIs or the DND database; use the public Focus Filter.

#### 9. Context rules for profiles
- **What:** Switch profile automatically by time of day / weekday, connected display, frontmost app, power source or Wi-Fi
  network.
- **Join / stay:** Turns NiceDock into an ambient tool that is always right without effort; the reason users keep Bartender
  and iStat Menus running.
- **Competitors:** Bartender (Triggers), iStat Menus (Rules), DockFlow (presets per task).
- **Status:** **Missing** (`grep autoSwitch|profileRule|SSID` finds nothing).
- **Complexity:** Medium · new rule evaluator next to `Services/VisibilityEvaluator.swift`, Settings → Profiles, MCP.
- **Priority:** 5 — core of the "smart dock" promise and reuses the demand-driven services.
- **Don't Go:** Don't use location services for "at home / at work"; Wi-Fi name (needs Location permission on macOS 14+) or
  display set is enough. No rule scripting language.

#### 10. Appearance and layout per profile
- **What:** Optionally store dock style, scenario and position in a profile, so "Focus" can be a slim black bar and "Home" a
  glass dock.
- **Join / stay:** Makes profiles feel like real modes, not just widget lists.
- **Competitors:** CoolDock roadmap ("Include appearance and other settings in the Profile"); Docky (themes and profiles).
- **Status:** **Missing** (`DockProfile` holds only `name`, `symbol`, `widgets`).
- **Complexity:** Medium · `Core/Models.swift`, `Core/AppStore.swift`, Settings → Profiles, MCP `create_profile`.
- **Priority:** 3 — nice multiplier for features 8 and 9, but not needed for them.
- **Don't Go:** Don't duplicate every setting per profile; keep language, shortcuts and privacy global.

#### 11. More widget visibility rules
- **What:** Add rules: charging / on battery, time window, Focus active, app frontmost (not just running), display
  connected, Wi-Fi network, during any calendar event.
- **Join / stay:** Widgets that appear only when they matter keep the dock short and useful.
- **Competitors:** Bartender (Triggers), iStat Menus (Rules); CoolDock roadmap ("Widget Triggers", "add condition display widget").
- **Status:** **Partial** (9 rules in `VisibilityRule`, `Services/VisibilityEvaluator.swift`).
- **Complexity:** Low · `Core/Models.swift`, `Services/VisibilityEvaluator.swift`, widget menu, MCP schemas.
- **Priority:** 4 — cheap extension of a working system with visible payoff.
- **Don't Go:** Don't add AND/OR rule combinations yet; one rule per widget.

#### 12. Apple Shortcuts actions
- **What:** App Intents for: switch profile, show / hide dock, start a timer or Pomodoro, add a todo, toggle a widget, run
  "set wallpaper".
- **Join / stay:** Lets NiceDock join users' existing automations (Shortcuts, Stream Deck, Raycast), which raises switching cost.
- **Competitors:** DockFlow, Dockside (Shortcuts integration), DockDoor (AppleScript and CLI).
- **Status:** **Missing** (no `AppIntent` / `AppShortcutsProvider` in `Sources/`).
- **Complexity:** Medium · new `App/Intents/`, `MCP/DockTools.swift` (reuse validated actions), build script (intents metadata).
- **Priority:** 5 — one action layer serves Shortcuts, Focus filters and the URL scheme.
- **Don't Go:** Don't expose secrets or Connected-widget data through intents.

#### 13. `nicedock://` URL scheme
- **What:** URLs such as `nicedock://profile/Work`, `nicedock://toggle`, `nicedock://widget/<id>/refresh`.
- **Join / stay:** Lets any launcher, browser bookmark or Stream Deck button drive NiceDock with zero setup.
- **Competitors:** DockDoor (scripting), Raycast (deeplinks).
- **Status:** **Missing** (the only `CFBundleURLSchemes` reference reads other apps' schemes in `Widgets/Apps/AppsIntegrations.swift`).
- **Complexity:** Low · `Info.plist` in `scripts/build-app.sh`, `App/AppDelegate.swift`, reuse of the intent actions.
- **Priority:** 4 — small and broad; ship it with feature 12.
- **Don't Go:** No URL action that changes settings without the same "Allow Changes" style switch the MCP server uses.

#### 14. Command-line control
- **What:** `NiceDock --cli profile Work`, `--cli toggle`, `--cli get` that talk to the running app through the existing
  assistant socket.
- **Join / stay:** Developers (a large part of NiceDock's Connected audience) script their setups.
- **Competitors:** DockDoor (CLI), SketchyBar (CLI-driven), Hammerspoon.
- **Status:** **Partial** (`NiceDock --mcp` speaks JSON-RPC only; no human CLI verbs).
- **Complexity:** Low · `App/main.swift`, `MCP/AssistantBridge.swift`.
- **Priority:** 3 — low effort because the socket and validation exist, but a narrower audience.
- **Don't Go:** Don't open a TCP port; keep the Unix socket with uid check.

#### 15. Profile launch actions
- **What:** When a profile activates, optionally open a set of apps, URLs or a folder, and hide apps not in the profile.
- **Join / stay:** "One click to start my work setup" is DockFlow's whole product.
- **Competitors:** DockFlow ("Launch your whole setup"), Dockset.
- **Status:** **Missing** (profile switch only swaps widgets).
- **Complexity:** Low · `Core/AppStore.swift`, Settings → Profiles.
- **Priority:** 3 — strong for some users, but must stay optional and quiet.
- **Don't Go:** Don't quit apps automatically; don't restore window positions (that's a window manager's job).

### C. Widget platform and extensibility

#### 16. Command widget (shell output)
- **What:** A widget that runs a user-written shell command on an interval and shows its output as a value, a line, a
  ring or a sparkline; click runs another command.
- **Join / stay:** Unlimited long-tail widgets without NiceDock writing each one; devs share snippets, which brings new users.
- **Competitors:** Übersicht, SketchyBar, Docky (scripted actions), Dockside ("Script It Your Way"), Hammerspoon.
- **Status:** **Missing** (no `/bin/sh` / `/bin/zsh` launch except a test stub in `Widgets/Connected/ConnAILocal.swift`).
- **Complexity:** Medium · new `Widgets/Utility/UtilCommand.swift`, `Core/WidgetCatalog.swift`, a `Process` runner with
  timeout and output cap.
- **Priority:** 5 — highest leverage per line of code; matches the developer audience.
- **Don't Go:** Don't let the MCP assistant create or edit commands (code execution); don't run commands as root; no
  HTML/JS rendering.

#### 17. JSON / URL value widget
- **What:** Point at any URL (local or remote), pick a JSON path, and show the value with a label, unit and optional
  threshold colours.
- **Join / stay:** Covers home servers, uptime pages, build counters and any API without coding.
- **Competitors:** Übersicht (fetch-based widgets), SketchyBar plugins, iStat Menus (public IP / network checks).
- **Status:** **Missing** (no generic HTTP widget; `Net.json` exists for built-in widgets).
- **Complexity:** Low · new widget, `Net.json`, `DiskCache`, `Secrets` for an optional header token.
- **Priority:** 4 — small, safe and broad; a good partner to the command widget.
- **Don't Go:** Don't build a visual API designer or OAuth flows; one URL, one header, one path.

#### 18. Smart Stacks
- **What:** Stack several widgets in one slot; scroll or swipe to flip, with optional auto-rotate by relevance (next meeting
  first, Now Playing while playing).
- **Join / stay:** More information in the same strip; the idea is familiar from iOS and macOS widgets.
- **Competitors:** Docky (Smart Stacks), Apple widgets (Smart Stack).
- **Status:** **Missing** (`grep smartStack|WidgetStack` finds nothing).
- **Complexity:** Medium · `Core/Models.swift` (`WidgetInstance` children), `App/DockRootView.swift`, `Widgets/WidgetHost.swift`, browser drag.
- **Priority:** 4 — big perceived value, and it reuses the visibility rules for relevance.
- **Don't Go:** No machine-learned ranking; relevance comes from the existing rules.

#### 19. Widget size variants
- **What:** Small / medium / large widths for widgets where it makes sense (weather, calendar, stocks), chosen in Customize.
- **Join / stay:** Users want to trade detail for space; a common CoolDock roadmap complaint.
- **Competitors:** Apple widgets, WidgetWall (size per widget); CoolDock roadmap ("Widget square size - next event").
- **Status:** **Missing** (width is fixed per kind in `WidgetSpec.width`).
- **Complexity:** Medium · `Core/WidgetCatalog.swift`, affected widget views, pixel-diff references.
- **Priority:** 3 — useful, but each variant is design and test work; start with 5–6 widgets.
- **Don't Go:** Don't allow free-form resizing by dragging.

#### 20. Shareable widget and layout files
- **What:** Export a widget (with settings, without secrets) or a whole profile as a small `.nicedock` JSON file; double-click
  to import.
- **Join / stay:** Users share setups on Reddit and X, which is free marketing; builds a community library.
- **Competitors:** Docky (`.dockywidget` bundles), DockFix (community presets); CoolDock roadmap ("Community-created widgets", "Ready-Made Widget Templates & Layouts").
- **Status:** **Missing** (no import / export; the only `NSSavePanel` writes diagnostics).
- **Complexity:** Low · `Core/AppStore.swift`, `Core/Models.swift` (Codable already), document type in `Info.plist`.
- **Priority:** 4 — low effort, enables features 56 and 57.
- **Don't Go:** A hosted gallery would need **[hosting]**; use a GitHub repo of files linked from the website instead.
  Never include Keychain secrets or contacts in exports.

#### 21. Web clip widget
- **What:** Show a small region of a web page (status page, dashboard tile), refreshed on an interval, in a panel or tile.
- **Join / stay:** Covers services NiceDock will never integrate.
- **Competitors:** WidgetWall (browser widget); CoolDock roadmap ("Interactive shortcuts inside web widgets").
- **Status:** **Missing** (no `WKWebView` in `Sources/`).
- **Complexity:** Medium · new widget family, `WKWebView` in a panel, non-persistent data store by default.
- **Priority:** 2 — WebKit costs 30–80 MB per view, which goes against NiceDock's memory budget.
- **Don't Go:** No always-live web view in the tile; render a snapshot and open the live page only in the panel.

#### 22. Host Apple WidgetKit widgets
- **What:** Show other apps' WidgetKit widgets inside NiceDock.
- **Join / stay:** Would unlock thousands of widgets.
- **Competitors:** None in this category (Dockset says Apple widgets are not supported).
- **Status:** **Missing** (no `WidgetKit` in `Sources/`).
- **Complexity:** High · needs private Chrono / WidgetKit hosting APIs.
- **Priority:** 1 — no public API; it would break on each macOS release.
- **Don't Go:** Don't build it. Point users to macOS desktop widgets and keep NiceDock's own catalog.

### D. Apps and windows

#### 23. Window previews on hover
- **What:** Hover an app tile to see thumbnails of its windows (incl. minimized and other Spaces), click to focus,
  buttons to close or minimize.
- **Join / stay:** The single most common feature across Dock apps; people who replace the macOS Dock expect it.
- **Competitors:** uBar, ActiveDock, HyperDock, DockDoor, Docky, DockFix, Docktor; CoolDock roadmap ("Preview on hover for pinned apps").
- **Status:** **Partial** (window list in the right-click menu, `Widgets/Apps/AppsAppMenu.swift`; no thumbnails, no `ScreenCaptureKit`).
- **Complexity:** High · ScreenCaptureKit, Screen Recording permission, `App/Panels.swift`, `Widgets/Apps/`.
- **Priority:** 4 — big draw, but Screen Recording permission costs trust; make it opt-in and text-only without it.
- **Don't Go:** Don't keep captures after the preview closes or write them to disk; don't capture continuously.

#### 24. Window switcher (⌥Tab)
- **What:** A keyboard switcher that lists every window (not just apps), with type-to-filter.
- **Join / stay:** A daily habit that makes the app hard to remove.
- **Competitors:** DockDoor, Docky, uBar.
- **Status:** **Partial** (App Switcher widget jumps between running apps by click only).
- **Complexity:** High · `App/HotKeys.swift`, AX window list (`App/WindowEvents.swift`), new panel.
- **Priority:** 2 — DockDoor and AltTab already do this well and free; it doesn't grow the widget story.
- **Don't Go:** Don't replace ⌘Tab system-wide by default.

#### 25. Custom app icons
- **What:** Choose an image or SF Symbol for any app or folder tile in NiceDock.
- **Join / stay:** Personalization drives screenshots and sharing.
- **Competitors:** ActiveDock, Docky, DockFix; CoolDock roadmap ("Custom App Icons?", "Folder coloring").
- **Status:** **Missing** (no icon override in `Sources/`; `AppIconStyle` changes all icons at once).
- **Complexity:** Low · `Widgets/Apps/AppsUI.swift`, `IconCache`, widget config.
- **Priority:** 3 — cheap and loved, but cosmetic.
- **Don't Go:** Don't change the icon inside the app bundle or in Finder; NiceDock-only.

#### 26. App attention and status signals
- **What:** Flash a tile when an app requests attention, mark unresponsive apps, show a progress ring for downloads or exports
  when the app exposes one.
- **Join / stay:** Running Apps becomes more useful than the macOS Dock section it replaces.
- **Competitors:** uBar (App Flashes, App Status, App Progress).
- **Status:** **Partial** (badges via `AXStatusLabel` in `Widgets/Apps/AppsBadges.swift`; no attention or hang state).
- **Complexity:** Medium · Accessibility observers, `Widgets/Apps/AppsLaunchers.swift`.
- **Priority:** 2 — useful for people in Replace mode only.
- **Don't Go:** No sounds; don't poll every app every second.

#### 27. Per-app CPU and memory on demand
- **What:** Hold a modifier key over Running Apps to show each app's CPU and memory; click to quit the heaviest.
- **Join / stay:** Connects system widgets with apps, a uBar favourite.
- **Competitors:** uBar (App Activity), iStat Menus, Stats.
- **Status:** **Partial** (top processes in `Widgets/System/SysDetailsPanel.swift`; not on app tiles).
- **Complexity:** Low · `Widgets/Apps/AppsLaunchers.swift`, existing `ps` sampling.
- **Priority:** 2 — nice, but the details panel already answers the question.
- **Don't Go:** Don't sample while the modifier is not held.

#### 28. Launcher with type-to-search
- **What:** A fullscreen or panel launcher for every app with keyboard navigation and fuzzy search, opened by hotkey or the
  Applications tile.
- **Join / stay:** Launchpad was removed in macOS 26; users look for a replacement.
- **Competitors:** Docky (Built-in Launchpad), ActiveDock (Start Menu), Raycast, uBar (uBar Menu).
- **Status:** **Partial** (Applications widget browses apps; no global hotkey or fuzzy search).
- **Complexity:** Medium · `Widgets/Apps/AppsLaunchers.swift`, `App/HotKeys.swift`, `App/Panels.swift`.
- **Priority:** 3 — timely because of the Launchpad change, but Raycast/Spotlight cover search.
- **Don't Go:** Don't become a command launcher with extensions; launch apps, files and widgets only.

#### 29. Minimized-window shelf
- **What:** A widget that collects minimized windows as titled chips, one click to restore.
- **Join / stay:** Fixes a long-standing macOS pain point, especially in Replace mode.
- **Competitors:** uBar (window grouping); CoolDock roadmap ("Dedicated view for minimized apps or windows").
- **Status:** **Partial** (minimized windows appear in the right-click window list, `kAXMinimizedAttribute` in `Widgets/Apps/AppsAppMenu.swift`).
- **Complexity:** Medium · `App/WindowEvents.swift`, new widget.
- **Priority:** 3 — clear value for Replace-mode users and reuses the AX observers.
- **Don't Go:** No live thumbnails here (see feature 23).

#### 30. Exclude apps from Running Apps
- **What:** Hide chosen apps (menu-bar utilities, helpers) from the Running Apps section.
- **Join / stay:** Removes clutter users complain about early.
- **Competitors:** ActiveDock ("Hiding and excluding Applications"); CoolDock roadmap ("Option to hide specific active apps").
- **Status:** **Missing** (no exclude list in `Core/Settings.swift` or `Widgets/Apps/AppsLaunchers.swift`).
- **Complexity:** Low · `Core/Settings.swift`, right-click menu on running app tiles.
- **Priority:** 3 — tiny, removes friction.
- **Don't Go:** No regex rules; a simple list by bundle id.

### E. System and monitoring

#### 31. Local alert rules and notifications
- **What:** Notify when CPU stays high, disk is nearly full, battery is low, network is down, a meeting starts in 5 minutes, or
  rain begins within the hour; optional sound.
- **Join / stay:** Proactive value even when the dock is hidden; iStat Menus users name this as a reason to stay.
- **Competitors:** iStat Menus (Rules), Bartender (Triggers).
- **Status:** **Partial** (visibility rules show widgets; notifications are only sent by timers in `Widgets/Clock/ClockTimerEngine.swift`).
- **Complexity:** Medium · `Services/VisibilityEvaluator.swift`, `UNUserNotificationCenter`, Settings.
- **Priority:** 4 — reuses existing monitors and gives a reason to keep NiceDock running.
- **Don't Go:** No push notifications from a server; no notification history UI.

#### 32. GPU, power and fan sensors
- **What:** GPU usage, package power (W) and fan speed rings and graphs.
- **Join / stay:** Completes the system-monitor set that Stats users expect.
- **Competitors:** Stats, iStat Menus.
- **Status:** **Missing** (only temperature; `grep GPU` finds comments, no sampler).
- **Complexity:** Medium · `Services/SystemMonitor.swift` (IOReport / SMC), new rings.
- **Priority:** 3 — expected by monitor users, but Stats is free; do GPU first.
- **Don't Go:** No fan control (Stats itself marks it unmaintained); read-only.

#### 33. Network details
- **What:** Wi-Fi name and signal, local and public IP, latency to a host, VPN on/off.
- **Join / stay:** A glance answer to "is it my network?", a daily question for remote workers.
- **Competitors:** iStat Menus, Stats, Bartender (VPN trigger).
- **Status:** **Missing** (`grep SSID|publicIP|VPN` finds nothing; Network widget shows throughput).
- **Complexity:** Low · `Services/SystemMonitor.swift`, CoreWLAN (already linked), Network framework.
- **Priority:** 3 — useful and cheap.
- **Don't Go:** Public IP lookup is a third-party request; make it opt-in and name the service.

#### 34. Disks widget with Eject All
- **What:** List mounted external volumes with free space and one-click eject (single or all).
- **Join / stay:** A frequent laptop chore made one click.
- **Competitors:** uBar ("Safely eject every external drive in one click").
- **Status:** **Missing** (no `DiskArbitration` / eject code).
- **Complexity:** Low · new widget, `NSWorkspace.unmountAndEjectDevice`.
- **Priority:** 3 — small and practical.
- **Don't Go:** No disk formatting or repair.

#### 35. AirPods and case battery
- **What:** Show left, right and case battery for AirPods and Beats, with a wider design.
- **Join / stay:** Highly visible daily info; a top CoolDock request.
- **Competitors:** Stats (Bluetooth devices); CoolDock roadmap ("airpods battery widget should show the case battery").
- **Status:** **Partial** (`Widgets/System/SysDevicesBattery.swift` shows one level per device).
- **Complexity:** Medium · Bluetooth battery keys are not public for the case; needs testing per model.
- **Priority:** 3 — loved, but data access is fragile.
- **Don't Go:** No private Bluetooth frameworks; show case battery only when the system reports it.

#### 36. Microphone mute and in-use indicator
- **What:** A toggle to mute the default input device, with a red state while any app uses the mic.
- **Join / stay:** Meeting-heavy users want a reliable mute button in view.
- **Competitors:** Bartender (mic trigger in meetings), uBar (sound inputs).
- **Status:** **Missing** (`Widgets/Utility/UtilAudio.swift` handles output only).
- **Complexity:** Low · CoreAudio input device properties.
- **Priority:** 3 — fits the existing Zoom-meeting visibility rule.
- **Don't Go:** Don't record or analyse audio.

### F. Productivity, calendar and focus

#### 37. Countdown and count-up widget
- **What:** Days / hours until (or since) a date: a launch, a trip, a birthday; optional progress bar.
- **Join / stay:** Emotional, shareable widget; easy to understand in onboarding.
- **Competitors:** WidgetWall (countdown, countup).
- **Status:** **Missing** (only the Timer widget counts down minutes).
- **Complexity:** Low · `Widgets/Clock/`, `Core/WidgetCatalog.swift`.
- **Priority:** 4 — cheap, popular, works fully offline and in Persian calendars.
- **Don't Go:** No event sharing or reminders; that's the calendar's job.

#### 38. Project time tracker
- **What:** Start / stop timers per project from the dock, with today's totals and a CSV export.
- **Join / stay:** Freelancers live in this; it gives a daily reason to click NiceDock.
- **Competitors:** CoolDock roadmap ("Simple Project Time Tracking for the Clock Widget").
- **Status:** **Missing** (Stopwatch has no projects or history).
- **Complexity:** Medium · `Widgets/Clock/ClockTimerEngine.swift`, local storage, export.
- **Priority:** 3 — clear audience, local data only.
- **Don't Go:** No invoicing, no sync to Toggl/Harvest in v1.

#### 39. Focus status and toggle
- **What:** Show the current Focus and switch Focus from Quick Toggles (via a Shortcut the user installs once).
- **Join / stay:** Goes together with Pomodoro and profile switching.
- **Competitors:** Bartender, Dockset (Focus integration).
- **Status:** **Partial** (Quick Toggles has Wi-Fi, Bluetooth, dark mode, keep awake, keyboard lock, hide desktop; no Focus).
- **Complexity:** Medium · `Widgets/Utility/UtilToggles.swift`, Shortcuts run via `shortcuts` CLI, Focus Filter intent.
- **Priority:** 3 — completes features 8 and 12.
- **Don't Go:** Don't edit the Focus database or use private DND APIs.

#### 40. Things, Todoist and OmniFocus tasks
- **What:** Show today's tasks from Things (AppleScript), OmniFocus (AppleScript) or Todoist **[3rd-party API]**; check off
  from the dock.
- **Join / stay:** Many users don't use Reminders; their task app decides whether NiceDock is useful.
- **Competitors:** Raycast extensions; CoolDock (Linear, Reminders).
- **Status:** **Missing** (`grep Things|Todoist|OmniFocus` finds nothing; Reminders, Todo and Linear exist).
- **Complexity:** Medium · new Connected widgets, Automation permission, `Secrets` for the Todoist token.
- **Priority:** 3 — Things first (local, popular on Mac).
- **Don't Go:** No full task editor; view, complete, quick add.

#### 41. Clipboard pins and search
- **What:** Pin snippets in the clipboard history and search it from the panel.
- **Join / stay:** Turns Clipboard into a daily tool rather than a novelty.
- **Competitors:** Bartender (Command Bar clipboard history), Dockside (clipboard history), Raycast.
- **Status:** **Partial** (history in `Widgets/Utility/UtilClipboard.swift`; no pins or search).
- **Complexity:** Low · `UtilClipboard.swift`.
- **Priority:** 3 — cheap upgrade of an existing widget.
- **Don't Go:** Never save password-manager items (respect `org.nspasteboard.ConcealedType`); no cloud sync of the history.

#### 42. RSS / news headlines
- **What:** Rotate the latest headlines from user-added RSS / Atom feeds; click opens the article.
- **Join / stay:** A light "glance" widget that refreshes all day.
- **Competitors:** Übersicht community widgets, Raycast extensions.
- **Status:** **Missing** (the only `rss` match is process memory in `SysDetailsPanel.swift`).
- **Complexity:** Low · `XMLParser`, `DiskCache`, new widget.
- **Priority:** 2 — easy, but news widgets are distracting for the focus audience.
- **Don't Go:** No built-in news service or recommended feeds list that needs curation.

#### 43. Weather extras: air quality, UV, rain soon
- **What:** AQI and UV from Open-Meteo's free air-quality API, and a "rain in 20 min" line from minutely precipitation.
- **Join / stay:** Weather is the most used widget category; small additions are noticed.
- **Competitors:** iStat Menus (weather, cloud cover); CoolDock roadmap ("Weather Radar").
- **Status:** **Partial** (current precipitation in `Services/WeatherService.swift`; no AQI or nowcast).
- **Complexity:** Low · `Services/WeatherService.swift`, weather widgets.
- **Priority:** 3 — low cost, no key needed.
- **Don't Go:** No radar map tiles (heavy and needs a tile provider).

#### 44. On-device translate and define
- **What:** Type or paste text to translate (Apple Translation framework, macOS 15+) or look up in the system dictionary.
- **Join / stay:** Valuable for the 10-language audience; works offline.
- **Competitors:** Raycast (translate extensions).
- **Status:** **Missing** (`grep Translation` finds only key translation in `App/HotKeys.swift`).
- **Complexity:** Low · new utility widget; macOS 15 availability check.
- **Priority:** 2 — useful but outside the dock's core.
- **Don't Go:** No cloud translation APIs.

#### 45. File Shelf drop actions
- **What:** Drop zones on the shelf: AirDrop, compress to ZIP, convert image to JPEG/PNG, move to a chosen folder, run a Shortcut.
- **Join / stay:** File handling is a daily pain; shelf apps sell on this.
- **Competitors:** Dockside (four drop zones, Clop, Dropshare, Shortcuts), Dockset (AirDrop zone).
- **Status:** **Partial** (File Shelf and AirDrop widgets exist separately, `Widgets/Apps/AppsFiles.swift`).
- **Complexity:** Medium · `AppsFiles.swift`, `NSSharingService`, Shortcuts CLI.
- **Priority:** 3 — sharpens an existing widget against a paid competitor.
- **Don't Go:** No cloud upload service of NiceDock's own.

### G. Connected and developer widgets

#### 46. CI / pipeline status
- **What:** Last runs of GitHub Actions or GitLab CI pipelines for chosen repos, red/green, click to open **[3rd-party API]**.
- **Join / stay:** Developers already use the GitHub widget; build status is something they check many times a day.
- **Competitors:** CoolDock (GitHub, Linear, Supabase widgets), Raycast extensions.
- **Status:** **Partial** (GitHub contributions only, `Widgets/Connected/ConnDeveloper.swift`; no GitLab).
- **Complexity:** Medium · `ConnDeveloper.swift`, `Secrets`, fixtures for tests.
- **Priority:** 4 — fits the developer audience and the Connected framework.
- **Don't Go:** No webhooks (would need a server); poll every 2–5 min while visible.

#### 47. Home Assistant
- **What:** Show entity states and toggle lights / scenes through the user's Home Assistant URL and long-lived token.
- **Join / stay:** Home Assistant users are vocal and share setups; it's local-network, not cloud.
- **Competitors:** CoolDock roadmap ("Home Assistant Integration").
- **Status:** **Missing** (`grep HomeKit|homeAssistant` finds nothing).
- **Complexity:** Medium · new Connected family, REST API, `Secrets`.
- **Priority:** 3 — strong community, small effort with the existing Connected scaffolding.
- **Don't Go:** No HomeKit (needs Catalyst / entitlement work); no automation editor.

#### 48. Slack and Teams presence
- **What:** Show and set your status / presence, and unread count **[3rd-party API]**.
- **Join / stay:** Work users ask for it; it pairs with meeting widgets.
- **Competitors:** CoolDock roadmap ("Slack Widgets", "Dedicated Microsoft Teams meeting status and controls").
- **Status:** **Missing** (`grep Slack` finds nothing).
- **Complexity:** High · OAuth app registration per vendor (client id ships in the app), token refresh.
- **Priority:** 2 — OAuth without a backend is awkward and vendor review is slow.
- **Don't Go:** No message reading or sending; status and counts only. No token exchange server.

#### 49. Local dev services: Docker and ports
- **What:** List running Docker containers and listening localhost ports, with open-in-browser and stop buttons.
- **Join / stay:** Developers check this constantly; no competitor dock does it.
- **Competitors:** Raycast extensions; none in Dock apps.
- **Status:** **Missing** (`grep -i docker` finds nothing).
- **Complexity:** Medium · Docker socket API, `lsof` parsing, new widget.
- **Priority:** 3 — a differentiator for NiceDock's developer niche.
- **Don't Go:** No container creation or compose editing.

#### 50. Live AI agent activity
- **What:** Show whether a Claude Code / Codex session is running now and its current task, plus Ollama / LM Studio
  loaded models.
- **Join / stay:** Extends the AI Usage widget, NiceDock's most distinctive Connected feature.
- **Competitors:** CoolDock roadmap ("Claude active session if agent is running", "Codex Usage").
- **Status:** **Partial** (AI Usage reads local logs for totals, `Widgets/Connected/ConnAILocal.swift`; no live session or Ollama).
- **Complexity:** Medium · log tailing on demand, Ollama `localhost:11434` API.
- **Priority:** 4 — on-trend, local-only, and nobody else does it well.
- **Don't Go:** Don't show prompt or code content from the logs; status and counts only.

#### 51. Website uptime check
- **What:** Ping a list of URLs every few minutes and show green/red plus response time.
- **Join / stay:** Indie makers (the Stripe / Plausible audience) want to know their site is up.
- **Competitors:** iStat Menus (connection rules), Übersicht widgets.
- **Status:** **Missing** (no URL health widget).
- **Complexity:** Low · new widget on `Net`, optional notification via feature 31.
- **Priority:** 3 — cheap and fits the maker audience.
- **Don't Go:** No status pages or history graphs beyond 24 h.

### H. Appearance

#### 52. Custom dock colour and background
- **What:** Pick any tint colour, gradient or image for the dock plate, with opacity.
- **Join / stay:** Personalization drives screenshots, which drive installs.
- **Competitors:** DockFix (colours, opacity), ActiveDock and uBar (themes).
- **Status:** **Partial** (6 fixed `DockStyle`s and 4 surfaces in `Core/Theme.swift`; no custom colour).
- **Complexity:** Low · `Core/Theme.swift`, Appearance pane, MCP `set_appearance`.
- **Priority:** 3 — cheap visual win.
- **Don't Go:** No per-widget colour pickers in v1.

#### 53. Wallpaper-matched colours
- **What:** Tint the dock and accents from the current wallpaper's dominant colours, updated when the wallpaper changes.
- **Join / stay:** "Looks built-in" is the top compliment in reviews of this category.
- **Competitors:** None in Dock apps; macOS tinted icons do something similar.
- **Status:** **Missing** (`grep dominantColor|averageColor` finds nothing).
- **Complexity:** Medium · `Core/Theme.swift`, wallpaper observer (`Widgets/Media/MediaPictures.swift` already watches Spaces).
- **Priority:** 2 — delightful but niche; ties in with the AI wallpaper painter.
- **Don't Go:** Don't re-render widgets on every Space switch; sample once per wallpaper.

#### 54. Theme files
- **What:** Save appearance settings as a theme file and apply others' themes.
- **Join / stay:** Community content without a server.
- **Competitors:** DockFix (community presets), ActiveDock (themes), Docky (themes).
- **Status:** **Missing** (no theme import / export).
- **Complexity:** Low · reuse feature 20's file format.
- **Priority:** 2 — follows naturally once feature 20 exists.
- **Don't Go:** **[hosting]** No in-app theme store; link a GitHub folder.

### I. Onboarding, data safety and retention

#### 55. Starter layouts gallery
- **What:** In onboarding and in the widget browser, offer 6–8 complete layouts by persona (Developer, Maker / revenue,
  Student, Music, Minimal, Persian / RTL), with live preview.
- **Join / stay:** The first minute decides retention; a full, good-looking dock right away is the "aha".
- **Competitors:** DockFix (community presets); CoolDock roadmap ("Provide Ready-Made Widget Templates & Layouts").
- **Status:** **Partial** (onboarding offers 4 layout scenarios and one starter profile, `UI/Onboarding.swift`).
- **Complexity:** Low · `UI/Onboarding.swift`, `UI/Browser/WidgetBrowser.swift`, bundled `.nicedock` files.
- **Priority:** 5 — the cheapest lever on first-week retention.
- **Don't Go:** Don't ask for permissions inside the gallery; each widget asks when first used.

#### 56. Export and import everything
- **What:** Export settings and all profiles to one file and import it on another Mac (secrets excluded).
- **Join / stay:** Users with several Macs ask for it; it also makes users dare to experiment.
- **Competitors:** Dockset (export), Bartender (settings transfer); CoolDock roadmap ("Allow for copying layouts").
- **Status:** **Missing** (no import / export; only diagnostics are exported).
- **Complexity:** Low · `Core/AppStore.swift` (`Persisted` is Codable), Settings → General.
- **Priority:** 5 — low effort, removes the fear of losing a layout.
- **Don't Go:** No account-based cloud backup.

#### 57. Sync through iCloud Drive
- **What:** Optionally keep the state file in an iCloud Drive folder so all Macs share profiles; per-Mac display settings stay local.
- **Join / stay:** Multi-Mac users stay when setups follow them.
- **Competitors:** Bartender (licences on all Macs), Raycast (cloud sync, account-based).
- **Status:** **Missing** (`grep CloudKit|ubiquity` finds only calendar text).
- **Complexity:** Medium · `Core/AppPaths.swift`, file coordination, conflict handling.
- **Priority:** 3 — valuable but conflict handling is real work; do export / import first.
- **Don't Go:** No CloudKit container or NiceDock server; file-based, user-visible, off by default.

#### 58. Undo and automatic snapshots
- **What:** ⌘Z for widget remove / move / settings changes, plus 10 automatic daily snapshots restorable from Settings.
- **Join / stay:** "I broke my layout" is a common reason to quit a customization app.
- **Competitors:** None in Dock apps (gap); DockFlow presets act as manual snapshots.
- **Status:** **Missing** (no `UndoManager` in `Sources/`; Reset only restores defaults).
- **Complexity:** Medium · `Core/AppStore.swift` mutations, Settings → General.
- **Priority:** 4 — protects users and supports bold MCP edits.
- **Don't Go:** No version history UI with diffs; a list of dated snapshots is enough.

#### 59. What's New and tips after updates
- **What:** A short in-app card after each update with new widgets ("Add to Dock" button) and one tip.
- **Join / stay:** Re-engages users with features they don't know exist, without tracking them.
- **Competitors:** Raycast and Bartender (release notes in app).
- **Status:** **Partial** (Sparkle links release notes to GitHub, `scripts/appcast.sh`; no in-app card).
- **Complexity:** Low · `App/AppUpdater.swift`, small window, localized strings.
- **Priority:** 3 — cheap, measurable only by goodwill, and needs translation discipline.
- **Don't Go:** No badges or nags; show once per version, dismiss forever.

#### 60. Suggested widgets from your Mac
- **What:** In the widget browser, suggest widgets based on installed apps (Spotify → Now Playing, Zoom → Next Meeting,
  Things → tasks) and attached devices.
- **Join / stay:** Shortens discovery in a 111-widget catalog.
- **Competitors:** Apple widget gallery (suggested widgets).
- **Status:** **Missing** (no suggestions in `UI/Browser/WidgetBrowser.swift`; search exists).
- **Complexity:** Low · `WidgetBrowser.swift`, a static app → widget map.
- **Priority:** 3 — cheap and fully local.
- **Don't Go:** No usage tracking to drive suggestions.

#### 61. Local weekly summary
- **What:** Optional Sunday card: Pomodoros done, habits kept, meeting hours, focus time; stored only on the Mac.
- **Join / stay:** Gives a reason to look at NiceDock weekly.
- **Competitors:** None directly (gap).
- **Status:** **Missing**.
- **Complexity:** Medium · Pomodoro / habit / calendar data, a summary view.
- **Priority:** 1 — retention gimmick risk; streak guilt can push users away.
- **Don't Go:** No streak shaming, no sharing images, no data leaving the Mac.

### J. Accessibility and AI

#### 62. Keyboard navigation of the dock
- **What:** A hotkey focuses the dock; arrows move between tiles, Return activates, Space opens the panel, Esc leaves.
- **Join / stay:** Needed for keyboard-first users and for accessibility.
- **Competitors:** DockDoor (keyboard controls), Docky (Launchpad keyboard navigation).
- **Status:** **Missing** (`FocusState` only in text fields; no tile focus ring).
- **Complexity:** Medium · `App/DockRootView.swift`, `App/HotKeys.swift`, panels.
- **Priority:** 3 — accessibility and power users; needs care with the non-activating panel.
- **Don't Go:** Don't steal focus from the frontmost app unless the hotkey is pressed.

#### 63. VoiceOver and Reduce Motion coverage
- **What:** Labels and values for every widget, honoured Reduce Motion everywhere, and an audit test.
- **Join / stay:** Opens NiceDock to users who can't use it today; App Store and press reviewers check this.
- **Competitors:** Apple widgets; most Dock apps are weak here (gap).
- **Status:** **Partial** (`accessibilityLabel` in 9 files; `accessibilityReduceMotion` only in `Widgets/Clock/ClockTimerWidgets.swift`).
- **Complexity:** Medium · all widget families, `Widgets/Components.swift` (`Tile` default label).
- **Priority:** 3 — the right thing to do; spread it over releases.
- **Don't Go:** Don't build a separate accessible mode; fix the main views.

#### 64. MCP: read widget data and prompts
- **What:** Read-only MCP tools for widget data (next meeting, weather, system load, AI usage) and ready prompts ("plan my
  focus profile").
- **Join / stay:** Makes NiceDock useful from Claude, Codex and Cursor every day, not only for setup.
- **Competitors:** None in Dock apps (NiceDock is ahead here).
- **Status:** **Partial** (14 tools in `MCP/AssistantTools.swift` cover configuration and wallpapers only).
- **Complexity:** Medium · `MCP/AssistantTools.swift`, `MCP/AssistantBridge.swift`, services.
- **Priority:** 3 — strengthens a unique feature; keep it behind the existing switches.
- **Don't Go:** Never return Connected-widget revenue or token data without an extra per-widget opt-in; no network listener.

#### 65. On-device AI widget
- **What:** A small prompt box that answers with Apple's on-device Foundation Models (macOS 26+) or a local Ollama model:
  summarize the clipboard, rewrite text, plan the day from the agenda.
- **Join / stay:** AI is the most requested new category; on-device fits the privacy story.
- **Competitors:** Raycast (Quick AI, cloud); CoolDock roadmap ("AI Assistant Widget").
- **Status:** **Missing** (no `FoundationModels` or Ollama code in `Sources/`).
- **Complexity:** Medium · new widget family, availability checks for macOS 26 and Apple Intelligence.
- **Priority:** 3 — attractive, but only on supported Macs; keep cloud models out.
- **Don't Go:** No cloud LLM keys inside NiceDock (MCP already lets cloud assistants in); no chat history storage.

## 4. Top-10 shortlist

Ranked by priority, then by retention impact per unit of effort. The vertical dock (feature 1) is left out because it is
already being built.

1. **Starter layouts gallery** (#55) — the first minute decides retention; low effort.
2. **Switch profiles with Focus modes** (#8) — daily, automatic value through a public system API.
3. **Context rules for profiles** (#9) — time, display, app, power and Wi-Fi switching make NiceDock "smart".
4. **Apple Shortcuts actions + `nicedock://` URLs** (#12, #13) — one action layer for Shortcuts, Focus, Stream Deck and launchers.
5. **Command widget** (#16) — unlimited long-tail widgets for the developer audience.
6. **Export / import everything + shareable layout files** (#56, #20) — safe experimentation and free community marketing.
7. **Smart Stacks** (#18) — more information in the same strip.
8. **Undo and automatic snapshots** (#58) — removes the fear of breaking a layout.
9. **Local alert rules and notifications** (#31) — value even when the dock is hidden.
10. **Window previews on hover, opt-in** (#23) — the most common Dock-app feature, behind an explicit Screen Recording switch.

## 5. Sources

NiceDock (local): `README.md`, `docs/WIDGET_GUIDE.md`, `docs/ai-assistant.md`, `Sources/CoolDock/Core/WidgetCatalog.swift`,
`Sources/CoolDock/Core/Settings.swift`, `Sources/CoolDock/Core/Models.swift`, and the `grep` checks named in each feature.

Competitors and references:

- CoolDock — [cooldock.app](https://cooldock.app), [roadmap](https://cooldock.app/roadmap), [ChatGate summary](https://chatgate.ai/post/cooldock), [AlternativeTo](https://alternativeto.net/software/cooldock/about/)
- uBar — [ubarapp.com](https://ubarapp.com), [AppleInsider hands-on](https://appleinsider.com/articles/18/07/29/hands-on-ubar-for-the-mac-shrinks-your-dock-and-makes-it-work-harder-for-you)
- ActiveDock 2 — [noteifyapp.com/activedock](https://noteifyapp.com/activedock/), [MacTech 2020](https://www.mactech.com/2020/08/10/activedock-2-for-macos-adds-new-drag-and-drop-features-more), [Softpedia changelog](https://mac.softpedia.com/progChangelog/ActiveDock-Changelog-142787.html)
- DockDoor — [dockdoor.net](https://dockdoor.net/), [GitHub](https://github.com/ejbills/DockDoor)
- Docky — [GitHub](https://github.com/josejuanqm/docky), [IT-Connect](https://www.it-connect.tech/docky-reinvents-the-macos-dock-free-open-source-and-packed-with-features/)
- Docktor — [ChatGate](https://chatgate.ai/post/docktor), [Product Hunt](https://producthunt.com/products/docktor)
- Dockset — [iPhoneSoft, Oct 2026](https://iphonesoft.fr/2026/10/06/dockset-revolutionner-dock-mac)
- DockFlow — [Setapp](https://setapp.com/apps/dockflow)
- DockFix — [dockfix.app](https://www.dockfix.app/)
- Dockside — [hachipoo.com/dockside-app](https://hachipoo.com/dockside-app), [ifun.de](https://www.ifun.de/dockside-mac-app-bietet-dateiablage-neben-dem-dock-244882/)
- HyperDock — [Mac App Store](https://apps.apple.com/us/app/hyperdock/id449830122), [9to5Mac](https://9to5mac.com/2016/02/23/how-to-display-window-previews-apps-mac-os-x-dock/), [AlternativeTo](https://alternativeto.net/software/hyperdock/about/), [DockView](https://noteifyapp.com/DockView)
- Übersicht — [GitHub](https://github.com/felixhageloh/uebersicht), [MakeUseOf](https://www.makeuseof.com/tag/ubersicht-turns-command-beautifully-formatted-widgets/)
- SketchyBar — [GitHub](https://github.com/FelixKratz/SketchyBar)
- WidgetWall — [Mac App Store](https://apps.apple.com/us/app/widgetwall/id1618466427?mt=12), [Setapp](https://setapp.com/apps/widgetwall)
- Widgetsmith — [widgetsmith.app](https://widgetsmith.app/)
- macOS desktop widgets — [Apple Support](https://support.apple.com/guide/mac-help/add-and-customize-widgets-mchl52be5da5/mac)
- Raycast — [raycast.com](https://www.raycast.com/)
- Stats — [GitHub](https://github.com/exelban/stats)
- iStat Menus 7 — [bjango.com](https://www.bjango.com/mac/istatmenus/), [MacRumors thread](https://forums.macrumors.com/threads/istat-menus-7-0-brings-comprehensive-redesign-and-new-features.2432615)
- Bartender 7 — [macbartender.com](https://www.macbartender.com/)
- Ice — [GitHub](https://github.com/jordanbaird/Ice), [MacStories roundup](https://www.macstories.net/roundups/managing-your-mac-menu-bar-a-roundup-of-my-favorite-bartender-alternatives/)
- Hammerspoon — [hammerspoon.org](https://www.hammerspoon.org/)

Adoption and retention:

- [App Onboarding That Protects Day-1 Retention (Sonar)](https://trysonar.app/blog/app-onboarding-that-protects-day-1-retention.md)
- [Indie app onboarding, day 0 to day 28 (DEV)](https://dev.to/kanta13jp1/indie-app-onboarding-that-retains-users-day-0-to-day-28-engagement-design-4ej6)
- [Utility-app retention benchmarks (DiVA thesis)](https://www.diva-portal.org/smash/get/diva2:1985428/FULLTEXT01.pdf)
- [The case against the Mac App Store for indie apps](https://teenyapps-website.pages.dev/articles/case-against-mac-app-store/)

Caveats: CoolDock roadmap entries are user requests, not shipped features. Several third-party listings (ChatGate,
Softpedia, deal sites) may be out of date; product pages were preferred wherever they loaded. Raycast's feature page and
the DockFix 3.6 news page returned errors and were not used.
