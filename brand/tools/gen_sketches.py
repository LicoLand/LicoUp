#!/usr/bin/env python3
"""LicoUp logo form exploration - 12 pure-silhouette thumbnail concepts.
No texture, no randomness: every mark is deterministic hand-placed geometry.
All concepts express one gesture: left & right converge and clasp at center.
Renders SVGs -> PNG via headless Chrome, then composes a contact sheet with
64px small-size readability insets."""
import math, os, subprocess
from PIL import Image, ImageDraw, ImageFont

BASE = os.path.join(os.path.dirname(__file__), "..", "sketches")
SVG_DIR = os.path.join(BASE, "svg")
PNG_DIR = os.path.join(BASE, "png")
os.makedirs(SVG_DIR, exist_ok=True)
os.makedirs(PNG_DIR, exist_ok=True)

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
INK = "#17171B"
VW, VH = 400, 300           # svg viewBox
RW, RH = 800, 600           # render size

def P(cx, cy, r, deg):
    a = math.radians(deg)
    return (cx + r * math.cos(a), cy + r * math.sin(a))

def arc(cx, cy, r, a0, a1, sweep=1):
    """SVG arc path from angle a0 to a1 (degrees). sweep=1: increasing angle."""
    x0, y0 = P(cx, cy, r, a0); x1, y1 = P(cx, cy, r, a1)
    large = 1 if abs(a1 - a0) > 180 else 0
    return f"M {x0:.1f} {y0:.1f} A {r} {r} 0 {large} {sweep} {x1:.1f} {y1:.1f}"

def st(path, w=24, extra=""):
    return (f'<path d="{path}" fill="none" stroke="{INK}" stroke-width="{w}" '
            f'stroke-linecap="round" stroke-linejoin="round" {extra}/>')

def stc(path, w, color, extra=""):
    return (f'<path d="{path}" fill="none" stroke="{color}" stroke-width="{w}" '
            f'stroke-linecap="round" stroke-linejoin="round" {extra}/>')

def solid(path, color=INK):
    return f'<path d="{path}" fill="{color}"/>'

def circ(cx, cy, r, w=24):
    return (f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="none" stroke="{INK}" '
            f'stroke-width="{w}"/>')

def dot(cx, cy, r, color=INK):
    return f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="{color}"/>'

def wrap(body):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{RW}" height="{RH}" '
            f'viewBox="0 0 {VW} {VH}">'
            f'<rect width="{VW}" height="{VH}" fill="white"/>{body}</svg>')

CONCEPTS = {}

# A 双钩相扣: two C-hooks, mouths facing, tips inside each other's mouths
CONCEPTS["A"] = ("双钩相扣", wrap(
    st(arc(156, 150, 60, -50, 230, sweep=1) , 24) +           # left hook, opening right
    st(arc(244, 150, 60, 130, 410, sweep=1), 24)))            # right hook, opening left

# B 等径双环互扣: classic interlocked rings, left over at top / under at bottom
_c = dict(cx=140, cy=150, r=70)
_b_gap = (19, 43)           # bottom crossing gap on left ring (under)
_b_over = (-43, -19)        # top crossing over-arc (halo)
CONCEPTS["B"] = ("等径双环", wrap(
    circ(260, 150, 70, 24) +
    stc(arc(_c["cx"], _c["cy"], _c["r"], _b_over[0], _b_over[1]), 36, "white") +
    st(arc(_c["cx"], _c["cy"], _c["r"], _b_over[0], _b_over[1]), 24) +
    st(arc(_c["cx"], _c["cy"], _c["r"], _b_gap[1], _b_gap[0] + 360), 24)))

# C 插销入扣: tongue slides through the buckle frame's left edge (gap = entry)
_buckle = ("M 210 128 V 122 Q 210 102 230 102 H 290 Q 310 102 310 122 "
           "V 178 Q 310 198 290 198 H 230 Q 210 198 210 178 V 172")
_tongue = ("M 95 131 L 235 131 L 235 119 L 268 148 L 235 177 L 235 165 "
           "L 95 165 Z")
CONCEPTS["C"] = ("插销入扣", wrap(st(_buckle, 22) + solid(_tongue)))

# D 无限中扣: two loops tangent at center, clamped by a solid buckle node
CONCEPTS["D"] = ("无限中扣", wrap(
    circ(146, 150, 52, 22) + circ(254, 150, 52, 22) +
    '<rect x="175" y="126" width="50" height="48" rx="13" fill="white"/>'
    '<rect x="179" y="130" width="42" height="40" rx="10" fill="' + INK + '"/>'))

# E 双L互钩: mirrored L letterforms (LicoUp) with hook tips approaching
CONCEPTS["E"] = ("双L互钩", wrap(
    st("M 125 75 V 195 H 215 V 168", 24) +
    st("M 275 225 V 105 H 185 V 132", 24)))

# F 汇聚上扬: two flows merge into one upward arrow (Link -> Up)
_arrow = "M 170 108 L 230 108 L 200 60 Z"
CONCEPTS["F"] = ("汇聚上扬", wrap(
    st("M 78 216 Q 145 200 194 156", 24) +
    st("M 322 216 Q 255 200 206 156", 24) +
    st("M 200 150 V 98", 24) + solid(_arrow)))

# G 大小双环: big platform link clasped with small node link (weave like B)
CONCEPTS["G"] = ("大小双环", wrap(
    circ(255, 150, 56, 24) +
    stc(arc(140, 150, 78, -38, -14), 36, "white") +
    st(arc(140, 150, 78, -38, -14), 24) +
    st(arc(140, 150, 78, 38, 346), 24)))

# H 盾形齿合: two halves locked by a central tooth seam -> shield = security
_shield = ("M 200 84 C 160 84 128 90 106 100 C 110 168 152 212 200 234 "
           "C 248 212 290 168 294 100 C 272 90 240 84 200 84 Z")
_seam = "M 200 92 L 200 138 L 216 138 L 216 162 L 200 162 L 200 226"
CONCEPTS["H"] = ("盾形齿合", wrap(solid(_shield) + stc(_seam, 5, "white")))

# I 穿环插销: pin pierces ring edge (gap) and locks with a knob inside
CONCEPTS["I"] = ("穿环插销", wrap(
    st(arc(255, 150, 58, 197, 523), 22) +
    '<rect x="85" y="139" width="153" height="22" rx="11" fill="' + INK + '"/>' +
    dot(240, 150, 16)))

# J 链环上扬: interlocked rings, right ring exits into an upward tail (Up)
_j_tail_h = "M 300.8 114.4 Q 332 96 346 68"
_j_head = "M 346 56 L 360 84 L 333 76 Z"
CONCEPTS["J"] = ("链环上扬", wrap(
    circ(250, 150, 62, 22) +
    stc(arc(150, 150, 62, -48, -24), 34, "white") +
    st(arc(150, 150, 62, -48, -24), 22) +
    st(arc(150, 150, 62, 48, 336), 22) +
    st(_j_tail_h, 20) + solid(_j_head)))

# K 回流中扣: two counter-flows (S) clamped at center node
CONCEPTS["K"] = ("回流中扣", wrap(
    st("M 93 150 A 52 52 0 0 1 197 150 A 52 52 0 0 0 301 150", 24) +
    dot(200, 150, 22, "white") + dot(200, 150, 16)))

# L 方钩握扣: two square hooks gripping side-by-side at center
CONCEPTS["L"] = ("方钩握扣", wrap(
    st("M 122 82 V 196 H 206 V 140", 24) +
    st("M 278 218 V 104 H 194 V 160", 24)))

# ---------------- render ----------------
def render_all():
    for key, (name, svg) in CONCEPTS.items():
        sp = os.path.join(SVG_DIR, f"{key}.svg")
        pp = os.path.join(PNG_DIR, f"{key}.png")
        with open(sp, "w") as f:
            f.write(svg)
        subprocess.run([CHROME, "--headless=new", "--disable-gpu",
                        "--hide-scrollbars", f"--window-size={RW},{RH}",
                        f"--screenshot={pp}", f"file://{sp}"],
                       check=True, capture_output=True, timeout=60)
        print("rendered", key, name)

def sheet():
    cols, rows = 4, 3
    cw, ch, pad, title_h = 620, 470, 30, 56
    W = cols * cw + (cols + 1) * pad
    H = rows * (ch + title_h) + (rows + 1) * pad
    im = Image.new("RGB", (W, H), (245, 245, 247))
    dr = ImageDraw.Draw(im)
    try:
        font = ImageFont.truetype("/System/Library/Fonts/PingFang.ttc", 30)
    except Exception:
        font = ImageFont.load_default()
    keys = sorted(CONCEPTS)
    for idx, key in enumerate(keys):
        name = CONCEPTS[key][0]
        cx0 = pad + (idx % cols) * (cw + pad)
        cy0 = pad + (idx // cols) * (ch + title_h + pad)
        dr.text((cx0 + 6, cy0 + 8), f"{key} · {name}", fill=(20, 20, 24), font=font)
        mark = Image.open(os.path.join(PNG_DIR, f"{key}.png")).convert("RGB")
        mark_big = mark.resize((480, 360), Image.LANCZOS)
        mx = cx0 + (cw - 480) // 2
        my = cy0 + title_h + (ch - 400) // 2
        im.paste(mark_big, (mx, my))
        mini = mark.resize((64, 48), Image.LANCZOS)
        im.paste(mini, (cx0 + cw - 84, cy0 + title_h + ch - 72))
        dr.rectangle([cx0 + cw - 85, cy0 + title_h + ch - 73,
                      cx0 + cw - 19, cy0 + title_h + ch - 7],
                     outline=(180, 180, 186))
        dr.text((cx0 + 6, cy0 + title_h + ch - 58), "64px →", fill=(140, 140, 146))
    out = os.path.join(BASE, "licoup-form-sheet.png")
    im.save(out, quality=95)
    print(out)

render_all()
sheet()
