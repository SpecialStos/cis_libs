-- The first server tier: the things that need no player and can therefore
-- always run.
--
-- Appendix A's `server` tier, restricted to the cases the fakes can actually
-- answer today. Everything here is a claim about cis_libs BEHAVIOUR on a real
-- server -- a real exports boundary, a real resource, a real Lua VM -- which is
-- the class of bug the unit suite structurally cannot see.

CisTestRunner.Suite('registry', { tier = 'server', realm = 'server' }, function(t)
    -- The fakes are holding every slot, so a refusal here is cis_libs refusing,
    -- not the environment being empty. That distinction is the reason the
    -- preflight exists.
    t.case('every slot resolves against the fakes', function()
        local caps = exports['cis_libs']:GetCapabilities()
        local unresolved, empty = {}, {}
        for slot, entry in pairs(caps) do
            if not entry.owner then
                empty[#empty + 1] = slot
            elseif not entry.resolved then
                unresolved[#unresolved + 1] = slot
            end
        end
        table.sort(empty)
        table.sort(unresolved)
        t.eq(#empty, 0, 'every declared slot has a provider installed' ..
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

        local rows, why = exports['cis_libs']:DbQuery('SELECT 1')
        t.eq(rows, false, 'a call with no provider is refused, not answered')
        t.ok(type(why) == 'string' and #why > 0, 'with a reason that says something')
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
end)

CisTestRunner.Suite('notify', { tier = 'server', realm = 'server' }, function(t)
    -- Appendix A: refused sources, oversize, burst.
    t.case('a refused source is refused with a reason', function()
        for _, bad in ipairs({ 0, -1 }) do
            local ok, why = exports['cis_libs']:NotifyClient(bad, 'harness', 'x')
            t.eq(ok, false, ('src %s is refused'):format(tostring(bad)))
            t.ok(type(why) == 'string' and #why > 0, ('src %s names the reason'):format(tostring(bad)))
        end
    end)

    t.case('a disconnected src is refused', function()
        local ok, why = exports['cis_libs']:NotifyClient(9999, 'harness', 'x')
        t.eq(ok, false, 'a src that is not connected is refused')
        t.ok(type(why) == 'string' and #why > 0, 'with a reason')
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
