-- Pure-module tests, AND the entry point for a real Lua 5.4 run.
--
--   node test/run.js     every suite, under fengari
--   lua5.4 test/run.lua  every suite, under a real Lua 5.4
--
-- fengari is Lua 5.3 semantics compiled to JavaScript, which is close enough
-- to be dangerous in both directions: a change can use a 5.4 construct, pass
-- here and fail on a server, or fail here for a reason no server cares about.
-- Running the same suites under a real interpreter is the only check that
-- covers both, so both report the same assertion count and a divergence is a
-- finding rather than an inconvenience.
--
-- CIS_SUITE_MODE is set by test/suite-runner.js. Set, this file is just another
-- suite and the JavaScript driver owns the reporting; unset, it is the driver.

local ROOT = '.'
local function readDisk(rel)
    local fh = io.open(ROOT .. '/' .. rel, 'rb')
    if not fh then
        return nil, ('cannot open %s'):format(rel)
    end
    local body = fh:read('a')
    fh:close()
    return body
end

-- The suites read shipped source out of CIS_TEST_FILES rather than off disk, so
-- the boundary contracts check the same bytes the manifest names. Under
-- fengari the JavaScript runner fills it in; here it is built from the manifest.
if not CIS_TEST_FILES then
    local manifest = assert(readDisk('fxmanifest.lua'))
    CIS_TEST_FILES = {}
    local injected = { ['init.lua'] = true, ['fxmanifest.lua'] = true }
    for entry in manifest:gmatch("'([^']+%.lua)'") do
        if not injected[entry] then
            injected[entry] = true
            CIS_TEST_FILES[entry] = assert(readDisk(entry))
        end
    end
    CIS_TEST_FILES['init.lua'] = assert(readDisk('init.lua'))
    CIS_TEST_FILES['fxmanifest.lua'] = manifest
    -- api.lua is not in the manifest, so the walk above never reaches it.
    CIS_TEST_FILES['api.lua'] = assert(readDisk('api.lua'))
    CIS_TEST_FILES['README.md'] = assert(readDisk('README.md'))
end

if not CIS_SUITE_MODE then
    -- Drive every suite in its own environment. Stock Lua has one global state
    -- per process, so isolation has to come from an environment table: each
    -- suite writes globals (TEST_CASES) and reads the standard library, and
    -- __index into _G gives it both without one suite seeing another's globals.
    --
    -- os.exit is replaced with a raise for the same reason. A suite that calls
    -- it to report failure would otherwise take the whole run down on the first
    -- red one, which is how four good suites get reported as four crashes.
    -- The same preload lists test/suite-runner.js uses, in the same order. They
    -- are duplicated rather than derived because the two run in different
    -- languages and a shared file would be a file both have to parse; what
    -- matters is that they agree, and the suite each one feeds proves it.
    --
    -- run.lua and binding.lua deliberately see SHARED only, because that is
    -- what they saw before the suites were isolated. Preserving that is the
    -- point: a driver that gave every suite everything would be testing a
    -- configuration that never existed.
    local SHARED = {
        -- First, like the manifest: the counters have to exist before the
        -- first thing that counts one.
        'shared/diagnostics.lua',
        'shared/timing.lua',
        -- Then loopguard, in the same order the manifest loads it: a guarded
        -- loop counts into diagnostics, so it needs the counter to exist.
        'shared/loopguard.lua',
        'shared/defaults.lua', 'shared/registry.lua', 'shared/grid.lua',
        'shared/zonegeom.lua', 'shared/hooks.lua',
        'shared/pending.lua', 'shared/owned.lua', 'shared/config.lua',
        'shared/ready.lua', 'shared/histogram.lua', 'shared/detect.lua',
    }
    local ALGO_UTIL = {
        'shared/algo/curve.lua', 'shared/algo/heap.lua', 'shared/algo/interp.lua',
        'shared/algo/lru.lua', 'shared/algo/random.lua', 'shared/algo/rate.lua',
        'shared/algo/sparse.lua', 'shared/algo/window.lua',
        'shared/util/id.lua', 'shared/util/json.lua', 'shared/util/semver.lua',
        'shared/util/string.lua', 'shared/util/table.lua', 'shared/util/time.lua',
        'shared/util/validate.lua',
    }
    local BOTH = {}
    for _, v in ipairs(SHARED) do BOTH[#BOTH + 1] = v end
    for _, v in ipairs(ALGO_UTIL) do BOTH[#BOTH + 1] = v end
    local SUITES = {
        'test/run.lua', 'test/binding.lua', 'test/contracts.lua',
        'test/modules.lua', 'test/client.lua', 'test/server.lua',
        'test/ctl-allow.lua', 'test/examples.lua',
    }
    local PRELOAD = {
        ['test/run.lua'] = SHARED,
        ['test/binding.lua'] = SHARED,
        ['test/contracts.lua'] = BOTH,
        ['test/modules.lua'] = BOTH,
        ['test/client.lua'] = BOTH,
        ['test/server.lua'] = BOTH,
        -- The cis_ctl allow-list on its own: it is pure Lua and depends on none
        -- of the library's modules, so loading them would only give this suite
        -- globals it has no business reading.
        ['test/ctl-allow.lua'] = { 'test/live/cis_ctl/server/allow.lua' },
        ['test/examples.lua'] = {},
    }

    local crashed, failedAssertions = 0, 0
    for _, rel in ipairs(SUITES) do
        local env = setmetatable({}, { __index = _G })
        env.arg = { [0] = rel }
        env.CIS_SUITE_MODE = true
        env.CIS_TEST_FILES = CIS_TEST_FILES
        -- The SOURCE of the cis_ctl allow-list, so its suite can reload the
        -- chunk the way cis_ctl does on the server. Without it the suite can
        -- only ever see one loaded instance, and a module that depends on a
        -- global staying alive passes here forever.
        env.CIS_CTL_ALLOW_SOURCE = assert(readDisk('test/live/cis_ctl/server/allow.lua'))
        -- FiveM provides this as a global; stock Lua does not, and several
        -- shipped files call it at load time.
        env.exports = {}
        -- The suites load shipped modules with `loadfile('./' .. rel)`. Under
        -- fengari there is exactly one state, so a chunk loaded that way lands
        -- in the same globals the suite is writing to and everything connects.
        -- With a per-suite environment it does not: `loadfile` compiles against
        -- _G, so the module's globals went somewhere the suite could not see and
        -- every failure looked like a missing native. These two make `loadfile`
        -- compile into THIS environment, which is what the suite meant.
        env.loadfile = function(p)
            if p:sub(1, 2) == './' then p = p:sub(3) end
            local fh = io.open(ROOT .. '/' .. p, 'rb')
            if not fh then return nil, ('cannot open %s'):format(p) end
            local src = fh:read('a')
            fh:close()
            return load(src, '@' .. p, 't', env)
        end
        env.load = function(chunk, chunkname, mode, chunkEnv)
            return load(chunk, chunkname, mode, chunkEnv or env)
        end
        env.os = setmetatable({ exit = function(code)
            error({ __suite_exit = code or 0 }, 0)
        end }, { __index = _G.os })

        local function exec(rel_)
            local src = assert(readDisk(rel_))
            local chunk, err = load(src, '@' .. rel_, 't', env)
            if not chunk then error(err, 0) end
            chunk()
        end

        local EXITED = {}
        local ok, e = xpcall(function()
            for _, p in ipairs(PRELOAD[rel]) do exec(p) end
            exec(rel)
        end, function(m)
            -- A suite that fails its assertions calls os.exit(1) rather than
            -- raising. That is a FAILED SUITE, not a crash, and it must not be
            -- reported as "crashed: nil" -- which is what returning nil from
            -- here produced, because xpcall turns a nil handler result into
            -- `false, nil` and the driver then had nothing to print.
            if type(m) == 'table' and m.__suite_exit then return EXITED end
            return debug.traceback(tostring(m), 2)
        end)
        if not ok and e ~= EXITED then
            io.stderr:write('FAIL(' .. rel .. '): crashed: ' .. tostring(e) .. '\n')
            crashed = crashed + 1
        else
            -- Every suite records each case in TEST_CASES, so failures are
            -- counted and NAMED here rather than inferred from a summary line
            -- this driver cannot see -- it has no pipe on its own stdout.
            local bad = 0
            for _, c in ipairs(env.TEST_CASES or {}) do
                if c.status == 'failed' then
                    io.stderr:write('FAIL(' .. rel .. '): ' .. tostring(c.name) .. '\n')
                    bad = bad + 1
                end
            end
            failedAssertions = failedAssertions + bad
        end
    end

    io.write(('lua54: %d suites, %d failed assertion(s), %d crashed\n'):format(#SUITES, failedAssertions, crashed))
    if failedAssertions > 0 or crashed > 0 then os.exit(1) end
    return
end

if not CisGrid then
    local function loadfile_rel(path_)
        local chunk, err = loadfile(ROOT .. '/' .. path_)
        if not chunk then
            error(err)
        end
        chunk()
    end
    loadfile_rel('shared/grid.lua')
    loadfile_rel('shared/pending.lua')
    loadfile_rel('shared/config.lua')
    loadfile_rel('shared/histogram.lua')
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

-- aabbFromPoints with an empty list is REFUSED, not answered with a box.
--
-- This assertion used to read `emptyBox.minX ~= math.huge`, which pinned the
-- old behaviour: it accepted the zero-size box at the world origin that the
-- function returned. That box was not a neutral placeholder -- a poly zone
-- configured with no points got registered at (0,0) and fired onEnter for a
-- player standing there. A flipped pin is exactly what a reviewer should
-- question, so the change is called out rather than made quietly.
local emptyBox, gridEmptyWhy = CisGrid.aabbFromPoints({}, 0, 1, 0)
expect(emptyBox == nil and type(gridEmptyWhy) == 'string',
    'empty point list is refused rather than answered with the origin')
-- A real list still produces the same box it always did.
local realBox = CisGrid.aabbFromPoints({ vec(0, 0), vec(10, 10) }, 0, 1, 0)
expect(realBox ~= nil and realBox.minX == 0 and realBox.maxX == 10 and realBox.maxY == 10,
    'a real point list still produces the box it always did')

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
-- The third argument is gone with the split: door data belongs to cis_keys, and
-- a client payload carrying every door on the server was a table walking to
-- every connected player.
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
})

expect(payload.Config.Framework.Type == 'QBCORE', 'framework type copied')
expect(payload.EventPrefix == 'cis_libs', 'event prefix copied')
expect(payload.DoorData == nil, 'door data is no longer sent to clients')
expect(payload.Config.Framework.Database == nil, 'database config stripped')
expect(payload.Config.Doorlock == nil, 'doorlock config is not this library to ship')
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
--
-- These used to be pinned at 250, which is where the drift lived: the payload
-- carried its own literal copy of the defaults and it had already fallen behind
-- shared/defaults.lua. Asserting the literal kept the drift in place -- a test
-- that pins the wrong number is worse than no test, because it reads as
-- coverage. They are asserted against CisDefaults now, so there is one source
-- and a change to it cannot break this file.
local noIntervals = CisConfigUtil.clientPayload({}, {}, {})
local defaultIntervals = CisDefaults.config().UpdateInterval
expect(noIntervals.Config.UpdateInterval.Player == defaultIntervals.Player,
    'update interval has the default')
expect(noIntervals.Config.UpdateInterval.Weapon == defaultIntervals.Weapon,
    'weapon interval has the default')
expect(noIntervals.Config.UpdateInterval.Vehicle == defaultIntervals.Vehicle,
    'vehicle interval has the default')
expect(noIntervals.Config.UpdateInterval.VehicleProperties
    == defaultIntervals.VehicleProperties,
    'vehicle-properties interval has the default')

-- Enable flags default to true when absent, and honour an explicit false.
expect(CisConfigUtil.clientPayload({}, {}, {}).Config.Sync.Enabled == true, 'sync enabled by default')
expect(CisConfigUtil.clientPayload({ Sync = { Enabled = false } }, {}, {}).Config.Sync.Enabled == false,
    'sync disabled explicitly')
expect(CisConfigUtil.clientPayload({}, {}, {}).Config.Framework.Zones.Enabled == true,
    'zones enabled by default')
expect(CisConfigUtil.clientPayload({ Framework = { Zones = { Enabled = false } } }, {}, {})
        .Config.Framework.Zones.Enabled == false, 'zones disabled explicitly')
-- The payload copies the server's RESOLVED framework name verbatim. It does not
-- translate an unresolved 'AUTO' into 'NONE', and the reason is worth stating:
-- redaction and interpretation are different jobs, and a whitelist that
-- second-guesses the server's own resolution is a whitelist that will be wrong
-- the moment the server's resolution changes. cis_core rewrites AUTO to the
-- framework it actually found before this ever runs, so by the time a payload
-- is built the value is already a decision.
expect(CisConfigUtil.clientPayload({ Framework = { Type = 'AUTO' } }, {}, {}).Config.Framework.Type == 'AUTO',
    'the payload copies the server value rather than reinterpreting it')
expect(CisConfigUtil.clientPayload({ Framework = { Type = 'QBOX' } }, {}, {}).Config.Framework.Type == 'QBOX',
    'a resolved framework name does reach the client')

-- copyPublic must never emit a function, at any depth.
local fnDeep = { a = { b = { c = function() end } } }
local copied = CisConfigUtil.clientPayload({ Framework = { Debug = fnDeep } }, {}, {})
expect(leaksSecrets(copied, 'copied') == nil, 'nested functions are not copied')

-- --------------------------------------------------------- capability registry
-- The registry is what the whole split rests on, so it gets tested as behaviour
-- rather than as plumbing. Nothing here touches a FiveM server: the registry
-- resolves a "resource:Export" string against the `exports` global, and a test
-- can stand a fake one up in three lines.
local function withFakeExports(body)
    local saved = exports
    exports = {}
    local ok, err = pcall(body)
    exports = saved
    if not ok then error(err, 0) end
end

withFakeExports(function()
    -- Nothing is registered to begin with, and an unresolved slot is a refusal
    -- with a reason rather than a nil. That distinction is the whole point: a
    -- library that answers nil forever without saying why is the most expensive
    -- thing it can do to its own support burden.
    expect(CisRegistry.has('database') == false, 'no capability is registered to begin with')
    local ok, reason = CisRegistry.call('database', 'query', 'SELECT 1', {})
    expect(ok == false, 'an unresolved capability refuses')
    expect(type(reason) == 'string' and reason:find('no provider') ~= nil,
        'an unresolved capability says which slot is missing')
    expect(CisRegistry.value('database', 'query', 'SELECT 1', {}) == nil,
        'value() on an unresolved capability is nil, not false')

    -- An unknown slot is refused. Without this, a typo in a slot name registers
    -- a capability nothing will ever read, and the product believes it installed.
    local badSlot, badWhy = CisRegistry.register('databse', 'cis_bridge:CisBridgeDatabase')
    expect(badSlot == false, 'a typo in a slot name is refused')
    expect(tostring(badWhy):find('unknown capability slot') ~= nil, 'the refusal names the unknown slot')

    -- T9. WaitCapability, and the event it is paired with. The point of both is
    -- that START ORDER STOPS MATTERING: a consumer that starts before the
    -- provider used to read "no provider registered" for the whole window
    -- between the two, and a consumer that cached that nil was wrong for the
    -- rest of the session.
    do
        -- A WAIT STUB. wait() parks on Wait(TICK_MS) until the deadline, so
        -- without a clock that advances it would spin. This one also counts the
        -- parks, which is what proves the wait is bounded rather than a busy
        -- loop -- the same distinction this file draws everywhere else.
        local clock, parks = 0, 0
        local realTimer, realWait = GetGameTimer, Wait
        GetGameTimer = function() return clock end
        Wait = function(ms) clock = clock + (ms or 0); parks = parks + 1 end

        -- Already filled: answers immediately, and names the owner.
        CisRegistry.register('database', 'cis_bridge:CisBridgeDatabase')
        local filled, owner = CisRegistry.wait('database', 1000)
        expect(filled == true, 'T9: wait on a filled slot answers true at once')
        expect(owner == 'cis_bridge', 'and names the owner that filled it')
        expect(parks == 0, 'without parking once, because it was already there')

        -- Unknown slot: refused, and the reason names it.
        local badOk, badWaitWhy = CisRegistry.wait('databse', 10)
        expect(badOk == false, 'T9: waiting on an unknown slot is refused')
        expect(tostring(badWaitWhy):find('unknown capability slot') ~= nil,
            'and the refusal names the slot, so a typo is visible')

        -- Never filled: a BOUNDED refusal. The reason has to name the slot --
        -- "no provider registered for database" is the difference between
        -- "nobody installed one" and "it is named wrong", and a caller that
        -- cannot tell those two apart will retry the wrong thing.
        CisRegistry.unregister('database')
        parks = 0
        local okWait, emptyWhy = CisRegistry.wait('database', 200)
        expect(okWait == false, 'T9: waiting on a slot nobody fills times out')
        expect(tostring(emptyWhy):find('database') ~= nil, 'and the refusal names the slot')
        expect(parks > 0 and parks <= 10,
            ('and it waited in bounded parks rather than spinning (parks=%d)'):format(parks))

        -- THE EVENT, on both edges. A consumer that only heard about
        -- registration would wait out its full timeout after a provider
        -- restarted, which is the failure mode this pairing exists to remove.
        local seen = {}
        local realTrigger = TriggerEvent
        TriggerEvent = function(name, data)
            if name == 'cis_libs:capabilityChanged' then seen[#seen + 1] = data end
        end
        CisRegistry.register('database', 'cis_bridge:CisBridgeDatabase')
        expect(#seen == 1, 'T9: registering fires cis_libs:capabilityChanged')
        expect(seen[1] and seen[1].slot == 'database' and seen[1].resolved == true,
            'and the payload names the slot and says it resolved')
        expect(seen[1] and seen[1].owner == 'cis_bridge', 'and who filled it')

        CisRegistry.unregister('database')
        expect(#seen == 2, 'T9: releasing fires it too')
        expect(seen[2] and seen[2].resolved == false, 'with resolved false, so a waiter knows it is gone')
        expect(seen[2] and seen[2].previousOwner == 'cis_bridge',
            'and the owner that went away, which is what a restart looks like')

        TriggerEvent = realTrigger
        GetGameTimer, Wait = realTimer, realWait
    end

    -- The registration form is a string, because a function cannot be sent over
    -- the boundary. A malformed one is refused rather than stored and failed at
    -- the first call, hours later.
    local badForm, formWhy = CisRegistry.register('database', 'cis_bridge')
    expect(badForm == false, 'a provider with no :Export is refused')
    expect(tostring(formWhy):find('resource:Export') ~= nil, 'the refusal names the required form')

    -- Register against a fake exports table and prove the call goes THROUGH the
    -- boundary, with every argument in its slot.
    --
    -- THE PROVIDER SHAPE HERE IS THE SHAPE EVERY REAL PROVIDER USES, and it is
    -- worth being precise about, because getting it wrong is invisible in a test
    -- and fatal in production. A provider exports ONE function that RETURNS a
    -- table of methods; `call` is given a method name as its first argument and
    -- dispatches into that table. This double used to be a single dispatcher
    -- function taking (op, sql, params), which no provider in the platform has
    -- ever been -- and the whole suite passed against it while every product
    -- shipped broken, because the fiction was the only thing being tested.
    local seen = {}
    exports.cis_bridge = {
        CisBridgeDatabase = function(self)
            return {
                query = function(sql, params)
                    seen.sql, seen.params = sql, params
                    return { { id = 1 } }
                end,
                update = function(sql, params)
                    seen.updateSql, seen.updateParams = sql, params
                    return 7
                end,
            }
        end,
    }
    expect(CisRegistry.register('database', 'cis_bridge:CisBridgeDatabase'), 'a well-formed provider registers')
    expect(CisRegistry.has('database'), 'the slot is now held')
    expect(CisRegistry.owner('database') == 'cis_bridge', 'the owner is recorded')

    -- The method name selects the implementation, and the remaining arguments
    -- arrive in their own slots with nothing shifted.
    local rows = CisRegistry.value('database', 'query', 'SELECT 1', { a = 2 })
    expect(seen.sql == 'SELECT 1' and seen.params.a == 2,
        'arguments survive the boundary unmoved')
    expect(rows and rows[1] and rows[1].id == 1, 'the provider result comes back')
    expect(CisRegistry.value('database', 'update', 'UPDATE t', { b = 3 }) == 7,
        'a second method on the same provider dispatches to its own function')
    expect(seen.updateSql == 'UPDATE t' and seen.updateParams.b == 3,
        'the second method receives its own arguments, not the first method\'s')

    -- A method the provider does not implement is a refusal naming the method,
    -- not a nil call and not the provider's whole table handed back.
    local missing, callWhy = CisRegistry.call('database', 'transaction', {}, {})
    expect(missing == false, 'a method the provider does not implement is refused')
    expect(tostring(callWhy):find('transaction') ~= nil, 'the refusal names the method that is missing')
    expect(seen.sql == 'SELECT 1', 'a refused method does not fall through to another one')

    -- A provider that raises is contained: the caller gets a reason, not a
    -- stack trace, and the slot survives for the next call.
    exports.cis_bridge.CisBridgeDatabase = function(self)
        return { query = function() error('driver exploded') end }
    end
    CisRegistry.invalidate('database')
    local raised, raiseWhy = CisRegistry.call('database', 'query', 'SELECT 1', {})
    expect(raised == false, 'a raising provider is contained at the boundary')
    expect(tostring(raiseWhy):find('driver exploded') ~= nil, 'the provider error text survives')

    -- The unbound-method trap. `exports[res][name]` is an unbound method, so a
    -- dispatcher that omits the exports table shifts every argument one slot left
    -- and raises nothing. The fake records `self` as a parameter, so a shifted
    -- call shows up as op == the exports table rather than op == 'query'.
    --
    -- A cross-boundary export that answers with a single function rather than a
    -- method table is still dispatched as a function, so an older or hand-written
    -- provider keeps working instead of failing every call.
    exports.cis_bridge.CisBridgeDatabase = function(self, op, sql, params)
        seen.self, seen.op = self, op
        return true
    end
    CisRegistry.invalidate('database')
    CisRegistry.call('database', 'query', 'SELECT 1', {})
    expect(seen.op == 'query', 'the exports table is passed as self, not swallowed as an argument')
    expect(seen.self == exports.cis_bridge, 'self is the exports table')

    -- FIRST REGISTRATION WINS. Two products both believing they own the
    -- database is a real failure and it is invisible until something is
    -- mysteriously not taking effect.
    local second, why = CisRegistry.register('database', 'cis_core:CisCoreDatabase')
    expect(second == false, 'a second resource cannot take a held slot')
    expect(tostring(why):find('cis_bridge') ~= nil, 'the refusal names the holder')
    expect(CisRegistry.owner('database') == 'cis_bridge', 'the original owner is unchanged')

    -- ...but the SAME resource re-registering is not a conflict. That is what a
    -- restart handler looks like, and refusing it would leave a restarted
    -- product permanently unable to re-announce itself.
    expect(CisRegistry.register('database', 'cis_bridge:CisBridgeDatabase'),
        'the same resource may re-register')

    -- A provider that raises is a refusal, never an exception in the caller's
    -- thread. A bug in a bridge adapter must not become a stack trace in
    -- somebody else's script.
    exports.cis_bridge.CisBridgeDatabase = function() error('adapter is on fire') end
    CisRegistry.invalidate('database')
    local boomOk, boomWhy = CisRegistry.call('database', 'query', 'SELECT 1', {})
    expect(boomOk == false, 'a raising provider is a refusal')
    expect(tostring(boomWhy):find('adapter is on fire') ~= nil, 'the refusal carries the provider error')

    -- Unregister is owner-only, so one product stopping cannot blank a slot
    -- another product is still serving.
    expect(CisRegistry.unregister('database', 'cis_core') == false, 'a non-owner cannot unregister')
    expect(CisRegistry.has('database') == true, 'the slot survives a non-owner release attempt')
    expect(CisRegistry.unregister('database', 'cis_bridge') == true, 'the owner may unregister')
    expect(CisRegistry.has('database') == false, 'the slot is empty after the owner releases it')
end)

-- =============================================== WHO OWNS A SLOT, AND WHY
--
-- The owner of a slot decides two things: who is refused a second registration,
-- and whose stop releases it. Both are trust decisions, so the owner has to be
-- the resource that CALLED -- not a name the caller supplied inside the provider
-- string it passed in.
--
-- Those are two different things, and treating them as one let any resource take
-- any slot:
--
--     exports['cis_libs']:RegisterCapability('database', 'cis_core:CisCoreDatabase')
--
-- reads as "owned by cis_core", so the conflict check compared a CLAIM against a
-- CLAIM. An attacker naming the resource it is impersonating was recorded as
-- that resource, and every SQL statement from every product then flowed through
-- an export the attacker controls. The same holds for `framework` (Notify,
-- GetPlayer, permission checks) and `security.drop` (the function that actually
-- kicks a cheater).
--
-- The dispatch target and the owner genuinely can differ -- cis_core can hold
-- the `doors` slot while cis_keys exports the implementation -- so the provider
-- string still names where the CODE lives and `ref.resource` keeps doing that
-- job. Only the identity that decides trust moves.
withFakeExports(function()
    local savedInvoke = rawget(_G, 'GetInvokingResource')
    local invoking = nil
    GetInvokingResource = function() return invoking end

    -- Runs `body` as though `resource` were the caller on the exports boundary,
    -- which is the only place `GetInvokingResource()` means anything.
    local function as(resource, body)
        local previous = invoking
        invoking = resource
        local ok, err = pcall(body)
        invoking = previous
        if not ok then
            error(err, 0)
        end
    end

    exports.cis_core = {
        CisCoreDatabase = function(self)
            return { query = function() return { { id = 1 } } end }
        end,
    }

    -- The honest case: cis_core registers cis_core's own export.
    as('cis_core', function()
        expect(CisRegistry.register('database', 'cis_core:CisCoreDatabase'),
            'the genuine provider registers')
    end)
    expect(CisRegistry.owner('database') == 'cis_core',
        'the owner is the resource that called')

    -- THE EXPLOIT. A forged provider string naming the holder of a held slot.
    local forged, forgedWhy
    as('cis_evil', function()
        forged, forgedWhy = CisRegistry.register('database', 'cis_core:CisCoreDatabase')
    end)
    expect(forged == false,
        ('a forged provider name cannot take a held slot (got %s)')
            :format(tostring(forged)))
    expect(tostring(forgedWhy):find('cis_core', 1, true) ~= nil,
        ('and the refusal names the REAL holder (got %s)'):format(tostring(forgedWhy)))
    expect(CisRegistry.owner('database') == 'cis_core',
        'the recorded owner is untouched by the attempt')
    expect(CisRegistry.call('database', 'query', 'SELECT 1', {}) ~= false,
        'and the slot still dispatches to the real provider')

    -- The reverse order: the attacker arrives FIRST, claiming to be cis_core.
    -- First-registration-wins still holds -- it is the documented policy and the
    -- one that stops two honest products racing -- but the winner is recorded
    -- under the name that actually ran, so `cis_debug`, the refusal message and
    -- `releaseOwner` all point at the attacker instead of at its victim.
    as('cis_evil', function()
        expect(CisRegistry.register('target', 'cis_core:CisCoreTarget'),
            'a first registration still wins, whoever makes it')
    end)
    expect(CisRegistry.owner('target') == 'cis_evil',
        ('and it is recorded as the CALLER, not the claimed name (got %s)')
            :format(tostring(CisRegistry.owner('target'))))

    as('cis_core', function()
        local taken, takenWhy = CisRegistry.register('target', 'cis_core:CisCoreTarget')
        expect(taken == false, 'the impersonated resource cannot displace the first registrant')
        expect(tostring(takenWhy):find('cis_evil', 1, true) ~= nil,
            ('and the refusal names the real holder, not the claimed one (got %s)')
                :format(tostring(takenWhy)))
    end)

    -- Releasing is a trust decision too, so it follows the same identity.
    local releasedForEvil = CisRegistry.releaseOwner('cis_evil')
    expect(#releasedForEvil == 1 and releasedForEvil[1] == 'target',
        'releaseOwner frees what the CALLER registered')
    expect(not CisRegistry.has('target'), 'and only that')
    expect(CisRegistry.has('database'), "the impersonated resource's own slot survives")

    -- A provider whose CODE lives in another resource still releases when THAT
    -- resource stops. Separating owner from dispatch target would otherwise open
    -- this: the registrar is alive, the export is gone, and the slot keeps
    -- answering with a reference to a dead export for the life of the server.
    exports.cis_keys = {
        CisKeysDoors = function(self) return { persisted = function() return true end } end,
    }
    as('cis_core', function()
        expect(CisRegistry.register('doors', 'cis_keys:CisKeysDoors'),
            "a registrar may point at another resource's export")
    end)
    expect(CisRegistry.owner('doors') == 'cis_core', 'the owner is the registrar')
    CisRegistry.releaseOwner('cis_keys')
    expect(not CisRegistry.has('doors'),
        'and the slot is freed when the resource hosting the export stops')

    -- With no caller at all -- cis_libs registering its own capability from
    -- inside its own Lua state -- the owner falls back to the provider string,
    -- which is trustworthy precisely because it did not cross the boundary.
    CisRegistry.unregister('database')
    expect(CisRegistry.register('database', 'cis_core:CisCoreDatabase'),
        'an in-VM registration still works without an invoking resource')
    expect(CisRegistry.owner('database') == 'cis_core',
        'and falls back to the provider resource')

    CisRegistry.unregister('database')
    expect(CisRegistry.register('security', function() return {} end),
        'a bare callable cis_libs registers for itself')
    expect(CisRegistry.owner('security') == 'cis_libs',
        'and is owned by cis_libs, never by a name the caller chose')

    GetInvokingResource = savedInvoke
end)

-- ==================================== a DEAD provider must not break the DIAGNOSTIC
--
-- MEASURED on a live server (FXServer b35245), not inferred. `exports[res][name]`
-- does not answer nil for a missing resource or a missing export -- it RAISES
-- "No such export X in resource Y". `resolve` read it unguarded, and
-- `snapshot()` calls `resolve` on EVERY slot to fill in `resolved`.
--
-- So one provider registered against a resource that does not exist made
-- `GetCapabilities` raise -- and `GetCapabilities` is the first thing anybody
-- runs when the platform is not working. The one command whose entire job is to
-- say which capability is missing was the thing that broke, and it broke in the
-- middle of the answer, on the slot that was broken.
withFakeExports(function()
    -- A resource that is not there at all, which is what FiveM raises on.
    local realExports = exports
    exports = setmetatable({}, {
        __index = function(_, resource)
            return setmetatable({}, {
                __index = function(_, exportName)
                    error(('No such export %s in resource %s'):format(tostring(exportName), tostring(resource)), 0)
                end,
            })
        end,
    })

    expect(CisRegistry.register('database', 'not_a_real_resource:Db'),
        'a provider naming a resource that does not exist still registers')
    expect(CisRegistry.owner('database') == 'not_a_real_resource', 'and is owned by its registrar')

    -- The DIAGNOSTIC. It has to answer, not raise.
    local snapOk, snap = pcall(CisRegistry.snapshot)
    expect(snapOk,
        'snapshot() answers when a provider names a resource that does not exist')
    expect(snapOk and type(snap) == 'table', 'and returns a table')
    expect(snapOk and snap.database ~= nil, 'naming the broken slot')
    expect(snapOk and snap.database.resolved == false,
        ('...with resolved FALSE rather than raising (got %s)')
            :format(tostring(snapOk and snap.database and snap.database.resolved)))
    expect(snapOk and snap.database.owner == 'not_a_real_resource',
        '...and still reporting who owns it, which is the half that is useful')

    -- And a call into it is a REFUSAL with a reason, not an exception in the
    -- caller's thread -- the same contract as any other unresolved slot.
    local called, refused, why = pcall(CisRegistry.call, 'database', 'query', 'SELECT 1', {})
    expect(called, 'a call into a dead provider does not throw')
    expect(called and refused == false, 'it is refused instead')
    expect(called and tostring(why):find('database', 1, true) ~= nil,
        ('with a reason naming the slot (got %s)'):format(tostring(why)))

    -- `has` is the cheap question, and it must not resolve anything at all --
    -- which is what makes it safe to call from a hot path.
    expect(CisRegistry.has('database') == true, 'has() is still true: a provider IS registered')

    CisRegistry.unregister('database')
    exports = realExports
end)

-- Method resolution against the shapes the platform's providers really export.
-- cis_core answers `Count`, cis_keys `lock`, cis_bridge's targets `name` for a
-- slot method called `named`. Each fake below is that shape, so a slot whose
-- method name drifts from its provider fails here rather than in production.
withFakeExports(function()
    local got = {}
    exports.cis_core = {
        CisCoreInventory = function(self)
            return {
                Count = function(countSrc, countItem) got.count = { countSrc, countItem }; return 4 end,
                Has = function(src, hasItem, amount) return amount <= 4 end,
                Add = function() return true end,
            }
        end,
    }
    expect(CisRegistry.register('inventory', 'cis_core:CisCoreInventory'), 'inventory registers')
    expect(CisRegistry.value('inventory', 'count', 3, 'bread') == 4,
        'a lower-case slot method reaches a capitalised provider function')
    expect(got.count[1] == 3 and got.count[2] == 'bread', 'arguments arrive unmoved after resolution')
    expect(CisRegistry.value('inventory', 'has', 3, 'bread', 2) == true, 'has resolves the same way')

    -- Conformance: what the cached table cannot serve, by slot method name.
    local missing = CisRegistry.missing('inventory')
    expect(type(missing) == 'table' and table.concat(missing, ',') == 'remove,snapshot',
        'missing() names exactly the declared methods the provider lacks')
    expect(CisRegistry.snapshot().inventory.missing ~= nil, 'the snapshot carries the missing list')
    expect(CisRegistry.missing('database') == nil, 'an unregistered slot reports nothing to judge')

    exports.cis_bridge = {
        CisBridgeTargetOx = function(self)
            return { name = function() return 'ox_target' end, available = function() return true end }
        end,
    }
    expect(CisRegistry.register('target', 'cis_bridge:CisBridgeTargetOx'), 'target registers')
    expect(CisRegistry.value('target', 'named') == 'ox_target',
        'target.named reaches the adapter name() through the declared provider name')

    -- A dispatcher provider (cis_migrate) takes the action as its first argument.
    exports.cis_migrate = {
        CisMigrateCapability = function(self, action, ...)
            if action == nil then return nil end
            return 'did:' .. tostring(action)
        end,
    }
    expect(CisRegistry.register('migration', 'cis_migrate:CisMigrateCapability'),
        'the migration slot is declared and accepts cis_migrate')
    expect(CisRegistry.value('migration', 'sources') == 'did:sources',
        'a dispatcher provider receives the action name')

    -- A stopped resource releases everything it owned, and only that.
    local released = CisRegistry.releaseOwner('cis_bridge')
    expect(#released == 1 and released[1] == 'target', 'releaseOwner returns exactly the slots it held')
    expect(not CisRegistry.has('target'), 'a released slot is empty')
    local ok, why = CisRegistry.call('target', 'named')
    expect(ok == false and tostring(why):find('no provider') ~= nil,
        'a call into a released slot is an honest refusal')
    expect(CisRegistry.has('inventory'), 'another resource\'s slot survives the release')
    expect(CisRegistry.register('target', 'cis_bridge:CisBridgeTargetOx'),
        'the restarted resource can register again')
    CisRegistry.releaseOwner('cis_bridge')
    CisRegistry.releaseOwner('cis_core')
    CisRegistry.releaseOwner('cis_migrate')
end)

-- The snapshot is what `cis_debug` prints and what GetConfigSummary returns, and
-- it is the answer to "which of my four resources is actually running".
local snap = CisRegistry.snapshot()
expect(type(snap) == 'table', 'the registry can describe itself')
expect(type(snap.database) == 'table', 'every declared slot appears in the snapshot')
expect(snap.database.owner == nil, 'a slot with no provider reports no owner')
local declared, described = 0, 0
for _ in pairs(CisRegistry.SLOTS) do declared = declared + 1 end
for _ in pairs(snap) do described = described + 1 end
expect(declared == described, 'the snapshot describes every declared slot')
expect(CisRegistry.SLOTS.ui ~= nil, '7.9: the ui slot is declared -- a provider registering it must not be refused as unknown')
expect(type(CisRegistry.SLOTS.ui.Notify) == 'string', '7.9: Notify is a declared ui method')
expect(type(CisRegistry.SLOTS.ui.TextUIShow) == 'string', '7.9: TextUIShow is a declared ui method')
expect(type(CisRegistry.SLOTS.ui.Progress) == 'string', '7.9: Progress is a declared ui method')
expect(CisRegistry.SLOTS.ui.Progress:find('Client only', 1, true) ~= nil,
    '7.9: Progress is marked Client only, so a server dispatch is refused by realm')
local okUi, whyUi = CisRegistry.register('ui', function() end)
expect(okUi == true, ('7.9: a ui provider can register (got %s, %s)'):format(tostring(okUi), tostring(whyUi)))
CisRegistry.unregister('ui', 'cis_libs')
expect(CisRegistry.has('ui') == false, '7.9: the test provider released the slot')

-- 7.12 containment is shared. A box around the origin contains (0,0,0) and
-- not a point a kilometre away. Client and server both call this.
do
    local box = { kind = 'box', cx = 0, cy = 0, cz = 0, hx = 2, hy = 2, hz = 2, heading = 0 }
    expect(CisZoneGeom.contains(box, { x = 0, y = 0, z = 0 }) == true, '7.12: origin is inside a 4m box')
    expect(CisZoneGeom.contains(box, { x = 1000, y = 0, z = 0 }) == false, '7.12: a kilometre away is outside')
    local sphere = { kind = 'sphere', cx = 0, cy = 0, cz = 0, radius = 5 }
    expect(CisZoneGeom.contains(sphere, { x = 3, y = 0, z = 0 }) == true, '7.12: 3m is inside a 5m sphere')
    expect(CisZoneGeom.contains(sphere, { x = 6, y = 0, z = 0 }) == false, '7.12: 6m is outside a 5m sphere')
end

-- 7.13 hooks. First veto wins. A raise is a veto.
do
    local id = CisHooks.on('test.give', function(p)
        if p and p.deny then return false, 'nope' end
        return true
    end, { priority = 1 })
    expect(type(id) == 'number', '7.13: on returns a cookie')
    local ok = CisHooks.run('test.give', { deny = false })
    expect(ok == true, '7.13: no veto allows')
    local ok2, why = CisHooks.run('test.give', { deny = true })
    expect(ok2 == false and why == 'nope', ('7.13: a veto refuses (%s)'):format(tostring(why)))
    local raiseId = CisHooks.on('test.give', function() error('boom') end, { priority = 10 })
    local ok3, why3 = CisHooks.run('test.give', { deny = false })
    expect(ok3 == false and type(why3) == 'string' and why3:find('raised', 1, true),
        '7.13: a raising hook is a veto')
    CisHooks.remove(id)
    CisHooks.remove(raiseId)
end

-- 8.1 pass timings. Not CisHistogram (that is job counts).
do
    CisTiming.reset()
    local ok, why = CisTiming.observe('nope', 1)
    expect(ok == false and type(why) == 'string' and why:find('unknown', 1, true),
        ('8.1: unknown series refused (%s)'):format(tostring(why)))
    local nanOk = CisTiming.observe('zonePass', 0/0)
    expect(nanOk == false, '8.1: NaN is refused')
    expect(CisTiming.observe('zonePass', 0.01) == true, '8.1: 0.01 observed')
    expect(CisTiming.observe('zonePass', 0.03) == true, '8.1: 0.03 observed')
    local timingSnap = CisTiming.snapshot()
    expect(timingSnap.zonePass.n == 2, '8.1: n is 2')
    expect(timingSnap.zonePass.min == 0.01, '8.1: min')
    expect(timingSnap.zonePass.max == 0.03, '8.1: max')
    expect(timingSnap.zonePass.le002 == 1, '8.1: 0.01 is in the 0.02 bucket')
    expect(timingSnap.zonePass.le005 == 1, '8.1: 0.03 is in the 0.05 bucket')
    local d = CisDiagnostics.Collect('server')
    expect(type(d.timings) == 'table', '8.1: Collect carries timings')
    expect(d.timings.zonePass.n == 2, '8.1: Collect sees the same n')
    local before = CisDiagnostics.Collect('server')
    CisTiming.observe('zonePass', 1)
    local after = CisDiagnostics.Collect('server')
    local changed = CisDiagnostics.Diff(before, after)
    expect(#changed == 0, ('8.1: Diff ignores timings (%s)'):format(table.concat(changed, '; ')))
    CisTiming.reset()
end

-- ------------------------------------------------------------------ defaults
-- A library with no config file has to have defaults, and they have to be right.
local cfg = CisDefaults.config()
expect(cfg.CallbackTimeout == 10000, 'callback timeout default')
expect(cfg.CheckVersion == false, 'the version check is OFF by default')
expect(cfg.UpdateInterval.Player == 1000, 'player interval default')
expect(cfg.Framework.Type == 'AUTO', 'framework defaults to AUTO, not a guess')
expect(cfg.Framework.Database.Type == 'AUTO', 'database defaults to AUTO')
expect(cfg.Sync.Enabled == true, 'sync defaults on')
expect(cfg.Printing.UseDiscordLogs == false, 'outbound logging defaults OFF')
local sec = CisDefaults.security()
expect(sec.EventPrefix == 'cis_libs', 'event prefix default')
expect(type(sec.AuthorizedResources) == 'table' and #sec.AuthorizedResources == 0,
    'the allow-list is empty, and empty means nobody')
expect(sec.DropPlayer == true, 'a player IS dropped by default')
expect(type(sec.DropPlayer) ~= 'function',
    'DropPlayer is a boolean, because a function cannot cross the boundary')

-- Fresh every call. A consumer that mutates the table it was handed must not be
-- able to corrupt the defaults for whoever asks next.
local d1 = CisDefaults.config()
d1.CallbackTimeout = 1
d1.Framework.Target.Debug = true
expect(CisDefaults.config().CallbackTimeout == 10000, 'config() hands out a fresh table')
expect(CisDefaults.config().Framework.Target.Debug == false, 'nested defaults are fresh too')

-- Merge is recursive, and that is the point: an operator who sets one leaf of
-- Framework.Target must keep the rest of that table rather than inheriting a
-- table with a single key in it, which is what a naive `or` chain produces.
local merged = CisDefaults.merge(CisDefaults.config(), {
    Framework = { Target = { Debug = true } },
    CallbackTimeout = 5000,
})
expect(merged.Framework.Target.Debug == true, 'the operator override lands')
expect(merged.Framework.Target.Type == 'ox_target', 'sibling keys in the same table survive the merge')
expect(merged.Framework.Type == 'AUTO', 'a higher branch of the same table survives the merge')
expect(merged.CallbackTimeout == 5000, 'a top-level override lands')
expect(merged.Sync.Enabled == true, 'an untouched branch keeps its default')

-- Sanitize drops functions at any depth. A config table that arrives from
-- another resource may legally contain one, and a callable sitting in a global is
-- something the client can never receive and the server cannot serialise.
local cleaned = CisDefaults.sanitize({ a = 1, b = function() end, c = { d = function() end, e = 2 } })
expect(cleaned.a == 1, 'scalars survive sanitize')
expect(cleaned.b == nil, 'a function is dropped')
expect(cleaned.c.d == nil, 'a nested function is dropped')
expect(cleaned.c.e == 2, 'a nested scalar survives')
-- Unbounded recursion over a caller-supplied table is a denial-of-service
-- surface, so the depth is capped and a table past it comes back nil.
local deep = { v = 1 }
local node = deep
for _ = 1, 40 do node.next = { v = 1 }; node = node.next end
expect(CisDefaults.sanitize(deep) ~= nil, 'a moderately nested config sanitizes')
expect(select(2, CisDefaults.sanitize(deep, 12)) == nil, 'a pathological config does not recurse forever')

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

-- The report encoder and probe helpers used to be tested here. They belong
-- to the live harness under test/live/, which is a separate FiveM resource.
-- ------------------------------------------------- framework + db detection
-- AUTO detection decides which bridge a server gets, and the failure mode is
-- silent: a wrong answer means a framework that reports itself ready and then
-- returns nil for every player. So the ordering rules are pinned here rather
-- than trusted. Every case below is a server shape someone has actually run.

-- A fake server. `started` is a set; `probed` is which exports answer.
--
-- The first return is a BOOLEAN, because that is exactly what the production
-- call site passes. An earlier version of this helper returned the string
-- 'started', so the suite asserted a contract production never used -- every
-- case passed, and AUTO detection went on to report "no supported framework"
-- against a live qbx_core. A test helper that does not match the call site is
-- not a test of the call site.
local function server(started, probed, versions)
    return function(name) return started[name] == true end,
        function(name) return (versions or {})[name] end,
        function(res, exportName)
            if not probed[res] then return false end
            local list = probed[res]
            if list == true then return true end
            return list[exportName] == true
        end
end

-- AUTO on a qbx_core server. The headline case: qbx_core removed GetCoreObject
-- in 1.9, so a probe on that export alone would report "no framework" on a
-- perfectly good server.
local s, v, p = server({ qbx_core = true }, { qbx_core = { GetPlayer = true } }, { qbx_core = '1.11.0' })
local r = CisDetect.framework('AUTO', nil, s, v, p)
expect(r.name == 'QBOX', 'AUTO detects qbx_core as QBOX')
expect(r.resource == 'qbx_core', 'AUTO names the resource it found')
expect(r.version == '1.11.0', 'AUTO reports the version it read')
expect(r.how == 'detected', 'AUTO records that it detected rather than was told')

-- A server with BOTH qbx_core and qb-core on disk. Order is load-bearing:
-- qbx_core is the modern one and must win, or every money call goes to a
-- framework the operator has already migrated away from.
s, v, p = server({ qbx_core = true, ['qb-core'] = true },
    { qbx_core = { GetPlayer = true }, ['qb-core'] = { GetCoreObject = true } },
    { qbx_core = '1.11.0', ['qb-core'] = '2.17.5' })
r = CisDetect.framework('AUTO', nil, s, v, p)
expect(r.name == 'QBOX', 'with both present, qbx_core wins over qb-core')
expect(r.version == '1.11.0', 'the version reported is the winning framework, not the loser')

-- A qb-core-only server.
s, v, p = server({ ['qb-core'] = true }, { ['qb-core'] = { GetCoreObject = true } }, { ['qb-core'] = '2.17.5' })
r = CisDetect.framework('AUTO', nil, s, v, p)
expect(r.name == 'QBCORE', 'AUTO detects a qb-core-only server as QBCORE')

-- A started resource whose probe export is missing is NOT a match. A lookalike
-- resource must not be mistaken for the real thing.
s, v, p = server({ ["qb-core"] = true }, { ['qb-core'] = { GetCoreObject = false } }, {})
r = CisDetect.framework('AUTO', nil, s, v, p)
expect(r.name == 'NONE', 'a started resource without the probe export is not a match')

-- An explicit, correct Type is honoured and reported as configured, not
-- detected -- the distinction is what cis_debug prints.
s, v, p = server({ ['qb-core'] = true }, { ['qb-core'] = { GetCoreObject = true } })
r = CisDetect.framework('QBCORE', nil, s, v, p)
expect(r.name == 'QBCORE' and r.how == 'configured', 'an explicit Type is honoured and marked configured')

-- An explicit Type for something not started says so rather than implying a
-- bridge that is not there.
s, v, p = server({}, {})
r = CisDetect.framework('QBOX', nil, s, v, p)
expect(r.name == 'QBOX' and r.resource == nil, 'a configured framework that is not started reports no resource')
expect(r.reason:find('not started') ~= nil, 'and the reason says so in words')

-- NONE is an explicit choice, not a failure to detect.
s, v, p = server({ qbx_core = true }, { qbx_core = { GetPlayer = true } })
r = CisDetect.framework('NONE', nil, s, v, p)
expect(r.name == 'NONE' and r.how == 'configured', 'NONE is honoured even on a server that has a framework')

-- A custom adapter wins over both AUTO and an explicit Type: the operator
-- wired one up precisely because the built-in branches would not serve them.
s, v, p = server({ my_framework = true }, { my_framework = { GetPlayer = true } }, { my_framework = '2.0' })
r = CisDetect.framework('AUTO', { resource = 'my_framework', name = 'myframework' }, s, v, p)
expect(r.name == 'MYFRAMEWORK', 'a custom adapter is used and takes its configured name')
expect(r.how == 'custom' and r.resource == 'my_framework', 'a custom adapter is reported as custom')
r = CisDetect.framework('QBCORE', { resource = 'my_framework', name = 'myframework' }, s, v, p)
expect(r.name == 'MYFRAMEWORK' and r.how == 'custom',
    'a custom adapter wins over an explicit Type too')

-- A custom adapter that is not started must say so rather than silently
-- falling back to a stock framework.
s, v, p = server({ qbx_core = true }, { qbx_core = { GetPlayer = true } })
r = CisDetect.framework('AUTO', { resource = 'not_running' }, s, v, p)
expect(r.name == 'NONE', 'a custom adapter that is not started does not fall back to a stock framework')
expect(r.reason:find('not started') ~= nil, 'and the reason names the adapter that is missing')

-- versionAtLeast, the ESX-legacy split.
expect(CisDetect.versionAtLeast('5.0.0', '5.0.0'), 'equal versions satisfy the bound')
expect(CisDetect.versionAtLeast('5.1.0', '5.0.0'), 'a greater version satisfies the bound')
expect(not CisDetect.versionAtLeast('1.9.0', '5.0.0'), 'a lower version does not')
expect(CisDetect.versionAtLeast('1.9', '1.9.0'), 'a missing component counts as zero')
expect(CisDetect.versionAtLeast('1.9.0-beta3', '1.9.0'), 'a non-numeric tail does not break the comparison')
expect(not CisDetect.versionAtLeast(nil, '1.0.0'), 'a missing version never satisfies a bound')

-- Database detection, same contract.
s, v = server({ oxmysql = true }, true, { oxmysql = '2.6.0' })
local d = CisDetect.database('AUTO', s, v)
expect(d.name == 'oxmysql' and d.version == '2.6.0', 'AUTO detects oxmysql and its version')
s, v = server({ ['mysql-async'] = true }), function(name) return name == 'mysql-async' and '0.6.2' or nil end
d = CisDetect.database('AUTO', s, v)
expect(d.name == 'mysql-async', 'AUTO detects mysql-async when it is the only one running')
s, v = server({}), function() return nil end
d = CisDetect.database('AUTO', s, v)
expect(d.name == 'NONE' and d.how == 'detected', 'no driver started is reported as detected NONE, not a crash')
s, v = server({ oxmysql = true }), function() return '2.6.0' end
d = CisDetect.database('NONE', s, v)
expect(d.name == 'NONE' and d.how == 'configured', 'database NONE is honoured')


-- ============================== 3.10: A LOOP THAT RAISES MUST SURVIVE IT
--
-- Every `while true do ... Wait(n) end` in cis_libs used to run its body bare.
-- A raise inside one -- a consumer's handler, a driver answering with the wrong
-- shape -- unwound the thread, and a thread that has unwound is GONE. It does
-- not come back on the next tick and nothing reports it, so the loop that was
-- sweeping expired callbacks or streaming records simply stops, and the symptom
-- arrives minutes later somewhere else entirely.
--
-- The assertion that matters is not "it counts" and not "it logs". It is that
-- the loop is STILL RUNNING afterwards.
do
    -- Minimal host surface: the guard needs a clock, a Wait that lets the test
    -- stop the loop, and the counter it increments.
    local savedGetGameTimer = rawget(_G, 'GetGameTimer')
    local savedWait = rawget(_G, 'Wait')
    local savedLogging = rawget(_G, 'Logging')
    local clock = 0
    _G.GetGameTimer = function() return clock end

    local waited = 0
    _G.Wait = function(ms)
        waited = waited + 1
        clock = clock + (tonumber(ms) or 0)
        if waited >= 4 then
            error('STOP', 0)
        end
    end
    local logged = {}
    _G.Logging = { Error = function(msg) logged[#logged + 1] = tostring(msg) end }

    CisLoopGuard.Raises = {}
    local before = CisDiagnostics.Count('loopErrors')

    local ticks = 0
    local good = 0
    local loop = CisLoopGuard.Run('test.loop', 1000, function()
        ticks = ticks + 1
        -- Fails on the second tick and only the second. A loop that dies on
        -- tick one is caught by any later assertion; one that dies halfway is
        -- the case worth having.
        if ticks == 2 then
            error('injected failure')
        end
        good = good + 1
    end)

    local ok, stopReason = pcall(loop)

    -- The SENTINEL is how the test stops an infinite loop, so `ok` being false
    -- is expected and is NOT the property under test. The property is what
    -- happened BEFORE it: the loop kept going after the body raised. Asserting
    -- `ok` would be asserting that my own test harness worked.
    expect(not ok and stopReason == 'STOP',
        ('the loop is only stopped by the test sentinel, never by the body (%s)')
            :format(tostring(stopReason)))
    expect(ticks >= 4,
        ('the loop KEPT RUNNING after the raise (ticks=%s)'):format(tostring(ticks)))
    expect(good == 3,
        ('every healthy tick after the failure still ran (good=%s of %s)')
            :format(tostring(good), tostring(ticks)))
    expect((CisLoopGuard.Raises['test.loop'] or 0) == 1,
        ('the raise is counted against the loop that raised it (%s)')
            :format(tostring(CisLoopGuard.Raises['test.loop'])))
    expect(CisDiagnostics.Count('loopErrors') == before + 1,
        'and it is counted in the diagnostics the harness diffs')
    expect(#logged == 1 and logged[1]:find('test.loop', 1, true) ~= nil,
        ('and it is logged ONCE, naming the loop (%d line(s))'):format(#logged))

    -- THROTTLED: a loop that raises every tick must not turn the console into
    -- the thing the operator learns to ignore.
    CisLoopGuard.Raises = {}
    logged = {}
    clock = 0
    local alwaysBad = 0
    local loop2 = CisLoopGuard.Run('test.noisy', 1000, function()
        alwaysBad = alwaysBad + 1
        error('every tick')
    end)
    local limit = 0
    _G.Wait = function()
        limit = limit + 1
        clock = clock + 1000
        if limit >= 30 then error('STOP', 0) end
    end
    pcall(loop2)
    -- EXACTLY 3, not "few". The clock advances 1000 ms per tick, so the throttle
    -- logs on the FIRST raise (nothing has been logged yet), then at 10 000 ms
    -- and 20 000 ms. Asserting an upper bound would pass a guard that logs once
    -- and never again, which is the opposite defect; the arithmetic is the
    -- check.
    expect(#logged == 3,
        ('a loop raising every tick is logged about every ten seconds, not every '
            .. 'tick (expected 3, got %d in 30 s)'):format(#logged))
    expect((CisLoopGuard.Raises['test.noisy'] or 0) == 30,
        ('and every one of them is still COUNTED even while quiet (%s)')
            :format(tostring(CisLoopGuard.Raises['test.noisy'])))

    _G.GetGameTimer = savedGetGameTimer
    _G.Wait = savedWait
    _G.Logging = savedLogging
    CisLoopGuard.Raises = {}
end

-- ============================================= DEC: THE DECLARED CONTRACT
--
-- CIS_LIBS_API_CONTRACT.md §3 documented an optional third argument to
-- RegisterCapability -- `{ api = 1, requiredMethods = { ... } }` -- and no such
-- parameter existed. `exports('RegisterCapability', function(slot, provider))`
-- on both the server and the client. A provider that passed a contract had it
-- silently dropped and went on believing it was checked.
--
-- That is the worst possible shape for a contract: it reads as protection and
-- provides none, and it fails invisibly BECAUSE the caller did the right thing.
-- So these tests pin the argument existing, refusing by name, and surviving a
-- restart -- because an argument that works once and vanishes on re-registration
-- is the same defect wearing a hat.
do
    -- A well-formed contract is ACCEPTED and recorded.
    local okContract = CisRegistry.register('database', function(op)
        return op
    end, { api = 1, requiredMethods = { 'query', 'single' } })
    expect(okContract == true, 'a contract naming real methods is accepted')
    local recorded = CisRegistry.contract('database')
    expect(type(recorded) == 'table', 'the declared contract is recorded on the slot')
    expect(recorded and recorded.api == 1,
        'and its api version is readable')
    expect(recorded and type(recorded.requiredMethods) == 'table'
        and #recorded.requiredMethods == 2,
        'and its requiredMethods survive the boundary')

    -- A method the SLOT does not declare is refused BY NAME, before the slot is
    -- touched. The refusal has to name the real method list, or the operator is
    -- left guessing which of eleven names they got wrong.
    --
    -- `migration` is used rather than `security` because `security` is already
    -- held by an earlier block in this suite, and "the slot is still empty" would
    -- then be a false failure for a correct refusal.
    local okBad, whyBad = CisRegistry.register('migration', function() end,
        { api = 1, requiredMethods = { 'DropTheServer' } })
    expect(okBad == false, 'a required method the slot does not declare is refused')
    expect(type(whyBad) == 'string' and whyBad:find('DropTheServer', 1, true) ~= nil,
        'and the refusal names the offending method')
    expect(type(whyBad) == 'string' and whyBad:find('plan', 1, true) ~= nil,
        'and lists what the slot DOES declare, so the fix is readable')
    expect(CisRegistry.has('migration') == false,
        'the refused registration left the slot empty -- it is not held by '
            .. 'something that could never have served it')

    -- A refused contract must not DISPLACE a working provider either. `security`
    -- is held by an earlier block, so this is the real version of the
    -- refusal happens before the slot is touched, not after it has been taken.
    local heldBefore = CisRegistry.owner('security')
    local okSteal = CisRegistry.register('security', function() return 'REPLACED' end,
        { api = 1, requiredMethods = { 'NoSuchMethod' } })
    expect(okSteal == false,
        'b: a bad contract is refused even against an already-held slot')
    expect(CisRegistry.owner('security') == heldBefore,
        'c: and the working provider still holds it -- the refusal is checked '
            .. 'before the slot is touched, not after')
    expect(CisRegistry.call('security', 'drop', 1, 'reason') ~= 'REPLACED',
        'd: and the slot still dispatches to the original provider')

    -- Malformed contracts are refused rather than half-accepted.
    -- A STRING is the old unused third argument (documented as a version) and
    -- is ignored, so a number is the shape that proves the type gate.
    local okStr = CisRegistry.register('discord', function() end, '2.1')
    expect(okStr == true, 'b: a version STRING is ignored rather than refused')
    CisRegistry.unregister('discord', 'cis_libs')
    local okType, whyType = CisRegistry.register('discord', function() end, 12)
    expect(okType == false, 'a non-table contract is refused')
    expect(type(whyType) == 'string' and whyType:find('table', 1, true) ~= nil,
        'and says what it wanted a table')

    local okApi, whyApi = CisRegistry.register('discord', function() end, { api = 'one' })
    expect(okApi == false, 'a non-numeric api is refused')
    expect(type(whyApi) == 'string' and whyApi:find('api', 1, true) ~= nil,
        'and names the field')
    local okTbl, whyTbl = CisRegistry.register('discord', function() end,
        { api = 1, requiredMethods = { {} } })
    expect(okTbl == false, 'b: a non-string requiredMethods entry is refused')
    expect(type(whyTbl) == 'string' and whyTbl:find('string', 1, true) ~= nil,
        'c: and says it wanted a string')
    expect(CisRegistry.has('discord') == false,
        'neither malformed contract left the slot held')

    -- Omitting the contract is ALWAYS allowed. cis_libs cannot invent a promise
    -- a provider never made, and refusing unknown would refuse every third-party
    -- resource and every existing internal call site.
    local okNone = CisRegistry.register('discord', function() end)
    expect(okNone == true, 'no contract at all is still accepted')
    expect(CisRegistry.contract('discord') == nil,
        'and records no contract rather than an empty one')

    -- THE RESTART CASE. A provider re-registering after onResourceStart is the
    -- ordinary case, not an edge case, and a bare re-register must not silently
    -- DOWNGRADE the recorded contract to "no promise" -- that is the same
    -- defect as never having had one, and it appears at exactly the moment a
    -- provider is least able to notice.
    CisRegistry.register('discord', function() end,
        { api = 1, requiredMethods = { 'log' } })
    expect(CisRegistry.contract('discord') ~= nil,
        'a re-registration with a contract records it')
    CisRegistry.register('discord', function() end)
    local afterRestart = CisRegistry.contract('discord')
    expect(afterRestart ~= nil and type(afterRestart.requiredMethods) == 'table'
        and #afterRestart.requiredMethods == 1,
        'a bare re-registration KEEPS the contract already recorded, so a '
            .. 'restart cannot silently drop a provider\'s promise')
    expect(CisRegistry.has('discord') == true,
        'and the slot is still held afterwards')

    for _, slot in ipairs({ 'database', 'discord' }) do
        CisRegistry.unregister(slot, 'cis_libs')
    end
end

io.write(('passed=%d failed=%d\n'):format(passed, failed))
if failed > 0 then
    os.exit(1)
end
