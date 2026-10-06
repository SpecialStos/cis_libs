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
    -- ---------------------------------------------------------- the wipe
    --
    -- One resource stopping must remove ITS sync records and leave every other
    -- resource's alone. A single consumer cannot show this, which is what
    -- cis_test_b exists for.
    t.case('one consumer stopping does not wipe another\'s sync records', function()
        -- cis_test_c creates a record at boot under its own name, so the two
        -- can be told apart in the per-owner count.
        --
        -- IT IS cis_test_c AND NOT cis_test_b, and the reason is worth keeping.
        -- cis_test_b is deliberately off AuthorizedResources -- correctly, it is
        -- what the security cases need something to refuse -- so every mutating
        -- export it calls comes back refused before any state exists. It owns no
        -- sync record and never could, so a case asserting that it does was
        -- asserting a fixture that could not pass: it reported a library defect
        -- that was never there. Ownership needs an authorized second consumer.
        local own = exports['cis_test_c']:Owns()
        t.ok(own.created,
            ('cis_test_c owns its record (why=%s)'):format(tostring(own.why)))

        -- Claim one here under our own name, so the two can be told apart.
        local mine = exports['cis_libs']:SyncCreate('prop', {
            id = 'cis_test_own',
            model = 'prop_barrier_05a',
            coords = { x = 20.0, y = 0.0, z = 0.0 },
        })
        t.ok(mine, 'cis_test creates its own sync record')

        local withBoth = exports['cis_libs']:GetDiagnostics()
        local byOwner = (withBoth.probes.syncRecords or {}).byOwner or {}
        t.ok((byOwner.cis_test_c or 0) >= 1,
            'cis_test_c owns at least one record')
        t.ok((byOwner.cis_test or 0) >= 1,
            'and so does cis_test')

        -- Stop the OTHER consumer.
        local stopped, why = CisTestControl.Stop('cis_test_c')
        if not stopped then
            t.fail('cis_test_c did not stop', tostring(why))
            return
        end
        t.cleanup(function()
            -- Put it back, so the rest of the tier and the player tier have the
            -- second consumer again -- and re-own, because a restarted resource
            -- starts with nothing.
            CisTestControl.Start('cis_test_c', { refresh = true })
            exports['cis_test_c']:Reown()
        end)

        local after = exports['cis_libs']:GetDiagnostics()
        local afterByOwner = (after.probes.syncRecords or {}).byOwner or {}
        t.eq(afterByOwner.cis_test_c, nil,
            'cis_test_c took its own records with it')
        t.ok((afterByOwner.cis_test or 0) >= 1,
            'and cis_test kept every one of its own')
        t.ok((after.probes.syncRecords or {}).total < (withBoth.probes.syncRecords or {}).total,
            'the total went down, so something was really removed')
    end)

    -- ------------------------------------------------- the provider going away
    --
    -- Every capability this server has is a fake. Taking the fakes away is the
    -- closest a test gets to "the product is not installed", and the calls must
    -- answer rather than raise.
    t.case('stopping the providers turns every call into a refusal', function()
        -- Refusals log warnings, and how many is a property of the registry,
        -- not of this case. See Case:allowCounterAny.
        t.allowCounterAny('warnings')
        local stopped, stopWhy = CisTestControl.Stop('cis_test_providers')
        if not stopped then
            t.fail('cis_test_providers did not stop', tostring(stopWhy))
            return
        end
        t.cleanup(function() CisTestControl.Start('cis_test_providers', { refresh = true }) end)

        for _, call in ipairs({
            { name = 'db query', fn = function() return exports['cis_libs']:DbQuery('SELECT 1') end },
            { name = 'framework check', fn = function() return exports['cis_libs']:GetNormalizedPlayer(1) end },
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
        -- Refusals log warnings, and how many is a property of the registry,
        -- not of this case. See Case:allowCounterAny.
        t.allowCounterAny('warnings')
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
        -- Refusals log warnings, and how many is a property of the registry,
        -- not of this case. See Case:allowCounterAny.
        t.allowCounterAny('warnings')
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
            -- A STARTED RESOURCE IS NOT A RESOURCE THAT HAS ACTED.
            --
            -- badmeta's claim runs in a CreateThread that first waits for
            -- cis_libs to be started, and only then calls RegisterCapability.
            -- This case used to read Attempts() the moment the resource reached
            -- 'started', which is before that thread has done anything --
            -- `attempts` was empty every single run, `refused` stayed false,
            -- and the case reported that the contract check had FAILED. The
            -- server log shows it plainly: `Started resource cis_test_badmeta`
            -- immediately followed by `Stopping resource cis_test_badmeta`,
            -- with no output from the resource in between.
            --
            -- So this waited 8 seconds on an "undiagnosed P0" that the fixture
            -- had never once exercised. Wait for the ATTEMPT, not the start.
            local refused = false
            local recorded = 0
            local deadline = GetGameTimer() + 8000
            while GetGameTimer() < deadline do
                local attempts = exports['cis_test_badmeta']:Attempts() or {}
                recorded = #attempts
                refused = false
                for _, a in ipairs(attempts) do
                    if a.ok == false then refused = true end
                end
                if recorded > 0 then break end
                Wait(100)
            end
            t.ok(refused,
                ('its capability claim was REFUSED rather than registered '
                    .. '(attempts recorded: %d)'):format(recorded))
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
    t.case('stopping a consumer releases its callbacks and nobody else\'s', function()
        -- THE PREVIOUS VERSION OF THIS CASE COULD NOT PASS, and it failed for a
        -- reason that read exactly like a security hole. It registered a handler
        -- that set `answered = true`, then started an await on it, then asserted
        -- `answered == false`. The handler ran because the case itself was the
        -- one awaiting -- cis_test answering cis_test -- so the assertion was
        -- "the thing I just did did not happen". It is a case that must fail.
        --
        -- WHAT REPLACED IT, AND WHY IT IS A BETTER QUESTION. The property the old
        -- case was reaching for -- a client cannot answer another client's
        -- pending callback -- needs a client, because there is no server-side
        -- path that can forge a client event. That half is asserted in
        -- test/server.lua, which emits `cis_libs:cb:serverRes` from a foreign
        -- source and then has the real owner answer its own.
        --
        -- The half that IS reachable here is the owner's: a resource stopping
        -- takes its own callbacks with it and leaves every other resource's
        -- alone. A sweep that took everything would be a different bug, and an
        -- easier one to write.
        local own = exports['cis_test_c']:Owns()
        t.ok(own.callbackName ~= nil, 'cis_test_c registered a callback')

        local mine = 'cis_test_own_cb'
        t.ok(exports['cis_libs']:RegisterCallback(mine, function() return 'from cis_test' end),
            'cis_test registers one of its own')

        -- THE AWAIT FORM, NOT `CallCallback`, AND THAT IS NOT A STYLE CHOICE.
        --
        -- `CallCallback(name, cb)` takes a function as its second argument, and
        -- a function CANNOT CROSS THE EXPORTS BOUNDARY -- it arrives as nil, so
        -- the export takes its `type(cb) ~= 'function'` branch, logs and returns,
        -- and the caller's closure is never called. That is the library's own
        -- constraint, and it cost this case one debugging round: the first
        -- version waited three seconds for an answer that could not arrive by
        -- construction.
        --
        -- `TryAwaitCallback` is the form a caller in ANOTHER resource uses. It
        -- answers `true, ...values` or `false, reason` and raises on nothing,
        -- which is what makes "did the handler go away" a value to assert on.
        local function ask(name)
            local answered, value = exports['cis_libs']:TryAwaitCallback(name)
            return { ok = answered, value = value }
        end

        local other = ask(own.callbackName)
        t.eq(other.ok, true,
            ('cis_test_c\'s callback answers before the stop (ok=%s value=%s name=%s)')
                :format(tostring(other.ok), tostring(other.value), tostring(own.callbackName)))
        local ours = ask(mine)
        t.eq(ours.ok, true,
            ('and so does ours (ok=%s value=%s)'):format(tostring(ours.ok), tostring(ours.value)))

        local stopped, why = CisTestControl.Stop('cis_test_c')
        if not stopped then
            t.fail('cis_test_c did not stop', tostring(why))
            return
        end
        t.cleanup(function() CisTestControl.Start('cis_test_c', { refresh = true }) end)

        local gone = ask(own.callbackName)
        t.eq(gone.ok, false, 'the stopped resource\'s callback is released')
        -- "unknown", not "error": a consumer has to be able to tell its wiring is
        -- wrong from its handler throwing. Those send you to completely different
        -- files.
        t.ok(tostring(gone.value):find('unknown', 1, true) ~= nil,
            ('and answers "unknown", not "error" (%s)'):format(tostring(gone.value)))
        t.eq(ask(mine).ok, true, 'while cis_test kept its own')
    end)
end)
-- ============================================== 5.1: modules, loaded on demand
--
-- cis_libs used to list its fifteen algo/util modules in shared_scripts, so every
-- server parsed all fifteen at boot to get none of them: nothing in init.lua,
-- server/ or client/ named any of those globals. Stage 5.1 moved them to
-- `files {}` and added Cis.require.
--
-- THE CLAIM IS NEGATIVE, so it is worth proving on a live server rather than in
-- a comment: cis_libs' own realms install NONE of the fifteen. An empty
-- `present` is the proof, and the probe publishes it precisely because an empty
-- answer is the whole claim.
CisTestRunner.Suite('modules', { tier = 'lifecycle', realm = 'server' }, function(t)
    t.case('cis_libs installs none of its fifteen module globals', function()
        local probes = exports['cis_libs']:GetDiagnostics().probes.modules or {}
        local present = probes.present or {}
        t.eq(#present, 0, ('no module global exists on the server realm (%s)')
            :format(json.encode(present)))
        t.eq(probes.known, 15,
            ('and the probe knows about all fifteen, so an empty answer is a real '
                .. 'one and not a probe that found nothing (got %s)')
                :format(tostring(probes.known)))
    end)

    t.case('a consumer that includes a module directly still gets it', function()
        -- cis_test_b `@include`s @cis_libs/shared/algo/lru.lua on both realms.
        -- The file is inside cis_libs, so this path is the ONLY way a consumer
        -- can get a module at all, and 5.1 must not have taken it away.
        local probe = exports['cis_test_b']:IncludeProbe()
        t.eq(probe.lru, 'table',
            ('the directly-included module installed its global (%s)')
                :format(tostring(probe.lru)))
        t.eq(probe.lruWorks, true,
            'and it works: an LRU was built, written and read back')

        -- AND THE VARARG COUNT, which is what makes the two paths differ at all.
        -- A module installs its global when the chunk did NOT get the marker, so
        -- an include that passed even one argument would invert that rule
        -- silently -- and every directly-included module in the ecosystem would
        -- stop existing. Asserted rather than believed.
        -- THE PLAN ASKED FOR THIS AND THE ANSWER IS NO.
        --
        -- 'Verify live that a plain include really sees no varargs.' Measured on
        -- run-20261005-010506: a manifest include passes ONE, and its value is 2.
        -- So the premise is false -- and it was only ever a PREMISE, because the
        -- mechanism branches on the marker being present, not on the vararg list
        -- being empty.
        --
        -- Which is why the branch is written as it is. Had it been written
        -- 'if next(...) then' -- install the global when there IS anything -- the
        -- direct include above would have installed NOTHING, and every consumer
        -- @including a cis_libs module would have got a nil. The assertion that
        -- matters is therefore the one below, not the count.
        t.ok(probe.firstVararg ~= 'cis_require',
            ('the vararg a manifest include passes is NOT the marker, which is '
                .. 'the whole branch condition (got count=%s value=%s)')
                :format(tostring(probe.varargCount), tostring(probe.firstVararg)))
        t.ok(probe.lru == 'table',
            'and the global IS installed, so a direct include still works despite '
                .. 'the platform passing an argument nobody documented')
    end)

    t.case('ModuleInfo answers what a module is without handing it over', function()
        -- A function cannot cross the exports boundary, so a consumer cannot be
        -- given the module. It can be told whether the name is real, and -- only
        -- when it asks -- shown the module loading without installing a global.
        local peek = exports['cis_libs']:ModuleInfo('lru')
        t.eq(peek.ok, true, ('lru is a known module (%s)'):format(tostring(peek.why)))
        t.eq(type(peek.functions), 'nil',
            'asking without opts.load does not load it, and says no functions')

        local loaded = exports['cis_libs']:ModuleInfo('lru', { load = true })
        t.eq(loaded.ok, true, ('and it loads on request (%s)'):format(tostring(loaded.why)))
        t.eq(loaded.loaded, true, 'which is what it reports')
        t.eq(type(loaded.functions), 'table',
            ('with a function list a consumer can act on (n=%d)')
                :format(type(loaded.functions) == 'table' and #loaded.functions or -1))
        t.eq(loaded.globalPresentAfterLoad, false,
            'and loading it STILL installs no global -- the whole point of 5.1')

        local bogus = exports['cis_libs']:ModuleInfo('not_a_module')
        t.eq(bogus.ok, false, 'an unknown name is refused')
        t.ok(bogus.why and tostring(bogus.why):find('not_a_module', 1, true) ~= nil,
            ('and the refusal names what was asked for (%s)'):format(tostring(bogus.why)))
        t.ok(type(bogus.valid) == 'table' and #bogus.valid == 15,
            'and it lists the valid names, so the caller can fix the call')
    end)
end)
