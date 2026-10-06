-- Randomness: shuffling, unbiased integers, weighted choice, and a seedable generator.

local M = {}

local MOD = 2147483647
local MULT = 48271
-- The other multiplier from the same Park-Miller family, applied to the magnitude of a
local MULT_NEG = 16807

-- The largest integer a double holds EXACTLY, and therefore the widest uniform range
local TWO53 = 9007199254740992
local TWO32 = 4294967296

-- Normalise caller bounds into an inclusive integer range, or nil when the request
local function intBounds(lo, hi, who)
    if type(lo) ~= 'number' or type(hi) ~= 'number' then
        error(('%s: lo and hi must be numbers, got %s and %s')
            :format(who, type(lo), type(hi)), 3)
    end
    -- NaN fails every comparison, so it needs its own check: `lo > hi` is false for it
    if lo ~= lo or hi ~= hi then
        return nil, 'a bound is NaN, which is not a range'
    end
    if lo == math.huge or lo == -math.huge or hi == math.huge or hi == -math.huge then
        return nil, 'a bound is infinite, so there is no finite range to draw from'
    end
    lo = math.floor(lo)
    hi = math.ceil(hi)
    if lo > hi then
        lo, hi = hi, lo
    end
    return lo, hi
end

-- Normalise the caller's `rng` argument into "give me a float in [0, 1)".
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
    -- Clamp rather than trust. An injected generator that returns 1 (or NaN, or a
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
local MAX_RETRIES = 8

-- The same rule for float bounds.
local function floatBounds(min, max, who)
    if type(min) ~= 'number' or type(max) ~= 'number' then
        error(('%s: min and max must be numbers, got %s and %s')
            :format(who, type(min), type(max)), 3)
    end
    if min ~= min or max ~= max then
        return nil, 'a bound is NaN, which is not a range'
    end
    if min == math.huge or max == math.huge or min == -math.huge or max == -math.huge then
        return nil, 'a bound is infinite, so the draw has no range to land in'
    end
    if min > max then
        min, max = max, min
    end
    return min, max
end

-- One draw in [0, span), assembled from as many rand01 calls as it takes.
local function randWide(rng, _)
    local acc, produced = 0, 0
    local take = 32
    while produced < 53 do
        if take > 53 - produced then take = 53 - produced end
        acc = acc * (2 ^ take) + math.floor(rand01(rng) * (2 ^ take))
        produced = produced + take
    end
    return acc
end

-- The bias-correction loop for the injected-function path.
local function drawBelow(rng, n, span)
    local limit = span - (span % n)
    local v, retries
    if span > TWO32 then
        v, retries = randWide(rng, span), 0
        while v >= limit and retries < MAX_RETRIES do
            v = randWide(rng, span)
            retries = retries + 1
        end
    else
        v, retries = rand01(rng) * span, 0
        while v >= limit and retries < MAX_RETRIES do
            v = rand01(rng) * span
            retries = retries + 1
        end
    end
    if v >= limit then
        v = math.floor(v)
        if v >= span then v = span - 1 end
    else
        v = math.floor(v)
    end
    return v
end

local function randInt(rng, lo, hi)
    local n = hi - lo + 1
    if n <= 0 then
        return lo
    end
    if type(rng) == 'table' and type(rng.int) == 'function' then
        return rng:int(lo, hi)
    end
    if rng == nil then
        -- math.random(lo, hi) is already unbiased: it is a modulus-rejection
        return math.random(lo, hi)
    end
    -- A single rand01 draw addresses 2^32.
    local span = TWO32
    if n > span then
        if n > TWO53 then
            error(('CisRandom: a range of %d is wider than the 2^53 a double holds exactly')
                :format(n), 3)
        end
        span = TWO53
    end
    return lo + (drawBelow(rng, n, span) % n)
end

-- The same 2^53 assembly for a generator object, which reaches one MINSTD step at a
local function nextWide(gen)
    local high = gen:next() - 1                  -- 0 .. MOD-2, 31 bits
    local low = (gen:next() - 1) % 4194304       -- 22 bits
    return high * 4194304 + low                  -- 0 .. 2^53 - 1, exactly
end

-- Hash a seed into the generator period.
local function hashSeed(seed)
    local negative = seed < 0
    local a = negative and -seed or seed
    local whole = math.floor(a)
    -- 32 bits of the fraction. Without this the floor above is all that survives and 1
    local frac = math.floor((a - whole) * TWO32)
    -- The sign goes in by selecting the multiplier, not by being abs'd away and not by
    local h = whole % (MOD - 1)
    h = (h * MULT) % MOD
    h = (h + frac * MULT) % MOD
    h = (h * (negative and MULT_NEG or MULT)) % MOD
    if h == 0 then
        h = 1
    end
    return h
end

--- A seeded, reproducible generator.
--- @param seed number|nil  any number. Fractions, negatives and magnitudes
--- @return table  { next, float, int, range }
function M.newGenerator(seed)
    local s
    if type(seed) == 'number' and seed == seed and math.abs(seed) < 1e18 then
        s = hashSeed(seed)
    else
        -- A nil or nonsense seed still has to produce a usable generator, or every
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

    --- Integer in [lo, hi] inclusive, unbiased, and reversed ranges are swapped rather
    function gen:int(lo, hi)
        local a, b = intBounds(lo, hi, 'generator:int')
        if a == nil then
            return nil, b
        end
        if a == b then
            return a
        end
        local n = b - a + 1
        if n <= MOD - 1 then
            -- next() yields 1 .. MOD-1, so the largest multiple of n in that range is
            local limit = (MOD - 1) - ((MOD - 1) % n)
            local v, retries = self:next(), 0
            while v > limit and retries < 8 do
                v = self:next()
                retries = retries + 1
            end
            if v > limit then
                v = v - 1 - ((v - 1 - limit) % n)
            end
            return a + ((v - 1) % n)
        end

        -- Wider than one period. This used to fall into the branch above with `limit`
        if n > TWO53 then
            error(('CisRandom: a range of %d is wider than the 2^53 a double holds exactly')
                :format(n), 2)
        end
        local limit = TWO53 - (TWO53 % n)
        local v, retries = nextWide(self), 0
        while v >= limit and retries < 8 do
            v = nextWide(self)
            retries = retries + 1
        end
        if v >= limit then
            v = v - (v - limit) % n
        end
        return a + (v % n)
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
--- @param rng table|function|nil  see the header; nil uses math.random
--- @param lo
--- @param hi
--- @return number  the drawn integer
--- @return number|nil,string  `nil, reason` when a bound is NaN or infinite
--- @raise  when a bound is not a number -- a mistake in the caller's code, which
function M.integer(lo, hi, rng)
    local a, b = intBounds(lo, hi, 'CisRandom.integer')
    if a == nil then
        return nil, b
    end
    if a == b then
        return a
    end
    return randInt(rng, a, b)
end

--- Float in [min, max). Same error style as `integer`, and for the same reason: this
--- @param min
--- @param max
--- @param rng
--- @return number
--- @return number|nil,string  `nil, reason` when a bound is NaN or infinite
--- @raise  when a bound is not a number
function M.float(min, max, rng)
    local a, b = floatBounds(min, max, 'CisRandom.float')
    if a == nil then
        return nil, b
    end
    if a == b then
        return a
    end
    return a + rand01(rng) * (b - a)
end

--- Fisher-Yates shuffle, IN PLACE.
--- @param list table|nil  any array; modified in place and returned
--- @param rng table|function|nil
--- @return table  the same table, or nil when list is not a table. Returning
function M.shuffle(list, rng)
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
--- @param list
--- @param rng
--- @return any  nil for an empty or non-table list -- "no element" has to be
function M.pick(list, rng)
    if type(list) ~= 'table' then
        return nil
    end
    local n = #list
    if n < 1 then
        return nil
    end
    return list[randInt(rng, 1, n)]
end

--- `k` distinct elements of a list, in random order, WITHOUT touching the input.
--- @param k number  clamped to [0, #list]; k <= 0 returns an empty table
--- @param list
--- @param rng
--- @return table  a NEW array of exactly k elements, in random order; never the
function M.sample(list, k, rng)
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
    -- Drop the tail. The first k slots are now a uniformly random SUBSET in a uniformly
    for i = k + 1, n do
        out[i] = nil
    end
    return out
end

--- Weighted choice. Cumulative weights plus a binary search, O(log n) per draw and O(n)
--- @param entries table  array of tables with `.weight` (number, may be
--- @param rng table|function|nil
--- @return any  the chosen `.value`, or nil when the list is empty, has no
function M.weighted(entries, rng)
    if type(entries) ~= 'table' then
        return nil
    end
    local n = #entries
    if n < 1 then
        return nil
    end

    -- Cumulative array first, then one uniform draw, then a search.
local cumulative = {}
    local last = 0
    local guaranteed
    for i = 1, n do
        local e = entries[i]
        local w = type(e) == 'table' and e.weight or nil
        if type(w) == 'number' and w > 0 then
            -- An infinite weight is a config saying "always this one", and it is
            if w == math.huge or last + w == math.huge then
                guaranteed = i
                break
            end
            last = last + w
            cumulative[i] = last
        else
            cumulative[i] = last
        end
    end

    if not guaranteed then
        if last <= 0 then
            return nil
        end
        local target = rand01(rng) * last
        -- Largest i with cumulative[i] <= target, over 1..n.
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
        guaranteed = lo
    end

    local e = entries[guaranteed]
    if type(e) ~= 'table' then
        return nil
    end
    -- An entry without a `value` field is its own value, so a weight list of plain
    if e.value ~= nil then
        return e.value
    end
    return e
end

--- Index of a weighted choice, for callers that keep weights and values in parallel
--- @param weights
--- @param rng
--- @return number|nil  1-based index, or nil when the total weight is 0
function M.weightedIndex(weights, rng)
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
            if w == math.huge or last + w == math.huge then
                return i
            end
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

--- Normally distributed value, mean 0 and standard deviation 1 unless told otherwise.
--- @param mean number|nil                default 0
--- @param standardDeviation number|nil  default 1
--- @param rng table|function|nil        LAST and optional, like every rng
--- @return number  mean + z * standardDeviation
function M.gaussian(mean, standardDeviation, rng)
    -- Legacy form: gaussian(rng, mean, standardDeviation).
    if type(mean) == 'function'
        or (type(mean) == 'table' and type(mean.float) == 'function') then
        rng, mean, standardDeviation = mean, standardDeviation, rng
    end
    mean = mean or 0
    standardDeviation = standardDeviation or 1
    -- A draw of exactly 0 makes log(0) -inf and the whole result NaN, which then
    local u1 = rand01(rng)
    if u1 < 1e-12 then u1 = 1e-12 end
    local u2 = rand01(rng)
    local radius = math.sqrt(-2 * math.log(u1))
    local angle = 2 * math.pi * u2
    return mean + radius * math.cos(angle) * standardDeviation
end

-- A MODULE, NOT A GLOBAL.
if ... ~= 'cis_require' then
    CisRandom = M
end

return M
