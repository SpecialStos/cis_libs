-- Capability forwards, client half. See server/proxy.lua for the reasoning; this file
-- is the same idea on the other side of the wire.

local warned = {}

local function warnOnce(slot, method, reason)
    local key = tostring(slot) .. '.' .. tostring(method)
    if warned[key] then
        return
    end
    warned[key] = true
    Logging.Warn(('cis_libs: %s.%s unavailable -- %s'):format(tostring(slot), tostring(method), tostring(reason)))
end

-- `onFail` is this slot's failure shape, and a function when the failure needs more
local function forward(slot, onFail, ...)
    local results = table.pack(CisRegistry.call(slot, ...))
    if not results[1] then
        warnOnce(slot, (...), results[2])
        if type(onFail) == 'function' then
            return onFail()
        end
        if onFail ~= nil then
            return onFail
        end
        return nil, results[2]
    end
    return table.unpack(results, 2, results.n)
end

-- Registered from both realms, so a resource that speaks to cis_libs never has to know
exports('RegisterCapability', function(slot, provider, contract)
    local ok, reason = CisRegistry.register(slot, provider, contract)
    if not ok then
        Logging.Warn(('cis_libs: capability %q refused: %s'):format(tostring(slot), tostring(reason)))
        return false, reason
    end
    return true
end)

exports('GetCapabilities', function()
    return CisRegistry.snapshot()
end)

-- See the server half: a stopped resource's exports are gone, so its slots are.
AddEventHandler('onResourceStop', function(resource)
    for _, slot in ipairs(CisRegistry.releaseOwner(resource)) do
        warned = {}
        Logging.Warn(('cis_libs: capability %q released: %s stopped'):format(slot, resource))
    end
end)

-- DETECTION

local function clientIsStarted(name)
    return GetResourceState(name) == 'started'
end

local function clientVersion(name)
    local ok, version = pcall(GetResourceMetadata, name, 'version', 0)
    return ok and version or nil
end

-- The same honest existence test the server uses.
local function clientProbe(name, exportName)
    if not exportName then
        return false
    end
    local ok, fn = pcall(function()
        return exports[name][exportName]
    end)
    return ok and fn ~= nil
end

exports('DetectFramework', function(configured, custom)
    return CisDetect.framework(configured, custom, clientIsStarted, clientVersion, clientProbe)
end)

exports('DetectDatabase', function(configured)
    return CisDetect.database(configured, clientIsStarted, clientVersion)
end)

exports('GetKnownTargets', function()
    return {
        frameworks = CisDetect and CisDetect.FRAMEWORKS or {},
        databases = CisDetect and CisDetect.DATABASES or {},
    }
end)

-- FRAMEWORK -> cis_core

-- NOTIFICATIONS -> cis_core

exports('Notify', function(message, kind)
    if CisRegistry.has('framework') then
        return forward('framework', nil, 'ShowNotification', message, kind)
    end
    -- No framework: the native feed.
    BeginTextCommandThefeedPost('STRING')
    AddTextComponentSubstringPlayerName(tostring(message))
    EndTextCommandThefeedPostTicker(false, false)
end)

-- INVENTORY -> cis_core

-- No leading src. The client service is `Count(item)` / `Has(item, amount)`: a client
exports('InventoryCount', function(item)
    return forward('inventory', 0, 'count', item)
end)

exports('InventoryHas', function(item, amount)
    return forward('inventory', false, 'has', item, amount)
end)

-- DOORS -> cis_keys

exports('AddDoorToSystem', function(data)
    return forward('doorsClient', false, 'add', data)
end)

exports('AddDoorGroup', function(data)
    return forward('doorsClient', false, 'addGroup', data)
end)

-- Ask the server for a fresh inventory snapshot.
exports('RequestInventorySync', function()
    if not CisReadyState.wait(15000) then
        return false
    end
    TriggerServerEvent('cis_libs:server:inventorySync')
    return true
end)

exports('GetClosestDoor', function()
    return forward('doorsClient', nil, 'closest')
end)

exports('GetDoorState', function(doorId)
    return forward('doorsClient', nil, 'state', doorId)
end)

-- The two REQUESTS rather than commands.
local function requestDoorState(identifier, lock)
    if not CisReadyState.wait(15000) then
        return nil
    end
    if CisRegistry.has('doorsClient') then
        return forward('doorsClient', nil, 'RequestState', identifier, lock)
    end
    return TriggerServerEvent((Security and Security.EventPrefix or 'cis_libs')
        .. ':doorlock:requestState', identifier, lock)
end

exports('RequestLockDoors', function(identifier)
    return requestDoorState(identifier, true)
end)

exports('RequestUnlockDoors', function(identifier)
    return requestDoorState(identifier, false)
end)

-- The client half of the same contract.
--- @return table counts and counters, never player data
exports('GetDiagnostics', function(opts)
    return CisDiagnostics.Collect('client', opts)
end)
