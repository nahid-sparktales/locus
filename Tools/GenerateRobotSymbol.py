#!/usr/bin/env python3
"""Generate an SF Symbols custom-symbol template SVG for a robot glyph.

All shapes are filled outlines (no strokes) so CoreSVG/actool treat them the
way an SF Symbols export would. Rings are produced with nonzero winding: the
outer contour runs clockwise, the inner one counter-clockwise.
"""
import math, sys

WEIGHTS = ["Ultralight", "Thin", "Light", "Regular", "Medium", "Semibold", "Bold", "Heavy", "Black"]
# Stroke thickness (template units at 100 pt) per weight. Regular ~8 matches SF's regular stems.
STROKE = {"Ultralight": 3.0, "Thin": 4.4, "Light": 6.0, "Regular": 8.0, "Medium": 9.0,
          "Semibold": 10.5, "Bold": 12.0, "Heavy": 13.5, "Black": 15.0}
SCALES = {"S": 0.783, "M": 1.0, "L": 1.288}
# Column centres for the nine weights and baselines for the three scales.
COL_X = [559.5 + i * 296.5 for i in range(9)]
BASELINE = {"S": 696.0, "M": 1196.0, "L": 1696.0}
CAP = 70.457  # cap height of the reference H
# Vertical anchor: the glyph's visual centre sits on the cap-height midline,
# nudged down a little because the antenna is thin and reads lighter.
def midline(scale):
    return BASELINE[scale] - CAP / 2

def fmt(v):
    return f"{v:.3f}".rstrip("0").rstrip(".")

def rounded_rect(cx, cy, w, h, r, clockwise=True):
    """Rounded-rect contour centred on (cx, cy). SVG y grows downward."""
    r = max(0.0, min(r, w / 2, h / 2))
    x0, y0, x1, y1 = cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2
    if clockwise:
        # start top-left after the corner, go right along the top edge
        return (f"M{fmt(x0 + r)} {fmt(y0)} "
                f"L{fmt(x1 - r)} {fmt(y0)} A{fmt(r)} {fmt(r)} 0 0 1 {fmt(x1)} {fmt(y0 + r)} "
                f"L{fmt(x1)} {fmt(y1 - r)} A{fmt(r)} {fmt(r)} 0 0 1 {fmt(x1 - r)} {fmt(y1)} "
                f"L{fmt(x0 + r)} {fmt(y1)} A{fmt(r)} {fmt(r)} 0 0 1 {fmt(x0)} {fmt(y1 - r)} "
                f"L{fmt(x0)} {fmt(y0 + r)} A{fmt(r)} {fmt(r)} 0 0 1 {fmt(x0 + r)} {fmt(y0)} Z")
    else:
        return (f"M{fmt(x0 + r)} {fmt(y0)} "
                f"A{fmt(r)} {fmt(r)} 0 0 0 {fmt(x0)} {fmt(y0 + r)} "
                f"L{fmt(x0)} {fmt(y1 - r)} A{fmt(r)} {fmt(r)} 0 0 0 {fmt(x0 + r)} {fmt(y1)} "
                f"L{fmt(x1 - r)} {fmt(y1)} A{fmt(r)} {fmt(r)} 0 0 0 {fmt(x1)} {fmt(y1 - r)} "
                f"L{fmt(x1)} {fmt(y0 + r)} A{fmt(r)} {fmt(r)} 0 0 0 {fmt(x1 - r)} {fmt(y0)} Z")

def circle(cx, cy, r):
    return (f"M{fmt(cx - r)} {fmt(cy)} "
            f"A{fmt(r)} {fmt(r)} 0 1 1 {fmt(cx + r)} {fmt(cy)} "
            f"A{fmt(r)} {fmt(r)} 0 1 1 {fmt(cx - r)} {fmt(cy)} Z")

def glyph_paths(t, s):
    """Return (paths, bbox) for stroke t at scale s, in local coords (origin = anchor)."""
    # Geometry in unscaled units.
    head_w, head_h, head_r = 88.0, 62.0, 17.0
    head_cy = 7.0
    eye_r = 3.8 + t * 0.45            # 4.7 (ultralight) .. 9.7 (black)
    eye_dx, eye_y = 16.5, 3.5
    mouth_w = 32.0
    mouth_h = max(t * 0.92, 3.0)
    mouth_y = 24.5
    stem_w = max(t * 0.92, 3.0)
    ball_r = 3.4 + t * 0.38           # 4.05 .. 8.25
    head_top = head_cy - head_h / 2   # -21
    stem_top = head_top - 10.0
    ball_cy = stem_top - ball_r + 1.0
    paths = []
    P = lambda cx, cy, w, h, r, cw=True: rounded_rect(cx * s, cy * s, w * s, h * s, r * s, cw)
    C = lambda cx, cy, r: circle(cx * s, cy * s, r * s)
    # Head ring
    paths.append(P(0, head_cy, head_w, head_h, head_r, True)
                 + " " + P(0, head_cy, head_w - 2 * t, head_h - 2 * t, max(head_r - t, 2.5), False))
    # Eyes
    paths.append(C(-eye_dx, eye_y, eye_r))
    paths.append(C(eye_dx, eye_y, eye_r))
    # Mouth
    paths.append(P(0, mouth_y, mouth_w, mouth_h, mouth_h / 2))
    # Antenna stem (overlaps head top slightly so it fuses)
    stem_h = (head_top + t * 0.5) - stem_top
    paths.append(P(0, (stem_top + head_top + t * 0.5) / 2, stem_w, stem_h, stem_w / 2))
    # Antenna ball
    paths.append(C(0, ball_cy, ball_r))
    top = (ball_cy - ball_r) * s
    bottom = (head_cy + head_h / 2) * s
    left = -head_w / 2 * s
    right = head_w / 2 * s
    return paths, (left, top, right, bottom)

def variant(weight, scale):
    t = STROKE[weight]
    s = SCALES[scale]
    paths, (l, top, r, b) = glyph_paths(t, s)
    cx = COL_X[WEIGHTS.index(weight)]
    # Anchor so the glyph's visual centre lands on the cap midline.
    cy = midline(scale) - (top + b) / 2
    bearing = 6.0 * s
    lines = [f'  <g id="{weight}-{scale}" transform="matrix(1 0 0 1 {fmt(cx)} {fmt(cy)})">']
    for d in paths:
        lines.append(f'   <path d="{d}"/>')
    lines.append(f'   <line id="left-margin-{weight}-{scale}" style="fill:none;stroke:#00AEEF;stroke-width:0.5;" '
                 f'x1="{fmt(l - bearing)}" x2="{fmt(l - bearing)}" y1="{fmt(top - 10)}" y2="{fmt(b + 10)}"/>')
    lines.append(f'   <line id="right-margin-{weight}-{scale}" style="fill:none;stroke:#00AEEF;stroke-width:0.5;" '
                 f'x1="{fmt(r + bearing)}" x2="{fmt(r + bearing)}" y1="{fmt(top - 10)}" y2="{fmt(b + 10)}"/>')
    lines.append("  </g>")
    return "\n".join(lines)

FONT = '-apple-system,&quot;SF Pro Display&quot;,&quot;SF Pro Text&quot;,Helvetica,sans-serif'

def build():
    out = []
    out.append('<?xml version="1.0" encoding="UTF-8"?>')
    out.append('<svg version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 3300 2200">')
    out.append(' <g id="Notes">')
    out.append('  <rect height="2200" id="artboard" style="fill:white;opacity:1" width="3300" x="0" y="0"/>')
    out.append(f'  <text style="stroke:none;fill:black;font-family:{FONT};font-weight:bold;" transform="matrix(1 0 0 1 263 322)">Weight/Scale Variations</text>')
    for i, w in enumerate(WEIGHTS):
        out.append(f'  <text style="stroke:none;fill:black;font-family:{FONT};text-anchor:middle;" transform="matrix(1 0 0 1 {fmt(COL_X[i])} 322)">{w}</text>')
    out.append(f'  <text id="template-version" style="stroke:none;fill:black;font-family:{FONT};text-anchor:end;" transform="matrix(1 0 0 1 3036 1933)">Template v.5.0</text>')
    out.append(f'  <text id="descriptive-name" style="stroke:none;fill:black;font-family:{FONT};text-anchor:end;" transform="matrix(1 0 0 1 3036 1957)">locus.robot</text>')
    out.append(' </g>')
    out.append(' <g id="Guides">')
    for scale in ["S", "M", "L"]:
        b = BASELINE[scale]
        out.append(f'  <line id="Capline-{scale}" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="{fmt(b - CAP)}" y2="{fmt(b - CAP)}"/>')
        out.append(f'  <line id="Baseline-{scale}" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="{fmt(b)}" y2="{fmt(b)}"/>')
    out.append(' </g>')
    out.append(' <g id="Symbols">')
    for scale in ["S", "M", "L"]:
        for w in WEIGHTS:
            out.append(variant(w, scale))
    out.append(' </g>')
    out.append('</svg>')
    return "\n".join(out) + "\n"

if __name__ == "__main__":
    sys.stdout.write(build())
