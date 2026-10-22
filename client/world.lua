-- cis_libs' world queries: ONE instance of the engine in client/core/world.lua,
-- behind the Closest* / Nearby* exports. A consumer's `Cis.world.*` runs the
-- same text in its own VM.

local engine = CisCore.world.new({
    callable = CisCallable,
    onFilterError = function()
        if CisDiagnostics and CisDiagnostics.Inc then
            CisDiagnostics.Inc('worldFilterErrors', 1)
        end
    end,
})

function CisWorldClosest(kind, coords, maxDistance, filter, opts)
    return engine:closest(kind, coords, maxDistance, filter, opts)
end

-- NEARBY ANSWERS A LIST, ALWAYS, and never nil.
function CisWorldNearby(kind, coords, maxDistance, filter, opts)
    return engine:nearby(kind, coords, maxDistance, filter, opts)
end

-- CLOSEST IS SINGULAR AND NEARBY IS PLURAL, and the plurality is not decoration:
exports('ClosestPed', function(coords, maxDistance, filter, opts)
    return CisWorldClosest('ped', coords, maxDistance, filter, opts)
end)
exports('ClosestVehicle', function(coords, maxDistance, filter, opts)
    return CisWorldClosest('vehicle', coords, maxDistance, filter, opts)
end)
exports('ClosestObject', function(coords, maxDistance, filter, opts)
    return CisWorldClosest('object', coords, maxDistance, filter, opts)
end)
exports('NearbyPeds', function(coords, maxDistance, filter, opts)
    return CisWorldNearby('ped', coords, maxDistance, filter, opts)
end)
exports('NearbyVehicles', function(coords, maxDistance, filter, opts)
    return CisWorldNearby('vehicle', coords, maxDistance, filter, opts)
end)
exports('NearbyObjects', function(coords, maxDistance, filter, opts)
    return CisWorldNearby('object', coords, maxDistance, filter, opts)
end)

-- The player pair, written out rather than in the loop above because their arity
exports('ClosestPlayer', function(coords, maxDistance, filter, opts)
    return CisWorldClosest('player', coords, maxDistance, filter, opts)
end)
exports('NearbyPlayers', function(coords, maxDistance, filter, opts)
    return CisWorldNearby('player', coords, maxDistance, filter, opts)
end)

CisDiagnostics.Register('both', 'world', function()
    -- COUNTS ONLY, and deliberately not per-kind: a pool walk on the caller's behalf is
    local out = { filterErrors = 0 }
    if CisDiagnostics and CisDiagnostics.Count then
        out.filterErrors = CisDiagnostics.Count('worldFilterErrors') or 0
    end
    return out
end)
