--[[--
城市与时区数据

城市坐标为市政府驻地中心点，用于向天气接口请求（请求时会截到两位小数），
精度对天气而言远超所需（差几公里不影响结果）。

`name` 是中文名，同时充当设置里 `dashboard_city` 的**键**，不能改；
`en` 只在英文界面下用于显示，缺省时退回 `name`。

`group` 是菜单分组名（中文原文即 i18n 词表的键）。

`tz` 是可选字段：
  · 国内城市**不带** tz——中国境内既有北京时间也有新疆时间，由用户自己选，
    选城市时不去覆盖他已选的时区（v2.51 之前的行为原样保留）；
  · 海外城市**必须带** tz，选城市时自动把时区一并改掉，避免「城市对了、时钟错了」
    这种最常见的配置失误；
  · `global = true` 表示不在和风天气的国内数据覆盖范围内，天气直接走 Open-Meteo。

时区采用「UTC 偏移 + IANA 名称」双字段：
  offset 是**标准时间**偏移（分钟），用于本地时钟/日期/农历计算
  iana   用于向天气接口声明数据所属时区，保证当日最高最低温归属正确
  dst    可选，夏令时规则名（见 DST_RULES）。真实偏移由 offsetAt() 按日期算，
         固定 offset 会让伦敦/纽约/悉尼这类城市在夏季稳定慢一小时。
--]]

local M = {}

M.cities = {
    -- 直辖市
    { name = "北京",   en = "Beijing",   group = "直辖市", lat = 39.9042, lon = 116.4074 },
    { name = "天津",   en = "Tianjin",   group = "直辖市", lat = 39.0842, lon = 117.2009 },
    { name = "上海",   en = "Shanghai",  group = "直辖市", lat = 31.2304, lon = 121.4737 },
    { name = "重庆",   en = "Chongqing", group = "直辖市", lat = 29.5630, lon = 106.5516 },

    -- 省会 / 自治区首府
    { name = "石家庄", en = "Shijiazhuang", group = "省会", lat = 38.0428, lon = 114.5149 },
    { name = "太原",   en = "Taiyuan",      group = "省会", lat = 37.8706, lon = 112.5489 },
    { name = "呼和浩特", en = "Hohhot",     group = "省会", lat = 40.8424, lon = 111.7490 },
    { name = "沈阳",   en = "Shenyang",     group = "省会", lat = 41.8057, lon = 123.4315 },
    { name = "长春",   en = "Changchun",    group = "省会", lat = 43.8171, lon = 125.3235 },
    { name = "哈尔滨", en = "Harbin",       group = "省会", lat = 45.8038, lon = 126.5349 },
    { name = "南京",   en = "Nanjing",      group = "省会", lat = 32.0603, lon = 118.7969 },
    { name = "杭州",   en = "Hangzhou",     group = "省会", lat = 30.2741, lon = 120.1551 },
    { name = "合肥",   en = "Hefei",        group = "省会", lat = 31.8206, lon = 117.2272 },
    { name = "福州",   en = "Fuzhou",       group = "省会", lat = 26.0745, lon = 119.2965 },
    { name = "南昌",   en = "Nanchang",     group = "省会", lat = 28.6820, lon = 115.8579 },
    { name = "济南",   en = "Jinan",        group = "省会", lat = 36.6512, lon = 117.1201 },
    { name = "郑州",   en = "Zhengzhou",    group = "省会", lat = 34.7466, lon = 113.6254 },
    { name = "武汉",   en = "Wuhan",        group = "省会", lat = 30.5928, lon = 114.3055 },
    { name = "长沙",   en = "Changsha",     group = "省会", lat = 28.2282, lon = 112.9388 },
    { name = "广州",   en = "Guangzhou",    group = "省会", lat = 23.1291, lon = 113.2644 },
    { name = "南宁",   en = "Nanning",      group = "省会", lat = 22.8170, lon = 108.3665 },
    { name = "海口",   en = "Haikou",       group = "省会", lat = 20.0440, lon = 110.1999 },
    { name = "成都",   en = "Chengdu",      group = "省会", lat = 30.5728, lon = 104.0668 },
    { name = "贵阳",   en = "Guiyang",      group = "省会", lat = 26.6470, lon = 106.6302 },
    { name = "昆明",   en = "Kunming",      group = "省会", lat = 25.0389, lon = 102.7183 },
    { name = "拉萨",   en = "Lhasa",        group = "省会", lat = 29.6520, lon = 91.1721 },
    { name = "西安",   en = "Xi'an",        group = "省会", lat = 34.3416, lon = 108.9398 },
    { name = "兰州",   en = "Lanzhou",      group = "省会", lat = 36.0611, lon = 103.8343 },
    { name = "西宁",   en = "Xining",       group = "省会", lat = 36.6171, lon = 101.7782 },
    { name = "银川",   en = "Yinchuan",     group = "省会", lat = 38.4872, lon = 106.2309 },
    { name = "乌鲁木齐", en = "Urumqi",     group = "省会", lat = 43.8256, lon = 87.6168 },

    -- 港澳台
    { name = "香港", en = "Hong Kong", group = "港澳台", lat = 22.3193, lon = 114.1694 },
    { name = "澳门", en = "Macao",     group = "港澳台", lat = 22.1987, lon = 113.5439 },
    { name = "台北", en = "Taipei",    group = "港澳台", lat = 25.0330, lon = 121.5654 },

    -- 亚洲（海外）
    { name = "东京",   en = "Tokyo",     group = "亚洲", tz = "Asia/Tokyo",         global = true, lat = 35.6762, lon = 139.6503 },
    { name = "首尔",   en = "Seoul",     group = "亚洲", tz = "Asia/Seoul",         global = true, lat = 37.5665, lon = 126.9780 },
    { name = "新加坡", en = "Singapore", group = "亚洲", tz = "Asia/Singapore",     global = true, lat = 1.3521,  lon = 103.8198 },
    { name = "曼谷",   en = "Bangkok",   group = "亚洲", tz = "Asia/Bangkok",       global = true, lat = 13.7563, lon = 100.5018 },
    { name = "雅加达", en = "Jakarta",   group = "亚洲", tz = "Asia/Jakarta",       global = true, lat = -6.2088, lon = 106.8456 },
    { name = "马尼拉", en = "Manila",    group = "亚洲", tz = "Asia/Manila",        global = true, lat = 14.5995, lon = 120.9842 },
    { name = "河内",   en = "Hanoi",     group = "亚洲", tz = "Asia/Ho_Chi_Minh",   global = true, lat = 21.0278, lon = 105.8342 },
    { name = "孟买",   en = "Mumbai",    group = "亚洲", tz = "Asia/Kolkata",       global = true, lat = 19.0760, lon = 72.8777 },
    { name = "新德里", en = "New Delhi", group = "亚洲", tz = "Asia/Kolkata",       global = true, lat = 28.6139, lon = 77.2090 },
    { name = "迪拜",   en = "Dubai",     group = "亚洲", tz = "Asia/Dubai",         global = true, lat = 25.2048, lon = 55.2708 },

    -- 欧洲
    { name = "伦敦",   en = "London",    group = "欧洲", tz = "Europe/London",      global = true, lat = 51.5074, lon = -0.1278 },
    { name = "巴黎",   en = "Paris",     group = "欧洲", tz = "Europe/Paris",       global = true, lat = 48.8566, lon = 2.3522 },
    { name = "柏林",   en = "Berlin",    group = "欧洲", tz = "Europe/Berlin",      global = true, lat = 52.5200, lon = 13.4050 },
    { name = "阿姆斯特丹", en = "Amsterdam", group = "欧洲", tz = "Europe/Amsterdam", global = true, lat = 52.3676, lon = 4.9041 },
    { name = "马德里", en = "Madrid",    group = "欧洲", tz = "Europe/Madrid",      global = true, lat = 40.4168, lon = -3.7038 },
    { name = "罗马",   en = "Rome",      group = "欧洲", tz = "Europe/Rome",        global = true, lat = 41.9028, lon = 12.4964 },
    { name = "苏黎世", en = "Zurich",    group = "欧洲", tz = "Europe/Zurich",      global = true, lat = 47.3769, lon = 8.5417 },
    { name = "斯德哥尔摩", en = "Stockholm", group = "欧洲", tz = "Europe/Stockholm", global = true, lat = 59.3293, lon = 18.0686 },
    { name = "华沙",   en = "Warsaw",    group = "欧洲", tz = "Europe/Warsaw",      global = true, lat = 52.2297, lon = 21.0122 },
    { name = "莫斯科", en = "Moscow",    group = "欧洲", tz = "Europe/Moscow",      global = true, lat = 55.7558, lon = 37.6173 },

    -- 北美洲
    { name = "纽约",   en = "New York",    group = "北美洲", tz = "America/New_York",    global = true, lat = 40.7128, lon = -74.0060 },
    { name = "洛杉矶", en = "Los Angeles", group = "北美洲", tz = "America/Los_Angeles", global = true, lat = 34.0522, lon = -118.2437 },
    { name = "芝加哥", en = "Chicago",     group = "北美洲", tz = "America/Chicago",     global = true, lat = 41.8781, lon = -87.6298 },
    { name = "旧金山", en = "San Francisco", group = "北美洲", tz = "America/Los_Angeles", global = true, lat = 37.7749, lon = -122.4194 },
    { name = "西雅图", en = "Seattle",     group = "北美洲", tz = "America/Los_Angeles", global = true, lat = 47.6062, lon = -122.3321 },
    { name = "丹佛",   en = "Denver",      group = "北美洲", tz = "America/Denver",      global = true, lat = 39.7392, lon = -104.9903 },
    { name = "多伦多", en = "Toronto",     group = "北美洲", tz = "America/Toronto",     global = true, lat = 43.6532, lon = -79.3832 },
    { name = "温哥华", en = "Vancouver",   group = "北美洲", tz = "America/Vancouver",   global = true, lat = 49.2827, lon = -123.1207 },
    { name = "墨西哥城", en = "Mexico City", group = "北美洲", tz = "America/Mexico_City", global = true, lat = 19.4326, lon = -99.1332 },

    -- 南美洲
    { name = "圣保罗",   en = "Sao Paulo",       group = "南美洲", tz = "America/Sao_Paulo",              global = true, lat = -23.5505, lon = -46.6333 },
    { name = "里约热内卢", en = "Rio de Janeiro", group = "南美洲", tz = "America/Sao_Paulo",              global = true, lat = -22.9068, lon = -43.1729 },
    { name = "布宜诺斯艾利斯", en = "Buenos Aires", group = "南美洲", tz = "America/Argentina/Buenos_Aires", global = true, lat = -34.6037, lon = -58.3816 },
    { name = "圣地亚哥", en = "Santiago",        group = "南美洲", tz = "America/Santiago",               global = true, lat = -33.4489, lon = -70.6693 },
    { name = "利马",     en = "Lima",            group = "南美洲", tz = "America/Lima",                   global = true, lat = -12.0464, lon = -77.0428 },
    { name = "波哥大",   en = "Bogota",          group = "南美洲", tz = "America/Bogota",                 global = true, lat = 4.7110,  lon = -74.0721 },

    -- 大洋洲
    { name = "悉尼",   en = "Sydney",    group = "大洋洲", tz = "Australia/Sydney",  global = true, lat = -33.8688, lon = 151.2093 },
    { name = "墨尔本", en = "Melbourne", group = "大洋洲", tz = "Australia/Melbourne", global = true, lat = -37.8136, lon = 144.9631 },
    { name = "布里斯班", en = "Brisbane", group = "大洋洲", tz = "Australia/Brisbane", global = true, lat = -27.4698, lon = 153.0251 },
    { name = "珀斯",   en = "Perth",     group = "大洋洲", tz = "Australia/Perth",   global = true, lat = -31.9505, lon = 115.8605 },
    { name = "奥克兰", en = "Auckland",  group = "大洋洲", tz = "Pacific/Auckland",  global = true, lat = -36.8485, lon = 174.7633 },
    { name = "惠灵顿", en = "Wellington", group = "大洋洲", tz = "Pacific/Auckland", global = true, lat = -41.2865, lon = 174.7762 },

    -- 非洲
    { name = "开罗",         en = "Cairo",       group = "非洲", tz = "Africa/Cairo",        global = true, lat = 30.0444, lon = 31.2357 },
    { name = "约翰内斯堡",   en = "Johannesburg", group = "非洲", tz = "Africa/Johannesburg", global = true, lat = -26.2041, lon = 28.0473 },
    { name = "开普敦",       en = "Cape Town",   group = "非洲", tz = "Africa/Johannesburg", global = true, lat = -33.9249, lon = 18.4241 },
    { name = "内罗毕",       en = "Nairobi",     group = "非洲", tz = "Africa/Nairobi",      global = true, lat = -1.2921,  lon = 36.8219 },
    { name = "拉各斯",       en = "Lagos",       group = "非洲", tz = "Africa/Lagos",        global = true, lat = 6.5244,   lon = 3.3792 },
    { name = "卡萨布兰卡",   en = "Casablanca",  group = "非洲", tz = "Africa/Casablanca",   global = true, lat = 33.5731, lon = -7.5898 },
}

-- 菜单分组的显示顺序。城市表按此顺序切分，增删城市只需保证 group 名在这里存在。
M.city_groups = {
    { key = "直辖市", text = "直辖市" },
    { key = "省会",   text = "省会与首府" },
    { key = "港澳台", text = "港澳台" },
    { key = "亚洲",   text = "亚洲" },
    { key = "欧洲",   text = "欧洲" },
    { key = "北美洲", text = "北美洲" },
    { key = "南美洲", text = "南美洲" },
    { key = "大洋洲", text = "大洋洲" },
    { key = "非洲",   text = "非洲" },
}

-- 时区表按 IANA 名唯一列出，**每个城市的 tz 必须能在这里查到**（verify_lua 会强制校验）。
-- 同偏移的城市各占一项而不合并：用户在自己的分组里找城市比找「中欧」这种区域名更准，
-- 而且合并会让「城市 ↔ 时区」的对应关系需要额外的别名映射表。
--
-- offset 单位为分钟，且是**标准时间**偏移；dst 为 nil 表示该地区不实行夏令时
-- （或规则过于特殊、按固定偏移处理误差可接受，见各条注释）。
M.timezones = {
    -- 亚洲
    { name = "北京时间 UTC+8",   en = "Beijing Time UTC+8",   group = "亚洲", offset = 480,  iana = "Asia/Shanghai" },
    { name = "新疆时间 UTC+6",   en = "Xinjiang Time UTC+6",  group = "亚洲", offset = 360,  iana = "Asia/Urumqi" },
    { name = "东京 UTC+9",       en = "Tokyo UTC+9",          group = "亚洲", offset = 540,  iana = "Asia/Tokyo" },
    { name = "首尔 UTC+9",       en = "Seoul UTC+9",          group = "亚洲", offset = 540,  iana = "Asia/Seoul" },
    { name = "新加坡 UTC+8",     en = "Singapore UTC+8",      group = "亚洲", offset = 480,  iana = "Asia/Singapore" },
    { name = "马尼拉 UTC+8",     en = "Manila UTC+8",         group = "亚洲", offset = 480,  iana = "Asia/Manila" },
    { name = "曼谷 UTC+7",       en = "Bangkok UTC+7",        group = "亚洲", offset = 420,  iana = "Asia/Bangkok" },
    { name = "雅加达 UTC+7",     en = "Jakarta UTC+7",        group = "亚洲", offset = 420,  iana = "Asia/Jakarta" },
    { name = "河内 UTC+7",       en = "Hanoi UTC+7",          group = "亚洲", offset = 420,  iana = "Asia/Ho_Chi_Minh" },
    { name = "印度 UTC+5:30",    en = "India UTC+5:30",       group = "亚洲", offset = 330,  iana = "Asia/Kolkata" },
    { name = "迪拜 UTC+4",       en = "Dubai UTC+4",          group = "亚洲", offset = 240,  iana = "Asia/Dubai" },

    -- 欧洲（莫斯科 2014 年起不再实行夏令时；其余西欧/中欧国家统一用 EU 规则）
    { name = "莫斯科 UTC+3",     en = "Moscow UTC+3",         group = "欧洲", offset = 180,  iana = "Europe/Moscow" },
    { name = "伦敦 UTC+0（夏令时 +1）",   en = "London UTC+0 (+1 DST)",      group = "欧洲", offset = 0,  iana = "Europe/London",      dst = "EU" },
    { name = "柏林 UTC+1（夏令时 +2）",   en = "Berlin UTC+1 (+2 DST)",      group = "欧洲", offset = 60, iana = "Europe/Berlin",      dst = "EU" },
    { name = "巴黎 UTC+1（夏令时 +2）",   en = "Paris UTC+1 (+2 DST)",       group = "欧洲", offset = 60, iana = "Europe/Paris",       dst = "EU" },
    { name = "阿姆斯特丹 UTC+1（夏令时 +2）", en = "Amsterdam UTC+1 (+2 DST)", group = "欧洲", offset = 60, iana = "Europe/Amsterdam", dst = "EU" },
    { name = "马德里 UTC+1（夏令时 +2）", en = "Madrid UTC+1 (+2 DST)",      group = "欧洲", offset = 60, iana = "Europe/Madrid",      dst = "EU" },
    { name = "罗马 UTC+1（夏令时 +2）",   en = "Rome UTC+1 (+2 DST)",        group = "欧洲", offset = 60, iana = "Europe/Rome",        dst = "EU" },
    { name = "苏黎世 UTC+1（夏令时 +2）", en = "Zurich UTC+1 (+2 DST)",      group = "欧洲", offset = 60, iana = "Europe/Zurich",      dst = "EU" },
    { name = "斯德哥尔摩 UTC+1（夏令时 +2）", en = "Stockholm UTC+1 (+2 DST)", group = "欧洲", offset = 60, iana = "Europe/Stockholm", dst = "EU" },
    { name = "华沙 UTC+1（夏令时 +2）",   en = "Warsaw UTC+1 (+2 DST)",      group = "欧洲", offset = 60, iana = "Europe/Warsaw",      dst = "EU" },

    -- 美洲
    { name = "纽约 UTC-5（夏令时 -4）",   en = "New York UTC-5 (-4 DST)",     group = "美洲", offset = -300, iana = "America/New_York",    dst = "US" },
    { name = "多伦多 UTC-5（夏令时 -4）", en = "Toronto UTC-5 (-4 DST)",      group = "美洲", offset = -300, iana = "America/Toronto",     dst = "US" },
    { name = "芝加哥 UTC-6（夏令时 -5）", en = "Chicago UTC-6 (-5 DST)",      group = "美洲", offset = -360, iana = "America/Chicago",     dst = "US" },
    { name = "丹佛 UTC-7（夏令时 -6）",   en = "Denver UTC-7 (-6 DST)",       group = "美洲", offset = -420, iana = "America/Denver",      dst = "US" },
    { name = "洛杉矶 UTC-8（夏令时 -7）", en = "Los Angeles UTC-8 (-7 DST)",  group = "美洲", offset = -480, iana = "America/Los_Angeles", dst = "US" },
    { name = "温哥华 UTC-8（夏令时 -7）", en = "Vancouver UTC-8 (-7 DST)",    group = "美洲", offset = -480, iana = "America/Vancouver",   dst = "US" },
    -- 墨西哥 2022 年起取消夏令时，按固定 -6 处理
    { name = "墨西哥城 UTC-6",   en = "Mexico City UTC-6",    group = "美洲", offset = -360, iana = "America/Mexico_City" },
    -- 巴西 2019 年起取消夏令时
    { name = "圣保罗 UTC-3",     en = "Sao Paulo UTC-3",      group = "美洲", offset = -180, iana = "America/Sao_Paulo" },
    { name = "阿根廷 UTC-3",     en = "Argentina UTC-3",      group = "美洲", offset = -180, iana = "America/Argentina/Buenos_Aires" },
    { name = "智利 UTC-4（夏令时 -3）", en = "Chile UTC-4 (-3 DST)", group = "美洲", offset = -240, iana = "America/Santiago", dst = "CL" },
    { name = "秘鲁 UTC-5",       en = "Peru UTC-5",           group = "美洲", offset = -300, iana = "America/Lima" },
    { name = "哥伦比亚 UTC-5",   en = "Colombia UTC-5",       group = "美洲", offset = -300, iana = "America/Bogota" },

    -- 大洋洲
    { name = "悉尼 UTC+10（夏令时 +11）",   en = "Sydney UTC+10 (+11 DST)",    group = "大洋洲", offset = 600, iana = "Australia/Sydney",    dst = "AU" },
    { name = "墨尔本 UTC+10（夏令时 +11）", en = "Melbourne UTC+10 (+11 DST)", group = "大洋洲", offset = 600, iana = "Australia/Melbourne", dst = "AU" },
    -- 昆士兰不实行夏令时
    { name = "布里斯班 UTC+10", en = "Brisbane UTC+10",      group = "大洋洲", offset = 600, iana = "Australia/Brisbane" },
    { name = "珀斯 UTC+8",      en = "Perth UTC+8",          group = "大洋洲", offset = 480, iana = "Australia/Perth" },
    { name = "奥克兰 UTC+12（夏令时 +13）", en = "Auckland UTC+12 (+13 DST)", group = "大洋洲", offset = 720, iana = "Pacific/Auckland", dst = "NZ" },

    -- 非洲
    -- 埃及 2023 年恢复夏令时，规则与 EU 接近但不完全一致；误差最多一小时，
    -- 换取少一套规则，这里按固定偏移处理。
    { name = "开罗 UTC+2",        en = "Cairo UTC+2",         group = "非洲", offset = 120, iana = "Africa/Cairo" },
    { name = "南非 UTC+2",        en = "South Africa UTC+2",  group = "非洲", offset = 120, iana = "Africa/Johannesburg" },
    { name = "东非 UTC+3",        en = "East Africa UTC+3",   group = "非洲", offset = 180, iana = "Africa/Nairobi" },
    { name = "西非 UTC+1",        en = "West Africa UTC+1",   group = "非洲", offset = 60,  iana = "Africa/Lagos" },
    -- 摩洛哥常年 UTC+1，斋月期间临时回拨，这里不做特殊处理
    { name = "摩洛哥 UTC+1",      en = "Morocco UTC+1",       group = "非洲", offset = 60,  iana = "Africa/Casablanca" },
}

M.tz_groups = {
    { key = "亚洲",   text = "亚洲" },
    { key = "欧洲",   text = "欧洲" },
    { key = "美洲",   text = "美洲" },
    { key = "大洋洲", text = "大洋洲" },
    { key = "非洲",   text = "非洲" },
}

-- ------------------------------------------------------------------ 夏令时
-- 规则全部以「当地标准时间 02:00」为切换点（EU 规范是 UTC 01:00，折成
-- 当地标准时间正好 02:00；US 是当地 02:00）。切换当天的个别小时精确到
-- 一小时内，对一块显示到分钟的看板足够。
--
-- start_n / end_n 为正数表示「该月第 n 个周日」，-1 表示「最后一个周日」。
-- south = true 表示南半球：区间跨年，判定条件变成「晚于开始 或 早于结束」。
local DST_RULES = {
    EU = { start_month = 3,  start_n = -1, end_month = 10, end_n = -1 },
    US = { start_month = 3,  start_n = 2,  end_month = 11, end_n = 1 },
    CL = { start_month = 9,  start_n = 1,  end_month = 4,  end_n = 1, south = true },
    AU = { start_month = 10, start_n = 1,  end_month = 4,  end_n = 1, south = true },
    NZ = { start_month = 9,  start_n = -1, end_month = 4,  end_n = 1, south = true },
}

local MONTH_DAYS = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

local function isLeap(y)
    return (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0
end

local function daysInMonth(y, m)
    if m == 2 and isLeap(y) then return 29 end
    return MONTH_DAYS[m] or 30
end

--- 星期几，0 = 周日。纯整数运算（Sakamoto 算法），不受设备时区影响。
local function weekdayOf(y, m, d)
    local t = { 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 }
    if m < 3 then y = y - 1 end
    return (y + math.floor(y / 4) - math.floor(y / 100) + math.floor(y / 400) + t[m] + d) % 7
end

local function nthSunday(y, m, n)
    local first = weekdayOf(y, m, 1)
    return 1 + ((7 - first) % 7) + (n - 1) * 7
end

local function lastSunday(y, m)
    local dim = daysInMonth(y, m)
    return dim - weekdayOf(y, m, dim)
end

--- 把「月/日/时/分」压成一个可比较的整数。月占 1e6 位，日占 1e4 位，
--- 日+时+分的最大值 31*1e4 + 23*100 + 59 = 312359 < 1e6，不会进位串月。
local function stamp(month, day, hour, min)
    return month * 1000000 + day * 10000 + (hour or 0) * 100 + (min or 0)
end

--- 某个时区在指定时刻实际生效的偏移（分钟，含夏令时）
--- @param tz table 时区项（M.timezones 的元素）
--- @param ts number|nil Unix 时间戳，缺省为当前时刻
function M.offsetAt(tz, ts)
    local base = tonumber(tz and tz.offset) or 0
    local rule = tz and tz.dst and DST_RULES[tz.dst]
    if not rule then return base end

    -- 按标准偏移分解出当地时间：DST 的切换点都以当地标准时间为准，
    -- 所以这里绝不能用「已经加了夏令时」的偏移去判断。
    local std = os.date("!*t", (ts or os.time()) + base * 60)
    local y = std.year
    local start_day = (rule.start_n < 0) and lastSunday(y, rule.start_month)
        or nthSunday(y, rule.start_month, rule.start_n)
    local end_day = (rule.end_n < 0) and lastSunday(y, rule.end_month)
        or nthSunday(y, rule.end_month, rule.end_n)
    local s = stamp(rule.start_month, start_day, 2, 0)
    local e = stamp(rule.end_month, end_day, 2, 0)
    local v = stamp(std.month, std.day, std.hour, std.min)

    local in_dst
    if rule.south then
        in_dst = (v >= s) or (v < e)
    else
        in_dst = (v >= s) and (v < e)
    end
    return in_dst and (base + 60) or base
end

-- ------------------------------------------------------------------ 查询辅助
--- 按 IANA 名取时区项，找不到返回 nil
function M.tzByIana(iana)
    for _, t in ipairs(M.timezones) do
        if t.iana == iana then return t end
    end
    return nil
end

--- 离给定坐标最近的城市。第二个返回值是近似距离（公里，1° ≈ 111 km），
--- 调用方用它判断「附近没有收录城市」，好给出提示而不是假装精确匹配。
function M.nearest(lat, lon)
    lat, lon = tonumber(lat), tonumber(lon)
    if not lat or not lon then return nil end
    local best, best_d
    local coslat = math.cos(math.rad(lat))
    for _, c in ipairs(M.cities) do
        local dlat = c.lat - lat
        local dlon = (c.lon - lon) * coslat
        local d = dlat * dlat + dlon * dlon
        if not best_d or d < best_d then
            best, best_d = c, d
        end
    end
    if not best then return nil end
    return best, math.sqrt(best_d) * 111
end

--- 某时区的代表城市：用于「首次运行按设备时区猜一个城市」
function M.defaultCityName(iana)
    for _, c in ipairs(M.cities) do
        if c.tz == iana then return c.name end
    end
    return "北京"
end

--- 设备本地时区偏移（分钟）。读不到一律返回 nil，调用方自备默认值。
--- 优先 os.date("%z")；个别平台（Kindle 某些固件）该字段为空，退回时间差法。
function M.deviceOffsetMinutes()
    local ok, s = pcall(os.date, "%z")
    if ok and type(s) == "string" then
        local sign, hh, mm = s:match("^([%+%-])(%d%d):?(%d%d)$")
        if sign then
            local v = tonumber(hh) * 60 + tonumber(mm)
            return sign == "-" and -v or v
        end
    end
    -- 时间差法：把 UTC 分解结果当本地时间去 os.time，与真实时间戳的差即偏移。
    -- 跨夏令时时可能有 1 小时误差，但只用于首次猜默认时区，可以接受。
    local ok2, diff = pcall(function()
        local utc = os.date("!*t")
        return os.difftime(os.time(), os.time(utc))
    end)
    if ok2 and type(diff) == "number" then
        local v = math.floor(diff / 60 + 0.5)
        -- 归一化到 [-720, 780]，排除解析异常导致的荒谬值
        if v >= -720 and v <= 780 then return v end
    end
    return nil
end

--- 按设备时区猜一个时区项，猜不到返回 nil（调用方回落到北京时间）
function M.guessTimezone()
    local off = M.deviceOffsetMinutes()
    if not off then return nil end
    local best, best_d
    for _, t in ipairs(M.timezones) do
        local d = math.abs(t.offset - off)
        if not best_d or d < best_d then
            best, best_d = t, d
        end
    end
    -- 差超过 2 小时说明表里没有这一带，宁可用默认值也不要猜错
    if best and best_d <= 120 then return best end
    return nil
end

return M
