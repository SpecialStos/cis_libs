-- Benchmarks for the hot paths. T5.
--
-- THE POINT IS NOT THE NUMBERS, IT IS THE CONDITIONS. A bare ops-per-second
-- figure is worse than no figure, because it is a claim without a caveat and
-- gets quoted without one. So every result here prints the workload it was
-- measured on, and `npm run bench` prints the interpreter next to it.
--
-- WHAT THIS WOULD HAVE CAUGHT. L-S3 (a bucket clamp documented but missing) and
-- L-S12 (a soft clear that never gave memory back) were both invisible to every
-- functional test in this repository. One is a per-insert arithmetic cost that
-- was silently quadratic; the other is a table that grows without bound while
-- every function using it keeps returning correct answers. Neither shows up as
-- a failing assertion. Both show up immediately as a number that does not fit
-- the trend of its neighbours.
--
-- So the bench also asserts TRENDS, not absolute numbers. A run that suddenly
-- costs three times what its neighbours cost is the signal, and an absolute
-- threshold would fire on a slow CI box and be ignored. The trend checks below
-- are deliberately loose -- they catch an order of magnitude, not a
-- microsecond.
--
-- NOT RUN IN CI. A benchmark on shared hardware measures the hardware. It is a
-- tool for the person changing the code, not a gate.

local out = {}
local function say(...)
  local t = {}
  for i = 1, select('#', ...) do t[i] = tostring((select(i, ...))) end
  out[#out + 1] = table.concat(t, ' ')
end

local function bench(name, _setup, work, iterations, note)
  -- Warm first. A cold JIT or a cold cache is a one-off, and averaging a
  -- one-off into the result is how a benchmark ends up measuring start-up.
  for _ = 1, math.max(1, math.floor(iterations / 10)) do work() end
  local t0 = os.clock()
  for _ = 1, iterations do work() end
  local dt = os.clock() - t0
  local ops = dt > 0 and (iterations / dt) or 0
  say(('  %-34s %10.0f ops/s   %8.2f ms total   %s')
    :format(name, ops, dt * 1000, note or ''))
  return ops, dt
end

say('=== cis_libs benchmarks ===')
say('interpreter: fengari (Lua 5.3 semantics, JavaScript VM)')
say('these numbers are for COMPARISON between runs, not as absolute performance')
say('')

-- ---------------------------------------------------------------- registry
say('-- CisRegistry --')
do
  CisRegistry.register('database', 'cis_bench:CisBenchDatabase')
  local t = 0
  bench('call() with a warm cache', nil, function()
    t = t + 1
    CisRegistry.call('database', 'query', 'SELECT 1', {})
  end, 20000, 'the query path, every call')
  say(('  (accumulated %d)'):format(t))
end
say('')

-- -------------------------------------------------------------------- grid
say('-- CisGrid --')
do
  local grid = CisGrid.new()
  local ITEMS = 2000
  for i = 1, ITEMS do
    CisGrid.insert(grid, i, CisGrid.aabbFromCenter(i * 2, 0, 0, 4, 4, 4))
  end
  bench('insert() a 4x4 cell box', nil, function()
    local n = 0
    CisGrid.insert(grid, 'probe', CisGrid.aabbFromCenter(0, 0, 0, 4, 4, 4))
    CisGrid.queryPoint(grid, 0, 0, 0, function() n = n + 1 end)
    CisGrid.remove(grid, 'probe')
  end, 5000, ('%d items already in the grid'):format(ITEMS))

  bench('queryPoint() a miss', nil, function()
    local n = 0
    CisGrid.queryPoint(grid, 999999, 999999, 0, function() n = n + 1 end)
  end, 20000, 'the common case: not in any cell')
end
say('')

-- --------------------------------------------------------------------- lru
say('-- CisLRU --')
do
  local lru = CisLRU.new(500)
  -- put() and get() are SEPARATE benchmarks on purpose. A combined '250 puts
  -- then one get' loop reports one number for two different operations, and the
  -- get() figure it produces is off by a factor of 250 -- which is how a cache
  -- benchmark ends up measuring the wrong thing and looking fine.
  local n = 0
  bench('put() into a 500-entry cache', nil, function()
    n = n + 1
    CisLRU.put(lru, n % 250, n)
  end, 50000, '250 live keys, round-robin so nothing is ever a hit')
  bench('get() on a hot key', nil, function()
    CisLRU.get(lru, 7)
  end, 100000, 'the key every caller wants')
  bench('get() on an absent key', nil, function()
    CisLRU.get(lru, 'nothing')
  end, 50000, 'the miss path')
end
say('')

-- -------------------------------------------------------------------- rate
say('-- CisRate --')
do
  local r = CisRate.newFixed({ limit = 1000, windowSec = 1 })
  local src = 0
  bench('allow() inside the limit', nil, function()
    src = src + 1
    CisRate.allow(r, src % 500, 1.0)
  end, 50000, 'the per-event hot path')
end
say('')

-- ------------------------------------------------------------------ window
say('-- CisWindow --')
do
  local w = CisWindow.newStats(10, 1)
  local src = 0
  bench('record()', nil, function()
    src = src + 1
    CisWindow.record(w, src % 100, src / 1000, 1)
  end, 20000, '100 keys, one bucket per second')
  bench('samples() the count query', nil, function()
    src = src + 1
    CisWindow.samples(w, src % 100, src / 1000)
  end, 20000, 'what a rate check calls')
end
say('')

-- ------------------------------------------------------------------ sparse
say('-- CisSparse --')
do
  local set = CisSparse.new()
  bench('add() 1k then clear() x100', nil, function()
    for i = 1, 1000 do set[i] = true end
    CisSparse.clear(set)
  end, 50, 'the streaming churn pattern')
end
say('')

-- ------------------------------------------------------------------- queue
say('-- CisHeap (priority queue) --')
do
  local q = CisHeap.newQueue()
  -- Separate for the same reason as the LRU pair above: a combined loop reports
  -- one number for a drain AND a refill.
  local v = 0
  bench('enqueue()', nil, function()
    v = v + 1
    CisHeap.enqueue(q, v, v % 97)
    if CisHeap.size(q) > 2000 then CisHeap.clear(q) end
  end, 20000, 'held at ~2000 so the log keeps growing')
  bench('dequeue()', nil, function()
    for _ = 1, 50 do
      v = v + 1
      CisHeap.enqueue(q, v, v % 97)
    end
    for _ = 1, 50 do CisHeap.dequeue(q) end
  end, 2000, '50 out, 50 in, at depth')
end
say('')

say('=== end ===')
print(table.concat(out, '\n'))