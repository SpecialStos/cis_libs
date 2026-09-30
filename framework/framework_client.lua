-- Client-side framework bridge. The mirror of framework_server.lua, but NOT a
-- copy of its detection, and the difference is load-bearing.
--
-- The server half probes `GetCoreObject` and, when it is missing, falls back to
-- probing `GetPlayer` -- because it holds a server id it can look up. This file
-- has no such fallback, and the consequence is worth stating plainly:
--
--   On a qbx_core that has removed GetCoreObject, this file's detect() prints
--   "qbx_core started but GetCoreObject failed", falls through to the qb-core
--   branch, and then to standalone mode. provider becomes 'NONE',
--   Config.Framework.Type is rewritten to 'NONE', and the QBOX block at the
--   bottom of this file never runs -- so no qbx_core client event is ever
--   listened for, and `cis_libs:jobUpdated` / `cis_libs:playerLoaded` do not
--   fire on the client.
--
-- The server half has the fallback and does not have this problem, so the two
-- halves disagree on exactly the server where qbx_core was configured. Nothing
-- errors; notifications fall back to the native feed and job tracking simply
-- never starts. There is no test over this file, so nothing catches it.
--
-- It is documented rather than changed because this pass is comments only.

FrameworkLoaded = false
Framework = {}
local PlayerJob = nil
local provider = 'NONE'
local QBCore, ESX, QBX

-- Same 50ms/5s shape as the server half, for the same reason: a boot-path wait
-- for another resource, where the only question is "has it started yet".
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
            -- qbx_core REMOVED GetCoreObject in 1.9. Probing only for it made
            -- this branch fail on every current qbx_core, which dropped the
            -- library to standalone mode -- and standalone means the QBOX event
            -- registrations at the bottom of this file never happen, so
            -- `cis_libs:jobUpdated` and `cis_libs:playerLoaded` never fire on
            -- the client. The server half already carries the fallback; this
            -- one had been left behind.
            local ok, core = pcall(function()
                return exports.qbx_core:GetCoreObject()
            end)
            if ok and core then
                QBX = core
                QBCore = core
                provider = 'QBOX'
                return
            end
            -- Fall back to the export a current qbx_core actually has.
            -- Calling a missing export raises; calling a present one with a bad
            -- id returns nil, so the pcall is an honest existence test.
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
        -- Configured for QBOX, running qb-core. Short 2s wait because the
        -- qbx_core branch above has already had its chance.
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
            -- Current ESX: ask for the export. Legacy ESX: it has no export, so
            -- it is not asked at all and the event below is the only route.
            -- Splitting on the CONFIGURED name rather than probing is what
            -- keeps a current build from waiting 3s for an event it would
            -- answer immediately.
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

-- nil when the framework has not published data yet, which on a fresh connect
-- is normal rather than exceptional. Every caller above checks before using it.
function Framework.GetPlayerData()
    if provider == 'QBCORE' or provider == 'QBOX' then
        -- The QBX path only fires on a qbx_core that still published a core
        -- object with GetPlayerData on it. Note the consequence: when QBX is
        -- nil this falls through to the QBCore branch, which also has nothing,
        -- so the result is nil -- and OnPlayerLoaded below bails on exactly
        -- that, so `cis_libs:playerLoaded` does not fire either. Read together
        -- with the header, that is the whole of the qbx_core problem.
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

-- The framework's job-change event, republishable on the library's own name so
-- a consumer listens to one event rather than to a per-framework list. The
-- local copy is the client's answer to GetPlayerJob: the framework is not
-- asked on demand, because its data is only valid while a character is loaded.
function Framework.UpdatePlayerJob(job)
    PlayerJob = job
    TriggerEvent('cis_libs:jobUpdated', job)
end

-- Fires the library's own playerLoaded. Gated on a job being present, so a
-- framework event that arrives before the character is ready is ignored rather
-- than republished as "loaded with no job".
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

-- The framework's own notification, and the native feed as the last resort.
-- The native fallback is not dead code: it is what a server in standalone mode
-- gets, and it is why notifications work at all on a server where detection
-- failed. The QBOX branch reaches the qbx_core export when no core object was
-- captured, which is the current-build case.
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

-- Callback style, not the library's await style, because this is the shape a
-- framework consumer already writes. The timeout and the rate limit come free
-- from server/callback.lua; this only exists to name the shape.
function Framework.TriggerServerCallback(name, cb, ...)
    exports['cis_libs']:TriggerLibCallback(name, cb, ...)
end

-- Client-side count, which is the CLIENT's view of its own inventory. The
-- server keeps its own count for authority; this is a display concern and the
-- two are allowed to disagree briefly.
function Framework.HasItem(item, amount)
    return InventoryHas(item, amount or 1)
end

-- Three paths, and the order is a preference order: the framework's own spawn
-- when it has one (it handles plate, state bags and ownership), then the
-- library's. The native path runs in a thread because RequestModelTimeout
-- yields, and a spawn that cannot load its model reports 0 rather than
-- skipping the callback -- a caller waiting on a vehicle handle has to be
-- woken either way.
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
        -- 5s to load a model. Longer than the native default because a cold
        -- stream on a busy server is the case this path exists for, and a
        -- caller that gets 0 has to handle a missing vehicle.
        local loaded, hash = RequestModelTimeout(model, 5000)
        if not loaded then
            finish(0)
            return
        end
        local vehicle = CreateVehicle(hash, coords.x, coords.y, coords.z, heading or 0.0, true, false)
        -- Released immediately after the spawn. Holding it would keep the model
        -- resident for the life of the session, and nothing here needs it again.
        SetModelAsNoLongerNeeded(hash)
        finish(vehicle)
    end)
end

-- A server round trip, not a local count. The client's own inventory does not
-- know who else is online, and a dispatch balance must not be decided by what
-- one player can see.
function Framework.GetOnlineJobCount(jobs, cb)
    exports['cis_libs']:TriggerLibCallback('cis_libs:getOnlineJobCount', cb, jobs)
end

exports('Notify', function(message, kind)
    CisFrameworkNotify(message, kind)
end)

-- Same shape as the server export, and the same belt-and-braces second wait:
-- the thread above sets FrameworkLoaded before it registers the listeners, so
-- a successful ready wait already implies the flag is set and the loop exits
-- immediately. 15s total, not 30s.
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

-- Client startup, and the order is the contract.
--
-- The ready gate is checked FIRST, unlike the server half. A client that
-- failed readiness must not go on to probe for a framework and register
-- listeners: the library has already told the player it is not working, and a
-- half-attached bridge on top of that produces errors the player cannot
-- explain. The early return still sets FrameworkLoaded so GetFramework stops
-- waiting on a thread that has already given up.
CreateThread(function()
    if not CisReadyState.wait(15000) then
        FrameworkLoaded = true
        return
    end
    detect()
    FrameworkLoaded = true
    -- Read the job once, immediately, so a consumer that asks before the
    -- framework's first event still gets an answer. The listeners below then
    -- keep it current.
    local playerData = Framework.GetPlayerData()
    if playerData and playerData.job then
        PlayerJob = playerData.job
    end
    -- BOTH ecosystems' events are registered for QBOX, not just the qbx_core
    -- pair. qbx_core still fires the QBCore events for compatibility, and a
    -- client that listened only for `qbx_core:client:*` would work on a current
    -- build and silently stop updating on a transitional one. Registering
    -- four listeners for one job is cheaper than the bug.
    --
    -- The whole block is unreachable on a qbx_core that removed GetCoreObject,
    -- because provider is 'NONE' by then. See the header.
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
