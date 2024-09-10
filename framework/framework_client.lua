-- cis_libs/framework/framework_client.lua

local Framework = {}
local FrameworkLoaded = false

Citizen.CreateThread(function()

    while Config == nil or Security == nil do
        Citizen.Wait(100)
    end

    if Config.Framework == "QBCORE" or Config.Framework == "QBOX" then
        QBCore = exports['qb-core']:GetCoreObject()
    elseif Config.Framework == "ESX" then
        ESX = exports["es_extended"]:getSharedObject()
    else
        FrameworkLoaded = true
    end

    while not FrameworkLoaded do
        Citizen.Wait(100)
    end
end)

function Framework.GetPlayerData()
    if Config.Framework == "QBCORE" or Config.Framework == "QBOX" then
        return QBCore.Functions.GetPlayerData()
    elseif Config.Framework == "ESX" then
        return ESX.GetPlayerData()
    end
    return nil
end

function Framework.ShowNotification(message)
    if Config.Framework == "QBCORE" or Config.Framework == "QBOX" then
        QBCore.Functions.Notify(message)
    elseif Config.Framework == "ESX" then
        ESX.ShowNotification(message)
    else
        -- Fallback to a basic notification if no framework is used
        SetNotificationTextEntry("STRING")
        AddTextComponentString(message)
        DrawNotification(false, false)
    end
end

function Framework.TriggerServerCallback(name, cb, ...)
    if Config.Framework == "QBCORE" or Config.Framework == "QBOX" then
        QBCore.Functions.TriggerCallback(name, cb, ...)
    elseif Config.Framework == "ESX" then
        ESX.TriggerServerCallback(name, cb, ...)
    end
end

-- Export functions
exports('GetPlayerData', Framework.GetPlayerData)
exports('ShowNotification', Framework.ShowNotification)
exports('TriggerServerCallback', Framework.TriggerServerCallback)