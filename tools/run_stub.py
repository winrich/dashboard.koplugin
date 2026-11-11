"""在竖屏 600x800 与横屏 1024x758 两种尺寸下运行插件冒烟测试。

用法（在项目根目录）：
    python tools/run_stub.py
"""
import os
import sys

from lupa import LuaRuntime

PLUGIN_DIR = "dashboard.koplugin"
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

SYNTAX_FILES = [
    f"{PLUGIN_DIR}/main.lua",
    f"{PLUGIN_DIR}/dashboard_lunar.lua",
    f"{PLUGIN_DIR}/dashboard_cities.lua",
]

DIRECTIONS = [
    ("竖屏", 600, 800),
    ("横屏", 1024, 758),
]


def check_syntax():
    lua = LuaRuntime(unpack_returned_tuples=True)
    loader = lua.eval(
        "function(s, n) local lf = loadstring or load; "
        "local f, e = lf(s, n); if f then return true, '' end; return false, tostring(e) end"
    )
    ok_all = True
    for path in SYNTAX_FILES:
        full = os.path.join(ROOT, path)
        with open(full, encoding="utf-8") as fh:
            src = fh.read()
        ok, err = loader(src, "@" + path)
        if ok:
            print(f"[PASS] 语法 {path}")
        else:
            ok_all = False
            print(f"[FAIL] 语法 {path}\n       {err}")
    return ok_all


def run_direction(label, w, h):
    print(f"\n{'=' * 62}\n== {label} {w}x{h}\n{'=' * 62}")
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(f"STUB_W = {w}; STUB_H = {h}")
    lua.execute(f'arg = {{ [1] = [[{PLUGIN_DIR}]] }}')
    with open(os.path.join(HERE, "stub_test.lua"), encoding="utf-8") as fh:
        src = fh.read()
    try:
        lua.execute(src)
    except Exception as exc:  # noqa: BLE001 - 需要把 Lua 报错原样呈现
        print(f"[FAIL] {label} 执行异常: {exc}")
        return False
    return True


def main():
    os.chdir(ROOT)
    if not check_syntax():
        return 1
    ok = True
    for label, w, h in DIRECTIONS:
        ok = run_direction(label, w, h) and ok
    print()
    print("[PASS] 两个方向全部通过" if ok else "[FAIL] 存在失败项")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
