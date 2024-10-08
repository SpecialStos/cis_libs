-- cis_libs/server/doorlock.lua

local DoorLock = {}
DoorLock.doorStates = {}
DoorLock.doorGroups = {}
DoorLock.doorData = {}

-- Initialize door states
Citizen.CreateThread(function()
    if Config.Printing and Config.Printing.Debug then
        exports['cis_libs']:LogDebug("Initializing server-side door states")
    end
end)

-- Handle door state change requests from clients
RegisterNetEvent(Security.EventPrefix .. ':doorlock:requestState')
AddEventHandler(Security.EventPrefix .. ':doorlock:requestState', function(identifier, state)
    local src = source
    if Config.Printing and Config.Printing.Debug then
        exports['cis_libs']:LogDebug("Door state change requested by player " .. src .. " for " .. identifier .. " to " .. tostring(state))
    end
    
    if DoorLock.PlayerHasPermission(src, identifier) then
        DoorLock.SetDoorState(identifier, state)
    else
        if Config.Printing and Config.Printing.Debug then
            exports['cis_libs']:LogDebug("Player " .. src .. " does not have permission to change door " .. identifier)
        end
        TriggerClientEvent('cis_libs:client:showNotification', src, "You don't have permission to interact with this door.")
    end
end)

-- Check if a player has permission to interact with a door
function DoorLock.PlayerHasPermission(playerId, identifier)
    local Framework = exports['cis_libs']:GetFramework()
    local playerJob = Framework.GetPlayerJob(playerId)
    
    local doorsToCheck = DoorLock.GetDoorsToUpdate(identifier)
    
    for _, doorId in ipairs(doorsToCheck) do
        if DoorLock.doorData[doorId] and DoorLock.doorData[doorId].groups then
            for _, allowedJob in ipairs(DoorLock.doorData[doorId].groups) do
                if playerJob.name == allowedJob then
                    return true
                end
            end
        end
    end
    
    return false
end

-- Update door state
function DoorLock.SetDoorState(identifier, state)
    local doorsToUpdate = DoorLock.GetDoorsToUpdate(identifier)

    for _, doorId in ipairs(doorsToUpdate) do
        if DoorLock.doorStates[doorId] ~= nil then
            DoorLock.doorStates[doorId] = state
            if DoorLock.doorData[doorId] then
                DoorLock.doorData[doorId].locked = state
            end
            TriggerClientEvent(Security.EventPrefix .. ':doorlock:updateState', -1, doorId, state)
            if Config.Printing and Config.Printing.Debug then
                exports['cis_libs']:LogDebug("Door state updated: " .. doorId .. " - Locked: " .. tostring(state))
            end
        else
            if Config.Printing and Config.Printing.Debug then
                exports['cis_libs']:LogError("Door not found in system: " .. doorId)
            end
        end
    end
end

-- Helper function to get doors to update
function DoorLock.GetDoorsToUpdate(identifier)
    if DoorLock.doorGroups[identifier] then
        return DoorLock.doorGroups[identifier]
    elseif DoorLock.doorStates[identifier] ~= nil then
        return {identifier}
    else
        for groupId, doors in pairs(DoorLock.doorGroups) do
            for _, doorId in ipairs(doors) do
                if doorId == identifier then
                    return DoorLock.doorGroups[groupId]
                end
            end
        end
        if Config.Printing and Config.Printing.Debug then
            exports['cis_libs']:LogError("Invalid identifier: " .. tostring(identifier))
        end
        return {}
    end
end

-- Add a door to the system
RegisterNetEvent(Security.EventPrefix .. ':doorlock:addDoor')
AddEventHandler(Security.EventPrefix .. ':doorlock:addDoor', function(newDoorData)
    if Config.Printing and Config.Printing.Debug then
        exports['cis_libs']:LogDebug("Adding door to system: " .. newDoorData.id)
    end
    if not DoorLock.doorStates[newDoorData.id] then
        DoorLock.doorStates[newDoorData.id] = newDoorData.locked
        DoorLock.doorData[newDoorData.id] = newDoorData
        if newDoorData.groupId then
            if not DoorLock.doorGroups[newDoorData.groupId] then
                DoorLock.doorGroups[newDoorData.groupId] = {}
            end
            table.insert(DoorLock.doorGroups[newDoorData.groupId], newDoorData.id)
        end
        TriggerClientEvent(Security.EventPrefix .. ':doorlock:addDoor', -1, newDoorData)
        if Config.Printing and Config.Printing.Debug then
            exports['cis_libs']:LogDebug("Door added to system: " .. newDoorData.id)
        end
    else
        if Config.Printing and Config.Printing.Debug then
            exports['cis_libs']:LogWarn("Door already exists in system: " .. newDoorData.id)
        end
    end
end)

-- Add a door group
RegisterNetEvent(Security.EventPrefix .. ':doorlock:addDoorGroup')
AddEventHandler(Security.EventPrefix .. ':doorlock:addDoorGroup', function(groupData)
    -- Log the start of the function for debugging
    if Config.Printing and Config.Printing.Debug then
        exports['cis_libs']:LogDebug("Attempting to add door group: " .. groupData.id)
    end

    -- Check if doorGroups is initialized
    if not doorGroups then
        doorGroups = {}
        if Config.Printing and Config.Printing.Debug then
            exports['cis_libs']:LogDebug("Initialized doorGroups table")
        end
    end

    -- Check if the door group already exists
    if doorGroups[groupData.id] then
        if Config.Printing and Config.Printing.Debug then
            exports['cis_libs']:LogDebug("Door group already exists: " .. groupData.id)
        end
        return
    end

    -- Add the door group
    doorGroups[groupData.id] = groupData.doors
    if Config.Printing and Config.Printing.Debug then
        exports['cis_libs']:LogDebug("Added door group: " .. groupData.id .. " with " .. #groupData.doors .. " doors")
    end
end)

-- Get door state
function DoorLock.GetDoorState(doorId)
    if DoorLock.doorStates[doorId] ~= nil then
        return DoorLock.doorStates[doorId]
    else
        if Config.Printing and Config.Printing.Debug then
            exports['cis_libs']:LogError("Door not found in system: " .. doorId)
        end
        return nil
    end
end

-- Lock doors
function DoorLock.LockDoors(identifier)
    if Config.Printing and Config.Printing.Debug then
        exports['cis_libs']:LogDebug("Attempting to lock door(s): " .. identifier)
    end
    DoorLock.SetDoorState(identifier, true)
end

-- Unlock doors
function DoorLock.UnlockDoors(identifier)
    if Config.Printing and Config.Printing.Debug then
        exports['cis_libs']:LogDebug("Attempting to unlock door(s): " .. identifier)
    end
    DoorLock.SetDoorState(identifier, false)
end

-- Break door
function DoorLock.BreakDoor(identifier)
    local doorsToBreak = DoorLock.GetDoorsToUpdate(identifier)
    
    for _, doorId in ipairs(doorsToBreak) do
        if DoorLock.doorStates[doorId] ~= nil then
            DoorLock.doorStates[doorId] = false -- Broken doors are always unlocked
            if DoorLock.doorData[doorId] then
                DoorLock.doorData[doorId].locked = false
                DoorLock.doorData[doorId].broken = true
            end
            TriggerClientEvent(Security.EventPrefix .. ':doorlock:updateState', -1, doorId, false)
            TriggerClientEvent(Security.EventPrefix .. ':doorlock:doorBroken', -1, doorId, true)
            if Config.Printing and Config.Printing.Debug then
                exports['cis_libs']:LogDebug("Door broken: " .. doorId)
            end
        else
            if Config.Printing and Config.Printing.Debug then
                exports['cis_libs']:LogError("Door not found in system: " .. doorId)
            end
        end
    end
end

-- Fix door
function DoorLock.FixDoor(identifier)
    local doorsToFix = DoorLock.GetDoorsToUpdate(identifier)
    
    for _, doorId in ipairs(doorsToFix) do
        if DoorLock.doorStates[doorId] ~= nil then
            if DoorLock.doorData[doorId] then
                DoorLock.doorData[doorId].broken = false
            end
            TriggerClientEvent(Security.EventPrefix .. ':doorlock:doorBroken', -1, doorId, false)
            if Config.Printing and Config.Printing.Debug then
                exports['cis_libs']:LogDebug("Door fixed: " .. doorId)
            end
        else
            if Config.Printing and Config.Printing.Debug then
                exports['cis_libs']:LogError("Door not found in system: " .. doorId)
            end
        end
    end
end

-- Get all door data
function DoorLock.GetAllDoorData()
    return {
        doors = DoorLock.doorData,
        groups = DoorLock.doorGroups
    }
end

-- Export functions
exports('GetDoorState', function(...)
    while not FrameworkLoaded do
        Citizen.Wait(100) -- Wait for 100 milliseconds
    end
    return DoorLock.GetDoorState(...)
end)

exports('LockDoors', function(...)
    while not FrameworkLoaded do
        Citizen.Wait(100) -- Wait for 100 milliseconds
    end
    return DoorLock.LockDoors(...)
end)

exports('UnlockDoors', function(...)
    while not FrameworkLoaded do
        Citizen.Wait(100) -- Wait for 100 milliseconds
    end
    return DoorLock.UnlockDoors(...)
end)

exports('BreakDoor', function(...)
    while not FrameworkLoaded do
        Citizen.Wait(100) -- Wait for 100 milliseconds
    end
    return DoorLock.BreakDoor(...)
end)

exports('FixDoor', function(...)
    while not FrameworkLoaded do
        Citizen.Wait(100) -- Wait for 100 milliseconds
    end
    return DoorLock.FixDoor(...)
end)

exports('GetAllDoorData', function(...)
    while not FrameworkLoaded do
        Citizen.Wait(100) -- Wait for 100 milliseconds
    end
    return DoorLock.GetAllDoorData(...)
end)

return DoorLock