-- cis_libs' zone set: ONE instance of the engine in client/core/zones.lua, behind
-- the CreateZone / RemoveZone / ZoneContains exports.
--
-- What lives here and nowhere else is the part only a SHARED set needs: who owns
-- which name, refusing a name another resource holds, the owner check on
-- remove, and releasing a stopped resource's zones. The geometry, the passes and
-- the handlers are the engine's -- the same text a consumer's `Cis.zones.*`
-- instance runs in its own VM.

local Engine = CisCore.zones

-- Which name-collisions have already been logged.
local collisionWarned = {}
-- who asked for which zone.
local owned = CisOwned.new()

-- NEVER GIVE UP ON READINESS. initialize.lua marks the library ready at the same
-- 15 s this used to wait, so a waiter could lose that race, get `false`, and
-- return -- ending the zone loop for the session. A failed boot still runs on the
-- built-in defaults, like every other client module.
local function awaitReady()
    while not CisReadyState.wait(15000) do
        if CisReadyState.failed then
            return
        end
    end
end

local engine = Engine.new({
    grid = CisGrid,
    geom = CisZoneGeom,
    -- Looked up per call, so a re-pointed Cis.player.coords is honoured.
    coords = function() return Cis.player.coords() end,
    callable = CisCallable,
    log = function(level, message) CisLog(level, message) end,
    guard = CisLoopGuard.Body,
    timing = CisTiming,
    -- ON DEMAND, as in a consumer: the engine runs its pass thread only while a
    -- zone exists. Two always-on loops woke six times a second with no zone.
    autoDrive = true,
    awaitReady = awaitReady,
    -- [D3] A NAME HELD BY ANOTHER RESOURCE IS REFUSED, NOT REPLACED.
    admit = function(name, held, zoneOwner)
        local holder = held and held.owner
        if holder and holder ~= zoneOwner then
            -- WARN ONCE PER (name, holder, requester) -- H5.
            local key = table.concat({ name, tostring(holder), zoneOwner }, '\29')
            if not collisionWarned[key] then
                collisionWarned[key] = true
                CisLog('warn', ('zone %q is already registered by %s; %s was refused. '
                    .. 'Further refusals for this name will not be logged again.')
                    :format(name, tostring(holder), zoneOwner))
            end
            return false, ('zone %q is already registered by %s; pick a different name')
                :format(name, tostring(holder))
        end
        return true
    end,
    onRegister = function(zone)
        CisOwned.track(owned, zone.owner, 'zone', zone.name)
    end,
    onRemove = function(zone)
        CisOwned.forget(owned, 'zone', zone.name)
    end,
})

function CisZonesCreate(kind, name, a, b, options)
    if Config and Config.Framework and Config.Framework.Zones and Config.Framework.Zones.Enabled == false then
        return false, 'zones disabled by config'
    end
    return engine:create(kind, name, a, b, options, GetInvokingResource() or 'cis_libs')
end

-- ONLY THE OWNER, or cis_libs. A zone name is a string anyone can guess, so any
-- resource could otherwise remove another's zones and fire their onExit.
function CisZonesRemove(name)
    local zone = engine:get(name)
    if not zone then
        return false
    end
    local caller = GetInvokingResource() or 'cis_libs'
    if caller ~= 'cis_libs' and caller ~= zone.owner then
        return false, ('zone %q belongs to %s, not %s'):format(tostring(name), tostring(zone.owner), caller)
    end
    return engine:remove(name)
end

function CisZonesContains(name, point)
    return engine:contains(name, point)
end

-- THE CALLER'S ZONES ONLY, as remove is: this set is shared, and one resource
-- listing another's is a view nothing needs. cis_libs sees every zone.
local function queryOwner()
    local caller = GetInvokingResource() or 'cis_libs'
    if caller == 'cis_libs' then
        return nil
    end
    return caller
end

function CisZonesGetCurrent()
    return engine:insideNames(queryOwner())
end

function CisZonesGetAll()
    return engine:allNames(queryOwner())
end

function CisZonesGetNearby(coords, radius)
    return engine:nearbyNames(coords, radius, queryOwner())
end

-- A CONSUMER THAT STOPS TAKES ITS ZONES WITH IT ().
AddEventHandler('onResourceStop', function(resource)
    -- A forged stop from another client script is ignored (shared/owned.lua).
    if not CisRealStop(resource) then
        return
    end
    if resource == GetCurrentResourceName() then
        return
    end
    local freed = CisOwned.release(owned, resource)
    for i = 1, #freed do
        if freed[i].kind == 'zone' then
            -- Under pcall: `onExitEvent` is a TriggerServerEvent into a resource that
            pcall(engine.remove, engine, freed[i].id)
        end
    end
    if #freed > 0 then
        CisLog('info', ('cis_libs: released %d zone(s) owned by %s'):format(#freed, tostring(resource)))
    end
end)

exports('CreateZone', CisZonesCreate)
exports('RemoveZone', CisZonesRemove)
exports('ZoneContains', CisZonesContains)
exports('GetCurrentZones', CisZonesGetCurrent)
exports('GetAllZones', CisZonesGetAll)
exports('GetNearbyZones', CisZonesGetNearby)

-- Built on request rather than on every pass: the pass used to rebuild and SORT
-- this list for a debug view nobody was reading.
exports('GetZoneDebug', function()
    local debugStats = engine.debugStats
    local names = engine:insideNames()
    debugStats.insideCount = #names
    debugStats.insideNames = names
    return debugStats
end)

-- A zone that outlives the resource that made it is invisible from the server and
CisDiagnostics.Register('client', 'zones', function()
    local out = { total = 0, byOwner = {} }
    for _, zone in pairs(engine.zones) do
        local owner = zone.owner or '<none>'
        out.byOwner[owner] = (out.byOwner[owner] or 0) + 1
        out.total = out.total + 1
    end
    return out
end)
