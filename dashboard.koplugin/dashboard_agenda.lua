--[[--
倒数日与待办的数据层（v2.47）

这个文件只做三件事：**存**、**算**、**解析输入**，一行绘制代码都没有。
拆出来的理由很实际：日期算法和输入解析是最容易出错、也最容易写测试的部分，
放进 3000 行的 main.lua 里就只能靠肉眼看了。

存储位置
--------
`<KOReader 设置目录>/dashboard_agenda.lua`，用 LuaSettings 存，和天气缓存同目录。
不塞进 G_reader_settings：那是 KOReader 自己的设置文件，往里面写用户数据一旦
格式出错会连累整个阅读器；单独一个文件坏了最多是这两个组件空着。

    { seq = 7,
      events = { { id = 1, name = "圣诞节", date = "2026-12-25", pinned = true }, ... },
      todos  = { { id = 2, date = "2026-11-12", text = "交周报", done = false }, ... } }

日期一律存 "YYYY-MM-DD" 字符串：人可读、能直接 grep、跨时区不会漂。

为什么要自己算「差几天」
----------------------
不用 os.time 做差：Kindle 的时区设置、夏令时切换都会让 86400 这个常数不成立，
而「12 月 25 日还有几天」只跟日历有关，跟钟点无关。这里用 Howard Hinnant 的
civil-days 算法（把年月日折成一个连续天数），纯整数运算、无时区、无 DST，
闰年和世纪年（1900/2000）都覆盖，桩件里可以拿已知日期逐条对。
]]

local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")

local M = {}

M.FILE = "dashboard_agenda.lua"
-- 已完成待办保留天数：超过这个天数的勾选项在下次保存时清掉，避免文件越长越大
M.DONE_KEEP_DAYS = 30

local store    -- 内存中的表（唯一真源）
local handle   -- LuaSettings 实例，保存时复用
local view_cache = { key = nil }

-- ------------------------------------------------------------------ 基础工具
local function trim(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end
M.trim = trim

local function settings_path()
    local ok, dir = pcall(function() return DataStorage:getSettingsDir() end)
    if ok and type(dir) == "string" and dir ~= "" then
        return dir .. "/" .. M.FILE
    end
    return nil
end

-- ------------------------------------------------------------------ 日历运算
function M.isLeap(y)
    return (y % 4 == 0 and y % 100 ~= 0) or (y % 400 == 0)
end

function M.daysInMonth(y, m)
    local d = ({ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 })[m]
    if m == 2 and M.isLeap(y) then return 29 end
    return d
end

function M.isValidDate(y, m, d)
    y, m, d = tonumber(y), tonumber(m), tonumber(d)
    if not (y and m and d) then return false end
    if y < 1900 or y > 2200 then return false end
    if m < 1 or m > 12 then return false end
    if d < 1 or d > (M.daysInMonth(y, m) or 0) then return false end
    return true
end

--- 公历日 -> 连续天数（Hinnant days_from_civil）。1970-01-01 为 0。
function M.daynum(y, m, d)
    local yy = (m <= 2) and (y - 1) or y
    local era = math.floor(yy / 400)
    local yoe = yy - era * 400
    local mp = (m + 9) % 12
    local doy = math.floor((153 * mp + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

--- 连续天数 -> 公历年月日（daynum 的逆运算）
function M.civilFromDays(z)
    z = z + 719468
    local era = math.floor(z / 146097)
    local doe = z - era * 146097
    local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524)
        - math.floor(doe / 146096)) / 365)
    local y = yoe + era * 400
    local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
    local mp = math.floor((5 * doy + 2) / 153)
    local d = doy - math.floor((153 * mp + 2) / 5) + 1
    local m = mp + (mp < 10 and 3 or -9)
    if m <= 2 then y = y + 1 end
    return y, m, d
end

function M.fmtDate(y, m, d)
    return string.format("%04d-%02d-%02d", y, m, d)
end

--- 今天的日期串。now 是 os.date("!*t") 那种表（main.lua 的 localNow 已经按城市时区算好）
function M.today(now)
    now = now or os.date("*t")
    return M.fmtDate(now.year, now.month, now.day)
end

--- 两个日期串相差几天（to - from）。任一解析失败返回 nil。
function M.daysBetween(from, to)
    local y1, m1, d1 = M.parseDate(from)
    local y2, m2, d2 = M.parseDate(to)
    if not (y1 and y2) then return nil end
    return M.daynum(y2, m2, d2) - M.daynum(y1, m1, d1)
end

--- 解析日期串。year 省略时按 ref_year 补（"12-25" 这种写法）。
--- 接受 2026-12-25 / 2026/12/25 / 2026.12.25 / 2026年12月25日 / 12-25 / 12月25日。
function M.parseDate(s, ref_year)
    if type(s) ~= "string" or s == "" then return nil end
    -- 尾部允许「日 / 号」："2026年12月25日" 和 "12月25号" 都认。
    -- 注意这里必须用字面量 "日$" 而不是 [日号]?：Lua 的字符类按**字节**匹配，
    -- [日号] 是一个字节集合，? 只能吃掉「日」三个字节里的一个，反而匹配不上。
    s = trim(s)
    s = s:gsub("日$", ""):gsub("号$", "")
    -- 分隔符按「一个或多个非数字字节」匹配：年 / 月 / 日 都是三字节 UTF-8，
    -- 用 %D 只吃一个字节，"2026年12月25日" 会匹配失败。
    local y, m, d = s:match("^(%d%d%d%d)[^%d]+(%d%d?)[^%d]+(%d%d?)$")
    if not y then
        m, d = s:match("^(%d%d?)[^%d]+(%d%d?)$")
        y = ref_year
    end
    if not y then return nil end
    y, m, d = tonumber(y), tonumber(m), tonumber(d)
    if not M.isValidDate(y, m, d) then return nil end
    return y, m, d
end

-- ------------------------------------------------------------------ 输入解析
-- 相对日：只认这几种，不做自然语言理解。「下周三」这种要么用户自己算，要么别做半套。
local REL_WORDS = {
    { "大后天", 3 }, { "后天", 2 }, { "明天", 1 }, { "今天", 0 }, { "今日", 0 },
    { "tomorrow", 1 }, { "today", 0 },
}

local function rel_offset(token)
    local low = token:lower()
    for _, w in ipairs(REL_WORDS) do
        if low == w[1] then return w[2] end
    end
    return nil
end

--- 把输入拆成 (日期串, 剩下的内容)。
--- 认两种写法：相对日在前（"明天 交周报"）、日期在前（"12-25 交周报"）；
--- 只给内容不给日期 → 日期返回 nil，由调用方决定默认（待办默认今天，倒数日必须显式写）。
function M.parseEntry(text, now)
    text = trim(text)
    if text == "" then return nil, "" end
    local today_idx = M.daynum(now.year, now.month, now.day)

    -- 1) 先看首个空格前的 token 是不是相对日或日期
    local head, rest = text:match("^(%S+)%s+(.*)$")
    if head then
        local off = rel_offset(head)
        if off then
            local y, m, d = M.civilFromDays(today_idx + off)
            return M.fmtDate(y, m, d), trim(rest)
        end
        local y, m, d = M.parseDate(head, now.year)
        if y then return M.fmtDate(y, m, d), trim(rest) end
    end

    -- 2) 整串就是一个日期（"12-25"）
    local y, m, d = M.parseDate(text, now.year)
    if y then return M.fmtDate(y, m, d), "" end

    -- 3) 日期夹在中间或粘在名字后面（"圣诞节2026-12-25" / "妈妈 生日 2026-05-01"）：
    --    按 token 找第一个纯日期，其余拼回去。只删第一个命中的 token，
    --    名字里重复出现的同形 token 原样保留。
    local parts = {}
    for tk in text:gmatch("%S+") do parts[#parts + 1] = tk end
    local date, skip
    for i, tk in ipairs(parts) do
        local yy, mm, dd = M.parseDate(tk, now.year)
        if yy then
            date = M.fmtDate(yy, mm, dd)
            skip = i
            break
        end
    end
    if date then
        local out = {}
        for i, tk in ipairs(parts) do
            if i ~= skip then out[#out + 1] = tk end
        end
        return date, trim(table.concat(out, " "))
    end

    -- 4) 连空格都没有（"圣诞节2026-12-25"）：在整串里找第一段完整日期再摘掉。
    --    只认带年份的写法——"圣诞12-25" 这种没法判断 12-25 是日期还是名字的一部分。
    local s, e, yy, mm, dd = text:find("(%d%d%d%d)[^%d]+(%d%d?)[^%d]+(%d%d?)")
    if s and M.isValidDate(yy, mm, dd) then
        -- 尾随的「日 / 号」也是日期的一部分，一并摘掉（各占 3 字节）
        local tail = text:sub(e + 1, e + 3)
        if tail == "日" or tail == "号" then e = e + 3 end
        local name = trim(text:sub(1, s - 1) .. " " .. text:sub(e + 1))
        return M.fmtDate(tonumber(yy), tonumber(mm), tonumber(dd)), name
    end

    return nil, text
end

--- 倒数日输入：名称和日期哪个在前都行。
--- 返回 name, date；解析不出日期返回 nil, nil（调用方提示格式）。
function M.parseEvent(text, now)
    local date, rest = M.parseEntry(text, now)
    if date and rest ~= "" then return rest, date end
    -- "2026-12-25 圣诞节" 这种情况 parseEntry 已处理；"圣诞节 2026-12-25" 也处理了。
    -- 剩下没解析出来的，直接失败，不再猜。
    return nil, nil
end

--- 待办输入：没有日期就记今天。
function M.parseTodo(text, now)
    local date, rest = M.parseEntry(text, now)
    if not date then
        return trim(text), M.today(now)
    end
    if rest == "" then return nil, nil end
    return rest, date
end

-- ------------------------------------------------------------------ 读写
local function normalize_events(raw)
    local out = {}
    if type(raw) ~= "table" then return out end
    for _, e in ipairs(raw) do
        if type(e) == "table" then
            local y, m, d = M.parseDate(e.date)
            local name = trim(e.name)
            if y and name ~= "" then
                out[#out + 1] = {
                    id = tonumber(e.id) or (#out + 1),
                    name = name,
                    date = M.fmtDate(y, m, d),
                    pinned = e.pinned and true or false,
                }
            end
        end
    end
    return out
end

local function normalize_todos(raw)
    local out = {}
    if type(raw) ~= "table" then return out end
    for _, t in ipairs(raw) do
        if type(t) == "table" then
            local y, m, d = M.parseDate(t.date)
            local text = trim(t.text)
            if y and text ~= "" then
                out[#out + 1] = {
                    id = tonumber(t.id) or (#out + 1),
                    date = M.fmtDate(y, m, d),
                    text = text,
                    done = t.done and true or false,
                }
            end
        end
    end
    return out
end

--- 载入（默认走缓存）。force=true 强制重读文件。
function M.load(force)
    if store and not force then return store end
    store = { events = {}, todos = {}, seq = 0, rev = 0 }
    local path = settings_path()
    if path then
        local ok, s = pcall(function() return LuaSettings:open(path) end)
        if ok and s then
            handle = s
            local okr, ev = pcall(function() return s:readSetting("events") end)
            local okt, td = pcall(function() return s:readSetting("todos") end)
            local oks, sq = pcall(function() return s:readSetting("seq") end)
            if okr then store.events = normalize_events(ev) end
            if okt then store.todos = normalize_todos(td) end
            if oks and tonumber(sq) then store.seq = tonumber(sq) end
        end
    end
    -- seq 掉了（手改文件 / 旧版数据）就按现有最大值补，避免 id 撞车
    local max_id = store.seq
    for _, e in ipairs(store.events) do max_id = math.max(max_id, e.id) end
    for _, t in ipairs(store.todos) do max_id = math.max(max_id, t.id) end
    store.seq = max_id
    view_cache.key = nil
    return store
end

local function save()
    if not store then return false end
    local path = settings_path()
    if not path then return false end
    local ok, err = pcall(function()
        if not handle then handle = LuaSettings:open(path) end
        handle:saveSetting("events", store.events)
        handle:saveSetting("todos", store.todos)
        handle:saveSetting("seq", store.seq)
        handle:flush()
    end)
    return ok, err
end
M.save = save

local function touch()
    store.rev = (store.rev or 0) + 1
    view_cache.key = nil
end

local function next_id()
    store.seq = (store.seq or 0) + 1
    return store.seq
end

-- ------------------------------------------------------------------ 事件增删
--- 置顶是「单选」：新置顶会取消旧的，因为这组件就是靠「唯一那条置顶」立住的。
function M.addEvent(name, date, pinned)
    M.load()
    name, date = trim(name), trim(date)
    local y, m, d = M.parseDate(date)
    if name == "" or not y then return nil end
    if pinned then
        for _, e in ipairs(store.events) do e.pinned = false end
    end
    local id = next_id()
    store.events[#store.events + 1] = {
        id = id, name = name, date = M.fmtDate(y, m, d), pinned = pinned and true or false,
    }
    touch()
    save()
    return id
end

function M.removeEvent(id)
    M.load()
    for i, e in ipairs(store.events) do
        if e.id == id then
            table.remove(store.events, i)
            touch()
            save()
            return true
        end
    end
    return false
end

function M.togglePin(id)
    M.load()
    local target
    for _, e in ipairs(store.events) do
        if e.id == id then target = e end
    end
    if not target then return false end
    local newv = not target.pinned
    for _, e in ipairs(store.events) do e.pinned = false end
    target.pinned = newv
    touch()
    save()
    return true
end

--- 把置顶给某条事件（菜单里用「置顶」而不是「切换」，语义更直白）
function M.pinEvent(id)
    M.load()
    local found = false
    for _, e in ipairs(store.events) do
        e.pinned = (e.id == id)
        if e.id == id then found = true end
    end
    if not found then return false end
    touch()
    save()
    return true
end

function M.unpinAll()
    M.load()
    for _, e in ipairs(store.events) do e.pinned = false end
    touch()
    save()
end

function M.eventById(id)
    M.load()
    for _, e in ipairs(store.events) do
        if e.id == id then return e end
    end
    return nil
end

-- ------------------------------------------------------------------ 待办增删
function M.addTodo(text, date)
    M.load()
    text, date = trim(text), trim(date)
    local y, m, d = M.parseDate(date)
    if text == "" or not y then return nil end
    local id = next_id()
    store.todos[#store.todos + 1] = {
        id = id, date = M.fmtDate(y, m, d), text = text, done = false,
    }
    touch()
    save()
    return id
end

function M.removeTodo(id)
    M.load()
    for i, t in ipairs(store.todos) do
        if t.id == id then
            table.remove(store.todos, i)
            touch()
            save()
            return true
        end
    end
    return false
end

function M.toggleTodo(id)
    M.load()
    for _, t in ipairs(store.todos) do
        if t.id == id then
            t.done = not t.done
            touch()
            save()
            return t.done
        end
    end
    return nil
end

--- 清掉所有已完成的待办，返回清掉的条数
function M.clearDone()
    M.load()
    local kept, n = {}, 0
    for _, t in ipairs(store.todos) do
        if t.done then n = n + 1 else kept[#kept + 1] = t end
    end
    if n > 0 then
        store.todos = kept
        touch()
        save()
    end
    return n
end

--- 已完成且日期早于 cutoff 的自动清掉（超出保留期），避免文件无限增长
local function pruneDone(now)
    local cutoff = M.daynum(now.year, now.month, now.day) - M.DONE_KEEP_DAYS
    local kept, removed = {}, 0
    for _, t in ipairs(store.todos) do
        local y, m, d = M.parseDate(t.date)
        local dn = y and M.daynum(y, m, d) or 0
        if t.done and dn < cutoff then
            removed = removed + 1
        else
            kept[#kept + 1] = t
        end
    end
    if removed > 0 then
        store.todos = kept
        touch()
        return removed
    end
    return 0
end

-- ------------------------------------------------------------------ 视图
--- 倒数日视图：
---   focus  = 展示在大字位的那一条（置顶优先；没有置顶就取最近一条未来的）
---   list   = 除 focus 外、最近的三条未来事件（按日期升序）
---   past   = 已过去的条数（只用于「还有 N 条已过期」这类提示，不占版面）
function M.eventsView(now)
    M.load()
    local today = M.today(now)
    local key = "e" .. today .. "#" .. tostring(store.rev)
    if view_cache.key == key then return view_cache end

    local ty, tm, td = M.parseDate(today)
    local tdn = M.daynum(ty, tm, td)
    local all = {}
    for _, e in ipairs(store.events) do
        local y, m, d = M.parseDate(e.date)
        if y then
            all[#all + 1] = {
                id = e.id, name = e.name, date = e.date, pinned = e.pinned and true or false,
                days = M.daynum(y, m, d) - tdn, month = m, day = d,
            }
        end
    end
    table.sort(all, function(a, b)
        if a.days ~= b.days then return a.days < b.days end
        return a.id < b.id
    end)

    local focus
    -- 1) 置顶里挑「最近的一个未来」；全过期了就挑最接近今天的那条（免得置顶凭空消失）
    local best_future, best_past
    for _, e in ipairs(all) do
        if e.pinned then
            if e.days >= 0 and (not best_future or e.days < best_future.days) then
                best_future = e
            end
            if e.days < 0 and (not best_past or e.days > best_past.days) then
                best_past = e
            end
        end
    end
    focus = best_future or best_past
    local focus_pinned = focus ~= nil
    if not focus then
        for _, e in ipairs(all) do
            if e.days >= 0 then focus = e break end
        end
        if not focus and all[1] then focus = all[#all] end
    end

    local list, past = {}, 0
    for _, e in ipairs(all) do
        if e.days < 0 then
            past = past + 1
        elseif not focus or e.id ~= focus.id then
            if #list < 3 then list[#list + 1] = e end
        end
    end

    view_cache = {
        key = key, focus = focus, focus_pinned = focus_pinned,
        list = list, total = #all, past = past,
    }
    return view_cache
end

--- 待办视图：今天的、未来的、已过期未完成的，分三桶
function M.todosView(now)
    M.load()
    local today = M.today(now)
    local key = "t" .. today .. "#" .. tostring(store.rev)
    if view_cache.key == key then return view_cache end

    local ty, tm, td = M.parseDate(today)
    local tdn = M.daynum(ty, tm, td)
    local out = { today = {}, future = {}, past = {}, done_today = 0, total_today = 0,
                  pending_future = 0, pending_past = 0 }
    for _, t in ipairs(store.todos) do
        local y, m, d = M.parseDate(t.date)
        if y then
            local dn = M.daynum(y, m, d)
            local item = { id = t.id, date = t.date, text = t.text, done = t.done,
                           days = dn - tdn, month = m, day = d }
            if dn == tdn then
                out.today[#out.today + 1] = item
                out.total_today = out.total_today + 1
                if t.done then out.done_today = out.done_today + 1 end
            elseif dn > tdn then
                out.future[#out.future + 1] = item
                if not t.done then out.pending_future = out.pending_future + 1 end
            elseif not t.done then
                out.past[#out.past + 1] = item
                out.pending_past = out.pending_past + 1
            end
        end
    end
    table.sort(out.today, function(a, b)
        if a.done ~= b.done then return not a.done end
        return a.id < b.id
    end)
    table.sort(out.future, function(a, b)
        if a.days ~= b.days then return a.days < b.days end
        return a.id < b.id
    end)
    table.sort(out.past, function(a, b)
        if a.days ~= b.days then return a.days > b.days end
        return a.id < b.id
    end)
    view_cache = out
    out.key = key
    return out
end

--- 当前内存里的原始数据（菜单里遍历用，不排序）
function M.allEvents()
    M.load()
    return store.events
end

function M.allTodos()
    M.load()
    return store.todos
end

--- 运行期调用：顺手清理过期已完成项。返回清掉的条数。
function M.maintenance(now)
    M.load()
    local n = pruneDone(now)
    if n > 0 then save() end
    return n
end

return M
