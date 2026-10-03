-- Capability forwards, client half. See server/proxy.lua for the reasoning;
-- this file is the same idea on the other side of the wire.
--
-- The asymmetry that matters here: on the client almost nothing is a command.
-- The server owns the doors, the inventory and the framework state, so what
-- crosses is either a READ of a snapshot the server pushed, or a REQUEST the
-- server re-validates. Nothing in this file is trusted, because nothing in this
-- file can be.

local warned = {}

local function warnOnce(slot, method, reason)
    local key = tostring(slot) .. '.' .. tostring(method)
    if warned[key] then
        return
    end
    warned[key] = true
    Logging.Warn(('cis_libs: %s.%s unavailable -- %s'):format(tostring(slot), tostring(method), tostring(reason)))
end

-- `onFail` is this slot's failure shape, and a function when the failure needs
-- more than one value: a count answers 0, a mutation answers false, a read
-- answers nil.
--
-- On success EVERY value the provider produced is returned. Several slots
-- answer in pairs -- a transaction is `ok, reason` and a zone create is
-- `ok, reason` -- and taking only the first silently swallowed the half of the
-- answer that explains the failure, which is the half a caller needs to decide
-- whether to retry.
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

-- Registered from both realms, so a resource that speaks to cis_libs never has
-- to know which side it is on.
--
-- NOT ALLOW-LIST GATED HERE, AND THAT IS A DECISION, NOT AN OMISSION (A3).
--
-- The server half refuses a capability from a resource that is not on
-- `Security.AuthorizedResources`. This half has no equivalent gate, and it is
-- worth being precise about why, because the asymmetry reads like a bug.
--
-- THE SERVER'S ALLOW-LIST IS NOT SENT TO CLIENTS, on purpose.
-- `CisConfigUtil.clientPayload` ships the event prefix and nothing else from
-- Security -- explicitly "not the allow-list, not the kick handler". Sending it
-- would hand every connected client the complete list of resources this server
-- trusts, which is an inventory of the install for anything that wants one.
--
-- AND A CLIENT-SIDE GATE WOULD NOT BUY ANYTHING AGAINST THE THREAT ANYWAY. The
-- threat is a cheat executor, which runs inside the client and can already call
-- `TriggerClientEvent` with any payload this library sends, and draw whatever
-- it likes over the top. Refusing one export to code that can skip the library
-- entirely is a lock on a door that is not there. The server half's gate is
-- different in kind: there the allow-list is checked before a value reaches the
-- server, which is a boundary the client genuinely cannot cross.
--
-- WHAT IS ACTUALLY PROTECTED HERE IS FIRST-COMES. Two resources registering the
-- same client slot is the realistic failure -- a bridge that registers twice on
-- a partial restart, or two products both believing they own the inventory --
-- and `CisRegistry.register` refuses the second and names the holder. That is
-- the same guard the server half relies on for the non-adversarial case.
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

-- See the server half: a stopped resource's exports are gone, so its slots are.
AddEventHandler('onResourceStop', function(resource)
    for _, slot in ipairs(CisRegistry.releaseOwner(resource)) do
        warned = {}
        Logging.Warn(('cis_libs: capability %q released: %s stopped'):format(slot, resource))
    end
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

-- No leading src. The client service is `Count(item)` / `Has(item, amount)`: a
-- client has no player to name, so a placeholder nil would arrive as the item.
exports('InventoryCount', function(item)
    return forward('inventory', 0, 'count', item)
end)

exports('InventoryHas', function(item, amount)
    return forward('inventory', false, 'has', item, amount)
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

-- ============================================================ GetDiagnostics
--
-- The client half of the same contract. Both realms answer the same shape so
-- one test can compare before and after on either, and so a snapshot taken on
-- one realm and the other can be lined up.
--
-- The interesting client counts are the ones that must return to baseline when
-- a consumer stops: zones by owner, spawned sync entities, targets. A zone that
-- outlives the resource that made it is invisible from the server and obvious
-- here.
---
--- @return table counts and counters, never player data
exports('GetDiagnostics', function()
    return CisDiagnostics.Collect('client')
end)
