-- Server-side bootstrap surface: the client's config pull, the readiness gate,
-- the diagnostic summary, and the console command.
--
-- Nothing in this file decides behaviour. It exists so a companion resource
-- and an operator can both find out what this server actually resolved to,
-- without either of them having to read Config.

CisNetOn('cis_libs:server:getData', function(src)
    -- Rebuilt per request rather than cached at load. Config and Security can
    -- be re-pointed at runtime by a consumer, and a cached payload would hand
    -- out the config that was true when the resource started. clientPayload is
    -- a whitelist, not a filter: anything absent from it was never copied, so a
    -- newly added secret in Config is not exposed by not being mentioned.
    local payload = CisConfigUtil.clientPayload(Config, Security, exports['cis_libs']:GetAllDoorData())
    TriggerClientEvent('cis_libs:client:getData', src, payload)
end)

exports('WaitReady', function(timeout)
    return CisReadyState.wait(timeout)
end)

-- Non-secret server config, for companion resources and diagnostics. Carries no
-- webhooks, credentials, database connection details, or the allow-list.
--
-- Every field is a resolved value rather than a copy of the config table, so
-- this cannot drift into leaking a table wholesale. `allowListConfigured` is a
-- boolean derived from the list; the list itself stays server-side, and a
-- consumer that needs the names must ask for them from a resource that is
-- already trusted to hold them.
exports('GetConfigSummary', function()
    -- Blocks until ready, and returns nil rather than a half-populated table if
    -- the wait runs out. A summary that says "framework NONE" because it was
    -- asked too early is worse than no summary: it looks like a real answer.
    if not CisReadyState.wait(15000) then
        return nil
    end
    local framework = Config and Config.Framework or {}
    local database = framework.Database or {}
    return {
        ready = CisReadyState.ready == true,
        -- `framework` is the CONFIGURED type, which detect() may have rewritten
        -- to 'NONE' when the provider could not be loaded. So a server that is
        -- configured for QBCore and got 'NONE' here is reporting that the
        -- detection failed, not that the operator configured nothing.
        framework = framework.Type or 'NONE',
        inventory = framework.Inventory or 'NONE',
        target = (framework.Target and framework.Target.Type) or 'NONE',
        -- `database` is the configured driver and `databaseReady` is whether it
        -- actually initialised. The two disagree on a server whose driver
        -- started late, which is the case this pair exists to make visible.
        database = database.Type or 'NONE',
        -- Reads the GLOBAL Database. If that table is ever re-localised in
        -- server/database.lua this silently reads a global that does not exist
        -- and reports false on every server, including working ones.
        databaseReady = Database and Database.ready == true,
        -- What detection actually concluded, and why. 'framework' and 'database'
        -- above are the CONFIGURED names, which under AUTO have been rewritten
        -- to match reality by the time anything reads them -- so these carry
        -- the provenance instead: which resource, which version, and whether it
        -- was detected or configured. Without them a working server and a
        -- silently-standalone one report the same thing to a consumer.
        frameworkDetail = CisFramework and CisFramework.detected or nil,
        databaseDetail = Database and Database.detected or nil,
        doorlock = Config and Config.Doorlock and Config.Doorlock.Type or 'NONE',
        syncEnabled = not (Config and Config.Sync and Config.Sync.Enabled == false),
        eventPrefix = (Security and Security.EventPrefix) or 'cis_libs',
        callbackTimeout = (Config and Config.CallbackTimeout) or 10000,
        allowListConfigured = type(Security and Security.AuthorizedResources) == 'table'
            and #Security.AuthorizedResources > 0,
    }
end)

-- Prints derived state only: a ready flag, one job count, and one boolean about
-- the client payload. No config values, no webhook URLs, no identifiers. That
-- is the constraint that makes it safe to have at all -- a debug command that
-- dumps config puts every secret on a server owner's screen and into their
-- client log.
--
-- The admin check is belt and braces. The third argument to RegisterCommand is
-- FiveM's restricted flag, and a console that forwards a player src, or a
-- restricted flag that is not what it was assumed to be, must not become a way
-- to run this without permission.
RegisterCommand('cis_debug', function(src)
    if src ~= 0 then
        local Framework = exports['cis_libs']:GetFramework()
        if not Framework.HasPermission(src, 'admin') then
            return
        end
    end
    print(('[cis_libs] ready=%s jobs=%s'):format(
        tostring(CisReadyState.ready),
        json.encode({ police = CisJobCount('police') })
    ))
    -- The payload is rebuilt with empty door data on purpose: this check is
    -- about whether the CONFIG half of the payload leaks, and including real
    -- door data would only add noise to the answer.
    local payload = CisConfigUtil.clientPayload(Config, Security, { doors = {}, groups = {} })
    -- Expected output is `false`. `true` means the whitelist in
    -- shared/config.lua has drifted and something that should stay server-side
    -- is now being sent to every client.
    print('[cis_libs] client payload has secrets: ' .. tostring(CisConfigUtil.containsSecret(payload)))

    -- DETECTION REPORT. This is the command a server owner runs when they
    -- want to know what cis_libs decided is running, and the answer has to be
    -- unambiguous: which framework, which version, whether that was DETECTED or
    -- merely CONFIGURED, and -- when something is wrong -- the reason in words.
    -- 'framework=QBOX' alone does not distinguish a working bridge from one
    -- that fell through to standalone and reports the configured name back.
    local function report(label, d)
        if type(d) ~= 'table' then
            print(('[cis_libs] %s: not detected'):format(label))
            return
        end
        local name = tostring(d.name or 'NONE')
        if d.version then
            name = name .. ' ' .. tostring(d.version)
        end
        if d.resource then
            name = name .. '  (' .. tostring(d.resource) .. ')'
        end
        print(('[cis_libs] %s: %s  [%s] -- %s'):format(label, name,
            tostring(d.how or 'unknown'), tostring(d.reason or '')))
    end
    -- RAW STATE of every framework and driver this library knows about. When
    -- detection says NONE, the operator's next question is always 'is my
    -- framework even started?' -- and answering it here beats sending them
    -- to the txAdmin resources page to work it out.
    local known = {}
    if CisDetect then
        for _, k in ipairs(CisDetect.FRAMEWORKS) do known[#known + 1] = k.resource end
        for _, k in ipairs(CisDetect.DATABASES) do known[#known + 1] = k.resource end
    end
    for _, res in ipairs(known) do
        print(('[cis_libs]   %s: %s'):format(res, tostring(GetResourceState(res))))
    end

    report('framework', CisFramework and CisFramework.detected)
    report('database ', Database and Database.detected)
    print(('[cis_libs] framework bridge loaded: %s   database ready: %s'):format(
        tostring(CisFramework and CisFramework.IsLoaded and CisFramework.IsLoaded()),
        tostring(Database and Database.ready == true)))
end, true)
