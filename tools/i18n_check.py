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


def strip_comments(text):
    """去掉 Lua 注释，只留代码。

    为什么必须去：main.lua 里有一段文档注释在**引用 KOReader 核心源码**的写法
    （`---   self.menu_items.screensaver = { text = T("Sleep screen"), ...`），
    不去掉就会被当成「我们有个叫 Sleep screen 的文案没翻译」，白白多一条假告警。

    只处理行注释 `--` 与长注释 `--[[ ]]` / `--[=[ ]=]`；字符串里的 `--` 不动。
    字符串扫描按 Lua 规则只认 `"` 与 `'`（本项目不用长字符串装文案）。
    """
    out = []
    i, n = 0, len(text)
    quote = None
    while i < n:
        c = text[i]
        if quote:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if c == quote or c == "\n":
                quote = None
            i += 1
            continue
        if c in "\"'":
            quote = c
            out.append(c)
            i += 1
            continue
        if text.startswith("--", i):
            m = re.match(r"--\[(=*)\[", text[i:])
            if m:                      # 长注释：跳到配对的 ]]（带等号要配对）
                close = "]" + m.group(1) + "]"
                j = text.find(close, i + m.end())
                i = n if j < 0 else j + len(close)
                out.append("\n")       # 保留换行，避免把上下两行粘成一行
                continue
            j = text.find("\n", i)     # 行注释：吃到行尾
            i = n if j < 0 else j
            continue
        out.append(c)
        i += 1
    return "".join(out)


def t_keys(path):
    """抽出 T("…") 的单行字面量键（注释里的示例不算）。"""
    text = strip_comments(open(path, encoding="utf-8").read())
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


def dynamic_keys():
    """运行时才拼出来的键：静态扫不到 T("…")，但确实是按词表翻译的。

    三类：
      1. 天气现象 —— `T(meta[1])`，meta 来自 QWeather.CONDITIONS / OpenMeteo.CODES
         的**第一个**字符串（两张表都长这样：{ "晴", "clear" } / { "晴", 100 }）；
      2. 组件名 —— 菜单里 `T(c.label)`，label 写在 main.lua 的 COMPONENTS 表；
      3. 凭据来源 —— `T(SOURCE_NAMES[key])`，值写在 main.lua 的 SOURCE_NAMES 表。

    不把这些算进来，条件词条会被整片误报成「表内未使用」，
    真正的死词条就淹在噪声里看不出来了。
    """
    keys = set()

    for fn, pat in (
        ("dashboard_qweather.lua", r'\[\d+\]\s*=\s*\{\s*"((?:[^"\\]|\\.)*)"'),
        ("dashboard_openmeteo.lua", r'\[\d+\]\s*=\s*\{\s*"((?:[^"\\]|\\.)*)"'),
    ):
        text = open(os.path.join(PLUGIN, fn), encoding="utf-8").read()
        keys.update(re.findall(pat, text))

    # 天气码表查不到时的兜底现象名 `... or { "未知天气", "partly" }`，
    # 不写成 [N] = {...}，上面两条正则漏掉，单独补一条。
    text = open(os.path.join(PLUGIN, "dashboard_qweather.lua"), encoding="utf-8").read()
    keys.update(re.findall(r'\bor\s*\{\s*"((?:[^"\\]|\\.)*)"\s*,', text))

    main = open(os.path.join(PLUGIN, "main.lua"), encoding="utf-8").read()
    for block, pat in (
        ("COMPONENTS", r'label\s*=\s*"((?:[^"\\]|\\.)*)"'),
        ("SOURCE_NAMES", r'^\s*(?:file|local_|settings|none)\s*=\s*"((?:[^"\\]|\\.)*)"'),
    ):
        m = re.search(r'local %s = \{.*?\n\}' % block, main, re.S)
        if m:
            keys.update(re.findall(pat, m.group(0), re.M))
    return keys


def main():
    verbose = "-v" in sys.argv
    used = t_keys(os.path.join(PLUGIN, "main.lua"))
    have = en_keys(os.path.join(PLUGIN, "dashboard_i18n.lua"))
    dyn = dynamic_keys()

    missing = sorted(used - have)
    unused = sorted(have - used - dyn)

    print(f"代码里 T() 字面量 : {len(used)}")
    print(f"运行时动态键      : {len(dyn)}（天气现象、组件名、凭据来源）")
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
