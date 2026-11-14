# -*- coding: utf-8 -*-
"""用内嵌 Lua 运行时校验 Lua 侧实现。

两部分：
  1) 语法检查：对每个 .lua 文件做 loadfile（只编译不执行）
  2) 算法交叉校验：把 dashboard_lunar.lua 的计算结果与已通过基准校验的
     Python 参考实现逐日比对（农历日期 + 节气归属 + 距下一节气天数）
"""

import datetime
import os
import re
import sys

from lupa import LuaRuntime

import lunar_check as ref

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PLUGIN = os.path.join(ROOT, "dashboard.koplugin")

# 必须随仓库分发的文件，缺一个就是错误
LUA_FILES = ["main.lua", "_meta.lua", "dashboard_lunar.lua", "dashboard_cities.lua",
             "dashboard_qweather.lua", "dashboard_openmeteo.lua",
             "dashboard_i18n.lua", "dashboard_agenda.lua", "dashboard_config.lua",
             "dashboard_geo.lua"]

# 内含真实凭据，被 .gitignore 排除。git clone 下来没有它是**正常状态**——插件会
# 自动降级到 Open-Meteo。所以这里只在文件存在时才检查，缺失只提示、不算失败，
# 否则别人照 README 跑第一条命令就撞 FileNotFoundError。
OPTIONAL_LUA_FILES = ["dashboard_config.local.lua"]


def lua_files():
    """实际要检查的文件名：必选的全在，可选的仅在存在时加入。"""
    names = list(LUA_FILES)
    for name in OPTIONAL_LUA_FILES:
        if os.path.exists(os.path.join(PLUGIN, name)):
            names.append(name)
    return names


# 这些字段在真机上可能是 ffi cdata：Blitbuffer 的 COLOR_* 都是 Color8/ColorRGB16 等
# （ffi/blitbuffer.lua:161 `Color8 = ffi.typeof("Color8")`）。LuaJIT 里 cdata 与 nil
# 比较不走「类型不同直接返回 false」，而是调 ColorRGB32_mt.__eq，它第一行就是
# color:getColorRGB32()，参数为 nil 立刻崩。真机 crash.log 实测过一次：
#   ffi/blitbuffer.lua:601: attempt to index local 'color' (a nil value)
#   <- main.lua:1079 stretchGaps <- build <- createRoot <- refreshLayout <- open
# 桩件（PUC Lua + 数字颜色）复现不了，所以只能用静态检查兜住。
CDATA_FIELDS = ("color", "fgcolor", "bgcolor", "background", "line_color")
NIL_CMP = re.compile(r"\.(%s)\s*[=~]=\s*nil" % "|".join(CDATA_FIELDS))


def lint_cdata_compare():
    print("=========== 0) 颜色字段判空写法 ===========")
    bad = []
    for name in lua_files():
        path = os.path.join(PLUGIN, name)
        with open(path, encoding="utf-8") as f:
            for no, line in enumerate(f, 1):
                code = line.split("--", 1)[0]  # 去掉行尾注释，避免注释里的示例被误判
                if NIL_CMP.search(code):
                    bad.append("%s:%d  %s" % (name, no, line.strip()))
    if bad:
        print("[FAIL] 颜色字段不能直接与 nil 比较：真机上会触发 cdata __eq 崩溃，"
              "判空请改用显式标记或 rawequal")
        for b in bad:
            print("   ", b)
        return False
    print("[PASS] 未发现颜色字段与 nil 直接比较")
    return True


def syntax_check(lua):
    print("=========== 1) 语法检查 ===========")
    ok_all = True
    files = lua_files()
    for name in files:
        path = os.path.join(PLUGIN, name).replace("\\", "/")
        code = lua.execute(
            'local f, err = loadfile([==[%s]==]); if f then return "OK", "" else return "FAIL", err end' % path
        )
        status, err = code[0], code[1]
        print(f"[{status}] {name}" + (f"  -> {err}" if err else ""))
        if status != "OK":
            ok_all = False
    for name in OPTIONAL_LUA_FILES:
        if name not in files:
            print(f"[SKIP] {name}（未配置凭据，属正常状态；插件会降级到 Open-Meteo）")
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


def city_check(lua):
    """城市/时区数据的一致性校验。

    这些错误在真机上的表现都是「静默错误」——菜单照常显示、看板照常出图，只是
    城市列表里少一个、或者时区悄悄回落到北京时间，肉眼很难发现。所以必须在
    改数据时就用工具拦住：

      1. 城市 tz 必须能在 timezones 里查到（查不到 getTz 会回落成北京时间）
      2. 城市 name 必须唯一（它是设置里 dashboard_city 的键）
      3. group 必须在分组表里存在，否则该城市在菜单里永远不显示
      4. 海外城市必须带 tz + global，国内城市不能带 tz（选城市不该覆盖用户选的时区）
      5. 夏令时规则抽查几个已知的切换前后时刻
    """
    print("=========== 3) 城市与时区数据 ===========")
    path = os.path.join(PLUGIN, "dashboard_cities.lua").replace("\\", "/")
    M = lua.execute('return dofile([==[%s]==])' % path)

    cities = list(M.cities.values())
    zones = list(M.timezones.values())
    city_groups = {g["key"] for g in M.city_groups.values()}
    tz_groups = {g["key"] for g in M.tz_groups.values()}
    by_iana = {z["iana"]: z for z in zones}

    bad = []
    names = set()
    for c in cities:
        name = c["name"]
        if name in names:
            bad.append(f"城市名重复：{name}（它是设置键，必须唯一）")
        names.add(name)
        for field in ("en", "group", "lat", "lon"):
            if c[field] is None:
                bad.append(f"{name} 缺少字段 {field}")
        if not (-90 <= c["lat"] <= 90 and -180 <= c["lon"] <= 180):
            bad.append(f"{name} 坐标越界：{c['lat']},{c['lon']}")
        if c["group"] not in city_groups:
            bad.append(f"{name} 的 group「{c['group']}」不在 city_groups 里，菜单里不会出现")
        tz = c["tz"]
        if tz is not None:
            if tz not in by_iana:
                bad.append(f"{name} 的 tz「{tz}」不在 timezones 里，getTz 会回落到北京时间")
            if not c["global"]:
                bad.append(f"{name} 有 tz 却没标 global，天气仍会去问和风")
        else:
            if c["global"]:
                bad.append(f"{name} 标了 global 却没有 tz，时区无法自动跟随")

    for z in zones:
        if z["group"] not in tz_groups:
            bad.append(f"时区 {z['iana']} 的 group「{z['group']}」不在 tz_groups 里")
        if z["dst"] is not None and z["dst"] not in ("EU", "US", "AU", "NZ", "CL"):
            bad.append(f"时区 {z['iana']} 的 dst 规则「{z['dst']}」未定义")
        if not (-720 <= z["offset"] <= 780):
            bad.append(f"时区 {z['iana']} 偏移越界：{z['offset']}")

    if bad:
        print(f"[FAIL] 城市/时区数据 {len(bad)} 处问题：")
        for b in bad[:10]:
            print("   ", b)
    else:
        overseas = sum(1 for c in cities if c["tz"] is not None)
        print(f"[PASS] {len(cities)} 个城市（海外 {overseas}）、{len(zones)} 个时区，字段与引用全部自洽")

    # 夏令时抽查：挑切换前后的典型时刻，错了就是真机上差一小时
    cases = [
        ("Europe/London", "2026-01-15", 0), ("Europe/London", "2026-07-01", 60),
        ("America/New_York", "2026-01-15", -300), ("America/New_York", "2026-07-01", -240),
        ("Australia/Sydney", "2026-01-15", 660), ("Australia/Sydney", "2026-07-01", 600),
        ("Pacific/Auckland", "2026-01-15", 780), ("Pacific/Auckland", "2026-07-01", 720),
        ("America/Santiago", "2026-01-15", -180), ("America/Santiago", "2026-07-01", -240),
        ("Asia/Tokyo", "2026-07-01", 540), ("Asia/Shanghai", "2026-07-01", 480),
    ]
    bad2 = []
    for iana, day, expect in cases:
        z = by_iana.get(iana)
        if not z:
            bad2.append(f"{iana} 不在时区表里")
            continue
        ts = int(datetime.datetime.strptime(day, "%Y-%m-%d")
                 .replace(tzinfo=datetime.timezone.utc).timestamp())
        got = int(M.offsetAt(z, ts))
        if got != expect:
            bad2.append(f"{iana} {day}: 得到 {got} 分钟，期望 {expect}")
    if bad2:
        print(f"[FAIL] 夏令时 {len(bad2)} 处不符：")
        for b in bad2:
            print("   ", b)
    else:
        print(f"[PASS] 夏令时抽查 {len(cases)} 个时刻全部正确")

    return not bad and not bad2


if __name__ == "__main__":
    runtime = LuaRuntime(unpack_returned_tuples=True)
    ok0 = lint_cdata_compare()
    ok1 = syntax_check(runtime)
    ok2 = algo_check(runtime)
    ok3 = city_check(runtime)
    print("\n================ 结论 ================")
    print("cdata 判空:", "通过" if ok0 else "未通过")
    print("语法检查:", "通过" if ok1 else "未通过")
    print("算法校验:", "通过" if ok2 else "未通过")
    print("城市时区:", "通过" if ok3 else "未通过")
    sys.exit(0 if (ok0 and ok1 and ok2 and ok3) else 1)
