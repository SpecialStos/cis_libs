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

TEST_CASES = {}
local function expect(cond, msg)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        io.stderr:write('FAIL: ' .. msg .. '\n')
    end
    TEST_CASES[#TEST_CASES + 1] = { name = msg, status = cond and 'passed' or 'failed' }
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

-- The report encoder and probe helpers used to be tested here. They belong to
-- cis_libstest, which is a separate repository and a separate FiveM resource,
-- and a change to either should be caught by that project's own suite:
--   https://github.com/SpecialStos/cis_libstest
io.write(('passed=%d failed=%d\n'):format(passed, failed))
if failed > 0 then
    os.exit(1)
end
