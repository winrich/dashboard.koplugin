--[[--
桌面看板（dashboard.koplugin） v2

全屏常驻显示，按屏幕方向自动切换版式：
  · 竖屏（H > W）  仪表盘版式：顶部城市条 + 大时钟 + 天气 + 农历大字 + 节气进度条 + 底部三格
  · 横屏（W >= H） 上下分区版式：顶部城市条 + 大时钟与天气 + 整月日历网格 + 农历节气

显示内容：时钟、公历日期与星期、农历（干支、生肖）、当前节气与距下一节气天数、
当日天气（图标/温度/现象/体感）、湿度、风向风力、空气质量 AQI、日出日落。

数据源：和风天气开发服务（QWeather），需要在 dashboard_config.lua 或
dashboard_config.local.lua（或菜单「天气服务」）里填写 API Host 与 API Key。
空气质量优先用服务端返回的国标 AQI（cn-mee），境外城市缺该项时按 HJ 633-2012
由 PM2.5/PM10 浓度换算。和风不可用时自动降级到 Open-Meteo（免凭据），
界面底部会标明当前数据来自哪一路。

交互（走 registerTouchZones 注册触摸区，框架没有 onTap/onHold 这种回调）：
  · 点按屏幕      -> 立即刷新天气
  · 上划屏幕      -> 退出看板

设计要点（均已按 KOReader 源码核对，非猜测）：
  · Widget:paintTo 基类是空实现，自绘控件必须自己实现 paintTo，getSize 返回 self.dimen
  · WidgetContainer:paintTo 不处理 background，白底必须自己刷，否则透出下层界面
  · TextWidget 支持 setText() 与 fgcolor（官方示例即用 Blitbuffer.COLOR_DARK_GRAY）
  · 防休眠用 UIManager:preventStandby() / allowStandby()（KOReader 官方接口）
  · HTTPS 走 socket.http（KOReader 自带 LuaSec 集成），失败再退到 ssl.https
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local DataStorage = require("datastorage")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Widget = require("ui/widget/widget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")

local _ = require("gettext")
local Lunar = require("dashboard_lunar")
local CityData = require("dashboard_cities")
local QWeather = require("dashboard_qweather")
local OpenMeteo = require("dashboard_openmeteo")

local Screen = Device.screen

--- 当前屏幕旋转值；这个版本没有 device/screen.lua，Screen 就是 framebuffer，
--- 个别平台可能没有 getRotationMode，读不到一律返回 nil
local function screen_rotation()
    if not (Screen and Screen.getRotationMode) then return nil end
    local ok, now = pcall(function() return Screen:getRotationMode() end)
    return ok and now or nil
end

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
-- 真机字体度量与设计预估相差较大（实测内容高度可达预估的 1.7 倍），步数必须留够，
-- 否则循环走完仍放不下、画面被裁切到屏幕边缘。0.96^20 ≈ 0.44，足够收敛。
local FIT_MAX_STEPS = 20
local FIT_STEP = 0.96

-- 纵向拉伸：竖屏在 PW3 上内容只占版心高度的 87%，余量被居中分到上下，画面看着
-- 浮在中间。这里只放大「分块之间」的竖向间距（左右留白和字号一概不动），
-- 取仍然装得下的最大一档，把余量均匀吸进各处空白。
-- 只拉伸间距不放大字号，是因为字号一放大文字就变宽，左右只剩 52px 余量会立刻撑破。
local VK_STEP = 0.05
local VK_MAX = 1.75

-- 屏幕旋转：KOReader 用 LinuxFB 常量（0=正立、1=顺时针 90°、2=倒置、3=逆时针 90°）。
-- Kindle 没有重力感应，设备横过来时屏幕像素方向不会变，只有旋转 framebuffer
-- （阅读界面「旋转 90°/270°」用的就是这套）才能让横屏画面是正的。
-- Kindle 上没有硬件强制旋转，setRotationMode 会退化成软件旋转 blitbuffer，
-- 旋转后 Screen:getWidth()/getHeight() 互换（已读 ffi/framebuffer.lua 确认）。
local ROT_PORTRAIT = 0
local ROT_LANDSCAPE_CW = 1
local ROT_LANDSCAPE_CCW = 3

--- 目标旋转值：以「打开看板时的方向」base 为基准推算。
--- 屏幕是竖是横只由旋转值的**奇偶**决定（奇数 = 宽高互换），所以「竖屏」取偶数档、
--- 「横屏」取奇数档，不能写死 0/1/3——万一 KOReader 本来就是横着启动的，
--- 写死 0 得到的还是同一个方向，转了等于没转（桩件里就踩到了这个）。
local function target_rotation(base, mode)
    base = base or 0
    if mode == "landscape" then
        return (base % 2 == 1) and base or (base + 1) % 4
    elseif mode == "landscape_ccw" then
        return (base % 2 == 1) and (base + 2) % 4 or (base + 3) % 4
    end
    return (base % 2 == 0) and base or (base + 3) % 4
end

-- 四边留白：15 个设计单位（600px 短边机型上正好 15px，PW3 上约 27px）。
-- 分隔线以前是通屏宽、内容又是居中放置，视觉上就贴着屏幕边缘；现在整块版心
-- 按 (屏幕 - 2*边距) 排版，长横线跟着缩进，四边都有稳定白边。
local EDGE_UNITS = 15
local EDGE_MIN_PX = 15

-- 风向（8 方位）。和风返回角度，这里换算成中文方位；风级直接用接口给的 scale
local WIND_DIRS = { "北", "东北", "东", "东南", "南", "西南", "西", "西北" }

-- 空气质量回退用：HJ 633-2012 浓度限值 { 浓度下限, 浓度上限, IAQI 下限, IAQI 上限 }
-- 服务端返回国标 AQI（cn-mee）时优先用服务端值，只有境外城市缺该项才走这张表
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

-- 电量图标：壳体 + 正极触点 + 电量填充，充电时整体反白（墨水屏上最省笔画的区分方式）
local BatteryGauge = Widget:extend{}
function BatteryGauge:getSize()
    return self.dimen
end
function BatteryGauge:paintTo(bb, x, y)
    local w, h = self.dimen.w, self.dimen.h
    if w < 6 or h < 4 then return end
    local bw = math.max(1, self.border or 2)
    local nub_w = math.max(2, math.floor(w * 0.14))
    local body_w = w - nub_w - 2
    local fg = self.charging and COLOR_WHITE or COLOR_BLACK

    if self.charging then
        bb:paintRect(x, y, w, h, COLOR_BLACK)
    end
    -- 壳体与正极触点
    bb:paintBorder(x, y, body_w, h, bw, fg, nil, false)
    bb:paintRect(x + body_w + 2, y + math.floor(h * 0.3), nub_w,
        math.max(2, math.floor(h * 0.4)), fg)
    -- 电量填充
    local inner_w = body_w - bw * 2
    local inner_h = h - bw * 2
    local ratio = math.max(0, math.min(1, self.ratio or 0))
    local filled = math.floor(inner_w * ratio + 0.5)
    if filled > 0 and inner_w > 0 and inner_h > 0 then
        bb:paintRect(x + bw, y + bw, filled, inner_h, fg)
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
local windDirName

-- ------------------------------------------------------------------ 生命周期
function Dashboard:init()
    self.cache = LuaSettings:open(DataStorage:getSettingsDir() .. "/dashboard_cache.lua")
    local cached = self.cache:readSetting("weather")
    -- source 标记用于识别旧版 Open-Meteo 缓存（WMO 代码），避免用错代码表；
    -- 新版降级路径同样用和风编号，所以两种来源的缓存都能直接用
    if type(cached) == "table" and (cached.source == "qweather" or cached.source == "open-meteo") then
        self.weather = cached
    end
    local air = self.cache:readSetting("air")
    if type(air) == "table" then
        self.air = air
    end
    -- 版式方向不在这里处理：打开看板时（open）才按设置旋转屏幕，
    -- 关闭时还原，避免插件加载就把整个 KOReader 转了向
    -- 凭据每次启动重新读取，改完配置重启 KOReader 即生效
    self.config = QWeather.loadConfig(self.path or PLUGIN_DIR, G_reader_settings)
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
end

--- 配置（惰性读取，插件目录确定后再加载更稳）
function Dashboard:getConfig()
    if not self.config then
        self.config = QWeather.loadConfig(self.path or PLUGIN_DIR, G_reader_settings)
    end
    return self.config
end

--- 配置改动后重新加载
function Dashboard:reloadConfig()
    self.config = QWeather.loadConfig(self.path or PLUGIN_DIR, G_reader_settings)
    return self.config
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
            -- 已经打开时这个入口没有意义，看板内弹出的菜单会把它过滤掉
            hide_in_dashboard = true,
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
        text = _("版式（竖屏 / 横屏）"),
        sub_item_table = {
            {
                text = _("竖屏"),
                checked_func = function() return self:getOrientation() == "portrait" end,
                callback = function() self:setOrientation("portrait") end,
            },
            {
                text = _("横屏（向右转 90°）"),
                checked_func = function() return self:getOrientation() == "landscape" end,
                callback = function() self:setOrientation("landscape") end,
            },
            {
                text = _("横屏（向左转 90°）"),
                checked_func = function() return self:getOrientation() == "landscape_ccw" end,
                callback = function() self:setOrientation("landscape_ccw") end,
            },
        },
    }

    items[#items + 1] = { text = _("天气服务"), sub_item_table = self:genWeatherMenu() }

    items[#items + 1] = {
        text = _("使用说明"),
        callback = function()
            UIManager:show(InfoMessage:new{
                text = _("手势：点按刷新天气 · 上划退出看板\n"
                    .. "屏幕上缘下滑 → 打开看板菜单（城市 / 时区 / 版式 / 天气服务）\n"
                    .. "左右滑动 → 竖屏 ↔ 横屏 互相切换（会真的旋转屏幕）\n\n"
                    .. "Kindle 没有重力感应，机器横过来屏幕不会自己转，\n"
                    .. "所以横屏要靠左右滑动（或菜单「版式」）手动切，切完请把设备横着拿。\n"
                    .. "若横屏后文字是倒的，到菜单「版式」里换「向左转 90°」那一项。\n\n"
                    .. "右上角显示电量百分比与电量图标（充电时图标反白）。\n"
                    .. "天气优先用和风天气，不可用时自动降级到 Open-Meteo，页脚会标注来源。\n"
                    .. "长时间显示建议接通电源；程序每 30 分钟自动全刷一次以清除电泳残影。"),
            })
        end,
    }
    return items
end

-- ------------------------------------------------------------------ 天气服务菜单
local SOURCE_NAMES = {
    file = _("插件内 dashboard_config.lua"),
    local_ = _("插件内 dashboard_config.local.lua"),
    settings = _("设备内录入"),
    none = _("未配置"),
}

--- 「天气服务」子菜单：查看 / 录入凭据、测试连接
function Dashboard:genWeatherMenu()
    local function source_name(key)
        if key == "local" then return SOURCE_NAMES.local_ end
        return SOURCE_NAMES[key] or SOURCE_NAMES.none
    end

    local function open_input(title, description, hint, getter, setter)
        local dialog
        dialog = InputDialog:new{
            title = title,
            input = getter() or "",
            input_hint = hint,
            description = description,
            buttons = {
                {
                    {
                        text = _("取消"),
                        id = "cancel",
                        callback = function() UIManager:close(dialog) end,
                    },
                    {
                        text = _("保存"),
                        callback = function()
                            local value = dialog:getInputText() or ""
                            value = value:gsub("^%s+", ""):gsub("%s+$", "")
                            UIManager:close(dialog)
                            setter(value)
                        end,
                    },
                },
            },
        }
        UIManager:show(dialog)
        if dialog.onShowKeyboard then dialog:onShowKeyboard() end
    end

    return {
        {
            text = _("查看当前凭据"),
            keep_menu_open = false,
            callback = function()
                local cfg = self:getConfig()
                local qw = cfg.qweather or {}
                local lines = {
                    string.format("%s：%s", _("API Host"),
                        (qw.api_host and qw.api_host ~= "") and qw.api_host or _("未填写")),
                    string.format("%s：%s", _("API Key"), QWeather.mask(qw.api_key)),
                    string.format("%s：%s", _("来源"), source_name(cfg._key_source)),
                }
                if qw.credential_id and qw.credential_id ~= "" then
                    lines[#lines + 1] = string.format("%s：%s", _("凭据 ID"), qw.credential_id)
                end
                if qw.project and qw.project ~= "" then
                    lines[#lines + 1] = string.format("%s：%s", _("项目"), qw.project)
                end
                UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n") })
            end,
        },
        {
            text = _("填写 API Host"),
            keep_menu_open = false,
            callback = function()
                open_input(_("和风天气 API Host"),
                    _("控制台「设置」页里的专属地址，形如 abcxyz.qweatherapi.com，不要带 https://"),
                    "abcxyz.qweatherapi.com",
                    function() return self:getConfig().qweather.api_host end,
                    function(value)
                        G_reader_settings:saveSetting("dashboard_qw_host", value)
                        G_reader_settings:flush()
                        self:reloadConfig()
                        self:onConfigChanged()
                    end)
            end,
        },
        {
            text = _("填写 API Key"),
            keep_menu_open = false,
            callback = function()
                open_input(_("和风天气 API Key"),
                    _("控制台「项目管理 - 凭据」里创建，需与上面的 API Host 属于同一项目"),
                    "",
                    function() return self:getConfig().qweather.api_key end,
                    function(value)
                        G_reader_settings:saveSetting("dashboard_qw_key", value)
                        G_reader_settings:flush()
                        self:reloadConfig()
                        self:onConfigChanged()
                    end)
            end,
        },
        {
            text = _("测试连接"),
            keep_menu_open = false,
            callback = function()
                self:reloadConfig()
                UIManager:show(InfoMessage:new{
                    text = _("正在连接和风天气…"),
                    timeout = 1,
                })
                self:fetchWeather(true)
            end,
        },
        {
            text = _("清除设备内录入"),
            keep_menu_open = false,
            callback = function()
                G_reader_settings:saveSetting("dashboard_qw_host", "")
                G_reader_settings:saveSetting("dashboard_qw_key", "")
                G_reader_settings:flush()
                self:reloadConfig()
                self:onConfigChanged()
                UIManager:show(InfoMessage:new{
                    text = _("已清除。凭据改由插件目录下的配置文件提供。"),
                    timeout = 2,
                })
            end,
        },
    }
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
    -- 记下打开前的屏幕方向，关闭时原样恢复，别把整个 KOReader 留在横屏
    self.base_rotation = screen_rotation()
    self:setKindleScreenSaver(true)
    UIManager:preventStandby()
    -- 沿用上次选定的方向：选了横屏，重启 KOReader 打开看板时仍然是横屏；
    -- 选的是竖屏而设备当前是横的（上次没还原干净），这里也一并转回去
    local mode = G_reader_settings:readSetting("dashboard_orientation")
    if mode == "portrait" or mode == "landscape" or mode == "landscape_ccw" then
        if self:rotateScreen(mode) then
            self.rotation_changed = (screen_rotation() ~= self.base_rotation)
        elseif mode ~= "portrait" then
            -- 转不了就按横屏版式排（画面方向不变，至少排版是另一套）
            self.force_landscape = true
        end
    end
    self:refreshLayout()
    self:fetchWeather()
    self:scheduleTick()
end

function Dashboard:close()
    if not self.shown then return end
    self.shown = false
    -- 万一是菜单开着的时候被关掉，别让标记卡住导致以后再也不重排
    self.menu_open = false
    self.relayout_pending = false
    self.pending_orientation = nil
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
    -- 把屏幕转回打开看板前的方向，否则退出看板后整个 KOReader 都是横的
    if self.rotation_changed and self.base_rotation ~= nil and Screen.setRotationMode then
        pcall(function() Screen:setRotationMode(self.base_rotation) end)
        self.rotation_changed = false
        UIManager:setDirty(nil, "full")
    end
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

    -- 定时拉取天气：已有数据时按配置间隔（默认 30 分钟）；还没有数据时 5 分钟重试
    local last = self.weather and self.weather.ts or 0
    local interval = tonumber(self:getConfig().update_interval) or UPDATE_INTERVAL
    if not self.weather then
        interval = 5 * 60
    end
    if os.time() - last >= interval then
        self:fetchWeather()
    end

    self:scheduleTick()
end

-- ------------------------------------------------------------------ 设备状态
--- 电量百分比与充电状态。
--- Device:getPowerDevice() 在个别设备上可能不存在，读不到就返回 nil，
--- 界面直接不画电量，不影响其他内容（Kindle 上取的是 powerd 的 battLevel）。
function Dashboard:batteryInfo()
    if not Device.getPowerDevice then return nil end
    local ok, powerd = pcall(function() return Device:getPowerDevice() end)
    if not ok or not powerd or not powerd.getCapacity then return nil end

    local okc, cap = pcall(function() return powerd:getCapacity() end)
    cap = okc and tonumber(cap) or nil
    if not cap or cap < 0 then return nil end

    local charging = false
    if powerd.isCharging then
        local okh, chg = pcall(function() return powerd:isCharging() end)
        charging = (okh and chg) and true or false
    end
    return math.max(0, math.min(100, math.floor(cap + 0.5))), charging
end

--- 当前天气数据来自哪一路（降级时如实标注）
function Dashboard:sourceLabel()
    local src = self.weather and self.weather.source
    if src == "open-meteo" then
        return _("天气 Open-Meteo（降级）")
    elseif src == "qweather" then
        return _("天气数据 和风天气")
    end
    return nil
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

    local meta = QWeather.condition(w.code)
    d.icon = meta[2]
    -- 服务端给的中文现象更准（如“晴间多云”），缓存里没有时才用本地表
    d.cond = w.cond or _(meta[1])

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
    -- 否则“东南风 2 级”会超过单格宽度，跨过分隔线串到相邻格。
    -- 风级直接用和风返回的蒲福风级，不再由风速换算。
    d.wind_dir = windDirName(w.winddir)
    d.wind = w.wind and string.format("%d 级", w.wind) or nil
    d.sunrise = w.sunrise
    d.sunset = w.sunset
    return d
end

--- 空气质量展示文本与等级
function Dashboard:airDisplay()
    local a = self.air
    if not a then
        return { text = "--", level = _("暂无数据") }
    end
    -- 国标 AQI 优先；境外城市没有 cn-mee 时按 PM2.5/PM10 回退估算
    local aqi = a.aqi or self:calcAQI(a.pm25, a.pm10)
    if not aqi then
        return { text = "--", level = _("暂无数据") }
    end
    aqi = math.floor(aqi + 0.5)
    local level = a.level
    if not level then
        -- 境外城市没有国标 AQI 时，才按 HJ 633-2012 分档
        if aqi <= 50 then level = _("优")
        elseif aqi <= 100 then level = _("良")
        elseif aqi <= 150 then level = _("轻度污染")
        elseif aqi <= 200 then level = _("中度污染")
        elseif aqi <= 300 then level = _("重度污染")
        else level = _("严重污染") end
    end
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
    -- 菜单在屏幕上时重建会把它盖掉，先记下来等菜单关掉再重排
    if self.menu_open then
        self.relayout_pending = true
        return
    end
    local old = self.root
    self.root = self:createRoot()
    UIManager:show(self.root)
    if old then
        UIManager:close(old)
    end
    UIManager:setDirty(self.root, "full")
end

--- 屏幕当前是否呈横向（像素宽 >= 高）
function Dashboard:screenIsLandscape()
    return Screen:getWidth() >= Screen:getHeight()
end

--- 旋转屏幕到指定方向，返回 true 表示旋转真的生效。
--- 转完 Screen:getWidth()/getHeight() 会互换，版式随尺寸自动切换，不用另加强制标志。
function Dashboard:rotateScreen(mode)
    if mode ~= "portrait" and mode ~= "landscape" and mode ~= "landscape_ccw" then
        return false
    end
    if not (Screen.setRotationMode and Screen.getRotationMode) then return false end
    local target = target_rotation(self.base_rotation or 0, mode)
    local ok, err = pcall(function() Screen:setRotationMode(target) end)
    if not ok then
        logger.warn("dashboard: 屏幕旋转失败", tostring(err))
        return false
    end
    return screen_rotation() == target
end

--- 当前方向，供菜单打勾（以屏幕实际旋转值为准）
function Dashboard:getOrientation()
    local now = screen_rotation()
    if now == nil then return "portrait" end
    local base = self.base_rotation or 0
    if now == target_rotation(base, "landscape") then return "landscape" end
    if now == target_rotation(base, "landscape_ccw") then return "landscape_ccw" end
    return "portrait"
end

--- 切换方向（portrait / landscape / landscape_ccw）并重建版面。
--- 优先真旋转屏幕——只有这样才能让「设备横过来」时画面是正的；万一这台设备
--- 转不了（Screen 没有 setRotationMode，或调了不生效），退化成「只换版式」：
--- 画面方向不变，仅换成另一套排版，至少内容不再是当前那一套。
function Dashboard:setOrientation(mode)
    if mode ~= "landscape" and mode ~= "landscape_ccw" then mode = "portrait" end
    -- 看板没打开时不要动屏幕：那会把整个 KOReader 界面转过去，而看板没开就没有
    -- close 来还原，用户会卡在横屏的阅读界面里回不来。此时只记住选择，打开时再生效。
    if not self.shown then
        G_reader_settings:saveSetting("dashboard_orientation", mode)
        if G_reader_settings.flush then G_reader_settings:flush() end
        UIManager:show(InfoMessage:new{
            text = _("已记住，下次打开看板时按这个方向显示"),
            timeout = 2,
        })
        return false
    end
    -- 菜单开着的时候别转屏幕：菜单控件是按旧尺寸排的，一转就错位。
    -- 挂起，等菜单关掉（close_callback）再执行。
    if self.menu_open then
        self.pending_orientation = mode
        self.relayout_pending = true
        G_reader_settings:saveSetting("dashboard_orientation", mode)
        if G_reader_settings.flush then G_reader_settings:flush() end
        return false
    end
    local rotated = self:rotateScreen(mode)
    if rotated then
        -- 旋转后版式由屏幕尺寸自然判定，不需要再强制
        self.force_landscape = nil
        -- 与打开时的方向不一样才算「改过」，close 时才需要还原
        self.rotation_changed = (screen_rotation() ~= self.base_rotation)
    else
        self.force_landscape = (mode ~= "portrait")
        logger.warn("dashboard: 屏幕旋转不可用，退化为仅切换版式")
    end
    G_reader_settings:saveSetting("dashboard_orientation", mode)
    if G_reader_settings.flush then G_reader_settings:flush() end
    self:refreshLayout()
    -- 旋转改的是整块画面的方向，必须整屏重画，否则会留下上一方向的残影
    UIManager:setDirty(nil, "full")
    return rotated
end

--- 左右滑动：在「竖屏 ↔ 横屏」之间来回切。
--- 以前这里只是把版面重建一次，而 Kindle 没有重力感应、Screen 尺寸永远不变，
--- 所以不管机器怎么摆、滑多少次，出来都是竖屏那一套（提示也恒为「竖屏」）。
--- 现在改成真的转屏幕：转完尺寸互换，横屏版式才有 1448x1072 的可用空间。
function Dashboard:relayoutFromGesture()
    if not self.shown then return end
    -- 以「当前实际排版」为准取反，不能看屏幕尺寸：转屏失败退化成纯版式切换时，
    -- 屏幕尺寸不会变，按尺寸判断会一直往同一个方向切。
    local to_landscape
    if self.layout_landscape ~= nil then
        to_landscape = not self.layout_landscape
    else
        to_landscape = not self:screenIsLandscape()
    end
    local rotated = self:setOrientation(to_landscape and "landscape" or "portrait")
    local text
    if to_landscape then
        text = rotated and _("已转为横屏，请把设备横着拿（再左右滑一下可转回竖屏）")
            or _("已切换为横屏版式（本机不支持转屏）")
    else
        text = _("已转回竖屏")
    end
    UIManager:show(InfoMessage:new{ text = text, timeout = 2 })
end

--- 屏幕上缘下滑：打开看板自己的菜单。看板是全屏控件，KOReader 主菜单只在
--- 阅读界面上缘下拉才出现，滚动到看板里就没有入口了，所以这里复用同一套菜单项
--- 自己弹一个 TouchMenu。
--- 注意 TouchMenu 的真实构造参数：没有 title，菜单项放在 tab_item_table[1] 的
--- 数组部分（该表的 icon/callback 字段是顶部标签栏用的）。
function Dashboard:openMenu()
    if not self.shown then return end
    local loaded, TouchMenu = pcall(require, "ui/widget/touchmenu")
    if not loaded or type(TouchMenu) ~= "table" then
        logger.warn("dashboard: TouchMenu 不可用", tostring(TouchMenu))
        return self:menuFallback()
    end

    local tab = {
        icon = "appbar.settings",
        callback = function() end,
    }
    local idx = 0
    for _, item in ipairs(self:genMenuItemTable()) do
        if not item.hide_in_dashboard then
            idx = idx + 1
            tab[idx] = item
        end
    end

    local menu
    self.menu_open = true
    local ok, err = pcall(function()
        menu = TouchMenu:new{
            width = math.floor(Screen:getWidth() * 0.94),
            tab_item_table = { tab },
            close_callback = function()
                if menu then UIManager:close(menu) end
                self.menu_open = false
                if self.pending_orientation then
                    -- 菜单里选的方向等到这时才真正执行（转屏会让菜单控件错位）
                    local mode = self.pending_orientation
                    self.pending_orientation = nil
                    self.relayout_pending = false
                    self:setOrientation(mode)
                elseif self.relayout_pending then
                    self.relayout_pending = false
                    self:refreshLayout()
                end
            end,
        }
        UIManager:show(menu)
    end)
    if not ok then
        -- 版本差异导致菜单弹不出来时不能把看板一起拖下水
        self.menu_open = false
        logger.warn("dashboard: TouchMenu 构造失败", tostring(err))
        return self:menuFallback()
    end
end

--- 菜单弹不出来时的兜底提示，告诉用户从哪还能进设置
function Dashboard:menuFallback()
    UIManager:show(InfoMessage:new{
        text = _("这个 KOReader 版本无法在看板内弹出菜单。\n"
            .. "请先上划退出看板，再从阅读界面上缘下拉 → 工具 → 桌面看板。\n\n"
            .. "看板内可直接用的手势：点按刷新、上划退出、左右滑动重新布局。"),
        timeout = 5,
    })
end

--- 日志用截断（按 UTF-8 字符边界切，最多 12 字）
local function clipText(s)
    s = tostring(s or "")
    local n, i = 0, 1
    while i <= #s and n < 12 do
        local b = s:byte(i)
        i = i + ((b >= 0xF0 and 4) or (b >= 0xE0 and 3) or (b >= 0xC0 and 2) or 1)
        n = n + 1
    end
    return i > #s and s or (s:sub(1, i - 1) .. "…")
end

--- 诊断：把真机字体度量与版面分块尺寸写进日志。
--- 真机排版与桩件估算差得远时，只能靠这份日志定位是哪一块超限，不能靠猜。
function Dashboard:logLayoutDiag(tag, body, avail_w, avail_h)
    local function sz(w)
        local ok, r = pcall(function() return w:getSize() end)
        if ok and r then return math.floor(r.w or 0), math.floor(r.h or 0) end
        return -1, -1
    end

    -- ① 字体真实度量：每个字号 100 时，一个汉字/一个字母的宽高各是多少
    local okp, probe = pcall(function()
        local face = Font:getFace("cfont", 100)
        local tw = TextWidget:new{ text = "中", face = face, padding = 0 }
        local aw = TextWidget:new{ text = "A", face = face, padding = 0 }
        local th, ah = tw:getSize(), aw:getSize()
        return string.format(
            "字体@100 请求字号=%s 实际=%s 汉字 %dx%d 字母 %dx%d（em 宽 汉字%.2f 字母%.2f，行高%.2f）",
            tostring(face.size), tostring(face.orig_font or face.font or "?"),
            th.w, th.h, ah.w, ah.h, th.w / 100, ah.w / 100, th.h / 100)
    end)
    logger.warn(string.format("dashboard[diag/%s] %s", tag,
        okp and probe or ("字体探测失败: " .. tostring(probe))))

    -- ② 顶层每一行
    for i = 1, #body do
        local row = body[i]
        local w, h = sz(row)
        local hint = row.text and (" «" .. clipText(row.text) .. "»") or ""
        logger.warn(string.format("dashboard[diag/%s] 行%-2d %5dx%-5d%s", tag, i, w, h, hint))
    end

    -- ③ 最宽的若干叶子文本：直接指出是谁把宽度撑破的
    local leaves = {}
    local function walk(node, path, depth)
        if type(node) ~= "table" or depth > 5 then return end
        if type(node.text) == "string" then
            local w, h = sz(node)
            leaves[#leaves + 1] = { w = w, h = h, path = path, text = node.text }
        end
        for i = 1, #node do walk(node[i], path .. "." .. i, depth + 1) end
    end
    walk(body, "", 0)
    table.sort(leaves, function(a, b) return a.w > b.w end)
    for i = 1, math.min(6, #leaves) do
        local o = leaves[i]
        logger.warn(string.format("dashboard[diag/%s] 文本%s %dx%d «%s»",
            tag, o.path, o.w, o.h, clipText(o.text)))
    end
    local bw, bh = sz(body)
    logger.warn(string.format("dashboard[diag/%s] 版心 %dx%d，内容实测 %dx%d", tag, avail_w, avail_h, bw, bh))
end

--- 文本控件工厂：字号与颜色统一在这里处理
---
--- 字号一律传「设计单位」，**不要乘 ctx.S**。Font:getFace 内部会调
--- Screen:scaleBySize()（frontend/ui/font.lua:276），而它的实现正好是
--- ceil(px * min(屏宽,屏高) / 600)，与 ctx.S 是同一条公式。之前两边各乘一次，
--- 文字被放大到 1.79 倍两遍，真机实测内容 1500x1902 撑破 1020x1396 的版心。
function Dashboard:makeText(ctx, str, px, opts)
    opts = opts or {}
    return TextWidget:new{
        text = str or "",
        face = Font:getFace(opts.face or "cfont", math.max(11, math.floor(px))),
        bold = opts.bold or false,
        fgcolor = opts.gray and COLOR_GRAY or COLOR_BLACK,
        padding = 0,
        max_width = opts.max_width,
    }
end

--- 把纵向余量吸进「分块之间的空白」。
--- 只放大顶层纯留白行（mkPad 造出来的那种：有 dimen、没子控件、没文字、没颜色/比例）
--- 的行高，所以既不会改变任何文字的字号，也不会改变横向宽度——左右只剩 52px 余量，
--- 任何放大字号的改法都会立刻横向撑破版心。
--- 顶层纯留白行就等于「块与块之间的间距」，块内部的 mkPad 在子控件里，不受影响。
local function stretchGaps(body, vk)
    if not vk or vk == 1 then return end
    for i = 1, #body do
        local row = body[i]
        local h = type(row.dimen) == "table" and row.dimen.h or nil
        if h and h > 1 and row[1] == nil and row.text == nil
            and row.color == nil and row.ratio == nil and row.file == nil then
            row.dimen.h = math.max(1, math.floor(h * vk))
        end
    end
end

function Dashboard:createRoot()
    local W, H = Screen:getWidth(), Screen:getHeight()
    -- 版式方向：默认按屏幕像素尺寸判断；左右滑动切换过之后由 force_landscape 指定。
    -- Kindle 没有重力感应，设备横过来时屏幕像素方向也不变（仍是 1072x1448），
    -- 只按 W >= H 判断的话，横过来永远还是竖屏那套版式。
    local landscape
    if self.force_landscape ~= nil then
        landscape = self.force_landscape
    else
        landscape = W >= H
    end
    self.layout_landscape = landscape
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

    -- 先按物理基准排一次；若高度超出可用区（真机字体度量比预估高，或横屏纵向
    -- 空间本就比竖屏紧），按 FIT_STEP 逐级缩小重排，最多 FIT_MAX_STEPS 次。
    -- 布局构建是纯计算，重排无副作用；稳定后 self.scale 记录实际倍率。
    local S = math.min(W, H) / BASE_SHORT
    local edge = math.max(EDGE_MIN_PX, math.floor(EDGE_UNITS * S))
    local avail_w, avail_h = W - edge * 2, H - edge * 2
    -- 版心宽度：所有行都按它排，长横线随之内缩，四边自然留出 edge
    ctx.edge = edge
    ctx.body_w = avail_w

    -- vk 是「分块之间空白」的纵向放大系数：只动上下空白，不动文字也不动宽度
    local function build(vk)
        ctx.S = S
        local b = landscape and self:buildLandscape(ctx) or self:buildPortrait(ctx)
        stretchGaps(b, vk)
        return b, b:getSize()
    end

    local body, bs
    local steps_used = 0
    for step = 1, FIT_MAX_STEPS do
        steps_used = step
        body, bs = build(1)
        if bs.h <= avail_h and bs.w <= avail_w then
            break
        end
        -- 只在第一次超限时打完整诊断，避免日志被刷屏
        if step == 1 then
            pcall(self.logLayoutDiag, self,
                string.format("%s S=%.3f", landscape and "横屏" or "竖屏", S), body, avail_w, avail_h)
        end
        logger.warn(string.format(
            "dashboard: 内容 %dx%d 超出可用区 %dx%d（四边留白 %d），缩放至 %.3f 重排",
            bs.w, bs.h, avail_w, avail_h, edge, S * FIT_STEP))
        S = S * FIT_STEP
    end

    -- 装得下就再往上撑：逐档放大分块间距，取仍然装得下的最大一档。
    -- 竖屏 PW3 上余量有 180px 左右，撑到 1.4~1.6 倍才吃满，上下不再空出两条大带。
    local vk = 1
    if bs.h <= avail_h and bs.w <= avail_w then
        local max_i = math.floor((VK_MAX - 1) / VK_STEP + 0.5)
        for i = 1, max_i do
            local k = 1 + VK_STEP * i
            local _, bs2 = build(k)
            if bs2.h <= avail_h and bs2.w <= avail_w then
                vk = k
            else
                break
            end
        end
        -- 必须按最终档位真正建一次：buildPortrait 会顺手把 self.clock_widget 指向
        -- 当次建的控件，而试探过程中被否决的那一版控件不会进控件树。
        -- 不重建的话时钟控件会指向一棵没显示的树，往后 tick 就再也刷不动时钟了。
        body, bs = build(vk)
    end
    self.scale = S
    self.vk = vk
    -- 只有真的缩过才写日志，正常情况下不刷屏
    if steps_used > 1 then
        local bs = body:getSize()
        logger.warn(string.format("dashboard: 内容放不下，缩放至 S=%.3f 收敛，内容 %dx%d / 可用 %dx%d",
            S, bs.w, bs.h, avail_w, avail_h))
    end

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

    -- KOReader 框架没有 onTap/onHold 这类回调（那只是普通字段，永远不会被调用，
    -- 之前长按退不出就是这个原因）。手势必须用 registerTouchZones 注册成触摸区，
    -- 框架才会把 Gesture 事件派发到 InputContainer:onGesture。
    -- 多个触摸区重叠时框架按注册顺序依次问，handler 返回 false 就继续问下一个，
    -- 所以「顶部下滑」区可以安全地和全屏的上划区共存。
    root:registerTouchZones({
        {
            id = "dashboard_tap",
            ges = "tap",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            handler = function()
                self:fetchWeather(true)
                return true
            end,
        },
        {
            id = "dashboard_swipe_up",
            ges = "swipe",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            handler = function(ges)
                -- 只有上划（north = 手指向上）才退出，其他方向让给后面的区
                if ges and ges.direction == "north" then
                    -- 在事件分发过程中直接销毁控件容易踩到重入，推迟一拍再关
                    UIManager:nextTick(function() self:close() end)
                    return true
                end
                return false
            end,
        },
        {
            id = "dashboard_swipe_down",
            ges = "swipe",
            -- 只看屏幕上缘 1/6 高度：从顶部往下拉打开看板自己的菜单
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 / 6 },
            handler = function(ges)
                if ges and ges.direction == "south" then
                    UIManager:nextTick(function() self:openMenu() end)
                    return true
                end
                return false
            end,
        },
        {
            id = "dashboard_swipe_side",
            ges = "swipe",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            handler = function(ges)
                local dir = ges and ges.direction
                if dir == "east" or dir == "west" then
                    -- 左右滑动 = 重新布局：设备转过向（或改了 KOReader 方向设置）之后
                    -- 用这个手势让看板按新尺寸重排，不必再进菜单
                    UIManager:nextTick(function() self:relayoutFromGesture() end)
                    return true
                end
                return false
            end,
        },
    })
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

--- 顶部条：城市 · 时区（左） + 更新时间与电量（右），两端撑满
function Dashboard:buildHeader(ctx, pad_lr)
    local W, S = ctx.body_w or ctx.W, ctx.S
    local avail = W - pad_lr * 2

    -- 右侧：更新时间 + 电量图标 + 百分比
    local right_items = {
        align = "center",
        self:makeText(ctx, self:updateLabel(ctx), 19, { gray = true }),
    }
    local cap, charging = self:batteryInfo()
    if cap then
        right_items[#right_items + 1] = mkPad(math.floor(14 * S), 1)
        right_items[#right_items + 1] = BatteryGauge:new{
            dimen = Geom:new{
                w = math.floor(34 * S),
                h = math.max(10, math.floor(17 * S)),
            },
            border = math.max(1, math.floor(2 * S)),
            ratio = cap / 100,
            charging = charging,
        }
        right_items[#right_items + 1] = mkPad(math.floor(6 * S), 1)
        right_items[#right_items + 1] = self:makeText(ctx, string.format("%d%%", cap), 19,
            { gray = true })
    end
    local right = HorizontalGroup:new(right_items)

    -- 左侧城市条按右侧实际占用反推可用宽度，避免两端挤在一起
    local min_fill = math.floor(16 * S)
    local left_w = math.floor(avail - right:getSize().w - min_fill)
    left_w = math.max(math.floor(avail * 0.35), left_w)
    local left = self:makeText(ctx, string.format("%s · %s", self:getCityName(), ctx.tz.iana),
        26, { max_width = left_w })
    local fill = math.max(min_fill, avail - left:getSize().w - right:getSize().w)
    return HorizontalGroup:new{
        align = "center",
        mkPad(pad_lr, 1), left, mkPad(fill, 1), right, mkPad(pad_lr, 1),
    }
end

--- 天气块：图标与温度左右并列，压缩纵向占用
--- 天气块：图标 + 温度/现象/体感。
--- max_w 是这一块能占的最大像素宽度：天气现象文字长度在不同天气下差三四倍
--- （「晴」对「雷阵雨伴冰雹」），不设上限会让整行宽度随措辞浮动，长名字直接把
--- 版心撑破、触发自动缩放。给了上限就只会折行，版式稳定。
function Dashboard:buildWeatherBlock(ctx, icon_px, temp_px, max_w)
    local S = ctx.S
    local d = self:weatherDisplay()
    local icon_w = math.floor(icon_px * S)
    local gap = math.floor(8 * S)
    local icon = ImageWidget:new{
        file = self:iconPath(d.icon),
        width = icon_w,
        height = icon_w,
        scale_factor = 0,
        alpha = true,
    }
    -- 文字区可用的宽度；留一个下限，避免极端情况下被压成一条竖线
    local side_max = max_w and math.max(math.floor(60 * S), max_w - icon_w - gap) or nil
    local side = VerticalGroup:new{
        align = "left",
        self:makeText(ctx, d.temp, temp_px, { max_width = side_max }),
        self:makeText(ctx, d.cond, 28, { max_width = side_max }),
        d.feels and self:makeText(ctx, d.feels, 20, { gray = true, max_width = side_max })
            or mkPad(1, 1),
    }
    return HorizontalGroup:new{
        align = "center",
        icon,
        mkPad(gap, 1),
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
    local W, S = ctx.body_w or ctx.W, ctx.S
    local pad_lr = math.floor(28 * S)
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
    local min_gap = math.floor(14 * S)
    local weather_block = self:buildWeatherBlock(ctx, 76, 50,
        content_w - clock_block:getSize().w - min_gap)
    local clock_fill = math.max(min_gap,
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
    push(self:buildHintRow(ctx, content_w, pad_lr, 17))

    return VerticalGroup:new{ align = "left", unpack(rows) }
end

-- ---------------------------------------------------------------- 横屏：上下分区
function Dashboard:buildLandscape(ctx)
    local W, S = ctx.body_w or ctx.W, ctx.S
    local pad_lr = math.floor(34 * S)
    local rows = {}
    local function push(widget) rows[#rows + 1] = widget end

    push(self:buildHeader(ctx, pad_lr))
    push(mkPad(W, math.floor(3 * S)))
    push(Solid:new{ dimen = Geom:new{ w = W, h = math.max(2, math.floor(4 * S)) }, color = COLOR_BLACK })
    push(mkPad(W, math.floor(4 * S)))

    -- 时钟与日期（左） / 天气（右），中间空白撑开
    self.clock_text = string.format("%02d:%02d", ctx.now.hour, ctx.now.min)
    self.clock_widget = self:makeText(ctx, self.clock_text, 82)
    local date_line = self:makeText(ctx, string.format("%d年%d月%d日 星期%s",
        ctx.now.year, ctx.now.month, ctx.now.day, Lunar.WEEKDAY_NAMES[ctx.now.wday] or ""), 28)
    local clock_block = VerticalGroup:new{
        align = "left",
        self.clock_widget,
        mkPad(1, math.floor(3 * S)),
        date_line,
    }
    local weather = self:buildWeatherBlock(ctx, 78, 60,
        W - pad_lr * 2 - clock_block:getSize().w)
    local fill = math.max(0, W - pad_lr * 2 - clock_block:getSize().w - weather:getSize().w)
    push(HorizontalGroup:new{
        align = "center",
        mkPad(pad_lr, 1),
        clock_block,
        mkPad(fill, 1),
        weather,
        mkPad(pad_lr, 1),
    })

    push(mkPad(W, math.floor(4 * S)))
    push(Solid:new{ dimen = Geom:new{ w = W, h = math.max(2, math.floor(3 * S)) }, color = COLOR_BLACK })
    push(mkPad(W, math.floor(4 * S)))

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

    -- 底部操作提示：横屏宽，固定一行，正好抵掉从右栏挪走的来源声明
    push(mkPad(W, math.floor(6 * S)))
    push(self:buildHintRow(ctx, avail, pad_lr, 20))

    return VerticalGroup:new{ align = "left", unpack(rows) }
end

--- 整月日历：周一起始、跨月补位、今天反白、节气日带点
function Dashboard:buildCalendar(ctx, cell_w)
    local now = ctx.now
    -- 单元格内容为「日号 + 圆点」，约 36 设计单位高，设定值低于此不起作用
    local row_h = math.floor(36 * ctx.S)
    local head_h = math.floor(24 * ctx.S)

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
                    self:makeText(ctx, tostring(d2), 19, { gray = true }),
                    mkPad(1, 1),
                }, { auto_h = true })
            else
                local y2, m2, d2 = Lunar.civil_from_days(daynum)
                local is_today = (daynum == today_num)
                local term = terms[d2]
                local num_text = self:makeText(ctx, tostring(d2), is_today and 21 or 19,
                    { fg = nil })
                if is_today then
                    num_text.fgcolor = COLOR_WHITE
                end
                local stack = VerticalGroup:new{
                    align = "center",
                    num_text,
                    mkPad(1, math.floor(1 * ctx.S)),
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

--- 底部操作提示：固定一行。文案变长或真机字体更宽时自动降字号，绝不换行
--- （换行会把版心撑高，横屏本来余量就小，一换行就触发整体缩放）
--- 底部单行操作提示。
--- 关键：量宽度必须用「不带 max_width」的探针。带了 max_width 的 TextWidget
--- 会折行，getSize().w 永远等于上限值，降字号的循环第一次就误判为“放得下”，
--- 结果真机上折成两行（实测 920x84 而不是 920x42）。
function Dashboard:buildHintRow(ctx, max_w, pad_lr, base_px)
    local text = self:hintLine()
    local px, natural = base_px, 0
    -- 每次降 1 个单位（原先是 0.92 的乘法，17 -> 15 会直接跳过 16，
    -- 一个字的差别就让字号掉两级）
    for _ = 1, 14 do
        natural = self:makeText(ctx, text, px):getSize().w
        if natural <= max_w or px <= 11 then break end
        px = math.max(11, px - 1)
    end
    local widget = self:makeText(ctx, text, px, { gray = true, max_width = max_w })
    self.hint_used = { px = px, w = natural, max_w = max_w }
    local w = widget:getSize().w
    return HorizontalGroup:new{
        align = "center",
        mkPad(pad_lr, 1),
        widget,
        mkPad(math.max(0, max_w - w), 1),
        mkPad(pad_lr, 1),
    }
end

--- 页脚用的短来源标注：底部只有一行，长的会把字号压小
function Dashboard:sourceShort()
    local src = self.weather and self.weather.source
    if src == "open-meteo" then return _("Open-Meteo 降级") end
    if src == "qweather" then return _("和风天气") end
    return nil
end

--- 单行操作提示文案（竖屏横屏共用，只有一个版本）
function Dashboard:hintLine()
    local line = _("点按刷新 · 上划退出 · 顶部下滑菜单 · 左右滑动换版式")
    if self:getConfig().show_attribution then
        local src = self:sourceShort()
        if src then line = line .. " · " .. src end
    end
    return line
end

-- ------------------------------------------------------------------ 数据换算
--- 风向角度 -> 中文方位（如“东南风”）。风级由接口直接给，这里不再换算
function windDirName(deg)
    local d = tonumber(deg)
    if not d then return nil end
    local idx = math.floor(((d % 360) + 22.5) % 360 / 45) + 1
    return (WIND_DIRS[idx] or "") .. "风"
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

-- ------------------------------------------------------------------ 天气拉取
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

    local cfg = self:getConfig()
    local city, tz = self:getCity(), self:getTz()

    NetworkMgr:runWhenOnline(function()
        -- 请求三个接口是同步的，用 pcall 兜住意外错误，否则 fetching 标志会卡死，
        -- 之后再也不会重试
        local called, weather, air, err = pcall(QWeather.fetch, {
            city = city,
            tz = tz,
            config = cfg,
        })
        if not called then
            logger.warn("dashboard: 和风拉取异常", tostring(weather))
            weather, air, err = nil, nil, tostring(weather)
        end

        -- 主源拿不到数据就降级到 Open-Meteo：免凭据，只求界面不空着。
        -- 降级成功时页脚会标注来源，不会让人误以为仍是和风的数据。
        if not weather and cfg.fallback_openmeteo ~= false then
            logger.warn("dashboard: 和风不可用，降级到 Open-Meteo：", tostring(err))
            local ok2, w2, a2, e2 = pcall(OpenMeteo.fetch, { city = city, tz = tz })
            if not ok2 then
                logger.warn("dashboard: Open-Meteo 降级异常", tostring(w2))
                err = (err and (err .. "；") or "") .. tostring(w2)
            elseif w2 then
                weather, air = w2, a2 or air
                err = nil
            else
                err = (err and (err .. "；") or "") .. tostring(e2 or _("降级同样失败"))
            end
        end

        if weather then
            self.weather = weather
            self.cache:saveSetting("weather", self.weather)
        end
        if air then
            self.air = air
            self.cache:saveSetting("air", self.air)
        end
        self.cache:flush()

        self.fetching = false
        if manual and not weather and not air then
            UIManager:show(InfoMessage:new{
                text = string.format(_("天气更新失败：%s"), err or _("未知原因")),
                timeout = 5,
            })
        end
        if self.shown then
            self:refreshLayout()
        end
    end)
end

return Dashboard
