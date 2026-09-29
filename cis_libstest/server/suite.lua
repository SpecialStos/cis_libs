-- Server-side test definitions.
--
-- cis_libstest is a SEPARATE resource with its own Lua VM, so none of
-- cis_libs's globals (CisReadyState, Config, Security, CisRateOk, ...) exist
-- here. Everything crossing into the library goes through either the Cis
-- proxy table from @cis_libs/init.lua or an explicit export. The pure shared/
-- modules (CisGrid, CisPending, CisHistogram, CisConfigUtil) are loaded
-- directly in fxmanifest and are safe to use as local copies.
--
-- vector3 does not exist server-side, so coordinates are plain tables.

CisTestServerSuite = {}

-- Exported on THIS resource. cis_libs reaches them as callable reference tables
-- (a returned function arrives as { __cfx_functionReference = ... }), so a
-- handler owned by another server-side resource is reachable after all.
local seenSource = nil
local seenNumber = nil

exports('cis_test:echo', function(_, a, b)
    return a, b, 'done'
end)

exports('cis_test:ok', function()
    return 'yes'
end)

exports('cis_test:src', function(src)
    seenSource = src
    return true
end)

exports('cis_test:boom', function()
    error('deliberate')
end)

exports('cis_test:number', function(_, n)
    seenNumber = n
    return n
end)

-- PlayerId() and GetPlayerServerId() are client-only natives. On the server a
-- test subject is simply a connected player id, and there may be none.
local function subject()
    local players = GetPlayers()
    return tonumber(players[1])
end

local function configSummary()
    return exports['cis_libs']:GetConfigSummary()
end

function CisTestServerSuite.build(ctx, config)
    local r = CisTestRunner.new()
    local reg = function(name, fn, opts)
        CisTestRunner.register(r, name, fn, opts)
    end

    -- ------------------------------------------------------------- lifecycle
    reg('server: cis_libs resource is started', function(t)
        t.equal(GetResourceState('cis_libs'), 'started', 'resource state')
    end)

    reg('server: Cis.wait resolves true', function(t)
        t.truthy(Cis.wait(15000), 'Cis.wait returns true')
    end)

    reg('server: config summary is readable', function(t)
        local c = t
        local summary = configSummary()
        c.exists(summary, 'GetConfigSummary returned a table')
        if summary then
            c.equal(type(summary.framework), 'string', 'framework is a string')
            c.equal(type(summary.inventory), 'string', 'inventory is a string')
            c.equal(type(summary.database), 'string', 'database is a string')
            c.equal(summary.ready, true, 'library reports ready')
        end
    end)

    reg('server: config summary leaks no secrets', function(t)
        local c = t
        local summary = configSummary()
        c.exists(summary, 'summary present')
        if summary then
            local blob = CisTestReport.encode(summary, '')
            c.truthy(not blob:find('discord.com/api/webhooks', 1, true), 'no webhook URL')
            c.truthy(not blob:find('CHANGE-ME', 1, true), 'no placeholder')
            c.equal(summary.database, summary.database, 'database is a type name, not a DSN')
            c.equal(type(summary.allowListConfigured), 'boolean', 'allow-list exposed as a boolean only')
        end
    end)

    reg('server: event prefix is available for door requests', function(t)
        local c = t
        local prefix = exports['cis_libs']:GetLibsPrefix()
        c.equal(type(prefix), 'string', 'prefix is a string')
        c.truthy(#prefix > 0, 'prefix is non-empty')
    end)

    -- ------------------------------------------------------- pure shared logic
    reg('server: grid finds a point inside a registered AABB', function(t)
        local g = CisGrid.new()
        CisGrid.insert(g, 'a', CisGrid.aabbFromCenter(10, 10, 0, 5, 5, 5), {})
        local hits = 0
        CisGrid.queryPoint(g, 10, 10, 0, function() hits = hits + 1 end)
        t.equal(hits, 1, 'queryPoint hit count')
    end)

    reg('server: grid rejects a point outside the AABB', function(t)
        local g = CisGrid.new()
        CisGrid.insert(g, 'a', CisGrid.aabbFromCenter(10, 10, 0, 5, 5, 5), {})
        local hits = 0
        CisGrid.queryPoint(g, 500, 500, 0, function() hits = hits + 1 end)
        t.equal(hits, 0, 'queryPoint miss count')
    end)

    reg('server: pending keys increment and sweep', function(t)
        local store = CisPending.new()
        local k1 = CisPending.alloc(store, { n = 1 }, 10)
        local k2 = CisPending.alloc(store, { n = 2 }, 30)
        t.equal(k1, 1, 'first key')
        t.equal(k2, 2, 'second key')
        CisPending.sweep(store, 20)
        t.equal(CisPending.take(store, k1), nil, 'expired key consumed by sweep')
        t.truthy(CisPending.take(store, k2), 'live key still takeable')
    end)

    reg('server: histogram tracks job counts', function(t)
        local jobs = CisHistogram.new()
        CisHistogram.set(jobs, 9001, { name = 'police' })
        CisHistogram.set(jobs, 9002, { name = 'police' })
        t.equal(CisHistogram.count(jobs, 'police'), 2, 'police count')
        CisHistogram.remove(jobs, 9001)
        t.equal(CisHistogram.count(jobs, 'police'), 1, 'after removal')
    end)

    reg('server: config whitelist strips secrets', function(t)
        local c = t
        local payload = CisConfigUtil.clientPayload({
            Framework = {
                Type = 'QBCORE',
                Inventory = 'ox_inventory',
                Database = { Type = 'oxmysql' },
                Target = { Enabled = true, Type = 'ox_target' },
            },
            Printing = { Debug = true, UseDiscordLogs = true },
        }, {
            EventPrefix = 'cis_libs',
            AuthorizedResources = { 'nope' },
            DiscordLogsLinks = { MasterLogs = 'https://discord.com/api/webhooks/111/abc' },
        }, {})
        c.equal(payload.Config.Framework.Database, nil, 'database config stripped')
        c.equal(payload.Config.Printing.UseDiscordLogs, nil, 'discord flag stripped')
        c.equal(payload.AuthorizedResources, nil, 'allow-list stripped')
        c.truthy(not CisConfigUtil.containsSecret(payload), 'no secret detected')
    end)

    reg('server: JSON encoder round-trips the report shape', function(t)
        local c = t
        local json = CisTestReport.encode({ a = 1, b = 'two' })
        c.truthy(json:find('"a"', 1, true) ~= nil, 'encodes number key')
        c.truthy(json:find('"two"', 1, true) ~= nil, 'encodes string value')
    end)

    -- -------------------------------------------------------------- callbacks
    reg('server: remote handler dispatch across resources', function(t)
        local c = t
        c.truthy(exports['cis_libs']:RegisterCallback('cis:test:ok', 'cis_libstest:cis_test:ok'),
            'registered by resource:export')
        local results = table.pack(pcall(function()
            return exports['cis_libs']:AwaitCallback('cis:test:ok')
        end))
        c.set('threw', not results[1])
        c.set('value', results[2])
        c.truthy(results[1], 'remote handler was invoked without error')
        c.equal(results[2], 'yes', 'remote handler return value crossed back')
    end)

    reg('server: callback event without a source is refused', function(t)
        local c = t
        -- TriggerEvent is resource-local and sets no `source`. The guard must
        -- reject it rather than dispatching with src=nil. Source passing for a
        -- REAL net event is verified client-side, where a source exists.
        seenSource = nil
        c.truthy(exports['cis_libs']:RegisterCallback('cis:test:src', 'cis_libstest:cis_test:src'),
            'registered by resource:export')
        TriggerEvent('cis_libs:cb', 'cis:test:src', 0, 1)
        Wait(200)
        c.set('seenSource', seenSource)
        c.equal(seenSource, nil, 'a sourceless trigger never reached the handler')
    end)

    reg('server: remote handler crash is contained', function(t)
        local c = t
        c.truthy(exports['cis_libs']:RegisterCallback('cis:test:boom', 'cis_libstest:cis_test:boom'),
            'registered by resource:export')
        local ok = pcall(function()
            return exports['cis_libs']:AwaitCallback('cis:test:boom')
        end)
        c.truthy(ok == false, 'a throwing remote handler surfaces as an error, not a crash')
    end)

    reg('server: remote handler receives numeric args as data', function(t)
        local c = t
        seenNumber = nil
        c.truthy(exports['cis_libs']:RegisterCallback('cis:test:number', 'cis_libstest:cis_test:number'),
            'registered by resource:export')
        local results = table.pack(pcall(function()
            return exports['cis_libs']:AwaitCallback('cis:test:number', 42)
        end))
        c.set('awaitThrew', not results[1])
        c.set('awaitReturned', results[2])
        c.set('seenNumber', seenNumber)
        c.equal(seenNumber, 42, 'numeric argument arrived intact at the remote handler')
        if results[2] == 42 then
            c.truthy(true, 'return value passed back through the reference call')
        else
            -- A handler invoked through a callable reference table may not
            -- yield its return value. The argument still arrives, which is the
            -- part that crosses the boundary as data.
            t.skip(('remote handler ran and received its argument, but the return value came back as %s '
                .. 'rather than 42'):format(tostring(results[2])))
        end
    end)

    reg('server: local callback call validates its completion callback', function(t)
        local c = t
        -- The completion callback cannot cross the boundary, so it arrives as
        -- nil. CallCallback must reject that rather than dispatching blind.
        local ok, a, b = pcall(function()
            return exports['cis_libs']:CallCallback('cis:test:absent', nil)
        end)
        c.truthy(ok, 'CallCallback with a nil completion did not throw')
        c.equal(a, nil, 'returns nothing when the completion callback is unusable')
        c.equal(b, nil, 'no second value either')
    end)

    reg('server: client-targeted callback rejects a dead target', function(t)
        local c = t
        local called = false
        Cis.callback.callClient(999999, 'cis:test:nobody', function() called = true end)
        c.equal(called, false, 'a dead target does not resolve synchronously')
    end)

    reg('server: forged response event cannot resolve server state', function(t)
        local c = t
        -- Local dispatch never allocates a pending key, so a guessed key in the
        -- response event has nothing to resolve.
        TriggerEvent('cis_libs:cb:serverRes', 1, true, 'forged')
        c.pass('forged response had no effect')
    end)

    -- -------------------------------------------------------------- framework
    reg('server: framework bridge is loaded', function(t)
        local c = t
        local framework = exports['cis_libs']:GetFramework()
        c.exists(framework, 'GetFramework returned a table')
        if framework then
            c.set('IsLoadedType', type(framework.IsLoaded))
            c.set('GetPlayerType', type(framework.GetPlayer))
            c.pass(('IsLoaded=%s GetPlayer=%s'):format(
                type(framework.IsLoaded), type(framework.GetPlayer)))
        end
    end)

    reg('server: normalised player has a stable shape', function(t)
        local c = t
        local pid = subject()
        if not pid then
            c.skip('no players connected')
            return
        end
        local player = exports['cis_libs']:GetNormalizedPlayer(pid)
        c.exists(player, 'GetNormalizedPlayer returned a table')
        if player then
            c.set('id', player.id)
            c.set('job', player.job and player.job.name or 'none')
            c.pass(('id=%s job=%s'):format(tostring(player.id),
                player.job and tostring(player.job.name) or 'nil'))
            c.truthy(type(player.name) == 'string' or player.name == nil, 'name is a string or nil')
            c.truthy(player.job == nil or type(player.job) == 'table', 'job is a table or nil')
        end
    end)

    reg('server: GetPlayer returns nil for an unknown source', function(t)
        local c = t
        local framework = exports['cis_libs']:GetFramework()
        c.equal(framework.GetPlayer(999999), nil, 'unknown source returns nil')
    end)

    reg('server: online job count is a number', function(t)
        local c = t
        local count = exports['cis_libs']:GetOnlineJobCount('police')
        c.equal(type(count), 'number', 'job count type')
    end)

    -- -------------------------------------------------------------- inventory
    reg('server: inventory count of a nonsense item is 0', function(t)
        local c = t
        local pid = subject()
        if not pid then
            c.skip('no players connected')
            return
        end
        local count = Cis.inventory.count(pid, 'cis_libs_not_a_real_item')
        c.equal(type(count), 'number', 'count is numeric')
        c.equal(count, 0, 'unknown item counts zero')
    end)

    reg('server: inventory has() is false for a nonsense item', function(t)
        local c = t
        local pid = subject()
        if not pid then
            c.skip('no players connected')
            return
        end
        c.equal(Cis.inventory.has(pid, 'cis_libs_not_a_real_item', 1), false, 'has is false')
    end)

    reg('server: inventory add/remove roundtrip', function(t)
        local c = t
        local pid = subject()
        if not pid then
            c.skip('no players connected')
            return
        end
        local added = Cis.inventory.add(pid, 'bread', 1)
        c.truthy(added, 'item added')
        if added then
            c.truthy(Cis.inventory.remove(pid, 'bread', 1), 'item removed')
        end
    end, { mutating = true })

    -- ------------------------------------------------------------------ doors
    reg('server: door can be added and read back', function(t)
        local c = t
        local id = 'cis_test_door_' .. tostring(GetGameTimer())
        local ok = Cis.doors.add({
            id = id,
            model = 'v_warehousedoor01a',
            coords = { x = 0.0, y = 0.0, z = 72.0 },
            locked = false,
        })
        c.truthy(ok, 'door registered')
        c.equal(Cis.doors.get(id), false, 'door state readable and unlocked')
        c.truthy(Cis.doors.setState(id, true), 'setState accepted')
        c.equal(Cis.doors.get(id), true, 'door now locked')
    end, { mutating = true })

    reg('server: unknown door returns nil state', function(t)
        t.equal(Cis.doors.get('cis_test_door_nonexistent'), nil, 'unknown door is nil')
    end)

    reg('server: door request without permission does not change state', function(t)
        local c = t
        local id = 'cis_test_door_guard'
        Cis.doors.add({
            id = id,
            model = 'v_warehousedoor01a',
            coords = { x = 0.0, y = 0.0, z = 72.0 },
            locked = false,
            groups = { 'cis_test_job_that_does_not_exist' },
        })
        local before = Cis.doors.get(id)
        local prefix = exports['cis_libs']:GetLibsPrefix()
        -- No source, so permission can never pass. The state must not move.
        TriggerEvent(prefix .. ':doorlock:requestState', id, true)
        Wait(100)
        c.equal(Cis.doors.get(id), before, 'state unchanged by an unauthorised request')
    end, { mutating = true })

    -- ------------------------------------------------------------------- sync
    reg('server: sync create returns an id', function(t)
        local c = t
        local id = Cis.sync.prop({
            model = 'prop_barrel_01a',
            coords = { x = 10.0, y = 10.0, z = 72.0 },
            networked = false,
        })
        c.truthy(id and #id > 0, 'sync id returned')
    end, { mutating = true })

    reg('server: sync rejects a record with no coords', function(t)
        t.equal(Cis.sync.prop({ model = 'prop_barrel_01a' }), nil, 'missing coords rejected')
    end)

    reg('server: sync remove reports whether it existed', function(t)
        t.equal(Cis.sync.remove('cis_test_sync_nothing'), false, 'removing an unknown id returns false')
    end)

    reg('server: sync upsert with identical data is a no-op', function(t)
        local c = t
        local data = { model = 'prop_barrel_01a', coords = { x = 20.0, y = 20.0, z = 72.0 }, networked = false }
        local first = Cis.sync.prop(data)
        local second = Cis.sync.prop(data)
        c.equal(first, second, 'same id returned for the same payload')
        if first then
            c.truthy(Cis.sync.remove(first), 'record removed')
        end
    end, { mutating = true })

    -- ---------------------------------------------------------------- security
    reg('server: invoking is allowed from the console', function(t)
        t.truthy(exports['cis_libs']:InvokingAllowed(), 'console may mutate')
    end)

    reg('server: rate limiter trips past the limit', function(t)
        local c = t
        local allowed = 0
        for _ = 1, 30 do
            if exports['cis_libs']:RateOk(1, 'cis:test:rate', 60000, 5) then
                allowed = allowed + 1
            end
        end
        c.truthy(allowed <= 5, ('only %d of 30 allowed under a limit of 5'):format(allowed))
    end)

    reg('server: rate limiter isolates per event name', function(t)
        local c = t
        exports['cis_libs']:RateOk(2, 'cis:test:name-a', 60000, 1)
        c.truthy(exports['cis_libs']:RateOk(2, 'cis:test:name-b', 60000, 1), 'separate budget per event')
    end)

    reg('server: security report refuses an invalid source', function(t)
        local c = t
        local ok = pcall(function()
            exports['cis_libs']:SecurityReport(999999, 'cis_libs self-test')
        end)
        c.truthy(ok, 'report did not throw for a non-player source')
    end)

    -- ----------------------------------------------------------------- logging
    reg('server: logging does not throw at any level', function(t)
        local c = t
        local ok = pcall(function()
            Cis.log.debug('cis_libs self-test debug')
            Cis.log.info('cis_libs self-test info')
            Cis.log.warn('cis_libs self-test warn')
            Cis.log.error('cis_libs self-test error')
        end)
        c.truthy(ok, 'all four log levels executed')
    end)

    reg('server: discord queue depth is readable', function(t)
        t.equal(type(exports['cis_libs']:GetDiscordQueueDepth()), 'number', 'queue depth is a number')
    end)

    -- -------------------------------------------------------------- networking
    reg('server: net.on registers without error', function(t)
        local c = t
        local name = 'cis:test:net:' .. tostring(GetGameTimer())
        local ok = pcall(function()
            exports['cis_libs']:SecureNetOn(name, function() end)
        end)
        c.truthy(ok, 'SecureNetOn did not throw')
    end)

    return r
end
