-- Client-side behaviour tests, under fengari with no FiveM server.
--
-- The client files are where the natives are, so they are also the only place a
-- signature bug can hide: `SET_VEHICLE_EXTRA`'s third parameter is `disable`,
-- not `toggle`, and nothing but a live game or a stub that RECORDS its arguments
-- can tell a caller which one this file believes. Every stub below records what
-- it was asked, so a test asserts on the effect rather than on "it did not
-- throw".
--
-- Suites here are loaded by test/run.js in their own Lua state (see T2), so a
-- stub defined here cannot leak into contracts.lua or modules.lua.

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

-- ============================================================ the stub harness
--
-- `natives` is the recorder table. A test writes into it, calls the file under
-- test, and reads back what the natives were asked. Saving and restoring every
-- global is deliberate: these files install REAL globals (`SetVehicleProperties`
-- and friends are not local), so loading one twice in one process would have the
-- second load overwrite the first's helpers and make a later assertion pass
-- against the wrong code.
local function newEnv(opts)
    opts = opts or {}
    local env = {
        natives = {},
        lines = {},
        saved = {},
        clock = opts.clock or 0,
        coords = opts.coords or { x = 0.0, y = 0.0, z = 0.0 },
        invoking = opts.invoking,
    }

    env.save = function(name)
        env.saved[#env.saved + 1] = { name = name, value = rawget(_G, name) }
    end

    function env.print(fmt, ...)
        local text = select('#', ...) > 0 and string.format(fmt, ...) or tostring(fmt)
        env.lines[#env.lines + 1] = text
    end
    print = env.print

    for _, name in ipairs({
        'Globals', 'Config', 'Security', 'Logging', 'CisLog', 'CisInvokingAllowed',
        'CisSyncEnabled', 'exports', 'print', 'Wait', 'CreateThread',
        'GetGameTimer', 'GetCurrentResourceName', 'GetInvokingResource',
        'AddEventHandler', 'onClientResourceStop', 'RegisterNetEvent',
        'TriggerEvent', 'TriggerServerEvent', 'RegisterCommand',
        'Citizen', 'RequestModel', 'HasModelLoaded', 'SetModelAsNoLongerNeeded',
        'joaat', 'NetworkGetEntityIsNetworked', 'NetworkDoesNetworkIdExist',
        'RequestModelTimeout', 'SetVehicleProperties', 'CreatePed', 'CreateObject',
        'CreateVehicle', 'DeleteEntity', 'DoesEntityExist', 'FreezeEntityPosition',
        'SetEntityCoords', 'SetEntityHeading', 'PlayerPedId', 'GetPlayerPed',
        'GetEntityCoords', 'IsEntityDead', 'GetGameBuildNumber',
        'AddEventHandler', 'PlayerId', 'NetworkGetEntityOwner', 'CisCache',
    }) do
        env.save(name)
    end

    -- Threads are COLLECTED, never run. Several client files start a
    -- `while true do Wait(...)` sweeper at load, and a stub whose Wait advances
    -- a counter would run that loop until the counter overflowed -- a test suite
    -- that hangs rather than fails. A test that wants a thread's body calls
    -- `env.threads[i]()` itself, with a Wait that advances.
    function CreateThread(fn)
        env.threads = env.threads or {}
        env.threads[#env.threads + 1] = fn
    end
    function Wait(ms)
        env.clock = env.clock + (tonumber(ms) or 0)
    end
    function GetGameTimer() return env.clock end
    function GetCurrentResourceName() return 'cis_libs' end
    function GetInvokingResource() return env.invoking end
    function GetGameBuildNumber() return 2372 end
    function joaat(s)
        -- Good enough to be a stable hash; nothing here depends on the real
        -- Jenkins one, only that it is deterministic and accepts a number.
        if type(s) == 'number' then return s end
        local h = 0
        for i = 1, #s do
            h = (h * 31 + s:byte(i)) % 0x7FFFFFFF
        end
        return h
    end
    function RequestModel() return true end
    function HasModelLoaded() return true end
    function SetModelAsNoLongerNeeded() end
    function NetworkGetEntityIsNetworked() return false end
    function NetworkDoesNetworkIdExist() return true end
    function PlayerPedId() return env.ped or 1 end
    function GetPlayerPed() return env.ped or 1 end
    function GetEntityCoords() return env.coords end
    function IsEntityDead() return false end
    function PlayerId() return 0 end
    function NetworkGetEntityOwner() return 1 end
    -- Event handlers are recorded rather than dropped: L-C7 and L-C8 assert on
    -- what a stop sweep is bound to, so the harness has to be able to fire one.
    env.handlers = {}
    function AddEventHandler(name, fn)
        env.handlers[name] = env.handlers[name] or {}
        env.handlers[name][#env.handlers[name] + 1] = fn
    end
    function env.fire(name, ...)
        for _, fn in ipairs(env.handlers[name] or {}) do fn(...) end
    end

    function env.reset()
        for i = #env.saved, 1, -1 do
            local entry = env.saved[i]
            if entry.name == '__metatable' then
                setmetatable(_G, entry.value)
            else
                _G[entry.name] = entry.value
            end
        end
        env.saved = {}
    end

-- Any native this harness was not told about answers nil instead of raising.
    --
    -- Deliberate, and it is what makes these suites practical: client/vehicle.lua
    -- alone calls around eighty natives, and hand-listing every one of them in
    -- every test would bury the two or three a test actually cares about. A test
    -- that cares about a native STUBS it above, which takes precedence -- this
    -- fallback only fires for the ones it does not mention, and those are the
    -- ones whose value cannot affect the assertion.
    --
    -- The guard keeps it away from everything that is not a native: a typo in a
    -- global name has to raise, or a test would silently assert against a stub
    -- standing in for a function that does not exist.
    local function nativeFallback(_, key)
        if type(key) ~= 'string' then
            return nil
        end
        -- Prefix list, matched with find rather than sub(1, n): "Does" is four
        -- letters and a fixed-width cut silently drops it.
        for _, prefix in ipairs({
            'Get', 'Is', 'Has', 'Set', 'Add', 'Remove', 'Does', 'Can',
            'Create', 'Delete', 'Freeze', 'Request', 'Clear', 'Toggle',
        }) do
            if key:sub(1, #prefix) == prefix then
                -- A getter answers a number and a predicate answers a boolean.
                -- Collapsing both to nil raises inside the library's own
                -- arithmetic (`math.floor(health + 0.5)`), which turns a
                -- missing stub into a crash that looks like a bug in the file
                -- under test. 0 is the neutral value for a getter and false is
                -- the honest answer for "does this exist".
                if prefix == 'Is' or prefix == 'Has' or prefix == 'Does'
                    or prefix == 'Can' then
                    return function() return false end
                end
                return function() return 0 end
            end
        end
        return nil
    end

    setmetatable(_G, { __index = nativeFallback })
    env.saved[#env.saved + 1] = { name = '__metatable', value = getmetatable(_G) }

    return env
end

local function loadModule(rel)
    local chunk = assert(loadfile('./' .. rel))
    chunk()
end

-- ======================================================= 1. vehicle extras
--
-- `SET_VEHICLE_EXTRA`'s THIRD parameter is `disable`. The getter above stores
-- 0 for an extra that is ON and 1 for one that is OFF, so the stored value IS
-- the `disable` flag and has to be passed through. Passing `off == 0` inverts
-- every restored extra: a siren off, a lightbar on.
--
-- Recorded rather than asserted on the return value, because the native
-- returns nothing and the bug is invisible to any caller that does not look.
do
    local env = newEnv()

    -- `DoesExtraExist` is the native's real name. Spelling it `IsExtraExist`
    -- would leave the real one to the harness fallback, which answers false --
    -- so the getter would quietly produce an EMPTY extras table and every
    -- assertion below would pass against nothing.
    local function stub(extraOn)
        function DoesEntityExist() return true end
        function DoesExtraExist() return true end
        function IsVehicleExtraTurnedOn() return extraOn end
        function GetClosestVehicle() return 0 end
        function SetVehicleExtra(vehicle, id, disable)
            env.natives[#env.natives + 1] = { vehicle = vehicle, id = id, disable = disable }
        end
        function SetVehicleModKit() end
        function GetVehicleColours() return 1, 2 end
        function GetVehicleExtraColours() return 0, 0 end
        function IsPedInAnyVehicle() return false end
        function GetVehiclePedIsIn() return 0 end
        function IsEntityAMissionEntity() return false end
    end

    stub(true)
    loadModule('client/vehicle.lua')

    env.natives = {}
    SetVehicleProperties(7, { extras = { [1] = 0 } })
    check(#env.natives == 1, 'one extra produced one SetVehicleExtra call')
    check(env.natives[1] and env.natives[1].vehicle == 7 and env.natives[1].id == 1,
        'SetVehicleExtra receives the vehicle and the numeric extra id')
    -- 0 in the table means "the extra was ON", so the native must be told to
    -- NOT disable it.
    check(env.natives[1] and env.natives[1].disable == false,
        'an extra stored as 0 (it was ON) is passed as disable=false, not true')

    env.natives = {}
    SetVehicleProperties(7, { extras = { [1] = 1 } })
    check(env.natives[1] and env.natives[1].disable == true,
        'an extra stored as 1 (it was OFF) is passed as disable=true, not false')

    -- And the round trip: what the getter wrote, the setter must reproduce.
    -- This is the property that actually matters -- a value read back out of
    -- GetVehicleProperties has to mean the same thing on the way in.
    --
    -- The `stub(false)` closure is not enough: `IsVehicleExtraTurnedOn` was
    -- closed over by the earlier `stub(true)` and the second stub does not
    -- reach it, so the getter would still see the extra as on. Assigning the
    -- global directly is what actually changes what the reader sees.
    env.natives = {}
    stub(false)
    local props = GetVehicleProperties(7)
    check(props and props.extras and props.extras[1] == 1,
        ('the getter stores 1 for an extra that is off (extras=%s)')
            :format(tostring(props and props.extras and props.extras[1])))
    SetVehicleProperties(7, { extras = props.extras })
    check(env.natives[1] and env.natives[1].disable == true,
        'getter output fed straight back to the setter disables the same extra')

    env.reset()
end

-- ==================================================================== report
for i = 1, #failures do
    io.stderr:write('FAIL(client): ' .. failures[i] .. '\n')
end
io.write(('client passed=%d failed=%d\n'):format(passed, failed))
if failed > 0 then
    os.exit(1)
end