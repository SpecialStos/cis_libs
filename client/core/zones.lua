-- The zone ENGINE. Grid discovery, containment, enter/exit/inside, debug draw.
--
-- ONE SOURCE, TWO VMS. This file holds no state at file scope: every zone set is
-- an instance made by `M.new(cfg)`. cis_libs runs it as a client_script and
-- client/zones.lua wraps one instance behind the CreateZone export (owner
-- tracking, name collisions, the stop sweep). A consumer gets ITS OWN instance
-- through init.lua (`Cis.zones.*`), loaded from this same text, so its handlers
-- are plain local functions and its zones survive a cis_libs restart.
--
-- cfg:
--   grid, geom   CisGrid and CisZoneGeom (the consumer passes its own copies)
--   coords()     the player's coords, memoised per frame by the caller
--   callable(v)  whether a handler can be called (cis_libs also takes funcrefs)
--   log(level, message)
--   guard(name, body) -> tick   wraps a loop body (CisLoopGuard.Body in cis_libs)
--   admit(name, held, owner)    -> ok, why   a refusal hook run before a create
--   onRegister(zone), onRemove(zone)   owner bookkeeping for the wrapper
--   timing       CisTiming or nil
--   autoDrive    true: the instance runs its own thread, ONLY while zones exist
--   awaitReady() optional; the driven thread calls it once before its first pass

local M = {}

-- Cadence for discovery: a one-cell grid query plus a sweep of what we are inside.
-- Bounded by the zones near the player, not by how many exist, so it runs for a
-- standing player too -- the only way one who stands still is ever found.
local RECHECK_MS = 200
-- Debug outlines further than this from the player are not drawn: a debug zone
-- across the map cost a frame of DrawLine calls for something nobody can see.
local DEBUG_DRAW_RANGE = 150.0

-- THE FLOOR FOR AN `insideEvent`, and the reason it exists.
local MIN_EVENT_INTERVAL_MS = 250

local Zones = {}
Zones.__index = Zones

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

-- A plain function, or a funcref table carrying `__cfx_functionReference`.
local function defaultCallable(v)
    if type(v) == 'function' then
        return true
    end
    return type(v) == 'table' and rawget(v, '__cfx_functionReference') ~= nil
end

local function noop() end

function M.new(cfg)
    cfg = cfg or {}
    local self = setmetatable({
        grid = cfg.grid.new(),
        Grid = cfg.grid,
        Geom = cfg.geom,
        coordsOf = cfg.coords,
        callable = cfg.callable or defaultCallable,
        log = cfg.log or noop,
        guard = cfg.guard or function(_, body) return body end,
        admit = cfg.admit,
        onRegister = cfg.onRegister or noop,
        onRemove = cfg.onRemove or noop,
        timing = cfg.timing,
        autoDrive = cfg.autoDrive == true,
        awaitReady = cfg.awaitReady,
        -- The resource local events are fired as, when other resources' zones
        -- share this instance (cis_libs'). Unset in a consumer's own VM.
        localEventsAs = cfg.localEventsAs,
        zones = {},
        inside = {},
        -- Set by any create or remove, so the next pass runs discovery at once.
        zonesDirty = true,
        lastRefresh = nil,
        passStamp = 0,
        driving = false,
        drawThreadStarted = false,
        debugStats = {
            lastPassMs = 0,
            lastPassAt = 0,
            -- Whether the draw thread is running right now.
            debugDrawing = false,
        },
    }, Zones)
    return self
end

-- A Lua callback cannot be sent across the exports boundary: an options table carrying
function Zones:invoke(zone, name, ...)
    local fn = zone[name]
    -- callable: a consumer's handler is a funcref table, and anything else that
    -- is merely truthy would raise inside the pcall on every pass.
    if self.callable(fn) then
        local ok, err = pcall(fn, zone, ...)
        if not ok then
            self.log('error', ('zone %s %s: %s'):format(zone.name, name, err))
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
                self.log('error', ('zone %s event %s: %s'):format(zone.name, eventName, err))
            end
        end
    end
end

function Zones:register(zone)
    -- The grid goes FIRST, so a refusal cannot leave a zone recorded that no query can
    local ok, why = self.Grid.insert(self.grid, zone.name, zone.aabb, zone)
    if not ok then
        return false, why
    end
    self.zones[zone.name] = zone
    -- The OWNER, captured at creation.
    self.onRegister(zone)
    return true
end

function Zones:get(name)
    return self.zones[name]
end

function Zones:hasZones()
    return next(self.zones) ~= nil
end

local function finite(v)
    return type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge
end

local function positive(v)
    return finite(v) and v > 0
end

local EVENT_KEYS = { 'onEnterEvent', 'onExitEvent', 'insideEvent' }
local MAX_EVENT_NAME = 128

-- A LOCAL EVENT IS FIRED AS THIS VM. In cis_libs' shared instance that is
-- cis_libs, and handlers that trust an invoker of cis_libs (the cache mirror,
-- CisRealStop for a stop of cis_libs) would take a zone named 'vehicle' firing
-- 'cis_libs:cache', or one named 'cis_libs' firing 'onResourceStop', as the
-- library itself. So there, another resource's zone may only fire local events
-- under its own '<owner>:' prefix. A server event carries no such identity: the
-- server sees the player, as it would from any client script.
function Zones:eventNameOk(eventName, isLocal, owner)
    if eventName == nil then
        return true
    end
    if type(eventName) ~= 'string' or eventName == '' or #eventName > MAX_EVENT_NAME then
        return false, ('must be a non-empty string of at most %d bytes, got %s')
            :format(MAX_EVENT_NAME, type(eventName) == 'string' and ('%d bytes'):format(#eventName) or type(eventName))
    end
    local as = self.localEventsAs
    if isLocal and as and type(owner) == 'string' and owner ~= as then
        local prefix = owner .. ':'
        if eventName:sub(1, #prefix) ~= prefix then
            return false, ('%q is a local event fired as %s, so it must start with %q')
                :format(eventName, as, prefix)
        end
    end
    return true
end

function Zones:create(kind, name, a, b, options, owner)
    -- Every refusal returns a reason as a second value.
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
    if self.admit then
        local admitted, why = self.admit(name, self.zones[name], owner)
        if not admitted then
            return false, why
        end
    end
    -- A BOX WITH NO SIZE IS REFUSED, NOT DEFAULTED ().
    if kind == 'box' and (b == nil) then
        return false, 'a box zone needs a size; it arrived as nil'
    end
    -- The old zone of this name is removed only once the new one is known to be
    -- good (below): re-creating 'shop' with a bad point list returned false and
    -- had already destroyed the live 'shop'.
    local zone = {
        name = name,
        kind = kind,
        -- recorded so a consumer's stop can take its zones with it.
        owner = owner,
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
    -- `local` is a Lua keyword, so this key is read with brackets. It applies to
    -- all three events; it used to be read only when insideEvent was set, so an
    -- onEnterEvent meant for this client went to the server.
    zone['local'] = options['local'] == true
    for _, key in ipairs(EVENT_KEYS) do
        local ok, why = self:eventNameOk(zone[key], zone['local'], owner)
        if not ok then
            return false, ('zone %q: %s %s'):format(name, key, why)
        end
    end

    local interval = zone.insideInterval
    if interval ~= nil and (type(interval) ~= 'number' or interval ~= interval or interval < 0) then
        return false, ('insideInterval must be a number of milliseconds, got %s'):format(tostring(interval))
    end
    -- THE INSIDE INTERVAL IS CLAMPED, AND A CLIENT-SIDE OPTION EXISTS.
    if zone.insideEvent then
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
        local minZ, maxZ = options.minZ, options.maxZ
        -- THICKNESS, as ox_lib's poly has it: a slab that tall around the points'
        -- average z. Without it a ported zone spanned z -1000 to 10000, so every
        -- floor of a building was inside. minZ/maxZ given explicitly still win.
        local thickness = options.thickness
        if thickness ~= nil then
            if type(thickness) ~= 'number' or thickness ~= thickness or thickness <= 0 then
                return false, ('poly zone %q: thickness must be a positive number, got %s')
                    :format(name, tostring(thickness))
            end
            if minZ == nil and maxZ == nil and #points > 0 then
                local sum = 0.0
                for i = 1, #points do
                    sum = sum + points[i].z
                end
                local mid = sum / #points
                minZ, maxZ = mid - thickness * 0.5, mid + thickness * 0.5
            end
        end
        zone.minZ = minZ or -1000.0
        zone.maxZ = maxZ or 10000.0
        -- A ZONE THAT CAN CONTAIN NOTHING IS REFUSED: two points have no area,
        -- and a slab with minZ above maxZ has no height. Both used to register
        -- and then never fire.
        if #points < 3 and #points > 0 then
            return false, ('poly zone %q: needs at least 3 points, got %d'):format(name, #points)
        end
        if not finite(zone.minZ) or not finite(zone.maxZ) or zone.minZ >= zone.maxZ then
            return false, ('poly zone %q: minZ (%s) must be a number below maxZ (%s)')
                :format(name, tostring(zone.minZ), tostring(zone.maxZ))
        end
        -- A poly zone with no points, or a point that did not survive the
        local box, boxWhy = self.Grid.aabbFromPoints(points, zone.minZ, zone.maxZ, 0.5)
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
        if not (positive(sx) and positive(sy) and positive(sz)) then
            return false, ('box zone %q: every size axis must be a positive number, got %s, %s, %s')
                :format(name, tostring(sx), tostring(sy), tostring(sz))
        end
        local heading = options.heading or options.rotation or 0.0
        if not finite(heading) then
            return false, ('box zone %q: heading must be a number of degrees, got %s'):format(name, tostring(heading))
        end
        zone.cx, zone.cy, zone.cz = center.x, center.y, center.z
        zone.hx, zone.hy, zone.hz = sx * 0.5, sy * 0.5, sz * 0.5
        zone.heading = heading
        -- THE INDEX BOX OF A ROTATED BOX IS THE ROTATED FOOTPRINT'S BOUNDS. The
        -- unrotated half-extents leave the corners of a turned box outside the
        -- index, and a player standing in a corner is never a candidate -- part
        -- of the zone that never triggers.
        local rad = math.rad(zone.heading)
        local c, s = math.abs(math.cos(rad)), math.abs(math.sin(rad))
        local ex = zone.hx * c + zone.hy * s
        local ey = zone.hx * s + zone.hy * c
        zone.aabb = self.Grid.aabbFromCenter(zone.cx, zone.cy, zone.cz, ex + 0.5, ey + 0.5, zone.hz + 0.5)
    elseif kind == 'sphere' then
        local center = asVec3(a)
        zone.cx, zone.cy, zone.cz = center.x, center.y, center.z
        zone.radius = b or 1.0
        if not positive(zone.radius) then
            return false, ('sphere zone %q: radius must be a positive number, got %s'):format(name, tostring(zone.radius))
        end
        zone.aabb = self.Grid.aabbFromCenter(zone.cx, zone.cy, zone.cz, zone.radius, zone.radius, zone.radius)
    else
        -- an unknown kind is a refusal WITH A REASON.
        return false, ('unknown zone kind %q; valid kinds are box, poly and sphere')
            :format(tostring(kind))
    end

    local fits, fitWhy = self.Grid.admits(zone.aabb)
    if not fits then
        return false, ('zone %q: %s'):format(name, tostring(fitWhy))
    end
    if self.zones[name] then
        self:remove(name)
    end
    local registered, registerWhy = self:register(zone)
    if not registered then
        return false, registerWhy
    end
    -- AFTER a successful registration, so a refused zone cannot start a thread that
    self.zonesDirty = true
    if self.autoDrive then
        self:drive()
    end
    if zone.debug then
        self:ensureDebugDraw()
    end
    return true
end

function Zones:hasDebugZone()
    for _, zone in pairs(self.zones) do
        if zone.debug then
            return true
        end
    end
    return false
end

-- Always running would spend a frame drawing nothing on every server that has no debug
function Zones:startDebugDraw()
    if self.drawThreadStarted then
        return
    end
    self.drawThreadStarted = true
    local debugStats = self.debugStats
    debugStats.debugDrawing = true
    CreateThread(function()
        local tick = self.guard('client.zones.draw', function()
            local coords = self.coordsOf()
            for _, zone in pairs(self.zones) do
                if zone.debug then
                    -- Culled by the index box, so a large zone the player is near
                    -- still draws while one across the map costs nothing.
                    local b = zone.aabb
                    local dx = math.max(b.minX - coords.x, 0.0, coords.x - b.maxX)
                    local dy = math.max(b.minY - coords.y, 0.0, coords.y - b.maxY)
                    if dx * dx + dy * dy <= DEBUG_DRAW_RANGE * DEBUG_DRAW_RANGE then
                        self:drawZone(zone, coords)
                    end
                end
            end
            -- NO SLEEP HERE. The body decides when it next runs, so a frame that drew
        end)
        while true do
            tick()
            -- AND STOP AS SOON AS THE LAST ONE GOES.
            if not self:hasDebugZone() then
                debugStats.debugDrawing = false
                self.drawThreadStarted = false
                return
            end
            Wait(0)
        end
    end)
end

function Zones:ensureDebugDraw()
    if self:hasDebugZone() then
        self:startDebugDraw()
    end
end

-- ONE ZONE, ONE SHAPE. Box and poly draw their outline with translucent walls between
function Zones:drawZone(zone, coords)
    local inZone = zone ~= nil and self.inside[zone.name] ~= nil
    local colour = inZone and { 0, 255, 0, 200 } or { 255, 0, 0, 160 }

    if zone.kind == 'sphere' then
        -- DRAW_MARKER: type, pos xyz, dir xyz, rot xyz, SCALE xyz, r, g, b, a,
        -- bob, faceCamera, p19, rotate, textureDict, textureName, drawOnEnts.
        -- Type 28 is the debug sphere, whose scale is its radius. The old call
        -- passed the alpha as scaleY and shifted every colour one slot left.
        DrawMarker(28, zone.cx, zone.cy, zone.cz, 0.0, 0.0, 0.0,
            0.0, 0.0, 0.0, zone.radius + 0.0, zone.radius + 0.0, zone.radius + 0.0,
            colour[1], colour[2], colour[3], 80,
            false, false, 2, false, nil, nil, false)
        return
    end

    -- A box's own height, not a guess: minZ/maxZ belong to poly zones.
    local minZ = zone.minZ or (zone.cz - (zone.hz or 5.0))
    local maxZ = zone.maxZ or (zone.cz + (zone.hz or 5.0))
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

    -- The four corners, TURNED BY THE HEADING the containment test uses
    -- (CisGrid.pointInBox rotates the point by -heading, so a corner is rotated by
    -- +heading). The outline used to be the unrotated box, which is not the zone.
    local rad = math.rad(zone.heading or 0.0)
    local c, s = math.cos(rad), math.sin(rad)
    local hx, hy = zone.hx, zone.hy
    local ax, ay = zone.cx - hx * c + hy * s, zone.cy - hx * s - hy * c
    local bx, by = zone.cx + hx * c + hy * s, zone.cy + hx * s - hy * c
    local qx, qy = zone.cx + hx * c - hy * s, zone.cy + hx * s + hy * c
    local dx, dy = zone.cx - hx * c - hy * s, zone.cy - hx * s + hy * c
    local r, g, b = colour[1], colour[2], colour[3]
    -- The footprint, at both heights, and the four uprights.
    DrawLine(ax, ay, minZ, bx, by, minZ, r, g, b, 255)
    DrawLine(bx, by, minZ, qx, qy, minZ, r, g, b, 255)
    DrawLine(qx, qy, minZ, dx, dy, minZ, r, g, b, 255)
    DrawLine(dx, dy, minZ, ax, ay, minZ, r, g, b, 255)
    DrawLine(ax, ay, maxZ, bx, by, maxZ, r, g, b, 255)
    DrawLine(bx, by, maxZ, qx, qy, maxZ, r, g, b, 255)
    DrawLine(qx, qy, maxZ, dx, dy, maxZ, r, g, b, 255)
    DrawLine(dx, dy, maxZ, ax, ay, maxZ, r, g, b, 255)
    DrawLine(ax, ay, minZ, ax, ay, maxZ, r, g, b, 255)
    DrawLine(bx, by, minZ, bx, by, maxZ, r, g, b, 255)
    DrawLine(qx, qy, minZ, qx, qy, maxZ, r, g, b, 255)
    DrawLine(dx, dy, minZ, dx, dy, maxZ, r, g, b, 255)
    if coords and zone.hx and zone.hy then
        -- A cross at the centre, so an operator can see which point the zone was
        DrawLine(zone.cx - 0.5, zone.cy, minZ, zone.cx + 0.5, zone.cy, minZ,
            255, 255, 0, 255)
        DrawLine(zone.cx, zone.cy - 0.5, minZ, zone.cx, zone.cy + 0.5, minZ,
            255, 255, 0, 255)
    end
end

-- The removal itself, with no owner check: the stop sweep and a same-owner
-- re-create use it directly. The wrapper's CisZonesRemove is the checked entry point.
function Zones:remove(name)
    local zones = self.zones
    if not zones[name] then
        return false
    end
    if self.inside[name] then
        -- THE PLAYER'S COORDS, not the zone's.
        local zone = zones[name]
        local ped = PlayerPedId()
        local p = GetEntityCoords(ped)
        local coords = (p and p.x ~= nil)
            and { x = p.x, y = p.y, z = p.z }
            or { x = zone.cx, y = zone.cy, z = zone.cz }
        self:invoke(zone, 'onExit', coords)
        self.inside[name] = nil
    end
    local zone = zones[name]
    self.Grid.remove(self.grid, name)
    zones[name] = nil
    -- Removed the ordinary way, so the ledger stops owing it.
    self.onRemove(zone)
    self.zonesDirty = true
    -- The draw thread notices on its next pass, one frame later.
    return true
end

function Zones:contains(name, point)
    local zone = self.zones[name]
    if not zone then
        return false
    end
    -- a point the boundary dropped must be a `false`, not a throw.
    local p = asVec3(point)
    if not p then
        return false
    end
    return self.Geom.contains(zone, p)
end

-- DISCOVERY WITHOUT ALLOCATION. The pass used to build a `seen` table on every
-- refresh; a stamp on each inside-state does the same job. The visitor is a
-- file-level function so the query does not allocate a closure either: the
-- instance and the coords it needs ride in two upvalues set around the query.
local visitSelf, visitCoords
local function visitZone(id, item)
    local self = visitSelf
    local zone = item.data
    local inside = self.inside
    local state = inside[id]
    if self.Geom.contains(zone, visitCoords) then
        if state then
            state.stamp = self.passStamp
        else
            inside[id] = { lastInside = 0, stamp = self.passStamp }
            self:invoke(zone, 'onEnter', visitCoords)
        end
    elseif state then
        inside[id] = nil
        self:invoke(zone, 'onExit', visitCoords)
    end
end

function Zones:refreshInside(coords)
    self.passStamp = self.passStamp + 1
    visitSelf, visitCoords = self, coords
    -- queryPoint is sufficient: insert() registers an id in every cell its AABB
    -- overlaps, so the player's own cell holds every zone that can contain them.
    self.Grid.queryPoint(self.grid, coords.x, coords.y, coords.z, visitZone)
    visitSelf, visitCoords = nil, nil
    -- Inside, but not a candidate this pass: the player left its index box.
    local inside = self.inside
    for id, state in pairs(inside) do
        if state.stamp ~= self.passStamp then
            local zone = self.zones[id]
            inside[id] = nil
            if zone then
                self:invoke(zone, 'onExit', coords)
            end
        end
    end
end

-- One pass. Answers the interval the next Wait should use.
function Zones:pass()
    local timing = self.timing
    if next(self.zones) == nil then
        local tIdle = timing and timing.now()
        if timing and tIdle ~= nil then
            timing.observe('zonePass', timing.now() - tIdle)
        end
        -- Returned, never waited on inside the guard: see the note on the loop.
        return 500
    end
    local debugStats = self.debugStats
    local started = GetGameTimer()
    local t0 = timing and timing.now()
    local coords = self.coordsOf()
    -- Discovery on any change to the zone set, and every RECHECK_MS. There is no
    -- movement gate: the old one refreshed whenever fewer zones were inside than
    -- existed -- always -- after counting every zone to find that out.
    if self.zonesDirty or self.lastRefresh == nil or started - self.lastRefresh >= RECHECK_MS then
        self.zonesDirty = false
        self.lastRefresh = started
        self:refreshInside(coords)
    end

    local now = GetGameTimer()
    local waitMs = 250
    for id, state in pairs(self.inside) do
        local zone = self.zones[id]
        if zone and (zone.inside or zone.insideEvent) then
            local interval = zone.insideInterval or 500
            if interval > 0 then
                if now - state.lastInside >= interval then
                    state.lastInside = now
                    self:invoke(zone, 'inside', coords)
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
    if timing and t0 ~= nil then
        timing.observe('zonePass', timing.now() - t0)
    end
    -- THE INTERVAL IS RETURNED, NOT WAITED ON HERE.
    return waitMs
end

-- The per-frame half: zones that asked for `insideInterval = 0`. Answers 0 while
-- one is being served and 250 otherwise.
function Zones:insidePass()
    local drew = false
    local coords
    for id in pairs(self.inside) do
        local zone = self.zones[id]
        if zone and (zone.inside or zone.insideEvent) and (zone.insideInterval or 500) <= 0 then
            coords = coords or self.coordsOf()
            self:invoke(zone, 'inside', coords)
            drew = true
        end
    end
    return drew and 0 or 250
end

-- THE DRIVER. One thread, started by the first create and ended by
-- the pass that finds the set empty, so a resource with no zones runs nothing.
-- cis_libs uses it too: client/zones.lua builds its engine with autoDrive.
function Zones:drive()
    if self.driving then
        return
    end
    self.driving = true
    CreateThread(function()
        if self.awaitReady then
            self.awaitReady()
        end
        local tick = self.guard('zones.pass', function() return self:pass() end)
        local tickInside = self.guard('zones.inside', function() return self:insidePass() end)
        while next(self.zones) ~= nil do
            local a = tick() or 250
            local b = tickInside() or 250
            Wait(a < b and a or b)
        end
        self.driving = false
    end)
end

-- Sorted names of the zones the player is inside, built on request only.
-- `owner` limits it to one resource's zones.
function Zones:insideNames(owner)
    local names = {}
    for id in pairs(self.inside) do
        local zone = self.zones[id]
        if zone and (owner == nil or zone.owner == owner) then
            names[#names + 1] = id
        end
    end
    table.sort(names)
    return names
end

-- Sorted names of every zone, or one resource's.
function Zones:allNames(owner)
    local names = {}
    for id, zone in pairs(self.zones) do
        if owner == nil or zone.owner == owner then
            names[#names + 1] = id
        end
    end
    table.sort(names)
    return names
end

-- Sorted names of the zones whose footprint comes within `radius` metres of
-- `coords` on the ground plane (default: the player, 50 m).
function Zones:nearbyNames(coords, radius, owner)
    coords = coords or self.coordsOf()
    radius = radius or 50.0
    local names = {}
    if not coords or type(radius) ~= 'number' or radius ~= radius or radius < 0 then
        return names
    end
    local r2 = radius * radius
    for id, zone in pairs(self.zones) do
        local box = zone.aabb
        if box and (owner == nil or zone.owner == owner) then
            local dx = math.max(box.minX - coords.x, 0.0, coords.x - box.maxX)
            local dy = math.max(box.minY - coords.y, 0.0, coords.y - box.maxY)
            if dx * dx + dy * dy <= r2 then
                names[#names + 1] = id
            end
        end
    end
    table.sort(names)
    return names
end

M.RECHECK_MS = RECHECK_MS
M.MIN_EVENT_INTERVAL_MS = MIN_EVENT_INTERVAL_MS

-- A MODULE. Run as one of cis_libs' client_scripts it publishes itself under
-- CisCore; loaded by a consumer through init.lua it only returns.
if ... ~= 'cis_require' then
    CisCore = CisCore or {}
    CisCore.zones = M
end

return M
