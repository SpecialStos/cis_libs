-- cis_libs/framework/framework_client.lua

FrameworkLoaded = false
local Framework = {}
local PlayerJob = nil

Citizen.CreateThread(function()
    while Config == nil do
        Citizen.Wait(100)
    end

    if Config.Framework.Type == "QBCORE" or Config.Framework.Type == "QBOX" then
        QBCore = exports['qb-core']:GetCoreObject()
        FrameworkLoaded = true
    elseif Config.Framework.Type == "ESX" or Config.Framework.Type == "ESX-LEGACY" then
        if Config.Framework.Type == "ESX-LEGACY" then
            ESX = exports["es_extended"]:getSharedObject()
        else
            while ESX == nil do
                TriggerEvent('esx:getSharedObject', function(obj) ESX = obj end)
                Citizen.Wait(0)
            end
        end
        FrameworkLoaded = true
    else
        FrameworkLoaded = true
    end

    while not FrameworkLoaded do
        Citizen.Wait(100)
    end

    -- Initialize player job
    local playerData = Framework.GetPlayerData()
    if playerData and playerData.job then
        PlayerJob = playerData.job
    end

    -- Register job update events
    if Config.Framework.Type == "QBCORE" or Config.Framework.Type == "QBOX" then
        RegisterNetEvent('QBCore:Client:OnJobUpdate')
        AddEventHandler('QBCore:Client:OnJobUpdate', Framework.UpdatePlayerJob)
        
        -- Add event for when player is loaded
        RegisterNetEvent('QBCore:Client:OnPlayerLoaded')
        AddEventHandler('QBCore:Client:OnPlayerLoaded', Framework.OnPlayerLoaded)
    elseif Config.Framework.Type == "ESX" or Config.Framework.Type == "ESX-LEGACY" then
        RegisterNetEvent('esx:setJob')
        AddEventHandler('esx:setJob', Framework.UpdatePlayerJob)
        
        -- Add event for when player is loaded
        RegisterNetEvent('esx:playerLoaded')
        AddEventHandler('esx:playerLoaded', Framework.OnPlayerLoaded)
    end
end)

function Framework.GetPlayerData()
    if Config.Framework.Type == "QBCORE" or Config.Framework.Type == "QBOX" then
        return QBCore.Functions.GetPlayerData()
    elseif Config.Framework.Type == "ESX" or Config.Framework.Type == "ESX-LEGACY" then
        return ESX.GetPlayerData()
    end
    return nil
end

function Framework.UpdatePlayerJob(job)
    PlayerJob = job
    --print("Job updated:", json.encode(PlayerJob))
    TriggerEvent('cis_libs:jobUpdated', job)
end

function Framework.OnPlayerLoaded(xPlayer)
    local playerData = Framework.GetPlayerData()
    if playerData and playerData.job then
        PlayerJob = playerData.job
        --print("Player loaded. Initial job:", json.encode(PlayerJob))
        TriggerEvent('cis_libs:playerLoaded', PlayerJob)
    end
end

function Framework.GetPlayerJob()
    return PlayerJob
end

function Framework.ShowNotification(message)
    if Config.Framework.Type == "QBCORE" or Config.Framework.Type == "QBOX" then
        QBCore.Functions.Notify(message)
    elseif Config.Framework.Type == "ESX" or Config.Framework.Type == "ESX-LEGACY" then
        ESX.ShowNotification(message)
    else
        SetNotificationTextEntry("STRING")
        AddTextComponentString(message)
        DrawNotification(false, false)
    end
end

function Framework.TriggerServerCallback(name, cb, ...)
    if Config.Framework.Type == "QBCORE" or Config.Framework.Type == "QBOX" then
        QBCore.Functions.TriggerCallback(name, cb, ...)
    elseif Config.Framework.Type == "ESX" or Config.Framework.Type == "ESX-LEGACY" then
        ESX.TriggerServerCallback(name, cb, ...)
    end
end

function Framework.HasItem(item)
    if Config.Framework.Inventory == "ox_inventory" then
        local count = exports.ox_inventory:Search('count', item)
        return count > 0
    elseif Config.Framework.Inventory == "qb-inventory" then
        return exports['qb-inventory']:HasItem(item, 1)
    elseif Config.Framework.Inventory == "qs-inventory" then
        return exports['qs-inventory']:HasItem(item, 1)
    elseif Config.Framework.Inventory == "codem-inventory" then
        local hasItem = false
        Framework.TriggerServerCallback(Security.EventPrefix .. ":server:codemCallback", function(result)
            hasItem = result
        end, item)
        return hasItem
    elseif Config.Framework.Inventory == "typical" then
        local Player = Framework.GetPlayerData()
        if Config.Framework.Type == "QBCORE" or Config.Framework.Type == "QBOX" then
            for i = 1, #Player.items, 1 do
                if Player.items[i] and Player.items[i].name == item then
                    return true
                end
            end
        elseif Config.Framework.Type == "ESX" or Config.Framework.Type == "ESX-LEGACY" then
            for i = 1, #Player.inventory, 1 do
                if Player.inventory[i].name == item and Player.inventory[i].count > 0 then
                    return true
                end
            end
        end
    end
    return false
end

function Framework.CreateVehicle(model, coords, heading, cb)
    if Config.Framework.Type == "QBCORE" or Config.Framework.Type == "QBOX" then
        QBCore.Functions.SpawnVehicle(model, function(vehicle)
            SetEntityHeading(vehicle, heading)
            SetVehicleOnGroundProperly(vehicle)
            if cb then cb(vehicle) end
        end, coords, true)
    elseif Config.Framework.Type == "ESX" or Config.Framework.Type == "ESX-LEGACY" then
        ESX.Game.SpawnVehicle(model, coords, heading, function(vehicle)
            SetVehicleOnGroundProperly(vehicle)
            if cb then cb(vehicle) end
        end)
    else
        -- Fallback to native function
        local vehicle = CreateVehicle(GetHashKey(model), coords.x, coords.y, coords.z, heading, true, false)
        SetVehicleOnGroundProperly(vehicle)
        if cb then cb(vehicle) end
    end
end

-- New function to get online job count
function Framework.GetOnlineJobCount(jobs, cb)
    if Config.Printing and Config.Printing.Debug then
        exports['cis_libs']:LogDebug("Requesting online job count for: " .. json.encode(jobs))
    end

    Framework.TriggerServerCallback('cis_libs:getOnlineJobCount', function(count)
        if Config.Printing and Config.Printing.Debug then
            exports['cis_libs']:LogDebug("Received online job count: " .. count)
        end
        cb(count)
    end, jobs)
end

-- Export functions
exports('GetFramework', function()
    -- Wait until FrameworkLoaded is true
    while not FrameworkLoaded do
        Citizen.Wait(100) -- Wait for 100 milliseconds
    end
    return Framework
end)