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
        -- truncate_with_ellipsis 与真机一致：只占一行，超出部分画省略号
        if not self.truncate_with_ellipsis then
            lines = math.ceil(nat / mw)
        end
    end
    return {
        w = math.floor(w),
        -- 1.363 是真机实测值：getFace("cfont",100) 返回 size=179 时
        -- TextWidget 高 244（179 * 1.363）。桩件原先按 1.35 估算，系统性偏小 1%。
        h = math.floor(size * 1.363) * lines,
    }
end
function TextWidget:paintTo(bb, x, y)
    -- 顺手记下 fgcolor：预览图要分清正文（黑）与注释（灰），否则两层字一样黑、看不出层次。
    -- 断言不读这个字段，真机上它是 Color8 cdata，这里只认 number。
    local c = self.fgcolor
    if type(c) ~= "number" then c = 0 end
    -- 字体族也要记：预览里衬线数字（时钟 / 温度 / AQI）必须和黑体区分开，
    -- 否则「换没换衬线」在预览图上完全看不出来。
    local serif = false
    if type(self.face) == "table" and type(self.face.name) == "string" then
        serif = self.face.name:find("Serif", 1, true) ~= nil
    end
    RECORD[#RECORD + 1] = { kind = "text", text = tostring(self.text or ""), x = x, y = y,
                            w = math.floor(self:getSize().w), h = math.floor(self:getSize().h),
                            color = c, serif = serif }
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

-- 绘制原语：与真机 ffi/blitbuffer.lua 的签名逐一对齐。
--   paintRect(x, y, w, h, value)
--   paintCircle(center_x, center_y, r, c, w)       w = 线宽，省略即实心
--   paintBorder(x, y, w, h, bw, c, r, anti_alias)  r ≠ 0 时走四角圆弧
--   paintRoundedRect(x, y, w, h, c, r)             实心圆角矩形
--   paintRoundedCorner(x, y, w, h, bw, r, c, aa)   只画四角，不含直边
-- 只记录参数、由渲染器还原，所以**参数必须一个不漏地记下来**：
-- 旧版 paintBorder 把 bw 丢了，预览里 1px 和 3px 的边框被画成同一粗细。
local fake_bb = {}
function fake_bb:paintRect(x, y, w, h, color)
    RECORD[#RECORD + 1] = { kind = "rect", x = x, y = y, w = w, h = h, color = color }
end

function fake_bb:paintCircle(center_x, center_y, r, color, line_w)
    if not r or r <= 0 then return end
    local lw = line_w
    if lw == nil or lw > r then lw = r end   -- 与真机一致：线宽大于半径按半径算
    RECORD[#RECORD + 1] = { kind = "circle", cx = center_x, cy = center_y,
                            r = r, lw = lw, color = color }
end

function fake_bb:paintBorder(x, y, w, h, bw, color, r, anti_alias)
    RECORD[#RECORD + 1] = { kind = "border", x = x, y = y, w = w, h = h,
                            bw = bw or 1, r = r or 0, color = color }
end

function fake_bb:paintRoundedRect(x, y, w, h, color, r)
    RECORD[#RECORD + 1] = { kind = "roundrect", x = x, y = y, w = w, h = h,
                            r = r or 0, color = color }
end

function fake_bb:paintRoundedCorner(x, y, w, h, bw, r, color, anti_alias)
    RECORD[#RECORD + 1] = { kind = "corner", x = x, y = y, w = w, h = h,
                            bw = bw or 1, r = r or 0, color = color }
end

-- 机器可读的最终帧导出，供 tools/render_board.py 还原版面。
-- 每行 = 5 个数值槽 + 一个尾串，槽位含义按 tag 解释（渲染器里一一对应）：
--   R 矩形      x  y  w  h  color
--   B 边框      x  y  w  h  color    尾串 bw=<线宽>;r=<圆角半径>
--   C 圆        cx cy r  lw color    尾串空；lw >= r 即实心
--   D 圆角矩形  x  y  w  h  color    尾串 r=<半径>
--   K 圆角四角  x  y  w  h  color    尾串 bw=<线宽>;r=<半径>
--   T 文字      x  y  w  h  color    尾串 = 文本
--   I 图片      x  y  w  h  color    尾串 = 路径
local instance        -- 前置声明：dump 函数是闭包，必须在此之前可见

-- 收进一张表而不是三个 local：主 chunk 已贴着 200 个局部变量的上限，
-- 每多一个顶层 local 都可能让整个桩件编译失败（"too many local variables"）。
local FRAME = {}

function FRAME.emit()
    for _, r in ipairs(RECORD) do
        local tag, x, y, w, h, tail
        if r.kind == "text" then
            -- 衬线串加 "#S#" 前缀：帧协议是「5 个数值槽 + 一个尾串」，字体没有槽位可放
            tag, x, y, w, h = "T", r.x, r.y, r.w, r.h
            tail = (r.serif and "#S#" or "") .. tostring(r.text or "")
        elseif r.kind == "image" then
            tag, x, y, w, h, tail = "I", r.x, r.y, r.w, r.h, tostring(r.text or "")
        elseif r.kind == "rect" then
            tag, x, y, w, h, tail = "R", r.x, r.y, r.w, r.h, ""
        elseif r.kind == "border" then
            tag, x, y, w, h = "B", r.x, r.y, r.w, r.h
            tail = string.format("bw=%g;r=%g", r.bw or 1, r.r or 0)
        elseif r.kind == "circle" then
            tag, x, y, w, h, tail = "C", r.cx, r.cy, r.r, r.lw, ""
        elseif r.kind == "roundrect" then
            tag, x, y, w, h = "D", r.x, r.y, r.w, r.h
            tail = string.format("r=%g", r.r or 0)
        elseif r.kind == "corner" then
            tag, x, y, w, h = "K", r.x, r.y, r.w, r.h
            tail = string.format("bw=%g;r=%g", r.bw or 1, r.r or 0)
        end
        if tag then
            print(string.format("FRAME|%s|%d|%d|%d|%d|%d|%s", tag,
                math.floor(x or 0), math.floor(y or 0), math.floor(w or 0),
                math.floor(h or 0), math.floor(r.color or 0), tail))
        end
    end
    print("FRAME|END")
end

function FRAME.dump()
    RECORD = {}
    instance.root:paintTo(fake_bb, 0, 0)
    FRAME.emit()
end

-- 原语自检页（STUB_PRIMITIVES=1）：只验证「桩件记录 → 渲染器还原」这条链，
-- 与任何真实版式无关。P0 新增的四个原语必须先在真机同款参数下看一眼，
-- 才敢往组件里用——否则圆角画歪、月牙缺口朝反都不会有人发现。
function FRAME.primitives()
    RECORD = {}
    -- 桩件值域反向：屏幕灰度 g 对应的记录值 = 255 - g
    local function ink(g) return 255 - g end
    local I0, I1, I2, I3 = ink(0x00), ink(0x33), ink(0x66), ink(0x88)
    local WHITE = ink(0xFF)

    local function label(y, s, col)
        RECORD[#RECORD + 1] = { kind = "text", text = s, x = 56, y = y,
                                w = 960, h = 41, color = col or I1 }
    end

    RECORD[#RECORD + 1] = { kind = "text", text = "P0 绘制原语自检 · 1072x1448",
                            x = 56, y = 30, w = 960, h = 52, color = I0 }

    -- 1. 实心圆：看边缘会不会糊、最小能到几 px
    label(100, "实心圆 r=8 / 16 / 32 / 56，墨阶 0x00 与 0x66")
    for _, t in ipairs({ { 110, 8, I0 }, { 210, 16, I0 }, { 360, 32, I0 },
                         { 560, 56, I0 }, { 690, 32, I2 }, { 800, 16, I2 },
                         { 890, 8, I2 } }) do
        fake_bb:paintCircle(t[1], 206, t[2], t[3])
    end

    -- 2. 圆环：线宽从 2 到 16，外加 6px 小点（电池触点、节气点的实际尺寸）
    label(286, "圆环 r=40 线宽 2 / 4 / 8 / 16 / 40；小点 r=10、r=6")
    for _, t in ipairs({ { 110, 40, 2 }, { 240, 40, 4 }, { 370, 40, 8 },
                         { 500, 40, 16 }, { 630, 40, 40 },
                         { 760, 10, 2 }, { 830, 10, 1 },
                         { 900, 6, 2 }, { 950, 6, 1 } }) do
        fake_bb:paintCircle(t[1], 372, t[2], I0, t[3])
    end

    -- 3. 月牙 = 两圆相减：给月相组件用，先确认缺口方向与留边
    label(436, "月牙 = 两圆相减：开口朝右上 / 右下 / 正右，r=56 与 r=40")
    fake_bb:paintCircle(150, 538, 56, I0)
    fake_bb:paintCircle(178, 524, 56, WHITE)
    fake_bb:paintCircle(330, 538, 56, I0)
    fake_bb:paintCircle(302, 552, 56, WHITE)
    fake_bb:paintCircle(520, 538, 56, I3)
    fake_bb:paintCircle(548, 538, 56, WHITE)
    fake_bb:paintCircle(680, 538, 40, I0)
    fake_bb:paintCircle(696, 532, 40, WHITE)

    -- 4. 实心圆角矩形：卡片底、按钮底
    label(618, "圆角矩形填充 r=4 / 12 / 24 / 44（210x96）")
    for i, r in ipairs({ 4, 12, 24, 44 }) do
        fake_bb:paintRoundedRect(56 + (i - 1) * 244, 668, 210, 96, ink(0xCC), r)
    end

    -- 5. 圆角边框：1px 最轻、3px 最重，看圆角和直边接得顺不顺
    label(788, "圆角边框 bw=1(0x99) / 1(0x33) / 2 / 3，r=12")
    local bx = { 56, 306, 556, 806 }
    fake_bb:paintBorder(bx[1], 838, 222, 110, 1, ink(0x99), 12)
    fake_bb:paintBorder(bx[2], 838, 222, 110, 1, I1, 12)
    fake_bb:paintBorder(bx[3], 838, 222, 110, 2, I1, 12)
    fake_bb:paintBorder(bx[4], 838, 222, 110, 3, I0, 12)

    -- 6. 1px 线径：直角 vs 圆角，0x99 与 0xDD 两档
    label(972, "1px 线径：直角 vs r=10（上 0x99 / 下 0xDD）")
    fake_bb:paintBorder(56, 1022, 460, 46, 1, ink(0x99), 0)
    fake_bb:paintBorder(556, 1022, 460, 46, 1, ink(0x99), 10)
    fake_bb:paintBorder(56, 1078, 460, 46, 1, ink(0xDD), 0)
    fake_bb:paintBorder(556, 1078, 460, 46, 1, ink(0xDD), 10)

    -- 7. 进度槽：细线槽 + 圆角填充，两种墨阶配比
    label(1148, "进度槽 r=17：0xCC 槽 + 0x33 填 / 0xDD 槽 + 0x66 填")
    fake_bb:paintRoundedRect(56, 1198, 960, 34, ink(0xCC), 17)
    fake_bb:paintRoundedRect(56, 1198, 600, 34, I1, 17)
    fake_bb:paintRoundedRect(56, 1242, 960, 34, ink(0xDD), 17)
    fake_bb:paintRoundedRect(56, 1242, 380, 34, I2, 17)

    -- 8. 合成示例：圆角卡片 + 双色图标 + 进度槽，这才是这些原语的真实用法
    label(1300, "合成：1px 0x99 圆角卡片 + 双色图标 + 内嵌进度槽")
    fake_bb:paintBorder(56, 1350, 460, 66, 1, ink(0x99), 12)
    fake_bb:paintCircle(104, 1383, 21, I2, 3)      -- 光晕（次要墨）
    fake_bb:paintCircle(104, 1383, 13, I0)         -- 太阳本体（主墨）
    fake_bb:paintRoundedRect(150, 1374, 330, 18, ink(0xDD), 9)
    fake_bb:paintRoundedRect(150, 1374, 198, 18, I1, 9)

    fake_bb:paintBorder(556, 1350, 460, 66, 1, ink(0x99), 12)
    fake_bb:paintCircle(600, 1383, 20, I0)
    fake_bb:paintCircle(610, 1377, 20, WHITE)
    fake_bb:paintRoundedRect(650, 1374, 330, 18, ink(0xDD), 9)
    fake_bb:paintRoundedRect(650, 1374, 120, 18, I2, 9)

    FRAME.emit()
end

function UIManager:show(widget)
    table.insert(stack, widget)
    -- 真机的窗口栈是 { widget = ..., ... } 结构，插件里有按它兜底回收菜单的逻辑
    UIManager._window_stack = UIManager._window_stack or {}
    table.insert(UIManager._window_stack, { widget = widget })
    if widget.paintTo then widget:paintTo(fake_bb, 0, 0) end
end

-- 取当前最上层窗口：两步录入的测试要「接着刚才弹出来的那个窗口」往下走
function UIManager:_top() return stack[#stack] end

function UIManager:close(widget)
    for i = #stack, 1, -1 do
        if stack[i] == widget then table.remove(stack, i) end
    end
    local ws = UIManager._window_stack
    if ws then
        for i = #ws, 1, -1 do
            if ws[i].widget == widget then table.remove(ws, i) end
        end
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

-- 和风天气响应样本。**结构与 2026-11-12 实测抓取的一致**（真实原文已脱敏存
-- tools/fixtures/*.json），数值换成整数便于断言。三个接口各一份，用来验证
-- 「gzip -> 解压 -> JSON 解析 -> 展示字段」整条链路。
--
-- 结构要点（都是实测踩出来的）：
--   · daily 的每一天**没有 date 字段**，日期只能从 forecastStartTime 取
--   · astro 里除日出日落还有月升月落与 moonPhase，只有和风给
--   · 空气的 CO 单位是 mg/m³，其余是 μg/m³，不能统一硬写
local QW_SAMPLES = {
    -- /weather/v1/current/
    ['current'] = '{"condition":{"text":"晴","code":"100"},'
        .. '"temperature":{"value":13.19,"unit":"°C"},'
        .. '"feelsLike":{"value":10.16,"unit":"°C"},'
        .. '"humidity":0.44,'
        .. '"wind":{"direction":{"degree":185,"compass":"s"},'
        .. '"speed":{"value":3.38,"unit":"m/s"},"scale":2}}',
    -- /weather/v1/daily/?days=7（localTime=true，时间带 +08:00）
    ['daily'] = '{"days":['
        .. '{"forecastStartTime":"2026-11-11T00:00+08:00",'
        .. '"astro":{"sunrise":"2026-11-11T06:54+08:00","sunset":"2026-11-11T17:02+08:00",'
        .. '"moonrise":"2026-11-11T09:52+08:00","moonset":"2026-11-11T18:41+08:00",'
        .. '"solarNoon":"2026-11-11T11:58+08:00","moonPhase":"waxing-crescent"},'
        .. '"temperatureMax":{"value":14.1,"unit":"°C"},'
        .. '"temperatureMin":{"value":0.56,"unit":"°C"},'
        .. '"daytime":{"condition":{"text":"晴","code":"100"},'
        .. '"precipitation":{"probability":0,"amount":{"value":0,"unit":"mm"}}},'
        .. '"nighttime":{"condition":{"text":"夜","code":"150"}}}'
        .. ',{"forecastStartTime":"2026-11-12T00:00+08:00",'
        .. '"astro":{"sunrise":"2026-11-12T06:55+08:00","sunset":"2026-11-12T17:01+08:00",'
        .. '"moonPhase":"waxing-crescent"},'
        .. '"temperatureMax":{"value":15.2,"unit":"°C"},'
        .. '"temperatureMin":{"value":1.2,"unit":"°C"},'
        .. '"daytime":{"condition":{"text":"霾","code":"502"},'
        .. '"precipitation":{"probability":10,"amount":{"value":0,"unit":"mm"}}}}'
        .. ',{"forecastStartTime":"2026-11-13T00:00+08:00",'
        .. '"astro":{"sunrise":"2026-11-13T06:56+08:00","sunset":"2026-11-13T17:00+08:00"},'
        .. '"temperatureMax":{"value":13.4,"unit":"°C"},'
        .. '"temperatureMin":{"value":2.6,"unit":"°C"},'
        .. '"daytime":{"condition":{"text":"多云","code":"101"},'
        .. '"precipitation":{"probability":20,"amount":{"value":0.2,"unit":"mm"}}}}'
        .. ',{"forecastStartTime":"2026-11-14T00:00+08:00",'
        .. '"astro":{"sunrise":"2026-11-14T06:57+08:00","sunset":"2026-11-14T16:59+08:00"},'
        .. '"temperatureMax":{"value":12.0,"unit":"°C"},'
        .. '"temperatureMin":{"value":3.0,"unit":"°C"},'
        .. '"daytime":{"condition":{"text":"阴","code":"104"}}}'
        .. ',{"forecastStartTime":"2026-11-15T00:00+08:00",'
        .. '"astro":{"sunrise":"2026-11-15T06:58+08:00","sunset":"2026-11-15T16:58+08:00"},'
        .. '"temperatureMax":{"value":10.5,"unit":"°C"},'
        .. '"temperatureMin":{"value":2.0,"unit":"°C"},'
        .. '"daytime":{"condition":{"text":"小雨","code":"305"}}}'
        .. ',{"forecastStartTime":"2026-11-16T00:00+08:00",'
        .. '"astro":{"sunrise":"2026-11-16T06:59+08:00","sunset":"2026-11-16T16:57+08:00"},'
        .. '"temperatureMax":{"value":9.1,"unit":"°C"},'
        .. '"temperatureMin":{"value":-1.0,"unit":"°C"},'
        .. '"daytime":{"condition":{"text":"晴","code":"100"}}}'
        .. ',{"forecastStartTime":"2026-11-17T00:00+08:00",'
        .. '"astro":{"sunrise":"2026-11-17T07:00+08:00","sunset":"2026-11-17T16:56+08:00"},'
        .. '"temperatureMax":{"value":11.8,"unit":"°C"},'
        .. '"temperatureMin":{"value":0.2,"unit":"°C"},'
        .. '"daytime":{"condition":{"text":"多云","code":"101"}}}'
        .. ']}',
    -- /airquality/v1/current/（国标 AQI 65，6 项污染物齐全，CO 是 mg/m³）
    ['air'] = '{"indexes":[{"code":"cn-mee","name":"AQI (CN)","aqi":65,'
        .. '"category":"良","primaryPollutant":{"code":"pm2p5",'
        .. '"name":"PM 2.5"}}],'
        .. '"pollutants":['
        .. '{"code":"pm2p5","name":"PM 2.5","concentration":{"value":42.0,"unit":"μg/m³"}},'
        .. '{"code":"pm10","name":"PM 10","concentration":{"value":70.0,"unit":"μg/m³"}},'
        .. '{"code":"no2","name":"NO2","concentration":{"value":31.0,"unit":"μg/m³"}},'
        .. '{"code":"o3","name":"O3","concentration":{"value":50.0,"unit":"μg/m³"}},'
        .. '{"code":"so2","name":"SO2","concentration":{"value":4.0,"unit":"μg/m³"}},'
        .. '{"code":"co","name":"CO","concentration":{"value":0.8,"unit":"mg/m\194\179"}}'
        .. ']}',
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

-- Open-Meteo 降级样本（结构照 2026-11-12 实测抓取，明文不压缩——正好也验证
-- 明文直通分支）。daily 里是 7 个平行数组，按 weekday 顺序对齐；
-- 空气给 6 项，其中 CO 是 μg/m³（和风是 mg/m³），解析时该除以 1000。
local OM_SAMPLES = {
    forecast = '{"current":{"temperature_2m":10.0,"relative_humidity_2m":74,'
        .. '"apparent_temperature":8.2,"weather_code":0,"wind_speed_10m":4.5,'
        .. '"wind_direction_10m":185},'
        .. '"daily":{"time":["2026-11-11","2026-11-12","2026-11-13","2026-11-14",'
        .. '"2026-11-15","2026-11-16","2026-11-17"],'
        .. '"weather_code":[0,3,45,61,71,95,2],'
        .. '"temperature_2m_max":[11.2,12.0,10.4,8.8,6.1,9.0,13.3],'
        .. '"temperature_2m_min":[1.2,2.0,0.4,-1.8,-3.1,0.0,2.2],'
        .. '"sunrise":["2026-11-10T22:54","2026-11-11T22:55","2026-11-12T22:56",'
        .. '"2026-11-13T22:57","2026-11-14T22:58","2026-11-15T22:59","2026-11-16T23:00"],'
        .. '"sunset":["2026-11-11T09:01","2026-11-12T09:00","2026-11-13T08:59",'
        .. '"2026-11-14T08:58","2026-11-15T08:57","2026-11-16T08:56","2026-11-17T08:56"]}}',
    air = '{"current":{"pm10":111.5,"pm2_5":108.7,"carbon_monoxide":2634.0,'
        .. '"nitrogen_dioxide":78.7,"sulphur_dioxide":26.0,"ozone":17.0}}',
}

-- 服务端强制 gzip，桩件也照做：返回真实压缩字节，而不是明文 JSON
local http = {}
function http.request(req)
    local url = req.url or ""
    local body, plain
    if url:find("ip%-api%.com") then
        -- 定位样本：纽约曼哈顿附近。STUB_GEO_FAIL 用来验证失败分支不动已有设置。
        body = _G.STUB_GEO_FAIL
            and '{"status":"fail","message":"private range"}'
            or ('{"status":"success","country":"United States","city":"New York",'
                .. '"lat":40.7143,"lon":-74.006,"timezone":"America/New_York"}')
        plain = true
    elseif url:find("air%-quality%-api%.") then
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
function G_settings:delSetting(k) store[k] = nil; return self end
function G_settings:isTrue(k) return store[k] == true end
function G_settings:nilOrTrue(k) return store[k] ~= false end
function G_settings:flush() return self end

local LuaSettings = {}
LuaSettings.__index = LuaSettings
-- 按路径持久化：真实 LuaSettings 是「一个文件一份数据」，桩件若每次都返回空表，
-- 「写完再读回来」这类断言就永远测不出问题（倒数日 / 待办正是靠这条）。
local LS_STORE = {}
function LuaSettings:open(path)
    local d = LS_STORE[path]
    if not d then
        d = {}
        LS_STORE[path] = d
    end
    return setmetatable({ path = path, data = d }, LuaSettings)
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
-- 真机 generic/device.lua 里是 return false，Kindle 覆写成 true（kindle/device.lua）。
-- 看板用它决定菜单挂到「设置→屏幕→屏保」还是退回「工具」标签页。
function Device:supportsScreensaver() return true end

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
-- 与真实实现一致：TouchMenu:closeMenu() 就是 self.close_callback()
function TouchMenu:closeMenu()
    self.close_callback()
end

-- InputDialog 桩：只保存构造参数，测试不弹键盘
local InputDialog = Widget:extend{}
function InputDialog:getInputText() return self.input or "" end
function InputDialog:onShowKeyboard() end

-- DateTimeWidget 桩：只记下构造参数（年 / 月 / 日的默认值），
-- 测试里用 fake_pick 模拟「翻好日期点了保存」，走的是真机同一个 callback。
local DateTimeWidget = Widget:extend{}
function DateTimeWidget:fake_pick(y, m, d)
    self.year, self.month, self.day = y, m, d
    if self.callback then self.callback(self) end
end

---------------------------------------------------------------- 模块注册
package.preload["ffi/blitbuffer"] = function()
    -- 桩件的值域是反的：0 = 纸白、255 = 纯黑。真机 Color8 正好相反
    -- （COLOR_BLACK = Color8(0)、COLOR_WHITE = Color8(0xFF)），
    -- 所以出图端一律用 255 - color 换回屏幕灰度。
    -- 这里把真机 ffi/blitbuffer.lua:2710 起那套命名灰**逐个补齐**（值取反），
    -- 否则 main.lua 里引用 COLOR_GRAY_E / COLOR_LIGHT_GRAY 会拿到 nil，
    -- 落进 `or COLOR_WHITE` 兜底 → 纸底和卡片全变纯白，预览看着像没改。
    -- 例：真机 COLOR_DARK_GRAY = Color8(0x88)，桩件 0x77 → 255-0x77 = 136 = 0x88 ✓
    local function ink(g) return 255 - g end
    return {
        COLOR_WHITE      = ink(0xFF),
        COLOR_GRAY_E     = ink(0xEE),
        COLOR_GRAY_D     = ink(0xDD),
        COLOR_LIGHT_GRAY = ink(0xCC),
        COLOR_GRAY_B     = ink(0xBB),
        COLOR_GRAY       = ink(0xAA),
        COLOR_GRAY_9     = ink(0x99),
        COLOR_DARK_GRAY  = ink(0x88),
        COLOR_GRAY_7     = ink(0x77),
        COLOR_GRAY_6     = ink(0x66),
        COLOR_GRAY_5     = ink(0x55),
        COLOR_GRAY_4     = ink(0x44),
        COLOR_GRAY_3     = ink(0x33),
        COLOR_BLACK      = ink(0x00),
    }
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
package.preload["ui/widget/datetimewidget"] = function() return DateTimeWidget end
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

-- ============ 封面桩（dashboard_cover 会 require 这四个模块）============
-- 目标是让「取位图 -> 缩放 -> 写 PNG -> 下次读缓存」这条链路真的跑一遍，
-- 而不是把 resolve() 整个替换掉（那样测不到缓存键、缓存命中、写盘失败这些分支）。
do
    local settings_dir = _G.STUB_SETTINGS_DIR
    if settings_dir then
        DataStorage.getSettingsDir = function() return settings_dir end
    end

    package.preload["ffi/sha2"] = function()
        return {
            md5 = function(str)
                -- 只要「同输入同输出、不同键不同输出」，桩件不验证密码学强度
                local h1, h2 = 5381, 52711
                for i = 1, #str do
                    local b = str:byte(i)
                    h1 = (h1 * 33 + b) % 4294967296
                    h2 = (h2 * 31 + b * (i % 7 + 1)) % 4294967296
                end
                return string.format("%08x%08x", h1, h2)
            end,
        }
    end

    local lfs = {}
    function lfs.attributes(path, what)
        local f = io.open(path, "rb")
        if not f then return nil end
        f:close()
        if what == "mode" then return "file" end
        if what == "modification" then
            -- 书的 mtime 必须稳定（缓存键里有它），缓存文件用当前时间（淘汰按它排序）
            if tostring(path):match("%.epub$") or tostring(path):match("%.txt$") then
                return 1762900000
            end
            return os.time()
        end
        return nil
    end
    -- 目录由 Python 侧建好（run_stub / render_board 都会 mkdir），这里只当成功
    function lfs.mkdir() return true end
    function lfs.dir() return function() return nil end end
    package.preload["libs/libkoreader-lfs"] = function() return lfs end

    local RenderImage = {}
    function RenderImage:scaleBlitBuffer(bb) return bb end
    package.preload["ui/renderimage"] = function() return RenderImage end

    local function copy_file(src, dst)
        local fi = io.open(src, "rb")
        if not fi then return false end
        local data = fi:read("*a")
        fi:close()
        local fo = io.open(dst, "wb")
        if not fo then return false end
        fo:write(data)
        fo:close()
        return true
    end

    -- 600x900 的「封面位图」：写 PNG 时把 tools/fixtures/cover_demo.png 拷过去，
    -- 这样落盘的是真 PNG，预览图也能把它画出来。英文出图换英文封面，
    -- 否则 README.en.md 的阅读卡里会冒出中文书名。
    local function make_cover_bb()
        local _cv_en = os.getenv("STUB_LANG") == "en"
        return {
            getWidth = function() return 600 end,
            getHeight = function() return 900 end,
            writePNG = function(_, path)
                return copy_file(_cv_en and "tools/fixtures/cover_demo_en.png"
                    or "tools/fixtures/cover_demo.png", path)
            end,
            free = function() end,
        }
    end

    package.preload["document/documentregistry"] = function()
        return {
            openDocument = function(_, path)
                _G.COVER_OPENS = (_G.COVER_OPENS or 0) + 1
                _G.COVER_LAST_PATH = path
                if _G.STUB_COVER_MODE == "none" then
                    -- 模拟「这本书没有封面」：拿得到文档对象，但取不出位图
                    return { getCoverPageImage = function() return nil end,
                             close = function() end }
                end
                if _G.STUB_COVER_MODE == "unopenable" then
                    return nil
                end
                return { getCoverPageImage = make_cover_bb,
                         close = function() end }
            end,
        }
    end
end

_G.G_reader_settings = G_settings

-- 目视检查用（只在 dump 帧时生效，dump 完立刻撤销，不参与任何断言）：
--   STUB_ZONES="clock_weather,calendar,stats_cells,clock_weather,calendar,side_panel"
--     依次指定 竖屏 A/B/C + 横屏 A/B/C 的组件；
--   STUB_LANG=en / zh 指定界面语言。
-- 配合 STUB_FRAME=1 与 tools/render_png.py，就能把任意组合/语言画出来看。

-- 预览专用注入（tools/render_board.py 出 README 图时用）：全部走环境变量，
-- 不设就完全不起作用，也不参与任何断言。真机上这几项来自
-- Device:getPowerDevice() / NetworkMgr / DocSettings，桩件默认没有，
-- 出图时就是「电量 -- · 网络 --」，不好看也不像真机。
--   STUB_POWER="58"            电量百分比；"58,charging" 表示充电中
--   STUB_WIFI="on|off|down"    WiFi 已连接 / 未开启 / 开着但没连上
--   STUB_READING="1"           注入一本「三体」当作在读文档
-- 包一层 do…end：桩件主 chunk 已经贴着 Lua 的 200 个局部变量上限，
-- 这里多出来的几个名字必须在块结束时回收，否则后面再加东西就编不过。
do
    local _env_power = os.getenv("STUB_POWER")
    if _env_power and _env_power ~= "" and _G.STUB_POWERD then
        local cap_s, flag = _env_power:match("^(%-?%d+),?(%a*)$")
        if tonumber(cap_s) then
            -- 直接改桩件的 powerd，别拦 Device：断言读的是同一个表，
            -- 只改 getCapacity 会得到「界面 58 / 断言 78」这种自欺欺人的结果。
            _G.STUB_POWERD.capacity = tonumber(cap_s)
            _G.STUB_POWERD.charging = (flag == "charging")
        end
    end

    local _env_wifi = os.getenv("STUB_WIFI")
    if _env_wifi == "on" or _env_wifi == "off" or _env_wifi == "down" then
        NetworkMgr.isWifiOn = function() return _env_wifi ~= "off" end
        NetworkMgr.isConnected = function() return _env_wifi == "on" end
    end

    if os.getenv("STUB_READING") then
        -- 书名跟语言走：README.en.md 的图里不能出现中文（STUB_LANG 在文件后面才读，
        -- 这里直接查环境变量，别依赖后面的 _env_lang）
        local _rd_en = os.getenv("STUB_LANG") == "en"
        local _rd_title = _rd_en and "The Three-Body Problem" or "三体（全集）"
        local _rd_author = _rd_en and "Liu Cixin" or "刘慈欣"
        package.preload["docsettings"] = function()
            return { open = function(_, _path)
                return { readSetting = function(_, key)
                    if key == "stats" then
                        return { title = _rd_title, authors = _rd_author, pages = 1203 }
                    elseif key == "percent_finished" then
                        return 0.37
                    end
                    return nil
                end }
            end }
        end
        G_settings:saveSetting("lastfile", "/mnt/us/documents/" .. _rd_title .. ".epub")
    end

    -- 预览专用：注入一组倒数日 / 待办。出图脚本按「今天」现算日期，
    -- 所以图里的「还有 N 天」不会隔天就过期。
    if _G.STUB_AGENDA then
        local s = LuaSettings:open(DataStorage:getSettingsDir() .. "/dashboard_agenda.lua")
        s:saveSetting("events", _G.STUB_AGENDA.events or {})
        s:saveSetting("todos", _G.STUB_AGENDA.todos or {})
        s:saveSetting("seq", _G.STUB_AGENDA.seq or 100)
        s:flush()
    end
end

local _env_zones = os.getenv("STUB_ZONES")
local _env_lang = os.getenv("STUB_LANG")
if _env_zones and _env_zones ~= "" then
    local t = {}
    for part in _env_zones:gmatch("[^,]+") do t[#t + 1] = part end
    if #t == 6 then
        store["dashboard_components"] = {
            portrait = { A = t[1], B = t[2], C = t[3] },
            landscape = { A = t[4], B = t[5], C = t[6] },
        }
    else
        print("[WARN] STUB_ZONES 需要 6 个逗号分隔的组件 id，已忽略")
    end
end
if _env_lang == "en" or _env_lang == "zh" then
    store["dashboard_lang"] = _env_lang
end

_G.unpack = _G.unpack or table.unpack

-- 记录 os.execute，避免真的去调 lipc
local real_execute = os.execute
os.execute = function(cmd)
    RECORD[#RECORD + 1] = { kind = "exec", text = cmd }
    return 0
end

-- 出图时把「现在」钉在 STUB_NOW（UTC 秒）。时钟和「更新于 16:18」都取 os.time()，
-- 不钉的话每次出图的时刻都不一样，README 的图天天换脸。注意必须传**真**的时间戳
-- （而不是把本地钟面转成秒），localNow 是「os.time() + 时区偏移再按 UTC 格式化」，
-- 传假值会整体偏出一个时区。只在这条环境变量存在时生效，测试不受影响。
-- 写成立即执行函数是为了不占顶层 local（主 chunk 的 local 已顶到 200 上限）。
(function()
    local fixed = tonumber(os.getenv("STUB_NOW") or "")
    if not fixed then return end
    local real_time, real_date = os.time, os.date
    os.time = function(t)
        if t == nil then return fixed end
        return real_time(t)
    end
    os.date = function(fmt, t)
        return real_date(fmt, t or fixed)
    end
end)()

---------------------------------------------------------------- 执行测试
local plugin_dir = arg and arg[1] or "dashboard.koplugin"
package.path = plugin_dir .. "/?.lua;" .. package.path

local plugin = assert(loadfile(plugin_dir .. "/main.lua"))()
EVENTS[#EVENTS + 1] = "== 插件加载成功 =="

-- 与 main.lua 同名的短别名：桩件里不少断言要「按当前语言的文案」去控件树里找，
-- 直接比对中文字面量的话，切到英文就全找不到（本轮踩过）
local I18n = require("dashboard_i18n")
local T = I18n.T

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
-- 配置入口要落到「设置 → 屏幕 → 屏保」之下：menusorter 递归按 id 找目标，
-- 屏保那项的 id 就是 "screensaver"。hint 写错（或目标不存在）项会被静默丢弃。
if desk.sorting_hint ~= "screensaver" then
    print("[FAIL] 菜单没挂到屏保之下，sorting_hint = " .. tostring(desk.sorting_hint))
    os.exit(1)
end
if not desk.separator then
    print("[FAIL] 没说要在屏保原生项前画分隔线")
    os.exit(1)
end
-- 顶层结构与「一页放得下」的硬约束（v2.60）。
--
-- TouchMenu 每页容量 = min(按行高算出来的条数, max_per_page_default)。真机实读
-- PW3 1072x1448：竖屏 10 条、横屏 9 条 —— 顶层超过 9 条横屏就会翻页。原来的
-- 15 条平铺正是用户反馈的「菜单要翻页」。上限写进断言，以后再往里加项会直接 FAIL。
;(function()
    local top = desk.sub_item_table
    local by_text = {}
    for _, item in ipairs(top) do
        -- 用 T() 取当前语言下的文案：桩件既要能跑中文，也要能跑 STUB_LANG=en
        by_text[item.text] = item
    end
    -- Settings 入口比看板内多一条「打开看板」，所以上限给 7
    if #top > 7 then
        print(string.format("[FAIL] 顶层菜单 %d 条，超过 7 条：横屏一页只放 9 条，会翻页", #top))
        os.exit(1)
    end
    for _, name in ipairs({ "外观", "地点与天气", "内容", "显示与省电", "语言 / Language" }) do
        if not by_text[T(name)] then
            print("[FAIL] 顶层菜单缺少分组：" .. name)
            os.exit(1)
        end
    end

    local place = by_text[T("地点与天气")]
    if #place.sub_item_table ~= 5 then
        print(string.format("[FAIL] 「地点与天气」应有 5 项，实际 %d", #place.sub_item_table))
        os.exit(1)
    end
    local seen_place = {}
    for _, it in ipairs(place.sub_item_table) do seen_place[it.text] = true end
    for _, name in ipairs({ "选择城市", "选择时区", "自动检测我的位置（按 IP）",
                            "天气服务", "立即刷新天气" }) do
        if not seen_place[T(name)] then
            print("[FAIL] 「地点与天气」缺少：" .. name)
            os.exit(1)
        end
    end

    -- 城市菜单：v2.60 拆成「国内城市 / 海外城市」两组。原来是 9 个分组 + 自动检测
    -- 共 10 条，竖屏刚够一页、横屏就要翻。
    local city
    for _, it in ipairs(place.sub_item_table) do
        if it.text == T("选择城市") then city = it end
    end
    local buckets = city and city.sub_item_table or {}
    if #buckets ~= 2 or buckets[1].text ~= T("国内城市")
        or buckets[2].text ~= T("海外城市") then
        print("[FAIL] 城市菜单应只有「国内城市」「海外城市」两组，实际 " .. tostring(#buckets))
        os.exit(1)
    end
    local group_names = {}
    for _, g in ipairs(buckets) do
        for _, sub in ipairs(g.sub_item_table) do
            if sub.sub_item_table then group_names[sub.text] = true end
        end
    end
    for _, name in ipairs({ "直辖市", "省会与首府", "港澳台", "亚洲", "欧洲",
                            "北美洲", "南美洲", "大洋洲", "非洲" }) do
        if not group_names[T(name)] then
            print("[FAIL] 城市菜单缺少分组：" .. name)
            os.exit(1)
        end
    end

    -- 分组层不许超过 9 条（横屏一页）。城市 / 时区那种纯叶子长列表不在此列：
    -- 它们的长短由数据决定，翻页是正常的，不该为了凑数去砍城市。
    local function any_sub(tbl)
        for _, it in ipairs(tbl) do
            if it.sub_item_table then return true end
        end
        return false
    end
    local function walk(tbl, where)
        if #tbl > 9 and any_sub(tbl) then
            print(string.format("[FAIL] %s 有 %d 条，超过横屏一页的 9 条", where, #tbl))
            os.exit(1)
        end
        for _, it in ipairs(tbl) do
            if it.sub_item_table then walk(it.sub_item_table, where .. " › " .. it.text) end
        end
    end
    walk(top, "顶层")
    EVENTS[#EVENTS + 1] = string.format(
        "== 菜单分层：顶层 %d 条，城市分国内 %d / 海外 %d 组，分组层均不超 9 条 ==",
        #top, #buckets[1].sub_item_table, #buckets[2].sub_item_table)
end)()

-- ============ 海外城市 / 自动定位 ============
-- 分组结构（国内 / 海外两组、九个子分组、自动检测的位置）已在上面的
-- 「菜单分层」块里断言过，这里只查数据本身：海外城市必须真的带 tz。
-- 用匿名函数包住：do…end 不隔开寄存器，顶层局部变量照样计入 200 上限。
-- 行首的分号必须有：上一行结尾是 `end)()`，不加分号时 Lua 会把这里的 `(`
-- 当成「调用上一个表达式的结果」，报 "attempt to call a string value"。
;(function()

    -- 海外城市必须自带 tz，且该 tz 能在时区表里查到（查不到会回落成北京时间）
    local CD = package.loaded["dashboard_cities"]
    local overseas, has_tz = 0, 0
    for _, c in ipairs(CD.cities) do
        if c.group ~= "直辖市" and c.group ~= "省会" and c.group ~= "港澳台" then
            overseas = overseas + 1
            if c.tz and CD.tzByIana(c.tz) then has_tz = has_tz + 1 end
        end
    end
    if overseas == 0 or has_tz ~= overseas then
        print(string.format("[FAIL] 海外城市 %d 个，其中时区可查的只有 %d 个", overseas, has_tz))
        os.exit(1)
    end
    EVENTS[#EVENTS + 1] = string.format("== 海外城市 %d 个，时区全部可查 ==", overseas)

    -- 选海外城市要自动改时区；选国内城市不能覆盖用户手选的时区
    instance:setCity("伦敦")
    if instance:getTzIana() ~= "Europe/London" then
        print("[FAIL] 选伦敦后时区没跟着变成 Europe/London，实际 " .. tostring(instance:getTzIana()))
        os.exit(1)
    end
    instance:setCity("北京")
    if instance:getTzIana() ~= "Europe/London" then
        print("[FAIL] 选国内城市不应覆盖已选时区")
        os.exit(1)
    end

    -- 定位失败：已有设置不能被动过
    local before_city, before_tz = instance:getCityName(), instance:getTzIana()
    _G.STUB_GEO_FAIL = true
    instance:autoLocateCity()
    local fail_msg = UIManager:_top() and UIManager:_top().text or ""
    UIManager:close(UIManager:_top())
    if instance:getCityName() ~= before_city or instance:getTzIana() ~= before_tz then
        print("[FAIL] 定位失败时改动了已有城市/时区")
        os.exit(1)
    end
    -- 断言查桩件返回的 message 原文：中英文界面下前缀不同，但这条 message 会原样带回
    if not fail_msg:find("private range", 1, true) then
        print("[FAIL] 定位失败没有把服务端原因带进提示：" .. tostring(fail_msg))
        os.exit(1)
    end

    -- 定位成功：样本在纽约，应选中纽约并把时区带到 America/New_York
    _G.STUB_GEO_FAIL = nil
    instance:autoLocateCity()
    local ok_msg = UIManager:_top() and UIManager:_top().text or ""
    UIManager:close(UIManager:_top())
    if instance:getCityName() ~= "纽约" then
        print("[FAIL] 自动定位没选到纽约，实际 " .. tostring(instance:getCityName()))
        os.exit(1)
    end
    if instance:getTzIana() ~= "America/New_York" then
        print("[FAIL] 自动定位没同步时区，实际 " .. tostring(instance:getTzIana()))
        os.exit(1)
    end
    -- 城市名按当前界面语言本地化，英文模式下是 New York，所以要用 I18n.city 取期望值
    if not ok_msg:find(I18n.city(instance:getCity()), 1, true) then
        print("[FAIL] 定位成功提示里没有城市名：" .. tostring(ok_msg))
        os.exit(1)
    end
    EVENTS[#EVENTS + 1] = "== 自动定位：成功选中纽约 + America/New_York，失败不动设置 =="

    -- 恢复默认，后面的中英文断言与出图用例都假定是北京
    instance:setTz("Asia/Shanghai")
    instance:setCity("北京")
end)()

-- 凭据来源与脱敏显示
--
-- git clone 下来没有 dashboard_config.local.lua（它被 .gitignore 排除），凭据为空是
-- 正常状态。这里注入一对**假凭据**：桩件把 socket.http 整个换成了固定样本，请求根本
-- 不会出网，所以不需要真实 key。不注入的话 QWeather.fetch 会在凭据检查那一步直接
-- 返回，和风主路径（字段比对、gzip、AQI）就完全测不到了。
local cfg = instance:getConfig()
local INJECTED = false
if cfg.qweather.api_host == "" or cfg.qweather.api_key == "" then
    G_reader_settings:saveSetting("dashboard_qw_host", "stub.qweatherapi.com")
    G_reader_settings:saveSetting("dashboard_qw_key", "stub-key-0001")
    instance.config = nil
    instance:reloadConfig()
    cfg = instance:getConfig()
    INJECTED = true
    EVENTS[#EVENTS + 1] = "== 未配置真实凭据，已注入桩件假凭据（和风主路径照常验证）=="
end
EVENTS[#EVENTS + 1] = string.format("== 凭据：host=%s key=%s 来源=%s ==",
    cfg.qweather.api_host, QW.mask(cfg.qweather.api_key), tostring(cfg._key_source))
if cfg.qweather.api_host == "" or cfg.qweather.api_key == "" then
    print("[FAIL] 注入假凭据后仍读不到 host/key，loadConfig 的覆盖顺序有问题")
    os.exit(1)
end
if QW.mask(cfg.qweather.api_key):find(cfg.qweather.api_key, 1, true) then
    print("[FAIL] 脱敏函数泄露了完整 key")
    os.exit(1)
end
if INJECTED and cfg._key_source ~= "settings" then
    print("[FAIL] 设备内录入的凭据没有最高优先级，来源 = " .. tostring(cfg._key_source))
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

-- 布局体检（STUB_DIAG=1 时生效，只打印不改流程）：
-- 逐行输出根容器的子块尺寸，用于确定 A/B/C 分区权重与各组件自然高度。
if os.getenv("STUB_DIAG") == "1" then
    local function kind(w)
        if w.is_gap then return "gap" end
        if w[1] then return "group" end
        if w.face then return "text" end
        if w.color then return "solid" end
        if w.dimen then return "box" end
        return "?"
    end
    local function container(w, d)
        if d > 4 then return nil end
        if w[1] == nil then return nil end
        if #w > 2 then return w end
        return container(w[1], d + 1)
    end
    local root = instance.root
    local rs = root:getSize()
    print(string.format("\n[DIAG] root=%dx%d  S=%.3f  vk=%s  landscape=%s",
        rs.w, rs.h, instance.scale or 0, tostring(instance.vk),
        tostring(instance.layout_landscape)))
    local c = container(root, 1)
    if c then
        local acc = 0
        for i = 1, #c do
            local ch = c[i]
            local cs = ch:getSize()
            acc = acc + cs.h
            print(string.format("[DIAG] %2d %-6s %5dx%-4d cum=%4d %s", i, kind(ch),
                cs.w, cs.h, acc, ch.is_gap and ("gap_h=" .. tostring(ch.gap_h)) or ""))
        end
        print(string.format("[DIAG] 合计 %d", acc))
    end
end
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
if Screensaver:close() ~= true then
    print("[FAIL] 唤醒时没有请求重绘（被接管的 close 必须返回 true）")
    os.exit(1)
end
if Device.screen_saver_mode then
    print("[FAIL] 唤醒后 screen_saver_mode 没有复位")
    os.exit(1)
end
EVENTS[#EVENTS + 1] = "== 休眠（看板已打开）：复用当前画面，唤醒请求全屏重绘 =="

-- ============ 点按展开：坐标命中 + 列表菜单 ============
-- 摆放位置靠「绘制时记录」而不是「按布局算」：版心居中、留白、间距拉伸都会
-- 影响盒子的绝对坐标，重算一份必然和真实绘制对不上。这条用例就是守着这条链路：
-- 摆上可展开组件 -> 真的画一遍 -> 坐标有了 -> 坐标内的点被吃掉、坐标外的点放行。
-- 坐标内/坐标外两条路都要走一遍。写成函数而不是 do…end：桩件主 chunk 的
-- 局部变量已经贴着 200 个上限，do 块里的局部变量会和主 chunk 的抢寄存器。
local function check_zone_tap()
    -- 出图时 STUB_ZONES 已经把版面配好了，这里必须先存下来：用例结束时若直接
    -- resetZoneLayout，最终帧就退回默认版面，预览图会画成另一套（踩过）。
    local saved_layout = G_reader_settings:readSetting("dashboard_components")
    local orient_t = instance.layout_landscape and "landscape" or "portrait"
    local zone_t = (orient_t == "portrait") and "A" or "B"
    local other_t = (orient_t == "portrait") and "B" or "C"
    instance:setZoneComponent(orient_t, zone_t, "countdown")
    instance:setZoneComponent(orient_t, other_t, "todo")
    instance:refreshLayout()

    local rec = instance.zone_hits and instance.zone_hits[zone_t]
    if not (rec and rec.x and rec.y) then
        print("[FAIL] 可展开组件没有在绘制时记录盒子坐标")
        os.exit(1)
    end
    if rec.w <= 0 or rec.h <= 0 then
        print("[FAIL] 记录的盒子尺寸不对")
        os.exit(1)
    end

    local handler
    for _, z in ipairs(instance.root._zones or {}) do
        if z.id == "dashboard_zone_tap" then handler = z.handler end
    end
    if not handler then
        print("[FAIL] 没有注册可展开组件的点按区")
        os.exit(1)
    end

    if handler({ pos = { x = rec.x + math.floor(rec.w / 2), y = rec.y + 5 } }) ~= true then
        print("[FAIL] 点在倒数日卡片上没有吃掉事件（会去刷新天气）")
        os.exit(1)
    end
    if not (instance.menu_open and instance.menu and instance.menu.item_count > 1) then
        print("[FAIL] 点卡片没有弹出列表菜单")
        os.exit(1)
    end
    instance:closeMenu()
    if instance.menu_open then
        print("[FAIL] 列表菜单关不掉，menu_open 卡住会阻断以后的重新布局")
        os.exit(1)
    end

    -- 盒子之外必须是 false：框架要继续问下一个触摸区（点按刷新）
    if handler({ pos = { x = 1, y = 1 } }) ~= false then
        print("[FAIL] 点在空白处也把事件吃掉了，点按刷新会失效")
        os.exit(1)
    end

    if saved_layout then
        G_reader_settings:saveSetting("dashboard_components", saved_layout)
    else
        instance:resetZoneLayout()
    end
    instance:refreshLayout()
    EVENTS[#EVENTS + 1] = "== 点按展开：命中卡片弹出列表、空白处放行 =="
end
check_zone_tap()

-- 时钟控件必须真的挂在控件树里。纵向拉伸会反复试算版式，而 buildPortrait 每次
-- 都会把 self.clock_widget 指向当次建的控件——一旦留着被否决那一版，
-- tick 就在刷新一棵没显示的树，钟会彻底停住（画面看不出来，日志也没错）。
--
-- 前提是「当前版式里确实有时钟组件」：把 A 区换成大字时钟、纯天气、在读卡之后，
-- 版式里可能一个时钟都没有（比如 纯天气 + 空气明细 + 日月）。那种情况下
-- clock_widget 应该保持 nil，而不是指向一个上一版留下的控件。
local function in_tree(node, target, depth)
    if node == target then return true end
    if type(node) ~= "table" or depth > 6 then return false end
    for i = 1, #node do
        if node[i] == target then return true end
        if in_tree(node[i], target, depth + 1) then return true end
    end
    return false
end
local function zone_component(key)
    -- 合并成一个函数是为了少占一个主 chunk 局部变量（上限 200，已经贴边）
    local lay = instance:getZoneLayout()
    return instance:componentRegistry()[lay[instance.layout_landscape and "landscape"
        or "portrait"][key]]
end
local has_clock = false
for _, key in ipairs({ "A", "B", "C" }) do
    local comp = zone_component(key)
    if comp and comp.has_clock then has_clock = true end
end
if has_clock then
    if not instance.clock_widget or not in_tree(instance.root, instance.clock_widget, 0) then
        print("[FAIL] 版式里有钟，但时钟控件不在控件树里（重排时选错了那一版，时钟将不再刷新）")
        os.exit(1)
    end
elseif instance.clock_widget then
    print("[FAIL] 版式里没有钟，却还留着 clock_widget 引用（会在旧树上刷新）")
    os.exit(1)
end
EVENTS[#EVENTS + 1] = string.format("== 时钟控件在树内（版式含钟 = %s），纵向拉伸档位 vk=%.2f ==",
    tostring(has_clock), instance.vk or 1)

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

-- 菜单里改方向：必须「选完就自动关菜单 + 立刻按新方向重排」。
-- 真凶是 TouchMenu:onMenuSelect 的分支：
--   if item.checked or item.checked_func then self:updateItems()   -- 只刷新，不关菜单
--   elseif not item.keep_menu_open then self:closeMenu() end        -- 普通项才自动关
-- 所以版式子项必须是**普通叶子项**，带勾选就永远不会自动关菜单。
local function reopen_menu()
    for _, z in ipairs(instance.root._zones or {}) do
        if z.id == "dashboard_swipe_down" then down_zone = z end
    end
    down_zone.handler({ direction = "south" })
    return MENU_SHOWN
end
local menu3 = reopen_menu()
-- v2.60 起版式三项挂在「外观」的第一屏（其后是竖屏布局 / 横屏布局 / 复制 / 恢复）。
-- 不能按「恰好 3 项」找，也不能只判首项含「竖屏」——「竖屏布局」同样以这两个字
-- 开头，会把匹配抢走（v2.54 踩过）。
local orient_item
for _, it in ipairs(menu3.tab or {}) do
    if it.text == T("外观") and it.sub_item_table then orient_item = it end
end
if not orient_item then
    print("[FAIL] 菜单里找不到「外观」子菜单")
    os.exit(1)
end
for i, sub in ipairs(orient_item.sub_item_table) do
    if sub.checked or sub.checked_func then
        print(string.format("[FAIL] 版式第 %d 项带了 checked_func：TouchMenu 对勾选项"
            .. "只 updateItems、不关菜单，真机上会点了没反应", i))
        os.exit(1)
    end
end
-- 当前方向要用文字标出来，否则用户看不出现在是哪个
local marked = 0
for _, sub in ipairs(orient_item.sub_item_table) do
    if sub.text:find(T("（当前）"), 1, true) then marked = marked + 1 end
end
if marked ~= 1 then
    print("[FAIL] 版式菜单没有（或重复）标出「当前」方向")
    os.exit(1)
end
local layout_before_menu = instance.layout_landscape
-- 子项顺序：竖屏 / 横屏（向右 90°）/ 横屏（向左 90°）。
-- 选「与当前相反」的那一项，否则从横屏起步的组合里选了横屏，版式本来就不该变。
local pick = layout_before_menu and 1 or 2
local picked = orient_item.sub_item_table[pick]
-- 【真机对齐】只调 callback，**不模拟** TouchMenu 那条自动关闭分支：
-- 设备上 onMenuSelect 的 `elseif not keep_menu_open then closeMenu()` 实测没关掉菜单，
-- 所以菜单必须由 callback 自己撤。能这么测，说明代码不再依赖框架的关闭行为。
picked.callback(MENU_SHOWN)
if instance.menu_open then
    print("[FAIL] 菜单里选完方向后菜单没有自动关闭")
    os.exit(1)
end
if instance.menu ~= nil then
    print("[FAIL] 菜单关闭后 self.menu 没有清空（以后会一直误判菜单还开着）")
    os.exit(1)
end
local menu_still_shown = false
for _, w in ipairs(stack) do
    if w == menu3 then menu_still_shown = true end
end
if menu_still_shown then
    print("[FAIL] 菜单控件没有被撤掉")
    os.exit(1)
end
if instance.pending_orientation ~= nil then
    print("[FAIL] 方向切换没有执行，还挂在 pending_orientation 上")
    os.exit(1)
end
if instance.layout_landscape == layout_before_menu then
    print("[FAIL] 菜单里选了横屏，版式却没变")
    os.exit(1)
end
-- 框架在 onMenuSelect 返回后可能还会自己走一次 closeMenu()（→ close_callback），
-- 这一次必须幂等：不能把版式再切回去，也不能重新弹窗
local layout_after = instance.layout_landscape
MENU_SHOWN:closeMenu()
if instance.layout_landscape ~= layout_after or instance.menu_open then
    print("[FAIL] 菜单的关闭回调被重复触发后，版式/菜单状态被二次改动")
    os.exit(1)
end
EVENTS[#EVENTS + 1] = "== 菜单里选方向：菜单自动关闭且版式立刻切换 =="

-- 兜底：self.menu 引用丢失 + callback 不带参（真机两种异常都出现过）
-- 这时只能按 _dashboard_menu 标记去窗口栈里把菜单揪出来撤掉，绝不能留下一个关不掉的菜单
local menu5 = reopen_menu()
instance.menu = nil
local orient_item5
for _, it in ipairs(menu5.tab or {}) do
    -- 同上：版式三项现在挂在「外观」下，前 3 项就是竖屏 / 横屏 / 横屏
    if it.text == T("外观") and it.sub_item_table then orient_item5 = it end
end
local layout_before_orphan = instance.layout_landscape
orient_item5.sub_item_table[layout_before_orphan and 1 or 2].callback()
for _, w in ipairs(stack) do
    if w == menu5 then
        print("[FAIL] self.menu 丢失时菜单没被兜底撤掉（屏幕上会留个关不掉的菜单）")
        os.exit(1)
    end
end
if instance.layout_landscape == layout_before_orphan then
    print("[FAIL] self.menu 丢失时选方向没生效")
    os.exit(1)
end
EVENTS[#EVENTS + 1] = "== 兜底：self.menu 丢失 + 菜单不传参，仍能关菜单并转向 =="

-- 菜单开着的时候休眠：屏幕停的是菜单，不能把菜单冻成屏保
reopen_menu()
local stack_before_sleep2 = #stack
stub_sleep()
if instance.menu_open or instance.menu ~= nil then
    print("[FAIL] 休眠时没有撤掉开着的菜单（屏保会定格成菜单）")
    os.exit(1)
end
if instance.saver_root then
    print("[FAIL] 看板已打开时休眠不该另建屏保树")
    os.exit(1)
end
if #stack ~= stack_before_sleep2 - 1 then
    print("[FAIL] 撤菜单后控件栈层数不对")
    os.exit(1)
end
Screensaver:close()
if instance._resume_ts == nil then
    print("[FAIL] 唤醒后没有记录唤醒时刻，天气会在唤醒瞬间同步拉取")
    os.exit(1)
end
EVENTS[#EVENTS + 1] = "== 菜单开着时休眠：先撤菜单再定格看板 =="

-- 唤醒要重建版面：定时器走 CLOCK_MONOTONIC，休眠期间不走，
-- 唤醒后最多还要再等一整分钟才到点，这一分钟里屏幕上是睡前的时钟。
local root_before_wake = instance.root
instance._resume_ts = nil
stub_sleep()
Screensaver:close()
if instance.root == root_before_wake then
    print("[FAIL] 唤醒后没有重建版面（时钟/电量会停在休眠前）")
    os.exit(1)
end
EVENTS[#EVENTS + 1] = "== 唤醒后重建版面并重置定时器 =="

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

-- STUB_DUMP_CIRCLES=1：把每一笔 paintCircle 的坐标打出来。
-- 「真机上多出几个孤立墨点」这类问题，判断它是布局问题还是图标原语问题，
-- 靠这一份坐标最快：坐标落在图标方框里、却又不对应任何 shapes 条目，
-- 那就是 Icon:paintTo 自己把圆传错了位置。
if os.getenv("STUB_DUMP_CIRCLES") then
    print("---------- 圆形原语 ----------")
    for _, r in ipairs(RECORD) do
        if r.kind == "circle" then
            print(string.format("[圆] cx=%.2f cy=%.2f r=%.2f lw=%s color=%s",
                r.cx, r.cy, r.r, tostring(r.lw), tostring(r.color)))
        end
    end
end

-- STUB_DUMP_IMAGES=1：列出所有走位图路径的图标。
-- 用来回答「图标到底有没有换成预渲染 PNG」——空清单说明全退回矢量绘制了
-- （多半是 icons/ui 里缺那个边长，或文件名后缀对不上）。
if os.getenv("STUB_DUMP_IMAGES") then
    print("---------- 位图图标 ----------")
    for _, r in ipairs(RECORD) do
        if r.kind == "image" and tostring(r.text):find("/ui/", 1, true) then
            print(string.format("[图] %-22d %s  (%dx%d)",
                r.x, r.text:match("[^/]+$") or r.text, r.w, r.h))
        end
    end
end

-- 电量与操作提示必须真的出现在画面上（不是只写进代码）
-- 期望值跟桩件的 powerd 走，不写死 "78%"：预览要改电量（STUB_POWER）时才不会
-- 出现「界面 58 / 断言 78」的自相矛盾。不另起局部变量——主 chunk 已到 200 上限。
local has_pct, has_hint = false, false
local pct_text, hint_text
for _, r in ipairs(RECORD) do
    if r.kind == "text" then
        local t = tostring(r.text)
        if t:find(tostring(_G.STUB_POWERD.capacity) .. "%", 1, true) then
            has_pct = true; pct_text = t
        end
        -- 判据取两语都有的 "Swipe up" / "上划退出"，靠 hintLine() 的真值更稳
        if t == instance:hintLine() then has_hint = true; hint_text = t end
    end
end
if not has_pct then
    print("[FAIL] 画面上没有电量百分比（桩件电量 "
        .. tostring(_G.STUB_POWERD.capacity) .. "%）")
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
-- 断言要与「整数取整」对齐：mkPad 的高度是整数，vk=1.05 时 6*1.05=6.3→6，
-- 这一行本来就不会长高。所以先算出「按当前 vk 应当长大的行数」，再逐一比对，
-- 而不是简单地要求 grew>0（v2.44 分区盒子填满后 gap 变小，旧的写法会误报）。
local vk_now = instance.vk or 1
local expect = 0
for i = 1, #group do
    local row = group[i]
    if row.is_gap and row.gap_h
        and math.floor((row.dimen.h / vk_now) * vk_now) > row.gap_h then
        expect = expect + 1
    end
end
if vk_now > 1 and expect > 0 and grew ~= expect then
    print(string.format("[FAIL] 留白拉伸行数不符：应 %d 行、实 %d 行（vk=%.2f）",
        expect, grew, vk_now))
    os.exit(1)
end
if vk_now <= 1 and grew > 0 then
    print("[FAIL] vk=1 却拉伸了留白行，说明倍率计算错位")
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
    -- 圆记录的是圆心与半径，没有 x/y/w/h：先换算成包围盒再判边界。
    -- （这条断言一直只认矩形类，v2.54 起组件开始画圆，才暴露出它会把每个圆
    --   都判成 (0,0) 0x0 越界。）
    local x, y, w, h
    if r.kind == "circle" then
        local rr = r.r or 0
        x, y, w, h = (r.cx or 0) - rr, (r.cy or 0) - rr, rr * 2, rr * 2
    else
        x, y, w, h = r.x or 0, r.y or 0, r.w or 0, r.h or 0
    end
    local is_bg = (r.kind == "rect" and r.color ~= 255 and w >= VW and h >= VH)
    if not is_bg and r.kind ~= "exec" then
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

-- 模拟跨分钟 tick。
-- 版式里可能没有钟（纯天气 / 在读卡 / 日月 这类组合），这时 clock_widget 为 nil，
-- 断言要跟着版式走，否则一换组件就得改测试。
instance:tick()
if instance.clock_widget then
    EVENTS[#EVENTS + 1] = string.format("== tick() 通过，时钟控件文本 = %s，定时器 = %d ==",
        instance.clock_widget.text, #timers)
else
    EVENTS[#EVENTS + 1] = string.format(
        "== tick() 通过（版式无钟，跳过时钟文本），定时器 = %d ==", #timers)
end

-- 唤醒宽限期：休眠之后天气必然过期，如果唤醒第一拍 tick 就去同步拉取，
-- 正好卡在用户按电源键的那一刻（http.TIMEOUT = 20 秒，最坏能卡一分多钟）
instance.weather.ts = 0                    -- 强制过期，正常逻辑一定会拉
instance.last_fetch_ts = os.time() - 7200  -- 上次尝试是睡前（两小时前），不是刚刚
instance._resume_ts = os.time()
instance:tick()
if instance.weather.ts ~= 0 then
    print("[FAIL] 唤醒宽限期内还是去拉天气了，会把唤醒拖成卡死")
    os.exit(1)
end
instance.weather.ts = 0
instance.last_fetch_ts = os.time() - 7200
instance._resume_ts = os.time() - 3600     -- 宽限期过了
instance:tick()
if instance.weather.ts == 0 then
    print("[FAIL] 宽限期过后仍然不拉天气，天气会一直停在旧数据")
    os.exit(1)
end
instance._resume_ts = nil
EVENTS[#EVENTS + 1] = "== 唤醒宽限期内不拉天气，之后再拉 =="

-- 定时器基于 CLOCK_MONOTONIC，休眠期间不走；两拍 tick 相隔过久要直接重建版面
local root_before_gap = instance.root
instance._last_tick_ts = os.time() - 3600
instance:tick()
if instance.root == root_before_gap then
    print("[FAIL] tick 间隔异常（休眠过）却没有重建版面，时钟会停在旧时间")
    os.exit(1)
end
EVENTS[#EVENTS + 1] = "== tick 间隔异常（休眠）后自动重建版面 =="

-- 省电：时钟粒度 / 仅触摸 / 低电保护 / 失败退避。
-- 用立即执行函数而不是 `local function`：主 chunk 的 local 已经贴着 200 上限，
-- 再加一个顶层 local 会直接 "too many local variables"。
;(function()
    local function fail(msg)
        print("[FAIL] " .. msg)
        os.exit(1)
    end

    -- 1) 5 分钟粒度：下一拍要落在整 5 分边界，即 1..300 秒
    G_reader_settings:saveSetting("dashboard_tick_step", 5)
    timers = {}
    instance:scheduleTick()
    local d = timers[#timers] and timers[#timers].delay or -1
    if d < 1 or d > 300 then
        fail(string.format("5 分钟粒度排出的间隔是 %.1f 秒，应落在 1..300", d))
    end

    -- 2) 0 = 仅触摸：不该再排定时器
    G_reader_settings:saveSetting("dashboard_tick_step", 0)
    timers = {}
    instance:scheduleTick()
    if #timers > 0 then
        fail("「只在触摸时刷新」仍然排了定时器")
    end

    -- 3) 低电：天气早已过期也不拉，且时钟粒度抬到 30 分钟
    G_reader_settings:saveSetting("dashboard_tick_step", 5)
    G_reader_settings:saveSetting("dashboard_low_battery", 10)
    local orig_battery = instance.batteryInfo
    instance.batteryInfo = function() return 8, false end
    instance._batt_cache = nil
    instance.weather.ts = 0
    instance._resume_ts = nil
    instance._last_tick_ts = os.time()
    instance:tick()
    if instance.weather.ts ~= 0 then
        fail("电量 8% 时仍然去拉天气")
    end
    if instance:tickStep() < 30 then
        fail("电量 8% 时时钟粒度没有降到 30 分钟")
    end
    instance.batteryInfo = function() return 8, true end
    instance._batt_cache = nil
    if instance.tickStep(instance) ~= 5 then
        fail("充电状态下不该降频")
    end
    instance.batteryInfo = orig_battery
    instance._batt_cache = nil
    G_reader_settings:saveSetting("dashboard_low_battery", 0)

    -- 4) 失败退避：无数据 + 连续失败 2 次 + 10 分钟前试过 → 不该再请求
    --    （5 分钟基准 × 2^2 = 20 分钟，10 分钟还没到）
    instance.weather = nil
    instance.fetch_fails = 2
    instance.last_fetch_ts = os.time() - 600
    instance._resume_ts = nil
    instance._last_tick_ts = os.time()
    instance:tick()
    if instance.weather ~= nil then
        fail("连续失败 2 次后 10 分钟就重试，退避没生效")
    end
    -- 退避清零后，同样过了 10 分钟就该允许重试（门槛 5 分钟）
    instance.fetch_fails = 0
    instance.last_fetch_ts = os.time() - 600
    instance:tick()
    if instance.weather == nil then
        fail("退避清零后仍不重试，天气会一直空着")
    end

    -- 5) 省电菜单结构：4 组，各自的选项数与预设一致
    local pm = instance:genPowerMenu()
    local want = { 6, 4, 5, 5 }
    if #pm ~= 4 then
        fail("省电菜单应有 4 组，实际 " .. #pm)
    end
    for i = 1, 4 do
        local sub = pm[i] and pm[i].sub_item_table or {}
        if #sub ~= want[i] then
            fail(string.format("省电菜单第 %d 组应有 %d 个选项，实际 %d", i, want[i], #sub))
        end
    end

    pcall(function() G_reader_settings:delSetting("dashboard_tick_step") end)
    pcall(function() G_reader_settings:delSetting("dashboard_low_battery") end)
end)()
EVENTS[#EVENTS + 1] = "== 省电：5 分钟粒度 / 仅触摸 / 低电降频且不拉天气 / 失败退避 =="

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
if shown.wind_dir ~= I18n.windDir(185) then
    mismatches[#mismatches + 1] = "风向（185° 应为 " .. tostring(I18n.windDir(185)) .. "）"
end
if mismatches[1] then
    print("[FAIL] 字段不符: " .. table.concat(mismatches, "，"))
    os.exit(1)
end

-- 七日预报与 6 项污染物（v2.45 数据层）。
-- 只验 AQI 是不够的：预报组件吃的是 weather.daily，「空气明细」吃的是 air.parts，
-- 这两处少一天/少一项，界面上就是一片 "--"，必须在这里卡住。
local daily = w.daily
if type(daily) ~= "table" then
    print("[FAIL] weather.daily 缺失（七日预报没解析出来）")
    os.exit(1)
end
if #daily ~= 7 then
    print(string.format("[FAIL] weather.daily 应有 7 天，实际 %d 天", #daily))
    os.exit(1)
end
local d1 = daily[1]
local date_ok = type(d1.date) == "table" and d1.date.y == 2026
    and d1.date.m == 11 and d1.date.d == 11
if not date_ok then
    print("[FAIL] daily[1].date 没从 forecastStartTime 取对（接口没有 date 字段）")
    os.exit(1)
end
if not near(d1.tmax, 14.1) or not near(d1.tmin, 0.56) then
    print("[FAIL] daily[1] 最高/最低温不对")
    os.exit(1)
end
if d1.sunrise ~= "06:54" or d1.sunset ~= "17:02" then
    print("[FAIL] daily[1] 日出日落不对: " .. tostring(d1.sunrise) .. "/" .. tostring(d1.sunset))
    os.exit(1)
end
if d1.moonphase ~= "waxing-crescent" then
    print("[FAIL] daily[1].moonphase 没解析出来: " .. tostring(d1.moonphase))
    os.exit(1)
end
if d1.cond ~= "晴" or d1.ncond ~= "夜" then
    print("[FAIL] daily[1] 白天/夜间现象不对: "
        .. tostring(d1.cond) .. "/" .. tostring(d1.ncond))
    os.exit(1)
end

local parts = instance.air and instance.air.parts
if type(parts) ~= "table" or #parts ~= 6 then
    print(string.format("[FAIL] air.parts 应有 6 项污染物，实际 %s",
        type(parts) == "table" and tostring(#parts) or "缺失"))
    os.exit(1)
end
local co
for _, p in ipairs(parts) do
    if p.code == "co" then co = p end
end
if not co then
    print("[FAIL] air.parts 里没有 CO")
    os.exit(1)
end
if co.unit ~= "mg/m³" then
    print("[FAIL] CO 单位应为 mg/m³，实际 " .. tostring(co.unit))
    os.exit(1)
end
if instance.air.primary ~= "pm2p5" then
    print("[FAIL] 首要污染物应取 indexes[0].primaryPollutant = pm2p5，实际 "
        .. tostring(instance.air.primary))
    os.exit(1)
end
EVENTS[#EVENTS + 1] = string.format(
    "== 数据层：daily %d 天（首日 %04d-%02d-%02d %s），污染物 %d 项（CO %s %s），首要 %s ==",
    #daily, d1.date.y, d1.date.m, d1.date.d, tostring(d1.cond), #parts,
    tostring(co.value), tostring(co.unit), tostring(instance.air.primary))

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
if instance:sourceLabel() ~= T("天气 Open-Meteo（降级）") then bad[#bad + 1] = "来源标签" end
-- 降级源也要撑起七日预报与 6 项污染物（否则装了一周预报组件就是一格 "--"）
if type(w2.daily) ~= "table" or #w2.daily ~= 7 then
    bad[#bad + 1] = "降级源的 daily 应有 7 天"
end
local d2 = type(w2.daily) == "table" and w2.daily[1]
if d2 and (not d2.date or d2.date.m ~= 11 or d2.date.d ~= 11) then
    bad[#bad + 1] = "降级源 daily[1].date（应从 time 字段取到 2026-11-11）"
end
if d2 and d2.code ~= 100 then
    bad[#bad + 1] = "降级源 daily[1] 现象（WMO 0 应映射成和风 100）"
end
local dparts = instance.air and instance.air.parts
if type(dparts) ~= "table" or #dparts ~= 6 then
    bad[#bad + 1] = "降级源 air.parts 应有 6 项"
end
-- CO：Open-Meteo 给 μg/m³，界面统一按 mg/m³ 显示，2634 μg → 2.634 mg
local dco
for _, p in ipairs(dparts or {}) do
    if p.code == "co" then dco = p end
end
if not dco or not near(dco.value, 2.634, 0.001) or dco.unit ~= "mg/m³" then
    bad[#bad + 1] = "降级源 CO 应换算成 2.634 mg/m³"
end
if bad[1] then
    print("[FAIL] 降级字段不符: " .. table.concat(bad, "，"))
    os.exit(1)
end
EVENTS[#EVENTS + 1] = string.format(
    "== 降级：%s %.1f° 代码 %d 日出 %s 日落 %s AQI %s（%s）==",
    tostring(w2.cond), w2.temp, w2.code, tostring(w2.sunrise), tostring(w2.sunset),
    instance:airDisplay().text, tostring(instance:sourceLabel()))

if _G.STUB_FRAME then
    -- 预览模式：上面那条降级用例刚把数据换成 Open-Meteo，直接出图会得到一张
    -- 「天气 Open-Meteo（降级）」的版面。出图前切回和风重拉一次，按正常数据重排。
    if os.getenv("STUB_PREVIEW") then
        _G.STUB_QW_FAIL = false
        instance.weather, instance.air = nil, nil
        pcall(function() instance:fetchWeather(true) end)
        if instance.shown then pcall(function() instance:refreshLayout() end) end
    end
    -- 原语自检页替换掉真实版面，只走「记录 → 出图」这一条链
    if _G.STUB_PRIMITIVES then
        FRAME.primitives()
    else
        FRAME.dump()
    end
end
-- 渲染开关只在上面那次 dump 时有效：撤掉它，否则后面的「无设置应回落默认」
-- 与中文文案断言会全部失败（这两个断言正是用来防止配置被悄悄改坏的）
if _env_zones or _env_lang then
    store["dashboard_components"] = nil
    store["dashboard_lang"] = nil
    require("dashboard_i18n").setLang("zh")
end

-- ============ 组件矩阵：所有组件 × 该组件允许的区 × 本尺寸 ============
-- 目的：任何组件放进任何「白名单允许的区」，都不能超过盒子高度**和宽度**。
--   · k=1 就装下     → 理想，正常字号
--   · 需要缩字       → 允许（K_LADDER 会缩），但记下来，缩多了观感差
--   · 最小档仍溢出   → 硬伤：真机上会撑破版心、触发全局缩放，判 FAIL
-- 宽和高都要查：v2.45 的空气明细三列排布只溢出宽度、不溢出高度，
-- 只看高度的断言放过了它，最后是在渲染图里看到文字顶到屏幕外才发现的。
-- 盒子尺寸一律从 main.lua 的 zoneSpec/contentBox/lowerWidths 取，不另写常数。
local Lunar2 = require("dashboard_lunar")
_G.STUB_QW_FAIL = false
pcall(function() instance:fetchWeather(true) end)

local S_m, edge_m, avail_m = instance:contentBox(SW, SH)
local spec_m = instance:zoneSpec()
local orient_m = instance.layout_landscape and "landscape" or "portrait"
local ctx_m = {
    W = SW, H = SH, landscape = (orient_m == "landscape"),
    now = instance:localNow(), tz = instance:getTz(),
    city = instance:getCity(), S = S_m, edge = edge_m, body_w = avail_m,
}
ctx_m.lunar = Lunar2.solar_to_lunar(ctx_m.now.year, ctx_m.now.month, ctx_m.now.day)
ctx_m.cur_term, ctx_m.next_term = Lunar2.current_term(ctx_m.now.year, ctx_m.now.month,
    ctx_m.now.day, ctx_m.tz.offset)

-- v2.53：盒子里套一层卡片，组件能用的高/宽都要先扣掉卡片内边距（card_pad）。
-- 这里跟 buildZone 用同一份 spec 与同一个算法，改了一边另一边不会偷偷跑偏。
local function matrixBox(orient, key)
    local spec_o = spec_m[orient]
    local cpad = math.floor(spec_o.card_pad * S_m)
    if orient == "portrait" then
        local box_h = math.floor(spec_o[key] * S_m)
        return avail_m, box_h - cpad * 2, avail_m - cpad * 2
    end
    if key == "A" then
        local box_h = math.floor(spec_o.A * S_m)
        return avail_m, box_h - cpad * 2, avail_m - cpad * 2
    end
    local bw, cw = instance:lowerWidths(avail_m, S_m)
    local w = (key == "B") and bw or cw
    local box_h = math.floor(spec_o.lower * S_m)
    return w, box_h - cpad * 2, w - cpad * 2
end

local ladder = instance:kLadder()
local m_fail, m_shrink, m_ok, m_total = {}, {}, 0, 0
-- 宽高一起判：返回空串表示装得下，否则返回「哪个方向、差多少」
local function unfit(unit, box_h, content_w)
    local s, bad = unit:getSize(), {}
    if s.h > box_h then
        bad[#bad + 1] = string.format("高 %d>%d", math.floor(s.h), math.floor(box_h))
    end
    if s.w > content_w + 1 then
        bad[#bad + 1] = string.format("宽 %d>%d", math.floor(s.w), math.floor(content_w))
    end
    return table.concat(bad, "、")
end
for id, comp in pairs(instance:componentRegistry()) do
    for _, key in ipairs(comp.zones[orient_m] or {}) do
        m_total = m_total + 1
        local box_w, box_h, content_w = matrixBox(orient_m, key)
        local okc, child = pcall(function()
            return instance[comp.build](instance, ctx_m, content_w, box_h, 1)
        end)
        if not okc then
            m_fail[#m_fail + 1] = string.format("%s@%s/%s 构建异常: %s",
                id, orient_m, key, tostring(child))
        else
            local why = unfit(child, box_h, content_w)
            if why == "" then
                m_ok = m_ok + 1
            else
                local fitted, last_why = nil, why
                for i = 2, #ladder do
                    local c2 = instance[comp.build](instance, ctx_m, content_w, box_h, ladder[i])
                    last_why = unfit(c2, box_h, content_w)
                    if last_why == "" then fitted = ladder[i] break end
                end
                if fitted then
                    m_shrink[#m_shrink + 1] = string.format("%s@%s/%s %s(k=%.2f)",
                        id, orient_m, key, why, fitted)
                else
                    m_fail[#m_fail + 1] = string.format("%s@%s/%s 最小档仍溢出 %s",
                        id, orient_m, key, last_why)
                end
            end
        end
    end
end
if m_fail[1] then
    print("[FAIL] 组件矩阵（" .. orient_m .. "）:" .. table.concat(m_fail, "；"))
    os.exit(1)
end
EVENTS[#EVENTS + 1] = string.format(
    "== 组件矩阵（%s）：%d 个组合全部装下（k=1 %d 个，需缩字 %d 个%s）==",
    orient_m, m_total, m_ok, #m_shrink,
    #m_shrink > 0 and ("：" .. table.concat(m_shrink, "，")) or "")

-- ============ 在读卡：活文档优先、lastfile 兜底 ============
-- 两条路各有各的坑：活文档拿不到时要能退到侧车（屏保场景），
-- 侧车读不到时还要能用文件名兜住（新书还没生成侧车）。三种情况都走一遍。
local function fake_ds(title, authors, pages, pct)
    return {
        readSetting = function(_, key)
            if key == "stats" then
                return { title = title, authors = authors, pages = pages }
            elseif key == "percent_finished" then
                return pct
            end
            return nil
        end,
    }
end

local ds_calls = 0
-- 换模块前必须清缓存：出预览图时（STUB_READING）前面已经 require 过一次 docsettings，
-- package.loaded 里躺着那个假 DocSettings，这里光换 package.preload 是不生效的。
package.loaded["docsettings"] = nil
package.preload["docsettings"] = function()
    return {
        open = function(_, path)
            ds_calls = ds_calls + 1
            return fake_ds("侧车书名 " .. path:match("[^/]+$"), "侧车作者", 640, 0.42)
        end,
    }
end
G_reader_settings:saveSetting("lastfile", "/mnt/us/documents/测试书.epub")
local r_last = instance:readingInfo()
if not r_last or r_last.source ~= "last" then
    print("[FAIL] lastfile 兜底没生效：" .. tostring(r_last and r_last.source))
    os.exit(1)
end
if not tostring(r_last.title):find("测试书", 1, true) or r_last.percent ~= 0.42 or r_last.pages ~= 640 then
    print(string.format("[FAIL] lastfile 侧车字段没读全：%s / %s / %s / %s",
        tostring(r_last.title), tostring(r_last.authors), tostring(r_last.pages), tostring(r_last.percent)))
    os.exit(1)
end
EVENTS[#EVENTS + 1] = string.format("== 在读卡 lastfile 兜底：%s · %s · %d 页 · %.0f%%（侧车读 %d 次）==",
    r_last.title, r_last.authors, r_last.pages, r_last.percent * 100, ds_calls)

-- 活文档优先：同样有 lastfile 的情况下，活文档的书名必须赢
local saved_document, saved_doc_settings, saved_page
    = instance.ui.document, instance.ui.doc_settings, instance.ui.getCurrentPage
instance.ui.document = {
    getPageCount = function() return 500 end,
}
instance.ui.doc_settings = fake_ds("正在读的书", "某作者", 500, 0.25)
local r_live = instance:readingInfo()
if not r_live or r_live.source ~= "live" or r_live.title ~= "正在读的书" then
    print("[FAIL] 活文档没优先于 lastfile：" .. tostring(r_live and (r_live.source .. "/" .. tostring(r_live.title))))
    os.exit(1)
end

-- 没有 percent_finished 时用「当前页 / 总页数」兜底
instance.ui.doc_settings = fake_ds("只有页码的书", "某作者", nil, nil)
instance.ui.getCurrentPage = function() return 125 end
local r_page = instance:readingInfo()
if not r_page or math.abs((r_page.percent or -1) - 0.25) > 0.001 then
    print("[FAIL] 没有 percent_finished 时没按页码比例兜底：" .. tostring(r_page and r_page.percent))
    os.exit(1)
end
EVENTS[#EVENTS + 1] = string.format("== 在读卡活文档优先：%s · 页码兜底 %.0f%% ==",
    r_live.title, r_page.percent * 100)

-- v2.61 统计口径：速度用「已读时长 ÷ 已读书页」，剩余时长用「已读时长 × 剩余比例 ÷ 已读比例」。
-- 这两个口径都绕开了 statistics 表里的 total_read_pages（那是屏幕页，字号一变页数就变），
-- 所以下面钉死的是数值本身，不是「大致对」。
local f1 = instance:readingFacts({ percent = 0.25, pages = 640 },
    { read_time = 3600, read_pages = 100, last_open = os.time(), week_sec = 7200, week_days = 2 })
if f1.read_pages ~= 160 then
    print("[FAIL] 已读页数应按 percent × 总页数算：" .. tostring(f1.read_pages))
    os.exit(1)
end
if f1.used ~= "1 小时" or f1.remain ~= "3 小时" then
    print(string.format("[FAIL] 时长口径不对：累计 %s / 还要读 %s", tostring(f1.used), tostring(f1.remain)))
    os.exit(1)
end
if not f1.speed or not f1.eta then
    print("[FAIL] 样本足够时应给出速度与预计读完")
    os.exit(1)
end

-- 样本太少不许外推：一本刚翻两页的书按比例算会得出「还要 8 小时」这种假精度
local f2 = instance:readingFacts({ percent = 0.004, pages = 640 },
    { read_time = 186, read_pages = 2, last_open = os.time(), week_sec = 186, week_days = 1 })
if f2.speed or f2.remain or f2.eta then
    print("[FAIL] 统计不足 10 屏时不该给速度/剩余/预计")
    os.exit(1)
end

-- 近 7 天没读：日均会掉到 0，日期会跳到明年，宁可不给
local f3 = instance:readingFacts({ percent = 0.5, pages = 400 },
    { read_time = 7200, read_pages = 200, last_open = os.time() - 30 * 86400,
      week_sec = 0, week_days = 0 })
if f3.eta then
    print("[FAIL] 近 7 天没读过时不该给「预计几号读完」")
    os.exit(1)
end

-- 统计库整个取不到（用户关了统计插件）：只退成进度四项，不能崩、不能画空三栏
local f0 = instance:readingFacts({ percent = 0.42, pages = 640 }, nil)
if f0.read_pages ~= 269 or f0.used or f0.remain then
    print(string.format("[FAIL] 统计库缺失时应只剩进度：已读 %s 累计 %s",
        tostring(f0.read_pages), tostring(f0.used)))
    os.exit(1)
end
EVENTS[#EVENTS + 1] = string.format("== 阅读统计口径：1 小时/640 页 → 已读 %d 页、还要 %s；样本不足与无统计均不外推 ==",
    f1.read_pages, tostring(f1.remain))

-- 没有可显示的数时整行返回 nil：横屏那档上面有条分隔线，空控件会让线悬在半空。
-- 早先版本缺值补「—」，真机上一排三个破折号，看着像卡片坏了。
-- 注意分级：
--   f2  读了 186 秒、2 屏 → 「累计 3 分」这一项成立，仍要画（画一栏，不是三栏）
--   tiny 只读了 10 秒     → 连累计都凑不成整数分钟，整行不画
-- 用 do 收窄作用域：桩件主 chunk 的局部变量已接近 Lua 的 200 上限。
do
    local tiny = instance:readingFacts({ percent = 0.79, pages = 1858 },
        { read_time = 10, read_pages = 1, last_open = os.time(), week_sec = 10, week_days = 1 })
    if tiny.used or tiny.speed or tiny.remain then
        print("[FAIL] 只读 10 秒时不该有任何一栏有值")
        os.exit(1)
    end
    if instance:readingStatRow(ctx_m, 600, 1, tiny) ~= nil then
        print("[FAIL] 三栏全空时应返回 nil（整行不画）")
        os.exit(1)
    end
    if instance:readingStatRow(ctx_m, 600, 1, f0) ~= nil then
        print("[FAIL] 统计库缺失时三栏应整行不画（返回 nil）")
        os.exit(1)
    end
    if not instance:readingStatRow(ctx_m, 600, 1, f2) then
        print("[FAIL] 读了 3 分钟时应至少画出「累计」一栏")
        os.exit(1)
    end
    if not instance:readingStatRow(ctx_m, 600, 1, f1) then
        print("[FAIL] 样本足够时三栏应正常画出")
        os.exit(1)
    end
end

-- 在读卡排版：书名动辄二三十字，必须单行省略、不许把盒子顶破
local long_title = "一个特别特别长的书名用来测试省略号是不是真的生效以及不会把版面顶破"
instance.ui.doc_settings = fake_ds(long_title, "某作者", 500, 0.33)
local box_w_r, box_h_r, content_w_r = matrixBox(orient_m, orient_m == "portrait" and "B" or "C")
local card = instance:compReading(ctx_m, content_w_r, box_h_r, 1)
local cs_r = card:getSize()
if cs_r.h > box_h_r or cs_r.w > content_w_r + 1 then
    print(string.format("[FAIL] 在读卡超出盒子：%dx%d > %dx%d", cs_r.w, cs_r.h, content_w_r, box_h_r))
    os.exit(1)
end
local saw_title = false
local function scan(widget)
    if not widget then return end
    if widget.text and tostring(widget.text):find("省略号", 1, true) then saw_title = true end
    for _, ch in ipairs(widget) do scan(ch) end
end
scan(card)
if not saw_title then
    print("[FAIL] 在读卡里没有书名文本")
    os.exit(1)
end
EVENTS[#EVENTS + 1] = string.format(
    "== 在读卡 31 字书名装进 %dx%d 盒子（单行省略），排版 %dx%d ==",
    content_w_r, box_h_r, cs_r.w, cs_r.h)

-- ============ 在读卡封面：取位图 -> 写 PNG -> 下次读缓存 ============
-- 这条链路有三个容易出错的地方，逐个断言：
--   1. 封面是不是真的出现了（控件树里有 ImageWidget，且在盒子内）
--   2. PNG 是不是真的落盘了（拿控件里的路径去 io.open）
--   3. 第二次构建还要不要再打开一遍书（缓存命中就该 0 次 —— 屏保刷新不能每次都开书）
local function find_image(widget)
    if type(widget) ~= "table" then return nil end
    if widget.file and widget.width and widget.height then return widget end
    for _, ch in ipairs(widget) do
        local got = find_image(ch)
        if got then return got end
    end
    return nil
end

if _G.STUB_SETTINGS_DIR then
    -- 书名带本次运行的 id：出图时同一个进程会连着跑多张，缓存目录是共用的，
    -- 用固定书名的话第二次就是「缓存命中」，这条断言会假失败/假通过。
    local run_id = tostring(_G.STUB_RUN_ID or "run")
    G_reader_settings:saveSetting("lastfile", "/mnt/us/documents/有封面的书" .. run_id .. ".epub")
    instance.ui.document, instance.ui.doc_settings = nil, nil
    _G.COVER_OPENS = 0
    _G.STUB_COVER_MODE = "demo"

    local card_c = instance:compReading(ctx_m, content_w_r, box_h_r, 1)
    local img = find_image(card_c)
    if not img then
        print("[FAIL] 在读卡没有画出封面（控件树里找不到 ImageWidget）")
        os.exit(1)
    end
    local sc = card_c:getSize()
    if sc.h > box_h_r or sc.w > content_w_r + 1 then
        print(string.format("[FAIL] 带封面的在读卡超出盒子：%dx%d > %dx%d",
            sc.w, sc.h, content_w_r, box_h_r))
        os.exit(1)
    end
    local fh = io.open(img.file, "rb")
    local exists = fh ~= nil
    if fh then fh:close() end
    if not exists then
        print("[FAIL] 封面 PNG 没有落盘：" .. tostring(img.file))
        os.exit(1)
    end
    local opens_first = _G.COVER_OPENS or 0
    if opens_first ~= 1 then
        print(string.format("[FAIL] 首次取封面应该只打开 1 次书，实际 %d 次", opens_first))
        os.exit(1)
    end

    -- 第二次：缓存命中，不该再打开书
    local card_c2 = instance:compReading(ctx_m, content_w_r, box_h_r, 1)
    local img2 = find_image(card_c2)
    local opens_second = _G.COVER_OPENS or 0
    if not img2 or img2.file ~= img.file then
        print("[FAIL] 第二次构建封面路径变了，缓存没命中")
        os.exit(1)
    end
    if opens_second ~= opens_first then
        print(string.format("[FAIL] 缓存命中又打开了一次书：%d -> %d", opens_first, opens_second))
        os.exit(1)
    end

    -- 换一本没有封面的书：不该画封面，也不该把卡片搞崩
    G_reader_settings:saveSetting("lastfile", "/mnt/us/documents/没有封面的书" .. run_id .. ".epub")
    _G.STUB_COVER_MODE = "none"
    local card_n = instance:compReading(ctx_m, content_w_r, box_h_r, 1)
    if find_image(card_n) then
        print("[FAIL] 书上没有封面，卡片却画出了封面位")
        os.exit(1)
    end
    local saw_title_n = false
    local function scan_n(widget)
        if type(widget) ~= "table" then return end
        if widget.text and tostring(widget.text):find("没有封面的书", 1, true) then saw_title_n = true end
        for _, ch in ipairs(widget) do scan_n(ch) end
    end
    scan_n(card_n)
    if not saw_title_n then
        print("[FAIL] 没封面时在读卡的纯文字版也丢了书名")
        os.exit(1)
    end

    -- 打不开书（损坏 / 权限）：同样退回文字版，不许抛
    G_reader_settings:saveSetting("lastfile", "/mnt/us/documents/打不开的书" .. run_id .. ".epub")
    _G.STUB_COVER_MODE = "unopenable"
    local ok_u, card_u = pcall(function()
        return instance:compReading(ctx_m, content_w_r, box_h_r, 1)
    end)
    if not ok_u or not card_u then
        print("[FAIL] 打不开书时在读卡直接报错了：" .. tostring(card_u))
        os.exit(1)
    end
    if find_image(card_u) then
        print("[FAIL] 打不开书却画出了封面")
        os.exit(1)
    end

    _G.STUB_COVER_MODE = "demo"
    EVENTS[#EVENTS + 1] = string.format(
        "== 在读卡封面：%dx%d 装在 %dx%d 盒子里，首次打开书 %d 次、缓存命中不再打开、无封面与打不开都退回文字版 ==",
        img.width, img.height, content_w_r, box_h_r, opens_first)
end

-- 收尾：把活文档摘掉，后面的用例回到「没有在读文档」的状态
instance.ui.document, instance.ui.doc_settings = saved_document, saved_doc_settings
instance.ui.getCurrentPage = saved_page
G_reader_settings:saveSetting("lastfile", nil)
if instance:readingInfo() ~= nil then
    print("[FAIL] 摘掉活文档和 lastfile 之后仍有在读信息，不该画出一个空卡")
    os.exit(1)
end

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

-- ------------------------------------------------------------------ 首次配置提示
-- 前面的用例靠注入假凭据跑和风主路径，所以这里必须临时把凭据清掉，才能验证
-- 「缺凭据 -> 提示一次、配好后不再提示」这条真实分支。
local function has_setup_hint()
    for i = #stack, 1, -1 do
        local w = stack[i]
        if type(w) == "table" and type(w.text) == "string"
            -- 两种语言都提到 Open-Meteo，用它做判据，不绑死中文
            and w.text:find("Open-Meteo", 1, true) then
            return true
        end
    end
    return false
end

-- 有凭据时不该弹（open() 里已经跑过一次 maybeShowSetupHint）
if has_setup_hint() then
    print("[FAIL] 已经配好凭据还弹「未配置」提示")
    os.exit(1)
end

-- 注意：开发机上 dashboard_config.local.lua 是存在的，清 G_reader_settings 里的凭据
-- 也会被文件层重新补上，所以这里直接打桩 getConfig 来构造"确实没有凭据"的状态。
local real_get_config = instance.getConfig
local function use_config(host, key)
    instance.getConfig = function()
        return { qweather = { api_host = host, api_key = key } }
    end
end

-- 模拟 git clone 后的首次打开：没有凭据、没有"已提示"标记
use_config("", "")
G_reader_settings:saveSetting("dashboard_qw_hint_shown", nil)
instance:maybeShowSetupHint()
if not has_setup_hint() then
    print("[FAIL] 缺凭据时没有提示走了降级源（用户不会知道空气质量是估算值）")
    os.exit(1)
end
local stack_after_hint = #stack

-- 第二次调用必须被"已提示"标记挡住
instance:maybeShowSetupHint()
if #stack ~= stack_after_hint then
    print("[FAIL] 未配置提示会重复弹出，用户会被反复打扰")
    os.exit(1)
end

-- 配好凭据后，即使把标记清掉也不该再弹
use_config("stub.qweatherapi.com", "stub-key-0001")
G_reader_settings:saveSetting("dashboard_qw_hint_shown", nil)
instance:maybeShowSetupHint()
if #stack ~= stack_after_hint then
    print("[FAIL] 配好凭据后仍在提示未配置")
    os.exit(1)
end
instance.getConfig = real_get_config
EVENTS[#EVENTS + 1] = "== 未配置提示：缺凭据弹一次，配好后不再弹 =="

-- ================= 分区组件与多语言（v2.44）

-- 1) 没有设置时，三区必须回落到默认组件
-- v2.53 起 B 区默认是 today_actions（今日行动），不再是 lunar_term / calendar：
-- 面积最大的一块留给「今天要做什么」，农历仍可在菜单里选回来。
-- v2.62 起横屏 C 区默认是在读卡（原侧栏三合一）；侧栏仍可在菜单里选回来。
local lay = instance:getZoneLayout()
if lay.portrait.A ~= "clock_weather" or lay.portrait.B ~= "today_actions"
    or lay.portrait.C ~= "stats_cells" or lay.landscape.A ~= "clock_weather"
    or lay.landscape.B ~= "today_actions" or lay.landscape.C ~= "reading_now" then
    print("[FAIL] 无设置时没有回落到默认分区")
    os.exit(1)
end

-- 2) 脏数据 / 越区组件都要回落：side_panel 不许进竖屏 B，calendar 不许进横屏 C
G_reader_settings:saveSetting("dashboard_components", {
    portrait = { A = "nope", B = "side_panel", C = "calendar" },
    landscape = { A = "lunar_term", B = "side_panel", C = "calendar" },
})
local lay2 = instance:getZoneLayout()
if lay2.portrait.A ~= "clock_weather" or lay2.portrait.B ~= "today_actions"
    or lay2.portrait.C ~= "stats_cells" then
    print(string.format("[FAIL] 竖屏非法组件未回落：%s/%s/%s",
        lay2.portrait.A, lay2.portrait.B, lay2.portrait.C))
    os.exit(1)
end
if lay2.landscape.A ~= "clock_weather" or lay2.landscape.C ~= "reading_now" then
    print("[FAIL] 横屏越区组件未回落默认")
    os.exit(1)
end

-- 3) 每个组件在允许的每个区都能出画面，且内容不超出屏幕
local tried = 0
for _, orient in ipairs({ "portrait", "landscape" }) do
    for _, zone in ipairs({ "A", "B", "C" }) do
        for _, id in ipairs(instance:componentIdsFor(orient, zone)) do
            instance:setZoneComponent(orient, zone, id)
            -- 直接重建一次版面树来量尺寸：不依赖 self.shown/self.root 的状态，
            -- 也让每个组合都在「同一份上下文」下比较
            local root = instance:createRoot()
            local body = root[1] and root[1][1]
            if not body then
                print("[FAIL] 换组件后没有版面树")
                os.exit(1)
            end
            local bs = body:getSize()
            local sw, sh = screen.getWidth(), screen.getHeight()
            if bs.w > sw or bs.h > sh then
                print(string.format("[FAIL] %s/%s 放 %s 后超屏：%dx%d",
                    orient, zone, id, bs.w, bs.h))
                os.exit(1)
            end
            tried = tried + 1
            instance:resetZoneLayout()
        end
    end
end
EVENTS[#EVENTS + 1] = string.format("== 组件矩阵：%d 种组合逐一渲染不崩 ==", tried)

-- ============ 倒数日 / 待办（v2.47）============
-- 这一节只测数据层与菜单结构，不碰绘制：日期算法和输入解析是最容易写错、
-- 又最不容易在画面上看出来的部分（差一天、认错日期都不会崩，只是显示不对）。
-- 预览模式（STUB_AGENDA 注入了样例）跳过，免得把出图用的数据清掉。
local function check_agenda()
    local A = require("dashboard_agenda")
    local now = instance:localNow()
    local function fail(msg) print("[FAIL] " .. msg); os.exit(1) end

    -- 1) civil-days：与已知日历对齐（含闰年、世纪年）
    if A.daynum(1970, 1, 1) ~= 0 then fail("1970-01-01 不是第 0 天") end
    if A.daynum(2000, 3, 1) - A.daynum(2000, 2, 28) ~= 2 then
        fail("2000-02-28 → 03-01 应跨 2 天（2000 是闰年）")
    end
    if A.daynum(1900, 3, 1) - A.daynum(1900, 2, 28) ~= 1 then
        fail("1900 不是闰年，02-28 → 03-01 应只有 1 天")
    end
    for _, d in ipairs({ { 1970, 1, 1 }, { 2000, 2, 29 }, { 2026, 11, 12 }, { 2038, 1, 19 } }) do
        local y, m, dd = A.civilFromDays(A.daynum(d[1], d[2], d[3]))
        if y ~= d[1] or m ~= d[2] or dd ~= d[3] then
            fail(string.format("daynum/civil 往返不一致：%d-%d-%d", d[1], d[2], d[3]))
        end
    end
    if A.parseDate("2026-02-30") then fail("2 月 30 日被当成了合法日期") end

    -- 2) 输入解析（今天由时区决定，期望值也现算，不写死）
    local today = A.today(now)
    local ty, tm, td = A.parseDate(today)
    local function d_plus(n)
        local y, m, d = A.civilFromDays(A.daynum(ty, tm, td) + n)
        return A.fmtDate(y, m, d)
    end
    local function parse_ok(text, want_date, want_rest)
        local date, rest = A.parseEntry(text, now)
        if date ~= want_date or (want_rest and rest ~= want_rest) then
            fail(string.format("parseEntry(%q) = %s / %s，期望 %s / %s",
                text, tostring(date), tostring(rest), tostring(want_date), tostring(want_rest)))
        end
    end
    parse_ok("明天 交周报", d_plus(1), "交周报")
    parse_ok("买牛奶", nil, "买牛奶")
    parse_ok("12-25 买菜", string.format("%04d-12-25", ty), "买菜")
    parse_ok("圣诞节 2026-12-25", "2026-12-25", "圣诞节")
    parse_ok("2026年12月25日", "2026-12-25", "")
    local name, date = A.parseEvent("2026-12-25 圣诞节", now)
    if name ~= "圣诞节" or date ~= "2026-12-25" then fail("parseEvent 日期在前解析失败") end
    name, date = A.parseEvent("圣诞节", now)
    if name or date then fail("parseEvent 没有日期时不该硬猜") end

    -- 3) 增删改 + 排序 + 存盘往返
    local s = LuaSettings:open(DataStorage:getSettingsDir() .. "/dashboard_agenda.lua")
    s:saveSetting("events", {})
    s:saveSetting("todos", {})
    s:saveSetting("seq", 0)
    s:flush()
    A.load(true)

    A.addEvent("元旦", d_plus(20), false)
    A.addEvent("圣诞", d_plus(43), true)
    A.addEvent("年会", d_plus(10), false)
    A.addEvent("春节", d_plus(80), false)
    A.addEvent("已过的事", d_plus(-5), false)
    A.load(true)                    -- 走一遍「写盘 → 再读回来」
    local ev = A.eventsView(now)
    if not ev.focus or ev.focus.name ~= "圣诞" or not ev.focus_pinned then
        fail("置顶事件没有占据大字位")
    end
    if #ev.list ~= 3 or ev.list[1].name ~= "年会" or ev.list[3].name ~= "春节" then
        fail("最近三条没有按日期升序取前三条")
    end
    if ev.past ~= 1 then fail("过期事件计数不对") end
    -- 置顶单选：再置顶另一条，旧的那条必须自动取消
    local want = nil
    for _, e in ipairs(A.allEvents()) do if e.name == "年会" then want = e.id end end
    A.pinEvent(want)
    local pinned = 0
    for _, e in ipairs(A.allEvents()) do if e.pinned then pinned = pinned + 1 end end
    if pinned ~= 1 then fail("同时存在多条置顶（应该单选）") end

    A.addTodo("买牛奶", today)
    A.addTodo("交周报", d_plus(1))
    A.addTodo("体检", d_plus(-1))
    A.addTodo("过期但已完成", d_plus(-2))
    local tv = A.todosView(now)
    if #tv.today ~= 1 or tv.today[1].text ~= "买牛奶" then fail("今日待办筛选不对") end
    if #tv.future ~= 1 or #tv.past ~= 2 then fail("未来 / 过期分桶不对") end
    A.toggleTodo(tv.today[1].id)
    tv = A.todosView(now)
    if tv.done_today ~= 1 then fail("勾选完成后今日计数没变") end
    -- 清除已完成：勾掉的今日项 + 过期已完成项，共 2 条
    A.toggleTodo(tv.past[1].id)
    local cleared = A.clearDone()
    if cleared ~= 2 then fail("清除已完成条数不对：" .. tostring(cleared)) end
    if #A.allTodos() ~= 2 then fail("清除后剩余条数不对") end

    -- 5) 有数据时的装盒检查。矩阵那一轮跑的是空数据，空态只有两行灰字，
    --    测不出「大字位 + 三条列表」的真实高度——而真机上恰好是这个状态常驻。
    for _, orient2 in ipairs({ "portrait", "landscape" }) do
        for _, id2 in ipairs({ "countdown", "todo" }) do
            local comp2 = instance:componentRegistry()[id2]
            for _, key2 in ipairs(comp2.zones[orient2] or {}) do
                local _, box_h2, content_w2 = matrixBox(orient2, key2)
                local fitted = false
                for i = 1, #ladder do
                    local c2 = instance[comp2.build](instance, ctx_m, content_w2, box_h2, ladder[i])
                    local sz = c2:getSize()
                    if sz.h <= box_h2 and sz.w <= content_w2 + 1 then
                        fitted = true
                        break
                    end
                end
                if not fitted then
                    fail(string.format("%s@%s/%s 有数据时最小档仍装不下", id2, orient2, key2))
                end
            end
        end
    end

    -- 6) 菜单结构：v2.60 起倒数日 / 待办在二级「内容」下，逐条子菜单
    local items = instance:genMenuItemTable()
    local cd, td_menu
    for _, it in ipairs(items) do
        if it.text == T("内容") then
            for _, sub in ipairs(it.sub_item_table or {}) do
                if sub.text == T("倒数日") then cd = sub end
                if sub.text == T("待办事项") then td_menu = sub end
            end
        end
    end
    if not cd or not td_menu then fail("菜单里缺倒数日 / 待办事项入口") end
    if #cd.sub_item_table ~= #A.allEvents() + 1 then
        fail("倒数日菜单项数不对（应为 添加 + 每条事件）")
    end
    local has_sub = false
    for _, it in ipairs(cd.sub_item_table) do
        if it.sub_item_table then has_sub = true end
    end
    if not has_sub then fail("倒数日条目里没有置顶 / 删除子菜单") end

    EVENTS[#EVENTS + 1] = string.format(
        "== 倒数日 / 待办：日期往返、5 种输入解析、置顶单选、今日/未来/过期分桶、存盘往返（事件 %d / 待办 %d）==",
        #A.allEvents(), #A.allTodos())
end

--- 两步录入：第 1 步只填名称（键盘），第 2 步点选日期（不弹键盘）。
--- 这里把两个窗口的按钮真按一遍，验证「名称在前、日期在后」的链路与日期默认值。
local function check_two_step()
    local A = require("dashboard_agenda")
    local now = instance:localNow()
    local function fail(msg) print("[FAIL] " .. msg); os.exit(1) end

    -- 记下现有最大 id：测完按 id 清掉本用例新增的条目，别污染后面的渲染帧
    local max_ev, max_td = 0, 0
    for _, e in ipairs(A.allEvents()) do if e.id > max_ev then max_ev = e.id end end
    for _, t in ipairs(A.allTodos()) do if t.id > max_td then max_td = t.id end end
    local n_ev, n_td = #A.allEvents(), #A.allTodos()

    --- 跑一遍第 1 步：弹输入框 → 填文字 → 点「保存」，返回紧接着弹出的那个窗口
    local function run_step1(opener, text)
        opener()
        local dlg = UIManager:_top()
        if not dlg or not dlg.buttons then fail("第 1 步没弹出输入框") end
        if dlg.buttons[1][2].text ~= T("保存") then fail("第 1 步第 2 个按钮不是「保存」") end
        dlg.input = text
        dlg.buttons[1][2].callback()
        return UIManager:_top()
    end

    -- 1) 倒数日：默认日期是今天，点掉之后写进 store
    local picker = run_step1(function() instance:promptAddEvent() end, "妈妈生日")
    if not picker or picker.info_text ~= T("选日期") then fail("第 2 步不是日期选择器") end
    if picker.year ~= now.year or picker.month ~= now.month or picker.day ~= now.day then
        fail(string.format("日期默认值不是今天：%s-%s-%s", tostring(picker.year),
            tostring(picker.month), tostring(picker.day)))
    end
    picker:fake_pick(2026, 11, 30)
    local evs = A.allEvents()
    local last = evs[#evs]
    if last.name ~= "妈妈生日" or last.date ~= "2026-11-30" then
        fail("两步录入的倒数日没写对：" .. tostring(last.name) .. " / " .. tostring(last.date))
    end

    -- 2) 名称里顺手带了日期：拆出来当默认值，名称只剩前半截
    picker = run_step1(function() instance:promptAddEvent() end, "圣诞节 2026-12-25")
    if picker.year ~= 2026 or picker.month ~= 12 or picker.day ~= 25 then
        fail("名称里夹的日期没有用上做默认值")
    end
    picker:fake_pick(2026, 12, 25)
    evs = A.allEvents()
    last = evs[#evs]
    if last.name ~= "圣诞节" or last.date ~= "2026-12-25" then
        fail("名称里夹日期时没剥干净：" .. tostring(last.name))
    end

    -- 3) 待办：不给日期就是今天，第 2 步可直接保存
    local td_before = #A.allTodos()
    picker = run_step1(function() instance:promptAddTodo() end, "买牛奶")
    if not picker or picker.info_text ~= T("选日期") then fail("待办第 2 步不是日期选择器") end
    if picker.year ~= now.year or picker.month ~= now.month or picker.day ~= now.day then
        fail("待办的日期默认值不是今天")
    end
    picker:fake_pick(now.year, now.month, now.day)
    if #A.allTodos() ~= td_before + 1 then fail("两步录入的待办没写进去") end

    -- 4) 名称空：第 1 步就拦住，不许进第 2 步
    local ev_before = #A.allEvents()
    instance:promptAddEvent()
    local dlg = UIManager:_top()
    dlg.input = "   "
    dlg.buttons[1][2].callback()
    if #A.allEvents() ~= ev_before then fail("空名称也加进去了") end
    if UIManager:_top().year then fail("空名称仍然进了日期选择") end

    -- 清理：按 id 删掉本用例新增的，check_agenda 留下的数据原样保留
    local del = {}
    for _, e in ipairs(A.allEvents()) do if e.id > max_ev then del[#del + 1] = e.id end end
    for _, id in ipairs(del) do A.removeEvent(id) end
    del = {}
    for _, t in ipairs(A.allTodos()) do if t.id > max_td then del[#del + 1] = t.id end end
    for _, id in ipairs(del) do A.removeTodo(id) end
    if #A.allEvents() ~= n_ev or #A.allTodos() ~= n_td then fail("用例没清理干净") end

    EVENTS[#EVENTS + 1] = string.format(
        "== 两步录入：名称→日期点选、默认今天、名称夹日期预填、空名称拦截（事件 %d / 待办 %d）==",
        #A.allEvents(), #A.allTodos())
end

if _G.STUB_AGENDA then
    EVENTS[#EVENTS + 1] = "== 预览模式：跳过倒数日 / 待办数据断言（STUB_AGENDA 已注入）=="
else
    check_agenda()
    check_two_step()
end

-- 4) 菜单入口存在且项数正确
local menu_items = instance:genMenuItemTable()
local layout_item, lang_item
for _, it in ipairs(menu_items) do
    -- v2.60：版式三项 + 布局组件四项合成「外观」一屏（布局组件不再是顶层）
    if it.text == T("外观") then layout_item = it end
    if it.text and it.text:find("Language", 1, true) then lang_item = it end
end
if not layout_item or #layout_item.sub_item_table ~= 7 then
    print("[FAIL] 外观菜单缺失或项数不对：应为版式 3 项 + 布局 4 项")
    os.exit(1)
end
if not lang_item or #lang_item.sub_item_table ~= 3 then
    print("[FAIL] 语言菜单缺失或项数不对")
    os.exit(1)
end
for i = 1, 3 do
    if not layout_item.sub_item_table[i].callback then
        print(string.format("[FAIL] 外观第 %d 项应为版式项（带 callback）", i))
        os.exit(1)
    end
end
-- 层级：外观 → 竖屏布局（第 4 项）→ A 区 → 具体组件项
local zone_a = layout_item.sub_item_table[4].sub_item_table
if #zone_a ~= 3 then
    print("[FAIL] 竖屏布局应有 A/B/C 三个区，实际 " .. #zone_a)
    os.exit(1)
end
for _, it in ipairs(zone_a[1].sub_item_table) do
    if not it.checked_func or not it.callback then
        print("[FAIL] 区组件菜单项缺少勾选或回调：" .. tostring(it.text))
        os.exit(1)
    end
end

-- 5) 多语言：命中返回英文，未收录原样退回中文
I18n.setLang("en")
if I18n.T("湿度") ~= "Humidity" or I18n.T("月历") ~= "Month calendar" then
    print("[FAIL] 英文词条没生效")
    os.exit(1)
end
if I18n.T("这个词条不存在") ~= "这个词条不存在" then
    print("[FAIL] 未收录词条应原样返回，不能变成 nil")
    os.exit(1)
end
if I18n.dateLine({ year = 2026, month = 11, day = 12, wday = 4 }, true):find("Nov") == nil then
    print("[FAIL] 英文日期行没有走本地化格式")
    os.exit(1)
end
-- 5b) 数据层的文案也必须跟着语言走（雾/霾、风力级、风向、AQI 等级、城市名）
--     这些字符串来自接口或数据文件，不经 T() 就会在英文界面里留中文。
instance.weather = {
    code = 501, cond = "雾", temp = 10, tmin = 5, tmax = 12, hum = 60,
    wind = 3, winddir = 135, feels = 8, sunrise = "06:50", sunset = "16:59",
}
instance.air = { aqi = 65, level = "良" }
local wd_en = instance:weatherDisplay()
local air_en = instance:airDisplay()
local bad_en = {}
if wd_en.cond ~= "Fog" then bad_en[#bad_en + 1] = "现象 " .. tostring(wd_en.cond) end
if wd_en.wind ~= "3 Bft" then bad_en[#bad_en + 1] = "风级 " .. tostring(wd_en.wind) end
if wd_en.wind_dir ~= "SE wind" then bad_en[#bad_en + 1] = "风向 " .. tostring(wd_en.wind_dir) end
if air_en.level ~= "Good" then bad_en[#bad_en + 1] = "空气质量等级 " .. tostring(air_en.level) end
if I18n.city(instance:getCity()) ~= "Beijing" then
    bad_en[#bad_en + 1] = "城市 " .. tostring(I18n.city(instance:getCity()))
end
if I18n.tzName(instance:getTz()):find("Beijing Time") == nil then
    bad_en[#bad_en + 1] = "时区 " .. tostring(I18n.tzName(instance:getTz()))
end
if I18n.monthTitle({ year = 2026, month = 11, day = 12, wday = 4 }) ~= "November 2026" then
    bad_en[#bad_en + 1] = "月历标题 " .. I18n.monthTitle({ year = 2026, month = 11, day = 12, wday = 4 })
end
if I18n.weekdayHead(2) ~= "Mo" then bad_en[#bad_en + 1] = "月历表头" end
if I18n.zodiacYear("马") ~= "Year of the Horse" then
    bad_en[#bad_en + 1] = "生肖年份 " .. tostring(I18n.zodiacYear("马"))
end
-- 农历也要全英文：英文图里出现「十月初四」就是 README.en.md 的穿帮
local lunar_probe = { year = 2026, month = 10, day = 4, leap = false }
if I18n.lunarMonthDay(lunar_probe) ~= "Month 10, Day 4" then
    bad_en[#bad_en + 1] = "农历月日 " .. tostring(I18n.lunarMonthDay(lunar_probe))
end
if I18n.lunarMonthDay({ year = 2026, month = 6, day = 1, leap = true }) ~= "Leap Month 6, Day 1" then
    bad_en[#bad_en + 1] = "农历闰月 " .. tostring(I18n.lunarMonthDay(
        { year = 2026, month = 6, day = 1, leap = true }))
end
if I18n.lunarGanzhi(lunar_probe) ~= "Bing-Wu" then
    bad_en[#bad_en + 1] = "干支 " .. tostring(I18n.lunarGanzhi(lunar_probe))
end
if I18n.lunarMonthDay(lunar_probe):find("[\228-\233]") then
    bad_en[#bad_en + 1] = "农历月日仍含汉字"
end
-- 「1 items」是机翻味道，量词必须跟单复数
if I18n.items(1) ~= "item" or I18n.items(3) ~= "items" then
    bad_en[#bad_en + 1] = "量词单复数 " .. I18n.items(1) .. "/" .. I18n.items(3)
end
if I18n.termProgress(I18n.term("立冬"), 5) ~= "Start of Winter · day 5" then
    bad_en[#bad_en + 1] = "节气进度 " .. I18n.termProgress(I18n.term("立冬"), 5)
end
if I18n.termCountdown(I18n.term("小雪"), 11) ~= "11 days to Minor Snow" then
    bad_en[#bad_en + 1] = "节气倒计时 " .. I18n.termCountdown(I18n.term("小雪"), 11)
end
if #bad_en > 0 then
    print("[FAIL] 英文模式仍有中文残留：" .. table.concat(bad_en, "，"))
    os.exit(1)
end

I18n.setLang("zh")
if I18n.T("湿度") ~= "湿度" then
    print("[FAIL] 切回中文失败")
    os.exit(1)
end
local wd_zh = instance:weatherDisplay()
if wd_zh.cond ~= "雾" or wd_zh.wind ~= "3 级" or wd_zh.wind_dir ~= "东南风"
    or instance:airDisplay().level ~= "良" then
    print(string.format("[FAIL] 中文模式文案被改坏：%s / %s / %s / %s",
        tostring(wd_zh.cond), tostring(wd_zh.wind), tostring(wd_zh.wind_dir),
        tostring(instance:airDisplay().level)))
    os.exit(1)
end
if I18n.city(instance:getCity()) ~= "北京" or I18n.weekdayHead(2) ~= "一" then
    print("[FAIL] 中文模式的城市名或月历表头不对")
    os.exit(1)
end
-- 中文农历必须原样退回「十月初四 / 丙午」，别被英文分支带跑
if I18n.lunarMonthDay(lunar_probe) ~= "十月初四"
    or I18n.lunarGanzhi(lunar_probe) ~= "丙午"
    or I18n.items(1) ~= "项" then
    print("[FAIL] 中文模式的农历或量词被改坏："
        .. tostring(I18n.lunarMonthDay(lunar_probe)) .. " / "
        .. tostring(I18n.lunarGanzhi(lunar_probe)) .. " / " .. I18n.items(1))
    os.exit(1)
end
EVENTS[#EVENTS + 1] = "== 多语言：英文本地化、数据层文案、未收录回落、切回中文 =="

-- 6) 月历列距：通用不变量是「任何宽度都不溢出」；PW3 上再验两条具体尺寸
local S_cal = instance.scale or (SW / 600)
for w = 400, 1500, 50 do
    local cw, gp = instance:calendarMetrics(w, S_cal, 1)
    if 7 * cw + 6 * gp > w then
        print(string.format("[FAIL] 月历在宽 %d 下溢出：格宽 %d 列距 %d 总宽 %d",
            w, cw, gp, 7 * cw + 6 * gp))
        os.exit(1)
    end
end
if SW == 1072 and SH == 1448 then
    -- PW3 竖屏内容列 920：改之前是 644（两侧各空 138），现在应铺到 900 以上
    local cw_p, gap_p = instance:calendarMetrics(920, S_cal, 1)
    local p_total = 7 * cw_p + 6 * gap_p
    if p_total < math.floor(920 * 0.94) then
        print(string.format("[FAIL] 竖屏月历没铺开：格宽 %d 列距 %d 总宽 %d / 可用 920",
            cw_p, gap_p, p_total))
        os.exit(1)
    end
    if gap_p < math.floor(cw_p * 0.25) then
        print(string.format("[FAIL] 竖屏月历列距太小：格宽 %d 列距 %d", cw_p, gap_p))
        os.exit(1)
    end
    -- PW3 横屏 B 是 7×92=644，刚好铺满，此时不该再塞列距
    local cw_l, gap_l = instance:calendarMetrics(644, S_cal, 1)
    if gap_l ~= 0 or 7 * cw_l > 644 then
        print(string.format("[FAIL] 横屏月历应维持铺满且无列距：格宽 %d 列距 %d",
            cw_l, gap_l))
        os.exit(1)
    end
    EVENTS[#EVENTS + 1] = string.format(
        "== 月历列距：竖屏 格宽 %d + 列距 %d = %d/920，横屏 格宽 %d 铺满 644 ==",
        cw_p, gap_p, p_total, cw_l)
end

print("---------- 事件序列 ----------")
for _, e in ipairs(EVENTS) do print(e) end

if standby ~= 0 then
    print("\n[FAIL] 待机抑制计数未归零，会导致系统一直不休眠")
    os.exit(1)
end
print("\n[PASS] 冒烟测试全部通过")
