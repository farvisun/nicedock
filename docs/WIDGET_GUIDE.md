# Writing NiceDock widgets

This is the contract every widget follows. Read it before touching `Sources/CoolDock/Widgets/`.

## Where things live

| Area | File |
| --- | --- |
| Widget kinds, titles, widths, config fields | `Core/WidgetCatalog.swift` |
| Instance model, config accessors | `Core/Models.swift` (`WidgetInstance.string/int/bool/list`) |
| Tile chrome + shared components | `Widgets/Components.swift` |
| Routing kind → family | `Widgets/WidgetHost.swift` (`WidgetFactory`) |
| One file (or folder) per family | `Widgets/<Family>/<Family>Widgets.swift` |
| Shared services | `Services/*.swift` |
| Pop-up panels | `App/Panels.swift` (`Panels.shared.toggle(id) { … }`, `PanelHeader`) |
| Reference screenshots (2×) | `docs/reference/<kind>.png` |

Each family enum exposes:

```swift
enum ClockWidgets {
    @MainActor @ViewBuilder static func view(_ w: WidgetInstance) -> some View
    @MainActor @ViewBuilder static func menu(_ w: WidgetInstance) -> some View   // extra right-click items
}
```

`view` switches on `w.kind` and returns one view type per kind. Put each widget in its own `struct`.
Helpers that are private to a family must be `private`/`fileprivate` or prefixed with the family name
(e.g. `ClockFlipDigit`) — all families compile into one module.

## Pixel rules

* Tile height is **62 pt** at Dock Size 100 %. Reference PNGs are 2× (124 px tall); divide pixels by 2.
* Width comes from `w.kind.spec.width`; use `Tile(width: w.kind.spec.width, padding: …) { … }`.
* Every literal dimension and font size goes through `@Environment(\.metrics) var m` → `m.u(x)`.
  `Text(…).dock(size, weight, color)` already scales.
* Colours come from `@Environment(\.palette) var p`: `p.primary` (white on dark), `p.secondary` (60 %),
  `p.tertiary` (36 %), `p.control` (button fill), `p.track` (ring track). Accents always go through
  `p.accent(.cdGreen)` so Monochrome mode works. Never hardcode `.white` for text.
* Accent palette: `.cdGreen .cdBlue .cdOrange .cdRed .cdPink .cdPurple .cdIndigo .cdCyan .cdTeal .cdYellow`.
* Typeface: `Font.dock(size, weight)` = SF Pro Rounded (Latin) / Estedad (Persian, Arabic). Use
  `mono: true` for changing numbers so digits don't jitter.
* Tiles: ~10–12 pt horizontal padding, content vertically centred; big numbers 26–30 pt semibold/bold,
  labels 10–11 pt medium in `p.secondary`.

## Localization & RTL

* Every user-visible string: `L("English text")` or `L("%d unread", n)`. English is the key.
* Numbers and dates: `Fmt.int`, `Fmt.number`, `Fmt.compact`, `Fmt.percent`, `Fmt.clock(date)`,
  `Fmt.date(date, "MMMd")`, `Fmt.weekdayShort`, `Fmt.temp`, `Fmt.bytes`, `Fmt.currency`, `Fmt.duration`.
  Raw digit strings go through `Fmt.digits(_)` or `T("…")` so Persian shows ۰۱۲۳.
* Calendar math uses `Fmt.calendar` (Persian Solar Hijri when the user picks it).
* Layout uses leading/trailing — never left/right. Directional glyphs (play, next, arrows) get
  `.flipsForRTL()` when they mean "forward". Charts stay left-to-right:
  `.environment(\.layoutDirection, .leftToRight)`.

## Performance & memory

* No per-widget `Timer`. Use `TimelineView(.everyMinute)` for minute clocks,
  `TimelineView(.periodic(from: .now, by: 1))` only for seconds, and
  `TimelineView(.animation(minimumInterval: 0.1))` only while something is actively running.
* Shared services are demand-driven: `.demand(SystemMonitor.shared)`, `.demand(CalendarDemand.events)`,
  `.demand(CalendarDemand.reminders)`. Weather: `.task(id: city) { await WeatherService.shared.keepFresh(city) }`
  then read `WeatherService.shared.snapshot(city)`.
* Network: `Net.json(url, headers:)`, cache last value with `DiskCache.save/load`, refresh no more than
  every 5–15 min, keep work inside `.task(id:)` so it cancels when the widget disappears.
* Images: downsample (`NowPlayingService.downsample`), app icons via `AppIcon(path:size:)` / `IconCache`.
* Persist small widget state with `AppStore.shared.updateWidget(w.id) { $0.config["k"] = v }` — never
  more often than on user actions.
* Secrets: `Secrets.get(w.id, "token")` / `Secrets.set(value, w.id, "token")`. They go to the login Keychain, or to the
  AES-GCM credential file when the user picks it in Settings → Privacy & Permissions → Credential Storage; widgets
  never care which. Never store tokens in `config`.
* Calendar data: read `CalData` (EventKit merged with the ICS/webcal feeds of Settings → Privacy & Permissions →
  Calendar Feeds, see `Services/CalendarFeeds.swift` and the parser `Services/ICS.swift`). Gate on `CalData.hasEvents`
  (Calendar access *or* a feed), never on EventKit access alone; Refresh calls `CalendarService.shared.refreshEvents()`.

## Interaction

* Click = primary action or `Panels.shared.toggle(w.id) { ExpandedView() }` for a mini window.
* Right-click = standard menu (Customize, Refresh, Visibility, Remove) + your `menu(_:)` items.
* Refresh requests: `.onWidgetRefresh(w.id) { … }`.
* Unconfigured / no permission / error: show `TileMessage(symbol:text:)` inside the tile with a click
  that fixes it (`WidgetSetup.customize(w)` or request permission).

## Verifying against references

```bash
swift build
./.build/debug/CoolDock --render /tmp/out clockDigital,timer --wait 2
magick /tmp/out/clockDigital.png docs/reference/clockDigital.png +append /tmp/compare.png
```

Renders are 2× with no padding, same size as the reference when the width matches.

Developer renders only: `COOLDOCK_ICS_FILE=/a.ics:/b.ics` shows local ICS files in the calendar widgets (instead of
the saved feeds) and `COOLDOCK_OFFLINE=1` keeps the render off the network. Both are ignored outside `--render` and
in `--scene reference`. Example: `docs/verification/calendar-feed/README.md`.
