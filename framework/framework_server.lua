-- cis_libs/framework/framework_server.lua

local Framework = {}
FrameworkLoaded = false

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
            TriggerEvent('esx:getSharedObject', function(obj) ESX = obj end)
        end
        FrameworkLoaded = true
    else
        FrameworkLoaded = true
    end
end)

function Framework.IsLoaded()
    return FrameworkLoaded
end

function Framework.GetOnlineJobCount(jobs)
    if Config.Printing and Config.Printing.Debug then
        exports['cis_libs']:LogDebug("Checking online job count for: " .. json.encode(jobs))
    end

    local count = 0
    local allPlayers = Framework.GetPlayers()

    -- Convert single job string to table for consistent processing
    if type(jobs) == "string" then
        jobs = {jobs}
    end

    for _, playerId in ipairs(allPlayers) do
        local player = Framework.GetPlayer(playerId)
        if player then
            local playerJob = Framework.GetPlayerJob(playerId)
            if playerJob and playerJob.name then
                for _, job in ipairs(jobs) do
                    if playerJob.name == job then
                        count = count + 1
                        break -- Count the player once even if they match multiple requested jobs
                    end
                end
            end
        end
    end

    if Config.Printing and Config.Printing.Debug then
        exports['cis_libs']:LogDebug("Online job count result: " .. count)
    end

    return count
end

function Framework.GetPlayers()
    if Config.Framework.Type == "QBCORE" or Config.Framework.Type == "QBOX" then
        return QBCore.Functions.GetPlayers()
    elseif Config.Framework.Type == "ESX" or Config.Framework.Type == "ESX-LEGACY" then
        return ESX.GetPlayers()
    end
    return {}
end

function Framework.GetPlayer(serverId)
    if Config.Framework.Type == "QBCORE" or Config.Framework.Type == "QBOX" then
        return QBCore.Functions.GetPlayer(serverId)
    elseif Config.Framework.Type == "ESX" or Config.Framework.Type == "ESX-LEGACY" then
        return ESX.GetPlayerFromId(serverId)
    end
    return nil
end

function Framework.GiveItem(serverId, item, amount)
    local Player = Framework.GetPlayer(serverId)
    if Player then
        if Config.Framework.Type == "QBCORE" or Config.Framework.Type == "QBOX" then
            Player.Functions.AddItem(item, amount)
        elseif Config.Framework.Type == "ESX" or Config.Framework.Type == "ESX-LEGACY" then
            Player.addInventoryItem(item, amount)
        end
    end
end

function Framework.GiveMoney(serverId, amount, moneyType)
    local Player = Framework.GetPlayer(serverId)
    if Player then
        if Config.Framework.Type == "QBCORE" or Config.Framework.Type == "QBOX" then
            if moneyType ~= "markedbills" then
                Player.Functions.AddMoney(moneyType, amount)
            else
                Player.Functions.AddItem("markedbills", 1, false, {worth = amount})
            end
        elseif Config.Framework.Type == "ESX" or Config.Framework.Type == "ESX-LEGACY" then
            if moneyType == "markedbills" then
                Player.addInventoryItem("markedbills", 1, {worth = amount})
            else
                Player.addAccountMoney(moneyType, amount)
            end
        end
    end
end

function Framework.HasItem(source, item)
    local Player = Framework.GetPlayer(source)
    if not Player then return false end

    if Config.Framework.Inventory == "ox_inventory" then
        local count = exports.ox_inventory:Search(source, 'count', item)
        return count > 0
    elseif Config.Framework.Inventory == "qb-inventory" or Config.Framework.Inventory == "qs-inventory" then
        return Player.Functions.GetItemByName(item) ~= nil
    elseif Config.Framework.Inventory == "codem-inventory" then
        return exports['codem-inventory']:HasItem(source, item, 1)
    elseif Config.Framework.Inventory == "typical" then
        if Config.Framework.Type == "QBCORE" or Config.Framework.Type == "QBOX" then
            return Player.Functions.GetItemByName(item) ~= nil
        elseif Config.Framework.Type == "ESX" or Config.Framework.Type == "ESX-LEGACY" then
            local item = Player.getInventoryItem(item)
            return item and item.count > 0
        end
    end
    return false
end

function Framework.RemoveItem(source, item, amount)
    local Player = Framework.GetPlayer(source)
    if not Player then return false end

    if Config.Framework.Inventory == "ox_inventory" then
        return exports.ox_inventory:RemoveItem(source, item, amount)
    elseif Config.Framework.Inventory == "qb-inventory" or Config.Framework.Inventory == "qs-inventory" then
        return Player.Functions.RemoveItem(item, amount)
    elseif Config.Framework.Inventory == "codem-inventory" then
        return exports['codem-inventory']:RemoveItem(source, item, amount)
    elseif Config.Framework.Inventory == "typical" then
        if Config.Framework.Type == "QBCORE" or Config.Framework.Type == "QBOX" then
            return Player.Functions.RemoveItem(item, amount)
        elseif Config.Framework.Type == "ESX" or Config.Framework.Type == "ESX-LEGACY" then
            return Player.removeInventoryItem(item, amount)
        end
    end
    return false
end

function Framework.GetPlayerIdentifier(serverId)
    local Player = Framework.GetPlayer(serverId)
    if Player then
        if Config.Framework.Type == "QBCORE" or Config.Framework.Type == "QBOX" then
            return Player.PlayerData.citizenid
        elseif Config.Framework.Type == "ESX" or Config.Framework.Type == "ESX-LEGACY" then
            return Player.identifier
        end
    end
    return nil
end

function Framework.GetPlayerJob(serverId)
    local Player = Framework.GetPlayer(serverId)
    if Player then
        if Config.Framework.Type == "QBCORE" or Config.Framework.Type == "QBOX" then
            return Player.PlayerData.job
        elseif Config.Framework.Type == "ESX" or Config.Framework.Type == "ESX-LEGACY" then
            return Player.job
        end
    end
    return nil
end

function Framework.SetPlayerJob(serverId, job, grade)
    local Player = Framework.GetPlayer(serverId)
    if Player then
        if Config.Framework.Type == "QBCORE" or Config.Framework.Type == "QBOX" then
            Player.Functions.SetJob(job, grade)
        elseif Config.Framework.Type == "ESX" or Config.Framework.Type == "ESX-LEGACY" then
            Player.setJob(job, grade)
        end
        TriggerClientEvent('cis_libs:jobUpdated', serverId, {name = job, grade = grade})
    end
end

function Framework.HasPermission(serverId, permission)
    local Player = Framework.GetPlayer(serverId)
    if Player then
        if Config.Framework.Type == "QBCORE" or Config.Framework.Type == "QBOX" then
            return QBCore.Functions.HasPermission(serverId, permission)
        elseif Config.Framework.Type == "ESX" or Config.Framework.Type == "ESX-LEGACY" then
            local xPlayer = ESX.GetPlayerFromId(serverId)
            return xPlayer.getGroup() == permission
        end
    end
    return false
end

-- Server callback for job count
Framework.CreateCallback = Framework.CreateCallback or function(name, cb)
    -- Implementation depends on the framework, this is a generic example
    RegisterNetEvent(name)
    AddEventHandler(name, function(...)
        local source = source
        cb(source, function(...)
            TriggerClientEvent(name .. ':response', source, ...)
        end, ...)
    end)
end

Framework.CreateCallback('cis_libs:getOnlineJobCount', function(source, cb, jobs)
    cb(Framework.GetOnlineJobCount(jobs))
end)

-- Export functions
exports('GetFramework', function()
    -- Wait until FrameworkLoaded is true
    while not FrameworkLoaded do
        Citizen.Wait(100) -- Wait for 100 milliseconds
    end

    return Framework
end)