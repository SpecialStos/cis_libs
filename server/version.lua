-- Optional update notice. Nothing here runs on a default install: see the comment on
-- versionCheckUrl below for why.

-- The remote document is plain text, not JSON: first line is the version, everything
-- after it is the changelog. A text file needs no build step and no content-type
local function parseVersionInfo(remoteVersion)
    local versionInfo = {}
    for line in remoteVersion:gmatch('[^\r\n]+') do
        if not versionInfo.latestVersion then
            versionInfo.latestVersion = line:gsub('^%s*(.-)%s*$', '%1')
        else
            versionInfo.changelog = (versionInfo.changelog or '') .. line .. '\n'
        end
    end
    return versionInfo
end

-- SEMVER ORDER, not string equality. Equality called every build that was not
-- byte-identical to the published line "outdated" -- a development build AHEAD of
-- it, a "v1.2.0", a trailing build tag. MAJOR.MINOR.PATCH compare as numbers
-- (so 1.10.0 is after 1.9.0), a pre-release sorts before its release
-- (1.2.0-beta < 1.2.0), and build metadata (+sha) is ignored.
local function parseSemver(v)
    if type(v) ~= 'string' then
        return nil
    end
    local core, pre = v:match('^%s*[vV]?(%d+[%.%d]*)%-?([%w%.%-]*)')
    if not core then
        return nil
    end
    local parts = {}
    for piece in core:gmatch('%d+') do
        parts[#parts + 1] = tonumber(piece)
    end
    return { parts[1] or 0, parts[2] or 0, parts[3] or 0, pre = pre ~= '' and pre or nil }
end

--- -1 when a is older than b, 0 when equal, 1 when newer; nil when either is not a version.
local function compareVersions(a, b)
    local x, y = parseSemver(a), parseSemver(b)
    if not x or not y then
        return nil
    end
    for i = 1, 3 do
        if x[i] ~= y[i] then
            return x[i] < y[i] and -1 or 1
        end
    end
    if x.pre == y.pre then
        return 0
    end
    if not x.pre then
        return 1
    end
    if not y.pre then
        return -1
    end
    return x.pre < y.pre and -1 or 1
end

-- NOTE on the callback's first parameter: it is the HTTP STATUS CODE, not an error,
local function checkVersion(url, currentVersion)
    PerformHttpRequest(url, function(err, remoteVersion)
        if err == 200 and remoteVersion then
            local versionInfo = parseVersionInfo(remoteVersion)
            local order = compareVersions(currentVersion, versionInfo.latestVersion)
            if order == nil then
                Logging.Warn(('Version check could not compare %s with the published %s; continuing startup.')
                    :format(tostring(currentVersion), tostring(versionInfo.latestVersion)))
            elseif order >= 0 then
                Logging.Info('Resource is up to date. Version: ' .. tostring(currentVersion) .. '.', 'master')
            else
                Logging.Warn(('Resource is outdated. Current: %s Latest: %s\n%s'):format(
                    tostring(currentVersion),
                    tostring(versionInfo.latestVersion),
                    versionInfo.changelog or ''
                ), 'master')
            end
        else
            Logging.Warn('Version check failed; continuing startup.')
        end
    end, 'GET')
end

-- The endpoint comes from config.
local function versionCheckUrl()
    local url = Config and Config.VersionCheckUrl
    if type(url) ~= 'string' or url == '' then
        return nil
    end
    return url
end

-- `set cis_check_version true|false` decides when it is set; otherwise
-- Config.CheckVersion does. Read when the check RUNS, never at load.
local function convarSwitch()
    if type(GetConvar) ~= 'function' then
        return nil
    end
    local ok, raw = pcall(GetConvar, 'cis_check_version', '')
    if not ok or type(raw) ~= 'string' then
        return nil
    end
    raw = raw:match('^%s*(.-)%s*$'):lower()
    if raw == '' then
        return nil
    end
    return raw == 'true' or raw == '1' or raw == 'yes' or raw == 'on'
end

local function checkEnabled()
    local pinned = convarSwitch()
    if pinned ~= nil then
        return pinned
    end
    return Config and Config.CheckVersion == true
end

-- How long boot waits for a configuration supplier before deciding. cis_libs
-- starts FIRST -- that is what `dependency 'cis_libs'` means -- so a thread that
-- read Config.CheckVersion on its first tick read the built-in default, false,
-- every time, and an operator who turned the check on in cis_core never got it.
local SUPPLIER_WAIT_MS = 30000
local SUPPLIER_POLL_MS = 500

-- Once per boot, and only if the operator turned it on.
CreateThread(function()
    local waited = 0
    while convarSwitch() == nil and Config and Config.__owner == 'cis_libs'
        and waited < SUPPLIER_WAIT_MS do
        Wait(SUPPLIER_POLL_MS)
        waited = waited + SUPPLIER_POLL_MS
    end
    if checkEnabled() then
        local url = versionCheckUrl()
        if not url then
            Logging.Warn('Config.CheckVersion is on but Config.VersionCheckUrl is not set; skipping version check.')
            return
        end
        -- Read from fxmanifest, not from a constant in this file, so the value an
        local currentVersion = GetResourceMetadata(GetCurrentResourceName(), 'version', 0)
        checkVersion(url, currentVersion)
    end
end)
