-- Rate limiting: fixed window, sliding window counter, token bucket.

local M = {}

local function positive(n, fallback)
    if type(n) ~= 'number' or n ~= n or n <= 0 then
        return fallback
    end
    return n
end

-- Validate `now`. A limiter that is fed a string or nil would otherwise compare it
local function clock(now)
    if type(now) ~= 'number' or now ~= now then
        return 0
    end
    return now
end


--- A counter that resets on an aligned boundary.
--- @param opts
--- @return table  the limiter
function M.newFixed(opts)
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

-- Advance a fixed-window key to `now`, returning its current window start and end.
local function fixedWindow(r, entry, now)
    if r.anchored then
        if entry.start == nil then
            entry.start = now
            entry.used = 0
        elseif now >= entry.start + r.windowSec then
            -- Jump by whole windows in one step.
            local windows = math.floor((now - entry.start) / r.windowSec)
            entry.start = entry.start + windows * r.windowSec
            -- NO FOLD BACK INTO ONE WINDOW.
            entry.used = 0
        end
    else
        local index = math.floor(now / r.windowSec)
        if entry.index == nil then
            entry.index = index
            entry.used = 0
        elseif index > entry.index then
            -- Move forward only. A clock that goes BACKWARDS must not roll the window
            entry.index = index
            entry.used = 0
        end
        entry.start = entry.index * r.windowSec
    end
    return entry.start, entry.start + r.windowSec
end


--- A two-bucket sliding window estimate.
--- @param opts
--- @return table  the limiter
function M.newSliding(opts)
    opts = opts or {}
    local sub = math.floor(positive(opts.subdivisions, 10))
    if sub < 1 then sub = 1 end
    local window = positive(opts.windowSec, 1)
    return {
        kind = 'sliding',
        limit = math.floor(positive(opts.limit, 10)),
        windowSec = window,
        sliceSec = window / sub,
        -- Stored on the limiter because `sumSlices` needs both and is called from
        subdivisions = sub,
        -- One slot MORE than there are slices in the window: the window is `sub` slices
        ringSize = sub + 1,
        keys = {},
        size = 0,
    }
end

-- Roll a sliding key forward to `now`, returning the weighted estimate.
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

    -- A clock that went backwards.
    local elapsed = now - entry.startedAt
    if elapsed < 0 then
        entry.startedAt = now
        return sumSlices(r, entry, 0)
    end

    -- Advance the cursor one whole slice at a time, zeroing what it steps over.
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


--- A continuously refilling bucket.
--- @param opts
--- @return table  the limiter
function M.newTokenBucket(opts)
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
        -- Clock went backwards. Re-baseline without adding tokens: a negative elapsed
        entry.updatedAt = now
    end
    return entry.tokens
end


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
--- @param cost number|nil  events to spend, default 1. Must be >= 1; a
--- @param r
--- @param key
--- @param now
--- @return boolean  true when the action is allowed. A refusal leaves the
function M.allow(r, key, now, cost)
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
--- @param r
--- @param key
--- @param now
--- @return table  { allowed, remaining, limit, retryAfter, resetAt }
function M.peek(r, key, now)
    now = clock(now)
    local e = r.keys[key]
    if not e then
        -- An unknown key is a key with its full allowance: a fixed or sliding window
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
        -- The estimate falls by `limit / windowSec` per second on average, so that is
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
--- @param r
--- @param key
--- @return nil  it mutates the limiter in place; a key that was not present is a no-op
function M.reset(r, key)
    if r.keys[key] ~= nil then
        r.keys[key] = nil
        r.size = r.size - 1
    end
end

--- Forget every key.
--- @param r
--- @return nil  it mutates the limiter in place
function M.clear(r)
    r.keys = {}
    r.size = 0
end

--- Drop keys that have not been touched for `idleSec`.
--- @param idleSec number|nil  defaults to a full window (or, for a token
--- @param r
--- @param now
--- @return number  how many keys were reclaimed
function M.prune(r, now, idleSec)
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
        -- A key whose clock reference is in the future has been re-baselined this call;
        if now - touchedAt >= idle then
            r.keys[key] = nil
            removed = removed + 1
        end
    end
    r.size = r.size - removed
    return removed
end

--- How many keys the limiter is tracking, including fully restored ones that have not
--- @param r
--- @return number
function M.count(r)
    return r.size
end

-- A MODULE, NOT A GLOBAL.
if ... ~= 'cis_require' then
    CisRate = M
end

return M
