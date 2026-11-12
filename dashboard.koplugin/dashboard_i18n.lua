--[[--
桌面看板的多语言文本表（v2.44）

为什么不用 KOReader 的 `_()`：插件没有 .po 目录，`_()` 只会原样返回中文；
而且看板是「常显在屏幕上的一页」，语言应当能独立于 KOReader 的界面语言切换
（设备只用来显示，不需要跟着阅读界面变）。所以自带一张表，键就是中文原文。

设计约定（重要，改代码前先读这段）：
1. **中文原文即键**。`T("湿度")` 命中就返回英文，没命中就原样返回中文。
   因此翻译不全不会崩、不会出现 nil，只会退回中文——这是刻意的降级设计。
2. 语言取值 `dashboard_lang` = "auto" | "zh" | "en"，存在 G_reader_settings。
   auto 的规则见 detect()：KOReader 显式设成非中文时才跟着变，
   KOReader 处于默认 "C"（语言没设过）时按中文，避免升级后看板突然变英文。
3. 农历月日、干支、生肖属于中国历法的专名，中英模式下都显示汉字；
   节气提供英文名（Solar terms 有国际通用译名），星期与月份用英文。
4. 长段落（使用说明、提示框）不用本表，改用 TL(zh, en) 显式二选一，
   避免多行拼接字符串做键时因换行/引号对不上而静默失效。
]]

local M = {}

local KEY = "dashboard_lang"

-- ------------------------------------------------------------------ 英文词条
-- 键必须与代码里的中文字面量**完全一致**（含标点和空格）。
local EN = {
    -- 界面标签
    ["农历"] = "Lunar",
    ["节气"] = "Solar term",
    ["天文与空气"] = "Sun & air",
    ["日出"] = "Sunrise",
    ["日落"] = "Sunset",
    ["空气"] = "Air",
    ["湿度"] = "Humidity",
    ["风力"] = "Wind",
    ["体感"] = "Feels",
    ["今天"] = "Today",
    ["明天"] = "Tomorrow",
    ["后天"] = "In 2 days",
    ["更新于"] = "Updated",
    ["尚未获取天气"] = "No weather yet",
    ["暂无数据"] = "No data",
    ["未知原因"] = "Unknown reason",
    ["未填写"] = "Empty",
    ["未配置"] = "Not configured",
    ["来源"] = "Source",
    ["项目"] = "Project",
    ["距"] = "in",

    -- 空气质量等级（HJ 633-2012）
    ["优"] = "Good",
    ["良"] = "Moderate",
    ["轻度污染"] = "Light",
    ["中度污染"] = "Medium",
    ["重度污染"] = "Heavy",
    ["严重污染"] = "Severe",

    -- 天气来源
    ["和风天气"] = "QWeather",
    ["Open-Meteo 降级"] = "Open-Meteo",
    ["天气数据 和风天气"] = "Weather: QWeather",
    ["天气 Open-Meteo（降级）"] = "Weather: Open-Meteo",

    -- 菜单
    ["桌面看板"] = "Desk dashboard",
    ["打开看板"] = "Open dashboard",
    ["立即刷新天气"] = "Refresh weather now",
    ["重新布局"] = "Relayout",
    ["休眠时显示看板（屏保）"] = "Show dashboard while asleep (screensaver)",
    ["选择城市"] = "City",
    ["选择时区"] = "Time zone",
    ["直辖市"] = "Municipalities",
    ["省会与首府"] = "Provincial capitals",
    ["港澳台"] = "HK / Macao / Taiwan",
    ["版式（竖屏 / 横屏）"] = "Layout (portrait / landscape)",
    ["竖屏"] = "Portrait",
    ["横屏（向右转 90°）"] = "Landscape (rotate right)",
    ["横屏（向左转 90°）"] = "Landscape (rotate left)",
    ["（当前）"] = " (current)",
    ["天气服务"] = "Weather service",
    ["使用说明"] = "Help",
    ["查看当前凭据"] = "View credentials",
    ["清除设备内录入"] = "Clear stored credentials",
    ["测试连接"] = "Test connection",
    ["正在连接和风天气…"] = "Connecting to QWeather…",
    ["填写 API Host"] = "Enter API Host",
    ["填写 API Key"] = "Enter API Key",
    ["和风天气 API Host"] = "QWeather API Host",
    ["和风天气 API Key"] = "QWeather API Key",
    ["API Host"] = "API Host",
    ["API Key"] = "API Key",
    ["凭据 ID"] = "Credential ID",
    ["取消"] = "Cancel",
    ["保存"] = "Save",
    ["设备内录入"] = "Stored on device",
    ["插件内 dashboard_config.lua"] = "dashboard_config.lua in plugin",
    ["插件内 dashboard_config.local.lua"] = "dashboard_config.local.lua in plugin",
    ["降级同样失败"] = "Fallback also failed",
    ["天气更新失败：%s"] = "Weather update failed: %s",
    ["当前未连接网络。接入 WiFi 后会自动重试。"] = "No network. Will retry after WiFi connects.",
    ["已清除。凭据改由插件目录下的配置文件提供。"] = "Cleared. Credentials now come from the plugin config file.",
    ["已记住，下次打开看板时按这个方向显示"] = "Saved. Applied next time the dashboard opens.",
    ["已切换为横屏版式（本机不支持转屏）"] = "Landscape layout (this device cannot rotate).",
    ["已转为横屏，请把设备横着拿（再左右滑一下可转回竖屏）"] =
        "Rotated to landscape — hold the device sideways (swipe to go back).",
    ["已转回竖屏"] = "Back to portrait.",

    -- 页脚与提示
    ["点按刷新 · 上划退出 · 顶部下滑菜单 · 左右滑动换版式"] =
        "Tap: refresh · Swipe up: exit · Swipe down: menu · Swipe sideways: layout",

    -- 组件
    ["时钟与天气"] = "Clock & weather",
    ["农历与节气"] = "Lunar & solar term",
    ["三格状态"] = "Humidity / wind / AQI",
    ["月历"] = "Month calendar",
    ["侧栏三合一"] = "Side panel",
    ["今日+三日"] = "Today + 3 days",
    ["纯天气"] = "Weather only",
    ["大字时钟"] = "Big clock",
    ["一周预报"] = "7-day forecast",
    ["在读卡"] = "Now reading",
    ["日月"] = "Sun & moon",
    ["空气明细"] = "Air quality",
    ["电量网络"] = "Battery & WiFi",

    -- 布局组件菜单
    ["布局组件"] = "Layout components",
    ["竖屏布局"] = "Portrait layout",
    ["横屏布局"] = "Landscape layout",
    ["A 区（上）"] = "Zone A (top)",
    ["B 区（中）"] = "Zone B (middle)",
    ["C 区（下）"] = "Zone C (bottom)",
    ["B 区（左下）"] = "Zone B (lower left)",
    ["C 区（右下）"] = "Zone C (lower right)",
    ["控制台「设置」页里的专属地址，形如 abcxyz.qweatherapi.com，不要带 https://"] =
        "Project host from the console Settings page, e.g. abcxyz.qweatherapi.com (no https://)",
    ["控制台「项目管理 - 凭据」里创建，需与上面的 API Host 属于同一项目"] =
        "Create it under Console → Project → Credentials, in the same project as the host",
    ["B 区（中 / 左下）"] = "Zone B (middle / lower-left)",
    ["C 区（下 / 右下）"] = "Zone C (bottom / lower-right)",
    ["复制竖屏布局到横屏"] = "Copy portrait layout to landscape",
    ["布局已复制"] = "Layout copied",
    ["恢复默认布局"] = "Restore default layout",
    ["默认"] = "default",
    ["语言 / Language"] = "Language / 语言",
    ["跟随 KOReader"] = "Follow KOReader",
    ["中文"] = "中文",
    ["English"] = "English",
    ["界面语言已切换，重开看板生效"] = "Language changed. Reopen the dashboard to apply.",
}

-- 星期（1=周日 … 7=周六，与 Lunar.WEEKDAY_NAMES 同序）
local WEEKDAY_EN = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
local MONTH_EN = { "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

-- 二十四节气英文名（按 Lunar.TERM_NAMES 的顺序：小寒起）
local TERM_EN = {
    "Minor Cold", "Major Cold", "Start of Spring", "Rain Water",
    "Awakening of Insects", "Spring Equinox", "Pure Brightness", "Grain Rain",
    "Start of Summer", "Grain Buds", "Grain in Ear", "Summer Solstice",
    "Minor Heat", "Major Heat", "Start of Autumn", "End of Heat",
    "White Dew", "Autumn Equinox", "Cold Dew", "Frost's Descent",
    "Start of Winter", "Minor Snow", "Major Snow", "Winter Solstice",
}

-- 十二生肖英文名（与 Lunar 的 ZODIAC 同序：鼠起）
local ZODIAC_EN = { "Rat", "Ox", "Tiger", "Rabbit", "Dragon", "Snake",
    "Horse", "Goat", "Monkey", "Rooster", "Dog", "Pig" }

-- ------------------------------------------------------------------ 语言解析
local cached_lang

--- 读设置。auto 时跟随 KOReader：显式设成中文 → zh，显式设成其他语言 → en，
--- 未设置（"C"）→ zh。第三条是刻意的：设备语言没设过时不能突然变英文。
local function detect()
    -- 注意：KOReader 的 gettext 模块本身是**可调用对象**（table + __call），
    -- 而桩件里它是个普通函数。所以这里不能直接 gt.current_lang，
    -- 必须 pcall 取字段并校验类型，否则桩件一加载就 "attempt to index a function value"。
    local cur = "C"
    local ok, gt = pcall(require, "gettext")
    if ok and gt then
        local ok2, v = pcall(function() return gt.current_lang end)
        if ok2 and type(v) == "string" and v ~= "" then
            cur = v
        end
    end
    if cur == "C" or cur == "" then
        return "zh"
    end
    if cur:lower():match("^zh") then
        return "zh"
    end
    return "en"
end

--- 当前语言："zh" 或 "en"
function M.lang()
    local set
    local ok = pcall(function()
        set = G_reader_settings and G_reader_settings:readSetting(KEY)
    end)
    if ok and (set == "zh" or set == "en") then
        return set
    end
    if cached_lang then return cached_lang end
    cached_lang = detect()
    return cached_lang
end

--- 设置语言："auto" | "zh" | "en"，传 nil 等价于 auto
function M.setLang(v)
    if v ~= "zh" and v ~= "en" then v = "auto" end
    pcall(function()
        G_reader_settings:saveSetting(KEY, v)
        if G_reader_settings.flush then G_reader_settings:flush() end
    end)
    cached_lang = nil
    return M.lang()
end

--- 读原始设置（菜单里打勾用）
function M.setting()
    local v
    pcall(function() v = G_reader_settings and G_reader_settings:readSetting(KEY) end)
    if v == "zh" or v == "en" then return v end
    return "auto"
end

--- 翻译。未命中时原样返回中文（降级，不报错）
function M.T(s)
    if type(s) ~= "string" then return s end
    if M.lang() ~= "en" then return s end
    return EN[s] or s
end

--- 二选一：长段落用，避免多行拼接字符串当键
function M.TL(zh, en)
    if M.lang() == "en" then return en end
    return zh
end

--- 星期名：i 取 1..7（1=周日）
function M.weekday(i)
    if M.lang() == "en" then
        return WEEKDAY_EN[i] or ""
    end
    return "星期" .. ({ "日", "一", "二", "三", "四", "五", "六" })[i]
end

--- 节气名：中文原样，英文查表（不认识就退回中文）
function M.term(name, index)
    if M.lang() ~= "en" then return name end
    if index and TERM_EN[index] then return TERM_EN[index] end
    -- 只有名字时反查：中文名 → TERM_EN
    local names = require("dashboard_lunar").TERM_NAMES
    for i, n in ipairs(names or {}) do
        if n == name then return TERM_EN[i] or name end
    end
    return name
end

--- 生肖
function M.zodiac(name, index)
    if M.lang() ~= "en" then return name end
    if index and ZODIAC_EN[index] then return ZODIAC_EN[index] end
    local names = { "鼠", "牛", "虎", "兔", "龙", "蛇", "马", "羊", "猴", "鸡", "狗", "猪" }
    for i, n in ipairs(names) do
        if n == name then return ZODIAC_EN[i] or name end
    end
    return name
end

--- 日期行。short=true 为竖屏（不带年份），false 为横屏（带年份）
function M.dateLine(now, short)
    if M.lang() == "en" then
        local wd = WEEKDAY_EN[now.wday] or ""
        local mon = MONTH_EN[now.month] or ""
        if short then
            return string.format("%s, %s %d", wd, mon, now.day)
        end
        return string.format("%s, %s %d, %d", wd, mon, now.day, now.year)
    end
    local wd = ({ "日", "一", "二", "三", "四", "五", "六" })[now.wday] or ""
    if short then
        return string.format("%d月%d日 星期%s", now.month, now.day, wd)
    end
    return string.format("%d年%d月%d日 星期%s", now.year, now.month, now.day, wd)
end

M.EN = EN
M.TERM_EN = TERM_EN

return M
