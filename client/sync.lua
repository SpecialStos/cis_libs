-- Client half of entity sync. A record whose model is unchanged is moved in place; only
-- a model or kind change forces a despawn/respawn.

local entities = {}
local records = {}

-- A consumer that wants to attach something to a synced entity -- a marker, a blip, a
local spawnHandlers = {}
local despawnHandlers = {}

local function fire(list, label, ...)
    -- By index, to a LENGTH captured first.
    local n = #list
    for i = 1, n do
        local ok, err = pcall(list[i], ...)
        if not ok then
            CisLog('error', ('Cis.sync: a consumer %s hook raised: %s')
                :format(label, tostring(err)))
        end
    end
end

local function fireSpawn(key, record)
    if #spawnHandlers == 0 then
        return
    end
    fire(spawnHandlers, 'onSpawn', key, record, entities[key])
end

local function fireDespawn(key)
    if #despawnHandlers == 0 then
        return
    end
    fire(despawnHandlers, 'onDespawn', key)
end

-- How long to wait for a model before giving up on a spawn.
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
    local tracked = records[id]
    -- Whether this client actually held something.
    local held = entry ~= nil
    -- A NETWORKED entity belongs to the server.
    if entry and entry ~= 0 and not (tracked and tracked.networked)
        and DoesEntityExist(entry) then
        DeleteEntity(entry)
    end
    entities[id] = nil
    records[id] = nil
    if held then
        fireDespawn(id)
    end
end

local function move(entity, record)
    local coords = record.coords
    SetEntityCoords(entity, coords.x, coords.y, coords.z, false, false, false)
    if record.heading then
        SetEntityHeading(entity, record.heading)
    end
    -- SetVehicleProperties diffs against its own last-applied snapshot, so calling it
    if record.kind == 'vehicle' and record.props then
        SetVehicleProperties(entity, record.props)
    end
end

-- Create the entity, and ANSWER WHETHER IT HAPPENED.
local function spawn(record)
    local modelHash = hashOf(record.model)
    local coords = record.coords
    local heading = record.heading or 0.0
    local entity

    -- A NETWORKED record is ONE entity the server already spawned.
    if record.spawnHere == false and record.netId then
        entity = NetworkGetEntityFromNetworkId(record.netId)
        if not entity or entity == 0 then
            -- The server's entity is gone, or has not arrived yet.
            return false
        end
        records[record.id] = { model = modelHash, kind = record.kind, networked = true }
        entities[record.id] = entity
        return true
    end

    if record.kind == 'ped' then
        -- The ped wrapper in client/utils.lua requests and releases the model itself,
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
            return false
        end
        entity = CreateVehicle(modelHash, coords.x, coords.y, coords.z, heading, record.networked ~= false, false)
        -- RELEASED BEFORE ANY RETURN. It used to sit inside the `entity ~= 0` branch,
        SetModelAsNoLongerNeeded(modelHash)
        if entity ~= 0 and record.props then
            SetVehicleProperties(entity, record.props)
        end
    else
        -- WAIT FOR THE MODEL, the way the ped path does.
        local ready = RequestModelTimeout(modelHash, MODEL_TIMEOUT)
        if not ready then
            SetModelAsNoLongerNeeded(modelHash)
            CisLog('error', 'sync model unavailable: ' .. tostring(record.model))
            return false
        end
        entity = CreateObject(modelHash, coords.x, coords.y, coords.z, record.networked ~= false, true, false)
        SetModelAsNoLongerNeeded(modelHash)
        if entity ~= 0 then
            SetEntityHeading(entity, heading)
            if record.freeze ~= false then
                FreezeEntityPosition(entity, true)
            end
        end
    end

    if not entity or entity == 0 then
        return false
    end
    entities[record.id] = entity
    records[record.id] = {
        model = modelHash,
        kind = record.kind,
        networked = record.networked == true,
    }
    return true
end

-- Serialise spawns per id. CreatePed yields while it waits for the model, so two rapid
local spawning = {}

-- A PER-ID GENERATION COUNTER ().
local generation = {}

local function bump(id)
    generation[id] = (generation[id] or 0) + 1
    return generation[id]
end

-- THE NEWEST STATE THE SERVER ASKED FOR, per id.
local wanted = {}
local retries = {}

-- Backoff. Bounded, because an unbounded retry is a per-record thread that never dies
local RETRY_BASE_MS = 500
local RETRY_MAX = 4

local scheduleRetry

-- Bring ONE id up to date with what the server wants.
local function drive(id)
    -- A spawn is already in flight.
    if spawning[id] then
        return
    end

    local record = wanted[id]
    if not record then
        return
    end

    local previous = records[id]
    local modelHash = hashOf(record.model)
    local sameEntity = previous
        and previous.model == modelHash
        and previous.kind == record.kind
        and alive(id)

    if sameEntity then
        move(entities[id], record)
        wanted[id] = nil
        retries[id] = nil
        return
    end

    spawning[id] = true
    -- The generation this spawn is serving.
    local mine = generation[id]
    despawn(id)
    local ok = spawn(record)
    spawning[id] = nil

    if not ok then
        -- The model is not here yet. Retried rather than abandoned: a prop synced a
        scheduleRetry(id)
        return
    end
    retries[id] = nil

    if generation[id] ~= mine then
        -- The record was removed while the model was loading.
        despawn(id)
        return
    end

    -- FIRED HERE, NOT IN `spawn`, and that placement is the point.
    fireSpawn(id, record)

    -- Something newer arrived while we were waiting.
    local newest = wanted[id]
    if newest and newest ~= record then
        drive(id)
    end
end

function scheduleRetry(id)
    local attempt = (retries[id] or 0) + 1
    retries[id] = attempt
    if attempt > RETRY_MAX then
        retries[id] = nil
        CisLog('error', 'sync gave up retrying an unavailable model after '
            .. tostring(RETRY_MAX) .. ' attempts')
        return
    end
    local delay = RETRY_BASE_MS * attempt
    CreateThread(function()
        Wait(delay)
        retries[id] = nil
        -- Only if the server still wants it AND nothing else is mid-spawn.
        if wanted[id] and not spawning[id] then
            drive(id)
        end
    end)
end

-- EVERY FIELD THE CLIENT RELIES ON, CHECKED, AND THE REFUSAL NAMED.

local function validCoords(c)
    -- A VECTOR3 IS NOT A TABLE. CfxLua reports a vector as userdata, so type() is not table.
    if c == nil or (type(c) ~= 'table' and type(c) ~= 'vector3') then
        return false, ('coords is a %s'):format(type(c))
    end
    local x, y, z = c.x, c.y, c.z
    if type(x) ~= 'number' or type(y) ~= 'number' or type(z) ~= 'number' then
        return false, 'coords x, y and z must all be numbers'
    end
    if x ~= x or y ~= y or z ~= z then
        return false, 'coords contain NaN'
    end
    return true
end

local function validModel(m)
    local t = type(m)
    -- A table is NOT a model. It used to be accepted, because `tostring` turns it into
    if t ~= 'string' and t ~= 'number' then
        return false, ('model must be a name or a hash, got a %s'):format(t)
    end
    return true
end

local function apply(record)
    -- `record.id` was already checked for being a string at the event boundary, where
    local ok, why = validCoords(record.coords)
    if not ok then
        CisLog('error', ('sync: ignoring a malformed record %s: %s')
            :format(tostring(record.id), why))
        return
    end
    ok, why = validModel(record.model)
    if not ok then
        CisLog('error', ('sync: ignoring a malformed record %s: %s')
            :format(tostring(record.id), why))
        return
    end
    -- NOT a return when a spawn is in flight: the newest state is recorded and the
    wanted[record.id] = record
    drive(record.id)
end

RegisterNetEvent('cis_libs:client:syncUpsert', function(record)
    -- THE IDENTITY IS `key`, NOT `id`.
    if type(record) ~= 'table' or type(record.key) ~= 'string' then
        return
    end
    record.id = record.key
    if CisTiming then
        CisTiming.measure('clientSyncPass', function()
            apply(record)
        end)
    else
        apply(record)
    end
end)

RegisterNetEvent('cis_libs:client:syncRemove', function(id)
    if type(id) ~= 'string' then
        return
    end
    -- The newest wanted state goes FIRST.
    wanted[id] = nil
    retries[id] = nil
    -- Bumped whether or not a spawn is running, so a remove that arrives DURING a model
    bump(id)
    despawn(id)
end)

-- A CLIENT THAT HAS JUST RELOADED HOLDS NOTHING, AND SAYS SO.
TriggerServerEvent('cis_libs:server:syncSnapshot')

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

-- THE READ SIDE OF A SPAWN HOOK, for a consumer that would rather ask than be told.
exports('GetSyncedEntity', function(key)
    if type(key) ~= 'string' then
        return nil
    end
    local handle = entities[key]
    if handle == nil or handle == 0 then
        return nil
    end
    if not DoesEntityExist(handle) then
        return nil
    end
    return handle
end)

-- Register a consumer hook. Refuses anything that is not a function rather than storing
exports('AddSyncSpawnHandler', function(fn)
    if type(fn) ~= 'function' then
        return false, 'Cis.sync.onSpawn needs a function'
    end
    spawnHandlers[#spawnHandlers + 1] = fn
    return true
end)

exports('AddSyncDespawnHandler', function(fn)
    if type(fn) ~= 'function' then
        return false, 'Cis.sync.onDespawn needs a function'
    end
    despawnHandlers[#despawnHandlers + 1] = fn
    return true
end)

-- Spawned entities are counted separately from the records that asked for them, because
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
