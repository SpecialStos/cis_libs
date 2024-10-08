-- cis_libs/server/versionCheck.lua

local function parseVersionInfo(remoteVersion)
    local versionInfo = {}
    for line in remoteVersion:gmatch("[^\r\n]+") do
        if not versionInfo.latestVersion then
            versionInfo.latestVersion = line:gsub("^%s*(.-)%s*$", "%1")
        else
            versionInfo.changelog = (versionInfo.changelog or "") .. line .. "\n"
        end
    end
    return versionInfo
end

local function checkVersion(url, currentVersion)
    PerformHttpRequest(url, function(err, remoteVersion, headers)
        if err == 200 and remoteVersion then
            local versionInfo = parseVersionInfo(remoteVersion)
            local latestVersion = versionInfo.latestVersion
            local changelog = versionInfo.changelog

            if currentVersion == latestVersion then
                Logging.Info("Resource is up to date. Version: " .. currentVersion .. ".", "master")
            else
                Logging.Warn(("Resource is outdated. Your current version is: %s. Latest version is: %s.\n\nChangelog:\n%s"):format(currentVersion, latestVersion, changelog), "master")
            end
        else
            Logging.Error("Failed to retrieve version information.", "error")
        end
    end, "GET")
end

Citizen.CreateThread(function()
    if Config.CheckVersion then
        local currentVersion = GetResourceMetadata(GetCurrentResourceName(), "version")
        checkVersion("https://specialstos.github.io/versionCheck/cis_libs.txt", currentVersion)
    end
end)

exports("CheckResourceVersion", function(resourceName, resourceUrl, currentVersion)
    if type(resourceName) ~= "string" or type(resourceUrl) ~= "string" or type(currentVersion) ~= "string" then
        error("Invalid arguments. Expected strings for resourceName, resourceUrl, and currentVersion.")
    end

    PerformHttpRequest(resourceUrl, function(err, remoteVersion, headers)
        if err == 200 and remoteVersion then
            local versionInfo = parseVersionInfo(remoteVersion)
            local latestVersion = versionInfo.latestVersion
            local changelog = versionInfo.changelog

            if currentVersion == latestVersion then
                Logging.Info(("[%s] Resource is up to date. Version: %s."):format(resourceName, currentVersion))
            else
                Logging.Warn(("^1[%s] Resource is outdated. Your current version is: %s. Latest version is: %s.^1\n\nChangelog:\n%s"):format(resourceName, currentVersion, latestVersion, changelog))
            end
        else
            Logging.Warn(("^1[%s] Failed to retrieve version information.^0"):format(resourceName))
        end
    end, "GET")
end)