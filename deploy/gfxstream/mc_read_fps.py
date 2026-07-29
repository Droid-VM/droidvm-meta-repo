#!/usr/bin/env python3
"""Read the fps off a Minecraft F6 capture, and refuse to guess when it cannot.

Minecraft draws the overlay in its own bitmap font at a fixed scale, so the digits are matched
against exact pixel templates rather than run through OCR. No extra dependency beyond Pillow, and
an unrecognised glyph is reported as a failure instead of a plausible-looking wrong number --
which matters here, because a bad fps reading is indistinguishable from a real regression.

Templates live in mc_fps_glyphs.json and were learned from captures whose value was read by eye.
Only the digits seen so far are in there; hitting a new one prints how to add it rather than
failing silently. `--learn <digits>` does that from a capture you have read yourself.

The state check is not decoration. Pressing F6 while GNOME is showing the Activities overview
leaves the game running as a scaled thumbnail: the world still renders, the window is still there,
and the capture looks fine at a glance. A run was scored that way here before this existed. The
overview covers about half the screen in desktop-background grey against 0.5% for a focused
window, which separates them with room to spare.

  mc_read_fps.py <capture.png>            -> "fps=N", exit 0
  mc_read_fps.py --learn 235 <capture.png> -> add that capture's digits to the templates
"""
import json
import os
import sys

try:
    from PIL import Image
except ImportError:
    print("reason=no-pillow (pip install pillow)", file=sys.stderr)
    sys.exit(1)

GLYPHS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "mc_fps_glyphs.json")

# GNOME's desktop background: near-neutral, dark but not black.
BG_LO, BG_HI, BG_NEUTRAL = 20, 60, 8
OVERVIEW_FRACTION = 0.20    # measured: 48% in the overview, 0.5% with the window focused
LIGHT = 560                 # sum(rgb) above this is overlay text, below 380 is its backing plate
GLYPH_H = 9


def desktop_state(im):
    px, (w, h) = im.load(), im.size
    dark = tot = 0
    for y in range(0, h, 4):
        for x in range(0, w, 4):
            r, g, b = px[x, y]
            tot += 1
            if abs(r - g) < BG_NEUTRAL and abs(g - b) < BG_NEUTRAL and BG_LO <= r <= BG_HI:
                dark += 1
    pct = 100.0 * dark / max(tot, 1)
    return ("overview" if pct > OVERVIEW_FRACTION * 100 else "window"), pct


def runs(px, y, xmax=300):
    """Column runs containing overlay-bright pixels, i.e. one per glyph."""
    on = [any(sum(px[x, yy]) > LIGHT for yy in range(y, y + GLYPH_H)) for x in range(xmax)]
    out, start = [], None
    for x, v in enumerate(on):
        if v and start is None:
            start = x
        elif not v and start is not None:
            out.append((start, x))
            start = None
    if start is not None:
        out.append((start, xmax))
    return out


def find_row(im):
    """Top of the fps line. It hugs the left edge of the game window and has several glyphs,
    which is what separates it from the GNOME top bar -- also light-on-dark, also near the top."""
    px = im.load()
    for y in range(60, min(220, im.size[1] - GLYPH_H)):
        r = runs(px, y)
        if r and r[0][0] <= 6 and len(r) >= 4:
            return y
    return None


def cellstr(px, x0, x1, y):
    return "".join("".join("1" if sum(px[x, yy]) > LIGHT else "0" for x in range(x0, x1))
                   for yy in range(y, y + GLYPH_H))


def digit_runs(px, y):
    """The leading glyph runs, up to the wide gap before 'fps'."""
    out, prev = [], None
    for (a, b) in runs(px, y):
        if b - a < 2:                 # the 1px sliver at x=0 is the plate edge, not a glyph
            continue
        if prev is not None and a - prev > 3:
            break
        out.append((a, b))
        prev = b
    return out


def main():
    argv = sys.argv[1:]
    learn = None
    if argv and argv[0] == "--learn":
        if len(argv) != 3:
            print("usage: mc_read_fps.py --learn <digits> <capture.png>", file=sys.stderr)
            return 2
        learn, path = argv[1], argv[2]
    elif len(argv) == 1:
        path = argv[0]
    else:
        print("usage: mc_read_fps.py [--learn <digits>] <capture.png>", file=sys.stderr)
        return 2

    im = Image.open(path).convert("RGB")
    state, pct = desktop_state(im)
    if state == "overview":
        print(f"state=overview bg={pct:.1f}% -- GNOME is in the window picker, so the game is a "
              f"thumbnail and the overlay is unreadable. Click the window, then press F6.",
              file=sys.stderr)
        return 1

    y = find_row(im)
    if y is None:
        print(f"state=window bg={pct:.1f}% reason=no-overlay -- press F6, not F3 (RealVNC "
              f"intercepts F3)", file=sys.stderr)
        return 1

    px = im.load()
    cells = digit_runs(px, y)
    if not cells:
        print(f"state=window bg={pct:.1f}% reason=no-digits row={y}", file=sys.stderr)
        return 1

    tpl = json.load(open(GLYPHS)) if os.path.exists(GLYPHS) else {}

    if learn is not None:
        if len(learn) != len(cells):
            print(f"--learn got {len(learn)} digits but the capture has {len(cells)} glyphs",
                  file=sys.stderr)
            return 1
        for d, (a, b) in zip(learn, cells):
            tpl[d] = cellstr(px, a, b, y)
        json.dump(tpl, open(GLYPHS, "w"), indent=1, sort_keys=True)
        print(f"learned {sorted(set(learn))}; templates now cover {sorted(tpl)}")
        return 0

    out = []
    for (a, b) in cells:
        key = cellstr(px, a, b, y)
        hit = next((d for d, t in tpl.items() if t == key), None)
        if hit is None:
            print(f"state=window bg={pct:.1f}% reason=unknown-glyph x={a}..{b} "
                  f"known={sorted(tpl)} -- read it by eye and run: "
                  f"mc_read_fps.py --learn <digits> {os.path.basename(path)}", file=sys.stderr)
            return 1
        out.append(hit)

    print(f"fps={''.join(out)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
