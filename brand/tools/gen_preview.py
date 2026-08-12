#!/usr/bin/env python3
"""Build a contact-sheet preview.html embedding all concept SVGs."""
import os, re

HERE = os.path.dirname(__file__)
CONCEPTS = os.path.join(HERE, "..", "concepts")

def read(name):
    with open(os.path.join(CONCEPTS, name)) as f:
        svg = f.read()
    # unique-ify gradient ids per embed instance
    return svg

def inst(name, size, prefix):
    svg = read(name)
    svg = re.sub(r'id="', f'id="{prefix}-', svg)
    svg = re.sub(r'url\(#', f'url(#{prefix}-', svg)
    svg = re.sub(r'width="240" height="240"', f'width="{size}" height="{size}"', svg)
    return svg

META = {
    "a": ("Concept A", "相扣环 · The Clasp", "两枚开口钩环抱成一枚封闭的圆——左右汇聚、上下交叉互锁，即“咔哒”扣紧的瞬间；闭环寓意隐私与安全的完整保护。"),
    "b": ("Concept B", "双L结 · Double-L Knot", "LicoUp 的首字母 L 左右相向，在方形结构中上下穿插编织成结——链路咬合，方正如基建模块，两端无限延伸。"),
    "c": ("Concept C", "汇聚·上扬 · Merge & Rise", "两条信号流自左右汇聚，在中点融合为一股向上的流——Link Up 的字面叙事：连接，然后向上。"),
}

def card(cid):
    en, cn, desc = META[cid]
    grad = f"licoup-{cid}-gradient.svg"
    mono = f"licoup-{cid}-mono.svg"
    white = f"licoup-{cid}-mono-white.svg"
    sizes = "".join(
        f'<div class="chip">{inst(grad, s, f"{cid}-s{s}")}<span>{s}px</span></div>'
        for s in (64, 32, 16))
    return f"""
<section>
  <h2>{en} · <b>{cn}</b></h2>
  <p class="desc">{desc}</p>
  <div class="row">
    <div class="cell light big">{inst(grad, 220, cid+"-gl")}</div>
    <div class="cell dark big">{inst(grad, 220, cid+"-gd")}</div>
    <div class="cell light">{inst(mono, 150, cid+"-ml")}<span>单色 · 藏青</span></div>
    <div class="cell dark">{inst(white, 150, cid+"-wd")}<span>单色 · 白</span></div>
    <div class="cell appicon">
      <div class="icon">{inst(white, 96, cid+"-ai")}</div><span>App Icon</span>
    </div>
  </div>
  <div class="row lockup">
    <div class="cell light wide">{inst(grad, 88, cid+"-lk")}<span class="wm">LicoUp</span></div>
    <div class="cell dark wide">{inst(white, 88, cid+"-lk2")}<span class="wm w">LicoUp</span></div>
    {sizes}
  </div>
</section>"""

html = f"""<!doctype html><html><head><meta charset="utf-8"><style>
  body {{ margin:0; padding:40px 48px; background:#EEF1F8;
        font-family:"Avenir Next","Futura","-apple-system",sans-serif; color:#16233F; }}
  h1 {{ font-size:26px; margin:0 0 4px; letter-spacing:.5px; }}
  .sub {{ color:#5A6B8C; font-size:14px; margin-bottom:24px; }}
  section {{ background:#fff; border-radius:18px; padding:26px 30px; margin-bottom:28px;
            box-shadow:0 2px 14px rgba(20,40,90,.07); }}
  h2 {{ font-size:17px; font-weight:600; margin:0 0 6px; color:#33415E; }}
  h2 b {{ color:#1B49E0; }}
  .desc {{ font-size:13.5px; color:#5A6B8C; margin:0 0 18px; max-width:900px; line-height:1.6; }}
  .row {{ display:flex; gap:18px; align-items:center; margin-bottom:14px; }}
  .cell {{ border-radius:14px; display:flex; flex-direction:column; gap:8px;
          align-items:center; justify-content:center; padding:18px; min-width:120px; }}
  .cell span {{ font-size:11px; color:#7A88A5; }}
  .light {{ background:#F5F8FF; border:1px solid #E3EAF9; }}
  .dark  {{ background:#0A1226; }}
  .big {{ padding:26px; }}
  .wide {{ flex-direction:row; gap:18px; padding:20px 28px; }}
  .wm {{ font-size:44px; font-weight:700; color:#0B1E4B; letter-spacing:-1px; }}
  .wm.w {{ color:#fff; }}
  .appicon {{ background:transparent; }}
  .appicon .icon {{ width:132px; height:132px; border-radius:30px;
      background:linear-gradient(135deg,#0B1E4B,#123B8F); display:flex;
      align-items:center; justify-content:center; box-shadow:0 6px 18px rgba(10,25,70,.35); }}
  .chip {{ background:#F5F8FF; border:1px solid #E3EAF9; border-radius:12px;
          padding:14px 18px; display:flex; flex-direction:column; gap:6px; align-items:center; }}
  .chip span {{ font-size:11px; color:#7A88A5; }}
  .palette {{ display:flex; gap:10px; margin:0 0 24px; }}
  .sw {{ width:120px; height:44px; border-radius:10px; color:#fff; font-size:11px;
       display:flex; align-items:flex-end; padding:6px 8px; }}
</style></head><body>
<h1>LicoUp · Logo Concepts</h1>
<div class="sub">品牌语义：左右汇聚 → 中点扣紧 → 安全连接 &nbsp;|&nbsp; 全部为正圆/贝塞尔参数化矢量</div>
<div class="palette">
  <div class="sw" style="background:#1B49E0">#1B49E0</div>
  <div class="sw" style="background:#2E7FFF">#2E7FFF</div>
  <div class="sw" style="background:#00BFFF">#00BFFF</div>
  <div class="sw" style="background:#00E0B8">#00E0B8</div>
  <div class="sw" style="background:#0B1E4B">#0B1E4B</div>
</div>
{card("a")}{card("b")}{card("c")}
</body></html>"""

out = os.path.join(HERE, "..", "preview.html")
with open(out, "w") as f:
    f.write(html)
print(out)
