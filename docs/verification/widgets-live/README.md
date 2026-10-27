# Live widget states (27 Oct 2026, macOS 27.0.1, final build)

Every one of the 111 widget kinds rendered with live data on this Mac (`CoolDock --render <dir> all --wait 4`, the
same pass `scripts/chrome-check.sh` makes). The sheets in this folder are from an earlier pass; the final pass is
summarised here instead of committed because it shows personal calendar, files and wallpaper.

| State | Widget kinds |
|---|---|
| Live data (51) | clockDigital, clockSeconds, clockDate, timeHero, dateTile, dayDate, dateTimeWeather (date and time; its weather part is network), flipClock, analogDark, analogLight, worldClock, pixelClock, dayProgress, monthProgress, yearProgress, progressRing, weekStrip, calendarToday, agenda, nextMeeting (real events), zoomMeeting, aiUsage (local Claude Code / Codex logs: 4.8 B tokens in 7 days), batteryRing, cpuRing, memoryRing, storageRing, temperatureRing (51°), cpuGraph, networkGraph (13 KB/s ↓), audioControls (MacBook speakers, 50 %), quickToggles (Wi-Fi on), runningApps, app, appFolder, applications, folder, trash, wallpaper (current desktop picture), recentPhoto (latest library photo), recentFiles, appSwitcher, bookmarks, downloads, recentScreenshots, screenshots, clipboard, dropbox, airDrop, fileShelf, findFiles, searchWeb |
| Ready, nothing to show yet (22) | nowPlaying, nowPlayingHero ("Nothing playing"; live helper verified in `now-playing/`), appVolume ("No apps playing"; live taps verified in `app-volume/`), backgroundSounds, youtubeVideo, reminders ("All done"), todo ("Nothing to do"), habitTracker ("Add a habit"), devicesBattery ("No devices"), contactCard ("Choose a contact"), calculator, converter (amount field; rate is network), emoji, colorPicker, voiceMemo, pomodoro, timer, stopwatch, drinkWater, posture, separator, space |
| Needs a permission, not a blocker (5) | quickContacts (Contacts), windowManager (Accessibility), mail, mailLatest, notes (Automation for counts; the tiles still open the apps) |
| Needs an account key, not a blocker (18) | githubContributions, linear, stripeRevenue, polarRevenue, dodoRevenue, shopifyChart, shopifyToday, shopifyOverview, plausible, simpleAnalytics, dataFast, visitorsChart, dubStats, resendStats, supabase, socialX, socialTikTok, socialYouTube |
| Live network data (15) | weatherCompact, weatherHero, weatherLocation, forecastDays, weatherToday, weatherCondition, forecastHourly, sunriseSunset, wind, stockQuote, stockChart, stockWatchlist, cryptoQuote, cryptoChart, cryptoWatchlist — drawn with live data from the test process (`network/*.png`); the app binary itself is held by this Mac's firewall, see below |

## Network widgets

In the app render these showed "Offline". The system log shows why: each connection failed within 4 ms with
`NSURLErrorDomain -1005` / POSIX 57, at the same millisecond Little Snitch's network extension logged
`No current verdict available, cannot report flow closed`. Little Snitch holds every freshly built, ad-hoc signed
`CoolDock` binary until it is allowed; `curl` from the same shell reached every service.

The same service code, run from the test process (`COOLDOCK_LIVE_NET=1 swift test --filter NetworkLive`), passed
against the real services:

| Path | Result |
|---|---|
| Weather (`WeatherService`, Open-Meteo geocoding + forecast) | Tehran 22.2 °C, 24 hours, 7 days, sunrise/sunset, `Asia/Tehran` |
| Stock (`FinService`, Yahoo Finance) | AAPL 343.91 (−1.10 %), 79 intraday points |
| Crypto (`FinService`) | BTC 79,552.04 (−0.57 %), 40 points. Binance answers 451 / times out from this network, so the Yahoo `BTC-USD` fallback took over after 2.5 s as designed |
| Currency (`UtilFX`, Frankfurter) | 1 USD = 0.894 EUR. Frankfurter moved to `api.frankfurter.dev/v1` (the old host now answers 301); the converter now calls the new host directly |

`COOLDOCK_LIVE_NET=1 COOLDOCK_EVIDENCE_DIR=$PWD/docs/verification/widgets-live/network swift test --filter NetworkTilesLive`
fetches through the same services, mounts the 15 tiles like the dock does and draws them (`network/*.png`):
Tehran 22 °C mostly clear with the 24-hour and 7-day forecast, sunrise 6:21 / sunset 17:14, SW wind 9 km/h gusting
25; AAPL 343.91 (−1.10 %), MSFT, NVDA; BTC 79,548.48 (−0.58 %), ETH, SOL, with live intraday charts.
