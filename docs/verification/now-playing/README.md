# Now Playing from any app (MediaRemote)

The Now Playing widgets follow whatever app owns the system's Now Playing session: Safari, Chrome, Firefox,
Podcasts, VLC, IINA, TV, Music, Spotify and so on.

Since macOS 15.4 the MediaRemote daemon only answers Apple-signed clients; a direct call from NiceDock gets an
empty answer. NiceDock runs `/usr/bin/perl` (an Apple platform binary) with a small helper library
(`Helpers/MediaRemote/CoolDockMediaRemote.m`, bundled as `Contents/Resources/MediaRemote`). The helper streams one
JSON object per line on every change and takes `play`, `pause`, `toggle`, `next`, `previous`, `seek` on stdin. It
exits when NiceDock closes the pipe, so it never outlives the app. When the helper can't run, the widgets fall back to
the Music and Spotify notifications and AppleScript as before.

## Evidence (macOS 27.0.1)

| Check | Result |
|---|---|
| Direct MediaRemote call from an unsigned process, with a probe track published | 0 keys, pid 0 (refused) |
| Same call through `/usr/bin/perl` + helper | title, artist, album, duration, elapsed, rate, playing, pid, artwork |
| `Tests/Fixtures/mediaremote/probe-stream.jsonl` | the bundled helper's real output: ready → track → track + artwork → after `pause` → after the probe quit (`none`) |
| `COOLDOCK_LIVE_MEDIA=1 swift test --filter MediaRemoteLive` | the test process publishes a track with MPNowPlayingInfoCenter, reads it back through `MediaRemoteBridge` (its own pid), sends `pause`, receives the command in its MPRemoteCommandCenter handler and sees the paused state reported back. Passed 3 of 3 runs. Opt-in because it briefly becomes the system's Now Playing app; it skips itself if something else is playing |
| `swift test --filter MediaRemoteStream` | chunked line parsing, decoding, position carried forward from the sample timestamp, rate and clamping, artwork decoded once per artwork id, `none` clears the widget, browser playback named after the parent app |
| Helper cost | 4.7 MB footprint, 0.0 % CPU while idle; only runs while a Now Playing widget or "while playing" rule is in use |

`{en,fa}-nowPlaying.png` and `{en,fa}-nowPlayingHero.png` are live `--render` frames (not reference-scene data)
taken while a probe process that is neither Music nor Spotify published "NiceDock Probe Song" with artwork:

```bash
scripts/build-app.sh release
# probe: any process that sets MPNowPlayingInfoCenter.default().nowPlayingInfo and playbackState = .playing
COOLDOCK_OFFLINE=1 build/NiceDock.app/Contents/MacOS/NiceDock --render <dir> nowPlaying,nowPlayingHero --wait 4 --lang en|fa
```
