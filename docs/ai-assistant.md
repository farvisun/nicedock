# AI Assistant (MCP)

Claude, Codex, Cursor, VS Code and other [Model Context Protocol](https://modelcontextprotocol.io) clients can read and
configure CoolDock, from dock style to widget settings, and paint a wallpaper by mood, style, colour, time of day,
season or weather. The assistant starts read-only; it can change things only after you turn on **Allow Changes**.

## Turn it on

CoolDock Settings → **Privacy & Permissions** → **AI Assistant**:

| Switch | Default | Effect |
| --- | --- | --- |
| Enable AI Assistant | off | While off, every tool answers *"The AI Assistant is disabled in CoolDock Settings…"*. |
| Allow Changes | off | While off the assistant is read-only: `get_dock`, `list_widget_kinds` and `preview_wallpaper` work; every other tool answers *"CoolDock is read-only; turn on Allow Changes in Settings → AI Assistant…"*. |

Both switches are saved in `state.json` (`aiAssistantEnabled`, `aiAllowChanges`). Below them, **Connect an Assistant**
shows ready-to-paste setup for each client with the path of *your* copy of CoolDock and a Copy button.

## Connect a client

The server is the CoolDock binary itself, started by the client with `--mcp` (stdio, nothing listens on the network).
Use the path shown in Settings; for an app in `/Applications` it is:

**Claude Code** (Terminal):

```bash
claude mcp add cooldock -- "/Applications/CoolDock.app/Contents/MacOS/CoolDock" --mcp
# add --scope user before `cooldock` to use it in every project
```

**Codex** — `~/.codex/config.toml`:

```toml
[mcp_servers.cooldock]
command = "/Applications/CoolDock.app/Contents/MacOS/CoolDock"
args = ["--mcp"]
```

**Cursor** — `~/.cursor/mcp.json` (Claude Desktop uses the same shape in `claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "cooldock": {
      "command": "/Applications/CoolDock.app/Contents/MacOS/CoolDock",
      "args": ["--mcp"]
    }
  }
}
```

**VS Code** — `.vscode/mcp.json` in the workspace (or *MCP: Add Server…*):

```json
{
  "servers": {
    "cooldock": {
      "type": "stdio",
      "command": "/Applications/CoolDock.app/Contents/MacOS/CoolDock",
      "args": ["--mcp"]
    }
  }
}
```

Then start a new session and ask, for example: *"Put a flip clock first in my Work profile"*, *"Make the dock white with
rounder corners and move it to the top right"*, *"Switch CoolDock to Persian with the Solar Hijri calendar"* or *"Give me a
cozy autumn evening wallpaper"*.

## Tools

| Tool | Changes? | What it does |
| --- | --- | --- |
| `get_dock` | no | Appearance, layout, language, assistant switches and every profile with its widgets (id, kind, position, settings). Secrets are never included. |
| `list_widget_kinds` | no | Kinds that can be added (`category`, `kind` filters): English title, category, width, settings with type, range/options and default. |
| `add_widget` | yes | `kind` (id or English title), `profile`, `position`, `config`, `visibility`. |
| `remove_widget` | yes | `widget_id` (full id or a unique prefix ≥ 4 characters). Also removes the widget's Keychain token. |
| `move_widget` | yes | `widget_id`, `position` (-1 = end), optional target `profile`. |
| `update_widget_config` | yes | `widget_id`, `config` (only the given keys change; `null` restores a default), `visibility`. |
| `set_appearance` | yes | `dock_style`, `widget_surface`, `theme`, `scale` 0.7–1.4, `spacing` 0–20, `corner_radius` 4–22, `overflow`, `monochrome`, `tile_backgrounds`, `shadow`, `reduce_transparency`, `icon_style`, `animations`. |
| `set_layout` | yes | `scenario`, `position` (switches to `fixed` when given alone), `edge_distance`, `alignment`, `show_delay`, `hide_delay`, `trigger_size`, `hide_on_window_hover`, `hide_during_fullscreen`, `screens`. |
| `set_language` | yes | `language` (code, English or native name), `calendar`, `digits`, `clock`, `use_estedad`. |
| `switch_profile` | yes | `profile` (id, name or 0-based index). |
| `create_profile` | yes | `name` (≤ 24, unique), `symbol`, `duplicate_from`, `activate` (default true). Up to 8 profiles. |
| `rename_profile` | yes | `profile`, `name`, `symbol`. |
| `set_wallpaper` | yes | Paints a wallpaper and sets it on every display (current Space). |
| `preview_wallpaper` | no | Paints and saves the same image without touching the desktop. |

Every argument is validated with the same rules as the Settings window (slider ranges and steps, choice values,
`#RRGGBB` or colour names, app names resolved in `/Applications`). Errors name the problem and list the valid values,
e.g. `Unknown widget kind 'laserClock'. Valid kinds: app, appFolder, …` or `timer.minutes must be between 1 and 240 min;
got 999.` API tokens and contacts can't be set by an assistant — the user enters them in CoolDock.

### Wallpapers

`mood` (calm, serene, happy, energetic, cozy, dreamy, romantic, mysterious, dramatic, melancholy, focused, playful),
`style` (gradient, mesh, blobs, aurora, bokeh, waves, dunes, mountains, minimal), `color` (name or hex),
`time_of_day` (dawn … midnight), `season`, `weather` (clear, sunny, partly_cloudy, cloudy, overcast, rain, storm, snow,
fog, windy) and `variation` are all optional. Painting is procedural and local (Core Graphics: layered gradients,
mesh-like colour blends, soft shapes, landscapes, weather effects and film grain against banding), at the main display's
pixel size. The same parameters always give the same image; `variation` gives another take. Files are JPEGs in
`~/Library/Application Support/CoolDock/Wallpapers/` (the 24 newest are kept). Samples:
[verification/ai-assistant/wallpaper-samples.jpg](verification/ai-assistant/wallpaper-samples.jpg).

## How changes reach the Dock

```
client ──stdio JSON-RPC──▶ CoolDock --mcp ──Unix socket──▶ running CoolDock ──▶ AppStore (animated, saved)
                                   │ (no app answering)
                                   └──────────────▶ state.json (same validation, file lock) → loaded at next launch
```

* `CoolDock --mcp` branches in `main.swift` before `NSApplication` exists: no window, no Dock icon, no permission prompt.
* The running app listens on `~/Library/Application Support/CoolDock/assistant.sock` (mode 0600, peer uid checked). One
  JSON line per request and reply. The app runs the tool on its live state on the main actor and applies the result through
  `AppStore` exactly like a change in Settings (spring animation, the usual save debounce, Keychain clean-up, widget
  refresh). The switches are checked by the app itself.
* When nothing answers on the socket (CoolDock not running, or a stale socket after a crash), the MCP process runs the
  same `DockTools` code on `state.json` under an exclusive lock and saves only when something changed. A missing state file
  means the assistant was never enabled; an unreadable one is never overwritten.
* Wallpapers are painted in the MCP process so the Dock never stalls; `set_wallpaper` then calls
  `NSWorkspace.setDesktopImageURL` for every screen.

## Protocol

JSON-RPC 2.0, one message per line on stdin/stdout, logs on stderr. `initialize` negotiates `2025-06-18`, `2025-03-26` or
`2024-11-05` (an unknown version gets `2025-06-18`), then `notifications/initialized`, `ping`, `tools/list`, `tools/call`.
Errors: `-32700` parse error, `-32600` invalid request, `-32601` unknown method, `-32602` invalid params / unknown tool,
`-32603` internal. Tool failures (validation, read-only, disabled) are tool results with `isError: true` so the model can
read and correct them. Batches are answered as arrays; notifications never get a reply.

Source: `Sources/CoolDock/MCP/` (`MCPServer`, `AssistantTools`, `DockTools`, `AssistantBridge`, `WallpaperGenerator`),
Settings section `UI/Settings/SettingsAIAssistant.swift`. Tests: `MCPProtocolTests`, `MCPToolSchemaTests`,
`AssistantGatingTests`, `DockToolsTests`, `StateFileApplyTests`, `AssistantBridgeTests`, `WallpaperTests`,
`MCPEndToEndTests`. Evidence: [verification/ai-assistant.md](verification/ai-assistant.md).
