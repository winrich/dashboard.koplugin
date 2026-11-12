#!/usr/bin/env python3
"""检查界面文案的英文覆盖率。

用法：python tools/i18n_check.py [-v]

做的事：
  1. 从 main.lua 里抽出所有 T("...") 的字面量（只认单行、无拼接的调用）；
  2. 从 dashboard_i18n.lua 的 EN 表里抽出已翻译的键；
  3. 列出「代码里在用、但没有英文」的条目，以及「表里有、代码已不用」的条目。

为什么只扫单行字面量：多行拼接（T("a" .. "b")）的键是运行时拼出来的，
静态扫不到；这类文案已经改用 TL(zh, en) 显式二选一，不依赖词表。
静态查不出来的部分只能靠真机切英文看一遍，工具只负责兜住绝大多数短标签。
"""

import re
import sys
import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PLUGIN = os.path.join(ROOT, "dashboard.koplugin")


def t_keys(path):
    """抽出 T("…") 的单行字面量键。"""
    text = open(path, encoding="utf-8").read()
    keys = set()
    # T("...") 后面不能紧跟 .. 这类拼接：用负向断言排除
    for m in re.finditer(r'\bT\("((?:[^"\\]|\\.)*)"\)', text):
        keys.add(m.group(1))
    return keys


def en_keys(path):
    text = open(path, encoding="utf-8").read()
    start = text.index("local EN = {")
    end = text.index("\n}", start)
    body = text[start:end]
    keys = set()
    for m in re.finditer(r'^\s{4}\["((?:[^"\\]|\\.)*)"\]\s*=', body, re.M):
        keys.add(m.group(1))
    return keys


def main():
    verbose = "-v" in sys.argv
    used = t_keys(os.path.join(PLUGIN, "main.lua"))
    have = en_keys(os.path.join(PLUGIN, "dashboard_i18n.lua"))

    missing = sorted(used - have)
    unused = sorted(have - used)

    print(f"代码里 T() 字面量 : {len(used)}")
    print(f"英文词条          : {len(have)}")
    print(f"缺英文            : {len(missing)}")
    print(f"表内未使用        : {len(unused)}")

    if missing:
        print("\n---------- 缺英文（英文模式下会原样显示中文）----------")
        for k in missing:
            print(f"  {k!r}")
    if verbose and unused:
        print("\n---------- 表内未使用 ----------")
        for k in unused:
            print(f"  {k!r}")

    # 缺英文不算失败：T() 会退回中文，功能正常。只是覆盖率需要盯着。
    return 0


if __name__ == "__main__":
    sys.exit(main())
