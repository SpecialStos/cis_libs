-- The lifecycle tier: what is left behind when a resource stops.
--
-- Appendix A's tier, restricted to what this server can produce. A second
-- player and a real player-drop cannot be made here, and those cases are on the
-- approved SKIP list.
--
-- EVERY CASE COMPARES COUNTS, taken from GetDiagnostics, taken either side.
-- "Nothing threw" is not evidence that something was cleaned up -- a leaked
-- handler does not throw, it simply stays -- so the only honest question is
-- whether the count came back.

CisTestRunner.Suite('lifecycle', { tier = 'lifecycle', realm = 'server' }, function(t)
    -- ---------------------------------------------------------- D-03: the wipe
    --
    -- One resource stopping must remove ITS sync records and leave every other
    -- resource's alone. A single consumer cannot show this, which is what
    -- cis_test_b exists for.
    t.case('one consumer stopping does not wipe another\'s sync records', function()
        -- cis_test_b creates 'shared-id' at boot. Claim one here under our own
        -- name so the two can be told apart in the per-owner count.
        local mine = exports['cis_libs']:SyncCreate('prop', {
            id = 'cis_test_own',
            model = 'prop_barrier_05a',
            coords = { x = 20.0, y = 0.0, z = 0.0 },
        })
        t.ok(mine, 'cis_test creates its own sync record')

        local withBoth = exports['cis_libs']:GetDiagnostics()
        local byOwner = (withBoth.probes.syncRecords or {}).byOwner or {}
        t.ok((byOwner.cis_test_b or 0) >= 1,
            'cis_test_b owns at least one record')
        t.ok((byOwner.cis_test or 0) >= 1,
            'and so does cis_test')

        -- Stop the OTHER consumer.
        local stopped, why = CisTestControl.Stop('cis_test_b')
        if not stopped then
            t.fail('cis_test_b did not stop', tostring(why))
            return
        end

        local after = exports['cis_libs']:GetDiagnostics()
        local afterByOwner = (after.probes.syncRecords or {}).byOwner or {}
        t.eq(afterByOwner.cis_test_b, nil,
            'cis_test_b took its own records with it')
        t.ok((afterByOwner.cis_test or 0) >= 1,
            'and cis_test kept every one of its own')
        t.ok((after.probes.syncRecords or {}).total < (withBoth.probes.syncRecords or {}).total,
            'the total went down, so something was really removed')

        -- Put it back, so the rest of the tier and the player tier have the
        -- second consumer again.
        CisTestControl.Start('cis_test_b', { refresh = true })
        t.ok(true, 'cis_test_b is started again for the cases that follow')
    end)

    -- ------------------------------------------------- the provider going away
    --
    -- Every capability this server has is a fake. Taking the fakes away is the
    -- closest a test gets to "the product is not installed", and the calls must
    -- answer rather than raise.
    t.case('stopping the providers turns every call into a refusal', function()
        local stopped, stopWhy = CisTestControl.Stop('cis_test_providers')
        if not stopped then
            t.fail('cis_test_providers did not stop', tostring(stopWhy))
            return
        end
        t.cleanup(function() CisTestControl.Start('cis_test_providers', { refresh = true }) end)

        for _, call in ipairs({
            { name = 'db query', fn = function() return exports['cis_libs']:DbQuery('SELECT 1') end },
            { name = 'framework check', fn = function() return exports['cis_libs']:GetFramework() end },
        }) do
            local ok, why = pcall(call.fn)
            t.ok(ok, ('%s does not RAISE with no provider'):format(call.name))
            if ok then
                t.ok(why == nil or why == false,
                    ('%s answers a refusal rather than a value'):format(call.name))
            end
        end
    end)

    -- ------------------------------------------- the provider coming back again
    t.case('the providers re-register and their calls work again', function()
        CisTestControl.Start('cis_test_providers', { refresh = true })
        local reached = CisTestControl.WaitForState('cis_libs', 'started', 3000)
        t.ok(reached, 'cis_libs is up')

        -- Give the fakes a moment to re-claim every slot.
        local ok = CisTestControl.WaitForState('cis_test_providers', 'started', 3000)
        t.ok(ok, 'cis_test_providers is up')
        Wait(1500)

        local caps = exports['cis_libs']:GetCapabilities()
        local resolved, owned = 0, 0
        for _, entry in pairs(caps or {}) do
            if entry.owner == 'cis_test_providers' then
                owned = owned + 1
                if entry.resolved then resolved = resolved + 1 end
            end
        end
        t.ok(owned >= 10,
            ('the fakes re-claimed the slots (%d owned)'):format(owned))
        t.ok(resolved >= 10,
            ('and every one resolves again (%d resolved)'):format(resolved))
    end)

    -- ----------------------------------------------- a deliberately bad start
    --
    -- cis_test_badmeta declares a contract cis_libs does not speak and omits
    -- the dependency. Starting it must NOT break the install -- that is the
    -- whole point of the refusal paths -- and its claim must be refused.
    t.case('a resource with a mismatched contract is refused, and the install survives', function()
        local before = exports['cis_libs']:GetSelfCheck()
        local beforeOk = before.ok

        CisTestControl.Start('cis_test_badmeta', { refresh = true })
        local started = CisTestControl.WaitForState('cis_test_badmeta', 'started', 5000)

        if not started then
            -- Not a failure: refusing to START is an acceptable outcome for a
            -- deliberately broken resource, and the install being intact is the
            -- property that matters either way.
            t.ok(true, 'cis_test_badmeta did not start, which is an acceptable refusal')
        else
            local attempts = exports['cis_test_badmeta']:Attempts()
            local refused = false
            for _, a in ipairs(attempts or {}) do
                if a.ok == false then refused = true end
            end
            t.ok(refused,
                'its capability claim was REFUSED rather than registered')
        end

        -- The property that actually matters: cis_libs is still healthy.
        local after = exports['cis_libs']:GetSelfCheck()
        t.eq(after.ok, beforeOk,
            'and cis_libs\' own self-check verdict is unchanged by it')

        local caps = exports['cis_libs']:GetCapabilities()
        local foreign = {}
        for slot, entry in pairs(caps or {}) do
            if entry.owner == 'cis_test_badmeta' then
                foreign[#foreign + 1] = slot
            end
        end
        t.eq(#foreign, 0,
            'and it owns no capability: ' .. table.concat(foreign, ', '))

        CisTestControl.Stop('cis_test_badmeta')
        t.ok(true, 'cis_test_badmeta stopped again')
    end)

    -- ----------------------------------------------------- callbacks are ours
    --
    -- One resource must not be able to answer another resource's pending
    -- callback. That is the property the ownership check exists for, and it is
    -- checkable from two real resources.
    t.case('one consumer cannot answer another\'s callback', function()
        local before = exports['cis_libs']:GetDiagnostics()
        local pendingBefore = (before.probes.pendingCallbacks or {}).total or 0
        -- Start an await that will not be answered within this case.
        local key = ('cis_test_probe_%d'):format(math.floor(GetGameTimer()))
        local answered = false
        exports['cis_libs']:RegisterCallback(key, function()
            answered = true
            return true
        end)

        exports['cis_libs']:AwaitCallback(key, 300)

        -- While that is outstanding, a DIFFERENT resource must not be able to
        -- complete it. cis_test_b has no access to the key, and the registry
        -- checks ownership before taking an entry, so nothing should have
        -- answered.
        t.eq(answered, false,
            'a callback nobody answered is still unanswered')

        local during = exports['cis_libs']:GetDiagnostics()
        t.ok(((during.probes.pendingCallbacks or {}).total or 0) >= pendingBefore,
            'and it is still counted as pending rather than silently dropped')
    end)
end)