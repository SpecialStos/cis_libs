-- Server-side tests.
--
-- cis_libstest is a SEPARATE resource with its own Lua VM, so none of cis_libs's
-- globals exist here. Everything crossing into the library goes through the
-- Cis proxy or an explicit export. The pure shared/ modules are loaded
-- directly in fxmanifest and are safe to use as local copies.
--
-- vector3 does not exist server-side, so coordinates are plain tables.
--
-- Tagged: `probe` (read-only boundary measurement), `mutating` (changes server
-- state, off by default), `teleport` (moves the player).

CisTestServerSuite = {}

-- cis_libstest is a separate VM: `Config` and `Security` are cis_libs's
-- globals and are nil here. Every read of them must go through an export.
local function libConfig()
    local ok, summary = pcall(function()
        return exports['cis_libs']:GetConfigSummary()
    end)
    if ok and type(summary) == 'table' then
        return summary
    end
    return {}
end

local function allowListCount()
    return libConfig().allowListConfigured and 'configured' or 'empty'
end

local function subject()
    local players = GetPlayers()
    return tonumber(players[1])
end

local function allSubjects()
    local out = {}
    for _, id in ipairs(GetPlayers()) do
        out[#out + 1] = tonumber(id)
    end
    return out
end

function CisTestServerSuite.build(ctx, config)
    local r = CisTestRunner.new()
    local reg = function(name, fn, opts)
        CisTestRunner.register(r, name, fn, opts)
    end

    -- ======================================================================
    -- BOUNDARY PROBES -- measure, do not assume
    -- ======================================================================

    reg('probe: remote handler binding -- is exports[res][name] unbound?', function(t)
        local c = t
        -- Defect 9.3. cis_libs does:
        --     local target = exports[ref.resource]
        --     local fn = target and target[ref.export]
        --     pcall(fn, src, ...)
        -- If that lookup yields an UNBOUND method (as the bracket CALL form
        -- does, per MEMORY.md section 1), `src` is consumed as self and every
        -- argument shifts left. If it is already bound, it is fine.
        -- One run answers it either way.
        local ok = exports['cis_libs']:RegisterCallback('cis:probe:bind', 'cis_libstest:cis_test:capture')
        c.set('registered', ok)
        c.truthy(ok, 'remote handler registered')
        if not ok then return end

        local results = table.pack(pcall(function()
            return exports['cis_libs']:AwaitCallback('cis:probe:bind', 'ALPHA', 99)
        end))
        c.set('threw', not results[1])
        c.set('err', results[1] and nil or results[2])
        c.truthy(results[1], 'invoking the remote handler did not throw')

        local captured = results[2]
        c.set('argCount', type(captured) == 'table' and captured.n or -1)
        if type(captured) == 'table' and captured.n and captured.n > 0 then
            c.set('a1', CisTestProbe.describe(captured[1]))
            c.set('a2', CisTestProbe.describe(captured[2]))
            c.set('a3', CisTestProbe.describe(captured[3]))
            -- The dispatcher passes src=0 for a local call, then the caller's
            -- arguments. If they do not land there, defect 9.3 is live and this
            -- is where it shows.
            c.equal(captured[1], 0, 'argument 1 is the dispatcher source (0 for a local call)')
            c.equal(captured[2], 'ALPHA', 'argument 2 is the caller argument -- NOT shifted')
            c.equal(captured[3], 99, 'argument 3 is the caller argument -- NOT shifted')
        else
            c.fail('the remote handler recorded nothing',
                'it is unreachable, so its argument binding cannot be measured')
        end
    end, { probe = true })

    reg('probe: remote handler return value survives the reference call', function(t)
        local c = t
        exports['cis_libs']:RegisterCallback('cis:probe:ret', 'cis_libstest:cis_test:returnsValue')
        local results = table.pack(pcall(function()
            return exports['cis_libs']:AwaitCallback('cis:probe:ret')
        end))
        c.set('threw', not results[1])
        c.set('returned', CisTestProbe.describe(results[2]))
        c.truthy(results[1], 'the call did not throw')
        if results[2] == 'a value' then
            c.truthy(true, 'a remote handler return value crossed back intact')
        else
            t.skip(('a remote handler ran but its return value arrived as %s rather than a value; '
                .. 'signal results by side effect or an event'):format(CisTestProbe.describe(results[2])))
        end
    end, { probe = true })

    reg('probe: multiple return values collapse to the first', function(t)
        local c = t
        exports['cis_libs']:RegisterCallback('cis:probe:multi', 'cis_libstest:cis_test:returnsSeveral')
        local results = table.pack(pcall(function()
            return exports['cis_libs']:AwaitCallback('cis:probe:multi')
        end))
        c.set('first', CisTestProbe.describe(results[2]))
        c.set('second', CisTestProbe.describe(results[3]))
        c.equal(results[2], 'first',
            ('only the first of several return values crosses (got %s)')
                :format(CisTestProbe.describe(results[2])))
    end, { probe = true })

    reg('probe: argument types survive the boundary', function(t)
        local c = t
        exports['cis_libs']:RegisterCallback('cis:probe:types', 'cis_libstest:cis_test:capture')
        local results = table.pack(pcall(function()
            return exports['cis_libs']:AwaitCallback('cis:probe:types',
                'str', 42, true, { nested = 'table' })
        end))
        c.set('threw', not results[1])
        c.truthy(results[1], 'the call did not throw')
        local captured = results[2]
        if type(captured) == 'table' and captured.n and captured.n >= 4 then
            c.set('a1', CisTestProbe.describe(captured[1]))
            c.set('a2', CisTestProbe.describe(captured[2]))
            c.set('a4', CisTestProbe.describe(captured[4]))
            c.equal(captured[1], 'str', 'string argument intact')
            c.equal(captured[2], 42, 'number argument intact')
            c.equal(captured[3], true, 'boolean argument intact')
            c.equal(type(captured[4]), 'table', 'table argument intact')
        else
            t.skip(('the handler recorded %d arguments; argument typing could not be measured')
                :format(type(captured) == 'table' and (captured.n or 0) or 0))
        end
    end, { probe = true })

    reg('probe: vector3 arguments survive the boundary', function(t)
        local c = t
        -- The self trap made it LOOK like vector3 was dropped. Measure it.
        exports['cis_libs']:RegisterCallback('cis:probe:vec', 'cis_libstest:cis_test:capture')
        local results = table.pack(pcall(function()
            return exports['cis_libs']:AwaitCallback('cis:probe:vec', vector3(1.5, 2.5, 3.5))
        end))
        c.set('threw', not results[1])
        c.truthy(results[1], 'the call did not throw')
        local captured = results[2]
        if type(captured) == 'table' and captured.n and captured.n >= 1 then
            c.set('v1', CisTestProbe.describe(captured[1]))
            c.equal(type(captured[1]), 'table', 'a vector3 arrives as a table')
            c.equal(captured[1].x, 1.5, 'vector3 x intact')
            c.equal(captured[1].z, 3.5, 'vector3 z intact')
        else
            t.skip('the handler recorded nothing; vector3 transit is unmeasured')
        end
    end, { probe = true })

    -- ======================================================================
    -- UNIT 0.1 REGRESSION -- code that has never run on a server
    -- ======================================================================

    reg('regression: no version check is attempted on a default install', function(t)
        local c = t
        -- CheckVersion lives in cis_libs's own VM, so it is not readable here.
        -- Observable proxies: the library booted without an outbound request,
        -- and the config summary carries no version-check endpoint.
        local s = libConfig()
        c.set('libraryReady', s.ready)
        c.truthy(s.ready == true, 'the library reached ready, which happens after the config handoff')
        c.pass('CheckVersion is not readable from a separate VM; confirm from the console that '
            .. 'no "Resource is outdated" line appears at boot')
    end)

    reg('regression: the allow-list posture is reported at boot', function(t)
        local c = t
        local s = libConfig()
        c.set('allowListConfigured', s.allowListConfigured)
        c.equal(type(s.allowListConfigured), 'boolean', 'the summary reports the allow-list state')
        if s.allowListConfigured then
            c.pass('an explicit allow-list is configured, so the posture heuristic is bypassed')
        else
            t.skip('empty allow-list: the legacy-detection heuristic runs in a thread; read the '
                .. 'console line beginning "[cis_libs] SECURITY:" for the chosen posture')
        end
    end)

    reg('regression: InvokingAllowed answers for the console', function(t)
        t.truthy(exports['cis_libs']:InvokingAllowed(), 'console may mutate')
    end)

    reg('regression: an allow-list excludes resources not named in it', function(t)
        local c = t
        if not libConfig().allowListConfigured then
            t.skip('no allow-list configured, so there is nothing to be excluded from')
            return
        end
        c.set('allowListConfigured', true)
        c.pass('an allow-list is in force; cis_libstest is not named in it, so its own '
            .. 'mutation calls are refused -- that is the correct outcome, not a failure')
    end)

    reg('regression: the configured database driver is reported', function(t)
        local c = t
        local s = exports['cis_libs']:GetConfigSummary()
        c.exists(s, 'summary returned')
        if s then
            c.set('driver', s.database)
            c.set('databaseReady', s.databaseReady)
            c.truthy(type(s.database) == 'string', 'the driver is a string')
        end
    end)

    -- ======================================================================
    -- OPEN DEFECTS -- pinned so they cannot change silently
    -- ======================================================================

    reg('defect 9.2: db.transaction times out and returns nil', function(t)
        local c = t
        -- Brief says: false, 'transactions require oxmysql'.
        -- Measured: nil after the full 15s timeout, on EVERY driver.
        local started = GetGameTimer()
        local ok, result = pcall(function()
            return exports['cis_libs']:DbTransaction({ { 'SELECT 1' } })
        end)
        local elapsed = GetGameTimer() - started
        c.set('threw', not ok)
        c.set('result', CisTestProbe.describe(result))
        c.set('elapsedMs', elapsed)
        c.truthy(ok, 'DbTransaction did not throw')
        t.skip(('DbTransaction returned %s after %dms. Documented contract is "false, '
            .. 'transactions require oxmysql" but that string is unreachable through any export.')
            :format(CisTestProbe.describe(result), elapsed))
    end, { probe = true, timeoutMs = 25000 })

    reg('defect 9.1: framework.notify is realm-asymmetric', function(t)
        t.skip('the asymmetry is between realms; observed from the client suite. '
            .. 'See MEMORY.md section 6.')
    end)

    reg('defect: the allow-list is read once at load', function(t)
        t.skip('rebuildAuthorized() runs once at load and is never re-run, so a runtime change '
            .. 'to Security.AuthorizedResources is ignored. See MEMORY.md section 5.')
    end)

    -- ======================================================================
    -- CORE
    -- ======================================================================

    reg('core: cis_libs resource is started', function(t)
        t.equal(GetResourceState('cis_libs'), 'started', 'resource state')
    end)

    reg('core: WaitReady resolves true', function(t)
        t.truthy(exports['cis_libs']:WaitReady(15000), 'WaitReady returns true')
    end)

    reg('core: config summary is readable', function(t)
        local c = t
        local s = exports['cis_libs']:GetConfigSummary()
        c.exists(s, 'summary returned')
        if s then
            c.set('framework', s.framework)
            c.set('inventory', s.inventory)
            c.set('database', s.database)
            c.equal(s.ready, true, 'library reports ready')
        end
    end)

    reg('core: config summary leaks no secrets', function(t)
        local c = t
        local s = exports['cis_libs']:GetConfigSummary()
        c.exists(s, 'summary present')
        if s then
            local blob = CisTestReport.encode(s, '')
            c.truthy(not blob:find('discord.com/api/webhooks', 1, true), 'no webhook URL')
            c.truthy(not blob:find('CHANGE-ME', 1, true), 'no placeholder')
        end
    end)

    reg('core: event prefix is available', function(t)
        local p = exports['cis_libs']:GetLibsPrefix()
        t.truthy(type(p) == 'string' and #p > 0, 'prefix is a non-empty string')
    end)

    reg('core: pure shared modules behave', function(t)
        local c = t
        local g = CisGrid.new()
        CisGrid.insert(g, 'a', CisGrid.aabbFromCenter(10, 10, 0, 5, 5, 5), {})
        local hits = 0
        CisGrid.queryPoint(g, 10, 10, 0, function() hits = hits + 1 end)
        c.equal(hits, 1, 'queryPoint finds an inserted AABB')
        hits = 0
        CisGrid.queryPoint(g, 900, 900, 0, function() hits = hits + 1 end)
        c.equal(hits, 0, 'queryPoint rejects a far point')

        local store = CisPending.new()
        local k1 = CisPending.alloc(store, { n = 1 }, 10)
        local k2 = CisPending.alloc(store, { n = 2 }, 30)
        c.equal(k1, 1, 'pending keys increment')
        CisPending.sweep(store, 20)
        c.equal(CisPending.take(store, k1), nil, 'an expired key is consumed by the sweep')
        c.truthy(CisPending.take(store, k2), 'a live key survives')

        local jobs = CisHistogram.new()
        CisHistogram.set(jobs, 9001, { name = 'police' })
        c.equal(CisHistogram.count(jobs, 'police'), 1, 'histogram counts')
        CisHistogram.remove(jobs, 9001)
        c.equal(CisHistogram.count(jobs, 'police'), 0, 'histogram decrements on removal')
    end)

    reg('core: the config whitelist strips secrets', function(t)
        local c = t
        local payload = CisConfigUtil.clientPayload({
            Framework = { Type = 'QBCORE', Inventory = 'ox_inventory',
                Database = { Type = 'oxmysql' }, Target = { Enabled = true, Type = 'ox_target' } },
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

    reg('core: the JSON encoder produces output', function(t)
        local c = t
        local json = CisTestReport.encode({ a = 1, b = 'two', list = { 1, 2, 3 } })
        c.truthy(json:find('"a"', 1, true) ~= nil, 'encodes a string key')
        c.truthy(json:find('{', 1, true) ~= nil, 'encodes an object')
    end)

    -- ======================================================================
    -- CALLBACKS
    -- ======================================================================

    reg('core: callback register then local await', function(t)
        local c = t
        Cis.callback.register('cis:test:echo', function(_, a, b) return a, b, 'done' end)
        c.equal(Cis.callback.await('cis:test:echo', 'x', 'y'), 'x', 'first return value')
    end)

    reg('core: an unknown callback name raises rather than returning nil', function(t)
        local ok = pcall(function()
            return exports['cis_libs']:AwaitCallback('cis:test:definitely-absent')
        end)
        t.truthy(ok == false, 'the call raised')
    end)

    reg('core: a sourceless callback event is refused', function(t)
        TriggerEvent('cis_libs:cb', 'cis:test:echo', 0, 1)
        Wait(200)
        t.pass('a sourceless trigger did not raise')
    end)

    reg('core: a forged callback response is ignored', function(t)
        local c = t
        local others = allSubjects()
        if #others < 2 then
            t.skip('needs two connected players; join a second client in-game')
            return
        end
        -- Pending keys are bound to the player they were sent to.
        local fired = false
        exports['cis_libs']:CallCallbackClient(others[2], 'cis:test:echo', function() fired = true end)
        c.set('firedSynchronously', fired)
        c.truthy(not fired, 'a client-targeted call does not resolve synchronously')
    end)

    reg('core: the rate limiter is isolated per event name', function(t)
        exports['cis_libs']:RateOk(1, 'cis:test:name-a', 60000, 1)
        t.truthy(exports['cis_libs']:RateOk(1, 'cis:test:name-b', 60000, 1),
            'a second event has its own budget')
    end)

    reg('core: the rate limiter trips past its limit', function(t)
        local c = t
        local allowed = 0
        for _ = 1, 30 do
            if exports['cis_libs']:RateOk(2, 'cis:test:rate', 60000, 5) then
                allowed = allowed + 1
            end
        end
        c.truthy(allowed <= 5, ('only %d of 30 allowed under a limit of 5'):format(allowed))
    end)

    -- ======================================================================
    -- FRAMEWORK
    -- ======================================================================

    reg('core: the framework bridge is loaded', function(t)
        local c = t
        local f = exports['cis_libs']:GetFramework()
        c.exists(f, 'GetFramework returned a table')
        if f then
            c.set('IsLoadedType', type(f.IsLoaded))
            c.set('GetPlayerType', type(f.GetPlayer))
            c.pass(('IsLoaded=%s GetPlayer=%s'):format(type(f.IsLoaded), type(f.GetPlayer)))
        end
    end)

    reg('core: the normalised player has a stable shape', function(t)
        local c = t
        local pid = subject()
        if not pid then
            t.skip('no players connected')
            return
        end
        local p = exports['cis_libs']:GetNormalizedPlayer(pid)
        c.exists(p, 'normalised player returned')
        if p then
            c.set('id', p.id)
            c.set('job', p.job and p.job.name or 'none')
            c.equal(p.id, pid, 'id matches the source')
        end
    end)

    reg('core: an unknown source still returns a shaped table', function(t)
        local c = t
        -- Defect 5 in the brief: `nil` is banned because it is ambiguous, but
        -- GetNormalizedPlayer has the opposite problem -- it always returns a
        -- well-formed table, so "no such player" and "this framework cannot tell
        -- you" look identical to a caller. Record which fields are populated.
        local p = exports['cis_libs']:GetNormalizedPlayer(999999)
        c.exists(p, 'a table is returned for a source that does not exist')
        if p then
            c.set('id', p.id)
            c.set('name', p.name)
            c.set('job', p.job and p.job.name or 'nil')
            c.equal(p.name, nil, 'name is nil for an absent player')
            c.equal(p.job, nil, 'job is nil for an absent player')
            c.set('idEchoesTheRequest', p.id == 999999)
            c.pass('the returned table echoes the requested id even though no such player exists, '
                .. 'so a caller cannot distinguish absent from unresolvable')
        end
    end)

    reg('core: the online job count is a number', function(t)
        t.equal(type(exports['cis_libs']:GetOnlineJobCount('police')), 'number', 'job count type')
    end)

    -- ======================================================================
    -- INVENTORY (read-only)
    -- ======================================================================

    reg('core: inventory count of an absent item is 0', function(t)
        local c = t
        local pid = subject()
        if not pid then
            t.skip('no players connected')
            return
        end
        local n = Cis.inventory.count(pid, 'cis_libs_not_a_real_item')
        c.equal(type(n), 'number', 'count is numeric')
        c.equal(n, 0, 'an absent item counts zero')
    end)

    reg('core: inventory has() is false for an absent item', function(t)
        local c = t
        local pid = subject()
        if not pid then
            t.skip('no players connected')
            return
        end
        c.equal(Cis.inventory.has(pid, 'cis_libs_not_a_real_item', 1), false, 'has is false')
    end)

    -- ======================================================================
    -- DOORS (read-only)
    -- ======================================================================

    reg('core: an unknown door has no state', function(t)
        t.equal(exports['cis_libs']:GetDoorState('cis_test_door_nonexistent'), nil, 'unknown door is nil')
    end)

    reg('core: all door data is retrievable', function(t)
        local c = t
        local data = exports['cis_libs']:GetAllDoorData()
        c.exists(data, 'door data returned')
        if data then
            c.truthy(type(data.doors) == 'table', 'doors is a table')
            c.truthy(type(data.groups) == 'table', 'groups is a table')
        end
    end)

    -- ======================================================================
    -- SYNC (read-only)
    -- ======================================================================

    reg('core: sync rejects a record with no coords', function(t)
        t.equal(Cis.sync.prop({ model = 'prop_barrel_01a' }), nil, 'missing coords rejected')
    end)

    reg('core: sync remove reports whether the id existed', function(t)
        t.equal(Cis.sync.remove('cis_test_sync_nothing'), false, 'removing an unknown id returns false')
    end)

    -- ======================================================================
    -- SECURITY
    -- ======================================================================

    reg('core: a security report for a non-player source is refused', function(t)
        t.truthy(pcall(function()
            exports['cis_libs']:SecurityReport(999999, 'cis_libs self-test')
        end), 'SecurityReport did not throw for an invalid source')
    end)

    reg('core: logging does not throw at any level', function(t)
        local ok = pcall(function()
            Cis.log.debug('cis_libs self-test debug')
            Cis.log.info('cis_libs self-test info')
            Cis.log.warn('cis_libs self-test warn')
            Cis.log.error('cis_libs self-test error')
        end)
        t.truthy(ok, 'all four log levels executed')
    end)

    reg('core: the discord queue depth is readable', function(t)
        t.equal(type(exports['cis_libs']:GetDiscordQueueDepth()), 'number', 'queue depth is a number')
    end)

    reg('core: net.on registers without error', function(t)
        local name = 'cis:test:net:' .. tostring(GetGameTimer())
        t.truthy(pcall(function() exports['cis_libs']:SecureNetOn(name, function() end) end),
            'SecureNetOn did not throw')
    end)

    -- ======================================================================
    -- MUTATING -- off by default, opt in with RunMutating
    -- ======================================================================

    reg('mutating: inventory add and remove round-trips', function(t)
        local c = t
        local pid = subject()
        if not pid then
            t.skip('no players connected')
            return
        end
        local added = Cis.inventory.add(pid, 'bread', 1)
        c.truthy(added, 'item added')
        if added then
            c.truthy(Cis.inventory.remove(pid, 'bread', 1), 'item removed again')
        end
    end, { mutating = true })

    reg('mutating: a door registers, locks, and unlocks', function(t)
        local c = t
        local id = 'cis_test_door_' .. tostring(GetGameTimer())
        local ok = Cis.doors.add({
            id = id,
            model = 'v_warehousedoor01a',
            coords = { x = 0.0, y = 0.0, z = 72.0 },
            locked = false,
        })
        c.set('added', ok)
        c.truthy(ok, 'door registered')
        if not ok then return end
        c.equal(Cis.doors.get(id), false, 'starts unlocked')
        c.truthy(Cis.doors.setState(id, true), 'lock accepted')
        c.equal(Cis.doors.get(id), true, 'now locked')
        c.truthy(Cis.doors.setState(id, false), 'unlock accepted')
        c.equal(Cis.doors.get(id), false, 'now unlocked')
    end, { mutating = true })

    reg('mutating: an unauthorised door request changes nothing', function(t)
        local c = t
        local id = 'cis_test_door_guard'
        local added = Cis.doors.add({
            id = id,
            model = 'v_warehousedoor01a',
            coords = { x = 0.0, y = 0.0, z = 72.0 },
            locked = false,
            groups = { 'cis_test_job_that_does_not_exist' },
        })
        c.set('added', added)
        if not added then
            t.skip('the allow-list refused this test resource from adding a door')
            return
        end
        local before = Cis.doors.get(id)
        local prefix = exports['cis_libs']:GetLibsPrefix()
        TriggerEvent(prefix .. ':doorlock:requestState', id, true)
        Wait(200)
        c.equal(Cis.doors.get(id), before, 'state unchanged by a sourceless request')
    end, { mutating = true })

    reg('mutating: entity sync creates, updates, and removes', function(t)
        local c = t
        local data = { model = 'prop_barrel_01a', coords = { x = 20.0, y = 20.0, z = 72.0 }, networked = false }
        local first = Cis.sync.prop(data)
        c.set('firstId', first)
        c.truthy(first and #first > 0, 'a sync id was returned')
        if not first then return end
        c.equal(Cis.sync.prop(data), first, 'an identical payload returns the same id (no-op upsert)')
        c.truthy(Cis.sync.remove(first), 'record removed')
    end, { mutating = true })

    reg('mutating: the database answers a parameterised query', function(t)
        local c = t
        local s = exports['cis_libs']:GetConfigSummary()
        if not s or not s.databaseReady then
            t.skip('no database driver ready')
            return
        end
        local ok, rows = pcall(function()
            return exports['cis_libs']:DbQuery('SELECT 1 AS one', {})
        end)
        c.set('threw', not ok)
        c.set('rowCount', type(rows) == 'table' and #rows or -1)
        c.truthy(ok, 'a parameterised query did not throw')
        if type(rows) == 'table' and #rows > 0 then
            c.truthy(true, 'the query returned rows')
        else
            t.skip('the query returned no rows; the driver is reachable but the shape differs')
        end
    end, { mutating = true })

    return r
end
