"""在多种屏幕尺寸下运行插件冒烟测试。

覆盖：
  · KPW3 竖屏 1072x1448（300ppi，3000 系列，用户实际设备）
  · KPW3 横屏 1448x1072
  · 600x800 与 800x600（167ppi 老机型，回归用）

用法（在项目根目录）：
    python tools/run_stub.py
"""
import gzip
import json
import os
import sys

from lupa import LuaRuntime

PLUGIN_DIR = "dashboard.koplugin"
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# 必须随仓库分发、缺一个就算失败
SYNTAX_FILES = [
    f"{PLUGIN_DIR}/main.lua",
    f"{PLUGIN_DIR}/dashboard_lunar.lua",
    f"{PLUGIN_DIR}/dashboard_cities.lua",
    f"{PLUGIN_DIR}/dashboard_qweather.lua",
    f"{PLUGIN_DIR}/dashboard_openmeteo.lua",
    f"{PLUGIN_DIR}/dashboard_i18n.lua",
    f"{PLUGIN_DIR}/dashboard_config.lua",
]

# 含真实凭据、被 .gitignore 排除。git clone 下来没有它是正常状态，
# 桩件会自己注入假凭据继续验证和风主路径，所以这里存在才检查。
OPTIONAL_SYNTAX_FILES = [
    f"{PLUGIN_DIR}/dashboard_config.local.lua",
]


def syntax_files():
    """实际要检查的文件：必选的全在，可选的仅在存在时加入。"""
    paths = list(SYNTAX_FILES)
    for path in OPTIONAL_SYNTAX_FILES:
        if os.path.exists(os.path.join(ROOT, path)):
            paths.append(path)
    return paths


DIRECTIONS = [
    # (标签, 原生宽, 原生高, 强制版式 None/landscape/portrait, 禁用转屏, 启动旋转值)
    ("竖屏 PW3", 1072, 1448, None, False, 0),
    ("横屏 PW3（KOReader 已转 90°）", 1072, 1448, None, False, 1),
    # 设备不支持转屏时的兜底：左右滑动只能换版式（竖屏屏幕跑横屏版式，最挤的一种）
    ("竖屏 PW3 + 不支持转屏", 1072, 1448, None, True, 0),
    ("竖屏 PW3 + 强制横屏版式", 1072, 1448, "landscape", False, 0),
    ("横屏 PW3 + 强制竖屏版式", 1072, 1448, "portrait", False, 1),
    ("竖屏 老机型", 600, 800, None, False, 0),
    ("横屏 老机型（已转 90°）", 600, 800, None, False, 1),
]


def to_lua(lua, obj):
    """Python 对象 -> 真正的 Lua table（main.lua 里大量用 type(x)=="table" 判断，
    直接把 Python dict 暴露给 Lua 会让这些判断全部失效）。"""
    if isinstance(obj, dict):
        t = lua.table()
        for k, v in obj.items():
            t[k] = to_lua(lua, v)
        return t
    if isinstance(obj, list):
        t = lua.table()
        for i, v in enumerate(obj, 1):
            t[i] = to_lua(lua, v)
        return t
    return obj


def install_bridges(lua):
    """给桩件接上真实的 JSON 解析与 gzip 编解码。

    lupa 在 Lua 与 Python 之间传递 Lua 字符串时会按 UTF-8 解码，二进制 gzip
    字节必然失败，所以二进制一律走 hex 字符串过渡（纯 ASCII，不会被转码破坏）。

    lupa 里没有 ffi，dashboard_qweather 的 libz 解压走不通，测试时把
    QWeather.gunzip 换成 Python zlib 实现，用来验证「gzip 字节 -> 解压 -> JSON
    解析 -> 展示字段」这条完整链路，而不是绕过它。
    """
    def json_loads(s):
        if isinstance(s, bytes):
            s = s.decode("utf-8", "replace")
        return to_lua(lua, json.loads(s))

    def gzip_compress_hex(s):
        if isinstance(s, str):
            s = s.encode("utf-8")
        return gzip.compress(s, 6, mtime=0).hex()

    def gzip_decompress_hex(h):
        if isinstance(h, bytes):
            h = h.decode("ascii")
        try:
            return gzip.decompress(bytes.fromhex(h)).decode("utf-8")
        except Exception as exc:  # noqa: BLE001 - 需要把失败原因带到 Lua 侧
            print(f"[stub] gunzip 失败: {exc!r}")
            return None

    lua.globals().PY_JSON_LOADS = json_loads
    lua.globals().PY_GZIP_HEX = gzip_compress_hex
    lua.globals().PY_GUNZIP_HEX = gzip_decompress_hex


def check_syntax():
    lua = LuaRuntime(unpack_returned_tuples=True)
    loader = lua.eval(
        "function(s, n) local lf = loadstring or load; "
        "local f, e = lf(s, n); if f then return true, '' end; return false, tostring(e) end"
    )
    ok_all = True
    paths = syntax_files()
    for path in paths:
        full = os.path.join(ROOT, path)
        with open(full, encoding="utf-8") as fh:
            src = fh.read()
        ok, err = loader(src, "@" + path)
        if ok:
            print(f"[PASS] 语法 {path}")
        else:
            ok_all = False
            print(f"[FAIL] 语法 {path}\n       {err}")
    for path in OPTIONAL_SYNTAX_FILES:
        if path not in paths:
            print(f"[SKIP] 语法 {path}（未配置凭据，属正常状态）")
    return ok_all


def run_direction(label, w, h, force=None, no_rotation=False, start_rotation=0):
    print(f"\n{'=' * 62}\n== {label} {w}x{h}\n{'=' * 62}")
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(f"STUB_W = {w}; STUB_H = {h}; STUB_START_ROTATION = {start_rotation}")
    lua.execute(f"STUB_VERBOSE = {str(os.environ.get('STUB_VERBOSE') == '1').lower()}")
    if force:
        lua.execute(f'STUB_FORCE_LAYOUT = "{force}"')
    if no_rotation:
        lua.execute("STUB_NO_ROTATION = true")
    install_bridges(lua)
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
    for label, w, h, force, no_rotation, start_rotation in DIRECTIONS:
        ok = run_direction(label, w, h, force, no_rotation, start_rotation) and ok
    print()
    print("[PASS] 全部尺寸通过" if ok else "[FAIL] 存在失败项")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
