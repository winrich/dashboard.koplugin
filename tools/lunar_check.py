# -*- coding: utf-8 -*-
"""农历/节气算法的交叉校验工具。

目的：不同来源的 lunarInfo 表在个别年份存在分歧（1996、1978、2057 等），
本脚本用权威基准日期同时校验两个版本，选出与实际万年历一致的那一份，
再据此生成 Lua 版本的数据表。

基准来源：
  1) 2026-11-11 应为 农历丙午年十月初三（多个万年历站点一致）
  2) 正月初一公历日期：1996-02-19 / 2008-02-07 / 2020-01-25 / 2024-02-10
     / 2025-01-29 / 2026-02-17 / 2027-02-06 / 2028-01-26 / 2029-02-13
     / 2030-02-03 / 2031-01-23
  3) 2026 年 24 节气日期（便民查询网 jieqi.bmcx.com）
"""

import datetime
import math

# ---------------------------------------------------------------- 版本 A
# jjonline/calendar.js 一系（中文站点使用最广）
LUNAR_A = [
    0x04bd8, 0x04ae0, 0x0a570, 0x054d5, 0x0d260, 0x0d950, 0x16554, 0x056a0, 0x09ad0, 0x055d2,  # 1900-1909
    0x04ae0, 0x0a5b6, 0x0a4d0, 0x0d250, 0x1d255, 0x0b540, 0x0d6a0, 0x0ada2, 0x095b0, 0x14977,  # 1910-1919
    0x04970, 0x0a4b0, 0x0b4b5, 0x06a50, 0x06d40, 0x1ab54, 0x02b60, 0x09570, 0x052f2, 0x04970,  # 1920-1929
    0x06566, 0x0d4a0, 0x0ea50, 0x06e95, 0x05ad0, 0x02b60, 0x186e3, 0x092e0, 0x1c8d7, 0x0c950,  # 1930-1939
    0x0d4a0, 0x1d8a6, 0x0b550, 0x056a0, 0x1a5b4, 0x025d0, 0x092d0, 0x0d2b2, 0x0a950, 0x0b557,  # 1940-1949
    0x06ca0, 0x0b550, 0x15355, 0x04da0, 0x0a5b0, 0x14573, 0x052b0, 0x0a9a8, 0x0e950, 0x06aa0,  # 1950-1959
    0x0aea6, 0x0ab50, 0x04b60, 0x0aae4, 0x0a570, 0x05260, 0x0f263, 0x0d950, 0x05b57, 0x056a0,  # 1960-1969
    0x096d0, 0x04dd5, 0x04ad0, 0x0a4d0, 0x0d4d4, 0x0d250, 0x0d558, 0x0b540, 0x0b5a0, 0x195a6,  # 1970-1979
    0x095b0, 0x049b0, 0x0a974, 0x0a4b0, 0x0b27a, 0x06a50, 0x06d40, 0x0af46, 0x0ab60, 0x09570,  # 1980-1989
    0x04af5, 0x04970, 0x064b0, 0x074a3, 0x0ea50, 0x06b58, 0x055c0, 0x0ab60, 0x096d5, 0x092e0,  # 1990-1999
    0x0c960, 0x0d954, 0x0d4a0, 0x0da50, 0x07552, 0x056a0, 0x0abb7, 0x025d0, 0x092d0, 0x0cab5,  # 2000-2009
    0x0a950, 0x0b4a0, 0x0baa4, 0x0ad50, 0x055d9, 0x04ba0, 0x0a5b0, 0x15176, 0x052b0, 0x0a930,  # 2010-2019
    0x07954, 0x06aa0, 0x0ad50, 0x05b52, 0x04b60, 0x0a6e6, 0x0a4e0, 0x0d260, 0x0ea65, 0x0d530,  # 2020-2029
    0x05aa0, 0x076a3, 0x096d0, 0x04afb, 0x04ad0, 0x0a4d0, 0x1d0b6, 0x0d250, 0x0d520, 0x0dd45,  # 2030-2039
    0x0b5a0, 0x056d0, 0x055b2, 0x049b0, 0x0a577, 0x0a4b0, 0x0aa50, 0x1b255, 0x06d20, 0x0ada0,  # 2040-2049
    0x14b63, 0x09370, 0x049f8, 0x04970, 0x064b0, 0x168a6, 0x0ea50, 0x06b20, 0x1a6c4, 0x0aae0,  # 2050-2059
    0x0a2e0, 0x0d2e3, 0x0c960, 0x0d557, 0x0d4a0, 0x0da50, 0x05d55, 0x056a0, 0x0a6d0, 0x055d4,  # 2060-2069
    0x052d0, 0x0a9b8, 0x0a950, 0x0b4a0, 0x0b6a6, 0x0ad50, 0x055a0, 0x0aba4, 0x0a5b0, 0x052b0,  # 2070-2079
    0x0b273, 0x06930, 0x07337, 0x06aa0, 0x0ad50, 0x14b55, 0x04b60, 0x0a570, 0x054e4, 0x0d160,  # 2080-2089
    0x0e968, 0x0d520, 0x0daa0, 0x16aa6, 0x056d0, 0x04ae0, 0x0a9d4, 0x0a2d0, 0x0d150, 0x0f252,  # 2090-2099
    0x0d520,  # 2100
]

# ---------------------------------------------------------------- 版本 B
# GNOME 扩展 / C# LunisolarCalendar 一系（自 1933、1978、1996、2057 等年份起不同）
LUNAR_B = [
    0x04bd8, 0x04ae0, 0x0a570, 0x054d5, 0x0d260, 0x0d950, 0x16554, 0x056a0, 0x09ad0, 0x055d2,
    0x04ae0, 0x0a5b6, 0x0a4d0, 0x0d250, 0x1d255, 0x0b540, 0x0d6a0, 0x0ada2, 0x095b0, 0x14977,
    0x04970, 0x0a4b0, 0x0b4b5, 0x06a50, 0x06d40, 0x1ab54, 0x02b60, 0x09570, 0x052f2, 0x04970,
    0x06566, 0x0d4a0, 0x0ea50, 0x16a95, 0x05ad0, 0x02b60, 0x186e3, 0x092e0, 0x1c8d7, 0x0c950,
    0x0d4a0, 0x1d8a6, 0x0b550, 0x056a0, 0x1a5b4, 0x025d0, 0x092d0, 0x0d2b2, 0x0a950, 0x0b557,
    0x06ca0, 0x0b550, 0x15355, 0x04da0, 0x0a5b0, 0x14573, 0x052b0, 0x0a9a8, 0x0e950, 0x06aa0,
    0x0aea6, 0x0ab50, 0x04b60, 0x0aae4, 0x0a570, 0x05260, 0x0f263, 0x0d950, 0x05b57, 0x056a0,
    0x096d0, 0x04dd5, 0x04ad0, 0x0a4d0, 0x0d4d4, 0x0d250, 0x0d558, 0x0b540, 0x0b6a0, 0x195a6,
    0x095b0, 0x049b0, 0x0a974, 0x0a4b0, 0x0b27a, 0x06a50, 0x06d40, 0x0af46, 0x0ab60, 0x09570,
    0x04af5, 0x04970, 0x064b0, 0x074a3, 0x0ea50, 0x06b58, 0x05ac0, 0x0ab60, 0x096d5, 0x092e0,
    0x0c960, 0x0d954, 0x0d4a0, 0x0da50, 0x07552, 0x056a0, 0x0abb7, 0x025d0, 0x092d0, 0x0cab5,
    0x0a950, 0x0b4a0, 0x0baa4, 0x0ad50, 0x055d9, 0x04ba0, 0x0a5b0, 0x15176, 0x052b0, 0x0a930,
    0x07954, 0x06aa0, 0x0ad50, 0x05b52, 0x04b60, 0x0a6e6, 0x0a4e0, 0x0d260, 0x0ea65, 0x0d530,
    0x05aa0, 0x076a3, 0x096d0, 0x04afb, 0x04ad0, 0x0a4d0, 0x1d0b6, 0x0d250, 0x0d520, 0x0dd45,
    0x0b5a0, 0x056d0, 0x055b2, 0x049b0, 0x0a577, 0x0a4b0, 0x0aa50, 0x1b255, 0x06d20, 0x0ada0,
    0x14b63, 0x09370, 0x049f8, 0x04970, 0x064b0, 0x168a6, 0x0ea50, 0x06aa0, 0x1a6c4, 0x0aae0,
    0x092e0, 0x0d2e3, 0x0c960, 0x0d557, 0x0d4a0, 0x0da50, 0x05d55, 0x056a0, 0x0a6d0, 0x055d4,
    0x052d0, 0x0a9b8, 0x0a950, 0x0b4a0, 0x0b6a6, 0x0ad50, 0x055a0, 0x0aba4, 0x0a5b0, 0x052b0,
    0x0b273, 0x06930, 0x07337, 0x06aa0, 0x0ad50, 0x14b55, 0x04b60, 0x0a570, 0x054e4, 0x0d160,
    0x0e968, 0x0d520, 0x0daa0, 0x16aa6, 0x056d0, 0x04ae0, 0x0a9d4, 0x0a2d0, 0x0d150, 0x0f252,
    0x0d520,
]

S_TERM = [0, 21208, 42467, 63836, 85337, 107014, 128867, 150921, 173149, 195551, 218072,
          240693, 263343, 285989, 308563, 331033, 353350, 375494, 397447, 419210, 440795,
          462224, 483532, 504758]

TERM_NAMES = ["小寒", "大寒", "立春", "雨水", "惊蛰", "春分", "清明", "谷雨", "立夏", "小满",
              "芒种", "夏至", "小暑", "大暑", "立秋", "处暑", "白露", "秋分", "寒露", "霜降",
              "立冬", "小雪", "大雪", "冬至"]

MONTH_NAMES = ["正", "二", "三", "四", "五", "六", "七", "八", "九", "十", "冬", "腊"]
DAY_NAMES = ["初一", "初二", "初三", "初四", "初五", "初六", "初七", "初八", "初九", "初十",
             "十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九", "二十",
             "廿一", "廿二", "廿三", "廿四", "廿五", "廿六", "廿七", "廿八", "廿九", "三十"]
GAN = "甲乙丙丁戊己庚辛壬癸"
ZHI = "子丑寅卯辰巳午未申酉戌亥"

EPOCH = datetime.date(1900, 1, 31)  # 农历 1900 年正月初一


def leap_month(year, table):
    return table[year - 1900] & 0xF


def leap_days(year, table):
    if leap_month(year, table):
        return 30 if (table[year - 1900] & 0x10000) else 29
    return 0


def month_days(year, month, table):
    return 30 if (table[year - 1900] & (0x10000 >> month)) else 29


def year_days(year, table):
    total = 0
    info = table[year - 1900]
    for m in range(1, 13):
        total += 30 if (info & (0x10000 >> m)) else 29
    return total + leap_days(year, table)


def solar_to_lunar(d, table):
    offset = (d - EPOCH).days
    year = 1900
    while year < 2101:
        yd = year_days(year, table)
        if offset < yd:
            break
        offset -= yd
        year += 1
    lm = leap_month(year, table)
    month = 1
    is_leap = False
    while month <= 12:
        if is_leap and month == lm:
            md = leap_days(year, table)
        else:
            md = month_days(year, month, table)
        if offset < md:
            break
        offset -= md
        if lm and month == lm and not is_leap:
            is_leap = True
        else:
            if is_leap:
                is_leap = False
            month += 1
    day = offset + 1
    return year, month, day, is_leap


def spring_festival(year, table):
    """返回该农历年正月初一对应的公历日期。"""
    days = 0
    for y in range(1900, year):
        days += year_days(y, table)
    return EPOCH + datetime.timedelta(days=days)


def solar_term_day(year, n):
    base = datetime.datetime(1900, 1, 6, 2, 5, tzinfo=datetime.timezone.utc)
    base_ms = base.timestamp() * 1000.0
    ms = 31556925974.7 * (year - 1900) + S_TERM[n] * 60000.0 + base_ms
    dt = datetime.datetime.fromtimestamp(ms / 1000.0, tz=datetime.timezone.utc)
    return dt.day


# ------------------------------------------------ 高精度节气：太阳视黄经求解
def jd_from_datetime(dt):
    """UTC datetime -> 儒略日"""
    y, m = dt.year, dt.month
    day = dt.day + (dt.hour + dt.minute / 60.0 + dt.second / 3600.0) / 24.0
    if m <= 2:
        y -= 1
        m += 12
    a = y // 100
    b = 2 - a + a // 4
    return int(365.25 * (y + 4716)) + int(30.6001 * (m + 1)) + day + b - 1524.5


def jd_to_datetime(jd):
    """儒略日 -> UTC datetime（Meeus 第 7 章）"""
    jd += 0.5
    z = int(jd)
    f = jd - z
    if z < 2299161:
        a = z
    else:
        alpha = int((z - 1867216.25) / 36524.25)
        a = z + 1 + alpha - alpha // 4
    b = a + 1524
    c = int((b - 122.1) / 365.25)
    d = int(365.25 * c)
    e = int((b - d) / 30.6001)
    day = b - d - int(30.6001 * e) + f
    month = e - 1 if e < 14 else e - 13
    year = c - 4716 if month > 2 else c - 4715
    d_int = int(day)
    return datetime.datetime(year, month, d_int) + datetime.timedelta(days=day - d_int)


def apparent_solar_longitude(jd):
    """太阳视黄经（度），Meeus 低精度公式，误差约 0.01 度"""
    t = (jd - 2451545.0) / 36525.0
    l0 = 280.46646 + 36000.76983 * t + 0.0003032 * t * t
    m = math.radians(357.52911 + 35999.05029 * t - 0.0001537 * t * t)
    c = ((1.914602 - 0.004817 * t - 0.000014 * t * t) * math.sin(m)
         + (0.019993 - 0.000101 * t) * math.sin(2 * m)
         + 0.000289 * math.sin(3 * m))
    true_long = l0 + c
    omega = math.radians(125.04 - 1934.136 * t)
    return (true_long - 0.00569 - 0.00478 * math.sin(omega)) % 360.0


def solar_term_jd(year, k):
    """返回第 k 个节气（0=小寒 … 23=冬至）的儒略日（UTC）"""
    target = (285.0 + 15.0 * k) % 360.0
    jd = jd_from_datetime(datetime.datetime(year, 1, 6)) + k * 15.22
    for _ in range(20):
        diff = (target - apparent_solar_longitude(jd) + 540.0) % 360.0 - 180.0
        jd += diff / 0.9856473
        if abs(diff) < 1e-7:
            break
    return jd


def solar_term_local_datetime(year, k, tz_hours=8):
    """节气在北京时间（UTC+8）下的日期时间"""
    return jd_to_datetime(solar_term_jd(year, k)) + datetime.timedelta(hours=tz_hours)


def check_table(name, table):
    print(f"\n=========== {name} ===========")
    ok = True

    # 1) 今天：2026-11-11 → 丙午年 十月初三
    y, m, d, lp = solar_to_lunar(datetime.date(2026, 11, 11), table)
    got = f"{y}年{'闰' if lp else ''}{MONTH_NAMES[m - 1]}月{DAY_NAMES[d - 1]}"
    exp = "2026年十月" + DAY_NAMES[2]
    flag = "PASS" if got == exp else "FAIL"
    if flag == "FAIL":
        ok = False
    print(f"[{flag}] 2026-11-11 -> {got}   (期望 {exp})")
    gz = GAN[(y - 4) % 10] + ZHI[(y - 4) % 12]
    print(f"       干支 {gz}（期望 丙午）" + ("" if gz == "丙午" else "  <-- FAIL"))

    # 2) 正月初一基准
    anchors = {
        1996: (2, 19), 1997: (2, 7), 1998: (1, 28), 1999: (2, 16), 2000: (2, 5),
        2001: (1, 24), 2002: (2, 12), 2003: (2, 1), 2004: (1, 22), 2005: (2, 9),
        2006: (1, 29), 2007: (2, 18), 2008: (2, 7), 2009: (1, 26), 2010: (2, 14),
        2011: (2, 3), 2012: (1, 23), 2013: (2, 10), 2014: (1, 31), 2015: (2, 19),
        2016: (2, 8), 2017: (1, 28), 2018: (2, 16), 2019: (2, 5), 2020: (1, 25),
        2021: (2, 12), 2022: (2, 1), 2023: (1, 22), 2024: (2, 10), 2025: (1, 29),
        2026: (2, 17), 2027: (2, 6), 2028: (1, 26), 2029: (2, 13), 2030: (2, 3),
        2031: (1, 23),
    }
    bad = []
    for yr, (mm, dd) in anchors.items():
        actual = spring_festival(yr, table)
        if (actual.month, actual.day) != (mm, dd):
            bad.append(f"{yr}:得到{actual.month}-{actual.day},应为{mm}-{dd}")
    if bad:
        ok = False
        print(f"[FAIL] 正月初一 {len(bad)} 处不符: " + "; ".join(bad))
    else:
        print(f"[PASS] 正月初一 {len(anchors)} 个年份全部吻合")

    # 3) 2026 年节气（高精度求解 vs 权威表）
    expect_terms = {0: 5, 1: 20, 2: 4, 3: 18, 4: 5, 5: 20, 6: 5, 7: 20, 8: 5, 9: 21, 10: 5,
                    11: 21, 12: 7, 13: 23, 14: 7, 15: 23, 16: 7, 17: 23, 18: 8, 19: 23,
                    20: 7, 21: 22, 22: 7, 23: 22}
    new_bad = []
    for n in range(24):
        dt = solar_term_local_datetime(2026, n)
        if dt.day != expect_terms[n]:
            new_bad.append(f"{TERM_NAMES[n]}得{dt.month}-{dt.day},应{expect_terms[n]}")
    if new_bad:
        ok = False
        print(f"[FAIL] 高精度节气 {len(new_bad)} 处不符: " + "; ".join(new_bad))
    else:
        print("[PASS] 2026 年 24 节气（高精度求解）全部吻合")
    old_bad = [TERM_NAMES[n] for n in range(24) if solar_term_day(2026, n) != expect_terms[n]]
    print(f"       对照：旧 sTermInfo 查表法错 {len(old_bad)} 处 -> {old_bad}")

    # 4) 闰月抽样：2020 闰四月、2023 闰二月、2025 闰六月
    leap_expect = {2020: 4, 2023: 2, 2025: 6}
    lz = [f"{y}年闰{leap_month(y, table)}月,应闰{lm}月"
          for y, lm in leap_expect.items() if leap_month(y, table) != lm]
    if lz:
        ok = False
        print("[FAIL] 闰月不符: " + "; ".join(lz))
    else:
        print("[PASS] 2020/2023/2025 闰月吻合")

    print(f"--- {name} 结论: {'全部通过' if ok else '存在不符，不可用'}")
    return ok


if __name__ == "__main__":
    a = check_table("版本 A（jjonline/calendar.js 系）", LUNAR_A)
    b = check_table("版本 B（GNOME / C# 系）", LUNAR_B)
    print("\n================ 最终结论 ================")
    if a and not b:
        print("采用 版本 A")
    elif b and not a:
        print("采用 版本 B")
    elif a and b:
        print("两版本在基准上均通过；需按下文逐年差异裁量")
    else:
        print("两版本均未通过，需重新取表")

    diff = [(1900 + i, hex(LUNAR_A[i]), hex(LUNAR_B[i]))
            for i in range(201) if LUNAR_A[i] != LUNAR_B[i]]
    print(f"\n两表差异 {len(diff)} 处:")
    for y, x, y2 in diff:
        print(f"  {y}: A={x} B={y2}  (闰{leap_month(y, LUNAR_A)}月/闰{leap_month(y, LUNAR_B)}月)")
