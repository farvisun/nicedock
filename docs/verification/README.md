# Verification evidence

Everything here is produced locally from the source tree; re-run the commands to regenerate it.

| What | How | Result (27 Oct 2026) |
|---|---|---|
| Pixel match vs cooldock.app | `scripts/build-app.sh release && scripts/pixel-diff.sh` → `build/pixel-report/report.html` | 74/74 site frames (73 widget images + the contact card from the site's widget atlas) exact size · mean 99.55 % of pixels within 8 % colour fuzz (strict 3 %: 99.40 %) · every frame ≥ 98.58 % |
| Widgets without a site frame | `scripts/chrome-check.sh` → `build/chrome-check/chrome.tsv` | all 29 tiles on the reference chrome (124 px tall, whole-point width, corners ≥ 97 % at 4 % fuzz); 7 bare widgets have no tile by design; `posture` is full-bleed like its referenced sibling `drinkWater` |
| Live widgets, real data | `CoolDock --render <dir> all --wait 8 --lang en|fa` → `widgets-live/{en,fa}-{1,2,3}.png` | all 108 kinds, live data (time, weather, stocks, crypto, CPU/memory/network, AI usage from local logs, exchange rates); unconfigured or permission-gated widgets show their setup state |
| Settings window | `open build/CoolDock.app --args --lang en|fa --settings <pane>` → `settings/{en,fa}-<pane>.png` | all 12 panes in English and Persian (right-to-left, Estedad) |
| Window space & credential storage | `COOLDOCK_EVIDENCE_DIR=$PWD/docs/verification/system swift test --filter SystemSettingsRender` → `system/` | Layout → Windows / Dock Space (no Accessibility, Reserve on with All Displays, auto-hiding layout) and Privacy → Credential Storage (Keychain, encrypted file, unreadable file), English and Persian; rendered offscreen from the real views, the app is never launched |
| Data providers & system features | `swift test` | 350 tests, passing in UTC−11 … UTC+14 (one is the opt-in Settings evidence render): Reserve Dock Space geometry, Hide on Window Hover state machine, encrypted credential file and Keychain ⇄ file migration (`system/README.md`), plus real captured responses (Open-Meteo, Yahoo Finance, Binance, GitHub contributions, Simple Analytics, local Claude Code / Codex logs, redacted OpenCode database rows), real live answers of every keyed endpoint without/with a fake key (`providers.md`), documentation-schema fixtures for keyed happy paths |
| Calendar from real feeds | ICS parser + feeds (`swift test --filter ICS`) → `calendar-feed/` | real Google / iCloud holiday feeds, LLVM and WordPress meeting calendars; every occurrence in an 8-week window matches an independent python-dateutil expansion; renders in English and Persian |
| AI Assistant (MCP) | `swift test` (`MCPEndToEndTests` spawns `CoolDock --mcp`) → [ai-assistant.md](ai-assistant.md) | 57 assistant tests of 201; JSON transcripts of a read-only session and of offline changes; Settings section in English and Persian; wallpaper sample sheet |
| Habit Tracker & Window Manager | `CoolDock --render <dir> habitTracker,windowManager[-variant] [--scene reference] --lang en\|fa` → `new-widgets/` | tiles and panels in English and Persian (scene data and the real first-run state); see `new-widgets/README.md` |
| App menus, folder window & badges | `swift test --filter Apps` + `CoolDock --render <dir> folder-panel[Nested\|Search\|Sorted],folder-colors,app-badges,app-menu --scene reference --lang en\|fa` → `apps/` | native right-click menus (window list, Options, Open Recent, New Window / private window / profiles for Chromium and Safari), folder colours, folder window search/sort/filter/breadcrumbs, Dock-style badges; see `apps/README.md`. Live on the desktop (`--menu-probe`): Open, Hide, Show, Keep in Dock, Quit on TextEdit and New Window in Chrome, real menus for five apps; Open Recent falls back to Spotlight because macOS 27 hides the Dock's lists — [apps/live-desktop.md](apps/live-desktop.md) |
| AI usage sources | `swift test --filter 'Usage\|LiveAuthAI'` → `ai-usage/` | OpenCode, Antigravity, Cursor, GitHub Copilot, Gemini API, Perplexity, Grok, GLM / Z.ai: data path per source in `providers.md`; tiles in English and Persian |
| Now Playing from any app | `COOLDOCK_LIVE_MEDIA=1 swift test --filter MediaRemote` + live `--render` with a probe player → `now-playing/` | MediaRemote through an Apple-signed host (direct calls are refused since macOS 15.4): real helper stream fixture, live publish → read → pause round trip, English and Persian frames; see `now-playing/README.md` |
| Translations | `python3 scripts/l10n.py check` | 10 languages × 1298 strings, 0 missing |

Widgets whose data needs the user's own account (Stripe, Shopify, Polar, Dodo, Dub, DataFast, Plausible,
Resend, Supabase, X, TikTok, YouTube, Linear, Anthropic/OpenAI admin usage, Cursor, Copilot, Gemini, Perplexity,
xAI, Z.ai usage) show their connect state until
a key is added: each endpoint is verified live up to authentication, the happy-path parsing against the
providers' documented schemas. Calendar widgets work from ICS feeds without any permission; Reminders,
Contacts, Photos and Microphone widgets need the matching macOS permission.
