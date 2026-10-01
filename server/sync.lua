-- Server-authoritative entity sync. Records are versioned so a dynamic record
-- only rebroadcasts when its data actually changed, instead of every tick.
--
-- Two identities are in play and they are not the same thing. `id` is the
-- handle the client uses to move or despawn an entity; the content fingerprint
-- is how the server decides a second call is describing the thing it already
-- has. The fingerprint deliberately ignores `id` (see canonical below) so a
-- caller who does not manage ids gets idempotence too.

local records = {}
local seq = 0
local revisions = 0

-- Server-issued, and never taken from the caller unless the caller supplied
-- one. A client-visible id that a caller could choose would collide across
-- resources sharing this table.
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
-- caller changing any field is never silently dropped. The id is excluded too:
-- CONTENT identity is what decides whether two calls describe the same entity,
-- and folding the id in makes every idless call unique by construction, which
-- defeats the no-op upsert for every caller that does not manage ids itself.
--
-- Concretely: with `id` included, the first `SyncCreate('door', {...})` and a
-- second identical one would produce two different fingerprints, the second
-- would find no `byContent` match, and every repeat call would spawn a
-- duplicate entity. The idless caller has no other way to say "same entity",
-- so the id has to be the one field the fingerprint cannot see.
--
-- `rev` and `print` are excluded because they are written BY this function
-- from the fingerprint's own inputs; including them would make the fingerprint
-- depend on its own previous value. Keys are sorted because pairs() order is
-- undefined, and an unsorted walk would fingerprint identical tables
-- differently and break the no-op.
local function canonical(value, out)
    out = out or {}
    local t = type(value)
    if t ~= 'table' then
        out[#out + 1] = tostring(value)
        return out
    end
    local keys = {}
    for k in pairs(value) do
        if k ~= 'rev' and k ~= 'print' and k ~= 'id' then
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

-- id <-> content index, so the implicit lookup below is O(1) rather than a
-- scan of every synced entity on the server. `records` alone cannot answer it:
-- `records` is keyed by id, and the question being asked is "which record has
-- THIS content", which is the reverse direction. Without the index that
-- question costs a full walk of the table plus a fingerprint recomputation per
-- entry on EVERY idless upsert -- and an idless upsert is the common case, so
-- the cost lands on the path a caller hits most.
--
-- The kind is part of the key, not just the content: two entities of
-- different kinds can legitimately have identical fields, and they must not
-- collapse into one record. \29 is ASCII SUB, which cannot occur in a model
-- name or a coordinate.
local byContent = {}

local function contentKey(kind, print_)
    return kind .. '\29' .. print_
end

local function indexRecord(id, stored)
    byContent[contentKey(stored.kind, stored.print)] = id
end

local function unindexRecord(id, stored)
    if not stored then
        return
    end
    local key = contentKey(stored.kind, stored.print)
    -- ONLY IF THE INDEX STILL POINTS AT THIS RECORD. The index is keyed on
    -- content alone, so two caller-managed ids can share a key -- and the map
    -- holds one of them, whichever was written last. Clearing it unconditionally
    -- meant updating or removing the OTHER record wiped the index entry of a
    -- record that still existed, so a later upsert with that content found no
    -- index, allocated a fresh id, and spawned a duplicate of an entity that was
    -- already in the world. The index exists precisely to stop that.
    if byContent[key] == id then
        byContent[key] = nil
    end
end

local function upsert(kind, data)
    -- Two refusals before any work, both returning nil rather than raising: a
    -- caller whose resource is not on the allow-list gets no entity and no
    -- error, so it cannot tell the difference between "refused" and "sync is
    -- switched off" and does not have to try.
    if not CisInvokingAllowed() then
        return nil
    end
    if not CisSyncEnabled() then
        return nil
    end
    data = data or {}
    -- Refused rather than defaulted. A record with no coords is not a record
    -- that can be range-filtered, and defaulting them to 0,0,0 would broadcast
    -- every such entity to every player on the server.
    if type(data.coords) ~= 'table' or data.coords.x == nil or data.coords.y == nil then
        Logging.Error('Cis.sync.' .. tostring(kind) .. ' rejected: missing coords')
        return nil
    end
    -- Normalised into a fresh three-number table, so `z` is always a number and
    -- a vector3 from a framework is stored as the same shape as a plain table.
    -- Anything else would make the fingerprint depend on which of the two the
    -- caller happened to pass.
    data.coords = {
        x = data.coords.x,
        y = data.coords.y,
        z = data.coords.z or 0.0,
    }
    data.kind = kind
    data.heading = data.heading or 0.0
    data.networked = data.networked ~= false
    data.dynamic = data.dynamic and true or false

    -- Fingerprint AFTER the defaults are applied and BEFORE an id is chosen,
    -- so two calls that describe the same entity agree on their content.
    local print_ = fingerprint(data)

    if data.id then
        -- Caller-managed identity: the id is authoritative and the fingerprint
        -- only decides whether anything actually changed.
        local previous = records[data.id]
        if previous and previous.print == print_ then
            return previous.id
        end
    else
        -- No id supplied. An identical payload is the SAME entity, so reuse the
        -- record that already holds it. Without this, DOCUMENTATION.md's
        -- "re-sending identical data is a no-op" held only for callers that
        -- tracked ids themselves, and every other caller got a duplicate
        -- entity per call -- which is what the integration suite caught.
        local existing = byContent[contentKey(kind, print_)]
        if existing and records[existing] then
            return existing
        end
        data.id = nextId(kind)
    end

    -- Monotonic, so a client can tell "newer" from "older" without comparing
    -- payloads. It is a stamp, not a version to merge: nothing reconciles a
    -- revision that arrives out of order, which cannot happen because every
    -- broadcast for a record is sent from this one coroutine in order.
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
    -- Reindex in both directions: the old content no longer points at this id,
    -- and the new content does. Doing it in this order means a lookup can never
    -- observe an id that points at content the record no longer has.
    unindexRecord(data.id, records[data.id])
    records[data.id] = stored
    indexRecord(data.id, stored)

    -- Range-filtered per record, so a player is only sent entities they could
    -- plausibly see. The 80.0 default is a radius in game units, not a
    -- distance, and a caller can widen it per record with `scope`.
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
    -- false for "no such entity", which is a different answer from true and is
    -- what lets a caller tell a stale id from a refused call.
    if not records[id] then
        return false
    end
    unindexRecord(id, records[id])
    records[id] = nil
    -- Broadcast to EVERYONE (-1), not to the range that received the upsert.
    -- The server does not keep a per-record audience, and a player who is
    -- currently out of range may already hold the entity -- if they stream in
    -- later the client drops what it has not seen, but a despawn they were
    -- never told about would leak a local entity that nothing cleans up.
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

-- The dynamic rebroadcast loop. Two intervals, and each is a budget rather
-- than a tuning knob:
--
--   2000ms -- how stale a MOVING entity may get. A prop that drifts at a walk
--     covers a few metres between rebroadcasts, which is below what the client
--     interpolates over. Halving it doubles the per-record, per-player event
--     traffic for a lag nobody can see, and that traffic is the cost:
--     broadcastDynamic fans out to every player in range of every dynamic
--     record on the server.
--
--   1000ms -- how long a newly created dynamic record waits before it starts
--     being broadcast at all. Records only appear through another resource's
--     call, so "has one appeared yet" has to be polled; 1s bounds that lag. It
--     is not tightened because on the overwhelmingly common server there are
--     no dynamic records at all, and the only work this branch does is the
--     scan below. It is not loosened either, because a one-second wait before
--     a moving prop appears is visible.
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
    -- Tell every client to drop what it holds, unconditionally and with no
    -- range filter, because the server no longer knows who holds what. A
    -- client that keeps a networked entity after the server forgot it is a
    -- permanently orphaned prop.
    for id in pairs(records) do
        TriggerClientEvent('cis_libs:client:syncRemove', -1, id)
    end
    -- Both tables, not just records. byContent maps content to an id in
    -- records, and leaving it populated across a stop/start would resolve
    -- lookups to ids that no longer exist -- the guard in upsert would then
    -- fall through and allocate a fresh id for content already present, which
    -- is the duplicate-entity case by another route.
    records = {}
    byContent = {}
end)

exports('SyncCreate', function(kind, data)
    return upsert(kind, data)
end)

exports('SyncRemove', function(id)
    return remove(id)
end)
