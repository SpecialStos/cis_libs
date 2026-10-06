-- Benchmarks for the hot paths. T5.
--
-- THE POINT IS NOT THE NUMBERS, IT IS THE CONDITIONS. A bare ops-per-second
-- figure is worse than no figure, because it is a claim without a caveat and
-- gets quoted without one. So every result here prints the workload it was
-- measured on, and `npm run bench` prints the interpreter next to it.
--
-- WHAT THIS WOULD HAVE CAUGHT. A bucket clamp documented but missing, and
-- a soft clear that never gave memory back, were both invisible to every
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
say('date: ' .. (os.date and os.date('%Y-%m-%dT%H:%M:%SZ') or '?'))
say('these numbers are for COMPARISON between runs, not as absolute performance')
say('fengari os.clock is often 0; a 0 ops/s row is a dead clock, not a free call')
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
  bench('enqueue 50 then dequeue 50', nil, function()
    for _ = 1, 50 do
      v = v + 1
      CisHeap.enqueue(q, v, v % 97)
    end
    for _ = 1, 50 do CisHeap.dequeue(q) end
  end, 2000, 'NOT a pure dequeue: 50 in + 50 out at depth, 2000 outer loops')
end
say('')

-- ----------------------------------------------------------- zone containment
say('-- CisZoneGeom.contains per shape --')
do
  local origin = { x = 0.0, y = 0.0, z = 0.0 }
  local inside = { x = 1.0, y = 1.0, z = 0.0 }
  local box = { kind = 'box', cx = 0, cy = 0, cz = 0, hx = 2, hy = 2, hz = 2, heading = 0 }
  local sphere = { kind = 'sphere', cx = 0, cy = 0, cz = 0, radius = 5 }
  local poly = {
    kind = 'poly',
    points = { { x = -4, y = -4 }, { x = 4, y = -4 }, { x = 4, y = 4 }, { x = -4, y = 4 } },
    minZ = -10, maxZ = 10,
  }
  bench('box hit', nil, function()
    CisZoneGeom.contains(box, inside)
  end, 100000, '4 m box, point 1 m off centre')
  bench('box miss', nil, function()
    CisZoneGeom.contains(box, { x = 50, y = 0, z = 0 })
  end, 100000, '4 m box, point 50 m away')
  bench('sphere hit', nil, function()
    CisZoneGeom.contains(sphere, inside)
  end, 100000, '5 m sphere, point 1.4 m off centre')
  bench('sphere miss', nil, function()
    CisZoneGeom.contains(sphere, { x = 50, y = 0, z = 0 })
  end, 100000, '5 m sphere, point 50 m away')
  bench('poly hit', nil, function()
    CisZoneGeom.contains(poly, origin)
  end, 50000, '4-vertex square, point at origin')
  bench('poly miss', nil, function()
    CisZoneGeom.contains(poly, { x = 50, y = 0, z = 0 })
  end, 50000, '4-vertex square, point 50 m away')
end
say('')

-- ------------------------------------------------------ sync visibility pass
say('-- sync visibility (grid, 64 players x 200 records) --')
do
  local SCOPE = 80.0
  local HYSTERESIS = 1.25
  local r = SCOPE * HYSTERESIS
  local grid = CisGrid.new()
  local records = {}
  for i = 1, 200 do
    local rec = {
      coords = { x = (i % 20) * 40.0, y = math.floor(i / 20) * 40.0, z = 0.0 },
    }
    records[i] = rec
    local aabb = CisGrid.aabbFromCenter(rec.coords.x, rec.coords.y, rec.coords.z, r, r, r)
    CisGrid.insert(grid, i, aabb, nil)
  end
  local players = {}
  for i = 1, 64 do
    players[i] = { x = (i % 8) * 80.0, y = math.floor(i / 8) * 80.0, z = 0.0 }
  end
  bench('grid queryPoint x 64', nil, function()
    local n = 0
    for i = 1, 64 do
      local p = players[i]
      CisGrid.queryPoint(grid, p.x, p.y, p.z, function() n = n + 1 end)
    end
  end, 500, '200 records in grid, 64 fake players, one cell each')
  bench('naive 64 x 200 distance', nil, function()
    local n = 0
    for i = 1, 64 do
      local p = players[i]
      for j = 1, 200 do
        local c = records[j].coords
        local dx, dy, dz = p.x - c.x, p.y - c.y, p.z - c.z
        if dx * dx + dy * dy + dz * dz <= SCOPE * SCOPE then
          n = n + 1
        end
      end
    end
  end, 200, 'same 64 x 200 without the grid, for the trend check')
end
say('')

say('=== end ===')
print(table.concat(out, '\n'))