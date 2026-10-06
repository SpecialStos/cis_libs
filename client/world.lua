-- What is in the world, and how far away it is.

local POOLS = {
    ped = 'CPoolablePed',
    vehicle = 'CPoolableVehicle',
    object = 'CPoolableObject',
}

-- Squared distance, because every comparison here is `d < best` and a square root per
local function dist2(ax, ay, az, bx, by, bz)
    local dx, dy, dz = ax - bx, ay - by, az - bz
    return dx * dx + dy * dy + dz * dz
end

-- Whether a handle is one this library should even consider.
local function usable(entity)
    if not entity or entity == 0 then return false end
    local exists = DoesEntityExist
    return type(exists) == 'function' and exists(entity)
end

-- Run the caller's filter, and count what it did.
local function passes(filter, entity, coords)
    if type(filter) ~= 'function' then return true end
    local ok, keep = pcall(filter, entity, coords)
    if not ok then
        if CisDiagnostics and CisDiagnostics.Inc then
            CisDiagnostics.Inc('worldFilterErrors', 1)
        end
        return false
    end
    return keep == true
end

-- THE WALK, shared by closest and nearby.
local function eachOfKind(kind, coords, maxDistance, filter, wantsAll, out)
    local fns = {}
    if kind == 'player' then
        -- Players are not a pool. A client gets the active indices and their peds; a
        local indices
        if IsDuplicityVersion() then
            indices = GetPlayers()
        else
            -- GetActivePlayers RETURNS A ZERO-INDEXED TABLE, and `#` on one is not a
            local active = GetActivePlayers()
            indices = {}
            for _, idx in pairs(active) do
                if type(idx) == 'number' then indices[#indices + 1] = idx end
            end
        end
        for i = 1, #indices do
            local ped = GetPlayerPed(indices[i])
            if usable(ped) then
                fns[#fns + 1] = { handle = ped, player = indices[i] }
            end
        end
    else
        local poolName = POOLS[kind]
        if not poolName then return nil, ('unknown kind %q; valid kinds are object, ped, player and vehicle'):format(tostring(kind)) end
        local pool = GetGamePool(poolName)
        for i = 1, #pool do
            local handle = pool[i]
            if usable(handle) then fns[#fns + 1] = { handle = handle } end
        end
    end

    local want2 = (type(maxDistance) == 'number' and maxDistance > 0) and (maxDistance * maxDistance) or nil
    for _, entry in ipairs(fns) do
        local c = GetEntityCoords(entry.handle)
        if c and c.x ~= nil then
            local d2 = dist2(coords.x, coords.y, coords.z, c.x, c.y, c.z)
            if (not want2 or d2 <= want2) and passes(filter, entry.handle, c) then
                if wantsAll then
                    out[#out + 1] = { entity = entry.handle, coords = c, distance = math.sqrt(d2), player = entry.player }
                elseif not out.best or d2 < out.best2 then
                    out.best = entry.handle
                    out.bestCoords = c
                    out.best2 = d2
                    out.bestPlayer = entry.player
                end
            end
        end
    end
    return true
end

-- Shared argument checking, so all six entry points refuse the same way.
local function checkCoords(coords, fn)
    if coords == nil then return false, (fn .. ': coords arrived as nil') end
    if type(coords) ~= 'vector3' and type(coords) ~= 'vector4' and type(coords) ~= 'table' then
        return false, (fn .. ': coords arrived as %s'):format(type(coords))
    end
    if type(coords.x) ~= 'number' or type(coords.y) ~= 'number' or type(coords.z) ~= 'number' then
        return false, (fn .. ': coords has no numeric x/y/z')
    end
    return true
end

function CisWorldClosest(kind, coords, maxDistance, filter)
    local ok, why = checkCoords(coords, 'closest' .. kind)
    if not ok then return false, why end
    local out = {}
    local walked, walkWhy = eachOfKind(kind, coords, maxDistance, filter, false, out)
    if walked == nil then return false, walkWhy end
    if not out.best then
        return false, ('no %s within %s'):format(tostring(kind), tostring(maxDistance or 'any distance'))
    end
    -- TWO SLOTS for a player, THREE for everything else, and the difference is
    if kind == 'player' then
        return out.best, out.bestCoords, out.bestPlayer
    end
    return out.best, out.bestCoords
end

-- NEARBY ANSWERS A LIST, ALWAYS, and never nil.
function CisWorldNearby(kind, coords, maxDistance, filter)
    local ok, why = checkCoords(coords, 'nearby' .. kind)
    if not ok then return false, why end
    local out = {}
    local walked, walkWhy = eachOfKind(kind, coords, maxDistance, filter, true, out)
    if walked == nil then return false, walkWhy end
    table.sort(out, function(a, b) return a.distance < b.distance end)
    return out
end

-- CLOSEST IS SINGULAR AND NEARBY IS PLURAL, and the plurality is not decoration:
exports('ClosestPed', function(coords, maxDistance, filter)
    return CisWorldClosest('ped', coords, maxDistance, filter)
end)
exports('ClosestVehicle', function(coords, maxDistance, filter)
    return CisWorldClosest('vehicle', coords, maxDistance, filter)
end)
exports('ClosestObject', function(coords, maxDistance, filter)
    return CisWorldClosest('object', coords, maxDistance, filter)
end)
exports('NearbyPeds', function(coords, maxDistance, filter)
    return CisWorldNearby('ped', coords, maxDistance, filter)
end)
exports('NearbyVehicles', function(coords, maxDistance, filter)
    return CisWorldNearby('vehicle', coords, maxDistance, filter)
end)
exports('NearbyObjects', function(coords, maxDistance, filter)
    return CisWorldNearby('object', coords, maxDistance, filter)
end)

-- The player pair, written out rather than in the loop above because their arity
exports('ClosestPlayer', function(coords, maxDistance, filter)
    return CisWorldClosest('player', coords, maxDistance, filter)
end)
exports('NearbyPlayers', function(coords, maxDistance, filter)
    return CisWorldNearby('player', coords, maxDistance, filter)
end)

CisDiagnostics.Register('both', 'world', function()
    -- COUNTS ONLY, and deliberately not per-kind: a pool walk on the caller's behalf is
    local out = { filterErrors = 0 }
    if CisDiagnostics and CisDiagnostics.Count then
        out.filterErrors = CisDiagnostics.Count('worldFilterErrors') or 0
    end
    return out
end)
