# CoolDock

A native macOS **second Dock with live widgets** — a from-scratch Swift/SwiftUI recreation of the
tools shown on [cooldock.app](https://cooldock.app): music, todos, events, weather, search, system
stats, quick actions and 111 widgets in one beautiful dock beside the macOS Dock.

* Native Swift 6 toolchain, SwiftUI + AppKit, macOS 14 Sonoma or later
* ~9 MB app bundle, ~34 MB memory (+4 MB for the Now Playing helper while a music widget is shown, +1.7 MB while an app is below 100 % volume), about 0.5 % of one core when idle with the default layout (the first minute after launch also scans local AI tool logs once)
* 10 languages, full right-to-left support, Persian with the **Estedad** typeface,
  Solar Hijri calendar and Persian digits
* Local-first: credentials live in the macOS Keychain, no account, no telemetry
* **AI Assistant**: Claude, Codex, Cursor, VS Code and other MCP clients can read and configure CoolDock
  (`CoolDock --mcp`) and paint wallpapers by mood, season or weather — off by default, read-only until you allow
  changes in Settings → Privacy & Permissions. Setup and tools: [docs/ai-assistant.md](docs/ai-assistant.md)

## Build & run

```bash
scripts/build-app.sh release --run     # builds build/CoolDock.app and launches it
scripts/build-app.sh debug             # faster debug build
swift build                            # compile only
```

The script compiles with SwiftPM, assembles the `.app` bundle (Info.plist, fonts, translations,
generated icon) and ad-hoc signs it. Drag `build/CoolDock.app` to `/Applications` to keep it.

Developer launch flags: `--lang <code>`, `--settings <pane>`, `--widgets`, `--onboarding`, `--mcp` (stdio MCP server,
no UI; `COOLDOCK_SUPPORT_DIR` points it at another state folder), and the offscreen widget
renderer `--render <dir> <kinds|all|category:name> [--wait s] [--lang fa] [--style darkGlass]`.
Debug builds also accept `--profile <index>` and `--tap <0…1>` (clicks the dock at that fraction of its
width) to inspect widget panels without UI scripting, and `--menu-probe <app> [--perform "Item"]…` to build and fire an
app tile's right-click menu against the real app.

## Verification

- **Pixel diff** — `scripts/pixel-diff.sh` renders every frame in `docs/reference` with deterministic
  reference data (`--scene reference`) and compares it with ImageMagick: exact size, match at 8 % and 3 % colour fuzz
  (ImageMagick's AE metric: 100 % minus the out-of-fuzz colour error, each differing pixel weighted by how far it is
  off), RMSE. Output: `build/pixel-report/report.html` (reference | render | diff strips),
  `report.md`, `metrics.tsv`. Current result: 74/74 frames exact size, mean match 99.93 % (median 99.95 %, strict 3 %:
  99.81 %), every frame ≥ 99.5 % (lowest: contactCard 99.51 %, nowPlaying 99.59 %; all others ≥ 99.71 %, 63 of 74
  ≥ 99.90 %). `scripts/pixel-residue.sh` then sorts what is left: 93.2 % of the pixels that still differ (8 % fuzz)
  lie within 1 px of an edge in the reference (anti-aliasing and sub-pixel placement); away from edges 99.96 % of
  pixels match on average, and 99.85 % match when each pixel may be compared with any reference pixel up to 1 px away.
  `scripts/chrome-check.sh` holds the 29 tiles without a site frame to the same chrome. Evidence index: [docs/verification](docs/verification/README.md).
- **Data providers** — `swift test` runs 476 tests (they pass in any time zone, UTC−11 to UTC+14; live Now Playing, App Volume, Accessibility and network suites are opt-in); the provider suites feed real captured responses (Open-Meteo, Yahoo
  Finance, Binance, GitHub contributions, Simple Analytics, redacted OpenCode database rows) and documentation-schema
  fixtures (Stripe, Shopify, Dodo, Polar, Dub, DataFast, Plausible, Resend, Supabase, X, TikTok, YouTube, Linear,
  Anthropic, OpenAI, Cursor, GitHub Copilot, Gemini API, Perplexity, xAI, Z.ai) through the same parsers the widgets use. `LiveAuthTests` replays each keyed provider's real
  no-key / fake-key answers through the widget's own request and error handling — see
  [docs/verification/providers.md](docs/verification/providers.md). `COOLDOCK_VERIFY_LOCAL_LOGS=1 swift test --filter
  LocalLogsTests` also checks AI-usage totals against this Mac's Claude Code / Codex logs.
- **Calendar feeds** — the ICS reader (`Services/ICS.swift`) is tested with handcrafted RFC 5545 snippets and four
  real feeds captured with curl (Google US holidays, iCloud US holidays, the LLVM community calendar, Make WordPress
  meetings); every occurrence in an eight-week window matches an independent python-dateutil expansion
  (`Tests/Scripts/ics_oracle.py`). Widget renders from real feeds, English and Persian:
  `docs/verification/calendar-feed/`.
- **AI Assistant** — `swift test` covers the MCP server (JSON-RPC framing, tool schemas, disabled/read-only gating,
  validation, the state.json path, the app socket bridge, wallpaper determinism) and spawns `CoolDock --mcp` end to end
  with a temporary home; transcript in [docs/verification/ai-assistant.md](docs/verification/ai-assistant.md).
- **Translations** — `python3 scripts/l10n.py check` (every language must report 0 missing).

## Using it

| Action | How |
| --- | --- |
| Add widgets | Right-click the Dock → **Widgets…**, click a card or drag it into place |
| Configure a widget | Right-click it → **Customize…** (connected widgets: **Connection & Settings…**) |
| Reorder | Hold **⌘** and drag a widget (plain drag while the widget browser is open) |
| Switch profiles | Hover the Dock and pick a tab, swipe across it, or **⌃⌥⌘0…7** |
| Hide / show | **⌃⌥⌘D** (configurable) |
| Settings | Menu bar icon → **Settings…**, right-click the Dock, or **⌘,** |
| App menus | Right-click an app: its windows, New Window / private window / browser profiles, Open Recent, Options ▸ Keep in Dock, Open at Login, Show in Finder; hold **⌥** for Force Quit |
| Lost the Dock? | Menu bar icon → **Layout → Reset Layout** |

## Widgets

| Category | Widgets |
| --- | --- |
| Apps & files | App, App Folder, Applications, Trash, Folder, Downloads, Recent Files, File Shelf, AirDrop, Dropbox, Find Files, App Switcher, Running Apps |
| Clocks & focus | Clock, Clock with Seconds, Time & Date, Time Card, Date, Day & Date, Date/Time/Weather, Flip Clock, Analog (dark/light), World Clock, Pixel Clock, Timer, Stopwatch, Pomodoro, Drink Water, Posture |
| Calendar & tasks | Today's Events, Agenda, Week, Next Meeting, Zoom Meeting, Day/Month/Year Progress, Progress Ring, Reminders, Todo, Habit Tracker, Linear |
| Weather | Weather, Weather & Forecast, Details, Daily, Today & Forecast, Conditions, Hourly, Sunrise & Sunset, Wind |
| System & controls | Battery, CPU, Memory, Storage, Temperature, CPU History, Network, Devices Battery, Audio, App Volume (per-app volume and mute, macOS 14.2+), Quick Toggles, Clipboard, Screenshots, Recent Screenshots, Voice Memo, Emoji |
| Utilities | Color Picker, Converter, Calculator, Bookmarks, Search Web, Window Manager, Separator, Space |
| Media & people | Now Playing (any app: Music, Spotify, browsers, Podcasts, VLC…), Now Playing Large, Background Sounds, YouTube Video, Recent Photo, Wallpaper, Mail, Latest Mail, Notes, Quick Contacts, Contact Card |
| Markets | Stock, Stock Chart, Watchlist, Crypto, Crypto Chart, Crypto Watchlist |
| Connected | Polar, Stripe, Dodo Payments, Shopify ×3, Plausible, Simple Analytics, DataFast, Visitors Chart, Dub, Resend, GitHub, Supabase, X, TikTok, YouTube, AI Usage (Claude Code, Codex, OpenCode, Antigravity, Cursor, GitHub Copilot, Gemini API, Perplexity, Grok, GLM / Z.ai, Anthropic/OpenAI admin APIs) |

Data sources: Open-Meteo (weather, no key), Frankfurter (currency), Yahoo Finance and Binance
(quotes), EventKit and ICS/webcal calendar feeds (Google, iCloud, Outlook, Fastmail, any .ics link), CoreAudio,
CoreWLAN, IOKit, PhotoKit, Contacts and each provider's public API.

## Settings

General · Appearance (live preview, six dock styles incl. Liquid Glass, size, spacing, corner
radius, monochrome, reduce transparency) · Layout (seven scenarios: Swap at the Bottom, Reveal,
Fixed ×6 positions, Reveal on Top, Replace the macOS Dock, Replace & Auto-Hide, Floating) ·
Screens (one / attached / all displays, rename, identify) · Dock · Profiles (up to 8) · Widgets (incl. App Volume) ·
Shortcuts (recorders) · Language & Region (language, calendar, digits, 12/24 h, Estedad) ·
Privacy & Permissions (incl. Calendar Feeds and the AI Assistant) · Performance (live memory/CPU of CoolDock) · About.

## Architecture

```
Sources/CoolDock
├── App/        AppDelegate, DockController (per-display panels, scenarios, reveal triggers),
│               DockRootView (plate, strip, reorder, profile tabs), Panels, HotKeys, StatusItem
├── Core/       AppStore (@Observable state + JSON persistence), Settings, Models, WidgetCatalog,
│               Localization (runtime language switching), Formatting (Fmt), Theme, Secrets
├── Services/   SystemMonitor, WeatherService, CalendarService, NowPlayingService, visibility rules
├── Widgets/    Components (Tile, rings, charts, brand marks) + one folder per widget family
└── UI/         Settings window, Widget browser, setup forms, onboarding
```

Performance rules: services are demand-driven (they run only while a visible widget subscribes),
clocks use `TimelineView` schedules instead of timers, hidden docks unmount their widgets, images are
downsampled at decode time, and closed windows release their SwiftUI trees.
See [docs/WIDGET_GUIDE.md](docs/WIDGET_GUIDE.md) for the widget contract.

## Localization

English strings are the keys; translations live in `Resources/<lang>.lproj/Localizable.strings`
(fa, ar, de, fr, es, tr, ru, zh-Hans, ja). Language changes apply instantly without relaunching.
Persian and Arabic switch the whole interface to right-to-left and use the bundled Estedad font
(SIL Open Font License, `Resources/Fonts/Estedad-OFL.txt`).

## Credits

Design inspired by [CoolDock](https://cooldock.app) by AppitStudio. Estedad typeface by Amin Abedi.
