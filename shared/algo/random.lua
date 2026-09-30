-- Randomness: shuffling, unbiased integers, weighted choice, and a seedable
-- generator.
--
-- PURE. No state: the generator is passed in and the caller owns it, so two
-- limiters or two loot tables can be made to behave identically for a test by
-- handing both the same seeded generator.
--
-- SECURITY, SAID PLAINLY BECAUSE IT IS THE THING THAT GETS MISREAD
--
-- `math.random` in LuaJIT -- which is what runs inside FiveM -- is a 64-bit
-- xorshift state advanced by a multiply. It is fast, well distributed for
-- gameplay purposes, and NOT cryptographically secure. It is not seeded from
-- an operating-system entropy source: FiveM seeds it at startup, so its stream
-- is the same for every server process that boots the same way, and an attacker
-- who can observe outputs (a loot roll, a hit location) can work backwards
-- toward the internal state. That matters only where a player profits from
-- predicting the stream -- paid loot rolls, gacha, anything where "random" is
-- money. For "pick a bar to send this drunk pedestrian to", it is completely
-- fine and there is no reason to pay for more.
--
-- So: this file does not claim to be secure, and it does not pretend to be.
-- If you need unpredictability across a process boundary, generate the seed
-- from outside Lua (a server-side native, an HTTP request, the OS) and pass it
-- to `CisRandom.newGenerator`. That is the only part that has to be
-- unpredictable; the generator itself does not have to be a cipher.
--
-- WHY A SEEDED GENERATOR AT ALL, GIVEN math.random EXISTS
--
-- Determinism. `math.randomseed(1)` is global -- it reseeds the state every
-- other code path in the process shares, so a test that seeds it perturbs
-- anything else that rolled a number first, and two servers cannot be made to
-- replay the same match. A generator object is a value: seed it, hand the same
-- object to everything that should be in lockstep, and the sequence is
-- reproducible across LuaJIT and Lua 5.4 and across runs.
--
-- The generator is MINSTD (Park-Miller, `state * 48271 mod 2^31-1`), chosen
-- because it needs no bitwise operators at all. That matters here: this
-- repository is `lua54 'yes'` but the parser is sensitive elsewhere (FiveM hash
-- literals, plain-Lua CI), and a generator written with `>>` and `&` cannot be
-- loaded by a tool that only has Lua 5.1 syntax. The whole state fits in a
-- double exactly -- the largest intermediate is about 1.04e14, well inside the
-- 2^53 range where a double is an exact integer -- so the arithmetic is exact
-- and the sequence is identical everywhere.
--
-- WHAT IT IS NOT: MINSTD has a period of 2^31-2 and is not a CSPRNG. It is a
-- deterministic sequence generator, and that is exactly what is wanted here.

CisRandom = {}

local MOD = 2147483647
local MULT = 48271

-- Normalise the caller's `rng` argument into "give me a float in [0, 1)".
-- Three accepted shapes, documented once here because every function below
-- takes it:
--   nil             use math.random
--   function         called with no arguments, must return a number in [0, 1)
--   table            a generator from newGenerator (uses its float method)
local function rand01(rng)
    local v
    if rng == nil then
        v = math.random()
    elseif type(rng) == 'function' then
        v = rng()
    elseif type(rng) == 'table' and type(rng.float) == 'function' then
        v = rng:float()
    else
        v = math.random()
    end
    -- Clamp rather than trust. An injected generator that returns 1 (or NaN,
    -- or a string) must not turn the rejection loop below into an infinite
    -- loop or poison a coordinate with NaN; both failure modes are far worse
    -- than the tiny bias a clamped draw introduces.
    if type(v) ~= 'number' or v ~= v then
        return 0
    end
    if v <= 0 then
        return 0
    end
    if v >= 1 then
        return 0.9999999999
    end
    return v
end

-- Integer draw in [lo, hi] for a generator that only exposes float.
--
-- THE REJECTION LOOP IS NOT OPTIMISM, IT IS CORRECTNESS. `lo + (v % n)` is
-- biased whenever n does not divide the size of the source range: the low
-- values of the range come up more often than the high ones. With a 2^32-wide
-- source and a small n the bias is around 1e-9 and no test will ever see it,
-- which is precisely why it survives for a decade. Here the cost is one
-- comparison in the overwhelming majority of draws and an exact distribution
-- always, so there is no reason to keep the biased version.
--
-- The retry count is bounded, and that is not a performance measure -- it is
-- what makes the function total. An INJECTED rng is a function this file does
-- not control, and one that returns a constant (a broken stub, a mock that
-- always returns 0.5, a seeded generator somebody clamped) never produces an
-- acceptable value, so an unbounded loop would hang the caller forever. After
-- MAX_RETRIES the biased modulo is used: a slightly wrong answer beats a
-- process that stops. No sane generator ever reaches that branch -- one draw
-- in 2^32-ish is rejected -- and CisRandom.newGenerator cannot reach it at all,
-- because MINSTD visits every residue class in a full period.
local MAX_RETRIES = 8

local function randInt(rng, lo, hi)
    if type(rng) == 'table' and type(rng.int) == 'function' then
        return rng:int(lo, hi)
    end
    if rng == nil then
        -- math.random(lo, hi) is already unbiased: it is a modulus-rejection
        -- implementation in C. Do not re-roll it.
        return math.random(lo, hi)
    end
    local n = hi - lo + 1
    if n <= 0 then
        return lo
    end
    local limit = 4294967296 - (4294967296 % n)
    local v = rand01(rng) * 4294967296
    local retries = 0
    while v >= limit and retries < MAX_RETRIES do
        v = rand01(rng) * 4294967296
        retries = retries + 1
    end
    if v >= limit then
        v = math.floor(v)
        if v >= 4294967296 then v = 4294967295 end
    else
        v = math.floor(v)
    end
    return lo + (v % n)
end

--- A seeded, reproducible generator.
---
--- @param seed number|nil  any number. Fractions are floored, negatives are
---        taken modulo the period, and 0 becomes 1 (0 is the fixed point of
---        this generator: seeding it with 0 yields 0 forever).
--- @return table  { next, float, int, range }
function CisRandom.newGenerator(seed)
    local s
    if type(seed) == 'number' and seed == seed and math.abs(seed) < 1e18 then
        s = math.floor(math.abs(seed)) % (MOD - 1) + 1
    else
        -- A nil or nonsense seed still has to produce a usable generator, or
        -- every caller has to guard the constructor. It does NOT produce a
        -- secure one: see the header.
        s = 12345
    end

    local gen = { state = s }

    --- Next raw value, 1 .. MOD-1.
    function gen:next()
        self.state = (self.state * MULT) % MOD
        return self.state
    end

    --- Float in [0, 1). Never returns exactly 1, so `(float() * n)` is never n.
    function gen:float()
        return self:next() / MOD
    end

    --- Integer in [lo, hi] inclusive, unbiased, and reversed ranges are
    --- swapped rather than returning something out of range.
    function gen:int(lo, hi)
        if lo > hi then
            lo, hi = hi, lo
        end
        if lo == hi then
            return lo
        end
        local n = hi - lo + 1
        -- next() yields 1 .. MOD-1, so the largest multiple of n in that range
        -- is the largest multiple of n not exceeding MOD-1. Truncating to MOD
        -- instead would leave a sliver of the range unaccounted for and bias
        -- the result by exactly one value in n.
        --
        -- The retry bound is unreachable here -- MINSTD's period covers every
        -- residue class, so a value above the limit is always followed by one
        -- below it -- and it exists so that this method has the same total
        -- shape as the injected-rng path and cannot be made to spin.
        local limit = (MOD - 1) - ((MOD - 1) % n)
        local v = self:next()
        local retries = 0
        while v > limit and retries < 8 do
            v = self:next()
            retries = retries + 1
        end
        if v > limit then
            v = v - 1 - ((v - 1 - limit) % n)
        end
        return lo + ((v - 1) % n)
    end

    --- Float in [min, max). A reversed range is swapped.
    function gen:range(min, max)
        if min > max then
            min, max = max, min
        end
        return min + self:float() * (max - min)
    end

    return gen
end

--- Integer in [lo, hi] INCLUSIVE, uniformly.
---
--- @param rng table|function|nil  see the header; nil uses math.random
--- @return number  `lo` when lo > hi or either bound is not a number
function CisRandom.integer(lo, hi, rng)
    if type(lo) ~= 'number' or type(hi) ~= 'number' then
        return 0
    end
    if lo > hi then
        lo, hi = hi, lo
    end
    if lo == hi then
        return lo
    end
    return randInt(rng, lo, hi)
end

--- Float in [min, max).
--- @return number  `min` when the bounds are not numbers or the range is empty
function CisRandom.float(min, max, rng)
    if type(min) ~= 'number' or type(max) ~= 'number' then
        return 0
    end
    if min > max then
        min, max = max, min
    end
    if min == max then
        return min
    end
    return min + rand01(rng) * (max - min)
end

--- Fisher-Yates shuffle, IN PLACE.
---
--- Fisher-Yates and not the naive "swap each element with a random one": the
--- naive version is measurably non-uniform, and it is non-uniform in a way that
--- only shows up at large N, which is to say it ships. Walking the list from
--- the END downwards and swapping each element with a uniformly chosen earlier
--- one makes every one of the n! permutations equally likely, and it is the
--- same cost.
---
--- @param list table|nil  any array; modified in place and returned
--- @param rng table|function|nil
--- @return table  the same table, or nil when list is not a table. Returning
---         nil rather than {} keeps `shuffle(config.items)` from silently
---         turning a nil config value into an empty table that then reads as
---         "the list is empty" instead of "the list is missing".
function CisRandom.shuffle(list, rng)
    if type(list) ~= 'table' then
        return nil
    end
    for i = #list, 2, -1 do
        local j = randInt(rng, 1, i)
        list[i], list[j] = list[j], list[i]
    end
    return list
end

--- One uniformly random element of a list.
--- @return any  nil for an empty or non-table list -- "no element" has to be
---         representable, and a caller indexing result[1] on nil is a caller
---         bug that should surface at the caller
function CisRandom.pick(list, rng)
    if type(list) ~= 'table' then
        return nil
    end
    local n = #list
    if n < 1 then
        return nil
    end
    return list[randInt(rng, 1, n)]
end

--- `k` distinct elements of a list, in random order, WITHOUT touching the
--- input.
---
--- Partial Fisher-Yates: copy the list, then shuffle only the first k slots by
--- swapping each into place from the shrinking tail. O(k) time after the copy.
---
--- The alternative is reservoir sampling (Algorithm R), which is O(n) time and
--- O(k) memory and never allocates a copy. It wins when the input is huge and
--- the copy is the expensive part -- a 50k-entry table at 60fps. It loses
--- otherwise, because it reads every element while the partial shuffle reads
--- k. At the sizes this library deals with the copy is cheap and the copy is
--- also what keeps the caller's table safe from a shuffle it did not ask for,
--- so the partial shuffle is the default. If you ever need the other one, it is
--- twenty lines and the shape is the same.
---
--- @param k number  clamped to [0, #list]; k <= 0 returns an empty table
--- @return table  a NEW array of exactly k elements, in random order; never the
---         input
function CisRandom.sample(list, k, rng)
    local out = {}
    if type(list) ~= 'table' then
        return out
    end
    local n = #list
    if type(k) ~= 'number' or k ~= k or k < 0 then
        return out
    end
    if k > n then k = n end
    for i = 1, n do
        out[i] = list[i]
    end
    for i = 1, k do
        local j = randInt(rng, i, n)
        out[i], out[j] = out[j], out[i]
    end
    -- Drop the tail. The first k slots are now a uniformly random SUBSET in a
    -- uniformly random order; slots k+1..n are just the untouched remainder of
    -- the copy and must not be handed back, or "give me 3" returns all 8.
    for i = k + 1, n do
        out[i] = nil
    end
    return out
end

--- Weighted choice.
---
--- Cumulative weights plus a binary search, O(log n) per draw and O(n) memory.
---
--- The alternative is Vose's alias method: O(1) per draw, but it needs an O(n)
--- build and 2n floats of memory. That is the right answer for a loot table
--- drawn a hundred thousand times from a fixed weight vector, and the wrong
--- answer for a config that is read once and drawn a few hundred times, which
--- is what a weight list in a FiveM resource actually is. The build cost and
--- the memory both dominate the draw cost at these sizes, so the simpler
--- structure wins. (It is also about fifteen lines against the alias table's
--- fifty, and a build step that can be got wrong is a bug that only shows up
--- under load.)
---
--- @param entries table  array of tables with `.weight` (number, may be
---        fractional) and `.value` (anything)
--- @param rng table|function|nil
--- @return any  the chosen `.value`, or nil when the list is empty, has no
---         usable entries, or every weight is zero. A zero total is a
---         configuration error and returning nil says "nothing to give" rather
---         than raising in the middle of a reward roll.
function CisRandom.weighted(entries, rng)
    if type(entries) ~= 'table' then
        return nil
    end
    local n = #entries
    if n < 1 then
        return nil
    end

    -- Cumulative array first, then one uniform draw, then a search. Building
    -- the array first means the search is over a fixed structure and the
    -- randomness enters exactly once, which is what keeps the distribution
    -- right.
    local cumulative = {}
    local last = 0
    for i = 1, n do
        local e = entries[i]
        local w = type(e) == 'table' and e.weight or nil
        if type(w) == 'number' and w > 0 then
            last = last + w
            cumulative[i] = last
        else
            cumulative[i] = last
        end
    end
    if last <= 0 then
        return nil
    end

    local target = rand01(rng) * last
    -- Largest i with cumulative[i] <= target, over 1..n. When every entry up to
    -- some point is zero-weight the array has plateaus; searching for the
    -- largest index at or below the target lands on the first entry that
    -- actually owns the interval, never on a zero-weight one.
    local lo, hi = 1, n
    while lo < hi do
        local mid = math.floor((lo + hi) * 0.5)
        if cumulative[mid] <= target then
            lo = mid + 1
        else
            hi = mid
        end
    end
    if lo < 1 then lo = 1 end
    if lo > n then lo = n end
    local e = entries[lo]
    if type(e) ~= 'table' then
        return nil
    end
    -- An entry without a `value` field is its own value, so a weight list of
    -- plain tables works without every entry carrying a self-reference.
    if e.value ~= nil then
        return e.value
    end
    return e
end

--- Index of a weighted choice, for callers that keep weights and values in
--- parallel arrays.
--- @return number|nil  1-based index, or nil when the total weight is 0
function CisRandom.weightedIndex(weights, rng)
    if type(weights) ~= 'table' then
        return nil
    end
    local n = #weights
    if n < 1 then
        return nil
    end
    local cumulative = {}
    local last = 0
    for i = 1, n do
        local w = weights[i]
        if type(w) == 'number' and w > 0 then
            last = last + w
        end
        cumulative[i] = last
    end
    if last <= 0 then
        return nil
    end
    local target = rand01(rng) * last
    local lo, hi = 1, n
    while lo < hi do
        local mid = math.floor((lo + hi) * 0.5)
        if cumulative[mid] <= target then
            lo = mid + 1
        else
            hi = mid
        end
    end
    if lo < 1 then lo = 1 end
    if lo > n then lo = n end
    return lo
end

--- Normally distributed value, mean 0 and standard deviation 1 unless told
--- otherwise.
---
--- Box-Muller: two independent normals from a pair of uniforms, in polar
--- coordinates, with the log and the cos discarded. The trig costs more than
--- the naive sum-of-uniforms approximation, and the approximation's error is
--- visible as a flat-topped bell in a spawn-distance histogram, which is
--- exactly the kind of thing that gets reported as "spawns feel wrong" with no
--- way to point at the cause.
---
--- The second normal from each pair is thrown away rather than cached. Caching
--- it would need state, and state in a random function means two draws no
-- longer being independent in a way a seeded test would have to model. The
--- cost is one extra log and one extra cos.
---
--- @return number  mean + z * standardDeviation
function CisRandom.gaussian(rng, mean, standardDeviation)
    mean = mean or 0
    standardDeviation = standardDeviation or 1
    -- A draw of exactly 0 makes log(0) -inf and the whole result NaN, which
    -- then propagates into a coordinate. Clamp it.
    local u1 = rand01(rng)
    if u1 < 1e-12 then u1 = 1e-12 end
    local u2 = rand01(rng)
    local radius = math.sqrt(-2 * math.log(u1))
    local angle = 2 * math.pi * u2
    return mean + radius * math.cos(angle) * standardDeviation
end
