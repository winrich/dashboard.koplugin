"""把桩件导出的最终帧还原成可查看的版面预览页。

用法（项目根目录）：python tools/render_preview.py
产物：preview/board.html —— 按真实像素坐标绘制的竖屏与横屏版面。
"""
import base64
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PLUGIN = "dashboard.koplugin"

SIZES = [
    ("竖屏 1072×1448", 1072, 1448, 340),
    ("横屏 1448×1072", 1448, 1072, 560),
]

# 桩件里的颜色常量（0=白 255=黑 85=深灰）
FILL = {0: "#ffffff", 255: "#111111", 85: "#8a8a8a"}


def grab(w, h):
    lua = (
        "STUB_FRAME = true\n"
        f"STUB_W = {w}\nSTUB_H = {h}\n"
        f'arg = {{ [1] = [[{PLUGIN}]] }}\n'
        f'package.path = [[{PLUGIN}/?.lua;]] .. package.path\n'
        f'dofile([[{HERE}/stub_test.lua]])\n'
    )
    out = subprocess.run([sys.executable, "-c", RUNNER, lua], cwd=ROOT,
                         capture_output=True, text=True, encoding="utf-8")
    if out.returncode != 0:
        raise SystemExit(f"桩件执行失败：\n{out.stdout[-2000:]}\n{out.stderr[-2000:]}")
    items = []
    for line in out.stdout.splitlines():
        if line.startswith("FRAME|"):
            parts = line.split("|")
            if parts[1] == "END":
                break
            tag = parts[1]
            x, y, iw, ih, color = (int(v) for v in parts[2:7])
            items.append((tag, x, y, iw, ih, color, "|".join(parts[7:])))
    return items


RUNNER = """
import sys, codecs
from lupa import LuaRuntime
script = sys.argv[1]
lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute(script)
"""


def esc(t):
    return (t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


def icon_data_uri(path):
    full = os.path.join(ROOT, path)
    if not os.path.exists(full):
        return None
    with open(full, "rb") as fh:
        return "data:image/png;base64," + base64.b64encode(fh.read()).decode()


def svg_for(items, w, h, disp_w):
    k = disp_w / w
    disp_h = h * k
    body = [f'<rect x="0" y="0" width="{w}" height="{h}" fill="#ffffff"/>']
    for tag, x, y, iw, ih, color, text in items:
        if tag == "R":
            body.append(f'<rect x="{x}" y="{y}" width="{iw}" height="{ih}" fill="{FILL.get(color, "#333")}"/>')
        elif tag == "B":
            body.append(f'<rect x="{x}" y="{y}" width="{iw}" height="{ih}" fill="none" '
                        f'stroke="#111" stroke-width="3"/>')
        elif tag == "T":
            size = max(6, round(ih * 0.72))
            fill = "#8a8a8a" if color == 85 else "#111111"
            body.append(f'<text x="{x}" y="{y + ih * 0.78:.0f}" font-size="{size}" fill="{fill}" '
                        f'font-family="PingFang SC, Noto Sans CJK SC, Microsoft YaHei, sans-serif">'
                        f'{esc(text)}</text>')
        elif tag == "I":
            uri = icon_data_uri(text)
            if uri:
                body.append(f'<image x="{x}" y="{y}" width="{iw}" height="{ih}" href="{uri}"/>')
    return (f'<svg viewBox="0 0 {w} {h}" width="{disp_w}" height="{disp_h:.0f}" '
            f'style="background:#fff;border:1px solid #d8d8d8;border-radius:6px">'
            + "".join(body) + "</svg>")


def main():
    cards = []
    for label, w, h, disp in SIZES:
        items = grab(w, h)
        cards.append(f'<figure><figcaption>{label}'
                     f'<span>{w}×{h} px</span></figcaption>{svg_for(items, w, h, disp)}</figure>')
        print(f"[OK] {label}：{len(items)} 个绘制元素")

    html = """<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<title>桌面看板版面预览（按真实坐标绘制）</title>
<style>
  body{margin:0;padding:28px 24px 40px;background:#f4f4f2;color:#111;
       font-family:"PingFang SC","Noto Sans CJK SC","Microsoft YaHei",sans-serif}
  h1{font-size:17px;font-weight:600;margin:0 0 6px}
  p.note{font-size:12.5px;color:#666;margin:0 0 22px;line-height:1.7}
  .row{display:flex;gap:34px;align-items:flex-start;flex-wrap:wrap}
  figure{margin:0}
  figcaption{font-size:12.5px;color:#444;margin-bottom:8px;display:flex;gap:10px;align-items:baseline}
  figcaption span{color:#999;font-size:11.5px}
</style></head><body>
<h1>桌面看板 · KPW3 版面预览</h1>
<p class="note">由测试桩输出的最终帧像素坐标还原，非示意图。文字宽度按控件实测尺寸定位，
字形本身由浏览器渲染，可能与 Kindle 上的 cfont 略有差异。</p>
<div class="row">%s</div>
</body></html>""" % "".join(cards)

    out_dir = os.path.join(ROOT, "preview")
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, "board.html")
    with open(path, "w", encoding="utf-8", newline="") as fh:
        fh.write(html)
    print(f"\n预览页：{path}")


if __name__ == "__main__":
    main()
