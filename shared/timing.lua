-- Pass timings for Stage 8. This is NOT CisHistogram: that file counts jobs.
--
-- GetGameTimer is integer milliseconds. A single zone pass is often 0 ms on
-- that clock. os.clock is seconds as a float and is what measure() uses when
-- it moves; fengari's os.clock is 0, so unit tests call observe() with a
-- number rather than trusting measure().
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
    if os and type(os.clock) == 'function' then
        local c = os.clock()
        if type(c) == 'number' and c == c and c > 0 then
            return c * 1000
        end
    end
    if type(GetGameTimer) == 'function' then
        return GetGameTimer()
    end
    return 0
end

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
    local t0 = nowMs()
    local a, b, c, d = fn()
    CisTiming.observe(name, nowMs() - t0)
    return a, b, c, d
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
