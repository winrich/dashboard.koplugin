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
    -- 明天 / 后天：留给「今日+三日」「一周预报」两个未上线组件，暂未被引用
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

    -- 空气质量等级（HJ 633-2012）
    -- 不用 Good/Moderate 这类单字：英文里 "Moderate" 会被读成「中等、还凑合」，
    -- 而国标的「良」是仅次于优的第二档，含义正好反了，所以写成完整短语。
    ["优"] = "Excellent",
    ["良"] = "Good",
    ["轻度污染"] = "Lightly polluted",
    ["中度污染"] = "Moderately polluted",
    ["重度污染"] = "Heavily polluted",
    ["严重污染"] = "Severely polluted",

    -- 天气现象（键必须与 dashboard_qweather.CONDITIONS 的中文描述完全一致）
    -- 英文模式按天气代码反查这张表，而不是翻译接口返回的中文原文，
    -- 这样「晴间多云」「雷阵雨伴有冰雹」这类长句也有稳定的对应词。
    ["晴"] = "Clear",
    ["多云"] = "Cloudy",
    ["少云"] = "Mostly clear",
    ["晴间多云"] = "Partly cloudy",
    ["阴"] = "Overcast",
    ["阵雨"] = "Showers",
    ["强阵雨"] = "Heavy showers",
    ["雷阵雨"] = "Thunderstorm",
    ["强雷阵雨"] = "Severe thunderstorm",
    ["雷阵雨伴冰雹"] = "Thunderstorm with hail",
    ["小雨"] = "Light rain",
    ["中雨"] = "Moderate rain",
    ["大雨"] = "Heavy rain",
    ["极端降雨"] = "Extreme rain",
    ["毛毛雨"] = "Drizzle",
    ["暴雨"] = "Rainstorm",
    ["大暴雨"] = "Heavy rainstorm",
    ["特大暴雨"] = "Extreme rainstorm",
    ["冻雨"] = "Freezing rain",
    ["小到中雨"] = "Light to moderate rain",
    ["中到大雨"] = "Moderate to heavy rain",
    ["大到暴雨"] = "Heavy rain to rainstorm",
    ["暴雨到大暴雨"] = "Rainstorm to heavy rainstorm",
    ["大暴雨到特大暴雨"] = "Heavy to extreme rainstorm",
    ["雨"] = "Rain",
    ["小雪"] = "Light snow",
    ["中雪"] = "Moderate snow",
    ["大雪"] = "Heavy snow",
    ["暴雪"] = "Snowstorm",
    ["雨夹雪"] = "Sleet",
    ["雨雪天气"] = "Rain and snow",
    ["阵雨夹雪"] = "Rain and snow showers",
    ["阵雪"] = "Snow showers",
    ["小到中雪"] = "Light to moderate snow",
    ["中到大雪"] = "Moderate to heavy snow",
    ["大到暴雪"] = "Heavy snow to snowstorm",
    ["雪"] = "Snow",
    ["薄雾"] = "Mist",
    ["雾"] = "Fog",
    ["霾"] = "Haze",
    ["扬沙"] = "Blowing sand",
    ["浮尘"] = "Dust",
    ["沙尘暴"] = "Sandstorm",
    ["强沙尘暴"] = "Severe sandstorm",
    ["浓雾"] = "Dense fog",
    ["强浓雾"] = "Thick fog",
    ["中度霾"] = "Moderate haze",
    ["重度霾"] = "Heavy haze",
    ["严重霾"] = "Severe haze",
    ["大雾"] = "Heavy fog",
    ["特强浓雾"] = "Very thick fog",
    ["热"] = "Hot",
    ["冷"] = "Cold",
    ["未知"] = "Unknown",
    ["未知天气"] = "Unknown weather",

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
    -- 省电设置
    ["省电设置"] = "Power saving",
    ["时钟刷新"] = "Clock refresh",
    ["天气更新"] = "Weather update",
    ["全刷周期"] = "Full refresh",
    ["低电保护"] = "Low battery guard",
    ["只在触摸时刷新"] = "Only on touch",
    ["%d 分钟"] = "%d min",
    ["电量 ≤ %d%%"] = "Battery ≤ %d%%",
    ["关闭"] = "Off",
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
    -- 英文必须比中文更短：中文 32 个字在 13 号字下已经占满 918/920，英文按字符数
    -- 是中文的两倍多，写成 "Swipe up: exit · Swipe down: menu · Swipe: layout" 这种
    -- 完整句会被压到 11 号还是差一点（实测 1012 > 920）。所以三个方向合成一条，
    -- 只保留一次 "Swipe"。
    ["点按刷新 · 点卡片展开 · 上划退出 · 顶部下滑菜单 · 左右滑动换版式"] =
        "Tap: refresh · Card: list · Swipe up/down/side: exit/menu/layout",

    -- 组件
    ["时钟与天气"] = "Clock & weather",
    ["农历与节气"] = "Lunar & solar term",
    ["三格状态"] = "Humidity / wind / AQI",
    ["月历"] = "Month calendar",
    ["侧栏三合一"] = "Side panel",
    -- 以下 8 条是尚未上线的组件名（先备好译文，组件落地即可直接用）。
    -- 它们暂时不会出现在代码里，i18n_check.py 会报「表内未使用」——属预期，勿删。
    ["今日+三日"] = "Today + 3 days",
    ["纯天气"] = "Weather only",
    ["大字时钟"] = "Big clock",
    ["一周预报"] = "7-day forecast",
    ["在读卡"] = "Now reading",
    ["日月"] = "Sun & moon",
    ["空气明细"] = "Air quality",
    ["电量网络"] = "Battery & WiFi",

    -- v2.45 新组件用到的短标签（预报 / 空气明细 / 日月 / 在读卡 / 电量网络）
    ["首要"] = "Main",
    ["白昼"] = "Daylight",
    ["月相"] = "Moon",
    ["月升"] = "Moonrise",
    ["月落"] = "Moonset",
    ["亮面"] = "Lit",
    ["本机计算"] = "on device",
    ["电量"] = "Battery",
    ["网络"] = "Network",
    ["已连接"] = "Connected",
    ["未连接"] = "Offline",
    ["未开启"] = "Wi-Fi off",
    ["充电中"] = "Charging",
    ["在读"] = "Now reading",
    ["暂无在读"] = "No book open",
    ["作者"] = "by",
    ["页"] = "p",

    -- 倒数日 / 待办（v2.47）
    -- 「还有」「已过」只用在中文侧拼「还有 23 天」；英文的语序不同（in 23 days /
    -- 23 days ago），由下面的 relDays()/preDays() 直接出整句，不靠这两条拼。
    ["倒数日"] = "Countdown",
    ["待办"] = "To-do",
    ["待办事项"] = "To-dos",
    ["置顶"] = "Pinned",
    ["还有"] = "in",
    ["已过"] = "ago",
    ["就是今天"] = "Today",
    ["天"] = "days",
    ["暂无倒数日"] = "No countdown yet",
    ["今日无待办"] = "Nothing due today",
    ["未来"] = "Upcoming",
    ["已过期"] = "Overdue",
    ["已完成"] = "Done",
    ["删除"] = "Delete",
    ["清除已完成"] = "Clear done",
    ["添加倒数日"] = "Add countdown",
    ["添加待办"] = "Add a to-do",
    ["置顶这条"] = "Pin this",
    ["取消置顶"] = "Unpin",
    -- 「项」不再走查表：英文要单复数（1 item / 2 items），由 M.items() 处理
    -- 录入失败时的提示。英文要把「怎么写」一起说清楚，否则用户不知道错在哪
    ["内容不能为空。"] = "The text cannot be empty.",
    ["名称不能为空。"] = "The name cannot be empty.",
    -- 两步录入的标题与降级提示
    ["选日期"] = "Pick a date",
    ["日期选择器不可用，请更新 KOReader。"] =
        "The date picker is unavailable. Please update KOReader.",

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
    ["复制竖屏布局到横屏"] = "Copy portrait layout to landscape",
    ["恢复默认布局"] = "Restore default layout",
    ["默认"] = "default",
    ["语言 / Language"] = "Language / 语言",
    ["跟随 KOReader"] = "Follow KOReader",
    -- 「中文」「English」这两项不走 T()：语言名一律用自身文字显示（切到英文时
    -- 仍要能一眼找到「中文」才切得回去），所以词表里不该有它们。
}

-- 星期（1=周日 … 7=周六，与 Lunar.WEEKDAY_NAMES 同序）
local WEEKDAY_EN = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
local MONTH_EN = { "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
-- 月历表头用两字母，既能区分 Tue/Thu，又不会把格子撑宽
local WEEKDAY_HEAD_EN = { "Su", "Mo", "Tu", "We", "Th", "Fr", "Sa" }
local MONTH_FULL_EN = { "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December" }
-- 风向（8 方位，与 main.lua 的 WIND_DIRS 同序：北起顺时针）
local WIND_DIRS_EN = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }

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

-- 天干 / 地支拼音（与 dashboard_lunar 的 GAN / ZHI 同序）
local STEM_EN = { "Jia", "Yi", "Bing", "Ding", "Wu", "Ji", "Geng", "Xin", "Ren", "Gui" }
local BRANCH_EN = { "Zi", "Chou", "Yin", "Mao", "Chen", "Si", "Wu", "Wei",
                    "Shen", "You", "Xu", "Hai" }

--- 农历干支年。英文用拼音（Bing-Wu），中文原样（丙午）。
--- 英文读者单看拼音没意义，但下面一行紧跟 in the Year of the Horse，两行叠起来才完整。
function M.lunarGanzhi(lunar)
    if M.lang() ~= "en" then
        return require("dashboard_lunar").ganzhi_year(lunar)
    end
    local i = (lunar.year or 0) - 4
    return STEM_EN[i % 10 + 1] .. "-" .. BRANCH_EN[i % 12 + 1]
end

--- 农历月日。英文 Month 10, Day 4（闰月 Leap Month 6），中文十月初四。
function M.lunarMonthDay(lunar)
    if M.lang() ~= "en" then
        return require("dashboard_lunar").month_day_text(lunar)
    end
    return string.format("%sMonth %d, Day %d",
        lunar.leap and "Leap " or "", lunar.month, lunar.day)
end

--- 「项」量词。英文要跟单复数：1 item / 2 items（"1 items" 一眼就是机翻）
function M.items(n)
    if M.lang() == "en" then
        return (tonumber(n) == 1) and "item" or "items"
    end
    return "项"
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

--- 城市名。城市数据里同时存了中文名与英文名，中文名是配置里的键，不能改。
function M.city(c)
    if type(c) ~= "table" then return "" end
    if M.lang() == "en" and c.en then return c.en end
    return c.name or ""
end

--- 时区名（菜单里显示的那一项）
function M.tzName(t)
    if type(t) ~= "table" then return "" end
    if M.lang() == "en" and t.en then return t.en end
    return t.name or ""
end

--- 生肖所在的年份：「蛇年」/「Year of the Snake」
function M.zodiacYear(name)
    if M.lang() == "en" then
        local z = M.zodiac(name)
        -- 认不出来（不是十二生肖之一）就原样返回，别拼出 "Year of the 未知"
        if z == name then return name end
        return "Year of the " .. z
    end
    return name .. "年"
end

--- 顶栏的时区标注：中文用 IANA 名（与设备设置里看到的一致，便于核对）；
--- 英文用 UTC±N——英文用户看偏移比看 "Asia/Shanghai" 直观，而且短得多，
--- 顶栏放得下才不会折成两行（折行会把 header 顶高，挤掉下面的内容）。
function M.headerTz(t)
    if type(t) ~= "table" then return "" end
    if M.lang() ~= "en" then return t.iana or "" end
    local off = tonumber(t.offset) or 0
    local sign = off < 0 and "-" or "+"
    off = math.abs(off)
    local hh, mm = math.floor(off / 60), off % 60
    if mm == 0 then
        return string.format("UTC%s%d", sign, hh)
    end
    return string.format("UTC%s%d:%02d", sign, hh, mm)
end

--- 月历标题：中文「2026 年 11 月」，英文「November 2026」
function M.monthTitle(now)
    if M.lang() == "en" then
        return string.format("%s %d", MONTH_FULL_EN[now.month] or "", now.year)
    end
    return string.format("%d 年 %d 月", now.year, now.month)
end

--- 月历表头（1=周日）：中文「日」，英文「Su」
function M.weekdayHead(i)
    if M.lang() == "en" then
        return WEEKDAY_HEAD_EN[i] or ""
    end
    return require("dashboard_lunar").WEEKDAY_NAMES[i] or ""
end

--- 蒲福风级：中文「2 级」，英文「2 Bft」
--- 注：英文不用 "Force 2"，看板上三格并排，字数越少越好读
function M.windScale(n)
    if n == nil then return nil end
    if M.lang() == "en" then
        return string.format("%s Bft", tostring(n))
    end
    return string.format("%s 级", tostring(n))
end

--- 风向：中文「东南风」，英文「SE wind」。deg 为风的来向角度。
function M.windDir(deg)
    local d = tonumber(deg)
    if not d then return nil end
    local idx = math.floor(((d % 360) + 22.5) % 360 / 45) + 1
    if M.lang() == "en" then
        local dir = WIND_DIRS_EN[idx]
        return dir and (dir .. " wind") or nil
    end
    -- 中文方位表放在这里而不是 main.lua：两侧顺序必须严格一致，
    -- 分开维护迟早会错位（WIND_DIRS 已随本函数迁出 main.lua）
    local dir = ({ "北", "东北", "东", "东南", "南", "西南", "西", "西北" })[idx]
    return dir and (dir .. "风") or nil
end

--- 节气进度单行：「立冬 第 6 天」/「Start of Winter · day 6」
function M.termProgress(name, day)
    day = day or 1
    if M.lang() == "en" then
        return string.format("%s · day %d", name, day)
    end
    return string.format("%s 第%d天", name, day)
end

--- 距下一个节气：「距小雪 12 天」/「12 days to Minor Snow」
function M.termCountdown(name, days)
    days = days or 0
    if M.lang() == "en" then
        return string.format("%d days to %s", days, name)
    end
    return string.format("距%s%d天", name, days)
end

-- ------------------------------------------------------------------ 预报与月相
--- 月相名。键是和风 astro.moonPhase 的 8 个枚举值，也是 dashboard_moon 输出的
--- M.NAMES——两边同一套，所以这里不需要「未收录」兜底逻辑，但仍保留透传。
local MOON_ZH = {
    ["new-moon"] = "朔",
    ["waxing-crescent"] = "蛾眉月",
    ["first-quarter"] = "上弦月",
    ["waxing-gibbous"] = "盈凸月",
    ["full-moon"] = "望",
    ["waning-gibbous"] = "亏凸月",
    ["last-quarter"] = "下弦月",
    ["waning-crescent"] = "残月",
}
local MOON_EN = {
    ["new-moon"] = "New moon",
    ["waxing-crescent"] = "Waxing crescent",
    ["first-quarter"] = "First quarter",
    ["waxing-gibbous"] = "Waxing gibbous",
    ["full-moon"] = "Full moon",
    ["waning-gibbous"] = "Waning gibbous",
    ["last-quarter"] = "Last quarter",
    ["waning-crescent"] = "Waning crescent",
}

--- 月相名：「蛾眉月」/「Waxing crescent」。认不出的键原样返回。
function M.moonPhase(name)
    if not name then return nil end
    local tbl = (M.lang() == "en") and MOON_EN or MOON_ZH
    return tbl[name] or name
end

--- 污染物符号。数据源给的名字写法不一（和风 "PM 2.5"、Open-Meteo "PM2.5"），
--- 统一按 code 出符号，否则同一块面板里两个源的字距都不一样。
--- 一律用 ASCII 数字：U+2082/U+2083 这类下标字符在 Kindle 的中文字体里通常没有，
--- 真机上会显示成方框（本地渲染时就能看到 O□ / NO□）。
local POLLUTANT_LABEL = {
    pm2p5 = "PM2.5", pm10 = "PM10", no2 = "NO2", o3 = "O3", so2 = "SO2", co = "CO",
}
--- 污染物展示顺序：颗粒物在前，气态在后，和国标 AQI 报表的习惯一致
M.POLLUTANT_ORDER = { "pm2p5", "pm10", "o3", "no2", "so2", "co" }

function M.pollutant(code)
    if not code then return "" end
    return POLLUTANT_LABEL[code] or tostring(code):upper()
end

--- 星期全称（1=周日）：中文「周三」，英文「Wed」
--- 预报列很窄，中英都取最短形式；表头的单字用 weekdayHead。
function M.weekdayShort(i)
    if M.lang() == "en" then
        return WEEKDAY_EN[i] or ""
    end
    local name = require("dashboard_lunar").WEEKDAY_NAMES[i]
    return name and ("周" .. name) or ""
end

--- 「今天 / 明天 / 后天 / 周三」——预报第一列用相对日，比星期更好认。
--- 英文只保留 Today / Tomorrow：'In 2 days' 在 7 列布局里会把列撑宽，
--- 第三天起一律用星期缩写。
function M.dayLabel(i, wd)
    if M.lang() == "en" then
        if i == 1 then return M.T("今天") end
        if i == 2 then return M.T("明天") end
        return M.weekdayShort(wd)
    end
    if i == 1 then return M.T("今天") end
    if i == 2 then return M.T("明天") end
    if i == 3 then return M.T("后天") end
    return M.weekdayShort(wd)
end

--- 短日期「11/12」。预报列里再用「11月12日」会把整行撑宽。
function M.monthDay(m, d)
    if not m or not d then return "" end
    return string.format("%d/%d", m, d)
end

-- ---------------------------------------------------------------- 倒数日
--- 「还有 23 天 / 就是今天 / 已过 3 天」。
--- 英文不能照字面拼：中文是「还有 + 数字 + 天」，英文是 "in + 数字 + days"，
--- 负数还得说 "3 days ago"（数字在前）。两种语序都写死在这儿，别在组件里拼。
function M.relDays(n)
    n = tonumber(n) or 0
    if n == 0 then return M.T("就是今天") end
    if M.lang() == "en" then
        return n > 0 and string.format("in %d days", n) or string.format("%d days ago", -n)
    end
    return n > 0 and string.format("还有 %d 天", n) or string.format("已过 %d 天", -n)
end

--- 大字位「数字」左边的前缀词。今天没有前缀（整句换成「就是今天」）。
function M.preDays(n)
    n = tonumber(n) or 0
    if n == 0 then return nil end
    if M.lang() == "en" then return n > 0 and "in" or nil end
    return n > 0 and M.T("还有") or M.T("已过")
end

--- 大字位「数字」右边的量词。英文过去时整段是 "days ago"，所以要吃 n。
function M.daysUnit(n)
    n = tonumber(n) or 0
    if M.lang() == "en" then
        return n < 0 and "days ago" or "days"
    end
    return M.T("天")
end

--- 温差（最高-最低）：「10°」，取不到就 nil
function M.tempRange(tmax, tmin)
    if not tmax or not tmin then return nil end
    return string.format("%d°", math.floor(tmax - tmin + 0.5))
end

M.EN = EN
M.TERM_EN = TERM_EN

return M
