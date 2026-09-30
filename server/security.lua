local rates = {}
local authorized

-- Written once a server has actually been touched by this library. Its absence
-- is the second half of the "is this a new install?" test.
local INSTALL_MARKER = 'configs/install.json'

-- Postures for the "AuthorizedResources is empty" case.
--   permissive -- today's behaviour: any server-side caller may mutate.
--   restrictive -- nobody but cis_libs itself may mutate.
-- nil means undecided, which is treated as permissive: an install we cannot
-- classify is never the one that gets broken.
local posture

local function configuredList()
    local list = Security and Security.AuthorizedResources
    if type(list) ~= 'table' or #list == 0 then
        return nil
    end
    return list
end

local function persistConfigured()
    return not not (Config and Config.Doorlock and Config.Doorlock.Persist)
end

local function driverName()
    local db = Config and Config.Framework and Config.Framework.Database
    return db and db.Type or 'oxmysql'
end

local function hasInstallMarker()
    if not LoadResourceFile then
        return false
    end
    local ok, body = pcall(LoadResourceFile, GetCurrentResourceName(), INSTALL_MARKER)
    return ok and type(body) == 'string' and body ~= ''
end

local function writeInstallMarker()
    if not SaveResourceFile then
        return
    end
    pcall(SaveResourceFile, GetCurrentResourceName(), INSTALL_MARKER,
        ('{"restricted":true,"eventPrefix":"%s"}'):format(tostring(
            (Security and Security.EventPrefix) or 'cis_libs')), -1)
end

-- A legacy install is one that was already running cis_libs before the
-- restrictive empty-list default existed. Two signals, either sufficient:
--
--   1. a written config this library left on disk
--   2. the cis_doors table, which only exists if Config.Doorlock.Persist was
--      on and that bootstrap has already run
--
-- Signal 2 is only conclusive when persistence is configured. With it off,
-- cis_libs never creates the table, so its absence is known immediately and
-- no database call is made. With it on, the answer needs a query, and until
-- that query returns the install stays permissive.
local function legacyByConfig()
    if hasInstallMarker() then
        return true, 'a written config already exists'
    end
    if not persistConfigured() then
        return false, 'no written config and door persistence was never enabled'
    end
    return nil, 'door persistence is enabled; waiting to read cis_doors'
end

local function reportRestrictive(reason)
    print('[cis_libs] SECURITY: door and sync mutations are REFUSED for every resource except cis_libs.')
    print(('  %s'):format(reason))
    print('  Security.AuthorizedResources is empty. On a new install that is the correct posture:')
    print('  an empty list used to mean "any server-side resource may add, break and rewrite doors".')
    print('  To restore the old permissive behaviour, name the resources that mutate doors, e.g.')
    print('      Security.AuthorizedResources = { "cis_storeRobberies", "cis_housing" }')
    print('  A resource can ask first: exports["cis_libs"]:InvokingAllowed(). See COMPATIBILITY.md section 6.')
end

local function applyPosture(next, reason)
    if posture == next then
        return
    end
    posture = next
    if next == 'restrictive' then
        writeInstallMarker()
        reportRestrictive(reason)
    else
        print(('[cis_libs] SECURITY: empty AuthorizedResources is PERMISSIVE for this install (%s).')
            :format(reason))
    end
end

local function rebuildAuthorized()
    authorized = nil
    local list = configuredList()
    if list then
        authorized = {}
        for i = 1, #list do
            authorized[list[i]] = true
        end
        -- An operator-named list is a DEFINITE answer. Nobody has to guess
        -- whether this install is legacy and nothing is waiting on a query.
        --
        -- Without this line `posture` stayed nil, so the deferred legacy probe
        -- below ran anyway and issued `SELECT id FROM cis_doors` -- a table
        -- that only exists when Doorlock.Persist is on. Every boot of every
        -- server with an allow-list configured therefore printed a database
        -- error naming a table that was never supposed to be there, and the
        -- cause was nowhere near the message.
        posture = 'configured'
        return
    end
    local legacy, reason = legacyByConfig()
    if legacy == nil then
        -- Unclassified, so `authorized` stays nil, which is the permissive
        -- reading. Do not guess the other way on a server we could not read.
        print(('[cis_libs] SECURITY: AuthorizedResources is empty and the install is not classified yet (%s);')
            :format(reason))
        print('  staying permissive until it is. No door or sync mutation is refused in the meantime.')
        return
    end
    if legacy then
        applyPosture('permissive', reason)
        return
    end
    applyPosture('restrictive', reason)
    -- An empty, non-nil table denies every foreign caller. `nil` means
    -- allow-all, which is how the permissive path is expressed.
    authorized = {}
end

rebuildAuthorized()

-- Resolve the deferred case: wait for the database driver to start, then ask
-- whether the persisted door table has any rows. A table this library created
-- moments ago on a fresh install is empty, and an empty one means new.
if posture == nil then
    CreateThread(function()
        -- `cis_doors` is only ever created when Doorlock.Persist is on, so
        -- this query is only meaningful when persistence is configured. Asking
        -- anyway asks the driver about a table that does not exist, and the
        -- driver answers with an error the operator can do nothing about.
        -- This mirrors legacyByConfig(), which already treats "persistence was
        -- never enabled" as a definite answer.
        if not persistConfigured() then
            applyPosture('restrictive', 'no written config and door persistence was never enabled')
            authorized = {}
            return
        end
        local name = driverName()
        local deadline = GetGameTimer() + 30000
        while GetResourceState(name) ~= 'started' and GetGameTimer() < deadline do
            Wait(2000)
        end
        if GetResourceState(name) ~= 'started' then
            return
        end
        pcall(function()
            exports['cis_libs']:DatabaseFetchAll('SELECT id FROM cis_doors', {}, function(rows)
                if type(rows) == 'table' and #rows > 0 then
                    applyPosture('permissive', 'the cis_doors table already has persisted rows')
                else
                    applyPosture('restrictive', 'no written config and cis_doors is empty')
                    authorized = {}
                end
            end)
        end)
        -- If the driver never calls back the install stays permissive, which
        -- is the same behaviour it has today. Refusing on a server we could
        -- not read would be the worse failure.
    end)
end

local function invokingAllowed()
    if not authorized then
        return true
    end
    local resource = GetInvokingResource()
    if not resource or resource == GetCurrentResourceName() then
        return true
    end
    return authorized[resource] == true
end

function CisInvokingAllowed()
    return invokingAllowed()
end

local function rateOk(src, name, windowMs, maxHits)
    windowMs = windowMs or 1000
    maxHits = maxHits or 8
    local now = GetGameTimer()
    rates[src] = rates[src] or {}
    local bucket = rates[src][name]
    if not bucket or now - bucket.started >= windowMs then
        rates[src][name] = { started = now, hits = 1 }
        return true
    end
    bucket.hits = bucket.hits + 1
    return bucket.hits <= maxHits
end

function CisRateOk(src, name, windowMs, maxHits)
    return rateOk(src, name, windowMs, maxHits)
end

function CisNetOn(name, fn, opts)
    opts = opts or {}
    RegisterNetEvent(name, function(...)
        local src = source
        if type(src) ~= 'number' or src <= 0 then
            return
        end
        if not rateOk(src, name, opts.windowMs, opts.maxHits) then
            CisLog('warn', ('rate limited %s from %s'):format(name, src), 'cheating')
            return
        end
        local ok, err = pcall(fn, src, ...)
        if not ok then
            Logging.AutoLogError(err, name)
        end
    end)
end

local DEFAULT_DROP_MESSAGE = 'cis_libs: Kicked. If you believe this is a mistake, contact the server owner.'

function CisSecurityReport(src, reason)
    CisLog('warn', ('security report src=%s reason=%s'):format(tostring(src), tostring(reason)), 'cheating')
    if type(src) ~= 'number' or src <= 0 then
        return false
    end
    if GetPlayerName(src) == nil then
        return false
    end
    -- Security.DropPlayer may be a boolean or a custom function(src, reason).
    local handler = Security and Security.DropPlayer
    if type(handler) == 'function' then
        local ok, err = pcall(handler, src, reason)
        if not ok then
            Logging.AutoLogError(err, 'Security.DropPlayer')
            return false
        end
        return true
    end
    if handler then
        DropPlayer(src, DEFAULT_DROP_MESSAGE)
        return true
    end
    return false
end

exports('SecureNetOn', function(name, fn)
    CisNetOn(name, fn)
end)

-- Exposed so a companion resource can ask "would a mutation from me be
-- allowed?" before attempting one, instead of guessing from the config.
exports('InvokingAllowed', function()
    return invokingAllowed()
end)

exports('RateOk', function(src, name, windowMs, maxHits)
    return rateOk(src, name, windowMs, maxHits)
end)

exports('SecurityReport', CisSecurityReport)

exports('GetLibsPrefix', function()
    return (Security and Security.EventPrefix) or 'cis_libs'
end)

AddEventHandler('playerDropped', function()
    rates[source] = nil
end)
