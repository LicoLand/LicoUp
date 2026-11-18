#!/usr/bin/env python3
"""Autocrop generated logo PNGs to content bbox with padding."""
import os
from PIL import Image

HERE = os.path.dirname(__file__)
GEN = os.path.join(HERE, "..", "gen2")

def autocrop(name, thresh=238, pad_ratio=0.08):
    src = os.path.join(GEN, name)
    im = Image.open(src).convert("RGB")
    gray = im.convert("L")
    mask = gray.point(lambda v: 255 if v < thresh else 0)
    bbox = mask.getbbox()
    if not bbox:
        print(f"skip {name}: no content")
        return None
    w, h = im.size
    bw, bh = bbox[2] - bbox[0], bbox[3] - bbox[1]
    pad = int(max(bw, bh) * pad_ratio)
    box = (max(0, bbox[0] - pad), max(0, bbox[1] - pad),
           min(w, bbox[2] + pad), min(h, bbox[3] + pad))
    out = im.crop(box)
    dst = os.path.join(GEN, name.replace(".png", "-crop.png"))
    out.save(dst)
    print(dst, out.size)
    return dst

for n in ["licoup-d2.png", "licoup-d3.png", "licoup-d5.png",
          "licoup-d6.png", "licoup-d7.png"]:
    autocrop(n)
