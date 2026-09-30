-- Boot sequence and config intake.
--
-- The server pushes a whitelisted Config; nothing is read from disk on the
-- client. That handshake is what everything else waits on, which is why the
-- whole file is one thread: until `Config` lands there is no interval and no
-- zone setting, and a module that started earlier would be reading them as nil
-- forever.
--
-- `Config` and `Security` are NOT nil'd here. shared/config.lua has already
-- installed the built-in defaults in this realm, and clearing them would
-- reintroduce exactly the bug this boot sequence exists to prevent: a client
-- module that starts before the payload lands reads nil, and nil read early is
-- nil cached forever. The defaults are a working floor -- a client that never
-- gets a payload at all is degraded, not broken.
--
-- The 15s deadline here is the same number Cis.wait() publishes to consumers,
-- so a consumer waiting on Cis.ready and this thread waiting on the server give
-- up together instead of one outliving the other.

CisLibReady = false
CisLibFailed = false

-- Set only by the server's payload, and never by the built-in defaults.
--
-- `Config` is already populated in this realm before this file runs, because
-- shared/config.lua installs the defaults in both realms. Waiting on "Config
-- exists" would therefore be satisfied immediately and would mean nothing. What
-- the thread below is actually waiting for is the ANSWER from the server, and
-- that is a separate fact.
local payloadReceived = false

function WaitForLibReady(timeout)
    return CisReadyState.wait(timeout)
end

exports('WaitReady', function(timeout)
    return CisReadyState.wait(timeout)
end)

-- The config this client was actually given. Already a whitelist: no webhooks,
-- no database settings, no allow-list. Lets a companion resource inspect what
-- this client was told without duplicating the event.
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
        -- NOT a failure. The built-in defaults are a working floor, so a client
        -- that never hears back is degraded rather than broken, and saying so
        -- plainly is better than a 15-second stall followed by a library that
        -- refuses to serve zones. The old code marked the whole client failed
        -- here, which meant a server with a slow or absent payload took every
        -- Cis.* call on that client down with it.
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
    -- Merged, not replaced. The payload is a whitelist and therefore
    -- necessarily partial: overwriting wholesale would drop every key it does
    -- not carry and quietly reset it to nil, which is how a running server ends
    -- up with a nil interval halfway through a session.
    Config = CisDefaults.merge(Config or CisDefaults.config(), CisDefaults.sanitize(data.Config))
    Security = {
        -- Only the prefix crosses to the client, not the allow-list or the kick
        -- handler.
        EventPrefix = data.EventPrefix or (Security and Security.EventPrefix) or 'cis_libs',
    }
    -- Either the thread above or this event marks readiness, whichever gets here
    -- first, and only once: a late duplicate of the config must not re-open a
    -- gate that has already released its waiters.
    if not CisLibReady and not CisLibFailed then
        CisLibReady = true
        CisReadyState.markReady()
    end
end)

RegisterNetEvent('cis_libs:client:showNotification', function(message, kind)
    -- Routed through the framework capability when one is registered, and to the
    -- native feed when it is not. The fallback is not decoration: a server
    -- running standalone has no framework, and without it a notification sent
    -- by a product would simply never appear.
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
