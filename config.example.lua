-- WeRead KOReader Plugin 高级配置示例
--
-- 普通用户优先使用：
--   工具 → 微信读书 → 设置 → 账号管理 → 微信扫码登录
--
-- 扫码登录成功后，插件会将 Cookie、API Key 和账号信息保存到 KOReader
-- 运行设置中，因此通常不需要创建 config.lua。
--
-- 仅在需要手动恢复账号、配置公众号凭据或调整高级选项时，才将本文件
-- 复制为 config.lua。config.lua 可能包含敏感凭据，绝不能提交到 GitHub、
-- 放入 Release 压缩包或发送给其他人。

return {
    -- 可选：官方 API Key，用于书架浏览和搜索。
    -- 留空不会覆盖扫码登录已经保存的 API Key。
    api_key = "",

    -- 可选：从浏览器 /web/book/read 请求复制的完整 cURL。
    -- 插件会提取 Cookie 和阅读时间上报所需的 payload 字段。
    curl = [[
]],

    -- 可选：从浏览器 /web/mp/articles 请求复制的完整 cURL。
    -- 插件会尝试提取 Cookie、x-wr-ticket 和 x-wrpa-0。
    mp_curl = [[
]],

    -- 可选：直接粘贴原始 Cookie header。
    -- 仅在 curl 为空时作为备用来源。
    cookie = [[
]],

    -- 可选：公众号文章列表可能需要的浏览器请求头。
    -- 也可以在插件弹出的输入框中粘贴 x-wr-ticket 或完整 cURL。
    wr_ticket = "",
    wr_wrpa = "",

    -- 进度同步选项目前仍处于开发阶段，菜单中的对应功能暂时禁用。
    sync = {
        pull_on_open = true,
        upload_on_close = true,
        ask_on_conflict = true,
        upload_interval_minutes = 0,
    },

    -- 下载和缓存偏好。
    cache = {
        download_book_images = true,
        download_mp_images = false,

        -- 保留用于兼容旧配置；当前整书下载是否包含划线和想法，主要由
        -- “下载完整书籍”与“下载完整书籍（带划线和想法）”入口决定。
        download_underlines_and_thoughts = false,

        show_annotations = true,
        max_size_mb = 1024,
    },

    -- 阅读时间上报。是否启用和目标书籍优先通过插件菜单设置。
    read_report = {
        interval_seconds = 30,
        report_on_open = true,
    },

    -- 书架排序。
    shelf = {
        sort_order = "time_desc",
    },
}
