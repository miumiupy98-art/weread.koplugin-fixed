local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local Crypto = require("lib.crypto")

local Updater = {}
Updater.__index = Updater

local LOG_MODULE = "[WeRead][Updater]"

local function shell_quote(value)
    value = tostring(value or "")
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function run_cmd(cmd)
    logger.info(LOG_MODULE, "run:", cmd)
    local a, _b, c = os.execute(cmd)
    if a == true or a == 0 or c == 0 then
        return true
    end
    return false, tostring(a) .. ":" .. tostring(c)
end

local function dirname(path)
    return tostring(path or ""):match("^(.*)/[^/]+/?$") or "."
end

local function file_exists(path)
    local f = io.open(path, "rb")
    if f then
        f:close()
        return true
    end
    return false
end

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local data = f:read("*a")
    f:close()
    return data
end

local function write_file(path, data)
    local f = io.open(path, "wb")
    if not f then
        return false
    end
    f:write(data or "")
    f:close()
    return true
end

local function trim_version(version)
    version = tostring(version or "")
    version = version:gsub("^v", "")
    version = version:gsub("%-.*$", "")
    return version
end

local function parse_version(version)
    version = trim_version(version)
    local parts = {}
    for n in version:gmatch("%d+") do
        parts[#parts + 1] = tonumber(n) or 0
    end
    return parts
end

local function compare_versions(a, b)
    local va, vb = parse_version(a), parse_version(b)
    local n = math.max(#va, #vb)
    for i = 1, n do
        local ai, bi = va[i] or 0, vb[i] or 0
        if ai < bi then return -1 end
        if ai > bi then return 1 end
    end
    return 0
end

local function basename(path)
    return tostring(path or ""):match("([^/]+)/?$") or "weread.koplugin"
end

function Updater:new(opts)
    opts = opts or {}
    local obj = setmetatable({}, self)
    obj.plugin = opts.plugin
    obj.current_version = opts.current_version or "0.0.0"
    obj.plugin_dir = opts.plugin_dir or "."
    obj.manifest_url = opts.manifest_url or ""
    return obj
end

function Updater:showInfo(text)
    if self.plugin and self.plugin.showInfo then
        self.plugin:showInfo(text)
        return
    end
    UIManager:show(InfoMessage:new{ text = text })
end

function Updater:showBusy(text)
    if self.plugin and self.plugin.showBusy then
        self.plugin:showBusy(text)
    else
        self:showInfo(text)
    end
end

function Updater:closeBusy()
    if self.plugin and self.plugin.closeBusy then
        self.plugin:closeBusy()
    end
end

function Updater:download(url)
    if not url or url == "" then
        error("empty download url")
    end
    if not self.plugin or not self.plugin.client then
        error("WeRead client is not available")
    end
    return self.plugin.client:get_binary(url, { referer = "https://github.com/" })
end

function Updater:decodeJson(data)
    if not self.plugin or not self.plugin.client or not self.plugin.client.json_decode then
        error("json decoder is not available")
    end
    return self.plugin.client:json_decode(data)
end

function Updater:fetchManifest()
    if self.manifest_url == "" then
        error("manifest_url is empty")
    end
    local raw = self:download(self.manifest_url)
    if type(raw) ~= "string" or raw == "" then
        error("empty manifest response")
    end
    local manifest = self:decodeJson(raw)
    if type(manifest) ~= "table" then
        error("invalid update manifest")
    end
    if type(manifest.version) ~= "string" or manifest.version == "" then
        error("manifest.version is missing")
    end
    if type(manifest.package_url) ~= "string" or manifest.package_url == "" then
        error("manifest.package_url is missing")
    end
    return manifest
end

function Updater:isNewer(manifest)
    return compare_versions(self.current_version, manifest.version) < 0
end

function Updater:checkWithUI()
    self:showBusy("正在检查更新...")
    UIManager:scheduleIn(0.1, function()
        local ok, manifest_or_err = xpcall(function()
            return self:fetchManifest()
        end, debug.traceback)
        self:closeBusy()
        if not ok then
            logger.warn(LOG_MODULE, "check failed:", tostring(manifest_or_err))
            self:showInfo("检查更新失败：\n" .. tostring(manifest_or_err))
            return
        end
        local manifest = manifest_or_err
        if not self:isNewer(manifest) then
            self:showInfo("当前已是最新版本。\n\n当前版本：v" .. tostring(self.current_version) .. "\n远程版本：v" .. tostring(manifest.version))
            return
        end
        self:confirmInstall(manifest)
    end)
end

function Updater:confirmInstall(manifest)
    local notes = manifest.notes or ""
    local text = "发现新版本：v" .. tostring(manifest.version)
        .. "\n当前版本：v" .. tostring(self.current_version)
    if manifest.name and manifest.name ~= "" then
        text = text .. "\n\n" .. tostring(manifest.name)
    end
    if notes ~= "" then
        text = text .. "\n\n更新说明：\n" .. tostring(notes)
    end
    text = text .. "\n\n是否下载并安装？安装完成后需要手动重启 KOReader。"

    local box
    box = ConfirmBox:new{
        text = text,
        ok_text = "下载并安装",
        ok_callback = function()
            UIManager:close(box)
            self:installWithUI(manifest)
        end,
        cancel_text = "取消",
    }
    UIManager:show(box)
end

function Updater:installWithUI(manifest)
    self:showBusy("正在下载并安装更新...")
    UIManager:scheduleIn(0.1, function()
        local ok, result_or_err = xpcall(function()
            return self:install(manifest)
        end, debug.traceback)
        self:closeBusy()
        if not ok then
            logger.err(LOG_MODULE, "install failed:", tostring(result_or_err))
            self:showInfo("更新失败：\n" .. tostring(result_or_err))
            return
        end
        self:showInfo("更新已安装：v" .. tostring(manifest.version)
            .. "\n\n已备份旧插件：\n" .. tostring(result_or_err.backup_dir)
            .. "\n\n请手动重启 KOReader 后生效。")
    end)
end

function Updater:install(manifest)
    local plugin_dir = self.plugin_dir
    if not plugin_dir or plugin_dir == "" or plugin_dir == "." then
        error("invalid plugin_dir")
    end
    if not file_exists(plugin_dir .. "/main.lua") then
        error("plugin_dir does not look like a KOReader plugin: " .. tostring(plugin_dir))
    end

    local parent_dir = dirname(plugin_dir)
    local plugin_name = basename(plugin_dir)
    local stamp = os.date("%Y%m%d-%H%M%S")
    local tmp_dir = parent_dir .. "/." .. plugin_name .. ".update-" .. stamp
    local unpack_dir = tmp_dir .. "/unpacked"
    local zip_path = tmp_dir .. "/update.zip"
    local backup_dir = plugin_dir .. ".bak-" .. stamp
    local keep_config = tmp_dir .. "/config.lua.keep"

    assert(run_cmd("rm -rf " .. shell_quote(tmp_dir)), "cannot clean temp directory")
    assert(run_cmd("mkdir -p " .. shell_quote(unpack_dir)), "cannot create temp directory")

    local zip_data = self:download(manifest.package_url)
    if type(zip_data) ~= "string" or zip_data == "" then
        error("downloaded update package is empty")
    end

    local expected_sha = tostring(manifest.sha256 or ""):lower():gsub("%s+", "")
    if expected_sha ~= "" and expected_sha ~= "put_zip_sha256_here" then
        local actual_sha = Crypto.sha256_hex(zip_data):lower()
        if actual_sha ~= expected_sha then
            error("sha256 mismatch\nexpected: " .. expected_sha .. "\nactual: " .. actual_sha)
        end
    else
        logger.warn(LOG_MODULE, "manifest.sha256 is empty; skip checksum verification")
    end

    assert(write_file(zip_path, zip_data), "cannot write update zip")
    assert(run_cmd("unzip -q " .. shell_quote(zip_path) .. " -d " .. shell_quote(unpack_dir)), "unzip failed")

    local src_dir
    if file_exists(unpack_dir .. "/" .. plugin_name .. "/main.lua") then
        src_dir = unpack_dir .. "/" .. plugin_name
    elseif file_exists(unpack_dir .. "/weread.koplugin/main.lua") then
        src_dir = unpack_dir .. "/weread.koplugin"
    elseif file_exists(unpack_dir .. "/main.lua") then
        src_dir = unpack_dir
    else
        error("update package does not contain main.lua")
    end

    -- config.lua contains user-specific credentials and local preferences.
    -- config.example.lua is only an onboarding template. Existing users may have
    -- edited it or may no longer need it after creating config.lua, so OTA should
    -- not overwrite either file. Keep updated config.example.lua in GitHub/Release
    -- packages for fresh installs, but skip it during OTA installs.
    for _, config_name in ipairs({ "config.lua", "config.example.lua" }) do
        local package_config = src_dir .. "/" .. config_name
        if file_exists(package_config) then
            logger.warn(LOG_MODULE, "remove " .. config_name .. " from update package before install")
            assert(run_cmd("rm -f " .. shell_quote(package_config)), "cannot remove package " .. config_name)
        end
    end

    if file_exists(plugin_dir .. "/config.lua") then
        assert(run_cmd("cp -f " .. shell_quote(plugin_dir .. "/config.lua") .. " " .. shell_quote(keep_config)), "cannot preserve config.lua")
    end

    assert(run_cmd("cp -a " .. shell_quote(plugin_dir) .. " " .. shell_quote(backup_dir)), "cannot backup current plugin")
    assert(run_cmd("cp -af " .. shell_quote(src_dir) .. "/. " .. shell_quote(plugin_dir) .. "/"), "cannot copy updated files")

    if file_exists(keep_config) then
        assert(run_cmd("cp -f " .. shell_quote(keep_config) .. " " .. shell_quote(plugin_dir .. "/config.lua")), "cannot restore config.lua")
    end

    local installed_main = read_file(plugin_dir .. "/main.lua") or ""
    local wanted = tostring(manifest.version):gsub("([%.%-%+%*%?%[%]%^%$%(%)%%])", "%%%1")
    if not installed_main:find("version%s*=%s*['\"]" .. wanted .. "['\"]") then
        logger.warn(LOG_MODULE, "installed main.lua version may not match manifest:", manifest.version)
    end

    run_cmd("rm -rf " .. shell_quote(tmp_dir))
    logger.info(LOG_MODULE, "update installed:", "version=", manifest.version, "backup=", backup_dir)
    return { backup_dir = backup_dir }
end

return Updater
