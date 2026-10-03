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

-- Notification bounds, stated once so the numbers are findable from the export
-- and not scattered through it. A notification is a courtesy, not a channel, so
-- both limits are generous: they exist to stop a runaway loop, not to ration.
local MAX_NOTIFY_LENGTH = 512
local NOTIFY_MAX_PER_SECOND = 10

-- THE ONE DELIVERY PATH. `Notify` with no framework behind it and
-- `NotifyClient` are the same act -- put one string in front of one player --
-- so they share one set of guards rather than each carrying its own.
--
-- They did not, and that is the defect this exists to remove: `NotifyClient`
-- grew a rate limit and `Notify`'s fallback never did, so the bounded path was
-- the rarer one. A guard that is written twice is a guard that is fixed once.
--
-- The checks, in order, because the reason a caller gets names the first thing
-- that was wrong:
--
--   * src is a number greater than zero. Zero is the console, negative is a
--     broadcast, and neither is a player. `'1'` is a string, and a string is the
--     shape a caller gets from JSON or a config file, where it looks fine.
--   * src is a player who is here. A plausible id is not a player: firing at
--     somebody who left is a success the caller is told about and nothing else,
--     which is the worst of both -- it looks delivered and reaches nobody.
--   * the message is length-capped. It crosses the wire as text and is rendered
--     on a screen the server does not own. Truncated rather than refused: a long
--     notification is a mistake rather than an attack, and refusing it outright
--     would break the caller without saying what was wrong.
--   * the (src, caller) pair is rate-limited. Unbounded, this is a resource
--     spending a server's event budget on one player at will. Keyed by caller as
--     well as target so one noisy resource cannot exhaust the budget that
--     another resource's legitimate notifications to the same player share.
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
--
-- Three events change who is trusted with what, and all three were visible only
-- as a console line: a capability registering or being released, and the
-- configuration being replaced. A console line is a SNAPSHOT. The question an
-- operator actually asks is "when did this change and WHO changed it", and a
-- snapshot cannot answer it -- by the time anybody thinks to ask, the line has
-- scrolled away.
--
-- Written to a file, one line per event, ALWAYS -- including refusals, which is
-- the half that matters. A capability that was REFUSED is precisely the thing
-- somebody will want to find later.
--
-- Best-effort by design. `SaveResourceFile` can fail (read-only data directory,
-- permissions), and an audit trail that takes the library down when it cannot be
-- written is worse than no audit trail: it would turn a disk problem into an
-- outage. So a failure says so ONCE and then goes quiet.
--
-- DECLARED HERE, ABOVE SetConfig, because Lua binds an upvalue where the
-- enclosing function is DEFINED: a `local audit` further down this file is nil
-- while SetConfig is compiled, and the call raises on the first config rather
-- than at load -- the worst possible time to discover it.
local auditFailures = 0
local auditText = ''

local function audit(event, detail)
    if auditFailures > 0 then
        return
    end
    auditText = auditText .. ('%s cis_libs %s %s\n'):format(
        os.date('%Y-%m-%dT%H:%M:%S'), event, detail or '')
    -- WHOLE-FILE REWRITE, every time. There is no append mode here, and that is
    -- worth stating rather than discovering: `SaveResourceFile`'s fourth argument
    -- is the INDENT, not a flag -- passing `-1` means "no indent" and overwrites.
    -- An audit log written that way keeps exactly one line, which is the one
    -- thing an audit log must never do.
    --
    -- Accumulating in memory and rewriting the lot is the cheap way to get real
    -- append semantics: the volume is a handful of lines per boot, so the write
    -- cost is irrelevant next to the correctness of the record. Bounded by the
    -- number of capability changes, which is small and human-scale.
    local okWrite = pcall(function()
        SaveResourceFile(GetCurrentResourceName(), 'audit.log', auditText, -1)
    end)
    if not okWrite then
        auditFailures = 1
        Logging.Warn('cis_libs: cannot write the audit log; capability changes will '
            .. 'be reported to the console only')
    end
end

-- A1 · THE CONTRACT VERSION THIS LIBRARY IMPLEMENTS, and the reader for the
-- version a product claims.
--
-- api.lua states `contract = { major = 1, minor = 0 }` while the product version
-- is 2.1.0, and those are DIFFERENT numbers answering different questions: the
-- contract is the compatibility promise between cis_libs and the products that
-- register capabilities, the product version is the library's own release. A
-- provider is refused on a MAJOR contract mismatch, because that is the one
-- that means "the shapes no longer mean the same thing".
--
-- Read from the CALLER's fxmanifest, which is the only place a product can
-- declare it. `GetResourceMetadata(resource, 'field', 0)` is the standard way to
-- read a custom manifest field in FiveM.
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
        -- THE REFUSAL STATES THE FIX. Two ways to change the supplier, and the
        -- caller has to be able to tell them apart: restart cis_libs, which
        -- rebuilds Config with no owner, or have the named resource supply it
        -- again. Anything else -- "permission denied" with no way forward -- is
        -- the ambiguity this library refuses everywhere else.
        return false, ('configuration was already supplied by %s; only that resource can '
            .. 'replace it. To hand it to someone else, restart cis_libs, or stop and '
            .. 'restart %s so it supplies the configuration again.')
            :format(tostring(Config.__owner), tostring(Config.__owner))
    end
    if type(config) == 'table' then
        -- Merged over the built-in defaults key by key, so an operator who set
        -- one leaf of Framework.Target keeps the rest of that table rather than
        -- inheriting a table with a single key in it.
        --
        -- MERGED AND THEN VALIDATED, in that order, and nothing is assigned
        -- until it passes. The config arrives across the exports boundary from
        -- another resource and none of its values were checked, so the failure
        -- modes were all silent: `CallbackTimeout = -1` makes every callback
        -- wait forever and then report a timeout that never came from a timeout;
        -- `UpdateInterval.Player = 0` is a client loop at the frame rate; a
        -- misspelled `AimingCheckType` falls through to the default, so aiming
        -- reads false almost always and looks like a game bug rather than a
        -- typo. None of them raises where the mistake was made.
        --
        -- VALIDATED ON A COPY. Half-applying a policy is worse than rejecting
        -- one: the operator cannot tell which half took effect, and the console
        -- goes on saying the configuration was supplied.
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
    -- EVERY CONNECTED CLIENT IS TOLD, not just the ones that have not fetched
    -- yet.
    --
    -- The client payload was pushed once, in answer to
    -- `cis_libs:server:getData`, which a client fires once at connect. Anything
    -- SetConfig changed after that point reached nobody: every connected client
    -- carried on running the config it had fetched, on a server whose operator
    -- had just told it something different. From the outside, "my config is being
    -- ignored" and "my config arrived too late" are the same bug report.
    --
    -- Re-pushed rather than cached-and-diffed: SetConfig runs a handful of times
    -- in a server's life (boot, and once per cis_libs restart), the payload is a
    -- few hundred bytes, and a diff would have to be right about which keys a
    -- client actually holds -- a client that connected between two SetConfigs
    -- would be left with a half-updated config and no way to tell.
    --
    -- Guarded on the natives rather than assumed: this file is loaded in the
    -- harness and by a consumer's VM in tests, where TriggerClientEvent may not
    -- exist, and a missing native must not turn a config call into an error.
    if CisConfigUtil and TriggerClientEvent then
        TriggerClientEvent('cis_libs:client:getData', -1,
            CisConfigUtil.clientPayload(Config, Security))
    end
    Logging.Info(('cis_libs: configuration supplied by %s'):format(tostring(Config.__owner)))
    -- A2 · Recorded, because this is the most consequential event the library
    -- has: the configuration IS the security policy. "Why did the allow-list
    -- change" has to be answerable after the fact, not only by whoever happens
    -- to still have the console scrollback.
    audit('config-supplied', ('owner=%s'):format(tostring(Config.__owner)))
    return true
end)

--- The outbound/webhook configuration, for the capability that does the
--- sending. Server realm only, and it is a secret: it holds webhook URLs, which
--- is exactly why it is not on the client whitelist and not in the debug
--- command's capability table.
---
--- A WEBHOOK URL IS A BEARER SECRET. Anyone holding one can post to the channel
--- as this server, and the channels configured here carry anti-cheat reports
--- naming players -- so a leak converts every ban into a support thread, which
--- is where the roadmap puts most of the running cost.
---
--- This export used to read:
---
---     if GetInvokingResource() == 'cis_libs' then return DiscordConfig end
---     return DiscordConfig or {}
---
--- and the `or {}` was not a redaction. With a config present -- the normal
--- state on any server that logs -- BOTH branches returned the full table, so
--- the check guarded nothing. It had the shape of a lock that opens when you
--- look at it, which is the kind of bug that survives review because every line
--- of it looks correct.
---
--- A foreign caller now gets an EMPTY table, always. Not nil: the capability
--- this export feeds has to keep working against an absent config rather than
--- raise on an index of nil, and an empty table and a nil are indistinguishable
--- to it while a populated one is not.
exports('GetDiscordConfig', function()
    if GetInvokingResource() == 'cis_libs' then
        return DiscordConfig or {}
    end
    -- Nothing, and it looks exactly like nothing. Returning nil here would tell
    -- a probing resource "this server has no Discord config", which is a fact
    -- about the install worth not handing out alongside every other answer.
    return {}
end)

--- Register a capability provider. The form is ALWAYS the string
--- "resource:Export", never a function, because a function cannot be sent
--- across the exports boundary -- it arrives as nil and the slot simply looks
--- empty, which is the failure mode this signature exists to make impossible
--- to hit by accident.
exports('RegisterCapability', function(slot, provider)
    -- A1 · THE CONTRACT VERSION IS CHECKED BEFORE ANYTHING ELSE HAPPENS.
    --
    -- A product declares `cis_libs_contract '2.1'` in its fxmanifest. A MAJOR
    -- mismatch is refused: the contract is the promise that a slot's method
    -- names and argument shapes mean the same thing on both sides, and a 3.x
    -- product registering into a 2.x cis_libs is exactly the case where they do
    -- not. Registering anyway produces a call that returns the wrong value for
    -- the right reason -- the hardest kind of bug to diagnose and the easiest to
    -- prevent.
    --
    -- MINOR mismatches are allowed, deliberately: a 2.1 product works against
    -- 2.0 and the other way round, because a minor bump only ADDS.
    --
    -- A product that declares nothing is allowed too. cis_libs cannot check a
    -- version that was never claimed, and refusing unknown would mean refusing
    -- every third-party resource that wants to fill a slot.
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

    local ok, reason = CisRegistry.register(slot, provider)
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
--- Only the owner may release its own slot, so one product stopping cannot
--- blank a capability another product is still serving.
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

--- A4 · REVOKE A CAPABILITY WITHOUT A RESTART.
---
--- The only way to recover from a resource that took a slot it should not have
--- was to restart cis_libs, which blanks every slot and therefore every
--- capability until each product re-registers. On a live server that is every
--- product at once, for as long as it takes them to come back.
---
--- DELIBERATELY A CONSOLE COMMAND AND NOT AN EXPORT. An export would put the
--- power to strip a capability in the hands of any resource on the server, which
--- is the exact authority S1 spent this batch removing. A console command runs
--- with no invoking resource, so there is no caller to authorise -- which is
--- exactly why it is safe here and would not be as an export.
---
--- RESTRICTED, AND THE SOURCE IS CHECKED ANYWAY. Those are two halves of one
--- property, not belt and braces for its own sake. Without the restricted flag
--- FiveM accepts the command from a client, and an unknown client command is
--- forwarded to the server with the player's server id as the source -- so a
--- player could strip `security`, `database` or `framework` from a running server
--- out of their own chat. The flag is the platform's half; the `src` check is
--- this library's, and it holds even if the flag is not what it was assumed to
--- be. `cis_debug` in server/initialize.lua is registered the same way.
RegisterCommand('cis_force_unregister', function(src, args)
    if src ~= 0 then
        print('cis_libs: cis_force_unregister is a server console command. '
            .. 'Run it from the txAdmin console or the server terminal.')
        -- Audited, because the audit log is how an owner finds out that somebody
        -- was trying. A refusal that prints and is never recorded is a refusal
        -- that leaves no trace, which is the same as no refusal at all as far as
        -- the next investigation is concerned.
        audit('capability-revoke-refused', ('slot=%s caller=%s')
            :format(tostring((args and args[1]) or '?'), tostring(src)))
        return
    end
    -- FiveM passes (source, args, argString): `args` is a TABLE of the words
    -- after the command name. Reading it as a table rather than as varargs is
    -- the signature that actually exists, and guessing wrong here is a syntax
    -- error in the middle of a file that has nothing to do with commands.
    local slot = args and args[1]
    if type(slot) ~= 'string' or not CisRegistry.SLOTS[slot] then
        print(('usage: cis_force_unregister <slot>. known slots: %s')
            :format(table.concat(sortedSlotNames(), ', ')))
        return
    end
    local previous = CisRegistry.owner(slot)
    -- No owner check, deliberately: this is the override, and that is the whole
    -- reason it exists.
    if not CisRegistry.unregister(slot) then
        print(('cis_libs: %q is not registered, so there is nothing to revoke'):format(slot))
        return
    end
    print(('cis_libs: revoked %q (was held by %s); the provider may register it again.')
        :format(slot, tostring(previous)))
    audit('capability-force-released', ('slot=%s owner=%s'):format(slot, tostring(previous)))
end, true)

--- What is registered, what is not, and who owns what. This is the answer to
--- "why is the database nil", and it is the first thing a support thread needs.
exports('GetCapabilities', function()
    return CisRegistry.snapshot()
end)

--- T9. Wait for a slot instead of answering nil during boot.
---
--- This is what makes start order irrelevant. `Cis.db.*` used to answer "no
--- provider registered" for the whole window between cis_libs starting and the
--- database adapter starting, and a consumer that read that as "there is no
--- database" would cache it. Waiting costs one coroutine park and turns a
--- silent nil into a bounded, reported answer.
exports('WaitCapability', function(slot, timeoutMs)
    return CisRegistry.wait(slot, timeoutMs)
end)

-- A stopped resource's exports are gone. Releasing its slots turns every later
-- call into an honest "no provider registered" and lets the restarted resource
-- register again; the warning latch is cleared so the next failure is reported.
AddEventHandler('onResourceStop', function(resource)
    for _, slot in ipairs(CisRegistry.releaseOwner(resource)) do
        warned = {}
        Logging.Warn(('cis_libs: capability %q released: %s stopped'):format(slot, resource))
    end
    -- THE CONFIGURATION OWNER IS DELIBERATELY NOT RELEASED HERE.
    --
    -- It used to be cleared alongside the capability slots, and that turned
    -- every restart of the config supplier into a window in which the security
    -- policy had no owner. An operator restarts cis_core to pick up a fix, and
    -- while it is down any resource that calls SetConfig is accepted as the
    -- FIRST supplier -- free to hand over `AuthorizedResources = {}`,
    -- `DropPlayer = false`, and its own webhook URLs, with the console then
    -- showing it as the legitimate supplier.
    --
    -- Nothing legitimate is lost by leaving it. A restarted cis_libs rebuilds
    -- its Config table from the defaults, which has no owner at all, and the
    -- same resource may always supply the configuration again (the same-owner
    -- path above, added for L-C6). So the owner only has to be cleared by
    -- restarting cis_libs, which is deliberate rather than incidental.
    --
    -- What it costs is the ability to move the configuration to a different
    -- resource without restarting the library, and that is the right trade: the
    -- operator takes one action they understand, and no resource can take the
    -- policy by racing a restart.
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
    -- dropping it. A server with no framework should not go mute.
    --
    -- And it delivers it through the SAME guarded path as NotifyClient, so a
    -- fallback cannot be the unbounded one. Which it was, until this call went
    -- through `deliverNotification` like its twin.
    return deliverNotification(src, message, kind)
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

-- THE THREE PUBLISHERS ARE NOT ALL THE SAME KIND OF CALL, and gating them as if
-- they were would break the platform to fix a nuisance.
--
-- Two of them MUTATE STATE somebody else owns -- a client's inventory snapshot,
-- and the server-wide job histogram -- so they sit on the same allow-list that
-- already gates doors and sync records. A resource that can push a fake
-- inventory to a client can make a product's UI lie to a player, and one that
-- can write the histogram can make `GetOnlineJobCount` report a server that does
-- not exist.
--
-- `NotifyClient` is NOT gated. It shows one player one string; there is no state
-- to corrupt, and the resources that legitimately send notifications are
-- numerous and mostly third-party. Gating it would break them to stop a resource
-- from being annoying, which is a trade this library should not make. It is
-- validated and rate-limited instead.

exports('PublishJobUpdate', function(job, src)
    if type(job) ~= 'table' then
        return false, 'job must be a table'
    end
    if not CisInvokingAllowed() then
        return false, 'not on Security.AuthorizedResources'
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
    return deliverNotification(src, message, kind)
end)

exports('PublishInventory', function(src)
    if type(src) ~= 'number' or src <= 0 then
        return false
    end
    -- On the allow-list, because this writes state a CLIENT acts on. See the
    -- note above the publishers: a fake snapshot makes a product's UI lie.
    if not CisInvokingAllowed() then
        return false, 'not on Security.AuthorizedResources'
    end
    local ok, snapshot = CisRegistry.call('inventory', 'snapshot', src)
    if not ok then
        return false
    end
    TriggerClientEvent('cis_libs:client:inventory', src, snapshot)
    return true
end)

-- ============================================================ GetDiagnostics
--
-- THE LEAK DETECTOR. Every lifecycle promise this library makes is a promise
-- that something was cleaned up when its owner stopped, and none of them can be
-- checked by asserting that nothing threw. They can only be checked by counting
-- before and after, which means the counts have to exist before there is
-- anything to run.
--
-- COUNTS ONLY. No player names, no identifiers, no coordinates. This table gets
-- pasted into bug reports and read by whoever is on call, so the grouping keys
-- are resource and slot names -- both of which are already in the audit log by
-- design -- and never anything about a person.
--
-- The probes are registered by the files that own the state rather than being
-- listed here, because a count of a table this file cannot see is a count
-- somebody has to remember to keep in step with the code that changes it.
---
--- @return table counts and counters, never player data
exports('GetDiagnostics', function()
    return CisDiagnostics.Collect('server')
end)
