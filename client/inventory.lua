local counts = {}

local function setCounts(items)
    counts = {}
    if type(items) ~= 'table' then
        return
    end
    for name, amount in pairs(items) do
        counts[name] = amount or 0
    end
end

RegisterNetEvent('cis_libs:client:inventory', function(items)
    setCounts(items)
end)

CreateThread(function()
    if not CisReadyState.wait(15000) then
        return
    end
    TriggerServerEvent('cis_libs:server:inventorySync')
end)

local function inventoryType()
    return Config and Config.Framework and Config.Framework.Inventory or 'typical'
end

local function snapshotOx()
    if GetResourceState('ox_inventory') ~= 'started' then
        return
    end
    local items
    local ok, result = pcall(function()
        return exports.ox_inventory:GetPlayerItems()
    end)
    if ok and type(result) == 'table' then
        items = result
    else
        ok, result = pcall(function()
            return exports.ox_inventory:Search('slots')
        end)
        if ok then
            items = result
        end
    end
    if type(items) ~= 'table' then
        return
    end
    local nextCounts = {}
    for _, entry in pairs(items) do
        if type(entry) == 'table' and entry.name then
            nextCounts[entry.name] = (nextCounts[entry.name] or 0) + (entry.count or entry.amount or 1)
        end
    end
    setCounts(nextCounts)
end

AddEventHandler('ox_inventory:updateInventory', function()
    if inventoryType() == 'ox_inventory' then
        snapshotOx()
    end
end)

RegisterNetEvent('QBCore:Player:SetPlayerData', function(data)
    if not data or not data.items then
        return
    end
    local nextCounts = {}
    for _, item in pairs(data.items) do
        if item and item.name then
            nextCounts[item.name] = (nextCounts[item.name] or 0) + (item.amount or item.count or 1)
        end
    end
    setCounts(nextCounts)
end)

function InventoryCount(item)
    return counts[item] or 0
end

function InventoryHas(item, amount)
    return InventoryCount(item) >= (amount or 1)
end

exports('InventoryCount', InventoryCount)
exports('InventoryHas', InventoryHas)
