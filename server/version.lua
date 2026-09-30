-- Optional update notice. Nothing here runs on a default install: see the
-- comment on versionCheckUrl below for why.

-- The remote document is plain text, not JSON: first line is the version,
-- everything after it is the changelog. A text file needs no build step and no
-- content-type negotiation on the host serving it, so the endpoint can be
-- anywhere -- a static host, a paste, an S3 object -- without this file caring.
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

-- NOTE on the callback's first parameter: it is the HTTP STATUS CODE, not an
-- error, despite the name. FiveM reports a transport failure as status 0 or
-- -1, so `err == 200` is the success test and a network failure falls into the
-- same "check failed" branch as a 404. The name is historical and is kept so
-- the diff against older copies of this file stays small -- do not read it as
-- "err means error".
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
--
-- It reads the setting rather than embedding a URL, and that is also why the
-- value must never be restored from an old default: the URL is a string this
-- library can only be told by whoever configured the server.
local function versionCheckUrl()
    local url = Config and Config.VersionCheckUrl
    if type(url) ~= 'string' or url == '' then
        return nil
    end
    return url
end

-- Once per boot, and only if the operator turned it on. Not a poll: the answer
-- cannot usefully change within a session, and re-checking would mean an
-- outbound request on a timer for the life of the server.
CreateThread(function()
    if Config and Config.CheckVersion then
        local url = versionCheckUrl()
        if not url then
            Logging.Warn('Config.CheckVersion is on but Config.VersionCheckUrl is not set; skipping version check.')
            return
        end
        -- Read from fxmanifest, not from a constant in this file, so the value
        -- an operator compares against is the one the resource reports.
        local currentVersion = GetResourceMetadata(GetCurrentResourceName(), 'version', 0)
        checkVersion(url, currentVersion)
    end
end)

-- For a COMPANION resource to check its own version. It does not consult
-- Config.CheckVersion: calling this export is itself the opt-in, so a resource
-- that wants a check on every boot can have one without the server owner
-- enabling it for everything. Nothing is stored and nothing is cached -- the
-- answer is logged and forgotten.
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
