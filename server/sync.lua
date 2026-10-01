-- Server-authoritative entity sync, streamed by distance.
--
-- STREAMING, NOT BROADCASTING. A record is not sent once to whoever happens to
-- be near it at creation; a pass runs every second and tells each player about
-- what is near THEM, and removes what is not. That is the difference between a
-- map that is correct and a map that is only correct for whoever was online
-- when the doors were synced -- and on a real server, the players who were
-- online when the doors were synced are nobody, because the doors are synced at
-- boot and players join afterwards.
--
-- TWO IDENTITIES, and they are not the same thing. `id` is the handle the client
-- uses to move or despawn an entity; the content fingerprint is how the server
-- decides a second call is describing the thing it already has. The fingerprint
-- deliberately ignores `id` (see canonical below) so a caller who does not
-- manage ids gets idempotence too.
--
-- CLIENT-LOCAL BY DEFAULT. A synced entity belongs to the player the server
-- streamed it to. Ask for `networked = true` and the server spawns ONE entity
-- and sends its netId instead, so every client renders the same entity rather
-- than each making its own.

local records = {}
local seq = 0
local revisions = 0

-- src -> { [recordId] = true }. Which records each player has been TOLD about.
--
-- This set is the whole of the streaming bookkeeping, and it is what turns a
-- per-second pass from a per-second event storm into a per-second comparison.
-- Without it the pass re-sends every nearby record to every player every second
-- forever; with it, a player is told about an id once, on the pass where they
-- enter range, and told to drop it on the pass where they leave.
--
-- Entries are removed on the leave, on SyncRemove, and on the player dropping,
-- because a stale entry is a player who is never told to despawn something they
-- are no longer near -- which on the client is a permanently orphaned
-- client-local entity.
local has = {}

-- How many records are DYNAMIC, kept as a counter rather than derived by
-- scanning `records`. The scan is the difference between an O(1) pass and an
-- O(records) pass, and the pass runs every second for the lifetime of the
-- server: on a server with 400 static door records and no dynamic ones at all,
-- the scan is 400 table lookups a second to learn something a counter already
-- knows.
local dynamicCount = 0

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

-- The default streaming radius, in game units. A per-record `scope` overrides
-- it: a synced vehicle wants a much wider radius than a shop prop, and a
-- per-record field is how the caller says so without a global setting.
local DEFAULT_SCOPE = 80.0

-- How often the streaming pass runs. See the loop at the bottom for why this
-- number is a budget rather than a preference.
local STREAM_MS = 1000

-- How long a networked spawn waits for its model. Same budget the client uses
-- (client/sync.lua MODEL_TIMEOUT), so a prop and a vehicle of the same rarity
-- take the same time to appear rather than one appearing instantly and the
-- other never.
local MODEL_TIMEOUT_MS = 5000

-- The only distance question this file asks. Squared rather than `sqrt`, because
-- every pair is tested once per pass and the square root buys nothing: the
-- comparison is exact either way.
local function isNear(p, coords, radius)
    local dx, dy, dz = p.x - coords.x, p.y - coords.y, p.z - coords.z
    return dx * dx + dy * dy + dz * dz <= (radius or DEFAULT_SCOPE) ^ 2
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

-- What actually goes over the wire.
--
-- A separate table from the stored record, and that separation is the point.
-- The stored record carries `print` -- the content fingerprint -- which can be
-- hundreds of bytes of concatenated field values, identical for every client
-- receiving it and of no use to any of them. It also carries `rev`, which exists
-- so the SERVER can tell an update from a repeat.
--
-- The client gets only what it needs to create or move the entity. Building the
-- table per send, rather than mutating the stored record, is also what lets the
-- server keep its own bookkeeping without leaking it onto the wire.
local function payload(record)
    local out = {}
    for k, v in pairs(record) do
        if k ~= 'print' and k ~= 'rev' and k ~= 'dynamic' and k ~= 'scope' then
            out[k] = v
        end
    end
    return out
end

-- Spawn a networked entity ONCE, on the server, and return its netId.
--
-- The alternative -- letting each client create its own networked copy -- is
-- what `networked = true` used to mean in practice, and it is the duplicate bug
-- this whole default exists to stop. A networked entity is ONE entity that every
-- client sees; the server owns it, so every client receives the SAME one rather
-- than each making its own.
--
-- nil when the spawn fails. The caller then keeps a client-local copy rather
-- than dropping the record: an entity that appears on every client separately is
-- wrong, but an entity that appears nowhere is worse, and the operator can tell
-- the two apart from the console line this logs.
local function spawnNetworked(record)
    if type(CreateObject) ~= 'function' or type(NetworkGetNetworkIdFromEntity) ~= 'function' then
        return nil
    end
    local model = record.model
    local hash = type(model) == 'number' and model or joaat(tostring(model))
    RequestModel(hash)
    local waited = 0
    while not HasModelLoaded(hash) and waited < MODEL_TIMEOUT_MS do
        Wait(0)
        waited = waited + 1
    end
    if not HasModelLoaded(hash) then
        Logging.Error('Cis.sync: networked model unavailable: ' .. tostring(model))
        return nil
    end
    local entity = CreateObject(hash, record.coords.x, record.coords.y, record.coords.z,
        true, true, false)
    if not entity or entity == 0 then
        SetModelAsNoLongerNeeded(hash)
        return nil
    end
    SetEntityHeading(entity, record.heading or 0.0)
    FreezeEntityPosition(entity, true)
    local netId = NetworkGetNetworkIdFromEntity(entity)
    SetModelAsNoLongerNeeded(hash)
    return netId
end

local function upsert(kind, data)
    -- Two refusals before any work, both returning nil rather than raising: a
    -- caller whose resource is not on the allow-list gets no entity and no
    -- error, so it cannot tell the difference from "sync is switched off" and
    -- does not have to try.
    if not CisInvokingAllowed() then
        return nil
    end
    if not CisSyncEnabled() then
        return nil
    end
    data = data or {}
    -- Refused rather than defaulted. A record with no coords is not a record
    -- that can be range-filtered, and defaulting them to 0,0,0 would stream
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
    -- CLIENT-LOCAL BY DEFAULT (D2). It used to default to true, which meant
    -- every in-range client spawned its OWN networked copy: two players standing
    -- beside one synced prop saw two of it, and neither owned either -- so
    -- neither could despawn it, and any player could drive it away.
    --
    -- A networked entity belongs to the SERVER; a client-local one belongs to
    -- the client that was told about it. That is exactly the property a
    -- range-filtered sync wants: the server decides who may see what.
    data.networked = data.networked == true
    data.dynamic = data.dynamic and true or false
    -- L-C7: the owning resource, so a consumer that stops takes its records with
    -- it. cis_libs owns no table and never creates an entity a caller did not
    -- ask for, but it is the one place that knows which resource asked.
    data.owner = GetInvokingResource() or 'cis_libs'

    -- Fingerprint AFTER the defaults are applied and BEFORE an id is chosen, so
    -- two calls that describe the same entity agree on their content.
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
        -- tracked ids themselves, and every other caller got a duplicate entity
        -- per call -- which is what the integration suite caught.
        local existing = byContent[contentKey(kind, print_)]
        if existing and records[existing] then
            return existing
        end
        data.id = nextId(kind)
    end

    -- Monotonic, so a client can tell "newer" from "older" without comparing
    -- payloads. It is a stamp, not a version to merge: nothing reconciles a
    -- revision that arrives out of order, which cannot happen because every
    -- send for a record comes from this one coroutine in order.
    revisions = revisions + 1
    -- Copy, do not retain the caller's table. Otherwise a later mutation by the
    -- caller would change the stored record behind a stale fingerprint and the
    -- change would never be streamed.
    local stored = {}
    for k, v in pairs(data) do
        stored[k] = v
    end
    stored.rev = revisions
    stored.print = print_

    -- A NETWORKED record is one entity the server owns. Spawn it once, here, and
    -- carry its netId; every client then renders that same entity instead of
    -- making its own. `spawnHere = false` tells the client not to create
    -- anything for a record that already exists on the network.
    if stored.networked and not stored.netId then
        stored.netId = spawnNetworked(stored)
        stored.spawnHere = false
    end

    local previous = records[data.id]
    unindexRecord(data.id, previous)
    -- The dynamic tally is a COUNTER, not a scan. Subtracting the old record's
    -- contribution before adding the new one keeps it exact through an update
    -- that flips `dynamic`, which is the case a naive `if stored.dynamic then
    -- count = count + 1 end` gets wrong.
    if previous and previous.dynamic then
        dynamicCount = dynamicCount - 1
    end
    records[data.id] = stored
    if stored.dynamic then
        dynamicCount = dynamicCount + 1
    end
    indexRecord(stored.id, stored)

    -- Tell whoever is ALREADY in range right now. This is an optimisation ON TOP
    -- of the streaming pass, not a replacement for it: a player who walks into
    -- range later is the pass's job. Sending here means the common case -- a prop
    -- created where people already are -- appears at once rather than up to a
    -- second later.
    local positions = playerPositions()
    for i = 1, #positions do
        local p = positions[i]
        if isNear(p, stored.coords, stored.scope or DEFAULT_SCOPE) then
            local set = has[p.src]
            if not set then
                set = {}
                has[p.src] = set
            end
            set[stored.id] = true
            TriggerClientEvent('cis_libs:client:syncUpsert', p.src, payload(stored))
        end
    end
    return stored.id
end

-- Forget one id in a player's set.
local function forget(src, id)
    local set = has[src]
    if set then
        set[id] = nil
        if next(set) == nil then
            has[src] = nil
        end
    end
end

local function remove(id)
    if not CisInvokingAllowed() then
        return false
    end
    -- false for "no such entity", which is a different answer from true and is
    -- what lets a caller tell a stale id from a refused call.
    local record = records[id]
    if not record then
        return false
    end
    unindexRecord(id, record)
    if record.dynamic then
        dynamicCount = dynamicCount - 1
    end
    records[id] = nil

    -- A networked entity belongs to the server, so the server deletes it. A
    -- client-local one has to be deleted by each client holding it, and the
    -- server cannot enumerate those except through its own `has` sets.
    if record.networked and record.netId and type(NetworkGetEntityFromNetworkId) == 'function' then
        local entity = NetworkGetEntityFromNetworkId(record.netId)
        if entity and entity ~= 0 and DoesEntityExist(entity) then
            DeleteEntity(entity)
        end
    end

    -- Tell every player who HOLDS it, and clear their `has` entry. Clearing it
    -- is not tidiness: the streaming pass decides what to send by consulting
    -- `has`, so a surviving entry would have the pass re-send a record that no
    -- longer exists and every client would respawn it -- forever.
    local told = 0
    for src in pairs(has) do
        if has[src] and has[src][id] then
            forget(src, id)
            TriggerClientEvent('cis_libs:client:syncRemove', src, id)
            told = told + 1
        end
    end
    -- Nobody in range holds it, but a client that received it earlier and has
    -- since walked away still has it. One broadcast covers that without
    -- enumerating a set that is already empty.
    if told == 0 then
        TriggerClientEvent('cis_libs:client:syncRemove', -1, id)
    end
    return true
end

-- ONE STREAMING PASS: every player against every record.
--
-- The defect this replaces: records were sent once, at creation, to whoever
-- happened to be within 80m AT THAT MOMENT. A player who joined a minute later,
-- or walked up to the entity a minute later, was never told -- the entity simply
-- did not exist for them, with nothing in any log. On a server whose doors and
-- shop props are synced at boot and whose players join afterwards, that is most
-- of the map silently missing.
--
-- The pass is O(players x records), which is the honest cost of "who should see
-- what right now". That is also why `has` matters: re-sending every nearby
-- record to everyone every second is the same scan PLUS an event per pair per
-- second, against every client on the server.
--
-- A DYNAMIC record is re-sent on every pass it is in range for, because it
-- moves: the client moves the entity in place rather than respawning it, so the
-- cadence costs traffic and not flicker. A STATIC one is sent only on the pass
-- where the player enters range, and never again.
local function streamPass()
    if not CisSyncEnabled() then
        return
    end
    local positions = playerPositions()
    if #positions == 0 then
        return
    end

    for _, p in ipairs(positions) do
        local set = has[p.src]
        -- A player who has just joined has no set at all. That is the
        -- late-joiner case, and it is why this is keyed off nil rather than off
        -- emptiness.
        if not set then
            set = {}
            has[p.src] = set
        end

        -- Anything they hold that is no longer in range, or that has been
        -- removed from `records` entirely, goes first. Collected into a list
        -- first because mutating a table mid-iteration skips entries.
        local stale = nil
        for id in pairs(set) do
            local record = records[id]
            if not record or not isNear(p, record.coords, record.scope or DEFAULT_SCOPE) then
                stale = stale or {}
                stale[#stale + 1] = id
            end
        end
        if stale then
            for i = 1, #stale do
                local id = stale[i]
                set[id] = nil
                TriggerClientEvent('cis_libs:client:syncRemove', p.src, id)
            end
        end

        for id, record in pairs(records) do
            local near = isNear(p, record.coords, record.scope or DEFAULT_SCOPE)
            if near and not set[id] then
                set[id] = true
                TriggerClientEvent('cis_libs:client:syncUpsert', p.src, payload(record))
            elseif near and record.dynamic then
                TriggerClientEvent('cis_libs:client:syncUpsert', p.src, payload(record))
            end
        end
    end
end

-- The streaming loop.
--
-- 1000ms is a BUDGET, not a tuning knob: it is the longest a player can walk up
-- to a synced entity and not see it. Halving it doubles the per-second scan
-- against every record on the server; doubling it produces a two-second wait to
-- see a prop you are standing next to, which is what gets reported as "sync is
-- broken".
--
-- The pass is skipped when nothing is synced at all, which is the default state
-- of a server running cis_libs alone: there the loop costs one table read and
-- one Wait a second.
CreateThread(function()
    while true do
        if next(records) then
            streamPass()
        end
        Wait(STREAM_MS)
    end
end)

-- A player who drops takes their whole set with them. Server ids are REUSED, so
-- a returning player would otherwise inherit every record the previous occupant
-- of their id was told about -- and would never be sent a remove for any of
-- them, because the pass only removes what has gone out of range.
AddEventHandler('playerDropped', function()
    has[source] = nil
end)

-- Records owned by a consumer that stops go with it (L-C7). ox_lib does not have
-- this problem because it runs inside the consumer's own VM; this library does
-- not, and a resource that stops and restarts would otherwise accumulate its
-- entities for the lifetime of the process and stream them to a growing list of
-- players every pass.
AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        -- cis_libs itself is stopping: tell every client to drop everything,
        -- because afterwards the server no longer knows who holds what, and a
        -- client keeping a client-local entity is a permanently orphaned prop.
        for id in pairs(records) do
            TriggerClientEvent('cis_libs:client:syncRemove', -1, id)
        end
    else
        for id, record in pairs(records) do
            if record.owner == resource then
                remove(id)
            end
        end
    end
    -- Both tables, not just records. byContent maps content to an id in records,
    -- and leaving it populated across a stop/start would resolve lookups to ids
    -- that no longer exist -- the guard in upsert would then fall through and
    -- allocate a fresh id for content already present, which is the
    -- duplicate-entity case by another route.
    records = {}
    byContent = {}
    has = {}
    dynamicCount = 0
end)

exports('SyncCreate', function(kind, data)
    return upsert(kind, data)
end)

exports('SyncRemove', function(id)
    return remove(id)
end)