#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把真机截图上的异常墨点圈出来，输出一张「问题定位图」。

点是从像素推出来的（纯 0x66、无抗锯齿、7x5 或 11x7 的小块），
不是目测的坐标，所以这份图可以直接当验收清单用。

用法：
    python tools/mark_dots.py <截图.png> [输出.png]
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFont

DOTS = [
    # (x0, y0, x1, y1, 说明)
    (25, 74, 31, 78, "标题栏·左边缘"),
    (206, 69, 212, 73, "标题栏·UTC+8 下方"),
    (658, 70, 668, 76, "标题栏·中部空白"),
    (457, 1230, 463, 1234, "C区·风力图标内"),
    (727, 1226, 737, 1232, "C区·风力与 AQI 之间"),
    (1001, 1224, 1007, 1228, "C区·AQI 数值右侧"),
]


def font(size):
    for p in ("C:/Windows/Fonts/msyh.ttc", "C:/Windows/Fonts/simhei.ttf",
              "/System/Library/Fonts/PingFang.ttc"):
        if os.path.exists(p):
            try:
                return ImageFont.truetype(p, size)
            except Exception:
                pass
    return ImageFont.load_default()


def main():
    src = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else src.replace(".png", "-marked.png")

    base = Image.open(src).convert("RGB")
    W, H = base.size
    # 放大两倍再画标注，圈和字都清楚
    im = base.resize((W * 2, H * 2), Image.LANCZOS)
    d = ImageDraw.Draw(im)
    f_num = font(26)
    f_leg = font(28)

    # 只打编号角标，说明文字统一放到底部图例里，不挡卡片内容
    for i, (x0, y0, x1, y1, _) in enumerate(DOTS, 1):
        r = 17
        cx = (x0 + x1) // 2 * 2
        cy = (y0 + y1) // 2 * 2
        d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=(205, 30, 30), width=4)
        d.text((cx - 8, cy - 15), str(i), fill=(205, 30, 30), font=f_num)

    # 图例放顶部，图片整体下移，避免盖住画面
    lh = 44
    legend_h = 70 + lh * len(DOTS)
    canvas = Image.new("RGB", (im.size[0], im.size[1] + legend_h), (255, 255, 255))
    canvas.paste(im, (0, legend_h))
    d2 = ImageDraw.Draw(canvas)
    d2.text((40, 20), "异常墨点定位（纯 0x66、无抗锯齿的小圆块，非文字笔画）",
            fill=(20, 20, 20), font=font(34))
    y = 74
    for i, (x0, y0, x1, y1, desc) in enumerate(DOTS, 1):
        d2.ellipse([40, y + 6, 68, y + 34], outline=(205, 30, 30), width=3)
        d2.text((47, y + 8), str(i), fill=(205, 30, 30), font=f_num)
        d2.text((86, y), "%-22s  (%d,%d)  %dx%d" % (desc, x0, y0, x1 - x0 + 1, y1 - y0 + 1),
                fill=(60, 60, 60), font=f_leg)
        y += lh

    canvas.save(out)
    print("标注图：%s  (%dx%d)" % (out, canvas.size[0], canvas.size[1]))


if __name__ == "__main__":
    main()
