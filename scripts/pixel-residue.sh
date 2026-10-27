#!/bin/zsh
# Classifies the residue left by scripts/pixel-diff.sh: anti-aliasing / sub-pixel placement on edges vs real
# differences in flat areas.
#
#   scripts/pixel-residue.sh [--out dir] [kind ...]        (run scripts/pixel-diff.sh first; renders are reused)
#
# Reads <out>/metrics.tsv and <out>/render/<kind>.png (default out = build/pixel-report), compares each render
# with docs/reference/<kind>.png on the reference canvas exactly like pixel-diff.sh, and writes <out>/residue.tsv.
#
# Every test below is ImageMagick's own `compare -fuzz FUZZ` per-pixel test (default FUZZ 8%), the one behind
# pixel-diff.sh's match column. A pixel "differs" when any colour channel differs by more than the fuzz
# threshold (ImageMagick 7.1.2 compares each channel against FUZZ x sqrt(2) of full scale, e.g. 29/255 at 8%).
# pixel-diff.sh's match % is ImageMagick's AE metric, which in 7.1.2 is weighted: each out-of-fuzz channel adds
# its difference (0-1) / 3, so a slightly-off pixel counts less than 1 and match % reads higher than the plain
# pixel counts below.
#
#   mismatch_px_pct     share of all pixels that differ (plain count, unweighted)
#   edge_px_pct         share of pixels "within 1 px of a reference edge": some pixel of its 3x3 neighbourhood in
#                       the reference differs from it by more than the fuzz (local contrast above the threshold)
#   on_edge_pct         share of the differing pixels that are edge pixels (= anti-aliasing / sub-pixel residue)
#   ae_on_edge_pct      share of pixel-diff.sh's AE (the weighted error behind its match %) that sits on edge pixels
#   shift_tol_pct       shift-tolerant match: a render pixel matches if ANY reference pixel in its 3x3
#                       neighbourhood is within the fuzz (forgives misplacement by up to 1 px in x and y)
#   flat_match_pct      match % over the non-edge pixels only (where a <= 1 px shift cannot cause a difference)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 - "$ROOT" "${FUZZ:-8%}" "$@" <<'EOF'
import os, sys, shutil, subprocess, statistics, tempfile
from concurrent.futures import ThreadPoolExecutor

root, fuzz, args = sys.argv[1], sys.argv[2], sys.argv[3:]
out = f'{root}/build/pixel-report'
if args[:1] == ['--out']:
    out, args = args[1], args[2:]
ref_dir = f'{root}/docs/reference'
try:
    rows = [l.rstrip('\n').split('\t') for l in open(f'{out}/metrics.tsv')][1:]
except FileNotFoundError:
    sys.exit(f'no {out}/metrics.tsv: run scripts/pixel-diff.sh first')
kinds = args or [r[0] for r in rows if os.path.exists(f'{out}/render/{r[0]}.png')]
SHIFTS = [(dx, dy) for dy in (-1, 0, 1) for dx in (-1, 0, 1)]


def magick(*a):
    return subprocess.run(['magick', *map(str, a)], capture_output=True, text=True)


def mask(a, b, dst):
    """White where ImageMagick's compare test at FUZZ says the pixel differs."""
    magick('compare', '-fuzz', fuzz, '-highlight-color', 'white', '-lowlight-color', 'black', '-compose', 'src',
           a, b, dst)
    magick(dst, '-alpha', 'off', '-colorspace', 'gray', '-threshold', '50%', dst)


def count(img):
    r = magick(img, '-format', '%[fx:mean*w*h]', 'info:')
    return round(float(r.stdout.strip()))


def ae(a, b):
    r = magick('compare', '-metric', 'AE', '-fuzz', fuzz, a, b, 'null:')
    return float(r.stderr.split()[0])


def analyse(kind):
    tmp = tempfile.mkdtemp(prefix=f'residue-{kind}-', dir=out)
    try:
        ref = f'{ref_dir}/{kind}.png'
        w, h = magick('identify', '-format', '%w %h', ref).stdout.split()
        n = int(w) * int(h)
        cmp_ = f'{tmp}/cmp.png'  # same canvas handling as pixel-diff.sh
        magick(f'{out}/render/{kind}.png', '-background', '#0B0B0B', '-gravity', 'center', '-extent', f'{w}x{h}', cmp_)
        refs = {}
        for dx, dy in SHIFTS:  # shifted(x, y) = ref(x + dx, y + dy), edges replicated
            p = f'{tmp}/ref{dx}{dy}.png'
            magick(ref, '-virtual-pixel', 'edge', '-define', f'distort:viewport={w}x{h}+{dx}+{dy}', '-filter', 'point',
                   '-distort', 'SRT', '0', '+repage', p)
            refs[dx, dy] = p
        m = f'{tmp}/m.png'; mask(ref, cmp_, m)
        edge_parts, shift_parts = [], []
        for d, p in refs.items():
            s = f'{tmp}/s{d[0]}{d[1]}.png'; mask(p, cmp_, s); shift_parts.append(s)
            if d != (0, 0):
                e = f'{tmp}/e{d[0]}{d[1]}.png'; mask(ref, p, e); edge_parts.append(e)
        e = f'{tmp}/edge.png'; magick(*edge_parts, '-evaluate-sequence', 'max', e)
        s = f'{tmp}/shift.png'; magick(*shift_parts, '-evaluate-sequence', 'min', s)
        me = f'{tmp}/me.png'; magick(m, e, '-evaluate-sequence', 'min', me)
        flat = f'{tmp}/flat.png'; magick(e, '-negate', flat)
        mf = f'{tmp}/mf.png'; magick(m, flat, '-evaluate-sequence', 'min', mf)
        on_edge_render = f'{tmp}/cmp-edge.png'  # render on edge pixels, reference elsewhere
        magick(ref, cmp_, e, '-composite', on_edge_render)
        nm, ne, nme, nmf, ns = count(m), count(e), count(me), count(mf), count(s)
        ae_all, ae_edge = ae(ref, cmp_), ae(ref, on_edge_render)
        return [kind, n, nm, 100 * (1 - nm / n), 100 * nm / n, 100 * ne / n,
                100 * nme / nm if nm else 100.0, 100 * ae_edge / ae_all if ae_all else 100.0,
                100 * (1 - ns / n), 100 * (1 - nmf / (n - ne)) if n > ne else 100.0]
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


with ThreadPoolExecutor(min(8, os.cpu_count() or 4)) as ex:
    res = sorted(ex.map(analyse, kinds), key=lambda r: r[3])
head = ['kind', 'pixels', 'mismatch_px', 'pixel_match_pct', 'mismatch_px_pct', 'edge_px_pct', 'on_edge_pct',
        'ae_on_edge_pct', 'shift_tol_pct', 'flat_match_pct']
with open(f'{out}/residue.tsv', 'w') as f:
    f.write('\t'.join(head) + '\n')
    for r in res:
        f.write('\t'.join(str(v) if isinstance(v, (int, str)) else f'{v:.2f}' for v in r) + '\n')
col = lambda i, rs=res: [r[i] for r in rs]
mn = lambda i, rs=res: min(rs, key=lambda r: r[i])
tot_m = sum(col(2)); tot_me = sum(r[2] * r[6] / 100 for r in res)
# The on-edge share of a frame with a handful of differing pixels (e.g. 4 tile-corner pixels) says nothing;
# per-frame on-edge stats use frames with at least 50 differing pixels.
busy = [r for r in res if r[2] >= 50] or res
print(f'{len(res)} frames · fuzz {fuzz} · differing pixels (plain count): mean {statistics.mean(col(4)):.2f}% '
      f'(pixel match mean {statistics.mean(col(3)):.2f}%, min {mn(3)[3]:.2f}% {mn(3)[0]}) · '
      f'on reference edges: {100 * tot_me / tot_m if tot_m else 100:.1f}% of all differing pixels; per frame '
      f'(the {len(busy)} with >= 50 differing px) mean {statistics.mean(col(6, busy)):.1f}%, '
      f'min {mn(6, busy)[6]:.1f}% {mn(6, busy)[0]}; AE weight on edges mean {statistics.mean(col(7, busy)):.1f}% · '
      f'shift-tolerant (3x3) match mean {statistics.mean(col(8)):.3f}%, min {mn(8)[8]:.3f}% {mn(8)[0]} · '
      f'flat-area match mean {statistics.mean(col(9)):.3f}%, min {mn(9)[9]:.3f}% {mn(9)[0]} → {out}/residue.tsv')
EOF
