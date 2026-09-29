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

CreateThread(function()
    if Config and Config.CheckVersion then
        local currentVersion = GetResourceMetadata(GetCurrentResourceName(), 'version', 0)
        checkVersion('https://specialstos.github.io/versionCheck/cis_libs.txt', currentVersion)
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
