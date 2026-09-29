CisNetOn('cis_libs:server:getData', function(src)
    local payload = CisConfigUtil.clientPayload(Config, Security, exports['cis_libs']:GetAllDoorData())
    TriggerClientEvent('cis_libs:client:getData', src, payload)
end)

exports('WaitReady', function(timeout)
    return CisReadyState.wait(timeout)
end)

-- Non-secret server config, for companion resources and diagnostics. Carries no
-- webhooks, credentials, database connection details, or the allow-list.
exports('GetConfigSummary', function()
    if not CisReadyState.wait(15000) then
        return nil
    end
    local framework = Config and Config.Framework or {}
    local database = framework.Database or {}
    return {
        ready = CisReadyState.ready == true,
        framework = framework.Type or 'NONE',
        inventory = framework.Inventory or 'NONE',
        target = (framework.Target and framework.Target.Type) or 'NONE',
        database = database.Type or 'NONE',
        databaseReady = Database and Database.ready == true,
        doorlock = Config and Config.Doorlock and Config.Doorlock.Type or 'NONE',
        syncEnabled = not (Config and Config.Sync and Config.Sync.Enabled == false),
        eventPrefix = (Security and Security.EventPrefix) or 'cis_libs',
        callbackTimeout = (Config and Config.CallbackTimeout) or 10000,
        allowListConfigured = type(Security and Security.AuthorizedResources) == 'table'
            and #Security.AuthorizedResources > 0,
    }
end)

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
    local payload = CisConfigUtil.clientPayload(Config, Security, { doors = {}, groups = {} })
    print('[cis_libs] client payload has secrets: ' .. tostring(CisConfigUtil.containsSecret(payload)))
end, true)
