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
        -- doorsClient is DELIBERATELY excluded. It is registered by the client
        -- fakes in the client's own Lua state, so the SERVER's table lists it
        -- with no owner for the life of the process. Asserting it here failed a
        -- correct install, which is the same mistake the preflight made and the
        -- reason this comment exists: a realm-only slot has no server owner and
        -- that is not a fault.
        local SERVER_OWNED = { doorsClient = true }
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

        local rows, why = exports['cis_libs']:DbQuery('SELECT 1')
        -- nil, not false: forward() hands back the provider's refusal reason so
        -- the caller can report it, and an answer of `false` would be
        -- indistinguishable from a provider that legitimately returned false.
        t.eq(rows, nil, 'a call with no provider answers nothing at all')
        -- FAILS AT THE BASELINE, ON PURPOSE. `forward()` does compute the reason
        -- and does return it -- as its second value -- and it still arrives nil.
        -- Everything that answer goes through an EXPORT, and a second return
        -- value is exactly what this library's own comments say does not
        -- survive a crossing. So the refusal a caller sees has no explanation in
        -- it, which is the same defect as the notify one below and for the same
        -- reason: the code standard says every refusal answers with a reason, and
        -- the boundary is where the reason goes.
        t.ok(type(why) == 'string' and #why > 0,
            'and hands back a reason that says something (the reason is lost across the export: ' ..
            tostring(why) .. ')')
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
    -- because a framework provider holds the slot and DEC-13 passes that call
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
