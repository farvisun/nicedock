# Verification evidence

Everything here is produced locally from the source tree; re-run the commands to regenerate it.

| What | How | Result (27 Oct 2026) |
|---|---|---|
| Pixel match vs cooldock.app | `scripts/build-app.sh release && scripts/pixel-diff.sh` → `build/pixel-report/report.html` | 73/73 site frames exact size · mean 99.55 % of pixels within 8 % colour fuzz (strict 3 %: 99.41 %) · every frame ≥ 98.58 % |
| Widgets without a site frame | `scripts/chrome-check.sh` → `build/chrome-check/chrome.tsv` | all 27 tiles on the reference chrome (124 px tall, whole-point width, corners ≥ 97 % at 4 % fuzz); 7 bare widgets have no tile by design; `posture` is full-bleed like its referenced sibling `drinkWater` |
| Live widgets, real data | `CoolDock --render <dir> all --wait 8 --lang en|fa` → `widgets-live/{en,fa}-{1,2,3}.png` | all 107 kinds, live data (time, weather, stocks, crypto, CPU/memory/network, AI usage from local logs, exchange rates); unconfigured or permission-gated widgets show their setup state |
| Settings window | `open build/CoolDock.app --args --lang en|fa --settings <pane>` → `settings/{en,fa}-<pane>.png` | all 12 panes in English and Persian (right-to-left, Estedad) |
| Data providers | `swift test` | 85 tests: real captured responses (Open-Meteo, Yahoo Finance, Binance, GitHub contributions, Simple Analytics, local Claude Code / Codex logs) and documentation-schema fixtures for keyed APIs |
| Translations | `python3 scripts/l10n.py check` | 10 languages, 0 missing |

Widgets whose data needs the user's own account (Stripe, Shopify, Polar, Dodo, Dub, DataFast, Plausible,
Resend, Supabase, X, TikTok, YouTube, Linear, Anthropic/OpenAI admin usage) or a macOS permission
(Calendars, Reminders, Contacts, Photos, Microphone) show their connect / allow state until the user
provides it; their parsing is covered by the tests above.
