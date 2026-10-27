# CoolDock

A native macOS **second Dock with live widgets** — a from-scratch Swift/SwiftUI recreation of the
tools shown on [cooldock.app](https://cooldock.app): music, todos, events, weather, search, system
stats, quick actions and 100 widgets in one beautiful dock beside the macOS Dock.

* Native Swift 6 toolchain, SwiftUI + AppKit, macOS 14 Sonoma or later
* ~3 MB app bundle, ~30 MB memory, ~0 % CPU when idle
* 11 languages, full right-to-left support, Persian with the **Estedad** typeface,
  Solar Hijri calendar and Persian digits
* Local-first: credentials live in the macOS Keychain, no account, no telemetry

## Build & run

```bash
scripts/build-app.sh release --run     # builds build/CoolDock.app and launches it
scripts/build-app.sh debug             # faster debug build
swift build                            # compile only
```

The script compiles with SwiftPM, assembles the `.app` bundle (Info.plist, fonts, translations,
generated icon) and ad-hoc signs it. Drag `build/CoolDock.app` to `/Applications` to keep it.

Developer launch flags: `--lang <code>`, `--settings <pane>`, `--widgets`, `--onboarding`, and the offscreen widget
renderer `--render <dir> <kinds|all|category:name> [--wait s] [--lang fa] [--style darkGlass]`.
Debug builds also accept `--profile <index>` and `--tap <0…1>` (clicks the dock at that fraction of its
width) to inspect widget panels without UI scripting.

## Verification

- **Pixel diff** — `scripts/pixel-diff.sh` renders every frame in `docs/reference` with deterministic
  reference data (`--scene reference`) and compares it with ImageMagick: exact size, share of pixels within
  8 % and 3 % colour fuzz, RMSE. Output: `build/pixel-report/report.html` (reference | render | diff strips),
  `report.md`, `metrics.tsv`. Current result: 73/73 frames exact size, mean match 99.5 %, every frame ≥ 98.5 %.
- **Data providers** — `swift test` runs 105 tests that feed real captured responses (Open-Meteo, Yahoo
  Finance, Binance, GitHub contributions, Simple Analytics) and documentation-schema fixtures (Stripe,
  Shopify, Dodo, Polar, Dub, DataFast, Plausible, Resend, Supabase, X, TikTok, YouTube, Linear, Anthropic,
  OpenAI) through the same parsers the widgets use. `LiveAuthTests` replays each keyed provider's real
  no-key / fake-key answers through the widget's own request and error handling — see
  [docs/verification/providers.md](docs/verification/providers.md). `COOLDOCK_VERIFY_LOCAL_LOGS=1 swift test --filter
  LocalLogsTests` also checks AI-usage totals against this Mac's Claude Code / Codex logs.
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
| Lost the Dock? | Menu bar icon → **Layout → Reset Layout** |

## Widgets

| Category | Widgets |
| --- | --- |
| Apps & files | App, App Folder, Applications, Trash, Folder, Downloads, Recent Files, File Shelf, AirDrop, Dropbox, Find Files, App Switcher, Running Apps |
| Clocks & focus | Clock, Clock with Seconds, Time & Date, Time Card, Date, Day & Date, Date/Time/Weather, Flip Clock, Analog (dark/light), World Clock, Pixel Clock, Timer, Stopwatch, Pomodoro, Drink Water, Posture |
| Calendar & tasks | Today's Events, Agenda, Week, Next Meeting, Zoom Meeting, Day/Month/Year Progress, Progress Ring, Reminders, Todo, Linear |
| Weather | Weather, Weather & Forecast, Details, Daily, Today & Forecast, Conditions, Hourly, Sunrise & Sunset, Wind |
| System & controls | Battery, CPU, Memory, Storage, Temperature, CPU History, Network, Devices Battery, Audio, Quick Toggles, Clipboard, Screenshots, Recent Screenshots, Voice Memo, Emoji |
| Utilities | Color Picker, Converter, Calculator, Bookmarks, Search Web, Separator, Space |
| Media & people | Now Playing (Music/Spotify), Now Playing Large, Background Sounds, YouTube Video, Recent Photo, Wallpaper, Mail, Latest Mail, Notes, Quick Contacts, Contact Card |
| Markets | Stock, Stock Chart, Watchlist, Crypto, Crypto Chart, Crypto Watchlist |
| Connected | Polar, Stripe, Dodo Payments, Shopify ×3, Plausible, Simple Analytics, DataFast, Visitors Chart, Dub, Resend, GitHub, Supabase, X, TikTok, YouTube, AI Usage (Claude Code, Codex, Anthropic/OpenAI admin APIs) |

Data sources: Open-Meteo (weather, no key), Frankfurter (currency), Yahoo Finance and Binance
(quotes), EventKit, CoreAudio, CoreWLAN, IOKit, PhotoKit, Contacts and each provider's public API.

## Settings

General · Appearance (live preview, six dock styles incl. Liquid Glass, size, spacing, corner
radius, monochrome, reduce transparency) · Layout (seven scenarios: Swap at the Bottom, Reveal,
Fixed ×6 positions, Reveal on Top, Replace the macOS Dock, Replace & Auto-Hide, Floating) ·
Screens (one / attached / all displays, rename, identify) · Dock · Profiles (up to 8) · Widgets ·
Shortcuts (recorders) · Language & Region (language, calendar, digits, 12/24 h, Estedad) ·
Privacy & Permissions · Performance (live memory/CPU of CoolDock) · About.

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
