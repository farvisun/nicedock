# AI Assistant (MCP) — verification

Produced on 27 Oct 2026 from this source tree. Nothing here launched the CoolDock app or changed the desktop picture:
the end-to-end runs spawn `.build/debug/CoolDock --mcp` with a temporary `HOME` and `COOLDOCK_SUPPORT_DIR`, and
wallpapers were only previewed.

| What | How | Result |
| --- | --- | --- |
| Unit and integration tests | `swift test` | 201 tests in 33 suites pass (57 new for the assistant: JSON-RPC framing and error codes, `tools/list` schema validity, disabled / read-only gating of every tool, per-tool validation, state.json apply path, socket bridge with fallback, wallpaper determinism and sizes) |
| End-to-end, read-only | `MCPEndToEndTests/initializeListAndGetDock` → [ai-assistant/e2e-read-only.txt](ai-assistant/e2e-read-only.txt) | `initialize` (2025-06-18), `tools/list` (14 tools), `get_dock` from the saved state, `add_widget` refused as read-only, state.json byte-identical afterwards |
| End-to-end, changes without the app | `MCPEndToEndTests/changesWithoutTheRunningApp` → [ai-assistant/e2e-changes.txt](ai-assistant/e2e-changes.txt) | `add_widget` and `set_appearance` written to state.json, `timer.minutes = 999` rejected, `preview_wallpaper` saved a 3024×1964 JPEG (this Mac's main display) in the temporary Wallpapers folder |
| Settings section | `COOLDOCK_SETTINGS_SNAPSHOT=<dir> swift test --filter AssistantSettingsSnapshotTests` (offscreen `NSHostingView`) | [English](ai-assistant/ai-assistant-en.png), [Persian](ai-assistant/ai-assistant-fa.png): right-to-left rows and footers, Latin names and paths isolated in place, code snippets left-to-right |
| Wallpapers | `COOLDOCK_WALLPAPER_SAMPLES=<dir> swift test --filter WallpaperTests/sampleSheet` | [16 requests](ai-assistant/wallpaper-samples.jpg) across moods, seasons, times of day, weather and all styles |
| Translations | `python3 scripts/l10n.py check` | 10 languages × 1111 strings, 0 missing (19 new) |

## Transcript

The JSON exchanged with the binary (`→` stdin, `←` stdout). Lines longer than ~420 characters are cut here; the
complete lines are in the two `.txt` files.

Read-only (`Enable AI Assistant` on, `Allow Changes` off, dock style set to Light Glass in the saved state):

```text
→ {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"cooldock-e2e","version":"1.0"}}}
← {"id":1,"jsonrpc":"2.0","result":{"capabilities":{"tools":{"listChanged":false}},"instructions":"CoolDock is the user's second Dock with live widgets on this Mac. Start with get_dock (current settings, profiles and widget ids) and list_widget_kinds (kinds and their settings). Tools are read-only until the user turns on Allow Changes in CoolDock Settings → Privacy & Permissions → AI Assistant. set_wallpaper pa … (646 characters in total)
→ {"jsonrpc":"2.0","method":"notifications/initialized"}
→ {"jsonrpc":"2.0","id":2,"method":"tools/list"}
← {"id":2,"jsonrpc":"2.0","result":{"tools":[{"annotations":{"destructiveHint":false,"idempotentHint":true,"openWorldHint":false,"readOnlyHint":true,"title":"Get Dock"},"description":"Summary of CoolDock: appearance (dock style, size, spacing, corner radius, theme…), layout scenario and position, language, and every profile with its widgets (ids, kinds, positions, settings). Call this first; ids from here are use … (14723 characters in total)
→ {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_dock","arguments":{}}}
← {"id":3,"jsonrpc":"2.0","result":{"content":[{"text":"{\"active_profile\":{\"id\":\"D0402E94-5290-4A9E-A99E-CCF5DB0ED083\",\"index\":0,\"name\":\"Home\"},\"appearance\":{\"animations\":true,\"corner_radius\":11.5,\"dock_style\":\"lightGlass\",\"icon_style\":\"standard\",\"monochrome\":false,\"overflow\":\"adapt\",\"reduce_transparency\":false,\"scale\":1,\"shadow\":true,\"spacing\":6,\"theme\":\"auto\",\"tile_bac … (4653 characters in total)
→ {"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"add_widget","arguments":{"kind":"flipClock"}}}
← {"id":4,"jsonrpc":"2.0","result":{"content":[{"text":"CoolDock is read-only; turn on Allow Changes in Settings → AI Assistant (CoolDock Settings → Privacy & Permissions) to let assistants change it.","type":"text"}],"isError":true}}
→ {"jsonrpc":"2.0","id":5,"method":"ping"}
← {"id":5,"jsonrpc":"2.0","result":{}}
```

Changes with CoolDock not running (`Allow Changes` on):

```text
→ {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"add_widget","arguments":{"kind":"flipClock","profile":"Work","position":0}}}
← {"id":2,"jsonrpc":"2.0","result":{"content":[{"text":"{\"message\":\"Added Flip Clock to Work at position 0.\",\"note\":\"CoolDock isn't running: the change was saved and appears when CoolDock starts.\",\"profile\":{\"id\":\"DD2004FA-8F83-436F-A784-DE5F755A4E54\",\"index\":1,\"name\":\"Work\"},\"widget\":{\"id\":\"4826AB5D-0928-4EE4-959D-8F14B15ACB27\",\"kind\":\"flipClock\",\"position\":0,\"title\":\"Flip Clock\"}}","type":"text"}],"isError":false}}
→ {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"set_appearance","arguments":{"dock_style":"black","corner_radius":14}}}
← {"id":3,"jsonrpc":"2.0","result":{"content":[{"text":"{\"appearance\":{\"animations\":true,\"corner_radius\":14,\"dock_style\":\"black\",\"icon_style\":\"standard\",\"monochrome\":false,\"overflow\":\"adapt\",\"reduce_transparency\":false,\"scale\":1,\"shadow\":true,\"spacing\":6,\"theme\":\"auto\",\"tile_backgrounds\":true,\"widget_surface\":\"glass\"},\"message\":\"Appearance updated: corner_radius=14, dock_style=black.\",\"note\":\"CoolDock isn't running: the change was saved and appears when CoolDock starts.\"}","type":"text"}],"isError":false}}
→ {"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"add_widget","arguments":{"kind":"timer","config":{"minutes":999}}}}
← {"id":4,"jsonrpc":"2.0","result":{"content":[{"text":"timer.minutes must be between 1 and 240 min; got 999.","type":"text"}],"isError":true}}
→ {"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"preview_wallpaper","arguments":{"mood":"calm","time_of_day":"dusk","season":"autumn"}}}
← {"id":5,"jsonrpc":"2.0","result":{"content":[{"text":"{\"description\":\"calm, autumn, dusk — waves\",\"height\":1964,\"message\":\"Preview saved. Call set_wallpaper with the same parameters to use it.\",\"parameters\":{\"color\":null,\"mood\":\"calm\",\"season\":\"autumn\",\"style\":\"waves\",\"time_of_day\":\"dusk\",\"variation\":0,\"weather\":null},\"path\":\"/var/folders/j6/wbdwp54s3wq4v8xqldx0ls0w0000gn/T/cd-B7D338A6/Library/Application Support/CoolDock/Wallpapers/cooldock-calm-autumn-dusk-waves-c644059b-3024x1964.jpg\",\"width\":3024}","type":"text"}],"isError":false}}
```

(The `initialize` exchange of the second session is identical to the first.) Regenerate both files with
`COOLDOCK_MCP_TRANSCRIPT=<file> COOLDOCK_MCP_TRANSCRIPT_CHANGES=<file> swift test --filter MCPEndToEndTests`; ids and
paths differ per run.

## Not covered by automated runs

* The live-app path (`assistant.sock` → `AppStore`) is exercised by `AssistantBridgeTests` with the app's own socket
  server and request handler on an in-memory state; the running GUI app was not launched for this verification.
* `set_wallpaper` was never called against the real desktop; its gating and the call into the desktop setter are tested
  with an injected setter (`AssistantGatingTests/wallpaperGating`).
