-- Rolling windows: a fixed-capacity ring, a time-based de-duplicator, and a
-- sliding count/min/max/mean aggregator.
--
-- PURE. All three structures are values; every one of them takes `now` as an
-- argument and calls no clock of its own. A rolling window that reads
-- GetGameTimer() internally cannot be tested, and a rolling window is precisely
-- the kind of thing that is wrong at the boundary and never visibly wrong in
-- the middle.
--
-- Three structures because there are three different questions, and they have
-- different right answers:
--
--   ring      "what happened in the last N things"  -- bounded by COUNT.
--             Player activity, the last 10 chat lines, an input buffer.
--   dedupe    "have I seen this key recently" -- bounded by TIME, one slot per
--             key. Footstep sounds, notification spam, duplicate net events.
--   stats     "what is the count/min/max/mean over the last N seconds" --
--             bounded by TIME and by a FIXED number of buckets per key, no
--             matter how fast events arrive.
--
-- They share a file because they share a failure mode, which is the real reason
-- a rolling window is hard: what happens AT A BOUNDARY. A ring silently drops
-- the oldest item the moment a new one arrives, even if that item is one
-- millisecond old. A dedupe that only checks "is the last time within the
-- window" is exact. A stats window that keeps every sample grows without bound.
-- Each of the three below is explicit about where its boundary is.

CisWindow = {}

-- ============================================================== RING BUFFER

--- A fixed-capacity ring of the last N pushes.
---
--- WHY A RING AND NOT table.remove(t, 1)
---
-- `table.remove(t, 1)` on a Lua array is O(n): every remaining element shifts
-- down one slot. Doing that 60 times a second on a 64-slot buffer is 3840
-- element moves a second to implement a shift that a pointer increment does in
-- O(1). The ring writes over the oldest slot and keeps a cursor, so push is one
-- index wrap and two array writes, forever, at any capacity.
---
--- The memory is exactly `capacity` slots, allocated once. It never grows and
--- never shrinks -- a ring that could grow would not be a ring, and one that
--- reallocates on every push would be a table.
---
--- @param capacity number  slots; below 1 becomes 1. A capacity-0 ring cannot
---        hold anything and every push would be a no-op that the caller reads
---        as a working buffer, so 1 is the smallest honest answer.
--- @return table  { kind, capacity, size, start, values, times }
function CisWindow.new(capacity)
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

-- The invariant, in one line: the `size` live entries occupy the contiguous
-- run that starts at `start` and ends at the slot before the next write. The
-- next write therefore lands at `start + size`, wrapped.
--
-- The obvious alternative -- a cursor to the NEXT WRITE, with special cases for
-- "not yet full" -- is the version this file had first, and every one of those
-- special cases is a place where the oldest and the newest are computed
-- differently. `start` has no special cases at all: it is always the oldest,
-- and the newest is always size-1 places after it, whether the ring is full,
-- half full, or empty.
local function slotAt(w, offset)
    return ((w.start - 1 + offset) % w.capacity) + 1
end

--- Append a value, overwriting the oldest one when the ring is full.
---
--- The eviction is the overwrite: when the ring is full, the slot the write
--- lands on IS the oldest, so there is nothing to search for and nothing to
--- shift. That is the whole difference from a list.
---
--- @param value any
--- @param time number|nil  recorded alongside the value; `pop` and `each`
---        hand it back. A ring with no use for the timestamp is one fewer
---        number per slot, so it is optional rather than mandatory.
--- @return any  the value that was pushed, for chaining
function CisWindow.push(w, value, time)
    local i = slotAt(w, w.size)
    w.values[i] = value
    w.times[i] = time
    if w.size < w.capacity then
        w.size = w.size + 1
    else
        -- Full: the slot just written was the oldest, so `start` advances past
        -- it. `size` stays at capacity.
        w.start = i + 1
        if w.start > w.capacity then
            w.start = 1
        end
    end
    return value
end

--- Remove and return the OLDEST value.
--- @return any, any  value, time -- nil, nil when the ring is empty
function CisWindow.pop(w)
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
--- @return any, any  value, time; nil, nil when empty
function CisWindow.newest(w)
    if w.size < 1 then
        return nil, nil
    end
    local i = slotAt(w, w.size - 1)
    return w.values[i], w.times[i]
end

--- The oldest value without removing it.
--- @return any, any  value, time; nil, nil when empty
function CisWindow.oldest(w)
    if w.size < 1 then
        return nil, nil
    end
    return w.values[w.start], w.times[w.start]
end

--- Walk from oldest to newest, calling `fn(value, time, index)`.
---
--- The visitor must not push or pop: both move the write cursor and the walk
--- is standing on it. Same rule and the same reasoning as CisLRU.each.
--- @return number  how many entries were visited
function CisWindow.each(w, fn)
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
---
--- Deliberately NOT replacing the arrays: a ring is expected to be cleared and
--- refilled constantly (every second, per player), and a fresh table per clear
--- would be the single biggest allocator in a server that uses one. The slots
--- are nilled so a stale value cannot be read back.
function CisWindow.clear(w)
    for i = 1, w.capacity do
        w.values[i] = nil
        w.times[i] = nil
    end
    w.size = 0
    w.start = 1
end

-- ======================================================== SLIDING DEDUPE

--- A per-key "seen recently" filter over a time window.
---
--- This is the "do not process this twice" structure, and the whole problem is
--- when a key stops counting as seen.
---
--- The wrong version stores a count and decrements it by sweeping a list of
--- expiry times. The right version stores ONE number per key -- the last time
--- it was seen -- and answers "is (now - last) >= window". That is exact, O(1)
--- per call, and one table slot per key, and it needs no sweep to stay
--- correct. The sweep below exists only to RECLAIM the slot of a key that has
--- gone quiet, not to make the answer right.
---
--- @param windowSec number  how long a key stays "seen" after a hit. Below 1
---        second becomes 1; a sub-second window is a debounce, and a debounce
---        that can be configured to zero is a debounce that is not a debounce.
--- @return table  { windowSec, entries, size }
function CisWindow.newDedupe(windowSec)
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

--- Would this key be ACCEPTED right now? Records the hit.
---
--- @return boolean  true the first time a key is seen and again once its
---         window has expired; false while it is still inside the window.
---
--- A `now` that goes BACKWARDS -- a server clock correction, a caller that mixed
--- up seconds and milliseconds -- is treated as "long expired" and accepts the
--- key. That is the fail-open direction: a duplicate slips through and the
--- consequence is one redundant event, whereas failing closed would silently
--- stop a player's footsteps for the lifetime of the process.
function CisWindow.seen(d, key, now)
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

--- Is a key currently inside its window? Records NOTHING.
---
--- The read that must not count as a hit, for the same reason CisLRU.peek
--- exists: a caller polling "may I play this sound" would otherwise extend the
--- window on every poll and the sound would never play.
--- @return boolean
function CisWindow.isSeen(d, key, now)
    local last = d.entries[key]
    if last == nil then
        return false
    end
    if now < last then
        return false
    end
    return (now - last) < d.windowSec
end

--- Forget a key entirely, so the next `seen` accepts it regardless of the
--- window. This is the "the player moved, play it again" button.
function CisWindow.reset(d, key)
    if d.entries[key] ~= nil then
        d.entries[key] = nil
        d.size = d.size - 1
    end
end

--- Drop every key whose window has expired.
---
--- O(size). This is a memory sweep, not a correctness mechanism -- the answers
--- are right with or without it. It has to be called periodically or a dedupe
--- keyed by entity handle or player id grows for the lifetime of the process;
--- a chat-message dedupe keyed by a string should never call it at all.
--- @return number  how many keys were reclaimed
function CisWindow.prune(d, now)
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
--- @return number
function CisWindow.dedupeCount(d)
    return d.size
end

-- ================================================ SLIDING STATS AGGREGATOR

--- Count / min / max / sum / mean over a trailing time window, per key.
---
--- WHY BUCKETS, AND NOT A LIST OF SAMPLES
--
-- The exact answer needs every sample in the window, so the obvious structure
-- is a per-key list that is pruned as it ages. That is correct and its memory
-- is proportional to the EVENT RATE, which is the one number nobody can bound
-- in advance -- the same structure is 200 bytes for a player who chats twice a
-- minute and 200k for one who is being spammed, which is exactly when you
-- least want a memory spike.
--
-- So the samples go into TIME BUCKETS instead. A key owns a fixed ring of
-- `bucketCount` buckets, each holding a sum, a count, a min, a max and a last
-- timestamp for one slice of time. Adding a sample is five array writes into a
-- slot that already exists. A bucket that falls out of the window is zeroed and
-- reused. Memory is fixed per key for the lifetime of the process regardless of
-- how many events arrive, and the aggregation over the live buckets is
-- O(bucketCount) at query time instead of O(samples) on every push.
--
-- The price is accuracy at the leading edge. A bucket is counted WHOLE once it
-- is live, including the part of it that is older than the window, so an event
-- that is genuinely outside the window still contributes for up to `bucketSec`
-- more seconds. With bucketSec = 1 and a 60s window that is up to 1.7% of the
-- count. Shrink bucketSec to tighten it and pay in memory and query time; that
-- is the trade and it is the same trade the sliding-window counter in
-- shared/algo/rate.lua makes, for the same reason.
--
--- @param windowSec number  length of the trailing window
--- @param bucketSec number|nil  slice width, default 1. Clamped to at most
---        windowSec and to at least 1/1000 of it.
--- @return table  the aggregator
function CisWindow.newStats(windowSec, bucketSec)
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
--
-- The ring is written strictly forwards, so the position `d` places before the
-- cursor holds the bucket `d` places before the current one -- EXCEPT across a
-- jump wider than the ring, which record() handles by zeroing everything, and
-- except for a key that has not yet been round the ring once, where the
-- positions ahead of the cursor have never been written and are simply empty.
-- Both of those fall out of the same expression, which is why the cursor
-- position is in it and not the ring size.
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
---
--- @param value number  non-numeric values and NaN are IGNORED rather than
---        poisoning the arithmetic for the whole window. A single NaN in a sum
---        makes every later min, max and mean NaN too, and a NaN mean looks
---        exactly like a server bug to whoever is reading the dashboard.
--- @return boolean  whether the sample was recorded
function CisWindow.record(stats, key, value, now)
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

    -- Absolute bucket index, so a step forward in time is seen as "the buckets
    -- in between are now empty" and a jump is seen as "everything is empty".
    -- Comparing absolute indices rather than timestamps is what makes a clock
    -- that jumps backwards self-healing: it is just a smaller index, the ring
    -- rewinds, and nothing can get stuck as permanently live.
    local bucketIndex = math.floor(now / stats.bucketSec)
    if entry.lastBucket >= 0 and bucketIndex ~= entry.lastBucket then
        local steps = bucketIndex - entry.lastBucket
        if steps >= ringSize then
            -- Wider than the whole ring: every bucket is stale, and zeroing
            -- them one cursor step at a time would be a loop of up to a
            -- million for a long-idle key.
            for i = 1, ringSize do
                entry.sums[i] = nil
                entry.counts[i] = nil
                entry.mins[i] = nil
                entry.maxs[i] = nil
                entry.lasts[i] = nil
            end
            entry.idx = 0
        elseif steps > 1 then
            -- A short jump: zero exactly the buckets that are about to be
            -- passed over, leaving the newest one (the next write overwrites it
            -- anyway, so steps - 1, not steps).
            for _ = 1, steps - 1 do
                local i = entry.idx % ringSize + 1
                entry.idx = i
                entry.sums[i] = nil
                entry.counts[i] = nil
                entry.mins[i] = nil
                entry.maxs[i] = nil
                entry.lasts[i] = nil
            end
        end
        entry.lastBucket = bucketIndex
    elseif entry.lastBucket < 0 then
        entry.lastBucket = bucketIndex
    end

    local i = entry.idx % ringSize + 1
    entry.idx = i
    entry.sums[i] = (entry.sums[i] or 0) + value
    entry.counts[i] = (entry.counts[i] or 0) + 1
    local mn, mx = entry.mins[i], entry.maxs[i]
    if mn == nil or value < mn then entry.mins[i] = value end
    if mx == nil or value > mx then entry.maxs[i] = value end
    entry.lasts[i] = now
    return true
end

--- Read a key's window.
---
--- @return table|nil  { count, sum, mean, min, max, last }, or nil when the key
---         has no live sample. `last` is the exact time of the most recent
---         sample still inside the window, so "how long since this player last
---         did the thing" is answerable from here without a second structure.
---         An empty window is reported as nil rather than as a table of zeros:
---         a caller that receives a table can trust that count >= 1.
function CisWindow.read(stats, key, now)
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

--- Count only, without building the result table.
---
--- The query a rate check runs on the hot path, where allocating a six-field
--- table per event to read one number is a real cost at 512 players and a
--- packet rate in the hundreds.
--- @return number
function CisWindow.count(stats, key, now)
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

--- Largest or smallest live sample, without building the result table.
--- @param wantMax boolean|nil  true for the max, false or nil for the min
--- @return number|nil  nil when there is no live sample
function CisWindow.extreme(stats, key, now, wantMax)
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
---
--- Same rule as the dedupe sweep: memory hygiene, not correctness -- every
--- answer above is right with or without it. Call it on a timer, never per
--- event, because it is O(keys * bucketCount).
--- @return number  how many keys were reclaimed
function CisWindow.pruneStats(stats, now)
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
