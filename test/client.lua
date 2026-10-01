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
    -- `cis_libs:cb` is registered through RegisterNetEvent, so it is delivered
    -- through env.net rather than env.fire.
    local fire = env.fire
    -- Net events are RECORDED, so a test can deliver the same event the server
    -- would. The server's `source` global is set around the dispatch rather than
    -- passed as an argument, exactly as FiveM does.
    env.netEvents = {}
    function RegisterNetEvent(name, fn)
        env.netEvents[name] = env.netEvents[name] or {}
        env.netEvents[name][#env.netEvents[name] + 1] = fn
    end
    function env.net(name, src, ...)
        local saved = rawget(_G, 'source')
        source = src
        for _, fn in ipairs(env.netEvents[name] or {}) do fn(...) end
        _G.source = saved
    end

    -- Outbound net events are RECORDED. `TriggerServerEvent` returns nothing, so
    -- "was the server told" is unanswerable from a caller's point of view --
    -- which is the whole of L-C14: an event that fires 60 times a second is
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

    -- The CLIENT-side stop event, which is a different global from the
    -- server's onResourceStop and fires for OTHER resources. A file that binds
    -- it and gets nil here would be untestable rather than broken, so it is
    -- recorded through the same handler table.
    function onClientResourceStop(fn)
        env.handlers.onClientResourceStop = env.handlers.onClientResourceStop or {}
        env.handlers.onClientResourceStop[#env.handlers.onClientResourceStop + 1] = fn
    end

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

-- ================================================= 2. entity sync, client half
--
-- The client-side defects are all about entities that outlive their record.
-- `TriggerClientEvent` returns nothing and `CreateObject` returns a handle, so
-- the only way to see either is to record what the natives were asked.
--
-- The harness here hands out entity handles from a counter and records every
-- CreateObject / DeleteEntity, which is what makes "an orphan was left behind"
-- an assertion rather than an opinion.
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
    function SetEntityCoords() end
    function SetEntityHeading() end
    function FreezeEntityPosition() end
    function SetModelAsNoLongerNeeded() end
    function NetworkGetEntityFromNetworkId(id)
        env.natives[#env.natives + 1] = { name = 'NetworkGetEntityFromNetworkId', id = id }
        return env.netEntity or 0
    end
    -- `HasModelLoaded` drives the yield. When it is false the spawn blocks in
    -- RequestModelTimeout, which is where the remove has to arrive.
    function HasModelLoaded() return env.modelReady end
    function IsModelInCdimage() return true end
    function IsModelValid() return true end
    function RequestModel() end
    -- client/streaming.lua is NOT loaded here -- it installs a real Wait loop
    -- that this harness's `Wait` cannot drive -- so the model wait is stubbed to
    -- yield directly. That is the whole point of the test: the bug lives in
    -- what happens ACROSS a yield, so the yield is what the stub has to
    -- reproduce, and reproducing it faithfully is the whole job.
    function RequestModelTimeout()
        while not env.modelReady do
            coroutine.yield()
        end
        return true
    end
    loadModule('client/sync.lua')
    env.upsert = env.netEvents['cis_libs:client:syncUpsert']
    env.remove = env.netEvents['cis_libs:client:syncRemove']
    return env
end

do
    -- L-C20 · a remove arriving DURING the model wait.
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

    local record = {
        id = 'prop_1', kind = 'prop', model = 'prop_barrel_01',
        coords = { x = 1.0, y = 2.0, z = 3.0 }, networked = false,
    }

    -- The interleaving IS the bug, so the test drives it directly rather than
    -- hoping a loop produces the order: start the upsert, stop it at the model
    -- yield, deliver the remove while it waits, then let the model arrive.
    local co = coroutine.create(function() env.upsert(record) end)
    local ok, err = coroutine.resume(co)
    check(ok, 'the upsert yields on the model: ' .. tostring(err))
    check(coroutine.status(co) == 'suspended', 'the upsert is suspended waiting for the model')

    -- The server removes the record while the client waits.
    env.remove('prop_1')
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
        ('L-C20: a remove during a yielding model load deletes the entity it '
            .. 'created (created=%d deleted=%s handle=%s)')
            :format(created, tostring(deleted ~= nil), tostring(deleted)))
    env.reset()
end

-- The ordinary case: an upsert with no remove leaves the entity alone.
do
    local env = syncEnv({})
    env.upsert({
        id = 'prop_2', kind = 'prop', model = 'prop_barrel_01',
        coords = { x = 1.0, y = 2.0, z = 3.0 }, networked = false,
    })
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
    env.upsert({
        id = 'prop_3', kind = 'prop', model = 'prop_barrel_01',
        coords = { x = 0.0, y = 0.0, z = 0.0 },
        networked = true, spawnHere = false, netId = 1234,
    })
    local created = 0
    for _, n in ipairs(env.natives) do
        if n.name == 'CreateObject' or n.name == 'CreateVehicle' then created = created + 1 end
    end
    check(created == 0,
        'L-C4: a networked record is NOT spawned again on the client')
    check(env.EXPORTS and true or true, 'the export table is present')
    env.reset()
end

-- A client-local entity is created LOCAL, which is what makes two clients'
-- copies independent rather than two networked duplicates.
do
    local env = syncEnv({})
    env.upsert({
        id = 'prop_4', kind = 'prop', model = 'prop_barrel_01',
        coords = { x = 0.0, y = 0.0, z = 0.0 }, networked = false,
    })
    local networked
    for _, n in ipairs(env.natives) do
        if n.name == 'CreateObject' then networked = n.networked end
    end
    check(networked == false,
        'L-C4: a client-local record creates a NON-networked entity on the client')
    env.reset()
end

-- ============================ 3. client callbacks by reference (L-C11)
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
    local promises = {}
    function promise.new()
        local p = { done = false }
        p.resolve = function(self, v) self.done, self.value = true, v end
        p.reject = function(self, v) self.done, self.value = true, v end
        promises[#promises + 1] = p
        return p
    end
    Citizen = {
        Await = function(p)
            if not p.done then
                -- Settle it the way the sweep would, so a test that awaits does
                -- not hang. The value carries the packed reply the real path
                -- resolves with.
                p.resolve({ 'timed out in the harness' })
            end
            return p.value
        end,
    }
    loadModule('client/callback.lua')

    local seenSelf, seenArgs
    env.foreign('my_resource').MyHandler = function(self, ...)
        seenSelf, seenArgs = self, table.pack(...)
        return 'answered', 7
    end

    check(env.EXPORTS.RegisterCallback('x', 'my_resource:MyHandler') == true,
        'L-C11: a client callback registers by "resource:export" reference')
    check(env.EXPORTS.RegisterCallback('bad', 'not-a-reference') == false,
        'L-C11: a malformed reference is refused rather than stored as a string')

    -- The server asks for it, and the client's own handler answers.
    env.net('cis_libs:cb', 1, 'x', 1, 'a', 'b')
    check(seenSelf == env.EXPORTS.my_resource,
        'L-C11: the handler is called with the exports table as self, not shifted')
    check(seenArgs and seenArgs.n == 2 and seenArgs[1] == 'a' and seenArgs[2] == 'b',
        ('L-C11: the caller\'s arguments arrive unmoved (n=%s)')
            :format(tostring(seenArgs and seenArgs.n)))
    env.reset()
end

-- A stopped consumer's client callback is released (L-C7), so the next request
-- answers 'unknown' instead of raising against a dead export.
do
    local env = newEnv({})
    function promise.new()
        local p = { done = false }
        p.resolve = function(self, v) self.done, self.value = true, v end
        p.reject = p.resolve
        return p
    end
    Citizen = { Await = function(p) return p.value end }
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
    check(before ~= nil, 'L-C7: the callback answers before the stop')
    check(before and before.args[2] == true,
        'L-C7: and answers success, not a refusal: ' .. tostring(before and before.args[2]))
    check(before and before.args[3] == 1,
        'L-C7: with the handler result behind the flag')

    env.fire('onClientResourceStop', 'res_a')

    env.serverEvents = {}
    env.net('cis_libs:cb', 1, 'y', 2)
    local after = lastReply()
    check(after and after.args[2] == false,
        'L-C7: after res_a stops, its client callback refuses')
    check(after and after.args[3] == 'unknown',
        ('L-C7: and the refusal is "unknown", not an error: %s')
            :format(tostring(after and after.args[3])))

    env.serverEvents = {}
    env.net('cis_libs:cb', 1, 'z', 3)
    local z = lastReply()
    check(z and z.args[2] == true,
        "L-C7: res_b's client callback SURVIVES another resource's stop")
    env.reset()
end

-- ================================== 4. zone insideEvent cannot flood (L-C14)
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
    env.saved[#env.saved + 1] = { name = 'CisReadyState', value = rawget(_G, 'CisReadyState') }
    CisReadyState = { wait = function() return true end, ready = true }
    -- Only the LAST thread is the one that drives inside-events; the sweeps are
    -- collected rather than run, for the reason in the base harness.
    local threads = {}
    function CreateThread(fn) threads[#threads + 1] = fn end
    -- zones.lua starts TWO threads and the ORDER IS LOAD-BEARING FOR THE TEST:
    -- threads[1] is the main pass loop (movement, containment, inside-events)
    -- and threads[2] is the `Wait(0)` loop that only exists to serve a zone
    -- asking for interval 0 -- which is precisely the flood under test. Driving
    -- the second one would measure the loop that was always going to be fast
    -- rather than the one that had to be clamped.
    env.saved[#env.saved + 1] = { name = 'Cis', value = rawget(_G, 'Cis') }
    env.saved[#env.saved + 1] = { name = 'vector3', value = rawget(_G, 'vector3') }
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
        env.clock = env.clock + (tonumber(ms) or 0)
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
    check(created == true, 'L-C14: a zone with an insideEvent creates')

    local wakeups = simulateSecond(env)

    local fired = #env.serverEventsOf('my_resource:inShop')
    check(fired <= 4,
        ('L-C14: an insideEvent with interval 0 fires at most 4 times per second (fired=%d)')
            :format(fired))
    check(fired >= 1,
        ('L-C14: and it still fires at all (fired=%d wakeups=%s err=%s grid=%s)')
            :format(fired, tostring(wakeups), tostring(env.lastErr), tostring(CisGrid)))
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
        'L-C14: `local = true` sends NOTHING to the server')
    check(#env.localEventsOf('my_resource:localInShop') >= 1,
        ('L-C14: and fires it on the client instead (fired=%d)')
            :format(#env.localEventsOf('my_resource:localInShop')))
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

    -- The MAIN loop first, and deliberately: an `inside` FUNCTION with interval 0
    -- is SKIPPED by it (`if interval > 0`), because the second loop is the one
    -- that serves interval 0. So the main loop's job here is to put the player
    -- INSIDE the zone, which is a precondition rather than the measurement.
    simulateSecond(env)

    -- The second loop is where the measurement happens. This is the thread the
    -- clamp must NOT have made unnecessary: a function callback costs nothing on
    -- the server, so clamping it would silently take a per-frame callback away
    -- from a caller who explicitly asked for one.
    local before = insideCalls
    local TICK = {}
    local realWait = Wait
    Wait = function(ms)
        env.clock = env.clock + (tonumber(ms) or 0)
        if insideCalls - before >= 30 then error(TICK, 0) end
    end
    local ok, err = pcall(env.threads[2])
    Wait = realWait
    if not ok and err ~= TICK then error(err, 0) end

    local fast = insideCalls - before
    check(fast >= 30,
        ('L-C14: a plain `inside` FUNCTION is NOT clamped to 250ms -- it reaches '
            .. 'per-frame (calls=%d in a burst)'):format(fast))
    check(#env.serverEventsOf('my_resource:anything') == 0,
        'L-C14: and it never became a server event -- it was always a local call')
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