--[[--
桌面看板（dashboard.koplugin） v2

全屏常驻显示，按屏幕方向自动切换版式：
  · 竖屏（H > W）  仪表盘版式：顶部城市条 + 大时钟 + 天气 + 农历大字 + 节气进度条 + 底部三格
  · 横屏（W >= H） 上下分区版式：顶部城市条 + 大时钟与天气 + 整月日历网格 + 农历节气

显示内容：时钟、公历日期与星期、农历（干支、生肖）、当前节气与距下一节气天数、
当日天气（图标/温度/现象/体感）、湿度、风向风力、空气质量 AQI、日出日落。

数据源：Open-Meteo 天气 + 空气质量（均免注册、免 API Key）。
空气质量按 HJ 633-2012 分档由 PM2.5/PM10 浓度换算，属估算值，非官方发布值。

交互：
  · 点按屏幕      -> 立即刷新天气
  · 长按屏幕      -> 退出看板

设计要点（均已按 KOReader 源码核对，非猜测）：
  · Widget:paintTo 基类是空实现，自绘控件必须自己实现 paintTo，getSize 返回 self.dimen
  · WidgetContainer:paintTo 不处理 background，白底必须自己刷，否则透出下层界面
  · TextWidget 支持 setText() 与 fgcolor（官方示例即用 Blitbuffer.COLOR_DARK_GRAY）
  · 防休眠用 UIManager:preventStandby() / allowStandby()（KOReader 官方接口）
  · HTTPS 走 socket.http（KOReader 自带 LuaSec 集成），失败再退到 ssl.https
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Widget = require("ui/widget/widget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")

local JSON = require("json")
local http = require("socket.http")
local ltn12 = require("ltn12")

local _ = require("gettext")
local Lunar = require("dashboard_lunar")
local CityData = require("dashboard_cities")

local Screen = Device.screen

http.TIMEOUT = 20

local COLOR_BLACK = Blitbuffer.COLOR_BLACK
local COLOR_WHITE = Blitbuffer.COLOR_WHITE
-- COLOR_DARK_GRAY 在个别老版本上可能不存在，退化成黑色而不是崩掉
local COLOR_GRAY = Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_BLACK

-- 插件自身目录（icons 相对此目录）
local PLUGIN_DIR = (function()
    local src = (debug.getinfo(1, "S").source or ""):gsub("^@", "")
    return src:match("^(.*)[/\\][^/\\]+$") or "."
end)()

local UPDATE_INTERVAL = 30 * 60      -- 天气拉取间隔
local FULL_REFRESH_PERIOD = 30       -- 每 30 分钟全刷一次清残影

-- 设计基准：屏幕短边 600 像素 = 1 倍。
-- 600x800@167ppi 与 1072x1448@300ppi 都是 6 英寸，短边比 1.787，物理尺寸一致；
-- 因此竖屏与横屏共用同一个缩放系数，旋转设备时字号的物理大小不变。
local BASE_SHORT = 600

-- 真机字体度量与设计预估总有偏差，装不下时逐级缩小重排，避免底部被截断
local FIT_MAX_STEPS = 8
local FIT_STEP = 0.96
local FIT_SAFE_RATIO = 0.985

-- WMO 天气代码 -> { 中文描述, 图标名 }
local WEATHER_CODES = {
    [0]  = { "晴",          "clear" },
    [1]  = { "晴间多云",     "mainly_clear" },
    [2]  = { "多云",        "partly" },
    [3]  = { "阴",          "overcast" },
    [45] = { "雾",          "fog" },
    [48] = { "雾凇",        "fog" },
    [51] = { "毛毛雨",       "drizzle" },
    [53] = { "毛毛雨",       "drizzle" },
    [55] = { "浓毛毛雨",     "drizzle" },
    [56] = { "冻毛毛雨",     "freezing_rain" },
    [57] = { "冻毛毛雨",     "freezing_rain" },
    [61] = { "小雨",        "rain" },
    [63] = { "中雨",        "rain" },
    [65] = { "大雨",        "rain" },
    [66] = { "冻雨",        "freezing_rain" },
    [67] = { "强冻雨",       "freezing_rain" },
    [71] = { "小雪",        "snow" },
    [73] = { "中雪",        "snow" },
    [75] = { "大雪",        "snow" },
    [77] = { "米雪",        "snow" },
    [80] = { "阵雨",        "shower" },
    [81] = { "强阵雨",       "shower" },
    [82] = { "暴阵雨",       "shower" },
    [85] = { "阵雪",        "snow_shower" },
    [86] = { "强阵雪",       "snow_shower" },
    [95] = { "雷阵雨",       "thunder" },
    [96] = { "雷阵雨伴冰雹",  "thunder" },
    [99] = { "雷阵雨伴冰雹",  "thunder" },
}

-- 蒲福风级（km/h 下限），索引即风级
local WIND_LEVEL_BOUNDS = { 1, 6, 12, 20, 29, 39, 50, 62, 75, 89, 103, 118 }
local WIND_DIRS = { "北", "东北", "东", "东南", "南", "西南", "西", "西北" }

-- 空气质量：HJ 633-2012 浓度限值 { 浓度下限, 浓度上限, IAQI 下限, IAQI 上限 }
local PM25_BREAKPOINTS = {
    { 0, 35, 0, 50 }, { 35, 75, 50, 100 }, { 75, 115, 100, 150 },
    { 115, 150, 150, 200 }, { 150, 250, 200, 300 }, { 250, 350, 300, 400 },
    { 350, 500, 400, 500 },
}
local PM10_BREAKPOINTS = {
    { 0, 50, 0, 50 }, { 50, 150, 50, 100 }, { 150, 250, 100, 150 },
    { 250, 350, 150, 200 }, { 350, 420, 200, 300 }, { 420, 500, 300, 400 },
    { 500, 600, 400, 500 },
}

-- ------------------------------------------------------------------ 自绘控件
-- Widget 基类的 paintTo 是空实现，这里补上三种最基础的绘制单元。

-- 实心色块：分隔线、竖线、圆点
local Solid = Widget:extend{}
function Solid:getSize()
    return self.dimen
end
function Solid:paintTo(bb, x, y)
    if self.dimen.w > 0 and self.dimen.h > 0 then
        bb:paintRect(x, y, self.dimen.w, self.dimen.h, self.color or COLOR_BLACK)
    end
end

-- 固定尺寸的区域：可填背景色（"今天"反白），子控件按 align 水平放置
-- auto_h = true 时高度取「设定值」与「子控件实际高度」的较大者，
-- 避免字体度量比预估高时，内容溢出压到下一行
local Stack = Widget:extend{}
function Stack:getSize()
    if self[1] and self.auto_h then
        local cs = self[1]:getSize()
        self.dimen.h = math.max(self.dimen.h or 0, cs.h)
    end
    return self.dimen
end
function Stack:paintTo(bb, x, y)
    if self.bg then
        bb:paintRect(x, y, self.dimen.w, self.dimen.h, self.bg)
    end
    local child = self[1]
    if child then
        local cs = child:getSize()
        local ox = math.max(0, math.floor((self.dimen.w - cs.w) / 2))
        if self.align == "left" then ox = 0 end
        local oy = math.max(0, math.floor((self.dimen.h - cs.h) / 2))
        child:paintTo(bb, x + ox, y + oy)
    end
end

-- 节气进度条：外框 + 已过部分实心填充
local ProgressBar = Widget:extend{}
function ProgressBar:getSize()
    return self.dimen
end
function ProgressBar:paintTo(bb, x, y)
    local w, h = self.dimen.w, self.dimen.h
    if w < 4 or h < 4 then return end
    local bw = math.max(1, self.border or 2)
    bb:paintBorder(x, y, w, h, bw, COLOR_BLACK, nil, false)
    local inner = w - bw * 2
    local ratio = math.max(0, math.min(1, self.ratio or 0))
    local filled = math.floor(inner * ratio + 0.5)
    if filled > 0 then
        bb:paintRect(x + bw, y + bw, filled, h - bw * 2, COLOR_BLACK)
    end
end

-- ------------------------------------------------------------------ 布局小工具
local function mkPad(w, h)
    return Widget:new{
        dimen = Geom:new{ w = math.max(0, math.floor(w)), h = math.max(1, math.floor(h)) },
    }
end

local function mkBox(w, h, child, opts)
    opts = opts or {}
    return Stack:new{
        dimen = Geom:new{ w = math.max(1, math.floor(w)), h = math.max(1, math.floor(h)) },
        bg = opts.bg,
        align = opts.align,
        auto_h = opts.auto_h,
        child,
    }
end

local Dashboard = WidgetContainer:extend{
    name = "dashboard",
    is_doc_only = false,
}

-- 前置声明（实现在文件末尾的数据换算区，避免污染全局命名空间）
local windLabel

-- ------------------------------------------------------------------ 生命周期
function Dashboard:init()
    self.cache = LuaSettings:open(DataStorage:getSettingsDir() .. "/dashboard_cache.lua")
    local cached = self.cache:readSetting("weather")
    if type(cached) == "table" then
        self.weather = cached
    end
    local air = self.cache:readSetting("air")
    if type(air) == "table" then
        self.air = air
    end
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
end

-- 应用退出时兜底恢复系统状态，避免屏幕保护被一直抑制
function Dashboard:onCloseWidget()
    if self.shown then
        self:close()
    end
end

-- ------------------------------------------------------------------ 菜单
function Dashboard:addToMainMenu(menu_items)
    menu_items.dashboard_desk = {
        sorting_hint = "tools",
        text = _("桌面看板"),
        sub_item_table = self:genMenuItemTable(),
    }
end

function Dashboard:genMenuItemTable()
    local items = {
        {
            text = _("打开看板"),
            callback = function() self:open() end,
        },
        {
            text = _("立即刷新天气"),
            callback = function() self:fetchWeather(true) end,
        },
        {
            text = _("重新布局"),
            callback = function()
                if self.shown then self:refreshLayout() end
            end,
        },
    }

    local city_groups = {
        { key = "直辖市", text = _("直辖市") },
        { key = "省会",   text = _("省会与首府") },
        { key = "港澳台", text = _("港澳台") },
    }
    local city_items = {}
    for _, g in ipairs(city_groups) do
        local sub = {}
        for _, c in ipairs(CityData.cities) do
            if c.group == g.key then
                sub[#sub + 1] = {
                    text = c.name,
                    checked_func = function() return self:getCityName() == c.name end,
                    callback = function() self:setCity(c.name) end,
                }
            end
        end
        city_items[#city_items + 1] = { text = g.text, sub_item_table = sub }
    end
    items[#items + 1] = { text = _("选择城市"), sub_item_table = city_items }

    local tz_items = {}
    for _, t in ipairs(CityData.timezones) do
        tz_items[#tz_items + 1] = {
            text = t.name,
            checked_func = function() return self:getTzIana() == t.iana end,
            callback = function() self:setTz(t.iana) end,
        }
    end
    items[#items + 1] = { text = _("选择时区"), sub_item_table = tz_items }

    items[#items + 1] = {
        text = _("使用说明"),
        callback = function()
            UIManager:show(InfoMessage:new{
                text = _("点按屏幕刷新天气，长按屏幕退出看板。\n\n"
                    .. "看板按屏幕方向自动切换版式：竖屏为仪表盘，横屏带整月日历。\n"
                    .. "旋转设备后若版式没跟着变，可从菜单执行「重新布局」。\n\n"
                    .. "长时间显示建议接通电源；程序每 30 分钟自动全刷一次以清除电泳残影。\n"
                    .. "空气质量由 PM2.5/PM10 浓度按国标分档估算，仅供参考。"),
            })
        end,
    }
    return items
end

-- ------------------------------------------------------------------ 配置读写
function Dashboard:getCityName()
    return G_reader_settings:readSetting("dashboard_city") or "北京"
end

function Dashboard:getCity()
    local name = self:getCityName()
    for _, c in ipairs(CityData.cities) do
        if c.name == name then return c end
    end
    return CityData.cities[1]
end

function Dashboard:getTzIana()
    return G_reader_settings:readSetting("dashboard_tz") or "Asia/Shanghai"
end

function Dashboard:getTz()
    local iana = self:getTzIana()
    for _, t in ipairs(CityData.timezones) do
        if t.iana == iana then return t end
    end
    return CityData.timezones[1]
end

function Dashboard:setCity(name)
    G_reader_settings:saveSetting("dashboard_city", name)
    self:onConfigChanged()
end

function Dashboard:setTz(iana)
    G_reader_settings:saveSetting("dashboard_tz", iana)
    self:onConfigChanged()
end

function Dashboard:onConfigChanged()
    if not self.shown then return end
    self:refreshLayout()
    self:fetchWeather()
end

-- 当前时区下的时间分解（不依赖设备时区设置）
function Dashboard:localNow()
    return os.date("!*t", os.time() + self:getTz().offset * 60)
end

-- ------------------------------------------------------------------ 打开 / 关闭
function Dashboard:open()
    if self.shown then return end
    self.shown = true
    self:setKindleScreenSaver(true)
    UIManager:preventStandby()
    self:refreshLayout()
    self:fetchWeather()
    self:scheduleTick()
end

function Dashboard:close()
    if not self.shown then return end
    self.shown = false
    if self._tick_fn then
        UIManager:unschedule(self._tick_fn)
    end
    local root = self.root
    self.root = nil
    if root then
        UIManager:close(root)
    end
    UIManager:allowStandby()
    self:setKindleScreenSaver(false)
end

-- Kindle 上抑制系统屏保（KOReader 自身只负责不主动待机，屏保由 powerd 管）
function Dashboard:setKindleScreenSaver(prevent)
    if not Device:isKindle() then return end
    local value = prevent and "1" or "0"
    local ok = os.execute("lipc-set-prop com.lab126.powerd preventScreenSaver " .. value)
    logger.dbg("dashboard: preventScreenSaver =", value, "result:", tostring(ok))
end

-- ------------------------------------------------------------------ 定时器
function Dashboard:scheduleTick()
    if not self.shown then return end
    if not self._tick_fn then
        self._tick_fn = function() self:tick() end
    end
    UIManager:unschedule(self._tick_fn)
    local now = self:localNow()
    UIManager:scheduleIn(math.max(1, 60 - (tonumber(now.sec) or 0)), self._tick_fn)
end

function Dashboard:tick()
    if not self.shown then return end
    local now = self:localNow()

    -- 分钟级：只改时钟文字，局部刷新
    local clock = string.format("%02d:%02d", now.hour, now.min)
    if self.clock_widget and clock ~= self.clock_text then
        self.clock_text = clock
        self.clock_widget:setText(clock)
        UIManager:setDirty(self.root, "ui")
    end

    -- 跨日：日期/农历/节气/月历全部要重算
    local day_key = string.format("%04d%02d%02d", now.year, now.month, now.day)
    if day_key ~= self.day_key then
        self:refreshLayout()
    elseif now.min % FULL_REFRESH_PERIOD == 0 then
        UIManager:setDirty(self.root, "full")
    end

    -- 定时拉取天气：已有数据时 30 分钟一次；还没有数据时 5 分钟重试
    local last = self.weather and self.weather.ts or 0
    local interval = self.weather and UPDATE_INTERVAL or 5 * 60
    if os.time() - last >= interval then
        self:fetchWeather()
    end

    self:scheduleTick()
end

-- ------------------------------------------------------------------ 数据整理
function Dashboard:iconPath(name)
    local dir = self.path or PLUGIN_DIR
    return dir .. "/icons/" .. name .. ".png"
end

--- 把缓存的天气数据整理成展示用的字段
function Dashboard:weatherDisplay()
    local w = self.weather
    local d = {
        icon = "partly",
        cond = _("暂无数据"),
        temp = "--°",
        range = nil,
        hum = nil,
        feels = nil,
        wind = nil,
        sunrise = nil,
        sunset = nil,
    }
    if not w then return d end

    local meta = WEATHER_CODES[tonumber(w.code) or -1]
    if meta then
        d.cond = _(meta[1])
        d.icon = meta[2]
    elseif w.code then
        d.cond = _("未知天气")
    end

    if w.temp then
        d.temp = string.format("%d°", math.floor(w.temp + 0.5))
    end
    if w.tmin and w.tmax then
        d.range = string.format("%d° ~ %d°",
            math.floor(w.tmin + 0.5), math.floor(w.tmax + 0.5))
    end
    if w.feels then
        d.feels = string.format("%s %d°", _("体感"), math.floor(w.feels + 0.5))
    end
    if w.hum then
        d.hum = string.format("%d%%", math.floor(w.hum + 0.5))
    end
    -- 风向与风级分开返回：三格布局里数值只放“2 级”，风向作为小注，
    -- 否则“东南风 2 级”会超过单格宽度，跨过分隔线串到相邻格
    local wdir, wlevel = windLabel(w.wind, w.winddir)
    d.wind_dir = wdir
    d.wind = wlevel and string.format("%d 级", wlevel) or nil
    d.sunrise = w.sunrise
    d.sunset = w.sunset
    return d
end

--- 空气质量展示文本与等级
function Dashboard:airDisplay()
    local a = self.air
    if not a or not a.aqi then
        return { text = "--", level = _("暂无数据") }
    end
    local aqi = math.floor(a.aqi + 0.5)
    local level
    if aqi <= 50 then level = _("优")
    elseif aqi <= 100 then level = _("良")
    elseif aqi <= 150 then level = _("轻度污染")
    elseif aqi <= 200 then level = _("中度污染")
    elseif aqi <= 300 then level = _("重度污染")
    else level = _("严重污染") end
    return { text = tostring(aqi), level = level }
end

--- 节气进度：当前节气已过天数 / 节气总长
function Dashboard:solarTermRatio(ctx)
    local cur, nxt = ctx.cur_term, ctx.next_term
    if not cur then return 0, nil, nil end
    local elapsed = math.max(1, cur.elapsed or 1)
    local remain = nxt and nxt.in_days or 0
    local total = elapsed + remain
    if total <= 0 then return 1, nil, nil end
    return elapsed / total, elapsed, remain
end

function Dashboard:updateLabel(ctx)
    local w = self.weather
    if w and w.ts then
        return string.format("%s %s", _("更新于"),
            os.date("!%H:%M", w.ts + ctx.tz.offset * 60))
    end
    return _("尚未获取天气")
end

-- ------------------------------------------------------------------ 界面构建
function Dashboard:refreshLayout()
    if not self.shown then return end
    local old = self.root
    self.root = self:createRoot()
    UIManager:show(self.root)
    if old then
        UIManager:close(old)
    end
    UIManager:setDirty(self.root, "full")
end

--- 文本控件工厂：字号与颜色统一在这里处理
function Dashboard:makeText(ctx, str, px, opts)
    opts = opts or {}
    return TextWidget:new{
        text = str or "",
        face = Font:getFace(opts.face or "cfont", math.max(11, math.floor(px * ctx.S))),
        bold = opts.bold or false,
        fgcolor = opts.gray and COLOR_GRAY or COLOR_BLACK,
        padding = 0,
        max_width = opts.max_width,
    }
end

function Dashboard:createRoot()
    local W, H = Screen:getWidth(), Screen:getHeight()
    local landscape = W >= H
    local now = self:localNow()
    local tz = self:getTz()

    local ctx = {
        W = W,
        H = H,
        landscape = landscape,
        now = now,
        tz = tz,
        lunar = Lunar.solar_to_lunar(now.year, now.month, now.day),
        city = self:getCity(),
    }
    ctx.cur_term, ctx.next_term = Lunar.current_term(now.year, now.month, now.day, tz.offset)

    -- 先按物理基准排一次；若高度超出屏幕（真机字体度量比预估高，或横屏纵向空间
    -- 本就比竖屏紧），按 FIT_STEP 逐级缩小重排，最多 FIT_MAX_STEPS 次。
    -- 布局构建是纯计算，重排无副作用；稳定后 self.scale 记录实际倍率。
    local S = math.min(W, H) / BASE_SHORT
    local body
    for _ = 1, FIT_MAX_STEPS do
        ctx.S = S
        body = landscape and self:buildLandscape(ctx) or self:buildPortrait(ctx)
        local bs = body:getSize()
        if bs.h <= H * FIT_SAFE_RATIO and bs.w <= W then break end
        logger.warn(string.format(
            "dashboard: 内容 %dx%d 超出可用区 %dx%d，缩放至 %.3f 重排", bs.w, bs.h, W, H, S * FIT_STEP))
        S = S * FIT_STEP
    end
    self.scale = S

    local root = InputContainer:new{
        dimen = Geom:new{ w = W, h = H },
    }

    -- 全屏白底：WidgetContainer 不会自动填背景，必须自己刷
    root.paintTo = function(self, bb, x, y)
        bb:paintRect(x, y, W, H, COLOR_WHITE)
        local child = self[1]
        if child then
            local cs = child:getSize()
            child:paintTo(bb,
                x + math.floor((W - cs.w) / 2),
                y + math.floor((H - cs.h) / 2))
        end
    end

    root[1] = CenterContainer:new{
        dimen = Geom:new{ w = W, h = H },
        body,
    }

    root.onTap = function() self:fetchWeather(true) end
    root.onHold = function() self:askExit() end
    -- 只有「当前正在显示的根控件」被外部关掉时才做清理；
    -- refreshLayout 替换旧根时 self.root 已指向新根，这里会直接跳过，
    -- 否则重绘会把刚建好的界面一起关掉（画面变空）。
    local this_root = root
    root.onCloseWidget = function()
        if self.shown and self.root == this_root then
            self:close()
        end
    end

    self.day_key = string.format("%04d%02d%02d", now.year, now.month, now.day)
    return root
end

--- 顶部条：城市 · 时区（左） + 更新时间（右），两端撑满
function Dashboard:buildHeader(ctx, pad_lr)
    local W = ctx.W
    local avail = W - pad_lr * 2
    local left = self:makeText(ctx, string.format("%s · %s", self:getCityName(), ctx.tz.iana), 26,
        { max_width = math.floor(avail * 0.58) })
    local right = self:makeText(ctx, self:updateLabel(ctx), 20,
        { gray = true, max_width = math.floor(avail * 0.38) })
    local fill = math.max(0, avail - left:getSize().w - right:getSize().w)
    return HorizontalGroup:new{
        align = "center",
        mkPad(pad_lr, 1), left, mkPad(fill, 1), right, mkPad(pad_lr, 1),
    }
end

--- 天气块：图标与温度左右并列，压缩纵向占用
function Dashboard:buildWeatherBlock(ctx, icon_px, temp_px)
    local d = self:weatherDisplay()
    local icon = ImageWidget:new{
        file = self:iconPath(d.icon),
        width = math.floor(icon_px * ctx.S),
        height = math.floor(icon_px * ctx.S),
        scale_factor = 0,
        alpha = true,
    }
    local side = VerticalGroup:new{
        align = "left",
        self:makeText(ctx, d.temp, temp_px),
        self:makeText(ctx, d.cond, 28),
        d.feels and self:makeText(ctx, d.feels, 20, { gray = true }) or mkPad(1, 1),
    }
    return HorizontalGroup:new{
        align = "center",
        icon,
        mkPad(math.floor(8 * ctx.S), 1),
        side,
    }
end

--- 底部三格：标签 + 大数值（可带一行小注）
function Dashboard:buildStatCells(ctx, cell_w, items)
    local cells = {}
    for i, it in ipairs(items) do
        if i > 1 then
            cells[#cells + 1] = mkBox(1, math.floor(86 * ctx.S), nil)
        end
        cells[#cells + 1] = mkBox(cell_w, math.floor(86 * ctx.S), VerticalGroup:new{
            align = "center",
            self:makeText(ctx, it[1], 20, { gray = true }),
            mkPad(1, math.floor(6 * ctx.S)),
            self:makeText(ctx, it[2], 34),
            it[3] and self:makeText(ctx, it[3], 18, { gray = true }) or mkPad(1, math.floor(24 * ctx.S)),
        }, { align = "center", auto_h = true })
    end
    return HorizontalGroup:new{ align = "center", unpack(cells) }
end

-- ---------------------------------------------------------------- 竖屏：仪表盘
function Dashboard:buildPortrait(ctx)
    local W, S = ctx.W, ctx.S
    local pad_lr = math.floor(32 * S)
    local content_w = W - pad_lr * 2
    local rows = {}
    local function push(widget) rows[#rows + 1] = widget end

    -- 顶部城市条
    push(self:buildHeader(ctx, pad_lr))
    push(mkPad(W, math.floor(6 * S)))
    push(Solid:new{ dimen = Geom:new{ w = W, h = math.max(2, math.floor(4 * S)) }, color = COLOR_BLACK })
    push(mkPad(W, math.floor(18 * S)))

    -- 时钟与天气左右并列
    self.clock_text = string.format("%02d:%02d", ctx.now.hour, ctx.now.min)
    self.clock_widget = self:makeText(ctx, self.clock_text, 112)
    local date_line = self:makeText(ctx, string.format("%d月%d日 星期%s",
        ctx.now.month, ctx.now.day, Lunar.WEEKDAY_NAMES[ctx.now.wday] or ""), 32)
    local clock_block = VerticalGroup:new{
        align = "left",
        self.clock_widget,
        mkPad(1, math.floor(6 * S)),
        date_line,
    }
    local weather_block = self:buildWeatherBlock(ctx, 84, 56)
    local clock_fill = math.max(math.floor(14 * S),
        content_w - clock_block:getSize().w - weather_block:getSize().w)
    push(HorizontalGroup:new{
        align = "center",
        mkPad(pad_lr, 1),
        clock_block,
        mkPad(clock_fill, 1),
        weather_block,
        mkPad(pad_lr, 1),
    })

    push(mkPad(W, math.floor(16 * S)))
    push(Solid:new{ dimen = Geom:new{ w = W, h = math.max(2, math.floor(3 * S)) }, color = COLOR_BLACK })
    push(mkPad(W, math.floor(14 * S)))

    -- 农历
    push(CenterContainer:new{
        dimen = Geom:new{ w = W, h = math.floor(20 * S * 1.4) },
        self:makeText(ctx, _("农历"), 20, { gray = true }),
    })
    push(mkPad(W, math.floor(2 * S)))
    local lunar_side = VerticalGroup:new{
        align = "left",
        self:makeText(ctx, Lunar.ganzhi_year(ctx.lunar), 30),
        mkPad(1, math.floor(4 * S)),
        self:makeText(ctx, string.format("%s年", Lunar.zodiac(ctx.lunar)), 22, { gray = true }),
    }
    local lunar_big = self:makeText(ctx, Lunar.month_day_text(ctx.lunar), 54)
    local lunar_fill = math.max(math.floor(20 * S),
        content_w - lunar_big:getSize().w - lunar_side:getSize().w)
    push(HorizontalGroup:new{
        align = "center",
        mkPad(pad_lr, 1),
        lunar_big,
        mkPad(lunar_fill, 1),
        lunar_side,
        mkPad(pad_lr, 1),
    })
    push(mkPad(W, math.floor(14 * S)))

    -- 节气：文字 + 进度条 + 两端刻度
    local ratio, elapsed, remain = self:solarTermRatio(ctx)
    local term_text
    if ctx.cur_term.is_today then
        term_text = string.format("%s · 今日交节", ctx.cur_term.name)
    elseif ctx.next_term then
        term_text = string.format("%s 第%d天 · 距%s%d天", ctx.cur_term.name,
            elapsed, ctx.next_term.name, remain)
    else
        term_text = string.format("%s 第%d天", ctx.cur_term.name, elapsed or 1)
    end
    local term_label = self:makeText(ctx, term_text, 26)
    push(HorizontalGroup:new{
        align = "center",
        mkPad(pad_lr, 1),
        term_label,
        mkPad(math.max(0, content_w - term_label:getSize().w), 1),
        mkPad(pad_lr, 1),
    })
    push(mkPad(W, math.floor(10 * S)))
    push(HorizontalGroup:new{
        align = "center",
        mkPad(pad_lr, 1),
        ProgressBar:new{
            dimen = Geom:new{ w = content_w, h = math.max(8, math.floor(10 * S)) },
            ratio = ratio,
            border = math.max(1, math.floor(2 * S)),
        },
    })
    push(mkPad(W, math.floor(8 * S)))

    local left_label = self:makeText(ctx, ctx.cur_term.name, 20, { gray = true })
    local right_label = ctx.next_term
        and self:makeText(ctx, ctx.next_term.name, 20, { gray = true })
        or self:makeText(ctx, "", 20)
    local lw, rw = left_label:getSize().w, right_label:getSize().w
    push(HorizontalGroup:new{
        align = "center",
        mkPad(pad_lr, 1),
        left_label,
        mkPad(math.max(0, content_w - lw - rw), 1),
        right_label,
    })

    push(mkPad(W, math.floor(16 * S)))
    push(Solid:new{ dimen = Geom:new{ w = W, h = math.max(2, math.floor(3 * S)) }, color = COLOR_BLACK })
    push(mkPad(W, math.floor(16 * S)))

    -- 底部三格：湿度 / 风力 / 空气质量
    local d = self:weatherDisplay()
    local air = self:airDisplay()
    push(HorizontalGroup:new{
        align = "center",
        mkPad(pad_lr, 1),
        self:buildStatCells(ctx, math.floor(content_w / 3), {
            { _("湿度"), d.hum or "--" },
            { _("风力"), d.wind or "--", d.wind_dir },
            { "AQI", air.text, air.level },
        }),
    })

    push(mkPad(W, math.floor(14 * S)))
    push(HorizontalGroup:new{
        align = "center",
        mkPad(pad_lr, 1),
        self:makeText(ctx, self.footerText(ctx), 18, { gray = true }),
    })

    return VerticalGroup:new{ align = "left", unpack(rows) }
end

-- ---------------------------------------------------------------- 横屏：上下分区
function Dashboard:buildLandscape(ctx)
    local W, S = ctx.W, ctx.S
    local pad_lr = math.floor(34 * S)
    local rows = {}
    local function push(widget) rows[#rows + 1] = widget end

    push(self:buildHeader(ctx, pad_lr))
    push(mkPad(W, math.floor(4 * S)))
    push(Solid:new{ dimen = Geom:new{ w = W, h = math.max(2, math.floor(4 * S)) }, color = COLOR_BLACK })
    push(mkPad(W, math.floor(8 * S)))

    -- 时钟与日期（左） / 天气（右），中间空白撑开
    self.clock_text = string.format("%02d:%02d", ctx.now.hour, ctx.now.min)
    self.clock_widget = self:makeText(ctx, self.clock_text, 92)
    local date_line = self:makeText(ctx, string.format("%d年%d月%d日 星期%s",
        ctx.now.year, ctx.now.month, ctx.now.day, Lunar.WEEKDAY_NAMES[ctx.now.wday] or ""), 28)
    local clock_block = VerticalGroup:new{
        align = "left",
        self.clock_widget,
        mkPad(1, math.floor(4 * S)),
        date_line,
    }
    local weather = self:buildWeatherBlock(ctx, 78, 60)
    local fill = math.max(0, W - pad_lr * 2 - clock_block:getSize().w - weather:getSize().w)
    push(HorizontalGroup:new{
        align = "center",
        mkPad(pad_lr, 1),
        clock_block,
        mkPad(fill, 1),
        weather,
        mkPad(pad_lr, 1),
    })

    push(mkPad(W, math.floor(8 * S)))
    push(Solid:new{ dimen = Geom:new{ w = W, h = math.max(2, math.floor(3 * S)) }, color = COLOR_BLACK })
    push(mkPad(W, math.floor(8 * S)))

    -- 下半区：左整月日历 / 右农历节气。
    -- 宽度必须由可用空间反推：固定 52*S 的列宽在 300ppi 的 1448px 屏上，
    -- 日历 + 右栏会超出屏幕 40px，右栏被裁掉。
    local avail = W - pad_lr * 2
    local gap = math.floor(24 * S)
    local vline_w = math.max(2, math.floor(3 * S))
    local right_min = math.floor(330 * S)
    local cell_w = math.min(math.floor(52 * S),
        math.floor((avail - right_min - gap * 2 - vline_w) / 7))
    cell_w = math.max(math.floor(34 * S), cell_w)
    local cal_w = cell_w * 7
    local right_w = math.max(math.floor(260 * S), avail - cal_w - gap * 2 - vline_w)

    local calendar = self:buildCalendar(ctx, cell_w)
    local panel = self:buildSidePanel(ctx, right_w)
    local vline_h = math.max(calendar:getSize().h, panel:getSize().h)

    push(HorizontalGroup:new{
        align = "top",
        mkPad(pad_lr, 1),
        calendar,
        mkPad(gap, 1),
        Solid:new{ dimen = Geom:new{ w = vline_w, h = vline_h }, color = COLOR_BLACK },
        mkPad(gap, 1),
        panel,
        mkPad(pad_lr, 1),
    })

    return VerticalGroup:new{ align = "left", unpack(rows) }
end

--- 整月日历：周一起始、跨月补位、今天反白、节气日带点
function Dashboard:buildCalendar(ctx, cell_w)
    local now = ctx.now
    -- 单元格内容为「日号 + 圆点」，约 36 设计单位高，设定值低于此不起作用
    local row_h = math.floor(36 * ctx.S)
    local head_h = math.floor(26 * ctx.S)

    local first = Lunar.days_from_civil(now.year, now.month, 1)
    local ny = (now.month == 12) and (now.year + 1) or now.year
    local nm = (now.month == 12) and 1 or (now.month + 1)
    local month_len = Lunar.days_from_civil(ny, nm, 1) - first
    local wday = (first + 4) % 7 + 1          -- 1=周日 … 7=周六
    local lead = (wday - 2) % 7               -- 周一起始，1 号前要补的格数
    local today_num = Lunar.days_from_civil(now.year, now.month, now.day)

    -- 当月节气：日期 -> 名称
    local terms = {}
    for k = 0, 23 do
        local ty, tm, td = Lunar.solar_term_date(now.year, k, ctx.tz.offset)
        if ty == now.year and tm == now.month then
            terms[td] = Lunar.TERM_NAMES[k + 1]
        end
    end

    local lines = {}
    lines[#lines + 1] = HorizontalGroup:new{
        align = "center",
        self:makeText(ctx, string.format("%d 年 %d 月", now.year, now.month), 22, { gray = true }),
    }
    lines[#lines + 1] = mkPad(1, math.floor(4 * ctx.S))

    -- 表头：一 二 三 四 五 六 日
    local head = { align = "center" }
    for i = 0, 6 do
        local wd = (2 + i - 1) % 7 + 1
        local is_weekend = (wd == 1 or wd == 7)
        head[#head + 1] = mkBox(cell_w, head_h, self:makeText(ctx,
            Lunar.WEEKDAY_NAMES[wd] or "", 18, { gray = is_weekend }))
    end
    lines[#lines + 1] = HorizontalGroup:new(head)

    -- 6 行 × 7 列，共 42 格，不足处留空
    for r = 0, 5 do
        local row = { align = "center" }
        for c = 0, 6 do
            local idx = r * 7 + c
            local daynum = first + idx - lead
            if idx < lead or daynum >= first + month_len then
                -- 前月补位 / 后月补位：跨月显示，用灰字
                local y2, m2, d2 = Lunar.civil_from_days(daynum)
                row[#row + 1] = mkBox(cell_w, row_h, VerticalGroup:new{
                    align = "center",
                    self:makeText(ctx, tostring(d2), 21, { gray = true }),
                    mkPad(1, 1),
                }, { auto_h = true })
            else
                local y2, m2, d2 = Lunar.civil_from_days(daynum)
                local is_today = (daynum == today_num)
                local term = terms[d2]
                local num_text = self:makeText(ctx, tostring(d2), is_today and 23 or 21,
                    { fg = nil })
                if is_today then
                    num_text.fgcolor = COLOR_WHITE
                end
                local stack = VerticalGroup:new{
                    align = "center",
                    num_text,
                    mkPad(1, math.floor(2 * ctx.S)),
                    term
                        and Solid:new{ dimen = Geom:new{ w = math.floor(6 * ctx.S), h = math.floor(6 * ctx.S) }, color = COLOR_BLACK }
                        or mkPad(math.floor(6 * ctx.S), math.floor(6 * ctx.S)),
                }
                row[#row + 1] = mkBox(cell_w, row_h, stack, {
                    bg = is_today and COLOR_BLACK or nil,
                    align = "center",
                    auto_h = true,
                })
            end
        end
        lines[#lines + 1] = HorizontalGroup:new(row)
    end

    lines[#lines + 1] = mkPad(1, math.floor(4 * ctx.S))
    lines[#lines + 1] = HorizontalGroup:new{
        align = "center",
        Solid:new{ dimen = Geom:new{ w = math.floor(10 * ctx.S), h = math.floor(10 * ctx.S) }, color = COLOR_BLACK },
        mkPad(math.floor(6 * ctx.S), 1),
        self:makeText(ctx, _("今天"), 17, { gray = true }),
        mkPad(math.floor(16 * ctx.S), 1),
        Solid:new{ dimen = Geom:new{ w = math.floor(6 * ctx.S), h = math.floor(6 * ctx.S) }, color = COLOR_BLACK },
        mkPad(math.floor(6 * ctx.S), 1),
        self:makeText(ctx, _("节气"), 17, { gray = true }),
    }

    return VerticalGroup:new{ align = "left", unpack(lines) }
end

--- 横屏右栏：农历 / 节气进度 / 天文与空气
-- 横屏纵向只有「短边」那么多（PW3 为 1072px，折合 600 设计单位），
-- 右栏又是下半区里最高的一列，所以这里的字号与间距比竖屏更克制。
function Dashboard:buildSidePanel(ctx, width)
    local S = ctx.S
    local ratio, elapsed, remain = self:solarTermRatio(ctx)
    local d = self:weatherDisplay()
    local air = self:airDisplay()

    local items = {
        align = "left",
        self:makeText(ctx, _("农历"), 18, { gray = true }),
        mkPad(1, math.floor(2 * S)),
        self:makeText(ctx, Lunar.month_day_text(ctx.lunar), 32),
        mkPad(1, math.floor(4 * S)),
        self:makeText(ctx, string.format("%s · %s年", Lunar.ganzhi_year(ctx.lunar),
            Lunar.zodiac(ctx.lunar)), 20, { gray = true }),
        mkPad(1, math.floor(8 * S)),
        Solid:new{ dimen = Geom:new{ w = width, h = 1 }, color = COLOR_GRAY },
        mkPad(1, math.floor(8 * S)),
        self:makeText(ctx, _("节气"), 18, { gray = true }),
        mkPad(1, math.floor(2 * S)),
        self:makeText(ctx, string.format("%s 第%d天", ctx.cur_term.name, elapsed or 1), 26),
        mkPad(1, math.floor(6 * S)),
        ProgressBar:new{
            dimen = Geom:new{ w = math.floor(width * 0.82), h = math.max(8, math.floor(10 * S)) },
            ratio = ratio,
            border = math.max(1, math.floor(2 * S)),
        },
        mkPad(1, math.floor(4 * S)),
        self:makeText(ctx, ctx.next_term
            and string.format("%s%s %d 天", _("距"), ctx.next_term.name, remain)
            or "", 18, { gray = true }),
        mkPad(1, math.floor(8 * S)),
        Solid:new{ dimen = Geom:new{ w = width, h = 1 }, color = COLOR_GRAY },
        mkPad(1, math.floor(8 * S)),
        self:makeText(ctx, _("天文与空气"), 18, { gray = true }),
        mkPad(1, math.floor(3 * S)),
        self:makeText(ctx, string.format("%s %s   %s %s",
            _("日出"), d.sunrise or "--:--", _("日落"), d.sunset or "--:--"), 19),
        mkPad(1, math.floor(4 * S)),
        self:makeText(ctx, string.format("%s   %s AQI %s",
            d.feels or "--", _("空气"), air.text), 19),
    }

    return VerticalGroup:new(items)
end

function Dashboard:footerText(ctx)
    return _("点按刷新 · 长按退出")
end

function Dashboard:askExit()
    UIManager:show(ConfirmBox:new{
        text = _("退出桌面看板？"),
        ok_text = _("退出"),
        cancel_text = _("继续显示"),
        ok_callback = function() self:close() end,
    })
end

-- ------------------------------------------------------------------ 数据换算
--- 风速与风向 -> 风向名（如“东南风”）、风级（数字）
function windLabel(speed_kmh, deg)
    local speed = tonumber(speed_kmh)
    if not speed then return nil, nil end
    local level = 0
    for i = 1, #WIND_LEVEL_BOUNDS do
        if speed >= WIND_LEVEL_BOUNDS[i] then level = i end
    end
    local d = tonumber(deg)
    if not d then return nil, level end
    local idx = math.floor(((d % 360) + 22.5) % 360 / 45) + 1
    return (WIND_DIRS[idx] or "") .. "风", level
end

--- 单项 IAQI（线性插值，HJ 633-2012）
local function calcIAQI(conc, breakpoints)
    if not conc then return nil end
    if conc < 0 then conc = 0 end
    for _, bp in ipairs(breakpoints) do
        if conc <= bp[2] then
            local c_lo, c_hi, i_lo, i_hi = bp[1], bp[2], bp[3], bp[4]
            if c_hi == c_lo then return i_hi end
            return math.floor((i_hi - i_lo) / (c_hi - c_lo) * (conc - c_lo) + i_lo + 0.5)
        end
    end
    return 500
end

--- 综合 AQI 取 PM2.5 与 PM10 的较大项
function Dashboard:calcAQI(pm25, pm10)
    local a = calcIAQI(tonumber(pm25), PM25_BREAKPOINTS)
    local b = calcIAQI(tonumber(pm10), PM10_BREAKPOINTS)
    if a and b then return math.max(a, b) end
    return a or b
end

-- ------------------------------------------------------------------ 网络请求
function Dashboard:httpGet(url)
    local modules = {}
    if url:match("^https") then
        local ok, ssl_https = pcall(require, "ssl.https")
        if ok and ssl_https then
            modules[#modules + 1] = ssl_https
        end
    end
    modules[#modules + 1] = http

    for _, mod in ipairs(modules) do
        local sink = {}
        local req_ok, code = mod.request{
            url = url,
            method = "GET",
            headers = { ["User-Agent"] = "KOReader-Dashboard/2.0" },
            sink = ltn12.sink.table(sink),
        }
        if req_ok == 1 and code == 200 then
            return table.concat(sink)
        end
        logger.warn("dashboard: request failed, http code:", tostring(code))
    end
    return nil
end

function Dashboard:fetchWeather(manual)
    if self.fetching then return end
    self.fetching = true

    -- 离线时不走 runWhenOnline，避免 KOReader 弹出「连接 WiFi」对话框打断看板
    if NetworkMgr.isOnline then
        local called, online = pcall(function() return NetworkMgr:isOnline() end)
        if called and not online then
            self.fetching = false
            if manual then
                UIManager:show(InfoMessage:new{
                    text = _("当前未连接网络。接入 WiFi 后会自动重试。"),
                    timeout = 3,
                })
            end
            if self.shown then self:refreshLayout() end
            return
        end
    end

    local city, tz = self:getCity(), self:getTz()
    local url = string.format(
        "https://api.open-meteo.com/v1/forecast?latitude=%.4f&longitude=%.4f"
        .. "&current=temperature_2m,relative_humidity_2m,apparent_temperature,weather_code"
        .. ",wind_speed_10m,wind_direction_10m"
        .. "&daily=weather_code,temperature_2m_max,temperature_2m_min,sunrise,sunset"
        .. "&timezone=%s&forecast_days=1",
        city.lat, city.lon, tz.iana)

    local air_url = string.format(
        "https://air-quality-api.open-meteo.com/v1/air-quality?latitude=%.4f&longitude=%.4f"
        .. "&current=pm2_5,pm10&timezone=%s",
        city.lat, city.lon, tz.iana)

    NetworkMgr:runWhenOnline(function()
        local ok = false

        local body = self:httpGet(url)
        if body then
            local parsed_ok, data = pcall(JSON.decode, body)
            if parsed_ok and type(data) == "table" and type(data.current) == "table" then
                local cur = data.current
                local daily = type(data.daily) == "table" and data.daily or {}
                local function first(tbl)
                    return type(tbl) == "table" and tbl[1] or nil
                end
                local sunrise, sunset
                if type(first(daily.sunrise)) == "string" then
                    sunrise = first(daily.sunrise):sub(12, 16)
                end
                if type(first(daily.sunset)) == "string" then
                    sunset = first(daily.sunset):sub(12, 16)
                end
                self.weather = {
                    city = city.name,
                    temp = tonumber(cur.temperature_2m),
                    code = tonumber(cur.weather_code),
                    hum = tonumber(cur.relative_humidity_2m),
                    feels = tonumber(cur.apparent_temperature),
                    wind = tonumber(cur.wind_speed_10m),
                    winddir = tonumber(cur.wind_direction_10m),
                    tmax = tonumber(first(daily.temperature_2m_max)),
                    tmin = tonumber(first(daily.temperature_2m_min)),
                    sunrise = sunrise,
                    sunset = sunset,
                    ts = os.time(),
                }
                self.cache:saveSetting("weather", self.weather)
                ok = true
            else
                logger.warn("dashboard: json decode failed")
            end
        end

        -- 空气质量独立请求，失败不影响天气显示
        local air_body = self:httpGet(air_url)
        if air_body then
            local parsed_ok, adata = pcall(JSON.decode, air_body)
            if parsed_ok and type(adata) == "table" and type(adata.current) == "table" then
                local pm25 = tonumber(adata.current.pm2_5)
                local pm10 = tonumber(adata.current.pm10)
                self.air = {
                    pm25 = pm25,
                    pm10 = pm10,
                    aqi = self:calcAQI(pm25, pm10),
                    ts = os.time(),
                }
                self.cache:saveSetting("air", self.air)
                ok = true
            end
        end

        self.cache:flush()

        if manual and not ok then
            UIManager:show(InfoMessage:new{
                text = _("天气更新失败。请确认设备已联网，再点按屏幕重试。"),
                timeout = 4,
            })
        end
        self.fetching = false
        if self.shown then
            self:refreshLayout()
        end
    end)
end

return Dashboard
