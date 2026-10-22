-- Client half of entity sync. A record whose model is unchanged is moved in place; only
-- a model or kind change forces a despawn/respawn.
--
-- CLIENT-LOCAL RECORDS arrive in numbered batches (`cis_libs:client:syncBatch`) and
-- are spawned here as NON-networked entities. NETWORKED records never arrive that
-- way: the server created the one entity, OneSync streams it, and its `cis_sync`
-- state bag says which record it is. This file only resolves it, applies the
-- metadata when this client OWNS it, and tells consumer hooks. It never creates,
-- moves or deletes a networked entity.

local entities = {}
local records = {}

-- A consumer that wants to attach something to a synced entity -- a marker, a blip, a
-- target -- registers here. Entries are { fn, owner }: a hook passed from another
-- resource is a function reference into that resource, released when it stops.
local spawnHandlers = {}
local despawnHandlers = {}

local function fire(list, label, ...)
    -- By index, to a LENGTH captured first.
    local n = #list
    for i = 1, n do
        local entry = list[i]
        if entry then
            local ok, err = pcall(entry.fn, ...)
            if not ok then
                CisLog('error', ('Cis.sync: a consumer %s hook (%s) raised: %s')
                    :format(label, tostring(entry.owner), tostring(err)))
            end
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
    -- SetVehicleProperties applies everything it is given. A move only happens for a
    -- NEW revision of the record, so this runs once per change, not per pass.
    if record.kind == 'vehicle' and record.props then
        SetVehicleProperties(entity, record.props)
    end
end

-- A model wait is not work: kept out of the clientSyncPass timing.
local function waitModel(modelHash)
    if CisTiming and CisTiming.exclude then
        return CisTiming.exclude(RequestModelTimeout, modelHash, MODEL_TIMEOUT)
    end
    return RequestModelTimeout(modelHash, MODEL_TIMEOUT)
end

-- Create the entity, and ANSWER WHETHER IT HAPPENED. Always client-LOCAL: a
-- networked record is never spawned here (see the header).
local function spawn(record)
    local modelHash = hashOf(record.model)
    local coords = record.coords
    local heading = record.heading or 0.0
    local entity

    if record.kind == 'ped' then
        -- The ped wrapper in client/utils.lua requests and releases the model itself,
        local opts = {
            networked = false,
            freeze = record.freeze,
            invincible = record.invincible,
            blockEvents = record.blockEvents,
            scenario = record.scenario,
        }
        -- CisCreatePed is the library's ped helper (client/utils.lua): it loads the
        -- model, creates, applies the options and answers 0 on failure. The
        -- CreatePed native itself is never replaced.
        if CisTiming and CisTiming.exclude then
            entity = CisTiming.exclude(CisCreatePed, modelHash, coords, heading, opts)
        else
            entity = CisCreatePed(modelHash, coords, heading, opts)
        end
    elseif record.kind == 'vehicle' then
        local ready = waitModel(modelHash)
        if not ready then
            CisLog('error', 'sync model unavailable: ' .. tostring(record.model))
            return false
        end
        entity = CreateVehicle(modelHash, coords.x, coords.y, coords.z, heading, false, false)
        -- RELEASED BEFORE ANY RETURN. It used to sit inside the `entity ~= 0` branch,
        SetModelAsNoLongerNeeded(modelHash)
        if entity ~= 0 and record.props then
            SetVehicleProperties(entity, record.props)
        end
    else
        -- WAIT FOR THE MODEL, the way the ped path does.
        local ready = waitModel(modelHash)
        if not ready then
            SetModelAsNoLongerNeeded(modelHash)
            CisLog('error', 'sync model unavailable: ' .. tostring(record.model))
            return false
        end
        entity = CreateObject(modelHash, coords.x, coords.y, coords.z, false, true, false)
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
        networked = false,
        rev = record.rev,
    }
    return true
end

-- Serialise spawns per id. The ped helper yields while it waits for the model, so two rapid
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
        previous.rev = record.rev
        wanted[id] = nil
        retries[id] = nil
        return
    end

    spawning[id] = true
    -- The generation this spawn is serving.
    local mine = generation[id]
    despawn(id)
    -- UNDER PCALL. A spawn that raised used to leave spawning[id] set for the rest
    -- of the session, and every later state for that id returned at the top.
    local okCall, result = pcall(spawn, record)
    spawning[id] = nil
    if not okCall then
        CisLog('error', ('sync: spawning %s raised: %s'):format(tostring(id), tostring(result)))
    end
    local ok = okCall and result == true

    if generation[id] ~= mine then
        -- The record was removed while the model was loading. Whatever was made
        -- goes; and if the server has wanted it AGAIN since, that newest state is
        -- driven now rather than dropped.
        despawn(id)
        if wanted[id] then
            drive(id)
        end
        return
    end

    if not ok then
        -- The model is not here yet. Retried rather than abandoned: a prop synced a
        scheduleRetry(id)
        return
    end
    retries[id] = nil

    -- FIRED HERE, NOT IN `spawn`, and that placement is the point.
    fireSpawn(id, record)

    -- Something newer arrived while we were waiting.
    local newest = wanted[id]
    if newest and newest ~= record then
        drive(id)
    elseif newest == record then
        wanted[id] = nil
    end
end

function scheduleRetry(id)
    local attempt = (retries[id] or 0) + 1
    retries[id] = attempt
    if attempt > RETRY_MAX then
        -- GIVE UP FOR REAL, AND SAY SO. The counter used to be reset inside the
        -- retry thread, so it never reached the limit and a missing model retried
        -- every 500 ms forever. Now the record is dropped here and the server is
        -- told, so it stops believing this client holds it and can offer it again
        -- later instead of never.
        retries[id] = nil
        wanted[id] = nil
        CisLog('error', 'sync gave up retrying an unavailable model after '
            .. tostring(RETRY_MAX) .. ' attempts')
        TriggerServerEvent('cis_libs:server:syncGaveUp', id)
        return
    end
    local delay = RETRY_BASE_MS * attempt
    CreateThread(function()
        Wait(delay)
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

-- Does this state need a model load before it can be shown? Only then does it
-- get a thread of its own; everything else is applied inline with its batch.
local function needsLoad(record)
    local previous = records[record.id]
    local modelHash = hashOf(record.model)
    if previous and previous.model == modelHash and previous.kind == record.kind and alive(record.id) then
        return false
    end
    return not HasModelLoaded(modelHash)
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
    -- NEVER A NETWORKED ENTITY FROM HERE. The server made it; OneSync streams it.
    if record.networked == true then
        CisLog('error', ('sync: ignoring %s: a networked record is never spawned by a client')
            :format(tostring(record.id)))
        return
    end
    -- NOT a return when a spawn is in flight: the newest state is recorded and the
    wanted[record.id] = record
    -- A fresh state starts a fresh retry budget.
    retries[record.id] = nil
    if spawning[record.id] then
        return
    end
    if needsLoad(record) then
        -- A model load yields for up to MODEL_TIMEOUT. One thread per such record,
        -- so a batch of fifty props does not load fifty models one after another.
        local id = record.id
        CreateThread(function()
            drive(id)
        end)
        return
    end
    drive(record.id)
end

local function removeKey(id)
    -- The newest wanted state goes FIRST.
    wanted[id] = nil
    retries[id] = nil
    -- Bumped whether or not a spawn is running, so a remove that arrives DURING a model
    bump(id)
    despawn(id)
end

-- ORDERING. A large batch travels on the LATENT channel and a small one on the
-- reliable channel, so a later batch can arrive first. Each batch is numbered per
-- player, and an entry is applied only if no later batch has touched that key: a
-- remove that overtook an older upsert is not undone by it arriving late.
local touched = {}
local touchedCount = 0
local newestBatch = 0
-- How many batches back a removed key's number is remembered.
local TOUCH_WINDOW = 1024

local function touch(key, n)
    local last = touched[key]
    if last and last > n then
        return false
    end
    if not last then
        touchedCount = touchedCount + 1
    end
    touched[key] = n
    return true
end

local function pruneTouched()
    if touchedCount <= 2 * TOUCH_WINDOW then
        return
    end
    local floor = newestBatch - TOUCH_WINDOW
    for key, n in pairs(touched) do
        if n < floor and not entities[key] and not wanted[key] then
            touched[key] = nil
            touchedCount = touchedCount - 1
        end
    end
end

local function applyBatch(n, ups, rems)
    if type(rems) == 'table' then
        for i = 1, #rems do
            local key = rems[i]
            if type(key) == 'string' and touch(key, n) then
                local ok, err = pcall(removeKey, key)
                if not ok then
                    CisLog('error', ('sync: removing %s raised: %s'):format(key, tostring(err)))
                end
            end
        end
    end
    if type(ups) == 'table' then
        for i = 1, #ups do
            local record = ups[i]
            -- THE IDENTITY IS `key`, NOT `id`.
            if type(record) == 'table' and type(record.key) == 'string' and touch(record.key, n) then
                record.id = record.key
                -- ONE BAD RECORD COSTS ONLY ITSELF.
                local ok, err = pcall(apply, record)
                if not ok then
                    CisLog('error', ('sync: applying %s raised: %s')
                        :format(tostring(record.key), tostring(err)))
                end
            end
        end
    end
    pruneTouched()
end

-- The server numbers batches 1, 2, 3... per player, so a real `n` is a small
-- positive integer. A huge one would pin `touched` for that key above every
-- later batch and refuse its upserts for the rest of the session.
local MAX_BATCH = 0x7fffffff

RegisterNetEvent('cis_libs:client:syncBatch', function(n, ups, rems)
    -- FROM THE SERVER, OR NOT AT ALL: a local TriggerEvent arrives with
    -- source == '' and would spawn and delete synced entities at will.
    if source == nil or source == '' then
        return
    end
    if type(n) ~= 'number' or n < 1 or n > MAX_BATCH or n ~= math.floor(n) then
        return
    end
    if n > newestBatch then
        newestBatch = n
    end
    if CisTiming then
        CisTiming.measure('clientSyncPass', function()
            applyBatch(n, ups, rems)
        end)
    else
        applyBatch(n, ups, rems)
    end
end)

-- ------------------------------------------------------------ networked records
-- key -> { entity, value, appliedRev }
local netTracked = {}
local netWatching = false
local NET_CHECK_MS = 1000

local function ownsEntity(entity)
    return NetworkGetEntityOwner(entity) == PlayerId()
end

-- What only the OWNER can make stick: invincibility, a ped's event blocking and
-- scenario, a vehicle's properties. Applied once per revision per owner; a new
-- owner after a migration applies it again.
local function applyOwned(t)
    local value, entity = t.value, t.entity
    if not value or t.appliedRev == value.rev or not ownsEntity(entity) then
        return
    end
    t.appliedRev = value.rev
    if value.invincible ~= nil then
        SetEntityInvincible(entity, value.invincible == true)
    end
    if value.kind == 'ped' then
        if value.blockEvents then
            SetBlockingOfNonTemporaryEvents(entity, true)
        end
        if type(value.scenario) == 'string' then
            TaskStartScenarioInPlace(entity, value.scenario, 0, true)
        end
    elseif value.kind == 'vehicle' and type(value.props) == 'table' then
        SetVehicleProperties(entity, value.props)
    end
end

local function untrackNet(key)
    local t = netTracked[key]
    if not t then
        return
    end
    netTracked[key] = nil
    -- Untracked, never deleted: the entity is the server's.
    despawn(key)
end

local function watchNet()
    while next(netTracked) do
        Wait(NET_CHECK_MS)
        local gone = nil
        for key, t in pairs(netTracked) do
            if not DoesEntityExist(t.entity) then
                -- Streamed out, or deleted: either way this client no longer has it.
                gone = gone or {}
                gone[#gone + 1] = key
            else
                local ok, err = pcall(applyOwned, t)
                if not ok then
                    CisLog('error', ('sync: applying %s raised: %s'):format(key, tostring(err)))
                end
            end
        end
        if gone then
            for i = 1, #gone do
                untrackNet(gone[i])
            end
        end
    end
    netWatching = false
end

local function onNetBag(entity, value, _replicated, deleted)
    if deleted or type(value) ~= 'table' or type(value.key) ~= 'string' then
        for key, t in pairs(netTracked) do
            if t.entity == entity then
                untrackNet(key)
                break
            end
        end
        return
    end
    local key = value.key
    local t = netTracked[key]
    if t and t.entity ~= entity then
        -- Re-created by the server (entityRemoved): a new entity for the same record.
        untrackNet(key)
        t = nil
    end
    if t then
        t.value = value
        applyOwned(t)
        return
    end
    -- A client-local copy under the same key cannot exist alongside this.
    if entities[key] and not (records[key] and records[key].networked) then
        removeKey(key)
    end
    t = { entity = entity, value = value }
    netTracked[key] = t
    entities[key] = entity
    records[key] = { kind = value.kind, networked = true, rev = value.rev }
    applyOwned(t)
    fireSpawn(key, value)
    if not netWatching then
        netWatching = true
        CreateThread(watchNet)
    end
end

if CisStatebagOnEntity then
    CisStatebagOnEntity('cis_sync', onNetBag)
end

-- A CLIENT THAT HAS JUST RELOADED HOLDS NOTHING, AND SAYS SO.
TriggerServerEvent('cis_libs:server:syncSnapshot')

local function dropHandlersOf(list, resource)
    for i = #list, 1, -1 do
        if list[i].owner == resource then
            table.remove(list, i)
        end
    end
end

AddEventHandler('onResourceStop', function(resource)
    -- A forged stop from another client script is ignored (shared/owned.lua).
    if not CisRealStop(resource) then
        return
    end
    if resource ~= GetCurrentResourceName() then
        -- A hook is a function reference into the resource that registered it.
        dropHandlersOf(spawnHandlers, resource)
        dropHandlersOf(despawnHandlers, resource)
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

-- Register a consumer hook. A function from another resource arrives as a callable
-- function reference, which is accepted; anything that cannot be called is refused
-- rather than stored.
exports('AddSyncSpawnHandler', function(fn)
    if not CisCallable(fn) then
        return false, 'Cis.sync.onSpawn needs a function'
    end
    spawnHandlers[#spawnHandlers + 1] = { fn = fn, owner = GetInvokingResource() or 'cis_libs' }
    return true
end)

exports('AddSyncDespawnHandler', function(fn)
    if not CisCallable(fn) then
        return false, 'Cis.sync.onDespawn needs a function'
    end
    despawnHandlers[#despawnHandlers + 1] = { fn = fn, owner = GetInvokingResource() or 'cis_libs' }
    return true
end)

-- Spawned entities are counted separately from the records that asked for them, because
CisDiagnostics.Register('client', 'syncEntities', function()
    local out = {
        entities = 0, records = 0, spawning = 0, networked = 0, recordsByOwner = {},
        hooks = #spawnHandlers + #despawnHandlers,
    }
    for _ in pairs(entities) do out.entities = out.entities + 1 end
    for _, record in pairs(records) do
        out.records = out.records + 1
        local owner = record.owner or '<none>'
        out.recordsByOwner[owner] = (out.recordsByOwner[owner] or 0) + 1
    end
    for _ in pairs(spawning) do out.spawning = out.spawning + 1 end
    for _ in pairs(netTracked) do out.networked = out.networked + 1 end
    return out
end)
