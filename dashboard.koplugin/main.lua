--[[--
桌面看板（dashboard.koplugin） v2

全屏常驻显示，按屏幕方向自动切换版式：
  · 竖屏（H > W）  仪表盘版式：顶部城市条 + 大时钟 + 天气 + 农历大字 + 节气进度条 + 底部三格
  · 横屏（W >= H） 上下分区版式：顶部城市条 + 大时钟与天气 + 整月日历网格 + 农历节气

显示内容：每个区各选一个组件（菜单「外观 → 竖屏布局 / 横屏布局」里换）。可选组件：
  时钟与天气 / 农历与节气 / 三格状态 / 月历 / 侧栏（v2.44 及以前）
  大字时钟 / 纯天气 / 今日+三日 / 一周预报 / 在读卡 / 日月 / 空气明细 / 电量网络（v2.45 新增）
月相优先用和风的 astro.moonphase，降级时由 dashboard_moon.lua 现算（日月黄经差）。
在读卡的封面由 dashboard_cover.lua 取（渲染引擎位图 → 缩到卡片尺寸存 PNG 缓存）。

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
  顶层固定 6 组（外观 / 地点与天气 / 内容 / 显示与省电 / 语言 / 使用说明），
  因为 TouchMenu 一页最多 10 条、横屏只有 9 条，超过就要翻页（v2.60 前的 15 条平铺
  正是这个问题）。加新项请挂进已有的组，或在组内再加一层，不要往顶层堆。

设计要点（均已按 KOReader 源码核对，非猜测）：
  · Widget:paintTo 基类是空实现，自绘控件必须自己实现 paintTo，getSize 返回 self.dimen
  · WidgetContainer:paintTo 不处理 background，白底必须自己刷，否则透出下层界面
  · TextWidget 支持 setText() 与 fgcolor（官方示例即用 Blitbuffer.COLOR_DARK_GRAY）
  · 不要用 UIManager:preventStandby()：会让设备永不休眠、看板一直刷。
    休眠/唤醒的接管点在 Screensaver.show / close，见下面「休眠屏保」一节
  · HTTPS 走 socket.http（KOReader 自带 LuaSec 集成），失败再退到 ssl.https

看板打开之后的状态机（每一条都已按 KOReader 上游源码核对）：
  触摸            点按刷新天气；上划退出；左右滑切版式；上缘下滑开菜单
  空闲但未超时      按「时钟刷新」粒度只重画时钟那一块（默认 5 分钟），全刷按周期清残影
                    （默认 60 分钟）；两项都可在菜单「显示与省电 → 省电设置」里改
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
-- 封面模块单独一个文件：它要 require 渲染引擎与 lfs，失败面比别处大，
-- 这里用 pcall 兜住——模块缺失时在读卡只是没有封面，不该让整个看板起不来。
local ok_cover, Cover = pcall(require, "dashboard_cover")
if not ok_cover then Cover = nil end
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
-- 按 IP 粗略定位：只在用户主动点菜单时联网，不参与日常刷新
local Geo = require("dashboard_geo")
local Moon = require("dashboard_moon")
-- 倒数日 / 待办的数据层（存盘、日期运算、输入解析都在里面，本文件只管画）
local Agenda = require("dashboard_agenda")

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

-- 墨阶（v2.53）。全部取 17 的倍数：Carta 面板把任何灰度 floor 到 17 的倍数，
-- 写 0xE6 出来就是 0xDD、写 0xF2 出来是 0xEE。实测见 device-tools/calib/RESULTS.md。
--   PAPER  0xEE  纸底。比纯白低一档，大面积铺开像微微泛灰的纸，不刺眼
--   CARD   0xFF  卡面。正文/数值都落在白卡上，对比度才够
--   RULE   0xCC  卡片边框、进度槽。落在 0xEE 纸底上仍是 2 档差，1px 看得见
--   RULE_SOFT 0xDD 白卡内的细分隔线（白底 1px 可见下限）
--   INK2   0x66  三级文字：标签、注释、单位
--   INK3   0x88  最浅文字，只在 ≥30px（17 设计单位）时用，再小就发虚
local PAPER     = Blitbuffer.COLOR_GRAY_E or Blitbuffer.COLOR_WHITE
local RULE      = Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_GRAY
local RULE_SOFT = Blitbuffer.COLOR_GRAY_D or Blitbuffer.COLOR_GRAY
-- 卡片边：比 RULE 深一档。0xCC 落在 0xEE 纸底上只有 2 档差，300ppi 的 1px 线太飘；
-- 0xBB 是 3 档，边"立"得住，又远没到黑线那种切断版面的程度。
local CARD_EDGE = Blitbuffer.COLOR_GRAY_B or RULE
local INK1      = Blitbuffer.COLOR_GRAY_3 or Blitbuffer.COLOR_BLACK
local INK2      = Blitbuffer.COLOR_GRAY_6 or Blitbuffer.COLOR_BLACK
local INK3      = COLOR_GRAY

-- 衬线字体：设备上 NotoSerif-Regular.ttf 只有拉丁字形，中文会回退到黑体。
-- 所以**只给纯数字串**用，且同一行不能有汉字（否则一行里两种字形打架）。
-- Font:getFace 对不在 fontmap 里的名字当文件名处理（frontend/ui/font.lua:279），
-- 不需要改 fontmap。
local FACE_SERIF = "NotoSerif-Regular.ttf"

-- 插件自身目录（icons 相对此目录）
local PLUGIN_DIR = (function()
    local src = (debug.getinfo(1, "S").source or ""):gsub("^@", "")
    return src:match("^(.*)[/\\][^/\\]+$") or "."
end)()

-- ------------------------------------------------------------------ 省电参数
-- 全部可由用户覆盖（菜单「省电设置」），键名集中在这里，避免散落各处。
-- 默认值偏省电，但界面看起来仍然「活着」：时钟 5 分钟一跳、天气 1 小时一拉。
local POWER_KEYS = {
    tick_step = "dashboard_tick_step",          -- 分钟；0 = 只在触摸/唤醒时刷新
    weather = "dashboard_weather_interval",     -- 秒
    full_refresh = "dashboard_full_refresh",    -- 分钟；0 = 关闭
    low_battery = "dashboard_low_battery",      -- 百分比；0 = 关闭
}

local TICK_STEP = 5                  -- 时钟刷新粒度（分钟）
local UPDATE_INTERVAL = 60 * 60      -- 天气拉取间隔（秒）
local FULL_REFRESH_PERIOD = 60       -- 全刷周期（分钟），清残影
local LOW_BATTERY_GUARD = 10         -- 电量低于此值：降频 + 停掉自动拉天气与全刷
local LOW_BATTERY_TICK_STEP = 30     -- 低电时至少降到这么久一跳
local FETCH_BACKOFF_MAX = 60 * 60    -- 无数据时重试退避的上限（秒）
local BATTERY_CACHE_TTL = 600        -- 电量读数缓存（秒），避免每拍都去 lipc 取

-- 版本号：显示在菜单「使用说明」那一项上。改动行为后一定同步改这里，
-- 上机时一眼就能确认「装的到底是不是刚改的这份」（避免文件没覆盖到、
-- 或者覆盖了但 KOReader 没重启，还在跑内存里的旧模块）。
local DASHBOARD_VERSION = "2.61"

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
    -- 空心边框：封面占位框用。边框必须在子控件之后画，否则会被文字盖住。
    if self.border and self.dimen.w > 2 and self.dimen.h > 2 then
        bb:paintBorder(x, y, self.dimen.w, self.dimen.h, self.border,
            self.border_color or COLOR_BLACK, nil, false)
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
    local bw = math.max(1, self.border or 1)
    -- 槽 0xDD、填充 0x66（实测最柔和的一对）。原来是 2px 纯黑外框 + 纯黑填充，
    -- 在 16 档灰的屏上等于一块实心黑条，压得整块版面往下沉。
    bb:paintBorder(x, y, w, h, bw, self.track or RULE_SOFT, nil, false)
    local inner = w - bw * 2
    local ratio = math.max(0, math.min(1, self.ratio or 0))
    local filled = math.floor(inner * ratio + 0.5)
    if filled > 0 then
        bb:paintRect(x + bw, y + bw, filled, h - bw * 2, self.fill or INK2)
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
    -- 壳体颜色可调：顶栏那枚用 0x66，和旁边的百分比同一档，不再比字还黑
    local fg = self.charging and COLOR_WHITE or (self.color or COLOR_BLACK)

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

--- 画一条任意角度的短线（只有矩形原语，只能逐点拼）。
--- t 是线宽（像素）。用于待办的勾选两笔——设备上没有 drawLine。
local function paintLine(bb, x0, y0, x1, y1, t, color)
    local dx, dy = x1 - x0, y1 - y0
    local n = math.max(math.abs(dx), math.abs(dy))
    if n < 1 then
        bb:paintRect(math.floor(x0), math.floor(y0), t, t, color)
        return
    end
    for i = 0, n do
        local px = math.floor(x0 + dx * i / n)
        local py = math.floor(y0 + dy * i / n)
        bb:paintRect(px, py, t, t, color)
    end
end

--- 圆弧：设备只有「矩形」和「圆」两个原语，弧只能逐段拼。
--- 角度用数学约定（0° 指右、90° 指上），sweep 正数逆时针、负数顺时针。
--- 每 4° 一段：300ppi 上 1px 的折角肉眼看不出，但比逐像素描圆省一个数量级的调用。
local function paintArc(bb, cx, cy, r, a0, sweep, t, color)
    local steps = math.max(6, math.ceil(math.abs(sweep) / 4))
    local lx = cx + math.cos(math.rad(a0)) * r
    local ly = cy - math.sin(math.rad(a0)) * r
    for i = 1, steps do
        local a = math.rad(a0 + sweep * i / steps)
        local x = cx + math.cos(a) * r
        local y = cy - math.sin(a) * r
        paintLine(bb, lx, ly, x, y, t, color)
        lx, ly = x, y
    end
end

--- 图标：24×24 设计栅格上的线性图形。
--- 为什么自己画、不用字体里的符号：font_audit 实测 ☾ ✦ ✧ ⛅ ➜ 这一批在设备字体里
--- 全是豆腐块；能用的 ● ○ ▲ ★ 又都是全角（advance 比同字号汉字还宽）、单色、
--- 尺寸跟着字号走，摆不进「图标 + 数值」这种版式。自己画才能让线宽和视觉重量
--- 与旁边 17du 的标签对齐。
--- shapes 每条：
---   {"l", x1, y1, x2, y2}        线段
---   {"a", cx, cy, r, a0, sweep}  圆弧（度）
---   {"o", cx, cy, r}             实心圆
---   {"r", x, y, w, h}            实心矩形（刻度 / 信号条 / 箭头杆）
--- shapes 也可以是函数：仪表类的指针角度要按当前值算。
local Icon = Widget:extend{}
function Icon:getSize()
    return self.dimen
end
function Icon:paintTo(bb, x, y)
    local size = math.min(self.dimen.w, self.dimen.h)
    if size < 6 then return end
    local u = size / 24
    -- 线宽 1.7u ≈ 图标尺寸的 7%：和 17du 的字（笔画约 3px）在 40px 图标上等重。
    -- 不按 u 线性取是因为小尺寸（16~20px）线一细就发虚，0x66 在 2px 以下几乎看不见。
    -- 2.1u：43px 的标签图标对应 3.8px 线宽。1.7u 在 300ppi 上只有 3px，
    -- 水滴那种细轮廓会发虚、和旁边的字不是一个重量级。
    local t = self.thick or math.max(3, math.floor(u * 2.1))
    local c = self.color or COLOR_BLACK
    local shapes = self.shapes
    if type(shapes) == "function" then shapes = shapes(self) end
    for _, sh in ipairs(shapes or {}) do
        local k = sh[1]
        if k == "l" then
            paintLine(bb, x + sh[2] * u, y + sh[3] * u,
                x + sh[4] * u, y + sh[5] * u, t, c)
        elseif k == "a" then
            paintArc(bb, x + sh[2] * u, y + sh[3] * u, sh[4] * u, sh[5], sh[6], t, c)
        elseif k == "o" then
            bb:paintCircle(x + sh[2] * u, y + sh[3] * u, sh[4] * u, c)
        elseif k == "r" then
            bb:paintRect(math.floor(x + sh[2] * u), math.floor(y + sh[3] * u),
                math.max(1, math.ceil(sh[4] * u)), math.max(1, math.ceil(sh[5] * u)), c)
        end
    end
    -- 状态斜杠：WiFi 未连接 / 未开启。压在最上层，从左上划到右下
    if self.slash then
        paintLine(bb, x + size * 0.15, y + size * 0.85,
            x + size * 0.85, y + size * 0.15, math.max(2, math.floor(t * 0.9)), c)
    end
end

--- 比例条：底轨 + 填充。
--- 数据条之所以一眼能读，一半靠数字、一半靠长度 —— 六个污染物都写"42 / 109 / 0.8"
--- 看不出谁重谁轻，配上"占限值多少"的长度立刻就有了比较。
local Meter = Widget:extend{}
function Meter:getSize()
    return self.dimen
end
function Meter:paintTo(bb, x, y)
    local w, h = self.dimen.w, self.dimen.h
    if w < 2 or h < 1 then return end
    bb:paintRect(x, y, w, h, self.track or RULE_SOFT)
    local r = math.max(0, math.min(1, self.ratio or 0))
    local filled = math.floor(w * r + 0.5)
    if filled > 0 then
        bb:paintRect(x, y, filled, h, self.color or INK1)
    end
end

--- 待办进度：N 段小方块，替掉块头右下角的「1/3」。
--- 完成度是「第几段填黑」，扫一眼就有比例感，不用先把 1/3 读成数、再在脑子里
--- 换算成比例 —— 星舰直播下沿那排数据条也是这个路子：能量化的都交给长度。
--- 段数上限 6：再多段宽就掉到 4px 以下，灰阶上数不清，那时退回去写数字。
local TickStrip = Widget:extend{}
function TickStrip:getSize()
    return self.dimen
end
function TickStrip:paintTo(bb, x, y)
    local n = math.max(0, self.n or 0)
    if n == 0 then return end
    local h = self.dimen.h
    local gap = self.gap or 2
    local seg = math.max(2, self.seg or math.floor((self.dimen.w - gap * (n - 1)) / n))
    local done = math.max(0, math.min(n, self.done or 0))
    for i = 1, n do
        local sx = x + (i - 1) * (seg + gap)
        if i <= done then
            bb:paintRect(sx, y, seg, h, self.color or INK1)
        else
            bb:paintBorder(sx, y, seg, h, math.max(1, self.line_w or 1),
                self.edge or RULE, nil, false)
        end
    end
end

--- 24×24 栅格上的图标库。
--- 只收「这个词没有公认图形就干脆不收」的那几个：太抽象的概念（如"时区"）
--- 硬配图标反而增加理解成本，不如留文字。
--- 国标 GB 3095-2012 二级浓度限值（µg/m³，CO 已换算成 µg/m³）。
--- 比例条的满量程取限值而不是实测最大值：这样"条的长短"等于"离超标还有多远"，
--- 是绝对判据，不会因为今天污染重就把所有条都画满。
local POLLUTANT_LIMIT = {
    pm2p5 = 75, pm10 = 150, o3 = 160, no2 = 80, so2 = 150, co = 4000,
}

local ICON = {
    -- 水滴（湿度）：顶点 + 两条斜边 + 下弧
    drop = {
        { "l", 12, 2.2, 5.2, 13.4 },
        { "l", 12, 2.2, 18.8, 13.4 },
        -- 下弧 180°：写 -206 会多转 26°，左侧收尾翘出一小块凸起（真机可见）
        { "a", 12, 13.4, 6.8, 0, -180 },
    },
    -- 风（风力）：三条横线 + 中间那条右端上扬。
    -- 不在小尺寸上做「末端卷钩」：34px 里钩的半径只有 3px，会糊成一个黑点。
    wind = {
        -- 三条线摊到 3.6 / 13 / 20.4（原来 6~18 只占方框一半），
        -- 与水滴的 2.2~20.2 体量相当，并排时不会一个满格、一个缩在中间。
        { "l", 2.2, 3.6, 13.6, 3.6 },
        -- 钩子：圆心抬高到 7.2 且只转 120°，末端停在 y≈8.8，
        -- 离中线（13）还有 2 个线宽的空白 —— 不然三条会连成"E"。
        { "a", 13.6, 7.2, 3.6, 90, -120 },
        { "l", 2.2, 14.5, 21.4, 14.5 },
        { "l", 2.2, 21.5, 10.8, 21.5 },
    },
    -- 刻度盘（AQI）：上半圆 + 三根基准刻度 + 按值转动的指针
    gauge = function(self)
        local v = math.max(0, math.min(1, (self.value or 0) / (self.max or 300)))
        local a = math.rad(180 - v * 180)
        -- 只画半圆 + 指针 + 圆心：43px 的标签图标里再塞三根刻度，会和指针糊成一团。
        -- 半圆本身已经说明"这是一个 0~满的刻度"，指针位置才是要被读出来的信息。
        return {
            -- 半径 11：半圆的横向跨度 22u，正好在 24 栅格里留 1u 边；
            -- 半圆天生只有半个方框高，靠「指针 + 圆心」把下半补齐。
            { "a", 12, 16.8, 11.0, 180, -180 },
            { "l", 12, 16.8, 12 + math.cos(a) * 7.6, 16.8 - math.sin(a) * 7.6 },
            { "o", 12, 16.8, 2.0 },
        }
    end,
    -- WiFi：三段弧 + 底点。lit = 亮几段（未开启只亮最内一段），
    -- 未连接时上层叠一条斜杠（Icon.slash）—— 状态靠图形本身说，不用汉字。
    wifi = function(self)
        -- 半径一路顶到 12：弧的横向跨度 2×12×sin45 ≈ 17u，加线宽正好撑满方框。
        -- 原来最外弧只有 8.8u，在 38du 的大字位上渲染出来是一小撮，认不出是 WiFi。
        local radii = { 4.0, 8.0, 12.0 }
        local out = {}
        for i = 1, math.max(1, math.min(3, self.lit or 3)) do
            out[#out + 1] = { "a", 12, 20.5, radii[i], 45, 90 }
        end
        out[#out + 1] = { "o", 12, 19.4, 2.0 }
        return out
    end,
    -- 太阳（日出）
    sun = {
        { "o", 12, 12, 3.6 },
        { "l", 12, 2.0, 12, 4.4 },
        { "l", 22.0, 12, 19.6, 12 },
        { "l", 12, 22.0, 12, 19.6 },
        { "l", 2.0, 12, 4.4, 12 },
        { "l", 18.9, 5.1, 17.2, 6.8 },
        { "l", 18.9, 18.9, 17.2, 17.2 },
        { "l", 5.1, 18.9, 6.8, 17.2 },
        { "l", 5.1, 5.1, 6.8, 6.8 },
    },
    -- 地平线 + 半日（日出 / 日落）：一个日轮浮在地平线上，箭头说明是升还是落
    horizon = {
        { "a", 12, 16.6, 7.4, 0, 180 },
        { "l", 1.6, 16.6, 22.4, 16.6 },
    },
    -- 月牙（月相）：外弧 + 内凹弧，两段弧端点重合才像月亮
    moon = {
        { "a", 12, 12, 8.6, 90, 180 },
        { "a", 18, 12, 10.5, 235, -110 },
    },
}

--- 把一块卡里的「块头 / 条目 / 脚注」铺满整个高度：
--- 块头贴卡顶、条目之间按比例吃余量、脚注压到卡底。
--- 为什么不交给 Card:fitChild：它按 gap_h 等比放大，条目一多就把余量摊薄，
--- 条目一少又会在卡底留一整块白。这里按「先量总量、再把余量分给指定行」算，
--- 结果是确定的：最后一行脚注永远贴在卡的下内边距上。
--- rows 是排好的控件数组，gaps 是其中可拉伸的留白行，tail_pad 是脚注上方那行。
--- ratio 是给条目的比例，剩下的全给脚注上方（脚注因此落到底）。
local function spreadToBottom(rows, gaps, tail_pad, h, ratio)
    local used = 0
    for _, r in ipairs(rows) do used = used + r:getSize().h end
    local slack = math.max(0, h - used)
    -- 没有脚注时余量全给条目：留 22% 在卡底就又是一块没来由的白。
    local ratio_eff = tail_pad and (ratio or 0.78) or 1
    local share = (#gaps > 0) and math.floor(slack * ratio_eff / #gaps) or 0
    for _, g in ipairs(gaps) do
        g.dimen.h = g.dimen.h + share
        -- gap_h 一起改、并标 fixed：否则 Card:fitChild 会按「设计间距」再算一遍，
        -- 把这里分好的余量抹平，条目缩回去、卡底又空出一块。
        g.gap_h = g.dimen.h
        g.fixed = true
    end
    if tail_pad then
        tail_pad.dimen.h = math.max(1, slack - share * #gaps)
        tail_pad.gap_h = tail_pad.dimen.h
    end
    local out = VerticalGroup:new(rows)
    out.spread = false
    return out
end

--- 卡片：一块白面 + 1px 浅边 + 圆角，浮在 0xEE 纸底上。
--- 整个 v2.53 版式的骨架——三区各一张卡，区与区之间露出纸底，
--- 不再用 7px 纯黑通栏线分区（线太重，且把版面切成三条横带）。
--- 高度按盒高固定，内容顶部对齐：块头永远贴着卡的上沿，下面留白由内容撑。
local Card = Widget:extend{}
function Card:getSize()
    if self[1] and self.auto_h then
        local cs = self[1]:getSize()
        local need = cs.h + (self.pad_t or 0) + (self.pad_b or 0)
        self.dimen.h = math.max(self.dimen.h or 0, need)
    end
    return self.dimen
end
--- 把卡片内部的留白拉开，让内容在卡里"铺开"而不是全挤在顶部。
--- 三区高度是固定的（版式要稳），但内容多少天天在变：待办三条 vs 六条、
--- 日月两行 vs 四行。内容少时若一律顶部对齐，卡下半就空一大片，看着像卡坏了。
--- 这里按 gap_h 的比例放大卡内留白行，把内容均匀铺到卡底。
--- 幂等：每次从 gap_h 重算（不是在上次结果上再乘），getSize 调用多少次都一样。
function Card:fitChild()
    local child = self[1]
    -- spread = false：组件自己已经把余量分完了（例如「今日行动」把脚注压到卡底），
    -- 这里再按比例铺一次就会把它抹掉。
    if not child or self.spread == false or child.spread == false then return end
    local avail = (self.dimen.h or 0) - (self.pad_t or 0) - (self.pad_b or 0)
    local used = child:getSize().h
    local slack = avail - used
    if slack <= 0 then return end
    local total = 0
    for i = 1, #child do
        local r = child[i]
        if r and r.gap_h and not r.fixed then total = total + r.gap_h end
    end
    if total <= 0 then return end
    local k = math.min(self.spread_max or 2.0, 1 + slack / total)
    for i = 1, #child do
        local r = child[i]
        if r and r.gap_h and r.dimen and not r.fixed then
            r.dimen.h = math.max(1, math.floor(r.gap_h * k))
        end
    end
end

function Card:paintTo(bb, x, y)
    local w, h = self.dimen.w, self.dimen.h
    if w < 4 or h < 4 then return end
    self:fitChild()
    local r = self.radius or 0
    if r > 0 then
        bb:paintRoundedRect(x, y, w, h, self.bg or COLOR_WHITE, r)
    else
        bb:paintRect(x, y, w, h, self.bg or COLOR_WHITE)
    end
    if self.border then
        bb:paintBorder(x, y, w, h, self.border, self.border_color or RULE,
            r > 0 and r or nil, false)
    end
    local child = self[1]
    if child then
        local oy = self.pad_t or 0
        if self.valign == "center" then
            local slack = h - (self.pad_t or 0) - (self.pad_b or 0) - child:getSize().h
            if slack > 0 then oy = oy + math.floor(slack / 2) end
        end
        child:paintTo(bb, x + (self.pad_l or 0), y + oy)
    end
end

--- 待办勾选框：16du 见方，未勾是空心方框，勾了是实心 + 两笔反白对勾。
--- 原来的 `[ ]` / `[x]` 是 ASCII 方括号拼的，笔画细碎、基线也不对，
--- 在一屏只有两三行的 B 区里特别扎眼。
local CheckBox = Widget:extend{}
function CheckBox:getSize()
    return self.dimen
end
function CheckBox:paintTo(bb, x, y)
    local s = math.min(self.dimen.w, self.dimen.h)
    if s < 4 then return end
    local bw = math.max(1, self.line_w or 1)
    local c = self.color or COLOR_BLACK
    if self.done then
        bb:paintRect(x, y, s, s, c)
        -- 反白对勾：线宽取 1/8 边，太细在灰阶上会被噪声吃掉
        local t = math.max(2, math.floor(s / 6))
        local wc = self.tick_color or COLOR_WHITE
        local pad = math.floor(s * 0.22)
        paintLine(bb, x + pad, y + s * 0.52, x + s * 0.44, y + s - pad, t, wc)
        paintLine(bb, x + s * 0.44, y + s - pad, x + s - pad, y + pad, t, wc)
        -- 收尾压齐：paintLine 是逐点矩形，端点会漏半个线宽
        bb:paintRect(math.floor(x + s - pad), math.floor(y + pad), t, t, wc)
    else
        bb:paintBorder(x, y, s, s, bw, c, nil, false)
    end
end

local function mkPad(w, h, fixed)
    local hh = math.max(1, math.floor(h))
    return Widget:new{
        dimen = Geom:new{ w = math.max(0, math.floor(w)), h = hh },
        -- 显式标记「纯留白行」，stretchGaps 只认这个标记。见该函数上方注释：
        -- 用字段探测（row.color == nil …）会在 LuaJIT 下把 Solid 的 cdata 颜色比爆。
        is_gap = true,
        -- 设计高度：桩件用它断言 stretchGaps「只放大、不缩小、不碰非留白行」
        gap_h = hh,
        -- fixed = 不参与"卡内铺开"。块头与正文之间那种「必须紧」的间距要标上，
        -- 否则余量会先被它吃掉，标题和第一行之间空出 30px，看着像两段不相干的内容。
        fixed = fixed or nil,
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
    portrait  = { A = 224, B = 292, C = 148, gap = 16, head_gap = 12, card_pad = 14, foot_gap = 12 },
    landscape = { A = 181, lower = 296,        gap = 14, head_gap = 12, card_pad = 14, foot_gap = 12 },
}

-- 卡片的圆角半径（设计单位）。8du 在 PW3 上是 14px，300ppi 下半径约 1.2mm ——
-- 比信用卡圆角（3.2mm）小一半，看着是"削了角"而不是"泡泡"。再大就发软，再小等于没圆。
-- 设备端 paintBorder 会把超大半径自动夹住。
local CARD_RADIUS = 8

-- 组装骨架时必须按这个顺序取区，与配置表的键一致
local ZONE_KEYS = { "A", "B", "C" }

--- 每区的默认组件。老用户升级后没有 dashboard_components 设置，
--- 全部回落到这里 → 视觉与升级前一致。
--- v2.53 改了竖屏 B 区：从"农历节气"换成"今日行动"。一屏最该回答的三件事是
--- 现在几点 / 今天什么天 / 今天要做什么，农历只回答第二个的一半，
--- 而它占的是面积最大的一块（37%）。
local ZONE_DEFAULT = {
    portrait  = { A = "clock_weather", B = "today_actions", C = "stats_cells" },
    landscape = { A = "clock_weather", B = "today_actions", C = "side_panel" },
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
        -- v2.53：横屏 B 区在窄屏下只有 ~370px 内容宽，农历那行「丙午年 · 马年」加上
        -- 大字位最少要 411px，只能留在更宽的 C 区（596px）。竖屏 B 区不受影响。
        label = "农历与节气", zones = { portrait = { "B" }, landscape = { "C" } },
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
        -- 日月在竖屏只进 C 区（三格里最矮的一条）。
        -- valign_center：这块没有块头（三个数字列 + 两行注释就是全部内容），
        -- 卡高 553 而内容只有 300 时，顶部对齐会在卡底留下半张卡的白 ——
        -- 有块头的卡靠"标题贴顶"站住，没有块头的卡只能靠居中。
        label = "日月", zones = { portrait = { "B", "C" }, landscape = { "B", "C" } },
        valign_center = true,
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
    -- ---- v2.47 新增 2 个 ----
    -- 这两个组件都有「点一下展开列表」，expandable 标记供 buildZone 记录盒子坐标。
    -- 横屏 A 区只有 294 高、1276 宽，是最扁的一条：倒数日的大数字位塞进去会挤掉
    -- 列表，所以这两个只放 B/C（543 高），竖屏三区都够。
    countdown = {
        -- v2.53：竖屏 C 区不再收倒数日。三区改成卡片之后 C 区要扣掉卡片内边距，
        -- 卡内只剩 214px，而倒数日「块头 + 大字位 + 名称 + 日期」最小也要 250px。
        label = "倒数日", zones = { portrait = { "A", "B" }, landscape = { "B", "C" } },
        expandable = "countdown",
        build = "compCountdown",
    },
    todo = {
        label = "待办", zones = { portrait = { "A", "B", "C" }, landscape = { "B", "C" } },
        expandable = "todo",
        build = "compTodo",
    },
    -- ---- v2.53 新增 ----
    -- 「今日行动」= 今日待办打卡（主体）+ 最近一条倒数日（脚注）。
    -- 与 todo 的区别：todo 是纯清单，这个是「今天要做的 + 还有几天到期」的合成块，
    -- 专门给 B 区（面积最大、视觉重心）用。点按同样展开待办列表。
    today_actions = {
        label = "今日行动", zones = { portrait = { "A", "B" }, landscape = { "B", "C" } },
        expandable = "todo",
        build = "compTodayActions",
    },
}

-- 收紧档位：只降字号，不换布局、不裁内容
local K_LADDER = { 1, 0.94, 0.88, 0.82, 0.76 }
-- 刻度盘指针的位图档数：预渲染 0°..180° 每 15° 一档，运行时按值取最近的一档。
-- 指针角度连续、位图只能是离散的，档数就是精度上限：13 档时一格 = 满量程的 1/12，
-- 300 满量程下相邻档差 25；再细下去图标数量翻倍，而 43px 的盘面上指针
-- 差 7.5° 根本看不出来（段长 7.6u，7.5° 只挪 1u ≈ 2.4px）。
local AQI_STEPS = 13
-- 月历的横向铺排参数：
--   列距 = 格宽 × CAL_GAP_RATIO（看起来是列与列之间透气，而不是把格子拉扁）
--   格宽上限 = 行高 × CAL_ASPECT_MAX（再宽日号就在格子里浮起来了）
-- v2.57：1.62 → 1.95。竖屏 B 区的内容列是 966px，而 1.62 把格宽压在 90px，
-- 7 列只铺到 798px——左右各空 86px，最后一周又只有 6 个数字（周日那列还都是
-- 个位数），墨迹重心整块偏左，看着就是"月历贴在左边"。放到 1.95 之后格宽由
-- 可用宽度反算（约 108px），7 列正好铺满内容列，左右两条边与上下的卡片对齐。
local CAL_GAP_RATIO = 0.32
local CAL_ASPECT_MAX = 1.95

--- 文本行高。与 TextWidget 的 1.363 同一条公式，桩件与真机一致。
local function textLineH(px, S, k)
    return math.floor(px * S * k * 1.363)
end

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

--- 横屏下半区宽度：左 B（7 个日历格宽）/ 右 C（吃掉剩余）。
--- v2.53 起两张卡之间不画竖线，只留一段纸底空隙，所以不再扣 vline_w。
--- 横屏下半区宽度：左 B（7 个日历格宽）/ 右 C（吃掉剩余）。
--- 入参是**整版心宽**（与 A 卡同宽），不是扣过内边距的可用宽：
--- v2.53 传的是 avail，结果下半区总宽比 A 卡窄两个 card_pad，
--- C 卡右沿比 A 卡缩进 50px，看着像 C 区右侧留白更多（其实是不齐）。
function Dashboard:lowerWidths(total, S)
    local gap = math.floor(ZONE_SPEC.landscape.gap * S)
    local right_min = math.floor(330 * S)
    local cell_w = math.min(math.floor(52 * S),
        math.floor((total - right_min - gap) / 7))
    cell_w = math.max(math.floor(34 * S), cell_w)
    local bw = cell_w * 7
    local cw = total - bw - gap
    -- 右卡有下限：够窄时让 B 卡吐宽度（日历格宽已经封了上限 52du）
    local min_c = math.floor(260 * S)
    if cw < min_c then
        cw = math.min(min_c, total - gap - math.floor(140 * S))
        bw = total - gap - cw
    end
    return bw, cw
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
    -- 倒数日 / 待办：读盘一次，之后都走内存；顺手清掉 30 天前已完成的待办
    pcall(function()
        Agenda.load(true)
        Agenda.maintenance(self:localNow())
    end)
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
    -- 顶层只放 6 条（Settings 入口 7 条，含「打开看板」）。
    --
    -- 这里有一条硬约束：TouchMenu 每页容量 = min(按行高算出来的条数,
    -- max_per_page_default)。真机实读（PW3 1072x1448）：竖屏算出 13，被默认值
    -- 挡住 → 10 条；横屏算出 9 → 9 条。所以**顶层超过 9 条就要翻页，横屏先翻**。
    -- 原来这一层是 15 条，两个方向都翻（截到过「第 1 页，共 2 页」）。
    --
    -- 分组的依据是用户心里的对象，不是代码里的模块：
    --   外观（版式 + 区域组件）· 地点与天气 · 内容（倒数日 / 待办）·
    --   显示与省电 · 语言 · 使用说明
    -- 深度是刻意守住的：「切横竖屏」仍在「外观」的第一屏；「换某区组件」仍是
    -- 四跳（外观 → 竖屏布局 → C 区 → 组件），与原来「布局组件」那条一样深。
    local items = {
        {
            text = T("打开看板"),
            -- 已经打开时这个入口没有意义，看板内弹出的菜单会把它过滤掉
            hide_in_dashboard = true,
            callback = function() self:open() end,
        },
        {
            text = T("外观"),
            help_text = TL(
                "版式（竖屏 / 横屏）与各区域放什么组件。",
                "Orientation (portrait / landscape) and what each zone shows."),
            sub_item_table = self:genAppearanceMenu(),
        },
        {
            text = T("地点与天气"),
            help_text = TL(
                "城市与时区决定看板上所有时间；天气服务决定数据从哪来。",
                "City and time zone set every clock on the board; the weather service\n"
                .. "picks where the data comes from."),
            sub_item_table = self:genPlaceMenu(),
        },
        {
            text = T("内容"),
            help_text = TL(
                "看板上只做「看 + 勾选」，增删改都在这里。",
                "The board only shows and ticks them; add and remove here."),
            sub_item_table = {
                { text = T("倒数日"), sub_item_table = self:genCountdownMenu() },
                { text = T("待办事项"), sub_item_table = self:genTodoMenu() },
            },
        },
        {
            text = T("显示与省电"),
            help_text = TL(
                "屏保行为、页脚提示、刷新节奏都在这里。",
                "Screensaver behaviour, footer hints and refresh cadence."),
            sub_item_table = self:genDisplayPowerMenu(),
        },
        {
            text = T("语言 / Language"),
            sub_item_table = self:genLangMenu(),
        },
        {
            -- 版本号放这儿：上机时打开菜单扫一眼就知道是不是刚改的那份代码
            text = T("使用说明") .. "  v" .. DASHBOARD_VERSION,
            callback = function()
                UIManager:show(InfoMessage:new{
                    text = TL(
                        "手势：点按刷新天气 · 上划退出看板\n"
                        .. "屏幕上缘下滑 → 打开看板菜单（外观 / 地点与天气 / 内容 / 显示与省电）\n"
                        .. "看板没打开时：设置 → 屏幕 → 屏保 → 桌面看板（同一套菜单）\n"
                        .. "城市可选国内与海外（亚洲/欧洲/美洲/大洋洲/非洲）；\n"
                        .. "选海外城市会自动把时区一并改掉，\n"
                        .. "也可点「地点与天气 → 自动检测我的位置（按 IP）」让它自己挑最近的城市。\n"
                        .. "左右滑动 → 竖屏 ↔ 横屏 互相切换（会真的旋转屏幕）\n\n"
                        .. "点「倒数日」「待办」这两块卡片 → 弹出列表（可切换置顶、勾选完成）；\n"
                        .. "增删改在菜单「内容 → 倒数日 / 待办事项」里，录入分两步：\n"
                        .. "第 1 步填名称（键盘），第 2 步点选日期（年 / 月 / 日 各自翻页，免键盘）。\n"
                        .. "  倒数日：名称 + 日期，例「妈妈生日」+ 2026-11-30\n"
                        .. "  待办：名称 + 日期，日期默认今天\n"
                        .. "数据存在 KOReader 设置目录的 dashboard_agenda.lua，可直接备份。\n\n"
                        .. "Kindle 没有重力感应，机器横过来屏幕不会自己转，\n"
                        .. "所以横屏要靠左右滑动（或菜单「外观」）手动切，切完请把设备横着拿。\n"
                        .. "菜单「外观」里选中一项后会立即关菜单并按新方向重排，不用手动关菜单。\n"
                        .. "若横屏后文字是倒的，到菜单「外观」里换「向左转 90°」那一项。\n\n"
                        .. "右上角显示电量百分比与电量图标（充电时图标反白）。\n"
                        .. "天气优先用和风天气，不可用时自动降级到 Open-Meteo，页脚会标注来源。\n"
                        .. "空闲超时或按电源键休眠时，屏幕会停留在看板上（相当于屏保）。\n"
                        .. "长时间显示建议接通电源；全刷周期默认 60 分钟，可在「显示与省电 → 省电设置」里调。\n\n"
                        .. "看板版本 v" .. DASHBOARD_VERSION,
                        "Gestures: tap to refresh · swipe up to exit\n"
                        .. "Swipe down from the top edge: dashboard menu (appearance / location & weather /\n"
                        .. "content / display & power)\n"
                        .. "When closed: Settings → Screen → Sleep screen → Desk dashboard\n"
                        .. "Cities cover China plus Asia, Europe, the Americas, Oceania and Africa;\n"
                        .. "picking an overseas one also sets its time zone.\n"
                        .. "Or use Location & weather → Detect my location (by IP) to pick the nearest city.\n"
                        .. "Swipe sideways: switch portrait ↔ landscape (really rotates the screen)\n\n"
                        .. "Kindles have no accelerometer, so landscape must be triggered manually\n"
                        .. "by swiping sideways or via the Appearance menu; then hold the device sideways.\n"
                        .. "If the landscape text appears upside down, pick the other rotation.\n\n"
                        .. "Tap the Countdown / To-do card to open its list (pin, tick off);\n"
                        .. "add and remove them under Content → Countdown / To-dos, in two steps:\n"
                        .. "step 1 types the name, step 2 picks the date (no typing for dates).\n"
                        .. "Data lives in dashboard_agenda.lua in the KOReader settings folder.\n\n"
                        .. "Top right: battery percentage and icon (inverted while charging).\n"
                        .. "Weather comes from QWeather; if unavailable it falls back to Open-Meteo,\n"
                        .. "and the footer shows the current source.\n"
                        .. "On idle or power-button sleep the screen keeps the dashboard (acts as a\n"
                        .. "screensaver). For long display, keep it plugged in; full refresh\n"
                        .. "defaults to every 60 minutes (Display & power → Power saving).\n\n"
                        .. "Dashboard version v" .. DASHBOARD_VERSION),
                })
            end,
        },
    }
    return items
end

-- ------------------------------------------------------------------ 外观菜单
--- 「外观」= 版式（竖屏 / 横屏）+ 各区域放什么组件。
--- 版式三项**刻意不用 checked_func**。TouchMenu:onMenuSelect 里是这么分支的
--- （v2025/v2026 一致）：
---   callback(self)
---   if item.checked or item.checked_func then   -- 勾选项
---       self:updateItems()                       -- 只刷新，**不关菜单**
---   elseif not item.keep_menu_open then
---       self:closeMenu()                         -- 普通项，回调后自动关
--- 也就是说「带勾选」和「点完自动关菜单」在 TouchMenu 里是互斥的，之前用
--- checked_func 就必然点完菜单还杵着。现在改成普通叶子项：点击 → callback 记下
--- 方向 → TouchMenu 自己 closeMenu() → close_callback → 立刻转屏重排。
--- 当前方向改用文字标注（不能依赖屏幕旋转结果：转不了屏的机型会退化成纯版式切换）。
function Dashboard:genAppearanceMenu()
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
    local sub = {
        orientEntry(T("竖屏"), "portrait"),
        orientEntry(T("横屏（向右转 90°）"), "landscape"),
        orientEntry(T("横屏（向左转 90°）"), "landscape_ccw"),
    }
    -- 分隔线画在「版式三项」之后（TouchMenu 的 separator 是画在**本项下面**的，
    -- 所以要挂在第三项上，挂到第四项就会落到「竖屏布局」和「横屏布局」中间）。
    sub[#sub].separator = true
    -- 下面四条就是原来的「布局组件」那一层，只是换了个挂点：
    -- 层级深度不变（外观 → 竖屏布局 → 区 → 组件），省掉的只是顶层的一条。
    for _, it in ipairs(self:genLayoutMenu()) do sub[#sub + 1] = it end
    return sub
end

-- ------------------------------------------------------------------ 地点与天气
--- 城市、时区、天气源三件事同属「看板显示的是哪里的天气几点钟」，并成一组。
--- 「立即刷新天气」放在这儿而不是顶层：看板上点一下屏幕就能刷新，
--- 菜单里不必为它长期占一个顶层位置。
function Dashboard:genPlaceMenu()
    return {
        { text = T("选择城市"), sub_item_table = self:genCityMenu() },
        { text = T("选择时区"), sub_item_table = self:genTzMenu() },
        {
            text = T("自动检测我的位置（按 IP）"),
            help_text = TL(
                "联网查一次出口 IP 的大致位置，自动选最近的城市，并把时区一起改掉。\n"
                .. "查不到时已有设置保持不变，可以继续手动选。",
                "Looks up the approximate location of this network once, then picks the\n"
                .. "nearest city and its time zone. If it fails, your current settings\n"
                .. "stay untouched and you can pick manually."),
            callback = function() self:autoLocateCity() end,
        },
        { text = T("天气服务"), sub_item_table = self:genWeatherMenu() },
        { text = T("立即刷新天气"), callback = function() self:fetchWeather(true) end },
    }
end

--- 国内三组与海外六组分开：原来 9 个分组 + 自动检测 = 10 条，竖屏刚够一页，
--- 横屏（9 条上限）就要翻页。现在两组各 3 / 6 条，任何方向都是一屏。
local DOMESTIC_CITY_GROUPS = {
    ["直辖市"] = true,
    ["省会"] = true,
    ["港澳台"] = true,
}

--- 城市菜单：国内城市 / 海外城市两个分组（都是单选，当前项打勾）。
--- 分组表放在数据模块里：新增城市只要 group 名在表中存在，就会出现在对应分组下，
--- 不必回到这里改菜单代码。国内组在前，海外组在后。
function Dashboard:genCityMenu()
    local domestic, overseas = {}, {}
    for _, g in ipairs(CityData.city_groups) do
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
        -- 空分组不显示：某天把一组城市删空，菜单里不该留个点进去什么都没有的空壳
        if #sub > 0 then
            local bucket = DOMESTIC_CITY_GROUPS[g.key] and domestic or overseas
            bucket[#bucket + 1] = { text = T(g.text), sub_item_table = sub }
        end
    end
    local items = {}
    if #domestic > 0 then
        items[#items + 1] = { text = T("国内城市"), sub_item_table = domestic }
    end
    if #overseas > 0 then
        items[#items + 1] = { text = T("海外城市"), sub_item_table = overseas }
    end
    return items
end

--- 时区菜单：按洲分组（北美与南美合成「美洲」，避免两组都只有三四项）。
function Dashboard:genTzMenu()
    local items = {}
    for _, g in ipairs(CityData.tz_groups) do
        local sub = {}
        for _, t in ipairs(CityData.timezones) do
            if t.group == g.key then
                sub[#sub + 1] = {
                    text = I18n.tzName(t),
                    checked_func = function() return self:getTzIana() == t.iana end,
                    callback = function() self:setTz(t.iana) end,
                }
            end
        end
        if #sub > 0 then
            items[#items + 1] = { text = T(g.text), sub_item_table = sub }
        end
    end
    return items
end

-- ------------------------------------------------------------------ 显示与省电
--- 屏保在休眠时接管屏幕，页脚提示与刷新节奏都属于「常显在屏幕上要付的代价」，
--- 四件事搁一起。省电设置仍是子菜单（内部四项各自还要选档，会超过一屏）。
function Dashboard:genDisplayPowerMenu()
    return {
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
        {
            text = T("页脚手势提示"),
            help_text = TL(
                "关闭时页脚只显示「数据时刻 · 来源」，六个手势改成只在第一次打开时提示。\n"
                .. "打开后在页脚常驻一行，会把版面下沿挤占掉。",
                "When off, the footer only shows the data time and source.\n"
                .. "When on, the gesture hints take up a full line at the bottom."),
            checked_func = function()
                return G_reader_settings:readSetting("dashboard_show_hints") == true
            end,
            callback = function()
                local on = G_reader_settings:readSetting("dashboard_show_hints") == true
                G_reader_settings:saveSetting("dashboard_show_hints", not on)
                if G_reader_settings.flush then G_reader_settings:flush() end
                if self.shown then self:refreshLayout() end
            end,
        },
        {
            text = T("重新布局"),
            help_text = TL(
                "按当前设置把整屏重画一遍。画面错乱、或者改完组件没跟着变时用。",
                "Redraws the whole board with the current settings, for when the screen\n"
                .. "looks wrong or a change did not apply."),
            callback = function()
                if self.shown then self:refreshLayout() end
            end,
        },
        {
            text = T("省电设置"),
            help_text = TL(
                "常开看板时，耗电主要来自「多久刷一次屏」和「多久拉一次天气」。\n"
                .. "这里的四项都会立即生效，不需要重开看板。",
                "When the board stays on, power is mostly spent on how often the screen\n"
                .. "refreshes and how often weather is fetched. All four apply immediately."),
            sub_item_table = self:genPowerMenu(),
        },
    }
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

-- ------------------------------------------------------------------ 省电菜单
--- 「省电设置」：时钟刷新粒度 / 天气更新间隔 / 全刷周期 / 低电保护。
--- 四项都写进 G_reader_settings，tick 每拍现读，改完立即生效。
--- 为什么把「时钟刷新」放第一位：常开时它是最大的单项支出——
--- 原来每分钟整屏刷新，一天 1440 次；提到 5 分钟后只剩 288 次。
function Dashboard:genPowerMenu()
    local function read(key, default)
        local v = tonumber(G_reader_settings:readSetting(key))
        if v == nil then return default end
        return v
    end
    local function set_num(key, value)
        G_reader_settings:saveSetting(key, value)
        if G_reader_settings.flush then G_reader_settings:flush() end
        -- 改完立刻按新参数重排下一次触发，否则要等旧的那一拍走完
        if self.shown then self:scheduleTick() end
    end
    local function minutes(v)
        return string.format(T("%d 分钟"), v)
    end
    local function pick(title, help, key, default, values, label)
        local sub = {}
        for _, v in ipairs(values) do
            sub[#sub + 1] = {
                text = label(v),
                help_text = help,
                checked_func = function() return read(key, default) == v end,
                callback = function() set_num(key, v) end,
            }
        end
        return { text = title, sub_item_table = sub }
    end

    return {
        pick(T("时钟刷新"), TL(
                "看板每隔多久重画一次时钟。这是常开时最大的耗电项。\n"
                .. "选「只在触摸时刷新」就完全不自己走，碰一下屏幕才校正时间。",
                "How often the clock is redrawn. This is the biggest drain when the board\n"
                .. "stays on. \"Only on touch\" stops it entirely until you tap the screen."),
            POWER_KEYS.tick_step, TICK_STEP, { 1, 2, 5, 10, 30, 0 },
            function(v)
                if v == 0 then return T("只在触摸时刷新") end
                return minutes(v)
            end),
        pick(T("天气更新"), TL(
                "多久拉一次天气。每次都要走三个接口，间隔越长越省电，电量也越省。\n"
                .. "刚唤醒后的 25 秒内不会拉取，避免按电源键时卡住。",
                "How often weather is fetched (three requests each time).\n"
                .. "Longer is cheaper. Nothing is fetched in the first 25 s after wake."),
            POWER_KEYS.weather, UPDATE_INTERVAL, { 15 * 60, 30 * 60, 60 * 60, 120 * 60 },
            function(v) return minutes(math.floor(v / 60)) end),
        pick(T("全刷周期"), TL(
                "每隔多久整屏闪一次，用来清电泳残影。关掉以后画面更安静，\n"
                .. "但长时间显示同一版式会留下淡淡的影子。",
                "How often the whole screen flashes to clear e-ink ghosting.\n"
                .. "Turning it off keeps the screen calm but may leave faint ghosts."),
            POWER_KEYS.full_refresh, FULL_REFRESH_PERIOD, { 30, 60, 120, 240, 0 },
            function(v)
                if v == 0 then return T("关闭") end
                return minutes(v)
            end),
        pick(T("低电保护"), TL(
                "电量低于这个值时，时钟自动降到 30 分钟一跳，并停掉自动拉天气与全刷。\n"
                .. "插上电或电量回升后自动恢复，不会一直卡在省电状态。",
                "Below this level the clock drops to a 30-minute step and weather\n"
                .. "and full refresh stop until you plug in or the level recovers."),
            POWER_KEYS.low_battery, LOW_BATTERY_GUARD, { 0, 5, 10, 15, 20 },
            function(v)
                if v == 0 then return T("关闭") end
                return string.format(T("电量 ≤ %d%%"), v)
            end),
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
    local name = G_reader_settings:readSetting("dashboard_city")
    if name then return name end
    -- 从未选过城市：按设备时区猜一个，海外用户开箱看到的就是本地城市而不是北京。
    -- 猜不到（读不出设备时区）才回落到北京。
    local tz = CityData.guessTimezone()
    if tz then return CityData.defaultCityName(tz.iana) end
    return "北京"
end

function Dashboard:getCity()
    local name = self:getCityName()
    for _, c in ipairs(CityData.cities) do
        if c.name == name then return c end
    end
    return CityData.cities[1]
end

function Dashboard:getTzIana()
    local iana = G_reader_settings:readSetting("dashboard_tz")
    if iana then return iana end
    local tz = CityData.guessTimezone()
    if tz then return tz.iana end
    return "Asia/Shanghai"
end

--- 当前时区项。返回的 offset 是**此刻实际生效**的偏移（夏令时期间已是 +60 后的值）；
--- 原表是静态数据，不改它，需要不同 offset 时另建副本。
function Dashboard:getTz()
    local t = CityData.tzByIana(self:getTzIana()) or CityData.timezones[1]
    local off = CityData.offsetAt(t, os.time())
    if off == t.offset then return t end
    return { name = t.name, en = t.en, iana = t.iana, offset = off, dst = t.dst }
end

function Dashboard:setCity(name)
    G_reader_settings:saveSetting("dashboard_city", name)
    -- 海外城市自带 tz：选城市时一并改时区，避免「城市对了、时钟错了」这种最常见的
    -- 配置失误。国内城市没有 tz，用户手动选的北京时间/新疆时间不会被覆盖。
    for _, c in ipairs(CityData.cities) do
        if c.name == name then
            if c.tz and CityData.tzByIana(c.tz) then
                G_reader_settings:saveSetting("dashboard_tz", c.tz)
            end
            break
        end
    end
    if G_reader_settings.flush then G_reader_settings:flush() end
    self:onConfigChanged()
end

function Dashboard:setTz(iana)
    G_reader_settings:saveSetting("dashboard_tz", iana)
    if G_reader_settings.flush then G_reader_settings:flush() end
    self:onConfigChanged()
end

--- 按 IP 定位并套用最近的城市与时区。同步阻塞，最长约 8 秒（http 超时）。
--- 失败只弹提示，不动已有设置。
function Dashboard:autoLocateCity()
    local info, err = Geo.locate()
    if not info then
        UIManager:show(InfoMessage:new{
            text = string.format(T("定位失败：%s"), err or T("未知原因")),
            timeout = 5,
        })
        return
    end
    local city, km = CityData.nearest(info.lat, info.lon)
    if not city then
        UIManager:show(InfoMessage:new{
            text = T("没有可用的城市数据"),
            timeout = 4,
        })
        return
    end

    self:setCity(city.name)
    local tz = self:getTz()

    local msg = string.format(T("已定位到：%s"), I18n.city(city))
    if info.country and info.country ~= "" then
        msg = msg .. "  " .. tostring(info.country)
    end
    msg = msg .. "\n" .. string.format(T("时区：%s"), I18n.tzName(tz))
    -- 最近的收录城市也在两百公里外：说明表里没有贴近的位置，说明白比装作精确好
    if km and km > 200 then
        msg = msg .. "\n" .. string.format(
            T("附近没有更近的收录城市，已选 %s（约 %d 公里）"),
            I18n.city(city), math.floor(km / 10) * 10)
    end
    UIManager:show(InfoMessage:new{ text = msg, timeout = 6 })
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
    -- 先转屏、后建 root：转屏期间画面上不能有我们的全屏窗口。
    -- 实测顺序反了就会失败——先 show(root) 再转屏，Screen 重建完 blitbuffer
    -- 立刻被按旧方向重画一次，rotation 复位成竖屏，最后开出来还是竖版。
    -- 只有「屏幕上还是文件管理器」的时候转屏才真的生效（devbridge 手动切过一次验证）。
    local want_rotate = mode
    if want_rotate then
        if self:rotateScreen(want_rotate) then
            -- 转成了：版式由屏幕尺寸自然判定，清掉上一轮留下的强制标记
            self.force_landscape = nil
            self.rotation_changed = (screen_rotation() ~= self.base_rotation)
        else
            -- 转不了就按要的方向排（画面方向不变，至少排版是另一套）
            self.force_landscape = (want_rotate ~= "portrait")
        end
        -- 尺寸要等 buffer 重建完才互换，隔一拍再建版式
        -- 1.2s：实测转屏后 Screen 的宽高要到 1 秒左右才互换，
        -- 太早重排读到的还是旧尺寸，画出来就是「横屏版式装在竖屏画布里」。
        UIManager:scheduleIn(1.2, function()
            if self.shown then self:refreshLayout() end
        end)
    else
        self.force_landscape = nil
        self:refreshLayout()
    end
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
    -- 先停表。挂起时定时器本来就不走，但「刚好在挂起前一秒到点」的那一拍会多刷
    -- 一次屏；唤醒时 onLeaveScreenSaver 又会整体重建，重复刷新没有意义。
    if self._tick_fn then
        UIManager:unschedule(self._tick_fn)
    end
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
--- 省电参数：每次都现读设置（而不是缓存），菜单改完立刻生效，不用重开看板。
--- 越界值一律回落到默认，避免手改设置文件写进 0 秒把设备刷死。
function Dashboard:powerConfig()
    local function num(key, default, min, max)
        local v = tonumber(G_reader_settings:readSetting(key))
        if not v or v < min then v = default end
        if max and v > max then v = max end
        return v
    end
    return {
        tick_step = num(POWER_KEYS.tick_step, TICK_STEP, 0, 60),
        -- 天气间隔的优先级：菜单设置 > 配置文件 update_interval > 本文件常量，
        -- 这样已经在自己配置里调过间隔的人不会被这次改动悄悄改掉
        weather = num(POWER_KEYS.weather,
            tonumber(self:getConfig().update_interval) or UPDATE_INTERVAL, 300, 6 * 3600),
        full_refresh = num(POWER_KEYS.full_refresh, FULL_REFRESH_PERIOD, 0, 720),
        low_battery = num(POWER_KEYS.low_battery, LOW_BATTERY_GUARD, 0, 50),
    }
end

--- 带缓存地读电量。tick 的频率可能低到几十秒一次，每次都去 lipc 取
--- （PowerD 每读一个属性都是一次外部进程）不划算，这里缓存 10 分钟。
function Dashboard:quickBattery()
    local now = os.time()
    local c = self._batt_cache
    if c and c.ts and now - c.ts >= 0 and now - c.ts < BATTERY_CACHE_TTL then
        return c.cap, c.charging
    end
    local cap, charging = self:batteryInfo()
    self._batt_cache = { ts = now, cap = cap, charging = charging }
    return cap, charging
end

--- 电量低于阈值且没在充电。返回 false 表示不需要降频。
function Dashboard:lowBatteryNow()
    local pc = self:powerConfig()
    if pc.low_battery <= 0 then return false end
    local cap, charging = self:quickBattery()
    return (cap ~= nil and not charging and cap <= pc.low_battery) and true or false
end

--- 实际使用的时钟粒度（分钟）。0 = 只在触摸/唤醒时校正。
--- 低电时抬到 LOW_BATTERY_TICK_STEP，宁可时钟走得钝一点，也别把电池耗干。
function Dashboard:tickStep()
    local step = self:powerConfig().tick_step
    if step > 0 and self:lowBatteryNow() then
        step = math.max(step, LOW_BATTERY_TICK_STEP)
    end
    return step
end

function Dashboard:scheduleTick()
    if not self.shown then return end
    if not self._tick_fn then
        self._tick_fn = function() self:tick() end
    end
    UIManager:unschedule(self._tick_fn)
    local step = self:tickStep()
    -- 0 = 仅触摸模式：不排表。时钟停在上一次校正的时刻，碰一下屏幕才更新。
    if step <= 0 then return end
    local now = self:localNow()
    local sec = tonumber(now.sec) or 0
    local min = tonumber(now.min) or 0
    -- step=1 对齐整分；step>1 对齐到整 step 边界（5 分钟粒度就落在 0/5/10… 分）
    local remain = (step == 1) and (60 - sec) or ((step - (min % step)) * 60 - sec)
    UIManager:scheduleIn(math.max(1, remain), self._tick_fn)
end

function Dashboard:tick()
    if not self.shown or not self.root then return end
    -- 屏保态不干活：休眠时定时器本来就不会走，这里防的是挂起前刚好到点的那一拍，
    -- 否则会在力尽的那一刻白白刷一次屏。这里刻意不重排表——唤醒时
    -- onLeaveScreenSaver 会统一重建版面并重新排表，两边都排就会重建两次。
    if Device.screen_saver_mode or self.screensaver_owned then return end
    local wall = os.time()
    local now = self:localNow()
    local pc = self:powerConfig()
    local low = self:lowBatteryNow()

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
    -- 每次跳字闪一下很难看。菜单关掉后下一拍自然就补上了。
    if self.menu_open then
        self:scheduleTick()
        return
    end

    -- 分钟级：只改时钟文字，并且**只刷时钟那一块**。
    -- 原来刷的是整棵树（整屏 1072×1448），每跳一次要驱动 150 万像素；
    -- 缩到钟面区域后，同一次刷新的波形时间大约只要五分之一。
    local clock = string.format("%02d:%02d", now.hour, now.min)
    if self.clock_widget and clock ~= self.clock_text then
        self.clock_text = clock
        self.clock_widget:setText(clock)
        UIManager:setDirty(self.clock_widget, "ui")
    end

    -- 跨日：日期/农历/节气/月历全部要重算
    local day_key = string.format("%04d%02d%02d", now.year, now.month, now.day)
    if day_key ~= self.day_key then
        self:refreshLayout()
    elseif not low and pc.full_refresh > 0 and now.min % pc.full_refresh == 0 then
        -- 全刷是为了清电泳残影，纯消耗：低电时先让位，接上电就恢复
        UIManager:setDirty(self.root, "full")
    end

    -- 定时拉取天气：有数据时按设置间隔，还没有数据时 5 分钟重试。
    -- 刚唤醒的宽限期内先不拉：请求是同步的（http.TIMEOUT=20），会正好卡在
    -- 用户按电源键的那一刻，看起来就是「按了没反应」。低电也不拉。
    local fresh = self._resume_ts and (wall - self._resume_ts < RESUME_FETCH_GRACE)
    if not fresh and not low then
        -- 基准取「最近一次成功」与「最近一次尝试」的较新者。
        -- 只用 weather.ts 的话，没有数据时它是 nil，基准恒为 0，
        -- 于是每一拍都判定「过期」——原先是每分钟一轮请求，注释写的 5 分钟反而没生效。
        local last = math.max(self.weather and self.weather.ts or 0,
            self.last_fetch_ts or 0)
        local interval = pc.weather
        if not self.weather then
            interval = 5 * 60
        end
        -- 连续失败必须退避：接口挂掉时固定 5 分钟重试，每轮三个接口、每个 20 秒
        -- 超时，占空比能到两成，是这套代码里最费电的一种状态。
        local fails = self.fetch_fails or 0
        if fails > 0 then
            interval = math.min(interval * 2 ^ math.min(fails, 4), FETCH_BACKOFF_MAX)
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
    -- v2.61：统计库（statistics.sqlite3）靠 md5 认书，换过文件名也对得上，
    -- 所以侧车里必须把它带出来；没有 md5 才退到按书名匹配。
    local md5 = setting("partial_md5_checksum")
    if type(md5) == "string" and md5 ~= "" then out.md5 = md5 end
    -- summary.modified 是「最后一次翻页」的日期（"2026-11-12"），
    -- 统计插件被关掉时它是唯一能回答「上次什么时候读的」的来源。
    local sum = setting("summary")
    if type(sum) == "table" then
        local mod = sum.modified
        if mod == nil and type(sum.readSetting) == "function" then
            local ok_mod, v = pcall(function() return sum:readSetting("modified") end)
            if ok_mod then mod = v end
        end
        if type(mod) == "string" and mod ~= "" then out.modified = mod end
    end
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
                -- 封面要用书在磁盘上的路径（活文档优先直接取内存位图，见 dashboard_cover）
                local ok_file, file = pcall(function() return doc.file end)
                if ok_file and type(file) == "string" then info.path = file end
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
        info.path = path
        return info
    end

    return nil
end

-- ------------------------------------------------------------------ 阅读统计
--- 时长串：宁可粗一档，也不要长到把栏宽撑破。
--- 三栏各只有 200 出头像素，18 设计单位的字一行只放得下 6 个汉字，
--- 所以过 100 小时就换成「天 + 小时」，绝不再往细里写分钟。
local function fmtSpan(sec)
    sec = math.max(0, math.floor(tonumber(sec) or 0))
    if sec < 60 then return nil end
    local m = math.floor(sec / 60 + 0.5)
    if m < 60 then return TL(string.format("%d 分", m), string.format("%dm", m)) end
    local hh, mm = math.floor(m / 60), m % 60
    if hh < 100 then
        if mm < 1 then return TL(string.format("%d 小时", hh), string.format("%dh", hh)) end
        return TL(string.format("%d 小时 %d 分", hh, mm), string.format("%dh %dm", hh, mm))
    end
    local dd, rh = math.floor(hh / 24), hh % 24
    return TL(string.format("%d 天 %d 小时", dd, rh), string.format("%dd %dh", dd, rh))
end

--- 阅读统计：时长 / 已读屏数 / 最后一次打开 / 近 7 天节奏，都存在
--- statistics.sqlite3 里，侧车文件只有「读到第几页」，没有「读了多久」。
---
--- 三条硬约束（每一条都是踩过才写的）：
---  1) 全 pcall。库不存在（用户关掉了统计插件）、被独占、字段缺失，
---     任何一种失败都只返回 nil，卡片退回纯元数据版，绝不带走整块看板。
---  2) 用完即关。屏保态刷新时统计插件可能正在写同一个库，长连接会互相卡住。
---  3) 缓存 120 秒。看板每分钟重建一次版面，而 total_read_time 只在真正翻页时才变，
---     每分钟开一次库纯属浪费（实测单次 24ms，但没必要）。
local STATS_TTL = 120

function Dashboard:readingStats(info)
    if type(info) ~= "table" then return nil end
    local key = info.md5 or info.title
    if not key then return nil end

    local now = os.time()
    local memo = self._read_stats_memo
    if memo and memo.key == key and (now - memo.at) < STATS_TTL then
        return memo.data
    end

    local data
    local ok = pcall(function()
        local path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
        -- 先探文件是否存在：lua-ljsqlite3 的 open 默认带 create 标志，
        -- 直接开会「顺手」建出一个空库。用户关掉统计插件时不该留下这种东西。
        local fh = io.open(path, "rb")
        if not fh then return end
        fh:close()
        local SQ = require("lua-ljsqlite3/init")
        local db = SQ.open(path)
        if not db then return end
        local function query(sql)
            local st = db:prepare(sql)
            if not st then return end
            local row = st:step()
            pcall(function() st:close() end)
            return row
        end
        -- md5 优先；侧车里没有 partial_md5_checksum 时才按书名精确匹配
        local row
        if info.md5 then
            row = query(string.format(
                "select id, total_read_time, total_read_pages, last_open from book where md5 = '%s' limit 1",
                info.md5))
        end
        if not row and info.title then
            row = query(string.format(
                "select id, total_read_time, total_read_pages, last_open from book where title = '%s' limit 1",
                tostring(info.title):gsub("'", "''")))
        end
        if row then
            data = {
                read_time = tonumber(row[2]) or 0,
                read_pages = tonumber(row[3]) or 0,
                last_open = tonumber(row[4]),
            }
            local id = tonumber(row[1])
            if id then
                -- 「近 7 天」同时取总时长和天数：只读了一天就不该按 7 天摊，
                -- 否则 2 小时会被摊成 17 分钟/天，预计读完直接推后四倍。
                local w = query(string.format(
                    "select sum(duration), count(distinct date(start_time, 'unixepoch', 'localtime'))"
                    .. " from page_stat where id_book = %d and start_time >= %d",
                    id, now - 7 * 86400))
                if w then
                    data.week_sec = tonumber(w[1]) or 0
                    data.week_days = tonumber(w[2]) or 0
                end
            end
        end
        pcall(function() db:close() end)
    end)

    if not ok then data = nil end
    self._read_stats_memo = { key = key, at = now, data = data }
    return data
end

--- 这本书的「读过时间跨度」。返回一句可以直接画的话，或 nil。
--- 只精确到「天」：三天前和五天前用户没有分辨需求，但「今天」和「上周」差很多。
function Dashboard:readingLastText(info, stats)
    local ts = stats and stats.last_open
    if not ts or ts <= 0 then
        -- 统计插件没记过这本书时 last_open 是 0，退到侧车里的日期串
        local m = info and info.modified
        if type(m) == "string" then
            local y, mo, d = m:match("^(%d%d%d%d)-(%d%d)-(%d%d)")
            if y then
                ts = os.time{ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = 12 }
            end
        end
    end
    if not ts then return nil end
    local function midnight(t)
        local d = os.date("*t", t)
        d.hour, d.min, d.sec = 0, 0, 0
        return os.time(d)
    end
    local n = math.floor((midnight(os.time()) - midnight(ts)) / 86400 + 0.5)
    if n <= 0 then return T("今天读过") end
    if n == 1 then return T("昨天读过") end
    if n <= 30 then
        return TL(string.format("%d 天前读过", n), string.format("Read %d days ago", n))
    end
    return TL("上次读是 " .. os.date("%m-%d", ts), "Last read " .. os.date("%m-%d", ts))
end

--- 把「读到哪」和「读了多久」揉成一组已算好、可直接画的串。
--- 版式层只管摆，不再做除法——除法的口径集中在这里，改口径只改一处。
---
--- 剩余时长用「已读时长 × 剩余比例 / 已读比例」推，而不是「剩余页数 × 单页耗时」：
--- 后者要先知道一页书占几屏，而 statistics 的 total_read_pages 记的是**屏幕页**
--- （字号、行距一变页数就变）。两个比例约掉之后同一件事只剩一个乘法，
--- 误差只来自「前后读速是否一致」，这比拿屏幕页去乘书页可靠得多。
---
--- 门槛：统计页数不到 10 屏、或进度不到 2%，一律不给速度与预估。
--- 一本刚翻两页的书按比例外推会算出「还要 8 小时」这种假精度，宁可不显示。
function Dashboard:readingFacts(info, stats)
    local f = { pct = math.max(0, math.min(1, tonumber(info.percent) or 0)) }
    local pages = tonumber(info.pages)
    f.pages = pages
    local pct = f.pct

    if pages and pages > 0 then
        f.read_pages = math.max(0, math.min(pages, math.floor(pages * pct + 0.5)))
        f.page_text = TL(
            string.format("已读 %d / %d 页", f.read_pages, pages),
            string.format("%d of %d pages", f.read_pages, pages))
    end
    f.pct_text = string.format("%d%%", math.floor(pct * 100 + 0.5))

    if not stats then return f end
    f.used = fmtSpan(stats.read_time)

    local enough = stats.read_pages >= 10 and pct >= 0.02 and stats.read_time >= 60
    if not enough then return f end

    if f.read_pages and f.read_pages > 0 then
        f.per_page = stats.read_time / f.read_pages
        f.speed = TL(
            string.format("1 页 %.0f 秒", f.per_page),
            string.format("%.0fs / page", f.per_page))
    end
    local remain_sec = stats.read_time * (1 - pct) / pct
    f.remain = fmtSpan(remain_sec)

    -- 预计读完：只有近 7 天真的读过才给日期。7 天没碰的话，
    -- 日均会掉到接近 0，日期会跳到明年，那还不如不说。
    if stats.week_days and stats.week_days > 0 and (stats.week_sec or 0) >= 120 then
        local per_day = stats.week_sec / stats.week_days
        local days = math.ceil(remain_sec / per_day)
        if days >= 1 and days <= 400 then
            local d = os.date("*t", os.time() + days * 86400)
            f.eta_days = days
            f.eta = TL(
                string.format("按最近 7 天的读法，预计 %d 月 %d 日读完", d.month, d.day),
                string.format("At this pace: done around %s %d", os.date("%b", os.time() + days * 86400), d.day))
        end
    end
    return f
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
--- 重建版面并重绘。
--- mode 决定刷新方式，默认 "full"（整屏闪一下，最干净）：
---   "full" → 跨日、转屏、唤醒、首次打开，内容整体变了，值得闪一次
---   "ui"   → 只是数值变了（天气拉到新数据），不闪、走局部刷新，残影交给定时全刷
--- 这个区分能把「每拉一次天气就闪一次屏」消掉，一天少闪几十次。
function Dashboard:refreshLayout(mode)
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
    -- 传 nil 而不是 self.root：让**整块屏幕**进脏区。
    -- 看板是盖在 KOReader 界面上的全屏窗口，只脏自己的话，底层那一层探出边界
    -- 的旧像素洗不掉——真机上表现为顶栏左边压着上一屏文件管理器的时刻、
    -- 三格之间的缝里留着上一版的残笔。整屏重画时底层先画、看板后画，
    -- 边界之外也一并盖住。
    UIManager:setDirty(nil, mode or "full")
end

--- 屏幕当前是否呈横向（像素宽 >= 高）
function Dashboard:screenIsLandscape()
    return Screen:getWidth() >= Screen:getHeight()
end

--- 旋转屏幕到指定方向，返回 true 表示旋转真的生效。
--- 转完 Screen:getWidth()/getHeight() 会互换，版式随尺寸自动切换，不用另加强制标志。
---
--- v2.57：改成走 KOReader 自己的旋转入口。只调 Screen:setRotationMode 是**不够**的——
--- 那一步只改内部的 rotation 计数，Kindle 上真正换方向要重建 blitbuffer，
--- 这一步由 FileManager / ReaderView 的 onSetRotationMode 负责（它们会接着调 rotate()
--- 重排整棵树）。真机实测：单独调 setRotationMode，getSize 立刻变 1448×1072，
--- 但下一次 refresh 就按旧方向画回去，看板 refreshLayout 时已经复位，
--- 于是永远排成竖屏。委托给 ui:onSetRotationMode 之后画面才真的转过来。
--- 顺序不能反：先自己 set 再调它，它判定「方向没变」就跳过重排（踩过）。
function Dashboard:rotateScreen(mode)
    if mode ~= "portrait" and mode ~= "landscape" and mode ~= "landscape_ccw" then
        return false
    end
    if not (Screen.setRotationMode and Screen.getRotationMode) then return false end
    local target = target_rotation(self.base_rotation or 0, mode)
    local ui = self.ui
    local ok, err = pcall(function()
        if ui and ui.onSetRotationMode then
            -- FileManager 的模式：内部判 mode ~= 当前值，再 Screen:setRotationMode + rotate()
            ui:onSetRotationMode(target)
        elseif ui and ui.view and ui.view.onSetRotationMode then
            ui.view:onSetRotationMode(target)
        else
            Screen:setRotationMode(target)
        end
    end)
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
    -- 与 open 同一个原因：转屏后尺寸要晚一拍才互换，这里再补排一次，
    -- 否则从菜单切横屏时画出来的还是竖屏版式。
    if rotated then
        -- 1.2s：与 open 同一个理由，转屏后尺寸互换需要时间
        UIManager:scheduleIn(1.2, function()
            if self.shown and not self.menu_open then self:refreshLayout() end
        end)
    end
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

-- ---------------------------------------------------------------- 组件列表（点按展开）
--- 点到了哪个「可展开」的区？返回 zone key（"A"/"B"/"C"）或 nil。
--- 坐标是屏幕绝对坐标，与 registerTouchZones 给的 ges.pos 同一坐标系。
function Dashboard:zoneHitAt(x, y)
    local hits = self.zone_hits
    if type(hits) ~= "table" then return nil end
    for key, rec in pairs(hits) do
        if rec.x and rec.y
            and x >= rec.x and x < rec.x + rec.w
            and y >= rec.y and y < rec.y + rec.h then
            return key
        end
    end
    return nil
end

--- 开一个「看板自己的」TouchMenu：复用 self.menu / menu_open 这套状态，
--- 关菜单时走同一个 onMenuClosed，所以 tick 暂停、关后重排这些行为全部继承。
--- 和 openMenu 的区别只是菜单项不同，所以没有并到那里去（那条路径是验证过的，
--- 不动它最省事）。
function Dashboard:openTouchMenu(items)
    local loaded, TouchMenu = pcall(require, "ui/widget/touchmenu")
    if not loaded or type(TouchMenu) ~= "table" then
        logger.warn("dashboard: TouchMenu 不可用，无法展开列表")
        return false
    end
    local tab = { icon = "appbar.settings", callback = function() end }
    for i, it in ipairs(items) do tab[i] = it end

    local menu
    self.menu_open = true
    local ok, err = pcall(function()
        menu = TouchMenu:new{
            width = math.floor(Screen:getWidth() * 0.94),
            tab_item_table = { tab },
            close_callback = function() self:onMenuClosed(menu) end,
        }
        menu._dashboard_menu = true
        self.menu = menu
        UIManager:show(menu)
    end)
    if not ok then
        self.menu = menu
        self.menu_open = (menu ~= nil)
        logger.warn("dashboard: 列表菜单构造失败", tostring(err))
        return false
    end
    return true
end

--- 点组件 → 按当前版式找到该区的组件，弹出对应列表
function Dashboard:openZoneList(key)
    if not self.shown then return end
    local orient = self.layout_landscape and "landscape" or "portrait"
    local id = self:getZoneLayout()[orient][key]
    local comp = COMPONENTS[id]
    if not comp or not comp.expandable then return end
    local items
    if comp.expandable == "countdown" then
        items = self:countdownListItems()
    else
        items = self:todoListItems()
    end
    return self:openTouchMenu(items)
end

local function menu_header(text)
    -- TouchMenu 的条目必须有 callback；给个空函数就是「只显示、点了不动」
    return { text = text, keep_menu_open = true, callback = function() end }
end

--- 倒数日列表：每条可切换置顶，最后一条去添加。
function Dashboard:countdownListItems()
    local now = self:localNow()
    local v = Agenda.eventsView(now)
    local items = { menu_header(T("倒数日")) }
    if v.total == 0 then
        items[#items + 1] = menu_header(T("暂无倒数日"))
    else
        -- 顺序与组件一致：先大字位那条，再列表
        local ordered = {}
        if v.focus then ordered[#ordered + 1] = v.focus end
        for _, e in ipairs(v.list) do ordered[#ordered + 1] = e end
        for _, e in ipairs(ordered) do
            local label = string.format("%s%s · %s · %s",
                e.pinned and "★ " or "", e.name, e.date, I18n.relDays(e.days))
            items[#items + 1] = {
                text = label,
                keep_menu_open = true,
                checked_func = function() return e.pinned end,
                callback = function()
                    Agenda.pinEvent(e.id)
                    self:afterAgendaChange()
                end,
            }
        end
    end
    items[#items + 1] = {
        text = T("添加倒数日"),
        keep_menu_open = false,
        callback = function() self:promptAddEvent() end,
    }
    return items
end

--- 待办列表：今日 → 未来 → 已过期，点一条就勾选/取消。
function Dashboard:todoListItems()
    local now = self:localNow()
    local v = Agenda.todosView(now)
    local items = { menu_header(T("待办事项")) }

    local function toggler(it, label)
        return {
            text = label,
            keep_menu_open = true,
            checked_func = function() return it.done end,
            callback = function()
                Agenda.toggleTodo(it.id)
                self:afterAgendaChange()
            end,
        }
    end

    if #v.today > 0 then
        items[#items + 1] = menu_header(T("今天"))
        for _, it in ipairs(v.today) do
            items[#items + 1] = toggler(it,
                string.format("%s %s", it.done and "[x]" or "[ ]", it.text))
        end
    end
    if #v.future > 0 then
        items[#items + 1] = menu_header(T("未来"))
        for _, it in ipairs(v.future) do
            items[#items + 1] = toggler(it, string.format("[ ] %s · %s", it.text,
                I18n.monthDay(it.month, it.day)))
        end
    end
    if #v.past > 0 then
        items[#items + 1] = menu_header(T("已过期"))
        for _, it in ipairs(v.past) do
            items[#items + 1] = toggler(it, string.format("[ ] %s · %s", it.text,
                I18n.monthDay(it.month, it.day)))
        end
    end
    if #v.today + #v.future + #v.past == 0 then
        items[#items + 1] = menu_header(T("今日无待办"))
    end
    items[#items + 1] = {
        text = T("添加待办"),
        keep_menu_open = false,
        callback = function() self:promptAddTodo() end,
    }
    return items
end

--- 数据改完之后统一收尾：菜单开着就等关菜单时重排（onMenuClosed 会做），
--- 没开菜单就直接重排。
function Dashboard:afterAgendaChange()
    if not self.shown then return end
    if self.menu_open then
        self.relayout_pending = true
        return
    end
    self:refreshLayout()
end

-- ---------------------------------------------------------------- 倒数日 / 待办：菜单与录入
--- 删除确认。ConfirmBox 不可用（老版本）时直接删，不能让功能卡在这里。
function Dashboard:confirmRemove(text, on_ok)
    local ok, ConfirmBox = pcall(require, "ui/widget/confirmbox")
    if not ok or type(ConfirmBox) ~= "table" then
        return on_ok()
    end
    local dialog
    dialog = ConfirmBox:new{
        text = text,
        ok_text = T("删除"),
        cancel_text = T("取消"),
        ok_callback = function()
            UIManager:close(dialog)
            on_ok()
        end,
    }
    UIManager:show(dialog)
end

--- 单行录入的公共壳子：一个输入框 + 取消/保存。
function Dashboard:promptOneLine(opts)
    local dialog
    dialog = InputDialog:new{
        title = opts.title,
        description = opts.description,
        input = opts.input or "",
        input_hint = opts.hint,
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
                        local raw = dialog:getInputText() or ""
                        UIManager:close(dialog)
                        opts.onSave(raw)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    if dialog.onShowKeyboard then dialog:onShowKeyboard() end
end

--- 两步录入的第 2 步：点选日期。年 / 月 / 日 三列各自上下翻，全程不弹键盘
--- （Kindle 上 KOReader 只能用自己的虚拟键盘，中文要切拼音+翻候选，能少敲就少敲）。
--- init 是 "YYYY-MM-DD"；给不出合法值就落在今天。
function Dashboard:promptPickDate(title, init, on_pick)
    local ok, DateTimeWidget = pcall(require, "ui/widget/datetimewidget")
    if not ok then
        UIManager:show(InfoMessage:new{ text = T("日期选择器不可用，请更新 KOReader。"), timeout = 3 })
        return
    end
    local y, m, d = Agenda.parseDate(init)
    if not y then
        local now = self:localNow()
        y, m, d = now.year, now.month, now.day
    end
    UIManager:show(DateTimeWidget:new{
        year = y, month = m, day = d,
        -- 下限放到 1970：倒数日也会记已经过去的日子（显示「已过 N 天」）
        year_min = 1970,
        info_text = title,
        ok_text = T("保存"),
        cancel_text = T("取消"),
        callback = function(sel)
            on_pick(Agenda.fmtDate(sel.year, sel.month, sel.day))
        end,
    })
end

--- 两步录入的公共壳子：第 1 步一个输入框（名称 / 内容），第 2 步点选日期。
--- 两步都由调用方给文案；parse(raw, now) 返回 text, date，text 为空即视为没填。
function Dashboard:promptTwoStep(opts)
    local now = self:localNow()
    self:promptOneLine{
        title = opts.title,
        description = opts.description,
        hint = opts.hint,
        onSave = function(raw)
            local text, init = opts.parse(raw, now)
            if not text or text == "" then
                UIManager:show(InfoMessage:new{ text = opts.empty_text, timeout = 3 })
                return
            end
            -- 输入框刚关掉就弹下一个窗口，等一拍更稳：避免两个窗口在 e-ink 上抢刷新
            UIManager:nextTick(function()
                self:promptPickDate(opts.picked_title, init, function(date)
                    opts.onPick(text, date)
                end)
            end)
        end,
    }
end

function Dashboard:promptAddEvent()
    self:promptTwoStep{
        title = T("添加倒数日"),
        description = TL(
            "第 1 步：填事项名称。\n"
            .. "第 2 步：点选日期（年、月、日各自翻页，不用敲键盘）。",
            "Step 1: name the event.\n"
            .. "Step 2: pick the date (no typing)."),
        hint = TL("妈妈生日", "Mum's birthday"),
        empty_text = T("名称不能为空。"),
        picked_title = T("选日期"),
        -- 名称里顺手带了日期（"圣诞节 2026-12-25"）也认：拆出来当默认值，省一次翻页
        parse = function(raw, now)
            local name, date = Agenda.parseEvent(raw, now)
            if name then return name, date end
            return Agenda.trim(raw), nil
        end,
        onPick = function(name, date)
            -- 第一条自动置顶：否则大字位会空着，看起来像没生效
            Agenda.addEvent(name, date, #Agenda.allEvents() == 0)
            self:afterAgendaChange()
        end,
    }
end

function Dashboard:promptAddTodo()
    self:promptTwoStep{
        title = T("添加待办"),
        description = TL(
            "第 1 步：填待办内容。\n"
            .. "第 2 步：点选日期（默认今天，可改）。",
            "Step 1: the task text.\n"
            .. "Step 2: pick the date (today by default)."),
        hint = TL("交周报", "Email report"),
        empty_text = T("内容不能为空。"),
        picked_title = T("选日期"),
        -- 没写日期就是今天（parseTodo 的既有约定）
        parse = function(raw, now)
            return Agenda.parseTodo(raw, now)
        end,
        onPick = function(text, date)
            Agenda.addTodo(text, date)
            self:afterAgendaChange()
        end,
    }
end

--- 「倒数日」设置子菜单：添加 + 逐条（置顶 / 删除）
function Dashboard:genCountdownMenu()
    local now = self:localNow()
    local items = {
        {
            text = T("添加倒数日"),
            keep_menu_open = false,
            callback = function() self:promptAddEvent() end,
        },
    }
    local list, events = {}, Agenda.allEvents()
    for _, e in ipairs(events) do list[#list + 1] = e end
    table.sort(list, function(a, b)
        local da = Agenda.daysBetween(Agenda.today(now), a.date) or 0
        local db = Agenda.daysBetween(Agenda.today(now), b.date) or 0
        if da ~= db then return da < db end
        return a.id < b.id
    end)
    for _, e in ipairs(list) do
        local days = Agenda.daysBetween(Agenda.today(now), e.date) or 0
        local sub = {
            {
                text = T("置顶这条"),
                checked_func = function() return e.pinned end,
                callback = function()
                    Agenda.pinEvent(e.id)
                    self:afterAgendaChange()
                end,
            },
            {
                text = T("删除"),
                keep_menu_open = false,
                callback = function()
                    self:confirmRemove(string.format("%s「%s」？", T("删除"), e.name), function()
                        Agenda.removeEvent(e.id)
                        self:afterAgendaChange()
                    end)
                end,
            },
        }
        -- 已经置顶的那条，「置顶这条」点了没变化，干脆给一条取消
        if e.pinned then
            sub[1] = {
                text = T("取消置顶"),
                callback = function()
                    Agenda.unpinAll()
                    self:afterAgendaChange()
                end,
            }
        end
        items[#items + 1] = {
            text = string.format("%s · %s · %s", e.name, e.date, I18n.relDays(days)),
            sub_item_table = sub,
        }
    end
    return items
end

--- 「待办事项」设置子菜单：添加 + 分组列表（完成 / 删除）+ 清除已完成
function Dashboard:genTodoMenu()
    local now = self:localNow()
    local v = Agenda.todosView(now)
    local items = {
        {
            text = T("添加待办"),
            keep_menu_open = false,
            callback = function() self:promptAddTodo() end,
        },
    }
    local function entry(it, label)
        return {
            text = label,
            sub_item_table = {
                {
                    -- checked_func 让 TouchMenu 走「只刷新、不关菜单」那条分支，
                    -- 勾完还能接着勾下一条
                    text = T("已完成"),
                    checked_func = function() return it.done end,
                    callback = function()
                        Agenda.toggleTodo(it.id)
                        self:afterAgendaChange()
                    end,
                },
                {
                    text = T("删除"),
                    keep_menu_open = false,
                    callback = function()
                        self:confirmRemove(string.format("%s「%s」？", T("删除"), it.text),
                            function()
                                Agenda.removeTodo(it.id)
                                self:afterAgendaChange()
                            end)
                    end,
                },
            },
        }
    end
    if #v.today > 0 then
        items[#items + 1] = menu_header(T("今天"))
        for _, it in ipairs(v.today) do
            items[#items + 1] = entry(it, string.format("%s %s", it.done and "[x]" or "[ ]", it.text))
        end
    end
    if #v.future > 0 then
        items[#items + 1] = menu_header(T("未来"))
        for _, it in ipairs(v.future) do
            items[#items + 1] = entry(it, string.format("%s · %s", it.text,
                I18n.monthDay(it.month, it.day)))
        end
    end
    if #v.past > 0 then
        items[#items + 1] = menu_header(T("已过期"))
        for _, it in ipairs(v.past) do
            items[#items + 1] = entry(it, string.format("%s · %s", it.text,
                I18n.monthDay(it.month, it.day)))
        end
    end
    items[#items + 1] = {
        text = T("清除已完成"),
        keep_menu_open = false,
        callback = function()
            local n = Agenda.clearDone()
            UIManager:show(InfoMessage:new{
                text = string.format("%s %d %s", T("清除已完成"), n, I18n.items(n)),
                timeout = 2,
            })
            self:afterAgendaChange()
        end,
    }
    return items
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
    local size = math.max(11, math.floor(px))
    local face = opts.face
    if not face and opts.serif then face = FACE_SERIF end
    local color = opts.color or COLOR_BLACK
    if opts.gray and not opts.color then
        -- 灰阶跟字号绑定：0x88 在 30px 以下会发虚（实测），30px = 17 设计单位。
        -- 所以小字一律降到 0x66，"最浅那档"只留给真正的大字。这条比墨阶表更实用：
        -- 全站所有 gray=true 的调用点不必逐个改，按字号自动落档。
        color = (size >= 17) and INK3 or INK2
    end
    return TextWidget:new{
        text = str or "",
        face = Font:getFace(face or "cfont", size),
        bold = opts.bold or false,
        fgcolor = color,
        padding = 0,
        max_width = opts.max_width,
        -- 顶栏这类「高度固定的一行」不能折行：折了就把 header 顶高，
        -- 下面的三区预算全部跟着缩水。传 ellipsis 时改成像真机那样截断加省略号。
        truncate_with_ellipsis = opts.ellipsis or nil,
    }
end

--- 纯数字串（时钟、温度、AQI、倒计时）用衬线。
--- 单独一个方法而不是给 makeText 加分支：调用点一眼能看出「这里换族了」，
--- 也方便日后统一改回来。中文串**不要**走这里——衬线字体没有汉字，会回退成黑体，
--- 一行里两种字形混排看着像 bug。
function Dashboard:makeNum(ctx, str, px, opts)
    opts = opts or {}
    opts.serif = true
    return self:makeText(ctx, str, px, opts)
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
        -- 每次试排都清空命中表：只有最后一版（真正显示的那棵）的坐标有效，
        -- 留着上一版会让点按打到已经不存在的盒子上。
        self.zone_hits = {}
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

    -- 全屏纸底：WidgetContainer 不会自动填背景，必须自己刷。
    -- v2.53 起铺 0xEE 而不是纯白 —— 三张白卡浮在微灰的纸上，卡与纸之间就有了
    -- 层次（纯白底上再画白卡，等于什么都没画）。
    root.paintTo = function(self, bb, x, y)
        bb:paintRect(x, y, W, H, PAPER)
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
            -- 必须排在最前：命中可展开组件时吃掉这一下，没命中返回 false，
            -- 后面的「点按刷新」照常接管（框架按注册顺序问，false 就继续问下一个）。
            id = "dashboard_zone_tap",
            ges = "tap",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            handler = function(ges)
                if not self.shown then return false end
                local pos = ges and ges.pos
                if not pos or not pos.x or not pos.y then return false end
                local key = self:zoneHitAt(pos.x, pos.y)
                if not key then return false end
                -- 直接在这里弹菜单会重入事件分发，推迟一拍
                UIManager:nextTick(function() self:openZoneList(key) end)
                return true
            end,
        },
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

--- 顶部条：城市 + 时区（左） / 电量（右），两端撑满。
--- v2.53 减信息：去掉了「更新于 16:18」——那是 A 区大钟已经回答过的问题，
--- 而它把顶栏挤成三段等宽的碎块。数据时刻挪到页脚，只在低头找的时候才需要。
function Dashboard:buildHeader(ctx, pad_lr)
    local W, S = ctx.body_w or ctx.W, ctx.S
    local avail = W - pad_lr * 2

    -- 右侧：WiFi 状态图标 + 电量百分比 + 电池壳体
    local right_items = { align = "center" }
    -- 顶栏是「一眼扫过」的地带：无线状态用三段弧 + 斜杠说清（连/未连/未开），
    -- 比「未连接」三个汉字快得多，也不吃宽度。与 C 区「电量网络」同一套图标，
    -- 两处看到的图形语言是一个。
    local net = self:netInfo()
    if net.wifi_on ~= nil then
        if net.wifi_on == false then
            -- v2.59：未开启改用汉字。那套「只亮内段 + 斜杠」要跟"未连接"的
            -- 「三段弧 + 斜杠」并排比才分得清；顶栏只出现一枚时两者看着是同一张图，
            -- 图形反而比字模糊。三个汉字 17px 占 51px，比图标加间距的 74px 还窄。
            right_items[#right_items + 1] = self:makeText(ctx, T("未开启"), 14,
                { color = INK2 })
            right_items[#right_items + 1] = mkPad(math.floor(12 * S), 1)
        else
            local opts = { color = INK2 }
            if not net.connected then opts.slash = true end
            right_items[#right_items + 1] = self:icon("wifi", math.floor(30 * S), opts)
            right_items[#right_items + 1] = mkPad(math.floor(12 * S), 1)
        end
    end
    local cap, charging = self:batteryInfo()
    if cap then
        right_items[#right_items + 1] = self:makeText(ctx, string.format("%d%%", cap), 17,
            { gray = true })
        right_items[#right_items + 1] = mkPad(math.floor(9 * S), 1)
        right_items[#right_items + 1] = BatteryGauge:new{
            dimen = Geom:new{
                w = math.floor(34 * S),
                h = math.max(10, math.floor(17 * S)),
            },
            border = math.max(1, math.floor(1.4 * S)),
            ratio = cap / 100,
            charging = charging,
            color = INK2,
        }
    end
    local right = HorizontalGroup:new(right_items)

    -- 左侧：城市名一档、时区一档，靠字号与颜色分层，不再用「·」串成一句
    local min_fill = math.floor(16 * S)
    local tz = self:makeText(ctx, I18n.headerTz(ctx.tz), 17, { gray = true })
    local left_w = math.floor(avail - right:getSize().w - min_fill)
    left_w = math.max(math.floor(avail * 0.35), left_w)
    local city = self:makeText(ctx, I18n.city(self:getCity()), 24,
        { max_width = math.max(math.floor(80 * S), left_w - tz:getSize().w - math.floor(10 * S)),
          ellipsis = true })
    local left = HorizontalGroup:new{
        align = "center",
        city,
        mkPad(math.floor(10 * S), 1),
        tz,
    }
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
        -- 温度是纯拉丁数字串，换衬线；下面两行是中文，一律留在黑体。
        self:makeNum(ctx, d.temp, temp_px, { max_width = side_max }),
        self:makeText(ctx, d.cond, 26, { max_width = side_max }),
        d.feels and self:makeText(ctx, d.feels, 17, { color = INK2, max_width = side_max })
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
function Dashboard:buildStatCells(ctx, total_w, items, box_h)
    local n = #items
    local S = ctx.S
    local cell_w = math.floor((total_w - (n - 1)) / n)
    -- v2.53：格子高度跟着卡片可用高走。原来是死板的 86 设计单位，
    -- 卡一变高就在格子下面空出一截——三格里"湿度 / 44% / 南风"挤在上半，下半全空。
    -- 改成「三行字量出固定高，剩余按 4:6 分给两个间距」：标签贴数值、数值离注远一点，
    -- 眼睛先读数值。这也顺便让 2 格（电量 / 网络）和 3 格长得一样高。
    local function lineH(px) return math.floor(px * S * 1.363) end
    -- 图标与数值同高（32du ≈ 57px）。放在 17du 的标签行里只有 43px，
    -- 水滴、刻度盘那些轮廓在 300ppi 上会发虚、认不出是什么 ——
    -- 图标小到认不出，就等于没画。
    local icon_px = math.floor(32 * S)
    local icon_gap = math.floor(9 * S)
    local tag_h = lineH(17)
    local val_h = lineH(38)
    local fixed_h = tag_h + val_h + tag_h
    -- 减 2：TextWidget 的实际行高比 1.363 估出来的偶尔多 1~2px，贴着算会顶出去
    local cell_h = math.max(math.floor(86 * S), math.floor((box_h or 0) - 2))
    local slack = math.max(0, cell_h - fixed_h)
    local gap_a = math.floor(slack * 0.4)
    local gap_b = math.max(0, slack - gap_a)

    -- v2.56：三格原先各自居中，谁的内容宽一点就先从中间散开——
    -- 结果三枚图标各在不同 x 上，三行文字也各在各的轴线上，看着"没对齐"。
    -- 做法改成「先量出最宽那一格，给三格同一个内容块宽」：块宽一旦相同，
    -- 块内的标签左沿、图标左沿、数值左沿在三格里就是同一组坐标，
    -- 块再以 cell_w 居中，整条还保持居中。对齐和居中不是二选一。
    local rows, block_w = {}, 0
    for i, it in ipairs(items) do
        local tag = self:makeText(ctx, it[1], 17, { color = INK2 })
        local val, lead
        if type(it[2]) == "table" and type(it[2].paintTo) == "function" then
            -- 值本身是图形（电池壳体、WiFi 状态），不再另配图标
            val, lead = it[2], 0
        elseif it[4] then
            -- 「▽ 44%」：图标占一个固定宽的位，数值右移同样的距离
            val, lead = self:makeText(ctx, it[2], 38), icon_px + icon_gap
        else
            val, lead = self:makeText(ctx, it[2], 38), 0
        end
        local note = it[3] and self:makeText(ctx, it[3], 17, { color = INK2 }) or nil
        local bw = math.max(tag:getSize().w, lead + val:getSize().w)
        if note then bw = math.max(bw, lead + note:getSize().w) end
        rows[i] = { tag = tag, val = val, note = note, lead = lead,
                    icon = it[4], icon_opts = it[5] }
        block_w = math.max(block_w, bw)
    end
    block_w = math.min(block_w, cell_w)

    -- 三格铺满整条内容列（块左沿贴版心左沿），两格仍旧各自居中在自己的半格。
    -- 为什么要分开：三格里第一块的左沿就是整页的"左轨"，上面几张卡的块头都在这条线上，
    -- 它一缩进 50px 就断了；两格时居中在 1/4 与 3/4 才是稳的（贴两边会显得被拉开）。
    local split = (n >= 3)
    local gap_x = split and math.max(0, math.floor((total_w - block_w * n) / (n - 1))) or 0

    local cells = {}
    for i, r in ipairs(rows) do
        if i > 1 and not split then
            cells[#cells + 1] = mkBox(1, cell_h, nil)
        end
        local val_row = r.icon and HorizontalGroup:new{
            align = "center",
            self:icon(r.icon, icon_px, r.icon_opts),
            mkPad(icon_gap, 1),
            r.val,
        } or r.val
        -- 每一行都装进等高定宽的盒子里：盒子高度固定，行与行在三格之间才齐；
        -- 盒子宽度固定，块的左右沿才一样。
        local block = VerticalGroup:new{
            align = "left",
            mkBox(block_w, tag_h, r.tag, { align = "left" }),
            mkPad(1, gap_a),
            mkBox(block_w, val_h, val_row, { align = "left" }),
            mkBox(block_w, tag_h, r.note, { align = "left" }),
            mkPad(1, gap_b),
        }
        if split then
            cells[#cells + 1] = block
            if i < n then cells[#cells + 1] = mkPad(gap_x, 1) end
        else
            cells[#cells + 1] = mkBox(cell_w, cell_h, block,
                { align = "center", auto_h = true })
        end
    end
    return HorizontalGroup:new{ align = "center", unpack(cells) }
end

-- ---------------------------------------------------------------- 分区装配
--- 建一个区：按当前配置取组件 → 在固定盒子里从 k=1 起逐档收紧字号，直到装得下。
--- 盒子宽高固定，组件内容在盒内居中（Stack 默认居中对齐），所以换组件不会
--- 牵动别的区；装不下也绝不裁切，只记日志交给 createRoot 的全局缩放兜底。
--- 取一枚图标。size 是像素边长（已乘 S），opts 里可带 color / slash / value / max / lit。
--- 名字写错时返回一块等大的留白而不是崩：图标是装饰层，不该阻断整屏绘制。
---
--- v2.58：优先用 icons/ui/ 下预渲染的位图，没有对应尺寸再退回现场矢量绘制。
--- 为什么改：Icon 画弧和圆心要走 bb:paintCircle，真机 KOReader 与本地桩件
--- 对它的第 5 个参数解释不一致（真机当布尔 filled、桩件当线宽），于是
--- 「预览干净、真机在图标周围多出孤立墨点」。位图一个像素一个值，
--- 画成什么样就是什么样，也不会越出自己的方框。
function Dashboard:icon(name, size, opts)
    opts = opts or {}
    local px = math.max(8, math.floor(size))
    local file = self:iconBitmap(name, px, opts)
    if file then
        -- width/height 与文件边长严格相等：ImageWidget 一旦缩放，抗锯齿的边
        -- 会被再采样一次，比现场画的还糊。scale_for_dpi 必须关掉，
        -- 否则 KOReader 会按屏幕 DPI 把 89px 的图再放大 1.79 倍。
        local ok, w = pcall(function()
            return ImageWidget:new{
                file = file,
                width = px,
                height = px,
                alpha = true,
                scale_for_dpi = false,
            }
        end)
        if ok and w then return w end
    end
    local shapes = ICON[name]
    if not shapes then return mkPad(px, px) end
    return Icon:new{
        dimen = Geom:new{ w = px, h = px },
        shapes = shapes,
        color = opts.color or INK2,
        thick = opts.thick,
        slash = opts.slash,
        value = opts.value,
        max = opts.max,
        lit = opts.lit,
    }
end

--- 把一个图标调用换算成 icons/ui/<键名>-<边长>.png；没有这张图返回 nil。
--- 键名是「状态」而不是「调用参数」：wifi 的 lit/slash 组合收敛成三种文件，
--- 刻度盘把连续角度收敛成 13 档，位图数量才不会随数据膨胀。
--- 缓存只为省掉重复的 stat：一次重排里同一个小图标会被问好几遍。
function Dashboard:iconBitmap(name, px, opts)
    opts = opts or {}
    local key
    if name == "wifi" then
        if opts.slash and (opts.lit or 3) <= 1 then
            key = "wifi_off"
        elseif opts.slash then
            key = "wifi_slash"
        else
            key = "wifi_on"
        end
    elseif name == "drop" then
        key = "humidity"
    elseif name == "wind" then
        key = "wind"
    elseif name == "gauge" then
        if opts.value == nil then
            key = "aqi_fixed"
        else
            local v = math.max(0, math.min(1, (opts.value or 0) / (opts.max or 300)))
            key = string.format("aqi_p%02d", math.floor(v * (AQI_STEPS - 1) + 0.5))
        end
    else
        return nil
    end
    local rel = "ui/" .. key .. "-" .. px
    -- 位图是死色，不能像矢量那样运行时改 color：电量网络卡里"已连接"用纯黑、
    -- 其余用 0x66，所以黑墨那一份单独存（后缀 -b）。
    --
    -- 用显式标记 opts.black，**不要**写 opts.color == COLOR_BLACK：真机上
    -- COLOR_BLACK 是 ffi cdata，与另一个 cdata 比较会走 ColorRGB32_mt.__eq
    -- （ffi/blitbuffer.lua:602 attempt to index local 'self'），桩件里是数字、永远测不出来。
    -- v2.59 上机即崩在 buildZone → icon → iconBitmap 这条路上，就是这一行。
    if opts.black then rel = rel .. "-b" end
    local cache = self._icon_bitmap_cache
    if not cache then
        cache = {}
        self._icon_bitmap_cache = cache
    end
    local hit = cache[rel]
    if hit ~= nil then
        return hit or nil
    end
    local file = self:iconPath(rel)
    local fh = io.open(file, "rb")
    if fh then
        fh:close()
        cache[rel] = file
        return file
    end
    cache[rel] = false
    return nil
end

function Dashboard:buildZone(ctx, orient, key, box_w, content_w, box_h)
    local id = self:getZoneLayout()[orient][key]
    local comp = COMPONENTS[id] or COMPONENTS[ZONE_DEFAULT[orient][key]]
    local method = comp.build
    -- v2.53：盒子变成一张卡片。box_w 是卡宽，content_w 是卡内可用宽
    -- （调用方按 box_w - 2*card_pad 算好传进来），box_h 含上下内边距。
    local S = ctx.S
    local cpad = math.floor(ZONE_SPEC[orient].card_pad * S)
    local inner_h = math.max(1, box_h - cpad * 2)
    local child
    for i = 1, #K_LADDER do
        child = self[method](self, ctx, content_w, inner_h, K_LADDER[i])
        if child:getSize().h <= inner_h then break end
        if i == #K_LADDER then
            logger.warn(string.format(
                "dashboard: 组件 %s 在 %s 区（内容高 %d）收到最小档仍占 %d，交给全局缩放",
                id, key, inner_h, child:getSize().h))
        end
    end
    local box = Card:new{
        dimen = Geom:new{ w = math.floor(box_w), h = math.floor(box_h) },
        pad_l = cpad,
        pad_t = cpad,
        pad_b = cpad,
        radius = math.floor(CARD_RADIUS * S),
        bg = COLOR_WHITE,
        border = math.max(1, math.floor(1.4 * S)),
        border_color = CARD_EDGE,
        -- A 卡是「时钟 + 天气」这种矮块，卡里通常还有几十像素余量：
        -- 顶部对齐会把整块内容顶在卡的上沿、下面空一条，居中看着才像"一张卡"。
        -- 没有块头的组件（日月）同理，即便它在 B/C 区也要居中。
        valign = ((key == "A") or comp.valign_center) and "center" or nil,
        child,
    }

    -- 可展开组件（倒数日 / 待办）要记录盒子在**屏幕上的绝对坐标**，点按时按坐标
    -- 判断点到的是哪个区。坐标只有绘制时才确定（版心居中 → 四边留白 → 拉伸间距
    -- 都会影响），所以在 paintTo 里顺手存一份；点按一定发生在绘制之后，读到的是
    -- 当前这一帧的值。盒子在每次重排时重建，记录自然跟着换。
    if comp.expandable then
        local rec = { kind = comp.expandable, id = id, w = box_w, h = box_h }
        self.zone_hits[key] = rec
        local base_paint = box.paintTo
        box.paintTo = function(this, bb, x, y)
            rec.x, rec.y = x, y
            return base_paint(this, bb, x, y)
        end
    end
    return box
end

--- 一条横向分隔线（宽度取版心宽，与四边留白对齐）
--- v2.53：三区改成卡片之后，页面上不再有通栏黑线；仅保留给卡内细分隔用。
local function softRule(w, px, color)
    return Solid:new{
        dimen = Geom:new{ w = w, h = math.max(1, math.floor(px)) },
        color = color or RULE_SOFT,
    }
end

-- ---------------------------------------------------------------- 竖屏：三张卡
function Dashboard:buildPortrait(ctx)
    local W, S = ctx.body_w or ctx.W, ctx.S
    local spec = ZONE_SPEC.portrait
    -- 顶栏与卡片**内容列**对齐（不是与卡片外沿对齐）：卡有内边距，顶栏跟着内缩，
    -- 于是页面上只有一条左基准线。原来顶栏缩进 26px、正文缩进 76px，三个边距并存。
    local cpad = math.floor(spec.card_pad * S)
    local content_w = W - cpad * 2
    local gap = math.floor(spec.gap * S)
    local rows = {}
    local function push(x) rows[#rows + 1] = x end

    push(self:buildHeader(ctx, cpad))
    push(mkPad(W, math.floor(spec.head_gap * S)))

    -- 时钟控件只由 clock_weather 组件产生；清空必须放在循环**外**，
    -- 否则建完 A 再建 B/C 时会把刚设好的引用清掉（桩件有断言专门抓这个）
    self.clock_widget = nil
    for i, key in ipairs(ZONE_KEYS) do
        push(self:buildZone(ctx, "portrait", key, W, content_w, math.floor(spec[key] * S)))
        if i < #ZONE_KEYS then
            push(mkPad(W, gap))
        end
    end

    push(mkPad(W, math.floor(spec.foot_gap * S)))
    push(self:buildHintRow(ctx, content_w, cpad, 17))
    return VerticalGroup:new{ align = "left", unpack(rows) }
end

-- ---------------------------------------------------------------- 横屏：一横条 + 两张卡
function Dashboard:buildLandscape(ctx)
    local W, S = ctx.body_w or ctx.W, ctx.S
    local spec = ZONE_SPEC.landscape
    local cpad = math.floor(spec.card_pad * S)
    local avail = W - cpad * 2
    local gap = math.floor(spec.gap * S)
    local rows = {}
    local function push(x) rows[#rows + 1] = x end

    push(self:buildHeader(ctx, cpad))
    push(mkPad(W, math.floor(spec.head_gap * S)))

    self.clock_widget = nil
    push(self:buildZone(ctx, "landscape", "A", W, avail, math.floor(spec.A * S)))

    push(mkPad(W, gap))

    -- 下半区：左 B / 右 C 两张卡，中间只留纸底的空隙（原来是一条竖黑线，
    -- 在两张白卡之间等于多画了一道边）。
    -- 两张卡加起来必须等于版心宽 W（A 卡也是 W），右沿才对得齐
    local bw, cw = self:lowerWidths(W, S)
    local lower_h = math.floor(spec.lower * S)

    local left = self:buildZone(ctx, "landscape", "B", bw, bw - cpad * 2, lower_h)
    local right = self:buildZone(ctx, "landscape", "C", cw, cw - cpad * 2, lower_h)
    push(HorizontalGroup:new{
        align = "top",
        left,
        mkPad(gap, 1),
        right,
    })

    push(mkPad(W, math.floor(spec.foot_gap * S)))
    push(self:buildHintRow(ctx, avail, cpad, 17))
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
    -- 大钟换衬线：四款字体的数字全是等宽（实测 57/56/56/50），所以逐分钟改字
    -- 不会抖动，可以放心用衬线。中文日期留在黑体（衬线没有汉字）。
    self.clock_widget = self:makeNum(ctx, self.clock_text,
        math.floor((land and 82 or 112) * k))
    local clock_block = VerticalGroup:new{
        align = "left",
        self.clock_widget,
        mkPad(1, math.floor(8 * S * k)),
        self:makeText(ctx, I18n.dateLine(ctx.now, not land),
            math.floor((land and 24 or 26) * k), { color = INK2 }),
    }
    local min_gap = math.floor(16 * S)
    local weather = self:buildWeatherBlock(ctx,
        math.floor((land and 78 or 76) * k),
        math.floor((land and 62 or 54) * k),
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

    -- 块头左对齐、17du / 0x66，与「今日行动」「待办」那些卡的块头对齐成一条线。
    -- 原来是居中，在一列全是左对齐的卡里显得没站住。
    push(HorizontalGroup:new{
        align = "left",
        self:makeText(ctx, T("农历"), math.floor(17 * k), { color = INK2 }),
    })
    push(mkPad(w, math.floor(6 * S * k)))

    local big_txt = I18n.lunarMonthDay(ctx.lunar)
    if I18n.lang() == "en" then
        -- 英文这两段都长（Month 10, Day 4 / Year of the Horse），并排要 1200 px，
        -- 竖屏 920 放不下，横屏 B 区 630 更放不下。改成三段居中竖排：
        -- 宽度只取决于最长的一行，且总高比原来两行 side 还略低。
        -- 横屏中栏只有 630 宽（竖屏 920），54 号的 "Month 10, Day 4" 要 800，
        -- 靠 max_width 会折成两行（"Month 10, Day" / "4"），很难看。
        -- 所以先按宽度逐档降字号，降到 30 号仍放不下才退回折行兜底。
        local big_px = math.floor(54 * k)
        local floor_px = math.max(28, math.floor(30 * k))
        local big = self:makeText(ctx, big_txt, big_px)
        while big_px > floor_px and big:getSize().w > w do
            big_px = big_px - 2
            big = self:makeText(ctx, big_txt, big_px)
        end
        if big:getSize().w > w then
            big = self:makeText(ctx, big_txt, big_px, { max_width = w })
        end
        -- 左对齐，不居中：这条卡里块头「农历」是贴左的，中文版也是贴左的；
        -- 只有英文版把这两行居中，结果干支那行被推右一百多像素，看着像缩进了一级。
        push(VerticalGroup:new{
            align = "left",
            big,
        })
        push(mkPad(w, math.floor(2 * S * k)))
        push(HorizontalGroup:new{
            align = "left",
            self:makeText(ctx, string.format("%s · %s",
                I18n.lunarGanzhi(ctx.lunar), I18n.zodiacYear(Lunar.zodiac(ctx.lunar))),
                math.floor(20 * k), { gray = true, max_width = w }),
        })
    else
        local side = VerticalGroup:new{
            align = "left",
            self:makeText(ctx, I18n.lunarGanzhi(ctx.lunar), math.floor(30 * k)),
            mkPad(1, math.floor(4 * S * k)),
            self:makeText(ctx, I18n.zodiacYear(Lunar.zodiac(ctx.lunar)),
                math.floor(20 * k), { gray = true }),
        }
        local big = self:makeText(ctx, big_txt, math.floor(54 * k))
        local fill = math.max(math.floor(20 * S), w - big:getSize().w - side:getSize().w)
        push(HorizontalGroup:new{
            align = "center",
            big,
            mkPad(fill, 1),
            side,
        })
    end
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
            dimen = Geom:new{ w = w, h = math.max(10, math.floor(12 * S * k)) },
            ratio = ratio,
            border = math.max(1, math.floor(1.4 * S)),
        },
    })
    push(mkPad(w, math.floor(8 * S * k)))

    local cur = I18n.term(ctx.cur_term.name)
    local nxt = ctx.next_term and I18n.term(ctx.next_term.name) or ""
    local left_label = self:makeText(ctx, cur, math.floor(17 * k), { gray = true })
    local right_label = self:makeText(ctx, nxt, math.floor(17 * k), { gray = true })
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
    -- AQI 刻度盘的指针按 300 封顶：国标 200 就到"重度污染"，
    -- 再往上的 300~500 在日常生活里几乎见不到，用它当满量程刻度才不挤。
    local aqi = tonumber(air.text) or 0
    return self:buildStatCells(ctx, w, {
        { T("湿度"), d.hum or "--", nil, "drop" },
        { T("风力"), d.wind or "--", d.wind_dir, "wind" },
        { "AQI", air.text, air.level, "gauge", { value = aqi, max = 300 } },
    }, h)
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
    -- 月历的宽度由格宽与列距决定，常常到不了盒宽（竖屏 B 区尤其明显：
    -- 行高把格宽压在两三百像素，右边就空出一大条）。卡是横的、内容是窄的，
    -- 又不居中就会变成"贴在左边的一张图"。这里把整块（含月份标题、图例）
    -- 用同一个盒子居中——标题本来就按块左沿对齐，跟着块一起走，不会散开。
    -- 盒子高度必须回**真实内容高**（不能夹到 h）：buildZone 靠它判断装不装得下，
    -- 夹成 h 就永远"刚好放下"，该降档时降不下去，图例会溢出到卡外。
    return mkBox(w, math.max(1, cal:getSize().h), cal, { align = "center" })
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
local function spreadRows(blocks, total_w, align)
    local used, n = 0, #blocks
    for _, b in ipairs(blocks) do used = used + b:getSize().w end
    local gap = (n > 1) and math.floor(math.max(0, total_w - used) / (n - 1)) or 0
    -- align = "top" 的时候三列按上沿看齐：英文的 "Waxing crescent" 会折成两行，
    -- 那一列比别列高一截，居中对齐会把它的列头往上顶，三个标签就不成一条线了。
    local items = { align = align or "center" }
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
    self.clock_widget = self:makeNum(ctx, self.clock_text,
        math.floor((land and 88 or 124) * k))
    -- v2.56：原来 align = "center"，日期在时钟的**盒子**里居中——
    -- 时钟盒子比字形宽，日期就被推到右下方一百多像素，看着像缩进了一级。
    -- 同一件事（时钟 + 日期）在「时钟与天气」里是左对齐的，这里必须一样：
    -- 同一信息不许有两种对齐方式。
    return VerticalGroup:new{
        align = "left",
        self.clock_widget,
        -- fixed：时钟与日期之间这段必须贴住。不标的话 Card 的"铺开"会把它拉成
        -- 上百像素，日期被推到卡片下沿，时钟孤零零悬在中间。
        mkPad(1, math.floor((land and 8 or 12) * S * k), true),
        self:makeText(ctx, I18n.dateLine(ctx.now, not land),
            math.floor((land and 24 or 26) * k), { color = INK2 }),
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
        self:makeNum(ctx, d.temp, math.floor((land and 70 or 86) * k),
            { max_width = side_max }),
        self:makeText(ctx, d.cond, math.floor((land and 26 or 28) * k),
            { max_width = side_max }),
        self:makeText(ctx, d.range or "--", math.floor((land and 19 or 21) * k),
            { color = INK2, max_width = side_max }),
        -- 竖屏 A 区又高又宽，只放三行会显得空；补一行体感（横屏放不下就不放）
        land and mkPad(1, 1) or self:makeText(ctx, d.feels or "", math.floor(17 * k),
            { color = INK2, max_width = side_max }),
    }
    -- 整块居中：A 区宽 920，图标 + 温度这一组只有 400 出头，靠左摆会在右边空出
    -- 一大片没有任何东西的白色，看着像内容没画完。居中之后左右留白相等，
    -- 那块白才读成"留白"。
    return CenterContainer:new{
        dimen = Geom:new{ w = w, h = math.floor(h) },
        HorizontalGroup:new{
            align = "center",
            ImageWidget:new{
                file = self:iconPath(d.icon), width = icon_w, height = icon_w,
                scale_factor = 0, alpha = true,
            },
            mkPad(math.floor(16 * S * k), 1),
            side,
        },
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
    local small_w = math.floor((land and 26 or 36) * S * k)

    -- 等宽单元格：按内容宽度平分留白的话，横屏 A 区 1276 宽会摊出
    -- 三个 200 px 的大豁口（今日块本来就比「明天/后天/周六」宽），看着像四块散落。
    -- 切成 w/n 的等宽格子，每块在自己格里居中，节奏就匀了。
    local n = math.max(1, #days)
    local cell_w = math.floor(w / n)

    -- 四列共用三条横线：标签 / 图标 / 数值。
    -- 之前今天列没有标签、图标又大一档，四个温度的高低各不相同 —— 极简的头一条
    -- 是对齐，第二条才是留白。这里把每一行都装进**等高定宽**的槽里：
    -- 标签贴同一条上沿，小图标在图标带里居中，数值在数值带里居中。
    -- 数值取居中而不是底对齐：真机的 TextWidget 不暴露 ascender，底对齐只能对齐
    -- 盒子底边，58 号与 24 号的下伸量差一截，反而差出十几像素；居中则是光学重心
    -- 对齐，大字小字同心，看着是一排数字而不是一排参差的数字。
    local label_px = 17
    local label_h = textLineH(label_px, S, k) + math.floor(3 * S * k)
    local num_slot = textLineH((land and 40 or 58), S, k)

    local function labelSlot(str)
        return mkBox(cell_w, label_h,
            self:makeText(ctx, str, math.floor(label_px * k), { gray = true }))
    end
    -- 图标槽统一按今天列的大图标算高：小图标在这格里居中，
    -- 四枚图标的光学中心因此横向连成一条线。
    local function iconSlot(file, px)
        return mkBox(cell_w, icon_w, ImageWidget:new{
            file = file, width = px, height = px, scale_factor = 0, alpha = true,
        })
    end
    local function numSlot(str, px)
        return mkBox(cell_w, num_slot, self:makeText(ctx, str, math.floor(px * k)))
    end

    -- 第 4、5 行（现象 / 高低温）也做成定高槽，四列共用：
    -- 原来只有今天列有这两行，明天起的列停在高低温上，于是「11 度」落在了
    -- 第二列「晴」那一行的同一水平线上 —— 一条横线穿过两个不相干的数据，
    -- 读者会以为它们是一回事。现在每列都是 标签/图标/高/现象/区间 五行。
    local cond_px = 20
    local range_px = 17
    local cond_h = textLineH(cond_px, S, k)
    local range_h = textLineH(range_px, S, k)

    local function condSlot(str)
        return mkBox(cell_w, cond_h, self:makeText(ctx, str, math.floor(cond_px * k),
            { gray = true, max_width = cell_w }))
    end
    local function rangeSlot(str)
        return mkBox(cell_w, range_h, self:makeText(ctx, str, math.floor(range_px * k),
            { gray = true, max_width = cell_w }))
    end

    local today = VerticalGroup:new{
        align = "center",
        labelSlot(I18n.dayLabel(1, days[1] and days[1].wd)),
        iconSlot(self:iconPath(d.icon), icon_w),
        numSlot(d.temp, (land and 40 or 58)),
        condSlot(d.cond),
        rangeSlot(d.range or "--"),
    }

    local blocks = { today }
    for i = 2, n do
        local day = days[i]
        local meta = QWeather.condition(day.code)
        blocks[#blocks + 1] = VerticalGroup:new{
            align = "center",
            labelSlot(I18n.dayLabel(i, day.wd)),
            iconSlot(self:iconPath(self:dayIcon(day)), small_w),
            numSlot(degText(day.tmax), (land and 20 or 24)),
            condSlot(T(meta[1])),
            rangeSlot((day.tmin and day.tmax)
                and string.format("%d° ~ %d°", math.floor(day.tmin + 0.5),
                    math.floor(day.tmax + 0.5))
                or "--"),
        }
    end
    -- 顶对齐：标签贴同一条上沿，今天列多出来的「现象 / 高低温」往下长，
    -- 不再靠垂直居中把整列往上顶。
    local cells = { align = "top" }
    for i, b in ipairs(blocks) do
        local cw = (i == n) and (w - cell_w * (n - 1)) or cell_w
        cells[#cells + 1] = mkBox(cw, 1, b, { auto_h = true })
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

--- 取封面 PNG 路径（拿不到就 nil）。整段 pcall：封面是「加分项」，
--- 任何一步（模块缺失 / 打不开书 / 缓存目录不可写）都不该影响文字版。
function Dashboard:coverFile(book_path, target_h)
    if not Cover or type(book_path) ~= "string" or book_path == "" then return nil end
    local ok, path = pcall(function()
        return Cover.resolve{ ui = self.ui, book_path = book_path, target_h = target_h }
    end)
    if ok and type(path) == "string" then return path end
    return nil
end

--- 在读卡：封面 + 书名 / 作者 / 进度 + 三栏统计（累计 / 速度 / 还要读）。
---
--- 三档版式按「盒子能放下什么」分，**不按横竖屏分**：
---   宽 ≥ 450du 且高 ≥ 200du   左封面 + 右文字（竖屏 B 区 972×471）
---   高 ≥ 200du（窄）          上封面 + 下三栏（横屏 C 区 673×474）
---   其余                      扁版，进度与三栏压在一起（竖屏 C 区 972×208）
--- 为什么不用 orient 判断：同一个区可以被配到任意版式里，按 orient 写死的话，
--- 用户把横屏切成竖版式就会渲染出错版；按实际盒子尺寸分档则天然跟着走。
--- 阈值用设计单位（除以 ctx.S），换分辨率时档位不会整体错位。
function Dashboard:compReading(ctx, w, h, k)
    local S = ctx.S
    local info = self:readingInfo()
    if not info then
        return CenterContainer:new{
            dimen = Geom:new{ w = w, h = math.floor(h) },
            self:makeText(ctx, T("暂无在读"), math.floor(26 * k), { gray = true }),
        }
    end

    -- 统计库取不到时 stats 为 nil，facts 会自己退化成「只有进度」那四项，
    -- 三栏照旧画（缺的显示破折号）——高度不跳，卡片不会因为一次查库失败就换形状。
    local stats = self:readingStats(info)
    local f = self:readingFacts(info, stats)
    f.last = self:readingLastText(info, stats)

    local du_w, du_h = w / S, h / S
    if du_h >= 200 and du_w >= 450 then
        return self:readingWide(ctx, w, h, k, info, f)
    elseif du_h >= 200 then
        return self:readingStack(ctx, w, h, k, info, f)
    end
    return self:readingFlat(ctx, w, h, k, info, f)
end

--- 封面块：有图就给图，没图给占位书脊。
--- 「留位」和「取到图」必须分开——取不到图时也占同样尺寸，
--- 否则同一个盒子会在「有封面 / 无封面」两种宽度之间跳，书名忽长忽短。
function Dashboard:readingCover(ctx, info, cw, ch, k)
    local file = self:coverFile(info.path, ch)
    if file then
        return ImageWidget:new{
            file = file, width = cw, height = ch, scale_factor = 0,
        }
    end
    return self:coverPlaceholder(ctx, info.title, cw, ch, k)
end

--- 进度条 + 「已读 412 / 1678 页（左） 24%（右）」。
--- 左右两端对齐靠手算留白：HorizontalGroup 没有 space-between，
--- 而用两个 1/1 容器分栏会把中间留白算成固定值，长书名时看着偏。
function Dashboard:readingProgress(ctx, tw, k, f, bar_h)
    local S = ctx.S
    local left = self:makeText(ctx, f.page_text or "", 17, { gray = true })
    local right = self:makeText(ctx, f.pct_text, 19, {})
    local lw, rw = left:getSize().w, right:getSize().w
    local pad = mkPad(math.max(0, math.floor(tw - lw - rw)), 1)
    return VerticalGroup:new{
        align = "left",
        ProgressBar:new{
            dimen = Geom:new{ w = math.floor(tw), h = math.max(8, bar_h) },
            ratio = f.pct,
            border = math.max(1, math.floor(2 * S)),
        },
        mkPad(1, math.floor(8 * S * k)),
        HorizontalGroup:new{ align = "center", left, pad, right },
    }
end

--- 三栏统计条。栏宽**固定等分**，这是硬要求：
--- 第一版用自适应宽度，第三栏被「9 小时 50 分」撑开，另外两栏跟着变形，
--- 横屏那版直接溢出到卡片外。固定栏宽 + 超长省略号才是稳的。
function Dashboard:readingStatRow(ctx, tw, k, f)
    local S = ctx.S
    -- 只画真有数的栏，不再画「—」占位。
    -- 最初三栏写死、缺值补破折号，结果统计样本不足时整排全是「—」——
    -- 比不显示更糟：读者看到三个破折号，只会觉得这卡坏了。
    local cells = {}
    if f.used then cells[#cells + 1] = { T("累计"), f.used } end
    if f.speed then cells[#cells + 1] = { T("平均速度"), f.speed } end
    if f.remain then cells[#cells + 1] = { T("还要读"), f.remain } end

    if #cells == 0 then
        -- 统计样本不足（读得少 / 统计插件才开）：整行不画。
        -- 试过塌缩成一行「还要读 · 还剩 N 页」，真机上它孤零零贴在左下角、
        -- 右边空出一大片，比三个破折号好但也不好看；而「已读 1460 / 1858 页」
        -- 本身已经隐含剩余页数，读者自己会减。少一行，卡片反而松快。
        -- 返回 nil 而不是空控件：横屏那档上面有一条分隔线，空控件会让线悬在半空。
        return nil
    end

    local gapx = math.floor(8 * S * k)
    local colw = math.floor((tw - gapx * (#cells - 1)) / #cells)
    local row = { align = "center" }
    for i, c in ipairs(cells) do
        if i > 1 then row[#row + 1] = mkPad(gapx, 1) end
        local col = VerticalGroup:new{
            align = "left",
            self:makeText(ctx, c[1], 14, { gray = true, max_width = colw, ellipsis = true }),
            mkPad(1, math.floor(7 * S * k)),
            self:makeText(ctx, c[2], 18, { max_width = colw, ellipsis = true }),
        }
        row[#row + 1] = Stack:new{
            dimen = Geom:new{ w = colw, h = col:getSize().h },
            align = "left",
            col,
        }
    end
    return HorizontalGroup:new(row)
end

--- 宽盒（竖屏 B）：左封面撑满盒高，右文字列。封面最宽只到盒宽 42%——
--- 再宽书名就只剩几个字，宁可封面小一点。
function Dashboard:readingWide(ctx, w, h, k, info, f)
    local S = ctx.S
    local function px(n) return math.floor(n * S * k) end
    local cover_h = math.floor(h)
    local cover_w = math.floor(cover_h * 2 / 3)
    local max_w = math.floor(w * 0.42)
    if cover_w > max_w then
        cover_w = max_w
        cover_h = math.floor(cover_w * 3 / 2)
    end
    local gap = px(13)
    local tw = math.max(px(120), w - cover_w - gap)

    local col = VerticalGroup:new{ align = "left" }
    if f.last then
        col[#col + 1] = self:makeText(ctx, T("在读") .. " · " .. f.last, 16,
            { gray = true, max_width = tw, ellipsis = true })
        col[#col + 1] = mkPad(1, px(3))
    else
        col[#col + 1] = self:makeText(ctx, T("在读"), 16, { gray = true })
        col[#col + 1] = mkPad(1, px(3))
    end
    -- 书名只画一行并带省略号——真机书名动辄二三十字，折行会把盒子顶破
    col[#col + 1] = self:makeText(ctx, info.title or "", 29, { max_width = tw, ellipsis = true })
    if info.authors then
        col[#col + 1] = mkPad(1, px(3))
        col[#col + 1] = self:makeText(ctx, T("作者") .. " " .. info.authors, 16,
            { gray = true, max_width = tw, ellipsis = true })
    end
    col[#col + 1] = mkPad(1, px(10))
    col[#col + 1] = self:readingProgress(ctx, tw, k, f, px(9))
    local stat = self:readingStatRow(ctx, tw, k, f)
    if stat then
        col[#col + 1] = mkPad(1, px(10))
        col[#col + 1] = Solid:new{
            dimen = Geom:new{ w = math.floor(tw), h = math.max(1, math.floor(S)) },
            color = RULE_SOFT,
        }
        col[#col + 1] = mkPad(1, px(9))
        col[#col + 1] = stat
    end
    if f.eta then
        col[#col + 1] = mkPad(1, px(11))
        col[#col + 1] = self:makeText(ctx, f.eta, 15, { gray = true, max_width = tw, ellipsis = true })
    end

    return HorizontalGroup:new{
        align = "center",
        self:readingCover(ctx, info, cover_w, cover_h, k),
        mkPad(gap, 1),
        col,
    }
end

--- 窄高盒（横屏 C）：上下两段。封面占 8 成高、三栏横跨整宽压在下面。
--- 一开始把三栏塞进封面右边，结果每栏只剩 190px，「9 小时 50 分」直接顶破；
--- 分两段之后每栏 220+ px，字也就不用缩。
function Dashboard:readingStack(ctx, w, h, k, info, f)
    local S = ctx.S
    local function px(n) return math.floor(n * S * k) end

    -- 先把下半部建出来量高度，再倒推封面能给多高。
    -- 反过来做（先按比例定封面）会在盒子偏矮时把三栏顶出卡片：
    -- h=478 那档实测差 1 px，桩件当场拦下来了。
    local stat = self:readingStatRow(ctx, w, k, f)
    local sep_h = math.max(1, math.floor(S))
    -- 没有统计行时，下半部就是 0：封面可以一直长到盒子底，
    -- 留出 px(10)+1+px(9) 的空档只会让卡片中间塌一块
    local lower_h = stat and (stat:getSize().h + px(10) + sep_h + px(9)) or 0
    local eta = nil
    if f.eta then
        eta = self:makeText(ctx, f.eta, 14, { gray = true, max_width = w, ellipsis = true })
        lower_h = lower_h + px(7) + eta:getSize().h
    end

    local avail = math.max(px(110), h - lower_h - 2)
    local cover_h = avail
    local cover_w = math.floor(cover_h * 2 / 3)
    local max_w = math.floor(w * 0.45)
    if cover_w > max_w then
        cover_w = max_w
        cover_h = math.min(avail, math.floor(cover_w * 3 / 2))
    end
    local gap = px(10)
    local tw = math.max(px(120), w - cover_w - gap)

    local meta = VerticalGroup:new{ align = "left" }
    if f.last then
        meta[#meta + 1] = self:makeText(ctx, T("在读") .. " · " .. f.last, 14,
            { gray = true, max_width = tw, ellipsis = true })
    else
        meta[#meta + 1] = self:makeText(ctx, T("在读"), 14, { gray = true })
    end
    meta[#meta + 1] = mkPad(1, px(6))
    meta[#meta + 1] = self:makeText(ctx, info.title or "", 22, { max_width = tw, ellipsis = true })
    if info.authors then
        meta[#meta + 1] = mkPad(1, px(5))
        meta[#meta + 1] = self:makeText(ctx, T("作者") .. " " .. info.authors, 15,
            { gray = true, max_width = tw, ellipsis = true })
    end
    meta[#meta + 1] = mkPad(1, px(14))
    meta[#meta + 1] = self:readingProgress(ctx, tw, k, f, px(8))

    local top = HorizontalGroup:new{
        align = "center",
        self:readingCover(ctx, info, cover_w, cover_h, k),
        mkPad(gap, 1),
        -- 文字在封面高度里垂直居中：顶对齐会让书名紧贴封面下沿，
        -- 中间空出一条，看着像漏画了东西
        CenterContainer:new{
            dimen = Geom:new{ w = tw, h = cover_h },
            meta,
        },
    }

    -- 三栏与 eta 都在上面量过高度了，这里直接复用同一批控件：
    -- 重建一遍不仅白跑，还会因为取整差异让「量到的高度」和「实际画的高度」对不上。
    local body = VerticalGroup:new{
        align = "left",
        top,
    }
    if stat then
        body[#body + 1] = mkPad(1, px(10))
        body[#body + 1] = Solid:new{
            dimen = Geom:new{ w = math.floor(w), h = sep_h },
            color = RULE_SOFT,
        }
        body[#body + 1] = mkPad(1, px(9))
        body[#body + 1] = stat
    end
    if eta then
        body[#body + 1] = mkPad(1, px(7))
        body[#body + 1] = eta
    end
    return body
end

--- 扁盒（竖屏 C，高 ~116du）：卡片只有 208px 高，一行都省不得。
--- 封面降到盒高（143×214 那个尺寸在 PW3 上已经是极限，再小就看不出是本书了），
--- 进度条与页数挤在同一行，三栏压在最下面。
function Dashboard:readingFlat(ctx, w, h, k, info, f)
    local S = ctx.S
    local function px(n) return math.floor(n * S * k) end
    local gap = px(10)
    local cover_h = math.floor(h)
    local cover_w = math.floor(cover_h * 2 / 3)
    local cover_shown = cover_h >= px(110) and cover_w >= px(70)
    if not cover_shown then
        cover_h, cover_w = 0, 0
    end
    local tw = math.max(px(120), w - (cover_shown and (cover_w + gap) or 0))

    local col = VerticalGroup:new{ align = "left" }
    if f.last then
        col[#col + 1] = self:makeText(ctx, T("在读") .. " · " .. f.last, 13,
            { gray = true, max_width = tw, ellipsis = true })
    else
        col[#col + 1] = self:makeText(ctx, T("在读"), 13, { gray = true })
    end
    col[#col + 1] = mkPad(1, px(3))
    col[#col + 1] = self:makeText(ctx, info.title or "", 21, { max_width = tw, ellipsis = true })
    col[#col + 1] = mkPad(1, px(8))

    -- 进度条与「已读 / 页数 / 百分比」同行：竖屏 C 区一共 208px，
    -- 分两行就要从三栏里挪走 40px，三栏会贴到卡片下沿
    local bar_w = math.floor(tw * 0.34)
    local pg = VerticalGroup:new{
        align = "left",
        HorizontalGroup:new{
            align = "center",
            ProgressBar:new{
                dimen = Geom:new{ w = bar_w, h = math.max(7, px(8)) },
                ratio = f.pct,
                border = math.max(1, math.floor(2 * S)),
            },
            mkPad(px(8), 1),
            self:makeText(ctx, f.page_text or "", 14, { gray = true }),
            mkPad(px(8), 1),
            self:makeText(ctx, f.pct_text, 15, {}),
        },
    }
    col[#col + 1] = pg
    local stat = self:readingStatRow(ctx, tw, k, f)
    if stat then
        col[#col + 1] = mkPad(1, px(8))
        col[#col + 1] = stat
    end

    local inner
    if cover_shown then
        inner = HorizontalGroup:new{
            align = "center",
            self:readingCover(ctx, info, cover_w, cover_h, k),
            mkPad(gap, 1),
            col,
        }
    else
        inner = col
    end

    -- 内容比盒子矮时垂直居中。竖屏 C 区在统计不足时会少掉三栏，
    -- 内容矮了 60 多 px，贴顶就让卡片下半截空着，看着像没渲染完。
    local ih = inner:getSize().h
    if ih < h - 4 then
        return VerticalGroup:new{
            align = "left",
            mkPad(1, math.floor((h - ih) / 2)),
            inner,
        }
    end
    return inner
end

--- 取不到封面时的占位书脊：同尺寸的空心框 + 书名首字。
--- 为什么不直接不画：封面位一旦消失，整张卡的宽度会变，书名长度跟着跳；
--- 而且 e-ink 上「一块空白」比「一个框」更像渲染失败。框里放首字，
--- 至少能看出这是哪本书的封面位。
function Dashboard:coverPlaceholder(ctx, title, w, h, k)
    local S = ctx.S
    -- 取第一个字符（UTF-8 安全）：中文一个字三字节，英文一个字节
    local first = tostring(title or ""):match("^([%z\1-\127\194-\244][\128-\191]*)") or "?"
    local label = self:makeText(ctx, first, math.floor(44 * k), { gray = true })
    return Stack:new{
        dimen = Geom:new{ w = w, h = h },
        border = math.max(1, math.floor(2 * S)),
        CenterContainer:new{
            dimen = Geom:new{ w = w, h = h },
            label,
        },
    }
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
    -- v2.53：阈值从 250 降到 190 —— C 卡扣掉卡片内边距只剩 ~214px，
    -- 按老阈值「白昼 / 月升月落」两行永远不显示，卡里空一大片。
    local tall = h >= math.floor(110 * S)
    -- 三列各占 (w - 2×列距)/3：窄盒里大字再按 36 设计单位会被挤破，按盒宽退到 26
    local big_px = (w < math.floor(300 * S)) and 26 or (tall and 36 or 32)
    local col_gap = math.floor(18 * S * k)
    local col_w = math.max(math.floor(60 * S), math.floor((w - col_gap * 2) / 3))

    -- 列宽是硬边界：正文长度随语言变（英文 "Waxing crescent" 是中文「盈凸月」的三倍多），
    -- 先用正常字号、装不进列宽就逐档退，退到底还宽才折行。
    local function column(label, big, serif, icon_name)
        local str = big or "--"
        local px = big_px
        for _, cand in ipairs({ big_px, big_px - 6, big_px - 12 }) do
            px = cand
            if self:makeText(ctx, str, math.floor(cand * k)):getSize().w <= col_w then break end
        end
        -- 时间是纯数字，换衬线；月相是中文，留在黑体（衬线字体没有汉字）
        local val
        if serif then
            val = self:makeNum(ctx, str, math.floor(px * k), { max_width = col_w })
        else
            val = self:makeText(ctx, str, math.floor(px * k), { max_width = col_w })
        end
        -- 列头带一枚小图标：日出日落共用「地平线 + 半日」，月相用月牙。
        -- 图标在这里只当视觉锚点（26px 上下认不出细节），真正的读数还是靠文字，
        -- 所以不把它做大 —— 抢了时间数字的视觉主导就不划算了。
        local head = self:makeText(ctx, label, math.floor(17 * k), { color = INK2 })
        if icon_name then
            local ipx = math.floor(18 * k * S)
            head = HorizontalGroup:new{
                align = "center",
                self:icon(icon_name, ipx),
                mkPad(math.floor(5 * S * k), 1),
                head,
            }
        end
        return VerticalGroup:new{
            align = "center",
            head,
            mkPad(1, math.floor(6 * S * k)),
            val,
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
        column(T("日出"), d.sunrise, true, "horizon"),
        column(T("日落"), d.sunset, true, "horizon"),
        column(T("月相"), moon.label, false, "moon"),
    }, w, "top")
    if not tall then return cols end
    -- 高度够时补两行注释：白昼时长 / 月升月落。都给 max_width，长文案折行不收边。
    -- 用 15 而不是 17：17 是「标签」那一档，注释与列头同号就分不出主次了。
    -- 整个产品只留四档字号——15 脚注 / 17 标签 / 26 数值 / A 区大字，
    -- 档位一多，眼睛就得先分辨"这行有多重要"才敢读。
    local note_px = 15
    local rows = {
        align = "center",
        cols,
        mkPad(1, math.floor(11 * S * k)),
        self:makeText(ctx, daylen_text or moon_note, math.floor(note_px * k),
            { color = INK2, max_width = w }),
    }
    if daylen_text then
        rows[#rows + 1] = mkPad(1, math.floor(5 * S * k))
        rows[#rows + 1] = self:makeText(ctx, moon_note, math.floor(note_px * k),
            { color = INK2, max_width = w })
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
    -- 单位上提到块头（只写一次）：六项各自跟一个 µg/m³，等于把每格撑宽 60px，
    -- 而六个单位说的是同一件事。CO 是 mg/m³（量纲差 1000 倍），它的单位仍然跟着数值走。
    local head_full = VerticalGroup:new{
        align = "left",
        HorizontalGroup:new{
            align = "center",
            -- 与「三格状态」里的 AQI 同一枚刻度盘（指针按当前值转）：
            -- 同一套图标语言，换区换组件也认得出这是空气指数
            self:icon("gauge", math.floor(20 * S),
                { color = INK2, value = tonumber(air.text) or 0, max = 300 }),
            mkPad(math.floor(7 * S), 1),
            self:makeText(ctx, "AQI", math.floor(17 * k), { color = INK2 }),
            mkPad(math.floor(8 * S), 1),
            self:makeText(ctx, "µg/m³", math.floor(15 * k), { color = INK2 }),
        },
        mkPad(1, math.floor(4 * S * k)),
        self:makeNum(ctx, air.text or "--", math.floor(58 * k)),
        mkPad(1, math.floor(2 * S * k)),
        self:makeText(ctx, sub, math.floor(19 * k), { color = INK2, max_width = w }),
        mkPad(1, math.floor(12 * S * k)),
    }
    local head_bare = VerticalGroup:new{
        align = "left",
        self:makeNum(ctx, air.text or "--", math.floor(58 * k)),
        mkPad(1, math.floor(2 * S * k)),
        self:makeText(ctx, sub, math.floor(19 * k), { color = INK2, max_width = w }),
        mkPad(1, math.floor(12 * S * k)),
    }
    local rows = { align = "left" }

    -- 六项按 POLLUTANT_ORDER 轮询：缺哪项就补一格 "--"，格子不错位。
    -- 每格拆成「标签（0x66 / 17du）+ 数值（26du）」两段：标签定宽、数值在格内右对齐，
    -- 六项的数字才会纵向成一条竖线。原来是一整串「PM2.5 42 µg/m³」，
    -- 位数一变（4 → 112）后面的文字就跟着漂。
    local order = I18n.POLLUTANT_ORDER
    local cols_data = {}
    local label_w, val_w = 0, 0
    for _, code in ipairs(order) do
        local p = by_code[code]
        local num = "--"
        local ratio = 0
        if p and p.value then
            -- CO 的量纲是 mg/m³，比其余五项大 1000 倍。这里统一换算成 µg/m³，
            -- 六个数字才能共用一个单位（单位写在块头），也不必为了 "0.8 mg/m³"
            -- 这一格把整列拉宽 —— 那一格的宽度会传染给另外五格。
            local v = (p.unit == "mg/m³") and (p.value * 1000) or p.value
            num = tostring(math.floor(v + 0.5))
            ratio = math.min(1, v / (POLLUTANT_LIMIT[code] or 200))
        end
        local lab = self:makeText(ctx, I18n.pollutant(code), math.floor(17 * k), { color = INK2 })
        local val = self:makeText(ctx, num, math.floor(26 * k))
        label_w = math.max(label_w, lab:getSize().w)
        val_w = math.max(val_w, val:getSize().w)
        cols_data[#cols_data + 1] = { lab = lab, val = val, ratio = ratio }
    end

    -- 列数按「一格实际需要多宽」选，不能写死：竖屏 920 三列正好，
    -- 横屏 C 区 650 宽三列会把最后两格顶出屏幕（实测溢出 95px）。
    local gap_in = math.floor(8 * S * k)
    local cell_need = label_w + gap_in + val_w
    local col_gap_min = math.floor(18 * S * k)
    local per_row = 1
    for _, cand in ipairs({ 3, 2 }) do
        if cell_need * cand + col_gap_min * (cand - 1) <= w then per_row = cand; break end
    end
    -- 列距吃满剩余宽度：格子本身只要「标签 + 数值」那么宽，
    -- 多出来的空间全部均分成列距。绝不吃进格内——格内留白一大，
    -- 标签和它的数字会被拉开成两段不相干的东西（预览图上一眼能看到）。
    local col_gap = 0
    if per_row > 1 then
        col_gap = math.floor(math.max(col_gap_min, (w - cell_need * per_row) / (per_row - 1)))
    end

    -- 每格从「标签 + 数值」变成「标签 + 数值 / 比例条」：
    -- 条长 = 占国标限值的比例。六个数字并排时，光看数不知道谁离超标更近，
    -- 加一条同量程的横条就有了绝对参照。
    local bar_h = math.max(3, math.floor(4 * S * k))
    local bar_gap = math.floor(5 * S * k)
    local row_h = textLineH(26, S, k)
    for i = 1, #cols_data, per_row do
        local line = { align = "left" }
        for j = 0, per_row - 1 do
            local d = cols_data[i + j]
            if d then
                if j > 0 then line[#line + 1] = mkPad(col_gap, 1) end
                line[#line + 1] = VerticalGroup:new{
                    align = "left",
                    HorizontalGroup:new{
                        align = "center",
                        mkBox(label_w, row_h, d.lab, { align = "left" }),
                        mkPad(gap_in, 1),
                        mkBox(val_w, row_h, d.val, { align = "right" }),
                    },
                    mkPad(1, bar_gap),
                    Meter:new{
                        dimen = Geom:new{ w = cell_need, h = bar_h },
                        ratio = d.ratio,
                        track = RULE_SOFT,
                        color = INK1,
                    },
                }
            end
        end
        rows[#rows + 1] = HorizontalGroup:new(line)
        if i + per_row <= #cols_data then
            rows[#rows + 1] = mkPad(1, math.floor(13 * S * k))
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
    local S = ctx.S
    local net = self:netInfo()
    -- 网络这格原来在 38du 的大字位上写「未连接」三个汉字：占掉半个格宽，
    -- 而且"信号弱"和"没开 WiFi"看起来一模一样。改成状态图标 ——
    --   已连接 = 三段弧 / 未连接 = 三段弧 + 斜杠。
    -- v2.59：未开启又改回汉字。它和"未连接"差的就是少亮两段弧，单看一枚
    -- 图标分不出是哪个；而"没开 WiFi"是最需要一个动作的状态，宁可让它占宽。
    local wifi
    local wpx = math.floor(50 * S)
    if net.wifi_on == true and net.connected then
        wifi = self:icon("wifi", wpx, { color = COLOR_BLACK, black = true })
    elseif net.wifi_on == true then
        wifi = self:icon("wifi", wpx, { color = INK2, slash = true })
    elseif net.wifi_on == false then
        wifi = self:makeText(ctx, T("未开启"), 24, { color = INK2 })
    else
        -- 取不到 NetworkMgr 的状态：不猜，留一个占位
        wifi = self:makeText(ctx, "--", 24, { color = INK2 })
    end

    -- 电量：壳体本身就在编码百分比（填充比例），数字只做精确读数。
    -- 原来把电池塞进标签行 34px 的图标位，细节全糊在一起，只剩一个方框 ——
    -- 那是"加了个图标"，不是"图形化"。
    local cap = net.cap
    -- 壳体尺寸收一档（64×21 → 52×16）：原来的电池是一大块实心黑，
    -- 比旁边的 58% 还重，一张卡里最响的成了"配角"。图形该做定语，数字才是主语。
    local battery = HorizontalGroup:new{
        align = "center",
        BatteryGauge:new{
            dimen = Geom:new{ w = math.floor(52 * S), h = math.floor(16 * S) },
            border = math.max(1, math.floor(1.4 * S)),
            ratio = (cap or 0) / 100,
            charging = net.charging,
            color = COLOR_BLACK,
        },
        mkPad(math.floor(14 * S), 1),
        self:makeNum(ctx, cap and string.format("%d%%", cap) or "--", 28),
    }
    local items = {
        { T("电量"), battery, net.charging and T("充电中") or nil },
        { T("网络"), wifi, nil },
    }
    return self:buildStatCells(ctx, w, items, h)
end

-- ---------------------------------------------------------------- 倒数日 / 待办
-- 这两个组件的共同点：条数不确定，画几行由盒高决定。做法统一为
-- 「先建头部和大字位 → 量出实际高度 → 把剩余高度换算成行数」，
-- 而不是「按 k 档预估能放几行」：字体度量在真机与桩件之间差 1%，
-- 预估多一行就会顶出盒子（v2.45 的周预报就是这么错的）。

--- 标题行：左标题，右侧可选小标签（置顶 / 2/5）。整行铺满盒宽。
--- 标题 17du（30px，中文可读下限）用 0x66 而不是 0x88：它是块头，要压得住内容，
--- 0x88 在 30px 上只是"勉强能看"。
--- 块头右侧的待办进度。≤6 项给分段条，更多项退回「3/12」——
--- 十几条待办画十几段，每段只有两三个像素，反而读不出是几比几。
function Dashboard:todoProgress(ctx, k, done, total)
    if not total or total <= 0 then return nil end
    if total > 6 then return string.format("%d/%d", done or 0, total) end
    local S = ctx.S
    local gap = math.floor(5 * S * k)
    -- 段宽 12du：9du 在真机上是 9px，空心段只剩一圈 1px 细边，缩到整页看像三颗灰点。
    local seg = math.floor(12 * S * k)
    return TickStrip:new{
        dimen = Geom:new{ w = total * seg + (total - 1) * gap,
            h = math.max(9, math.floor(15 * S * k)) },
        n = total,
        done = done or 0,
        seg = seg,
        gap = gap,
        line_w = math.max(1, math.floor(1.5 * S)),
        color = INK1,
        -- 空心段用 0x88 描边：0xBB 太浅，和卡里的细分隔线混成一片，
        -- 分不出「还没做的格子」和「一条装饰线」。
        edge = INK3,
    }
end

function Dashboard:compHeadRow(ctx, w, k, left_text, right_text)
    local left = self:makeText(ctx, left_text, math.floor(17 * k), { color = INK2 })
    local row = { align = "center", left }
    if right_text then
        -- right_text 既可以是文案（"3/12"），也可以是控件（分段进度条）：
        -- 有形状的量画出来比写出来快，不占宽的才留文字。
        local right = type(right_text) == "string"
            and self:makeText(ctx, right_text, math.floor(15 * k), { color = INK2 })
            or right_text
        row[#row + 1] = mkPad(math.max(0, w - left:getSize().w - right:getSize().w), 1)
        row[#row + 1] = right
    end
    return HorizontalGroup:new(row)
end

--- 一行「名称 …… 右侧倒数值」。名称用定宽盒子左对齐，右侧数值才贴得齐右边缘；
--- 直接给名称 max_width 不行——短名字会让整行变窄，右侧数值参差不齐。
function Dashboard:countdownRow(ctx, w, k, name, right_text)
    local px = 22
    local right = self:makeText(ctx, right_text, math.floor(px * k), { gray = true })
    local gap = math.floor(16 * ctx.S * k)
    local name_w = math.max(math.floor(80 * ctx.S), w - right:getSize().w - gap)
    local name_box = mkBox(name_w, textLineH(px, ctx.S, k), self:makeText(ctx, name,
        math.floor(px * k), { ellipsis = true, max_width = name_w }), { align = "left" })
    return HorizontalGroup:new{
        align = "center",
        name_box,
        mkPad(gap, 1),
        right,
    }
end

--- 倒数日：大字位显示置顶（或最近一条）事件，下面最多三条。
function Dashboard:compCountdown(ctx, w, h, k)
    local S = ctx.S
    local v = Agenda.eventsView(ctx.now)
    local head = self:compHeadRow(ctx, w, k, T("倒数日"), v.focus_pinned and T("置顶") or nil)

    if v.total == 0 then
        return CenterContainer:new{
            dimen = Geom:new{ w = w, h = math.floor(h) },
            VerticalGroup:new{
                align = "center",
                self:makeText(ctx, T("暂无倒数日"), math.floor(20 * k), { gray = true }),
                mkPad(1, math.floor(8 * S * k)),
                self:makeText(ctx, TL("菜单 → 内容 → 倒数日 → 添加", "Menu → Content → Countdown → Add"),
                    math.floor(15 * k), { gray = true }),
            },
        }
    end

    local f = v.focus
    local big_px = 44
    local block = VerticalGroup:new{ align = "left" }
    if f.days == 0 then
        -- 今天不用「还有 0 天」，直接说「就是今天」
        block[#block + 1] = self:makeText(ctx, T("就是今天"), math.floor(big_px * 0.78 * k))
    else
        local line = { align = "center" }
        local pre = I18n.preDays(f.days)
        if pre then
            line[#line + 1] = self:makeText(ctx, pre, math.floor(20 * k), { gray = true })
            line[#line + 1] = mkPad(math.floor(10 * S * k), 1)
        end
        line[#line + 1] = self:makeNum(ctx, tostring(math.abs(f.days)), math.floor(big_px * k))
        line[#line + 1] = mkPad(math.floor(6 * S * k), 1)
        line[#line + 1] = self:makeText(ctx, I18n.daysUnit(f.days), math.floor(17 * k),
            { gray = true })
        block[#block + 1] = HorizontalGroup:new(line)
    end
    block[#block + 1] = self:makeText(ctx, f.name, math.floor(26 * k),
        { ellipsis = true, max_width = w })
    block[#block + 1] = self:makeText(ctx, f.date, math.floor(15 * k), { gray = true })

    local gap1 = math.floor(10 * S * k)
    local gap2 = math.floor(8 * S * k)
    local avail = h - head:getSize().h - gap1 - block:getSize().h - gap2
    local row_px = 22
    local row_h = textLineH(row_px, S, k) + math.floor(5 * S * k)
    local n = math.max(0, math.min(#v.list, math.floor(avail / row_h)))

    if n == 0 then
        -- 盒子只够画大字位（竖屏 C 区最小档就是这种）
        return VerticalGroup:new{ align = "left", head, mkPad(1, gap1), block }
    end
    local rows = { align = "left", head, mkPad(1, gap1), block, mkPad(1, gap2) }
    for i = 1, n do
        local e = v.list[i]
        if i > 1 then rows[#rows + 1] = mkPad(1, math.floor(5 * S * k)) end
        rows[#rows + 1] = self:countdownRow(ctx, w, k, e.name, I18n.relDays(e.days))
    end
    return VerticalGroup:new(rows)
end

--- 待办：只显示今天，行数按盒高定。
function Dashboard:compTodo(ctx, w, h, k)
    local S = ctx.S
    local v = Agenda.todosView(ctx.now)
    local counter = self:todoProgress(ctx, k, v.done_today, v.total_today)
    local head = self:compHeadRow(ctx, w, k, T("待办"), counter)

    if v.total_today == 0 then
        local sub
        if v.pending_future > 0 then
            -- 「今日无待办 · 未来 3 项」：让人知道不是数据丢了，只是今天没事
            sub = string.format("%s · %s %d %s", T("今日无待办"), T("未来"),
                v.pending_future, I18n.items(v.pending_future))
        else
            sub = TL("菜单 → 内容 → 待办事项 → 添加", "Menu → Content → To-dos → Add")
        end
        return CenterContainer:new{
            dimen = Geom:new{ w = w, h = math.floor(h) },
            VerticalGroup:new{
                align = "center",
                self:makeText(ctx, T("今日无待办"), math.floor(20 * k), { color = INK2 }),
                mkPad(1, math.floor(8 * S * k)),
                self:makeText(ctx, sub, math.floor(15 * k), { color = INK2, max_width = w }),
            },
        }
    end

    local gap1 = math.floor(8 * S * k)
    local row_px = 22
    local box_px = math.floor(18 * S * k)
    local line_h = math.max(textLineH(row_px, S, k), box_px)
    local row_gap = math.floor(6 * S * k)
    local row_h = line_h + row_gap
    local cap = math.max(0, math.floor((h - head:getSize().h - gap1) / row_h))
    local n = math.min(#v.today, cap)
    local rows = { align = "left", head, mkPad(1, gap1, true) }
    local gaps = {}
    for i = 1, n do
        if i > 1 then
            local g = mkPad(1, row_gap)
            gaps[#gaps + 1] = g
            rows[#rows + 1] = g
        end
        rows[#rows + 1] = self:todoRow(ctx, w, k, v.today[i], row_px, box_px)
    end

    -- 还有空位就补一行「未来 N 项」，不占行数预算时才有
    local tail_pad
    if n == #v.today and v.pending_future > 0 then
        local foot_h = textLineH(16, S, k)
        local used = head:getSize().h + gap1 + n * row_h
        if used + foot_h + math.floor(6 * S * k) <= h then
            rows[#rows + 1] = mkPad(1, math.floor(6 * S * k), true)
            tail_pad = rows[#rows]
            rows[#rows + 1] = self:makeText(ctx,
                string.format("%s %d %s", T("未来"), v.pending_future, I18n.items(v.pending_future)),
                math.floor(15 * k), { color = INK2 })
        end
    end
    return spreadToBottom(rows, gaps, tail_pad, h)
end

--- 一行待办：自绘勾选框 + 文本。
--- 勾选框不用 `[ ]` / `[x]`：方括号笔画细碎、基线也不对，在一屏只有三四行的
--- B 区里特别扎眼。自绘方框能控制线宽、间距和勾的两笔，还能和文字块垂直居中。
function Dashboard:todoRow(ctx, w, k, it, row_px, box_px)
    local S = ctx.S
    local gap = math.floor(13 * S)
    local box = CheckBox:new{
        dimen = Geom:new{ w = box_px, h = box_px },
        done = it.done,
        line_w = math.max(1, math.floor(1.4 * S)),
        color = it.done and INK2 or COLOR_BLACK,
    }
    local text_w = math.max(math.floor(40 * S), w - box_px - gap)
    local txt = self:makeText(ctx, it.text, math.floor(row_px * k), {
        color = it.done and INK2 or COLOR_BLACK,
        ellipsis = true,
        max_width = text_w,
    })
    return HorizontalGroup:new{
        align = "center",
        box,
        mkPad(gap, 1),
        txt,
    }
end

--- 今日行动（v2.53 默认 B 区）：今日打卡清单为主体，末尾带一条倒数日。
--- 与「待办」组件的区别：字号更大（26 vs 22）、行距更松（它是版面主体，
--- 不是清单附录），并且把最近一条倒数日当脚注挂在末尾——
--- 「今天做什么」和「还剩几天」本来就是同一个问题。
function Dashboard:compTodayActions(ctx, w, h, k)
    local S = ctx.S
    local v = Agenda.todosView(ctx.now)
    local counter = self:todoProgress(ctx, k, v.done_today, v.total_today)
    local head = self:compHeadRow(ctx, w, k, T("今日行动"), counter)

    if v.total_today == 0 then
        local sub = v.pending_future > 0
            and string.format("%s · %s %d %s", T("今日无待办"), T("未来"),
                v.pending_future, I18n.items(v.pending_future))
            or TL("菜单 → 内容 → 待办事项 → 添加", "Menu → Content → To-dos → Add")
        return CenterContainer:new{
            dimen = Geom:new{ w = w, h = math.floor(h) },
            VerticalGroup:new{
                align = "center",
                self:makeText(ctx, T("今日无待办"), math.floor(24 * k), { color = INK2 }),
                mkPad(1, math.floor(9 * S * k)),
                self:makeText(ctx, sub, math.floor(15 * k), { color = INK2, max_width = w }),
            },
        }
    end

    local gap1 = math.floor(11 * S * k)
    local row_px = 26
    local box_px = math.floor(19 * S * k)
    local line_h = math.max(textLineH(row_px, S, k), box_px)
    local row_gap = math.floor(9 * S * k)
    local row_h = line_h + row_gap

    -- 脚注优先占一行：它是「今天之外还有几天」的唯一线索，被列表挤掉就白放了
    local ev = Agenda.eventsView(ctx.now)
    local foot_text
    if ev.focus then
        foot_text = string.format("%s · %s", ev.focus.name, I18n.relDays(ev.focus.days))
    end
    local foot_block = foot_text and (textLineH(15, S, k) + math.floor(13 * S * k)) or 0

    local avail = h - head:getSize().h - gap1 - foot_block
    local cap = math.max(0, math.floor(avail / row_h))
    local n = math.min(#v.today, cap)

    local rows = { align = "left", head, mkPad(1, gap1, true) }
    local gaps = {}
    for i = 1, n do
        if i > 1 then
            local g = mkPad(1, row_gap)
            gaps[#gaps + 1] = g
            rows[#rows + 1] = g
        end
        rows[#rows + 1] = self:todoRow(ctx, w, k, v.today[i], row_px, box_px)
    end

    -- 尾部一行：还有没排上的条目就说条数，否则说倒数日（两者都有时优先条数）
    local rest = #v.today - n
    local tail
    if rest > 0 then
        tail = string.format("%s %d %s", T("另有"), rest, I18n.items(rest))
    else
        tail = foot_text
    end
    local tail_pad
    if tail then
        rows[#rows + 1] = mkPad(1, 13 * S * k, true)  -- 占位，下面按余量重算
        tail_pad = rows[#rows]
        rows[#rows + 1] = self:makeText(ctx, tail, math.floor(15 * k),
            { color = INK2, max_width = w })
    end

    -- 三条横线：块头贴卡顶、条目在中间摊开、脚注贴卡底（见 spreadToBottom）。
    return spreadToBottom(rows, gaps, tail_pad, h)
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
        mt(T("农历"), 17, { color = INK2 }),
        mkPad(1, math.floor(3 * S)),
        mt(I18n.lunarMonthDay(ctx.lunar), 32),
        mkPad(1, math.floor(5 * S)),
        mt(string.format("%s · %s", I18n.lunarGanzhi(ctx.lunar),
            I18n.zodiacYear(Lunar.zodiac(ctx.lunar))), 19, { color = INK2 }),
        mkPad(1, math.floor(12 * S)),
        softRule(width, 1, RULE_SOFT),
        mkPad(1, math.floor(12 * S)),
        mt(T("节气"), 17, { color = INK2 }),
        mkPad(1, math.floor(3 * S)),
        mt(I18n.termProgress(I18n.term(ctx.cur_term.name), elapsed or 1), 26),
        mkPad(1, math.floor(8 * S)),
        ProgressBar:new{
            dimen = Geom:new{ w = width, h = math.max(10, math.floor(12 * S)) },
            ratio = ratio,
            border = math.max(1, math.floor(1.4 * S)),
        },
        mkPad(1, math.floor(6 * S)),
        mt(ctx.next_term
            and I18n.termCountdown(I18n.term(ctx.next_term.name), remain)
            or "", 17, { color = INK2 }),
        mkPad(1, math.floor(12 * S)),
        softRule(width, 1, RULE_SOFT),
        mkPad(1, math.floor(12 * S)),
        mt(T("天文与空气"), 17, { color = INK2 }),
        mkPad(1, math.floor(5 * S)),
        mt(string.format("%s %s   %s %s",
            T("日出"), d.sunrise or "--:--", T("日落"), d.sunset or "--:--"), 19),
        mkPad(1, math.floor(5 * S)),
        mt(string.format("%s   %s AQI %s",
            d.feels or "--", T("空气"), air.text), 19),
    }

    return VerticalGroup:new(items)
end

--- 底部单行。默认只印「数据时刻 · 来源」，手势提示收进配置（show_hints）。
--- 理由：六段手势提示常驻一行，占了页脚全部空间，而它只在头三天有用；
--- 版面上最该抢眼的永远是 A/B 区的内容，不是操作说明。
--- 关键：量宽度必须用「不带 max_width」的探针。带了 max_width 的 TextWidget
--- 会折行，getSize().w 永远等于上限值，降字号的循环第一次就误判为“放得下”，
--- 结果真机上折成两行（实测 920x84 而不是 920x42）。
function Dashboard:buildHintRow(ctx, max_w, pad_lr, base_px)
    local text = self:hintLine(ctx)
    local px, natural = base_px, 0
    -- 每次降 1 个单位（原先是 0.92 的乘法，17 -> 15 会直接跳过 16，
    -- 一个字的差别就让字号掉两级）
    for _ = 1, 14 do
        natural = self:makeText(ctx, text, px):getSize().w
        if natural <= max_w or px <= 11 then break end
        px = math.max(11, px - 1)
    end
    local widget = self:makeText(ctx, text, px, { color = INK2, max_width = max_w })
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

--- 页脚文案：「16:18 · 和风天气」，或（开关打开时）那串手势提示。
--- ctx 可省：桩件的断言直接调 instance:hintLine() 对文案，这时自己去取时区。
function Dashboard:hintLine(ctx)
    local cfg = self:getConfig()
    -- 手势提示默认关（v2.53）：它是「头三天有用、此后天天占一行」的东西。
    -- 开关放 G_reader_settings 而不是 dashboard_config.lua，
    -- 这样在设备上点一下就能切，不必插 USB 改文件。
    if G_reader_settings:readSetting("dashboard_show_hints") == true then
        local line = T("点按刷新 · 点卡片展开 · 上划退出 · 顶部下滑菜单 · 左右滑动换版式")
        if cfg.show_attribution then
            local src = self:sourceShort()
            if src then line = line .. " · " .. src end
        end
        return line
    end
    local parts = {}
    local w = self.weather
    if w and w.ts then
        local tz = (ctx and ctx.tz) or self:getTz()
        parts[#parts + 1] = os.date("!%H:%M", w.ts + (tz and tz.offset or 0) * 60)
    end
    if cfg.show_attribution then
        local src = self:sourceShort()
        if src then parts[#parts + 1] = src end
    end
    if #parts == 0 then return T("暂无数据") end
    return table.concat(parts, " · ")
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
    -- 记录「尝试时刻」：tick 的间隔判断要用它，否则没有数据时会每拍都发起请求
    self.last_fetch_ts = os.time()

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
    -- 海外城市标记 global：和风的空气质量接口只覆盖国内站点，海外坐标去问主源
    -- 必然白跑一趟（还占一次配额），直接走 Open-Meteo
    local overseas = city.global == true

    NetworkMgr:runWhenOnline(function()
        local weather, air, err
        if not overseas then
            -- 请求三个接口是同步的，用 pcall 兜住意外错误，否则 fetching 标志会卡死，
            -- 之后再也不会重试
            local called, w, a, e = pcall(QWeather.fetch, {
                city = city,
                tz = tz,
                config = cfg,
            })
            if called then
                weather, air, err = w, a, e
            else
                logger.warn("dashboard: 和风拉取异常", tostring(w))
                err = tostring(w)
            end
        end

        -- 主源拿不到数据就降级到 Open-Meteo：免凭据，只求界面不空着。
        -- 降级成功时页脚会标注来源，不会让人误以为仍是和风的数据。
        -- 海外城市没有「和风可用」这个前提，不受 fallback_openmeteo 开关限制。
        if not weather and (overseas or cfg.fallback_openmeteo ~= false) then
            if not overseas then
                logger.warn("dashboard: 和风不可用，降级到 Open-Meteo：", tostring(err))
            end
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

        -- 失败计数喂给 tick 做退避：接口挂掉时不能仍按 5 分钟一轮猛冲
        if weather or air then
            self.fetch_fails = 0
        else
            self.fetch_fails = (self.fetch_fails or 0) + 1
            logger.warn("dashboard: 天气连续失败", self.fetch_fails, "次，下次重试将退避")
        end

        self.fetching = false
        if manual and not weather and not air then
            UIManager:show(InfoMessage:new{
                text = string.format(T("天气更新失败：%s"), err or T("未知原因")),
                timeout = 5,
            })
        end
        if self.shown then
            -- 只是数值更新：局部刷新即可，不必整屏闪一下
            self:refreshLayout("ui")
        end
    end)
end

return Dashboard
