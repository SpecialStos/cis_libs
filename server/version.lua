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

-- NOTE on the callback's first parameter: it is the HTTP STATUS CODE, not an error,
local function checkVersion(url, currentVersion)
    PerformHttpRequest(url, function(err, remoteVersion)
        if err == 200 and remoteVersion then
            local versionInfo = parseVersionInfo(remoteVersion)
            if currentVersion == versionInfo.latestVersion then
                Logging.Info('Resource is up to date. Version: ' .. currentVersion .. '.', 'master')
            else
                Logging.Warn(('Resource is outdated. Current: %s Latest: %s\n%s'):format(
                    currentVersion,
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

-- Once per boot, and only if the operator turned it on.
CreateThread(function()
    if Config and Config.CheckVersion then
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

