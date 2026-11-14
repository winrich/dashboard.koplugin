#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""把 preview/ 下的版面图拼成对照版，便于一屏横向评审。

只做拼版，不改动原图；输出到 preview/_review/。
"""
import glob
import os
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PREV = os.path.join(ROOT, "preview")
OUT = os.path.join(PREV, "_review")

FONT_PATH = "C:/Windows/Fonts/msyh.ttc"
FONT_BOLD = "C:/Windows/Fonts/msyhbd.ttc"


def font(size, bold=False):
    for p in ((FONT_BOLD if bold else FONT_PATH), FONT_PATH):
        try:
            return ImageFont.truetype(p, size)
        except OSError:
            continue
    return ImageFont.load_default()


def sheet(paths, cols, tile_w, label_h, title, out_path, bg=0xF2):
    """paths: [(path, label)]；按 cols 列排成网格。"""
    tiles = []
    for p, label in paths:
        im = Image.open(p).convert("L")
        ratio = tile_w / im.width
        tw, th = tile_w, int(round(im.height * ratio))
        tiles.append((im.resize((tw, th), Image.LANCZOS), th, label))

    cell_w = tile_w + 18
    cell_h = max(t[1] for t in tiles) + label_h + 18
    rows = (len(tiles) + cols - 1) // cols
    head = 64
    W = cols * cell_w + 18
    H = head + rows * cell_h + 18

    canvas = Image.new("L", (W, H), bg)
    d = ImageDraw.Draw(canvas)
    d.text((18, 16), title, font=font(30, True), fill=0)

    for i, (im, th, label) in enumerate(tiles):
        r, c = divmod(i, cols)
        x = 18 + c * cell_w
        y = head + r * cell_h
        canvas.paste(im, (x, y))
        d.rectangle([x, y, x + im.width - 1, y + th - 1], outline=0xB4, width=2)
        d.text((x + 2, y + th + 8), label, font=font(24), fill=0x33)

    canvas.save(out_path)
    print("%-46s %dx%d" % (os.path.basename(out_path), W, H))
    return out_path


def pick(pattern):
    return sorted(glob.glob(os.path.join(PREV, pattern)))


os.makedirs(OUT, exist_ok=True)

groups = [
    ("zh", "竖屏", ["portrait.png"] + ["portrait-%d.png" % i for i in range(1, 6)], 3, 520),
    ("zh", "横屏", ["landscape.png"] + ["landscape-%d.png" % i for i in range(1, 6)], 3, 660),
    ("en", "竖屏", ["portrait-%d.png" % i for i in range(1, 6)], 3, 520),
    ("en", "横屏", ["landscape-%d.png" % i for i in range(1, 6)], 3, 660),
]

for lang, orient, names, cols, tile_w in groups:
    paths = []
    for n in names:
        p = os.path.join(PREV, "en", n) if lang == "en" else os.path.join(PREV, n)
        if os.path.exists(p):
            paths.append((p, n.replace(".png", "")))
    tag = "中" if lang == "zh" else "EN"
    sheet(paths, cols, tile_w, 42, "%s · %s（%d 张）" % (tag, orient, len(paths)),
          os.path.join(OUT, "sheet-%s-%s.png" % (lang, "portrait" if "竖" in orient else "landscape")))
