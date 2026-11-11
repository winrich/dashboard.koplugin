--[[--
KOReader API 桩 + 插件冒烟测试

目的：本机无法运行真正的 KOReader，用最小可信的桩件执行插件的
init -> 打开 -> 渲染 -> 定时 tick -> 关网刷新 -> 关闭 全流程，
捕获 nil 索引、控件构造错误、尺寸溢出、待机计数不平衡等问题。

桩件严格按 KOReader 真实语义实现关键部分：
  · WidgetContainer:paintTo 不填背景（与真实一致，验证我们自己刷白底）
  · CenterContainer 用 dimen 居中，VerticalGroup 垂直累加高度
  · TextWidget:setText 只改文字，尺寸下次 getSize 时重算
未声明的字段一律为 nil，从而能暴露对不存在 API 的依赖。
--]]

---------------------------------------------------------------- 记录器
local RECORD = {}
local EVENTS = {}

local function log(fmt, ...)
    EVENTS[#EVENTS + 1] = string.format(fmt, ...)
end

---------------------------------------------------------------- 基础类
local Widget = {}
Widget.__index = Widget
function Widget:extend(o)
    o = o or {}
    setmetatable(o, { __index = self })
    o.__index = o
    o.new = self.new
    o.extend = self.extend
    return o
end
function Widget:new(o)
    o = o or {}
    setmetatable(o, self)
    return o
end
function Widget:getSize()
    return self.dimen or { w = 0, h = 0 }
end
function Widget:paintTo() end
function Widget:free() end
function Widget:handleEvent()
    return false
end

local WidgetContainer = Widget:extend{}
function WidgetContainer:getSize()
    if self.dimen then return self.dimen end
    if self[1] then return self[1]:getSize() end
    return { w = 0, h = 0 }
end
function WidgetContainer:paintTo(bb, x, y)
    if not self[1] then return end
    local cs = self[1]:getSize()
    local w = (self.dimen and self.dimen.w) or cs.w
    local h = (self.dimen and self.dimen.h) or cs.h
    if self.align == "center" then
        self[1]:paintTo(bb, x + math.floor((w - cs.w) / 2), y + math.floor((h - cs.h) / 2))
    else
        self[1]:paintTo(bb, x, y)
    end
end
function WidgetContainer:free() end

local InputContainer = WidgetContainer:extend{}

local CenterContainer = WidgetContainer:extend{}
function CenterContainer:getSize()
    return self.dimen
end
-- 真实 CenterContainer 无论 align 取值都会居中，这里保持一致
function CenterContainer:paintTo(bb, x, y)
    if not self[1] then return end
    local cs = self[1]:getSize()
    local dw = (self.dimen and self.dimen.w) or cs.w
    local dh = (self.dimen and self.dimen.h) or cs.h
    self[1]:paintTo(bb,
        x + math.floor((dw - cs.w) / 2),
        y + math.floor((dh - cs.h) / 2))
end

local VerticalGroup = WidgetContainer:extend{}
function VerticalGroup:getSize()
    local w, h = 0, 0
    for _, child in ipairs(self) do
        local cs = child:getSize()
        w = math.max(w, cs.w)
        h = h + cs.h
    end
    return { w = w, h = h }
end
function VerticalGroup:paintTo(bb, x, y)
    local cy = y
    for _, child in ipairs(self) do
        local cs = child:getSize()
        local cx = x
        if self.align == "center" then
            cx = x + math.floor((self:getSize().w - cs.w) / 2)
        end
        child:paintTo(bb, cx, cy)
        cy = cy + cs.h
    end
end

local HorizontalGroup = WidgetContainer:extend{}
function HorizontalGroup:getSize()
    local w, h = 0, 0
    for _, child in ipairs(self) do
        local cs = child:getSize()
        w = w + cs.w
        h = math.max(h, cs.h)
    end
    return { w = w, h = h }
end
function HorizontalGroup:paintTo(bb, x, y)
    local cx = x
    for _, child in ipairs(self) do
        local cs = child:getSize()
        local cy = y
        if self.align == "center" then
            cy = y + math.floor((self:getSize().h - cs.h) / 2)
        end
        child:paintTo(bb, cx, cy)
        cx = cx + cs.w
    end
end

local function text_width(text, size)
    local w, i = 0, 1
    while i <= #text do
        local b = text:byte(i)
        if b < 128 then
            w = w + size * 0.55
            i = i + 1
        elseif b < 224 then
            w = w + size * 0.55
            i = i + 2
        else
            w = w + size * 1.0
            i = i + 3
        end
    end
    return w
end

local TextWidget = Widget:extend{}
function TextWidget:getSize()
    -- 真实 TextWidget 的高度是 getHeightAndAscender() 取整后加 padding，这里同样取整，
    -- 否则 VerticalGroup 累加出的 y 坐标会带小数，与真机行为不符
    return {
        w = math.floor(text_width(tostring(self.text or ""), self.face.size)),
        h = math.floor(self.face.size * 1.35),
    }
end
function TextWidget:paintTo(bb, x, y)
    RECORD[#RECORD + 1] = { kind = "text", text = tostring(self.text or ""), x = x, y = y,
                            w = math.floor(self:getSize().w), h = math.floor(self:getSize().h) }
end
function TextWidget:setText(text)
    if text == self.text then return end
    self.text = text
    self._updated = false
end

local ImageWidget = Widget:extend{}
function ImageWidget:getSize()
    return { w = self.width or 0, h = self.height or 0 }
end
function ImageWidget:paintTo(bb, x, y)
    RECORD[#RECORD + 1] = { kind = "image", text = self.file, x = x, y = y,
                            w = self.width or 0, h = self.height or 0 }
end

local Geom = {}
Geom.__index = Geom
function Geom:new(o)
    o = o or {}
    setmetatable(o, Geom)
    return o
end

local Font = {}
function Font:getFace(name, size)
    return { name = name, size = size }
end

---------------------------------------------------------------- 桩件模块
local UIManager = {}
local stack = {}
local timers = {}
local standby = 0

local fake_bb = {}
function fake_bb:paintRect(x, y, w, h, color)
    RECORD[#RECORD + 1] = { kind = "rect", x = x, y = y, w = w, h = h, color = color }
end
-- 节气进度条的外框走 paintBorder
function fake_bb:paintBorder(x, y, w, h, bw, color)
    RECORD[#RECORD + 1] = { kind = "border", x = x, y = y, w = w, h = h, color = color }
end

function UIManager:show(widget)
    table.insert(stack, widget)
    if widget.paintTo then widget:paintTo(fake_bb, 0, 0) end
end

function UIManager:close(widget)
    for i = #stack, 1, -1 do
        if stack[i] == widget then table.remove(stack, i) end
    end
    if widget.onCloseWidget then widget:onCloseWidget() end
end

function UIManager:setDirty(widget, mode)
    log("setDirty mode=%s", tostring(mode))
    if widget and widget.paintTo then widget:paintTo(fake_bb, 0, 0) end
end

function UIManager:scheduleIn(delay, fn)
    timers[#timers + 1] = { delay = delay, fn = fn }
end

function UIManager:unschedule(fn)
    for i = #timers, 1, -1 do
        if timers[i].fn == fn then table.remove(timers, i) end
    end
end

function UIManager:preventStandby() standby = standby + 1 end
function UIManager:allowStandby() standby = standby - 1 end
function UIManager:askForRestart() end

local weather_store = {
    current = {
        temperature_2m = 12.4,
        relative_humidity_2m = 45,
        apparent_temperature = 10.1,
        weather_code = 3,
        wind_speed_10m = 8.2,
        wind_direction_10m = 135,
    },
    daily = {
        temperature_2m_max = { 16.2 },
        temperature_2m_min = { 4.8 },
        sunrise = { "2026-11-11T06:52" },
        sunset = { "2026-11-11T16:58" },
    },
}

local air_store = {
    current = { pm2_5 = 28.4, pm10 = 46.0 },
}

local JSON = {}
function JSON.decode(s)
    if type(s) == "string" and s:find('"air"', 1, true) then return air_store end
    return weather_store
end

local ltn12 = {}
ltn12.sink = {}
function ltn12.sink.table(t)
    return function(chunk)
        if chunk then t[#t + 1] = chunk end
        return 1
    end
end

local http = {}
function http.request(req)
    -- 空气质量走独立域名，返回不同的标记体，让 JSON 桩分流
    local body = '{"weather":true}'
    if req.url and req.url:find("air%-quality") then
        body = '{"air":true}'
    end
    if req.sink then req.sink(body) end
    return 1, 200, {}, "HTTP/1.1 200 OK"
end

local NetworkMgr = {}
function NetworkMgr:runWhenOnline(fn) fn() end

local store = {}
local G_settings = {}
function G_settings:readSetting(k, d) return store[k] or d end
function G_settings:saveSetting(k, v) store[k] = v end
function G_settings:isTrue(k) return store[k] == true end
function G_settings:nilOrTrue(k) return store[k] ~= false end

local LuaSettings = {}
LuaSettings.__index = LuaSettings
function LuaSettings:open(path)
    return setmetatable({ path = path, data = {} }, LuaSettings)
end
function LuaSettings:readSetting(k, d) return self.data[k] or d end
function LuaSettings:saveSetting(k, v) self.data[k] = v; return self end
function LuaSettings:flush() return self end
function LuaSettings:has(k) return self.data[k] ~= nil end

local DataStorage = {}
function DataStorage:getSettingsDir() return "/tmp/settings" end

-- 屏幕尺寸由外部注入，用于分别验证竖屏与横屏版式
local SW = tonumber(_G.STUB_W) or 600
local SH = tonumber(_G.STUB_H) or 800

local screen = {
    getWidth = function() return SW end,
    getHeight = function() return SH end,
}
local Device = {}
Device.screen = screen
function Device:isKindle() return true end

local logger = {}
for _, lvl in ipairs({ "dbg", "info", "warn", "err" }) do
    logger[lvl] = function(...) end
end

local ConfirmBox = Widget:extend{}
local InfoMessage = Widget:extend{}

---------------------------------------------------------------- 模块注册
package.preload["ffi/blitbuffer"] = function()
    return { COLOR_WHITE = 0, COLOR_BLACK = 255, COLOR_DARK_GRAY = 0x55 }
end
package.preload["ui/widget/widget"] = function() return Widget end
package.preload["ui/widget/container/widgetcontainer"] = function() return WidgetContainer end
package.preload["ui/widget/container/inputcontainer"] = function() return InputContainer end
package.preload["ui/widget/container/centercontainer"] = function() return CenterContainer end
package.preload["ui/widget/horizontalgroup"] = function() return HorizontalGroup end
package.preload["ui/widget/verticalgroup"] = function() return VerticalGroup end
package.preload["ui/widget/textwidget"] = function() return TextWidget end
package.preload["ui/widget/imagewidget"] = function() return ImageWidget end
package.preload["ui/widget/confirmbox"] = function() return ConfirmBox end
package.preload["ui/widget/infomessage"] = function() return InfoMessage end
package.preload["ui/geometry"] = function() return Geom end
package.preload["ui/font"] = function() return Font end
package.preload["ui/uimanager"] = function() return UIManager end
package.preload["ui/network/manager"] = function() return NetworkMgr end
package.preload["json"] = function() return JSON end
package.preload["socket.http"] = function() return http end
package.preload["ltn12"] = function() return ltn12 end
package.preload["luasettings"] = function() return LuaSettings end
package.preload["datastorage"] = function() return DataStorage end
package.preload["device"] = function() return Device end
package.preload["logger"] = function() return logger end
package.preload["gettext"] = function()
    return function(s) return s end
end

_G.G_reader_settings = G_settings
_G.unpack = _G.unpack or table.unpack

-- 记录 os.execute，避免真的去调 lipc
local real_execute = os.execute
os.execute = function(cmd)
    RECORD[#RECORD + 1] = { kind = "exec", text = cmd }
    return 0
end

---------------------------------------------------------------- 执行测试
local plugin_dir = arg and arg[1] or "dashboard.koplugin"
package.path = plugin_dir .. "/?.lua;" .. package.path

local plugin = assert(loadfile(plugin_dir .. "/main.lua"))()
EVENTS[#EVENTS + 1] = "== 插件加载成功 =="

local instance = plugin:new{}
instance.path = plugin_dir
instance.ui = { menu = { registerToMainMenu = function() end } }

local ok, err = pcall(function() instance:init() end)
if not ok then
    print("init 失败: " .. tostring(err))
    os.exit(1)
end
EVENTS[#EVENTS + 1] = "== init() 通过 =="

-- 菜单结构
local menu_items = {}
instance:addToMainMenu(menu_items)
local desk = menu_items.dashboard_desk
local city_menu, tz_menu = nil, nil
for _, item in ipairs(desk.sub_item_table) do
    if item.text == "选择城市" then city_menu = item end
    if item.text == "选择时区" then tz_menu = item end
end
local city_count = 0
for _, g in ipairs(city_menu.sub_item_table) do
    city_count = city_count + #g.sub_item_table
end
EVENTS[#EVENTS + 1] = string.format("== 菜单：城市 %d 个（分组 %d），时区 %d 个 ==",
    city_count, #city_menu.sub_item_table, #tz_menu.sub_item_table)

-- 打开看板（含渲染与天气请求）
RECORD = {}
ok, err = pcall(function() instance:open() end)
if not ok then
    print("open 失败: " .. tostring(err))
    os.exit(1)
end
EVENTS[#EVENTS + 1] = "== open() 通过 =="
EVENTS[#EVENTS + 1] = string.format("== 待机抑制计数 = %d，激活的定时器 = %d ==", standby, #timers)

-- 渲染结果（文本层）
print("---------- 渲染出的文本行 ----------")
local rows = {}
for _, r in ipairs(RECORD) do
    if r.kind == "text" then
        rows[#rows + 1] = r
    elseif r.kind == "image" then
        print(string.format("[图标] x=%d y=%d %dx%d  %s", r.x, r.y, r.w, r.h, r.text))
    elseif r.kind == "rect" then
        print(string.format("[底图] %dx%d color=%s", r.w, r.h, tostring(r.color)))
    elseif r.kind == "exec" then
        print("[系统调用] " .. r.text)
    end
end
for _, r in ipairs(rows) do
    print(string.format("[文本] x=%-4d y=%-4d w=%-4d h=%-3d  %s",
        math.floor(r.x), math.floor(r.y), math.floor(r.w), math.floor(r.h), r.text))
end

-- 检查总高度是否溢出屏幕
local group = instance.root[1][1]
local gs = group:getSize()
local overflow = (gs.h > SH + 1) or (gs.w > SW + 1)
if overflow then
    print(string.format("[FAIL] 内容 %dx%d 超出屏幕 %dx%d", math.floor(gs.w), math.floor(gs.h), SW, SH))
    os.exit(1)
end
EVENTS[#EVENTS + 1] = string.format(
    "== 内容总尺寸 %dx%d（屏幕 %dx%d），水平余量 %d px，垂直余量 %d px ==",
    math.floor(gs.w), math.floor(gs.h), SW, SH,
    SW - math.floor(gs.w), SH - math.floor(gs.h))

-- 模拟跨分钟 tick
local texts_before = RECORD[#RECORD]
instance:tick()
EVENTS[#EVENTS + 1] = string.format("== tick() 通过，时钟控件文本 = %s，定时器 = %d ==",
    instance.clock_widget.text, #timers)

-- 模拟手动刷新
ok, err = pcall(function() instance:fetchWeather(true) end)
if not ok then
    print("fetchWeather 失败: " .. tostring(err))
    os.exit(1)
end
EVENTS[#EVENTS + 1] = string.format("== fetchWeather() 通过，温度 %.1f，天气码 %d ==",
    instance.weather.temp, instance.weather.code)
local shown = instance:weatherDisplay()
EVENTS[#EVENTS + 1] = string.format("== 风力 %s，日出 %s，日落 %s ==",
    tostring(shown.wind), tostring(shown.sunrise), tostring(shown.sunset))
EVENTS[#EVENTS + 1] = string.format("== 空气质量 AQI = %s（PM2.5 %.1f，PM10 %.1f）==",
    tostring(instance.air and instance.air.aqi),
    tonumber(instance.air and instance.air.pm25) or -1,
    tonumber(instance.air and instance.air.pm10) or -1)

-- 关闭，检查状态恢复
ok, err = pcall(function() instance:close() end)
if not ok then
    print("close 失败: " .. tostring(err))
    os.exit(1)
end
EVENTS[#EVENTS + 1] = string.format("== close() 通过，待机抑制计数 = %d，定时器 = %d，widget 栈 = %d ==",
    standby, #timers, #stack)

print("---------- 事件序列 ----------")
for _, e in ipairs(EVENTS) do print(e) end

if standby ~= 0 then
    print("\n[FAIL] 待机抑制计数未归零，会导致系统一直不休眠")
    os.exit(1)
end
print("\n[PASS] 冒烟测试全部通过")
