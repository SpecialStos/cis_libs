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

local function expect(cond, msg)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        io.stderr:write('FAIL: ' .. msg .. '\n')
    end
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

    -- L-S12. A SOFT clear is O(1) by not deleting anything, which means every
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
    -- L-S13. The doc said roundTo returns "the number of whole units"; the code
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

-- ================================================================= CisGrid
do
    local G = CisGrid
    local grid = G.new()
    -- L-S17. insert() walks every cell an AABB overlaps, in a nested loop, on
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

    -- L-S6. A range wider than one MINSTD period. Every draw used to come back
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
    end

    -- L-S7. The two paths disagreed about the same call: math.random raises on
    -- a fractional bound, the generator returned 1.5, and a NaN bound came back
    -- out of the generator as NaN and straight into whatever used it.
    do
        -- A wrapper, because `pcall(CisRandom.integer, a, b, nil)` is a parse
        -- error in fengari: the call cannot end on a bare nil.
        local function tryInteger(a, b, rng)
            return pcall(CisRandom.integer, a, b, rng)
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
        expect(r1 == 0 and r2 == 0 and r3 == 0,
            'a NaN bound is refused on every path instead of propagating NaN')

        local ok4, r4 = tryInteger(0, math.huge, CisRandom.newGenerator(9))
        expect(ok4 and r4 == 0, 'an infinite bound is refused, not answered with Infinity')

        -- The ordinary integer path is untouched by any of that.
        local g = CisRandom.newGenerator(9)
        expect(CisRandom.integer(5, 5, g) == 5, 'a single-value range returns that value')
        expect(CisRandom.integer('a', 5, g) == 0, 'a non-number bound keeps its documented answer')
    end

    -- L-S14. An infinite weight made the whole cumulative array infinite, so
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

    -- L-S15. abs() then floor() then a modulo folded 1, -1 and 1.7 onto the
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
        local a, b = CisRandom.newGenerator(12345), CisRandom.newGenerator(12345)
        expect(a.state == b.state and a.state ~= nil and a.state >= 1 and a.state <= 2147483646,
            'the hashed state still lands inside the generator period')
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
    local x, y, z, ok = CisCurve.pointAtXYZ(path, 0)
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

    -- L-S9. A numeric component too wide for a double used to RAISE out of
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

        -- 15 digits is the last width a double holds exactly. 16 does not
        -- round-trip -- it becomes a different number, silently -- which is why
        -- it is refused rather than accepted.
        expect(S.parse('1.2.123456789012345').normalized == '1.2.123456789012345',
            'a 15-digit component parses and normalizes exactly')
        local ok3, res3 = parseOf('1.2.1234567890123456')
        expect(ok3 and res3 == nil, 'a 16-digit component is refused rather than rounded')

        -- The refusal has to survive the whole chain, or it just moves the
        -- raise one function up.
        local okS = pcall(CisSemver.satisfies, '1.2.99999999999999999999', '^1.0.0')
        expect(okS, 'satisfies does not raise on an unparsable version')
        expect(S.satisfies('1.2.99999999999999999999', '^1.0.0') == nil,
            'satisfies refuses an unparsable version with nil, not a raise')
    end

    -- L-S10. npm reads '<=1.2' as '<1.3.0' and '>1.2' as '>=1.3.0'. Both were
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

        -- The component count that drives both rewrites must ignore the digits
        -- inside a prerelease: '~1-rc1' counted the '1' in 'rc1' as a second
        -- component and became '>=1.0.0 <1.1.0'.
        expect(S.satisfies('1.5.0', '~1') == true, "'~1' still means >=1.0.0 <2.0.0")
        expect(S.satisfies('1.5.0', '~1-rc1') == true,
            "'~1-rc1' does not count the prerelease digits as a component")
    end
end

-- ===================================================================== CisId
do
    -- CONTRACT MISMATCH between the two modules, found only by running them
    -- together: CisId wants a bare FUNCTION returning [0,1), while
    -- CisRandom.newGenerator returns an OBJECT with :float(). Bridged with a
    -- closure here; one signature should absorb the other, and that is
    -- recorded rather than papered over.
    local gen = CisRandom.newGenerator(4242)
    local r = function() return gen:float() end
    local a = CisId.short('door', { rng = r, length = 8 })
    local b = CisId.short('door', { rng = r, length = 8 })
    expect(type(a) == 'string', 'short returns a string or a refusal: ' .. tostring(a))
    expect(a:sub(1, 5) == 'door_', 'short puts the readable prefix first, for log lines')
    expect(a ~= b, 'two draws differ')
end

-- =================================================================== CisJson
-- No codec is shipped: the module wraps an injected one. Under fengari there
-- is no real codec, so the contract under test is the refusal layer -- it
-- must never raise, whatever the injected codec does.
do
    local J = CisJson
    local hostile = function() error('codec exploded') end
    local ok = pcall(function() return J.check(hostile, { a = 1 }) end)
    expect(ok, 'check does not raise when the codec raises')
    local enc = pcall(function() return J.encode({ a = 1 }, hostile) end)
    expect(enc, 'encode does not raise when the codec raises')
end

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
        ('L-S1: 100 evenly spread calls in 1s allow at most limit+1 (allowed %d)')
            :format(allowed))

    -- Ten at once, then one a quarter of a second later: refused. This is the
    -- case that separates a per-WINDOW limiter from a per-SLICE one -- the old
    -- code reset `current` at the slice boundary and treated the reset as a
    -- fresh allowance.
    local burst = CisRate.newSliding({ limit = 10, windowSec = 1, subdivisions = 10 })
    for _ = 1, 10 do CisRate.allow(burst, 'k', 0, 1) end
    expect(not CisRate.allow(burst, 'k', 0.25, 1),
        'L-S1: ten calls at t=0 followed by one at t=0.25 is refused')
    -- ...and it recovers once the window has genuinely passed, which is what
    -- makes it a limiter rather than a permanent lockout.
    expect(CisRate.allow(burst, 'k', 2, 1),
        'L-S1: the allowance returns once the window has passed')

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
        'L-S1: a refused call does not consume budget, so it stays refused')
end

-- ================================================================= CisWindow
-- L-S2 · recording a sample with an EARLIER timestamp than the newest one.
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
        ('L-S2: an earlier sample is merged rather than evicting the newest (count=%s)')
            :format(tostring(r and r.count)))
    expect(r and r.sum == 3, 'L-S2: both samples contribute to the sum')
    expect(r and r.min == 1 and r.max == 2, 'L-S2: the extremes cover both samples')

    -- The forward case must still work, which is the property the rewind fix
    -- could plausibly have broken.
    local f = CisWindow.newStats(60, 1)
    for _, t in ipairs({ 10, 11, 12 }) do CisWindow.record(f, 'k', t, t) end
    local rf = CisWindow.read(f, 'k', 12.5)
    expect(rf and rf.count == 3, 'L-S2: forward recording is unaffected')
end

-- L-S3 · the bucket clamp was documented and missing.
--
-- The header says bucketSec is "clamped to at most windowSec and to at least
-- 1/1000 of it", and the code clamped only the upper bound. `newStats(60, 1e-6)`
-- therefore built a ring of 60 million slots: a table allocation large enough
-- to fail, from a call whose arguments look reasonable.
do
    local s = CisWindow.newStats(60, 1e-6)
    expect(s.bucketCount <= 1000,
        ('L-S3: an absurd bucket width is clamped (bucketCount=%s)')
            :format(tostring(s.bucketCount)))
    expect(s.bucketSec >= 60 / 1000, 'L-S3: the clamp is at window/1000')
    local ordinary = CisWindow.newStats(60, 5)
    expect(ordinary.bucketCount == 12, 'L-S3: an ordinary bucket width is untouched')
end

-- L-S8 · `seen(d, key, nil)` incremented size and stored nothing.
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
    expect(ok, 'L-S8: seen() does not raise on a nil now')
    expect(d.size == before, 'L-S8: a rejected now does not grow the window')
end

-- ================================================================ CisPending
-- L-S5 · a throwing `onExpire` aborted the sweep.
--
-- `sweep` iterated `store.items` and called `onExpire` from inside the loop,
-- uncaught. One consumer whose expire handler raised -- which is exactly what
-- happens when the handler logs and the logger is gone -- left every OTHER
-- expired key in the store for ever, and every future sweep to raise at the
-- same key. The store leaked, one key at a time, and nothing said so.
do
    local store = CisPending.new()
    CisPending.alloc(store, { n = 1 }, 10)
    CisPending.alloc(store, { n = 2 }, 10)
    CisPending.alloc(store, { n = 3 }, 10)
    local reported = {}
    local ok = pcall(CisPending.sweep, store, 20, function(key)
        reported[#reported + 1] = key
        if key == 1 then error('the logger is gone') end
    end)
    expect(ok, 'L-S5: a throwing onExpire does not escape the sweep')
    expect(CisPending.count(store) == 0,
        ('L-S5: every expired key is still removed (left=%d)')
            :format(CisPending.count(store)))
    expect(#reported == 3,
        ('L-S5: every expired key is still reported (reported=%d)'):format(#reported))
    expect(CisPending.peek(store, 1) == nil, 'L-S5: peek confirms the first key is gone')
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
-- L-S11 · `call(slot)` with a nil or non-string method raised.
--
-- A caller that builds the method name at runtime -- `call('database',
-- queryName)` where the name came from a config -- hit `method:sub(1, 1)` on a
-- nil and the exception surfaced in whatever thread called it. A refusal with a
-- reason is the contract everywhere else in this file.
do
    local threw = not pcall(function() return CisRegistry.call('database') end)
    expect(not threw, 'L-S11: call() with no method does not raise')
    local ok, reason = CisRegistry.call('database')
    expect(ok == false, 'L-S11: call() with no method refuses')
    expect(type(reason) == 'string' and reason:find('method', 1, true) ~= nil,
        'L-S11: and the refusal says a method name is required: ' .. tostring(reason))
    local ok2, reason2 = CisRegistry.call('database', 42)
    expect(ok2 == false and type(reason2) == 'string',
        'L-S11: a non-string method name refuses rather than raising')
end

-- ================================================================== CisOwned
-- THE OWNERSHIP LEDGER, which is the whole of the consumer-stop fix.
--
-- ox_lib does not have this problem because it runs inside the consumer's own
-- Lua VM: everything a resource creates dies with it. cis_libs runs in its OWN
-- VM, so a zone, a target, a synced entity and a remote callback outlive the
-- resource that asked for them -- silently, and until the process restarts.
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

io.write(('module tests: passed=%d failed=%d\n'):format(passed, failed))
if failed > 0 then
    os.exit(1)
end
