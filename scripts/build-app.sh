#!/bin/bash
# Builds NiceDock.app into ./build. Usage: scripts/build-app.sh [debug|release] [--run]
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
APP="build/NiceDock.app"

swift build -c "$CONFIG" --product CoolDock
BIN="$(swift build -c "$CONFIG" --show-bin-path)/CoolDock"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Fonts"
cp "$BIN" "$APP/Contents/MacOS/NiceDock"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Fonts/*.ttf Resources/Fonts/*.txt "$APP/Contents/Resources/Fonts/"
for lproj in Resources/*.lproj; do cp -R "$lproj" "$APP/Contents/Resources/"; done

if [ ! -f build/AppIcon.icns ] || [ scripts/make-icon.swift -nt build/AppIcon.icns ]; then
  rm -rf build/AppIcon.iconset
  swift scripts/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# System-wide Now Playing helper (loaded into /usr/bin/perl, see Helpers/MediaRemote).
mkdir -p "$APP/Contents/Resources/MediaRemote"
# clang leaves an empty folder per architecture step in $TMPDIR; give it a private one and remove it afterwards.
mkdir -p build/.clang-tmp
TMPDIR="$PWD/build/.clang-tmp" clang -dynamiclib -fobjc-arc -O2 -Wall -Werror -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 -framework Foundation \
  Helpers/MediaRemote/CoolDockMediaRemote.m -o "$APP/Contents/Resources/MediaRemote/libCoolDockMediaRemote.dylib"
rm -rf build/.clang-tmp
cp Helpers/MediaRemote/mediaremote.pl "$APP/Contents/Resources/MediaRemote/"

# Sparkle (updates from the GitHub release appcast).
mkdir -p "$APP/Contents/Frameworks"
ditto "$(swift build -c "$CONFIG" --show-bin-path)/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"

if [ "$CONFIG" = "release" ]; then strip -x "$APP/Contents/MacOS/NiceDock" || true; fi
# Sign inside out (no --deep, which would drop the Downloader's entitlements): Sparkle's helpers,
# the framework, the Now Playing helper, then the app.
SIGN=(codesign --force --sign - --timestamp=none)
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
"${SIGN[@]}" "$SPARKLE/XPCServices/Installer.xpc"
"${SIGN[@]}" --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
"${SIGN[@]}" "$SPARKLE/Autoupdate" "$SPARKLE/Updater.app"
"${SIGN[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
"${SIGN[@]}" "$APP/Contents/Resources/MediaRemote/libCoolDockMediaRemote.dylib"
"${SIGN[@]}" "$APP" >/dev/null
echo "Built $APP ($(du -sh "$APP" | cut -f1))"

if [ "${2:-}" = "--run" ]; then
  pkill -x NiceDock || true
  open "$APP"
fi
