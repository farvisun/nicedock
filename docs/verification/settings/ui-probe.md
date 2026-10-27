# Settings and widget controls, clicked in the running app (27 Oct 2026, macOS 27.0.1)

`--ui-probe` launches the real app and operates it the way VoiceOver, Voice Control or a UI-scripting tool would:
through the Accessibility API, on NiceDock's own windows. It is not a test host. The normal `AppDelegate` launch runs
(Dock window, menu bar item, hot keys, AI Assistant socket), then the probe presses, steps and types into the real
Settings window and the real Dock.

```bash
scripts/build-app.sh debug        # the probe is compiled into debug builds only (#if DEBUG)
COOLDOCK_SUPPORT_DIR="$(mktemp -d)" build/NiceDock.app/Contents/MacOS/NiceDock --ui-probe --out /tmp/ui-probe.json
echo $?                           # 0 only when every check passed
```

`--dump <file.json>` writes the Accessibility tree of the Dock and of every Settings pane instead of running the checks
(a development aid; it is how the controls below were found).

## What it does

- **State.** Persistence is off (`AppStore.persistenceEnabled = false`). Support and cache folders are
  `COOLDOCK_SUPPORT_DIR` (else a temporary folder, removed at exit). The in-memory state is English, the default Fixed
  layout, onboarding done, and one profile, "UI Probe", with the 15 widgets below. Background Sounds is set to volume 0.
- **Accessibility only.** Every action goes through `AXUIElementCreateApplication(getpid())`: `AXPress`,
  `AXIncrement`/`AXDecrement` on sliders, `AXValue` and `AXFocused` on text fields, `AXConfirm` (Return) and named
  actions. Every result is read back through Accessibility: `AXValue`, `AXDescription`, `AXTitle`, `AXEnabled`, frames,
  and the font through `AXAttributedStringForRange`. The effect is then confirmed where it lands:
  `AppStore.shared.settings`, the widget's config, `ClockTimerEngine`, `MediaSoundEngine`, the pasteboard or a captured
  URL. Every change is restored afterwards (Pomodoro's skipped phase and the reminders' counts stay in memory and end
  with the process).
- **Nothing leaves the app.** Copy buttons write to a private pasteboard, so the user's clipboard is never touched.
  URLs are captured, not opened. Timer and reminder alerts go to a sink, so there is no sound and no notification
  permission prompt. Every change NiceDock would make to the macOS Dock is captured instead of made
  (`SystemDock.interceptor`). The probe also reads `com.apple.dock` `autohide` / `autohide-delay` at start and at exit,
  and fails if they differ.
- **Never pressed.** These controls are only checked to exist and be enabled, because they have effects outside the
  app: Turn On/Off Dock Auto-Hide, the "Replace the macOS Dock" and "Replace & Auto-Hide" layouts, Launch at Login,
  every permission button (Allow…, Review, Open System Settings), Choose Folder…, Export…/Export Diagnostics…, Reset…,
  Show Onboarding, Clear Cache, the Color Picker's eyedropper (screen sampler), Emoji's "Add" (system Character
  Viewer), Voice Memo's record control, and the Quick Toggles (Wi-Fi, Bluetooth, Dark Mode, Keep Awake, Keyboard
  Cleaning Lock).
- **Output.** One line per pane and widget on stdout. The JSON report (`--out`) lists every case with the AX elements
  found, each action with before / after values, and pass / fail, plus the Dock preferences before and after, the
  captured URLs and alerts. The probe closes the Settings window with its close button and quits through
  `NSApp.terminate` (the normal `applicationWillTerminate` path). It exits 0 only if everything passed.

## Result

**3 consecutive passing runs on the final build**: 12/12 panes, 15/15 widgets, 103 checks each, 16.5 s, 15.8 s and
16.5 s in the app (16–17 s wall clock). The report of the third run is [ui-probe.json](ui-probe.json). Four earlier
runs also passed; they used the same code without the final watchdog and cache-folder cleanup. In every run the
system Dock stayed at `autohide 0` with no `autohide-delay` key, no Dock change was attempted, no NiceDock process was
left, and `AXIsProcessTrusted()` was false (no Accessibility grant).

### Settings: 12 panes

Each pane is selected by pressing its sidebar row (`AXPress`). The check is that the window title (the pane's
`navigationTitle`) and the detail header change from the previous pane to this one. About has no header, so its check
is the app-name line.

| Pane | Operated through Accessibility | Confirmed (then restored) |
|---|---|---|
| General | switch "Show menu bar icon" | `showMenuBarIcon` true → false, switch AXValue 1 → 0. Choose Folder…, Export…, Reset… present and enabled (not pressed) |
| Appearance | segment Theme → Dark; Dock Size slider AXIncrement; switch "Dock shadow" | `appTheme` auto → dark; `dockScale` 1.0 → 1.05 (AXValue 1 → 1.05); `shadow` true → false |
| Layout | Distance from Bottom Edge AXIncrement; Screen Position "Bottom Left" | `edgeDistance` 8 → 9; `fixedPosition` bottomCenter → bottomLeft. Auto-Hide and the two "replace" layouts present (not pressed) |
| Screens | segment "All Displays" | `screensMode` one → all |
| Dock | switches "Show running indicators", "Open Folders in Finder" | true → false; false → true |
| Profiles | switch "Show profile switcher on hover"; button "New Profile" | `showProfileSwitcher` true → false; 1 → 2 profiles, the new row appears in the pane (removed again through the model) |
| Widgets | switch "Remember volume per app"; widget list | `remembersAppVolumes` true → false; 15 rows for 15 widgets |
| Shortcuts | switches of "Hide and Show Dock" and "Switch Profile" | `toggleHotKey.enabled`, `profileHotKeysEnabled` true → false |
| Language & Region | segment Time format → 24-hour; button "فارسی"; switch "استفاده از Estedad…" (operated in Persian); button "English" | `clockStyle` → h24. Persian: language fa, the sidebar moves to the right (AX frame), window title and header "زبان و منطقه", header font **Estedad-Bold** (read through AX), Estedad active. Estedad switch true → false → true. English: left-to-right again, title "Language & Region" |
| Privacy & Permissions | switch "Enable AI Assistant" | `assistantEnabled` false → true; the dependent "Allow Changes" switch goes from disabled to enabled; Access shows "Read-only". The 8 permission rows are read, not pressed (on this Mac: Calendars, Reminders, Photos, Microphone Allowed; Contacts, Location, Accessibility "Allow…"; Automation "Review") |
| Performance | System stats interval AXIncrement; switch "Pause widgets while NiceDock is hidden" | `systemSampleInterval` 2 → 3; `pauseWhenHidden` true → false. Clear Cache present (not pressed) |
| About | button "Widgets…", then the browser's close button | Widget Browser window opens (`browserOpen` true, AX window "Widgets") and closes again. Version line "Version 1.0.0 (1)". Show Onboarding and Export Diagnostics… present (not pressed) |

### Widgets: 15 in the real Dock

A widget's elements are the ones carrying its name as Accessibility help (the Dock's tooltip).

| Widget | AX elements found | Actions | Before → after |
|---|---|---|---|
| Timer | display button, Play | Play, Pause, Cancel | 5:00 → 4:59 running; paused reads equal 1.2 s apart; Cancel → 5:00 |
| Stopwatch | display, Reset (disabled), Play | Play (wait 1.3 s), Pause, Reset | 0:00.0 → 0:01.3; frozen while paused; Reset enabled, → 0:00.0 and disabled again |
| Pomodoro | phase "Focus", round "1/4", time, Skip, Play | Play, Pause, Skip Phase | 25:00 → 24:59; frozen while paused; Focus → Break, 5:00 |
| Drink Water | tile button "29:48, Every 30 min" | press ("I drank water") | count 0 → 1, countdown 29:48 → 30:00 |
| Posture | tile button "44:48, Every 45 min" | press ("I sat up straight") | count 0 → 1, countdown 44:48 → 45:00 |
| Calculator | expression button, result text | press the expression, AXValue "12*(3+4)", AXConfirm, clear | result 0 → 84; Return copies "84" (private pasteboard); cleared → 0 |
| Converter | amount, USD, EUR, swap, result | Swap ×2; press amount, AXValue "250", AXConfirm; back to 500 | USD/EUR → EUR/USD → USD/EUR; amount shown and saved 500 → 250 → 500 (the rate itself comes from the network and is not part of the check) |
| Emoji | 9 emoji buttons, Add | press 😂 | pasteboard "😂", the button turns into "Selected" for 0.9 s and back. Add present (not pressed) |
| Color Picker | swatches #EE5450, #3499DC, #FAC716, eyedropper | press #EE5450 | pasteboard "#EE5450". Eyedropper present (not pressed) |
| Todo | tile "Nothing to do, Click to add a task"; panel text field | press the tile; AXValue "UI probe task" + AXConfirm in the panel; the row's Delete action | panel opens; 0 → 1 task, shown on the tile; Delete → 0, tile empty again |
| Habit Tracker | tile "Add a habit, Build a daily streak"; panel field, ring, Delete | press the tile; type "Probe habit" + AXConfirm; press the ring twice; Delete, then confirm | habit added, ring on the tile; done today false → true → false; deleted, tile empty again |
| Voice Memo | record button "Microphone" | none (would record) | a button, enabled, with AXPress and a named action "Recordings…"; microphone status read (authorized) |
| Background Sounds | tile button, AXValue "Off" | press, press again | plays at volume 0: AXValue Off → Rain, `isPlaying` true, volume 0; then Off, stopped |
| YouTube Video | button "Open Video" | press | the video URL is captured (not opened): `https://www.youtube.com/watch?v=4GB3XQaYejk` |
| Quick Toggles | Wi-Fi, Bluetooth, Dark Mode, Keep Awake, Keyboard Cleaning Lock | none (would change the Mac) | names and states read: Wi-Fi On, Bluetooth On, Dark Mode Off, Keep Awake Off, Keyboard Cleaning Lock Off |

## Bugs found and fixed

1. **Settings sidebar rows did nothing when pressed.** Each row's link answered `AXPress` without changing the pane:
   the list's selection drives the detail, and the link has no destination. VoiceOver's VO-Space and Voice Control's
   "Click Appearance" therefore did nothing. In the first run, 11 of 12 panes failed selection, and General passed only
   because it was already showing. Fix: the row's press action selects its pane
   (`UI/Settings/SettingsWindow.swift`).
2. **The Settings window title fell out of step with the pane.** Whenever Settings was shown again (after a language
   change, ⌘, or About while open), `WindowHost` set "NiceDock Settings" *after* the new content, which overrode the
   pane's `navigationTitle`. Accessibility, the Window menu and Mission Control then named the window "NiceDock
   Settings" while it showed another pane. In Persian, the title read "تنظیمات NiceDock" over the "زبان و منطقه" pane.
   Fix: set the title before the content (`UI/WindowHost.swift`).
3. **Converter: an amount confirmed with Return was not saved.** Return ended editing without calling `save()`, and
   the field's end-of-editing handler only fires on focus loss. The tile showed the new amount, but the widget kept the
   old one, so it came back after a profile switch or relaunch. A run with the fix reverted showed `shown 250, saved
   500`. Fix: Return saves (`Widgets/Utility/UtilConverter.swift`).
4. **Seven widgets could not be operated through Accessibility.** Their clicks were plain tap gestures with no
   `AXPress`: the Calculator's and the Converter's inline fields, the Todo tile, the Habit Tracker tile (empty and with
   habits), Voice Memo's record tile, Background Sounds (tap and long press; its playing state wasn't exposed either),
   and the YouTube video. They showed up as `AXStaticText`, `AXImage` or `AXUnknown` with no action. A new
   `accessibilityPress` modifier gives the same handler to Accessibility (`Widgets/Components.swift`). Background
   Sounds now also reports Off or the sound as its value and has a named action for its panel.
5. **Hover-only controls were unreachable.** The Todo panel's Delete button appears only under the pointer, and so
   does Voice Memo's Recordings… button. Both are now named actions (`Widgets/Calendar/CalendarTasks.swift`,
   `Widgets/Utility/UtilVoiceMemo.swift`).
6. **Unlabelled or mislabelled controls.**
   - The Color Picker's swatches had no name; they are now named by their hex.
   - Quick Toggles named its buttons after their glyphs: Bluetooth had no name, Dark Mode read "Brightness Higher",
     Keep Awake read "Snooze", and none reported on/off. Each button now gives its name and On/Off.
   - Layout's six Screen Position buttons had no name; they now carry the position names.

All of these are Accessibility modifiers or a logic fix; nothing is drawn differently. `scripts/pixel-diff.sh` on the
release build still gives 74/74 exact size, mean 99.93 %, median 99.95 %, min 99.51 %.

The probe needed four seams, none of which changes behaviour for users:

- `UtilPasteboard.board`, for the private pasteboard.
- `SystemDock.interceptor`.
- `AppPaths.overrideCacheDirectory`.
- `ClockAlerts.prepare()` no longer asks for the notification permission when alerts go to a sink. That happens only
  in tests and the probe.

## The boundary

- **Own windows only.** A process needs no Accessibility permission to drive its own windows. The probe ran untrusted
  (`AXIsProcessTrusted()` false). Other apps' windows need the user's Accessibility grant in System Settings ▸
  Privacy & Security ▸ Accessibility, which a shell-launched process doesn't have on this Mac. The probe never
  addresses another process. The same applies to NiceDock's own window features on other apps; see
  [../apps/accessibility-live.md](../apps/accessibility-live.md).
- **Not exercised.**
  - Pop-up buttons and `Menu`s (Temperature unit, Running apps, Calendar, Digits, the Converter's currency capsules,
    the profile and display "More" menus). They open an `NSMenu`; their values are read only.
  - The controls listed under "Never pressed" above.
  - The Settings "replace" layouts and Dock auto-hide (intent-only coverage is in `SettingsBehaviourTests`).
- **Gesture-only tiles outside the probe.** About 60 tap handlers remain in widgets that are not in the probe's profile:
  calendar, weather, system, apps, media and others. The same `accessibilityPress` modifier fixes each one.
- **Left on disk by any run of the app bundle.** The probe leaves nothing in its support folder. macOS still writes
  the URL cache (`~/Library/Caches/app.nicedock.NiceDock`, `~/Library/HTTPStorages/app.nicedock.NiceDock`) and the
  Settings and Widgets window frames (`defaults read app.nicedock.NiceDock`). Remove them with
  `defaults delete app.nicedock.NiceDock` and by deleting those two folders.
