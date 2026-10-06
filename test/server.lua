-- Server-side behaviour tests, under fengari with no FiveM server.
--
-- Same shape as test/client.lua and for the same reason: `TriggerClientEvent`
-- returns nothing, so a test that only asserts "it did not throw" cannot tell a
-- streaming pass that sent an upsert from one that sent nothing. Every client
-- event this harness sees is recorded, with the src it was aimed at, because
-- WHO was told WHAT is the entire contract of entity sync.
--
-- Loaded by test/run.js in its own Lua state, so globals saved here cannot leak
-- into the other suites.

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
local function newEnv(opts)
    opts = opts or {}
    local env = {
        sent = {},
        natives = {},
        lines = {},
        saved = {},
        clock = opts.clock or 0,
        players = opts.players or {},
        invoking = opts.invoking,
        threads = {},
        netOk = opts.netOk,
        entities = {},
        byNetId = {},
    }

    function env.print(fmt, ...)
        local text = select('#', ...) > 0 and string.format(fmt, ...) or tostring(fmt)
        env.lines[#env.lines + 1] = text
    end
    print = env.print

    for _, name in ipairs({
        'Config', 'Security', 'Logging', 'CisLog', 'CisInvokingAllowed',
        'CisSyncEnabled', 'exports', 'print', 'Wait', 'CreateThread',
        'GetGameTimer', 'GetPlayers', 'GetPlayerPed', 'GetEntityCoords',
        'GetCurrentResourceName', 'GetInvokingResource', 'AddEventHandler',
        'RegisterNetEvent', 'TriggerClientEvent', 'TriggerEvent', 'CisNetOn',
        'GetPlayerName', 'DropPlayer', 'GetResourceState',
        'NetworkGetEntityFromNetworkId', 'Entity', 'DoesEntityExist',
        'DeleteEntity', 'SetEntityCoords', 'SetEntityHeading',
        'SetNetworkedEntityLocallyVisible', 'SetNetworkedEntityLocallyInvisible',
        'promise', 'Citizen', 'collectgarbage',
    }) do
        env.saved[#env.saved + 1] = { name = name, value = rawget(_G, name) }
    end

    function CreateThread(fn)
        env.threads[#env.threads + 1] = fn
    end
    function Wait(ms)
        env.clock = env.clock + (tonumber(ms) or 0)
    end

    -- Run one of the collected threads for `passes` iterations of its loop.
    --
    -- The sync file's pass is `while true do ...; Wait(1000) end`, so calling
    -- the body directly never returns. `Wait` is where the loop goes round, so
    -- that is where the iteration is counted and where a private sentinel
    -- unwinds it. The sentinel is raised and caught INSIDE this function, so it
    -- never reaches the suite's error handling and never reads as a failure.
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
    function GetResourceState() return 'missing' end
    -- SRC-AWARE, because a stub that answers a name for every id makes "is this
    -- player connected" untestable: every src looks connected, so a guard that
    -- checks it passes for the wrong reason. This is the same change the contract
    -- suite got, and for the same reason.
    function GetPlayerName(src)
        if src == nil then return 'TestPlayer' end
        return env.players[src] and 'TestPlayer' or nil
    end
    function DropPlayer() end
    -- `collectgarbage` is a Lua builtin, but only the real one: fengari raises
    -- `lua_gc not implemented` for the 'count' form `GetDiagnostics` asks for, so
    -- every probe of that export was unreachable in this suite. A stub, because
    -- the memory figure is a diagnostic and not a behaviour under test.
    local realCollect = collectgarbage
    collectgarbage = function(opt)
        if opt == 'count' then return 64.0 end
        return realCollect(opt)
    end
    -- Event handlers are RECORDED, not dropped: the consumer-stop fix is
    -- entirely about what happens when `onResourceStop` fires, so the harness
    -- has to be able to fire one and a test has to be able to see the binding.
    env.handlers = {}
    function AddEventHandler(name, fn)
        env.handlers[name] = env.handlers[name] or {}
        env.handlers[name][#env.handlers[name] + 1] = fn
    end
    function env.fire(name, ...)
        for _, fn in ipairs(env.handlers[name] or {}) do fn(...) end
    end
    function RegisterNetEvent(name, fn)
        env.netEvents = env.netEvents or {}
        env.netEvents[name] = env.netEvents[name] or {}
        env.netEvents[name][#env.netEvents[name] + 1] = fn
    end
    -- The `source` global is what a net-event handler reads, so the harness
    -- sets it around a dispatch rather than passing it as an argument.
    function env.emit(name, src, ...)
        local saved = rawget(_G, 'source')
        source = src
        for _, fn in ipairs((env.netEvents or {})[name] or {}) do fn(...) end
        _G.source = saved
    end
    function TriggerEvent() end
    -- The plumbing `CisNetOn` provides, and only the plumbing: it registers the
    -- handler and injects `source` as the first argument, which is what the
    -- handler's shape depends on.
    --
    -- NOT the limiter. The real `CisNetOn`'s rate limiting and src validation
    -- are covered where they live, in server/security.lua; a test that needed a
    -- snapshot request to be rate-limited would be testing security.lua through
    -- a sync file, and a second implementation of it here would only prove that
    -- the copy agrees with itself.
    function CisNetOn(name, fn)
        RegisterNetEvent(name, function(...)
            return fn(source, ...)
        end)
        return true
    end
    -- `env.players` is a MAP keyed by src, which is how a test writes it
    -- (`{ [1] = {...}, [2] = {...} }`), so the KEYS are the ids. `ipairs` would
    -- yield the values -- tables -- and `tonumber(table)` is nil, which is how
    -- every position in the pass came back with a nil src.
    function GetPlayers()
        local out = {}
        for src in pairs(env.players) do
            out[#out + 1] = tostring(src)
        end
        table.sort(out)
        return out
    end
    -- Coordinates are per-SRC, because that is the question every streaming
    -- decision asks: is THIS player near that record. A single shared point
    -- would make the range tests meaningless.
    function GetPlayerPed(src) return (src or 0) + 1000 end
    -- ROUTING BUCKETS. A server native (ext/native-decls
    -- GetPlayerRoutingBucket.md, `ns: CFX, apiset: server`) returning the
    -- player's bucket id. Per-SRC like the coordinates, because "is this player
    -- in this bucket" is the question the streaming pass now asks.
    --
    -- The DEFAULT is 0, which is what a player with no bucket set is in, so a
    -- test that sets nothing behaves exactly as it did before this existed.
    function GetPlayerRoutingBucket(src)
        local p = env.players[src]
        local bucket = type(p) == 'table' and p.bucket or nil
        return tonumber(bucket) or 0
    end
    function GetEntityCoords(ped)
        local src = (ped or 0) - 1000
        local p = env.players[src]
        local c = type(p) == 'table' and p.coords or p
        return { x = c and c.x or 0.0, y = c and c.y or 0.0, z = c and c.z or 0.0 }
    end
    function joaat(s)
        if type(s) == 'number' then return s end
        local h = 0
        for i = 1, #s do h = (h * 31 + s:byte(i)) % 0x7FFFFFFF end
        return h
    end
    -- THE SERVER-SIDE NETWORKED SPAWN.
    --
    -- These are the natives the networked path is supposed to use, and every one
    -- of them is `apiset: server` in the CitizenFX definitions
    -- (tools/natives/natives_cfx.json) -- the server RPC that tells every client
    -- to make the SAME entity. Each records its arguments so a test can read which
    -- one was called with what, and allocates its own handle so two spawns are
    -- distinguishable.
    --
    -- `env.netOk = false` makes every creation fail, which is how a test tells
    -- "the server spawned one entity" apart from "every client makes its own".
    env.entitySeq = 0
    local function newEntity()
        env.entitySeq = env.entitySeq + 1
        local e = 77 + env.entitySeq
        env.entities[e] = { alive = true }
        return e
    end
    function CreateObjectNoOffset(hash, x, y, z, isNetwork, mission, doorFlag)
        local e = (not env.netOk) and 0 or newEntity()
        env.natives[#env.natives + 1] = {
            name = 'CreateObjectNoOffset', hash = hash, x = x, y = y, z = z,
            networked = isNetwork, mission = mission, door = doorFlag, entity = e,
        }
        return e
    end
    function CreateVehicleServerSetter(hash, vehicleType, x, y, z, heading)
        local e = (not env.netOk) and 0 or newEntity()
        env.natives[#env.natives + 1] = {
            name = 'CreateVehicleServerSetter', hash = hash,
            vehicleType = vehicleType, x = x, y = y, z = z, heading = heading, entity = e,
        }
        return e
    end
    function CreatePed(pedType, hash, x, y, z, heading, isNetwork, hostPed)
        local e = (not env.netOk) and 0 or newEntity()
        env.natives[#env.natives + 1] = {
            name = 'CreatePed', pedType = pedType, hash = hash,
            x = x, y = y, z = z, heading = heading,
            networked = isNetwork, hostPed = hostPed, entity = e,
        }
        return e
    end
    function SetEntityRoutingBucket(entity, bucket)
        env.natives[#env.natives + 1] =
            { name = 'SetEntityRoutingBucket', entity = entity, bucket = bucket }
    end
    function SetEntityOrphanMode(entity, mode)
        env.natives[#env.natives + 1] =
            { name = 'SetEntityOrphanMode', entity = entity, mode = mode }
    end

    -- Kept deliberately, and asserted NEVER CALLED. These three are
    -- `apiset: client`; a server file that calls them is the defect this section
    -- exists to close. Recording them rather than leaving them undefined turns a
    -- regression into a failed check with a readable message instead of a nil
    -- call that aborts the whole suite before anything is reported.
    function RequestModel() env.natives[#env.natives + 1] = { name = 'RequestModel' } end
    function HasModelLoaded() return true end
    function SetModelAsNoLongerNeeded() end
    function NetworkGetNetworkIdFromEntity(e)
        local netId = 4000 + (e or 0)
        env.byNetId[netId] = e
        return netId
    end
    function NetworkGetEntityFromNetworkId(netId)
        local e = env.byNetId[netId]
        if e and env.entities[e] and env.entities[e].alive then return e end
        return 0
    end
    function DoesEntityExist(e)
        local entry = env.entities[e]
        return (entry ~= nil and entry.alive == true) and true or false
    end
    function DeleteEntity(e)
        env.natives[#env.natives + 1] = { name = 'DeleteEntity', entity = e }
        if env.entities[e] then env.entities[e].alive = false end
    end
    function SetEntityCoords(entity, x, y, z)
        env.natives[#env.natives + 1] =
            { name = 'SetEntityCoords', entity = entity, x = x, y = y, z = z }
    end
    function SetEntityHeading(entity, heading)
        env.natives[#env.natives + 1] =
            { name = 'SetEntityHeading', entity = entity, heading = heading }
    end
    function FreezeEntityPosition() end
    -- The pre-4.5 spawn, recorded for the same reason: a server file that still
    -- calls CreateObject for every kind is the defect, not a style choice.
    function CreateObject(hash, x, y, z, networked)
        env.natives[#env.natives + 1] = {
            name = 'CreateObject', hash = hash, x = x, y = y, z = z, networked = networked,
        }
        if not env.netOk then return 0 end
        return newEntity()
    end
    -- A fresh exports table per env, exactly like the contracts harness. Each
    -- scenario loads the files again, and a table shared between them would let
    -- one scenario pass against another scenario's registrations.
    local EXPORTS = {}
    setmetatable(EXPORTS, {
        __call = function(_, name, fn)
            EXPORTS[name] = fn
        end,
    })
    env.EXPORTS = EXPORTS
    exports = EXPORTS

    function TriggerClientEvent(name, target, ...)
        local n = select('#', ...)
        local args = { n = n }
        for i = 1, n do args[i] = select(i, ...) end
        env.sent[#env.sent + 1] = { name = name, target = target, args = args }
    end

    -- THE PROMISES AND `Citizen.Await`, MATCHING THE REAL NATIVE.
    --
    -- There was no promise stub in this suite at all, so `AwaitCallbackClient`
    -- -- the server's only way to ask a client for a RETURN value -- was never
    -- executed by a single test. Everything about it was believed rather than
    -- known.
    --
    -- The real `Citizen.Await`, verified against citizenfx/fivem
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
    -- ONE value, and a rejection is a RAISE. `deferred:resolve(value)` also
    -- takes a single value and stores it in one slot with no `n`, so resolving
    -- with several arguments silently drops all but the first.
    env.promises = {}
    promise = {
        new = function()
            local p = { done = false, value = nil, rejected = false }
            p.resolve = function(self, v) self.done, self.value = true, v end
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
                -- THE CALLER IS PARKED HERE; the real scheduler yields and is
                -- resumed when the promise settles. `awaitHook` is how a test
                -- injects the reply DURING the await, which is the order
                -- production has -- answering afterwards would exercise a
                -- different code path and prove nothing.
                if type(env.awaitHook) == 'function' then
                    env.awaitHook(p)
                end
            end
            if not p.done then
                -- Nothing drove this thread. Settling with nil keeps the suite
                -- honest rather than hanging: the caller sees no answer, which
                -- is what would really have happened.
                p.done, p.value = true, nil
            end
            if p.rejected then
                error(p.value, 2)
            end
            return p.value
        end,
    }

    -- Everything a server file calls that this harness was not told about
    -- answers nil. The prefix guard keeps a typo in a global name raising, so a
    -- test can never pass against a stub standing in for something that does
    -- not exist.
    setmetatable(_G, {
        __index = function(_, key)
            if type(key) ~= 'string' then
                return nil
            end
            for _, prefix in ipairs({
                'Get', 'Is', 'Has', 'Set', 'Add', 'Remove', 'Does', 'Can',
                'Create', 'Delete', 'Register', 'Count',
            }) do
                if key:sub(1, #prefix) == prefix then
                    return function() return nil end
                end
            end
            return nil
        end,
    })
    env.saved[#env.saved + 1] = { name = '__metatable', value = getmetatable(_G) }

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

    -- The events aimed at one src, by name. `env.sentTo(1, 'x')` reads as the
    -- question every test here is actually asking.
    function env.sentTo(src, name)
        local out = {}
        for i = 1, #env.sent do
            local e = env.sent[i]
            if e.target == src and (name == nil or e.name == name) then
                out[#out + 1] = e
            end
        end
        return out
    end

    -- How many times one src was told to upsert a given record id.
    function env.upsertsTo(src, id)
        local n = 0
        for _, e in ipairs(env.sentTo(src, 'cis_libs:client:syncUpsert')) do
            local record = e.args[1]
            if record and record.id == id then
                n = n + 1
            end
        end
        return n
    end

    -- The wire identity of a record, from the payload the server actually sent.
    --
    -- A record now travels under `key` -- the caller's id namespaced by owner --
    -- and it is the key a remove carries, because it is the key the CLIENT keys
    -- its entities on. `upsertsTo` still matches on `id` because the payload
    -- carries both, but a remove has only one name for the record and it is not
    -- the caller's.
    --
    -- The payload is the only place the mapping exists outside the library, which
    -- makes this the honest place to read it.
    function env.wireKeyOf(id)
        for i = 1, #env.sent do
            local e = env.sent[i]
            if e.name == 'cis_libs:client:syncUpsert' then
                local record = e.args[1]
                if record and record.id == id and type(record.key) == 'string' then
                    return record.key
                end
            end
        end
        return nil
    end

    -- Resolve to the name a remove will carry. The `or id` fallback can only
    -- make a count go DOWN -- an unresolvable id matches nothing a server with
    -- namespacing would send -- so it can never turn a broken remove into a
    -- passing assertion. It exists so the failure reads as "counted 0", which is
    -- the symptom, rather than as a nil error inside the helper.
    local function wireName(id)
        return env.wireKeyOf(id) or id
    end

    function env.removesOf(id)
        local wanted = wireName(id)
        local n = 0
        for i = 1, #env.sent do
            local e = env.sent[i]
            if e.name == 'cis_libs:client:syncRemove' and e.args[1] == wanted then
                n = n + 1
            end
        end
        return n
    end

    -- The same question as `upsertsTo`, scoped to one src: how many times was
    -- THIS player told to drop that record. A remove broadcast to -1 is not a
    -- remove to anybody in particular, and counting those together would let a
    -- broken sweep read as a working one.
    function env.removesTo(src, id)
        local wanted = wireName(id)
        local n = 0
        for _, e in ipairs(env.sentTo(src, 'cis_libs:client:syncRemove')) do
            if e.args[1] == wanted then
                n = n + 1
            end
        end
        return n
    end

    -- T2 / ISOLATION FINDING. `json` is a FiveM-provided global, so fengari has
    -- no idea it exists. In the shared state this suite reached
    -- server/initialize.lua and had never been asked for it, because the
    -- `_G` fallback quietly answered nil and the ready line that calls
    -- json.encode was never reached on the paths these tests drive.
    --
    -- It IS reached here, so the suite now supplies the one function the server
    -- code actually calls. A stub that encodes nothing in particular is
    -- honest: the test cares that a table was serialisable, not that the
    -- serialiser matches FiveM's byte for byte.
    env.saved[#env.saved + 1] = { name = 'json', value = rawget(_G, 'json') }
    json = {
        encode = function(t)
            local parts = {}
            for k, v in pairs(t) do parts[#parts + 1] = ('%q:%s'):format(tostring(k), tostring(v)) end
            return '{' .. table.concat(parts, ',') .. '}'
        end,
        decode = function() return nil, 'decode is not stubbed' end,
    }

    -- T2 / ISOLATION FINDING. server/logging.lua is loaded HERE, inside the env,
    -- because it needs `exports` at load time and only this harness provides it.
    --
    -- It was never loaded at all before. `Logging` was a global left behind by an
    -- earlier suite in a shared lua_State, and server/sync.lua indexes it on its
    -- first error path. Nothing asserted the dependency -- it worked by accident,
    -- and the accident stopped working the moment the suites were given their own
    -- processes. Loading it here is the honest version of what every env was
    -- already relying on.
    -- `loadModule` is declared below this point, so the load is inline. Logging
    -- is already in the saved-globals list above, so env.reset puts the previous
    -- one back and one env cannot leak its Logging into the next.
    do
        -- Re-established immediately before the load. logging.lua calls
        -- `exports('LogInfo', ...)` at load time, so it has to be the callable
        -- proxy, and an env that has been through a reset can have had it
        -- cleared underneath it.
        exports = env.EXPORTS
        local chunk = assert(loadfile('./server/logging.lua'))
        chunk()
    end

    return env
end

local function loadModule(rel)
    local chunk = assert(loadfile('./' .. rel))
    chunk()
end

-- Load a server file with the globals it expects already in place. Split out
-- because almost every scenario here wants the same two files in the manifest's
-- order: security.lua decides the allow-list, sync.lua asks it.
local function loadSync(env)
    env.saved[#env.saved + 1] = { name = 'Config', value = rawget(_G, 'Config') }
    env.saved[#env.saved + 1] = { name = 'Security', value = rawget(_G, 'Security') }
    env.saved[#env.saved + 1] = { name = 'CisInvokingAllowed', value = rawget(_G, 'CisInvokingAllowed') }
    env.saved[#env.saved + 1] = { name = 'CisSyncEnabled', value = rawget(_G, 'CisSyncEnabled') }
    Config = CisDefaults.config()
    Security = CisDefaults.security()
    -- Default posture for these tests is permissive, so the allow-list is not
    -- what any of them is measuring.
    Security.AuthorizedResources = { 'cis_anyProduct' }
    env.invoking = 'cis_anyProduct'
    function CisInvokingAllowed() return true end
    function CisSyncEnabled() return true end
    loadModule('server/sync.lua')
    -- The file installs its exports on a fresh table each load, so a second
    -- scenario must not read the first scenario's.
    env.EXPORTS = exports
    return env
end

-- ================================================== 1. entity sync streaming
--
-- THE DEFECT. Static records were sent once, at creation time, to whoever was
-- within 80m AT THAT MOMENT. A player who joined a minute later, or walked up
-- to the entity a minute later, never received it -- the entity simply did not
-- exist for them, for the rest of the session, with nothing in any log. On a
-- server where the doors and the shop props are synced at boot and players join
-- afterwards, that is most of the map missing.
--
-- `networked` defaulted to true as well, so each in-range client spawned its
-- OWN networked copy: N clients near one synced prop produced N identical
-- networked props, each owned by nobody and visible to everyone.
--
-- The fix is a streaming pass: every second, tell each player about what is
-- near them and remove what is not. A `has` set per player is the whole
-- bookkeeping -- a player is told about an id once, and told to drop it when
-- they leave.
do
    -- A record created while nobody is anywhere near it, then a player walks
    -- in. This is the late-joiner case, and it is the one that used to produce
    -- nothing at all.
    local env = newEnv({ players = { [1] = { coords = { x = 5000.0, y = 5000.0, z = 0.0 } } } })
    loadSync(env)

    local id = env.EXPORTS.SyncCreate('prop', {
        model = 'prop_barrier_05a',
        coords = { x = 0.0, y = 0.0, z = 0.0 },
    })
    check(type(id) == 'string', 'a sync record gets an id')
    check(env.upsertsTo(1, id) == 0, 'nobody in range is told nothing at creation')

    -- The player walks up. One streaming pass.
    env.players[1] = { coords = { x = 10.0, y = 0.0, z = 0.0 } }
    check(#env.threads > 0, 'the sync file starts its streaming pass at load')
    env.tick()
    check(env.upsertsTo(1, id) == 1,
        'a player who walks into range is sent the static record')

    -- Walking in AGAIN must not resend. A pass every second that re-sends
    -- every nearby record forever is a per-second event storm against every
    -- client on the server.
    env.tick()
    check(env.upsertsTo(1, id) == 1,
        'a second pass does not resend a record the player already has')
    env.reset()
end

-- The other half: leaving the range has to remove the entity, or a client walks
-- away from a prop that stays in the world forever, client-local and permanent.
do
    local env = newEnv({ players = { [1] = { coords = { x = 10.0, y = 0.0, z = 0.0 } } } })
    loadSync(env)
    local id = env.EXPORTS.SyncCreate('prop', {
        model = 'prop_barrier_05a',
        coords = { x = 0.0, y = 0.0, z = 0.0 },
    })
    env.tick()
    check(env.upsertsTo(1, id) == 1, 'in range, the record is sent')

    env.players[1] = { coords = { x = 5000.0, y = 5000.0, z = 0.0 } }
    env.tick()
    check(env.removesOf(id) == 1, 'leaving the range sends a remove')

    -- And it is not re-sent on every subsequent pass while out of range.
    env.tick()
    check(env.upsertsTo(1, id) == 1, 'an out-of-range player is not sent it again')
    env.reset()
end

-- OWNERSHIP ON STOP. One resource stopping must take ITS OWN records and leave
-- every other resource's alone. A single-owner test cannot see this at all --
-- with one owner, "removed everything" and "removed its own" are the same
-- observation -- which is why this needed a second owner to exist at all, and
-- why the live harness needed a second owner before it could show the defect.
--
-- ASSERTED THROUGH WHAT A PLAYER RECEIVES, not through an internal count. What
-- a client is told is the thing that actually happened; a per-owner tally
-- would be the library marking its own homework.
do
    local env = newEnv({ players = { [1] = { coords = { x = 10.0, y = 0.0, z = 0.0 } } } })
    loadSync(env)

    local function ownAs(ownerName, id, x)
        env.invoking = ownerName
        local made = env.EXPORTS.SyncCreate('prop', {
            id = id,
            model = 'prop_barrier_05a',
            coords = { x = x, y = 0.0, z = 0.0 },
        })
        env.invoking = 'cis_anyProduct'
        return made
    end

    local mineA = ownAs('res_a', 'a-one', 0.0)
    local mineB = ownAs('res_b', 'b-one', 20.0)
    check(type(mineA) == 'string' and type(mineB) == 'string',
        'two resources each own a record')

    env.tick()
    check(env.upsertsTo(1, mineA) == 1 and env.upsertsTo(1, mineB) == 1,
        'the player standing between them is sent both')

    -- res_a stops.
    env.fire('onResourceStop', 'res_a')

    check(env.removesOf(mineA) == 1,
        'the stopped resource took its own record with it')

    -- WALK OUT OF RANGE. This is the assertion that has teeth, and it took a
    -- second pass to find. Counting records does not catch this defect: the
    -- reset at the end of the handler drops them SILENTLY, so a tally says
    -- "gone" exactly as it should whether the drop was announced or not.
    --
    -- The harm is on the client. A record the server forgets without sending a
    -- remove leaves every client that was told about it holding a prop forever:
    -- nobody owns it, nobody despawns it, and the player walks away from a
    -- world object that will not go. So the question is not "is the record
    -- gone" but "was anybody TOLD".
    env.players[1] = { coords = { x = 5000.0, y = 5000.0, z = 0.0 } }
    env.tick()
    check(env.removesOf(mineB) == 1,
        'the OTHER resource\'s record is still removed from the player who '
            .. 'walks out of range (a silent drop leaves them holding it forever)')

    -- And walking back re-sends it, which also proves the content index still
    -- resolves: a record left in `records` but dropped from `byContent` would
    -- allocate a SECOND id for the same content and spawn a duplicate.
    env.players[1] = { coords = { x = 10.0, y = 0.0, z = 0.0 } }
    env.tick()
    check(env.upsertsTo(1, mineB) == 2,
        'and it streams again when the player comes back, under the SAME id')
    env.reset()
end

-- Two players at different distances: the near one has it, the far one does not.
-- A single-player test cannot tell a range filter from "sent to everyone".
do
    local env = newEnv({
        players = {
            [1] = { coords = { x = 5.0, y = 0.0, z = 0.0 } },
            [2] = { coords = { x = 900.0, y = 0.0, z = 0.0 } },
        },
    })
    loadSync(env)
    local id = env.EXPORTS.SyncCreate('prop', {
        model = 'prop_barrier_05a',
        coords = { x = 0.0, y = 0.0, z = 0.0 },
    })
    env.tick()
    check(env.upsertsTo(1, id) == 1, 'the near player is sent the record')
    check(env.upsertsTo(2, id) == 0, 'the far player is not')
    env.reset()
end

-- `scope` widens the radius per record, and a vehicle synced at 200m has to
-- stream to a player 150m away.
do
    local env = newEnv({ players = { [1] = { coords = { x = 150.0, y = 0.0, z = 0.0 } } } })
    loadSync(env)
    local id = env.EXPORTS.SyncCreate('vehicle', {
        model = 'adder',
        coords = { x = 0.0, y = 0.0, z = 0.0 },
        scope = 200.0,
    })
    env.tick()
    check(env.upsertsTo(1, id) == 1, 'scope widens the streaming radius for that record')
    env.reset()
end

-- ====================================== 1b. routing buckets (C3)
--
-- The streaming pass asked ONE question per (player, record) pair: are these
-- close? It never asked which BUCKET either was in, and the whole file
-- contained no reference to `GetPlayerRoutingBucket` at all.
--
-- That is invisible on a server that does not use buckets, which is why it
-- survived: a player in bucket 0 and a player in bucket 2 standing at the same
-- coordinates are indistinguishable to a pure distance test. So the entity
-- synced for one instance appears in the other -- a door in a separate world, a
-- shop prop duplicated into a racing track, a staged set leaking into the main
-- world. And it is not a ghost that can be despawned on request, because the
-- server genuinely believes the player should see it.
--
-- Two records at the same coordinates in different buckets is the shape that
-- proves it: a distance-only filter cannot tell them apart.
do
    local env = newEnv({
        players = {
            [1] = { coords = { x = 5.0, y = 0.0, z = 0.0 }, bucket = 0 },
            [2] = { coords = { x = 5.0, y = 0.0, z = 0.0 }, bucket = 2 },
        },
    })
    loadSync(env)

    -- Two entities at the SAME coordinates, in different worlds.
    local main = env.EXPORTS.SyncCreate('prop', {
        model = 'prop_barrier_05a',
        coords = { x = 0.0, y = 0.0, z = 0.0 },
    })
    local instanced = env.EXPORTS.SyncCreate('prop', {
        model = 'prop_barrier_05a',
        coords = { x = 0.0, y = 0.0, z = 0.0 },
        bucket = 2,
    })
    env.tick()

    check(env.upsertsTo(1, main) == 1, 'C3: a bucket-0 player is sent the bucket-0 record')
    check(env.upsertsTo(1, instanced) == 0,
        ('C3: and NOT the record from another bucket (got %d)')
            :format(env.upsertsTo(1, instanced)))
    check(env.upsertsTo(2, instanced) == 1,
        'C3: the bucket-2 player IS sent the bucket-2 record')
    check(env.upsertsTo(2, main) == 0,
        ('C3: and not the bucket-0 one (got %d)'):format(env.upsertsTo(2, main)))

    -- A player who is MOVED between buckets loses what they were told, without
    -- walking a metre. Their set has to be swept on the bucket change exactly as
    -- it is on the distance change, or the entity stays in the world they just
    -- left.
    local beforeMove = env.upsertsTo(1, instanced)
    env.players[1].bucket = 2
    env.tick()
    check(env.removesTo(1, main) == 1,
        ('C3: moving to another bucket removes what that bucket did not hold (got %d)')
            :format(env.removesTo(1, main)))
    check(env.upsertsTo(1, instanced) == beforeMove + 1,
        ('C3: and brings in what its new bucket does hold (before=%d after=%d)')
            :format(beforeMove, env.upsertsTo(1, instanced)))

    env.reset()
end

-- The default has to stay 0, or every record created before this existed would
-- be invisible on a server whose players sit in the main bucket.
do
    local env = newEnv({ players = { [1] = { coords = { x = 5.0, y = 0.0, z = 0.0 } } } })
    loadSync(env)
    local id = env.EXPORTS.SyncCreate('prop', {
        model = 'prop_barrier_05a',
        coords = { x = 0.0, y = 0.0, z = 0.0 },
    })
    env.tick()
    check(env.upsertsTo(1, id) == 1,
        'C3: a record with no bucket belongs to bucket 0, and streams as it always did')
    env.reset()
end

-- ============================================ 2. networked defaults to FALSE
--
-- D2. `networked` defaulted to true, so every in-range client spawned its own
-- networked copy. Two players standing next to one synced prop saw two of it,
-- and neither was the owner -- they were both unowned networked entities that
-- any player could drive away and no client could despawn.
--
-- A client-local entity is invisible to everyone else, which is what a
-- range-filtered sync actually wants: the server decides who should SEE it.
do
    local env = newEnv({ players = { [1] = { coords = { x = 5.0, y = 0.0, z = 0.0 } } } })
    loadSync(env)
    local id = env.EXPORTS.SyncCreate('prop', {
        model = 'prop_barrier_05a',
        coords = { x = 0.0, y = 0.0, z = 0.0 },
    })
    env.tick()
    local upserts = env.sentTo(1, 'cis_libs:client:syncUpsert')
    check(#upserts == 1, 'the streaming pass sent one upsert')
    local record = upserts[1] and upserts[1].args[1]
    check(record and record.networked == false,
        'a synced entity is client-local by default, not networked')
    check(id ~= nil and type(id) == 'string', 'the record still has an id')
    env.reset()
end

-- A caller that explicitly asks for a networked entity still gets one, and the
-- server spawns it ONCE and sends the netId rather than the coordinates. That is
-- the difference: a networked entity belongs to the server, so every client
-- receives the same one rather than making its own.
do
    local env = newEnv({
        players = { [1] = { coords = { x = 5.0, y = 0.0, z = 0.0 } } },
        netOk = true,
    })
    loadSync(env)
    env.EXPORTS.SyncCreate('prop', {
        model = 'prop_barrier_05a',
        coords = { x = 0.0, y = 0.0, z = 0.0 },
        networked = true,
    })
    env.tick()
    local upserts = env.sentTo(1, 'cis_libs:client:syncUpsert')
    local record = upserts[1] and upserts[1].args[1]
    check(record and record.networked == true,
        'a caller asking for networked=true still gets one')
    check(record and record.netId ~= nil,
        'a networked record carries the netId of the entity the server spawned')
    check(record and record.spawnHere == false,
        'a networked record tells the client NOT to spawn its own copy')

    -- Spawned ONCE, on the server. One creation call for two records of the same
    -- shape would be the duplicate bug wearing a different hat. Counted across
    -- all three server creation natives, so this asserts the property rather
    -- than the particular native that happens to implement it today.
    local spawns = 0
    for i = 1, #env.natives do
        local n = env.natives[i].name
        if n == 'CreateObjectNoOffset' or n == 'CreateVehicleServerSetter'
            or n == 'CreatePed' or n == 'CreateObject' then
            spawns = spawns + 1
        end
    end
    check(spawns == 1,
        'a networked entity is spawned once, on the server, not once per client')
    local made
    for i = 1, #env.natives do
        if env.natives[i].name == 'CreateObjectNoOffset' then made = env.natives[i] end
    end
    check(made ~= nil and made.networked == true,
        'the server-side spawn is itself networked, so every client shares it')
    env.reset()
end

-- A networked spawn that FAILS must not lose the entity. Falling back to a
-- client-local copy is wrong-but-visible; dropping the record is wrong-and-
-- invisible, and invisible is the one that gets reported as "the prop is
-- missing and nothing is in the console".
do
    local env = newEnv({
        players = { [1] = { coords = { x = 5.0, y = 0.0, z = 0.0 } } },
        netOk = false,
    })
    loadSync(env)
    local id = env.EXPORTS.SyncCreate('prop', {
        model = 'prop_barrier_05a',
        coords = { x = 0.0, y = 0.0, z = 0.0 },
        networked = true,
    })
    check(id ~= nil, 'a failed networked spawn still yields a record')
    env.tick()
    local upserts = env.sentTo(1, 'cis_libs:client:syncUpsert')
    check(#upserts == 1,
        'a record whose networked spawn failed is still streamed to the player')
    env.reset()
end

-- ==================================== 3. the payload is only what is needed
--
-- The whole record went over the wire, `print` (the content fingerprint) and
-- `rev` included. `print` is an internal index key that can be hundreds of
-- bytes of concatenated field values, it is identical for every client, and it
-- is of no use to any of them.
do
    local env = newEnv({ players = { [1] = { coords = { x = 5.0, y = 0.0, z = 0.0 } } } })
    loadSync(env)
    local id = env.EXPORTS.SyncCreate('prop', {
        model = 'prop_barrier_05a',
        coords = { x = 0.0, y = 0.0, z = 0.0 },
    })
    env.tick()
    local upserts = env.sentTo(1, 'cis_libs:client:syncUpsert')
    local record = upserts[1] and upserts[1].args[1]
    check(record ~= nil, 'the streaming pass sent a record')
    check(record and record.print == nil,
        'the content fingerprint is not sent to clients')
    check(record and record.id == id, 'the record still carries its id')
    check(record and record.coords ~= nil and record.coords.x == 0.0,
        'the record carries the coordinates the client needs')
    check(record and record.model == 'prop_barrier_05a',
        'the record carries the model the client needs')
    env.reset()
end

-- ==================================== 4. removal and the consumer stop sweep
do
    local env = newEnv({ players = { [1] = { coords = { x = 5.0, y = 0.0, z = 0.0 } } } })
    loadSync(env)
    local id = env.EXPORTS.SyncCreate('prop', {
        model = 'prop_barrier_05a',
        coords = { x = 0.0, y = 0.0, z = 0.0 },
    })
    env.tick()
    check(env.upsertsTo(1, id) == 1, 'the player holds the entity')

    check(env.EXPORTS.SyncRemove(id) == true, 'SyncRemove reports success for a known id')
    check(env.EXPORTS.SyncRemove(id) == false,
        'SyncRemove reports false for an id it does not hold, distinct from true')

    -- After a removal the streaming pass must not resurrect it. The `has` set
    -- has to be cleared as well as the record, or every player is re-sent a
    -- despawned entity on the next tick and it reappears forever.
    env.tick()
    check(env.upsertsTo(1, id) == 1,
        'a removed record is not streamed back on the next pass')
    env.reset()
end

-- A record without coords is refused, not defaulted to the origin. Defaulting
-- would broadcast it to every player on the server.
do
    local env = newEnv({})
    loadSync(env)
    check(env.EXPORTS.SyncCreate('prop', { model = 'prop_barrier_05a' }) == nil,
        'a record with no coords is refused')
    check(env.EXPORTS.SyncCreate('prop', { model = 'x', coords = { y = 1.0 } }) == nil,
        'a record missing an x is refused')
    env.reset()
end


-- ================================== 6. cis_debug runs for an in-game admin
--
-- The permission check asked `CisRegistry.resolve('framework')` for a
-- `HasPermission` field. That is the export, not the method table, so the field
-- was nil, the `and` chain short-circuited to a refusal, and an in-game admin
-- got NOTHING: no output, no error, no trace. The command an operator is told to
-- run in game was dead in game.
do
    local env = newEnv({})
    Config = CisDefaults.config()
    Security = CisDefaults.security()
    loadModule('server/security.lua')
    loadModule('server/proxy.lua')

    -- The command handler, captured at registration. TWO commands live in
    -- initialize.lua (cis_debug and cis_doctor); the last one registered is
    -- not cis_debug.
    local commandsByName = {}
    local savedRegister = RegisterCommand
    RegisterCommand = function(name, fn) commandsByName[name] = fn end
    -- server/player.lua defines CisJobCount and the job histogram; cis_debug
    -- prints a count from it, so the command cannot run without it.
    loadModule('server/player.lua')
    loadModule('server/initialize.lua')
    RegisterCommand = savedRegister
    local command = commandsByName['cis_debug']

    check(command ~= nil, 'cis_debug is registered')
    check(commandsByName['cis_doctor'] ~= nil, '7.14: cis_doctor is registered')
    if not command then
        env.reset()
        return
    end

    -- No framework at all: a player is refused, and nothing is printed.
    local before = #env.lines
    command(1)
    check(#env.lines == before,
        'with no framework, an in-game call prints nothing')

    -- A framework that grants admin to src 1.
    local exported = env.EXPORTS
    exported.cis_core = {
        CisCoreFramework = function()
            return {
                HasPermission = function(src, permission)
                    return src == 1 and permission == 'admin'
                end,
            }
        end,
    }
    check(CisRegistry.register('framework', 'cis_core:CisCoreFramework'),
        'a framework provider registers for the debug command test')
    CisRegistry.invalidate('framework')

    before = #env.lines
    local threw = not pcall(command, 1)
    check(not threw, 'cis_debug does not throw for an in-game admin')
    check(#env.lines > before,
        ('cis_debug PRINTS for an in-game admin (lines=%d)'):format(#env.lines - before))

    local found = false
    for i = before + 1, #env.lines do
        if env.lines[i]:find('ready=', 1, true) then found = true end
    end
    check(found, 'and the output is the diagnostic block, not a trace')

    -- A player who is not an admin is still refused, with no output.
    before = #env.lines
    command(2)
    check(#env.lines == before, 'a player without the permission still gets nothing')

    -- The console, which has no src, always gets the block.
    env.lines = {}
    command(0)
    check(#env.lines > 0, 'the console always gets the block')
    CisRegistry.releaseOwner('cis_core')
    env.reset()
end

-- ==================================== 7. CisNetOn binds each event name once
--
-- `CisNetOn(name, 'res:export')` called `RegisterNetEvent(name, ...)` on every
-- registration. FiveM's RegisterNetEvent APPENDS a handler rather than replacing
-- one, so a consumer that restarts five times had five live handlers on the same
-- event -- and after a restart, the first four point at exports of a resource
-- that no longer exists.
--
-- That is not four wasted calls. Each stale handler raised on every single
-- invocation, inside its pcall, and each raise went to `Logging.AutoLogError`
-- with the event name attached. So a resource that restarts a few times turns
-- one client action into a burst of identical error lines -- and the operator
-- looking at that console is being told the wrong thing, because the handler
-- they would go and fix is the one that is working.
do
    local env = newEnv({})
    Config = CisDefaults.config()
    Security = CisDefaults.security()

    -- The harness's RegisterNetEvent APPENDS, as FiveM does. A test that
    -- models it as "replace" cannot see the bug at all.
    env.exported = {}
    exports.cis_shop = env.exported
    local calls = 0
    env.exported.OnBuy = function(_, src)
        calls = calls + 1
    end

    loadModule('server/security.lua')

    check(CisNetOn('cis_shop:buy', 'cis_shop:OnBuy') == true,
        'a resource:export handler registers')
    check(CisNetOn('cis_shop:buy', 'cis_shop:OnBuy') == true,
        'registering the SAME name again is accepted, not refused')
    check(#(env.netEvents['cis_shop:buy'] or {}) == 1,
        ('but the net event is bound ONCE, not once per registration (bound=%d)')
            :format(#(env.netEvents['cis_shop:buy'] or {})))

    -- Firing it invokes the handler exactly once.
    env.emit('cis_shop:buy', 5, 1)
    check(calls == 1,
        ('one client action runs the handler ONCE (calls=%d)'):format(calls))
    env.reset()
end

-- ============================== a missing export is a REFUSAL, not a raise
--
-- FOUND ON A LIVE SERVER, not in the suite. `exports[resource][name]` against a
-- resource that IS running but does not export `name` RAISES in FiveM --
-- "No such export handleFile in resource cis_dispatch" -- it does not return
-- nil. So this line:
--
--     self = exports[resource]
--     handler = self and self[exportName]
--
-- guards the WRONG case. It covers a resource that is not running, where `self`
-- is nil, and says nothing about an export missing from one that is. The raise
-- happens on the very line the guard was written to make safe, and it escapes
-- CisNetOn before the "registered nothing" refusal underneath can run -- so it
-- propagates into the CONSUMER's own boot path and that consumer's remaining
-- registrations may never happen.
--
-- 29 distinct exports across 6 resources did exactly this on a live server.
--
-- THE STUB REPLICATES THE FIVE BEHAVIOUR rather than using a plain table. A
-- plain table returns nil for a missing key, which IS the defect -- a stub more
-- forgiving than the runtime passes against this bug and certifies it, which is
-- the same trap as a `type(x)=='function'` check meeting a stub that returns 1.
do
    local env = newEnv({})
    Config = CisDefaults.config()
    Security = CisDefaults.security()

    -- Stub Logging itself, rather than chasing where its output goes.
    -- server/logging.lua is never loaded by this suite, so `Logging` is whatever
    -- survived from an earlier suite and there is nothing here to capture. What
    -- is under test is what security.lua REPORTS, not how the logger prints it.
    local logged = {}
    env.saved[#env.saved + 1] = { name = 'Logging', value = rawget(_G, 'Logging') }
    env.saved[#env.saved + 1] = { name = 'CisLog', value = rawget(_G, 'CisLog') }
    Logging = setmetatable({}, {
        __index = function(_, key)
            return function(message)
                logged[#logged + 1] = { key = key, message = message }
            end
        end,
    })
    CisLog = function() end

    -- A resource that IS running and DOES export OnBuy -- and RAISES, like
    -- FiveM, for anything it does not export.
    local rigid = setmetatable({}, {
        __index = function(_, key)
            error(('No such export %s in resource cis_rigid'):format(tostring(key)), 2)
        end,
    })
    rigid.OnBuy = function(_, src) env.buyHits = (env.buyHits or 0) + 1 end
    exports.cis_rigid = rigid

    loadModule('server/security.lua')

    local ok, result = pcall(CisNetOn, 'cis_rigid:buy', 'cis_rigid:NotExported')
    check(ok,
        'a missing export is REFUSED, not raised -- the consumer keeps booting')
    check(result == false,
        'and the refusal is false, so the caller has something to act on')

    -- The message must name the reference that failed. "registered nothing"
    -- without saying WHAT leaves an operator guessing which of thirty
    -- registrations is broken.
    local found = false
    for _, entry in ipairs(logged) do
        if tostring(entry.message):find('cis_rigid', 1, true) then found = true end
    end
    check(found, 'and the error names the reference that failed')

    -- An export that DOES exist must still bind and still fire, or "fix" the
    -- raise by refusing everything would pass every assertion above.
    check(CisNetOn('cis_rigid:buy', 'cis_rigid:OnBuy') == true,
        'an export that exists still registers')
    env.emit('cis_rigid:buy', 5, 1)
    check(env.buyHits == 1,
        ('and still fires exactly once (hits=%s)'):format(tostring(env.buyHits)))

    -- A resource that is NOT running at all is the case the old guard covered,
    -- and must keep answering false rather than raising.
    local ok2, result2 = pcall(CisNetOn, 'cis_absent:ev', 'cis_absent:Nope')
    check(ok2 and result2 == false,
        'a resource that is not running is still a plain false')

    env.reset()
end

-- ============================== T8 · the boot self-check, and its own promise
--
-- The block's entire value is that it is ACTIONABLE. A check that reports a
-- problem without saying what to change has moved the work from the operator to
-- whoever wrote it, which is the opposite of what a boot self-check is for. So
-- the last assertion here is the important one: EVERY problem line is followed
-- by a line that names the change.
do
    local env = newEnv({})
    Config = CisDefaults.config()
    Security = CisDefaults.security()

    -- A three-resource world: one that needs a capability nobody provides, one
    -- that names a slot that does not exist, and one that is simply fine.
    local RESOURCES = {
        'cis_core', 'cis_needs_db', 'cis_typo_slot', 'cis_fine', 'cis_libs',
    }
    local REQUIREMENTS = {
        cis_needs_db = 'database',
        cis_typo_slot = 'databse',
    }
    env.saved[#env.saved + 1] = { name = 'GetNumResources', value = rawget(_G, 'GetNumResources') }
    env.saved[#env.saved + 1] = { name = 'GetResourceByFindIndex', value = rawget(_G, 'GetResourceByFindIndex') }
    env.saved[#env.saved + 1] = { name = 'GetResourceMetadata', value = rawget(_G, 'GetResourceMetadata') }
    env.saved[#env.saved + 1] = { name = 'GetResourceState', value = rawget(_G, 'GetResourceState') }
    env.saved[#env.saved + 1] = { name = 'SetTimeout', value = rawget(_G, 'SetTimeout') }

    GetNumResources = function() return #RESOURCES end
    GetResourceByFindIndex = function(i) return RESOURCES[i + 1] end
    GetResourceMetadata = function(name, key)
        if key == 'cis_requires' then return REQUIREMENTS[name] end
        return nil
    end
    GetResourceState = function() return 'started' end

    -- Captured rather than run on a timer: the check is the thing under test,
    -- so the test drives it.
    local scheduled
    SetTimeout = function(ms, fn) scheduled = { ms = ms, fn = fn } end

    -- A provider that RESOLVES but hands back a method table missing most of its
    -- contract. This is the real shape -- a resource in another repo exporting
    -- a table -- and it is the one no test inside THIS repository can catch,
    -- because the table comes from outside. It has to be a table provider, not
    -- a bare callable: a bare callable is cached as `resolved` without ever
    -- caching `methods`, so CisRegistry.missing() answers nil for it and the
    -- check would be blind to exactly the case it exists for.
    exports.cis_doortest = {
        Get = function() return { state = function() end, lock = function() end } end,
    }
    CisRegistry.register('doors', 'cis_doortest:Get')

    loadModule('server/selfcheck.lua')

    check(scheduled ~= nil and scheduled.ms == 20000,
        'T8: the check is scheduled on a 20s grace period, not run at once')
    check(type(scheduled.fn) == 'function', 'T8: and it is a real callback')

    env.lines = {}
    scheduled.fn()

    local body = table.concat(env.lines, '\n')
    check(body:find('cis_needs_db', 1, true) ~= nil,
        'T8: a consumer whose required capability has no provider is named')
    check(body:find('no provider is registered', 1, true) ~= nil,
        'T8: and it says the capability has no provider')
    check(body:find('cis_typo_slot', 1, true) ~= nil,
        'T8: a consumer naming a slot that does not exist is named')
    check(body:find('not a slot this library knows', 1, true) ~= nil,
        'T8: and it says the slot is unknown, rather than blaming the provider')
    check(body:find('missing:', 1, true) ~= nil,
        'T8: a slot that resolved but is missing a method is reported')

    -- THE PROMISE. Every line that reports a problem must be followed by one
    -- that names the change. Counted over the whole block rather than per
    -- assertion, because a check that names the fix for one of three problems
    -- reads identically to one that names all three.
    local problems, fixes = 0, 0
    for _, l in ipairs(env.lines) do
        if l:find('[x]', 1, true) then problems = problems + 1 end
        if l:find('fix:', 1, true) then fixes = fixes + 1 end
    end
    check(problems >= 3, ('T8: the block reported the problems (lines=%d)'):format(problems))
    check(fixes >= problems,
        ('T8: every problem line is followed by one that names the change (problems=%d fixes=%d)')
            :format(problems, fixes))

    -- And it does not cry wolf. A resource with no requirements and a slot with
    -- nothing missing must produce no problems at all -- a self-check that always
    -- finds something is one the operator learns to skip.
    --
    -- The doors provider is REPLACED with a complete one first. Same owner, so
    -- re-registering is the update path rather than a conflict -- which is also
    -- how a real fix would land. Without it this pass would still find the
    -- half-built provider, and the "clean install" assertion would end up
    -- asserting that the check lies.
    env.lines = {}
    RESOURCES = { 'cis_libs', 'cis_fine' }
    local complete = {}
    for method in pairs(CisRegistry.SLOTS.doors) do complete[method] = function() end end
    exports.cis_doortest.Get = function() return complete end
    CisRegistry.register('doors', 'cis_doortest:Get')
    scheduled.fn()
    local quiet = table.concat(env.lines, '\n')
    check(quiet:find('[x]') == nil, 'T8: a clean install reports no problems')
    check(quiet:find('no capability problems found', 1, true) ~= nil,
        'T8: and says so explicitly, so the block being quiet is legible')

    env.reset()
end

-- A DIFFERENT event name is a different handler, and must not be collapsed.
do
    local env = newEnv({})
    Config = CisDefaults.config()
    Security = CisDefaults.security()
    exports.cis_shop = { OnBuy = function() end, OnSell = function() end }
    loadModule('server/security.lua')
    CisNetOn('cis_shop:buy', 'cis_shop:OnBuy')
    CisNetOn('cis_shop:sell', 'cis_shop:OnSell')
    check(#(env.netEvents['cis_shop:buy'] or {}) == 1, 'the first name is bound once')
    check(#(env.netEvents['cis_shop:sell'] or {}) == 1, 'a DIFFERENT name is bound separately')
    env.reset()
end

-- ================================== 8. a rate-limited flood warns once
--
-- Every limited event logged on the `cheating` channel with `ping = true`. A
-- client firing one event in a loop at 60Hz produced 52 log lines a second and
-- 52 Discord posts a second -- which is a denial of service against the
-- operator's console AND against the webhook, from the very code that exists to
-- detect an attack. The signal that matters is "this is happening", and it is
-- said once per (src, event) per window, with the count attached.
do
    local env = newEnv({})
    Config = CisDefaults.config()
    Security = CisDefaults.security()
    local warned = {}
    env.saved[#env.saved + 1] = { name = 'CisLog', value = rawget(_G, 'CisLog') }
    CisLog = function(level, message, channel)
        warned[#warned + 1] = { level = level, message = message, channel = channel }
    end
    loadModule('server/security.lua')

    -- A hundred limited events from one src on one event name.
    local limited = 0
    for _ = 1, 100 do
        if not CisRateOk(1, 'cis_shop:buy', 1000, 8) then
            limited = limited + 1
        end
    end
    check(limited == 92, ('the limiter really did refuse 92 of 100 (refused=%d)'):format(limited))
    env.reset()
end

-- The warning itself, through the net-event path where it is produced.
do
    local env = newEnv({})
    Config = CisDefaults.config()
    Security = CisDefaults.security()
    local logged = {}
    env.saved[#env.saved + 1] = { name = 'CisLog', value = rawget(_G, 'CisLog') }
    CisLog = function(level, message, channel)
        logged[#logged + 1] = { level = level, message = message, channel = channel }
    end
    local reported = {}
    env.saved[#env.saved + 1] = { name = 'CisSecurityReport', value = rawget(_G, 'CisSecurityReport') }

    exports.cis_shop = { OnBuy = function() end }
    loadModule('server/security.lua')

    -- Rebind CisSecurityReport AFTER the load, because security.lua defines it
    -- at load and the spy has to see the escalations it triggers.
    function CisSecurityReport(src, reason)
        reported[#reported + 1] = { src = src, reason = reason }
        return true
    end

    check(CisNetOn('cis_shop:buy', 'cis_shop:OnBuy', { maxHits = 4, windowMs = 1000 }) == true,
        'the handler registers with a tight limit')

    for _ = 1, 100 do env.emit('cis_shop:buy', 5, 1) end

    -- Nothing yet: the line is emitted when the window ROLLS, so the count in
    -- it is the window's real total rather than "at least N so far".
    check(#logged == 0,
        ('a flood inside one window logs nothing per event (logs=%d)'):format(#logged))

    -- A flood big enough to matter escalates to the drop handler.
    for _ = 1, 400 do env.emit('cis_shop:buy', 5, 1) end
    check(#reported == 1,
        ('a sustained flood escalates to CisSecurityReport ONCE per window (reports=%d)')
            :format(#reported))
    if reported[1] then
        check(reported[1].reason:find('cis_shop:buy', 1, true) ~= nil,
            'the escalation names the event')
    end

    -- The next window rolls, and that is when the console line is emitted --
    -- ONE line, carrying the total. The clock is advanced explicitly because the
    -- harness has no real time: the roll is the whole mechanism under test, and
    -- a test that never crosses a window boundary would assert nothing about it.
    local before = #logged
    env.clock = env.clock + 1500
    for _ = 1, 40 do env.emit('cis_shop:buy', 5, 1) end
    -- One more drop in the NEXT window: that is what emits the previous
    -- window's line, which is why the state has to survive the roll.
    env.clock = env.clock + 1500
    env.emit('cis_shop:buy', 5, 1)
    local rolled = #logged - before
    check(rolled >= 1, 'the window roll produces a warning')
    check(rolled <= 2,
        ('and it is ONE line per window, not one per event (lines=%d)'):format(rolled))
    if logged[before + 1] then
        local m = logged[before + 1].message
        check(m:find('cis_shop:buy', 1, true) ~= nil,
            'the warning names the event that was limited')
        check(m:find('5', 1, true) ~= nil,
            'and names the source it came from')
        check(m:match('%d+ events dropped') ~= nil,
            'and carries the number of events dropped: ' .. m)
        check(logged[before + 1].channel == 'cheating',
            'on the cheating channel, which is where an operator looks')
    end
    env.reset()
end

-- ============================ 9. a consumer's stop releases its own records
--
-- cis_libs runs in its OWN VM, so a callback outlives the resource that
-- registered it -- silently, and until the process restarts.
--
-- The specific damage here is a name that stays registered after its export is
-- gone: every call raises inside the pcall and the caller gets `false, 'error'`,
-- which reads as "the handler has a bug" and sends the consumer to look at their
-- own code. It also blocks the resource from re-registering the name on restart,
-- because the dead one is still holding it.
--
-- The other half is what must NOT happen: another resource's callbacks have to
-- survive. A sweep that took everything would be a different bug and an easier
-- one to write.
do
    local env = newEnv({})
    Config = CisDefaults.config()
    Security = CisDefaults.security()
    loadModule('server/security.lua')
    loadModule('server/proxy.lua')
    -- callback.lua registers RegisterCallback/CallCallback, and it needs the
    -- rate limiter security.lua provides, hence the order.
    loadModule('server/callback.lua')

    env.invoking = 'res_a'
    check(env.EXPORTS.RegisterCallback('a:one', function() return 'from a' end) == true,
        'res_a registers a callback')
    env.invoking = 'res_b'
    check(env.EXPORTS.RegisterCallback('b:one', function() return 'from b' end) == true,
        'res_b registers a callback')

    local function callLocal(name)
        local got
        env.EXPORTS.CallCallback(name, function(ok, value) got = { ok = ok, value = value } end)
        return got
    end

    check(callLocal('a:one').ok == true, 'res_a\'s callback answers before the stop')
    check(callLocal('b:one').ok == true, 'res_b\'s callback answers before the stop')

    -- res_a stops.
    env.fire('onResourceStop', 'res_a')

    local a = callLocal('a:one')
    check(a.ok == false, 'after res_a stops, its callback is released')
    check(tostring(a.value):find('unknown', 1, true) ~= nil,
        'and answers "unknown", not "error" -- a consumer must be told its wiring '
            .. 'is wrong, not that its handler threw: ' .. tostring(a.value))
    check(callLocal('b:one').ok == true,
        "res_b's callback SURVIVES another resource's stop")

    -- And the name is bindable again, which is the half that is easy to miss: a
    -- restarted resource registering the same name must not be refused against
    -- its own dead handler.
    env.invoking = 'res_a'
    check(env.EXPORTS.RegisterCallback('a:one', function() return 'from a again' end) == true,
        'a restarted resource can register the same name again')
    check(callLocal('a:one').value == 'from a again',
        'and the restarted handler is the one that answers')
    env.reset()
end

-- ============================================ 10. net bindings and the stop
-- The net-event half of the same fix. A resource that stops must not keep the
-- name it bound: FiveM cannot unbind a net event, so the handler survives and now
-- dispatches to nothing -- which is the right outcome (accept and ignore, never
-- raise) -- but the NAME must become free again, or a resource that stops and
-- restarts is told it is losing a conflict with something that no longer exists.
do
    local env = newEnv({})
    Config = CisDefaults.config()
    Security = CisDefaults.security()
    exports.res_a = { OnBuy = function() end }
    exports.res_b = { OnBuy = function() end }
    loadModule('server/security.lua')

    env.invoking = 'res_a'
    check(CisNetOn('ev:buy', 'res_a:OnBuy') == true, 'res_a binds the event')
    env.invoking = 'res_b'
    check(CisNetOn('ev:buy', 'res_b:OnBuy') == false,
        'a DIFFERENT resource cannot take a bound name')
    check(CisNetOn('ev:sell', 'res_b:OnBuy') == true, 'a different NAME is unaffected')

    env.fire('onResourceStop', 'res_a')
    env.invoking = 'res_b'
    check(CisNetOn('ev:buy', 'res_b:OnBuy') == true,
        'after res_a stops, res_b CAN bind the name it was refused')
    env.reset()
end

-- ================================ 11. callback replies survive a nil in them
--
-- `table.pack` / `table.unpack` were used without a COUNT on the unpack, so
-- `{...}` truncated at the first nil. A handler answering `nil, 'not found'` --
-- the single most common shape in the platform, because "no such row" is
-- normally reported that way -- arrived at the caller as NOTHING: `await`
-- returned nil, nil, and a consumer's `if not rows then` could not tell a
-- missing row from a missing answer.
--
-- This is and the fix is `table.unpack(packed, 1, packed.n)` on every
-- hop. Asserted through a REAL round trip -- handler, event, pending key --
-- because a unit test of `table.unpack` proves nothing about whether the call
-- sites pass the count.
do
    local env = newEnv({})
    Config = CisDefaults.config()
    Security = CisDefaults.security()
    loadModule('server/security.lua')
    loadModule('server/proxy.lua')
    loadModule('server/callback.lua')

    -- A handler that answers the shape in question. The first parameter is ALWAYS
    -- src (0 for a local call) -- that invariant is what `invoke` exists to
    -- protect, and a test double that ignores it would silently test the wrong
    -- call shape.
    env.EXPORTS.RegisterCallback('shop:get', function(src, id)
        if id == 'missing' then
            return nil, 'not found'
        end
        return { id = id }, 200
    end)

    -- `values` is indexed by POSITION and sized by `n`, deliberately not a plain
    -- array: a nil in the first slot is the case under test, and a table
    -- `{ [1] = nil }` is indistinguishable from an empty one unless the count is
    -- carried beside it. Reading `values[1]` alone would therefore assert
    -- nothing, which is the trap this helper is shaped to avoid.
    local function roundTrip(id)
        local values, n, ok = {}, 0, false
        env.EXPORTS.CallCallback('shop:get', function(sentOk, ...)
            n = select('#', ...)
            for i = 1, n do values[i] = select(i, ...) end
            ok = sentOk
        end, id)
        return values, n, ok
    end

    local found, foundN, foundOk = roundTrip('abc')
    check(foundOk == true, 'a successful callback reports ok')
    check(foundN == 2 and found[1] and found[2] == 200,
        ('both values survive (n=%d)'):format(foundN))

    -- The case the bug was about.
    local missing, missingN, missingOk = roundTrip('missing')
    check(missingOk == true, 'a nil first value is not an error')
    check(missingN == 2,
        ('the answer is TWO values, not truncated to zero (n=%d)'):format(missingN))
    check(missing[1] == nil,
        ('the first value really is nil (got %s)'):format(tostring(missing[1])))
    check(missing[2] == 'not found',
        ('and the REASON after it survives -- this is the whole point: %s')
            :format(tostring(missing[2])))
    env.reset()
end

-- The await form, and the naming of a refusal.
do
    local env = newEnv({})
    Config = CisDefaults.config()
    Security = CisDefaults.security()
    loadModule('server/security.lua')
    loadModule('server/proxy.lua')
    loadModule('server/callback.lua')

    env.EXPORTS.RegisterCallback('shop:found', function() return { ok = true }, 'extra' end)

    local a, b = env.EXPORTS.AwaitCallback('shop:found')
    check(type(a) == 'table' and a.ok == true, 'await returns the first value')
    check(b == 'extra', 'await returns the second value too')

    -- A refusal NAMES the callback. `error('unknown')` reaches the console as
    -- "SCRIPT ERROR: @cis_libs/server/callback.lua:186: unknown", which says the
    -- library failed and says nothing about which of dozens of registered
    -- callbacks did.
    local ok, err = pcall(env.EXPORTS.AwaitCallback, 'no:such:callback')
    check(not ok, 'awaiting a name with no handler raises')
    check(tostring(err):find('no:such:callback', 1, true) ~= nil,
        'and the error NAMES the callback: ' .. tostring(err))
    env.reset()
end

-- `tryAwait` never raises. Some callers cannot have an exception thrown through
-- their thread -- a coroutine with no error boundary, an event handler that
-- would take the thread with it -- and today their only option is CallCallback,
-- which they cannot use because they want a return value rather than a closure.
do
    local env = newEnv({})
    Config = CisDefaults.config()
    Security = CisDefaults.security()
    loadModule('server/security.lua')
    loadModule('server/proxy.lua')
    loadModule('server/callback.lua')

    env.EXPORTS.RegisterCallback('ok:one', function() return 'value' end)

    local raised = not pcall(env.EXPORTS.TryAwaitCallback, 'no:such:callback')
    check(not raised, 'tryAwait never raises, even for an unknown name')

    local ok, value = env.EXPORTS.TryAwaitCallback('ok:one')
    check(ok == true, 'tryAwait reports success')
    check(value == 'value', 'tryAwait returns the handler value')

    local ok2, reason = env.EXPORTS.TryAwaitCallback('no:such:callback')
    check(ok2 == false, 'tryAwait reports failure rather than raising')
    check(type(reason) == 'string' and reason ~= '',
        'and carries a reason: ' .. tostring(reason))
    env.reset()
end

-- ============================================ 12. server->client callback rate
-- `cis_libs:cb:serverRes` went through CisNetOn with no limit of its
-- own, so it inherited the default backstop of EIGHT per second per player. A
-- server with more than eight callbacks in flight to one client had the rest
-- DROPPED at the boundary, and every caller then waited out the full 10s
-- timeout for an answer that had already been refused.
--
-- The limit protects nothing the ownership check does not already protect --
-- the handler peeks the pending entry and rejects any key not addressed to that
-- client before doing anything -- and a UI never has eight in flight. 40 is
-- still far above any real client.
--
-- The test drives the REAL handler through the REAL net event, ten times in one
-- window, and counts how many reached the callback.
do
    local env = newEnv({})
    Config = CisDefaults.config()
    Security = CisDefaults.security()
    loadModule('server/security.lua')
    loadModule('server/proxy.lua')
    loadModule('server/callback.lua')

    -- Ten server->client callbacks to ONE player. The harness already records
    -- every TriggerClientEvent with its arguments, so the keys the resource
    -- handed the client are read back off `env.sent` rather than re-derived.
    local resolved = 0
    for i = 1, 10 do
        env.EXPORTS.CallCallbackClient('shop:buy', 7, function() resolved = resolved + 1 end, i)
    end

    local keys = {}
    for _, e in ipairs(env.sentTo(7, 'cis_libs:cb')) do
        -- args are (name, key, ...)
        keys[#keys + 1] = e.args[2]
    end
    check(#keys == 10,
        ('all ten server->client callbacks were sent (%d)'):format(#keys))

    -- Answer each one as the client would: (key, true, 'ok').
    for i = 1, #keys do
        env.emit('cis_libs:cb:serverRes', 7, keys[i], true, 'ok')
    end

    check(resolved == 10,
        ('ten replies to one client in one window are ALL delivered (%d of 10)')
            :format(resolved))
    env.reset()
end

-- ================= 13. random callback names cannot grow the limiter ()
--
-- The rate bucket was allocated BEFORE the handler lookup, and buckets are keyed
-- on the event NAME -- which arrives off the wire. A client firing `cis_libs:cb`
-- with ten thousand distinct made-up names therefore grew the limiter by ten
-- thousand entries, never freed, with no error and no limit anywhere. That is a
-- client-triggered memory leak with a denial-of-service shape.
do
    local env = newEnv({})
    Config = CisDefaults.config()
    Security = CisDefaults.security()
    loadModule('server/security.lua')
    loadModule('server/proxy.lua')
    loadModule('server/callback.lua')

    -- Ten thousand distinct names, none of them registered.
    for i = 1, 10000 do
        env.emit('cis_libs:cb', 1, ('no:such:callback:%d'):format(i))
    end
    check(CisRateBucketCount(1) == 0,
        ('an UNKNOWN name allocates no rate bucket at all (buckets=%d)')
            :format(CisRateBucketCount(1)))

    -- Ten thousand distinct REAL names -- registered, so the handler check
    -- passes. The cap in security.lua is what bounds this case, and it is a
    -- separate defence from the ordering above: without it a client that named
    -- real callbacks could still grow the map.
    for i = 1, 10000 do
        env.EXPORTS.RegisterCallback(('real:%d'):format(i), function() return 1 end)
    end
    for i = 1, 10000 do
        env.emit('cis_libs:cb', 1, ('real:%d'):format(i))
    end
    local held = CisRateBucketCount(1)
    check(held > 0 and held <= 256,
        ('10k REAL callback names stay under the per-src cap (buckets=%d)')
            :format(held))

    -- And a name that already owns a bucket keeps working at its own rate: the
    -- cap bounds the number of KEYS, it is not a throttle on a resource using a
    -- name it already holds.
    local before = CisRateBucketCount(1)
    for _ = 1, 10 do env.emit('cis_libs:cb', 1, 'real:1') end
    check(CisRateBucketCount(1) == before,
        'reusing an existing name adds no bucket')
    env.reset()
end

-- ================= 13b. a dropping player takes the bucket COUNT too (C2)
--
-- `playerDropped` cleared `rates[src]` and the per-player warning state but not
-- `rateCounts[src]` -- the tally of how many buckets that player holds.
--
-- Both halves are asserted because they fail differently. It is a leak first:
-- one number per connecting player, for the life of the process. It is a
-- correctness bug second: the count is the budget behind the per-src cap, and a
-- server id is reused, so a returning player inherits a count for buckets that
-- no longer exist and can hit the cap against a budget they never spent.
do
    local env = newEnv({})
    Config = CisDefaults.config()
    Security = CisDefaults.security()
    loadModule('server/security.lua')
    loadModule('server/proxy.lua')
    loadModule('server/callback.lua')

    for i = 1, 5 do
        env.EXPORTS.RegisterCallback(('live:%d'):format(i), function() return 1 end)
        env.emit('cis_libs:cb', 3, ('live:%d'):format(i))
    end
    check(CisRateBucketCount(3) == 5,
        ('C2: five distinct names leave five buckets (got %d)'):format(CisRateBucketCount(3)))

    -- A second player, so the assertion below is about the count and not about
    -- the drop handler clearing everything it can reach.
    env.EXPORTS.RegisterCallback('other:1', function() return 1 end)
    env.emit('cis_libs:cb', 4, 'other:1')
    check(CisRateBucketCount(4) == 1, 'C2: a second player has their own bucket count')

    -- `playerDropped` is registered with AddEventHandler, not RegisterNetEvent,
    -- and the handler reads the `source` GLOBAL. `env.emit` delivers net events
    -- and would reach nothing at all here, so `source` is set by hand and the
    -- AddEventHandler list is fired -- which is exactly how the server does it.
    local savedSource = rawget(_G, 'source')
    source = 3
    env.fire('playerDropped')
    _G.source = savedSource

    check(CisRateBucketCount(3) == 0,
        ('C2: a dropping player leaves NO bucket count behind (got %d)')
            :format(CisRateBucketCount(3)))
    check(CisRateBucketCount(4) == 1,
        "C2: another player's buckets survive the drop")

    -- The id is reused: a returning player starts from nothing rather than
    -- inheriting the previous occupant's budget.
    for i = 1, 3 do
        env.EXPORTS.RegisterCallback(('again:%d'):format(i), function() return 1 end)
        env.emit('cis_libs:cb', 3, ('again:%d'):format(i))
    end
    check(CisRateBucketCount(3) == 3,
        ('C2: a player returning on a reused id starts from a clean count (got %d)')
            :format(CisRateBucketCount(3)))

    env.reset()
end

-- ================== 14. AwaitCallbackClient, against the REAL native (C1)
--
-- The server's only way to ask a CLIENT for a return value. It read:
--
--     local settled, results = Citizen.Await(p)
--     if not settled then ... end
--     if type(results) == 'table' and results.n then ... end
--     return true, results
--
-- and `Citizen.Await` returns ONE value. So `settled` was the reply table -- and
-- a table is truthy, so the refusal branch never ran -- and `results` was nil,
-- so the branch that unpacked the pack never ran either.
--
-- Every `awaitClient` call therefore answered `true, nil`, whatever the client
-- said, including when the client refused. The server could not tell "this
-- client answered nil" from "this client refused" from "this client never
-- answered at all", and a timeout arrived as a successful empty result rather
-- than as the timeout it was.
--
-- Verified against citizenfx/fivem
-- `data/shared/citizen/scripting/lua/scheduler.lua`; the promise stub at the top
-- of this file models it exactly.
do
    -- Player 7 is REGISTERED, because `GetPlayerName` is src-aware in this stub
    -- and an unregistered id is a player who is not there. This block is about
    -- the answer's SHAPE, so the target has to be a real one -- previously it did
    -- not have to be, because the stub answered a name for every id.
    local env = newEnv({ players = { [7] = {}, [8] = {} } })
    Config = CisDefaults.config()
    Security = CisDefaults.security()
    loadModule('server/security.lua')
    loadModule('server/proxy.lua')
    loadModule('server/callback.lua')

    -- The reply a client sends back: `cis_libs:cb:serverRes` reaches the server
    -- through CisNetOn, so it is delivered with env.emit and `source` set to the
    -- answering client.
    --
    -- THE KEY IS READ FROM THE REQUEST rather than hardcoded. `CisPending` hands
    -- out sequential ids, so the first call in this env is 1 and every later one
    -- is not -- and a reply carrying the wrong key is simply dropped, which
    -- looks exactly like a broken await.
    local function lastRequest()
        for i = #env.sent, 1, -1 do
            if env.sent[i].name == 'cis_libs:cb' then
                return env.sent[i]
            end
        end
        return nil
    end

    local function replyFrom(src, ok, ...)
        local packed = table.pack(...)
        env.awaitHook = function()
            local req = lastRequest()
            env.emit('cis_libs:cb:serverRes', src, req.args[2], ok,
                table.unpack(packed, 1, packed.n))
        end
    end

    -- The happy path: the client answers with two values.
    do
        env.sent = {}
        replyFrom(7, true, { id = 7 }, 'second')
        local ok, a, b = env.EXPORTS.AwaitCallbackClient('ask', 7)
        local req = lastRequest()
        check(ok == true,
            ('C1: awaitClient reports success on a fulfilled reply (got %s)'):format(tostring(ok)))
        check(type(a) == 'table' and a.id == 7,
            ('C1: and returns the first value (got %s)'):format(tostring(a)))
        check(b == 'second',
            ('C1: and the SECOND value too, which Await used to drop (got %s)'):format(tostring(b)))
        check(req and req.target == 7 and req.args[1] == 'ask',
            'C1: and the request went to the client that was asked, naming the callback')
    end

    -- A nil first value with the reason behind it -- the shape "no such row"
    -- takes everywhere in this platform.
    do
        env.sent = {}
        replyFrom(7, true, nil, 'not found')
        local ok, a, b = env.EXPORTS.AwaitCallbackClient('holed', 7)
        check(ok == true, 'C1: a nil first value is a success, not a refusal')
        check(a == nil, ('C1: and the first value really is nil (got %s)'):format(tostring(a)))
        check(b == 'not found',
            ('C1: and the reason BEHIND the nil survives (got %s)'):format(tostring(b)))
    end

    -- A REFUSAL. `Citizen.Await` signals a rejection by RAISING, so the await
    -- has to catch it. Reading a second return value instead meant a refusal
    -- was reported to the caller as `true, nil` -- a success.
    do
        env.sent = {}
        replyFrom(7, false, 'unknown')
        local ok, reason = env.EXPORTS.AwaitCallbackClient('nope', 7)
        check(ok == false,
            ('C1: a client refusal is reported as false, not success-with-nil (got %s)')
                :format(tostring(ok)))
        check(tostring(reason):find('unknown', 1, true) ~= nil,
            ('C1: and carries the client\'s reason (got %s)'):format(tostring(reason)))
    end

    -- A client that never answers must still be bounded, and must say so. This
    -- is the timeout the sweep produces, and it is the case that used to look
    -- most like success: an empty result indistinguishable from a real one.
    do
        env.sent = {}
        replyFrom(7, false, 'timeout')
        local ok, reason = env.EXPORTS.AwaitCallbackClient('silent', 7)
        check(ok == false,
            ('C1: a timeout is a refusal, not an empty success (got %s)'):format(tostring(ok)))
        check(tostring(reason):find('timeout', 1, true) ~= nil,
            ('C1: and says "timeout" rather than answering nil (got %s)'):format(tostring(reason)))
    end

    -- The reason has to NAME the callback. In a resource with a dozen in
    -- flight, "timeout" alone is not an actionable message.
    do
        env.sent = {}
        replyFrom(7, false, 'timeout')
        local ok, reason = env.EXPORTS.AwaitCallbackClient('shop:stock', 7)
        check(ok == false and tostring(reason):find('shop:stock', 1, true) ~= nil,
            ('C1: a timeout names the callback that timed out (got %s)'):format(tostring(reason)))
    end

    -- A reply from a DIFFERENT client must not resolve this one. Ownership is
    -- checked before the entry is consumed (), and the await has to stay
    -- that way: one client hanging another's request is the failure the
    -- peek-before-take was added to stop. The honest answer is that the wrong
    -- client was ignored and the RIGHT one still settles the call, so the hook
    -- fires twice.
    do
        env.sent = {}
        env.awaitHook = function()
            local req = lastRequest()
            env.emit('cis_libs:cb:serverRes', 99, req.args[2], true, 'stolen')
            env.emit('cis_libs:cb:serverRes', 7, req.args[2], true, 'mine')
        end
        local ok, a = env.EXPORTS.AwaitCallbackClient('mine', 7)
        check(ok == true and a == 'mine',
            ('C1: a reply addressed to another client is ignored (got %s, %s)')
                :format(tostring(ok), tostring(a)))
    end

    -- A bad target is still refused before anything is allocated (), and
    -- that must survive a fix to the await path.
    do
        local ok, reason = env.EXPORTS.AwaitCallbackClient('x', 'not a src')
        check(ok == false and tostring(reason):find('target', 1, true) ~= nil,
            ('C1: a non-numeric target is still refused (got %s, %s)')
                :format(tostring(ok), tostring(reason)))
    end

    env.awaitHook = nil
    env.reset()
end

-- ================= 15. an oversized callback payload is refused (H4)
--
-- `GetEventData` cannot do this job, and the reason is worth pinning because it
-- is the obvious thing to reach for: it reads the RAGE SCRIPT event queue
-- (`SCRIPT_EVENT_QUEUE_AI` / `_NETWORK` -- the game's internal scripted-event
-- system), it is client-only with no server apiset, it takes the buffer size as
-- an INPUT rather than reporting one, and it returns success rather than a size.
-- It has nothing to do with the Lua net-event path and cannot report a payload
-- length at all.
--
-- So the payload is ALREADY DESERIALIZED by the time any Lua runs, and what is
-- left to check is breadth and depth -- which is what a hostile payload
-- actually abuses. A very wide table is cheap to send and expensive to walk, and
-- the rate limiter counts EVENTS rather than keys, so it cannot see it.
do
    local env = newEnv({})
    Config = CisDefaults.config()
    Security = CisDefaults.security()
    loadModule('server/security.lua')
    loadModule('server/proxy.lua')
    loadModule('server/callback.lua')

    local reached = 0
    env.EXPORTS.RegisterCallback('measure', function()
        reached = reached + 1
        return 'ok'
    end)

    -- The LAST reply, found by SEARCHING rather than by assuming the reply is
    -- the most recent event: a handler that logs puts a different event after
    -- its own reply, and a helper reading `env.sent[#env.sent]` then reports the
    -- log line, so every assertion about the reply fails for a reason that has
    -- nothing to do with the code under test.
    local function lastReply()
        for i = #env.sent, 1, -1 do
            if env.sent[i].name == 'cis_libs:cb:res' then
                return env.sent[i]
            end
        end
        return nil
    end

    -- Ordinary traffic is unaffected. A guard that complains about normal
    -- payloads is worse than none.
    reached = 0
    env.emit('cis_libs:cb', 1, 'measure', 1, { a = 1, b = 2, c = 3 }, 'x', 7)
    check(reached == 1, 'H4: an ordinary payload still reaches the handler')
    check(lastReply() and lastReply().args[2] == true,
        ('H4: and is answered (got %s)')
            :format(tostring(lastReply() and lastReply().args[2])))

    -- WIDE. 400 keys in one table: cheap to send, and not cheap to walk.
    reached = 0
    local wide = {}
    for i = 1, 400 do wide[i] = i end
    env.emit('cis_libs:cb', 1, 'measure', 2, wide)
    check(reached == 0,
        ('H4: a 400-key table is refused BEFORE the handler runs (reached %d)'):format(reached))
    check(lastReply() and lastReply().args[2] == false,
        'H4: and the client is told the request was refused')
    check(lastReply() and tostring(lastReply().args[3]):find('too large', 1, true) ~= nil,
        ('H4: with a reason it can act on (got %s)')
            :format(tostring(lastReply() and lastReply().args[3])))

    -- DEEP. Nesting is the other axis, and depth is what a recursive consumer
    -- handler would fall over on.
    reached = 0
    local deep = { leaf = true }
    for _ = 1, 40 do deep = { nested = deep } end
    env.emit('cis_libs:cb', 1, 'measure', 3, deep)
    check(reached == 0, 'H4: a deeply nested table is refused too')

    -- The budget is SHARED across the payload, not per argument -- or "nine
    -- arguments each holding a hundred keys" walks straight past a per-argument
    -- limit, which is the same payload split up.
    reached = 0
    local chunk = {}
    for i = 1, 30 do chunk[i] = i end
    env.emit('cis_libs:cb', 1, 'measure', 4, chunk, chunk, chunk, chunk, chunk,
        chunk, chunk, chunk, chunk, chunk)
    check(reached == 0,
        'H4: the key budget is shared across the whole payload, not per argument')

    -- Too many arguments at all.
    reached = 0
    env.emit('cis_libs:cb', 1, 'measure', 5, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
        11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27,
        28, 29, 30, 31, 32, 33, 34, 35, 36)
    check(reached == 0, 'H4: and so is an absurd argument count')

    -- A refused payload must still ANSWER the caller. `CisPending.take` happens
    -- before this check, so the key is already consumed -- a caller left
    -- unanswered here would wait out its full timeout for a request that was
    -- refused a millisecond after it was sent.
    check(lastReply() and lastReply().args[2] == false,
        'H4: the refused caller is ANSWERED, so it cannot wait out its timeout')

    env.reset()
end

-- ==================================================================== report
for i = 1, #failures do
    io.stderr:write('FAIL(server): ' .. failures[i] .. '\n')
end
-- ===================== the net guard and the limiter, tested for their defaults
--
-- These exist because two mutations survived the whole suite at the baseline:
-- deleting the `src <= 0` half of the guard in CisNetOn, and raising the default
-- rate limit from 8 to 8000. Neither broke a single assertion, which means the
-- suite had no test for either behaviour and both had been load-bearing without
-- anyone knowing.
--
-- The rule from here on: a security check is not DONE until its mutation is in
-- test/mutations.json and killed. These three rows are that proof.
do
    -- ---- 1. a net handler is never reached without a real player -------
    -- `source` is 0 when the event was raised server-side and -1 when it came
    -- from a scheduled context. Neither is a player. A handler that accepts them
    -- can be driven by anything able to raise the event locally, with no player
    -- behind it and therefore nothing to rate-limit, attribute or attribute it
    -- TO. The string '1' is the other shape worth naming: FiveM hands `source`
    -- through as a number, so a string can only come from a forged or mangled
    -- call, and type(src) ~= 'number' is what stops it.
    local env = newEnv({})
    Config = CisDefaults.config()
    Security = CisDefaults.security()

    local reached = 0
    env.exported = {}
    exports.cis_guard = env.exported
    env.exported.OnBuy = function(_, src)
        reached = reached + 1
    end

    loadModule('server/security.lua')
    check(CisNetOn('cis_guard:buy', 'cis_guard:OnBuy') == true,
        'G1: the guarded handler registers')

    local refused = { 0, -1, '1', 'conn', {} }
    local names = { 'server-side (0)', 'scheduled (-1)', 'string "1"', 'string "conn"', 'table' }
    for i, badSrc in ipairs(refused) do
        reached = 0
        env.emit('cis_guard:buy', badSrc, 1)
        check(reached == 0,
            ('G1: src %s never reaches the handler'):format(names[i]))
    end

    -- And the positive case still works, so the guard is a filter and not a
    -- wall: a real player id passes.
    reached = 0
    env.emit('cis_guard:buy', 7, 1)
    check(reached == 1,
        ('G1: a real player id DOES reach the handler (reached=%d)'):format(reached))
    env.reset()
end

-- ============================ the default limiter is 8 per 1000 ms, and is 8
--
-- Not "there is a limiter" -- there has always been a limiter, and a limiter
-- that defaults to permissive is the same as no limiter. The numbers are what
-- every doc page promises, so the numbers are what is asserted.
do
    local env = newEnv({})
    Config = CisDefaults.config()
    Security = CisDefaults.security()
    loadModule('server/security.lua')

    -- One src, one event, one window, no explicit limits: every default.
    local allowed = 0
    for _ = 1, 20 do
        if CisRateOk(11, 'cis_rate:probe') then allowed = allowed + 1 end
    end
    check(allowed == 8,
        ('G2: the default limiter allows exactly 8 hits in the window, then refuses (allowed=%d)'):format(allowed))

    -- A different src is a different bucket. Sharing one counter across players
    -- would let one player exhaust everyone else's budget.
    check(CisRateOk(12, 'cis_rate:probe') == true,
        'G2: a different src has its own budget')
    -- A different event is a different bucket too.
    check(CisRateOk(11, 'cis_rate:other') == true,
        'G2: a different event has its own budget')

    -- The window closes: past 1000 ms the bucket refills. Without this the test
    -- above would also pass against a limiter that simply stopped forever.
    env.clock = 1001
    check(CisRateOk(11, 'cis_rate:probe') == true,
        'G2: after the window closes the bucket refills')
    env.clock = 2002
    local allowed2 = 0
    for _ = 1, 20 do
        if CisRateOk(11, 'cis_rate:probe') then allowed2 = allowed2 + 1 end
    end
    check(allowed2 == 8,
        ('G2: the refilled bucket allows 8 again, not more (allowed=%d)'):format(allowed2))
    env.reset()
end

-- ================================ the capability owner is the invoker, always
--
-- Third mutation to survive at the baseline. The registry records who owns a
-- slot, and that record is what every downstream decision rests on: `unregister`
-- may only be called by the owner, the audit log names it, and a resource that
-- restarts has to find its own slot again. Taking the owner from an argument
-- instead of from `invokingResource()` lets any caller claim a slot it did not
-- register, and every check built on the owner then passes for the wrong
-- resource.
do
    local env = newEnv({ invoking = 'cis_alpha' })
    Config = CisDefaults.config()
    Security = CisDefaults.security()
    loadModule('shared/registry.lua')

    check(CisRegistry.register('database', 'cis_alpha:CisAlphaDatabase') == true,
        'G3: a resource registers a capability')
    check(CisRegistry.owner('database') == 'cis_alpha',
        ('G3: the owner is the INVOKING resource, not the slot name (owner=%s)')
            :format(tostring(CisRegistry.owner('database'))))

    -- The decisive one: a resource that did not register the slot cannot
    -- release it. `unregister(slot, resource)` is the owning form -- it asserts
    -- ownership rather than trusting the caller -- and it is what a consumer
    -- calls when it tears itself down.
    check(CisRegistry.unregister('database', 'cis_beta') == false,
        'G3: a resource that did not register the slot cannot release it')
    check(CisRegistry.owner('database') == 'cis_alpha',
        'G3: and the slot still belongs to the resource that registered it')

    check(CisRegistry.unregister('database', 'cis_alpha') == true,
        'G3: the owner can release its own slot')
    env.reset()
end

-- ============================================================== 3.5 · PENDING
-- Four gaps in one block, because they are one property: a pending entry has to
-- end when the thing that made it ends. A player who leaves, and a resource
-- that stops, are both "gone", and neither was noticed.
--
-- TIME IS FAKE HERE, so "at once" is provable. The gap between asking and being
-- answered is the whole cost, and a test that only checks the final state cannot
-- tell an instant refusal from a fast one.
do
    local env = newEnv({ players = { [1] = {}, [2] = {} } })
    loadModule('server/security.lua')
    loadModule('server/proxy.lua')
    loadModule('server/callback.lua')

    env.invoking = 'res_a'
    env.EXPORTS.RegisterCallback('a:live', function() return 'from a' end)

    local function byOwner()
        return ((env.EXPORTS.GetDiagnostics().probes or {}).pendingCallbacks or {}).byOwner or {}
    end

    -- (1) A PLAYER WHO IS NOT THERE IS REFUSED IMMEDIATELY.
    --
    -- 9001 has no ped, no name and no place in GetPlayers(). Before the fix
    -- this allocated an entry, fired an event at nobody, and left the caller
    -- parked until the full CallbackTimeout -- 10 seconds of a thread doing
    -- nothing, for a caller who already knows the answer.
    local startedAt = env.clock
    local ok, why = env.EXPORTS.AwaitCallbackClient('a:live', 9001)
    check(ok == false, '3.5: an await on a player who is not connected is refused')
    check(tostring(why):find('not connected', 1, true) ~= nil,
        ('3.5: and says so (%s)'):format(tostring(why)))
    check(env.clock == startedAt,
        '3.5: and is refused WITHOUT waiting -- the whole point of the check')

    -- (2) THE ENTRY RECORDS WHO ASKED FOR IT, AND THE PROBE CAN SAY SO.
    --
    -- Without an owner on the entry a stopping resource's pending entries are
    -- indistinguishable from anyone else's, and the stop sweep cannot exist.
    -- Grouped BY OWNER for the same reason `syncRecords` is: a total cannot tell
    -- "released its own" from "released everything", and those are different
    -- answers to the question the lifecycle tier asks.
    env.invoking = 'res_a'
    env.EXPORTS.CallCallbackClient('a:live', 1, function() end)
    check((byOwner().res_a or 0) == 1,
        ('3.5: a pending entry records the resource that created it (%s)')
            :format(tostring(byOwner().res_a)))

    -- (3) A RESOURCE THAT STOPS TAKES ITS OWN PENDING ENTRIES WITH IT, and
    -- nobody else's.
    env.invoking = 'res_b'
    env.EXPORTS.RegisterCallback('b:live', function() return 'from b' end)
    env.EXPORTS.CallCallbackClient('b:live', 2, function() end)
    check((byOwner().res_b or 0) == 1, '3.5: and so does the second resource\'s')

    env.fire('onResourceStop', 'res_a')
    check(byOwner().res_a == nil,
        '3.5: a stopped resource takes its own pending entries with it')
    check((byOwner().res_b or 0) == 1,
        '3.5: and another resource\'s entries are untouched')

    -- (4) A PLAYER WHO DROPS DOES NOT LEAVE THE SERVER WAITING FOR THEM.
    --
    -- This one was missing, and mutation M20 said so: without it the whole
    -- `playerDropped` handler is a SURVIVOR, because every other assertion in
    -- this block passes with it deleted.
    --
    -- The entry is recreated first, so the stop sweep above is not what empties
    -- the map -- otherwise the two properties could be confused for each other
    -- and both would pass with either one broken.
    local answeredWith, answeredWhy
    env.invoking = 'res_a'
    env.EXPORTS.CallCallbackClient('a:live', 1, function(cbOk, cbWhy)
        answeredWith, answeredWhy = cbOk, cbWhy
    end)
    check((byOwner().res_a or 0) == 1, '3.5: res_a has an entry aimed at player 1')

    -- `playerDropped` is an AddEventHandler and the handler reads the `source`
    -- GLOBAL, which the net-event emitter never sets. Hand-set, the same way the
    -- C2 case above does it.
    local savedSource = rawget(_G, 'source')
    source = 1
    env.fire('playerDropped')
    _G.source = savedSource

    check(byOwner().res_a == nil,
        '3.5: a dropped player takes their pending entries with them')
    check(answeredWith == false,
        '3.5: and the waiting caller is ANSWERED, not left to time out')
    check(tostring(answeredWhy) == 'player dropped',
        ('3.5: with a reason that says what happened (%s)'):format(tostring(answeredWhy)))
    check((byOwner().res_b or 0) == 1,
        "3.5: another player's entries survive the drop")
    env.reset()
end

-- ============================================ 3.11 · the manifest checks, rewritten
--
-- `declaresDependencyOnUs` opened a file at
-- `GetResourcePath(name) .. '/' .. name .. '/fxmanifest.lua'` -- a DOUBLED
-- path, because GetResourcePath already ends in the resource name. The handle
-- was therefore always nil, the function always answered false, and check 3
-- ("a consumer started before cis_libs") could never fire on any install, ever.
-- It also used `io.open`, which is on the shipped boundary contract as a
-- forbidden call -- a contract violation that existed in the same file.
--
-- FiveM DOES expose the manifest: `GetNumResourceMetadata` and
-- `GetResourceMetadata`. The rewrite uses them.
--
-- EVERY metadata entry is scanned rather than a named key. The plan asks for
-- this to be verified live against `cis_test_badmeta` -- whether a plural
-- `dependencies { }` block appears under the singular key -- and that could
-- not be verified here (no client, no running server), so the code does not
-- assume it either way. Reading every value and recognising the shapes is
-- correct whichever answer is right, and an assumption that turns out wrong is
-- a check that never fires.
do
    local env = newEnv({})
    Config = CisDefaults.config()
    Security = CisDefaults.security()
    loadModule('server/security.lua')

    -- A manifest, modelled as FiveM reports it: an index and a value per entry.
    -- Deliberately mixed singular and plural, because whether FiveM normalises
    -- that is exactly the thing not to assume.
    local manifests = {
        cis_good = { dependency = { 'cis_libs' } },
        -- Includes us and does NOT declare us: exactly what cis_test_badmeta is.
        cis_no_dependency = { shared_script = { '@cis_libs/init.lua' } },
        cis_plural_blocks = {
            dependencies = { 'cis_libs' },
            shared_scripts = { '@cis_libs/init.lua' },
        },
        cis_internal = {
            dependency = { 'cis_libs' },
            shared_script = { '@cis_libs/shared/registry.lua' },
        },
    }
    local started = {
        cis_good = true, cis_no_dependency = true,
        cis_plural_blocks = true, cis_internal = true,
    }

    env.started = started
    function GetResourceState(name) return started[name] and 'started' or 'missing' end
    function GetNumResources()
        local n = 0
        for _ in pairs(manifests) do n = n + 1 end
        return n
    end
    function GetResourceByFindIndex(i)
        local names = {}
        for k in pairs(manifests) do names[#names + 1] = k end
        table.sort(names)
        return names[i + 1]
    end
    function GetNumResourceMetadata(name)
        local m = manifests[name]
        if not m then return 0 end
        local n = 0
        for _, values in pairs(m) do n = n + #values end
        return n
    end
    function GetResourceMetadata(name, key, index)
        local values = manifests[name] and manifests[name][key]
        if not values then return nil end
        return values[(tonumber(index) or 0) + 1]
    end

    local scheduled
    SetTimeout = function(ms, fn) scheduled = { ms = ms, fn = fn } end
    loadModule('server/selfcheck.lua')
    scheduled.fn()

    local result = exports.GetSelfCheck()
    check(result.ok == false, '3.11: GetSelfCheck answers with a result')

    local byCode = {}
    for _, p in ipairs(result.problems) do
        byCode[p.code] = byCode[p.code] or {}
        table.insert(byCode[p.code], p)
    end

    check(byCode.missing_dependency ~= nil,
        '3.11: a resource that includes cis_libs without declaring it is reported')
    local md = byCode.missing_dependency and byCode.missing_dependency[1]
    check(md ~= nil and tostring(md.message):find('cis_no_dependency', 1, true) ~= nil,
        ('3.11: and it NAMES the resource (%s)'):format(tostring(md and md.message)))
    check(md ~= nil and tostring(md.fix):find('dependency', 1, true) ~= nil
            and tostring(md.fix):find('cis_libs', 1, true) ~= nil,
        ('3.11: and the fix names the exact line to add (%s)'):format(tostring(md and md.fix)))

    check(byCode.internal_include ~= nil,
        '3.11: a resource including a stateful internal file is reported')
    local ii = byCode.internal_include and byCode.internal_include[1]
    check(ii ~= nil and tostring(ii.message):find('cis_internal', 1, true) ~= nil,
        ('3.11: and it names the resource (%s)'):format(tostring(ii and ii.message)))
    check(ii ~= nil and tostring(ii.message):find('registry', 1, true) ~= nil,
        ('3.11: and which internal file it pulled in (%s)'):format(tostring(ii and ii.message)))

    -- THE PLURAL-BLOCK CASE, written so it holds whichever way FiveM reports
    -- it: `cis_plural_blocks` declares the dependency under a plural key and
    -- must NOT be reported. Before this task nothing was reported at all, so
    -- this assertion is what stops the rewrite reporting it by accident.
    for i = 1, #result.problems do print('DBG', result.problems[i].code, result.problems[i].message) end
    -- `cis_plural_blocks` DOES declare the dependency, under the plural spelling.
    -- It must therefore never appear as MISSING_DEPENDENCY.
    --
    -- Scoped to that one code on purpose. It legitimately appears under
    -- `started_before_dependency` instead -- the stub marks every resource as
    -- running before cis_libs starts, which is exactly check 3's situation, and
    -- it names the resource because it does declare us. A first version of this
    -- assertion rejected ANY problem mentioning the resource, and reported a
    -- false positive that was a correct finding from a different check.
    local falsePositive = false
    local reported = {}
    for _, p in ipairs(result.problems) do
        reported[#reported + 1] = ('%s: %s'):format(p.code, tostring(p.message))
        if p.code == 'missing_dependency'
            and tostring(p.message):find('cis_plural_blocks', 1, true) then
            falsePositive = true
        end
    end
    -- The message names what WAS reported. A false-positive assertion that only
    -- says "one was reported" sends whoever is on call back to the harness to
    -- find out which problem fired, which is the trip this file exists to
    -- remove.
    check(not falsePositive,
        ('3.11: a resource that DOES declare the dependency is never reported as '
            .. 'missing, whether its manifest says dependency or dependencies. '
            .. 'Reported: %s'):format(table.concat(reported, ' | ')))

    -- AND THE OTHER DIRECTION: a resource that includes us but is silent is
    -- reported even though it never mentioned a dependency at all.
    check(byCode.missing_dependency ~= nil
            and (#byCode.missing_dependency >= 1),
        '3.11: and at least one such resource is caught')

    env.reset()
end

-- ============================================== 4.2 · every coordinate shape
--
-- The check was `type(data.coords) ~= 'table'`, and a REAL vector3 in CfxLua is
-- USERDATA. So every framework that hands cis_libs a vector3 -- which is most of
-- them -- had its sync calls refused, and the caller got nil with an error in
-- the log. A resource that never passes a plain table simply never syncs
-- anything, and nothing says why.
--
-- vector4 carries a heading in `w`; a plain table carries it in `heading`. Both
-- are read, so one record shape works from either side.
--
-- And non-finite numbers are refused WITH A REASON. NaN fails every comparison
-- silently, so a record at NaN is never in range and never out of range: it is
-- streamed to nobody and removed from nobody, forever.
do
    local env = newEnv({ players = { [1] = { coords = { x = 0.0, y = 0.0, z = 0.0 } } } })
    loadSync(env)

-- The forms, one at a time. CfxLua's `type()` answers 'vector3' and
    -- 'vector4' for those, and THAT is the whole point of this block -- but
    -- neither fengari nor stock Lua can be made to report a `__type` from a
    -- table, so `type` is wrapped for the duration and restored after. A stub
    -- that cannot reach the branch under test proves nothing about it.
    local realType = type
    _G.type = function(v)
        local tag = realType(v)
        if tag == 'table' then
            local mt = getmetatable(v)
            if mt and mt.__type then return mt.__type end
        end
        return tag
    end

    local function vec3(x, y, z)
        return setmetatable({ x = x, y = y, z = z }, { __type = 'vector3' })
    end
    local function vec4(x, y, z, w)
        return setmetatable({ x = x, y = y, z = z, w = w }, { __type = 'vector4' })
    end

    local plain = env.EXPORTS.SyncCreate('prop', {
        id = 'plain', model = 'prop_barrel_01', coords = { x = 5.0, y = 6.0, z = 7.0 },
    })
    check(type(plain) == 'string', ('4.2: a plain { x, y, z } table is accepted (%s)')
        :format(tostring(plain)))

    local v3 = env.EXPORTS.SyncCreate('prop', {
        id = 'v3', model = 'prop_barrel_01', coords = vec3(15.0, 16.0, 17.0),
    })
    check(type(v3) == 'string',
        ('4.2: a real vector3 -- type "vector3", which is USERDATA -- is accepted (%s)')
            :format(tostring(v3)))

    local v4 = env.EXPORTS.SyncCreate('prop', {
        id = 'v4', model = 'prop_barrel_01', coords = vec4(25.0, 26.0, 27.0, 1.5),
    })
    check(type(v4) == 'string', ('4.2: a vector4 is accepted (%s)'):format(tostring(v4)))

    -- z omitted, because `{ x, y }` is what a caller with a 2D position writes.
    local noZ = env.EXPORTS.SyncCreate('prop', {
        id = 'noz', model = 'prop_barrel_01', coords = { x = 35.0, y = 36.0 },
    })
    check(type(noZ) == 'string', ('4.2: a table with no z still places the record (%s)')
        :format(tostring(noZ)))

    -- NON-FINITE IS REFUSED. NaN and infinity are the shapes that pass every
    -- range comparison without ever being in range.
    for _, bad in ipairs({ { x = 0 / 0, y = 0.0, z = 0.0 },
                           { x = 0.0, y = math.huge, z = 0.0 },
                           { x = 0.0, y = 0.0, z = -math.huge } }) do
        local made = env.EXPORTS.SyncCreate('prop', {
            id = 'bad', model = 'prop_barrel_01', coords = bad,
        })
        check(made == nil,
            ('4.2: non-finite coords are refused (%s,%s,%s)')
                :format(tostring(bad.x), tostring(bad.y), tostring(bad.z)))
    end

    -- AND A MISSING ONE IS STILL REFUSED, with the reason naming the key.
    local before = #env.lines
    local none = env.EXPORTS.SyncCreate('prop', { id = 'none', model = 'prop_barrel_01' })
    check(none == nil, '4.2: a record with no coords at all is refused')
    local saidCoords = false
    for i = before, #env.lines do
        if tostring(env.lines[i]):lower():find('coords', 1, true) then saidCoords = true end
    end
    check(saidCoords, '4.2: and the refusal names the key that is wrong')

    _G.type = realType
    env.reset()
end

-- ============================================== 4.3 · ids live in a namespace
--
-- `records` was one flat table for the whole server, keyed on whatever the
-- caller passed as `id`. Two resources that both name a record "door1" -- which
-- is the obvious name to pick in both, and is what the library's own harness
-- does -- did not get two records. The second call OVERWROTE the first, took
-- ownership of it, and the first resource's prop was silently replaced by a
-- different model in a different place. Nothing raised, nothing was logged, and
-- the first resource's `remove` then removed the second resource's entity.
--
-- A numeric id had the mirror defect: it stayed a number all the way to the
-- wire, and client/sync.lua drops any record whose id is not a string. The
-- caller got a number back, the record was stored, the streaming pass told every
-- client about it, every client dropped it, and no log mentioned it.
--
-- Every assertion here is about what a CLIENT RECEIVED or what the CALLER HELD.
-- A count of internal records cannot tell two owners apart.
do
    local env = newEnv({ players = { [1] = { coords = { x = 10.0, y = 0.0, z = 0.0 } } } })
    loadSync(env)

    local function as(ownerName, kind, data)
        local saved = env.invoking
        env.invoking = ownerName
        local made = env.EXPORTS.SyncCreate(kind, data)
        env.invoking = saved
        return made
    end

    local function upserts()
        local out = {}
        for _, e in ipairs(env.sentTo(1, 'cis_libs:client:syncUpsert')) do
            out[#out + 1] = e.args[1]
        end
        return out
    end

    -- THE COLLISION. The same id, two resources, two genuinely different props.
    local gotA = as('res_a', 'prop', {
        id = 'door1', model = 'prop_barrier_05a', coords = { x = 0.0, y = 0.0, z = 0.0 },
    })
    local gotB = as('res_b', 'prop', {
        id = 'door1', model = 'prop_barrel_01', coords = { x = 20.0, y = 0.0, z = 0.0 },
    })

    -- THE CALLER GETS ITS OWN ID BACK, unchanged. A consumer that stores the id
    -- and hands it back to remove later must keep working, and two resources
    -- both holding the string "door1" is exactly what makes this worth saying.
    check(gotA == 'door1' and gotB == 'door1',
        ('4.3: each caller gets the id it passed in (%s, %s)'):format(
            tostring(gotA), tostring(gotB)))

    -- What the client received: two records, not one.
    local wire = upserts()
    check(#wire == 2,
        ('4.3: two resources using the same id reach the client as two records (%d)')
            :format(#wire))

    -- Two records with ONE identity between them would be one entity that
    -- respawns itself forever, so the key is the observable that matters.
    local models = {}
    for _, r in ipairs(wire) do
        models[r.model] = (models[r.model] or 0) + 1
    end
    check((models['prop_barrier_05a'] or 0) == 1 and (models['prop_barrel_01'] or 0) == 1,
        '4.3: neither prop overwrote the other -- both models reached the client')

    local keyA, keyB = wire[1] and wire[1].key, wire[2] and wire[2].key
    check(type(keyA) == 'string' and type(keyB) == 'string' and keyA ~= keyB,
        ('4.3: every record carries its own opaque key (%s vs %s)'):format(
            tostring(keyA), tostring(keyB)))
    check(type(keyA) == 'string' and keyA:find('res_a', 1, true) ~= nil
        and keyB:find('res_b', 1, true) ~= nil,
        '4.3: the key names the owning resource, so two owners cannot collide')

    -- ONE OWNER STOPS. It takes ITS colliding record and leaves the other
    -- alone: before the namespacing this removed whichever record happened to
    -- be stored under that id, which was the survivor's.
    env.fire('onResourceStop', 'res_a')
    local removedKeys = {}
    for _, e in ipairs(env.sentTo(1, 'cis_libs:client:syncRemove')) do
        removedKeys[#removedKeys + 1] = e.args[1]
    end
    check(#removedKeys == 1 and removedKeys[1] == keyA,
        ('4.3: the stopped resource took its own colliding record (%s)'):format(
            tostring(#removedKeys)))

    env.tick()
    local stillThere = false
    for _, r in ipairs(upserts()) do
        if r.key == keyB then stillThere = true end
    end
    check(stillThere, '4.3: the other resource still owns its record after that')

    -- A NUMERIC ID. Converted at the boundary, on the wire, and on the way back
    -- in -- a caller holding a number must be able to remove with it.
    local numeric = as('res_a', 'prop', {
        id = 7, model = 'prop_barrel_01', coords = { x = 40.0, y = 0.0, z = 0.0 },
    })
    check(type(numeric) == 'string' and numeric == '7',
        ('4.3: a numeric id becomes a string at the boundary (%s, %s)'):format(
            type(numeric), tostring(numeric)))

    local sevenOnWire = false
    for _, r in ipairs(upserts()) do
        if r.id == '7' and type(r.id) == 'string' then sevenOnWire = true end
    end
    check(sevenOnWire,
        '4.3: and it reaches the client as a string, which is the only shape the '
            .. 'client accepts -- a number is dropped in silence')

    env.invoking = 'res_a'
    check(env.EXPORTS.SyncRemove(7) == true,
        '4.3: a numeric id removes the record its string names')
    env.invoking = 'cis_anyProduct'

    -- A NUL inside an id would forge a boundary the composite key depends on,
    -- so it is refused and the reason says why.
    local beforeNul = #env.lines
    local withNul = as('res_a', 'prop', {
        id = 'a\0b', model = 'prop_barrel_01', coords = { x = 50.0, y = 0.0, z = 0.0 },
    })
    check(withNul == nil, '4.3: an id containing a NUL is refused')
    local namedIt = false
    for i = beforeNul, #env.lines do
        local line = tostring(env.lines[i]):lower()
        if line:find('id', 1, true) and line:find('nul', 1, true) then namedIt = true end
    end
    check(namedIt, '4.3: and the refusal names the key that is wrong')

    -- AN ID THAT IS NEITHER A STRING NOR A NUMBER refuses to remove, rather
    -- than raising. A consumer cannot catch an error raised across the export
    -- boundary -- it does not get a return value at all, so a table where an id
    -- was expected turns "no such entity" into a call that never answers.
    local removesBefore = #env.sent
    env.invoking = 'res_b'
    check(env.EXPORTS.SyncRemove({ 'not', 'an', 'id' }) == false,
        '4.3: removing with an id that is not a string or a number answers false')
    check(env.EXPORTS.SyncRemove(true) == false,
        '4.3: and so does a boolean, rather than raising inside the export')
    env.invoking = 'cis_anyProduct'
    local removesTold = 0
    -- `removesBefore` is a COUNT, and the list is 1-based, so the first NEW
    -- event is at removesBefore + 1. Starting at removesBefore re-counts the
    -- last event that was already there, which is the remove the numeric-id
    -- case above legitimately sent.
    for i = removesBefore + 1, #env.sent do
        if env.sent[i].name == 'cis_libs:client:syncRemove' then removesTold = removesTold + 1 end
    end
    check(removesTold == 0, '4.3: and a refused remove tells no client to despawn anything')

    env.reset()
end

-- ============================================== 4.4 · who may remove a record
--
-- The namespace makes the rule STRUCTURAL -- res_b's remove resolves to
-- res_b\0door1 and simply cannot reach res_a's -- so what is left to build is
-- the ANSWER. `false` on its own is the same answer for "that id is nobody's"
-- and "that id is not yours", and a consumer holding a stale handle cannot tell
-- a bookkeeping bug from a permissions problem.
--
-- The last case below is what keeps the reason honest: after the owner has
-- really removed the record, the very same call has to answer differently. A
-- constant refusal string would pass the first two checks and fail that one.
do
    local env = newEnv({ players = { [1] = { coords = { x = 10.0, y = 0.0, z = 0.0 } } } })
    loadSync(env)

    local function as(ownerName, data)
        local saved = env.invoking
        env.invoking = ownerName
        local made = env.EXPORTS.SyncCreate('prop', data)
        env.invoking = saved
        return made
    end

    as('res_a', {
        id = 'door1', model = 'prop_barrier_05a', coords = { x = 0.0, y = 0.0, z = 0.0 },
    })

    -- (1) ANOTHER RESOURCE CANNOT REMOVE IT.
    env.invoking = 'res_b'
    local took, why = env.EXPORTS.SyncRemove('door1')
    env.invoking = 'cis_anyProduct'
    check(took == false, '4.4: another resource cannot remove a record it does not own')
    check(tostring(why):find('another resource', 1, true) ~= nil,
        ('4.4: and the reason says the record belongs to someone else (%s)')
            :format(tostring(why)))

    -- Nothing was announced, so no client despawns a prop that is still there.
    local removesAfterRefusal = 0
    for _, e in ipairs(env.sent) do
        if e.name == 'cis_libs:client:syncRemove' then removesAfterRefusal = removesAfterRefusal + 1 end
    end
    check(removesAfterRefusal == 0,
        '4.4: a refused remove sends nothing, so the prop every player can see stays')

    -- (2) AND ANOTHER RESOURCE'S UPDATE DOES NOT MOVE IT.
    --
    -- `SyncCreate` with an id somebody else holds is not an update of their
    -- record; it is this resource's own record under its own namespace. The
    -- player in range must still be shown BOTH models at BOTH places.
    --
    -- Both records are placed WITHIN the default 80m scope on purpose. At 100m
    -- this resource's record is correctly never streamed, and the assertion
    -- below would have failed for that reason and reported a namespacing defect
    -- that was not there.
    as('res_b', {
        id = 'door1', model = 'prop_barrel_01', coords = { x = 30.0, y = 0.0, z = 0.0 },
    })
    env.tick()

    local seen = {}
    for _, e in ipairs(env.sentTo(1, 'cis_libs:client:syncUpsert')) do
        local record = e.args[1]
        seen[('%s@%s'):format(record.model, tostring(record.coords.x))] = true
    end
    check(seen['prop_barrier_05a@0.0'] == true,
        '4.4: the first resource\'s record is still where it put it')
    check(seen['prop_barrel_01@30.0'] == true,
        '4.4: and the second resource got its own record, not an update of the first')

    -- (3) THE OWNER STILL CAN.
    env.invoking = 'res_a'
    local removed, removeWhy = env.EXPORTS.SyncRemove('door1')
    env.invoking = 'cis_anyProduct'
    check(removed == true,
        ('4.4: the owner still removes its own record (%s)'):format(tostring(removeWhy)))

    -- (4) "NOT YOURS" IS NOT "NOT THERE".
    --
    -- Same call, same resource, and now the record really is gone -- so the
    -- answer has to change. This is the assertion a constant refusal string
    -- cannot survive.
    env.invoking = 'res_b'
    local _, goneWhy = env.EXPORTS.SyncRemove('door1')
    env.invoking = 'cis_anyProduct'
    check(tostring(goneWhy):find('another resource', 1, true) == nil,
        ('4.4: once it is really gone the reason is "not there", not "not yours" (%s)')
            :format(tostring(goneWhy)))

    -- And an id nobody ever used says the same.
    env.invoking = 'res_b'
    local _, neverWhy = env.EXPORTS.SyncRemove('never-created')
    env.invoking = 'cis_anyProduct'
    check(type(neverWhy) == 'string' and neverWhy ~= '',
        ('4.4: an id that never existed still answers with a reason (%s)')
            :format(tostring(neverWhy)))
    check(tostring(neverWhy):find('never%-created') ~= nil,
        ('4.4: and it names the id it could not find (%s)'):format(tostring(neverWhy)))
    -- And it must NOT blame another resource. "Nobody has this id" and "that id
    -- is not yours" are different bugs with different fixes, and only one of
    -- them is about permissions -- so an id that never existed has to say so.
    check(tostring(neverWhy):find('another resource', 1, true) == nil,
        ('4.4: an id nobody created is not reported as somebody else\'s (%s)')
            :format(tostring(neverWhy)))

    env.reset()
end

-- ============================= 4.5 · the networked path, created on the server
--
-- THE DEFECT. `server/sync.lua` asked for a model with `RequestModel`, waited on
-- `HasModelLoaded`, released it with `SetModelAsNoLongerNeeded` and then created
-- every kind with `CreateObject`. All four are wrong on the server:
--
--   * the first three are `apiset: client`. A server file calling them does not
--     spawn anything; it gets whatever the runtime stubs, which on a real server
--     is nothing at all. The networked path could not work, and it failed
--     SILENTLY -- the record still existed, the client still resolved an id, and
--     the entity was simply never there.
--   * `CreateObject` makes an object. Handing it a vehicle model produces no
--     vehicle, and handing it a ped model produces no ped, so `kind = 'vehicle'`
--     and `kind = 'ped'` could never produce the entity they name.
--
-- The correct natives are the server RPC ones -- `CreateObjectNoOffset`,
-- `CreateVehicleServerSetter`, `CreatePed` -- and every one of them is
-- `apiset: server`. Verified in tools/natives/natives_cfx.json, not recalled.
--
-- Each block below reads the natives the file ACTUALLY called, because a stub
-- that answers "true" for everything cannot tell a networked spawn from a
-- client-local one.
local function callsNamed(env, name)
    local out = {}
    for i = 1, #env.natives do
        if env.natives[i].name == name then out[#out + 1] = env.natives[i] end
    end
    return out
end
do
    -- (1) ONE KIND, ONE NATIVE. A prop is an object.
    local env = newEnv({
        players = { [1] = { coords = { x = 5.0, y = 0.0, z = 0.0 } } },
        netOk = true,
    })
    loadSync(env)
    env.EXPORTS.SyncCreate('prop', {
        model = 'prop_barrel_01',
        coords = { x = 0.0, y = 0.0, z = 12.0 },
        heading = 45.0,
        networked = true,
    })
    local made = callsNamed(env, 'CreateObjectNoOffset')
    check(#made == 1,
        '4.5: a networked prop is created with CreateObjectNoOffset')
    check(#made == 1 and made[1].x == 0.0 and made[1].y == 0.0 and made[1].z == 12.0,
        '4.5: at the coordinates the record names')
    check(#made == 1 and made[1].networked == true,
        '4.5: and as a networked entity, so every client shares ONE of it')
    check(#made == 1 and made[1].mission == true,
        '4.5: pinned to this script, so the server keeps ownership of it')
    check(#callsNamed(env, 'CreateObject') == 0,
        '4.5: and not with CreateObject, which is the client-side spawn')
    -- The three client-only natives. THIS is the violation the realm check
    -- reports, asserted where it can be acted on.
    check(#callsNamed(env, 'RequestModel') == 0,
        '4.5: a server file never calls RequestModel (apiset: client)')
    check(#callsNamed(env, 'SetModelAsNoLongerNeeded') == 0,
        '4.5: and never SetModelAsNoLongerNeeded (apiset: client)')
    env.reset()
end

-- (2) A VEHICLE IS NOT AN OBJECT.
do
    local env = newEnv({
        players = { [1] = { coords = { x = 5.0, y = 0.0, z = 0.0 } } },
        netOk = true,
    })
    loadSync(env)
    env.EXPORTS.SyncCreate('vehicle', {
        model = 'adder',
        coords = { x = 3.0, y = 4.0, z = 5.0 },
        heading = 90.0,
        networked = true,
    })
    local made = callsNamed(env, 'CreateVehicleServerSetter')
    check(#made == 1,
        '4.5: a networked vehicle is created with CreateVehicleServerSetter')
    check(#made == 1 and made[1].vehicleType == 'automobile',
        ('4.5: with the vehicle type the native requires (%s)')
            :format(tostring(made[1] and made[1].vehicleType)))
    check(#made == 1 and made[1].heading == 90.0,
        '4.5: and the heading travels at creation, not in a second call')
    check(#callsNamed(env, 'CreateObjectNoOffset') == 0,
        '4.5: a vehicle is not created through the object native')
    -- The vehicle type is carried by the record, so a caller spawning boats does
    -- not get automobiles.
    env.EXPORTS.SyncCreate('vehicle', {
        id = 'a-boat',
        model = 'jetmax',
        coords = { x = 3.0, y = 4.0, z = 5.0 },
        heading = 0.0,
        vehicleType = 'boat',
        networked = true,
    })
    local boats = callsNamed(env, 'CreateVehicleServerSetter')
    check(#boats == 2 and boats[2] and boats[2].vehicleType == 'boat',
        '4.5: the record carries the vehicle type, defaulting to automobile')
    env.reset()
end

-- (3) A PED IS NOT AN OBJECT EITHER.
do
    local env = newEnv({
        players = { [1] = { coords = { x = 5.0, y = 0.0, z = 0.0 } } },
        netOk = true,
    })
    loadSync(env)
    env.EXPORTS.SyncCreate('ped', {
        model = 'a_m_m_yogh_01',
        coords = { x = 1.0, y = 2.0, z = 3.0 },
        heading = 180.0,
        networked = true,
    })
    local made = callsNamed(env, 'CreatePed')
    check(#made == 1, '4.5: a networked ped is created with CreatePed')
    check(#made == 1 and made[1].networked == true,
        '4.5: and as a networked entity')
    check(#made == 1 and made[1].heading == 180.0,
        '4.5: with the heading the record carries')
    check(#callsNamed(env, 'CreateObjectNoOffset') == 0,
        '4.5: a ped is not created through the object native')
    env.reset()
end

-- (4) THE ENTITY GOES IN THE WORLD THE RECORD NAMES, AND SURVIVES ITS OWNER.
--
-- Both were missing entirely, and both are what makes a networked record wrong
-- in a way no test above can see. Without the bucket, an entity spawned for a
-- job in a racing instance appears in the main world too -- and the client that
-- despawns it on request cannot, because the server genuinely believes the
-- player should see it. Without orphan mode the server deletes the entity the
-- moment it decides nobody needs it, mid-session, with no event to anyone.
do
    local env = newEnv({
        players = { [1] = { coords = { x = 5.0, y = 0.0, z = 0.0 }, bucket = 3 } },
        netOk = true,
    })
    loadSync(env)
    env.EXPORTS.SyncCreate('prop', {
        model = 'prop_barrel_01',
        coords = { x = 0.0, y = 0.0, z = 0.0 },
        bucket = 3,
        networked = true,
    })
    local bucket = callsNamed(env, 'SetEntityRoutingBucket')
    check(#bucket == 1 and bucket[1].bucket == 3,
        '4.5: the entity is put in the routing bucket its record names')
    local orphan = callsNamed(env, 'SetEntityOrphanMode')
    -- KeepEntity = 2. DeleteWhenNotRelevant (0) and DeleteOnOwnerDisconnect (1)
    -- both remove the entity while the record still exists, which is the defect.
    check(#orphan == 1 and orphan[1].mode == 2,
        ('4.5: and set to keep, not to be reaped when nobody is near (%s)')
            :format(tostring(orphan[1] and orphan[1].mode)))
    check(#orphan == 1 and bucket[1] and bucket[1].entity == orphan[1].entity,
        '4.5: both applied to the entity that was just created')
    env.reset()
end

-- (5) A MOVE IS A MOVE. Re-upserting the same record at new coordinates moves
-- the entity that already exists; it does not spawn a second one. Spawning a
-- second one and leaving the first on the network is exactly the "orphaned on
-- the network" defect the spec pins, and it is invisible on the client: both
-- clients see one entity either way, because they resolve the newest id.
do
    local env = newEnv({
        players = { [1] = { coords = { x = 5.0, y = 0.0, z = 0.0 } } },
        netOk = true,
    })
    loadSync(env)
    env.EXPORTS.SyncCreate('prop', {
        id = 'mover',
        model = 'prop_barrel_01',
        coords = { x = 0.0, y = 0.0, z = 0.0 },
        networked = true,
    })
    env.EXPORTS.SyncCreate('prop', {
        id = 'mover',
        model = 'prop_barrel_01',
        coords = { x = 0.0, y = 0.0, z = 9.0 },
        networked = true,
    })
    check(#callsNamed(env, 'CreateObjectNoOffset') == 1,
        '4.5: moving a networked record spawns nothing new')
    local moves = callsNamed(env, 'SetEntityCoords')
    check(#moves == 1 and moves[1].z == 9.0,
        ('4.5: it moves the entity the server already owns (%s)')
            :format(tostring(#moves == 1 and moves[1].z)))
    env.reset()
end

-- (6) A DIFFERENT MODEL IS A DIFFERENT ENTITY. The client cannot swap a prop's
-- model in place, so the server deletes and re-creates -- and must delete the
-- old one, or it stays on the network owned by nobody.
do
    local env = newEnv({
        players = { [1] = { coords = { x = 5.0, y = 0.0, z = 0.0 } } },
        netOk = true,
    })
    loadSync(env)
    env.EXPORTS.SyncCreate('prop', {
        id = 'swapper',
        model = 'prop_barrel_01',
        coords = { x = 0.0, y = 0.0, z = 0.0 },
        networked = true,
    })
    env.EXPORTS.SyncCreate('prop', {
        id = 'swapper',
        model = 'prop_barrel_02b',
        coords = { x = 0.0, y = 0.0, z = 0.0 },
        networked = true,
    })
    check(#callsNamed(env, 'CreateObjectNoOffset') == 2,
        '4.5: a model change re-creates the entity')
    local deletions = callsNamed(env, 'DeleteEntity')
    check(#deletions == 1,
        ('4.5: and deletes the one it replaced (%d deleted)')
            :format(#deletions))
    env.reset()
end

-- (7) REMOVE DELETES ON THE SERVER. A networked entity belongs to the server;
-- telling clients to despawn it only asks them to drop a reference to something
-- that is still in the world, owned by nobody, forever.
do
    local env = newEnv({
        players = { [1] = { coords = { x = 5.0, y = 0.0, z = 0.0 } } },
        netOk = true,
    })
    loadSync(env)
    env.EXPORTS.SyncCreate('prop', {
        id = 'doomed',
        model = 'prop_barrel_01',
        coords = { x = 0.0, y = 0.0, z = 0.0 },
        networked = true,
    })
    local created = callsNamed(env, 'CreateObjectNoOffset')
    local removed, why = env.EXPORTS.SyncRemove('doomed')
    check(removed == true, ('4.5: the record removes (%s)'):format(tostring(why)))
    local deletions = callsNamed(env, 'DeleteEntity')
    check(#deletions == 1,
        ('4.5: and the SERVER deletes the entity it owns (%d deletions)')
            :format(#deletions))
    check(#deletions == 1 and #created == 1
            and deletions[1].entity == created[1].entity,
        '4.5: naming the entity that was actually created')
    check(#created == 1 and env.entities[created[1].entity]
            and env.entities[created[1].entity].alive == false,
        '4.5: and that entity no longer exists')
    env.reset()
end

-- (8) A KIND THAT CANNOT BE MADE RELIABLE SAYS SO.
--
-- The rule is not "try it and hope". A record naming a kind the server has no
-- creation native for is answered with nil and a reason, rather than a record
-- that claims an entity exists and has none. Silently downgrading to
-- client-local would be the worst of the three: the caller asked for one shared
-- entity and would get one per player, with nothing in any log.
do
    local env = newEnv({
        players = { [1] = { coords = { x = 5.0, y = 0.0, z = 0.0 } } },
        netOk = true,
    })
    loadSync(env)
    local made, why = env.EXPORTS.SyncCreate('blimp', {
        model = 'blimp',
        coords = { x = 0.0, y = 0.0, z = 0.0 },
        networked = true,
    })
    check(made == nil,
        '4.5: an unknown kind refuses networked creation rather than pretending')
    check(type(why) == 'string' and why ~= '',
        ('4.5: and answers with a reason (%s)'):format(tostring(why)))
    check(tostring(why):lower():find('blimp') ~= nil,
        ('4.5: naming the kind it could not create (%s)'):format(tostring(why)))
    check(#callsNamed(env, 'CreateObjectNoOffset') == 0
            and #callsNamed(env, 'CreateVehicleServerSetter') == 0
            and #callsNamed(env, 'CreatePed') == 0,
        '4.5: and creates nothing at all')
    env.reset()
end

-- ============================ 4.7 · the streaming pass
--
-- TWO DEFECTS, both invisible on a server with few records and one player.
do
    -- HYSTERESIS. One threshold for entering and for leaving range means a
    -- player standing on the boundary is sent a record and removed from it on
    -- alternate passes: one extra event each way per second, and on the client a
    -- spawn and a despawn of the same prop, forever, for a player standing still.
    local env = newEnv({
        players = { [1] = { coords = { x = 5.0, y = 0.0, z = 0.0 } } },
        netOk = true,
    })
    loadSync(env)
    local id = env.EXPORTS.SyncCreate('prop', {
        model = 'prop_barrel_01',
        coords = { x = 0.0, y = 0.0, z = 0.0 },
        scope = 80.0,
    })
    env.tick()
    check(env.upsertsTo(1, id) == 1, '4.7: sent while in range')

    -- Just outside the send radius, inside the exit one.
    env.players[1].coords = { x = 90.0, y = 0.0, z = 0.0 }
    for _ = 1, 4 do env.tick() end
    check(env.removesOf(id) == 0,
        ('4.7: a player just outside range is NOT removed (%d removes)')
            :format(env.removesOf(id)))
    check(env.upsertsTo(1, id) == 1,
        '4.7: and is not re-sent either, so the client sees no churn')

    -- Well past the exit radius.
    env.players[1].coords = { x = 200.0, y = 0.0, z = 0.0 }
    for _ = 1, 4 do env.tick() end
    check(env.removesOf(id) == 1,
        ('4.7: and IS removed once past the exit radius (%d removes)')
            :format(env.removesOf(id)))

    -- And back again, which is the whole reason for the second radius.
    env.players[1].coords = { x = 5.0, y = 0.0, z = 0.0 }
    for _ = 1, 4 do env.tick() end
    check(env.upsertsTo(1, id) == 2, '4.7: and re-entering sends it once more')
    env.reset()
end

-- ONE BAD RECORD MUST NOT STOP THE PASS.
--
-- The pass walks every player against every record, so one record whose payload
-- or native call raises costs every OTHER record on the server its update --
-- silently, because a loop that dies mid-pass has sent a prefix and logged
-- nothing. That is the shape of "sync just stopped working on my server".
do
    local env = newEnv({
        players = {
            [1] = { coords = { x = 5.0, y = 0.0, z = 0.0 } },
            [2] = { coords = { x = 6.0, y = 0.0, z = 0.0 } },
        },
        netOk = true,
    })
    loadSync(env)
    local id = env.EXPORTS.SyncCreate('prop', {
        model = 'prop_barrel_01', coords = { x = 0.0, y = 0.0, z = 0.0 },
    })
    -- Creation already told both players, so the counters start at one. Both
    -- players are then walked OUT and back so that the tick under test is the
    -- one that has to send -- a test that only counts the create-time send
    -- passes whether or not the pass survives anything at all.
    env.players[1].coords = { x = 400.0, y = 0.0, z = 0.0 }
    env.players[2].coords = { x = 400.0, y = 0.0, z = 0.0 }
    env.tick()
    env.players[1].coords = { x = 5.0, y = 0.0, z = 0.0 }
    env.players[2].coords = { x = 6.0, y = 0.0, z = 0.0 }

    -- Player 1 is processed FIRST -- GetPlayers is sorted by source -- so
    -- raising there is deterministic: without a per-player guard the pass
    -- aborts and player 2 is never sent.
    local realTrigger = TriggerClientEvent
    function TriggerClientEvent(name, target, ...)
        if target == 1 then
            error('cis_test: this player explodes on purpose')
        end
        return realTrigger(name, target, ...)
    end
    env.tick()
    TriggerClientEvent = realTrigger

    check(env.upsertsTo(2, id) == 2,
        ('4.7: a player that raises does not stop the next player (%d sends, want 2)')
            :format(env.upsertsTo(2, id)))
    env.reset()
end

-- THE GRID MUST NOT LOSE A RECORD.
--
-- THE PLAYER STARTS OUT OF RANGE AND WALKS IN. That is the whole shape of these
-- cases, and getting it wrong made them worth nothing: `upsert` already tells
-- whoever is ALREADY in range about a new record, so a test that creates the
-- record with the player standing next to it never runs the streaming pass at
-- all. Two mutations survived on the strength of that -- removing the index
-- entirely, and dropping the fallback for records the index refused -- because
-- nothing in either test needed the pass to work.
--
-- `CisGrid.queryPoint` examines only the cell the POINT is in, so it is correct
-- only because records go into every cell their AABB touches. An index that is
-- right for a record at the player's own cell and wrong for one whose centre is
-- two cells away is the kind of defect that streams perfectly in testing and
-- silently drops doors on a live server.
do
    local env = newEnv({
        players = { [1] = { coords = { x = 900.0, y = 0.0, z = 0.0 } } },
        netOk = true,
    })
    loadSync(env)
    local inside = env.EXPORTS.SyncCreate('prop', {
        id = 'near1', model = 'prop_barrel_01',
        coords = { x = 0.0, y = 0.0, z = 0.0 }, scope = 80.0,
    })
    local outside = env.EXPORTS.SyncCreate('prop', {
        id = 'far1', model = 'prop_barrel_01',
        coords = { x = 500.0, y = 0.0, z = 0.0 }, scope = 80.0,
    })
    env.tick()
    check(env.upsertsTo(1, inside) == 0,
        '4.7: nothing is sent while the player is out of range')
    check(env.upsertsTo(1, outside) == 0, '4.7: and nothing is sent for the far one')

    -- Walk in to (70, 20): 72.8 m from the origin, inside scope 80, and in cell
    -- (1, 0) -- a DIFFERENT cell from the record's centre at (0, 0). That is the
    -- case a cell lookup gets wrong. The first version of this case put the
    -- player at (90, 90), which is 127 m away and out of range for reasons that
    -- had nothing to do with cells.
    env.players[1].coords = { x = 70.0, y = 20.0, z = 0.0 }
    env.tick()
    check(env.upsertsTo(1, inside) == 1,
        ('4.7: the pass finds a record inside the radius but across a cell boundary (%d)')
            :format(env.upsertsTo(1, inside)))
    check(env.upsertsTo(1, outside) == 0,
        '4.7: and still does not send the one that is 431 m away')
    env.reset()
end

-- A RECORD THE INDEX REFUSED STILL STREAMS.
--
-- `CisGrid.insert` refuses an AABB covering more than its cell budget, and
-- nothing about that refusal means the record should stop existing. A very
-- large `scope` is a legal thing for a caller to write -- a marker visible
-- across a map -- and it is exactly the input that gets refused.
do
    local env = newEnv({
        -- 5000 m away, beyond the 2000 scope below, so the create-time send has
        -- nothing to do and the streaming pass is what delivers it.
        players = { [1] = { coords = { x = 5000.0, y = 0.0, z = 0.0 } } },
        netOk = true,
    })
    loadSync(env)
    -- scope 2000 makes a 2500 m radius, an AABB covering about 79 cells each
    -- way: 6241 cells against a budget of 4096, so the index refuses it.
    local big = env.EXPORTS.SyncCreate('prop', {
        id = 'huge', model = 'prop_barrel_01',
        coords = { x = 0.0, y = 0.0, z = 0.0 }, scope = 2000.0,
    })
    env.tick()
    check(env.upsertsTo(1, big) == 0, '4.7: the huge record is out of range to start')

    env.players[1].coords = { x = 300.0, y = 0.0, z = 0.0 }
    env.tick()
    check(env.upsertsTo(1, big) == 1,
        ('4.7: a record the spatial index REFUSED still streams (%d sent)')
            :format(env.upsertsTo(1, big)))
    env.reset()
end

-- AND AT SCALE. 200 records inside one radius is a shape a cell lookup gets
-- wrong in a way a single record never will.
do
    local env = newEnv({
        players = { [1] = { coords = { x = 5000.0, y = 0.0, z = 0.0 } } },
        netOk = true,
    })
    loadSync(env)
    local ids = {}
    -- Spread so the furthest is sqrt(57^2 + 54^2) ~= 78.5, inside scope 80.
    for i = 1, 200 do
        ids[i] = env.EXPORTS.SyncCreate('prop', {
            id = 'g' .. i, model = 'prop_barrel_01',
            coords = { x = (i % 20) * 3.0, y = math.floor(i / 20) * 6.0, z = 0.0 },
            scope = 80.0,
        })
    end
    env.tick()
    env.players[1].coords = { x = 0.0, y = 0.0, z = 0.0 }
    env.tick()
    local got = 0
    for i = 1, 200 do
        if env.upsertsTo(1, ids[i]) == 1 then got = got + 1 end
    end
    check(got == 200,
        ('4.7: the pass delivers every one of 200 in-range records (%d did)'):format(got))
    env.reset()
end

-- ============================ 4.8 · a client that has lost its state asks
--
-- THE DEFECT. The streaming pass only sends a record to a player the server
-- believes does NOT already hold it. That belief lives in `has[src]`, on the
-- server, and nothing ever revises it when the CLIENT forgets.
--
-- A client restart is the ordinary way that happens: the client scripts reload,
-- its `entities` and `records` go with them, and it holds nothing. The server
-- still has every key in `has[src]`, so the pass finds them all "already sent"
-- and sends nothing. Every synced entity on the server is then permanently
-- invisible to that client, with no error anywhere and no event to wait for.
--
-- The same shape covers a client that missed events while the resource was
-- restarting, which is the only window in which that is possible.
do
    local env = newEnv({
        players = { [1] = { coords = { x = 5000.0, y = 0.0, z = 0.0 } } },
        netOk = true,
    })
    loadSync(env)
    local id = env.EXPORTS.SyncCreate('prop', {
        model = 'prop_barrel_01', coords = { x = 0.0, y = 0.0, z = 0.0 },
    })
    env.players[1].coords = { x = 5.0, y = 0.0, z = 0.0 }
    env.tick()
    check(env.upsertsTo(1, id) == 1, '4.8: sent when the player walks into range')

    -- The client's state is gone; the server's is not. Nothing happens on its
    -- own, which is the whole defect.
    for _ = 1, 3 do env.tick() end
    check(env.upsertsTo(1, id) == 1,
        '4.8: and the pass does not re-send it unprompted (the defect)')

    -- The client asks.
    env.emit('cis_libs:server:syncSnapshot', 1)
    check(env.upsertsTo(1, id) == 2,
        ('4.8: a snapshot request re-sends what the client lost (%d sends)')
            :format(env.upsertsTo(1, id)))
    env.reset()
end

-- AND THE SNAPSHOT IS SCOPED TO THE PLAYER WHO ASKED. It clears one `has`
-- entry; clearing every player's would drop every entity on the server for
-- everyone, which is the opposite of a recovery.
do
    local env = newEnv({
        players = {
            [1] = { coords = { x = 5.0, y = 0.0, z = 0.0 } },
            [2] = { coords = { x = 6.0, y = 0.0, z = 0.0 } },
        },
        netOk = true,
    })
    loadSync(env)
    local id = env.EXPORTS.SyncCreate('prop', {
        model = 'prop_barrel_01', coords = { x = 0.0, y = 0.0, z = 0.0 },
    })
    env.tick()
    check(env.upsertsTo(1, id) == 1 and env.upsertsTo(2, id) == 1,
        '4.8: both players hold it before the snapshot')

    env.emit('cis_libs:server:syncSnapshot', 1)
    env.tick()
    check(env.upsertsTo(1, id) == 2, '4.8: the asking player is re-sent')
    check(env.upsertsTo(2, id) == 1, '4.8: and the other player is left alone')
    env.reset()
end

-- A SNAPSHOT IS A REQUEST, NOT A DOOR. It clears bookkeeping and sends what is
-- visible; it never invents a record for a player who is nowhere near one, and
-- it never sends a record from another bucket.
do
    local env = newEnv({
        players = { [1] = { coords = { x = 5.0, y = 0.0, z = 0.0 }, bucket = 2 } },
        netOk = true,
    })
    loadSync(env)
    local mine = env.EXPORTS.SyncCreate('prop', {
        id = 'mine', model = 'prop_barrel_01',
        coords = { x = 0.0, y = 0.0, z = 0.0 }, bucket = 2,
    })
    local theirs = env.EXPORTS.SyncCreate('prop', {
        id = 'theirs', model = 'prop_barrel_01',
        coords = { x = 0.0, y = 0.0, z = 0.0 }, bucket = 7,
    })
    env.emit('cis_libs:server:syncSnapshot', 1)
    -- TWO sends, not one: once when the record was created with the player
    -- standing there, and once because the snapshot was asked for.
    check(env.upsertsTo(1, mine) == 2,
        ('4.8: the snapshot re-sends what is in the player\'s own bucket (%d)')
            :format(env.upsertsTo(1, mine)))
    check(env.upsertsTo(1, theirs) == 0,
        '4.8: and nothing from another world')
    env.reset()
end

-- A SNAPSHOT WITH NO PLAYER BEHIND IT IS REFUSED.
--
-- `source` is 0 for a server-side trigger and -1 for a scheduled one, so
-- neither is a player. Handling it anyway would clear `has[0]` and walk a body
-- that does not exist -- the harness's coords for src 0 are the origin, so the
-- records it would find are the ones around (0,0,0), and the target on the
-- event is the server itself.
do
    local env = newEnv({
        players = { [1] = { coords = { x = 5.0, y = 0.0, z = 0.0 } } },
        netOk = true,
    })
    loadSync(env)
    local id = env.EXPORTS.SyncCreate('prop', {
        model = 'prop_barrel_01', coords = { x = 0.0, y = 0.0, z = 0.0 },
    })
    env.tick()
    check(env.upsertsTo(1, id) == 1, '4.8: the real player holds it to start')

    env.emit('cis_libs:server:syncSnapshot', 0)
    env.emit('cis_libs:server:syncSnapshot', -1)
    check(#env.sentTo(0, 'cis_libs:client:syncUpsert') == 0,
        ('4.8: a snapshot with source 0 sends nothing to a target that is the server (%d sent)')
            :format(#env.sentTo(0, 'cis_libs:client:syncUpsert')))

    -- And it did not disturb the player that IS there.
    env.emit('cis_libs:server:syncSnapshot', 1)
    check(env.upsertsTo(1, id) == 2,
        ('4.8: and the real player still recovers (%d sends)')
            :format(env.upsertsTo(1, id)))
    env.reset()
end

-- ============================ 4.9 · what the client is told, and nothing else
--
-- THE DEFECT. `payload` was a DENY-list: everything except `print`, `rev`,
-- `dynamic`, `scope` and `bucket` went to the client. A deny-list grows by
-- accident -- every field a consumer adds to a record is sent, forever, to every
-- client in range, with no size check and no review.
--
-- An ALLOW-list inverts it. A field the client needs is named; a field nobody
-- named does not go. A new field is inert until it is added on purpose.
do
    local env = newEnv({
        players = { [1] = { coords = { x = 5.0, y = 0.0, z = 0.0 } } },
        netOk = true,
    })
    loadSync(env)
    env.EXPORTS.SyncCreate('prop', {
        model = 'prop_barrel_01', coords = { x = 0.0, y = 0.0, z = 0.0 },
        myCustomThing = 'should not travel',
        owner_hint = 'cis_anyProduct',
    })
    env.tick()
    local record = env.sentTo(1, 'cis_libs:client:syncUpsert')[1].args[1]

    check(record ~= nil, '4.9: the record reached the client at all')
    check(record.myCustomThing == nil,
        '4.9: a field the client does not need does NOT travel')
    check(record.owner_hint == nil, '4.9: nor any other unlisted field')
    check(record.owner == nil,
        '4.9: and not the owning resource name, which is server bookkeeping')
    check(record.model == 'prop_barrel_01' and record.kind == 'prop'
            and record.key ~= nil and record.coords ~= nil,
        '4.9: the fields the client DOES need all arrive')
    env.reset()
end

-- AND CONSUMER DATA TRAVELS IN ONE NAMED, SIZE-CAPPED PLACE. `clientData` is
-- the whole of it -- a record carrying an inventory table would otherwise be
-- copied to every client in range on every pass it is dynamic.
do
    local env = newEnv({
        players = { [1] = { coords = { x = 5.0, y = 0.0, z = 0.0 } } },
        netOk = true,
    })
    loadSync(env)
    env.EXPORTS.SyncCreate('prop', {
        id = 'good', model = 'prop_barrel_01',
        coords = { x = 0.0, y = 0.0, z = 0.0 },
        clientData = { label = 'ATM', cash = true },
    })
    -- A caller who tries the old way gets nothing rather than everything.
    env.EXPORTS.SyncCreate('prop', {
        id = 'sneaky', model = 'prop_barrel_01',
        coords = { x = 0.0, y = 0.0, z = 0.0 },
        label = 'ATM',
    })
    env.tick()
    local withData, without
    for _, e in ipairs(env.sentTo(1, 'cis_libs:client:syncUpsert')) do
        if e.args[1].clientData then withData = e.args[1] else without = e.args[1] end
    end
    check(withData ~= nil and withData.clientData.label == 'ATM'
            and withData.clientData.cash == true,
        '4.9: clientData arrives intact')
    check(without ~= nil and without.label == nil,
        '4.9: and the same field outside it does not')
    env.reset()
end

-- THE CAP IS REAL. A clientData big enough to be a denial of service is cut
-- down, not shipped.
do
    local env = newEnv({
        players = { [1] = { coords = { x = 5.0, y = 0.0, z = 0.0 } } },
        netOk = true,
    })
    loadSync(env)
    local huge = {}
    for i = 1, 5000 do huge['k' .. i] = i end
    env.EXPORTS.SyncCreate('prop', {
        id = 'huge', model = 'prop_barrel_01',
        coords = { x = 0.0, y = 0.0, z = 0.0 },
        clientData = huge,
    })
    env.tick()
    local record
    for _, e in ipairs(env.sentTo(1, 'cis_libs:client:syncUpsert')) do
        if e.args[1].id == 'huge' then record = e.args[1] end
    end
    check(record ~= nil, '4.9: the record with the huge clientData still arrives')
    local n = 0
    if record and record.clientData then
        for _ in pairs(record.clientData) do n = n + 1 end
    end
    check(n < 5000,
        ('4.9: an oversized clientData is cut down (%d of 5000 keys sent)'):format(n))
    env.reset()
end

-- A clientData THAT IS NOT A TABLE IS REFUSED, not passed through. A string or
-- a number here would otherwise reach every client in range as whatever the
-- caller felt like putting in it.
do
    local env = newEnv({
        players = { [1] = { coords = { x = 5.0, y = 0.0, z = 0.0 } } },
        netOk = true,
    })
    loadSync(env)
    env.EXPORTS.SyncCreate('prop', {
        id = 's', model = 'prop_barrel_01',
        coords = { x = 0.0, y = 0.0, z = 0.0 },
        clientData = 'just a string',
    })
    env.tick()
    local record
    for _, e in ipairs(env.sentTo(1, 'cis_libs:client:syncUpsert')) do
        if e.args[1].id == 's' then record = e.args[1] end
    end
    check(record ~= nil and record.clientData == nil,
        '4.9: a clientData that is not a table is refused')
    env.reset()
end

-- ================================================ 4.10a. the dedupe fingerprint
--
-- WHAT THE INDEX IS. `byContent` answers "does a record with THIS content
-- already exist?", which is the question an idless upsert asks. Its key used to
-- be `kind .. SEP .. fingerprint`, and the fingerprint walks every field of the
-- record EXCEPT the three this file writes itself (`rev`, `print`, `id`).
--
-- `owner` is not one of those three, so the owner was inside the fingerprint --
-- by ACCIDENT, as a side effect of a walk whose stated purpose was "a caller
-- changing any field is never silently dropped". Nothing said the owner
-- belonged there, and nothing would have failed if it stopped being there.
--
-- The consequence is not theoretical. An idless caller in res_a and an idless
-- caller in res_b asking for a prop of the same model at the same place are
-- describing TWO entities that belong to TWO resources. Merge them and res_b
-- gets back res_a's id: its own record was never created, its entity was never
-- spawned, and the id it now holds names a record it does not own -- so
-- `SyncRemove` on it answers "belongs to another resource". One resource's prop
-- silently replaces another's, which is the same defect the `owner \0 id`
-- namespace exists to prevent, one layer up.
do
    local env = newEnv({ players = { [1] = { coords = { x = 5.0, y = 0.0, z = 0.0 } } } })
    loadSync(env)

    local function idlessAs(ownerName)
        env.invoking = ownerName
        local made = env.EXPORTS.SyncCreate('prop', {
            model = 'prop_barrel_01',
            coords = { x = 0.0, y = 0.0, z = 0.0 },
        })
        env.invoking = 'cis_anyProduct'
        return made
    end

    local a1 = idlessAs('res_a')
    local b1 = idlessAs('res_b')
    check(a1 ~= nil and b1 ~= nil, '4.10a: two resources each get an id from an idless upsert')
    -- THE ASSERTION. Same kind, same model, same coordinates, no ids anywhere.
    -- The only thing that distinguishes them is WHO ASKED, and if the owner is
    -- not in the content key they are one record.
    check(a1 ~= b1,
        ('4.10a: an idless record of res_a is NOT merged with the same content '
            .. 'in res_b (got the same id %s twice)'):format(tostring(a1)))

    -- And the merged case is not merely a shared id: each must still be
    -- removable by the resource that owns it. If res_b holds res_a's id, then
    -- `SyncRemove` from res_b is refused, and res_b's entity can never be taken
    -- down -- which is how a prop outlives the resource that made it.
    env.invoking = 'res_b'
    local removed, why = env.EXPORTS.SyncRemove(b1)
    env.invoking = 'cis_anyProduct'
    check(removed == true,
        ('4.10a: res_b can remove its own idless record (got %s: %s)')
            :format(tostring(removed), tostring(why)))
    env.reset()
end

-- SAME OWNER, SAME CONTENT, NO ID: this is the dedupe the index exists for, and
-- it must keep working. Paired with the case above on purpose -- a fix that
-- simply stopped deduplicating would pass the cross-owner test and break every
-- idless caller on the server, spawning a duplicate entity per call.
do
    local env = newEnv({ players = { [1] = { coords = { x = 5.0, y = 0.0, z = 0.0 } } } })
    loadSync(env)
    local first = env.EXPORTS.SyncCreate('prop', {
        model = 'prop_barrel_01',
        coords = { x = 0.0, y = 0.0, z = 0.0 },
    })
    local second = env.EXPORTS.SyncCreate('prop', {
        model = 'prop_barrel_01',
        coords = { x = 0.0, y = 0.0, z = 0.0 },
    })
    check(first == second,
        '4.10a: the SAME owner asking twice with identical content gets one record')
    env.reset()
end

-- ================================================ 4.10b. coords rounded to 0.01
--
-- The fingerprint's job is to answer "same entity?", and the question is asked
-- with a coordinate that a caller computed. Nothing rounds it: two resources
-- that both read a ped's position, and one that reads it a frame later, produce
-- two records for one entity -- and with the old key they were also free to be
-- merged with a DIFFERENT resource's record. The rounding is what makes "the
-- same place" a decidable question instead of a float comparison.
--
-- 0.01 is a hundredth of a game unit, which is a centimetre: finer than any
-- entity the platform streams, coarse enough to absorb float noise.
do
    local env = newEnv({ players = { [1] = { coords = { x = 5.0, y = 0.0, z = 0.0 } } } })
    loadSync(env)
    -- Both sets land in the SAME HUNDREDTH on every axis, which is the point.
    --
    -- Written the obvious way first -- -3.002 against -3.007, five thousandths
    -- apart -- and it failed for a reason that was not a defect: the pair
    -- straddles the -3.005 rounding boundary, so a value 3 thousandths closer
    -- rounds down on one side and up on the other, and they ARE different
    -- places. "Within 0.01" is the tolerance; "lands in the same hundredth" is
    -- what the fingerprint compares. A test that asserts the tolerance against
    -- data that straddles a boundary is testing the rounding, not the rule.
    local a = env.EXPORTS.SyncCreate('prop', {
        model = 'prop_barrel_01',
        coords = { x = 10.004, y = -3.001, z = 71.996 },
    })
    local b = env.EXPORTS.SyncCreate('prop', {
        model = 'prop_barrel_01',
        coords = { x = 10.001, y = -3.004, z = 71.998 },
    })
    check(a == b,
        ('4.10a: coords differing by less than 0.01 are the same place, so one '
            .. 'record (got %s and %s)'):format(tostring(a), tostring(b)))
    env.reset()
end

-- AND THE OTHER DIRECTION. A rounding that is too coarse merges two entities a
-- player can see is two, which is the failure the index is supposed to prevent
-- -- a rounding test that only proves "close things merge" passes just as well
-- with a rounding of 1000.0.
do
    local env = newEnv({ players = { [1] = { coords = { x = 5.0, y = 0.0, z = 0.0 } } } })
    loadSync(env)
    local a = env.EXPORTS.SyncCreate('prop', {
        model = 'prop_barrel_01',
        coords = { x = 10.0, y = 0.0, z = 0.0 },
    })
    local b = env.EXPORTS.SyncCreate('prop', {
        model = 'prop_barrel_01',
        coords = { x = 12.0, y = 0.0, z = 0.0 },
    })
    check(a ~= b, '4.10a: coords two metres apart are two records')
    env.reset()
end

-- ============================================== 4.10c. server list() and clear()
--
-- A resource that syncs entities and then stops needs to know what it left
-- behind, and a resource reloading its map needs to take the old entities down
-- before it puts new ones up. Neither had a way to ask. The scoping is the whole
-- of the feature: these answers are the caller's own records and nothing else,
-- because a list that named another resource's entities is a map of every prop
-- on the server handed to whichever resource asked, and a clear that reached
-- across owners is one resource's reload deleting every other resource's world.
do
    local env = newEnv({ players = { [1] = { coords = { x = 5.0, y = 0.0, z = 0.0 } } } })
    loadSync(env)

    local function makeAs(ownerName, id, x)
        env.invoking = ownerName
        local made = env.EXPORTS.SyncCreate('prop', {
            id = id, model = 'prop_barrel_01',
            coords = { x = x, y = 0.0, z = 0.0 },
        })
        env.invoking = 'cis_anyProduct'
        return made
    end

    makeAs('res_a', 'a-one', 0.0)
    makeAs('res_a', 'a-two', 15.0)
    makeAs('res_b', 'b-one', 30.0)

    env.invoking = 'res_a'
    local mine = env.EXPORTS.SyncList()
    env.invoking = 'res_b'
    local theirs = env.EXPORTS.SyncList()
    env.invoking = 'cis_anyProduct'

check(type(mine) == 'table', '4.10c: SyncList answers a table')
    -- The counts are read into locals FIRST. A `#mine` inside the message is
    -- evaluated even when the condition is false, so a missing answer raised
    -- inside its own failure text and took the whole suite down with it --
    -- which hides every assertion above it, including the ones that were
    -- genuinely red.
    local mineCount = type(mine) == 'table' and #mine or -1
    local theirCount = type(theirs) == 'table' and #theirs or -1
    check(mineCount == 2,
        ('4.10c: it lists the CALLER\'s records and no others (got %s for res_a, '
            .. 'which owns 2 of 3)'):format(tostring(mineCount)))
    check(theirCount == 1,
        ('4.10c: and res_b sees only its own (got %s, which owns 1 of 3)')
            :format(tostring(theirCount)))

    -- The ids it names must be the CALLER'S ids, not the namespaced keys. A
    -- consumer handing one of these straight back to SyncRemove is the whole
    -- use, and a namespaced key would not resolve -- it would be escaped
    -- against the caller's own namespace a second time.
    local named = {}
    for _, entry in ipairs(type(mine) == 'table' and mine or {}) do
        named[entry.id] = true
    end
    check(named['a-one'] == true and named['a-two'] == true,
        '4.10c: it answers the caller\'s own ids, not internal keys')
    env.reset()
end

-- clear() takes the caller's records down AND tells every client holding them.
-- The announcement is the part that matters: a record removed without a remove
-- leaves a client-local entity in the world forever, and this is the path a
-- resource takes on reload, so it is the common case rather than an edge one.
do
    local env = newEnv({ players = { [1] = { coords = { x = 5.0, y = 0.0, z = 0.0 } } } })
    loadSync(env)

    local function makeAs(ownerName, id, x)
        env.invoking = ownerName
        local made = env.EXPORTS.SyncCreate('prop', {
            id = id, model = 'prop_barrel_01',
            coords = { x = x, y = 0.0, z = 0.0 },
        })
        env.invoking = 'cis_anyProduct'
        return made
    end

    local mineA = makeAs('res_a', 'a-one', 0.0)
    local mineB = makeAs('res_a', 'a-two', 15.0)
    local theirs = makeAs('res_b', 'b-one', 30.0)
    env.tick()

    env.invoking = 'res_a'
    local n = env.EXPORTS.SyncClear()
    env.invoking = 'cis_anyProduct'

    check(n == 2, ('4.10c: clear answers how many of the CALLER\'s records it took (got %s)'):format(tostring(n)))
    check(env.removesTo(1, mineA) == 1 and env.removesTo(1, mineB) == 1,
        '4.10c: and every client holding one is told to despawn it')
    check(env.removesTo(1, theirs) == 0,
        '4.10c: another resource\'s record is untouched and still on the wire')

    -- Nothing left behind, or a re-sync spawns a duplicate next to the old one.
    env.invoking = 'res_a'
    local left = env.EXPORTS.SyncList()
    env.invoking = 'cis_anyProduct'
    check(type(left) == 'table' and #left == 0, '4.10c: the caller holds nothing after a clear')

    -- And the other resource's record still streams, which is the same
    -- "walks out of range and comes back" assertion 4.9's ownership test used.
    env.players[1] = { coords = { x = 5000.0, y = 5000.0, z = 0.0 } }
    env.tick()
    env.players[1] = { coords = { x = 5.0, y = 0.0, z = 0.0 } }
    env.tick()
    check(env.upsertsTo(1, theirs) == 2,
        '4.10c: a record that survived another resource\'s clear still streams')
    env.reset()
end

-- clear() on a caller with nothing is 0, not an error. A reload path calls it
-- unconditionally, and a resource that refuses that has to wrap every call in a
-- check for a condition it cannot see.
do
    local env = newEnv({ players = { [1] = { coords = { x = 5.0, y = 0.0, z = 0.0 } } } })
    loadSync(env)
    env.invoking = 'res_a'
    local n = env.EXPORTS.SyncClear()
    local list = env.EXPORTS.SyncList()
    env.invoking = 'cis_anyProduct'
    check(n == 0, '4.10c: clearing a caller that holds nothing answers 0')
    check(type(list) == 'table' and #list == 0, '4.10c: and its list is empty, not nil')
    env.reset()
end

-- Both answers come from the CALLER's namespace, so they must be refused for a
-- resource that is not allow-listed -- exactly as SyncCreate is. Otherwise the
-- allow-list, which exists to keep an unapproved resource out of the sync
-- system, has a read path straight past it.
do
    local env = newEnv({ players = { [1] = { coords = { x = 5.0, y = 0.0, z = 0.0 } } } })
    loadSync(env)
    env.EXPORTS.SyncCreate('prop', {
        id = 'mine', model = 'prop_barrel_01',
        coords = { x = 0.0, y = 0.0, z = 0.0 },
    })
    function CisInvokingAllowed() return false end
    local list, why = env.EXPORTS.SyncList()
    local cleared = env.EXPORTS.SyncClear()
    check(list == nil and cleared == nil,
        '4.10c: an un-authorised resource gets no list and no clear')
    check(type(why) == 'string' and why:find('not', 1, true) ~= nil,
        ('4.10c: and the refusal says why (got %s)'):format(tostring(why)))
    env.reset()
end

-- ================================================ 4.11. the dynamic tally
--
-- THE PLAN SAYS `dynamicCount` IS NEVER READ, and that is REFUTED: it feeds
-- `out.dynamic` in the `syncRecords` probe. So the VALUE stays. What is wrong
-- with it is the reason it gives for existing.
--
-- The comment claims the counter is what keeps the streaming pass from scanning
-- every record each second. The pass has never read it -- it goes through the
-- spatial index either way -- so four write sites on the upsert and remove paths
-- are justified by a performance claim the code does not deliver.
--
-- The tally is still worth having, because the diagnostics probe already walks
-- every record to answer `total`, and counting the dynamic ones there costs
-- nothing extra. That is strictly better than a counter, for a reason that is
-- not tidiness: a counter has to be decremented on every path that removes a
-- record, and a future path that forgets is a diagnostic that silently lies to
-- an operator. A wrong number is worse than no number, because nothing about it
-- looks wrong.
--
-- This is a PRESERVATION test, not a red-first one: it passes both before and
-- after, because the point is that the number does not move. A test that only
-- passes afterwards would be describing a behaviour change, and this is not one.
do
    local env = newEnv({ players = { [1] = { coords = { x = 5.0, y = 0.0, z = 0.0 } } } })
    -- BOTH HALVES, in the manifest's order. shared/diagnostics.lua is the
    -- REGISTRY a probe registers into; server/proxy.lua is what exports
    -- GetDiagnostics. Loading only the first answers nothing, and loading them
    -- after sync is a configuration that never happens on a real server --
    -- sync registers its probe at load time.
    loadModule('shared/diagnostics.lua')
    loadModule('server/proxy.lua')
    loadSync(env)

    local function dynamic()
        return ((env.EXPORTS.GetDiagnostics().probes or {}).syncRecords or {}).dynamic
    end

    check(dynamic() == 0, '4.11: an empty server reports no dynamic records')

    env.EXPORTS.SyncCreate('prop', {
        id = 's1', model = 'prop_barrel_01',
        coords = { x = 0.0, y = 0.0, z = 0.0 },
    })
    env.EXPORTS.SyncCreate('prop', {
        id = 'd1', model = 'prop_barrel_01',
        coords = { x = 5.0, y = 0.0, z = 0.0 }, dynamic = true,
    })
    check(dynamic() == 1,
        ('4.11: one dynamic record of two is counted (got %s)'):format(tostring(dynamic())))

    -- THE FLIP, which is where a naive `if stored.dynamic then count = count + 1`
    -- goes wrong: a record that BECOMES dynamic has to be added, not counted
    -- twice, and one that STOPS being dynamic has to be subtracted.
    env.EXPORTS.SyncCreate('prop', {
        id = 's1', model = 'prop_barrel_01',
        coords = { x = 0.0, y = 0.0, z = 0.0 }, dynamic = true,
    })
    check(dynamic() == 2,
        ('4.11: a static record that becomes dynamic is added (got %s)')
            :format(tostring(dynamic())))

    env.EXPORTS.SyncCreate('prop', {
        id = 'd1', model = 'prop_barrel_01',
        coords = { x = 5.0, y = 0.0, z = 0.0 },
    })
    check(dynamic() == 1,
        ('4.11: one that stops being dynamic is subtracted (got %s)')
            :format(tostring(dynamic())))

    env.EXPORTS.SyncRemove('d1')
    check(dynamic() == 1,
        ('4.11: removing a static record does not touch the tally (got %s)')
            :format(tostring(dynamic())))

    env.EXPORTS.SyncRemove('s1')
    check(dynamic() == 0,
        ('4.11: and removing the last dynamic one returns it to zero (got %s)')
            :format(tostring(dynamic())))
    env.reset()
end

-- ================================================ 4.12. scale
--
-- A THOUSAND RECORDS, and one player in the middle of them.
--
-- Every other sync test here has between one and three records, so the suite has
-- never asked the two questions that only appear at scale: does the spatial
-- index still find the records it should, and does a player standing among a
-- thousand get the RIGHT ones rather than a plausible subset.
--
-- The layout is deliberate. Records sit on a 100 m grid and the default radius
-- is 80 m, so the player is inside a count that can be worked out from the
-- geometry rather than guessed at. That is what makes the assertion worth
-- anything: an index that quietly stopped indexing delivers all 1,024, one that
-- indexed wrongly delivers some arbitrary subset, and "some arrived" cannot tell
-- those two apart. The COUNT is the assertion.
do
    local env = newEnv({ players = { [1] = { coords = { x = 0.0, y = 0.0, z = 0.0 } } } })
    -- Diagnostics and the GetDiagnostics export FIRST: sync registers its probe
    -- when the file loads, so a registry that arrives afterwards is a
    -- configuration no real server ever has.
    loadModule('shared/diagnostics.lua')
    loadModule('server/proxy.lua')
    loadSync(env)

    local GRID = 32          -- 32 x 32 = 1,024 records
    local SPACING = 100.0    -- and with an 80 m radius, only the centre is in range
    for i = 0, GRID - 1 do
        for j = 0, GRID - 1 do
            env.EXPORTS.SyncCreate('prop', {
                id = ('g-%d-%d'):format(i, j),
                model = 'prop_barrel_01',
                coords = { x = (i - GRID / 2) * SPACING, y = (j - GRID / 2) * SPACING, z = 0.0 },
            })
        end
    end

    local probes = env.EXPORTS.GetDiagnostics().probes.syncRecords
    check(probes and probes.total == GRID * GRID,
        ('4.12: a thousand records are all stored (got %s)')
            :format(tostring(probes and probes.total)))

    env.tick()
    local near = env.sentTo(1, 'cis_libs:client:syncUpsert')
    -- Exactly one: at (0,0) the player is standing on that record, and the four
    -- grid neighbours are 100 m away, outside the 80 m radius.
    check(#near == 1,
        ('4.12: a player among 1024 records is sent only those within the radius '
            .. '(got %d, expected 1 at an exact grid point)'):format(#near))

    -- OFF THE GRID POINT, into the 2x2 block around it. From (40,40) the
    -- distances to (0,0), (0,100) and (100,0) are 56.6, 72.1 and 72.1 -- all
    -- inside 80. The fourth corner (100,100) is 84.9 and correctly out. So two
    -- NEW records, three in total.
    env.players[1] = { coords = { x = 40.0, y = 40.0, z = 0.0 } }
    env.tick()
    local moved = env.sentTo(1, 'cis_libs:client:syncUpsert')
    check(#moved == 3,
        ('4.12: walking into the 2x2 block brings exactly two more (total %d, expected 3)')
            :format(#moved))

    -- AND THE WALK OUT, which is the half that leaves orphans. Every one of the
    -- three must be taken back, or the client is holding props in a world it
    -- left and nothing will ever remove them.
    env.players[1] = { coords = { x = 9000.0, y = 9000.0, z = 0.0 } }
    env.tick()
    local removals = env.sentTo(1, 'cis_libs:client:syncRemove')
    check(#removals == 3,
        ('4.12: and walking away removes all three (got %d)'):format(#removals))
    env.reset()
end

-- THE DEDUPE INDEX AT SCALE, which is a different question from streaming: 1,000
-- idless records that differ only in a coordinate must all stay distinct, and
-- the index that decides that is the one every idless caller leans on.
do
    local env = newEnv({ players = { [1] = { coords = { x = 0.0, y = 0.0, z = 0.0 } } } })
    loadSync(env)
    local first = env.EXPORTS.SyncCreate('prop', {
        model = 'prop_barrel_01',
        coords = { x = 1.0, y = 2.0, z = 3.0 },
    })
    local seen = { [first] = true }
    local collapsed = 0
    for i = 1, 999 do
        local id = env.EXPORTS.SyncCreate('prop', {
            model = 'prop_barrel_01',
            coords = { x = 1.0 + i, y = 2.0, z = 3.0 },
        })
        if seen[id] then collapsed = collapsed + 1 end
        seen[id] = true
    end
    check(collapsed == 0,
        ('4.12: a thousand idless records at distinct places stay distinct '
            .. '(%d collapsed)'):format(collapsed))

    -- And the same content asked for twice is still ONE record at scale. A
    -- "fix" for the assertion above that simply stopped deduplicating would
    -- pass it, and this is what catches that.
    local again = env.EXPORTS.SyncCreate('prop', {
        model = 'prop_barrel_01',
        coords = { x = 501.0, y = 2.0, z = 3.0 },
    })
    check(seen[again] == true,
        '4.12: and re-asking for one of them still resolves to the same record')
    env.reset()
end

-- ===================================================== 7.6 Cis.command
do
    local env = newEnv({})
    env.commands = {}
    env.ace = {}
    env.chat = {}
    function RegisterCommand(name, fn, restricted)
        env.commands[name] = { fn = fn, restricted = restricted }
    end
    function IsPrincipalAceAllowed(principal, object)
        env.ace[#env.ace + 1] = { principal = principal, object = object }
        return env.aceAllow == true
    end
    function GetResourceState(name)
        if name == 'chat' then return env.chatStarted and 'started' or 'missing' end
        return 'missing'
    end
    function TriggerClientEvent(name, target, ...)
        env.chat[#env.chat + 1] = { name = name, target = target, args = table.pack(...) }
    end
    function GetInvokingResource() return 'cis_libs' end
    loadModule('server/command.lua')

    local parsed = exports.CommandParse('give "hello world" 5')
    check(#parsed == 3 and parsed[1] == 'give' and parsed[2] == 'hello world' and parsed[3] == '5',
        ('7.6: quoted arguments group (got %s)'):format(tostring(parsed and table.concat(parsed, '|'))))

    local ran = {}
    local ok, why = exports.CommandAdd('cis_test_cmd', { params = { 'item' }, help = 'give an item' }, function(src, args, raw)
        ran[#ran + 1] = { src = src, args = args, raw = raw }
    end)
    check(ok == true, ('7.6: add accepts a function handler (got %s, %s)'):format(tostring(ok), tostring(why)))
    check(env.commands['cis_test_cmd'] ~= nil, '7.6: RegisterCommand was called')
    check(env.commands['cis_test_cmd'].restricted == false, '7.6: unrestricted commands are not ACE-gated')

    env.commands['cis_test_cmd'].fn(1, { 'bread' }, 'cis_test_cmd bread')
    check(#ran == 1 and ran[1].src == 1 and ran[1].args[1] == 'bread',
        '7.6: handler is (src, args, raw) with src injected, not taken from the caller')

    local badFn, badWhy = exports.CommandAdd('nope', {}, 'not a function')
    check(badFn == false and type(badWhy) == 'string' and badWhy:find('function', 1, true),
        ('7.6: a non-function handler is refused by name (got %s)'):format(tostring(badWhy)))

    env.aceAllow = false
    local adminRan = 0
    local okR = exports.CommandAdd('cis_admin_cmd', { restricted = true }, function() adminRan = adminRan + 1 end)
    check(okR == true, '7.6: restricted=true is accepted (true/false/group string)')
    check(env.commands['cis_admin_cmd'].restricted == true, '7.6: RegisterCommand restricted flag is true')
    env.commands['cis_admin_cmd'].fn(7, {}, 'cis_admin_cmd')
    check(#env.ace == 1 and env.ace[1].principal == 'player.7' and env.ace[1].object == 'command.cis_admin_cmd',
        ('7.6: ACE check is (player.SRC, command.NAME) strings, not a numeric source (got %s, %s)')
            :format(tostring(env.ace[1] and env.ace[1].principal), tostring(env.ace[1] and env.ace[1].object)))
    check(adminRan == 0, '7.6: a refused ACE does not run the handler')

    env.chatStarted = true
    exports.CommandAdd('cis_chat_cmd', { help = 'hello', params = { 'who' } }, function() end)
    check(#env.chat == 1 and env.chat[1].name == 'chat:addSuggestion' and env.chat[1].target == -1,
        '7.6: a started chat resource gets a suggestion ')
    env.reset()
end

-- ==================================================================== report
-- Named, not just counted. A suite that reports "failed=3" and exits tells you
-- something broke and nothing about what, and the fix is to re-run with a print
-- statement added -- which is how a red suite ends up being ignored.
for i = 1, #failures do
    io.stderr:write('FAIL(server): ' .. failures[i] .. '\n')
end
io.write(('server passed=%d failed=%d\n'):format(passed, failed))
if failed > 0 then
    os.exit(1)
end