--[[--
和风天气数据源（QWeather 开发服务 v1 接口）

三个接口，均只认经纬度，不需要 LocationID、不调用 GeoAPI：
  GET /weather/v1/current/{lat}/{lon}?localTime=true&lang=zh     实况
  GET /weather/v1/daily/{lat}/{lon}?days=1&localTime=true&lang=zh 今日预报（含日出日落、最高最低温）
  GET /airquality/v1/current/{lat}/{lon}?lang=zh                  空气质量（含国标 AQI）

认证：请求头 X-QW-Api-Key（不再用 ?key= 查询参数）
Host：每个账号独立的 API Host，形如 abcxyz.qweatherapi.com

两个必须处理的服务端行为（2026-11 实测确认）：
  · 响应一律 Content-Encoding: gzip，即使请求头声明 Accept-Encoding: identity
    也照压不误，所以必须自己解压。ffi 不可用时解压失败，此时返回明确错误，
    界面显示「天气数据解压失败」，不会崩也不会静默显示旧数据。
  · 湿度 humidity 是 0~1 的比例（旧 Open-Meteo 是百分比），要乘 100。
--]]

local JSON = require("json")
local logger = require("logger")
local http = require("socket.http")
local ltn12 = require("ltn12")
local _ = require("gettext")

http.TIMEOUT = 20

local M = {}

-- ------------------------------------------------------------------ 天气现象
-- 和风天气现象代码 -> { 中文描述, 本地图标名 }
-- 图标只有 12 个，同一类现象复用图形；描述优先用接口返回的 condition.text，
-- 这张表主要用来决定图标，代码表变化时最差退化成 partly 而不是报错。
M.CONDITIONS = {
    [100] = { "晴",       "clear" },
    [101] = { "多云",     "partly" },
    [102] = { "少云",     "mainly_clear" },
    [103] = { "晴间多云",  "mainly_clear" },
    [104] = { "阴",       "overcast" },
    [150] = { "晴",       "clear" },
    [151] = { "多云",     "partly" },
    [152] = { "少云",     "mainly_clear" },
    [153] = { "晴间多云",  "mainly_clear" },

    [300] = { "阵雨",     "shower" },
    [301] = { "强阵雨",    "shower" },
    [302] = { "雷阵雨",    "thunder" },
    [303] = { "强雷阵雨",  "thunder" },
    [304] = { "雷阵雨伴冰雹", "thunder" },
    [305] = { "小雨",     "rain" },
    [306] = { "中雨",     "rain" },
    [307] = { "大雨",     "rain" },
    [308] = { "极端降雨",  "rain" },
    [309] = { "毛毛雨",    "drizzle" },
    [310] = { "暴雨",     "rain" },
    [311] = { "大暴雨",    "rain" },
    [312] = { "特大暴雨",  "rain" },
    [313] = { "冻雨",     "freezing_rain" },
    [314] = { "小到中雨",  "rain" },
    [315] = { "中到大雨",  "rain" },
    [316] = { "大到暴雨",  "rain" },
    [317] = { "暴雨到大暴雨", "rain" },
    [318] = { "大暴雨到特大暴雨", "rain" },
    [399] = { "雨",       "rain" },

    [400] = { "小雪",     "snow" },
    [401] = { "中雪",     "snow" },
    [402] = { "大雪",     "snow" },
    [403] = { "暴雪",     "snow" },
    [404] = { "雨夹雪",    "snow" },
    [405] = { "雨雪天气",  "snow" },
    [406] = { "阵雨夹雪",  "snow_shower" },
    [407] = { "阵雪",     "snow_shower" },
    [408] = { "小到中雪",  "snow" },
    [409] = { "中到大雪",  "snow" },
    [410] = { "大到暴雪",  "snow" },
    [499] = { "雪",       "snow" },

    [500] = { "薄雾",     "fog" },
    [501] = { "雾",       "fog" },
    [502] = { "霾",       "fog" },
    [503] = { "扬沙",     "fog" },
    [504] = { "浮尘",     "fog" },
    [507] = { "沙尘暴",    "fog" },
    [508] = { "强沙尘暴",  "fog" },
    [509] = { "浓雾",     "fog" },
    [510] = { "强浓雾",    "fog" },
    [511] = { "中度霾",    "fog" },
    [512] = { "重度霾",    "fog" },
    [513] = { "严重霾",    "fog" },
    [514] = { "大雾",     "fog" },
    [515] = { "特强浓雾",  "fog" },

    [900] = { "热",       "clear" },
    [901] = { "冷",       "clear" },
    [999] = { "未知",     "partly" },
}

--- 天气现象代码 -> { 中文描述, 图标名 }
function M.condition(code)
    return M.CONDITIONS[tonumber(code) or -1] or { "未知天气", "partly" }
end

-- ------------------------------------------------------------------ gzip 解压
-- 自检样本：gzip("dashboard-probe")，用固定字节验证 inflate 调用链是否正确。
-- 自检不通过就说明 libz 绑定有问题，此时宁可报错也不要把乱码喂给 JSON。
local GZIP_PROBE_IN = "\31\139\8\0\0\0\0\0\2\255\75\73\44\206\72\202\79\44\74"
    .. "\209\45\40\202\79\74\5\0\163\210\173\127\15\0\0\0"
local GZIP_PROBE_OUT = "dashboard-probe"

local Z_STREAM_CDEF = [[
typedef struct dash_z_stream_s {
    const unsigned char *next_in;
    unsigned int  avail_in;
    unsigned long total_in;
    unsigned char *next_out;
    unsigned int  avail_out;
    unsigned long total_out;
    const char   *msg;
    void         *state;
    void         *zalloc;
    void         *zfree;
    void         *opaque;
    int           data_type;
    unsigned long adler;
    unsigned long reserved;
} dash_z_stream;
const char *zlibVersion(void);
int inflateInit2_(dash_z_stream *strm, int windowBits, const char *version, int stream_size);
int inflate(dash_z_stream *strm, int flush);
int inflateEnd(dash_z_stream *strm);
]]

local libz_state   -- nil 未检测 / false 不可用 / 库对象 可用
local cdef_done = false

-- windowBits = 15 + 32：自动识别 gzip 与 zlib 头
local WINDOW_BITS_AUTO = 47
local Z_OK = 0
local Z_STREAM_END = 1

local function inflate_gzip(libz, data)
    local ffi = require("ffi")
    local cap = math.max(8192, #data * 10)
    local out = ffi.new("unsigned char[?]", cap)
    local strm = ffi.new("dash_z_stream")
    strm.next_in = ffi.cast("const unsigned char *", data)
    strm.avail_in = #data
    strm.next_out = out
    strm.avail_out = cap

    local rc = libz.inflateInit2_(strm, WINDOW_BITS_AUTO, libz.zlibVersion(),
        ffi.sizeof("dash_z_stream"))
    if rc ~= Z_OK then
        return nil, "inflateInit2 rc=" .. tostring(rc)
    end

    local parts = {}
    local guard = 0
    while true do
        guard = guard + 1
        if guard > 64 then
            libz.inflateEnd(strm)
            return nil, "inflate 循环过多"
        end
        rc = libz.inflate(strm, 0)  -- Z_NO_FLUSH
        local produced = cap - tonumber(strm.avail_out)
        if produced > 0 then
            parts[#parts + 1] = ffi.string(out, produced)
            strm.next_out = out
            strm.avail_out = cap
        end
        if rc == Z_STREAM_END then
            break
        elseif rc ~= Z_OK then
            libz.inflateEnd(strm)
            return nil, "inflate rc=" .. tostring(rc)
        elseif produced == 0 and tonumber(strm.avail_in) == 0 then
            libz.inflateEnd(strm)
            return nil, "gzip 数据被截断"
        end
    end
    libz.inflateEnd(strm)
    return table.concat(parts)
end

--- 取得可用的 libz 绑定，并跑一次自检；失败返回 nil
local function get_libz()
    if libz_state ~= nil then
        return libz_state or nil
    end
    libz_state = false

    local ok_ffi, ffi = pcall(require, "ffi")
    if not ok_ffi then
        logger.warn("dashboard: 当前环境没有 ffi，无法解压 gzip 响应")
        return nil
    end
    if not cdef_done then
        -- 重复 cdef 会抛错，但同一个进程里只需成功一次
        pcall(ffi.cdef, Z_STREAM_CDEF)
        cdef_done = true
    end

    local libz
    local ok_load, loaded = pcall(function()
        if ffi.loadlib then return ffi.loadlib("z", 1) end
        local ok, l = pcall(ffi.load, "z")
        if ok then return l end
        return ffi.load("libz.so.1")
    end)
    if ok_load and loaded then
        libz = loaded
    end
    if not libz then
        logger.warn("dashboard: libz 加载失败，无法解压 gzip 响应")
        return nil
    end

    local ok_probe, probe = pcall(inflate_gzip, libz, GZIP_PROBE_IN)
    if not ok_probe or probe ~= GZIP_PROBE_OUT then
        logger.warn("dashboard: zlib 自检未通过，gzip 解压不可用",
            tostring(ok_probe and probe or nil))
        return nil
    end

    libz_state = libz
    return libz
end

--- gzip 解压；非 gzip 数据原样返回
--- @return string|nil 解压后的正文，失败时返回 nil, 错误描述
function M.gunzip(data)
    if type(data) ~= "string" or #data < 2 then return data end
    if data:byte(1) ~= 0x1f or data:byte(2) ~= 0x8b then return data end
    local libz = get_libz()
    if not libz then return nil, "gzip 解压不可用" end
    local ok, res, err = pcall(inflate_gzip, libz, data)
    if not ok then return nil, "gzip 解压异常: " .. tostring(res) end
    if not res then return nil, err end
    return res
end

-- ------------------------------------------------------------------ 配置读取
local function merge(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" and type(dst[k]) == "table" then
            merge(dst[k], v)
        else
            dst[k] = v
        end
    end
    return dst
end

local function read_table(path)
    local f = io.open(path, "r")
    if not f then return nil end
    f:close()
    local ok, t = pcall(dofile, path)
    if not ok then
        logger.warn("dashboard: 配置文件有语法错误", path, tostring(t))
        return nil
    end
    if type(t) ~= "table" then return nil end
    return t
end

--- 读配置：dashboard_config.lua -> dashboard_config.local.lua -> 设备内录入
--- 返回值额外带 _host_source / _key_source，供菜单显示凭据来自哪里
function M.loadConfig(plugin_dir, greader)
    local cfg = { qweather = {}, _host_source = "none", _key_source = "none" }

    local base = read_table(plugin_dir .. "/dashboard_config.lua")
    if base then
        merge(cfg, base)
        if cfg.qweather.api_host and cfg.qweather.api_host ~= "" then
            cfg._host_source = "file"
        end
        if cfg.qweather.api_key and cfg.qweather.api_key ~= "" then
            cfg._key_source = "file"
        end
    end

    local local_cfg = read_table(plugin_dir .. "/dashboard_config.local.lua")
    if local_cfg then
        merge(cfg, local_cfg)
        if local_cfg.qweather then
            if local_cfg.qweather.api_host and local_cfg.qweather.api_host ~= "" then
                cfg._host_source = "local"
            end
            if local_cfg.qweather.api_key and local_cfg.qweather.api_key ~= "" then
                cfg._key_source = "local"
            end
        end
    end

    if greader then
        local host = greader:readSetting("dashboard_qw_host")
        local key = greader:readSetting("dashboard_qw_key")
        if type(host) == "string" and host ~= "" then
            cfg.qweather.api_host = host
            cfg._host_source = "settings"
        end
        if type(key) == "string" and key ~= "" then
            cfg.qweather.api_key = key
            cfg._key_source = "settings"
        end
    end

    -- 容错：有人会把 https:// 或结尾斜杠一起粘进来
    local host = cfg.qweather.api_host or ""
    host = host:gsub("^%s+", ""):gsub("%s+$", "")
    host = host:gsub("^[Hh][Tt][Tt][Pp][Ss]?://", ""):gsub("/+$", "")
    cfg.qweather.api_host = host

    local key = cfg.qweather.api_key or ""
    cfg.qweather.api_key = key:gsub("^%s+", ""):gsub("%s+$", "")

    return cfg
end

--- 脱敏显示，用于菜单：b85dcb****4e3b
function M.mask(secret)
    if type(secret) ~= "string" or #secret < 8 then return "(未配置)" end
    return secret:sub(1, 6) .. "****" .. secret:sub(-4)
end

-- ------------------------------------------------------------------ 时间换算
--- ISO8601（带偏移）-> 目标时区下的 "HH:MM"
--- 接口 localTime=true 返回的是查询地当地的时间，如 2026-11-11T06:54+08:00；
--- 用户可在看板里选其他时区，这里统一换算，避免时钟与日出日落对不上。
function M.local_hm(iso, tz_offset_min)
    if type(iso) ~= "string" then return nil end
    local h, mi, sign, oh, om = iso:match("T(%d%d):(%d%d)([%+%-])(%d%d):(%d%d)")
    local offset_min
    if h then
        offset_min = tonumber(oh) * 60 + tonumber(om)
        if sign == "-" then offset_min = -offset_min end
    else
        h, mi = iso:match("T(%d%d):(%d%d)Z")
        if not h then return nil end
        offset_min = 0
    end
    local total = tonumber(h) * 60 + tonumber(mi) - offset_min + (tonumber(tz_offset_min) or 0)
    total = total % 1440
    return string.format("%02d:%02d", math.floor(total / 60), total % 60)
end

-- ------------------------------------------------------------------ 网络请求
local function http_get(url, headers)
    local modules = {}
    if url:match("^https") then
        local ok, ssl_https = pcall(require, "ssl.https")
        if ok and ssl_https then
            modules[#modules + 1] = ssl_https
        end
    end
    modules[#modules + 1] = http

    local last_code
    for _, mod in ipairs(modules) do
        local sink = {}
        local req_ok, code = mod.request{
            url = url,
            method = "GET",
            headers = headers,
            sink = ltn12.sink.table(sink),
        }
        if req_ok == 1 then
            return table.concat(sink), code
        end
        last_code = code
        logger.warn("dashboard: 请求失败, http code =", tostring(code))
    end
    return nil, last_code
end

--- 把服务端错误体翻译成看得懂的一句话
local function describe_error(code, body)
    local detail
    if body then
        local ok, data = pcall(JSON.decode, body)
        if ok and type(data) == "table" and type(data.error) == "table" then
            detail = data.error.detail or data.error.title
        end
    end
    local hint
    if code == 401 then
        hint = _("API Key 或 API Host 不正确")
    elseif code == 403 then
        hint = _("该凭据没有开通天气预报/空气质量数据权限")
    elseif code == 429 then
        hint = _("请求过于频繁，超出免费额度")
    elseif code == 404 then
        hint = _("接口路径或 API Host 错误")
    elseif code then
        hint = string.format(_("服务端返回 HTTP %s"), tostring(code))
    else
        hint = _("网络请求失败")
    end
    return detail and (hint .. "：" .. tostring(detail)) or hint
end

-- ------------------------------------------------------------------ 对外接口
--- 拉取一个地点的天气与空气质量
--- @param opts table { city = {name,lat,lon}, tz = {offset,iana}, config = <loadConfig 结果> }
--- @return weather|nil, air|nil, err|nil
function M.fetch(opts)
    local cfg = opts.config or {}
    local qw = cfg.qweather or {}
    if not qw.api_host or qw.api_host == "" or not qw.api_key or qw.api_key == "" then
        return nil, nil, _("未配置和风天气 API Host 或 API Key")
    end

    local city, tz = opts.city, opts.tz
    if not city then return nil, nil, _("未选择城市") end

    -- 接口要求经纬度最多两位小数
    local lat = string.format("%.2f", city.lat)
    local lon = string.format("%.2f", city.lon)
    local base = "https://" .. qw.api_host
    local headers = { ["X-QW-Api-Key"] = qw.api_key }

    local cur_url = string.format("%s/weather/v1/current/%s/%s?localTime=true&lang=zh",
        base, lat, lon)
    local day_url = string.format("%s/weather/v1/daily/%s/%s?days=1&localTime=true&lang=zh",
        base, lat, lon)
    local air_url = string.format("%s/airquality/v1/current/%s/%s?lang=zh", base, lat, lon)

    local first_err

    ------------------------------------------------------------------ 实况
    local weather
    local raw, code = http_get(cur_url, headers)
    if raw then
        local body, gz_err = M.gunzip(raw)
        if not body then
            first_err = first_err or (_("天气数据解压失败") .. "：" .. tostring(gz_err))
        else
            local ok, data = pcall(JSON.decode, body)
            if ok and type(data) == "table" and type(data.condition) == "table" then
                local wind = type(data.wind) == "table" and data.wind or {}
                local dir = type(wind.direction) == "table" and wind.direction or {}
                local speed = type(wind.speed) == "table" and wind.speed or {}
                local hum = tonumber(data.humidity)
                weather = {
                    city = city.name,
                    -- 标记来源：界面用它决定页脚的数据来源声明，缓存也靠它判断代码表
                    source = "qweather",
                    code = tonumber(data.condition.code),
                    cond = data.condition.text,
                    temp = tonumber(type(data.temperature) == "table" and data.temperature.value),
                    feels = tonumber(type(data.feelsLike) == "table" and data.feelsLike.value),
                    -- 接口给的是 0~1 比例，展示统一用百分比
                    hum = hum and hum * 100 or nil,
                    wind = tonumber(wind.scale),
                    winddir = tonumber(dir.degree),
                    compass = dir.compass,
                    windspeed = tonumber(speed.value),
                    ts = os.time(),
                }
            else
                first_err = first_err or describe_error(code, body)
                logger.warn("dashboard: 实况 JSON 解析失败",
                    type(body) == "string" and body:sub(1, 200) or "")
            end
        end
    else
        first_err = first_err or describe_error(code, nil)
    end

    ------------------------------------------------------------------ 今日预报
    if weather then
        local draw, dcode = http_get(day_url, headers)
        if draw then
            local body = M.gunzip(draw)
            local ok, data = pcall(JSON.decode, body or "")
            if ok and type(data) == "table" and type(data.days) == "table" and data.days[1] then
                local day = data.days[1]
                local astro = type(day.astro) == "table" and day.astro or {}
                weather.tmax = tonumber(type(day.temperatureMax) == "table"
                    and day.temperatureMax.value)
                weather.tmin = tonumber(type(day.temperatureMin) == "table"
                    and day.temperatureMin.value)
                weather.sunrise = M.local_hm(astro.sunrise, tz.offset)
                weather.sunset = M.local_hm(astro.sunset, tz.offset)
            else
                logger.warn("dashboard: 预报 JSON 解析失败")
            end
        else
            logger.warn("dashboard: 预报请求失败, code =", tostring(dcode))
        end
    end

    ------------------------------------------------------------------ 空气质量
    local air
    local araw, acode = http_get(air_url, headers)
    if araw then
        local body = M.gunzip(araw)
        local ok, data = pcall(JSON.decode, body or "")
        if ok and type(data) == "table" then
            local aqi, level
            -- 优先国标 AQI（cn-mee），境外城市没有时再回退
            if type(data.indexes) == "table" then
                for _, idx in ipairs(data.indexes) do
                    if type(idx) == "table" and idx.code == "cn-mee" then
                        aqi = tonumber(idx.aqi)
                        level = idx.category
                        break
                    end
                end
            end
            local pm25, pm10
            if type(data.pollutants) == "table" then
                for _, p in ipairs(data.pollutants) do
                    if type(p) == "table" and type(p.concentration) == "table" then
                        if p.code == "pm2p5" then pm25 = tonumber(p.concentration.value)
                        elseif p.code == "pm10" then pm10 = tonumber(p.concentration.value) end
                    end
                end
            end
            if aqi or pm25 or pm10 then
                air = { aqi = aqi, level = level, pm25 = pm25, pm10 = pm10, ts = os.time() }
            end
        else
            logger.warn("dashboard: 空气质量 JSON 解析失败")
        end
    else
        logger.warn("dashboard: 空气质量请求失败, code =", tostring(acode))
    end

    if not weather and not air then
        return nil, nil, first_err or _("天气更新失败")
    end
    return weather, air, nil
end

return M
