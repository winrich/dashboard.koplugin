"""把桩件导出的最终帧画成 PNG，用来目视检查版面（边距、重叠、对齐）。

和 render_preview.py 的区别：那个输出 HTML 用浏览器看，这个直接出 PNG，
适合在终端/对话里快速确认「四边留白有没有真的留出来」。

用法：
    python tools/render_png.py            # 竖屏 + 横屏各一张
    python tools/render_png.py 600 800    # 指定尺寸

说明：
- 桩件里 Blitbuffer 的 COLOR_WHITE=0、COLOR_BLACK=255，与真机相反，画图时要取反。
- 文本元素在桩件里不带颜色（recorded color 恒为 0），一律按黑色画。
- 框线（灰色）是四边安全区参考线，不是界面的一部分。
"""

import os
import sys

from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from render_preview import grab  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT_DIR = os.path.join(ROOT, "preview")

DEFAULT_SIZES = [("portrait", 1072, 1448, 0), ("landscape", 1072, 1448, 1)]

FONT_CANDIDATES = [
    r"C:\Windows\Fonts\msyh.ttc",
    r"C:\Windows\Fonts\simhei.ttf",
    "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
]


def load_font(size):
    for path in FONT_CANDIDATES:
        if os.path.exists(path):
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


def safe_edge(w):
    """与 main.lua 的 EDGE_UNITS=15 对应：短边 600 为 1 倍。"""
    short = min(w, 1448)
    return max(15, int(15 * short / 600))


def render(name, w, h, rot=0):
    # 原生尺寸固定是竖屏；rot 为奇数时 framebuffer 转 90°，画布宽高互换
    dw, dh = (h, w) if rot % 2 else (w, h)
    items = grab(w, h, rot)
    img = Image.new("L", (dw, dh), 255)
    draw = ImageDraw.Draw(img)

    for tag, x, y, iw, ih, color, text in items:
        if tag == "R":
            draw.rectangle([x, y, x + iw, y + ih], fill=255 - (color or 0))
        elif tag == "B":
            draw.rectangle([x, y, x + iw, y + ih], outline=255 - (color or 0), width=2)
        elif tag == "I":
            draw.rectangle([x, y, x + iw, y + ih], fill=0)
        elif tag == "T" and text:
            size = max(6, int(ih * 0.78))
            font = load_font(size)
            draw.text((x, y + (ih - size) * 0.45), text, font=font, fill=0)

    edge = safe_edge(dw)
    draw.rectangle([edge, edge, dw - edge, dh - edge], outline=170)

    os.makedirs(OUT_DIR, exist_ok=True)
    out = os.path.join(OUT_DIR, name + ".png")
    img.save(out)
    print(f"[OK] {name} {w}x{h}  ->  {out}")


def main():
    args = [a for a in sys.argv[1:] if a.isdigit()]
    if len(args) >= 2:
        render("board_%sx%s" % (args[0], args[1]), int(args[0]), int(args[1]), 0)
    else:
        for name, w, h, rot in DEFAULT_SIZES:
            render(name, w, h, rot)


if __name__ == "__main__":
    main()
