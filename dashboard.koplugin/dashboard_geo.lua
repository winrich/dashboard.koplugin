--[[--
按 IP 粗略定位（只有用户主动点「自动检测我的位置」时才会联网）

只做一件事：问一次 ip-api.com 自己在哪，然后把结果交给调用方去匹配城市。
不缓存、不常驻、不参与天气刷新——每次点都要现查，避免用户换了网络还拿着旧结果。

为什么用它：免注册、免 Key、返回经纬度与时区 IANA 名，正好是设置里需要的三个值。
它只有免费版仅支持 http（https 要付费），所以这里走明文；请求里不带任何设备标识，
也不落盘，隐私面仅限于对方能看到出口 IP。

失败一律返回 nil + 原因，调用方回落到「手动选城市」，不影响已有配置。
--]]

local http = require("socket.http")
local ltn12 = require("ltn12")
local logger = require("logger")
local I18n = require("dashboard_i18n")

-- 用看板自己的词表而不是 gettext：插件没有 .po 目录，_() 只会原样返回中文
local T = I18n.T

local M = {}

-- 只要这几个字段，响应体小一半；status/message 用于区分「查询失败」与「网络失败」
local URL = "http://ip-api.com/json/?fields=status,message,country,city,lat,lon,timezone"

--- 发一次 GET。成功返回响应体，失败返回 nil + 原因。
local function http_get(url)
    local sink = {}
    -- http.TIMEOUT 是模块级共享设置，改完必须还原，否则会把天气请求的超时也改掉
    local prev = http.TIMEOUT
    http.TIMEOUT = 8
    local ok, res, code = pcall(function()
        return http.request{
            url = url,
            method = "GET",
            sink = ltn12.sink.table(sink),
        }
    end)
    http.TIMEOUT = prev
    if not ok then
        logger.warn("dashboard: 定位请求异常", tostring(res))
        return nil, tostring(res)
    end
    if res ~= 1 then
        logger.warn("dashboard: 定位请求失败, http code =", tostring(code))
        return nil, string.format(T("网络请求失败（%s）"), tostring(code or "?"))
    end
    return table.concat(sink)
end

--- 查询本机出口 IP 的大致位置
--- @return table|nil { lat, lon, city, country, iana }, string|nil 错误原因
function M.locate()
    local body, err = http_get(URL)
    if not body then return nil, err end

    local JSON = require("json")
    local ok, data = pcall(JSON.decode, body)
    if not ok or type(data) ~= "table" then
        return nil, T("返回内容无法解析")
    end
    if data.status ~= "success" then
        return nil, data.message or T("服务拒绝了这次查询")
    end

    local lat, lon = tonumber(data.lat), tonumber(data.lon)
    if not lat or not lon then
        return nil, T("返回内容缺少坐标")
    end

    return {
        lat = lat,
        lon = lon,
        city = data.city,
        country = data.country,
        iana = data.timezone,
    }
end

return M
