#!/bin/zsh
# Pixel-diffs widget renders against the reference frames in docs/reference.
#
#   scripts/pixel-diff.sh [--no-render] [--app path/to/CoolDock.app] [--out dir] [kind ...]
#
# Renders every reference widget with deterministic reference data (`--scene reference`),
# compares each PNG with ImageMagick and writes <out>/report.md, <out>/report.html and
# <out>/metrics.tsv plus a ref | render | diff strip per widget.
#
# Metrics (per widget, 2x pixels):
#   size   render size must equal reference size exactly
#   match  share of pixels whose colour differs by at most FUZZ (default 8%)
#   strict same with STRICT fuzz (default 3%): catches hairlines and antialiasing shifts
#   rmse   normalised root-mean-square error (0 = identical)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/CoolDock.app"
OUT="$ROOT/build/pixel-report"
FUZZ="${FUZZ:-8%}"
STRICT="${STRICT:-3%}"
RENDER=1
KINDS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --no-render) RENDER=0 ;;
    --app) APP="$2"; shift ;;
    --out) OUT="$2"; shift ;;
    *) KINDS+=("$1") ;;
  esac
  shift
done
REF="$ROOT/docs/reference"
if [ ${#KINDS[@]} -eq 0 ]; then KINDS=($(ls "$REF" | sed -n 's/\.png$//p')); fi
mkdir -p "$OUT/render" "$OUT/strips"

if [ $RENDER -eq 1 ]; then
  "$APP/Contents/MacOS/CoolDock" --render "$OUT/render" "${(j:,:)KINDS}" --scene reference --lang en --style darkGlass >/dev/null
fi

TSV="$OUT/metrics.tsv"
printf 'kind\tref\trender\tsize_ok\tmatch_pct\trmse\tstrict_pct\n' > "$TSV"
for k in "${KINDS[@]}"; do
  r="$REF/$k.png"; o="$OUT/render/$k.png"
  [ -f "$o" ] || { printf '%s\t-\tmissing\tno\t0\t1\t0\n' "$k" >> "$TSV"; continue; }
  rs=$(magick identify -format '%wx%h' "$r"); os=$(magick identify -format '%wx%h' "$o")
  size_ok=no; [ "$rs" = "$os" ] && size_ok=yes
  # Compare on the reference canvas (pads/crops the render if the size differs).
  w=${rs%x*}; h=${rs#*x}
  magick "$o" -background '#0B0B0B' -gravity center -extent "${w}x${h}" "$OUT/strips/.cmp-$k.png"
  ae=$(magick compare -metric AE -fuzz "$FUZZ" "$r" "$OUT/strips/.cmp-$k.png" null: 2>&1 | sed -E 's/^([0-9.e+]+).*/\1/' || true)
  rmse=$(magick compare -metric RMSE "$r" "$OUT/strips/.cmp-$k.png" null: 2>&1 | sed -E 's/.*\(([0-9.e-]+)\).*/\1/' || true)
  ae3=$(magick compare -metric AE -fuzz "$STRICT" "$r" "$OUT/strips/.cmp-$k.png" null: 2>&1 | sed -E 's/^([0-9.e+]+).*/\1/' || true)
  match=$(python3 -c "print(f'{100*(1-float(\"$ae\")/($w*$h)):.2f}')")
  strict=$(python3 -c "print(f'{100*(1-float(\"$ae3\")/($w*$h)):.2f}')")
  magick compare -fuzz "$FUZZ" -highlight-color '#FF2D55' -lowlight-color '#00000000' "$r" "$OUT/strips/.cmp-$k.png" "$OUT/strips/.diff-$k.png" 2>/dev/null || true
  magick "$r" "$OUT/strips/.cmp-$k.png" \( "$r" -modulate 40 "$OUT/strips/.diff-$k.png" -composite \) -background '#555' -splice 6x0 +append -chop 6x0 "$OUT/strips/$k.png"
  rm -f "$OUT/strips/.cmp-$k.png" "$OUT/strips/.diff-$k.png"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$k" "$rs" "$os" "$size_ok" "$match" "$rmse" "$strict" >> "$TSV"
done

python3 - "$OUT" "$FUZZ" "$STRICT" <<'EOF'
import sys, html, statistics
out, fuzz, strict_fuzz = sys.argv[1], sys.argv[2], sys.argv[3]
rows = [l.rstrip('\n').split('\t') for l in open(f'{out}/metrics.tsv')][1:]
rows.sort(key=lambda r: float(r[4]))
matches = [float(r[4]) for r in rows]
sized = sum(r[3] == 'yes' for r in rows)
summary = (f'{len(rows)} widgets · size exact {sized}/{len(rows)} · match (fuzz {fuzz}) '
           f'mean {statistics.mean(matches):.2f}% · median {statistics.median(matches):.2f}% · min {min(matches):.2f}% · '
           f'≥99%: {sum(m >= 99 for m in matches)} · ≥97%: {sum(m >= 97 for m in matches)} · ≥95%: {sum(m >= 95 for m in matches)} · '
           f'strict (fuzz {strict_fuzz}) mean {statistics.mean(float(r[6]) for r in rows):.2f}% · '
           f'RMSE mean {statistics.mean(float(r[5]) for r in rows):.4f}')
md = ['# Pixel diff vs docs/reference', '', summary, '', f'| widget | reference | render | size | match ({fuzz}) | strict ({strict_fuzz}) | RMSE |', '|---|---|---|---|---|---|---|']
md += [f'| {r[0]} | {r[1]} | {r[2]} | {r[3]} | {r[4]}% | {r[6]}% | {float(r[5]):.4f} |' for r in rows]
open(f'{out}/report.md', 'w').write('\n'.join(md) + '\n')
cards = ''.join(f'<div class=c><b>{html.escape(r[0])}</b> <span>{r[4]}% · strict {r[6]}% · RMSE {float(r[5]):.4f} · {r[1]}{"" if r[3]=="yes" else " ≠ " + r[2]}</span>'
                f'<img src="strips/{html.escape(r[0])}.png"></div>' for r in rows)
open(f'{out}/report.html', 'w').write(f'''<!doctype html><meta charset=utf-8><title>CoolDock pixel diff</title>
<style>body{{background:#1c1c1e;color:#eee;font:13px -apple-system;margin:24px}}.c{{margin:0 0 18px}}span{{color:#999;margin-left:8px}}
img{{display:block;margin-top:6px;zoom:.5}}</style><h1>Pixel diff vs reference</h1><p>{summary}</p>
<p>Each strip: reference | CoolDock render | differing pixels (pink) over the dimmed reference.</p>{cards}''')
print(summary)
EOF
