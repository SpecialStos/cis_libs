-- Console commands. Every one refuses source ~= 0.
--
-- `source` is 0 for the server console and non-zero for a player or a scheduled
-- context. A harness whose commands a player can run is not a harness: `cis_test
-- restore` deletes everything the run created and `cis_test run all` starts
-- thirty minutes of work, and neither should be a thing a client can do to a
-- server it is not a consumer of. This is belt and braces for the same reason
-- cis_debug does it twice: RegisterCommand's `restricted` flag is one gate and
-- the check inside is the other, and the second catches a mistake in the first.
--
-- ACES DO NOT SURVIVE A RESTART, so a session needs these typed once (2.6).
-- Where a command is refused anyway, the runbook says so and the harness falls
-- back to printing `[cis_test] ACTION: <command>` for a human to type.

-- The value RegisterCommand PASSES, not the global .
--
-- The global is nil in a server-command context, so reading it refuses EVERY
-- console call -- which is exactly what happened: cis_debug in cis_libs uses the
-- handler parameter, and this used the global, so every command answered
-- "refused: console-only" from the console itself. The parameter is the
-- documented, authoritative value and it is what the restricted flag and this
-- check must both be reasoning about.
local function refuseIfPlayer(src)
    if src ~= 0 then
        print(('[cis_test] refused: that command is console-only (source=%s)'):format(tostring(src)))
        return true
    end
    return false
end

-- Run ids are sortable and readable: run-20261003-014233.
local function makeRunId()
    return ('run-%s-%s'):format(os.date('!%Y%m%d'), os.date('!%H%M%S'))
end

-- The 'selftest' tier is EXCLUDED from 'all' on purpose. Its cases are
-- written to fail, because a harness that has only ever been seen to pass has
-- not been tested. Leaving it in would mean `cis_test run all` could never be
-- green, and a permanently red command is one everybody stops reading. Run it
-- on its own with `cis_test run selftest`, where a FAIL is the correct answer.
local SELFTEST_TIER = 'selftest'

local function selectedSuites(spec)
    local suites = CisTestRunner.Suites()
    if not spec or spec == 'all' then
        local out = {}
        for _, s in ipairs(suites) do
            if s.tier ~= SELFTEST_TIER then out[#out + 1] = s end
        end
        return out
    end

    local wanted = {}
    for part in tostring(spec):gmatch('[^,]+') do
        wanted[(part:gsub('^%s*(.-)%s*$', '%1'))] = true
    end

    local out, missing = {}, {}
    -- A TIER IS NOT CONSUMED BY ITS FIRST MATCH, and that distinction is the
    -- whole function.
    --
    -- It used to do `wanted[s.name] = nil; wanted[s.tier] = nil` for whichever
    -- matched, so naming a tier collected the FIRST suite in it and then threw
    -- the token away. `cis_test run server` ran the single `boundary` case out
    -- of ten, reported pass 1 fail 0, and exited 0 -- a green run of almost
    -- nothing, which is the one outcome worse than a red one.
    --
    -- A SUITE NAME is consumed, because that is how a typo gets reported. A tier
    -- is remembered as HIT rather than consumed, and only a name nothing ever
    -- matched is missing.
    local hit = {}
    for _, s in ipairs(suites) do
        local byName = wanted[s.name] and true or false
        local byTier = wanted[s.tier] and true or false
        if byName or byTier then
            out[#out + 1] = s
        end
        if byName then
            wanted[s.name] = nil
        end
        if byTier then
            hit[s.tier] = true
        end
    end
    for name in pairs(wanted) do
        if not hit[name] then
            missing[#missing + 1] = name
        end
    end
    if #missing > 0 then
        table.sort(missing)
        print(('[cis_test] no suite or tier matches: %s'):format(table.concat(missing, ', ')))
        print(('[cis_test] known tiers: %s'):format(table.concat(CisTestRunner.DistinctTiers(), ', ')))
    end
    if #out == 0 and (spec ~= 'all') then
        -- Said out loud, because "nothing ran" and "everything passed" print the
        -- same summary otherwise, and only one of them is a result.
        print(('[cis_test] %q selected 0 suites; nothing will run'):format(tostring(spec)))
    end
    return out
end

-- --------------------------------------------------------------- preflight
--
-- The plan's preflight: refuse to run if any slot is held by anything other
-- than cis_test_providers. A run against a half-faked environment produces
-- failures that look like library defects and are not, and the operator has no
-- way to tell them apart from the ones that are real.
local function preflight()
    local ok, caps = pcall(function() return exports['cis_libs']:GetCapabilities() end)
    if not ok or type(caps) ~= 'table' then
        return false, ('GetCapabilities refused: %s'):format(tostring(caps))
    end
    -- Empty is NOT a failure. doorsClient is registered by the CLIENT fakes in
    -- the client's own Lua state, so the server's capability table lists it with
    -- no owner forever, and a rule that required every declared slot to be
    -- filled refused a perfectly correct install. The plan's rule is precisely
    -- 'no slot held by anything other than the fakes' -- a FOREIGN owner, which
    -- means a real product would answer instead of a fake and every result
    -- would be about the environment.
    local foreign, empty = {}, {}
    for slot, entry in pairs(caps) do
        local owner = entry.owner
        if not owner then
            empty[#empty + 1] = slot
        elseif owner ~= 'cis_test_providers' then
            foreign[#foreign + 1] = ('%s held by %s'):format(slot, tostring(owner))
        end
    end
    if #foreign > 0 then
        table.sort(foreign)
        return false, 'slots held by something other than the fakes: ' .. table.concat(foreign, ', ')
    end
    if #empty > 0 then
        table.sort(empty)
        -- Reported, not refused. Most of these are client-side slots the server
        -- VM will never hold; the ones that matter are the client fakes'.
        print(('[cis_test] note: no server-side provider for %s (client-only slot, or its fake not running)')
            :format(table.concat(empty, ', ')))
    end
    return true
end

-- ------------------------------------------------------------------- status

local function status()
    -- status.json is the machine-readable half of this command, and since W3 the
    -- agent reads that file rather than the console. Forced, so the timestamp
    -- and the snapshot always reflect the moment the command was typed.
    local wrote = CisTestStatus.Refresh(true)
    print(('[cis_test] status.json %s'):format(wrote and 'written' or 'NOT written'))

    -- There is no GetVersion export, so the version is read the only way it can
    -- be: from the resource's own fxmanifest. Guessing at a print here would put
    -- a '?' in the one line an operator reads to decide which build is running.
    local version = 'unknown'
    pcall(function()
        local mf = LoadResourceFile('cis_libs', 'fxmanifest.lua')
        version = (mf and mf:match('version%s+"([^"]+)"')) or 'unknown'
    end)
    print(('[cis_test] cis_libs %s, deployed commit %s'):format(version, CisTestRunner.Commit()))
    print(('[cis_test] players connected: %d'):format(CisTestRunner.PlayerCount()))

    local ok, caps = pcall(function() return exports['cis_libs']:GetCapabilities() end)
    if ok and type(caps) == 'table' then
        local slots = {}
        for slot, entry in pairs(caps) do
            slots[#slots + 1] = ('%s=%s'):format(slot, tostring(entry.owner or '-'))
        end
        table.sort(slots)
        print('[cis_test] slot owners: ' .. table.concat(slots, ' '))
    else
        print('[cis_test] slot owners: unavailable (' .. tostring(caps) .. ')')
    end

    local checkOk, check = pcall(function() return exports['cis_libs']:GetSelfCheck() end)
    if checkOk and type(check) == 'table' then
        print(('[cis_test] self-check: %s (%d problem(s))')
            :format(tostring(check.ok), #(check.problems or {})))
        for _, p in ipairs(check.problems or {}) do
            print(('[cis_test]   %s: %s -- fix: %s'):format(p.code, p.message, p.fix))
        end
    end

    local suites = CisTestRunner.Suites()
    print(('[cis_test] %d suite(s) registered, tiers: %s')
        :format(#suites, table.concat(CisTestRunner.DistinctTiers(), ', ')))
end

-- ----------------------------------------------------------------------- run

local running = false

local function run(spec)
    if running then
        print('[cis_test] a run is already in progress; cis_test abort first')
        return
    end

    local ready, why = preflight()
    if not ready then
        print('[cis_test] PREFLIGHT REFUSED: ' .. tostring(why))
        return
    end

    local suites = selectedSuites(spec)
    if #suites == 0 then
        print('[cis_test] nothing to run')
        return
    end

    running = true
    local runId = makeRunId()
    CisTestRunner.BeginRun(runId)

    CreateThread(function()
        for _, suite in ipairs(suites) do
            if CisTestRunner.Aborted() then break end
            local ok, err = xpcall(function() CisTestRunner.runSuite(suite) end, function(m)
                return debug.traceback(tostring(m), 2)
            end)
            if not ok then
                CisTestJson.Line({
                    ev = 'suite_crashed', run = runId, suite = suite.name,
                    msg = tostring(err), trace = tostring(err),
                })
            end
            -- A yield between suites so an abort takes effect between them even
            -- when the suite itself is a tight loop of synchronous cases.
            Wait(0)
        end

        local tally = CisTestRunner.EndRun()
        CisTestReport.Write(runId, tally)
        running = false
    end)
end

-- --------------------------------------------------------------------- list

local function list(tier)
    local suites = CisTestRunner.Suites()
    print(('[cis_test] %d suite(s):'):format(#suites))
    for _, s in ipairs(suites) do
        if not tier or s.tier == tier then
            print(('[cis_test]   %-24s tier=%-9s realm=%-6s player=%s')
                :format(s.name, s.tier, s.realm, tostring(s.needsPlayer)))
        end
    end
end

-- ------------------------------------------------------- abort and restore

local function abort()
    if not running then
        print('[cis_test] nothing is running')
        return
    end
    CisTestRunner.Abort()
    print('[cis_test] aborting after the current suite; cleanups still run')
end

-- Deletes everything the harness created. The emergency reset, and the thing
-- that has to work when a run has left something behind.
local function restore()
    CisTestRunner.Abort()
    print('[cis_test] restore: releasing every claimed slot')
    -- Suites clean up after themselves on the way out; this is the backstop for
    -- a run that died before it got there. The PLAYER is deliberately not
    -- touched: restore never moves, freezes or respawns anyone.
    local released = 0
    pcall(function()
        local caps = exports['cis_libs']:GetCapabilities()
        for slot, entry in pairs(caps or {}) do
            if entry.owner == 'cis_test_providers' then
                local ok = pcall(function()
                    exports['cis_test_providers']:ReleaseSlot(slot)
                end)
                if ok then released = released + 1 end
            end
        end
    end)
    print(('[cis_test] restore: released %d slot(s); player snapshot untouched')
        :format(released))
end

-- ------------------------------------------------------- registration

RegisterCommand('cis_test', function(src, _args, argString)
    if refuseIfPlayer(src) then return end

    -- RegisterCommand's third argument is the RAW string INCLUDING the command
    -- name, so `cis_test status` arrives whole. Splitting it as though the name
    -- were already gone is why the first live run answered
    -- `unknown command "cis_test"` to a command it had just accepted.
    local rest = (argString and argString:match('^%s*%S+%s*(.*)')) or ''
    local cmd = rest:match('^%s*(%S+)') or 'status'
    local tail = rest:match('^%s*%S+%s*(.*)') or ''

    if cmd == 'status' then
        status()
    elseif cmd == 'list' then
        list(tail ~= '' and tail or nil)
    elseif cmd == 'run' then
        run(tail ~= '' and tail or 'all')
    elseif cmd == 'phase' then
        -- The split cis_libs restart. Restarting cis_libs takes cis_test down with
        -- it, so this cannot happen inside a case: the before phase records what
        -- is about to change, the operator restarts, and the after phase runs in
        -- a FRESH cis_test that has no memory of the first.
        print(('resources: cis_libs=%s cis_test_providers=%s cis_test_b=%s cis_test_c=%s')
            :format(GetResourceState('cis_libs'), GetResourceState('cis_test_providers'),
                    GetResourceState('cis_test_b'), GetResourceState('cis_test_c')))
        if tail == 'libs_restart_before' then
            local states = CisTestControl.ResourceStates()
            local ok = CisTestControl.WritePhase('libs_restart_before', states)
            print(('[cis_test] recorded the before state (%s)')
                :format(ok and 'written to phase.json' or 'NOT written'))
            print('[cis_test] ACTION: restart cis_libs   then: ensure cis_test_providers, '
                .. 'ensure cis_test_b, ensure cis_test_c, ensure cis_test')
        elseif tail == 'libs_restart_after' then
            local states = CisTestControl.ResourceStates()
            local bad = {}
            for name, st in pairs(states) do
                if name ~= 'cis_libs' and st ~= 'started' then bad[#bad + 1] = name .. '=' .. st end
            end
            table.sort(bad)
            print(('[cis_test] after: %s'):format(#bad == 0 and 'every harness resource is started'
                or table.concat(bad, ', ')))
            local check = exports['cis_libs']:GetSelfCheck()
            print(('[cis_test] self-check after the restart: ok=%s (%d problem(s))')
                :format(tostring(check.ok), #(check.problems or {})))
        else
            print('[cis_test] phase name required: libs_restart_before | libs_restart_after')
        end
    elseif cmd == 'abort' then
        abort()
    elseif cmd == 'restore' then
        restore()
    else
        print(('[cis_test] unknown command %q. Known: status, list [tier], run <tier|suite|all>, abort, restore')
            :format(tostring(cmd)))
    end
end, false)
