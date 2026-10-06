-- Server-authoritative entity sync, streamed by distance.

local records = {}
local seq = 0
local revisions = 0

-- src -> { [recordKey] = true }.
local has = {}

-- HOW MANY RECORDS ARE DYNAMIC.

-- Server-issued, and never taken from the caller unless the caller supplied one.
local function nextId(kind)
    seq = seq + 1
    return ('%s_%s'):format(kind, seq)
end

-- THE NAMESPACE. Every record is stored and streamed under owner plus id.
local function recordKey(owner, id)
    return owner .. '\0' .. id
end

-- The caller-facing half: its own id, as a string.
local function normalizeId(value)
    if type(value) == 'number' then
        return tostring(value)
    end
    return value
end

function CisSyncEnabled()
    return not (Config and Config.Sync and Config.Sync.Enabled == false)
end

-- One pass over connected players, reused across every record in a broadcast tick.
local function playerBucket(src)
    if type(GetPlayerRoutingBucket) ~= 'function' then
        return 0
    end
    local ok, bucket = pcall(GetPlayerRoutingBucket, src)
    if not ok then
        return 0
    end
    return tonumber(bucket) or 0
end

local function playerPositions()
    local out = {}
    for _, id in ipairs(GetPlayers()) do
        local src = tonumber(id)
        local ped = GetPlayerPed(src)
        if ped and ped ~= 0 then
            local pos = GetEntityCoords(ped)
            out[#out + 1] = {
                src = src, x = pos.x, y = pos.y, z = pos.z,
                bucket = playerBucket(src),
            }
        end
    end
    return out
end

-- The default streaming radius, in game units.
local DEFAULT_SCOPE = 80.0

-- How often the streaming pass runs.
local STREAM_MS = 1000

-- How long a networked spawn waits for its model.
local MODEL_TIMEOUT_MS = 5000

-- The only distance question this file asks.
local function nearByDistance(p, coords, radius)
    local dx, dy, dz = p.x - coords.x, p.y - coords.y, p.z - coords.z
    return dx * dx + dy * dy + dz * dz <= (radius or DEFAULT_SCOPE) ^ 2
end

-- SHOULD THIS PLAYER BE TOLD ABOUT THIS RECORD AT ALL (C3).
local function isNear(p, record)
    if p.bucket ~= (record.bucket or 0) then
        return false
    end
    return nearByDistance(p, record.coords, record.scope or DEFAULT_SCOPE)
end

-- HYSTERESIS: TWO RADII, NOT ONE.
local HYSTERESIS = 1.25

local function stillNear(p, record)
    if p.bucket ~= (record.bucket or 0) then
        return false
    end
    return nearByDistance(p, record.coords,
        (record.scope or DEFAULT_SCOPE) * HYSTERESIS)
end

-- Caps on one event, so a pass cannot hand a client an unbounded payload when a server
local MAX_UPDATES_PER_PLAYER = 200

-- THE SPATIAL INDEX, and exactly what it is allowed to break.
local streamGrid = CisGrid.new()
local unindexed = {}

local function gridInsert(key, record)
    local r = (record.scope or DEFAULT_SCOPE) * HYSTERESIS
    local aabb = CisGrid.aabbFromCenter(record.coords.x, record.coords.y,
        record.coords.z, r, r, r)
    if aabb then
        local ok = CisGrid.insert(streamGrid, key, aabb, nil)
        if ok then
            unindexed[key] = nil
            return
        end
    end
    unindexed[key] = true
    Logging.Error(('Cis.sync: record %s is not in the spatial index and will be '
        .. 'scanned: %s'):format(tostring(record.id), tostring(aabb)))
end

local function gridForget(key)
    CisGrid.remove(streamGrid, key)
    unindexed[key] = nil
end

-- Revision covers the whole record (minus our own bookkeeping fields) so a caller
local function canonical(value, out)
    out = out or {}
    local t = type(value)
    if t ~= 'table' then
        out[#out + 1] = tostring(value)
        return out
    end
    local keys = {}
    for k in pairs(value) do
        if k ~= 'rev' and k ~= 'print' and k ~= 'id' and k ~= 'owner' then
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

-- COORDINATES IN THE FINGERPRINT, ROUNDED TO A HUNDREDTH OF A UNIT.
local function coordKey(v)
    local s = ('%.2f'):format(v)
    -- `-0.00` and `0.00` are the same place, and format writes the sign.
    if s == '-0.00' then
        return '0.00'
    end
    return s
end

-- THE FINGERPRINT IS CONTENT ALONE, and it is computed over a PROBE rather than over
local function fingerprint(data)
    local probe = {}
    for k, v in pairs(data) do
        if k == 'coords' and type(v) == 'table' then
            probe[k] = { x = coordKey(v.x), y = coordKey(v.y), z = coordKey(v.z) }
        else
            probe[k] = v
        end
    end
    return table.concat(canonical(probe), '\30')
end

-- id<-> content index, so the implicit lookup below is O(1) rather than a scan of every
local byContent = {}

-- recordKey -> server entity handle, for NETWORKED records only.
local handles = {}

-- \0 is the same boundary `recordKey` uses, and for the same reason: it cannot occur in
local function contentKey(owner, kind, print_)
    return owner .. '\0' .. kind .. '\29' .. print_
end

local function indexRecord(id, stored)
    byContent[contentKey(stored.owner, stored.kind, stored.print)] = id
end

local function unindexRecord(id, stored)
    if not stored then
        return
    end
    local key = contentKey(stored.owner, stored.kind, stored.print)
    -- ONLY IF THE INDEX STILL POINTS AT THIS RECORD.
    if byContent[key] == id then
        byContent[key] = nil
    end
end

-- What actually goes over the wire.
local CLIENT_FIELDS = {
    key = true, id = true, kind = true, model = true, coords = true,
    heading = true, networked = true, netId = true, spawnHere = true,
    freeze = true, invincible = true, blockEvents = true, scenario = true,
    props = true, clientData = true,
}

-- How much of a caller's own data may travel.
local MAX_CLIENT_DATA_NODES = 256

-- Copy at most `budget` entries.
local function copyCapped(value, budget, depth)
    if type(value) ~= 'table' or depth > 4 then
        return nil
    end
    local out = {}
    local spent = 0
    for k, v in pairs(value) do
        if spent >= budget then
            Logging.Error('Cis.sync: clientData truncated at the size cap')
            break
        end
        spent = spent + 1
        if type(v) == 'table' then
            out[k] = copyCapped(v, budget - spent, depth + 1)
        else
            out[k] = v
        end
    end
    return out
end

local function payload(record)
    local out = {}
    for k in pairs(CLIENT_FIELDS) do
        local v = record[k]
        if v ~= nil then
            out[k] = v
        end
    end
    if out.clientData ~= nil then
        out.clientData = copyCapped(record.clientData, MAX_CLIENT_DATA_NODES, 1)
    end
    return out
end

-- Spawn a networked entity ONCE, on the server, and return its handle.

-- The vehicle type the server setter native takes as a string.
local VEHICLE_TYPES = {
    automobile = true, bike = true, boat = true, heli = true,
    plane = true, submarine = true, trailer = true,
}

-- Orphan mode KeepEntity. The other two values are the defect this replaces:
local ORPHAN_KEEP = 2

local function modelHashOf(model)
    if type(model) == 'number' then
        return model
    end
    return joaat(tostring(model))
end

-- One entity, created the way THIS KIND has to be created, plus the two calls that
local function createEntity(record)
    local hash = modelHashOf(record.model)
    local c = record.coords
    local heading = record.heading or 0.0
    local entity

    if record.kind == 'prop' then
        if type(CreateObjectNoOffset) ~= 'function' then
            return nil, 'this server cannot create an object (CreateObjectNoOffset is absent)', true
        end
        entity = CreateObjectNoOffset(hash, c.x, c.y, c.z, true, true, false)
    elseif record.kind == 'vehicle' then
        local vehicleType = record.vehicleType or 'automobile'
        if not VEHICLE_TYPES[vehicleType] then
            return nil, ('vehicleType must be one of automobile, bike, boat, heli, plane, '
                .. 'submarine, trailer; got %s'):format(tostring(record.vehicleType)), true
        end
        if type(CreateVehicleServerSetter) ~= 'function' then
            return nil, 'this server cannot create a vehicle (CreateVehicleServerSetter is absent)', true
        end
        entity = CreateVehicleServerSetter(hash, vehicleType, c.x, c.y, c.z, heading)
    elseif record.kind == 'ped' then
        if type(CreatePed) ~= 'function' then
            return nil, 'this server cannot create a ped (CreatePed is absent)', true
        end
        -- The first argument is documented as unused; the ped's type comes from the
        entity = CreatePed(0, hash, c.x, c.y, c.z, heading, true, true)
    else
        return nil, ('no server-side creation for kind %s: a networked entity can be a '
            .. 'prop, a vehicle or a ped, or any other kind with networked = false')
            :format(tostring(record.kind)), true
    end

    if not entity or entity == 0 then
        return nil, ('the server could not create %s %s')
            :format(tostring(record.kind), tostring(record.model))
    end

    -- The handle comes back immediately, but the entity is not necessarily addressable
    if type(DoesEntityExist) == 'function' then
        local waited = 0
        while not DoesEntityExist(entity) and waited < MODEL_TIMEOUT_MS do
            Wait(0)
            waited = waited + 1
        end
        if not DoesEntityExist(entity) then
            return nil, ('the server created %s %s but it never came into existence')
                :format(tostring(record.kind), tostring(record.model))
        end
    end

    -- WHICH WORLD. A routing bucket is a separate instance of the map, and the
    if type(SetEntityRoutingBucket) == 'function' then
        SetEntityRoutingBucket(entity, record.bucket or 0)
    end
    if type(SetEntityOrphanMode) == 'function' then
        SetEntityOrphanMode(entity, ORPHAN_KEEP)
    end
    return entity
end

local function destroyEntity(entity)
    if not entity or entity == 0 then
        return
    end
    if type(DoesEntityExist) == 'function' and not DoesEntityExist(entity) then
        return
    end
    if type(DeleteEntity) == 'function' then
        DeleteEntity(entity)
    end
end

-- Move an entity the server already owns.
local function moveEntity(entity, record)
    local c = record.coords
    if type(SetEntityCoords) == 'function' then
        SetEntityCoords(entity, c.x, c.y, c.z)
    end
    if type(SetEntityHeading) == 'function' then
        SetEntityHeading(entity, record.heading or 0.0)
    end
end

--- Coords out of whatever shape a consumer holds, into a fresh three-number table, or
--- @param value any  vector3, vector4, or a table with x/y/z
--- @param heading number|nil  the heading to keep when the value carries none
--- @return table|nil { x, y, z, heading }
--- @return string|nil why  set only when the value is refused
local function normalizeCoords(value, heading)
    if value == nil then
        return nil, 'missing coords; pass a vector3, a vector4, or { x, y, z }'
    end

    local x, y, z, w
    local tag = type(value)
    if tag == 'vector3' or tag == 'vector4' then
        x, y, z, w = value.x, value.y, value.z, value.w
    elseif tag == 'table' then
        x, y, z = value.x, value.y, value.z
        w = value.w
    else
        return nil, ('coords must be a vector3, a vector4 or { x, y, z }, got %s')
            :format(tag)
    end

    -- x AND y are required; z is not, because `{ x, y }` is what a caller with a 2D
    if type(x) ~= 'number' or type(y) ~= 'number' then
        return nil, 'coords need numeric x and y'
    end
    z = (type(z) == 'number') and z or 0.0

    -- FINITE, EXPLICITLY. `x ~= x` is NaN; there is no isfinite in CfxLua.
    if x ~= x or y ~= y or z ~= z then
        return nil, 'coords must be finite numbers, got NaN'
    end
    if x == math.huge or x == -math.huge
        or y == math.huge or y == -math.huge
        or z == math.huge or z == -math.huge then
        return nil, 'coords must be finite numbers, got infinity'
    end

    local h = heading
    if h == nil and type(w) == 'number' then
        h = w
    end
    return { x = x, y = y, z = z, heading = (type(h) == 'number') and h or 0.0 }
end

local function upsert(kind, data)
    -- Two refusals before any work, both returning nil rather than raising: a caller
    if not CisInvokingAllowed() then
        return nil
    end
    if not CisSyncEnabled() then
        return nil
    end
    data = data or {}

    -- THE COORDINATES, IN EVERY SHAPE A CONSUMER WRITES THEM.
    local coords, coordsWhy = normalizeCoords(data.coords, data.heading)
    if not coords then
        Logging.Error(('Cis.sync.%s rejected: %s'):format(tostring(kind), coordsWhy))
        return nil
    end
    data.coords = coords
    data.heading = data.heading or coords.heading or 0.0
    data.kind = kind
    data.heading = data.heading or 0.0
    -- CLIENT-LOCAL BY DEFAULT (D2).
    data.networked = data.networked == true
    data.dynamic = data.dynamic and true or false
    -- WHICH WORLD. A routing bucket is a separate instance of the map, so a record is
    if data.bucket ~= nil then
        local bucket = tonumber(data.bucket)
        if not bucket or bucket < 0 or bucket % 1 ~= 0 then
            Logging.Error(('Cis.sync.%s rejected: bucket must be a non-negative whole number, got %s')
                :format(tostring(kind), tostring(data.bucket)))
            return nil
        end
        data.bucket = bucket
    else
        data.bucket = 0
    end
    -- the owning resource, so a consumer that stops takes its records with it.
    data.owner = GetInvokingResource() or 'cis_libs'

    -- THE CALLER'S ID, BEFORE IT IS USED AS PART OF A KEY.
    if data.id ~= nil then
        local id = normalizeId(data.id)
        local idType = type(id)
        if id ~= '' and idType ~= 'string' and idType ~= 'number' then
            Logging.Error(('Cis.sync.%s rejected: id must be a string or a number, got %s')
                :format(tostring(kind), idType))
            return nil
        end
        if idType == 'string' and id:find('\0', 1, true) then
            Logging.Error(('Cis.sync.%s rejected: id must not contain a NUL')
                :format(tostring(kind)))
            return nil
        end
        data.id = id
    end

    -- Fingerprint AFTER the defaults are applied and BEFORE an id is chosen, so two
    local print_ = fingerprint(data)

    if data.id then
        -- Caller-managed identity: the id is authoritative and the fingerprint only
        local previous = records[recordKey(data.owner, data.id)]
        if previous and previous.print == print_ then
            return previous.id
        end
    else
        -- No id supplied. An identical payload is the SAME entity, so reuse the record
        local existing = byContent[contentKey(data.owner, kind, print_)]
        if existing and records[existing] then
            return records[existing].id
        end
        data.id = nextId(kind)
    end

    -- The key this record is stored and streamed under.
    local key = recordKey(data.owner, data.id)

    -- Monotonic, so a client can tell "newer" from "older" without comparing payloads.
    revisions = revisions + 1
    -- Copy, do not retain the caller's table.
    local stored = {}
    for k, v in pairs(data) do
        stored[k] = v
    end
    stored.rev = revisions
    stored.print = print_
    stored.key = key

    -- A NETWORKED record is one entity the server owns.
    local previous = records[key]
    if stored.networked then
        local entity = handles[key]
        local sameShape = previous and previous.kind == stored.kind
            and modelHashOf(previous.model) == modelHashOf(stored.model)
        if entity and sameShape then
            moveEntity(entity, stored)
        else
            -- Create the replacement BEFORE destroying what is there.
            local created, why, unsupported = createEntity(stored)
            if unsupported then
                -- THIS KIND CANNOT BE NETWORKED.
                Logging.Error(('Cis.sync.%s rejected: %s'):format(
                    tostring(stored.id), tostring(why)))
                return nil, why
            end
            if entity then
                -- The shape changed, so the old entity no longer describes this record.
                destroyEntity(entity)
                handles[key] = nil
            end
            if created then
                handles[key] = created
                if type(NetworkGetNetworkIdFromEntity) == 'function' then
                    stored.netId = NetworkGetNetworkIdFromEntity(created)
                end
                stored.spawnHere = false
            else
                -- The server tried and could not.
                Logging.Error(('Cis.sync.%s networked: %s'):format(
                    tostring(stored.id), tostring(why)))
            end
        end
    elseif handles[key] then
        -- No longer asked to be networked.
        destroyEntity(handles[key])
        handles[key] = nil
    end

    unindexRecord(key, previous)
    records[key] = stored
    indexRecord(key, stored)
    gridInsert(key, stored)

    -- Tell whoever is ALREADY in range right now.
    local positions = playerPositions()
    for i = 1, #positions do
        local p = positions[i]
        if isNear(p, stored) then
            local set = has[p.src]
            if not set then
                set = {}
                has[p.src] = set
            end
            set[key] = true
            TriggerClientEvent('cis_libs:client:syncUpsert', p.src, payload(stored))
        end
    end
    return stored.id
end

-- Forget one record key in a player's set.
local function forget(src, key)
    local set = has[src]
    if set then
        set[key] = nil
        if next(set) == nil then
            has[src] = nil
        end
    end
end

-- Takes the INTERNAL key. Every caller resolves its own id to one first, so there is
local function remove(key)
    if not CisInvokingAllowed() then
        return false
    end
    -- false for "no such entity", which is a different answer from true and is what
    local record = records[key]
    if not record then
        return false
    end
    unindexRecord(key, record)
    gridForget(key)
    records[key] = nil

    -- A networked entity belongs to the server, so the SERVER deletes it.
    local entity = handles[key]
    if entity then
        destroyEntity(entity)
        handles[key] = nil
    end

    -- Tell every player who HOLDS it, and clear their `has` entry.
    local told = 0
    for src in pairs(has) do
        if has[src] and has[src][key] then
            forget(src, key)
            TriggerClientEvent('cis_libs:client:syncRemove', src, key)
            told = told + 1
        end
    end
    -- Nobody in range holds it, but a client that received it earlier and has since
    if told == 0 then
        TriggerClientEvent('cis_libs:client:syncRemove', -1, key)
    end
    return true
end

-- ONE STREAMING PASS: every player against every record.
local function streamPass()
    if not CisSyncEnabled() then
        return
    end
    local positions = playerPositions()
    if #positions == 0 then
        return
    end

    -- PER PLAYER, UNDER PCALL.
    for _, p in ipairs(positions) do
        local ok, err = pcall(function()
            local set = has[p.src]
            -- A player who has just joined has no set at all.
            if not set then
                set = {}
                has[p.src] = set
            end

            -- Anything they hold that has gone, or that is past the EXIT radius -- not
            local stale = nil
            for key in pairs(set) do
                local record = records[key]
                if not record or not stillNear(p, record) then
                    stale = stale or {}
                    stale[#stale + 1] = key
                end
            end
            if stale then
                for i = 1, #stale do
                    local gone = stale[i]
                    set[gone] = nil
                    TriggerClientEvent('cis_libs:client:syncRemove', p.src, gone)
                end
            end

            -- PER RECORD, UNDER PCALL. One record with a payload that cannot be built
            local sent = 0
            local function consider(key)
                local record = records[key]
                if not record then
                    return
                end
                local okRecord, recordErr = pcall(function()
                    local near = isNear(p, record)
                    if near and not set[key] then
                        if sent < MAX_UPDATES_PER_PLAYER then
                            set[key] = true
                            TriggerClientEvent('cis_libs:client:syncUpsert', p.src, payload(record))
                            sent = sent + 1
                        end
                    elseif near and record.dynamic then
                        TriggerClientEvent('cis_libs:client:syncUpsert', p.src, payload(record))
                    end
                end)
                if not okRecord then
                    -- Counted, and named, rather than swallowed.
                    Logging.Error(('Cis.sync: record %s skipped: %s')
                        :format(tostring(record.id), tostring(recordErr)))
                end
            end
            -- `z` is nil on purpose: the grid then does not filter on height, and the
            CisGrid.queryPoint(streamGrid, p.x, p.y, nil, consider)
            for key in pairs(unindexed) do
                consider(key)
            end
        end)
        if not ok then
            Logging.Error(('Cis.sync: streaming pass failed for a player: %s')
                :format(tostring(err)))
        end
    end
end

-- `has[src]` is the server's belief about what a player holds, and the pass only sends
local function snapshotFor(src)
    local set = has[src]
    if not set then
        set = {}
        has[src] = set
    end

    -- A player with no ped has not spawned yet.
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then
        return 0
    end
    local c = GetEntityCoords(ped)
    if not c then
        return 0
    end
    local p = {
        src = src, x = c.x, y = c.y, z = c.z,
        bucket = playerBucket(src),
    }

    local sent = 0
    local function offer(key)
        local record = records[key]
        if not record or set[key] then
            return
        end
        local ok = pcall(function()
            if isNear(p, record) then
                set[key] = true
                TriggerClientEvent('cis_libs:client:syncUpsert', src, payload(record))
                sent = sent + 1
            end
        end)
        if not ok then
            Logging.Error(('Cis.sync: snapshot skipped record %s')
                :format(tostring(record.id)))
        end
    end

    CisGrid.queryPoint(streamGrid, p.x, p.y, nil, offer)
    for key in pairs(unindexed) do
        offer(key)
    end
    return sent
end

CisNetOn('cis_libs:server:syncSnapshot', function(src)
    if type(src) ~= 'number' or src <= 0 then
        return
    end
    -- FORGET, THEN ANSWER. Clearing `has` first is what makes this a recovery rather
    has[src] = nil
    snapshotFor(src)
end)

-- The streaming loop.
CreateThread(CisLoopGuard.Run('server.sync.stream', STREAM_MS, function()
    if next(records) then
        if CisTiming then
            CisTiming.measure('serverSyncPass', streamPass)
        else
            streamPass()
        end
    end
end))

-- A player who drops takes their whole set with them.
AddEventHandler('playerDropped', function()
    has[source] = nil
end)

-- Records owned by a consumer that stops go with it ().
AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        -- cis_libs itself is stopping: tell every client to drop everything, because
        for key in pairs(records) do
            TriggerClientEvent('cis_libs:client:syncRemove', -1, key)
            local entity = handles[key]
            if entity then
                destroyEntity(entity)
                handles[key] = nil
            end
        end
        -- ALL FOUR, AND ONLY HERE. This reset used to run on EVERY stop, for every
        records = {}
        byContent = {}
        has = {}
        handles = {}
        unindexed = {}
        streamGrid = CisGrid.new()
        return
    end

    -- `remove` IS the fix for another resource stopping.
    for key, record in pairs(records) do
        if record.owner == resource then
            remove(key)
        end
    end
end)

exports('SyncCreate', function(kind, data)
    return upsert(kind, data)
end)

-- Does ANY resource hold a record under this id?
local function heldByAnotherOwner(id)
    for _, record in pairs(records) do
        if record.id == id then
            return true
        end
    end
    return false
end

-- The caller's id is namespaced by WHO IS ASKING, and that resource is never taken from
exports('SyncRemove', function(id)
    if id == nil then
        return false, 'no sync id given'
    end
    local normalized = normalizeId(id)
    if type(normalized) ~= 'string' then
        return false, ('sync id must be a string or a number, got %s'):format(type(id))
    end
    local owner = GetInvokingResource() or 'cis_libs'
    local key = recordKey(owner, normalized)
    if records[key] then
        return remove(key)
    end
    if heldByAnotherOwner(normalized) then
        return false, ('sync id %q belongs to another resource: ids are scoped to '
            .. 'the resource that created them, so create and remove under your '
            .. 'own'):format(normalized)
    end
    return false, ('no sync record with id %q in this resource\'s namespace')
        :format(normalized)
end)
-- WHAT THIS RESOURCE HAS IN THE WORLD, and the two calls that act on it.
exports('SyncList', function()
    if not CisInvokingAllowed() then
        return nil, 'this resource is not in Security.AuthorizedResources'
    end
    local owner = GetInvokingResource() or 'cis_libs'
    local out = {}
    for _, record in pairs(records) do
        if record.owner == owner then
            -- The CALLER'S OWN ID, never the namespaced key.
            out[#out + 1] = {
                id = record.id,
                kind = record.kind,
                model = record.model,
                coords = record.coords,
                heading = record.heading,
                networked = record.networked == true,
                scope = record.scope,
                bucket = record.bucket,
                dynamic = record.dynamic == true,
            }
        end
    end
    -- Sorted, so two calls in the same state answer in the same order.
    table.sort(out, function(a, b) return tostring(a.id) < tostring(b.id) end)
    return out
end)

-- TAKE THEM ALL DOWN. This is what a resource calls before it rebuilds its map, so it
exports('SyncClear', function()
    if not CisInvokingAllowed() then
        return nil, 'this resource is not in Security.AuthorizedResources'
    end
    local owner = GetInvokingResource() or 'cis_libs'
    -- Collected first, then removed.
    local doomed = {}
    for key, record in pairs(records) do
        if record.owner == owner then
            doomed[#doomed + 1] = key
        end
    end
    local taken = 0
    for i = 1, #doomed do
        if remove(doomed[i]) then
            taken = taken + 1
        end
    end
    return taken
end)

-- Registered rather than counted by the diagnostics module, because the records table
CisDiagnostics.Register('server', 'syncRecords', function()
    local out = {
        total = 0, byOwner = {}, networked = 0, clientLocal = 0,
        entities = 0, refused = 0, dynamic = 0,
    }
    for _, record in pairs(records) do
        local owner = record.owner or '<none>'
        out.byOwner[owner] = (out.byOwner[owner] or 0) + 1
        out.total = out.total + 1
        if record.networked then out.networked = out.networked + 1
        else out.clientLocal = out.clientLocal + 1 end
        -- Counted HERE, on the walk this function was making anyway to answer `total`.
        if record.dynamic then out.dynamic = out.dynamic + 1 end
        -- `networked` counts what the caller ASKED for.
        if handles[record.key] then out.entities = out.entities + 1 end
        if record.networked and not record.netId then out.refused = out.refused + 1 end
    end
    return out
end)
