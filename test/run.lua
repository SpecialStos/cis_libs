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
    local missing, why = CisRegistry.call('database', 'transaction', {}, {})
    expect(missing == false, 'a method the provider does not implement is refused')
    expect(tostring(why):find('transaction') ~= nil, 'the refusal names the method that is missing')
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

-- Method resolution against the shapes the platform's providers really export.
-- cis_core answers `Count`, cis_keys `lock`, cis_bridge's targets `name` for a
-- slot method called `named`. Each fake below is that shape, so a slot whose
-- method name drifts from its provider fails here rather than in production.
withFakeExports(function()
    local got = {}
    exports.cis_core = {
        CisCoreInventory = function(self)
            return {
                Count = function(src, item) got.count = { src, item }; return 4 end,
                Has = function(src, item, amount) return amount <= 4 end,
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

-- ------------------------------------------------------------------ defaults
-- A library with no config file has to have defaults, and they have to be right.
local d = CisDefaults.config()
expect(d.CallbackTimeout == 10000, 'callback timeout default')
expect(d.CheckVersion == false, 'the version check is OFF by default')
expect(d.UpdateInterval.Player == 1000, 'player interval default')
expect(d.Framework.Type == 'AUTO', 'framework defaults to AUTO, not a guess')
expect(d.Framework.Database.Type == 'AUTO', 'database defaults to AUTO')
expect(d.Sync.Enabled == true, 'sync defaults on')
expect(d.Printing.UseDiscordLogs == false, 'outbound logging defaults OFF')
local s = CisDefaults.security()
expect(s.EventPrefix == 'cis_libs', 'event prefix default')
expect(type(s.AuthorizedResources) == 'table' and #s.AuthorizedResources == 0,
    'the allow-list is empty, and empty means nobody')
expect(s.DropPlayer == true, 'a player IS dropped by default')
expect(type(s.DropPlayer) ~= 'function',
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

-- The report encoder and probe helpers used to be tested here. They belong to
-- cis_libstest, which is a separate repository and a separate FiveM resource,
-- and a change to either should be caught by that project's own suite:
--   https://github.com/SpecialStos/cis_libstest
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
s, v, p = server({ oxmysql = true }, true, { oxmysql = '2.6.0' })
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


io.write(('passed=%d failed=%d\n'):format(passed, failed))
if failed > 0 then
    os.exit(1)
end
