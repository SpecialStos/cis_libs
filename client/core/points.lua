-- The point ENGINE: a coordinate, a radius, and enter / exit / nearby.
--
-- ONE SOURCE, TWO VMS, like client/core/zones.lua. No state at file scope: a
-- point set is an instance from `M.new(cfg)`. client/points.lua wraps cis_libs'
-- instance behind the CreatePoint export; a consumer's `Cis.points.*` gets its
-- own, loaded from this same text by init.lua.
--
-- cfg:
--   grid         CisGrid
--   coords()     the player's coords
--   callable(v), log(level, message), guard(name, body) -> tick
--   onRegister(point), onRemove(point)   owner bookkeeping for the wrapper
--   autoDrive    true: the instance runs its own thread, ONLY while points exist

local M = {}

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

local Points = {}
Points.__index = Points

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

local function defaultCallable(v)
    if type(v) == 'function' then
        return true
    end
    return type(v) == 'table' and rawget(v, '__cfx_functionReference') ~= nil
end

local function noop() end

function M.new(cfg)
    cfg = cfg or {}
    return setmetatable({
        Grid = cfg.grid,
        grid = cfg.grid.new(),
        coordsOf = cfg.coords,
        callable = cfg.callable or defaultCallable,
        log = cfg.log or noop,
        guard = cfg.guard or function(_, body) return body end,
        onRegister = cfg.onRegister or noop,
        onRemove = cfg.onRemove or noop,
        autoDrive = cfg.autoDrive == true,
        points = {},
        -- Which points the engine currently believes the player is inside.
        inside = {},
        -- WHY THE IDS ARE MONOTONIC AND NEVER REUSED.
        nextId = 0,
        -- Set by any mutation of the point set.
        passDirty = true,
        lastRefresh = 0,
        -- The pass cadence the next Wait should use, so a point asking for a fast `nearby` is
        waitMs = IDLE_MS,
        driving = false,
        -- Scalars only. The inside list is built on demand by debug(), so a
        -- pass never allocates or sorts for a debug view nobody is reading.
        debugStats = {
            lastPassMs = 0,
            lastPassAt = 0,
            insideCount = 0,
            insideIds = {},
        },
    }, Points)
end

-- A CONSUMER CALLBACK, and the boundary it sits on.
function Points:callHook(point, key, ...)
    local fn = point[key]
    -- callable, not `type(fn) == 'function'`: a handler from another resource
    -- arrives as a funcref table, and the type check dropped every one of them.
    if not self.callable(fn) then
        return
    end
    local ok, err = pcall(fn, ...)
    if not ok then
        self.log('error', ('cis_libs: point %s %s callback raised: %s')
            :format(tostring(point.id), key, tostring(err)))
    end
end

function Points:fireEvent(point, key, coords)
    local name = point[key]
    if type(name) ~= 'string' or name == '' then
        return
    end
    local ok, err = pcall(TriggerServerEvent, name, point.id, coords.x, coords.y, coords.z)
    if not ok then
        self.log('error', ('cis_libs: point %s event %q raised: %s')
            :format(tostring(point.id), name, tostring(err)))
    end
end

-- A transition fires BOTH forms, and that is not a duplicate.
function Points:enter(point, coords)
    -- `lastNearby` IS SET HERE, and that is the whole fix for a feature that registers,
    self.inside[point.id] = { since = GetGameTimer(), lastNearby = GetGameTimer() - point.nearbyInterval }
    -- The point's id rides along, so one handler can serve many points.
    self:callHook(point, 'onEnter', coords, point.id)
    self:fireEvent(point, 'onEnterEvent', coords)
end

function Points:exit(point, coords)
    self.inside[point.id] = nil
    self:callHook(point, 'onExit', coords, point.id)
    self:fireEvent(point, 'onExitEvent', coords)
end

--- Register a proximity point.
--- @return the id, or `false, reason`. An id is a number and is never reused.
function Points:add(data, owner)
    if type(data) ~= 'table' then
        return false, ('options arrived as %s, not a table'):format(type(data))
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
        owner = owner,
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

    -- THE INDEX BOX IS THE EXIT RADIUS, NOT THE ENTER RADIUS.
    local aabb = self.Grid.aabbFromCenter(
        point.x, point.y, point.z,
        exitDistance + 0.5, exitDistance + 0.5, exitDistance + 0.5)
    point.aabb = aabb

    self.nextId = self.nextId + 1
    point.id = self.nextId
    -- THE INDEX HAS TO TAKE IT, or nothing is recorded. A point the grid refused
    -- (NaN coords, or a radius of about 1,780 m and up) was still stored and
    -- given an id: getClosest found it and onEnter never fired.
    local indexed, indexWhy = self.Grid.insert(self.grid, point.id, aabb, point)
    if not indexed then
        return false, ('point not indexed: %s'):format(tostring(indexWhy))
    end
    self.points[point.id] = point
    -- recorded so a consumer's stop can take its points with it.
    self.onRegister(point)

    -- The snapshot must not be stale: a point added while the player is already
    self.passDirty = true
    if self.autoDrive then
        self:drive()
    end

    return point.id
end

function Points:get(id)
    return self.points[id]
end

function Points:hasPoints()
    return next(self.points) ~= nil
end

local function sortedIds(set, points, owner)
    local ids = {}
    for id in pairs(set) do
        local point = points[id]
        if point and (owner == nil or point.owner == owner) then
            ids[#ids + 1] = id
        end
    end
    table.sort(ids)
    return ids
end

-- Every point's id, or one resource's, ascending.
function Points:allIds(owner)
    return sortedIds(self.points, self.points, owner)
end

-- The ids of the points the player is inside right now, ascending.
function Points:nearbyIds(owner)
    return sortedIds(self.inside, self.points, owner)
end

--- Remove a point, with no owner check (the wrapper owns that). `silent` drops
--- it without calling the Lua callbacks -- the stop sweep's case, whose
--- callbacks belong to a resource that no longer exists -- but still fires the
--- event twin.
function Points:remove(id, silent)
    local point = self.points[id]
    if not point then
        return false
    end
    if self.inside[id] then
        local p = GetEntityCoords(PlayerPedId())
        local coords = (p and p.x ~= nil)
            and { x = p.x, y = p.y, z = p.z }
            or { x = point.x, y = point.y, z = point.z }
        if silent then
            -- The event only: the stopping resource's Lua callbacks are dead.
            self:fireEvent(point, 'onExitEvent', coords)
            self.inside[id] = nil
        else
            self:exit(point, coords)
        end
    end
    self.Grid.remove(self.grid, id)
    self.points[id] = nil
    -- Removed the ordinary way, so the ledger stops owing it.
    self.onRemove(point)
    self.passDirty = true
    return true
end

local function distanceTo(point, coords)
    local dx = coords.x - point.x
    local dy = coords.y - point.y
    local dz = coords.z - point.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--- The nearest registered point, and how far away it is. `owner` limits the
--- answer to that resource's points; nil means every point.
function Points:getClosest(coords, owner)
    if next(self.points) == nil then
        return nil, 'no points are registered'
    end
    coords = coords or GetEntityCoords(PlayerPedId())
    if not coords then
        return nil, 'the player has no coordinates yet'
    end
    -- Read once and checked: a table with no z raised in the subtraction.
    local x, y, z = tonumber(coords.x), tonumber(coords.y), tonumber(coords.z)
    if not x or not y or not z then
        return nil, 'coords has no numeric x/y/z'
    end
    local here = { x = x, y = y, z = z }
    local bestId, bestDistance
    for id, point in pairs(self.points) do
        if owner == nil or point.owner == owner then
            local d = distanceTo(point, here)
            if not bestDistance or d < bestDistance then
                bestId, bestDistance = id, d
            end
        end
    end
    if not bestId then
        return nil, ('%s has no points registered'):format(tostring(owner))
    end
    return bestId, bestDistance
end

function Points:debug()
    -- Built here, on request, rather than on every pass.
    local ids = {}
    for id in pairs(self.inside) do
        ids[#ids + 1] = id
    end
    table.sort(ids)
    local debugStats = self.debugStats
    debugStats.insideCount = #ids
    debugStats.insideIds = ids
    return debugStats
end

-- EXIT IS A SWEEP OVER WHAT IS INSIDE, NOT A TEST OF THE CANDIDATES.
function Points:sweepExits(coords)
    for id in pairs(self.inside) do
        local point = self.points[id]
        if not point then
            -- A point removed out from under the table.
            self.inside[id] = nil
        elseif distanceTo(point, coords) > point.exitDistance then
            self:exit(point, coords)
        end
    end
end

-- The candidate visitor, at file scope so a pass allocates no closure: the
-- instance and the coords ride in two upvalues set around the query.
local visitSelf, visitCoords
local function visitPoint(id)
    local self = visitSelf
    local point = self.points[id]
    if point and not self.inside[id] and distanceTo(point, visitCoords) <= point.distance then
        self:enter(point, visitCoords)
    end
end

function Points:refresh(coords)
    -- The candidates come from the grid, and the containment test runs on each.
    visitSelf, visitCoords = self, coords
    self.Grid.queryPoint(self.grid, coords.x, coords.y, coords.z, visitPoint)
    visitSelf, visitCoords = nil, nil
    self:sweepExits(coords)
end

function Points:serveInside(coords, now)
    local waitMs = IDLE_MS
    for id, state in pairs(self.inside) do
        local point = self.points[id]
        if point and (point.nearby ~= nil or point.nearbyEvent ~= nil) then
            if now - state.lastNearby >= point.nearbyInterval then
                state.lastNearby = now
                self:callHook(point, 'nearby', coords, point.id)
                -- The event twin, exactly as enter and exit have one: the only form a
                -- server-side consumer can observe.
                self:fireEvent(point, 'nearbyEvent', coords)
            end
            local remain = point.nearbyInterval - (now - state.lastNearby)
            if remain < waitMs then
                waitMs = math.max(0, remain)
            end
        end
    end
    self.waitMs = waitMs
end

-- One pass. Discovery (a one-cell grid query, then a sweep of what we are inside)
-- runs on any mutation and every RECHECK_MS; between those, a pass only serves
-- `nearby`. There is no movement gate: the old one refreshed whenever fewer points
-- were inside than were registered, which is always, after counting every
-- registered point twice to find that out.
function Points:pass()
    if next(self.points) == nil then
        return IDLE_MS
    end
    local started = GetGameTimer()
    local coords = self.coordsOf()
    if not coords then
        return IDLE_MS
    end
    if self.passDirty or started - self.lastRefresh >= RECHECK_MS then
        self.passDirty = false
        self.lastRefresh = started
        self:refresh(coords)
    end

    self:serveInside(coords, GetGameTimer())

    local debugStats = self.debugStats
    debugStats.lastPassMs = GetGameTimer() - started
    debugStats.lastPassAt = GetGameTimer()
    return math.max(0, math.min(self.waitMs, RECHECK_MS))
end

-- THE CONSUMER'S DRIVER: one thread while any point exists, none otherwise.
function Points:drive()
    if self.driving then
        return
    end
    self.driving = true
    CreateThread(function()
        local tick = self.guard('points.pass', function() return self:pass() end)
        while next(self.points) ~= nil do
            Wait(tick() or IDLE_MS)
        end
        self.driving = false
    end)
end

M.IDLE_MS = IDLE_MS
M.RECHECK_MS = RECHECK_MS

-- A MODULE. Published under CisCore when cis_libs runs it as a client_script.
if ... ~= 'cis_require' then
    CisCore = CisCore or {}
    CisCore.points = M
end

return M
