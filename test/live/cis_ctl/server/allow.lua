-- What cis_ctl is allowed to run, and why it is a list rather than a pattern.
--
-- cis_ctl exists so the agent never has to type into txAdmin's web console. That
-- only makes sense if the thing that replaced it is NARROWER than a console: a
-- file-watching bridge that accepts any string and hands it to ExecuteCommand is
-- the same power the console gives, with none of the things that make a console
-- accountable -- no visible history, no principal, and one typo away from `quit`.
--
-- So this is a complete allow-list, and the default answer is NO. A verb that is
-- not in ACTIONS is refused. A resource that is not in LIFECYCLE is refused. An
-- argument outside the character set is refused. Nothing is matched loosely,
-- nothing is matched by prefix, and there is no escape hatch, because an escape
-- hatch would be the whole vulnerability.
--
-- WHAT THIS BUYS, SPECIFICALLY. `sv_licenseKey` is a console command that PRINTS
-- the server's licence key. The agent works on a box whose files it can read and
-- whose model provider may log what it reads, so the one thing that must never
-- happen is a licence key crossing into a transcript. An agent that types into a
-- console can do that by accident. An agent that can only write these eleven
-- shapes into inbox.json cannot do it at all.
--
-- PURE LUA, NO FiveM. Everything here is a string decision, so it is unit
-- tested off-server by test/ctl-allow.lua under both fengari and a real Lua 5.4.
-- The parts that talk to the server live in ctl.lua and are not testable here;
-- the part that decides WHETHER to talk to the server is, and that is the part
-- where a bug would matter.

-- A LOCAL TABLE, with the global as a handle for the loader rather than as the
-- module itself.
--
-- It used to be `CisCtlAllow = {}` with every function reaching back through
-- that global. That works exactly as long as the global stays alive, and
-- nothing in the file said so. cis_ctl loads this chunk once per command and
-- clears the global afterwards, and the first command after that died on
-- `attempt to index a nil value (global 'CisCtlAllow')` -- an error caught by
-- the poll loop's pcall, so the bridge stayed up and silently dropped the
-- command instead of reporting anything.
--
-- The off-server suite missed it because it loads this file ONCE and never
-- clears the global, so the dependency it did not know about was always
-- satisfied. `test/ctl-allow.lua` now reloads, which is what catches it.
local allow = {}

-- The resources a lifecycle command may name. `cis_ctl` is deliberately absent:
-- it is the one resource in the list whose restart would stop the very thread
-- doing the work, so it gets its own branch below rather than sharing this one.
allow.LIFECYCLE = {
    ['cis_libs'] = true,
    ['cis_test'] = true,
    ['cis_test_b'] = true,
    ['cis_test_c'] = true,
    ['cis_test_providers'] = true,
    ['cis_test_badmeta'] = true,
}

-- Only these four verbs. `start` is not `ensure`: both are accepted because the
-- runbook's console sequence uses both, and neither implies a fifth.
local ACTIONS = {
    ensure = 'ensure',
    start = 'start',
    stop = 'stop',
    restart = 'restart',
}

-- What cis_test is allowed to be told, per cis_libs_vps_setup.md W2: letters,
-- digits, spaces, and _ : - .
--
-- Written with a literal space rather than %s so that a TAB or a NEWLINE is
-- refused. Neither has any business in a command line, and %s would admit both,
-- including the newline that makes a one-line command look like two.
local ARG_CHARS = '^[%w_ :%%-%%.]+$'

-- The state a lifecycle command is expected to reach. Report, not assert: the
-- caller decides what a timeout means.
local EXPECTED = {
    ensure = 'started',
    start = 'started',
    restart = 'started',
    stop = 'stopped',
}

function allow.Check(cmd)
    if type(cmd) ~= 'string' then
        return false, nil, nil, nil, ('cmd is a %s, not a string'):format(type(cmd))
    end

    -- Trim. An inbox written by a human on a terminal line carries trailing
    -- whitespace often enough that refusing it would be a nuisance rather than
    -- a protection: nothing after the trim can reach ExecuteCommand unparsed,
    -- because every pattern below is anchored at both ends.
    local text = cmd:gsub('^%s+', ''):gsub('%s+$', '')

    if text == '' then
        return false, nil, nil, nil, 'empty command'
    end

    if text == 'refresh' then
        -- A bare word, matched whole. `refresh now` is refused below by falling
        -- through to the final refusal, which is the point of an exact match.
        return true, 'refresh', nil, nil
    end

    -- Before the lifecycle branch, because cis_ctl is not in LIFECYCLE and would
    -- otherwise be refused as "not a harness resource".
    if text == 'restart cis_ctl' then
        return true, 'restart', 'cis_ctl', nil
    end

    local verb, arg = text:match('^(%S+)%s+(%S+)$')
    if verb and ACTIONS[verb] then
        if allow.LIFECYCLE[arg] then
            return true, ACTIONS[verb], arg, nil
        end
        return false, nil, nil, nil, ('refused: %s is not a harness resource'):format(arg)
    end

    local args = text:match('^cis_test%s+(.+)$')
    if args then
        args = args:gsub('%s+$', '')
        if args == '' then
            return false, nil, nil, nil, 'cis_test needs arguments'
        end
        if not args:match(ARG_CHARS) then
            return false, nil, nil, nil,
                'refused: cis_test arguments may contain only letters, digits, spaces and _ : - .'
        end
        return true, 'cis_test', 'cis_test', args
    end

    return false, nil, nil, nil, ('refused: %q is not an allow-listed command'):format(text)
end

-- The state a lifecycle command should end in, or nil when it has none.
function allow.ExpectedState(action)
    return EXPECTED[action]
end

-- The handle the loader reads. Set LAST, so a chunk that raises part-way
-- through leaves the previous good one in place rather than replacing it with
-- half a module.
CisCtlAllow = allow

return true