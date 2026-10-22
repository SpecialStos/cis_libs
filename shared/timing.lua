-- Pass timings for Stage 8. This is NOT CisHistogram: that file counts jobs.
--
-- THE CLOCK. A wall clock, never os.clock: os.clock is PROCESS CPU time, and on
-- a Linux server that is every thread of FXServer added together, so a 0.1 ms
-- pass on a busy box read as whatever the other threads burned meanwhile. The
-- CfxLua runtime has a high-resolution monotonic os.nanotime (and os.microtime);
-- they are feature-detected, and GetGameTimer -- integer milliseconds, so a
-- short pass often reads 0 -- is the floor where neither exists.
--
-- YIELDS ARE NOT WORK. A measured body that waits on a model load would report
-- the load as pass time. `CisTiming.exclude(fn, ...)` runs fn and subtracts its
-- wall time from the measurement it is nested in (per coroutine, because a
-- yielded measurement interleaves with others).
--
-- GetDiagnostics.Collect copies snapshot() into `timings`, a sibling of
-- `probes`. CisDiagnostics.Diff does not walk it: a live harness that diffs
-- snapshots around every case would otherwise fail every case that ran a pass.

CisTiming = {}

local SERIES = {
    zonePass = true,
    serverSyncPass = true,
    clientSyncPass = true,
    callbackRtt = true,
    exportCrossing = true,
}

-- Bucket edges match Stage 8.2 targets: idle 0.02, 100 zones 0.05,
-- 1000 zones 0.15, 0.5 is the investigate line.
local EDGES = { 0.02, 0.05, 0.15, 0.5 }

local series = {}

local function nowMs()
    if type(CisTiming._now) == 'function' then
        return CisTiming._now()
    end
    -- rawget: these are CfxLua extensions, absent from stock Lua's os table.
    local nano = rawget(os, 'nanotime')
    if type(nano) == 'function' then
        return nano() / 1e6
    end
    local micro = rawget(os, 'microtime')
    if type(micro) == 'function' then
        return micro() / 1e3
    end
    if type(GetGameTimer) == 'function' then
        return GetGameTimer()
    end
    return 0
end

-- coroutine -> the innermost open measurement in it. Weak, so a coroutine that
-- died mid-measurement does not pin its frame.
local frames = setmetatable({}, { __mode = 'k' })

function CisTiming.now()
    return nowMs()
end

local function emptyBuckets()
    return { 0, 0, 0, 0, 0 }
end

local function bucketOf(ms)
    for i = 1, #EDGES do
        if ms <= EDGES[i] then
            return i
        end
    end
    return #EDGES + 1
end

function CisTiming.observe(name, ms)
    if type(name) ~= 'string' or not SERIES[name] then
        return false, ('unknown timing series %q'):format(tostring(name))
    end
    if type(ms) ~= 'number' or ms ~= ms or ms == math.huge or ms == -math.huge then
        return false, 'timing ms is not a finite number'
    end
    if ms < 0 then
        return false, 'timing ms is negative'
    end
    local s = series[name]
    if not s then
        s = {
            n = 0,
            sum = 0,
            min = ms,
            max = ms,
            last = ms,
            buckets = emptyBuckets(),
        }
        series[name] = s
    end
    s.n = s.n + 1
    s.sum = s.sum + ms
    s.last = ms
    if ms < s.min then s.min = ms end
    if ms > s.max then s.max = ms end
    local b = bucketOf(ms)
    s.buckets[b] = (s.buckets[b] or 0) + 1
    return true
end

function CisTiming.measure(name, fn)
    if type(fn) ~= 'function' then
        return nil, 'measure needs a function'
    end
    local co = coroutine.running()
    local frame = { excluded = 0, parent = frames[co] }
    frames[co] = frame
    local t0 = nowMs()
    local ok, a, b, c, d = pcall(fn)
    frames[co] = frame.parent
    if not ok then
        error(a, 0)
    end
    local ms = nowMs() - t0 - frame.excluded
    CisTiming.observe(name, ms > 0 and ms or 0)
    return a, b, c, d
end

--- Run fn, and keep its wall time out of the measurement it is nested in.
--- For the part of a measured body that WAITS (a model load) rather than works.
function CisTiming.exclude(fn, ...)
    local co = coroutine.running()
    local t0 = nowMs()
    local packed = table.pack(fn(...))
    local frame = frames[co]
    if frame then
        frame.excluded = frame.excluded + (nowMs() - t0)
    end
    return table.unpack(packed, 1, packed.n)
end

function CisTiming.measureN(name, n, fn)
    if type(fn) ~= 'function' then
        return nil, 'measureN needs a function'
    end
    n = tonumber(n)
    if not n or n ~= n or n < 1 then
        return nil, 'measureN n must be a positive number'
    end
    n = math.floor(n)
    local t0 = nowMs()
    for _ = 1, n do
        fn()
    end
    local ms = (nowMs() - t0) / n
    local ok, why = CisTiming.observe(name, ms)
    if not ok then
        return nil, why
    end
    return ms
end

function CisTiming.snapshot()
    local out = {}
    for name, s in pairs(series) do
        out[name] = {
            n = s.n,
            sum = s.sum,
            min = s.min,
            max = s.max,
            last = s.last,
            mean = s.n > 0 and (s.sum / s.n) or 0,
            le002 = s.buckets[1] or 0,
            le005 = s.buckets[2] or 0,
            le015 = s.buckets[3] or 0,
            le05 = s.buckets[4] or 0,
            gt05 = s.buckets[5] or 0,
        }
    end
    return out
end

function CisTiming.reset(name)
    if name == nil then
        series = {}
        return true
    end
    if type(name) ~= 'string' or not SERIES[name] then
        return false, ('unknown timing series %q'):format(tostring(name))
    end
    series[name] = nil
    return true
end
