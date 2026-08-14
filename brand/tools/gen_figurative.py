#!/usr/bin/env python3
"""LicoUp figurative network-logo studies: concrete symbols (chain / infinity / DNA)
rendered in the node-constellation style the client responded to.
Silhouette carries the symbol; nodes+links carry the network texture."""
import math, os, random
from PIL import Image, ImageDraw, ImageFilter

OUT = os.path.join(os.path.dirname(__file__), "..", "gen3")
os.makedirs(OUT, exist_ok=True)

SS = 2
W, H = 2048, 1365
CX, CY = W / 2, H / 2
INK = (22, 22, 26, 255)
ACCENT = (27, 73, 224, 255)

def S(v): return v * SS

def node(dsh, d, x, y, r, color):
    xs, ys, rs = S(x), S(y), S(r)
    dsh.ellipse([xs + S(7) - rs * 1.12, ys + S(15) - rs * 1.12,
                 xs + S(7) + rs * 1.12, ys + S(15) + rs * 1.12], fill=(0, 0, 0, 60))
    d.ellipse([xs - rs, ys - rs, xs + rs, ys + rs], fill=color)

def link(d, x1, y1, x2, y2, width=3, alpha=150, color=(40, 40, 46)):
    d.line([S(x1), S(y1), S(x2), S(y2)], fill=color + (alpha,),
           width=max(1, int(round(S(width)))))

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

def chords(d, rng, pts, dist, prob, alpha=55, skip=()):
    for i in range(len(pts)):
        for j in range(i + 1, len(pts)):
            if (i, j) in skip:
                continue
            x1, y1 = pts[i]; x2, y2 = pts[j]
            if math.hypot(x2 - x1, y2 - y1) < dist and rng.random() < prob:
                link(d, x1, y1, x2, y2, width=2, alpha=alpha)

# ---------------- stadium (rounded capsule outline) sampling ----------------
def stadium_points(cx, cy, L, r, n, rot=0.0):
    P = 4 * L + 2 * math.pi * r
    ca, sa = math.cos(math.radians(rot)), math.sin(math.radians(rot))
    pts = []
    for k in range(n):
        t = (P * k / n) % P
        if t < 2 * L:                                   # top straight, left->right
            x, y = -L + t, -r
        elif t < 2 * L + math.pi * r:                   # right arc, top->bottom
            a = -math.pi / 2 + (t - 2 * L) / r
            x, y = L + r * math.cos(a), r * math.sin(a)
        elif t < 4 * L + math.pi * r:                   # bottom straight, right->left
            x, y = L - (t - 2 * L - math.pi * r), r
        else:                                           # left arc, bottom->top
            a = math.pi / 2 + (t - 4 * L - math.pi * r) / r
            x, y = -L + r * math.cos(a), r * math.sin(a)
        pts.append((cx + x * ca - y * sa, cy + x * sa + y * ca))
    return pts

def crossing_zones(A, B, near=48, cluster_gap=140):
    dense_A = stadium_points_dense(A) ; dense_B = stadium_points_dense(B)
    raw = []
    for a in dense_A:
        for b in dense_B:
            if math.hypot(a[0] - b[0], a[1] - b[1]) < near:
                raw.append(((a[0] + b[0]) / 2, (a[1] + b[1]) / 2))
    raw.sort()
    zones = []
    for p in raw:
        if zones and math.hypot(p[0] - zones[-1][-1][0],
                                p[1] - zones[-1][-1][1]) < cluster_gap:
            zones[-1].append(p)
        else:
            zones.append([p])
    return [(sum(p[0] for p in z) / len(z), sum(p[1] for p in z) / len(z)) for z in zones]

_ST_DENSE = {}
def stadium_points_dense(params):
    key = params
    if key not in _ST_DENSE:
        cx, cy, L, r, rot = params
        _ST_DENSE[key] = stadium_points(cx, cy, L, r, 720, rot)
    return _ST_DENSE[key]

# ================================================== V6: chain links
def v6(accent=False, fname="licoup-v6-chain.png"):
    rng = random.Random(17)
    L, r = 250, 265
    A = (CX - 250, CY, L, r, -16.0)
    B = (CX + 250, CY, L, r, 16.0)
    zones = crossing_zones(A, B)
    zones.sort(key=lambda z: math.atan2(z[1] - CY, z[0] - CX))   # around center
    im, d, sh, dsh = canvas()

    all_kept = []
    lock_pts = []
    for li, params in enumerate((A, B)):
        pts = stadium_points(params[0], params[1], params[2], params[3], 28, params[4])
        under_at = {zi for zi in range(len(zones)) if (zi + li) % 2 == 1}
        kept = []
        for p in pts:
            drop = any((zi in under_at) and math.hypot(p[0] - z[0], p[1] - z[1]) < 78
                       for zi, z in enumerate(zones))
            if not drop:
                kept.append(p)
        for i, p in enumerate(kept):
            q = kept[(i + 1) % len(kept)]
            mx, my = (p[0] + q[0]) / 2, (p[1] + q[1]) / 2
            if len(kept) - 1 < 3 or not any((zi in under_at) and
                    math.hypot(mx - z[0], my - z[1]) < 78 for zi, z in enumerate(zones)):
                if math.hypot(q[0] - p[0], q[1] - p[1]) < 200:
                        link(d, *p, *q)
        all_kept.append(kept)
        for zi, z in enumerate(zones):
            near = min(kept, key=lambda p: math.hypot(p[0] - z[0], p[1] - z[1]))
            if zi not in under_at:
                lock_pts.append(near)
    for kept in all_kept:
        inner = [p for p in kept if math.hypot(p[0] - CX, p[1] - CY) > 250]
        chords(d, rng, inner, 290, 0.3)

    apex_l = min(all_kept[0], key=lambda p: p[0])
    apex_r = max(all_kept[1], key=lambda p: p[0])
    for kept in all_kept:
        for p in kept:
            rr = 15 + rng.random() * 5
            if p in (apex_l, apex_r):
                rr = 50
            elif p in lock_pts:
                rr = 34
            col = ACCENT if (accent and p in lock_pts) else INK
            node(dsh, d, *p, rr, col)
    finish(im, sh, os.path.join(OUT, fname))

# ================================================== V7: infinity
def v7(accent=False, fname="licoup-v7-infinity.png"):
    rng = random.Random(31)
    A = 640
    im, d, sh, dsh = canvas()
    N = 40
    pts = []
    for i in range(N):
        t = 2 * math.pi * i / N
        den = 1 + math.sin(t) ** 2
        pts.append((CX + A * math.cos(t) / den,
                    CY + A * 0.62 * math.sin(t) * math.cos(t) / den))
    # center crossing: passages near t=pi/2 (under) & 3pi/2 (over)
    def passage(t):
        return math.sin(t) > 0      # t in (0,pi) -> upper passage
    kept = []
    for i, p in enumerate(pts):
        t = 2 * math.pi * i / N
        if passage(t) and math.hypot(p[0] - CX, p[1] - CY) < 105:
            continue                # drop under-passage nodes at crossing
        kept.append(i)
    for ii, i in enumerate(kept):
        j = kept[(ii + 1) % len(kept)]
        if (j - i) % N == 1:
            p, q = pts[i], pts[j]
            mx, my = (p[0] + q[0]) / 2, (p[1] + q[1]) / 2
            if not (math.hypot(mx - CX, my - CY) < 105 and passage(2 * math.pi * i / N)):
                link(d, *p, *q)
    left_nodes = [pts[i] for i in kept if pts[i][0] < CX - 40]
    right_nodes = [pts[i] for i in kept if pts[i][0] > CX + 40]
    chords(d, rng, left_nodes, 280, 0.38)
    chords(d, rng, right_nodes, 280, 0.38)
    center_node = min(kept, key=lambda i: math.hypot(pts[i][0] - CX, pts[i][1] - CY))
    apexes = [min(kept, key=lambda i: pts[i][0]), max(kept, key=lambda i: pts[i][0])]
    for i in kept:
        p = pts[i]
        rr = 15 + rng.random() * 5
        if i in apexes:
            rr = 50
        elif i == center_node:
            rr = 34
        col = ACCENT if (accent and i == center_node) else INK
        node(dsh, d, *p, rr, col)
    link(d, *pts[center_node], CX, CY - 1, width=3, alpha=0)  # noop keep signature
    finish(im, sh, os.path.join(OUT, fname))

# ================================================== V8: DNA twist
def v8(accent=False, fname="licoup-v8-dna.png"):
    rng = random.Random(43)
    im, d, sh, dsh = canvas()
    X0, X1, AMP = 430, 1618, 210
    def y_up(x):   return CY - AMP * math.sin(2 * math.pi * (x - X0) / (X1 - X0))
    def y_dn(x):   return CY + AMP * math.sin(2 * math.pi * (x - X0) / (X1 - X0))
    N = 17
    up, dn = [], []
    for i in range(N):
        x = X0 + (X1 - X0) * i / (N - 1)
        up.append((x, y_up(x)))
        dn.append((x, y_dn(x)))
    # weave: upper strand over at center crossing (x=CX)
    up_kept = up
    dn_kept = [p for p in dn if abs(p[0] - CX) > 85]
    for strand, kept in ((up, up_kept), (dn, dn_kept)):
        for p, q in zip(kept, kept[1:]):
            if abs(q[0] - p[0]) < 130:
                link(d, *p, *q)
    # rungs (DNA base pairs), skip near center crossing
    for k in range(1, 11):
        x = X0 + (X1 - X0) * k / 11
        if abs(x - CX) < 110:
            continue
        link(d, x, y_up(x), x, y_dn(x), width=2.5, alpha=115)
    # light chords along each strand
    chords(d, rng, up_kept, 260, 0.25, alpha=48)
    chords(d, rng, dn_kept, 260, 0.25, alpha=48)
    ends = {up[0], up[-1], dn[0], dn[-1]}
    for strand in (up_kept, dn_kept):
        for p in strand:
            rr = 42 if p in ends else 14 + rng.random() * 5
            node(dsh, d, *p, rr, INK)
    if accent:
        node(dsh, d, CX, CY, 30, ACCENT)
    finish(im, sh, os.path.join(OUT, fname))

v6(); v6(accent=True, fname="licoup-v6-chain-accent.png")
v7(); v8(); v8(accent=True, fname="licoup-v8-dna-accent.png")
