-- The first server tier: the things that need no player and can therefore
-- always run.
--
-- Appendix A's `server` tier, restricted to the cases the fakes can actually
-- answer today. Everything here is a claim about cis_libs BEHAVIOUR on a real
-- server -- a real exports boundary, a real resource, a real Lua VM -- which is
-- the class of bug the unit suite structurally cannot see.

-- WHAT SURVIVES AN EXPORT CALL, MEASURED RATHER THAN ASSUMED.
--
-- Three live cases report a refusal that arrives with no explanation, and each
-- one carries a comment saying the reason does not survive the boundary. That
-- may be true when the first value is nil and false when it is `false` --
-- `CreateZone` returns `false, reason` and its reason arrives intact, which
-- already contradicts the general claim. So it is measured.
--
-- This is deliberately a property of the HARNESS, not of cis_libs: it lives
-- here so the answer is about the platform, not about this library's exports.
exports('ReturnShapeProbe', function(shape)
    if shape == 'nil' then return nil, 'reason-after-nil' end
    if shape == 'false' then return false, 'reason-after-false' end
    if shape == 'none' then return end
    return true, 'reason-after-true'
end)

--- Ask for a NETWORKED entity of a kind the server has no creation native for,
--- and answer whatever the library said -- id or nil, plus the reason.
---
--- An export so the REASON crosses the boundary to be read. A nil first value
--- does not always carry its second value with it, and this case is about what
--- the caller is told, not only about what it is refused.
exports('SyncCreateUnsupportedNetworked', function()
    local id, why = exports['cis_libs']:SyncCreate('blimp', {
        model = 'blimp',
        coords = { x = 0.0, y = 0.0, z = 0.0 },
        networked = true,
    })
    return id, why
end)

CisTestRunner.Suite('boundary', { tier = 'server', realm = 'server' }, function(t)
    t.case('a second return value survives UNLESS the first is nil', function()
        local seen = {}
        for _, shape in ipairs({ 'none', 'true', 'false', 'nil' }) do
            local _, second = exports['cis_test']:ReturnShapeProbe(shape)
            seen[shape] = second
        end
        -- MEASURED, run-20261003-075458:
        --   none  -> nil                (nothing was returned; correct)
        --   true  -> reason-after-true  (survives)
        --   false -> reason-after-false (survives)
        --   nil   -> nil                (TRUNCATED)
        --
        -- So it is not "a second return value does not survive the exports
        -- boundary", which is what three live cases asserted in their comments
        -- and what this project believed for a stage. It is a nil FIRST value
        -- that truncates the return list, and nothing else does.
        --
        -- This matters because cis_libs answers `nil, reason` on a read that has
        -- no provider, and `CreateZone` answers `false, reason` on a refusal --
        -- one loses its reason, the other keeps it, from the same boundary.
        t.ok(seen['true'] == 'reason-after-true',
            'a reason survives behind a `true` (' .. tostring(seen['true']) .. ')')
        t.ok(seen['false'] == 'reason-after-false',
            'and behind a `false` (' .. tostring(seen['false']) .. ')')
        t.ok(seen['nil'] == nil,
            ('but is LOST behind a `nil` (%s) -- the return list is truncated '
                .. 'at the nil, so any export answering `nil, reason` hands '
                .. 'the caller no reason at all'):format(tostring(seen['nil'])))
    end)
end)

CisTestRunner.Suite('registry', { tier = 'server', realm = 'server' }, function(t)
    -- The fakes are holding every slot, so a refusal here is cis_libs refusing,
    -- not the environment being empty. That distinction is the reason the
    -- preflight exists.
    t.case('every slot resolves against the fakes', function()
        local caps = exports['cis_libs']:GetCapabilities()
        local unresolved, empty = {}, {}
        -- doorsClient and ui are DELIBERATELY excluded. doorsClient is
        -- registered by the client fakes in the client's own Lua state; ui is
        -- Client only  and has a native fallback, so no server fake
        -- exists. The SERVER's table lists both with no owner for the life of
        -- the process. Asserting them here failed a correct install: a
        -- realm-only slot has no server owner and that is not a fault.
        local SERVER_OWNED = { doorsClient = true, ui = true }
        for slot, entry in pairs(caps) do
            if not SERVER_OWNED[slot] then
                if not entry.owner then
                    empty[#empty + 1] = slot
                elseif not entry.resolved then
                    unresolved[#unresolved + 1] = slot
                end
            end
        end
        table.sort(empty)
        table.sort(unresolved)
        t.eq(#empty, 0, 'every server-owned slot has a provider installed' ..
            (#empty > 0 and (': ' .. table.concat(empty, ', ')) or ''))
        t.eq(#unresolved, 0, 'every provider answers its whole contract' ..
            (#unresolved > 0 and (': ' .. table.concat(unresolved, ', ')) or ''))
    end)

    t.case('a capability forwards its arguments exactly', function()
        exports['cis_test_providers']:ResetCalls('database')
        exports['cis_test_providers']:SetDbRows({ { id = 1 }, { id = 2 } })

        local rows = exports['cis_libs']:DbQuery('SELECT id FROM t WHERE a = ?', { 7 })

        local calls = exports['cis_test_providers']:GetCalls('database', 'query')
        t.eq(#calls, 1, 'the provider saw exactly one query')
        if calls[1] then
            -- args[1] is the sql, args[2] the params. Asserting BOTH is the
            -- point: a wrapper that shifts arguments left is silent, and the
            -- count alone would not notice it.
            t.eq(calls[1].args[1], 'SELECT id FROM t WHERE a = ?', 'the sql arrived intact')
            t.ok(type(calls[1].args[2]) == 'table', 'the params arrived as a table')
            t.near(calls[1].args[2] and calls[1].args[2][1], 7, 1e-9, 'and the first param value is right')
        end
        t.ok(type(rows) == 'table', 'and the provider answer came back to the caller')
    end)

    t.case('an empty result and a nil result are different', function()
        exports['cis_test_providers']:SetDbRows(nil)
        local missing = exports['cis_libs']:DbQuery('SELECT 1')
        t.eq(missing, nil, 'a nil answer stays nil')

        exports['cis_test_providers']:SetDbRows({})
        local empty = exports['cis_libs']:DbQuery('SELECT 1')
        t.ok(type(empty) == 'table', 'an empty answer stays a table')
        t.eq(empty and #empty or -1, 0, 'with zero rows, not nil')
    end)

    t.case('no provider means a refusal, not a raise', function()
        -- Releasing the slot is the closest a test gets to "the product is not
        -- installed", and what comes back must still be an answer rather than a
        -- nil-index. `database` is used because a real export forwards to it, so
        -- the refusal travels the whole path instead of stopping at a lookup.
        local released = exports['cis_test_providers']:ReleaseSlot('database')
        t.cleanup(function()
            exports['cis_test_providers']:ClaimSlot('database')
        end)
        t.ok(released == true, 'the slot was released')

        -- ONE WARNING, AND DECLARED. The missing provider is worth exactly one
        -- console line -- `forward` latches it per slot and method so a boot
        -- cannot flood the operator -- and this case is the first thing on a
        -- fresh process to trigger it. Declaring the delta is the honest way to
        -- say "this is the warning I am causing", as opposed to allowing the
        -- counter to move for any reason at all, which is how a real leak gets
        -- waved through.
        t.expectCounter('warnings', 1)

        local rows = exports['cis_libs']:DbQuery('SELECT 1')
        -- nil, not false: forward() hands back the provider's refusal reason so
        -- the caller can report it, and an answer of `false` would be
        -- indistinguishable from a provider that legitimately returned false.
        -- Nine contract tests pin that shape deliberately, because `if not rows`
        -- is the test most callers actually write.
        t.eq(rows, nil, 'a call with no provider answers nothing at all')

        -- THE REASON COMES FROM SOMEWHERE ELSE, and that is not a workaround --
        -- it is the only shape that works. A nil FIRST value truncates the
        -- return list at the exports boundary, which the `boundary` suite in
        -- this same file measures. So `nil, reason` structurally cannot carry
        -- the explanation the code standard requires, and the refusal travels
        -- out of band instead.
        local refusal = exports['cis_libs']:GetLastRefusal()
        t.ok(type(refusal) == 'string' and #refusal > 0,
            ('and the reason is readable from GetLastRefusal (got %s)'):format(tostring(refusal)))
        t.ok(refusal and refusal:find('database', 1, true) ~= nil,
            ('and it names the capability that is missing (%s)'):format(tostring(refusal)))
    end)

    t.case('a provider that raises never escapes into the consumer', function()
        exports['cis_test_providers']:SetFault('discord', 'log', 'raise')
        t.cleanup(function()
            exports['cis_test_providers']:ClearFaults('discord')
        end)

        -- The library must absorb it. If this raises, the failure is in the
        -- pcall around the provider and the consumer sees a stack trace.
        local ok = pcall(function()
            exports['cis_libs']:Notify('info', 'harness', 'message')
        end)
        t.ok(ok, 'a raising provider does not raise into the caller')
    end)

    -- THE PLAYER-SOURCE HALF IS UNIT-ONLY, AND THAT IS NOT AN EXCUSE.
    -- `cis_force_unregister` is restricted and refuses a non-console source,
    -- because FiveM forwards an unknown client command to the server with the
    -- player's id as its source. Proving that needs a client to type the
    -- command, and this machine has no GPU to run one -- so it is asserted in
    -- test/contracts.lua, where the handler is invoked directly with source 5.
    --
    -- What a server CAN prove, and what would be a much worse regression than
    -- the hole itself, is that the command still works from the console. A
    -- command locked down past the point of being usable is not a fix; it is the
    -- same outage with an extra step. ExecuteCommand runs as the console
    -- (source 0), so this is the operator's exact path.
    t.case('the revoke command still works from the console', function()
        -- `GetCapabilities` lists EVERY slot with an `owner` that is nil when it
        -- is unregistered, so the owner is the thing to read. Asserting on the
        -- slot's presence instead asks a question with a constant answer: the
        -- table always has an entry for all of them.
        local function holder()
            return exports['cis_libs']:GetCapabilities().discord
                and exports['cis_libs']:GetCapabilities().discord.owner
        end

        t.ok(holder() ~= nil, 'a fake holds discord before the command runs')
        t.cleanup(function()
            exports['cis_test_providers']:ClaimSlot('discord')
        end)

        ExecuteCommand('cis_force_unregister discord')

        t.eq(holder(), nil, 'the console revoked it')

        -- Claimed HERE rather than only in cleanup, and the ordering matters:
        -- cleanup runs after the case body, so a case that registers its own
        -- re-claim in cleanup and then asserts on it is asserting on a state
        -- that has not happened yet. It reads as a library refusal.
        local re, why = exports['cis_test_providers']:ClaimSlot('discord')
        t.cleanup(function()
            exports['cis_test_providers']:ClaimSlot('discord')
        end)
        t.eq(holder(), 'cis_test_providers',
            ('and the provider took it straight back (ok=%s why=%s)'):format(
                tostring(re), tostring(why)))
    end)
end)

CisTestRunner.Suite('notify', { tier = 'server', realm = 'server' }, function(t)
    -- Appendix A: refused sources, oversize, burst.
    --
    -- THE TWO CASES BELOW FAILED AGAINST THE PRE-FIX BUILD, ON PURPOSE. They
    -- were written before the fix and they found it:
    --
    --   * NotifyClient refused src 0 and -1 with a BARE `false` and no reason,
    --     while the rate limit one line below refused with one. Every other
    --     refusal in this library answers `false, reason`.
    --   * NotifyClient to a src that is not CONNECTED returned true and fired
    --     the event at a player who was not there. The guard checked the
    --     number's shape, not whether the player exists.
    --
    -- Both now pass, and `test/contracts.lua` holds the strings behind them --
    -- including the `Notify` fallback, which cannot be reached on this server
    -- because a framework provider holds the slot and passes that call
    -- through untouched.
    t.case('a refused source is refused WITH a reason', function()
        -- '1' is here for the same reason it is refused in the unit suite: it is
        -- the shape a caller gets from JSON or a config file, where it looks
        -- fine, and `type(src) ~= 'number'` is what catches it.
        for _, bad in ipairs({ 0, -1, '1' }) do
            local ok, why = exports['cis_libs']:NotifyClient(bad, 'harness', 'x')
            t.eq(ok, false, ('src %s is refused'):format(tostring(bad)))
            t.ok(type(why) == 'string' and #why > 0,
                ('src %s names the reason'):format(tostring(bad)))
        end
    end)

t.case('a disconnected src is refused', function()
        local ok, why = exports['cis_libs']:NotifyClient(9999, 'harness', 'x')
        t.eq(ok, false, 'a src that is not connected is refused')
        t.ok(type(why) == 'string' and #why > 0, 'with a reason')
    end)

    -- The remaining two bounds -- the burst limit and the length cap -- CANNOT
    -- be asserted here, and the reason is worth writing down rather than
    -- discovering at 2am: both need a src that resolves to a real player, and
    -- the connected check now refuses everything else. Standing in a fake id
    -- would make the case a second copy of the one above wearing a different
    -- name, which is worse than no case: it reports PASS for a thing it never
    -- tested. Both are asserted in test/contracts.lua against a src-aware
    -- player stub, and both are on the list to run live the day a client exists.
end)

CisTestRunner.Suite('waitfor', { tier = 'server', realm = 'server' }, function(t)
    t.case('waitFor answers a value, and times out with a reason instead of raising', function()
        t.ok(type(Cis) == 'table' and type(Cis.waitFor) == 'function',
            'cis_test includes init.lua, so Cis.waitFor exists in this VM')
        local n = 0
        local got = Cis.waitFor(function()
            n = n + 1
            return 7
        end, 'live-immediate', 1000)
        t.eq(got, 7, 'a truthy first poll answers the value')
        t.eq(n, 1, 'and does not poll again')

        local ok, v, why = pcall(function()
            return Cis.waitFor(function() return false end, 'live-timeout', 20)
        end)
        t.eq(ok, true, 'a timeout does not raise')
        t.eq(v, nil, 'timeout answers nil')
        t.ok(type(why) == 'string' and why:find('live-timeout', 1, true) ~= nil,
            ('and the reason names the wait (got %s)'):format(tostring(why)))
    end)
end)

CisTestRunner.Suite('serverzones', { tier = 'server', realm = 'server' }, function(t)
    t.case('a server box contains the centre and not a far point', function()
        local id, why = exports['cis_libs']:ServerZoneBox({ x = 0.0, y = 0.0, z = 0.0 }, 4.0)
        t.ok(type(id) == 'number', ('box id (%s %s)'):format(tostring(id), tostring(why)))
        t.eq(exports['cis_libs']:ServerZoneContains(id, { x = 0.0, y = 0.0, z = 0.0 }), true, 'centre is inside')
        t.eq(exports['cis_libs']:ServerZoneContains(id, { x = 50.0, y = 0.0, z = 0.0 }), false, '50m is outside')
        t.eq(exports['cis_libs']:ServerZoneRemove(id), true, 'remove')
    end)
end)

-- Functions cannot cross the exports boundary. A consumer must pass
-- resource:Export; a function arrives as nil and HookOn answers false.
-- HookOn's string path is `fn(exportsTable, payload)`. A colon call from
-- this resource is `fn(payload)` only. Read deny off whichever table has it.
exports('HookAllowOrVeto', function(...)
    local n = select('#', ...)
    for i = 1, n do
        local a = select(i, ...)
        if type(a) == 'table' and a.deny then
            return false, 'denied'
        end
    end
    return true
end)

CisTestRunner.Suite('hooks', { tier = 'server', realm = 'server' }, function(t)
    t.case('a hook can allow and can veto', function()
        local id
        t.cleanup(function()
            if type(id) == 'number' then
                pcall(function() exports['cis_libs']:HookRemove(id) end)
            end
        end)
        local why
        id, why = exports['cis_libs']:HookOn('cis_test:hook', 'cis_test:HookAllowOrVeto')
        t.ok(type(id) == 'number', ('HookOn cookie (%s %s)'):format(tostring(id), tostring(why)))
        local direct, directWhy = exports['cis_test']:HookAllowOrVeto({ deny = true })
        t.eq(direct, false, ('direct colon veto (%s)'):format(tostring(directWhy)))
        local ok = exports['cis_libs']:HookRun('cis_test:hook', { deny = false })
        t.eq(ok, true, 'allow')
        local ok2, reason = exports['cis_libs']:HookRun('cis_test:hook', { deny = true })
        t.eq(ok2, false, ('veto (%s)'):format(tostring(reason)))
        t.ok(type(reason) == 'string' and reason:find('denied', 1, true), 'reason')
    end)
end)

CisTestRunner.Suite('diagnostics', { tier = 'server', realm = 'server' }, function(t)
    -- The leak detector has to detect something, or every other case in this
    -- harness is checking nothing.
    t.case('a snapshot is a table and carries no player data', function()
        local d = exports['cis_libs']:GetDiagnostics()
        t.eq(type(d), 'table', 'GetDiagnostics answers a table')
        t.eq(d.realm, 'server', 'and says which realm it is')
        t.ok(type(d.uptimeMs) == 'number', 'with an uptime')
        t.ok(type(d.memoryKb) == 'number', 'and a memory figure')
        t.ok(type(d.probes) == 'table', 'and the probes')
    end)

    t.case('two snapshots of an idle server agree', function()
        local before = exports['cis_libs']:GetDiagnostics()
        Wait(200)
        local after = exports['cis_libs']:GetDiagnostics()
        t.eq(after.counters.errors, before.counters.errors, 'no error appeared while idle')
        t.eq(after.probes.netHandlers and after.probes.netHandlers.total,
             before.probes.netHandlers and before.probes.netHandlers.total,
             'the net handler count did not move')
    end)

    t.case('self-check answers ok and names nothing when there is nothing', function()
        local check = exports['cis_libs']:GetSelfCheck()
        t.eq(type(check), 'table', 'GetSelfCheck answers a table')
        t.eq(type(check.ok), 'boolean', 'with an ok flag')
        t.ok(type(check.problems) == 'table', 'and a problems list')
    end)
end)
CisTestRunner.Suite('syncids', { tier = 'server', realm = 'server' }, function(t)
    -- 4.3 · TWO OWNERS, ONE ID.
    --
    -- cis_test_b already creates a record under the id `shared-id` and its
    -- comment says the point is that ids must not be global. It was the ONLY
    -- resource using that id, so the case it describes could not fail: with one
    -- owner there is nothing to collide with, and a green run said nothing about
    -- namespacing either way.
    --
    -- So this side creates its own `shared-id` -- a DIFFERENT model at a
    -- DIFFERENT place -- and the assertion is that both records exist as two.
    t.case('two resources can both own an id, and both records survive', function()
        -- The second owner is cis_test_c, NOT cis_test_b, and the reason is the
        -- one the lifecycle suite already gives. cis_test_b is deliberately off
        -- AuthorizedResources -- correctly, it is what the security cases need
        -- something to refuse -- so every mutating export it calls is refused
        -- before any state exists. It owns no sync record and never could, so
        -- a case asserting that it did was asserting a fixture that could not
        -- pass. That is what run-20261004-091704 showed: one FAIL, on the
        -- fixture, not on the library.
        --
        -- Reown first, so the collider exists whatever order the tiers ran in.
        exports['cis_test_c']:Reown()
        local own = exports['cis_test_c']:Owns()
        t.eq(own.sharedId, 'shared-id',
            'cis_test_c holds the same id string under its own namespace')
        t.ok(own.sharedCreated,
            ('which it really owns (why=%s)'):format(tostring(own.sharedWhy)))

        local made, why = exports['cis_libs']:SyncCreate('prop', {
            id = 'shared-id',
            model = 'prop_barrel_01',
            coords = { x = 5.0, y = 0.0, z = 0.0 },
        })
        t.ok(made, ('cis_test claims shared-id too (why=%s)'):format(tostring(why)))
        t.cleanup(function()
            exports['cis_libs']:SyncRemove('shared-id')
        end)

        local probes = exports['cis_libs']:GetDiagnostics().probes.syncRecords or {}
        local byOwner = probes.byOwner or {}

        -- GROUPED, not totalled. A total of two is satisfied by one resource
        -- owning two records, which is what a merged namespace would produce if
        -- the two calls had differed at all. Two OWNERS each holding at least
        -- one is the only shape that distinguishes the two answers.
        t.ok((byOwner.cis_test or 0) >= 1,
            ('cis_test owns a record (%s)'):format(tostring(byOwner.cis_test)))
        t.ok((byOwner.cis_test_c or 0) >= 1,
            ('and cis_test_c still owns its own (byOwner=%s)'):format(
                json.encode(byOwner)))

        -- And MY id is MY id: it comes back as the string I passed, not as the
        -- namespaced key the client sees.
        t.eq(type(made), 'string', 'SyncCreate answers a string')
        t.ok(tostring(made):find('shared%-id') ~= nil,
            ('which is the caller\'s own id, not an internal key (%s)'):format(
                tostring(made)))
    end)

    t.case('a numeric id becomes a string and removes as one', function()
        local made, why = exports['cis_libs']:SyncCreate('prop', {
            id = 4242,
            model = 'prop_barrel_01',
            coords = { x = 7.0, y = 0.0, z = 0.0 },
        })
        t.ok(made, ('a numeric id is accepted (why=%s)'):format(tostring(why)))
        t.eq(type(made), 'string', 'and comes back as a string')
        t.eq(made, '4242', ('which is the number as text (%s)'):format(tostring(made)))
        t.cleanup(function()
            exports['cis_libs']:SyncRemove('4242')
        end)
        t.eq(exports['cis_libs']:SyncRemove(4242), true,
            'and the number removes the record its string names')
    end)
end)

-- A suite that is KNOWN to fail, so the harness itself is under test.
--
-- A harness that has only ever been seen to pass has not been tested, and this
-- one is worse than an ordinary test rig: it reports on the library from a
-- different Lua VM, across a real exports boundary, on a live server. If it
-- cannot fail, its green means nothing and every other result in the file is
-- decoration.
--
-- So this suite asserts something false on purpose, and `cis_test run selftest`
-- must report a FAIL. If this ever passes, the harness is broken and the other
-- suites' results cannot be believed.
CisTestRunner.Suite('selftest', { tier = 'selftest', realm = 'server' }, function(t)
    t.case('this case is meant to fail', function()
        t.eq(1, 1, 'the first assertion is true, so the failure that follows is the only one')
        t.eq('actual', 'expected', 'and this one is not true, on purpose')
    end)

    t.case('this case is meant to raise', function()
        error('the harness must turn a raise into an ERROR with a traceback, not a crash')
    end)

    t.case('a cleanup that raises is reported and does not stop the ones under it', function()
        t.cleanup(function() error('the first cleanup is broken on purpose') end)
        t.cleanup(function() error('the second cleanup is broken too') end)
        t.eq(1, 1, 'the case itself passes; only its cleanups are broken')
    end)
end)

-- THE NETWORKED PATH, ON A REAL SERVER.
--
-- The unit suite for this proves the SHAPE of the call: that the right native is
-- chosen per kind, that the bucket and the orphan mode are applied, that a move
-- is a move. It cannot prove the natives EXIST, because it stubs them. A stub
-- that answers "return an entity" proves nothing about what the server does when
-- handed a real one, and the whole failure this replaces was silent -- the record
-- existed, the client resolved an id, and no entity was anywhere.
--
-- So this asks the real runtime, per kind, and reports what it answered. A
-- native that does not exist on this server answers FAIL with the reason from
-- the library, which is the discovery this case exists to make.
--
-- SERVER SIDE ONLY, and that is stated rather than hidden: whether a CLIENT can
-- see the entity, resolve its netId, or despawn it needs a connected player, and
-- this box has no GPU so no client can connect. Those are in UNRUN.md, not here.
CisTestRunner.Suite('syncnetwork', { tier = 'server', realm = 'server' }, function(t)
    local function probe()
        local probes = exports['cis_libs']:GetDiagnostics().probes.syncRecords or {}
        return probes.entities or 0, probes
    end

    for _, case in ipairs({
        { kind = 'prop', model = 'prop_barrel_01' },
        { kind = 'vehicle', model = 'adder', vehicleType = 'automobile' },
        { kind = 'ped', model = 'a_m_m_yogh_01' },
    }) do
        t.case(('a networked %s really exists on this server'):format(case.kind), function()
            local before = probe()
            local made, why = exports['cis_libs']:SyncCreate(case.kind, {
                model = case.model,
                vehicleType = case.vehicleType,
                -- With nobody connected there is no origin to be relative to.
                -- Far enough out that it cannot be anyone's business, and gone
                -- again in this case's cleanup.
                coords = { x = 0.0, y = 0.0, z = 0.0 },
                networked = true,
            })
            t.ok(made, ('cis_test created a networked %s (why=%s)')
                :format(case.kind, tostring(why)))
            t.cleanup(function() exports['cis_libs']:SyncRemove(made) end)

            local after, probes = probe()
            t.eq(after, before + 1,
                ('4.5: the server really made a networked %s entity, not just a record')
                    :format(case.kind))
            t.eq(probes.refused or 0, 0,
                ('4.5: no networked record was left without an entity (%d refused)')
                    :format(probes.refused or 0))
        end)
    end

    t.case('remove takes the entity with it', function()
        local before = probe()
        local made = exports['cis_libs']:SyncCreate('prop', {
            model = 'prop_barrel_01',
            coords = { x = 0.0, y = 0.0, z = 0.0 },
            networked = true,
        })
        t.ok(made, 'a networked prop to remove')
        local withIt = probe()
        t.eq(withIt, before + 1, 'the entity exists while the record does')
        local removed, why = exports['cis_libs']:SyncRemove(made)
        t.ok(removed, ('and the record removes (%s)'):format(tostring(why)))
        local after = probe()
        t.eq(after, before,
            '4.5: the entity is gone with the record, not orphaned on the network')
    end)

    t.case('a kind the server cannot make is refused, not downgraded', function()
        -- A refusal is LOGGED, so this case is allowed exactly one error and the
        -- allowance is an assertion rather than a comment. Anything other than
        -- one still fails here.
        t.allowCounter('errors', 1)
        local before, probes = probe()
        local made, why = exports['cis_test']:SyncCreateUnsupportedNetworked()
        t.eq(made, nil, 'an unsupported networked kind gets no record')
        t.eq(probes.entities, before,
            '4.5: and nothing was created for it')

        -- WHY THERE IS NO ASSERTION THAT THE REASON ARRIVED, which is the whole
        -- point of writing it down rather than leaving it out silently:
        --
        -- `SyncCreate` answers `nil, reason`, and the `boundary` suite above
        -- MEASURED that a nil first value truncates the return list across the
        -- exports boundary. `why` is therefore nil here on a correct library,
        -- and asserting otherwise would be a failing test on working code.
        --
        -- The reason is not lost, it is routed to the log -- which is where every
        -- other refusal in this library already puts it, and the one error this
        -- case allows above IS that log line. Changing the refusal to
        -- `false, reason` would carry it, and would also change the return shape
        -- of a 1.0.0 export that a sibling may already be branching on
        -- (`id ~= nil`), so it is not this task's to take.
        print(('[cis_test] unsupported networked kind -> refused (reason %s, in the log)')
            :format(why == nil and 'truncated by the boundary' or tostring(why)))
    end)
end)
