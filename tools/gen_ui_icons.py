#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""预渲染 UI 图标（无线 / 湿度 / 风力 / 污染）。

为什么不用 main.lua 里的矢量 Icon 现场画：
    Icon:paintTo 逐段拼线、逐点 stamp 方块，还要把分数坐标交给
    bb:paintCircle()；真机（KOReader 的 blitbuffer）与本地桩件对同一个
    调用的解释并不一致（第 5 个参数：真机是布尔 filled，桩件当线宽），
    于是「预览干净、真机多了几个孤立墨点」。位图没有这个问题：
    一个像素一个值，画成什么样就是什么样，也不会越出自己的方框。

字形与 main.lua 的 ICON 表一一对应（24×24 设计栅格），只是换成
「先画成矢量、再按目标像素**精确**光栅化」，所以：
    · 24 栅格坐标直接照抄，改一处两边一致；
    · 输出边长 = 控件实测边长，ImageWidget 拿到 1:1 不缩放（缩放会掉像素）。

用法：
    python tools/gen_ui_icons.py                     # 出全部图标 + 审核图
    python tools/gen_ui_icons.py --sheet-only         # 只重出审核图
    python tools/gen_ui_icons.py --sizes 53,57        # 指定像素边长
"""

import math
import os
import struct
import sys
import zlib

# 每个字形要出哪几种「边长 × 墨色」—— 必须和 main.lua 里各调用点的 size
# 严格相等，ImageWidget 拿到不同边长的图就会缩放，抗锯齿的边会被再采样一遍。
#   53 = floor(30·S) 顶栏 WiFi；89 = floor(50·S) 电量网络卡
#   57 = floor(32·S) 三格状态；  35 = floor(20·S) 空气明细卡块头
# S = min(1072,1448)/600 = 1.7867（PW3）。换机型按同一条公式重算并重出。
#
# 墨色要单独出：电量网络卡里"已连接"用纯黑（和电池壳体同一档），
# 未连接/未开启才用 0x66。位图是死色，不能像矢量那样运行时改 color，
# 所以两种墨各存一份（文件名后缀 -b 表示黑墨）。
INK_GRAY, INK_BLACK = 102, 0
SIZE_MAP = {
    "wifi_on": ((53, INK_GRAY), (89, INK_GRAY), (89, INK_BLACK)),
    "wifi_slash": ((53, INK_GRAY), (89, INK_GRAY)),
    "wifi_off": ((53, INK_GRAY), (89, INK_GRAY)),
    "humidity": ((57, INK_GRAY),),
    "wind": ((57, INK_GRAY),),
    "aqi_fixed": ((35, INK_GRAY), (57, INK_GRAY)),
}

INK = 102          # 0x66，与 INK2 一致：图标和旁边的 17du 标签同一档灰度
PAPER = 238        # 0xEE，纸底；审核图按它合成，才和真机观感一致
GRID = 24          # 设计栅格边长
SS = 6             # 光栅化超采样倍数

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.join(os.path.dirname(HERE), "dashboard.koplugin", "icons", "ui")
REVIEW_DIR = os.path.join(os.path.dirname(HERE), "preview", "_review")


# ------------------------------------------------------------------ PNG 编码
def write_png(path, w, h, rgba):
    raw = bytearray()
    stride = w * 4
    for y in range(h):
        raw.append(0)
        raw.extend(rgba[y * stride:(y + 1) * stride])

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    ihdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)
    png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
           + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b""))
    with open(path, "wb") as f:
        f.write(png)


# ------------------------------------------------------------------ 光栅化
class Cover:
    """在 SS 倍画布上记覆盖，再降采样成 alpha。"""

    def __init__(self, size):
        self.size = size
        self.n = size * SS
        self.buf = bytearray(self.n * self.n)   # 0/1 覆盖

    def _dot(self, x, y):
        if 0 <= x < self.n and 0 <= y < self.n:
            self.buf[y * self.n + x] = 1

    def disc(self, cx, cy, r):
        """实心圆：中心/半径都是设计栅格单位。"""
        k = self.n / float(GRID)
        cx, cy, r = cx * k, cy * k, r * k
        for y in range(int(cy - r) - 1, int(cy + r) + 2):
            for x in range(int(cx - r) - 1, int(cx + r) + 2):
                if (x - cx) ** 2 + (y - cy) ** 2 <= r * r:
                    self._dot(x, y)

    def line(self, x0, y0, x1, y1, thick, cap=False, erase=False):
        """直线。x/y 是设计栅格单位，thick 是**设备像素**宽
        （和 Icon:paintTo 里 t = max(3, floor(u*2.1)) 同一档），
        所以换算成超采样像素时只乘 SS，不能再乘设计栅格的 k。

        cap=False 用平头：长横线两端的圆头在 57px 上会鼓成菱形，
        看起来像多了两个尖，比原图还脏。cap=True 留给弧线的细分段
        （每段只有零点几像素，平头会在弯道上断成虚线）。
        erase=True 反着写：擦掉已经画上的墨。
        """
        k = self.n / float(GRID)
        x0, y0, x1, y1 = x0 * k, y0 * k, x1 * k, y1 * k
        r = thick * SS / 2.0
        dx, dy = x1 - x0, y1 - y0
        ln2 = max(1e-9, dx * dx + dy * dy)
        for y in range(int(min(y0, y1) - r) - 1, int(max(y0, y1) + r) + 2):
            for x in range(int(min(x0, x1) - r) - 1, int(max(x0, x1) + r) + 2):
                t = ((x - x0) * dx + (y - y0) * dy) / ln2
                if not cap and (t < 0.0 or t > 1.0):
                    continue
                t = max(0.0, min(1.0, t))
                px_, py_ = x0 + t * dx, y0 + t * dy
                if (x - px_) ** 2 + (y - py_) ** 2 <= r * r:
                    if erase:
                        if 0 <= x < self.n and 0 <= y < self.n:
                            self.buf[y * self.n + x] = 0
                    else:
                        self._dot(x, y)

    def arc(self, cx, cy, r, a0, sweep, thick):
        """角度用数学约定（0° 指右、逆时针为正），与 main.lua 的 paintArc 一致。"""
        steps = max(8, int(abs(sweep) / 1.5))
        px_ = py_ = None
        for i in range(steps + 1):
            a = math.radians(a0 + sweep * i / steps)
            x = cx + math.cos(a) * r
            y = cy - math.sin(a) * r
            if px_ is not None:
                self.line(px_, py_, x, y, thick, cap=True)
            px_, py_ = x, y

    def arc_dashed(self, cx, cy, r, a0, sweep, dashes, thick):
        """虚线弧：把 sweep 均分成 2n-1 格，奇数格画、偶数格留空。

        为什么不在弧线上按像素长度切：n 取 2/3/4 对应半径 4/8/12，
        正好让每一段的**弧长**都在 2.4u 上下（换算到 57px 约 5.7px），
        三段弧看起来是同一个笔触密度，而不是内圈碎成点、外圈连成线。
        """
        n = max(1, dashes)
        slot = abs(sweep) / (2 * n - 1)
        for i in range(n):
            s0 = a0 + (2 * i) * slot * (1 if sweep > 0 else -1)
            self.arc(cx, cy, r, s0, slot, thick)

    def alpha(self):
        """降采样：返回 size×size 的 0..255 alpha。"""
        out = bytearray(self.size * self.size)
        area = SS * SS
        for y in range(self.size):
            for x in range(self.size):
                acc = 0
                for dy in range(SS):
                    row = (y * SS + dy) * self.n + x * SS
                    acc += sum(self.buf[row:row + SS])
                out[y * self.size + x] = int(round(255.0 * acc / area))
        return out


def render(size, shapes, thick, hard):
    c = Cover(size)
    for sh in shapes:
        k = sh[0]
        if k == "l":
            c.line(sh[1], sh[2], sh[3], sh[4], thick)
        elif k == "a":
            c.arc(sh[1], sh[2], sh[3], sh[4], sh[5], thick)
        elif k == "d":
            c.arc_dashed(sh[1], sh[2], sh[3], sh[4], sh[5], sh[6], thick)
        elif k == "o":
            c.disc(sh[1], sh[2], sh[3])
        elif k == "k":
            # 挖空带：沿这条线把已经画上的墨擦掉，宽度 = 线宽 × 倍数
            c.line(sh[1], sh[2], sh[3], sh[4], thick * sh[5], erase=True)
    a = c.alpha()
    if hard:
        # 硬边：按覆盖率过半判定，边缘不出现中间灰（和现在矢量渲染的观感一致）
        a = bytearray(255 if v >= 128 else 0 for v in a)
    return a


def to_rgba(alpha, size, ink=INK):
    buf = bytearray(size * size * 4)
    for i, v in enumerate(alpha):
        if v:
            j = i * 4
            buf[j] = ink
            buf[j + 1] = ink
            buf[j + 2] = ink
            buf[j + 3] = v
    return buf


# ------------------------------------------------------------------ 图形定义
def thick_for(size):
    """与 Icon:paintTo 同一条公式：max(3, floor(u*2.1))，u = size/24。"""
    return max(3, int(size / float(GRID) * 2.1))


def drop():
    # 顶端 + 两条切线 + 180° 下弧。
    # 原 Lua 里 sweep 写的是 -206：多转 26°，左侧收尾会翘出一个凸起（真机可见）。
    return [
        ("l", 12, 2.2, 5.2, 13.4),
        ("l", 12, 2.2, 18.8, 13.4),
        ("a", 12, 13.4, 6.8, 0, -180),
    ]


def wind():
    return [
        ("l", 2.2, 3.6, 13.6, 3.6),
        ("a", 13.6, 7.2, 3.6, 90, -120),
        ("l", 2.2, 14.5, 21.4, 14.5),
        ("l", 2.2, 21.5, 10.8, 21.5),
    ]


def wifi(lit=3, slash=False, dashed=False):
    """三段弧 + 底点。弧心 (12,20.5)、半径 4/8/12，实体在 45°~135°。

    底点原来是 (12,19.4) r=2.0：r=2u 在 57px 上是 4.75px，紧贴着最内圈弧的
    两个端点，光栅化后粘成"蘑菇"。改成 r=1.25 并下移到弧心 (12,20.4) ——
    点落在弧的圆心上，才像信号源，也留出 2px 的空。

    dashed=True 出「未开启」：三段弧全画成虚线。只亮最内一段的做法在 53px
    上读不出是无线图标——一小截弧加斜杠更像「禁止」；虚线本身就在说
    「信号是断的」，三段一起出现才认得出是 WiFi。
    """
    radii = (4.0, 8.0, 12.0)[:max(1, min(3, lit))]
    if dashed:
        # 每段弧的虚线数 内 2 / 中 2 / 外 3：53px 上笔画只有 4px，
        # 切太密（4/3/2）每一段都短到只剩两三个像素，整体读成"糊掉的图标"；
        # 少切几刀、每段留长一点，才看得出是「断了的三段弧」。
        out = [("d", 12, 20.5, r, 45, 90, n)
               for r, n in ((4.0, 2), (8.0, 2), (12.0, 3)) if r in radii]
    else:
        out = [("a", 12, 20.5, r, 45, 90) for r in radii]
    out.append(("o", 12, 20.4, 1.25))
    if slash:
        # 先沿斜杠挖一条留白，再压斜杠本体：不挖的话斜杠和弧同色，
        # 交叉处糊成一片，"划掉"的意思读不出来。位图才能这么做。
        # 虚线版挖窄一点（1.25×）：弧本身已经有断口，再挖宽就等于多切一刀，
        # 剩下的笔画会碎到认不出形状。
        out.append(("k", 3.6, 20.4, 20.4, 3.6, 1.25 if dashed else 1.5))
        out.append(("l", 3.6, 20.4, 20.4, 3.6))
    return out


def aqi(step=None, steps=13):
    """刻度盘。step=None 出无指针版；否则指针按 step/(steps-1) 落在 180°..0°。"""
    out = [("a", 12, 16.8, 11.0, 180, -180)]
    if step is not None:
        v = step / float(steps - 1)
        a = math.radians(180 - v * 180)
        out.append(("l", 12, 16.8, 12 + math.cos(a) * 7.6, 16.8 - math.sin(a) * 7.6))
    out.append(("o", 12, 16.8, 2.0))
    return out


def icon_set():
    items = [
        ("wifi_on", wifi(3, False), "无线·已连接"),
        ("wifi_slash", wifi(3, True), "无线·未连接"),
        ("wifi_off", wifi(3, True, True), "无线·未开启（虚线弧）"),
        ("humidity", drop(), "湿度"),
        ("wind", wind(), "风力"),
        ("aqi_fixed", aqi(None), "污染·无指针"),
    ]
    for i in range(13):
        items.append(("aqi_p%02d" % i, aqi(i), "污染·指针 %d°" % (180 - i * 15)))
    return items


def sizes_for(name):
    """返回 [(边长, 墨色), ...]；aqi 的 13 档共用 aqi_fixed 那一套尺寸。"""
    if name.startswith("aqi_p"):
        return SIZE_MAP["aqi_fixed"]
    return SIZE_MAP[name]


def fname(name, size, ink):
    return "%s-%d%s.png" % (name, size, "" if ink == INK_GRAY else "-b")


# ------------------------------------------------------------------ 审核图
def _font(size):
    from PIL import ImageFont
    for p in ("C:/Windows/Fonts/msyh.ttc", "C:/Windows/Fonts/simhei.ttf",
              "/System/Library/Fonts/PingFang.ttc",
              "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc"):
        if os.path.exists(p):
            try:
                return ImageFont.truetype(p, size)
            except Exception:
                pass
    return ImageFont.load_default()


def _tile(size, shapes, hard, ink=INK):
    """把 alpha 合到纸底色上再交出——审核图必须按设备上的真实底色（0xEE）
    预览，浮在白底上会显得比真机更淡。"""
    from PIL import Image
    a = render(size, shapes, thick_for(size), hard)
    tile = Image.new("RGBA", (size, size), (PAPER, PAPER, PAPER, 255))
    px = tile.load()
    for i, v in enumerate(a):
        if v:
            px[i % size, i // size] = (ink, ink, ink, v)
    return tile


def make_sheet(items, big=5):
    """审核图：每行一枚字形。左列是它**实际使用**的像素边长（1:1），
    右边两列放大看形状；抗锯齿版是采用版（标题里打了 ✓）。"""
    from PIL import Image, ImageDraw

    f_title, f_name, f_meta, f_tiny = _font(30), _font(24), _font(18), _font(16)
    pad, gap, label_w = 28, 20, 250
    zoom = 57 * big
    col_w = [130, zoom + 26, zoom + 26]
    strip_h = 120

    main = [it for it in items if not it[0].startswith("aqi_p")]
    steps = [it for it in items if it[0].startswith("aqi_p")]

    W = pad * 2 + label_w + sum(col_w) + gap * 2
    row_h = zoom + gap + 22
    H = 132 + row_h * len(main) + 96 + strip_h + pad

    im = Image.new("RGBA", (W, H), (255, 255, 255, 255))
    d = ImageDraw.Draw(im)
    d.text((pad, 26), "UI 图标预渲染稿（位图替代现场矢量绘制）", fill=(20, 20, 20), font=f_title)
    d.text((pad, 74), "左列是设备上的真实像素（1:1 不缩放，边长按各调用点算好）；右侧放大 %d 倍。" % big,
           fill=(105, 105, 105), font=f_meta)

    for title, x in (("实尺 1:1", pad + label_w),
                     ("%dx 硬边" % big, pad + label_w + col_w[0] + gap),
                     ("%dx 抗锯齿 ✓" % big, pad + label_w + col_w[0] + col_w[1] + gap * 2)):
        d.text((x + 4, 112), title, fill=(140, 140, 140), font=f_tiny)

    y = 132
    for name, shapes, desc in main:
        d.text((pad, y + 4), desc, fill=(20, 20, 20), font=f_name)
        d.text((pad, y + 34), name, fill=(150, 150, 150), font=f_tiny)
        x = pad + label_w
        # 实尺：每种边长都摆一枚，右下角标数字；黑墨版标 b
        sx = x
        for size, ink in sizes_for(name):
            t = _tile(size, shapes, False, ink)
            im.paste(t, (sx, y + (row_h - size) // 2), t)
            d.rectangle([sx - 1, y + (row_h - size) // 2 - 1,
                         sx + size, y + (row_h - size) // 2 + size], outline=(226, 226, 226))
            d.text((sx, y + (row_h - size) // 2 + size + 2),
                   "%d%s" % (size, "" if ink == INK_GRAY else "b"),
                   fill=(150, 150, 150), font=f_tiny)
            sx += size + 16
        for ci, hard in enumerate((True, False), start=1):
            xx = pad + label_w + sum(col_w[:ci]) + gap * ci
            t = _tile(57, shapes, hard).resize((zoom, zoom), Image.NEAREST)
            im.paste(t, (xx + (col_w[ci] - zoom) // 2, y), t)
            d.rectangle([xx + (col_w[ci] - zoom) // 2 - 1, y - 1,
                         xx + (col_w[ci] - zoom) // 2 + zoom, y + zoom], outline=(226, 226, 226))
        y += row_h

    # AQI 指针档位条
    d.text((pad, y + 22), "污染（刻度盘指针）13 档：每 15° 一档，运行时代码按数值取最近的一档",
           fill=(20, 20, 20), font=f_name)
    y += 62
    sw = 57
    sx = pad
    for name, shapes, _ in steps:
        t = _tile(sw, shapes, False)
        im.paste(t, (sx, y), t)
        d.text((sx + 2, y + sw + 2), name.split("_p")[1], fill=(150, 150, 150), font=f_tiny)
        sx += sw + 12
    return im



def main():
    args = sys.argv[1:]
    sheet_only = "--sheet-only" in args
    only = None
    if "--sizes" in args:
        only = tuple(int(v) for v in args[args.index("--sizes") + 1].split(","))

    items = icon_set()
    if not sheet_only:
        os.makedirs(OUT_DIR, exist_ok=True)
        n = 0
        for name, shapes, _ in items:
            for size, ink in sizes_for(name):
                if only and size not in only:
                    continue
                # 抗锯齿：6 倍超采样的覆盖率直接写进 alpha，由 blitbuffer 混合。
                # 硬边版把 1px 笔画削成断点，斜杠和虚线弧尤其经不起。
                a = render(size, shapes, thick_for(size), False)
                write_png(os.path.join(OUT_DIR, fname(name, size, ink)),
                          size, size, to_rgba(a, size, ink))
                n += 1
        print("写入 %d 个 PNG 到 %s" % (n, OUT_DIR))

    os.makedirs(REVIEW_DIR, exist_ok=True)
    sheet = make_sheet(items)
    out = os.path.join(REVIEW_DIR, "ui_icons.png")
    sheet.convert("RGB").save(out, quality=95)
    print("审核图：%s  (%dx%d)" % (out, sheet.size[0], sheet.size[1]))


if __name__ == "__main__":
    main()
