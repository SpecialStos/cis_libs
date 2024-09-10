-- cis_libs/framework/framework_server.lua

local Framework = {}
local FrameworkLoaded = false
local currentCops = 0

Citizen.CreateThread(function()
    if Config.Framework == "QBCORE" or Config.Framework == "QBOX" then
        QBCore = exports['qb-core']:GetCoreObject()
    elseif Config.Framework == "ESX" then
        ESX = exports["es_extended"]:getSharedObject()
    else
        FrameworkLoaded = true
    end
end)

function Framework.CheckPoliceCount()
    local numCops = 0
    if Config.Framework == "QBCORE" or Config.Framework == "QBOX" then
        numCops = #QBCore.Functions.GetPlayersOnDuty("police")
    elseif Config.Framework == "ESX" then
        local xPlayers = ESX.GetPlayers()
        for i=1, #xPlayers, 1 do
            local xPlayer = ESX.GetPlayerFromId(xPlayers[i])
            if xPlayer and xPlayer.job.name == "police" then
                numCops = numCops + 1
            end
        end
    end
    return numCops
end

function Framework.GiveItem(serverId, item, amount)
    if type(item) == "table" then
        item = item.name
    end
    
    local Player = Framework.GetPlayer(serverId)
    if Player then
        if Config.Framework == "QBCORE" or Config.Framework == "QBOX" then
            Player.Functions.AddItem(item, amount)
        elseif Config.Framework == "ESX" then
            Player.addInventoryItem(item, amount)
        end
    else
        TriggerEvent(Security.EventPrefix .. ":server:log", "Player not found to give item.", "error")
    end
end

function Framework.GiveMoney(serverId, amount)
    local Player = Framework.GetPlayer(serverId)
    if Player then
        if Config.Framework == "QBCORE" or Config.Framework == "QBOX" then
            if Config.GlobalStoreSettings.GiveMoneyType ~= "markedbills" then
                Player.Functions.AddMoney(Config.GlobalStoreSettings.GiveMoneyType, amount)
            else
                Player.Functions.AddItem('markedbills', 1, false, {worth = amount})
            end
        elseif Config.Framework == "ESX" then
            Player.addAccountMoney(Config.GlobalStoreSettings.GiveMoneyType, amount)
        end
    else
        TriggerEvent(Security.EventPrefix .. ":server:log", "Player not found to give money.", "error")
    end
end

function Framework.GetPlayer(serverId)
    if Config.Framework == "QBCORE" or Config.Framework == "QBOX" then
        return QBCore.Functions.GetPlayer(serverId)
    elseif Config.Framework == "ESX" then
        return ESX.GetPlayerFromId(serverId)
    end
    return nil
end

function Framework.GetPlayerIdentifier(serverId)
    local Player = Framework.GetPlayer(serverId)
    if Player then
        if Config.Framework == 'QBCORE' or Config.Framework == "QBOX" then
            return Player.PlayerData.citizenid
        elseif Config.Framework == 'ESX' then
            return Player.identifier
        end
    end
    return nil
end

-- Export functions
exports('CheckPoliceCount', Framework.CheckPoliceCount)
exports('GiveItem', Framework.GiveItem)
exports('GiveMoney', Framework.GiveMoney)
exports('GetPlayer', Framework.GetPlayer)
exports('GetPlayerIdentifier', Framework.GetPlayerIdentifier)