--[[--
城市与时区数据

城市坐标为市政府驻地中心点，用于向和风天气请求（请求时会截到两位小数），
精度对天气而言远超所需（差几公里不影响结果）。

`name` 是中文名，同时充当设置里 `dashboard_city` 的**键**，不能改；
`en` 只在英文界面下用于显示，缺省时退回 `name`。

时区采用「UTC 偏移 + IANA 名称」双字段：
  offset 用于本地时钟/日期/农历计算（纯算术，不依赖设备时区库）
  iana   用于向天气接口声明数据所属时区，保证当日最高最低温归属正确
--]]

return {
    cities = {
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
    },

    -- offset 单位为分钟
    timezones = {
        { name = "北京时间 UTC+8", en = "Beijing Time UTC+8",   offset = 480,  iana = "Asia/Shanghai" },
        { name = "新疆时间 UTC+6", en = "Xinjiang Time UTC+6",  offset = 360,  iana = "Asia/Urumqi" },
        { name = "东京 UTC+9",     en = "Tokyo UTC+9",          offset = 540,  iana = "Asia/Tokyo" },
        { name = "曼谷 UTC+7",     en = "Bangkok UTC+7",        offset = 420,  iana = "Asia/Bangkok" },
        { name = "印度 UTC+5:30",  en = "India UTC+5:30",       offset = 330,  iana = "Asia/Kolkata" },
        { name = "莫斯科 UTC+3",   en = "Moscow UTC+3",         offset = 180,  iana = "Europe/Moscow" },
        { name = "中欧 UTC+1",     en = "Central Europe UTC+1", offset = 60,   iana = "Europe/Berlin" },
        { name = "伦敦 UTC+0",     en = "London UTC+0",         offset = 0,    iana = "Europe/London" },
        { name = "美东 UTC-5",     en = "US Eastern UTC-5",     offset = -300, iana = "America/New_York" },
        { name = "美西 UTC-8",     en = "US Pacific UTC-8",     offset = -480, iana = "America/Los_Angeles" },
    },
}
