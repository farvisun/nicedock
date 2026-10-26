#!/bin/bash
# Builds CoolDock.app into ./build. Usage: scripts/build-app.sh [debug|release] [--run]
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
APP="build/CoolDock.app"

swift build -c "$CONFIG" --product CoolDock
BIN="$(swift build -c "$CONFIG" --show-bin-path)/CoolDock"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Fonts"
cp "$BIN" "$APP/Contents/MacOS/CoolDock"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Fonts/*.ttf Resources/Fonts/*.txt "$APP/Contents/Resources/Fonts/"
for lproj in Resources/*.lproj; do cp -R "$lproj" "$APP/Contents/Resources/"; done

if [ ! -f build/AppIcon.icns ] || [ scripts/make-icon.swift -nt build/AppIcon.icns ]; then
  rm -rf build/AppIcon.iconset
  swift scripts/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if [ "$CONFIG" = "release" ]; then strip -x "$APP/Contents/MacOS/CoolDock" || true; fi
codesign --force --deep --sign - --timestamp=none "$APP" >/dev/null
echo "Built $APP ($(du -sh "$APP" | cut -f1))"

if [ "${2:-}" = "--run" ]; then
  pkill -x CoolDock || true
  open "$APP"
fi
