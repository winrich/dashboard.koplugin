#!/usr/bin/env python3
"""对齐审计：量每张卡内墨迹的左右留白，找出「内容偏左 / 偏右 / 没铺满」的卡。

用法：
    python tools/audit_align.py                 # 审计 preview 下全部中文图
    python tools/audit_align.py preview/en      # 审计英文图
    python tools/audit_align.py preview/portrait.png

原理：卡片是纯白 0xFF，纸底是 0xEE。按行统计白像素找出卡片所在的横带，
再在白带里取墨迹（灰度 <150，避开 0xBB 边框）的包围盒，比较左右留白。
判定阈值只用来**筛可疑项**，结论仍要人眼复核图片。
"""

import os
import sys

from PIL import Image

WHITE_MIN = 252      # 卡面
INK_MAX = 150        # 墨迹；0xBB(187) 边框不算
ROW_WHITE_RATIO = 0.45
MIN_CARD_H = 60
# 左右留白差超过这个像素数就报出来（1072 短边下 6px ≈ 1.5mm，肉眼可辨）
LR_TOL = 12


def row_bands(mask, w, h):
    """按「这一行白像素占比」切出卡片的横带。

    卡内的一条细分隔线（0xDD）会横贯整张卡，把那一行的白占比压到 0.5 以下——
    单行判据会把一张卡劈成上下两张。所以要求**连续 4 行**都掉下去才收带。
    """
    data = mask.tobytes()
    stride = w
    on = []
    for y in range(h):
        row = data[y * stride:(y + 1) * stride]
        on.append(row.count(255) / w >= ROW_WHITE_RATIO)
    bands = []
    start = None
    off_run = 0
    last_on = None
    for y, v in enumerate(on):
        if v:
            if start is None:
                start = y
            last_on = y
            off_run = 0
        else:
            off_run += 1
            if start is not None and off_run >= 4:
                if last_on - start + 1 >= MIN_CARD_H:
                    bands.append((start, last_on))
                start = None
    if start is not None and last_on - start + 1 >= MIN_CARD_H:
        bands.append((start, last_on))
    return bands


def card_spans(mask, w, y0, y1):
    """横带里按列切卡：横屏下半区是左右两张卡，必须分开量。"""
    data = mask.tobytes()
    height = y1 - y0 + 1
    rows = [data[y * w:(y + 1) * w] for y in range(y0, y1 + 1)]
    spans = []
    start = None
    for x in range(w):
        white = 0
        for row in rows:
            if row[x] == 255:
                white += 1
        on = white > height * 0.35
        if on and start is None:
            start = x
        elif not on and start is not None:
            if x - start >= 100:
                spans.append((start, x - 1))
            start = None
    if start is not None and w - start >= 100:
        spans.append((start, w - 1))
    return spans


def audit(path):
    im = Image.open(path).convert("L")
    w, h = im.size
    mask = im.point(lambda v: 255 if v >= WHITE_MIN else 0)
    ink = im.point(lambda v: 255 if v < INK_MAX else 0)
    out = []
    idx = 0
    for (y0, y1) in row_bands(mask, w, h):
        for (x0, x1) in card_spans(mask, w, y0, y1):
            idx += 1
            box = (x0, y0, x1 + 1, y1 + 1)
            bb = ink.crop(box).getbbox()
            if not bb:
                out.append((idx, box, None))
                continue
            l = bb[0]
            r = (x1 - x0 + 1) - bb[2]
            t = bb[1]
            b = (y1 - y0 + 1) - bb[3]
            out.append((idx, box, (l, r, t, b)))
    return out


def fmt(name, rows):
    print(f"\n=== {name} ===")
    for idx, box, m in rows:
        bw = box[2] - box[0]
        bh = box[3] - box[1]
        if m is None:
            print(f"  card{idx+1} {bw}x{bh} @({box[0]},{box[1]})  空白")
            continue
        l, r, t, b = m
        flags = []
        if abs(l - r) > LR_TOL:
            flags.append("左重" if l < r else "左空")
        if min(l, r) > bw * 0.06:
            flags.append("两侧皆空")
        tag = ("  <<< " + " ".join(flags)) if flags else ""
        print(f"  card{idx+1} {bw}x{bh} @({box[0]},{box[1]})  "
              f"L{l:>3} R{r:>3} T{t:>3} B{b:>3}{tag}")


def main():
    target = sys.argv[1] if len(sys.argv) > 1 else "preview"
    if os.path.isdir(target):
        files = sorted(f for f in os.listdir(target)
                       if f.endswith(".png") and not f.startswith("overview"))
        for f in files:
            fmt(f, audit(os.path.join(target, f)))
    else:
        fmt(os.path.basename(target), audit(target))


if __name__ == "__main__":
    main()
