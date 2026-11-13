--[[--
看板配置（默认骨架，可以提交到 git）

凭据的填写顺序（后者覆盖前者）：
  1) 本文件的 qweather 字段 —— 留空即可，这里只作结构说明
  2) 同目录 dashboard_config.local.lua —— 真实凭据放这里，已被 .gitignore 排除
  3) KOReader 菜单「桌面看板 → 天气服务 → 填写 API Host / API Key」—— 写入
     settings/dashboard_config.lua，优先级最高，改 key 不用插 USB

和风天气控制台：https://console.qweather.com
  · API Host  在「设置」页，形如 abcxyz.qweatherapi.com（不要带 https://）
  · API Key   在「项目管理 → 凭据」里创建
  两者必须属于同一个项目，且该项目已开通「天气预报」与「空气质量」数据。
--]]

return {
    -- 天气数据源。目前只实现和风天气；保留此字段便于以后扩展
    provider = "qweather",

    qweather = {
        api_host = "",
        api_key = "",
        credential_id = "",
        project = "",
    },

    -- 天气拉取间隔（秒）。免费额度 5 万次/月，一小时一次约 700 次/月，余量充足。
    -- 菜单「省电设置 → 天气更新」里改的优先级更高；这里只作默认值。
    update_interval = 60 * 60,

    -- 和风拿不到数据时是否降级到 Open-Meteo（免凭据、免 API Key）。
    -- 只作兜底，界面底部会标注「天气 Open-Meteo（降级）」。设为 false 则关闭降级
    fallback_openmeteo = true,

    -- 和风天气要求在展示数据时保留数据来源声明
    show_attribution = true,
}
