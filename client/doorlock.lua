local DoorLock = {}
local doors = {}
local doorGroups = {}
local addedTargets = {}
local grid = CisGrid.new()
local prefix = 'cis_libs'
local targetMode = false
local fallbackLogged = false

local function eventPrefix()
    return (Security and Security.EventPrefix) or prefix
end

local function interactDistance()
    return (Config and Config.Doorlock and Config.Doorlock.InteractableDistance) or 2.0
end

local modeCache
local modeCacheKey

local function targetStateKey()
    return GetResourceState('ox_target') .. '|' .. GetResourceState('qb-target')
end

local function doorMode()
    -- Resolved once and re-resolved only when the target resource changes
    -- state. The DrawText3D loop calls this every frame, and every miss was a
    -- cross-resource export call.
    local configured = Config and Config.Doorlock and Config.Doorlock.Type or 'target'
    if modeCache then
        if configured ~= 'target' or modeCacheKey == targetStateKey() then
            return modeCache
        end
    end

    if configured == 'target' then
        modeCacheKey = targetStateKey()
        if exports['cis_libs']:TargetAvailable() then
            modeCache = 'target'
            return modeCache
        end
        if not fallbackLogged then
            fallbackLogged = true
            CisLog('warn', 'Door target provider missing; using DrawText3D')
        end
        modeCache = 'DrawText3D'
        return modeCache
    end
    modeCache = configured
    return modeCache
end

AddEventHandler('onClientResourceStart', function(name)
    if name == 'ox_target' or name == 'qb-target' then
        modeCache = nil
        fallbackLogged = false
    end
end)

AddEventHandler('onClientResourceStop', function(name)
    if name == 'ox_target' or name == 'qb-target' then
        modeCache = nil
        fallbackLogged = false
    end
end)

local function asVec3(value)
    if not value then
        return nil
    end
    if type(value) == 'vector3' then
        return value
    end
    return vector3(value.x or value[1], value.y or value[2], value.z or value[3] or 0.0)
end

local function insertDoor(door)
    local coords = door.interactCoords
    local radius = (door.maxDistance or interactDistance()) * 1.5
    CisGrid.insert(grid, door.id, CisGrid.aabbFromCenter(coords.x, coords.y, coords.z, radius, radius, radius), door)
end

function DoorLock.IsDoorGroupLocked(doorIds)
    for i = 1, #doorIds do
        local door = doors[doorIds[i]]
        if door and door.locked then
            return true
        end
    end
    return false
end

local function currentJob()
    if Framework and Framework.GetPlayerJob then
        return Framework.GetPlayerJob()
    end
    return nil
end

function DoorLock.CanInteractWithDoorGroup(doorIds)
    local playerJob = currentJob()
    if not playerJob or not playerJob.name then
        return false
    end
    for i = 1, #doorIds do
        local door = doors[doorIds[i]]
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

function DoorLock.GetDoorsToUpdate(identifier)
    if doorGroups[identifier] then
        return doorGroups[identifier]
    elseif doors[identifier] then
        return { identifier }
    end
    return {}
end

function DoorLock.RequestDoorStateChange(identifier, state)
    TriggerServerEvent(eventPrefix() .. ':doorlock:requestState', identifier, state)
end

function DoorLock.ToggleDoorState(doorId)
    local door = doors[doorId]
    if door then
        DoorLock.RequestDoorStateChange(doorId, not door.locked)
    end
end

function DoorLock.ToggleDoorGroupState(doorIds)
    local newState = not DoorLock.IsDoorGroupLocked(doorIds)
    for i = 1, #doorIds do
        DoorLock.RequestDoorStateChange(doorIds[i], newState)
    end
end

function DoorLock.RemoveTarget(zoneId)
    if not addedTargets[zoneId] then
        return
    end
    exports['cis_libs']:RemoveTarget(zoneId)
    addedTargets[zoneId] = nil
end

function DoorLock.CreateTarget(zoneId, door, targetDoors, isLocked)
    DoorLock.RemoveTarget(zoneId)
    local options = {
        options = {
            {
                name = 'toggle_door_' .. zoneId,
                icon = 'fas fa-door-open',
                label = isLocked and 'Locked' or 'Unlocked',
                canInteract = function()
                    return DoorLock.CanInteractWithDoorGroup(targetDoors)
                end,
                onSelect = function()
                    DoorLock.ToggleDoorGroupState(targetDoors)
                end,
                action = function()
                    DoorLock.ToggleDoorGroupState(targetDoors)
                end,
            },
        },
        distance = door.maxDistance or interactDistance(),
    }
    local size = vec3(1.0, 1.0, 1.0)
    local ok = exports['cis_libs']:CreateTarget('box', zoneId, door.interactCoords, size, options)
    if ok then
        addedTargets[zoneId] = {
            id = zoneId,
            coords = door.interactCoords,
            doors = targetDoors,
            locked = isLocked,
        }
    end
end

function DoorLock.UpdateTarget(zoneId, isLocked)
    local target = addedTargets[zoneId]
    if not target then
        return
    end
    local door = doors[target.doors[1]]
    if not door then
        return
    end
    DoorLock.CreateTarget(zoneId, door, target.doors, isLocked)
end

function DoorLock.AddDoorToSystem(doorData)
    if not doorData or doors[doorData.id] then
        return
    end
    local model = doorData.model
    local doorHash = type(model) == 'number' and model or GetHashKey(model)
    local coords = asVec3(doorData.coords)
    local interact = asVec3(doorData.interactCoords) or coords
    doors[doorData.id] = {
        id = doorData.id,
        coords = coords,
        model = doorHash,
        locked = doorData.locked and true or false,
        broken = doorData.broken and true or false,
        interactCoords = interact,
        maxDistance = doorData.maxDistance or interactDistance(),
        groups = doorData.groups or {},
        groupId = doorData.groupId,
        doorRate = doorData.doorRate,
        auto = doorData.auto,
        state = doorData.state,
    }
    AddDoorToSystem(doorData.id, doorHash, coords.x, coords.y, coords.z, false, false, false)
    DoorSystemSetDoorState(doorData.id, doors[doorData.id].locked and 1 or 0, false, false)
    if doorData.groupId then
        doorGroups[doorData.groupId] = doorGroups[doorData.groupId] or {}
        doorGroups[doorData.groupId][#doorGroups[doorData.groupId] + 1] = doorData.id
    end
    insertDoor(doors[doorData.id])
end

function DoorLock.AddDoorGroup(groupData)
    if not groupData or not groupData.id or not groupData.doors then
        return
    end
    if doorGroups[groupData.id] then
        return
    end
    doorGroups[groupData.id] = groupData.doors
end

function DoorLock.GetClosestDoor()
    local coords = Cis.player.coords()
    local closest, closestDist
    -- insertDoor() sizes each AABB at 1.5x the door's max distance, so any
    -- door within maxDistance is guaranteed to cover this point.
    CisGrid.queryPoint(grid, coords.x, coords.y, coords.z, function(id, item)
        local door = item.data
        local dist = #(coords - door.interactCoords)
        if dist <= door.maxDistance and (not closestDist or dist < closestDist) then
            closestDist = dist
            closest = { id = id, distance = dist, door = door }
        end
    end)
    return closest
end

function DoorLock.GetDoorState(doorId)
    local door = doors[doorId]
    if not door then
        return nil
    end
    return door.locked
end

function DoorLock.UpdateDoorState(identifier, state)
    local doorsToUpdate = DoorLock.GetDoorsToUpdate(identifier)
    for i = 1, #doorsToUpdate do
        local doorId = doorsToUpdate[i]
        local door = doors[doorId]
        if door then
            door.locked = state and true or false
            DoorSystemSetDoorState(doorId, door.locked and 1 or 0, false, false)
            local zoneId = 'door_' .. (door.groupId or doorId)
            if addedTargets[zoneId] then
                DoorLock.UpdateTarget(zoneId, door.locked)
            end
        end
    end
end

function DoorLock.SetBroken(doorId, broken)
    local door = doors[doorId]
    if not door then
        return
    end
    door.broken = broken and true or false
    if door.broken then
        door.locked = false
        DoorSystemSetDoorState(doorId, 0, false, false)
    end
end

local function ensureTarget(doorId, door)
    local groupId = door.groupId
    local targetId = groupId or doorId
    local zoneId = 'door_' .. targetId
    if addedTargets[zoneId] then
        return
    end
    local targetDoors = groupId and doorGroups[groupId] or { doorId }
    DoorLock.CreateTarget(zoneId, door, targetDoors, DoorLock.IsDoorGroupLocked(targetDoors))
end

function DoorLock.RefreshNearbyTargets(coords)
    if not targetMode then
        return
    end
    local keep = {}
    -- The keep radius matches the insert AABB half-extent exactly, so a point
    -- query covers the same door set a neighbour scan would.
    CisGrid.queryPoint(grid, coords.x, coords.y, coords.z, function(id, item)
        local door = item.data
        local dist = #(coords - door.interactCoords)
        if dist <= (door.maxDistance * 1.5) then
            local zoneId = 'door_' .. (door.groupId or id)
            keep[zoneId] = true
            ensureTarget(id, door)
        end
    end)
    for zoneId, target in pairs(addedTargets) do
        if not keep[zoneId] then
            DoorLock.RemoveTarget(zoneId)
        elseif target.doors then
            local locked = DoorLock.IsDoorGroupLocked(target.doors)
            if target.locked ~= locked then
                DoorLock.UpdateTarget(zoneId, locked)
            end
        end
    end
end

function DoorLock.RefreshAllTargets()
    for zoneId in pairs(addedTargets) do
        DoorLock.RemoveTarget(zoneId)
    end
    if targetMode and Cis and Cis.player then
        DoorLock.RefreshNearbyTargets(Cis.player.coords())
    end
end

local function startDrawMode()
    CreateThread(function()
        while doorMode() == 'DrawText3D' do
            local closest = DoorLock.GetClosestDoor()
            if closest then
                local text = closest.door.locked and 'Locked' or 'Unlocked'
                local color = closest.door.locked and { 255, 0, 0, 215 } or { 0, 255, 0, 215 }
                DrawText3D(closest.door.interactCoords.x, closest.door.interactCoords.y, closest.door.interactCoords.z, text, color)
                if IsControlJustReleased(0, 38) then
                    DoorLock.ToggleDoorState(closest.id)
                end
                Wait(0)
            else
                Wait(400)
            end
        end
    end)
end

function DoorLock.Init()
    if Config and Config.Doorlock and Config.Doorlock.Enabled == false then
        return
    end
    targetMode = doorMode() == 'target'
    RegisterNetEvent(eventPrefix() .. ':doorlock:updateState', DoorLock.UpdateDoorState)
    RegisterNetEvent(eventPrefix() .. ':doorlock:addDoor', DoorLock.AddDoorToSystem)
    RegisterNetEvent(eventPrefix() .. ':doorlock:addDoorGroup', DoorLock.AddDoorGroup)
    RegisterNetEvent(eventPrefix() .. ':doorlock:doorBroken', DoorLock.SetBroken)
    RegisterNetEvent('cis_libs:jobUpdated', DoorLock.RefreshAllTargets)
    RegisterNetEvent('cis_libs:playerLoaded', DoorLock.RefreshAllTargets)

    if DoorData and DoorData.doors then
        for _, doorInfo in pairs(DoorData.doors) do
            DoorLock.AddDoorToSystem(doorInfo)
        end
    end
    if DoorData and DoorData.groups then
        for _, groupInfo in pairs(DoorData.groups) do
            DoorLock.AddDoorGroup(groupInfo)
        end
    end

    if targetMode then
        CreateThread(function()
            local last
            while targetMode do
                local coords = Cis.player.coords()
                if not last or #(coords - last) >= 4.0 then
                    last = coords
                    DoorLock.RefreshNearbyTargets(coords)
                end
                Wait(400)
            end
        end)
    else
        startDrawMode()
    end
end

CreateThread(function()
    if not CisReadyState.wait(15000) then
        return
    end
    DoorLock.Init()
end)

RegisterNetEvent('cis_libs:client:toggleDoor', function(data)
    if type(data.doorId) == 'table' then
        DoorLock.ToggleDoorGroupState(data.doorId)
    else
        DoorLock.ToggleDoorState(data.doorId)
    end
end)

exports('AddDoorToSystem', function(data)
    if not CisReadyState.wait(15000) then
        return
    end
    return DoorLock.AddDoorToSystem(data)
end)

exports('AddDoorGroup', function(data)
    if not CisReadyState.wait(15000) then
        return
    end
    return DoorLock.AddDoorGroup(data)
end)

exports('RequestLockDoors', function(identifier)
    if not CisReadyState.wait(15000) then
        return
    end
    return DoorLock.RequestDoorStateChange(identifier, true)
end)

exports('RequestUnlockDoors', function(identifier)
    if not CisReadyState.wait(15000) then
        return
    end
    return DoorLock.RequestDoorStateChange(identifier, false)
end)

exports('GetClosestDoor', function()
    if not CisReadyState.wait(15000) then
        return
    end
    return DoorLock.GetClosestDoor()
end)

exports('GetDoorState', function(doorId)
    if not CisReadyState.wait(15000) then
        return
    end
    return DoorLock.GetDoorState(doorId)
end)
