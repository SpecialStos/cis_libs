-- Server-side zones. Containment is CisZoneGeom, the same math the client
-- uses. Ped coords come from the server (GetPlayerPed / GetEntityCoords),
-- so a client's "I am inside" claim is never trusted.
--
-- Ids are numbers this file allocates and never reuses, same as points.
--
-- THE PASS IS INDEXED. It used to test every player against every zone every
-- 500 ms: 200 players x 500 zones is 100,000 containment tests a pass, almost
-- all of them for zones on the other side of the map. Zones now sit in a CisGrid
-- by their bounding box, so a player is tested only against the zones whose box
-- covers the cell they stand in, and only after a cheap AABB check (z included).
--
-- WHICH WORLD. A zone belongs to ONE routing bucket (opts.bucket, default 0, the
-- main world) and a player in another bucket is never inside it -- a zone at the
-- bank does not fire for a player in an instanced copy of the bank.
--
-- EXITS ARE OWED. A player who drops, and every player inside a zone that is
-- removed (by its owner, or because the owner stopped), gets the exit event. A
-- consumer that pairs enter/exit -- a counter, a buff, a UI -- otherwise leaks.

local zones = {}
local nextId = 0
local owned = CisOwned.new()

-- The spatial index, plus the zones too large for it (scanned every pass).
local zoneGrid = CisGrid.new()
local unindexed = {}

-- src -> { [zoneId] = true }: what each player is inside, for drop and removal.
local insideOf = {}

local PASS_MS = 500

local function finite(v)
    return type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge
end

local function asPoint(p)
    if p == nil then
        return nil
    end
    local t = type(p)
    if t ~= 'table' and t ~= 'vector3' and t ~= 'vector4' and t ~= 'vector2' then
        return nil
    end
    if not (finite(p.x) and finite(p.y)) then
        return nil
    end
    local z = p.z
    if z == nil then
        z = 0.0
    elseif not finite(z) then
        return nil
    end
    return { x = p.x, y = p.y, z = z }
end

local function ownerNow()
    return GetInvokingResource() or 'cis_libs'
end

-- A routing bucket: a non-negative whole number, 0 when not given.
local function bucketOf(opts)
    local b = opts.bucket
    if b == nil then
        return 0
    end
    b = tonumber(b)
    if not b or b ~= b or b < 0 or b % 1 ~= 0 then
        return nil, 'bucket must be a non-negative whole number'
    end
    return b
end

local function common(zone, opts)
    local bucket, why = bucketOf(opts)
    if not bucket then
        return nil, why
    end
    zone.bucket = bucket
    zone.onEnterEvent = opts.onEnterEvent
    zone.onExitEvent = opts.onExitEvent
    zone.inside = {}
    return zone
end

local function positive(v)
    return finite(v) and v > 0
end

local function makeBox(center, size, opts)
    local c = asPoint(center)
    if not c then
        return nil, 'center is not a finite point'
    end
    local sx, sy, sz
    if type(size) == 'number' then
        sx, sy, sz = size, size, size
    elseif type(size) == 'table' or type(size) == 'vector3' then
        sx = size.x or size[1]
        sy = size.y or size[2] or sx
        sz = size.z or size[3] or sy
    end
    -- ALL THREE. Only x was checked, so a size of { 4, -1, 0/0 } built a box no
    -- point could ever be inside, which looks exactly like a zone that works.
    if not (positive(sx) and positive(sy) and positive(sz)) then
        return nil, 'size must be a positive finite number or vector (x, y and z)'
    end
    opts = opts or {}
    local heading = tonumber(opts.heading) or 0.0
    if not finite(heading) then
        return nil, 'heading must be a finite number'
    end
    local zone = {
        kind = 'box',
        cx = c.x, cy = c.y, cz = c.z,
        hx = sx * 0.5, hy = sy * 0.5, hz = sz * 0.5,
        heading = heading,
    }
    return common(zone, opts)
end

local function makeSphere(center, radius, opts)
    local c = asPoint(center)
    if not c then
        return nil, 'center is not a finite point'
    end
    radius = tonumber(radius)
    if not positive(radius) then
        return nil, 'radius must be a positive finite number'
    end
    opts = opts or {}
    local zone = {
        kind = 'sphere',
        cx = c.x, cy = c.y, cz = c.z,
        radius = radius,
    }
    return common(zone, opts)
end

local function makePoly(points, opts)
    if type(points) ~= 'table' or #points < 3 then
        return nil, 'poly needs at least 3 points'
    end
    local out = {}
    for i = 1, #points do
        local p = asPoint(points[i])
        if not p then
            return nil, ('point %s is not a finite coordinate'):format(tostring(i))
        end
        out[i] = p
    end
    opts = opts or {}
    local minZ = tonumber(opts.minZ) or -1000.0
    local maxZ = tonumber(opts.maxZ) or 1000.0
    if not (finite(minZ) and finite(maxZ)) or minZ > maxZ then
        return nil, 'minZ and maxZ must be finite with minZ <= maxZ'
    end
    local zone = {
        kind = 'poly',
        points = out,
        minZ = minZ,
        maxZ = maxZ,
    }
    return common(zone, opts)
end

-- The box that contains the zone in every orientation, z included.
local function aabbOf(zone)
    if zone.kind == 'sphere' then
        local r = zone.radius
        return CisGrid.aabbFromCenter(zone.cx, zone.cy, zone.cz, r, r, r)
    elseif zone.kind == 'box' then
        -- A rotated box fits inside the circle through its corners.
        local r = math.sqrt(zone.hx * zone.hx + zone.hy * zone.hy)
        return CisGrid.aabbFromCenter(zone.cx, zone.cy, zone.cz, r, r, zone.hz)
    end
    return CisGrid.aabbFromPoints(zone.points, zone.minZ, zone.maxZ, 0)
end

local function index(zone)
    local aabb = aabbOf(zone)
    zone.aabb = aabb
    if aabb and CisGrid.insert(zoneGrid, zone.id, aabb, zone) then
        unindexed[zone.id] = nil
        return
    end
    unindexed[zone.id] = true
end

local function unindex(id)
    CisGrid.remove(zoneGrid, id)
    unindexed[id] = nil
end

local function insert(zone)
    nextId = nextId + 1
    zone.id = nextId
    zone.owner = ownerNow()
    zones[zone.id] = zone
    index(zone)
    CisOwned.track(owned, zone.owner, 'serverZone', zone.id)
    return zone.id
end

function CisServerZoneBox(center, size, opts)
    local zone, why = makeBox(center, size, opts)
    if not zone then
        return false, why
    end
    return insert(zone)
end

function CisServerZoneSphere(center, radius, opts)
    local zone, why = makeSphere(center, radius, opts)
    if not zone then
        return false, why
    end
    return insert(zone)
end

function CisServerZonePoly(points, opts)
    local zone, why = makePoly(points, opts)
    if not zone then
        return false, why
    end
    return insert(zone)
end

function CisServerZoneContains(id, coords)
    local zone = zones[id]
    if not zone then
        return false, 'no such zone'
    end
    local p = asPoint(coords)
    if not p then
        return false, 'coords is not a point'
    end
    return CisZoneGeom.contains(zone, p)
end

function CisServerZonePlayers(id)
    local zone = zones[id]
    if not zone then
        return false, 'no such zone'
    end
    local out = {}
    for src in pairs(zone.inside) do
        out[#out + 1] = src
    end
    table.sort(out)
    return out
end

local function fire(event, src, zone)
    if type(event) ~= 'string' or event == '' then
        return
    end
    TriggerEvent(event, zone.id, src)
end

local function leave(zone, src)
    zone.inside[src] = nil
    local set = insideOf[src]
    if set then
        set[zone.id] = nil
        if next(set) == nil then
            insideOf[src] = nil
        end
    end
    fire(zone.onExitEvent, src, zone)
end

local function enter(zone, src)
    zone.inside[src] = true
    local set = insideOf[src]
    if not set then
        set = {}
        insideOf[src] = set
    end
    set[zone.id] = true
    fire(zone.onEnterEvent, src, zone)
end

-- Take a zone out of the world, and tell everyone who was in it.
local function drop(id)
    local zone = zones[id]
    if not zone then
        return
    end
    zones[id] = nil
    unindex(id)
    CisOwned.forget(owned, 'serverZone', id)
    local who = {}
    for src in pairs(zone.inside) do
        who[#who + 1] = src
    end
    table.sort(who)
    for i = 1, #who do
        leave(zone, who[i])
    end
end

function CisServerZoneRemove(id)
    local zone = zones[id]
    if not zone then
        return false, 'no such zone'
    end
    local who = ownerNow()
    if zone.owner ~= who and who ~= 'cis_libs' then
        return false, 'not the owner'
    end
    drop(id)
    return true
end

local function playerCoords(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then
        return nil
    end
    local c = GetEntityCoords(ped)
    if c == nil or type(c.x) ~= 'number' then
        return nil
    end
    return c
end

local function playerBucket(src)
    local ok, bucket = pcall(GetPlayerRoutingBucket, src)
    return ok and tonumber(bucket) or 0
end

-- One player against the zones near them. Hoisted, not a closure per player.
local passSrc, passCoords, passBucket, passNow

local function consider(id)
    local zone = zones[id]
    if not zone or zone.bucket ~= passBucket then
        return
    end
    local c = passCoords
    local aabb = zone.aabb
    if aabb and (c.x < aabb.minX or c.x > aabb.maxX or c.y < aabb.minY or c.y > aabb.maxY
        or (c.z or 0.0) < aabb.minZ or (c.z or 0.0) > aabb.maxZ) then
        return
    end
    if CisZoneGeom.contains(zone, c) then
        passNow[id] = true
    end
end

local function playerPass(src)
    -- No ped (spawning, switching model): no answer this pass, not "outside".
    local coords = playerCoords(src)
    if not coords then
        return
    end
    local now = {}
    passSrc, passCoords, passBucket, passNow = src, coords, playerBucket(src), now
    CisGrid.queryPoint(zoneGrid, coords.x, coords.y, nil, consider)
    for id in pairs(unindexed) do
        consider(id)
    end
    -- Exits first, so a player crossing from one zone into its neighbour gets the
    -- exit before the enter.
    local was = insideOf[passSrc]
    if was then
        local gone = nil
        for id in pairs(was) do
            if not now[id] then
                gone = gone or {}
                gone[#gone + 1] = id
            end
        end
        if gone then
            table.sort(gone)
            for i = 1, #gone do
                local zone = zones[gone[i]]
                if zone then
                    leave(zone, passSrc)
                end
            end
        end
    end
    local entered = nil
    for id in pairs(now) do
        local zone = zones[id]
        if zone and not zone.inside[passSrc] then
            entered = entered or {}
            entered[#entered + 1] = id
        end
    end
    if entered then
        table.sort(entered)
        for i = 1, #entered do
            enter(zones[entered[i]], passSrc)
        end
    end
end

local leaveAll

local function zonePass()
    if next(zones) == nil then
        return
    end
    local players = GetPlayers()
    local present = {}
    for i = 1, #players do
        local src = tonumber(players[i])
        if src then
            present[src] = true
            playerPass(src)
        end
    end
    -- A player who is gone without a playerDropped this file saw.
    for src in pairs(insideOf) do
        if not present[src] then
            leaveAll(src)
        end
    end
end

CreateThread(function()
    local tick = CisLoopGuard.Body('server.zones.pass', function()
        if CisTiming then
            CisTiming.measure('zonePass', zonePass)
        else
            zonePass()
        end
        return PASS_MS
    end)
    while true do
        Wait(tick() or PASS_MS)
    end
end)

-- A player who leaves the server leaves every zone they were in.
function leaveAll(src)
    local set = insideOf[src]
    if not set then
        return
    end
    local ids = {}
    for id in pairs(set) do
        ids[#ids + 1] = id
    end
    table.sort(ids)
    for i = 1, #ids do
        local zone = zones[ids[i]]
        if zone then
            leave(zone, src)
        end
    end
    insideOf[src] = nil
end

AddEventHandler('playerDropped', function()
    local src = tonumber(source)
    if src then
        leaveAll(src)
    end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        return
    end
    local freed = CisOwned.release(owned, resource)
    for i = 1, #freed do
        if freed[i].kind == 'serverZone' then
            drop(freed[i].id)
        end
    end
end)

exports('ServerZoneBox', CisServerZoneBox)
exports('ServerZoneSphere', CisServerZoneSphere)
exports('ServerZonePoly', CisServerZonePoly)
exports('ServerZoneContains', CisServerZoneContains)
exports('ServerZonePlayers', CisServerZonePlayers)
exports('ServerZoneRemove', CisServerZoneRemove)
