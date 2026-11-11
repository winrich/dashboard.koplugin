--[[--
桌面看板（dashboard.koplugin）

全屏常驻显示：
  · 时钟（分钟级刷新，不走秒，避免电子墨水屏残影）
  · 公历日期与星期
  · 农历日期、干支、生肖
  · 当前节气与距下一节气天数
  · 当日天气（图标 + 温度 + 天气现象 + 最高/最低温 + 湿度）

可配置：34 个城市（直辖市 / 省会 / 港澳台）、10 个时区。
数据源：Open-Meteo（免注册、免 API Key）。

交互：
  · 点按屏幕      -> 立即刷新天气
  · 长按屏幕      -> 退出看板

设计要点（均已按 KOReader 源码核对，非猜测）：
  · WidgetContainer:paintTo 不处理 background，白底必须自己刷，否则透出下层界面
  · TextWidget 支持 setText() 做分钟级局部更新，避免整屏重建
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

-- 插件自身目录（icons 相对此目录）
local PLUGIN_DIR = (function()
    local src = (debug.getinfo(1, "S").source or ""):gsub("^@", "")
    return src:match("^(.*)[/\\][^/\\]+$") or "."
end)()

local UPDATE_INTERVAL = 30 * 60      -- 天气拉取间隔
local FULL_REFRESH_PERIOD = 30       -- 每 30 分钟全刷一次清残影

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

local Dashboard = WidgetContainer:extend{
    name = "dashboard",
    is_doc_only = false,
}

-- ------------------------------------------------------------------ 生命周期
function Dashboard:init()
    self.cache = LuaSettings:open(DataStorage:getSettingsDir() .. "/dashboard_cache.lua")
    local cached = self.cache:readSetting("weather")
    if type(cached) == "table" then
        self.weather = cached
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
                text = _("点按屏幕刷新天气，长按屏幕退出看板。\n\n长时间显示建议接通电源；程序每 30 分钟自动全刷一次以清除电泳残影。"),
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

    -- 跨日：日期/农历/节气全部要重算
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

-- ------------------------------------------------------------------ 界面构建
function Dashboard:iconPath(name)
    local dir = self.path or PLUGIN_DIR
    return dir .. "/icons/" .. name .. ".png"
end

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

function Dashboard:createRoot()
    local W, H = Screen:getWidth(), Screen:getHeight()
    local S = W / 600
    local now = self:localNow()
    local tz = self:getTz()
    local lunar = Lunar.solar_to_lunar(now.year, now.month, now.day)
    local cur_term, next_term = Lunar.current_term(now.year, now.month, now.day, tz.offset)

    local function sized(px)
        return math.max(11, math.floor(px * S))
    end

    local rows = {}
    local function addRow(height, widget)
        rows[#rows + 1] = CenterContainer:new{
            dimen = Geom:new{ w = W, h = math.max(1, math.floor(height)) },
            widget,
        }
    end

    -- 城市 · 时区
    addRow(H * 0.072, TextWidget:new{
        text = string.format("%s · %s", self:getCityName(), tz.name),
        face = Font:getFace("cfont", sized(24)),
        padding = 0,
        max_width = W - 40,
    })

    -- 时钟
    self.clock_text = string.format("%02d:%02d", now.hour, now.min)
    self.clock_widget = TextWidget:new{
        text = self.clock_text,
        face = Font:getFace("cfont", sized(W * 0.205)),
        padding = 0,
    }
    addRow(H * 0.268, self.clock_widget)

    -- 公历日期
    addRow(H * 0.066, TextWidget:new{
        text = string.format("%d年%d月%d日 星期%s", now.year, now.month, now.day,
            Lunar.WEEKDAY_NAMES[now.wday] or ""),
        face = Font:getFace("cfont", sized(30)),
        padding = 0,
    })

    -- 农历
    addRow(H * 0.062, TextWidget:new{
        text = string.format("农历%s · %s", Lunar.lunar_text(lunar), Lunar.zodiac(lunar)),
        face = Font:getFace("cfont", sized(27)),
        padding = 0,
    })

    -- 节气
    local term_text
    if cur_term.is_today then
        term_text = string.format("%s · 今日交节", cur_term.name)
    elseif next_term then
        term_text = string.format("%s 第%d天 · 距%s%d天", cur_term.name, cur_term.elapsed,
            next_term.name, next_term.in_days)
    else
        term_text = string.format("%s 第%d天", cur_term.name, cur_term.elapsed)
    end
    addRow(H * 0.058, TextWidget:new{
        text = term_text,
        face = Font:getFace("cfont", sized(24)),
        padding = 0,
    })

    -- 天气
    addRow(H * 0.278, self:createWeatherRow(S, W))

    -- 底部状态
    addRow(H * 0.052, TextWidget:new{
        text = self:footerText(tz),
        face = Font:getFace("cfont", sized(17)),
        padding = 0,
        max_width = W - 40,
    })

    local root = InputContainer:new{
        dimen = Geom:new{ w = W, h = H },
    }

    -- 全屏白底：WidgetContainer 不会自动填背景，必须自己刷
    root.paintTo = function(self, bb, x, y)
        bb:paintRect(x, y, W, H, Blitbuffer.COLOR_WHITE)
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
        VerticalGroup:new{
            align = "center",
            unpack(rows),
        },
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

function Dashboard:createWeatherRow(S, W)
    local icon_size = math.floor(W * 0.185)
    local icon_name, cond_text = "partly", _("暂无数据")
    local temp_text = "--°"
    local detail_text = ""

    local w = self.weather
    if w and w.code then
        local meta = WEATHER_CODES[w.code]
        if meta then
            cond_text = _(meta[1])
            icon_name = meta[2]
        else
            cond_text = _("未知天气")
        end
        if w.temp then
            temp_text = string.format("%d°", math.floor(w.temp + 0.5))
        end
        local parts = {}
        if w.tmin and w.tmax then
            parts[#parts + 1] = string.format("%d° / %d°",
                math.floor(w.tmin + 0.5), math.floor(w.tmax + 0.5))
        end
        if w.hum then
            parts[#parts + 1] = string.format("%s %d%%", _("湿度"), math.floor(w.hum + 0.5))
        end
        detail_text = table.concat(parts, "   ")
    end

    local icon = ImageWidget:new{
        file = self:iconPath(icon_name),
        width = icon_size,
        height = icon_size,
        scale_factor = 0,
        alpha = true,
    }

    local text_stack = VerticalGroup:new{
        align = "center",
        TextWidget:new{
            text = temp_text,
            face = Font:getFace("cfont", math.max(11, math.floor(58 * S))),
            padding = 0,
        },
        TextWidget:new{
            text = cond_text,
            face = Font:getFace("cfont", math.max(11, math.floor(26 * S))),
            padding = 0,
        },
        TextWidget:new{
            text = detail_text,
            face = Font:getFace("cfont", math.max(11, math.floor(21 * S))),
            padding = 0,
        },
    }

    return HorizontalGroup:new{
        align = "center",
        icon,
        Widget:new{ dimen = Geom:new{ w = math.max(1, math.floor(34 * S)), h = 1 } },
        text_stack,
    }
end

function Dashboard:footerText(tz)
    local stamp
    if self.weather and self.weather.ts then
        stamp = os.date("!%H:%M", self.weather.ts + tz.offset * 60)
    end
    if stamp then
        return string.format("%s %s · %s", _("更新于"), stamp, _("点按刷新 · 长按退出"))
    end
    return _("尚未获取天气 · 点按刷新 · 长按退出")
end

function Dashboard:askExit()
    UIManager:show(ConfirmBox:new{
        text = _("退出桌面看板？"),
        ok_text = _("退出"),
        cancel_text = _("继续显示"),
        ok_callback = function() self:close() end,
    })
end

-- ------------------------------------------------------------------ 天气请求
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
            headers = { ["User-Agent"] = "KOReader-Dashboard/1.0" },
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
        .. "&current=temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m"
        .. "&daily=weather_code,temperature_2m_max,temperature_2m_min"
        .. "&timezone=%s&forecast_days=1",
        city.lat, city.lon, tz.iana)

    NetworkMgr:runWhenOnline(function()
        local body = self:httpGet(url)
        local ok = false
        if body then
            local parsed_ok, data = pcall(JSON.decode, body)
            if parsed_ok and type(data) == "table" and type(data.current) == "table" then
                local cur = data.current
                local daily = type(data.daily) == "table" and data.daily or {}
                self.weather = {
                    city = city.name,
                    temp = tonumber(cur.temperature_2m),
                    code = tonumber(cur.weather_code),
                    hum = tonumber(cur.relative_humidity_2m),
                    feels = tonumber(cur.apparent_temperature),
                    wind = tonumber(cur.wind_speed_10m),
                    tmax = daily.temperature_2m_max and tonumber(daily.temperature_2m_max[1]),
                    tmin = daily.temperature_2m_min and tonumber(daily.temperature_2m_min[1]),
                    ts = os.time(),
                }
                self.cache:saveSetting("weather", self.weather)
                self.cache:flush()
                ok = true
            else
                logger.warn("dashboard: json decode failed")
            end
        end

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
