-- Proximity points: a coordinate, a radius, and enter / exit / nearby.

local points = {}
local grid = CisGrid.new()
-- Which points the library currently believes the player is inside.
local inside = {}
local owned = CisOwned.new()

-- WHY THE IDS ARE MONOTONIC AND NEVER REUSED.
local nextId = 0

-- THE HYSTERESIS BAND, and why it exists at all.
local HYSTERESIS = 0.15
local HYSTERESIS_FLOOR = 0.5

-- Cadence for discovery: a one-cell grid query plus a sweep of what we are inside.
-- Both are bounded by the points near the player, not by how many are registered,
-- so running it every RECHECK_MS for a standing player is cheap -- and it is the
-- only way a player who stands still, or walks a few metres, is ever found.
local RECHECK_MS = 200
-- Nothing registered: do not walk the grid at all.
local IDLE_MS = 500
-- THE FLOOR FOR A `nearbyEvent`. A server event per frame per point is a flood
-- aimed at the server's rate limiter; zones clamp `insideEvent` to the same value.
local MIN_EVENT_INTERVAL_MS = 250

-- Set by any mutation of the point set.
local passDirty = true

-- Scalars only. The inside list is built on demand by CisPointsGetDebug, so a
-- pass never allocates or sorts for a debug view nobody is reading.
local debugStats = {
    lastPassMs = 0,
    lastPassAt = 0,
    insideCount = 0,
    insideIds = {},
}

-- The pass cadence the next Wait should use, so a point asking for a fast `nearby` is
local waitMs = IDLE_MS


local function asVec3(v)
    if type(v) == 'vector3' or type(v) == 'vector4' then
        return v
    end
    if type(v) == 'table' then
        local x = v.x or v[1]
        local y = v.y or v[2]
        local z = v.z or v[3]
        if type(x) == 'number' and type(y) == 'number' then
            return { x = x, y = y, z = type(z) == 'number' and z or 0.0 }
        end
    end
    return nil
end

-- A CONSUMER CALLBACK, and the boundary it sits on.
local function callHook(point, key, ...)
    local fn = point[key]
    -- CisCallable, not `type(fn) == 'function'`: a handler from another resource
    -- arrives as a funcref table, and the type check dropped every one of them.
    if not CisCallable(fn) then
        return
    end
    local ok, err = pcall(fn, ...)
    if not ok then
        CisLog('error', ('cis_libs: point %s %s callback raised: %s')
            :format(tostring(point.id), key, tostring(err)))
    end
end

local function fireEvent(point, key, coords)
    local name = point[key]
    if type(name) ~= 'string' or name == '' then
        return
    end
    local ok, err = pcall(TriggerServerEvent, name, point.id, coords.x, coords.y, coords.z)
    if not ok then
        CisLog('error', ('cis_libs: point %s event %q raised: %s')
            :format(tostring(point.id), name, tostring(err)))
    end
end

-- A transition fires BOTH forms, and that is not a duplicate.
local function enter(point, coords)
    -- `lastNearby` IS SET HERE, and that is the whole fix for a feature that registers,
    inside[point.id] = { since = GetGameTimer(), lastNearby = GetGameTimer() - point.nearbyInterval }
    callHook(point, 'onEnter', coords)
    fireEvent(point, 'onEnterEvent', coords)
end

local function exit(point, coords)
    inside[point.id] = nil
    callHook(point, 'onExit', coords)
    fireEvent(point, 'onExitEvent', coords)
end


--- Register a proximity point.
--- @return the id, or `false, reason`. An id is a number and is never reused.
function CisPointsCreate(data)
    if type(data) ~= 'table' then
        return false, ('options arrived as %s, not a table'):format(type(data))
    end
    if Config and Config.Framework and Config.Framework.Zones and Config.Framework.Zones.Enabled == false then
        return false, 'points disabled by config'
    end

    local coords = asVec3(data.coords)
    if not coords then
        return false, 'coords arrived as nil or as a type with no x/y (the exports boundary drops a value entirely)'
    end

    -- THE DISTANCE IS CHECKED, NOT DEFAULTED INTO A HUGER ONE.
    local distance = data.distance
    if distance == nil then
        return false, 'a point needs a `distance`; there is no default, because any default is a radius nobody asked for'
    end
    if type(distance) ~= 'number' then
        return false, ('distance arrived as %s'):format(type(distance))
    end
    -- NaN is truthy and infinity is a number, so a plain `> 0` lets both through.
    if distance ~= distance then
        return false, 'distance is NaN'
    end
    if distance <= 0 then
        return false, ('distance must be greater than zero, got %s'):format(tostring(distance))
    end
    if distance == math.huge then
        return false, 'distance is infinite; a point with no radius is not a point'
    end

    local exitDistance = distance * (1.0 + HYSTERESIS)
    if exitDistance - distance < HYSTERESIS_FLOOR then
        exitDistance = distance + HYSTERESIS_FLOOR
    end

    -- Read HERE, before anything can yield or reach another resource: this is the only
    local point = {
        id = 0,
        owner = GetInvokingResource() or 'cis_libs',
        x = coords.x,
        y = coords.y,
        z = coords.z,
        distance = distance,
        exitDistance = exitDistance,
        onEnter = data.onEnter,
        onExit = data.onExit,
        nearby = data.nearby,
        onEnterEvent = data.onEnterEvent,
        onExitEvent = data.onExitEvent,
        nearbyEvent = data.nearbyEvent,
        -- The cadence `nearby` runs at.
        nearbyInterval = data.nearbyInterval,
    }
    if type(point.nearbyInterval) ~= 'number' or point.nearbyInterval ~= point.nearbyInterval
        or point.nearbyInterval < 0 then
        point.nearbyInterval = 200
    end
    if type(point.nearbyEvent) == 'string' and point.nearbyEvent ~= ''
        and point.nearbyInterval < MIN_EVENT_INTERVAL_MS then
        point.nearbyInterval = MIN_EVENT_INTERVAL_MS
    end

    nextId = nextId + 1
    point.id = nextId

    -- THE INDEX BOX IS THE EXIT RADIUS, NOT THE ENTER RADIUS.
    local aabb = CisGrid.aabbFromCenter(
        point.x, point.y, point.z,
        exitDistance + 0.5, exitDistance + 0.5, exitDistance + 0.5)
    point.aabb = aabb
    points[point.id] = point
    CisGrid.insert(grid, point.id, aabb, point)
    -- recorded so a consumer's stop can take its points with it.
    CisOwned.track(owned, point.owner, 'point', point.id)

    -- The snapshot must not be stale: a point added while the player is already
    passDirty = true

    return point.id
end

--- Remove a point. Answers `false` for an id nobody holds, and a removed point that the
function CisPointsRemove(id)
    local point = points[id]
    if not point then
        return false
    end
    -- ONLY THE OWNER, or cis_libs itself. Ids are small monotonic integers, so any
    -- resource could otherwise remove every other resource's points by counting.
    local caller = GetInvokingResource() or 'cis_libs'
    if caller ~= 'cis_libs' and caller ~= point.owner then
        return false, ('point %s belongs to %s, not %s'):format(tostring(id), tostring(point.owner), caller)
    end
    if inside[id] then
        local p = GetEntityCoords(PlayerPedId())
        local coords = (p and p.x ~= nil)
            and { x = p.x, y = p.y, z = p.z }
            or { x = point.x, y = point.y, z = point.z }
        exit(point, coords)
    end
    CisGrid.remove(grid, id)
    points[id] = nil
    -- Removed the ordinary way, so the ledger stops owing it.
    CisOwned.forget(owned, 'point', id)
    passDirty = true
    return true
end

--- The nearest registered point, and how far away it is.
function CisPointsGetClosest()
    if next(points) == nil then
        return nil, 'no points are registered'
    end
    local coords = GetEntityCoords(PlayerPedId())
    if not coords then
        return nil, 'the player has no coordinates yet'
    end
    local bestId, bestDistance
    for id, point in pairs(points) do
        local dx = coords.x - point.x
        local dy = coords.y - point.y
        local dz = coords.z - point.z
        local d = math.sqrt(dx * dx + dy * dy + dz * dz)
        if not bestDistance or d < bestDistance then
            bestId, bestDistance = id, d
        end
    end
    return bestId, bestDistance
end

function CisPointsGetDebug()
    -- Built here, on request, rather than on every pass.
    local ids = {}
    for id in pairs(inside) do
        ids[#ids + 1] = id
    end
    table.sort(ids)
    debugStats.insideCount = #ids
    debugStats.insideIds = ids
    return debugStats
end


local function containment(point, coords)
    local dx = coords.x - point.x
    local dy = coords.y - point.y
    local dz = coords.z - point.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- EXIT IS A SWEEP OVER WHAT IS INSIDE, NOT A TEST OF THE CANDIDATES.
local function sweepExits(coords)
    for id in pairs(inside) do
        local point = points[id]
        if not point then
            -- A point removed out from under the table.
            inside[id] = nil
        elseif containment(point, coords) > point.exitDistance then
            exit(point, coords)
        end
    end
end

local function refresh(coords)
    -- The candidates come from the grid, and the containment test runs on each.
    CisGrid.queryPoint(grid, coords.x, coords.y, coords.z, function(id)
        local point = points[id]
        if point and not inside[id] and containment(point, coords) <= point.distance then
            enter(point, coords)
        end
    end)
    sweepExits(coords)
end

local function serveInside(coords, now)
    waitMs = IDLE_MS
    for id, state in pairs(inside) do
        local point = points[id]
        if point and (point.nearby ~= nil or point.nearbyEvent ~= nil) then
            if now - state.lastNearby >= point.nearbyInterval then
                state.lastNearby = now
                callHook(point, 'nearby', coords)
                -- The event twin, exactly as enter and exit have one: the only form a
                -- server-side consumer can observe.
                fireEvent(point, 'nearbyEvent', coords)
            end
            local remain = point.nearbyInterval - (now - state.lastNearby)
            if remain < waitMs then
                waitMs = math.max(0, remain)
            end
        end
    end
end

local lastRefresh = 0

-- One pass. Discovery (a one-cell grid query, then a sweep of what we are inside)
-- runs on any mutation and every RECHECK_MS; between those, a pass only serves
-- `nearby`. There is no movement gate: the old one refreshed whenever fewer points
-- were inside than were registered, which is always, after counting every
-- registered point twice to find that out.
local function pass()
    if next(points) == nil then
        return IDLE_MS
    end
    local started = GetGameTimer()
    local coords = Cis.player.coords()
    if not coords then
        return IDLE_MS
    end
    if passDirty or started - lastRefresh >= RECHECK_MS then
        passDirty = false
        lastRefresh = started
        refresh(coords)
    end

    serveInside(coords, GetGameTimer())

    debugStats.lastPassMs = GetGameTimer() - started
    debugStats.lastPassAt = GetGameTimer()
    return math.max(0, math.min(waitMs, RECHECK_MS))
end

-- GUARDED, for the reason zones are: one raise in here used to end the loop for good.
-- AND A LOOP. This thread used to call `Wait(tick())` once and fall off the end, so
-- the first pass was the only pass and no point ever fired after it.
CreateThread(function()
    local tick = CisLoopGuard.Body('client.points.pass', pass)
    while true do
        -- The interval is returned by the body and waited on HERE, so a yield is never
        -- swallowed by the guard's pcall.
        Wait(tick() or IDLE_MS)
    end
end)


-- A point that outlives the resource that made it is invisible from the server and
AddEventHandler('onResourceStop', function(resource)
    local freed = CisOwned.release(owned, resource)
    -- `release` hands back { kind, id } ENTRIES. Iterating it with `for id in ipairs`
    -- walked the positions 1..n instead, which deleted whichever points happened to
    -- hold those ids -- other resources' points -- and left this one's in place.
    local released = 0
    for i = 1, #freed do
        local id = freed[i].id
        local point = freed[i].kind == 'point' and points[id] or nil
        if point then
            if inside[id] then
                local p = GetEntityCoords(PlayerPedId())
                local coords = (p and p.x ~= nil)
                    and { x = p.x, y = p.y, z = p.z }
                    or { x = point.x, y = point.y, z = point.z }
                -- The event only: the stopping resource's Lua callbacks are dead.
                fireEvent(point, 'onExitEvent', coords)
            end
            CisGrid.remove(grid, id)
            points[id] = nil
            inside[id] = nil
            released = released + 1
        end
        CisOwned.forget(owned, freed[i].kind, id)
    end
    passDirty = true
    if released > 0 then
        CisLog('info', ('cis_libs: released %d point(s) owned by %s'):format(released, tostring(resource)))
    end
end)

exports('CreatePoint', CisPointsCreate)
exports('RemovePoint', CisPointsRemove)
exports('GetClosestPoint', CisPointsGetClosest)
exports('GetPointsDebug', CisPointsGetDebug)

CisDiagnostics.Register('client', 'points', function()
    local out = { total = 0, byOwner = {} }
    for _, point in pairs(points) do
        local owner = point.owner or '<none>'
        out.byOwner[owner] = (out.byOwner[owner] or 0) + 1
        out.total = out.total + 1
    end
    return out
end)
