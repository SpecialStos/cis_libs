-- cis_libs' point set: ONE instance of the engine in client/core/points.lua,
-- behind the CreatePoint / RemovePoint / GetClosestPoint exports.
--
-- Owner tracking, the owner check on remove and the stop sweep live here; the
-- radius, the hysteresis, the pass and the handlers are the engine's -- the same
-- text a consumer's `Cis.points.*` instance runs in its own VM.

local Engine = CisCore.points
local owned = CisOwned.new()

local engine = Engine.new({
    grid = CisGrid,
    coords = function() return Cis.player.coords() end,
    callable = CisCallable,
    log = function(level, message) CisLog(level, message) end,
    guard = CisLoopGuard.Body,
    -- ON DEMAND, as in a consumer: a pass thread only while a point exists.
    autoDrive = true,
    onRegister = function(point)
        -- recorded so a consumer's stop can take its points with it.
        CisOwned.track(owned, point.owner, 'point', point.id)
    end,
    onRemove = function(point)
        CisOwned.forget(owned, 'point', point.id)
    end,
})

--- Register a proximity point.
--- @return the id, or `false, reason`. An id is a number and is never reused.
function CisPointsCreate(data)
    if type(data) ~= 'table' then
        return false, ('options arrived as %s, not a table'):format(type(data))
    end
    if Config and Config.Framework and Config.Framework.Zones and Config.Framework.Zones.Enabled == false then
        return false, 'points disabled by config'
    end
    return engine:add(data, GetInvokingResource() or 'cis_libs')
end

--- Remove a point. Answers `false` for an id nobody holds, and a removed point that the
function CisPointsRemove(id)
    local point = engine:get(id)
    if not point then
        return false
    end
    -- ONLY THE OWNER, or cis_libs itself. Ids are small monotonic integers, so any
    -- resource could otherwise remove every other resource's points by counting.
    local caller = GetInvokingResource() or 'cis_libs'
    if caller ~= 'cis_libs' and caller ~= point.owner then
        return false, ('point %s belongs to %s, not %s'):format(tostring(id), tostring(point.owner), caller)
    end
    return engine:remove(id)
end

function CisPointsGetDebug()
    return engine:debug()
end

-- THE CALLER'S POINTS ONLY, as remove is: this set is shared, and one resource
-- listing another's is a view nothing needs. cis_libs sees every point.
local function queryOwner()
    local caller = GetInvokingResource() or 'cis_libs'
    if caller == 'cis_libs' then
        return nil
    end
    return caller
end

--- The nearest of the CALLER'S points, and how far away it is.
function CisPointsGetClosest()
    return engine:getClosest(nil, queryOwner())
end

function CisPointsGetAll()
    return engine:allIds(queryOwner())
end

function CisPointsGetNearby()
    return engine:nearbyIds(queryOwner())
end

-- A point that outlives the resource that made it is invisible from the server and
AddEventHandler('onResourceStop', function(resource)
    -- A forged stop from another client script is ignored (shared/owned.lua).
    if not CisRealStop(resource) then
        return
    end
    local freed = CisOwned.release(owned, resource)
    -- `release` hands back { kind, id } ENTRIES. Iterating it with `for id in ipairs`
    -- walked the positions 1..n instead, which deleted whichever points happened to
    -- hold those ids -- other resources' points -- and left this one's in place.
    local released = 0
    for i = 1, #freed do
        local id = freed[i].id
        if freed[i].kind == 'point' and engine:remove(id, true) then
            released = released + 1
        end
        CisOwned.forget(owned, freed[i].kind, id)
    end
    engine.passDirty = true
    if released > 0 then
        CisLog('info', ('cis_libs: released %d point(s) owned by %s'):format(released, tostring(resource)))
    end
end)

exports('CreatePoint', CisPointsCreate)
exports('RemovePoint', CisPointsRemove)
exports('GetClosestPoint', CisPointsGetClosest)
exports('GetPointsDebug', CisPointsGetDebug)
exports('GetAllPoints', CisPointsGetAll)
exports('GetNearbyPoints', CisPointsGetNearby)

CisDiagnostics.Register('client', 'points', function()
    local out = { total = 0, byOwner = {} }
    for _, point in pairs(engine.points) do
        local owner = point.owner or '<none>'
        out.byOwner[owner] = (out.byOwner[owner] or 0) + 1
        out.total = out.total + 1
    end
    return out
end)
