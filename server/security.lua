-- Net-event gate, rate limiter, and the door/sync allow-list.
--
-- Everything a client can send arrives through CisNetOn below, so the two
-- checks that matter to a server owner -- "may this event run at all" and "how
-- often may it run" -- are applied in exactly one place rather than per
-- handler. Handlers therefore receive a src they can trust, and no handler has
-- to remember to rate-limit itself.

local rates = {}
local authorized

-- Written once a server has actually been touched by this library. Its absence
-- is the second half of the "is this a new install?" test.
local INSTALL_MARKER = 'configs/install.json'

-- Postures for the "AuthorizedResources is empty" case.
--   permissive -- today's behaviour: any server-side caller may mutate.
--   restrictive -- nobody but cis_libs itself may mutate.
--   configured -- an allow-list was named, so there is no empty-list case left.
-- nil means undecided, which is treated as permissive: an install we cannot
-- classify is never the one that gets broken.
local posture

-- An empty table is treated as "not configured", the same as nil. That is what
-- makes the decision below possible at all: the restrictive reading is
-- *triggered by* the list being empty, so a config that ships an empty stub
-- cannot accidentally be read as a deliberate allow-nothing list.
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

-- The RESOURCE name of the driver that is actually running, not the
-- configured value. Under `Type = "AUTO"` the configured value is the literal
-- string "AUTO", which is not a resource -- waiting for it to start would sit
-- out the full 30s deadline and then give up, and the door table would never
-- be read. Database.Init() runs before this file's boot wait and rewrites the
-- config to the driver it found, so falling back to that keeps the two
-- readings in step.
local function driverName()
    local db = Config and Config.Framework and Config.Framework.Database
    local configured = db and db.Type or 'AUTO'
    if configured and configured ~= 'AUTO' then
        return configured
    end
    local detected = rawget(_G, 'Database')
    if type(detected) == 'table' and detected.detected and detected.detected.resource then
        return detected.detected.resource
    end
    return 'oxmysql'
end

-- A file left inside the resource's own configs/ directory, not in the
-- operator's server cfg. That is deliberate: it travels with the resource
-- rather than with the server, so a config that never had an allow-list but
-- does have this file is an install that already ran the decision below once.
-- Read and written under pcall because a read-only resource directory (a
-- cooked/packed deploy) must degrade to "no marker", not to a hard stop.
local function hasInstallMarker()
    if not LoadResourceFile then
        return false
    end
    local ok, body = pcall(LoadResourceFile, GetCurrentResourceName(), INSTALL_MARKER)
    return ok and type(body) == 'string' and body ~= ''
end

-- Only ever called from applyPosture('restrictive'), so writing the file is
-- itself the record of the decision. The trailing -1 is SaveResourceFile's
-- indent argument, and there is deliberately no indent.
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

-- One decision, applied once. Idempotent because the deferred probe below can
-- reach the same verdict the synchronous path already took; re-running it would
-- rewrite the marker and reprint a paragraph the operator has already read.
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

-- Decides the allow-list, in this order, and each step ends the search:
--
--   1. a list was named          -> that list, and the question is closed
--   2. classified as legacy      -> permissive, preserving old behaviour
--   3. classified as new         -> restrictive, and refuse every foreign caller
--   4. cannot be classified yet  -> permissive for now, decide when the answer
--                                   arrives
--
-- Step 4 is the only one that leaves work outstanding, and it is the only one
-- that reaches the deferred thread. Steps 1 to 3 all end with `posture` set.
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
        -- 2s poll, 30s ceiling. The thing being waited on is another RESOURCE
        -- starting, which is measured in seconds and is not under this
        -- library's control, so a tighter poll buys nothing a maintainer can
        -- observe and costs a scheduler wakeup for the whole window. After 30s
        -- the give-up is silent on purpose: the posture stays permissive, which
        -- is the pre-existing behaviour, and the operator has already been
        -- told the install is unclassified.
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

-- The one place a mutation asks "may I?". `authorized` carries three states
-- and they are not interchangeable:
--
--   nil      -- undecided or permissive; allow everything
--   {}       -- restrictive; allow nothing but cis_libs itself
--   {name...} -- an operator's list; allow exactly those
--
-- nil and {} both read as "no foreign caller is on the list" in the code
-- below, so the distinction is carried entirely by the nil check. Turning
-- nil into an empty table is what turns permissive into restrictive, which is
-- why every restrictive path below sets both.
local function invokingAllowed()
    if not authorized then
        return true
    end
    local resource = GetInvokingResource()
    -- No invoking resource means the call came from cis_libs' own code (a
    -- net event, or a direct global call), and cis_libs is always permitted:
    -- otherwise the library would refuse to load its own restored doors.
    if not resource or resource == GetCurrentResourceName() then
        return true
    end
    return authorized[resource] == true
end

function CisInvokingAllowed()
    return invokingAllowed()
end

-- A fixed window, not a sliding one, and not a token bucket. The window is
-- per (src, event name), so a client is limited per event rather than across
-- all of them: a legitimate client firing a handful of different events in the
-- same second must not spend one shared budget. The cost is the known
-- boundary case -- a client can burst 2x maxHits across a window edge. That is
-- acceptable here because the limit exists to stop a runaway loop, not to
-- meter anything.
--
-- Defaults: 8 per second, applied to any event registered through CisNetOn
-- that does not set its own limit. It is a backstop, not a tuned value: the
-- events that legitimately fire more often set their own (server/callback.lua
-- allows 20 per second per callback name), and the one a UI can produce in a
-- burst -- the doorlock toggle -- carries a 250ms cooldown of its own and does
-- not rely on this. Anything reaching 8 a second on an event that did not ask
-- for more is a script, not a UI.
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

-- Every net event a client can reach goes through here. Two things it does
-- that a bare RegisterNetEvent does not:
--
--   1. the handler receives `src` as its first argument, so no handler has to
--      read the `source` global and every handler is written the same way;
--   2. the handler runs under pcall, so a bug in one handler is logged
--      against the EVENT NAME rather than surfacing as a FiveM script error
--      attributed to whatever file happened to be on top of the stack. An
--      operator looking at a console line naming `cis_libs:doorlock:...` can
--      find the handler; a stack trace from inside a net event cannot.
--
-- A returned function arrives as a callable reference TABLE, not a function,
-- so `type(x) == 'function'` rejects handlers that work. This is the same
-- check server/callback.lua uses; both must agree or a handler registered one
-- way is refused the other.
local function isCallableRef(v)
    if type(v) == 'function' then
        return true
    end
    return type(v) == 'table' and rawget(v, '__cfx_functionReference') ~= nil
end

-- `fn` may be a function OR a `'resource:export'` reference string.
--
-- A consumer resource cannot pass a function: a function sent INTO a resource
-- across the boundary arrives nil, which is the rule this library documents
-- everywhere else. The old proxy did exactly that, so `Cis.net.on` registered
-- a handler that was already nil and every client invocation raised inside the
-- pcall below. The reference form is how `Cis.callback.register` has always
-- worked, and it is the only form a consumer can actually use.
--
-- The reference is resolved the way server/callback.lua resolves one, which
-- means passing the exports table EXPLICITLY: `exports[res][name]` is an
-- unbound method and eats the first argument as `self` (see the long note in
-- server/callback.lua). Getting that wrong costs the handler its `src`.
--
-- Note the name is used verbatim: CisNetOn does not prepend a prefix. Callers
-- that want Security.EventPrefix applied pass it in (see server/doorlock.lua);
-- the rest use the literal `cis_libs:` namespace.
function CisNetOn(name, fn, opts)
    opts = opts or {}

    local self, handler
    if type(fn) == 'string' then
        local resource, exportName = fn:match('^([^:]+):(.+)$')
        if resource and exportName then
            self = exports[resource]
            handler = self and self[exportName]
        end
        if not isCallableRef(handler) then
            handler = nil
        end
    elseif type(fn) == 'function' then
        handler = fn
    end

    if not handler then
        Logging.Error(('Cis.net.on("%s") registered nothing: the handler must be a function '
            .. '(cis_libs only) or a "resource:export" reference, not %s')
            :format(tostring(name), type(fn)))
        return false
    end

    RegisterNetEvent(name, function(...)
        local src = source
        if type(src) ~= 'number' or src <= 0 then
            return
        end
        if not rateOk(src, name, opts.windowMs, opts.maxHits) then
            CisLog('warn', ('rate limited %s from %s'):format(name, src), 'cheating')
            return
        end
        local ok, err
        if self then
            ok, err = pcall(handler, self, src, ...)
        else
            ok, err = pcall(handler, src, ...)
        end
        if not ok then
            Logging.AutoLogError(err, name)
        end
    end)
    -- true once the event is actually bound. Without it a caller had no way
    -- to tell a successful registration from a REFUSAL, because the refusal
    -- also returned nothing -- which is how a test asserting only "did not
    -- throw" came to pass against a registration that had not happened.
    return true
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

-- The only cleanup this file does, and it is required rather than tidy: the
-- buckets are keyed by src, and server ids are REUSED. Without this a returning
-- player would inherit whatever limit the previous occupant of their id had
-- left behind, and would be rate limited on their first event.
AddEventHandler('playerDropped', function()
    rates[source] = nil
end)
