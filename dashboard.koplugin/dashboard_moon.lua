--[[
桌面看板的月相计算（v2.45）

为什么要自己算：和风天气的每日预报里有 astro.moonPhase，但降级源 Open-Meteo
完全不给月相。为了让「日月」组件在两种数据源下表现一致，本地按 Meeus
《Astronomical Algorithms》的日月黄经级数算「月亮相对太阳的黄经差」
（elongation），再由它推相位名与亮面比例。

为什么不用「平均朔望月 29.53 天整除」：
  实测过，7 天里有 3 天判错（相位带宽只有约 ±0.5 天，平均朔望月忽略月球轨道
  偏心率，误差可达 ±0.6 天，正好卡在边界上）。
为什么不用「Meeus 第 49 章真朔月公式」：
  先按真朔月实现了一版，月龄算得对，但和和风的日标签只对上 7/10——因为和风
  不是按「月龄落在哪一段」命名，而是按当天正午的日月夹角判定（见下）。
为什么按黄经差：它直接给出「离新月/上弦/望/下弦多远」，判定与命名一致，
  且能用日食（夹角≈0°）与月食（≈180°）这两个天文事实校验。

校验（tools/moon_check.py，可复现）：
  · 与和风 10 天真实值逐日对照 10/10 一致（样本已脱敏存 tools/fixtures/）
  · 7 个日食/月食时刻的夹角偏差 0.03°~0.13°（折合 1~3 分钟），远小于相位带宽
  · 连续 400 天：夹角单调推进、亮面比例在 [0,1]
]]

local Lunar = require("dashboard_lunar")

local M = {}

--- 平均朔望月（天）。只用于「月龄」这种粗略换算，不参与相位判定。
M.SYNODIC = 29.530588861

--- 与和风 astro.moonPhase 一致的 8 个枚举值，从新月开始。
M.NAMES = {
    "new-moon", "waxing-crescent", "first-quarter", "waxing-gibbous",
    "full-moon", "waning-gibbous", "last-quarter", "waning-crescent",
}

--- 相位名对应的中文（英文在 dashboard_i18n 词表里）
M.NAMES_ZH = { "朔", "蛾眉月", "上弦月", "盈凸月", "望", "亏凸月", "下弦月", "残月" }

--- 主相位的判定带宽（黄经差，度）。
--- 0°/90°/180°/270° 各自 ±6° 内算「朔/上弦/望/下弦」，其余按象限给蛾眉月/
--- 盈凸月/亏凸月/残月。±6° ≈ ±0.49 天。
--- 取值依据：与和风 10 天样本对照，±4°~±7° 都能 10/10，取中间值留余量。
M.WINDOW_DEG = 6

local EPOCH_JD = 2451545.0          -- J2000.0
local sin, cos = math.sin, math.cos
local function rad(deg) return deg * math.pi / 180 end

--- 某一时刻的日月黄经差（0~360°，0=朔、90=上弦、180=望、270=下弦）。
--- 输入儒略日（UT 即可，TT-UT 差 69 秒对相位无影响）。
--- Meeus 第 25 章太阳视黄经 + 第 47 章月球黄经截断级数，精度约 0.1°。
function M.elongation(jd)
    local T = (jd - EPOCH_JD) / 36525.0
    local T2 = T * T
    local T3 = T2 * T
    local T4 = T3 * T

    -- 太阳：几何平黄经 + 中心差，再改正到视黄经
    local L0 = 280.46646 + 36000.76983 * T + 0.0003032 * T2
    local Ms = 357.52911 + 35999.05029 * T - 0.0001537 * T2
    local C = (1.914602 - 0.004817 * T - 0.000014 * T2) * sin(rad(Ms))
        + (0.019993 - 0.000101 * T) * sin(rad(2 * Ms))
        + 0.000289 * sin(rad(3 * Ms))
    local Om = 125.04 - 1934.136 * T
    local sun = L0 + C - 0.00569 - 0.00478 * sin(rad(Om))

    -- 月球：平黄经 + 主要周期项（截断到 0.006° 量级，足够判相位）
    local Lp = 218.3164477 + 481267.88123421 * T - 0.0015786 * T2
        + T3 / 538841 - T4 / 65194000
    local D = 297.8501921 + 445267.1114034 * T - 0.0018819 * T2
        + T3 / 545868 - T4 / 113065000
    local Mp = 134.9633964 + 477198.8675055 * T + 0.0087414 * T2
        + T3 / 69699 - T4 / 14712000
    local F = 93.2720950 + 483202.0175233 * T - 0.0036539 * T2
        - T3 / 3526000 + T4 / 863310000

    local moon = Lp
        + 6.288774 * sin(rad(Mp))
        + 1.274027 * sin(rad(2 * D - Mp))
        + 0.658314 * sin(rad(2 * D))
        + 0.213618 * sin(rad(2 * Mp))
        - 0.185116 * sin(rad(Ms))
        - 0.114332 * sin(rad(2 * F))
        + 0.058793 * sin(rad(2 * D - 2 * Mp))
        + 0.057066 * sin(rad(2 * D - Ms - Mp))
        + 0.053322 * sin(rad(2 * D + Mp))
        + 0.045758 * sin(rad(2 * D - Ms))
        + 0.041024 * sin(rad(Ms - Mp))
        - 0.034718 * sin(rad(D))
        - 0.030465 * sin(rad(Ms + Mp))
        + 0.015326 * sin(rad(2 * D - 2 * F))
        - 0.012528 * sin(rad(2 * F + Mp))
        - 0.010980 * sin(rad(2 * F - Mp))
        + 0.010674 * sin(rad(4 * D - Mp))
        + 0.010034 * sin(rad(3 * Mp))
        + 0.008548 * sin(rad(4 * D - 2 * Mp))
        - 0.007910 * sin(rad(Ms - Mp + 2 * D))
        - 0.006783 * sin(rad(2 * D + Ms))

    return (moon - sun) % 360
end

--- 公历日期 → 儒略日（含日内小数，UT/GMT）。
--- 与 dashboard_lunar 共用同一套日期换算，避免两处历法边界不一致。
function M.jd_from_ymd(y, m, d, day_frac)
    return Lunar.days_from_civil(y, m, d) + 2440587.5 + (day_frac or 0)
end

--- 黄经差 → 相位序号（1..8）与名称。
--- 判定顺序很重要：先看四个主相位（±WINDOW_DEG），再落到象限，
--- 否则新月附近会被算成「残月」（夹角 359° 落进最后一段）。
function M.name_of(elong, win)
    win = win or M.WINDOW_DEG
    local targets = { 0, 90, 180, 270 }
    for i = 1, 4 do
        local diff = math.abs(elong - targets[i])
        if diff > 180 then diff = 360 - diff end
        if diff <= win then
            return i * 2 - 1, M.NAMES[i * 2 - 1]
        end
    end
    if elong < 90 then return 2, M.NAMES[2]      -- 蛾眉月
    elseif elong < 180 then return 4, M.NAMES[4] -- 盈凸月
    elseif elong < 270 then return 6, M.NAMES[6] -- 亏凸月
    end
    return 8, M.NAMES[8]                          -- 残月
end

--- 某一时刻（本地时区）的月相。
--- year/month/day + hour（0~24 小数）+ tz_offset_min（东八区传 480）
--- 返回：elong 日月黄经差、ratio 亮面比例 0~1、index 1..8、name 相位名
function M.phase_at_local(year, month, day, hour, tz_offset_min)
    hour = hour or 12
    local jd = M.jd_from_ymd(year, month, day,
        (hour - (tz_offset_min or 0) / 60) / 24)
    local elong = M.elongation(jd)
    -- 亮面比例由夹角直接给出：(1 - cos e)/2，朔 0 → 望 1，不依赖月龄
    local ratio = (1 - cos(rad(elong))) / 2
    local index, name = M.name_of(elong)
    return elong, ratio, index, name
end

--- 便捷封装：返回表。hour 省略时取当地正午（与和风日标签的判定时刻一致）。
function M.phase(y, m, d, tz_offset_min, hour)
    local elong, ratio, index, name = M.phase_at_local(y, m, d, hour, tz_offset_min)
    return {
        elong = elong, ratio = ratio, index = index, name = name,
        age = elong / 360 * M.SYNODIC,   -- 月龄（由夹角折算，仅作显示用，非精确朔龄）
    }
end

return M
