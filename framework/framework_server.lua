FrameworkLoaded = false
CisFramework = {}
local Framework = CisFramework
local provider = 'NONE'
local QBCore, ESX, QBX

local function waitResource(name, timeout)
    local deadline = GetGameTimer() + (timeout or 5000)
    while GetResourceState(name) ~= 'started' and GetGameTimer() < deadline do
        Wait(50)
    end
    return GetResourceState(name) == 'started'
end

local function detect()
    local configured = string.upper((Config and Config.Framework and Config.Framework.Type) or 'NONE')
    if configured == 'QBCORE' then
        if waitResource('qb-core', 5000) then
            local ok, core = pcall(function()
                return exports['qb-core']:GetCoreObject()
            end)
            if ok and core then
                QBCore = core
                provider = 'QBCORE'
                return
            end
            print('cis_libs: qb-core started but GetCoreObject failed')
        end
    elseif configured == 'QBOX' then
        if waitResource('qbx_core', 5000) then
            -- qbx_core REMOVED GetCoreObject in 1.9 and exposes player lookups
            -- directly as exports -- which is exactly what Framework.GetPlayer
            -- already calls. Detecting on GetCoreObject therefore fails on
            -- every current qbx_core, and the library fell straight through to
            -- standalone mode on precisely the server it was configured for.
            -- Nothing errored; `Cis.framework.player(src)` just quietly began
            -- returning a table with no name and no job.
            --
            -- Probe GetCoreObject for an older qbx_core, then fall back to the
            -- export that modern qbx_core actually has. Calling a missing
            -- export raises; calling a present one with a bad id returns nil
            -- without raising, so the pcall is an honest existence test.
            local ok, core = pcall(function()
                return exports.qbx_core:GetCoreObject()
            end)
            if ok and core then
                QBX = core
                QBCore = core
                provider = 'QBOX'
                return
            end
            local hasGetPlayer = pcall(function()
                return exports.qbx_core:GetPlayer(0)
            end)
            if hasGetPlayer then
                provider = 'QBOX'
                return
            end
            print('cis_libs: qbx_core is started but exposes neither '
                .. 'GetCoreObject nor GetPlayer; treating it as unusable')
        end
        if waitResource('qb-core', 2000) then
            local ok, core = pcall(function()
                return exports['qb-core']:GetCoreObject()
            end)
            if ok then
                QBCore = core
                provider = 'QBCORE'
                return
            end
        end
    elseif configured == 'ESX' or configured == 'ESX-LEGACY' then
        if waitResource('es_extended', 5000) then
            local ok, obj = pcall(function()
                return exports['es_extended']:getSharedObject()
            end)
            if ok then
                ESX = obj
            end
            if not ESX then
                local deadline = GetGameTimer() + 3000
                while ESX == nil and GetGameTimer() < deadline do
                    TriggerEvent('esx:getSharedObject', function(shared)
                        ESX = shared
                    end)
                    Wait(50)
                end
            end
            if ESX then
                provider = configured
                return
            end
        end
    else
        provider = 'NONE'
        return
    end
    print('cis_libs: Framework provider unavailable; using standalone mode')
    provider = 'NONE'
    if Config and Config.Framework then
        Config.Framework.Type = 'NONE'
    end
end

function Framework.IsLoaded()
    return FrameworkLoaded
end

function Framework.GetPlayers()
    if provider == 'QBCORE' and QBCore and QBCore.Functions then
        return QBCore.Functions.GetPlayers()
    end
    if (provider == 'ESX' or provider == 'ESX-LEGACY') and ESX then
        return ESX.GetPlayers()
    end
    return GetPlayers()
end

function Framework.GetPlayer(serverId)
    if provider == 'QBOX' and GetResourceState('qbx_core') == 'started' then
        local ok, player = pcall(function()
            return exports.qbx_core:GetPlayer(serverId)
        end)
        if ok and player then
            return player
        end
    end
    if (provider == 'QBCORE' or provider == 'QBOX') and QBCore and QBCore.Functions then
        return QBCore.Functions.GetPlayer(serverId)
    end
    if (provider == 'ESX' or provider == 'ESX-LEGACY') and ESX then
        return ESX.GetPlayerFromId(serverId)
    end
    return nil
end

function Framework.GiveItem(serverId, item, amount)
    return InventoryAdd(serverId, item, amount)
end

function Framework.RemoveItem(source, item, amount)
    return InventoryRemove(source, item, amount)
end

function Framework.HasItem(source, item)
    return InventoryHas(source, item, 1)
end

function Framework.GiveMoney(serverId, amount, moneyType)
    local player = Framework.GetPlayer(serverId)
    if not player then
        return false
    end
    moneyType = moneyType or 'cash'
    if provider == 'QBCORE' or provider == 'QBOX' then
        if moneyType == 'markedbills' then
            return InventoryAdd(serverId, 'markedbills', 1, { worth = amount })
        end
        if player.Functions and player.Functions.AddMoney then
            -- AddMoney reports false on a rejected transaction; do not paper over it.
            return player.Functions.AddMoney(moneyType, amount) and true or false
        end
        if GetResourceState('qbx_core') == 'started' then
            local ok, result = pcall(function()
                return exports.qbx_core:AddMoney(serverId, moneyType, amount, 'cis_libs')
            end)
            return ok and result and true or false
        end
    elseif provider == 'ESX' or provider == 'ESX-LEGACY' then
        if moneyType == 'markedbills' then
            return InventoryAdd(serverId, 'markedbills', 1, { worth = amount })
        end
        local ok = pcall(function()
            return player.addAccountMoney(moneyType, amount)
        end)
        return ok
    end
    return false
end

function Framework.RemoveMoney(serverId, amount, moneyType)
    local player = Framework.GetPlayer(serverId)
    if not player then
        return false
    end
    moneyType = moneyType or 'cash'
    if provider == 'QBCORE' or provider == 'QBOX' then
        if moneyType == 'markedbills' then
            return InventoryRemove(serverId, 'markedbills', 1)
        end
        if player.Functions and player.Functions.RemoveMoney then
            return player.Functions.RemoveMoney(moneyType, amount) and true or false
        end
        if GetResourceState('qbx_core') == 'started' then
            local ok, result = pcall(function()
                return exports.qbx_core:RemoveMoney(serverId, moneyType, amount, 'cis_libs')
            end)
            return ok and result and true or false
        end
    elseif provider == 'ESX' or provider == 'ESX-LEGACY' then
        if moneyType == 'markedbills' then
            return InventoryRemove(serverId, 'markedbills', 1)
        end
        local ok = pcall(function()
            return player.removeAccountMoney(moneyType, amount)
        end)
        return ok
    end
    return false
end

function Framework.GetPlayerIdentifier(serverId)
    local player = Framework.GetPlayer(serverId)
    if not player then
        return nil
    end
    if provider == 'QBCORE' or provider == 'QBOX' then
        return player.PlayerData and player.PlayerData.citizenid
    end
    if provider == 'ESX' or provider == 'ESX-LEGACY' then
        return player.identifier
    end
    return nil
end

function Framework.GetPlayerJob(serverId)
    local player = Framework.GetPlayer(serverId)
    if not player then
        return nil
    end
    if provider == 'QBCORE' or provider == 'QBOX' then
        return player.PlayerData and player.PlayerData.job
    end
    if provider == 'ESX' or provider == 'ESX-LEGACY' then
        return player.job
    end
    return nil
end

function Framework.SetPlayerJob(serverId, job, grade)
    local player = Framework.GetPlayer(serverId)
    if not player then
        return
    end
    if provider == 'QBCORE' or provider == 'QBOX' then
        if player.Functions and player.Functions.SetJob then
            player.Functions.SetJob(job, grade)
        elseif GetResourceState('qbx_core') == 'started' then
            pcall(function()
                exports.qbx_core:SetJob(serverId, job, grade)
            end)
        end
    elseif provider == 'ESX' or provider == 'ESX-LEGACY' then
        player.setJob(job, grade)
    end
    CisRememberJob(serverId, { name = job, grade = grade })
    TriggerClientEvent('cis_libs:jobUpdated', serverId, { name = job, grade = grade })
end

function Framework.HasPermission(serverId, permission)
    local player = Framework.GetPlayer(serverId)
    if not player then
        return false
    end
    if provider == 'QBCORE' or provider == 'QBOX' then
        if QBCore and QBCore.Functions and QBCore.Functions.HasPermission then
            return QBCore.Functions.HasPermission(serverId, permission)
        end
        if GetResourceState('qbx_core') == 'started' then
            local ok, result = pcall(function()
                return exports.qbx_core:HasPermission(serverId, permission)
            end)
            return ok and result or false
        end
    elseif provider == 'ESX' or provider == 'ESX-LEGACY' then
        return player.getGroup and player.getGroup() == permission
    end
    return false
end

function Framework.GetOnlineJobCount(jobs)
    return CisJobCount(jobs)
end

function Framework.CreateCallback(name, cb)
    CisRegisterCallback(name, function(src, ...)
        local result
        cb(src, function(...)
            result = table.pack(...)
        end, ...)
        if result then
            return table.unpack(result, 1, result.n)
        end
    end)
end

function Framework.Notify(src, message, kind)
    TriggerClientEvent('cis_libs:client:showNotification', src, message, kind)
end

local function esxAccounts(player)
    if not player or type(player.getAccounts) ~= 'function' then
        return nil
    end
    local ok, accounts = pcall(function()
        return player.getAccounts()
    end)
    if not ok or type(accounts) ~= 'table' then
        return nil
    end
    local out = {}
    for i = 1, #accounts do
        local account = accounts[i]
        if account and account.name then
            out[account.name] = account.money
        end
    end
    return out
end

function Framework.NormalizedPlayer(src)
    local player = Framework.GetPlayer(src)
    local job = Framework.GetPlayerJob(src)
    local name, money, metadata
    if player then
        if player.PlayerData and player.PlayerData.charinfo then
            local info = player.PlayerData.charinfo
            name = ((info.firstname or '') .. ' ' .. (info.lastname or '')):gsub('^%s+', ''):gsub('%s+$', '')
        elseif type(player.getName) == 'function' then
            local ok, value = pcall(function()
                return player.getName()
            end)
            name = ok and value or nil
        end
        if player.PlayerData then
            money = player.PlayerData.money
            metadata = player.PlayerData.metadata
        else
            -- ESX keeps money in accounts and metadata on the xPlayer itself.
            money = esxAccounts(player)
            local ok, value = pcall(function()
                return player.get('metadata')
            end)
            if ok then
                metadata = value
            end
        end
    end
    return {
        id = src,
        name = name,
        job = job,
        identifier = Framework.GetPlayerIdentifier(src),
        money = money,
        metadata = metadata,
    }
end

exports('GetFramework', function()
    if not CisReadyState.wait(15000) then
        return Framework
    end
    local deadline = GetGameTimer() + 15000
    while not FrameworkLoaded and GetGameTimer() < deadline do
        Wait(50)
    end
    return Framework
end)

exports('GetNormalizedPlayer', function(src)
    return Framework.NormalizedPlayer(src)
end)

exports('Notify', function(src, message, kind)
    Framework.Notify(src, message, kind)
end)

CreateThread(function()
    detect()
    FrameworkLoaded = true
    CisReadyState.markReady()
    CisRegisterCallback('cis_libs:getOnlineJobCount', function(_, jobs)
        return Framework.GetOnlineJobCount(jobs)
    end)
    for _, id in ipairs(GetPlayers()) do
        local src = tonumber(id)
        if src then
            CisRememberJob(src, Framework.GetPlayerJob(src))
        end
    end
end)

AddEventHandler('QBCore:Server:PlayerLoaded', function(player)
    local src = player and (player.PlayerData and player.PlayerData.source or player.source)
    if src then
        CisRememberJob(src, Framework.GetPlayerJob(src))
        TriggerClientEvent('cis_libs:client:inventory', src, InventorySnapshot(src))
    end
end)

AddEventHandler('esx:playerLoaded', function(src)
    CisRememberJob(src, Framework.GetPlayerJob(src))
    TriggerClientEvent('cis_libs:client:inventory', src, InventorySnapshot(src))
end)

AddEventHandler('QBCore:Server:OnJobUpdate', function(src, job)
    CisRememberJob(src, job)
end)

AddEventHandler('esx:setJob', function(src, job)
    CisRememberJob(src, job)
end)
