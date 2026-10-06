-- The cis_ctl allow-list, off-server.
--
-- WHAT THIS PROTECTS. cis_ctl is the only way the agent runs a server command.
-- Its value is not that it is convenient -- the web console already existed --
-- but that its entire command surface is eleven shapes wide and enumerable. If
-- that surface is wrong, the agent can type anything, and the list below is the
-- only thing standing between a test harness and `sv_licenseKey` printing the
-- server's licence key into a transcript.
--
-- So the cases here are not "the common commands work". They are the refusals,
-- because the refusals are the security property and the accepts are the easy
-- half. A canary at the end proves the checker is not simply refusing
-- everything: a checker that always said no would pass every refusal case here
-- and leave the agent unable to run a single test.
--
-- No FiveM server, no io, no exports. allow.lua is pure string logic precisely
-- so this can run under both fengari and a real Lua 5.4.

local passed, failed = 0, 0
local failures = {}

TEST_CASES = {}
local function check(cond, msg)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        failures[#failures + 1] = msg
    end
    TEST_CASES[#TEST_CASES + 1] = { name = msg, status = cond and 'passed' or 'failed' }
end

-- The allow-list arrives as a preloaded global: suite-runner.js and the Lua 5.4
-- driver both exec the file before this suite, the same way they exec the
-- library's own modules. Nothing is read off disk here, so the suite tests the
-- same code the server loads rather than a copy.
local Allow = CisCtlAllow

check(type(Allow) == 'table' and type(Allow.Check) == 'function',
    'the allow-list loaded and exposes Check')

if type(Allow) == 'table' and type(Allow.Check) == 'function' then

    ---------------------------------------------------------------- accepted

    local function accepts(cmd, action, resource, args, why)
        local ok, gotAction, gotResource, gotArgs = Allow.Check(cmd)
        check(ok and gotAction == action and gotResource == resource and gotArgs == args,
            ('ACCEPTS %q as %s%s -- %s'):format(
                cmd, tostring(gotAction),
                gotResource and (' ' .. tostring(gotResource)) or '',
                why or 'expected ' .. tostring(action) .. '/' .. tostring(resource)
                    .. '/' .. tostring(args)))
    end

    local function refuses(cmd, why)
        local ok, _, _, _, reason = Allow.Check(cmd)
        check(not ok and type(reason) == 'string' and reason ~= '',
            ('REFUSES %q -- %s'):format(cmd, why or ('reason was ' .. tostring(reason))))
    end

    accepts('refresh', 'refresh', nil, nil, 'a bare word, whole')

    for _, verb in ipairs({ 'ensure', 'start', 'stop', 'restart' }) do
        for _, res in ipairs({ 'cis_libs', 'cis_test', 'cis_test_b', 'cis_test_c',
            'cis_test_providers', 'cis_test_badmeta' }) do
            accepts(verb .. ' ' .. res, verb, res, nil, 'every allow-listed verb x resource')
        end
    end

    accepts('restart cis_ctl', 'restart', 'cis_ctl', nil,
        'the self-restart is its own branch, not a lifecycle command')
    accepts('cis_test run all', 'cis_test', 'cis_test', 'run all', 'the run command')
    accepts('cis_test status', 'cis_test', 'cis_test', 'status', 'the status command')
    accepts('cis_test run player', 'cis_test', 'cis_test', 'run player', 'a named tier')
    accepts('cis_test run selftest', 'cis_test', 'cis_test', 'run selftest', 'the self-test tier')
    accepts('cis_test abort', 'cis_test', 'cis_test', 'abort', 'abort')
    accepts('cis_test soak 30', 'cis_test', 'cis_test', 'soak 30', 'the 8.5 soak')
    accepts('cis_test soak 60', 'cis_test', 'cis_test', 'soak 60', 'a 60 minute soak')
    accepts('cis_test restore', 'cis_test', 'cis_test', 'restore', 'restore')
    accepts('cis_test phase libs_restart_before', 'cis_test', 'cis_test',
        'phase libs_restart_before', 'the split-restart phase')
    accepts('cis_test run a-b_c.d:e', 'cis_test', 'cis_test', 'run a-b_c.d:e',
        'every character the doc permits: letters, digits, space and _ : - .')
    accepts('  ensure cis_libs  ', 'ensure', 'cis_libs', nil,
        'surrounding whitespace from a hand-typed inbox is trimmed')
    accepts('ensure  cis_test_b', 'ensure', 'cis_test_b', nil,
        'whitespace BETWEEN the verb and the resource is separator, not argument')
    accepts('ensure\ncis_libs', 'ensure', 'cis_libs', nil,
        'a newline between verb and target is whitespace and separates them')

    -- `cis_test quit` is ACCEPTED, and the reason it is safe is worth stating
    -- precisely, because "anything after `cis_test` is letters" looks alarming
    -- until you know what the command reaches. ExecuteCommand('cis_test quit')
    -- dispatches to the cis_test COMMAND HANDLER, which parses `quit` as a
    -- subcommand, finds no such subcommand and prints its usage line. It cannot
    -- reach the server's own quit, which is a different command entirely -- the
    -- same reason `cis_test run all` cannot start a resource.
    -- The bare `quit` IS refused, and that is the case the doc names.
    accepts('cis_test quit', 'cis_test', 'cis_test', 'quit',
        'reaches cis_test\'s own parser as an unknown subcommand, never the server quit')

    ---------------------------------------------------------------- refused

    refuses('', 'empty is not a command')
    refuses('   ', 'whitespace is not a command')
    refuses('quit', 'the doc calls this out by name: quit is refused')
    refuses('sv_licenseKey', 'the whole point -- a licence key getter is not allow-listed')
    refuses('sv_licenseKey ""', 'nor with an argument')
    refuses('exec secrets.cfg', 'config execution is not allow-listed')
    refuses('add_ace resource.cis_ctl command.quit allow', 'the agent cannot widen its own ACL')
    refuses('add_principal identifier.fivem:1 group.admin', 'nor escalate a principal')
    refuses('stop mapmanager', 'a vanilla resource is not ours to stop')
    refuses('ensure fivem-map-hipster', 'nor to ensure')
    refuses('ensure cisprobe', 'the stale scratch probes are not on the list')
    refuses('restart txAdmin', 'txAdmin is the owner\'s, not the agent\'s')
    refuses('restart monitor', 'nor the monitor resource')
    refuses('stop', 'a verb with no target is not a command')
    refuses('ensure', 'nor is a target with no verb')
    refuses('cis_libs', 'a bare resource name is not a command')
    refuses('refresh now', 'refresh is matched whole, not by prefix')
    refuses('cis_test', 'cis_test needs arguments')
    refuses('cis_test ', 'and trailing whitespace is still no arguments')
    refuses('Cis_Test status', 'the match is case-sensitive: no second spelling')
    refuses('REFRESH', 'nor for refresh')
    refuses('Ensure cis_libs', 'nor a capitalised verb')
    refuses('stop    ', 'trailing whitespace does not turn a missing target into one')

    -- Argument smuggling. Each of these is a shape a well-meaning caller could
    -- produce by accident and an attacker could produce on purpose.
    refuses('cis_test run all; quit', 'a semicolon chains a second command')
    refuses('cis_test "run all"', 'a quote is outside the permitted set')
    refuses("cis_test 'run all'", 'either quote')
    refuses('cis_test run all && quit', 'a shell operator')
    refuses('cis_test run\nquit', 'a newline is whitespace, and %s is deliberately not permitted here')
    refuses('cis_test run\tall', 'nor a tab')
    refuses('cis_test run all | more', 'a pipe')
    refuses('cis_test run all\0', 'a NUL byte')
    -- A COMMA IS REFUSED, and that is a real limitation rather than an oversight.
    -- cis_test's own parser accepts `cis_test run server,lifecycle`, but
    -- cis_libs_vps_setup.md W2 names the permitted set explicitly -- letters,
    -- digits, spaces and _ : - . -- and a comma is not in it. The spec is
    -- followed rather than widened: an allow-list that grows a character because
    -- one command wanted it is how an allow-list stops being one.
    -- tools/live-run.js runs a single tier per invocation, so nothing the agent
    -- needs is blocked; the limitation is recorded in the handoff and runbook.
    refuses('cis_test run server,lifecycle', 'a comma is outside the documented set; run tiers separately')
    refuses('ensure cis_libs; quit', 'smuggling after a valid verb')
    refuses('ensure cis_libs quit', 'an extra token turns the target into something else')
    refuses('ensure cis_libs extra', 'three tokens is not a lifecycle command')
    refuses('stop cis_libs restart', 'the verb is read once, from the front')
    refuses('restart restart cis_ctl', 'no nesting')
    refuses('ensure CIs_libs', 'the resource match is case-sensitive')
    refuses('ensure cis_libs_', 'no prefix matching against the resource list')
    refuses('ensurecis_libs', 'no separator is not a separator')
    refuses('ensure ./cis_libs', 'a path is not a resource name')

    -- A newline AFTER a complete command is the case that would matter, because
    -- these patterns are anchored at both ends to stop exactly that. Lua's `%S`
    -- excludes whitespace, so a second token after a newline cannot be absorbed
    -- by the target capture: the whole match has to reach the true end of the
    -- subject. (A newline BETWEEN verb and target is just a separator -- `%s+`
    -- matches it -- and is accepted above, which is safe because FiveM passes
    -- the string to one command and does not split it.)
    refuses('ensure cis_libs\nquit', 'a newline after a valid lifecycle target')
    refuses('refresh\nquit', 'a newline after refresh')
    refuses('restart cis_ctl\nquit', 'a newline after the self-restart')
    refuses('restart cis_ctl; quit', 'a semicolon after the self-restart')

    -- Non-strings. tools/fx.js writes both fields; a malformed inbox must be
    -- refused, not coerced, because coercion is how a nil becomes "the string
    -- nil" and gets executed.
    check(not (Allow.Check(nil)), 'REFUSES a nil cmd')
    check(not (Allow.Check(42)), 'REFUSES a number cmd')
    check(not (Allow.Check({})), 'REFUSES a table cmd')
    check(not (Allow.Check(true)), 'REFUSES a boolean cmd')
    check(Allow.Check(nil) == false, 'REFUSES nil with a literal false, not merely falsy')
    local _, _, _, _, nilReason = Allow.Check(nil)
    check(type(nilReason) == 'string' and nilReason ~= '',
        'a nil cmd is refused WITH a reason, like every other refusal')

    ------------------------------------------------------- expected states

    -- The state a lifecycle command waits for is what tells fx.js whether the
    -- command happened. A wrong mapping here is a false PASS, not a false
    -- failure: `ensure` reported as stopped would be reported as a timeout and
    -- a genuine failure would read as success.
    check(Allow.ExpectedState('ensure') == 'started', 'ensure waits for started')
    check(Allow.ExpectedState('start') == 'started', 'start waits for started')
    check(Allow.ExpectedState('restart') == 'started', 'restart waits for started')
    check(Allow.ExpectedState('stop') == 'stopped', 'stop waits for stopped')
    check(Allow.ExpectedState('refresh') == nil, 'refresh has no state to wait for')
    check(Allow.ExpectedState('cis_test') == nil, 'nor does a cis_test command')

    ---------------------------------------------------------------- canary

    -- A checker that refuses everything passes every refusal above and is
    -- useless. This proves the accepts still work after all of that.
    local canaryOk, canaryAction = Allow.Check('ensure cis_libs')
    check(canaryOk and canaryAction == 'ensure',
        'CANARY: the allow-list still accepts a real command after refusing everything above')
    check(Allow.Check('cis_test run all') == true,
        'CANARY: and the run command the agent actually uses')

    -- The self-restart really is reachable, which is the property that stops
    -- cis_ctl restarting itself in a loop: it has to be allow-listed for the
    -- loop guard to matter.
    local selfOk, selfAction, selfRes = Allow.Check('restart cis_ctl')
    check(selfOk and selfAction == 'restart' and selfRes == 'cis_ctl',
        'CANARY: restart cis_ctl is allow-listed, which is what makes the startup seen-id rule necessary')
end

-- -------------------------------------------------------------------- reload
--
-- cis_ctl loads this chunk ONCE PER COMMAND and clears the global afterwards,
-- so the module has to survive being loaded, used, unloaded and loaded again.
-- The live server found out the hard way: the first case after a reload died
-- on `attempt to index a nil value (global 'CisCtlAllow')`, because every
-- function reached back through the global it had been attached to. The pcall
-- in the poll loop caught it, so the bridge stayed up and silently dropped the
-- command -- a bridge that looks alive and does nothing is the one failure this
-- whole resource exists to avoid.
--
-- The rest of this file loads the module exactly once and never clears the
-- global, so that dependency was always satisfied here and the suite could not
-- see it. Everything above runs against a module that has been through this
-- cycle first, which is the state the server actually uses it in.
do
    local src = CIS_CTL_ALLOW_SOURCE
    check(type(src) == 'string' and #src > 0,
        'the allow-list source is available to reload from')

    CisCtlAllow = nil
    check(CisCtlAllow == nil, 'the global is cleared, as cis_ctl does after each command')

    local chunk = (type(load) == 'function') and load(src, '@server/allow.lua', 't')
    check(type(chunk) == 'function', 'and the chunk compiles again from that source')

    if type(chunk) == 'function' then
        -- Everything here runs under pcall on purpose. A module that still
        -- reaches through the global it was attached to does not merely fail an
        -- assertion -- it raises on the FIRST line that touches it, taking the
        -- whole suite down and hiding every other result. A test that reports
        -- "this one thing is broken" is worth more here than a test that
        -- reports "the harness is broken".
        local ran, err = pcall(chunk)
        check(ran, ('the reloaded chunk runs without raising (%s)'):format(tostring(err)))

        -- cis_ctl's loadAllow, exactly: run the chunk, take the table the
        -- global now names, then CLEAR the global. The clear is the part that
        -- matters and the part a reload test usually skips -- with the global
        -- still set, every function reaches back through it and finds what it
        -- expects, so the bug stays invisible.
        local re = CisCtlAllow
        CisCtlAllow = nil
        check(type(re) == 'table' and type(re.Check) == 'function',
            'the table survives having the global taken away')

        if type(re) == 'table' and type(re.Check) == 'function' then
            -- The assertion that matters: a CHECK, not just a load. The stale
            -- reference only blows up when a function is actually CALLED, which
            -- is the whole reason a load-only reload test passes by accident.
            local callOk, accepted, action = pcall(re.Check, 'ensure cis_libs')
            check(callOk, ('a reloaded allow-list can still be CALLED (%s)'):format(tostring(accepted)))
            check(accepted == true and action == 'ensure',
                'a reloaded allow-list still ACCEPTS after the global is gone')

            local refuseOk, refused = pcall(re.Check, 'sv_licenseKey')
            check(refuseOk and refused == false,
                'and still refuses, which is the property the whole resource exists for')

            local cOk, cRes = pcall(re.Check, 'stop cis_test_c')
            check(cOk and cRes == true,
                'including the harness resource added after this suite was written')

            local sOk, want = pcall(re.ExpectedState, 'ensure')
            check(sOk and want == 'started',
                'and ExpectedState still answers with the global gone')
        end
    end
end

for i = 1, #failures do
    io.stderr:write('FAIL(ctl-allow): ' .. failures[i] .. '\n')
end
io.write(('ctl-allow passed=%d failed=%d\n'):format(passed, failed))
if failed > 0 then
    os.exit(1)
end