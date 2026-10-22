-- cis_libs' vehicle surface. The property capture and apply are the engine in
-- client/core/vehicle.lua -- the same text a consumer's `Cis.vehicle.*` runs in
-- its own VM. What stays here is what reads cis_libs' own player cache.

local Vehicle = CisCore.vehicle

-- FIELD-COMPATIBLE WITH ox_lib's getVehicleProperties: see client/core/vehicle.lua.
function GetVehicleProperties(vehicle)
    return Vehicle.getProperties(vehicle)
end

-- Applies what `props` names and nothing else.
-- @return true, or false plus a reason. Nothing is written on a refusal.
function SetVehicleProperties(vehicle, props, fixVehicle)
    return Vehicle.setProperties(vehicle, props, fixVehicle)
end

-- The cache first, and only the cache when it holds an answer. This is on the
-- door interaction path, which runs every frame while a door is in range, so
-- the fallback seat scan -- up to a dozen native calls -- must not be the
-- normal case.
function GetPlayerVehicleSeat()
    if CisCache and CisCache.vehicle ~= 0 and CisCache.seat ~= nil then
        return CisCache.seat
    end
    local ped = (CisCache and CisCache.ped ~= 0 and CisCache.ped) or PlayerPedId()
    local vehicle = GetVehiclePedIsIn(ped, false)
    if vehicle == 0 then
        return nil
    end
    if GetPedInVehicleSeat(vehicle, -1) == ped then
        return -1
    end
    local maxPassengers = GetVehicleMaxNumberOfPassengers(vehicle)
    for i = 0, maxPassengers - 1 do
        if GetPedInVehicleSeat(vehicle, i) == ped then
            return i
        end
    end
    return nil
end

local CLOSEST_RANGE = 5.0
-- START_SHAPE_TEST_LOS_PROBE flags: 2 = vehicles.
local PROBE_VEHICLES = 2
-- How long the forward probe is polled for before the pool answers instead.
local PROBE_WAIT_MS = 100

-- The vehicle under the forward probe, or nil. ASYNCHRONOUS: the synchronous
-- probe blocked the game thread. A result needs a later frame, so it is polled
-- only by a caller that can yield; one that cannot gets the pool's answer and no
-- probe is started, so no handle is left unread.
local function probeAhead(ped, from)
    if not coroutine.isyieldable() then
        return nil
    end
    local to = GetOffsetFromEntityInWorldCoords(ped, 0.0, CLOSEST_RANGE, 0.0)
    if not to or to.x == nil then
        return nil
    end
    -- SIX FLOATS, not two vectors: the probe takes x1, y1, z1, x2, y2, z2.
    local handle = StartShapeTestLosProbe(
        from.x, from.y, from.z, to.x, to.y, to.z, PROBE_VEHICLES, ped, 7)
    if not handle or handle == 0 then
        return nil
    end
    local deadline = GetGameTimer() + PROBE_WAIT_MS
    while true do
        local status, hit, _, _, entityHit = GetShapeTestResult(handle)
        if status == 2 then
            -- `hit` is a BOOL out-parameter; CfxLua hands those back as 0/1. Both
            -- spellings are accepted so a runtime that answers a boolean agrees.
            if (hit == true or hit == 1) and entityHit and entityHit ~= 0
                and GetEntityType(entityHit) == 2 then
                return entityHit
            end
            return nil
        end
        -- 0 is a handle the engine no longer knows; anything but 1 is not pending.
        if status ~= 1 or GetGameTimer() >= deadline then
            return nil
        end
        Wait(0)
    end
end

-- The vehicle the player means: the one under a 5 m forward probe if there is
-- one, otherwise the nearest within 5 m from the vehicle pool. 0 when there is
-- none, the game's own "no entity".
--
-- A CIS-PREFIXED GLOBAL. This used to be a global named GetClosestVehicle, which
-- REPLACED the native of that name for every file in cis_libs -- and its own
-- fallback then called the native, which misses most parked and player
-- vehicles anyway. The export keeps its published name.
function CisGetClosestVehicle()
    local ped = (CisCache and CisCache.ped ~= 0 and CisCache.ped) or PlayerPedId()
    local from = GetEntityCoords(ped)
    if not from or from.x == nil then
        return 0
    end
    local ahead = probeAhead(ped, from)
    if ahead then
        return ahead
    end
    local best, best2 = 0, CLOSEST_RANGE * CLOSEST_RANGE
    local pool = GetGamePool('CVehicle')
    for i = 1, #pool do
        local vehicle = pool[i]
        local c = GetEntityCoords(vehicle)
        if c and c.x ~= nil then
            local dx, dy, dz = c.x - from.x, c.y - from.y, c.z - from.z
            local d2 = dx * dx + dy * dy + dz * dz
            if d2 <= best2 then
                best, best2 = vehicle, d2
            end
        end
    end
    return best
end

exports('GetVehicleProperties', GetVehicleProperties)
exports('SetVehicleProperties', SetVehicleProperties)
exports('GetPlayerVehicleSeat', GetPlayerVehicleSeat)
exports('GetClosestVehicle', CisGetClosestVehicle)
