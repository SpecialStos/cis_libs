-- Randomness: shuffling, unbiased integers, weighted choice, and a seedable generator.

local M = {}

-- MRG32k3a (L'Ecuyer 1999), in exact double arithmetic: every product below is
-- under 2^53, so fengari and Lua 5.4 produce the same stream bit for bit. The
-- constants are floats on purpose: fengari integers are 32 bits and wrap.
-- It replaces MINSTD, whose streams for seeds k and 1 were the same stream times
-- k: seeds 1 and 2 drew b == 2a (mod 1) on every draw.
local M1 = 4294967087.0
local M2 = 4294944443.0
local A12 = 1403580.0
local A13N = 810728.0
local A21 = 527612.0
local A23N = 1370589.0
-- The seed is mixed by cubing modulo M1. M1 is prime and 3 does not divide
-- M1 - 1, so cubing permutes 0 .. M1-1: a nonlinear map with no collisions.
local SEED_STEP = 2654435769.0
local SEED_IV = 625341585.0

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
    if lo > hi then
        lo, hi = hi, lo
    end
    -- INWARD, not outward: the integers inside [1.5, 3.5] are 2 and 3. Rounding
    -- lo down and hi up drew 1 and 4 as well, outside the range asked for.
    lo = math.ceil(lo)
    hi = math.floor(hi)
    if lo > hi then
        return nil, 'there is no integer between the bounds'
    end
    return lo, hi
end

-- How many integers [lo, hi] holds, or nil when that is more than 2^53. Counted
-- WITHOUT TRUSTING THE SUBTRACTION: on integers `hi - lo + 1` wraps, so
-- integer(0, math.maxinteger) counted -2^63 values and always drew 0, and
-- integer(math.mininteger, math.maxinteger) counted 0 and always drew mininteger.
-- With hi >= lo the true difference is never negative, so a negative one wrapped,
-- and is taken again in floats: past 2^63 that is too wide anyway, and on a
-- 32-bit integer runtime it is the exact count of a range wider than 2^31.
local function countOf(lo, hi)
    local d = hi - lo
    if d < 0 then
        d = (hi + 0.0) - (lo + 0.0)
    end
    local n = d + 1
    if n <= 0 then
        n = d + 1.0
    end
    if n > TWO53 then
        return nil
    end
    return n
end

local function tooWide(lo, hi, level)
    error(('CisRandom: the range %s to %s holds more than the 2^53 values a double holds exactly')
        :format(tostring(lo), tostring(hi)), level + 1)
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
-- A rejected draw is redrawn at worst about half the time, so 64 redraws leave 2^-64 of
-- the draws to the fold below; 8 left 1 in 512, all landing on one end of the range.
local MAX_RETRIES = 64

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
    if lo == hi then
        return lo
    end
    if type(rng) == 'table' and type(rng.int) == 'function' then
        return rng:int(lo, hi)
    end
    if rng == nil then
        -- math.random(lo, hi) is already unbiased: it is a modulus-rejection, and
        -- in Lua 5.4 it spans the whole integer range, so no count is needed.
        return math.random(lo, hi)
    end
    local n = countOf(lo, hi)
    if not n then
        tooWide(lo, hi, 3)
    end
    -- A single rand01 draw addresses 2^32.
    local span = TWO32
    if n > span then
        span = TWO53
    end
    return lo + (drawBelow(rng, n, span) % n)
end

-- A uniform draw in [0, scale), scale a power of two, from one raw draw. next()
-- yields M1 values, not a power of two, so a draw at or past the largest
-- multiple of scale is redrawn.
local function nextBits(gen, scale)
    local limit = math.floor(M1 / scale) * scale
    local r, retries = gen:next() - 1, 0
    while r >= limit and retries < MAX_RETRIES do
        r = gen:next() - 1
        retries = retries + 1
    end
    return r % scale
end

-- The same 2^53 assembly for a generator object: 27 high bits, then 26 low.
local function nextWide(gen)
    -- Float constants: in fengari 2^27 * 2^26 on integers wraps at 32 bits.
    return nextBits(gen, 134217728.0) * 67108864.0 + nextBits(gen, 67108864.0)  -- 0 .. 2^53 - 1
end

-- a * b mod m, exactly, for a and b below 2^32: b is split into 16-bit halves
-- so no product reaches 2^53. `a` is always a float here (SEED_STEP is one), so
-- fengari never multiplies two 32-bit integers.
local function mulmod(a, b, m)
    local bh = math.floor(b / 65536)
    local bl = b % 65536
    return ((a * bh) % m * 65536 + a * bl) % m
end

local function absorb(h, w)
    local x = (h + w + SEED_STEP) % M1
    return mulmod(mulmod(x, x, M1), x, M1)
end

-- Hash a seed into the six state words. Every word of the seed goes through the
-- cube, so neighbouring seeds land on unrelated states: no seed is a multiple,
-- shift or reflection of another.
local function seedState(seed)
    local negative = seed < 0
    local a = negative and -seed or seed
    local whole = math.floor(a)
    -- 32 bits of the fraction, so 1 and 1.7 are different seeds.
    local frac = math.floor((a - whole) * TWO32)
    local lo = whole % TWO32
    local hi = math.floor(whole / TWO32)
    -- 16-bit pieces, each below M1, so 0 and M1 do not fold onto one word.
    local h = SEED_IV
    h = absorb(h, lo % 65536)
    h = absorb(h, math.floor(lo / 65536))
    h = absorb(h, hi)
    h = absorb(h, frac % 65536)
    h = absorb(h, math.floor(frac / 65536))
    h = absorb(h, negative and 1 or 0)
    local state = {}
    for k = 1, 6 do
        h = absorb(h, k)
        state[k] = k <= 3 and h or h % M2
    end
    -- Each component needs one nonzero word, or it stays at zero forever.
    if state[1] == 0 and state[2] == 0 and state[3] == 0 then state[1] = 1.0 end
    if state[4] == 0 and state[5] == 0 and state[6] == 0 then state[4] = 1.0 end
    return state
end

--- A seeded, reproducible generator (MRG32k3a, the seed mixed nonlinearly; the same stream in Lua 5.4 and fengari).
---@param seed? number  any number. Fractions, negatives and magnitudes
---@return table  { next, float, int, range }
function M.newGenerator(seed)
    if type(seed) ~= 'number' or seed ~= seed or math.abs(seed) >= 1e18 then
        -- A nil or nonsense seed still has to produce a usable generator, or every
        seed = 12345
    end

    local gen = { state = seedState(seed) }

    --- Next raw value, 1 .. M1 (4294967087).
    function gen:next()
        local s = self.state
        local p1 = (A12 * s[2] - A13N * s[1]) % M1
        s[1], s[2], s[3] = s[2], s[3], p1
        local p2 = (A21 * s[6] - A23N * s[4]) % M2
        s[4], s[5], s[6] = s[5], s[6], p2
        local z = (p1 - p2) % M1
        if z == 0 then
            z = M1
        end
        return math.floor(z)
    end

    --- Float in (0, 1). Never returns exactly 1, so `(float() * n)` is never n.
    function gen:float()
        return self:next() / (M1 + 1)
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
        local n = countOf(a, b)
        if not n then
            tooWide(a, b, 2)
        end
        if n <= M1 then
            -- next() yields 1 .. M1, so the largest multiple of n in that range is
            local limit = M1 - (M1 % n)
            local v, retries = self:next(), 0
            while v > limit and retries < MAX_RETRIES do
                v = self:next()
                retries = retries + 1
            end
            if v > limit then
                v = v - 1 - ((v - 1 - limit) % n)
            end
            return a + math.floor((v - 1) % n)
        end

        -- Wider than one period. This used to fall into the branch above with `limit`
        local limit = TWO53 - (TWO53 % n)
        local v, retries = nextWide(self), 0
        while v >= limit and retries < MAX_RETRIES do
            v = nextWide(self)
            retries = retries + 1
        end
        if v >= limit then
            v = v - (v - limit) % n
        end
        return a + math.floor(v % n)
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
--- @raise  when a bound is not a number -- a mistake in the caller's code, which
---@param lo number
---@param hi number
---@param rng? table|fun(): number  see the header; nil uses math.random
---@return integer|nil  the draw
---@return string|nil  why, when the range is NaN, infinite or holds no integer
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
--- @raise  when a bound is not a number
---@param min number
---@param max number
---@param rng? table|fun(): number
---@return number|nil  the draw, in [min, max)
---@return string|nil  why, when a bound is NaN or infinite
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
---@param list table  any array; modified in place and returned
---@param rng? table|fun(): number
---@return table|nil  the same table, shuffled in place
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
---@param list table
---@param rng? table|fun(): number
---@return any  nil for an empty list
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
---@param list table
---@param k number  floored, then clamped to [0, #list]
---@param rng? table|fun(): number
---@return table  a NEW array of floor(k) distinct elements
function M.sample(list, k, rng)
    local out = {}
    if type(list) ~= 'table' then
        return out
    end
    local n = #list
    if type(k) ~= 'number' or k ~= k or k < 0 then
        return out
    end
    -- Whole elements only. A fractional k drew floor(k) and then cleared the
    -- tail from k + 1, which for k = 2.5 cleared 3.5, 4.5, ... -- keys that do
    -- not exist -- and handed back the whole list.
    k = math.floor(k)
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
---@param entries table  array of tables with `.weight` (number, may be
---@param rng? table|fun(): number
---@return any  the chosen .value (or entry), or nil
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
---@param weights number[]
---@param rng? table|fun(): number
---@return integer|nil  1-based index, or nil when the total weight is 0
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
---@param mean? number  default 0
---@param standardDeviation? number  default 1
---@param rng? table|fun(): number  LAST and optional, like every rng
---@return number  mean + z * standardDeviation
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
