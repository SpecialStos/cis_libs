-- Binding tests for the exports call convention.
--
-- The `self` trap: `exports[resource][name](...)` is an UNBOUND method call in
-- FiveM. The exports table is expected as the first argument, so calling the
-- bracket form without it shifts every argument one slot left. That bug lived
-- in `init.lua`'s exportCall and silently corrupted every API call in the
-- library -- a zone created as (kind, name, coords) arrived as
-- (name, coords, size), so the zone's name became its own coordinates and
-- creation returned false with no error raised.
--
-- No FiveM server required. The stub below models the real boundary semantics,
-- and the canary proves the model is faithful, so a regression cannot pass by
-- accident.
--
-- Every assertion is type-safe: a shifted argument lands in the wrong slot and
-- the test reports WHICH field broke, rather than throwing on a string.

local passed, failed = 0, 0
local failures = {}

TEST_CASES = {}
local function check(cond, msg)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        failures[#failures + 1] = msg
    end
    TEST_CASES[#TEST_CASES + 1] = { name = msg, status = cond and 'passed' or 'failed' }
end

-- Declared first: loadFor closes over it, and a Lua local is not visible to a
-- function defined before its declaration.
local root = (arg and arg[0] or '.'):gsub('[/\\]test[/\\]binding%.lua$', '')
if root == (arg and arg[0] or '.') then
    root = '.'
end

-- ------------------------------------------------------------------- helpers
-- Safe field access: a shifted argument may be any type at all.
local function f(t, key)
    if type(t) ~= 'table' then
        return nil
    end
    return t[key]
end

local function describe(v)
    if type(v) == 'table' then
        if f(v, 'x') ~= nil then
            return ('{%s,%s,%s}'):format(tostring(f(v, 'x')), tostring(f(v, 'y')), tostring(f(v, 'z')))
        end
        return 'table'
    end
    return ('%s(%s)'):format(type(v), tostring(v))
end

-- ---------------------------------------------------------------- the stub
-- Records raw positional arguments. `self` occupies slot 1 exactly as a real
-- FiveM export expects, which is what makes a shift observable.
local calls

local function recorder(...)
    local n = select('#', ...)
    local raw = { n = n }
    for i = 1, n do
        raw[i] = select(i, ...)
    end
    calls[#calls + 1] = raw
    return true
end

local EXPORTS = setmetatable({}, {
    __index = function()
        return recorder
    end,
})

-- The only FiveM surface `init.lua` touches at load time.
GetCurrentResourceName = function() return 'cis_libstest' end
exports = { cis_libs = EXPORTS }

-- CreateZone(kind, name, a, b, options) -> recorder slots
--   correct call: slot1=self, slot2=kind, slot3=name, slot4=a, slot5=b, slot6=options
local function loadFor(realm)
    calls = {}
    IsDuplicityVersion = function() return realm == 'server' end
    Cis = nil
    local chunk = assert(loadfile(root .. '/init.lua'))
    chunk()
end

-- -------------------------------------------------------------- consumer path
loadFor('client')

calls = {}
Cis.zones.box('shop', { x = 1, y = 2, z = 3 }, { x = 4, y = 5, z = 6 }, {})
local zc = calls[1]
check(zc ~= nil, 'Cis.zones.box reached the export')
check(f(zc, 2) == 'box', ('zone kind in slot 2 (got %s)'):format(describe(f(zc, 2))))
check(f(zc, 3) == 'shop', ('zone name in slot 3 (got %s)'):format(describe(f(zc, 3))))
check(f(f(zc, 4), 'x') == 1, ('zone centre in slot 4 (got %s)'):format(describe(f(zc, 4))))
check(f(f(zc, 5), 'x') == 4, ('zone size in slot 5 (got %s)'):format(describe(f(zc, 5))))
check(type(f(zc, 6)) == 'table', ('zone options in slot 6 (got %s)'):format(describe(f(zc, 6))))

calls = {}
-- sphere: Cis.zones.sphere(name, centre, radius, options) -> a=centre, b=radius
Cis.zones.sphere('beacon', { x = 1, y = 2, z = 3 }, 10.0, {})
local sc = calls[1]
check(sc ~= nil, 'Cis.zones.sphere reached the export')
check(f(sc, 3) == 'beacon', ('sphere name in slot 3 (got %s)'):format(describe(f(sc, 3))))
check(f(sc, 5) == 10.0, ('sphere radius in slot 5 (got %s)'):format(describe(f(sc, 5))))

calls = {}
Cis.zones.remove('shop')
local rc = calls[1]
check(rc ~= nil, 'Cis.zones.remove reached the export')
check(f(rc, 2) == 'shop', ('remove name in slot 2 (got %s)'):format(describe(f(rc, 2))))
check(rc.n == 2, ('remove passed exactly one argument (got %d)'):format(rc.n or -1))

calls = {}
Cis.player.near({ x = 5, y = 6, z = 7 }, 12.0)
local nc = calls[1]
check(nc ~= nil, 'Cis.player.near reached the export')
check(f(f(nc, 2), 'x') == 5, ('near coords in slot 2 (got %s)'):format(describe(f(nc, 2))))
check(f(nc, 3) == 12.0, ('near distance in slot 3 (got %s)'):format(describe(f(nc, 3))))

-- ---------------------------------------------------------------- server path
loadFor('server')

calls = {}
Cis.db.query('SELECT 1', { 7 })
local dc = calls[1]
check(dc ~= nil, 'Cis.db.query reached the export')
check(f(dc, 2) == 'SELECT 1', ('db sql in slot 2 (got %s)'):format(describe(f(dc, 2))))
check(type(f(dc, 3)) == 'table', ('db params in slot 3 (got %s)'):format(describe(f(dc, 3))))

calls = {}
Cis.inventory.count(3, 'bread')
local ic = calls[1]
check(ic ~= nil, 'Cis.inventory.count reached the export')
check(f(ic, 2) == 3, ('inventory src in slot 2 (got %s)'):format(describe(f(ic, 2))))
check(f(ic, 3) == 'bread', ('inventory item in slot 3 (got %s)'):format(describe(f(ic, 3))))

calls = {}
Cis.callback.register('shop:buy', 'cis_shop:handleBuy')
local cc = calls[1]
check(cc ~= nil, 'Cis.callback.register reached the export')
check(f(cc, 2) == 'shop:buy', ('callback name in slot 2 (got %s)'):format(describe(f(cc, 2))))
check(f(cc, 3) == 'cis_shop:handleBuy', ('remote handler in slot 3 (got %s)'):format(describe(f(cc, 3))))

-- ------------------------------------------------------------------- canary
-- Prove the stub actually models the trap. If the bracket form did not shift
-- arguments, every assertion above could pass while the real boundary broke.
calls = {}
recorder('box', 'shop', { x = 1 }, { x = 4 }, {})
local canary = calls[1]
check(canary ~= nil, 'CANARY: the stub recorded a bracket-form call')
check(f(canary, 2) == 'shop',
    'CANARY: bracket form shifts arguments (proves the stub models the trap)')
check(f(canary, 3) ~= 'shop',
    'CANARY: a shifted call corrupts the name slot, which is what these tests detect')

-- --------------------------------------------------------------------- report
for i = 1, #failures do
    io.stderr:write('FAIL(binding): ' .. failures[i] .. '\n')
end
io.write(('binding passed=%d failed=%d\n'):format(passed, failed))
if failed > 0 then
    os.exit(1)
end
