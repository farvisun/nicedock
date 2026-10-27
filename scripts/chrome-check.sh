#!/bin/zsh
# Checks that every widget (including the ones cooldock.app has no reference frame for) is drawn on the
# same tile chrome as the reference frames: 62 pt (124 px @2x) tall, whole-point width, and the four
# 16×16 px corners (rounded edge, hairline border, fill, plate) matching the reference chrome.
#
#   scripts/chrome-check.sh [--no-render] [--lang en] [--out dir]
#
# Widgets that have their own frame in docs/reference are covered by scripts/pixel-diff.sh and only listed.
# Writes <out>/chrome.tsv and prints a summary. Bare widgets (no tile: separator, space…) are listed
# separately (`bare: true` in WidgetCatalog.swift). Canonical corners come from docs/reference/downloads.png
# (a plain tile); corners compare at 4% fuzz so plate (#0B0B0B) vs tile fill (#141414) is distinguished.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/CoolDock.app"
OUT="$ROOT/build/chrome-check"
LANG_CODE=en
RENDER=1
while [ $# -gt 0 ]; do
  case "$1" in
    --no-render) RENDER=0 ;;
    --lang) LANG_CODE="$2"; shift ;;
    --out) OUT="$2"; shift ;;
  esac
  shift
done
mkdir -p "$OUT/render"
if [ $RENDER -eq 1 ]; then
  "$APP/Contents/MacOS/CoolDock" --render "$OUT/render" all --wait 4 --lang "$LANG_CODE" --style darkGlass >/dev/null
fi

REF="$ROOT/docs/reference/downloads.png"
P=16
rw=$(magick identify -format %w "$REF"); rh=$(magick identify -format %h "$REF")
corners=("+0+0" "+$((rw-P))+0" "+0+$((rh-P))" "+$((rw-P))+$((rh-P))")
for i in 1 2 3 4; do magick "$REF" -crop ${P}x${P}${corners[$i]} +repage "$OUT/.ref-c$i.png"; done

# Same full-bleed design as a referenced sibling (the fill reaches the tile corners on purpose).
typeset -A FULLBLEED
FULLBLEED=(posture drinkWater)
BARE=" $(awk '/case \.[a-zA-Z]+:/ { match($0, /case \.[a-zA-Z]+/); k = substr($0, RSTART + 6, RLENGTH - 6) } /bare: true/ { print k }' "$ROOT/Sources/CoolDock/Core/WidgetCatalog.swift" | tr '\n' ' ') "
printf 'kind\tsize\theight_ok\twidth_ok\tcorner_match_pct\tresult\n' > "$OUT/chrome.tsv"
for f in "$OUT"/render/*.png; do
  k=$(basename "$f" .png)
  w=$(magick identify -format %w "$f"); h=$(magick identify -format %h "$f")
  hok=no; [ "$h" -eq 124 ] && hok=yes
  wok=no; [ $((w % 2)) -eq 0 ] && wok=yes
  cs=("+0+0" "+$((w-P))+0" "+0+$((h-P))" "+$((w-P))+$((h-P))")
  total=0
  for i in 1 2 3 4; do
    canon="$OUT/.ref-c$i.png"
    ae=$(magick "$f" -crop ${P}x${P}${cs[$i]} +repage png:- | magick compare -metric AE -fuzz 4% "$canon" - null: 2>&1 | sed -E 's/^([0-9.e+]+).*/\1/' || true)
    total=$(python3 -c "print($total + $ae)")
  done
  pct=$(python3 -c "print(f'{100*(1-$total/(4*$P*$P)):.2f}')")
  res=pass
  if [ "$hok" = no ] || [ "$wok" = no ]; then res=fail; fi
  if python3 -c "import sys; sys.exit(0 if $pct < 97 else 1)"; then res=fail; fi
  [ -f "$ROOT/docs/reference/$k.png" ] && res=referenced
  [ -n "${FULLBLEED[$k]:-}" ] && res="full-bleed"
  case "$BARE" in *" $k "*) res=bare ;; esac
  printf '%s\t%sx%s\t%s\t%s\t%s\t%s\n' "$k" "$w" "$h" "$hok" "$wok" "$pct" "$res" >> "$OUT/chrome.tsv"
done
rm -f "$OUT"/.ref-c*.png
python3 - "$OUT/chrome.tsv" <<'EOF'
import sys
rows = [l.rstrip('\n').split('\t') for l in open(sys.argv[1])][1:]
ref = [r for r in rows if r[5] == 'referenced']
bare = [r for r in rows if r[5] == 'bare']
bleed = [r for r in rows if r[5] == 'full-bleed']
own = [r for r in rows if r[5] in ('pass', 'fail')]
ok = [r for r in own if r[5] == 'pass']
print(f'{len(rows)} widgets: {len(ref)} have a site frame (see pixel-diff) · {len(bare)} bare by design '
      f'({", ".join(r[0] for r in bare)}) · {len(bleed)} full-bleed like a referenced sibling ({", ".join(r[0] for r in bleed)})')
print(f'without a site frame: {len(ok)}/{len(own)} on the reference tile chrome (124 px tall, whole-point width, corners ≥97% at 4% fuzz)')
for r in own:
    if r[5] == 'fail': print('  differs:', r[0], r[1], 'corners', r[4] + '%')
EOF
