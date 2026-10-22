-- Server-authoritative entity sync.
--
-- TWO KINDS OF RECORD, AND TWO TRANSPORTS.
--
--   client-local (the default). The server streams the RECORD by distance and
--   each client in range spawns its own non-networked copy. What a client holds
--   is tracked per player (`has`), every change carries a revision, and a player
--   is sent a record only when the revision they hold is older than the record's.
--   One batched event per player per pass, latent when it is large.
--
--   networked. The server creates ONE entity (orphan mode KeepEntity, in the
--   record's routing bucket) and OneSync streams it -- that is what OneSync is
--   for, and doing it again over events was a second, worse copy. The record's
--   metadata rides an entity state bag (`cis_sync`) that the owning client
--   applies. Clients NEVER create a networked entity and never move one: a moving
--   vehicle is where its driver put it, not where it was spawned. If the entity
--   is removed behind the library's back (`entityRemoved`), it is re-created or
--   the record dropped, per `respawn`.

local records = {}
local seq = 0
local revisions = 0

-- src -> { [recordKey] = rev that player was sent }.
local has = {}

-- src -> { [recordKey] = { rev, untilMs } }: a model the client gave up on.
local refused = {}

-- src -> the sequence number of the last batch sent to that player. A client
-- applies an entry only if no LATER batch has already touched that key, which is
-- what makes a latent batch safe next to a reliable one that overtakes it.
local batchSeq = {}

-- src -> GetGameTimer of the last snapshot honoured.
local lastSnapshot = {}

-- recordKey -> { owner, cancelled } while an upsert for it may yield.
local inflight = {}
-- contentKey -> true while an idless upsert for that content may yield.
local inflightContent = {}

local stats = { networkedFailed = 0, respawned = 0, truncated = 0, snapshotsRefused = 0 }

-- THE NAMESPACE. Every record is stored and streamed under owner plus id.
local function recordKey(owner, id)
    return owner .. '\0' .. id
end

-- Server-issued, and never taken from the caller unless the caller supplied one.
-- COLLISION-PROOF: an explicit `prop_1` used to be overwritten by the next
-- idless upsert, which generated the same id. A taken or in-flight key is
-- skipped. Takes the owner because the key is owner plus id.
local function nextId(kind, owner)
    while true do
        seq = seq + 1
        local id = ('%s_%s'):format(kind, seq)
        local key = recordKey(owner, id)
        if records[key] == nil and inflight[key] == nil then
            return id
        end
    end
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
-- The largest radius a record may ask for: the whole map is about 8 km across.
local MAX_SCOPE = 10000.0

-- How often the streaming pass runs.
local STREAM_MS = 1000

-- How long a networked spawn waits for its entity to become addressable, in
-- MILLISECONDS on the game clock. It used to count loop iterations, so the
-- "5 second" timeout was 5000 frames.
local ENTITY_WAIT_MS = 5000
-- A runaway guard for a clock that does not move.
local ENTITY_WAIT_TICKS = 20000

-- A batch this large goes over the latent channel instead of the reliable one.
local LATENT_MIN_ENTRIES = 32
local LATENT_BPS = 256000

-- A snapshot is a recovery, not a feed: one per player per this long.
local SNAPSHOT_COOLDOWN_MS = 10000
-- The most keys a client may claim to hold in one snapshot request.
local MAX_HELD_CLAIMS = 512

-- A client that gave up on a model is not re-sent that revision for this long.
local REFUSED_BACKOFF_MS = 30000

-- entityRemoved re-creations allowed per record per window before re-creation
-- BACKS OFF. Dropping the record after three let any client that could delete
-- the entity (KeepEntity does not stop a client delete) remove it for good.
local RESPAWN_MAX = 3
local RESPAWN_WINDOW_MS = 60000
local RESPAWN_BACKOFF_MS = 5000
local RESPAWN_BACKOFF_MAX_MS = 300000

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

-- recordKey -> server entity handle, for NETWORKED records only, and the reverse.
local handles = {}
local byEntity = {}

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

-- How much of a caller's own data may travel: ONE budget for the whole record --
-- clientData and vehicle props together, at every depth. The nested copy used to
-- be handed the budget by value, so a table of tables spent its allowance once
-- per level and the cap was a cap on the top level only.
local MAX_CLIENT_DATA_NODES = 256
local MAX_CLIENT_DATA_BYTES = 16384
local MAX_DEPTH = 4

-- Copy at most the budget's entries and string bytes. `budget` is shared and
-- charged as it goes, so nesting cannot multiply it.
local function copyCapped(value, budget, depth)
    if type(value) ~= 'table' or depth > MAX_DEPTH then
        return nil
    end
    local out = {}
    for k, v in pairs(value) do
        local tk, tv = type(k), type(v)
        if tk ~= 'string' and tk ~= 'number' then
            budget.truncated = true
        else
            budget.nodes = budget.nodes - 1
            if tk == 'string' then
                budget.bytes = budget.bytes - #k
            end
            if tv == 'string' then
                budget.bytes = budget.bytes - #v
            end
            if budget.nodes < 0 or budget.bytes < 0 then
                budget.truncated = true
                break
            end
            if tv == 'table' then
                local nested = copyCapped(v, budget, depth + 1)
                if nested == nil then
                    budget.truncated = true
                else
                    out[k] = nested
                end
                if budget.nodes < 0 or budget.bytes < 0 then
                    break
                end
            elseif tv == 'string' or tv == 'number' or tv == 'boolean' then
                out[k] = v
            else
                -- A function or userdata cannot cross the network.
                budget.truncated = true
            end
        end
    end
    return out
end

-- WHAT GOES OVER THE WIRE, built ONCE per revision and shared by every send of
-- it. An allow-list: a field nobody named here does not travel.
local function buildWire(record)
    local c = record.coords
    local out = {
        key = record.key, id = record.id, kind = record.kind, model = record.model,
        coords = { x = c.x, y = c.y, z = c.z }, heading = record.heading,
        networked = false, rev = record.rev,
        freeze = record.freeze, invincible = record.invincible,
        blockEvents = record.blockEvents,
    }
    if type(record.scenario) == 'string' then
        out.scenario = record.scenario
    end
    local budget = { nodes = MAX_CLIENT_DATA_NODES, bytes = MAX_CLIENT_DATA_BYTES }
    if type(record.props) == 'table' then
        out.props = copyCapped(record.props, budget, 1)
    end
    if type(record.clientData) == 'table' then
        out.clientData = copyCapped(record.clientData, budget, 1)
    end
    if budget.truncated then
        stats.truncated = stats.truncated + 1
        Logging.Error(('Cis.sync: record %s clientData/props truncated at the size cap '
            .. '(%d entries, %d bytes)'):format(tostring(record.id),
            MAX_CLIENT_DATA_NODES, MAX_CLIENT_DATA_BYTES))
    end
    return out
end

-- What a networked entity carries in its `cis_sync` state bag: everything the
-- OWNING client applies, and nothing about where the entity is.
local function buildBag(record)
    local budget = { nodes = MAX_CLIENT_DATA_NODES, bytes = MAX_CLIENT_DATA_BYTES }
    local out = {
        key = record.key, id = record.id, kind = record.kind, rev = record.rev,
        invincible = record.invincible, blockEvents = record.blockEvents,
        scenario = type(record.scenario) == 'string' and record.scenario or nil,
    }
    if type(record.props) == 'table' then
        out.props = copyCapped(record.props, budget, 1)
    end
    if type(record.clientData) == 'table' then
        out.clientData = copyCapped(record.clientData, budget, 1)
    end
    return out
end

-- ------------------------------------------------------------------ the wire
local EMPTY = {}

-- ONE event per player per call: upserts and removes together, numbered.
local function send(src, ups, rems)
    local nUps = ups and #ups or 0
    local nRems = rems and #rems or 0
    if nUps + nRems == 0 then
        return
    end
    local n = (batchSeq[src] or 0) + 1
    batchSeq[src] = n
    if nUps + nRems >= LATENT_MIN_ENTRIES then
        TriggerLatentClientEvent('cis_libs:client:syncBatch', src, LATENT_BPS, n,
            ups or EMPTY, rems or EMPTY)
    else
        TriggerClientEvent('cis_libs:client:syncBatch', src, n, ups or EMPTY, rems or EMPTY)
    end
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

-- Props are frozen unless asked not to be; anything else only when asked.
local function wantsFreeze(record)
    if record.kind == 'prop' then
        return record.freeze ~= false
    end
    return record.freeze == true
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

    -- The handle comes back immediately, but the entity is not necessarily
    -- addressable yet. A deadline on the game clock, in milliseconds.
    if type(DoesEntityExist) == 'function' then
        local deadline = GetGameTimer() + ENTITY_WAIT_MS
        local ticks = 0
        while not DoesEntityExist(entity) do
            if GetGameTimer() >= deadline or ticks >= ENTITY_WAIT_TICKS then
                -- The handle is deleted, not dropped: an entity that turns up
                -- later would otherwise be in the world with no record behind it.
                if type(DeleteEntity) == 'function' then
                    pcall(DeleteEntity, entity)
                end
                return nil, ('the server created %s %s but it never came into existence')
                    :format(tostring(record.kind), tostring(record.model))
            end
            ticks = ticks + 1
            Wait(0)
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
    byEntity[entity] = nil
    if type(DoesEntityExist) == 'function' and not DoesEntityExist(entity) then
        return
    end
    if type(DeleteEntity) == 'function' then
        DeleteEntity(entity)
    end
end

-- The server-side half of a networked record's look: heading, freeze, the
-- streaming radius, and the bag the owning client reads the rest from.
local function applyServerSide(entity, record, previous)
    if previous == nil then
        -- The object native takes no heading; the vehicle and ped ones did.
        if record.kind == 'prop' and type(SetEntityHeading) == 'function' then
            SetEntityHeading(entity, record.heading or 0.0)
        end
    else
        -- AN EXPLICIT MOVE ONLY. A re-upsert that names the same coordinates -- a
        -- consumer updating a vehicle's props, say -- must not teleport an entity a
        -- player is driving back to where it was spawned.
        local pc, c = previous.coords, record.coords
        local moved = pc.x ~= c.x or pc.y ~= c.y or pc.z ~= c.z
        if moved and type(SetEntityCoords) == 'function' then
            SetEntityCoords(entity, c.x, c.y, c.z, false, false, false, false)
        end
        if (moved or previous.heading ~= record.heading) and type(SetEntityHeading) == 'function' then
            SetEntityHeading(entity, record.heading or 0.0)
        end
        if previous.bucket ~= record.bucket and type(SetEntityRoutingBucket) == 'function' then
            SetEntityRoutingBucket(entity, record.bucket or 0)
        end
    end
    local freeze = wantsFreeze(record)
    if (previous == nil and freeze) or (previous ~= nil and wantsFreeze(previous) ~= freeze) then
        if type(FreezeEntityPosition) == 'function' then
            FreezeEntityPosition(entity, freeze)
        end
    end
    -- `scope` on a networked record is OneSync's own culling radius for it: the
    -- streaming distance is then measured from where the entity actually IS.
    if record.scope and (previous == nil or previous.scope ~= record.scope)
        and type(SetEntityDistanceCullingRadius) == 'function' then
        SetEntityDistanceCullingRadius(entity, record.scope + 0.0)
    end
    if Entity then
        Entity(entity).state:set('cis_sync', buildBag(record), true)
    end
end

local function attach(key, record, entity)
    handles[key] = entity
    byEntity[entity] = key
    if type(NetworkGetNetworkIdFromEntity) == 'function' then
        record.netId = NetworkGetNetworkIdFromEntity(entity)
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

local function refuse(kind, why)
    Logging.Error(('Cis.sync.%s rejected: %s'):format(tostring(kind), why))
    return nil
end

-- Wait for another upsert of the same key (or content) to finish its yield.
local function awaitFree(locks, k)
    if not locks[k] then
        return true
    end
    local deadline = GetGameTimer() + ENTITY_WAIT_MS * 2
    local ticks = 0
    while locks[k] do
        if GetGameTimer() >= deadline or ticks >= ENTITY_WAIT_TICKS then
            return false
        end
        ticks = ticks + 1
        Wait(0)
    end
    return true
end

-- Tell every player who holds the key, or who is in range of it now. Holders are
-- told even from the hysteresis band, where the pass would not have SENT it but
-- would also not have taken it away.
--
-- BATCHED. Each upsert used to read every player's position and send one event
-- per record per player, so 300 upserts in a loop were 300 events to one
-- player. Keys are queued and flushed on the next tick: one position read, one
-- batch per player, each record at its latest revision, and a record removed
-- before the flush is not sent at all.
local pushQueued, pushOrder, pushArmed = {}, {}, false

local function flushPushes()
    pushArmed = false
    if #pushOrder == 0 then
        return
    end
    local order = pushOrder
    pushOrder, pushQueued = {}, {}
    local positions = playerPositions()
    for i = 1, #positions do
        local p = positions[i]
        local set = has[p.src]
        local ups = nil
        for j = 1, #order do
            local key = order[j]
            local record = records[key]
            if record then
                local held = set and set[key] ~= nil
                if (held and stillNear(p, record)) or isNear(p, record) then
                    if not set then
                        set = {}
                        has[p.src] = set
                    end
                    set[key] = record.rev
                    ups = ups or {}
                    ups[#ups + 1] = record.wire
                end
            end
        end
        if ups then
            send(p.src, ups, nil)
        end
    end
end

local function push(key)
    if not pushQueued[key] then
        pushQueued[key] = true
        pushOrder[#pushOrder + 1] = key
    end
    if pushArmed then
        return
    end
    -- SetTimeout(0) runs on the next tick. Without it (a bare test VM) the queue
    -- is flushed at once, which is the old timing.
    if type(SetTimeout) == 'function' then
        pushArmed = true
        SetTimeout(0, flushPushes)
    else
        flushPushes()
    end
end

-- Forget a key for every holder and collect who must be told, per player.
local function collectHolders(key, out)
    for src, set in pairs(has) do
        if set[key] ~= nil then
            set[key] = nil
            local list = out[src]
            if not list then
                list = {}
                out[src] = list
            end
            list[#list + 1] = key
        end
    end
end

local function flushRemoves(out)
    for src, list in pairs(out) do
        send(src, nil, list)
    end
end

-- Take one record out of every index. Clients are told by the caller, batched.
local function unlink(key)
    local record = records[key]
    if not record then
        return nil
    end
    unindexRecord(key, record)
    gridForget(key)
    records[key] = nil
    -- A networked entity belongs to the server, so the SERVER deletes it.
    local entity = handles[key]
    if entity then
        handles[key] = nil
        destroyEntity(entity)
    end
    local lock = inflight[key]
    if lock then
        lock.cancelled = true
    end
    return record
end

-- Remove many keys and tell each holder ONCE, with every key it held.
local function removeMany(keys)
    local tell = {}
    local taken = 0
    for i = 1, #keys do
        if unlink(keys[i]) then
            taken = taken + 1
            collectHolders(keys[i], tell)
        end
    end
    flushRemoves(tell)
    return taken
end

local function upsertLocked(rec, key, print_)
    local previous = records[key]
    if previous and previous.print == print_ then
        return previous.id
    end

    -- Monotonic, so a client can tell "newer" from "older" without comparing payloads.
    revisions = revisions + 1
    rec.rev = revisions
    rec.print = print_
    rec.key = key

    if rec.networked then
        local entity = handles[key]
        local sameShape = previous and previous.networked and previous.kind == rec.kind
            and modelHashOf(previous.model) == modelHashOf(rec.model)
        if entity and sameShape then
            rec.netId = previous.netId
            rec.respawns = previous.respawns
            applyServerSide(entity, rec, previous)
        else
            -- Create the replacement BEFORE destroying what is there. This can YIELD.
            local created, why, unsupported = createEntity(rec)
            if unsupported then
                -- THIS KIND CANNOT BE NETWORKED.
                Logging.Error(('Cis.sync.%s rejected: %s'):format(
                    tostring(rec.id), tostring(why)))
                return nil, why
            end
            if not created then
                -- NEVER A NETWORKED RECORD WITHOUT AN ENTITY. The old shape stored it
                -- with no netId and every client spawned its own networked copy.
                stats.networkedFailed = stats.networkedFailed + 1
                Logging.Error(('Cis.sync.%s networked: %s'):format(
                    tostring(rec.id), tostring(why)))
                return nil, why
            end
            -- RE-CHECK AFTER THE YIELD. A remove, a clear or the owner stopping may
            -- have happened while the entity was being created.
            local lock = inflight[key]
            if lock and lock.cancelled then
                destroyEntity(created)
                return nil, 'removed while its entity was being created'
            end
            previous = records[key]
            local old = handles[key]
            if old then
                -- The shape changed, so the old entity no longer describes this record.
                handles[key] = nil
                destroyEntity(old)
            end
            attach(key, rec, created)
            applyServerSide(created, rec, nil)
        end
        if previous and not previous.networked then
            -- It was streamed client-local; holders drop their copies.
            local tell = {}
            collectHolders(key, tell)
            flushRemoves(tell)
            gridForget(key)
        end
        unindexRecord(key, previous)
        records[key] = rec
        indexRecord(key, rec)
        return rec.id
    end

    if handles[key] then
        -- No longer asked to be networked.
        local entity = handles[key]
        handles[key] = nil
        destroyEntity(entity)
    end

    rec.wire = buildWire(rec)
    unindexRecord(key, previous)
    records[key] = rec
    indexRecord(key, rec)
    gridInsert(key, rec)
    push(key)
    return rec.id
end

local function upsert(kind, data)
    -- Two refusals before any work, both returning nil rather than raising: a caller
    if not CisInvokingAllowed() then
        return nil
    end
    if not CisSyncEnabled() then
        return nil
    end
    if type(data) ~= 'table' then
        return refuse(kind, ('data must be a table, got %s'):format(type(data)))
    end

    -- A COPY. The caller's table is never written to or retained.
    local rec = {}
    for k, v in pairs(data) do
        rec[k] = v
    end

    -- THE COORDINATES, IN EVERY SHAPE A CONSUMER WRITES THEM.
    local coords, coordsWhy = normalizeCoords(rec.coords, rec.heading)
    if not coords then
        return refuse(kind, coordsWhy)
    end
    rec.coords = coords
    local heading = rec.heading or coords.heading or 0.0
    if type(heading) ~= 'number' or heading ~= heading
        or heading == math.huge or heading == -math.huge then
        return refuse(kind, 'heading must be a finite number')
    end
    rec.heading = heading
    rec.kind = kind
    local modelType = type(rec.model)
    if modelType ~= 'string' and modelType ~= 'number' then
        return refuse(kind, ('model must be a name or a hash, got %s'):format(modelType))
    end
    -- CLIENT-LOCAL BY DEFAULT (D2).
    rec.networked = rec.networked == true
    rec.dynamic = rec.dynamic and true or false
    rec.respawn = rec.respawn ~= false
    -- THE STREAMING RADIUS. A string, a negative, NaN or infinity used to reach
    -- the pass, where `nil ^ 2`, a negative radius or a NaN comparison broke every
    -- record for every player, or none.
    if rec.scope ~= nil then
        local s = rec.scope
        if type(s) ~= 'number' or s ~= s or s <= 0 or s > MAX_SCOPE then
            return refuse(kind, ('scope must be a number of metres in (0, %d], got %s')
                :format(MAX_SCOPE, tostring(s)))
        end
    end
    -- WHICH WORLD. A routing bucket is a separate instance of the map, so a record is
    if rec.bucket ~= nil then
        local bucket = tonumber(rec.bucket)
        if not bucket or bucket < 0 or bucket % 1 ~= 0 then
            return refuse(kind, ('bucket must be a non-negative whole number, got %s')
                :format(tostring(rec.bucket)))
        end
        rec.bucket = bucket
    else
        rec.bucket = 0
    end
    -- the owning resource, so a consumer that stops takes its records with it.
    rec.owner = GetInvokingResource() or 'cis_libs'

    -- THE CALLER'S ID, BEFORE IT IS USED AS PART OF A KEY.
    if rec.id ~= nil then
        local id = normalizeId(rec.id)
        local idType = type(id)
        if id ~= '' and idType ~= 'string' and idType ~= 'number' then
            return refuse(kind, ('id must be a string or a number, got %s'):format(idType))
        end
        if idType == 'string' and id:find('\0', 1, true) then
            return refuse(kind, 'id must not contain a NUL')
        end
        rec.id = id
    end

    -- Fingerprint AFTER the defaults are applied and BEFORE an id is chosen, so two
    local print_ = fingerprint(rec)

    local contentLock = nil
    if not rec.id then
        -- No id supplied. An identical payload is the SAME entity, so reuse the record.
        -- One idless creation per content at a time, or two that yield together
        -- would both miss the index and make two.
        local ckey = contentKey(rec.owner, kind, print_)
        if not awaitFree(inflightContent, ckey) then
            return refuse(kind, 'an identical record is still being created')
        end
        local existing = byContent[ckey]
        if existing and records[existing] then
            return records[existing].id
        end
        rec.id = nextId(kind, rec.owner)
        contentLock = ckey
        inflightContent[ckey] = true
    end

    -- The key this record is stored and streamed under.
    local key = recordKey(rec.owner, rec.id)
    if not awaitFree(inflight, key) then
        if contentLock then inflightContent[contentLock] = nil end
        return refuse(kind, ('record %s is still being created'):format(tostring(rec.id)))
    end
    inflight[key] = { owner = rec.owner, cancelled = false }
    local ok, a, b = pcall(upsertLocked, rec, key, print_)
    inflight[key] = nil
    if contentLock then
        inflightContent[contentLock] = nil
    end
    if not ok then
        error(a, 0)
    end
    return a, b
end

-- Takes the INTERNAL key. Every caller resolves its own id to one first, so there is
local function remove(key)
    if not CisInvokingAllowed() then
        return false
    end
    -- false for "no such entity", which is a different answer from true and is what
    if not records[key] then
        local lock = inflight[key]
        if lock then
            -- Still being created: the creation sees this after its yield.
            lock.cancelled = true
            return true
        end
        return false
    end
    return removeMany({ key }) == 1
end

-- ------------------------------------------------------------------ the pass
-- Hoisted per-player state, so a pass allocates no closure per player.
local passPlayer, passSet, passUps, passSent, passRefused, passNow = nil, nil, nil, 0, nil, 0

-- NO PCALL PER RECORD, on purpose. The per-record step used to BUILD the payload
-- and could raise for one bad record; the payload is now built once, at upsert,
-- where a failure is the caller's. What is left here is arithmetic on fields the
-- upsert validated, and the per-player pcall in the pass still bounds any raise.
local function consider(key)
    local record = records[key]
    if not record or record.networked then
        return
    end
    local have = passSet[key]
    if have == record.rev then
        return
    end
    if have ~= nil then
        -- HELD, and in the hysteresis band or nearer: it gets the update, or it
        -- holds a stale copy until it walks out and back.
        if not stillNear(passPlayer, record) then
            return
        end
    else
        if not isNear(passPlayer, record) then
            return
        end
        local r = passRefused and passRefused[key]
        if r then
            if r.rev == record.rev and r.untilMs > passNow then
                return
            end
            passRefused[key] = nil
        end
    end
    if passSent >= MAX_UPDATES_PER_PLAYER then
        return
    end
    passSent = passSent + 1
    passSet[key] = record.rev
    if not passUps then
        passUps = {}
    end
    passUps[#passUps + 1] = record.wire
end

local function passFor(p)
    local set = has[p.src]
    -- A player who has just joined has no set at all.
    if not set then
        set = {}
        has[p.src] = set
    end

    -- Anything they hold that has gone, or that is past the EXIT radius -- not
    local rems = nil
    for key in pairs(set) do
        local record = records[key]
        if not record or not stillNear(p, record) then
            rems = rems or {}
            rems[#rems + 1] = key
        end
    end
    if rems then
        for i = 1, #rems do
            set[rems[i]] = nil
        end
    end

    passPlayer, passSet, passUps, passSent = p, set, nil, 0
    passRefused = refused[p.src]
    -- `z` is nil on purpose: the grid then does not filter on height, and the
    CisGrid.queryPoint(streamGrid, p.x, p.y, nil, consider)
    for key in pairs(unindexed) do
        consider(key)
    end
    local ups = passUps
    passPlayer, passSet, passUps, passRefused = nil, nil, nil, nil
    send(p.src, ups, rems)
end

-- ONE STREAMING PASS: every player against the records near them.
local function streamPass()
    if not CisSyncEnabled() then
        return
    end
    local positions = playerPositions()
    if #positions == 0 then
        return
    end
    passNow = GetGameTimer()

    -- PER PLAYER, UNDER PCALL.
    for i = 1, #positions do
        local ok, err = pcall(passFor, positions[i])
        if not ok then
            passPlayer, passSet, passUps, passRefused = nil, nil, nil, nil
            Logging.Error(('Cis.sync: streaming pass failed for a player: %s')
                :format(tostring(err)))
        end
    end
end

-- ------------------------------------------------------------------ snapshot
-- A client that has just loaded holds nothing and says what it DOES hold (an
-- empty claim on a fresh start). The server reconciles `has` against the claim
-- instead of wiping it, answers with one capped batch, and lets the pass deliver
-- the rest. Honoured once per SNAPSHOT_COOLDOWN_MS per player: it used to wipe
-- and resend everything, uncapped, up to the event limiter's 8 a second -- a
-- request that cost nothing to send and a full world to answer.
local function snapshotFor(src, held)
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

    -- What the client claims, bounded and type-checked.
    local claimed = {}
    if type(held) == 'table' then
        local n = 0
        for k, v in pairs(held) do
            if n >= MAX_HELD_CLAIMS then
                break
            end
            if type(k) == 'string' and type(v) == 'number' then
                claimed[k] = v
                n = n + 1
            end
        end
    end

    -- FORGET WHAT THE CLIENT DOES NOT HOLD, at the revision it holds it.
    for key, rev in pairs(set) do
        if claimed[key] ~= rev then
            set[key] = nil
        end
    end
    -- And take back what it holds and should not.
    local rems = nil
    for key, rev in pairs(claimed) do
        if set[key] == nil then
            local record = records[key]
            if record and not record.networked and record.rev == rev and stillNear(p, record) then
                set[key] = rev
            else
                rems = rems or {}
                rems[#rems + 1] = key
            end
        end
    end
    refused[src] = nil

    passPlayer, passSet, passUps, passSent, passRefused = p, set, nil, 0, nil
    passNow = GetGameTimer()
    CisGrid.queryPoint(streamGrid, p.x, p.y, nil, consider)
    for key in pairs(unindexed) do
        consider(key)
    end
    local ups, sent = passUps, passSent
    passPlayer, passSet, passUps = nil, nil, nil
    send(src, ups, rems)
    return sent
end

CisNetOn('cis_libs:server:syncSnapshot', function(src, held)
    if type(src) ~= 'number' or src <= 0 then
        return
    end
    local now = GetGameTimer()
    local last = lastSnapshot[src]
    if last and now - last < SNAPSHOT_COOLDOWN_MS then
        stats.snapshotsRefused = stats.snapshotsRefused + 1
        return
    end
    lastSnapshot[src] = now
    snapshotFor(src, held)
end)

-- A client that could not load a model after its retries says so. The server
-- forgets that it holds the record -- so it is not removed from a client that
-- never had it -- and holds back that revision for a while, so a missing asset
-- is not a resend loop. A new revision, or the backoff ending, sends it again.
local function gaveUp(src, key)
    if type(key) ~= 'string' then
        return
    end
    local set = has[src]
    if not set or set[key] == nil then
        return
    end
    set[key] = nil
    local record = records[key]
    if record then
        local mine = refused[src]
        if not mine then
            mine = {}
            refused[src] = mine
        end
        mine[key] = { rev = record.rev, untilMs = GetGameTimer() + REFUSED_BACKOFF_MS }
    end
end

-- The most keys one give-up event may carry; the client sends at most this many.
local MAX_GAVEUP_KEYS = 256

-- One key (an older client) or a LIST of them: a client batches its give-ups,
-- because one event per key ran into this event's rate limit.
CisNetOn('cis_libs:server:syncGaveUp', function(src, keys)
    if type(src) ~= 'number' or src <= 0 then
        return
    end
    if type(keys) == 'string' then
        gaveUp(src, keys)
        return
    end
    if type(keys) ~= 'table' then
        return
    end
    for i = 1, math.min(#keys, MAX_GAVEUP_KEYS) do
        gaveUp(src, keys[i])
    end
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
    refused[source] = nil
    batchSeq[source] = nil
    lastSnapshot[source] = nil
end)

-- A NETWORKED ENTITY REMOVED BEHIND THE LIBRARY'S BACK: a client deleted it, a
-- cleanup script swept it, an admin tool removed it. KeepEntity only stops the
-- SERVER from reaping it. The record is re-created (default) or dropped when it
-- asked for `respawn = false`, and re-creation is budgeted so something that
-- deletes it on sight cannot turn this into a spawn loop.
AddEventHandler('entityRemoved', function(entity)
    local key = byEntity[entity]
    if not key then
        return
    end
    byEntity[entity] = nil
    if handles[key] ~= entity then
        return
    end
    handles[key] = nil
    local record = records[key]
    if not record then
        return
    end
    if not record.respawn then
        Logging.Error(('Cis.sync: networked record %s lost its entity; the record is dropped')
            :format(tostring(record.id)))
        removeMany({ key })
        return
    end
    local now = GetGameTimer()
    local window = record.respawns
    if not window or now - window.since >= RESPAWN_WINDOW_MS then
        window = { since = now, n = 0, backoff = nil }
        record.respawns = window
    end
    window.n = window.n + 1
    if window.n > RESPAWN_MAX then
        -- Too often for this window: wait, doubling each time, and keep the record.
        local delay = window.backoff and math.min(window.backoff * 2, RESPAWN_BACKOFF_MAX_MS) or RESPAWN_BACKOFF_MS
        window.backoff = delay
        Logging.Warn(('Cis.sync: networked record %s lost its entity %d times; re-created in %d ms')
            :format(tostring(record.id), window.n, delay))
        Wait(delay)
        if records[key] ~= record or handles[key] then
            return
        end
    end
    if not awaitFree(inflight, key) then
        return
    end
    inflight[key] = { owner = record.owner, cancelled = false }
    local created = createEntity(record)
    local lock = inflight[key]
    inflight[key] = nil
    if not created then
        stats.networkedFailed = stats.networkedFailed + 1
        removeMany({ key })
        return
    end
    if lock.cancelled or records[key] ~= record or handles[key] then
        destroyEntity(created)
        return
    end
    stats.respawned = stats.respawned + 1
    attach(key, record, created)
    applyServerSide(created, record, nil)
end)

-- Records owned by a consumer that stops go with it ().
AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        -- cis_libs itself is stopping. Its clients stop with it and despawn their
        -- client-local copies on their own onResourceStop, so nothing is sent: a
        -- remove per record to every player was the largest burst this file ever
        -- produced, at the moment it could least afford one. The server's own
        -- networked entities are the server's to delete.
        for key in pairs(records) do
            local entity = handles[key]
            if entity then
                handles[key] = nil
                destroyEntity(entity)
            end
        end
        -- ALL OF IT, AND ONLY HERE. This reset used to run on EVERY stop, for every
        records = {}
        byContent = {}
        has = {}
        handles = {}
        byEntity = {}
        unindexed = {}
        refused = {}
        streamGrid = CisGrid.new()
        return
    end

    -- Creations still in flight for the stopping owner are cancelled.
    for _, lock in pairs(inflight) do
        if lock.owner == resource then
            lock.cancelled = true
        end
    end
    -- `remove` IS the fix for another resource stopping, batched per player.
    local doomed = {}
    for key, record in pairs(records) do
        if record.owner == resource then
            doomed[#doomed + 1] = key
        end
    end
    removeMany(doomed)
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
    if records[key] or inflight[key] then
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
    -- Collected first, then removed, and every holder told ONCE.
    local doomed = {}
    for key, record in pairs(records) do
        if record.owner == owner then
            doomed[#doomed + 1] = key
        end
    end
    return removeMany(doomed)
end)

-- Registered rather than counted by the diagnostics module, because the records table
CisDiagnostics.Register('server', 'syncRecords', function()
    local out = {
        total = 0, byOwner = {}, networked = 0, clientLocal = 0,
        entities = 0, refused = stats.networkedFailed, dynamic = 0,
        respawned = stats.respawned, truncated = stats.truncated,
        snapshotsRefused = stats.snapshotsRefused,
    }
    for _, record in pairs(records) do
        local owner = record.owner or '<none>'
        out.byOwner[owner] = (out.byOwner[owner] or 0) + 1
        out.total = out.total + 1
        if record.networked then out.networked = out.networked + 1
        else out.clientLocal = out.clientLocal + 1 end
        -- Counted HERE, on the walk this function was making anyway to answer `total`.
        if record.dynamic then out.dynamic = out.dynamic + 1 end
        if handles[record.key] then out.entities = out.entities + 1 end
    end
    return out
end)
