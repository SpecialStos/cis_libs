local DoorLock = {
    doorStates = {},
    doorGroups = {},
    doorData = {},
}

local prefix = 'cis_libs'
local lastChange = {}

local function eventPrefix()
    return (Security and Security.EventPrefix) or prefix
end

local function persistEnabled()
    if not (Config and Config.Doorlock and Config.Doorlock.Persist) then
        return false
    end
    local driver = Config.Framework and Config.Framework.Database and Config.Framework.Database.Type
    return driver == 'oxmysql' or driver == 'mysql-async' or driver == 'ghmattimysql'
end

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

function DoorLock.GetDoorsToUpdate(identifier)
    if DoorLock.doorGroups[identifier] then
        return DoorLock.doorGroups[identifier]
    elseif DoorLock.doorStates[identifier] ~= nil then
        return { identifier }
    end
    return {}
end

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

local function persistDoor(door)
    if not persistEnabled() then
        return
    end
    exports['cis_libs']:DatabaseExecute(
        'INSERT INTO cis_doors (id, data) VALUES (?, ?) ON DUPLICATE KEY UPDATE data = VALUES(data)',
        { door.id, json.encode(door) }
    )
end

function DoorLock.SetDoorState(identifier, state)
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
        end
    end
end

function DoorLock.AddDoor(newDoorData, internal)
    if not internal and not CisInvokingAllowed() then
        return false
    end
    if not newDoorData or not newDoorData.id or DoorLock.doorStates[newDoorData.id] ~= nil then
        return false
    end
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

function DoorLock.GetDoorState(doorId)
    return DoorLock.doorStates[doorId]
end

function DoorLock.LockDoors(identifier)
    DoorLock.SetDoorState(identifier, true)
end

function DoorLock.UnlockDoors(identifier)
    DoorLock.SetDoorState(identifier, false)
end

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

CisNetOn(eventPrefix() .. ':doorlock:requestState', function(src, identifier, state)
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

AddEventHandler('playerDropped', function()
    lastChange[source] = nil
end)

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
