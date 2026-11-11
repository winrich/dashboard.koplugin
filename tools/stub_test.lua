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
-- 真实实现会把触摸区编译进 DepGraph 并按依赖排序；桩件只需按下标保存，
-- 测试据此确认「点按刷新 / 上划退出」两个区真的注册上了
function InputContainer:registerTouchZones(zones)
    self._zones = self._zones or {}
    for _, z in ipairs(zones) do
        self._zones[#self._zones + 1] = z
    end
end

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
    -- 否则 VerticalGroup 累加出的 y 坐标会带小数，与真机行为不符。
    -- max_width 必须实现：真机超宽会折成多行（宽度收到 max_width、高度按行数增），
    -- 桩件若不折行，就测不出“长文本靠折行兜住版心”这条防线。
    local size = self.face.size
    local nat = text_width(tostring(self.text or ""), size)
    local mw = self.max_width
    local w, lines = nat, 1
    if mw and mw > 0 and nat > mw then
        w = mw
        lines = math.ceil(nat / mw)
    end
    return {
        w = math.floor(w),
        -- 1.363 是真机实测值：getFace("cfont",100) 返回 size=179 时
        -- TextWidget 高 244（179 * 1.363）。桩件原先按 1.35 估算，系统性偏小 1%。
        h = math.floor(size * 1.363) * lines,
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

-- 真机 Font:getFace 内部会调 Screen:scaleBySize()（frontend/ui/font.lua:276），
-- 其实现是 ceil(px * min(屏宽,屏高) / 600)。桩件必须照做，否则会低估字号 1.79 倍。
-- 实测对照：真机上 getFace("cfont", 100) 返回 face.size = 179（PW3 1072x1448）。
local Font = {}
function Font:getFace(name, size)
    local scale = math.min(_G.STUB_W or 600, _G.STUB_H or 800) / 600
    return { name = name, size = math.ceil((size or 0) * scale) }
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

-- 机器可读的最终帧导出，供 tools/render_preview.py 还原版面
local instance        -- 前置声明：dump_frame 是闭包，必须在此之前可见
local function dump_frame()
    RECORD = {}
    instance.root:paintTo(fake_bb, 0, 0)
    for _, r in ipairs(RECORD) do
        local tag = ({ text = "T", rect = "R", border = "B", image = "I" })[r.kind]
        if tag then
            print(string.format("FRAME|%s|%d|%d|%d|%d|%d|%s", tag,
                math.floor(r.x or 0), math.floor(r.y or 0), math.floor(r.w or 0),
                math.floor(r.h or 0), math.floor(r.color or 0), tostring(r.text or "")))
        end
    end
    print("FRAME|END")
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
-- 休眠屏保渲染后要同步刷完再挂起（真机拦的是 _repaint）
function UIManager:forceRePaint() end
function UIManager:askForRestart() end
-- 上划退出的关闭动作被推迟到 nextTick，桩件里直接同步执行
function UIManager:nextTick(fn) fn() end

-- 真实和风天气响应样本（2026-11-11 北京实测抓取的字段结构，数值保持原样）。
-- 三个接口各一份，用来验证「gzip -> 解压 -> JSON 解析 -> 展示字段」整条链路。
local QW_SAMPLES = {
    -- /weather/v1/current/
    ['current'] = '{"condition":{"text":"晴","code":"100"},'
        .. '"temperature":{"value":13.19,"unit":"\194\176C"},'
        .. '"feelsLike":{"value":10.16,"unit":"\194\176C"},'
        .. '"humidity":0.44,'
        .. '"wind":{"direction":{"degree":185,"compass":"s"},'
        .. '"speed":{"value":3.38,"unit":"m/s"},"scale":2}}',
    -- /weather/v1/daily/（localTime=true，时间带 +08:00）
    ['daily'] = '{"days":[{"astro":{"sunrise":"2026-11-11T06:54+08:00",'
        .. '"sunset":"2026-11-11T17:02+08:00"},'
        .. '"temperatureMax":{"value":14.1,"unit":"\194\176C"},'
        .. '"temperatureMin":{"value":0.56,"unit":"\194\176C"}}]}',
    -- /airquality/v1/current/（国标 AQI 65，PM2.5 42 / PM10 70）
    ['air'] = '{"indexes":[{"code":"cn-mee","name":"AQI (CN)","aqi":65,'
        .. '"category":"\232\137\175"}],'
        .. '"pollutants":[{"code":"pm2p5","concentration":{"value":42.0}},'
        .. '{"code":"pm10","concentration":{"value":70.0}}]}',
}

-- Lua <-> Python 之间只传 ASCII 的 hex，避免二进制被 UTF-8 转码破坏
local function bytes_to_hex(s)
    return (s:gsub(".", function(c) return string.format("%02x", string.byte(c)) end))
end
local function hex_to_bytes(h)
    return (h:gsub("%x%x", function(cc) return string.char(tonumber(cc, 16)) end))
end

local JSON = {}
function JSON.decode(s)
    if PY_JSON_LOADS then return PY_JSON_LOADS(s) end
    return {}
end

local ltn12 = {}
ltn12.sink = {}
function ltn12.sink.table(t)
    return function(chunk)
        if chunk then t[#t + 1] = chunk end
        return 1
    end
end

-- Open-Meteo 降级样本（2026-11-11 北京实测抓取，明文不压缩——正好也验证明文直通分支）
local OM_SAMPLES = {
    forecast = '{"current":{"temperature_2m":10.0,"relative_humidity_2m":74,'
        .. '"apparent_temperature":8.2,"weather_code":0,"wind_speed_10m":4.5,'
        .. '"wind_direction_10m":185},'
        .. '"daily":{"temperature_2m_max":[11.2],"temperature_2m_min":[1.2],'
        .. '"sunrise":["2026-11-10T22:54"],"sunset":["2026-11-11T09:01"]}}',
    air = '{"current":{"pm10":111.5,"pm2_5":108.7}}',
}

-- 服务端强制 gzip，桩件也照做：返回真实压缩字节，而不是明文 JSON
local http = {}
function http.request(req)
    local url = req.url or ""
    local body, plain
    if url:find("air%-quality%-api%.") then
        body, plain = OM_SAMPLES.air, true
    elseif url:find("api%.open%-meteo%.") then
        body, plain = OM_SAMPLES.forecast, true
    elseif url:find("/weather/v1/current/") then
        -- _G.STUB_QW_FAIL 用来模拟和风整体不可用，验证降级路径
        body = _G.STUB_QW_FAIL and '{"error":{"title":"Service Unavailable"}}' or QW_SAMPLES.current
    elseif url:find("/weather/v1/daily/") then
        body = _G.STUB_QW_FAIL and '{}' or QW_SAMPLES.daily
    elseif url:find("/airquality/v1/current/") then
        body = _G.STUB_QW_FAIL and '{}' or QW_SAMPLES.air
    else
        body = '{"error":{"title":"Not Found"}}'
    end
    if not plain and PY_GZIP_HEX then body = hex_to_bytes(PY_GZIP_HEX(body)) end
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
function G_settings:flush() return self end

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

-- 屏幕尺寸由外部注入。STUB_W/STUB_H 始终是**原生竖屏**尺寸（真机 1072x1448），
-- STUB_START_ROTATION 表示 KOReader 启动时已经转到的方向（0=正立，奇数=宽高互换）。
local SW = tonumber(_G.STUB_W) or 600
local SH = tonumber(_G.STUB_H) or 800

-- 旋转支持：真机上 Screen:setRotationMode 会旋转 blitbuffer，旋转后 getWidth/getHeight
-- 互换（ffi/framebuffer.lua:454 -> bb:rotateAbsolute）。桩件照此实现，才能验证
-- 「左右滑动 -> 转屏 -> 版式跟着换」这条真实路径。
-- STUB_NO_ROTATION=1 时去掉这两个接口，用来验证「转不了就只换版式」的兜底分支。
local rotation = tonumber(_G.STUB_START_ROTATION) or 0
local screen = {
    getWidth = function() return (rotation % 2 == 1) and SH or SW end,
    getHeight = function() return (rotation % 2 == 1) and SW or SH end,
}
if not _G.STUB_NO_ROTATION then
    screen.getRotationMode = function() return rotation end
    screen.setRotationMode = function(_, mode) rotation = tonumber(mode) or 0 end
end
local Device = {}
Device.screen = screen
Device.screen_saver_mode = false     -- 真机 generic/device.lua 的同名字段
Device.canSuspend = true
function Device:isKindle() return true end

-- 屏保桩：真机上 Screensaver:show() 负责画屏保，看板插件会接管这两个入口。
-- 这里如实实现 show/close 的语义，才能验证「休眠画看板 / 唤醒撤掉并重绘」。
-- close() 在没建过 widget 时返回 nil（真机 screensaver.lua:713 的行为），
-- 看板接管的场合要改成返回 true，否则 outofScreenSaver 不会做全屏重绘。
local Screensaver = {}
function Screensaver:show()
    Device.screen_saver_mode = true
end
function Screensaver:close()
    Device.screen_saver_mode = false
    return nil
end

-- 照抄 Kindle:intoScreenSaver / outofScreenSaver 的关键分支
local function stub_sleep()
    if not Device.screen_saver_mode then
        Screensaver:show()
    end
end
local function stub_wake()
    if Device.screen_saver_mode then
        local widget_was_closed = Screensaver:close()
        if widget_was_closed then
            UIManager:setDirty(nil, "full")
        end
    end
end

-- 电量桩：真机上对应 powerd 的 battLevel / isCharging
local powerd = { capacity = 78, charging = false }
function powerd:getCapacity() return self.capacity end
function powerd:isCharging() return self.charging end
function Device:getPowerDevice() return powerd end
_G.STUB_POWERD = powerd

-- GestureRange / DepGraph 桩：registerTouchZones 内部要用，桩件里不需要真正的几何匹配
local GestureRange = {}
function GestureRange:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end
function GestureRange:match() return true end

local DepGraph = {}
function DepGraph:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    o.nodes = {}
    return o
end
function DepGraph:addNode(id) self.nodes[#self.nodes + 1] = id end
function DepGraph:addNodeDep() end
function DepGraph:removeNode(id)
    for i, v in ipairs(self.nodes) do
        if v == id then table.remove(self.nodes, i) break end
    end
end
function DepGraph:serialize() return self.nodes end

-- STUB_VERBOSE=1 时把插件自己的日志打出来（排查自动缩放用）
local logger = {}
for _, lvl in ipairs({ "dbg", "info", "warn", "err" }) do
    logger[lvl] = function(...)
        if _G.STUB_VERBOSE then print("[log:" .. lvl .. "]", ...) end
    end
end

local ConfirmBox = Widget:extend{}
local InfoMessage = Widget:extend{}

-- TouchMenu 桩：记录构造参数，供断言检查「顶部下滑是否弹出菜单」
-- 真实 TouchMenu 没有 title，菜单项在 tab_item_table[1] 的数组部分
local MENU_SHOWN = nil
local TouchMenu = Widget:extend{}
function TouchMenu:new(args)
    local o = setmetatable({}, TouchMenu)
    o.tab = args.tab_item_table and args.tab_item_table[1]
    o.item_count = o.tab and #o.tab or 0
    o.close_callback = args.close_callback
    MENU_SHOWN = o
    return o
end

-- InputDialog 桩：只保存构造参数，测试不弹键盘
local InputDialog = Widget:extend{}
function InputDialog:getInputText() return self.input or "" end
function InputDialog:onShowKeyboard() end

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
package.preload["ui/widget/inputdialog"] = function() return InputDialog end
package.preload["ui/widget/touchmenu"] = function() return TouchMenu end
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
package.preload["ui/screensaver"] = function() return Screensaver end
package.preload["logger"] = function() return logger end
package.preload["ui/gesturerange"] = function() return GestureRange end
package.preload["depgraph"] = function() return DepGraph end
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

-- 桩件环境没有 ffi，dashboard_qweather 的 libz 解压走不通：
-- 1) 先验证非 gzip 数据原样返回（这条分支不碰 ffi）
-- 2) 再把解压换成 Python 的 zlib，让后续请求走真实 gzip 路径
local QW = require("dashboard_qweather")
local passthrough = QW.gunzip('{"a":1}')
if passthrough ~= '{"a":1}' then
    print("[FAIL] 非 gzip 数据没有原样返回")
    os.exit(1)
end
if not PY_GUNZIP_HEX then
    print("[FAIL] 缺少 PY_GUNZIP_HEX 桥接，无法验证 gzip 解压链路")
    os.exit(1)
end
QW.gunzip = function(data)
    if type(data) ~= "string" or #data < 2 then return data end
    if data:byte(1) ~= 0x1f or data:byte(2) ~= 0x8b then return data end
    local out = PY_GUNZIP_HEX(bytes_to_hex(data))
    if out then return out end
    return nil, "python gunzip 失败"
end
EVENTS[#EVENTS + 1] = "== gzip 解压链路已接管（非 gzip 直通分支已验证）=="

instance = plugin:new{}
instance.path = plugin_dir
instance.ui = { menu = { registerToMainMenu = function() end } }
-- 版式方向可以由外部强制（验证「竖屏屏幕跑横屏版式」这类不匹配组合）
if _G.STUB_FORCE_LAYOUT == "landscape" then
    instance.force_landscape = true
elseif _G.STUB_FORCE_LAYOUT == "portrait" then
    instance.force_landscape = false
end

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
local city_menu, tz_menu, weather_menu = nil, nil, nil
for _, item in ipairs(desk.sub_item_table) do
    if item.text == "选择城市" then city_menu = item end
    if item.text == "选择时区" then tz_menu = item end
    if item.text == "天气服务" then weather_menu = item end
end
local city_count = 0
for _, g in ipairs(city_menu.sub_item_table) do
    city_count = city_count + #g.sub_item_table
end
if not weather_menu then
    print("[FAIL] 菜单里没有「天气服务」入口")
    os.exit(1)
end
EVENTS[#EVENTS + 1] = string.format(
    "== 菜单：城市 %d 个（分组 %d），时区 %d 个，天气服务 %d 项 ==",
    city_count, #city_menu.sub_item_table, #tz_menu.sub_item_table,
    #weather_menu.sub_item_table)

-- 凭据来源与脱敏显示
local cfg = instance:getConfig()
EVENTS[#EVENTS + 1] = string.format("== 凭据：host=%s key=%s 来源=%s ==",
    cfg.qweather.api_host, QW.mask(cfg.qweather.api_key), tostring(cfg._key_source))
if cfg.qweather.api_host == "" or cfg.qweather.api_key == "" then
    print("[FAIL] 没有读到凭据，检查 dashboard_config.local.lua 是否就位")
    os.exit(1)
end
if QW.mask(cfg.qweather.api_key):find(cfg.qweather.api_key, 1, true) then
    print("[FAIL] 脱敏函数泄露了完整 key")
    os.exit(1)
end

-- 打开看板（含渲染与天气请求）
RECORD = {}
ok, err = pcall(function() instance:open() end)
if not ok then
    print("open 失败: " .. tostring(err))
    os.exit(1)
end
EVENTS[#EVENTS + 1] = "== open() 通过 =="
EVENTS[#EVENTS + 1] = string.format("== 待机抑制计数 = %d，激活的定时器 = %d ==", standby, #timers)

-- 休眠屏保（1）：看板已经打开时，画面本来就是看板，不该再建第二棵树
local stack_open = #stack
stub_sleep()
if not Device.screen_saver_mode then
    print("[FAIL] 休眠时没有设 screen_saver_mode，唤醒分支永远不会执行")
    os.exit(1)
end
if instance.saver_root then
    print("[FAIL] 看板已打开时休眠又建了一棵看板树（画面会重复叠加）")
    os.exit(1)
end
if #stack ~= stack_open then
    print("[FAIL] 看板已打开时休眠改变了控件栈")
    os.exit(1)
end
if not instance.screensaver_owned then
    print("[FAIL] 休眠时没有标记屏保归看板接管")
    os.exit(1)
end
-- 唤醒必须返回 true，Kindle:outofScreenSaver 才会做一次全屏重绘
local woke_ok = Screensaver:close()
if woke_ok ~= true then
    print("[FAIL] 唤醒时没有请求重绘（被接管的 close 必须返回 true）")
    os.exit(1)
end
if Device.screen_saver_mode then
    print("[FAIL] 唤醒后 screen_saver_mode 没有复位")
    os.exit(1)
end
EVENTS[#EVENTS + 1] = "== 休眠（看板已打开）：复用当前画面，唤醒请求全屏重绘 =="

-- 时钟控件必须真的挂在控件树里。纵向拉伸会反复试算版式，而 buildPortrait 每次
-- 都会把 self.clock_widget 指向当次建的控件——一旦留着被否决那一版，
-- tick 就在刷新一棵没显示的树，钟会彻底停住（画面看不出来，日志也没错）。
local function in_tree(node, target, depth)
    if node == target then return true end
    if type(node) ~= "table" or depth > 6 then return false end
    for i = 1, #node do
        if node[i] == target then return true end
        if in_tree(node[i], target, depth + 1) then return true end
    end
    return false
end
if not instance.clock_widget or not in_tree(instance.root, instance.clock_widget, 0) then
    print("[FAIL] 时钟控件不在控件树里（重排时选错了那一版，时钟将不再刷新）")
    os.exit(1)
end
EVENTS[#EVENTS + 1] = string.format("== 时钟控件在树内，纵向拉伸档位 vk=%.2f ==",
    instance.vk or 1)

-- 手势：框架不认 onTap/onHold，只有注册成触摸区才会派发事件
local zone_list = instance.root._zones or {}
local zone_by_id = {}
local zone_ids = {}
for _, z in ipairs(zone_list) do
    zone_by_id[z.id] = z
    zone_ids[#zone_ids + 1] = z.id
end
if not zone_by_id.dashboard_tap or not zone_by_id.dashboard_swipe_up then
    print("[FAIL] 触摸区没有注册上（onTap/onHold 是无效写法，长按退不出去就是这个原因）")
    os.exit(1)
end
EVENTS[#EVENTS + 1] = "== 触摸区：" .. table.concat(zone_ids, ", ") .. " =="

-- 非上划方向不拦截
if zone_by_id.dashboard_swipe_up.handler({ direction = "south" }) ~= false then
    print("[FAIL] 下划不应被拦截，否则会吃掉其他手势")
    os.exit(1)
end
-- 点按刷新
instance.fetching = false
if zone_by_id.dashboard_tap.handler() ~= true then
    print("[FAIL] 点按 handler 没有返回 true")
    os.exit(1)
end
EVENTS[#EVENTS + 1] = "== 点按刷新触发成功 =="
-- 上划退出（重新取一次，点按后控件树已重建）
local root_now = instance.root
local swipe_zone
for _, z in ipairs(root_now._zones or {}) do
    if z.id == "dashboard_swipe_up" then swipe_zone = z end
end
swipe_zone.handler({ direction = "north" })
if instance.shown then
    print("[FAIL] 上划（north）之后看板没有关闭")
    os.exit(1)
end
EVENTS[#EVENTS + 1] = "== 上划退出成功（看板已关闭）=="
instance:open()
EVENTS[#EVENTS + 1] = "== 重新 open() 继续后续检查 =="

-- 顶部下滑 -> 打开看板自己的菜单；左右滑动 -> 重新布局
local root2 = instance.root
local down_zone, side_zone
for _, z in ipairs(root2._zones or {}) do
    if z.id == "dashboard_swipe_down" then down_zone = z end
    if z.id == "dashboard_swipe_side" then side_zone = z end
end
if not down_zone or not side_zone then
    print("[FAIL] 缺少「顶部下滑菜单」或「左右滑动重排」触摸区")
    os.exit(1)
end
if down_zone.handler({ direction = "north" }) ~= false then
    print("[FAIL] 顶部下滑区不该拦截上划，否则会抢走上划退出")
    os.exit(1)
end
if down_zone.handler({ direction = "south" }) ~= true then
    print("[FAIL] 顶部下滑没有响应")
    os.exit(1)
end
if not MENU_SHOWN then
    print("[FAIL] 顶部下滑没有弹出看板菜单")
    os.exit(1)
end
if not MENU_SHOWN.item_count or MENU_SHOWN.item_count < 5 then
    print("[FAIL] 弹出的菜单项数量不对")
    os.exit(1)
end
EVENTS[#EVENTS + 1] = string.format("== 顶部下滑弹出菜单：%d 项 ==", MENU_SHOWN.item_count)
if not instance.menu_open then
    print("[FAIL] menu_open 标记没有置位")
    os.exit(1)
end
-- 菜单打开期间不能重建版面，否则会把菜单盖掉
instance.relayout_pending = nil
instance:refreshLayout()
if instance.root ~= root2 or not instance.relayout_pending then
    print("[FAIL] 菜单打开时 refreshLayout 没有挂起")
    os.exit(1)
end
MENU_SHOWN.close_callback()
if instance.menu_open then
    print("[FAIL] 菜单关闭后 menu_open 没有复位")
    os.exit(1)
end
EVENTS[#EVENTS + 1] = "== 菜单打开期间重建已挂起，关闭后自动补做 =="

for _, z in ipairs(instance.root._zones or {}) do
    if z.id == "dashboard_swipe_side" then side_zone = z end
end
if side_zone.handler({ direction = "north" }) ~= false then
    print("[FAIL] 左右滑动区不该拦截上划")
    os.exit(1)
end
-- 左右滑动必须真的换到「另一种」版式：以前只是把版面重建一次，
-- Kindle 没有重力感应、Screen 尺寸不变，所以滑完还是原来那套（提示恒为「竖屏」）
local layout_before = instance.layout_landscape
if side_zone.handler({ direction = "east" }) ~= true then
    print("[FAIL] 左右滑动没有响应")
    os.exit(1)
end
if instance.layout_landscape == layout_before then
    print(string.format("[FAIL] 左右滑动后版式没变（仍是 %s）", tostring(layout_before)))
    os.exit(1)
end
-- 支持转屏时必须真的把屏幕转了（尺寸互换），而不是只换排版
if not _G.STUB_NO_ROTATION then
    local w_now, h_now = screen.getWidth(), screen.getHeight()
    local now_landscape = w_now >= h_now
    if now_landscape == layout_before then
        print("[FAIL] 支持转屏时，滑动应当真的把屏幕旋转 90°")
        os.exit(1)
    end
    if now_landscape ~= instance.layout_landscape then
        print("[FAIL] 转屏后屏幕方向与版式不一致")
        os.exit(1)
    end
end
-- 切换之后立刻校验：新版的画面必须仍然装得进当前屏幕
local w_after, h_after = screen.getWidth(), screen.getHeight()
local g_after = instance.root[1][1]:getSize()
if g_after.h > h_after + 1 or g_after.w > w_after + 1 then
    print(string.format("[FAIL] 切换版式后内容 %dx%d 溢出屏幕 %dx%d",
        math.floor(g_after.w), math.floor(g_after.h), w_after, h_after))
    os.exit(1)
end
EVENTS[#EVENTS + 1] = string.format("== 切换后内容 %dx%d（屏幕 %dx%d，缩放 %.3f）==",
    math.floor(g_after.w), math.floor(g_after.h), w_after, h_after, instance.scale or -1)

if side_zone.handler({ direction = "west" }) ~= true then
    print("[FAIL] 再次左右滑动没有响应")
    os.exit(1)
end
if instance.layout_landscape ~= layout_before then
    print("[FAIL] 再滑一次没有回到原来的版式")
    os.exit(1)
end
EVENTS[#EVENTS + 1] = string.format(
    "== 左右滑动切换版式成功（%s -> %s -> %s，转屏=%s）==",
    tostring(layout_before), tostring(not layout_before), tostring(layout_before),
    _G.STUB_NO_ROTATION and "不支持" or "已旋转 90°")

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

-- 电量与操作提示必须真的出现在画面上（不是只写进代码）
local has_pct, has_hint = false, false
local pct_text, hint_text
for _, r in ipairs(RECORD) do
    if r.kind == "text" then
        local t = tostring(r.text)
        if t:find("78%", 1, true) then has_pct = true; pct_text = t end
        if t:find("上划退出", 1, true) then has_hint = true; hint_text = t end
    end
end
if not has_pct then
    print("[FAIL] 画面上没有电量百分比（桩件电量 78%）")
    os.exit(1)
end
if not has_hint then
    print("[FAIL] 画面上没有操作提示文字")
    os.exit(1)
end
EVENTS[#EVENTS + 1] = string.format("== 电量显示：%s / 提示：%s ==",
    tostring(pct_text), tostring(hint_text))

-- 检查总高度是否溢出屏幕（用当前实际屏幕尺寸：转屏后宽高会互换）
local VW, VH = screen.getWidth(), screen.getHeight()
local group = instance.root[1][1]
local gs = group:getSize()
local overflow = (gs.h > VH + 1) or (gs.w > VW + 1)
if overflow then
    print(string.format("[FAIL] 内容 %dx%d 超出屏幕 %dx%d", math.floor(gs.w), math.floor(gs.h), VW, VH))
    os.exit(1)
end
EVENTS[#EVENTS + 1] = string.format(
    "== 内容总尺寸 %dx%d（屏幕 %dx%d），水平余量 %d px，垂直余量 %d px，"
    .. "缩放 %.3f，设计单位约占短边 %.1f%% ==",
    math.floor(gs.w), math.floor(gs.h), VW, VH,
    VW - math.floor(gs.w), VH - math.floor(gs.h),
    instance.scale or -1, (gs.h / (instance.scale or 1)) / math.min(SW, SH) * 100)

-- stretchGaps 的契约：只放大 mkPad 打了 is_gap 的留白行，其余行（分隔线、文字块）原样。
-- 真机上就是这里出过一次事故：旧实现靠「row.color == nil」逐字段探测留白行，而
-- COLOR_BLACK 是 ffi cdata，LuaJIT 下 cdata == nil 会走 ColorRGB32_mt.__eq(nil) 直接崩。
-- 桩件跑 PUC Lua、颜色是数字 255，永远复现不了，所以这里改为断言「契约」而不是崩不崩。
local gaps, grew, gap_total = 0, 0, 0
for i = 1, #group do
    local row = group[i]
    if row.is_gap then
        gaps = gaps + 1
        gap_total = gap_total + row.dimen.h
        if row.dimen.h > (row.gap_h or 0) then grew = grew + 1 end
    end
end
if gaps == 0 then
    print("[FAIL] 版式里没有顶层留白行，stretchGaps 无从生效")
    os.exit(1)
end
if grew == 0 then
    print("[FAIL] 留白行没有被拉伸（is_gap 标记或 vk 倍率没生效）")
    os.exit(1)
end
EVENTS[#EVENTS + 1] = string.format(
    "== 分块间距 %d 行，其中 %d 行被拉伸，留白合计 %d px ==", gaps, grew, gap_total)

-- 四边留白：直接查最终帧里每个可见元素的像素位置，白底铺满那一块要排除
-- 先清空记录并重画一次，否则拿到的是历次重绘的累积
RECORD = {}
instance.root:paintTo(fake_bb, 0, 0)
local EDGE_MIN = 15
local scale_now = instance.scale or 1
local edge_expect = math.max(EDGE_MIN, math.floor(15 * scale_now))
local tight = {}
for _, r in ipairs(RECORD) do
    local w, h = r.w or 0, r.h or 0
    local is_bg = (r.kind == "rect" and r.color ~= 255 and w >= VW and h >= VH)
    if not is_bg and r.kind ~= "exec" then
        local x, y = r.x or 0, r.y or 0
        if x < edge_expect - 1 or y < edge_expect - 1
            or x + w > VW - edge_expect + 1 or y + h > VH - edge_expect + 1 then
            tight[#tight + 1] = string.format("%s@(%d,%d) %dx%d", r.kind, math.floor(x), math.floor(y),
                math.floor(w), math.floor(h))
        end
    end
end
if #tight > 0 then
    print(string.format("[FAIL] 有 %d 个元素没有落在四边 %d px 留白内：%s",
        #tight, edge_expect, table.concat(tight, " | ", 1, math.min(4, #tight))))
    os.exit(1)
end
EVENTS[#EVENTS + 1] = string.format("== 四边留白 %d px：所有元素都在安全区内 ==", edge_expect)

-- 操作提示必须只有一行（多行会把版心撑高，横屏会触发整体缩放）。
-- 注意：折行的 TextWidget 仍然只画一次，数记录条数测不出来 —— 必须比
--   ① 自然宽度是否超过上限（超了就会折行）
--   ② 实际渲染高度是否等于单行行高（折行会翻倍）
local hu = instance.hint_used
if type(hu) ~= "table" then
    print("[FAIL] 没有记录到提示行的排版信息 hint_used")
    os.exit(1)
end
if hu.w > hu.max_w then
    print(string.format("[FAIL] 提示行自然宽 %d 超过上限 %d，会折行", hu.w, hu.max_w))
    os.exit(1)
end
local face_px = math.ceil(hu.px * (math.min(SW, SH) / 600))
local one_line = math.floor(face_px * 1.363)
for _, r in ipairs(RECORD) do
    if r.kind == "text" and tostring(r.text):find("上划退出", 1, true) then
        if r.h > one_line * 1.5 then
            print(string.format("[FAIL] 提示行实际渲染高 %d，单行应为 %d，说明折了行",
                r.h, one_line))
            os.exit(1)
        end
        break
    end
end
EVENTS[#EVENTS + 1] = string.format("== 操作提示为 1 行（字号 %d，自然宽 %d / 上限 %d）==",
    hu.px, hu.w, hu.max_w)

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
if not instance.weather then
    print("[FAIL] fetchWeather 之后没有天气数据")
    os.exit(1)
end
local w = instance.weather
local shown = instance:weatherDisplay()
EVENTS[#EVENTS + 1] = string.format(
    "== 实况：温度 %.2f°，体感 %.2f°，现象 %s(%d)，湿度 %.0f%%，风向 %s(%s°)，风级 %s ==",
    w.temp, w.feels, tostring(w.cond), w.code, w.hum,
    tostring(shown.wind_dir), tostring(w.winddir), tostring(shown.wind))
EVENTS[#EVENTS + 1] = string.format(
    "== 预报：最高 %.1f° 最低 %.1f°，日出 %s 日落 %s ==",
    w.tmax, w.tmin, tostring(w.sunrise), tostring(w.sunset))
EVENTS[#EVENTS + 1] = string.format(
    "== 空气：AQI %s（%s），PM2.5 %.1f，PM10 %.1f ==",
    tostring(instance.air and instance.air.aqi),
    tostring(instance.air and instance.air.level),
    tonumber(instance.air and instance.air.pm25) or -1,
    tonumber(instance.air and instance.air.pm10) or -1)

-- 逐项对照样本值：跑通但数值错同样算失败
local mismatches = {}
local function near(a, b, tol)
    return type(a) == "number" and math.abs(a - b) <= (tol or 0.01)
end
if not near(w.temp, 13.19) then mismatches[#mismatches + 1] = "温度" end
if w.code ~= 100 then mismatches[#mismatches + 1] = "天气代码" end
if not near(w.hum, 44, 0.51) then mismatches[#mismatches + 1] = "湿度（0~1 比例应乘 100）" end
if w.wind ~= 2 then mismatches[#mismatches + 1] = "风级" end
if w.sunrise ~= "06:54" then mismatches[#mismatches + 1] = "日出" end
if w.sunset ~= "17:02" then mismatches[#mismatches + 1] = "日落" end
if not near(w.tmax, 14.1) then mismatches[#mismatches + 1] = "最高温" end
if not near(w.tmin, 0.56) then mismatches[#mismatches + 1] = "最低温" end
if not (instance.air and instance.air.aqi == 65) then
    mismatches[#mismatches + 1] = "AQI（应取国标 cn-mee=65）"
end
if shown.wind_dir ~= "南风" then
    mismatches[#mismatches + 1] = "风向（185° 应为南风）"
end
if mismatches[1] then
    print("[FAIL] 字段不符: " .. table.concat(mismatches, "，"))
    os.exit(1)
end

-- 降级路径：和风整体失败 -> Open-Meteo，来源标记必须跟着变
_G.STUB_QW_FAIL = true
instance.weather, instance.air = nil, nil
ok, err = pcall(function() instance:fetchWeather(true) end)
_G.STUB_QW_FAIL = false
if not ok then
    print("降级 fetchWeather 失败: " .. tostring(err))
    os.exit(1)
end
local w2 = instance.weather
if not w2 or w2.source ~= "open-meteo" then
    print("[FAIL] 和风失败后没有降级到 Open-Meteo，当前来源 = "
        .. tostring(w2 and w2.source))
    os.exit(1)
end
local bad = {}
if not near(w2.temp, 10.0) then bad[#bad + 1] = "温度" end
if w2.code ~= 100 then bad[#bad + 1] = "现象代码（WMO 0 应映射成和风 100）" end
if w2.sunrise ~= "06:54" then bad[#bad + 1] = "日出（GMT 22:54 + 8h 应为 06:54）" end
if w2.wind ~= 1 then bad[#bad + 1] = "风级（4.5 km/h 应为 1 级）" end
if instance:airDisplay().text ~= "142" then
    bad[#bad + 1] = "降级 AQI（PM2.5 108.7 / PM10 111.5 应换算为 142）"
end
if instance:sourceLabel() ~= "天气 Open-Meteo（降级）" then bad[#bad + 1] = "来源标签" end
if bad[1] then
    print("[FAIL] 降级字段不符: " .. table.concat(bad, "，"))
    os.exit(1)
end
EVENTS[#EVENTS + 1] = string.format(
    "== 降级：%s %.1f° 代码 %d 日出 %s 日落 %s AQI %s（%s）==",
    tostring(w2.cond), w2.temp, w2.code, tostring(w2.sunrise), tostring(w2.sunset),
    instance:airDisplay().text, tostring(instance:sourceLabel()))

if _G.STUB_FRAME then dump_frame() end

-- 关闭，检查状态恢复
ok, err = pcall(function() instance:close() end)
if not ok then
    print("close 失败: " .. tostring(err))
    os.exit(1)
end
EVENTS[#EVENTS + 1] = string.format("== close() 通过，待机抑制计数 = %d，定时器 = %d，widget 栈 = %d ==",
    standby, #timers, #stack)

-- 休眠屏保（2）：看板关掉之后（在看书 / 书架）休眠，应现建一棵看板画上去
local stack_closed = #stack
RECORD = {}
stub_sleep()
if not instance.saver_root then
    print("[FAIL] 看板未打开时休眠没有渲染看板（会留着空屏或原生屏保）")
    os.exit(1)
end
if #stack ~= stack_closed + 1 then
    print("[FAIL] 屏保看板没有正确地占用控件栈一层")
    os.exit(1)
end
local saw_time = false
for _, r in ipairs(RECORD) do
    if r.kind == "text" and type(r.text) == "string" and r.text:match("^%d%d?:%d%d") then
        saw_time = true
        break
    end
end
if not saw_time then
    print("[FAIL] 屏保看板里没有时钟文本，只建了树没真正画出来")
    os.exit(1)
end
local woke2 = Screensaver:close()
if woke2 ~= true then
    print("[FAIL] 从屏保看板唤醒时没有请求重绘")
    os.exit(1)
end
if instance.saver_root then
    print("[FAIL] 唤醒后屏保看板没有撤掉")
    os.exit(1)
end
if #stack ~= stack_closed then
    print("[FAIL] 唤醒后控件栈没有恢复到休眠前")
    os.exit(1)
end
EVENTS[#EVENTS + 1] = "== 休眠（看板未打开）：现建看板作屏保；唤醒后栈已恢复 =="

print("---------- 事件序列 ----------")
for _, e in ipairs(EVENTS) do print(e) end

if standby ~= 0 then
    print("\n[FAIL] 待机抑制计数未归零，会导致系统一直不休眠")
    os.exit(1)
end
print("\n[PASS] 冒烟测试全部通过")
