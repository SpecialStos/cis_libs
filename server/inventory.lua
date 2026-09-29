local function inventoryType()
    return Config and Config.Framework and Config.Framework.Inventory or 'typical'
end

local function started(name)
    return GetResourceState(name) == 'started'
end

local function oxCount(src, item)
    if not started('ox_inventory') then
        return 0
    end
    local count = exports.ox_inventory:Search(src, 'count', item)
    return count or 0
end

local function playerItems(src)
    if not CisFramework then
        return {}
    end
    local player = CisFramework.GetPlayer(src)
    if not player then
        return {}
    end
    if player.PlayerData and player.PlayerData.items then
        return player.PlayerData.items
    end
    if player.getInventory then
        return player.getInventory()
    end
    return player.inventory or {}
end

function InventoryCount(src, item)
    local kind = inventoryType()
    if kind == 'ox_inventory' then
        return oxCount(src, item)
    end
    if kind == 'codem-inventory' and started('codem-inventory') then
        local ok, result = pcall(function()
            return exports['codem-inventory']:GetItemsTotalAmount(src, item)
        end)
        if ok and type(result) == 'number' then
            return result
        end
        ok, result = pcall(function()
            return exports['codem-inventory']:HasItem(src, item, 1)
        end)
        if ok then
            return result and 1 or 0
        end
    end
    local total = 0
    for _, entry in pairs(playerItems(src)) do
        if entry and (entry.name == item or entry.item == item) then
            total = total + (entry.amount or entry.count or 1)
        end
    end
    return total
end

function InventoryHas(src, item, amount)
    return InventoryCount(src, item) >= (amount or 1)
end

function InventorySnapshot(src)
    local snapshot = {}
    local kind = inventoryType()
    if kind == 'ox_inventory' and started('ox_inventory') then
        local items = exports.ox_inventory:GetInventoryItems(src)
        if type(items) == 'table' then
            for _, entry in pairs(items) do
                if entry and entry.name then
                    snapshot[entry.name] = (snapshot[entry.name] or 0) + (entry.count or entry.amount or 1)
                end
            end
        end
        return snapshot
    end
    for _, entry in pairs(playerItems(src)) do
        if entry and (entry.name or entry.item) then
            local name = entry.name or entry.item
            snapshot[name] = (snapshot[name] or 0) + (entry.amount or entry.count or 1)
        end
    end
    return snapshot
end

local function pushSnapshot(src)
    TriggerClientEvent('cis_libs:client:inventory', src, InventorySnapshot(src))
end

local function typicalPlayer(src)
    return CisFramework and CisFramework.GetPlayer(src) or nil
end

function InventoryAdd(src, item, amount, metadata)
    amount = amount or 1
    local kind = inventoryType()
    local ok
    if kind == 'ox_inventory' and started('ox_inventory') then
        ok = exports.ox_inventory:AddItem(src, item, amount, metadata)
    elseif kind == 'codem-inventory' and started('codem-inventory') then
        ok = exports['codem-inventory']:AddItem(src, item, amount, nil, metadata)
    elseif kind == 'qs-inventory' and started('qs-inventory') then
        ok = exports['qs-inventory']:AddItem(src, item, amount, nil, metadata)
    elseif kind == 'qb-inventory' and started('qb-inventory') then
        ok = exports['qb-inventory']:AddItem(src, item, amount, false, metadata)
    else
        local player = typicalPlayer(src)
        if player and player.Functions and player.Functions.AddItem then
            ok = player.Functions.AddItem(item, amount, false, metadata)
        elseif player and player.addInventoryItem then
            ok = player.addInventoryItem(item, amount, metadata)
        else
            ok = false
        end
    end
    if ok then
        pushSnapshot(src)
    end
    return ok
end

function InventoryRemove(src, item, amount)
    amount = amount or 1
    local kind = inventoryType()
    local ok
    if kind == 'ox_inventory' and started('ox_inventory') then
        ok = exports.ox_inventory:RemoveItem(src, item, amount)
    elseif kind == 'codem-inventory' and started('codem-inventory') then
        ok = exports['codem-inventory']:RemoveItem(src, item, amount)
    elseif kind == 'qs-inventory' and started('qs-inventory') then
        ok = exports['qs-inventory']:RemoveItem(src, item, amount)
    elseif kind == 'qb-inventory' and started('qb-inventory') then
        ok = exports['qb-inventory']:RemoveItem(src, item, amount, false)
    else
        local player = typicalPlayer(src)
        if player and player.Functions and player.Functions.RemoveItem then
            ok = player.Functions.RemoveItem(item, amount)
        elseif player and player.removeInventoryItem then
            ok = player.removeInventoryItem(item, amount)
        else
            ok = false
        end
    end
    if ok then
        pushSnapshot(src)
    end
    return ok
end

CisNetOn('cis_libs:server:inventorySync', function(src)
    pushSnapshot(src)
end)

CreateThread(function()
    CisRegisterCallback('cis_libs:inventoryCount', function(src, item)
        return InventoryCount(src, item)
    end)
end)

AddEventHandler('ox_inventory:openedInventory', function(src)
    pushSnapshot(src)
end)

exports('InventoryCount', InventoryCount)
exports('InventoryAdd', InventoryAdd)
exports('InventoryRemove', InventoryRemove)
exports('InventoryHas', InventoryHas)
