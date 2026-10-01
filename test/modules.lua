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

io.write(('module tests: passed=%d failed=%d\n'):format(passed, failed))
if failed > 0 then
    os.exit(1)
end
