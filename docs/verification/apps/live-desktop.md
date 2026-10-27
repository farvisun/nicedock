# App menus on the real desktop (27 Oct 2026, macOS 27.0.1)

`NiceDock --menu-probe <app> [--redact] [--perform "Item" | "Submenu/Item"]…` (debug builds) builds the same
right-click menu the Dock shows (`AppsAppMenu.build`) for a real app, prints it, fires items one by one and reports the
app's state after each (running, hidden, active, on-screen windows via CGWindowList, kept in Dock). Nothing is saved;
`--redact` replaces file and profile names with counts.

```bash
swift build
COOLDOCK_SUPPORT_DIR=$(mktemp -d) .build/debug/CoolDock --menu-probe /System/Applications/TextEdit.app --redact --step 3 \
  --perform Open --perform Hide --perform Show --perform "Options/Keep in Dock" --perform Quit
```

## Actions performed on real apps

| App | Item | Before → after |
|---|---|---|
| TextEdit (not running) | Open | not running → running, active, 1 window |
| TextEdit | Hide | 1 window → hidden, 0 windows on screen |
| TextEdit | Show | hidden → visible, 1 window |
| TextEdit | Options ▸ Keep in Dock | not pinned → pinned |
| TextEdit | Quit | running → not running |
| Google Chrome (running) | New Window (`open -na … --args --new-window`) | 1 → 2 on-screen windows (the window took longer than the probe's 4 s step to appear; counted again afterwards) |

## Menus built for real apps (redacted)

```
Google Chrome (running)          Preview (running)        TextEdit (not running)   Safari (not running)   Mail (not running)
New Window                       Open Recent ▸ 10 items   New Document             New Window             New Message
New Incognito Window             ---                      ---                      New Private Window     ---
Open Recent ▸ 7 items            Options ▸ …              Options ▸ …              ---                    Options ▸ …
---                              ---                      ---                      Options ▸ …            ---
Options ▸ Keep in Dock,          Show All Windows         Open                     ---                    Open
  Open at Login, Show in Finder,  Hide                                              Open
  Show Windows & Badges…          Quit / ⌥ Force Quit
Show All Windows · Hide · Quit / ⌥ Force Quit
```

## What this run found and changed

- **Open Recent** read only the Dock's own lists in
  `~/Library/Application Support/com.apple.sharedfilelist`. macOS 27 keeps that folder behind Full Disk Access and
  denies it silently, so the submenu never appeared. It now falls back to Spotlight: files used in the last 60 days
  (`kMDItemLastUsedDate`) that open in that app by default, newest first. No permission is needed. The search runs
  in the background and is cached for a minute. The Dock's own list still wins when it is readable.
  Unit tests: `AppsRecentSpotlightTests`.
- **New Window with Profile** (Chromium) needs the browser's `Local State`. macOS 27 also denies other apps' browser
  data folders (Chrome, Edge, Firefox) here, so with a single readable profile or none the submenu is simply
  omitted; New Window and the private window don't need it.

## Not exercised live, and why

| Item | Needs | Covered by |
|---|---|---|
| Window list, Dock badges, generic New Window (File ▸ New Window), Safari private / profile windows — on *other* apps | Accessibility permission for NiceDock, which only the user can grant in System Settings | The same code driven live against the test process's own windows and menus (no permission needed for itself; only the pid differs): [accessibility-live.md](accessibility-live.md). Badges: the reader degrades cleanly without the permission, the parser ran on a Dock-shaped tree. Plus AX title matching, badge formatting and menu-model unit tests; reference-scene renders in `en/`, `fa/` |
| Open at Login | one-time Automation approval for System Events (a system prompt) | login-item path normalisation and parsing tests |
| New Document (TextEdit, Pages…) | Automation approval for that app | menu presence above |
| Show All Windows | runs Mission Control's App Exposé on screen | — |
