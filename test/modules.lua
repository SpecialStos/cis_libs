-- Tests for the utility and algorithm modules.
--
-- Written after the modules, against their REAL signatures -- which is the
-- point of running these rather than trusting a summary. A first draft of
-- this file called `smoothstep(0)`, `CisCurve.new`, `CisHeap:push` and
-- `CisSparse:add`; every one of those is wrong, and the file crashed on the
-- first call. The API is function-based and takes the container as its first
-- argument, not method-based.
--
-- These assert the CONTRACTS each module claims rather than re-deriving them.
-- Where a module documents a specific behaviour -- frame-rate independence, an
-- O(1) clear, a refusal that carries a reason -- that behaviour is pinned here,
-- because a documented promise nobody checks is a comment.
--
-- The fengari findings in these modules are real and apply to THIS file too:
--   * `table.sort` here rejects a comparator returning -1/0/1; it wants a
--     boolean. Real Lua accepts both.
--   * Lua patterns have no alternation, so `match('^(a|b)$', x)` matches the
--     LITERAL string "a|b" and passes silently.
--   * `pairs` does not walk the array part in ascending order here, so a
--     positional counter over a config array is not safe.

local passed, failed = 0, 0

-- Recorded as well as printed. The stock-Lua 5.4 driver runs every suite in
-- this process and has no pipe on its own stdout, so it cannot read the FAIL
-- lines; it reads TEST_CASES instead. Without this the driver counted a suite
-- that had failed and exited as PASSED, which is the one failure shape this
-- repository has already been bitten by once.
TEST_CASES = {}

local function expect(cond, msg)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        io.stderr:write('FAIL: ' .. msg .. '\n')
    end
    TEST_CASES[#TEST_CASES + 1] = { name = msg, status = cond and 'passed' or 'failed' }
end

local function near(a, b, tol, msg)
    expect(type(a) == 'number' and math.abs(a - b) <= (tol or 1e-6), msg)
end

-- ================================================================== CisInterp
-- The headline promise: smoothing is FRAME-RATE INDEPENDENT. Same wall-clock
-- time, different step sizes, same answer. A smoother that is not is the
-- classic source of "why is this faster on my machine".
do
    local I = CisInterp
    expect(I.clamp(5, 0, 10) == 5, 'clamp passes a value inside the range')
    expect(I.clamp(-1, 0, 10) == 0, 'clamp raises a value below the range')
    expect(I.clamp(11, 0, 10) == 10, 'clamp lowers a value above the range')
    near(I.lerp(0, 10, 0.5), 5, nil, 'lerp is linear')
    expect(I.lerp(0, 10, 0) == 0 and I.lerp(0, 10, 1) == 10, 'lerp honours its endpoints')
    expect(I.inverseLerp(0, 10, 5) == 0.5, 'inverseLerp inverts lerp')
    expect(I.smoothstep(0, 1, 0) == 0, 'smoothstep is 0 at the first edge')
    expect(I.smoothstep(0, 1, 1) == 1, 'smoothstep is 1 at the second edge')
    expect(I.smoothstep(0, 1, 0.5) > 0.4 and I.smoothstep(0, 1, 0.5) < 0.6,
        'smoothstep is eased in between, not linear')
    -- Reversed edges must not produce a NaN.
    expect(type(I.smoothstep(10, 0, 5)) == 'number', 'smoothstep survives reversed edges')

    -- wrap must handle NEGATIVE input. Lua's % is fmod and returns a negative
    -- remainder, so the naive one-liner wraps the wrong way below zero.
    near(I.wrap(-1, 0, 10), 9, nil, 'wrap handles a negative value')
    near(I.wrap(11, 0, 10), 1, nil, 'wrap handles an over-range value')
    near(I.wrap(5, 0, 10), 5, nil, 'wrap leaves an in-range value alone')

    -- Frame-rate independence means the SAME elapsed time arrives at the same
    -- place however it was chopped up. A single call is ONE step, so the
    -- comparison has to COMPOSE the smaller steps: running one 0.5s step and
    -- one 0.25s step and comparing them measures nothing, and they should not
    -- match.
    local one = I.damp(0, 100, 0.5, 0.5)
    local two = I.damp(I.damp(0, 100, 0.5, 0.25), 100, 0.5, 0.25)
    local four = I.damp(I.damp(I.damp(I.damp(0, 100, 0.5, 0.125), 100, 0.5, 0.125),
        100, 0.5, 0.125), 100, 0.5, 0.125)
    near(one, two, 1e-9, 'damp: one 0.5s step equals two composed 0.25s steps')
    near(two, four, 1e-9, 'damp: two 0.25s steps equal four composed 0.125s steps')
    expect(one > 0 and one < 100, 'damp actually moves toward the target')
    expect(I.damp(7, 100, 0.5, 0) == 7, 'damp with dt=0 returns the current value unchanged')
    expect(I.damp(7, 100, 0.5, -1) == 7, 'damp with a negative dt is also a no-op, not a backwards step')

    expect(I.hasEase('quadIn'), 'hasEase recognises a curve it ships')
    expect(not I.hasEase('nope'), 'hasEase rejects one it does not')
    expect(I.ease('linear', 0.5) == 0.5, 'the linear ease is the identity')
    expect(I.ease('quadIn', 0) == 0 and I.ease('quadIn', 1) == 1,
        'an ease is pinned at both ends')
end

-- ==================================================================== CisLRU
-- The contract is eviction ORDER: the least recently USED entry goes, and
-- reading an entry refreshes it.
do
    local L = CisLRU.new(3)
    CisLRU.put(L, 'a', 1) CisLRU.put(L, 'b', 2) CisLRU.put(L, 'c', 3)
    expect(CisLRU.get(L, 'a') == 1, 'a is retrievable')
    CisLRU.put(L, 'd', 4)                  -- evicts b, now the least recently used
    expect(CisLRU.get(L, 'b') == nil, 'the least recently USED entry is evicted')
    expect(CisLRU.get(L, 'a') == 1, 'an entry that was read survives eviction')
    expect(CisLRU.count(L) == 3, 'the cache never exceeds its capacity')
end

-- =================================================================== CisHeap
-- Ordering is the whole point; a heap that pops the wrong element is worse
-- than no heap.
do
    local h = CisHeap.new()
    for _, v in ipairs({ 5, 1, 9, 3, 7, 2 }) do CisHeap.push(h, v) end
    expect(CisHeap.size(h) == 6, 'the heap counts what was pushed')
    local popped = {}
    while not CisHeap.isEmpty(h) do popped[#popped + 1] = CisHeap.pop(h) end
    local sorted = true
    for i = 2, #popped do
        if popped[i - 1] > popped[i] then sorted = false end
    end
    expect(sorted, 'the heap pops in ascending order')
    expect(popped[1] == 1 and popped[#popped] == 9, 'the extremes come out first and last')
    expect(CisHeap.isEmpty(h), 'the heap reports empty once drained')
end

-- ================================================================== CisSparse
-- The claim is that clear is O(1) and that iteration costs the SIZE, not the
-- number of slots ever written. Both hold only if the dense array is
-- maintained, so this churns far more slots than survive.
do
    local s = CisSparse.new()
    for i = 1, 5000 do CisSparse.add(s, i) end
    expect(CisSparse.count(s) == 5000, 'the set counts its members')
    CisSparse.clear(s)
    expect(CisSparse.count(s) == 0, 'clear empties the set')
    CisSparse.add(s, 1) CisSparse.add(s, 2)
    expect(CisSparse.count(s) == 2, 'the set is reusable after a clear')
    expect(CisSparse.has(s, 1) and not CisSparse.has(s, 3), 'membership is correct after a clear')

    -- A SOFT clear is O(1) by not deleting anything, which means every
    -- value ever added stayed in the slots table forever. A set cleared
    -- repeatedly -- the streaming loops, a zone resync -- grew its hash without
    -- bound while count() stayed at 0, which is exactly what a leak looks like
    -- from the outside.
    do
        local churn = CisSparse.new()
        for i = 1, 1000 do
            CisSparse.add(churn, 'id' .. i)
            CisSparse.clear(churn)
        end
        expect(CisSparse.count(churn) == 0, 'the churned set is empty')
        local stale = CisSparse.staleCount(churn)
        expect(stale <= 128,
            '1000 soft add/clear cycles keep the stale slot count bounded, got ' .. tostring(stale))

        -- Sweeping must not change what the set MEANS: a value from an earlier
        -- cycle stays gone, a new one is accepted, and iteration agrees with
        -- membership. A sweep that dropped live slots, or kept stale ones, would
        -- still pass the count above.
        CisSparse.add(churn, 'live')
        expect(CisSparse.has(churn, 'live'), 'the set still accepts a value after sweeping')
        expect(not CisSparse.has(churn, 'id500'), 'a value from an earlier cycle is still gone')
        expect(CisSparse.count(churn) == 1, 'a sweep does not resurrect a stale value')
        local visited = 0
        CisSparse.each(churn, function() visited = visited + 1 end)
        expect(visited == 1, 'iteration sees exactly the live values after a sweep')

        -- A hard clear drops the tables outright, and removal has to keep the
        -- write counter honest or the sweep threshold drifts upward forever.
        local r = CisSparse.new()
        for i = 1, 200 do CisSparse.add(r, i) end
        for i = 1, 200 do CisSparse.remove(r, i) end
        expect(CisSparse.staleCount(r) == 0, 'removing every value leaves no slots behind')
        for i = 1, 100 do
            CisSparse.add(r, i)
            CisSparse.clear(r, true)
        end
        expect(CisSparse.staleCount(r) == 0, 'a hard clear leaves no slots behind either')
        expect(CisSparse.count(r) == 0, 'the set is still usable after 100 hard clears')
    end
end

-- ================================================================ CisReady
-- The whole contract of this gate is that it SETTLES ONCE. Three ways it did
-- not: a failure after a success left both flags true, a late waiter learned
-- it had failed but not why, and the immediate callback was not under pcall,
-- so a consumer's throw escaped onReady() with every other waiter still
-- queued behind it.
--
-- The module has had no tests at all until now, which is why "the whole module
-- is untested" in the audit was true rather than an exaggeration. It was also
-- unreachable until 185ad1c, when the runner started loading it.
do
    local R = CisReadyState

    -- A settled gate is one or the other, never both.
    R.reset()
    R.markReady()
    R.markFailed('too late')
    expect(R.ready and not R.failed, 'a failure after a success is refused; the gate stays ready')

    R.reset()
    R.markFailed('config never arrived')
    R.markReady()
    expect(R.failed and not R.ready, 'a success after a failure is refused; the gate stays failed')
    expect(R.reason == 'config never arrived', 'the failure reason survives a refused success')

    -- A waiter arriving after the failure is told WHY, not just that it failed.
    local readyNow, whyNow
    R.onReady(function(ready, why)
        readyNow, whyNow = ready, why
    end)
    expect(readyNow == false, 'a late waiter is told the gate failed')
    expect(whyNow == 'config never arrived', 'a late waiter is told the reason it failed')

    -- The immediate path runs a CONSUMER's function, so it is under pcall like the
-- queued one. A throw here used to escape onReady() itself.
--
-- Tested from a freshly-settled gate in EACH state on purpose. Reaching it from
-- the state left behind by the assertions above would have made this pass
-- against the broken build for the wrong reason -- it only said the call
-- returned, not that the throw was contained.
    R.reset()
    R.markReady()
    local survivedReady = pcall(function()
        R.onReady(function() error('consumer callback exploded') end)
    end)
    expect(survivedReady, 'a throwing immediate callback does not escape onReady when ready')

    R.reset()
    R.markFailed('nope')
    local survivedFailed = pcall(function()
        R.onReady(function() error('consumer callback exploded') end)
    end)
    expect(survivedFailed, 'a throwing immediate callback does not escape onReady when failed')

    -- And a throwing waiter must not strand the waiters behind it.
    R.reset()
    local reached = {}
    R.onReady(function() error('first waiter exploded') end)
    R.onReady(function() reached[#reached + 1] = 'second' end)
    R.markReady()
    expect(#reached == 1, 'a throwing waiter does not strand the waiters behind it')

    -- A queued waiter fires exactly once, and not before the gate settles.
    R.reset()
    local fired = 0
    R.onReady(function() fired = fired + 1 end)
    R.onReady(function() fired = fired + 1 end)
    expect(fired == 0, 'a queued waiter does not fire before the gate settles')
    R.markReady()
    expect(fired == 2, 'both queued waiters fire when the gate becomes ready')
    R.markReady()
    expect(fired == 2, 'a second markReady does not re-fire them')

    -- A waiter sees the flags it is being told about. Cis.isReady was written
    -- AFTER the waiters ran, so a waiter that read it was told false.
    local savedCis = rawget(_G, 'Cis')
    Cis = { isReady = false, isFailed = false }
    local sawReady, sawFailed
    R.reset()
    R.onReady(function() sawReady = Cis.isReady end)
    R.markReady()
    expect(sawReady == true, 'a ready waiter reads Cis.isReady as true')
    Cis = { isReady = false, isFailed = false }
    R.reset()
    R.onReady(function() sawFailed = Cis.isFailed end)
    R.markFailed('nope')
    expect(sawFailed == true, 'a failure waiter reads Cis.isFailed as true')
    Cis = savedCis
    R.reset()
    R.markReady()

    -- wait() short-circuits on a settled gate. Deliberately NOT testing the
    -- polling path: sleep() is a no-op outside FiveM, so a real wait would spin
    -- against os.clock until its deadline.
    expect(R.wait(0) == true, 'wait answers immediately once the gate is ready')
    R.reset()
    R.markFailed('nope')
    expect(R.wait(0) == false, 'wait answers immediately once the gate has failed')

    -- Hand the gate back the way it was found, because the suites that run
    -- after this one read it.
    R.reset()
end

-- ================================================================= CisTime
do
    local T = CisTime
    -- The doc said roundTo returns "the number of whole units"; the code
    -- returns a whole number of SECONDS. For roundTo(90, 60) those differ by a
    -- factor of sixty, and the doc is the one a caller reads. Asserting the
    -- real contract is the only way a wrong doc fails anything.
    expect(T.roundTo(90, 60) == 120, 'roundTo returns SECONDS, not a count of units')
    expect(T.roundTo(89, 60) == 60, 'roundTo rounds down below the halfway point')
    expect(T.roundTo(91, 60) == 120, 'roundTo rounds up above the halfway point')
    expect(T.roundTo(150, 60) == 180, 'a tie goes up, the conservative direction for a rate limit')
    -- An EXACT tie rounds up too, which is the documented rule rather than a
    -- defect: 30s is precisely half of a minute and goes to 60.
    expect(T.roundTo(30, 60) == 60, 'an exact tie rounds up, as documented')
    expect(T.roundTo(29, 60) == 0, 'roundTo strictly below half a unit rounds to zero')
    expect(T.roundTo(90, T.MINUTE) == 120, 'roundTo is the same with the named constant')
    expect(T.roundTo(90) == 120, 'roundTo defaults to minutes')
    expect(T.roundTo(3600) == 3600, 'roundTo leaves an exact multiple alone')
    expect(T.roundTo(0, 60) == 0, 'roundTo of zero is zero')
    expect(T.roundTo('x', 60) == 0, 'roundTo of a non-number is zero')
    expect(T.roundTo(90, 0) == 0, 'roundTo with a zero unit is zero rather than a division by zero')
    expect(T.roundTo(90, -60) == 0, 'roundTo with a negative unit is zero')
end

-- ================================================== the meaning of `count`
--
-- `count` means "how many entries does this container hold" everywhere else in
-- this library: CisSparse.count, CisLRU.count, CisPending.count,
-- CisOwned.count, CisCurve.count, CisHistogram.count. CisWindow.count was the
-- exception -- it counts SAMPLES for one key, which is a different question.
-- For a rate check it is the question that matters, so the function stays and
-- the NAME moves; the old name is kept as an alias rather than removed.
do
    local s = CisWindow.newStats(3, 1)
    for t = 10, 12 do
        CisWindow.record(s, 'k', t, t)
    end
    expect(CisWindow.samples(s, 'k', 12.5) == 3, 'samples() counts the live samples for a key')
    expect(CisWindow.count == CisWindow.samples,
        'count is kept as an alias of samples, not a second implementation')
    expect(CisWindow.count(s, 'k', 12.5) == 3, 'and the alias answers the same thing')

    -- THE DISTINCTION THE RENAME EXISTS FOR. Three samples of one key is one
    -- key and three samples. Only one of those is what `count` means in every
    -- other module, which is why the same word doing two jobs was worth fixing.
    local keys = 0
    for _ in pairs(s.entries) do keys = keys + 1 end
    expect(keys == 1, 'this stats table holds exactly one key')
    expect(CisWindow.samples(s, 'k', 12.5) == 3,
        'and samples() still reports 3, which is not what count() means elsewhere')

    -- The edges the alias has to keep.
    expect(CisWindow.samples(s, 'nope', 12.5) == 0, 'an unknown key has no samples')
    expect(CisWindow.samples(s, 'k', 0 / 0) == 0, 'a NaN now answers 0 rather than raising')
end

-- ================================================== Phase 4 · the error style
--
-- ONE RULE: a PROGRAMMER error (wrong type, nil where a value is required)
-- RAISES, because the caller has to change code to fix it and a silent default
-- lets it ship. A DATA error (NaN, an unparsable number, an inverted range)
-- RETURNS `nil, reason`, because it arrived from a config file and the only
-- honest answer is "nothing to give you, and here is why".
--
-- What this replaces is the quiet default: a 0 that reads like a result, or a
-- NaN that propagates into a coordinate and surfaces three subsystems later as
-- "spawns appear in the wrong place". Both are worse than an error, because
-- neither names the fix.
do
    -- ------------------------------------------------------------ Random
    -- `integer` answered 0 for a non-number bound AND for a non-finite one, so
    -- "you passed a string" and "you passed NaN" were indistinguishable from
    -- "the draw came up 0".
    do
        local function tryInteger(...)
            local a = { ... }
            return pcall(CisRandom.integer, a[1], a[2], a[3])
        end

        local okType = pcall(function() return CisRandom.integer('a', 5, nil) end)
        expect(not okType, 'integer() with a string bound RAISES rather than answering 0')
        local okType2 = pcall(function() return CisRandom.integer(0, {}, nil) end)
        expect(not okType2, 'integer() with a table bound raises too')

        local okNan, nanRes, nanWhy = tryInteger(0 / 0, 5, nil)
        expect(okNan and nanRes == nil and type(nanWhy) == 'string' and nanWhy ~= '',
            'integer() with a NaN bound returns nil and a reason, not 0')
        local okInf, infRes, infWhy = tryInteger(0, math.huge, nil)
        expect(okInf and infRes == nil and type(infWhy) == 'string',
            'integer() with an infinite bound returns nil and a reason, not 0')

        -- The raise must NAME the fix. A bare "bad argument #1" from the
        -- comparison operator is what the rule exists to replace.
        local message = select(2, pcall(function() return CisRandom.integer('a', 5, nil) end))
        expect(type(message) == 'string' and message:find('number', 1, true) ~= nil,
            ('integer() names what it wanted: %s'):format(tostring(message)))
        expect(tostring(message):find('string', 1, true) ~= nil,
            'and what it actually got, so the caller can find the call site')

        -- The good paths are untouched. A grid that refuses everything passes
        -- every assertion above.
        local g = CisRandom.newGenerator(9)
        expect(CisRandom.integer(5, 5, g) == 5, 'integer() still returns a single-value range')
        local drew = CisRandom.integer(1, 6, g)
        expect(type(drew) == 'number' and drew >= 1 and drew <= 6 and drew % 1 == 0,
            'integer() still draws an ordinary range')
    end

    -- `float` sits beside `integer` with the identical quiet default and has no
    -- callers anywhere in the repository, so leaving it would be indefensible:
    -- the same mistake, one function away, for no reason at all.
    do
        expect(not pcall(function() return CisRandom.float('a', 5, nil) end),
            'float() with a non-number bound raises rather than answering 0')
        local ok, res, why = pcall(CisRandom.float, 0 / 0, 5, nil)
        expect(ok and res == nil and type(why) == 'string',
            'float() with a NaN bound returns nil and a reason')
        local v = CisRandom.float(1, 2, CisRandom.newGenerator(4))
        expect(type(v) == 'number' and v >= 1 and v < 2, 'float() still draws an ordinary range')
    end

    -- ------------------------------------------------------------- Interp
    -- The defect here is NARROWER than in Random: clamp is called from
    -- smoothDamp with INFINITE bounds (`maxSpeed or math.huge`), so an
    -- infinite limit is a legitimate "no limit" and must keep working. Only a
    -- NaN value is the bug -- every comparison against NaN is false, so it fell
    -- through all three and came back out as NaN.
    do
        local I = CisInterp
        expect(not pcall(function() return I.clamp('a', 0, 10) end),
            'clamp() with a non-number value raises rather than answering a number')
        expect(not pcall(function() return I.clamp(5, 'a', 10) end),
            'clamp() with a non-number bound raises')

        local res, why = I.clamp(0 / 0, 0, 10)
        expect(res == nil and type(why) == 'string',
            'clamp() of a NaN returns nil and a reason instead of passing NaN through')
        expect(why and why:lower():find('nan') ~= nil,
            ('and the reason names the NaN: %s'):format(tostring(why)))

        local res2, why2 = I.clamp(5, 10, 0)
        expect(res2 == nil and type(why2) == 'string',
            'clamp() with an inverted range returns nil and a reason')

        -- INFINITE BOUNDS ARE NOT AN ERROR. smoothDamp calls clamp with
        -- `-maxChange, maxChange` where maxChange is `math.huge` whenever the
        -- caller passes no maxSpeed, so refusing infinities here would break
        -- the most common calling pattern in the module. This is the assertion
        -- that stops a well-meaning "fix" from doing exactly that.
        expect(I.clamp(5, -math.huge, math.huge) == 5,
            'clamp() accepts infinite bounds, which smoothDamp relies on')
        expect(I.clamp(1e308, -math.huge, math.huge) == 1e308,
            'and clamps through them unchanged')
        expect(I.clamp(math.huge, 0, 10) == 10,
            'an infinite VALUE still clamps to the top of the range')
        expect(I.clamp(-math.huge, 0, 10) == 0,
            'and a negative infinite value to the bottom')

        -- The ordinary path.
        expect(I.clamp(5, 0, 10) == 5, 'clamp() passes a value inside the range')
        expect(I.clamp(-1, 0, 10) == 0, 'clamp() raises a value below the range')
        expect(I.clamp(11, 0, 10) == 10, 'clamp() lowers a value above the range')
        -- And smoothDamp, the internal caller, must still work with its
        -- infinite bounds -- this is what would break first otherwise.
        -- maxSpeed is left nil on purpose, which is what makes smoothDamp
        -- compute `maxChange = math.huge` and hand clamp infinite bounds.
        local moved, vel = I.smoothDamp(0, 100, 0, 0.5, nil, 0.1)
        expect(type(moved) == 'number' and type(vel) == 'number',
            'smoothDamp still runs with its internal infinite clamp bounds')
        expect(moved > 0 and moved < 100, 'and it still moves toward the target')
    end

    -- ----------------------------------------------------------- Validate
    -- AUDITED, NOT CHANGED. `CisValidate.clamp` already returns `nil, reason`
    -- for a non-number, a non-finite value and an inverted range -- it was
    -- written this way. The plan named it as an audit target, and the honest
    -- result of that audit is that there is nothing to do. Pinned here so a
    -- future change that "simplifies" it back to a quiet default fails.
    do
        local V = CisValidate
        local r1, w1 = V.clamp('a', 0, 10)
        expect(r1 == nil and type(w1) == 'string', 'Validate.clamp refuses a non-number with a reason')
        local r2, w2 = V.clamp(0 / 0, 0, 10)
        expect(r2 == nil and type(w2) == 'string', 'Validate.clamp refuses a non-finite value')
        local r3, w3 = V.clamp(5, 10, 0)
        expect(r3 == nil and type(w3) == 'string', 'Validate.clamp refuses an inverted range')
        expect(V.clamp(5, 0, 10) == 5, 'Validate.clamp still clamps an ordinary value')
    end
end
do
    local G = CisGrid
    local grid = G.new()
    -- insert() walks every cell an AABB overlaps, in a nested loop, on
    -- the main thread. A size in metres that reached this file as a cell count,
    -- or a zone covering "the whole map", is a config typo away from freezing
    -- the client -- and there is no way to interrupt a Lua loop once it starts.
    --
    -- The magnitude below is deliberately one that TERMINATES when uncapped
    -- (24649 cells, a few milliseconds). The catastrophic case -- 1e9, which is
    -- billions of iterations -- cannot be written as a failing test, because
    -- against the uncapped code the suite does not fail, it hangs. The cap is
    -- what makes that case safe, and this assertion is what holds the cap.
    local refused, why = G.insert(grid, 'huge', G.aabbFromCenter(0, 0, 0, 5000, 5000, 5000))
    expect(refused == false and type(why) == 'string',
        'an AABB covering too many cells is refused with a reason, not walked')

    -- A refusal must leave the grid untouched, or a caller that ignores the
    -- return has a half-inserted item it can then query.
    local hitsAfterRefusal = 0
    G.queryPoint(grid, 0, 0, 0, function() hitsAfterRefusal = hitsAfterRefusal + 1 end)
    expect(hitsAfterRefusal == 0, 'a refused insert leaves nothing queryable behind')

    -- NaN fails every comparison, so it slips past a naive sanity check and
    -- makes the cell loops silently cover nothing.
    local nanRefused, nanWhy = G.insert(grid, 'nan',
        { minX = 0 / 0, maxX = 10, minY = 0, maxY = 10, minZ = 0, maxZ = 10 })
    expect(nanRefused == false and type(nanWhy) == 'string', 'a NaN coordinate is refused')

    local invRefused, invWhy = G.insert(grid, 'inverted',
        { minX = 100, maxX = 0, minY = 0, maxY = 10, minZ = 0, maxZ = 10 })
    expect(invRefused == false and type(invWhy) == 'string', 'an inverted AABB is refused')

    local nilRefused, nilWhy = G.insert(grid, 'nilbox', nil)
    expect(nilRefused == false and type(nilWhy) == 'string', 'a missing AABB is refused')

    -- THE REFUSAL ITSELF MUST NEVER RAISE, for ANY input. An infinite bound is
    -- the case that got through the first version of this fix: the cell count
    -- is then infinite, and the refusal message formatted it with %d, which
    -- raises on a value with no integer representation. So the worst possible
    -- input turned the refusal into the crash it was written to prevent -- and
    -- a test written only against NaN would have passed it, because NaN takes
    -- the earlier check and never reaches the message.
    local infRefused, infWhy = G.insert(grid, 'inf', {
        minX = -math.huge, maxX = math.huge,
        minY = -math.huge, maxY = math.huge,
        minZ = 0, maxZ = 10,
    })
    expect(infRefused == false and type(infWhy) == 'string',
        'an infinite AABB is refused with a reason rather than raising')
    expect(infWhy and infWhy:lower():find('inf') ~= nil,
        'the refusal for an infinite AABB names the infinite count, and returns')

    -- Same for the overwhelming-but-finite case the cap exists for: the whole
    -- map in one box.
    local wholeMap, wholeMapWhy = G.insert(grid, 'whole-map', G.aabbFromCenter(0, 0, 0, 1e9, 1e9, 1e9))
    expect(wholeMap == false and type(wholeMapWhy) == 'string',
        'a whole-map AABB is refused with a reason rather than walked')

    -- An empty point list is a config error, not a box at the world origin. It
    -- used to return one, which registers a poly zone covering (0,0) and fires
    -- its enter event for a player who happened to spawn there.
    local box, boxWhy = G.aabbFromPoints({}, 0, 1, 0)
    expect(box == nil and type(boxWhy) == 'string',
        'an empty point list is refused rather than answered with the origin')
    expect(G.aabbFromPoints(nil, 0, 1, 0) == nil, 'a nil point list is refused too')

    -- And the ordinary path is untouched: a real zone still inserts, still
    -- queries, and still reports success.
    local ok = G.insert(grid, 'real', G.aabbFromCenter(10, 10, 0, 5, 5, 5), { name = 'real' })
    expect(ok ~= false, 'a normal AABB still inserts')
    local hits = 0
    G.queryPoint(grid, 10, 10, 0, function() hits = hits + 1 end)
    expect(hits == 1, 'a normal AABB is still found by queryPoint')
    local box2 = G.aabbFromPoints({ { x = 0, y = 0 }, { x = 10, y = 10 } }, 0, 1, 0)
    expect(box2 ~= nil and box2.minX == 0 and box2.maxX == 10,
        'a real point list still produces the box it always did')
end

-- =================================================================== CisRate
-- The three limiters differ in boundary behaviour and nothing else. Options
-- are `limit` and `windowSec`, and `now` is in SECONDS -- an earlier draft of
-- this test used maxHits/windowMs in milliseconds, which the limiter ignored,
-- so every case ran against the default budget of 10 and the assertions
-- below passed or failed for the wrong reason.
do
    local fixed = CisRate.newFixed({ limit = 3, windowSec = 1 })
    expect(CisRate.allow(fixed, 'k', 0, 1), 'fixed: hit 1 of 3 allowed')
    expect(CisRate.allow(fixed, 'k', 0, 1), 'fixed: hit 2 of 3 allowed')
    expect(CisRate.allow(fixed, 'k', 0, 1), 'fixed: hit 3 of 3 allowed')
    expect(not CisRate.allow(fixed, 'k', 0, 1), 'fixed: the 4th hit in the window is refused')
    expect(CisRate.allow(fixed, 'k', 1.5, 1), 'fixed: the allowance returns after the window')

    -- The sliding counter is a BUCKETED ESTIMATE, which is the trade for
    -- O(1) amortised instead of O(hits in window). Its exact behaviour at a
    -- window boundary is therefore approximate BY DESIGN, and pinning a precise
    -- one here would assert a precision the module explicitly does not claim.
    -- What must hold is that the limit is enforced against a burst and that it
    -- recovers once the window has genuinely passed.
    local sliding = CisRate.newSliding({ limit = 3, windowSec = 1 })
    for _ = 1, 3 do CisRate.allow(sliding, 'k', 0, 1) end
    expect(not CisRate.allow(sliding, 'k', 0, 1), 'sliding: refuses a burst past the limit')
    expect(CisRate.allow(sliding, 'k', 5, 1), 'sliding: allowed well after the window has passed')

    -- Keys are independent: one player's traffic must not consume another's.
    -- This is the whole reason a limiter is keyed at all.
    local perKey = CisRate.newSliding({ limit = 1, windowSec = 1 })
    expect(CisRate.allow(perKey, 'p1', 0, 1), 'key p1 allowed')
    expect(not CisRate.allow(perKey, 'p1', 0.1, 1), 'key p1 refused on its second hit')
    expect(CisRate.allow(perKey, 'p2', 0.1, 1), 'key p2 is unaffected by p1 exhausting its budget')

    local bucket = CisRate.newTokenBucket({ capacity = 2, refillSec = 10 })
    expect(CisRate.allow(bucket, 'k', 0, 1), 'bucket: first token taken')
    expect(CisRate.allow(bucket, 'k', 0, 1), 'bucket: second token taken')
    expect(not CisRate.allow(bucket, 'k', 0, 1), 'bucket: an empty bucket refuses')
    expect(CisRate.allow(bucket, 'k', 10, 1), 'bucket: refilled after the refill interval')
end

-- ================================================================= CisWindow
-- The ring keeps its size in `w.size`. `CisWindow.count` belongs to the STATS
-- aggregator and takes (stats, key, now) -- calling it on a ring is a
-- different question and reads a field the ring does not have.
do
    local w = CisWindow.new(4)
    CisWindow.push(w, 10, 0) CisWindow.push(w, 20, 1) CisWindow.push(w, 30, 2)
    expect(w.size == 3, 'the window counts its entries')
    CisWindow.push(w, 40, 3) CisWindow.push(w, 50, 4)
    expect(w.size == 4, 'the window is bounded at its capacity')
    expect(CisWindow.oldest(w) == 20, 'the oldest entry is the one that survived longest')
    expect(CisWindow.newest(w) == 50, 'the newest entry is the one just pushed')

    local d = CisWindow.newDedupe(1.0)
    expect(CisWindow.seen(d, 'k', 0), 'first sighting of a key is allowed')
    expect(not CisWindow.seen(d, 'k', 0.5), 'the same key inside the window is refused')
    expect(CisWindow.seen(d, 'k', 1.5), 'the same key after the window is allowed again')
    expect(CisWindow.seen(d, 'other', 0.2), 'a different key is unaffected')
end

-- ================================================================= CisRandom
-- Determinism is the claim, so it is tested by running the same seed twice.
-- The generator is an OBJECT with :next() / :int(), not a bare function --
-- the module functions take it as their last argument so a caller can swap
-- in a different generator.
do
    local a = CisRandom.newGenerator(12345)
    local b = CisRandom.newGenerator(12345)
    local same = true
    for _ = 1, 50 do
        if a:next() ~= b:next() then same = false end
    end
    expect(same, 'the same seed produces the same sequence')
    local c = CisRandom.newGenerator(999)
    local differs = false
    for _ = 1, 50 do
        if a:next() ~= c:next() then differs = true end
    end
    expect(differs, 'a different seed produces a different sequence')

    local r = CisRandom.newGenerator(7)
    local inRange = true
    for _ = 1, 500 do
        local v = CisRandom.integer(3, 7, r)
        if type(v) ~= 'number' or v < 3 or v > 7 or v % 1 ~= 0 then inRange = false end
    end
    expect(inRange, 'integer(lo, hi, rng) stays in range and stays integral')

    -- The bug the author found: sample returned all n elements, not k.
    local shuffled = CisRandom.shuffle({ 1, 2, 3, 4, 5 }, r)
    expect(#shuffled == 5, 'shuffle returns every element')
    local picked = CisRandom.sample({ 1, 2, 3, 4, 5, 6, 7, 8 }, 3, r)
    expect(#picked == 3, 'sample returns exactly k elements, not all of them')

    -- A shuffle must be a permutation, not a copy: the same multiset out.
    local src = { 1, 2, 3, 4, 5, 6 }
    local out = CisRandom.shuffle(src, r)
    local total = 0
    for _, v in ipairs(out) do total = total + v end
    expect(total == 21, 'shuffle preserves the multiset it was given')
    local distinct = true
    for i = 2, #out do
        for j = 1, i - 1 do
            if out[i] == out[j] then distinct = false end
        end
    end
    expect(distinct, 'shuffle introduces no duplicates')

    -- A range wider than one MINSTD period. Every draw used to come back
    -- `hi`: the generator could not represent the range, and the collapse was
    -- silent. A caller drawing a 64-bit id got the same id every time, which
    -- looks like a working feature right up until two players draw one.
    do
        local wide = CisRandom.newGenerator(31337)
        local seen = {}
        for _ = 1, 100 do seen[wide:int(0, 2 ^ 40)] = true end
        local distinctWide = 0
        for _ in pairs(seen) do distinctWide = distinctWide + 1 end
        expect(distinctWide > 1, 'gen:int over a range wider than 2^31 does not collapse to one value')

        local stayedInRange = true
        local highest = 0
        for _ = 1, 200 do
            local v = wide:int(0, 2 ^ 40)
            if type(v) ~= 'number' or v < 0 or v > 2 ^ 40 or v % 1 ~= 0 then stayedInRange = false end
            if v > highest then highest = v end
        end
        expect(stayedInRange, 'gen:int stays in range and integral past 2^31')
        -- "Not all equal" is the weakest form of this assertion: a fix that
        -- drew from one 31-bit step and took `% n` would produce 200 distinct
        -- low-valued numbers and pass it. The draw has to actually reach the
        -- top of the range, which only an assembled 53-bit draw does.
        expect(highest > 2 ^ 39, 'gen:int uses the high bits of a wide range, not just the low ones')

        -- The public entry point, and the injected-function path, hit the same
        -- ceiling from a different direction and have to survive it too.
        local g2 = CisRandom.newGenerator(31337)
        local seen2 = {}
        for _ = 1, 100 do seen2[CisRandom.integer(0, 2 ^ 40, g2)] = true end
        local distinct2 = 0
        for _ in pairs(seen2) do distinct2 = distinct2 + 1 end
        expect(distinct2 > 1, 'integer(lo, hi, gen) survives a range wider than 2^31')

        local g3 = CisRandom.newGenerator(31337)
        local seen3 = {}
        for _ = 1, 100 do
            seen3[CisRandom.integer(0, 2 ^ 40, function() return g3:float() end)] = true
        end
        local distinct3 = 0
        for _ in pairs(seen3) do distinct3 = distinct3 + 1 end
        expect(distinct3 > 1, 'integer(lo, hi, injected fn) survives a range wider than 2^32')

        -- Past what a double can hold exactly there is no honest answer to
        -- give, so the generator refuses instead of returning a plausible one.
        -- Pinning that here is the point: a fix that quietly answered `lo`
        -- would pass every assertion above.
        local ok, err = pcall(function() return wide:int(0, 1e18) end)
        expect(not ok and type(err) == 'string',
            'gen:int refuses a range wider than it can represent, rather than answering')

        -- THE INTEGER BOUNDS, where `hi - lo + 1` wraps. integer(0, maxinteger)
        -- counted a negative range and always drew 0; the full integer range
        -- counted 0. On a runtime whose integers are 64-bit both are wider than
        -- 2^53 and an injected generator refuses them; on a 32-bit one they fit.
        local maxI, minI = math.maxinteger, math.mininteger
        local wideInts = (maxI + 0.0) > 2 ^ 53
        local seenTop, nonZero, drawsInRange = 0, false, true
        for _ = 1, 64 do
            local v = CisRandom.integer(0, maxI)
            if v ~= 0 then nonZero = true end
            if type(v) ~= 'number' or v < 0 or v > maxI then drawsInRange = false end
            if v > maxI / 2 then seenTop = seenTop + 1 end
        end
        expect(nonZero and drawsInRange and seenTop > 0,
            ('integer(0, math.maxinteger) draws across the range, not 0 every time (upper half %d of 64)'):format(seenTop))
        local g4 = CisRandom.newGenerator(77)
        local okFn, fnRes = pcall(CisRandom.integer, 0, maxI, function() return g4:float() end)
        local okGen, genRes = pcall(CisRandom.integer, minI, maxI, CisRandom.newGenerator(78))
        if wideInts then
            expect(not okFn and tostring(fnRes):find('2^53', 1, true) ~= nil
                and not okGen and tostring(genRes):find('2^53', 1, true) ~= nil,
                ('the 64-bit integer range is refused by an injected generator, not answered (%s / %s)')
                    :format(tostring(fnRes), tostring(genRes)))
        else
            expect(okFn and fnRes >= 0 and fnRes <= maxI and okGen and genRes >= minI and genRes <= maxI,
                ('the 32-bit integer range is drawn from by an injected generator (%s / %s)')
                    :format(tostring(fnRes), tostring(genRes)))
        end
    end

    -- The two paths disagreed about the same call: math.random raises on
    -- a fractional bound, the generator returned 1.5, and a NaN bound came back
    -- out of the generator as NaN and straight into whatever used it.
    do
        -- A wrapper, because `pcall(CisRandom.integer, a, b, nil)` is a parse
        -- error in fengari: the call cannot end on a bare nil.
        local function tryInteger(lo, hi, generator)
            return pcall(CisRandom.integer, lo, hi, generator)
        end

        local withGen = CisRandom.integer(1.5, 3.5, CisRandom.newGenerator(9))
        local okNoGen, withoutGen = tryInteger(1.5, 3.5)
        expect(okNoGen, 'integer(1.5, 3.5) does not raise without a generator')
        expect(type(withGen) == 'number' and withGen % 1 == 0,
            'integer(1.5, 3.5, gen) is integral, not 1.5')
        expect(type(withoutGen) == 'number' and withoutGen % 1 == 0,
            'integer(1.5, 3.5) is integral on the math.random path too')
        -- Type-guarded, because on the broken build `withoutGen` is the pcall
        -- ERROR STRING and an ordering comparison against a string raises --
        -- which would abort the whole file instead of reporting a failure.
        expect(type(withGen) == 'number' and type(withoutGen) == 'number'
            and withGen >= 1 and withGen <= 4 and withoutGen >= 1 and withoutGen <= 4,
            'a fractional range floors its low bound and ceils its high bound')

        local ok1, r1 = tryInteger(0 / 0, 5, CisRandom.newGenerator(9))
        local ok2, r2 = tryInteger(0, 0 / 0, CisRandom.newGenerator(9))
        local ok3, r3 = tryInteger(0, 0 / 0)
        expect(ok1 and ok2 and ok3, 'a NaN bound does not raise on any path')
        expect(r1 == nil and r2 == nil and r3 == nil,
            'a NaN bound is refused on every path instead of propagating NaN')

        local ok4, r4 = tryInteger(0, math.huge, CisRandom.newGenerator(9))
        expect(ok4 and r4 == nil, 'an infinite bound is refused, not answered with Infinity')

        -- The ordinary integer path is untouched by any of that.
        local g = CisRandom.newGenerator(9)
        expect(CisRandom.integer(5, 5, g) == 5, 'a single-value range returns that value')
    end

    -- An infinite weight made the whole cumulative array infinite, so
    -- the binary search walked to the last index and the infinite entry was
    -- never picked -- 0 times out of 200, not occasionally.
    do
        local g = CisRandom.newGenerator(3)
        expect(CisRandom.weightedIndex({ math.huge, 1 }, g) == 1,
            'an infinite weight is picked, not skipped')
        local hits = 0
        local g2 = CisRandom.newGenerator(3)
        for _ = 1, 200 do
            if CisRandom.weightedIndex({ math.huge, 1 }, g2) == 1 then hits = hits + 1 end
        end
        expect(hits == 200, 'an infinite weight wins every draw, not none of them')
        expect(CisRandom.weighted({ { weight = math.huge, value = 'a' }, { weight = 1, value = 'b' } }, g2) == 'a',
            'weighted agrees with weightedIndex on an infinite weight')

        local g3 = CisRandom.newGenerator(3)
        expect(CisRandom.weightedIndex({ 0, 0 }, g3) == nil, 'a table of zero weights still returns nil')
        expect(CisRandom.weightedIndex({ 0 / 0, 1 }, g3) == 2,
            'a NaN weight is skipped rather than summed into the total')
        expect(CisRandom.weightedIndex({}, g3) == nil, 'an empty weight table still returns nil')

        -- The ordinary path is untouched: a big but finite weight still draws
        -- by proportion, and neither entry is starved.
        local seen = { [1] = 0, [2] = 0 }
        local g4 = CisRandom.newGenerator(3)
        for _ = 1, 400 do
            local idx = CisRandom.weightedIndex({ 3, 1 }, g4)
            seen[idx] = (seen[idx] or 0) + 1
        end
        expect(seen[1] and seen[2] and seen[1] > 0 and seen[2] > 0,
            'finite weights still draw both entries in proportion')
    end

    -- abs() then floor() then a modulo folded 1, -1 and 1.7 onto the
    -- same state, so three different seeds produced three identical streams.
    do
        local function firstDraw(seed)
            return CisRandom.newGenerator(seed):float()
        end
        expect(firstDraw(1) ~= firstDraw(-1),
            'a negative seed is not the same generator as its absolute value')
        expect(firstDraw(1) ~= firstDraw(1.7),
            'a fractional seed is not floored onto its integer part')
        expect(firstDraw(2147483646) ~= firstDraw(2147483647),
            'seeds either side of the period do not collide')
        expect(firstDraw(0) ~= firstDraw(1), 'seed 0 is not the generator fixed point')
        expect(firstDraw(12345) == firstDraw(12345), 'hashing the seed keeps it deterministic')
        expect(firstDraw('nope') == firstDraw('nope'),
            'a nonsense seed still gives a usable, repeatable generator')
        local g1, g2 = CisRandom.newGenerator(12345), CisRandom.newGenerator(12345)
        local stateOk = type(g1.state) == 'table' and #g1.state == 6
        for k = 1, 6 do
            local w, top = stateOk and g1.state[k], k <= 3 and 4294967087 or 4294944443
            if not (w and w == g2.state[k] and w >= 0 and w < top and w % 1 == 0) then stateOk = false end
        end
        expect(stateOk, 'the hashed state is six integral words inside the two MRG32k3a moduli')
    end

    -- MINSTD made seed k the same stream as seed 1 times k: for seeds 1 and 2,
    -- b == 2a (mod 1) held on every draw, and seeds 0 and 2147483646 were the
    -- same generator. The generator is now MRG32k3a with a cubed seed.
    do
        local function firstDraw(seed)
            return CisRandom.newGenerator(seed):float()
        end
        expect(firstDraw(0) ~= firstDraw(2147483646), 'seeds 0 and 2147483646 are different generators')
        expect(firstDraw(0) ~= firstDraw(4294967087), 'a seed past the modulus does not fold onto a smaller one')
        local base = CisRandom.newGenerator(1)
        local others = { [2] = CisRandom.newGenerator(2), [3] = CisRandom.newGenerator(3), [7] = CisRandom.newGenerator(7) }
        local linear = 0
        for _ = 1, 1000 do
            local x = base:float()
            for k, g in pairs(others) do
                if math.abs((k * x) % 1 - g:float()) < 1e-6 then linear = linear + 1 end
            end
        end
        expect(linear < 5, ('seeds 2, 3 and 7 are not seed 1 times a constant (%d of 3000 draws)'):format(linear))
        -- L'Ecuyer's published state 12345 x 6: the first U01 is 0.1270111220.
        local kat = CisRandom.newGenerator(1)
        kat.state = { 12345, 12345, 12345, 12345, 12345, 12345 }
        local r1, r2, r3 = kat:next(), kat:next(), kat:next()
        -- The seeded stream itself is pinned: it is the same under Lua 5.4 and
        -- fengari, where an integer product wraps at 32 bits.
        local s1, s2 = CisRandom.newGenerator(1):next(), CisRandom.newGenerator(-2.5):next()
        local wideDraw = CisRandom.newGenerator(31337):int(0, 2 ^ 40)
        expect(s1 == 2869526954 and s2 == 4041100382 and wideDraw == 25302793138,
            ('the seeded stream is the pinned one in every runtime, got %s %s %s')
                :format(tostring(s1), tostring(s2), tostring(wideDraw)))
        local drawn = CisRandom.newGenerator(9):int(3, 7)
        expect(math.type(drawn) == 'integer', 'gen:int answers an integer, not a float, got ' .. tostring(drawn))
        expect(r1 == 545508589 and r2 == 1368065410 and r3 == 1327943761,
            ('MRG32k3a matches the reference stream, got %s %s %s'):format(tostring(r1), tostring(r2), tostring(r3)))
    end
end

-- =================================================================== CisCurve
-- A spline that does not pass through its control points is the wrong tool
-- for a waypoint list, so that is what is checked.
do
    local path = CisCurve.newPath({ { x = 0, y = 0 }, { x = 10, y = 0 }, { x = 10, y = 10 } })
    expect(path ~= nil, 'a path builds from three points')
    expect(CisCurve.count(path) == 3, 'the path holds every waypoint')
    -- A spline BOWS between its waypoints, so the arc is longer than the
    -- 20-unit polyline. Asserting 20 would be asserting the module is a
    -- polyline; it is the opposite, and that is why it exists.
    expect(CisCurve.length(path) > 20, 'the curve bows out beyond the straight polyline')
    -- pointAtXYZ returns x, y, z AND an ok flag -- four numbers, not a point
    -- table. pointAt(path, distance, out) is the one that fills a table.
    local x, y, _, ok = CisCurve.pointAtXYZ(path, 0)
    expect(ok == true, 'a distance inside the path is reported as on-path')
    near(x, 0, 1e-6, 'the path starts at its first waypoint on x')
    near(y, 0, 1e-6, 'the path starts at its first waypoint on y')
    local out = {}
    CisCurve.pointAt(path, CisCurve.length(path) * 0.5, out)
    expect(type(out.x) == 'number' and type(out.y) == 'number' and type(out.z) == 'number',
        'pointAt fills the supplied table with a real point')
end

-- ================================================================== CisTable
do
    local T = CisTable
    local src = { a = 1, b = { c = 2, d = { 3, 4 } } }
    local cp = T.deepCopy(src)
    expect(cp.b.c == 2 and cp.b.d[2] == 4, 'deep copy reproduces a nested structure')
    cp.b.c = 99
    expect(src.b.c == 2, 'deep copy does not alias the original')
    expect(T.isArray({ 1, 2, 3 }), 'isArray recognises an array')
    expect(not T.isArray({ a = 1 }), 'isArray rejects a map')
    expect(T.count({ 1, 2, 3 }) == 3, 'count sizes an array')
    expect(T.count({ a = 1, b = 2 }) == 2, 'count sizes a map')
    -- The bug the author found: reduce fed the seed element to the callback
    -- twice, so the sum of 1..5 came out 16.
    near(T.reduce({ 1, 2, 3, 4, 5 }, function(acc, v) return acc + v end, 0), 15, nil,
        'reduce sums correctly and does not double-count the seed')
    -- ...and deepMerge recursed into two arrays, turning {1,2,3}+{9} into {9,2,3}
    local merged = T.deepMerge({ 1, 2, 3 }, { 9 })
    expect(#merged == 3, 'deepMerge does not recurse into arrays as if they were maps')

    -- A cycle must not hang the copier. This is the totality claim.
    local cyclic = { name = 'root' }
    cyclic.self = cyclic
    local copied = T.deepCopy(cyclic)
    expect(copied ~= nil and copied.name == 'root', 'deepCopy survives a self-referencing table')
end

-- ================================================================= CisString
do
    local S = CisString
    expect(#S.split('a,b,c', ',') == 3, 'split returns every part')
    expect(#S.split('', ',') == 0, 'split of an empty string returns an empty list, not a nil part')
    expect(S.truncate('abcdefgh', 5):len() <= 6, 'truncate bounds the result')
    expect(S.contains('Hello', 'ell'), 'contains finds a substring')
    expect(S.startsWith('cis_libs', 'cis'), 'startsWith')
    expect(S.endsWith('cis_libs', 'libs'), 'endsWith')
    expect(S.levenshtein('cis_libs', 'cis_libz') == 1, 'levenshtein counts a single substitution')
    expect(S.levenshtein('', 'abc') == 3, 'levenshtein against an empty string')
    expect(S.levenshtein('same', 'same') == 0, 'levenshtein of identical strings is zero')
    -- The bug the author found: joinCased only touched the first letter, so
    -- GIVE_MONEY came out as gIVEmONEY.
    local snake = S.camel('GIVE_MONEY')
    expect(snake == 'giveMoney' or snake == 'give_money', 'camel casing handles SHOUTING_SNAKE')
end

-- ================================================================ CisValidate
-- This repo's refusal convention: never a bare nil, always a reason.
do
    local V = CisValidate
    expect(V.number(5) == true, 'a valid number passes')
    local ok, why = V.number('x')
    expect(ok == false, 'an invalid number fails')
    expect(type(why) == 'string' and why ~= '', 'and the refusal carries a reason string')
    expect(V.string('x') == true, 'a valid string passes')
    local ok2, why2 = V.string(5)
    expect(ok2 == false and type(why2) == 'string', 'a non-string fails with a reason')
    expect(V.integer(3) == true, 'an integer passes')
    expect(V.integer(3.5) == false, 'a non-integer fails')
    expect(V.clamp(15, 0, 10) == 10, 'clamp bounds a value')
    expect(V.clamp(-5, 0, 10) == 0, 'clamp raises a value')
end

-- =================================================================== CisTime
do
    local T = CisTime
    expect(T.formatDuration(90000):find('h') ~= nil, '90 seconds formats with hours')
    local text = T.formatDuration(9000)
    local secs, why = T.parseDuration(text)
    expect(secs == 9000 and why == nil, 'parseDuration reads back exactly what formatDuration wrote')
    expect(T.parseDuration('nonsense') == nil, 'parseDuration refuses a string it cannot read')
    expect(T.relative(1000, 5000):len() > 0, 'relative renders without error')
    expect(T.relative(5000, 1000):len() > 0, 'relative handles a future timestamp')
end

-- ================================================================== CisSemver
-- Lua patterns have no alternation, which is how every '>=' in a range
-- silently matched a literal string and validated nothing.
do
    local S = CisSemver
    expect(S.compare('1.2.3', '1.2.4') < 0, 'compare orders a lower minor below')
    expect(S.compare('1.10.0', '1.9.0') > 0, 'compare is numeric, not lexical, per component')
    expect(S.gte('1.2.3', '1.2.3'), 'gte is inclusive')
    expect(S.satisfies('1.2.3', '^1.0.0'), 'satisfies accepts inside a caret range')
    expect(not S.satisfies('2.0.0', '^1.0.0'), 'satisfies rejects outside a caret range')
    expect(S.satisfies('1.2.9', '~1.2.0'), 'satisfies accepts inside a tilde range')
    expect(not S.satisfies('1.3.0', '~1.2.0'), 'satisfies rejects outside a tilde range')
    expect(S.satisfies('1.5.0', '>=1.0.0'), 'satisfies handles a >= comparator')
    expect(not S.satisfies('0.9.0', '>=1.0.0'), 'satisfies rejects below a >= comparator')
    expect(S.satisfies('1.5.0', '1.x'), 'satisfies handles a wildcard')

    -- Wrappers, because a bare `pcall(CisSemver.parse, '1.2.3')` is fragile in
    -- fengari's parser when the first argument is a dotted global.
    local function parseOf(str)
        return pcall(CisSemver.parse, str)
    end

    -- A numeric component too wide for a double used to RAISE out of
    -- the parser rather than being refused. `parse` is documented as never
    -- raising and returning `nil, reason`, and a version string arrives from
    -- another resource's manifest, so raising here took down the caller.
    do
        local ok, res, why = parseOf('1.2.99999999999999999999')
        expect(ok, 'parse does not raise on a numeric part too wide for a double')
        expect(res == nil and type(why) == 'string' and why ~= '',
            'an over-wide numeric part is refused with a reason, not silently rounded')

        local ok2, res2, why2 = parseOf('99999999999999999999.2.3')
        expect(ok2 and res2 == nil and type(why2) == 'string',
            'the same refusal applies to an over-wide major')

        -- 2^53 - 1 is the largest integer a double holds exactly, and the
        -- limit node-semver applies. Anything above it would silently become a
        -- different number, so it is refused rather than rounded.
        expect(S.parse('1.2.123456789012345').normalized == '1.2.123456789012345',
            'a 15-digit component parses and normalizes exactly')
        expect((S.parse('1.2.9007199254740991') or {}).normalized == '1.2.9007199254740991',
            'a component of exactly 2^53 - 1 parses and normalizes exactly')
        local ok3, res3 = parseOf('1.2.9007199254740992')
        expect(ok3 and res3 == nil, 'a component of 2^53 is refused rather than rounded')

        -- The refusal has to survive the whole chain, or it just moves the
        -- raise one function up.
        local okS = pcall(CisSemver.satisfies, '1.2.99999999999999999999', '^1.0.0')
        expect(okS, 'satisfies does not raise on an unparsable version')
        expect(S.satisfies('1.2.99999999999999999999', '^1.0.0') == nil,
            'satisfies refuses an unparsable version with nil, not a raise')
    end

    -- npm reads '<=1.2' as '<1.3.0' and '>1.2' as '>=1.3.0'. Both were
    -- read as a bound against 1.2.0 EXACTLY, so a range meant to allow a whole
    -- minor silently refused every patch after it -- the kind of range that
    -- looks right in a config and rejects a working resource at boot.
    do
        expect(S.satisfies('1.2.5', '<=1.2') == true, "'<=1.2' allows 1.2.5, as npm does")
        expect(S.satisfies('1.3.0', '<=1.2') == false, "'<=1.2' still refuses 1.3.0")
        expect(S.satisfies('1.2.5', '>1.2') == false, "'>1.2' refuses 1.2.5, as npm does")
        expect(S.satisfies('1.3.0', '>1.2') == true, "'>1.2' allows 1.3.0")

        -- The single-component form moves too.
        expect(S.satisfies('1.9.0', '<=1') == true, "'<=1' allows 1.9.0")
        expect(S.satisfies('2.0.0', '<=1') == false, "'<=1' refuses 2.0.0")
        expect(S.satisfies('1.9.0', '>1') == false, "'>1' refuses 1.9.0")
        expect(S.satisfies('2.0.0', '>1') == true, "'>1' allows 2.0.0")

        -- A full three-component comparator is an exact bound and stays one.
        expect(S.satisfies('1.2.5', '<=1.2.5') == true, "'<=1.2.5' is still an exact bound")
        expect(S.satisfies('1.2.5', '>1.2.5') == false, "'>1.2.5' is still an exact bound")
        expect(S.satisfies('1.2.5', '>1.2.4') == true, "'>1.2.4' is still an exact bound")

        -- '<' and '>=' already meant what they say and must keep meaning it.
        expect(S.satisfies('1.2.5', '<1.2') == false, "'<1.2' is still '<1.2.0'")
        expect(S.satisfies('1.2.5', '>=1.2') == true, "'>=1.2' is still '>=1.2.0'")

        -- The rewritten bound must not carry a prerelease, or it would let a
        -- prerelease target past the rule that is the whole point of the file.
        expect(S.satisfies('1.2.5-rc1', '<=1.2') == false,
            "a prerelease of 1.2.5 is still refused by '<=1.2'")

        -- A prerelease only follows a full MAJOR.MINOR.PATCH, in a version and
        -- in a range. '~1-rc1' used to be read as '~1' with the tag ignored;
        -- npm refuses it, and so does this.
        expect(S.satisfies('1.5.0', '~1') == true, "'~1' still means >=1.0.0 <2.0.0-0")
        expect(S.satisfies('1.5.0', '~1-rc1') == nil,
            "'~1-rc1' is not a range: a prerelease needs a full version")
    end
end

-- ================================================================= CisId
do
    -- CONTRACT MISMATCH between the two modules, found only by running them
    -- together: CisId wanted a bare FUNCTION returning [0,1), while
    -- CisRandom.newGenerator returns an OBJECT with :float(). It used to be
    -- bridged with a closure, and the mismatch recorded rather than fixed.
    --
    -- Phase 4 settles the convention: the rng is LAST and OPTIONAL, and it
    -- accepts either shape. So the closure below should no longer be needed --
    -- which is the assertion, because "the shim exists" is worth nothing unless
    -- something stops needing the workaround.
    local gen = CisRandom.newGenerator(4242)
    local a = CisId.short('door', { rng = gen, length = 8 })
    local b = CisId.short('door', { rng = gen, length = 8 })
    expect(type(a) == 'string', 'short returns a string or a refusal: ' .. tostring(a))
    expect(a:sub(1, 5) == 'door_', 'short puts the readable prefix first, for log lines')
    expect(a ~= b, 'two draws differ')

    -- draw, with the rng in the CONVENTIONAL position and a generator object
    -- handed straight in.
    do
        local g = CisRandom.newGenerator(99)
        local s, why = CisId.draw(8, nil, g)
        expect(type(s) == 'string' and #s == 8,
            ('draw(count, alphabet, generator) works: %s'):format(tostring(why)))

        -- Optional: no rng at all means math.random, which is what every other
        -- function in this file does when handed no generator.
        local s2 = CisId.draw(8)
        expect(type(s2) == 'string' and #s2 == 8, 'draw(count) with no rng at all still draws')

        -- A plain function still works in the same position.
        local s3 = CisId.draw(8, nil, function() return 0.5 end)
        expect(type(s3) == 'string' and #s3 == 8, 'draw accepts a bare function in the last position')

        -- THE LEGACY FIRST-POSITION FORM STILL WORKS. This is a minor version,
        -- and a consumer written against 2.0.0 has `draw(rng, count, alphabet)`
        -- in its code already.
        local legacyFn = CisId.draw(function() return 0.5 end, 8, nil)
        expect(type(legacyFn) == 'string' and #legacyFn == 8,
            'the legacy draw(rng, count, alphabet) form still works')
        local legacyGen = CisId.draw(CisRandom.newGenerator(99), 8, nil)
        expect(type(legacyGen) == 'string' and #legacyGen == 8,
            'and it now accepts a generator object there too, which it used to refuse')

        -- Determinism: the same generator twice gives the same id. This is the
        -- whole reason to pass an rng, and it is only true if the object was
        -- actually used rather than ignored in favour of math.random.
        local g1, g2 = CisRandom.newGenerator(7), CisRandom.newGenerator(7)
        expect(CisId.draw(12, nil, g1) == CisId.draw(12, nil, g2),
            'the same generator gives the same id, so the object really is the source')

        -- A broken generator is still refused with a reason. Accepting the
        -- object shape must not have loosened this.
        local bad, badWhy = CisId.draw(4, nil, function() return 1.0 end)
        expect(bad == nil and type(badWhy) == 'string',
            'a generator returning 1.0 is still refused with a reason')
        local bad2, badWhy2 = CisId.draw(4, nil, 'not an rng')
        expect(bad2 == nil and type(badWhy2) == 'string',
            'and something that is not an rng at all is refused with a reason')
    end

    -- gaussian: same convention, and it is the OTHER function the plan named.
    do
        local g = CisRandom.newGenerator(11)
        local v = CisRandom.gaussian(0, 1, g)
        expect(type(v) == 'number' and v == v, 'gaussian(mean, sd, generator) draws a number')
        expect(type(CisRandom.gaussian()) == 'number',
            'gaussian() with no arguments at all still draws')
        -- Guarded, because the broken form does not return a wrong number here --
        -- it performs arithmetic on the rng itself and RAISES, which would
        -- abort the whole file instead of reporting one failed assertion.
        local legacyOk, legacy = pcall(CisRandom.gaussian, function() return 0.5 end, 10, 1)
        expect(legacyOk and type(legacy) == 'number',
            'the legacy gaussian(rng, mean, sd) form still works')
        -- The generator really is used: same seed, same value.
        local g1, g2 = CisRandom.newGenerator(3), CisRandom.newGenerator(3)
        expect(CisRandom.gaussian(0, 1, g1) == CisRandom.gaussian(0, 1, g2),
            'gaussian is deterministic in the generator it was given')
    end
end

-- =================================================================== CisJson
-- The real codec tests are in Phase 6 below, against a working reference codec.

-- =================================================================== CisWindow
-- A ring of time buckets. The invariant pinned here is that the ring cursor
-- moves ONCE PER BUCKET, and that every slot it steps over is zeroed before
-- the next write merges into it.
--
-- Both halves were wrong, in opposite directions, and neither showed up in the
-- other tests because every existing case fed the window one sample at a time:
--
--   * the cursor advanced once per SAMPLE, so four samples inside one bucket
--     landed in four slots and `bucketAt` dated three of them a bucket too old
--     -- they expired early and the window UNDER-counted;
--   * the slots stepped over were not always cleared, and the write merges
--     ADDITIVELY, so on a one-bucket advance the oldest live sample was added
--     to instead of replaced -- the window OVER-counted and reported a value a
--     whole window old as live. `count` is what a rate check runs on.
do
    local s = CisWindow.newStats(3, 1)
    for _, t in ipairs({ 10, 11, 12, 13 }) do
        CisWindow.record(s, 'k', t, t)
    end
    local r = CisWindow.read(s, 'k', 13.5)
    expect(r ~= nil and r.count == 3 and r.sum == 36 and r.min == 11,
        'window: the three live buckets count, and the one that aged out does not')

    local one = CisWindow.newStats(3, 1)
    CisWindow.record(one, 'k', 5, 10)
    local r1 = CisWindow.read(one, 'k', 11.5)
    expect(r1 ~= nil and r1.count == 1 and r1.sum == 5,
        'window: a single live sample counts once, not merged with a stale one')

    local bucket = CisWindow.newStats(3, 1)
    for _, t in ipairs({ 10.1, 10.2, 10.3, 10.4 }) do
        CisWindow.record(bucket, 'k', 1, t)
    end
    local rb = CisWindow.read(bucket, 'k', 11.5)
    expect(rb ~= nil and rb.count == 4,
        'window: four samples inside ONE bucket stay in one slot and all count')

    local summed = CisWindow.newStats(3, 1)
    CisWindow.record(summed, 'k', 2, 10)
    CisWindow.record(summed, 'k', 3, 10)
    local rs = CisWindow.read(summed, 'k', 11.0)
    expect(rs ~= nil and rs.count == 2 and rs.sum == 5 and rs.min == 2 and rs.max == 3,
        'window: samples in one bucket merge into one sum with the right extremes')

    local stale = CisWindow.newStats(3, 1)
    CisWindow.record(stale, 'k', 7, 10)
    expect(CisWindow.read(stale, 'k', 1000.0) == nil,
        'window: a jump wider than the ring empties it')

    local rolled = CisWindow.newStats(3, 1)
    for t = 1, 50 do
        CisWindow.record(rolled, 'k', t, t)
    end
    local rr = CisWindow.read(rolled, 'k', 50.5)
    expect(rr ~= nil and rr.count == 3 and rr.sum == (48 + 49 + 50) and rr.min == 48,
        'window: after 50 samples the ring holds exactly the last three')
end

-- ================================================================== CisRate
-- ANCHORING, which is a separate mode from the fixed limiter tested above and
-- had no test at all.
--
-- `anchored = true` used to fold the window anchor back into one window with
-- `start = start % windowSec`, added to stop float error accumulating. Folding
-- severs the anchor from wall-clock time, so the very next call found
-- `now >= start + windowSec` trivially true, reset the counter and let the key
-- spend again: an anchored limiter of 2 per 10s allowed 20 calls inside a
-- single 10s window. A limiter that allows everything is worse than no limiter,
-- because a caller trusts it.
do
    local anchored = CisRate.newFixed({ limit = 2, windowSec = 10, anchored = true })
    expect(CisRate.allow(anchored, 'k', 200, 1), 'anchored: the allowance starts')
    expect(CisRate.allow(anchored, 'k', 200, 1), 'anchored: the second of two is allowed')
    -- 205 is still inside the anchored window that opened at 200, so none of
    -- these twenty may be served. The fold bug served all twenty.
    local spent = 0
    for i = 1, 20 do
        if CisRate.allow(anchored, 'k', 205 + i * 0.01, 1) then
            spent = spent + 1
        end
    end
    expect(spent == 0, 'anchored: the rest of that window is refused, not handed out again')

    local again = CisRate.newFixed({ limit = 2, windowSec = 10, anchored = true })
    CisRate.allow(again, 'k', 200, 1)
    CisRate.allow(again, 'k', 200, 1)
    expect(CisRate.allow(again, 'k', 211, 1), 'anchored: a genuinely new window restores the allowance')
end

-- ================================================================= CisRate
-- THE SLIDING LIMITER ENFORCED THE LIMIT PER SLICE, NOT PER WINDOW.
--
-- This is the limiter the module itself recommends for anti-cheat, and it was
-- the one that did not work. The estimate was
--
--     previous * (1 - progress) + current
--
-- over TWO numbers, so `current` -- the slice the caller is in right now -- was
-- compared against the whole `limit`. With limit=10, windowSec=1 and ten
-- subdivisions, a caller could place 10 events in every slice and the estimate
-- never exceeded 10: 100 evenly spaced calls inside one second were allowed.
-- The slice is a unit of RESOLUTION, not a unit of budget, and the code was
-- treating it as a budget.
do
    -- The headline case, stated exactly as the audit found it.
    local l = CisRate.newSliding({ limit = 10, windowSec = 1, subdivisions = 10 })
    local allowed = 0
    for i = 1, 100 do
        if CisRate.allow(l, 'k', (i - 1) * 0.01, 1) then
            allowed = allowed + 1
        end
    end
    expect(allowed <= 11,
        ('100 evenly spread calls in 1s allow at most limit+1 (allowed %d)')
            :format(allowed))

    -- Ten at once, then one a quarter of a second later: refused. This is the
    -- case that separates a per-WINDOW limiter from a per-SLICE one -- the old
    -- code reset `current` at the slice boundary and treated the reset as a
    -- fresh allowance.
    local burst = CisRate.newSliding({ limit = 10, windowSec = 1, subdivisions = 10 })
    for _ = 1, 10 do CisRate.allow(burst, 'k', 0, 1) end
    expect(not CisRate.allow(burst, 'k', 0.25, 1),
        'ten calls at t=0 followed by one at t=0.25 is refused')
    -- ...and it recovers once the window has genuinely passed, which is what
    -- makes it a limiter rather than a permanent lockout.
    expect(CisRate.allow(burst, 'k', 2, 1),
        'the allowance returns once the window has passed')

    -- The estimate must DECAY, not reset: a caller that is refused keeps
    -- decaying toward the limit as the old slices age out of the window.
    local decay = CisRate.newSliding({ limit = 10, windowSec = 2, subdivisions = 10 })
    for _ = 1, 10 do CisRate.allow(decay, 'k', 0, 1) end
    expect(not CisRate.allow(decay, 'k', 0.5, 1), 'still refused halfway through the window')
    expect(CisRate.allow(decay, 'k', 2.1, 1), 'allowed once the earliest slices have aged out')

    -- A refusal must still not consume budget, and a lower cost must fit where
    -- a full one does not. Both are documented properties of `allow`.
    local cost = CisRate.newSliding({ limit = 5, windowSec = 1, subdivisions = 5 })
    for _ = 1, 5 do CisRate.allow(cost, 'k', 0, 1) end
    expect(not CisRate.allow(cost, 'k', 0, 1), 'a full-cost call is refused at the limit')
    expect(not CisRate.allow(cost, 'k', 0, 1),
        'a refused call does not consume budget, so it stays refused')
end

-- ================================================================= CisWindow
-- recording a sample with an EARLIER timestamp than the newest one.
--
-- `record` walked the ring cursor forward to wherever `now` landed and set
-- `lastBucket` to that index. A sample from before the newest one therefore
-- rewound the cursor and evicted the newest bucket, so the count a caller read
-- back was one short and the min/max were those of the wrong sample. A clock
-- that goes backwards -- an NTP correction, a caller mixing seconds and
-- milliseconds -- produced a window that silently under-counts forever after.
do
    local w = CisWindow.newStats(60, 1)
    CisWindow.record(w, 'k', 1, 100)
    CisWindow.record(w, 'k', 2, 50)
    local r = CisWindow.read(w, 'k', 100)
    expect(r ~= nil and r.count == 2,
        ('an earlier sample is merged rather than evicting the newest (count=%s)')
            :format(tostring(r and r.count)))
    expect(r and r.sum == 3, 'both samples contribute to the sum')
    expect(r and r.min == 1 and r.max == 2, 'the extremes cover both samples')

    -- The forward case must still work, which is the property the rewind fix
    -- could plausibly have broken.
    local f = CisWindow.newStats(60, 1)
    for _, t in ipairs({ 10, 11, 12 }) do CisWindow.record(f, 'k', t, t) end
    local rf = CisWindow.read(f, 'k', 12.5)
    expect(rf and rf.count == 3, 'forward recording is unaffected')
end

-- the bucket clamp was documented and missing.
--
-- The header says bucketSec is "clamped to at most windowSec and to at least
-- 1/1000 of it", and the code clamped only the upper bound. `newStats(60, 1e-6)`
-- therefore built a ring of 60 million slots: a table allocation large enough
-- to fail, from a call whose arguments look reasonable.
do
    local s = CisWindow.newStats(60, 1e-6)
    expect(s.bucketCount <= 1000,
        ('an absurd bucket width is clamped (bucketCount=%s)')
            :format(tostring(s.bucketCount)))
    expect(s.bucketSec >= 60 / 1000, 'the clamp is at window/1000')
    local ordinary = CisWindow.newStats(60, 5)
    expect(ordinary.bucketCount == 12, 'an ordinary bucket width is untouched')
end

-- `seen(d, key, nil)` incremented size and stored nothing.
--
-- `now - last` on a nil `now` raises inside arithmetic in some paths and
-- compares nil in others; the one that stored a nil and bumped `size` left the
-- dedupe window claiming a key it had no timestamp for, so `size` grew on every
-- call and nothing ever expired.
do
    local d = CisWindow.newDedupe(1.0)
    CisWindow.seen(d, 'k', 0)
    local before = d.size
    local ok = pcall(function() return CisWindow.seen(d, 'j', nil) end)
    expect(ok, 'seen() does not raise on a nil now')
    expect(d.size == before, 'a rejected now does not grow the window')
end

-- ================================================================ CisPending
-- a throwing `onExpire` aborted the sweep.
--
-- `sweep` iterated `store.items` and called `onExpire` from inside the loop,
-- uncaught. One consumer whose expire handler raised -- which is exactly what
-- happens when the handler logs and the logger is gone -- left every OTHER
-- expired key in the store for ever, and every future sweep to raise at the
-- same key. The store leaked, one key at a time, and nothing said so.
do
    local store = CisPending.new()
    local first = CisPending.alloc(store, { n = 1 }, 10)
    CisPending.alloc(store, { n = 2 }, 10)
    CisPending.alloc(store, { n = 3 }, 10)
    local reported = {}
    local ok = pcall(CisPending.sweep, store, 20, function(key)
        reported[#reported + 1] = key
        if key == first then error('the logger is gone') end
    end)
    expect(ok, 'a throwing onExpire does not escape the sweep')
    expect(CisPending.count(store) == 0,
        ('every expired key is still removed (left=%d)')
            :format(CisPending.count(store)))
    expect(#reported == 3,
        ('every expired key is still reported (reported=%d)'):format(#reported))
    expect(CisPending.peek(store, first) == nil, 'peek confirms the first key is gone')
end

-- CisRealStop: a client stop counts only when the engine fired it (no script
-- below the handler) or the resource named itself; on the server every stop
-- counts, because txAdmin's monitor runs `restart` from its own runtime.
do
    local savedDup, savedInv = rawget(_ENV, 'IsDuplicityVersion'), rawget(_ENV, 'GetInvokingResource')
    local by
    GetInvokingResource = function() return by end
    IsDuplicityVersion = function() return false end
    by = nil
    expect(CisRealStop('res_a') == true, 'client: the engine\'s own stop counts')
    by = 'evil_res'
    expect(CisRealStop('res_a') == false, 'client: a stop another script TriggerEvent\'d does not')
    by = 'res_a'
    expect(CisRealStop('res_a') == true, 'client: a resource naming itself counts')
    IsDuplicityVersion = function() return true end
    by = 'monitor'
    expect(CisRealStop('res_a') == true, 'server: a restart run from txAdmin\'s runtime counts')
    rawset(_ENV, 'IsDuplicityVersion', savedDup)
    rawset(_ENV, 'GetInvokingResource', savedInv)
end

-- CisConfigUtil.digest is computed by the server and checked by the client, so
-- both runtimes must produce the same digits: pinned to values computed apart
-- from Lua (IEEE doubles), which this suite checks under fengari and Lua 5.4.
do
    expect(CisConfigUtil.digest('cis_keys') == '2130725535.3064527974',
        ('digest: a known name gives its known digest (%s)'):format(CisConfigUtil.digest('cis_keys')))
    expect(CisConfigUtil.digest('cis_ui') == '4135222049.2229876390', 'digest: and another')
    expect(CisConfigUtil.digest('') == '5381.0', 'digest: the empty name is the seed')
    expect(CisConfigUtil.digest('cis_keys') ~= CisConfigUtil.digest('cis_keyt'),
        'digest: one byte apart is a different digest')
end

-- KEYS ARE TOKENS. The key is the only thing that matches a reply to its call, so
-- a key a script can predict is a reply a script can forge: with 1, 2, 3...
-- `for k = 1, 500 do TriggerEvent('cis_libs:cb:res', k, true, fake) end`
-- answered every in-flight await on the client.
do
    local store = CisPending.new()
    local seen, keys = {}, {}
    for i = 1, 200 do
        local k = CisPending.alloc(store, { n = i }, 100)
        keys[i] = k
        expect(not seen[k], ('key %d is unique (%s)'):format(i, tostring(k)))
        seen[k] = true
    end
    expect(type(keys[1]) == 'string' and #keys[1] >= 16,
        ('a key carries random bits, not just a count (%s)'):format(tostring(keys[1])))
    local guessed = 0
    for k = 1, 500 do
        if CisPending.peek(store, k) then guessed = guessed + 1 end
    end
    expect(guessed == 0, ('counting from 1 finds no pending entry (found %d)'):format(guessed))
    local a = CisPending.alloc(CisPending.new(), {}, 100)
    local b = CisPending.alloc(CisPending.new(), {}, 100)
    expect(a ~= b, 'two stores at the same count still hand out different keys')
end

-- peek does not consume, which is the property that lets a caller ask "is this
-- mine?" before destroying it.
do
    local store = CisPending.new()
    local k = CisPending.alloc(store, { n = 9 }, 100)
    local item = CisPending.peek(store, k)
    expect(item ~= nil and item.payload.n == 9, 'peek reads an entry without consuming it')
    expect(CisPending.count(store) == 1, 'peek leaves the entry in the store')
    expect(CisPending.take(store, k) ~= nil, 'take still gets it afterwards')
    expect(CisPending.peek(store, k) == nil, 'and the entry is gone once taken')
    expect(CisPending.peek(store, 9999) == nil, 'peek of an unknown key is nil, not an error')
end

-- ================================================================ CisRegistry
-- `call(slot)` with a nil or non-string method raised.
--
-- A caller that builds the method name at runtime -- `call('database',
-- queryName)` where the name came from a config -- hit `method:sub(1, 1)` on a
-- nil and the exception surfaced in whatever thread called it. A refusal with a
-- reason is the contract everywhere else in this file.
do
    local threw = not pcall(function() return CisRegistry.call('database') end)
    expect(not threw, 'call() with no method does not raise')
    local ok, reason = CisRegistry.call('database')
    expect(ok == false, 'call() with no method refuses')
    expect(type(reason) == 'string' and reason:find('method', 1, true) ~= nil,
        'and the refusal says a method name is required: ' .. tostring(reason))
    local ok2, reason2 = CisRegistry.call('database', 42)
    expect(ok2 == false and type(reason2) == 'string',
        'a non-string method name refuses rather than raising')
end

-- ================================================================== CisOwned
-- THE OWNERSHIP LEDGER, which is the whole of the consumer-stop fix.
--
-- cis_libs runs in its OWN VM, so a zone, a target, a synced entity and a
-- remote callback outlive the resource that asked for them -- silently, and
-- until the process restarts.
--
-- The ledger has to be exactly right about the case that makes it awkward: a
-- resource that RESTARTS. It re-runs its own registration, and a naive ledger
-- would still attribute its names to the dead instance -- so the sweep for that
-- dead owner would then delete a live record.
do
    local L = CisOwned.new()

    CisOwned.track(L, 'res_a', 'zone', 'shop')
    CisOwned.track(L, 'res_a', 'zone', 'bank')
    CisOwned.track(L, 'res_b', 'zone', 'depot')

    expect(CisOwned.count(L) == 3, 'owned: every tracked record is counted')
    expect(CisOwned.ownerOf(L, 'zone', 'shop') == 'res_a',
        'owned: the owner of a record is reported')
    expect(CisOwned.ownerOf(L, 'zone', 'nope') == nil,
        'owned: an untracked record has no owner')
    expect(CisOwned.isHeldBy(L, 'zone', 'shop', 'res_a'), 'owned: isHeldBy agrees')
    expect(not CisOwned.isHeldBy(L, 'zone', 'shop', 'res_b'),
        'owned: and disagrees for the wrong owner')

    -- A STOP releases exactly what that resource held. res_b's record must
    -- survive: a sweep that took everything would be a different bug, and one
    -- that took nothing would be this one.
    local freed = CisOwned.release(L, 'res_a')
    expect(#freed == 2, ('owned: release returns exactly what the owner held (%d)'):format(#freed))
    local kinds = {}
    for _, rec in ipairs(freed) do kinds[rec.kind .. ':' .. tostring(rec.id)] = true end
    expect(kinds['zone:shop'] and kinds['zone:bank'],
        'owned: and names each of them, kind and id')
    expect(CisOwned.ownerOf(L, 'zone', 'depot') == 'res_b',
        "owned: another resource's record SURVIVES the sweep")

    -- Release is sorted. A sweep whose order changes between two identical
    -- stops is a sweep whose bugs are unreproducible.
    local again = {}
    CisOwned.track(L, 'res_c', 'zone', 'zebra')
    CisOwned.track(L, 'res_c', 'zone', 'alpha')
    for _, rec in ipairs(CisOwned.release(L, 'res_c')) do
        again[#again + 1] = tostring(rec.id)
    end
    expect(again[1] == 'alpha' and again[2] == 'zebra',
        'owned: release is sorted, so a stop is reproducible')

    -- RESTART. The same resource re-tracks its own names.
    local R = CisOwned.new()
    CisOwned.track(R, 'res_a', 'zone', 'shop')
    CisOwned.track(R, 'res_a', 'zone', 'shop')
    expect(CisOwned.count(R) == 1, 'owned: tracking the same record twice is one record')
    expect(CisOwned.ownerOf(R, 'zone', 'shop') == 'res_a',
        'owned: and the owner is unchanged by a re-track')

    -- ...and a name HANDED OVER to another resource moves, rather than being
    -- owned by both. Without the move, stopping the first resource would delete
    -- a record the second one is now using.
    CisOwned.track(R, 'res_b', 'zone', 'shop')
    expect(CisOwned.ownerOf(R, 'zone', 'shop') == 'res_b',
        'owned: a re-track by a DIFFERENT owner is a move, not a second claim')
    local moved = CisOwned.release(R, 'res_a')
    expect(#moved == 0, 'owned: and the previous owner holds nothing afterwards')
    expect(CisOwned.ownerOf(R, 'zone', 'shop') == 'res_b',
        'owned: so stopping the old owner does not take the live record')

    -- forget() is the ordinary path: a record removed by its owner, with nobody
    -- stopping, still stops being owed.
    CisOwned.forget(R, 'zone', 'shop')
    expect(CisOwned.ownerOf(R, 'zone', 'shop') == nil, 'owned: forget drops a record')
    expect(CisOwned.count(R) == 0, 'owned: and the ledger is empty again')
    expect(CisOwned.forget(R, 'zone', 'shop') == false,
        'owned: forgetting a record that is not there reports false')

    -- Refusals, not silent acceptance: a record with no id is not a record.
    expect(CisOwned.track(R, 'res_a', 'zone', nil) == false,
        'owned: tracking a nil id is refused')
    expect(CisOwned.track(R, 'res_a', nil, 'x') == false,
        'owned: tracking with no kind is refused')
    expect(#CisOwned.release(R, 'nobody') == 0,
        'owned: releasing a resource that owns nothing is an empty list')

    -- clear() is what cis_libs's own stop uses.
    CisOwned.track(R, 'res_a', 'zone', 'x')
    CisOwned.clear(R)
    expect(CisOwned.count(R) == 0, 'owned: clear empties the ledger')
    expect(#CisOwned.release(R, 'res_a') == 0,
        'owned: and nothing is owed afterwards')
end

-- ==================================== Phase 5 T3 · the untested surface
--
-- Every function below was named in the audit's coverage-gaps list and had no
-- test referencing it at all. Each block states what the function PROMISES,
-- because an assertion that only checks a return value is how the extras
-- test passed against a regression.
do
    -- ---------------------------------------------------------- pending.peek
    -- The difference between take and peek is OWNERSHIP: take consumes the
    -- key, peek leaves it. A consumer that peeks twice must get the same answer
    -- twice -- that is the entire reason the function exists.
    local store = CisPending.new()
    local key = CisPending.alloc(store, { v = 1 }, 100)
    local peeked = CisPending.peek(store, key)
    local again = CisPending.peek(store, key)
    expect(peeked ~= nil and again ~= nil, 'pending.peek returns the payload')
    expect(peeked == again, 'and returns the SAME one on a second peek -- it does not consume')
    expect(CisPending.count(store) == 1, 'and the key is still held after two peeks')
    expect(CisPending.take(store, key) ~= nil, 'take after peek still gets the payload')
    expect(CisPending.peek(store, key) == nil, 'and now peek is empty, because take consumed it')
    expect(CisPending.peek(store, 99) == nil, 'peek on an unknown key is nil, not a raise')

    -- ---------------------------------------------------------------- heap
    do
        local h = CisHeap.new(function(a, b) return a < b end)
        expect(CisHeap.isEmpty(h), 'a new heap is empty')
        for _, v in ipairs({ 5, 1, 4, 2, 3 }) do CisHeap.push(h, v) end
        expect(CisHeap.size(h) == 5, 'five pushes are five elements')
        expect(CisHeap.peek(h) == 1, 'peek returns the minimum without removing it')
        expect(CisHeap.size(h) == 5, 'and peek did not consume')
        expect(CisHeap.pop(h) == 1 and CisHeap.pop(h) == 2, 'pop returns cheapest first')
        expect(CisHeap.replaceTop(h, 99) == 4, 'replaceTop returns the NEW top after sifting')
        expect(CisHeap.peek(h) == 4, 'and the new top took its place')
        expect(CisHeap.pop(h) == 4 and CisHeap.pop(h) == 5 and CisHeap.pop(h) == 99 and CisHeap.isEmpty(h),
            'and the heap drains in order -- 99 replaced the ROOT, so it is now the largest')

        -- build() is the bulk form a caller reaching for a priority queue
        -- actually uses, and it was untested.
        local built = CisHeap.build({ 3, 1, 2 }, function(a, b) return a < b end)
        expect(CisHeap.size(built) == 3, 'build() makes a heap of the whole list')
        expect(CisHeap.peek(built) == 1, 'build() HEAPIFIES rather than just wrapping the list')

        -- The queue: priority first, and TIES in insertion order. The tie rule
        -- is the whole reason a queue exists over a plain heap, and it is not
        -- obvious from the name.
        local q = CisHeap.newQueue()
        CisHeap.enqueue(q, 'low', 10)
        CisHeap.enqueue(q, 'high-a', 1)
        CisHeap.enqueue(q, 'high-b', 1)
        expect(CisHeap.peekQueue(q) == 'high-a', 'peekQueue sees the lowest priority')
        expect(CisHeap.dequeue(q) == 'high-a', 'dequeue returns it')
        expect(CisHeap.dequeue(q) == 'high-b',
            'and an equal priority dequeues FIRST IN, not in reverse')
        expect(CisHeap.dequeue(q) == 'low', 'then the higher priority')
        expect(CisHeap.dequeue(q) == nil, 'an empty queue dequeues nil rather than raising')
    end

    -- ----------------------------------------------------------------- lru
    do
        local lru = CisLRU.new(3)
        CisLRU.put(lru, 'a', 1)
        CisLRU.put(lru, 'b', 2)
        CisLRU.put(lru, 'c', 3)
        expect(CisLRU.peek(lru, 'a') == 1, 'peek reads a value without making it hot')
        expect(CisLRU.keys(lru)[1] == 'c',
            'so the most recently PUT is still first after peeking the oldest')
        expect(CisLRU.get(lru, 'a') == 1, 'get reads it')
        expect(CisLRU.keys(lru)[1] == 'a', 'and get DOES make it hot -- that is the difference')

        expect(CisLRU.popOldest(lru) == 2, 'popOldest evicts the least recently used')
        expect(not CisLRU.has(lru, 'b'), 'and the key is gone')
        expect(CisLRU.count(lru) == 2, 'and the count dropped by one')

        -- Capacity is the whole point of an LRU.
        CisLRU.put(lru, 'd', 4)
        CisLRU.put(lru, 'e', 5)
        expect(CisLRU.count(lru) == 3, 'putting past capacity does not grow the cache')
        expect(not CisLRU.has(lru, 'c') and CisLRU.has(lru, 'a'),
            'and it dropped the LEAST RECENTLY USED -- c, not the a that get() just touched')

        -- removeWhere is the one that takes a predicate.
        local removed = CisLRU.removeWhere(lru, function(_, v) return v >= 4 end)
        expect(removed == 2, 'removeWhere returns how many it removed')
        expect(CisLRU.count(lru) == 1, 'and removed exactly those')

        local seen = 0
        CisLRU.each(lru, function() seen = seen + 1 end)
        expect(seen == CisLRU.count(lru), 'each visits every entry')
        expect(CisLRU.each(lru, 'not a function') == 0,
            'each with a non-function visits nothing rather than raising')
    end

    -- ---------------------------------------------------------------- rate
    do
        -- peek() asks "would this be allowed" WITHOUT spending the budget. If it
        -- consumed, a UI asking before acting would consume the limit itself.
        local r = CisRate.newFixed({ limit = 2, windowSec = 10 })
        expect(CisRate.allow(r, 'k', 0), 'first hit allowed')
        expect(CisRate.allow(r, 'k', 0), 'second hit allowed')
        expect(not CisRate.allow(r, 'k', 0), 'third hit is over the limit')
        expect(CisRate.peek(r, 'k', 0).allowed == false,
            'peek agrees the key is currently blocked')
        expect(CisRate.peek(r, 'other', 0).allowed == true, 'peek on an untouched key is allowed')
        expect(CisRate.peek(r, 'other', 0).remaining == 2,
            'and reports the full remaining budget, which is the reason to ask by peek')
        expect(not CisRate.allow(r, 'k', 0), 'and peek did not refund the limit')

        -- prune() drops idle keys so the map cannot grow without bound.
        local g = CisRate.newFixed({ limit = 5, windowSec = 1 })
        for i = 1, 20 do CisRate.allow(g, 'key' .. i, 0) end
        expect(CisRate.count(g) == 20, 'twenty keys are tracked')
        CisRate.prune(g, 100, 1)
        expect(CisRate.count(g) == 0, 'prune drops keys idle past the window -- here, all of them')

        -- The sliding limiter's FULL WINDOW, which is where lived.
        local s = CisRate.newSliding({ limit = 10, windowSec = 1 })
        local allowed = 0
        for i = 0, 99 do
            if CisRate.allow(s, 'even', i / 100) then allowed = allowed + 1 end
        end
        expect(allowed <= 11,
            ('the sliding limiter allows at most limit+1 across a spread window (allowed=%d)')
                :format(allowed))
        expect(allowed >= 9,
            ('and still allows a real budget rather than a starved one (allowed=%d)'):format(allowed))
    end

    -- -------------------------------------------------------------- window
    do
        local w = CisWindow.newStats(3, 1)
        for t = 10, 12 do CisWindow.record(w, 'k', t, t) end
-- DEFECT FOUND BY THIS BLOCK, PINNED RATHER THAN USED:
        -- CisWindow.isSeen reads d.entries[key] as a NUMBER, but record() stores
        -- an entry TABLE there for a stats window, so it raises
        -- "attempt to compare number with table" instead of answering. It is
        -- written for the dedupe window, where entries[key] IS a number. Not
        -- fixed here: the coverage pass found it, and the fix belongs with
        -- whoever owns the two window types.
        local isSeenOk = pcall(CisWindow.isSeen, w, 'k', 12)
        expect(not isSeenOk,
            'isSeen raises on a stats window rather than answering -- see the note above')

        local varied = CisWindow.newStats(5, 1)
        -- record(stats, key, VALUE, now): the value comes BEFORE the time.
        CisWindow.record(varied, 'k', 5, 10)
        CisWindow.record(varied, 'k', 90, 11)
        CisWindow.record(varied, 'k', 40, 12)
        expect(CisWindow.extreme(varied, 'k', 12, true) == 90, 'extreme(max) is the largest')
        expect(CisWindow.extreme(varied, 'k', 12, false) == 5, 'extreme(min) is the smallest')
        expect(CisWindow.extreme(varied, 'k', 12, false) == 5,
            'and min is not just max with the flag flipped')
        expect(CisWindow.extreme(varied, 'gone', 12, true) == nil,
            'extreme on an unknown key is nil rather than a raise')
    end

    -- ---------------------------------------------------------- util/table
    do
        local T = CisTable
        expect(T.isEmpty({}) == true, 'isEmpty on {} is true')
        expect(T.isEmpty({ a = 1 }) == false, 'isEmpty on a populated table is false')
        expect(T.isEmpty('not a table') == true, 'isEmpty treats a non-table as empty')
        expect(T.isArray({ 1, 2, 3 }) == true, 'isArray on a dense list is true')
        expect(T.isArray({ a = 1 }) == false, 'isArray on a map is false')
        expect(T.isMap({ a = 1 }) == true, 'isMap on a map is true')
        expect(T.isMap({}) == true, 'isMap on {} is true -- {} is not an array')

        local src = { a = 1, nested = { x = 1 } }
        local shallow = T.shallowCopy(src)
        shallow.a = 2
        expect(src.a == 1, 'a shallow copy is independent at the top level')
        expect(shallow.nested == src.nested,
            'but SHARES the nested table, which is what "shallow" means')

        local deep = T.deepCopy(src)
        deep.nested.x = 99
        expect(src.nested.x == 1, 'a deep copy is independent all the way down')
        expect(T.count(src) == 2, 'count is the number of keys')

        -- A cycle is the case that makes a naive deepCopy recurse forever.
        local cyc = {}
        cyc.self = cyc
        local copied = T.deepCopy(cyc)
        expect(copied.self == copied, 'deepCopy resolves a cycle to the copy in progress, not forever')

        expect(T.join({ 'a', 'b', 'c' }, '-') == 'a-b-c', 'join uses the separator')
        expect(T.join({}) == '', 'join of an empty list is an empty string')
    end

    -- ------------------------------------------------------ util/validate
    do
        local V = CisValidate
        local ok, why = V.schema({ name = 'cis', count = 3, tags = { 'a', 'b' } }, {
            name = { type = 'string', required = true },
            count = { type = 'number', required = true, min = 1, max = 10, integer = true },
            tags = { type = 'table', shape = 'array', min = 1 },
        })
        expect(ok == true, ('schema accepts a conforming value (%s)'):format(tostring(why)))

-- schema() returns a LIST of reasons, not one string. Asserting on the
        -- type of the second value is what caught that: a table of errors is
        -- the better shape, and a caller that assumed a string would have been
        -- silently wrong.
        local ok2, why2 = V.schema({ name = 5 }, { name = { type = 'string', required = true } })
        expect(ok2 == false and type(why2) == 'table' and #why2 > 0,
            'schema refuses a wrong type and returns the list of reasons')

        local ok3, why3 = V.schema({}, { name = { type = 'string', required = true } })
        expect(ok3 == false and type(why3) == 'table' and #why3 > 0,
            'schema refuses a MISSING required field, which catches a typo in a config key')

        -- The schema is { field = SPEC }, and a spec is a table carrying
        -- `default`. A bare number in that position is not a spec, so it fills
        -- nothing and says nothing -- the failure mode the comment in
        -- validate.lua calls invisible.
        local filled = V.defaults({ a = 1 }, { a = { default = 0 }, b = { default = 2 } })
        expect(filled.a == 1, 'defaults does not overwrite a value that is already there')
        expect(filled.b == 2, 'and fills one that is absent')
    end

    -- ------------------------------------------------------------ util/json
    do
        local J = CisJson
        -- check() answers nil + a REASON rather than false: the second value is
        -- what tells a caller WHICH half of the codec contract is missing.
        local noCodec, codecWhy = J.check(nil)
        expect(noCodec == nil and type(codecWhy) == 'string', 'check refuses a missing codec, with a reason')
        local halfCodec, halfWhy = J.check({ encode = function() end })
        expect(halfCodec == nil and type(halfWhy) == 'string',
            'check refuses a codec missing decode, and says which half')

        -- A codec TABLE whose halves raise, in the argument order the module
        -- takes: (codec, value). A bare function is not a codec and is refused
        -- by check() before anything is called, so it tests nothing here.
        local hostile = {
            encode = function() error('codec exploded') end,
            decode = function() error('codec exploded') end,
        }
        local okE, encoded, encWhy = pcall(J.encode, hostile, { a = 1 })
        expect(okE and encoded == nil and type(encWhy) == 'string' and encWhy:find('exploded', 1, true),
            'encode turns a raising codec into nil + the codec reason')
        local okD, decoded, decWhy = pcall(J.decode, hostile, '{}')
        expect(okD and decoded == nil and type(decWhy) == 'string' and decWhy:find('exploded', 1, true),
            'decode turns a raising codec into nil + the codec reason')

        local good = J.checkEncodable({ a = 1, b = { c = 2 } })
        expect(good == true, 'a plain structure is encodable')
        local bad, badWhy = J.checkEncodable({ fn = function() end })
        expect(bad == false and type(badWhy) == 'string',
            'a table carrying a function is refused, and the reason says so')
    end
end

-- ============================================ Phase 6 · properties, not examples
--
-- Every block below pins a defect that the example tests above let through.
-- Most compare the module against a REFERENCE written here, over many
-- generated cases, because a single hand-picked example is exactly what the
-- original tests were and exactly what the defects slipped past.

-- A deterministic generator owned by the TEST, so the cases do not depend on
-- the module under test (CisRandom) being right. Park-Miller in doubles, which
-- is exact on fengari's 32-bit integers and on Lua 5.4 alike.
local function testRng(seed)
    local state = math.floor(seed) % 2147483647
    if state <= 0 then state = state + 2147483646 end
    return function()
        state = (state * 16807.0) % 2147483647
        return state / 2147483647
    end
end

-- Load a shipped module FRESH into its own environment, so a test can give it
-- a `type` that knows about FiveM vectors. Both runners inject the source of
-- every manifest file as CIS_TEST_FILES.
local function freshModule(rel, overrides)
    local src = assert(CIS_TEST_FILES and CIS_TEST_FILES[rel], 'no injected source for ' .. rel)
    local env = setmetatable(overrides or {}, { __index = _G })
    local chunk = assert(load(src, '@' .. rel, 't', env))
    return chunk('cis_require')
end

-- Stand-ins for CfxLua's vector2/3/4. `type()` on a real one answers
-- 'vector3', not 'table', and reading a field the vector does not have
-- RAISES -- so a reader that touches .z on a vector2, or [1] on any vector,
-- fails here the way it would in FiveM.
local VECTOR_FIELDS = {
    vector2 = { x = true, y = true },
    vector3 = { x = true, y = true, z = true },
    vector4 = { x = true, y = true, z = true, w = true },
}
local function fakeVector(kind, x, y, z, w)
    local data = { x = x, y = y, z = z, w = w }
    local allowed = VECTOR_FIELDS[kind]
    return setmetatable({}, {
        __vectype = kind,
        __index = function(_, k)
            if allowed[k] then return data[k] end
            error(('invalid %s field %s'):format(kind, tostring(k)), 2)
        end,
        __newindex = function() error('vectors are read-only here', 2) end,
    })
end
local realType = type
local function vectorAwareType(v)
    local mt = getmetatable(v)
    if realType(mt) == 'table' and rawget(mt, '__vectype') then
        return rawget(mt, '__vectype')
    end
    return realType(v)
end

local function angleClose(a, b, tol)
    local d = math.abs((a - b) % 360)
    return d <= tol or 360 - d <= tol
end

-- ---------------------------------------------------- interp: FiveM vectors
do
    local I = freshModule('shared/algo/interp.lua', { type = vectorAwareType })
    local a3, b3 = fakeVector('vector3', 1, 2, 3), fakeVector('vector3', 4, 6, 3)
    near(I.distance3D(a3, b3), 5, 1e-12, 'interp: distance3D reads two vector3s (was 0)')
    near(I.distance2D(fakeVector('vector2', 0, 0), fakeVector('vector2', 3, 4)), 5, 1e-12,
        'interp: distance2D reads two vector2s without touching .z')
    local mid = I.lerpVec3(a3, b3, 0.5)
    expect(mid.x == 2.5 and mid.y == 4 and mid.z == 3, 'interp: lerpVec3 blends vector3s')
    local v4 = I.normalize(fakeVector('vector4', 0, 3, 4, 99))
    near(v4.y, 0.6, 1e-12, 'interp: normalize reads x/y/z of a vector4 and ignores w')
    local moved = I.moveTowardsVec3(fakeVector('vector3', 0, 0, 0), fakeVector('vector3', 10, 0, 0), 2)
    expect(moved.x == 2 and moved.y == 0 and moved.z == 0, 'interp: moveTowardsVec3 moves a vector3')
    local okUd = pcall(I.distance3D, io.stdout, a3)
    expect(okUd, 'interp: a userdata with no .x is a refusal, not a raise')
end

-- ---------------------------------------------- interp: 2D moveTowardsVec3
do
    local I = CisInterp
    local p = I.moveTowardsVec3({ x = 0, y = 0 }, { x = 3, y = 4 }, 1)
    near(p.x, 0.6, 1e-12, 'interp: a 2D point moves toward a 2D target (it used to stay put)')
    near(p.y, 0.8, 1e-12, 'interp: and along the right direction')
    local q = I.moveTowardsVec3({ 0, 0 }, { x = 3, y = 4, z = 12 }, 100)
    expect(q.x == 3 and q.y == 4 and q.z == 12, 'interp: a 2D point takes the 3D target\'s z')
end

-- -------------------------------------------- interp: smoothDamp maxSpeed
do
    local I = CisInterp
    local ok, out, vel = pcall(I.smoothDamp, 0, 10, 0, 0.3, -5, 1 / 60)
    expect(ok and out == 0 and vel == 0,
        ('interp: smoothDamp with a negative maxSpeed holds still rather than raising (%s %s)')
            :format(tostring(out), tostring(vel)))
    local okNan, outNan = pcall(I.smoothDamp, 0, 10, 0, 0.3, 0 / 0, 1 / 60)
    expect(okNan and outNan > 0 and outNan < 10, 'interp: a NaN maxSpeed is "no limit"')
    -- The limit must still bite: a step cannot cover more than maxSpeed * smoothTime.
    local capped = I.smoothDamp(0, 1000, 0, 0.5, 4, 0.1)
    local free = I.smoothDamp(0, 1000, 0, 0.5, nil, 0.1)
    expect(capped < free and capped > 0, 'interp: a positive maxSpeed still limits the step')
end

-- ------------------------------------------------- interp: GTA headings
do
    local I = CisInterp
    near(I.lerpHeading(10, 350, 0.5), 0, 1e-9, 'interp: lerpHeading(10, 350, .5) goes through north')
    near(I.lerpHeading(350, 10, 0.5), 0, 1e-9, 'interp: and the other way round')
    local rng = testRng(9001)
    local bad = {}
    for _ = 1, 400 do
        local a, b, t = rng() * 720 - 360, rng() * 720 - 360, rng()
        local d = I.headingDelta(a, b)
        -- Reference: the shortest signed arc, in [-180, 180).
        local ref = ((b - a) % 360 + 540) % 360 - 180
        if not (d >= -180 and d < 180 and math.abs(d - ref) < 1e-9) then
            bad[#bad + 1] = ('delta(%g,%g)=%g want %g'):format(a, b, d, ref)
        end
        local h = I.lerpHeading(a, b, t)
        if not (h >= 0 and h < 360 and angleClose(h, a + ref * t, 1e-7)) then
            bad[#bad + 1] = ('lerp(%g,%g,%g)=%g'):format(a, b, t, h)
        end
    end
    expect(#bad == 0, 'interp: headingDelta/lerpHeading take the shortest arc for 400 random pairs: '
        .. table.concat(bad, '; ', 1, math.min(#bad, 3)))

    -- GetEntityForwardVector at heading h is (-sin h, cos h): 0 faces +Y, 90 faces -X.
    local fx, fy = I.headingToVector(0)
    expect(math.abs(fx) < 1e-12 and math.abs(fy - 1) < 1e-12, 'interp: heading 0 faces +Y')
    fx, fy = I.headingToVector(90)
    expect(math.abs(fx + 1) < 1e-12 and math.abs(fy) < 1e-12, 'interp: heading 90 faces -X, as in GTA')
    fx, fy = I.headingToVector(270)
    expect(math.abs(fx - 1) < 1e-12 and math.abs(fy) < 1e-12, 'interp: heading 270 faces +X')
    near(I.vectorToHeading(-1, 0), 90, 1e-9, 'interp: vectorToHeading(-1, 0) is 90')
    near(I.vectorToHeading(0, -1), 180, 1e-9, 'interp: vectorToHeading(0, -1) is 180')
    local trip = {}
    for _ = 1, 400 do
        local h = rng() * 1080 - 360
        local x, y = I.headingToVector(h)
        local back = I.vectorToHeading(x * 7, y * 7)
        if not (angleClose(back, h, 1e-7) and back >= 0 and back < 360) then
            trip[#trip + 1] = ('%g -> %g'):format(h, back)
        end
        if math.abs(x + math.sin(math.rad(h))) > 1e-12 or math.abs(y - math.cos(math.rad(h))) > 1e-12 then
            trip[#trip + 1] = ('forward(%g)'):format(h)
        end
    end
    expect(#trip == 0, 'interp: heading -> vector -> heading round-trips for 400 headings: '
        .. table.concat(trip, '; ', 1, math.min(#trip, 3)))
end

-- -------------------------------- curve: centripetal against Barry-Goldman
do
    -- The reference: Barry and Goldman's pyramid, which IS the definition of a
    -- non-uniform Catmull-Rom segment, evaluated at the knot that matches u.
    local function dist3(a, b)
        return math.sqrt((b[1] - a[1]) ^ 2 + (b[2] - a[2]) ^ 2 + (b[3] - a[3]) ^ 2)
    end
    local function barryGoldman(P0, P1, P2, P3, alpha, u)
        local t0 = 0
        local t1 = t0 + dist3(P0, P1) ^ alpha
        local t2 = t1 + dist3(P1, P2) ^ alpha
        local t3 = t2 + dist3(P2, P3) ^ alpha
        local t = t1 + (t2 - t1) * u
        local function L(A, B, ta, tb)
            local o = {}
            for i = 1, 3 do o[i] = (tb - t) / (tb - ta) * A[i] + (t - ta) / (tb - ta) * B[i] end
            return o
        end
        local A1, A2, A3 = L(P0, P1, t0, t1), L(P1, P2, t1, t2), L(P2, P3, t2, t3)
        local B1, B2 = L(A1, A2, t0, t2), L(A2, A3, t1, t3)
        return L(B1, B2, t1, t2)
    end
    local function asPoint(P) return { x = P[1], y = P[2], z = P[3] } end

    local C = CisCurve
    local rng = testRng(4242)
    local worst = { 0, 0, 0, 0 }
    local alphas = { 0, 0.25, 0.5, 1 }
    for _ = 1, 150 do
        local P = {}
        for i = 1, 4 do
            P[i] = { rng() * 100 - 50, rng() * 100 - 50, rng() * 20 - 10 }
        end
        for ai, alpha in ipairs(alphas) do
            local u = rng()
            local ref = barryGoldman(P[1], P[2], P[3], P[4], alpha, u)
            local x, y, z = C.catmullRom(asPoint(P[1]), asPoint(P[2]), asPoint(P[3]), asPoint(P[4]), u, alpha)
            local err = math.max(math.abs(x - ref[1]), math.abs(y - ref[2]), math.abs(z - ref[3]))
            if err > worst[ai] then worst[ai] = err end
        end
    end
    for ai, alpha in ipairs(alphas) do
        expect(worst[ai] < 1e-7, ('curve: catmullRom matches Barry-Goldman at alpha=%g over 150 random'
            .. ' segments (worst error %g)'):format(alpha, worst[ai]))
    end

    -- The path stores its own tangents; the same reference checks them, on the
    -- interior segments of an open path and on every segment of a closed one.
    local pts = {}
    for i = 1, 7 do pts[i] = { rng() * 80, rng() * 80, rng() * 8 } end
    local tablePts = {}
    for i = 1, #pts do tablePts[i] = asPoint(pts[i]) end
    local pathWorst = 0
    for _, closed in ipairs({ false, true }) do
        local path = C.newPath(tablePts, { alpha = 0.5, closed = closed })
        local n = #pts
        local first, last = 2, n - 2
        if closed then first, last = 1, n end
        for s = first, last do
            local function at(i) return pts[((i - 1) % n) + 1] end
            for _, u in ipairs({ 0.1, 0.37, 0.5, 0.81 }) do
                local ref = barryGoldman(at(s - 1), at(s), at(s + 1), at(s + 2), 0.5, u)
                local x, y, z = C.hermite(asPoint(at(s)), asPoint(at(s + 1)),
                    { x = path.m1x[s], y = path.m1y[s], z = path.m1z[s] },
                    { x = path.m2x[s], y = path.m2y[s], z = path.m2z[s] }, u)
                pathWorst = math.max(pathWorst, math.abs(x - ref[1]), math.abs(y - ref[2]), math.abs(z - ref[3]))
            end
        end
    end
    expect(pathWorst < 1e-7, ('curve: newPath tangents match Barry-Goldman, open and closed (worst %g)')
        :format(pathWorst))
end

-- --------------------------------------------------- curve: FiveM vectors
do
    local C = freshModule('shared/algo/curve.lua', { type = vectorAwareType })
    local asTables = { { x = 0, y = 0, z = 1 }, { x = 10, y = 0, z = 1 }, { x = 10, y = 10, z = 2 } }
    local asVectors = {}
    for i, p in ipairs(asTables) do asVectors[i] = fakeVector('vector3', p.x, p.y, p.z) end
    local pt = C.newPath(asTables)
    local pv = C.newPath(asVectors)
    expect(C.count(pv) == 3, 'curve: newPath keeps vector3 control points (it dropped every one)')
    near(C.length(pv), C.length(pt), 1e-9, 'curve: a vector3 path has the same length as the table path')
    near(C.lengthOf({ fakeVector('vector2', 0, 0), fakeVector('vector2', 3, 4) }), 5, 1e-12,
        'curve: lengthOf reads vector2s')
    local x = C.catmullRom(asVectors[1], asVectors[1], asVectors[2], asVectors[3], 0.5)
    expect(x > 0 and x < 10, 'curve: catmullRom reads vector3 control points (it answered 0)')
end

-- --------------------------------------------------- lru: each is re-entrant
do
    local L = CisLRU
    local function build(n)
        local c = L.new(100)
        for i = 1, n do L.put(c, 'k' .. i, i) end
        return c
    end
    local c = build(5)
    local visits, seen, runaway = 0, {}, false
    local ok, err = pcall(L.each, c, function(k)
        visits = visits + 1
        if visits > 50 then runaway = true error('runaway') end
        seen[k] = (seen[k] or 0) + 1
        L.get(c, k)                       -- relinks k to the front
    end)
    local once = true
    for i = 1, 5 do if seen['k' .. i] ~= 1 then once = false end end
    expect(ok and not runaway and once and visits == 5,
        ('lru: each visits every key once when the callback calls get (%s, %d visits)')
            :format(tostring(err), visits))

    c = build(5)
    local order = L.keys(c)
    local got = {}
    ok, err = pcall(L.each, c, function(k)
        got[#got + 1] = k
        -- Remove the entry being visited AND whatever comes next in the
        -- original order. Removing the current node unlinks it, so a walk that
        -- reads node.next afterwards reads nil.
        L.remove(c, k)
        for i = 1, #order - 1 do
            if order[i] == k then L.remove(c, order[i + 1]) end
        end
    end)
    expect(ok and #got == 3 and got[1] == order[1] and got[2] == order[3] and got[3] == order[5]
        and L.count(c) == 0,
        ('lru: each survives the callback removing the current and next entries (%s)'):format(tostring(err)))

    c = build(4)
    local n = 0
    ok = pcall(L.each, c, function() n = n + 1 L.clear(c) end)
    expect(ok and n == 1, 'lru: each stops visiting once the callback clears the cache')

    c = build(3)
    ok = pcall(L.each, c, function(k) L.put(c, k .. '_new', 0) end)
    expect(ok and L.count(c) == 6, 'lru: an entry added during each is not visited, and nothing breaks')
end

-- --------------------------------------------------- rate: sliding and clock
do
    local R = CisRate
    local r = R.newSliding({ limit = 3, windowSec = 1, subdivisions = 4 })
    expect(R.allow(r, 'k', 0, 10) == false, 'rate: a first call over the limit is refused')
    -- One slice later (a slice is 0.25 s), so the cursor steps by one rather
    -- than wiping the ring -- the path that did arithmetic on the nil cursor.
    local ok, res = pcall(R.allow, r, 'k', 0.3)
    expect(ok and res == true,
        ('rate: a sliding key whose first call was refused rolls forward without raising (%s)')
            :format(tostring(res)))

    -- nil `now` reads the game timer, in seconds, and the fixed window ROLLS.
    local savedTimer = GetGameTimer
    local ms = 100000
    GetGameTimer = function() return ms end
    local f = R.newFixed({ limit = 2, windowSec = 1 })
    local a, b, c = R.allow(f, 'p'), R.allow(f, 'p'), R.allow(f, 'p')
    ms = ms + 1000
    local d = R.allow(f, 'p')
    GetGameTimer = savedTimer
    expect(a and b and not c and d,
        'rate: with now omitted the default clock is used and the window rolls (it was pinned at 0)')

    local okNaN = pcall(R.allow, f, 'p', 0 / 0)
    expect(not okNaN, 'rate: a NaN clock raises rather than pinning the window at 0')
    local okStr = pcall(R.allow, f, 'p', '5')
    expect(not okStr, 'rate: a string clock raises')
    local okPeek = pcall(R.peek, f, 'p', {})
    expect(not okPeek, 'rate: peek validates the clock the same way')
end

-- -------------------------------------------- random: inward integer bounds
do
    local Rn = CisRandom
    local sources = {
        { 'math.random', nil },
        { 'a function', testRng(77) },
        { 'a generator', Rn.newGenerator(77) },
    }
    for _, src in ipairs(sources) do
        local outside, hit2, hit3 = 0, false, false
        for _ = 1, 400 do
            local v = Rn.integer(1.5, 3.5, src[2])
            if v == 2 then hit2 = true elseif v == 3 then hit3 = true else outside = outside + 1 end
        end
        expect(outside == 0 and hit2 and hit3,
            ('random: integer(1.5, 3.5) draws only 2 and 3 from %s (%d outside)'):format(src[1], outside))
    end
    local none, why = Rn.integer(1.2, 1.8)
    expect(none == nil and type(why) == 'string', 'random: a range holding no integer is a refusal')
    local g = Rn.newGenerator(5)
    local outside = 0
    for _ = 1, 200 do
        local v = g:int(-2.5, 0.5)
        if v ~= -2 and v ~= -1 and v ~= 0 then outside = outside + 1 end
    end
    expect(outside == 0, 'random: generator:int rounds a fractional range inward too')

    local list = { 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h' }
    local wrong = {}
    for _, k in ipairs({ 0, 0.5, 1, 1.9, 2.5, 7.2, 8, 9.5 }) do
        local want = math.min(math.floor(k), #list)
        local s = Rn.sample(list, k, testRng(k * 100 + 1))
        local count, distinct, valid = 0, {}, true
        for key, v in pairs(s) do
            count = count + 1
            if type(key) ~= 'number' or key % 1 ~= 0 or key < 1 or key > want then valid = false end
            if distinct[v] then valid = false end
            distinct[v] = true
        end
        if count ~= want or #s ~= want or not valid then
            wrong[#wrong + 1] = ('k=%g gave %d'):format(k, count)
        end
    end
    expect(#wrong == 0, 'random: sample returns floor(k) distinct elements: ' .. table.concat(wrong, ', '))
end

-- ----------------------------------------------- heap: refusals and a model
do
    local H = CisHeap
    local h = H.new()
    H.push(h, 3)
    local okNil, size, why = pcall(H.push, h, nil)
    local okNext = pcall(H.push, h, 1)
    expect(okNil and size == nil and type(why) == 'string' and okNext and H.size(h) == 2,
        'heap: push(nil) is refused, the size is unchanged, and the heap still works')
    local okNan, nanSize = pcall(H.push, h, 0 / 0)
    expect(okNan and nanSize == nil and H.size(h) == 2, 'heap: NaN is refused under the default ordering')

    -- Model check: random pushes and pops against a sorted reference list.
    local rng = testRng(31337)
    local ref, mismatch = {}, nil
    h = H.new()
    for step = 1, 600 do
        if rng() < 0.6 or #ref == 0 then
            local v = math.floor(rng() * 50)
            H.push(h, v)
            ref[#ref + 1] = v
            table.sort(ref)
        else
            local got = H.pop(h)
            local want = table.remove(ref, 1)
            if got ~= want then
                mismatch = ('step %d popped %s, want %s'):format(step, tostring(got), tostring(want))
                break
            end
        end
    end
    expect(mismatch == nil and H.size(h) == #ref,
        'heap: 600 random push/pop steps agree with a sorted reference: ' .. tostring(mismatch))
end

-- --------------------------------------------- window: sub-second, negatives
do
    local W = CisWindow
    local d = W.newDedupe(0.25)
    expect(d.windowSec == 0.25, 'window: a sub-second dedupe window is kept (it was raised to 1s)')
    expect(W.seen(d, 'k', 10.0) == true and W.seen(d, 'k', 10.1) == false and W.seen(d, 'k', 10.3) == true,
        'window: and it behaves as a 250 ms window')

    -- Shifting every timestamp by a whole number of buckets cannot change any
    -- answer. Negative timestamps used to collide with the -1 "no data yet"
    -- sentinel and re-initialise the key on every record without clearing it.
    local function run(offset)
        local rng = testRng(2718)
        local st = W.newStats(10, 1)
        local t = 0
        local answers = {}
        for i = 1, 120 do
            t = t + rng() * 3
            W.record(st, 'k', i, t + offset)
            local r = W.read(st, 'k', t + offset)
            answers[#answers + 1] = r and (r.count .. ':' .. r.sum .. ':' .. r.min .. ':' .. r.max) or 'nil'
        end
        return table.concat(answers, ' ')
    end
    expect(run(0) == run(-100000), 'window: stats answer identically for timestamps shifted below zero')
    local st = W.newStats(10, 1)
    W.record(st, 'k', 1, -30)
    W.record(st, 'k', 1, -5)
    expect(W.samples(st, 'k', -5) == 1, 'window: a sample 25 s older than a negative now has expired')
end

-- -------------------------------------- sparse: a soft clear lets go of values
do
    local Sp = CisSparse
    local set = Sp.new()
    local held = {}
    Sp.add(set, held)
    Sp.add(set, 'str')
    Sp.clear(set)
    local stillInDense = false
    for _, v in pairs(set.dense) do if v == held then stillInDense = true end end
    expect(not stillInDense, 'sparse: a soft clear drops the dense references')
    expect(not Sp.has(set, held) and Sp.count(set) == 0, 'sparse: and the value is gone from the set')
    expect(Sp.add(set, held) == true and Sp.has(set, held), 'sparse: and it can be added again')

    -- Real collection, where the interpreter has weak tables (fengari does not).
    local probe = setmetatable({}, { __mode = 'k' })
    probe[{}] = true
    local hasGc = pcall(collectgarbage) and pcall(collectgarbage)
    if hasGc and next(probe) == nil then
        local s2 = Sp.new()
        local watch = setmetatable({}, { __mode = 'k' })
        do
            local obj = {}
            watch[obj] = true
            Sp.add(s2, obj)
            Sp.add(s2, 'x')
        end
        Sp.clear(s2)
        collectgarbage() collectgarbage()
        expect(next(watch) == nil, 'sparse: after a soft clear the old member is garbage-collectable')
        local s3 = Sp.new()
        local keep = setmetatable({}, { __mode = 'k' })
        do
            local obj = {}
            keep[obj] = true
            Sp.add(s3, obj)
        end
        collectgarbage() collectgarbage()
        expect(next(keep) ~= nil and Sp.count(s3) == 1, 'sparse: but a LIVE member is never collected')
    end
end

-- ------------------------------------- sparse: each survives its own visitor
do
    local Sp = CisSparse
    -- each walked the live dense array: a visitor that removed the current value
    -- moved the last one into the hole, so later values were skipped and the tail
    -- was handed nil. The doc promises every value present when the walk started.
    local set = Sp.new()
    for i = 1, 5 do Sp.add(set, 'v' .. i) end
    local seen = {}
    local n = Sp.each(set, function(v)
        seen[#seen + 1] = tostring(v)
        Sp.remove(set, v)
    end)
    expect(n == 5 and table.concat(seen, ',') == 'v1,v2,v3,v4,v5' and Sp.count(set) == 0,
        'sparse: each visits every value present at the start although the visitor removes them: ' .. table.concat(seen, ','))

    -- add(NaN) raised on the slot write after size had already grown.
    local s2 = Sp.new()
    Sp.add(s2, 'a')
    local ok, added = pcall(Sp.add, s2, 0 / 0)
    expect(ok and added == false and Sp.count(s2) == 1 and #Sp.toArray(s2) == 1 and not Sp.has(s2, 0 / 0),
        'sparse: add(NaN) is refused with false and leaves the set as it was')
    expect(Sp.add(s2, 'b') == true and Sp.count(s2) == 2 and Sp.at(s2, 2) == 'b',
        'sparse: and the set still takes values after the refused NaN')
end

-- ------------------------------- validate: a field spec keeps the options it names
do
    local V = CisValidate
    -- field() built its string options by hand and left nonEmpty out; the table
    -- branch passed nothing on, so min, max, of and nonEmpty did nothing.
    -- `required` still means "not nil": an empty string is for nonEmpty to refuse.
    expect(not V.field('', { type = 'string', nonEmpty = true }, 'name'), 'validate: a string field honours nonEmpty')
    expect(V.field('', { type = 'string', required = true }, 'name') == true, 'validate: required alone is still only "not nil"')
    expect(V.field('x', { type = 'string', nonEmpty = true }, 'name') == true, 'validate: and a non-empty string passes nonEmpty')
    expect(not V.field({}, { type = 'table', nonEmpty = true }, 'cfg'), 'validate: a table field honours nonEmpty')
    expect(not V.field({ 1, 2, 3 }, { type = 'table', max = 2 }, 'cfg') and not V.field({ 1 }, { type = 'table', min = 2 }, 'cfg')
        and V.field({ 1, 2 }, { type = 'table', min = 2, max = 2 }, 'cfg') == true, 'validate: a table field honours min and max entries')
    local okOf, whyOf = V.field({ a = 1, b = 'x' }, { type = 'table', of = { type = 'number' } }, 'cfg')
    expect(okOf == false and type(whyOf) == 'string' and whyOf:find('cfg[b]', 1, true) ~= nil,
        'validate: a table field checks every entry against of, naming the key: ' .. tostring(whyOf))
    expect(V.field({ a = 1, b = 2 }, { type = 'table', of = { type = 'number' } }, 'cfg') == true, 'validate: and a table of valid entries passes')
    expect(not V.field({}, { type = 'array', nonEmpty = true }, 'list') and not V.field({}, { type = 'map', nonEmpty = true }, 'list')
        and V.field({ 1 }, { type = 'array', nonEmpty = true }, 'list') == true, 'validate: an array or map field honours nonEmpty')
end

-- ----------------------- table, validate: a deep or cyclic input answers nil, why
do
    local T, V = CisTable, CisValidate
    local function chain(n)
        local root = {}
        local cur = root
        for _ = 1, n do
            local child = {}
            cur.k = child
            cur = child
        end
        return root
    end
    -- deepMerge took opts.maxDepth only for its cycle search, then copied and
    -- recursed through a 300000-level overlay until the stack overflowed.
    local ok, merged, why = pcall(T.deepMerge, {}, chain(300000))
    expect(ok and merged == nil and type(why) == 'string' and why:find('deeper', 1, true) ~= nil,
        'table: deepMerge of a 300000-level overlay answers nil, why instead of raising: ' .. tostring(merged) .. ' ' .. tostring(why))
    ok, merged, why = pcall(T.deepMerge, chain(300000), { a = 1 })
    expect(ok and merged == nil and type(why) == 'string', 'table: and so does a 300000-level base')
    ok, merged, why = pcall(T.deepMerge, chain(100), { a = 1 }, nil, { maxDepth = 10 })
    expect(ok and merged == nil and type(why) == 'string' and why:find('10', 1, true) ~= nil,
        'table: deepMerge honours opts.maxDepth for the nesting too: ' .. tostring(why))
    ok, merged = pcall(T.deepMerge, chain(5), { a = 1 }, nil, { maxDepth = 10 })
    expect(ok and merged ~= nil and merged.a == 1 and merged.k.k.k.k.k ~= nil, 'table: and a tree within maxDepth still merges')

    -- validate.defaults copied its input with a recursion that knew no cycle and no depth.
    local cyc = {}
    cyc.self = cyc
    local okD, filled, whyD = pcall(V.defaults, cyc, { n = { default = 1 } })
    expect(okD and filled == nil and type(whyD) == 'string' and whyD:find('cycle', 1, true) ~= nil,
        'validate: defaults of a cyclic table answers nil, why instead of raising: ' .. tostring(filled) .. ' ' .. tostring(whyD))
    okD, filled, whyD = pcall(V.defaults, chain(300000), {})
    expect(okD and filled == nil and type(whyD) == 'string' and whyD:find('deeper', 1, true) ~= nil,
        'validate: defaults of a 300000-level table answers nil, why: ' .. tostring(filled) .. ' ' .. tostring(whyD))
    okD, filled = pcall(V.defaults, chain(10), { n = { default = 1 } })
    expect(okD and filled ~= nil and filled.n == 1 and filled.k.k.k ~= nil, 'validate: and an ordinary nested table is still filled')
    local shared = { x = 1 }
    okD, filled = pcall(V.defaults, { a = shared, b = shared }, { n = { default = 1 } })
    expect(okD and filled ~= nil and filled.a.x == 1 and filled.b.x == 1, 'validate: a table shared by two keys is not a cycle')
end

-- ------------------------------------------------- id: uuid takes a generator
do
    local Id = CisId
    local _, a = pcall(Id.uuid, CisRandom.newGenerator(11))
    local _, b = pcall(Id.uuid, CisRandom.newGenerator(11))
    expect(type(a) == 'string' and a == b, 'id: uuid accepts a CisRandom generator and is reproducible')
    expect(type(a) == 'string'
        and a:match('^%x%x%x%x%x%x%x%x%-%x%x%x%x%-4%x%x%x%-[89ab]%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$') ~= nil,
        'id: and the result is a version-4, variant-1 UUID: ' .. tostring(a))
    local none, why = Id.uuid('nope')
    expect(none == nil and type(why) == 'string', 'id: a non-generator is a refusal, not a raise')
    expect(#Id.short() == Id.LENGTH and Id.LENGTH * 5 == 60, 'id: LENGTH is 12 symbols, 60 bits')
end

-- Structural equality, for round trips and reference comparisons.
local function deepEqual(a, b)
    if a == b then return true end
    if type(a) ~= 'table' or type(b) ~= 'table' then return false end
    for k, v in pairs(a) do
        if not deepEqual(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

-- ------------------------------------------------- json: a REAL codec
--
-- FiveM gives every resource `json.encode`/`json.decode`. Neither interpreter
-- here has one, so this is a small, strict reference codec written for the
-- test: it really encodes and really parses, and it raises on anything it
-- cannot represent, the way a production codec does. The module's tests used
-- to pass a bare function as the "codec", with the arguments in the wrong
-- order, and assert only that nothing raised -- which a module that did
-- nothing at all would also pass.
local RefJson = {}
do
    local escapes = { ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
        ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
    local function encodeString(s)
        return '"' .. s:gsub('[%c"\\]', function(c)
            return escapes[c] or ('\\u%04x'):format(c:byte())
        end) .. '"'
    end
    local function isArray(t)
        local n = 0
        for k in pairs(t) do
            if type(k) ~= 'number' or k % 1 ~= 0 or k < 1 then return false end
            n = n + 1
        end
        for i = 1, n do if t[i] == nil then return false end end
        return true, n
    end
    local function enc(v, out)
        local t = type(v)
        if v == nil then out[#out + 1] = 'null'
        elseif t == 'boolean' then out[#out + 1] = tostring(v)
        elseif t == 'number' then
            if v ~= v or v == math.huge or v == -math.huge then error('cannot encode ' .. tostring(v)) end
            if v % 1 == 0 and math.abs(v) < 1e15 then
                out[#out + 1] = ('%.0f'):format(v)
            else
                out[#out + 1] = ('%.17g'):format(v)
            end
        elseif t == 'string' then out[#out + 1] = encodeString(v)
        elseif t == 'table' then
            local arr, n = isArray(v)
            if arr then
                out[#out + 1] = '['
                for i = 1, n do
                    if i > 1 then out[#out + 1] = ',' end
                    enc(v[i], out)
                end
                out[#out + 1] = ']'
            else
                local keys = {}
                for k in pairs(v) do
                    if type(k) ~= 'string' then error('cannot encode a ' .. type(k) .. ' key') end
                    keys[#keys + 1] = k
                end
                table.sort(keys)
                out[#out + 1] = '{'
                for i, k in ipairs(keys) do
                    if i > 1 then out[#out + 1] = ',' end
                    out[#out + 1] = encodeString(k)
                    out[#out + 1] = ':'
                    enc(v[k], out)
                end
                out[#out + 1] = '}'
            end
        else
            error('cannot encode a ' .. t)
        end
    end
    function RefJson.encode(v)
        local out = {}
        enc(v, out)
        return table.concat(out)
    end

    function RefJson.decode(s)
        local pos = 1
        local function fail(what) error(('json: %s at byte %d'):format(what, pos), 0) end
        local function ws() pos = s:find('[^ \t\r\n]', pos) or (#s + 1) end
        local value
        local function str()
            pos = pos + 1
            local buf = {}
            while true do
                local c = s:sub(pos, pos)
                if c == '' then fail('unterminated string') end
                if c == '"' then pos = pos + 1 break end
                if c == '\\' then
                    local e = s:sub(pos + 1, pos + 1)
                    local map = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f',
                        n = '\n', r = '\r', t = '\t' }
                    if map[e] then
                        buf[#buf + 1] = map[e]
                        pos = pos + 2
                    elseif e == 'u' then
                        local hex = s:sub(pos + 2, pos + 5)
                        if not hex:match('^%x%x%x%x$') then fail('bad \\u escape') end
                        local code = tonumber(hex, 16)
                        if code >= 128 then fail('non-ASCII \\u escape is outside this reference') end
                        buf[#buf + 1] = string.char(code)
                        pos = pos + 6
                    else
                        fail('bad escape')
                    end
                elseif c:byte() < 32 then
                    fail('raw control character in string')
                else
                    buf[#buf + 1] = c
                    pos = pos + 1
                end
            end
            return table.concat(buf)
        end
        function value()
            ws()
            local c = s:sub(pos, pos)
            if c == '{' then
                pos = pos + 1
                local obj = {}
                ws()
                if s:sub(pos, pos) == '}' then pos = pos + 1 return obj end
                while true do
                    ws()
                    if s:sub(pos, pos) ~= '"' then fail('expected a key') end
                    local k = str()
                    ws()
                    if s:sub(pos, pos) ~= ':' then fail('expected :') end
                    pos = pos + 1
                    obj[k] = value()
                    ws()
                    local d = s:sub(pos, pos)
                    pos = pos + 1
                    if d == '}' then return obj end
                    if d ~= ',' then fail('expected , or }') end
                end
            elseif c == '[' then
                pos = pos + 1
                local arr, n = {}, 0
                ws()
                if s:sub(pos, pos) == ']' then pos = pos + 1 return arr end
                while true do
                    n = n + 1
                    arr[n] = value()
                    ws()
                    local d = s:sub(pos, pos)
                    pos = pos + 1
                    if d == ']' then return arr end
                    if d ~= ',' then fail('expected , or ]') end
                end
            elseif c == '"' then
                return str()
            elseif s:sub(pos, pos + 3) == 'true' then pos = pos + 4 return true
            elseif s:sub(pos, pos + 4) == 'false' then pos = pos + 5 return false
            elseif s:sub(pos, pos + 3) == 'null' then pos = pos + 4 return nil
            else
                local num = s:match('^-?%d+%.?%d*[eE]?[-+]?%d*', pos)
                if not num or num == '' or num == '-' then fail('unexpected character') end
                pos = pos + #num
                return tonumber(num) or fail('bad number')
            end
        end
        local v = value()
        ws()
        if pos <= #s then fail('trailing text') end
        return v
    end
end

-- Random JSON-shaped values: arrays, string-keyed objects, scalars, and
-- strings carrying every escape class plus raw UTF-8.
local function randomJsonValue(rng, depth)
    local r = rng()
    if depth > 3 or r < 0.45 then
        local s = rng()
        if s < 0.25 then return math.floor(rng() * 2000000) - 1000000 end
        if s < 0.4 then return (rng() - 0.5) * 1e6 end
        if s < 0.5 then return rng() < 0.5 end
        local pieces = { 'a', 'Z', '"', '\\', '\n', '\t', '\1', 'é', '€', '😀', ' ', '/', '{', ']' }
        local out = {}
        for i = 1, math.floor(rng() * 8) do out[i] = pieces[math.floor(rng() * #pieces) + 1] end
        return table.concat(out)
    end
    local t = {}
    if r < 0.7 then
        for i = 1, math.floor(rng() * 5) do t[i] = randomJsonValue(rng, depth + 1) end
    else
        for i = 1, math.floor(rng() * 5) + 1 do
            t['k' .. math.floor(rng() * 100) .. (i % 2 == 0 and '"' or '')] = randomJsonValue(rng, depth + 1)
        end
    end
    return t
end

do
    local J = CisJson
    -- The reference itself first: a broken reference makes everything below
    -- meaningless, so it has to prove it parses what it writes.
    local refOk = deepEqual(RefJson.decode(RefJson.encode({ 1, 'two', { three = 3 } })),
        { 1, 'two', { three = 3 } })
    expect(refOk, 'json: the reference codec round-trips a known value')

    local rng = testRng(1234)
    local bad = {}
    for i = 1, 250 do
        local v = randomJsonValue(rng, 1)
        local back, why = J.roundTrip(RefJson, v)
        if why ~= nil or not deepEqual(back, v) then
            bad[#bad + 1] = ('#%d %s'):format(i, tostring(why))
        end
        local text = J.encode(RefJson, v)
        if text ~= RefJson.encode(v) then bad[#bad + 1] = ('#%d encode differs'):format(i) end
    end
    expect(#bad == 0, 'json: 250 random values round-trip through a real codec unchanged: '
        .. table.concat(bad, '; ', 1, math.min(#bad, 3)))

    local nullValue, nullWhy = J.decode(RefJson, 'null')
    expect(nullValue == nil and nullWhy == nil, 'json: JSON null decodes to nil with NO reason')
    local okT, tv = J.tryDecode(RefJson, '[1,2,3]')
    expect(okT == true and deepEqual(tv, { 1, 2, 3 }), 'json: tryDecode answers true, value')
    local okBad, badWhy = J.tryDecode(RefJson, '{"a":')
    expect(okBad == false and type(badWhy) == 'string', 'json: malformed text is a refusal')

    -- Codecs that REFUSE without raising. Both used to read as success-null.
    local nilErr = {
        encode = function(v)
            local ok, out = pcall(RefJson.encode, v)
            if ok then return out end
            return nil, out
        end,
        decode = function(s)
            local ok, out = pcall(RefJson.decode, s)
            if ok then return out end
            return nil, out
        end,
    }
    local dkStyle = {
        encode = RefJson.encode,
        decode = function(s)
            local ok, out = pcall(RefJson.decode, s)
            if ok then return out, #s + 1 end
            return nil, 1, out
        end,
    }
    for _, codec in ipairs({ { 'nil, err', nilErr }, { 'nil, pos, err', dkStyle } }) do
        local v, why = J.decode(codec[2], '{"a":')
        expect(v == nil and type(why) == 'string' and why:find('json:', 1, true) ~= nil,
            ('json: a codec answering `%s` is a refusal with its reason, not a null (%s)')
                :format(codec[1], tostring(why)))
        local ok2 = J.tryDecode(codec[2], '[1')
        expect(ok2 == false, ('json: and tryDecode answers false for it (%s)'):format(codec[1]))
        local good = J.decode(codec[2], '{"a":[1,2]}')
        expect(deepEqual(good, { a = { 1, 2 } }), ('json: the same codec still decodes good text (%s)')
            :format(codec[1]))
    end
    local nullDk, nullDkWhy = J.decode(dkStyle, 'null')
    expect(nullDk == nil and nullDkWhy == nil, 'json: a dkjson-style `nil, position` for null is NOT a refusal')
    local encNil, encWhy = J.encode({ encode = function() return nil, 'no can do' end, decode = RefJson.decode }, {})
    expect(encNil == nil and type(encWhy) == 'string' and encWhy:find('no can do', 1, true) ~= nil,
        'json: an encoder answering nil, err is refused with ITS reason')
end

-- ------------------------------------------ json: the shape rule, by reference
do
    local J = CisJson
    -- The reference: what every codec agrees on. Written independently of
    -- the module, recursively, with no memoisation.
    local function refEncodable(v, depth, maxDepth)
        local t = type(v)
        if t == 'function' or t == 'thread' or t == 'userdata' then return false end
        if t == 'number' then return v == v and v ~= math.huge and v ~= -math.huge end
        if t ~= 'table' then return true end
        if depth > maxDepth then return false end
        local n, strings, numbers = 0, 0, 0
        for k in pairs(v) do
            n = n + 1
            if type(k) == 'string' then strings = strings + 1
            elseif type(k) == 'number' and k % 1 == 0 and k >= 1 then numbers = numbers + 1
            else return false end
        end
        if strings > 0 and numbers > 0 then return false end
        if numbers > 0 then for i = 1, n do if v[i] == nil then return false end end end
        for _, child in pairs(v) do
            if not refEncodable(child, depth + 1, maxDepth) then return false end
        end
        return true
    end
    -- Random tables, some with a defect planted somewhere inside.
    local function plant(rng, depth)
        local v = randomJsonValue(rng, depth)
        if type(v) ~= 'table' or rng() < 0.5 then return v end
        local d = rng()
        if d < 0.2 then v.name = 'x' ; v[1] = v[1] or 1          -- mixed
        elseif d < 0.4 then v[#v + 2] = 'gap'                     -- sparse
        elseif d < 0.55 then v[1.5] = 'half'                      -- fractional key
        elseif d < 0.65 then v[0] = 'zero'                        -- below 1
        elseif d < 0.75 then v[{}] = 'table key'
        elseif d < 0.85 then v.f = 0 / 0
        else v.child = plant(rng, depth + 1) end
        return v
    end
    local rng = testRng(777)
    local disagree, refused, accepted = {}, 0, 0
    for i = 1, 400 do
        local v = plant(rng, 1)
        local want = refEncodable(v, 1, 6)
        local got, why = J.checkEncodable(v, { maxDepth = 6 })
        if got then accepted = accepted + 1 else refused = refused + 1 end
        if (got == true) ~= want or (not got and type(why) ~= 'string') then
            disagree[#disagree + 1] = ('#%d want %s got %s (%s)'):format(i, tostring(want), tostring(got), tostring(why))
        end
    end
    expect(#disagree == 0 and refused > 50 and accepted > 50,
        ('json: checkEncodable agrees with the reference on 400 tables (%d refused, %d accepted): %s')
            :format(refused, accepted, table.concat(disagree, '; ', 1, math.min(#disagree, 3))))

    local _, mixedWhy = J.checkEncodable({ outer = { 1, 2, name = 'x' } })
    expect(type(mixedWhy) == 'string' and mixedWhy:find('outer', 1, true) and mixedWhy:find('mixed', 1, true),
        'json: a mixed table is refused and the reason names its path: ' .. tostring(mixedWhy))
    local _, sparseWhy = J.checkEncodable({ list = { [1] = 'a', [3] = 'c' } })
    expect(type(sparseWhy) == 'string' and sparseWhy:find('sparse', 1, true) ~= nil,
        'json: a sparse array is refused: ' .. tostring(sparseWhy))
    expect(J.checkEncodable({}) == true and J.checkEncodable({ {}, {} }) == true,
        'json: empty tables are encodable')

    -- A table shared by two parents is not a cycle, and must be checked once.
    local function dag(depth)
        local node = { leaf = true }
        for _ = 1, depth do node = { a = node, b = node } end
        return node
    end
    -- Counted, not timed: a fresh copy of the module whose `type` counts its
    -- calls. 16 levels is 17 distinct tables and 2^17 ROUTES; a walk per table
    -- is a few dozen calls, a walk per route is hundreds of thousands.
    local calls = 0
    local Jc = freshModule('shared/util/json.lua', {
        type = function(v) calls = calls + 1 return realType(v) end,
    })
    local okDag = Jc.checkEncodable(dag(16), { maxDepth = 64 })
    expect(okDag == true and calls < 1000,
        ('json: a 16-level shared-subtable DAG is walked once per table, not once per route'
            .. ' (%d type() calls; it was exponential)'):format(calls))
    -- And the depth that matters is the DEEPEST route to a shared table, not
    -- the first one the walk happened to take.
    local shared = { x = { y = { z = {} } } }        -- 4 levels including itself
    local tricky = { a = shared, b = { c = { d = shared } } }
    local okShallow = J.checkEncodable(tricky, { maxDepth = 7 })
    local okDeep, deepWhy = J.checkEncodable(tricky, { maxDepth = 6 })
    expect(okShallow == true and okDeep == false and type(deepWhy) == 'string',
        'json: a shared table too deep on its longer route is refused, whichever route is walked first')
    local cyc = { name = 'loop' }
    cyc.self = { back = cyc }
    local okCyc, cycWhy = J.checkEncodable(cyc)
    expect(okCyc == false and type(cycWhy) == 'string' and cycWhy:find('cycle', 1, true) ~= nil,
        'json: a real cycle is still refused')
end

-- ------------------------------------------------- table: keys with holes
do
    local T = CisTable
    local rng = testRng(5150)
    local wrong = {}
    for i = 1, 300 do
        local t = {}
        for k = 1, math.floor(rng() * 8) do
            if rng() < 0.75 then t[k] = 'v' .. k end
        end
        for _ = 1, math.floor(rng() * 4) do t['s' .. math.floor(rng() * 50)] = true end
        if rng() < 0.3 then t[math.floor(rng() * 20) + 10] = 'far' end
        if rng() < 0.2 then t[-1] = 'neg' end
        -- Reference: the contiguous prefix by rawget, then the rest sorted.
        local n = 0
        while rawget(t, n + 1) ~= nil do n = n + 1 end
        local want = {}
        for k = 1, n do want[k] = k end
        local rest = {}
        for k in pairs(t) do
            if not (type(k) == 'number' and k >= 1 and k <= n and k % 1 == 0) then rest[#rest + 1] = k end
        end
        table.sort(rest, function(a, b) return T.compareKeys(a, b) < 0 end)
        for _, k in ipairs(rest) do want[#want + 1] = k end
        local got = T.keys(t)
        local vals = T.values(t)
        local visited = {}
        T.each(t, nil, function(_, k) visited[#visited + 1] = k end)
        local valsOk = #vals == #want
        for j = 1, #want do if vals[j] ~= t[want[j]] then valsOk = false end end
        if not deepEqual(got, want) or not valsOk or not deepEqual(visited, want) then
            wrong[#wrong + 1] = ('#%d'):format(i)
        end
    end
    expect(#wrong == 0, 'table: keys/values/each list every real key exactly once, in one order, for 300'
        .. ' tables with holes: ' .. table.concat(wrong, ' ', 1, math.min(#wrong, 5)))
    local holey = { 1, nil, 3 }
    local ks = T.keys(holey)
    expect(#ks == 2 and ks[1] == 1 and ks[2] == 3, 'table: keys({1, nil, 3}) is {1, 3}, not {1, 2}')
end

-- ------------------------------------------------- table: sortBy is stable
do
    local T = CisTable
    local rng = testRng(8080)
    local comparators = {
        { 'boolean', function(a, b) return a < b end },
        { 'three-way', function(a, b) return a - b end },
        { 'default', nil },
    }
    for _, cmp in ipairs(comparators) do
        local unstable = 0
        for _ = 1, 60 do
            local list = {}
            for i = 1, 40 do list[i] = { k = math.floor(rng() * 5), id = i } end
            -- Reference: insertion sort, which is stable by construction.
            local ref = {}
            for i, e in ipairs(list) do
                local j = i
                while j > 1 and ref[j - 1].k > e.k do ref[j] = ref[j - 1] j = j - 1 end
                ref[j] = e
            end
            T.sortBy(list, function(e) return e.k end, cmp[2])
            for i = 1, #list do if list[i] ~= ref[i] then unstable = unstable + 1 break end end
        end
        expect(unstable == 0, ('table: sortBy is stable with a %s comparator (%d of 60 lists out of order)')
            :format(cmp[1], unstable))
    end
end

-- -------------------------------------- table: deepCopy, map, reduce, DAGs
do
    local T = CisTable
    local key = { id = 'player' }
    local src = { [key] = { hp = 100 } }
    local copy = T.deepCopy(src)
    expect(copy[key] ~= nil and copy[key] ~= src[key] and copy[key].hp == 100,
        'table: deepCopy keeps table KEYS by identity and copies the values')

    local mapped = T.map({ 1, 2, 3 }, function(v) if v ~= 2 then return v * 10 end end)
    expect(mapped[1] == 10 and mapped[2] == nil and mapped[3] == 30,
        'table: map keeps a nil result as nil, not as an invented false')
    local falses = T.map({ 1, 2 }, function() return false end)
    expect(falses[1] == false and falses[2] == false, 'table: and a real false is kept')

    local r, why = T.reduce({}, function(a, b) return a + b end)
    expect(r == nil and type(why) == 'string', 'table: reduce of {} with no initial value is a refusal')
    expect(T.reduce({}, function(a, b) return a + b end, 7) == 7, 'table: with an initial value it answers it')

    -- depth() against a brute-force reference on random DAGs.
    local rng = testRng(606)
    local wrongDepth = 0
    local function bruteDepth(v)
        local best = 0
        for _, c in pairs(v) do
            if type(c) == 'table' then
                local d = bruteDepth(c)
                if d > best then best = d end
            end
        end
        return best + 1
    end
    for _ = 1, 200 do
        local nodes = {}
        local count = math.floor(rng() * 10) + 2
        for i = 1, count do nodes[i] = { id = i } end
        for i = 1, count - 1 do
            for _ = 1, math.floor(rng() * 3) do
                local j = i + 1 + math.floor(rng() * (count - i))
                nodes[i]['e' .. j .. '_' .. math.floor(rng() * 100)] = nodes[j]
            end
        end
        if T.depth(nodes[1]) ~= bruteDepth(nodes[1]) then wrongDepth = wrongDepth + 1 end
    end
    expect(wrongDepth == 0, ('table: depth() counts the deepest route through shared tables on 200 random'
        .. ' DAGs (%d wrong)'):format(wrongDepth))

    local function dag(depth)
        local node = { leaf = true }
        for _ = 1, depth do node = { a = node, b = node } end
        return node
    end
    local calls = 0
    local Tc = freshModule('shared/util/table.lua', {
        type = function(v) calls = calls + 1 return realType(v) end,
    })
    local merged, mergeWhy = Tc.deepMerge({}, dag(16))
    expect(merged ~= nil and calls < 2000,
        ('table: deepMerge of a 16-level shared DAG walks each table a bounded number of times'
            .. ' (%d type() calls, %s; findCycle was exponential)'):format(calls, tostring(mergeWhy)))
    local cyc = {}
    cyc.a = { b = cyc }
    expect(T.findCycle(cyc) ~= nil and T.findCycle(dag(10)) == nil,
        'table: findCycle still tells a cycle from a shared table')
end

-- ---------------------------------------------------- string: truncate
do
    local S = CisString
    if type(utf8) == 'table' and utf8.charpattern then
        local chars = { 'a', 'b', ' ', 'é', '€', '😀', 'Z' }
        local function split(str)
            local out = {}
            for ch in str:gmatch(utf8.charpattern) do out[#out + 1] = ch end
            return out
        end
        local function firstN(list, n)
            return table.concat(list, '', 1, math.min(n, #list))
        end
        local rng = testRng(3141)
        local wrong = {}
        for i = 1, 400 do
            local parts = {}
            for j = 1, math.floor(rng() * 12) do parts[j] = chars[math.floor(rng() * #chars) + 1] end
            local s = table.concat(parts)
            local max = math.floor(rng() * 14)
            if rng() < 0.4 then max = max + 0.5 end
            local ellipses = { { nil, '...' }, { '', '' }, { '…', '…' }, { '..', '..' } }
            local e = ellipses[math.floor(rng() * #ellipses) + 1]
            -- Reference, in CHARACTERS.
            local whole = math.floor(max)
            local want
            if #parts <= whole then
                want = s
            elseif e[2] == '' then
                want = firstN(parts, whole)
            else
                local ell = split(e[2])
                local keep = whole - #ell
                if keep <= 0 then want = firstN(ell, whole) else want = firstN(parts, keep) .. e[2] end
            end
            local ok, got = pcall(S.truncate, s, max, e[1])
            if not ok or got ~= want then
                wrong[#wrong + 1] = ('#%d max=%g %s'):format(i, max, ok and ('got %q want %q'):format(got, want) or got)
            end
        end
        expect(#wrong == 0, 'string: truncate counts characters and floors max, for 400 random cases: '
            .. table.concat(wrong, '; ', 1, math.min(#wrong, 3)))
    end
    local ok, out = pcall(S.truncate, 'abcdef', 3.7, '')
    expect(ok and out == 'abc', 'string: a fractional max is floored rather than raising')
    local okBad, outBad = pcall(S.truncate, 'ab\255cdef', 4, '')
    expect(okBad and outBad == 'ab\255c', 'string: invalid UTF-8 is cut by bytes rather than raising')
end

-- ------------------------------------------- time/validate: %d and integers
do
    local Tm = CisTime
    local ok, s = pcall(Tm.relative, 0, 1e300)
    expect(ok and type(s) == 'string' and s:find(' ago', 1, true) ~= nil,
        'time: relative() of an enormous span formats rather than raising: ' .. tostring(s))
    local okF, f = pcall(Tm.formatDuration, 1e20)
    expect(okF and type(f) == 'string' and f:match('^%d+w') ~= nil,
        'time: formatDuration of 1e20 seconds formats rather than raising: ' .. tostring(f))
    expect(Tm.relative(math.huge, 0) == 'unknown' and Tm.relative(0, -math.huge) == 'unknown',
        'time: an infinite instant is unknown')
    expect(Tm.formatDuration(90061) == '1d 1h' and Tm.relative(0, 120) == '2 minutes ago',
        'time: ordinary values format as before')

    local V = CisValidate
    expect(V.isInteger(math.huge) == false and V.isInteger(-math.huge) == false,
        'validate: infinity is not an integer')
    expect(V.isInteger(5.0) == true and V.isInteger(5.5) == false and V.isInteger(0 / 0) == false,
        'validate: 5.0 is an integer, 5.5 and NaN are not')
    local okS, good, why = pcall(V.string, 'ab', { min = 2.5 })
    expect(okS and good == false and type(why) == 'string' and why:find('2.5', 1, true) ~= nil,
        'validate: a fractional length bound is reported, not raised: ' .. tostring(why))
    local okT, goodT, whyT = pcall(V.tableValue, { 1 }, { min = 1.5 })
    expect(okT and goodT == false and type(whyT) == 'string', 'validate: same for a table entry bound')
    local _, intWhy = V.string('abc', { max = 2 })
    expect(type(intWhy) == 'string' and intWhy:find('at most 2 characters', 1, true) ~= nil,
        'validate: a whole bound still reads as a whole number: ' .. tostring(intWhy))
end

-- ------------------------------------------- semver: against node-semver
--
-- The expected answers below were PRODUCED, not written: node-semver 7.6.3
-- evaluated every range against every version (plain, and with
-- includePrerelease), and the semver.org 2.0.0 regex judged every parse case.
-- npm's own behaviour is the contract for ranges; the spec is the contract for
-- versions. Two node-semver quirks are deliberately left out of the table:
-- numeric prerelease identifiers above 2^53 compare EQUAL there (it converts
-- them to doubles), and a hyphen range whose lower end carries build metadata
-- loses its '-0' under includePrerelease (string concatenation). Both are
-- pinned separately below with the spec-correct answer.
do
    -- GENERATED from node-semver 7.6.3 (ranges, compare) and the semver.org
    -- 2.0.0 regex (parse validity) by a one-off script;
    -- see the comment above.
    local SEMVER_PARSE = {
        { "1.2.3", true },
        { "0.0.0", true },
        { "10.20.30", true },
        { "1.1.2-prerelease+meta", true },
        { "1.0.0-alpha", true },
        { "1.0.0-alpha.beta", true },
        { "1.0.0-alpha.1", true },
        { "1.0.0-alpha0.valid", true },
        { "1.0.0-alpha.0valid", true },
        { "1.0.0-rc.1+build.1", true },
        { "2.0.0-rc.1+build.123", true },
        { "1.2.3-beta", true },
        { "10.2.3-DEV-SNAPSHOT", true },
        { "1.2.3-SNAPSHOT-123", true },
        { "2.0.0+build.1848", true },
        { "2.0.1-alpha.1227", true },
        { "1.0.0-alpha+beta", true },
        { "1.2.3----RC-SNAPSHOT.12.9.1--.12+788", true },
        { "1.2.3----R-S.12.9.1--.12+meta", true },
        { "1.0.0+0.build.1-rc.10000aaa-kk-0.1", true },
        { "1.0.0-0A.is.legal", true },
        { "1.2.3+001", true },
        { "1.2.3-0x1", true },
        { "1.2.3-1e3", true },
        { "9007199254740991.0.0", true },
        { "9007199254740992.0.0", false },
        { "1", false },
        { "1.2", false },
        { "1.2.3-0123", false },
        { "1.2.3-0123.0123", false },
        { "1.1.2+.123", false },
        { "+invalid", false },
        { "-invalid", false },
        { "-invalid+invalid", false },
        { "-invalid.01", false },
        { "alpha", false },
        { "alpha.beta", false },
        { "alpha.beta.1", false },
        { "alpha.1", false },
        { "alpha+beta", false },
        { "alpha_beta", false },
        { "alpha.", false },
        { "alpha..", false },
        { "beta", false },
        { "1.0.0-alpha_beta", false },
        { "-alpha.", false },
        { "1.0.0-alpha..", false },
        { "1.0.0-alpha..1", false },
        { "1.0.0-alpha...1", false },
        { "01.1.1", false },
        { "1.01.1", false },
        { "1.1.01", false },
        { "1.2.3.DEV", false },
        { "1.2-SNAPSHOT", false },
        { "1.2.31.2.3----RC-SNAPSHOT.12.09.1--..12+788", false },
        { "1.2-RC-SNAPSHOT", false },
        { "-1.0.3-gamma+b7718", false },
        { "+justmeta", false },
        { "9.8.7+meta+meta", false },
        { "9.8.7-whatever+meta+meta", false },
        { "1..2", false },
        { ".1.2.", false },
        { "1.2.", false },
        { ".1.2", false },
        { "1.2.3-", false },
        { "1.2.3+", false },
        { "1.2.3-a..b", false },
        { "v1.2.3", false },
        { " 1.2.3", false },
        { "1.2.3 ", false },
        { "=1.2.3", false },
        { "1.2.3.4", false },
        { "", false },
        { "1.2.3-a_b", false },
        { "1.2.3-x.7.z.92", true },
        { "1.2.3-é", false },
    }
    local SEMVER_VERSIONS = {
        "0.0.0", "0.0.1", "0.0.2", "0.1.0", "0.1.5", "0.2.0",
        "0.2.3", "1.0.0-0", "1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-beta", "1.0.0",
        "1.0.1", "1.2.0", "1.2.3-beta.2", "1.2.3-beta.10", "1.2.3", "1.2.3+build.5",
        "1.2.4-rc.1", "1.2.4", "1.2.99", "1.3.0-0", "1.3.0", "1.9.9",
        "2.0.0-0", "2.0.0-alpha", "2.0.0", "2.3.4", "2.3.5", "3.0.0-rc.1",
        "3.0.0", "10.0.0",
    }
    -- { range, plain row, includePrerelease row }: one character per version
    -- above, '1' satisfies and '0' does not; 'E' is a range node-semver rejects.
    local SEMVER_RANGES = {
        { "", '11111110000111001101101100111011', '11111111111111111111111111111111' },
        { "*", '11111110000111001101101100111011', '11111111111111111111111111111111' },
        { "x", '11111110000111001101101100111011', '11111111111111111111111111111111' },
        { "X", '11111110000111001101101100111011', '11111111111111111111111111111111' },
        { "1", '00000000000111001101101100000000', '00000001111111111111111100000000' },
        { "1.x", '00000000000111001101101100000000', '00000001111111111111111100000000' },
        { "1.X", '00000000000111001101101100000000', '00000001111111111111111100000000' },
        { "1.*", '00000000000111001101101100000000', '00000001111111111111111100000000' },
        { "1.2", '00000000000001001101100000000000', '00000000000001111111100000000000' },
        { "1.2.x", '00000000000001001101100000000000', '00000000000001111111100000000000' },
        { "1.2.*", '00000000000001001101100000000000', '00000000000001111111100000000000' },
        { "1.2.3", '00000000000000001100000000000000', '00000000000000001100000000000000' },
        { "=1.2.3", '00000000000000001100000000000000', '00000000000000001100000000000000' },
        { "v1.2.3", '00000000000000001100000000000000', '00000000000000001100000000000000' },
        { "=v1.2.3", '00000000000000001100000000000000', '00000000000000001100000000000000' },
        { "1.2.3-beta.2", '00000000000000100000000000000000', '00000000000000100000000000000000' },
        { ">1.2.3", '00000000000000000001101100111011', '00000000000000000011111111111111' },
        { ">=1.2.3", '00000000000000001101101100111011', '00000000000000001111111111111111' },
        { "<1.2.3", '11111110000111000000000000000000', '11111111111111110000000000000000' },
        { "<=1.2.3", '11111110000111001100000000000000', '11111111111111111100000000000000' },
        { "> 1.2.3", '00000000000000000001101100111011', '00000000000000000011111111111111' },
        { ">= 1.2.3", '00000000000000001101101100111011', '00000000000000001111111111111111' },
        { "< 2", '11111110000111001101101100000000', '11111111111111111111111100000000' },
        { ">1", '00000000000000000000000000111011', '00000000000000000000000011111111' },
        { ">=1", '00000000000111001101101100111011', '00000001111111111111111111111111' },
        { "<1", '11111110000000000000000000000000', '11111110000000000000000000000000' },
        { "<=1", '11111110000111001101101100000000', '11111111111111111111111100000000' },
        { ">1.2", '00000000000000000000001100111011', '00000000000000000000011111111111' },
        { ">=1.2", '00000000000001001101101100111011', '00000000000001111111111111111111' },
        { "<1.2", '11111110000110000000000000000000', '11111111111110000000000000000000' },
        { "<=1.2", '11111110000111001101100000000000', '11111111111111111111100000000000' },
        { "<1.x", '11111110000000000000000000000000', '11111110000000000000000000000000' },
        { ">1.x", '00000000000000000000000000111011', '00000000000000000000000011111111' },
        { "<=1.x", '11111110000111001101101100000000', '11111111111111111111111100000000' },
        { ">=1.x", '00000000000111001101101100111011', '00000001111111111111111111111111' },
        { ">*", '00000000000000000000000000000000', '00000000000000000000000000000000' },
        { "<*", '00000000000000000000000000000000', '00000000000000000000000000000000' },
        { ">=*", '11111110000111001101101100111011', '11111111111111111111111111111111' },
        { ">=x", '11111110000111001101101100111011', '11111111111111111111111111111111' },
        { "~1", '00000000000111001101101100000000', '00000000000111111111111100000000' },
        { "~1.2", '00000000000001001101100000000000', '00000000000001111111100000000000' },
        { "~1.2.3", '00000000000000001101100000000000', '00000000000000001111100000000000' },
        { "~0.2.3", '00000010000000000000000000000000', '00000010000000000000000000000000' },
        { "~1.2.3-beta.2", '00000000000000111101100000000000', '00000000000000111111100000000000' },
        { "~>1.2", '00000000000001001101100000000000', '00000000000001111111100000000000' },
        { "~> 1.2.3", '00000000000000001101100000000000', '00000000000000001111100000000000' },
        { "~ 1", '00000000000111001101101100000000', '00000000000111111111111100000000' },
        { "~x", '11111110000111001101101100111011', '11111111111111111111111111111111' },
        { "~*", '11111110000111001101101100111011', '11111111111111111111111111111111' },
        { "~", 'E', 'E' },
        { "^1", '00000000000111001101101100000000', '00000001111111111111111100000000' },
        { "^1.x", '00000000000111001101101100000000', '00000001111111111111111100000000' },
        { "^1.2", '00000000000001001101101100000000', '00000000000001111111111100000000' },
        { "^1.2.x", '00000000000001001101101100000000', '00000000000001111111111100000000' },
        { "^1.2.3", '00000000000000001101101100000000', '00000000000000001111111100000000' },
        { "^0", '11111110000000000000000000000000', '11111110000000000000000000000000' },
        { "^0.x", '11111110000000000000000000000000', '11111110000000000000000000000000' },
        { "^0.0", '11100000000000000000000000000000', '11100000000000000000000000000000' },
        { "^0.0.x", '11100000000000000000000000000000', '11100000000000000000000000000000' },
        { "^0.0.1", '01000000000000000000000000000000', '01000000000000000000000000000000' },
        { "^0.1", '00011000000000000000000000000000', '00011000000000000000000000000000' },
        { "^0.1.x", '00011000000000000000000000000000', '00011000000000000000000000000000' },
        { "^0.1.5", '00001000000000000000000000000000', '00001000000000000000000000000000' },
        { "^0.0.1-beta", '01000000000000000000000000000000', '01000000000000000000000000000000' },
        { "^1.2.3-beta.2", '00000000000000111101101100000000', '00000000000000111111111100000000' },
        { "^0.2.3-beta", '00000010000000000000000000000000', '00000010000000000000000000000000' },
        { "^ 1.2", '00000000000001001101101100000000', '00000000000001111111111100000000' },
        { "^x", '11111110000111001101101100111011', '11111111111111111111111111111111' },
        { "^*", '11111110000111001101101100111011', '11111111111111111111111111111111' },
        { "^", 'E', 'E' },
        { "1.2.3 - 2.3.4", '00000000000000001101101100110000', '00000000000000111111111111110000' },
        { "1.2 - 2.3.4", '00000000000001001101101100110000', '00000000000001111111111111110000' },
        { "1.2.3 - 2.3", '00000000000000001101101100111000', '00000000000000111111111111111000' },
        { "1.2.3 - 2", '00000000000000001101101100111000', '00000000000000111111111111111000' },
        { "1 - 2", '00000000000111001101101100111000', '00000001111111111111111111111000' },
        { "* - 2", '11111110000111001101101100111000', '11111111111111111111111111111000' },
        { "1.2.3 - *", '00000000000000001101101100111011', '00000000000000111111111111111111' },
        { "1.2.3-beta.2 - 2.3.4", '00000000000000111101101100110000', '00000000000000111111111111110000' },
        { "1.2.3 - 2.0.0-alpha", '00000000000000001101101111000000', '00000000000000111111111111000000' },
        { "0.0.1 - 0.1.5", '01111000000000000000000000000000', '01111000000000000000000000000000' },
        { ">=1.2.3 <2", '00000000000000001101101100000000', '00000000000000001111111100000000' },
        { ">=1.2.3 <2.0.0", '00000000000000001101101100000000', '00000000000000001111111111000000' },
        { ">1.2.3 <=2.3.4", '00000000000000000001101100110000', '00000000000000000011111111110000' },
        { ">=1.0.0-alpha <1.0.0", '00000000111000000000000000000000', '00000000111000000000000000000000' },
        { "<1.0.0-beta >=1.0.0-alpha", '00000000110000000000000000000000', '00000000110000000000000000000000' },
        { "1.x || >=2.5.0 || 5.0.0 - 7.2.3", '00000000000111001101101100000011', '00000001111111111111111100000111' },
        { "^1.2 || ^2", '00000000000001001101101100111000', '00000000000001111111111111111000' },
        { "^2 ||", '11111110000111001101101100111011', '11111111111111111111111111111111' },
        { "|| ^2", '11111110000111001101101100111011', '11111111111111111111111111111111' },
        { "^1.0.0 || || ^3.0.0", '11111110000111001101101100111011', '11111111111111111111111111111111' },
        { "<0.1 || >3", '11100000000000000000000000000001', '11100000000000000000000000000001' },
        { "1.2.3 1.2.4", '00000000000000000000000000000000', '00000000000000000000000000000000' },
        { ">=1.2.3-beta.2 <1.2.4", '00000000000000111100000000000000', '00000000000000111110000000000000' },
        { "1..2", 'E', 'E' },
        { ">=1.2.3-", 'E', 'E' },
        { "^1.2.3.4", 'E', 'E' },
        { "abc", 'E', 'E' },
        { "~1-rc1", 'E', 'E' },
        { ">=01.2.3", 'E', 'E' },
        { ">>1", 'E', 'E' },
        { "1.2.3 - ", 'E', 'E' },
        { "x.1.2.3", 'E', 'E' },
        { "^1.2.3-a..b", 'E', 'E' },
        { ">=1.2.3 foo", 'E', 'E' },
        { "1.2.3-01", 'E', 'E' },
        { ">=", 'E', 'E' },
        { "<", 'E', 'E' },
        { "=", 'E', 'E' },
        { "v", 'E', 'E' },
        { "1.2.3 -2", 'E', 'E' },
        { "1.2.3- 2", 'E', 'E' },
        { ">=1.2.3+build", '00000000000000001101101100111011', '00000000000000001111111111111111' },
        { ">=1.2.3-rc.1+b <2", '00000000000000001101101100000000', '00000000000000001111111100000000' },
    }
    -- In ascending precedence order where node-semver orders them; ties share a rank.
    local SEMVER_ORDER = {
        { "0.0.0", 0 },
        { "1.0.0-1", 1 },
        { "1.0.0-999", 2 },
        { "1.0.0-1000", 3 },
        { "1.0.0-0x1", 4 },
        { "1.0.0-1e3", 5 },
        { "1.0.0-a", 6 },
        { "1.0.0-a-b", 7 },
        { "1.0.0-alpha", 8 },
        { "1.0.0-alpha.1", 9 },
        { "1.0.0-alpha.beta", 10 },
        { "1.0.0-beta", 11 },
        { "1.0.0-beta.2", 12 },
        { "1.0.0-beta.11", 13 },
        { "1.0.0-rc.1", 14 },
        { "1.0.0", 15 },
        { "1.0.0+build", 15 },
        { "1.9.0", 16 },
        { "1.10.0", 17 },
        { "2.0.0", 18 },
    }

    local S = CisSemver
    local wrongParse = {}
    for _, c in ipairs(SEMVER_PARSE) do
        local parsed = S.parse(c[1])
        if (parsed ~= nil) ~= c[2] then wrongParse[#wrongParse + 1] = ('%q'):format(c[1]) end
    end
    expect(#wrongParse == 0, ('semver: strict parse agrees with the SemVer 2.0.0 grammar on %d inputs: %s')
        :format(#SEMVER_PARSE, table.concat(wrongParse, ' ')))

    local wrongRange = {}
    for _, r in ipairs(SEMVER_RANGES) do
        for mode = 2, 3 do
            local row, problem = {}, nil
            for i, v in ipairs(SEMVER_VERSIONS) do
                local res, why = S.satisfies(v, r[1], { includePrerelease = mode == 3 })
                if res == nil then row, problem = 'E', why break end
                row[i] = res and '1' or '0'
            end
            if type(row) == 'table' then row = table.concat(row) end
            if row ~= r[mode] then
                wrongRange[#wrongRange + 1] = ('%q%s want %s got %s (%s)'):format(r[1],
                    mode == 3 and ' +pre' or '', r[mode], row, tostring(problem))
            end
        end
    end
    expect(#wrongRange == 0, ('semver: %d ranges x %d versions agree with node-semver, plain and with'
        .. ' includePrerelease: %s'):format(#SEMVER_RANGES, #SEMVER_VERSIONS,
        table.concat(wrongRange, '; ', 1, math.min(#wrongRange, 4))))

    local wrongOrder = {}
    for i = 1, #SEMVER_ORDER do
        for j = 1, #SEMVER_ORDER do
            local a, b = SEMVER_ORDER[i], SEMVER_ORDER[j]
            local want = a[2] < b[2] and -1 or (a[2] > b[2] and 1 or 0)
            if S.compare(a[1], b[1]) ~= want then
                wrongOrder[#wrongOrder + 1] = a[1] .. ' vs ' .. b[1]
            end
        end
    end
    expect(#wrongOrder == 0, 'semver: compare orders every pair as node-semver does: '
        .. table.concat(wrongOrder, '; ', 1, math.min(#wrongOrder, 4)))

    -- Numeric identifiers are compared as NUMBERS of any size: tonumber
    -- would call '0x1' and '1e3' numeric, and a double cannot tell the last
    -- digit of a 20-digit id apart.
    expect(S.compare('1.0.0-0x1', '1.0.0-2') == 1, "semver: '0x1' is alphanumeric, so it sorts above 2")
    expect(S.compare('1.0.0-1e3', '1.0.0-999') == 1, "semver: '1e3' is alphanumeric too")
    expect(S.compare('1.0.0-12345678901234567890', '1.0.0-12345678901234567891') == -1,
        'semver: 20-digit numeric identifiers compare exactly')

    -- loose is explicit, and is the only way the old lenient inputs get in.
    local lv = S.parse(' v1.2 ', { loose = true })
    expect(lv ~= nil and lv.normalized == '1.2.0', "semver: loose reads ' v1.2 ' as 1.2.0")
    expect(S.parse('v1.2.3') == nil and S.parse('1') == nil, 'semver: strict does not')
    expect(S.parse('1..2', { loose = true }) == nil and S.parse('.1.2.', { loose = true }) == nil,
        "semver: '1..2' and '.1.2.' are not versions in any mode")
    expect((S.parse('01.2.3', { loose = true }) or {}).major == 1, 'semver: loose allows a leading zero')
    expect(S.satisfies(' v1.2.3', '^1', { loose = true }) == true and S.satisfies(' v1.2.3', '^1') == nil,
        'semver: satisfies honours loose for the version, and is strict without it')

    -- A table is validated, not trusted.
    local fromTable = S.parse({ major = 1, minor = 2, patch = 3, prerelease = 'rc.1' })
    expect(fromTable ~= nil and fromTable.normalized == '1.2.3-rc.1', 'semver: a version table normalises')
    local badTables = {
        {}, { major = 1, minor = 2 }, { major = -1, minor = 0, patch = 0 },
        { major = 1.5, minor = 0, patch = 0 }, { major = 1, minor = 0, patch = 0, prerelease = 'a..b' },
        { major = 1, minor = 0, patch = 0, prerelease = 7 }, { major = 0 / 0, minor = 0, patch = 0 },
    }
    local accepted = 0
    for _, t in ipairs(badTables) do
        if S.parse(t) ~= nil then accepted = accepted + 1 end
    end
    expect(accepted == 0, ('semver: malformed version tables are refused (%d accepted)'):format(accepted))
    expect(S.compare({}, '1.0.0') == nil, 'semver: compare refuses a malformed table instead of comparing nil')

    expect(S.best({ '1.2.3', '1.4.0', '2.0.0', '1.4.0-rc.1' }, '^1.2') == '1.4.0',
        'semver: best picks the highest match and skips the prerelease')
    expect(S.best({ '1.0.0', 'garbage' }, '*') == nil, 'semver: best refuses a malformed candidate')
end

io.write(('module tests: passed=%d failed=%d\n'):format(passed, failed))
if failed > 0 then
    os.exit(1)
end
