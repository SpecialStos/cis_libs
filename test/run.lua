-- Pure-module tests. Run with: node test/run.js  or  lua test/run.lua
-- Covers shared/ only. Anything needing a FiveM native is exercised by the
-- client/server integration path, not here.

if not CisGrid then
    local root = (arg and arg[0] or '.'):gsub('[/\\]test[/\\]run%.lua$', '')
    if root == (arg and arg[0] or '.') then
        root = '.'
    end
    local function loadfile_rel(path_)
        local chunk, err = loadfile(root .. '/' .. path_)
        if not chunk then
            error(err)
        end
        chunk()
    end
    loadfile_rel('shared/grid.lua')
    loadfile_rel('shared/pending.lua')
    loadfile_rel('shared/config.lua')
    loadfile_rel('shared/histogram.lua')
    loadfile_rel('cis_libstest/shared/report.lua')
end

local failed = 0
local passed = 0

local function expect(cond, msg)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        io.stderr:write('FAIL: ' .. msg .. '\n')
    end
end

local function vec(x, y, z)
    return { x = x, y = y, z = z or 0 }
end

-- ---------------------------------------------------------------- grid: basics
local grid = CisGrid.new()
local aabb = CisGrid.aabbFromCenter(10, 10, 0, 4, 4, 4)
CisGrid.insert(grid, 'a', aabb, { name = 'a' })
local hits = 0
CisGrid.queryNeighbors(grid, 10, 10, 0, function()
    hits = hits + 1
end)
expect(hits == 1, 'queryNeighbors hits inserted item')

hits = 0
CisGrid.queryNeighbors(grid, 80, 80, 0, function()
    hits = hits + 1
end)
expect(hits == 0, 'AABB reject far point')

CisGrid.insert(grid, 'a', CisGrid.aabbFromCenter(100, 100, 0, 2, 2, 2), { name = 'moved' })
hits = 0
CisGrid.queryNeighbors(grid, 10, 10, 0, function()
    hits = hits + 1
end)
expect(hits == 0, 'reinsert removes old cells')
hits = 0
CisGrid.queryNeighbors(grid, 100, 100, 0, function()
    hits = hits + 1
end)
expect(hits == 1, 'reinsert lands in new cell')

-- Removing must also drop the empty cell, or cells leak for the process life.
CisGrid.insert(grid, 'tmp', CisGrid.aabbFromCenter(500, 500, 0, 1, 1, 1), {})
local tmpKey = CisGrid.keyFromWorld(500, 500)
expect(grid.cells[tmpKey] ~= nil, 'cell bucket created on insert')
CisGrid.remove(grid, 'tmp')
expect(grid.cells[tmpKey] == nil, 'empty cell bucket is reaped on remove')

CisGrid.clear(grid)
expect(next(grid.cells) == nil and next(grid.items) == nil, 'clear empties grid')

-- ------------------------------------------------- grid: queryPoint equivalence
-- insert() registers an id in every cell its AABB overlaps, so the single
-- cell containing the point is provably enough. This pins that property: the
-- zones and doors call queryPoint on the strength of it.
math.randomseed(20240917)

local function collectPoint(g, x, y, z)
    local out = {}
    CisGrid.queryPoint(g, x, y, z, function(id) out[#out + 1] = id end)
    table.sort(out)
    return out
end

local function collectNeighbors(g, x, y, z)
    local out = {}
    CisGrid.queryNeighbors(g, x, y, z, function(id) out[#out + 1] = id end)
    table.sort(out)
    return out
end

local function bruteForce(g, x, y, z)
    local out = {}
    for id, item in pairs(g.items) do
        local a = item.aabb
        if x >= a.minX and x <= a.maxX and y >= a.minY and y <= a.maxY
            and z >= a.minZ and z <= a.maxZ then
            out[#out + 1] = id
        end
    end
    table.sort(out)
    return out
end

local function sameSet(a, b)
    if #a ~= #b then
        return false
    end
    for i = 1, #a do
        if a[i] ~= b[i] then
            return false
        end
    end
    return true
end

local fuzz = CisGrid.new()
for i = 1, 250 do
    local cx = math.random(-400, 400)
    local cy = math.random(-400, 400)
    local hx = math.random(1, 80)
    local hz = math.random(1, 20)
    -- z deliberately varied so the Z axis is exercised too
    CisGrid.insert(fuzz, 'f' .. i, CisGrid.aabbFromCenter(cx, cy, math.random(-30, 30), hx, hx, hz), {})
end

local pointVsBrute, pointVsNeighbors, neighborsVsBrute = 0, 0, 0
for _ = 1, 3000 do
    local px = math.random(-500, 500)
    local py = math.random(-500, 500)
    local pz = math.random(-60, 60)
    local p = collectPoint(fuzz, px, py, pz)
    local n = collectNeighbors(fuzz, px, py, pz)
    local b = bruteForce(fuzz, px, py, pz)
    if not sameSet(p, b) then pointVsBrute = pointVsBrute + 1 end
    if not sameSet(p, n) then pointVsNeighbors = pointVsNeighbors + 1 end
    if not sameSet(n, b) then neighborsVsBrute = neighborsVsBrute + 1 end
end
expect(pointVsBrute == 0, 'queryPoint matches brute force over 3000 fuzz points')
expect(pointVsNeighbors == 0, 'queryPoint matches queryNeighbors over 3000 fuzz points')
expect(neighborsVsBrute == 0, 'queryNeighbors matches brute force over 3000 fuzz points')

-- A zone wider than one cell must still be found from any cell it covers.
local wide = CisGrid.new()
CisGrid.insert(wide, 'wide', CisGrid.aabbFromCenter(0, 0, 0, 500, 500, 500), {})
expect(#collectPoint(wide, 400, 400, 0) == 1, 'oversized AABB reachable across many cells')
expect(#collectPoint(wide, -490, 490, 0) == 1, 'oversized AABB reachable at far corner')

-- ------------------------------------------------------------------- geometry
local square = { vec(0, 0), vec(10, 0), vec(10, 10), vec(0, 10) }
expect(CisGrid.pointInPolygon(5, 5, square), 'point inside square')
expect(not CisGrid.pointInPolygon(15, 5, square), 'point outside square')
expect(CisGrid.pointInPolygon(1, 1, square), 'point at lower corner inside')
expect(not CisGrid.pointInPolygon(-0.001, 5, square), 'point just left of square outside')
expect(CisGrid.pointInSphere(1, 0, 0, 0, 0, 0, 1.5), 'point in sphere')
expect(not CisGrid.pointInSphere(3, 0, 0, 0, 0, 0, 1.5), 'point outside sphere')
expect(CisGrid.pointInBox(1, 1, 0, 0, 0, 0, 2, 2, 2, 0), 'point in box')
expect(not CisGrid.pointInBox(5, 0, 0, 0, 0, 0, 2, 2, 2, 0), 'point outside box')
expect(not CisGrid.pointInBox(0, 0, 5, 0, 0, 0, 2, 2, 2, 0), 'point above box outside')

-- A box rotated 90 degrees must swap its axes.
expect(CisGrid.pointInBox(3, 0, 0, 0, 0, 0, 1, 4, 4, 90), 'rotated box along x')
expect(not CisGrid.pointInBox(0, 3, 0, 0, 0, 0, 1, 4, 4, 90), 'rotated box rejects old x extent')

-- pointInPolygon must handle both windings of the same square.
local rev = { vec(0, 0), vec(0, 10), vec(10, 10), vec(10, 0) }
expect(CisGrid.pointInPolygon(5, 5, rev), 'polygon works with reversed winding')
expect(not CisGrid.pointInPolygon(15, 5, rev), 'reversed polygon rejects outside point')

-- aabbFromPoints with an empty list must not produce an infinite box
local emptyBox = CisGrid.aabbFromPoints({}, 0, 1, 0)
expect(emptyBox.minX ~= math.huge, 'empty point list does not yield infinite AABB')

-- ------------------------------------------------------------- pending keys
local store = CisPending.new()
local k1 = CisPending.alloc(store, { n = 1 }, 10)
local k2 = CisPending.alloc(store, { n = 2 }, 30)
expect(k1 == 1 and k2 == 2, 'keys increment')
local expired = 0
CisPending.sweep(store, 20, function()
    expired = expired + 1
end)
expect(expired == 1, 'sweep expires due keys')
expect(CisPending.take(store, k1) == nil, 'expired key is gone')
local item = CisPending.take(store, k2)
expect(item and item.payload.n == 2, 'live key still takeable')
local k3 = CisPending.alloc(store, { n = 3 }, 100)
expect(k3 == 3, 'keys keep incrementing after timeout')
expect(CisPending.count(store) == 1, 'count after take')
-- take() must consume: a second take of the same key returns nil, which is what
-- stops a forged callback response from resolving twice.
expect(CisPending.take(store, k3) ~= nil, 'first take succeeds')
expect(CisPending.take(store, k3) == nil, 'second take of same key returns nil')

-- -------------------------------------------------------------- config strip
local payload = CisConfigUtil.clientPayload({
    Framework = {
        Type = 'QBCORE',
        Inventory = 'ox_inventory',
        Database = { Type = 'oxmysql', Collection = 'secret' },
        Target = { Enabled = true, Type = 'ox_target' },
        Zones = { Enabled = true },
    },
    Printing = { Debug = true, UseDiscordLogs = true },
    Doorlock = { Enabled = true, Type = 'target', InteractableDistance = 2.0 },
}, {
    EventPrefix = 'cis_libs',
    DropPlayer = true,
    AuthorizedResources = { 'nope' },
    DiscordLogsLinks = {
        MasterLogs = 'https://discord.com/api/webhooks/111/abc',
    },
}, { doors = { door_1 = { id = 'door_1' } }, groups = {} })

expect(payload.Config.Framework.Type == 'QBCORE', 'framework type copied')
expect(payload.EventPrefix == 'cis_libs', 'event prefix copied')
expect(payload.DoorData.doors.door_1 ~= nil, 'door data copied')
expect(payload.Config.Framework.Database == nil, 'database config stripped')
expect(payload.Config.Printing.UseDiscordLogs == nil, 'discord flag stripped')
expect(payload.AuthorizedResources == nil, 'allow-list stripped')
expect(not CisConfigUtil.containsSecret(payload), 'payload has no secrets')

-- Walk the whole payload: no key anywhere may look like a server secret.
local function leaksSecrets(node, path)
    if type(node) == 'string' then
        if node:find('discord.com/api/webhooks', 1, true) or node:find('CHANGE-ME', 1, true) then
            return path
        end
    elseif type(node) == 'table' then
        for k, v in pairs(node) do
            local hit = leaksSecrets(v, path .. '.' .. tostring(k))
            if hit then
                return hit
            end
        end
    end
    return nil
end
expect(leaksSecrets(payload, 'payload') == nil, 'no webhook URL anywhere in payload')

-- containsSecret must actually fire when a payload really does leak, or the
-- cis_debug check is decorative. clientPayload strips webhooks, so build the
-- bad payload by hand to simulate the regression it is meant to catch.
local leaky = {
    Config = { Printing = { Hook = 'https://discord.com/api/webhooks/111/abc' } },
}
expect(CisConfigUtil.containsSecret(leaky), 'containsSecret detects a leaked webhook')
expect(CisConfigUtil.containsSecret({ Config = { fn = function() end } }), 'containsSecret detects a function')
expect(not CisConfigUtil.containsSecret({ Config = { AimingCheckType = 'default' } }), 'clean payload is not flagged')

-- Config.UpdateInterval must reach the client or the cache loop cannot read it.
local withIntervals = CisConfigUtil.clientPayload({
    UpdateInterval = { Player = 750, Weapon = 500, Vehicle = 1000, VehicleProperties = 5000 },
}, {}, {})
expect(withIntervals.Config.UpdateInterval.Player == 750, 'update interval reaches client')

-- Defaults must be present when the server sends no intervals.
local noIntervals = CisConfigUtil.clientPayload({}, {}, {})
expect(noIntervals.Config.UpdateInterval.Player == 250, 'update interval has a default')
expect(noIntervals.Config.UpdateInterval.Weapon == 250, 'weapon interval has a default')

-- Enable flags default to true when absent, and honour an explicit false.
expect(CisConfigUtil.clientPayload({}, {}, {}).Config.Sync.Enabled == true, 'sync enabled by default')
expect(CisConfigUtil.clientPayload({ Sync = { Enabled = false } }, {}, {}).Config.Sync.Enabled == false,
    'sync disabled explicitly')
expect(CisConfigUtil.clientPayload({}, {}, {}).Config.Doorlock.Enabled == true, 'doorlock enabled by default')
expect(CisConfigUtil.clientPayload({ Doorlock = { Enabled = false } }, {}, {}).Config.Doorlock.Enabled == false,
    'doorlock disabled explicitly')

-- copyPublic must never emit a function, at any depth.
local fnDeep = { a = { b = { c = function() end } } }
local copied = CisConfigUtil.clientPayload({ Framework = { Debug = fnDeep } }, {}, {})
expect(leaksSecrets(copied, 'copied') == nil, 'nested functions are not copied')

-- ---------------------------------------------------------------- histogram
local jobs = CisHistogram.new()
CisHistogram.set(jobs, 1, { name = 'police' })
CisHistogram.set(jobs, 2, { name = 'police' })
CisHistogram.set(jobs, 3, { name = 'ambulance' })
expect(CisHistogram.count(jobs, 'police') == 2, 'job count police')
expect(CisHistogram.count(jobs, { 'police', 'ambulance' }) == 3, 'job count table')
CisHistogram.set(jobs, 1, { name = 'ambulance' })
expect(CisHistogram.count(jobs, 'police') == 1, 'job move decrements old')
CisHistogram.remove(jobs, 2)
expect(CisHistogram.count(jobs, 'police') == 0, 'drop decrements')

-- Setting the same job twice must not double count.
CisHistogram.set(jobs, 5, { name = 'mechanic' })
CisHistogram.set(jobs, 5, { name = 'mechanic' })
expect(CisHistogram.count(jobs, 'mechanic') == 1, 'idempotent set does not double count')

-- A job changing to nothing must decrement, and counts must never go negative.
CisHistogram.set(jobs, 6, { name = 'police' })
CisHistogram.set(jobs, 6, nil)
expect(CisHistogram.count(jobs, 'police') == 0, 'nil job decrements previous')
CisHistogram.remove(jobs, 99)
expect(CisHistogram.count(jobs, 'police') == 0, 'removing unknown player is a no-op')
expect(CisHistogram.count(jobs, 'nosuchjob') == 0, 'unknown job counts zero')
expect(CisHistogram.count(jobs, 12345) == 0, 'non-table non-string job counts zero')

-- ------------------------------------------------- test-harness JSON encoder
-- The report encoder is hand-rolled, and every array or escape it gets wrong
-- makes the saved report unparseable. Pin the shapes that actually appear.
local function json(value)
    local text = CisTestReport.encode(value, '  ')
    return (text:gsub('%s+', ''))
end

expect(json({ 1, 2, 3 }) == '[1,2,3]', 'array encodes with brackets')
expect(json({}) == '{}', 'empty table encodes as an object')
expect(json({ a = 1, b = 'x' }) == '{"a":1,"b":"x"}', 'flat object encodes')
expect(json({ a = { 1, 2 } }) == '{"a":[1,2]}', 'nested array keeps its brackets')
expect(json({ server = { { name = 'a' } } }) == '{"server":[{"name":"a"}]}', 'array of objects encodes')
expect(json({ a = { b = { c = 'd' } } }) == '{"a":{"b":{"c":"d"}}}', 'deep nesting encodes')

-- false must stay false. The report stores `detail = false` for a test that
-- failed without detail, and emitting null there would be a lie.
expect(json({ detail = false }) == '{"detail":false}', 'false is not encoded as null')
expect(json({ a = false, b = true }) == '{"a":false,"b":true}', 'booleans encode verbatim')
expect(json({ n = 0 }) == '{"n":0}', 'zero encodes as 0')
expect(json({ n = -3 }) == '{"n":-3}', 'negative numbers encode')

-- Backslash must be escaped first, otherwise the backslashes introduced by
-- the later replacements get doubled up. These assertions use the raw encoded
-- text: the whitespace-stripping helper above would eat the spaces that are
-- part of the string value itself.
local tricky = 'q" b\\ n\n t\thi'
local raw = CisTestReport.encode({ s = tricky }, '  ')
-- expected: {"s":"q\" b\\ n\n t\thi"} with each backslash doubled in Lua source
expect(raw == '{\n  "s": "q\\" b\\\\ n\\n t\\thi"\n}',
    'quotes, backslashes, newlines and tabs escape correctly')
-- One backslash in, exactly two out. If backslash were escaped last the
-- backslashes from the \n and \t replacements would also be doubled.
expect(raw:find('b\\\\ n', 1, true) ~= nil, 'a single backslash becomes exactly two')
expect(raw:find('\\\\n', 1, true) == nil, 'a real newline is not left as a literal backslash-n')
expect(raw:find('\\n', 1, true) ~= nil, 'a newline is escaped')
expect(raw:find('\\t', 1, true) ~= nil, 'a tab is escaped')
expect(json({ c = string.char(1) }) == '{"c":"\\u0001"}', 'control characters become unicode escapes')

-- Key order must be stable so two runs of an unchanged system are diffable.
local a = CisTestReport.encode({ z = 1, a = 2, m = 3 }, '  ')
local b = CisTestReport.encode({ m = 3, z = 1, a = 2 }, '  ')
expect(a == b, 'encoding is order-independent and therefore diffable')

-- ------------------------------------------------------------ report contexts
local rep = CisTestReport.new()
local okCtx = CisTestReport.context(rep, 'passes')
okCtx.equal(1, 1, 'one equals one')
okCtx.truthy(true, 'truthy value')
local passEntry = CisTestReport.finish(rep, okCtx, 3)
expect(passEntry.status == 'passed', 'context with no failures reports passed')

local failCtx = CisTestReport.context(rep, 'fails')
failCtx.equal(1, 2, 'one does not equal two')
local failEntry = CisTestReport.finish(rep, failCtx, 1)
expect(failEntry.status == 'failed', 'failed assertion marks the entry failed')
expect(failEntry.message ~= nil, 'failed entry carries a message')

local skipCtx = CisTestReport.context(rep, 'skips')
skipCtx.skip('no provider')
expect(CisTestReport.finish(rep, skipCtx, 0).status == 'skipped', 'skip marks the entry skipped')

local summary = CisTestReport.summarize(rep)
expect(summary.total == 3, 'summary counts every entry')
expect(summary.passed == 1, 'summary counts passes')
expect(summary.failed == 1, 'summary counts failures')
expect(summary.skipped == 1, 'summary counts skips')

local built = CisTestReport.build({ meta = { v = 1 } })
expect(built.server ~= nil and built.client ~= nil, 'build always yields server and client sections')

-- The recorder must tolerate a bare table. The harness once passed `{}` where a
-- report object was expected and every test died on a nil index; a mistake in
-- setup should not take down the whole suite.
local bare = {}
local bareCtx = CisTestReport.context(bare, 'bare')
bareCtx.pass('fine')
local bareEntry = CisTestReport.finish(bare, bareCtx, 1)
expect(bareEntry.status == 'passed', 'recorder accepts a bare table')
expect(type(bare.entries) == 'table' and #bare.entries == 1, 'bare table gained an entries array')
expect(CisTestReport.summarize(bare).total == 1, 'summarize reads a bare table')
expect(CisTestReport.summarize({}).total == 0, 'summarize of an empty table is zero')
expect(CisTestReport.summarize(nil).total == 0, 'summarize of nil is zero, not a crash')

-- ------------------------------------------------ regression: false green runs
-- The runner once handed every test body a capture callback instead of its own
-- context, so assertions landed on nothing and all 81 tests reported "passed".
-- Pin the invariant: one context per test, named after the test, and a failure
-- inside one must not be absorbed by its neighbours.
local multi = CisTestReport.new()
local names = {}
for i = 1, 4 do
    local cx = CisTestReport.context(multi, 'test ' .. i)
    names[#names + 1] = cx.name
    if i == 2 then
        cx.equal(1, 2, 'deliberate failure')
    elseif i == 4 then
        cx.skip('nothing to do')
    else
        cx.pass('fine')
    end
    CisTestReport.finish(multi, cx, 0)
end
expect(names[1] == 'test 1' and names[2] == 'test 2', 'each test keeps its own name')
expect(names[3] == 'test 3' and names[4] == 'test 4', 'names are not shared between tests')
local ms = CisTestReport.summarize(multi)
expect(ms.total == 4, 'all four tests recorded')
expect(ms.failed == 1, 'exactly the failing test is counted as failed')
expect(ms.passed == 2, 'the passing tests are counted as passed')
expect(ms.skipped == 1, 'the skipped test is counted as skipped')
expect(multi.entries[2].name == 'test 2', 'the failure is attributed to the right test')
expect(multi.entries[1].status == 'passed', 'a failure in test 2 does not mark test 1 failed')
expect(multi.entries[3].status == 'passed', 'a failure in test 2 does not mark test 3 failed')
expect(multi.entries[4].status == 'skipped', 'a failure in test 2 does not mark test 4 skipped')
expect(multi.entries[1].status == 'passed', 'a failure in test 2 does not mark test 1 failed')
expect(multi.entries[4].status == 'skipped', 'a failure in test 2 does not mark test 4 skipped')

io.stdout:write(('passed=%d failed=%d\n'):format(passed, failed))
if failed > 0 then
    os.exit(1)
end
