#!/usr/bin/env python3
"""把若干预览图拼成一张宫格总览图（公众号配图用）。

用法（项目根目录）：
    python tools/make_grid.py                      # 默认四宫格竖屏
    python tools/make_grid.py --cols 3             # 换三列
    python tools/make_grid.py --out preview/x.png a.png b.png ...

格内按各自比例等比缩放后居中，混入横屏图也不会被拉伸。
"""
import argparse
import os

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# 默认四张：第一张是文章主推的版面，正文点它时能直接对上
DEFAULT = [
    "preview/portrait.png",      # 左上：时钟 + 农历节气 + 三格
    "preview/portrait-1.png",    # 右上：时钟 + 整月日历 + 三格
    "preview/portrait-3.png",    # 左下：天气 + 空气明细 + 日月
    "preview/portrait-5.png",    # 右下：时钟 + 倒数日 + 待办
]

TOTAL_W = 1200                      # 成品总宽，公众号里够清晰
OUTER = 30                          # 外边距
GAP = 24                            # 格间距
BORDER = (168, 168, 168)
BORDER_W = 2


def fit(im, w, h):
    """等比缩放到能装进 w×h，返回 (图, x 偏移, y 偏移)，居中。"""
    r = min(w / im.width, h / im.height)
    nw, nh = max(1, int(im.width * r)), max(1, int(im.height * r))
    return im.resize((nw, nh), Image.LANCZOS), (w - nw) // 2, (h - nh) // 2


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cols", type=int, default=2, help="列数，默认 2")
    ap.add_argument("--out", default="preview/overview.png")
    ap.add_argument("images", nargs="*", help="留空则用内置四张")
    a = ap.parse_args()

    paths = a.images or DEFAULT
    imgs = [Image.open(os.path.join(ROOT, p)).convert("RGB") for p in paths]
    if not imgs:
        raise SystemExit("没有可用的图片")

    cols = max(1, a.cols)
    rows = (len(imgs) + cols - 1) // cols
    cell_w = (TOTAL_W - 2 * OUTER - (cols - 1) * GAP) // cols
    # 格高取「最瘦那张」的高度，保证任何一张都不会被裁
    tallest = max(im.height / im.width for im in imgs)
    cell_h = int(cell_w * tallest)

    total_h = 2 * OUTER + rows * cell_h + (rows - 1) * GAP
    canvas = Image.new("RGB", (TOTAL_W, total_h), (255, 255, 255))
    draw = ImageDraw.Draw(canvas)

    for i, im in enumerate(imgs):
        r, c = divmod(i, cols)
        x = OUTER + c * (cell_w + GAP)
        y = OUTER + r * (cell_h + GAP)
        scaled, ox, oy = fit(im, cell_w, cell_h)
        canvas.paste(scaled, (x + ox, y + oy))
        draw.rectangle([x - 1, y - 1, x + cell_w, y + cell_h],
                       outline=BORDER, width=BORDER_W)

    out = os.path.join(ROOT, a.out)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    canvas.save(out, optimize=True)
    print(f"[OK] {a.out}  {canvas.size[0]}×{canvas.size[1]}  "
          f"{len(imgs)} 张 / {cols} 列 {rows} 行")


if __name__ == "__main__":
    main()
