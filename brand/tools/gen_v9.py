#!/usr/bin/env python3
"""LicoUp V9: interlocking chain-link rings, organic plexus texture (813be style)
constrained to a figurative silhouette. Over/under weave at the two crossing
zones makes the 'clasp' readable; blue lock node = the 'click' point."""
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

# ---------- stadium centreline ----------
def stadium_points(cx, cy, L, r, n, rot=0.0):
    P = 4 * L + 2 * math.pi * r
    ca, sa = math.cos(math.radians(rot)), math.sin(math.radians(rot))
    pts = []
    for k in range(n):
        t = (P * k / n) % P
        if t < 2 * L:
            x, y = -L + t, -r
        elif t < 2 * L + math.pi * r:
            a = -math.pi / 2 + (t - 2 * L) / r
            x, y = L + r * math.cos(a), r * math.sin(a)
        elif t < 4 * L + math.pi * r:
            x, y = L - (t - 2 * L - math.pi * r), r
        else:
            a = math.pi / 2 + (t - 4 * L - math.pi * r) / r
            x, y = -L + r * math.cos(a), r * math.sin(a)
        pts.append((cx + x * ca - y * sa, cy + x * sa + y * ca))
    return pts

def dist_to_path(p, path):
    return min(math.hypot(p[0] - q[0], p[1] - q[1]) for q in path)

def _seg_intersect(p1, p2, p3, p4):
    """Proper segment intersection point or None (excludes parallel/touch)."""
    d = (p2[0]-p1[0])*(p4[1]-p3[1]) - (p2[1]-p1[1])*(p4[0]-p3[0])
    if abs(d) < 1e-9:
        return None
    t = ((p3[0]-p1[0])*(p4[1]-p3[1]) - (p3[1]-p1[1])*(p4[0]-p3[0])) / d
    u = ((p3[0]-p1[0])*(p2[1]-p1[1]) - (p3[1]-p1[1])*(p2[0]-p1[0])) / d
    if 1e-6 < t < 1 - 1e-6 and 1e-6 < u < 1 - 1e-6:
        return (p1[0] + t*(p2[0]-p1[0]), p1[1] + t*(p2[1]-p1[1]))
    return None

def crossing_zones(pathA, pathB, cluster_gap=160):
    raw = []
    nA, nB = len(pathA), len(pathB)
    for i in range(nA):
        a1, a2 = pathA[i], pathA[(i+1) % nA]
        for j in range(nB):
            hit = _seg_intersect(a1, a2, pathB[j], pathB[(j+1) % nB])
            if hit:
                raw.append(hit)
    raw.sort()
    zones = []
    for p in raw:
        if zones and math.hypot(p[0] - zones[-1][-1][0],
                                p[1] - zones[-1][-1][1]) < cluster_gap:
            zones[-1].append(p)
        else:
            zones.append([p])
    out = [(sum(p[0] for p in z) / len(z), sum(p[1] for p in z) / len(z)) for z in zones]
    out.sort(key=lambda z: z[1])          # top zone first
    return out

# ---------- organic band sampling ----------
def sample_band(rng, path, band_half, target, min_dist):
    xs = [p[0] for p in path]; ys = [p[1] for p in path]
    x0, x1 = min(xs) - band_half, max(xs) + band_half
    y0, y1 = min(ys) - band_half, max(ys) + band_half
    cell = min_dist / math.sqrt(2)
    grid = {}
    kept = []
    tries = 0
    while len(kept) < target and tries < target * 400:
        tries += 1
        p = (rng.uniform(x0, x1), rng.uniform(y0, y1))
        if dist_to_path(p, path) > band_half:
            continue
        gx, gy = int(p[0] / cell), int(p[1] / cell)
        ok = True
        for ix in range(gx - 2, gx + 3):
            for iy in range(gy - 2, gy + 3):
                for q in grid.get((ix, iy), ()):
                    if math.hypot(p[0] - q[0], p[1] - q[1]) < min_dist:
                        ok = False; break
                if not ok: break
            if not ok: break
        if not ok:
            continue
        grid.setdefault((gx, gy), []).append(p)
        kept.append(p)
    return kept

def v9(seed=7, accent=False, fname="licoup-v9-clasp.png", tilt=14.0, dx=250.0):
    rng = random.Random(seed)
    L, r, band = 235, 250, 58
    A = (CX - dx, CY, L, r, -tilt)
    B = (CX + dx, CY, L, r, tilt)
    pathA = stadium_points(*A[:4], 720, A[4])
    pathB = stadium_points(*B[:4], 720, B[4])
    zones = crossing_zones(pathA, pathB)
    if len(zones) != 2:
        print("WARN zones:", len(zones),
              [(round(x), round(y)) for x, y in zones]); return
    GAP_NODE, GAP_LINK = 80, 95

    rings = []
    for li, path in enumerate((pathA, pathB)):
        # ring li passes UNDER at zones[zi] when (zi+li) odd  -> A over top, B over bottom
        under = {zi for zi in range(2) if (zi + li) % 2 == 1}
        pts = sample_band(rng, path, band, target=64, min_dist=47)
        kept = [p for p in pts
                if not any(zi in under and math.hypot(p[0]-z[0], p[1]-z[1]) < GAP_NODE
                           for zi, z in enumerate(zones))]
        rings.append([kept, under])

    # cross-ring de-clutter near zones: under-ring node yields to over-ring node
    for zi, z in enumerate(zones):
        over_li = 0 if zi % 2 == 0 else 1
        under_li = 1 - over_li
        over_kept, under_kept = rings[over_li][0], rings[under_li][0]
        rings[under_li][0] = [
            p for p in under_kept
            if not (math.hypot(p[0]-z[0], p[1]-z[1]) < 190 and
                    any(math.hypot(p[0]-q[0], p[1]-q[1]) < 40 for q in over_kept))]

    im, d, sh, dsh = canvas()

    lock_nodes = []
    for kept, under in rings:
        for i, p in enumerate(kept):
            for q in kept[i+1:]:
                dd = math.hypot(p[0]-q[0], p[1]-q[1])
                if dd > 128:
                    continue
                mx, my = (p[0]+q[0])/2, (p[1]+q[1])/2
                if any(zi in under and math.hypot(mx-z[0], my-z[1]) < GAP_LINK
                       for zi, z in enumerate(zones)):
                    continue
                a = int(175 * (1 - dd / 128)) + 28
                d.line([S(p[0]), S(p[1]), S(q[0]), S(q[1])],
                       fill=(40, 40, 46, a), width=max(1, int(round(S(2)))))
        # spine: slightly larger nodes along centreline for silhouette readability
        for zi, z in enumerate(zones):
            if zi not in under:
                lock_nodes.append(min(kept, key=lambda p: math.hypot(p[0]-z[0], p[1]-z[1])))

    for kept, under in rings:
        for p in kept:
            u = rng.random()
            rr = 9 + u * u * 16          # mostly small, few medium
            near_zone = any(math.hypot(p[0]-z[0], p[1]-z[1]) < 160 for z in zones)
            if near_zone:
                rr = min(rr, 13)         # keep the clasp area clean
            if p in lock_nodes:
                rr = 32
            col = ACCENT if (accent and p in lock_nodes) else INK
            node(dsh, d, p[0], p[1], rr, col)
    finish(im, sh, os.path.join(OUT, fname))

v9(seed=7, fname="licoup-v9-clasp.png")
v9(seed=7, accent=True, fname="licoup-v9-clasp-accent.png")
v9(seed=21, fname="licoup-v9b-clasp.png")
v9(seed=21, accent=True, fname="licoup-v9b-clasp-accent.png")
v9(seed=33, fname="licoup-v9c-clasp.png")
v9(seed=33, accent=True, fname="licoup-v9c-clasp-accent.png")
