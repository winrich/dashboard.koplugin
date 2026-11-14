#!/usr/bin/env python3
"""按灰度分档找「可疑小点」：只抓中间灰（0x66 附近），排除正文黑与浅灰细线。"""
import sys
from collections import deque

from PIL import Image

path = sys.argv[1]
lo = int(sys.argv[2]) if len(sys.argv) > 2 else 85
hi = int(sys.argv[3]) if len(sys.argv) > 3 else 125

img = Image.open(path).convert("L")
w, h = img.size
px = img.load()

seen = bytearray(w * h)
comps = []
for y in range(h):
    for x in range(w):
        k = y * w + x
        if seen[k]:
            continue
        v = px[x, y]
        if not (lo <= v <= hi):
            continue
        q = deque([(x, y)])
        seen[k] = 1
        x0 = x1 = x
        y0 = y1 = y
        n = 0
        while q:
            cx, cy = q.popleft()
            n += 1
            x0 = min(x0, cx); x1 = max(x1, cx)
            y0 = min(y0, cy); y1 = max(y1, cy)
            for dy in (-1, 0, 1):
                ny = cy + dy
                if ny < 0 or ny >= h:
                    continue
                for dx in (-1, 0, 1):
                    nx = cx + dx
                    if nx < 0 or nx >= w:
                        continue
                    kk = ny * w + nx
                    if seen[kk]:
                        continue
                    vv = px[nx, ny]
                    if lo <= vv <= hi:
                        seen[kk] = 1
                        q.append((nx, ny))
        comps.append((n, x0, y0, x1, y1))

small = [c for c in comps if (c[3] - c[1]) <= 24 and (c[4] - c[2]) <= 24]
small.sort(key=lambda c: (c[2], c[1]))
print("%s 灰阶 %d..%d  连通域 %d，其中 <=24px 小点 %d" % (path, lo, hi, len(comps), len(small)))
for n, x0, y0, x1, y1 in small:
    print("  %-4dpx (%4d,%4d)-(%4d,%4d)  %2dx%-2d" % (n, x0, y0, x1, y1, x1 - x0 + 1, y1 - y0 + 1))
