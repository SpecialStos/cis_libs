-- Server-authoritative entity sync. Records are versioned so a dynamic record
-- only rebroadcasts when its data actually changed, instead of every tick.

local records = {}
local seq = 0
local revisions = 0

local function nextId(kind)
    seq = seq + 1
    return ('%s_%s'):format(kind, seq)
end

function CisSyncEnabled()
    return not (Config and Config.Sync and Config.Sync.Enabled == false)
end

-- One pass over connected players, reused across every record in a broadcast
-- tick. Reading coords per (player, record) pair was the dominant cost.
local function playerPositions()
    local out = {}
    for _, id in ipairs(GetPlayers()) do
        local src = tonumber(id)
        local ped = GetPlayerPed(src)
        if ped and ped ~= 0 then
            local pos = GetEntityCoords(ped)
            out[#out + 1] = { src = src, x = pos.x, y = pos.y, z = pos.z }
        end
    end
    return out
end

local function withinRange(positions, coords, radius)
    radius = radius or 80.0
    local r2 = radius * radius
    local list = {}
    for i = 1, #positions do
        local p = positions[i]
        local dx, dy, dz = p.x - coords.x, p.y - coords.y, p.z - coords.z
        if dx * dx + dy * dy + dz * dz <= r2 then
            list[#list + 1] = p.src
        end
    end
    return list
end

local function playersInRange(coords, radius)
    return withinRange(playerPositions(), coords, radius)
end

-- Revision covers the whole record (minus our own bookkeeping fields) so a
-- caller changing any field is never silently dropped.
local function canonical(value, out)
    out = out or {}
    local t = type(value)
    if t ~= 'table' then
        out[#out + 1] = tostring(value)
        return out
    end
    local keys = {}
    for k in pairs(value) do
        if k ~= 'rev' and k ~= 'print' then
            keys[#keys + 1] = k
        end
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do
        out[#out + 1] = tostring(k)
        canonical(value[k], out)
    end
    return out
end

local function fingerprint(data)
    return table.concat(canonical(data), '\30')
end

local function upsert(kind, data)
    if not CisInvokingAllowed() then
        return nil
    end
    if not CisSyncEnabled() then
        return nil
    end
    data = data or {}
    if type(data.coords) ~= 'table' or data.coords.x == nil or data.coords.y == nil then
        Logging.Error('Cis.sync.' .. tostring(kind) .. ' rejected: missing coords')
        return nil
    end
    data.coords = {
        x = data.coords.x,
        y = data.coords.y,
        z = data.coords.z or 0.0,
    }
    data.kind = kind
    data.id = data.id or nextId(kind)
    data.heading = data.heading or 0.0
    data.networked = data.networked ~= false
    data.dynamic = data.dynamic and true or false

    local previous = records[data.id]
    local print_ = fingerprint(data)
    if previous and previous.print == print_ then
        return previous.id
    end

    revisions = revisions + 1
    -- Copy, do not retain the caller's table. Otherwise a later mutation by
    -- the caller would change the stored record behind a stale fingerprint
    -- and the change would never be broadcast.
    local stored = {}
    for k, v in pairs(data) do
        stored[k] = v
    end
    stored.rev = revisions
    stored.print = print_
    records[data.id] = stored

    local audience = playersInRange(stored.coords, stored.scope or 80.0)
    for i = 1, #audience do
        TriggerClientEvent('cis_libs:client:syncUpsert', audience[i], stored)
    end
    return data.id
end

local function remove(id)
    if not CisInvokingAllowed() then
        return false
    end
    if not records[id] then
        return false
    end
    records[id] = nil
    TriggerClientEvent('cis_libs:client:syncRemove', -1, id)
    return true
end

local function broadcastDynamic()
    -- Dynamic records are rebroadcast on a timer on purpose: a player who
    -- walks into range after the last upsert still has to receive the entity.
    -- The client moves an existing entity instead of respawning it, so this
    -- cadence does not make anything flicker.
    local positions = playerPositions()
    for id, record in pairs(records) do
        if record.dynamic then
            local audience = withinRange(positions, record.coords, record.scope or 80.0)
            for i = 1, #audience do
                TriggerClientEvent('cis_libs:client:syncUpsert', audience[i], record)
            end
        end
    end
end

CreateThread(function()
    while true do
        local hasDynamic = false
        for _, record in pairs(records) do
            if record.dynamic then
                hasDynamic = true
                break
            end
        end
        if not hasDynamic then
            Wait(1000)
        else
            broadcastDynamic()
            Wait(2000)
        end
    end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then
        return
    end
    for id in pairs(records) do
        TriggerClientEvent('cis_libs:client:syncRemove', -1, id)
    end
    records = {}
end)

exports('SyncCreate', function(kind, data)
    return upsert(kind, data)
end)

exports('SyncRemove', function(id)
    return remove(id)
end)
