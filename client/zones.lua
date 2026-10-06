-- Grid zones. Proximity pass only after half-cell movement. Per-zone inside interval.

local zones = {}
local grid = CisGrid.new()

-- Which name-collisions have already been logged.
local collisionWarned = {}
local inside = {}
-- who asked for which zone.
local owned = CisOwned.new()
local debugStats = {
    lastPassMs = 0,
    lastPassAt = 0,
    -- Whether the draw thread is running right now.
    debugDrawing = false,
}

local HALF_CELL = CisGrid.CELL * 0.5
-- Cadence for re-testing zones we are already inside, so onExit is not delayed until
local RECHECK_MS = 200

-- THE FLOOR FOR AN `insideEvent`, and the reason it exists.
local MIN_EVENT_INTERVAL_MS = 250

local function asVec3(p, fallbackZ)
    if p == nil then
        -- The exports boundary can drop a value entirely.
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
    return CisZoneGeom.contains(zone, coords)
end

-- A Lua callback cannot be sent across the exports boundary: an options table carrying
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
                if zone['local'] then
                    -- `local = true` (): a CLIENT-SIDE event.
                    TriggerEvent(eventName, zone.name, coords.x, coords.y, coords.z)
                else
                    TriggerServerEvent(eventName, zone.name, coords.x, coords.y, coords.z)
                end
            end)
            if not ok then
                CisLog('error', ('zone %s event %s: %s'):format(zone.name, eventName, err))
            end
        end
    end
end

local function register(zone)
    -- The grid goes FIRST, so a refusal cannot leave a zone recorded that no query can
    local ok, why = CisGrid.insert(grid, zone.name, zone.aabb, zone)
    if not ok then
        return false, why
    end
    zones[zone.name] = zone
    -- The OWNER, captured at creation.
    CisOwned.track(owned, zone.owner, 'zone', zone.name)
    return true
end

-- Forward declarations, for the reason the file already relies on: an upvalue is
local ensureDebugDraw, startDebugDraw, drawZone, hasDebugZone

function CisZonesCreate(kind, name, a, b, options)
    -- Every refusal returns a reason as a second value.
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
    -- [D3] A NAME HELD BY ANOTHER RESOURCE IS REFUSED, NOT REPLACED.
    local zoneOwner = GetInvokingResource() or 'cis_libs'
    local holder = zones[name] and zones[name].owner
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
    -- A BOX WITH NO SIZE IS REFUSED, NOT DEFAULTED ().
    if kind == 'box' and (b == nil) then
        return false, 'a box zone needs a size; it arrived as nil'
    end
    if zones[name] then
        CisZonesRemove(name)
    end
    local zone = {
        name = name,
        kind = kind,
        -- recorded so a consumer's stop can take its zones with it.
        owner = zoneOwner,
        onEnter = options.onEnter,
        onExit = options.onExit,
        inside = options.inside,
        insideInterval = options.insideInterval,
        debug = options.debug,
    }
    -- Event twins of the callbacks: the only way a consumer resource can observe this
    zone.onEnterEvent = options.onEnterEvent
    zone.onExitEvent = options.onExitEvent
    zone.insideEvent = options.insideEvent

    -- THE INSIDE INTERVAL IS CLAMPED, AND A CLIENT-SIDE OPTION EXISTS.
    if zone.insideEvent then
        -- `local` is a Lua keyword, so this key is read with brackets.
        zone['local'] = options['local'] and true or false
        if zone.insideInterval == nil then
            zone.insideInterval = 500
        end
        if zone.insideInterval < MIN_EVENT_INTERVAL_MS then
            zone.insideInterval = MIN_EVENT_INTERVAL_MS
        end
    elseif zone.inside and zone.insideInterval == nil then
        zone.insideInterval = 500
    end

    if kind == 'poly' then
        local points = normalizePoints(a, options.minZ)
        zone.points = points
        zone.minZ = options.minZ or -1000.0
        zone.maxZ = options.maxZ or 10000.0
        -- A poly zone with no points, or a point that did not survive the
        local box, boxWhy = CisGrid.aabbFromPoints(points, zone.minZ, zone.maxZ, 0.5)
        if not box then
            return false, ('poly zone %q: %s'):format(name, tostring(boxWhy))
        end
        zone.aabb = box
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
        -- an unknown kind is a refusal WITH A REASON.
        return false, ('unknown zone kind %q; valid kinds are box, poly and sphere')
            :format(tostring(kind))
    end

    local registered, registerWhy = register(zone)
    if not registered then
        return false, registerWhy
    end
    -- AFTER a successful registration, so a refused zone cannot start a thread that
    if zone.debug then
        ensureDebugDraw()
    end
    return true
end

-- Always running would spend a frame drawing nothing on every server that has no debug
local drawThreadStarted = false

hasDebugZone = function()
    for _, zone in pairs(zones) do
        if zone.debug then
            return true
        end
    end
    return false
end

startDebugDraw = function()
    if drawThreadStarted then
        return
    end
    drawThreadStarted = true
    debugStats.debugDrawing = true
    CreateThread(function()
        local tick = CisLoopGuard.Body('client.zones.draw', function()
            local coords = Cis.player.coords()
            for _, zone in pairs(zones) do
                if zone.debug then
                    drawZone(zone, coords)
                end
            end
            -- NO SLEEP HERE. The body decides when it next runs, so a frame that drew
        end)
        while true do
            tick()
            -- AND STOP AS SOON AS THE LAST ONE GOES.
            if not hasDebugZone() then
                debugStats.debugDrawing = false
                drawThreadStarted = false
                return
            end
            Wait(0)
        end
    end)
end

ensureDebugDraw = function()
    if hasDebugZone() then
        startDebugDraw()
    end
end

-- ONE ZONE, ONE SHAPE. Box and poly draw their outline with translucent walls between
drawZone = function(zone, coords)
    local inZone = zone ~= nil and inside[zone.name] ~= nil
    local colour = inZone and { 0, 255, 0, 200 } or { 255, 0, 0, 160 }

    if zone.kind == 'sphere' then
        DrawMarker(1, zone.cx, zone.cy, zone.cz + zone.radius, 0.0, 0.0, 0.0,
            0.0, 0.0, 0.0, zone.radius, colour[4] or 200, colour[1], colour[2], colour[3],
            false, false, 2, false, nil, nil, false)
        return
    end

    local minZ = zone.minZ or (zone.cz - 5.0)
    local maxZ = zone.maxZ or (zone.cz + 5.0)
    if zone.kind == 'poly' and zone.points then
        -- The polygon, one edge per segment, plus its walls.
        local n = #zone.points
        for i = 1, n do
            local p = zone.points[i]
            local q = zone.points[(i % n) + 1]
            DrawLine(p.x, p.y, minZ, q.x, q.y, minZ, colour[1], colour[2], colour[3], 255)
            DrawLine(p.x, p.y, maxZ, q.x, q.y, maxZ, colour[1], colour[2], colour[3], 255)
            DrawLine(p.x, p.y, minZ, p.x, p.y, maxZ, colour[1], colour[2], colour[3], 255)
        end
        return
    end

    local x1 = zone.cx - zone.hx
    local x2 = zone.cx + zone.hx
    local y1 = zone.cy - zone.hy
    local y2 = zone.cy + zone.hy
    -- The footprint, at both heights.
    for _, z in ipairs({ minZ, maxZ }) do
        DrawLine(x1, y1, z, x2, y1, z, colour[1], colour[2], colour[3], 255)
        DrawLine(x2, y1, z, x2, y2, z, colour[1], colour[2], colour[3], 255)
        DrawLine(x2, y2, z, x1, y2, z, colour[1], colour[2], colour[3], 255)
        DrawLine(x1, y2, z, x1, y1, z, colour[1], colour[2], colour[3], 255)
    end
    for _, p in ipairs({
        { x1, y1 }, { x2, y1 }, { x2, y2 }, { x1, y2 },
    }) do
        DrawLine(p[1], p[2], minZ, p[1], p[2], maxZ, colour[1], colour[2], colour[3], 255)
    end
    if coords and zone.hx and zone.hy then
        -- A cross at the centre, so an operator can see which point the zone was
        DrawLine(zone.cx - 0.5, zone.cy, minZ, zone.cx + 0.5, zone.cy, minZ,
            255, 255, 0, 255)
        DrawLine(zone.cx, zone.cy - 0.5, minZ, zone.cx, zone.cy + 0.5, minZ,
            255, 255, 0, 255)
    end
end

function CisZonesRemove(name)
    if not zones[name] then
        return false
    end
    if inside[name] then
        -- THE PLAYER'S COORDS, not the zone's.
        local zone = zones[name]
        local ped = PlayerPedId()
        local p = GetEntityCoords(ped)
        local coords = (p and p.x ~= nil)
            and { x = p.x, y = p.y, z = p.z }
            or { x = zone.cx, y = zone.cy, z = zone.cz }
        invoke(zone, 'onExit', coords)
        inside[name] = nil
    end
    CisGrid.remove(grid, name)
    zones[name] = nil
    -- Removed the ordinary way, so the ledger stops owing it.
    CisOwned.forget(owned, 'zone', name)
    -- The draw thread notices on its next pass, one frame later.
    return true
end

function CisZonesContains(name, point)
    local zone = zones[name]
    if not zone then
        return false
    end
    -- a point the boundary dropped must be a `false`, not a throw.
    local p = asVec3(point)
    if not p then
        return false
    end
    return contains(zone, p)
end

local function refreshInside(coords)
    local seen = {}
    -- queryPoint is sufficient: insert() registers an id in every cell its AABB
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

-- The grid pass above only runs after half a cell of movement, which is cheap but
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
    -- GUARDED (3.10). One raise in here used to end this loop for good: the thread
    local tick = CisLoopGuard.Body('client.zones.pass', function()
                if next(zones) == nil then
                    -- debugStats is rebuilt inside the pass below, which only runs when
                    local tIdle = CisTiming and CisTiming.now()
                    debugStats.insideCount = 0
                    debugStats.insideNames = {}
                    if CisTiming and tIdle ~= nil then
                        CisTiming.observe('zonePass', CisTiming.now() - tIdle)
                    end
                    -- Returned, never waited on inside the guard: see the note on the
                    return 500
                else
                    local started = GetGameTimer()
                    local t0 = CisTiming and CisTiming.now()
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
                        -- DISCOVERY WAS GATED ON MOVEMENT, AND NOTHING ELSE.
                        local insideCount = 0
                        for _ in pairs(inside) do insideCount = insideCount + 1 end
                        local zoneCount = 0
                        for _ in pairs(zones) do zoneCount = zoneCount + 1 end
                        if insideCount < zoneCount then
                            refreshInside(coords)
                        else
                            recheckInside(coords)
                        end
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
                    -- WHICH zones the library currently believes the player is inside.
                    debugStats.insideCount = 0
                    debugStats.insideNames = {}
                    for id in pairs(inside) do
                        debugStats.insideCount = debugStats.insideCount + 1
                        debugStats.insideNames[#debugStats.insideNames + 1] = id
                    end
                    table.sort(debugStats.insideNames)
debugStats.lastPassMs = GetGameTimer() - started
            debugStats.lastPassAt = GetGameTimer()
                    if CisTiming and t0 ~= nil then
                        CisTiming.observe('zonePass', CisTiming.now() - t0)
                    end
            -- THE INTERVAL IS RETURNED, NOT WAITED ON HERE.
            return waitMs
                end
    end)
    -- The interval this pass uses when the guarded body raises and therefore cannot
    -- from out here is an undefined global, which luacheck caught.
    local PASS_DEFAULT_MS = 250
    while true do
        -- The Wait is HERE, outside the guard's pcall, so a yield cannot be swallowed
        Wait(tick() or PASS_DEFAULT_MS)
    end
end)

CreateThread(function()
    if not CisReadyState.wait(15000) then
        return
    end
    -- GUARDED (3.10): an `inside` callback raising used to end this loop for good, and
    local tickInside = CisLoopGuard.Body('client.zones.inside', function()
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
        return drew and 0 or 250
    end)
    while true do
        Wait(tickInside() or 250)
    end
end)

-- A CONSUMER THAT STOPS TAKES ITS ZONES WITH IT ().
AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        return
    end
    local freed = CisOwned.release(owned, resource)
    for i = 1, #freed do
        if freed[i].kind == 'zone' then
            -- Under pcall: `onExitEvent` is a TriggerServerEvent into a resource that
            pcall(CisZonesRemove, freed[i].id)
        end
    end
    if #freed > 0 then
        CisLog('info', ('cis_libs: released %d zone(s) owned by %s'):format(#freed, tostring(resource)))
    end
end)

exports('CreateZone', CisZonesCreate)
exports('RemoveZone', CisZonesRemove)
exports('ZoneContains', CisZonesContains)

exports('GetZoneDebug', function()
    return debugStats
end)

-- A zone that outlives the resource that made it is invisible from the server and
CisDiagnostics.Register('client', 'zones', function()
    local out = { total = 0, byOwner = {} }
    for _, zone in pairs(zones) do
        local owner = zone.owner or '<none>'
        out.byOwner[owner] = (out.byOwner[owner] or 0) + 1
        out.total = out.total + 1
    end
    return out
end)
