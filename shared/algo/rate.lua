-- Rate limiting: fixed window, sliding window counter, token bucket.
--
-- PURE. The limiter is a value, the clock is an argument, and nothing here
-- reads GetGameTimer or os.time. `now` is in seconds from any monotonic source.
--
-- WHY THREE, AND WHY THEY ARE NOT INTERCHANGEABLE
--
-- They differ in ONE thing that matters: what happens at the window boundary.
-- Everything else -- the limit, the window, the memory per key -- is the same
-- argument three times. A limiter with the wrong boundary behaviour is the
-- classic "the exploit only works at the top of the second" bug report.
--
--   FIXED WINDOW   counts inside aligned windows. Simplest thing that works:
--                  one integer per key, no division, no floating point, and
--                  the arithmetic is exact. Its boundary is a CLIFF: a client
--                  that spends its whole budget in the last millisecond of one
--                  window and its whole budget in the first millisecond of the
--                  next gets 2x the limit inside a 2ms span. That is not a
--                  rounding artefact, it is the defining property, and it is
--                  why a fixed window is the wrong limiter for anything an
--                  attacker is choosing when to send.
--
--   SLIDING        an estimate from two adjacent windows, weighted by how far
--     COUNTER      through the current one we are. Removes the cliff: the count
--                  decays smoothly instead of resetting. Costs O(1) memory and
--                  one multiply. Its error is bounded by the subdivision: it
--                  cannot see a burst that happened entirely inside the
--                  previous window, so a determined attacker still gets up to
--                  2x at a boundary, just over a much smaller interval. That
--                  is the price of not storing every timestamp, and it is a
--                  real price, not a rounding one.
--
--   TOKEN BUCKET   a bucket that refills at a constant rate up to a capacity.
--                  No window at all, so there is no boundary and no boundary
--                  exploit. It ALLOWS a burst of up to `capacity` on top of the
--                  sustained rate, which is the behaviour almost every real
--                  limit wants: a player who fires a shotgun and then switches
--                  to a pistol has not violated anything.
--
-- WHICH ONE
--
--   Rate limiting a player's own actions (chat, commands, interaction spam)
--       -> TOKEN BUCKET. Burst is legitimate, boundary is not.
--   Throttling your OWN server (a database query, an outbound webhook) so one
--   player cannot make the server do 50k of them
--       -> TOKEN BUCKET with capacity == limit, which is a hard smooth rate.
--   Anti-cheat / anti-replay where an attacker picks the timing
--       -> SLIDING COUNTER, and set the subdivision to 1/10th of the window so
--          the boundary hole is 100ms wide rather than a second wide.
--   Counting "how many per second" for a metric, where the answer is a number
--   and not a decision
--       -> FIXED WINDOW. Nothing else does it with less code.
--
-- WHAT NONE OF THEM DO
--
-- A rejected request does NOT consume budget. That is deliberate: if a client
-- is being throttled because it is reconnecting in a loop, counting the
-- rejected attempts would extend the lockout every time the client retries and
-- the player would be locked out for as long as they kept trying. The
-- consequence is that a flooder is limited to `limit` ALLOWED actions and an
-- unbounded number of refused ones, so a limiter is not a defence against
-- packet flooding -- it is a defence against the CONSEQUENCE of a flood. If the
-- work happens before the check, move the check earlier.
--
-- MEMORY
--
-- O(keys). There is a `prune` for exactly the reason there has to be: a
-- limiter keyed by server id that is never swept is a table that grows by one
-- entry per player who ever connects, for the lifetime of the process.

CisRate = {}

local function positive(n, fallback)
    if type(n) ~= 'number' or n ~= n or n <= 0 then
        return fallback
    end
    return n
end

-- Validate `now`. A limiter that is fed a string or nil would otherwise
-- compare it against numbers forever and silently never expire anything, so
-- the failure is turned into a number up front.
local function clock(now)
    if type(now) ~= 'number' or now ~= now then
        return 0
    end
    return now
end

-- ============================================================ FIXED WINDOW

--- A counter that resets on an aligned boundary.
---
--- opts:
---   limit      number  events allowed per window. Must be >= 1.
---   windowSec  number  window length in seconds. Must be > 0.
---   anchored   boolean|nil  false by default. See below.
---
--- `anchored` is the one non-obvious option. The default window is ALIGNED to
--- the clock -- [0, 1), [1, 2), [2, 3) -- and that alignment is exactly what
--- creates the 2x burst. With `anchored = true` the window starts at the first
--- event instead, so a client that spends its budget in the last 1ms of a window
--- cannot start a fresh one until a full window later. Windows after the first
--- advance by whole windows rather than restarting at `now`, so the boundary
--- does not drift later and later with every restart.
---
--- The cost: two clients that start at different times are limited on
--- different boundaries, so a coordinated attack from two accounts no longer
--- shares a reset point. For a single-client limit that is a fair trade; for a
--- "how many events per second is this SERVER sending" metric it is not, and
--- the default is right.
---@param opts
--- @return table  the limiter
function CisRate.newFixed(opts)
    opts = opts or {}
    return {
        kind = 'fixed',
        limit = math.floor(positive(opts.limit, 10)),
        windowSec = positive(opts.windowSec, 1),
        anchored = opts.anchored and true or false,
        keys = {},
        size = 0,
    }
end

-- Advance a fixed-window key to `now`, returning its current window start and
-- end. Anchored windows move by whole windows so the boundary does not drift.
local function fixedWindow(r, entry, now)
    if r.anchored then
        if entry.start == nil then
            entry.start = now
            entry.used = 0
        elseif now >= entry.start + r.windowSec then
            -- Jump by whole windows in one step. A `while` loop here is correct
            -- and is a hang: with a 0.1s window and a key that was idle for an
            -- hour it would run 36000 times to do arithmetic that is two
            -- operations.
            local windows = math.floor((now - entry.start) / r.windowSec)
            entry.start = entry.start + windows * r.windowSec
            -- NO FOLD BACK INTO ONE WINDOW. There used to be a
            -- `entry.start = entry.start % r.windowSec` here, added to stop the
            -- anchor accumulating float error, and it quietly switched the
            -- limiter off. Folding maps the anchor into [0, W), which severs
            -- it from wall-clock time; the very next call then finds
            -- `now >= start + W` trivially true for any real `now`, resets
            -- `used` to zero, and lets the key spend again. A fixed window of 2
            -- per 10s, anchored, allowed 20 calls inside one 10s window.
            --
            -- The drift it was guarding against does not occur. `windows` is
            -- recomputed from the true elapsed time on every call and the
            -- anchor moves by whole multiples of W, so it never accumulates one
            -- float addition at a time -- and an anchor that has drifted is
            -- harmless anyway, because the only question ever asked of it is
            -- "has a whole window passed since this key last reset".
            entry.used = 0
        end
    else
        local index = math.floor(now / r.windowSec)
        if entry.index == nil then
            entry.index = index
            entry.used = 0
        elseif index > entry.index then
            -- Move forward only. A clock that goes BACKWARDS must not roll the
            -- window back with it: that would hand the key a fresh allowance,
            -- and the whole point of a limiter is that a client cannot get a
            -- second one by confusing the clock. The other two limiters here
            -- also refuse to go backwards, and a limiter that behaves
            -- differently depending on which one you picked is a limiter
            -- nobody can reason about.
            entry.index = index
            entry.used = 0
        end
        entry.start = entry.index * r.windowSec
    end
    return entry.start, entry.start + r.windowSec
end

-- ==================================================== SLIDING WINDOW COUNTER

--- A two-bucket sliding window estimate.
---
--- opts:
---   limit       number  events allowed per window. Must be >= 1.
---   windowSec   number  window length in seconds. Must be > 0.
---   subdivisions number|nil  how many slices the window is estimated at,
---        default 10. More slices means a narrower boundary hole and the same
---        O(1) memory -- only the resolution of the estimate changes. It does
---        NOT change the amount of state, so there is no reason to keep it
---        small.
---
--- The estimate at time `t` inside the current slice is
---
---     previous * (1 - progress) + current
--
--- which is continuous across a slice change: at the instant a slice ends,
--- progress is 1, the estimate is exactly `previous`, and on the next slice
--- `current` becomes `previous` and progress is 0 -- the same number. That
--- continuity is the entire point of this structure; the fixed window's
--- estimate is discontinuous at its boundary, which is its bug.
---@param opts
--- @return table  the limiter
function CisRate.newSliding(opts)
    opts = opts or {}
    local sub = math.floor(positive(opts.subdivisions, 10))
    if sub < 1 then sub = 1 end
    local window = positive(opts.windowSec, 1)
    return {
        kind = 'sliding',
        limit = math.floor(positive(opts.limit, 10)),
        windowSec = window,
        sliceSec = window / sub,
        -- Stored on the limiter because `sumSlices` needs both and is called
        -- from `peek` as well as from `allow`; reading them off the entry would
        -- mean every key carrying a copy.
        subdivisions = sub,
        -- One slot MORE than there are slices in the window: the window is `sub`
        -- slices wide, so `sub` of them are wholly inside it and one more is
        -- partly in. See sumSlices.
        ringSize = sub + 1,
        keys = {},
        size = 0,
    }
end

-- Roll a sliding key forward to `now`, returning the weighted estimate. The
-- caller decides what to do with it; this function never refuses anything.
--
-- A RING OF `sub` SLICES, not two buckets.
--
-- It used to keep exactly two numbers -- `previous` and `current` -- and weight
-- them by progress through the slice:
--
--     previous * (1 - progress) + current
--
-- That is the textbook sliding-window COUNTER, and it is wrong for the job this
-- module recommends it for. `current` is the number of events in the slice the
-- caller is inside RIGHT NOW, and it was compared against the whole `limit`.
-- The slice is a unit of RESOLUTION, not a unit of budget, so a caller that
-- placed `limit` events in every slice was never over the limit: with
-- limit=10, windowSec=1, subdivisions=10, a hundred evenly spaced calls inside
-- one second were allowed. This is the limiter the module tells you to use for
-- anti-cheat, and it enforced `limit` per tenth of a second.
--
-- The estimate is now the sum over every slice still inside the window, with the
-- oldest one weighted down by how far through it we are:
--
--     sum of the `sub - 1` full slices + oldest * (1 - progress)
--
-- which is continuous across a slice change for the same reason the old one was
-- -- at progress 1 the oldest slice's weight is 0, and on the next slice it has
-- left the window and contributes 0 instead. Memory is `sub` integers per key
-- rather than two, which is the price of the accuracy and is still O(1) in the
-- number of events rather than O(hits in window).
-- The estimate itself: every slice fully inside the window, whole, plus the one
-- that is only partly inside it, weighted by the fraction that is.
--
-- The ring holds `subdivisions + 1` slices rather than `subdivisions`, and that
-- extra slot is the whole correction. The window is `sub` slices WIDE, so at any
-- moment `sub` of them are fully inside it and a `sub+1`th is partly in. A ring
-- of exactly `sub` drops the oldest the instant the cursor moves, which decays
-- the estimate a whole slice early: with limit=10, windowSec=1 and ten slices, a
-- hundred evenly spread calls were allowed 18 times instead of 10, because the
-- first slice had stopped counting a tenth of a second before it had actually
-- left the window.
--
-- `entry.idx` is the slice we are inside, so slice `idx - d` is `d` slices old.
-- For d in 0..sub-1 it is wholly inside the window. For d == sub it is the
-- partial one, and `(1 - progress)` of it is still inside -- the same
-- continuity the two-bucket version had, at a finer resolution.
local function sumSlices(r, entry, progress)
    local counts = entry.counts
    local ring = r.ringSize
    local idx = entry.idx or 0
    local total = 0
    for d = 0, ring - 1 do
        local n = counts[(idx - d) % ring]
        if n and n > 0 then
            if d == r.subdivisions then
                total = total + n * (1 - progress)
            else
                total = total + n
            end
        end
    end
    return total
end

local function slidingCount(r, entry, now)
    if entry.startedAt == nil then
        entry.counts = {}
        entry.startedAt = now
    end
    local counts = entry.counts
    local sliceSec = r.sliceSec

    -- A clock that went backwards. Rewind rather than compute a negative
    -- weight, which would make the estimate negative and hand out free
    -- allowance.
    local elapsed = now - entry.startedAt
    if elapsed < 0 then
        entry.startedAt = now
        return sumSlices(r, entry, 0)
    end

    -- Advance the cursor one whole slice at a time, zeroing what it steps over.
    -- A `while` here is a hang: a key idle for an hour against a 0.1s slice
    -- would run 36000 times to do arithmetic that is one modulo.
    local steps = math.floor(elapsed / sliceSec)
    if steps > 0 then
        local ring = r.ringSize
        if steps >= ring then
            -- Wider than the whole ring: every slice is out of window.
            for i = 0, ring - 1 do counts[i] = nil end
        else
            for _ = 1, steps do
                entry.idx = (entry.idx + 1) % ring
                counts[entry.idx] = nil
            end
        end
        entry.startedAt = entry.startedAt + steps * sliceSec
    end

    local progress = (now - entry.startedAt) / sliceSec
    if progress < 0 then progress = 0 end
    if progress > 1 then progress = 1 end
    return sumSlices(r, entry, progress)
end

-- Spend into the current slice.
local function slidingSpend(_, entry, cost)
    entry.idx = entry.idx or 0
    entry.counts[entry.idx] = (entry.counts[entry.idx] or 0) + cost
end

-- ============================================================== TOKEN BUCKET

--- A continuously refilling bucket.
---
--- opts:
---   capacity      number  maximum burst. Must be >= 1. This is the whole
---        difference from the other two: capacity == limit is a hard smooth
---        rate, capacity much larger than the sustained rate is "you may
---        burst".
---   refillPerSec  number  sustained rate. Must be > 0.
---
--- There is no window and therefore no boundary. A client can never get 2x the
--- limit in a short span, because there is no point at which its allowance
--- resets. What it CAN do is spend the whole capacity at once, which is what
--- capacity is for. Set capacity to the limit if you do not want that.
---
--- A key starts with a FULL bucket, not an empty one. A player who has just
--- connected is not a flooder, and making them wait `capacity / refillPerSec`
--- seconds before their first action is a bug that gets reported as "the first
--- command after joining does nothing".
---@param opts
--- @return table  the limiter
function CisRate.newTokenBucket(opts)
    opts = opts or {}
    local capacity = positive(opts.capacity, 10)
    local refill = positive(opts.refillPerSec, capacity)
    return {
        kind = 'token',
        capacity = capacity,
        refillPerSec = refill,
        keys = {},
        size = 0,
    }
end

-- Fill a token bucket to `now`, returning the token count.
local function refillTokens(r, entry, now)
    if entry.tokens == nil then
        entry.tokens = r.capacity
        entry.updatedAt = now
        return entry.tokens
    end
    local elapsed = now - entry.updatedAt
    if elapsed > 0 then
        entry.tokens = math.min(r.capacity, entry.tokens + elapsed * r.refillPerSec)
        entry.updatedAt = now
    elseif elapsed < 0 then
        -- Clock went backwards. Re-baseline without adding tokens: a negative
        -- elapsed time must never REMOVE tokens, or a client that can influence
        -- the clock can freeze its own limiter.
        entry.updatedAt = now
    end
    return entry.tokens
end

-- ================================================================ THE API

local function entryFor(r, key)
    local e = r.keys[key]
    if not e then
        e = {}
        r.keys[key] = e
        r.size = r.size + 1
    end
    return e
end

--- Try to spend `cost` from a key's budget.
---
--- @param cost number|nil  events to spend, default 1. Must be >= 1; a
---        fractional or zero cost is treated as 1 rather than as a free action.
---@param r
---@param key
---@param now
--- @return boolean  true when the action is allowed. A refusal leaves the
---         budget untouched -- see the header for why.
function CisRate.allow(r, key, now, cost)
    now = clock(now)
    if type(cost) ~= 'number' or cost ~= cost or cost < 1 then
        cost = 1
    end
    local e = entryFor(r, key)

    if r.kind == 'fixed' then
        fixedWindow(r, e, now)
        if e.used + cost > r.limit then
            return false
        end
        e.used = e.used + cost
        return true

    elseif r.kind == 'sliding' then
        local estimate = slidingCount(r, e, now)
        if estimate + cost > r.limit then
            return false
        end
        slidingSpend(r, e, cost)
        return true

    else
        local tokens = refillTokens(r, e, now)
        if tokens < cost then
            return false
        end
        e.tokens = tokens - cost
        return true
    end
end

--- Inspect a key's budget WITHOUT spending from it.
---
--- This is the call that turns a throttle into a useful error: it gives the
--- client how long to wait, so a resource can send "slow down, 3 seconds"
--- instead of silently dropping the event. It refills the bucket as a side
--- effect -- the same side effect `allow` has -- but spends nothing.
---
---@param r
---@param key
---@param now
--- @return table  { allowed, remaining, limit, retryAfter, resetAt }
---         `remaining` is how many more of the same cost fit right now
---         `retryAfter` is seconds until one more fits; 0 when it already does
---         `resetAt` is when the budget is fully restored, or nil for a token
---         bucket that is already full
function CisRate.peek(r, key, now)
    now = clock(now)
    local e = r.keys[key]
    if not e then
        -- An unknown key is a key with its full allowance: a fixed or sliding
        -- window has spent nothing, and a token bucket starts FULL, which is
        -- what lets a joining player act immediately instead of waiting out a
        -- refill. `remaining` is the burst ceiling for a token bucket and the
        -- per-window limit for the other two, so it is kind-aware here.
        local budget = r.kind == 'token' and r.capacity or r.limit
        return {
            allowed = true, remaining = budget, limit = budget,
            retryAfter = 0, resetAt = nil,
        }
    end

    if r.kind == 'fixed' then
        local _, finish = fixedWindow(r, e, now)
        local remaining = r.limit - e.used
        if remaining < 0 then remaining = 0 end
        return {
            allowed = remaining >= 1,
            remaining = remaining,
            limit = r.limit,
            retryAfter = remaining >= 1 and 0 or (finish - now),
            resetAt = finish,
        }

    elseif r.kind == 'sliding' then
        local estimate = slidingCount(r, e, now)
        local remaining = r.limit - estimate
        if remaining < 0 then remaining = 0 end
        -- The estimate falls by `limit / windowSec` per second on average, so
        -- that is how long until one more fits. It is an estimate of an
        -- estimate; rounding UP is the safe direction for a "wait this long"
        -- message, because rounding down produces a retry that is refused
        -- again.
        local perSec = r.limit / r.windowSec
        local retry = 0
        if remaining < 1 and perSec > 0 then
            retry = (1 - remaining) / perSec
        end
        return {
            allowed = remaining >= 1,
            remaining = remaining,
            limit = r.limit,
            retryAfter = retry,
            resetAt = now + r.windowSec,
        }

    else
        local tokens = refillTokens(r, e, now)
        local remaining = tokens
        local retry = 0
        if remaining < 1 and r.refillPerSec > 0 then
            retry = (1 - remaining) / r.refillPerSec
        end
        return {
            allowed = remaining >= 1,
            remaining = remaining,
            limit = r.capacity,
            retryAfter = retry,
            resetAt = tokens >= r.capacity and now or (now + (r.capacity - tokens) / r.refillPerSec),
        }
    end
end

--- Forget one key entirely. The right call when a player disconnects.
---@param r
---@param key
--- @return nil  it mutates the limiter in place; a key that was not present is a no-op
function CisRate.reset(r, key)
    if r.keys[key] ~= nil then
        r.keys[key] = nil
        r.size = r.size - 1
    end
end

--- Forget every key.
---@param r
--- @return nil  it mutates the limiter in place
function CisRate.clear(r)
    r.keys = {}
    r.size = 0
end

--- Drop keys that have not been touched for `idleSec`.
---
--- A key is idle when its budget is completely restored, because a key that is
--- already full holds no information. That makes the default safe to run often
--- and it is why there is no lastSeen field to keep.
---
--- @param idleSec number|nil  defaults to a full window (or, for a token
---        bucket, to the time to refill the whole capacity)
---@param r
---@param now
--- @return number  how many keys were reclaimed
function CisRate.prune(r, now, idleSec)
    now = clock(now)
    local idle = idleSec
    if type(idle) ~= 'number' or idle ~= idle or idle <= 0 then
        if r.kind == 'token' then
            idle = r.capacity / r.refillPerSec
        else
            idle = r.windowSec
        end
    end

    local removed = 0
    for key, e in pairs(r.keys) do
        local touchedAt
        if r.kind == 'fixed' then
            touchedAt = e.start or now
        elseif r.kind == 'sliding' then
            touchedAt = e.startedAt or now
        else
            touchedAt = e.updatedAt or now
        end
        -- A key whose clock reference is in the future has been re-baselined
        -- this call; treat it as touched so a backwards clock cannot make
        -- prune() delete keys that are still live.
        if now - touchedAt >= idle then
            r.keys[key] = nil
            removed = removed + 1
        end
    end
    r.size = r.size - removed
    return removed
end

--- How many keys the limiter is tracking, including fully restored ones that
--- have not been pruned.
---@param r
--- @return number
function CisRate.count(r)
    return r.size
end
