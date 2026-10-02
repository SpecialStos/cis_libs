-- Client half of entity sync. A record whose model is unchanged is moved in
-- place; only a model or kind change forces a despawn/respawn.
--
-- `entities`, `records` and `spawning` are process state (COMPATIBILITY.md
-- §10). `records` in particular is what makes the move-instead-of-respawn
-- decision possible, so a copy of this file would respawn on every upsert of
-- entities it did not itself create.

local entities = {}
local records = {}

-- How long to wait for a model before giving up on a spawn. The same budget
-- CreatePed already used, so a prop and a ped of the same rarity take the same
-- time to appear rather than one of them appearing instantly and the other
-- never.
local MODEL_TIMEOUT = 5000

local function hashOf(model)
    if type(model) == 'number' then
        return model
    end
    return joaat(tostring(model))
end

local function alive(id)
    local handle = entities[id]
    return handle and handle ~= 0 and DoesEntityExist(handle)
end

local function despawn(id)
    local entry = entities[id]
    if entry and entry ~= 0 and DoesEntityExist(entry) then
        DeleteEntity(entry)
    end
    entities[id] = nil
    records[id] = nil
end

local function move(entity, record)
    local coords = record.coords
    SetEntityCoords(entity, coords.x, coords.y, coords.z, false, false, false)
    if record.heading then
        SetEntityHeading(entity, record.heading)
    end
    -- SetVehicleProperties diffs against its own last-applied snapshot, so
    -- calling it on every position tick is cheap and skips unchanged fields.
    if record.kind == 'vehicle' and record.props then
        SetVehicleProperties(entity, record.props)
    end
end

local function spawn(record)
    local modelHash = hashOf(record.model)
    local coords = record.coords
    local heading = record.heading or 0.0
    local entity

    -- A NETWORKED record is ONE entity the server already spawned. The client
    -- resolves the netId and tracks that entity instead of creating its own --
    -- creating one here is exactly the duplicate that `networked` used to
    -- produce for every in-range client.
    if record.spawnHere == false and record.netId then
        entity = NetworkGetEntityFromNetworkId(record.netId)
        if not entity or entity == 0 then
            -- The server's entity is gone (it was despawned, or the session it
            -- belonged to ended). Nothing to track; the server will send an
            -- upsert if it still wants the record.
            return
        end
        records[record.id] = { model = modelHash, kind = record.kind, networked = true }
        entities[record.id] = entity
        return
    end

    if record.kind == 'ped' then
        entity = CreatePed(modelHash, coords, heading, {
            networked = record.networked,
            freeze = record.freeze,
            invincible = record.invincible,
            blockEvents = record.blockEvents,
            scenario = record.scenario,
        })
    elseif record.kind == 'vehicle' then
        local ready = RequestModelTimeout(modelHash, MODEL_TIMEOUT)
        if not ready then
            CisLog('error', 'sync model unavailable: ' .. tostring(record.model))
            return
        end
        entity = CreateVehicle(modelHash, coords.x, coords.y, coords.z, heading, record.networked ~= false, false)
        if entity ~= 0 and record.props then
            SetVehicleProperties(entity, record.props)
        end
    else
        -- WAIT FOR THE MODEL, the way the ped path does. This branch used to
        -- call `RequestModel` and then immediately `CreateObject`, and a
        -- RequestModel that has not finished is not a loaded model:
        -- `CreateObject` returned 0, the `entity ~= 0` test below dropped it,
        -- `spawning[id]` was cleared, and nothing ever retried. A static prop
        -- synced before its model streamed simply never appeared, for the rest
        -- of the session, with no error anywhere.
        local ready = RequestModelTimeout(modelHash, MODEL_TIMEOUT)
        if not ready then
            CisLog('error', 'sync model unavailable: ' .. tostring(record.model))
            return
        end
        entity = CreateObject(modelHash, coords.x, coords.y, coords.z, record.networked ~= false, true, false)
        if entity ~= 0 then
            SetEntityHeading(entity, heading)
            if record.freeze ~= false then
                FreezeEntityPosition(entity, true)
            end
        end
    end

    if entity and entity ~= 0 then
        entities[record.id] = entity
        records[record.id] = {
            model = modelHash,
            kind = record.kind,
        }
        SetModelAsNoLongerNeeded(modelHash)
    end
end

-- Serialise spawns per id. CreatePed yields while it waits for the model, so
-- two rapid upserts for the same id would otherwise both pass the despawn
-- check and leave one orphan entity behind.
local spawning = {}

-- A PER-ID GENERATION COUNTER (L-C20).
--
-- `spawning[id]` says a spawn is in progress. It cannot say whether the record
-- being waited for is still the one the server wants: `spawn` yields for up to
-- five seconds waiting for a model, and during that yield the server may stream
-- the player out of range and send a remove. The remove finds `spawning[id]`
-- true, does nothing, and the spawn then completes -- creating an entity for a
-- record the server has already forgotten, in a world where nothing will ever
-- remove it again. A client-local entity with no owner and no sweeper is the
-- most permanent leak this library can produce.
--
-- A generation counter makes the wait cancellable without cancelling the yield:
-- the spawn records the generation it is serving, and the remove bumps it. The
-- spawn checks on the way out and deletes what it made if the number moved.
local generation = {}

local function bump(id)
    generation[id] = (generation[id] or 0) + 1
    return generation[id]
end

local function apply(record)
    if type(record) ~= 'table' or type(record.id) ~= 'string' then
        return
    end
    if type(record.coords) ~= 'table' or record.coords.x == nil then
        return
    end
    if spawning[record.id] then
        return
    end

    local previous = records[record.id]
    local modelHash = hashOf(record.model)
    local sameEntity = previous
        and previous.model == modelHash
        and previous.kind == record.kind
        and alive(record.id)

    if sameEntity then
        move(entities[record.id], record)
        return
    end

    spawning[record.id] = true
    -- The generation this spawn is serving. Anything that removes the record
    -- while we wait bumps it, and the check after `spawn` catches that.
    local mine = bump(record.id)
    despawn(record.id)
    spawn(record)
    if generation[record.id] ~= mine then
        -- The record was removed while the model was loading. Delete what the
        -- spawn just made rather than leaving an orphan nothing will clean up.
        despawn(record.id)
    end
    spawning[record.id] = nil
end

RegisterNetEvent('cis_libs:client:syncUpsert', function(record)
    apply(record)
end)

RegisterNetEvent('cis_libs:client:syncRemove', function(id)
    if type(id) ~= 'string' then
        return
    end
    -- Bumped whether or not a spawn is running, so a remove that arrives
    -- DURING a model wait is still visible to the spawn on its way out.
    bump(id)
    despawn(id)
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then
        return
    end
    for id in pairs(entities) do
        despawn(id)
    end
end)

exports('GetSyncedEntities', function()
    local out = {}
    for id, handle in pairs(entities) do
        out[id] = handle
    end
    return out
end)

-- Spawned entities are counted separately from the records that asked for them,
-- because those come apart in exactly one direction: a record whose model never
-- loads leaves a record and no entity, and a client that deleted nothing leaves
-- an entity and no record.
CisDiagnostics.Register('client', 'syncEntities', function()
    local out = { entities = 0, records = 0, spawning = 0, recordsByOwner = {} }
    for _ in pairs(entities) do out.entities = out.entities + 1 end
    for _, record in pairs(records) do
        out.records = out.records + 1
        local owner = record.owner or '<none>'
        out.recordsByOwner[owner] = (out.recordsByOwner[owner] or 0) + 1
    end
    for _ in pairs(spawning) do out.spawning = out.spawning + 1 end
    return out
end)
