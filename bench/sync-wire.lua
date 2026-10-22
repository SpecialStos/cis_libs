-- Entity-sync WIRE benchmark: what server/sync.lua puts on the network.
--
--   lua5.4 bench/sync-wire.lua            (from the repository root)
--
-- NOT RUN IN CI, like bench/bench.lua. It loads the real server/sync.lua into a
-- sandbox with stubbed natives, drives a fixed workload, and counts every
-- client event the file sends: how many calls, how many payload entries, and an
-- estimate of the encoded bytes (msgpack-shaped: what FiveM serialises events
-- with). The counts are what matter -- a reliable client event is a packet on
-- the reliable channel, and the reliable channel is what overflows.
--
-- THE WORKLOAD, printed with the result so a number is never quoted without it:
--   64 players: 16 standing in a hub, 48 spread over the map, 8 of them walking
--   1000 client-local props on a 40 m lattice; 100 of them `dynamic`
--   every pass, 20 records are re-upserted with new clientData
--   60 one-second passes, then one owner stops (300 records)

local root = './'

local env = setmetatable({}, { __index = _G })
env._G = env

-- ------------------------------------------------------------------ the wire
local wire = { calls = 0, latent = 0, entries = 0, bytes = 0 }

local function sizeOf(v)
    local t = type(v)
    if t == 'nil' or t == 'boolean' then return 1 end
    if t == 'number' then
        if math.type(v) == 'integer' and v >= -32 and v < 128 then return 1 end
        return (math.type(v) == 'integer') and 5 or 9
    end
    if t == 'string' then return #v + (#v < 32 and 1 or 2) end
    if t == 'table' then
        local n = 3
        for k, x in pairs(v) do n = n + sizeOf(k) + sizeOf(x) end
        return n
    end
    return 1
end

local function countEntries(args)
    -- A batch: (n, upserts, removes).
    if type(args[1]) == 'number' and type(args[2]) == 'table' then
        return #args[2] + #(args[3] or {})
    end
    local a = args[1]
    if type(a) ~= 'table' then return 1 end
    if a.key ~= nil then return 1 end
    local n = 0
    for _ in pairs(a) do n = n + 1 end
    -- A batch event may carry a second list.
    if type(args[2]) == 'table' then
        for _ in pairs(args[2]) do n = n + 1 end
    end
    return n
end

local function record(name, target, latent, ...)
    local args = table.pack(...)
    -- -1 is a broadcast: one call, but every connected player receives it.
    local fanout = (target == -1) and 64 or 1
    wire.calls = wire.calls + fanout
    if latent then wire.latent = wire.latent + fanout end
    wire.entries = wire.entries + countEntries(args) * fanout
    local bytes = #name + 8
    for i = 1, args.n do bytes = bytes + sizeOf(args[i]) end
    wire.bytes = wire.bytes + bytes * fanout
end

-- ------------------------------------------------------------------ the world
local players = {}
local clock = 0
local invoking = 'bench_res'
local threads = {}
local handlers = {}
local entitySeq = 0

env.GetGameTimer = function() return clock end
env.Wait = function(ms) clock = clock + (ms or 0) end
env.CreateThread = function(fn) threads[#threads + 1] = fn end
env.GetCurrentResourceName = function() return 'cis_libs' end
env.GetInvokingResource = function() return invoking end
env.GetResourceState = function() return 'started' end
env.GetPlayers = function()
    local out = {}
    for src in pairs(players) do out[#out + 1] = tostring(src) end
    table.sort(out)
    return out
end
env.GetPlayerPed = function(src) return (tonumber(src) or 0) + 1000 end
env.GetPlayerRoutingBucket = function() return 0 end
env.GetEntityCoords = function(ped)
    local p = players[(ped or 0) - 1000]
    if p then return { x = p.x, y = p.y, z = p.z } end
    return { x = 0.0, y = 0.0, z = 0.0 }
end
env.joaat = function(s)
    if type(s) == 'number' then return s end
    local h = 0
    for i = 1, #s do h = (h * 31 + s:byte(i)) % 0x7FFFFFFF end
    return h
end
env.DoesEntityExist = function() return true end
env.CreateObjectNoOffset = function() entitySeq = entitySeq + 1; return entitySeq end
env.NetworkGetNetworkIdFromEntity = function(e) return e end
env.TriggerClientEvent = function(name, target, ...) record(name, target, false, ...) end
env.TriggerLatentClientEvent = function(name, target, _bps, ...) record(name, target, true, ...) end
env.AddEventHandler = function(name, fn)
    handlers[name] = handlers[name] or {}
    handlers[name][#handlers[name] + 1] = fn
end
env.RegisterNetEvent = function() end
env.CisNetOn = function() return true end
env.CisInvokingAllowed = function() return true end
env.CisSyncEnabled = function() return true end
env.Logging = { Error = function() end, Warn = function() end, Info = function() end }
env.CisLog = function() end
local exportsTable = {}
env.exports = setmetatable(exportsTable, { __call = function(t, name, fn) rawset(t, name, fn) end })

local function loadFile(rel)
    local f = assert(io.open(root .. rel, 'r'))
    local src = f:read('a')
    f:close()
    assert(load(src, '@' .. rel, 't', env))()
end

for _, rel in ipairs({
    'shared/diagnostics.lua', 'shared/timing.lua', 'shared/loopguard.lua',
    'shared/grid.lua', 'shared/owned.lua', 'server/sync.lua',
}) do
    loadFile(rel)
end

local SyncCreate = exportsTable.SyncCreate

-- ------------------------------------------------------------------ workload
local rng = 12345
local function rand()
    rng = (rng * 1103515245 + 12345) % 2147483648
    return rng / 2147483648
end

for src = 1, 64 do
    if src <= 16 then
        players[src] = { x = 600.0 + rand() * 40, y = 600.0 + rand() * 40, z = 0.0 }
    else
        players[src] = { x = rand() * 1200, y = rand() * 1200, z = 0.0 }
    end
end

for i = 1, 1000 do
    if i <= 300 then invoking = 'bench_doomed' else invoking = 'bench_res' end
    SyncCreate('prop', {
        id = 'r' .. i, model = 'prop_barrel_01',
        coords = { x = (i % 32) * 40.0, y = math.floor(i / 32) * 40.0, z = 0.0 },
        dynamic = i % 10 == 0,
        clientData = { label = 'r' .. i, n = i },
    })
end
invoking = 'bench_res'
local afterCreate = { calls = wire.calls, entries = wire.entries, bytes = wire.bytes }

local loop = threads[#threads]
local TICK = {}
local passCpu = 0
local function pass()
    local p0 = os.clock()
    local budget = 1
    local realWait = env.Wait
    env.Wait = function(ms)
        budget = budget - 1
        if budget <= 0 then error(TICK, 0) end
        realWait(ms)
    end
    local ok, err = pcall(loop)
    env.Wait = realWait
    clock = clock + 1000
    passCpu = passCpu + (os.clock() - p0)
    if not ok and err ~= TICK then error(err, 0) end
end

local t0 = os.clock()
for second = 1, 60 do
    for src = 17, 24 do
        local p = players[src]
        p.x = p.x + 15.0
        if p.x > 1250 then p.x = 0.0 end
    end
    for k = 1, 20 do
        local i = 300 + ((second * 20 + k) % 700) + 1
        SyncCreate('prop', {
            id = 'r' .. i, model = 'prop_barrel_01',
            coords = { x = (i % 32) * 40.0, y = math.floor(i / 32) * 40.0, z = 0.0 },
            dynamic = i % 10 == 0,
            clientData = { label = 'r' .. i, n = i, t = second },
        })
    end
    pass()
end
local cpu = os.clock() - t0
local afterPasses = { calls = wire.calls, entries = wire.entries, bytes = wire.bytes }

for _, fn in ipairs(handlers.onResourceStop or {}) do fn('bench_doomed') end

local function delta(a, b) return b.calls - a.calls, b.entries - a.entries, b.bytes - a.bytes end
print(('sync wire bench (%s)'):format(_VERSION))
print('  workload: 64 players (16 in a hub, 8 walking), 1000 props (100 dynamic),')
print('            20 re-upserts/pass, 60 passes, then one owner with 300 records stops')
print(('  create (1000 upserts)    %7d events %8d entries %10d bytes')
    :format(afterCreate.calls, afterCreate.entries, afterCreate.bytes))
local pc, pe, pb = delta(afterCreate, afterPasses)
print(('  60 passes + updates      %7d events %8d entries %10d bytes   (%.0f ms cpu, %.0f in passes)')
    :format(pc, pe, pb, cpu * 1000, passCpu * 1000))
print(('  owner stop (300)         %7d events %8d entries %10d bytes')
    :format(delta(afterPasses, wire)))
print(('  latent events            %7d'):format(wire.latent))
