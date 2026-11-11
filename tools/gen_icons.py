# -*- coding: utf-8 -*-
"""生成桌面看板所需的单色天气图标（黑底透明，RGBA PNG）。

不依赖第三方库：自带最小 PNG 编码器（zlib + struct），逐像素绘制。
输出 160x160，插件侧按需缩放，避免小尺寸下的锯齿。
"""

import os
import struct
import zlib

SIZE = 160


# ------------------------------------------------------------------ PNG 编码
def write_png(path, width, height, rgba):
    raw = bytearray()
    stride = width * 4
    for y in range(height):
        raw.append(0)  # filter type 0
        raw.extend(rgba[y * stride:(y + 1) * stride])

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", ihdr)
           + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
           + chunk(b"IEND", b""))
    with open(path, "wb") as f:
        f.write(png)


# ------------------------------------------------------------------ 画布
class Canvas:
    def __init__(self, size=SIZE):
        self.w = self.h = size
        self.buf = bytearray(b"\x00" * (size * size * 4))

    def px(self, x, y, a):
        x, y = int(x), int(y)
        if 0 <= x < self.w and 0 <= y < self.h and a > 0:
            i = (y * self.w + x) * 4
            cur = self.buf[i + 3]
            if a > cur:
                self.buf[i] = 0
                self.buf[i + 1] = 0
                self.buf[i + 2] = 0
                self.buf[i + 3] = a

    def circle(self, cx, cy, r, a=255):
        r2 = r * r
        for y in range(int(cy - r), int(cy + r) + 1):
            for x in range(int(cx - r), int(cx + r) + 1):
                d2 = (x - cx) ** 2 + (y - cy) ** 2
                if d2 <= r2:
                    self.px(x, y, a)
                elif d2 <= (r + 1) ** 2:
                    self.px(x, y, int(a * (1 - (d2 ** 0.5 - r))))

    def ring(self, cx, cy, r, thick, a=255):
        r_in = r - thick
        for y in range(int(cy - r), int(cy + r) + 1):
            for x in range(int(cx - r), int(cx + r) + 1):
                d = ((x - cx) ** 2 + (y - cy) ** 2) ** 0.5
                if r_in <= d <= r:
                    self.px(x, y, a)

    def rect(self, x0, y0, x1, y1, a=255):
        for y in range(int(y0), int(y1) + 1):
            for x in range(int(x0), int(x1) + 1):
                self.px(x, y, a)

    def line(self, x0, y0, x1, y1, thick=6, a=255):
        dx, dy = x1 - x0, y1 - y0
        length = max(1.0, (dx * dx + dy * dy) ** 0.5)
        r = thick / 2.0
        for y in range(int(min(y0, y1) - r) - 1, int(max(y0, y1) + r) + 2):
            for x in range(int(min(x0, x1) - r) - 1, int(max(x0, x1) + r) + 2):
                t = ((x - x0) * dx + (y - y0) * dy) / (length * length)
                t = max(0.0, min(1.0, t))
                px_, py_ = x0 + t * dx, y0 + t * dy
                if ((x - px_) ** 2 + (y - py_) ** 2) ** 0.5 <= r:
                    self.px(x, y, a)

    def poly(self, pts, a=255):
        ys = [p[1] for p in pts]
        for y in range(int(min(ys)), int(max(ys)) + 1):
            xs = []
            for i in range(len(pts)):
                x0, y0 = pts[i]
                x1, y1 = pts[(i + 1) % len(pts)]
                if y0 == y1:
                    continue
                if min(y0, y1) <= y < max(y0, y1):
                    xs.append(x0 + (y - y0) * (x1 - x0) / (y1 - y0))
            xs.sort()
            for i in range(0, len(xs) - 1, 2):
                for x in range(int(xs[i]) + 1, int(xs[i + 1])):
                    self.px(x, y, a)


# ------------------------------------------------------------------ 元件
def sun(c, cx, cy, r=30, rays=True, a=255):
    c.circle(cx, cy, r, a)
    if rays:
        import math
        for i in range(8):
            ang = math.radians(i * 45)
            x0 = cx + math.cos(ang) * (r + 8)
            y0 = cy + math.sin(ang) * (r + 8)
            x1 = cx + math.cos(ang) * (r + 24)
            y1 = cy + math.sin(ang) * (r + 24)
            c.line(x0, y0, x1, y1, 8, a)


def cloud(c, dy=0, a=255):
    c.circle(62, 92 + dy, 26, a)
    c.circle(92, 78 + dy, 32, a)
    c.circle(120, 94 + dy, 24, a)
    c.rect(62, 92 + dy, 120, 116 + dy, a)


def rain(c, count=4, a=255):
    import math
    for i in range(count):
        x = 56 + i * 20
        c.line(x, 124, x - 12, 148, 8, a)


def snow(c, count=3, a=255):
    for i in range(count):
        cx, cy = 58 + i * 26, 136
        for k in range(3):
            import math
            ang = math.radians(k * 60)
            c.line(cx - math.cos(ang) * 9, cy - math.sin(ang) * 9,
                   cx + math.cos(ang) * 9, cy + math.sin(ang) * 9, 5, a)


def bolt(c, a=255):
    c.poly([(84, 112), (104, 112), (92, 132), (106, 132), (78, 158), (88, 138), (76, 138)], a)


def fog(c, a=255):
    for i in range(3):
        y = 128 + i * 12
        c.line(44, y, 116 - i * 6, y, 8, a)


ICONS = {}


def icon(name):
    def deco(fn):
        ICONS[name] = fn
        return fn
    return deco


@icon("clear")
def _(c):
    sun(c, 80, 80, 34)


@icon("mainly_clear")
def _(c):
    sun(c, 56, 52, 22)
    cloud(c, 26)


@icon("partly")
def _(c):
    sun(c, 48, 46, 18)
    cloud(c, 30)


@icon("overcast")
def _(c):
    cloud(c, -14, 120)
    cloud(c, 12)


@icon("fog")
def _(c):
    cloud(c, -6)
    fog(c)


@icon("drizzle")
def _(c):
    cloud(c, -6)
    rain(c, 4)


@icon("rain")
def _(c):
    cloud(c, -8)
    rain(c, 4)


@icon("freezing_rain")
def _(c):
    cloud(c, -8)
    rain(c, 3)
    c.circle(126, 140, 6)
    c.circle(70, 140, 6)


@icon("snow")
def _(c):
    cloud(c, -6)
    snow(c, 3)


@icon("shower")
def _(c):
    sun(c, 52, 52, 18, rays=False)
    cloud(c, 0)
    rain(c, 3)


@icon("snow_shower")
def _(c):
    sun(c, 52, 52, 18, rays=False)
    cloud(c, 0)
    snow(c, 3)


@icon("thunder")
def _(c):
    cloud(c, -10)
    bolt(c)


def main():
    out_dir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                           "dashboard.koplugin", "icons")
    os.makedirs(out_dir, exist_ok=True)
    for name, fn in ICONS.items():
        c = Canvas()
        fn(c)
        path = os.path.join(out_dir, name + ".png")
        write_png(path, c.w, c.h, c.buf)
        print(f"{name}.png  {os.path.getsize(path)} bytes")
    print(f"\n共生成 {len(ICONS)} 个图标 -> {out_dir}")


if __name__ == "__main__":
    main()
