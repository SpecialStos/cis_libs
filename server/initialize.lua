-- Server bootstrap: the client's config pull, the readiness gate, the
-- diagnostic summary, and the console command.
--
-- Nothing in this file decides behaviour. It exists so a companion resource
-- and an operator can both find out what this server actually resolved to,
-- without either of them having to read Config -- and, since the platform is
-- now four resources rather than one, so they can find out WHICH PARTS ARE
-- INSTALLED AT ALL.

CisNetOn('cis_libs:server:getData', function(src)
    -- Rebuilt per request rather than cached at load. Config and Security can
    -- be re-pointed at runtime by a consumer, and a cached payload would hand
    -- out the config that was true when the resource started. clientPayload is
    -- a whitelist, not a filter: anything absent from it was never copied, so a
    -- newly added secret in Config is not exposed by not being mentioned.
    local payload = CisConfigUtil.clientPayload(Config, Security)
    TriggerClientEvent('cis_libs:client:getData', src, payload)
end)

exports('WaitReady', function(timeout)
    return CisReadyState.wait(timeout)
end)

-- READINESS IS THIS LIBRARY'S OWN BUSINESS, and it used not to be.
--
-- `CisReadyState.markReady()` was called by the framework layer once a
-- framework had been detected -- which is fine when everything is in one
-- resource and actively broken the moment it is not. Split out, a server
-- running cis_libs alone with no cis_core installed would have waited for a
-- framework that was never coming, so every `Cis.ready`, every zone create and
-- every client boot would have timed out on a library that was working
-- perfectly. "Optional" has to mean optional all the way down, including in the
-- boot sequence.
--
-- So the gate opens when THIS resource has finished its own boot, and a product
-- that needs more waits on WaitReady for as long as it likes. Nothing here
-- depends on a capability being registered.
CreateThread(function()
    -- One tick of grace so the handlers above are all registered before anyone
    -- can observe a ready state and start calling into a half-loaded resource.
    Wait(0)
    CisReadyState.markReady()
end)

-- Non-secret server config, for companion resources and diagnostics. Carries no
-- webhooks, credentials, database connection details, or the allow-list.
--
-- Every field is a resolved value rather than a copy of the config table, so
-- this cannot drift into leaking a table wholesale. `allowListConfigured` is a
-- boolean derived from the list; the list itself stays server-side, and a
-- consumer that needs the names must ask for them from a resource that is
-- already trusted to hold them.
exports('GetConfigSummary', function()
    -- Blocks until ready, and returns nil rather than a half-populated table if
    -- the wait runs out. A summary that says "framework NONE" because it was
    -- asked too early is worse than no summary: it looks like a real answer.
    if not CisReadyState.wait(15000) then
        return nil
    end
    local framework = Config and Config.Framework or {}
    local database = framework.Database or {}
    local caps = CisRegistry.snapshot()
    return {
        ready = CisReadyState.ready == true,
        -- `framework` is the CONFIGURED type, which detection may have rewritten
        -- to 'NONE' when the provider could not be loaded. So a server that is
        -- configured for QBCore and got 'NONE' here is reporting that the
        -- detection failed, not that the operator configured nothing.
        framework = framework.Type or 'NONE',
        inventory = framework.Inventory or 'NONE',
        target = (framework.Target and framework.Target.Type) or 'NONE',
        -- `database` is the configured driver and `databaseReady` is whether
        -- anything actually answers. The two disagree on a server whose driver
        -- started late, which is the case this pair exists to make visible.
        database = database.Type or 'NONE',
        databaseReady = caps.database ~= nil and caps.database.owner ~= nil
            and caps.database.resolved == true,
        -- WHO ANSWERS, not what was configured. This is the field that turns
        -- "the database is nil" into "cis_core is not started" -- the answer an
        -- operator can act on in one line, and the answer a support thread
        -- otherwise spends four messages arriving at.
        providers = {
            framework = caps.framework and caps.framework.owner or nil,
            database = caps.database and caps.database.owner or nil,
            target = caps.target and caps.target.owner or nil,
            inventory = caps.inventory and caps.inventory.owner or nil,
            doors = caps.doors and caps.doors.owner or nil,
        },
        missing = (function()
            local out = {}
            for slot, entry in pairs(caps) do
                if not entry.owner then
                    out[#out + 1] = slot
                end
            end
            table.sort(out)
            return out
        end)(),
        syncEnabled = not (Config and Config.Sync and Config.Sync.Enabled == false),
        eventPrefix = (Security and Security.EventPrefix) or 'cis_libs',
        callbackTimeout = (Config and Config.CallbackTimeout) or 10000,
        allowListConfigured = type(Security and Security.AuthorizedResources) == 'table'
            and #Security.AuthorizedResources > 0,
    }
end)

-- Prints derived state only: a ready flag, one job count, one boolean about the
-- client payload, and the capability table. No config values, no webhook URLs,
-- no identifiers. That is the constraint that makes it safe to have at all --
-- a debug command that dumps config puts every secret on a server owner's
-- screen and into their client log.
--
-- The admin check is belt and braces. The third argument to RegisterCommand is
-- FiveM's restricted flag, and a console that forwards a player src, or a
-- restricted flag that is not what it was assumed to be, must not become a way
-- to run this without permission.
RegisterCommand('cis_debug', function(src)
    if src ~= 0 then
        -- The permission check asks whichever framework is registered. A server
        -- with no framework cannot answer, and the answer it gives is "no" --
        -- which is the right direction: an unauthenticated player gets nothing,
        -- and an operator who needs this uses the server console.
        local fw = CisRegistry.resolve('framework')
        if not (fw and fw.HasPermission and fw.HasPermission(src, 'admin')) then
            return
        end
    end
    print(('[cis_libs] ready=%s jobs=%s'):format(
        tostring(CisReadyState.ready),
        json.encode({ police = CisJobCount('police') })
    ))
    -- The payload is rebuilt empty on purpose: this check is about whether the
    -- CONFIG half of the payload leaks, and including real data would only add
    -- noise to the answer.
    local payload = CisConfigUtil.clientPayload(Config, Security)
    -- Expected output is `false`. `true` means the whitelist in
    -- shared/config.lua has drifted and something that should stay server-side
    -- is now being sent to every client.
    print('[cis_libs] client payload has secrets: ' .. tostring(CisConfigUtil.containsSecret(payload)))

    -- THE CAPABILITY TABLE. This is the command a server owner runs when
    -- something in the platform is not working, and the first question is
    -- always "which of my four resources is actually running". A line per slot
    -- with the owning resource and a resolved/unresolved verdict answers it
    -- without the owner having to read any source, and a slot with no owner is
    -- a sentence they can act on: install that product.
    print('[cis_libs] --- capabilities ---')
    local caps = CisRegistry.snapshot()
    local slots = {}
    for slot in pairs(caps) do
        slots[#slots + 1] = slot
    end
    table.sort(slots)
    for _, slot in ipairs(slots) do
        local entry = caps[slot]
        if entry.owner then
            print(('[cis_libs]   %-18s %-16s %s'):format(
                slot, entry.owner, entry.resolved and 'resolved' or 'UNRESOLVED'))
            -- A provider that registered but cannot serve part of its contract
            -- answers those calls with the fallback value forever. Naming the
            -- methods turns that into a version mismatch someone can fix.
            if entry.missing and #entry.missing > 0 then
                print(('[cis_libs]   %-18s missing: %s'):format('', table.concat(entry.missing, ', ')))
            end
        else
            print(('[cis_libs]   %-18s %-16s %s'):format(slot, '-', 'no provider installed'))
        end
    end

    -- RAW STATE of every framework and driver this library knows about. When a
    -- capability reads as missing, the operator's next question is always "is my
    -- framework even started?" -- and answering it here beats sending them to
    -- the txAdmin resources page to work it out.
    local known = {}
    if CisDetect then
        for _, k in ipairs(CisDetect.FRAMEWORKS) do known[#known + 1] = k.resource end
        for _, k in ipairs(CisDetect.DATABASES) do known[#known + 1] = k.resource end
    end
    for _, res in ipairs(known) do
        print(('[cis_libs]   %s: %s'):format(res, tostring(GetResourceState(res))))
    end
    print(('[cis_libs] configuration supplied by: %s'):format(
        tostring(Config and Config.__owner or 'built-in defaults (no cis_core)')))
end, true)
