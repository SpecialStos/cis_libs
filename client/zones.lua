-- Grid zones. Proximity pass only after half-cell movement. Per-zone inside interval.
--
-- `zones`, `grid` and `inside` are the single index of every zone on the server
-- (COMPATIBILITY.md §10). Nothing here is a cache of anything: a consumer that
-- copies this file gets zones that only its own resource can see.

local zones = {}
local grid = CisGrid.new()
local inside = {}
-- L-C7: who asked for which zone. ox_lib does not need this because it runs in
-- the consumer's own VM; this library does not, so a zone outlives the resource
-- that created it until the process restarts. See shared/owned.lua.
local owned = CisOwned.new()
local debugStats = {
    lastPassMs = 0,
    lastPassAt = 0,
}

local HALF_CELL = CisGrid.CELL * 0.5
-- Cadence for re-testing zones we are already inside, so onExit is not delayed
-- until the next half-cell movement.
local RECHECK_MS = 200

-- THE FLOOR FOR AN `insideEvent`, and the reason it exists. A zone event that
-- reaches the SERVER is a net event, so its rate is a server-side budget: 60 a
-- second per player per zone is enough to have that player's other events
-- rate-limited by their own handler, for a zone the caller probably meant as a
-- client-side tick.
--
-- 250ms is the floor because it is the fastest a server-side zone event is
-- useful -- anything faster and the server is being told the same thing several
-- times before a player can act on any of it -- and it is far below the 8/s
-- backstop CisNetOn applies, so a legitimate zone never trips the limiter.
-- A caller that genuinely wants per-frame uses `inside` (a function, which
-- cannot cross the boundary and therefore stays on the client) or `local = true`.
local MIN_EVENT_INTERVAL_MS = 250

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
                if zone['local'] then
                    -- `local = true` (L-C14): a CLIENT-SIDE event.
                    --
                    -- Every zone event reaches the server by default, because
                    -- that is the only way a consumer on the server can be
                    -- notified. But a consumer that only cares about its own
                    -- client does not need a round trip, and paying one per
                    -- inside-tick is what made `insideInterval = 0` a flood.
                    -- `TriggerEvent` stays on this client entirely.
                    --
                    -- Named explicitly rather than inferred: "the server does
                    -- not listen for this name" is not knowable here, and
                    -- guessing would silently break a consumer whose server
                    -- handler exists.
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
    zones[zone.name] = zone
    CisGrid.insert(grid, zone.name, zone.aabb, zone)
    -- The OWNER, captured at creation. A zone created by cis_libs's own code
    -- (none today, but the doorlock and the sync layer both reach here) is owned
    -- by cis_libs and is never swept on a consumer's stop.
    CisOwned.track(owned, zone.owner, 'zone', zone.name)
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
    -- [D3] A NAME HELD BY ANOTHER RESOURCE IS REFUSED, NOT REPLACED.
    --
    -- Namespacing (`owner:name`) was the other option and it was rejected because
    -- it changes what `remove(name)` means -- a caller writing `remove('shop')`
    -- would silently stop working, which is worse than a loud refusal.
    --
    -- The behaviour being replaced is that the second registration overwrote the
    -- first: `zones[name]` and the grid entry both became the new zone, so
    -- `remove('shop')` removed the SECOND resource's zone while the first
    -- resource's kept firing from a record nothing could reach. Two resources, one
    -- name, and neither able to see the other.
    --
    -- The SAME owner re-creating its own zone is the update path, not a conflict,
    -- and is explicitly allowed -- refusing it would break every resource that
    -- rebuilds a zone on a reconfigure, which is the common case.
    -- Read HERE, before anything can yield or reach another resource: this is the
    -- only point at which GetInvokingResource() still names the caller.
    local zoneOwner = GetInvokingResource() or 'cis_libs'
    local holder = zones[name] and zones[name].owner
    if holder and holder ~= zoneOwner then
        return false, ('zone %q is already registered by %s; pick a different name')
            :format(name, tostring(holder))
    end
    -- A BOX WITH NO SIZE IS REFUSED, NOT DEFAULTED (L-C24).
    --
    -- `size` arrives from a consumer's exports call, and the boundary can drop a
    -- value entirely. Indexing the nil raised inside this file -- so the stack
    -- trace landed in the CONSUMER's log naming a file it does not own, for a
    -- mistake the caller could have been told about in a return value.
    if kind == 'box' and (b == nil) then
        return false, 'a box zone needs a size; it arrived as nil'
    end
    if zones[name] then
        CisZonesRemove(name)
    end
    local zone = {
        name = name,
        kind = kind,
        -- L-C7: recorded so a consumer's stop can take its zones with it.
        owner = zoneOwner,
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

    -- L-C14 · THE INSIDE INTERVAL IS CLAMPED, AND A CLIENT-SIDE OPTION EXISTS.
    --
    -- `insideEvent` is dispatched with TriggerServerEvent, so a zone created
    -- with `insideInterval = 0` and an `insideEvent` fired that event EVERY
    -- FRAME -- and the second thread below runs on `Wait(0)` while any such zone
    -- is active, so a player standing in one produced 60 net events a second,
    -- per zone, aimed at the server's rate limiter. The author's intent with an
    -- interval of 0 is "as often as possible", and on a client-side `inside`
    -- callback that is a legitimate thing to ask for; aimed at the SERVER it is
    -- only ever a client-side flood, whatever the caller meant by it.
    --
    -- So: 250ms is the floor whenever an `insideEvent` is set, because that is
    -- the fastest a server-side event can be useful; a client-side `inside`
    -- function keeps whatever interval the caller asked for, including 0.
    if zone.insideEvent then
        -- `local` is a Lua keyword, so this key is read with brackets. A
        -- consumer writes `local = true` in its options table, which is
        -- ordinary Lua on their side; only the READ of that key is bracketed
        -- here, and only because `zone.local` would not parse.
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
        -- L-C24: an unknown kind is a refusal WITH A REASON. A bare `false`
        -- leaves a caller with nothing to print and nowhere to look: the kind
        -- came from their own code, so the reason has to name what they passed
        -- and what the three accepted values are.
        return false, ('unknown zone kind %q; valid kinds are box, poly and sphere')
            :format(tostring(kind))
    end

    register(zone)
    return true
end

function CisZonesRemove(name)
    if not zones[name] then
        return false
    end
    if inside[name] then
        -- WITH COORDINATES. The `onExit` call passed none, and `invoke` only
        -- reaches `TriggerServerEvent` when it has coords to send -- so removing
        -- a zone the player was standing in silently skipped the `onExitEvent`
        -- and the consumer's "player left" handler never ran. A function cannot
        -- cross the exports boundary, so `onExitEvent` is the ONLY way a
        -- consumer learns about it, and this was the one route that lost it.
        -- The zone's own centre is what the enter side would have reported, so
        -- the pair still describes the same place.
        local zone = zones[name]
        invoke(zone, 'onExit', { x = zone.cx, y = zone.cy, z = zone.cz })
        inside[name] = nil
    end
    CisGrid.remove(grid, name)
    zones[name] = nil
    -- Removed the ordinary way, so the ledger stops owing it. Without this the
    -- name stays attributed to its owner for the life of the process, and the
    -- sweep below would try to remove a zone that is already gone.
    CisOwned.forget(owned, 'zone', name)
    return true
end

function CisZonesContains(name, point)
    local zone = zones[name]
    if not zone then
        return false
    end
    -- L-C24: a point the boundary dropped must be a `false`, not a throw. Both
    -- a nil name and a nil point arrive the same way and mean the same thing to
    -- a caller: they did not get their argument through.
    local p = asVec3(point)
    if not p then
        return false
    end
    return contains(zone, p)
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

-- A CONSUMER THAT STOPS TAKES ITS ZONES WITH IT (L-C7).
--
-- The exit event fires FIRST, and that ordering is the point. A zone's
-- `onExitEvent` is the only way a consumer learns the player left -- a function
-- cannot cross the exports boundary -- so sweeping the zone without firing it
-- would leave a consumer believing its player is still inside a shop. It is
-- strictly worse than leaking the zone, and it is the order a careless
-- implementation gets wrong.
--
-- Guarded against cis_libs's OWN stop: at that point every client is going
-- away and firing server events for zones nobody will ever hear about is noise
-- on a resource that is mid-shutdown.
onClientResourceStop(function(resource)
    if resource == GetCurrentResourceName() then
        return
    end
    local freed = CisOwned.release(owned, resource)
    for i = 1, #freed do
        if freed[i].kind == 'zone' then
            -- Under pcall: `onExitEvent` is a TriggerServerEvent into a resource
            -- that has already stopped, and an error there must not abandon the
            -- rest of the sweep and leak every zone after the first.
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
