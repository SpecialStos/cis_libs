-- Rolling windows: a fixed-capacity ring, a time-based de-duplicator, and a sliding
-- count/min/max/mean aggregator.

local M = {}


-- `table.remove(t, 1)` on a Lua array is O(n): every remaining element shifts down one
--- A fixed-capacity ring of the last N pushes.
--- @param capacity number  slots; below 1 becomes 1. A capacity-0 ring cannot
--- @return table  { kind, capacity, size, start, values, times }
function M.new(capacity)
    local cap = 1
    if type(capacity) == 'number' and capacity == capacity and capacity >= 1 then
        cap = math.floor(capacity)
    end
    return {
        kind = 'ring',
        capacity = cap,
        size = 0,
        start = 1,        -- index of the OLDEST live entry
        values = {},
        times = {},
    }
end

-- The invariant, in one line: the `size` live entries occupy the contiguous run that
local function slotAt(w, offset)
    return ((w.start - 1 + offset) % w.capacity) + 1
end

--- Append a value, overwriting the oldest one when the ring is full.
--- @param value any
--- @param time number|nil  recorded alongside the value; `pop` and `each`
--- @param w
--- @return any  the value that was pushed, for chaining
function M.push(w, value, time)
    local i = slotAt(w, w.size)
    w.values[i] = value
    w.times[i] = time
    if w.size < w.capacity then
        w.size = w.size + 1
    else
        -- Full: the slot just written was the oldest, so `start` advances past it.
        w.start = i + 1
        if w.start > w.capacity then
            w.start = 1
        end
    end
    return value
end

--- Remove and return the OLDEST value.
--- @param w
--- @return any, any  value, time -- nil, nil when the ring is empty
function M.pop(w)
    if w.size < 1 then
        return nil, nil
    end
    local i = w.start
    local value, time = w.values[i], w.times[i]
    w.values[i] = nil
    w.times[i] = nil
    w.size = w.size - 1
    w.start = i + 1
    if w.start > w.capacity then
        w.start = 1
    end
    return value, time
end

--- The newest value without removing it.
--- @param w
--- @return any, any  value, time; nil, nil when empty
function M.newest(w)
    if w.size < 1 then
        return nil, nil
    end
    local i = slotAt(w, w.size - 1)
    return w.values[i], w.times[i]
end

--- The oldest value without removing it.
--- @param w
--- @return any, any  value, time; nil, nil when empty
function M.oldest(w)
    if w.size < 1 then
        return nil, nil
    end
    return w.values[w.start], w.times[w.start]
end

--- Walk from oldest to newest, calling `fn(value, time, index)`.
--- @param w
--- @param fn
--- @return number  how many entries were visited
function M.each(w, fn)
    if type(fn) ~= 'function' then
        return 0
    end
    local n = w.size
    for k = 0, n - 1 do
        local i = slotAt(w, k)
        fn(w.values[i], w.times[i], k + 1)
    end
    return n
end

--- Empty the ring, keeping its allocated capacity.
--- @param w
--- @return nil  it empties the ring in place
function M.clear(w)
    for i = 1, w.capacity do
        w.values[i] = nil
        w.times[i] = nil
    end
    w.size = 0
    w.start = 1
end


--- A per-key "seen recently" filter over a time window.
--- @param windowSec number  how long a key stays "seen" after a hit. Below 1
--- @return table  { windowSec, entries, size }
function M.newDedupe(windowSec)
    local w = windowSec
    if type(w) ~= 'number' or w ~= w or w < 1 then
        w = 1
    end
    return {
        kind = 'dedupe',
        windowSec = w,
        entries = {},   -- key -> last seen time
        size = 0,
    }
end

--- Would this key be ACCEPTED right now?
--- @param d
--- @param key
--- @param now
--- @return boolean  true the first time a key is seen and again once its
function M.seen(d, key, now)
    -- A non-numeric or NaN `now` is REFUSED, not coerced.
    if type(now) ~= 'number' or now ~= now then
        return false
    end
    local last = d.entries[key]
    if last == nil or now - last >= d.windowSec or now < last then
        d.entries[key] = now
        if last == nil then
            d.size = d.size + 1
        end
        return true
    end
    return false
end

--- Is a key currently inside its window?
--- @param d
--- @param key
--- @param now
--- @return boolean
function M.isSeen(d, key, now)
    local last = d.entries[key]
    if last == nil then
        return false
    end
    if now < last then
        return false
    end
    return (now - last) < d.windowSec
end

--- Forget a key entirely, so the next `seen` accepts it regardless of the window.
--- @param d
--- @param key
--- @return nil  it mutates the stats in place; a key that was not present is a no-op
function M.reset(d, key)
    if d.entries[key] ~= nil then
        d.entries[key] = nil
        d.size = d.size - 1
    end
end

--- Drop every key whose window has expired.
--- @param d
--- @param now
--- @return number  how many keys were reclaimed
function M.prune(d, now)
    local removed = 0
    for key, last in pairs(d.entries) do
        if now - last >= d.windowSec or now < last then
            d.entries[key] = nil
            removed = removed + 1
        end
    end
    d.size = d.size - removed
    return removed
end

--- How many keys are being tracked, including expired ones not yet pruned.
--- @param d
--- @return number
function M.dedupeCount(d)
    return d.size
end


-- The exact answer needs every sample in the window, so the obvious structure is a
--- Count / min / max / sum / mean over a trailing time window, per key.
--- @param windowSec number  length of the trailing window
--- @param bucketSec number|nil  slice width, default 1. Clamped to at most
--- @return table  the aggregator
function M.newStats(windowSec, bucketSec)
    local window = windowSec
    if type(window) ~= 'number' or window ~= window or window <= 0 then
        window = 60
    end
    local bucket = bucketSec
    if type(bucket) ~= 'number' or bucket ~= bucket or bucket <= 0 then
        bucket = 1
    end
    if bucket > window then
        bucket = window
    end
    -- THE LOWER CLAMP, documented in the header since it was written and absent from
    local floorWidth = window / 1000
    if bucket < floorWidth then
        bucket = floorWidth
    end
    local count = math.ceil(window / bucket)
    if count < 1 then count = 1 end
    return {
        kind = 'stats',
        windowSec = window,
        bucketSec = bucket,
        bucketCount = count,
        entries = {},   -- key -> one ring, see record()
        size = 0,
    }
end

-- The absolute time-bucket index that a ring position holds.
local function bucketAt(entry, i, ringSize)
    return entry.lastBucket - ((entry.idx - i) % ringSize)
end

-- Is the bucket at ring position `i` inside the window ending at `now`?
local function bucketLive(entry, i, stats, cutoffBucket)
    local c = entry.counts[i]
    if not c or c <= 0 then
        return nil
    end
    if bucketAt(entry, i, stats.bucketCount) < cutoffBucket then
        return nil
    end
    return c
end

--- Add a value to a key's window.
--- @param value number  non-numeric values and NaN are IGNORED rather than
--- @param stats
--- @param key
--- @param now
--- @return boolean  whether the sample was recorded
function M.record(stats, key, value, now)
    if type(value) ~= 'number' or value ~= value then
        return false
    end
    if type(now) ~= 'number' or now ~= now then
        return false
    end

    local ringSize = stats.bucketCount
    local entry = stats.entries[key]
    if not entry then
        entry = {
            idx = 0,        -- ring cursor: the position of the newest bucket
            lastBucket = -1, -- absolute index of the newest bucket
            sums = {}, counts = {}, mins = {}, maxs = {}, lasts = {},
        }
        stats.entries[key] = entry
        stats.size = stats.size + 1
    end

    -- Absolute bucket index, so a step forward in time is seen as "the buckets in
    local bucketIndex = math.floor(now / stats.bucketSec)
    -- INVARIANT: `entry.idx` is the ring slot holding the NEWEST bucket.
    local function clearSlot(i)
        entry.sums[i] = nil
        entry.counts[i] = nil
        entry.mins[i] = nil
        entry.maxs[i] = nil
        entry.lasts[i] = nil
    end

    if entry.lastBucket < 0 then
        entry.lastBucket = bucketIndex
        entry.idx = 1
    elseif bucketIndex ~= entry.lastBucket then
        local steps = bucketIndex - entry.lastBucket
        if steps >= ringSize then
            -- Wider than the whole ring: every bucket is stale, and zeroing them one
            for i = 1, ringSize do
                clearSlot(i)
            end
            entry.idx = 1
        else
            for _ = 1, steps do
                entry.idx = entry.idx % ringSize + 1
                clearSlot(entry.idx)
            end
        end
        entry.lastBucket = bucketIndex
    end

    local i = entry.idx
    entry.sums[i] = (entry.sums[i] or 0) + value
    entry.counts[i] = (entry.counts[i] or 0) + 1
    local mn, mx = entry.mins[i], entry.maxs[i]
    if mn == nil or value < mn then entry.mins[i] = value end
    if mx == nil or value > mx then entry.maxs[i] = value end
    entry.lasts[i] = now
    return true
end

--- Read a key's window.
--- @param stats
--- @param key
--- @param now
--- @return table|nil  { count, sum, mean, min, max, last }, or nil when the key
function M.read(stats, key, now)
    local entry = stats.entries[key]
    if not entry or type(now) ~= 'number' or now ~= now then
        return nil
    end
    local cutoffBucket = math.floor((now - stats.windowSec) / stats.bucketSec)
    local total, sum = 0, 0
    local minV, maxV, lastT
    for i = 1, stats.bucketCount do
        local c = bucketLive(entry, i, stats, cutoffBucket)
        if c then
            total = total + c
            sum = sum + entry.sums[i]
            local mn, mx = entry.mins[i], entry.maxs[i]
            if minV == nil or mn < minV then minV = mn end
            if maxV == nil or mx > maxV then maxV = mx end
            local lt = entry.lasts[i]
            if lastT == nil or lt > lastT then lastT = lt end
        end
    end
    if total < 1 then
        return nil
    end
    return {
        count = total,
        sum = sum,
        mean = sum / total,
        min = minV,
        max = maxV,
        last = lastT,
    }
end

--- The number of live SAMPLES for `key` inside the window.
--- @param stats
--- @param key
--- @param now
--- @return number
function M.samples(stats, key, now)
    local entry = stats.entries[key]
    if not entry or type(now) ~= 'number' or now ~= now then
        return 0
    end
    local cutoffBucket = math.floor((now - stats.windowSec) / stats.bucketSec)
    local total = 0
    for i = 1, stats.bucketCount do
        local c = bucketLive(entry, i, stats, cutoffBucket)
        if c then
            total = total + c
        end
    end
    return total
end

--- @deprecated  use `samples`. Kept because this is a minor version and a
M.count = M.samples

--- Largest or smallest live sample, without building the result table.
--- @param wantMax boolean|nil  true for the max, false or nil for the min
--- @param stats
--- @param key
--- @param now
--- @return number|nil  nil when there is no live sample
function M.extreme(stats, key, now, wantMax)
    local entry = stats.entries[key]
    if not entry or type(now) ~= 'number' or now ~= now then
        return nil
    end
    local cutoffBucket = math.floor((now - stats.windowSec) / stats.bucketSec)
    local best
    for i = 1, stats.bucketCount do
        if bucketLive(entry, i, stats, cutoffBucket) then
            local v
            if wantMax then v = entry.maxs[i] else v = entry.mins[i] end
            if best == nil or (wantMax and v > best) or (not wantMax and v < best) then
                best = v
            end
        end
    end
    return best
end

--- Drop keys with no live sample.
--- @param stats
--- @param now
--- @return number  how many keys were reclaimed
function M.pruneStats(stats, now)
    if type(now) ~= 'number' or now ~= now then
        return 0
    end
    local cutoffBucket = math.floor((now - stats.windowSec) / stats.bucketSec)
    local removed = 0
    for key, entry in pairs(stats.entries) do
        local live = false
        for i = 1, stats.bucketCount do
            if bucketLive(entry, i, stats, cutoffBucket) then
                live = true
                break
            end
        end
        if not live then
            stats.entries[key] = nil
            removed = removed + 1
        end
    end
    stats.size = stats.size - removed
    return removed
end

-- A MODULE, NOT A GLOBAL.
if ... ~= 'cis_require' then
    CisWindow = M
end

return M
