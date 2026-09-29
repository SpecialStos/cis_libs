-- Grid zones. Proximity pass only after half-cell movement. Per-zone inside interval.

local zones = {}
local grid = CisGrid.new()
local inside = {}
local debugStats = {
    lastPassMs = 0,
    lastPassAt = 0,
}

local HALF_CELL = CisGrid.CELL * 0.5
-- Cadence for re-testing zones we are already inside, so onExit is not delayed
-- until the next half-cell movement.
local RECHECK_MS = 200

local function asVec3(p, fallbackZ)
    if p == nil then
        -- The exports boundary can drop a value entirely. Indexing nil here
        -- would throw and take the caller's export call with it.
        return nil
    end
    if type(p) == 'vector3' then
        return p
    end
    if type(p) == 'vector4' then
        return vector3(p.x, p.y, p.z)
    end
    return vector3(p.x or p[1], p.y or p[2], p.z or p[3] or fallbackZ or 0.0)
end

local function normalizePoints(points, minZ)
    local out = {}
    for i = 1, #points do
        out[i] = asVec3(points[i], minZ)
    end
    return out
end

local function contains(zone, coords)
    if zone.kind == 'poly' then
        if coords.z < zone.minZ or coords.z > zone.maxZ then
            return false
        end
        return CisGrid.pointInPolygon(coords.x, coords.y, zone.points)
    elseif zone.kind == 'sphere' then
        return CisGrid.pointInSphere(coords.x, coords.y, coords.z, zone.cx, zone.cy, zone.cz, zone.radius)
    elseif zone.kind == 'box' then
        return CisGrid.pointInBox(coords.x, coords.y, coords.z, zone.cx, zone.cy, zone.cz, zone.hx, zone.hy, zone.hz, zone.heading)
    end
    return false
end

-- A Lua callback cannot be sent across the exports boundary: an options table
-- carrying onEnter arrives with it stripped. A net event can, because it carries
-- only data. So every callback option has an *Event twin:
--
--   onEnter    = function(coords) ... end
--   onEnterEvent = 'myResource:shopEnter'   -- receive: (zoneName, x, y, z)
--
-- The function form works inside cis_libs; the event form works from a consumer.
local function invoke(zone, name, ...)
    local fn = zone[name]
    if fn then
        local ok, err = pcall(fn, zone, ...)
        if not ok then
            CisLog('error', ('zone %s %s: %s'):format(zone.name, name, err))
        end
        return
    end
    local eventName = zone[name .. 'Event']
    if eventName then
        local coords = select(1, ...)
        if coords then
            local ok, err = pcall(function()
                TriggerServerEvent(eventName, zone.name, coords.x, coords.y, coords.z)
            end)
            if not ok then
                CisLog('error', ('zone %s event %s: %s'):format(zone.name, eventName, err))
            end
        end
    end
end

local function register(zone)
    zones[zone.name] = zone
    CisGrid.insert(grid, zone.name, zone.aabb, zone)
end

function CisZonesCreate(kind, name, a, b, options)
    -- Every refusal returns a reason as a second value. A caller on the other
    -- side of the exports boundary cannot read our logs, so "false" alone
    -- gives it nothing to act on.
    if Config and Config.Framework and Config.Framework.Zones and Config.Framework.Zones.Enabled == false then
        return false, 'zones disabled by config'
    end
    if type(name) ~= 'string' or name == '' then
        return false, ('name arrived as %s'):format(type(name))
    end
    if kind == 'poly' then
        options = b or {}
    else
        options = options or {}
    end
    if a == nil then
        return false, 'coords arrived as nil (the exports boundary dropped them)'
    end
    if type(a) ~= 'vector3' and type(a) ~= 'vector4' and type(a) ~= 'table' then
        return false, ('coords arrived as %s'):format(type(a))
    end
    if zones[name] then
        CisZonesRemove(name)
    end
    local zone = {
        name = name,
        kind = kind,
        onEnter = options.onEnter,
        onExit = options.onExit,
        inside = options.inside,
        insideInterval = options.insideInterval,
        debug = options.debug,
    }
    -- Event twins of the callbacks: the only way a consumer resource can
    -- observe this zone, because a function cannot cross the boundary.
    zone.onEnterEvent = options.onEnterEvent
    zone.onExitEvent = options.onExitEvent
    zone.insideEvent = options.insideEvent
    if (zone.inside or zone.insideEvent) and zone.insideInterval == nil then
        zone.insideInterval = 500
    end

    if kind == 'poly' then
        local points = normalizePoints(a, options.minZ)
        zone.points = points
        zone.minZ = options.minZ or -1000.0
        zone.maxZ = options.maxZ or 10000.0
        zone.aabb = CisGrid.aabbFromPoints(points, zone.minZ, zone.maxZ, 0.5)
    elseif kind == 'box' then
        local center = asVec3(a)
        local size = b
        local sx, sy, sz
        if type(size) == 'vector3' or type(size) == 'table' then
            sx = size.x or size[1] or 1.0
            sy = size.y or size[2] or 1.0
            sz = size.z or size[3] or 2.0
        else
            sx, sy, sz = size, size, size
        end
        zone.cx, zone.cy, zone.cz = center.x, center.y, center.z
        zone.hx, zone.hy, zone.hz = sx * 0.5, sy * 0.5, sz * 0.5
        zone.heading = options.heading or options.rotation or 0.0
        zone.aabb = CisGrid.aabbFromCenter(zone.cx, zone.cy, zone.cz, zone.hx + 0.5, zone.hy + 0.5, zone.hz + 0.5)
    elseif kind == 'sphere' then
        local center = asVec3(a)
        zone.cx, zone.cy, zone.cz = center.x, center.y, center.z
        zone.radius = b or 1.0
        zone.aabb = CisGrid.aabbFromCenter(zone.cx, zone.cy, zone.cz, zone.radius, zone.radius, zone.radius)
    else
        return false
    end

    register(zone)
    return true
end

function CisZonesRemove(name)
    if not zones[name] then
        return false
    end
    if inside[name] then
        invoke(zones[name], 'onExit')
        inside[name] = nil
    end
    CisGrid.remove(grid, name)
    zones[name] = nil
    return true
end

function CisZonesContains(name, point)
    local zone = zones[name]
    if not zone then
        return false
    end
    return contains(zone, asVec3(point))
end

local function refreshInside(coords)
    local seen = {}
    -- queryPoint is sufficient: insert() registers an id in every cell its
    -- AABB overlaps, so anything containing this point is in this cell. A 3x3
    -- neighbour scan returns the identical set for 9x the bucket lookups.
    CisGrid.queryPoint(grid, coords.x, coords.y, coords.z, function(id, item)
        local zone = item.data
        seen[id] = true
        if contains(zone, coords) then
            if not inside[id] then
                inside[id] = { lastInside = 0 }
                invoke(zone, 'onEnter', coords)
            end
        elseif inside[id] then
            inside[id] = nil
            invoke(zone, 'onExit', coords)
        end
    end)
    for id in pairs(inside) do
        if not seen[id] then
            local zone = zones[id]
            inside[id] = nil
            if zone then
                invoke(zone, 'onExit', coords)
            end
        end
    end
end

-- The grid pass above only runs after half a cell of movement, which is cheap
-- but leaves a small zone reporting its exit tens of metres late. Re-testing
-- only the handful of zones we are already inside costs one exact test each and
-- gives an accurate exit.
local function recheckInside(coords)
    if next(inside) == nil then
        return false
    end
    local changed = false
    for id in pairs(inside) do
        local zone = zones[id]
        if zone and not contains(zone, coords) then
            inside[id] = nil
            invoke(zone, 'onExit', coords)
            changed = true
        end
    end
    return changed
end

CreateThread(function()
    if not CisReadyState.wait(15000) then
        return
    end
    local lastCellX, lastCellY
    local lastPos
    local lastRecheck = 0
    while true do
        if next(zones) == nil then
            Wait(500)
        else
            local started = GetGameTimer()
            local coords = Cis.player.coords()
            local cx, cy = CisGrid.cell(coords.x, coords.y)
            local moved = not lastPos or #(coords - lastPos) >= HALF_CELL or cx ~= lastCellX or cy ~= lastCellY
            if moved then
                lastPos = coords
                lastCellX, lastCellY = cx, cy
                refreshInside(coords)
                lastRecheck = GetGameTimer()
            elseif GetGameTimer() - lastRecheck >= RECHECK_MS then
                lastRecheck = GetGameTimer()
                recheckInside(coords)
            end

            local now = GetGameTimer()
            local waitMs = 250
            for id, state in pairs(inside) do
                local zone = zones[id]
                if zone and (zone.inside or zone.insideEvent) then
                    local interval = zone.insideInterval or 500
                    if interval > 0 then
                        if now - state.lastInside >= interval then
                            state.lastInside = now
                            invoke(zone, 'inside', coords)
                        end
                        local remain = interval - (now - state.lastInside)
                        if remain < waitMs then
                            waitMs = math.max(0, remain)
                        end
                    end
                end
            end
            debugStats.lastPassMs = GetGameTimer() - started
            debugStats.lastPassAt = GetGameTimer()
            Wait(waitMs)
        end
    end
end)

CreateThread(function()
    if not CisReadyState.wait(15000) then
        return
    end
    while true do
        local drew = false
        local coords
        for id in pairs(inside) do
            local zone = zones[id]
            if zone and (zone.inside or zone.insideEvent) and (zone.insideInterval or 500) <= 0 then
                coords = coords or Cis.player.coords()
                invoke(zone, 'inside', coords)
                drew = true
            end
        end
        if drew then
            Wait(0)
        else
            Wait(250)
        end
    end
end)

exports('CreateZone', CisZonesCreate)
exports('RemoveZone', CisZonesRemove)
exports('ZoneContains', CisZonesContains)

exports('GetPolyzones', function()
    return {
        Create = function(name, points, options)
            return CisZonesCreate('poly', name, points, options)
        end,
        Remove = CisZonesRemove,
        IsPointInside = CisZonesContains,
    }
end)

exports('GetZoneDebug', function()
    return debugStats
end)
