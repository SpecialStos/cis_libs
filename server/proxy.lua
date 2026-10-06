-- Capability forwards.

local warned = {}

-- Notification bounds, stated once so the numbers are findable from the export and not
local MAX_NOTIFY_LENGTH = 512
local NOTIFY_MAX_PER_SECOND = 10

-- THE ONE DELIVERY PATH. `Notify` with no framework behind it and `NotifyClient` are
local function deliverNotification(src, message, kind)
    if type(src) ~= 'number' or src <= 0 then
        return false, ('src must be a connected player id, got %s'):format(tostring(src))
    end
    if not GetPlayerName(src) then
        return false, ('src %d is not connected'):format(src)
    end
    if type(message) == 'string' and #message > MAX_NOTIFY_LENGTH then
        message = message:sub(1, MAX_NOTIFY_LENGTH)
    end
    local caller = GetInvokingResource() or 'cis_libs'
    if not CisRateOk(src, 'notify:' .. tostring(caller), 1000, NOTIFY_MAX_PER_SECOND) then
        return false, 'notification rate limit'
    end
    TriggerClientEvent('cis_libs:client:showNotification', src, message, kind)
    return true
end

-- A2 · THE AUDIT LINE.
local function notAuthorizedReason(exportName)
    local caller = GetInvokingResource() or 'cis_libs'
    return ("cis_libs refused %s from %s: add '%s' to Security.AuthorizedResources")
        :format(tostring(exportName), tostring(caller), tostring(caller))
end
-- IN MEMORY, IN A BOUNDED RING, AND NOWHERE ELSE .
local AUDIT_DEFAULT_LINES = 500
local auditRing = {}
local auditNext = 1
local auditHeld = 0

local function auditCapacity()
    local configured = Config and Config.AuditLines
    local n = tonumber(configured)
    if not n or n < 1 then
        return AUDIT_DEFAULT_LINES
    end
    -- A ceiling as well as a floor.
    return math.min(math.floor(n), 10000)
end

--- Every entry also goes through the normal log path, so an operator watching the
local function audit(event, detail)
    local line = ('%s cis_libs %s %s'):format(
        os.date('%Y-%m-%dT%H:%M:%S'), tostring(event), tostring(detail or ''))
    Logging.Info(line)

    auditRing[auditNext] = { event = tostring(event), detail = tostring(detail or ''), line = line }
    auditNext = auditNext + 1
    if auditNext > auditCapacity() then
        auditNext = 1
    end
    if auditHeld < auditCapacity() then
        auditHeld = auditHeld + 1
    end
end

-- DECLARED BEFORE the console command below, which uses it.
--- The entries, newest LAST. `limit` is capped by what the ring actually holds, so
local function auditEntries(limit)
    local want = tonumber(limit)
    if not want or want < 1 then
        want = auditHeld
    end
    want = math.min(math.floor(want), auditHeld)
    local out = {}
    for i = 1, want do
        -- The oldest surviving entry, then forward.
        out[#out + 1] = auditRing[((auditNext - 1 - want + i - 1) % auditCapacity()) + 1]
    end
    return out
end

--- The console reader, for the operator who has no resource to call from.
RegisterCommand('cis_audit', function(src, args)
    if src ~= 0 then
        print('cis_libs: cis_audit is a server console command. Run it from the '
            .. 'txAdmin console or the server terminal.')
        return
    end
    local limit = tonumber(args and args[1]) or auditHeld
    local shown = 0
    for _, entry in ipairs(auditEntries(limit)) do
        print(entry.line)
        shown = shown + 1
    end
    print(('[cis_libs] audit: %d entr%s held, %d shown (capacity %d)')
        :format(auditHeld, auditHeld == 1 and 'y' or 'ies', shown, auditCapacity()))
end, true)

exports('GetAuditLog', function(limit)
    if not CisInvokingAllowed() then
        return false, notAuthorizedReason('GetAuditLog')
    end
    return auditEntries(limit)
end)

-- A1 · THE CONTRACT VERSION THIS LIBRARY IMPLEMENTS, and the reader for the version a
local CONTRACT_MAJOR = 1

local function readContractVersion()
    local resource = GetInvokingResource()
    if not resource or not GetResourceMetadata then
        return nil
    end
    local ok, declared = pcall(function()
        return GetResourceMetadata(resource, 'cis_libs_contract', 0)
    end)
    if not ok or type(declared) ~= 'string' then
        return nil
    end
    return tonumber(declared:match('^(%d+)'))
end

local function sortedSlotNames()
    local names = {}
    for slot in pairs(CisRegistry.SLOTS) do
        names[#names + 1] = slot
    end
    table.sort(names)
    return names
end

-- One line per missing capability, then silence.
local function warnOnce(slot, method, reason)
    local key = tostring(slot) .. '.' .. tostring(method)
    if warned[key] then
        return
    end
    warned[key] = true
    Logging.Warn(('cis_libs: %s.%s unavailable -- %s. %s'):format(
        tostring(slot), tostring(method),
        tostring(reason),
        'Install the product that provides it, or call '
            .. 'exports["cis_libs"]:GetCapabilities() to see what is missing.'))
end

-- The generic forward. Returns nil (or false) plus a reason on failure, and hands back
local lastRefusal = {}

--- The reason for the most recent capability refusal made BY THIS RESOURCE.
exports('GetLastRefusal', function()
    return lastRefusal[GetInvokingResource() or 'cis_libs']
end)

local function forward(slot, onFail, ...)
    local caller = GetInvokingResource() or 'cis_libs'
    local results = table.pack(CisRegistry.call(slot, ...))
    if not results[1] then
        warnOnce(slot, (...), results[2])
        lastRefusal[caller] = results[2]
        if type(onFail) == 'function' then
            return onFail()
        end
        if onFail ~= nil then
            return onFail
        end
        return nil, results[2]
    end
    lastRefusal[caller] = nil
    return table.unpack(results, 2, results.n)
end

-- CONFIGURATION

exports('SetConfig', function(config, security, discord)
    -- FIRST SUPPLIER WINS, and the loser is told.
    local supplier = GetInvokingResource() or 'cis_libs'
    if Config and Config.__owned and Config.__owner ~= 'cis_libs' and Config.__owner ~= supplier then
        -- THE REFUSAL STATES THE FIX. Two ways to change the supplier, and the caller
        return false, ('configuration was already supplied by %s; only that resource can '
            .. 'replace it. To hand it to someone else, restart cis_libs, or stop and '
            .. 'restart %s so it supplies the configuration again.')
            :format(tostring(Config.__owner), tostring(Config.__owner))
    end
    if type(config) == 'table' then
        -- Merged over the built-in defaults key by key, so an operator who set one leaf
        local merged = CisDefaults.merge(CisDefaults.config(), CisDefaults.sanitize(config))
        local ok, problems = CisDefaults.validate(merged)
        if not ok then
            Logging.Error(('cis_libs: configuration from %s refused. %d problem(s):')
                :format(tostring(supplier), #problems))
            for i = 1, #problems do
                Logging.Error('  ' .. problems[i])
            end
            Logging.Error('  Nothing was applied. Fix the config in the file your '
                .. 'product ships and restart that resource.')
            return false, ('configuration from %s refused: %s')
                :format(tostring(supplier), table.concat(problems, '; '))
        end
        Config = merged
    end
    if type(security) == 'table' then
        -- Deliberately NOT merged with the default Security.
        Security = CisDefaults.sanitize(security)
        Security.EventPrefix = Security.EventPrefix or 'cis_libs'
        Security.AuthorizedResources = Security.AuthorizedResources or {}
    end
    if type(discord) == 'table' then
        -- The webhook table is configuration like any other and has to arrive the same
        DiscordConfig = CisDefaults.sanitize(discord)
    end
    Config.__owned = true
    Config.__owner = GetInvokingResource() or 'cis_libs'
    -- The allow-list is DERIVED from Security, so replacing Security has to rebuild it.
    if type(security) == 'table' and CisSecurityRebuild then
        CisSecurityRebuild()
    end
    -- EVERY CONNECTED CLIENT IS TOLD, not just the ones that have not fetched yet.
    if CisConfigUtil and TriggerClientEvent then
        TriggerClientEvent('cis_libs:client:getData', -1,
            CisConfigUtil.clientPayload(Config, Security))
    end
    Logging.Info(('cis_libs: configuration supplied by %s'):format(tostring(Config.__owner)))
    -- A2 · Recorded, because this is the most consequential event the library has: the
    audit('config-supplied', ('owner=%s'):format(tostring(Config.__owner)))
    return true
end)

--- The outbound/webhook configuration, for the capability that does the sending.
exports('GetDiscordConfig', function()
    if GetInvokingResource() == 'cis_libs' then
        return DiscordConfig or {}
    end
    -- Nothing, and it looks exactly like nothing.
    return {}
end)

--- Register a capability provider.
exports('RegisterCapability', function(slot, provider, contract)
    -- A1 · THE CONTRACT VERSION IS CHECKED BEFORE ANYTHING ELSE HAPPENS.
    local declared = readContractVersion()
    if declared and declared ~= CONTRACT_MAJOR then
        local reason = ('%s declares cis_libs_contract %s but this cis_libs is %s.x; '
            .. 'update %s to match, or install a cis_libs that does')
            :format(tostring(GetInvokingResource()), tostring(declared),
                tostring(CONTRACT_MAJOR), tostring(GetInvokingResource()))
        Logging.Warn(('cis_libs: capability %q refused: %s'):format(tostring(slot), reason))
        audit('capability-refused', ('slot=%s caller=%s reason=contract-mismatch')
            :format(tostring(slot), tostring(GetInvokingResource())))
        return false, reason
    end

    local ok, reason = CisRegistry.register(slot, provider, contract)
    if not ok then
        Logging.Warn(('cis_libs: capability %q refused: %s'):format(tostring(slot), tostring(reason)))
        audit('capability-refused', ('slot=%s caller=%s provider=%s reason=%s')
            :format(tostring(slot), tostring(GetInvokingResource()), tostring(provider),
                tostring(reason)))
        return false, reason
    end
    local owner = CisRegistry.owner(slot)
    Logging.Info(('cis_libs: capability %q <- %s'):format(tostring(slot), tostring(owner)))
    audit('capability-registered', ('slot=%s owner=%s provider=%s')
        :format(tostring(slot), tostring(owner), tostring(provider)))
    return true
end)

--- Release a capability, for a resource that is shutting down or handing over.
exports('UnregisterCapability', function(slot)
    local resource = GetInvokingResource()
    local previous = CisRegistry.owner(slot)
    if not CisRegistry.unregister(slot, resource) then
        audit('capability-release-refused', ('slot=%s caller=%s holder=%s')
            :format(tostring(slot), tostring(resource), tostring(previous)))
        return false
    end
    audit('capability-released', ('slot=%s owner=%s'):format(tostring(slot), tostring(previous)))
    return true
end)

--- REVOKE A CAPABILITY WITHOUT A RESTART.
RegisterCommand('cis_force_unregister', function(src, args)
    if src ~= 0 then
        print('cis_libs: cis_force_unregister is a server console command. '
            .. 'Run it from the txAdmin console or the server terminal.')
        -- Audited, because the audit log is how an owner finds out that somebody was
        audit('capability-revoke-refused', ('slot=%s caller=%s')
            :format(tostring((args and args[1]) or '?'), tostring(src)))
        return
    end
    -- FiveM passes (source, args, argString): `args` is a TABLE of the words after the
    local slot = args and args[1]
    if type(slot) ~= 'string' or not CisRegistry.SLOTS[slot] then
        print(('usage: cis_force_unregister <slot>. known slots: %s')
            :format(table.concat(sortedSlotNames(), ', ')))
        return
    end
    local previous = CisRegistry.owner(slot)
    -- No owner check, deliberately: this is the override, and that is the whole reason
    if not CisRegistry.unregister(slot) then
        print(('cis_libs: %q is not registered, so there is nothing to revoke'):format(slot))
        return
    end
    print(('cis_libs: revoked %q (was held by %s); the provider may register it again.')
        :format(slot, tostring(previous)))
    audit('capability-force-released', ('slot=%s owner=%s'):format(slot, tostring(previous)))
end, true)

--- What is registered, what is not, and who owns what.
exports('GetCapabilities', function()
    return CisRegistry.snapshot()
end)

--- T9. Wait for a slot instead of answering nil during boot.
exports('WaitCapability', function(slot, timeoutMs)
    return CisRegistry.wait(slot, timeoutMs)
end)

-- A stopped resource's exports are gone.
AddEventHandler('onResourceStop', function(resource)
    -- The resource's refusal goes with it.
    lastRefusal[resource] = nil
    for _, slot in ipairs(CisRegistry.releaseOwner(resource)) do
        warned = {}
        Logging.Warn(('cis_libs: capability %q released: %s stopped'):format(slot, resource))
    end
    -- It used to be cleared alongside the capability slots, and that turned every
end)

--- The frameworks and drivers this library knows how to detect, copied out of the pure
exports('GetKnownTargets', function()
    return {
        frameworks = CisDetect and CisDetect.FRAMEWORKS or {},
        databases = CisDetect and CisDetect.DATABASES or {},
    }
end)

-- DETECTION

local function isStarted(name)
    return GetResourceState(name) == 'started'
end

local function resourceVersion(name)
    if not GetResourceMetadata then
        return nil
    end
    local ok, version = pcall(GetResourceMetadata, name, 'version', 0)
    return ok and version or nil
end

-- MEASURED: calling a missing export on a started resource RAISES, so a probe is an
local function probe(name, exportName)
    if not exportName then
        return false
    end
    local ok, fn = pcall(function()
        return exports[name][exportName]
    end)
    return ok and fn ~= nil
end

--- Decide which framework this server runs.
exports('DetectFramework', function(configured, custom)
    return CisDetect.framework(configured, custom, isStarted, resourceVersion, probe)
end)

--- Decide which database driver is in use.
exports('DetectDatabase', function(configured)
    return CisDetect.database(configured, isStarted, resourceVersion)
end)

-- FRAMEWORK -> cis_core

exports('GetNormalizedPlayer', function(src)
    return forward('framework', nil, 'NormalizedPlayer', src)
end)

exports('Notify', function(src, message, kind)
    if CisRegistry.has('framework') then
        return forward('framework', nil, 'Notify', src, message, kind)
    end
    -- No framework: cis_libs delivers the notification itself rather than dropping it.
    return deliverNotification(src, message, kind)
end)

-- DATABASE -> cis_bridge (one adapter per driver)

exports('DbQuery', function(sql, params)
    return forward('database', nil, 'query', sql, params)
end)

exports('DbSingle', function(sql, params)
    return forward('database', nil, 'single', sql, params)
end)

exports('DbScalar', function(sql, params)
    return forward('database', nil, 'scalar', sql, params)
end)

exports('DbInsert', function(sql, params)
    return forward('database', nil, 'insert', sql, params)
end)

exports('DbUpdate', function(sql, params)
    return forward('database', nil, 'update', sql, params)
end)

-- The only asymmetry in this block, preserved deliberately: Transaction takes a LIST of
exports('DbTransaction', function(queries)
    return forward('database', function()
        return false, 'no database provider is registered; transactions are unavailable'
    end, 'transaction', queries)
end)

-- INVENTORY -> cis_core

exports('InventoryCount', function(src, item)
    return forward('inventory', 0, 'count', src, item)
end)

exports('InventoryAdd', function(src, item, amount, metadata)
    return forward('inventory', false, 'add', src, item, amount, metadata)
end)

exports('InventoryRemove', function(src, item, amount)
    return forward('inventory', false, 'remove', src, item, amount)
end)

exports('InventoryHas', function(src, item, amount)
    return forward('inventory', false, 'has', src, item, amount)
end)

-- DOORS -> cis_keys

exports('AddDoorToSystem', function(newDoorData, internal)
    if not CisInvokingAllowed() then
        return false
    end
    return forward('doors', false, 'add', newDoorData, internal)
end)

exports('AddDoorGroup', function(groupData)
    if not CisInvokingAllowed() then
        return false
    end
    return forward('doors', false, 'addGroup', groupData)
end)

exports('BreakDoor', function(identifier)
    return forward('doors', nil, 'breakDoor', identifier)
end)

exports('FixDoor', function(identifier)
    return forward('doors', nil, 'fixDoor', identifier)
end)

exports('LockDoors', function(identifier)
    return forward('doors', 0, 'lock', identifier)
end)

exports('UnlockDoors', function(identifier)
    return forward('doors', 0, 'unlock', identifier)
end)

-- nil is no such door; false is unlocked.
exports('GetDoorState', function(doorId)
    return forward('doors', nil, 'state', doorId)
end)

exports('GetAllDoorData', function()
    return forward('doors', nil, 'all')
end)

-- DISCORD -> cis_bridge

exports('SendDiscordLog', function(webhookURL, title, message, color, ping)
    return forward('discord', nil, 'log', webhookURL, title, message, color, ping)
end)

exports('GetDiscordQueueDepth', function()
    return forward('discord', 0, 'depth')
end)

-- SECURITY HANDLER

exports('SetDropPlayerHandler', function(provider)
    return CisRegistry.register('security', provider)
end)

-- PUBLISHING

-- THE THREE PUBLISHERS ARE NOT ALL THE SAME KIND OF CALL, and gating them as if they

exports('PublishJobUpdate', function(job, src)
    if type(job) ~= 'table' then
        return false, 'job must be a table'
    end
    if not CisInvokingAllowed() then
        return false, notAuthorizedReason('PublishJobUpdate')
    end
    -- The job histogram is a cis_libs feature and stays one: it is a pure in-memory
    if src then
        CisRememberJob(src, job)
        TriggerClientEvent('cis_libs:jobUpdated', src, {
            name = job.name,
            grade = job.grade,
        })
    else
        TriggerClientEvent('cis_libs:jobUpdated', -1, {
            name = job.name,
            grade = job.grade,
        })
    end
    return true
end)

exports('PublishPlayerLoaded', function(job, src)
    if type(job) == 'table' and src then
        CisRememberJob(src, job)
    end
    -- Client-local, not broadcast.
    if src then
        TriggerClientEvent('cis_libs:playerLoaded', src, job)
    end
    return true
end)

-- The client's half of the same conversation.
CisNetOn('cis_libs:server:inventorySync', function(src)
    exports['cis_libs']:PublishInventory(src)
end)

-- The inventory snapshot push.
exports('NotifyClient', function(src, message, kind)
    return deliverNotification(src, message, kind)
end)

exports('PublishInventory', function(src)
    if type(src) ~= 'number' or src <= 0 then
        return false
    end
    -- On the allow-list, because this writes state a CLIENT acts on.
    if not CisInvokingAllowed() then
        return false, notAuthorizedReason('PublishInventory')
    end
    local ok, snapshot = CisRegistry.call('inventory', 'snapshot', src)
    if not ok then
        return false
    end
    TriggerClientEvent('cis_libs:client:inventory', src, snapshot)
    return true
end)

-- THE LEAK DETECTOR. Every lifecycle promise this library makes is a promise that
--- @return table counts and counters, never player data
exports('GetDiagnostics', function(opts)
    return CisDiagnostics.Collect('server', opts)
end)
