-- The runner. Suites, cases, assertions, cleanups, and the diagnostics diff.
--
-- THE RULE THAT MAKES THIS WORTH HAVING. Before and after every case the
-- runner snapshots GetDiagnostics on BOTH realms and compares them. A grown
-- error counter fails the case unless the case declared the growth it expected.
--
-- That single mechanism is what turns "the suite passed" into a statement about
-- leaks rather than about absence of exceptions -- and it is the only reason a
-- lifecycle promise in this library can be checked at all.
--
-- EVERY CASE RUNS UNDER xpcall WITH A TRACEBACK. A case that raises is a FAIL
-- with the stack attached, never a crashed run: a suite that dies on case 40 of
-- 60 has already lost the information in cases 1..39, and the operator reading
-- the console at 3am needs the 59 that passed as much as the one that failed.
--
-- CLEANUPS RUN LIFO ON EVERY EXIT PATH -- pass, fail, error, timeout and abort
-- alike. A cleanup that runs on the happy path only is a cleanup that leaks on
-- the interesting one, and the interesting path is the one being tested.

CisTestRunner = {}

local SUITES = {}
local state = {
    runId = nil,
    startedAt = nil,
    results = nil,
    aborted = false,
    activeCase = nil,
}

-- ---------------------------------------------------------------- registry

function CisTestRunner.Suite(name, opts, fn)
    if type(name) ~= 'string' or #name == 0 then
        error('Suite needs a name', 2)
    end
    opts = opts or {}
    if type(fn) ~= 'function' then
        error(('Suite %q needs a function'):format(name), 2)
    end
    for _, s in ipairs(SUITES) do
        if s.name == name then
            error(('duplicate suite name %q -- two suites answering to one name make a result untraceable'):format(name), 2)
        end
    end
    SUITES[#SUITES + 1] = {
        name = name,
        tier = opts.tier or 'server',
        realm = opts.realm or 'server',
        needsPlayer = opts.needsPlayer == true,
        timeoutMs = opts.timeoutMs or 10000,
        fn = fn,
    }
    return true
end

function CisTestRunner.Suites()
    return SUITES
end

function CisTestRunner.Find(name)
    for _, s in ipairs(SUITES) do
        if s.name == name then return s end
    end
    return nil
end

-- ------------------------------------------------------------- diagnostics

local function snapshot(realm)
    local ok, value = pcall(function()
        return exports['cis_libs']:GetDiagnostics()
    end)
    if not ok then
        -- Reported, not thrown. A harness that cannot read diagnostics must say
        -- so on every case rather than pretend the comparison passed.
        return { error = tostring(value) }
    end
    return value
end

-- The counters a case is allowed to move, and only when it says so. These are
-- the counters whose whole purpose is to be non-zero on the path a case is
-- deliberately exercising.
-- ------------------------------------------------------------- assertions

local Case = {}
Case.__index = Case

function Case:eq(a, b, msg)
    local ok = (a == b)
    self:record(ok, msg or 'values differ', ok and nil or ({
        ('expected %s, got %s'):format(CisTestRunner.show(b), CisTestRunner.show(a))
    }))
    return ok
end

function Case:ok(v, msg)
    local good = v and true or false
    self:record(good, msg or 'expected a truthy value',
        good and nil or 'value was ' .. CisTestRunner.show(v))
    return good
end

function Case:near(a, b, eps, msg)
    eps = eps or 1e-6
    local good = type(a) == 'number' and math.abs(a - b) <= eps
    self:record(good, msg or 'numbers differ',
        good and nil or ('expected %s +/- %s, got %s'):format(CisTestRunner.show(b), tostring(eps), CisTestRunner.show(a)))
    return good
end

function Case:raises(fn, pattern)
    local ok, err = pcall(fn)
    local matched = not ok
    if matched and pattern then
        matched = tostring(err):find(pattern, 1, true) ~= nil
    end
    self:record(matched, 'expected the call to raise' .. (pattern and (' matching ' .. pattern) or ''),
        matched and nil or ('it returned %s'):format(CisTestRunner.show(ok and err or nil)))
    return matched
end

-- SKIP IS NOT PASS. A tier that needs a player reports SKIP with a reason, and
-- a SKIP never counts toward done -- because a run full of skips that reports
-- green is a run that proved nothing.
function Case:skip(reason)
    self.status = 'SKIP'
    self.skipReason = tostring(reason or 'no reason given')
    return false
end

-- What only a human can judge: debug drawing, how a notification looks. Recorded
-- with exact steps, counted separately, and never counted as coverage.
function Case:manual(steps)
    self.status = 'MANUAL'
    self.manualSteps = steps
    return true
end

function Case:cleanup(fn)
    self.cleanups[#self.cleanups + 1] = fn
    return self
end

function Case:expectCounter(name, delta)
    self.expectedCounters[name] = delta
    return self
end

-- A case that wants a growing counter to be its SUBJECT rather than a failure.
-- Declared per counter per case, and the diff honours it, so "this case is
-- allowed to raise exactly one error" is an assertion rather than a comment.
function Case:allowCounter(name, delta)
    self.expectedCounters[name] = delta
    return self
end

-- ANY INCREASE IS EXPECTED HERE, and the number is not what is under test.
--
-- Some cases exist to make cis_libs REFUSE things: stop its providers, register
-- a resource whose contract it does not speak. Those refusals log warnings, so
-- the warning counter rises by however many slots happen to be affected --
-- eleven, then twenty-one -- and the count tracks the registry rather than
-- anything the case asserts. `allowCounter` demands an exact delta, so those
-- cases could only ever declare a number that is incidental, and would break
-- the day a slot is added.
--
-- This is the opt-out, and it is opt-IN per counter per case. Exact deltas stay
-- the default everywhere else, because "this case is allowed to raise exactly
-- one error" is an assertion and "warnings may move here" is not.
local ANY_COUNTER = {}

function Case:allowCounterAny(name)
    self.expectedCounters[name] = ANY_COUNTER
    return self
end

function Case:record(passed, msg, detail)
    self.checks = self.checks + 1
    if passed then
        self.passed = self.passed + 1
    else
        if self.status == 'PASS' then self.status = 'FAIL' end
        self.failures[#self.failures + 1] = {
            msg = msg,
            detail = detail,
        }
    end
    return passed
end

-- Short, safe rendering of any value in a failure message. tostring on a table
-- gives an address, which is the same every time and tells nobody anything.
function CisTestRunner.show(v)
    local t = type(v)
    if t == 'string' then
        if #v > 120 then return ('%s...'):format(v:sub(1, 117)) end
        return ('%q'):format(v)
    end
    if t == 'table' then
        local n = 0
        for _ in pairs(v) do n = n + 1 end
        return ('<table %d field(s)>'):format(n)
    end
    return tostring(v)
end

-- ------------------------------------------------------------------ cleanup

local function runCleanups(case)
    -- LIFO, and every one of them pcall'd. A cleanup that raises must not stop
    -- the cleanup under it, or one broken teardown strands everything the
    -- case had already set up.
    for i = #case.cleanups, 1, -1 do
        local ok, err = pcall(case.cleanups[i])
        if not ok then
            case.cleanupErrors[#case.cleanupErrors + 1] = tostring(err)
        end
    end
end

-- --------------------------------------------------------------- execution

-- What the diff means, in words an operator can act on.
local function diffCounters(before, after, expected)
    local moved = {}
    local bc = (before and before.counters) or {}
    local ac = (after and after.counters) or {}
    for _, key in ipairs({
        'errors', 'warnings', 'rateLimited', 'netRefused',
        'callbackErrors', 'providerErrors', 'zoneErrors', 'tickErrors',
    }) do
        local was, now = bc[key] or 0, ac[key] or 0
        if now ~= was then
            local allowed = expected[key]
            local declared = allowed ~= nil
            local explained = declared and (allowed == ANY_COUNTER or (now - was) == allowed)
            if not explained then
                local suffix
                if not declared then
                    suffix = ' (no case declared this)'
                elseif allowed == ANY_COUNTER then
                    suffix = ' (this case declares any movement expected)'
                else
                    suffix = (' (this case allows %d)'):format(allowed)
                end
                moved[#moved + 1] = ('%s went %d -> %d%s'):format(key, was, now, suffix)
            end
        end
    end
    return moved
end

local function runCase(suite, caseName, fn)
    local case = setmetatable({
        name = caseName,
        checks = 0,
        passed = 0,
        status = 'PASS',
        failures = {},
        cleanupErrors = {},
        cleanups = {},
        expectedCounters = {},
    }, Case)

    -- Published so the assertions record against THIS object. An earlier
    -- version built a second, identical-looking case in the suite body and
    -- recorded assertions on that one while reporting from this one, so
    -- `checks` came back 0 and a FAILING CASE REPORTED AS PASS. Every case in
    -- the first live run showed "checks":0, which is what exposed it: a harness
    -- that cannot fail is worse than no harness, because its green is believed.
    state.activeCase = case

    local startedAt = GetGameTimer()
    local serverBefore = snapshot('server')

    local ok, err = xpcall(function()
        fn(case)
    end, function(m)
        return debug.traceback(tostring(m), 2)
    end)

    if not ok then
        case.status = 'ERROR'
        case.trace = tostring(err)
    end

    runCleanups(case)

    local ms = GetGameTimer() - startedAt
    local serverAfter = snapshot('server')

    -- The leak gate. A case that threw still gets compared, because a case that
    -- threw after leaking is the more interesting failure.
    local moved = diffCounters(serverBefore, serverAfter, case.expectedCounters)
    if #moved > 0 and case.status == 'PASS' then
        case.status = 'FAIL'
        case.failures[#case.failures + 1] = {
            msg = 'a counter moved and the case did not say it would',
            detail = table.concat(moved, '; '),
        }
    end

    local entry = {
        ev = 'case',
        run = state.runId,
        tier = suite.tier,
        suite = suite.name,
        case = case.name,
        status = case.status,
        ms = ms,
        checks = case.checks,
        msg = case.failures[1] and case.failures[1].msg or nil,
        -- The detail belongs in the FILE, not only on the console. A results
        -- file that records WHAT failed but not WHY sends whoever reads it back
        -- to the console to find out, which is the thing the file exists to avoid.
        detail = case.failures[1] and case.failures[1].detail or nil,
        trace = case.trace,
        skipReason = case.skipReason,
        manual = case.manualSteps and (type(case.manualSteps) == 'table'
            and table.concat(case.manualSteps, ' / ') or tostring(case.manualSteps)),
    }
    -- Every failure is printed, not just the first. A case that fails five
    -- assertions should not need five runs to be diagnosed.
    for i, f in ipairs(case.failures) do
        if i > 1 then
            CisTestJson.Line({
                ev = 'case_detail', run = state.runId,
                suite = suite.name, case = case.name,
                msg = f.msg, detail = f.detail,
            })
        end
    end
    for _, ce in ipairs(case.cleanupErrors) do
        CisTestJson.Line({
            ev = 'cleanup_error', run = state.runId,
            suite = suite.name, case = case.name, msg = ce,
        })
    end

    state.activeCase = nil

    state.results[#state.results + 1] = entry
    CisTestJson.Line(entry)
    return entry
end

-- Runs one suite. Returns the suite's tallies.
--
-- `t` is ONE table carrying the whole suite API, and the assertions forward to
-- whichever case is currently running. They are not bound per case, because a
-- case body receives `t` and calls `t.eq(...)`: binding them to a case object
-- would mean every suite writes `t.eq` differently and the API stops being one
-- API.
local function runSuite(suite)
    CisTestJson.Line({
        ev = 'suite_start', run = state.runId, tier = suite.tier,
        suite = suite.name, realm = suite.realm,
    })

    local counts = { pass = 0, fail = 0, skip = 0, manual = 0, error = 0 }

    -- Reads the case the RUNNER is running, not one this scope invented. One
    -- object, created once, recorded into and reported from.
    local function needCase(what)
        local active = state.activeCase
        if not active then
            error(('%s is only meaningful inside t.case(...)'):format(what), 3)
        end
        return active
    end

    local t = {}

    t.case = function(name, fn)
        if type(name) ~= 'string' then error('a case needs a name', 3) end
        if type(fn) ~= 'function' then
            error(('case %q needs a function'):format(name), 3)
        end
        if state.aborted then
            return { status = 'SKIP', skipReason = 'the run was aborted' }
        end

        local entry = runCase(suite, name, fn, t)

        local key = entry.status:lower()
        counts[key] = (counts[key] or 0) + 1
        return entry
    end

    t.eq = function(a, b, msg) return Case.eq(needCase('t.eq'), a, b, msg) end
    t.ok = function(v, msg) return Case.ok(needCase('t.ok'), v, msg) end
    t.near = function(a, b, eps, msg) return Case.near(needCase('t.near'), a, b, eps, msg) end
    t.raises = function(fn, pattern) return Case.raises(needCase('t.raises'), fn, pattern) end
    t.skip = function(reason) return Case.skip(needCase('t.skip'), reason) end
    t.manual = function(steps) return Case.manual(needCase('t.manual'), steps) end
    t.cleanup = function(fn) return Case.cleanup(needCase('t.cleanup'), fn) end
    -- Report a FAILURE that is an observation rather than a comparison.
    -- A case that relays a verdict from somewhere else -- a client suite, a
    -- restore check -- has no two values to assert about, and reaching for
    -- `t.eq(false, false)` would record a PASS. This is how the player tier
    -- reports a client suite that answered FAIL, and it was missing: the first
    -- live player run crashed on exactly this, which is the correct outcome for
    -- a harness bug and a waste of a run.
    t.fail = function(msg, detail) return Case.record(needCase('t.fail'), false, msg, detail) end
    t.allowCounter = function(name, delta)
        return Case.allowCounter(needCase('t.allowCounter'), name, delta)
    end
    t.allowCounterAny = function(name)
        return Case.allowCounterAny(needCase('t.allowCounterAny'), name)
    end
    t.waitUntil = function(fn, timeoutMs, msg)
        return CisTestRunner.waitUntil(fn, timeoutMs, msg)
    end

    -- A tier that needs a player says so rather than failing every case.
    if suite.needsPlayer and CisTestRunner.PlayerCount() == 0 then
        local entry = {
            ev = 'case', run = state.runId, tier = suite.tier, suite = suite.name,
            case = '<whole suite>', status = 'SKIP', ms = 0, skipReason = 'no player connected',
        }
        state.results[#state.results + 1] = entry
        CisTestJson.Line(entry)
        counts.skip = counts.skip + 1
        CisTestJson.Line({
            ev = 'suite_end', run = state.runId, tier = suite.tier, suite = suite.name,
            pass = 0, fail = 0, skip = 1, manual = 0, error = 0,
        })
        return counts
    end

    local ok, err = xpcall(function() suite.fn(t) end, function(m)
        return debug.traceback(tostring(m), 2)
    end)
    if not ok then
        -- The suite body raised OUTSIDE a case. Recorded as an error rather than
        -- dropped, because a suite that never runs its cases has silently
        -- converted its coverage into nothing.
        local entry = {
            ev = 'case', run = state.runId, tier = suite.tier, suite = suite.name,
            case = '<suite body>', status = 'ERROR', ms = 0,
            msg = tostring(err), trace = tostring(err),
        }
        state.results[#state.results + 1] = entry
        CisTestJson.Line(entry)
        counts.error = counts.error + 1
    end

    CisTestJson.Line({
        ev = 'suite_end', run = state.runId, tier = suite.tier, suite = suite.name,
        pass = counts.pass, fail = counts.fail, skip = counts.skip,
        manual = counts.manual, error = counts.error,
    })
    return counts
end


-- ------------------------------------------------------------------- state

function CisTestRunner.State()
    return state
end

function CisTestRunner.BeginRun(runId)
    state.runId = runId
    state.startedAt = GetGameTimer()
    state.results = {}
    state.aborted = false
    CisTestJson.Line({
        ev = 'run_start', run = runId,
        commit = CisTestRunner.Commit(),
        tiers = CisTestRunner.DistinctTiers(),
    })
end

function CisTestRunner.EndRun()
    local r = { pass = 0, fail = 0, skip = 0, manual = 0, error = 0 }
    for _, entry in ipairs(state.results) do
        local key = entry.status:lower()
        r[key] = (r[key] or 0) + 1
    end
    r.ms = GetGameTimer() - (state.startedAt or GetGameTimer())
    CisTestJson.Line({
        ev = 'run_end', run = state.runId,
        pass = r.pass, fail = r.fail, skip = r.skip, manual = r.manual, error = r.error,
        ms = r.ms,
    })
    state.runId = nil
    return r
end

function CisTestRunner.Aborted()
    return state.aborted == true
end

function CisTestRunner.Abort()
    state.aborted = true
end

function CisTestRunner.Results()
    return state.results
end

-- ------------------------------------------------------------------ helpers

function CisTestRunner.PlayerCount()
    local ok, players = pcall(function() return GetPlayers() end)
    if not ok or type(players) ~= 'table' then return 0 end
    return #players
end

function CisTestRunner.Commit()
    local ok, text = pcall(function()
        return LoadResourceFile(GetCurrentResourceName(), 'deploy.json')
    end)
    if not ok or type(text) ~= 'string' then return 'unknown' end
    local sha = text:match('"commit"%s*:%s*"([^"]*)"')
    return sha or 'unknown'
end

function CisTestRunner.DistinctTiers()
    local seen, out = {}, {}
    for _, s in ipairs(SUITES) do
        if not seen[s.tier] then
            seen[s.tier] = true
            out[#out + 1] = s.tier
        end
    end
    table.sort(out)
    return out
end

-- Wait until `fn` is true, or give up. A harness that blocks forever is worse
-- than one that fails: the operator cannot tell it apart from a running suite.
function CisTestRunner.waitUntil(fn, timeoutMs, msg)
    local deadline = GetGameTimer() + (timeoutMs or 5000)
    while GetGameTimer() < deadline do
        if CisTestRunner.Aborted() then return false end
        local ok, value = pcall(fn)
        if ok and value then return true end
        Wait(50)
    end
    if msg then
        CisTestJson.Line({ ev = 'wait_timeout', run = state.runId, msg = msg })
    end
    return false
end

CisTestRunner.runSuite = runSuite
CisTestRunner.snapshot = snapshot