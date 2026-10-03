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
        'RegisterNetEvent', 'TriggerClientEvent', 'TriggerEvent',
        'GetPlayerName', 'DropPlayer', 'GetResourceState',
        'NetworkGetEntityFromNetworkId', 'Entity', 'DoesEntityExist',
        'DeleteEntity', 'SetEntityCoords', 'SetEntityHeading',
        'SetNetworkedEntityLocallyVisible', 'SetNetworkedEntityLocallyInvisible',
        'promise', 'Citizen',
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
    function GetPlayerName() return 'TestPlayer' end
    function DropPlayer() end
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
    function RequestModel() env.natives[#env.natives + 1] = { name = 'RequestModel' } end
    function HasModelLoaded() return true end
    function SetModelAsNoLongerNeeded() end
    function NetworkGetNetworkIdFromEntity(e) return 4000 + (e or 0) end
    function SetEntityHeading() end
    function FreezeEntityPosition() end
    -- The server-side networked spawn. `env.netOk = false` makes it fail, which
    -- is how a test tells "the server spawned one entity" apart from "every
    -- client makes its own".
    function CreateObject(hash, x, y, z, networked)
        env.natives[#env.natives + 1] = {
            name = 'CreateObject', hash = hash, x = x, y = y, z = z, networked = networked,
        }
        if not env.netOk then return 0 end
        return env.serverEntity or 77
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

    -- T1 · THE PROMISES AND `Citizen.Await`, MATCHING THE REAL NATIVE.
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

    function env.removesOf(id)
        local n = 0
        for i = 1, #env.sent do
            local e = env.sent[i]
            if e.name == 'cis_libs:client:syncRemove' and e.args[1] == id then
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
        local n = 0
        for _, e in ipairs(env.sentTo(src, 'cis_libs:client:syncRemove')) do
            if e.args[1] == id then
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
        'L-C3: a player who walks into range is sent the static record')

    -- Walking in AGAIN must not resend. A pass every second that re-sends
    -- every nearby record forever is a per-second event storm against every
    -- client on the server.
    env.tick()
    check(env.upsertsTo(1, id) == 1,
        'L-C3: a second pass does not resend a record the player already has')
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
    check(env.upsertsTo(1, id) == 1, 'L-C3: in range, the record is sent')

    env.players[1] = { coords = { x = 5000.0, y = 5000.0, z = 0.0 } }
    env.tick()
    check(env.removesOf(id) == 1, 'L-C3: leaving the range sends a remove')

    -- And it is not re-sent on every subsequent pass while out of range.
    env.tick()
    check(env.upsertsTo(1, id) == 1, 'L-C3: an out-of-range player is not sent it again')
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
        'D-03: two resources each own a record')

    env.tick()
    check(env.upsertsTo(1, mineA) == 1 and env.upsertsTo(1, mineB) == 1,
        'D-03: the player standing between them is sent both')

    -- res_a stops.
    env.fire('onResourceStop', 'res_a')

    check(env.removesOf(mineA) == 1,
        'D-03: the stopped resource took its own record with it')

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
        'D-03: the OTHER resource\'s record is still removed from the player who '
            .. 'walks out of range (a silent drop leaves them holding it forever)')

    -- And walking back re-sends it, which also proves the content index still
    -- resolves: a record left in `records` but dropped from `byContent` would
    -- allocate a SECOND id for the same content and spawn a duplicate.
    env.players[1] = { coords = { x = 10.0, y = 0.0, z = 0.0 } }
    env.tick()
    check(env.upsertsTo(1, mineB) == 2,
        'D-03: and it streams again when the player comes back, under the SAME id')
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
        'L-C4: a synced entity is client-local by default, not networked')
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

    -- Spawned ONCE, on the server. One CreateObject call for two records of the
    -- same shape would be the duplicate bug wearing a different hat.
    local spawns = 0
    for i = 1, #env.natives do
        if env.natives[i].name == 'CreateObject' then spawns = spawns + 1 end
    end
    check(spawns == 1,
        'L-C4: a networked entity is spawned once, on the server, not once per client')
    check(env.natives[#env.natives].networked == true,
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
        'L-C3: a removed record is not streamed back on the next pass')
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

-- ======================================= 5. GetFramework returns a TABLE
--
-- `exports['cis_libs']:GetFramework()` returned `CisRegistry.resolve('framework')`
-- -- the provider's export, which is a callable or a callable TABLE once it has
-- crossed the exports boundary, and not the table its methods live in. Every
-- caller then did `fw.GetPlayer(src)` on that, got nil, and had no way to tell
-- it apart from "this player has no framework record". api.lua documents a
-- table; the source returned something else.
do
    local env = newEnv({})
    Config = CisDefaults.config()
    Security = CisDefaults.security()
    loadModule('server/security.lua')
    loadModule('server/proxy.lua')

    -- `GetFramework` waits on CisReadyState for up to 15s before giving up, and
    -- this harness's clock never reaches 15s on its own. Marked ready rather
    -- than stubbed, because the wait is part of what is being tested.
    CisReadyState.reset()
    CisReadyState.ready = true

    check(env.EXPORTS.GetFramework() == nil,
        'L-C17: GetFramework is nil when no framework is registered')

    -- Register a framework the way a product does: one export that returns the
    -- method table.
    env.EXPORTS.cis_core = {
        CisCoreFramework = function()
            return {
                get = function() return true end,
                NormalizedPlayer = function(src) return { id = src, name = 'Tester' } end,
                Notify = function() end,
                HasPermission = function(src, permission)
                    return src == 1 and permission == 'admin'
                end,
                IsLoaded = function() return true end,
            }
        end,
    }
    check(CisRegistry.register('framework', 'cis_core:CisCoreFramework'),
        'a framework provider registers')

    local fw = env.EXPORTS.GetFramework()
    check(type(fw) == 'table',
        'L-C17: GetFramework returns a TABLE, not a function: got ' .. type(fw))
    check(fw and type(fw.NormalizedPlayer) == 'function',
        'L-C17: and the table carries the provider methods')
    local player = fw and fw.NormalizedPlayer(7)
    check(player and player.id == 7,
        'L-C17: a caller can call straight into it -- fw.NormalizedPlayer(7)')
    CisRegistry.releaseOwner('cis_core')
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

    -- The command handler, captured at registration.
    local command
    local savedRegister = RegisterCommand
    RegisterCommand = function(name, fn) command = fn end
    -- server/player.lua defines CisJobCount and the job histogram; cis_debug
    -- prints a count from it, so the command cannot run without it.
    loadModule('server/player.lua')
    loadModule('server/initialize.lua')
    RegisterCommand = savedRegister

    check(command ~= nil, 'cis_debug is registered')
    if not command then
        env.reset()
        return
    end

    -- No framework at all: a player is refused, and nothing is printed.
    local before = #env.lines
    command(1)
    check(#env.lines == before,
        'L-C17: with no framework, an in-game call prints nothing')

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
    check(not threw, 'L-C17: cis_debug does not throw for an in-game admin')
    check(#env.lines > before,
        ('L-C17: cis_debug PRINTS for an in-game admin (lines=%d)'):format(#env.lines - before))

    local found = false
    for i = before + 1, #env.lines do
        if env.lines[i]:find('ready=', 1, true) then found = true end
    end
    check(found, 'L-C17: and the output is the diagnostic block, not a trace')

    -- A player who is not an admin is still refused, with no output.
    before = #env.lines
    command(2)
    check(#env.lines == before, 'L-C17: a player without the permission still gets nothing')

    -- The console, which has no src, always gets the block.
    env.lines = {}
    command(0)
    check(#env.lines > 0, 'L-C17: the console always gets the block')
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
        'L-C8: a resource:export handler registers')
    check(CisNetOn('cis_shop:buy', 'cis_shop:OnBuy') == true,
        'L-C8: registering the SAME name again is accepted, not refused')
    check(#(env.netEvents['cis_shop:buy'] or {}) == 1,
        ('L-C8: but the net event is bound ONCE, not once per registration (bound=%d)')
            :format(#(env.netEvents['cis_shop:buy'] or {})))

    -- Firing it invokes the handler exactly once.
    env.emit('cis_shop:buy', 5, 1)
    check(calls == 1,
        ('L-C8: one client action runs the handler ONCE (calls=%d)'):format(calls))
    env.reset()
end

-- ============================== L-S26: a missing export is a REFUSAL, not a raise
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
        'L-S26: a missing export is REFUSED, not raised -- the consumer keeps booting')
    check(result == false,
        'L-S26: and the refusal is false, so the caller has something to act on')

    -- The message must name the reference that failed. "registered nothing"
    -- without saying WHAT leaves an operator guessing which of thirty
    -- registrations is broken.
    local found = false
    for _, entry in ipairs(logged) do
        if tostring(entry.message):find('cis_rigid', 1, true) then found = true end
    end
    check(found, 'L-S26: and the error names the reference that failed')

    -- An export that DOES exist must still bind and still fire, or "fix" the
    -- raise by refusing everything would pass every assertion above.
    check(CisNetOn('cis_rigid:buy', 'cis_rigid:OnBuy') == true,
        'L-S26: an export that exists still registers')
    env.emit('cis_rigid:buy', 5, 1)
    check(env.buyHits == 1,
        ('L-S26: and still fires exactly once (hits=%s)'):format(tostring(env.buyHits)))

    -- A resource that is NOT running at all is the case the old guard covered,
    -- and must keep answering false rather than raising.
    local ok2, result2 = pcall(CisNetOn, 'cis_absent:ev', 'cis_absent:Nope')
    check(ok2 and result2 == false,
        'L-S26: a resource that is not running is still a plain false')

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
        'L-C9: the handler registers with a tight limit')

    for _ = 1, 100 do env.emit('cis_shop:buy', 5, 1) end

    -- Nothing yet: the line is emitted when the window ROLLS, so the count in
    -- it is the window's real total rather than "at least N so far".
    check(#logged == 0,
        ('L-C9: a flood inside one window logs nothing per event (logs=%d)'):format(#logged))

    -- A flood big enough to matter escalates to the drop handler.
    for _ = 1, 400 do env.emit('cis_shop:buy', 5, 1) end
    check(#reported == 1,
        ('L-C9: a sustained flood escalates to CisSecurityReport ONCE per window (reports=%d)')
            :format(#reported))
    if reported[1] then
        check(reported[1].reason:find('cis_shop:buy', 1, true) ~= nil,
            'L-C9: the escalation names the event')
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
    check(rolled >= 1, 'L-C9: the window roll produces a warning')
    check(rolled <= 2,
        ('L-C9: and it is ONE line per window, not one per event (lines=%d)'):format(rolled))
    if logged[before + 1] then
        local m = logged[before + 1].message
        check(m:find('cis_shop:buy', 1, true) ~= nil,
            'L-C9: the warning names the event that was limited')
        check(m:find('5', 1, true) ~= nil,
            'L-C9: and names the source it came from')
        check(m:match('%d+ events dropped') ~= nil,
            'L-C9: and carries the number of events dropped: ' .. m)
        check(logged[before + 1].channel == 'cheating',
            'L-C9: on the cheating channel, which is where an operator looks')
    end
    env.reset()
end

-- ============================ 9. a consumer's stop releases its own records
--
-- ox_lib does not have this problem because it runs inside the consumer's own
-- Lua VM, so everything a resource creates dies with it. cis_libs runs in its
-- OWN VM, so a callback outlives the resource that registered it -- silently,
-- and until the process restarts.
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
        'L-C7: res_a registers a callback')
    env.invoking = 'res_b'
    check(env.EXPORTS.RegisterCallback('b:one', function() return 'from b' end) == true,
        'L-C7: res_b registers a callback')

    local function callLocal(name)
        local got
        env.EXPORTS.CallCallback(name, function(ok, value) got = { ok = ok, value = value } end)
        return got
    end

    check(callLocal('a:one').ok == true, 'L-C7: res_a\'s callback answers before the stop')
    check(callLocal('b:one').ok == true, 'L-C7: res_b\'s callback answers before the stop')

    -- res_a stops.
    env.fire('onResourceStop', 'res_a')

    local a = callLocal('a:one')
    check(a.ok == false, 'L-C7: after res_a stops, its callback is released')
    check(tostring(a.value):find('unknown', 1, true) ~= nil,
        'L-C7: and answers "unknown", not "error" -- a consumer must be told its wiring '
            .. 'is wrong, not that its handler threw: ' .. tostring(a.value))
    check(callLocal('b:one').ok == true,
        "L-C7: res_b's callback SURVIVES another resource's stop")

    -- And the name is bindable again, which is the half that is easy to miss: a
    -- restarted resource registering the same name must not be refused against
    -- its own dead handler.
    env.invoking = 'res_a'
    check(env.EXPORTS.RegisterCallback('a:one', function() return 'from a again' end) == true,
        'L-C7: a restarted resource can register the same name again')
    check(callLocal('a:one').value == 'from a again',
        'L-C7: and the restarted handler is the one that answers')
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
    check(CisNetOn('ev:buy', 'res_a:OnBuy') == true, 'L-C7: res_a binds the event')
    env.invoking = 'res_b'
    check(CisNetOn('ev:buy', 'res_b:OnBuy') == false,
        'L-C7: a DIFFERENT resource cannot take a bound name')
    check(CisNetOn('ev:sell', 'res_b:OnBuy') == true, 'a different NAME is unaffected')

    env.fire('onResourceStop', 'res_a')
    env.invoking = 'res_b'
    check(CisNetOn('ev:buy', 'res_b:OnBuy') == true,
        'L-C7: after res_a stops, res_b CAN bind the name it was refused')
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
-- This is L-C10, and the fix is `table.unpack(packed, 1, packed.n)` on every
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
    check(foundOk == true, 'L-C10: a successful callback reports ok')
    check(foundN == 2 and found[1] and found[2] == 200,
        ('L-C10: both values survive (n=%d)'):format(foundN))

    -- The case the bug was about.
    local missing, missingN, missingOk = roundTrip('missing')
    check(missingOk == true, 'L-C10: a nil first value is not an error')
    check(missingN == 2,
        ('L-C10: the answer is TWO values, not truncated to zero (n=%d)'):format(missingN))
    check(missing[1] == nil,
        ('L-C10: the first value really is nil (got %s)'):format(tostring(missing[1])))
    check(missing[2] == 'not found',
        ('L-C10: and the REASON after it survives -- this is the whole point: %s')
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
    check(type(a) == 'table' and a.ok == true, 'L-C10: await returns the first value')
    check(b == 'extra', 'L-C10: await returns the second value too')

    -- A refusal NAMES the callback. `error('unknown')` reaches the console as
    -- "SCRIPT ERROR: @cis_libs/server/callback.lua:186: unknown", which says the
    -- library failed and says nothing about which of dozens of registered
    -- callbacks did.
    local ok, err = pcall(env.EXPORTS.AwaitCallback, 'no:such:callback')
    check(not ok, 'L-C10: awaiting a name with no handler raises')
    check(tostring(err):find('no:such:callback', 1, true) ~= nil,
        'L-C10: and the error NAMES the callback: ' .. tostring(err))
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
    check(not raised, 'L-C10: tryAwait never raises, even for an unknown name')

    local ok, value = env.EXPORTS.TryAwaitCallback('ok:one')
    check(ok == true, 'L-C10: tryAwait reports success')
    check(value == 'value', 'L-C10: tryAwait returns the handler value')

    local ok2, reason = env.EXPORTS.TryAwaitCallback('no:such:callback')
    check(ok2 == false, 'L-C10: tryAwait reports failure rather than raising')
    check(type(reason) == 'string' and reason ~= '',
        'L-C10: and carries a reason: ' .. tostring(reason))
    env.reset()
end

-- ============================================ 12. server->client callback rate
-- L-C12 · `cis_libs:cb:serverRes` went through CisNetOn with no limit of its
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
        ('L-C12: all ten server->client callbacks were sent (%d)'):format(#keys))

    -- Answer each one as the client would: (key, true, 'ok').
    for i = 1, #keys do
        env.emit('cis_libs:cb:serverRes', 7, keys[i], true, 'ok')
    end

    check(resolved == 10,
        ('L-C12: ten replies to one client in one window are ALL delivered (%d of 10)')
            :format(resolved))
    env.reset()
end

-- ================= 13. random callback names cannot grow the limiter (L-C13)
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
        ('L-C13: an UNKNOWN name allocates no rate bucket at all (buckets=%d)')
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
        ('L-C13: 10k REAL callback names stay under the per-src cap (buckets=%d)')
            :format(held))

    -- And a name that already owns a bucket keeps working at its own rate: the
    -- cap bounds the number of KEYS, it is not a throttle on a resource using a
    -- name it already holds.
    local before = CisRateBucketCount(1)
    for _ = 1, 10 do env.emit('cis_libs:cb', 1, 'real:1') end
    check(CisRateBucketCount(1) == before,
        'L-C13: reusing an existing name adds no bucket')
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
    local env = newEnv({})
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
    -- checked before the entry is consumed (L-C10), and the await has to stay
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

    -- A bad target is still refused before anything is allocated (L-C24), and
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