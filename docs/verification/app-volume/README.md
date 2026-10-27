# App Volume: per-app volume and mute (Core Audio process taps)

Each app that is producing sound gets its own slider and mute: in the Audio widget's panel (new **App Volume**
section under the output devices) and in the new **App Volume** widget (Controls, next to Audio; up to three
playing apps, click a name for the full list). Settings → Widgets → App Volume has **Remember volume per app** and
**Reset All**; Settings → Privacy & Permissions lists **System Audio Recording**. macOS 14.2 or later; before that
the widget is not offered and the panel section is hidden.

## How it works

| Piece | File |
|---|---|
| Levels, gain math, real-time render routine, aggregate description, process grouping / diff / tap plan, the tap object | `Sources/CoolDock/Widgets/Utility/UtilAppVolumeEngine.swift` |
| Service: process list, listeners, taps on a serial queue, persistence, permission | `…/UtilAppVolumeService.swift` |
| Tile, panel rows, Audio panel section, Settings group | `…/UtilAppVolumeViews.swift` |

* **No tap at 100 %.** An app gets a tap only while its volume is below 100 % or it is muted
  (`UtilAppVolumeModel.plan`). Dragging the slider to the end (≥ 99.5 %) removes the tap and its aggregate.
* **Tap**: `CATapDescription(stereoMixdownOfProcesses:)` over all of the app's process objects, `muteBehavior = .muted`,
  private. **Aggregate**: private, not stacked, the default output's UID as main sub-device, the tap with drift
  compensation, `tapautostart`. Its IO block (`UtilAppVolumeDSP.render`, HAL IO thread, nil queue) writes
  input × gain to the output: no allocation, no locks, no actors; the gain is one aligned `Float` in a heap struct
  that the main thread stores into and the IO thread reads; gain changes ramp over one buffer.
* **IO only while the app plays.** A paused app keeps its tap (it stays muted, so resuming never blasts at full
  volume) but its IO is stopped: no IO thread, no CPU.
* **Apps, not processes**: processes are grouped by the app responsible for them
  (`responsibility_get_pid_responsible_for_pid`): Chrome's helpers → Chrome, Safari's WebKit GPU process → Safari,
  a command-line tool → the terminal app that started it (or its executable path). CoolDock never lists itself.
* **Event-driven only**: listeners on `kAudioHardwarePropertyProcessObjectList`, `kAudioHardwarePropertyDefaultOutputDevice`
  and each process's IsRunning / IsRunningOutput. They run while an App Volume view is shown or while any app has a
  changed level; no timers. Gotcha found on macOS 27.0.1: `kAudioProcessPropertyIsRunningOutput` never posts a change
  notification, `kAudioProcessPropertyIsRunning` does, so both are observed and IsRunningOutput is re-read.
* **Default output changes** rebuild every aggregate on the new device (new tap + aggregate made first, old IO stopped,
  new IO started, old destroyed: both taps mute the app meanwhile, so no full-volume blip). A browser that spawns
  another audio helper is handled the same way.
* **Cleanup**: tap and aggregate are destroyed at 100 %, when the app's processes go away, on Reset All, and on quit
  (`applicationWillTerminate` → `shutdown()`, bounded to 1.5 s). CoolDock's aggregates are hidden from the Audio
  widget's output list.
* **Persistence**: `Settings.appVolumes` (`[bundle id: {volume, muted}]`, only changed apps, optional so older
  state files load) and `Settings.appVolumeRemember` (default on), saved through `AppStore` 0.6 s after the last
  change, so `AppStore.persistenceEnabled` (renders, tests) is respected. With Remember off a level lasts while the app
  runs. Remembered levels apply as soon as the app appears (CoolDock starts listening at launch when any exist).
* **Permission**: `NSAudioCaptureUsageDescription` is in `Resources/Info.plist`. TCC's read-only preflight is
  checked before creating taps, when a view appears and 1.5 s / 6 s after a tap starts; denied removes every tap
  (apps play normally), disables the sliders and shows a short hint with **Open Privacy Settings**
  (`appVolume-denied`, `appVolume-panel-denied`). When CoolDock ran as its own responsible process (launched outside a
  terminal that already has the permission), `AudioDeviceCreateIOProcIDWithBlock` for the first tap stayed blocked in
  a reply from coreaudiod (`sample` stack), consistent with macOS waiting for the System Audio Recording prompt to be
  answered. That wait is on the tap queue: the UI stays responsive, the app is muted rather than loud, and after
  1.2 s the same hint appears.
  A tap that can't be created marks that app's slider disabled with a warning icon and resets its level.

## Evidence (macOS 27.0.1, MacBook speakers 48 kHz)

| Check | Result |
|---|---|
| `swift test --filter AppVolume` | 22 tests: clamping / snapping / NaN, linear gain, mute = 0; render routine on hand-built buffer lists (stereo at 0.5 exact, one-buffer ramp, mute exactly 0, stereo → mono average, extra output channels and buffers silent, non-interleaved and short input, no input, Float32 only); aggregate dictionary (keys `name uid master private stacked tapautostart subdevices taps`, one sub-device, one drift-compensated tap); process-list diff, grouping of Chrome helpers and WebKit, tap plan (create only for changed levels, gain / process / running updates, destroy at 100 %, on exit and when denied, failed apps not retried); persistence (Settings round trip keyed by bundle id, pre-App-Volume state files, pruning of defaults, reload in a new session, Reset All, Remember off) |
| `COOLDOCK_LIVE_AUDIO=1 swift test --filter AppVolumeLive` | passed 3 of 3 runs (plus earlier ones); see the log below |
| Full `swift test` | 372 tests pass (opt-in suites skipped) |
| `scripts/build-app.sh release` | 0 warnings |
| `scripts/pixel-diff.sh` | 74/74 frames, mean 99.76 %, audioControls 99.71 %, min 99.10 % (nowPlaying); every frame's match, strict match and RMSE identical to the unmodified commit built side by side |
| `scripts/chrome-check.sh` | 111 widgets, 30/30 tiles without a site frame on the reference chrome; appVolume 448×124 px, corners 99.99 %. (After the session moved to a shell with Photos access, recentPhoto showed a live full-bleed photo and failed the corner check: 28/29 on the unmodified commit too) |
| `python3 scripts/l10n.py check` | 10 languages × 1319 strings, 0 missing, 0 stale (21 new) |

Live test log (the tone is a 5 s, 220 Hz sine at 0.1 played by `/usr/bin/afplay`; peaks are measured inside the IO
block over 0.5 s):

```
AppVolumeLive: afplay pid 94188 → key com.mitchellh.ghostty, process objects [120]
AppVolumeLive: setVolume → tap built 31 ms, first IO cycle 53 ms, afplay's audio in the IO block 53 ms
AppVolumeLive: 50 %: input peak 0.10000, output peak 0.05000, ratio 0.50000 over 49 IO cycles (build 31 ms)
AppVolumeLive: muted: input peak 0.10000, output peak 0.00000
AppVolumeLive: 100 %: tap removed, aggregate in HAL: false, tap in HAL: false
AppVolumeLive: afplay exited (status 0): tap removed, aggregate in HAL: false
AppVolumeLive: second afplay, remembered 50 %: input 0.10000, output 0.05000
AppVolumeLive: shutdown: aggregate in HAL false, tap in HAL false
```

afplay is attributed to the terminal that launched it (Ghostty here; in a shell without a responsible app the key
was `/usr/bin/afplay`). Over the runs the tap was built in 25–33 ms and afplay's audio reached the IO block 53–398 ms
after `setVolume` (the first run of a session is the slow one); the app is muted, not loud, in between.

### Memory and CPU (release build, App Volume + Audio widgets on screen)

Measured from outside with `proc_pid_rusage` (CPU time, phys footprint), `footprint -p` and `ps`, while a 12 s
quiet tone played with a remembered level of 50 % (`COOLDOCK_SUPPORT_DIR` = a temporary state):

| State | CPU (whole app) | phys footprint | RSS | IO thread |
|---|---|---|---|---|
| idle, no tap | 0.04–0.35 % | 26.5 MB | 77–88 MB | none |
| tap active (afplay at 50 %) | 0.24–0.30 % | 28.2 MB | 83–90 MB | `com.apple.audio.IOThread.client` present (`sample`) |
| after afplay exited (tap removed) | 0.07 % | 27.0 MB | 83–90 MB | none |

So one active tap costs about 1.7 MB and a few tenths of a percent of one core (the render routine itself is a copy
and multiply of 1024 samples per 10.7 ms buffer); at 100 % there is no tap and no cost.

## Frames

`{en,fa}-appVolume.png` (tile: Music 72 %, Safari 35 %, Zoom muted), `-appVolume-panel` (the widget's panel),
`-appVolume-denied` / `-appVolume-panel-denied` (System Audio Recording denied: hint, disabled sliders),
`-appVolume-empty` (nothing playing), `-audioControls-panel` (the Audio widget's popover with the new section; the
collapsed Audio tile is unchanged). Reference-scene data, rendered with:

```bash
scripts/build-app.sh release
COOLDOCK_SUPPORT_DIR=$(mktemp -d) build/CoolDock.app/Contents/MacOS/CoolDock --render <dir> \
  appVolume,appVolume-panel,appVolume-denied,appVolume-empty,appVolume-panel-denied,audioControls-panel \
  --scene reference --lang en   # and --lang fa
```

Persian frames are right-to-left with Estedad: sliders fill from the right, the mute badge and percentages sit on
the trailing side, digits are Persian. App names are content and stay as macOS reports them. Zoom isn't installed
on this Mac, so its icon is the drawn stand-in used for apps without a bundle icon.
