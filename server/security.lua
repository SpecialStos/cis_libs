-- Net-event gate, rate limiter, and the door/sync allow-list.
--
-- Everything a client can send arrives through CisNetOn below, so the two
-- checks that matter to a server owner -- "may this event run at all" and "how
-- often may it run" -- are applied in exactly one place rather than per
-- handler. Handlers therefore receive a src they can trust, and no handler has
-- to remember to rate-limit itself.

local rates = {}
-- How many buckets each src is holding, kept as a COUNTER beside the map.
--
-- Counting them would mean walking `rates[src]` on every new event name, and the
-- check has to happen on the hot path -- a client firing one event in a loop
-- would otherwise pay an O(keys) walk per invocation to learn the key count it
-- already knows.
local rateCounts = {}
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

-- Whether anything on this server has ever persisted state through this
-- library. It used to be `Config.Doorlock.Persist`, which meant this file knew
-- the name of a config section owned by a product, and then queried a table
-- owned by another. Both of those are gone: cis_libs owns no table, and the
-- question now belongs to whichever product holds one.
--
-- A server with no doors product installed has certainly never stored a door,
-- so the absent capability is a DEFINITE answer rather than an unknown one --
-- which is what lets a fresh install reach a verdict immediately instead of
-- sitting permissive for 30 seconds and then guessing.
local function persistConfigured()
    if not CisRegistry.has('doors') then
        return false
    end
    local ok, persisted = CisRegistry.call('doors', 'persisted')
    return ok and persisted == true
end

-- A file left inside the resource's own configs/ directory, not in the
-- operator's server cfg. That is deliberate: it travels with the resource
-- rather than with the server, so a config that never had an allow-list but
-- does have this file is an install that already ran the decision below once.
-- Read and written under pcall because a read-only resource directory (a
-- cooked/packed deploy) must degrade to "no marker", not to a hard stop.
--
-- RETURNS THE PARSED MARKER, not a boolean, and that is the whole fix.
--
-- `hasInstallMarker()` used to be a presence test, and `legacyByConfig()` read
-- presence as "a written config already exists", which means legacy, which
-- means permissive. The marker is written only when the posture is RESTRICTIVE,
-- so its presence meant the opposite of what it was taken to mean: boot 1 ran
-- restrictive and wrote the marker, boot 2 read it as legacy and ran
-- permissive, on the same server with the same files. An operator who installed
-- fresh, saw the refusal, rebooted, and found door mutations wide open had no
-- way to get back to refusing without deleting a file they had never heard of.
--
-- The two cases are now distinct, which is what they always were:
--
--   {"restricted":true}  -- THIS library wrote it, and it decided to refuse.
--                           Boot 2 must refuse again. That is the whole point
--                           of writing it: the decision is STABLE across boots.
--   anything else, or an
--   unparsable body        -- something else wrote it, or an older version of
--                           this library did. Unknown provenance is not
--                           evidence of a decision, so it is NOT treated as
--                           legacy on the strength of existing.
local function readInstallMarker()
    if not LoadResourceFile then
        return nil
    end
    local ok, body = pcall(LoadResourceFile, GetCurrentResourceName(), INSTALL_MARKER)
    if not ok or type(body) ~= 'string' or body == '' then
        return nil
    end
    -- Deliberately not a JSON parser. The file is one flat table of primitives
    -- written by the function below, and a body with an embedded quote or brace
    -- must read as "not a marker this library wrote" rather than raise -- a
    -- syntax error while deciding a security posture is the worst possible time
    -- to raise.
    local restricted = body:match('"restricted"%s*:%s*true')
    if restricted then
        return { restricted = true }
    end
    return { restricted = false }
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
    -- A marker this library wrote is a decision, and the decision is
    -- RESTRICTIVE. Re-deciding it as legacy on the second boot is the inversion
    -- described on readInstallMarker.
    local marker = readInstallMarker()
    if marker and marker.restricted then
        return false, 'this install previously decided to refuse, and that decision is being kept'
    end
    if not persistConfigured() then
        return false, 'no written config and no product that persists state is installed'
    end
    return nil, 'a persisting product is installed; waiting to ask it whether it holds any rows'
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

-- Rebuild the allow-list, for SetConfig.
--
-- `rebuildAuthorized` used to run exactly once, at load, against the DEFAULT
-- empty Security. SetConfig then replaced that table wholesale and nothing
-- rebuilt, so an operator who wrote AuthorizedResources into their master config
-- got a library that read it, stored it, printed it -- and enforced nothing.
-- Every foreign resource stayed refused while the console showed the resource
-- named as permitted, which is the worst shape of bug to receive a support
-- ticket about.
--
-- Exposed as a named function rather than triggered by a global, because a
-- global is a worse contract than a call another file can see and audit.
--
-- Safe to call when the posture is already decided, which matters because
-- SetConfig runs again on every `onResourceStart('cis_libs')` -- a restart must
-- not reprint a paragraph the operator has already read, and must not rewrite
-- the marker over a decision this very file made.
function CisSecurityRebuild()
    rebuildAuthorized()
end

-- Resolve the deferred case: wait for whichever product persists state to
-- register its probe, then ask it whether it holds any rows. A store created
-- moments ago on a fresh install is empty, and an empty one means new.
if posture == nil then
    CreateThread(function()
        -- Only meaningful when something that persists state is installed.
        -- Asking a store that was never configured asks the driver about a
        -- table that does not exist, and the driver answers with an error the
        -- operator can do nothing about. This mirrors legacyByConfig(), which
        -- already treats an absent store as a definite answer.
        if not persistConfigured() then
            applyPosture('restrictive', 'no written config and no product that persists state is installed')
            authorized = {}
            return
        end
        -- 2s poll, 30s ceiling, on the REGISTRY rather than on a resource name.
        -- This library no longer knows what the table is called or which driver
        -- holds it, so the only honest thing to wait for is the product itself
        -- announcing that it can answer. The interval is the same as before
        -- because the thing being waited on is measured in seconds either way:
        -- another resource starting, which is not under this library's control,
        -- so a tighter poll buys nothing a maintainer can observe and costs a
        -- scheduler wakeup for the whole window.
        local deadline = GetGameTimer() + 30000
        while not CisRegistry.has('dataProbe') and GetGameTimer() < deadline do
            Wait(2000)
        end
        if not CisRegistry.has('dataProbe') then
            return
        end
        -- Asking, not guessing. `hasRows` yields on a real driver, so the call
        -- is wrapped: a driver that never answers would otherwise park this
        -- thread for the length of its timeout with the posture still
        -- undecided, which is the permissive reading and the pre-existing one.
        local ok, hasRows = CisRegistry.call('dataProbe', 'hasRows')
        if not ok then
            return
        end
        if hasRows then
            applyPosture('permissive', 'the installed store already holds persisted rows')
        else
            applyPosture('restrictive', 'no written config and the installed store is empty')
            authorized = {}
        end
        -- If the store never answers the install stays permissive, which is the
        -- same behaviour it has today. Refusing on a server we could not read
        -- would be the worse failure.
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
-- The most buckets one source may hold. A limiter is keyed by EVENT NAME, and
-- event names arrive off the wire -- so an unbounded map is a memory growth rate
-- a client controls. 256 is far more distinct events than any resource publishes
-- (the whole platform uses about a dozen) and is four orders of magnitude below
-- the point where the table itself is a problem.
local RATE_BUCKET_CAP = 256

local function rateOk(src, name, windowMs, maxHits)
    windowMs = windowMs or 1000
    maxHits = maxHits or 8
    local now = GetGameTimer()
    local perSrc = rates[src]
    if not perSrc then
        perSrc = {}
        rates[src] = perSrc
    end
    local bucket = perSrc[name]
    if not bucket or now - bucket.started >= windowMs then
        -- The cap is checked only when a NEW name appears. An existing key must
        -- keep working at whatever rate its caller asked for, because the cap is
        -- there to bound the number of KEYS, not to throttle a resource using a
        -- name it already owns.
        if not bucket and (rateCounts[src] or 0) >= RATE_BUCKET_CAP then
            -- Refuse rather than allocate. The window still applies to every
            -- existing bucket, so a client at the cap is throttled exactly as it
            -- would be by maxHits -- which is the point: it is bounded, and
            -- loudly, rather than quietly growing a table.
            return false
        end
        perSrc[name] = { started = now, hits = 1 }
        rateCounts[src] = (rateCounts[src] or 0) + 1
        return true
    end
    bucket.hits = bucket.hits + 1
    return bucket.hits <= maxHits
end

function CisRateOk(src, name, windowMs, maxHits)
    return rateOk(src, name, windowMs, maxHits)
end

--- How many rate buckets a source is currently holding.
---
--- Exposed rather than kept private because it is the answer to "is this server
--- being attacked right now?": a src sitting at RATE_BUCKET_CAP is a client
--- naming events that do not exist, and nothing else in the library shows that.
--- @param src number
--- @return number
function CisRateBucketCount(src)
    return rateCounts[src] or 0
end

-- ONCE PER (src, event) PER WINDOW, carrying the number dropped.
--
-- Every limited event used to log on the `cheating` channel with `ping = true`.
-- A client firing one event in a loop at 60Hz produced 52 console lines a second
-- and 52 Discord posts a second -- a denial of service against the operator's
-- console and against the webhook, produced by the very code that exists to
-- detect an attack. The operator ends up with the console scroll to explain what
-- is already sitting in their Discord channel.
--
-- The line is emitted when the window ROLLS rather than as the drops arrive, so
-- the count in it is the window's real total instead of "at least N so far". A
-- player who taps an event twice costs one line naming a count of 2; a script
-- firing 60 times a second costs one line naming 60. Both are visible and
-- neither is amplified.
--
-- Past a threshold it escalates to `CisSecurityReport`, which reaches the drop
-- handler and the webhook -- that is for the case it exists for, and one call
-- per window is not an amplification. The threshold is 100, which no UI
-- produces: it is roughly two seconds of a client firing as fast as the server
-- will accept.
local RATE_WARN_LIMIT = 100
local rateWarned = {}

local function warnRateLimited(src, name)
    local key = tostring(src) .. '\29' .. tostring(name)
    local state = rateWarned[key]
    local now = GetGameTimer()

    if state then
        if now - state.windowStarted >= 1000 then
            -- The window just rolled. ONE line, carrying the total it cost.
            CisLog('warn', ('rate limited %s from %s: %d events dropped in one second')
                :format(tostring(name), tostring(src), state.count), 'cheating')
            state.windowStarted = now
            state.count = 1
            state.escalated = false
            return
        end
        state.count = state.count + 1
        if state.count > RATE_WARN_LIMIT and not state.escalated then
            state.escalated = true
            CisSecurityReport(src, ('rate limited %s: %d events dropped in one second')
                :format(tostring(name), state.count))
        end
        return
    end

    rateWarned[key] = { count = 1, windowStarted = now, escalated = false }
end

-- A player who drops takes their rate buckets, their bucket COUNT and their
-- warning state. Server ids are reused, so a returning player would otherwise
-- inherit a throttle budget spent by the previous occupant of their id, and an
-- operator would see the previous occupant's flood re-reported against their own
-- name.
--
-- `rateCounts` is the tally behind that budget, and it has to go with the
-- buckets. It is the one entry that was missed, and it is a leak rather than a
-- correctness bug: each connecting player leaves one more number behind for the
-- life of the process, so a busy server accrues roughly 40kB a day at 10k
-- connects. Small, unbounded, and exactly the sort of thing that is invisible
-- until someone reads the memory profile a year later.
AddEventHandler('playerDropped', function()
    rates[source] = nil
    rateCounts[source] = nil
    local prefix = tostring(source) .. '\29'
    for k in pairs(rateWarned) do
        if k:sub(1, #prefix) == prefix then
            rateWarned[k] = nil
        end
    end
end)

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
-- event name -> { owner, self, handler, opts }
--
-- ONE BINDING PER NAME, and the ref is resolved on EVERY CALL.
--
-- `RegisterNetEvent` APPENDS. It does not replace, and it does not return the
-- previous handler. Calling it per registration meant a consumer that restarted
-- five times had five live handlers on the same event, and after a restart the
-- first four pointed at exports of a resource that no longer existed.
--
-- That is not four wasted calls. Each stale handler raised on every single
-- invocation, inside its own pcall, and each raise went to
-- `Logging.AutoLogError` tagged with the event name. So a resource that
-- restarts a few times turns one client action into a burst of identical error
-- lines -- and the operator reading that console is sent to go and fix the one
-- handler that is working correctly.
--
-- So the binding happens once, and what changes on a re-registration is the ref
-- it dispatches to. The handler is looked up per call rather than captured,
-- because a restarted resource exports NEW closures: capturing at bind time
-- would keep calling the previous instance, which is the same class of bug seen
-- in the capability registry.
local netBindings = {}

function CisNetOn(name, fn, opts)
    opts = opts or {}

    local resource, exportName, self, handler
    if type(fn) == 'string' then
        resource, exportName = fn:match('^([^:]+):(.+)$')
        if resource and exportName then
            -- pcall BECAUSE LOOKING UP A MISSING EXPORT RAISES.
            --
            -- `exports[resource]` is nil for a resource that is not running, so
            -- the old `self and self[exportName]` covered that case. It said
            -- nothing about a resource that IS running and does not export this
            -- name: indexing a FiveM resource export proxy with an unexported
            -- key RAISES "No such export X in resource Y" rather than returning
            -- nil. So the raise happened on the very line the guard was written
            -- to make safe, and escaped this function before the "registered
            -- nothing" refusal underneath could run -- propagating into the
            -- CONSUMER's own boot, where it can stop that consumer registering
            -- anything after this line.
            --
            -- Found on a live server: 29 distinct exports across 6 resources
            -- produced one of these each. A missing export is a refusal with a
            -- reason, not an exception, and that is what the block below now
            -- does -- the reason names the reference, so an operator looking at
            -- thirty registrations can see which one is wrong.
            local ok, fetched = pcall(function()
                local res = exports[resource]
                return res and res[exportName] or nil
            end)
            if ok then
                self = exports[resource]
                handler = fetched
            end
        end
        if not isCallableRef(handler) then
            handler = nil
        end
    elseif type(fn) == 'function' then
        resource = GetInvokingResource() or 'cis_libs'
        handler = fn
    end

    if not handler then
        -- The message has to name the REFERENCE, not just the type. A server
        -- can have thirty of these registrations and an operator reading one
        -- console line has to be able to tell which one is wrong. It used to
        -- report `not string` for a string reference whose export was missing,
        -- which reads as "a string is not allowed" -- when a string is exactly
        -- the supported form, and the export simply is not there.
        if type(fn) == 'string' and resource and exportName then
            Logging.Error(('Cis.net.on("%s") registered nothing: resource %q does '
                .. 'not export %q. Check the name, and that the resource is started.')
                :format(tostring(name), tostring(resource), tostring(exportName)))
        else
            Logging.Error(('Cis.net.on("%s") registered nothing: the handler must be a function '
                .. '(cis_libs only) or a "resource:export" reference, not %s')
                :format(tostring(name), type(fn)))
        end
        return false
    end

    local binding = netBindings[name]
    if binding then
        -- Same owner, re-registering: exactly what a `onResourceStart` handler
        -- after a restart looks like, and it replaces the ref rather than
        -- stacking a second one.
        if binding.owner == resource then
            binding.self = self
            binding.handler = handler
            binding.opts = opts
            binding.resource = resource
            binding.exportName = exportName
            return true
        end
        Logging.Warn(('cis_libs: net event %q is already bound by %s; %s was refused')
            :format(tostring(name), tostring(binding.owner), tostring(resource)))
        return false
    end

    netBindings[name] = {
        owner = resource, resource = resource, exportName = exportName,
        self = self, handler = handler, opts = opts,
    }

    RegisterNetEvent(name, function(...)
        local src = source
        if type(src) ~= 'number' or src <= 0 then
            return
        end
        local live = netBindings[name]
        if not live then
            return
        end
        -- Re-resolved per call: a restarted resource exports new closures, and a
        -- captured ref keeps calling the instance that no longer exists.
        local target = live.handler
        local exportsTable = live.self
        if live.exportName then
            exportsTable = exports[live.resource]
            target = exportsTable and exportsTable[live.exportName]
            if not isCallableRef(target) then
                -- The owning resource is gone, or has not finished restarting.
                -- Nothing to call. Returning quietly is right here: raising would
                -- put a stack trace on the console for every client action until
                -- the resource came back, which is a louder failure than the
                -- one being avoided.
                return
            end
        end
        if not isCallableRef(target) then
            return
        end
        if not rateOk(src, name, live.opts.windowMs, live.opts.maxHits) then
            -- ONE WARNING PER (src, name) PER WINDOW, with the number dropped.
            -- Logging every limited event was a denial of service against the
            -- operator's console AND against the webhook, produced by the very
            -- code that exists to detect an attack: 52 lines a second from one
            -- client firing one event in a loop.
            warnRateLimited(src, name)
            return
        end
        local ok, err
        if exportsTable then
            ok, err = pcall(target, exportsTable, src, ...)
        else
            ok, err = pcall(target, src, ...)
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
    -- A custom drop handler is a FUNCTION, and a function cannot be sent
    -- across the exports boundary -- so `Security.DropPlayer` is a boolean here
    -- and the code arrives as a capability. The boolean is still honoured, and
    -- the capability is consulted first: an operator who wrote a handler meant
    -- it, and silently preferring the generic kick would make their handler
    -- look broken rather than absent.
    local ok, custom = CisRegistry.call('security', 'drop', src, reason)
    if ok then
        return true
    end
    if Security and Security.DropPlayer then
        DropPlayer(src, DEFAULT_DROP_MESSAGE)
        return true
    end
    return false
end

-- L-C24 · THE RESULT IS RETURNED, AND `opts` IS PASSED THROUGH.
--
-- Both were dropped. The result is the worse of the two: an export that returns
-- nothing whatever happened cannot be told apart from a REFUSAL, so a caller
-- registering a handler that was never registered had no way to find out. That
-- is the same silent-success shape as a callback that registers nothing and
-- reports success.
--
-- `opts` matters just as much in practice and much less visibly: the rate limit
-- is set there, so a consumer passing `{maxHits = 2}` was silently ignored and
-- got the default 8. A security control the caller believes they set and did not.
exports('SecureNetOn', function(name, fn, opts)
    return CisNetOn(name, fn, opts)
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

-- A resource that stops takes its net bindings with it (L-C7).
--
-- Not tidiness. The binding is gone from this table, but `RegisterNetEvent`
-- cannot be undone -- FiveM offers no unregister -- so the event stays bound for
-- the life of the process and now dispatches to `netBindings[name]`, which is
-- nil, and returns. That is the honest outcome: a stopped resource's event
-- accepts connections and does nothing, rather than raising on every one of
-- them. What MUST happen is that the name becomes bindable again, so a resource
-- that stops and restarts re-registers instead of being told the name is taken
-- by a resource that no longer exists.
AddEventHandler('onResourceStop', function(resource)
    for name, binding in pairs(netBindings) do
        if binding.owner == resource then
            netBindings[name] = nil
        end
    end
end)
