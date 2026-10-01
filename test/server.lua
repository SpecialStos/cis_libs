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
    function AddEventHandler() end
    function RegisterNetEvent() end
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
    local id = env.EXPORTS.SyncCreate('prop', {
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
    local EXPORTS = env.EXPORTS
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

    -- RegisterNetEvent APPENDS, as FiveM does. A test that models it as
    -- "replace" cannot see the bug at all.
    env.netHandlers = {}
    function RegisterNetEvent(name, fn)
        env.netHandlers[name] = env.netHandlers[name] or {}
        env.netHandlers[name][#env.netHandlers[name] + 1] = fn
    end
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
    check(#(env.netHandlers['cis_shop:buy'] or {}) == 1,
        ('L-C8: but the net event is bound ONCE, not once per registration (bound=%d)')
            :format(#(env.netHandlers['cis_shop:buy'] or {})))

    -- Firing it invokes the handler exactly once.
    source = 5
    for _, fn in ipairs(env.netHandlers['cis_shop:buy'] or {}) do fn(1) end
    source = nil
    check(calls == 1,
        ('L-C8: one client action runs the handler ONCE (calls=%d)'):format(calls))
    env.reset()
end

-- A DIFFERENT event name is a different handler, and must not be collapsed.
do
    local env = newEnv({})
    Config = CisDefaults.config()
    Security = CisDefaults.security()
    env.netHandlers = {}
    function RegisterNetEvent(name, fn)
        env.netHandlers[name] = env.netHandlers[name] or {}
        env.netHandlers[name][#env.netHandlers[name] + 1] = fn
    end
    exports.cis_shop = { OnBuy = function() end, OnSell = function() end }
    loadModule('server/security.lua')
    CisNetOn('cis_shop:buy', 'cis_shop:OnBuy')
    CisNetOn('cis_shop:sell', 'cis_shop:OnSell')
    check(#(env.netHandlers['cis_shop:buy'] or {}) == 1, 'the first name is bound once')
    check(#(env.netHandlers['cis_shop:sell'] or {}) == 1, 'a DIFFERENT name is bound separately')
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
    env.netHandlers = {}
    function RegisterNetEvent(name, fn)
        env.netHandlers[name] = env.netHandlers[name] or {}
        env.netHandlers[name][#env.netHandlers[name] + 1] = fn
    end
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

    source = 5
    for _ = 1, 100 do
        for _, fn in ipairs(env.netHandlers['cis_shop:buy'] or {}) do fn(1) end
    end
    source = nil

    -- Nothing yet: the line is emitted when the window ROLLS, so the count in
    -- it is the window's real total rather than "at least N so far".
    check(#logged == 0,
        ('L-C9: a flood inside one window logs nothing per event (logs=%d)'):format(#logged))

    -- A flood big enough to matter escalates to the drop handler.
    source = 5
    for _ = 1, 400 do
        for _, fn in ipairs(env.netHandlers['cis_shop:buy'] or {}) do fn(1) end
    end
    source = nil
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
    source = 5
    for _ = 1, 40 do
        for _, fn in ipairs(env.netHandlers['cis_shop:buy'] or {}) do fn(1) end
    end
    -- One more drop in the NEXT window: that is what emits the previous
    -- window's line, which is why the state has to survive the roll.
    env.clock = env.clock + 1500
    for _, fn in ipairs(env.netHandlers['cis_shop:buy'] or {}) do fn(1) end
    source = nil
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

-- ==================================================================== report
for i = 1, #failures do
    io.stderr:write('FAIL(server): ' .. failures[i] .. '\n')
end
io.write(('server passed=%d failed=%d\n'):format(passed, failed))
if failed > 0 then
    os.exit(1)
end