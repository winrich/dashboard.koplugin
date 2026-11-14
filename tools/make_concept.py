#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""v2.53 视觉语言概念图（1072×1448，1:1 真机像素，KPW3 @300ppi）。

本轮修订：
  · 字号按物理尺寸重定，中文下限 28px（2.37mm / 6.7pt），拉丁数字下限 22px
  · 全页 8px 基线网格，所有块顶/底吸附
  · 三条纵向参考线：左版心 56 / 中缝 536 / 右版心 1016
  · 单位上提到区块标题，不再跟在每个数值后面
  · 数据来源并入区块标题，页脚只留装饰

墨色取 17 的倍数，见 device-tools/calib/RESULTS.md。
圆/圆角真机支持（paintCircle / paintBorder 带半径），预览桩件暂不支持。
"""
import math

from PIL import Image, ImageDraw, ImageFont

W, H = 1072, 1448

I0, I1, I2, I3 = 0x00, 0x33, 0x66, 0x88
L1, L2, F1, F2, PAPER = 0x99, 0xAA, 0xCC, 0xDD, 0xFF

F_SERIF = "F:/koreader/fonts/noto/NotoSerif-Regular.ttf"
F_SANS = "F:/koreader/fonts/noto/NotoSans-Regular.ttf"
F_CJK = "F:/koreader/fonts/noto/NotoSansCJKsc-Regular.otf"

# ---- 字号阶梯（px @300ppi）----
M0, M1, M2, M3, M4 = 160, 104, 46, 30, 26
#   主值  次值   值  标签  微注（仅拉丁/数字）

X_L, X_R = 56, W - 56
X_MID = (X_L + X_R) // 2
COL_W = (X_R - X_L) // 3


def f(p, px):
    return ImageFont.truetype(p, px)


def ink(v):
    return int(v)


im = Image.new("L", (W, H), PAPER)
d = ImageDraw.Draw(im)


def text(xy, s, font, color):
    d.text(xy, s, font=font, fill=ink(color))


def wof(s, font):
    return d.textlength(s, font=font)


def text_r(x_right, y, s, font, color):
    """右对齐到给定参考线。"""
    text((x_right - wof(s, font), y), s, font, color)


def text_c(x_center, y, s, font, color):
    text((x_center - wof(s, font) / 2, y), s, font, color)


# ---------------------------------------------------------------- 装裱细框
d.rounded_rectangle([18, 18, W - 19, H - 19], radius=14, outline=ink(F2), width=1)

# ---------------------------------------------------------------- 顶栏
text((X_L, 44), "北京", f(F_CJK, 32), I0)
cw = wof("北京", f(F_CJK, 32))
text((X_L + cw + 12, 54), "UTC+8", f(F_SANS, M4), I2)

# 电量：三格 + 百分比，整体右对齐到 X_R
bw, bh = 66, 28
bx1 = X_R
bx0 = bx1 - bw
by = 50
d.rounded_rectangle([bx0, by, bx1, by + bh], radius=4, outline=ink(L1), width=1)
for i in range(3):
    x = bx0 + 5 + i * 20
    d.rectangle([x, by + 5, x + 15, by + bh - 5], fill=ink(I1) if i < 2 else PAPER)
d.rectangle([bx1 + 1, by + 9, bx1 + 6, by + 19], fill=ink(L1))
text_r(bx0 - 14, by + 2, "58%", f(F_SANS, M4), I2)


# ---------------------------------------------------------------- 区块标题
def section(y, label, note=None):
    text((X_L, y), label, f(F_CJK, M3), I1)
    if note:
        text_r(X_R, y + 2, note, f(F_CJK, 24), I2)
    d.rectangle([X_L, y + 46, X_R, y + 46], fill=ink(F2))
    return y + 46


# ---------------------------------------------------------------- A 区：天气
section(118, "天气", "和风 16:18")

CX, CY, R = 158, 296, 56
for i in range(12):
    a = math.radians(i * 30)
    r0, r1 = R + 18, R + 18 + (30 if i % 3 == 0 else 20)
    d.line([CX + r0 * math.cos(a), CY + r0 * math.sin(a),
            CX + r1 * math.cos(a), CY + r1 * math.sin(a)],
           fill=ink(I0), width=6 if i % 3 == 0 else 3)
d.ellipse([CX - R, CY - R, CX + R, CY + R], fill=ink(I0))

fT = f(F_SERIF, M0)
text((282, 190), "13", fT, I0)
w13 = wof("13", fT)
text((282 + w13 + 8, 198), "°", f(F_SERIF, 58), I2)

text((286, 366), "晴", f(F_CJK, M2), I1)
text((286, 432), "1° ~ 14°", f(F_SANS, 36), I2)

text_r(X_R, 196, "最高 14°", f(F_CJK, M3), I2)
text_r(X_R, 252, "最低 1°", f(F_CJK, M3), I2)
text_r(X_R, 308, "体感 10°", f(F_CJK, M3), I2)

# ---------------------------------------------------------------- B 区：空气
section(500, "空气 · µg/m³", "首要 PM2.5")

fA = f(F_SERIF, M1)
text((X_L, 568), "65", fA, I0)
wa = wof("65", fA)
text((X_L + wa + 22, 612), "良", f(F_CJK, M2), I1)

sx0, sx1, sy = X_L, X_R, 712
d.rectangle([sx0, sy, sx1, sy + 2], fill=ink(F1))
for fr in (0, 0.22, 0.44, 0.66, 0.88):
    x = sx0 + (sx1 - sx0) * fr
    d.rectangle([x, sy - 10, x + 2, sy + 2], fill=ink(L2))
px = sx0 + (sx1 - sx0) * (65 / 300.0)
d.rectangle([px - 2, sy - 18, px + 2, sy + 10], fill=ink(I0))
for txt, fr in (("0", 0), ("50", 0.22), ("100", 0.44), ("150", 0.66), ("200", 0.88)):
    text_c(sx0 + (sx1 - sx0) * fr, sy + 18, txt, f(F_SANS, M4), I2)

rows = [("PM2.5", "42"), ("PM10", "70"), ("O3", "50"),
        ("NO2", "31"), ("SO2", "4"), ("CO", "0.8")]
fk, fv = f(F_SANS, M3), f(F_SANS, M2)
asc_k = fk.getmetrics()[0]
asc_v = fv.getmetrics()[0]
for i, (k, v) in enumerate(rows):
    r, c = divmod(i, 3)
    x = X_L + c * COL_W
    y = 784 + r * 76
    text((x, y + (asc_v - asc_k)), k, fk, I2)      # 基线对齐，不是顶对齐
    text((x + wof(k, fk) + 16, y), v, fv, I0)

# ---------------------------------------------------------------- C 区：日月
section(976, "日月", "白昼 10:08")

tl_y, tl_x0, tl_x1 = 1108, X_L + 4, 700
d.rectangle([tl_x0, tl_y, tl_x1, tl_y + 2], fill=ink(L1))
frac = (16.30 - 6.90) / (17.03 - 6.90)
sun_x = tl_x0 + (tl_x1 - tl_x0) * frac
for x, lab, tm, align in ((tl_x0, "日出", "06:54", "L"), (tl_x1, "日落", "17:02", "R")):
    d.rectangle([x - 3, tl_y - 13, x + 3, tl_y + 15], fill=ink(I0))
    ft, fl = f(F_SANS, M2), f(F_CJK, M3)
    if align == "L":
        text((x, tl_y - 66), lab, fl, I2)
        text((x, tl_y + 26), tm, ft, I0)
    else:
        text_r(x, tl_y - 66, lab, fl, I2)
        text_r(x, tl_y + 26, tm, ft, I0)
d.ellipse([sun_x - 10, tl_y - 10, sun_x + 10, tl_y + 10], fill=ink(I0))

mx, my, mr = 936, 1116, 46
d.ellipse([mx - mr, my - mr, mx + mr, my + mr], fill=ink(I0))
d.ellipse([mx - mr - 19, my - mr, mx + mr - 19, my + mr], fill=ink(PAPER))
text_r(866, 1050, "蛾眉月", f(F_CJK, 36), I1)
text_r(866, 1102, "亮面 18%", f(F_CJK, M3), I2)

# ---------------------------------------------------------------- 页脚装饰
dy = 1286
for i in range(6):
    x = X_R - (5 - i) * 16
    if i == 2:
        d.rectangle([x, dy, x + 8, dy + 8], fill=ink(I0))
    else:
        d.rectangle([x, dy, x + 8, dy + 8], outline=ink(L2), width=1)

for i in range(0, (X_R - X_L) // 12 + 1):
    x = X_L + i * 12
    h = 9 if i % 5 == 0 else 4
    d.rectangle([x, 1402 - h, x + 1, 1402], fill=ink(F2))

im.save("preview/_review/concept-after.png")

# ---------------------------------------------------------------- 网格与对齐导图
grid = im.convert("RGB")
gd = ImageDraw.Draw(grid)

for y in range(0, H, 8):
    if y % 40 == 0:
        gd.line([(0, y), (W, y)], fill=(210, 232, 250), width=1)
    elif y % 16 == 0:
        gd.line([(0, y), (W, y)], fill=(240, 247, 252), width=1)
for x, col in ((X_L, (255, 120, 150)), (X_MID, (255, 190, 120)), (X_R, (255, 120, 150))):
    gd.line([(x, 0), (x, H)], fill=col, width=1)
for c in (X_L + COL_W, X_L + 2 * COL_W):
    gd.line([(c, 780), (c, 980)], fill=(150, 235, 185), width=1)
for y in (118, 164, 520, 566, 748, 812, 908, 1032, 1078):
    gd.line([(0, y), (26, y)], fill=(255, 120, 150), width=2)

lg = Image.new("RGB", (W, 120), (255, 255, 255))
ld = ImageDraw.Draw(lg)
f_lab = f(F_CJK, 24)
for i, (col, s) in enumerate([((255, 120, 150), "版心线 X=56 / X=1016"),
                              ((255, 190, 120), "中缝 X=536"),
                              ((150, 235, 185), "三列网格 320px"),
                              ((210, 232, 250), "基线网格 8px / 主格 40px")]):
    x = 30 + (i % 2) * 520
    y = 22 + (i // 2) * 46
    ld.rectangle([x, y + 6, x + 18, y + 18], fill=col)
    ld.text((x + 28, y), s, font=f_lab, fill=(30, 30, 30))
out = Image.new("RGB", (W, H + 120), (255, 255, 255))
out.paste(grid, (0, 0))
out.paste(lg, (0, H))
out.save("preview/_review/concept-grid.png")

# ---------------------------------------------------------------- 并排对比
before = Image.open("preview/portrait-3.png").convert("L")
gap = 26
canvas = Image.new("L", (W * 2 + gap + 40, H + 76), 0xF6)
canvas.paste(before, (20, 56))
canvas.paste(im, (20 + W + gap, 56))
dc = ImageDraw.Draw(canvas)
dc.text((20, 14), "现状 v2.51", font=f(F_CJK, 26), fill=0x00)
dc.text((20 + W + gap, 14), "概念 v2.53（同内容 · 可读字号）",
        font=f(F_CJK, 26), fill=0x00)
canvas.save("preview/_review/concept-before-after.png")
print("ok", im.size, out.size, canvas.size)
