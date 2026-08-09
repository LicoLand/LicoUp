#!/usr/bin/env python3
"""LicoUp logo concept generator — parametric, mathematically exact arcs."""
import math, os

OUT = os.path.join(os.path.dirname(__file__), "..", "concepts")
os.makedirs(OUT, exist_ok=True)

# ---------- palette ----------
BLUE_DEEP  = "#1B49E0"
BLUE_MID   = "#2E7FFF"
AZURE      = "#00BFFF"
MINT       = "#00E0B8"
NAVY       = "#0B1E4B"   # mono dark
DARK_BG    = "#0A1226"
LIGHT_BG   = "#F5F8FF"

def pt(cx, cy, r, deg):
    a = math.radians(deg)
    return (cx + r * math.cos(a), cy + r * math.sin(a))

def fmt(p):
    return f"{p[0]:.2f},{p[1]:.2f}"

def arc_seg(cx, cy, r, a1, a2, sweep):
    """SVG arc command from angle a1 to a2 (degrees, increasing = screen clockwise)."""
    p1, p2 = pt(cx, cy, r, a1), pt(cx, cy, r, a2)
    delta = abs(a2 - a1)
    large = 1 if delta > 180 else 0
    return f"A {r:.2f} {r:.2f} 0 {large} {sweep} {fmt(p2)}", p1, p2

def arc_path_with_gaps(cx, cy, r, a_start, a_end, gaps):
    """Build path data for a circle arc from a_start to a_end (increasing angles,
    sweep=1) skipping gap intervals [(g0,g1),...]. Returns path d string."""
    pts = sorted([a_start] + [a_end] +
                 [x for g in gaps for x in g])
    spans = []
    cursor = a_start
    for g0, g1 in sorted(gaps):
        if g0 > cursor:
            spans.append((cursor, g0))
        cursor = max(cursor, g1)
    if cursor < a_end:
        spans.append((cursor, a_end))
    d_parts = []
    for s0, s1 in spans:
        p0 = pt(cx, cy, r, s0)
        seg, _, _ = arc_seg(cx, cy, r, s0, s1, 1)
        d_parts.append(f"M {fmt(p0)} {seg}")
    return " ".join(d_parts)

# ============================================================
# Concept A — "Clasp" 相扣环: two open hooks interlocked in one plane
# ============================================================
R, W = 77, 30
CL, CR = (108, 120), (132, 120)
G_HALF = 14  # gap half-angle at underpasses

def concept_a(stroke_l, stroke_r, extra_defs=""):
    # Left hook: from 35° to 325° (long way through 180°), gap at bottom crossing 81°
    d_left = arc_path_with_gaps(CL[0], CL[1], R, 35, 325, [(81 - G_HALF, 81 + G_HALF)])
    # Right hook: mirrored, from 145° down to -145° (sweep 0), gap at top crossing -99°
    def dec_arc(a1, a2):
        p1, p2 = pt(CR[0], CR[1], R, a1), pt(CR[0], CR[1], R, a2)
        large = 1 if abs(a2 - a1) > 180 else 0
        return f"M {fmt(p1)} A {R} {R} 0 {large} 0 {fmt(p2)}"
    d_right = dec_arc(145, -(99 - G_HALF)) + " " + dec_arc(-(99 + G_HALF), -145)
    defs = f"""
    <linearGradient id="gA-l" gradientUnits="userSpaceOnUse" x1="43" y1="120" x2="165" y2="95">
      <stop offset="0" stop-color="{BLUE_DEEP}"/><stop offset="1" stop-color="{BLUE_MID}"/>
    </linearGradient>
    <linearGradient id="gA-r" gradientUnits="userSpaceOnUse" x1="197" y1="120" x2="75" y2="95">
      <stop offset="0" stop-color="{MINT}"/><stop offset="1" stop-color="{AZURE}"/>
    </linearGradient>{extra_defs}"""
    sl = stroke_l if (stroke_l and stroke_l.startswith("#")) else "url(#gA-l)"
    sr = stroke_r if (stroke_r and stroke_r.startswith("#")) else "url(#gA-r)"
    body = f"""
    <path d="{d_left}" fill="none" stroke="{sl}" stroke-width="{W}" stroke-linecap="round"/>
    <path d="{d_right}" fill="none" stroke="{sr}" stroke-width="{W}" stroke-linecap="round"/>"""
    return defs, body

# ============================================================
# Concept B — "Double-L Knot" 双L结: two L strokes woven into a square
# ============================================================
WB = 28
def concept_b(stroke_l, stroke_r, extra_defs=""):
    d_l = "M 78,54 L 78,166 L 142,166"          # dives under right vertical at 162
    d_r = "M 162,186 L 162,74 L 98,74"          # dives under left vertical at 78
    defs = f"""
    <linearGradient id="gB-l" gradientUnits="userSpaceOnUse" x1="78" y1="54" x2="142" y2="166">
      <stop offset="0" stop-color="{BLUE_MID}"/><stop offset="1" stop-color="{BLUE_DEEP}"/>
    </linearGradient>
    <linearGradient id="gB-r" gradientUnits="userSpaceOnUse" x1="162" y1="186" x2="98" y2="74">
      <stop offset="0" stop-color="{MINT}"/><stop offset="1" stop-color="{AZURE}"/>
    </linearGradient>{extra_defs}"""
    sl = stroke_l if (stroke_l and stroke_l.startswith("#")) else "url(#gB-l)"
    sr = stroke_r if (stroke_r and stroke_r.startswith("#")) else "url(#gB-r)"
    body = f"""
    <path d="{d_l}" fill="none" stroke="{sl}" stroke-width="{WB}" stroke-linecap="round" stroke-linejoin="round"/>
    <path d="{d_r}" fill="none" stroke="{sr}" stroke-width="{WB}" stroke-linecap="round" stroke-linejoin="round"/>"""
    return defs, body

# ============================================================
# Concept C — "Merge & Rise" 汇聚·上扬: two streams fuse, rise as one
# ============================================================
WC = 24
def concept_c(stroke, extra_defs=""):
    d_trunk_left = ("M 120,48 L 120,116 "
                    "C 120,140 106,154 86,161 "
                    "C 72,165.5 58,164 48,156")
    d_right = ("M 192,156 C 182,164 168,165.5 154,161 "
               "C 134,154 120,140 120,116")
    defs = f"""
    <linearGradient id="gC" gradientUnits="userSpaceOnUse" x1="120" y1="180" x2="120" y2="42">
      <stop offset="0" stop-color="{BLUE_DEEP}"/><stop offset="0.55" stop-color="{BLUE_MID}"/>
      <stop offset="1" stop-color="{AZURE}"/>
    </linearGradient>{extra_defs}"""
    s = stroke if (stroke and stroke.startswith("#")) else "url(#gC)"
    body = f"""
    <path d="{d_trunk_left}" fill="none" stroke="{s}" stroke-width="{WC}" stroke-linecap="round"/>
    <path d="{d_right}" fill="none" stroke="{s}" stroke-width="{WC}" stroke-linecap="round"/>"""
    return defs, body

# ---------- write SVG files ----------
def write_svg(name, defs, body, vb=240):
    svg = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {vb} {vb}" '
           f'width="{vb}" height="{vb}">\n<defs>{defs}\n</defs>\n{body}\n</svg>\n')
    path = os.path.join(OUT, name)
    with open(path, "w") as f:
        f.write(svg)
    return path

files = []
for tag, fn in (("a", concept_a), ("b", concept_b), ("c", concept_c)):
    if tag == "c":
        d, b = fn(None); files.append(write_svg(f"licoup-{tag}-gradient.svg", d, b))
        d, b = fn(NAVY);   files.append(write_svg(f"licoup-{tag}-mono.svg", d, b))
        d, b = fn("#FFFFFF"); files.append(write_svg(f"licoup-{tag}-mono-white.svg", d, b))
    else:
        d, b = fn(None, None); files.append(write_svg(f"licoup-{tag}-gradient.svg", d, b))
        d, b = fn(NAVY, NAVY); files.append(write_svg(f"licoup-{tag}-mono.svg", d, b))
        d, b = fn("#FFFFFF", "#FFFFFF"); files.append(write_svg(f"licoup-{tag}-mono-white.svg", d, b))

print("\n".join(files))
