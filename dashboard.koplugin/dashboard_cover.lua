--[[--
在读卡的图书封面：把「当前在读那本书」的封面落成 PNG，交给 ImageWidget 画。

为什么不能直接从侧车文件读
-----------------------
侧车里只有 stats.title / authors / percent_finished 这类文字字段，没有封面。
封面是渲染引擎现生成的位图（CreDocument:getCoverPageImage 会内部 loadDocument，
再把首页渲成 BlitBuffer），因此必须显式调一次才有。

为什么要落盘缓存
-------------
看板多数时候在屏保态刷新，此时没有活文档，取封面等于「每次刷新都打开一遍书」：
crengine 加载 + 首页渲染，几百毫秒，屏保会明显卡一下。所以取到就缩到目标高度
存成 PNG，之后直接读文件。缓存键里带 mtime，书被替换/重新下载会自动失效。

约定
----
所有函数都不抛异常：取不到封面返回 nil，卡片退回纯文字版，
不让一次取图失败带走整块看板。
]]

local DataStorage = require("datastorage")
local RenderImage = require("ui/renderimage")

local M = {}

M.DIRNAME = "dashboard_covers"
-- 只留最近用过的几个：竖屏 A/B/C + 横屏 C 各一份，换书时旧的会自然被淘汰
M.MAX_KEEP = 6

local function lfs_or_nil()
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok then return lfs end
    return nil
end

--- 缓存键：优先用 sha2 的 md5；取不到就退到 djb2（碰撞概率高一些，但键里还有 mtime）
local function hash_hex(s)
    local ok, sha2 = pcall(require, "ffi/sha2")
    if ok and sha2 and sha2.md5 then
        local ok_md5, h = pcall(sha2.md5, s)
        if ok_md5 and type(h) == "string" then return h end
    end
    local h = 5381
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
    return string.format("%08x", h)
end

function M.dir()
    local ok, dir = pcall(function()
        return DataStorage:getSettingsDir() .. "/" .. M.DIRNAME
    end)
    if ok and type(dir) == "string" then return dir end
    return nil
end

function M.cache_path(book_path, target_h, mtime)
    local dir = M.dir()
    if not dir then return nil end
    local key = tostring(book_path) .. "|" .. tostring(mtime or 0) .. "|" .. tostring(target_h)
    return dir .. "/c_" .. hash_hex(key) .. ".png"
end

function M.exists(path)
    if type(path) ~= "string" or path == "" then return false end
    local lfs = lfs_or_nil()
    if not lfs then return false end
    local ok, mode = pcall(lfs.attributes, path, "mode")
    return ok and mode == "file"
end

--- 只保留最近 MAX_KEEP 个缓存文件。失败无所谓，最多是目录里多躺几个 PNG。
function M.prune()
    local dir, lfs = M.dir(), lfs_or_nil()
    if not dir or not lfs then return end
    local ok_dir, iter, obj = pcall(lfs.dir, dir)
    if not ok_dir or not iter then return end
    local list = {}
    pcall(function()
        for entry in iter, obj do
            if entry ~= "." and entry ~= ".." then
                local full = dir .. "/" .. entry
                local mt = lfs.attributes(full, "modification") or 0
                list[#list + 1] = { path = full, mt = mt }
            end
        end
    end)
    if #list <= M.MAX_KEEP then return end
    table.sort(list, function(a, b) return a.mt > b.mt end)
    for i = M.MAX_KEEP + 1, #list do
        pcall(os.remove, list[i].path)
    end
end

--- 位图缩到目标高度并存 PNG。返回是否成功。
local function save_scaled(bb, path, target_h)
    local w = bb:getWidth()
    local h = bb:getHeight()
    if not w or not h or w <= 0 or h <= 0 then return false end
    local out = bb
    if h > target_h then
        local nw = math.max(1, math.floor(w * target_h / h + 0.5))
        -- 第 4 个参数 true：缩放成功时由它释放原图，这里不要在下面再 free 一次
        local ok_scale, scaled = pcall(function()
            return RenderImage:scaleBlitBuffer(bb, nw, target_h, true)
        end)
        if ok_scale and scaled then out = scaled end
    end
    local ok_write = pcall(function() out:writePNG(path) end)
    pcall(function() out:free() end)
    return ok_write and M.exists(path)
end

--- 取封面位图：活文档直接用内存里的，否则临时打开那本书（只在缓存未命中时发生）。
local function grab_bitmap(ui, book_path)
    local live = ui and ui.document
    if live and live.file == book_path then
        local ok, img = pcall(function() return live:getCoverPageImage() end)
        if ok and img then return img end
    end
    local ok_reg, DocumentRegistry = pcall(require, "document/documentregistry")
    if not ok_reg or not DocumentRegistry then return nil end
    local ok_open, doc = pcall(function() return DocumentRegistry:openDocument(book_path) end)
    if not ok_open or not doc then return nil end
    local ok_img, img = pcall(function() return doc:getCoverPageImage() end)
    pcall(function() doc:close() end)
    if ok_img then return img end
    return nil
end

--- 取封面 PNG 路径。
--- opts = { ui=, book_path=, target_h=, force= }
--- 返回：缓存文件路径 / nil（取不到）
function M.resolve(opts)
    if type(opts) ~= "table" then return nil end
    local book_path, target_h = opts.book_path, opts.target_h
    if type(book_path) ~= "string" or book_path == "" then return nil end
    if type(target_h) ~= "number" or target_h <= 0 then return nil end

    local dir = M.dir()
    if not dir then return nil end
    local lfs = lfs_or_nil()
    if lfs then pcall(lfs.mkdir, dir) end

    local mtime = 0
    if lfs then
        local ok_mt, mt = pcall(lfs.attributes, book_path, "modification")
        if ok_mt and tonumber(mt) then mtime = tonumber(mt) end
    end

    local cache = M.cache_path(book_path, target_h, mtime)
    if not cache then return nil end
    if not opts.force and M.exists(cache) then return cache end

    local bb = grab_bitmap(opts.ui, book_path)
    if not bb then return nil end
    if not save_scaled(bb, cache, target_h) then return nil end
    M.prune()
    return cache
end

return M
