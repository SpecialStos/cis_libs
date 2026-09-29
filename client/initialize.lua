Config = nil
Security = nil
DoorData = nil
CisLibReady = false
CisLibFailed = false

function WaitForLibReady(timeout)
    return CisReadyState.wait(timeout)
end

exports('WaitReady', function(timeout)
    return CisReadyState.wait(timeout)
end)

-- The config the server sent to this client. Already a whitelist: no webhooks,
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
    while Config == nil and GetGameTimer() < deadline do
        Wait(50)
    end

    if Config == nil then
        CisLibFailed = true
        CisReadyState.markFailed('config timeout')
        print('cis_libs: Timed out waiting for server configuration')
        return
    end

    print('cis_libs: Loaded (version ' .. tostring(version) .. ')')
    if not CisLibReady then
        CisLibReady = true
        CisReadyState.markReady()
    end
end)

RegisterNetEvent('cis_libs:client:getData', function(data)
    Config = data.Config
    Security = {
        EventPrefix = data.EventPrefix or 'cis_libs',
    }
    DoorData = data.DoorData or { doors = {}, groups = {} }
    if not CisLibReady and not CisLibFailed then
        CisLibReady = true
        CisReadyState.markReady()
    end
end)

RegisterNetEvent('cis_libs:client:showNotification', function(message, kind)
    if CisFrameworkNotify then
        CisFrameworkNotify(message, kind)
        return
    end
    BeginTextCommandThefeedPost('STRING')
    AddTextComponentSubstringPlayerName(tostring(message))
    EndTextCommandThefeedPostTicker(false, false)
end)
