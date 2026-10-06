-- Boot sequence and config intake.

-- Sibling chunks still load after shared/identity.lua errors, so the client
-- half of the license check lives here too. StopResource is server-only.
if type(GetCurrentResourceName) == 'function' then
    local ok, name = pcall(GetCurrentResourceName)
    if ok and type(name) == 'string' and name ~= 'cis_libs' then
        local err = ('[cis_libs] FATAL: this resource is %q. The Cisoko Community Source & Identity License requires the folder name cis_libs. Rename the folder. Rebranding is not permitted.'):format(name)
        print('^1' .. err .. '^7')
        error(err, 0)
    end
end

CisLibReady = false
CisLibFailed = false

-- Set only by the server's payload, and never by the built-in defaults.
local payloadReceived = false

function WaitForLibReady(timeout)
    return CisReadyState.wait(timeout)
end

exports('WaitReady', function(timeout)
    return CisReadyState.wait(timeout)
end)

-- The config this client was actually given.
exports('GetClientConfig', function()
    if not CisReadyState.wait(15000) then
        return nil
    end
    return Config
end)

exports('IsReady', function()
    return CisReadyState.ready == true
end)

CreateThread(function()
    local version = GetResourceMetadata(GetCurrentResourceName(), 'version', 0)
    print('cis_libs: Loading (version ' .. tostring(version) .. ')')
    TriggerServerEvent('cis_libs:server:getData')

    local deadline = GetGameTimer() + 15000
    while not payloadReceived and GetGameTimer() < deadline do
        Wait(50)
    end

    if not payloadReceived then
        -- NOT a failure. The built-in defaults are a working floor, so a client that
        print('cis_libs: No configuration arrived within 15s; running on built-in defaults')
        if not CisLibReady then
            CisLibReady = true
            CisReadyState.markReady()
        end
        return
    end

    print('cis_libs: Loaded (version ' .. tostring(version) .. ')')
    if not CisLibReady then
        CisLibReady = true
        CisReadyState.markReady()
    end
end)

RegisterNetEvent('cis_libs:client:getData', function(data)
    data = data or {}
    payloadReceived = true
    -- Merged, not replaced. The payload is a whitelist and therefore necessarily
    Config = CisDefaults.merge(Config or CisDefaults.config(), CisDefaults.sanitize(data.Config))
    Security = {
        -- Only the prefix crosses to the client, not the allow-list or the kick
        EventPrefix = data.EventPrefix or (Security and Security.EventPrefix) or 'cis_libs',
    }
    -- Either the thread above or this event marks readiness, whichever gets here first,
    if not CisLibReady and not CisLibFailed then
        CisLibReady = true
        CisReadyState.markReady()
    end
end)

RegisterNetEvent('cis_libs:client:showNotification', function(message, kind)
    -- Routed through the framework capability when one is registered, and to the native
    if CisRegistry.has('framework') then
        local ok = CisRegistry.call('framework', 'ShowNotification', message, kind)
        if ok then
            return
        end
    end
    BeginTextCommandThefeedPost('STRING')
    AddTextComponentSubstringPlayerName(tostring(message))
    EndTextCommandThefeedPostTicker(false, false)
end)

-- The client half of the server files export above, and for the same reason: a consumer
exports('ModuleInfo', function(name, opts)
    return Cis.moduleInfo(name, opts)
end)

-- Which of the fifteen globals exist on THIS realm.
CisDiagnostics.Register('client', 'modules', function()
    return Cis.moduleProbe()
end)
