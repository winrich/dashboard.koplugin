# -*- coding: utf-8 -*-
"""用内嵌 Lua 运行时校验 Lua 侧实现。

两部分：
  1) 语法检查：对每个 .lua 文件做 loadfile（只编译不执行）
  2) 算法交叉校验：把 dashboard_lunar.lua 的计算结果与已通过基准校验的
     Python 参考实现逐日比对（农历日期 + 节气归属 + 距下一节气天数）
"""

import datetime
import os
import sys

from lupa import LuaRuntime

import lunar_check as ref

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PLUGIN = os.path.join(ROOT, "dashboard.koplugin")

LUA_FILES = ["main.lua", "_meta.lua", "dashboard_lunar.lua", "dashboard_cities.lua",
             "dashboard_qweather.lua", "dashboard_openmeteo.lua",
             "dashboard_config.lua", "dashboard_config.local.lua"]


def syntax_check(lua):
    print("=========== 1) 语法检查 ===========")
    ok_all = True
    for name in LUA_FILES:
        path = os.path.join(PLUGIN, name).replace("\\", "/")
        code = lua.execute(
            'local f, err = loadfile([==[%s]==]); if f then return "OK", "" else return "FAIL", err end' % path
        )
        status, err = code[0], code[1]
        print(f"[{status}] {name}" + (f"  -> {err}" if err else ""))
        if status != "OK":
            ok_all = False
    return ok_all


def load_lunar(lua):
    path = os.path.join(PLUGIN, "dashboard_lunar.lua").replace("\\", "/")
    lua.execute('LUNAR = assert(loadfile([==[%s]==]))()' % path)
    return lua.globals().LUNAR


MONTH_NAMES = ref.MONTH_NAMES
DAY_NAMES = ref.DAY_NAMES
TERM_NAMES = ref.TERM_NAMES
EPOCH = datetime.date(1970, 1, 1)

_term_cache = {}


def term_days_of_year(year, tz_minutes):
    key = (year, tz_minutes)
    if key not in _term_cache:
        items = []
        for k in range(24):
            dt = ref.solar_term_local_datetime(year, k, tz_hours=tz_minutes / 60.0)
            items.append(((dt.date() - EPOCH).days, TERM_NAMES[k]))
        _term_cache[key] = items
    return _term_cache[key]


def current_term_py(y, m, d, tz_minutes=480):
    today = (datetime.date(y, m, d) - EPOCH).days
    items = []
    for yy in (y - 1, y, y + 1):
        items.extend(term_days_of_year(yy, tz_minutes))
    items.sort()
    cur = nxt = None
    for i, (days, name) in enumerate(items):
        if days <= today:
            cur = (days, name)
            nxt = items[i + 1] if i + 1 < len(items) else None
    if cur is None:
        cur = items[0]
    return (
        cur[1],
        today - cur[0] + 1,
        cur[0] == today,
        nxt[1] if nxt else None,
        (nxt[0] - today) if nxt else None,
    )


def algo_check(lua):
    print("\n=========== 2) 算法交叉校验 ===========")
    M = load_lunar(lua)

    # 2.1 农历逐日（2020-01-01 ~ 2035-12-31，每 3 天）
    start = datetime.date(2020, 1, 1)
    end = datetime.date(2035, 12, 31)
    bad = []
    n = 0
    d = start
    while d <= end:
        got = M.solar_to_lunar(d.year, d.month, d.day)
        exp = ref.solar_to_lunar(d, ref.LUNAR_B)
        n += 1
        gy, gm, gd = int(got["year"]), int(got["month"]), int(got["day"])
        gl = bool(got["leap"])
        if (gy, gm, gd, gl) != (exp[0], exp[1], exp[2], exp[3]):
            bad.append(f"{d}: 得到 {gy}-{gm}-{gd}{'(闰)' if gl else ''}, 期望 {exp[0]}-{exp[1]}-{exp[2]}")
        d += datetime.timedelta(days=3)
    if bad:
        print(f"[FAIL] 农历 {len(bad)}/{n} 处不符，前 5 条：")
        for b in bad[:5]:
            print("   ", b)
    else:
        print(f"[PASS] 农历逐日比对 {n} 个日期全部一致（2020-2035，步长 3 天）")

    # 2.2 节气归属（2021-01-01 ~ 2034-12-31，每 15 天，东八区）
    bad2 = []
    n2 = 0
    d = datetime.date(2021, 1, 1)
    while d <= datetime.date(2034, 12, 31):
        cur, nxt = M.current_term(d.year, d.month, d.day, 480)
        exp = current_term_py(d.year, d.month, d.day, 480)
        n2 += 1
        got = (cur["name"], int(cur["elapsed"]), bool(cur["is_today"]),
               nxt["name"] if nxt else None, int(nxt["in_days"]) if nxt else None)
        if got != exp:
            bad2.append(f"{d}: 得到 {got}, 期望 {exp}")
        d += datetime.timedelta(days=15)
    if bad2:
        print(f"[FAIL] 节气 {len(bad2)}/{n2} 处不符，前 5 条：")
        for b in bad2[:5]:
            print("   ", b)
    else:
        print(f"[PASS] 节气归属比对 {n2} 个日期全部一致（2021-2034，步长 15 天）")

    # 2.3 关键单点
    print("\n---------- 单点抽查 ----------")
    y, m, dd, lp = M.solar_to_lunar(2026, 11, 11)["year"], M.solar_to_lunar(2026, 11, 11)["month"], \
        M.solar_to_lunar(2026, 11, 11)["day"], M.solar_to_lunar(2026, 11, 11)["leap"]
    text = M.lunar_text(M.solar_to_lunar(2026, 11, 11))
    print(f"2026-11-11 -> 农历 {int(y)}年{int(m)}月{int(dd)}日  {text}  闰={bool(lp)}")
    cur, nxt = M.current_term(2026, 11, 11, 480)
    print(f"节气 -> {cur['name']} 第{int(cur['elapsed'])}天；下一节气 {nxt['name']} 还有 {int(nxt['in_days'])} 天")
    z = M.zodiac(M.solar_to_lunar(2026, 11, 11))
    gz = M.ganzhi_year(M.solar_to_lunar(2026, 11, 11))
    print(f"干支/生肖 -> {gz}年 {z}")

    return (not bad) and (not bad2)


if __name__ == "__main__":
    runtime = LuaRuntime(unpack_returned_tuples=True)
    ok1 = syntax_check(runtime)
    ok2 = algo_check(runtime)
    print("\n================ 结论 ================")
    print("语法检查:", "通过" if ok1 else "未通过")
    print("算法校验:", "通过" if ok2 else "未通过")
    sys.exit(0 if (ok1 and ok2) else 1)
