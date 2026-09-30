-- Client inventory counts, as a cache.
--
-- Three sources write the same table and they disagree in shape, so this file
-- normalises to a flat name -> amount map and nothing downstream knows or cares
-- which provider is running. The map is a HINT: it is a snapshot, it can be
-- stale between updates, and it is never authority for a server-side decision.
--
-- One `counts` table, so this file is stateful and must not be duplicated
-- (COMPATIBILITY.md §10).

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

-- ox_inventory exports two different shapes depending on the build, so both are
-- tried before giving up. Failing either one is not an error: a server that has
-- ox_inventory running with a different permission set just leaves the pushed
-- snapshot as the answer.
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

-- 0, never nil. A consumer comparing against nil decides a player has no
-- items; one comparing against 0 decides the same thing, and only the second
-- is the truth.
function InventoryCount(item)
    return counts[item] or 0
end

function InventoryHas(item, amount)
    return InventoryCount(item) >= (amount or 1)
end

exports('InventoryCount', InventoryCount)
exports('InventoryHas', InventoryHas)
