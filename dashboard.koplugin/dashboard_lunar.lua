--[[--
农历与二十四节气计算（纯算术实现，不依赖系统时区数据库）

数据表来源与校验：
  LUNAR_INFO 采用经过校正的版本（GNOME 扩展 / C# LunisolarCalendar 一系）。
  tools/lunar_check.py 已用 36 个正月初一基准（1996-2031）与 2026 年全部
  24 个节气日期做过交叉校验，全部吻合；对比另一版本的表，差异仅在
  1933 / 1978 / 1996 / 2057 / 2060 这五个年份的内部月序，不影响显示。

节气采用太阳视黄经求解（Meeus 低精度公式 + 牛顿迭代），
而不是传统的 sTermInfo 分钟偏移查表法——后者在 2026 年芒种会算错一天。

这里所有日期计算都用 Howard Hinnant 的 civil-from-days 算法，
只做整数运算，不受设备时区与夏令时影响。
--]]

local M = {}

local LUNAR_INFO = {
    0x04bd8, 0x04ae0, 0x0a570, 0x054d5, 0x0d260, 0x0d950, 0x16554, 0x056a0, 0x09ad0, 0x055d2,  -- 1900-1909
    0x04ae0, 0x0a5b6, 0x0a4d0, 0x0d250, 0x1d255, 0x0b540, 0x0d6a0, 0x0ada2, 0x095b0, 0x14977,  -- 1910-1919
    0x04970, 0x0a4b0, 0x0b4b5, 0x06a50, 0x06d40, 0x1ab54, 0x02b60, 0x09570, 0x052f2, 0x04970,  -- 1920-1929
    0x06566, 0x0d4a0, 0x0ea50, 0x16a95, 0x05ad0, 0x02b60, 0x186e3, 0x092e0, 0x1c8d7, 0x0c950,  -- 1930-1939
    0x0d4a0, 0x1d8a6, 0x0b550, 0x056a0, 0x1a5b4, 0x025d0, 0x092d0, 0x0d2b2, 0x0a950, 0x0b557,  -- 1940-1949
    0x06ca0, 0x0b550, 0x15355, 0x04da0, 0x0a5b0, 0x14573, 0x052b0, 0x0a9a8, 0x0e950, 0x06aa0,  -- 1950-1959
    0x0aea6, 0x0ab50, 0x04b60, 0x0aae4, 0x0a570, 0x05260, 0x0f263, 0x0d950, 0x05b57, 0x056a0,  -- 1960-1969
    0x096d0, 0x04dd5, 0x04ad0, 0x0a4d0, 0x0d4d4, 0x0d250, 0x0d558, 0x0b540, 0x0b6a0, 0x195a6,  -- 1970-1979
    0x095b0, 0x049b0, 0x0a974, 0x0a4b0, 0x0b27a, 0x06a50, 0x06d40, 0x0af46, 0x0ab60, 0x09570,  -- 1980-1989
    0x04af5, 0x04970, 0x064b0, 0x074a3, 0x0ea50, 0x06b58, 0x05ac0, 0x0ab60, 0x096d5, 0x092e0,  -- 1990-1999
    0x0c960, 0x0d954, 0x0d4a0, 0x0da50, 0x07552, 0x056a0, 0x0abb7, 0x025d0, 0x092d0, 0x0cab5,  -- 2000-2009
    0x0a950, 0x0b4a0, 0x0baa4, 0x0ad50, 0x055d9, 0x04ba0, 0x0a5b0, 0x15176, 0x052b0, 0x0a930,  -- 2010-2019
    0x07954, 0x06aa0, 0x0ad50, 0x05b52, 0x04b60, 0x0a6e6, 0x0a4e0, 0x0d260, 0x0ea65, 0x0d530,  -- 2020-2029
    0x05aa0, 0x076a3, 0x096d0, 0x04afb, 0x04ad0, 0x0a4d0, 0x1d0b6, 0x0d250, 0x0d520, 0x0dd45,  -- 2030-2039
    0x0b5a0, 0x056d0, 0x055b2, 0x049b0, 0x0a577, 0x0a4b0, 0x0aa50, 0x1b255, 0x06d20, 0x0ada0,  -- 2040-2049
    0x14b63, 0x09370, 0x049f8, 0x04970, 0x064b0, 0x168a6, 0x0ea50, 0x06aa0, 0x1a6c4, 0x0aae0,  -- 2050-2059
    0x092e0, 0x0d2e3, 0x0c960, 0x0d557, 0x0d4a0, 0x0da50, 0x05d55, 0x056a0, 0x0a6d0, 0x055d4,  -- 2060-2069
    0x052d0, 0x0a9b8, 0x0a950, 0x0b4a0, 0x0b6a6, 0x0ad50, 0x055a0, 0x0aba4, 0x0a5b0, 0x052b0,  -- 2070-2079
    0x0b273, 0x06930, 0x07337, 0x06aa0, 0x0ad50, 0x14b55, 0x04b60, 0x0a570, 0x054e4, 0x0d160,  -- 2080-2089
    0x0e968, 0x0d520, 0x0daa0, 0x16aa6, 0x056d0, 0x04ae0, 0x0a9d4, 0x0a2d0, 0x0d150, 0x0f252,  -- 2090-2099
    0x0d520,  -- 2100
}

local MONTH_NAMES = { "正", "二", "三", "四", "五", "六", "七", "八", "九", "十", "冬", "腊" }
local DAY_NAMES = {
    "初一", "初二", "初三", "初四", "初五", "初六", "初七", "初八", "初九", "初十",
    "十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九", "二十",
    "廿一", "廿二", "廿三", "廿四", "廿五", "廿六", "廿七", "廿八", "廿九", "三十",
}
local GAN = { "甲", "乙", "丙", "丁", "戊", "己", "庚", "辛", "壬", "癸" }
local ZHI = { "子", "丑", "寅", "卯", "辰", "巳", "午", "未", "申", "酉", "戌", "亥" }
local ZODIAC = { "鼠", "牛", "虎", "兔", "龙", "蛇", "马", "羊", "猴", "鸡", "狗", "猪" }
local TERM_NAMES = {
    "小寒", "大寒", "立春", "雨水", "惊蛰", "春分", "清明", "谷雨",
    "立夏", "小满", "芒种", "夏至", "小暑", "大暑", "立秋", "处暑",
    "白露", "秋分", "寒露", "霜降", "立冬", "小雪", "大雪", "冬至",
}
local WEEKDAY_NAMES = { "日", "一", "二", "三", "四", "五", "六" }

M.MONTH_NAMES = MONTH_NAMES
M.DAY_NAMES = DAY_NAMES
M.TERM_NAMES = TERM_NAMES
M.WEEKDAY_NAMES = WEEKDAY_NAMES

-- ------------------------------------------------------------------ 日历算术
-- 返回自 1970-01-01 起的天数（可为负），纯整数运算
function M.days_from_civil(y, m, d)
    if m <= 2 then y = y - 1 end
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local mp = (m + 9) % 12
    local doy = math.floor((153 * mp + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

function M.civil_from_days(z)
    z = z + 719468
    local era = math.floor(z / 146097)
    local doe = z - era * 146097
    local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524)
        - math.floor(doe / 146096)) / 365)
    local y = yoe + era * 400
    local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
    local mp = math.floor((5 * doy + 2) / 153)
    local d = doy - math.floor((153 * mp + 2) / 5) + 1
    local m
    if mp < 10 then m = mp + 3 else m = mp - 9 end
    if m <= 2 then y = y + 1 end
    return y, m, d
end

-- ------------------------------------------------------------------ 农历
local EPOCH_DAYS = M.days_from_civil(1900, 1, 31)  -- 农历 1900 年正月初一

local function info_of(year)
    -- 表中第 1 项对应 1900 年（Lua 数组从 1 开始，与常见实现的下标差 1）
    return LUNAR_INFO[year - 1899]
end

local function leap_month(year)
    return info_of(year) % 16
end

local function leap_days(year)
    if leap_month(year) == 0 then return 0 end
    return (math.floor(info_of(year) / 65536) % 2 == 1) and 30 or 29
end

local function month_days(year, month)
    local v = math.floor(info_of(year) / 2 ^ (16 - month)) % 2
    return v == 1 and 30 or 29
end

local function year_days(year)
    local total = 0
    for m = 1, 12 do
        total = total + month_days(year, m)
    end
    return total + leap_days(year)
end

--- 公历 -> 农历
-- @param y,m,d 公历年月日
-- @return table { year, month, day, leap }
function M.solar_to_lunar(y, m, d)
    local offset = M.days_from_civil(y, m, d) - EPOCH_DAYS
    local ly = 1900
    while ly < 2101 do
        local yd = year_days(ly)
        if offset < yd then break end
        offset = offset - yd
        ly = ly + 1
    end
    local lm = leap_month(ly)
    local month = 1
    local is_leap = false
    while month <= 12 do
        local md
        if is_leap and month == lm then
            md = leap_days(ly)
        else
            md = month_days(ly, month)
        end
        if offset < md then break end
        offset = offset - md
        if lm ~= 0 and month == lm and not is_leap then
            is_leap = true
        else
            if is_leap then is_leap = false end
            month = month + 1
        end
    end
    return { year = ly, month = month, day = offset + 1, leap = is_leap }
end

--- 农历文字，例如 “丙午年十月初三” / “丙午年闰六月初一”
function M.lunar_text(lunar)
    local gz = GAN[(lunar.year - 4) % 10 + 1] .. ZHI[(lunar.year - 4) % 12 + 1]
    local month_txt = (lunar.leap and "闰" or "") .. MONTH_NAMES[lunar.month] .. "月"
    return string.format("%s年%s%s", gz, month_txt, DAY_NAMES[lunar.day])
end

function M.zodiac(lunar)
    return ZODIAC[(lunar.year - 4) % 12 + 1]
end

function M.ganzhi_year(lunar)
    return GAN[(lunar.year - 4) % 10 + 1] .. ZHI[(lunar.year - 4) % 12 + 1]
end

-- ------------------------------------------------------------------ 二十四节气
local function jd_from_days(days, hour_frac)
    return days + 2440587.5 + (hour_frac or 0) / 24
end

local function apparent_solar_longitude(jd)
    local t = (jd - 2451545.0) / 36525.0
    local l0 = 280.46646 + 36000.76983 * t + 0.0003032 * t * t
    local m = math.rad(357.52911 + 35999.05029 * t - 0.0001537 * t * t)
    local c = (1.914602 - 0.004817 * t - 0.000014 * t * t) * math.sin(m)
        + (0.019993 - 0.000101 * t) * math.sin(2 * m)
        + 0.000289 * math.sin(3 * m)
    local true_long = l0 + c
    local omega = math.rad(125.04 - 1934.136 * t)
    return (true_long - 0.00569 - 0.00478 * math.sin(omega)) % 360
end

--- 第 k 个节气（0=小寒 … 23=冬至）的儒略日（UTC）
local function solar_term_jd(year, k)
    local target = (285 + 15 * k) % 360
    local jd = jd_from_days(M.days_from_civil(year, 1, 6)) + k * 15.22
    for _ = 1, 20 do
        local lon = apparent_solar_longitude(jd)
        local diff = (target - lon + 540) % 360 - 180
        jd = jd + diff / 0.9856473
        if math.abs(diff) < 1e-7 then break end
    end
    return jd
end

--- 节气在指定时区下的日期（返回 天序号、年、月、日）
local function solar_term_days(year, k, tz_minutes)
    local jd = solar_term_jd(year, k) + tz_minutes / 1440
    local days = math.floor(jd - 2440587.5)
    local y, m, d = M.civil_from_days(days)
    return days, y, m, d
end

--- 返回当日所处节气与下一节气
-- @return cur { name, days=已过天数(1 表示当天), index }, next { name, days=距今天数 }
function M.current_term(y, m, d, tz_minutes)
    tz_minutes = tz_minutes or 480
    local today = M.days_from_civil(y, m, d)
    local list = {}
    for yy = y - 1, y + 1 do
        for k = 0, 23 do
            local days = solar_term_days(yy, k, tz_minutes)
            list[#list + 1] = { days = days, name = TERM_NAMES[k + 1] }
        end
    end
    table.sort(list, function(a, b) return a.days < b.days end)
    local cur, nxt
    for i = 1, #list do
        if list[i].days <= today then
            cur = list[i]
            nxt = list[i + 1]
        end
    end
    if not cur then
        cur = list[1]
    end
    return {
        name = cur.name,
        elapsed = today - cur.days + 1,
        is_today = (cur.days == today),
    }, nxt and {
        name = nxt.name,
        in_days = nxt.days - today,
    } or nil
end

return M
