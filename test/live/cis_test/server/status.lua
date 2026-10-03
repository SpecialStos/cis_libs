-- status.json: what the agent reads instead of console scrollback.
--
-- WHY A FILE AT ALL. Before this, the only way to learn what the server was
-- running was to read the txAdmin console -- which is a web UI, is not
-- line-oriented, is not addressable from a script, and on the PC session had to
-- be scraped by hand. The handoff records the result: a deploy once "succeeded"
-- while old code kept running, and nothing noticed for a cycle. That is the
-- failure this file exists to make impossible, and it is why tools/live-run.js
-- checks the commit in here against the commit it just deployed before it will
-- run a single case.
--
-- WHAT IS IN IT, AND WHAT IS DELIBERATELY NOT. The cis_libs version, the
-- deployed commit, whether a player is connected, and who owns each capability
-- slot. NOT who the player is: no name, no identifier, no IP, ever. A count and
-- a boolean are enough to decide whether the player tier can run, and a
-- status.json that named the player would be a file with a person's details in
-- it that gets copied around. `cis_test restore` and the results files keep the
-- same rule: counts, never identities.
--
-- WHEN IT IS WRITTEN. At start, on every player join and drop, and on
-- `cis_test status`. The join/drop half is implemented as a change-detecting
-- watcher rather than only as event handlers, and that is deliberate: FiveM has
-- no single reliable server-side "player joined" event, and an event-driven
-- implementation would silently stop updating the one field the agent waits on.
-- The watcher writes only when something actually changed, so it costs one cheap
-- compare a second and still behaves exactly like an event handler.

CisTestStatus = {}

local RESOURCES = { 'cis_libs', 'cis_test_providers', 'cis_test_b', 'cis_test_c', 'cis_test_badmeta', 'cis_ctl' }

-- --------------------------------------------------------------- collecting

local function libsVersion()
    -- Read out of cis_libs' own manifest rather than asked for. There is no
    -- GetVersion export, and a guessed '?' in the one line an operator reads to
    -- decide which build is live is worse than no line at all.
    local version = 'unknown'
    pcall(function()
        local mf = LoadResourceFile('cis_libs', 'fxmanifest.lua')
        version = (mf and mf:match('version%s+"([^"]+)"')) or 'unknown'
    end)
    return version
end

-- The whole snapshot, minus the timestamp.
function CisTestStatus.Snapshot()
    local count = CisTestRunner.PlayerCount()
    local slotOwners = {}
    local ok, caps = pcall(function() return exports['cis_libs']:GetCapabilities() end)
    if ok and type(caps) == 'table' then
        for slot, entry in pairs(caps) do
            -- The owner name is a resource name, never a player's.
            slotOwners[slot] = (type(entry) == 'table' and entry.owner) or '-'
        end
    end

    local resources = {}
    for _, name in ipairs(RESOURCES) do
        resources[name] = GetResourceState(name)
    end

    -- Which suites exist and which of them need a player, read from the runner
    -- rather than written down anywhere else. tools/live-run.js needs this to
    -- decide whether to start a client, and a hard-coded tier list there would
    -- be the thing that goes stale: a suite added tomorrow would be run with no
    -- player and every case in it would SKIP, and the run would still be green.
    local suites = {}
    local okSuites, list = pcall(function() return CisTestRunner.Suites() end)
    if okSuites and type(list) == 'table' then
        for _, s in ipairs(list) do
            suites[#suites + 1] = {
                suite = tostring(s.name),
                tier = tostring(s.tier),
                needsPlayer = (s.needsPlayer == true),
            }
        end
    end

    return {
        cisLibsVersion = libsVersion(),
        -- 'unknown' when deploy.json is missing, which is itself the signal: it
        -- means the harness was deployed by something other than the deploy tool.
        commit = CisTestRunner.Commit(),
        playerConnected = count > 0,
        playerCount = count,
        slotOwners = slotOwners,
        resources = resources,
        suites = suites,
    }
end

-- ------------------------------------------------------------------ writing

function CisTestStatus.Write()
    local snap = CisTestStatus.Snapshot()
    local body = {
        written = os.date('!%Y-%m-%dT%H:%M:%SZ'),
        cisLibsVersion = snap.cisLibsVersion,
        commit = snap.commit,
        playerConnected = snap.playerConnected,
        playerCount = snap.playerCount,
        slotOwners = snap.slotOwners,
        resources = snap.resources,
        suites = snap.suites,
    }
    local encoded = CisTestJson.encode(body)
    local ok, err = pcall(SaveResourceFile, GetCurrentResourceName(), 'status.json', encoded, -1)
    if not ok then
        print(('[cis_test] could not write status.json: %s'):format(tostring(err)))
        return false
    end
    return true, encoded
end

-- ------------------------------------------------------------------ reading

-- Parsed back out of the encoded form rather than reused from the table, so the
-- signature describes what was actually WRITTEN. Comparing the table instead
-- would sign off on an encoding that silently dropped a field.
local function signature(encoded)
    local stripped = encoded:gsub('"written":"[^"]*",', '')
    return stripped
end

-- ------------------------------------------------------------------- watching

local lastSignature = nil

-- Writes only on a change. Called on a timer AND from `cis_test status`, so the
-- status command always writes whether or not anything moved.
function CisTestStatus.Refresh(force)
    local ok, encoded = CisTestStatus.Write()
    if not ok then return false end
    local sig = signature(encoded)
    if force or sig ~= lastSignature then
        lastSignature = sig
        return true
    end
    return false
end

-- One write at load, so a `cis_test status` immediately after a start finds a
-- file rather than waiting out the watcher's first tick.
pcall(function() CisTestStatus.Refresh(true) end)

CreateThread(function()
    while true do
        Wait(1000)
        pcall(function() CisTestStatus.Refresh(false) end)
    end
end)

-- The event path, kept alongside the watcher because a drop is the one moment
-- an operator is most likely to be looking, and the watcher would otherwise
-- take up to a second to agree with it.
RegisterNetEvent('playerDropped', function()
    CreateThread(function()
        -- One tick of delay: the dropped player is still in GetPlayers() at the
        -- moment the event fires, and writing status.json that says a player is
        -- connected when they just left is exactly the kind of stale fact this
        -- file exists to eliminate.
        Wait(500)
        pcall(function() CisTestStatus.Refresh(true) end)
    end)
end)

return true