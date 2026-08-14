#!/usr/bin/env python3
"""LicoUp network-constellation logo studies.
Form language: left-right interlocking clasp (ref 7d5e).
Style language: node constellation, thin links, soft shadows (ref 813be).
Rendered programmatically at 2x then downscaled — hi-res PNG first.
"""
import math, os, random
from PIL import Image, ImageDraw, ImageFilter

OUT = os.path.join(os.path.dirname(__file__), "..", "gen3")
os.makedirs(OUT, exist_ok=True)

SS = 2                      # supersample factor
W, H = 2048, 1365           # final canvas (3:2)
CX, CY = W / 2, H / 2
INK = (22, 22, 26, 255)     # near-black
ACCENT = (27, 73, 224, 255) # deep safety blue

def S(v): return v * SS

def node(draw_shadow, draw, x, y, r, color, shadow_blur=18):
    xs, ys, rs = S(x), S(y), S(r)
    # soft shadow on separate layer
    draw_shadow.ellipse([xs + S(7) - rs * 1.12, ys + S(15) - rs * 1.12,
                         xs + S(7) + rs * 1.12, ys + S(15) + rs * 1.12],
                        fill=(0, 0, 0, 60))
    draw.ellipse([xs - rs, ys - rs, xs + rs, ys + rs], fill=color)

def link(draw, x1, y1, x2, y2, width=3, alpha=150, color=(40, 40, 46)):
    draw.line([S(x1), S(y1), S(x2), S(y2)],
              fill=color + (alpha,), width=max(1, int(round(S(width)))))

def canvas():
    im = Image.new("RGBA", (W * SS, H * SS), (255, 255, 255, 255))
    sh = Image.new("RGBA", im.size, (0, 0, 0, 0))
    return im, ImageDraw.Draw(im), sh, ImageDraw.Draw(sh)

def finish(im, sh, path):
    sh = sh.filter(ImageFilter.GaussianBlur(S(11)))
    im = Image.alpha_composite(im, sh)
    im = im.resize((W, H), Image.LANCZOS).convert("RGB")
    im.save(path, quality=95)
    print(path)

def pt(cx, cy, r, deg):
    a = math.radians(deg)
    return (cx + r * math.cos(a), cy + r * math.sin(a))

# ---------------------------------------------------------------- V1: interlocked clasp
def v1(accent=False, fname="licoup-v1-clasp.png"):
    rng = random.Random(7)
    R, SEP = 430, 300
    CL, CR = (CX - SEP / 2, CY), (CX + SEP / 2, CY)
    cross_l, cross_r = 69.6, 249.6          # bottom-crossing angle on L; top-crossing on R
    GAP = 13                                # half-angle of underpass gap
    im, d, sh, dsh = canvas()

    def circle_nodes(center, gap_angle):
        nodes = {}
        for i in range(16):
            a = i * 22.5
            if abs((a - gap_angle + 180) % 360 - 180) < GAP:
                continue                     # node inside underpass gap
            x, y = pt(center[0], center[1], R, a)
            nodes[a] = (x, y)
        return nodes

    NL, NR = circle_nodes(CL, cross_l), circle_nodes(CR, cross_r)

    # strand links (consecutive along circle, skip across gaps)
    for nodes, gap in ((NL, cross_l), (NR, cross_r)):
        angs = sorted(nodes)
        for a1, a2 in zip(angs, angs[1:] + [angs[0] + 360]):
            mid = (a1 + a2) / 2 % 360
            if abs((mid - gap + 180) % 360 - 180) < GAP + 11:
                continue                     # link crosses underpass gap
            x1, y1 = nodes[a1]
            x2, y2 = pt(CL[0] if nodes is NL else CR[0], CY, R, a2)
            link(d, x1, y1, x2, y2)

    # constellation cross-links (faint, distance-limited, within each circle)
    for nodes in (NL, NR):
        keys = sorted(nodes)
        for i, a1 in enumerate(keys):
            for a2 in keys[i + 1:]:
                if abs(a2 - a1) in (22.5,):
                    continue
                x1, y1, x2, y2 = *nodes[a1], *nodes[a2]
                dist = math.hypot(x2 - x1, y2 - y1)
                if dist < 300 and rng.random() < 0.5:
                    link(d, x1, y1, x2, y2, width=2, alpha=70)

    # node sizes
    def size(a, hero):
        return hero[a] if a in hero else 15 + rng.random() * 7

    heroes_l = {180: 46, 337.5: 30, 22.5: 30}
    heroes_r = {0: 46, 157.5: 30, 202.5: 30}
    for a, (x, y) in NL.items():
        node(dsh, d, x, y, size(a, heroes_l), INK)
    for a, (x, y) in NR.items():
        node(dsh, d, x, y, size(a, heroes_r), INK)

    # central lock core + links to the four crossing flanks
    core_col = ACCENT if accent else INK
    flank_angles = [(NL, CL, 45.0), (NL, CL, 90.0), (NR, CR, 225.0), (NR, CR, 270.0)]
    for nodes, c, a in flank_angles:
        if a in nodes:
            link(d, CX, CY, *nodes[a], width=3, alpha=120,
                 color=(27, 73, 224) if accent else (40, 40, 46))
    node(dsh, d, CX, CY, 52, core_col)
    finish(im, sh, os.path.join(OUT, fname))

# ---------------------------------------------------------------- V2: infinity constellation
def v2(accent=False, fname="licoup-v2-infinity.png"):
    rng = random.Random(11)
    A = 640
    im, d, sh, dsh = canvas()
    N = 30
    pts = []
    for i in range(N):
        t = 2 * math.pi * i / N
        den = 1 + math.sin(t) ** 2
        x = CX + A * math.cos(t) / den
        y = CY + A * 0.62 * math.sin(t) * math.cos(t) / den
        pts.append((x, y))
    # skip nodes near center crossing (t≈π/2 & 3π/2 region is ends; crossing at t=0/π)
    # lemniscate crosses center at t=0, π/2? -> with this formula crossing at t=π/2, 3π/2 give (0,0)
    keep = []
    for i, (x, y) in enumerate(pts):
        t = 2 * math.pi * i / N
        gap = math.pi / 2
        dt = min(abs(t - gap), abs(t - 3 * gap), abs(t - 2 * math.pi + gap))
        if abs(x - CX) < 95 and abs(y - CY) < 60:
            continue
        keep.append(i)
    for i, j in zip(keep, keep[1:] + [keep[0]]):
        if (j - i) % N != 1:
            continue
        link(d, *pts[i], *pts[j])
    for ii, i in enumerate(keep):
        for j in keep[ii + 1:]:
            dist = math.hypot(pts[j][0] - pts[i][0], pts[j][1] - pts[i][1])
            if dist < 240 and rng.random() < 0.4:
                link(d, *pts[i], *pts[j], width=2, alpha=70)
    for i in keep:
        x, y = pts[i]
        r = 15 + rng.random() * 7
        if abs(x - CX) > 480:   # loop apexes
            r = 44
        node(dsh, d, x, y, r, INK)
    node(dsh, d, CX, CY, 52, ACCENT if accent else INK)
    near = sorted(keep, key=lambda i: math.hypot(pts[i][0] - CX, pts[i][1] - CY))[:2]
    for i in near:
        link(d, CX, CY, *pts[i], width=3, alpha=110)
    finish(im, sh, os.path.join(OUT, fname))

# ---------------------------------------------------------------- V3: organic plexus clasp
def v3(accent=False, fname="licoup-v3-plexus.png"):
    rng = random.Random(23)
    im, d, sh, dsh = canvas()
    nodes = []
    for cx, n in ((CX - 330, 16), (CX + 330, 16)):
        for _ in range(n):
            a = rng.uniform(0, 2 * math.pi)
            rr = math.sqrt(rng.random())
            x = cx + 300 * rr * math.cos(a)
            y = CY + 330 * rr * math.sin(a)
            nodes.append((x, y, 12 + rng.random() * 10))
    for _ in range(9):                       # central knot
        a = rng.uniform(0, 2 * math.pi)
        rr = math.sqrt(rng.random())
        nodes.append((CX + 150 * rr * math.cos(a), CY + 150 * rr * math.sin(a),
                      13 + rng.random() * 9))
    nodes += [(CX - 330, CY, 48), (CX + 330, CY, 48), (CX, CY, 54)]
    for i, (x1, y1, _) in enumerate(nodes):
        for x2, y2, _ in nodes[i + 1:]:
            dist = math.hypot(x2 - x1, y2 - y1)
            if dist < 235:
                w_, a_ = (3, 150) if dist < 150 else (2, 80)
                link(d, x1, y1, x2, y2, width=w_, alpha=a_)
    for x, y, r in nodes:
        col = ACCENT if (accent and abs(x - CX) < 1 and abs(y - CY) < 1) else INK
        node(dsh, d, x, y, r, col)
    finish(im, sh, os.path.join(OUT, fname))

# ---------------------------------------------------------------- V4: shared clasp nodes
def v4(accent=False, dense=False, fname="licoup-v4-clasp-nodes.png"):
    """Two node-rings that literally SHARE two nodes at the crossings:
    the left and right rings clasp through the shared top/bottom lock nodes."""
    rng = random.Random(5)
    R, SEP = 430, 300
    CL, CR = (CX - SEP / 2, CY), (CX + SEP / 2, CY)
    X_TOP, X_BOT = 69.6, 290.4            # crossing angles on left circle
    im, d, sh, dsh = canvas()

    left_angles  = [0, 30, 69.6, 90, 120, 150, 180, 210, 240, 270, 290.4, 330]
    right_angles = [0, 30, 60, 90, 110.4, 150, 180, 210, 249.6, 270, 300, 330]
    # under-strand: links adjacent to these are omitted (it dives below)
    skip_left  = {X_BOT}                  # left dives under at bottom crossing
    skip_right = {249.6}                  # right dives under at top crossing

    NL = {a: pt(CL[0], CL[1], R, a) for a in left_angles}
    NR = {a: pt(CR[0], CR[1], R, a) for a in right_angles}

    def ring_links(nodes, skips):
        angs = sorted(nodes)
        for a1, a2 in zip(angs, angs[1:] + [angs[0] + 360]):
            if (a1 % 360) in skips or (a2 % 360) in skips:
                continue
            link(d, *nodes[a1], *pt(CR[0] if nodes is NR else CL[0], CY, R, a2),
                 width=2.6 if dense else 3, alpha=150)

    ring_links(NL, skip_left)
    ring_links(NR, skip_right)

    chord_prob, chord_alpha = (0.55, 80) if dense else (0.32, 55)
    for nodes in (NL, NR):
        keys = sorted(nodes)
        for i, a1 in enumerate(keys):
            for a2 in keys[i + 1:]:
                if abs(a2 - a1) < 45 or a1 in (X_BOT,) or a2 in (249.6,):
                    continue
                x1, y1, x2, y2 = *nodes[a1], *nodes[a2]
                if math.hypot(x2 - x1, y2 - y1) < 330 and rng.random() < chord_prob:
                    link(d, x1, y1, x2, y2, width=2, alpha=chord_alpha)

    sizes_l = {180: 48, 270: 28}
    sizes_r = {0: 48, 90: 28}
    shared = {X_BOT, 290.4}               # left-circle angles of shared nodes
    for a, (x, y) in NL.items():
        if a in shared:
            continue
        node(dsh, d, x, y, sizes_l.get(a, 14 + rng.random() * 5), INK)
    for a, (x, y) in NR.items():
        if pt(CR[0], CR[1], R, a) in [NL[X_BOT], NL[290.4]]:
            continue
        node(dsh, d, x, y, sizes_r.get(a, 14 + rng.random() * 5), INK)
    for a in sorted(shared):
        node(dsh, d, *NL[a], 40, ACCENT if accent else INK)
    finish(im, sh, os.path.join(OUT, fname))

# ---------------------------------------------------------------- V5: dense rings, shared clasp nodes
def v5(accent=False, web=False, fname="licoup-v5.png"):
    """Two 16-node rings sharing two clasp nodes at the crossings —
    left/right converge and click together at the shared nodes. No hub, no spokes."""
    rng = random.Random(9)
    chord_dist, chord_prob, chord_alpha = (330, 0.5, 62) if web else (300, 0.3, 50)
    R, SEP = 430, 300
    CL, CR = (CX - SEP / 2, CY), (CX + SEP / 2, CY)
    im, d, sh, dsh = canvas()

    base = [i * 22.5 for i in range(16)]
    left_angles = [69.6 if a == 67.5 else 290.4 if a == 292.5 else a for a in base]
    right_angles = [110.4 if a == 112.5 else 249.6 if a == 247.5 else a for a in base]
    SHARED_L = (69.6, 290.4)              # bottom, top shared node angles (left circle)

    NL = {a: pt(CL[0], CL[1], R, a) for a in left_angles}
    NR = {a: pt(CR[0], CR[1], R, a) for a in right_angles}

    def ring_links(nodes, center):
        angs = sorted(nodes)
        for a1, a2 in zip(angs, angs[1:] + [angs[0] + 360]):
            link(d, *nodes[a1], *pt(center[0], CY, R, a2), width=3, alpha=155)

    ring_links(NL, CL)
    ring_links(NR, CR)

    SKIP = {69.6, 290.4, 110.4, 249.6}
    for nodes in (NL, NR):
        keys = sorted(nodes)
        for i, a1 in enumerate(keys):
            for a2 in keys[i + 1:]:
                if abs(a2 - a1) < 45 or a1 in SKIP or a2 in SKIP:
                    continue
                x1, y1, x2, y2 = *nodes[a1], *nodes[a2]
                if math.hypot(x2 - x1, y2 - y1) < chord_dist and rng.random() < chord_prob:
                    link(d, x1, y1, x2, y2, width=2, alpha=chord_alpha)

    sizes_l = {180: 50, 270: 26}
    sizes_r = {0: 50, 90: 26}
    shared_pts = {NL[SHARED_L[0]], NL[SHARED_L[1]]}
    for a, (x, y) in NL.items():
        if (x, y) in shared_pts:
            continue
        node(dsh, d, x, y, sizes_l.get(a, 13 + rng.random() * 5), INK)
    for a, (x, y) in NR.items():
        if (x, y) in shared_pts:
            continue
        node(dsh, d, x, y, sizes_r.get(a, 13 + rng.random() * 5), INK)
    for p in sorted(shared_pts):
        node(dsh, d, *p, 36, ACCENT if accent else INK)
    finish(im, sh, os.path.join(OUT, fname))

v5(fname="licoup-v5-clasp.png")
v5(accent=True, fname="licoup-v5-clasp-accent.png")
v5(web=True, fname="licoup-v5-clasp-web.png")
