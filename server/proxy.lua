-- Capability forwards.
--
-- This file is the reason the split did not break a single consumer.
--
-- Every export below used to be defined by the code that did the work: a
-- database export was a database call, a door export was a door operation, a
-- framework export reached into ESX or QBCore. Now each one is a forward --
-- the same name, the same arguments, the same return shape, resolving to
-- whichever resource registered that capability.
--
-- A consumer's manifest line does not change:
--
--     shared_script '@cis_libs/init.lua'
--     local rows = Cis.db.query('SELECT 1')
--
-- ...and that still works, because `Cis.db.query` still resolves to
-- `exports['cis_libs']:DbQuery`, and `DbQuery` is below. What changed is that
-- the code behind it now lives in a product, and that this library is
-- installable, runnable and useful with none of those products present.
--
-- Two rules run through every forward below:
--
--   1. NEVER THROW. A provider is another resource's code. Its failure is
--      reported as a value, because a consumer that gets an exception gets it
--      in whatever thread it happened to call from.
--   2. NEVER SILENTLY SUBSTITUTE. When no provider is registered, these
--      return the same value the old code returned on failure -- nil for a
--      query, false for a mutation, false+reason for a refusal -- and warn ONCE
--      per capability. A library that returns nil forever without saying why is
--      the single most expensive thing it can do to its own support burden.

local warned = {}

-- One line per missing capability, then silence. A per-call warning on a hot
-- path is a denial-of-service against the operator's console, and a server that
-- has run for a year should not be able to drown its own log.
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

-- The generic forward. Returns nil (or false) plus a reason on failure, and
-- hands back every value the provider produced on success.
--
-- `onFail` is this slot's failure shape, and the shapes differ. A count answers
-- 0, a mutation answers false, a transaction answers false AND a reason, and a
-- read answers nil -- and those are the shapes consumers' existing `if not x`
-- tests were written against. Pass a function when the failure needs more than
-- one value; it is called, not returned.
local function forward(slot, onFail, ...)
    local results = table.pack(CisRegistry.call(slot, ...))
    if not results[1] then
        warnOnce(slot, (...), results[2])
        if type(onFail) == 'function' then
            return onFail()
        end
        if onFail ~= nil then
            return onFail
        end
        return nil, results[2]
    end
    return table.unpack(results, 2, results.n)
end

-- ===========================================================================
--  CONFIGURATION
--
--  The one place another resource hands cis_libs its configuration, because
--  configuration is a product decision and a library has no business owning an
--  editable file. Tables cross the boundary by value, so this works; FUNCTIONS
--  DO NOT, which is why `Security.DropPlayer` arrives as the boolean `true` and
--  the actual handler is registered as a capability below.
-- ===========================================================================

exports('SetConfig', function(config, security, discord)
    -- FIRST SUPPLIER WINS, and the loser is told. Two products both believing
    -- they own the configuration is a real failure mode and it is invisible
    -- until something is mysteriously not taking effect; naming the resource
    -- that lost turns it into a console line.
    --
    -- cis_libs's own built-in defaults are NOT a supplier. They are the floor,
    -- set before anything can call this, and a product replacing them is the
    -- intended path rather than a conflict.
    --
    -- THE SAME RESOURCE IS NOT A CONFLICT. It has to be allowed, and the reason
    -- is not politeness: this export is called again on every
    -- `onResourceStart('cis_libs')`, because a restarted cis_libs loses every
    -- config value cis_core supplied to it. Refusing the owner on the second
    -- call meant a restarted cis_libs silently kept the defaults -- an empty
    -- allow-list, an empty webhook table -- while cis_core's console said the
    -- configuration had been supplied. The refusal is what made it invisible.
    local supplier = GetInvokingResource() or 'cis_libs'
    if Config and Config.__owned and Config.__owner ~= 'cis_libs' and Config.__owner ~= supplier then
        return false, ('configuration was already supplied by %s'):format(tostring(Config.__owner))
    end
    if type(config) == 'table' then
        -- Merged over the built-in defaults key by key, so an operator who set
        -- one leaf of Framework.Target keeps the rest of that table rather than
        -- inheriting a table with a single key in it.
        Config = CisDefaults.merge(CisDefaults.config(), CisDefaults.sanitize(config))
    end
    if type(security) == 'table' then
        -- Deliberately NOT merged with the default Security. An operator who
        -- sets AuthorizedResources means exactly the list they wrote, and a
        -- default entry silently retained next to theirs would be an
        -- authorisation they did not intend to grant.
        Security = CisDefaults.sanitize(security)
        Security.EventPrefix = Security.EventPrefix or 'cis_libs'
        Security.AuthorizedResources = Security.AuthorizedResources or {}
    end
    if type(discord) == 'table' then
        -- The webhook table is configuration like any other and has to arrive the
        -- same way. It used to be read straight out of a `DiscordConfig` global
        -- belonging to whichever resource loaded the config file -- which is a
        -- different Lua state from this one, so the lookup was always nil and
        -- every outbound log line was silently discarded. It is held here, on the
        -- server only, and never reaches a client: `GetClientConfig` has its own
        -- whitelist and this is not on it.
        DiscordConfig = CisDefaults.sanitize(discord)
    end
    Config.__owned = true
    Config.__owner = GetInvokingResource() or 'cis_libs'
    -- The allow-list is DERIVED from Security, so replacing Security has to
    -- rebuild it. Without this the operator's AuthorizedResources was read,
    -- stored, printed and never enforced. No-op when no security table arrived,
    -- so a config-only SetConfig cannot silently re-decide the posture.
    if type(security) == 'table' and CisSecurityRebuild then
        CisSecurityRebuild()
    end
    Logging.Info(('cis_libs: configuration supplied by %s'):format(tostring(Config.__owner)))
    return true
end)

--- The outbound/webhook configuration, for the capability that does the
--- sending. Server realm only, and it is a secret: it holds webhook URLs, which
--- is exactly why it is not on the client whitelist and not in the debug
--- command's capability table.
exports('GetDiscordConfig', function()
    if GetInvokingResource() == 'cis_libs' then
        return DiscordConfig
    end
    return DiscordConfig or {}
end)

--- Register a capability provider. The form is ALWAYS the string
--- "resource:Export", never a function, because a function cannot be sent
--- across the exports boundary -- it arrives as nil and the slot simply looks
--- empty, which is the failure mode this signature exists to make impossible
--- to hit by accident.
exports('RegisterCapability', function(slot, provider)
    local ok, reason = CisRegistry.register(slot, provider)
    if not ok then
        Logging.Warn(('cis_libs: capability %q refused: %s'):format(tostring(slot), tostring(reason)))
        return false, reason
    end
    Logging.Info(('cis_libs: capability %q <- %s'):format(tostring(slot), tostring(CisRegistry.owner(slot))))
    return true
end)

--- Release a capability, for a resource that is shutting down or handing over.
--- Only the owner may release its own slot, so one product stopping cannot
--- blank a capability another product is still serving.
exports('UnregisterCapability', function(slot)
    local resource = GetInvokingResource()
    if not CisRegistry.unregister(slot, resource) then
        return false
    end
    return true
end)

--- What is registered, what is not, and who owns what. This is the answer to
--- "why is the database nil", and it is the first thing a support thread needs.
exports('GetCapabilities', function()
    return CisRegistry.snapshot()
end)

-- A stopped resource's exports are gone. Releasing its slots turns every later
-- call into an honest "no provider registered" and lets the restarted resource
-- register again; the warning latch is cleared so the next failure is reported.
AddEventHandler('onResourceStop', function(resource)
    for _, slot in ipairs(CisRegistry.releaseOwner(resource)) do
        warned = {}
        Logging.Warn(('cis_libs: capability %q released: %s stopped'):format(slot, resource))
    end
    -- The configuration owner is released with everything else it held. cis_libs
    -- itself restarting must not leave the next cis_core looking like a SECOND
    -- supplier and being refused for a config it is entitled to supply.
    if Config and Config.__owner == resource then
        Config.__owned = nil
        Config.__owner = nil
    end
end)

--- The frameworks and drivers this library knows how to detect, copied out of
--- the pure detection module.
---
--- Shared rather than duplicated on purpose. The ordering of that table is
--- load-bearing -- a qbx_core server also has qb-* resources on disk, and a
--- naive "is anything started" scan reports whichever it finds first -- so a
--- second copy in a product is a second thing to keep in step, and a product
--- that disagrees with the debug output about what is running is worse than
--- either being wrong alone.
exports('GetKnownTargets', function()
    return {
        frameworks = CisDetect and CisDetect.FRAMEWORKS or {},
        databases = CisDetect and CisDetect.DATABASES or {},
    }
end)

-- ===========================================================================
--  DETECTION
--
--  The DECISION lives in the pure module above; the PROBING lives here, and
--  that split is the whole design. The decision takes `isStarted`, `version`
--  and `probe` as injected functions, which is what makes it unit-testable
--  under fengari with no FiveM server at all. A function cannot be SENT across
--  the exports boundary, so a product cannot inject its own probes -- which
--  means either every product reimplements the probing (four copies of the one
--  place that gets a framework's export name subtly wrong) or the probing lives
--  where the natives are. It lives here.
--
--  What a product owns is the CONFIGURATION -- what the operator wrote -- and
--  the abstraction over whatever comes back. What this owns is asking the
--  server what it is actually running, once, in one place.
-- ===========================================================================

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

-- MEASURED: calling a missing export on a started resource RAISES, so a probe
-- is an honest existence test rather than a guess. Wrapped because the raise
-- is the expected outcome for a resource that is not the thing it claims to be.
local function probe(name, exportName)
    if not exportName then
        return false
    end
    local ok, fn = pcall(function()
        return exports[name][exportName]
    end)
    return ok and fn ~= nil
end

--- Decide which framework this server runs. Returns
--- { name, resource, version, how, reason }.
---
--- `reason` is the point of the whole call. A server that fell through to
--- standalone and a server that is correctly standalone are indistinguishable
--- from the name alone, and that ambiguity is what produced the original bug:
--- a bridge that reported itself ready and then answered nil for every player.
exports('DetectFramework', function(configured, custom)
    return CisDetect.framework(configured, custom, isStarted, resourceVersion, probe)
end)

--- Decide which database driver is in use. Same return shape.
exports('DetectDatabase', function(configured)
    return CisDetect.database(configured, isStarted, resourceVersion)
end)

-- ===========================================================================
--  FRAMEWORK  ->  cis_core
--
--  Registered as cis_core:CisCoreFramework, whose table answers get / player /
--  notify / loaded. Until it registers, these return the standalone answers
--  they returned before any framework existed.
-- ===========================================================================

-- The normalized framework API TABLE, which is what every caller actually
-- wants: `fw.GetPlayer(src)`, `fw.Notify(src, msg, kind)`.
--
-- It used to return `CisRegistry.resolve('framework')`, which is the provider's
-- export -- a callable, or a callable table once it has crossed the boundary --
-- and NOT the table those methods live in. Every caller then did
-- `fw.GetPlayer(src)` on a function, got nil, and had no way to tell that from
-- "this player has no framework record". api.lua documents a table, and the
-- source returned something else.
exports('GetFramework', function()
    if not CisReadyState.wait(15000) then
        return nil
    end
    return CisRegistry.methods('framework')
end)

exports('GetNormalizedPlayer', function(src)
    return forward('framework', nil, 'NormalizedPlayer', src)
end)

exports('Notify', function(src, message, kind)
    if CisRegistry.has('framework') then
        return forward('framework', nil, 'Notify', src, message, kind)
    end
    -- No framework: cis_libs delivers the notification itself rather than
    -- dropping it. The old standalone path fell back to the native feed on the
    -- client, and a server with no framework should not go mute.
    TriggerClientEvent('cis_libs:client:showNotification', src, message, kind)
end)

-- ===========================================================================
--  DATABASE  ->  cis_bridge (one adapter per driver)
--
--  The await-style pair yield on the far side and answer nil on timeout, which
--  is the contract every consumer already codes against: a nil here means
--  "timed out or no driver", NOT "no rows". Use Single or Scalar to ask about
--  emptiness. That distinction is why these are forwards and not wrappers that
--  normalise the nil away -- normalising it would have been a silent behaviour
--  change to every installed server.
-- ===========================================================================

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

-- The only asymmetry in this block, preserved deliberately: Transaction takes
-- a LIST of queries, not (sql, params), so it cannot go through the same shape
-- as the five above. It is also the only capability that refuses loudly rather
-- than yielding, because a driver without transaction support would otherwise
-- hold the caller for the full timeout and then answer nil -- indistinguishable
-- from a lost query. `false, <reason>` is answerable; nil is not.
exports('DbTransaction', function(queries)
    return forward('database', function()
        return false, 'no database provider is registered; transactions are unavailable'
    end, 'transaction', queries)
end)

-- Callback-style twins, kept because they are published in api.lua and are in
-- use. The callback is a FUNCTION, so it cannot be sent across the boundary --
-- which is why these are only useful from inside cis_libs or from a resource
-- that receives the callable back. The await-style five above are the form that
-- works from a consumer, and the documentation says so.
exports('DatabaseExecute', function(query, params, cb)
    local rows = forward('database', nil, 'query', query, params)
    if cb then cb(rows) end
    return rows
end)

exports('DatabaseFetchAll', function(query, params, cb)
    local rows = forward('database', nil, 'query', query, params)
    if cb then cb(rows) end
    return rows
end)

exports('DatabaseFetchOne', function(query, params, cb)
    local row = forward('database', nil, 'single', query, params)
    if cb then cb(row) end
    return row
end)

exports('DatabaseInsert', function(sql, params, cb)
    local id = forward('database', nil, 'insert', sql, params)
    if cb then cb(id) end
    return id
end)

exports('DatabaseUpdate', function(sql, params, cb)
    local n = forward('database', nil, 'update', sql, params)
    if cb then cb(n) end
    return n
end)

exports('DatabaseDelete', function(sql, params, cb)
    local n = forward('database', nil, 'update', sql, params)
    if cb then cb(n) end
    return n
end)

-- ===========================================================================
--  INVENTORY  ->  cis_core
-- ===========================================================================

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

-- ===========================================================================
--  DOORS  ->  cis_keys
--
--  Registration is authorised and registration is mutation. These forwards
--  enforce the allow-list BEFORE the capability is consulted, so an
--  unauthorised resource cannot even reach a provider -- which is stronger than
--  checking inside the provider, because a provider added later inherits the
--  check rather than having to remember it.
-- ===========================================================================

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

-- BreakDoor and FixDoor are NOT allow-list gated here, matching the behaviour
-- they had before the split: they were reachable by any allow-listed resource
-- through the export, and the net-event path was already server-only. cis_keys
-- owns the permission model now and this library is not the place to second-
-- guess it; what this library does guarantee is that the call is forwarded and
-- its nil return is preserved.
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

-- nil is "no such door" and false is "that door is unlocked". Deliberately
-- distinct, and deliberately preserved: a consumer that collapses the two
-- cannot tell a typo'd door id from an unlocked one.
exports('GetDoorState', function(doorId)
    return forward('doors', nil, 'state', doorId)
end)

exports('GetAllDoorData', function()
    return forward('doors', nil, 'all')
end)

-- ===========================================================================
--  DISCORD  ->  cis_bridge
-- ===========================================================================

exports('SendDiscordLog', function(webhookURL, title, message, color, ping)
    return forward('discord', nil, 'log', webhookURL, title, message, color, ping)
end)

exports('GetDiscordQueueDepth', function()
    return forward('discord', 0, 'depth')
end)

-- ===========================================================================
--  SECURITY HANDLER
--
--  `Security.DropPlayer` is a boolean here and a FUNCTION in the product that
--  ships the config, because a function cannot cross the boundary. The handler
--  arrives as a capability instead, and this is the only place it is called --
--  so there is exactly one line to audit for "can a player be dropped, and by
--  whose code".
-- ===========================================================================

exports('SetDropPlayerHandler', function(provider)
    return CisRegistry.register('security', provider)
end)

-- ===========================================================================
--  PUBLISHING
--
--  The event NAMES belong to this library, and the FACTS belong to whichever
--  product detected them. That split is not tidiness: a net event name is part
--  of the published contract, and a name that moved to another resource is a
--  name that resource can rename without anyone noticing until a consumer
--  silently stops hearing about it.
--
--  So `cis_libs:jobUpdated` is fired here, by a product calling in, rather than
--  by a product calling its own event. A consumer listening for it keeps
--  working whichever framework is installed, and a framework upgrade cannot
--  break it.
-- ===========================================================================

exports('PublishJobUpdate', function(job, src)
    if type(job) ~= 'table' then
        return false, 'job must be a table'
    end
    -- The job histogram is a cis_libs feature and stays one: it is a pure
    -- in-memory structure, it owns no table, and `GetOnlineJobCount` is
    -- published. Feeding it is a product's job; keeping it is this library's.
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
    -- Client-local, not broadcast. A player-load is a fact about one player's
    -- client, and sending it to the whole server would tell every client about
    -- every other player's job change.
    if src then
        TriggerClientEvent('cis_libs:playerLoaded', src, job)
    end
    return true
end)

-- The client's half of the same conversation. Both directions are owned here so
-- the pair moves together: if the push name ever changed, the request name would
-- change with it rather than drifting into two resources that have to be
-- updated in the same edit.
--
-- Rate-limited and source-checked by CisNetOn rather than a bare RegisterNetEvent,
-- because this arrives from a client on every inventory open and an
-- unthrottled handler here is a request amplifier.
CisNetOn('cis_libs:server:inventorySync', function(src)
    exports['cis_libs']:PublishInventory(src)
end)

-- The inventory snapshot push. The wire format and the event name are this
-- library's; deciding WHEN to push is the inventory service's, because only it
-- knows when a player object has come into existence.
-- Tell ONE client something, by the library's own notification event.
--
-- A product asking to show a notification must not hardcode this library's
-- event name: a name hardcoded in a product is a name this library can never
-- rename. Routing it through an export keeps the wire -- the event name, the
-- payload shape, the fallback -- in the one place that owns it.
exports('NotifyClient', function(src, message, kind)
    if type(src) ~= 'number' or src <= 0 then
        return false
    end
    TriggerClientEvent('cis_libs:client:showNotification', src, message, kind)
    return true
end)

exports('PublishInventory', function(src)
    if type(src) ~= 'number' or src <= 0 then
        return false
    end
    local ok, snapshot = CisRegistry.call('inventory', 'snapshot', src)
    if not ok then
        return false
    end
    TriggerClientEvent('cis_libs:client:inventory', src, snapshot)
    return true
end)
