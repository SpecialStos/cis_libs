-- Capability forwards, client half. See server/proxy.lua for the reasoning;
-- this file is the same idea on the other side of the wire.
--
-- The asymmetry that matters here: on the client almost nothing is a command.
-- The server owns the doors, the inventory and the framework state, so what
-- crosses is either a READ of a snapshot the server pushed, or a REQUEST the
-- server re-validates. Nothing in this file is trusted, because nothing in this
-- file can be.

local warned = {}

local function warnOnce(slot, reason)
    if warned[slot] then
        return
    end
    warned[slot] = true
    Logging.Warn(('cis_libs: no provider for %q -- %s'):format(tostring(slot), tostring(reason)))
end

-- `onFail` is this slot's failure shape, and a function when the failure needs
-- more than one value: a count answers 0, a mutation answers false, a read
-- answers nil.
local function forward(slot, onFail, ...)
    local ok, reason = CisRegistry.call(slot, ...)
    if not ok then
        warnOnce(slot, reason)
        if type(onFail) == 'function' then
            return onFail()
        end
        if onFail ~= nil then
            return onFail
        end
        return nil, reason
    end
    return reason
end

-- Registered from both realms, so a resource that speaks to cis_libs never has
-- to know which side it is on.
exports('RegisterCapability', function(slot, provider)
    local ok, reason = CisRegistry.register(slot, provider)
    if not ok then
        Logging.Warn(('cis_libs: capability %q refused: %s'):format(tostring(slot), tostring(reason)))
        return false, reason
    end
    return true
end)

exports('GetCapabilities', function()
    return CisRegistry.snapshot()
end)

-- ===========================================================================
--  DETECTION
--
--  The client probes rather than being told, and that is the correction this
--  half needed: the server used to decide the framework and the client used to
--  re-derive it with its own private decision tree, and the two trees drifted.
--  The client defaulted to NONE where the server defaulted to AUTO, the client
--  had no custom-adapter support, and the client branched on the CONFIGURED
--  name for ESX-LEGACY where the server probed. Two implementations of one
--  rule, with no test over this one at all, is how a divergence survives for
--  years.
--
--  One table, one order, one decision. The client now asks the same question
--  the server asked and gets the same answer.
-- ===========================================================================

local function clientIsStarted(name)
    return GetResourceState(name) == 'started'
end

local function clientVersion(name)
    local ok, version = pcall(GetResourceMetadata, name, 'version', 0)
    return ok and version or nil
end

-- The same honest existence test the server uses. A client that cannot call an
-- export is not running the framework that export belongs to.
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

-- ===========================================================================
--  FRAMEWORK  ->  cis_core
--
--  `GetFramework` is registered in BOTH realms under the same name with the
--  same zero-argument signature, because it is the same question asked from
--  either side: what am I running against, and is it there yet. A consumer
--  should not have to branch on IsDuplicityVersion() to ask it.
-- ===========================================================================

exports('GetFramework', function()
    if not CisReadyState.wait(15000) then
        return nil
    end
    return CisRegistry.resolve('framework')
end)

-- ===========================================================================
--  NOTIFICATIONS  ->  cis_core
--
--  Note the two-argument shape. The server's Notify is (src, message, kind);
--  this one is (message, kind) because a client cannot address another client.
--  Both are registered under the same name, which is correct -- they are the
--  same operation seen from the side that can see it -- and the reason init.lua
--  branches on realm before choosing which to call.
-- ===========================================================================

exports('Notify', function(message, kind)
    if CisRegistry.has('framework') then
        return forward('framework', nil, 'ShowNotification', message, kind)
    end
    -- No framework: the native feed. A server with no framework should still be
    -- able to tell a player something.
    BeginTextCommandThefeedPost('STRING')
    AddTextComponentSubstringPlayerName(tostring(message))
    EndTextCommandThefeedPostTicker(false, false)
end)

-- ===========================================================================
--  INVENTORY  ->  cis_core
--
--  A client count is a HINT and always was. It is a snapshot the server pushed,
--  and it can be up to one inventory-change event stale. Never gate a
--  server-side action on it -- the server re-checks, and a player who was
--  holding a gun at the moment of the check is holding it regardless of what
--  their client last reported.
-- ===========================================================================

exports('InventoryCount', function(item)
    return forward('inventory', 0, 'count', nil, item)
end)

exports('InventoryHas', function(item, amount)
    return forward('inventory', false, 'has', nil, item, amount)
end)

-- ===========================================================================
--  DOORS  ->  cis_keys
-- ===========================================================================

exports('AddDoorToSystem', function(data)
    return forward('doorsClient', false, 'add', data)
end)

exports('AddDoorGroup', function(data)
    return forward('doorsClient', false, 'addGroup', data)
end)

-- Ask the server for a fresh inventory snapshot. The client is a HINT here and
-- always was; this is how it is refreshed, and a caller should never gate a
-- server-side action on what it last returned.
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

-- The two REQUESTS rather than commands. There is deliberately no doorlock code
-- here: the client does not decide, and a client that could set a lock state
-- locally would be a client that can open a server's doors.
exports('RequestLockDoors', function(identifier)
    if not CisReadyState.wait(15000) then
        return nil
    end
    TriggerServerEvent((Security and Security.EventPrefix or 'cis_libs') .. ':doorlock:requestState',
        identifier, true)
end)

exports('RequestUnlockDoors', function(identifier)
    if not CisReadyState.wait(15000) then
        return nil
    end
    TriggerServerEvent((Security and Security.EventPrefix or 'cis_libs') .. ':doorlock:requestState',
        identifier, false)
end)
