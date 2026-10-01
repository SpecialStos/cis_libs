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
    despawn(record.id)
    spawn(record)
    spawning[record.id] = nil
end

RegisterNetEvent('cis_libs:client:syncUpsert', function(record)
    apply(record)
end)

RegisterNetEvent('cis_libs:client:syncRemove', function(id)
    if type(id) == 'string' then
        despawn(id)
    end
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
