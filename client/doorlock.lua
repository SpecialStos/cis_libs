-- cis_libs/client/doorlock.lua

local DoorLock = {}
local doors = {}
local doorGroups = {}
local addedTargets = {}

-- Initialize the door lock system
function DoorLock.Init()
    if Config.Printing and Config.Printing.Debug then
        exports['cis_libs']:LogDebug("Initializing door lock system")
    end

    -- Register network events
    RegisterNetEvent(Security.EventPrefix .. ':doorlock:updateState')
    AddEventHandler(Security.EventPrefix .. ':doorlock:updateState', DoorLock.UpdateDoorState)

    RegisterNetEvent(Security.EventPrefix .. ':doorlock:addDoor')
    AddEventHandler(Security.EventPrefix .. ':doorlock:addDoor', DoorLock.AddDoorToSystem)

    RegisterNetEvent(Security.EventPrefix .. ':doorlock:addDoorGroup')
    AddEventHandler(Security.EventPrefix .. ':doorlock:addDoorGroup', DoorLock.AddDoorGroup)

    -- Register job update event
    RegisterNetEvent('cis_libs:jobUpdated')
    AddEventHandler('cis_libs:jobUpdated', DoorLock.OnJobUpdate)

    -- Register player loaded event
    RegisterNetEvent('cis_libs:playerLoaded')
    AddEventHandler('cis_libs:playerLoaded', DoorLock.OnPlayerLoaded)

    -- Initialize doors from the data received in initialize.lua
    if DoorData and DoorData.doors then
        for doorId, doorInfo in pairs(DoorData.doors) do
            DoorLock.AddDoorToSystem(doorInfo)
        end
        if Config.Printing and Config.Printing.Debug then
            exports['cis_libs']:LogDebug("Initialized " .. #DoorData.doors .. " doors from initial data")
        end
    end

    -- Initialize door groups from the data received in initialize.lua
    if DoorData and DoorData.groups then
        for groupId, groupInfo in pairs(DoorData.groups) do
            DoorLock.AddDoorGroup(groupInfo)
        end
        if Config.Printing and Config.Printing.Debug then
            exports['cis_libs']:LogDebug("Initialized " .. #DoorData.groups .. " door groups from initial data")
        end
    end

    -- Start the main loop for door interactions
    Citizen.CreateThread(DoorLock.MainLoop)

    --print("Door lock system initialized client-side")
end

-- Main loop for door interactions
function DoorLock.MainLoop()
    while true do
        Citizen.Wait(0)
        local playerPed = PlayerPedId()
        local playerCoords = GetEntityCoords(playerPed)
        local closestDoor = DoorLock.GetClosestDoor()

        if closestDoor then
            if Config.Doorlock.Type == "DrawText3D" then
                DoorLock.HandleDrawText3D(closestDoor)
            elseif Config.Doorlock.Type == "target" then
                DoorLock.HandleTarget(closestDoor)
            end
        end

        -- Clean up targets for doors that are no longer nearby
        DoorLock.CleanupTargets(playerCoords)
    end
end

-- Cleanup targets for doors that are no longer nearby
function DoorLock.CleanupTargets(playerCoords)
    for zoneId, targetData in pairs(addedTargets) do
        if #(playerCoords - targetData.coords) > Config.Doorlock.InteractableDistance * 1.5 then
            DoorLock.RemoveTarget(zoneId)
        end
    end
end

-- Remove a target
function DoorLock.RemoveTarget(zoneId)
    if addedTargets[zoneId] then
        if Config.Framework.Target.Type == "ox_target" then
            exports.ox_target:removeZone(zoneId)
        elseif Config.Framework.Target.Type == "qb-target" then
            exports['qb-target']:RemoveZone(zoneId)
        end
        addedTargets[zoneId] = nil
        if Config.Printing and Config.Printing.Debug then
            exports['cis_libs']:LogDebug("Removed target: " .. zoneId)
        end
    end
end

-- Check if any door in a group is locked
function DoorLock.IsDoorGroupLocked(doorIds)
    for _, doorId in ipairs(doorIds) do
        if doors[doorId] and doors[doorId].locked then
            return true
        end
    end
    return false
end

-- Handle DrawText3D interaction
function DoorLock.HandleDrawText3D(closestDoor)
    local text = closestDoor.door.locked and "Locked" or "Unlocked"
    local color = closestDoor.door.locked and {255, 0, 0} or {0, 255, 0}
    
    DrawText3D(closestDoor.door.interactCoords.x, closestDoor.door.interactCoords.y, closestDoor.door.interactCoords.z, text, color)

    if IsControlJustReleased(0, 38) then -- 'E' key
        DoorLock.ToggleDoorState(closestDoor.id)
    end
end

-- Handle target interaction
function DoorLock.HandleTarget(closestDoor)
    local doorId = closestDoor.id
    local groupId = doors[doorId] and doors[doorId].groupId
    local targetId = groupId or doorId
    local zoneId = "door_" .. targetId
    local targetDoors = groupId and doorGroups[groupId] or {doorId}
    
    -- Add nil checks before accessing the table
    if not doors[doorId] then
        if Config.Printing and Config.Printing.Debug then
            exports['cis_libs']:LogError("Door not found in doors table: " .. tostring(doorId))
        end
        return
    end
    
    local isLocked = DoorLock.IsDoorGroupLocked(targetDoors)

    if addedTargets[zoneId] then
        if addedTargets[zoneId].locked ~= isLocked then
            DoorLock.UpdateTarget(zoneId, isLocked)
        end
    else
        DoorLock.CreateTarget(zoneId, closestDoor, targetDoors, isLocked)
    end

    if Config.Printing and Config.Printing.Debug then
        exports['cis_libs']:LogDebug("HandleTarget executed for door: " .. tostring(doorId) .. ", isLocked: " .. tostring(isLocked))
    end
end

function DoorLock.CreateTarget(zoneId, closestDoor, targetDoors, isLocked)
    DoorLock.RemoveTarget(zoneId)

    local options = {
        {
            name = 'toggle_door_' .. zoneId,
            icon = 'fas fa-door-open',
            label = isLocked and "Locked" or "Unlocked",
            canInteract = function()
                return DoorLock.CanInteractWithDoorGroup(targetDoors)
            end,
            onSelect = function()
                DoorLock.ToggleDoorGroupState(targetDoors)
            end
        }
    }

    if Config.Framework.Target.Type == "ox_target" then
        exports.ox_target:addBoxZone({
            coords = closestDoor.door.interactCoords,
            size = vec3(1, 1, 1),
            rotation = 0,
            debug = Config.Printing.Debug,
            options = options,
            name = zoneId
        })
    elseif Config.Framework.Target.Type == "qb-target" then
        exports['qb-target']:AddBoxZone(zoneId, closestDoor.door.interactCoords, 1, 1, {
            name = zoneId,
            heading = 0,
            debugPoly = Config.Printing.Debug,
            minZ = closestDoor.door.interactCoords.z - 0.5,
            maxZ = closestDoor.door.interactCoords.z + 0.5,
        }, {
            options = options,
            distance = 1.5
        })
    end

    addedTargets[zoneId] = {
        id = zoneId,
        coords = closestDoor.door.interactCoords,
        doors = targetDoors,
        locked = isLocked
    }

    if Config.Printing and Config.Printing.Debug then
        exports['cis_libs']:LogDebug("Added new target: " .. zoneId .. ", Locked: " .. tostring(isLocked))
    end
end

function DoorLock.UpdateTarget(zoneId, isLocked)
    if Config.Printing and Config.Printing.Debug then
        exports['cis_libs']:LogDebug("Updating target for zoneId: " .. tostring(zoneId) .. ", locked: " .. tostring(isLocked))
    end

    if not addedTargets[zoneId] then
        if Config.Printing and Config.Printing.Debug then
            exports['cis_libs']:LogWarn("Attempted to update non-existent target: " .. tostring(zoneId))
        end
        return
    end

    local targetData = addedTargets[zoneId]
    if not targetData.coords then
        if Config.Printing and Config.Printing.Debug then
            exports['cis_libs']:LogError("Target data missing coordinates for zoneId: " .. tostring(zoneId))
        end
        return
    end

    DoorLock.RemoveTarget(zoneId)
    DoorLock.CreateTarget(zoneId, {door = {interactCoords = targetData.coords}}, targetData.doors, isLocked)

    if Config.Printing and Config.Printing.Debug then
        exports['cis_libs']:LogDebug("Updated target: " .. tostring(zoneId) .. ", Locked: " .. tostring(isLocked))
    end
end

-- Check if player can interact with any door in a group
function DoorLock.CanInteractWithDoorGroup(doorIds)
    local playerJob = exports['cis_libs']:GetFramework().GetPlayerJob()
    if not playerJob or not playerJob.name then
        if Config.Printing and Config.Printing.Debug then
            exports['cis_libs']:LogError("Player job not found")
        end
        return false
    end

    for _, doorId in ipairs(doorIds) do
        if doors[doorId] and doors[doorId].groups then
            for _, allowedJob in ipairs(doors[doorId].groups) do
                if playerJob.name == allowedJob then
                    return true
                end
            end
        end
    end

    return false
end

-- Toggle door state
function DoorLock.ToggleDoorState(doorId)
    if doors[doorId] then
        local newState = not doors[doorId].locked
        DoorLock.RequestDoorStateChange(doorId, newState)
    end
end

-- Toggle state for a group of doors
function DoorLock.ToggleDoorGroupState(doorIds)
    local newState = not DoorLock.IsDoorGroupLocked(doorIds)
    for _, doorId in ipairs(doorIds) do
        DoorLock.RequestDoorStateChange(doorId, newState)
    end
end

-- Request door state change
function DoorLock.RequestDoorStateChange(identifier, state)
    TriggerServerEvent(Security.EventPrefix .. ':doorlock:requestState', identifier, state)
    if Config.Printing and Config.Printing.Debug then
        exports['cis_libs']:LogDebug("Door state change requested for " .. identifier .. " to " .. tostring(state))
    end
end

-- Update the state of a door or door group
function DoorLock.UpdateDoorState(identifier, state)
    if Config.Printing and Config.Printing.Debug then
        exports['cis_libs']:LogDebug("Updating door state for identifier: " .. tostring(identifier) .. ", new state: " .. tostring(state))
    end

    local doorsToUpdate = DoorLock.GetDoorsToUpdate(identifier)

    if #doorsToUpdate == 0 then
        if Config.Printing and Config.Printing.Debug then
            exports['cis_libs']:LogWarn("No doors found to update for identifier: " .. tostring(identifier))
        end
        return
    end

    for _, doorId in ipairs(doorsToUpdate) do
        if doors[doorId] then
            doors[doorId].locked = state
            DoorSystemSetDoorState(doorId, state and 1 or 0, false, false)
            
            -- Update target if it exists
            local zoneId = "door_" .. (doors[doorId].groupId or doorId)
            if addedTargets[zoneId] then
                DoorLock.UpdateTarget(zoneId, state)
            else
                if Config.Printing and Config.Printing.Debug then
                    exports['cis_libs']:LogDebug("No target found for zoneId: " .. zoneId)
                end
            end
        else
            if Config.Printing and Config.Printing.Debug then
                exports['cis_libs']:LogWarn("Door not found in system: " .. tostring(doorId))
            end
        end
    end

    if Config.Printing and Config.Printing.Debug then
        exports['cis_libs']:LogDebug("Door state update completed for identifier: " .. tostring(identifier))
    end
end

-- Helper function to get doors to update
function DoorLock.GetDoorsToUpdate(identifier)
    if doorGroups[identifier] then
        return doorGroups[identifier]
    elseif doors[identifier] then
        return {identifier}
    else
        if Config.Printing and Config.Printing.Debug then
            exports['cis_libs']:LogError("Invalid identifier: " .. tostring(identifier))
        end
        return {}
    end
end

-- Add a door to the system
function DoorLock.AddDoorToSystem(doorData)
    if doors[doorData.id] then
        if Config.Printing and Config.Printing.Debug then
            exports['cis_libs']:LogDebug("Door already exists: " .. doorData.id)
        end
        return
    end

    local doorHash = GetHashKey(doorData.model)
    doors[doorData.id] = {
        id = doorData.id,
        coords = doorData.coords,
        model = doorHash,
        locked = doorData.locked,
        interactCoords = doorData.interactCoords or doorData.coords,
        maxDistance = doorData.maxDistance or Config.Doorlock.InteractableDistance,
        groups = doorData.groups or {},
        lockpick = doorData.lockpick or false,
        groupId = doorData.groupId
    }

    AddDoorToSystem(doorData.id, doorHash, doorData.coords.x, doorData.coords.y, doorData.coords.z, false, false, false)
    DoorSystemSetDoorState(doorData.id, doorData.locked and 1 or 0, false, false)

    if doorData.groupId then
        if not doorGroups[doorData.groupId] then
            doorGroups[doorData.groupId] = {}
        end
        table.insert(doorGroups[doorData.groupId], doorData.id)
    end

    if Config.Printing and Config.Printing.Debug then
        exports['cis_libs']:LogDebug("Added door to system: " .. doorData.id)
    end
end

-- Add a door group
function DoorLock.AddDoorGroup(groupData)
    if Config.Printing and Config.Printing.Debug then
        exports['cis_libs']:LogDebug("Attempting to add door group: " .. tostring(groupData.id))
    end

    -- Initialize doorGroups if it doesn't exist
    if not doorGroups then
        doorGroups = {}
        if Config.Printing and Config.Printing.Debug then
            exports['cis_libs']:LogDebug("Initialized doorGroups table")
        end
    end

    -- Check if the door group already exists
    if doorGroups[groupData.id] then
        if Config.Printing and Config.Printing.Debug then
            exports['cis_libs']:LogDebug("Door group already exists: " .. tostring(groupData.id))
        end
        return
    end

    -- Ensure groupData and groupData.doors are not nil
    if not groupData or not groupData.doors then
        if Config.Printing and Config.Printing.Debug then
            exports['cis_libs']:LogError("Invalid groupData provided to AddDoorGroup")
        end
        return
    end

    -- Add the door group
    doorGroups[groupData.id] = groupData.doors
    if Config.Printing and Config.Printing.Debug then
        exports['cis_libs']:LogDebug("Added door group: " .. tostring(groupData.id) .. " with " .. #groupData.doors .. " doors")
    end
end

-- Get the closest door to the player
function DoorLock.GetClosestDoor()
    local playerPed = PlayerPedId()
    local playerCoords = GetEntityCoords(playerPed)
    local closestDoor = nil
    local closestDistance = math.huge

    for id, door in pairs(doors) do
        local distance = #(playerCoords - door.interactCoords)
        if distance < closestDistance and distance <= door.maxDistance then
            closestDistance = distance
            closestDoor = {id = id, distance = distance, door = door}
        end
    end

    if Config.Printing and Config.Printing.Debug and closestDoor then
        exports['cis_libs']:LogDebug("Closest door found: " .. closestDoor.id .. " at distance " .. closestDoor.distance)
    end

    return closestDoor
end

-- Get the state of a specific door
function DoorLock.GetDoorState(doorId)
    if doors[doorId] then
        if Config.Printing and Config.Printing.Debug then
            exports['cis_libs']:LogDebug("Door state for " .. doorId .. ": " .. tostring(doors[doorId].locked))
        end
        return doors[doorId].locked
    else
        if Config.Printing and Config.Printing.Debug then
            exports['cis_libs']:LogError("Door not found in system: " .. doorId)
        end
        return nil
    end
end

-- Handle job updates
function DoorLock.OnJobUpdate(job)
    if Config.Printing and Config.Printing.Debug then
        exports['cis_libs']:LogDebug("Job updated: " .. json.encode(job))
    end
    DoorLock.RefreshAllTargets()
end

-- Handle player loaded
function DoorLock.OnPlayerLoaded(playerData)
    if Config.Printing and Config.Printing.Debug then
        exports['cis_libs']:LogDebug("Player loaded. Initializing door locks.")
    end
    -- Ensure doors are properly set up for the newly loaded player
    DoorLock.RefreshAllTargets()
end

-- Refresh all targets based on new job
function DoorLock.RefreshAllTargets()
    if Config.Printing and Config.Printing.Debug then
        exports['cis_libs']:LogDebug("Refreshing all door targets")
    end
    
    for zoneId, _ in pairs(addedTargets) do
        DoorLock.RemoveTarget(zoneId)
    end
    addedTargets = {}

    -- Re-add targets for all doors
    for doorId, door in pairs(doors) do
        local groupId = door.groupId
        local targetId = groupId or doorId
        local zoneId = "door_" .. targetId
        local targetDoors = groupId and doorGroups[groupId] or {doorId}
        local isLocked = DoorLock.IsDoorGroupLocked(targetDoors)
        
        DoorLock.CreateTarget(zoneId, {door = door}, targetDoors, isLocked)
    end
end

-- Export functions
exports('AddDoorToSystem', function(...)
    while not FrameworkLoaded do
        Citizen.Wait(100) -- Wait for 100 milliseconds
    end
    return DoorLock.AddDoorToSystem(...)
end)

exports('AddDoorGroup', function(...)
    while not FrameworkLoaded do
        Citizen.Wait(100) -- Wait for 100 milliseconds
    end
    return DoorLock.AddDoorGroup(...)
end)

exports('RequestLockDoors', function(...)
    while not FrameworkLoaded do
        Citizen.Wait(100) -- Wait for 100 milliseconds
    end
    return DoorLock.RequestDoorStateChange(...)
end)

exports('RequestUnlockDoors', function(...)
    while not FrameworkLoaded do
        Citizen.Wait(100) -- Wait for 100 milliseconds
    end
    return DoorLock.RequestDoorStateChange(...)
end)

exports('GetClosestDoor', function(...)
    while not FrameworkLoaded do
        Citizen.Wait(100) -- Wait for 100 milliseconds
    end
    return DoorLock.GetClosestDoor(...)
end)

exports('GetDoorState', function(...)
    while not FrameworkLoaded do
        Citizen.Wait(100) -- Wait for 100 milliseconds
    end
    return DoorLock.GetDoorState(...)
end)

-- Initialize the system
Citizen.CreateThread(function()
    while Config == nil do
        Citizen.Wait(100)
    end

    DoorLock.Init()
end)

-- Event handler for qb-target door toggle
RegisterNetEvent('cis_libs:client:toggleDoor')
AddEventHandler('cis_libs:client:toggleDoor', function(data)
    if type(data.doorId) == "table" then
        DoorLock.ToggleDoorGroupState(data.doorId)
    else
        DoorLock.ToggleDoorState(data.doorId)
    end
end)

return DoorLock