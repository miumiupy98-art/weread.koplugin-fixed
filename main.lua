local BD = require("ui/bidi")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Dispatcher = require("dispatcher")
local DownloadDialog = require("lib.download_dialog")
local Event = require("ui/event")
local ProgressbarDialog = require("ui/widget/progressbardialog")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local logger = require("logger")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local PathChooser = require("ui/widget/pathchooser")
local QRMessage = require("ui/widget/qrmessage")
local time = require("ui/time")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local T = require("ffi/util").template

local Cookie = require("lib.cookie")
local Client = require("lib.client")
local Content = require("lib.content")
local Crypto = require("lib.crypto")
local I18n = require("lib.i18n")
local Settings = require("lib.settings")
local Thoughts = require("lib.thoughts")
local WeRead = require("lib.weread")

-- `_` is the translation function; never reuse it as a loop placeholder in this file.
local function _(text)
    return I18n.tr(text)
end

local LOG_MODULE = "[WeRead]"
local unpack_args = unpack or table.unpack

local function log_error(err)
    local text = tostring(err):gsub("[%c]+", " ")
    if #text > 500 then
        return text:sub(1, 500) .. "..."
    end
    return text
end

local function display_error(err)
    local text = tostring(err)
    text = text:match("^[^\r\n]+") or text
    if #text > 300 then
        return text:sub(1, 300) .. "..."
    end
    return text
end

local function file_exists(path)
    if type(path) ~= "string" or path == "" then
        return false
    end
    local file = io.open(path, "rb")
    if not file then
        return false
    end
    file:close()
    return true
end

local function config_auth_fingerprint(config)
    local parts = {}
    for _, key in ipairs({ "curl", "cookie", "mp_curl", "wr_ticket", "wr_wrpa" }) do
        local value = type(config[key]) == "string" and config[key] or ""
        table.insert(parts, key .. ":" .. tostring(#value) .. ":" .. value)
    end
    return Crypto.sha256_hex(table.concat(parts, "\n"))
end

local function stable_config_value(value)
    if type(value) ~= "table" then
        return type(value) .. ":" .. tostring(value)
    end
    local keys = {}
    for key in pairs(value) do
        table.insert(keys, tostring(key))
    end
    table.sort(keys)
    local parts = {}
    for _, key in ipairs(keys) do
        table.insert(parts, key .. "=" .. stable_config_value(value[key]))
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function config_preferences_fingerprint(config)
    local preferences = {
        sync = config.sync,
        cache = config.cache,
        read_report = config.read_report,
        shelf = config.shelf,
    }
    return Crypto.sha256_hex(stable_config_value(preferences))
end

local function merge_cookie_tables(current, updates)
    current = current or {}
    for key, value in pairs(updates or {}) do
        current[key] = value
    end
    return current
end

local PLUGIN_VERSION = "0.3.5"

local READ_REPORT_DEFAULT_INTERVAL_SECONDS = 30
local READ_REPORT_DEFAULT_IDLE_TIMEOUT_SECONDS = 10 * 60

local UPDATE_MANIFEST_URL = "https://raw.githubusercontent.com/miumiupy98-art/weread.koplugin-fixed/main/update.json"

local WeReadPlugin = WidgetContainer:extend{
    name = "weread",
    is_doc_only = false,
    version = PLUGIN_VERSION,
}

local function plugin_dir()
    local source = debug.getinfo(1, "S").source or ""
    local path = source:match("^@(.+)$") or source
    return path:match("^(.*)/[^/]+$") or "."
end



local function ota_shell_quote(value)
    value = tostring(value or "")
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function ota_run_cmd(cmd)
    logger.info(LOG_MODULE, "ota cleanup run:", cmd)
    local a, _b, c = os.execute(cmd)
    return a == true or a == 0 or c == 0
end

local function ota_dirname(path)
    return tostring(path or ""):match("^(.*)/[^/]+/?$") or "."
end

local function ota_read_file(path)
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local data = f:read("*a")
    f:close()
    return data
end

local function ota_file_exists(path)
    local f = io.open(path, "rb")
    if f then
        f:close()
        return true
    end
    return false
end

function WeReadPlugin:_otaPaths()
    local pdir = self.plugin_dir or plugin_dir()
    local parent_dir = ota_dirname(pdir)
    local koreader_dir = ota_dirname(parent_dir)
    local ota_root = koreader_dir .. "/weread/ota"
    return {
        parent_dir = parent_dir,
        ota_root = ota_root,
        backup_root = ota_root .. "/backups",
        pending_file = ota_root .. "/pending_cleanup.txt",
    }
end

function WeReadPlugin:_cleanupLegacyPluginBackups(parent_dir)
    -- Old updater versions created folders such as plugins/weread.koplugin.bak-20260709-171935.
    -- They are not real plugins and should not stay in the plugin search directory.
    if not parent_dir or parent_dir == "" then
        return
    end
    ota_run_cmd("find " .. ota_shell_quote(parent_dir) .. " -maxdepth 1 -type d -name 'weread.koplugin.bak-*' -exec rm -rf {} \\;")
end

function WeReadPlugin:_cleanupPendingOtaBackup()
    local paths = self:_otaPaths()
    self:_cleanupLegacyPluginBackups(paths.parent_dir)

    local pending = ota_read_file(paths.pending_file)
    if not pending or pending == "" then
        return
    end

    local backup_dir = pending:match("backup_dir=([^\r\n]+)")
    if backup_dir and backup_dir:sub(1, #paths.backup_root) == paths.backup_root and not backup_dir:find("..", 1, true) then
        ota_run_cmd("rm -rf " .. ota_shell_quote(backup_dir))
    else
        logger.warn(LOG_MODULE, "skip unsafe OTA backup cleanup path:", tostring(backup_dir))
    end

    -- Also remove old backup folders that were already moved to the backup root by previous updater runs.
    -- This is only done after the new plugin has successfully started.
    if ota_file_exists(paths.backup_root) then
        ota_run_cmd("find " .. ota_shell_quote(paths.backup_root) .. " -maxdepth 1 -type d -name 'weread-backup-*' -exec rm -rf {} \\;")
        ota_run_cmd("find " .. ota_shell_quote(paths.backup_root) .. " -maxdepth 1 -type d -name 'weread.koplugin.bak-*' -exec rm -rf {} \\;")
    end

    ota_run_cmd("rm -f " .. ota_shell_quote(paths.pending_file))
    logger.info(LOG_MODULE, "OTA backup cleanup completed")
end

function WeReadPlugin:scheduleOtaBackupCleanup()
    UIManager:scheduleIn(3, function()
        local ok, err = pcall(function()
            self:_cleanupPendingOtaBackup()
        end)
        if not ok then
            logger.warn(LOG_MODULE, "OTA backup cleanup failed:", log_error(err))
        end
    end)
end

function WeReadPlugin:init()
    self.version = PLUGIN_VERSION
    math.randomseed(os.time())
    self.plugin_dir = plugin_dir()
    self.settings = Settings:new()
    self.client = Client:new(self.settings)
    self:loadConfigFile("startup")
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)

    -- Reading-time reporting is deliberately tied to an active Reader document.
    -- Never start a background reporting loop from the file manager.
    self._reader_session_gen = 0
    self._report_generation = 0
    self._report_state = "stopped"
    self._report_stop_reason = "startup"
    self._report_consecutive_failures = 0
    self._report_failure_count = 0
    self._report_suspended = false
    self._report_last_activity = nil
    self._report_last_page = nil
    self._report_current_book_id = nil
    self._report_current_book_title = nil
    self._report_current_book_source = nil

    self:scheduleOtaBackupCleanup()
    logger.info(LOG_MODULE, "initialized:", "version=", PLUGIN_VERSION)
end

function WeReadPlugin:loadConfigFile(source)
    source = source or "unknown"
    self._config_error = nil
    local config_path = (self.plugin_dir or plugin_dir()) .. "/config.lua"
    local file = io.open(config_path, "r")
    if not file then
        logger.info(LOG_MODULE, "config.lua not found; using stored settings:", "source=", source)
        return
    end
    file:close()

    local ok, config = pcall(dofile, config_path)
    if not ok then
        self._config_error = tostring(config)
        logger.warn(LOG_MODULE, "config.lua load failed:", "source=", source, log_error(config))
        return
    end
    local preferences_fingerprint = config_preferences_fingerprint(config)
    local stored_preferences_fingerprint = self.settings:get("config_preferences_fingerprint", "")
    local apply_preferences = source == "manual_reload"
        or preferences_fingerprint ~= stored_preferences_fingerprint
    local applied, err = self.settings:apply_config(config, {
        apply_preferences = apply_preferences,
    })
    if not applied then
        self._config_error = err
        logger.warn(LOG_MODULE, "config.lua apply failed:", "source=", source, log_error(err))
        return
    end
    if apply_preferences then
        self.settings:set("config_preferences_fingerprint", preferences_fingerprint)
        logger.info(LOG_MODULE, "config preferences imported:", "source=", source)
    else
        logger.info(LOG_MODULE, "config preferences unchanged; using persisted settings")
    end

    local fingerprint = config_auth_fingerprint(config)
    local stored_fingerprint = self.settings:get("config_auth_fingerprint", "")
    local import_auth = source == "manual_reload" or fingerprint ~= stored_fingerprint
    if import_auth then
        local raw_cookie = ""
        local curl_payload
        local imported_cookies = self.settings:get("cookies", {})
        if type(config.curl) == "string" and config.curl:match("%S") then
            raw_cookie, curl_payload = Cookie.extract_from_curl(config.curl)
        elseif type(config.cookie) == "string" and config.cookie:match("%S") then
            raw_cookie = config.cookie
        end

        if raw_cookie and raw_cookie:match("%S") then
            local cookies = Cookie.parse_cookie_header(raw_cookie)
            if Cookie.has_login_cookie(cookies) then
                imported_cookies = merge_cookie_tables(imported_cookies, cookies)
            end
        end

        local mp_source = type(config.mp_curl) == "string" and config.mp_curl:match("%S")
            and config.mp_curl or config.curl
        if type(mp_source) == "string" then
            local ticket = mp_source:match("%-H%s+['\"][Xx]%-[Ww][Rr]%-[Tt]icket:%s*(.-)['\"]")
            if ticket and ticket ~= "" then
                self.settings:set("wr_ticket", ticket)
            end
            local wrpa = mp_source:match("%-H%s+['\"][Xx]%-[Ww][Rr][Pp][Aa]%-0:%s*(.-)['\"]")
            if wrpa and wrpa ~= "" then
                self.settings:set("wr_wrpa", wrpa)
            end
        end
        if type(config.wr_ticket) == "string" and config.wr_ticket:match("%S") then
            self.settings:set("wr_ticket", config.wr_ticket)
        end
        if type(config.wr_wrpa) == "string" and config.wr_wrpa:match("%S") then
            self.settings:set("wr_wrpa", config.wr_wrpa)
        end
        if type(config.mp_curl) == "string" and config.mp_curl:match("%S") then
            local mp_cookie = Cookie.extract_from_curl(config.mp_curl)
            if mp_cookie and mp_cookie:match("%S") then
                local cookies = Cookie.parse_cookie_header(mp_cookie)
                if Cookie.has_login_cookie(cookies) then
                    imported_cookies = merge_cookie_tables(imported_cookies, cookies)
                end
            end
        end

        if Cookie.has_login_cookie(imported_cookies) then
            self.settings:set("cookies", imported_cookies)
        end

        if curl_payload and curl_payload ~= "" then
            local parsed_ok, payload = pcall(function()
                return self.client:json_decode(curl_payload)
            end)
            if parsed_ok and type(payload) == "table" then
                self.settings:set("curl_payload", payload)
            end
        end
        self.settings:set("config_auth_fingerprint", fingerprint)
        logger.info(LOG_MODULE, "config credentials imported:", "source=", source)
    else
        logger.info(LOG_MODULE, "config credentials unchanged; using persisted credentials")
    end
    self.settings:flush()
    logger.info(LOG_MODULE, "config.lua loaded:", "source=", source)
end

function WeReadPlugin:onDispatcherRegisterActions()
    Dispatcher:registerAction("weread_show", {
        category = "none",
        event = "ShowWeRead",
        title = _("WeRead"),
        filemanager = true,
        reader = true,
    })
    Dispatcher:registerAction("weread_sync_progress", {
        category = "none",
        event = "WeReadSyncProgress",
        title = _("Sync WeRead progress"),
        reader = true,
    })
end

function WeReadPlugin:addToMainMenu(menu_items)
    menu_items.weread = {
        text = _("WeRead"),
        sorting_hint = "tools",
        sub_item_table_func = function()
            return self:getMainMenuItems()
        end,
    }
end

function WeReadPlugin:safeCallback(label, callback)
    return function(...)
        local args = { ... }
        local ok, err = xpcall(function()
            return callback(unpack_args(args))
        end, debug.traceback)
        if not ok then
            self:closeBusy()
            logger.err(LOG_MODULE, "action failed:", label, log_error(err))
            self:showInfo(T(_("%1 failed:\n%2"), label, display_error(err)))
        end
    end
end

function WeReadPlugin:getMainMenuItems()
    local items = {
        {
            text = _("Bookshelf"),
            callback = self:safeCallback(_("Bookshelf"), function()
                self:showBookshelf()
            end),
        },
        {
            text = _("Search"),
            callback = self:safeCallback(_("Search"), function()
                self:showSearch()
            end),
        },
        {
            text = _("Reading time report"),
            sub_item_table_func = function()
                return self:getReadReportMenuItems()
            end,
        },
        {
            text = _("Settings"),
            sub_item_table_func = function()
                return self:getSettingsMenuItems()
            end,
        },
        {
            text = _("检查更新"),
            callback = self:safeCallback(_("检查更新"), function()
                self:checkUpdateWithUI()
            end),
        },
        {
            text = T(_("About (v%1)"), PLUGIN_VERSION),
            callback = function()
                local about_text
                if I18n.is_zh() then
                    about_text = T([[微信读书 KOReader 插件
非官方增强版 Fork v%1
个人测试构建

本项目是 QiuYukang/weread.koplugin 的公开增强版 Fork，不是上游官方版本。

本分支主要增强：
• 插件内微信扫码登录及验证码处理
• Cookie、API Key 和账号信息持久化
• 干净 EPUB 与带划线/想法 EPUB 独立下载
• 想法独立存储并通过自定义弹窗显示
• 划线显示/隐藏及当前书重新下载入口
• 微信读书原书脚注处理
• OTA 更新、SHA-256 校验和更新备份保护
• 账号凭据及设置备份安全清理

上游项目：
https://github.com/QiuYukang/weread.koplugin

本增强分支：
https://github.com/miumiupy98-art/weread.koplugin-fixed

本项目仅用于个人学习和技术研究。请遵守微信读书用户协议、适用许可及相关法律法规。]], PLUGIN_VERSION)
                else
                    about_text = T([[WeRead KOReader Plugin
Unofficial Enhanced Fork v%1
Personal test build

This project is a public enhanced fork of QiuYukang/weread.koplugin and is not an official upstream release.

Main additions maintained by this fork:
• In-plugin QR login and verification-code handling
• Persistent Cookie, API key, and account settings
• Separate clean and annotated EPUB downloads
• Independently stored thoughts with a custom popup
• Annotation visibility controls and re-download actions
• Original-book footnote processing
• OTA updates with SHA-256 verification and backup protection
• Secure credential and settings-backup cleanup

Upstream:
https://github.com/QiuYukang/weread.koplugin

Maintained fork:
https://github.com/miumiupy98-art/weread.koplugin-fixed

For personal learning and technical research. Follow the WeRead user agreement, applicable licenses, and relevant laws.]], PLUGIN_VERSION)
                end
                UIManager:show(InfoMessage:new{
                    text = about_text,
                })
            end,
        },

    }

    if self.ui.document then
        table.insert(items, 1, {
            text = _("Sync progress now") .. "  (" .. _("WIP") .. ")",
            enabled_func = function() return false end,
        })
        table.insert(items, 2, {
            text = _("Book details") .. "  (" .. _("WIP") .. ")",
            enabled_func = function() return false end,
        })
        table.insert(items, 3, {
            text = _("显示/隐藏划线和想法"),
            checked_func = function()
                return self.settings:get("cache").show_annotations ~= false
            end,
            keep_menu_open = true,
            callback = self:safeCallback(_("显示/隐藏划线和想法"), function()
                local cache = self.settings:get("cache")
                cache.show_annotations = not (cache.show_annotations ~= false)
                self.settings:set("cache", cache)
                self.settings:flush()
                logger.info(
                    LOG_MODULE,
                    "annotation visibility changed:",
                    "show=", tostring(cache.show_annotations)
                )
                if cache.show_annotations and not self:currentBookHasAnnotations() then
                    self:showInfo(_("当前缓存书不包含划线和想法。请先使用“重新下载当前书（带划线和想法）”生成新版本。"))
                end
                self:applyAnnotationVisibility()
            end),
        })
        table.insert(items, 4, {
            text = _("重新下载当前书（带划线和想法）"),
            enabled_func = function()
                return self:detectWeReadBook() ~= nil
            end,
            callback = self:safeCallback(_("重新下载当前书（带划线和想法）"), function()
                local book_id = self:detectWeReadBook()
                local books = self.settings:get("books", {})
                local book = book_id and books[book_id]
                if not book then
                    self:showInfo(_("当前书没有关联微信读书元数据。请先从 WeRead 插件缓存中打开这本书。"))
                    return
                end
                self:confirmDownloadAllChapters(book, {
                    annotations = true,
                    suffix = "with-thoughts",
                })
            end),
        })
    end

    return items
end

function WeReadPlugin:getSettingsMenuItems()
    return {
        {
            text = _("Cache management"),
            sub_item_table_func = function()
                return {
                    {
                        text = _("Cache cleanup"),
                        callback = self:safeCallback(_("Cache cleanup"), function()
                            self:showCacheManagement()
                        end),
                    },
                    {
                        text_func = function()
                            return T(_("Cache directory: %1"), BD.dirpath(self.settings:get_download_dir()))
                        end,
                        keep_menu_open = true,
                        callback = self:safeCallback(_("Cache directory"), function(touchmenu_instance)
                            self:showDownloadDirPicker(touchmenu_instance)
                        end),
                    },
                }
            end,
        },
        {
            text = _("Reload config.lua"),
            keep_menu_open = true,
            callback = self:safeCallback(_("Reload config.lua"), function()
                self:loadConfigFile("manual_reload")
                if self._config_error then
                    self:showInfo(T(_("config.lua error:\n%1"), self._config_error))
                else
                    self:showInfo(_("config.lua loaded."))
                end
            end),
        },
        {
            text = _("Renew cookie now"),
            keep_menu_open = true,
            callback = self:safeCallback(_("Renew cookie now"), function()
                self:renewCookieWithUI()
            end),
        },
        {
            text = _("Progress management"),
            sub_item_table_func = function()
                return {
                    {
                        text = _("Pull progress on open"),
                        enabled_func = function() return false end,
                        checked_func = function()
                            return self.settings:get("sync").pull_on_open
                        end,
                    },
                    {
                        text = _("Upload progress on close"),
                        enabled_func = function() return false end,
                        checked_func = function()
                            return self.settings:get("sync").upload_on_close
                        end,
                    },
                }
            end,
        },
        {
            text = _("Download content"),
            sub_item_table_func = function()
                return {
                    {
                        text = _("Book images"),
                        keep_menu_open = true,
                        checked_func = function()
                            return self.settings:get("cache").download_book_images
                        end,
                        callback = self:safeCallback(_("Book images"), function()
                            local cache = self.settings:get("cache")
                            cache.download_book_images = not cache.download_book_images
                            self.settings:set("cache", cache)
                            self.settings:flush()
                            logger.info(
                                LOG_MODULE,
                                "image download setting changed:",
                                "target=book",
                                "enabled=", tostring(cache.download_book_images)
                            )
                        end),
                    },
                    {
                        text = _("Public account article images"),
                        keep_menu_open = true,
                        checked_func = function()
                            return self.settings:get("cache").download_mp_images
                        end,
                        check_callback_updates_menu = true,
                        callback = self:safeCallback(_("Public account article images"), function(touchmenu_instance)
                            local cache = self.settings:get("cache")
                            if cache.download_mp_images then
                                self:setMPImageDownload(false)
                                touchmenu_instance:updateItems()
                                return
                            end
                            UIManager:show(ConfirmBox:new{
                                text = _("Downloading public account article images may significantly increase download time. Continue?"),
                                ok_text = _("Confirm"),
                                ok_callback = self:safeCallback(_("Confirm"), function()
                                    self:setMPImageDownload(true)
                                    touchmenu_instance:updateItems()
                                end),
                                cancel_text = _("Cancel"),
                            })
                        end),
                    },
                }
            end,
        },
        {
            text = _("Bookshelf sort order"),
            sub_item_table_func = function()
                return self:getShelfSortMenuItems()
            end,
        },
        {
            text = _("Account management"),
            sub_item_table_func = function()
                return {
                    {
                        text = _("Scan QR code to log in"),
                        callback = self:safeCallback(_("QR login"), function()
                            self:startQRLogin()
                        end),
                    },
                    {
                        text = _("Account status"),
                        callback = self:safeCallback(_("Account status"), function()
                            self:showAccountStatus()
                        end),
                    },
                    {
                        text = _("Manual cookie/cURL import"),
                        callback = self:safeCallback(_("Manual cookie/cURL import"), function()
                            self:showImportCookieDialog()
                        end),
                    },
                    {
                        text = _("Clear account data"),
                        keep_menu_open = true,
                        callback = self:safeCallback(_("Clear account data"), function()
                            self:confirmClearAccount()
                        end),
                    },
                }
            end,
        },
    }
end

function WeReadPlugin:setMPImageDownload(enabled)
    local cache = self.settings:get("cache")
    cache.download_mp_images = enabled == true
    self.settings:set("cache", cache)
    self.settings:flush()
    logger.info(
        LOG_MODULE,
        "image download setting changed:",
        "target=mp",
        "enabled=", tostring(cache.download_mp_images)
    )
end

-- Returns true if the directory is usable (creatable and writable), else false + message.
function WeReadPlugin:validateDownloadDir(path)
    local lfs = require("libs/libkoreader-lfs")
    if type(path) ~= "string" or path == "" then
        return false, _("Invalid path.")
    end
    if not lfs.attributes(path, "mode") then
        os.execute("mkdir -p " .. string.format("%q", path))
        if not lfs.attributes(path, "mode") then
            return false, _("Directory does not exist and could not be created.")
        end
    end
    local test_file = path .. "/.weread_write_test"
    local f = io.open(test_file, "w")
    if not f then
        return false, _("Directory is not writable.")
    end
    f:close()
    os.remove(test_file)
    return true
end

function WeReadPlugin:showDownloadDirPicker(touchmenu_instance)
    local current = self.settings:get_download_dir()
    local path_chooser = PathChooser:new{
        select_directory = true,
        select_file = false,
        path = current,
        onConfirm = function(path)
            local ok, err = self:validateDownloadDir(path)
            if not ok then
                self:showInfo(T(_("Cannot use this directory: %1"), err))
                return
            end
            local old_dir = self.settings:get_download_dir()
            self.settings:set_download_dir(path)
            logger.info(LOG_MODULE, "download directory changed:", path)
            if touchmenu_instance then
                touchmenu_instance:updateItems()
            end
            self:offerMoveBooksToNewDir(old_dir, path)
        end,
    }
    UIManager:show(path_chooser)
end

-- After the download directory changes, offer to move already-cached books from
-- their old locations into the new directory. Without this, old files stay behind
-- as orphans (still reachable via the stored paths, but not under the new root).
function WeReadPlugin:offerMoveBooksToNewDir(old_dir, new_dir)
    if old_dir == new_dir then
        self:showInfo(T(_("Download directory set to:\n%1"), new_dir))
        return
    end
    local lfs = require("libs/libkoreader-lfs")
    local books = self.settings:get("books", {})
    local movable = {}
    for book_id, book in pairs(books) do
        local src = Content.book_resolved_dir(self.settings, book_id, book)
        local dst = Content.book_cache_dir(self.settings, book_id)
        if src ~= dst then
            local attr = lfs.attributes(src)
            if attr and attr.mode == "directory" then
                table.insert(movable, { book_id = book_id, src = src, dst = dst })
            end
        end
    end
    if #movable == 0 then
        self:showInfo(T(_("Download directory set to:\n%1"), new_dir))
        return
    end
    UIManager:show(ConfirmBox:new{
        text = T(_("Download directory changed. Move %1 cached book(s) to the new location?"), tostring(#movable)),
        ok_text = _("Move"),
        ok_callback = function()
            self:moveBooksToNewDir(movable, new_dir)
        end,
        cancel_text = _("Keep"),
        cancel_callback = function()
            self:showInfo(T(_("Download directory set to:\n%1\nExisting downloads stay in the old location."), new_dir))
        end,
    })
end

function WeReadPlugin:moveBooksToNewDir(movable, new_dir)
    self:showBusy(_("Moving cached books..."))
    UIManager:scheduleIn(0.1, function()
        local books = self.settings:get("books", {})
        local moved, skipped, failed = 0, 0, 0
        for _i, m in ipairs(movable) do
            local ok, reason = self:moveBookDir(m.src, m.dst)
            if ok then
                local book = books[m.book_id]
                if book then
                    book.cache_dir = m.dst
                    book.cached_file = self:remapCachedPath(book.cached_file, m.dst)
                    if type(book.cached_chapters) == "table" then
                        for uid, path in pairs(book.cached_chapters) do
                            book.cached_chapters[uid] = self:remapCachedPath(path, m.dst)
                        end
                    end
                end
                moved = moved + 1
            elseif reason == "target_exists" then
                skipped = skipped + 1
                logger.warn(LOG_MODULE, "skip move, target exists:", m.dst)
            else
                failed = failed + 1
                logger.err(LOG_MODULE, "move book cache failed:", m.src, "->", m.dst)
            end
        end
        self.settings:set("books", books)
        self.settings:flush()
        self:closeBusy()
        if skipped == 0 and failed == 0 then
            self:showInfo(T(_("Moved %1 book(s) to:\n%2"), tostring(moved), new_dir))
        else
            self:showInfo(T(_("Moved %1 book(s). %2 skipped (target already exists), %3 failed. These stay in the old location."), tostring(moved), tostring(skipped), tostring(failed)))
        end
    end)
end

-- Move one book directory to dst. Uses `mv`, which (unlike os.rename) handles
-- moves across filesystems, e.g. internal storage to an SD card. Returns
-- true on success, or false plus a reason ("target_exists" / "move_failed").
function WeReadPlugin:moveBookDir(src, dst)
    if src == dst then
        return true
    end
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(dst) then
        -- The target already exists. Since the new directory is user-selected, it
        -- may be unrelated user data that only happens to share the sanitized name.
        -- Never delete it; leave the book in its old location instead.
        return false, "target_exists"
    end
    local parent = dst:match("^(.*)/[^/]+$")
    if parent then
        os.execute("mkdir -p " .. string.format("%q", parent))
    end
    local status = os.execute("mv -f " .. string.format("%q", src) .. " " .. string.format("%q", dst))
    if status == true or status == 0 then
        return true
    end
    return false, "move_failed"
end

-- Rewrite a stored absolute file path to sit under the new book directory,
-- keeping the original filename.
function WeReadPlugin:remapCachedPath(path, dst)
    if type(path) ~= "string" then
        return path
    end
    local name = path:match("[^/]+$")
    if not name then
        return path
    end
    return dst .. "/" .. name
end

local SHELF_SORT_OPTIONS = {
    { key = "time_desc", label = _("Last read time (newest first)") },
    { key = "time_asc",  label = _("Last read time (oldest first)") },
    { key = "default",   label = _("Default order") },
    { key = "name_asc",  label = _("Title A-Z") },
    { key = "name_desc", label = _("Title Z-A") },
}

local function shelfSortLabel(sort_key)
    for _i, opt in ipairs(SHELF_SORT_OPTIONS) do
        if opt.key == sort_key then
            return opt.label
        end
    end
    return SHELF_SORT_OPTIONS[1].label
end

function WeReadPlugin:getShelfSortMenuItems()
    local items = {}
    for _i, opt in ipairs(SHELF_SORT_OPTIONS) do
        local current_opt = opt
        table.insert(items, {
            text = current_opt.label,
            checked_func = function()
                return self.settings:get("shelf").sort_order == current_opt.key
            end,
            callback = function()
                local shelf = self.settings:get("shelf")
                shelf.sort_order = current_opt.key
                self.settings:set("shelf", shelf)
                self.settings:flush()
                if self._shelf_refresh then
                    self._shelf_refresh()
                end
            end,
        })
    end
    return items
end

local SHELF_FILTER_OPTIONS = {
    { dim = "reading",  value = "finished",       label = _("Only show finished books"),       short = _("Finished") },
    { dim = "reading",  value = "unfinished",     label = _("Only show unfinished books"),     short = _("Unfinished") },
    { dim = "download", value = "downloaded",     label = _("Only show downloaded books"),     short = _("Downloaded") },
    { dim = "download", value = "not_downloaded", label = _("Only show not-downloaded books"), short = _("Not downloaded") },
}

function WeReadPlugin:shelfFilterSummary()
    local filters = self.shelf_filters or {}
    local parts = {}
    for _i, opt in ipairs(SHELF_FILTER_OPTIONS) do
        if filters[opt.dim] == opt.value then
            table.insert(parts, opt.short)
        end
    end
    if #parts == 0 then
        return _("All")
    end
    return table.concat(parts, " / ")
end

function WeReadPlugin:saveShelfFilters()
    local shelf = self.settings:get("shelf")
    shelf.filter_reading = self.shelf_filters and self.shelf_filters.reading or nil
    shelf.filter_download = self.shelf_filters and self.shelf_filters.download or nil
    self.settings:set("shelf", shelf)
    self.settings:flush()
end

function WeReadPlugin:bookMatchesFilters(book, saved_books, downloaded_cache)
    local filters = self.shelf_filters or {}
    if filters.reading == "finished" and book.finishReading ~= 1 then return false end
    if filters.reading == "unfinished" and book.finishReading == 1 then return false end
    if filters.download then
        local is_downloaded = self:isBookDownloaded(book, saved_books, downloaded_cache)
        if filters.download == "downloaded" and not is_downloaded then return false end
        if filters.download == "not_downloaded" and is_downloaded then return false end
    end
    return true
end

function WeReadPlugin:showShelfSortOptions(on_sorted)
    local dialog
    local current_sort = self.settings:get("shelf").sort_order or "default"
    local buttons = {}
    for _i, opt in ipairs(SHELF_SORT_OPTIONS) do
        local current_opt = opt
        table.insert(buttons, {
            {
                text = current_opt.label,
                checked_func = function()
                    return current_opt.key == current_sort
                end,
                callback = function()
                    UIManager:nextTick(function()
                        UIManager:close(dialog)
                        local shelf = self.settings:get("shelf")
                        shelf.sort_order = current_opt.key
                        self.settings:set("shelf", shelf)
                        self.settings:flush()
                        if on_sorted then on_sorted() end
                    end)
                end,
            },
        })
    end
    dialog = ButtonDialog:new{
        title = _("Sort by"),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function WeReadPlugin:showShelfFilterOptions(on_changed)
    local dialog
    self.shelf_filters = self.shelf_filters or {}
    local filters = self.shelf_filters
    local buttons = {
        {
            {
                text = _("All"),
                checked_func = function()
                    return filters.reading == nil and filters.download == nil
                end,
                callback = function()
                    UIManager:nextTick(function()
                        UIManager:close(dialog)
                        filters.reading = nil
                        filters.download = nil
                        self:saveShelfFilters()
                        if on_changed then on_changed() end
                    end)
                end,
            },
        },
    }
    for _i, opt in ipairs(SHELF_FILTER_OPTIONS) do
        local current_opt = opt
        table.insert(buttons, {
            {
                text = current_opt.label,
                checked_func = function()
                    return filters[current_opt.dim] == current_opt.value
                end,
                callback = function()
                    UIManager:nextTick(function()
                        UIManager:close(dialog)
                        filters[current_opt.dim] = (filters[current_opt.dim] == current_opt.value) and nil or current_opt.value
                        self:saveShelfFilters()
                        if on_changed then on_changed() end
                    end)
                end,
            },
        })
    end
    dialog = ButtonDialog:new{
        title = _("Filter by"),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function WeReadPlugin:isBookDownloaded(book, saved_books, downloaded_cache)
    local book_id = book.book_id or book.bookId
    if not book_id then
        return false
    end
    if downloaded_cache and downloaded_cache[book_id] ~= nil then
        return downloaded_cache[book_id]
    end
    local record = (saved_books or self.settings:get("books", {}))[book_id]
    local is_downloaded = record ~= nil and file_exists(record.cached_file)
    if downloaded_cache then
        downloaded_cache[book_id] = is_downloaded
    end
    return is_downloaded
end

function WeReadPlugin:shelfToolbarItems(with_filters, refresh)
    local sort_order = self.settings:get("shelf").sort_order
    local items = {
        {
            text = _("Sort"),
            mandatory = T(_("%1 \u{25BE}"), shelfSortLabel(sort_order)),
            callback = self:safeCallback(_("Sort"), function()
                self:showShelfSortOptions(refresh)
            end),
        },
    }
    if with_filters then
        table.insert(items, {
            text = _("Filter"),
            mandatory = T(_("%1 \u{25BE}"), self:shelfFilterSummary()),
            callback = self:safeCallback(_("Filter"), function()
                self:showShelfFilterOptions(refresh)
            end),
        })
    end
    items[#items].separator = true
    return items
end

function WeReadPlugin:showCacheManagement()
    local lfs = require("libs/libkoreader-lfs")
    local books = self.settings:get("books", {})
    local items = {}
    local entries = {}
    local seen_dirs = {}
    local total_size = 0
    local mp_total_size = 0

    local function directory_stats(path)
        local size = 0
        local file_count = 0
        local ok, iter, dir_obj = pcall(lfs.dir, path)
        if not ok then
            return size, file_count
        end
        for entry in iter, dir_obj do
            if entry ~= "." and entry ~= ".." then
                local child = path .. "/" .. entry
                local attr = lfs.attributes(child)
                if attr and attr.mode == "file" then
                    size = size + (attr.size or 0)
                    file_count = file_count + 1
                elseif attr and attr.mode == "directory" then
                    local child_size, child_count = directory_stats(child)
                    size = size + child_size
                    file_count = file_count + child_count
                end
            end
        end
        return size, file_count
    end

    local function add_cache_entry(book_id, title, book_dir)
        if seen_dirs[book_dir] then
            return
        end
        seen_dirs[book_dir] = true
        local size, file_count = directory_stats(book_dir)
        if file_count == 0 then
            return
        end
        local is_mp = WeRead.is_mp_book(book_id)
        total_size = total_size + size
        if is_mp then
            mp_total_size = mp_total_size + size
        end
        table.insert(entries, {
            book_id = book_id,
            title = title or book_id,
            size = size,
            file_count = file_count,
            is_mp = is_mp,
        })
    end

    -- Only list plugin-owned entries tracked in the books table. Scanning the
    -- filesystem would list unrelated subfolders when cache_dir is a user-selected
    -- library directory, and deleting one would rm -rf a non-WeRead folder.
    for book_id, book in pairs(books) do
        add_cache_entry(book_id, book.title, Content.book_resolved_dir(self.settings, book_id, book))
    end

    table.sort(entries, function(a, b)
        if a.is_mp ~= b.is_mp then
            return a.is_mp
        end
        return tostring(a.title):lower() < tostring(b.title):lower()
    end)

    local total_str = total_size < 1024 * 1024
        and string.format("%.0f KB", total_size / 1024)
        or string.format("%.1f MB", total_size / 1024 / 1024)
    local mp_total_str = mp_total_size < 1024 * 1024
        and string.format("%.0f KB", mp_total_size / 1024)
        or string.format("%.1f MB", mp_total_size / 1024 / 1024)
    table.insert(items, {
        text = T(_("[Cleanup] Clear all public account cache (%1)"), mp_total_str),
        callback = self:safeCallback(_("Clear all public account cache"), function()
            UIManager:show(ConfirmBox:new{
                text = _("Clear all public account cache? Downloaded articles and cached article lists will be deleted."),
                ok_text = _("Clear"),
                ok_callback = function()
                    self:clearAllMPCache()
                    self:refreshCacheManagement(_("Public account cache cleared"))
                end,
            })
        end),
    })
    table.insert(items, {
        text = T(_("[Cleanup] Clear all cache (%1)"), total_str),
        separator = true,
        callback = self:safeCallback(_("Clear all cache"), function()
            UIManager:show(ConfirmBox:new{
                text = _("Clear all cache? Downloaded books and articles will be deleted."),
                ok_text = _("Clear"),
                ok_callback = function()
                    self:clearAllCache()
                    self:refreshCacheManagement(_("Cache cleared"))
                end,
            })
        end),
    })

    for entry_index, entry in ipairs(entries) do
        local size_str = entry.size < 1024 * 1024
            and string.format("%.0f KB", entry.size / 1024)
            or string.format("%.1f MB", entry.size / 1024 / 1024)
        table.insert(items, {
            text = entry.title,
            post_text = T(_("%1 files, %2"), tostring(entry.file_count), size_str),
            mandatory = entry.is_mp and _("Public Account") or "",
            callback = self:safeCallback(entry.title, function()
                self:confirmClearBookCache(entry.book_id, entry.title)
            end),
        })
    end

    self.cache_menu = self:showList(_("Cache management"), items, _("No cached items"))
end

function WeReadPlugin:refreshCacheManagement(message)
    if self.cache_menu then
        UIManager:close(self.cache_menu)
        self.cache_menu = nil
    end
    self:showCacheManagement()
    if message then
        self:showTransientInfo(message)
    end
end

function WeReadPlugin:confirmClearBookCache(book_id, title, on_cleared)
    UIManager:show(ConfirmBox:new{
        text = T(_("Clear cache for \"%1\"?"), title),
        ok_text = _("Clear"),
        ok_callback = function()
            self:clearBookCache(book_id)
            if on_cleared then
                on_cleared()
                self:showTransientInfo(_("Cache cleared"))
            else
                self:refreshCacheManagement(_("Cache cleared"))
            end
        end,
    })
end

function WeReadPlugin:clearBookCache(book_id)
    local books = self.settings:get("books", {})
    local cache_dir = Content.book_resolved_dir(self.settings, book_id, books[book_id])
    os.execute("rm -rf " .. string.format("%q", cache_dir))
    if books[book_id] then
        books[book_id].cached_file = nil
        books[book_id].cached_chapters = nil
        books[book_id].cache_dir = nil
        if WeRead.is_mp_book(book_id) then
            books[book_id].mp_articles = nil
            books[book_id].mp_articles_time = nil
        end
        self.settings:set("books", books)
        self.settings:flush()
    end
    self:refreshShelfCacheIndicators()
end

function WeReadPlugin:clearAllMPCache()
    -- Delete each MP book's real directory (which may sit under an old download
    -- root) rather than scanning only the current cache_dir, and only touch
    -- plugin-owned entries tracked in the books table.
    local books = self.settings:get("books", {})
    for book_id, book in pairs(books) do
        if WeRead.is_mp_book(book_id) then
            os.execute("rm -rf " .. string.format("%q", Content.book_resolved_dir(self.settings, book_id, book)))
            book.cached_file = nil
            book.cached_chapters = nil
            book.cache_dir = nil
            book.mp_articles = nil
            book.mp_articles_time = nil
        end
    end
    self.settings:set("books", books)
    self.settings:flush()
end

function WeReadPlugin:clearAllCache()
    local books = self.settings:get("books", {})
    for book_id, book in pairs(books) do
        os.execute("rm -rf " .. string.format("%q", Content.book_resolved_dir(self.settings, book_id, book)))
        book.cached_file = nil
        book.cached_chapters = nil
        book.cache_dir = nil
        book.mp_articles = nil
        book.mp_articles_time = nil
    end
    self.settings:set("books", books)
    self.settings:flush()
end

function WeReadPlugin:showInfo(text)
    UIManager:show(InfoMessage:new{
        text = text,
    })
end

function WeReadPlugin:showTransientInfo(text, timeout)
    UIManager:show(InfoMessage:new{
        text = text,
        timeout = timeout or 2,
    })
end

function WeReadPlugin:showBusy(text)
    self:closeBusy()
    self.busy_message = InfoMessage:new{
        text = text,
        dismissable = false,
    }
    UIManager:show(self.busy_message)
    self:refreshUI()
end

function WeReadPlugin:closeBusy()
    if self.busy_message then
        UIManager:close(self.busy_message)
        self.busy_message = nil
        self:refreshUI()
    end
end

function WeReadPlugin:refreshUI()
    if UIManager.forceRePaint then
        local ok, err = pcall(function()
            UIManager:forceRePaint()
        end)
        if not ok then
            logger.warn(LOG_MODULE, "forceRePaint failed:", log_error(err))
        end
    end
end

function WeReadPlugin:showInputDialog(dialog)
    UIManager:show(dialog)
    if dialog.onShowKeyboard then
        local ok, err = pcall(function()
            dialog:onShowKeyboard()
        end)
        if not ok then
            logger.warn(LOG_MODULE, "failed to show keyboard:", log_error(err))
        end
    end
end

function WeReadPlugin:isNetworkOnline()
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if not ok or not NetworkMgr or not NetworkMgr.isOnline then
        return true
    end
    local ok_online, online = pcall(function()
        return NetworkMgr:isOnline()
    end)
    if not ok_online then
        logger.warn(LOG_MODULE, "network status check failed:", log_error(online))
        return true
    end
    return online == true
end

function WeReadPlugin:showOffline(label)
    self:closeBusy()
    logger.warn(LOG_MODULE, "network unavailable:", label)
    self:showInfo(T(_("%1 failed:\n%2"), label, _("No network connection. Please connect Wi-Fi and try again.")))
end

function WeReadPlugin:runOnlineTask(label, callback, delay)
    if not self:isNetworkOnline() then
        self:showOffline(label)
        return false
    end
    UIManager:scheduleIn(delay or 0.1, function()
        local ok, err = xpcall(callback, debug.traceback)
        if not ok then
            self:closeBusy()
            logger.err(LOG_MODULE, "network task failed:", label, log_error(err))
            self:showInfo(T(_("%1 failed:\n%2"), label, display_error(err)))
        end
    end)
    return true
end

function WeReadPlugin:runNetworkAction(label, action)
    self:runOnlineTask(label, function()
        local ok, result = pcall(action)
        if ok then
            self:showInfo(result or label)
        else
            logger.err(LOG_MODULE, "network action failed:", label, log_error(result))
            self:showInfo(T(_("%1 failed:\n%2"), label, display_error(result)))
        end
    end)
end

function WeReadPlugin:showList(title, items, empty_text)
    if not items or #items == 0 then
        self:showInfo(empty_text or _("No items."))
        return
    end
    local menu = Menu:new{
        title = title,
        item_table = items,
        is_borderless = true,
        title_bar_fm_style = true,
    }
    UIManager:show(menu)
    return menu
end

function WeReadPlugin:showImportCookieDialog()
    local dialog
    dialog = InputDialog:new{
        title = _("Import WeRead cookie or cURL"),
        input = "",
        input_type = "text",
        description = _("Paste a raw Cookie header or a full cURL copied from /web/book/read."),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = self:safeCallback(_("Cancel"), function()
                        UIManager:close(dialog)
                    end),
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = self:safeCallback(_("Save"), function()
                        local input = dialog:getInputText()
                        local cookie_header, curl_data = Cookie.extract_from_curl(input)
                        local cookies = Cookie.parse_cookie_header(cookie_header)
                        if not Cookie.has_login_cookie(cookies) then
                            self:showInfo(_("Could not find a valid wr_skey cookie."))
                            return
                        end
                        local current_cookies = self.settings:get("cookies", {})
                        self.settings:set("cookies", merge_cookie_tables(current_cookies, cookies))
                        if curl_data and curl_data ~= "" then
                            local ok, payload = pcall(function()
                                return self.client:json_decode(curl_data)
                            end)
                            if ok and type(payload) == "table" then
                                self.settings:set("curl_payload", payload)
                            end
                        end
                        self.settings:flush()
                        UIManager:close(dialog)
                        self:renewCookieWithUI()
                    end),
                },
            },
        },
    }
    self:showInputDialog(dialog)
end

function WeReadPlugin:renewCookieWithUI()
    if not self.settings:is_cookie_configured() then
        self:showInfo(_("Cookie is not configured."))
        return
    end
    self:runNetworkAction(_("Renew cookie"), function()
        local result = self.client:renew_cookie()
        if type(result) == "table" and (result.succ == true or tonumber(result.succ) == 1) then
            logger.info(LOG_MODULE, "cookie renewed")
            return _("WeRead cookie renewed.")
        end
        logger.warn(LOG_MODULE, "cookie renewal completed without succ=1")
        return _("Cookie renewal completed, but response did not include succ=1.")
    end)
end

function WeReadPlugin:_closeQRLoginDialog(programmatic)
    local dialog = self._qr_login_dialog
    if not dialog then
        return
    end
    self._qr_login_dialog = nil
    self._qr_login_programmatic_close = programmatic == true
    UIManager:close(dialog)
    self._qr_login_programmatic_close = false
end

function WeReadPlugin:startQRLogin()
    if not self:isNetworkOnline() then
        self:showOffline(_("QR login"))
        return
    end

    self._qr_login_generation = (self._qr_login_generation or 0) + 1
    local generation = self._qr_login_generation
    self.client:cancel_qr_login()
    self:_closeQRLoginDialog(true)
    self:showBusy(_("Getting login QR code..."))

    self:runOnlineTask(_("QR login"), function()
        local ok, uid_or_err = pcall(function()
            return self.client:begin_qr_login()
        end)
        self:closeBusy()
        if generation ~= self._qr_login_generation then
            return
        end
        if not ok then
            logger.err(LOG_MODULE, "get QR login uid failed:", log_error(uid_or_err))
            self:showInfo(T(_("QR login failed:\n%1"), display_error(uid_or_err)))
            return
        end
        self:_showQRLoginCode(uid_or_err, generation)
    end)
end

function WeReadPlugin:_showQRLoginCode(uid, generation)
    local qr_url = "https://weread.qq.com/web/confirm?uid=" .. tostring(uid)
    local dialog
    dialog = QRMessage:new{
        text = qr_url,
        width = Device.screen:getWidth(),
        height = Device.screen:getHeight(),
        dismiss_callback = function()
            if self._qr_login_dialog == dialog then
                self._qr_login_dialog = nil
            end
            if not self._qr_login_programmatic_close
                and generation == self._qr_login_generation then
                self._qr_login_generation = self._qr_login_generation + 1
                self.client:cancel_qr_login()
                self:showTransientInfo(_("QR login cancelled."), 2)
            end
        end,
    }
    self._qr_login_dialog = dialog
    UIManager:show(dialog)
    self:refreshUI()

    -- Allow one event-loop turn to paint the QR before the synchronous long poll.
    UIManager:scheduleIn(0.5, function()
        if generation ~= self._qr_login_generation or self._qr_login_dialog ~= dialog then
            return
        end
        self:_pollQRLogin(uid, generation)
    end)
end

function WeReadPlugin:_pollQRLogin(uid, generation, otp)
    local ok, result = pcall(function()
        return self.client:poll_qr_login(uid, otp or "")
    end)
    if generation ~= self._qr_login_generation then
        return
    end
    if not ok then
        self:_closeQRLoginDialog(true)
        self.client:cancel_qr_login()
        logger.err(LOG_MODULE, "QR login polling failed:", log_error(result))
        self:showInfo(T(_("QR login failed:\n%1"), display_error(result)))
        return
    end

    if result.succeed == true then
        self:_closeQRLoginDialog(true)
        self:_completeQRLogin(result, generation)
        return
    end

    local logic_code = tostring(result.logicCode or "")
    if logic_code == "NEED_OTP" then
        self:_closeQRLoginDialog(true)
        self:_showQRLoginOTP(uid, generation)
    elseif logic_code == "LOGIN_TIMEOUT" then
        self:_closeQRLoginDialog(true)
        self.client:cancel_qr_login()
        self:showInfo(_("The QR code has expired. Please try again."))
    elseif logic_code == "OTP_EXPIRED" then
        self:_closeQRLoginDialog(true)
        self.client:cancel_qr_login()
        self:showInfo(_("The verification code has expired. Please try again."))
    elseif logic_code == "OTP_NOT_MATCH" then
        self:_closeQRLoginDialog(true)
        self:_showQRLoginOTP(uid, generation, _("Incorrect verification code."))
    else
        self:_closeQRLoginDialog(true)
        self.client:cancel_qr_login()
        self:showInfo(T(_("QR login failed:\n%1"), logic_code ~= "" and logic_code or _("Unknown login response")))
    end
end

function WeReadPlugin:_showQRLoginOTP(uid, generation, error_text)
    local dialog
    local description = _("Enter the four-digit verification code shown on your phone.")
    if error_text and error_text ~= "" then
        description = error_text .. "\n\n" .. description
    end
    dialog = InputDialog:new{
        title = _("Verification code required"),
        input = "",
        input_type = "text",
        description = description,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                        if generation == self._qr_login_generation then
                            self._qr_login_generation = self._qr_login_generation + 1
                        end
                        self.client:cancel_qr_login()
                    end,
                },
                {
                    text = _("Verify"),
                    is_enter_default = true,
                    callback = function()
                        local otp = tostring(dialog:getInputText() or "")
                            :gsub("^%s+", ""):gsub("%s+$", "")
                        if not otp:match("^%d%d%d%d$") then
                            self:showInfo(_("The verification code must contain four digits."))
                            return
                        end
                        UIManager:close(dialog)
                        self:showBusy(_("Verifying login..."))
                        self:runOnlineTask(_("QR login"), function()
                            local ok, result = pcall(function()
                                return self.client:poll_qr_login(uid, otp)
                            end)
                            self:closeBusy()
                            if generation ~= self._qr_login_generation then
                                return
                            end
                            if not ok then
                                logger.err(LOG_MODULE, "QR OTP verification failed:", log_error(result))
                                self.client:cancel_qr_login()
                                self:showInfo(T(_("QR login failed:\n%1"), display_error(result)))
                                return
                            end
                            if result.succeed == true then
                                self:_completeQRLogin(result, generation)
                                return
                            end
                            local code = tostring(result.logicCode or "")
                            if code == "OTP_NOT_MATCH" or code == "NEED_OTP" then
                                self:_showQRLoginOTP(uid, generation, _("Incorrect verification code."))
                            elseif code == "OTP_EXPIRED" then
                                self.client:cancel_qr_login()
                                self:showInfo(_("The verification code has expired. Please try again."))
                            else
                                self.client:cancel_qr_login()
                                self:showInfo(T(_("QR login failed:\n%1"), code ~= "" and code or _("Unknown login response")))
                            end
                        end)
                    end,
                },
            },
        },
    }
    self:showInputDialog(dialog)
end

function WeReadPlugin:_completeQRLogin(login_result, generation)
    self:showBusy(_("Completing WeRead login..."))
    self:runOnlineTask(_("QR login"), function()
        local ok, account_or_err = pcall(function()
            return self.client:complete_qr_login(login_result)
        end)
        self:closeBusy()
        if generation ~= self._qr_login_generation then
            return
        end
        if not ok then
            logger.err(LOG_MODULE, "complete QR login failed:", log_error(account_or_err))
            self.client:cancel_qr_login()
            self:showInfo(T(_("QR login failed:\n%1"), display_error(account_or_err)))
            return
        end

        local account_name = account_or_err.name
        if type(account_name) ~= "string" or account_name == "" then
            account_name = _("Unknown account")
        end
        logger.info(LOG_MODULE, "QR login completed")

        -- QR login now supplies all authentication material needed to build the
        -- browser reading context. If a WeRead book is already open, initialize
        -- that context immediately; otherwise it is initialized automatically on
        -- the first reporting tick after a WeRead book is opened.
        local current_book_id = self:detectWeReadBook()
        if current_book_id then
            local context_ok, context_or_err = pcall(function()
                return self:ensureReadReportContext(current_book_id, true)
            end)
            if context_ok then
                logger.info(LOG_MODULE, "read report context initialized after QR login:",
                    "book_id=", current_book_id)
            else
                logger.warn(LOG_MODULE, "read report context initialization deferred:",
                    log_error(context_or_err))
            end
        end

        self:showInfo(T(
            _("WeRead login successful.\n\nAccount: %1\nCookie: %2\nOfficial API key: %3"),
            account_name,
            _("configured"),
            _("configured")
        ))
    end)
end

function WeReadPlugin:showAccountStatus()
    local cookie_status = self.settings:is_cookie_configured() and _("configured") or _("missing")
    local api_status = self.settings:is_api_configured() and _("configured") or _("missing")
    local account = self.settings:get("account", {})
    local account_name = type(account.name) == "string" and account.name or ""
    if account_name == "" then
        account_name = (self.settings:is_cookie_configured() or self.settings:is_api_configured())
            and _("Unknown account") or _("Not logged in")
    end
    local login_method
    if account.login_method == "qr" then
        login_method = _("QR login")
    elseif self.settings:is_cookie_configured() or self.settings:is_api_configured() then
        login_method = _("Manual configuration")
    else
        login_method = _("Not logged in")
    end
    self:showInfo(T(
        _("Account: %1\nLogin method: %2\nCookie: %3\nOfficial API key: %4\nCache directory:\n%5"),
        account_name,
        login_method,
        cookie_status,
        api_status,
        BD.dirpath(self.settings.cache_dir)
    ))
end

function WeReadPlugin:removeLocalCredentialFiles()
    local base = (self.plugin_dir or plugin_dir()) .. "/config.lua"
    for _, path in ipairs({ base, base .. ".old", base .. ".new", base .. ".bak" }) do
        pcall(os.remove, path)
    end
end

function WeReadPlugin:confirmClearAccount()
    UIManager:show(ConfirmBox:new{
        text = _("Clear WeRead cookie, API key, account metadata, settings backups, and local config.lua credentials? Cached books will remain."),
        ok_text = _("Clear"),
        ok_callback = self:safeCallback(_("Clear"), function()
            self._qr_login_generation = (self._qr_login_generation or 0) + 1
            self:_closeQRLoginDialog(true)
            self.client:cancel_qr_login()
            self:removeLocalCredentialFiles()
            self.settings:reset_account()
            self:showInfo(_("WeRead account data and local credential files cleared."))
        end),
    })
end

function WeReadPlugin:getReadReportMenuItems()
    local rr = self.settings:get("read_report")
    return {
        {
            text = _("Enable reading time report"),
            checked_func = function()
                return self.settings:get("read_report").enabled
            end,
            callback = self:safeCallback(_("Enable reading time report"), function()
                local cur = self.settings:get("read_report")
                cur.enabled = not cur.enabled
                -- This build always limits reporting to an active Reader session.
                cur.report_on_open = true
                self.settings:set("read_report", cur)
                self.settings:flush()
                if cur.enabled then
                    if not self:maybeStartReadReport("enabled") then
                        self:showTransientInfo(_("Open a WeRead book to start reading time report"), 2)
                    end
                else
                    self:stopReadReport("disabled")
                end
            end),
        },
        {
            text = T(_("Pause after %1 minutes without page activity"), tostring(math.floor((rr.idle_timeout_seconds or READ_REPORT_DEFAULT_IDLE_TIMEOUT_SECONDS) / 60))),
            enabled_func = function()
                return false
            end,
        },
        {
            text = _("Select target book"),
            post_text = rr.mode == "auto" and _("Auto-associate")
                or (rr.book_title ~= "" and T(_("Manual: %1"), rr.book_title) or _("Not configured")),
            sub_item_table_func = function()
                return self:getReportTargetMenuItems()
            end,
        },
        {
            text = _("Report status"),
            keep_menu_open = true,
            callback = self:safeCallback(_("Report status"), function()
                local cur = self.settings:get("read_report")
                local target
                if self._report_current_book_title then
                    target = self._report_current_book_title
                elseif cur.mode == "manual" and cur.book_title ~= "" then
                    target = cur.book_title
                else
                    target = _("Auto-associate")
                end
                local state_labels = {
                    active = _("Active"),
                    waiting = _("Waiting"),
                    idle = _("Idle"),
                    offline = _("Offline"),
                    suspended = _("Suspended"),
                    error = _("Error"),
                    stopped = _("Stopped"),
                }
                local status = state_labels[self._report_state or "stopped"] or tostring(self._report_state or "stopped")
                local count = self._report_count or 0
                local failures = self._report_failure_count or 0
                local last = self._report_last_time
                    and os.date("%H:%M:%S", self._report_last_time) or "--"
                local activity = self._report_last_activity
                    and tostring(math.max(0, os.time() - self._report_last_activity)) .. _(" seconds ago") or "--"
                local err = self._report_last_error or ""
                local msg = T(_("Report book: %1\nStatus: %2"), target, status)
                    .. "\n" .. T(_("Reported: %1 times, last: %2"), tostring(count), last)
                    .. "\n" .. T(_("Failures: %1, consecutive: %2"), tostring(failures), tostring(self._report_consecutive_failures or 0))
                    .. "\n" .. T(_("Last activity: %1"), activity)
                if self._report_stop_reason and self._report_stop_reason ~= "" then
                    msg = msg .. "\n" .. T(_("Stop reason: %1"), self._report_stop_reason)
                end
                if err ~= "" then
                    msg = msg .. "\n" .. T(_("Last error: %1"), err)
                end
                self:showInfo(msg)
            end),
        },
    }
end

function WeReadPlugin:getReportTargetMenuItems()
    local rr = self.settings:get("read_report")
    return {
        {
            text = _("Auto-associate with WeRead book"),
            checked_func = function()
                return self.settings:get("read_report").mode == "auto"
            end,
            callback = self:safeCallback(_("Auto-associate with WeRead book"), function()
                local cur = self.settings:get("read_report")
                cur.mode = "auto"
                cur.book_id = ""
                cur.book_title = ""
                cur.report_on_open = true
                self.settings:set("read_report", cur)
                self.settings:flush()
                self:stopReadReport("target_mode_changed")
                self:maybeStartReadReport("target_mode_changed")
            end),
        },
        {
            text = _("Manually set report book"),
            checked_func = function()
                return self.settings:get("read_report").mode == "manual"
            end,
            post_text = rr.mode == "manual" and rr.book_title ~= "" and rr.book_title or "",
            callback = self:safeCallback(_("Manually set report book"), function()
                local cur = self.settings:get("read_report")
                cur.mode = "manual"
                cur.report_on_open = true
                self.settings:set("read_report", cur)
                self.settings:flush()
                self:showReadReportBookPicker()
            end),
        },
    }
end

local function normalize_report_path(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    return path:gsub("/+", "/"):gsub("/$", "")
end

function WeReadPlugin:detectWeReadBook()
    if not self.ui.document then
        return nil, nil
    end
    local file = normalize_report_path(self.ui.document.file)
    if not file then
        return nil, nil
    end

    -- First match the exact path saved by the plugin. This supports opening the
    -- downloaded EPUB from KOReader's own file manager or recent-books list.
    local books = self.settings:get("books", {})
    for book_id, book in pairs(books) do
        if type(book) == "table" and normalize_report_path(book.cached_file) == file then
            return tostring(book_id), "cached_file"
        end
    end

    -- Then fall back to the standard cache layout: <cache>/<book_id>/<file>.epub.
    local cache_dir = normalize_report_path(self.settings.cache_dir)
    if cache_dir then
        local prefix = cache_dir .. "/"
        if file:sub(1, #prefix) == prefix then
            local rest = file:sub(#prefix + 1)
            local book_id = rest:match("^([^/]+)")
            if book_id and book_id ~= "" then
                return book_id, "cache_path"
            end
        end
    end
    return nil, nil
end

function WeReadPlugin:resolveReadReportTarget()
    if not self.ui.document then
        return nil, nil, "no_document"
    end

    local detected_id, detected_source = self:detectWeReadBook()
    if detected_id then
        local books = self.settings:get("books", {})
        local book = books[detected_id]
        local title = type(book) == "table" and book.title or detected_id
        return detected_id, title, detected_source or "current_document"
    end

    local rr = self.settings:get("read_report")
    if rr.mode == "manual" and type(rr.book_id) == "string" and rr.book_id ~= "" then
        return rr.book_id, rr.book_title ~= "" and rr.book_title or rr.book_id, "manual"
    end
    return nil, nil, "document_not_weread"
end

function WeReadPlugin:cachedBookFileContainsAnnotations(book)
    if not book or type(book.cached_file) ~= "string" or book.cached_file == "" then
        return false
    end
    local file = io.open(book.cached_file, "rb")
    if not file then
        return false
    end
    local data = file:read("*a") or ""
    file:close()
    return data:find("wr%-underline") ~= nil or data:find("weread%-thought") ~= nil
end

function WeReadPlugin:currentBookHasAnnotations()
    local book_id = self:detectWeReadBook()
    if not book_id then
        return false
    end
    local books = self.settings:get("books", {})
    local book = books[book_id]
    if not book then
        return false
    end
    return book.annotations_cached == true or self:cachedBookFileContainsAnnotations(book)
end

function WeReadPlugin:showReadReportBookPicker()
    if not self.settings:is_api_configured() then
        self:showInfo(_("Set the official API key to browse your WeRead shelf. You can still open a book by pasting a reader URL."))
        return
    end
    self:showBusy(_("Loading bookshelf..."))
    self:runOnlineTask(_("Bookshelf"), function()
        local ok, result = pcall(function()
            return self.client:gateway("/shelf/sync", {})
        end)
        if not ok then
            self:closeBusy()
            logger.err(LOG_MODULE, "load report bookshelf failed:", log_error(result))
            self:showInfo(T(_("Load bookshelf failed:\n%1"), display_error(result)))
            return
        end
        self:closeBusy()
        local all_books = result.books or {}
        local items = {}
        for i, book in ipairs(all_books) do
            if not WeRead.is_mp_book(book.bookId) then
                table.insert(items, {
                    text = book.title or book.bookId or _("Untitled"),
                    post_text = book.author or "",
                    callback = self:safeCallback(book.title or _("Select target book"), function()
                        local rr = self.settings:get("read_report")
                        rr.book_id = book.bookId
                        rr.book_title = book.title or book.bookId
                        self.settings:set("read_report", rr)
                        self.settings:flush()
                        if self._picker_menu then
                            UIManager:close(self._picker_menu)
                            self._picker_menu = nil
                        end
                        self:showTransientInfo(T(_("Target book set: %1"), rr.book_title))
                        self:maybeStartReadReport()
                    end),
                })
            end
        end
        if not items or #items == 0 then
            self:showInfo(_("Your WeRead shelf is empty."))
            return
        end
        self._picker_menu = Menu:new{
            title = _("Select a book to report reading time"),
            item_table = items,
            is_borderless = true,
            title_bar_fm_style = true,
        }
        UIManager:show(self._picker_menu)
    end)
end

function WeReadPlugin:showBookshelf()
    if not self.settings:is_api_configured() then
        self:showInfo(_("Set the official API key to browse your WeRead shelf. You can still open a book by pasting a reader URL."))
        return
    end
    self:showBusy(_("Loading bookshelf..."))
    self:runOnlineTask(_("Bookshelf"), function()
        local ok, result = pcall(function()
            return self.client:gateway("/shelf/sync", {})
        end)
        if not ok then
            self:closeBusy()
            logger.err(LOG_MODULE, "load bookshelf failed:", log_error(result))
            self:showInfo(T(_("Load bookshelf failed:\n%1"), display_error(result)))
            return
        end
        local all_books = result.books or {}
        local shelf = self.settings:get("shelf")
        self.shelf_filters = {
            reading = shelf.filter_reading,
            download = shelf.filter_download,
        }
        self.shelf_regular = {}
        self.shelf_mp = {}
        for _i, book in ipairs(all_books) do
            if WeRead.is_mp_book(book.bookId) then
                table.insert(self.shelf_mp, book)
            else
                table.insert(self.shelf_regular, book)
            end
        end
        self.shelf_books = self.shelf_regular
        self:closeBusy()
        if #self.shelf_mp > 0 then
            self:showShelfTabs()
        else
            self:showShelfPage()
        end
    end)
end

local function sortBooks(books, sort_order)
    if sort_order == "default" or not sort_order then
        return books
    end
    local sorted = {}
    for i, book in ipairs(books) do
        sorted[i] = book
    end
    if sort_order == "time_desc" then
        table.sort(sorted, function(a, b)
            return (a.readUpdateTime or 0) > (b.readUpdateTime or 0)
        end)
    elseif sort_order == "time_asc" then
        table.sort(sorted, function(a, b)
            return (a.readUpdateTime or 0) < (b.readUpdateTime or 0)
        end)
    elseif sort_order == "name_asc" then
        table.sort(sorted, function(a, b)
            return (a.title or "") < (b.title or "")
        end)
    elseif sort_order == "name_desc" then
        table.sort(sorted, function(a, b)
            return (a.title or "") > (b.title or "")
        end)
    end
    return sorted
end

function WeReadPlugin:showShelfPage()
    local books = self.shelf_books or {}
    if #books == 0 then
        self:showInfo(_("Your WeRead shelf is empty."))
        return
    end
    local menu, buildItems
    local function refresh()
        if menu then
            menu:switchItemTable(nil, buildItems())
        end
    end
    buildItems = function()
        local items = self:shelfToolbarItems(true, refresh)
        local sorted = sortBooks(books, self.settings:get("shelf").sort_order)
        local saved_books = self.settings:get("books", {})
        local downloaded_cache = {}
        self._shelf_saved_books = saved_books
        for _i, book in ipairs(sorted) do
            local current_book = book
            if self:bookMatchesFilters(current_book, saved_books, downloaded_cache) then
                local book_id = current_book.book_id or current_book.bookId
                local is_cached = self:isBookDownloaded(current_book, saved_books, downloaded_cache)
                local right_text
                if current_book.readUpdateTime and current_book.readUpdateTime > 0 then
                    right_text = os.date("%Y-%m-%d", current_book.readUpdateTime)
                elseif current_book.finishReading == 1 then
                    right_text = _("Done")
                else
                    right_text = ""
                end
                local function rightStatus(cached)
                    if cached then
                        return right_text ~= "" and "✓  " .. right_text or "✓"
                    end
                    return right_text
                end
                table.insert(items, {
                    text = current_book.title or current_book.bookId or _("Untitled"),
                    mandatory = rightStatus(is_cached),
                    mandatory_func = function()
                        local current = self._shelf_saved_books and self._shelf_saved_books[book_id]
                        return rightStatus(current and file_exists(current.cached_file))
                    end,
                    callback = self:safeCallback(current_book.title or current_book.bookId or _("Untitled"), function()
                        self:showBookRecord(current_book)
                    end),
                })
            end
        end
        return items
    end
    menu = self:showList(_("WeRead Bookshelf"), buildItems(), _("Your WeRead shelf is empty."))
    self.shelf_menu = menu
    self._shelf_refresh = refresh
end

function WeReadPlugin:refreshShelfCacheIndicators()
    self._shelf_saved_books = self.settings:get("books", {})
    if self.shelf_menu and self._shelf_refresh then
        local ok, err = pcall(self._shelf_refresh)
        if not ok then
            logger.warn(LOG_MODULE, "refresh shelf cache indicators failed:", log_error(err))
        end
    end
end

function WeReadPlugin:showBookRecord(book)
    local books = self.settings:get("books", {})
    local book_id = book.book_id or book.bookId
    if WeRead.is_mp_book(book_id) then
        self:showMPAccount(book)
        return
    end
    if book_id then
        books[book_id] = books[book_id] or {}
        books[book_id].book_id = book_id
        books[book_id].title = book.title
        books[book_id].author = book.author
        books[book_id].cover = book.cover
        books[book_id].updated_at = os.time()
        self.settings:set("books", books)
        self.settings:flush()
    end
    local saved = books[book_id] or book
    self:showBusy(_("Loading book info..."))
    self:runOnlineTask(_("Book info"), function()
        local ok, err = pcall(function()
            local info = self.client:get_book_info(book_id)
            if info then
                saved.intro = info.intro
                saved.publisher = info.publisher
                saved.isbn = info.isbn
                saved.wordCount = info.wordCount
                saved.newRating = info.newRating
                saved.newRatingCount = info.newRatingCount
                saved.translator = info.translator
                saved.categoryName = info.categoryName or info.category
                books[book_id] = saved
                self.settings:set("books", books)
                self.settings:flush()
            end
            local progress_result = self.client:get_progress(book_id)
            if progress_result and progress_result.book then
                saved.progress = progress_result.book.progress or 0
            end
        end)
        self:closeBusy()
        if not ok then
            logger.err(LOG_MODULE, "load book info failed:", log_error(err))
            self:showInfo(T(_("%1 failed:\n%2"), _("Book info"), display_error(err)))
            return
        end
        self:showBookMenu(saved)
    end)
end

function WeReadPlugin:showBookMenu(book)
    local book_id = book.book_id or book.bookId
    local menu, buildItems

    local function refresh()
        if menu then
            menu:switchItemTable(nil, buildItems())
        end
    end

    buildItems = function()
        local items = {}

        if book.author and book.author ~= "" then
            table.insert(items, { text = _("Author"), mandatory = book.author })
        end
        if book.translator and book.translator ~= "" then
            table.insert(items, { text = _("Translator"), mandatory = book.translator })
        end
        if book.publisher and book.publisher ~= "" then
            table.insert(items, { text = _("Publisher"), mandatory = book.publisher })
        end
        if book.categoryName and book.categoryName ~= "" then
            table.insert(items, { text = _("Category"), mandatory = book.categoryName })
        end
        if book.wordCount and book.wordCount > 0 then
            local wc = book.wordCount >= 10000
                and string.format("%.1f%s", book.wordCount / 10000, _("w words"))
                or tostring(book.wordCount)
            table.insert(items, { text = _("Word count"), mandatory = wc })
        end
        if book.newRating and book.newRating > 0 then
            local score = string.format("%.1f", book.newRating / 100)
            local count = book.newRatingCount and tostring(book.newRatingCount) or "0"
            table.insert(items, { text = _("Rating"), mandatory = T(_("%1 (%2 ratings)"), score, count) })
        end
        if book.isbn and book.isbn ~= "" then
            table.insert(items, { text = "ISBN", mandatory = book.isbn })
        end
        if book.progress and book.progress > 0 then
            table.insert(items, { text = _("Reading progress"), mandatory = tostring(book.progress) .. "%" })
        end
        if book.intro and book.intro ~= "" then
            table.insert(items, {
                text = _("Introduction"),
                callback = function()
                    UIManager:show(InfoMessage:new{ text = book.intro })
                end,
            })
        end

        if #items > 0 then
            items[#items].separator = true
        end

        local saved_books = self.settings:get("books", {})
        local saved = saved_books[book_id]
        local cached_path = saved and saved.cached_file or book.cached_file
        local is_cached = file_exists(cached_path)
        book.cached_file = is_cached and cached_path or nil

        table.insert(items, {
            text = _("Chapter list"),
            post_text = book.chapters and T(_("%1 chapters"), tostring(#book.chapters)) or _("Not loaded"),
            callback = self:safeCallback(_("Chapter list"), function()
                self:showChapterList(book)
            end),
        })
        if is_cached then
            table.insert(items, {
                text = _("Clear book cache"),
                callback = self:safeCallback(_("Clear book cache"), function()
                    self:confirmClearBookCache(book_id, book.title or book_id, function()
                        book.cached_file = nil
                        book.cached_chapters = nil
                        book.cache_dir = nil
                        refresh()
                    end)
                end),
            })
        end
        table.insert(items, {
            text = _("Open cached book"),
            post_text = is_cached and _("Cached") or _("Not cached"),
            enabled_func = function() return is_cached end,
            callback = self:safeCallback(_("Open cached book"), function()
                self:openCachedBook(book)
            end),
        })
        table.insert(items, {
            text = _("下载完整书籍"),
            post_text = _("干净 EPUB"),
            callback = self:safeCallback(_("下载完整书籍"), function()
                self:confirmDownloadAllChapters(book, {
                    annotations = false,
                    suffix = "full",
                })
            end),
        })
        table.insert(items, {
            text = _("下载完整书籍（带划线和想法）"),
            post_text = _("EPUB"),
            callback = self:safeCallback(_("下载完整书籍（带划线和想法）"), function()
                self:confirmDownloadAllChapters(book, {
                    annotations = true,
                    suffix = "with-thoughts",
                })
            end),
        })
        return items
    end

    menu = self:showList(book.title or _("Book details"), buildItems(), _("No actions."))
end

function WeReadPlugin:showShelfTabs()
    local items = {
        {
            text = _("Books"),
            post_text = T(_("%1 books"), tostring(#self.shelf_regular)),
            callback = self:safeCallback(_("Books"), function()
                self.shelf_books = self.shelf_regular
                self:showShelfPage()
            end),
        },
        {
            text = _("Public Accounts"),
            post_text = T(_("%1 accounts"), tostring(#self.shelf_mp)),
            callback = self:safeCallback(_("Public Accounts"), function()
                self:showMPShelfPage()
            end),
        },
    }
    self:showList(_("WeRead Bookshelf"), items, _("Your WeRead shelf is empty."))
end

function WeReadPlugin:showMPShelfPage()
    local books = self.shelf_mp or {}
    if #books == 0 then
        self:showInfo(_("No items."))
        return
    end
    local menu, buildItems
    local function refresh()
        if menu then
            menu:switchItemTable(nil, buildItems())
        end
    end
    buildItems = function()
        local items = self:shelfToolbarItems(false, refresh)
        local sorted = sortBooks(books, self.settings:get("shelf").sort_order)
        for _i, book in ipairs(sorted) do
            local current_book = book
            table.insert(items, {
                text = current_book.title or current_book.bookId or _("Untitled"),
                post_text = current_book.author or "",
                callback = self:safeCallback(current_book.title or current_book.bookId or _("Untitled"), function()
                    self:showMPAccount(current_book)
                end),
            })
        end
        return items
    end
    menu = self:showList(_("Public Accounts"), buildItems(), _("No items."))
end

function WeReadPlugin:showMPAccount(book)
    self:rememberMPAccount(book)
    if not self.settings:is_cookie_configured() then
        self:showInfo(_("Import cookie/cURL before loading articles."))
        return
    end
    local book_id = book.book_id or book.bookId
    local cached = self:getCachedMPArticles(book_id)
    if cached and #cached > 0 then
        self:showMPArticleList(book, cached)
        return
    end
    self:fetchMPArticles(book, nil)
end

function WeReadPlugin:rememberMPAccount(book)
    local book_id = book.book_id or book.bookId
    if not book_id then
        return
    end
    local books = self.settings:get("books", {})
    local record = books[book_id] or {}
    record.book_id = book_id
    record.title = book.title or record.title
    record.author = book.author or record.author
    record.updated_at = os.time()
    -- Keep the resolved cache directory in sync both ways so the transient book
    -- object used for cached-path lookups knows where its articles actually live.
    record.cache_dir = book.cache_dir or record.cache_dir
    book.cache_dir = record.cache_dir
    books[book_id] = record
    self.settings:set("books", books)
    self.settings:flush()
end

function WeReadPlugin:fetchMPArticles(book, wr_ticket)
    self:runOnlineTask(_("Loading articles..."), function()
        self:showBusy(_("Loading articles..."))
        local book_id = book.book_id or book.bookId
        local ticket = wr_ticket or self.settings:get("wr_ticket", "")
        if ticket == "" then ticket = nil end
        local ok, result, err_code = pcall(function()
            return self.client:get_mp_articles(book_id, 0, 100, ticket)
        end)
        self:closeBusy()
        if not ok then
            logger.err(LOG_MODULE, "load MP articles failed:", log_error(result))
            self:showInfo(T(_("Load articles failed:\n%1"), display_error(result)))
            return
        end
        if not result and (err_code == -2041 or err_code == -2012) then
            logger.warn(LOG_MODULE, "load MP articles rejected, error_code:", tostring(err_code))
            local saved_ticket = self.settings:get("wr_ticket", "")
            if saved_ticket ~= "" then
                self:showInfo(T(_("Load articles failed:\n%1"), "wr_ticket expired, update wr_ticket in config.lua"))
            else
                self:showInfo(_("MP articles require wr_ticket. Set wr_ticket in config.lua, then reload config."))
            end
            return
        end
        if not result then
            logger.warn(LOG_MODULE, "load MP articles failed, error_code:", tostring(err_code))
            self:showInfo(T(_("Load articles failed:\n%1"), "errCode " .. tostring(err_code)))
            return
        end
        local articles = Content.parse_mp_articles(result)
        self:cacheMPArticles(book_id, articles)
        self:showMPArticleList(book, articles)
    end)
end

function WeReadPlugin:showWrTicketDialog(book)
    local dialog
    dialog = InputDialog:new{
        title = _("Provide x-wr-ticket"),
        input = self.settings:get("wr_ticket", ""),
        input_type = "text",
        description = _("MP article list requires a browser token.\n\n1. Open weread.qq.com in a browser\n2. Open an MP account page\n3. Open DevTools (F12) → Network tab\n4. Find the /web/mp/articles request\n5. Copy the x-wr-ticket header value\n\nPaste it here (or paste the full cURL):"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = self:safeCallback(_("Cancel"), function()
                        UIManager:close(dialog)
                    end),
                },
                {
                    text = _("Fetch"),
                    is_enter_default = true,
                    callback = self:safeCallback(_("Fetch"), function()
                        local input = dialog:getInputText()
                        UIManager:close(dialog)
                        local ticket = input
                        local extracted = input:match("%-H%s+['\"][Xx]%-[Ww][Rr]%-[Tt]icket:%s*(.-)['\"]")
                        if extracted then
                            ticket = extracted
                        elseif input:match("^%s*curl%s") then
                            ticket = nil
                        end
                        if not ticket or ticket == "" then
                            self:showInfo(_("No ticket provided."))
                            return
                        end
                        self.settings:set("wr_ticket", ticket)
                        local wrpa = input:match("%-H%s+['\"][Xx]%-[Ww][Rr][Pp][Aa]%-0:%s*(.-)['\"]")
                        if wrpa and wrpa ~= "" then
                            self.settings:set("wr_wrpa", wrpa)
                        end
                        local raw_cookie = Cookie.extract_from_curl(input)
                        local cookies = Cookie.parse_cookie_header(raw_cookie)
                        if Cookie.has_login_cookie(cookies) then
                            self.settings:set(
                                "cookies",
                                merge_cookie_tables(self.settings:get("cookies", {}), cookies)
                            )
                        end
                        self.settings:flush()
                        self:fetchMPArticles(book, ticket)
                    end),
                },
            },
        },
    }
    self:showInputDialog(dialog)
end

function WeReadPlugin:getCachedMPArticles(book_id)
    local books = self.settings:get("books", {})
    local record = books[book_id]
    if record and record.mp_articles then
        return record.mp_articles
    end
    return nil
end

function WeReadPlugin:cacheMPArticles(book_id, articles)
    local books = self.settings:get("books", {})
    books[book_id] = books[book_id] or {}
    books[book_id].mp_articles = articles
    books[book_id].mp_articles_time = os.time()
    self.settings:set("books", books)
    self.settings:flush()
end

function WeReadPlugin:showMPArticleList(book, articles)
    local items = {}
    for _i, article in ipairs(articles) do
        local cached_path = Content.mp_article_cached_path(self.settings, book, article)
        local is_cached = cached_path ~= nil
        local date_str = ""
        if article.createTime and article.createTime > 0 then
            date_str = os.date("%Y-%m-%d", article.createTime)
        end
        table.insert(items, {
            text = article.title or _("Article"),
            post_text = date_str,
            mandatory = is_cached and _("Cached") or "",
            callback = self:safeCallback(article.title or _("Article"), function()
                if is_cached then
                    self:openFile(cached_path)
                else
                    self:downloadMPArticleAndRead(book, article)
                end
            end),
        })
    end
    table.insert(items, {
        text = _("Refresh article list"),
        callback = self:safeCallback(_("Refresh article list"), function()
            self:showWrTicketDialog(book)
        end),
    })
    self:showList(book.title or _("Public Account"), items, _("No articles."))
end

function WeReadPlugin:downloadMPArticleAndRead(book, article)
    if not self.settings:is_cookie_configured() then
        self:showInfo(_("Import cookie/cURL before downloading articles."))
        return
    end
    self:runOnlineTask(_("Download article and read"), function()
        self:showBusy(T(_("Downloading article: %1"), article.title or ""))
        local progress_dialog
        local ok, path_or_err = pcall(function()
            return Content.fetch_mp_article_html(self.client, self.settings, book, article, {
                progress = function(current, total)
                    if not progress_dialog then
                        self:closeBusy()
                        progress_dialog = ProgressbarDialog:new{
                            title = T(_("Downloading images: %1"), article.title or ""),
                            progress_max = total,
                        }
                        progress_dialog:show()
                        self:refreshUI()
                    end
                    progress_dialog:reportProgress(current)
                end,
            })
        end)
        if progress_dialog then
            progress_dialog:close()
        else
            self:closeBusy()
        end
        if not ok then
            logger.err(LOG_MODULE, "download MP article failed:", log_error(path_or_err))
            self:showInfo(T(_("下载失败：\n%1"), display_error(path_or_err)))
            return
        end
        logger.info(
            LOG_MODULE,
            "MP article downloaded:",
            "images=", self.settings:get("cache").download_mp_images and "embedded" or "removed"
        )
        -- Persist the resolved cache directory (set by save_mp_article_html) so the
        -- article files can still be located after the download directory changes.
        local book_id = book.book_id or book.bookId
        if book_id and book.cache_dir then
            local books = self.settings:get("books", {})
            local record = books[book_id] or {}
            record.cache_dir = book.cache_dir
            books[book_id] = record
            self.settings:set("books", books)
            self.settings:flush()
        end
        self:openFile(path_or_err)
    end)
end

function WeReadPlugin:loadChapters(book, callback)
    if book.chapters and #book.chapters > 0 then
        callback(book.chapters)
        return
    end
    if not self.settings:is_cookie_configured() then
        self:showInfo(_("Import cookie/cURL before loading chapters."))
        return
    end
    self:runOnlineTask(_("Loading chapter list..."), function()
        self:showBusy(_("Loading chapter list..."))
        local ok, chapters_or_err = pcall(function()
            Content.ensure_reader_state(self.client, book)
            return Content.fetch_catalog(self.client, book)
        end)
        self:closeBusy()
        if not ok then
            logger.err(LOG_MODULE, "load chapters failed:", log_error(chapters_or_err))
            self:showInfo(T(_("Load chapters failed:\n%1"), display_error(chapters_or_err)))
            return
        end
        local books = self.settings:get("books", {})
        local book_id = book.book_id or book.bookId
        if book_id then
            books[book_id] = book
            self.settings:set("books", books)
            self.settings:flush()
        end
        callback(chapters_or_err)
    end)
end

function WeReadPlugin:showChapterList(book)
    self:loadChapters(book, function(chapters)
        local items = {}
        for _i, chapter in ipairs(chapters) do
            local cached = book.cached_chapters and book.cached_chapters[tostring(chapter.chapterUid)]
            table.insert(items, {
                text = chapter.title or T(_("Chapter %1"), tostring(chapter.chapterUid)),
                post_text = cached and _("Cached") or T(_("%1 words"), tostring(chapter.wordCount or 0)),
                callback = self:safeCallback(chapter.title or _("Chapter"), function()
                    if cached then
                        self:openFile(cached)
                    else
                        self:downloadChapterAndRead(book, chapter)
                    end
                end),
            })
        end
        self:showList(book.title or _("Chapter list"), items, _("No chapters."))
    end)
end

function WeReadPlugin:openFile(path)
    if not path or path == "" then
        self:showInfo(_("No cached file."))
        return
    end
    if self.ui.document then
        self.ui:switchDocument(path)
    else
        self.ui:openFile(path)
    end
end

function WeReadPlugin:openCachedBook(book)
    self:openFile(book.cached_file)
end

function WeReadPlugin:downloadFirstChapterAndRead(book)
    self:loadChapters(book, function(chapters)
        local chapter = Content.first_readable_chapter(chapters)
        if not chapter then
            self:showInfo(_("No readable chapter found"))
            return
        end
        self:downloadChaptersAsBook(book, { chapter }, "first-chapter", {
            single_chapter = true,
            annotations = false,
        })
    end)
end

function WeReadPlugin:downloadChapterAndRead(book, chapter)
    self:downloadChaptersAsBook(book, { chapter }, "chapter", {
        single_chapter = true,
        annotations = false,
    })
end

function WeReadPlugin:downloadFirstNChapters(book, count)
    if not self.settings:is_cookie_configured() then
        self:showInfo(_("下载书籍内容前，请先导入 cookie/cURL。"))
        return
    end
    self:loadChapters(book, function(chapters)
        local limit = math.min(count or 5, #chapters)
        local selected = {}
        for chapter_index = 1, limit do
            table.insert(selected, chapters[chapter_index])
        end
        self:downloadChaptersAsBook(book, selected, "first-" .. tostring(limit), {
            annotations = false,
        })
    end)
end

function WeReadPlugin:confirmDownloadAllChapters(book, options)
    options = options or {}
    self:loadChapters(book, function(chapters)
        local confirm
        local message = T(_("将全部 %1 个章节下载为一个 EPUB？"), tostring(#chapters))
        if options.annotations then
            message = message .. "\n\n" .. _("本次下载会包含划线和想法。")
            message = message .. "\n" .. _("This download includes underlines and thoughts and may take significantly longer.")
        else
            message = message .. "\n\n" .. _("本次下载将生成干净 EPUB，不包含划线和想法。")
        end
        local label = options.annotations and _("下载完整书籍（带划线和想法）") or _("下载完整书籍")
        confirm = ConfirmBox:new{
            text = message,
            ok_text = _("下载"),
            ok_callback = self:safeCallback(label, function()
                UIManager:close(confirm)
                local suffix = options.suffix or (options.annotations and "with-thoughts" or "full")
                self:downloadChaptersAsBook(book, chapters, suffix, options)
            end),
            cancel_text = _("关闭"),
        }
        UIManager:show(confirm)
    end)
end

function WeReadPlugin:downloadChaptersAsBook(book, chapters, suffix, options)
    options = options or {}
    if not self.settings:is_cookie_configured() then
        self:showInfo(_("下载书籍内容前，请先导入 cookie/cURL。"))
        return
    end
    local task_label = options.single_chapter and _("Download chapter and read") or _("下载完整书籍")
    self:runOnlineTask(task_label, function()
        local ok_init, err_init = pcall(function()
            Content.ensure_reader_state(self.client, book)
        end)
        if not ok_init then
            logger.err(LOG_MODULE, "initialize book download failed:", log_error(err_init))
            self:showInfo(T(_("下载失败：\n%1"), display_error(err_init)))
            return
        end

        local total = #chapters
        local dl = {
            book = book,
            chapters = chapters,
            suffix = suffix or "book",
            index = 1,
            cancelled = false,
            selected = {},
            bodies = {},
            assets = {},
            state = {
                include_annotations = options.annotations == true,
                chapters = chapters,
            },
            annotations = options.annotations == true,
            total = total,
            failed = {},
            annotation_failed_batches = 0,
            single_chapter = options.single_chapter == true,
            started_at = time.now(),
        }

        local progress_dialog = DownloadDialog:new{
            title = T(_("正在下载：%1"), book.title or ""),
            progress_max = total,
            buttons = {{
                {
                    text = _("取消下载"),
                    callback = function()
                        dl.cancelled = true
                        if dl.progress_dialog then
                            dl.progress_dialog:close()
                            dl.progress_dialog = nil
                        end
                    end,
                },
            }},
        }
        dl.progress_dialog = progress_dialog
        progress_dialog:show()
        self:refreshUI()

        UIManager:scheduleIn(0.1, function()
            self:_downloadStep(dl)
        end)
    end)
end

function WeReadPlugin:_setDownloadStage(dl, title, progress)
    if not dl.progress_dialog then return end
    dl.progress_dialog:setTitle(title)
    if progress then
        dl.progress_dialog:reportProgress(progress)
    end
end

function WeReadPlugin:_downloadPerf(dl, stage, started, ...)
    local elapsed = tonumber(time.now() - started) / 1000
    logger.info(LOG_MODULE, "download_perf", "stage=", stage,
        "ms=", string.format("%.1f", elapsed),
        "chapter=", tostring(dl.index) .. "/" .. tostring(dl.total), ...)
end

function WeReadPlugin:_failCurrentDownloadChapter(dl, err)
    local chapter = dl.chapters[dl.index]
    local uid = tostring(chapter and chapter.chapterUid or dl.index)
    table.insert(dl.failed, uid)
    logger.warn(LOG_MODULE, "chapter download failed:",
        "index=", tostring(dl.index) .. "/" .. tostring(dl.total),
        "chapter_uid=", uid, "error=", log_error(err))
    dl.current = nil
    dl.annotation = nil
    dl.index = dl.index + 1
    if dl.progress_dialog then
        dl.progress_dialog:reportProgress(dl.index - 1)
    end
    UIManager:scheduleIn(0.1, function() self:_downloadStep(dl) end)
end

function WeReadPlugin:_finishCurrentDownloadChapter(dl)
    if dl.cancelled or not dl.current then return end
    local chapter = dl.current.chapter
    local cache = self.settings:get("cache")
    local stage_text
    if cache.download_book_images then
        stage_text = T(_("Downloading images · chapter %1/%2"), tostring(dl.index), tostring(dl.total))
    else
        stage_text = T(_("Processing chapter %1/%2"), tostring(dl.index), tostring(dl.total))
    end
    self:_setDownloadStage(dl, stage_text, dl.index - 0.1)

    local started = time.now()
    local ok, xhtml, chapter_assets = pcall(function()
        return Content.finalize_single_chapter_content(
            self.client, self.settings, dl.book, chapter, dl.current.xhtml, dl.state
        )
    end)
    self:_downloadPerf(dl, "images_and_finalize", started, "ok=", tostring(ok))
    if not ok then
        self:_failCurrentDownloadChapter(dl, xhtml)
        return
    end

    local uid = tostring(chapter.chapterUid or dl.index)
    dl.bodies[uid] = xhtml
    table.insert(dl.selected, chapter)
    for _i, asset in ipairs(chapter_assets or {}) do
        table.insert(dl.assets, asset)
    end
    dl.current = nil
    dl.annotation = nil
    dl.index = dl.index + 1
    if dl.progress_dialog then
        dl.progress_dialog:reportProgress(dl.index - 1)
    end
    UIManager:scheduleIn(0.1, function() self:_downloadStep(dl) end)
end

function WeReadPlugin:_applyCurrentAnnotations(dl)
    if dl.cancelled or not dl.current or not dl.annotation then return end
    local annotation = dl.annotation
    local chapter = dl.current.chapter
    local book_id = dl.book.book_id or dl.book.bookId
    self:_setDownloadStage(
        dl,
        T(_("Processing underlines and thoughts · chapter %1/%2"), tostring(dl.index), tostring(dl.total)),
        dl.index - 0.15
    )

    local started = time.now()
    local ok, processed, annotation_css = pcall(function()
        return Thoughts.apply_data(
            self.settings, book_id, chapter.chapterUid,
            dl.current.xhtml, annotation.underlines, annotation.reviews
        )
    end)
    self:_downloadPerf(dl, "apply_annotations", started, "ok=", tostring(ok),
        "reviews=", tostring(#annotation.reviews))
    if not ok then
        self:_failCurrentDownloadChapter(dl, processed)
        return
    end

    dl.current.xhtml = processed
    dl.state.annotation_css_seen = dl.state.annotation_css_seen or {}
    if annotation_css ~= "" and not dl.state.annotation_css_seen[annotation_css] then
        dl.state.css = Thoughts.merge_css(dl.state.css, annotation_css)
        dl.state.annotation_css_seen[annotation_css] = true
    end
    self:_finishCurrentDownloadChapter(dl)
end

function WeReadPlugin:_downloadAnnotationBatch(dl)
    if dl.cancelled then
        self:showTransientInfo(_("下载已取消"), 2)
        return
    end
    local annotation = dl.annotation
    if not annotation then
        self:_finishCurrentDownloadChapter(dl)
        return
    end
    if annotation.batch_index > #annotation.batches then
        self:_applyCurrentAnnotations(dl)
        return
    end

    local batch_index = annotation.batch_index
    local batch_total = #annotation.batches
    local fractional = dl.index - 0.85 + 0.7 * batch_index / math.max(1, batch_total)
    self:_setDownloadStage(
        dl,
        T(_("Downloading thoughts %1/%2 · chapter %3/%4"),
            tostring(batch_index), tostring(batch_total), tostring(dl.index), tostring(dl.total)),
        fractional
    )

    local started = time.now()
    local ok, result, err = self.client:get_chapter_reviews_batch(
        dl.book.book_id or dl.book.bookId,
        dl.current.chapter.chapterUid,
        annotation.batches[batch_index]
    )
    self:_downloadPerf(dl, "thought_batch", started,
        "batch=", tostring(batch_index) .. "/" .. tostring(batch_total),
        "ok=", tostring(ok), "retry=", tostring(annotation.retry))

    if not ok then
        if annotation.retry < 2 then
            annotation.retry = annotation.retry + 1
            self:_setDownloadStage(
                dl,
                T(_("Retrying thoughts %1/%2 · attempt %3"),
                    tostring(batch_index), tostring(batch_total), tostring(annotation.retry)),
                fractional
            )
            UIManager:scheduleIn(0.6 * annotation.retry, function()
                self:_downloadAnnotationBatch(dl)
            end)
            return
        end
        dl.annotation_failed_batches = dl.annotation_failed_batches + 1
        logger.warn(LOG_MODULE, "thought batch skipped:",
            "batch=", tostring(batch_index) .. "/" .. tostring(batch_total),
            "error=", log_error(err or "unknown"))
    elseif result and type(result.reviews) == "table" then
        for _i, review in ipairs(result.reviews) do
            annotation.reviews[#annotation.reviews + 1] = review
        end
    end

    annotation.batch_index = batch_index + 1
    annotation.retry = 0
    UIManager:scheduleIn(0.3, function() self:_downloadAnnotationBatch(dl) end)
end

function WeReadPlugin:_startCurrentAnnotations(dl)
    local chapter = dl.current.chapter
    local book_id = dl.book.book_id or dl.book.bookId
    self:_setDownloadStage(
        dl,
        T(_("Downloading underlines · chapter %1/%2"), tostring(dl.index), tostring(dl.total)),
        dl.index - 0.85
    )

    local started = time.now()
    local ok, underlines, ranges, err = Thoughts.fetch_underlines(
        self.client, self.settings, book_id, chapter.chapterUid, dl.annotations
    )
    self:_downloadPerf(dl, "underlines", started, "ok=", tostring(ok),
        "ranges=", tostring(#(ranges or {})))
    if not ok or type(underlines) ~= "table" then
        logger.warn(LOG_MODULE, "skip chapter annotations:", log_error(err or "no data"))
        self:_finishCurrentDownloadChapter(dl)
        return
    end

    dl.annotation = {
        underlines = underlines,
        reviews = {},
        batches = self.client:build_chapter_review_batches(ranges),
        batch_index = 1,
        retry = 0,
    }
    if #dl.annotation.batches == 0 then
        self:_applyCurrentAnnotations(dl)
    else
        UIManager:scheduleIn(0.1, function() self:_downloadAnnotationBatch(dl) end)
    end
end

function WeReadPlugin:_downloadStep(dl)
    if dl.cancelled then
        self:showTransientInfo(_("下载已取消"), 2)
        return
    end

    if dl.index > dl.total then
        if #dl.selected == 0 then
            if dl.progress_dialog then
                dl.progress_dialog:close()
                dl.progress_dialog = nil
            end
            logger.err(LOG_MODULE, "book download failed: no chapters downloaded")
            self:showInfo(_("No chapters were downloaded."))
            return
        end

        self:_setDownloadStage(dl, _("Building EPUB..."), dl.total)
        local save_started = time.now()
        local ok, path = pcall(function()
            if dl.single_chapter then
                local chapter = dl.selected[1]
                local uid = tostring(chapter.chapterUid or 1)
                return Content.save_chapter_epub(
                    self.settings, dl.book, chapter, dl.bodies[uid], dl.assets, dl.state.css
                )
            end
            local cover_data
            local cover_url = WeRead.normalize_cover_url(dl.book.cover)
            if cover_url and cover_url ~= "" then
                pcall(function() cover_data = self.client:get_binary(cover_url) end)
            end
            return Content.save_book_epub(
                self.settings, dl.book, dl.selected, dl.bodies,
                dl.suffix, dl.assets, dl.state.css, cover_data
            )
        end)
        self:_downloadPerf(dl, "save_epub", save_started, "ok=", tostring(ok),
            "single=", tostring(dl.single_chapter))

        if dl.progress_dialog then
            dl.progress_dialog:close()
            dl.progress_dialog = nil
        end

        local books = self.settings:get("books", {})
        local book_id = dl.book.book_id or dl.book.bookId
        if book_id then
            dl.book.cached_chapters = dl.book.cached_chapters or {}
            for chapter_index, chapter in ipairs(dl.selected) do
                dl.book.cached_chapters[tostring(chapter.chapterUid or chapter_index)] = ok and path or nil
            end
            if ok then
                dl.book.cached_file = path
                dl.book.annotations_cached = dl.annotations == true
            end
            dl.book.reader_url = dl.book.reader_url or WeRead.reader_url(book_id)
            books[book_id] = dl.book
            self.settings:set("books", books)
            self.settings:flush()
        end
        self:refreshShelfCacheIndicators()

        if not ok then
            logger.err(LOG_MODULE, "save downloaded book failed:", log_error(path))
            self:showInfo(T(_("下载失败：\n%1"), display_error(path)))
            return
        end

        if #dl.failed > 0 then
            logger.warn(LOG_MODULE, "book download completed with skipped chapters:",
                "success=", tostring(#dl.selected), "failed=", tostring(#dl.failed))
        else
            logger.info(LOG_MODULE, "book download completed:", "chapters=", tostring(#dl.selected))
        end

        self:_downloadPerf(dl, "download_total", dl.started_at,
            "success_chapters=", tostring(#dl.selected),
            "failed_chapters=", tostring(#dl.failed),
            "failed_thought_batches=", tostring(dl.annotation_failed_batches))

        if dl.single_chapter then
            if dl.annotation_failed_batches > 0 then
                self:showTransientInfo(T(
                    _("%1 thought batch(es) failed after retries; the EPUB contains the remaining available thoughts."),
                    tostring(dl.annotation_failed_batches)
                ), 4)
            end
            self:openFile(path)
            return
        end

        local completion_text
        if #dl.failed > 0 then
            completion_text = T(
                _("Downloaded %1 chapters; %2 failed.\n\nBook saved:\n%3\n\nRead now?"),
                tostring(#dl.selected), tostring(#dl.failed), path
            )
        else
            completion_text = T(
                _("Downloaded %1 chapters.\n\nBook saved:\n%2\n\nRead now?"),
                tostring(#dl.selected), path
            )
        end
        if dl.annotation_failed_batches > 0 then
            completion_text = completion_text .. "\n\n" .. T(
                _("%1 thought batch(es) failed after retries; the EPUB contains the remaining available thoughts."),
                tostring(dl.annotation_failed_batches)
            )
        end

        UIManager:show(ConfirmBox:new{
            text = completion_text,
            ok_text = _("现在阅读"),
            ok_callback = self:safeCallback(_("现在阅读"), function()
                self:openFile(path)
            end),
            cancel_text = _("关闭"),
        })
        return
    end

    local chapter = dl.chapters[dl.index]
    self:_setDownloadStage(
        dl,
        T(_("Downloading chapter %1/%2: %3"), tostring(dl.index), tostring(dl.total),
            chapter.title or tostring(chapter.chapterUid)),
        dl.index - 1
    )

    local started = time.now()
    local ok, xhtml = pcall(function()
        return Content.fetch_single_chapter_source(
            self.client, self.settings, dl.book, chapter, dl.state
        )
    end)
    self:_downloadPerf(dl, "chapter_source", started, "ok=", tostring(ok))
    if not ok then
        self:_failCurrentDownloadChapter(dl, xhtml)
        return
    end

    dl.current = { chapter = chapter, xhtml = xhtml }
    if dl.annotations then
        self:_startCurrentAnnotations(dl)
    else
        self:_finishCurrentDownloadChapter(dl)
    end
end

function WeReadPlugin:pullProgressWithUI(book_id)
    self:runNetworkAction(_("Pull progress"), function()
        local result = self.client:get_progress(book_id)
        local progress = result and result.book and result.book.progress or 0
        return T(_("Remote progress: %1%"), tostring(progress))
    end)
end

function WeReadPlugin:showSearch()
    if not self.settings:is_api_configured() then
        self:showInfo(_("Set the official API key before using WeRead search."))
        return
    end
    local dialog
    dialog = InputDialog:new{
        title = _("Search WeRead"),
        input = "",
        input_type = "text",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = self:safeCallback(_("Cancel"), function()
                        UIManager:close(dialog)
                    end),
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = self:safeCallback(_("Search"), function()
                        local keyword = dialog:getInputText()
                        UIManager:close(dialog)
                        self:searchWithUI(keyword)
                    end),
                },
            },
        },
    }
    self:showInputDialog(dialog)
end

function WeReadPlugin:searchWithUI(keyword)
    if not keyword or keyword == "" then
        return
    end
    self:runOnlineTask(_("Search"), function()
        local ok, result = pcall(function()
            return self.client:gateway("/store/search", {
                keyword = keyword,
                count = 10,
            })
        end)
        if not ok then
            logger.err(LOG_MODULE, "search failed:", log_error(result))
            self:showInfo(T(_("Search failed:\n%1"), display_error(result)))
            return
        end
        local items = {}
        for group_index, group in ipairs(result.results or {}) do
            for book_index, entry in ipairs(group.books or {}) do
                local book = entry.bookInfo or entry
                table.insert(items, {
                    text = book.title or book.bookId or _("Untitled"),
                    post_text = book.author or "",
                    mandatory = book.category or "",
                    callback = self:safeCallback(book.title or book.bookId or _("Untitled"), function()
                        self:showBookRecord(book)
                    end),
                })
            end
        end
        self:showList(T(_("Search: %1"), keyword), items, _("No search results."))
    end)
end

function WeReadPlugin:showPasteReaderURL()
    local dialog
    dialog = InputDialog:new{
        title = _("Paste WeRead reader URL"),
        input = "https://weread.qq.com/web/reader/",
        input_type = "text",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = self:safeCallback(_("Cancel"), function()
                        UIManager:close(dialog)
                    end),
                },
                {
                    text = _("Parse"),
                    is_enter_default = true,
                    callback = self:safeCallback(_("Parse"), function()
                        local url = dialog:getInputText()
                        UIManager:close(dialog)
                        self:parseReaderURLWithUI(url)
                    end),
                },
            },
        },
    }
    self:showInputDialog(dialog)
end

function WeReadPlugin:parseReaderURLWithUI(url)
    if not self.settings:is_cookie_configured() then
        self:showInfo(_("Import cookie/cURL before parsing reader URLs."))
        return
    end
    self:runNetworkAction(_("Parse reader URL"), function()
        local html = self.client:get_text(url, { referer = url })
        local book_id = html:match([["bookId"%s*:%s*"([^"]+)"]]) or html:match([["bookId"%s*:%s*(%d+)]])
        local title = html:match([["title"%s*:%s*"([^"]+)"]]) or _("Unknown title")
        local psvts = html:match([["psvts"%s*:%s*"([^"]+)"]])
        local pclts = html:match([["pclts"%s*:%s*"([^"]+)"]])
        local token = html:match([["token"%s*:%s*"([^"]+)"]])
        if not book_id then
            return _("Reader HTML loaded, but bookId was not found.")
        end
        local books = self.settings:get("books", {})
        books[book_id] = {
            book_id = book_id,
            title = title,
            reader_url = url,
            psvts = psvts,
            pclts = pclts,
            token = token,
            updated_at = os.time(),
        }
        self.settings:set("books", books)
        self.settings:flush()
        return T(_("Reader URL parsed.\nBook: %1\nbookId: %2"), title, book_id)
    end)
end


function WeReadPlugin:showCurrentBookDetails()
    self:showInfo(_("Current-book WeRead metadata is not linked yet. Open a parsed WeRead book from the plugin cache first."))
end

function WeReadPlugin:onShowWeRead()
    self:showAccountStatus()
end

function WeReadPlugin:onWeReadSyncProgress()
    local books = self.settings:get("books", {})
    local book_id, book
    for id, item in pairs(books) do
        book_id, book = id, item
        break
    end
    if not book_id then
        self:showInfo(_("Parse a WeRead reader URL before testing progress sync."))
        return
    end
    local payload = WeRead.make_read_payload{
        book_id = book_id,
        chapter_uid = book.chapter_uid or 0,
        chapter_idx = book.chapter_idx or 0,
        chapter_offset = book.chapter_offset or 0,
        progress = book.progress or 0,
        summary = book.summary or "",
        app_id = book.app_id or self.settings:get("curl_payload", {}).appId,
        psvts = book.psvts or self.settings:get("curl_payload", {}).ps,
        pclts = book.pclts or self.settings:get("curl_payload", {}).pc,
        token = book.token,
    }
    UIManager:show(ConfirmBox:new{
        text = T(_("Upload local progress to WeRead?\n\nBook: %1\nProgress: %2%%\nChapter offset: %3"), book.title or book_id, tostring(payload.pr), tostring(payload.co)),
        ok_text = _("Upload"),
        ok_callback = self:safeCallback(_("Upload"), function()
            self:runNetworkAction(_("Sync progress"), function()
                local result = self.client:report_read(payload, book.reader_url)
                if result and result.succ then
                    return _("WeRead progress synced.")
                end
                return _("Progress request sent, but response did not include succ=1.")
            end)
        end),
    })
end


-- Runtime CSS that hides underlines and thought stars baked into cached EPUBs.
-- Applied as an appended stylesheet (not persisted to the book sidecar) so it
-- acts as a global display preference without mutating downloaded files.
-- NOTE: only tweak visual/metric properties (border, padding, font-size). Never
-- use display/white-space here — changing those marks the built DOM stale and
-- makes ReaderRolling repeatedly prompt for a full document reload.
local ANNOTATION_HIDE_CSS =
    ".wr-underline{border-bottom:0 !important;padding-bottom:0 !important;} "
    .. ".wr-star{font-size:0 !important;margin-left:0 !important;} "
    .. ".wr-thought-link{pointer-events:none !important;text-decoration:none !important;color:inherit !important;}"

-- Apply the initial hidden state before KOReader renders the document.
-- Doing this in onReaderReady may trigger repeated seamless reloads on some
-- KOReader builds, so the upstream 0.2.1 timing is preserved here.
function WeReadPlugin:onReadSettings()
    if not self.ui or not self.ui.document or not self:detectWeReadBook() then
        return
    end
    if self.settings:get("cache").show_annotations ~= false then
        return
    end
    local typeset = self.ui.typeset
    if not typeset or not typeset.css then
        logger.warn(LOG_MODULE, "onReadSettings: typeset stylesheet unavailable")
        return
    end
    local tweaks = ""
    local styletweak = self.ui.styletweak
    if styletweak and type(styletweak.getCssText) == "function" then
        tweaks = styletweak:getCssText() or ""
    end
    local ok, err = pcall(function()
        self.ui.document:setStyleSheet(typeset.css, tweaks .. "\n" .. ANNOTATION_HIDE_CSS)
    end)
    if not ok then
        logger.warn(LOG_MODULE, "initial annotation visibility failed:", err)
    end
end

-- Reapply the current annotation visibility preference to the open WeRead book.
-- Show=true reapplies the base stylesheet + user tweaks (revealing baked-in
-- underlines); show=false appends ANNOTATION_HIDE_CSS on top. Triggers a reflow.
function WeReadPlugin:applyAnnotationVisibility()
    if not self.ui or not self.ui.document then
        return
    end
    if not self:detectWeReadBook() then
        return
    end
    local typeset = self.ui.typeset
    if not typeset or not typeset.css then
        logger.warn(LOG_MODULE, "applyAnnotationVisibility: typeset stylesheet unavailable")
        return
    end
    local show = self.settings:get("cache").show_annotations ~= false
    local tweaks = ""
    local styletweak = self.ui.styletweak
    if styletweak and type(styletweak.getCssText) == "function" then
        tweaks = styletweak:getCssText() or ""
    end
    if not show then
        tweaks = tweaks .. "\n" .. ANNOTATION_HIDE_CSS
    end
    local ok, err = pcall(function()
        self.ui.document:setStyleSheet(typeset.css, tweaks)
        self.ui:handleEvent(Event:new("UpdatePos"))
    end)
    if not ok then
        logger.warn(LOG_MODULE, "applyAnnotationVisibility failed:", err)
    end
end

function WeReadPlugin:_teardownThoughtInterception()
    if self._annotation_tap_suppression_setup and self.ui then
        pcall(function()
            self.ui:unRegisterTouchZones({
                { id = "weread_thought_popup", overrides = { "tap_link" } },
            })
        end)
        self._annotation_tap_suppression_setup = nil
    end
    self._thought_json_cache = nil
    local ok_popup, ThoughtPopup = pcall(require, "lib.thought_popup")
    if ok_popup and ThoughtPopup and type(ThoughtPopup.closeVisible) == "function" then
        pcall(function() ThoughtPopup.closeVisible() end)
    end
end

function WeReadPlugin:_setupAnnotationTapSuppression()
    local ok_device, Device = pcall(require, "device")
    if not ok_device or not Device:isTouchDevice() then
        return
    end
    if not self.ui or self._annotation_tap_suppression_setup then
        return
    end
    self.ui:registerTouchZones({
        {
            id = "weread_thought_popup",
            ges = "tap",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            overrides = { "tap_link" },
            handler = function(ges)
                return self:_onThoughtLinkTap(ges)
            end,
        },
    })
    self._annotation_tap_suppression_setup = true
end

function WeReadPlugin:_linkHref(link)
    -- KOReader's link objects differ between engines and even between tap
    -- locations inside the same anchor. On some pages, tapping the star exposes
    -- href, while tapping the underlined text exposes the same URI under another
    -- field. Search common fields first, then do a shallow recursive scan.
    local seen = {}

    local function extract(value, depth)
        if depth > 4 or value == nil then
            return nil
        end
        if type(value) == "string" then
            local href = value:match("(wrthought://[^%s%\"%'<>%)]+)")
                or value:match("(#wrthought%-[%w%._%-]+)")
                or value:match("(wrthought%-[%w%._%-]+)")
            if href then
                return href
            end
            return nil
        end
        if type(value) ~= "table" or seen[value] then
            return nil
        end
        seen[value] = true

        for _, key in ipairs({ "href", "url", "target", "link", "uri", "dest", "destination", "src" }) do
            local found = extract(value[key], depth + 1)
            if found then
                return found
            end
        end

        for _, child in pairs(value) do
            local found = extract(child, depth + 1)
            if found then
                return found
            end
        end
        return nil
    end

    return extract(link, 0)
end

function WeReadPlugin:_isWeReadThoughtLink(link)
    local href = self:_linkHref(link)
    return type(href) == "string" and (href:find("^wrthought://") ~= nil or href:find("^#?wrthought%-") ~= nil)
end

local function uri_decode(text)
    text = tostring(text or "")
    text = text:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16) or 0)
    end)
    return text
end

local function decode_json_text(data)
    if type(data) ~= "string" or data == "" then
        return nil
    end

    local ok_json, json = pcall(require, "json")
    if ok_json and type(json) == "table" then
        if type(json.decode) == "function" then
            local ok, parsed = pcall(json.decode, data)
            if ok and type(parsed) == "table" then
                return parsed
            end
        end
        local ok, parsed = pcall(function()
            return json:decode(data)
        end)
        if ok and type(parsed) == "table" then
            return parsed
        end
    end

    local ok_rapid, rapidjson = pcall(require, "rapidjson")
    if ok_rapid and rapidjson then
        if type(rapidjson) == "table" and type(rapidjson.decode) == "function" then
            local ok, parsed = pcall(rapidjson.decode, data)
            if ok and type(parsed) == "table" then
                return parsed
            end
        end
        local ok, parsed = pcall(function()
            return rapidjson:decode(data)
        end)
        if ok and type(parsed) == "table" then
            return parsed
        end
    end

    return nil
end

function WeReadPlugin:_parseThoughtHref(href)
    if type(href) ~= "string" then
        return nil
    end

    local rest = href:match("^wrthought://(.+)$")
    if rest then
        local book_id, chapter_uid, range = rest:match("^([^/]+)/([^/]+)/(.+)$")
        if book_id and chapter_uid and range then
            return {
                book_id = uri_decode(book_id),
                chapter_uid = uri_decode(chapter_uid),
                range = uri_decode(range),
            }
        end
    end

    -- 新方案：内部锚点 #wrthought-BOOKID-CHAPTERUID-START-END。
    -- 这不是外部链接；若插件拦截失败，KOReader 最多跳回当前划线位置。
    local anchor = href:match("#?(wrthought%-[%w%._%-]+)")
    if anchor then
        local book_id, chapter_uid, start_pos, end_pos = anchor:match("^wrthought%-([^%-]+)%-([^%-]+)%-(%d+)%-([%d]+)$")
        if book_id and chapter_uid and start_pos and end_pos then
            return {
                book_id = book_id,
                chapter_uid = chapter_uid,
                range = tostring(start_pos) .. "-" .. tostring(end_pos),
            }
        end
    end

    return nil
end

function WeReadPlugin:_thoughtCachePath(book_id, chapter_uid)
    if not book_id or not chapter_uid then
        return nil
    end
    local books = self.settings:get("books", {})
    local book = books[tostring(book_id)] or books[book_id]
    local dir = Content.book_resolved_dir(self.settings, tostring(book_id), book)
    return dir .. "/thoughts/" .. tostring(chapter_uid) .. ".json"
end

function WeReadPlugin:_loadThoughtReviews(book_id, chapter_uid)
    self._thought_json_cache = self._thought_json_cache or {}
    local key = tostring(book_id or "") .. ":" .. tostring(chapter_uid or "")
    if self._thought_json_cache[key] ~= nil then
        local cached = self._thought_json_cache[key]
        return cached ~= false and cached or nil
    end

    local path = self:_thoughtCachePath(book_id, chapter_uid)
    if not path then
        self._thought_json_cache[key] = false
        return nil
    end
    local file = io.open(path, "r")
    if not file then
        logger.warn(LOG_MODULE, "thought cache not found:", path)
        self._thought_json_cache[key] = false
        return nil
    end
    local data = file:read("*a") or ""
    file:close()
    local parsed = decode_json_text(data)
    if type(parsed) ~= "table" then
        logger.warn(LOG_MODULE, "thought cache decode failed:", path)
        self._thought_json_cache[key] = false
        return nil
    end
    self._thought_json_cache[key] = parsed
    return parsed
end

local function trim_text(text)
    return tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function limit_text(text, max_len)
    text = tostring(text or "")
    max_len = max_len or 1800
    if #text <= max_len then
        return text
    end
    return text:sub(1, max_len) .. "..."
end

local function html_escape(value)
    value = tostring(value or "")
    value = value:gsub("&", "&amp;")
    value = value:gsub("<", "&lt;")
    value = value:gsub(">", "&gt;")
    value = value:gsub('"', "&quot;")
    return value
end

local function strip_tags(html)
    return tostring(html or ""):gsub("<[^>]+>", ""):gsub("&lt;", "<"):gsub("&gt;", ">")
        :gsub("&quot;", '"'):gsub("&amp;", "&")
end

function WeReadPlugin:_formatThoughtPopupHtml(range_review)
    if type(range_review) ~= "table" or type(range_review.pageReviews) ~= "table" then
        return nil
    end

    local parts = { '<div class="weread-thought-popup">' }
    local first = range_review.pageReviews[1]
    local abstract = first and first.review and (first.review.abstract or first.review.contextAbstract)
    abstract = trim_text(abstract)
    if abstract ~= "" then
        parts[#parts + 1] = '<blockquote>「' .. html_escape(limit_text(abstract, 500)) .. '」</blockquote>'
    end

    for i, pr in ipairs(range_review.pageReviews) do
        local review = pr.review or {}
        local author = review.author or {}
        local name = trim_text(author.nick or author.name or _("Anonymous"))
        local likes = tonumber(pr.likesCount or review.likesCount or 0) or 0
        local content = trim_text(review.content or "")
        local header = tostring(i) .. ". " .. name
        if likes > 0 then
            header = header .. " · ♥ " .. tostring(likes)
        end
        parts[#parts + 1] = '<p><strong>' .. html_escape(header) .. '</strong><br/>'
        if content ~= "" then
            parts[#parts + 1] = html_escape(limit_text(content, 3000))
        else
            parts[#parts + 1] = html_escape(_("Empty thought"))
        end
        parts[#parts + 1] = '</p>'
    end

    parts[#parts + 1] = '</div>'
    return table.concat(parts, "\n")
end

function WeReadPlugin:_formatThoughtPopupText(range_review)
    local html = self:_formatThoughtPopupHtml(range_review)
    if not html then
        return nil
    end
    return strip_tags(html)
end

function WeReadPlugin:_thoughtPopupOptions(html)
    local ok_device, Device = pcall(require, "device")
    local Screen = ok_device and Device.screen
    local scale = function(v)
        if Screen and type(Screen.scaleBySize) == "function" then
            return Screen:scaleBySize(v)
        end
        return v
    end

    -- Render WeRead comments relative to the reader's *visible* body font size.
    -- Some KOReader documents do not expose it as document.configurable.font_size;
    -- try several known places and normalize common stored formats. If all reads
    -- fail, use a moderate fallback instead of the old too-small one.
    local function normalize_font_size(value)
        local n = tonumber(value)
        if not n or n <= 0 then
            return nil
        end
        -- Some settings may be stored as 2200 or 220 for a visible size around 22.
        if n > 1000 then
            n = n / 100
        elseif n > 120 then
            n = n / 10
        end
        if n >= 8 and n <= 90 then
            return math.floor(n + 0.5)
        end
        return nil
    end

    local function read_setting(obj, key)
        if not obj or type(obj.readSetting) ~= "function" then
            return nil
        end
        local ok, value = pcall(function()
            return obj:readSetting(key)
        end)
        if ok then
            return value
        end
        return nil
    end

    local function find_reader_font_size(ui)
        local keys = {
            "font_size", "copt_font_size", "text_font_size", "reader_font_size",
            "fontSize", "copt_font_size_default",
        }
        local objects = {}
        if ui then
            objects[#objects + 1] = ui.document and ui.document.configurable
            objects[#objects + 1] = ui.document and ui.document.settings
            objects[#objects + 1] = ui.document
            objects[#objects + 1] = ui.view and ui.view.document and ui.view.document.configurable
            objects[#objects + 1] = ui.view and ui.view.document
            objects[#objects + 1] = ui.doc_settings
            objects[#objects + 1] = ui.reader_settings
        end
        objects[#objects + 1] = rawget(_G, "G_reader_settings")

        for _, obj in ipairs(objects) do
            if type(obj) == "table" then
                for _, key in ipairs(keys) do
                    local direct = normalize_font_size(obj[key])
                    if direct then
                        return direct, key
                    end
                    local setting = normalize_font_size(read_setting(obj, key))
                    if setting then
                        return setting, key
                    end
                end
            end
        end
        return nil, nil
    end

    local function find_reader_font_name(ui)
        local keys = { "font_face", "font_family", "copt_font_face", "fontFace", "font" }
        local objects = {}
        if ui then
            objects[#objects + 1] = ui.document and ui.document.configurable
            objects[#objects + 1] = ui.document and ui.document.settings
            objects[#objects + 1] = ui.document
            objects[#objects + 1] = ui.view and ui.view.document and ui.view.document.configurable
            objects[#objects + 1] = ui.view and ui.view.document
            objects[#objects + 1] = ui.doc_settings
            objects[#objects + 1] = ui.reader_settings
        end
        objects[#objects + 1] = rawget(_G, "G_reader_settings")
        for _, obj in ipairs(objects) do
            if type(obj) == "table" then
                for _, key in ipairs(keys) do
                    local value = obj[key]
                    if type(value) == "string" and value ~= "" then
                        return value
                    end
                    value = read_setting(obj, key)
                    if type(value) == "string" and value ~= "" then
                        return value
                    end
                end
            end
        end
        return nil
    end

    -- KOReader's reader font_size is a CRE logical size, while ScrollHtmlWidget
    -- expects screen-scaled widget pixels. Keep the 80% relation in CRE units,
    -- then scale once for the popup renderer. Do not use the unscaled value as
    -- CSS px: on Kindle Voyage that rendered much smaller than the reader text.
    local fallback_reader_font_size = 28
    local min_popup_font_size = scale(12)
    local doc_margins = {
        left = scale(20),
        right = scale(20),
        top = scale(10),
        bottom = scale(10),
    }
    local doc_font_name = find_reader_font_name(self.ui)
    local reader_font_size, reader_font_source = find_reader_font_size(self.ui)
    local effective_reader_font_size = reader_font_size or self._weread_last_reader_font_size or fallback_reader_font_size

    if reader_font_size then
        self._weread_last_reader_font_size = reader_font_size
    end

    local popup_reader_units = math.max(12, math.floor(effective_reader_font_size * 0.8 + 0.5))
    local doc_font_size = math.max(min_popup_font_size, scale(popup_reader_units))
    local css_font_size = doc_font_size

    logger.info(
        LOG_MODULE,
        "thought popup font:",
        "reader=", tostring(effective_reader_font_size),
        "source=", tostring(reader_font_source or (self._weread_last_reader_font_size and "last" or "fallback")),
        "popup_units=", tostring(popup_reader_units),
        "widget_px=", tostring(doc_font_size),
        "css_px=", tostring(css_font_size),
        "font=", tostring(doc_font_name or "default")
    )

    return {
        html = html,
        css = [[
body{font-size:]] .. tostring(css_font_size) .. [[px !important;}
.weread-thought-popup{font-size:1em !important;line-height:1.35;}
.weread-thought-popup blockquote{margin:0 0 0.7em 0;padding-left:0.7em;border-left:2px solid #aaa;color:#555;font-size:1em !important;}
.weread-thought-popup p{margin:0 0 0.85em 0;font-size:1em !important;}
.weread-thought-popup strong{font-weight:bold;color:#333;font-size:1em !important;}
]],
        doc_font_name = doc_font_name,
        doc_font_size = doc_font_size,
        doc_margins = doc_margins,
        height_ratio = 0.42,
        dialog = self.ui,
    }
end

function WeReadPlugin:showThoughtPopupFromHref(href)
    local info = self:_parseThoughtHref(href)
    if not info then
        return false
    end

    local reviews = self:_loadThoughtReviews(info.book_id, info.chapter_uid)
    if type(reviews) ~= "table" then
        self:showInfo(_("No cached thoughts found for this chapter. Please re-download the book with underlines and thoughts."))
        return true
    end

    local target
    for _, rv in ipairs(reviews) do
        if tostring(rv.range or "") == tostring(info.range or "") then
            target = rv
            break
        end
    end

    if not target then
        self:showInfo(_("No matching thought found for this underline."))
        return true
    end

    local html = self:_formatThoughtPopupHtml(target)
    if not html or html == "" then
        self:showInfo(_("No thought content."))
        return true
    end

    local ok_popup, ThoughtPopup = pcall(require, "lib.thought_popup")
    if ok_popup and ThoughtPopup and type(ThoughtPopup.show) == "function" then
        local ok, err = pcall(function()
            if type(ThoughtPopup.init) == "function" then
                ThoughtPopup.init({})
            end
            ThoughtPopup.show(self:_thoughtPopupOptions(html))
        end)
        if ok then
            return true
        end
        logger.warn(LOG_MODULE, "thought popup failed, fallback to ConfirmBox:", err)
    end

    local text = self:_formatThoughtPopupText(target)
    UIManager:show(ConfirmBox:new{
        text = text or strip_tags(html),
        ok_text = _("Close"),
    })
    return true
end

function WeReadPlugin:_onThoughtLinkTap(ges)
    if not self.ui or not self.ui.link then
        return false
    end

    local ok, link = pcall(function()
        return self.ui.link:getLinkFromGes(ges)
    end)
    if not ok or not link then
        return false
    end

    local href = self:_linkHref(link)
    if type(href) ~= "string" or not (href:find("^wrthought://") or href:find("^#?wrthought%-")) then
        return false
    end

    -- When annotations are hidden, swallow the tap so the custom scheme never
    -- falls through to KOReader's default link handler.
    if self.settings:get("cache").show_annotations == false then
        return true
    end

    return self:showThoughtPopupFromHref(href)
end

function WeReadPlugin:onReaderReady()
    self._reader_session_gen = (self._reader_session_gen or 0) + 1
    self._report_suspended = false
    self:_teardownThoughtInterception()

    local weread_book_id = self:detectWeReadBook()
    -- The handler only consumes WeRead thought links, so it is safe to register for
    -- any reader document. This also keeps popups working if the cache directory
    -- was changed after the book was generated and detectWeReadBook() cannot
    -- resolve the old path.
    self:_setupAnnotationTapSuppression()

    -- Do not call applyAnnotationVisibility() automatically on reader open.
    -- setStyleSheet() + UpdatePos can trigger visible reload/flicker on some EPUBs.
    self._report_last_page = nil
    self:markReadActivity("reader_ready")

    local rr = self.settings:get("read_report")
    if rr.enabled then
        if self:maybeStartReadReport("reader_ready") then
            if weread_book_id then
                self:showTransientInfo(T(_("Reading time report started: %1"), self._report_current_book_title or weread_book_id), 2)
            end
        elseif rr.mode == "auto" then
            self:showTransientInfo(_("Current book is not from WeRead, reading time not reported"), 1)
        end
    end
end

function WeReadPlugin:onPageUpdate(page)
    if page == nil or page == false or not self.ui.document then
        return
    end
    if self._report_last_page ~= page then
        self._report_last_page = page
        self:markReadActivity("page_update")
    end
end

function WeReadPlugin:onSuspend()
    self._report_suspended = true
    self:stopReadReport("suspend")
end

function WeReadPlugin:onResume()
    self._report_suspended = false
    if self.ui.document then
        self:markReadActivity("resume")
        self:maybeStartReadReport("resume")
    end
end

function WeReadPlugin:onCloseDocument()
    self._reader_session_gen = (self._reader_session_gen or 0) + 1
    self:_teardownThoughtInterception()
    self:stopReadReport("document_closed")
    self._auto_report_book_id = nil
    self._auto_report_book_title = nil
    self._report_current_book_id = nil
    self._report_current_book_title = nil
    self._report_current_book_source = nil
    self._report_last_activity = nil
    self._report_last_page = nil
end

function WeReadPlugin:markReadActivity(reason)
    if not self.ui.document or self._report_suspended then
        return false
    end
    local book_id, title, source = self:resolveReadReportTarget()
    if not book_id then
        return false
    end
    self._auto_report_book_id = book_id
    self._auto_report_book_title = title
    self._report_current_book_id = book_id
    self._report_current_book_title = title
    self._report_current_book_source = source
    self._report_last_activity = os.time()
    self._report_last_activity_reason = reason or "reader_activity"
    self._report_stop_reason = nil
    if self._report_state == "idle" or self._report_state == "stopped" or self._report_state == "suspended" then
        self._report_state = "active"
    end
    if self.settings:get("read_report").enabled and not self._report_task then
        self:maybeStartReadReport(reason or "reader_activity")
    end
    return true
end

function WeReadPlugin:logReadReportSkip(reason, detail)
    local message = tostring(reason or "unknown") .. (detail and (":" .. tostring(detail)) or "")
    if self._report_last_skip ~= message then
        logger.info(LOG_MODULE, "read report skipped:", message)
        self._report_last_skip = message
    end
end

function WeReadPlugin:maybeStartReadReport(reason)
    local rr = self.settings:get("read_report")
    if not rr.enabled then
        self:logReadReportSkip("disabled")
        return false
    end
    if self._report_suspended then
        self._report_state = "suspended"
        self:logReadReportSkip("suspended")
        return false
    end
    if not self.ui.document then
        if self._report_task then
            self:stopReadReport("no_document")
        else
            self._report_state = "stopped"
        end
        self:logReadReportSkip("no_document")
        return false
    end

    local book_id, title, source = self:resolveReadReportTarget()
    if not book_id then
        if self._report_task then
            self:stopReadReport(source or "missing_book_id")
        else
            self._report_state = "stopped"
        end
        self:logReadReportSkip(source or "missing_book_id")
        return false
    end

    self._auto_report_book_id = book_id
    self._auto_report_book_title = title
    self._report_current_book_id = book_id
    self._report_current_book_title = title
    self._report_current_book_source = source
    self._report_last_activity = self._report_last_activity or os.time()

    if self._report_task then
        return true
    end
    return self:startReadReport(true, reason or "maybe_start")
end

function WeReadPlugin:startReadReport(silent, reason)
    local rr = self.settings:get("read_report")
    if not rr.enabled or self._report_suspended or not self.ui.document then
        return false
    end

    local book_id, title, source = self:resolveReadReportTarget()
    if not book_id then
        self:logReadReportSkip(source or "missing_book_id")
        return false
    end

    if self._report_task then
        return true
    end

    local interval = tonumber(rr.interval_seconds) or READ_REPORT_DEFAULT_INTERVAL_SECONDS
    if interval < 10 then
        interval = 10
    end
    self._report_generation = (self._report_generation or 0) + 1
    local generation = self._report_generation
    self._report_count = self._report_count or 0
    self._report_tick_count = 0
    self._report_failure_count = self._report_failure_count or 0
    self._report_consecutive_failures = self._report_consecutive_failures or 0
    self._report_last_activity = self._report_last_activity or os.time()
    self._report_current_book_id = book_id
    self._report_current_book_title = title
    self._report_current_book_source = source
    self._report_state = "waiting"
    self._report_stop_reason = nil
    self._report_last_skip = nil

    local task
    task = function()
        if self._report_generation ~= generation or self._report_task ~= task then
            return
        end
        self._report_tick_count = (self._report_tick_count or 0) + 1
        if self._report_tick_count == 1 or self._report_tick_count % 20 == 0 then
            logger.info(LOG_MODULE, "read report tick:",
                "count=", self._report_tick_count,
                "book_id=", self._report_current_book_id or "",
                "state=", self._report_state or "unknown")
        end
        local ok, err = pcall(function()
            self:doReadReport()
        end)
        if not ok then
            self:setReadReportError(err, "report task error:", true, "task_error")
        end
        if self._report_generation == generation and self._report_task == task then
            UIManager:scheduleIn(interval, task)
        end
    end
    self._report_task = task
    UIManager:scheduleIn(interval, task)
    logger.info(LOG_MODULE, "reading time report started:",
        "reason=", reason or "unknown",
        "book_id=", book_id,
        "source=", source or "unknown",
        "interval=", interval,
        "idle_timeout=", rr.idle_timeout_seconds or READ_REPORT_DEFAULT_IDLE_TIMEOUT_SECONDS)
    if not silent then
        self:showTransientInfo(T(_("Reading time report started: %1"), title or book_id), 1)
    end
    return true
end

function WeReadPlugin:stopReadReport(reason)
    reason = reason or "unspecified"
    local had_task = self._report_task ~= nil
    self._report_generation = (self._report_generation or 0) + 1
    if self._report_task then
        UIManager:unschedule(self._report_task)
        self._report_task = nil
    end

    if reason == "idle_timeout" then
        self._report_state = "idle"
    elseif reason == "suspend" then
        self._report_state = "suspended"
    else
        self._report_state = "stopped"
    end
    self._report_stop_reason = reason

    if had_task then
        logger.info(LOG_MODULE, "reading time report stopped:",
            "reason=", reason,
            "success_count=", self._report_count or 0,
            "failure_count=", self._report_failure_count or 0)
    end
end

function WeReadPlugin:setReadReportError(err, log_prefix, update_status, kind)
    local message = tostring(err)
    if update_status ~= false then
        self._report_last_error = message
        self._report_last_error_kind = kind or "error"
        self._report_failure_count = (self._report_failure_count or 0) + 1
        self._report_consecutive_failures = (self._report_consecutive_failures or 0) + 1
        self._report_state = "error"
    end
    if self._report_logged_error ~= message then
        logger.warn(LOG_MODULE, log_prefix or "read report error:", log_error(message))
        self._report_logged_error = message
    end
end

local function read_report_accepted(result)
    return type(result) == "table"
        and (result.succ == true or tonumber(result.succ) == 1)
end

local function read_report_confirmed(result)
    -- WeRead does not always return synckey. succ=1 is the actual acceptance
    -- signal, so a missing synckey must not be counted as a failed report.
    return read_report_accepted(result)
end

local function read_report_result_summary(result)
    if type(result) ~= "table" then
        return "non_table_response"
    end
    local parts = {
        "succ=" .. tostring(result.succ),
        "has_synckey=" .. tostring(result.synckey ~= nil),
    }
    local err_code = result.errCode or result.errcode or result.code
    local err_message = result.errMsg or result.errmsg or result.message or result.msg
    if err_code ~= nil then
        parts[#parts + 1] = "error_code=" .. tostring(err_code)
    end
    if err_message ~= nil then
        parts[#parts + 1] = "error_message=" .. tostring(err_message):gsub("[%c]+", " "):sub(1, 160)
    end
    return table.concat(parts, ", ")
end

function WeReadPlugin:recordReadReportSuccess(result)
    local recovered = self._report_last_error ~= nil
    self._report_count = (self._report_count or 0) + 1
    self._report_last_time = os.time()
    self._report_last_error = nil
    self._report_last_error_kind = nil
    self._report_logged_error = nil
    self._report_last_skip = nil
    self._report_consecutive_failures = 0
    self._report_state = "active"
    if recovered or self._report_count == 1 or self._report_count % 20 == 0 then
        logger.info(LOG_MODULE, "read report success:",
            "count=", self._report_count,
            "has_synckey=", type(result) == "table" and result.synckey ~= nil or false)
    end
end

local function read_report_book_record(books, book_id)
    if type(books) ~= "table" then
        return nil
    end
    return books[tostring(book_id)] or books[book_id]
end

local function normalize_progress_ratio(value)
    value = tonumber(value)
    if not value then
        return nil
    end
    if value > 1 then
        value = value / 100
    end
    if value < 0 then
        value = 0
    elseif value > 1 then
        value = 1
    end
    return value
end

function WeReadPlugin:getLocalReadProgressRatio()
    local ratio

    -- Reflowable documents usually expose progress through ReaderRolling.
    if self.ui and self.ui.rolling and type(self.ui.rolling.getProgress) == "function" then
        local ok, value = pcall(function()
            return self.ui.rolling:getProgress()
        end)
        if ok then
            ratio = normalize_progress_ratio(value)
        end
    end

    -- Paginated documents expose current page and page count instead.
    if not ratio and self.ui and self.ui.document then
        local page = tonumber(self._report_last_page)
        if not page and type(self.ui.document.getCurrentPage) == "function" then
            local ok, value = pcall(function()
                return self.ui.document:getCurrentPage()
            end)
            if ok then
                page = tonumber(value)
            end
        end
        local page_count
        if type(self.ui.document.getPageCount) == "function" then
            local ok, value = pcall(function()
                return self.ui.document:getPageCount()
            end)
            if ok then
                page_count = tonumber(value)
            end
        end
        if page and page_count and page_count > 0 then
            ratio = normalize_progress_ratio(page / page_count)
        end
    end

    return ratio
end

function WeReadPlugin:ensureReadReportContext(book_id, force)
    book_id = tostring(book_id or "")
    if book_id == "" then
        error("missing book id")
    end
    if not self.settings:is_cookie_configured() then
        error("cookie not configured")
    end

    local books = self.settings:get("books", {})
    local book = read_report_book_record(books, book_id) or {
        book_id = book_id,
        title = self._report_current_book_title or book_id,
    }
    book.book_id = book.book_id or book.bookId or book_id
    book.reader_url = book.reader_url or WeRead.reader_url(book_id)

    local now = os.time()
    local context_age = now - (tonumber(book.read_context_updated_at) or 0)
    local context_ready = book.psvts ~= nil and tostring(book.psvts) ~= ""
        and book.chapter_uid ~= nil
        and type(book.chapters) == "table" and #book.chapters > 0

    if not force and context_ready and context_age < 15 * 60 then
        return book
    end

    -- This is the step that replaces manual cURL import: use the QR-login Cookie
    -- to open the real web reader and extract psvts, pclts and token.
    Content.ensure_reader_state(self.client, book)

    if force or type(book.chapters) ~= "table" or #book.chapters == 0 then
        Content.fetch_catalog(self.client, book)
    end

    -- Seed the context from WeRead's existing remote progress when available.
    local progress_ok, progress_result = pcall(function()
        return self.client:get_progress(book_id)
    end)
    if progress_ok and type(progress_result) == "table" then
        local remote = type(progress_result.book) == "table" and progress_result.book or progress_result
        book.progress = tonumber(remote.progress) or tonumber(book.progress) or 0
        book.chapter_uid = remote.chapterUid or remote.chapterId or remote.chapter_uid or book.chapter_uid
        book.chapter_idx = tonumber(remote.chapterIdx or remote.chapterIndex or remote.chapter_idx)
            or tonumber(book.chapter_idx)
        book.chapter_offset = tonumber(remote.chapterOffset or remote.chapterPos or remote.offset)
            or tonumber(book.chapter_offset) or 0
    end

    local chapters = book.chapters or {}
    local selected
    if book.chapter_uid ~= nil then
        for _, chapter in ipairs(chapters) do
            if tostring(chapter.chapterUid or "") == tostring(book.chapter_uid) then
                selected = chapter
                break
            end
        end
    end

    if not selected and #chapters > 0 then
        local ratio = normalize_progress_ratio(book.progress) or 0
        local index = math.floor(ratio * #chapters) + 1
        if index < 1 then
            index = 1
        elseif index > #chapters then
            index = #chapters
        end
        selected = chapters[index]
    end
    selected = selected or Content.first_readable_chapter(chapters)
    if not selected then
        error("no readable chapter found for report context")
    end

    book.chapter_uid = selected.chapterUid or book.chapter_uid
    book.chapter_idx = tonumber(selected.chapterIdx) or tonumber(book.chapter_idx) or 0
    book.chapter_word_count = tonumber(selected.wordCount) or tonumber(book.chapter_word_count) or 0
    book.app_id = book.app_id or WeRead.web_app_id()
    book.read_context_updated_at = now
    book.read_context_ready = book.psvts ~= nil and tostring(book.psvts) ~= ""
        and book.chapter_uid ~= nil

    if not book.read_context_ready then
        error("reader context is incomplete")
    end

    books[book_id] = book
    self.settings:set("books", books)
    self.settings:flush()
    return book
end

function WeReadPlugin:estimateReadReportPosition(book)
    local chapters = type(book.chapters) == "table" and book.chapters or {}
    local ratio = self:getLocalReadProgressRatio()
        or normalize_progress_ratio(book.progress)
        or 0

    local chapter
    local within_chapter = 0
    if #chapters > 0 then
        local scaled = ratio * #chapters
        local index = math.floor(scaled) + 1
        if index < 1 then
            index = 1
        elseif index > #chapters then
            index = #chapters
        end
        chapter = chapters[index]
        within_chapter = scaled - math.floor(scaled)
        if index == #chapters and ratio >= 1 then
            within_chapter = 1
        end
    end

    if not chapter and book.chapter_uid ~= nil then
        for _, item in ipairs(chapters) do
            if tostring(item.chapterUid or "") == tostring(book.chapter_uid) then
                chapter = item
                break
            end
        end
    end

    local chapter_uid = chapter and chapter.chapterUid or book.chapter_uid or 0
    local chapter_idx = tonumber(chapter and chapter.chapterIdx)
        or tonumber(book.chapter_idx) or 0
    local word_count = tonumber(chapter and chapter.wordCount)
        or tonumber(book.chapter_word_count) or 0
    local chapter_offset = tonumber(book.chapter_offset) or 0
    if word_count > 0 then
        chapter_offset = math.floor(within_chapter * word_count)
    end

    return {
        chapter_uid = chapter_uid,
        chapter_idx = chapter_idx,
        chapter_offset = chapter_offset,
        progress = math.floor(ratio * 100 + 0.5),
    }
end

function WeReadPlugin:buildReadReportPayload(book_id, elapsed_seconds, book)
    book = book or self:ensureReadReportContext(book_id, false)
    local position = self:estimateReadReportPosition(book)
    return WeRead.make_read_payload{
        book_id = book_id,
        chapter_uid = position.chapter_uid,
        chapter_idx = position.chapter_idx,
        chapter_offset = position.chapter_offset,
        progress = position.progress,
        summary = book.summary or "",
        elapsed_seconds = elapsed_seconds,
        app_id = book.app_id or WeRead.web_app_id(),
        psvts = book.psvts,
        pclts = book.pclts,
        token = book.token,
    }
end

function WeReadPlugin:doReadReport()
    local rr = self.settings:get("read_report")
    if not rr.enabled then
        self:stopReadReport("disabled")
        return
    end
    if self._report_suspended then
        self:stopReadReport("suspend")
        return
    end
    if not self.ui.document then
        self:stopReadReport("no_document")
        return
    end

    local report_book_id, title, source = self:resolveReadReportTarget()
    if not report_book_id then
        self:stopReadReport(source or "missing_book_id")
        return
    end
    if self._report_current_book_id and self._report_current_book_id ~= report_book_id then
        self:stopReadReport("document_changed")
        self._report_last_activity = os.time()
        self:maybeStartReadReport("document_changed")
        return
    end
    self._report_current_book_id = report_book_id
    self._report_current_book_title = title
    self._report_current_book_source = source

    local idle_timeout = tonumber(rr.idle_timeout_seconds) or READ_REPORT_DEFAULT_IDLE_TIMEOUT_SECONDS
    local last_activity = self._report_last_activity or os.time()
    local idle_seconds = math.max(0, os.time() - last_activity)
    if idle_seconds >= idle_timeout then
        logger.info(LOG_MODULE, "read report idle timeout:", "idle_seconds=", idle_seconds)
        self:stopReadReport("idle_timeout")
        return
    end

    if not self.settings:is_cookie_configured() then
        self:setReadReportError("cookie not configured", "read report skipped:", true, "authentication")
        return
    end
    if not NetworkMgr:isOnline() then
        self._report_state = "offline"
        self:logReadReportSkip("offline")
        return
    end

    local interval = tonumber(rr.interval_seconds) or READ_REPORT_DEFAULT_INTERVAL_SECONDS
    if interval < 10 then
        interval = 10
    end
    self._report_state = "active"

    -- Lazily initialize a real reader context from the QR-login Cookie. This is
    -- automatic and replaces the old manual /web/book/read cURL requirement.
    local context_ok, report_book = pcall(function()
        return self:ensureReadReportContext(report_book_id, false)
    end)
    if not context_ok then
        self:setReadReportError(report_book, "read report context init failed:", true, "context")
        return
    end

    local report_referer = report_book.reader_url or WeRead.reader_url(report_book_id)
    local payload = self:buildReadReportPayload(report_book_id, interval, report_book)
    local ok, result = pcall(function()
        return self.client:report_read(payload, report_referer)
    end)
    if ok and read_report_confirmed(result) then
        self:recordReadReportSuccess(result)
        return
    end
    if not ok then
        self:setReadReportError(result, "read report request failed:", true, "transport")
        return
    end

    -- A server rejection usually means the short-lived reader context has
    -- expired. Re-open the web reader, rebuild the signed payload, and retry.
    local first_failure = read_report_result_summary(result)
    local refresh_ok, refreshed_book = pcall(function()
        return self:ensureReadReportContext(report_book_id, true)
    end)
    if refresh_ok then
        local retry_payload = self:buildReadReportPayload(report_book_id, interval, refreshed_book)
        local retry_ok, retry_result = pcall(function()
            return self.client:report_read(
                retry_payload,
                refreshed_book.reader_url or report_referer
            )
        end)
        if retry_ok and read_report_confirmed(retry_result) then
            self:recordReadReportSuccess(retry_result)
            return
        end
        first_failure = "initial=" .. first_failure .. "; refreshed="
            .. (retry_ok and read_report_result_summary(retry_result) or tostring(retry_result))
    else
        first_failure = first_failure .. "; context_refresh=" .. tostring(refreshed_book)
    end

    -- Only after a fresh reader context also fails do we renew the login Cookie.
    local now = os.time()
    local renewal_cooldown = 10 * 60
    if now - (self._report_last_renew_attempt or 0) < renewal_cooldown then
        self:setReadReportError(first_failure, "read report server rejected:", true, "server")
        return
    end

    self._report_last_renew_attempt = now
    local renew_ok, renew_result = pcall(function()
        return self.client:renew_cookie()
    end)
    if not renew_ok or not read_report_accepted(renew_result) then
        local renewal_error = renew_ok and read_report_result_summary(renew_result) or tostring(renew_result)
        self:setReadReportError(first_failure .. "; renewal=" .. renewal_error,
            "read report renewal failed:", true, "authentication")
        return
    end

    local final_context_ok, final_book = pcall(function()
        return self:ensureReadReportContext(report_book_id, true)
    end)
    if not final_context_ok then
        self:setReadReportError(first_failure .. "; final_context=" .. tostring(final_book),
            "read report retry failed:", true, "context")
        return
    end

    local final_payload = self:buildReadReportPayload(report_book_id, interval, final_book)
    local final_ok, final_result = pcall(function()
        return self.client:report_read(
            final_payload,
            final_book.reader_url or report_referer
        )
    end)
    if final_ok and read_report_confirmed(final_result) then
        self:recordReadReportSuccess(final_result)
        return
    end

    local final_error = final_ok and read_report_result_summary(final_result) or tostring(final_result)
    self:setReadReportError(first_failure .. "; final=" .. final_error,
        "read report retry failed:", true, final_ok and "server" or "transport")
end

function WeReadPlugin:checkUpdateWithUI()
    local Updater = require("lib.updater")
    logger.info(LOG_MODULE, "check update:", "manifest=", UPDATE_MANIFEST_URL)
    local updater = Updater:new{
        plugin = self,
        current_version = PLUGIN_VERSION,
        plugin_dir = self.plugin_dir,
        manifest_url = UPDATE_MANIFEST_URL,
    }
    updater:checkWithUI()
end

function WeReadPlugin:onFlushSettings()
    if self.settings then
        self.settings:flush()
    end
end

return WeReadPlugin