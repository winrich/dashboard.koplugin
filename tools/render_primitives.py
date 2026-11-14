"""出「绘制原语自检页」：验证桩件记录 → 渲染器还原这条链。

P0 给桩件补了 paintCircle / paintRoundedRect / 圆角 paintBorder / paintRoundedCorner，
但这四个原语目前没有任何组件在用，正常出图看不到它们。这个脚本走桩件里
STUB_PRIMITIVES 分支，把原语按真机同款参数直接画一页，用于：

  · 圆边缘有没有锯齿、最小半径能到多少；
  · 月牙（两圆相减）的缺口方向对不对；
  · 圆角与直边的接缝在 1px 线宽下顺不顺；
  · 进度槽「槽 + 填」两段圆角能否对齐。

用法（项目根目录）：
    python tools/render_primitives.py
输出 preview/_review/primitives.png（1:1，1072×1448）。
"""

import os

from render_board import NATIVE_H, NATIVE_W, OUT_DIR, ROOT, draw_items, grab

OUT = os.path.join(OUT_DIR, "_review", "primitives.png")


def main():
    items = grab(NATIVE_W, NATIVE_H, 0, ["clock_weather"], "zh", "58", "on", "1",
                 extra_lua="STUB_PRIMITIVES = true\n")
    img = draw_items(items, NATIVE_W, NATIVE_H)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    img.save(OUT, optimize=True)
    kinds = {}
    for tag, *_ in items:
        kinds[tag] = kinds.get(tag, 0) + 1
    print("[OK] 原语自检页 %dx%d  %d 个元素  %s"
          % (NATIVE_W, NATIVE_H, len(items),
             " ".join("%s×%d" % (k, v) for k, v in sorted(kinds.items()))))
    print("     " + os.path.relpath(OUT, ROOT).replace(os.sep, "/"))


if __name__ == "__main__":
    main()
