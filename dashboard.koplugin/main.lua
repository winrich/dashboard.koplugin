--[[--
桌面看板（dashboard.koplugin） v2

全屏常驻显示，按屏幕方向自动切换版式：
  · 竖屏（H > W）  仪表盘版式：顶部城市条 + 大时钟 + 天气 + 农历大字 + 节气进度条 + 底部三格
  · 横屏（W >= H） 上下分区版式：顶部城市条 + 大时钟与天气 + 整月日历网格 + 农历节气

显示内容：每个区各选一个组件（菜单「布局组件」里换）。可选组件：
  时钟与天气 / 农历与节气 / 三格状态 / 月历 / 侧栏（v2.44 及以前）
  大字时钟 / 纯天气 / 今日+三日 / 一周预报 / 在读卡 / 日月 / 空气明细 / 电量网络（v2.45 新增）
月相优先用和风的 astro.moonphase，降级时由 dashboard_moon.lua 现算（日月黄经差）。

数据源：和风天气开发服务（QWeather），需要在 dashboard_config.lua 或
dashboard_config.local.lua（或菜单「天气服务」）里填写 API Host 与 API Key。
空气质量优先用服务端返回的国标 AQI（cn-mee），境外城市缺该项时按 HJ 633-2012
由 PM2.5/PM10 浓度换算。和风不可用时自动降级到 Open-Meteo（免凭据），
界面底部会标明当前数据来自哪一路。

交互（走 registerTouchZones 注册触摸区，框架没有 onTap/onHold 这种回调）：
  · 点按屏幕      -> 立即刷新天气
  · 上划屏幕      -> 退出看板

配置入口（两处，同一份菜单项 genMenuItemTable）：
  · 设置 → 屏幕 → 屏保 → 桌面看板（不开看板时改，靠 sorting_hint="screensaver" 挂进去）
  · 看板打开时屏幕上缘下滑（TouchMenu；KOReader 菜单被看板盖住时进不去）

设计要点（均已按 KOReader 源码核对，非猜测）：
  · Widget:paintTo 基类是空实现，自绘控件必须自己实现 paintTo，getSize 返回 self.dimen
  · WidgetContainer:paintTo 不处理 background，白底必须自己刷，否则透出下层界面
  · TextWidget 支持 setText() 与 fgcolor（官方示例即用 Blitbuffer.COLOR_DARK_GRAY）
  · 不要用 UIManager:preventStandby()：会让设备永不休眠、看板一直刷。
    休眠/唤醒的接管点在 Screensaver.show / close，见下面「休眠屏保」一节
  · HTTPS 走 socket.http（KOReader 自带 LuaSec 集成），失败再退到 ssl.https

看板打开之后的状态机（每一条都已按 KOReader 上游源码核对）：
  触摸            点按刷新天气；上划退出；左右滑切版式；上缘下滑开菜单
  空闲但未超时      每分钟局部刷新时钟（只重画时钟那一块），每 30 分钟全刷一次清残影
  空闲超时 / 按电源键  powerd → Device:intoScreenSaver() → Screensaver.show 被我们接管
                     → 屏幕保持看板 → powerd:beforeSuspend() 真正挂起（CPU 停）
                     所以「按电源键屏幕没变化」是正常的：它本来就在显示看板
  休眠中            CPU 停、定时器基于 CLOCK_MONOTONIC 也不走，画面静止（屏保本就该静态）
  唤醒              Screensaver.close → 重建版面（时钟/电量/日期/跨日内容一次校正）
                     + 重置定时器；拉天气推迟几秒，避免同步 HTTP 把唤醒拖成「卡死」
  菜单开着时休眠      先把菜单撤掉再定格看板，别把菜单当屏保
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
local I18n = require("dashboard_i18n")
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
local Moon = require("dashboard_moon")

-- 多语言：T() 查表，未收录时原样返回中文（缺词条不会崩，只会退回中文）
local T = I18n.T
local TL = I18n.TL

local Screen = Device.screen

--- 当前屏幕旋转值；这个版本没有 device/screen.lua，Screen 就是 framebuffer，
--- 个别平台可能没有 getRotationMode，读不到一律返回 nil
local function screen_rotation()
    if not (Screen and Screen.getRotationMode) then return nil end
    local ok, now = pcall(function() return Screen:getRotationMode() end)
    return ok and now or nil
end

--- 读 Kindle 的 lipc 整型属性。读不到返回 nil（调用方自备默认值）。
--- 用 io.popen 而不是 liblipclua：这个插件不依赖额外的 .so，越狱环境更稳。
local function readLipcInt(service, prop)
    local cmd = string.format("lipc-get-prop -i %s %s 2>/dev/null", service, prop)
    local ok, handle = pcall(io.popen, cmd)
    if not ok or not handle then return nil end
    local line = handle:read("*l")
    handle:close()
    return tonumber(line or "")
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

-- 版本号：显示在菜单「使用说明」那一项上。改动行为后一定同步改这里，
-- 上机时一眼就能确认「装的到底是不是刚改的这份」（避免文件没覆盖到、
-- 或者覆盖了但 KOReader 没重启，还在跑内存里的旧模块）。
local DASHBOARD_VERSION = "2.45"

-- 唤醒宽限期：刚醒来的这几秒里先不拉天气。http.TIMEOUT 是 20 秒，三个接口
-- 外加 LuaSec/socket.http 双通道，最坏能同步卡住一两分钟；而休眠之后天气必然过期，
-- 唤醒后第一拍 tick 一定会去拉，正好撞上用户按电源键的那一刻，表现就是「按了没反应」。
local RESUME_FETCH_GRACE = 25

-- 两拍 tick 间隔超过这个值，说明中间经历了休眠（或系统长时间卡住）。
-- 定时器走 CLOCK_MONOTONIC，休眠期间不走，唤醒后可能还要再等几十秒才到点，
-- 这期间屏幕上的时钟是睡前的；所以一旦发现间隔异常就直接重建版面校正。
local TICK_GAP_REBUILD = 180

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
        if self.align == "left" then
            ox = 0
        elseif self.align == "right" then
            -- 右对齐：温度列用固定宽度的盒子靠右，七行右边缘才对得齐
            ox = math.max(0, self.dimen.w - cs.w)
        end
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
    local hh = math.max(1, math.floor(h))
    return Widget:new{
        dimen = Geom:new{ w = math.max(0, math.floor(w)), h = hh },
        -- 显式标记「纯留白行」，stretchGaps 只认这个标记。见该函数上方注释：
        -- 用字段探测（row.color == nil …）会在 LuaJIT 下把 Solid 的 cdata 颜色比爆。
        is_gap = true,
        -- 设计高度：桩件用它断言 stretchGaps「只放大、不缩小、不碰非留白行」
        gap_h = hh,
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

-- ------------------------------------------------------------------ 分区与组件
-- 三区骨架：header 与 hint 之外，剩余纵向空间切成 A / B / C 三个「盒子」。
-- 每个区只放一个组件（单选替换，不做叠加），盒子高度固定，组件在盒内自适应：
-- 先按 k=1 建，装不下就按 K_LADDER 逐档收紧字号（宽度不动），绝不裁切。
--
-- 高度是「设计单位」，乘 S 得真机像素。数值来自 PW3 桩件实测（见 memory 2026-11-12）：
--   竖屏 版心 1020×1389、内容列 920 → A 414 / B 518 / C 239 px
--   横屏 版心 1396×1018、内容列 1276 → A 295 / 下半 565（B 630 + 分隔 53 + C 593）
local ZONE_SPEC = {
    portrait  = { A = 224, B = 279, C = 128, gap = 9, sep = 4, sep2 = 3, pad = 28 },
    landscape = { A = 162, lower = 304,          gap = 4, sep = 4, sep2 = 3, pad = 34 },
}

-- 组装骨架时必须按这个顺序取区，与配置表的键一致
local ZONE_KEYS = { "A", "B", "C" }

--- 每区的默认组件。老用户升级后没有 dashboard_components 设置，
--- 全部回落到这里 → 视觉与升级前一致。
local ZONE_DEFAULT = {
    portrait  = { A = "clock_weather", B = "lunar_term", C = "stats_cells" },
    landscape = { A = "clock_weather", B = "calendar",   C = "side_panel" },
}

--- 组件注册表。zones 按方向分别声明白名单（同一个组件在竖屏能进的区
--- 和在横屏能进的区并不一样，例如侧栏只在横屏 C）。
--- build 存方法名而不是函数，避免在表构造时就要拿到 Dashboard 的方法。
local COMPONENTS = {
    clock_weather = {
        label = "时钟与天气", zones = { portrait = { "A" }, landscape = { "A" } },
        -- has_clock：这个组件会产生「自己会走的钟」。tick 靠 self.clock_widget
        -- 逐分钟改字，桩件也靠这个标记判断「版式里到底该不该有钟」。
        has_clock = true,
        build = "compClockWeather",
    },
    lunar_term = {
        label = "农历与节气", zones = { portrait = { "B" }, landscape = { "B", "C" } },
        build = "compLunar",
    },
    stats_cells = {
        label = "三格状态", zones = { portrait = { "C" }, landscape = { "C" } },
        build = "compStats",
    },
    calendar = {
        label = "月历", zones = { portrait = { "B" }, landscape = { "B" } },
        build = "compCalendar",
    },
    side_panel = {
        label = "侧栏三合一", zones = { portrait = {}, landscape = { "C" } },
        build = "compSidePanel",
    },
    -- ---- v2.45 新增 8 个 ----
    -- 白名单不是随手写的，每条都按「这个区装得下吗」定：
    --   竖屏 A 920×407 / B 920×505 / C 920×232；横屏 A 1276×294 / B 630×553 / C 593×553
    -- 例：一周预报要 7 列就得宽，横屏只有 A 区够宽；竖屏排成 7 行，A/B 都行。
    clock_big = {
        label = "大字时钟", zones = { portrait = { "A" }, landscape = { "A" } },
        has_clock = true,
        build = "compClockBig",
    },
    weather_big = {
        label = "纯天气", zones = { portrait = { "A" }, landscape = { "A" } },
        build = "compWeatherBig",
    },
    weather_today_3d = {
        label = "今日+三日", zones = { portrait = { "A", "B" }, landscape = { "A" } },
        build = "compToday3d",
    },
    forecast_week = {
        label = "一周预报", zones = { portrait = { "A", "B" }, landscape = { "A", "B" } },
        build = "compWeek",
    },
    reading_now = {
        label = "在读卡", zones = { portrait = { "A", "B", "C" }, landscape = { "C" } },
        build = "compReading",
    },
    sun_moon = {
        label = "日月", zones = { portrait = { "B", "C" }, landscape = { "B", "C" } },
        build = "compSunMoon",
    },
    air_detail = {
        label = "空气明细", zones = { portrait = { "B" }, landscape = { "B", "C" } },
        build = "compAirDetail",
    },
    battery_net = {
        label = "电量网络", zones = { portrait = { "C" }, landscape = { "C" } },
        build = "compBatteryNet",
    },
}

-- 收紧档位：只降字号，不换布局、不裁内容
local K_LADDER = { 1, 0.94, 0.88, 0.82, 0.76 }
-- 月历的横向铺排参数：
--   列距 = 格宽 × CAL_GAP_RATIO（看起来是列与列之间透气，而不是把格子拉扁）
--   格宽上限 = 行高 × CAL_ASPECT_MAX（再宽日号就在格子里浮起来了）
local CAL_GAP_RATIO = 0.32
local CAL_ASPECT_MAX = 1.62

local Dashboard = WidgetContainer:extend{
    name = "dashboard",
    is_doc_only = false,
}

-- ------------------------------------------------------------------ 版式度量
-- 下面几个方法把「布局用到的数值」暴露出来，生产代码与桩件断言共用同一份，
-- 避免测试里另写一套常数——改了一边、另一边还在用旧值，这种错最难发现。

--- 组件注册表：桩件按它遍历「所有组件 × 该组件允许的区」
function Dashboard:componentRegistry() return COMPONENTS end

--- 分区规格（设计单位）
function Dashboard:zoneSpec() return ZONE_SPEC end

--- 收紧档位（桩件的组件矩阵断言按同一套档位复算，别各写一份）
function Dashboard:kLadder() return K_LADDER end

--- 版心几何：倍率、四边留白、可用宽高
function Dashboard:contentBox(W, H)
    local S = math.min(W, H) / BASE_SHORT
    local edge = math.max(EDGE_MIN_PX, math.floor(EDGE_UNITS * S))
    return S, edge, W - edge * 2, H - edge * 2
end

--- 横屏下半区宽度：左 B（7 个日历格宽）/ 右 C（吃掉剩余）/ 中间竖线
function Dashboard:lowerWidths(avail, S)
    local gap = self:lowerVGap(S)
    local vline_w = math.max(2, math.floor(3 * S))
    local right_min = math.floor(330 * S)
    local cell_w = math.min(math.floor(52 * S),
        math.floor((avail - right_min - gap * 2 - vline_w) / 7))
    cell_w = math.max(math.floor(34 * S), cell_w)
    local bw = cell_w * 7
    local cw = math.max(math.floor(260 * S), avail - bw - gap * 2 - vline_w)
    return bw, cw, vline_w
end

--- 竖线两侧的留白。
--- 水平分隔线用 4 个设计单位就够了（那是条线，不挨字），但竖线两边紧挨着正文：
--- 在读卡的书名、空气明细的 AQI 都会几乎压到线上（实测只剩 7 px，等于贴着）。
--- 单独给到 10 个设计单位，B/C 两栏都跟着退回一点，宽度由 lowerWidths 同步扣掉。
function Dashboard:lowerVGap(S)
    return math.floor(ZONE_SPEC.landscape.gap * 2.6 * S)
end

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
    -- 休眠时把看板当屏保：钩子必须在插件加载时就装上，
    -- 这样即使看板没打开（在看书 / 书架），休眠也会显示看板
    self:installScreenSaverHook()
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
--- 把看板配置挂到「设置 → 屏幕 → 屏保」之下（v2.42）。
---
--- 为什么能挂进去：KOReader 的插件菜单项只按 sorting_hint 归位，而
--- frontend/ui/menusorter.lua 的 sort() 对「带 sorting_hint 的项」是这样处理的：
---   local m = self:findById(menu_table["KOMenu:menu_buttons"], sorting_hint)
---   m = m.sub_item_table or m
---   table.insert(m, v)
--- 而 findById 是**递归**遍历 sub_item_table 的，所以 hint 指到哪个子菜单，项就追加进
--- 那个子菜单。readermenu.lua 里注册屏保那一项的写法是
---   self.menu_items.screensaver = { text = T("Sleep screen"),
---       sub_item_table = dofile("frontend/ui/elements/screensaver_menu.lua") }
--- id 正好是 "screensaver"，所以 hint 给 "screensaver" 就落到屏保菜单里，不用改核心文件。
---
--- 一个坑：hint 目标不存在时，menusorter 是**直接把项丢掉**（只有没 hint 的项才会
--- 被塞进第一个标签页当孤儿，带 hint 找不到就 logger.warn 然后什么也不做）。
--- 所以先确认设备支持屏保；不支持就退回「工具」标签页，不能让入口凭空消失。
function Dashboard:addToMainMenu(menu_items)
    local hint = "tools"
    local ok, supports = pcall(function() return Device:supportsScreensaver() end)
    if ok and supports then
        hint = "screensaver"
    end
    menu_items.dashboard_desk = {
        sorting_hint = hint,
        text = T("桌面看板"),
        -- 和屏保自带的那几组设置之间画一条线，视觉上分开
        separator = true,
        sub_item_table = self:genMenuItemTable(),
    }
end

function Dashboard:genMenuItemTable()
    local items = {
        {
            text = T("打开看板"),
            -- 已经打开时这个入口没有意义，看板内弹出的菜单会把它过滤掉
            hide_in_dashboard = true,
            callback = function() self:open() end,
        },
        {
            text = T("立即刷新天气"),
            callback = function() self:fetchWeather(true) end,
        },
        {
            text = T("重新布局"),
            callback = function()
                if self.shown then self:refreshLayout() end
            end,
        },
        {
            text = T("休眠时显示看板（屏保）"),
            help_text = TL(
                "按电源键或空闲自动休眠时，屏幕停留在看板上，而不是 KOReader 的原生屏保。\n"
                .. "e-ink 断电保画面，所以休眠期间看板是静止的，唤醒后继续刷新。",
                "When the device sleeps, the screen keeps showing the dashboard instead of\n"
                .. "KOReader's native screensaver. E-ink holds the image without power,\n"
                .. "so the dashboard is static while asleep and refreshes on wake."),
            checked_func = function() return self:screensaverEnabled() end,
            callback = function()
                local enabled = self:screensaverEnabled()
                G_reader_settings:saveSetting("dashboard_screensaver", not enabled)
                if G_reader_settings.flush then G_reader_settings:flush() end
            end,
        },
    }

    local city_groups = {
        { key = "直辖市", text = T("直辖市") },
        { key = "省会",   text = T("省会与首府") },
        { key = "港澳台", text = T("港澳台") },
    }
    local city_items = {}
    for _, g in ipairs(city_groups) do
        local sub = {}
        for _, c in ipairs(CityData.cities) do
            if c.group == g.key then
                sub[#sub + 1] = {
                    -- 只译显示名：checked/callback 仍用中文名做键，设置里存的也是它
                    text = I18n.city(c),
                    checked_func = function() return self:getCityName() == c.name end,
                    callback = function() self:setCity(c.name) end,
                }
            end
        end
        city_items[#city_items + 1] = { text = g.text, sub_item_table = sub }
    end
    items[#items + 1] = { text = T("选择城市"), sub_item_table = city_items }

    local tz_items = {}
    for _, t in ipairs(CityData.timezones) do
        tz_items[#tz_items + 1] = {
            text = I18n.tzName(t),
            checked_func = function() return self:getTzIana() == t.iana end,
            callback = function() self:setTz(t.iana) end,
        }
    end
    items[#items + 1] = { text = T("选择时区"), sub_item_table = tz_items }

    -- 版式三项**刻意不用 checked_func**。TouchMenu:onMenuSelect 里是这么分支的
    -- （v2025/v2026 一致）：
    --   callback(self)
    --   if item.checked or item.checked_func then   -- 勾选项
    --       self:updateItems()                       -- 只刷新，**不关菜单**
    --   elseif not item.keep_menu_open then
    --       self:closeMenu()                         -- 普通项，回调后自动关
    -- 也就是说「带勾选」和「点完自动关菜单」在 TouchMenu 里是互斥的，之前用
    -- checked_func 就必然点完菜单还杵着。现在改成普通叶子项：点击 → callback 记下
    -- 方向 → TouchMenu 自己 closeMenu() → close_callback → 立刻转屏重排。
    -- 当前方向改用文字标注（不能依赖屏幕旋转结果：转不了屏的机型会退化成纯版式切换）。
    local cur_mode = self:currentOrientationMode()
    local function orientEntry(text, mode)
        return {
            text = (cur_mode == mode) and (text .. T("（当前）")) or text,
            -- TouchMenu 调 callback 时会把**菜单自己**作为第一个参数传进来
            -- （源码注释：Provide callback with us, so it can call our closemenu()）。
            -- 真机上「靠 onMenuSelect 自动关菜单」这条分支没生效，所以这里拿住菜单
            -- 实例，自己去关，不再赌框架行为。
            callback = function(menu) self:setOrientationFromMenu(mode, menu) end,
        }
    end
    items[#items + 1] = {
        text = T("版式（竖屏 / 横屏）"),
        sub_item_table = {
            orientEntry(T("竖屏"), "portrait"),
            orientEntry(T("横屏（向右转 90°）"), "landscape"),
            orientEntry(T("横屏（向左转 90°）"), "landscape_ccw"),
        },
    }

    items[#items + 1] = { text = T("布局组件"), sub_item_table = self:genLayoutMenu() }

    items[#items + 1] = { text = T("语言 / Language"), sub_item_table = self:genLangMenu() }

    items[#items + 1] = { text = T("天气服务"), sub_item_table = self:genWeatherMenu() }

    items[#items + 1] = {
        -- 版本号放这儿：上机时打开菜单扫一眼就知道是不是刚改的那份代码
        text = T("使用说明") .. "  v" .. DASHBOARD_VERSION,
        callback = function()
            UIManager:show(InfoMessage:new{
                text = TL(
                    "手势：点按刷新天气 · 上划退出看板\n"
                    .. "屏幕上缘下滑 → 打开看板菜单（城市 / 时区 / 版式 / 天气服务）\n"
                    .. "看板没打开时：设置 → 屏幕 → 屏保 → 桌面看板（同一套菜单）\n"
                    .. "左右滑动 → 竖屏 ↔ 横屏 互相切换（会真的旋转屏幕）\n\n"
                    .. "Kindle 没有重力感应，机器横过来屏幕不会自己转，\n"
                    .. "所以横屏要靠左右滑动（或菜单「版式」）手动切，切完请把设备横着拿。\n"
                    .. "菜单「版式」里选中一项后会立即关菜单并按新方向重排，不用手动关菜单。\n"
                    .. "若横屏后文字是倒的，到菜单「版式」里换「向左转 90°」那一项。\n\n"
                    .. "右上角显示电量百分比与电量图标（充电时图标反白）。\n"
                    .. "天气优先用和风天气，不可用时自动降级到 Open-Meteo，页脚会标注来源。\n"
                    .. "空闲超时或按电源键休眠时，屏幕会停留在看板上（相当于屏保）。\n"
                    .. "长时间显示建议接通电源；程序每 30 分钟自动全刷一次以清除电泳残影。\n\n"
                    .. "看板版本 v" .. DASHBOARD_VERSION,
                    "Gestures: tap to refresh · swipe up to exit\n"
                    .. "Swipe down from the top edge: dashboard menu (city / time zone / layout)\n"
                    .. "When closed: Settings → Screen → Sleep screen → Desk dashboard\n"
                    .. "Swipe sideways: switch portrait ↔ landscape (really rotates the screen)\n\n"
                    .. "Kindles have no accelerometer, so landscape must be triggered manually\n"
                    .. "by swiping sideways or via the Layout menu; then hold the device sideways.\n"
                    .. "If the landscape text appears upside down, pick the other rotation.\n\n"
                    .. "Top right: battery percentage and icon (inverted while charging).\n"
                    .. "Weather comes from QWeather; if unavailable it falls back to Open-Meteo,\n"
                    .. "and the footer shows the current source.\n"
                    .. "On idle or power-button sleep the screen keeps the dashboard (acts as a\n"
                    .. "screensaver). For long display, keep it plugged in; a full refresh runs\n"
                    .. "every 30 minutes to clear e-ink ghosting.\n\n"
                    .. "Dashboard version v" .. DASHBOARD_VERSION),
            })
        end,
    }
    return items
end

-- ------------------------------------------------------------------ 布局组件菜单
--- 「布局组件」：竖屏 / 横屏 → A/B/C → 该区可选的组件（单选，当前项打勾）。
--- 用 checked_func 会让 TouchMenu「只刷新、不关菜单」，正好方便连续改三个区；
--- 每选一次都会经 onConfigChanged → refreshLayout 立即生效。
function Dashboard:genLayoutMenu()
    local function zone_entry(orient, key, title)
        local sub = {}
        for _, id in ipairs(self:componentIdsFor(orient, key)) do
            local c = COMPONENTS[id]
            local is_default = (ZONE_DEFAULT[orient][key] == id)
            sub[#sub + 1] = {
                text = T(c.label) .. (is_default and (" · " .. T("默认")) or ""),
                checked_func = function()
                    return self:getZoneLayout()[orient][key] == id
                end,
                callback = function() self:setZoneComponent(orient, key, id) end,
            }
        end
        return { text = title, sub_item_table = sub }
    end

    return {
        {
            text = T("竖屏布局"),
            sub_item_table = {
                zone_entry("portrait", "A", T("A 区（上）")),
                zone_entry("portrait", "B", T("B 区（中）")),
                zone_entry("portrait", "C", T("C 区（下）")),
            },
        },
        {
            text = T("横屏布局"),
            sub_item_table = {
                zone_entry("landscape", "A", T("A 区（上）")),
                zone_entry("landscape", "B", T("B 区（左下）")),
                zone_entry("landscape", "C", T("C 区（右下）")),
            },
        },
        {
            text = T("复制竖屏布局到横屏"),
            callback = function() self:copyPortraitLayoutToLandscape() end,
        },
        {
            text = T("恢复默认布局"),
            callback = function() self:resetZoneLayout() end,
        },
    }
end

-- ------------------------------------------------------------------ 语言菜单
--- 语言：auto 跟随 KOReader（未显式设置语言时按中文），或强制 zh / en。
--- 改完立刻重排，菜单保持打开也能看到背后变化。
function Dashboard:genLangMenu()
    local function entry(text, value)
        return {
            text = text,
            checked_func = function() return I18n.setting() == value end,
            callback = function()
                I18n.setLang(value)
                if self.shown then self:refreshLayout() end
            end,
        }
    end
    return {
        entry(T("跟随 KOReader"), "auto"),
        entry("中文", "zh"),
        entry("English", "en"),
    }
end

-- ------------------------------------------------------------------ 天气服务菜单
local SOURCE_NAMES = {
    file = "插件内 dashboard_config.lua",
    local_ = "插件内 dashboard_config.local.lua",
    settings = "设备内录入",
    none = "未配置",
}

--- 「天气服务」子菜单：查看 / 录入凭据、测试连接
function Dashboard:genWeatherMenu()
    -- 这里刻意不在表里预先翻译：语言可以在运行中切换，表若在加载时求值就会
    -- 永远停在启动那一刻的语言。存原文、用时再 T()。
    local function source_name(key)
        if key == "local" then return T(SOURCE_NAMES.local_) end
        return T(SOURCE_NAMES[key] or SOURCE_NAMES.none)
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
                        text = T("取消"),
                        id = "cancel",
                        callback = function() UIManager:close(dialog) end,
                    },
                    {
                        text = T("保存"),
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
            text = T("查看当前凭据"),
            keep_menu_open = false,
            callback = function()
                local cfg = self:getConfig()
                local qw = cfg.qweather or {}
                local lines = {
                    string.format("%s：%s", T("API Host"),
                        (qw.api_host and qw.api_host ~= "") and qw.api_host or T("未填写")),
                    string.format("%s：%s", T("API Key"), QWeather.mask(qw.api_key)),
                    string.format("%s：%s", T("来源"), source_name(cfg._key_source)),
                }
                if qw.credential_id and qw.credential_id ~= "" then
                    lines[#lines + 1] = string.format("%s：%s", T("凭据 ID"), qw.credential_id)
                end
                if qw.project and qw.project ~= "" then
                    lines[#lines + 1] = string.format("%s：%s", T("项目"), qw.project)
                end
                UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n") })
            end,
        },
        {
            text = T("填写 API Host"),
            keep_menu_open = false,
            callback = function()
                open_input(T("和风天气 API Host"),
                    T("控制台「设置」页里的专属地址，形如 abcxyz.qweatherapi.com，不要带 https://"),
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
            text = T("填写 API Key"),
            keep_menu_open = false,
            callback = function()
                open_input(T("和风天气 API Key"),
                    T("控制台「项目管理 - 凭据」里创建，需与上面的 API Host 属于同一项目"),
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
            text = T("测试连接"),
            keep_menu_open = false,
            callback = function()
                self:reloadConfig()
                UIManager:show(InfoMessage:new{
                    text = T("正在连接和风天气…"),
                    timeout = 1,
                })
                self:fetchWeather(true)
            end,
        },
        {
            text = T("清除设备内录入"),
            keep_menu_open = false,
            callback = function()
                G_reader_settings:saveSetting("dashboard_qw_host", "")
                G_reader_settings:saveSetting("dashboard_qw_key", "")
                G_reader_settings:flush()
                self:reloadConfig()
                self:onConfigChanged()
                UIManager:show(InfoMessage:new{
                    text = T("已清除。凭据改由插件目录下的配置文件提供。"),
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

-- ------------------------------------------------------------------ 分区配置
--- 读分区配置。逐项校验：不存在的组件、未获准进该区的组件、旧版本残留的
--- 非法值，一律回落到该区默认，保证任何一份脏设置都能出画面。
function Dashboard:getZoneLayout()
    local saved = G_reader_settings:readSetting("dashboard_components")
    local out = {}
    for _, orient in ipairs({ "portrait", "landscape" }) do
        out[orient] = {}
        for _, key in ipairs(ZONE_KEYS) do
            local id = type(saved) == "table" and type(saved[orient]) == "table"
                and saved[orient][key] or nil
            local comp = id and COMPONENTS[id] or nil
            local allowed = false
            if comp then
                for _, z in ipairs(comp.zones[orient] or {}) do
                    if z == key then allowed = true break end
                end
            end
            out[orient][key] = allowed and id or ZONE_DEFAULT[orient][key]
        end
    end
    return out
end

--- 写某一区的组件，立即重排（与「选择城市」走同一条链路，已上机验证过）
function Dashboard:setZoneComponent(orient, key, id)
    if not (COMPONENTS[id]) then return end
    local layout = self:getZoneLayout()
    layout[orient][key] = id
    G_reader_settings:saveSetting("dashboard_components", layout)
    if G_reader_settings.flush then G_reader_settings:flush() end
    self:onConfigChanged()
end

--- 某方向某区可选的组件 id 列表：默认项排最前，其余按 id 排序（pairs 顺序不定）
function Dashboard:componentIdsFor(orient, key)
    local ids = {}
    for id, comp in pairs(COMPONENTS) do
        for _, z in ipairs(comp.zones[orient] or {}) do
            if z == key then ids[#ids + 1] = id break end
        end
    end
    local def = ZONE_DEFAULT[orient][key]
    table.sort(ids, function(a, b)
        if a == def then return true end
        if b == def then return false end
        return a < b
    end)
    return ids
end

--- 把竖屏三区整套抄给横屏（同名组件在横屏不允许的区会自动回落默认）
function Dashboard:copyPortraitLayoutToLandscape()
    local layout = self:getZoneLayout()
    for _, key in ipairs(ZONE_KEYS) do
        local id = layout.portrait[key]
        local comp = COMPONENTS[id]
        local allowed = false
        for _, z in ipairs(comp and comp.zones.landscape or {}) do
            if z == key then allowed = true break end
        end
        layout.landscape[key] = allowed and id or ZONE_DEFAULT.landscape[key]
    end
    G_reader_settings:saveSetting("dashboard_components", layout)
    if G_reader_settings.flush then G_reader_settings:flush() end
    self:onConfigChanged()
end

--- 恢复默认：直接删键，比写一份默认值更干净（以后改默认值能跟着变）
function Dashboard:resetZoneLayout()
    pcall(function() G_reader_settings:delSetting("dashboard_components") end)
    if G_reader_settings.flush then G_reader_settings:flush() end
    self:onConfigChanged()
end

-- 当前时区下的时间分解（不依赖设备时区设置）
function Dashboard:localNow()
    return os.date("!*t", os.time() + self:getTz().offset * 60)
end

-- ------------------------------------------------------------------ 打开 / 关闭
function Dashboard:open()
    if self.shown then return end
    -- 休眠屏保时画的那棵树可能还在屏幕上（比如唤醒事件没走 close 分支、或者
    -- 用户从菜单里直接打开看板）。先撤掉，否则同一块屏幕上会叠两棵看板树。
    self:dismissSaverFrame()
    self.shown = true
    -- 记下打开前的屏幕方向，关闭时原样恢复，别把整个 KOReader 留在横屏
    self.base_rotation = screen_rotation()
    -- 恢复电源键 + 允许休眠：老版本这里设 preventScreenSaver=1 并 preventStandby，
    -- 结果是按电源键完全没反应。休眠画面由 installScreenSaverHook 接管成看板，
    -- 所以这里不再需要抑制系统屏保。
    self:releaseKindleScreenSaverLock()
    -- 菜单/挂起重排的状态一并清干净，避免上一轮留下的标记把新会话卡住
    self.menu = nil
    self.menu_open = false
    self.relayout_pending = false
    self.pending_orientation = nil
    self._last_tick_ts = os.time()
    self._resume_ts = nil
    -- 沿用上次选定的方向：选了横屏，重启 KOReader 打开看板时仍然是横屏；
    -- 选的是竖屏而设备当前是横的（上次没还原干净），这里也一并转回去
    local mode = G_reader_settings:readSetting("dashboard_orientation")
    if mode ~= "portrait" and mode ~= "landscape" and mode ~= "landscape_ccw" then
        mode = nil
    end
    -- 菜单里的「（当前）」标记要用它；没有存过配置就按屏幕实际方向
    self.orientation_mode = mode or self:getOrientation()
    if mode then
        if self:rotateScreen(mode) then
            -- 转成了：版式由屏幕尺寸自然判定，清掉上一轮留下的强制标记
            self.force_landscape = nil
            self.rotation_changed = (screen_rotation() ~= self.base_rotation)
        else
            -- 转不了就按要的方向排（画面方向不变，至少排版是另一套）。
            -- 注意「竖屏」也要显式写 false，否则上一轮遗留的 true 会让它一直排横屏。
            self.force_landscape = (mode ~= "portrait")
        end
    end
    self:refreshLayout()
    self:fetchWeather()
    self:scheduleTick()
    self:maybeShowSetupHint()
end

--- 首次打开且没有可用凭据时，提示一次「当前在用降级数据源」。
---
--- 为什么需要：凭据缺失时 QWeather.fetch 会返回 nil 并由 Open-Meteo 兜底，界面一切
--- 正常、只是页脚多一行小字。刚部署的人（尤其是从 git clone 后没放
--- dashboard_config.local.lua 的）不会意识到自己在用估算的空气质量，也不会想到去配 key。
---
--- 只在「确实缺 host 或 key」且「从没提示过」时弹一次，配置好之后永久不再打扰。
--- 标记写在 KOReader 全局设置里，卸载插件时随之失效，不需要额外清理。
function Dashboard:maybeShowSetupHint()
    local cfg = self:getConfig()
    local qw = cfg.qweather or {}
    local has_host = qw.api_host and qw.api_host ~= ""
    local has_key = qw.api_key and qw.api_key ~= ""
    if has_host and has_key then return end
    if G_reader_settings:readSetting("dashboard_qw_hint_shown") then return end
    -- 先落标记再弹窗：弹窗本身失败也不该反复弹
    G_reader_settings:saveSetting("dashboard_qw_hint_shown", true)
    if not UIManager or not InfoMessage then return end
    pcall(function()
        UIManager:show(InfoMessage:new{
            text = TL("还没有配置和风天气凭据。\n\n"
                .. "当前天气走 Open-Meteo 降级源：温度、现象、湿度、风力、日出日落都正常，"
                .. "但空气质量是由 PM2.5/PM10 浓度换算出的估算值，不是国标 AQI。\n\n"
                .. "要改用和风天气：\n"
                .. "设置 → 屏幕 → 屏保 → 桌面看板 → 天气服务，"
                .. "填入 API Host 与 API Key（两者需属于同一个和风项目）。\n\n"
                .. "此提示只出现一次。",
                "No QWeather credentials configured.\n\n"
                .. "Weather is currently taken from the Open-Meteo fallback: temperature,\n"
                .. "condition, humidity, wind and sunrise/sunset are fine, but air quality\n"
                .. "is estimated from PM2.5/PM10 instead of the official CN AQI.\n\n"
                .. "To use QWeather: Settings → Screen → Sleep screen → Desk dashboard\n"
                .. "→ Weather service, and fill in API Host and API Key (same project).\n\n"
                .. "This hint appears only once."),
            timeout = 15,
        })
    end)
end

function Dashboard:close()
    if not self.shown then return end
    self.shown = false
    -- 万一是菜单开着的时候被关掉，别让标记卡住导致以后再也不重排；
    -- 菜单控件本身也要撤，否则屏幕上会留一个没人管的孤儿菜单。
    local menu = self.menu
    self.menu = nil
    self.menu_open = false
    self.relayout_pending = false
    self.pending_orientation = nil
    if menu then
        pcall(function() UIManager:close(menu) end)
    end
    -- 屏保用的那棵树同理：正常流程里唤醒时就撤掉了，这里只是兜底
    self:dismissSaverFrame()
    if self._tick_fn then
        UIManager:unschedule(self._tick_fn)
    end
    self._last_tick_ts = nil
    self._resume_ts = nil
    local root = self.root
    self.root = nil
    if root then
        UIManager:close(root)
    end
    self:restoreKindleScreenSaverLock()
    -- 把屏幕转回打开看板前的方向，否则退出看板后整个 KOReader 都是横的
    if self.rotation_changed and self.base_rotation ~= nil and Screen.setRotationMode then
        pcall(function() Screen:setRotationMode(self.base_rotation) end)
        self.rotation_changed = false
        UIManager:setDirty(nil, "full")
    end
end

--- Kindle 屏保总开关：进入看板时放开它。
--- 老版本这里设 preventScreenSaver=1，想的是「别让屏保盖掉看板」，
--- 但 powerd 这个属性的副作用远比预想大：设成 1 之后**电源键会被完全忽略**，
--- 而且不产生可捕获的事件（MobileRead 上做 Kindle 屏保工具的开发者实测原话：
--- "If we set preventScreenSaver to 1, the power button seems to be ignored totally"）。
--- 表现就是按电源键毫无反应、设备也不会自动休眠。
--- 现在改为显式写 0：电源键恢复、设备可以正常休眠（这正是我们要的：
--- 休眠那一刻的画面由下面的屏保钩子接管成看板，比一直亮着省电得多）。
function Dashboard:releaseKindleScreenSaverLock()
    if not Device:isKindle() then return end
    -- 记下进入前的值，退出看板时还原（多数机器是 0）
    if self.saved_prevent_ss == nil then
        self.saved_prevent_ss = readLipcInt("com.lab126.powerd", "preventScreenSaver")
    end
    os.execute("lipc-set-prop -i com.lab126.powerd preventScreenSaver 0")
    logger.dbg("dashboard: preventScreenSaver = 0（放开电源键与自动休眠）")
end

--- 退出看板时把 preventScreenSaver 写回进入前的值。
function Dashboard:restoreKindleScreenSaverLock()
    if not Device:isKindle() then return end
    local value = self.saved_prevent_ss
    if value == nil then return end
    self.saved_prevent_ss = nil
    os.execute(string.format("lipc-set-prop -i com.lab126.powerd preventScreenSaver %d", value))
    logger.dbg("dashboard: preventScreenSaver 还原为", value)
end

-- ---------------------------------------------------------------- 休眠屏保
-- Kindle 的休眠链路（已在本机 KOReader 源码里逐层确认）：
--   按电源键 / 空闲超时
--     → powerd 发事件 → Device:intoScreenSaver()
--       → Screensaver:setup() + Screensaver:show()   ← 屏保在这一步画
--       → powerd:beforeSuspend() → 真正挂起
-- 我们接管 Screensaver.show()：
--   · 看板已经打开 → 屏幕本来就是看板，只要阻止 KOReader 画屏保盖掉它
--   · 看板没打开（在看书 / 书架）→ 现建一棵看板控件树画上去，
--     数据用 init() 时从 dashboard_cache.lua 载入的那一份
-- e-ink 断电保画面，于是整个休眠期间屏幕就停在看板上。
-- 唤醒时接管 Screensaver.close()：撤掉看板，并返回 true 让
-- Kindle:outofScreenSaver 走一次 setDirty("all","full") 把原界面完整刷回来。
--
-- 注意 e-ink 的物理限制：休眠时 CPU 是停的，定时器不走，
-- 所以休眠期间看板是**静止**的（屏保本来就该是静态的），唤醒后才继续刷新。

--- 是否允许看板接管休眠屏保。默认开；设成 false 就完全走 KOReader 原生屏保。
function Dashboard:screensaverEnabled()
    local v = G_reader_settings:readSetting("dashboard_screensaver")
    return v == nil or v == true
end

--- 休眠瞬间：把看板画到屏幕上
function Dashboard:onEnterScreenSaver()
    -- 菜单开着的时候休眠是个坑：屏幕此刻停的是菜单，不是看板，
    -- 冻成屏保就变成一张「设置菜单截图」。先把菜单撤掉、把看板本体重画一次。
    -- 挂起的转屏请求直接丢弃：马上要挂起了，这时转屏既慢又容易刷不干净。
    if self.menu_open or self.menu then
        self.pending_orientation = nil
        self.relayout_pending = false
        local menu = self.menu
        self.menu = nil
        self.menu_open = false
        if menu then
            pcall(function() UIManager:close(menu) end)
        end
        if self.shown then
            self:refreshLayout()
            pcall(function() UIManager:forceRePaint() end)
        end
    end
    if not self.shown then
        self:renderSaverFrame()
    end
    -- Screensaver:show() 本来会设这个标记，我们绕过了它，必须自己设，
    -- 否则唤醒时 Kindle:outofScreenSaver 不会进 close 分支
    Device.screen_saver_mode = true
    self.screensaver_owned = true
end

--- 建一棵看板控件树并画到屏幕上（仅在休眠时用，不启动定时器）
function Dashboard:renderSaverFrame()
    if self.saver_root then return end
    local ok, root = pcall(self.createRoot, self)
    if not ok or not root then
        logger.warn("dashboard: 休眠屏保渲染失败", tostring(root))
        return
    end
    self.saver_root = root
    UIManager:show(root)
    UIManager:setDirty(root, "full")
    -- 挂起紧跟着就发生，必须在这里同步刷完，否则屏幕还停在旧画面上
    pcall(function() UIManager:forceRePaint() end)
end

--- 撤掉休眠时画的那棵看板树（幂等，任何时候调用都安全）
function Dashboard:dismissSaverFrame()
    local root = self.saver_root
    self.saver_root = nil
    if root then
        pcall(function() UIManager:close(root) end)
    end
end

--- 唤醒：撤掉屏保树，并把看板校正到「现在」
function Dashboard:onLeaveScreenSaver()
    self:dismissSaverFrame()
    self.screensaver_owned = false
    if not self.shown then return end
    -- 两个问题一起解决：
    --  · 定时器基于 CLOCK_MONOTONIC，休眠期间不走，唤醒后最多还要再等一整分钟
    --    才到点，这一分钟里屏幕上还是睡前的时钟；
    --  · 电量、日期、农历、跨日（睡过去一整晚）也都是旧的。
    -- 直接重建一次版面最省事，也把电池/日期一次校正。
    self._resume_ts = os.time()
    self:refreshLayout()
    self:scheduleTick()
end

--- 把我们的逻辑挂到 Screensaver 的 show/close 上（只装一次，只在 Kindle 上装）
function Dashboard:installScreenSaverHook()
    if self._ss_hooked or not Device:isKindle() then return end
    local ok, Screensaver = pcall(require, "ui/screensaver")
    if not ok or type(Screensaver) ~= "table" then
        logger.warn("dashboard: 取不到 ui/screensaver，休眠屏保功能不可用")
        return
    end
    self._ss_hooked = true
    local this = self

    local orig_show = Screensaver.show
    Screensaver.show = function(ss, ...)
        if not this:screensaverEnabled() then
            return orig_show(ss, ...)
        end
        local ok2, err = pcall(function() this:onEnterScreenSaver() end)
        if not ok2 then
            -- 接管失败就老老实实退回原生屏保，别把休眠弄坏
            logger.warn("dashboard: 屏保接管失败，回退原生", tostring(err))
            return orig_show(ss, ...)
        end
    end

    local orig_close = Screensaver.close
    Screensaver.close = function(ss, ...)
        if not this.screensaver_owned then
            return orig_close(ss, ...)
        end
        -- 两种情形都会走到这里：
        --  · 看板已打开 → 我们没建 widget，orig_close 会走 cleanup() 把
        --    Device.screen_saver_mode 复位（这是唯一会复位它的地方，别跳过）
        --  · 休眠时现建的看板树 → 由 onLeaveScreenSaver 撤掉
        -- orig_close 必须在撤树之前跑：它内部的 cleanup() 是唯一会把
        -- Device.screen_saver_mode 复位的地方，跳过它下次休眠就进不了 show 分支了。
        -- 它的返回值（「没有 widget」时是 nil）不能用，我们在下面自己返回 true。
        orig_close(ss, ...)
        local ok2, err = pcall(function() this:onLeaveScreenSaver() end)
        if not ok2 then
            logger.warn("dashboard: 唤醒处理失败", tostring(err))
        end
        -- 一律返回 true 让 outofScreenSaver 做一次全屏重绘，把休眠前的界面刷回来。
        return true
    end

    logger.dbg("dashboard: 已接管休眠屏保")
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
    if not self.shown or not self.root then return end
    local wall = os.time()
    local now = self:localNow()

    -- 睡眠/长时间中断后的自愈：两拍 tick 相隔过久，说明中间设备挂起过
    -- （或者被别的东西卡住了）。此时屏幕上的时钟、电量、日期全是旧的，
    -- 直接重建一次版面，比逐项判断省事也更可靠。
    local last_ts = self._last_tick_ts
    self._last_tick_ts = wall
    if last_ts and wall - last_ts > TICK_GAP_REBUILD then
        logger.dbg("dashboard: 距上次 tick", wall - last_ts, "秒，按唤醒处理，重建版面")
        self._resume_ts = self._resume_ts or wall
        self:refreshLayout()
        self:scheduleTick()
        return
    end

    -- 菜单盖在上面的时候不动画面：e-ink 上局部刷新会把菜单区域一起重画，
    -- 每分钟闪一下很难看。菜单关掉后下一拍（≤60 秒）自然就补上了。
    if self.menu_open then
        self:scheduleTick()
        return
    end

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
    -- 刚唤醒的宽限期内先不拉：请求是同步的（http.TIMEOUT=20），会正好卡在
    -- 用户按电源键的那一刻，看起来就是「按了没反应」。
    local fresh = self._resume_ts and (wall - self._resume_ts < RESUME_FETCH_GRACE)
    if not fresh then
        local last = self.weather and self.weather.ts or 0
        local interval = tonumber(self:getConfig().update_interval) or UPDATE_INTERVAL
        if not self.weather then
            interval = 5 * 60
        end
        if wall - last >= interval then
            self:fetchWeather()
        end
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
        return T("天气 Open-Meteo（降级）")
    elseif src == "qweather" then
        return T("天气数据 和风天气")
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
        cond = T("暂无数据"),
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
    -- 中文模式优先用服务端给的现象（比本地表细，如“晴间多云有零星小雨”）；
    -- 英文模式改用代码表反查：接口固定按 lang=zh 取数，中文原文无法逐条对译，
    -- 而代码表覆盖全部现象，翻出来的是统一的标准说法。
    if I18n.lang() == "en" then
        d.cond = T(meta[1])
    else
        d.cond = w.cond or meta[1]
    end

    if w.temp then
        d.temp = string.format("%d°", math.floor(w.temp + 0.5))
    end
    if w.tmin and w.tmax then
        d.range = string.format("%d° ~ %d°",
            math.floor(w.tmin + 0.5), math.floor(w.tmax + 0.5))
    end
    if w.feels then
        d.feels = string.format("%s %d°", T("体感"), math.floor(w.feels + 0.5))
    end
    if w.hum then
        d.hum = string.format("%d%%", math.floor(w.hum + 0.5))
    end
    -- 风向与风级分开返回：三格布局里数值只放“2 级”，风向作为小注，
    -- 否则“东南风 2 级”会超过单格宽度，跨过分隔线串到相邻格。
    -- 风级直接用和风返回的蒲福风级，不再由风速换算。
    d.wind_dir = I18n.windDir(w.winddir)
    d.wind = I18n.windScale(w.wind)
    d.sunrise = w.sunrise
    d.sunset = w.sunset
    return d
end

--- 空气质量展示文本与等级
function Dashboard:airDisplay()
    local a = self.air
    if not a then
        return { text = "--", level = T("暂无数据") }
    end
    -- 国标 AQI 优先；境外城市没有 cn-mee 时按 PM2.5/PM10 回退估算
    local aqi = a.aqi or self:calcAQI(a.pm25, a.pm10)
    if not aqi then
        return { text = "--", level = T("暂无数据") }
    end
    aqi = math.floor(aqi + 0.5)
    -- 服务端返回的等级是中文（优/良/轻度污染……），展示前过一遍词表；
    -- 词表里没有的原样显示，不会变成 nil
    local level = a.level and T(a.level) or nil
    if not level then
        -- 境外城市没有国标 AQI 时，才按 HJ 633-2012 分档
        if aqi <= 50 then level = T("优")
        elseif aqi <= 100 then level = T("良")
        elseif aqi <= 150 then level = T("轻度污染")
        elseif aqi <= 200 then level = T("中度污染")
        elseif aqi <= 300 then level = T("重度污染")
        else level = T("严重污染") end
    end
    return { text = tostring(aqi), level = level }
end

--- 第 i 天预报（1 = 今天）。数据源只给日期，星期在这里补齐，组件只管画。
--- 老缓存没有 daily 字段、或数据源只回了 1 天时返回 nil，组件显示 "--" 而不是崩。
function Dashboard:dailyAt(i)
    local w = self.weather
    if not w or type(w.daily) ~= "table" then return nil end
    local d = w.daily[i]
    if type(d) ~= "table" or type(d.date) ~= "table" then return nil end
    if not d.wd then
        -- 与 buildCalendar 用同一套换算：1=周日 … 7=周六
        d.wd = (Lunar.days_from_civil(d.date.y, d.date.m, d.date.d) + 4) % 7 + 1
    end
    return d
end

--- 从今天起最多 n 天的预报（数据不足就返回短的，不补空壳）
function Dashboard:forecastDays(n)
    local out = {}
    for i = 1, (n or 7) do
        local d = self:dailyAt(i)
        if not d then break end
        out[#out + 1] = d
    end
    return out
end

--- 月相：和风的每日预报带 moonPhase（它自己的天文引擎算的），优先用它；
--- 降级源不给这个字段，回落到本地 dashboard_moon（已与和风 10 天逐日对到 10/10）。
--- 亮面比例两路都用本地算——和风不提供这个数值。
function Dashboard:moonInfo(ctx)
    local day = self:dailyAt(1)
    local hour = (ctx.now.hour or 12) + (ctx.now.min or 0) / 60
    local phase = Moon.phase(ctx.now.year, ctx.now.month, ctx.now.day,
        ctx.tz.offset, hour)
    local name = (day and day.moonphase) or phase.name
    return {
        name = name,
        label = I18n.moonPhase(name),
        ratio = phase.ratio,
        from_api = (day and day.moonphase) ~= nil,
    }
end

--- 从一份 DocSettings 里抠出书名 / 作者 / 页数 / 进度，读不到的字段就留空。
--- ds 在真机上是 DocSettings 实例（userdata 或 table 都有可能），
--- 所以每个 readSetting 都单独 pcall，不让一个字段读失败带走整张卡。
local function read_doc_info(ds, out)
    if ds == nil then return out end
    local function setting(key)
        local ok, v = pcall(function() return ds:readSetting(key) end)
        if ok then return v end
        return nil
    end
    local stats = setting("stats")
    if type(stats) == "table" then
        if type(stats.title) == "string" and stats.title ~= "" then out.title = stats.title end
        if type(stats.authors) == "string" and stats.authors ~= "" then out.authors = stats.authors end
        out.pages = tonumber(stats.pages) or out.pages
    end
    local t = setting("title")
    if not out.title and type(t) == "string" and t ~= "" then out.title = t end
    local a = setting("authors")
    if not out.authors and type(a) == "string" and a ~= "" then out.authors = a end
    local pct = tonumber(setting("percent_finished"))
    if pct then out.percent = math.max(0, math.min(1, pct)) end
    local dp = tonumber(setting("doc_pages"))
    if dp and not out.pages then out.pages = dp end
    return out
end

--- 在读卡：优先活文档（从阅读界面打开看板时进度最新），
--- 拿不到再读 KOReader 的 lastfile 侧车——看板当屏保时（在书架/休眠）也有内容。
--- 两路都失败就返回 nil，组件整块不画，不会画出一个空卡。
function Dashboard:readingInfo()
    local info = {}

    -- 1) 活文档
    local ui = self.ui
    if ui then
        local ok_doc, doc = pcall(function() return ui.document end)
        if ok_doc and doc then
            local ok_set, ds = pcall(function() return ui.doc_settings end)
            if ok_set and ds then read_doc_info(ds, info) end
            -- 页内进度兜底：有些书没有 percent_finished，用当前页/总页数
            if not info.percent then
                local ok_page, page = pcall(function() return ui:getCurrentPage() end)
                local ok_cnt, cnt = pcall(function() return doc:getPageCount() end)
                if ok_page and ok_cnt and tonumber(page) and tonumber(cnt)
                    and tonumber(cnt) > 0 then
                    info.percent = math.max(0, math.min(1, page / cnt))
                    info.pages = info.pages or cnt
                end
            end
            if info.title then
                info.source = "live"
                return info
            end
        end
    end

    -- 2) lastfile 侧车（屏保 / 书架场景）
    local ok_path, path = pcall(function() return G_reader_settings:readSetting("lastfile") end)
    if ok_path and type(path) == "string" and path ~= "" then
        local ok_req, DocSettings = pcall(require, "docsettings")
        if ok_req and type(DocSettings) == "table" and DocSettings.open then
            local ok_open, ds = pcall(function() return DocSettings:open(path) end)
            if ok_open and ds then read_doc_info(ds, info) end
        end
        if not info.title then
            -- 侧车读不到（新书还没生成 / 权限问题）就用文件名，总比空着强
            info.title = path:match("([^/\\]+)%.[^%.]+$") or path
        end
        info.source = "last"
        return info
    end

    return nil
end

--- 电量与网络状态。网络部分全走 pcall：KOReader 的 NetworkMgr 在不同版本上
--- 方法名有出入，取不到就只显示电量那一半，不影响整块。
function Dashboard:netInfo()
    local cap, charging = self:batteryInfo()
    local info = { cap = cap, charging = charging }
    local function call(name)
        local ok, v = pcall(function() return NetworkMgr[name](NetworkMgr) end)
        if ok then return v end
        return nil
    end
    local on = call("isWifiOn")
    if on ~= nil then info.wifi_on = on and true or false end
    local conn = call("isConnected")
    if conn ~= nil then info.connected = conn and true or false end
    return info
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
        return string.format("%s %s", T("更新于"),
            os.date("!%H:%M", w.ts + ctx.tz.offset * 60))
    end
    return T("尚未获取天气")
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

--- 当前生效的方向（给菜单打「（当前）」标记用）。
--- 不能直接用 getOrientation()：那是按屏幕真实旋转反推的，转不了屏的机型
--- 会退化成「只换版式」，此时屏幕永远是竖的，标记就会一直指在「竖屏」上。
function Dashboard:currentOrientationMode()
    if self.orientation_mode then return self.orientation_mode end
    return self:getOrientation()
end

--- 切换方向（portrait / landscape / landscape_ccw）并重建版面。
--- 优先真旋转屏幕——只有这样才能让「设备横过来」时画面是正的；万一这台设备
--- 转不了（Screen 没有 setRotationMode，或调了不生效），退化成「只换版式」：
--- 画面方向不变，仅换成另一套排版，至少内容不再是当前那一套。
function Dashboard:setOrientation(mode)
    if mode ~= "landscape" and mode ~= "landscape_ccw" then mode = "portrait" end
    -- 记下「用户想要的」方向，菜单里打标记用它（见 currentOrientationMode）
    self.orientation_mode = mode
    -- 看板没打开时不要动屏幕：那会把整个 KOReader 界面转过去，而看板没开就没有
    -- close 来还原，用户会卡在横屏的阅读界面里回不来。此时只记住选择，打开时再生效。
    if not self.shown then
        G_reader_settings:saveSetting("dashboard_orientation", mode)
        if G_reader_settings.flush then G_reader_settings:flush() end
        UIManager:show(InfoMessage:new{
            text = T("已记住，下次打开看板时按这个方向显示"),
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
        text = rotated and T("已转为横屏，请把设备横着拿（再左右滑一下可转回竖屏）")
            or T("已切换为横屏版式（本机不支持转屏）")
    else
        text = T("已转回竖屏")
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
            -- 用户点菜单外面、按返回键、或者我们自己调 closeMenu()，
            -- 最终都会汇到这里；统一在 onMenuClosed 里收尾（撤控件 + 执行挂起的动作）
            close_callback = function() self:onMenuClosed(menu) end,
        }
        -- 打个标记：万一 self.menu 引用丢了，还能 closeOrphanMenu() 按它把窗口找回来
        menu._dashboard_menu = true
        -- 先存引用再 show：万一 show 期间因为重入把状态搅乱，也不会出现
        -- 「菜单在屏幕上、self.menu 却是 nil」——那会让 closeMenu 直接放弃关闭。
        self.menu = menu
        UIManager:show(menu)
    end)
    if not ok then
        -- 版本差异导致菜单弹不出来时不能把看板一起拖下水。
        -- 但窗口可能已经加进栈了，引用必须留着，否则屏幕上会留个关不掉的菜单。
        self.menu = menu
        self.menu_open = (menu ~= nil)
        logger.warn("dashboard: TouchMenu 构造失败", tostring(err))
        if not menu then
            return self:menuFallback()
        end
        return
    end
end

--- 菜单真正关掉之后要做的事：撤控件 + 执行菜单里挂起的动作。
--- 由 TouchMenu 的 close_callback 调用（点外面、按返回、我们自己关，三条路都到这里）。
function Dashboard:onMenuClosed(menu)
    if menu then
        if self.menu == menu then self.menu = nil end
        if self._closed_menu == menu then
            -- 已经由 setOrientationFromMenu 主动关掉了，不再重复 close
            self._closed_menu = nil
        else
            -- 这里**不做 self.menu == menu 的判断**：菜单窗口可能因为别的路径已经从
            -- self.menu 上摘掉了，但人还留在窗口栈里。判断失败就跳过 close，结果就是
            -- 「菜单关不掉、版式不生效」。UIManager:close 对不在栈里的控件是空操作，
            -- 重复调用无害，所以直接关。
            pcall(function() UIManager:close(menu) end)
        end
    end
    self.menu_open = false
    local mode = self.pending_orientation
    self.pending_orientation = nil
    logger.dbg("dashboard: 菜单已关闭，待执行方向 =", tostring(mode),
        "待重排 =", tostring(self.relayout_pending))
    if mode then
        -- 菜单里选的方向等到这时才真正执行：菜单控件是按旧尺寸排的，边转边排版会错位
        self.relayout_pending = false
        self:setOrientation(mode)
    elseif self.relayout_pending then
        self.relayout_pending = false
        self:refreshLayout()
    end
end

--- 主动关掉看板内的菜单（菜单里选完东西要立即生效时用）。
--- 返回 true 表示确实关了一个菜单。
function Dashboard:closeMenu()
    local menu = self.menu
    if not menu then
        self.menu_open = false
        return false
    end
    if type(menu.closeMenu) == "function" then
        local ok, err = pcall(function() menu:closeMenu() end)
        if ok then
            -- close_callback 正常已经跑过了；个别版本不触发的话这里兜一次，
            -- 否则 menu_open 会一直为 true，看板从此再也不重排。
            if self.menu == menu then self:onMenuClosed(menu) end
            return true
        end
        logger.warn("dashboard: 菜单关闭失败", tostring(err))
    end
    self:onMenuClosed(menu)
    return true
end

--- 兜底：把看板自己弹出的菜单从窗口栈里揪出来撤掉。
--- 正常路径用不上（我们手里有菜单实例），但真机上出现过「菜单还在屏幕上、
--- self.menu 却是 nil」的情况——那时任何基于 self.menu 的关闭手段都会空转，
--- 只能按标记去窗口栈里找。菜单在 openMenu 里被打了 _dashboard_menu 标记，
--- 所以不会误伤 KOReader 自己的菜单或别的窗口。
function Dashboard:closeOrphanMenu()
    local stack = UIManager._window_stack
    if type(stack) ~= "table" then return false end
    for i = #stack, 1, -1 do
        local entry = stack[i]
        local w = entry and entry.widget
        if w and w._dashboard_menu then
            pcall(function() UIManager:close(w) end)
            logger.dbg("dashboard: 兜底撤掉了一个孤儿菜单")
            return true
        end
    end
    return false
end

--- 菜单里选了屏幕方向。
---
--- 真机上踩过两次，结论是**不能指望 TouchMenu 帮我们关菜单**：
---   1) 带 checked_func 时，onMenuSelect 走 `updateItems()` 分支，根本不关菜单；
---   2) 去掉 checked_func 后，理论上该走 `elseif not keep_menu_open then closeMenu()`
---      自动关，实测仍然不关（那一条在设备上没生效）。
--- 所以这里改成自己动手：TouchMenu 调 callback 时会把菜单实例作为参数传进来，
--- 拿住它直接 UIManager:close()——同步执行、一定生效——然后再转屏重排。
--- 菜单关闭与转屏之间不再有任何异步环节。
function Dashboard:setOrientationFromMenu(mode, menu)
    -- 从 KOReader 主菜单里进来时既没有看板菜单、也没有 menu 实参，走普通路径
    -- （含「看板没打开」的处理）。判断条件是「两者都没有」而不是只看 menu_open：
    -- 万一 menu_open 标记因为别的原因没置上、但菜单确实开着，照样要能关掉它。
    if not self.menu_open and not menu then
        return self:setOrientation(mode)
    end
    self.orientation_mode = mode
    G_reader_settings:saveSetting("dashboard_orientation", mode)
    if G_reader_settings.flush then G_reader_settings:flush() end

    -- 撤菜单。menu 来自 callback 的实参；万一某个版本不传，退回 self.menu；
    -- 连 self.menu 都没有时，按标记去窗口栈里找（见 closeOrphanMenu）。
    local m = menu or self.menu
    if m then
        -- 记一笔：onMenuSelect 返回后 TouchMenu 可能还会自己 closeMenu() 一次，
        -- onMenuClosed 看到这个标记就跳过重复 close（对已出栈的控件再 close 会重复
        -- 触发 CloseWidget 事件，没必要）。
        self._closed_menu = m
        pcall(function() UIManager:close(m) end)
    else
        self:closeOrphanMenu()
    end
    self.menu = nil
    self.menu_open = false
    self.pending_orientation = nil
    self.relayout_pending = false
    logger.dbg("dashboard: 菜单里选方向", mode, "，菜单已撤，开始转屏")

    -- 立刻按新方向重排：转屏 + 重建控件树 + setDirty(nil,"full") 整屏重绘
    self:setOrientation(mode)
    return true
end

--- 菜单弹不出来时的兜底提示，告诉用户从哪还能进设置
function Dashboard:menuFallback()
    UIManager:show(InfoMessage:new{
        text = TL("这个 KOReader 版本无法在看板内弹出菜单。\n"
            .. "请先上划退出看板，再从阅读界面上缘下拉 → 设置 → 屏幕 → 屏保 → 桌面看板。\n\n"
            .. "看板内可直接用的手势：点按刷新、上划退出、左右滑动重新布局。",
            "This KOReader build cannot open the menu inside the dashboard.\n"
            .. "Swipe up to exit, then pull down from the top edge → Settings → Screen\n"
            .. "→ Sleep screen → Desk dashboard.\n\n"
            .. "Gestures available inside: tap to refresh, swipe up to exit,\n"
            .. "swipe sideways to switch layout."),
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
        -- 顶栏这类「高度固定的一行」不能折行：折了就把 header 顶高，
        -- 下面的三区预算全部跟着缩水。传 ellipsis 时改成像真机那样截断加省略号。
        truncate_with_ellipsis = opts.ellipsis or nil,
    }
end

--- 把纵向余量吸进「分块之间的空白」。
--- 只放大 mkPad 打上 is_gap 标记的顶层留白行：字号不动、宽度不动（左右只剩 52px
--- 余量，任何放大字号的改法都会立刻横向撑破版心）。块内部的 mkPad 在子控件里，
--- 不在 body 顶层，天然不受影响。
---
--- 判定必须靠显式标记，**绝对不能**用「row.color == nil」这类逐字段探测：
--- COLOR_BLACK 是 ffi cdata（ffi/blitbuffer.lua:161 `Color8 = ffi.typeof(...)`），
--- LuaJIT 里 cdata 与 nil 比较会走 ColorRGB32_mt.__eq，而它第一行就是
--- color:getColorRGB32()，参数为 nil 直接崩：
---   ffi/blitbuffer.lua:601: attempt to index local 'color' (a nil value)
---   ← main.lua:1079 stretchGaps ← build ← createRoot ← refreshLayout ← open
--- 这是真机 crash.log 里实测到的崩溃（2026-11-11 20:12），桩件抓不到：桩件里
--- COLOR_BLACK 是数字 255、跑的是 PUC Lua，`table == nil` 不会触发 __eq。
local function stretchGaps(body, vk)
    if not vk or vk == 1 then return end
    for i = 1, #body do
        local row = body[i]
        local dimen = row.dimen
        if row.is_gap and type(dimen) == "table" and dimen.h > 1 then
            dimen.h = math.max(1, math.floor(dimen.h * vk))
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
    local S, edge, avail_w, avail_h = self:contentBox(W, H)
    -- 版心宽度：所有行都按它排，长横线随之内缩，四边自然留出 edge
    ctx.edge = edge
    ctx.body_w = avail_w

    -- vk 是「分块之间空白」的纵向放大系数：只动上下空白，不动文字也不动宽度
    local function build(vk)
        ctx.S = S
        local b = landscape and self:buildLandscape(ctx) or self:buildPortrait(ctx)
        -- 拉伸只是锦上添花。这里必须兜住：一旦抛出，整个看板会连带崩掉（真机上
        -- 表现为 KOReader 直接重启），而不拉伸只是上下紧一点。
        local ok, err = pcall(stretchGaps, b, vk)
        if not ok then
            logger.warn("dashboard: 间距自适应失败，按原间距排版", tostring(err))
        end
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
                -- 休眠屏保用的那棵树也带着这套触摸区，屏幕一唤醒的第一下触摸会落到
                -- 它上面；若这时去同步拉天气，用户看到的就是「唤醒后卡住」。
                if not self.shown then return false end
                self:fetchWeather(true)
                return true
            end,
        },
        {
            id = "dashboard_swipe_up",
            ges = "swipe",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            handler = function(ges)
                if not self.shown then return false end
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
                if not self.shown then return false end
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
                if not self.shown then return false end
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
    local left = self:makeText(ctx, string.format("%s · %s",
        I18n.city(self:getCity()), I18n.headerTz(ctx.tz)), 26,
        { max_width = left_w, ellipsis = true })
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
--- 等分状态格：湿度 / 风力 / AQI，或电量 / 网络。
--- 总宽传进来、格宽在这里算：分隔线本身也占 1 px，先从总宽扣掉再等分，
--- 否则 3 格会溢出 2 px（600x800 横屏 C 区实测 323>321，宽检查抓出来的）。
function Dashboard:buildStatCells(ctx, total_w, items)
    local n = #items
    local cell_w = math.floor((total_w - (n - 1)) / n)
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

-- ---------------------------------------------------------------- 分区装配
--- 建一个区：按当前配置取组件 → 在固定盒子里从 k=1 起逐档收紧字号，直到装得下。
--- 盒子宽高固定，组件内容在盒内居中（Stack 默认居中对齐），所以换组件不会
--- 牵动别的区；装不下也绝不裁切，只记日志交给 createRoot 的全局缩放兜底。
function Dashboard:buildZone(ctx, orient, key, box_w, content_w, box_h)
    local id = self:getZoneLayout()[orient][key]
    local comp = COMPONENTS[id] or COMPONENTS[ZONE_DEFAULT[orient][key]]
    local method = comp.build
    local child
    for i = 1, #K_LADDER do
        child = self[method](self, ctx, content_w, box_h, K_LADDER[i])
        if child:getSize().h <= box_h then break end
        if i == #K_LADDER then
            logger.warn(string.format(
                "dashboard: 组件 %s 在 %s 区（高 %d）收到最小档仍占 %d，交给全局缩放",
                id, key, box_h, child:getSize().h))
        end
    end
    return mkBox(box_w, box_h, child)
end

--- 一条横向分隔线（宽度取版心宽，与四边留白对齐）
local function sepLine(w, px)
    return Solid:new{
        dimen = Geom:new{ w = w, h = math.max(2, math.floor(px)) },
        color = COLOR_BLACK,
    }
end

-- ---------------------------------------------------------------- 竖屏：三区
function Dashboard:buildPortrait(ctx)
    local W, S = ctx.body_w or ctx.W, ctx.S
    local spec = ZONE_SPEC.portrait
    local pad = math.floor(spec.pad * S)
    local content_w = W - pad * 2
    local gap = math.floor(spec.gap * S)
    local rows = {}
    local function push(x) rows[#rows + 1] = x end

    push(self:buildHeader(ctx, pad))
    push(mkPad(W, gap))
    push(sepLine(W, spec.sep * S))
    push(mkPad(W, gap))

    -- 时钟控件只由 clock_weather 组件产生；清空必须放在循环**外**，
    -- 否则建完 A 再建 B/C 时会把刚设好的引用清掉（桩件有断言专门抓这个）
    self.clock_widget = nil
    for i, key in ipairs(ZONE_KEYS) do
        push(self:buildZone(ctx, "portrait", key, W, content_w, math.floor(spec[key] * S)))
        if i < #ZONE_KEYS then
            push(mkPad(W, gap))
            push(sepLine(W, spec.sep2 * S))
            push(mkPad(W, gap))
        end
    end

    push(mkPad(W, gap))
    push(self:buildHintRow(ctx, content_w, pad, 17))
    return VerticalGroup:new{ align = "left", unpack(rows) }
end

-- ---------------------------------------------------------------- 横屏：A + 下半
function Dashboard:buildLandscape(ctx)
    local W, S = ctx.body_w or ctx.W, ctx.S
    local spec = ZONE_SPEC.landscape
    local pad = math.floor(spec.pad * S)
    local avail = W - pad * 2
    local gap = math.floor(spec.gap * S)
    local rows = {}
    local function push(x) rows[#rows + 1] = x end

    push(self:buildHeader(ctx, pad))
    push(mkPad(W, gap))
    push(sepLine(W, spec.sep * S))
    push(mkPad(W, gap))

    self.clock_widget = nil
    push(self:buildZone(ctx, "landscape", "A", W, avail, math.floor(spec.A * S)))

    push(mkPad(W, gap))
    push(sepLine(W, spec.sep2 * S))
    push(mkPad(W, gap))

    -- 下半区：左 B / 竖线 / 右 C。宽度由可用空间反推——固定列宽在 300ppi 的
    -- 1448px 屏上会让右栏被挤出屏幕，所以 B 的列宽先算，C 吃掉剩下的。
    local bw, cw, vline_w = self:lowerWidths(avail, S)
    local vgap = self:lowerVGap(S)
    local lower_h = math.floor(spec.lower * S)

    local left = self:buildZone(ctx, "landscape", "B", bw, bw, lower_h)
    local right = self:buildZone(ctx, "landscape", "C", cw, cw, lower_h)
    push(HorizontalGroup:new{
        align = "top",
        mkPad(pad, 1),
        left,
        mkPad(vgap, 1),
        Solid:new{ dimen = Geom:new{ w = vline_w, h = lower_h }, color = COLOR_BLACK },
        mkPad(vgap, 1),
        right,
        mkPad(pad, 1),
    })

    push(mkPad(W, gap))
    push(self:buildHintRow(ctx, avail, pad, 20))
    return VerticalGroup:new{ align = "left", unpack(rows) }
end

-- ---------------------------------------------------------------- 组件实现
-- 统一签名：(ctx, w, h, k) → widget。w 是内容列宽，h 是盒子高，k 是密度系数。
-- 约定：只缩字号与间距，**不改宽度**（左右只有 6.4mm 留白，撑宽必然破版）。

--- 节气文案：中英两套句法，别用拼接硬套
function Dashboard:termText(ctx, with_next)
    local ratio, elapsed, remain = self:solarTermRatio(ctx)
    local cur = I18n.term(ctx.cur_term.name)
    if I18n.lang() == "en" then
        if ctx.cur_term.is_today then
            return string.format("%s · starts today", cur), ratio, elapsed, remain
        end
        if with_next and ctx.next_term then
            -- 不能写成 "%d days to %s"：中文这行只有 14 个字，英文同义句要 46 个
            -- 字符，26 号字下会超出内容列宽（实测 1214 > 920）而被迫折行。
            -- 下一个节气的名字在进度条右端已经标出，这里只说还剩几天。
            return string.format("%s · day %d · %dd left", cur, elapsed or 1,
                remain or 0), ratio, elapsed, remain
        end
        return string.format("%s · day %d", cur, elapsed or 1), ratio, elapsed, remain
    end
    local text
    if ctx.cur_term.is_today then
        text = string.format("%s · 今日交节", cur)
    elseif with_next and ctx.next_term then
        text = string.format("%s 第%d天 · 距%s%d天", cur, elapsed, ctx.next_term.name, remain)
    else
        text = string.format("%s 第%d天", cur, elapsed or 1)
    end
    return text, ratio, elapsed, remain
end

--- 时钟与天气：左时钟+日期，右图标+温度+现象+体感
function Dashboard:compClockWeather(ctx, w, h, k)
    local S = ctx.S
    local land = ctx.landscape
    self.clock_text = string.format("%02d:%02d", ctx.now.hour, ctx.now.min)
    self.clock_widget = self:makeText(ctx, self.clock_text,
        math.floor((land and 82 or 112) * k))
    local clock_block = VerticalGroup:new{
        align = "left",
        self.clock_widget,
        mkPad(1, math.floor(6 * S * k)),
        self:makeText(ctx, I18n.dateLine(ctx.now, not land),
            math.floor((land and 28 or 32) * k)),
    }
    local min_gap = math.floor(14 * S)
    local weather = self:buildWeatherBlock(ctx,
        math.floor((land and 78 or 76) * k),
        math.floor((land and 60 or 50) * k),
        math.max(math.floor(w * 0.42), w - clock_block:getSize().w - min_gap))
    local fill = math.max(min_gap, w - clock_block:getSize().w - weather:getSize().w)
    return HorizontalGroup:new{
        align = "center",
        clock_block,
        mkPad(fill, 1),
        weather,
    }
end

--- 农历与节气：标签 + 农历大字（右干支生肖）+ 节气文案 + 进度条 + 两端刻度
function Dashboard:compLunar(ctx, w, h, k)
    local S = ctx.S
    local rows = {}
    local function push(x) rows[#rows + 1] = x end

    push(CenterContainer:new{
        dimen = Geom:new{ w = w, h = math.floor(28 * S * k) },
        self:makeText(ctx, T("农历"), math.floor(20 * k), { gray = true }),
    })
    push(mkPad(w, math.floor(2 * S * k)))

    local side = VerticalGroup:new{
        align = "left",
        self:makeText(ctx, Lunar.ganzhi_year(ctx.lunar), math.floor(30 * k)),
        mkPad(1, math.floor(4 * S * k)),
        self:makeText(ctx, I18n.zodiacYear(Lunar.zodiac(ctx.lunar)),
            math.floor(22 * k), { gray = true }),
    }
    local big = self:makeText(ctx, Lunar.month_day_text(ctx.lunar), math.floor(54 * k))
    local fill = math.max(math.floor(20 * S), w - big:getSize().w - side:getSize().w)
    push(HorizontalGroup:new{
        align = "center",
        big,
        mkPad(fill, 1),
        side,
    })
    push(mkPad(w, math.floor(14 * S * k)))

    local term_text, ratio = self:termText(ctx, true)
    push(HorizontalGroup:new{
        align = "center",
        -- 两处都为了英文：同一句英文的字符数是中文的三倍左右。
        -- ① 字号 26→23：实测 26 号时该行占 878/920，真机 ASCII 略宽就会折行；
        -- ② max_width 兜底：不给上限时它连 1214 都敢画出去（溢出屏幕）。
        self:makeText(ctx, term_text,
            math.floor((I18n.lang() == "en" and 23 or 26) * k), { max_width = w }),
    })
    push(mkPad(w, math.floor(10 * S * k)))
    push(HorizontalGroup:new{
        align = "center",
        ProgressBar:new{
            dimen = Geom:new{ w = w, h = math.max(8, math.floor(10 * S * k)) },
            ratio = ratio,
            border = math.max(1, math.floor(2 * S)),
        },
    })
    push(mkPad(w, math.floor(8 * S * k)))

    local cur = I18n.term(ctx.cur_term.name)
    local nxt = ctx.next_term and I18n.term(ctx.next_term.name) or ""
    local left_label = self:makeText(ctx, cur, math.floor(20 * k), { gray = true })
    local right_label = self:makeText(ctx, nxt, math.floor(20 * k), { gray = true })
    push(HorizontalGroup:new{
        align = "center",
        left_label,
        mkPad(math.max(0, w - left_label:getSize().w - right_label:getSize().w), 1),
        right_label,
    })
    return VerticalGroup:new{ align = "left", unpack(rows) }
end

--- 三格状态：湿度 / 风力 / 空气质量
function Dashboard:compStats(ctx, w, h, k)
    local d = self:weatherDisplay()
    local air = self:airDisplay()
    return self:buildStatCells(ctx, w, {
        { T("湿度"), d.hum or "--" },
        { T("风力"), d.wind or "--", d.wind_dir },
        { "AQI", air.text, air.level },
    })
end

--- 月历的格宽与列距。抽成独立方法是为了让桩件能直接断言排布，
--- 不必通过「渲染一遍再猜树里的宽度」来验证。
--- 返回：格宽、列距、行高（三者都是像素）
function Dashboard:calendarMetrics(w, S, k)
    k = k or 1
    local row_h = math.floor(36 * S * k)
    -- 基准格宽：先按字号给（52 设计单位），再被盒宽压住，最后兜一个下限
    local base = math.min(math.floor(52 * S * k), math.floor(w / 7))
    base = math.max(math.floor(34 * S * k), base)
    -- 铺满目标：7·cw + 6·(ratio·cw) = w  →  cw = w / (7 + 6·ratio)
    -- 竖屏内容列 920 时算出 103（原来固定 92，两侧各空 138）：现在列距 32、总宽 913
    -- 横屏内容列 630 时算出 70 < base 90，于是仍按 90 铺满、列距为 0（维持原样）
    local by_fill = math.floor(w / (7 + 6 * CAL_GAP_RATIO))
    local cell_w = math.max(base, math.min(by_fill, math.floor(row_h * CAL_ASPECT_MAX)))
    -- 兜底：盒子窄到放不下 7×最小格宽时，宁可压缩格子也不许溢出（白名单里
    -- 月历只允许进宽区，这条分支实际走不到，但不该留一个会破版的漏洞）
    cell_w = math.min(cell_w, math.max(1, math.floor(w / 7)))
    local col_gap = self:calendarGap(w, cell_w)
    return cell_w, col_gap, row_h
end

--- 给定盒宽与格宽，算出还能给多少列距（不会把总宽撑出盒子）
function Dashboard:calendarGap(w, cell_w)
    local slack = (w - 7 * cell_w) / 6
    local gap = math.min(cell_w * CAL_GAP_RATIO, slack)
    if gap <= 0 then return 0 end
    return math.floor(gap)
end

--- 月历：格子边长受字号与盒宽双重约束；富余的横向空间优先给列距，
--- 这样 7 列会铺开到接近内容列宽，而不是挤在中间、两侧各空一大片。
function Dashboard:compCalendar(ctx, w, h, k)
    local cell_w, col_gap = self:calendarMetrics(w, ctx.S, k)
    local cal = self:buildCalendar(ctx, cell_w, k, col_gap)
    -- 行高是 6 行固定量：装不下时按比例压格子，列距同步重算
    local need = cal:getSize().h
    if need > h and need > 0 then
        local ratio = h / need
        cell_w = math.max(math.floor(20 * ctx.S), math.floor(cell_w * math.sqrt(ratio)))
        col_gap = self:calendarGap(w, cell_w)
        cal = self:buildCalendar(ctx, cell_w, k, col_gap)
    end
    return cal
end

--- 侧栏三合一：农历 / 节气 / 天文与空气
function Dashboard:compSidePanel(ctx, w, h, k)
    return self:buildSidePanel(ctx, w, k, h)
end

-- ---------------------------------------------------------------- v2.45 新组件
-- 统一约定（与前面五个组件一致）：
--   · 字号传「设计单位」，Font:getFace 内部会乘短边倍率；
--   · 图标边长、间距这类像素量必须自己乘 ctx.S；
--   · 盒子高度 h 是像素，用来判断装不装得下；
--   · 宽度只做「不超出 w」的约束，不硬撑——横屏左右只剩 6.4mm 留白。

--- 把若干块横向排开，把剩余宽度均分成间隔。
--- 为什么不用固定列宽：一列里「14°/1°」和「-10°/-18°」宽度差一截，
--- 固定列宽在大负数时会把文字压出格子；均分剩余空隙则永远贴边不溢出。
local function spreadRows(blocks, total_w)
    local used, n = 0, #blocks
    for _, b in ipairs(blocks) do used = used + b:getSize().w end
    local gap = (n > 1) and math.floor(math.max(0, total_w - used) / (n - 1)) or 0
    local items = { align = "center" }
    for i, b in ipairs(blocks) do
        if i > 1 then items[#items + 1] = mkPad(gap, 1) end
        items[#items + 1] = b
    end
    return HorizontalGroup:new(items)
end

--- 温度文案「14°」；取不到给 "--"
local function degText(v)
    if not v then return "--" end
    return string.format("%d°", math.floor(v + 0.5))
end

--- 某天预报的图标名：数据源给的是现象代码，换成本地图标表
function Dashboard:dayIcon(day)
    if not day or not day.code then return "partly" end
    local meta = QWeather.condition(day.code)
    return meta[2]
end

--- 两段 "HH:MM" 之间的分钟差（日落 - 日出 = 白昼），跨零点按 +24h 处理
local function minutesBetween(from_hm, to_hm)
    if type(from_hm) ~= "string" or type(to_hm) ~= "string" then return nil end
    local h1, m1 = from_hm:match("^(%d%d):(%d%d)")
    local h2, m2 = to_hm:match("^(%d%d):(%d%d)")
    if not (h1 and h2) then return nil end
    local a = tonumber(h1) * 60 + tonumber(m1)
    local b = tonumber(h2) * 60 + tonumber(m2)
    if b < a then b = b + 1440 end
    return b - a
end

--- 大字时钟（A 区）：只有时钟与日期，比「时钟与天气」更纯粹。
--- 仍然登记 self.clock_widget：tick 靠它逐分钟改字，不登记时钟就停在打开那一刻。
function Dashboard:compClockBig(ctx, w, h, k)
    local S, land = ctx.S, ctx.landscape
    self.clock_text = string.format("%02d:%02d", ctx.now.hour, ctx.now.min)
    self.clock_widget = self:makeText(ctx, self.clock_text,
        math.floor((land and 88 or 124) * k))
    return VerticalGroup:new{
        align = "center",
        self.clock_widget,
        mkPad(1, math.floor((land and 6 or 10) * S * k)),
        self:makeText(ctx, I18n.dateLine(ctx.now, not land),
            math.floor((land and 26 or 30) * k), { gray = true }),
    }
end

--- 纯天气（A 区）：大图标 + 温度 + 现象 + 高低温，不放时钟
function Dashboard:compWeatherBig(ctx, w, h, k)
    local S, land = ctx.S, ctx.landscape
    local d = self:weatherDisplay()
    local icon_w = math.floor((land and 84 or 112) * S * k)
    local side_max = math.max(math.floor(80 * S),
        w - icon_w - math.floor(16 * S))
    local side = VerticalGroup:new{
        align = "left",
        -- 竖屏温度 92→86：真机字号要再乘 1.79（Font:getFace 里走 scaleBySize），
        -- 92 时整列 410 px，比 A 区的 400 px 高出一截，只能靠 K_LADDER 缩字收场
        self:makeText(ctx, d.temp, math.floor((land and 70 or 86) * k),
            { max_width = side_max }),
        self:makeText(ctx, d.cond, math.floor((land and 26 or 32) * k),
            { max_width = side_max }),
        self:makeText(ctx, d.range or "--", math.floor((land and 20 or 24) * k),
            { gray = true, max_width = side_max }),
        -- 竖屏 A 区又高又宽，只放三行会显得空；补一行体感（横屏放不下就不放）
        land and mkPad(1, 1) or self:makeText(ctx, d.feels or "", math.floor(19 * k),
            { gray = true, max_width = side_max }),
    }
    return HorizontalGroup:new{
        align = "center",
        ImageWidget:new{
            file = self:iconPath(d.icon), width = icon_w, height = icon_w,
            scale_factor = 0, alpha = true,
        },
        mkPad(math.floor(16 * S * k), 1),
        side,
    }
end

--- 今日 + 后三日：左边今日大块，右边三列（标签 / 图标 / 高温 / 低温）
function Dashboard:compToday3d(ctx, w, h, k)
    local S, land = ctx.S, ctx.landscape
    local days = self:forecastDays(4)
    if #days == 0 then
        return CenterContainer:new{
            dimen = Geom:new{ w = w, h = math.floor(h) },
            self:makeText(ctx, T("暂无数据"), math.floor(26 * k), { gray = true }),
        }
    end
    local d = self:weatherDisplay()
    -- 横屏 A 区只有 162 设计单位高，今日块的图标与温度各降一档就正好放下（289 内）
    local icon_w = math.floor((land and 46 or 72) * S * k)
    local today_max = math.max(math.floor(90 * S), math.floor(w * 0.30))
    local today = VerticalGroup:new{
        align = "center",
        ImageWidget:new{
            file = self:iconPath(d.icon), width = icon_w, height = icon_w,
            scale_factor = 0, alpha = true,
        },
        self:makeText(ctx, d.temp, math.floor((land and 40 or 58) * k),
            { max_width = today_max }),
        self:makeText(ctx, d.cond, math.floor((land and 20 or 24) * k),
            { gray = true, max_width = today_max }),
        self:makeText(ctx, d.range or "--", math.floor((land and 18 or 22) * k),
            { gray = true, max_width = today_max }),
    }
    local blocks = { today }
    for i = 2, #days do
        local day = days[i]
        local di = math.floor((land and 26 or 36) * S * k)
        blocks[#blocks + 1] = VerticalGroup:new{
            align = "center",
            self:makeText(ctx, I18n.dayLabel(i, day.wd), math.floor((land and 15 or 18) * k),
                { gray = true }),
            mkPad(1, math.floor(3 * S * k)),
            ImageWidget:new{
                file = self:iconPath(self:dayIcon(day)), width = di, height = di,
                scale_factor = 0, alpha = true,
            },
            mkPad(1, math.floor(3 * S * k)),
            self:makeText(ctx, degText(day.tmax), math.floor((land and 20 or 24) * k)),
            self:makeText(ctx, degText(day.tmin), math.floor((land and 17 or 20) * k),
                { gray = true }),
        }
    end
    -- 等宽单元格再居中：按内容宽度平分留白的话，横屏 A 区 1276 宽会摊出
    -- 三个 200 px 的大豁口（今日块本来就比「明天/后天/周六」宽），看着像四块散落。
    -- 切成 w/4 的等宽格子，每块在自己格里居中，节奏就匀了。
    local cell_w = math.floor(w / #blocks)
    local cells = { align = "center" }
    for _, b in ipairs(blocks) do
        cells[#cells + 1] = mkBox(cell_w, 1, b, { align = "center", auto_h = true })
    end
    return HorizontalGroup:new(cells)
end

--- 一周预报：横屏 A 区又宽又矮，排 7 列；其余场合逐行排（更像列表，好扫）。
function Dashboard:compWeek(ctx, w, h, k)
    local S, land = ctx.S, ctx.landscape
    local days = self:forecastDays(7)
    if #days == 0 then
        return CenterContainer:new{
            dimen = Geom:new{ w = w, h = math.floor(h) },
            self:makeText(ctx, T("暂无数据"), math.floor(26 * k), { gray = true }),
        }
    end
    local as_columns = land and h < math.floor(400 * S)

    if as_columns then
        -- 七列各吃 w/7：竖屏设备被强制成横屏版式时 B 区只有 413~420 px，
        -- 原来那套字号排下来要 430 px，得整块缩到 k=0.94。窄盒里各降一档就正好。
        local narrow = w < math.floor(300 * S)
        local label_px = narrow and 14 or 16
        local icon_du = narrow and 24 or 30
        local hi_px = narrow and 18 or 21
        local lo_px = narrow and 16 or 18
        local blocks = {}
        for i, day in ipairs(days) do
            local di = math.floor(icon_du * S * k)
            blocks[#blocks + 1] = VerticalGroup:new{
                align = "center",
                self:makeText(ctx, I18n.dayLabel(i, day.wd), math.floor(label_px * k), { gray = true }),
                mkPad(1, math.floor(3 * S * k)),
                ImageWidget:new{
                    file = self:iconPath(self:dayIcon(day)), width = di, height = di,
                    scale_factor = 0, alpha = true,
                },
                mkPad(1, math.floor(3 * S * k)),
                self:makeText(ctx, degText(day.tmax), math.floor(hi_px * k)),
                self:makeText(ctx, degText(day.tmin), math.floor(lo_px * k), { gray = true }),
            }
        end
        return spreadRows(blocks, w)
    end

    -- 逐行：日期靠左、温度靠右，中间用弹性留白撑开。
    -- 不这么排的话 7 行会挤在版面中间、右侧空一大片（实测过：整块只占 350/920）。
    local dense = h < math.floor(230 * S)
    local label_px = dense and 17 or 19
    local hi_px = dense and 20 or 22
    local lo_px = dense and 17 or 19
    local icon_du = dense and 22 or 26
    local row_gap = dense and 4 or 6
    local label_w = math.floor(w * 0.22)
    -- 温度列用固定宽度的右对齐盒子：不然「1°」和「-2°」宽度不同，
    -- 七行的右边缘会参差不齐（渲染图里一眼就能看出来）。
    local hi_w = self:makeText(ctx, "-20°", math.floor(hi_px * k)):getSize().w
    local lo_w = self:makeText(ctx, "-20°", math.floor(lo_px * k)):getSize().w
    -- 降水概率也要定宽：0% 与 10% 差 17 px，不定宽的话「有概率的行」整行左移，
    -- 七行的温度列就对不成一条竖线（预览图里 777/760/760 三档错位）。
    local pop_w = self:makeText(ctx, "100%", math.floor(17 * k)):getSize().w
    local rows = { align = "center" }
    for i, day in ipairs(days) do
        local di = math.floor(icon_du * S * k)
        local label = mkBox(label_w, 1, self:makeText(ctx,
            I18n.dayLabel(i, day.wd), math.floor(label_px * k)), { align = "left", auto_h = true })
        local icon = ImageWidget:new{
            file = self:iconPath(self:dayIcon(day)), width = di, height = di,
            scale_factor = 0, alpha = true,
        }
        local hi = mkBox(hi_w, 1, self:makeText(ctx, degText(day.tmax), math.floor(hi_px * k)),
            { align = "right", auto_h = true })
        local lo = mkBox(lo_w, 1, self:makeText(ctx, degText(day.tmin), math.floor(lo_px * k),
            { gray = true }), { align = "right", auto_h = true })
        -- 没有降水概率的日子留一个等宽空格子，保证七行的列宽完全一致
        local pop = mkBox(pop_w, 1, day.pop and self:makeText(ctx,
            string.format("%d%%", math.floor(day.pop + 0.5)),
            math.floor(17 * k), { gray = true }) or nil, { align = "left", auto_h = true })
        local gap1 = math.floor(12 * S * k)
        local gap2 = math.floor(10 * S * k)
        local used = label_w + di + gap1 + hi_w + gap2 + lo_w + gap2 + pop_w
        -- 图标摆整行中间，留白分成前后两段。
        -- 之前是「图标紧贴日期、留白全塞在图标和温度之间」，920 宽的竖屏上
        -- 图标和温度之间空出 330 px，看着像图标漏在左边、右侧一大片白。
        local slack = math.max(0, w - used)
        local min_pad = math.floor(8 * S)
        local fill1, fill2
        if slack < min_pad * 2 then
            fill1, fill2 = 0, slack
        else
            local icon_left = math.floor((w - di) / 2)
            fill1 = math.min(math.max(icon_left - label_w, min_pad), slack - min_pad)
            fill2 = slack - fill1
        end
        local row = { align = "center", label, mkPad(fill1, 1), icon, mkPad(fill2, 1), hi,
            mkPad(gap2, 1), lo, mkPad(gap2, 1), pop }
        if i > 1 then rows[#rows + 1] = mkPad(1, math.floor(row_gap * S * k)) end
        rows[#rows + 1] = HorizontalGroup:new(row)
    end
    return VerticalGroup:new(rows)
end

--- 在读卡：书名 / 作者 / 进度条 / 百分比。
--- 书名只画一行并带省略号——真机书名动辄二三十字，折行会把盒子顶破。
function Dashboard:compReading(ctx, w, h, k)
    local S = ctx.S
    local info = self:readingInfo()
    if not info then
        return CenterContainer:new{
            dimen = Geom:new{ w = w, h = math.floor(h) },
            self:makeText(ctx, T("暂无在读"), math.floor(26 * k), { gray = true }),
        }
    end
    local rows = {
        align = "left",
        self:makeText(ctx, T("在读"), math.floor(18 * k), { gray = true }),
        mkPad(1, math.floor(4 * S * k)),
        self:makeText(ctx, info.title, math.floor(30 * k), { max_width = w, ellipsis = true }),
    }
    if info.authors then
        rows[#rows + 1] = self:makeText(ctx,
            T("作者") .. " " .. info.authors, math.floor(18 * k), { gray = true })
    end
    local pct = info.percent or 0
    rows[#rows + 1] = mkPad(1, math.floor(10 * S * k))
    -- 进度条铺满整宽：它是这一块的「最宽元素」，宽度决定整块被盒子居中后
    -- 的左边界。取 0.72w 时整块只有 662 宽，居中后文字比下面的一周预报内缩了 130 px。
    rows[#rows + 1] = ProgressBar:new{
        dimen = Geom:new{ w = math.floor(w), h = math.max(8, math.floor(10 * S * k)) },
        ratio = pct,
        border = math.max(1, math.floor(2 * S)),
    }
    local pct_text = string.format("%d%%", math.floor(pct * 100 + 0.5))
    if info.pages then
        pct_text = pct_text .. string.format(" · %d %s", info.pages, T("页"))
    end
    rows[#rows + 1] = mkPad(1, math.floor(4 * S * k))
    rows[#rows + 1] = self:makeText(ctx, pct_text, math.floor(20 * k), { gray = true })
    return VerticalGroup:new(rows)
end

--- 日月（B/C 区）：日出 / 日落 / 月相三列；高度富余时补白昼与月升月落。
--- 注释一律**不进三列**，改在下面单独成行：
---   窄盒（横屏 B 区最窄只到 413 px）里三列各带注释时总宽 525 px，直接顶出盒子；
---   单独成行后每行都能 max_width 折行，宽窄两种盒子都不用另写一套版式。
function Dashboard:compSunMoon(ctx, w, h, k)
    local S = ctx.S
    local d = self:weatherDisplay()
    local moon = self:moonInfo(ctx)
    local day = self:dailyAt(1)
    local daylen = minutesBetween(d.sunrise, d.sunset)
    local tall = h >= math.floor(250 * S)
    -- 三列各占 (w - 2×列距)/3：窄盒里大字再按 36 设计单位会被挤破，按盒宽退到 26
    local big_px = (w < math.floor(300 * S)) and 26 or (tall and 36 or 32)
    local col_gap = math.floor(18 * S * k)
    local col_w = math.max(math.floor(60 * S), math.floor((w - col_gap * 2) / 3))

    -- 列宽是硬边界：正文长度随语言变（英文 "Waxing crescent" 是中文「盈凸月」的三倍多），
    -- 先用正常字号、装不进列宽就逐档退，退到底还宽才折行。
    local function column(label, big)
        local str = big or "--"
        local px = big_px
        for _, cand in ipairs({ big_px, big_px - 6, big_px - 12 }) do
            px = cand
            if self:makeText(ctx, str, math.floor(cand * k)):getSize().w <= col_w then break end
        end
        return VerticalGroup:new{
            align = "center",
            self:makeText(ctx, label, math.floor(18 * k), { gray = true }),
            mkPad(1, math.floor(4 * S * k)),
            self:makeText(ctx, str, math.floor(px * k), { max_width = col_w }),
        }
    end

    local moon_note
    if day and day.moonrise and day.moonset then
        moon_note = string.format("%s %s · %s %s",
            T("月升"), day.moonrise, T("月落"), day.moonset)
    else
        moon_note = string.format("%s %d%%", T("亮面"), math.floor(moon.ratio * 100 + 0.5))
    end
    if not moon.from_api then
        moon_note = moon_note .. " · " .. T("本机计算")
    end
    local daylen_text
    if daylen then
        daylen_text = string.format("%s %dh%02dm", T("白昼"),
            math.floor(daylen / 60), daylen % 60)
    end

    local cols = spreadRows({
        column(T("日出"), d.sunrise),
        column(T("日落"), d.sunset),
        column(T("月相"), moon.label),
    }, w)
    if not tall then return cols end
    -- 高度够时补两行注释：白昼时长 / 月升月落。都给 max_width，长文案折行不收边。
    local rows = {
        align = "center",
        cols,
        mkPad(1, math.floor(12 * S * k)),
        self:makeText(ctx, daylen_text or moon_note, math.floor(17 * k),
            { gray = true, max_width = w }),
    }
    if daylen_text then
        rows[#rows + 1] = mkPad(1, math.floor(6 * S * k))
        rows[#rows + 1] = self:makeText(ctx, moon_note, math.floor(17 * k),
            { gray = true, max_width = w })
    end
    return VerticalGroup:new(rows)
end

--- 空气明细：AQI 大数 + 等级/首要，下面 2×3 六项浓度。
--- 等级与首要**另起一行**放在 AQI 下面：并排时 AQI 三位数（如 142）会把
--- 「轻度污染」挤到数字上，视觉上像叠字。竖排最稳，窄区也不怕。
function Dashboard:compAirDetail(ctx, w, h, k)
    local S = ctx.S
    local air = self:airDisplay()
    local parts = (self.air and self.air.parts) or {}
    local by_code = {}
    for _, p in ipairs(parts) do by_code[p.code] = p end

    local primary = self.air and self.air.primary
    local sub = air.level or ""
    if primary then
        sub = sub .. " · " .. T("首要") .. " " .. I18n.pollutant(primary)
    end
    -- 给个「AQI」标签：光一个 65 摆在版面上没人知道是啥（三格状态那边也是标签在上）。
    -- 但窄盒里要能去掉——横屏 B 区只有 553 高，带标签就得整块缩字号（实测 588>543），
    -- 所以两种头都备着，装不下就退到没标签那版。
    local head_full = VerticalGroup:new{
        align = "left",
        self:makeText(ctx, "AQI", math.floor(17 * k), { gray = true }),
        mkPad(1, math.floor(2 * S * k)),
        self:makeText(ctx, air.text or "--", math.floor(56 * k)),
        self:makeText(ctx, sub, math.floor(21 * k), { gray = true, max_width = w }),
        mkPad(1, math.floor(12 * S * k)),
    }
    local head_bare = VerticalGroup:new{
        align = "left",
        self:makeText(ctx, air.text or "--", math.floor(56 * k)),
        self:makeText(ctx, sub, math.floor(21 * k), { gray = true, max_width = w }),
        mkPad(1, math.floor(12 * S * k)),
    }
    local rows = { align = "left" }

    -- 六项按 POLLUTANT_ORDER 轮询：缺哪项就补一格 "--"，格子不错位。
    -- 浓度格式跟着单位走：mg/m³（CO）保留一位小数，μg/m³ 取整——
    -- CO 的 0.8 与 2.6 取整后会变成 1 和 3，差别就很明显了。
    local cells, order = {}, I18n.POLLUTANT_ORDER
    for _, code in ipairs(order) do
        local p = by_code[code]
        local value = "--"
        if p and p.value then
            local num = (p.unit == "mg/m³")
                and string.format("%.1f", p.value)
                or tostring(math.floor(p.value + 0.5))
            value = num .. " " .. p.unit
        end
        cells[#cells + 1] = self:makeText(ctx,
            I18n.pollutant(code) .. " " .. value, math.floor(18 * k), { max_width = w })
    end

    -- 列数按实测宽度选，不能写死三列：竖屏 920 宽三列刚好，横屏 C 区只有 650 宽，
    -- 三列会把最后两格顶到屏幕外（实测溢出 95 px）。
    -- 判据是「最宽那格 × 列数 ≤ 盒宽」——等宽栅格里每格只有 w/列数，
    -- 按「每行之和」判会放过一格比格宽还宽的情况，相邻两格就叠在一起了。
    local max_cell = 0
    for _, c in ipairs(cells) do
        max_cell = math.max(max_cell, c:getSize().w)
    end
    local per_row = 1
    for _, cand in ipairs({ 3, 2 }) do
        if max_cell * cand <= w then per_row = cand; break end
    end
    local cell_w = math.floor(w / per_row)

    -- 等宽栅格、格内左对齐。不用 spreadRows：两列时它会把格子推到版面两端
    -- （横屏 C 区 733 宽，左边「PM2.5 109」右边「PM10 112」，中间空一大条），
    -- 栅格排下来才像一张表，六项也好对位。
    for i = 1, #cells, per_row do
        local line = { align = "left" }
        for j = 0, per_row - 1 do
            local c = cells[i + j]
            if c then
                line[#line + 1] = mkBox(cell_w, 1, c, { align = "left", auto_h = true })
            end
        end
        rows[#rows + 1] = HorizontalGroup:new(line)
        if i + per_row <= #cells then
            rows[#rows + 1] = mkPad(1, math.floor(8 * S * k))
        end
    end
    local grid = VerticalGroup:new(rows)
    local out = VerticalGroup:new{ align = "left", head_full, grid }
    if out:getSize().h > h then
        out = VerticalGroup:new{ align = "left", head_bare, grid }
    end
    return out
end

--- 电量网络（C 区）：电量百分比（充电中另有标注）+ WiFi 开关与连接状态
function Dashboard:compBatteryNet(ctx, w, h, k)
    local net = self:netInfo()
    local wifi_text
    if net.wifi_on == nil then
        wifi_text = "--"
    elseif not net.wifi_on then
        wifi_text = T("未开启")
    elseif net.connected then
        wifi_text = T("已连接")
    else
        wifi_text = T("未连接")
    end
    local items = {
        {
            T("电量"),
            net.cap and string.format("%d%%", net.cap) or "--",
            net.charging and T("充电中") or nil,
        },
        { T("网络"), wifi_text, nil },
    }
    return self:buildStatCells(ctx, w, items)
end

--- 整月日历：周一起始、跨月补位、今天反白、节气日带点
function Dashboard:buildCalendar(ctx, cell_w, kf, col_gap)
    -- kf 是密度系数：盒子装不下时整体收紧字号与行高，格子宽度由调用方先给
    -- col_gap 是列与列之间的空隙（像素），由 compCalendar 按盒宽算好后传进来
    kf = kf or 1
    col_gap = col_gap or 0
    local S = ctx.S * kf
    local function mt(str, px, opts)
        return self:makeText(ctx, str, math.floor(px * kf), opts)
    end
    local now = ctx.now
    -- 单元格内容为「日号 + 圆点」，约 36 设计单位高，设定值低于此不起作用
    local row_h = math.floor(36 * S)
    local head_h = math.floor(24 * S)

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
        mt(I18n.monthTitle(now), 22, { gray = true }),
    }
    lines[#lines + 1] = mkPad(1, math.floor(4 * S))

    -- 表头：一 二 三 四 五 六 日（英文为 Su Mo Tu We Th Fr Sa）
    local head = { align = "center" }
    for i = 0, 6 do
        local wd = (2 + i - 1) % 7 + 1
        local is_weekend = (wd == 1 or wd == 7)
        if i > 0 and col_gap > 0 then head[#head + 1] = mkPad(col_gap, 1) end
        head[#head + 1] = mkBox(cell_w, head_h, self:makeText(ctx,
            I18n.weekdayHead(wd), 18, { gray = is_weekend }))
    end
    lines[#lines + 1] = HorizontalGroup:new(head)

    -- 6 行 × 7 列，共 42 格，不足处留空
    for r = 0, 5 do
        local row = { align = "center" }
        for c = 0, 6 do
            if c > 0 and col_gap > 0 then row[#row + 1] = mkPad(col_gap, 1) end
            local idx = r * 7 + c
            local daynum = first + idx - lead
            if idx < lead or daynum >= first + month_len then
                -- 前月补位 / 后月补位：跨月显示，用灰字
                local y2, m2, d2 = Lunar.civil_from_days(daynum)
                row[#row + 1] = mkBox(cell_w, row_h, VerticalGroup:new{
                    align = "center",
                    mt(tostring(d2), 19, { gray = true }),
                    mkPad(1, 1),
                }, { auto_h = true })
            else
                local y2, m2, d2 = Lunar.civil_from_days(daynum)
                local is_today = (daynum == today_num)
                local term = terms[d2]
                local num_text = mt(tostring(d2), is_today and 21 or 19,
                    { fg = nil })
                if is_today then
                    num_text.fgcolor = COLOR_WHITE
                end
                local stack = VerticalGroup:new{
                    align = "center",
                    num_text,
                    mkPad(1, math.floor(1 * S)),
                    term
                        and Solid:new{ dimen = Geom:new{ w = math.floor(6 * S), h = math.floor(6 * S) }, color = COLOR_BLACK }
                        or mkPad(math.floor(6 * S), math.floor(6 * S)),
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

    lines[#lines + 1] = mkPad(1, math.floor(4 * S))
    lines[#lines + 1] = HorizontalGroup:new{
        align = "center",
        Solid:new{ dimen = Geom:new{ w = math.floor(10 * S), h = math.floor(10 * S) }, color = COLOR_BLACK },
        mkPad(math.floor(6 * S), 1),
        mt(T("今天"), 17, { gray = true }),
        mkPad(math.floor(16 * S), 1),
        Solid:new{ dimen = Geom:new{ w = math.floor(6 * S), h = math.floor(6 * S) }, color = COLOR_BLACK },
        mkPad(math.floor(6 * S), 1),
        mt(T("节气"), 17, { gray = true }),
    }

    return VerticalGroup:new{ align = "left", unpack(lines) }
end

--- 横屏右栏：农历 / 节气进度 / 天文与空气
-- 横屏纵向只有「短边」那么多（PW3 为 1072px，折合 600 设计单位），
-- 右栏又是下半区里最高的一列，所以这里的字号与间距比竖屏更克制。
function Dashboard:buildSidePanel(ctx, width, kf, max_h)
    kf = kf or 1
    local S = ctx.S * kf
    local function mt(str, px, opts)
        return self:makeText(ctx, str, math.floor(px * kf), opts)
    end
    local ratio, elapsed, remain = self:solarTermRatio(ctx)
    local d = self:weatherDisplay()
    local air = self:airDisplay()

    local items = {
        align = "left",
        mt(T("农历"), 18, { gray = true }),
        mkPad(1, math.floor(2 * S)),
        mt(Lunar.month_day_text(ctx.lunar), 32),
        mkPad(1, math.floor(4 * S)),
        mt(string.format("%s · %s", Lunar.ganzhi_year(ctx.lunar),
            I18n.zodiacYear(Lunar.zodiac(ctx.lunar))), 20, { gray = true }),
        mkPad(1, math.floor(8 * S)),
        Solid:new{ dimen = Geom:new{ w = width, h = 1 }, color = COLOR_GRAY },
        mkPad(1, math.floor(8 * S)),
        mt(T("节气"), 18, { gray = true }),
        mkPad(1, math.floor(2 * S)),
        mt(I18n.termProgress(I18n.term(ctx.cur_term.name), elapsed or 1), 26),
        mkPad(1, math.floor(6 * S)),
        ProgressBar:new{
            dimen = Geom:new{ w = math.floor(width * 0.82), h = math.max(8, math.floor(10 * S)) },
            ratio = ratio,
            border = math.max(1, math.floor(2 * S)),
        },
        mkPad(1, math.floor(4 * S)),
        mt(ctx.next_term
            and I18n.termCountdown(I18n.term(ctx.next_term.name), remain)
            or "", 18, { gray = true }),
        mkPad(1, math.floor(8 * S)),
        Solid:new{ dimen = Geom:new{ w = width, h = 1 }, color = COLOR_GRAY },
        mkPad(1, math.floor(8 * S)),
        mt(T("天文与空气"), 18, { gray = true }),
        mkPad(1, math.floor(3 * S)),
        mt(string.format("%s %s   %s %s",
            T("日出"), d.sunrise or "--:--", T("日落"), d.sunset or "--:--"), 19),
        mkPad(1, math.floor(4 * S)),
        mt(string.format("%s   %s AQI %s",
            d.feels or "--", T("空气"), air.text), 19),
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
    if src == "open-meteo" then return T("Open-Meteo 降级") end
    if src == "qweather" then return T("和风天气") end
    return nil
end

--- 单行操作提示文案（竖屏横屏共用，只有一个版本）
function Dashboard:hintLine()
    local line = T("点按刷新 · 上划退出 · 顶部下滑菜单 · 左右滑动换版式")
    if self:getConfig().show_attribution then
        local src = self:sourceShort()
        if src then line = line .. " · " .. src end
    end
    return line
end

-- ------------------------------------------------------------------ 数据换算
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
                    text = T("当前未连接网络。接入 WiFi 后会自动重试。"),
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
                err = (err and (err .. "；") or "") .. tostring(e2 or T("降级同样失败"))
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
                text = string.format(T("天气更新失败：%s"), err or T("未知原因")),
                timeout = 5,
            })
        end
        if self.shown then
            self:refreshLayout()
        end
    end)
end

return Dashboard
