-- Server-side zones. Containment is CisZoneGeom, the same math the client
-- uses. Ped coords come from the server (GetPlayerPed / GetEntityCoords),
-- so a client's "I am inside" claim is never trusted.
--
-- Ids are numbers this file allocates and never reuses, same as points.

local zones = {}
local nextId = 0
local owned = CisOwned.new()

local function asPoint(p)
    if p == nil then
        return nil
    end
    if type(p.x) == 'number' and type(p.y) == 'number' then
        return { x = p.x, y = p.y, z = type(p.z) == 'number' and p.z or 0.0 }
    end
    return nil
end

local function ownerNow()
    return GetInvokingResource() or 'cis_libs'
end

local function makeBox(center, size, opts)
    local c = asPoint(center)
    if not c then
        return nil, 'center is not a point'
    end
    local sx, sy, sz
    if type(size) == 'number' then
        sx, sy, sz = size, size, size
    elseif type(size) == 'table' then
        sx = size.x or size[1]
        sy = size.y or size[2] or sx
        sz = size.z or size[3] or sy
    end
    if type(sx) ~= 'number' or sx <= 0 then
        return nil, 'size must be a positive number or vector'
    end
    opts = opts or {}
    return {
        kind = 'box',
        cx = c.x, cy = c.y, cz = c.z,
        hx = sx * 0.5, hy = sy * 0.5, hz = sz * 0.5,
        heading = tonumber(opts.heading) or 0.0,
        onEnterEvent = opts.onEnterEvent,
        onExitEvent = opts.onExitEvent,
        inside = {},
    }
end

local function makeSphere(center, radius, opts)
    local c = asPoint(center)
    if not c then
        return nil, 'center is not a point'
    end
    radius = tonumber(radius)
    if not radius or radius <= 0 or radius ~= radius then
        return nil, 'radius must be a positive finite number'
    end
    opts = opts or {}
    return {
        kind = 'sphere',
        cx = c.x, cy = c.y, cz = c.z,
        radius = radius,
        onEnterEvent = opts.onEnterEvent,
        onExitEvent = opts.onExitEvent,
        inside = {},
    }
end

local function makePoly(points, opts)
    if type(points) ~= 'table' or #points < 3 then
        return nil, 'poly needs at least 3 points'
    end
    local out = {}
    for i = 1, #points do
        local p = asPoint(points[i])
        if not p then
            return nil, ('point %s is not a coordinate'):format(tostring(i))
        end
        out[i] = p
    end
    opts = opts or {}
    return {
        kind = 'poly',
        points = out,
        minZ = tonumber(opts.minZ) or -1000.0,
        maxZ = tonumber(opts.maxZ) or 1000.0,
        onEnterEvent = opts.onEnterEvent,
        onExitEvent = opts.onExitEvent,
        inside = {},
    }
end

local function insert(zone)
    nextId = nextId + 1
    zone.id = nextId
    zone.owner = ownerNow()
    zones[zone.id] = zone
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

function CisServerZoneRemove(id)
    local zone = zones[id]
    if not zone then
        return false, 'no such zone'
    end
    local who = ownerNow()
    if zone.owner ~= who and who ~= 'cis_libs' then
        return false, 'not the owner'
    end
    zones[id] = nil
    CisOwned.forget(owned, 'serverZone', id)
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

local function fire(event, src, zone)
    if type(event) ~= 'string' or event == '' then
        return
    end
    TriggerEvent(event, zone.id, src)
end

CreateThread(function()
    local tick = CisLoopGuard.Body('server.zones.pass', function()
        local players = GetPlayers()
        local present = {}
        for i = 1, #players do
            local src = tonumber(players[i])
            if src then
                present[src] = true
                local coords = playerCoords(src)
                if coords then
                    for _, zone in pairs(zones) do
                        local nowIn = CisZoneGeom.contains(zone, coords)
                        local wasIn = zone.inside[src] == true
                        if nowIn and not wasIn then
                            zone.inside[src] = true
                            fire(zone.onEnterEvent, src, zone)
                        elseif wasIn and not nowIn then
                            zone.inside[src] = nil
                            fire(zone.onExitEvent, src, zone)
                        end
                    end
                end
            end
        end
        for _, zone in pairs(zones) do
            for src in pairs(zone.inside) do
                if not present[src] then
                    zone.inside[src] = nil
                end
            end
        end
        return 500
    end)
    while true do
        Wait(tick() or 500)
    end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        return
    end
    local freed = CisOwned.release(owned, resource)
    for i = 1, #freed do
        if freed[i].kind == 'serverZone' then
            zones[freed[i].id] = nil
            CisOwned.forget(owned, 'serverZone', freed[i].id)
        end
    end
end)

exports('ServerZoneBox', CisServerZoneBox)
exports('ServerZoneSphere', CisServerZoneSphere)
exports('ServerZonePoly', CisServerZonePoly)
exports('ServerZoneContains', CisServerZoneContains)
exports('ServerZonePlayers', CisServerZonePlayers)
exports('ServerZoneRemove', CisServerZoneRemove)
