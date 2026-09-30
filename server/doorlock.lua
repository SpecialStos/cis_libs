-- Door and door-group state. Server-authoritative: a client's request is
-- treated as a claim, and both permission and physical distance are re-checked
-- here before anything changes.
--
-- Three parallel maps, keyed differently on purpose: doorStates is a flat
-- id -> boolean that every lookup can use, doorData holds the full record for
-- the ones that have one, and doorGroups is the only index from a group name to
-- a list of ids. Flat lookup on the hot path (a toggle) matters; the group
-- index is built once at AddDoor time rather than scanned per query.

local DoorLock = {
    doorStates = {},
    doorGroups = {},
    doorData = {},
}

local prefix = 'cis_libs'
local lastChange = {}

-- Event names, not internal state. An operator renames Security.EventPrefix to
-- run cis_libs alongside another copy of itself, and the client derives the
-- same name from the same config; a hardcoded literal here would half-apply
-- the rename and leave a client listening on a name nobody triggers.
local function eventPrefix()
    return (Security and Security.EventPrefix) or prefix
end

-- Persistence needs BOTH the setting and a SQL driver. mongodb is configured
-- and reachable but has no CREATE TABLE and no upsert, so honouring Persist
-- against it would write every door to a table that never exists. The check is
-- repeated here rather than trusted to Config, because Config.Framework can be
-- re-pointed at runtime by a consumer.
local function persistEnabled()
    if not (Config and Config.Doorlock and Config.Doorlock.Persist) then
        return false
    end
    local driver = Config.Framework and Config.Framework.Database and Config.Framework.Database.Type
    return driver == 'oxmysql' or driver == 'mysql-async' or driver == 'ghmattimysql'
end

-- Accepts either a vector3 ({x=,y=,z=}) or a positional array ({1,2,3}), and
-- always returns the vector3 form. Callers write door coordinates both ways and
-- the stored form is read by a fingerprint-like comparison on the client, so
-- storing whatever arrived would make the same door look different to two
-- callers.
local function vec(value)
    if not value then
        return nil
    end
    return {
        x = value.x or value[1],
        y = value.y or value[2],
        z = value.z or value[3] or 0.0,
    }
end

-- The server's half of the distance check. The client has the same test, but a
-- client is the party being asked to prove its own claim: without this, a
-- player anywhere on the map can send the requestState event naming a door they
-- cannot see and have it toggle.
--
-- "Within range of ANY door in the group" is deliberate and is how a group is
-- meant to work: a job toggling a bank gets to toggle any door of that bank
-- once they are at any one of them. The per-door maxDistance overrides the
-- config default for the wide ones.
local function distanceOk(src, identifier)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then
        return false
    end
    local coords = GetEntityCoords(ped)
    local doorsToCheck = DoorLock.GetDoorsToUpdate(identifier)
    local maxDist = (Config and Config.Doorlock and Config.Doorlock.InteractableDistance) or 2.0
    for i = 1, #doorsToCheck do
        local door = DoorLock.doorData[doorsToCheck[i]]
        if door then
            local c = door.interactCoords or door.coords
            if c then
                local dx = coords.x - (c.x or c[1])
                local dy = coords.y - (c.y or c[2])
                local dz = coords.z - (c.z or c[3] or coords.z)
                local limit = door.maxDistance or maxDist
                if (dx * dx + dy * dy + dz * dz) <= (limit * limit) then
                    return true
                end
            end
        end
    end
    return false
end

-- One identifier, three possible meanings, resolved in one place so no caller
-- has to know which kind of identifier it was handed:
--
--   a group name  -> every door in that group
--   a door id     -> that one door
--   unknown       -> nothing
--
-- The group lookup wins over the door lookup because a group and a door can
-- share a name; a name registered as a group is meant to expand, and an
-- identifier that is neither is a no-op rather than an error.
function DoorLock.GetDoorsToUpdate(identifier)
    if DoorLock.doorGroups[identifier] then
        return DoorLock.doorGroups[identifier]
    elseif DoorLock.doorStates[identifier] ~= nil then
        return { identifier }
    end
    return {}
end

-- Admin first, and unconditionally. An admin overriding a door's job list is a
-- deliberate server-owner capability, and it is also the escape hatch for a
-- door whose `groups` was never configured correctly -- without it a
-- misconfigured door is permanently unopenable by the people meant to use it.
--
-- The job check walks the EXPANDED door set, so a group name is matched
-- against every door it expands to, and a door id against that one door.
function DoorLock.PlayerHasPermission(playerId, identifier)
    local Framework = CisFramework or exports['cis_libs']:GetFramework()
    if Framework.HasPermission and Framework.HasPermission(playerId, 'admin') then
        return true
    end
    local playerJob = Framework.GetPlayerJob(playerId)
    if not playerJob or not playerJob.name then
        return false
    end
    local doorsToCheck = DoorLock.GetDoorsToUpdate(identifier)
    for i = 1, #doorsToCheck do
        local door = DoorLock.doorData[doorsToCheck[i]]
        if door and door.groups then
            for j = 1, #door.groups do
                if playerJob.name == door.groups[j] then
                    return true
                end
            end
        end
    end
    return false
end

-- The whole door record is stored as one JSON blob rather than as columns.
-- The shape of a door is a caller-defined payload that cis_libs does not read
-- (it only needs id, coords, groups, locked), so a schema would either be
-- lossy or have to be migrated by this library every time a companion resource
-- wants one more field. The upsert is keyed on id, so a door's row is replaced
-- wholesale and there is no partial-update state to get wrong.
--
-- Fire and forget: no callback, and no error branch. A door that fails to
-- persist is still live in memory for this boot, and blocking a toggle on a
-- database round trip would put the driver's latency in front of a player
-- pressing a key.
local function persistDoor(door)
    if not persistEnabled() then
        return
    end
    exports['cis_libs']:DatabaseExecute(
        'INSERT INTO cis_doors (id, data) VALUES (?, ?) ON DUPLICATE KEY UPDATE data = VALUES(data)',
        { door.id, json.encode(door) }
    )
end

-- Returns how many doors it actually changed. This used to return nothing, so
-- `Cis.doors.setState` on the server could not tell "locked it" from "no such
-- door" -- both arrived as nil, which is the exact ambiguity the library's own
-- refusal convention exists to prevent. The return is additive: a caller that
-- ignored the old nil is unaffected, and a caller that checks it now learns
-- something it previously could not.
--
-- A count rather than a boolean, because an identifier can expand to many
-- doors: 0 means the identifier named nothing, and a positive number says how
-- many of the doors a caller believed it was touching actually existed. A
-- boolean cannot express "2 of the 5 in that group are real".
--
-- `state` is coerced to a strict boolean, so doorStates never holds nil or a
-- truthy non-boolean. The `~= nil` guard is what keeps a group containing a
-- door id that was never added from being counted: absent is not false.
function DoorLock.SetDoorState(identifier, state)
    local changed = 0
    local doorsToUpdate = DoorLock.GetDoorsToUpdate(identifier)
    for i = 1, #doorsToUpdate do
        local doorId = doorsToUpdate[i]
        if DoorLock.doorStates[doorId] ~= nil then
            DoorLock.doorStates[doorId] = state and true or false
            if DoorLock.doorData[doorId] then
                DoorLock.doorData[doorId].locked = DoorLock.doorStates[doorId]
                persistDoor(DoorLock.doorData[doorId])
            end
            TriggerClientEvent(eventPrefix() .. ':doorlock:updateState', -1, doorId, DoorLock.doorStates[doorId])
            changed = changed + 1
        end
    end
    return changed
end

-- `internal` skips the allow-list check, and it is only ever true on the path
-- that restores doors this library itself wrote to the database at boot. Those
-- rows are cis_libs' own state, not a foreign resource mutating someone else's
-- doors, so re-authorising them would mean a restrictive install could not
-- bring its own persisted doors back. A caller that can reach the database can
-- already write a row directly; the allow-list is about the export surface,
-- not about the storage behind it.
function DoorLock.AddDoor(newDoorData, internal)
    if not internal and not CisInvokingAllowed() then
        return false
    end
    -- Rejected when the id is missing (a door nothing can be addressed by) or
    -- already present. Re-adding is refused rather than treated as an update,
    -- so AddDoor never silently discards a live door's locked state; an update
    -- goes through SetDoorState.
    if not newDoorData or not newDoorData.id or DoorLock.doorStates[newDoorData.id] ~= nil then
        return false
    end
    -- interactCoords is the point a player must reach to use the door, which
    -- for a door on a model is not always the model's origin. It falls back to
    -- coords so a caller that supplies only coords still gets a usable door.
    newDoorData.coords = vec(newDoorData.coords) or newDoorData.coords
    newDoorData.interactCoords = vec(newDoorData.interactCoords) or newDoorData.coords
    newDoorData.locked = newDoorData.locked and true or false
    DoorLock.doorStates[newDoorData.id] = newDoorData.locked
    DoorLock.doorData[newDoorData.id] = newDoorData
    if newDoorData.groupId then
        DoorLock.doorGroups[newDoorData.groupId] = DoorLock.doorGroups[newDoorData.groupId] or {}
        DoorLock.doorGroups[newDoorData.groupId][#DoorLock.doorGroups[newDoorData.groupId] + 1] = newDoorData.id
    end
    TriggerClientEvent(eventPrefix() .. ':doorlock:addDoor', -1, newDoorData)
    persistDoor(newDoorData)
    return true
end

-- The group is stored whole and never merged: re-registering a name is
-- refused rather than appended to, so two resources claiming the same group id
-- produce a visible false instead of a door set that silently grew. The default
-- to an empty list keeps GetDoorsToUpdate's group branch truthy for a group
-- that legitimately has no doors yet.
function DoorLock.AddDoorGroup(groupData)
    if not CisInvokingAllowed() then
        return false
    end
    if not groupData or not groupData.id or DoorLock.doorGroups[groupData.id] then
        return false
    end
    DoorLock.doorGroups[groupData.id] = groupData.doors or {}
    TriggerClientEvent(eventPrefix() .. ':doorlock:addDoorGroup', -1, groupData)
    return true
end

-- nil for a door that does not exist, which is deliberately distinct from
-- false. "This door is unlocked" and "there is no such door" are different
-- answers, and a caller that cannot tell them apart will report an unopenable
-- door that simply was never registered.
function DoorLock.GetDoorState(doorId)
    return DoorLock.doorStates[doorId]
end

-- Lock/Unlock are the same call with the boolean flipped, so they inherit the
-- count return and there is no second implementation to drift.
function DoorLock.LockDoors(identifier)
    return DoorLock.SetDoorState(identifier, true)
end

function DoorLock.UnlockDoors(identifier)
    return DoorLock.SetDoorState(identifier, false)
end

-- Break is not SetDoorState: it unlocks the door AND marks it broken, and it
-- sends two events, because the client renders a broken door differently and
-- needs to know the reason for the state change to show that.
--
-- Note these two return nothing, unlike SetDoorState above. Callers that want
-- to know whether anything happened have to count the expansion themselves.
-- Both are declared stable in api.lua, so the nil return is part of their
-- contract and is left alone rather than made to match SetDoorState.
function DoorLock.BreakDoor(identifier)
    local doorsToBreak = DoorLock.GetDoorsToUpdate(identifier)
    for i = 1, #doorsToBreak do
        local doorId = doorsToBreak[i]
        if DoorLock.doorStates[doorId] ~= nil then
            DoorLock.doorStates[doorId] = false
            if DoorLock.doorData[doorId] then
                DoorLock.doorData[doorId].locked = false
                DoorLock.doorData[doorId].broken = true
                persistDoor(DoorLock.doorData[doorId])
            end
            TriggerClientEvent(eventPrefix() .. ':doorlock:updateState', -1, doorId, false)
            TriggerClientEvent(eventPrefix() .. ':doorlock:doorBroken', -1, doorId, true)
        end
    end
end

function DoorLock.FixDoor(identifier)
    local doorsToFix = DoorLock.GetDoorsToUpdate(identifier)
    for i = 1, #doorsToFix do
        local doorId = doorsToFix[i]
        if DoorLock.doorStates[doorId] ~= nil then
            if DoorLock.doorData[doorId] then
                DoorLock.doorData[doorId].broken = false
                persistDoor(DoorLock.doorData[doorId])
            end
            TriggerClientEvent(eventPrefix() .. ':doorlock:doorBroken', -1, doorId, false)
        end
    end
end

function DoorLock.GetAllDoorData()
    return {
        doors = DoorLock.doorData,
        groups = DoorLock.doorGroups,
    }
end

-- The client-facing toggle. Order is the security property: cooldown, then
-- permission, then distance. Checking distance before permission would leak
-- "a door with that name exists near you" to anyone, and the notification in
-- the permission branch has to be sent before the silent distance return or
-- the player sees nothing happen and no reason why.
CisNetOn(eventPrefix() .. ':doorlock:requestState', function(src, identifier, state)
    -- 250ms per player, tighter than the generic rate limiter on purpose: this
    -- is the one event a UI produces by accident, and a held key or a
    -- double-bound toggle arrives as a burst of two within a frame. Suppressed
    -- silently -- a rate-limited toggle is not a security event, and logging
    -- it as one would fill the cheating channel with a player mashing a key.
    if lastChange[src] and GetGameTimer() - lastChange[src] < 250 then
        return
    end
    lastChange[src] = GetGameTimer()
    if not DoorLock.PlayerHasPermission(src, identifier) then
        TriggerClientEvent('cis_libs:client:showNotification', src, "You don't have permission to interact with this door.")
        return
    end
    if not distanceOk(src, identifier) then
        return
    end
    DoorLock.SetDoorState(identifier, state and true or false)
end)

-- Required, not tidy: server ids are reused, and a returning player inheriting
-- a previous occupant's 250ms cooldown would find their first door press
-- ignored.
AddEventHandler('playerDropped', function()
    lastChange[source] = nil
end)

-- Boot-time restore. The CREATE TABLE is inside the same call as the SELECT
-- because the SELECT depends on it, and this is the only statement in the file
-- that can create it -- which is why server/security.lua must not query
-- cis_doors unless persistence is configured.
--
-- No poll and no retry: the thread runs once, and the driver's own callback is
-- the only synchronisation. A driver that has not started yet resolves
-- Database.ready to false, DatabaseExecute reports nothing back, and this
-- thread is simply gone -- a server whose driver started after cis_libs loses
-- its persisted doors for that boot. That is accepted rather than papered over
-- with a retry loop, because the alternative is a thread that re-runs a
-- destructive CREATE TABLE for the life of the resource.
CreateThread(function()
    if not persistEnabled() then
        return
    end
    exports['cis_libs']:DatabaseExecute([[
        CREATE TABLE IF NOT EXISTS cis_doors (
            id VARCHAR(64) NOT NULL PRIMARY KEY,
            data LONGTEXT NOT NULL
        )
    ]], {}, function()
        exports['cis_libs']:DatabaseFetchAll('SELECT id, data FROM cis_doors', {}, function(rows)
            if type(rows) ~= 'table' then
                return
            end
            for i = 1, #rows do
                -- One bad row must not stop the rest from loading. `data` is
                -- JSON this library wrote, but a hand-edited row, a truncated
                -- write, or a row from a different schema would otherwise
                -- raise in the middle of the loop and leave the server with
                -- half its doors. Skip it and keep going.
                local ok, data = pcall(json.decode, rows[i].data)
                if ok and data then
                    DoorLock.AddDoor(data, true)
                end
            end
        end)
    end)
end)

exports('GetDoorState', DoorLock.GetDoorState)
exports('LockDoors', DoorLock.LockDoors)
exports('UnlockDoors', DoorLock.UnlockDoors)
exports('BreakDoor', DoorLock.BreakDoor)
exports('FixDoor', DoorLock.FixDoor)
exports('GetAllDoorData', DoorLock.GetAllDoorData)
exports('AddDoorToSystem', DoorLock.AddDoor)
exports('AddDoorGroup', DoorLock.AddDoorGroup)
