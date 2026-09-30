-- Server-side framework bridge. One normalised surface over ESX, QBCore and
-- QBOX, and a standalone mode when none of them load.
--
-- Two things here are load-bearing and easy to break:
--
--   1. detection PROBES exports rather than trusting Config.Framework.Type,
--      because the name an operator configures is not a promise about what the
--      resource exposes -- see the QBOX branch;
--   2. every money and item operation goes back out to the framework rather
--      than editing PlayerData directly, so whatever the framework does for
--      validation, replication and side effects still happens.

FrameworkLoaded = false
CisFramework = {}
local Framework = CisFramework
local provider = 'NONE'
local QBCore, ESX, QBX

-- 50ms poll, 5s default ceiling. This is a boot-path wait for another RESOURCE
-- to start, not a hot loop: it runs at most a handful of times per server
-- start, and what it is waiting on resolves in seconds. 50ms is well under any
-- perceptible difference in when a consumer gets its framework, and it keeps
-- the resource-start path responsive instead of parking on a coarse timer. A
-- tighter poll would only burn scheduler time waiting for a resource whose
-- start time this library does not control.
local function waitResource(name, timeout)
    local deadline = GetGameTimer() + (timeout or 5000)
    while GetResourceState(name) ~= 'started' and GetGameTimer() < deadline do
        Wait(50)
    end
    return GetResourceState(name) == 'started'
end

-- What the last detect() concluded, for cis_debug and the boot report.
-- Recorded rather than recomputed: a diagnosis that runs different code from
-- the thing it diagnoses is not a diagnosis.
Framework.detected = nil

-- A resolved custom adapter, when one is configured. Comes from
-- Config.Framework.Custom, or from a global `CisCustomFramework` a consumer can
-- define before cis_libs starts -- the escape hatch for a framework this
-- library has never heard of.
local customAdapter = nil

local function loadCustomAdapter()
    local global = rawget(_G, 'CisCustomFramework')
    if type(global) == 'table' then
        return {
            resource = global.resource or 'CisCustomFramework',
            name = global.name or 'CUSTOM',
            getPlayer = type(global.getPlayer) == 'string' and global.getPlayer or 'GetPlayer',
            getPlayerFn = type(global.getPlayer) == 'function' and global.getPlayer or nil,
        }
    end
    local custom = Config and Config.Framework and Config.Framework.Custom
    if type(custom) == 'table' and type(custom.resource) == 'string' and custom.resource ~= '' then
        return {
            resource = custom.resource,
            name = custom.name or 'CUSTOM',
            getPlayer = custom.getPlayer or custom.probe,
        }
    end
    return nil
end

-- Existence probe for an export. Calling a missing export raises; calling a
-- present one with a deliberately bad argument does not, so the pcall result
-- is an honest answer rather than a guess.
-- Existence probe for an export: does the resource publish this name?
--
-- It RESOLVES the reference rather than calling it. Calling to test is wrong:
-- `qbx_core:GetPlayer(0)` raises on an invalid source, and a raise inside a
-- pcall is indistinguishable from "the export does not exist" -- so a perfectly
-- good server was reported as having no framework at all. Measured, not
-- assumed: that is exactly what the first AUTO run on a live qbx_core did.
--
-- A returned function arrives as a callable reference table, so `type() ==
-- 'function'` is the wrong test and rejects an export that IS present. Both
-- shapes count; nil means the name is not published.
local function probeExport(resource, exportName)
    if type(exportName) ~= 'string' or exportName == '' then
        return true
    end
    local ok, fn = pcall(function()
        return exports[resource][exportName]
    end)
    if not ok or fn == nil then
        return false
    end
    if type(fn) == 'function' then
        return true
    end
    return type(fn) == 'table' and rawget(fn, '__cfx_functionReference') ~= nil
end

local function detect()
    local configured = string.upper((Config and Config.Framework and Config.Framework.Type) or 'AUTO')
    customAdapter = loadCustomAdapter()

    -- AUTO and CUSTOM both mean "ask the server". The pure module decides, so
    -- the ordering that distinguishes qbx_core from qb-core is unit tested
    -- rather than trusted.
    if configured == 'AUTO' or customAdapter then
        local choice = CisDetect.framework(
            configured,
            customAdapter and {
                resource = customAdapter.resource,
                name = customAdapter.name,
                getPlayer = customAdapter.getPlayer,
            } or nil,
            function(name) return GetResourceState(name) == 'started' end,
            function(name) return GetResourceMetadata(name, 'version') end,
            probeExport
        )
        Framework.detected = choice
        provider = choice.name

        if choice.name == 'NONE' then
            print(('cis_libs: no framework available (%s). Running standalone: player '
                .. 'lookups will return a table with no name and no job.')
                :format(choice.reason))
            if Config and Config.Framework then
                Config.Framework.Type = 'NONE'
            end
            return
        end

        -- Give the resource a moment to finish publishing its exports. A
        -- started resource is usually ready, and "usually" is the whole
        -- difference between working and silently degrading.
        if not waitResource(choice.resource, 5000) then
            print(('cis_libs: %s reported as %s but did not finish starting')
                :format(choice.resource, choice.name))
            provider = 'NONE'
            if Config and Config.Framework then
                Config.Framework.Type = 'NONE'
            end
            return
        end

        if choice.name == 'QBCORE' then
            local ok, core = pcall(function() return exports['qb-core']:GetCoreObject() end)
            if ok and core then
                QBCore = core
            end
        elseif choice.name == 'QBOX' then
            -- qbx_core removed GetCoreObject in 1.9 and exposes the lookups
            -- directly; an older one still has it, and taking the core object
            -- when it exists keeps the money helpers working.
            local ok, core = pcall(function() return exports.qbx_core:GetCoreObject() end)
            if ok and core then
                QBX = core
                QBCore = core
            end
        elseif choice.name == 'ESX' or choice.name == 'ESX-LEGACY' then
            local ok, obj = pcall(function() return exports['es_extended']:getSharedObject() end)
            if ok then
                ESX = obj
            end
            if not ESX then
                local deadline = GetGameTimer() + 3000
                while ESX == nil and GetGameTimer() < deadline do
                    TriggerEvent('esx:getSharedObject', function(shared) ESX = shared end)
                    Wait(50)
                end
            end
        end

        print(('cis_libs: framework %s (%s%s) -- %s'):format(choice.name, choice.resource,
            choice.version and (' ' .. tostring(choice.version)) or '', choice.reason))

        if Config and Config.Framework and configured == 'AUTO' then
            -- Config is REWRITTEN to what was actually detected, so every
            -- consumer that reads Config.Framework.Type -- including the
            -- client, which receives it in the config payload -- agrees with
            -- reality rather than with what someone guessed.
            Config.Framework.Type = choice.name
        end
        return
    end

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
            -- GetPlayer(0) is safe for that purpose precisely because a bad id
            -- is a nil return and not an error -- server id 0 is the console
            -- and is never a real player, so nothing is looked up and nothing
            -- is decided on the value.
            --
            -- Note the second probe sets NO core object. That is intentional:
            -- a modern qbx_core has nothing to capture, and Framework.GetPlayer
            -- reaches the export directly on its first branch for provider
            -- 'QBOX'. Do not "fix" this by assigning a placeholder -- every
            -- other `QBCore.Functions` check in this file tests for a table and
            -- would take a different path.
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
        -- Configured for QBOX but running qb-core. A short 2s wait, not 5s:
        -- this is the unexpected branch, and a server that really runs QBOX has
        -- already answered above. Provider is reported as QBCORE, not QBOX,
        -- because that is what is actually loaded and a consumer branching on
        -- it will call the right thing.
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
            -- The modern path. ESX may not have published the export yet even
            -- though the resource reports started, so `ok` alone is not enough:
            -- a nil object has to fall through to the event below.
            local ok, obj = pcall(function()
                return exports['es_extended']:getSharedObject()
            end)
            if ok then
                ESX = obj
            end
            if not ESX then
                -- The legacy path: older ESX has no export and only answers a
                -- request event, which has to be triggered and then waited on.
                -- 3s, 50ms apart -- the object is created during es_extended's
                -- own start, so this either succeeds in the first few rounds
                -- or never will.
                local deadline = GetGameTimer() + 3000
                while ESX == nil and GetGameTimer() < deadline do
                    TriggerEvent('esx:getSharedObject', function(shared)
                        ESX = shared
                    end)
                    Wait(50)
                end
            end
            if ESX then
                -- The CONFIGURED name is preserved rather than normalised to
                -- 'ESX', because Config.Framework.Type is what a consumer reads
                -- to decide how to talk to the framework.
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
    -- Config is REWRITTEN, not just reported. A server that is silently
    -- running standalone is the single most damaging outcome here -- every
    -- player lookup returns a table with no name and no job, and nothing
    -- errors -- so the config is corrected to match reality and
    -- GetConfigSummary in server/initialize.lua then reports 'NONE' instead of
    -- a framework this server is not running.
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

-- The hottest call in this file: a dispatch, a gate, a money operation all
-- start here. nil for "no such player" -- a disconnected or not-yet-loaded src
-- is normal traffic, not an error, and the callers below all treat it as a
-- plain false.
function Framework.GetPlayer(serverId)
    -- A custom adapter is tried FIRST and unconditionally. The operator
    -- configured it precisely because the branches below would not recognise
    -- their framework, so trying the known ones first is the wrong order.
    --
    -- `getPlayer` may be a function on the adapter table, or the NAME of an
    -- export on the adapter's resource. The table form wins when both are
    -- given, because it is the more explicit of the two.
    if customAdapter then
        local got = nil
        local fn = customAdapter.getPlayerFn
        if type(fn) == 'function' then
            local ok, player = pcall(fn, serverId)
            if ok then
                got = player
            end
        elseif type(customAdapter.getPlayer) == 'string' then
            local res = customAdapter.resource
            local ok, player = pcall(function()
                return exports[res][customAdapter.getPlayer](exports[res], serverId)
            end)
            -- The exports table is passed EXPLICITLY: `exports[res][name]` is an
            -- unbound method and would eat serverId as `self`, so the handler
            -- would run with a number where the player should be. The same
            -- trap the callback dispatcher documents.
            if ok then
                got = player
            end
        end
        if got then
            return got
        end
    end

    -- QBOX first, and unconditionally of whether detection found a core
    -- object. On a current qbx_core the export IS the interface, and the
    -- QBCore.Functions branch below has nothing to offer -- so this has to be
    -- tried before it, not only when a core object was captured. A nil here is
    -- ambiguous (no such player, or an id type the export rejects) and both
    -- mean the same thing to a caller, so the fallthrough is correct.
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

-- Items go to server/inventory.lua rather than to the framework's own item
-- API, so that a server running an external inventory (ox_inventory, qb-
-- inventory) is not silently bypassed by a framework bridge call.
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
        -- 'markedbills' is an ITEM on every framework this supports, not an
        -- account, so it is routed to the inventory with the value carried as
        -- metadata. Handing it to AddMoney instead would create an account
        -- named markedbills that no shop and no ATM knows how to spend.
        if moneyType == 'markedbills' then
            return InventoryAdd(serverId, 'markedbills', 1, { worth = amount })
        end
        -- Three attempts, in order of preference: the object method when a core
        -- object was captured, then the qbx_core export. The last branch is
        -- what a current qbx_core uses, and it is reached only when the player
        -- object has no Functions table -- which is exactly the shape modern
        -- qbx_core returns. `ok and result and true or false` collapses "raised",
        -- "returned nil" and "returned false" into one honest answer.
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
        -- pcall, not a return-value check: ESX's addAccountMoney returns nothing
        -- and raises on an unknown account, so `ok` is the only success signal
        -- available.
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
    -- The local mirror is updated UNCONDITIONALLY, after whichever framework
    -- call succeeded or not. It is what an online-job-count is answered from,
    -- and a job change the framework accepted but the mirror missed would
    -- leave a cop counted as a civilian until they next changed job. Same
    -- reasoning for the client event: the player's UI must not depend on the
    -- framework's own job event arriving in the right shape.
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

-- Every permission check in the library funnels here, and the QBCore and qbx
-- branches answer with an explicit boolean rather than nil: a nil would read
-- as "no" in one caller and raise in another. Note the ESX branch below does
-- NOT normalise -- an xPlayer with no getGroup returns nil, not false. Both
-- callers treat it as falsy, so it works, but it is the one answer from this
-- function that is not a real boolean.
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

-- ESX-style callback shape (cb, ...) wrapped into a cis_libs callback, so a
-- consumer written against ESX can keep its `function(src, cb, ...) cb(x) end`
-- and get the library's dispatch, rate limiting and timeout for free.
--
-- The adapter is SYNCHRONOUS, and that is a real constraint: it calls cb, then
-- returns whatever cb captured. A handler that calls its callback later -- from
-- an await, a timer, or a database round trip -- returns nothing here, and the
-- client gets a timeout instead of the value. That is inherent to a server-side
-- dispatch that has already answered; the fix for such a handler is to register
-- it as "resource:export" so the await happens on the client.
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

-- One player, one shape, whichever framework is underneath. `money` is
-- deliberately not normalised further than "a table keyed by account name":
-- the SQL frameworks hand back a money table and ESX hands back an account
-- list, and collapsing them to a common currency would mean picking one of
-- them and losing information the other carries. A consumer that needs a
-- number asks for the account it wants.
--
-- The name is a JOIN, not the player name. A player with no charinfo and no
-- getName (a framework that stores neither) gets nil rather than an empty
-- string, so a consumer can tell "no name" from "the name is blank".
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

-- The one a consumer uses to get at the bridge. Blocks rather than returning a
-- half-initialised table, because every function on Framework depends on
-- `provider` being decided and a call made before detect() finishes would read
-- it as 'NONE'.
--
-- The second wait is belt and braces and is not additive with the first: the
-- thread at the bottom sets FrameworkLoaded and THEN calls markReady, so
-- CisReadyState.wait returning true already implies FrameworkLoaded is true and
-- the loop exits on its first test. The ceiling is therefore 15s, not 30s.
-- The first wait returning false returns early rather than proceeding, because
-- a failed ready state means the library gave up and there is nothing to wait
-- for.
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

-- Startup, in this order, and the order is the contract:
--
--   detect()   -- decides `provider`; every Framework function reads it
--   loaded     -- GetFramework's belt-and-braces loop watches this
--   markReady  -- the signal consumers actually wait on
--   register   -- the callback is claimed only now
--   backfill   -- everyone already online is recorded in the job histogram
--
-- Backfill is last and is why the histogram is correct on a resource restart:
-- the framework's PlayerLoaded events have already fired for every connected
-- player by the time this thread runs, so without this walk the job store
-- starts empty and an online-police count reads zero until each player
-- reconnects.
--
-- Known ordering wart, left as-is: markReady() runs BEFORE the callback is
-- registered, so a consumer that wakes on ready and fires
-- `cis_libs:getOnlineJobCount` in the same tick gets 'unknown' rather than a
-- count. The window is a single scheduler slot and closing it means moving
-- markReady after the registration, which would change when every other
-- consumer unblocks.
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

-- The four events below are the frameworks' own notifications, and they are
-- what keeps the job histogram live after startup. Two per framework because
-- the two ecosystems are not interchangeable and a server runs exactly one:
-- qbx_core still fires the QBCore events for compatibility, and a listener
-- for the qbx_core-specific ones alone would miss players on a QBCore build.
-- The src extraction below covers both event payload shapes (QBCore passes a
-- player object, ESX passes a number), because the two cannot be told apart by
-- the event alone.
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
