FrameworkLoaded = false
Framework = {}
local PlayerJob = nil
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
            local ok, core = pcall(function()
                return exports.qbx_core:GetCoreObject()
            end)
            if ok and core then
                QBX = core
                QBCore = core
                provider = 'QBOX'
                return
            end
            print('cis_libs: qbx_core started but GetCoreObject failed')
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
            if configured == 'ESX-LEGACY' then
                local ok, obj = pcall(function()
                    return exports['es_extended']:getSharedObject()
                end)
                if ok then
                    ESX = obj
                end
            end
            if not ESX then
                local deadline = GetGameTimer() + 3000
                while ESX == nil and GetGameTimer() < deadline do
                    TriggerEvent('esx:getSharedObject', function(obj)
                        ESX = obj
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

function Framework.GetPlayerData()
    if provider == 'QBCORE' or provider == 'QBOX' then
        if provider == 'QBOX' and QBX and QBX.GetPlayerData then
            return QBX.GetPlayerData()
        end
        if QBCore and QBCore.Functions then
            return QBCore.Functions.GetPlayerData()
        end
    elseif provider == 'ESX' or provider == 'ESX-LEGACY' then
        return ESX.GetPlayerData()
    end
    return nil
end

function Framework.UpdatePlayerJob(job)
    PlayerJob = job
    TriggerEvent('cis_libs:jobUpdated', job)
end

function Framework.OnPlayerLoaded()
    local playerData = Framework.GetPlayerData()
    if playerData and playerData.job then
        PlayerJob = playerData.job
        TriggerEvent('cis_libs:playerLoaded', PlayerJob)
    end
end

function Framework.GetPlayerJob()
    return PlayerJob
end

function CisFrameworkNotify(message, kind)
    if provider == 'QBCORE' or provider == 'QBOX' then
        if QBCore and QBCore.Functions and QBCore.Functions.Notify then
            QBCore.Functions.Notify(message, kind)
            return
        end
        if GetResourceState('qbx_core') == 'started' then
            pcall(function()
                exports.qbx_core:Notify(message, kind or 'inform')
            end)
            return
        end
    elseif provider == 'ESX' or provider == 'ESX-LEGACY' then
        ESX.ShowNotification(message)
        return
    end
    BeginTextCommandThefeedPost('STRING')
    AddTextComponentSubstringPlayerName(tostring(message))
    EndTextCommandThefeedPostTicker(false, false)
end

function Framework.ShowNotification(message, kind)
    CisFrameworkNotify(message, kind)
end

function Framework.TriggerServerCallback(name, cb, ...)
    exports['cis_libs']:TriggerLibCallback(name, cb, ...)
end

function Framework.HasItem(item, amount)
    return InventoryHas(item, amount or 1)
end

function Framework.CreateVehicle(model, coords, heading, cb)
    local function finish(vehicle)
        if vehicle and vehicle ~= 0 then
            SetEntityHeading(vehicle, heading or 0.0)
            SetVehicleOnGroundProperly(vehicle)
        end
        if cb then
            cb(vehicle)
        end
    end
    if provider == 'QBCORE' and QBCore and QBCore.Functions and QBCore.Functions.SpawnVehicle then
        QBCore.Functions.SpawnVehicle(model, finish, coords, true)
        return
    end
    if (provider == 'ESX' or provider == 'ESX-LEGACY') and ESX and ESX.Game and ESX.Game.SpawnVehicle then
        ESX.Game.SpawnVehicle(model, coords, heading, finish)
        return
    end
    CreateThread(function()
        local loaded, hash = RequestModelTimeout(model, 5000)
        if not loaded then
            finish(0)
            return
        end
        local vehicle = CreateVehicle(hash, coords.x, coords.y, coords.z, heading or 0.0, true, false)
        SetModelAsNoLongerNeeded(hash)
        finish(vehicle)
    end)
end

function Framework.GetOnlineJobCount(jobs, cb)
    exports['cis_libs']:TriggerLibCallback('cis_libs:getOnlineJobCount', cb, jobs)
end

exports('Notify', function(message, kind)
    CisFrameworkNotify(message, kind)
end)

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

CreateThread(function()
    if not CisReadyState.wait(15000) then
        FrameworkLoaded = true
        return
    end
    detect()
    FrameworkLoaded = true
    local playerData = Framework.GetPlayerData()
    if playerData and playerData.job then
        PlayerJob = playerData.job
    end
    if provider == 'QBCORE' or provider == 'QBOX' then
        RegisterNetEvent('QBCore:Client:OnJobUpdate', Framework.UpdatePlayerJob)
        RegisterNetEvent('QBCore:Client:OnPlayerLoaded', Framework.OnPlayerLoaded)
        RegisterNetEvent('qbx_core:client:playerLoaded', Framework.OnPlayerLoaded)
        RegisterNetEvent('qbx_core:client:onJobUpdate', Framework.UpdatePlayerJob)
    elseif provider == 'ESX' or provider == 'ESX-LEGACY' then
        RegisterNetEvent('esx:setJob', Framework.UpdatePlayerJob)
        RegisterNetEvent('esx:playerLoaded', Framework.OnPlayerLoaded)
    end
end)
