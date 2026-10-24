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

-- A handler as it arrives from ANOTHER resource: not a Lua function but a table
-- carrying `__cfx_functionReference`, callable through its metatable. Every API
-- that takes a handler has to accept this shape, and `type(fn) == 'function'`
-- refuses it.
local function funcref(fn)
    return setmetatable({ __cfx_functionReference = 'test:' .. tostring(fn) }, {
        __call = function(_, ...) return fn(...) end,
    })
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
        env.saved[#env.saved + 1] = { name = name, value = rawget(_ENV, name) }
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
        'AddEventHandler', 'RegisterNetEvent',
        'TriggerEvent', 'TriggerServerEvent', 'RegisterCommand',
        'Citizen', 'promise', 'RequestModel', 'HasModelLoaded', 'SetModelAsNoLongerNeeded',
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

    -- Drive the LAST collected thread for N passes of its loop. A loop shaped
    -- `while true do ...; Wait(t) end` never returns on its own, so `Wait` is
    -- where the iteration is counted and where a private sentinel unwinds it.
    -- The sentinel is raised and caught INSIDE this function, so it never
    -- reaches the suite's error handling and never reads as a failure.
    env.TICK_LIMIT = {}
    function env.tick(passes)
        passes = passes or 1
        local fn = env.threads[#env.threads]
        if not fn then
            return
        end
        local budget = passes
        local realWait = Wait
        Wait = function(ms)
            budget = budget - 1
            if budget <= 0 then
                error(env.TICK_LIMIT, 0)
            end
            realWait(ms)
        end
        local ok, err = pcall(fn)
        Wait = realWait
        if not ok and err ~= env.TICK_LIMIT then
            error(err, 0)
        end
    end
    function GetGameTimer() return env.clock end
    function GetCurrentResourceName() return 'cis_libs' end
    function GetInvokingResource() return env.invoking end
    function GetGameBuildNumber() return 2372 end
    -- Sync's owner-side apply asks who owns a networked entity; this client by default.
    function NetworkGetEntityOwner() return 1 end
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
    function vec4(x, y, z, w) return { x = x, y = y, z = z, w = w } end
    function PlayerId() return 0 end
    -- Event handlers are recorded rather than dropped: and assert on
    -- what a stop sweep is bound to, so the harness has to be able to fire one.
    env.handlers = {}
    function AddEventHandler(name, fn)
        env.handlers[name] = env.handlers[name] or {}
        env.handlers[name][#env.handlers[name] + 1] = fn
    end
    -- Commands are recorded for the same reason events are: client/cache.lua
    -- registers one, and a suite that cannot load a file because of an
    -- unstubbed registration is a suite that silently tests nothing.
    env.commands = {}
    function RegisterCommand(name, fn, restricted)
        env.commands[name] = { fn = fn, restricted = restricted }
    end

    -- `by` is the resource whose script triggered the event, which is what
    -- GetInvokingResource answers inside the handler. The engine's own events --
    -- a real onResourceStop among them -- have no script below the handler, so
    -- env.fire delivers with nil; env.fireFrom is a TriggerEvent from a script.
    function env.fireFrom(by, name, ...)
        -- _ENV, not _G: under test/run.lua a suite's globals live in its own
        -- environment, and _G is the interpreter's.
        local saved = rawget(_ENV, 'GetInvokingResource')
        GetInvokingResource = function() return by end
        local ok, err = pcall(function(...)
            for _, fn in ipairs(env.handlers[name] or {}) do fn(...) end
        end, ...)
        rawset(_ENV, 'GetInvokingResource', saved)
        if not ok then error(err, 0) end
    end
    function env.fire(name, ...)
        return env.fireFrom(nil, name, ...)
    end
    -- `cis_libs:cb` is registered through RegisterNetEvent, so it is delivered
    -- through env.net rather than env.fire.
    -- Net events are RECORDED, so a test can deliver the same event the server
    -- would. The server's `source` global is set around the dispatch rather than
    -- passed as an argument, exactly as FiveM does.
    env.netEvents = {}
    function RegisterNetEvent(name, fn)
        env.netEvents[name] = env.netEvents[name] or {}
        env.netEvents[name][#env.netEvents[name] + 1] = fn
    end
    function env.net(name, src, ...)
        local saved = rawget(_ENV, 'source')
        source = src
        for _, fn in ipairs(env.netEvents[name] or {}) do fn(...) end
        rawset(_ENV, 'source', saved)
    end

    -- A minimal promise and Citizen.Await, because the callback module parks a
    -- coroutine on one. Resolved synchronously, so a test that awaits settles on
    -- its first turn rather than hanging on a scheduler this harness does not
    -- have.
    --
    -- Assigned as a WHOLE table rather than by declaring `function promise.new()`
    -- into an existing one: the global is nil at this point, so the dotted form
    -- would be an index of nil before the assignment ever ran.
    -- A Logging table with the shape the files use. Records rather than prints,
    -- so an error a file raises internally is visible to the test that caused it
    -- instead of disappearing into the suite's own output.
    env.logged = {}
    Logging = {
        Levels = { DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4 },
        Debug = function(m) env.logged[#env.logged + 1] = { 'debug', m } end,
        Info = function(m) env.logged[#env.logged + 1] = { 'info', m } end,
        Warn = function(m) env.logged[#env.logged + 1] = { 'warn', m } end,
        Error = function(m) env.logged[#env.logged + 1] = { 'error', m } end,
        AutoLogError = function(e, ctx)
            env.logged[#env.logged + 1] = { 'autolog', e, ctx }
        end,
    }

    -- CisLog is the client-side counterpart of Logging and is what the files
    -- under test actually call for user-facing messages.
    function CisLog(level, message)
        env.logged[#env.logged + 1] = { level, message }
    end

    -- THESE FAKES NOW MATCH THE REAL NATIVE, AND THAT IS THE POINT.
    --
    -- `Citizen.Await` returned `p.done, p.value` -- TWO values. The real one
    -- returns exactly ONE, verified against citizenfx/fivem
    -- `data/shared/citizen/scripting/lua/scheduler.lua`:
    --
    --     function Citizen.Await(promise)
    --         ...
    --         if promise.state == 2 or promise.state == 4 then
    --             error(promise.value, 2)   -- a rejection THROWS
    --         end
    --         return promise.value           -- a fulfilment returns ONE value
    --     end
    --
    -- A fake that returns two values is a fake that AGREES WITH THE BUG: it
    -- made `local settled, value = Citizen.Await(p)` look correct, and that line
    -- is wrong on a live server in a way nothing here could see. Each property
    -- below is verified against that source rather than assumed.
    env.promises = {}
    promise = {
        new = function()
            local p = { done = false, value = nil, rejected = false }
            p.resolve = function(self, v) self.done, self.value = true, v end
            -- Recorded separately, because the real `Await` branches on a
            -- rejection and is otherwise indistinguishable from a fulfilment.
            p.reject = function(self, v)
                self.done, self.value, self.rejected = true, v, true
            end
            env.promises[#env.promises + 1] = p
            return p
        end,
    }
    Citizen = {
        Await = function(p)
            if not p.done then
                -- THE CALLER IS PARKED HERE. The real scheduler yields and
                -- resumes when the promise settles, so a reply arrives DURING
                -- the await. `awaitHook` is how a test injects that arrival --
                -- without it, the only way to settle a promise is after Await
                -- has returned, which is a different order than production and
                -- would make an await test meaningless.
                if type(env.awaitHook) == 'function' then
                    env.awaitHook(p)
                end
            end
            if not p.done then
                -- Nothing drove this thread. The real scheduler would park it
                -- forever; settling with nil keeps the suite honest -- the
                -- caller sees no answer, which is what would really happen --
                -- without hanging the run.
                p.done, p.value = true, nil
            end
            -- `error(value, 2)`: the rejection reason becomes the error object,
            -- so `pcall` yields exactly what was passed to `reject`.
            if p.rejected then
                error(p.value, 2)
            end
            return p.value
        end,
    }

    -- Outbound net events are RECORDED. `TriggerServerEvent` returns nothing, so
    -- "was the server told" is unanswerable from a caller's point of view --
    -- which is the whole of an event that fires 60 times a second is
    -- invisible to every test that does not keep a count.
    env.serverEvents = {}
    function TriggerServerEvent(name, ...)
        env.serverEvents[#env.serverEvents + 1] = { name = name, args = table.pack(...) }
    end
    function TriggerEvent(name, ...)
        env.serverEvents[#env.serverEvents + 1] = { name = name, args = table.pack(...), clientLocal = true }
    end
    function env.serverEventsOf(name)
        local out = {}
        for i = 1, #env.serverEvents do
            if env.serverEvents[i].name == name and not env.serverEvents[i].clientLocal then
                out[#out + 1] = env.serverEvents[i]
            end
        end
        return out
    end
    function env.localEventsOf(name)
        local out = {}
        for i = 1, #env.serverEvents do
            if env.serverEvents[i].name == name and env.serverEvents[i].clientLocal then
                out[#out + 1] = env.serverEvents[i]
            end
        end
        return out
    end

    -- THERE IS NO onClientResourceStop GLOBAL, and that is the point of this
    -- comment.
    --
    -- This harness used to define one, so four client files could call it and
    -- pass 95 assertions under a real Lua 5.4 while raising on every live
    -- client. A stub for a global that does not exist is not a convenience: it
    -- is a lie that makes a broken file look correct, and it did exactly that.
    -- `client/zones.lua` and `client/target.lua` never finished loading on the
    -- server, so all nine of their exports were missing, and the zone suite
    -- spent a session reporting a behavioural P0 against code that never ran.
    --
    -- Deleting the stub is the regression test. A file that reaches for it again
    -- now fails here, in a second, instead of on a live server.

    -- The exports table the files under test install onto, modelled on the real
    -- one: callable as `exports('Name', fn)` and indexable as
    -- `exports['resource']`. `env.EXPORTS` is cis_libs's OWN table -- which is
    -- what a file loaded inside cis_libs registers into -- and `env.foreign`
    -- is where a test puts the fake resources a 'resource:export' reference
    -- resolves against.
    local EXPORTS = {}
    setmetatable(EXPORTS, {
        __call = function(_, name, fn)
            EXPORTS[name] = fn
        end,
    })
    env.EXPORTS = EXPORTS
    exports = EXPORTS
    function env.foreign(resource)
        EXPORTS[resource] = EXPORTS[resource] or {}
        return EXPORTS[resource]
    end

    function env.reset()
        for i = #env.saved, 1, -1 do
            local entry = env.saved[i]
            if entry.name == '__metatable' then
                setmetatable(_G, entry.value)
            else
                _ENV[entry.name] = entry.value
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
            'Create', 'Delete', 'Freeze', 'Request', 'Clear', 'Toggle', 'Roll',
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

-- Loads a client file, translating FiveM's BACKTICK HASH LITERALS first.
--
-- `` `WEAPON_UNARMED` `` is a FiveM compiler extension: it becomes the hash of
-- the named constant at build time. Plain Lua -- including fengari, which is what
-- this suite runs on -- cannot parse it, and tools/luacheck.js skips
-- client/cache.lua and client/weapon.lua for the same reason.
--
-- Rewriting it rather than skipping the file is the whole point. Those two hold
-- the aiming bug and the near-watcher surface, and "cannot be loaded, so
-- cannot be tested" is how the aiming defect survived an audit in the first
-- place. The VALUE does not matter to any assertion here -- what matters is that
-- one name always yields one number, so the cache's equality comparisons behave
-- the way they do in game.
local BACKTICK_PATTERN = '`([^`]*)`'

local function readSource(rel)
    -- fengari's io library in the node build has no `open`, so the file arrives
    -- as text injected by test/run.js. Falling back to loadfile keeps the suite
    -- runnable under a real `lua test/client.lua`.
    if CIS_TEST_FILES and CIS_TEST_FILES[rel] then
        return CIS_TEST_FILES[rel]
    end
    local f = io.open('./' .. rel, 'r')
    if not f then
        error('client suite: cannot read ' .. rel, 0)
    end
    local body = f:read('*a')
    f:close()
    return body
end

-- `load` rather than `loadstring`: this suite runs on fengari, which is Lua
-- 5.3, where `loadstring` was removed. `load` takes the same arguments and is
-- the form the file is actually compiled by in game.
-- A client file that wraps an ENGINE (client/core/<same name>.lua) needs the
-- engine loaded first, exactly as the manifest orders them: the engines are
-- client_scripts listed before the wrappers. Loaded here rather than by every
-- test, so a test cannot exercise a wrapper against an engine it forgot.
local function hasSource(rel)
    if CIS_TEST_FILES and CIS_TEST_FILES[rel] then
        return true
    end
    local f = io.open and io.open('./' .. rel, 'r')
    if f then
        f:close()
        return true
    end
    return false
end

local function loadModule(rel)
    local core = rel:match('^client/([%w_]+)%.lua$')
    if core and hasSource('client/core/' .. core .. '.lua') then
        local src = readSource('client/core/' .. core .. '.lua'):gsub(BACKTICK_PATTERN, '0x11111111')
        local engine, engineErr = load(src, '@client/core/' .. core .. '.lua')
        if not engine then
            error(('client/core/%s.lua: %s'):format(core, tostring(engineErr)), 0)
        end
        engine()
    end
    local body = readSource(rel):gsub(BACKTICK_PATTERN, '0x11111111')
    local chunk, err = load(body, '@' .. rel)
    if not chunk then
        error(('%s: %s'):format(rel, tostring(err)), 0)
    end
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
    --
    -- C5 · AS AN INTEGER, NOT A BOOLEAN. The native declares its third
    -- parameter `BOOL disable`, but its own declaration carries the note
    -- "Confirmed p2 does not work as a bool. Changed to int. [0=on, 1=off]"
    -- (citizenfx/natives, SET_VEHICLE_EXTRA.md). Passing Lua `true` is relying
    -- on the marshaller doing the right thing with a value the native's own
    -- documentation says it does not accept, so the flag goes across as 1/0.
    --
    -- This assertion used to pin `== false`, which is what the bug looked like
    -- from the outside: both readings are "the value the setter chose", so a
    -- test written against the implementation rather than the native cannot
    -- tell the difference between correct and nearly-correct.
    check(env.natives[1] and env.natives[1].disable == 0,
        ('an extra stored as 0 (it was ON) is passed as the integer 0 (got %s)')
            :format(tostring(env.natives[1] and env.natives[1].disable)))

    env.natives = {}
    SetVehicleProperties(7, { extras = { [1] = 1 } })
    check(env.natives[1] and env.natives[1].disable == 1,
        ('an extra stored as 1 (it was OFF) is passed as the integer 1 (got %s)')
            :format(tostring(env.natives[1] and env.natives[1].disable)))

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
    check(env.natives[1] and env.natives[1].disable == 1,
        ('getter output fed straight back to the setter disables the same extra (got %s)')
            :format(tostring(env.natives[1] and env.natives[1].disable)))

    env.reset()
end

-- ===================================================== 7.10 vehicle + cache
do
    local env = newEnv()
    env.locks = {}
    function DoesEntityExist() return true end
    function DoesExtraExist() return false end
    function IsVehicleExtraTurnedOn() return false end
    function GetVehicleDoorLockStatus() return 2 end
    function GetVehicleLivery() return 4 end
    function GetVehicleLiveryCount() return 5 end
    function GetVehicleMod(_, id) return id == 48 and 7 or -1 end
    function SetVehicleDoorsLocked(vehicle, state)
        env.locks[#env.locks + 1] = { vehicle = vehicle, state = state }
    end
    function SetVehicleModKit() end
    function GetVehicleColours() return 1, 2 end
    function GetVehicleExtraColours() return 0, 0 end
    function IsVehicleWindowIntact() return true end
    function IsVehicleDoorDamaged() return false end
    function IsVehicleTyreBurst() return false end
    function IsVehicleNeonLightEnabled() return false end
    function GetGameBuildNumber() return 1604 end
    loadModule('client/vehicle.lua')

    local props = GetVehicleProperties(9)
    check(props and props.lockState == 2,
        ('7.10: getter carries lockState (got %s)'):format(tostring(props and props.lockState)))
    check(props and props.livery == 4,
        ('7.10: getter carries livery from GetVehicleLivery, not only mod 48 (got %s)')
            :format(tostring(props and props.livery)))

    -- A ROLLED-DOWN WINDOW IS NOT A BROKEN ONE. Window 1 is smashed, window 2 is
    -- only down; both read not-intact. Saving both made the setter remove
    -- window 2 on restore. The getter tells them apart by rolling up and asking
    -- again, and puts window 2 back down.
    local broken, down, rolled = { [1] = true }, { [2] = true }, {}
    env.save('IsVehicleWindowIntact')
    env.save('RollUpWindow')
    env.save('RollDownWindow')
    IsVehicleWindowIntact = function(_, i) return not broken[i] and not down[i] end
    RollUpWindow = function(_, i) down[i] = nil; rolled[#rolled + 1] = 'up' .. i end
    RollDownWindow = function(_, i) down[i] = true; rolled[#rolled + 1] = 'down' .. i end
    local winProps = GetVehicleProperties(9)
    check(winProps and #winProps.windows == 1 and winProps.windows[1] == 1,
        ('7.10: only the smashed window is saved, not the rolled-down one (got %s)')
            :format(winProps and table.concat(winProps.windows, ',') or 'nil'))
    check(down[2] == true and not down[1],
        '7.10: and the getter leaves the rolled-down window down')
    IsVehicleWindowIntact = function() return true end

    SetVehicleProperties(9, { lockState = 0 })
    check(#env.locks == 1 and env.locks[1].state == 0,
        '7.10: lockState 0 is applied -- it is unlocked, not "absent"')
    env.reset()
end

-- ================================================= 2. entity sync, client half
--
-- The client-side defects are all about entities that outlive their record.
-- `TriggerClientEvent` returns nothing and `CreateObject` returns a handle, so
-- the only way to see either is to record what the natives were asked.
--
-- The harness here hands out entity handles from a counter and records every
-- CreateObject / DeleteEntity, which is what makes "an orphan was left behind"
-- an assertion rather than an opinion.
-- A payload exactly as the server sends one, and the name a remove for it
-- carries. Stated ONCE here because the identity of a record on this side is
-- the namespaced `key`, and four literals that each forgot it would read as
-- four passing tests while asserting nothing.
local function wirePayload(id, fields)
    fields = fields or {}
    fields.id = id
    fields.key = 'cis_anyProduct\0' .. id
    return fields
end

local function wireKeyOf(id)
    return 'cis_anyProduct\0' .. id
end

local function syncEnv(opts)
    opts = opts or {}
    local env = newEnv(opts)
    env.nextEntity = 100
    env.modelReady = true
    env.netEvents = env.netEvents or {}
    function RegisterNetEvent(name, fn)
        env.netEvents[name] = fn
    end
    function CreateObject(hash, x, y, z, networked)
        env.nextEntity = env.nextEntity + 1
        env.natives[#env.natives + 1] = { name = 'CreateObject', networked = networked }
        if not env.modelReady then return 0 end
        env.alive[env.nextEntity] = true
        return env.nextEntity
    end
    function CreateVehicle(hash, x, y, z, heading, networked)
        env.nextEntity = env.nextEntity + 1
        env.natives[#env.natives + 1] = { name = 'CreateVehicle', networked = networked }
        env.alive[env.nextEntity] = true
        return env.nextEntity
    end
    function CreatePed(hash, coords, heading)
        env.nextEntity = env.nextEntity + 1
        env.natives[#env.natives + 1] = { name = 'CreatePed' }
        env.alive[env.nextEntity] = true
        return env.nextEntity
    end
    function DeleteEntity(handle)
        env.alive[handle] = nil
        env.natives[#env.natives + 1] = { name = 'DeleteEntity', handle = handle }
    end
    -- A created handle stays alive until it is deleted, because despawn tests
    -- `DoesEntityExist` before calling DeleteEntity. The default 0 would make
    -- every despawn silently do nothing, and the test would pass against a
    -- delete that never happened.
    env.alive = env.alive or {}
    function DoesEntityExist(handle)
        return env.alive[handle] == true
    end
    -- Recorded, not swallowed. "Did the entity actually MOVE, and to where" is
    -- the whole of a move-instead-of-respawn, and a stub that discards the call
    -- makes that unanswerable -- which is how a case reported "the newest state
    -- was dropped" against a library that had moved it correctly.
    function SetEntityCoords(entity, x, y, z)
        env.natives[#env.natives + 1] =
            { name = 'SetEntityCoords', entity = entity, x = x, y = y, z = z }
    end
    function SetEntityHeading(entity, heading)
        env.natives[#env.natives + 1] =
            { name = 'SetEntityHeading', entity = entity, heading = heading }
    end
    function FreezeEntityPosition() end
    function SetModelAsNoLongerNeeded() end
    -- `HasModelLoaded` drives the yield. When it is false the spawn blocks in
    -- RequestModelTimeout, which is where the remove has to arrive.
    function HasModelLoaded() return env.modelReady end
    function IsModelInCdimage() return true end
    function RequestModel() end
    -- client/streaming.lua is NOT loaded here -- it installs a real Wait loop
    -- that this harness's `Wait` cannot drive -- so the model wait is stubbed to
    -- yield directly. That is the whole point of the test: the bug lives in
    -- what happens ACROSS a yield, so the yield is what the stub has to
    -- reproduce, and reproducing it faithfully is the whole job.
    function RequestModelTimeout()
        env.modelRequests = (env.modelRequests or 0) + 1
        env.natives[#env.natives + 1] = { name = 'RequestModelTimeout' }
        -- A model that does not arrive. `env.modelFails` is how many attempts
        -- time out before one succeeds, which is the shape a rare asset takes:
        -- the first request loses and a retry finds it.
        if env.modelFails and env.modelRequests <= env.modelFails then
            return false
        end
        while not env.modelReady do
            coroutine.yield()
        end
        return true
    end
    -- Recorded rather than swallowed. "Was the model released?" is one of the
    -- questions the 4.6 cases exist to answer, and a stub that discards the call
    -- cannot answer it.
    function SetModelAsNoLongerNeeded(hash)
        env.natives[#env.natives + 1] = { name = 'SetModelAsNoLongerNeeded', hash = hash }
    end
    -- Run the threads a file under test spawns, once each. A retry is a real
    -- thread in production, so it has to be driven the same way here or "it
    -- retries" is an untested claim.
    --
    -- `env.threads or {}` because this harness creates the table LAZILY, inside
    -- CreateThread: a file under test that spawns nothing leaves it nil, and a
    -- driver that assumed otherwise crashed on the one case that had nothing to
    -- run. A harness bug that only shows up when there is nothing to do is
    -- still a harness bug.
    env.ranThreads = {}
    env.runThreads = function(limit)
        local n = 0
        for _, fn in ipairs(env.threads or {}) do
            if fn and not env.ranThreads[fn] and (limit == nil or n < limit) then
                env.ranThreads[fn] = true
                n = n + 1
                local co = coroutine.create(fn)
                local ok, err = coroutine.resume(co)
                if not ok then error(err, 0) end
            end
        end
        return n
    end
    -- The exports table the file under test installs onto, modelled on the real
    -- one: callable as `exports('Name', fn)`, indexable as `exports['resource']`.
    -- Built FRESH per environment rather than left to whatever a previous one
    -- happened to leave behind -- a test that inherits its subject is not
    -- testing that subject.
    local SYNC_EXPORTS = {}
    setmetatable(SYNC_EXPORTS, {
        __call = function(_, name, fn) SYNC_EXPORTS[name] = fn end,
    })
    env.EXPORTS = SYNC_EXPORTS
    exports = SYNC_EXPORTS
    -- The networked half listens on the `cis_sync` state bag through the
    -- library's own watcher; the stub hands the test that handler.
    env.save('CisStatebagOnEntity')
    env.save('TriggerServerEvent')
    function CisStatebagOnEntity(key, fn)
        env.bagWatch = { key = key, fn = fn }
        return 1
    end
    env.serverEvents = {}
    function TriggerServerEvent(name, ...)
        env.serverEvents[#env.serverEvents + 1] = { name = name, args = table.pack(...) }
    end
    loadModule('client/sync.lua')
    -- THE WIRE IS A NUMBERED BATCH. `upsert` and `remove` are the one-entry
    -- batches most tests want; `batch` sends exactly what the server would.
    -- Delivered the way the network delivers it: `source` is the server's net id
    -- (65535) for the duration of the call. `env.forge` is the same handler
    -- reached by a local TriggerEvent, where the runtime sets `source` to ''.
    local handler = env.netEvents['cis_libs:client:syncBatch']
    local function deliver(src, ...)
        local saved = rawget(_ENV, 'source')
        source = src
        local out = table.pack(handler(...))
        rawset(_ENV, 'source', saved)
        return table.unpack(out, 1, out.n)
    end
    env.batch = function(...) return deliver(65535, ...) end
    env.forge = function(...) return deliver('', ...) end
    env.batchN = 0
    function env.upsert(record)
        env.batchN = env.batchN + 1
        return env.batch(env.batchN, { record }, {})
    end
    function env.remove(key)
        env.batchN = env.batchN + 1
        return env.batch(env.batchN, {}, { key })
    end
    return env
end

do
    -- a remove arriving DURING the model wait.
    --
    -- The server streams the player out of range and sends a remove while the
    -- client is still inside RequestModelTimeout. Before the fix the remove
    -- found `spawning[id]` true, did nothing, and the spawn then completed --
    -- creating an entity for a record the server had already forgotten. Nothing
    -- would ever remove it: the client-local entity has no owner and the server
    -- no longer holds the id.
    local env = syncEnv({})
    env.modelReady = false
    check(type(env.upsert) == 'function', 'the client registers the upsert handler')
    check(type(env.remove) == 'function', 'the client registers the remove handler')

    local record = wirePayload('prop_1', {
        kind = 'prop', model = 'prop_barrel_01',
        coords = { x = 1.0, y = 2.0, z = 3.0 }, networked = false,
    })

    -- The interleaving IS the bug, so the test drives it directly rather than
    -- hoping a loop produces the order: start the upsert, stop it at the model
    -- yield, deliver the remove while it waits, then let the model arrive.
    --
    -- A record whose model is not loaded is driven on a thread of its own, so one
    -- slow model does not hold up the rest of its batch. That thread is the one
    -- that yields, and the one this test steps.
    env.upsert(record)
    check(#(env.threads or {}) == 1,
        'a record whose model is not loaded gets ONE drive thread of its own')
    local co = coroutine.create(env.threads[#env.threads])
    local ok, err = coroutine.resume(co)
    check(ok, 'the upsert yields on the model: ' .. tostring(err))
    check(coroutine.status(co) == 'suspended', 'the upsert is suspended waiting for the model')

    -- The server removes the record while the client waits.
    env.remove(wireKeyOf('prop_1'))
    check(coroutine.status(co) == 'suspended', 'the remove does not itself yield')

    -- The model arrives and the spawn finishes.
    env.modelReady = true
    local ok2, err2 = coroutine.resume(co)
    check(ok2, 'the spawn resumes cleanly: ' .. tostring(err2))

    local created, deleted = 0, nil
    for _, n in ipairs(env.natives) do
        if n.name == 'CreateObject' then created = created + 1 end
        if n.name == 'DeleteEntity' then deleted = n.handle end
    end
    check(created == 1, 'the spawn did create the entity before checking')
    check(deleted ~= nil,
        ('a remove during a yielding model load deletes the entity it '
            .. 'created (created=%d deleted=%s handle=%s)')
            :format(created, tostring(deleted ~= nil), tostring(deleted)))
    env.reset()
end

-- The ordinary case: an upsert with no remove leaves the entity alone.
do
    local env = syncEnv({})
    env.upsert(wirePayload('prop_2', {
        kind = 'prop', model = 'prop_barrel_01',
        coords = { x = 1.0, y = 2.0, z = 3.0 }, networked = false,
    }))
    local deleted = 0
    for _, n in ipairs(env.natives) do
        if n.name == 'DeleteEntity' then deleted = deleted + 1 end
    end
    check(deleted == 0, 'an ordinary upsert deletes nothing')
    env.reset()
end

-- A NETWORKED record is one entity the server already spawned. The client
-- resolves the netId and tracks that entity; it must not create its own, which
-- is the duplicate `networked = true` used to produce for every in-range client.
do
    local env = syncEnv({})
    env.netEntity = 555
    env.upsert(wirePayload('prop_3', {
        kind = 'prop', model = 'prop_barrel_01',
        coords = { x = 0.0, y = 0.0, z = 0.0 },
        networked = true, spawnHere = false, netId = 1234,
    }))
    local created = 0
    for _, n in ipairs(env.natives) do
        if n.name == 'CreateObject' or n.name == 'CreateVehicle' then created = created + 1 end
    end
    check(created == 0,
        'a networked record is NOT spawned again on the client')
    check(env.EXPORTS and true or true, 'the export table is present')
    env.reset()
end

-- THE CLIENT NEVER DELETES A NETWORKED ENTITY.
--
-- It resolved a handle for an entity the SERVER owns, and a remove event says
-- "stop tracking this", not "you may delete this". DeleteEntity from a client on
-- an entity it does not own is a request: it can be refused, and when it is not
-- honoured the entity vanishes from a world this client was never entitled to
-- change, while the server still believes it is there and still streams it.
-- Everything after that is a desync.
do
    local env = syncEnv({})
    env.netEntity = 555
    -- The resolved handle has to be ALIVE, or despawn's own DoesEntityExist
    -- guard skips the delete and the test passes against code that would have
    -- deleted it. A green result here has to mean the guard in despawn stopped
    -- it, not that nothing was reachable.
    env.alive[555] = true
    -- It is found through its `cis_sync` state bag: the watcher hands the entity.
    check(env.bagWatch ~= nil and env.bagWatch.key == 'cis_sync',
        '4.5: the client watches the cis_sync state bag for networked records')
    env.bagWatch.fn(555, { key = wireKeyOf('prop_net'), id = 'prop_net', kind = 'prop', rev = 1 },
        true, false)
    local tracked = env.EXPORTS.GetSyncedEntities()
    check(tracked[wireKeyOf('prop_net')] == 555,
        '4.5: the networked handle is tracked, so this case is not vacuous')

    local before = #env.natives
    env.remove(wireKeyOf('prop_net'))
    local deletions = 0
    for i = before + 1, #env.natives do
        if env.natives[i].name == 'DeleteEntity' then deletions = deletions + 1 end
    end
    check(deletions == 0,
        '4.5: despawning a networked entity does not call DeleteEntity')
    local after = env.EXPORTS.GetSyncedEntities()
    check(after[wireKeyOf('prop_net')] == nil,
        '4.5: the client does stop tracking it, which is all it does')
    env.reset()
end

-- The other half of the same rule, and the one that must still work: a
-- client-LOCAL entity is this client's own, and the client deletes it. Guarding
-- the networked case by never deleting anything would look correct on the
-- networked test and strand a client-local entity in the world forever.
do
    local env = syncEnv({})
    env.upsert(wirePayload('prop_local', {
        kind = 'prop', model = 'prop_barrel_01',
        coords = { x = 0.0, y = 0.0, z = 0.0 }, networked = false,
    }))
    local before = #env.natives
    env.remove(wireKeyOf('prop_local'))
    local deletions = 0
    for i = before + 1, #env.natives do
        if env.natives[i].name == 'DeleteEntity' then deletions = deletions + 1 end
    end
    check(deletions == 1,
        '4.5: a client-local entity is still deleted by the client that made it')
    env.reset()
end

-- A client-local entity is created LOCAL, which is what makes two clients'
-- copies independent rather than two networked duplicates.
do
    local env = syncEnv({})
    env.upsert(wirePayload('prop_4', {
        kind = 'prop', model = 'prop_barrel_01',
        coords = { x = 0.0, y = 0.0, z = 0.0 }, networked = false,
    }))
    local networked
    for _, n in ipairs(env.natives) do
        if n.name == 'CreateObject' then networked = n.networked end
    end
    check(networked == false,
        'a client-local record creates a NON-networked entity on the client')
    env.reset()
end

-- 4.3 · THE KEY IS THE IDENTITY HERE, and these are the two ways that can fail.
do
    -- (1) A record with NO key is refused, not taken on its caller's word.
    --
    -- This is the boundary that decides whether the namespacing reaches the
    -- client at all. Keying on `id` instead would put two owners' entities in
    -- one slot on any server running a cis_libs without the field -- the exact
    -- silent overwrite the key exists to stop, reappearing one hop away.
    local env = syncEnv({})
    env.upsert({
        id = 'door1', kind = 'prop', model = 'prop_barrel_01',
        coords = { x = 0.0, y = 0.0, z = 0.0 }, networked = false,
    })
    local created = 0
    for _, n in ipairs(env.natives) do
        if n.name == 'CreateObject' then created = created + 1 end
    end
    check(created == 0, '4.3: a record with no key spawns nothing')
    env.reset()

    -- (2) Two owners, SAME id, two entities.
    --
    -- The observable is two CreateObject calls, not one: with one, the second
    -- payload lands in the first's slot and the entity the player is looking at
    -- is silently the wrong one.
    local env2 = syncEnv({})
    env2.upsert({
        id = 'door1', key = 'res_a\0door1', kind = 'prop', model = 'prop_barrel_01',
        coords = { x = 0.0, y = 0.0, z = 0.0 }, networked = false,
    })
    env2.upsert({
        id = 'door1', key = 'res_b\0door1', kind = 'prop', model = 'prop_barrel_01',
        coords = { x = 5.0, y = 0.0, z = 0.0 }, networked = false,
    })
    local two = 0
    for _, n in ipairs(env2.natives) do
        if n.name == 'CreateObject' then two = two + 1 end
    end
    check(two == 2,
        ('4.3: two owners using the same id produce two entities (%d)'):format(two))

    -- And a remove for one leaves the other standing -- which is the whole
    -- point, and would be one despawn if the two shared a slot.
    env2.remove('res_a\0door1')
    local deleted = 0
    for _, n in ipairs(env2.natives) do
        if n.name == 'DeleteEntity' then deleted = deleted + 1 end
    end
    check(deleted == 1,
        ('4.3: removing one owner\'s record leaves the other\'s alone (%d deleted)')
            :format(deleted))
    env2.reset()
end

-- ============================ 3. client callbacks by reference ()
--
-- `client/callback.lua` had no remote dispatch at all. `RegisterCallback(name,
-- 'res:export')` stored the STRING, and the dispatch pcall failed on every
-- call -- so the documented form silently did not work, and failed as a raised
-- error answered to the server as `false, 'error'`. api.lua has always declared
-- RegisterCallback's realm as `both`.
--
-- The unbound-method trap is asserted here too, because it is the reason a
-- correct-looking fix still fails: `exports[res][name]` swallows the first real
-- argument as `self`.
do
    local env = newEnv({})
    loadModule('client/callback.lua')

    local seenSelf, seenArgs
    env.foreign('my_resource').MyHandler = function(self, ...)
        seenSelf, seenArgs = self, table.pack(...)
        return 'answered', 7
    end

    check(env.EXPORTS.RegisterCallback('x', 'my_resource:MyHandler') == true,
        'a client callback registers by "resource:export" reference')
    check(env.EXPORTS.RegisterCallback('bad', 'not-a-reference') == false,
        'a malformed reference is refused rather than stored as a string')

    -- The server asks for it, and the client's own handler answers.
    env.net('cis_libs:cb', 1, 'x', 1, 'a', 'b')
    check(seenSelf == env.EXPORTS.my_resource,
        'the handler is called with the exports table as self, not shifted')
    check(seenArgs and seenArgs.n == 2 and seenArgs[1] == 'a' and seenArgs[2] == 'b',
        ('the caller\'s arguments arrive unmoved (n=%s)')
            :format(tostring(seenArgs and seenArgs.n)))
    env.reset()
end

-- A MISSING EXPORT IS ANSWERED. FiveM raises on the lookup of an export a
-- resource does not have, and raised outside pcall no reply was sent: the
-- server waited out its whole timeout for an answer that was never coming.
do
    local env = newEnv({})
    loadModule('client/callback.lua')
    local mt = getmetatable(env.EXPORTS)
    mt.__index = function(_, res)
        if res == 'ghost' then
            error('No such export Nope in resource ghost', 2)
        end
    end
    check(env.EXPORTS.RegisterCallback('ghostly', 'ghost:Nope') == true,
        'a reference to a resource that is not there yet registers')
    env.serverEvents = {}
    local ran = pcall(env.net, 'cis_libs:cb', 1, 'ghostly', 41)
    local r = env.serverEvents[#env.serverEvents]
    check(ran and r and r.name == 'cis_libs:cb:serverRes' and r.args[1] == 41
        and r.args[2] == false and r.args[3] == 'error',
        ('a missing export is answered error at once, not left to time out (ran=%s reply=%s)')
            :format(tostring(ran), tostring(r and r.args[3])))
    mt.__index = nil
    env.reset()
end

-- A stopped consumer's client callback is released (), so the next request
-- answers 'unknown' instead of raising against a dead export.
do
    local env = newEnv({})
    loadModule('client/callback.lua')

    env.invoking = 'res_a'
    env.EXPORTS.RegisterCallback('y', function() return 1 end)
    env.invoking = 'res_b'
    env.EXPORTS.RegisterCallback('z', function() return 2 end)

    -- THE WIRE SHAPE OF A REPLY IS (key, ok, ...). Slot 1 is the key, slot 2 is
    -- the flag, slot 3 is the refusal reason. Reading one slot off would pass
    -- against the wrong field -- `args[3] == 1` is the HANDLER's first result,
    -- not the ok flag, and an assertion written that way looks right and proves
    -- nothing.
    local function lastReply()
        local r = env.serverEvents[#env.serverEvents]
        return r and r.name == 'cis_libs:cb:serverRes' and r or nil
    end

    env.serverEvents = {}
    env.net('cis_libs:cb', 1, 'y', 1)
    local before = lastReply()
    check(before ~= nil, 'the callback answers before the stop')
    check(before and before.args[2] == true,
        'and answers success, not a refusal: ' .. tostring(before and before.args[2]))
    check(before and before.args[3] == 1,
        'with the handler result behind the flag')

    env.fire('onResourceStop', 'res_a')

    env.serverEvents = {}
    env.net('cis_libs:cb', 1, 'y', 2)
    local after = lastReply()
    check(after and after.args[2] == false,
        'after res_a stops, its client callback refuses')
    check(after and after.args[3] == 'unknown',
        ('and the refusal is "unknown", not an error: %s')
            :format(tostring(after and after.args[3])))

    env.serverEvents = {}
    env.net('cis_libs:cb', 1, 'z', 3)
    local z = lastReply()
    check(z and z.args[2] == true,
        "res_b's client callback SURVIVES another resource's stop")

    -- A NAME ANOTHER RESOURCE HOLDS IS NOT TAKEN OVER. res_b holds 'z'; res_c
    -- registering 'z' used to replace res_b's handler and answer the server in
    -- its place, by function or by "resource:export" alike.
    env.invoking = 'res_c'
    local took, why = env.EXPORTS.RegisterCallback('z', function() return 'hijacked' end)
    check(took == false and tostring(why):find('res_b', 1, true) ~= nil,
        ('another resource cannot take over a client callback name (%s)'):format(tostring(why)))
    check(env.EXPORTS.RegisterCallback('z', 'res_c:Steal') == false,
        'nor by "resource:export" reference')
    env.serverEvents = {}
    env.net('cis_libs:cb', 1, 'z', 4)
    local still = lastReply()
    check(still and still.args[3] == 2, "and res_b's handler still answers")
    env.invoking = 'res_b'
    check(env.EXPORTS.RegisterCallback('z', function() return 3 end) == true,
        'the owner may replace its own')
    env.invoking = 'res_c'
    check(env.EXPORTS.RegisterCallback('y', function() return 4 end) == true,
        'and a name whose owner stopped is free again')
    env.reset()
end

-- A LOCAL FORGERY IS NOT THE SERVER. Both callback events are net events, so any
-- client resource can reach them with TriggerEvent, and the runtime sets `source`
-- to '' when it does. Unchecked, a forged `cis_libs:cb` ran a consumer's handler
-- with the forger's arguments, and a forged `cis_libs:cb:res` answered another
-- resource's in-flight call with the forger's data.
do
    local env = newEnv({})
    loadModule('client/callback.lua')

    local ran = 0
    env.EXPORTS.RegisterCallback('bank:pin', function() ran = ran + 1 end)
    env.serverEvents = {}
    env.net('cis_libs:cb', '', 'bank:pin', 1)
    check(ran == 0, 'a forged cis_libs:cb does not run the handler')
    check(#env.serverEvents == 0, 'and sends no reply to the server')
    env.net('cis_libs:cb', 65535, 'bank:pin', 2)
    check(ran == 1, 'the same request from the server does')

    local got
    env.serverEvents = {}
    env.EXPORTS.CallCallback('shop:price', function(ok, v) got = { ok, v } end)
    local key = env.serverEvents[1] and env.serverEvents[1].args[2]
    env.net('cis_libs:cb:res', '', key, true, 'forged')
    check(got == nil, 'a forged cis_libs:cb:res does not answer the caller')
    env.net('cis_libs:cb:res', 65535, key, true, 'real')
    check(got and got[1] == true and got[2] == 'real',
        ('the server reply still does (%s)'):format(tostring(got and got[2])))
    env.reset()
end

-- ============================ C1: the await path, against the REAL native
--
-- Every await path here read the result of `Citizen.Await` as TWO values:
--
--     local settled, value = Citizen.Await(p)
--
-- and the native returns ONE. So `settled` received the reply -- a table -- and
-- `value` received nil, and the branch meant to recognise a refusal compared a
-- TABLE against false. It could never be true. Two failures fell out of that one
-- line: every value in the pack was dropped, and every REFUSAL was reported to
-- the caller as a SUCCESS carrying nil.
--
-- `await` is the client's main way to ask the server something, so this was not
-- an edge case -- it was the whole await surface, on both AwaitCallback and
-- TryAwaitCallback. And the fake returned two values, so the suite was green.
do
    local env = newEnv({})
    loadModule('client/callback.lua')

    env.EXPORTS.RegisterCallback('ask', function()
        return { id = 7 }, 'second'
    end)
    env.EXPORTS.RegisterCallback('holed', function()
        return nil, 'not found'
    end)

    -- Answers the parked promise the way the server's reply handler does, with
    -- the reply arriving DURING the await -- which is the order production has.
    --
    -- NOTE THE LEADING 0. `env.net(name, src, ...)` sets the `source` global and
    -- forwards only the varargs, so the key has to be an explicit argument. Left
    -- out, the key would land in `src`, every reply would arrive for the wrong
    -- entry, and every assertion here would fail for a reason that has nothing
    -- to do with the code under test.
    local function replyWith(ok, ...)
        local packed = table.pack(...)
        env.awaitHook = function()
            local req = env.serverEvents[#env.serverEvents]
            env.net('cis_libs:cb:res', 0, req.args[2], ok, table.unpack(packed, 1, packed.n))
        end
    end

    -- A fulfilled promise carries the PACK, and the await must hand back every
    -- value in it.
    do
        env.serverEvents = {}
        replyWith(true, { id = 7 }, 'second')
        local ok, a, b = env.EXPORTS.TryAwaitCallback('ask')
        check(ok == true,
            ('C1: tryAwait reports success on a fulfilled promise (got %s)'):format(tostring(ok)))
        check(type(a) == 'table' and a.id == 7,
            ('C1: and returns the first value (got %s)'):format(tostring(a)))
        check(b == 'second',
            ('C1: and the SECOND value too, which Await used to drop (got %s)'):format(tostring(b)))
    end

    -- The nil-in-the-middle case, which is the one this platform hits most:
    -- "no such row" is normally reported as `nil, 'not found'`.
    do
        env.serverEvents = {}
        replyWith(true, nil, 'not found')
        local ok, a, b = env.EXPORTS.TryAwaitCallback('holed')
        check(ok == true, 'C1: a nil first value is a success, not an error')
        check(a == nil,
            ('C1: and the first value really is nil (got %s)'):format(tostring(a)))
        check(b == 'not found',
            ('C1: and the reason BEHIND the nil survives it (got %s)'):format(tostring(b)))
    end

    -- A REFUSAL. `Citizen.Await` raises on a rejected promise, so the await has
    -- to catch that and turn it into `false, reason`.
    do
        env.serverEvents = {}
        replyWith(false, 'rate')
        local ok, reason = env.EXPORTS.TryAwaitCallback('ask')
        check(ok == false,
            ('C1: a refusal is reported as false, not success-with-nil (got %s)')
                :format(tostring(ok)))
        check(tostring(reason):find('rate', 1, true) ~= nil,
            ('C1: and carries the reason the server sent (got %s)'):format(tostring(reason)))
    end

    -- An unknown name is refused by the server. That refusal has to come back as
    -- a refusal -- it used to be indistinguishable from a handler that answered
    -- nothing at all.
    do
        env.serverEvents = {}
        replyWith(false, 'unknown')
        local ok, reason = env.EXPORTS.TryAwaitCallback('no_such_callback')
        check(ok == false,
            ('C1: an unknown name is a refusal, not an empty success (got %s)')
                :format(tostring(ok)))
        check(tostring(reason):find('unknown', 1, true) ~= nil,
            ('C1: with "unknown" as the reason: %s'):format(tostring(reason)))
    end

    -- `AwaitCallback` is the raising twin: it turns that same refusal into an
    -- error that NAMES the callback. Against the old two-value read it did not
    -- raise at all, so a timeout reached the caller as a nil answer.
    do
        env.serverEvents = {}
        replyWith(false, 'timeout')
        local okCall, errCall = pcall(env.EXPORTS.AwaitCallback, 'ask')
        check(not okCall,
            'C1: AwaitCallback raises on a refusal rather than returning nil')
        check(tostring(errCall):find('ask', 1, true) ~= nil,
            ('C1: and the error names the callback: %s'):format(tostring(errCall)))
        check(tostring(errCall):find('timeout', 1, true) ~= nil,
            ("C1: carrying the server's reason: %s"):format(tostring(errCall)))
    end

    -- The server sends up to SIX values and the docs promise six. AwaitCallback
    -- read `local ok, a, b` and returned `a, b`, so the third onwards vanished.
    do
        env.serverEvents = {}
        replyWith(true, 'one', 'two', 'three', nil, 'five', 'six')
        local packed = table.pack(env.EXPORTS.AwaitCallback('ask'))
        check(packed.n == 6 and packed[1] == 'one' and packed[3] == 'three'
                and packed[4] == nil and packed[6] == 'six',
            ('C1: AwaitCallback returns all six values, a nil among them (n=%d, third=%s, sixth=%s)')
                :format(packed.n, tostring(packed[3]), tostring(packed[6])))
    end

    -- The callback form is untouched by all of this, and is asserted anyway: it
    -- is the form a consumer uses when it does not want a promise, and a fix
    -- to the await path must not change what it delivers.
    do
        env.serverEvents = {}
        local got, n
        env.EXPORTS.CallCallback('ask', function(...)
            n = select('#', ...)
            got = table.pack(...)
        end)
        local req = env.serverEvents[#env.serverEvents]
        env.net('cis_libs:cb:res', 0, req.args[2], true, { id = 7 }, 'second')
        check(n == 3 and got[1] == true,
            ('C1: the callback form still delivers the flag and both values (n=%d)')
                :format(tostring(n)))
    end

    env.awaitHook = nil
    env.reset()
end

-- ================================== 4. zone insideEvent cannot flood ()
--
-- A zone created with `insideEvent` set and `insideInterval = 0` fired that
-- event EVERY FRAME, and the second zone thread runs on `Wait(0)` while any such
-- zone is active -- so a player standing in one produced 60 net events a second,
-- per zone, aimed at the server's rate limiter. The author's intent with an
-- interval of 0 is "as often as possible"; aimed at the SERVER it is only ever
-- a client-side flood.
--
-- The audit's number for the test: at most 4 per simulated second. That is the
-- 250ms floor rather than an arbitrary tolerance, which is why the assertion
-- states it exactly.
local function zoneEnv()
    local env = newEnv({})
    env.coords = { x = 0.0, y = 0.0, z = 0.0 }
    -- A REAL vector3, not a plain table. client/zones.lua does `#(coords -
    -- lastPos)` to decide whether the player has moved half a cell, and both
    -- operators are Cfx natives on the real type. A plain table makes that line
    -- raise, and the loop dies on its first pass -- which looks exactly like a
    -- zone that never fires.
    local Vec = {}
    Vec.__index = Vec
    Vec.__sub = function(a, b) return vector3(a.x - b.x, a.y - b.y, a.z - b.z) end
    Vec.__len = function(v) return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z) end
    function vector3(x, y, z) return setmetatable({ x = x, y = y, z = z }, Vec) end
    env.saved[#env.saved + 1] = { name = 'CisReadyState', value = rawget(_ENV, 'CisReadyState') }
    CisReadyState = { wait = function() return true end, ready = true }
    -- Only the LAST thread is the one that drives inside-events; the sweeps are
    -- collected rather than run, for the reason in the base harness.
    local threads = {}
    function CreateThread(fn) threads[#threads + 1] = fn end
    -- zones.lua starts ONE thread, on the first create: the engine's on-demand
    -- driver, which runs the main pass and the per-frame inside pass together
    -- and ends once no zone is left. threads[1] is that thread.
    env.saved[#env.saved + 1] = { name = 'Cis', value = rawget(_ENV, 'Cis') }
    env.saved[#env.saved + 1] = { name = 'vector3', value = rawget(_ENV, 'vector3') }
    Cis = Cis or {}
    Cis.player = Cis.player or {}
    -- A player that walks a little and stops: inside the 20-unit box, and past
    -- the half-cell movement threshold so containment is actually re-tested.
    env.step = 0
    Cis.player.coords = function()
        env.step = (env.step or 0) + 1
        return vector3(env.step * 0.1, 0.0, 0.0)
    end
    env.threads = threads
    loadModule('client/zones.lua')
    return env
end

-- ONE SIMULATED SECOND OF THE ZONE LOOP.
--
-- The loop is `while true do ... Wait(waitMs) end`, so calling it directly never
-- returns. `Wait` is where the loop goes round, so that is where the iteration
-- is counted and where a private sentinel unwinds it -- the same technique the
-- server harness uses, and for the same reason.
--
-- The WAKEUPS are what matter, not the loop iterations: `waitMs` is computed per
-- pass from the zone's own interval, so a 250ms zone produces about four wakeups
-- a second and an unclamped one produces sixty. Counting wakeups therefore
-- measures the rate the audit is about, which counting iterations would not.
-- A private sentinel, LOCAL: as a bare assignment this would create a
-- global named `env`, which would then be indexed on every call.
local TICK_LIMIT = {}
local function simulateSecond(env)
    env.serverEvents = {}
    env.clock = 0
    -- The loop only re-tests containment after HALF A CELL of movement, so a
    -- player standing still never enters the zone and the test measures nothing.
    -- The first pass always moves (lastPos is nil), so the very first tick is
    -- the one that matters -- but the coords move every frame here so the zone
    -- is entered and STAYED in, which is what an insideEvent is about.
    env.move = 0
    -- The MAIN loop, not the last one. See the note in zoneEnv.
    local last = env.threads[1]
    if not last then
        return 0
    end
    local wakeups = 0
    local realWait = Wait
    Wait = function(ms)
        -- A Wait resumes no sooner than the next frame, so `Wait(0)` is one 16 ms
        -- frame here as in game; counted as 0 ms the second never ended.
        env.clock = env.clock + math.max(tonumber(ms) or 0, 16)
        wakeups = wakeups + 1
        if env.clock >= 1000 then
            error(TICK_LIMIT, 0)
        end
    end
    local ok, err = pcall(last)
    Wait = realWait
    if not ok and err ~= TICK_LIMIT then
        error(err, 0)
    end
    if wakeups == 0 then
        env.lastErr = tostring(err)
    end
    return wakeups
end

do
    local env = zoneEnv()
    local created = exports.CreateZone('box', 'shop',
        { x = 0.0, y = 0.0, z = 0.0 }, { x = 20.0, y = 20.0, z = 20.0 }, {
            insideEvent = 'my_resource:inShop',
            insideInterval = 0,
        })
    check(created == true, 'a zone with an insideEvent creates')

    local wakeups = simulateSecond(env)

    local fired = #env.serverEventsOf('my_resource:inShop')
    check(fired <= 4,
        ('an insideEvent with interval 0 fires at most 4 times per second (fired=%d)')
            :format(fired))
    check(fired >= 1,
        ('and it still fires at all (fired=%d wakeups=%s err=%s grid=%s)')
            :format(fired, tostring(wakeups), tostring(env.lastErr), tostring(CisGrid)))
    env.reset()
end

-- A PLAYER WHO WALKS A SHORT WAY INTO A ZONE MUST BE FOUND.
--
-- Discovery was gated on `moved`: half a cell, 32 m at CELL = 64, or a cell
-- boundary crossing. Below that threshold the only work that happened was
-- `recheckInside`, which by definition re-tests the zones already inside and
-- so can never discover one. A zone was therefore enterable only by a player
-- who happened to travel far enough or land in a new cell.
--
-- Every zone test above passed on the FIRST pass alone: `lastPos` is nil then,
-- and `not lastPos` counts as moved, so the discovery path ran exactly once and
-- the threshold was never exercised. That is why this passed in unit tests and
-- failed on a real player: live, run-20261003-003525, a player walking ~17 m
-- into a 4 m box reported `0 time(s), insideCount=0 inside=[]`.
--
-- 40 passes at 0.1 each puts the player at x = 4.0 -- inside a box spanning
-- 3..7, and nowhere near the 32 m that would have woken the old gate.
do
    local env = zoneEnv()
    env.enterCount = 0
    local created = exports.CreateZone('box', 'shortwalk',
        { x = 5.0, y = 0.0, z = 0.0 }, { x = 4.0, y = 4.0, z = 4.0 }, {
            onEnter = function() env.enterCount = env.enterCount + 1 end,
        })
    check(created == true, 'the short-walk zone creates')

    local realWait = Wait
    local passes = 0
    Wait = function(ms)
        env.clock = env.clock + (tonumber(ms) or 0)
        passes = passes + 1
        if passes >= 40 then error(TICK_LIMIT, 0) end
    end
    local ok, err = pcall(env.threads[1])
    Wait = realWait
    if not ok and err ~= TICK_LIMIT then error(err, 0) end

    local dbg = exports.GetZoneDebug()
    check(env.enterCount == 1,
        ('a player who walks 4 m into a zone is found exactly once '
            .. '(onEnter=%d insideCount=%s inside=[%s] after %d passes)')
            :format(env.enterCount, tostring(dbg and dbg.insideCount),
                    tostring(dbg and table.concat(dbg.insideNames or {}, ',')),
                    passes))

    -- The duplicate half of the claim: once found, the player must STAY found,
    -- and the pass that discovers must not also re-fire onEnter every tick.
    check(dbg ~= nil and dbg.insideCount == 1,
        ('and the player stays inside it (insideCount=%s)')
            :format(tostring(dbg and dbg.insideCount)))
    env.reset()
end

-- `local = true` keeps the event on the client. Every zone event reaches the
-- server by default, because that is the only way a server-side consumer can be
-- notified -- but a consumer that only cares about its own client does not need
-- the round trip, and paying one per inside-tick is what made the flood.
do
    local env = zoneEnv()
    exports.CreateZone('box', 'localShop',
        { x = 0.0, y = 0.0, z = 0.0 }, { x = 20.0, y = 20.0, z = 20.0 }, {
            insideEvent = 'my_resource:localInShop',
            insideInterval = 0,
            ['local'] = true,
        })

    simulateSecond(env)

    check(#env.serverEventsOf('my_resource:localInShop') == 0,
        '`local = true` sends NOTHING to the server')
    check(#env.localEventsOf('my_resource:localInShop') >= 1,
        ('and fires it on the client instead (fired=%d)')
            :format(#env.localEventsOf('my_resource:localInShop')))
    env.reset()
end

-- `local = true` covers onEnterEvent too. It was read only when insideEvent was
-- set, so an enter event meant to stay on this client went to the server.
do
    local env = zoneEnv()
    env.invoking = 'my_resource'
    local ok = exports.CreateZone('box', 'localEnter',
        { x = 0.0, y = 0.0, z = 0.0 }, { x = 20.0, y = 20.0, z = 20.0 }, {
            onEnterEvent = 'my_resource:entered',
            ['local'] = true,
        })
    env.invoking = nil
    simulateSecond(env)
    check(ok == true and #env.serverEventsOf('my_resource:entered') == 0
        and #env.localEventsOf('my_resource:entered') == 1,
        ('`local = true` with only onEnterEvent fires it locally, once (server=%d local=%d)')
            :format(#env.serverEventsOf('my_resource:entered'), #env.localEventsOf('my_resource:entered')))
    env.reset()
end

-- AN onEnter THAT CREATES A ZONE does not insert into the bucket being walked.
-- The handler ran inside the grid's `pairs`, so a zone made there was a new key
-- in the table under traversal. The grid is watched rather than trusted to
-- crash: a Lua table often survives this and silently skips a zone instead.
do
    local env = zoneEnv()
    local realQuery, realInsert = CisGrid.queryPoint, CisGrid.insert
    local walking, insertedMidWalk = false, 0
    CisGrid.queryPoint = function(...)
        walking = true
        local ok, err = pcall(realQuery, ...)
        walking = false
        if not ok then error(err, 0) end
    end
    CisGrid.insert = function(...)
        if walking then insertedMidWalk = insertedMidWalk + 1 end
        return realInsert(...)
    end
    local childEntered, spawned = 0, false
    exports.CreateZone('box', 'spawner', { x = 0.0, y = 0.0, z = 0.0 }, { x = 20.0, y = 20.0, z = 20.0 }, {
        onEnter = function()
            if spawned then return end
            spawned = true
            for i = 1, 8 do
                exports.CreateZone('box', 'child' .. i, { x = 0.0, y = 0.0, z = 0.0 }, { x = 20.0, y = 20.0, z = 20.0 }, {
                    onEnter = function() childEntered = childEntered + 1 end,
                })
            end
        end,
    })
    local okRun, runErr = pcall(simulateSecond, env)
    CisGrid.queryPoint, CisGrid.insert = realQuery, realInsert
    check(okRun and spawned and insertedMidWalk == 0,
        ('a zone created in onEnter is inserted after the grid walk, not during it (mid-walk=%d, %s)')
            :format(insertedMidWalk, tostring(runErr)))
    check(childEntered == 8, ('and every zone it created is entered on a later pass (%d of 8)'):format(childEntered))
    env.reset()
end

-- An onEnter that REMOVES a zone the same walk also found: that zone is not
-- entered after it was removed.
do
    local env = zoneEnv()
    local order = {}
    local function make(name, victim)
        exports.CreateZone('box', name, { x = 0.0, y = 0.0, z = 0.0 }, { x = 20.0, y = 20.0, z = 20.0 }, {
            onEnter = function()
                order[#order + 1] = name
                if victim then exports.RemoveZone(victim) end
            end,
        })
    end
    make('killerA', 'killerB')
    make('killerB', 'killerA')
    simulateSecond(env)
    check(#order == 1, ('of two zones that remove each other on entry, only the first is entered (%s)')
        :format(table.concat(order, ',')))
    env.reset()
end

-- A LOCAL ZONE EVENT IS FIRED AS cis_libs, so another resource may not name an
-- event that trusts that: the cache mirror's, or onResourceStop for a zone named
-- 'cis_libs' (CisRealStop passes when the invoker is the resource stopping).
do
    local env = zoneEnv()
    env.invoking = 'evil'
    local center, size = { x = 0.0, y = 0.0, z = 0.0 }, { x = 20.0, y = 20.0, z = 20.0 }
    for _, c in ipairs({
        { 'vehicle', 'onEnterEvent', 'cis_libs:cache' },
        { 'cis_libs', 'onEnterEvent', 'onResourceStop' },
        { 'evilExit', 'onExitEvent', 'onClientResourceStop' },
        { 'evilInside', 'insideEvent', 'other_res:open' },
    }) do
        local okZone, why = exports.CreateZone('box', c[1], center, size, { [c[2]] = c[3], ['local'] = true })
        check(okZone == false and tostring(why):find('evil:', 1, true) ~= nil,
            ('a local %s %q from another resource is refused, naming the prefix it needs (%s)')
                :format(c[2], c[3], tostring(why)))
    end
    local okOwn = exports.CreateZone('box', 'evilOwn', center, size, { onEnterEvent = 'evil:entered', ['local'] = true })
    check(okOwn == true, 'its own "<resource>:" local event is allowed')
    local okServer = exports.CreateZone('box', 'evilServer', center, size, { onEnterEvent = 'cis_libs:anything' })
    check(okServer == true, 'and a server event keeps any name: the server sees the player, not cis_libs')
    local okType, typeWhy = exports.CreateZone('box', 'evilType', center, size, { onEnterEvent = 42 })
    check(okType == false and tostring(typeWhy):find('string', 1, true) ~= nil,
        ('an event name that is not a string is refused (%s)'):format(tostring(typeWhy)))
    env.invoking = nil
    simulateSecond(env)
    check(#env.localEventsOf('onResourceStop') == 0 and #env.localEventsOf('cis_libs:cache') == 0,
        'and nothing reserved was fired')
    env.reset()
end

-- A zone whose `inside` is a plain FUNCTION keeps whatever interval the caller
-- asked for, including 0. The clamp exists because an event aimed at the SERVER
-- spends someone else's budget; a local function spends none, and clamping it
-- would be a silent behaviour change for a caller who asked for per-frame and
-- got 4Hz.
do
    local env = zoneEnv()
    local insideCalls = 0
    exports.CreateZone('box', 'localFn',
        { x = 0.0, y = 0.0, z = 0.0 }, { x = 20.0, y = 20.0, z = 20.0 }, {
            inside = function() insideCalls = insideCalls + 1 end,
            insideInterval = 0,
        })

    -- The first second puts the player INSIDE the zone, which is a precondition
    -- rather than the measurement.
    simulateSecond(env)

    -- The per-frame inside pass is where the measurement happens. The clamp must
    -- NOT reach it: a function callback costs nothing on the server, so clamping
    -- it would silently take a per-frame callback away from a caller who
    -- explicitly asked for one.
    -- The player STOPS here: the stub walks 0.1 per read, and at per-frame rate
    -- it would walk out of the box before the burst is counted.
    Cis.player.coords = function() return vector3(0.0, 0.0, 0.0) end
    local before = insideCalls
    local TICK = {}
    local realWait = Wait
    local frames = 0
    Wait = function(ms)
        env.clock = env.clock + math.max(tonumber(ms) or 0, 16)
        frames = frames + 1
        if insideCalls - before >= 30 or frames >= 600 then error(TICK, 0) end
    end
    local ok, err = pcall(env.threads[1])
    Wait = realWait
    if not ok and err ~= TICK then error(err, 0) end

    local fast = insideCalls - before
    check(fast >= 30,
        ('a plain `inside` FUNCTION is NOT clamped to 250ms -- it reaches '
            .. 'per-frame (calls=%d in a burst)'):format(fast))
    check(#env.serverEventsOf('my_resource:anything') == 0,
        'and it never became a server event -- it was always a local call')
    env.reset()
end

-- ======================================== 5. aiming reads a BOOLEAN ()
--
-- `IsPlayerFreeAiming()` and `GetPedConfigFlag()` both answer a BOOLEAN in Lua.
-- Comparing either to 1 is therefore `true == 1`, which is false for every
-- player at every moment -- so `CisCache.aiming` was never true and every
-- consumer listening for it heard nothing, on a stock server, forever.
--
-- The stub returns a boolean on purpose. A stub returning 1 would pass against
-- the broken code, which is how a test that models the wrong thing certifies the
-- wrong thing.
do
    local env = newEnv({})
    -- Both natives answer BOOLEANS, which is what they answer in game. That is
    -- the whole bug: a stub returning 1 would pass against the broken comparison
    -- and certify it.
    env.sawAiming = false
    function IsPlayerFreeAiming()
        env.sawAiming = true
        return true
    end
    function GetPedConfigFlag() return true end
    function GetPedConfigFlag() return true end
    Config = CisDefaults.config()
    Globals = {}
    -- CisReadyState gates the cache loop's first pass. Saved and set here rather
    -- than left to whatever a previous suite left behind: with `wait` answering
    -- false the thread returns before it reads anything, and the test asserts on
    -- a cache that was never populated -- which passes for the wrong reason.
    env.saved[#env.saved + 1] = { name = 'CisReadyState', value = rawget(_ENV, 'CisReadyState') }
    CisReadyState = { wait = function() return true end, ready = true, failed = false }
    -- One bounded pass of the cache loop. The loop is `while true`, so `Wait` is
    -- where it goes round and where a private sentinel unwinds it.
    loadModule('client/cache.lua')
    -- client/cache.lua starts two threads: the main loop and the near-watcher
    -- sweep. The FIRST is the one that computes `aiming`.
    local pass = env.threads[1]
    local TICK = {}
    local realWait = Wait
    Wait = function(ms) env.clock = env.clock + (tonumber(ms) or 0); error(TICK, 0) end
    local ok, err = pcall(pass)
    Wait = realWait
    if not ok and err ~= TICK then error(err, 0) end

    -- `CisCache.aiming` is the field setField writes; `Globals.Player.IsAiming`
    -- is what publishGlobals mirrors it into. Asserted through the cache, which
    -- is where the boolean is decided, and through the mirror, which is what a
    -- consumer actually reads.
    check(CisCache.aiming == true,
        ('the aiming flag is TRUE while the player IS aiming (got %s)')
            :format(tostring(CisCache.aiming)))
    check(Globals.Player and Globals.Player.IsAiming == true,
        ('and the published mirror agrees (got %s)')
            :format(tostring(Globals.Player and Globals.Player.IsAiming)))

    -- The same check against the configFlag path, which has the identical bug:
    -- GetPedConfigFlag answers a boolean and was compared to 1.
    Config = CisDefaults.config()
    Config.AimingCheckType = 'configFlag'
    Globals = {}
    CisReadyState = { wait = function() return true end, ready = true, failed = false }
    loadModule('client/cache.lua')
    local pass2 = env.threads[1]
    Wait = function(ms) env.clock = env.clock + (tonumber(ms) or 0); error(TICK, 0) end
    local ok2, err2 = pcall(pass2)
    Wait = realWait
    if not ok2 and err2 ~= TICK then error(err2, 0) end
    check(CisCache.aiming == true,
        ('and the configFlag path agrees (got %s)'):format(tostring(CisCache.aiming)))
    env.reset()
end

-- ============================================ 5b. the cache pass itself
--
-- A world the test controls: which vehicle, which seat, armed, shooting,
-- heading. GetPedInVehicleSeat answers from `env.seat`, so a shuffle is a test
-- writing one number.
local function cacheEnv(opts)
    opts = opts or {}
    local env = newEnv({})
    env.ped = 7
    env.vehicle, env.seat = 0, nil
    env.armed, env.shooting, env.heading = false, false, 0.0
    env.save('CisReadyState')
    env.save('GetWeaponAttachments')
    CisReadyState = opts.ready or { wait = function() return true end, ready = true, failed = false }
    Config = opts.config
    Globals = {}
    function GetPlayerServerId() return 12 end
    function GetEntityHeading() return env.heading end
    function IsPedInAnyVehicle() return env.vehicle ~= 0 end
    function GetVehiclePedIsIn() return env.vehicle end
    function GetPedInVehicleSeat(veh, i)
        env.seatReads = (env.seatReads or 0) + 1
        return (veh == env.vehicle and i == env.seat) and env.ped or 0
    end
    function GetVehicleMaxNumberOfPassengers() return 3 end
    function IsPedArmed() return env.armed end
    function GetSelectedPedWeapon() return 0x1234 end
    function GetAmmoInPedWeapon() return 30 end
    function GetWeaponAttachments() return {} end
    function IsPlayerFreeAiming() return false end
    function IsPedShooting() return env.shooting end
    loadModule('client/cache.lua')
    return env
end

-- Drive the MAIN cache thread for `n` passes. `between(i)` runs at each Wait,
-- so a test changes the world between passes; the waits are recorded.
local CACHE_DONE = {}
local function cachePasses(env, n, between)
    local waits = {}
    local realWait = Wait
    Wait = function(ms)
        waits[#waits + 1] = ms
        env.clock = env.clock + (tonumber(ms) or 0)
        if #waits >= n then error(CACHE_DONE, 0) end
        if between then between(#waits) end
    end
    local ok, err = pcall(env.threads[1])
    Wait = realWait
    if not ok and err ~= CACHE_DONE then error(err, 0) end
    return waits
end

-- HEADING IS PUSHED ONLY WHILE A CONSUMER FOLLOWS IT. Every push is a
-- TriggerEvent into every client resource's runtime, several times a second
-- while the player moves, and only a heading listener needs it.
do
    local env = cacheEnv()
    local function headingPushes()
        local n = 0
        for _, e in ipairs(env.serverEvents) do
            if e.name == 'cis_libs:cache' and e.args[1] == 'heading' then n = n + 1 end
        end
        return n
    end
    env.serverEvents = {}
    local h = 0
    cachePasses(env, 4, function() h = h + 10; env.heading = h end)
    check(headingPushes() == 0, ('cache: with no follower, heading changes are not pushed (%d)'):format(headingPushes()))
    env.invoking = 'res_a'
    check(exports.FollowCacheHeading() == true, 'cache: a consumer follows the heading')
    env.invoking = nil
    cachePasses(env, 4, function() h = h + 10; env.heading = h end)
    check(headingPushes() > 0, 'cache: and from then heading changes are pushed')
    env.fire('onResourceStop', 'res_a')
    env.serverEvents = {}
    cachePasses(env, 4, function() h = h + 10; env.heading = h end)
    check(headingPushes() == 0, 'cache: the follower stopping ends the pushes')
    env.reset()
end

-- AN ATTACHMENT FITTED TO THE HELD WEAPON IS SEEN. The same hash only re-read
-- the ammo, so a suppressor added while holding the gun stayed invisible until
-- the player switched weapons.
do
    local env = cacheEnv()
    local fitted = {}
    function GetWeaponAttachments() return fitted end
    local seen = 0
    CisCache.on('weapon', function() seen = seen + 1 end)
    env.armed = true
    cachePasses(env, 2)
    check(CisCache.weapon and #CisCache.weapon.attachments == 0, 'cache: the weapon starts bare')
    local before = seen
    fitted = { 0xABCD }
    cachePasses(env, 12)
    check(CisCache.weapon and #CisCache.weapon.attachments == 1 and CisCache.weapon.attachments[1] == 0xABCD,
        'cache: a suppressor fitted to the held weapon reaches the cache')
    check(seen > before, 'cache: and weapon listeners are told')
    env.reset()
end

-- A SEAT SHUFFLE IS SEEN, and the vehicle listener sees the NEW seat.
do
    local env = cacheEnv()
    local seenSeats, seatAtVehicle = {}, nil
    CisCache.on('seat', function(seat) seenSeats[#seenSeats + 1] = seat end)
    CisCache.on('vehicle', function() seatAtVehicle = CisCache.seat end)
    env.vehicle, env.seat = 50, 1
    cachePasses(env, 3, function(i)
        if i == 1 then env.seat = -1 end
    end)
    check(seatAtVehicle == 1,
        ('cache: a vehicle listener sees the seat that came WITH the vehicle (got %s)'):format(tostring(seatAtVehicle)))
    check(CisCache.seat == -1 and seenSeats[#seenSeats] == -1,
        ('cache: a shuffle to the driver seat is seen on the next pass (seat=%s)'):format(tostring(CisCache.seat)))
    env.reset()
end

-- THE PUSH TO EVERY CONSUMER'S MIRROR. cis_libs is the single producer: each
-- change is one LOCAL `cis_libs:cache` event, the seat rides on the vehicle push
-- so the two land together in a consumer too, an ammo-only refresh is silent,
-- and a pass that changes nothing pushes nothing.
do
    local env = cacheEnv()
    env.vehicle, env.seat = 50, 1
    cachePasses(env, 2, function(i)
        if i == 1 then env.seat = -1 end
    end)
    local function pushesOf(key)
        local out = {}
        for _, e in ipairs(env.localEventsOf('cis_libs:cache')) do
            if e.args[1] == key then out[#out + 1] = e.args end
        end
        return out
    end
    local veh = pushesOf('vehicle')
    check(#veh == 2 and veh[1][2] == 50 and veh[1][3] == 1 and veh[2][2] == 50 and veh[2][3] == -1,
        ('cache: a vehicle and a shuffle are two vehicle pushes, each carrying its seat (%d pushes)')
            :format(#veh))
    check(#pushesOf('seat') == 0, 'cache: the seat never travels on its own, so it cannot arrive apart from its vehicle')
    check(#pushesOf('serverId') == 1 and pushesOf('serverId')[1][2] == 12,
        'cache: the ids are pushed when they are first known')
    check(#env.serverEventsOf('cis_libs:cache') == 0, 'cache: the push is a LOCAL event; nothing reaches the server')

    local before = #env.localEventsOf('cis_libs:cache')
    cachePasses(env, 3)
    check(#env.localEventsOf('cis_libs:cache') == before,
        ('cache: passes that change nothing push nothing (%d new)'):format(#env.localEventsOf('cis_libs:cache') - before))

    env.armed = true
    cachePasses(env, 2)
    local weapon = pushesOf('weapon')
    check(#weapon == 1 and type(weapon[1][2]) == 'table' and weapon[1][2].ammo == 30 and weapon[1][4] == nil,
        'cache: drawing a weapon is an announced weapon push')
    env.save('GetAmmoInPedWeapon')
    function GetAmmoInPedWeapon() return 29 end
    cachePasses(env, 2)
    weapon = pushesOf('weapon')
    check(#weapon == 2 and weapon[2][2].ammo == 29 and weapon[2][4] == true,
        'cache: a shot that only moves the ammo is a SILENT push')

    local snap = exports.GetCacheSnapshot()
    check(type(snap) == 'table' and snap ~= CisCache and snap.vehicle == 50 and snap.seat == -1
        and snap.serverId == 12 and snap.armed == true and snap.weapon and snap.weapon.ammo == 29,
        'cache: GetCacheSnapshot answers every mirrored key in a fresh table')
    env.reset()
end

-- THE CADENCE. The config default is 1000 ms, which made the pass a 1 Hz poll:
-- a shot (`IsPedShooting` true for a frame or two) was never seen. Clamped to
-- 100..250 with or without a config.
do
    local env = cacheEnv({ config = CisDefaults.config() })
    local waits = cachePasses(env, 2)
    check(waits[1] ~= nil and waits[1] >= 100 and waits[1] <= 250,
        ('cache: the pass runs at 100-250 ms even when the config says 1000 (waited %s)'):format(tostring(waits[1])))
    env.reset()
    local env2 = cacheEnv({ config = nil })
    local waits2 = cachePasses(env2, 2)
    check(waits2[1] ~= nil and waits2[1] >= 100 and waits2[1] <= 250,
        ('cache: and with no config at all (waited %s)'):format(tostring(waits2[1])))
    env2.reset()
end

-- SHOOTING AND HEADING EMIT, like every other key.
do
    local env = cacheEnv()
    local shots, headings = {}, {}
    local _, sid = CisCache.on('shooting', function(v) shots[#shots + 1] = v end)
    CisCache.on('heading', function(v) headings[#headings + 1] = v end)
    check(type(sid) == 'number', 'cache: on() answers an id in slot two')
    cachePasses(env, 4, function(i)
        if i == 1 then env.shooting = true; env.heading = 90.0 end
        if i == 2 then env.shooting = false end
    end)
    check(#shots == 2 and shots[1] == true and shots[2] == false,
        ('cache: shooting emits on and off (events=%d)'):format(#shots))
    check(headings[#headings] == 90.0, 'cache: heading emits its change')
    local bad, why = CisCache.on('coords', function() end)
    check(bad == nil and type(why) == 'string' and why:find('unknown', 1, true),
        'cache: an unknown key is refused with a reason, not silently never fired')
    env.reset()
end

-- LISTENERS FROM OTHER RESOURCES: funcrefs, owned, removable by id, released on stop.
do
    local env = cacheEnv()
    env.save('GetInvokingResource')
    GetInvokingResource = function() return 'res_a' end
    local got = 0
    local unsub, id = exports.OnPlayerCache('armed', funcref(function() got = got + 1 end))
    check(type(id) == 'number', ('cache: a funcref listener is accepted (id=%s)'):format(tostring(id)))
    local _, id2 = exports.OnPlayerCache('armed', funcref(function() got = got + 100 end))
    cachePasses(env, 2, function() env.armed = true end)
    check(got == 101, ('cache: both funcref listeners fire (got=%d)'):format(got))
    GetInvokingResource = function() return 'res_b' end
    local stolen = exports.RemovePlayerCacheListener(id)
    check(stolen == false, 'cache: another resource cannot remove the listener')
    GetInvokingResource = function() return 'res_a' end
    check(exports.RemovePlayerCacheListener(id) == true, 'cache: its owner removes it by id')
    env.fire('onResourceStop', 'res_a')
    got = 0
    cachePasses(env, 2, function() env.armed = false end)
    check(got == 0, ('cache: a stopped owner\'s listeners are released (got=%d)'):format(got))
    check(exports.RemovePlayerCacheListener(id2) == false, 'cache: and the released id is gone')
    check(type(unsub) == 'function', 'cache: the in-realm unsubscribe is still returned in slot one')

    -- A near watcher is removed by its owner or cis_libs only. The ids are
    -- sequential, so an unchecked RemoveNearWatcher let any script count up from
    -- 1 and remove every resource's watchers.
    GetInvokingResource = function() return 'res_a' end
    local _, wid = exports.WatchNear({ x = 0.0, y = 0.0, z = 0.0 }, 2.0, nil, nil, 'a:in', 'a:out')
    GetInvokingResource = function() return 'res_b' end
    local took, why = exports.RemoveNearWatcher(wid)
    check(took == false and tostring(why):find('res_a', 1, true) ~= nil,
        ('cache: another resource cannot remove a near watcher (%s)'):format(tostring(why)))
    GetInvokingResource = function() return 'res_a' end
    check(exports.RemoveNearWatcher(wid) == true, 'cache: its owner removes it by id')
    local _, wid2 = exports.WatchNear({ x = 0.0, y = 0.0, z = 0.0 }, 2.0, nil, nil, 'a:in', 'a:out')
    GetInvokingResource = function() return nil end
    check(exports.RemoveNearWatcher(wid2) == true, 'cache: and so does cis_libs')
    env.reset()
end

-- THE NEAR-WATCHER THREAD IS ON DEMAND. It used to wake twice a second on
-- every client with no watcher at all: started with the first watcher, ended
-- with the last, and started again by the next one.
do
    local env = cacheEnv()
    env.saved[#env.saved + 1] = { name = 'Cis', value = rawget(_ENV, 'Cis') }
    Cis = Cis or {}
    Cis.player = Cis.player or {}
    local priorCoords = Cis.player.coords
    Cis.player.coords = function() return vector3(0.0, 0.0, 0.0) end
    local base = #(env.threads or {})
    check(base == 1, ('near: a client with no watcher runs only the cache loop (%d threads)'):format(base))
    GetInvokingResource = function() return 'res_a' end
    local _, w1 = exports.WatchNear({ x = 0.0, y = 0.0, z = 0.0 }, 2.0, nil, nil, 'a:in', 'a:out')
    local _, w2 = exports.WatchNear({ x = 1.0, y = 0.0, z = 0.0 }, 2.0, nil, nil, 'a:in', 'a:out')
    check(#env.threads == base + 1, ('near: two watchers start ONE thread (%d)'):format(#env.threads - base))
    local nearThread = env.threads[#env.threads]
    -- The thread runs while a watcher is left and returns once none is.
    local waits = 0
    local realWait = Wait
    Wait = function(ms)
        waits = waits + 1
        env.clock = env.clock + (tonumber(ms) or 0)
        if waits == 1 then exports.RemoveNearWatcher(w1) end
        if waits == 2 then exports.RemoveNearWatcher(w2) end
        if waits > 10 then error('near: the thread did not end with its last watcher', 0) end
    end
    local ok, err = pcall(nearThread)
    Wait = realWait
    check(ok and waits == 2, ('near: the thread ends with the last watcher (waits=%d %s)'):format(waits, tostring(err)))
    check(#env.serverEventsOf('a:in') >= 1, 'near: and while it ran it told the watcher it was entered')
    exports.WatchNear({ x = 0.0, y = 0.0, z = 0.0 }, 2.0, nil, nil, 'a:in', 'a:out')
    check(#env.threads == base + 2, 'near: and the next watcher starts it again')
    Cis.player.coords = priorCoords
    env.reset()
end

-- THE CACHE LOOP NEVER GIVES UP ON READINESS.
do
    local calls = 0
    local env = cacheEnv({ ready = {
        wait = function() calls = calls + 1; return calls > 1 end, ready = false, failed = false,
    } })
    env.vehicle, env.seat = 50, 0
    cachePasses(env, 2)
    check(calls >= 2 and CisCache.vehicle == 50,
        ('cache: a first ready wait that times out is retried, and the loop runs (waits=%d vehicle=%s)')
            :format(calls, tostring(CisCache.vehicle)))
    env.reset()
end

-- THE VEHICLE EVENT CANNOT BE FORGED. gameEventTriggered for ANOTHER player, or
-- a hand-raised 'CEventNetworkPlayerEnteredVehicle', must not rewrite the cache.
do
    local env = cacheEnv()
    cachePasses(env, 1)
    check(env.handlers['CEventNetworkPlayerEnteredVehicle'] == nil,
        'cache: no handler on the bare CEventNetworkPlayerEnteredVehicle name, which the game never raises')
    env.fire('gameEventTriggered', 'CEventNetworkPlayerEnteredVehicle', { 5, 999 })
    check(CisCache.vehicle == 0,
        ('cache: another player entering a vehicle does not change ours (vehicle=%s)'):format(tostring(CisCache.vehicle)))
    env.fire('gameEventTriggered', 'CEventNetworkPlayerEnteredVehicle', { 0, 999, -1 })
    check(CisCache.vehicle == 0,
        'cache: even our own event cannot write a vehicle the natives do not confirm')
    env.vehicle, env.seat = 60, 2
    env.fire('gameEventTriggered', 'CEventNetworkPlayerEnteredVehicle', { 0, 60 })
    check(CisCache.vehicle == 60 and CisCache.seat == 2,
        ('cache: our own event triggers an immediate re-read (vehicle=%s seat=%s)')
            :format(tostring(CisCache.vehicle), tostring(CisCache.seat)))
    env.reset()
end

-- ============================================ 6. a dead cached ped ()
--
-- `GetCachedPed` answered `CisCache.ped ~= 0 and CisCache.ped or PlayerPedId()`,
-- which is right -- but the CACHE LOOP held `CisCache.ped` for up to a second
-- after a respawn handed out a new one, so zones tested the DEAD ped's
-- coordinates and reported the player as flickering out of and into whatever
-- they were standing in.
--
-- The fix is one cheap native: ask for the ped rather than trusting a value that
-- is up to a second stale.
do
    local env = newEnv({})
    env.ped = 55
    loadModule('client/cache.lua')
    -- CisCache.ped starts empty, so the getter must fall back to the native.
    CisCache.ped = 0
    local got = CisCache.ped ~= 0 and CisCache.ped or PlayerPedId()
    check(got == 55,
        ('a missing cached ped falls back to PlayerPedId (got %s)'):format(tostring(got)))
    env.reset()
end

-- ================================== 7. vehicle colour re-apply ()
--
-- `SetVehicleProperties` diffs every field against its own last-applied
-- snapshot, so a second apply with identical props does nothing -- which is the
-- point, and what makes it cheap on a moving synced vehicle.
--
-- But `lastApplied` stores whatever the CALLER passed. For a custom RGB the
-- caller passes a TABLE (`{ r, g, b }`), and the setter reads the live primary
-- colour from the vehicle rather than from the props. So the snapshot held
-- `{10,20,30}` while the vehicle's actual colour was something else, and the
-- NEXT apply of the same props diffed a table against a table, decided nothing
-- had changed, and skipped -- even though the colour on the vehicle had moved.
--
-- On the SYNC path that is a vehicle whose paint never updates again, with no
-- error anywhere. Asserted through the natives, because a colour bug raises
-- nothing and returns nothing.
do
    local env = newEnv({})
    local calls = {}
    -- The vehicle's LIVE primary colour, which the setter must consult rather
    -- than trusting the snapshot. Changing it between applies is what makes the
    -- two props different in reality while looking identical in the snapshot.
    local livePrimary = 1
    function DoesEntityExist() return true end
    function GetClosestVehicle() return 0 end
    function SetVehicleModKit() end
    function GetVehicleColours() return livePrimary, 2 end
    function GetVehicleExtraColours() return 0, 0 end
    function GetIsVehiclePrimaryColourCustom() return false end
    function GetIsVehicleSecondaryColourCustom() return false end
    function SetVehicleColours(vehicle, primary, secondary)
        calls[#calls + 1] = { name = 'SetVehicleColours', primary = primary, secondary = secondary }
        if type(primary) == 'number' then livePrimary = primary end
    end
    function SetVehicleCustomPrimaryColour(_, r, g, b)
        calls[#calls + 1] = { name = 'SetVehicleCustomPrimaryColour', r = r, g = g, b = b }
    end
    function ClearVehicleCustomPrimaryColour()
        calls[#calls + 1] = { name = 'ClearVehicleCustomPrimaryColour' }
    end
    function IsPedInAnyVehicle() return false end
    function GetVehiclePedIsIn() return 0 end
    function IsEntityAMissionEntity() return false end
    function SetVehicleNumberPlateText(_, text)
        calls[#calls + 1] = { name = 'SetVehicleNumberPlateText', text = text }
    end
    loadModule('client/vehicle.lua')

    -- First apply: a palette number. Nothing to compare yet.
    SetVehicleProperties(9, { color1 = 55 })
    check(#calls > 0, 'the first apply reaches the colour setters')

    -- The vehicle's colour is changed by something else -- another resource, or
    -- the game. This is the state the snapshot cannot see.
    livePrimary = 99

    -- Same props again. The vehicle is now a different colour, so the correct
    -- behaviour is to apply them AGAIN; the defect is to diff them away.
    local before = #calls
    SetVehicleProperties(9, { color1 = 55 })
    check(#calls > before,
        ('a re-apply whose colour drifted on the vehicle is NOT skipped '
            .. '(setter calls before=%d after=%d)'):format(before, #calls))

    -- And a custom RGB table must never reach SetVehicleColours, which takes a
    -- number. Reaching it with a table is a silent no-op in game.
    calls = {}
    SetVehicleProperties(9, { color1 = { 10, 20, 30 } })
    local leaked = false
    for _, c in ipairs(calls) do
        if c.name == 'SetVehicleColours' and type(c.primary) == 'table' then leaked = true end
    end
    check(not leaked,
        'a table color1 is never passed to SetVehicleColours, which wants a number')

    -- THERE IS NO DIFF. A re-apply of the same props applies again: the
    -- snapshot it used to diff against went stale the moment gameplay, another
    -- resource or a repair touched the vehicle, and was keyed by a recycled
    -- handle -- so the apply that was skipped was exactly the one needed.
    calls = {}
    SetVehicleProperties(9, { plate = 'ABC123' })
    local firstPlate = #calls
    calls = {}
    SetVehicleProperties(9, { plate = 'ABC123' })
    check(firstPlate > 0 and #calls == firstPlate,
        ('an identical re-apply is applied again, not skipped by a stale snapshot '
            .. '(first apply made %d calls, second made %d)')
            :format(firstPlate, #calls))

    calls = {}
    SetVehicleProperties(9, { plate = 'XYZ789' })
    check(#calls > 0, 'and a CHANGED plate is still applied')
    env.reset()
end

-- ====================================== 7b. vehicle properties, field by field
--
-- A recorder for every setter, and getters answering a known vehicle, so the
-- round trip get -> set can be asserted field by field against ox_lib's shape.
local VEH_SETTERS = {
    'SetVehicleModKit', 'SetVehicleFixed', 'SetVehicleExtra', 'SetVehicleDoorsLocked',
    'SetVehicleNumberPlateText', 'SetVehicleNumberPlateTextIndex', 'SetVehicleBodyHealth',
    'SetVehicleEngineHealth', 'SetVehiclePetrolTankHealth', 'SetVehicleFuelLevel', 'SetVehicleOilLevel',
    'SetVehicleDirtLevel', 'ClearVehicleCustomPrimaryColour', 'ClearVehicleCustomSecondaryColour',
    'SetVehicleModColor_1', 'SetVehicleModColor_2', 'SetVehicleColours', 'SetVehicleCustomPrimaryColour',
    'SetVehicleCustomSecondaryColour', 'SetVehicleExtraColours', 'SetVehicleInteriorColor',
    'SetVehicleDashboardColor', 'SetVehicleWheelType', 'SetVehicleWindowTint', 'SetVehicleNeonLightEnabled',
    'SetVehicleNeonLightsColour', 'RemoveVehicleWindow', 'SetVehicleDoorBroken', 'SetVehicleTyreBurst',
    'SetVehicleTyreSmokeColor', 'SetVehicleMod', 'ToggleVehicleMod', 'SetVehicleXenonLightsColor',
    'SetVehicleWheelSize', 'SetVehicleWheelWidth', 'SetVehicleLivery', 'SetVehicleRoofLivery',
    'SetVehicleTyresCanBurst', 'SetDriftTyresEnabled', 'NetworkRequestControlOfEntity',
}
local function vehEnv()
    local env = newEnv({})
    env.calls = {}
    -- Into _ENV, not _G: under the lua54 driver each suite runs in its own
    -- environment, and an earlier test's `function SetVehicleColours()` lives
    -- THERE, shadowing anything written to _G. Restored by env.reset.
    local previous = {}
    for _, name in ipairs(VEH_SETTERS) do
        previous[name] = rawget(_ENV, name)
    end
    local baseReset = env.reset
    env.reset = function()
        for _, name in ipairs(VEH_SETTERS) do
            rawset(_ENV, name, previous[name])
        end
        baseReset()
    end
    for _, name in ipairs(VEH_SETTERS) do
        _ENV[name] = function(...)
            local a = table.pack(...)
            -- SetVehicleColours takes two palette INDICES; anything else is the
            -- defect that reset or aborted the apply.
            if name == 'SetVehicleColours' then
                assert(math.type(a[2]) == 'integer' and math.type(a[3]) == 'integer',
                    ('SetVehicleColours wants two integers, got %s, %s'):format(type(a[2]), type(a[3])))
            end
            env.calls[#env.calls + 1] = { name = name, args = a }
        end
    end
    env.extrasAsked = {}
    env.tyresAsked = {}
    function DoesEntityExist() return true end
    function GetVehicleColours() return 5, 6 end
    function GetVehicleExtraColours() return 7, 8 end
    function GetVehicleModColor_1() return 3, 0, 0 end
    function GetVehicleModColor_2() return 1, 0 end
    function GetIsVehiclePrimaryColourCustom() return false end
    function GetIsVehicleSecondaryColourCustom() return false end
    function DoesExtraExist(_, i) env.extrasAsked[#env.extrasAsked + 1] = i; return i == 0 or i == 20 end
    function IsVehicleExtraTurnedOn(_, i) return i == 0 end
    function GetVehicleLiveryCount() return 3 end
    function GetVehicleLivery() return 1 end
    function GetVehicleMod(_, i) return i == 47 and 2 or -1 end
    function IsVehicleWindowIntact() return true end
    function IsVehicleDoorDamaged() return false end
    function IsVehicleTyreBurst(_, i) env.tyresAsked[i] = true; return i == 45 end
    function IsVehicleNeonLightEnabled() return false end
    function GetVehicleInteriorColor() return 11 end
    function GetVehicleDashboardColour() return 12 end
    function GetVehicleWheelWidth() return 0.75 end
    function GetVehicleWheelSize() return 0.8 end
    function GetVehicleXenonLightsColor() return 4 end
    function GetVehicleTyresCanBurst() return false end
    function IsToggleModOn(_, i) return i == 21 end
    function GetDriftTyresEnabled() return false end
    loadModule('client/vehicle.lua')
    function env.called(name)
        local out = {}
        for i, c in ipairs(env.calls) do
            if c.name == name then out[#out + 1] = c; c.at = i end
        end
        return out
    end
    return env
end

do
    local env = vehEnv()
    -- color2 ALONE keeps the live primary. It used to pass `appliedColor1`,
    -- nil here, which reset the primary to black.
    SetVehicleProperties(9, { color2 = 33 })
    local sc = env.called('SetVehicleColours')[1]
    check(sc and sc.args[2] == 5 and sc.args[3] == 33,
        ('vehicle: color2 alone keeps the live primary (got %s, %s)')
            :format(tostring(sc and sc.args[2]), tostring(sc and sc.args[3])))

    -- A CUSTOM color1 WITH A PALETTE color2 does not hand SetVehicleColours a
    -- table, and the props after the colours are still applied.
    env.calls = {}
    local ok, err = pcall(SetVehicleProperties, 9, { color1 = { 1, 2, 3 }, color2 = 40, plate = 'AFTER' })
    check(ok, ('vehicle: custom color1 + palette color2 does not raise (%s)'):format(tostring(err)))
    sc = env.called('SetVehicleColours')[1]
    check(sc and sc.args[2] == 5 and sc.args[3] == 40, 'vehicle: and the palette secondary lands beside the live primary')
    check(#env.called('SetVehicleCustomPrimaryColour') == 1, 'vehicle: the custom primary is applied')
    check(#env.called('SetVehicleNumberPlateText') == 1, 'vehicle: and the fields after the colours still apply')
    env.reset()
end

-- GET -> SET ROUND TRIP. Every field the getter reads, the setter writes, with
-- ox_lib's meaning.
do
    local env = vehEnv()
    local props = GetVehicleProperties(9)
    check(props.bulletProofTyres == true,
        'vehicle: bulletProofTyres is NOT GetVehicleTyresCanBurst -- tyres that cannot burst are bulletproof')
    check(props.modDoorR == 2, ('vehicle: modDoorR is read from mod 47 (got %s)'):format(tostring(props.modDoorR)))
    check(props.modHydraulics == true, 'vehicle: modHydraulics is the VMT_HYDRAULICS toggle, as ox_lib reads it')
    check(props.extras[0] == 0 and props.extras[20] == 1,
        'vehicle: extras 0 and 20 are read (the range is 0..20, not 1..15)')
    check(env.tyresAsked[45] and env.tyresAsked[47] and props.tyres[45] ~= nil,
        'vehicle: the trailer tyres 45 and 47 are read')
    env.calls = {}
    local ok, err = pcall(SetVehicleProperties, 9, props)
    check(ok, ('vehicle: the getter output applies cleanly (%s)'):format(tostring(err)))
    local function argOf(name, slot)
        local c = env.called(name)[1]
        return c and c.args[slot]
    end
    check(argOf('SetVehicleXenonLightsColor', 2) == 4, 'vehicle: xenonColor is written back')
    check(argOf('SetVehicleInteriorColor', 2) == 11, 'vehicle: interiorColor is written back')
    check(argOf('SetVehicleDashboardColor', 2) == 12, 'vehicle: dashboardColor is written back')
    check(argOf('SetVehicleWheelWidth', 2) == 0.75, 'vehicle: wheelWidth is written back')
    check(argOf('SetVehicleWheelSize', 2) == 0.8, 'vehicle: wheelSize is written back')
    check(argOf('SetVehicleTyresCanBurst', 2) == false, 'vehicle: a bulletproof set is written as CAN NOT burst')
    check(argOf('SetVehicleModColor_1', 2) == 3, 'vehicle: paintType1 is written for a palette colour too')
    local doorR = false
    for _, c in ipairs(env.called('SetVehicleMod')) do
        if c.args[2] == 47 and c.args[3] == 2 then doorR = true end
    end
    check(doorR, 'vehicle: modDoorR is written to mod 47')
    local hyd = false
    for _, c in ipairs(env.called('ToggleVehicleMod')) do
        if c.args[2] == 21 and c.args[3] == true then hyd = true end
    end
    check(hyd, 'vehicle: modHydraulics is toggled back on')
    local tyre45 = false
    for _, c in ipairs(env.called('SetVehicleTyreBurst')) do
        if c.args[2] == 45 then tyre45 = true end
    end
    check(tyre45, 'vehicle: a burst trailer tyre is restored')
    -- Wheel size and width only take on non-default rims, so they come after them.
    local wheelsAt, sizeAt
    for i, c in ipairs(env.calls) do
        if c.name == 'SetVehicleMod' and c.args[2] == 23 then wheelsAt = i end
        if c.name == 'SetVehicleWheelSize' then sizeAt = i end
    end
    check(wheelsAt and sizeAt and sizeAt > wheelsAt, 'vehicle: wheel size is applied after the wheel mod')
    env.reset()
end

-- REPAIR FIRST, so saved damage survives a fixVehicle apply.
do
    local env = vehEnv()
    SetVehicleProperties(9, { tyres = { [0] = 2 }, bodyHealth = 500 }, true)
    local fixAt, burstAt
    for i, c in ipairs(env.calls) do
        if c.name == 'SetVehicleFixed' then fixAt = i end
        if c.name == 'SetVehicleTyreBurst' then burstAt = i end
    end
    check(fixAt and burstAt and fixAt < burstAt,
        ('vehicle: SetVehicleFixed runs BEFORE the saved damage, not after it (fix=%s burst=%s)')
            :format(tostring(fixAt), tostring(burstAt)))
    env.reset()
end

-- NETWORK CONTROL. A networked vehicle this client does not control is not
-- written: control is requested and the caller is told why.
do
    local env = vehEnv()
    function NetworkGetEntityIsNetworked() return true end
    function NetworkHasControlOfEntity() return false end
    local ok, why = SetVehicleProperties(9, { plate = 'NOPE' })
    check(ok == false and type(why) == 'string' and why:find('control', 1, true),
        ('vehicle: no control answers false and a reason (got %s, %s)'):format(tostring(ok), tostring(why)))
    check(#env.called('NetworkRequestControlOfEntity') == 1, 'vehicle: and control is requested')
    check(#env.called('SetVehicleNumberPlateText') == 0, 'vehicle: and nothing is written')
    function NetworkHasControlOfEntity() return true end
    check(SetVehicleProperties(9, { plate = 'YES' }) == true, 'vehicle: with control it applies and answers true')
    env.reset()
end

-- GetClosestVehicle IS NOT REPLACED, and the export finds a parked vehicle.
do
    local env = newEnv({})
    local native = function() return 'native' end
    GetClosestVehicle = native
    env.save('GetGamePool')
    env.save('GetOffsetFromEntityInWorldCoords')
    env.save('StartExpensiveSynchronousShapeTestLosProbe')
    env.save('GetShapeTestResult')
    env.save('GetEntityType')
    local pos = { [1] = { x = 0.0, y = 0.0, z = 0.0 }, [300] = { x = 3.0, y = 0.0, z = 0.0 }, [301] = { x = 4.0, y = 0.0, z = 0.0 } }
    function GetEntityCoords(e) return pos[e] end
    function GetOffsetFromEntityInWorldCoords() return { x = 0.0, y = 5.0, z = 0.0 } end
    env.save('StartShapeTestLosProbe')
    local probe, reads, waits = nil, 0, 0
    -- The synchronous probe blocks the game thread; calling it fails the test.
    rawset(_ENV, 'StartExpensiveSynchronousShapeTestLosProbe', function()
        error('vehicle: the synchronous LOS probe blocks the game thread', 0)
    end)
    function StartShapeTestLosProbe(...)
        probe = table.pack(...)
        return 1
    end
    -- PENDING once, then a hit on vehicle 400, so a result needs a later frame.
    function GetShapeTestResult()
        reads = reads + 1
        if reads == 1 then return 1, 0, nil, nil, 0 end
        return 2, 1, { x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 0 }, 400
    end
    function GetEntityType(e) return e == 400 and 2 or 0 end
    function GetGamePool(name)
        assert(name == 'CVehicle', 'GetGamePool: unknown pool ' .. tostring(name))
        return { 301, 300 }
    end
    loadModule('client/vehicle.lua')
    check(GetClosestVehicle == native, 'vehicle: loading cis_libs does not replace the GetClosestVehicle native')
    -- A caller that cannot yield gets the pool's answer, and no probe is started.
    local got = exports.GetClosestVehicle()
    check(got == 300, ('vehicle: the export walks the vehicle pool for the nearest (got %s)'):format(tostring(got)))
    check(probe == nil, 'vehicle: a caller that cannot yield starts no probe it could not read')
    -- A caller in a thread waits for the async probe, and the vehicle ahead wins.
    local realWait = Wait
    Wait = function(ms) waits = waits + 1; realWait(ms) end
    local co = coroutine.create(function() return exports.GetClosestVehicle() end)
    local done, ahead = coroutine.resume(co)
    Wait = realWait
    check(done and ahead == 400 and waits == 1,
        ('vehicle: in a thread the async probe is polled a frame and its vehicle answers (got %s, waits=%d)')
            :format(tostring(ahead), waits))
    check(probe and probe.n == 9 and type(probe[1]) == 'number' and type(probe[6]) == 'number',
        'vehicle: the aim probe is given six floats, not two vectors')
    env.reset()
end

-- ============================= 8. zone and target names are NOT global ()
--
-- [D3] Namespacing would change what `remove(name)` means, so the choice is to
-- REFUSE a name another resource already holds, and say who holds it.
--
-- The behaviour being replaced is worse than it looks. Resource B creating a zone
-- called 'shop' did not fail and did not warn: it overwrote B's own table entry,
-- so from then on `remove('shop')` removed B's zone while A's kept firing from the
-- grid, and A's exit callbacks went to A for a zone A had lost. Two resources,
-- one name, and neither able to see the other.
do
    local env = zoneEnv()

    env.invoking = 'res_a'
    local first = exports.CreateZone('box', 'shop',
        { x = 0.0, y = 0.0, z = 0.0 }, { x = 20.0, y = 20.0, z = 20.0 }, {})
    check(first == true, 'the first resource creates a zone with the name')

    -- The SAME resource re-creating its own zone is the update path, not a
    -- conflict. Refusing it would break every resource that legitimately rebuilds
    -- a zone, which is the common case on a reconfigure.
    env.invoking = 'res_a'
    local again = exports.CreateZone('box', 'shop',
        { x = 5.0, y = 0.0, z = 0.0 }, { x = 20.0, y = 20.0, z = 20.0 }, {})
    check(again == true, 'the same owner may re-create its own zone')

    -- A DIFFERENT resource is refused, and told who holds it.
    env.invoking = 'res_b'
    local clash, why = exports.CreateZone('box', 'shop',
        { x = 0.0, y = 0.0, z = 0.0 }, { x = 20.0, y = 20.0, z = 20.0 }, {})
    check(clash == false, 'a DIFFERENT owner is refused the name')
    check(tostring(why):find('res_a', 1, true) ~= nil,
        ('and the reason names the holder, so it is actionable: %s')
            :format(tostring(why)))

    -- And the refused zone really did not replace the live one. Coordinates are
    -- the observable: the zone B tried to create was at the origin, A's moved.
    check(exports.ZoneContains('shop', { x = 5.0, y = 0.0, z = 0.0 }) == true,
        'and the FIRST zone is still the one registered under that name')

    -- A BAD RE-CREATE LEAVES THE LIVE ZONE ALONE. The old zone was removed before
    -- the new geometry was checked, so a re-create that failed destroyed it.
    env.invoking = 'res_a'
    local bad = exports.CreateZone('poly', 'shop', {}, {})
    check(bad == false and exports.ZoneContains('shop', { x = 5.0, y = 0.0, z = 0.0 }) == true,
        'a re-create with an empty point list is refused and the live zone survives')
    local huge = exports.CreateZone('sphere', 'shop', { x = 0.0, y = 0.0, z = 0.0 }, 1e6, {})
    check(huge == false and exports.ZoneContains('shop', { x = 5.0, y = 0.0, z = 0.0 }) == true,
        'so does one the index refuses (a sphere a thousand kilometres wide)')
    for _, c in ipairs({ { 'y = -inf', 0.0, -math.huge }, { 'x = 1e21', 1e21, 0.0 } }) do
        debug.sethook(function() error('HUNG', 0) end, '', 2000000)
        local okCall, inf, infWhy = pcall(exports.CreateZone, 'sphere', 'far', { x = c[2], y = c[3], z = 0.0 }, 2.0, {})
        debug.sethook()
        check(okCall and inf == false and type(infWhy) == 'string',
            ('a sphere at %s is refused with a reason, not a hang (%s, %s)'):format(c[1], tostring(inf), tostring(infWhy)))
    end
    local str, strWhy = exports.CreateZone('box', 'shop2',
        { x = 0.0, y = 0.0, z = 0.0 }, { x = 2.0, y = 2.0, z = 2.0 },
        { inside = function() end, insideInterval = '250' })
    check(str == false and tostring(strWhy):find('insideInterval', 1, true) ~= nil,
        ('a string insideInterval is refused with a reason, not a raise (%s)'):format(tostring(strWhy)))
    env.invoking = 'res_b'

    -- H5 · A RETRY LOOP MUST NOT FLOOD THE CONSOLE.
    --
    -- The refusal is correct and the victim's zone is safe either way, but a
    -- resource that retries in a loop turns a correct refusal into a denial of
    -- service against the operator's console -- and the log is the thing
    -- somebody reads when they are already looking for a problem.
    --
    -- THE REFUSAL ITSELF IS *NOT* LATCHED, and that is the half that matters: a
    -- retrying caller must keep being told it was refused, or it will read
    -- persistence as success and carry on believing it owns the name.
    local function warningsAbout(needle)
        local n = 0
        for _, l in ipairs(env.logged) do
            if tostring(l[2] or ''):find(needle, 1, true) then
                n = n + 1
            end
        end
        return n
    end

    local before = warningsAbout('already registered by')
    for _ = 1, 50 do
        exports.CreateZone('box', 'shop',
            { x = 0.0, y = 0.0, z = 0.0 }, { x = 20.0, y = 20.0, z = 20.0 }, {})
    end
    local after = warningsAbout('already registered by')
    check(after - before <= 1,
        ('H5: fifty retries produce at most ONE warning (got %d)')
            :format(after - before))

    -- ...and the refusal is still returned EVERY time, not just the first.
    local stillRefused = true
    for _ = 1, 10 do
        local retry = exports.CreateZone('box', 'shop',
            { x = 0.0, y = 0.0, z = 0.0 }, { x = 20.0, y = 20.0, z = 20.0 }, {})
        if retry ~= false then stillRefused = false end
    end
    check(stillRefused == true,
        'H5: but every retry is STILL refused -- a latched return would let the '
            .. 'retrying resource believe it owns the name')

    -- A different collision pair is a different problem and is still reported.
    env.invoking = 'res_c'
    exports.CreateZone('box', 'shop',
        { x = 0.0, y = 0.0, z = 0.0 }, { x = 20.0, y = 20.0, z = 20.0 }, {})
    check(warningsAbout('already registered by') > after,
        'H5: and a DIFFERENT requester colliding with the same name is reported once')

    -- ONLY THE OWNER REMOVES. res_c is still the caller here, and a name is a
    -- guessable string: without the check it removes res_a's zone and fires
    -- res_a's onExit.
    local stolen, stolenWhy = exports.RemoveZone('shop')
    check(stolen == false and type(stolenWhy) == 'string' and stolenWhy:find('res_a', 1, true),
        ('remove() by a resource that does not own the zone is refused (got %s, %s)')
            :format(tostring(stolen), tostring(stolenWhy)))
    env.invoking = 'res_a'
    check(exports.RemoveZone('shop') == true, 'remove() works on the surviving zone, for its owner')
    env.reset()
end

-- The same rule for TARGETS, where the consequence is worse: the zones live in
-- the provider, so a silent replacement leaves an orphaned zone in the world
-- that only a restart of that provider clears.
do
    local env = newEnv({})
    env.invoking = 'res_a'
    -- A target provider that records what it was asked to remove, so the test can
    -- assert on the effect rather than on cis_libs's bookkeeping.
    local created, removed = {}, {}
    env.foreign('cis_bridge').CisBridgeTargetOx = function()
        return {
            name = function() return 'ox_target' end,
            available = function() return true end,
            create = function(spec)
                created[#created + 1] = spec.name
                return true
            end,
            remove = function(name)
                removed[#removed + 1] = name
                return true
            end,
        }
    end
    -- `Target.Create` waits on CisReadyState before it will do anything, and the
    -- base harness leaves it unset. Set here rather than in the harness because a
    -- test that needs readiness should SAY it needs readiness -- a harness that
    -- always reported ready would make every other test pass for the wrong
    -- reason if that guard ever regressed.
    env.saved[#env.saved + 1] = { name = 'CisReadyState', value = rawget(_ENV, 'CisReadyState') }
    CisReadyState = { wait = function() return true end, ready = true, failed = false }
    loadModule('client/target.lua')
    CisRegistry.register('target', 'cis_bridge:CisBridgeTargetOx')

    local CreateTarget = env.EXPORTS.CreateTarget
    local okA = CreateTarget('box', 't', { x = 0.0, y = 0.0, z = 0.0 }, { x = 2.0, y = 2.0, z = 2.0 }, {})
    check(okA == true, 'the first resource creates a target')

    env.invoking = 'res_a'
    check(CreateTarget('box', 't', { x = 1.0, y = 0.0, z = 0.0 }, { x = 2.0, y = 2.0, z = 2.0 }, {}) == true,
        'the same owner may re-create its own target')

    env.invoking = 'res_b'
    local okB, whyB = CreateTarget('box', 't', { x = 0.0, y = 0.0, z = 0.0 }, { x = 2.0, y = 2.0, z = 2.0 }, {})
    check(okB == false, 'a DIFFERENT owner is refused the target name')
    check(tostring(whyB):find('res_a', 1, true) ~= nil,
        ('and told who holds it: %s'):format(tostring(whyB)))

    -- The provider was never asked to create the refused one. A refusal that
    -- still hits the provider has already leaked a zone.
    local createdT = 0
    for _, n in ipairs(created) do
        if n == 't' then createdT = createdT + 1 end
    end
    check(createdT == 2,
        ('the provider was asked exactly twice (A initial, A update), '
            .. 'never for the refused one (asked %d)'):format(createdT))

    -- ONLY THE OWNER REMOVES OR UPDATES. res_b still cannot reach res_a's
    -- target by name, and the provider is never asked to.
    env.invoking = 'res_b'
    local rmB, rmWhy = env.EXPORTS.RemoveTarget('t')
    check(rmB == false and tostring(rmWhy):find('res_a', 1, true) ~= nil,
        ('RemoveTarget by another resource is refused (got %s, %s)'):format(tostring(rmB), tostring(rmWhy)))
    local upB = env.EXPORTS.UpdateTarget('t', {})
    check(upB == false, 'UpdateTarget by another resource is refused')
    check(#removed == 0, ('and the provider was never asked to remove it (removed=%d)'):format(#removed))
    check(env.EXPORTS.TargetExists('t') == true, 'the target still exists')
    env.invoking = 'res_a'
    check(env.EXPORTS.UpdateTarget('t', {}) == true, 'its owner can update it')
    check(env.EXPORTS.RemoveTarget('t') == true, 'and remove it')
    env.reset()
end

-- ======================================= 9. the zone guards (rest)
--
-- Arguments the exports boundary can drop, and no check for them. Each raised
-- INSIDE this file, so the stack trace landed in the consumer's log naming a file
-- it does not own -- for a mistake the caller could have been told about in a
-- return value.
do
    local env = zoneEnv()

    local ok, why = exports.CreateZone('box', 'noSize',
        { x = 0.0, y = 0.0, z = 0.0 }, nil, {})
    check(ok == false, 'a box with a nil size is refused, not defaulted')
    check(tostring(why):find('size', 1, true) ~= nil,
        ('and the reason names the missing argument: %s'):format(tostring(why)))

    ok, why = exports.CreateZone('hexagon', 'weird', { x = 0.0, y = 0.0, z = 0.0 }, 5.0, {})
    check(ok == false, 'an unknown zone kind is refused')
    check(tostring(why):find('hexagon', 1, true) ~= nil,
        ('and the reason names the kind it did not recognise: %s')
            :format(tostring(why)))

    -- ZoneContains with a point the boundary dropped. Indexing the nil raised in
    -- `contains`, and a caller asking "am I in this zone?" cannot act on a
    -- stack trace.
    exports.CreateZone('box', 'ok', { x = 0.0, y = 0.0, z = 0.0 }, { x = 4.0, y = 4.0, z = 4.0 }, {})
    local threw = not pcall(function() return exports.ZoneContains('ok', nil) end)
    check(not threw, 'ZoneContains with a nil point does not throw')
    check(exports.ZoneContains('ok', nil) == false,
        'and answers false, which is what a caller can act on')
    check(exports.ZoneContains('noSuchZone', { x = 0.0, y = 0.0, z = 0.0 }) == false,
        'an unknown zone name is also a false, not an error')
    env.reset()
end

-- ============================ 10. zone registration, which is now the grid's
--
-- made CisGrid.insert refuse a malformed AABB, and register() now inserts
-- BEFORE recording the zone, so a refusal cannot leave a zone stored that no
-- query can reach. That reordering touches the ordinary update path, and
-- nothing above tested what register() does at all -- `CreateZone` was only
-- ever checked for its ROUTING (contracts.lua), never for its result. So the
-- ordinary path is pinned here: a zone that works, a zone re-created under the
-- same name, and zones refused for having no usable box.
do
    local env = zoneEnv()

    local ok = exports.CreateZone('box', 'shop',
        { x = 10.0, y = 10.0, z = 0.0 }, { x = 4.0, y = 4.0, z = 4.0 }, {})
    local why
    check(ok == true, 'an ordinary box zone is created')
    check(exports.ZoneContains('shop', { x = 10.0, y = 10.0, z = 0.0 }) == true,
        'and it contains its own centre')

    -- THE UPDATE PATH. Re-creating a zone under the same name is the common
    -- case -- every resource that rebuilds a zone on a reconfigure does it --
    -- and it is the path most exposed by an insert that can now fail. If the
    -- reorder lost the update, the OLD box would still be what every query
    -- answered with and the new position would simply never match.
    ok = exports.CreateZone('box', 'shop',
        { x = 90.0, y = 90.0, z = 0.0 }, { x = 4.0, y = 4.0, z = 4.0 }, {})
    check(ok == true, 'the same owner may re-create its own zone')
    check(exports.ZoneContains('shop', { x = 90.0, y = 90.0, z = 0.0 }) == true,
        'the re-created zone is at its NEW position')
    check(exports.ZoneContains('shop', { x = 10.0, y = 10.0, z = 0.0 }) == false,
        'and no longer at the old one')

    -- A POLY WITH REAL POINTS, which is the branch that now has to build a box
    -- or refuse.
    ok, why = exports.CreateZone('poly', 'yard', {
        { x = 0.0, y = 0.0, z = 0.0 },
        { x = 10.0, y = 0.0, z = 0.0 },
        { x = 10.0, y = 10.0, z = 0.0 },
        { x = 0.0, y = 10.0, z = 0.0 },
    }, nil, {})
    check(ok == true, ('a poly zone with real points is created: %s'):format(tostring(why)))
    check(exports.ZoneContains('yard', { x = 5.0, y = 5.0, z = 0.0 }) == true,
        'and contains a point inside its polygon')

    -- THE DEFECT THIS EXISTS FOR. A poly with no points used to register a
    -- zero-size box at the WORLD ORIGIN, so it fired onEnter for anyone who
    -- spawned or respawned at (0,0), and nothing ever heard about the real
    -- zone not working. "It silently works somewhere else" is the worst shape
    -- a config mistake can take, because the mistake is invisible.
    ok, why = exports.CreateZone('poly', 'ghost', {}, nil, {})
    check(ok == false, 'a poly zone with no points is refused')
    check(tostring(why):find('empty', 1, true) ~= nil,
        ('and the reason says why: %s'):format(tostring(why)))
    check(exports.ZoneContains('ghost', { x = 0.0, y = 0.0, z = 0.0 }) == false,
        'and it is not registered at the origin')
    check(exports.RemoveZone('ghost') == false,
        'and there is nothing to remove, because it was never registered')

    -- A SHAPE THAT CAN CONTAIN NOTHING, OR CANNOT BE COMPUTED, IS REFUSED WITH A
    -- REASON. A table radius or a string heading raised inside the export; a
    -- negative size, a two-point poly or minZ above maxZ registered a zone that
    -- never fires.
    local o = { x = 0.0, y = 0.0, z = 0.0 }
    local p3 = { { x = 0.0, y = 0.0, z = 0.0 }, { x = 4.0, y = 0.0, z = 0.0 }, { x = 0.0, y = 4.0, z = 0.0 } }
    for _, c in ipairs({
        { 'a sphere with a table radius', 'sphere', o, { 2 }, {}, 'radius' },
        { 'a sphere with a negative radius', 'sphere', o, -1.0, {}, 'radius' },
        { 'a box with a negative size', 'box', o, { x = -0.5, y = 2.0, z = 2.0 }, {}, 'size' },
        { 'a box with a NaN size', 'box', o, 0 / 0, {}, 'size' },
        { 'a box with a string heading', 'box', o, 2.0, { heading = 'north' }, 'heading' },
        { 'a two-point poly', 'poly', { p3[1], p3[2] }, {}, nil, '3 points' },
        { 'a poly with minZ above maxZ', 'poly', p3, { minZ = 10.0, maxZ = 5.0 }, nil, 'minZ' },
    }) do
        local okCall, okShape, whyShape = pcall(exports.CreateZone, c[2], 'shape', c[3], c[4], c[5])
        check(okCall and okShape == false and tostring(whyShape):find(c[6], 1, true) ~= nil,
            ('%s is refused with a reason naming %s (%s, %s)'):format(c[1], c[6], tostring(okShape), tostring(whyShape)))
    end
    check(exports.CreateZone('poly', 'tri', p3, { minZ = -1.0, maxZ = 3.0 }) == true,
        'a three-point poly with minZ below maxZ is still accepted')
    exports.RemoveZone('tri')

    -- A box whose AABB would cover an absurd number of cells. The refusal has
    -- to leave nothing behind: a zone stored that no query can reach is the
    -- same invisible-record failure was about, in a new place.
    ok, why = exports.CreateZone('box', 'vast',
        { x = 0.0, y = 0.0, z = 0.0 }, { x = 2e4, y = 2e4, z = 10.0 }, {})
    check(ok == false, 'a zone covering an absurd number of cells is refused')
    check(tostring(why):find('cells', 1, true) ~= nil,
        ('and the reason names the cell count: %s'):format(tostring(why)))
    check(exports.ZoneContains('vast', { x = 0.0, y = 0.0, z = 0.0 }) == false,
        'and leaves no zone nothing-can-reach behind')

    -- The ordinary teardown still works after all of that.
    check(exports.RemoveZone('shop') == true, 'an ordinary zone still removes')
    check(exports.RemoveZone('yard') == true, 'and so does the poly')
    env.reset()
end

-- ============================================== 3.6 · every value survives
--
-- The client handler's results were captured into six named locals --
-- `local ok, a, b, c, d, e, f` -- and the reply was rebuilt from exactly those
-- six. A handler returning seven values lost the seventh, with no error and no
-- indication that anything had gone missing: the caller got a shorter answer and
-- had no way to know it.
--
-- Six was never a documented limit. It was however many names somebody wrote
-- down, which is the worst possible reason for an API to stop.
--
-- A NIL IN THE MIDDLE is the interesting case, because `{...}` and a bare
-- `unpack` both truncate at the first nil. Position 3 is nil and everything
-- after it must still arrive.
do
    local env = newEnv({})
    loadModule('client/callback.lua')

    env.invoking = 'res_a'
    env.EXPORTS.RegisterCallback('many', function()
        return 'one', 'two', nil, 'four', 'five', 'six', 'seven', 'eight'
    end)

    env.serverEvents = {}
    env.net('cis_libs:cb', 1, 'many', 42)
    local reply = env.serverEvents[#env.serverEvents]
    check(reply and reply.name == 'cis_libs:cb:serverRes',
        '3.6: the client answers the request')

    local args = reply and reply.args or {}
    -- The wire shape is (key, ok, then the handler's values).
    check(args[1] == 42, '3.6: the key comes back first')
    check(args[2] == true, '3.6: and the ok flag')
    check(args[3] == 'one' and args[4] == 'two',
        '3.6: the first two handler values arrive')
    check(args[6] == 'four' and args[7] == 'five',
        '3.6: EVERYTHING AFTER A NIL SURVIVES -- the part a bare unpack loses')
    check(args[8] == 'six' and args[9] == 'seven' and args[10] == 'eight',
        ('3.6: and so does the seventh value, which used to be dropped (n=%d)')
            :format(#args))
    env.reset()
end

-- ================================================ 3.4 · DrawText3D raises
--
-- `DrawText3D` called two natives that DO NOT EXIST: `GetGameplayCamCoords`
-- (the native is singular, `GetGameplayCamCoord`) and `DrawText` (there is no
-- such native at all -- screen text is `BeginTextCommandDisplayText` followed
-- by `EndTextComponentDisplayText`). It raised `attempt to call a nil value`
-- the first time anybody drew, and `cis_keys` calls it in a loop.
--
-- It survived because NO TEST CALLED IT. That is the whole lesson: a file can be
-- loaded, exported, documented and linted every single run while the one line
-- that makes it work is dead.
--
-- The native names are not guessed, and THAT IS THE POINT OF THE LOOKUP. The
-- first version of this fix used `EndTextComponentDisplayText`, which is the
-- obvious name to reach for and does not exist. Verified against FiveM's own
-- published database (`tools/natives/natives_gta.json`, re-downloaded from
-- runtime.fivem.net for this task):
--   CAM/GET_GAMEPLAY_CAM_COORD           ()
--   HUD/BEGIN_TEXT_COMMAND_DISPLAY_TEXT  (char* text)
--   HUD/END_TEXT_COMMAND_DISPLAY_TEXT    (float x, float y)
-- and there is no DRAW_TEXT entry, nor an END_TEXT_COMPONENT_DISPLAY_TEXT one.
do
    local env = newEnv({})
    -- Every text/camera native as an explicit stub that RECORDS its name, so the
    -- assertion is about what was called rather than about what did not raise.
    -- An unstubbed native is nil in this VM, which is exactly how the real
    -- defect presented.
    env.called = {}
    local function rec(name)
        return function(...)
            env.called[#env.called + 1] = name
            return nil
        end
    end
    for _, n in ipairs({
        'GetGameplayCamCoord', 'GetGameplayCamFov', 'SetTextScale', 'SetTextFont',
        'SetTextProportional', 'SetTextColour', 'SetTextCentre',
        'BeginTextCommandDisplayText', 'EndTextCommandDisplayText', 'DrawRect',
    }) do
        _G[n] = rec(n)
    end
    _G.GetGameplayCamCoord = function()
        env.called[#env.called + 1] = 'GetGameplayCamCoord'
        return { x = 0.0, y = 0.0, z = 0.0 }
    end
    _G.GetGameplayCamFov = function()
        env.called[#env.called + 1] = 'GetGameplayCamFov'
        return 50.0
    end
    _G.World3dToScreen2d = function()
        return true, 0.5, 0.5
    end
    -- BEGIN_TEXT_COMMAND_DISPLAY_TEXT TAKES A GXT LABEL. 'STRING' is the label that
    -- renders its components verbatim; anything else here is the caller's text
    -- being used as a label, which draws nothing in game.
    _G.BeginTextCommandDisplayText = function(label)
        env.called[#env.called + 1] = 'BeginTextCommandDisplayText'
        env.label = label
        if label ~= 'STRING' then
            error(('BeginTextCommandDisplayText wants the STRING label, got %q'):format(tostring(label)), 2)
        end
    end
    env.components = {}
    _G.AddTextComponentSubstringPlayerName = function(text)
        env.components[#env.components + 1] = text
    end
    -- The natives CisCreatePed and CisGetDistanceBetweenCoords must leave alone.
    local nativeCreatePed = function() return 4242 end
    local nativeDistance = function() return 'native' end
    env.save('GetDistanceBetweenCoords')
    CreatePed = nativeCreatePed
    GetDistanceBetweenCoords = nativeDistance
    -- vec2/vector3 are CfxLua builtins this VM does not have. `vector3` is
    -- already stubbed by newEnv; vec2 was not, which is why the first version of
    -- this test failed on a NATIVE and looked like the fix had not worked.
    _G.vec2 = function(x, y) return { x = x, y = y } end
    -- The ROUND native, which the Round export must leave alone.
    env.save('Round')
    local nativeRound = function() return 'native' end
    rawset(_ENV, 'Round', nativeRound)

    loadModule('client/utils.lua')
    check(rawget(_ENV, 'Round') == nativeRound, '10: loading cis_libs does not replace the ROUND native')
    check(exports.Round(1.256, 2) == 1.26, ('10: the Round export still rounds (got %s)'):format(tostring(exports.Round(1.256, 2))))

    local ok, err = pcall(function()
        exports.DrawText3D(10.0, 20.0, 30.0, 'harness')
    end)
    check(ok, ('3.4: DrawText3D does not raise on first call (%s)'):format(tostring(err)))

    local function called(name)
        for i = 1, #env.called do
            if env.called[i] == name then return true end
        end
        return false
    end
    check(called('GetGameplayCamCoord'),
        '3.4: it asks the camera for its coords (singular -- the plural does not exist)')
    check(called('BeginTextCommandDisplayText'),
        '3.4: and hands the text to BeginTextCommandDisplayText')
    check(called('EndTextCommandDisplayText'),
        '3.4: and positions it with EndTextCommandDisplayText -- Command, not '
            .. 'Component, and there is no DrawText native at all')
    check(env.label == 'STRING' and env.components[1] == 'harness',
        ('3.4: the label is STRING and the text is a substring component (label=%s component=%s)')
            :format(tostring(env.label), tostring(env.components[1])))

    -- NO NATIVE IS REBOUND. Both used to be replaced for every file in cis_libs.
    check(CreatePed == nativeCreatePed, 'utils: loading cis_libs does not replace the CreatePed native')
    check(GetDistanceBetweenCoords == nativeDistance,
        'utils: nor the GetDistanceBetweenCoords native')
    local flat = exports.GetDistanceBetweenCoords(0, 0, 0, 3, 4, 100, false)
    check(flat == 5, ('utils: the distance export honours useZ = false (got %s)'):format(tostring(flat)))
    local full = exports.GetDistanceBetweenCoords(0, 0, 0, 0, 3, 4)
    check(full == 5, ('utils: and is 3D by default (got %s)'):format(tostring(full)))
    -- A ped with no coords is refused with the documented 0, not a raise.
    local okPed, ped = pcall(exports.CreatePed, 'a_m_y_skater_01', nil, 0.0)
    check(okPed and ped == 0, ('utils: CreatePed with nil coords answers 0 (got %s, %s)'):format(tostring(okPed), tostring(ped)))
    env.reset()
end

-- ============================================== 3.3 · onExit on remove
--
-- `CisZonesRemove` fired `onExit` with the zone's CENTRE. Every other exit in
-- this file passes where the player actually is, so a consumer that uses the
-- coordinates got two different meanings from one handler -- and a removal was
-- the one case where it was guaranteed to be wrong, because the zone centre is
-- almost never where anybody is standing.
--
-- The old comment claimed "the pair still describes the same place". It does
-- not, and a test that agreed with it would have passed.
do
    local env = zoneEnv()
    local entered, exited
    exports.CreateZone('box', 'shop', { x = 0.0, y = 0.0, z = 0.0 },
        { x = 20.0, y = 20.0, z = 20.0 }, {
            onEnter = function() entered = true end,
            onExit = function(_, coords) exited = coords end,
        })

    -- Stand inside the zone, then move to a spot well away from its centre.
    -- The pass only re-tests containment after half a cell of movement, so a
    -- player standing still never enters and the test would measure nothing.
    env.coords = vector3(2.0, 2.0, 0.0)
    simulateSecond(env)
    check(entered == true, '3.3: entering fires onEnter and arms the exit')

    env.coords = vector3(15.5, 17.25, 0.0)
    simulateSecond(env)
    exited = nil
    check(exports.RemoveZone('shop') == true, '3.3: the zone removes')
    check(type(exited) == 'table',
        '3.3: and removing it while the player is inside fires onExit')
    check(exited and math.abs(exited.x - 15.5) < 0.001 and math.abs(exited.y - 17.25) < 0.001,
        ('3.3: with the PLAYER\'s position, not the zone centre (got %s, %s)')
            :format(tostring(exited and exited.x), tostring(exited and exited.y)))
    check(exited and math.abs(exited.x - 0.0) > 0.001,
        ('3.3: and it is demonstrably NOT the old value, which was %s')
            :format(tostring(exited and exited.x)))
    env.reset()
end

-- ============================================== 3.14 · the doorsClient path
--
-- `RequestLockDoors` / `RequestUnlockDoors` fired
-- `<prefix>:doorlock:requestState` DIRECTLY, bypassing the capability slot
-- every other client→server call in this library goes through.
--
-- It works today only because `cis_keys` happens to handle that exact event
-- name. So a product that supplies the `doorsClient` slot the documented way is
-- ignored, and the wire name this library chose is load-bearing on every
-- installed server whether anybody agreed to it or not.
--
-- The fix is go through `CisRegistry.call('doorsClient', 'RequestState',
-- ...)` when a provider is registered, and fall back to the event only when
-- none is.
do
    local env = newEnv({})
    env.saved[#env.saved + 1] = { name = 'CisReadyState', value = rawget(_ENV, 'CisReadyState') }
    CisReadyState = { wait = function() return true end, ready = true }
    loadModule('client/proxy.lua')

    -- NO provider registered: the event fallback must carry it, because that is
    -- what every installed server uses today.
    env.serverEvents = {}
    exports.RequestLockDoors('shop')
    local fired = env.serverEvents[#env.serverEvents]
    check(fired and fired.name:find('doorlock:requestState', 1, true) ~= nil,
        '3.14: with no doorsClient provider the event fallback still fires')
    check(fired and fired.args[1] == 'shop' and fired.args[2] == true,
        '3.14: and it carries the identifier and the state')

    -- WITH a provider: the slot must win, and the event must NOT fire. Firing
    -- both is the failure that would leave a product seeing two requests for one
    -- door lock and having no idea which one it answered.
    -- A PROVIDER SHAPE THIS LIBRARY DOCUMENTS: a bare callable is a DISPATCHER
    -- and takes the method name as its first argument -- cis_migrate's shape,
    -- and the one `CisRegistry.register` explicitly supports.
    --
    -- The first version of this fixture registered a function that RETURNS a
    -- method table. The registry read that as a dispatcher being asked for a
    -- method, it answered with a table, and the call SUCCEEDED -- so the case
    -- reported zero calls and no error anywhere. A test fixture that is the
    -- wrong shape for the thing it is testing fails in a way that looks exactly
    -- like the defect it was written to catch.
    local seen = {}
    CisRegistry.register('doorsClient', function(method, identifier, lock)
        if method ~= 'RequestState' then
            return nil
        end
        seen[#seen + 1] = { identifier = identifier, lock = lock }
        return 'handled by the slot'
    end)

    env.serverEvents = {}
    exports.RequestLockDoors('bank')
    check(#seen == 1 and seen[1].identifier == 'bank' and seen[1].lock == true,
        ('3.14: a registered doorsClient provider is asked instead (%d call(s))')
            :format(#seen))
    check(#env.serverEvents == 0,
        ('3.14: and the event does NOT also fire -- one request, one handler '
            .. '(%d event(s))'):format(#env.serverEvents))

    seen = {}
    exports.RequestUnlockDoors('bank')
    check(#seen == 1 and seen[1].lock == false,
        '3.14: and the same path answers for the unlock half')
    check(#env.serverEvents == 0, '3.14: with no event fallback either')
    env.reset()
end

-- ================================================ 3.4b · the debug draw thread
--
-- `debug = true` on a zone is stored and nothing reads it. There is no
-- drawing at all, so the option an operator reaches for to work out why a zone
-- does not fire does nothing -- and does nothing SILENTLY, which is the worst
-- way for a diagnostic to fail.
--
-- The thread's whole reason for existing is that it starts with the FIRST debug
-- zone and stops after the LAST. A thread that is always running spends a
-- frame drawing nothing on every server that has no debug zones, which is all
-- of them; a thread that never stops is worse than no thread.
do
    local env = zoneEnv()
    -- GetZoneDebug, not a harness flag. `debugDrawing` is the PUBLIC report of
    -- whether the thread is alive, and a test that watched a private variable
    -- would pass while the thing an operator reads reported something else.
    local function drawing()
        local diag = exports.GetZoneDebug()
        return diag and diag.debugDrawing
    end

    check(drawing() == false,
        '3.4b: no draw thread before any debug zone exists')

    exports.CreateZone('box', 'quiet', { x = 0.0, y = 0.0, z = 0.0 },
        { x = 10.0, y = 10.0, z = 4.0 }, {})
    check(drawing() == false,
        '3.4b: a zone WITHOUT debug does not start the draw thread')

    exports.CreateZone('box', 'loud', { x = 0.0, y = 0.0, z = 0.0 },
        { x = 10.0, y = 10.0, z = 4.0 }, { debug = true })
    check(drawing() == true,
        '3.4b: the FIRST debug zone starts the draw thread')

    -- The thread stops on its next pass, so it has to be GIVEN one. That is the
    -- real contract: the removal does not reach into the thread, the thread
    -- notices.
    env.tick(1)
    exports.RemoveZone('loud')
    env.tick(1)
    check(drawing() == false,
        '3.4b: the LAST debug zone stops it again, on the next pass')

    -- A sphere's radius is the SECOND POSITIONAL argument, not an option: the
    -- sphere branch reads `b` and everything else comes from `options`. Passing
    -- `radius` in options gives a radius of 1.0 and no error at all.
    exports.CreateZone('sphere', 'round', { x = 0.0, y = 0.0, z = 0.0 }, 5.0,
        { debug = true })
    check(drawing() == true, '3.4b: and another debug zone starts it again')

    -- AND A REFUSED ZONE MUST NOT. Starting the thread before the registration
    -- is accepted leaves a thread drawing nothing for a zone that does not
    -- exist, which is the failure the start-after-register ordering prevents.
    local bad = exports.CreateZone('nonsense', 'bad', { x = 0.0, y = 0.0, z = 0.0 },
        { x = 1.0, y = 1.0, z = 1.0 }, { debug = true })
    check(bad == false, '3.4b: a zone of an unknown kind is refused')
    env.tick(1)
    check(drawing() == true,
        '3.4b: and the refused zone did not disturb the thread')

    env.reset()
end

-- WHAT THE DEBUG THREAD DRAWS, against DRAW_MARKER's and DRAW_LINE's real
-- parameter lists. The stubs refuse a call whose scale or colour slots hold the
-- wrong thing, which is how the sphere's shifted arguments went unseen.
do
    local env = zoneEnv()
    env.lines, env.markers = {}, {}
    function DrawLine(...)
        local a = table.pack(...)
        assert(a.n == 10, 'DrawLine takes 10 arguments')
        env.lines[#env.lines + 1] = a
    end
    function DrawMarker(...)
        local a = table.pack(...)
        -- type, pos(3), dir(3), rot(3), scale(3), r, g, b, a, bob, face, p19,
        -- rotate, dict, name, drawOnEnts.
        assert(a.n == 24, ('DrawMarker takes 24 arguments, got %d'):format(a.n))
        for i = 14, 17 do
            assert(math.type(a[i]) == 'integer' and a[i] >= 0 and a[i] <= 255,
                ('DrawMarker colour slot %d must be an integer 0..255'):format(i))
        end
        env.markers[#env.markers + 1] = a
    end
    Cis.player.coords = function() return vector3(0.0, 0.0, 0.0) end

    exports.CreateZone('sphere', 'ball', { x = 0.0, y = 0.0, z = 0.0 }, 4.0, { debug = true })
    env.tick(1)
    local m = env.markers[1]
    check(m ~= nil and m[11] == 4.0 and m[12] == 4.0 and m[13] == 4.0,
        ('3.4b: a debug sphere is drawn with scale = radius on all three axes (got %s,%s,%s)')
            :format(tostring(m and m[11]), tostring(m and m[12]), tostring(m and m[13])))
    exports.RemoveZone('ball')

    -- A ROTATED BOX IS DRAWN ROTATED. A 10 x 2 box turned 90 degrees has a corner
    -- at (1, 5), and the unrotated outline never touches it.
    env.lines = {}
    exports.CreateZone('box', 'turned', { x = 0.0, y = 0.0, z = 0.0 },
        { x = 10.0, y = 2.0, z = 2.0 }, { debug = true, heading = 90.0 })
    env.tick(1)
    local sawCorner = false
    for _, l in ipairs(env.lines) do
        if math.abs(l[1] - 1.0) < 0.01 and math.abs(l[2] - 5.0) < 0.01 then sawCorner = true end
    end
    check(#env.lines > 0 and sawCorner,
        ('3.4b: a rotated box outline follows its heading (lines=%d)'):format(#env.lines))
    exports.RemoveZone('turned')

    -- AND ONLY NEAR THE PLAYER.
    env.lines = {}
    exports.CreateZone('box', 'faraway', { x = 3000.0, y = 0.0, z = 0.0 },
        { x = 4.0, y = 4.0, z = 4.0 }, { debug = true })
    env.tick(1)
    check(#env.lines == 0, ('3.4b: a debug zone across the map is not drawn (lines=%d)'):format(#env.lines))
    env.reset()
end

-- A ROTATED BOX MUST BE ENTERABLE IN ITS CORNERS. The index box used the
-- unrotated half-extents, so a 20 x 2 box turned 45 degrees indexed y within
-- +-1.5 m while its far end reaches y = 6.4: standing there was never a
-- candidate, so it never fired.
do
    local env = zoneEnv()
    local entered = 0
    exports.CreateZone('box', 'diag', { x = 0.0, y = 0.0, z = 0.0 },
        { x = 20.0, y = 2.0, z = 4.0 }, { heading = 45.0, onEnter = function() entered = entered + 1 end })
    Cis.player.coords = function() return vector3(6.0, 6.0, 0.0) end
    check(exports.ZoneContains('diag', { x = 6.0, y = 6.0, z = 0.0 }) == true,
        'rotated box: (6, 6) is inside a 20 x 2 box turned 45 degrees')
    local SENT = {}
    local n = 0
    local realWait = Wait
    Wait = function(ms) env.clock = env.clock + (tonumber(ms) or 0); n = n + 1; if n >= 2 then error(SENT, 0) end end
    local ok, err = pcall(env.threads[1])
    Wait = realWait
    if not ok and err ~= SENT then error(err, 0) end
    check(entered == 1, ('rotated box: a player in its far end is found by the pass (onEnter=%d)'):format(entered))
    env.reset()
end

-- THE ZONE LOOP NEVER GIVES UP ON READINESS. `wait(15000)` answering false used
-- to `return` from the thread: initialize.lua marks ready at the same 15 s, so
-- losing that race ended zones for the session.
do
    local env = zoneEnv()
    local calls = 0
    CisReadyState = {
        wait = function() calls = calls + 1; return calls > 1 end,
        ready = false,
    }
    local entered = 0
    exports.CreateZone('box', 'late', { x = 0.0, y = 0.0, z = 0.0 },
        { x = 10.0, y = 10.0, z = 10.0 }, { onEnter = function() entered = entered + 1 end })
    Cis.player.coords = function() return vector3(0.0, 0.0, 0.0) end
    local SENT = {}
    local realWait = Wait
    Wait = function(ms) env.clock = env.clock + (tonumber(ms) or 0); error(SENT, 0) end
    local ok, err = pcall(env.threads[1])
    Wait = realWait
    if not ok and err ~= SENT then error(err, 0) end
    check(calls >= 2 and entered == 1,
        ('a zone loop whose first ready wait timed out keeps waiting and then runs (waits=%d onEnter=%d)')
            :format(calls, entered))
    env.reset()
end

-- A PASS DOES NOT BUILD DEBUG STATE: no sort, and the list is right when asked.
do
    local env = zoneEnv()
    Cis.player.coords = function() return vector3(0.0, 0.0, 0.0) end
    exports.CreateZone('box', 'b1', { x = 0.0, y = 0.0, z = 0.0 }, { x = 10.0, y = 10.0, z = 10.0 }, {})
    exports.CreateZone('box', 'a1', { x = 0.0, y = 0.0, z = 0.0 }, { x = 10.0, y = 10.0, z = 10.0 }, {})
    local realSort = table.sort
    local sorts = 0
    table.sort = function(...) sorts = sorts + 1; return realSort(...) end
    local SENT = {}
    local n = 0
    local realWait = Wait
    Wait = function(ms) env.clock = env.clock + 200; n = n + 1; if n >= 3 then error(SENT, 0) end end
    local ok, err = pcall(env.threads[1])
    Wait = realWait
    table.sort = realSort
    if not ok and err ~= SENT then error(err, 0) end
    check(sorts == 0, ('a zone pass performs no sort (sorts=%d)'):format(sorts))
    local dbg = exports.GetZoneDebug()
    check(dbg.insideCount == 2 and dbg.insideNames[1] == 'a1' and dbg.insideNames[2] == 'b1',
        ('and GetZoneDebug still lists what the player is inside, sorted (count=%s)'):format(tostring(dbg.insideCount)))
    env.reset()
end

-- ============================ 4.6 · the spawn state machine, latest state wins
--
-- THE DEFECT. `apply` opened with
--
--     if spawning[record.id] then return end
--
-- so an upsert arriving while that id's model was loading was THROWN AWAY. The
-- server had already decided the entity belongs somewhere else -- the player
-- walked, or the record was updated -- and the client kept the position the
-- server had superseded. Nothing retries it: a static record is re-sent only
-- when a player crosses its scope boundary, so a synced prop sits at the wrong
-- place until somebody walks out of range and back.
do
    -- AN UPDATE ARRIVES WHILE THE MODEL IS LOADING. Latest wins.
    local env = syncEnv({})
    -- The model is NOT ready, or the spawn never yields and there is no window
    -- for anything to arrive during. `syncEnv` defaults it to true for the
    -- cases that want a spawn to complete immediately.
    env.modelReady = false
    env.upsert(wirePayload('latest', {
        kind = 'prop', model = 'prop_barrel_01',
        coords = { x = 1.0, y = 0.0, z = 0.0 }, networked = false,
    }))
    local co = coroutine.create(env.threads[#env.threads])
    check(coroutine.resume(co), '4.6: the first upsert starts spawning')
    check(coroutine.status(co) == 'suspended', '4.6: and is waiting on the model')

    -- The server moves it while we wait.
    env.upsert(wirePayload('latest', {
        kind = 'prop', model = 'prop_barrel_01',
        coords = { x = 9.0, y = 0.0, z = 0.0 }, networked = false,
    }))

    env.modelReady = true
    -- Resumed more than once, because reconciling the newest state can drive a
    -- further pass and a single resume would stop one step short of the answer.
    for _ = 1, 6 do
        if coroutine.status(co) == 'dead' then break end
        coroutine.resume(co)
    end

    local tracked = env.EXPORTS.GetSyncedEntities()
    local live = 0
    for _ in pairs(tracked) do live = live + 1 end
    check(live == 1,
        ('4.6: the superseded upsert is reconciled, not dropped, and exactly one '
            .. 'entity remains (%d alive)'):format(live))

    local moved = 0
    for _, n in ipairs(env.natives) do
        if n.name == 'SetEntityCoords' and n.x == 9.0 then moved = moved + 1 end
    end
    check(moved >= 1,
        ('4.6: and the entity ends where the NEWEST record said (%d moves to x=9)')
            :format(moved))
    env.reset()
end

-- MODEL RELEASE ON EVERY PATH, NOT ONLY THE SUCCESSFUL ONE.
--
-- `SetModelAsNoLongerNeeded` sat inside the `entity ~= 0` branch, so a model
-- that loaded and then produced nothing stayed loaded for the rest of the
-- session. On a server streaming hundreds of props that is a stream-out budget
-- spent on models nothing is using any more.
do
    local env = syncEnv({})
    local realCreate = CreateObject
    CreateObject = function() return 0 end
    env.upsert(wirePayload('released', {
        kind = 'prop', model = 'prop_barrel_01',
        coords = { x = 0.0, y = 0.0, z = 0.0 }, networked = false,
    }))
    CreateObject = realCreate

    local released = 0
    for _, n in ipairs(env.natives) do
        if n.name == 'SetModelAsNoLongerNeeded' then released = released + 1 end
    end
    check(released >= 1,
        ('4.6: a model whose create failed is still released (%d releases)')
            :format(released))
    env.reset()
end

-- A MODEL THAT NEVER ARRIVES IS RETRIED, NOT GIVEN UP ON.
--
-- One attempt that logs and gives up means a prop synced a second before its
-- model streams in never appears for the rest of the session. Bounded, because
-- an unbounded retry is a per-record thread that never dies.
do
    local env = syncEnv({})
    env.modelFails = 1
    env.upsert(wirePayload('retried', {
        kind = 'prop', model = 'prop_barrel_01',
        coords = { x = 0.0, y = 0.0, z = 0.0 }, networked = false,
    }))

    local attempts = 0
    for _, n in ipairs(env.natives) do
        if n.name == 'RequestModelTimeout' then attempts = attempts + 1 end
    end
    check(attempts == 1, ('4.6: one attempt so far (%d)'):format(attempts))

    env.runThreads()
    local after = 0
    for _, n in ipairs(env.natives) do
        if n.name == 'RequestModelTimeout' then after = after + 1 end
    end
    check(after == 2,
        ('4.6: a timed-out model is requested again (%d attempts after the retry)')
            :format(after))
    check(env.EXPORTS.GetSyncedEntities()[wireKeyOf('retried')] ~= nil,
        '4.6: and the retry leaves exactly one entity behind')
    env.reset()
end

-- A REMOVE DURING THE RETRY WINS. The retry must not resurrect a record the
-- server has already forgotten, which is the permanent leak this whole
-- mechanism exists to avoid.
do
    local env = syncEnv({})
    env.modelFails = 1
    env.upsert(wirePayload('gone', {
        kind = 'prop', model = 'prop_barrel_01',
        coords = { x = 0.0, y = 0.0, z = 0.0 }, networked = false,
    }))
    env.remove(wireKeyOf('gone'))
    env.runThreads()

    check(env.EXPORTS.GetSyncedEntities()[wireKeyOf('gone')] == nil,
        '4.6: a retry does not resurrect a removed record')
    local created = 0
    for _, n in ipairs(env.natives) do
        if n.name == 'CreateObject' then created = created + 1 end
    end
    check(created == 0,
        ('4.6: and nothing is created for it (%d creates)'):format(created))
    env.reset()
end

-- ============================ 4.6b · retries end, and the server is told
--
-- The retry thread reset the counter before it drove, so RETRY_MAX was never
-- reached: a model that does not exist was requested every 500 ms forever.
do
    local env = syncEnv({})
    env.modelFails = 1000
    env.upsert(wirePayload('absent', {
        kind = 'prop', model = 'prop_does_not_exist',
        coords = { x = 0.0, y = 0.0, z = 0.0 }, networked = false,
    }))
    for _ = 1, 20 do
        if env.runThreads() == 0 then break end
    end
    local attempts = 0
    for _, n in ipairs(env.natives) do
        if n.name == 'RequestModelTimeout' then attempts = attempts + 1 end
    end
    check(attempts == 5,
        ('4.6b: a missing model is tried once plus four retries, then given up (%d attempts)')
            :format(attempts))
    local told = nil
    for _ = 1, 3 do env.runThreads() end
    for _, e in ipairs(env.serverEvents) do
        if e.name == 'cis_libs:server:syncGaveUp' and type(e.args[1]) == 'table' then told = e.args[1][1] end
    end
    check(told == wireKeyOf('absent'),
        ('4.6b: and the server is told, so it stops believing this client holds it (%s)')
            :format(tostring(told)))
    env.reset()
end

-- ============================ 4.6d · give-ups go in one event
--
-- One event per key ran into the server's 8-a-second limit with nine bad models,
-- and the server kept believing this client held the rest.
do
    local env = syncEnv({})
    env.modelFails = 100000
    for i = 1, 20 do
        env.upsert(wirePayload('absent' .. i, {
            kind = 'prop', model = 'prop_does_not_exist',
            coords = { x = 0.0, y = 0.0, z = 0.0 }, networked = false,
        }))
    end
    for _ = 1, 40 do
        if env.runThreads() == 0 then break end
    end
    local events, keys = 0, 0
    for _, e in ipairs(env.serverEvents) do
        if e.name == 'cis_libs:server:syncGaveUp' then
            events = events + 1
            keys = keys + (type(e.args[1]) == 'table' and #e.args[1] or 0)
        end
    end
    check(events == 1 and keys == 20,
        ('4.6d: twenty give-ups reach the server as one event (events=%d keys=%d)'):format(events, keys))
    env.reset()
end

-- ============================ 4.6c · removed mid-spawn, then wanted again
do
    local env = syncEnv({})
    env.modelReady = false
    env.upsert(wirePayload('again', {
        kind = 'prop', model = 'prop_barrel_01',
        coords = { x = 1.0, y = 0.0, z = 0.0 }, networked = false,
    }))
    local co = coroutine.create(env.threads[#env.threads])
    coroutine.resume(co)
    -- Removed while the model loads, and wanted again at a new place.
    env.remove(wireKeyOf('again'))
    env.upsert(wirePayload('again', {
        kind = 'prop', model = 'prop_barrel_01',
        coords = { x = 7.0, y = 0.0, z = 0.0 }, networked = false,
    }))
    env.modelReady = true
    for _ = 1, 6 do
        if coroutine.status(co) == 'dead' then break end
        coroutine.resume(co)
    end
    local handle = env.EXPORTS.GetSyncedEntity(wireKeyOf('again'))
    check(handle ~= nil,
        '4.6c: a record removed and re-sent during a model load is spawned, not dropped')
    local alive = 0
    for _ in pairs(env.alive) do alive = alive + 1 end
    check(alive == 1, ('4.6c: and exactly one entity exists (%d)'):format(alive))
    env.reset()
end

-- ============================ 4.6d · a spawn that raises costs only itself
do
    local env = syncEnv({})
    local realCreate = CreateObject
    local raiseOnce = true
    CreateObject = function(...)
        if raiseOnce then
            raiseOnce = false
            error('native exploded')
        end
        return realCreate(...)
    end
    local ok = pcall(env.upsert, wirePayload('boom', {
        kind = 'prop', model = 'prop_barrel_01',
        coords = { x = 0.0, y = 0.0, z = 0.0 }, networked = false,
    }))
    check(ok, '4.6d: a raising spawn does not escape the net handler')
    env.upsert(wirePayload('boom', {
        kind = 'prop', model = 'prop_barrel_01',
        coords = { x = 2.0, y = 0.0, z = 0.0 }, networked = false,
    }))
    check(env.EXPORTS.GetSyncedEntity(wireKeyOf('boom')) ~= nil,
        '4.6d: and the next state for that id still spawns (it is not stuck "spawning")')

    -- In one batch, a bad record does not cost the good one after it.
    raiseOnce = true
    env.batch(100, {
        wirePayload('first', { kind = 'prop', model = 'prop_barrel_01',
            coords = { x = 0.0, y = 0.0, z = 0.0 }, networked = false }),
        wirePayload('second', { kind = 'prop', model = 'prop_barrel_01',
            coords = { x = 3.0, y = 0.0, z = 0.0 }, networked = false }),
    }, {})
    check(env.EXPORTS.GetSyncedEntity(wireKeyOf('second')) ~= nil,
        '4.6d: a record that raises does not take the rest of its batch with it')
    CreateObject = realCreate
    env.reset()
end

-- ============================ 4.6e · batches apply in the order they were SENT
--
-- A large batch goes latent and a small one reliable, so a later batch can arrive
-- first. A remove that overtook an older upsert must not be undone by it.
do
    local env = syncEnv({})
    env.batch(6, {}, { wireKeyOf('late') })
    env.batch(5, { wirePayload('late', {
        kind = 'prop', model = 'prop_barrel_01',
        coords = { x = 0.0, y = 0.0, z = 0.0 }, networked = false,
    }) }, {})
    check(env.EXPORTS.GetSyncedEntity(wireKeyOf('late')) == nil,
        '4.6e: an upsert from an EARLIER batch arriving after a remove is ignored')
    env.batch(7, { wirePayload('late', {
        kind = 'prop', model = 'prop_barrel_01',
        coords = { x = 0.0, y = 0.0, z = 0.0 }, networked = false,
    }) }, {})
    check(env.EXPORTS.GetSyncedEntity(wireKeyOf('late')) ~= nil,
        '4.6e: and a LATER one is applied')

    -- A networked record on this wire is refused: clients never create one.
    env.batch(8, { wirePayload('net', {
        kind = 'prop', model = 'prop_barrel_01',
        coords = { x = 0.0, y = 0.0, z = 0.0 }, networked = true, netId = 77,
    }) }, {})
    local networkedCreates = 0
    for _, n in ipairs(env.natives) do
        if (n.name == 'CreateObject' or n.name == 'CreateVehicle') and n.networked ~= false then
            networkedCreates = networkedCreates + 1
        end
    end
    check(env.EXPORTS.GetSyncedEntity(wireKeyOf('net')) == nil and networkedCreates == 0,
        '4.6e: a client never creates a networked entity, whatever the payload says')
    env.reset()
end

-- ============================ 4.6g · a batch comes from the server or not at all
--
-- `cis_libs:client:syncBatch` is a net event, and a net event is also reachable
-- by a local TriggerEvent from any client resource. Unchecked, one line deleted
-- a synced ped and pinned its key above every later batch:
--     TriggerEvent('cis_libs:client:syncBatch', 1e12, nil, { key })
do
    local env = syncEnv({})
    local shop = wirePayload('shop_ped', {
        kind = 'prop', model = 'prop_barrel_01',
        coords = { x = 0.0, y = 0.0, z = 0.0 }, networked = false,
    })
    env.batch(1, { shop }, {})
    check(env.EXPORTS.GetSyncedEntity(wireKeyOf('shop_ped')) ~= nil,
        '4.6g: the real batch spawns the record')

    env.forge(1e12, nil, { wireKeyOf('shop_ped') })
    check(env.EXPORTS.GetSyncedEntity(wireKeyOf('shop_ped')) ~= nil,
        '4.6g: a forged local batch does not delete a synced entity')
    env.forge(2, { wirePayload('fake', {
        kind = 'prop', model = 'prop_barrel_01',
        coords = { x = 0.0, y = 0.0, z = 0.0 }, networked = false,
    }) }, {})
    check(env.EXPORTS.GetSyncedEntity(wireKeyOf('fake')) == nil,
        '4.6g: a forged local batch does not spawn anything')

    -- The number is bounded too: a batch number no server sends is refused, so
    -- it cannot pin a key above every real batch that follows.
    env.batch(1e12, {}, { wireKeyOf('shop_ped') })
    env.batch(2.5, {}, { wireKeyOf('shop_ped') })
    env.batch(0 / 0, {}, { wireKeyOf('shop_ped') })
    check(env.EXPORTS.GetSyncedEntity(wireKeyOf('shop_ped')) ~= nil,
        '4.6g: a huge, fractional or NaN batch number is refused')
    env.batch(2, {}, { wireKeyOf('shop_ped') })
    check(env.EXPORTS.GetSyncedEntity(wireKeyOf('shop_ped')) == nil,
        '4.6g: and the next real batch still applies')
    env.reset()
end

-- ============================ 4.6f · networked records through their state bag
do
    local env = syncEnv({})
    env.save('SetEntityInvincible')
    env.save('SetVehicleProperties')
    local invincible, props = {}, {}
    function SetEntityInvincible(e, on) invincible[#invincible + 1] = { e, on } end
    function SetVehicleProperties(e, p) props[#props + 1] = { e, p } end
    local spawned, despawned = {}, {}
    env.EXPORTS.AddSyncSpawnHandler(function(key, record, entity) spawned[#spawned + 1] = entity end)
    env.EXPORTS.AddSyncDespawnHandler(function(key) despawned[#despawned + 1] = key end)

    env.alive[901] = true
    local owner = 7
    function NetworkGetEntityOwner() return owner end
    function PlayerId() return 3 end
    env.bagWatch.fn(901, { key = wireKeyOf('car'), id = 'car', kind = 'vehicle', rev = 4,
        invincible = true, props = { plate = 'X' } }, true, false)
    check(#spawned == 1 and spawned[1] == 901, '4.6f: the bag resolves to the entity and fires onSpawn')
    check(#invincible == 0 and #props == 0,
        '4.6f: a client that does not OWN the entity applies nothing')

    -- Ownership migrates here: the monitor applies the metadata once. The
    -- monitor is a loop; it is stepped one Wait at a time.
    env.save('Wait')
    Wait = function() coroutine.yield() end
    local co = coroutine.create(env.threads[#env.threads])
    coroutine.resume(co)
    owner = 3
    coroutine.resume(co)
    coroutine.resume(co)
    check(#invincible == 1 and #props == 1 and props[1][2].plate == 'X',
        ('4.6f: the new owner applies the bag once (invincible %d, props %d)'):format(#invincible, #props))

    -- The entity streams out: tracked no more, and never deleted from here.
    env.alive[901] = nil
    coroutine.resume(co)
    check(#despawned == 1 and env.EXPORTS.GetSyncedEntity(wireKeyOf('car')) == nil,
        '4.6f: an entity that is gone is untracked and onDespawn fires')
    local deletes = 0
    for _, n in ipairs(env.natives) do
        if n.name == 'DeleteEntity' then deletes = deletes + 1 end
    end
    check(deletes == 0, '4.6f: and nothing is deleted: the entity was the server\'s')
    env.reset()
end

-- ============================ 4.6g · hooks from other resources, and their owners
do
    local env = syncEnv({ invoking = 'res_a' })
    local calls = 0
    local ref = setmetatable({ __cfx_functionReference = 'res_a:9' }, {
        __call = function() calls = calls + 1 end,
    })
    local ok = env.EXPORTS.AddSyncSpawnHandler(ref)
    local okD = env.EXPORTS.AddSyncDespawnHandler(ref)
    check(ok == true and okD == true,
        '4.6g: a hook passed from another resource (a funcref) is accepted')
    env.upsert(wirePayload('hooked', {
        kind = 'prop', model = 'prop_barrel_01',
        coords = { x = 0.0, y = 0.0, z = 0.0 }, networked = false,
    }))
    check(calls == 1, '4.6g: and called')
    env.fire('onResourceStop', 'res_a')
    env.remove(wireKeyOf('hooked'))
    env.upsert(wirePayload('hooked2', {
        kind = 'prop', model = 'prop_barrel_01',
        coords = { x = 0.0, y = 0.0, z = 0.0 }, networked = false,
    }))
    check(calls == 1, '4.6g: a hook is released when the resource that registered it stops')
    env.reset()
end

-- ============================ 4.9 · a malformed record is ignored AND NAMED
--
-- The client is the last thing between a bad payload and an entity in the
-- world. It already refused a record with no usable coords -- SILENTLY, which is
-- the wrong half: a silent refusal and a record that was never meant to arrive
-- look exactly the same from the console, so the person whose door never appears
-- has nothing to act on.
--
-- Every field the client relies on is checked, and a refusal says which one.
do
    -- Coords that are not a position.
    local env = syncEnv({})
    env.upsert(wirePayload('bad_coords', {
        kind = 'prop', model = 'prop_barrel_01',
        coords = 'somewhere over there', networked = false,
    }))
    local tracked = env.EXPORTS.GetSyncedEntities()
    check(tracked[wireKeyOf('bad_coords')] == nil,
        '4.9: a record with non-table coords is ignored')
    check(#env.logged >= 1,
        ('4.9: and it is logged rather than dropped in silence (%d lines)')
            :format(#env.logged))
    env.reset()
end

-- A model that is neither a name nor a hash is refused the same way, so a
-- consumer who ships a typo does not get a prop that silently never appears.
do
    local env = syncEnv({})
    env.upsert(wirePayload('bad_model', {
        kind = 'prop', model = { shape = 'not a model' },
        coords = { x = 0.0, y = 0.0, z = 0.0 }, networked = false,
    }))
    check(env.EXPORTS.GetSyncedEntities()[wireKeyOf('bad_model')] == nil,
        '4.9: a record whose model is neither string nor hash is ignored')
    check(#env.logged >= 1,
        ('4.9: and it is logged too (%d lines)'):format(#env.logged))
    env.reset()
end

-- AND A GOOD RECORD STILL WORKS. Three bad records above must not have left the
-- spawn path refusing everything.
do
    local env = syncEnv({})
    env.upsert(wirePayload('good', {
        kind = 'prop', model = 'prop_barrel_01',
        coords = { x = 0.0, y = 0.0, z = 0.0 }, networked = false,
    }))
    check(env.EXPORTS.GetSyncedEntities()[wireKeyOf('good')] ~= nil,
        '4.9: a valid record still spawns after the refusals')
    env.reset()
end

-- ================================== 4.10. the consumer-facing client surface
--
-- A consumer that syncs an entity can register one and never learn its handle,
-- because the handle is created on a spawn that happens up to five seconds
-- after the request -- during a model load, on a thread the caller does not own.
-- `Cis.sync.entity(key)` is the read side of that: the caller holds the KEY it
-- passed in, and can ask what the entity is whenever it needs to.
do
    local env = syncEnv({})
    env.upsert(wirePayload('one', {
        kind = 'prop', model = 'prop_barrel_01',
        coords = { x = 0.0, y = 0.0, z = 0.0 }, networked = false,
    }))
    local key = wireKeyOf('one')
    local handle = env.EXPORTS.GetSyncedEntity(key)
    check(type(handle) == 'number' and handle ~= 0,
        ('4.10: entity(key) answers the handle of a spawned record (got %s)')
            :format(tostring(handle)))
    check(env.EXPORTS.GetSyncedEntity('no-such-key') == nil,
        '4.10: and nil for a key this client holds nothing for')
    -- A key is the CALLER'S id namespaced by owner. Asking with the bare id must
    -- not find it, or `Cis.sync.entity('door1')` would resolve against every
    -- resource's door1 and hand back a handle that is not the caller's.
    check(env.EXPORTS.GetSyncedEntity('one') == nil,
        '4.10: the bare id does not resolve -- the key is the identity, not the id')
    check(env.EXPORTS.GetSyncedEntity(nil) == nil,
        '4.10: and a nil key answers nil rather than raising')
    env.reset()
end

-- THE HOOKS. A consumer that has to attach something to a synced entity --
-- a marker, a blip, a zone link -- has nothing to attach to at the moment it
-- asks, and polling is the alternative. These fire under pcall, and the reason
-- they MUST is not politeness: a consumer hook raises inside the sync path, and
-- an unprotected hook takes the client's despawn with it.
do
    local env = syncEnv({})
    local spawned, despawned = {}, {}
    env.EXPORTS.AddSyncSpawnHandler(function(key, record, entity)
        spawned[#spawned + 1] = { key = key, id = record and record.id, record = record, entity = entity }
    end)
    env.EXPORTS.AddSyncDespawnHandler(function(key)
        despawned[#despawned + 1] = key
    end)

    env.upsert(wirePayload('one', {
        kind = 'prop', model = 'prop_barrel_01',
        coords = { x = 0.0, y = 0.0, z = 0.0 }, networked = false,
        clientData = { label = 'shop-door' },
    }))
    check(#spawned == 1,
        ('4.10: onSpawn fires once when a record spawns (got %d)'):format(#spawned))
    -- Asserted on `clientData`, which is what a consumer actually reads, rather
    -- than on `record.id`. It is NOT the caller's own id on this side: the
    -- upsert handler rebinds `record.id` to the namespaced `key` for the whole
    -- file, so a hook asserting the caller's id would be asserting a field that
    -- no longer exists by the time anything can see it.
    check(spawned[1] and spawned[1].record
            and spawned[1].record.clientData
            and spawned[1].record.clientData.label == 'shop-door',
        '4.10: and it carries the record, so a consumer can read clientData')
    check(spawned[1] and spawned[1].id == spawned[1].key,
        '4.10: and the record it carries is keyed by the same key it was given')
    check(type(spawned[1] and spawned[1].entity) == 'number',
        '4.10: and the live handle, which is the whole reason to be called')

    local key = wireKeyOf('one')
    env.remove(key)
    check(#despawned == 1 and despawned[1] == key,
        '4.10: onDespawn fires with the same key when the record is removed')

    -- AND NOT FOR A RECORD THAT WAS NEVER THERE. A remove for a key this client
    -- does not hold is routine -- it walks out of range, comes back, and the
    -- server forgets it in between -- and firing the hook for it would tell a
    -- consumer to clean up an entity it never had.
    env.remove('never-existed')
    check(#despawned == 1,
        ('4.10: onDespawn does NOT fire for a key that was never spawned (got %d)')
            :format(#despawned))
    env.reset()
end

-- THE PCALL, AND IT IS THE POINT. Each hook is run on its own so one raising
-- consumer cannot stop the next, and a raise is named rather than swallowed --
-- a hook that fails silently is indistinguishable from one that never ran.
do
    local env = syncEnv({})
    env.EXPORTS.AddSyncSpawnHandler(function() error('spawn hook exploded') end)
    local second = 0
    env.EXPORTS.AddSyncSpawnHandler(function() second = second + 1 end)

    env.upsert(wirePayload('one', {
        kind = 'prop', model = 'prop_barrel_01',
        coords = { x = 0.0, y = 0.0, z = 0.0 }, networked = false,
    }))
    check(env.EXPORTS.GetSyncedEntity(wireKeyOf('one')) ~= nil,
        '4.10: a raising onSpawn hook does NOT stop the entity from spawning')
    check(second == 1,
        ('4.10: and the next hook still runs (got %d)'):format(second))
    local named = false
    for _, l in ipairs(env.logged) do
        if tostring(l[2]):find('spawn hook exploded', 1, true) ~= nil then named = true end
    end
    check(named, '4.10: and the failure is logged with the error text in it')
    env.reset()
end

-- Same for despawn, and this one is the more dangerous of the two: the hook
-- runs on the path that deletes the entity, so an unprotected raise there
-- strands a client-local prop in the world with nothing left to remove it.
do
    local env = syncEnv({})
    env.EXPORTS.AddSyncDespawnHandler(function() error('despawn hook exploded') end)
    env.upsert(wirePayload('one', {
        kind = 'prop', model = 'prop_barrel_01',
        coords = { x = 0.0, y = 0.0, z = 0.0 }, networked = false,
    }))
    local key = wireKeyOf('one')
    local handle = env.EXPORTS.GetSyncedEntity(key)
    env.remove(key)
    check(env.EXPORTS.GetSyncedEntity(key) == nil,
        '4.10: a raising onDespawn hook does NOT stop the entity being dropped')
    local deleted = false
    for _, e in ipairs(env.natives) do
        if e.name == 'DeleteEntity' and e.handle == handle then deleted = true end
    end
    check(deleted, '4.10: and the entity really was deleted')
    env.reset()
end

-- A hook that is not a function is refused rather than stored. Stored, it is a
-- nil call on the spawn path, which is exactly the raise the pcall above exists
-- to contain -- one step later and with no name attached.
do
    local env = syncEnv({})
    local okSpawn, whySpawn = env.EXPORTS.AddSyncSpawnHandler('not a function')
    local okDespawn, whyDespawn = env.EXPORTS.AddSyncDespawnHandler(nil)
    check(okSpawn == false, '4.10: registering a spawn hook that is not a function is refused')
    check(okDespawn == false, '4.10: and the same for a despawn hook')
    check(type(whySpawn) == 'string' and type(whyDespawn) == 'string',
        '4.10: both refusals say why')
    -- And a refused registration leaves nothing behind that a later spawn trips.
    env.upsert(wirePayload('one', {
        kind = 'prop', model = 'prop_barrel_01',
        coords = { x = 0.0, y = 0.0, z = 0.0 }, networked = false,
    }))
    check(env.EXPORTS.GetSyncedEntity(wireKeyOf('one')) ~= nil,
        '4.10: a refused hook does not poison the spawn path')
    env.reset()
end

-- ====================================================== 4.10. the realm refusals
--
-- `Cis.sync.*` is written for both realms, but every mutating call in it is a
-- SERVER export: the server owns the record table, and there is no client-side
-- table for a create to write to. Calling one from a client used to reach
-- `exports['cis_libs'].SyncCreate`, which is not there, and raise
-- "attempt to call a nil value" from inside a consumer's thread.
--
-- A raise is the wrong answer for two reasons. It takes the CALLER's thread
-- down, so a consumer's own cleanup never runs; and it names no fix, so the
-- report is "cis_libs is broken" rather than "you called a server-only
-- function on the client". `false, 'server only'` is a value the caller can
-- test and a message that says what happened.
--
-- Run on the SERVER too, in the same suite, because the refusals must be scoped
-- to the client: a server-side guard that fired on the server would make the
-- whole feature unreachable.
do
    local env = syncEnv({})
    -- Load init.lua against an exports table that has NO sync exports on it,
    -- which is exactly the client's situation: the server half of the file is
    -- not in this Lua state at all, so `exports['cis_libs'].SyncCreate` is nil
    -- and calling it raises.
    --
    -- The stub is modelled on the real shape -- `exports[resource]` is a TABLE
    -- of functions, not a function. A stub that answered the index with a
    -- function fails one line earlier, in init.lua, and the assertion below
    -- never runs -- so it would look like a library defect rather than the
    -- realm defect it is meant to be.
    local savedExports = exports
    local reached = {}
    local inner = setmetatable({}, {
        __index = function(_, name)
            reached[#reached + 1] = name
            return nil
        end,
    })
    exports = setmetatable({}, {
        __index = function(_, name)
            if name == 'cis_libs' then return inner end
            return nil
        end,
        __call = function() end,
    })
    local savedDup = IsDuplicityVersion
    IsDuplicityVersion = function() return false end
    local savedCis = rawget(_ENV, 'Cis')
    Cis = nil
    assert(loadfile('./init.lua'))()
    -- The reference is taken BEFORE the global is put back: restoring first and
    -- then reading `Cis` reads whatever this suite had before, which is nil.
    local clientCis = Cis
    exports = savedExports
    IsDuplicityVersion = savedDup
    rawset(_ENV, 'Cis', savedCis)

    for _, name in ipairs({ 'ped', 'prop', 'vehicle', 'remove' }) do
        -- Under PCALL ON PURPOSE. Before the fix this call RAISES -- that is
        -- the defect -- and an unguarded call would take the whole suite down
        -- with it, which reports as a crash rather than as the failing
        -- assertion it is. Captured, a raise is a value: the check below fails,
        -- the rest of the suite still runs, and the message says what happened.
        local ok, a, b = pcall(clientCis.sync[name], { id = 'x' })
        check(ok,
            ('4.10: Cis.sync.%s does not RAISE on the client (it raised: %s)')
                :format(name, tostring(a)))
        check(a == false,
            ('4.10: Cis.sync.%s answers false on the client (got %s)')
                :format(name, tostring(a)))
        check(b == 'server only',
            ('4.10: and the reason is "server only" for %s (got %s)')
                :format(name, tostring(b)))
    end
    check(#reached == 0,
        ('4.10: a refused call does not reach the exports boundary at all (%d looked up)')
            :format(#reached))
    env.reset()
end

-- The new client-only half is the mirror image: calling THOSE on the server is
-- the refusal, not a nil index. A server that asked for an entity handle has no
-- such table, because the server never holds client entities.
do
    local savedExports = exports
    local inner = setmetatable({}, { __index = function() return nil end })
    exports = setmetatable({}, {
        __index = function(_, name)
            if name == 'cis_libs' then return inner end
            return nil
        end,
        __call = function() end,
    })
    local savedDup = IsDuplicityVersion
    IsDuplicityVersion = function() return true end
    local savedCis = rawget(_ENV, 'Cis')
    Cis = nil
    assert(loadfile('./init.lua'))()
    local serverCis = Cis
    exports = savedExports
    IsDuplicityVersion = savedDup
    rawset(_ENV, 'Cis', savedCis)

    local okEntityCall, okEntity, whyEntity = pcall(serverCis.sync.entity, 'any-key')
    local okSpawnCall, okSpawn = pcall(serverCis.sync.onSpawn, function() end)
    local okDespawnCall, okDespawn = pcall(serverCis.sync.onDespawn, function() end)

    check(okEntityCall and okSpawnCall and okDespawnCall,
        '4.10: the client-only sync calls do not RAISE on the server')
    check(okEntity == false, '4.10: Cis.sync.entity answers false on the server')
    check(whyEntity == 'server only',
        ('4.10: and says so (got %s)'):format(tostring(whyEntity)))
    check(okSpawn == false, '4.10: Cis.sync.onSpawn answers false on the server')
    check(okDespawn == false, '4.10: Cis.sync.onDespawn answers false on the server')
end

-- ===================================================== 7.1 Cis.points
--
-- A point is a radius around one coordinate, and the two things that make it
-- worth having over a tiny box zone are the two things that can go wrong: a
-- point created around a STANDING player, and a player who pauses ON the
-- boundary. Both are invisible to a test that walks cleanly across an edge, so
-- both are tested here explicitly.
--
-- The environment mirrors zoneEnv because points and zones need the same shared
-- modules, and a test that built its own stubs would be testing the stubs.
local function pointEnv()
    local env = newEnv({})
    env.coords = { x = 0.0, y = 0.0, z = 0.0 }
    -- A REAL vector3, for the same reason as the zone harness: client/points.lua
    -- does `#(coords - lastPos)` to decide half-cell movement, and both
    -- operators are Cfx natives on the real type.
    local Vec = {}
    Vec.__index = Vec
    Vec.__sub = function(a, b) return vector3(a.x - b.x, a.y - b.y, a.z - b.z) end
    Vec.__len = function(v) return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z) end
    function vector3(x, y, z) return setmetatable({ x = x, y = y, z = z }, Vec) end
    env.save('CisReadyState')
    CisReadyState = { wait = function() return true end, ready = true }
    env.save('Cis')
    env.save('vector3')
    Cis = Cis or {}
    Cis.player = Cis.player or {}
    -- THE PLAYER DOES NOT MOVE unless a test moves them. That is the whole
    -- point: every "standing still" assertion depends on it, and a harness that
    -- drifted the player a little per pass would make all of them vacuous.
    Cis.player.coords = function() return vector3(env.coords.x, env.coords.y, env.coords.z) end
    local threads = {}
    function CreateThread(fn) threads[#threads + 1] = fn end
    env.threads = threads
    loadModule('client/points.lua')
    return env
end

-- Move the player and run the pass ONCE.
--
-- One call, not a simulated second: the acceptance is about a single crossing
-- producing exactly one enter and one exit, and a loop that ran 200 wakeups
-- would make an off-by-one in the transition count invisible inside a count of
-- transitions.
--
-- THE CLOCK ADVANCES ON EVERY WAKEUP, and the first version of this did not --
-- which made six assertions fail for a reason that had nothing to do with the
-- pass. `recheck` is reached only once RECHECK_MS have elapsed on
-- `GetGameTimer()`, and with a frozen clock that branch is never taken, so a
-- point the player steps away from is never re-tested. The failures looked like
-- a broken exit path; the exit path was fine and the harness was standing still
-- in a way the player is not.
local POINT_PASS_DONE = {}
local function pointPass(env, advanceMs)
    local tick = env.threads[1]
    if not tick then
        return nil, 'client/points.lua started no thread'
    end
    -- ONE PASS, then out through a private sentinel at the pass's Wait. The thread
    -- is a `while true` loop; this harness used to rely on it returning after one
    -- Wait, which is exactly the defect (the loop ran once and died) it hid.
    -- The clock moves at least RECHECK_MS (200) so the next pass is a later pass.
    local realWait = Wait
    local waited = 0
    Wait = function(ms)
        waited = waited + 1
        env.clock = env.clock + math.max(tonumber(ms) or 0, advanceMs or 200)
        error(POINT_PASS_DONE, 0)
    end
    local ok, err = pcall(tick)
    Wait = realWait
    if not ok and err ~= POINT_PASS_DONE then
        return nil, tostring(err)
    end
    return waited
end

do
    local env = pointEnv()
    local log = { enter = 0, exit = 0, nearby = 0, events = {} }

    -- A point created around a player who is ALREADY STANDING ON IT. This is
    -- the shape: discovery gated on movement finds a standing player never,
    -- and the symptom is a point that registered successfully and then never
    -- fired for the resource that registered it.
    local id = exports.CreatePoint({
        coords = { x = 0.0, y = 0.0, z = 0.0 },
        distance = 5.0,
        onEnter = function() log.enter = log.enter + 1 end,
        onExit = function() log.exit = log.exit + 1 end,
        nearby = function() log.nearby = log.nearby + 1 end,
    })
    check(type(id) == 'number' and id > 0, ('7.1: add returns a numeric id (got %s)'):format(tostring(id)))

    local ran, why = pointPass(env)
    check(ran ~= nil, ('7.1: the pass ran (%s)'):format(tostring(why)))
    check(log.enter == 1,
        ('7.1: a point created around a STANDING player fires onEnter exactly once (got %d)')
            :format(log.enter))
    check(log.nearby >= 1,
        ('7.1: nearby runs while inside (got %d)'):format(log.nearby))

    -- HYSTERESIS. 5.0 * 1.15 + 0.5 is the exit radius, so 5.4 m is still INSIDE
    -- the band and must not fire onExit -- and 6.0 m is past it and must.
    env.coords = { x = 5.4, y = 0.0, z = 0.0 }
    pointPass(env)
    check(log.exit == 0,
        ('7.1: 5.4m on a 5m point is inside the hysteresis band and does NOT exit (exit=%d)')
            :format(log.exit))
    check(log.nearby >= 2,
        ('7.1: nearby still runs inside the band (got %d)'):format(log.nearby))

    env.coords = { x = 6.0, y = 0.0, z = 0.0 }
    pointPass(env)
    check(log.exit == 1,
        ('7.1: 6.0m is past the exit radius and fires onExit exactly once (exit=%d)')
            :format(log.exit))

    -- AND IT COMES BACK, once, not once per pass.
    env.coords = { x = 0.0, y = 0.0, z = 0.0 }
    pointPass(env)
    pointPass(env)
    pointPass(env)
    check(log.enter == 2,
        ('7.1: re-entering fires onEnter once more and STAYS entered across further passes (enter=%d)')
            :format(log.enter))
    check(log.exit == 1, ('7.1: no further exits while standing inside (exit=%d)'):format(log.exit))

    -- The nearby count must not have grown while OUTSIDE, which is the other
    -- half of "runs only inside".
    local nearbyOutside = log.nearby
    env.coords = { x = 200.0, y = 0.0, z = 0.0 }
    pointPass(env)
    check(log.nearby == nearbyOutside,
        ('7.1: nearby does NOT run once outside (before=%d after=%d)')
            :format(nearbyOutside, log.nearby))

    -- remove() fires onExit for a player who was inside, with the PLAYER's
    -- coordinates and not the point's. The zone harness has a comment about
    -- this being the one case that was guaranteed to be wrong.
    env.coords = { x = 0.0, y = 0.0, z = 0.0 }
    pointPass(env)
    local exitCoords
    local id2 = exports.CreatePoint({
        coords = { x = 500.0, y = 0.0, z = 0.0 },
        distance = 4.0,
        onEnter = function() end,
        onExit = function(c) exitCoords = c end,
    })
    env.coords = { x = 500.0, y = 0.0, z = 0.0 }
    pointPass(env)
    exitCoords = nil
    check(exports.RemovePoint(id2) == true, '7.1: remove answers true for a live id')
    check(exitCoords ~= nil and math.abs(exitCoords.x - 500.0) < 0.001,
        '7.1: remove fires onExit with the player coordinates')

    check(exports.RemovePoint(id2) == false, '7.1: removing an id twice is false, not an error')
    check(exports.RemovePoint(999999) == false, '7.1: removing an id nobody holds is false')

    env.reset()
end

-- The refusals. Each one is a distinct mistake, and each has to say what to do
-- rather than returning a bare false a caller cannot act on.
do
    local env = pointEnv()
    local function whyOf(...)
        local ok, reason = exports.CreatePoint(...)
        return ok, reason
    end

    local ok1, why1 = whyOf({ coords = { x = 0, y = 0, z = 0 } })
    -- The word looked for is one the harness does not rewrite. The message names
    -- the key in backticks, and the harness turns every backtick literal into
    -- 0x11111111 -- so asserting on the key itself would test the harness's
    -- substitution rather than the refusal.
    check(ok1 == false and type(why1) == 'string' and why1:find('radius'),
        ('7.1: a point with no distance is refused, and says why (got %s)'):format(tostring(why1)))

    local ok2, why2 = whyOf({ coords = { x = 0, y = 0, z = 0 }, distance = 0 })
    check(ok2 == false and type(why2) == 'string',
        ('7.1: a zero distance is refused (got %s)'):format(tostring(why2)))

    -- A POINT THE INDEX REFUSES IS NOT ADDED. The grid's refusal was ignored, so
    -- a radius it cannot hold, or NaN coords, still got an id: getClosest found
    -- the point and onEnter never fired.
    local okBig, whyBig = whyOf({ coords = { x = 0, y = 0, z = 0 }, distance = 5000 })
    check(okBig == false and tostring(whyBig):find('indexed', 1, true) ~= nil,
        ('7.1: a radius the index cannot hold is refused (got %s, %s)'):format(tostring(okBig), tostring(whyBig)))
    local okNan = whyOf({ coords = { x = 0 / 0, y = 0, z = 0 }, distance = 5 })
    check(okNan == false, '7.1: and so are NaN coords')
    -- Infinite or absurd coords froze the game thread inside the export: the
    -- grid walked a float loop that never ends. The hook makes a hang a failure.
    for _, c in ipairs({ { 'x = inf', math.huge, 0 }, { 'x = 1e21', 1e21, 0 }, { 'y = -inf', 0, -math.huge } }) do
        debug.sethook(function() error('HUNG', 0) end, '', 2000000)
        local okCall, okInf, whyInf = pcall(whyOf, { coords = { x = c[2], y = c[3], z = 0 }, distance = 2 })
        debug.sethook()
        check(okCall and okInf == false and type(whyInf) == 'string',
            ('7.1: a point at %s is refused with a reason, not a hang (%s, %s)'):format(c[1], tostring(okInf), tostring(whyInf)))
    end
    check(exports.GetClosestPoint() == nil, '7.1: neither left a point behind for getClosest')

    -- NaN IS TRUTHY. `if distance ~= distance` is the NaN test; `if not
    -- distance` is not, and a NaN radius makes every containment test false --
    -- a point that registers and then silently never fires.
    local ok3, why3 = whyOf({ coords = { x = 0, y = 0, z = 0 }, distance = 0 / 0 })
    check(ok3 == false and tostring(why3):find('NaN'),
        ('7.1: a NaN distance is refused and says so (got %s)'):format(tostring(why3)))

    local ok4, why4 = whyOf({ coords = { x = 0, y = 0, z = 0 }, distance = math.huge })
    check(ok4 == false and type(why4) == 'string',
        ('7.1: an infinite distance is refused (got %s)'):format(tostring(why4)))

    local ok5, why5 = whyOf(nil)
    check(ok5 == false and type(why5) == 'string',
        ('7.1: a nil options table is refused (got %s)'):format(tostring(why5)))

    local ok6, why6 = whyOf({ distance = 5 })
    check(ok6 == false and type(why6) == 'string',
        ('7.1: missing coords is refused (got %s)'):format(tostring(why6)))

    -- EVERY refusal names its own fix.
    check(type(why1) == 'string' and #why1 > 10,
        '7.1: a refusal carries a sentence, not a token')

    env.reset()
end

-- getClosest answers an id AND a distance, and says why when there is nothing.
do
    local env = pointEnv()
    local none, whyNone = exports.GetClosestPoint()
    check(none == nil and type(whyNone) == 'string' and whyNone:find('no points'),
        ('7.1: getClosest with nothing registered says so (got %s, %s)'):format(tostring(none), tostring(whyNone)))

    local a = exports.CreatePoint({ coords = { x = 0, y = 0, z = 0 }, distance = 5 })
    local b = exports.CreatePoint({ coords = { x = 30, y = 0, z = 0 }, distance = 5 })
    check(b > a, ('7.1: ids are monotonic (a=%s b=%s)'):format(tostring(a), tostring(b)))

    env.coords = { x = 28.0, y = 0.0, z = 0.0 }
    local best, distance = exports.GetClosestPoint()
    check(best == b, ('7.1: getClosest picks the nearest point (got %s, wanted %s)'):format(tostring(best), tostring(b)))
    check(type(distance) == 'number' and math.abs(distance - 2.0) < 0.001,
        ('7.1: getClosest answers the distance in metres (got %s)'):format(tostring(distance)))

    -- THE CALLER'S POINTS ONLY, as GetAllPoints: the set is shared, and the
    -- nearest point of another resource is not this resource's business.
    env.invoking = 'shop'
    local mine = exports.CreatePoint({ coords = { x = 100, y = 0, z = 0 }, distance = 5 })
    local shopBest = exports.GetClosestPoint()
    check(shopBest == mine, ('7.1: getClosest answers the caller\'s own nearest point (got %s, wanted %s)')
        :format(tostring(shopBest), tostring(mine)))
    env.invoking = 'bank'
    local noneOwn, whyOwn = exports.GetClosestPoint()
    check(noneOwn == nil and tostring(whyOwn):find('bank', 1, true) ~= nil,
        ('7.1: a resource with no points is told so by name (got %s, %s)'):format(tostring(noneOwn), tostring(whyOwn)))
    env.invoking = nil
    check(exports.GetClosestPoint() == b, '7.1: cis_libs still sees every point')

    -- A player position with no z is refused, not raised in the subtraction.
    env.coords = { x = 28.0, y = 0.0 }
    local okZ, idZ, whyZ = pcall(exports.GetClosestPoint)
    check(okZ and idZ == nil and tostring(whyZ):find('x/y/z', 1, true) ~= nil,
        ('7.1: coords with no z are refused with a reason (%s, %s)'):format(tostring(idZ), tostring(whyZ)))

    env.reset()
end

-- A consumer callback that raises must not end the pass. A pass that dies takes
-- every OTHER point with it, and the symptom is a set of points that stop
-- firing for a reason that appears minutes later.
do
    local env = pointEnv()
    local after = 0
    local bad = exports.CreatePoint({
        coords = { x = 0, y = 0, z = 0 },
        distance = 5,
        onEnter = function() error('consumer bug') end,
    })
    local good = exports.CreatePoint({
        coords = { x = 0, y = 0, z = 0 },
        distance = 5,
        onEnter = function() after = after + 1 end,
    })
    local ran, why = pointPass(env)
    check(ran ~= nil, ('7.1: a raising callback does not end the pass (%s)'):format(tostring(why)))
    check(after == 1,
        ('7.1: a point registered after the raising one still fires (got %d)'):format(after))
    -- Both ids are real and both are removable, which is the assertion: a pass
    -- that died on the first callback would leave the registry inconsistent, and
    -- an id that refuses to remove is how that shows.
    check(exports.RemovePoint(bad) == true and exports.RemovePoint(good) == true,
        '7.1: both points are removable after one of their callbacks raised')
    -- The loop-error COUNTER is deliberately not asserted here. Reading it means
    -- calling CisDiagnostics.Collect, which calls collectgarbage, and fengari
    -- does not implement lua_gc -- the suite dies on a harness limitation with a
    -- message that names neither the callback nor the pass. The assertion that
    -- matters is the one above: the pass survived, and the point registered after
    -- the raising one still fired.

    env.reset()
end

-- Ownership: a point must not outlive the resource that made it.
do
    local env = pointEnv()
    env.save('GetInvokingResource')
    GetInvokingResource = function() return 'my_resource' end
    local id = exports.CreatePoint({ coords = { x = 0, y = 0, z = 0 }, distance = 5 })
    GetInvokingResource = function() return nil end
    check(exports.RemovePoint(id) == true,
        '7.1: the point was registered under the calling resource, and the ledger did not lose it')
    -- GetPointsDebug exists so a harness can tell "the pass found nothing" from
    -- "no point was ever registered". The two look identical from the outside,
    -- which is the same ambiguity the zone harness reports through insideNames.
    local dbg = exports.GetPointsDebug()
    check(type(dbg) == 'table' and dbg.insideCount == 0,
        ('7.1: the debug record reports nothing inside after the only point was removed (got %s)')
            :format(tostring(dbg and dbg.insideCount)))
    env.reset()
end

-- THE PASS IS A LOOP. The thread called `Wait(tick())` once and fell off the
-- end, so the first pass was the only pass: a point the player walked into on
-- the second pass or later never fired. Driven here for several wakeups of ONE
-- thread, with the player arriving only after the first.
do
    local env = pointEnv()
    local entered = 0
    exports.CreatePoint({
        coords = { x = 50.0, y = 0.0, z = 0.0 }, distance = 3.0,
        onEnter = function() entered = entered + 1 end,
    })
    env.coords = { x = 0.0, y = 0.0, z = 0.0 }
    local SENT = {}
    local waits = 0
    local realWait = Wait
    Wait = function(ms)
        waits = waits + 1
        env.clock = env.clock + math.max(tonumber(ms) or 0, 1)
        if waits == 2 then env.coords = { x = 50.0, y = 0.0, z = 0.0 } end
        if waits >= 6 then error(SENT, 0) end
    end
    local ok, err = pcall(env.threads[1])
    Wait = realWait
    check((ok or err == SENT) and waits >= 6,
        ('7.1: the points thread keeps looping after its first pass (waits=%d, err=%s)')
            :format(waits, tostring(not ok and err ~= SENT and err or nil)))
    check(entered == 1,
        ('7.1: a player who arrives AFTER the first pass is found (onEnter=%d)'):format(entered))
    env.reset()
end

-- A HANDLER FROM ANOTHER RESOURCE IS A FUNCREF TABLE, and it must fire.
do
    local env = pointEnv()
    local fired = { enter = 0, nearby = 0, exit = 0 }
    exports.CreatePoint({
        coords = { x = 0.0, y = 0.0, z = 0.0 }, distance = 5.0,
        onEnter = funcref(function() fired.enter = fired.enter + 1 end),
        nearby = funcref(function() fired.nearby = fired.nearby + 1 end),
        onExit = funcref(function() fired.exit = fired.exit + 1 end),
    })
    pointPass(env)
    env.coords = { x = 100.0, y = 0.0, z = 0.0 }
    pointPass(env)
    check(fired.enter == 1 and fired.nearby >= 1 and fired.exit == 1,
        ('7.1: funcref onEnter/nearby/onExit all fire (enter=%d nearby=%d exit=%d)')
            :format(fired.enter, fired.nearby, fired.exit))
    env.reset()
end

-- `nearbyEvent` WAS ACCEPTED AND NEVER FIRED. It is the only way a server-side
-- consumer can observe a point it is standing in, and it is clamped to 250 ms
-- for the reason zone `insideEvent` is: it is a server event.
do
    local env = pointEnv()
    exports.CreatePoint({
        coords = { x = 0.0, y = 0.0, z = 0.0 }, distance = 5.0,
        nearbyEvent = 'my_res:nearPoint', nearbyInterval = 0,
    })
    -- One second of the real loop.
    local SENT = {}
    local realWait = Wait
    Wait = function(ms)
        env.clock = env.clock + math.max(tonumber(ms) or 0, 1)
        if env.clock >= 1000 then error(SENT, 0) end
    end
    local ok, err = pcall(env.threads[1])
    Wait = realWait
    if not ok and err ~= SENT then error(err, 0) end
    local fired = #env.serverEventsOf('my_res:nearPoint')
    check(fired >= 1, ('7.1: nearbyEvent fires as a server event while inside (fired=%d)'):format(fired))
    check(fired <= 5, ('7.1: nearbyEvent is clamped to 250 ms, not per frame (fired=%d in 1s)'):format(fired))
    local ev = env.serverEventsOf('my_res:nearPoint')[1]
    check(ev and type(ev.args[1]) == 'number',
        '7.1: nearbyEvent carries the point id first, like the enter/exit events')
    env.reset()
end

-- THE STOP SWEEP RELEASES THE STOPPING RESOURCE'S POINTS -- AND ONLY THOSE.
-- `for id in ipairs(freed)` walked positions 1..n: stopping a resource that held
-- one point deleted point #1, whoever owned it, and left its own point alive.
do
    local env = pointEnv()
    env.save('GetInvokingResource')
    GetInvokingResource = function() return nil end
    local mine = exports.CreatePoint({ coords = { x = 0, y = 0, z = 0 }, distance = 5 })
    GetInvokingResource = function() return 'res_b' end
    local theirs = exports.CreatePoint({ coords = { x = 9, y = 0, z = 0 }, distance = 5 })
    GetInvokingResource = function() return nil end
    check(mine == 1 and theirs == 2, '7.1: ids 1 (cis_libs) and 2 (res_b) -- the case the bug needs')
    env.fire('onResourceStop', 'res_b')
    env.coords = { x = 0.0, y = 0.0, z = 0.0 }
    local closest = exports.GetClosestPoint()
    check(closest == mine,
        ('7.1: stopping res_b leaves cis_libs point %s alive (closest=%s)'):format(tostring(mine), tostring(closest)))
    check(exports.RemovePoint(theirs) == false,
        '7.1: and res_b point is gone after its owner stopped')
    check(exports.RemovePoint(mine) == true, '7.1: the survivor is still removable')
    env.reset()
end

-- ONLY THE OWNER MAY REMOVE A POINT. Ids are 1, 2, 3...: without the check any
-- resource removes every other resource's points by counting.
do
    local env = pointEnv()
    env.save('GetInvokingResource')
    GetInvokingResource = function() return 'res_a' end
    local id = exports.CreatePoint({ coords = { x = 0, y = 0, z = 0 }, distance = 5 })
    GetInvokingResource = function() return 'res_b' end
    local ok, why = exports.RemovePoint(id)
    check(ok == false and type(why) == 'string' and why:find('res_a', 1, true),
        ('7.1: another resource cannot remove a point it does not own (got %s, %s)'):format(tostring(ok), tostring(why)))
    GetInvokingResource = function() return 'res_a' end
    check(exports.RemovePoint(id) == true, '7.1: the owner can')
    env.reset()
end

-- A PASS DOES NOT BUILD DEBUG STATE. The inside list was rebuilt AND SORTED on
-- every pass for a debug view nobody was reading; it is now built on request.
do
    local env = pointEnv()
    exports.CreatePoint({ coords = { x = 0, y = 0, z = 0 }, distance = 5 })
    exports.CreatePoint({ coords = { x = 1, y = 0, z = 0 }, distance = 5 })
    local realSort = table.sort
    local sorts = 0
    table.sort = function(...) sorts = sorts + 1; return realSort(...) end
    pointPass(env)
    pointPass(env)
    table.sort = realSort
    check(sorts == 0, ('7.1: a pass performs no sort (sorts=%d)'):format(sorts))
    local dbg = exports.GetPointsDebug()
    check(dbg.insideCount == 2 and dbg.insideIds[1] == 1 and dbg.insideIds[2] == 2,
        ('7.1: the debug view is still right when asked (count=%s)'):format(tostring(dbg.insideCount)))
    env.reset()
end

-- ===================================================== 7.2 Cis.streaming
--
-- Seven asset kinds, one table, and four things that have to be true for each
-- of them or the feature is a different feature from the one that was asked
-- for: a valid request answers the asset; an invalid one refuses WITH A REASON
-- and does not sit out the timeout; a timed-out one RELEASES; and a name kind
-- never gets a hash.
--
-- The environment stubs every native the table names and RECORDS what it was
-- asked, because the release-on-timeout branch is invisible from a return
-- value: the function answers the same `nil, reason` whether or not it
-- released, and the only difference is a native call nobody would otherwise see.
local function streamEnv(opts)
    opts = opts or {}
    local env = newEnv({})
    env.calls = {}
    env.loadedAfter = opts.loadedAfter or nil
    env.never = opts.never == true
    -- Copied from opts rather than read off it at the use site, because the
    -- first version read `opts.badAnimDict` directly and it was ALWAYS nil --
    -- so the "an invalid anim dict is refused" case silently tested the
    -- opposite and the suite said the refusal path worked.
    env.badAnimDict = opts.badAnimDict == true
    env.badModel = opts.badModel == true
    env.clock = 0

    local function recorder(name, result)
        return function(...)
            env.calls[#env.calls + 1] = { name = name, args = table.pack(...) }
            return result
        end
    end
    local function probe(name)
        return function(asset)
            env.calls[#env.calls + 1] = { name = name, args = table.pack(asset) }
            if env.never then return false end
            if env.loadedAfter ~= nil and env.clock >= env.loadedAfter then return true end
            return false
        end
    end

    function IsModelInCdimage() return not env.badModel end
    function joaat(s) return 1000 + #tostring(s) end

    -- The request natives. `RequestScaleformMovie` and `RequestScriptAudioBank`
    -- ANSWER, which is the whole reason those two kinds are special.
    RequestModel = recorder('RequestModel')
    RequestAnimDict = recorder('RequestAnimDict')
    RequestAnimSet = recorder('RequestAnimSet')
    RequestNamedPtfxAsset = recorder('RequestNamedPtfxAsset')
    RequestStreamedTextureDict = recorder('RequestStreamedTextureDict')
    RequestWeaponAsset = recorder('RequestWeaponAsset')
    RequestScaleformMovie = recorder('RequestScaleformMovie', opts.scaleformRefused and 0 or 7)
    -- REQUEST_SCRIPT_AUDIO_BANK IS ITS OWN POLL: false while the bank loads, true
    -- once it is in. `bankAfter` is when it starts answering true.
    env.bankAfter = opts.bankAfter
    RequestScriptAudioBank = function(...)
        env.calls[#env.calls + 1] = { name = 'RequestScriptAudioBank', args = table.pack(...) }
        if env.never then return false end
        return env.bankAfter == nil or env.clock >= env.bankAfter
    end

    HasModelLoaded = probe('HasModelLoaded')
    HasAnimDictLoaded = probe('HasAnimDictLoaded')
    HasAnimSetLoaded = probe('HasAnimSetLoaded')
    HasNamedPtfxAssetLoaded = probe('HasNamedPtfxAssetLoaded')
    HasStreamedTextureDictLoaded = probe('HasStreamedTextureDictLoaded')
    HasWeaponAssetLoaded = probe('HasWeaponAssetLoaded')
    -- HAS_SCALEFORM_MOVIE_LOADED TAKES THE HANDLE RequestScaleformMovie returned.
    -- Asked with a name it can never answer true in game, so here it raises.
    local scaleformProbe = probe('HasScaleformMovieLoaded')
    HasScaleformMovieLoaded = function(handle)
        if handle ~= 7 then
            error(('HasScaleformMovieLoaded takes the movie handle, got %s'):format(tostring(handle)), 2)
        end
        return scaleformProbe(handle)
    end
    DoesAnimDictExist = function(name)
        env.calls[#env.calls + 1] = { name = 'DoesAnimDictExist', args = table.pack(name) }
        return not env.badAnimDict
    end

    -- The release natives, which is what the timeout branch asserts on.
    SetModelAsNoLongerNeeded = recorder('SetModelAsNoLongerNeeded')
    RemoveAnimDict = recorder('RemoveAnimDict')
    RemoveAnimSet = recorder('RemoveAnimSet')
    RemoveNamedPtfxAsset = recorder('RemoveNamedPtfxAsset')
    SetStreamedTextureDictAsNoLongerNeeded = recorder('SetStreamedTextureDictAsNoLongerNeeded')
    RemoveWeaponAsset = recorder('RemoveWeaponAsset')
    SetScaleformMovieAsNoLongerNeeded = recorder('SetScaleformMovieAsNoLongerNeeded')
    ReleaseNamedScriptAudioBank = recorder('ReleaseNamedScriptAudioBank')

    GetNumberOfStreamingRequests = function() return 3 end
    HaveAllStreamingRequestsCompleted = function() return true end

    -- A Wait that advances the clock, so a timeout is reachable in a test at
    -- all. The first version of this harness did not advance it, and every
    -- timeout assertion failed for a reason that had nothing to do with the
    -- code under test.
    function Wait(ms)
        env.clock = env.clock + (tonumber(ms) or 0)
    end
    function GetGameTimer() return env.clock end

    loadModule('client/streaming.lua')
    env.called = function(name)
        for _, c in ipairs(env.calls) do
            if c.name == name then return c end
        end
        return nil
    end
    env.countOf = function(name)
        local n = 0
        for _, c in ipairs(env.calls) do
            if c.name == name then n = n + 1 end
        end
        return n
    end
    return env
end

-- EVERY KIND, and what its request native is called. Written out rather than
-- looped over a table the implementation also owns, so a kind that stops being
-- registered shows up as a missing key here instead of as a row that quietly
-- did not run.
do
    local KINDS = {
        { call = 'AnimDict', asset = 'amb@code_human_in_bus_passenger_idles@female@seat@cl_a@idle', request = 'RequestAnimDict', release = 'RemoveAnimDict' },
        { call = 'AnimSet', asset = 'move_m@_a', request = 'RequestAnimSet', release = 'RemoveAnimSet' },
        { call = 'Ptfx', asset = 'scr_fire1', request = 'RequestNamedPtfxAsset', release = 'RemoveNamedPtfxAsset' },
        { call = 'TextureDict', asset = 'mpbigteams', request = 'RequestStreamedTextureDict', release = 'SetStreamedTextureDictAsNoLongerNeeded' },
        { call = 'WeaponAsset', asset = 0x1F45D307, request = 'RequestWeaponAsset', release = 'RemoveWeaponAsset' },
        { call = 'Scaleform', asset = 'bossmp', request = 'RequestScaleformMovie', release = 'SetScaleformMovieAsNoLongerNeeded' },
        { call = 'AudioBank', asset = 'ambient_bank_indoor', request = 'RequestScriptAudioBank', release = 'ReleaseNamedScriptAudioBank' },
    }

    -- A VALID REQUEST, for every kind. `loadedAfter = 50` rather than 0,
    -- because an asset that is ALREADY resident returns without requesting at
    -- all -- which is the correct behaviour and is asserted separately below.
    -- The first version of this table used 0, so the request native was never
    -- called and four of the seven kinds reported a failure that was really a
    -- test asserting the wrong path.
    for _, k in ipairs(KINDS) do
        local env = streamEnv({ loadedAfter = 50 })
        local got, why = exports[k.call](k.asset, 1000)
        check(got ~= nil,
            ('7.2: %s loads and answers the asset (got nil, %s)'):format(k.call, tostring(why)))
        check(env.called(k.request) ~= nil,
            ('7.2: %s called %s'):format(k.call, k.request))
        check(env.countOf(k.release) == 0,
            ('7.2: %s does NOT release on success -- releasing is the caller job'):format(k.call))
        env.reset()
    end

    -- AN ALREADY-RESIDENT ASSET IS NOT RE-REQUESTED. Asking twice is the whole
    -- reason to have these rather than calling the native directly, and a
    -- re-request on a resident asset is what pushes a server towards "too many
    -- loaded assets".
    for _, k in ipairs(KINDS) do
        -- Not a scaleform (its probe takes a handle, which only a request makes)
        -- and not an audio bank (its request IS the probe).
        if k.call ~= 'AudioBank' and k.call ~= 'Scaleform' then
            local env = streamEnv({ loadedAfter = 0 })
            local got = exports[k.call](k.asset, 1000)
            check(got ~= nil, ('7.2: %s answers immediately when already resident'):format(k.call))
            check(env.called(k.request) == nil,
                ('7.2: %s does NOT re-request an asset that is already loaded'):format(k.call))
            env.reset()
        end
    end

    -- A TIMED-OUT REQUEST, for every kind that waits. This is the branch the
    -- whole file exists for, so it is asserted per kind and not once.
    for _, k in ipairs(KINDS) do
        -- Every kind, the audio bank included: it is polled to a deadline too.
        do
            local env = streamEnv({ never = true })
            local got, why = exports[k.call](k.asset, 100)
            check(got == nil and type(why) == 'string' and why:find('did not load'),
                ('7.2: %s times out with a reason (got %s, %s)'):format(k.call, tostring(got), tostring(why)))
            check(env.called(k.release) ~= nil,
                ('7.2: %s RELEASES on timeout -- without this the request stays resident forever'):format(k.call))
            env.reset()
        end
        -- A NaN deadline never passes, so a NaN timeout polled forever. The hook
        -- turns that back into a failure.
        for _, bad in ipairs({ 0 / 0, math.huge, -1 }) do
            local env = streamEnv({ never = true })
            debug.sethook(function() error('HUNG', 0) end, '', 2000000)
            local okCall, got, why = pcall(exports[k.call], k.asset, bad)
            debug.sethook()
            check(okCall and got == nil and tostring(why):find('timeout', 1, true) ~= nil,
                ('7.2: %s refuses a timeout of %s with a reason, not a wait (%s)'):format(k.call, tostring(bad), tostring(why)))
            env.reset()
        end
    end

    -- THE NAME KINDS NEVER GET A HASH, and this catches the reverse mistake.
    -- `RequestAnimDict` takes a char*, so a hash is a type error the game
    -- answers by never loading -- and the caller waits out the whole timeout to
    -- find out.
    do
        local env = streamEnv({ loadedAfter = 50 })
        exports.AnimDict('some_dict')
        local call = env.called('RequestAnimDict')
        check(call ~= nil and type(call.args[1]) == 'string',
            '7.2: an anim dict is requested BY NAME, not by hash')
        env.reset()
    end

    -- `RequestStreamedTextureDict` takes TWO arguments and the second is the
    -- streamed flag. Passing one puts a nil where a BOOL belongs, which reads as
    -- false and quietly requests a non-streamed dictionary.
    do
        local env = streamEnv({ loadedAfter = 50 })
        exports.TextureDict('mpbigteams')
        local call = env.called('RequestStreamedTextureDict')
        check(call ~= nil and call.args.n == 2 and call.args[2] == true,
            ('7.2: a texture dict is requested with the streamed flag set (n=%s, p2=%s)')
                :format(tostring(call and call.args.n), tostring(call and call.args[2])))
        env.reset()
    end

    -- `RequestScriptAudioBank` answers directly, so it must NOT wait. A wait
    -- here would cost the caller the timeout on every SUCCESS.
    do
        local env = streamEnv({})
        local before = env.clock
        local got = exports.AudioBank('ambient_bank_indoor', 5000)
        check(got ~= nil, '7.2: an audio bank that is already in answers immediately')
        check(env.clock == before,
            ('7.2: an audio bank does NOT wait (the clock moved %dms)'):format(env.clock - before))
        env.reset()
    end

    -- ONE false FROM RequestScriptAudioBank IS "NOT YET". The bank answers false
    -- while it loads; treating the first false as a refusal failed every bank
    -- that was not already resident.
    do
        local env = streamEnv({ bankAfter = 200 })
        local got, why = exports.AudioBank('ambient_bank_indoor', 5000)
        check(got == 'ambient_bank_indoor',
            ('7.2: an audio bank still loading is asked again until it answers true (got %s, %s)')
                :format(tostring(got), tostring(why)))
        check(env.countOf('RequestScriptAudioBank') >= 3,
            ('7.2: the request is repeated (calls=%d)'):format(env.countOf('RequestScriptAudioBank')))
        env.reset()
    end

    -- A scaleform is polled by its HANDLE and answers it in slot two.
    do
        local env = streamEnv({ loadedAfter = 50 })
        local got, handle = exports.Scaleform('bossmp', 1000)
        check(got == 'bossmp' and handle == 7,
            ('7.2: a scaleform answers its name and the movie handle (got %s, %s)'):format(tostring(got), tostring(handle)))
        env.reset()
    end

    -- A REFUSAL that answers FALSE, which for scaleform is a real third state
    -- between "not yet" and "loaded" -- the request native returns 0, and losing
    -- that would mean waiting out the timeout for something that will never
    -- exist.
    do
        local env = streamEnv({ never = true, scaleformRefused = true })
        local got, why = exports.Scaleform('bossmp', 3000)
        check(got == nil and type(why) == 'string',
            ('7.2: a scaleform the engine refuses answers nil with a reason (got %s, %s)')
                :format(tostring(got), tostring(why)))
        env.reset()
    end

    -- THE EXISTENCE PROBE, and the asymmetry that has to be documented: an
    -- invalid anim dict is refused in microseconds, and an invalid ptfx name
    -- costs the whole timeout because there is no probe for it.
    do
        local env = streamEnv({ badAnimDict = true })
        local before = env.clock
        local got, why = exports.AnimDict('not_a_real_dict', 5000)
        check(got == nil and type(why) == 'string' and why:find('does not exist'),
            ('7.2: a non-existent anim dict is refused by name (got %s, %s)'):format(tostring(got), tostring(why)))
        check(env.clock == before,
            '7.2: the existence probe refuses WITHOUT waiting out the timeout')
        env.reset()
    end

    -- Every refusal names its own fix, and none of them is a bare nil.
    do
        local env = streamEnv({ never = true })
        local g1, w1 = exports.AnimDict()
        check(g1 == nil and type(w1) == 'string', '7.2: a missing asset is refused with a reason')
        local g2, w2 = exports.AnimDict({})
        check(g2 == nil and type(w2) == 'string' and w2:find('name or a hash'),
            ('7.2: a table where an asset was wanted names the two legal shapes (got %s)'):format(tostring(w2)))
        -- AN UNKNOWN KIND IS NOT REACHABLE, and the assertion that says so is
        -- this file failing to find an export rather than one passing. The
        -- exports are GENERATED FROM THE KIND TABLE, so there is no name a
        -- caller can type that is not a kind. The guard inside requestAsset
        -- therefore protects the two internal call sites -- RequestModelTimeout
        -- and the export loop -- against a typo, and nothing else.
        --
        -- That is worth stating rather than testing: a branch no caller can
        -- reach is not a coverage hole, it is a typo-catcher, and calling it
        -- either way would be a claim the test could not support.
        check(type(exports.AnimSet) == 'function',
            '7.2: every kind in the table has its export registered, including animSet')
        env.reset()
    end
end

-- `Cis.streaming.model` keeps this published shape. The first slot is a boolean
-- and the second is ALWAYS the hash, on every path including every refusal --
-- because that export is published and a caller written as
-- `local ok, hash = ...` has to keep working. This is the one asymmetry in the
-- namespace and it is deliberate.
do
    local env = streamEnv({ loadedAfter = 50 })
    local ok, hash = exports.RequestModelTimeout('a_model', 1000)
    check(ok == true and type(hash) == 'number',
        ('7.2: model answers boolean then hash on success (got %s, %s)'):format(tostring(ok), tostring(hash)))
    env.reset()

    local env2 = streamEnv({ never = true })
    local ok2, hash2 = exports.RequestModelTimeout('a_model', 100)
    check(ok2 == false and type(hash2) == 'number',
        ('7.2: model answers FALSE then the hash on a timeout -- the hash is never nil (got %s, %s)')
            :format(tostring(ok2), tostring(hash2)))
    env2.reset()

    local env3 = streamEnv({})
    env3.badModel = true
    local ok3, hash3 = exports.RequestModelTimeout('nope', 1000)
    check(ok3 == false and type(hash3) == 'number',
        ('7.2: an invalid model is refused immediately and STILL answers the hash (got %s, %s)')
            :format(tostring(ok3), tostring(hash3)))
    env3.reset()
end

-- ===================================================== 7.3 Cis.world
--
-- Four closest getters and four nearby lists, all from ONE pool walk, plus the
-- caller-supplied filter.
--
-- The filter is the interesting part and it has several failure modes worth a
-- test each: a filter that excludes (the obvious one), a filter that RAISES
-- (which must not end the scan), a filter that returns a TRUTHY NON-BOOLEAN
-- (which must not silently include), and a filter that raises for ONE entity
-- (which must not remove the others).
local function worldEnv()
    local env = newEnv({})
    env.entities = {
        [101] = { x = 3.0, y = 0.0, z = 0.0, alive = true },
        [102] = { x = 12.0, y = 0.0, z = 0.0, alive = true },
        [103] = { x = 30.0, y = 0.0, z = 0.0, alive = true },
        [104] = { x = 5.0, y = 0.0, z = 0.0, alive = false },
    }
    -- THE REAL POOL NAMES. These were `CPoolablePed` and friends, matching the
    -- library's own wrong names, so the suite certified queries that find nothing
    -- in game. GET_GAME_POOL knows CPed, CVehicle, CObject and CPickup.
    env.pools = { CPed = {}, CVehicle = {}, CObject = {}, CPickup = {} }
    env.activePlayers = { 0, 1 }
    -- PlayerId() is 0 in the base harness, so player 0 / ped 201 is the local
    -- player.
    env.ped = 201
    env.playerPeds = { [0] = 201, [1] = 202 }
    env.playerPedCoords = {
        [201] = { x = 8.0, y = 0.0, z = 0.0 },
        [202] = { x = 40.0, y = 0.0, z = 0.0 },
    }

    function DoesEntityExist(e)
        if e == nil or e == 0 then return false end
        if env.playerPedCoords[e] ~= nil then return true end
        local rec = env.entities[e]
        return rec ~= nil and rec.alive == true
    end
    function GetEntityCoords(e)
        return env.entities[e] or env.playerPedCoords[e]
    end
    function GetGamePool(name)
        -- A name the game does not know is a test failure, not an empty pool: the
        -- empty answer is exactly how the wrong names went unnoticed.
        local pool = env.pools[name]
        if pool == nil then error(('GetGamePool: no pool named %s'):format(tostring(name)), 2) end
        local snapshot = {}
        for i = 1, #pool do snapshot[i] = pool[i] end
        return snapshot
    end
    function GetActivePlayers() return env.activePlayers end
    function GetPlayerPed(i) return env.playerPeds[i] end
    function GetPlayers() return { '1', '2' } end
    function IsDuplicityVersion() return false end
    function IsPedAPlayer(ped) return env.playerPedCoords[ped] ~= nil end

    loadModule('client/world.lua')
    return env
end

-- Written out so a kind that stops being scanned shows up as a missing key
-- rather than as a silently shorter list.
local function seed(env)
    -- The ped pool holds PLAYER peds too, as the real one does.
    env.pools.CPed = { 101, 102, 103, 104, 201, 202 }
    env.pools.CVehicle = { 101, 102 }
    env.pools.CObject = { 101 }
end

do
    -- CLOSEST, and the ORDERING is the whole assertion: 101 is 3 m away, 102 is
    -- 12, 103 is 30, and 104 is dead. A pool walk that took the first candidate
    -- would pass this by luck and fail the filter case below.
    local env = worldEnv(); seed(env)
    local ped, coords = exports.ClosestPed({ x = 0.0, y = 0.0, z = 0.0 })
    check(ped == 101, ('7.3: closestPed picks the NEAREST, not the first (got %s)'):format(tostring(ped)))
    check(coords ~= nil and math.abs(coords.x - 3.0) < 0.001, '7.3: closestPed answers the coords too')
    env.reset()

    -- THE DEAD ENTITY IS NEVER CONSIDERED.
    local env2 = worldEnv(); seed(env2)
    local all = exports.NearbyPeds({ x = 0.0, y = 0.0, z = 0.0 }, 100)
    local sawDead = false
    for _, e in ipairs(all) do
        if e.entity == 104 then sawDead = true end
    end
    check(not sawDead, '7.3: a dead pool entity is skipped rather than returned')
    env2.reset()

    -- NEARBY IS A SORTED LIST AND NEVER NIL. An empty result is a real answer.
    local env3 = worldEnv(); seed(env3)
    local near = exports.NearbyPeds({ x = 0.0, y = 0.0, z = 0.0 }, 100)
    check(type(near) == 'table' and #near == 3,
        ('7.3: nearbyPeds returns every live ped in range (got %s entries)'):format(tostring(near and #near)))
    local sorted = true
    for i = 2, #near do
        if near[i].distance < near[i - 1].distance then sorted = false end
    end
    check(sorted, '7.3: nearbyPeds is sorted by distance, so element 1 is the closest')
    check(near[1].entity == 101 and near[1].coords ~= nil,
        '7.3: a nearby entry carries the handle AND the coords')
    local none = exports.NearbyPeds({ x = 900.0, y = 0.0, z = 0.0 }, 5)
    check(type(none) == 'table' and #none == 0,
        '7.3: nothing in range is an EMPTY LIST, not nil')
    env3.reset()

    -- MAX DISTANCE IS HONOURED.
    local env4 = worldEnv(); seed(env4)
    local close = exports.NearbyPeds({ x = 0.0, y = 0.0, z = 0.0 }, 10)
    check(#close == 1,
        ('7.3: maxDistance bounds the list (got %d entries, wanted 1)'):format(#close))
    env4.reset()
end

-- THE FILTER.
do
    -- It EXCLUDES, and the excluded one is the NEAREST -- so an implementation
    -- that picked the closest first and filtered afterwards would pass
    -- everything else and fail exactly here.
    local env = worldEnv(); seed(env)
    local got = exports.ClosestPed({ x = 0.0, y = 0.0, z = 0.0 }, 100, function(entity)
        return entity ~= 101
    end)
    check(got == 102, ('7.3: the filter is applied BEFORE the closest is chosen (got %s)'):format(tostring(got)))
    env.reset()

    -- It receives the handle AND the coords. A filter that only ever received
    -- the handle would be much less useful, and would be a silent reduction.
    local env2 = worldEnv(); seed(env2)
    local sawCoords = false
    exports.ClosestPed({ x = 0.0, y = 0.0, z = 0.0 }, 100, function(_entity, c)
        if type(c) == 'table' and c.x ~= nil then sawCoords = true end
        return true
    end)
    check(sawCoords, '7.3: the filter is given the entity AND its coords')
    env2.reset()

    -- IT RAISES, and the scan survives and ends in a refusal rather than a
    -- crash. This is the whole reason for the pcall: consumer code called once
    -- per candidate, per call, on a thread the caller does not own.
    local env3 = worldEnv(); seed(env3)
    local ok, why = exports.ClosestPed({ x = 0.0, y = 0.0, z = 0.0 }, 100, function()
        error('consumer bug')
    end)
    check(ok == false and type(why) == 'string',
        ('7.3: a filter that raises on every entity ends with a refusal, not a crash (got %s, %s)')
            :format(tostring(ok), tostring(why)))
    local counted = CisDiagnostics and CisDiagnostics.Count and CisDiagnostics.Count('worldFilterErrors')
    check(type(counted) == 'number' and counted >= 3,
        ('7.3: the raising filter is COUNTED, once per candidate (got %s)'):format(tostring(counted)))
    env3.reset()

    -- A filter that RAISES for ONE entity does not remove the others.
    local env4 = worldEnv(); seed(env4)
    local partial = exports.ClosestPed({ x = 0.0, y = 0.0, z = 0.0 }, 100, function(entity)
        if entity == 102 then error('only this one') end
        return true
    end)
    check(partial == 101,
        ('7.3: a filter that raises for one entity does not remove the rest (got %s)'):format(tostring(partial)))
    env4.reset()

    -- A TRUTHY NON-BOOLEAN is not true. `if keep then` would include a filter
    -- that returned the entity handle -- always truthy -- so a consumer writing
    -- `return entity` instead of `return true` would get NO filtering at all,
    -- which is the opposite of what their code reads as saying.
    local env5 = worldEnv(); seed(env5)
    local truthy = exports.ClosestPed({ x = 0.0, y = 0.0, z = 0.0 }, 100, function(entity)
        return entity
    end)
    check(truthy == false,
        ('7.3: a filter returning a truthy NON-boolean excludes rather than includes (got %s)'):format(tostring(truthy)))
    env5.reset()
end

-- PLAYERS, whose arity differs from everything else on purpose.
do
    local env = worldEnv(); seed(env)
    -- YOU ARE NOT THE CLOSEST PLAYER TO YOURSELF. Player 0 (ped 201, 8 m) is the
    -- local player; without the exclusion every caller standing anywhere got
    -- themselves back.
    local ped, coords, playerId = exports.ClosestPlayer({ x = 0.0, y = 0.0, z = 0.0 }, 100)
    check(ped == 202, ('7.3: closestPlayer answers ANOTHER player ped, never your own (got %s)'):format(tostring(ped)))
    check(coords ~= nil, '7.3: closestPlayer answers the coords')
    check(playerId == 1, ('7.3: closestPlayer answers WHICH player in slot 3 (got %s)'):format(tostring(playerId)))
    local mine = exports.ClosestPlayer({ x = 0.0, y = 0.0, z = 0.0 }, 100, nil, { includeSelf = true })
    check(mine == 201, ('7.3: includeSelf puts the local player back (got %s)'):format(tostring(mine)))
    local list = exports.NearbyPlayers({ x = 0.0, y = 0.0, z = 0.0 }, 100)
    check(type(list) == 'table' and #list == 1 and list[1].player == 1,
        ('7.3: nearbyPlayers lists every OTHER connected player (got %s)'):format(tostring(list and #list)))
    local all = exports.NearbyPlayers({ x = 0.0, y = 0.0, z = 0.0 }, 100, nil, { includeSelf = true })
    check(#all == 2, ('7.3: and includeSelf lists all of them (got %d)'):format(#all))
    env.reset()
end

-- A PED QUERY MEANS NPCs. Player peds sit in the same pool, so without the
-- exclusion `closestPed` near another player answered that player.
do
    local env = worldEnv(); seed(env)
    local near = exports.NearbyPeds({ x = 0.0, y = 0.0, z = 0.0 }, 100)
    local sawPlayer = false
    for _, e in ipairs(near) do
        if e.entity == 201 or e.entity == 202 then sawPlayer = true end
    end
    check(not sawPlayer and #near == 3, ('7.3: nearbyPeds excludes player peds (got %d entries)'):format(#near))
    local withPlayers = exports.NearbyPeds({ x = 0.0, y = 0.0, z = 0.0 }, 100, nil, { includePlayers = true })
    check(#withPlayers == 4, ('7.3: includePlayers adds OTHER players, not yourself (got %d)'):format(#withPlayers))
    env.reset()
end

-- A FILTER FROM ANOTHER RESOURCE IS A FUNCREF TABLE, and it must filter.
do
    local env = worldEnv(); seed(env)
    local got = exports.ClosestPed({ x = 0.0, y = 0.0, z = 0.0 }, 100, funcref(function(entity)
        return entity ~= 101
    end))
    check(got == 102, ('7.3: a funcref filter is applied (got %s)'):format(tostring(got)))
    env.reset()
end

-- EVERY REFUSAL NAMES ITS OWN FIX, and none raises on a nil coords.
do
    local env = worldEnv(); seed(env)
    local ok1, why1 = exports.ClosestPed()
    check(ok1 == false and type(why1) == 'string' and why1:find('nil'),
        ('7.3: missing coords is refused by name (got %s, %s)'):format(tostring(ok1), tostring(why1)))
    local ok2, why2 = exports.NearbyPeds('not coords')
    check(ok2 == false and type(why2) == 'string',
        ('7.3: a string where coords belong is refused (got %s)'):format(tostring(why2)))
    local ok3, why3 = exports.ClosestPed({ y = 1.0, z = 2.0 })
    check(ok3 == false and type(why3) == 'string' and why3:find('x'),
        ('7.3: coords with no x is refused and names the missing component (got %s)'):format(tostring(why3)))
    local ok4 = exports.ClosestPed({ x = 0, y = 0, z = 0 }, 100, nil)
    check(ok4 == 101, '7.3: an omitted filter is simply not applied')
    -- A NIL KIND IS REFUSED BY NAME, whatever the coords. 'closest' .. nil raised
    -- inside the coords check, before the kind was ever looked at.
    for _, fn in ipairs({ CisWorldClosest, CisWorldNearby }) do
        local okK, whyK = pcall(fn, nil, nil)
        check(okK and whyK == false, ('7.3: a nil kind is refused, not raised (%s)'):format(tostring(whyK)))
        local _, reason = fn(nil, { x = 0, y = 0, z = 0 })
        check(type(reason) == 'string' and reason:find('unknown kind', 1, true) ~= nil,
            ('7.3: and the refusal names the kinds (%s)'):format(tostring(reason)))
        local _, reasonB = fn('boat', nil)
        check(type(reasonB) == 'string' and reasonB:find('unknown kind "boat"', 1, true) ~= nil,
            ('7.3: an unknown kind is named before the coords are checked (%s)'):format(tostring(reasonB)))
    end
    local players = CisWorldNearby('player', { x = 0, y = 0, z = 0 }, 100)
    check(#players == 1 and players[1].player == 1 and players[1].entity == 202,
        '7.3: a nearby player entry still carries its player index')
    env.reset()
end

-- ===================================================== initialize: server-only events
--
-- A RegisterNetEvent handler is also reachable by a local TriggerEvent from any
-- client resource; the runtime sets `source` to '' for that and to 65535 for
-- one from the server. Only the second may rewrite the config or notify.
do
    local env = newEnv({})
    env.save('CisLibReady')
    env.save('CisLibFailed')
    env.save('CisReadyState')
    env.save('BeginTextCommandThefeedPost')
    env.save('AddTextComponentSubstringPlayerName')
    env.save('EndTextCommandThefeedPostTicker')
    CisReadyState = { ready = false, failed = false, markReady = function() CisReadyState.ready = true end,
        wait = function() return true end }
    Config = CisDefaults.config()
    local notified = {}
    function BeginTextCommandThefeedPost() end
    function AddTextComponentSubstringPlayerName(t) notified[#notified + 1] = t end
    function EndTextCommandThefeedPostTicker() end
    loadModule('client/initialize.lua')
    local before = Config.CallbackTimeout
    env.net('cis_libs:client:getData', '', { Config = { CallbackTimeout = 1234 } })
    check(Config.CallbackTimeout == before and CisReadyState.ready == false,
        ('initialize: a LOCAL TriggerEvent of getData (source \'\') is ignored (timeout=%s)')
            :format(tostring(Config.CallbackTimeout)))
    env.net('cis_libs:client:showNotification', '', 'forged')
    check(#notified == 0, 'initialize: a local showNotification is ignored')
    env.net('cis_libs:client:getData', 65535, { Config = { CallbackTimeout = 1234 } })
    check(Config.CallbackTimeout == 1234 and CisReadyState.ready == true,
        ('initialize: the server\'s getData (source 65535) is applied (timeout=%s)'):format(tostring(Config.CallbackTimeout)))
    env.net('cis_libs:client:showNotification', 65535, 'real')
    check(notified[1] == 'real', 'initialize: and the server\'s notification is shown')
    env.reset()
end

-- ===================================================== weapon attachments
--
-- The attachment list used to be 24 generic COMPONENT_AT_* names, so a pistol's
-- extended clip or a finish was never reported. The game decides which
-- components a weapon takes; the stub answers that question for a pistol.
do
    local env = newEnv({})
    local takesAsked = 0
    local pistol = joaat('WEAPON_PISTOL')
    local takes = {
        [joaat('COMPONENT_PISTOL_CLIP_02')] = true,
        [joaat('COMPONENT_AT_PI_FLSH')] = true,
        [joaat('COMPONENT_PISTOL_VARMOD_LUXE')] = true,
    }
    local has = {
        [joaat('COMPONENT_PISTOL_CLIP_02')] = true,
        [joaat('COMPONENT_PISTOL_VARMOD_LUXE')] = true,
    }
    function DoesWeaponTakeWeaponComponent(weapon, component)
        takesAsked = takesAsked + 1
        return weapon == pistol and takes[component] == true
    end
    function HasPedGotWeaponComponent(_, weapon, component)
        assert(takes[component], 'HasPedGotWeaponComponent asked about a component the weapon cannot take')
        return weapon == pistol and has[component] == true
    end
    loadModule('client/weapon.lua')
    local got = GetWeaponAttachments(7, pistol)
    local set = {}
    for _, c in ipairs(got) do set[c] = true end
    check(#got == 2 and set[joaat('COMPONENT_PISTOL_CLIP_02')] and set[joaat('COMPONENT_PISTOL_VARMOD_LUXE')],
        ('weapon: a pistol reports its extended clip and its finish, not only AT_* parts (got %d)'):format(#got))
    local asked = takesAsked
    GetWeaponAttachments(7, pistol)
    check(takesAsked == asked,
        ('weapon: which components a weapon takes is asked once and cached (asked again %d times)')
            :format(takesAsked - asked))
    check(#GetWeaponAttachments(7, 0) == 0, 'weapon: no weapon has no attachments')
    env.reset()
end

-- ===================================================== 7.4 Cis.raycast
--
-- Bounded poll, camera forward in RADIANS, ignore defaults to the player, LOS
-- options 7. The shape-test stub answers what the native answers: status 1
-- while pending, 2 when done, 0 for a dead handle, and `hit` as the INTEGER
-- 0 or 1 that CfxLua returns for a BOOL* out-parameter.
-- ITEM 10 NATIVE ARGUMENTS. REQUEST_WEAPON_ASSET's p1 is 31 in the scripts the
-- native docs cite; HAVE_ALL_STREAMING_REQUESTS_COMPLETED takes a ped; and a
-- fractional timeout is reported, not raised on by `%d`.
do
    local env = streamEnv({ loadedAfter = 50 })
    exports.WeaponAsset(0x1F45D307, 1000)
    local req = env.called('RequestWeaponAsset')
    check(req and req.args[2] == 31 and req.args[3] == 0,
        ('10: RequestWeaponAsset is asked with p1 = 31, p2 = 0 (got %s, %s)')
            :format(tostring(req and req.args[2]), tostring(req and req.args[3])))
    env.reset()

    env = streamEnv({ never = true })
    local ok, got, why = pcall(exports.AnimDict, 'missing_dict', 10.5)
    check(ok and got == nil and tostring(why):find('10.5ms', 1, true) ~= nil,
        ('10: a fractional streaming timeout answers a reason, not a raise (%s, %s)'):format(tostring(got), tostring(why)))
    env.reset()

    -- The diagnostics probe is captured as it registers, then asked.
    local probes = {}
    local realRegister = CisDiagnostics.Register
    CisDiagnostics.Register = function(realm, name, fn) probes[name] = fn end
    env = streamEnv({})
    CisDiagnostics.Register = realRegister
    local askedWith
    HaveAllStreamingRequestsCompleted = function(...) askedWith = table.pack(...); return true end
    local report = probes.streaming and probes.streaming()
    check(report and report.allComplete == true and askedWith and askedWith.n == 1 and askedWith[1] == PlayerPedId(),
        ('10: HaveAllStreamingRequestsCompleted is given the player ped (got %s)')
            :format(tostring(askedWith and askedWith[1])))
    env.reset()
end

local function raycastEnv(opts)
    opts = opts or {}
    local env = newEnv({})
    env.calls = {}
    env.clock = 0
    env.hit = opts.hit == true
    env.endCoords = opts.endCoords or { x = 1, y = 2, z = 3 }
    env.normal = opts.normal or { x = 0, y = 0, z = 1 }
    env.material = opts.material or 123
    env.entity = opts.entity or 77
    env.pendingReads = opts.pendingReads or 1
    env.reads = 0
    env.cam = opts.cam or { x = 0, y = 0, z = 0 }
    env.rot = opts.rot or { x = 0, y = 0, z = 90 }
    function Wait(ms)
        env.clock = env.clock + math.max(tonumber(ms) or 0, 1)
    end
    function GetGameTimer() return env.clock end
    function GetGameplayCamRot() return env.rot end
    function GetGameplayCamCoord() return env.cam end
    -- THE ASYNC PROBE. The synchronous one blocks the game thread; calling it fails.
    env.save('StartShapeTestLosProbe')
    rawset(_ENV, 'StartExpensiveSynchronousShapeTestLosProbe', function()
        error('raycast: the synchronous LOS probe blocks the game thread', 0)
    end)
    function StartShapeTestLosProbe(...)
        env.calls[#env.calls + 1] = { name = 'StartShapeTestLosProbe', args = table.pack(...) }
        return opts.refused and 0 or 9
    end
    function GetShapeTestResultIncludingMaterial(handle)
        env.reads = env.reads + 1
        if opts.failed then
            return 0, 0, nil, nil, 0, 0
        end
        if opts.never or env.reads <= env.pendingReads then
            return 1, 0, nil, nil, 0, 0
        end
        return 2, env.hit and 1 or 0, env.endCoords, env.normal, env.material, env.hit and env.entity or 0
    end
    env.ped = 31
    env.inVehicle = opts.inVehicle or 0
    function GetVehiclePedIsIn() return env.inVehicle end
    loadModule('client/raycast.lua')
    return env
end

do
    local env = raycastEnv({ pendingReads = 1, hit = true, entity = 42 })
    local hit, entity, coords, normal, material = exports.RaycastFromCoords(
        { x = 0, y = 0, z = 0 }, { x = 10, y = 0, z = 0 }, nil, nil, 2000)
    check(hit == true, ('7.4: a resolved hit answers true (got %s)'):format(tostring(hit)))
    check(entity == 42, ('7.4: and the entity (got %s)'):format(tostring(entity)))
    check(coords and coords.x == 1, '7.4: and endCoords')
    check(normal and normal.z == 1, '7.4: and the surface normal')
    check(material == 123, '7.4: and the material hash')
    local start = env.calls[1]
    check(start ~= nil and start.args[8] == 31,
        ('7.4: ignore defaults to the player ped, so a ray does not hit its own caster (got %s)')
            :format(tostring(start and start.args[8])))
    check(start ~= nil and start.args[9] == 7,
        ('7.4: LOS options are 7 (got %s)'):format(tostring(start and start.args[9])))
    env.reset()
end

do
    local env = raycastEnv({ pendingReads = 1, hit = false })
    local hit, entity, coords = exports.RaycastFromCoords(
        { x = 0, y = 0, z = 0 }, { x = 1, y = 0, z = 0 })
    check(hit == false, ('7.4: a miss answers false, not nil (got %s)'):format(tostring(hit)))
    check(entity == nil, '7.4: a miss has no entity')
    check(coords ~= nil, '7.4: a miss still carries endCoords -- how far the ray got')
    env.reset()
end

-- A MISS IS hit == 0, and 0 is truthy. `if hit` reported every miss as a hit.
do
    local env = raycastEnv({ pendingReads = 0, hit = false })
    local hit, entity = exports.RaycastFromCoords({ x = 0, y = 0, z = 0 }, { x = 1, y = 0, z = 0 })
    check(hit == false and entity == nil,
        ('7.4: an integer 0 hit is a MISS (got %s, %s)'):format(tostring(hit), tostring(entity)))
    env.reset()
end

-- STATUS 0 IS A FAILED PROBE, answered at once rather than polled to the timeout.
do
    local env = raycastEnv({ failed = true })
    local hit, why = exports.RaycastFromCoords({ x = 0, y = 0, z = 0 }, { x = 1, y = 0, z = 0 }, -1, 0, 2000)
    check(hit == nil and type(why) == 'string' and why:find('failed', 1, true) and env.clock < 100,
        ('7.4: status 0 is a failure with a reason, not a pending probe (got %s, %s, clock=%d)')
            :format(tostring(hit), tostring(why), env.clock))
    env.reset()
end

-- IN A VEHICLE, the camera ray ignores the vehicle, which is what it starts behind.
do
    local env = raycastEnv({ pendingReads = 0, hit = false, inVehicle = 88 })
    exports.RaycastCamera(nil, nil, 10, 2000)
    local start = env.calls[1]
    check(start ~= nil and start.args[8] == 88,
        ('7.4: a camera ray from a vehicle ignores that vehicle (got %s)'):format(tostring(start and start.args[8])))
    env.reset()
end

do
    local env = raycastEnv({ never = true })
    local hit, why = exports.RaycastFromCoords(
        { x = 0, y = 0, z = 0 }, { x = 1, y = 0, z = 0 }, -1, 0, 5)
    check(hit == nil and type(why) == 'string' and why:find('did not resolve', 1, true),
        ('7.4: a probe that never resolves times out WITH A REASON (got %s, %s)'):format(tostring(hit), tostring(why)))
    env.reset()
end

-- A FRACTIONAL TIMEOUT times out with a reason; `%d` raised on it in Lua 5.4.
do
    local env = raycastEnv({ never = true })
    local ok, hit, why = pcall(exports.RaycastFromCoords,
        { x = 0, y = 0, z = 0 }, { x = 1, y = 0, z = 0 }, -1, 0, 5.5)
    check(ok and hit == nil and tostring(why):find('5.5ms', 1, true) ~= nil,
        ('10: a fractional raycast timeout answers a reason, not a raise (%s, %s)'):format(tostring(hit), tostring(why)))
    env.reset()
end

do
    local env = raycastEnv({ pendingReads = 0, hit = true })
    exports.RaycastCamera(nil, nil, 10, 2000)
    local start = env.calls[1]
    -- rot.z = 90 degrees, looking +X in this convention: dirX = -sin(rad(90)) = -1
    check(start ~= nil and math.abs(start.args[4] + 10) < 0.01,
        ('7.4: camera direction uses RADIANS, so 90 degrees looks along -X (x2=%s)')
            :format(tostring(start and start.args[4])))
    env.reset()
end

do
    local env = raycastEnv({})
    local ok, why = exports.RaycastFromCoords(nil, { x = 1, y = 0, z = 0 })
    check(ok == nil and type(why) == 'string' and why:find('origin', 1, true),
        ('7.4: a missing origin is refused by name (got %s)'):format(tostring(why)))
    env.reset()
end

-- AN INFINITE RAY, OR A NaN END, NEVER REACHES THE PROBE. inf passed the
-- distance check, and a NaN coordinate passed the type check.
do
    local env = raycastEnv({ pendingReads = 0, hit = true })
    for _, d in ipairs({ math.huge, 1e9 }) do
        local ok, why = exports.RaycastCamera(nil, nil, d, 2000)
        check(ok == nil and tostring(why):find('distance', 1, true) ~= nil,
            ('7.4: a camera distance of %s is refused (%s)'):format(tostring(d), tostring(why)))
    end
    local nan = 0 / 0
    local okO, whyO = exports.RaycastFromCoords({ x = nan, y = 0, z = 0 }, { x = 1, y = 0, z = 0 })
    check(okO == nil and tostring(whyO):find('origin', 1, true) ~= nil,
        ('7.4: a NaN origin is refused by name (%s)'):format(tostring(whyO)))
    local okT, whyT = exports.RaycastFromCoords({ x = 0, y = 0, z = 0 }, { x = 1, y = -math.huge, z = 0 })
    check(okT == nil and tostring(whyT):find('target', 1, true) ~= nil,
        ('7.4: an infinite target is refused by name (%s)'):format(tostring(whyT)))
    check(#env.calls == 0, ('7.4: and no probe was started (%d)'):format(#env.calls))
    env.reset()
end

-- ===================================================== 7.5 Cis.keybind
do
    local env = newEnv({})
    env.mappings = {}
    function RegisterKeyMapping(...)
        env.mappings[#env.mappings + 1] = table.pack(...)
    end
    loadModule('client/keybind.lua')

    local pressed, released = 0, 0
    local handle, why = exports.KeybindAdd({
        name = 'cis_test_bind',
        description = 'test bind',
        defaultKey = 'F7',
        onPress = function() pressed = pressed + 1 end,
        onRelease = function() released = released + 1 end,
    })
    check(type(handle) == 'table' and handle.isPressed ~= nil,
        ('7.5: add returns a handle (got %s, %s)'):format(tostring(handle), tostring(why)))
    local map = env.mappings[1]
    check(map ~= nil and map[1] == '+cis_test_bind',
        ('7.5: RegisterKeyMapping commandString is +name (got %s)'):format(tostring(map and map[1])))
    check(map ~= nil and map.n == 4 and map[3] == 'keyboard' and map[4] == 'F7',
        ('7.5: four args, mapper keyboard, key F7 (n=%s mapper=%s key=%s)')
            :format(tostring(map and map.n), tostring(map and map[3]), tostring(map and map[4])))
    check(env.commands['+cis_test_bind'] ~= nil and env.commands['-cis_test_bind'] ~= nil,
        '7.5: both +name and -name commands are registered BEFORE the mapping')

    env.commands['+cis_test_bind'].fn()
    check(pressed == 1 and handle:isPressed() == true, '7.5: +name fires onPress and isPressed')
    env.commands['-cis_test_bind'].fn()
    check(released == 1 and handle:isPressed() == false, '7.5: -name fires onRelease and clears pressed')

    handle:disable(true)
    local before = pressed
    env.commands['+cis_test_bind'].fn()
    check(pressed == before, '7.5: disable stops onPress')

    local bad, badWhy = exports.KeybindAdd({ name = 'has space', onPress = function() end })
    check(bad == false and type(badWhy) == 'string' and badWhy:find('name', 1, true),
        ('7.5: a name with a space is refused (got %s)'):format(tostring(badWhy)))
    local none, noneWhy = exports.KeybindAdd({ name = 'okname' })
    check(none == false and type(noneWhy) == 'string' and noneWhy:find('onPress', 1, true),
        '7.5: a binding with neither callback is refused')

    -- A COMMAND ANOTHER RESOURCE HOLDS IS REFUSED. Each consumer's engine has
    -- its own byName, so only the client-wide command list can see the clash.
    local savedList = rawget(_ENV, 'GetRegisteredCommands')
    GetRegisteredCommands = function()
        return {
            { name = '+other_menu', resource = 'other_res', arity = -1 },
            { name = '+builtin_bind', arity = -1 },
            { name = '+cis_test_bind', resource = 'cis_libs', arity = -1 },
        }
    end
    local taken, takenWhy = exports.KeybindAdd({ name = 'other_menu', onPress = function() end })
    check(taken == false and tostring(takenWhy):find('other_res', 1, true) ~= nil and env.commands['+other_menu'] == nil,
        ('7.5: a +name another resource registered is refused, naming it (%s)'):format(tostring(takenWhy)))
    local builtin, builtinWhy = exports.KeybindAdd({ name = 'BUILTIN_BIND', onPress = function() end })
    check(builtin == false and tostring(builtinWhy):find('builtin', 1, true) ~= nil,
        ('7.5: a builtin of the same name, in any case, is refused (%s)'):format(tostring(builtinWhy)))
    local again = exports.KeybindAdd({ name = 'cis_test_bind', onPress = function() end })
    check(type(again) == 'table', '7.5: a command this resource registered itself is not a clash')
    GetRegisteredCommands = savedList
    env.reset()
end

-- THE CONSUMER'S VIEW: handlers are funcrefs, the handle arrives without its
-- metatable, and the commands outlive every binding because FiveM cannot
-- unregister one.
do
    local env = newEnv({})
    env.mappings = {}
    function RegisterKeyMapping(...)
        env.mappings[#env.mappings + 1] = table.pack(...)
    end
    loadModule('client/keybind.lua')
    env.save('GetInvokingResource')
    GetInvokingResource = function() return 'res_a' end

    local pressed = 0
    local handle = exports.KeybindAdd({
        name = 'cis_ref_bind',
        onPress = funcref(function() pressed = pressed + 1 end),
    })
    check(type(handle) == 'table' and type(handle.id) == 'number',
        ('7.5: a funcref onPress is accepted (got %s)'):format(tostring(handle)))
    local id = handle and handle.id
    env.commands['+cis_ref_bind'].fn()
    check(pressed == 1, ('7.5: and it fires on +name (pressed=%d)'):format(pressed))
    check(exports.KeybindIsPressed(id) == true, '7.5: KeybindIsPressed(id) answers by id')
    env.commands['-cis_ref_bind'].fn()
    check(exports.KeybindIsPressed(id) == false, '7.5: and clears on -name')

    -- Keybinds hands out snapshots, never another resource's callbacks.
    local list = exports.Keybinds()
    local leaked = false
    for _, b in ipairs(list) do
        if b.onPress ~= nil or b.onRelease ~= nil or getmetatable(b) ~= nil then leaked = true end
    end
    check(#list == 1 and not leaked, '7.5: Keybinds lists bindings without their callbacks')

    -- A NAME ANOTHER RESOURCE HOLDS IS REFUSED.
    GetInvokingResource = function() return 'res_b' end
    local stolen, why = exports.KeybindAdd({ name = 'cis_ref_bind', onPress = function() end })
    check(stolen == false and type(why) == 'string' and why:find('res_a', 1, true),
        ('7.5: res_b cannot take a name res_a holds (got %s, %s)'):format(tostring(stolen), tostring(why)))
    env.commands['+cis_ref_bind'].fn()
    check(pressed == 2, '7.5: and res_a still owns the key')

    -- Id-based control is the owner's.
    local okB = exports.KeybindDisable(id)
    check(okB == false, '7.5: res_b cannot disable res_a binding by id')
    GetInvokingResource = function() return 'res_a' end
    check(exports.KeybindDisable(id) == true, '7.5: the owner can disable by id')
    env.commands['+cis_ref_bind'].fn()
    check(pressed == 2, '7.5: a binding disabled by id does not fire')
    check(exports.KeybindEnable(id) == true, '7.5: and re-enable by id')
    env.commands['+cis_ref_bind'].fn()
    check(pressed == 3, '7.5: and it fires again')

    -- REMOVE MAKES THE COMMAND INERT. The command cannot be unregistered, so the
    -- closure must find nothing to call -- not a live flag and a dead funcref.
    check(exports.KeybindRemove(id) == true, '7.5: the owner can remove by id')
    env.commands['+cis_ref_bind'].fn()
    check(pressed == 3, ('7.5: a removed binding\'s command does nothing (pressed=%d)'):format(pressed))
    check(handle.enabled == false, '7.5: and the handle says it is disabled')

    -- AN OWNER'S STOP MAKES ITS BINDINGS INERT, and frees the name.
    local stopCalls = 0
    exports.KeybindAdd({ name = 'cis_stop_bind', onPress = funcref(function() stopCalls = stopCalls + 1 end) })
    env.fire('onResourceStop', 'res_a')
    local ok, err = pcall(env.commands['+cis_stop_bind'].fn)
    check(ok and stopCalls == 0, ('7.5: a stopped owner\'s binding no longer calls its dead handler (%s, calls=%d)')
        :format(tostring(err), stopCalls))
    GetInvokingResource = function() return 'res_b' end
    local reused = exports.KeybindAdd({ name = 'cis_stop_bind', onPress = function() end })
    check(type(reused) == 'table', '7.5: the name is free for another resource once its owner stopped')
    env.reset()
end

-- ===================================================== 7.7 Cis.statebag
--
-- THE DEFECT. The watcher parsed `entity:<netId>` and handed the NUMBER to the
-- handler as an entity. A netId is not a handle: on a client DoesEntityExist(netId)
-- names some unrelated script handle or nothing, so the wait timed out and the
-- handler never fired; when it did "exist", the consumer was handed the wrong
-- entity. The bag is resolved with GetEntityFromStateBagName, which is the native
-- for exactly that, and a delete is value == nil -- `reserved` is documented as
-- unused, and reading it as "deleted" reported every ordinary set as a delete or
-- none at all.
--
-- The stubs map bag -> entity with numbers that DIFFER from the netId, and make
-- the netId itself "exist", so a parse-and-hand-over regression is a wrong value
-- rather than a coincidentally right one.
local function statebagEnv(opts)
    opts = opts or {}
    local env = newEnv({ invoking = opts.invoking })
    for _, name in ipairs({
        'IsDuplicityVersion', 'AddStateBagChangeHandler', 'RemoveStateBagChangeHandler',
        'GetEntityFromStateBagName', 'GetPlayerFromStateBagName', 'GetPlayerServerId',
        'GetPlayerPed', 'CisStatebagOnEntity', 'CisStatebagOnPlayer',
    }) do
        env.save(name)
    end
    env.cookies = 0
    env.bagHandlers = {}
    env.removedCookies = {}
    env.bagEntities = {}
    env.exists = {}
    env.playerHandles = {}
    env.serverIds = {}
    env.peds = {}
    function IsDuplicityVersion() return opts.server == true end
    function DoesEntityExist(id) return env.exists[id] == true end
    function AddStateBagChangeHandler(key, bagFilter, fn)
        env.cookies = env.cookies + 1
        env.bagKey = key
        env.bagFilter = bagFilter
        env.bagHandlers[env.cookies] = fn
        return env.cookies
    end
    function RemoveStateBagChangeHandler(cookie)
        env.removedCookies[#env.removedCookies + 1] = cookie
        env.bagHandlers[cookie] = nil
    end
    function GetEntityFromStateBagName(bag) return env.bagEntities[bag] or 0 end
    function GetPlayerFromStateBagName(bag) return env.playerHandles[bag] or -1 end
    function GetPlayerServerId(handle) return env.serverIds[handle] or 0 end
    function GetPlayerPed(handle) return env.peds[handle] or 0 end
    -- Every registered change handler sees every change, the way the runtime
    -- dispatches them; the key filter is the handler's own business.
    function env.change(bag, key, value, reserved, replicated)
        for _, fn in pairs(env.bagHandlers) do
            fn(bag, key, value, reserved or 0, replicated ~= false)
        end
    end
    -- The drain thread, stepped one Wait at a time.
    function env.stepPump(steps)
        local fn = env.threads and env.threads[#env.threads]
        if not fn then return false end
        -- A drained queue ends its thread; the next change starts a new one.
        if not env.pumpCo or coroutine.status(env.pumpCo) == 'dead'
            or env.pumpThreads ~= #env.threads then
            env.pumpCo = coroutine.create(fn)
            env.pumpThreads = #env.threads
        end
        local realWait = Wait
        Wait = function(ms)
            env.clock = env.clock + (tonumber(ms) or 0)
            coroutine.yield()
        end
        for _ = 1, steps or 1 do
            if coroutine.status(env.pumpCo) == 'dead' then break end
            local ok, err = coroutine.resume(env.pumpCo)
            if not ok then Wait = realWait; error(err, 0) end
        end
        Wait = realWait
        return coroutine.status(env.pumpCo) ~= 'dead'
    end
    loadModule('shared/statebag.lua')
    return env
end

local function statebagProbe()
    return CisDiagnostics.Collect('client').probes.statebag or {}
end

do
    local env = statebagEnv({})
    local seen = {}
    local cookie = exports.StatebagOnEntity('locked', function(entity, value, replicated, deleted)
        seen[#seen + 1] = { entity = entity, value = value, replicated = replicated, deleted = deleted }
    end, 200)
    check(cookie == 1, ('7.7: onEntity returns a cookie (got %s)'):format(tostring(cookie)))

    -- netId 99 also "exists" as a handle, which is what made the old parse look right.
    env.exists[99] = true
    env.bagEntities['entity:99'] = 7001
    env.exists[7001] = true
    env.change('entity:99', 'locked', 'yes', 0, true)
    check(#seen == 1 and seen[1].entity == 7001,
        ('7.7: an entity bag resolves through GetEntityFromStateBagName, not the netId '
            .. 'in its name (got %s)'):format(tostring(seen[1] and seen[1].entity)))
    check(seen[1] ~= nil and seen[1].value == 'yes' and seen[1].deleted == false,
        '7.7: a set is not a delete')

    -- `reserved` is unused by the runtime; a 1 there is not a delete.
    env.change('entity:99', 'locked', false, 1, true)
    check(#seen == 2 and seen[2].deleted == false and seen[2].value == false,
        '7.7: a non-zero reserved is NOT read as a delete; false is a value')
    env.change('entity:99', 'locked', nil, 0, true)
    check(#seen == 3 and seen[3].deleted == true,
        '7.7: a change to nil is the delete')

    local ok = exports.RemoveStatebagHandler(cookie)
    check(ok == true and env.removedCookies[1] == cookie, '7.7: remove takes the cookie')
    local again = exports.RemoveStatebagHandler(cookie)
    check(again == false, '7.7: a cookie that was already removed answers false')

    local bad = exports.StatebagOnEntity('', function() end)
    check(bad == nil, '7.7: an empty key is refused')
    local notFn = exports.StatebagOnEntity('locked', 'nope')
    check(notFn == nil, '7.7: a handler that is not callable is refused')
    env.reset()
end

-- THE PENDING QUEUE. A client hears about a bag before its entity exists. That
-- change waits -- in ONE queue, with ONE drain thread, newest value winning -- and
-- fires once the entity is there. The old shape started a polling coroutine per
-- change, so 100 changes on an entity this client never streams were 100 threads.
do
    local env = statebagEnv({})
    local seen = {}
    exports.StatebagOnEntity('door', function(entity, value)
        seen[#seen + 1] = { entity = entity, value = value }
    end, 500)

    for i = 1, 100 do
        env.change('entity:40', 'door', i, 0, true)
    end
    check(#seen == 0, '7.7: a change for an entity that is not here yet does not fire')
    check(#(env.threads or {}) == 1,
        ('7.7: 100 changes on one missing entity start ONE drain thread (got %d)')
            :format(#(env.threads or {})))
    check(statebagProbe().pending == 1,
        ('7.7: and coalesce into ONE pending entry (got %s)'):format(tostring(statebagProbe().pending)))

    env.stepPump(2)
    check(#seen == 0, '7.7: still nothing while the entity is missing')
    env.bagEntities['entity:40'] = 8040
    env.stepPump(1)
    check(#seen == 1 and seen[1].entity == 8040 and seen[1].value == 100,
        ('7.7: the entity arrives and the NEWEST value fires once (got %d, value %s)')
            :format(#seen, tostring(seen[1] and seen[1].value)))
    env.stepPump(3)
    check(#seen == 1, '7.7: and only once')

    -- An entity that never arrives expires at the watcher's deadline, and the
    -- queue is BOUNDED: distinct bags past the cap drop the oldest.
    for i = 1, 300 do
        env.change('entity:' .. (1000 + i), 'door', true, 0, true)
    end
    local probe = statebagProbe()
    check((probe.pending or 999) <= 256 and (probe.dropped or 0) >= 44,
        ('7.7: the queue is bounded (pending %s, dropped %s)')
            :format(tostring(probe.pending), tostring(probe.dropped)))
    env.stepPump(20)
    probe = statebagProbe()
    check(probe.pending == 0 and (probe.expired or 0) >= 1,
        ('7.7: entities that never arrive expire at the deadline (pending %s, expired %s)')
            :format(tostring(probe.pending), tostring(probe.expired)))
    check(#seen == 1, '7.7: and an expired change never fires')
    env.reset()
end

-- PLAYERS, AND WHO OWNS A WATCHER.
do
    local env = statebagEnv({ invoking = 'res_a' })
    local players, peds, fromFuncref = {}, {}, {}
    exports.StatebagOnPlayer('dead', function(src, value)
        players[#players + 1] = { src = src, value = value }
    end)
    -- A function from another resource arrives as a callable funcref table.
    local ref = setmetatable({ __cfx_functionReference = 'res_a:1' }, {
        __call = function(_, entity, value) fromFuncref[#fromFuncref + 1] = { entity, value } end,
    })
    local refCookie = exports.StatebagOnEntity('dead', ref)
    check(type(refCookie) == 'number',
        '7.7: a funcref from another resource is accepted as a handler')
    exports.StatebagOnEntity('dead', function(entity, value)
        peds[#peds + 1] = { entity = entity, value = value }
    end)

    -- On a client the native answers a player HANDLE; the handler gets the server id.
    env.playerHandles['player:12'] = 5
    env.serverIds[5] = 12
    env.peds[5] = 9005
    env.change('player:12', 'dead', true, 0, true)
    check(#players == 1 and players[1].src == 12,
        ('7.7: a player watcher is handed the server id (got %s)')
            :format(tostring(players[1] and players[1].src)))
    check(#peds == 1 and peds[1].entity == 9005,
        ('7.7: an entity watcher on a player bag is handed that player\'s ped (got %s)')
            :format(tostring(peds[1] and peds[1].entity)))
    check(#fromFuncref == 1 and fromFuncref[1][1] == 9005,
        '7.7: and the funcref handler is called like a function')

    -- Out of scope: no handle, but the id is in the bag name and nothing waits.
    env.change('player:31', 'dead', false, 0, true)
    check(#players == 2 and players[2].src == 31,
        '7.7: a player this client cannot see still reports its server id')

    -- Another resource cannot remove res_a's watcher.
    env.invoking = 'res_b'
    local took, why = exports.RemoveStatebagHandler(refCookie)
    check(took == false and tostring(why):find('owner', 1, true) ~= nil,
        ('7.7: another resource cannot remove a watcher it does not own (%s)'):format(tostring(why)))

    -- The owner stops: every watcher it registered is removed from the runtime.
    env.fire('onResourceStop', 'res_a')
    check(#env.removedCookies == 3,
        ('7.7: a stopping owner takes all three of its watchers with it (removed %d)')
            :format(#env.removedCookies))
    env.change('player:12', 'dead', false, 0, true)
    check(#players == 2 and #fromFuncref == 1,
        '7.7: and a handler into a stopped resource is never called again')
    env.reset()
end

-- THE SERVER: no queue, and the wildcard is the native's absent filter.
do
    local env = statebagEnv({ server = true })
    local seen = {}
    exports.StatebagOnEntity('*', function(entity) seen[#seen + 1] = entity end)
    check(env.bagKey == nil,
        ('7.7: the "*" wildcard is passed as an absent key filter (got %s)'):format(tostring(env.bagKey)))
    env.change('entity:5', 'any', 1, 0, true)
    check(#seen == 0 and #(env.threads or {}) == 0,
        '7.7: on the server a bag that does not resolve is gone, not late: nothing waits')
    env.bagEntities['entity:5'] = 66
    env.change('entity:5', 'any', 1, 0, true)
    check(#seen == 1 and seen[1] == 66, '7.7: and one that resolves fires at once')
    env.reset()
end

-- ===================================================== 7.9 Cis.ui
--
-- Native fallbacks for notify and textUI; progress/confirm/input forward
-- only. The ui slot is declared in shared/registry.lua; these tests stub
-- CisRegistry so "has a provider" is a world fact, not a load of the
-- registry.

local function uiEnv(opts)
    opts = opts or {}
    local env = newEnv({})
    env.save('CisRegistry')
    for _, name in ipairs({
        'BeginTextCommandThefeedPost', 'AddTextComponentSubstringPlayerName',
        'EndTextCommandThefeedPostTicker', 'BeginTextCommandDisplayHelp',
        'EndTextCommandDisplayHelp', 'ClearAllHelpMessages',
    }) do
        env.save(name)
    end
    env.feed = {}
    env.help = {}
    env.cleared = 0
    env.hasUi = opts.hasUi == true
    env.uiMethods = opts.uiMethods or {}
    env.providerCalls = {}

    function BeginTextCommandThefeedPost(s)
        env.feed[#env.feed + 1] = { cmd = 'begin', s = s }
    end
    function AddTextComponentSubstringPlayerName(s)
        env.feed[#env.feed + 1] = { cmd = 'add', s = s }
        env.help[#env.help + 1] = { cmd = 'add', s = s }
    end
    function EndTextCommandThefeedPostTicker(a, b)
        env.feed[#env.feed + 1] = { cmd = 'end', a = a, b = b }
    end
    function BeginTextCommandDisplayHelp(s)
        env.help[#env.help + 1] = { cmd = 'begin', s = s }
    end
    function EndTextCommandDisplayHelp(shape, loop, beep, duration)
        env.help[#env.help + 1] = {
            cmd = 'end', shape = shape, loop = loop, beep = beep, duration = duration,
        }
        env.helpEnd = env.help[#env.help]
    end
    function ClearAllHelpMessages()
        env.cleared = env.cleared + 1
    end

    CisRegistry = {
        has = function(slot)
            return slot == 'ui' and env.hasUi == true
        end,
        call = function(slot, method, ...)
            env.providerCalls[#env.providerCalls + 1] = {
                slot = slot, method = method, args = table.pack(...),
            }
            local impl = env.uiMethods[method]
            if not impl then
                return false, ('no method %s'):format(tostring(method))
            end
            return true, impl(...)
        end,
    }

    loadModule('client/ui.lua')
    return env
end

local function feedAdds(env)
    local out = {}
    for i = 1, #env.feed do
        if env.feed[i].cmd == 'add' then
            out[#out + 1] = env.feed[i].s
        end
    end
    return out
end

do
    local env = uiEnv()
    local ok, why = exports.UiNotify('hello')
    check(ok == true, ('7.9: native notify answers true (got %s, %s)'):format(tostring(ok), tostring(why)))
    check(env.feed[1] ~= nil and env.feed[1].s == 'STRING',
        '7.9: native notify begins a STRING thefeed post')
    local adds = feedAdds(env)
    check(#adds == 1 and adds[1] == 'hello',
        ('7.9: native notify adds the message (got %s)'):format(tostring(adds[1])))
    check(env.feed[#env.feed] ~= nil and env.feed[#env.feed].cmd == 'end',
        '7.9: native notify ends the ticker')
    env.reset()
end

do
    local env = uiEnv()
    local ok = exports.UiNotify({ description = 'from-table', type = 'success' })
    check(ok == true, '7.9: a table with description is accepted')
    local adds = feedAdds(env)
    check(#adds == 1 and adds[1] == 'from-table',
        ('7.9: table.description is the message (got %s)'):format(tostring(adds[1])))
    env.reset()
end

do
    local env = uiEnv()
    local ok, why = exports.UiNotify('')
    check(ok == false and type(why) == 'string' and why:find('message', 1, true),
        ('7.9: an empty message is refused by name (got %s)'):format(tostring(why)))
    check(#env.feed == 0, '7.9: a refused notify does not touch the feed')
    local ok2, why2 = exports.UiNotify(nil)
    check(ok2 == false and type(why2) == 'string' and why2:find('message', 1, true),
        '7.9: a nil message is refused by name')
    env.reset()
end

do
    local env = uiEnv()
    local ok = exports.UiNotify(string.rep('x', 100))
    check(ok == true, '7.9: a 100-character message is accepted')
    local adds = feedAdds(env)
    check(#adds == 2,
        ('7.9: ADD_TEXT_COMPONENT is 99 characters, so 100 is TWO adds (got %d)')
            :format(#adds))
    check(adds[1] == string.rep('x', 99) and adds[2] == 'x',
        '7.9: the split is 99 then the remainder, not a silent truncate')
    env.reset()
end

-- A CUT NEVER SPLITS A UTF-8 CHARACTER. 98 ASCII bytes and then 'é' (two bytes)
-- put the 99-byte boundary inside the 'é'; a fixed cut renders garbage on both
-- sides of it.
do
    local env = uiEnv()
    local text = string.rep('x', 98) .. '\195\169' .. string.rep('y', 5) .. '\226\130\172'
    exports.UiNotify(text)
    local adds = feedAdds(env)
    local clean = true
    for _, piece in ipairs(adds) do
        local first, last = piece:byte(1), piece:byte(#piece)
        if first and first >= 0x80 and first < 0xC0 then clean = false end
        -- A piece must not END on a lead byte or mid-sequence: check it decodes.
        if utf8.len(piece) == nil then clean = false end
        if last and last >= 0xC0 then clean = false end
    end
    check(clean and table.concat(adds) == text and #adds[1] <= 99,
        ('7.9: help/notify text is chunked on UTF-8 character boundaries (pieces=%d, first=%d bytes)')
            :format(#adds, adds[1] and #adds[1] or -1))
    env.reset()
end

do
    local env = uiEnv()
    local ok, why = exports.UiTextUIShow('press e')
    check(ok == true, ('7.9: native textUI.show answers true (got %s, %s)'):format(tostring(ok), tostring(why)))
    check(env.help[1] ~= nil and env.help[1].s == 'STRING',
        '7.9: native help begins a STRING command')
    check(env.helpEnd ~= nil and env.helpEnd.loop == true and env.helpEnd.shape == 0
            and env.helpEnd.duration == -1,
        ('7.9: EndTextCommandDisplayHelp is loop=true, shape=0, duration=-1 (loop=%s)')
            :format(tostring(env.helpEnd and env.helpEnd.loop)))
    check(exports.UiTextUIIsOpen() == true, '7.9: isOpen is true after show')
    env.reset()
end

do
    local env = uiEnv()
    exports.UiTextUIShow('press e')
    local before = env.cleared
    local ok = exports.UiTextUIHide()
    check(ok == true, '7.9: hide answers true')
    check(env.cleared == before + 1, '7.9: hide of native help calls ClearAllHelpMessages')
    check(exports.UiTextUIIsOpen() == false, '7.9: isOpen is false after hide')
    env.reset()
end

do
    local env = uiEnv()
    local ok = exports.UiTextUIHide()
    check(ok == true, '7.9: hide with nothing open is still true')
    check(env.cleared == 0,
        '7.9: hide without show does NOT ClearAllHelpMessages -- that native wipes every help message, not just ours')
    env.reset()
end

do
    local env = uiEnv()
    local ok, why = exports.UiTextUIShow('')
    check(ok == false and type(why) == 'string' and why:find('string', 1, true),
        ('7.9: empty textUI text is refused (got %s)'):format(tostring(why)))
    check(exports.UiTextUIIsOpen() == false, '7.9: a refused show does not open')
    env.reset()
end

do
    local env = uiEnv()
    local ok, why = exports.UiProgress({})
    check(ok == false and type(why) == 'string' and why:find('no ui provider', 1, true),
        ('7.9: progress without a provider is false, \'no ui provider\' (got %s, %s)')
            :format(tostring(ok), tostring(why)))
    local cOk, cWhy = exports.UiConfirm({ header = 'x', content = 'y' })
    check(cOk == false and type(cWhy) == 'string' and cWhy:find('no ui provider', 1, true),
        '7.9: confirm without a provider is the same refusal')
    local iOk, iWhy = exports.UiInput({ heading = 'x' })
    check(iOk == false and type(iWhy) == 'string' and iWhy:find('no ui provider', 1, true),
        '7.9: input without a provider is the same refusal')
    local bad, badWhy = exports.UiProgress('nope')
    check(bad == false and type(badWhy) == 'string' and badWhy:find('table', 1, true),
        ('7.9: progress with a string is refused by name (got %s)'):format(tostring(badWhy)))
    env.reset()
end

do
    local env = uiEnv({
        hasUi = true,
        uiMethods = {
            Notify = function()
                return true
            end,
        },
    })
    local ok = exports.UiNotify('hi', 'error')
    check(ok == true, ('7.9: a ui provider Notify is forwarded (got %s)'):format(tostring(ok)))
    check(#env.feed == 0, '7.9: a live provider means the GTA feed is not touched')
    check(#env.providerCalls == 1 and env.providerCalls[1].method == 'Notify',
        '7.9: the provider was asked for Notify')
    local args = env.providerCalls[1].args
    check(args[1] == 'hi' and args[2] == 'error',
        ('7.9: the provider received (message, kind) unmoved (got %s, %s)')
            :format(tostring(args[1]), tostring(args[2])))
    env.reset()
end

do
    local env = uiEnv({ hasUi = true, uiMethods = {} })
    local ok = exports.UiNotify('still-native')
    check(ok == true, '7.9: a ui slot that cannot serve Notify still shows the native feed')
    local adds = feedAdds(env)
    check(#adds == 1 and adds[1] == 'still-native',
        '7.9: missing Notify on a registered slot falls through to the feed, not silence')
    env.reset()
end

do
    local env = uiEnv()
    env.invoking = 'my_resource'
    exports.UiTextUIShow('owned')
    check(exports.UiTextUIIsOpen() == true, '7.9: show under an owner opens')
    env.fire('onResourceStop', 'someone_else')
    check(exports.UiTextUIIsOpen() == true,
        '7.9: another resource stopping does not hide our help')
    env.fireFrom('evil_res', 'onResourceStop', 'my_resource')
    check(exports.UiTextUIIsOpen() == true,
        '7.9: a forged stop of the owner does not close its text UI')
    env.fire('onResourceStop', 'my_resource')
    check(exports.UiTextUIIsOpen() == false,
        '7.9: the owner stopping hides native help -- loop=true would otherwise stay forever')
    check(env.cleared >= 1, '7.9: owner-stop actually cleared the native')
    env.reset()
end

-- 7.9b: with the built-in NUI loaded (CisInterface), every Cis.ui call that no
-- provider answers goes to it, never to the GTA feed or to 'no ui provider'.
local function builtinUi(env)
    env.save('CisInterface')
    env.builtin = {}
    local log = env.builtin
    CisInterface = {
        notify = function(data) log[#log + 1] = { 'notify', data }; return true end,
        textUI = {
            show = function(text, opts) log[#log + 1] = { 'show', text, opts }; env.tuiOpen = true; return true end,
            hide = function() log[#log + 1] = { 'hide' }; env.tuiOpen = false; return true end,
            isOpen = function() return env.tuiOpen == true, 'x' end,
        },
        progress = {
            bar = function(o) log[#log + 1] = { 'bar', o }; return true end,
            circle = function(o) log[#log + 1] = { 'circle', o }; return false end,
        },
        alert = { open = function(o) log[#log + 1] = { 'alert', o }; return env.alertAnswer end },
        input = { open = function(h, rows, o) log[#log + 1] = { 'input', h, rows, o }; return { 'v1' } end },
    }
end

do
    local env = uiEnv()
    builtinUi(env)
    check(exports.UiNotify('hello', 'success') == true, '7.9b: notify answers through the built-in UI')
    local call = env.builtin[1]
    check(call and call[1] == 'notify' and call[2].description == 'hello' and call[2].type == 'success',
        '7.9b: a string notify becomes { description, type } for the built-in toast')
    check(#env.feed == 0, '7.9b: the built-in UI means the GTA feed is not touched')
    exports.UiNotify({ title = 'T', description = 'D', type = 'error', icon = 'bell' })
    call = env.builtin[2]
    check(call and call[2].title == 'T' and call[2].description == 'D' and call[2].icon == 'bell'
        and call[2].type == 'error', '7.9b: a table notify keeps title, icon and type')
    env.reset()
end

do
    local env = uiEnv()
    builtinUi(env)
    exports.UiTextUIShow('press E', { position = 'left' })
    check(env.builtin[1][1] == 'show' and env.builtin[1][2] == 'press E', '7.9b: textUI.show uses the built-in UI')
    check(#env.help == 0, '7.9b: built-in textUI never draws native help')
    check(exports.UiTextUIIsOpen() == true, '7.9b: isOpen reads the built-in state')
    exports.UiTextUIHide()
    check(exports.UiTextUIIsOpen() == false, '7.9b: hide closes the built-in text UI')
    env.reset()
end

do
    local env = uiEnv()
    builtinUi(env)
    check(exports.UiProgress({ duration = 10 }) == true, '7.9b: progress runs a bar by default')
    check(env.builtin[1][1] == 'bar', '7.9b: default progress is the bar')
    check(exports.UiProgress({ duration = 10, type = 'circle' }) == false, '7.9b: circle answers its own result')
    check(env.builtin[2][1] == 'circle', '7.9b: type = circle selects the circle')
    env.alertAnswer = 'confirm'
    local ok, raw = exports.UiConfirm({ title = 'Sure?', message = 'Really' })
    check(ok == true and raw == 'confirm', '7.9b: confirm maps the alert result to true')
    check(env.builtin[3][2].header == 'Sure?' and env.builtin[3][2].content == 'Really',
        '7.9b: confirm title/message become alert header/content')
    env.alertAnswer = 'cancel'
    ok = exports.UiConfirm({ header = 'x' })
    check(ok == false, '7.9b: a cancelled alert is false')
    local values = exports.UiInput({ heading = 'Name', rows = { { type = 'input', label = 'n' } } })
    check(type(values) == 'table' and values[1] == 'v1', '7.9b: input returns the built-in dialog values')
    check(env.builtin[5][2] == 'Name', '7.9b: input heading is forwarded')
    env.reset()
end

-- ============================ the allow-list gates client capability providers
--
-- A slot is first-come. A client script that started before the real `ui`
-- provider owned the slot and answered every consumer's Cis.ui.input and
-- confirm. The server now sends who may provide -- as digests, never names --
-- and a registration that arrives before that is held, in order, and filed or
-- refused when it does.
do
    local env = newEnv({})
    env.save('CisReadyState')
    CisReadyState = { wait = function() return true end, ready = true, failed = false }
    env.save('CisRegistry')
    loadModule('shared/registry.lua')
    loadModule('client/proxy.lua')

    env.invoking = 'rogue'
    local early = env.EXPORTS.RegisterCapability('ui', 'rogue:Ui')
    env.invoking = 'cis_ui'
    local legit = env.EXPORTS.RegisterCapability('ui', 'cis_ui:Ui')
    check(early == true and legit == true and not CisRegistry.has('ui'),
        'capability gate: before the server answers, registrations are held, not filed')
    env.invoking = nil

    env.net('cis_libs:client:getData', '', { Providers = 'any' })
    check(not CisRegistry.has('ui'), 'capability gate: a forged payload opens nothing')

    env.net('cis_libs:client:getData', 65535, { Providers = { CisConfigUtil.digest('cis_ui') } })
    check(CisRegistry.owner('ui') == 'cis_ui',
        ('capability gate: the listed provider gets the slot the squatter asked for first (owner=%s)')
            :format(tostring(CisRegistry.owner('ui'))))

    env.invoking = 'rogue'
    local late, why = env.EXPORTS.RegisterCapability('target', 'rogue:Target')
    check(late == false and tostring(why):find('cis_authorized_resources', 1, true) ~= nil
        and not CisRegistry.has('target'),
        ('capability gate: once known, an unlisted provider is refused at once (%s)'):format(tostring(why)))
    env.invoking = nil
    check(env.EXPORTS.RegisterCapability('target', function() return true end) == true,
        'capability gate: cis_libs\' own registrations are not gated')
    CisRegistry.unregister('target')

    env.net('cis_libs:client:getData', 65535, { Providers = 'any' })
    env.invoking = 'rogue'
    check(env.EXPORTS.RegisterCapability('target', 'rogue:Target') == true,
        'capability gate: a permissive server lets any resource provide')
    env.reset()
end

-- ==================================== a forged onResourceStop releases nothing
--
-- `onResourceStop` is an ordinary event: `TriggerEvent('onResourceStop',
-- 'victim')` from any client script used to release the victim's zones,
-- keybinds, targets, callbacks, cache listeners, statebag watchers and
-- capability slots. The engine fires a real stop with no script below the
-- handler, so GetInvokingResource() is nil there and the forger's name here.
-- Each file's sweep is watched through the release call it makes.
do
    local SWEEPS = {
        { file = 'client/cache.lua', lib = 'CisOwned', fn = 'release' },
        { file = 'client/callback.lua', lib = 'CisOwned', fn = 'release' },
        { file = 'client/keybind.lua', lib = 'CisOwned', fn = 'release' },
        { file = 'client/points.lua', lib = 'CisOwned', fn = 'release' },
        { file = 'client/target.lua', lib = 'CisOwned', fn = 'release' },
        { file = 'client/zones.lua', lib = 'CisOwned', fn = 'release' },
        { file = 'shared/statebag.lua', lib = 'CisOwned', fn = 'release' },
        { file = 'client/proxy.lua', lib = 'CisRegistry', fn = 'releaseOwner' },
        { file = 'shared/hooks.lua', lib = 'CisHooks', fn = 'releaseOwner' },
    }
    for _, s in ipairs(SWEEPS) do
        local env = newEnv({})
        env.save('CisReadyState')
        CisReadyState = { wait = function() return true end, ready = true, failed = false }
        env.save(s.lib)
        local calls = 0
        -- hooks.lua defines CisHooks itself, so it is watched after the load.
        if s.file ~= 'shared/hooks.lua' then
            -- Loaded fresh, so the spy does not depend on what an earlier test
            -- left in _G (the two runners preload differently).
            env.save('CisCallable')
            env.save('CisRealStop')
            loadModule(s.lib == 'CisOwned' and 'shared/owned.lua' or 'shared/registry.lua')
            local lib = _ENV[s.lib]
            local real = lib[s.fn]
            _ENV[s.lib] = setmetatable({ [s.fn] = function(...)
                calls = calls + 1
                return real(...)
            end }, { __index = lib })
        end
        env.handlers = {}
        local loaded, err = pcall(loadModule, s.file)
        check(loaded, ('forged stop: %s loads (%s)'):format(s.file, tostring(err)))
        if s.file == 'shared/hooks.lua' then
            local made = _ENV.CisHooks
            local own = made[s.fn]
            made[s.fn] = function(...)
                calls = calls + 1
                return own(...)
            end
        end
        env.fireFrom('evil_res', 'onResourceStop', 'res_a')
        check(calls == 0, ('forged stop: %s ignores a stop TriggerEvent\'d by another script (%d)')
            :format(s.file, calls))
        env.fire('onResourceStop', 'res_a')
        check(calls >= 1, ('forged stop: %s still sweeps on the engine\'s stop (%d)'):format(s.file, calls))
        local before = calls
        env.fireFrom('res_a', 'onResourceStop', 'res_a')
        check(calls > before, ('forged stop: %s accepts a resource stopping itself'):format(s.file))
        env.reset()
    end
end

-- A forged stop naming cis_libs itself despawned every synced entity while
-- cis_libs kept running; one naming a consumer dropped its spawn hooks.
do
    local env = syncEnv({})
    local calls = 0
    env.EXPORTS.AddSyncSpawnHandler(setmetatable({ __cfx_functionReference = 'res_a:1' }, {
        __call = function() calls = calls + 1 end,
    }))
    env.upsert(wirePayload('kept', {
        kind = 'prop', model = 'prop_barrel_01',
        coords = { x = 0.0, y = 0.0, z = 0.0 }, networked = false,
    }))
    env.fireFrom('evil_res', 'onResourceStop', GetCurrentResourceName())
    check(env.EXPORTS.GetSyncedEntity(wireKeyOf('kept')) ~= nil,
        'forged stop: naming cis_libs does not despawn its synced entities')
    env.fireFrom('evil_res', 'onResourceStop', 'res_a')
    env.upsert(wirePayload('kept2', {
        kind = 'prop', model = 'prop_barrel_01',
        coords = { x = 0.0, y = 0.0, z = 0.0 }, networked = false,
    }))
    check(calls == 2, ('forged stop: and naming a consumer keeps its spawn hooks (calls=%d)'):format(calls))
    env.fire('onResourceStop', GetCurrentResourceName())
    check(env.EXPORTS.GetSyncedEntity(wireKeyOf('kept')) == nil,
        'forged stop: the real cis_libs stop still despawns them')
    env.reset()
end

-- ============================ 11. the ox_lib gaps in the export path
--
-- Zones: a poly `thickness` (a ported zone spanned z -1000 to 10000) and the
-- getCurrent / getAll / getNearby queries, each limited to the caller's zones.
do
    local env = zoneEnv()
    local square = { { x = -5.0, y = -5.0, z = 10.0 }, { x = 5.0, y = -5.0, z = 10.0 },
        { x = 5.0, y = 5.0, z = 10.0 }, { x = -5.0, y = 5.0, z = 10.0 } }
    check(exports.CreateZone('poly', 'slab', square, { thickness = 4.0 }) == true, '11: a poly with thickness creates')
    check(exports.ZoneContains('slab', { x = 0.0, y = 0.0, z = 11.5 }) == true,
        '11: thickness 4 around z 10 holds z 11.5')
    check(exports.ZoneContains('slab', { x = 0.0, y = 0.0, z = 13.0 }) == false,
        '11: and not z 13 -- the floor above is outside the slab')
    local bad, badWhy = exports.CreateZone('poly', 'badslab', square, { thickness = 'tall' })
    check(bad == false and tostring(badWhy):find('thickness', 1, true) ~= nil,
        ('11: a non-number thickness is refused by name (%s)'):format(tostring(badWhy)))
    exports.RemoveZone('slab')

    env.invoking = 'res_a'
    exports.CreateZone('box', 'a_here', { x = 0.0, y = 0.0, z = 0.0 }, { x = 4.0, y = 4.0, z = 4.0 }, {})
    exports.CreateZone('box', 'a_far', { x = 500.0, y = 0.0, z = 0.0 }, { x = 4.0, y = 4.0, z = 4.0 }, {})
    env.invoking = 'res_b'
    exports.CreateZone('box', 'b_here', { x = 0.0, y = 0.0, z = 0.0 }, { x = 4.0, y = 4.0, z = 4.0 }, {})
    Cis.player.coords = function() return vector3(0.0, 0.0, 0.0) end
    local SENT = {}
    local realWait = Wait
    Wait = function(ms) env.clock = env.clock + math.max(tonumber(ms) or 0, 16); error(SENT, 0) end
    local ok, err = pcall(env.threads[#env.threads])
    Wait = realWait
    if not ok and err ~= SENT then error(err, 0) end
    env.invoking = 'res_a'
    check(table.concat(exports.GetAllZones(), ',') == 'a_far,a_here',
        ('11: GetAllZones answers the caller own zones, sorted (%s)'):format(table.concat(exports.GetAllZones(), ',')))
    check(table.concat(exports.GetCurrentZones(), ',') == 'a_here',
        ('11: GetCurrentZones answers the caller zones the player is in (%s)'):format(table.concat(exports.GetCurrentZones(), ',')))
    check(table.concat(exports.GetNearbyZones({ x = 0.0, y = 0.0, z = 0.0 }, 50), ',') == 'a_here',
        '11: GetNearbyZones leaves out a zone 500 m away')
    check(#exports.GetNearbyZones({ x = 0.0, y = 0.0, z = 0.0 }, -1) == 0, '11: and answers nothing for a bad radius')
    env.invoking = nil
    check(table.concat(exports.GetAllZones(), ',') == 'a_far,a_here,b_here', ('11: cis_libs sees every zone (%s)'):format(table.concat(exports.GetAllZones(), ',')))
    env.reset()
end

-- Points: handlers get the point's id, and getAll / getNearby list the caller's.
do
    local env = pointEnv()
    env.invoking = 'res_a'
    local enteredWith
    local idA = exports.CreatePoint({ coords = { x = 0.0, y = 0.0, z = 0.0 }, distance = 5.0,
        onEnter = function(coords, id) enteredWith = { coords, id } end })
    local idFar = exports.CreatePoint({ coords = { x = 300.0, y = 0.0, z = 0.0 }, distance = 5.0 })
    env.invoking = 'res_b'
    exports.CreatePoint({ coords = { x = 0.0, y = 0.0, z = 0.0 }, distance = 5.0 })
    pointPass(env)
    check(enteredWith and enteredWith[2] == idA and type(enteredWith[1]) == 'table',
        ('11: onEnter gets (coords, id) (id=%s)'):format(tostring(enteredWith and enteredWith[2])))
    env.invoking = 'res_a'
    local all = exports.GetAllPoints()
    check(#all == 2 and all[1] == idA and all[2] == idFar, '11: GetAllPoints answers the caller own ids, ascending')
    local near = exports.GetNearbyPoints()
    check(#near == 1 and near[1] == idA, ('11: GetNearbyPoints answers the points the player is inside (%d)'):format(#near))
    env.invoking = nil
    check(#exports.GetAllPoints() == 3, '11: cis_libs sees every point')
    env.reset()
end

-- Keybinds: secondaryKey registers the ~! alternate, disabled starts off, and
-- getCurrentKey reads the label of the bound key.
do
    local env = newEnv({})
    env.mappings = {}
    function RegisterKeyMapping(...)
        env.mappings[#env.mappings + 1] = table.pack(...)
    end
    env.save('GetHashKey')
    env.save('GetControlInstructionalButton')
    local askedControl
    function GetHashKey() return 0x12345678 end
    function GetControlInstructionalButton(pad, control, p2)
        askedControl = { pad, control, p2 }
        return 't_F7'
    end
    loadModule('client/keybind.lua')
    local pressed = 0
    local handle = exports.KeybindAdd({
        name = 'cis_two_keys', defaultKey = 'F7', secondaryKey = 'IOM_WHEEL_UP',
        secondaryMapper = 'mouse_wheel', disabled = true,
        onPress = function() pressed = pressed + 1 end,
    })
    local alt = env.mappings[2]
    check(alt and alt[1] == '~!+cis_two_keys' and alt[3] == 'mouse_wheel' and alt[4] == 'IOM_WHEEL_UP',
        ('11: secondaryKey registers the ~! alternate mapping (%s %s %s)')
            :format(tostring(alt and alt[1]), tostring(alt and alt[3]), tostring(alt and alt[4])))
    env.commands['+cis_two_keys'].fn()
    check(pressed == 0, '11: a binding added with disabled = true does not fire')
    handle:disable(false)
    env.commands['+cis_two_keys'].fn()
    check(pressed == 1, '11: and fires once enabled')
    check(handle:getCurrentKey() == 'F7', ('11: getCurrentKey reads the label (%s)'):format(tostring(handle:getCurrentKey())))
    check(askedControl and askedControl[2] == (0x12345678 | 0x80000000),
        '11: and asks for the command hash with the top bit set')
    local badAlt, badWhy = exports.KeybindAdd({ name = 'cis_bad_alt', secondaryKey = 5, onPress = function() end })
    check(badAlt == false and tostring(badWhy):find('secondaryKey', 1, true) ~= nil, '11: a non-string secondaryKey is refused by name')
    env.reset()
end

-- Callbacks: a per-call timeout, refused by name when it is not one.
do
    local env = newEnv({})
    loadModule('client/callback.lua')
    local deadlines = {}
    local realAlloc = CisPending.alloc
    CisPending.alloc = function(pending, payload, deadline)
        deadlines[#deadlines + 1] = deadline - GetGameTimer()
        return realAlloc(pending, payload, deadline)
    end
    env.awaitHook = function()
        local req = env.serverEvents[#env.serverEvents]
        env.net('cis_libs:cb:res', 0, req.args[2], true, 'quick')
    end
    local ok, v = env.EXPORTS.TryAwaitCallbackWithin('shop:price', 1500, 'apple')
    check(ok == true and v == 'quick', ('11: TryAwaitCallbackWithin answers the reply (%s, %s)'):format(tostring(ok), tostring(v)))
    check(deadlines[1] == 1500, ('11: and the call carries its own deadline (%s ms)'):format(tostring(deadlines[1])))
    -- A plain await keeps the configured deadline (Config.CallbackTimeout, else 10 s).
    local configured = (Config and Config.CallbackTimeout) or 10000
    env.EXPORTS.TryAwaitCallback('shop:price')
    check(deadlines[2] == configured,
        ('11: a plain await still uses the configured timeout (%s ms, want %s)'):format(tostring(deadlines[2]), tostring(configured)))
    local refused, why = env.EXPORTS.TryAwaitCallbackWithin('shop:price', -1)
    check(refused == false and tostring(why):find('timeout', 1, true) ~= nil,
        ('11: a bad timeout is refused by name (%s)'):format(tostring(why)))
    CisPending.alloc = realAlloc
    env.awaitHook = nil
    env.reset()
end

-- ============================ D1. client detection and deprecated slots warn once per caller
do
    local env = newEnv({})
    env.saved[#env.saved + 1] = { name = 'CisReadyState', value = rawget(_ENV, 'CisReadyState') }
    env.saved[#env.saved + 1] = { name = 'Logging', value = rawget(_ENV, 'Logging') }
    CisReadyState = { wait = function() return true end, ready = true }
    local warns = {}
    Logging = setmetatable({}, {
        __index = function(_, key)
            return function(message)
                if key == 'Warn' then warns[#warns + 1] = tostring(message) end
            end
        end,
    })
    local function count(needle)
        local n = 0
        for _, line in ipairs(warns) do
            if line:find('deprecated', 1, true) and line:find(needle, 1, true) then n = n + 1 end
        end
        return n
    end
    loadModule('client/proxy.lua')
    env.invoking = 'cis_hud'
    exports.DetectFramework()
    exports.DetectFramework()
    exports.DetectDatabase()
    check(count('DetectFramework') == 1 and count('DetectDatabase') == 1,
        ('D1: client DetectFramework and DetectDatabase warn cis_hud once each (got %d, %d)')
            :format(count('DetectFramework'), count('DetectDatabase')))
    env.invoking = 'cis_hud'
    exports.InventoryCount('water')
    exports.InventoryCount('water')
    check(count('"inventory"') == 1, ('D1: a client inventory call warns once (got %d)'):format(count('"inventory"')))
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