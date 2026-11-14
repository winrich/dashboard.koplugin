#!/usr/bin/env python3
"""在真机截图里找「孤立的小深色块」——黑点。

用法：
    python tools/find_dots.py <png> [--max 26] [--th 120]

思路：
    1. 二值化取墨迹（默认 < 120，只抓真正的黑，不要 0x66 / 0xBB 的灰）；
    2. 8 邻域连通域标记；
    3. 包围盒宽高都 <= --max 的连通域视为候选「点」，单独打印；
    4. 同时打印每个点所在的行段，便于判断它是落在哪个组件里。
"""
import sys
from collections import deque

from PIL import Image


def components(img, th):
    w, h = img.size
    px = img.load()
    seen = bytearray(w * h)
    out = []
    for y in range(h):
        row = y * w
        for x in range(w):
            if seen[row + x] or px[x, y] >= th:
                continue
            # BFS
            q = deque([(x, y)])
            seen[row + x] = 1
            x0 = x1 = x
            y0 = y1 = y
            n = 0
            while q:
                cx, cy = q.popleft()
                n += 1
                if cx < x0:
                    x0 = cx
                if cx > x1:
                    x1 = cx
                if cy < y0:
                    y0 = cy
                if cy > y1:
                    y1 = cy
                for dy in (-1, 0, 1):
                    ny = cy + dy
                    if ny < 0 or ny >= h:
                        continue
                    for dx in (-1, 0, 1):
                        nx = cx + dx
                        if nx < 0 or nx >= w:
                            continue
                        k = ny * w + nx
                        if not seen[k] and px[nx, ny] < th:
                            seen[k] = 1
                            q.append((nx, ny))
            out.append((n, x0, y0, x1, y1))
    return out


def main():
    path = sys.argv[1]
    cap = 26
    th = 120
    args = sys.argv[2:]
    i = 0
    while i < len(args):
        if args[i] == "--max":
            cap = int(args[i + 1])
            i += 2
        elif args[i] == "--th":
            th = int(args[i + 1])
            i += 2
        else:
            i += 1

    img = Image.open(path).convert("L")
    w, h = img.size
    comps = components(img, th)
    dots = [c for c in comps if (c[3] - c[1]) <= cap and (c[4] - c[2]) <= cap]
    dots.sort(key=lambda c: (c[2], c[1]))
    print("%s  %dx%d  连通域 %d 个，其中小深色块 %d 个（阈值<%d，边长<=%d）"
          % (path, w, h, len(comps), len(dots), th, cap))
    for n, x0, y0, x1, y1 in dots:
        print("  点 %-3d px  位置 (%4d,%4d)-(%4d,%4d)  尺寸 %2dx%-2d"
              % (n, x0, y0, x1, y1, x1 - x0 + 1, y1 - y0 + 1))

    # 统计「谁最大」——用于排除字体的句末标点之类
    big = [c for c in comps if c[0] >= 12 and (c[3] - c[1]) > cap or (c[4] - c[2]) > cap]
    print("  另有 %d 个正常字形/图形块（未列出）" % len(big))


if __name__ == "__main__":
    main()
