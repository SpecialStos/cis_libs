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

-- The endpoint comes from config. There is no hardcoded host in this file: a
-- default-on outbound request to a third party on every boot is a supply-chain
-- risk, stalls on an air-gapped server, and is a phone-home a commercial
-- product should not make. `Config.CheckVersion` ships false, so on a default
-- install nothing here is reached at all.
local function versionCheckUrl()
    local url = Config and Config.VersionCheckUrl
    if type(url) ~= 'string' or url == '' then
        return nil
    end
    return url
end

CreateThread(function()
    if Config and Config.CheckVersion then
        local url = versionCheckUrl()
        if not url then
            Logging.Warn('Config.CheckVersion is on but Config.VersionCheckUrl is not set; skipping version check.')
            return
        end
        local currentVersion = GetResourceMetadata(GetCurrentResourceName(), 'version', 0)
        checkVersion(url, currentVersion)
    end
end)

exports('CheckResourceVersion', function(resourceName, resourceUrl, currentVersion)
    if type(resourceName) ~= 'string' or type(resourceUrl) ~= 'string' or type(currentVersion) ~= 'string' then
        return
    end
    PerformHttpRequest(resourceUrl, function(err, remoteVersion)
        if err == 200 and remoteVersion then
            local versionInfo = parseVersionInfo(remoteVersion)
            if currentVersion == versionInfo.latestVersion then
                Logging.Info(('[%s] up to date (%s)'):format(resourceName, currentVersion))
            else
                Logging.Warn(('[%s] outdated %s -> %s'):format(resourceName, currentVersion, tostring(versionInfo.latestVersion)))
            end
        else
            Logging.Warn(('[%s] version check failed'):format(resourceName))
        end
    end, 'GET')
end)
