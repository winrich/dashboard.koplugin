--[[--
Open-Meteo 降级数据源

只在和风天气不可用（无凭据、超时、凭据失效、解压失败）时兜底，避免看板长时间空着。
免注册、免 API Key，但要素比和风少，所以只作降级而不是主源：

  · 现象代码是 WMO 标准，这里映射成和风编号，界面那套图标表可以直接复用
  · 空气质量只给 PM2.5 / PM10 浓度，没有国标 AQI，由 main.lua 按 HJ 633-2012 换算
  · 风力接口只给风速（km/h），按蒲福风级表换算等级
  · 日出日落按 GMT 取（timezone=GMT），再按用户选择的时区偏移换算出显示时刻，
    与和风路径的换算方式保持一致

实测（2026-11）：响应为明文 JSON，不带 Content-Encoding。仍保留 gzip 魔数判断，
避免哪天服务端改了压缩策略后解析出一堆乱码。
--]]

local JSON = require("json")
local logger = require("logger")
local http = require("socket.http")
local ltn12 = require("ltn12")
local _ = require("gettext")

http.TIMEOUT = 20

local M = {}

-- ------------------------------------------------------------------ 天气现象
-- WMO 天气代码 -> { 中文描述, 和风现象代码 }
-- 第二项只用于选图标，不参与展示，取值与和风代码表一致（晴=100、小雨=305……）
M.CODES = {
    [0]  = { "晴",        100 },
    [1]  = { "晴间多云",   103 },
    [2]  = { "多云",      101 },
    [3]  = { "阴",        104 },
    [45] = { "雾",        501 },
    [48] = { "雾凇",      501 },
    [51] = { "毛毛雨",     309 },
    [53] = { "毛毛雨",     309 },
    [55] = { "浓毛毛雨",   309 },
    [56] = { "冻毛毛雨",   313 },
    [57] = { "冻毛毛雨",   313 },
    [61] = { "小雨",      305 },
    [63] = { "中雨",      306 },
    [65] = { "大雨",      307 },
    [66] = { "冻雨",      313 },
    [67] = { "强冻雨",     313 },
    [71] = { "小雪",      400 },
    [73] = { "中雪",      401 },
    [75] = { "大雪",      402 },
    [77] = { "米雪",      499 },
    [80] = { "阵雨",      300 },
    [81] = { "强阵雨",     301 },
    [82] = { "暴阵雨",     301 },
    [85] = { "阵雪",      407 },
    [86] = { "强阵雪",     407 },
    [95] = { "雷阵雨",     302 },
    [96] = { "雷阵雨伴冰雹", 304 },
    [99] = { "雷阵雨伴冰雹", 304 },
}

-- 蒲福风级（km/h 下限），索引即风级
local WIND_LEVEL_BOUNDS = { 1, 6, 12, 20, 29, 39, 50, 62, 75, 89, 103, 118 }

local function wind_scale(kmh)
    local v = tonumber(kmh)
    if not v then return nil end
    local level = 0
    for i = 1, #WIND_LEVEL_BOUNDS do
        if v >= WIND_LEVEL_BOUNDS[i] then level = i end
    end
    return level
end

--- GMT 的 ISO 时刻 -> 目标时区下的 HH:MM
local function local_hm(iso, tz_offset_min)
    local hh, mm = tostring(iso or ""):match("T(%d%d):(%d%d)")
    if not hh then return nil end
    local total = (tonumber(hh) * 60 + tonumber(mm) + (tonumber(tz_offset_min) or 0)) % 1440
    return string.format("%02d:%02d", math.floor(total / 60), total % 60)
end

-- ------------------------------------------------------------------ 网络
-- 与和风路径同样的双通道尝试：优先 LuaSec，失败退回 socket.http
local function http_get(url)
    local modules = {}
    local ok, ssl_https = pcall(require, "ssl.https")
    if ok and ssl_https then
        modules[#modules + 1] = ssl_https
    end
    modules[#modules + 1] = http

    local last_code
    for _, mod in ipairs(modules) do
        local sink = {}
        local req_ok, code = mod.request{
            url = url,
            method = "GET",
            sink = ltn12.sink.table(sink),
        }
        if req_ok == 1 then
            return table.concat(sink), code
        end
        last_code = code
        logger.warn("dashboard: Open-Meteo 请求失败, http code =", tostring(code))
    end
    return nil, last_code
end

--- gzip 魔数判断：服务端若改回压缩，借和风模块的解压能力兜一下
local function maybe_gunzip(body)
    if type(body) ~= "string" or #body < 2 then return body end
    if body:byte(1) ~= 0x1f or body:byte(2) ~= 0x8b then return body end
    local ok, QW = pcall(require, "dashboard_qweather")
    if ok and QW.gunzip then
        local plain = QW.gunzip(body)
        if plain then return plain end
    end
    return nil
end

-- ------------------------------------------------------------------ 对外接口
--- 拉取一个地点的天气与空气质量
--- @param opts table { city = {name,lat,lon}, tz = {offset,iana} }
--- @return weather|nil, air|nil, err|nil
function M.fetch(opts)
    local city, tz = opts.city, opts.tz
    if not city then return nil, nil, _("未选择城市") end
    local offset = tz and tz.offset or 480

    local lat = string.format("%.2f", city.lat)
    local lon = string.format("%.2f", city.lon)

    local cur_url = string.format(
        "https://api.open-meteo.com/v1/forecast?latitude=%s&longitude=%s"
        .. "&current=temperature_2m,relative_humidity_2m,apparent_temperature,"
        .. "weather_code,wind_speed_10m,wind_direction_10m"
        .. "&daily=temperature_2m_max,temperature_2m_min,sunrise,sunset"
        .. "&timezone=GMT&forecast_days=1", lat, lon)
    local air_url = string.format(
        "https://air-quality-api.open-meteo.com/v1/air-quality?latitude=%s&longitude=%s"
        .. "&current=pm10,pm2_5&timezone=GMT", lat, lon)

    local first_err
    local weather

    local raw, code = http_get(cur_url)
    if raw then
        local body = maybe_gunzip(raw)
        local ok, data = pcall(JSON.decode, body or "")
        if ok and type(data) == "table" and type(data.current) == "table" then
            local cur = data.current
            local daily = type(data.daily) == "table" and data.daily or {}
            local wmo = tonumber(cur.weather_code)
            local meta = M.CODES[wmo] or { nil, nil }
            local level = wind_scale(cur.wind_speed_10m)

            local function first(t)
                return type(t) == "table" and t[1] or nil
            end

            weather = {
                city = city.name,
                source = "open-meteo",
                -- 统一成和风编号，图标表只需一份
                code = meta[2],
                cond = meta[1],
                temp = tonumber(cur.temperature_2m),
                feels = tonumber(cur.apparent_temperature),
                hum = tonumber(cur.relative_humidity_2m),
                wind = level,
                winddir = tonumber(cur.wind_direction_10m),
                windspeed = tonumber(cur.wind_speed_10m),
                tmax = tonumber(first(daily.temperature_2m_max)),
                tmin = tonumber(first(daily.temperature_2m_min)),
                sunrise = local_hm(first(daily.sunrise), offset),
                sunset = local_hm(first(daily.sunset), offset),
                ts = os.time(),
            }
        else
            first_err = string.format(_("Open-Meteo 数据解析失败（HTTP %s）"), tostring(code))
            logger.warn("dashboard: Open-Meteo JSON 解析失败",
                type(body) == "string" and body:sub(1, 200) or "")
        end
    else
        first_err = string.format(_("Open-Meteo 请求失败（HTTP %s）"), tostring(code or "-"))
    end

    local air
    local araw, acode = http_get(air_url)
    if araw then
        local body = maybe_gunzip(araw)
        local ok, data = pcall(JSON.decode, body or "")
        if ok and type(data) == "table" and type(data.current) == "table" then
            local cur = data.current
            local pm25 = tonumber(cur.pm2_5)
            local pm10 = tonumber(cur.pm10)
            if pm25 or pm10 then
                -- 没有国标 AQI，交给 main.lua 按浓度换算
                air = { pm25 = pm25, pm10 = pm10, ts = os.time() }
            end
        else
            logger.warn("dashboard: Open-Meteo 空气质量解析失败")
        end
    else
        logger.warn("dashboard: Open-Meteo 空气质量请求失败, code =", tostring(acode))
    end

    if not weather and not air then
        return nil, nil, first_err or _("Open-Meteo 天气更新失败")
    end
    return weather, air, nil
end

return M
